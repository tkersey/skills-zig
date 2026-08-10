const std = @import("std");

pub const Custody = union(enum) {
    reused_current: []const u8,
    managed: []const u8,

    pub fn path(self: Custody) []const u8 {
        return switch (self) {
            inline else => |p| p,
        };
    }
    pub fn kind(self: Custody) []const u8 {
        return switch (self) {
            .reused_current => "reused-current",
            .managed => "managed",
        };
    }
};

pub const Baseline = struct {
    allocator: std.mem.Allocator,
    head_oid: []u8,
    branch: ?[]u8,
    porcelain_v2: []u8,
    tracked_digest: [32]u8,
    artifacts: std.ArrayList([]u8) = .empty,

    pub fn capture(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !Baseline {
        const head = try gitOutput(allocator, io, cwd, &.{ "git", "rev-parse", "HEAD" }, error.WorktreeHeadReadFailed);
        defer allocator.free(head);
        const branch_result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "branch", "--show-current" }, .cwd = .{ .path = cwd } });
        defer allocator.free(branch_result.stdout);
        defer allocator.free(branch_result.stderr);
        if (branch_result.term != .exited or branch_result.term.exited != 0) return error.WorktreeBranchReadFailed;
        const branch_text = std.mem.trim(u8, branch_result.stdout, "\r\n");
        const porcelain = try statusAlloc(allocator, io, cwd);
        errdefer allocator.free(porcelain);
        var baseline = Baseline{ .allocator = allocator, .head_oid = try allocator.dupe(u8, std.mem.trim(u8, head, "\r\n")), .branch = if (branch_text.len == 0) null else try allocator.dupe(u8, branch_text), .porcelain_v2 = porcelain, .tracked_digest = try trackedDigest(allocator, io, cwd) };
        errdefer baseline.deinit();
        try listArtifacts(allocator, io, cwd, &baseline.artifacts);
        return baseline;
    }

    pub fn deinit(self: *Baseline) void {
        self.allocator.free(self.head_oid);
        if (self.branch) |value| self.allocator.free(value);
        self.allocator.free(self.porcelain_v2);
        for (self.artifacts.items) |path| self.allocator.free(path);
        self.artifacts.deinit(self.allocator);
    }

    fn replace(self: *Baseline, next: Baseline) void {
        self.deinit();
        self.* = next;
    }
};

pub fn isClean(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8) !bool {
    const status = try statusAlloc(allocator, io, cwd);
    defer allocator.free(status);
    return status.len == 0;
}

pub fn select(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, head_ref: []const u8, head_oid: []const u8, managed_path: []const u8) !Custody {
    if (try isClean(io, allocator, cwd)) {
        const head = try gitOutput(allocator, io, cwd, &.{ "git", "rev-parse", "HEAD" }, error.WorktreeHeadReadFailed);
        defer allocator.free(head);
        const branch = try gitOutput(allocator, io, cwd, &.{ "git", "branch", "--show-current" }, error.WorktreeBranchReadFailed);
        defer allocator.free(branch);
        if (std.mem.eql(u8, std.mem.trim(u8, head, "\r\n"), head_oid) and std.mem.eql(u8, std.mem.trim(u8, branch, "\r\n"), head_ref)) return .{ .reused_current = try allocator.dupe(u8, cwd) };
    }
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(managed_path) orelse return error.InvalidManagedWorktreePath);
    try fetch(allocator, io, cwd, head_oid);
    const add = try std.process.run(allocator, io, .{ .argv = &.{ "git", "worktree", "add", "--detach", managed_path, head_oid }, .cwd = .{ .path = cwd } });
    defer allocator.free(add.stdout);
    defer allocator.free(add.stderr);
    if (add.term != .exited or add.term.exited != 0) return error.ManagedWorktreeCreationFailed;
    return .{ .managed = try allocator.dupe(u8, managed_path) };
}

pub fn cleanupAllowed(custody: Custody) bool {
    return custody == .managed;
}
pub fn requireManagedRefresh(custody: Custody) !void {
    if (custody != .managed) return error.ReusedCheckoutRefreshRequiresManagedMigration;
}

pub fn synchronize(allocator: std.mem.Allocator, io: std.Io, custody: Custody, repository_cwd: []const u8, next_head: []const u8, baseline: *Baseline) !void {
    switch (custody) {
        .managed => try synchronizeManaged(allocator, io, custody, repository_cwd, next_head, baseline),
        .reused_current => try synchronizeReused(allocator, io, custody.path(), next_head, baseline),
    }
}

pub fn reconcileShutdown(allocator: std.mem.Allocator, io: std.Io, custody: Custody, selected_head: []const u8, baseline: *Baseline) !void {
    switch (custody) {
        .managed => try cleanManaged(allocator, io, custody.path(), selected_head, baseline),
        .reused_current => try requireReusedUnchanged(allocator, io, custody.path(), baseline),
    }
}

pub fn synchronizeManaged(allocator: std.mem.Allocator, io: std.Io, custody: Custody, repository_cwd: []const u8, head_oid: []const u8, baseline: *Baseline) !void {
    try requireManagedRefresh(custody);
    try cleanManaged(allocator, io, custody.path(), baseline.head_oid, baseline);
    try fetch(allocator, io, repository_cwd, head_oid);
    const checkout = try std.process.run(allocator, io, .{ .argv = &.{ "git", "checkout", "--detach", head_oid }, .cwd = .{ .path = custody.path() } });
    defer allocator.free(checkout.stdout);
    defer allocator.free(checkout.stderr);
    if (checkout.term != .exited or checkout.term.exited != 0) return error.ManagedWorktreeRefreshFailed;
    const next = try Baseline.capture(allocator, io, custody.path());
    baseline.replace(next);
}

fn synchronizeReused(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, next_head: []const u8, baseline: *Baseline) !void {
    try requireReusedUnchanged(allocator, io, cwd, baseline);
    const branch = baseline.branch orelse return error.ReusedCheckoutRefreshRequiresManagedMigration;
    const current_branch = try gitOutput(allocator, io, cwd, &.{ "git", "branch", "--show-current" }, error.WorktreeBranchReadFailed);
    defer allocator.free(current_branch);
    if (!std.mem.eql(u8, std.mem.trim(u8, current_branch, "\r\n"), branch)) return error.ReusedCheckoutRefreshRequiresManagedMigration;
    try fetch(allocator, io, cwd, next_head);
    const ancestor = try std.process.run(allocator, io, .{ .argv = &.{ "git", "merge-base", "--is-ancestor", baseline.head_oid, next_head }, .cwd = .{ .path = cwd } });
    defer allocator.free(ancestor.stdout);
    defer allocator.free(ancestor.stderr);
    if (ancestor.term != .exited or ancestor.term.exited != 0) return error.ReusedCheckoutRefreshRequiresManagedMigration;
    const merge = try std.process.run(allocator, io, .{ .argv = &.{ "git", "merge", "--ff-only", next_head }, .cwd = .{ .path = cwd } });
    defer allocator.free(merge.stdout);
    defer allocator.free(merge.stderr);
    if (merge.term != .exited or merge.term.exited != 0) return error.ReusedCheckoutFastForwardFailed;
    const next = try Baseline.capture(allocator, io, cwd);
    if (!std.mem.eql(u8, next.head_oid, next_head) or next.porcelain_v2.len != 0) {
        var invalid = next;
        invalid.deinit();
        return error.ReusedCheckoutRefreshRequiresManagedMigration;
    }
    baseline.replace(next);
}

fn requireReusedUnchanged(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, baseline: *const Baseline) !void {
    const head = try gitOutput(allocator, io, cwd, &.{ "git", "rev-parse", "HEAD" }, error.WorktreeHeadReadFailed);
    defer allocator.free(head);
    const status = try statusAlloc(allocator, io, cwd);
    defer allocator.free(status);
    const digest = try trackedDigest(allocator, io, cwd);
    var artifacts: std.ArrayList([]u8) = .empty;
    defer {
        for (artifacts.items) |path| allocator.free(path);
        artifacts.deinit(allocator);
    }
    try listArtifacts(allocator, io, cwd, &artifacts);
    if (!std.mem.eql(u8, std.mem.trim(u8, head, "\r\n"), baseline.head_oid) or !std.mem.eql(u8, status, baseline.porcelain_v2) or !std.mem.eql(u8, &digest, &baseline.tracked_digest) or !samePaths(artifacts.items, baseline.artifacts.items)) return error.ReusedCheckoutRefreshRequiresManagedMigration;
}

fn cleanManaged(allocator: std.mem.Allocator, io: std.Io, root: []const u8, selected_head: []const u8, baseline: *const Baseline) !void {
    const restore = try std.process.run(allocator, io, .{ .argv = &.{ "git", "restore", "--source", selected_head, "--staged", "--worktree", "--", "." }, .cwd = .{ .path = root } });
    defer allocator.free(restore.stdout);
    defer allocator.free(restore.stderr);
    if (restore.term != .exited or restore.term.exited != 0) return error.ManagedTrackedCleanupFailed;
    const status = try statusAlloc(allocator, io, root);
    defer allocator.free(status);
    var current: std.ArrayList([]u8) = .empty;
    defer {
        for (current.items) |path| allocator.free(path);
        current.deinit(allocator);
    }
    try listArtifacts(allocator, io, root, &current);
    for (current.items) |relative| {
        if (containsPath(baseline.artifacts.items, relative)) continue;
        try deleteConfined(io, root, relative);
    }
    const final_status = try statusAlloc(allocator, io, root);
    defer allocator.free(final_status);
    var final_artifacts: std.ArrayList([]u8) = .empty;
    defer {
        for (final_artifacts.items) |path| allocator.free(path);
        final_artifacts.deinit(allocator);
    }
    try listArtifacts(allocator, io, root, &final_artifacts);
    const final_head = try gitOutput(allocator, io, root, &.{ "git", "rev-parse", "HEAD" }, error.WorktreeHeadReadFailed);
    defer allocator.free(final_head);
    const final_digest = try trackedDigest(allocator, io, root);
    if (!std.mem.eql(u8, std.mem.trim(u8, final_head, "\r\n"), selected_head) or !std.mem.eql(u8, &final_digest, &baseline.tracked_digest) or !std.mem.eql(u8, final_status, baseline.porcelain_v2) or !samePaths(final_artifacts.items, baseline.artifacts.items)) return error.ManagedWorktreeCleanupIncomplete;
}

fn statusAlloc(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]u8 {
    return gitOutput(allocator, io, cwd, &.{ "git", "status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignore-submodules=none" }, error.WorktreeStatusFailed);
}

fn trackedDigest(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![32]u8 {
    const identity = try gitOutput(allocator, io, cwd, &.{ "git", "ls-files", "-s", "-z" }, error.WorktreeDigestFailed);
    defer allocator.free(identity);
    const diff = try gitOutput(allocator, io, cwd, &.{ "git", "diff", "--no-ext-diff", "--binary", "HEAD", "--" }, error.WorktreeDigestFailed);
    defer allocator.free(diff);
    const cached = try gitOutput(allocator, io, cwd, &.{ "git", "diff", "--cached", "--no-ext-diff", "--binary", "HEAD", "--" }, error.WorktreeDigestFailed);
    defer allocator.free(cached);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(identity);
    hash.update(&.{0});
    hash.update(diff);
    hash.update(&.{0});
    hash.update(cached);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn listArtifacts(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, output: *std.ArrayList([]u8)) !void {
    const ordinary = try gitOutput(allocator, io, cwd, &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" }, error.WorktreeStatusFailed);
    defer allocator.free(ordinary);
    const ignored = try gitOutput(allocator, io, cwd, &.{ "git", "ls-files", "--others", "--ignored", "--exclude-standard", "-z" }, error.WorktreeStatusFailed);
    defer allocator.free(ignored);
    for ([_][]const u8{ ordinary, ignored }) |raw| {
        var paths = std.mem.splitScalar(u8, raw, 0);
        while (paths.next()) |path| if (path.len > 0) try output.append(allocator, try allocator.dupe(u8, path));
    }
}

fn containsPath(paths: []const []u8, needle: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, needle)) return true;
    return false;
}
fn samePaths(a: []const []u8, b: []const []u8) bool {
    if (a.len != b.len) return false;
    for (a) |path| if (!containsPath(b, path)) return false;
    return true;
}

fn deleteConfined(io: std.Io, root: []const u8, relative: []const u8) !void {
    if (relative.len == 0 or std.fs.path.isAbsolute(relative)) return error.UnsafeManagedArtifactPath;
    var parts = std.mem.splitScalar(u8, relative, std.fs.path.sep);
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..")) return error.UnsafeManagedArtifactPath;
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer dir.close(io);
    dir.deleteFile(io, relative) catch |err| switch (err) {
        error.IsDir => try dir.deleteTree(io, relative),
        error.FileNotFound => {},
        else => return err,
    };
    var parent = std.fs.path.dirname(relative);
    while (parent) |value| {
        if (value.len == 0 or std.mem.eql(u8, value, ".")) break;
        dir.deleteDir(io, value) catch |err| switch (err) {
            error.DirNotEmpty, error.FileNotFound => break,
            else => return err,
        };
        parent = std.fs.path.dirname(value);
    }
}

fn fetch(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, head_oid: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "fetch", "--no-tags", "origin", head_oid }, .cwd = .{ .path = cwd } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.ManagedWorktreeFetchFailed;
}

fn gitOutput(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8, failure: anyerror) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return failure;
    }
    return result.stdout;
}

test "custody makes destructive policy explicit" {
    try std.testing.expectEqualStrings("managed", (Custody{ .managed = "/tmp/w" }).kind());
}
test "reused checkout can never be cleanup target" {
    try std.testing.expect(!cleanupAllowed(.{ .reused_current = "/user" }));
}
