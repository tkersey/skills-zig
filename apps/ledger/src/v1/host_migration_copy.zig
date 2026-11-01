const std = @import("std");
const catalog = @import("host_catalog.zig");

pub const directory_name = ".migration-copy";
pub const payload_name = "payload";
pub const bytes_max: u64 = 2 * 1024 * 1024 * 1024;

pub const Scratch = struct {
    dir: std.Io.Dir,

    pub fn open(io: std.Io, root: std.Io.Dir) !Scratch {
        root.createDir(io, directory_name, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const dir = try root.openDir(io, directory_name, .{
            .follow_symlinks = false,
            .iterate = true,
        });
        errdefer dir.close(io);
        try catalog.sync(io, root);
        const result: Scratch = .{ .dir = dir };
        try result.clear(io);
        return result;
    }

    pub fn deinit(self: Scratch, io: std.Io) void {
        self.dir.close(io);
    }

    pub fn clear(self: Scratch, io: std.Io) !void {
        var entries = self.dir.iterate();
        const entry = (try entries.next(io)) orelse return;
        if (!std.mem.eql(u8, entry.name, payload_name) or try entries.next(io) != null)
            return error.UnknownMigrationScratch;
        const stat = try self.dir.statFile(io, payload_name, .{ .follow_symlinks = false });
        if (stat.kind != .file or stat.nlink != 1 or stat.size > bytes_max)
            return error.UnknownMigrationScratch;
        try self.dir.deleteFile(io, payload_name);
        try catalog.sync(io, self.dir);
    }

    pub fn copy(
        self: Scratch,
        io: std.Io,
        input: std.Io.File,
        destination: std.Io.Dir,
        leaf: []const u8,
        expected: u64,
        digest: []const u8,
    ) !void {
        if (expected > bytes_max or digest.len != 64) return error.InvalidLegacyManifest;
        try self.clear(io);
        const output = try self.dir.createFile(io, payload_name, .{
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        defer output.close(io);
        try stream(io, input, output, expected, digest);
        try output.sync(io);
        try self.dir.renamePreserve(payload_name, destination, leaf, io);
        try catalog.sync(io, destination);
        try catalog.sync(io, self.dir);
    }
};

pub fn stream(
    io: std.Io,
    input: std.Io.File,
    output: std.Io.File,
    expected: u64,
    digest: []const u8,
) !void {
    if (expected > bytes_max or digest.len != 64) return error.InvalidLegacyManifest;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var size: u64 = 0;
    while (size <= expected) {
        const count = input.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        if (count > expected - size) return error.SourceChanged;
        size += count;
        hash.update(buffer[0..count]);
        try output.writeStreamingAll(io, buffer[0..count]);
    }
    const actual = std.fmt.bytesToHex(hash.finalResult(), .lower);
    if (size != expected or !std.mem.eql(u8, &actual, digest)) return error.SourceChanged;
}

pub const TestFault = struct {
    pub const Kind = enum { write, before_rename, after_rename, directory_sync };
    pub var kind: Kind = .write;
    var file: ?std.Io.File = null;
    var writes: usize = 0;
    var published: bool = false;
    pub var reached: bool = false;

    pub fn install(vtable: *std.Io.VTable, selected: Kind) void {
        kind = selected;
        file = null;
        writes = 0;
        published = false;
        reached = false;
        vtable.dirCreateFile = create;
        vtable.operate = operate;
        vtable.dirRenamePreserve = rename;
        vtable.fileSync = sync;
    }

    fn create(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        name: []const u8,
        options: std.Io.Dir.CreateFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        const result = try std.testing.io.vtable.dirCreateFile(userdata, dir, name, options);
        if (std.mem.eql(u8, name, payload_name)) {
            const path = dir.realPathFileAlloc(
                std.testing.io,
                ".",
                std.testing.allocator,
            ) catch |err| {
                std.debug.panic("copy probe directory: {s}", .{@errorName(err)});
            };
            defer std.testing.allocator.free(path);
            if (std.mem.eql(u8, std.fs.path.basename(path), directory_name)) file = result;
        }
        return result;
    }

    fn operate(
        userdata: ?*anyopaque,
        operation: std.Io.Operation,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        if (operation == .file_write_streaming and kind == .write and file != null) {
            const write = operation.file_write_streaming;
            if (write.file.handle == file.?.handle) {
                reached = true;
                writes += 1;
                if (writes > 1) return .{ .file_write_streaming = error.NoSpaceLeft };
                return std.testing.io.vtable.operate(userdata, .{ .file_write_streaming = .{
                    .file = write.file,
                    .data = &.{write.data[0][0..@min(2, write.data[0].len)]},
                } });
            }
        }
        return std.testing.io.vtable.operate(userdata, operation);
    }

    fn rename(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_name: []const u8,
        new_dir: std.Io.Dir,
        new_name: []const u8,
    ) std.Io.Dir.RenamePreserveError!void {
        const selected = std.mem.eql(u8, old_name, payload_name);
        if (selected and kind == .before_rename) {
            reached = true;
            return error.Canceled;
        }
        try std.testing.io.vtable.dirRenamePreserve(
            userdata,
            old_dir,
            old_name,
            new_dir,
            new_name,
        );
        if (selected) {
            published = true;
            if (kind == .after_rename) {
                reached = true;
                return error.HardwareFailure;
            }
        }
    }

    fn sync(userdata: ?*anyopaque, target: std.Io.File) std.Io.File.SyncError!void {
        if (published and kind == .directory_sync) {
            reached = true;
            return error.InputOutput;
        }
        return std.testing.io.vtable.fileSync(userdata, target);
    }
};

test "migration copy rejects digest mismatch and preserves publication collisions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "history\n" });
    const scratch = try Scratch.open(io, tmp.dir);
    defer scratch.deinit(io);
    const input = try tmp.dir.openFile(io, "source", .{});
    defer input.close(io);
    const digest = testDigest();
    const wrong: [64]u8 = @splat('0');
    try std.testing.expectError(
        error.SourceChanged,
        scratch.copy(io, input, tmp.dir, "canonical", 8, &wrong),
    );
    try std.testing.expect(!try catalog.existsAt(io, tmp.dir, "canonical"));
    try tmp.dir.writeFile(io, .{ .sub_path = "canonical", .data = "other history\n" });
    const second = try tmp.dir.openFile(io, "source", .{});
    defer second.close(io);
    try std.testing.expectError(
        error.PathAlreadyExists,
        scratch.copy(io, second, tmp.dir, "canonical", 8, &digest),
    );
    const bytes = try catalog.readBytes(std.testing.allocator, io, tmp.dir, "canonical", 128);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("other history\n", bytes);
}

test "migration copy one hundred interrupted attempts retain one bounded payload" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "history\n" });
    const digest = testDigest();
    for (0..100) |_| {
        const scratch = try Scratch.open(io, tmp.dir);
        defer scratch.deinit(io);
        const input = try tmp.dir.openFile(io, "source", .{});
        defer input.close(io);
        var vtable = io.vtable.*;
        TestFault.install(&vtable, .write);
        var injected = io;
        injected.vtable = &vtable;
        try std.testing.expectError(
            error.NoSpaceLeft,
            scratch.copy(injected, input, tmp.dir, "canonical", 8, &digest),
        );
        try std.testing.expect(TestFault.reached);
        try std.testing.expect(!try catalog.existsAt(io, tmp.dir, "canonical"));
        var entries = scratch.dir.iterate();
        try std.testing.expectEqualStrings(payload_name, (try entries.next(io)).?.name);
        try std.testing.expect(try entries.next(io) == null);
        try std.testing.expectEqual(
            @as(u64, 2),
            (try scratch.dir.statFile(io, payload_name, .{})).size,
        );
    }
    const scratch = try Scratch.open(io, tmp.dir);
    defer scratch.deinit(io);
    const input = try tmp.dir.openFile(io, "source", .{});
    defer input.close(io);
    try scratch.copy(io, input, tmp.dir, "canonical", 8, &digest);
    try std.testing.expect(!try catalog.existsAt(io, scratch.dir, payload_name));
}

fn testDigest() [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("history\n", &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "migration copy retains an unexpected scratch link" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try Scratch.open(io, tmp.dir);
    defer scratch.deinit(io);
    try scratch.dir.symLink(io, "/missing/foreign", payload_name, .{});
    try std.testing.expectError(error.UnknownMigrationScratch, scratch.clear(io));
    try std.testing.expectEqual(
        .sym_link,
        (try scratch.dir.statFile(io, payload_name, .{ .follow_symlinks = false })).kind,
    );
}
