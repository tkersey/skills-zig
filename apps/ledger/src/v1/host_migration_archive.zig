const std = @import("std");
const catalog = @import("host_catalog.zig");

pub const directory_name = ".migration-archive";
const declaration_name = "migration-archive.json";
const schema = "ledger-migration-archive/v1";
const Declaration = struct { schema: []const u8, store_id: []const u8, store_root: []const u8 };
const Expected = struct { kind: std.Io.File.Kind, size: u64 = 0 };
const Member = struct { path: []const u8, kind: std.Io.File.Kind };
const bytes_max: u64 = 2 * 1024 * 1024 * 1024;
pub const manifest_bytes_max: usize = 2 * 1024 * 1024 * 1024;

pub const Scratch = struct {
    root: std.Io.Dir,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        controls: std.Io.Dir,
        root: std.Io.Dir,
        store_id: []const u8,
        store_root: []const u8,
    ) !Scratch {
        const expected: Declaration = .{
            .schema = schema,
            .store_id = store_id,
            .store_root = store_root,
        };
        if (try catalog.existsAt(io, controls, declaration_name)) {
            const bytes = try catalog.readBytes(allocator, io, controls, declaration_name, 4096);
            defer allocator.free(bytes);
            var parsed = try std.json.parseFromSlice(Declaration, allocator, bytes, .{
                .duplicate_field_behavior = .@"error",
            });
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.schema, schema) or
                !std.mem.eql(u8, parsed.value.store_id, store_id) or
                !std.mem.eql(u8, parsed.value.store_root, store_root))
                return error.InvalidMigrationArchive;
        } else {
            if (try catalog.existsAt(io, root, directory_name))
                return error.UndeclaredMigrationArchive;
            try catalog.writeJson(allocator, io, controls, declaration_name, expected, 4096);
        }
        const declaration = try controls.openFile(io, declaration_name, .{
            .follow_symlinks = false,
        });
        defer declaration.close(io);
        const stat = try declaration.stat(io);
        if (stat.kind != .file or stat.nlink != 1) return error.InvalidMigrationArchive;
        try declaration.sync(io);
        try catalog.sync(io, controls);
        return .{ .root = try root.openDir(io, ".", .{ .follow_symlinks = false }) };
    }

    pub fn deinit(self: Scratch, io: std.Io) void {
        self.root.close(io);
    }

    pub fn restart(
        self: Scratch,
        allocator: std.mem.Allocator,
        io: std.Io,
        snapshot: anytype,
    ) !void {
        try self.clear(allocator, io, snapshot);
        try self.root.createDir(io, directory_name, .fromMode(0o700));
        try catalog.sync(io, self.root);
    }

    pub fn clear(
        self: Scratch,
        allocator: std.mem.Allocator,
        io: std.Io,
        snapshot: anytype,
    ) !void {
        if (!try catalog.existsAt(io, self.root, directory_name)) return;
        const stage = try self.root.openDir(io, directory_name, .{
            .follow_symlinks = false,
            .iterate = true,
        });
        defer stage.close(io);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const owned = arena.allocator();
        var iterator = stage.iterate();
        const first = try iterator.next(io);
        if (first == null or
            (std.mem.eql(u8, first.?.name, "manifest.json") and try iterator.next(io) == null))
        {
            if (first != null) {
                const stat = try stage.statFile(io, "manifest.json", .{ .follow_symlinks = false });
                if (stat.kind != .file or stat.nlink != 1 or stat.size > bytes_max)
                    return error.UnknownMigrationArchive;
                try catalog.sync(io, stage);
                try stage.deleteFile(io, "manifest.json");
            }
            try self.root.deleteDir(io, directory_name);
            try catalog.sync(io, self.root);
            return;
        }
        const expected = try expectedMembers(@TypeOf(snapshot.sources), owned, io, stage);
        const members = try inspect(owned, io, stage, &expected);
        var remaining = members.len;
        while (remaining > 0) {
            remaining -= 1;
            const member = members[remaining];
            if (std.mem.eql(u8, member.path, "manifest.json")) continue;
            if (member.kind == .directory) {
                try stage.deleteDir(io, member.path);
            } else {
                try stage.deleteFile(io, member.path);
            }
        }
        try catalog.sync(io, stage);
        try stage.deleteFile(io, "manifest.json");
        try self.root.deleteDir(io, directory_name);
        try catalog.sync(io, self.root);
    }
};

fn expectedMembers(
    comptime Sources: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    stage: std.Io.Dir,
) !std.StringHashMap(Expected) {
    const Manifest = struct { schema: []const u8, sources: Sources };
    const bytes = try catalog.readBytes(allocator, io, stage, "manifest.json", manifest_bytes_max);
    const prior = try std.json.parseFromSlice(Manifest, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    if (!std.mem.eql(u8, prior.value.schema, "ledger-legacy-archive/v1") or
        prior.value.sources.map.count() > 128)
        return error.UnknownMigrationArchive;
    var expected: std.StringHashMap(Expected) = .init(allocator);
    try expected.put("manifest.json", .{ .kind = .file, .size = bytes.len });
    var total: u64 = 0;
    var count: usize = 0;
    for (prior.value.sources.map.keys(), prior.value.sources.map.values()) |index, source| {
        if (index.len == 0 or index.len > 3) return error.UnknownMigrationArchive;
        for (index) |byte| if (!std.ascii.isDigit(byte)) return error.UnknownMigrationArchive;
        for (source.entries.map.keys(), source.entries.map.values()) |name, entry| {
            count += 1;
            if (count > 100000) return error.UnknownMigrationArchive;
            if (name.len == 0 or name.len > std.fs.max_path_bytes or std.fs.path.isAbsolute(name))
                return error.UnknownMigrationArchive;
            var components = std.fs.path.componentIterator(name);
            while (components.next()) |component| {
                if (std.mem.eql(u8, component.name, ".") or
                    std.mem.eql(u8, component.name, "..")) return error.UnknownMigrationArchive;
            }
            const kind: std.Io.File.Kind = if (std.mem.eql(u8, entry.kind, "file"))
                .file
            else if (std.mem.eql(u8, entry.kind, "directory"))
                .directory
            else
                continue;
            const size = entry.size orelse 0;
            if (size > bytes_max - total) return error.UnknownMigrationArchive;
            total += size;
            const path = try std.fmt.allocPrint(allocator, "worktree-{s}/{s}", .{ index, name });
            try expected.put(path, .{ .kind = kind, .size = size });
            var parent = std.fs.path.dirname(path);
            while (parent) |directory| {
                try expected.put(directory, .{ .kind = .directory });
                parent = std.fs.path.dirname(directory);
            }
        }
    }
    return expected;
}

fn inspect(
    allocator: std.mem.Allocator,
    io: std.Io,
    stage: std.Io.Dir,
    expected: *const std.StringHashMap(Expected),
) ![]const Member {
    var directories: std.ArrayList([]const u8) = .empty;
    try directories.append(allocator, ".");
    var members: std.ArrayList(Member) = .empty;
    var cursor: usize = 0;
    while (cursor < directories.items.len) : (cursor += 1) {
        const prefix = directories.items[cursor];
        const dir = try stage.openDir(io, prefix, .{ .follow_symlinks = false, .iterate = true });
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (members.items.len >= expected.count()) return error.UnknownMigrationArchive;
            const path = if (std.mem.eql(u8, prefix, "."))
                try allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(allocator, &.{ prefix, entry.name });
            const admitted = expected.get(path) orelse return error.UnknownMigrationArchive;
            const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
            if (stat.kind != admitted.kind or
                (stat.kind == .file and (stat.nlink != 1 or stat.size > admitted.size)))
                return error.UnknownMigrationArchive;
            try members.append(allocator, .{ .path = path, .kind = stat.kind });
            if (stat.kind == .directory) try directories.append(allocator, path);
        }
    }
    return members.toOwnedSlice(allocator);
}

pub const TestFault = struct {
    pub const Kind = enum { manifest, write, before_rename, after_rename, directory_sync };
    var kind: Kind = .write;
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
        if (file != null) return result;
        const path = dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator) catch |err| {
            std.debug.panic("archive probe directory: {s}", .{@errorName(err)});
        };
        defer std.testing.allocator.free(path);
        if ((kind == .manifest and std.mem.eql(u8, std.fs.path.basename(path), directory_name)) or
            (kind == .write and std.mem.indexOf(u8, path, "/.migration-archive/") != null))
            file = result;
        return result;
    }

    fn operate(
        userdata: ?*anyopaque,
        operation: std.Io.Operation,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        if (operation == .file_write_streaming and file != null) {
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
        from: std.Io.Dir,
        name: []const u8,
        to: std.Io.Dir,
        leaf: []const u8,
    ) std.Io.Dir.RenamePreserveError!void {
        const selected = std.mem.eql(u8, name, directory_name);
        if (selected and kind == .before_rename) {
            reached = true;
            return error.Canceled;
        }
        try std.testing.io.vtable.dirRenamePreserve(userdata, from, name, to, leaf);
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

test "archive declaration rejects occupied unowned paths and survives publication errors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try tmp.dir.createDir(io, "controls", .fromMode(0o700));
    const controls = try tmp.dir.openDir(io, "controls", .{});
    defer controls.close(io);
    try tmp.dir.createDir(io, directory_name, .fromMode(0o700));
    try std.testing.expectError(error.UndeclaredMigrationArchive, Scratch.open(
        allocator,
        io,
        controls,
        tmp.dir,
        id,
        root,
    ));
    try std.testing.expect(!try catalog.existsAt(io, controls, declaration_name));
    try tmp.dir.deleteDir(io, directory_name);
    var vtable = io.vtable.*;
    vtable.dirRename = struct {
        fn rename(
            userdata: ?*anyopaque,
            from: std.Io.Dir,
            name: []const u8,
            to: std.Io.Dir,
            leaf: []const u8,
        ) std.Io.Dir.RenameError!void {
            try std.testing.io.vtable.dirRename(userdata, from, name, to, leaf);
            if (std.mem.eql(u8, leaf, declaration_name)) return error.HardwareFailure;
        }
    }.rename;
    var injected = io;
    injected.vtable = &vtable;
    try std.testing.expectError(error.HardwareFailure, Scratch.open(
        allocator,
        injected,
        controls,
        tmp.dir,
        id,
        root,
    ));
    try std.testing.expect(!try catalog.existsAt(io, tmp.dir, directory_name));
    const before = try controls.statFile(io, declaration_name, .{});
    const scratch = try Scratch.open(allocator, io, controls, tmp.dir, id, root);
    defer scratch.deinit(io);
    const after = try controls.statFile(io, declaration_name, .{});
    try std.testing.expectEqual(before.inode, after.inode);
    try std.testing.expectError(error.InvalidMigrationArchive, Scratch.open(
        allocator,
        io,
        controls,
        tmp.dir,
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        root,
    ));
    const unchanged = try controls.statFile(io, declaration_name, .{});
    try std.testing.expectEqual(before.inode, unchanged.inode);
}
