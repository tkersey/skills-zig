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
    const query = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
    const canonical = std.mem.trimEnd(u8, raw[0..query], "/");
    var parts = std.mem.splitScalar(u8, canonical[prefix.len..], '/');
    const owner = parts.next() orelse return error.InvalidPullRequestSelector;
    const repo = parts.next() orelse return error.InvalidPullRequestSelector;
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidPullRequestSelector, "pull"))
        return error.InvalidPullRequestSelector;
    const number = try std.fmt.parseInt(
        u64,
        parts.next() orelse return error.InvalidPullRequestSelector,
        10,
    );
    if (parts.next() != null) return error.InvalidPullRequestSelector;
    return .{ .owner = owner, .repository = repo, .number = number };
}

pub fn parseSelector(
    raw: []const u8,
    context_owner: ?[]const u8,
    context_repository: ?[]const u8,
) !Identity {
    if (std.mem.startsWith(u8, raw, "https://")) return parseUrl(raw);
    const number = std.fmt.parseInt(u64, raw, 10) catch return error.SelectorRequiresGhResolution;
    return .{
        .owner = context_owner orelse return error.RepositoryContextRequired,
        .repository = context_repository orelse return error.RepositoryContextRequired,
        .number = number,
    };
}

test "canonical PR URL" {
    const id = try parseUrl("https://github.com/o/r/pull/42");
    try std.testing.expectEqual(@as(u64, 42), id.number);
}

test "numeric selector uses repository context" {
    const id = try parseSelector("7", "o", "r");
    try std.testing.expectEqual(@as(u64, 7), id.number);
}
test "canonical URL accepts browser query and trailing slash" {
    const id = try parseUrl("https://github.com/o/r/pull/9/?tab=files");
    try std.testing.expectEqual(@as(u64, 9), id.number);
}
