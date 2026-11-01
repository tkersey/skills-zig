const std = @import("std");
const catalog = @import("host_catalog.zig");

pub const Associations = struct {
    arena: std.heap.ArenaAllocator,
    workspace_root: ?[]const u8,
    git_common_dir: ?[]const u8,
    aliases: []const []const u8,

    pub fn deinit(self: *Associations) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const GitPaths = struct {
    root: []const u8,
    common: []const u8,
};

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    workspace: ?[]const u8,
) !Associations {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const selected = workspace orelse return .{
        .arena = arena,
        .workspace_root = null,
        .git_common_dir = null,
        .aliases = &.{},
    };
    if (!std.fs.path.isAbsolute(selected)) return error.WorkspaceNotAbsolute;
    var root = try canonicalPath(owned, io, selected);
    var common: ?[]const u8 = null;
    if (try isDirectory(io, root)) {
        const paths = try gitOrPlain(owned, io, environment, root);
        if (paths) |found| {
            root = found.root;
            common = found.common;
        }
    }
    const aliases = try owned.alloc([]const u8, if (common != null) 2 else 1);
    aliases[0] = try std.fmt.allocPrint(owned, "workspace:{s}", .{root});
    if (common) |path| aliases[1] = try std.fmt.allocPrint(owned, "git-common-dir:{s}", .{path});
    return .{
        .arena = arena,
        .workspace_root = root,
        .git_common_dir = common,
        .aliases = aliases,
    };
}

pub fn gitOrPlain(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    root: []const u8,
) !?GitPaths {
    return verifiedGit(allocator, io, environment, root) catch |err| switch (err) {
        error.GitContextUnavailable, error.FileNotFound, error.NotDir => blk: {
            var ancestor: ?[]const u8 = root;
            while (ancestor) |path| {
                const dir = try catalog.openDirectory(io, path, false);
                defer dir.close(io);
                const bare = try catalog.existsAt(io, dir, "objects") and
                    (try catalog.existsAt(io, dir, "HEAD") or
                        (try catalog.existsAt(io, dir, "config") and
                            try catalog.existsAt(io, dir, "refs")));
                if (try catalog.existsAt(io, dir, ".git") or bare)
                    return error.UnverifiableGitFamily;
                ancestor = std.fs.path.dirname(path);
                if (ancestor != null and std.mem.eql(u8, ancestor.?, path)) break;
            }
            if (git(allocator, io, environment, root, &.{ "rev-parse", "--git-dir" })) |bytes| {
                allocator.free(bytes);
                return error.UnverifiableGitFamily;
            } else |probe_error| switch (probe_error) {
                error.GitContextUnavailable, error.FileNotFound, error.NotDir => {},
                else => return probe_error,
            }
            break :blk null;
        },
        else => return err,
    };
}

pub fn git(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    root: []const u8,
    arguments: []const []const u8,
) ![]u8 {
    var sanitized = try environment.clone(allocator);
    defer sanitized.deinit();
    for ([_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE" }) |key| {
        _ = sanitized.swapRemove(key);
    }
    const argv = try allocator.alloc([]const u8, arguments.len + 3);
    defer allocator.free(argv);
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = root;
    @memcpy(argv[3..], arguments);
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = &sanitized,
        .stdout_limit = .limited(1048576),
        .stderr_limit = .limited(65536),
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.GitContextUnavailable;
    return result.stdout;
}

pub fn verifiedGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    path: []const u8,
) !GitPaths {
    const inside = try git(
        allocator,
        io,
        environment,
        path,
        &.{ "rev-parse", "--is-inside-work-tree" },
    );
    defer allocator.free(inside);
    if (!std.mem.eql(u8, std.mem.trim(u8, inside, "\r\n"), "true"))
        return error.GitContextUnavailable;
    const raw_root = try git(
        allocator,
        io,
        environment,
        path,
        &.{ "rev-parse", "--show-toplevel" },
    );
    defer allocator.free(raw_root);
    const canonical_root = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        std.mem.trimEnd(u8, raw_root, "\n"),
        allocator,
    );
    defer allocator.free(canonical_root);
    const root = try allocator.dupe(u8, canonical_root);
    errdefer allocator.free(root);
    const raw_common = try git(
        allocator,
        io,
        environment,
        root,
        &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" },
    );
    defer allocator.free(raw_common);
    const canonical_common = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        std.mem.trimEnd(u8, raw_common, "\n"),
        allocator,
    );
    defer allocator.free(canonical_common);
    const common = try allocator.dupe(u8, canonical_common);
    return .{ .root = root, .common = common };
}

pub fn worktrees(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    root: []const u8,
) ![]const []const u8 {
    const output = try git(
        allocator,
        io,
        environment,
        root,
        &.{ "worktree", "list", "--porcelain", "-z" },
    );
    defer allocator.free(output);
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |path| allocator.free(path);
        result.deinit(allocator);
    }
    var fields = std.mem.splitScalar(u8, output, 0);
    while (fields.next()) |field| {
        if (!std.mem.startsWith(u8, field, "worktree ")) continue;
        const path = field["worktree ".len..];
        if (!try isDirectory(io, path)) return error.UnavailableWorktree;
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
        defer allocator.free(canonical);
        const owned = try allocator.dupe(u8, canonical);
        errdefer allocator.free(owned);
        try result.append(allocator, owned);
    }
    return result.toOwnedSlice(allocator);
}

pub fn freeWorktrees(allocator: std.mem.Allocator, trees: []const []const u8) void {
    for (trees) |tree| allocator.free(tree);
    allocator.free(trees);
}

pub fn canonicalPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return error.WorkspaceNotAbsolute;
    const normalized = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(normalized);
    var end = normalized.len;
    for (0..4096) |_| {
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(
            io,
            normalized[0..end],
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                if (end <= 1) return err;
                end = (std.fs.path.dirname(normalized[0..end]) orelse return err).len;
                continue;
            },
            else => return err,
        };
        defer allocator.free(canonical);
        return std.fs.path.join(
            allocator,
            &.{ canonical, std.mem.trimStart(u8, normalized[end..], "/") },
        );
    }
    return error.PathDepthExceeded;
}

pub fn isDirectory(io: std.Io, path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return stat.kind == .directory;
}

pub fn hasLegacyHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    legacy_paths: []const []const u8,
) !bool {
    for (legacy_paths) |relative| {
        if (relative.len == 0 or std.fs.path.isAbsolute(relative)) return error.InvalidLegacyPath;
        var parts = std.fs.path.componentIterator(relative);
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part.name, "..")) return error.InvalidLegacyPath;
        }
        const retired = try std.fs.path.join(allocator, &.{ root, relative });
        defer allocator.free(retired);
        if (try catalog.exists(io, retired)) return error.RetiredSourceRequiresRecovery;
    }
    const path = try std.fs.path.join(allocator, &.{ root, ".ledger" });
    defer allocator.free(path);
    if (!try catalog.exists(io, path)) return false;
    const dir = try catalog.openDirectory(io, path, false);
    defer dir.close(io);
    var entries = dir.iterate();
    return try entries.next(io) != null;
}

test "plain and missing workspace resolution do not create custody" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const missing = try std.fs.path.join(allocator, &.{ root, "missing" });
    defer allocator.free(missing);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var selected = try resolve(allocator, io, &environment, missing);
    defer selected.deinit();
    try std.testing.expectEqualStrings(missing, selected.workspace_root.?);
    try std.testing.expect(selected.git_common_dir == null);
    try std.testing.expect(!try catalog.exists(io, missing));
}

pub fn testPlainDirectory() !std.testing.TmpDir {
    const io = std.testing.io;
    const parent = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    errdefer parent.close(io);
    var random: [12]u8 = undefined;
    io.random(&random);
    var name: @FieldType(std.testing.TmpDir, "sub_path") = undefined;
    _ = std.base64.url_safe.Encoder.encode(&name, &random);
    try parent.createDir(io, &name, .fromMode(0o700));
    errdefer parent.deleteTree(io, &name) catch |err| @panic(@errorName(err));
    const dir = try parent.openDir(io, &name, .{});
    return .{ .dir = dir, .parent_dir = parent, .sub_path = name };
}

test "plain admission with missing Git rejects broken nested and bare Git evidence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try testPlainDirectory();
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/nonexistent-ledger-git");
    var plain = try resolve(allocator, io, &environment, root);
    defer plain.deinit();
    try std.testing.expect(plain.git_common_dir == null);
    try tmp.dir.createDir(io, "nested", .default_dir);
    const nested = try std.fs.path.join(allocator, &.{ root, "nested" });
    defer allocator.free(nested);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: /missing\n" });
    try std.testing.expectError(error.UnverifiableGitFamily, resolve(
        allocator,
        io,
        &environment,
        nested,
    ));
    try tmp.dir.deleteFile(io, ".git");
    try tmp.dir.createDir(io, "objects", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
    try std.testing.expectError(error.UnverifiableGitFamily, resolve(
        allocator,
        io,
        &environment,
        root,
    ));
}
