const std = @import("std");

pub const snapshot_query =
    "query SynopticPullRequest($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){id number url title body baseRefName baseRefOid headRefName headRefOid files(first:100,after:$after){nodes{path additions deletions changeType viewerViewedState}pageInfo{hasNextPage endCursor}}}}}";
pub const threads_query =
    "query SynopticReviewThreads($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$after){nodes{id path line isResolved isOutdated}pageInfo{hasNextPage endCursor}}}}}";
pub const file_state_query =
    "query SynopticFileState($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid files(first:100,after:$after){nodes{path viewerViewedState}pageInfo{hasNextPage endCursor}}}}}";
pub const anchor_query =
    "query SynopticAnchor($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid files(first:100,after:$after){nodes{path}pageInfo{hasNextPage endCursor}}}}}";
pub const mark_viewed_mutation =
    "mutation SynopticMarkFileViewed($input:MarkFileAsViewedInput!){markFileAsViewed(input:$input){pullRequest{id}}}";
pub const add_inline_comment_mutation =
    "mutation SynopticAddInlineComment($input:AddPullRequestReviewInput!){addPullRequestReview(input:$input){pullRequestReview{id url}}}";

pub fn operationName(document: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, document, '(') orelse return null;
    const prefix = std.mem.trim(u8, document[0..open], " \t\r\n");
    const space = std.mem.lastIndexOfScalar(u8, prefix, ' ') orelse return null;
    return prefix[space + 1 ..];
}

pub fn requestAlloc(allocator: std.mem.Allocator, query: []const u8, variables_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, variables_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGraphqlVariables;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"query\":");
    try std.json.Stringify.value(query, .{}, &out.writer);
    try out.writer.writeAll(",\"variables\":");
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn pageCursor(allocator: std.mem.Allocator, raw: []const u8, connection: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const pr_value = (((parsed.value.object.get("data") orelse return error.InvalidGraphqlResponse).object.get("repository") orelse return error.InvalidGraphqlResponse).object.get("pullRequest") orelse return error.InvalidGraphqlResponse);
    const conn = pr_value.object.get(connection) orelse return error.InvalidGraphqlResponse;
    const info = conn.object.get("pageInfo") orelse return error.InvalidGraphqlResponse;
    if (!(info.object.get("hasNextPage") orelse return error.InvalidGraphqlResponse).bool) return null;
    return @as(?[]u8, try allocator.dupe(u8, (info.object.get("endCursor") orelse return error.InvalidGraphqlResponse).string));
}

test "GraphQL request owns document and variables" {
    const out = try requestAlloc(std.testing.allocator, "query X{viewer{login}}", "{}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"variables\":{}") != null);
}

test "operation identity remains inspectable in fake gh stdin" {
    try std.testing.expectEqualStrings("SynopticMarkFileViewed", operationName(mark_viewed_mutation).?);
}
