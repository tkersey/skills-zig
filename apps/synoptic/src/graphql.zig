const std = @import("std");

pub const snapshot_query =
    "query SynopticPullRequest($owner:String!,$name:String!,$number:Int!,$after:String){" ++
    "repository(owner:$owner,name:$name){pullRequest(number:$number){id number url title body " ++
    "state isDraft baseRefName baseRefOid headRefName headRefOid files(first:100,after:$after){" ++
    "nodes{path additions deletions changeType viewerViewedState}" ++
    "pageInfo{hasNextPage endCursor}}}}}";
pub const threads_query =
    "query SynopticReviewThreads($owner:String!,$name:String!,$number:Int!,$after:String){" ++
    "repository(owner:$owner,name:$name){pullRequest(number:$number){baseRefOid headRefOid " ++
    "reviewThreads(first:100,after:$after){nodes{id path line startLine diffSide startDiffSide " ++
    "subjectType isResolved isOutdated viewerCanReply viewerCanResolve viewerCanUnresolve " ++
    "comments(first:1){nodes{id body createdAt url author{login} viewerDidAuthor " ++
    "pullRequestReview{id state}}pageInfo{hasNextPage endCursor}}}" ++
    "pageInfo{hasNextPage endCursor}}}}}";
pub const thread_comments_query =
    "query SynopticThreadComments($owner:String!,$name:String!,$number:Int!," ++
    "$threadId:ID!,$after:String){repository(owner:$owner,name:$name){" ++
    "pullRequest(number:$number){baseRefOid headRefOid}}node(id:$threadId){" ++
    "... on PullRequestReviewThread{id path line startLine diffSide startDiffSide subjectType " ++
    "isResolved isOutdated viewerCanReply viewerCanResolve viewerCanUnresolve " ++
    "comments(first:100,after:$after){nodes{id body createdAt url author{login} " ++
    "viewerDidAuthor pullRequestReview{id state}}pageInfo{hasNextPage endCursor}}}}}";
pub const file_state_query =
    "query SynopticFileState($owner:String!,$name:String!,$" ++
    "number:Int!,$after:String){repository(owner:$owner,nam" ++
    "e:$name){pullRequest(number:$number){baseRefOid headRefOid files(" ++
    "first:100,after:$after){nodes{path viewerViewedState}p" ++
    "ageInfo{hasNextPage endCursor}}}}}";
pub const anchor_query =
    "query SynopticAnchor($owner:String!,$name:String!,$num" ++
    "ber:Int!,$after:String){repository(owner:$owner,name:$" ++
    "name){pullRequest(number:$number){baseRefOid headRefOid files(fir" ++
    "st:100,after:$after){nodes{path}pageInfo{hasNextPage e" ++
    "ndCursor}}}}}";
pub const mark_viewed_mutation =
    "mutation SynopticMarkFileViewed($input:MarkFileAsViewe" ++
    "dInput!){markFileAsViewed(input:$input){pullRequest{id" ++
    "}}}";

pub fn markViewedBatchMutationAlloc(
    allocator: std.mem.Allocator,
    count: usize,
) ![]u8 {
    if (count == 0) return error.EmptyGraphqlBatch;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("mutation SynopticMarkFileViewedBatch(");
    for (0..count) |index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.print("$input{d}:MarkFileAsViewedInput!", .{index});
    }
    try out.writer.writeAll("){");
    for (0..count) |index| {
        try out.writer.print(
            "file{d}:markFileAsViewed(input:$input{d}){{pullRequest{{id}}}}",
            .{ index, index },
        );
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}
pub const add_inline_comment_mutation =
    "mutation SynopticAddInlineComment($input:AddPullReques" ++
    "tReviewInput!){addPullRequestReview(input:$input){pull" ++
    "RequestReview{id url}}}";
pub const reply_thread_mutation =
    "mutation SynopticReply($input:AddPullRequestReviewThre" ++
    "adReplyInput!){addPullRequestReviewThreadReply(input:$" ++
    "input){comment{id body url}}}";
pub const resolve_thread_mutation =
    "mutation SynopticResolveThread($input:ResolveReviewThr" ++
    "eadInput!){resolveReviewThread(input:$input){thread{id" ++
    " isResolved}}}";
pub const unresolve_thread_mutation =
    "mutation SynopticUnresolveThread($input:UnresolveRevie" ++
    "wThreadInput!){unresolveReviewThread(input:$input){thr" ++
    "ead{id isResolved}}}";
pub const update_comment_mutation =
    "mutation SynopticUpdateComment($input:UpdatePullReques" ++
    "tReviewCommentInput!){updatePullRequestReviewComment(i" ++
    "nput:$input){pullRequestReviewComment{id body url}}}";
pub const delete_comment_mutation =
    "mutation SynopticDeleteComment($input:DeletePullReques" ++
    "tReviewCommentInput!){deletePullRequestReviewComment(i" ++
    "nput:$input){clientMutationId}}";
pub const unmark_viewed_mutation =
    "mutation SynopticUnmarkFileViewed($input:UnmarkFileAsV" ++
    "iewedInput!){unmarkFileAsViewed(input:$input){pullRequ" ++
    "est{id}}}";
pub const action_authority_query =
    "query SynopticActionAuthority($owner:String!,$name:String!,$number:Int!,$after:String){" ++
    "repository(owner:$owner,name:$name){pullRequest(number:$number){baseRefOid headRefOid " ++
    "reviewThreads(first:100,after:$after){nodes{id path viewerCanReply viewerCanResolve " ++
    "viewerCanUnresolve comments(first:1){nodes{id body viewerDidAuthor}" ++
    "pageInfo{hasNextPage endCursor}}}pageInfo{hasNextPage endCursor}}}}}";
pub const reconcile_query =
    "query SynopticReconcile($owner:String!,$name:String!,$number:Int!,$after:String){" ++
    "repository(owner:$owner,name:$name){pullRequest(number:$number){baseRefOid headRefOid " ++
    "reviewThreads(first:100,after:$after){nodes{id path line startLine diffSide startDiffSide " ++
    "isResolved comments(first:1){" ++
    "nodes{id body createdAt viewerDidAuthor}pageInfo{hasNextPage endCursor}}}" ++
    "pageInfo{hasNextPage endCursor}}}}}";

pub const TransparentLimits = struct {
    pub const document_bytes: usize = 32 * 1024;
    pub const variables_bytes: usize = 64 * 1024;
};

/// Transparent mutations deliberately remain GraphQL rather than becoming a
/// second browser API. This small validator owns the authority boundary: one
/// named mutation, one unaliased root effect, and no syntax that can obscure
/// the effect shown on the immutable card.
pub fn validateTransparent(
    document: []const u8,
    expected_operation: []const u8,
    variables_json: []const u8,
    pull_request_id: []const u8,
) !void {
    return validateTransparentWithHead(
        document,
        expected_operation,
        variables_json,
        pull_request_id,
        null,
    );
}

pub fn validateTransparentAtHead(
    document: []const u8,
    expected_operation: []const u8,
    variables_json: []const u8,
    pull_request_id: []const u8,
    expected_head_oid: []const u8,
) !void {
    return validateTransparentWithHead(
        document,
        expected_operation,
        variables_json,
        pull_request_id,
        expected_head_oid,
    );
}

fn validateTransparentWithHead(
    document: []const u8,
    expected_operation: []const u8,
    variables_json: []const u8,
    pull_request_id: []const u8,
    expected_head_oid: ?[]const u8,
) !void {
    if (document.len == 0 or document.len > TransparentLimits.document_bytes or
        variables_json.len > TransparentLimits.variables_bytes) return error.GraphqlActionTooLarge;
    if (!validName(expected_operation)) return error.InvalidGraphqlOperationName;
    const obscured = std.mem.indexOf(u8, document, "...") != null or
        std.mem.indexOfScalar(u8, document, '@') != null;
    if (obscured) return error.GraphqlSyntaxForbidden;

    var tokens = try tokenize(std.heap.page_allocator, document);
    defer tokens.deinit(std.heap.page_allocator);
    if (tokens.items.len < 4 or !std.mem.eql(u8, tokens.items[0].text, "mutation") or
        !std.mem.eql(
            u8,
            tokens.items[1].text,
            expected_operation,
        )) return error.InvalidGraphqlOperationName;
    for (tokens.items) |token| {
        if (token.kind == .name and std.mem.eql(u8, token.text, "fragment")) {
            return error.GraphqlSyntaxForbidden;
        }
    }
    const root = try validateTokenShape(tokens.items);
    var variables = try std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        variables_json,
        .{ .max_value_len = TransparentLimits.variables_bytes },
    );
    defer variables.deinit();
    if (variables.value != .object) return error.InvalidGraphqlVariables;
    const input = variables.value.object.get(root.input_variable) orelse
        return error.InvalidGraphqlVariables;
    var saw_target = false;
    try validateVariables(input, pull_request_id, &saw_target);
    if (!saw_target) return error.GraphqlPullRequestTargetMissing;
    if (transparentMutationRequiresHead(root.field)) {
        if (input != .object) return error.InvalidGraphqlVariables;
        const head = input.object.get("expectedHeadOid") orelse
            return error.GraphqlExpectedHeadMissing;
        if (head != .string or head.string.len == 0) return error.GraphqlExpectedHeadMissing;
        if (expected_head_oid) |expected| if (!std.mem.eql(u8, head.string, expected))
            return error.GraphqlExpectedHeadMismatch;
    }
}

fn transparentMutationRequiresHead(field: []const u8) bool {
    return std.mem.eql(u8, field, "mergePullRequest") or
        std.mem.eql(u8, field, "updatePullRequestBranch");
}

const TransparentRoot = struct {
    field: []const u8,
    input_variable: []const u8,
};

fn validateTokenShape(tokens: []const Token) !TransparentRoot {
    var selection: ?usize = null;
    var parens: usize = 0;
    for (tokens[2..], 2..) |token, index| switch (token.kind) {
        .l_paren => parens += 1,
        .r_paren => {
            if (parens == 0) return error.InvalidGraphqlDocument;
            parens -= 1;
        },
        .l_brace => if (parens == 0) {
            selection = index;
            break;
        },
        else => {},
    };
    const start = selection orelse return error.InvalidGraphqlDocument;
    if (containsSelectionAlias(tokens, start)) return error.GraphqlAliasForbidden;
    var depth: usize = 0;
    var root_count: usize = 0;
    var root_index: ?usize = null;
    var index = start;
    while (index < tokens.len) : (index += 1) {
        const token = tokens[index];
        switch (token.kind) {
            .l_brace => depth += 1,
            .r_brace => {
                if (depth == 0) return error.InvalidGraphqlDocument;
                depth -= 1;
                if (depth == 0) {
                    if (index + 1 != tokens.len) return error.InvalidGraphqlDocument;
                    break;
                }
            },
            .name => if (depth == 1) {
                // At selection depth one, a name preceded by a completed root
                // selection is another root. A colon immediately following is
                // an alias and is forbidden.
                if (index + 1 < tokens.len and tokens[index + 1].kind == .colon)
                    return error.GraphqlAliasForbidden;
                root_count += 1;
                root_index = index;
                index = skipSelection(tokens, index + 1) catch return error.InvalidGraphqlDocument;
                if (index > 0) index -= 1;
            },
            else => {},
        }
    }
    if (depth != 0 or root_count != 1) return error.GraphqlRootCountInvalid;
    const root = root_index orelse return error.GraphqlRootCountInvalid;
    return .{
        .field = tokens[root].text,
        .input_variable = try rootInputVariable(tokens, root),
    };
}

fn rootInputVariable(tokens: []const Token, root: usize) ![]const u8 {
    var index = root + 1;
    if (index >= tokens.len or tokens[index].kind != .l_paren) {
        return error.GraphqlPullRequestTargetMissing;
    }
    index += 1;
    while (index + 3 < tokens.len and tokens[index].kind != .r_paren) : (index += 1) {
        if (tokens[index].kind != .name or
            !std.mem.eql(u8, tokens[index].text, "input")) continue;
        if (tokens[index + 1].kind != .colon or
            tokens[index + 2].kind != .dollar or
            tokens[index + 3].kind != .name)
        {
            return error.InvalidGraphqlDocument;
        }
        return tokens[index + 3].text;
    }
    return error.GraphqlPullRequestTargetMissing;
}

const TokenKind = enum {
    name,
    l_brace,
    r_brace,
    l_paren,
    r_paren,
    colon,
    dollar,
    bang,
    bracket,
    string,
    other,
};
const Token = struct { kind: TokenKind, text: []const u8 };

fn tokenize(allocator: std.mem.Allocator, document: []const u8) !std.ArrayList(Token) {
    var result: std.ArrayList(Token) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < document.len) {
        const c = document[i];
        if (std.ascii.isWhitespace(c) or c == ',') {
            i += 1;
            continue;
        }
        if (c == '#') {
            while (i < document.len and document[i] != '\n') i += 1;
            continue;
        }
        if (c == '"') {
            const begin = i;
            i += 1;
            var escaped = false;
            while (i < document.len) : (i += 1) {
                if (!escaped and document[i] == '"') {
                    i += 1;
                    break;
                }
                escaped = !escaped and document[i] == '\\';
                if (document[i] != '\\') escaped = false;
            }
            if (i > document.len or document[i - 1] != '"') return error.InvalidGraphqlDocument;
            try result.append(allocator, .{ .kind = .string, .text = document[begin..i] });
            continue;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const begin = i;
            i += 1;
            while (i < document.len and (std.ascii.isAlphanumeric(document[i]) or document[i] ==
                '_')) i += 1;
            try result.append(allocator, .{ .kind = .name, .text = document[begin..i] });
            continue;
        }
        const kind: TokenKind = switch (c) {
            '{' => .l_brace,
            '}' => .r_brace,
            '(' => .l_paren,
            ')' => .r_paren,
            ':' => .colon,
            '$' => .dollar,
            '!' => .bang,
            '[', ']' => .bracket,
            else => .other,
        };
        try result.append(allocator, .{ .kind = kind, .text = document[i .. i + 1] });
        i += 1;
    }
    return result;
}

pub fn isMutation(allocator: std.mem.Allocator, document: []const u8) !bool {
    var tokens = try tokenize(allocator, document);
    defer tokens.deinit(allocator);
    if (tokens.items.len == 0 or tokens.items[0].kind != .name) {
        return error.InvalidGraphqlDocument;
    }
    return std.mem.eql(u8, tokens.items[0].text, "mutation");
}

fn skipSelection(tokens: []const Token, start: usize) !usize {
    var i = start;
    var parens: usize = 0;
    while (i < tokens.len) : (i += 1) switch (tokens[i].kind) {
        .l_paren => parens += 1,
        .r_paren => {
            if (parens == 0) return error.InvalidGraphqlDocument;
            parens -= 1;
        },
        .l_brace => if (parens == 0) {
            var depth: usize = 1;
            i += 1;
            while (i < tokens.len and depth > 0) : (i += 1) switch (tokens[i].kind) {
                .l_brace => depth += 1,
                .r_brace => depth -= 1,
                else => {},
            };
            if (depth != 0) return error.InvalidGraphqlDocument;
            return i;
        },
        .r_brace => if (parens == 0) return i,
        else => {},
    };
    return error.InvalidGraphqlDocument;
}

fn validName(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn containsSelectionAlias(tokens: []const Token, start: usize) bool {
    var braces: usize = 0;
    var parens: usize = 0;
    var i = start;
    while (i < tokens.len) : (i += 1) switch (tokens[i].kind) {
        .l_brace => if (parens == 0) {
            braces += 1;
        },
        .r_brace => if (parens == 0 and braces > 0) {
            braces -= 1;
        },
        .l_paren => parens += 1,
        .r_paren => if (parens > 0) {
            parens -= 1;
        },
        .name => if (braces > 0 and parens == 0 and i + 1 < tokens.len and tokens[i + 1].kind ==
            .colon) return true,
        else => {},
    };
    return false;
}

fn validateVariables(value: std.json.Value, pull_request_id: []const u8, saw_target: *bool) !void {
    var pending: [4096]std.json.Value = undefined;
    var pending_len: usize = 1;
    pending[0] = value;
    while (pending_len > 0) {
        pending_len -= 1;
        switch (pending[pending_len]) {
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const target_key = std.mem.eql(u8, key, "pullRequestId") or
                        std.mem.eql(u8, key, "subjectId") or
                        std.mem.eql(u8, key, "labelableId");
                    if (target_key) {
                        if (entry.value_ptr.* != .string or !std.mem.eql(
                            u8,
                            entry.value_ptr.string,
                            pull_request_id,
                        )) return error.GraphqlPullRequestTargetMismatch;
                        saw_target.* = true;
                    }
                    if (pending_len == pending.len) return error.InvalidGraphqlVariables;
                    pending[pending_len] = entry.value_ptr.*;
                    pending_len += 1;
                }
            },
            .array => |array| for (array.items) |item| {
                if (pending_len == pending.len) return error.InvalidGraphqlVariables;
                pending[pending_len] = item;
                pending_len += 1;
            },
            else => {},
        }
    }
}

pub fn operationName(document: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, document, '(') orelse return null;
    const prefix = std.mem.trim(u8, document[0..open], " \t\r\n");
    const space = std.mem.lastIndexOfScalar(u8, prefix, ' ') orelse return null;
    return prefix[space + 1 ..];
}

pub fn requestAlloc(
    allocator: std.mem.Allocator,
    query: []const u8,
    variables_json: []const u8,
) ![]u8 {
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
    if (parsed.value != .object) return error.InvalidGraphqlResponse;
    const data = parsed.value.object.get("data") orelse return error.InvalidGraphqlResponse;
    if (data != .object) return error.InvalidGraphqlResponse;
    const repository = data.object.get("repository") orelse return error.InvalidGraphqlResponse;
    if (repository != .object) return error.InvalidGraphqlResponse;
    const pr_value = repository.object.get("pullRequest") orelse
        return error.InvalidGraphqlResponse;
    if (pr_value != .object) return error.InvalidGraphqlResponse;
    const conn = pr_value.object.get(connection) orelse return error.InvalidGraphqlResponse;
    if (conn != .object) return error.InvalidGraphqlResponse;
    const info = conn.object.get("pageInfo") orelse return error.InvalidGraphqlResponse;
    if (info != .object) return error.InvalidGraphqlResponse;
    const has_next = info.object.get("hasNextPage") orelse return error.InvalidGraphqlResponse;
    if (has_next != .bool) return error.InvalidGraphqlResponse;
    if (!has_next.bool) return null;
    const cursor = info.object.get("endCursor") orelse return error.InvalidGraphqlResponse;
    if (cursor != .string) return error.InvalidGraphqlResponse;
    return @as(?[]u8, try allocator.dupe(u8, cursor.string));
}

test "GraphQL request owns document and variables" {
    const out = try requestAlloc(std.testing.allocator, "query X{viewer{login}}", "{}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"variables\":{}") != null);
}

test "pagination rejects nullable GraphQL targets" {
    const nullable_repository = "{\"data\":{\"repository\":null}}";
    try std.testing.expectError(
        error.InvalidGraphqlResponse,
        pageCursor(std.testing.allocator, nullable_repository, "files"),
    );
    const nullable_pull = "{\"data\":{\"repository\":{\"pullRequest\":null}}}";
    try std.testing.expectError(
        error.InvalidGraphqlResponse,
        pageCursor(std.testing.allocator, nullable_pull, "files"),
    );
}

test "thread metadata and nested comments have separate response bounds" {
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(
        u8,
        threads_query,
        "comments(first:1)",
    ));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(
        u8,
        action_authority_query,
        "comments(first:1)",
    ));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(
        u8,
        reconcile_query,
        "comments(first:1)",
    ));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(
        u8,
        thread_comments_query,
        "comments(first:100,after:$after)",
    ));
}

test "operation identity remains inspectable in fake gh stdin" {
    try std.testing.expectEqualStrings(
        "SynopticMarkFileViewed",
        operationName(mark_viewed_mutation).?,
    );
}

test "viewed batch mutation retains one root and input per file" {
    const document = try markViewedBatchMutationAlloc(std.testing.allocator, 3);
    defer std.testing.allocator.free(document);
    try std.testing.expect(try isMutation(std.testing.allocator, document));
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, document, ":markFileAsViewed("),
    );
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, document, "$input2"));
}

test "operation kind ignores legal leading GraphQL comments" {
    try std.testing.expect(try isMutation(
        std.testing.allocator,
        "# exact requested effect\nmutation Change($input:Input!){change(input:$input){id}}",
    ));
    try std.testing.expect(!try isMutation(
        std.testing.allocator,
        "# read only\nquery Read{viewer{login}}",
    ));
}

test "transparent GraphQL binds broad mutations to exact PR" {
    const safe =
        "mutation AddReviewNote($input:AddCommentInput!){addCom" ++
        "ment(input:$input){clientMutationId}}";
    try validateTransparentAtHead(
        safe,
        "AddReviewNote",
        "{\"input\":{\"subjectId\":\"PR_1\",\"body\":\"note\"}}",
        "PR_1",
        "HEAD_1",
    );
    const variables = "{\"input\":{\"subjectId\":\"PR_1\"}}";
    const alias = "mutation AddReviewNote($input:AddCommentInput!){hidden" ++
        ":addComment(input:$input){clientMutationId}}";
    try std.testing.expectError(
        error.GraphqlAliasForbidden,
        validateTransparentAtHead(alias, "AddReviewNote", variables, "PR_1", "HEAD_1"),
    );
    const fragment = "mutation AddReviewNote($input:AddCommentInput!){addCom" ++
        "ment(input:$input){...Fields}} fragment Fields on AddC" ++
        "ommentPayload{clientMutationId}";
    try std.testing.expectError(
        error.GraphqlSyntaxForbidden,
        validateTransparentAtHead(fragment, "AddReviewNote", variables, "PR_1", "HEAD_1"),
    );
    const multiple = "mutation AddReviewNote($input:AddCommentInput!){addCom" ++
        "ment(input:$input){clientMutationId} deleteIssue(input" ++
        ":$input){clientMutationId}}";
    try std.testing.expectError(
        error.GraphqlRootCountInvalid,
        validateTransparentAtHead(multiple, "AddReviewNote", variables, "PR_1", "HEAD_1"),
    );
    const update = "mutation ChangePr($input:UpdatePullRequestInput!){upda" ++
        "tePullRequest(input:$input){clientMutationId}}";
    const update_variables = "{\"input\":{\"pullRequestId\":\"PR_1\",\"state\":\"CLOSED\"," ++
        "\"projectIds\":[\"P_1\"]}}";
    try validateTransparentAtHead(update, "ChangePr", update_variables, "PR_1", "HEAD_1");
    try std.testing.expectError(
        error.GraphqlPullRequestTargetMismatch,
        validateTransparentAtHead(
            safe,
            "AddReviewNote",
            "{\"input\":{\"subjectId\":\"PR_OTHER\"}}",
            "PR_1",
            "HEAD_1",
        ),
    );
    try std.testing.expectError(
        error.GraphqlPullRequestTargetMismatch,
        validateTransparentAtHead(
            safe,
            "AddReviewNote",
            "{\"input\":{\"subjectId\":\"PR_OTHER\"}," ++
                "\"decoy\":{\"subjectId\":\"PR_1\"}}",
            "PR_1",
            "HEAD_1",
        ),
    );
    try expectTransparentHeadSensitiveMutationBinding();
}

fn expectTransparentHeadSensitiveMutationBinding() !void {
    const merge = "mutation Merge($input:MergePullRequestInput!){mergePullRequest" ++
        "(input:$input){pullRequest{id}}}";
    try expectTransparentHeadBinding(merge, "Merge");
    const update = "mutation UpdateBranch($input:UpdatePullRequestBranchInput!){" ++
        "updatePullRequestBranch(input:$input){clientMutationId}}";
    try expectTransparentHeadBinding(update, "UpdateBranch");
}

fn expectTransparentHeadBinding(document: []const u8, operation: []const u8) !void {
    try validateTransparentAtHead(
        document,
        operation,
        "{\"input\":{\"pullRequestId\":\"PR_1\",\"expectedHeadOid\":\"HEAD_1\"}}",
        "PR_1",
        "HEAD_1",
    );
    try std.testing.expectError(
        error.GraphqlExpectedHeadMissing,
        validateTransparentAtHead(
            document,
            operation,
            "{\"input\":{\"pullRequestId\":\"PR_1\"}}",
            "PR_1",
            "HEAD_1",
        ),
    );
    try std.testing.expectError(
        error.GraphqlExpectedHeadMismatch,
        validateTransparentAtHead(
            document,
            operation,
            "{\"input\":{\"pullRequestId\":\"PR_1\",\"expectedHeadOid\":\"OLD\"}}",
            "PR_1",
            "HEAD_1",
        ),
    );
}
