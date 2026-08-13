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
pub const max_retained_action_cards: usize = 256;
pub const max_retained_action_bytes: usize = 4 * 1024 * 1024;

pub const ActionTarget = struct {
    repository: []const u8,
    pull_request: u64,
    pull_request_id: []const u8,
    base_oid: []const u8,
    head_oid: []const u8,
    /// Historical path that identifies the originating file session.
    session_path: []const u8,
    /// Current-generation path resolved from the session's file lineage.
    current_path: []const u8,
    /// Exact path reported by GitHub for the targeted file, thread, or comment.
    path: ?[]const u8 = null,
    line: ?u32 = null,
    start_line: ?u32 = null,
    side: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    comment_id: ?[]const u8 = null,
    /// Server-observed body at preparation time for destructive comment actions.
    /// Serialized into the immutable confirmation card so the human can identify
    /// the exact target; execution still revalidates this authoritative snapshot.
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
    base_oid: []const u8,
    head_oid: []const u8,
    session_path: []const u8,
    current_path: []const u8,
    github_path: ?[]const u8 = null,
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
    var result = try initPreparedActionInput(
        allocator,
        slot_value,
        kind,
        effect,
        payload_value,
    );
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

    const PendingSlot = struct {
        index: ?usize = null,
        id: ?[]const u8 = null,
    };

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
        try validateAgainstSession(input, authoritative.current_path);
        if (input.kind == .graphql) try graphql.validateTransparent(
            input.document.?,
            input.operation_name.?,
            input.variables.?,
            authoritative.pull_request_id,
        );
        const pending_slot = self.pendingSlot(session_id, input.slot);
        const github_path: ?[]const u8 = if (authoritative.github_path) |path|
            path
        else
            input.path;
        const card = try self.buildCard(
            session_id,
            source_turn_id,
            input,
            authoritative,
            github_path,
            pending_slot.id,
        );
        errdefer self.freeCard(card);
        try self.cards.append(self.allocator, card);
        if (pending_slot.index) |index| self.cards.items[index].status = .superseded;
        self.enforceRetentionBudget() catch |err| {
            const added = self.cards.pop().?;
            if (pending_slot.id) |prior_id| for (self.cards.items) |*prior| {
                if (std.mem.eql(u8, prior.id, prior_id)) prior.status = .pending;
            };
            self.freeCard(added);
            return err;
        };
        self.next_id += 1;
        return &self.cards.items[self.cards.items.len - 1];
    }

    fn enforceRetentionBudget(self: *ActionStore) !void {
        while (self.cards.items.len > max_retained_action_cards or
            self.retainedBytes() > max_retained_action_bytes)
        {
            var removable: ?usize = null;
            for (self.cards.items, 0..) |card, index| {
                if (index == self.cards.items.len - 1) continue;
                if (card.status == .pending or card.status == .executing) continue;
                removable = index;
                break;
            }
            const index = removable orelse return error.ActionStoreCapacityExceeded;
            const removed = self.cards.orderedRemove(index);
            self.freeCard(removed);
        }
    }

    pub fn retainedBytes(self: *const ActionStore) usize {
        var total: usize = 0;
        for (self.cards.items) |card| total += cardRetainedBytes(card);
        return total;
    }

    fn cardRetainedBytes(card: ActionCard) usize {
        var total = card.id.len + card.session_id.len + card.source_turn_id.len +
            card.slot.len + card.effect_summary.len + card.payload_json.len +
            card.target.repository.len + card.target.pull_request_id.len +
            card.target.base_oid.len + card.target.head_oid.len +
            card.target.session_path.len + card.target.current_path.len;
        inline for (.{
            card.body,
            card.supersedes,
            card.target.path,
            card.target.side,
            card.target.thread_id,
            card.target.comment_id,
            card.target.comment_body_snapshot,
        }) |value| if (value) |bytes| {
            total += bytes.len;
        };
        if (card.graphql) |action| {
            total += action.operation_name.len + action.document.len + action.variables.len;
        }
        return total;
    }

    fn buildCard(
        self: *ActionStore,
        session_id: []const u8,
        source_turn_id: []const u8,
        input: PreparedActionInput,
        authoritative: AuthoritativeTarget,
        github_path: ?[]const u8,
        supersedes: ?[]const u8,
    ) !ActionCard {
        const id = try std.fmt.allocPrint(self.allocator, "act-{d}", .{self.next_id});
        errdefer self.allocator.free(id);
        const owned_session_id = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(owned_session_id);
        const owned_turn_id = try self.allocator.dupe(u8, source_turn_id);
        errdefer self.allocator.free(owned_turn_id);
        const slot = try self.allocator.dupe(u8, input.slot);
        errdefer self.allocator.free(slot);
        const effect_summary = try self.allocator.dupe(u8, input.effect_summary);
        errdefer self.allocator.free(effect_summary);
        const target = try self.buildTarget(input, authoritative, github_path);
        errdefer self.freeTarget(target);
        const body = try dupeOptional(self.allocator, input.body);
        errdefer if (body) |value| self.allocator.free(value);
        const payload_json = try self.allocator.dupe(u8, input.payload_json);
        errdefer self.allocator.free(payload_json);
        const owned_supersedes = try dupeOptional(self.allocator, supersedes);
        errdefer if (owned_supersedes) |value| self.allocator.free(value);
        const transparent = if (input.kind == .graphql)
            try self.buildTransparentAction(input)
        else
            null;
        errdefer if (transparent) |action| self.freeTransparent(action);
        return .{
            .id = id,
            .session_id = owned_session_id,
            .source_turn_id = owned_turn_id,
            .slot = slot,
            .kind = input.kind,
            .effect_summary = effect_summary,
            .target = target,
            .body = body,
            .payload_json = payload_json,
            .graphql = transparent,
            .supersedes = owned_supersedes,
        };
    }

    fn buildTarget(
        self: *ActionStore,
        input: PreparedActionInput,
        authoritative: AuthoritativeTarget,
        github_path: ?[]const u8,
    ) !ActionTarget {
        const repository = try self.allocator.dupe(u8, authoritative.repository);
        errdefer self.allocator.free(repository);
        const pull_request_id = try self.allocator.dupe(u8, authoritative.pull_request_id);
        errdefer self.allocator.free(pull_request_id);
        const base_oid = try self.allocator.dupe(u8, authoritative.base_oid);
        errdefer self.allocator.free(base_oid);
        const head_oid = try self.allocator.dupe(u8, authoritative.head_oid);
        errdefer self.allocator.free(head_oid);
        const session_path = try self.allocator.dupe(u8, authoritative.session_path);
        errdefer self.allocator.free(session_path);
        const current_path = try self.allocator.dupe(u8, authoritative.current_path);
        errdefer self.allocator.free(current_path);
        const path = try dupeOptional(self.allocator, github_path);
        errdefer if (path) |value| self.allocator.free(value);
        const side: ?[]u8 = if (input.kind == .add_inline_comment)
            try self.allocator.dupe(u8, input.side orelse "RIGHT")
        else
            try dupeOptional(self.allocator, input.side);
        errdefer if (side) |value| self.allocator.free(value);
        const thread_id = try dupeOptional(self.allocator, input.thread_id);
        errdefer if (thread_id) |value| self.allocator.free(value);
        const comment_id = try dupeOptional(self.allocator, input.comment_id);
        errdefer if (comment_id) |value| self.allocator.free(value);
        const snapshot = try dupeOptional(self.allocator, authoritative.comment_body_snapshot);
        errdefer if (snapshot) |value| self.allocator.free(value);
        return .{
            .repository = repository,
            .pull_request = authoritative.pull_request,
            .pull_request_id = pull_request_id,
            .base_oid = base_oid,
            .head_oid = head_oid,
            .session_path = session_path,
            .current_path = current_path,
            .path = path,
            .line = input.line,
            .start_line = input.start_line,
            .side = side,
            .thread_id = thread_id,
            .comment_id = comment_id,
            .comment_body_snapshot = snapshot,
        };
    }

    fn freeTarget(self: *ActionStore, target: ActionTarget) void {
        inline for (.{
            target.repository,
            target.pull_request_id,
            target.base_oid,
            target.head_oid,
            target.session_path,
            target.current_path,
        }) |value| self.allocator.free(value);
        inline for (.{
            target.path,
            target.side,
            target.thread_id,
            target.comment_id,
            target.comment_body_snapshot,
        }) |value| if (value) |owned| self.allocator.free(owned);
    }

    fn buildTransparentAction(
        self: *ActionStore,
        input: PreparedActionInput,
    ) !TransparentAction {
        const operation_name = try self.allocator.dupe(u8, input.operation_name.?);
        errdefer self.allocator.free(operation_name);
        const document = try self.allocator.dupe(u8, input.document.?);
        errdefer self.allocator.free(document);
        const variables = try self.allocator.dupe(u8, input.variables.?);
        return .{
            .operation_name = operation_name,
            .document = document,
            .variables = variables,
        };
    }

    fn freeTransparent(self: *ActionStore, action: TransparentAction) void {
        inline for (.{ action.operation_name, action.document, action.variables }) |value| {
            self.allocator.free(value);
        }
    }

    fn pendingSlot(self: *const ActionStore, session_id: []const u8, slot: []const u8) PendingSlot {
        var result = PendingSlot{};
        for (self.cards.items, 0..) |card, index| if (card.status == .pending and
            std.mem.eql(u8, card.session_id, session_id) and std.mem.eql(u8, card.slot, slot))
        {
            result.index = index;
            result.id = card.id;
        };
        return result;
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
    pub fn byId(self: *ActionStore, id: []const u8) !*ActionCard {
        for (self.cards.items) |*card| if (std.mem.eql(u8, card.id, id)) return card;
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
                card.payload_json,
            },
        ) |value| self.allocator.free(value);
        inline for (
            .{
                card.body,
                card.supersedes,
            },
        ) |value| if (value) |owned|
            self.allocator.free(owned);
        self.freeTarget(card.target);
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
        std.json.fmt(card.target.base_oid, .{}),
        std.json.fmt(card.target.head_oid, .{}),
    };
    try out.writer.print("{{\"schema\":\"synoptic-github-action/v1\",\"id\":{f}," ++
        "\"sessionId\":{f},\"sourceTurnId\":{f},\"slot\":{f},\"" ++
        "status\":{f},\"kind\":{f},\"effectSummary\":{f},\"targ" ++
        "et\":{{\"repository\":{f},\"pullRequest\":{d},\"baseOi" ++
        "d\":{f},\"headOid\":{f},\"sessionPath\":", header_arguments);
    try writeOptionalString(&out.writer, card.target.session_path);
    try out.writer.writeAll(",\"currentPath\":");
    try writeOptionalString(&out.writer, card.target.current_path);
    try out.writer.writeAll(",\"path\":");
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
    try out.writer.writeAll(",\"commentBodySnapshot\":");
    try writeOptionalString(&out.writer, card.target.comment_body_snapshot);
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
fn initPreparedActionInput(
    allocator: std.mem.Allocator,
    slot: []const u8,
    kind: ActionKind,
    effect_summary: []const u8,
    payload: std.json.Value,
) !PreparedActionInput {
    const owned_slot = try allocator.dupe(u8, slot);
    errdefer allocator.free(owned_slot);
    const owned_effect = try allocator.dupe(u8, effect_summary);
    errdefer allocator.free(owned_effect);
    const payload_json = try stringifyAlloc(allocator, payload);
    errdefer allocator.free(payload_json);
    return .{
        .slot = owned_slot,
        .kind = kind,
        .effect_summary = owned_effect,
        .payload_json = payload_json,
    };
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
test "prepared action input decoding releases every partial allocation" {
    const raw =
        \\{"arguments":{"slot":"finding","kind":"add_inline_comment",
        \\"effectSummary":"Add an inline comment","payload":{"path":"a.zig",
        \\"line":1,"body":"Could this fail?"}}}
    ;
    var successes: usize = 0;
    for (0..32) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const decoded = decodePreparedAction(failing.allocator(), raw);
        if (decoded) |input| {
            input.deinit(failing.allocator());
            successes += 1;
        } else |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => {},
            else => return err,
        }
    }
    try std.testing.expect(successes > 0);
}
test "same session slot supersedes immutably and execution is once" {
    var store = ActionStore{ .allocator = std.testing.allocator };
    defer store.deinit();
    const target = AuthoritativeTarget{
        .repository = "o/r",
        .pull_request = 1,
        .pull_request_id = "PR_1",
        .base_oid = "unknown-base",
        .head_oid = "h",
        .session_path = "a",
        .current_path = "a",
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

test "action store evicts oldest terminal history within fixed budgets" {
    var store = ActionStore{ .allocator = std.testing.allocator };
    defer store.deinit();
    const target = AuthoritativeTarget{
        .repository = "o/r",
        .pull_request = 1,
        .pull_request_id = "PR_1",
        .base_oid = "base",
        .head_oid = "head",
        .session_path = "a.zig",
        .current_path = "a.zig",
    };
    for (0..max_retained_action_cards + 8) |index| {
        var slot_buffer: [32]u8 = undefined;
        const slot = try std.fmt.bufPrint(&slot_buffer, "finding-{d}", .{index});
        const card = try store.prepare("s", "t", .{
            .slot = @constCast(slot),
            .kind = .mark_viewed,
            .effect_summary = @constCast("mark viewed"),
            .payload_json = @constCast("{}"),
            .path = @constCast("a.zig"),
        }, target);
        try store.reject(card.id);
    }
    try std.testing.expect(store.cards.items.len <= max_retained_action_cards);
    try std.testing.expect(store.retainedBytes() <= max_retained_action_bytes);
    try std.testing.expectEqualStrings("act-9", store.cards.items[0].id);
}
test "inline comment card owns the default RIGHT side" {
    var store = ActionStore{ .allocator = std.testing.allocator };
    defer store.deinit();
    const card = try store.prepare(
        "s",
        "t",
        .{
            .slot = @constCast("finding"),
            .kind = .add_inline_comment,
            .effect_summary = @constCast("comment"),
            .payload_json = @constCast("{}"),
            .path = @constCast("a.zig"),
            .line = 1,
            .body = @constCast("body"),
        },
        .{
            .repository = "o/r",
            .pull_request = 1,
            .pull_request_id = "PR_1",
            .base_oid = "unknown-base",
            .head_oid = "h",
            .session_path = "a.zig",
            .current_path = "a.zig",
        },
    );
    try std.testing.expectEqualStrings("RIGHT", card.target.side.?);
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
                .base_oid = "unknown-base",
                .head_oid = "h",
                .session_path = "a",
                .current_path = "a",
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), store.cards.items.len);
}
