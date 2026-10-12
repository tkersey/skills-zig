const std = @import("std");
const durable_store = @import("durable_store");

const Io = std.Io.Threaded.global_single_threaded;
const lock_marker = "memory-note-extension-lock/v1\n";
const stage_attempts_max = 16;

pub const ExtensionLock = struct {
    file: std.Io.File,
    created: bool,

    pub fn release(self: *ExtensionLock) void {
        self.file.close(Io.io());
        self.* = undefined;
    }
};

/// Keep the marker in place: old writers use create-new sentinel locks and
/// must not enter while this process-held locking protocol is in use.
pub fn acquireExtensionLock(
    allocator: std.mem.Allocator,
    path: []const u8,
) !ExtensionLock {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    const created = try prepareLockMarker(allocator, path);
    var file = std.Io.Dir.openFileAbsolute(Io.io(), path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.MemoryNoteBusy,
        error.SymLinkLoop => return error.SymlinkComponent,
        else => return err,
    };
    errdefer file.close(Io.io());
    const stat = try file.stat(Io.io());
    if (stat.kind != .file) return error.NotFile;
    if (stat.size != lock_marker.len) return error.LegacyLockNeedsReview;
    var reader = file.reader(Io.io(), &.{});
    const raw = try reader.interface.allocRemaining(allocator, .limited(lock_marker.len + 1));
    defer allocator.free(raw);
    if (!std.mem.eql(u8, raw, lock_marker)) return error.LegacyLockNeedsReview;
    return .{ .file = file, .created = created };
}

fn prepareLockMarker(allocator: std.mem.Allocator, path: []const u8) !bool {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try durable_store.ensureDirectoryPathNoSymlinks(parent);
    const info = std.Io.Dir.cwd().statFile(Io.io(), path, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (info) |stat| {
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) return error.NotFile;
        return false;
    }
    // Atomic marker publication has no visible empty-sentinel interval.
    durable_store.writeTextCreateNewAtomic(allocator, path, lock_marker, .{}) catch |err|
        switch (err) {
            error.PathAlreadyExists => return false,
            else => return err,
        };
    return true;
}

const Stage = struct {
    file: std.Io.File,
    name: [32]u8,
    file_open: bool = true,
    exists: bool = true,

    fn deinit(self: *Stage, directory: std.Io.Dir) void {
        if (self.file_open) self.file.close(Io.io());
        if (self.exists) directory.deleteFile(Io.io(), &self.name) catch |err| {
            std.log.warn("memory-note staging cleanup failed for {s}: {s}", .{
                self.name, @errorName(err),
            });
        };
        self.* = undefined;
    }
};

fn createStage(directory: std.Io.Dir) !Stage {
    for (0..stage_attempts_max) |_| {
        var random: [16]u8 = undefined;
        Io.io().random(&random);
        const name = std.fmt.bytesToHex(random, .lower);
        const file = directory.createFile(Io.io(), &name, .{
            .exclusive = true,
            .read = true,
            .permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
                std.Io.File.Permissions.fromMode(0o600)
            else
                .default_file,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return .{ .file = file, .name = name };
    }
    return error.StagingNameExhausted;
}

/// Stage outside notes, including on systems without unnamed temporary files.
/// A killed writer can leave control bytes here, never a partial admission in
/// the inventory. Publication preserves both the final name and existing files.
pub fn publishNote(
    allocator: std.mem.Allocator,
    path: []const u8,
    raw: []const u8,
) !void {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    const notes = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const base = std.fs.path.basename(path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, ".."))
        return error.InvalidPath;
    const extension = std.fs.path.dirname(notes) orelse return error.InvalidPath;
    const staging = try std.fs.path.join(allocator, &.{ extension, ".memory-note-staging" });
    defer allocator.free(staging);
    try durable_store.ensureDirectoryPathNoSymlinks(notes);
    try durable_store.ensureDirectoryPathNoSymlinks(staging);
    var notes_dir = try std.Io.Dir.openDirAbsolute(Io.io(), notes, .{ .follow_symlinks = false });
    defer notes_dir.close(Io.io());
    var staging_dir = try std.Io.Dir.openDirAbsolute(Io.io(), staging, .{
        .follow_symlinks = false,
    });
    defer staging_dir.close(Io.io());
    var stage = try createStage(staging_dir);
    defer stage.deinit(staging_dir);
    try stage.file.writeStreamingAll(Io.io(), raw);
    try stage.file.sync(Io.io());
    stage.file.close(Io.io());
    stage.file_open = false;
    try staging_dir.renamePreserve(&stage.name, notes_dir, base, Io.io());
    stage.exists = false;
}

test "extension lock is exclusive reusable and leaves its recognized marker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const path = try std.fs.path.join(allocator, &.{ home, "locks", "harness.lock" });
    defer allocator.free(path);
    {
        var first = try acquireExtensionLock(allocator, path);
        defer first.release();
        try std.testing.expect(first.created);
        try std.testing.expectError(error.MemoryNoteBusy, acquireExtensionLock(allocator, path));
    }
    const raw = try durable_store.readRegularFileNoSymlink(allocator, path, 64);
    defer allocator.free(raw);
    try std.testing.expectEqualStrings(lock_marker, raw);
    var second = try acquireExtensionLock(allocator, path);
    defer second.release();
    try std.testing.expect(!second.created);
}

test "extension lock does not steal legacy sentinels or follow symlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const path = try std.fs.path.join(allocator, &.{ home, "legacy.lock" });
    defer allocator.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy.lock", .data = "" });
    try std.testing.expectError(error.LegacyLockNeedsReview, acquireExtensionLock(allocator, path));
    try std.testing.expectEqual(@as(u64, 0), (try tmp.dir.statFile(io, "legacy.lock", .{})).size);
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy.lock", .data = "unrecognized" });
    try std.testing.expectError(error.LegacyLockNeedsReview, acquireExtensionLock(allocator, path));
    try tmp.dir.deleteFile(io, "legacy.lock");
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = lock_marker });
    try tmp.dir.symLink(io, "target", "legacy.lock", .{});
    try std.testing.expectError(error.SymlinkComponent, acquireExtensionLock(allocator, path));
}

test "publication isolates abandoned staging and never replaces an admission" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "extension/.memory-note-staging");
    try tmp.dir.writeFile(io, .{
        .sub_path = "extension/.memory-note-staging/abandoned",
        .data = "{partial",
    });
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const target = try std.fs.path.join(allocator, &.{ home, "extension", "notes", "note.md" });
    defer allocator.free(target);
    try publishNote(allocator, target, "{\"complete\":true}\n");
    const stat = try tmp.dir.statFile(io, "extension/notes/note.md", .{});
    if (@hasDecl(std.Io.File.Permissions, "toMode"))
        try std.testing.expectEqual(
            @as(std.posix.mode_t, 0o600),
            stat.permissions.toMode() & 0o777,
        );
    try std.testing.expectError(error.PathAlreadyExists, publishNote(allocator, target, "changed"));
    const raw = try durable_store.readRegularFileNoSymlink(allocator, target, 64);
    defer allocator.free(raw);
    try std.testing.expectEqualStrings("{\"complete\":true}\n", raw);
    _ = try tmp.dir.statFile(io, "extension/.memory-note-staging/abandoned", .{});
    const notes = try std.fs.path.join(allocator, &.{ home, "extension", "notes" });
    defer allocator.free(notes);
    const names = try durable_store.listSortedRegularFilesNoSymlink(allocator, notes, 2, 64);
    defer durable_store.freeStringList(allocator, names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("note.md", names[0]);
}

test "publication rejects a symlinked control staging directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "extension");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.symLink(io, "../elsewhere", "extension/.memory-note-staging", .{
        .is_directory = true,
    });
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const target = try std.fs.path.join(allocator, &.{ home, "extension", "notes", "note.md" });
    defer allocator.free(target);
    try std.testing.expectError(error.SymlinkComponent, publishNote(allocator, target, "complete"));
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io, "extension/notes/note.md", .{}),
    );
}
