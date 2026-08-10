const std = @import("std");

pub const snapshot_query =
    "query SynopticPullRequest($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){id number url title body baseRefName baseRefOid headRefName headRefOid files(first:100,after:$after){nodes{path additions deletions changeType viewerViewedState}pageInfo{hasNextPage endCursor}}}}}";
pub const mark_viewed_mutation =
    "mutation SynopticMarkFileViewed($input:MarkFileAsViewedInput!){markFileAsViewed(input:$input){pullRequest{id}}}";
pub const add_inline_comment_mutation =
    "mutation SynopticAddInlineComment($input:AddPullRequestReviewInput!){addPullRequestReview(input:$input){pullRequestReview{id url}}}";

pub fn requestAlloc(allocator: std.mem.Allocator, query: []const u8, variables_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, variables_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGraphqlVariables;
    var out: std.Io.Writer.Allocating = .init(allocator); errdefer out.deinit();
    try out.writer.writeAll("{\"query\":");
    try std.json.Stringify.value(query, .{}, &out.writer);
    try out.writer.writeAll(",\"variables\":");
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

test "GraphQL request owns document and variables" {
    const out = try requestAlloc(std.testing.allocator, "query X{viewer{login}}", "{}"); defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"variables\":{}") != null);
}
