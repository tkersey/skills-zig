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

pub fn isClean(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8) !bool {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "status", "--porcelain=v2", "--untracked-files=all" }, .cwd = .{ .path = cwd } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0 and result.stdout.len == 0;
}

pub fn select(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, head_oid: []const u8, managed_path: []const u8) !Custody {
    if (try isClean(io, allocator, cwd)) {
        const result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = .{ .path = cwd } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0 and std.mem.eql(u8, std.mem.trim(u8, result.stdout, "\r\n"), head_oid)) return .{ .reused_current = try allocator.dupe(u8, cwd) };
    }
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(managed_path) orelse return error.InvalidManagedWorktreePath);
    const fetch = try std.process.run(allocator, io, .{ .argv = &.{ "git", "fetch", "--no-tags", "origin", head_oid }, .cwd = .{ .path = cwd } });
    defer allocator.free(fetch.stdout);
    defer allocator.free(fetch.stderr);
    if (fetch.term != .exited or fetch.term.exited != 0) return error.ManagedWorktreeFetchFailed;
    const add = try std.process.run(allocator, io, .{ .argv = &.{ "git", "worktree", "add", "--detach", managed_path, head_oid }, .cwd = .{ .path = cwd } });
    defer allocator.free(add.stdout);
    defer allocator.free(add.stderr);
    if (add.term != .exited or add.term.exited != 0) return error.ManagedWorktreeCreationFailed;
    return .{ .managed = try allocator.dupe(u8, managed_path) };
}

pub fn cleanupAllowed(custody: Custody) bool {
    return custody == .managed;
}

/// Advances only a Synoptic-owned detached worktree. Reused user checkouts are
/// deliberately excluded from this mutation boundary.
pub fn synchronizeManaged(allocator: std.mem.Allocator, io: std.Io, custody: Custody, repository_cwd: []const u8, head_oid: []const u8) !void {
    if (custody != .managed) return error.ReusedCheckoutRefreshRequiresManagedMigration;
    const fetch = try std.process.run(allocator, io, .{ .argv = &.{ "git", "fetch", "--no-tags", "origin", head_oid }, .cwd = .{ .path = repository_cwd } });
    defer allocator.free(fetch.stdout);
    defer allocator.free(fetch.stderr);
    if (fetch.term != .exited or fetch.term.exited != 0) return error.ManagedWorktreeFetchFailed;
    const checkout = try std.process.run(allocator, io, .{ .argv = &.{ "git", "checkout", "--detach", head_oid }, .cwd = .{ .path = custody.path() } });
    defer allocator.free(checkout.stdout);
    defer allocator.free(checkout.stderr);
    if (checkout.term != .exited or checkout.term.exited != 0) return error.ManagedWorktreeRefreshFailed;
}

test "custody makes destructive policy explicit" {
    try std.testing.expectEqualStrings("managed", (Custody{ .managed = "/tmp/w" }).kind());
}
test "reused checkout can never be cleanup target" {
    try std.testing.expect(!cleanupAllowed(.{ .reused_current = "/user" }));
}
test "reused checkout can never be synchronized destructively" {
    try std.testing.expectError(error.ReusedCheckoutRefreshRequiresManagedMigration, synchronizeManaged(std.testing.allocator, std.testing.io, .{ .reused_current = "/user" }, "/repo", "head"));
}
