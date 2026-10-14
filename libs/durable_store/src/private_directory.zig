const core_io = @import("core_io");
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
        var directory = try core_io.openSearchDirectory(
            fs.io,
            fs.directory(),
            if (std.fs.path.isAbsolute(path)) "/" else ".",
            .{ .follow_symlinks = false },
        );
        errdefer directory.close(fs.io);
        var components = std.mem.tokenizeScalar(u8, path, std.fs.path.sep);
        while (components.next()) |component| {
            if (mode == .create and components.peek() == null)
                try repairPrivateChild(fs.io, directory, component);
            const child = try core_io.openSearchDirectory(fs.io, directory, component, .{
                .follow_symlinks = false,
            });
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

    pub fn openChild(
        self: *const PrivateDirectory,
        leaf: []const u8,
        mode: Mode,
    ) !PrivateDirectory {
        try validateLeaf(leaf);
        try admit(self.io, self.directory, .read_only);
        if (mode == .create) {
            self.directory.createDir(
                self.io,
                leaf,
                privatePermissions(0o700),
            ) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            try repairPrivateChild(self.io, self.directory, leaf);
        }
        const directory = try core_io.openSearchDirectory(self.io, self.directory, leaf, .{
            .follow_symlinks = false,
        });
        errdefer directory.close(self.io);
        try admit(self.io, directory, mode);
        return .{ .io = self.io, .directory = directory };
    }

    pub fn readAlloc(
        self: *const PrivateDirectory,
        allocator: std.mem.Allocator,
        leaf: []const u8,
        max_bytes: usize,
    ) ![]u8 {
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
        return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| {
            if (err == error.ReadFailed) {
                const cause = reader.err orelse return err;
                if (cause == error.Canceled) return cause;
            }
            return err;
        };
    }

    /// Optional caches may abandon a failed publication. Errors do not imply
    /// that the old destination remains present: a rename reply can be lost.
    pub fn replace(
        self: *const PrivateDirectory,
        leaf: []const u8,
        parts: []const []const u8,
    ) !void {
        try validateLeaf(leaf);
        try admit(self.io, self.directory, .read_only);
        const outcome = staged.publishReplacement(
            self.io,
            self.directory,
            self.directory,
            leaf,
            parts,
            .{
                .permissions = privatePermissions(0o600),
            },
        );
        switch (outcome) {
            .complete => {},
            .not_published, .publication_unknown => |failure| {
                if (failure.cleanup) |cleanup| authority.warn(
                    self.io,
                    "rollback file removal failed for {s}: {s}; inspect" ++
                        " and remove the leftover file",
                    .{ cleanup.stage_name, @errorName(cleanup.cause) },
                );
                return failure.cause;
            },
            .published_unsynced => |err| return err,
        }
    }
};

fn repairPrivateChild(io: std.Io, parent: std.Io.Dir, leaf: []const u8) !void {
    const stat = try parent.statFile(io, leaf, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.NotDir;
    if (@hasDecl(std.Io.File.Permissions, "fromMode"))
        try parent.setFilePermissions(io, leaf, privatePermissions(0o700), .{
            .follow_symlinks = false,
        });
}

fn privatePermissions(mode: u32) std.Io.File.Permissions {
    return if (@hasDecl(
        std.Io.File.Permissions,
        "fromMode",
    )) .fromMode(@intCast(mode)) else .default_file;
}

fn admit(io: std.Io, directory: std.Io.Dir, mode: PrivateDirectory.Mode) !void {
    // Linux traversal handles use O_PATH and cannot be passed to fchmod.
    // Resolve "." relative to the owned handle: the same admitted directory
    // remains authoritative without requiring read access before repairing its mode.
    if (mode == .create and @hasDecl(std.Io.File.Permissions, "fromMode"))
        try directory.setFilePermissions(io, ".", privatePermissions(0o700), .{
            .follow_symlinks = false,
        });
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
    try std.testing.expectError(
        error.FileTooBig,
        plans.readAlloc(std.testing.allocator, "entry", 13),
    );
    try std.testing.expectError(error.InvalidPath, plans.replace("../escape", &.{"x"}));
    try std.testing.expectError(error.FileNotFound, replacement.openChild("plans", .read_only));
    try tmp.dir.symLink(io, "original", "alias", .{ .is_directory = true });
    try std.testing.expectError(
        error.NotDir,
        PrivateDirectory.open(.init(io, tmp.dir), "alias/plans", .read_only),
    );
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) {
        try plans.directory.setFilePermissions(io, "entry", .fromMode(0o644), .{});
        try std.testing.expectError(
            error.InsecurePrivateFile,
            plans.readAlloc(std.testing.allocator, "entry", 64),
        );
        try plans.directory.setFilePermissions(io, ".", .fromMode(0o755), .{
            .follow_symlinks = false,
        });
        try std.testing.expectError(
            error.InsecurePrivateDirectory,
            plans.replace("entry", &.{"x"}),
        );
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

test "private directory repair admits owner-restricted roots and children" {
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "cache", .fromMode(0o700));
    for ([_]u32{ 0o300, 0o100, 0o000, 0o700 }) |mode| {
        try tmp.dir.setFilePermissions(io, "cache", .fromMode(@intCast(mode)), .{});
        defer restoreTestPermissions(io, tmp.dir, "cache");
        try expectPrivateRepair(io, tmp.dir);
    }
}

fn expectPrivateRepair(io: std.Io, parent: std.Io.Dir) !void {
    var cache = try PrivateDirectory.open(.init(io, parent), "cache", .create);
    defer cache.deinit();
    try std.testing.expectEqual(
        @as(u32, 0o700),
        (try cache.directory.stat(io)).permissions.toMode() & 0o777,
    );
    cache.directory.createDir(io, "entries", .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    // In particular, mode 000 cannot be repaired by resolving "." through
    // the restricted child's handle; the parent must authorize that repair.
    try cache.directory.setFilePermissions(io, "entries", .fromMode(0o000), .{});
    defer restoreTestPermissions(io, cache.directory, "entries");
    var entries = try cache.openChild("entries", .create);
    defer entries.deinit();
    try std.testing.expectEqual(
        @as(u32, 0o700),
        (try entries.directory.stat(io)).permissions.toMode() & 0o777,
    );
    try entries.replace("entry", &.{"private"});
    const data = try entries.readAlloc(std.testing.allocator, "entry", 7);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("private", data);
}

test "private directory traversal preserves search-only ancestors and readers" {
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "ancestor/cache");
    try tmp.dir.setFilePermissions(io, "ancestor", .fromMode(0o100), .{});
    defer restoreTestPermissions(io, tmp.dir, "ancestor");
    var cache = try PrivateDirectory.open(.init(io, tmp.dir), "ancestor/cache", .create);
    defer cache.deinit();
    try cache.replace("entry", &.{"private"});
    try tmp.dir.setFilePermissions(io, "ancestor/cache", .fromMode(0o100), .{});
    defer restoreTestPermissions(io, tmp.dir, "ancestor/cache");
    var reader = try PrivateDirectory.open(.init(io, tmp.dir), "ancestor/cache", .read_only);
    defer reader.deinit();
    const bytes = try reader.readAlloc(std.testing.allocator, "entry", 7);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("private", bytes);
    for ([_][]const u8{ "ancestor", "ancestor/cache" }) |path| {
        const stat = try tmp.dir.statFile(io, path, .{});
        try std.testing.expectEqual(@as(u32, 0o100), stat.permissions.toMode() & 0o777);
    }
}

test "private directory repair rejects symlinks without changing their targets" {
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cache = try PrivateDirectory.open(.init(io, tmp.dir), "cache", .create);
    defer cache.deinit();
    try cache.directory.createDir(io, "target", .fromMode(0o755));
    try cache.directory.symLink(io, "target", "alias", .{ .is_directory = true });
    try std.testing.expectError(error.NotDir, cache.openChild("alias", .create));
    const stat = try cache.directory.statFile(io, "target", .{});
    try std.testing.expectEqual(@as(u32, 0o755), stat.permissions.toMode() & 0o777);
}

test "private directory admission retains supplied cancellation and permission failures" {
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;
    const Failure = struct {
        fn cancel(_: ?*anyopaque) std.Io.Cancelable!void {
            return error.Canceled;
        }
        fn open(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir.OpenOptions,
        ) std.Io.Dir.OpenError!std.Io.Dir {
            return error.AccessDenied;
        }
        fn permissions(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.File.Permissions,
            _: std.Io.Dir.SetFilePermissionsOptions,
        ) std.Io.Dir.SetFilePermissionsError!void {
            return error.AccessDenied;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var vtable = io.vtable.*;
    vtable.checkCancel = Failure.cancel;
    const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try std.testing.expectError(
        error.Canceled,
        PrivateDirectory.open(.init(injected, tmp.dir), ".", .read_only),
    );
    vtable = io.vtable.*;
    vtable.dirOpenDir = Failure.open;
    try std.testing.expectError(
        error.AccessDenied,
        PrivateDirectory.open(.init(injected, tmp.dir), ".", .read_only),
    );
    vtable = io.vtable.*;
    vtable.dirSetFilePermissions = Failure.permissions;
    try tmp.dir.createDir(io, "cache", .fromMode(0o300));
    defer restoreTestPermissions(io, tmp.dir, "cache");
    try std.testing.expectError(
        error.AccessDenied,
        PrivateDirectory.open(.init(injected, tmp.dir), "cache", .create),
    );
    const stat = try tmp.dir.statFile(io, "cache", .{});
    try std.testing.expectEqual(@as(u32, 0o300), stat.permissions.toMode() & 0o777);
}

fn restoreTestPermissions(io: std.Io, dir: std.Io.Dir, path: []const u8) void {
    dir.setFilePermissions(io, path, .fromMode(0o700), .{}) catch |err|
        std.debug.panic("restore test directory permissions: {s}", .{@errorName(err)});
}
