const std = @import("std");

pub const TraceFormat = enum {
    new_044_plus,
    mid_payload_meta,
    old_2025_08_root_meta,
    unknown,
};

pub const TurnStatus = enum {
    complete,
    aborted,
    ongoing,
    @"error",
};

pub const ToolKind = enum {
    exec_command,
    mcp_tool,
    patch_apply,
    web_search,
    image_generation,
    spawn_agent,
    wait_agent,
    close_agent,
    unknown,
};

pub const ToolLifecycleStatus = enum {
    declared,
    completed,
    failed,
    unresolved,
    inferred,
    duplicate_suppressed,
    unknown,
};

pub const TraceParseOptions = struct {
    ongoing_threshold_secs: i64 = 60,
    include_raw: bool = false,
};

pub const RawTraceEvent = struct {
    path: []u8,
    line_number: usize,
    entry_type: []u8,
    event_type: ?[]u8 = null,
    timestamp: ?[]u8 = null,
    payload_json: ?[]u8 = null,
    raw_json: ?[]u8 = null,
    format: TraceFormat,

    pub fn deinit(self: *RawTraceEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.entry_type);
        if (self.event_type) |v| allocator.free(v);
        if (self.timestamp) |v| allocator.free(v);
        if (self.payload_json) |v| allocator.free(v);
        if (self.raw_json) |v| allocator.free(v);
    }
};

pub const SessionRecord = struct {
    session_id: ?[]u8 = null,
    path: []u8,
    date_group: ?[]u8 = null,
    start_time: ?[]u8 = null,
    end_time: ?[]u8 = null,
    cwd: ?[]u8 = null,
    git_branch: ?[]u8 = null,
    git_commit_hash: ?[]u8 = null,
    git_repository_url: ?[]u8 = null,
    originator: ?[]u8 = null,
    cli_version: ?[]u8 = null,
    model: ?[]u8 = null,
    model_provider: ?[]u8 = null,
    thread_name: ?[]u8 = null,
    turn_count: i64 = 0,
    total_tokens: ?i64 = null,
    input_tokens: ?i64 = null,
    cached_input_tokens: ?i64 = null,
    output_tokens: ?i64 = null,
    reasoning_output_tokens: ?i64 = null,
    is_ongoing: bool = false,
    status_reason: ?[]u8 = null,
    is_external_worker: bool = false,
    is_inline_worker: bool = false,
    spawned_worker_count: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !SessionRecord {
        return .{ .path = try allocator.dupe(u8, path) };
    }

    pub fn deinit(self: *SessionRecord, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.session_id);
        allocator.free(self.path);
        freeOpt(allocator, self.date_group);
        freeOpt(allocator, self.start_time);
        freeOpt(allocator, self.end_time);
        freeOpt(allocator, self.cwd);
        freeOpt(allocator, self.git_branch);
        freeOpt(allocator, self.git_commit_hash);
        freeOpt(allocator, self.git_repository_url);
        freeOpt(allocator, self.originator);
        freeOpt(allocator, self.cli_version);
        freeOpt(allocator, self.model);
        freeOpt(allocator, self.model_provider);
        freeOpt(allocator, self.thread_name);
        freeOpt(allocator, self.status_reason);
    }
};

pub const TurnRecord = struct {
    session_id: ?[]u8 = null,
    path: []u8,
    turn_id: []u8,
    turn_index: i64,
    started_at: ?[]u8 = null,
    completed_at: ?[]u8 = null,
    duration_ms: ?i64 = null,
    status: TurnStatus = .ongoing,
    status_reason: ?[]u8 = null,
    user_message: ?[]u8 = null,
    user_preview: ?[]u8 = null,
    final_answer: ?[]u8 = null,
    final_answer_line: ?usize = null,
    assistant_preview: ?[]u8 = null,
    model: ?[]u8 = null,
    cwd: ?[]u8 = null,
    reasoning_effort: ?[]u8 = null,
    input_tokens: ?i64 = null,
    cached_input_tokens: ?i64 = null,
    output_tokens: ?i64 = null,
    reasoning_output_tokens: ?i64 = null,
    total_tokens: ?i64 = null,
    tool_count: i64 = 0,
    has_compaction: bool = false,
    thread_name: ?[]u8 = null,
    @"error": ?[]u8 = null,
    aborted_reason: ?[]u8 = null,
    spawned_worker_count: i64 = 0,

    pub fn deinit(self: *TurnRecord, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.session_id);
        allocator.free(self.path);
        allocator.free(self.turn_id);
        freeOpt(allocator, self.started_at);
        freeOpt(allocator, self.completed_at);
        freeOpt(allocator, self.status_reason);
        freeOpt(allocator, self.user_message);
        freeOpt(allocator, self.user_preview);
        freeOpt(allocator, self.final_answer);
        freeOpt(allocator, self.assistant_preview);
        freeOpt(allocator, self.model);
        freeOpt(allocator, self.cwd);
        freeOpt(allocator, self.reasoning_effort);
        freeOpt(allocator, self.thread_name);
        freeOpt(allocator, self.@"error");
        freeOpt(allocator, self.aborted_reason);
    }
};

pub const ToolLifecycleRecord = struct {
    session_id: ?[]u8 = null,
    path: []u8,
    turn_id: ?[]u8 = null,
    turn_index: ?i64 = null,
    started_at: ?[]u8 = null,
    completed_at: ?[]u8 = null,
    call_id: ?[]u8 = null,
    kind: ToolKind = .unknown,
    tool_name: ?[]u8 = null,
    namespace: ?[]u8 = null,
    arguments_json: ?[]u8 = null,
    input_text: ?[]u8 = null,
    output_text: ?[]u8 = null,
    command_text: ?[]u8 = null,
    cwd: ?[]u8 = null,
    exit_code: ?i64 = null,
    duration_ms: ?i64 = null,
    mcp_server: ?[]u8 = null,
    mcp_tool: ?[]u8 = null,
    patch_success: ?bool = null,
    patch_changes_json: ?[]u8 = null,
    web_query: ?[]u8 = null,
    web_url: ?[]u8 = null,
    image_prompt: ?[]u8 = null,
    lifecycle_status: ToolLifecycleStatus = .unknown,
    declared_line: ?i64 = null,
    finalized_line: ?i64 = null,

    pub fn deinit(self: *ToolLifecycleRecord, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.session_id);
        allocator.free(self.path);
        freeOpt(allocator, self.turn_id);
        freeOpt(allocator, self.started_at);
        freeOpt(allocator, self.completed_at);
        freeOpt(allocator, self.call_id);
        freeOpt(allocator, self.tool_name);
        freeOpt(allocator, self.namespace);
        freeOpt(allocator, self.arguments_json);
        freeOpt(allocator, self.input_text);
        freeOpt(allocator, self.output_text);
        freeOpt(allocator, self.command_text);
        freeOpt(allocator, self.cwd);
        freeOpt(allocator, self.mcp_server);
        freeOpt(allocator, self.mcp_tool);
        freeOpt(allocator, self.patch_changes_json);
        freeOpt(allocator, self.web_query);
        freeOpt(allocator, self.web_url);
        freeOpt(allocator, self.image_prompt);
    }
};

pub const SessionGraphNode = struct {
    session_id: ?[]u8 = null,
    path: []u8,
    thread_name: ?[]u8 = null,
    cwd: ?[]u8 = null,
    model: ?[]u8 = null,
    status: ?[]u8 = null,
    is_external_worker: bool = false,
    is_inline_worker: bool = false,
};

pub const SessionGraphEdge = struct {
    parent_session_id: ?[]u8 = null,
    worker_session_id: ?[]u8 = null,
    parent_path: []u8,
    worker_path: ?[]u8 = null,
    call_id: ?[]u8 = null,
    agent_nickname: ?[]u8 = null,
    agent_role: ?[]u8 = null,
    model: ?[]u8 = null,
    reasoning_effort: ?[]u8 = null,
    spawned_at: ?[]u8 = null,
    prompt_preview: ?[]u8 = null,
    worker_status: ?[]u8 = null,

    pub fn deinit(self: *SessionGraphEdge, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.parent_session_id);
        freeOpt(allocator, self.worker_session_id);
        allocator.free(self.parent_path);
        freeOpt(allocator, self.worker_path);
        freeOpt(allocator, self.call_id);
        freeOpt(allocator, self.agent_nickname);
        freeOpt(allocator, self.agent_role);
        freeOpt(allocator, self.model);
        freeOpt(allocator, self.reasoning_effort);
        freeOpt(allocator, self.spawned_at);
        freeOpt(allocator, self.prompt_preview);
        freeOpt(allocator, self.worker_status);
    }
};

pub const TraceOccurrence = struct {
    line_number: usize,
    ordinal: usize,
    turn_index: ?i64 = null,
    entry_type: []u8,
    event_type: ?[]u8 = null,
    role: ?[]u8 = null,
    timestamp: ?[]u8 = null,
    payload_json: ?[]u8 = null,
    text: ?[]u8 = null,
    private: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        line_number: usize,
        turn_index: ?i64,
        entry_type: []const u8,
        event_type: ?[]const u8,
        role: ?[]const u8,
        text: ?[]const u8,
        private: bool,
    ) !TraceOccurrence {
        return .{
            .line_number = line_number,
            .ordinal = 0,
            .turn_index = turn_index,
            .entry_type = try allocator.dupe(u8, entry_type),
            .event_type = if (event_type) |value| try allocator.dupe(u8, value) else null,
            .role = if (role) |value| try allocator.dupe(u8, value) else null,
            .text = if (text) |value| try allocator.dupe(u8, value) else null,
            .private = private,
        };
    }

    pub fn deinit(self: *TraceOccurrence, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_type);
        freeOpt(allocator, self.event_type);
        freeOpt(allocator, self.role);
        freeOpt(allocator, self.timestamp);
        freeOpt(allocator, self.payload_json);
        freeOpt(allocator, self.text);
    }
};

pub const MessageTextPart = struct {
    text: []u8,

    pub fn deinit(self: *MessageTextPart, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub fn messageTextPartsFromPayloadAlloc(
    allocator: std.mem.Allocator,
    payload_json: []const u8,
) ![]MessageTextPart {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const payload = switch (parsed.value) {
        .object => |map| map,
        else => return error.InvalidMessagePayload,
    };
    return messageTextPartsAlloc(allocator, payload);
}

pub fn freeMessageTextParts(allocator: std.mem.Allocator, parts: []MessageTextPart) void {
    for (parts) |*part| part.deinit(allocator);
    allocator.free(parts);
}

pub const CutBoundContext = struct {
    cwd: ?[]u8 = null,
    git_commit_hash: ?[]u8 = null,
    cli_version: ?[]u8 = null,
    model: ?[]u8 = null,
    model_provider: ?[]u8 = null,
    reasoning_effort: ?[]u8 = null,
    context_window_json: ?[]u8 = null,
    compaction_identity: ?[]u8 = null,

    pub fn deinit(self: *CutBoundContext, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.cwd);
        freeOpt(allocator, self.git_commit_hash);
        freeOpt(allocator, self.cli_version);
        freeOpt(allocator, self.model);
        freeOpt(allocator, self.model_provider);
        freeOpt(allocator, self.reasoning_effort);
        freeOpt(allocator, self.context_window_json);
        freeOpt(allocator, self.compaction_identity);
    }
};

pub const CanonicalSessionTrace = struct {
    session: SessionRecord,
    turns: std.ArrayList(TurnRecord) = .empty,
    tools: std.ArrayList(ToolLifecycleRecord) = .empty,
    graph_edges: std.ArrayList(SessionGraphEdge) = .empty,
    occurrences: std.ArrayList(TraceOccurrence) = .empty,
    warnings: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *CanonicalSessionTrace, allocator: std.mem.Allocator) void {
        self.session.deinit(allocator);
        for (self.turns.items) |*turn| turn.deinit(allocator);
        self.turns.deinit(allocator);
        for (self.tools.items) |*tool| tool.deinit(allocator);
        self.tools.deinit(allocator);
        for (self.graph_edges.items) |*edge| edge.deinit(allocator);
        self.graph_edges.deinit(allocator);
        for (self.occurrences.items) |*occurrence| occurrence.deinit(allocator);
        self.occurrences.deinit(allocator);
        for (self.warnings.items) |warning| allocator.free(warning);
        self.warnings.deinit(allocator);
    }
};

pub fn parseRawTraceEvent(
    allocator: std.mem.Allocator,
    path: []const u8,
    line_number: usize,
    line: []const u8,
) !?RawTraceEvent {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    if (stringField(root, "record_type")) |record_type| {
        if (std.mem.eql(u8, record_type, "state")) return null;
    }

    var entry_type: []const u8 = "unknown";
    var event_type: ?[]const u8 = null;
    var format: TraceFormat = .unknown;

    if (stringField(root, "type")) |root_type| {
        entry_type = root_type;
        format = .new_044_plus;
        if (std.mem.eql(u8, root_type, "event_msg")) {
            if (objectField(root, "payload")) |payload| event_type = stringField(payload, "type");
        } else if (std.mem.eql(u8, root_type, "response_item")) {
            if (objectField(root, "payload")) |payload| event_type = stringField(payload, "type");
        }
    } else if (root.get("payload") != null) {
        entry_type = "payload";
        format = .mid_payload_meta;
        if (objectField(root, "payload")) |payload| event_type = stringField(payload, "type");
    } else {
        format = .old_2025_08_root_meta;
        if (root.get("id") != null and root.get("timestamp") != null) {
            entry_type = "session_meta";
        } else if (root.get("call_id") != null and root.get("arguments") != null and root.get("name") != null) {
            entry_type = "function_call";
            event_type = "function_call";
        } else if (root.get("call_id") != null and root.get("output") != null) {
            entry_type = "function_call_output";
            event_type = "function_call_output";
        } else if (root.get("role") != null and root.get("content") != null) {
            entry_type = "message";
            event_type = stringField(root, "role");
        } else if (root.get("encrypted_content") != null) {
            entry_type = "reasoning";
            event_type = "reasoning";
        } else {
            format = .unknown;
        }
    }

    const payload_json = if (root.get("payload")) |payload| try stringifyJsonValue(allocator, payload) else null;
    errdefer if (payload_json) |v| allocator.free(v);

    return .{
        .path = try allocator.dupe(u8, path),
        .line_number = line_number,
        .entry_type = try allocator.dupe(u8, entry_type),
        .event_type = if (event_type) |v| try allocator.dupe(u8, v) else null,
        .timestamp = if (bestTimestamp(root)) |v| try allocator.dupe(u8, v) else null,
        .payload_json = payload_json,
        .raw_json = try allocator.dupe(u8, trimmed),
        .format = format,
    };
}

pub fn parseSessionTrace(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: TraceParseOptions,
) !CanonicalSessionTrace {
    const file = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    const content = try reader.interface.allocRemaining(allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(content);

    return parseSessionTraceBytes(
        allocator,
        path,
        content,
        stat.mtime.nanoseconds,
        options,
    );
}

/// Parses the caller-owned immutable session bytes. The path is provenance
/// only and is never reopened. `source_mtime_ns` is observed by the caller
/// from the same held source file and is used only for ongoing-turn status.
pub fn parseSessionTraceBytes(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    source_mtime_ns: i128,
    options: TraceParseOptions,
) !CanonicalSessionTrace {
    var trace = CanonicalSessionTrace{
        .session = try SessionRecord.init(allocator, path),
    };
    errdefer trace.deinit(allocator);
    trace.session.date_group = try deriveDateGroup(allocator, path);

    var current_turn_index: ?usize = null;
    var synthetic_turns: i64 = 0;
    var saw_task_started = false;
    var saw_primary_session_meta = false;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    while (line_it.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{}) catch {
            try trace.warnings.append(allocator, try std.fmt.allocPrint(allocator, "{s}:{d}: malformed JSONL skipped", .{ path, line_number }));
            continue;
        };
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        const root_type = stringField(root, "type");
        const payload = objectField(root, "payload");
        const timestamp = bestTimestamp(root);
        const occurrence_index = try appendOccurrence(allocator, &trace, root, root_type, payload, timestamp, current_turn_index, line_number);
        if (stringField(root, "record_type")) |record_type| {
            // Preserve state carriers in the canonical occurrence stream so
            // exact-context consumers can explicitly retain or reject them.
            if (std.mem.eql(u8, record_type, "state")) continue;
        }
        if (trace.session.start_time == null) trace.session.start_time = try dupOpt(allocator, timestamp);
        if (timestamp) |ts| try replaceOpt(allocator, &trace.session.end_time, ts);

        if (root_type) |entry_type| {
            if (std.mem.eql(u8, entry_type, "session_meta")) {
                if (payload) |p| try applyPrimarySessionMeta(allocator, &trace, p, &saw_primary_session_meta, line_number);
                continue;
            }
            if (std.mem.eql(u8, entry_type, "turn_context")) {
                const idx = try ensureTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp, null);
                try applyTurnContext(allocator, &trace.turns.items[idx], payload orelse root);
                try applySessionContextFromTurn(allocator, &trace.session, trace.turns.items[idx]);
                trace.occurrences.items[occurrence_index].turn_index = @intCast(idx);
                continue;
            }
            if (std.mem.eql(u8, entry_type, "compacted")) {
                const idx = try ensureTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp, null);
                trace.turns.items[idx].has_compaction = true;
                trace.occurrences.items[occurrence_index].turn_index = @intCast(idx);
                continue;
            }
            if (std.mem.eql(u8, entry_type, "event_msg")) {
                if (payload) |p| {
                    const event_type = stringField(p, "type") orelse "";
                    if (std.mem.eql(u8, event_type, "task_started")) {
                        saw_task_started = true;
                        const idx = try startTurn(allocator, &trace, path, &current_turn_index, stringField(p, "turn_id"), timestamp);
                        trace.turns.items[idx].status_reason = try dupReplace(allocator, trace.turns.items[idx].status_reason, "task_started");
                    } else if (std.mem.eql(u8, event_type, "user_message")) {
                        const idx = try ensureTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp, stringField(p, "turn_id"));
                        const msg = stringField(p, "message") orelse stringField(p, "text") orelse "";
                        try replaceUserMessage(allocator, &trace.turns.items[idx], msg);
                    } else if (std.mem.eql(u8, event_type, "agent_message")) {
                        const idx = try ensureTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp, stringField(p, "turn_id"));
                        const msg = stringField(p, "message") orelse stringField(p, "text") orelse "";
                        try attachAssistantMessage(allocator, &trace.turns.items[idx], msg, line_number);
                    } else if (std.mem.eql(u8, event_type, "task_complete")) {
                        if (current_turn_index) |idx| try completeTurn(allocator, &trace.turns.items[idx], .complete, "task_complete", timestamp, p);
                    } else if (std.mem.eql(u8, event_type, "turn_aborted")) {
                        if (current_turn_index) |idx| {
                            try completeTurn(allocator, &trace.turns.items[idx], .aborted, "turn_aborted", timestamp, p);
                            try replaceOpt(allocator, &trace.turns.items[idx].aborted_reason, stringField(p, "reason") orelse "turn_aborted");
                        }
                    } else if (std.mem.eql(u8, event_type, "error")) {
                        const idx = try ensureTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp, stringField(p, "turn_id"));
                        try completeTurn(allocator, &trace.turns.items[idx], .@"error", "error", timestamp, p);
                        try replaceOpt(allocator, &trace.turns.items[idx].@"error", stringField(p, "message") orelse stringField(p, "error") orelse "error");
                    } else if (std.mem.eql(u8, event_type, "token_count")) {
                        const idx = try ensureTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp, stringField(p, "turn_id"));
                        applyTokenCount(&trace.turns.items[idx], &trace.session, p);
                    } else if (std.mem.eql(u8, event_type, "thread_name_updated")) {
                        const name = stringField(p, "thread_name") orelse stringField(p, "name");
                        if (name) |value| {
                            try replaceOpt(allocator, &trace.session.thread_name, value);
                            if (current_turn_index) |idx| try replaceOpt(allocator, &trace.turns.items[idx].thread_name, value);
                        }
                    } else if (std.mem.endsWith(u8, event_type, "_end")) {
                        const idx = try ensureTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp, stringField(p, "turn_id"));
                        try finalizeToolEvent(allocator, &trace, idx, p, event_type, timestamp, line_number);
                    }
                }
                if (current_turn_index) |idx| trace.occurrences.items[occurrence_index].turn_index = @intCast(idx);
                continue;
            }
            if (std.mem.eql(u8, entry_type, "response_item")) {
                if (payload) |p| try applyResponseItem(allocator, &trace, path, &current_turn_index, &synthetic_turns, saw_task_started, p, timestamp, line_number);
                if (current_turn_index) |idx| trace.occurrences.items[occurrence_index].turn_index = @intCast(idx);
                continue;
            }
        }

        if (root_type == null and payload != null) {
            const p = payload.?;
            if (stringField(p, "type")) |payload_type| {
                if (std.mem.eql(u8, payload_type, "session_meta")) try applyPrimarySessionMeta(allocator, &trace, p, &saw_primary_session_meta, line_number);
            }
            continue;
        }

        if (root_type == null) {
            if (root.get("id") != null and root.get("timestamp") != null) {
                try applyPrimarySessionMeta(allocator, &trace, root, &saw_primary_session_meta, line_number);
            } else if (root.get("role") != null and root.get("content") != null) {
                const role = stringField(root, "role") orelse "";
                if (std.mem.eql(u8, role, "user")) {
                    const idx = try startSyntheticTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp);
                    const text = try messageTextAlloc(allocator, root);
                    defer allocator.free(text);
                    try attachUserMessage(allocator, &trace.turns.items[idx], text);
                } else if (std.mem.eql(u8, role, "assistant")) {
                    const idx = try ensureTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp, null);
                    const text = try messageTextAlloc(allocator, root);
                    defer allocator.free(text);
                    try attachAssistantMessage(allocator, &trace.turns.items[idx], text, line_number);
                    try completeTurn(allocator, &trace.turns.items[idx], .complete, "synthetic_message_boundary", timestamp, root);
                }
            } else if (root.get("call_id") != null and root.get("arguments") != null and root.get("name") != null) {
                const idx = try ensureTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp, null);
                try declareTool(allocator, &trace, idx, root, timestamp, line_number);
            } else if (root.get("call_id") != null and root.get("output") != null) {
                const idx = try ensureTurn(allocator, &trace, path, &current_turn_index, &synthetic_turns, timestamp, null);
                try finalizeToolOutput(allocator, &trace, idx, root, "function_call_output", timestamp, line_number);
            }
            if (current_turn_index) |idx| trace.occurrences.items[occurrence_index].turn_index = @intCast(idx);
        }
    }

    const now_ns = nowRealtimeNs();
    const age_secs = @divTrunc(now_ns - source_mtime_ns, std.time.ns_per_s);
    for (trace.turns.items) |*turn| {
        if (turn.status == .ongoing) {
            if (age_secs <= options.ongoing_threshold_secs) {
                turn.status_reason = try dupReplace(allocator, turn.status_reason, "fresh_ongoing_turn");
                trace.session.is_ongoing = true;
                try replaceOpt(allocator, &trace.session.status_reason, "fresh_ongoing_turn");
            } else {
                turn.status = .aborted;
                turn.status_reason = try dupReplace(allocator, turn.status_reason, "stale_ongoing_file");
                try replaceOpt(allocator, &trace.session.status_reason, "stale_ongoing_file");
            }
        }
    }
    if (!trace.session.is_ongoing and trace.session.status_reason == null) {
        if (trace.turns.items.len == 0) {
            try replaceOpt(allocator, &trace.session.status_reason, "no_turns");
        } else {
            const last = trace.turns.items[trace.turns.items.len - 1];
            try replaceOpt(allocator, &trace.session.status_reason, last.status_reason orelse @tagName(last.status));
        }
    }

    for (trace.tools.items) |*tool| {
        if (tool.lifecycle_status == .declared) tool.lifecycle_status = .unresolved;
    }
    trace.session.turn_count = @intCast(trace.turns.items.len);
    return trace;
}

pub fn parseSessionSummaryTrace(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: TraceParseOptions,
) !CanonicalSessionTrace {
    const file = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    const content = try reader.interface.allocRemaining(allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(content);

    var trace = CanonicalSessionTrace{
        .session = try SessionRecord.init(allocator, path),
    };
    errdefer trace.deinit(allocator);
    trace.session.date_group = try deriveDateGroup(allocator, path);

    var seen_turn_ids = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen_turn_ids.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen_turn_ids.deinit();
    }

    var last_turn_open = false;
    var saw_primary_session_meta = false;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    while (line_it.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        if (fastTimestampSlice(line)) |ts| {
            if (trace.session.start_time == null) trace.session.start_time = try allocator.dupe(u8, ts);
            try replaceOpt(allocator, &trace.session.end_time, ts);
        }
        if (!sessionSummaryLineCouldMatter(line)) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{}) catch {
            try trace.warnings.append(allocator, try std.fmt.allocPrint(allocator, "{s}:{d}: malformed JSONL skipped", .{ path, line_number }));
            continue;
        };
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        if (stringField(root, "record_type")) |record_type| {
            if (std.mem.eql(u8, record_type, "state")) continue;
        }

        const root_type = stringField(root, "type");
        const payload = objectField(root, "payload");
        const timestamp = bestTimestamp(root);
        if (trace.session.start_time == null) trace.session.start_time = try dupOpt(allocator, timestamp);
        if (timestamp) |ts| try replaceOpt(allocator, &trace.session.end_time, ts);

        if (root_type) |entry_type| {
            if (std.mem.eql(u8, entry_type, "session_meta")) {
                if (payload) |p| try applyPrimarySessionMeta(allocator, &trace, p, &saw_primary_session_meta, line_number);
                continue;
            }
            if (std.mem.eql(u8, entry_type, "turn_context")) {
                if (payload) |p| try applySessionContextFields(allocator, &trace.session, p);
                continue;
            }
            if (std.mem.eql(u8, entry_type, "event_msg")) {
                const p = payload orelse continue;
                const event_type = stringField(p, "type") orelse "";
                if (std.mem.eql(u8, event_type, "task_started")) {
                    try noteSummaryTurn(allocator, &trace.session, &seen_turn_ids, stringField(p, "turn_id"));
                    last_turn_open = true;
                    try replaceOpt(allocator, &trace.session.status_reason, "task_started");
                } else if (std.mem.eql(u8, event_type, "task_complete")) {
                    last_turn_open = false;
                    try replaceOpt(allocator, &trace.session.status_reason, "task_complete");
                } else if (std.mem.eql(u8, event_type, "turn_aborted")) {
                    last_turn_open = false;
                    try replaceOpt(allocator, &trace.session.status_reason, stringField(p, "reason") orelse "turn_aborted");
                } else if (std.mem.eql(u8, event_type, "error")) {
                    try noteSummaryTurn(allocator, &trace.session, &seen_turn_ids, stringField(p, "turn_id"));
                    last_turn_open = false;
                    try replaceOpt(allocator, &trace.session.status_reason, stringField(p, "message") orelse stringField(p, "error") orelse "error");
                } else if (std.mem.eql(u8, event_type, "token_count")) {
                    applyTokenCountToSession(&trace.session, p);
                } else if (std.mem.eql(u8, event_type, "thread_name_updated")) {
                    const name = stringField(p, "thread_name") orelse stringField(p, "name");
                    if (name) |value| try replaceOpt(allocator, &trace.session.thread_name, value);
                } else if (std.mem.eql(u8, event_type, "collab_agent_spawn_end")) {
                    try appendGraphEdge(allocator, &trace, p, timestamp);
                    trace.session.spawned_worker_count += 1;
                }
                continue;
            }
        }

        if (root_type == null and payload != null) {
            const p = payload.?;
            if (stringField(p, "type")) |payload_type| {
                if (std.mem.eql(u8, payload_type, "session_meta")) try applyPrimarySessionMeta(allocator, &trace, p, &saw_primary_session_meta, line_number);
            }
            continue;
        }

        if (root_type == null and root.get("id") != null and root.get("timestamp") != null) {
            try applyPrimarySessionMeta(allocator, &trace, root, &saw_primary_session_meta, line_number);
        }
    }

    const now_ns = nowRealtimeNs();
    const age_secs = @divTrunc(now_ns - stat.mtime.nanoseconds, std.time.ns_per_s);
    if (last_turn_open) {
        if (age_secs <= options.ongoing_threshold_secs) {
            trace.session.is_ongoing = true;
            try replaceOpt(allocator, &trace.session.status_reason, "fresh_ongoing_turn");
        } else {
            try replaceOpt(allocator, &trace.session.status_reason, "stale_ongoing_file");
        }
    }
    if (!trace.session.is_ongoing and trace.session.status_reason == null) {
        if (trace.session.turn_count == 0) {
            try replaceOpt(allocator, &trace.session.status_reason, "no_turns");
        } else {
            try replaceOpt(allocator, &trace.session.status_reason, "task_complete");
        }
    }
    return trace;
}

fn appendOccurrence(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    root: std.json.ObjectMap,
    root_type: ?[]const u8,
    payload: ?std.json.ObjectMap,
    timestamp: ?[]const u8,
    current_turn_index: ?usize,
    line_number: usize,
) !usize {
    const source = payload orelse root;
    const source_type = stringField(source, "type");
    const record_type = stringField(root, "record_type");
    const entry_type = if (record_type) |kind|
        if (std.mem.eql(u8, kind, "state")) "state" else "unknown"
    else
        root_type orelse if (source_type) |kind|
            if (oneOfString(kind, &.{ "session_meta", "turn_context", "compacted", "event_msg", "response_item", "world_state" })) kind else "unknown"
        else if (root.get("id") != null and root.get("timestamp") != null)
            "session_meta"
        else if (root.get("role") != null)
            "message"
        else if (root.get("call_id") != null and root.get("arguments") != null)
            "function_call"
        else if (root.get("call_id") != null and root.get("output") != null)
            "function_call_output"
        else if (root.get("encrypted_content") != null)
            "reasoning"
        else
            "unknown";
    const event_type = stringField(source, "type") orelse if (std.mem.eql(u8, entry_type, "message")) stringField(source, "role") else null;
    const role = stringField(source, "role") orelse if (std.mem.eql(u8, entry_type, "event_msg")) blk: {
        const kind = event_type orelse "";
        if (std.mem.eql(u8, kind, "user_message")) break :blk "user";
        if (std.mem.eql(u8, kind, "agent_message")) break :blk "assistant";
        break :blk null;
    } else null;
    const private = std.mem.eql(u8, entry_type, "reasoning") or std.mem.eql(u8, event_type orelse "", "reasoning");

    var text: ?[]u8 = null;
    errdefer freeOpt(allocator, text);
    if (!private) {
        if ((std.mem.eql(u8, entry_type, "response_item") and std.mem.eql(u8, event_type orelse "", "message")) or
            std.mem.eql(u8, entry_type, "message"))
        {
            text = try messageTextAlloc(allocator, source);
        } else if (std.mem.eql(u8, entry_type, "event_msg") and
            (std.mem.eql(u8, event_type orelse "", "user_message") or std.mem.eql(u8, event_type orelse "", "agent_message")))
        {
            text = try allocator.dupe(u8, stringField(source, "message") orelse stringField(source, "text") orelse "");
        }
    }

    var occurrence = try TraceOccurrence.init(
        allocator,
        line_number,
        if (current_turn_index) |index| @intCast(index) else null,
        entry_type,
        event_type,
        role,
        text,
        private,
    );
    errdefer occurrence.deinit(allocator);
    freeOpt(allocator, text);
    text = null;
    occurrence.ordinal = trace.occurrences.items.len;
    occurrence.timestamp = if (timestamp) |value| try allocator.dupe(u8, value) else null;
    occurrence.payload_json = if (!private) try stringifyJsonValue(allocator, if (payload != null) root.get("payload").? else std.json.Value{ .object = root }) else null;
    try trace.occurrences.append(allocator, occurrence);
    return trace.occurrences.items.len - 1;
}

pub fn cutBoundContextAlloc(allocator: std.mem.Allocator, trace: CanonicalSessionTrace, last_fixed_line: usize) !CutBoundContext {
    var context = CutBoundContext{};
    errdefer context.deinit(allocator);
    var saw_primary_meta = false;
    for (trace.occurrences.items) |occurrence| {
        if (occurrence.line_number > last_fixed_line) break;
        const payload_json = occurrence.payload_json orelse continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch continue;
        defer parsed.deinit();
        const payload = switch (parsed.value) {
            .object => |map| map,
            else => continue,
        };
        if (std.mem.eql(u8, occurrence.entry_type, "session_meta")) {
            if (saw_primary_meta) continue;
            saw_primary_meta = true;
            if (stringField(payload, "cwd")) |value| try replaceOpt(allocator, &context.cwd, value);
            if (stringField(payload, "cli_version")) |value| try replaceOpt(allocator, &context.cli_version, value);
            if (stringField(payload, "model")) |value| try replaceOpt(allocator, &context.model, value);
            if (stringField(payload, "model_provider")) |value| try replaceOpt(allocator, &context.model_provider, value);
            if (stringField(payload, "git_commit_hash")) |value| try replaceOpt(allocator, &context.git_commit_hash, value);
            if (objectField(payload, "git")) |git| if (stringField(git, "commit_hash")) |value| try replaceOpt(allocator, &context.git_commit_hash, value);
            if (payload.get("context_window")) |value| {
                const encoded = try stringifyJsonValue(allocator, value);
                defer allocator.free(encoded);
                try replaceOpt(allocator, &context.context_window_json, encoded);
            }
        } else if (std.mem.eql(u8, occurrence.entry_type, "turn_context")) {
            if (stringField(payload, "cwd")) |value| try replaceOpt(allocator, &context.cwd, value);
            if (stringField(payload, "model")) |value| try replaceOpt(allocator, &context.model, value);
            if (stringField(payload, "model_provider")) |value| try replaceOpt(allocator, &context.model_provider, value);
            if (stringField(payload, "reasoning_effort") orelse stringField(payload, "effort")) |value| try replaceOpt(allocator, &context.reasoning_effort, value);
            if (stringField(payload, "comp_hash")) |value| try replaceOpt(allocator, &context.compaction_identity, value);
        }
    }
    return context;
}

fn oneOfString(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn sessionSummaryLineCouldMatter(line: []const u8) bool {
    const prefix = line[0..@min(line.len, 96)];
    if (std.mem.indexOf(u8, prefix, "\"type\":\"response_item\"") != null) return false;
    if (std.mem.indexOf(u8, prefix, "\"type\":\"session_meta\"") != null) return true;
    if (std.mem.indexOf(u8, prefix, "\"type\":\"turn_context\"") != null) return true;
    if (std.mem.indexOf(u8, prefix, "\"type\":\"event_msg\"") != null) {
        return std.mem.containsAtLeast(u8, line, 1, "task_started") or
            std.mem.containsAtLeast(u8, line, 1, "task_complete") or
            std.mem.containsAtLeast(u8, line, 1, "turn_aborted") or
            std.mem.containsAtLeast(u8, line, 1, "token_count") or
            std.mem.containsAtLeast(u8, line, 1, "thread_name_updated") or
            std.mem.containsAtLeast(u8, line, 1, "collab_agent_spawn_end") or
            std.mem.containsAtLeast(u8, line, 1, "\"error\"");
    }
    return std.mem.containsAtLeast(u8, line, 1, "\"id\"") and
        std.mem.containsAtLeast(u8, line, 1, "\"timestamp\"");
}

fn fastTimestampSlice(line: []const u8) ?[]const u8 {
    const key = "\"timestamp\"";
    const pos = std.mem.indexOf(u8, line, key) orelse return null;
    var i = pos + key.len;
    while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
    if (i >= line.len or line[i] != ':') return null;
    i += 1;
    while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
    if (i >= line.len or line[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < line.len and line[i] != '"') : (i += 1) {
        if (line[i] == '\\') return null;
    }
    if (i >= line.len) return null;
    return line[start..i];
}

fn applySessionContextFields(allocator: std.mem.Allocator, session: *SessionRecord, ctx: std.json.ObjectMap) !void {
    if (session.model == null) if (stringField(ctx, "model")) |v| try replaceOpt(allocator, &session.model, v);
    if (session.cwd == null) if (stringField(ctx, "cwd")) |v| try replaceOpt(allocator, &session.cwd, v);
}

fn noteSummaryTurn(
    allocator: std.mem.Allocator,
    session: *SessionRecord,
    seen_turn_ids: *std.StringHashMap(void),
    turn_id_opt: ?[]const u8,
) !void {
    if (turn_id_opt) |turn_id| {
        if (seen_turn_ids.contains(turn_id)) return;
        try seen_turn_ids.put(try allocator.dupe(u8, turn_id), {});
    }
    session.turn_count += 1;
}

fn applyTokenCountToSession(session: *SessionRecord, payload: std.json.ObjectMap) void {
    const info = objectField(payload, "info") orelse payload;
    const total = objectField(info, "total_token_usage") orelse objectField(info, "last_token_usage") orelse return;
    if (intField(total, "input_tokens")) |v| session.input_tokens = v;
    if (intField(total, "cached_input_tokens")) |v| session.cached_input_tokens = v;
    if (intField(total, "output_tokens")) |v| session.output_tokens = v;
    if (intField(total, "reasoning_output_tokens")) |v| session.reasoning_output_tokens = v;
    if (intField(total, "total_tokens")) |v| session.total_tokens = v;
}

fn objectField(root: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = root.get(key) orelse return null;
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn stringField(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = root.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn valueArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |arr| arr,
        else => null,
    };
}

fn intField(root: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = root.get(key) orelse return null;
    return switch (value) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        else => null,
    };
}

fn boolField(root: std.json.ObjectMap, key: []const u8) ?bool {
    const value = root.get(key) orelse return null;
    return switch (value) {
        .bool => |v| v,
        else => null,
    };
}

fn nestedObject(root: std.json.ObjectMap, a: []const u8, b: []const u8) ?std.json.ObjectMap {
    const first = objectField(root, a) orelse return null;
    return objectField(first, b);
}

fn dupOpt(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn replaceOpt(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = try allocator.dupe(u8, value);
}

fn dupReplace(allocator: std.mem.Allocator, old: ?[]u8, value: []const u8) ![]u8 {
    if (old) |v| allocator.free(v);
    return allocator.dupe(u8, value);
}

fn deriveDateGroup(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var i: usize = 0;
    while (i + 10 <= path.len) : (i += 1) {
        if (i > 0 and path[i - 1] != '/') continue;
        if (i + 10 < path.len and path[i + 10] != '/') continue;
        if (std.ascii.isDigit(path[i]) and std.ascii.isDigit(path[i + 1]) and
            std.ascii.isDigit(path[i + 2]) and std.ascii.isDigit(path[i + 3]) and
            path[i + 4] == '/' and std.ascii.isDigit(path[i + 5]) and
            std.ascii.isDigit(path[i + 6]) and path[i + 7] == '/' and
            std.ascii.isDigit(path[i + 8]) and std.ascii.isDigit(path[i + 9]))
        {
            return try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ path[i .. i + 4], path[i + 5 .. i + 7], path[i + 8 .. i + 10] });
        }
    }
    return null;
}

fn applySessionMeta(allocator: std.mem.Allocator, session: *SessionRecord, meta: std.json.ObjectMap) !void {
    if (stringField(meta, "id")) |v| try replaceOpt(allocator, &session.session_id, v);
    if (stringField(meta, "cwd")) |v| try replaceOpt(allocator, &session.cwd, v);
    if (stringField(meta, "originator")) |v| try replaceOpt(allocator, &session.originator, v);
    if (stringField(meta, "cli_version")) |v| try replaceOpt(allocator, &session.cli_version, v);
    if (stringField(meta, "model")) |v| try replaceOpt(allocator, &session.model, v);
    if (stringField(meta, "model_provider")) |v| try replaceOpt(allocator, &session.model_provider, v);
    if (stringField(meta, "thread_name")) |v| try replaceOpt(allocator, &session.thread_name, v);
    if (stringField(meta, "git_branch")) |v| try replaceOpt(allocator, &session.git_branch, v);
    if (stringField(meta, "git_commit_hash")) |v| try replaceOpt(allocator, &session.git_commit_hash, v);
    if (stringField(meta, "git_repository_url")) |v| try replaceOpt(allocator, &session.git_repository_url, v);
    if (nestedObject(meta, "source", "subagent")) |_| session.is_external_worker = true;
    if (objectField(meta, "git")) |git| {
        if (stringField(git, "branch")) |v| try replaceOpt(allocator, &session.git_branch, v);
        if (stringField(git, "commit_hash")) |v| try replaceOpt(allocator, &session.git_commit_hash, v);
        if (stringField(git, "repository_url")) |v| try replaceOpt(allocator, &session.git_repository_url, v);
    }
}

fn applyPrimarySessionMeta(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    meta: std.json.ObjectMap,
    seen: *bool,
    line_number: usize,
) !void {
    if (!seen.*) {
        try applySessionMeta(allocator, &trace.session, meta);
        seen.* = true;
        return;
    }
    const later_id = stringField(meta, "id") orelse return;
    const primary_id = trace.session.session_id orelse return;
    if (!std.mem.eql(u8, later_id, primary_id)) {
        try trace.warnings.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}:{d}: conflicting later session_meta {s} preserved as an occurrence; primary session {s} remains authoritative",
            .{ trace.session.path, line_number, later_id, primary_id },
        ));
    }
}

fn applyTurnContext(allocator: std.mem.Allocator, turn: *TurnRecord, ctx: std.json.ObjectMap) !void {
    if (stringField(ctx, "model")) |v| try replaceOpt(allocator, &turn.model, v);
    if (stringField(ctx, "cwd")) |v| try replaceOpt(allocator, &turn.cwd, v);
    if (stringField(ctx, "reasoning_effort") orelse stringField(ctx, "effort")) |v| try replaceOpt(allocator, &turn.reasoning_effort, v);
}

fn applySessionContextFromTurn(allocator: std.mem.Allocator, session: *SessionRecord, turn: TurnRecord) !void {
    if (session.model == null) if (turn.model) |v| try replaceOpt(allocator, &session.model, v);
    if (session.cwd == null) if (turn.cwd) |v| try replaceOpt(allocator, &session.cwd, v);
}

fn startTurn(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    path: []const u8,
    current_turn_index: *?usize,
    turn_id_opt: ?[]const u8,
    timestamp: ?[]const u8,
) !usize {
    var owned_id: ?[]u8 = null;
    defer if (owned_id) |v| allocator.free(v);
    const turn_id = turn_id_opt orelse blk: {
        owned_id = try std.fmt.allocPrint(allocator, "turn-{d}", .{trace.turns.items.len + 1});
        break :blk owned_id.?;
    };
    var turn = TurnRecord{
        .session_id = try dupOpt(allocator, trace.session.session_id),
        .path = try allocator.dupe(u8, path),
        .turn_id = try allocator.dupe(u8, turn_id),
        .turn_index = @intCast(trace.turns.items.len + 1),
        .started_at = try dupOpt(allocator, timestamp),
        .status = .ongoing,
    };
    errdefer turn.deinit(allocator);
    if (trace.session.thread_name) |name| turn.thread_name = try allocator.dupe(u8, name);
    try trace.turns.append(allocator, turn);
    current_turn_index.* = trace.turns.items.len - 1;
    return current_turn_index.*.?;
}

fn startSyntheticTurn(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    path: []const u8,
    current_turn_index: *?usize,
    synthetic_turns: *i64,
    timestamp: ?[]const u8,
) !usize {
    synthetic_turns.* += 1;
    const turn_id = try std.fmt.allocPrint(allocator, "turn-{d}", .{synthetic_turns.*});
    defer allocator.free(turn_id);
    return startTurn(allocator, trace, path, current_turn_index, turn_id, timestamp);
}

fn ensureTurn(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    path: []const u8,
    current_turn_index: *?usize,
    synthetic_turns: *i64,
    timestamp: ?[]const u8,
    turn_id: ?[]const u8,
) !usize {
    if (turn_id) |id| {
        for (trace.turns.items, 0..) |turn, idx| {
            if (std.mem.eql(u8, turn.turn_id, id)) {
                current_turn_index.* = idx;
                return idx;
            }
        }
    }
    if (current_turn_index.*) |idx| return idx;
    return startSyntheticTurn(allocator, trace, path, current_turn_index, synthetic_turns, timestamp);
}

fn attachUserMessage(allocator: std.mem.Allocator, turn: *TurnRecord, text: []const u8) !void {
    if (turn.user_message == null) {
        turn.user_message = try allocator.dupe(u8, text);
        turn.user_preview = try previewAlloc(allocator, text);
    }
}

fn replaceUserMessage(allocator: std.mem.Allocator, turn: *TurnRecord, text: []const u8) !void {
    if (turn.user_message) |old| allocator.free(old);
    turn.user_message = try allocator.dupe(u8, text);
    if (turn.user_preview) |old| allocator.free(old);
    turn.user_preview = try previewAlloc(allocator, text);
}

fn attachAssistantMessage(allocator: std.mem.Allocator, turn: *TurnRecord, text: []const u8, line_number: usize) !void {
    if (turn.final_answer) |old| allocator.free(old);
    turn.final_answer = try allocator.dupe(u8, text);
    turn.final_answer_line = line_number;
    if (turn.assistant_preview) |old| allocator.free(old);
    turn.assistant_preview = try previewAlloc(allocator, text);
}

fn completeTurn(allocator: std.mem.Allocator, turn: *TurnRecord, status: TurnStatus, reason: []const u8, timestamp: ?[]const u8, payload: std.json.ObjectMap) !void {
    turn.status = status;
    turn.status_reason = try dupReplace(allocator, turn.status_reason, reason);
    if (timestamp) |ts| try replaceOpt(allocator, &turn.completed_at, ts);
    if (intField(payload, "duration_ms")) |v| turn.duration_ms = v;
    if (intField(payload, "duration")) |v| turn.duration_ms = v;
    if (intField(payload, "duration_secs")) |v| turn.duration_ms = v * 1000;
}

fn applyTokenCount(turn: *TurnRecord, session: *SessionRecord, payload: std.json.ObjectMap) void {
    const info = objectField(payload, "info") orelse payload;
    const total = objectField(info, "total_token_usage") orelse objectField(info, "last_token_usage") orelse return;
    if (intField(total, "input_tokens")) |v| {
        turn.input_tokens = v;
        session.input_tokens = v;
    }
    if (intField(total, "cached_input_tokens")) |v| {
        turn.cached_input_tokens = v;
        session.cached_input_tokens = v;
    }
    if (intField(total, "output_tokens")) |v| {
        turn.output_tokens = v;
        session.output_tokens = v;
    }
    if (intField(total, "reasoning_output_tokens")) |v| {
        turn.reasoning_output_tokens = v;
        session.reasoning_output_tokens = v;
    }
    if (intField(total, "total_tokens")) |v| {
        turn.total_tokens = v;
        session.total_tokens = v;
    }
}

fn applyResponseItem(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    path: []const u8,
    current_turn_index: *?usize,
    synthetic_turns: *i64,
    saw_task_started: bool,
    payload: std.json.ObjectMap,
    timestamp: ?[]const u8,
    line_number: usize,
) !void {
    const payload_type = stringField(payload, "type") orelse return;
    if (std.mem.eql(u8, payload_type, "message")) {
        const role = stringField(payload, "role") orelse "";
        const idx = if (std.mem.eql(u8, role, "user") and !saw_task_started)
            try startSyntheticTurn(allocator, trace, path, current_turn_index, synthetic_turns, timestamp)
        else
            try ensureTurn(allocator, trace, path, current_turn_index, synthetic_turns, timestamp, stringField(payload, "turn_id"));
        const text = try messageTextAlloc(allocator, payload);
        defer allocator.free(text);
        if (std.mem.eql(u8, role, "user")) {
            try attachUserMessage(allocator, &trace.turns.items[idx], text);
        } else if (std.mem.eql(u8, role, "assistant")) {
            try attachAssistantMessage(allocator, &trace.turns.items[idx], text, line_number);
        }
        return;
    }
    const idx = try ensureTurn(allocator, trace, path, current_turn_index, synthetic_turns, timestamp, stringField(payload, "turn_id"));
    if (std.mem.eql(u8, payload_type, "function_call") or std.mem.eql(u8, payload_type, "custom_tool_call")) {
        try declareTool(allocator, trace, idx, payload, timestamp, line_number);
    } else if (std.mem.eql(u8, payload_type, "function_call_output") or std.mem.eql(u8, payload_type, "custom_tool_call_output")) {
        try finalizeToolOutput(allocator, trace, idx, payload, payload_type, timestamp, line_number);
    }
}

fn messageTextAlloc(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    const parts = try messageTextPartsAlloc(allocator, obj);
    defer freeMessageTextParts(allocator, parts);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (parts) |part| try out.appendSlice(allocator, part.text);
    return out.toOwnedSlice(allocator);
}

fn messageTextPartsAlloc(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]MessageTextPart {
    var parts = std.ArrayList(MessageTextPart).empty;
    errdefer {
        for (parts.items) |*part| part.deinit(allocator);
        parts.deinit(allocator);
    }
    if (stringField(obj, "content")) |text| {
        const owned = try allocator.dupe(u8, text);
        errdefer allocator.free(owned);
        try parts.append(allocator, .{ .text = owned });
        return parts.toOwnedSlice(allocator);
    }
    const content = obj.get("content") orelse return parts.toOwnedSlice(allocator);
    const arr = valueArray(content) orelse return parts.toOwnedSlice(allocator);
    for (arr.items) |part| {
        const part_obj = valueObject(part) orelse continue;
        const part_type = stringField(part_obj, "type") orelse "";
        if (!std.mem.eql(u8, part_type, "input_text") and !std.mem.eql(u8, part_type, "output_text") and !std.mem.eql(u8, part_type, "text")) continue;
        if (stringField(part_obj, "text")) |text| {
            const owned = try allocator.dupe(u8, text);
            errdefer allocator.free(owned);
            try parts.append(allocator, .{ .text = owned });
        }
    }
    return parts.toOwnedSlice(allocator);
}

test "message text-part projection preserves ordered source boundaries" {
    const split =
        "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"a\"},{\"type\":\"input_text\",\"text\":\"b\"}]}";
    const joined =
        "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"ab\"}]}";
    const split_parts = try messageTextPartsFromPayloadAlloc(std.testing.allocator, split);
    defer freeMessageTextParts(std.testing.allocator, split_parts);
    const joined_parts = try messageTextPartsFromPayloadAlloc(std.testing.allocator, joined);
    defer freeMessageTextParts(std.testing.allocator, joined_parts);
    try std.testing.expectEqual(@as(usize, 2), split_parts.len);
    try std.testing.expectEqualStrings("a", split_parts[0].text);
    try std.testing.expectEqualStrings("b", split_parts[1].text);
    try std.testing.expectEqual(@as(usize, 1), joined_parts.len);
    try std.testing.expectEqualStrings("ab", joined_parts[0].text);
}

fn previewAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = @min(trimmed.len, 120);
    return allocator.dupe(u8, trimmed[0..end]);
}

fn findToolByCallId(trace: *CanonicalSessionTrace, call_id: []const u8) ?usize {
    var idx = trace.tools.items.len;
    while (idx > 0) {
        idx -= 1;
        const existing = trace.tools.items[idx].call_id orelse continue;
        if (std.mem.eql(u8, existing, call_id)) return idx;
    }
    return null;
}

fn declareTool(allocator: std.mem.Allocator, trace: *CanonicalSessionTrace, turn_idx: usize, payload: std.json.ObjectMap, timestamp: ?[]const u8, line_number: usize) !void {
    const call_id = stringField(payload, "call_id") orelse stringField(payload, "id") orelse return;
    if (findToolByCallId(trace, call_id)) |_| return;
    const name = stringField(payload, "name") orelse stringField(payload, "tool_name") orelse "unknown";
    var record = ToolLifecycleRecord{
        .session_id = try dupOpt(allocator, trace.session.session_id),
        .path = try allocator.dupe(u8, trace.session.path),
        .turn_id = try allocator.dupe(u8, trace.turns.items[turn_idx].turn_id),
        .turn_index = trace.turns.items[turn_idx].turn_index,
        .started_at = try dupOpt(allocator, timestamp),
        .call_id = try allocator.dupe(u8, call_id),
        .kind = kindFromName(name),
        .tool_name = try allocator.dupe(u8, name),
        .namespace = try namespaceFromName(allocator, name),
        .arguments_json = if (stringField(payload, "arguments")) |v| try allocator.dupe(u8, v) else null,
        .input_text = if (stringField(payload, "input")) |v| try allocator.dupe(u8, v) else null,
        .lifecycle_status = .declared,
        .declared_line = @intCast(line_number),
    };
    errdefer record.deinit(allocator);
    if (record.arguments_json) |args| try parseExecArgsIntoRecord(allocator, &record, args);
    trace.turns.items[turn_idx].tool_count += 1;
    try trace.tools.append(allocator, record);
}

fn finalizeToolEvent(allocator: std.mem.Allocator, trace: *CanonicalSessionTrace, turn_idx: usize, payload: std.json.ObjectMap, event_type: []const u8, timestamp: ?[]const u8, line_number: usize) !void {
    try finalizeToolOutput(allocator, trace, turn_idx, payload, event_type, timestamp, line_number);
    if (std.mem.eql(u8, event_type, "collab_agent_spawn_end")) {
        try appendGraphEdge(allocator, trace, payload, timestamp);
        trace.turns.items[turn_idx].spawned_worker_count += 1;
        trace.session.spawned_worker_count += 1;
    }
}

fn finalizeToolOutput(allocator: std.mem.Allocator, trace: *CanonicalSessionTrace, turn_idx: usize, payload: std.json.ObjectMap, event_type: []const u8, timestamp: ?[]const u8, line_number: usize) !void {
    const call_id = stringField(payload, "call_id") orelse stringField(payload, "id") orelse event_type;
    const idx = findToolByCallId(trace, call_id) orelse blk: {
        var record = ToolLifecycleRecord{
            .session_id = try dupOpt(allocator, trace.session.session_id),
            .path = try allocator.dupe(u8, trace.session.path),
            .turn_id = try allocator.dupe(u8, trace.turns.items[turn_idx].turn_id),
            .turn_index = trace.turns.items[turn_idx].turn_index,
            .completed_at = try dupOpt(allocator, timestamp),
            .call_id = try allocator.dupe(u8, call_id),
            .lifecycle_status = .inferred,
        };
        errdefer record.deinit(allocator);
        try trace.tools.append(allocator, record);
        trace.turns.items[turn_idx].tool_count += 1;
        break :blk trace.tools.items.len - 1;
    };
    var rec = &trace.tools.items[idx];
    rec.kind = kindFromEndEvent(event_type, rec.tool_name);
    rec.finalized_line = @intCast(line_number);
    if (timestamp) |ts| try replaceOpt(allocator, &rec.completed_at, ts);
    try replaceOpt(allocator, &rec.output_text, stringField(payload, "output") orelse stringField(payload, "aggregated_output") orelse stringField(payload, "stdout") orelse "");
    if (stringField(payload, "command")) |v| try replaceOpt(allocator, &rec.command_text, v);
    if (stringField(payload, "cwd")) |v| try replaceOpt(allocator, &rec.cwd, v);
    if (intField(payload, "exit_code")) |v| rec.exit_code = v;
    if (intField(payload, "duration_ms")) |v| rec.duration_ms = v;
    if (intField(payload, "duration_secs")) |v| rec.duration_ms = v * 1000;
    if (objectField(payload, "invocation")) |inv| {
        if (stringField(inv, "server")) |v| try replaceOpt(allocator, &rec.mcp_server, v);
        if (stringField(inv, "tool")) |v| try replaceOpt(allocator, &rec.mcp_tool, v);
    }
    if (boolField(payload, "success")) |v| rec.patch_success = v;
    if (payload.get("changes")) |changes| {
        const json = try stringifyJsonValue(allocator, changes);
        defer allocator.free(json);
        try replaceOpt(allocator, &rec.patch_changes_json, json);
    }
    if (stringField(payload, "query")) |v| try replaceOpt(allocator, &rec.web_query, v);
    if (objectField(payload, "action")) |action| if (stringField(action, "url")) |v| try replaceOpt(allocator, &rec.web_url, v);
    if (stringField(payload, "prompt")) |v| try replaceOpt(allocator, &rec.image_prompt, v);
    rec.lifecycle_status = if (rec.exit_code) |code| if (code == 0) .completed else .failed else if (boolField(payload, "success")) |ok| if (ok) .completed else .failed else .completed;
}

fn parseExecArgsIntoRecord(allocator: std.mem.Allocator, record: *ToolLifecycleRecord, args: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return;
    defer parsed.deinit();
    const obj = valueObject(parsed.value) orelse return;
    if (stringField(obj, "cmd")) |v| try replaceOpt(allocator, &record.command_text, v);
    if (stringField(obj, "command")) |v| try replaceOpt(allocator, &record.command_text, v);
    if (stringField(obj, "cwd")) |v| try replaceOpt(allocator, &record.cwd, v);
}

fn appendGraphEdge(allocator: std.mem.Allocator, trace: *CanonicalSessionTrace, payload: std.json.ObjectMap, timestamp: ?[]const u8) !void {
    var edge = SessionGraphEdge{
        .parent_session_id = try dupOpt(allocator, trace.session.session_id),
        .worker_session_id = if (stringField(payload, "new_thread_id")) |v| try allocator.dupe(u8, v) else if (stringField(payload, "worker_session_id")) |v| try allocator.dupe(u8, v) else null,
        .parent_path = try allocator.dupe(u8, trace.session.path),
        .call_id = if (stringField(payload, "call_id")) |v| try allocator.dupe(u8, v) else null,
        .agent_nickname = if (stringField(payload, "agent_nickname")) |v| try allocator.dupe(u8, v) else null,
        .agent_role = if (stringField(payload, "agent_role")) |v| try allocator.dupe(u8, v) else null,
        .model = if (stringField(payload, "model")) |v| try allocator.dupe(u8, v) else null,
        .reasoning_effort = if (stringField(payload, "reasoning_effort") orelse stringField(payload, "effort")) |v| try allocator.dupe(u8, v) else null,
        .spawned_at = try dupOpt(allocator, timestamp),
        .prompt_preview = if (stringField(payload, "prompt")) |v| try previewAlloc(allocator, v) else null,
        .worker_status = if (stringField(payload, "status")) |v| try allocator.dupe(u8, v) else null,
    };
    errdefer edge.deinit(allocator);
    try trace.graph_edges.append(allocator, edge);
}

fn kindFromName(name: []const u8) ToolKind {
    if (std.mem.eql(u8, name, "exec_command") or std.mem.eql(u8, name, "shell")) return .exec_command;
    if (std.mem.eql(u8, name, "apply_patch")) return .patch_apply;
    if (std.mem.indexOf(u8, name, "web") != null) return .web_search;
    if (std.mem.indexOf(u8, name, "image") != null) return .image_generation;
    if (std.mem.eql(u8, name, "spawn_agent")) return .spawn_agent;
    if (std.mem.eql(u8, name, "wait_agent")) return .wait_agent;
    if (std.mem.eql(u8, name, "close_agent")) return .close_agent;
    if (std.mem.startsWith(u8, name, "mcp__")) return .mcp_tool;
    return .unknown;
}

fn kindFromEndEvent(event_type: []const u8, existing_name: ?[]u8) ToolKind {
    if (std.mem.eql(u8, event_type, "exec_command_end")) return .exec_command;
    if (std.mem.eql(u8, event_type, "mcp_tool_call_end")) return .mcp_tool;
    if (std.mem.eql(u8, event_type, "patch_apply_end")) return .patch_apply;
    if (std.mem.eql(u8, event_type, "web_search_end")) return .web_search;
    if (std.mem.eql(u8, event_type, "image_generation_end")) return .image_generation;
    if (std.mem.eql(u8, event_type, "collab_agent_spawn_end")) return .spawn_agent;
    if (std.mem.eql(u8, event_type, "collab_waiting_end")) return .wait_agent;
    if (std.mem.eql(u8, event_type, "collab_close_end")) return .close_agent;
    if (existing_name) |name| return kindFromName(name);
    return .unknown;
}

fn namespaceFromName(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, name, "mcp__")) return null;
    const rest = name["mcp__".len..];
    const split = std.mem.indexOf(u8, rest, "__") orelse return null;
    return try allocator.dupe(u8, rest[0..split]);
}

fn nowRealtimeNs() i128 {
    var ts: std.posix.timespec = undefined;
    return switch (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts))) {
        .SUCCESS => (@as(i128, ts.sec) * std.time.ns_per_s) + ts.nsec,
        else => 0,
    };
}

fn bestTimestamp(root: std.json.ObjectMap) ?[]const u8 {
    if (stringField(root, "timestamp")) |v| return v;
    if (objectField(root, "payload")) |payload| {
        if (stringField(payload, "timestamp")) |v| return v;
    }
    return null;
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn freeOpt(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |v| allocator.free(v);
}

test "parseRawTraceEvent detects newer event_msg" {
    const line =
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-04-01T00:00:00Z\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"t1\"}}";
    var event = (try parseRawTraceEvent(std.testing.allocator, "rollout.jsonl", 1, line)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(TraceFormat.new_044_plus, event.format);
    try std.testing.expectEqualStrings("event_msg", event.entry_type);
    try std.testing.expectEqualStrings("task_started", event.event_type.?);
}

test "parseRawTraceEvent skips state and malformed lines" {
    try std.testing.expect((try parseRawTraceEvent(std.testing.allocator, "x", 1, "")) == null);
    try std.testing.expect((try parseRawTraceEvent(std.testing.allocator, "x", 2, "{\"record_type\":\"state\"}")) == null);
    try std.testing.expect((try parseRawTraceEvent(std.testing.allocator, "x", 3, "{bad")) == null);
}

test "parseRawTraceEvent detects old root function call output" {
    const line =
        "{\"call_id\":\"call-1\",\"output\":\"ok\",\"timestamp\":\"2025-08-01T00:00:00Z\"}";
    var event = (try parseRawTraceEvent(std.testing.allocator, "old.jsonl", 4, line)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(TraceFormat.old_2025_08_root_meta, event.format);
    try std.testing.expectEqualStrings("function_call_output", event.entry_type);
}

fn testPath(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, relative });
}

test "parseSessionTrace reconstructs new complete turn" {
    const path = try testPath(std.testing.allocator, "testdata/trace/new_044_plus.jsonl");
    defer std.testing.allocator.free(path);
    var trace = try parseSessionTrace(std.testing.allocator, path, .{ .ongoing_threshold_secs = 0 });
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new-session", trace.session.session_id.?);
    try std.testing.expectEqual(@as(usize, 1), trace.turns.items.len);
    try std.testing.expectEqual(TurnStatus.complete, trace.turns.items[0].status);
    try std.testing.expectEqual(@as(i64, 15), trace.turns.items[0].total_tokens.?);
    try std.testing.expect(trace.turns.items[0].has_compaction);
    try std.testing.expectEqual(@as(usize, 1), trace.tools.items.len);
    try std.testing.expectEqual(ToolKind.exec_command, trace.tools.items[0].kind);
}

test "bytes-backed trace parsing preserves the exact assistant occurrence line" {
    const source =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-13T00:00:00Z\",\"payload\":{\"id\":\"session-bytes\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-13T00:00:01Z\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-one\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-07-13T00:00:02Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"first\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-13T00:00:03Z\",\"payload\":{\"type\":\"agent_message\",\"message\":\"selected\"}}\n";
    var trace = try parseSessionTraceBytes(
        std.testing.allocator,
        "/provenance/only.jsonl",
        source,
        nowRealtimeNs(),
        .{},
    );
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), trace.turns.items[0].final_answer_line.?);
    try std.testing.expectEqualStrings("selected", trace.turns.items[0].final_answer.?);
}

test "canonical trace retains state and unknown carriers for exact consumers" {
    const source =
        "{\"record_type\":\"state\",\"payload\":{\"opaque\":true}}\n" ++
        "{\"type\":\"future_carrier\",\"payload\":{\"opaque\":true}}\n";
    var trace = try parseSessionTraceBytes(
        std.testing.allocator,
        "/provenance/only.jsonl",
        source,
        nowRealtimeNs(),
        .{},
    );
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), trace.occurrences.items.len);
    try std.testing.expectEqualStrings("state", trace.occurrences.items[0].entry_type);
    try std.testing.expectEqualStrings("future_carrier", trace.occurrences.items[1].entry_type);
}

test "parseSessionSummaryTrace preserves session inventory fields" {
    const path = try testPath(std.testing.allocator, "testdata/trace/new_044_plus.jsonl");
    defer std.testing.allocator.free(path);
    var full = try parseSessionTrace(std.testing.allocator, path, .{ .ongoing_threshold_secs = 0 });
    defer full.deinit(std.testing.allocator);
    var summary = try parseSessionSummaryTrace(std.testing.allocator, path, .{ .ongoing_threshold_secs = 0 });
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(full.session.session_id.?, summary.session.session_id.?);
    try std.testing.expectEqualStrings(full.session.start_time.?, summary.session.start_time.?);
    try std.testing.expectEqualStrings(full.session.end_time.?, summary.session.end_time.?);
    try std.testing.expectEqualStrings(full.session.cwd.?, summary.session.cwd.?);
    try std.testing.expectEqual(full.session.turn_count, summary.session.turn_count);
    try std.testing.expectEqual(full.session.total_tokens.?, summary.session.total_tokens.?);
    try std.testing.expectEqual(full.session.is_ongoing, summary.session.is_ongoing);
    try std.testing.expectEqualStrings(full.session.status_reason.?, summary.session.status_reason.?);
}

test "first file-owner session metadata remains authoritative" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-13T00:00:00Z\",\"payload\":{\"id\":\"worker\",\"cwd\":\"/worker\",\"cli_version\":\"2\",\"model\":\"worker-model\",\"git\":{\"branch\":\"feature\",\"commit_hash\":\"worker-commit\"}}}\n" ++
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-13T00:00:01Z\",\"payload\":{\"id\":\"parent\",\"cwd\":\"/parent\",\"cli_version\":\"1\",\"model\":\"parent-model\",\"git\":{\"branch\":\"main\",\"commit_hash\":\"parent-commit\"}}}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rollout-worker.jsonl", .data = source });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "rollout-worker.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var full = try parseSessionTrace(std.testing.allocator, path, .{});
    defer full.deinit(std.testing.allocator);
    var summary = try parseSessionSummaryTrace(std.testing.allocator, path, .{});
    defer summary.deinit(std.testing.allocator);

    for ([_]*const SessionRecord{ &full.session, &summary.session }) |session| {
        try std.testing.expectEqualStrings("worker", session.session_id.?);
        try std.testing.expectEqualStrings("/worker", session.cwd.?);
        try std.testing.expectEqualStrings("2", session.cli_version.?);
        try std.testing.expectEqualStrings("worker-model", session.model.?);
        try std.testing.expectEqualStrings("feature", session.git_branch.?);
        try std.testing.expectEqualStrings("worker-commit", session.git_commit_hash.?);
    }
    try std.testing.expectEqual(@as(usize, 2), full.occurrences.items.len);
    try std.testing.expectEqual(@as(usize, 1), full.warnings.items.len);
    try std.testing.expectEqual(@as(usize, 1), summary.warnings.items.len);
}

test "parseSessionTrace reconstructs old synthetic turns" {
    const path = try testPath(std.testing.allocator, "testdata/trace/old_2025_08_root_meta.jsonl");
    defer std.testing.allocator.free(path);
    var trace = try parseSessionTrace(std.testing.allocator, path, .{ .ongoing_threshold_secs = 0 });
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("old-session", trace.session.session_id.?);
    try std.testing.expectEqual(@as(usize, 2), trace.turns.items.len);
    try std.testing.expectEqualStrings("turn-1", trace.turns.items[0].turn_id);
    try std.testing.expectEqualStrings("turn-2", trace.turns.items[1].turn_id);
}

test "parseSessionTrace reports lifecycle and graph edges" {
    const path = try testPath(std.testing.allocator, "testdata/trace/tools.jsonl");
    defer std.testing.allocator.free(path);
    var trace = try parseSessionTrace(std.testing.allocator, path, .{ .ongoing_threshold_secs = 0 });
    defer trace.deinit(std.testing.allocator);
    try std.testing.expect(trace.tools.items.len >= 7);
    try std.testing.expectEqual(@as(usize, 1), trace.graph_edges.items.len);
    try std.testing.expectEqualStrings("worker", trace.graph_edges.items[0].worker_session_id.?);
    var saw_unresolved = false;
    for (trace.tools.items) |tool| {
        if (tool.lifecycle_status == .unresolved) saw_unresolved = true;
    }
    try std.testing.expect(saw_unresolved);
}
