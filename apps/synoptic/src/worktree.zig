const std = @import("std");

pub const Custody = union(enum) {
    reused_current: []const u8,
    managed: []const u8,

    pub fn path(self: Custody) []const u8 { return switch (self) { inline else => |p| p }; }
    pub fn kind(self: Custody) []const u8 { return switch (self) { .reused_current => "reused-current", .managed => "managed" }; }
};

pub fn isClean(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8) !bool {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "status", "--porcelain=v2", "--untracked-files=all" }, .cwd = .{ .path = cwd } });
    defer allocator.free(result.stdout); defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0 and result.stdout.len == 0;
}

test "custody makes destructive policy explicit" {
    try std.testing.expectEqualStrings("managed", (Custody{ .managed = "/tmp/w" }).kind());
}
