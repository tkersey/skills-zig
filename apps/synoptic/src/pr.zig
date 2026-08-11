const std = @import("std");

pub const Identity = struct {
    host: []const u8 = "github.com",
    owner: []const u8,
    repository: []const u8,
    number: u64,
};

pub fn parseUrl(raw: []const u8) !Identity {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, raw, scheme)) return error.InvalidPullRequestSelector;
    const host_end = std.mem.indexOfScalarPos(u8, raw, scheme.len, '/') orelse
        return error.InvalidPullRequestSelector;
    const host = raw[scheme.len..host_end];
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '@') != null) {
        return error.InvalidPullRequestSelector;
    }
    const query = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
    if (query <= host_end) return error.InvalidPullRequestSelector;
    const canonical = std.mem.trimEnd(u8, raw[0..query], "/");
    var parts = std.mem.splitScalar(u8, canonical[host_end + 1 ..], '/');
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
    return .{ .host = host, .owner = owner, .repository = repo, .number = number };
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
test "enterprise PR URL retains its selected host" {
    const id = try parseUrl("https://github.example.test/o/r/pull/9");
    try std.testing.expectEqualStrings("github.example.test", id.host);
}
test "query before a complete authority and path is rejected" {
    try std.testing.expectError(
        error.InvalidPullRequestSelector,
        parseUrl("https://github.example?bad/o/r/pull/9"),
    );
}
