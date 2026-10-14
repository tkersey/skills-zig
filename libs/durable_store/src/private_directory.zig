const std = @import("std");
const authority = @import("fs_authority.zig");
const filesystem = @import("filesystem.zig");
const staged = @import("staged_file.zig");

/// An operation-local owner for private entries. Directory handles are owned;
/// the supplied I/O implementation must outlive this owner and its children.
pub const PrivateDirectory = struct {
    io: std.Io,
    directory: std.Io.Dir,

    pub const Mode = enum { read_only, create };

    pub fn open(fs: authority.Fs, path: []const u8, mode: Mode) !PrivateDirectory {
        if (path.len == 0) return error.InvalidPath;
        if (mode == .create) try filesystem.ensureDirectoryPathNoSymlinks(fs, path);
        var directory = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openDirAbsolute(fs.io, "/", .{ .follow_symlinks = false })
        else
            try fs.directory().openDir(fs.io, ".", .{ .follow_symlinks = false });
        errdefer directory.close(fs.io);
        var components = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);
        while (components.next()) |component| {
            const child = try directory.openDir(fs.io, component, .{ .follow_symlinks = false });
            directory.close(fs.io);
            directory = child;
        }
        try admit(fs.io, directory, mode);
        return .{ .io = fs.io, .directory = directory };
    }

    pub fn deinit(self: *PrivateDirectory) void {
        self.directory.close(self.io);
        self.* = undefined;
    }

    pub fn openChild(self: *const PrivateDirectory, leaf: []const u8, mode: Mode) !PrivateDirectory {
        try validateLeaf(leaf);
        try admit(self.io, self.directory, .read_only);
        if (mode == .create) {
            self.directory.createDir(self.io, leaf, privatePermissions(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        const directory = try self.directory.openDir(self.io, leaf, .{ .follow_symlinks = false });
        errdefer directory.close(self.io);
        try admit(self.io, directory, mode);
        return .{ .io = self.io, .directory = directory };
    }

    pub fn readAlloc(self: *const PrivateDirectory, allocator: std.mem.Allocator, leaf: []const u8, max_bytes: usize) ![]u8 {
        try validateLeaf(leaf);
        try admit(self.io, self.directory, .read_only);
        const file = try self.directory.openFile(self.io, leaf, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file) return error.NotFile;
        if (stat.nlink != 1) return error.HardlinkTarget;
        if (@hasDecl(std.Io.File.Permissions, "toMode") and stat.permissions.toMode() & 0o077 != 0)
            return error.InsecurePrivateFile;
        if (stat.size > max_bytes) return error.FileTooBig;
        var reader = file.reader(self.io, &.{});
        return reader.interface.allocRemaining(allocator, .limited(max_bytes));
    }

    /// Optional caches may abandon a failed publication. Errors do not imply
    /// that the old destination remains present: a rename reply can be lost.
    pub fn replace(self: *const PrivateDirectory, leaf: []const u8, parts: []const []const u8) !void {
        try validateLeaf(leaf);
        try admit(self.io, self.directory, .read_only);
        const outcome = staged.publishReplacement(self.io, self.directory, self.directory, leaf, parts, .{
            .permissions = privatePermissions(0o600),
        });
        switch (outcome) {
            .complete => {},
            .not_published, .publication_unknown => |failure| {
                if (failure.cleanup) |cleanup| authority.warn(self.io, "rollback file removal failed for {s}: {s}; inspect and remove the leftover file", .{ cleanup.stage_name, @errorName(cleanup.cause) });
                return failure.cause;
            },
            .published_unsynced => |err| return err,
        }
    }
};

fn privatePermissions(mode: u32) std.Io.File.Permissions {
    return if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(@intCast(mode)) else .default_file;
}

fn admit(io: std.Io, directory: std.Io.Dir, mode: PrivateDirectory.Mode) !void {
    if (mode == .create and @hasDecl(std.Io.File.Permissions, "fromMode"))
        try directory.setPermissions(io, privatePermissions(0o700));
    const stat = try directory.stat(io);
    if (stat.kind != .directory) return error.NotDir;
    if (@hasDecl(std.Io.File.Permissions, "toMode") and stat.permissions.toMode() & 0o077 != 0)
        return error.InsecurePrivateDirectory;
}

fn validateLeaf(leaf: []const u8) !void {
    if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..") or
        std.mem.indexOfAny(u8, leaf, "/\\\x00") != null) return error.InvalidPath;
}

test "private entry directory binds reads and multipart publication across root swaps" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try PrivateDirectory.open(.init(io, tmp.dir), "cache", .create);
    defer root.deinit();
    var plans = try root.openChild("plans", .create);
    defer plans.deinit();
    try plans.replace("entry", &.{ "head", "body" });
    try tmp.dir.rename("cache", tmp.dir, "original", io);
    var replacement = try PrivateDirectory.open(.init(io, tmp.dir), "cache", .create);
    defer replacement.deinit();
    try plans.replace("entry", &.{"original owner"});
    const bytes = try plans.readAlloc(std.testing.allocator, "entry", 14);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("original owner", bytes);
    try std.testing.expectError(error.FileTooBig, plans.readAlloc(std.testing.allocator, "entry", 13));
    try std.testing.expectError(error.InvalidPath, plans.replace("../escape", &.{"x"}));
    try std.testing.expectError(error.FileNotFound, replacement.openChild("plans", .read_only));
    try tmp.dir.symLink(io, "original", "alias", .{ .is_directory = true });
    try std.testing.expectError(error.NotDir, PrivateDirectory.open(.init(io, tmp.dir), "alias/plans", .read_only));
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) {
        try plans.directory.setFilePermissions(io, "entry", .fromMode(0o644), .{});
        try std.testing.expectError(error.InsecurePrivateFile, plans.readAlloc(std.testing.allocator, "entry", 64));
        try plans.directory.setPermissions(io, .fromMode(0o755));
        try std.testing.expectError(error.InsecurePrivateDirectory, plans.replace("entry", &.{"x"}));
    }
}

test "private cache paths reject shared permissions" {
    const fs = authority.Fs.init(std.testing.io, std.Io.Dir.cwd());
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const private_dir = try std.fs.path.join(allocator, &.{ root, "private" });
    defer allocator.free(private_dir);
    try filesystem.ensurePrivateDirectoryPathNoSymlinks(fs, private_dir);
    const private_path = try std.fs.path.join(allocator, &.{ private_dir, "entry.bin" });
    defer allocator.free(private_path);
    var entries = try PrivateDirectory.open(fs, private_dir, .read_only);
    defer entries.deinit();
    try entries.replace("entry.bin", &.{"plan"});
    const bytes = try entries.readAlloc(allocator, "entry.bin", 16);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("plan", bytes);
    try fs.directory().setFilePermissions(
        std.testing.io,
        private_path,
        std.Io.File.Permissions.fromMode(0o644),
        .{ .follow_symlinks = false },
    );
    try std.testing.expectError(
        error.InsecurePrivateFile,
        entries.readAlloc(allocator, "entry.bin", 16),
    );
}
