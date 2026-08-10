const std = @import("std");

pub const Identity = struct {
    host: []const u8 = "github.com",
    owner: []const u8,
    repository: []const u8,
    number: u64,
};

pub fn parseUrl(raw: []const u8) !Identity {
    const prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, raw, prefix)) return error.InvalidPullRequestSelector;
    var parts = std.mem.splitScalar(u8, raw[prefix.len..], '/');
    const owner = parts.next() orelse return error.InvalidPullRequestSelector;
    const repo = parts.next() orelse return error.InvalidPullRequestSelector;
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidPullRequestSelector, "pull")) return error.InvalidPullRequestSelector;
    const number = try std.fmt.parseInt(u64, parts.next() orelse return error.InvalidPullRequestSelector, 10);
    if (parts.next() != null) return error.InvalidPullRequestSelector;
    return .{ .owner = owner, .repository = repo, .number = number };
}

test "canonical PR URL" {
    const id = try parseUrl("https://github.com/o/r/pull/42");
    try std.testing.expectEqual(@as(u64, 42), id.number);
}
