const std = @import("std");
const graphql = @import("graphql.zig");

pub const ActionKind = enum {
    add_inline_comment,
    reply_thread,
    resolve_thread,
    unresolve_thread,
    update_comment,
    delete_comment,
    mark_viewed,
    unmark_viewed,
    graphql,
};
pub const ActionStatus = enum {
    pending,
    superseded,
    rejected,
    executing,
    succeeded,
    failed,
    outcome_unknown,
    invalidated,
};
pub const ToolPhase = enum { initial_review, conversation };
pub const max_tool_payload_bytes: usize = 128 * 1024;

pub const ActionTarget = struct {
    repository: []const u8,
    pull_request: u64,
    pull_request_id: []const u8,
    head_oid: []const u8,
    path: ?[]const u8 = null,
    line: ?u32 = null,
    start_line: ?u32 = null,
    side: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    comment_id: ?[]const u8 = null,
    /// Server-observed body at preparation time for destructive comment actions.
    /// This is intentionally omitted from the browser card representation.
    comment_body_snapshot: ?[]const u8 = null,
};

pub const TransparentAction = struct {
    operation_name: []const u8,
    document: []const u8,
    variables: []const u8,
};

/// All strings in a stored card are owned by ActionStore. The public value is
/// immutable except for the state-machine fields `status` and `supersedes`.
pub const ActionCard = struct {
    id: []const u8,
    session_id: []const u8,
    source_turn_id: []const u8,
    slot: []const u8,
    kind: ActionKind,
    effect_summary: []const u8,
    target: ActionTarget,
    body: ?[]const u8 = null,
    payload_json: []const u8,
    graphql: ?TransparentAction = null,
    supersedes: ?[]const u8 = null,
    status: ActionStatus = .pending,
};

pub const PreparedActionInput = struct {
    slot: []u8,
    kind: ActionKind,
    effect_summary: []u8,
    payload_json: []u8,
    path: ?[]u8 = null,
    line: ?u32 = null,
    start_line: ?u32 = null,
    side: ?[]u8 = null,
    body: ?[]u8 = null,
    thread_id: ?[]u8 = null,
    comment_id: ?[]u8 = null,
    operation_name: ?[]u8 = null,
    document: ?[]u8 = null,
    variables: ?[]u8 = null,

    pub fn deinit(self: PreparedActionInput, allocator: std.mem.Allocator) void {
        allocator.free(self.slot);
        allocator.free(self.effect_summary);
        allocator.free(self.payload_json);
        inline for (
            .{
                self.path,
                self.side,
                self.body,
                self.thread_id,
                self.comment_id,
                self.operation_name,
                self.document,
                self.variables,
            },
        ) |value| if (value) |owned|
            allocator.free(owned);
    }
};

pub const AuthoritativeTarget = struct {
    repository: []const u8,
    pull_request: u64,
    pull_request_id: []const u8,
    head_oid: []const u8,
    session_path: []const u8,
    comment_body_snapshot: ?[]const u8 = null,
};

pub fn authorizeTool(phase: ToolPhase, human_directed: bool) !void {
    if (phase == .initial_review) return error.InitialReviewActionForbidden;
    if (!human_directed) return error.HumanDirectionRequired;
}

pub fn initialReviewMayPrepareAction(initial_turn: bool, human_directed: bool) bool {
    return !initial_turn and human_directed;
}

pub fn parseKind(value: []const u8) !ActionKind {
    inline for (std.meta.fields(ActionKind)) |field| if (std.mem.eql(u8, value, field.name))
        return @enumFromInt(field.value);
    return error.UnsupportedGithubActionKind;
}

pub fn decodePreparedAction(allocator: std.mem.Allocator, raw: []const u8) !PreparedActionInput {
    if (raw.len > max_tool_payload_bytes) return error.ToolPayloadTooLarge;
    var root = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        raw,
        .{ .max_value_len = graphql.TransparentLimits.variables_bytes },
    );
    defer root.deinit();
    const root_object = object(root.value) orelse return error.InvalidToolPayload;
    const params = if (root_object.get("params")) |value|
        object(value) orelse return error.InvalidToolPayload
    else
        root_object;
    const argument_value = params.get("arguments") orelse
        params.get("input") orelse return error.InvalidToolPayload;
    const arguments = object(argument_value) orelse return error.InvalidToolPayload;
    const slot_value = string(arguments.get("slot")) orelse return error.InvalidToolPayload;
    const kind_value = string(arguments.get("kind")) orelse "add_inline_comment";
    const kind = try parseKind(kind_value);
    const effect = string(arguments.get("effectSummary")) orelse
        string(arguments.get("effect_summary")) orelse return error.InvalidToolPayload;
    if (slot_value.len == 0 or slot_value.len > 128 or effect.len == 0 or effect.len > 2048)
        return error.InvalidToolPayload;
    const payload_value = arguments.get("payload") orelse rootPayload(arguments, kind);
    const payload = object(payload_value) orelse return error.InvalidToolPayload;
    const payload_json = try stringifyAlloc(allocator, payload_value);
    errdefer allocator.free(payload_json);
    var result = PreparedActionInput{
        .slot = try allocator.dupe(u8, slot_value),
        .kind = kind,
        .effect_summary = try allocator.dupe(u8, effect),
        .payload_json = payload_json,
    };
    errdefer result.deinit(allocator);
    result.path = try dupeOptional(allocator, string(payload.get("path")));
    result.line = uint32(payload.get("line"));
    result.start_line = uint32(payload.get("startLine") orelse payload.get("start_line"));
    result.side = try dupeOptional(allocator, string(payload.get("side")));
    result.body = try dupeOptional(allocator, string(payload.get("body")));
    result.thread_id = try dupeOptional(allocator, string(payload.get("threadId") orelse
        payload.get("thread_id")));
    result.comment_id = try dupeOptional(allocator, string(payload.get("commentId") orelse
        payload.get("comment_id")));
    if (kind == .graphql) {
        result.operation_name = try dupeOptional(allocator, string(payload.get("operationName")));
        result.document = try dupeOptional(allocator, string(payload.get("document")));
        if (payload.get("variables")) |variables| {
            result.variables = try stringifyAlloc(allocator, variables);
        }
    }
    try validateInput(result);
    return result;
}

fn rootPayload(arguments: std.json.ObjectMap, kind: ActionKind) std.json.Value {
    _ = kind;
    return .{ .object = arguments };
}

pub fn validateInput(input: PreparedActionInput) !void {
    switch (input.kind) {
        .add_inline_comment => if (input.path == null or input.line == null or input.line.? ==
            0 or input.body == null or input.body.?.len == 0) return error.InvalidInlineAction,
        .reply_thread => if (input.thread_id == null or input.body == null or input.body.?.len ==
            0) return error.InvalidThreadAction,
        .resolve_thread, .unresolve_thread => if (input.thread_id == null)
            return error.InvalidThreadAction,
        .update_comment => if (input.comment_id == null or input.body == null or
            input.body.?.len == 0) return error.InvalidCommentAction,
        .delete_comment => if (input.comment_id == null) return error.InvalidCommentAction,
        .mark_viewed, .unmark_viewed => if (input.path == null) return error.InvalidViewedAction,
        .graphql => if (input.operation_name == null or input.document == null or
            input.variables == null) return error.InvalidGraphqlAction,
    }
    if (input.side) |side| {
        const valid = std.mem.eql(u8, side, "RIGHT") or std.mem.eql(u8, side, "LEFT");
        if (!valid) return error.InvalidDiffSide;
    }
}

pub fn validateAgainstSession(input: PreparedActionInput, session_path: []const u8) !void {
    if (input.path) |path| {
        if (!std.mem.eql(u8, path, session_path)) return error.ActionTargetsAnotherSession;
    }
}

pub const ActionStore = struct {
    allocator: std.mem.Allocator,
    cards: std.ArrayList(ActionCard) = .empty,
    next_id: u64 = 1,

    pub fn deinit(self: *ActionStore) void {
        for (self.cards.items) |card| self.freeCard(card);
        self.cards.deinit(self.allocator);
    }

    pub fn prepare(
        self: *ActionStore,
        session_id: []const u8,
        source_turn_id: []const u8,
        input: PreparedActionInput,
        authoritative: AuthoritativeTarget,
    ) !*ActionCard {
        try validateAgainstSession(input, authoritative.session_path);
        if (input.kind == .graphql) try graphql.validateTransparent(
            input.document.?,
            input.operation_name.?,
            input.variables.?,
            authoritative.pull_request_id,
        );
        var superseded_index: ?usize = null;
        var supersedes: ?[]const u8 = null;
        for (self.cards.items, 0..) |card, index| if (card.status == .pending and
            std.mem.eql(u8, card.session_id, session_id) and std.mem.eql(u8, card.slot, input.slot))
        {
            superseded_index = index;
            supersedes = card.id;
        };
        const id = try std.fmt.allocPrint(self.allocator, "act-{d}", .{self.next_id});
        errdefer self.allocator.free(id);
        self.next_id += 1;
        var card = ActionCard{
            .id = id,
            .session_id = try self.allocator.dupe(u8, session_id),
            .source_turn_id = try self.allocator.dupe(u8, source_turn_id),
            .slot = try self.allocator.dupe(u8, input.slot),
            .kind = input.kind,
            .effect_summary = try self.allocator.dupe(u8, input.effect_summary),
            .target = .{
                .repository = try self.allocator.dupe(u8, authoritative.repository),
                .pull_request = authoritative.pull_request,
                .pull_request_id = try self.allocator.dupe(u8, authoritative.pull_request_id),
                .head_oid = try self.allocator.dupe(u8, authoritative.head_oid),
                .path = try dupeOptional(self.allocator, input.path),
                .line = input.line,
                .start_line = input.start_line,
                .side = try dupeOptional(self.allocator, input.side),
                .thread_id = try dupeOptional(self.allocator, input.thread_id),
                .comment_id = try dupeOptional(self.allocator, input.comment_id),
                .comment_body_snapshot = try dupeOptional(
                    self.allocator,
                    authoritative.comment_body_snapshot,
                ),
            },
            .body = try dupeOptional(self.allocator, input.body),
            .payload_json = try self.allocator.dupe(u8, input.payload_json),
            .supersedes = try dupeOptional(self.allocator, supersedes),
        };
        errdefer self.freeCard(card);
        if (input.kind == .graphql) card.graphql = .{
            .operation_name = try self.allocator.dupe(u8, input.operation_name.?),
            .document = try self.allocator.dupe(u8, input.document.?),
            .variables = try self.allocator.dupe(u8, input.variables.?),
        };
        try self.cards.append(self.allocator, card);
        if (superseded_index) |index| self.cards.items[index].status = .superseded;
        return &self.cards.items[self.cards.items.len - 1];
    }

    pub fn pendingIdForSlot(
        self: *const ActionStore,
        session_id: []const u8,
        slot: []const u8,
    ) ?[]const u8 {
        for (self.cards.items) |card| if (card.status == .pending and std.mem.eql(
            u8,
            card.session_id,
            session_id,
        ) and std.mem.eql(u8, card.slot, slot)) return card.id;
        return null;
    }

    pub fn pendingMatching(
        self: *ActionStore,
        session_id: []const u8,
        source_turn_id: []const u8,
        input: PreparedActionInput,
    ) ?*ActionCard {
        for (self.cards.items) |*card| {
            const identity_matches = card.status == .pending and
                std.mem.eql(u8, card.session_id, session_id) and
                std.mem.eql(u8, card.source_turn_id, source_turn_id) and
                std.mem.eql(u8, card.slot, input.slot) and card.kind == input.kind;
            if (identity_matches and
                std.mem.eql(u8, card.effect_summary, input.effect_summary) and
                std.mem.eql(u8, card.payload_json, input.payload_json)) return card;
        }
        return null;
    }

    pub fn pendingById(self: *ActionStore, id: []const u8) !*ActionCard {
        for (self.cards.items) |*card| if (std.mem.eql(u8, card.id, id)) {
            if (card.status != .pending) return error.ActionNotPending;
            return card;
        };
        return error.UnknownAction;
    }
    pub fn beginExecute(self: *ActionStore, id: []const u8) !*ActionCard {
        const card = try self.pendingById(id);
        card.status = .executing;
        return card;
    }
    pub fn reject(self: *ActionStore, id: []const u8) !void {
        const card = try self.pendingById(id);
        card.status = .rejected;
    }
    pub fn invalidate(self: *ActionStore, id: []const u8) !void {
        const card = try self.pendingById(id);
        card.status = .invalidated;
    }
    pub fn setTerminal(self: *ActionStore, id: []const u8, status: ActionStatus) !void {
        if (status != .succeeded and status != .failed and status != .outcome_unknown and
            status != .invalidated) return error.InvalidTerminalStatus;
        for (self.cards.items) |*card| if (std.mem.eql(u8, card.id, id)) {
            if (card.status != .executing) return error.ActionNotExecuting;
            card.status = status;
            return;
        };
        return error.UnknownAction;
    }

    fn freeCard(self: *ActionStore, card: ActionCard) void {
        inline for (
            .{
                card.id,
                card.session_id,
                card.source_turn_id,
                card.slot,
                card.effect_summary,
                card.target.repository,
                card.target.pull_request_id,
                card.target.head_oid,
                card.payload_json,
            },
        ) |value| self.allocator.free(value);
        inline for (
            .{
                card.target.path,
                card.target.side,
                card.target.thread_id,
                card.target.comment_id,
                card.target.comment_body_snapshot,
                card.body,
                card.supersedes,
            },
        ) |value| if (value) |owned|
            self.allocator.free(owned);
        if (card.graphql) |action| inline for (
            .{ action.operation_name, action.document, action.variables },
        ) |value| self.allocator.free(value);
    }
};

pub fn cardJsonAlloc(allocator: std.mem.Allocator, card: ActionCard) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const header_arguments = .{
        std.json.fmt(card.id, .{}),
        std.json.fmt(card.session_id, .{}),
        std.json.fmt(card.source_turn_id, .{}),
        std.json.fmt(card.slot, .{}),
        std.json.fmt(actionStatusName(card.status), .{}),
        std.json.fmt(@tagName(card.kind), .{}),
        std.json.fmt(card.effect_summary, .{}),
        std.json.fmt(card.target.repository, .{}),
        card.target.pull_request,
        std.json.fmt(card.target.head_oid, .{}),
    };
    try out.writer.print("{{\"schema\":\"synoptic-github-action/v1\",\"id\":{f}," ++
        "\"sessionId\":{f},\"sourceTurnId\":{f},\"slot\":{f},\"" ++
        "status\":{f},\"kind\":{f},\"effectSummary\":{f},\"targ" ++
        "et\":{{\"repository\":{f},\"pullRequest\":{d},\"headOi" ++
        "d\":{f},\"path\":", header_arguments);
    try writeOptionalString(&out.writer, card.target.path);
    try out.writer.writeAll(",\"line\":");
    try writeOptionalInt(&out.writer, card.target.line);
    try out.writer.writeAll(",\"startLine\":");
    try writeOptionalInt(&out.writer, card.target.start_line);
    try out.writer.writeAll(",\"side\":");
    try writeOptionalString(&out.writer, card.target.side);
    try out.writer.writeAll(",\"threadId\":");
    try writeOptionalString(&out.writer, card.target.thread_id);
    try out.writer.writeAll(",\"commentId\":");
    try writeOptionalString(&out.writer, card.target.comment_id);
    try out.writer.writeAll("},\"body\":");
    try writeOptionalString(&out.writer, card.body);
    try out.writer.writeAll(",\"payload\":");
    try out.writer.writeAll(card.payload_json);
    try out.writer.writeAll(",\"graphql\":");
    if (card.graphql) |action| {
        try out.writer.print("{{\"operationName\":{f},\"document\":{f},\"variables\":" ++
            "{s}}}", .{
            std.json.fmt(action.operation_name, .{}),
            std.json.fmt(action.document, .{}),
            action.variables,
        });
    } else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"supersedes\":");
    try writeOptionalString(&out.writer, card.supersedes);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn actionStatusName(status: ActionStatus) []const u8 {
    return switch (status) {
        .outcome_unknown => "outcome-unknown",
        else => @tagName(status),
    };
}
fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |present| {
        try std.json.Stringify.value(present, .{}, writer);
    } else try writer.writeAll("null");
}
fn writeOptionalInt(writer: *std.Io.Writer, value: ?u32) !void {
    if (value) |present| try writer.print("{d}", .{present}) else try writer.writeAll("null");
}
fn object(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |v| v,
        else => null,
    };
}
fn string(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |v| v,
        else => null,
    };
}
fn uint32(value: ?std.json.Value) ?u32 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |v| if (v > 0 and v <= std.math.maxInt(u32)) @intCast(v) else null,
        else => null,
    };
}
fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}
fn stringifyAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "initial tool call is rejected even with plausible payload" {
    try std.testing.expectError(
        error.InitialReviewActionForbidden,
        authorizeTool(.initial_review, true),
    );
}
test "same session slot supersedes immutably and execution is once" {
    var store = ActionStore{ .allocator = std.testing.allocator };
    defer store.deinit();
    const target = AuthoritativeTarget{
        .repository = "o/r",
        .pull_request = 1,
        .pull_request_id = "PR_1",
        .head_oid = "h",
        .session_path = "a",
    };
    const one = PreparedActionInput{
        .slot = @constCast("finding"),
        .kind = .add_inline_comment,
        .effect_summary = @constCast("first"),
        .payload_json = @constCast("{}"),
        .path = @constCast("a"),
        .line = 1,
        .body = @constCast("one"),
    };
    const two = PreparedActionInput{
        .slot = @constCast("finding"),
        .kind = .add_inline_comment,
        .effect_summary = @constCast("second"),
        .payload_json = @constCast("{}"),
        .path = @constCast("a"),
        .line = 2,
        .body = @constCast("two"),
    };
    const first = try store.prepare("s", "t1", one, target);
    try std.testing.expect(store.pendingMatching("s", "t1", one) == first);
    try std.testing.expect(store.pendingMatching("s", "other-turn", one) == null);
    _ = try store.prepare("s", "t2", two, target);
    try std.testing.expectEqual(ActionStatus.superseded, store.cards.items[0].status);
    try std.testing.expectEqualStrings("act-1", store.cards.items[1].supersedes.?);
    _ = try store.beginExecute("act-2");
    try std.testing.expectError(error.ActionNotPending, store.beginExecute("act-2"));
}
test "transparent validation runs before immutable card creation" {
    var store = ActionStore{ .allocator = std.testing.allocator };
    defer store.deinit();
    const input = PreparedActionInput{
        .slot = @constCast("unsafe"),
        .kind = .graphql,
        .effect_summary = @constCast("Add a note"),
        .payload_json = @constCast("{}"),
        .operation_name = @constCast("AddNote"),
        .document = @constCast(
            "mutation AddNote($input:AddCommentInput!){hidden:" ++
                "addComment(input:$input){clientMutationId}}",
        ),
        .variables = @constCast("{\"input\":{\"subjectId\":\"PR_1\"}}"),
    };
    try std.testing.expectError(
        error.GraphqlAliasForbidden,
        store.prepare(
            "s",
            "t",
            input,
            .{
                .repository = "o/r",
                .pull_request = 1,
                .pull_request_id = "PR_1",
                .head_oid = "h",
                .session_path = "a",
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), store.cards.items.len);
}
