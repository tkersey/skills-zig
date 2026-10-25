const std = @import("std");
const jsonl_stream = @import("jsonl_core");

pub const TraceFormat = enum {
    new_044_plus,
    mid_payload_meta,
    old_2025_08_root_meta,
    pi_session_jsonl,
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
    include_occurrences: bool = true,
    include_occurrence_payloads: bool = true,
    include_token_events: bool = false,
    include_message_bodies: bool = true,
    /// Retain the stable top N tools ordered by turn_index descending. This
    /// matches the tool_lifecycle dataset's limit semantics without retaining
    /// large payloads for rows that cannot reach that result.
    max_tools: ?usize = null,
};

pub const StreamMetrics = struct {
    bytes_read: usize = 0,
    lines_seen: usize = 0,
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
    source_format: TraceFormat = .unknown,
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
    root_session_id: ?[]u8 = null,
    parent_session_id: ?[]u8 = null,
    parent_relation: ?[]u8 = null,
    lineage_conflict: bool = false,
    service_tier: ?[]u8 = null,

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
        freeOpt(allocator, self.root_session_id);
        freeOpt(allocator, self.parent_session_id);
        freeOpt(allocator, self.parent_relation);
        freeOpt(allocator, self.service_tier);
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
    source_event_id: [71]u8,
    line_number: usize,
    ordinal: usize,
    turn_index: ?i64 = null,
    entry_type: []u8,
    event_type: ?[]u8 = null,
    role: ?[]u8 = null,
    timestamp: ?[]u8 = null,
    payload_json: ?[]u8 = null,
    raw_json: ?[]u8 = null,
    text: ?[]u8 = null,
    message_visible: bool = true,
    private: bool = false,
    format: TraceFormat = .unknown,

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        line_number: usize,
        ordinal: usize,
        turn_index: ?i64,
        entry_type: []const u8,
        event_type: ?[]const u8,
        role: ?[]const u8,
        text: ?[]const u8,
        private: bool,
    ) !TraceOccurrence {
        var occurrence = TraceOccurrence{
            .source_event_id = computeSourceEventId(path, line_number, ordinal),
            .line_number = line_number,
            .ordinal = ordinal,
            .turn_index = turn_index,
            .entry_type = try allocator.dupe(u8, entry_type),
            .private = private,
        };
        errdefer occurrence.deinit(allocator);
        occurrence.event_type = try dupOpt(allocator, event_type);
        occurrence.role = try dupOpt(allocator, role);
        occurrence.text = try dupOpt(allocator, text);
        return occurrence;
    }

    pub fn deinit(self: *TraceOccurrence, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_type);
        freeOpt(allocator, self.event_type);
        freeOpt(allocator, self.role);
        freeOpt(allocator, self.timestamp);
        freeOpt(allocator, self.payload_json);
        freeOpt(allocator, self.raw_json);
        freeOpt(allocator, self.text);
    }

    pub fn sourceEventId(self: *const TraceOccurrence) []const u8 {
        return &self.source_event_id;
    }
};

pub const TokenEventRecord = struct {
    occurrence_index: usize,
    turn_index: i64,
    input_tokens: ?i64 = null,
    cached_input_tokens: ?i64 = null,
    output_tokens: ?i64 = null,
    reasoning_output_tokens: ?i64 = null,
    total_tokens: ?i64 = null,
    total_input_tokens: ?i64 = null,
    total_cached_input_tokens: ?i64 = null,
    total_output_tokens: ?i64 = null,
    total_reasoning_output_tokens: ?i64 = null,
    total_total_tokens: ?i64 = null,
    last_input_tokens: ?i64 = null,
    last_cached_input_tokens: ?i64 = null,
    last_output_tokens: ?i64 = null,
    last_reasoning_output_tokens: ?i64 = null,
    last_total_tokens: ?i64 = null,
    has_total_usage: bool = false,
    has_last_usage: bool = false,
    model: ?[]u8 = null,
    service_tier: ?[]u8 = null,

    pub fn deinit(self: *TokenEventRecord, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.model);
        freeOpt(allocator, self.service_tier);
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
    // Pi keeps the persisted entry envelope as its occurrence payload so that
    // entry IDs and parent IDs remain available to exact source consumers.
    if (std.mem.eql(u8, stringField(payload, "type") orelse "", "message")) {
        if (objectField(payload, "message")) |message| {
            return messageTextPartsAlloc(allocator, message);
        }
    }
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
    omitted_tool_call_ids: std.StringHashMapUnmanaged(void) = .empty,
    graph_edges: std.ArrayList(SessionGraphEdge) = .empty,
    occurrences: std.ArrayList(TraceOccurrence) = .empty,
    token_events: std.ArrayList(TokenEventRecord) = .empty,
    warnings: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *CanonicalSessionTrace, allocator: std.mem.Allocator) void {
        self.session.deinit(allocator);
        for (self.turns.items) |*turn| turn.deinit(allocator);
        self.turns.deinit(allocator);
        for (self.tools.items) |*tool| tool.deinit(allocator);
        self.tools.deinit(allocator);
        var omitted_it = self.omitted_tool_call_ids.keyIterator();
        while (omitted_it.next()) |call_id| allocator.free(call_id.*);
        self.omitted_tool_call_ids.deinit(allocator);
        for (self.graph_edges.items) |*edge| edge.deinit(allocator);
        self.graph_edges.deinit(allocator);
        for (self.occurrences.items) |*occurrence| occurrence.deinit(allocator);
        self.occurrences.deinit(allocator);
        for (self.token_events.items) |*event| event.deinit(allocator);
        self.token_events.deinit(allocator);
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
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
    defer parsed.deinit();
    const root = valueObject(parsed.value) orelse return null;
    if (stringField(root, "record_type")) |record_type| {
        if (std.mem.eql(u8, record_type, "state")) return null;
    }
    const classification = classifyRawEvent(root);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    var event = RawTraceEvent{
        .path = owned_path,
        .line_number = line_number,
        .entry_type = try allocator.dupe(u8, classification.entry_type),
        .format = classification.format,
    };
    // The separate path cleanup remains armed until the event is returned.
    errdefer {
        allocator.free(event.entry_type);
        freeOpt(allocator, event.event_type);
        freeOpt(allocator, event.timestamp);
        freeOpt(allocator, event.payload_json);
        freeOpt(allocator, event.raw_json);
    }
    event.event_type = try dupOpt(allocator, classification.event_type);
    event.timestamp = try dupOpt(allocator, bestTimestamp(root));
    if (classification.format == .pi_session_jsonl) {
        event.payload_json = try piPayloadJsonAlloc(allocator, root);
    } else if (root.get("payload")) |payload| {
        event.payload_json = try stringifyJsonValue(allocator, payload);
    }
    event.raw_json = try allocator.dupe(u8, trimmed);
    return event;
}

const RawEventClassification = struct {
    entry_type: []const u8,
    event_type: ?[]const u8,
    format: TraceFormat,
};

fn classifyRawEvent(root: std.json.ObjectMap) RawEventClassification {
    if (isPiStandaloneEntry(root)) {
        const message = objectField(root, "message");
        return .{
            .entry_type = stringField(root, "type").?,
            .event_type = if (message) |value| stringField(value, "role") else null,
            .format = .pi_session_jsonl,
        };
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
        } else if (root.get("call_id") != null and
            root.get("arguments") != null and root.get("name") != null)
        {
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

    return .{ .entry_type = entry_type, .event_type = event_type, .format = format };
}

pub fn parseSessionTrace(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    path: []const u8,
    options: TraceParseOptions,
) !CanonicalSessionTrace {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    var reader = file.reader(io, &.{});
    return parseSessionTraceReader(
        io,
        allocator,
        path,
        &reader.interface,
        stat.mtime.nanoseconds,
        options,
    );
}

/// Parses the caller-owned immutable session bytes. The path is provenance
/// only and is never reopened. `source_mtime_ns` is observed by the caller
/// from the same held source file and is used only for ongoing-turn status.
pub fn parseSessionTraceBytes(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    source_mtime_ns: i128,
    options: TraceParseOptions,
) !CanonicalSessionTrace {
    var reader = std.Io.Reader.fixed(content);
    return parseSessionTraceReader(io, allocator, path, &reader, source_mtime_ns, options);
}

pub fn parseSessionTraceReader(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    reader: *std.Io.Reader,
    source_mtime_ns: i128,
    options: TraceParseOptions,
) !CanonicalSessionTrace {
    const Ignore = struct {
        fn visit(_: void, _: []const u8, _: usize) !void {}
    };
    return parseSessionTraceReaderWithVisitor(
        io,
        allocator,
        path,
        reader,
        source_mtime_ns,
        options,
        {},
        Ignore.visit,
    );
}

pub fn parseSessionTraceReaderWithVisitor(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    reader: *std.Io.Reader,
    source_mtime_ns: i128,
    options: TraceParseOptions,
    context: anytype,
    comptime visit: anytype,
) !CanonicalSessionTrace {
    var metrics = StreamMetrics{};
    return parseSessionTraceReaderWithVisitorMetrics(
        io,
        allocator,
        path,
        reader,
        source_mtime_ns,
        options,
        context,
        visit,
        &metrics,
    );
}

const scratch_retention_limit = 1024 * 1024;
const MessageDigestMap = std.AutoHashMap([std.crypto.hash.sha2.Sha256.digest_length]u8, u8);

/// Parsed strings borrow the current line or this arena only until reset.
/// Every retained trace field is separately owned by the result allocator.
const ParseScratch = struct {
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator) ParseScratch {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *ParseScratch) void {
        self.arena.deinit();
    }

    fn reset(self: *ParseScratch) void {
        // Reset retains at most one used and one free node; include both headers.
        const node_bytes = @sizeOf(@TypeOf(self.arena.state.used_list.?.*));
        const payload_limit = scratch_retention_limit - 2 * node_bytes;
        if (!self.arena.reset(.{ .retain_with_limit = payload_limit })) {
            // Failed arena shrinking may retain the old oversized chunk.
            self.arena.deinit();
            self.arena.state = .init;
        }
        std.debug.assert(self.arena.queryCapacity() <= payload_limit);
    }

    fn parse(self: *ParseScratch, line: []const u8) !?std.json.ObjectMap {
        const value = try std.json.parseFromSliceLeaky(
            std.json.Value,
            self.arena.allocator(),
            line,
            .{},
        );
        return valueObject(value);
    }
};

const ParsedRecord = struct {
    root: std.json.ObjectMap,
    root_type: ?[]const u8,
    payload: ?std.json.ObjectMap,
    timestamp: ?[]const u8,
    line_number: usize,
    line: []const u8,

    fn init(root: std.json.ObjectMap, number: usize, line: []const u8) ParsedRecord {
        return .{
            .root = root,
            .root_type = stringField(root, "type"),
            .payload = objectField(root, "payload"),
            .timestamp = bestTimestamp(root),
            .line_number = number,
            .line = line,
        };
    }

    fn isState(self: ParsedRecord) bool {
        return std.mem.eql(u8, stringField(self.root, "record_type") orelse "", "state");
    }
};

fn appendMalformedWarning(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    line_number: usize,
) !void {
    const warning = try allocator.print(
        "{s}:{d}: malformed JSONL skipped",
        .{ trace.session.path, line_number },
    );
    errdefer allocator.free(warning);
    try trace.warnings.append(allocator, warning);
}

pub fn parseSessionTraceReaderWithVisitorMetrics(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    reader: *std.Io.Reader,
    source_mtime_ns: i128,
    options: TraceParseOptions,
    context: anytype,
    comptime visit: anytype,
    metrics: *StreamMetrics,
) !CanonicalSessionTrace {
    var trace = CanonicalSessionTrace{ .session = try SessionRecord.init(allocator, path) };
    errdefer trace.deinit(allocator);
    trace.session.date_group = try deriveDateGroup(allocator, path);
    var parser = TraceParser{
        .allocator = allocator,
        .trace = &trace,
        .options = options,
        .seen_messages = MessageDigestMap.init(allocator),
        .tool_lookup = .{ .enabled = options.max_tools == null },
    };
    defer parser.seen_messages.deinit();
    defer parser.tool_lookup.deinit(allocator);
    var pi_parser = PiParser.init(allocator, &trace, options, false);
    defer pi_parser.deinit();
    var source_is_pi: ?bool = null;
    var scratch = ParseScratch.init(allocator);
    defer scratch.deinit();
    var lines = try jsonl_stream.Stream.init(allocator, reader, .{});
    defer lines.deinit();
    while (try lines.next()) |record| {
        defer scratch.reset();
        try visit(context, record.bytes, record.number);
        const line = std.mem.trim(u8, record.bytes, " \t\r\n");
        if (line.len == 0) continue;
        const root = scratch.parse(line) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try appendMalformedWarning(allocator, &trace, record.number);
                continue;
            },
        } orelse continue;
        if (source_is_pi == null) source_is_pi = isPiSessionHeader(root);
        const parsed_record = ParsedRecord.init(root, record.number, line);
        if (source_is_pi.?) {
            try pi_parser.apply(parsed_record);
        } else {
            try parser.apply(parsed_record);
        }
    }
    if (source_is_pi orelse false) {
        try pi_parser.finish(io, source_mtime_ns);
    } else {
        try finalizeTrace(io, allocator, &trace, source_mtime_ns, options);
    }
    metrics.* = .{ .bytes_read = lines.bytes_read, .lines_seen = lines.line_number };
    return trace;
}

fn isPiSessionHeader(root: std.json.ObjectMap) bool {
    return std.mem.eql(u8, stringField(root, "type") orelse "", "session") and
        stringField(root, "id") != null;
}

fn isPiStandaloneEntry(root: std.json.ObjectMap) bool {
    if (isPiSessionHeader(root)) return true;
    const entry_type = stringField(root, "type") orelse return false;
    if (std.mem.eql(u8, entry_type, "message")) {
        const message = objectField(root, "message") orelse return false;
        return stringField(message, "role") != null;
    }
    return oneOfString(entry_type, &.{
        "model_change", "thinking_level_change", "session_info",
        "compaction",   "branch_summary",        "custom_message",
        "context_edit",
    });
}

const PiTurnState = struct {
    status: TurnStatus = .ongoing,
    reason: []const u8 = "pi_user_message",
};

const PiEntryContext = struct {
    turn_index: ?usize = null,
    settings_index: ?usize = null,
};

const PiSettings = struct {
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
};

/// Pi is an append-only tree. Keep all physical entries, attributing each to
/// its nearest user ancestor instead of whichever branch was read most recently.
/// Summary parsing retains only this lineage index and compact turn status.
const PiParser = struct {
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    options: TraceParseOptions,
    summary: bool,
    header_seen: bool = false,
    version: i64 = 1,
    entry_contexts: std.StringHashMapUnmanaged(PiEntryContext) = .empty,
    turn_states: std.ArrayList(PiTurnState) = .empty,
    previous_context: PiEntryContext = .{},
    settings: std.ArrayList(PiSettings) = .empty,
    metadata_arena: std.heap.ArenaAllocator,
    tool_lookup: ToolLookup,

    fn init(
        allocator: std.mem.Allocator,
        trace: *CanonicalSessionTrace,
        options: TraceParseOptions,
        summary: bool,
    ) PiParser {
        return .{
            .allocator = allocator,
            .trace = trace,
            .options = options,
            .summary = summary,
            .metadata_arena = std.heap.ArenaAllocator.init(allocator),
            .tool_lookup = .{ .enabled = options.max_tools == null },
        };
    }

    fn deinit(self: *PiParser) void {
        var keys = self.entry_contexts.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.entry_contexts.deinit(self.allocator);
        self.turn_states.deinit(self.allocator);
        self.tool_lookup.deinit(self.allocator);
        self.settings.deinit(self.allocator);
        self.metadata_arena.deinit();
    }

    fn apply(self: *PiParser, record: ParsedRecord) !void {
        if (!self.header_seen) {
            try self.applyHeader(record);
            try self.appendOccurrence(record, null);
            return;
        }
        try applySessionTimestamp(self.allocator, &self.trace.session, record.timestamp);
        var context = self.parentContext(record.root);
        const entry_type = record.root_type orelse "unknown";
        if (std.mem.eql(u8, entry_type, "message")) {
            if (objectField(record.root, "message")) |message| {
                if (std.mem.eql(u8, stringField(message, "role") orelse "", "assistant")) {
                    try self.updateSettings(&context, .{
                        .model = stringField(message, "model"),
                        .provider = stringField(message, "provider"),
                    });
                }
                context.turn_index = try self.applyMessage(record, message, context);
            }
        } else {
            try self.applyMetadata(record, &context);
        }
        try self.rememberEntry(record, context);
        try self.appendOccurrence(record, context.turn_index);
    }

    fn applyHeader(self: *PiParser, record: ParsedRecord) !void {
        std.debug.assert(isPiSessionHeader(record.root));
        if (self.options.include_token_events) return error.PiCumulativeTokenEventsUnavailable;
        self.header_seen = true;
        self.version = intField(record.root, "version") orelse 1;
        const session = &self.trace.session;
        session.source_format = .pi_session_jsonl;
        const id = stringField(record.root, "id").?;
        try replaceOpt(self.allocator, &session.session_id, id);
        try replaceOpt(self.allocator, &session.root_session_id, id);
        try replaceOpt(self.allocator, &session.originator, "pi");
        if (stringField(record.root, "cwd")) |cwd| {
            try replaceOpt(self.allocator, &session.cwd, cwd);
        }
        try applySessionTimestamp(self.allocator, session, record.timestamp);
        // parentSession is a file path, not a worker/session identifier.
        if (self.version > 3) {
            try self.warn(record, "future Pi version interpreted using known tree fields");
        }
    }

    fn parentContext(self: *const PiParser, root: std.json.ObjectMap) PiEntryContext {
        if (self.version < 2) return self.previous_context;
        const parent_id = stringField(root, "parentId") orelse return .{};
        return self.entry_contexts.get(parent_id) orelse .{};
    }

    fn settingsAt(self: *const PiParser, context: PiEntryContext) PiSettings {
        return if (context.settings_index) |index| self.settings.items[index] else .{};
    }

    fn updateSettings(self: *PiParser, context: *PiEntryContext, updates: PiSettings) !void {
        var settings = self.settingsAt(context.*);
        var changed = false;
        inline for (.{ "model", "provider", "reasoning_effort" }) |field| {
            if (@field(updates, field)) |value| {
                const previous = @field(settings, field);
                if (previous == null or !std.mem.eql(u8, previous.?, value)) {
                    @field(settings, field) = try self.metadata_arena.allocator().dupe(u8, value);
                    changed = true;
                }
            }
        }
        if (!changed) return;
        try self.settings.append(self.allocator, settings);
        context.settings_index = self.settings.items.len - 1;
    }

    fn rememberEntry(self: *PiParser, record: ParsedRecord, context: PiEntryContext) !void {
        self.previous_context = context;
        const id = stringField(record.root, "id") orelse return;
        if (self.entry_contexts.getPtr(id)) |existing| {
            existing.* = context;
            try self.warn(record, "duplicate Pi entry ID; latest occurrence owns descendants");
            return;
        }
        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        try self.entry_contexts.put(self.allocator, owned_id, context);
    }

    fn newTurn(self: *PiParser, record: ParsedRecord, context: PiEntryContext) !usize {
        const index = self.turn_states.items.len;
        try self.turn_states.append(self.allocator, .{});
        if (self.summary) return index;
        var current: ?usize = null;
        const full_index = try startTurn(
            self.allocator,
            self.trace,
            self.trace.session.path,
            &current,
            stringField(record.root, "id"),
            record.timestamp,
        );
        std.debug.assert(full_index == index);
        const turn = &self.trace.turns.items[index];
        const settings = self.settingsAt(context);
        turn.cwd = try dupOpt(self.allocator, self.trace.session.cwd);
        turn.model = try dupOpt(self.allocator, settings.model);
        turn.reasoning_effort = try dupOpt(self.allocator, settings.reasoning_effort);
        return index;
    }

    fn applyMessage(
        self: *PiParser,
        record: ParsedRecord,
        message: std.json.ObjectMap,
        context: PiEntryContext,
    ) !?usize {
        const parent_turn = context.turn_index;
        const role = stringField(message, "role") orelse return parent_turn;
        if (std.mem.eql(u8, role, "user")) {
            if (parent_turn) |index| {
                if (self.turn_states.items[index].status == .ongoing) {
                    try self.setStatus(index, .aborted, "pi_superseded_turn", record.timestamp);
                }
            }
            const index = try self.newTurn(record, context);
            if (!self.summary and self.options.include_message_bodies) {
                try applyResponseMessage(
                    self.allocator,
                    &self.trace.turns.items[index],
                    message,
                    role,
                    record.line_number,
                );
            }
            return index;
        }
        if (!oneOfString(role, &.{ "assistant", "toolResult", "bashExecution" })) {
            return parent_turn;
        }
        const index = parent_turn orelse try self.newTurn(record, context);
        if (std.mem.eql(u8, role, "assistant")) {
            if (!self.summary) {
                const settings = self.settingsAt(context);
                const turn = &self.trace.turns.items[index];
                try replaceNullable(self.allocator, &turn.model, settings.model);
                try replaceNullable(
                    self.allocator,
                    &turn.reasoning_effort,
                    settings.reasoning_effort,
                );
            }
            try self.applyAssistant(record, message, index);
        } else if (std.mem.eql(u8, role, "toolResult")) {
            if (!self.summary) try self.applyToolResult(record, message, index);
        } else {
            if (!self.summary) try self.applyBashExecution(record, message, index);
            if (parent_turn == null) {
                try self.setStatus(index, .complete, "pi_shell_execution", record.timestamp);
            }
        }
        return index;
    }

    fn applyMetadata(self: *PiParser, record: ParsedRecord, context: *PiEntryContext) !void {
        const entry_type = record.root_type orelse return;
        const session = &self.trace.session;
        if (std.mem.eql(u8, entry_type, "model_change")) {
            try self.updateSettings(context, .{
                .model = stringField(record.root, "modelId"),
                .provider = stringField(record.root, "provider"),
            });
        } else if (std.mem.eql(u8, entry_type, "thinking_level_change")) {
            try self.updateSettings(context, .{
                .reasoning_effort = stringField(record.root, "thinkingLevel"),
            });
        } else if (std.mem.eql(u8, entry_type, "session_info")) {
            const name = stringField(record.root, "name");
            const nonempty_name = if (name) |value|
                if (std.mem.trim(u8, value, " \t\r\n").len > 0) value else null
            else
                null;
            try replaceNullable(self.allocator, &session.thread_name, nonempty_name);
        } else if (std.mem.eql(u8, entry_type, "compaction")) {
            if (!self.summary) {
                if (context.turn_index) |index| self.trace.turns.items[index].has_compaction = true;
            }
        }
    }

    fn applyAssistant(
        self: *PiParser,
        record: ParsedRecord,
        message: std.json.ObjectMap,
        turn_index: usize,
    ) !void {
        if (stringField(message, "model")) |model| {
            try replaceOpt(self.allocator, &self.trace.session.model, model);
            if (!self.summary) {
                try replaceOpt(self.allocator, &self.trace.turns.items[turn_index].model, model);
            }
        }
        if (stringField(message, "provider")) |provider| {
            try replaceOpt(self.allocator, &self.trace.session.model_provider, provider);
        }
        try self.applyUsage(record, message, turn_index);
        const state = piAssistantStatus(stringField(message, "stopReason") orelse "");
        try self.setStatus(turn_index, state.status, state.reason, record.timestamp);
        if (self.summary) return;
        const turn = &self.trace.turns.items[turn_index];
        if (stringField(message, "errorMessage")) |error_message| {
            try replaceOpt(self.allocator, &turn.@"error", error_message);
            if (state.status == .aborted) {
                try replaceOpt(self.allocator, &turn.aborted_reason, error_message);
            }
        }
        if (self.options.include_message_bodies) {
            const text = try messageTextAlloc(self.allocator, message);
            defer self.allocator.free(text);
            if (text.len > 0) {
                try attachAssistantMessage(self.allocator, turn, text, record.line_number);
            }
        }
        try self.declareTools(record, message, turn_index);
    }

    fn setStatus(
        self: *PiParser,
        turn_index: usize,
        status: TurnStatus,
        reason: []const u8,
        timestamp: ?[]const u8,
    ) !void {
        self.turn_states.items[turn_index] = .{ .status = status, .reason = reason };
        if (self.summary) return;
        const turn = &self.trace.turns.items[turn_index];
        turn.status = status;
        try replaceOpt(self.allocator, &turn.status_reason, reason);
        if (status == .ongoing) {
            freeOpt(self.allocator, turn.completed_at);
            turn.completed_at = null;
        } else if (timestamp) |value| {
            try replaceOpt(self.allocator, &turn.completed_at, value);
        }
    }

    fn applyUsage(
        self: *PiParser,
        record: ParsedRecord,
        message: std.json.ObjectMap,
        turn_index: usize,
    ) !void {
        const raw_usage = objectField(message, "usage") orelse {
            if (message.get("usage") != null) {
                try self.warn(record, "invalid Pi usage object; totals cover observed fields only");
            }
            return;
        };
        const usage = PiUsage.read(raw_usage);
        var valid = usage.valid;
        valid = addPiUsage(&self.trace.session, usage) and valid;
        if (!self.summary) {
            valid = addPiUsage(&self.trace.turns.items[turn_index], usage) and valid;
        }
        if (!valid) {
            try self.warn(
                record,
                "incomplete or invalid Pi usage; totals cover observed fields only",
            );
        }
    }

    fn declareTools(
        self: *PiParser,
        record: ParsedRecord,
        message: std.json.ObjectMap,
        turn_index: usize,
    ) !void {
        const content = message.get("content") orelse return;
        const parts = valueArray(content) orelse return;
        for (parts.items) |part| {
            const call = valueObject(part) orelse continue;
            if (!std.mem.eql(u8, stringField(call, "type") orelse "", "toolCall")) continue;
            try self.declareTool(record, call, turn_index);
        }
    }

    fn declareTool(
        self: *PiParser,
        record: ParsedRecord,
        call: std.json.ObjectMap,
        turn_index: usize,
    ) !void {
        const id = stringField(call, "id") orelse return;
        if (self.tool_lookup.find(self.trace, id) != null) return;
        if (self.trace.omitted_tool_call_ids.contains(id)) return;
        const name = stringField(call, "name") orelse "unknown";
        var tool = try initToolRecord(self.allocator, self.trace, turn_index, id);
        var owned = true;
        errdefer if (owned) tool.deinit(self.allocator);
        tool.started_at = try dupOpt(self.allocator, record.timestamp);
        tool.tool_name = try self.allocator.dupe(u8, name);
        tool.kind = piToolKind(name);
        tool.namespace = if (stringField(call, "namespace")) |namespace|
            try self.allocator.dupe(u8, namespace)
        else
            try namespaceFromName(self.allocator, name);
        if (call.get("arguments")) |arguments| {
            tool.arguments_json = try stringifyJsonValue(self.allocator, arguments);
            try parseExecArgsIntoRecord(self.allocator, &tool, tool.arguments_json.?);
        }
        if (tool.cwd == null) tool.cwd = try dupOpt(self.allocator, self.trace.session.cwd);
        tool.lifecycle_status = .declared;
        tool.declared_line = @intCast(record.line_number);
        try self.trace.tools.append(self.allocator, tool);
        owned = false;
        try self.tool_lookup.remember(self.allocator, self.trace);
        self.trace.turns.items[turn_index].tool_count += 1;
        try retainNewestTools(self.allocator, self.trace, self.options.max_tools);
    }

    fn applyToolResult(
        self: *PiParser,
        record: ParsedRecord,
        message: std.json.ObjectMap,
        turn_index: usize,
    ) !void {
        const id = stringField(message, "toolCallId") orelse return;
        const index = self.tool_lookup.find(self.trace, id) orelse blk: {
            if (self.trace.omitted_tool_call_ids.contains(id)) return;
            try inferToolRecord(
                self.allocator,
                self.trace,
                &self.tool_lookup,
                turn_index,
                id,
                record.timestamp,
                self.options.max_tools,
            );
            break :blk self.tool_lookup.find(self.trace, id) orelse return;
        };
        const tool = &self.trace.tools.items[index];
        if (stringField(message, "toolName")) |name| {
            try replaceOpt(self.allocator, &tool.tool_name, name);
            tool.kind = piToolKind(name);
        }
        const output = try messageTextAlloc(self.allocator, message);
        defer self.allocator.free(output);
        try replaceOpt(self.allocator, &tool.output_text, output);
        if (record.timestamp) |timestamp| {
            try replaceOpt(self.allocator, &tool.completed_at, timestamp);
        }
        tool.finalized_line = @intCast(record.line_number);
        tool.duration_ms = intField(message, "durationMs");
        if (objectField(message, "details")) |details| {
            tool.exit_code = intField(details, "exitCode");
            if (tool.duration_ms == null) tool.duration_ms = intField(details, "durationMs");
        }
        tool.lifecycle_status = if (boolField(message, "isError") orelse false)
            .failed
        else
            completedToolStatus(tool.exit_code, null);
    }

    fn applyBashExecution(
        self: *PiParser,
        record: ParsedRecord,
        message: std.json.ObjectMap,
        turn_index: usize,
    ) !void {
        const id = try self.allocator.print("pi-bash-{d}", .{record.line_number});
        defer self.allocator.free(id);
        var tool = try initToolRecord(self.allocator, self.trace, turn_index, id);
        var owned = true;
        errdefer if (owned) tool.deinit(self.allocator);
        tool.kind = .exec_command;
        tool.tool_name = try self.allocator.dupe(u8, "bash");
        tool.started_at = try dupOpt(self.allocator, record.timestamp);
        tool.completed_at = try dupOpt(self.allocator, record.timestamp);
        tool.command_text = try dupOpt(self.allocator, stringField(message, "command"));
        tool.output_text = try dupOpt(self.allocator, stringField(message, "output"));
        tool.cwd = try dupOpt(self.allocator, self.trace.session.cwd);
        tool.exit_code = intField(message, "exitCode");
        tool.lifecycle_status = if (boolField(message, "cancelled") orelse false)
            .failed
        else
            completedToolStatus(tool.exit_code, null);
        tool.declared_line = @intCast(record.line_number);
        tool.finalized_line = @intCast(record.line_number);
        try self.trace.tools.append(self.allocator, tool);
        owned = false;
        try self.tool_lookup.remember(self.allocator, self.trace);
        self.trace.turns.items[turn_index].tool_count += 1;
        try retainNewestTools(self.allocator, self.trace, self.options.max_tools);
    }

    fn appendOccurrence(self: *PiParser, record: ParsedRecord, turn_index: ?usize) !void {
        if (self.summary or !self.options.include_occurrences) return;
        const entry_type = record.root_type orelse "unknown";
        const message = if (std.mem.eql(u8, entry_type, "message"))
            objectField(record.root, "message")
        else
            null;
        const role = if (message) |value| stringField(value, "role") else null;
        var occurrence = try TraceOccurrence.init(
            self.allocator,
            self.trace.session.path,
            record.line_number,
            self.trace.occurrences.items.len,
            if (turn_index) |index| @intCast(index + 1) else null,
            entry_type,
            role,
            role,
            null,
            false,
        );
        errdefer occurrence.deinit(self.allocator);
        occurrence.format = .pi_session_jsonl;
        occurrence.private = piMessageOnlyThinking(record.root);
        occurrence.timestamp = try dupOpt(self.allocator, record.timestamp);
        if (message) |value| {
            occurrence.text = try messageTextAlloc(self.allocator, value);
        } else if (std.mem.eql(u8, entry_type, "custom_message")) {
            occurrence.text = try messageTextAlloc(self.allocator, record.root);
        } else if (oneOfString(entry_type, &.{ "compaction", "branch_summary" })) {
            occurrence.text = try dupOpt(self.allocator, stringField(record.root, "summary"));
        }
        occurrence.message_visible = if (role) |value|
            oneOfString(value, &.{ "user", "assistant" }) and
                (if (occurrence.text) |text| text.len > 0 else false)
        else
            false;
        if (self.options.include_occurrence_payloads) {
            occurrence.payload_json = try piPayloadJsonAlloc(self.allocator, record.root);
        }
        if (self.options.include_raw) {
            occurrence.raw_json = try self.allocator.dupe(u8, record.line);
        }
        try self.trace.occurrences.append(self.allocator, occurrence);
    }

    fn finish(self: *PiParser, io: std.Io, source_mtime_ns: i128) !void {
        const age_secs = @divTrunc(nowRealtimeNs(io) - source_mtime_ns, std.time.ns_per_s);
        const fresh = age_secs <= self.options.ongoing_threshold_secs;
        for (self.turn_states.items, 0..) |state, index| {
            if (state.status != .ongoing) continue;
            const active_turn = self.previous_context.turn_index;
            const active = active_turn != null and active_turn.? == index;
            const reason = if (!active)
                "pi_inactive_branch"
            else if (fresh)
                "fresh_ongoing_turn"
            else
                "stale_ongoing_file";
            const status: TurnStatus = if (active and fresh) .ongoing else .aborted;
            try self.setStatus(index, status, reason, null);
            if (active and fresh) self.trace.session.is_ongoing = true;
        }
        const reason = if (self.turn_states.items.len == 0)
            "no_turns"
        else
            self.turn_states.items[
                self.previous_context.turn_index orelse self.turn_states.items.len - 1
            ].reason;
        try replaceOpt(self.allocator, &self.trace.session.status_reason, reason);
        const settings = self.settingsAt(self.previous_context);
        try replaceNullable(self.allocator, &self.trace.session.model, settings.model);
        try replaceNullable(self.allocator, &self.trace.session.model_provider, settings.provider);
        self.trace.session.turn_count = @intCast(self.turn_states.items.len);
        for (self.trace.tools.items) |*tool| {
            if (tool.lifecycle_status == .declared) tool.lifecycle_status = .unresolved;
        }
    }

    fn warn(self: *PiParser, record: ParsedRecord, description: []const u8) !void {
        const warning = try self.allocator.print(
            "{s}:{d}: {s}",
            .{ self.trace.session.path, record.line_number, description },
        );
        errdefer self.allocator.free(warning);
        try self.trace.warnings.append(self.allocator, warning);
    }
};

fn piMessageOnlyThinking(root: std.json.ObjectMap) bool {
    const message = objectField(root, "message") orelse return false;
    if (!std.mem.eql(u8, stringField(message, "role") orelse "", "assistant")) return false;
    const content = message.get("content") orelse return false;
    const parts = valueArray(content) orelse return false;
    if (parts.items.len == 0) return false;
    for (parts.items) |part| {
        const block = valueObject(part) orelse return false;
        if (!std.mem.eql(u8, stringField(block, "type") orelse "", "thinking")) return false;
    }
    return true;
}

/// Payload is a public projection; only explicit raw_json retains thinking.
/// Shallow containers borrow parsed values until serialization, preserving the
/// persisted entry identity without copying or rewriting its private blocks.
fn piPayloadJsonAlloc(allocator: std.mem.Allocator, root: std.json.ObjectMap) !?[]u8 {
    if (piMessageOnlyThinking(root)) return null;
    const message = objectField(root, "message") orelse
        return try stringifyJsonValue(allocator, .{ .object = root });
    if (!std.mem.eql(u8, stringField(message, "role") orelse "", "assistant")) {
        return try stringifyJsonValue(allocator, .{ .object = root });
    }
    const content = message.get("content") orelse
        return try stringifyJsonValue(allocator, .{ .object = root });
    const parts = valueArray(content) orelse
        return try stringifyJsonValue(allocator, .{ .object = root });
    var public_parts = std.json.Array.init(allocator);
    defer public_parts.deinit();
    var public_blocks: std.ArrayList(std.json.ObjectMap) = .empty;
    defer {
        for (public_blocks.items) |*block| block.deinit(allocator);
        public_blocks.deinit(allocator);
    }
    for (parts.items) |part| {
        if (valueObject(part)) |block| {
            if (std.mem.eql(u8, stringField(block, "type") orelse "", "thinking")) continue;
            if (block.get("thoughtSignature") != null) {
                var public_block = try piObjectCopy(allocator, block);
                var owned = true;
                errdefer if (owned) public_block.deinit(allocator);
                _ = public_block.orderedRemove("thoughtSignature");
                try public_blocks.append(allocator, public_block);
                owned = false;
                try public_parts.append(.{ .object = public_block });
                continue;
            }
        }
        try public_parts.append(part);
    }
    var public_message = try piObjectCopy(allocator, message);
    defer public_message.deinit(allocator);
    try public_message.put(allocator, "content", .{ .array = public_parts });
    var public_root = try piObjectCopy(allocator, root);
    defer public_root.deinit(allocator);
    try public_root.put(allocator, "message", .{ .object = public_message });
    return try stringifyJsonValue(allocator, .{ .object = public_root });
}

fn piObjectCopy(allocator: std.mem.Allocator, source: std.json.ObjectMap) !std.json.ObjectMap {
    var copy: std.json.ObjectMap = .empty;
    errdefer copy.deinit(allocator);
    var fields = source.iterator();
    while (fields.next()) |field| try copy.put(allocator, field.key_ptr.*, field.value_ptr.*);
    return copy;
}

fn piAssistantStatus(stop_reason: []const u8) PiTurnState {
    if (std.mem.eql(u8, stop_reason, "stop")) {
        return .{ .status = .complete, .reason = "pi_stop" };
    }
    if (std.mem.eql(u8, stop_reason, "length")) {
        return .{ .status = .complete, .reason = "pi_length" };
    }
    if (std.mem.eql(u8, stop_reason, "error")) {
        return .{ .status = .@"error", .reason = "pi_error" };
    }
    if (std.mem.eql(u8, stop_reason, "aborted")) {
        return .{ .status = .aborted, .reason = "pi_aborted" };
    }
    return .{ .status = .ongoing, .reason = "pi_request_incomplete" };
}

fn piToolKind(name: []const u8) ToolKind {
    if (oneOfString(name, &.{ "bash", "powershell" })) return .exec_command;
    return kindFromName(name);
}

const PiUsage = struct {
    input_tokens: ?i64 = null,
    cached_input_tokens: ?i64 = null,
    output_tokens: ?i64 = null,
    reasoning_output_tokens: ?i64 = null,
    total_tokens: ?i64 = null,
    valid: bool = true,

    fn read(raw: std.json.ObjectMap) PiUsage {
        var usage = PiUsage{
            .input_tokens = piCounter(raw, "input"),
            .cached_input_tokens = piCounter(raw, "cacheRead"),
            .output_tokens = piCounter(raw, "output"),
            .reasoning_output_tokens = piCounter(raw, "reasoning"),
            .total_tokens = piCounter(raw, "totalTokens"),
        };
        const cache_write = piCounter(raw, "cacheWrite");
        usage.valid = usage.input_tokens != null and usage.cached_input_tokens != null and
            cache_write != null and usage.output_tokens != null and usage.total_tokens != null;
        if (raw.get("reasoning") != null and usage.reasoning_output_tokens == null) {
            usage.valid = false;
        }
        // Pi's input count excludes both cache categories. Canonical input
        // includes them; cacheRead is the reported cached subset of that input.
        const input_complete = usage.input_tokens != null and
            usage.cached_input_tokens != null and cache_write != null;
        if (input_complete) {
            const read_added = addPiCounter(&usage.input_tokens, usage.cached_input_tokens);
            const write_added = addPiCounter(&usage.input_tokens, cache_write);
            if (!read_added or !write_added) usage.input_tokens = null;
        } else {
            usage.input_tokens = null;
        }
        if (usage.output_tokens != null) {
            if (usage.reasoning_output_tokens) |reasoning| {
                if (reasoning > usage.output_tokens.?) usage.valid = false;
            }
        }
        if (usage.input_tokens == null) usage.valid = false;
        return usage;
    }
};

fn piCounter(raw: std.json.ObjectMap, key: []const u8) ?i64 {
    const raw_value = raw.get(key) orelse return null;
    if (raw_value == .float and @trunc(raw_value.float) != raw_value.float) return null;
    const value = intField(raw, key) orelse return null;
    return if (value >= 0) value else null;
}

fn addPiCounter(target: *?i64, value: ?i64) bool {
    if (value) |amount| target.* = std.math.add(i64, target.* orelse 0, amount) catch return false;
    return true;
}

fn addPiUsage(target: anytype, usage: PiUsage) bool {
    var valid = true;
    inline for (.{
        "input_tokens",            "cached_input_tokens", "output_tokens",
        "reasoning_output_tokens", "total_tokens",
    }) |field| {
        valid = addPiCounter(&@field(target, field), @field(usage, field)) and valid;
    }
    return valid;
}

fn replaceNullable(
    allocator: std.mem.Allocator,
    target: *?[]u8,
    value: ?[]const u8,
) !void {
    if (value) |text| {
        try replaceOpt(allocator, target, text);
    } else {
        freeOpt(allocator, target.*);
        target.* = null;
    }
}

const TraceParser = struct {
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    options: TraceParseOptions,
    current_turn_index: ?usize = null,
    synthetic_turns: i64 = 0,
    saw_task_started: bool = false,
    saw_primary_session_meta: bool = false,
    seen_messages: MessageDigestMap,
    tool_lookup: ToolLookup,

    fn ensure(self: *TraceParser, record: ParsedRecord, turn_id: ?[]const u8) !usize {
        return ensureTurn(
            self.allocator,
            self.trace,
            self.trace.session.path,
            &self.current_turn_index,
            &self.synthetic_turns,
            record.timestamp,
            turn_id,
        );
    }

    fn assignOccurrence(self: *TraceParser, occurrence_index: ?usize) void {
        const index = occurrence_index orelse return;
        const turn = self.current_turn_index orelse return;
        self.trace.occurrences.items[index].turn_index = self.trace.turns.items[turn].turn_index;
    }

    fn apply(self: *TraceParser, record: ParsedRecord) !void {
        const occurrence_index = if (self.options.include_occurrences)
            try appendOccurrence(
                self.allocator,
                self.trace,
                record.root,
                record.root_type,
                record.payload,
                record.timestamp,
                self.current_turn_index,
                record.line_number,
                record.line,
                self.options.include_raw,
                self.options.include_occurrence_payloads,
                self.saw_task_started,
                &self.seen_messages,
            )
        else
            null;
        if (record.isState()) return;
        try applySessionTimestamp(self.allocator, &self.trace.session, record.timestamp);
        if (record.root_type) |entry_type| {
            return self.applyTyped(record, entry_type, occurrence_index);
        }
        if (record.payload) |payload| {
            if (std.mem.eql(u8, stringField(payload, "type") orelse "", "session_meta")) {
                try self.applyMeta(payload, record.line_number);
            }
            return;
        }
        try self.applyLegacy(record);
        self.assignOccurrence(occurrence_index);
    }

    fn applyMeta(self: *TraceParser, meta: std.json.ObjectMap, line_number: usize) !void {
        try applyPrimarySessionMeta(
            self.allocator,
            self.trace,
            meta,
            &self.saw_primary_session_meta,
            line_number,
        );
    }

    fn applyTyped(
        self: *TraceParser,
        record: ParsedRecord,
        entry_type: []const u8,
        occurrence_index: ?usize,
    ) !void {
        const Kind = enum { session_meta, turn_context, compacted, event_msg, response_item };
        const kind = std.meta.stringToEnum(Kind, entry_type) orelse return;
        switch (kind) {
            .session_meta => {
                if (record.payload) |payload| try self.applyMeta(payload, record.line_number);
                return;
            },
            .turn_context => {
                const idx = try self.ensure(record, null);
                const turn = &self.trace.turns.items[idx];
                try applyTurnContext(self.allocator, turn, record.payload orelse record.root);
                try applySessionContextFromTurn(self.allocator, &self.trace.session, turn.*);
            },
            .compacted => {
                const idx = try self.ensure(record, null);
                self.trace.turns.items[idx].has_compaction = true;
            },
            .event_msg => if (record.payload) |payload| {
                try self.applyEvent(record, payload, occurrence_index);
            },
            .response_item => if (record.payload) |payload| {
                try applyResponseItem(
                    self.allocator,
                    self.trace,
                    &self.tool_lookup,
                    self.trace.session.path,
                    &self.current_turn_index,
                    &self.synthetic_turns,
                    self.saw_task_started,
                    payload,
                    record.timestamp,
                    record.line_number,
                    self.options,
                );
            },
        }
        self.assignOccurrence(occurrence_index);
    }

    fn applyEvent(
        self: *TraceParser,
        record: ParsedRecord,
        payload: std.json.ObjectMap,
        occurrence_index: ?usize,
    ) !void {
        const event_type = stringField(payload, "type") orelse "";
        const Kind = enum {
            task_started,
            user_message,
            agent_message,
            task_complete,
            turn_aborted,
            @"error",
            token_count,
            thread_settings_applied,
            thread_name_updated,
        };
        const kind = std.meta.stringToEnum(Kind, event_type) orelse {
            if (std.mem.endsWith(u8, event_type, "_end")) {
                const idx = try self.ensure(record, stringField(payload, "turn_id"));
                try finalizeToolEvent(
                    self.allocator,
                    self.trace,
                    &self.tool_lookup,
                    idx,
                    payload,
                    event_type,
                    record.timestamp,
                    record.line_number,
                    self.options.max_tools,
                );
            }
            return;
        };
        switch (kind) {
            .task_started => try self.start(record, payload),
            .user_message, .agent_message => {
                const idx = try self.ensure(record, stringField(payload, "turn_id"));
                if (!self.options.include_message_bodies) return;
                const msg = stringField(payload, "message") orelse
                    stringField(payload, "text") orelse "";
                const turn = &self.trace.turns.items[idx];
                if (kind == .user_message) {
                    try replaceUserMessage(self.allocator, turn, msg);
                } else {
                    try attachAssistantMessage(self.allocator, turn, msg, record.line_number);
                }
            },
            .task_complete, .turn_aborted, .@"error" => {
                try self.complete(record, payload, event_type);
            },
            .token_count => try self.tokens(record, payload, occurrence_index),
            .thread_settings_applied => {
                try applyThreadSettings(self.allocator, &self.trace.session, payload);
            },
            .thread_name_updated => {
                const name = stringField(payload, "thread_name") orelse
                    stringField(payload, "name");
                const value = name orelse return;
                try replaceOpt(self.allocator, &self.trace.session.thread_name, value);
                if (self.current_turn_index) |idx| {
                    try replaceOpt(self.allocator, &self.trace.turns.items[idx].thread_name, value);
                }
            },
        }
    }

    fn start(self: *TraceParser, record: ParsedRecord, payload: std.json.ObjectMap) !void {
        self.saw_task_started = true;
        const idx = try startTurn(
            self.allocator,
            self.trace,
            self.trace.session.path,
            &self.current_turn_index,
            stringField(payload, "turn_id"),
            record.timestamp,
        );
        try replaceOpt(self.allocator, &self.trace.turns.items[idx].status_reason, "task_started");
    }

    fn complete(
        self: *TraceParser,
        record: ParsedRecord,
        payload: std.json.ObjectMap,
        event_type: []const u8,
    ) !void {
        const is_error = std.mem.eql(u8, event_type, "error");
        const idx = if (is_error)
            try self.ensure(record, stringField(payload, "turn_id"))
        else
            self.current_turn_index orelse return;
        const turn = &self.trace.turns.items[idx];
        const status: TurnStatus = if (is_error) .@"error" else status: {
            break :status if (std.mem.eql(u8, event_type, "turn_aborted")) .aborted else .complete;
        };
        try completeTurn(self.allocator, turn, status, event_type, record.timestamp, payload);
        if (status == .aborted) {
            const reason = stringField(payload, "reason") orelse "turn_aborted";
            try replaceOpt(self.allocator, &turn.aborted_reason, reason);
        } else if (is_error) {
            const message = stringField(payload, "message") orelse
                stringField(payload, "error") orelse "error";
            try replaceOpt(self.allocator, &turn.@"error", message);
        }
    }

    fn tokens(
        self: *TraceParser,
        record: ParsedRecord,
        payload: std.json.ObjectMap,
        occurrence_index: ?usize,
    ) !void {
        const idx = try self.ensure(record, stringField(payload, "turn_id"));
        applyTokenCount(&self.trace.turns.items[idx], &self.trace.session, payload);
        if (!self.options.include_token_events) return;
        var event = try tokenEvent(
            self.allocator,
            occurrence_index orelse return error.TokenEventOccurrenceMissing,
            self.trace.turns.items[idx].turn_index,
            self.trace.session,
            payload,
        );
        errdefer event.deinit(self.allocator);
        try self.trace.token_events.append(self.allocator, event);
    }

    fn applyLegacy(self: *TraceParser, record: ParsedRecord) !void {
        const root = record.root;
        if (root.get("id") != null and root.get("timestamp") != null) {
            try self.applyMeta(root, record.line_number);
        } else if (root.get("role") != null and root.get("content") != null) {
            try self.applyLegacyMessage(record);
        } else if (root.get("call_id") != null and
            root.get("arguments") != null and root.get("name") != null)
        {
            const idx = try self.ensure(record, null);
            try declareTool(
                self.allocator,
                self.trace,
                &self.tool_lookup,
                idx,
                root,
                record.timestamp,
                record.line_number,
                self.options.max_tools,
            );
        } else if (root.get("call_id") != null and root.get("output") != null) {
            const idx = try self.ensure(record, null);
            try finalizeToolOutput(
                self.allocator,
                self.trace,
                &self.tool_lookup,
                idx,
                root,
                "function_call_output",
                record.timestamp,
                record.line_number,
                self.options.max_tools,
            );
        }
    }

    fn applyLegacyMessage(self: *TraceParser, record: ParsedRecord) !void {
        const role = stringField(record.root, "role") orelse "";
        const is_user = std.mem.eql(u8, role, "user");
        if (!is_user and !std.mem.eql(u8, role, "assistant")) return;
        const idx = if (is_user)
            try startSyntheticTurn(
                self.allocator,
                self.trace,
                self.trace.session.path,
                &self.current_turn_index,
                &self.synthetic_turns,
                record.timestamp,
            )
        else
            try self.ensure(record, null);
        const turn = &self.trace.turns.items[idx];
        if (self.options.include_message_bodies) {
            const text = try messageTextAlloc(self.allocator, record.root);
            defer self.allocator.free(text);
            if (is_user) {
                try attachUserMessage(self.allocator, turn, text);
            } else {
                try attachAssistantMessage(self.allocator, turn, text, record.line_number);
            }
        }
        if (!is_user) {
            try completeTurn(
                self.allocator,
                turn,
                .complete,
                "synthetic_message_boundary",
                record.timestamp,
                record.root,
            );
        }
    }
};

fn applySessionTimestamp(
    allocator: std.mem.Allocator,
    session: *SessionRecord,
    timestamp: ?[]const u8,
) !void {
    if (session.start_time == null) session.start_time = try dupOpt(allocator, timestamp);
    if (timestamp) |value| try replaceOpt(allocator, &session.end_time, value);
}

fn applyThreadSettings(
    allocator: std.mem.Allocator,
    session: *SessionRecord,
    payload: std.json.ObjectMap,
) !void {
    const settings = objectField(payload, "thread_settings") orelse return;
    if (stringField(settings, "model")) |value| try replaceOpt(allocator, &session.model, value);
    if (stringField(settings, "service_tier")) |value| {
        try replaceOpt(allocator, &session.service_tier, value);
    }
}

fn finalizeTrace(
    io: std.Io,
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    source_mtime_ns: i128,
    options: TraceParseOptions,
) !void {
    const age_secs = @divTrunc(nowRealtimeNs(io) - source_mtime_ns, std.time.ns_per_s);
    for (trace.turns.items) |*turn| {
        if (turn.status != .ongoing) continue;
        const fresh = age_secs <= options.ongoing_threshold_secs;
        const reason = if (fresh) "fresh_ongoing_turn" else "stale_ongoing_file";
        if (fresh) trace.session.is_ongoing = true else turn.status = .aborted;
        try replaceOpt(allocator, &turn.status_reason, reason);
        try replaceOpt(allocator, &trace.session.status_reason, reason);
    }
    if (!trace.session.is_ongoing and trace.session.status_reason == null) {
        const reason = if (trace.turns.items.len == 0) "no_turns" else blk: {
            const last = trace.turns.items[trace.turns.items.len - 1];
            break :blk last.status_reason orelse @tagName(last.status);
        };
        try replaceOpt(allocator, &trace.session.status_reason, reason);
    }
    for (trace.tools.items) |*tool| {
        if (tool.lifecycle_status == .declared) tool.lifecycle_status = .unresolved;
    }
    trace.session.turn_count = @intCast(trace.turns.items.len);
}

pub fn parseSessionSummaryTrace(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    path: []const u8,
    options: TraceParseOptions,
) !CanonicalSessionTrace {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    var reader = file.reader(io, &.{});
    return parseSessionSummaryTraceReader(
        io,
        allocator,
        path,
        &reader.interface,
        stat.mtime.nanoseconds,
        options,
    );
}

pub fn parseSessionSummaryTraceReader(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    reader: *std.Io.Reader,
    source_mtime_ns: i128,
    options: TraceParseOptions,
) !CanonicalSessionTrace {
    const Ignore = struct {
        fn visit(_: void, _: []const u8, _: usize) !void {}
    };
    return parseSessionSummaryTraceReaderWithVisitor(
        io,
        allocator,
        path,
        reader,
        source_mtime_ns,
        options,
        {},
        Ignore.visit,
    );
}

pub fn parseSessionSummaryTraceReaderWithVisitor(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    reader: *std.Io.Reader,
    source_mtime_ns: i128,
    options: TraceParseOptions,
    context: anytype,
    comptime visit: anytype,
) !CanonicalSessionTrace {
    var metrics = StreamMetrics{};
    return parseSessionSummaryTraceReaderWithVisitorMetrics(
        io,
        allocator,
        path,
        reader,
        source_mtime_ns,
        options,
        context,
        visit,
        &metrics,
    );
}

pub fn parseSessionSummaryTraceReaderWithVisitorMetrics(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    reader: *std.Io.Reader,
    source_mtime_ns: i128,
    options: TraceParseOptions,
    context: anytype,
    comptime visit: anytype,
    metrics: *StreamMetrics,
) !CanonicalSessionTrace {
    var trace = CanonicalSessionTrace{ .session = try SessionRecord.init(allocator, path) };
    errdefer trace.deinit(allocator);
    trace.session.date_group = try deriveDateGroup(allocator, path);
    var parser = SummaryParser{
        .allocator = allocator,
        .trace = &trace,
        .seen_turn_ids = std.StringHashMap(void).init(allocator),
    };
    defer parser.deinit();
    var pi_parser = PiParser.init(allocator, &trace, options, true);
    defer pi_parser.deinit();
    var source_is_pi: ?bool = null;
    var scratch = ParseScratch.init(allocator);
    defer scratch.deinit();
    var lines = try jsonl_stream.Stream.init(allocator, reader, .{});
    defer lines.deinit();
    while (try lines.next()) |record| {
        defer scratch.reset();
        try visit(context, record.bytes, record.number);
        const line = std.mem.trim(u8, record.bytes, " \t\r\n");
        if (line.len == 0) continue;
        if (source_is_pi != null and !source_is_pi.?) {
            if (fastTimestampSlice(line)) |timestamp| {
                try applySessionTimestamp(allocator, &trace.session, timestamp);
            }
            if (!sessionSummaryLineCouldMatter(line)) continue;
        }
        const root = scratch.parse(line) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try appendMalformedWarning(allocator, &trace, record.number);
                continue;
            },
        } orelse continue;
        if (source_is_pi == null) source_is_pi = isPiSessionHeader(root);
        const parsed_record = ParsedRecord.init(root, record.number, line);
        if (source_is_pi.?) {
            try pi_parser.apply(parsed_record);
        } else {
            try parser.apply(parsed_record);
        }
    }
    if (source_is_pi orelse false) {
        try pi_parser.finish(io, source_mtime_ns);
    } else {
        try parser.finish(io, source_mtime_ns, options);
    }
    metrics.* = .{ .bytes_read = lines.bytes_read, .lines_seen = lines.line_number };
    return trace;
}

const SummaryParser = struct {
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    seen_turn_ids: std.StringHashMap(void),
    last_turn_open: bool = false,
    saw_primary_session_meta: bool = false,

    fn deinit(self: *SummaryParser) void {
        var it = self.seen_turn_ids.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.seen_turn_ids.deinit();
    }

    fn applyMeta(self: *SummaryParser, meta: std.json.ObjectMap, line_number: usize) !void {
        try applyPrimarySessionMeta(
            self.allocator,
            self.trace,
            meta,
            &self.saw_primary_session_meta,
            line_number,
        );
    }

    fn apply(self: *SummaryParser, record: ParsedRecord) !void {
        if (record.isState()) return;
        try applySessionTimestamp(self.allocator, &self.trace.session, record.timestamp);
        if (record.root_type) |entry_type| {
            const payload = record.payload orelse return;
            if (std.mem.eql(u8, entry_type, "session_meta")) {
                try self.applyMeta(payload, record.line_number);
            } else if (std.mem.eql(u8, entry_type, "turn_context")) {
                try applySessionContextFields(self.allocator, &self.trace.session, payload);
            } else if (std.mem.eql(u8, entry_type, "event_msg")) {
                try self.applyEvent(payload, record.timestamp);
            }
            return;
        }
        if (record.payload) |payload| {
            if (std.mem.eql(u8, stringField(payload, "type") orelse "", "session_meta")) {
                try self.applyMeta(payload, record.line_number);
            }
        } else if (record.root.get("id") != null and record.root.get("timestamp") != null) {
            try self.applyMeta(record.root, record.line_number);
        }
    }

    fn applyEvent(
        self: *SummaryParser,
        payload: std.json.ObjectMap,
        timestamp: ?[]const u8,
    ) !void {
        const event_type = stringField(payload, "type") orelse "";
        const Kind = enum {
            task_started,
            task_complete,
            turn_aborted,
            @"error",
            token_count,
            thread_settings_applied,
            thread_name_updated,
            collab_agent_spawn_end,
        };
        const kind = std.meta.stringToEnum(Kind, event_type) orelse return;
        const session = &self.trace.session;
        switch (kind) {
            .task_started, .@"error" => {
                try noteSummaryTurn(
                    self.allocator,
                    session,
                    &self.seen_turn_ids,
                    stringField(payload, "turn_id"),
                );
                self.last_turn_open = kind == .task_started;
                const error_message = stringField(payload, "message") orelse
                    stringField(payload, "error") orelse "error";
                const reason = if (self.last_turn_open) "task_started" else error_message;
                try replaceOpt(self.allocator, &session.status_reason, reason);
            },
            .task_complete, .turn_aborted => {
                self.last_turn_open = false;
                const aborted_reason = stringField(payload, "reason") orelse "turn_aborted";
                const reason = if (kind == .task_complete) "task_complete" else aborted_reason;
                try replaceOpt(self.allocator, &session.status_reason, reason);
            },
            .token_count => applyTokenCountToSession(session, payload),
            .thread_settings_applied => try applyThreadSettings(self.allocator, session, payload),
            .thread_name_updated => {
                const name = stringField(payload, "thread_name") orelse
                    stringField(payload, "name");
                if (name) |value| try replaceOpt(self.allocator, &session.thread_name, value);
            },
            .collab_agent_spawn_end => {
                try appendGraphEdge(self.allocator, self.trace, payload, timestamp);
                session.spawned_worker_count += 1;
            },
        }
    }

    fn finish(
        self: *SummaryParser,
        io: std.Io,
        source_mtime_ns: i128,
        options: TraceParseOptions,
    ) !void {
        const session = &self.trace.session;
        const age_secs = @divTrunc(nowRealtimeNs(io) - source_mtime_ns, std.time.ns_per_s);
        if (self.last_turn_open) {
            const fresh = age_secs <= options.ongoing_threshold_secs;
            const reason = if (fresh) "fresh_ongoing_turn" else "stale_ongoing_file";
            session.is_ongoing = fresh;
            try replaceOpt(self.allocator, &session.status_reason, reason);
        }
        if (!session.is_ongoing and session.status_reason == null) {
            const reason = if (session.turn_count == 0) "no_turns" else "task_complete";
            try replaceOpt(self.allocator, &session.status_reason, reason);
        }
    }
};

const OccurrenceSource = struct {
    source: std.json.ObjectMap,
    entry_type: []const u8,
    event_type: ?[]const u8,
    role: ?[]const u8,
    private: bool,

    fn init(
        root: std.json.ObjectMap,
        root_type: ?[]const u8,
        payload: ?std.json.ObjectMap,
    ) OccurrenceSource {
        const source = payload orelse root;
        const entry_type = occurrenceEntryType(root, root_type, source);
        const event_type = stringField(source, "type") orelse
            if (std.mem.eql(u8, entry_type, "message")) stringField(source, "role") else null;
        const role = stringField(source, "role") orelse role: {
            if (!std.mem.eql(u8, entry_type, "event_msg")) break :role null;
            const kind = event_type orelse "";
            if (std.mem.eql(u8, kind, "user_message")) break :role "user";
            if (std.mem.eql(u8, kind, "agent_message")) break :role "assistant";
            break :role null;
        };
        return .{
            .source = source,
            .entry_type = entry_type,
            .event_type = event_type,
            .role = role,
            .private = std.mem.eql(u8, entry_type, "reasoning") or
                std.mem.eql(u8, event_type orelse "", "reasoning"),
        };
    }

    fn textAlloc(self: OccurrenceSource, allocator: std.mem.Allocator) !?[]u8 {
        if (self.private) return null;
        const kind = self.event_type orelse "";
        if ((std.mem.eql(u8, self.entry_type, "response_item") and
            std.mem.eql(u8, kind, "message")) or std.mem.eql(u8, self.entry_type, "message"))
        {
            return try messageTextAlloc(allocator, self.source);
        }
        if (std.mem.eql(u8, self.entry_type, "event_msg") and
            oneOfString(kind, &.{ "user_message", "agent_message" }))
        {
            const message = stringField(self.source, "message") orelse
                stringField(self.source, "text") orelse "";
            return try allocator.dupe(u8, message);
        }
        return null;
    }
};

fn occurrenceEntryType(
    root: std.json.ObjectMap,
    root_type: ?[]const u8,
    source: std.json.ObjectMap,
) []const u8 {
    if (stringField(root, "record_type")) |kind| {
        return if (std.mem.eql(u8, kind, "state")) "state" else "unknown";
    }
    if (root_type) |kind| return kind;
    if (stringField(source, "type")) |kind| {
        const allowed = &.{
            "session_meta", "turn_context",  "compacted",
            "event_msg",    "response_item", "world_state",
        };
        return if (oneOfString(kind, allowed)) kind else "unknown";
    }
    if (root.get("id") != null and root.get("timestamp") != null) return "session_meta";
    if (root.get("role") != null) return "message";
    if (root.get("call_id") != null and root.get("arguments") != null) return "function_call";
    if (root.get("call_id") != null and root.get("output") != null) return "function_call_output";
    if (root.get("encrypted_content") != null) return "reasoning";
    return "unknown";
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
    raw_json: []const u8,
    include_raw: bool,
    include_payload: bool,
    saw_task_started: bool,
    seen_messages: *MessageDigestMap,
) !usize {
    const source = OccurrenceSource.init(root, root_type, payload);
    var text = try source.textAlloc(allocator);
    defer freeOpt(allocator, text);
    const visible = try occurrenceMessageVisible(
        allocator,
        trace,
        source,
        &text,
        current_turn_index,
        saw_task_started,
        timestamp,
        seen_messages,
    );
    var occurrence = try TraceOccurrence.init(
        allocator,
        trace.session.path,
        line_number,
        trace.occurrences.items.len,
        if (current_turn_index) |index| trace.turns.items[index].turn_index else null,
        source.entry_type,
        source.event_type,
        source.role,
        text,
        source.private,
    );
    errdefer occurrence.deinit(allocator);
    occurrence.message_visible = visible;
    occurrence.timestamp = if (timestamp) |value|
        try normalizeTimestampAlloc(allocator, value)
    else
        null;
    occurrence.payload_json = if (!source.private and include_payload)
        try stringifyJsonValue(
            allocator,
            if (payload != null) root.get("payload").? else std.json.Value{ .object = root },
        )
    else
        null;
    occurrence.raw_json = if (include_raw) try allocator.dupe(u8, raw_json) else null;
    occurrence.format = traceFormat(root, root_type, payload);
    try trace.occurrences.append(allocator, occurrence);
    return trace.occurrences.items.len - 1;
}

fn occurrenceMessageVisible(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    source: OccurrenceSource,
    text: *?[]u8,
    current_turn_index: ?usize,
    saw_task_started: bool,
    timestamp: ?[]const u8,
    seen_messages: *MessageDigestMap,
) !bool {
    const role = source.role orelse return false;
    const message = text.* orelse return false;
    if (!oneOfString(role, &.{ "user", "assistant" })) return false;
    const selected = if (std.mem.eql(u8, role, "assistant")) stripEchoView(message) else message;
    const normalized = try normalizeMessageTextAlloc(allocator, selected);
    allocator.free(message);
    text.* = normalized;
    if (normalized.len == 0) return false;
    if (std.mem.eql(u8, role, "user") and isMetaUserMessage(normalized)) return false;
    const carrier: u8 = if (std.mem.eql(u8, source.entry_type, "event_msg")) 0b10 else 0b01;
    const counterpart: u8 = if (carrier == 0b01) 0b10 else 0b01;
    const digest = messageMirrorDigest(
        role,
        normalized,
        messageTurnKey(
            trace,
            source.source,
            source.entry_type,
            role,
            current_turn_index,
            saw_task_started,
        ),
        timestamp,
    );
    const entry = try seen_messages.getOrPut(digest);
    if (!entry.found_existing) entry.value_ptr.* = 0;
    const visible = entry.value_ptr.* & counterpart == 0;
    entry.value_ptr.* |= carrier;
    return visible;
}

fn computeSourceEventId(path: []const u8, line_number: usize, ordinal: usize) [71]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("trace-source-event/v1\x00");
    hasher.update(path);
    var number: [8]u8 = undefined;
    std.mem.writeInt(u64, &number, @intCast(line_number), .big);
    hasher.update(&number);
    std.mem.writeInt(u64, &number, @intCast(ordinal), .big);
    hasher.update(&number);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    var identity: [71]u8 = undefined;
    @memcpy(identity[0..7], "sha256:");
    @memcpy(identity[7..], &hex);
    return identity;
}

fn traceFormat(
    root: std.json.ObjectMap,
    root_type: ?[]const u8,
    payload: ?std.json.ObjectMap,
) TraceFormat {
    if (root_type != null) return .new_044_plus;
    if (payload != null) return .mid_payload_meta;
    if ((root.get("id") != null and root.get("timestamp") != null) or
        (root.get("role") != null and root.get("content") != null) or
        (root.get("call_id") != null and root.get("arguments") != null) or
        (root.get("call_id") != null and root.get("output") != null) or
        root.get("encrypted_content") != null)
    {
        return .old_2025_08_root_meta;
    }
    return .unknown;
}

pub fn cutBoundContextAlloc(
    allocator: std.mem.Allocator,
    trace: CanonicalSessionTrace,
    last_fixed_line: usize,
) !CutBoundContext {
    var context = CutBoundContext{};
    errdefer context.deinit(allocator);
    var saw_primary_meta = false;
    for (trace.occurrences.items) |occurrence| {
        if (occurrence.line_number > last_fixed_line) break;
        const payload_json = occurrence.payload_json orelse continue;
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            payload_json,
            .{},
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        defer parsed.deinit();
        const payload = switch (parsed.value) {
            .object => |map| map,
            else => continue,
        };
        if (std.mem.eql(u8, occurrence.entry_type, "session_meta")) {
            if (saw_primary_meta) continue;
            saw_primary_meta = true;
            try applyCutSessionContext(allocator, &context, payload);
        } else if (std.mem.eql(u8, occurrence.entry_type, "turn_context")) {
            try applyCutTurnContext(allocator, &context, payload);
        }
    }
    return context;
}

fn applyCutSessionContext(
    allocator: std.mem.Allocator,
    context: *CutBoundContext,
    payload: std.json.ObjectMap,
) !void {
    if (stringField(payload, "cwd")) |v| try replaceOpt(allocator, &context.cwd, v);
    if (stringField(payload, "cli_version")) |v| try replaceOpt(allocator, &context.cli_version, v);
    if (stringField(payload, "model")) |v| try replaceOpt(allocator, &context.model, v);
    if (stringField(payload, "model_provider")) |v| {
        try replaceOpt(allocator, &context.model_provider, v);
    }
    if (stringField(payload, "git_commit_hash")) |v| {
        try replaceOpt(allocator, &context.git_commit_hash, v);
    }
    if (objectField(payload, "git")) |git| {
        if (stringField(git, "commit_hash")) |v| {
            try replaceOpt(allocator, &context.git_commit_hash, v);
        }
    }
    if (payload.get("context_window")) |value| {
        const encoded = try stringifyJsonValue(allocator, value);
        defer allocator.free(encoded);
        try replaceOpt(allocator, &context.context_window_json, encoded);
    }
}

fn applyCutTurnContext(
    allocator: std.mem.Allocator,
    context: *CutBoundContext,
    payload: std.json.ObjectMap,
) !void {
    if (stringField(payload, "cwd")) |v| try replaceOpt(allocator, &context.cwd, v);
    if (stringField(payload, "model")) |v| try replaceOpt(allocator, &context.model, v);
    if (stringField(payload, "model_provider")) |v| {
        try replaceOpt(allocator, &context.model_provider, v);
    }
    if (stringField(payload, "reasoning_effort") orelse stringField(payload, "effort")) |v| {
        try replaceOpt(allocator, &context.reasoning_effort, v);
    }
    if (stringField(payload, "comp_hash")) |v| {
        try replaceOpt(allocator, &context.compaction_identity, v);
    }
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

fn applySessionContextFields(
    allocator: std.mem.Allocator,
    session: *SessionRecord,
    ctx: std.json.ObjectMap,
) !void {
    if (session.model == null) {
        if (stringField(ctx, "model")) |v| try replaceOpt(allocator, &session.model, v);
    }
    if (session.cwd == null) {
        if (stringField(ctx, "cwd")) |v| try replaceOpt(allocator, &session.cwd, v);
    }
}

fn noteSummaryTurn(
    allocator: std.mem.Allocator,
    session: *SessionRecord,
    seen_turn_ids: *std.StringHashMap(void),
    turn_id_opt: ?[]const u8,
) !void {
    if (turn_id_opt) |turn_id| {
        if (seen_turn_ids.contains(turn_id)) return;
        const owned_id = try allocator.dupe(u8, turn_id);
        errdefer allocator.free(owned_id);
        try seen_turn_ids.put(owned_id, {});
    }
    session.turn_count += 1;
}

fn applyTokenCountToSession(session: *SessionRecord, payload: std.json.ObjectMap) void {
    const info = objectField(payload, "info") orelse payload;
    const total = objectField(info, "total_token_usage") orelse
        objectField(info, "last_token_usage") orelse return;
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
        .float => |v| blk: {
            // The upper i64 bound rounds to 2^63 in f64 and must stay exclusive.
            if (!std.math.isFinite(v) or v < -0x1p63 or v >= 0x1p63) break :blk null;
            break :blk @intFromFloat(v);
        },
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
    slot.* = try dupReplace(allocator, slot.*, value);
}

fn dupReplace(allocator: std.mem.Allocator, old: ?[]u8, value: []const u8) ![]u8 {
    const replacement = try allocator.dupe(u8, value);
    if (old) |v| allocator.free(v);
    return replacement;
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
            return try allocator.print("{s}-{s}-{s}", .{
                path[i .. i + 4],
                path[i + 5 .. i + 7],
                path[i + 8 .. i + 10],
            });
        }
    }
    return null;
}

fn applySessionMeta(
    allocator: std.mem.Allocator,
    session: *SessionRecord,
    meta: std.json.ObjectMap,
) !void {
    if (stringField(meta, "id")) |v| try replaceOpt(allocator, &session.session_id, v);
    if (stringField(meta, "session_id")) |v| try replaceOpt(allocator, &session.root_session_id, v);
    if (stringField(meta, "cwd")) |v| try replaceOpt(allocator, &session.cwd, v);
    if (stringField(meta, "originator")) |v| try replaceOpt(allocator, &session.originator, v);
    if (stringField(meta, "cli_version")) |v| try replaceOpt(allocator, &session.cli_version, v);
    if (stringField(meta, "model")) |v| try replaceOpt(allocator, &session.model, v);
    if (stringField(meta, "model_provider")) |v| {
        try replaceOpt(allocator, &session.model_provider, v);
    }
    if (stringField(meta, "thread_name")) |v| try replaceOpt(allocator, &session.thread_name, v);
    if (stringField(meta, "git_branch")) |v| try replaceOpt(allocator, &session.git_branch, v);
    if (stringField(meta, "git_commit_hash")) |v| {
        try replaceOpt(allocator, &session.git_commit_hash, v);
    }
    if (stringField(meta, "git_repository_url")) |v| {
        try replaceOpt(allocator, &session.git_repository_url, v);
    }
    const parent_thread_id = stringField(meta, "parent_thread_id");
    const forked_from_id = stringField(meta, "forked_from_id");
    if (parent_thread_id != null and forked_from_id != null and
        !std.mem.eql(u8, parent_thread_id.?, forked_from_id.?))
    {
        session.lineage_conflict = true;
    }
    if (parent_thread_id orelse forked_from_id) |v| {
        try replaceOpt(allocator, &session.parent_session_id, v);
        try replaceOpt(
            allocator,
            &session.parent_relation,
            if (parent_thread_id != null) "parent_thread_id" else "forked_from_id",
        );
    }
    if (session.root_session_id == null) {
        if (session.session_id) |v| try replaceOpt(allocator, &session.root_session_id, v);
    }
    if (nestedObject(meta, "source", "subagent")) |_| session.is_external_worker = true;
    if (objectField(meta, "git")) |git| {
        if (stringField(git, "branch")) |v| try replaceOpt(allocator, &session.git_branch, v);
        if (stringField(git, "commit_hash")) |v| {
            try replaceOpt(allocator, &session.git_commit_hash, v);
        }
        if (stringField(git, "repository_url")) |v| {
            try replaceOpt(allocator, &session.git_repository_url, v);
        }
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
        const warning = try allocator.print(
            "{s}:{d}: conflicting later session_meta {s} preserved as an occurrence; " ++
                "primary session {s} remains authoritative",
            .{ trace.session.path, line_number, later_id, primary_id },
        );
        errdefer allocator.free(warning);
        try trace.warnings.append(allocator, warning);
    }
}

fn applyTurnContext(
    allocator: std.mem.Allocator,
    turn: *TurnRecord,
    ctx: std.json.ObjectMap,
) !void {
    if (stringField(ctx, "model")) |v| try replaceOpt(allocator, &turn.model, v);
    if (stringField(ctx, "cwd")) |v| try replaceOpt(allocator, &turn.cwd, v);
    if (stringField(ctx, "reasoning_effort") orelse stringField(ctx, "effort")) |v| {
        try replaceOpt(allocator, &turn.reasoning_effort, v);
    }
}

fn applySessionContextFromTurn(
    allocator: std.mem.Allocator,
    session: *SessionRecord,
    turn: TurnRecord,
) !void {
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
        owned_id = try allocator.print("turn-{d}", .{trace.turns.items.len + 1});
        break :blk owned_id.?;
    };
    var turn = TurnRecord{
        .path = try allocator.dupe(u8, path),
        .turn_id = &.{},
        .turn_index = @intCast(trace.turns.items.len + 1),
        .status = .ongoing,
    };
    errdefer turn.deinit(allocator);
    turn.turn_id = try allocator.dupe(u8, turn_id);
    turn.session_id = try dupOpt(allocator, trace.session.session_id);
    turn.started_at = try dupOpt(allocator, timestamp);
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
    const turn_id = try allocator.print("turn-{d}", .{synthetic_turns.*});
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
    return startSyntheticTurn(
        allocator,
        trace,
        path,
        current_turn_index,
        synthetic_turns,
        timestamp,
    );
}

fn attachUserMessage(allocator: std.mem.Allocator, turn: *TurnRecord, text: []const u8) !void {
    if (turn.user_message == null) try replaceUserMessage(allocator, turn, text);
}

fn replaceUserMessage(allocator: std.mem.Allocator, turn: *TurnRecord, text: []const u8) !void {
    const message = try allocator.dupe(u8, text);
    errdefer allocator.free(message);
    const preview = try previewAlloc(allocator, text);
    if (turn.user_message) |old| allocator.free(old);
    if (turn.user_preview) |old| allocator.free(old);
    turn.user_message = message;
    turn.user_preview = preview;
}

fn attachAssistantMessage(
    allocator: std.mem.Allocator,
    turn: *TurnRecord,
    text: []const u8,
    line_number: usize,
) !void {
    const message = try allocator.dupe(u8, text);
    errdefer allocator.free(message);
    const preview = try previewAlloc(allocator, text);
    if (turn.final_answer) |old| allocator.free(old);
    turn.final_answer = message;
    turn.final_answer_line = line_number;
    if (turn.assistant_preview) |old| allocator.free(old);
    turn.assistant_preview = preview;
}

fn completeTurn(
    allocator: std.mem.Allocator,
    turn: *TurnRecord,
    status: TurnStatus,
    reason: []const u8,
    timestamp: ?[]const u8,
    payload: std.json.ObjectMap,
) !void {
    turn.status = status;
    turn.status_reason = try dupReplace(allocator, turn.status_reason, reason);
    if (timestamp) |ts| try replaceOpt(allocator, &turn.completed_at, ts);
    if (intField(payload, "duration_ms")) |v| turn.duration_ms = v;
    if (intField(payload, "duration")) |v| turn.duration_ms = v;
    if (intField(payload, "duration_secs")) |v| {
        if (durationMilliseconds(v)) |milliseconds| turn.duration_ms = milliseconds;
    }
}

fn durationMilliseconds(seconds: i64) ?i64 {
    return std.math.mul(i64, seconds, 1000) catch null;
}

test "numeric fields ignore unrepresentable integer values" {
    const allocator = std.testing.allocator;
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(allocator);
    const cases = [_]struct { value: f64, expected: ?i64 }{
        .{ .value = 3.9, .expected = 3 },
        .{ .value = -3.9, .expected = -3 },
        .{ .value = -0x1p63, .expected = std.math.minInt(i64) },
        .{ .value = 0x1p63, .expected = null },
        .{ .value = -0x1p64, .expected = null },
        .{ .value = std.math.inf(f64), .expected = null },
        .{ .value = -std.math.inf(f64), .expected = null },
        .{ .value = std.math.nan(f64), .expected = null },
    };
    for (cases) |case| {
        try object.put(allocator, "value", .{ .float = case.value });
        try std.testing.expectEqual(case.expected, intField(object, "value"));
    }
    try std.testing.expectEqual(@as(?i64, 3000), durationMilliseconds(3));
    try std.testing.expectEqual(@as(?i64, -3000), durationMilliseconds(-3));
    try std.testing.expectEqual(@as(?i64, null), durationMilliseconds(std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(?i64, null), durationMilliseconds(std.math.minInt(i64)));
}

test "message replacements preserve allocation ownership at every failure" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkMessageReplacementAllocationFailures,
        .{},
    );
}

fn checkMessageReplacementAllocationFailures(allocator: std.mem.Allocator) !void {
    var turn = TurnRecord{
        .path = try allocator.dupe(u8, "trace.jsonl"),
        .turn_id = &.{},
        .turn_index = 1,
    };
    defer turn.deinit(allocator);
    try replaceUserMessage(allocator, &turn, "user one");
    try replaceUserMessage(allocator, &turn, "user two");
    try attachAssistantMessage(allocator, &turn, "assistant one", 1);
    try attachAssistantMessage(allocator, &turn, "assistant two", 2);
    try replaceOpt(allocator, &turn.model, "initial");
    try replaceOpt(allocator, &turn.model, turn.model.?);
    try std.testing.expectEqualStrings("initial", turn.model.?);
}

fn applyTokenCount(turn: *TurnRecord, session: *SessionRecord, payload: std.json.ObjectMap) void {
    const info = objectField(payload, "info") orelse payload;
    if (objectField(info, "total_token_usage")) |total| {
        applyCumulativeToken(
            &turn.input_tokens,
            &session.input_tokens,
            intField(total, "input_tokens"),
        );
        applyCumulativeToken(
            &turn.cached_input_tokens,
            &session.cached_input_tokens,
            intField(total, "cached_input_tokens"),
        );
        applyCumulativeToken(
            &turn.output_tokens,
            &session.output_tokens,
            intField(total, "output_tokens"),
        );
        applyCumulativeToken(
            &turn.reasoning_output_tokens,
            &session.reasoning_output_tokens,
            intField(total, "reasoning_output_tokens"),
        );
        applyCumulativeToken(
            &turn.total_tokens,
            &session.total_tokens,
            intField(total, "total_tokens"),
        );
        return;
    }
    const last = objectField(info, "last_token_usage") orelse return;
    applyTurnToken(
        &turn.input_tokens,
        &session.input_tokens,
        intField(last, "input_tokens"),
    );
    applyTurnToken(
        &turn.cached_input_tokens,
        &session.cached_input_tokens,
        intField(last, "cached_input_tokens"),
    );
    applyTurnToken(
        &turn.output_tokens,
        &session.output_tokens,
        intField(last, "output_tokens"),
    );
    applyTurnToken(
        &turn.reasoning_output_tokens,
        &session.reasoning_output_tokens,
        intField(last, "reasoning_output_tokens"),
    );
    applyTurnToken(
        &turn.total_tokens,
        &session.total_tokens,
        intField(last, "total_tokens"),
    );
}

fn applyCumulativeToken(
    turn: *?i64,
    session: *?i64,
    next: ?i64,
) void {
    const value = next orelse return;
    const prior_session = session.* orelse 0;
    const prior_turn = turn.* orelse 0;
    const baseline = if (prior_session >= prior_turn)
        prior_session - prior_turn
    else
        0;
    turn.* = if (value >= baseline) value - baseline else value;
    session.* = value;
}

fn applyTurnToken(
    turn: *?i64,
    session: *?i64,
    next: ?i64,
) void {
    const value = next orelse return;
    const prior_session = session.* orelse 0;
    const prior_turn = turn.* orelse 0;
    const baseline = if (prior_session >= prior_turn)
        prior_session - prior_turn
    else
        0;
    turn.* = value;
    session.* = std.math.add(i64, baseline, value) catch value;
}

fn tokenEvent(
    allocator: std.mem.Allocator,
    occurrence_index: usize,
    turn_index: i64,
    session: SessionRecord,
    payload: std.json.ObjectMap,
) !TokenEventRecord {
    const info = objectField(payload, "info") orelse payload;
    const total_usage = objectField(info, "total_token_usage");
    const last_usage = objectField(info, "last_token_usage");
    const total = tokenUsage(payload);
    const model = try dupOpt(allocator, session.model);
    errdefer freeOpt(allocator, model);
    const service_tier = try dupOpt(allocator, session.service_tier);
    return .{
        .occurrence_index = occurrence_index,
        .turn_index = turn_index,
        .input_tokens = if (total) |value|
            intField(value, "input_tokens")
        else
            null,
        .cached_input_tokens = if (total) |value|
            intField(value, "cached_input_tokens")
        else
            null,
        .output_tokens = if (total) |value|
            intField(value, "output_tokens")
        else
            null,
        .reasoning_output_tokens = if (total) |value|
            intField(value, "reasoning_output_tokens")
        else
            null,
        .total_tokens = if (total) |value|
            intField(value, "total_tokens")
        else
            null,
        .total_input_tokens = tokenField(total_usage, "input_tokens"),
        .total_cached_input_tokens = tokenField(total_usage, "cached_input_tokens"),
        .total_output_tokens = tokenField(total_usage, "output_tokens"),
        .total_reasoning_output_tokens = tokenField(total_usage, "reasoning_output_tokens"),
        .total_total_tokens = tokenField(total_usage, "total_tokens"),
        .last_input_tokens = tokenField(last_usage, "input_tokens"),
        .last_cached_input_tokens = tokenField(last_usage, "cached_input_tokens"),
        .last_output_tokens = tokenField(last_usage, "output_tokens"),
        .last_reasoning_output_tokens = tokenField(last_usage, "reasoning_output_tokens"),
        .last_total_tokens = tokenField(last_usage, "total_tokens"),
        .has_total_usage = total_usage != null,
        .has_last_usage = last_usage != null,
        .model = model,
        .service_tier = service_tier,
    };
}

fn tokenField(usage: ?std.json.ObjectMap, field: []const u8) ?i64 {
    return if (usage) |value| intField(value, field) else null;
}

fn tokenUsage(payload: std.json.ObjectMap) ?std.json.ObjectMap {
    const info = objectField(payload, "info") orelse payload;
    return objectField(info, "total_token_usage") orelse
        objectField(info, "last_token_usage");
}

test "cumulative token snapshots become per-turn deltas" {
    var session_tokens: ?i64 = null;
    var first_turn_tokens: ?i64 = null;
    var second_turn_tokens: ?i64 = null;

    applyCumulativeToken(
        &first_turn_tokens,
        &session_tokens,
        100,
    );
    applyCumulativeToken(
        &first_turn_tokens,
        &session_tokens,
        120,
    );
    applyCumulativeToken(
        &second_turn_tokens,
        &session_tokens,
        175,
    );
    try std.testing.expectEqual(@as(i64, 120), first_turn_tokens.?);
    try std.testing.expectEqual(@as(i64, 55), second_turn_tokens.?);
    try std.testing.expectEqual(@as(i64, 175), session_tokens.?);
}

fn applyResponseItem(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    lookup: *ToolLookup,
    path: []const u8,
    current_turn_index: *?usize,
    synthetic_turns: *i64,
    saw_task_started: bool,
    payload: std.json.ObjectMap,
    timestamp: ?[]const u8,
    line_number: usize,
    options: TraceParseOptions,
) !void {
    const payload_type = stringField(payload, "type") orelse return;
    const is_message = std.mem.eql(u8, payload_type, "message");
    const role = stringField(payload, "role") orelse "";
    const idx = if (is_message and std.mem.eql(u8, role, "user") and !saw_task_started)
        try startSyntheticTurn(
            allocator,
            trace,
            path,
            current_turn_index,
            synthetic_turns,
            timestamp,
        )
    else
        try ensureTurn(
            allocator,
            trace,
            path,
            current_turn_index,
            synthetic_turns,
            timestamp,
            stringField(payload, "turn_id"),
        );
    if (is_message) {
        if (options.include_message_bodies) {
            try applyResponseMessage(
                allocator,
                &trace.turns.items[idx],
                payload,
                role,
                line_number,
            );
        }
        return;
    }
    const limit = options.max_tools;
    if (oneOfString(payload_type, &.{ "function_call", "custom_tool_call" })) {
        try declareTool(allocator, trace, lookup, idx, payload, timestamp, line_number, limit);
    } else if (oneOfString(payload_type, &.{ "function_call_output", "custom_tool_call_output" })) {
        try finalizeToolOutput(
            allocator,
            trace,
            lookup,
            idx,
            payload,
            payload_type,
            timestamp,
            line_number,
            options.max_tools,
        );
    }
}

fn applyResponseMessage(
    allocator: std.mem.Allocator,
    turn: *TurnRecord,
    payload: std.json.ObjectMap,
    role: []const u8,
    line_number: usize,
) !void {
    const text = try messageTextAlloc(allocator, payload);
    defer allocator.free(text);
    if (std.mem.eql(u8, role, "user")) {
        try attachUserMessage(allocator, turn, text);
    } else if (std.mem.eql(u8, role, "assistant")) {
        try attachAssistantMessage(allocator, turn, text, line_number);
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

fn stripEchoView(text: []const u8) []const u8 {
    const left = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, left, "Echo:")) return text;

    const newline_index = std.mem.indexOfScalar(u8, left, '\n') orelse
        return "";
    var rest = left[newline_index + 1 ..];
    while (rest.len > 0 and rest[0] == '\r') rest = rest[1..];

    var index: usize = 0;
    while (index < rest.len and
        (rest[index] == ' ' or
            rest[index] == '\t' or
            rest[index] == '\r')) : (index += 1)
    {}
    if (index < rest.len and rest[index] == '\n') {
        rest = rest[index + 1 ..];
    }
    return rest;
}

fn isMetaUserMessage(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "# AGENTS.md instructions")) {
        return true;
    }
    if (std.mem.startsWith(u8, trimmed, "<environment_context>")) return true;
    if (std.mem.startsWith(u8, trimmed, "<INSTRUCTIONS>")) return true;
    const end = @min(trimmed.len, 200);
    return std.mem.indexOf(
        u8,
        trimmed[0..end],
        "AGENTS.md instructions",
    ) != null;
}

fn normalizeMessageTextAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\r') {
            if (index + 1 < text.len and text[index + 1] == '\n') index += 1;
            try output.append(allocator, '\n');
        } else {
            try output.append(allocator, text[index]);
        }
    }
    return allocator.dupe(
        u8,
        std.mem.trim(u8, output.items, " \t\n"),
    );
}

fn normalizeTimestampAlloc(
    allocator: std.mem.Allocator,
    timestamp: []const u8,
) ![]u8 {
    if (timestamp.len > 0 and timestamp[timestamp.len - 1] == 'Z') {
        return allocator.print(
            "{s}+00:00",
            .{timestamp[0 .. timestamp.len - 1]},
        );
    }
    return allocator.dupe(u8, timestamp);
}

fn messageMirrorDigest(
    role: []const u8,
    text: []const u8,
    turn_key: usize,
    timestamp: ?[]const u8,
) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(role);
    hasher.update("\x1f");
    hasher.update(text);
    hasher.update("\x1f");
    var number: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &number,
        @intCast(turn_key),
        .big,
    );
    hasher.update(&number);
    hasher.update("\x1f");
    if (timestamp) |value| {
        if (value.len > 0 and value[value.len - 1] == 'Z') {
            hasher.update(value[0 .. value.len - 1]);
            hasher.update("+00:00");
        } else {
            hasher.update(value);
        }
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn messageTurnKey(
    trace: *const CanonicalSessionTrace,
    source: std.json.ObjectMap,
    entry_type: []const u8,
    role: []const u8,
    current_turn_index: ?usize,
    saw_task_started: bool,
) usize {
    if (std.mem.eql(u8, role, "user") and
        ((std.mem.eql(u8, entry_type, "response_item") and
            !saw_task_started) or
            std.mem.eql(u8, entry_type, "message")))
    {
        return trace.turns.items.len;
    }
    if (stringField(source, "turn_id")) |turn_id| {
        for (trace.turns.items, 0..) |turn, index| {
            if (std.mem.eql(u8, turn.turn_id, turn_id)) return index;
        }
    }
    return current_turn_index orelse trace.turns.items.len;
}

fn messageTextPartsAlloc(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]MessageTextPart {
    var parts = std.ArrayList(MessageTextPart).empty;
    errdefer {
        for (parts.items) |*part| part.deinit(allocator);
        parts.deinit(allocator);
    }
    if (stringField(obj, "content")) |text| {
        try appendMessageTextPart(allocator, &parts, text);
        return parts.toOwnedSlice(allocator);
    }
    const content = obj.get("content") orelse return parts.toOwnedSlice(allocator);
    const arr = valueArray(content) orelse return parts.toOwnedSlice(allocator);
    for (arr.items) |part| {
        const part_obj = valueObject(part) orelse continue;
        const part_type = stringField(part_obj, "type") orelse "";
        if (!oneOfString(part_type, &.{ "input_text", "output_text", "text" })) continue;
        if (stringField(part_obj, "text")) |text| {
            try appendMessageTextPart(allocator, &parts, text);
        }
    }
    return parts.toOwnedSlice(allocator);
}

fn appendMessageTextPart(
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(MessageTextPart),
    text: []const u8,
) !void {
    const owned = try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    try parts.append(allocator, .{ .text = owned });
}

test "message text parts retain one owner across allocation failures" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkMessagePartAllocationFailures,
        .{},
    );
}

fn checkMessagePartAllocationFailures(allocator: std.mem.Allocator) !void {
    const inputs = [_][]const u8{
        "{\"content\":\"plain\"}",
        "{\"content\":[{\"type\":\"input_text\",\"text\":\"a\"}," ++
            "{\"type\":\"output_text\",\"text\":\"b\"}]}",
    };
    for (inputs) |input| {
        const parts = try messageTextPartsFromPayloadAlloc(allocator, input);
        defer freeMessageTextParts(allocator, parts);
        try std.testing.expect(parts.len > 0);
    }
}

pub fn completeTraceDigest(
    allocator: std.mem.Allocator,
    trace: CanonicalSessionTrace,
) ![]u8 {
    return retainedTraceDigest(
        allocator,
        trace,
        @intCast(trace.turns.items.len),
    );
}

pub fn retainedTraceDigest(
    allocator: std.mem.Allocator,
    trace: CanonicalSessionTrace,
    keep_through_turn_index: i64,
) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;

    try writer.print("turns:{d}\n", .{keep_through_turn_index});
    for (trace.turns.items) |turn| {
        if (turn.turn_index > keep_through_turn_index) continue;
        try writer.print(
            "{d}|{s}|{s}|",
            .{ turn.turn_index, turn.turn_id, @tagName(turn.status) },
        );
        if (turn.user_message) |value| try writeTraceContentDigest(writer, value);
        try writer.writeByte('|');
        if (turn.final_answer) |value| try writeTraceContentDigest(writer, value);
        try writer.writeByte('\n');
        for (trace.tools.items) |tool| {
            if (tool.turn_index == null or
                tool.turn_index.? != turn.turn_index)
            {
                continue;
            }
            try writeToolTraceDigest(writer, tool);
        }
    }
    const canonical = try writer_alloc.toOwnedSlice();
    defer allocator.free(canonical);
    return sha256Prefixed(allocator, canonical);
}

fn writeToolTraceDigest(writer: anytype, tool: ToolLifecycleRecord) !void {
    try writer.writeAll("tool|");
    if (tool.call_id) |value| try writer.writeAll(value);
    try writer.writeByte('|');
    if (tool.tool_name) |value| try writer.writeAll(value);
    try writer.writeByte('|');
    try writer.writeAll(@tagName(tool.lifecycle_status));
    const content = [_]?[]const u8{
        tool.arguments_json,
        tool.input_text,
        tool.output_text,
        tool.command_text,
        tool.cwd,
        tool.patch_changes_json,
        tool.web_query,
        tool.web_url,
        tool.image_prompt,
    };
    for (content) |item| {
        try writer.writeByte('|');
        if (item) |value| try writeTraceContentDigest(writer, value);
    }
    try writer.writeByte('|');
    if (tool.exit_code) |value| try writer.print("{d}", .{value});
    try writer.writeByte('\n');
}

fn writeTraceContentDigest(writer: anytype, text: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try writer.writeAll(hex[0..]);
}

fn sha256Prefixed(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.print("sha256:{s}", .{hex});
}

test "retained trace digest changes with observed tool payload" {
    var trace = CanonicalSessionTrace{
        .session = try SessionRecord.init(
            std.testing.allocator,
            "rollout.jsonl",
        ),
    };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .status = .complete,
    });
    try trace.tools.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout.jsonl"),
        .turn_index = 1,
        .call_id = try std.testing.allocator.dupe(u8, "call-1"),
        .tool_name = try std.testing.allocator.dupe(u8, "exec_command"),
        .arguments_json = try std.testing.allocator.dupe(
            u8,
            "{\"cmd\":\"zig build test\"}",
        ),
        .lifecycle_status = .completed,
    });

    const before = try completeTraceDigest(std.testing.allocator, trace);
    defer std.testing.allocator.free(before);
    std.testing.allocator.free(trace.tools.items[0].arguments_json.?);
    trace.tools.items[0].arguments_json = try std.testing.allocator.dupe(
        u8,
        "{\"cmd\":\"zig build lint\"}",
    );
    const after = try completeTraceDigest(std.testing.allocator, trace);
    defer std.testing.allocator.free(after);
    try std.testing.expect(!std.mem.eql(u8, before, after));
}

test "message text-part projection preserves ordered source boundaries" {
    const split =
        "{\"type\":\"message\",\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"input_text\",\"text\":\"a\"},{\"type\":\"input_text\",\"text\":\"b\"}]}";
    const joined =
        "{\"type\":\"message\",\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"input_text\",\"text\":\"ab\"}]}";
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

/// Uncapped parsing appends tools only, so owned call-ID bytes remain stable.
/// Capped parsing keeps its existing bounded reverse scan across ordered removals.
const ToolLookup = struct {
    // Small scans avoid populating allocator size classes for a short-lived index.
    const scan_tools_max: usize = 64;
    enabled: bool,
    promoted: bool = false,
    by_call_id: std.StringHashMapUnmanaged(usize) = .empty,

    fn deinit(self: *ToolLookup, allocator: std.mem.Allocator) void {
        self.by_call_id.deinit(allocator);
    }

    fn find(self: *const ToolLookup, trace: *CanonicalSessionTrace, call_id: []const u8) ?usize {
        if (!self.promoted) return findToolByCallId(trace, call_id);
        const index = self.by_call_id.get(call_id) orelse return null;
        std.debug.assert(index < trace.tools.items.len);
        std.debug.assert(std.mem.eql(u8, trace.tools.items[index].call_id.?, call_id));
        return index;
    }

    fn remember(
        self: *ToolLookup,
        allocator: std.mem.Allocator,
        trace: *const CanonicalSessionTrace,
    ) !void {
        if (!self.enabled) return;
        std.debug.assert(trace.tools.items.len > 0);
        if (!self.promoted) {
            if (trace.tools.items.len <= scan_tools_max) return;
            const capacity = std.math.cast(u32, trace.tools.items.len) orelse
                return error.OutOfMemory;
            try self.by_call_id.ensureTotalCapacity(allocator, capacity);
            for (trace.tools.items, 0..) |tool, index| {
                const call_id = tool.call_id orelse continue;
                self.by_call_id.putAssumeCapacity(call_id, index);
            }
            self.promoted = true;
            return;
        }
        const index = trace.tools.items.len - 1;
        const call_id = trace.tools.items[index].call_id orelse return;
        try self.by_call_id.put(allocator, call_id, index);
        std.debug.assert(self.by_call_id.count() <= trace.tools.items.len);
    }
};

fn findToolByCallId(trace: *CanonicalSessionTrace, call_id: []const u8) ?usize {
    var idx = trace.tools.items.len;
    while (idx > 0) {
        idx -= 1;
        const existing = trace.tools.items[idx].call_id orelse continue;
        if (std.mem.eql(u8, existing, call_id)) return idx;
    }
    return null;
}

fn toolCandidateIsNoBetter(
    candidate: ToolLifecycleRecord,
    current_worst: ToolLifecycleRecord,
) bool {
    const candidate_turn = candidate.turn_index orelse return true;
    const worst_turn = current_worst.turn_index orelse return false;
    return candidate_turn <= worst_turn;
}

fn retainNewestTools(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    max_tools: ?usize,
) !void {
    const limit = max_tools orelse return;
    if (trace.tools.items.len <= limit) return;

    // Rows enter in source order. For equal turn indexes the query engine is
    // stable, so the later equal-key row is the one that cannot reach top N.
    var discard_index: usize = 0;
    for (trace.tools.items[1..], 1..) |candidate, index| {
        if (toolCandidateIsNoBetter(candidate, trace.tools.items[discard_index])) {
            discard_index = index;
        }
    }

    var discarded = trace.tools.orderedRemove(discard_index);
    defer discarded.deinit(allocator);
    if (discarded.call_id) |call_id| {
        if (!trace.omitted_tool_call_ids.contains(call_id)) {
            const owned_call_id = try allocator.dupe(u8, call_id);
            errdefer allocator.free(owned_call_id);
            try trace.omitted_tool_call_ids.put(allocator, owned_call_id, {});
        }
    }
}

fn declareTool(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    lookup: *ToolLookup,
    turn_idx: usize,
    payload: std.json.ObjectMap,
    timestamp: ?[]const u8,
    line_number: usize,
    max_tools: ?usize,
) !void {
    const call_id = stringField(payload, "call_id") orelse stringField(payload, "id") orelse return;
    if (lookup.find(trace, call_id)) |_| return;
    if (trace.omitted_tool_call_ids.contains(call_id)) return;
    const name = stringField(payload, "name") orelse
        stringField(payload, "tool_name") orelse "unknown";
    var record = try initToolRecord(allocator, trace, turn_idx, call_id);
    var record_owned = true;
    errdefer if (record_owned) record.deinit(allocator);
    record.started_at = try dupOpt(allocator, timestamp);
    record.kind = kindFromName(name);
    record.tool_name = try allocator.dupe(u8, name);
    record.namespace = try namespaceFromName(allocator, name);
    record.arguments_json = try dupOpt(allocator, stringField(payload, "arguments"));
    record.input_text = try dupOpt(allocator, stringField(payload, "input"));
    record.lifecycle_status = .declared;
    record.declared_line = @intCast(line_number);
    if (record.arguments_json) |args| try parseExecArgsIntoRecord(allocator, &record, args);
    try trace.tools.append(allocator, record);
    record_owned = false;
    try lookup.remember(allocator, trace);
    trace.turns.items[turn_idx].tool_count += 1;
    try retainNewestTools(allocator, trace, max_tools);
}

fn initToolRecord(
    allocator: std.mem.Allocator,
    trace: *const CanonicalSessionTrace,
    turn_idx: usize,
    call_id: []const u8,
) !ToolLifecycleRecord {
    var record = ToolLifecycleRecord{
        .path = try allocator.dupe(u8, trace.session.path),
        .turn_index = trace.turns.items[turn_idx].turn_index,
    };
    errdefer record.deinit(allocator);
    record.session_id = try dupOpt(allocator, trace.session.session_id);
    record.turn_id = try allocator.dupe(u8, trace.turns.items[turn_idx].turn_id);
    record.call_id = try allocator.dupe(u8, call_id);
    return record;
}

fn finalizeToolEvent(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    lookup: *ToolLookup,
    turn_idx: usize,
    payload: std.json.ObjectMap,
    event_type: []const u8,
    timestamp: ?[]const u8,
    line_number: usize,
    max_tools: ?usize,
) !void {
    try finalizeToolOutput(
        allocator,
        trace,
        lookup,
        turn_idx,
        payload,
        event_type,
        timestamp,
        line_number,
        max_tools,
    );
    if (std.mem.eql(u8, event_type, "collab_agent_spawn_end")) {
        try appendGraphEdge(allocator, trace, payload, timestamp);
        trace.turns.items[turn_idx].spawned_worker_count += 1;
        trace.session.spawned_worker_count += 1;
    }
}

fn finalizeToolOutput(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    lookup: *ToolLookup,
    turn_idx: usize,
    payload: std.json.ObjectMap,
    event_type: []const u8,
    timestamp: ?[]const u8,
    line_number: usize,
    max_tools: ?usize,
) !void {
    const call_id = stringField(payload, "call_id") orelse
        stringField(payload, "id") orelse event_type;
    const idx = lookup.find(trace, call_id) orelse blk: {
        if (trace.omitted_tool_call_ids.contains(call_id)) return;
        try inferToolRecord(allocator, trace, lookup, turn_idx, call_id, timestamp, max_tools);
        if (trace.omitted_tool_call_ids.contains(call_id)) return;
        const retained_index = lookup.find(trace, call_id) orelse return;
        break :blk retained_index;
    };
    var rec = &trace.tools.items[idx];
    rec.kind = kindFromEndEvent(event_type, rec.tool_name);
    rec.finalized_line = @intCast(line_number);
    if (timestamp) |ts| try replaceOpt(allocator, &rec.completed_at, ts);
    try applyToolOutput(allocator, rec, payload);
    rec.lifecycle_status = completedToolStatus(rec.exit_code, boolField(payload, "success"));
}

fn inferToolRecord(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    lookup: *ToolLookup,
    turn_idx: usize,
    call_id: []const u8,
    timestamp: ?[]const u8,
    max_tools: ?usize,
) !void {
    var record = try initToolRecord(allocator, trace, turn_idx, call_id);
    var record_owned = true;
    errdefer if (record_owned) record.deinit(allocator);
    record.completed_at = try dupOpt(allocator, timestamp);
    record.lifecycle_status = .inferred;
    try trace.tools.append(allocator, record);
    record_owned = false;
    try lookup.remember(allocator, trace);
    trace.turns.items[turn_idx].tool_count += 1;
    try retainNewestTools(allocator, trace, max_tools);
}

fn applyToolOutput(
    allocator: std.mem.Allocator,
    rec: *ToolLifecycleRecord,
    payload: std.json.ObjectMap,
) !void {
    const output = stringField(payload, "output") orelse
        stringField(payload, "aggregated_output") orelse stringField(payload, "stdout") orelse "";
    try replaceOpt(allocator, &rec.output_text, output);
    if (stringField(payload, "command")) |v| try replaceOpt(allocator, &rec.command_text, v);
    if (stringField(payload, "cwd")) |v| try replaceOpt(allocator, &rec.cwd, v);
    if (intField(payload, "exit_code")) |v| rec.exit_code = v;
    if (intField(payload, "duration_ms")) |v| rec.duration_ms = v;
    if (intField(payload, "duration_secs")) |v| {
        if (durationMilliseconds(v)) |ms| rec.duration_ms = ms;
    }
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
    if (objectField(payload, "action")) |action| {
        if (stringField(action, "url")) |v| try replaceOpt(allocator, &rec.web_url, v);
    }
    if (stringField(payload, "prompt")) |v| try replaceOpt(allocator, &rec.image_prompt, v);
}

fn completedToolStatus(exit_code: ?i64, success: ?bool) ToolLifecycleStatus {
    if (exit_code) |code| return if (code == 0) .completed else .failed;
    if (success) |ok| return if (ok) .completed else .failed;
    return .completed;
}

fn parseExecArgsIntoRecord(
    allocator: std.mem.Allocator,
    record: *ToolLifecycleRecord,
    args: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return;
    };
    defer parsed.deinit();
    const obj = valueObject(parsed.value) orelse return;
    if (stringField(obj, "cmd")) |v| try replaceOpt(allocator, &record.command_text, v);
    if (stringField(obj, "command")) |v| try replaceOpt(allocator, &record.command_text, v);
    if (stringField(obj, "cwd")) |v| try replaceOpt(allocator, &record.cwd, v);
}

fn appendGraphEdge(
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    payload: std.json.ObjectMap,
    timestamp: ?[]const u8,
) !void {
    var edge = SessionGraphEdge{
        .parent_path = try allocator.dupe(u8, trace.session.path),
    };
    errdefer edge.deinit(allocator);
    edge.parent_session_id = try dupOpt(allocator, trace.session.session_id);
    const worker_id = stringField(payload, "new_thread_id") orelse
        stringField(payload, "worker_session_id");
    edge.worker_session_id = try dupOpt(allocator, worker_id);
    edge.call_id = try dupOpt(allocator, stringField(payload, "call_id"));
    edge.agent_nickname = try dupOpt(allocator, stringField(payload, "agent_nickname"));
    edge.agent_role = try dupOpt(allocator, stringField(payload, "agent_role"));
    edge.model = try dupOpt(allocator, stringField(payload, "model"));
    const effort = stringField(payload, "reasoning_effort") orelse stringField(payload, "effort");
    edge.reasoning_effort = try dupOpt(allocator, effort);
    edge.spawned_at = try dupOpt(allocator, timestamp);
    if (stringField(payload, "prompt")) |v| edge.prompt_preview = try previewAlloc(allocator, v);
    edge.worker_status = try dupOpt(allocator, stringField(payload, "status"));
    try trace.graph_edges.append(allocator, edge);
}

fn kindFromName(name: []const u8) ToolKind {
    if (std.mem.eql(u8, name, "exec_command") or std.mem.eql(u8, name, "shell")) {
        return .exec_command;
    }
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

fn nowRealtimeNs(io: std.Io) i128 {
    return std.Io.Clock.real.now(io).nanoseconds;
}

fn bestTimestamp(root: std.json.ObjectMap) ?[]const u8 {
    if (stringField(root, "timestamp")) |v| return v;
    if (objectField(root, "payload")) |payload| {
        if (stringField(payload, "timestamp")) |v| return v;
    }
    return null;
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn freeOpt(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |v| allocator.free(v);
}

const pi_test_trace =
    \\{"type":"session","version":3,"id":"pi-test","timestamp":"2026-10-01T10:00:00Z","cwd":"/pi-work","parentSession":"/archive/old.jsonl"}
    \\{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-10-01T10:00:01Z","provider":"moonshot","modelId":"kimi"}
    \\{"type":"thinking_level_change","id":"h1","parentId":"m1","thinkingLevel":"high"}
    \\{"type":"message","id":"u1","parentId":"h1","timestamp":"2026-10-01T10:00:02Z","message":{"role":"user","content":"first question"}}
    \\{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-10-01T10:00:03Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"PRIVATE_THOUGHT","thinkingSignature":"PRIVATE_SIGNATURE"},{"type":"text","text":"Inspecting"},{"type":"toolCall","id":"call-1","name":"bash","arguments":{"command":"printf hi"},"thoughtSignature":"PRIVATE_PI_TOOL_SIGNATURE"}],"usage":{"input":10,"cacheRead":3,"cacheWrite":4,"output":2,"reasoning":1,"totalTokens":19},"stopReason":"toolUse"}}
    \\{"type":"message","id":"r1","parentId":"a1","timestamp":"2026-10-01T10:00:04Z","message":{"role":"toolResult","toolCallId":"call-1","toolName":"bash","content":[{"type":"text","text":"failure"}],"isError":true,"details":{"exitCode":1},"durationMs":12}}
    \\{"type":"message","id":"a2","parentId":"r1","timestamp":"2026-10-01T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"original answer"}],"usage":{"input":20,"cacheRead":0,"cacheWrite":0,"output":4,"totalTokens":24},"stopReason":"stop"}}
    \\{"type":"message","id":"u2","parentId":"a2","timestamp":"2026-10-01T10:00:06Z","message":{"role":"user","content":"second question"}}
    \\{"type":"message","id":"a3","parentId":"u2","timestamp":"2026-10-01T10:00:07Z","message":{"role":"assistant","content":[{"type":"text","text":"second answer"}],"stopReason":"length"}}
    \\{"type":"message","id":"a4","parentId":"u1","timestamp":"2026-10-01T10:00:08Z","message":{"role":"assistant","content":[{"type":"text","text":"alternative answer"}],"usage":{"input":30,"cacheRead":0,"cacheWrite":0,"output":6,"totalTokens":36},"stopReason":"stop"}}
    \\{"type":"compaction","id":"c1","parentId":"a4","summary":"condensed","firstKeptEntryId":"u1","tokensBefore":42}
    \\{"type":"custom_message","id":"x1","parentId":"c1","content":[{"type":"text","text":"extension note"}],"customType":"test","display":true}
    \\{"type":"future_entry","id":"f1","parentId":"x1","futureData":{"kept":true}}
    \\{"type":"session_info","id":"i1","parentId":"f1","timestamp":"2026-10-01T10:00:09Z","name":"Pi test"}
;

fn piTestSummary(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: TraceParseOptions,
) !CanonicalSessionTrace {
    var reader = std.Io.Reader.fixed(source);
    return parseSessionSummaryTraceReader(
        std.testing.io,
        allocator,
        "pi.jsonl",
        &reader,
        0,
        options,
    );
}

test "Pi trees retain all branches and map assistant replies and tools to their ancestors" {
    const allocator = std.testing.allocator;
    var trace = try parseSessionTraceBytes(
        std.testing.io,
        allocator,
        "pi.jsonl",
        pi_test_trace,
        0,
        .{ .include_raw = true },
    );
    defer trace.deinit(allocator);
    try std.testing.expectEqual(TraceFormat.pi_session_jsonl, trace.session.source_format);
    try std.testing.expectEqualStrings("pi-test", trace.session.session_id.?);
    try std.testing.expectEqualStrings("/pi-work", trace.session.cwd.?);
    try std.testing.expectEqualStrings("pi", trace.session.originator.?);
    try std.testing.expectEqualStrings("Pi test", trace.session.thread_name.?);
    try std.testing.expectEqualStrings("kimi", trace.session.model.?);
    try std.testing.expectEqual(@as(?i64, 79), trace.session.total_tokens);
    try std.testing.expectEqual(@as(?i64, 67), trace.session.input_tokens);
    try std.testing.expectEqual(@as(?i64, 3), trace.session.cached_input_tokens);
    try std.testing.expectEqual(@as(?i64, 12), trace.session.output_tokens);
    try std.testing.expectEqual(@as(?i64, 1), trace.session.reasoning_output_tokens);
    try std.testing.expectEqual(@as(usize, 2), trace.turns.items.len);
    try std.testing.expectEqualStrings("alternative answer", trace.turns.items[0].final_answer.?);
    try std.testing.expectEqualStrings("second answer", trace.turns.items[1].final_answer.?);
    try std.testing.expectEqualStrings("high", trace.turns.items[0].reasoning_effort.?);
    try std.testing.expectEqual(@as(?usize, 10), trace.turns.items[0].final_answer_line);
    try std.testing.expectEqual(@as(?i64, 79), trace.turns.items[0].total_tokens);
    try std.testing.expectEqual(@as(?i64, null), trace.turns.items[1].total_tokens);
    try std.testing.expect(trace.turns.items[0].has_compaction);
    try std.testing.expectEqual(@as(usize, 1), trace.tools.items.len);
    const tool = trace.tools.items[0];
    try std.testing.expectEqual(ToolKind.exec_command, tool.kind);
    try std.testing.expectEqual(ToolLifecycleStatus.failed, tool.lifecycle_status);
    try std.testing.expectEqualStrings("printf hi", tool.command_text.?);
    try std.testing.expectEqualStrings("failure", tool.output_text.?);
    try std.testing.expectEqual(@as(?i64, 1), tool.turn_index);
    try std.testing.expectEqual(@as(?i64, 5), tool.declared_line);
    try std.testing.expectEqual(@as(?i64, 6), tool.finalized_line);
    try std.testing.expectEqual(@as(?i64, 12), tool.duration_ms);
    try std.testing.expectEqual(@as(usize, 14), trace.occurrences.items.len);
    try std.testing.expectEqual(@as(?i64, 1), trace.occurrences.items[9].turn_index);
    try std.testing.expectEqualStrings("original answer", trace.occurrences.items[6].text.?);
    try std.testing.expectEqualStrings("future_entry", trace.occurrences.items[12].entry_type);
    try std.testing.expectEqual(@as(usize, 0), trace.graph_edges.items.len);
    try std.testing.expect(trace.session.parent_session_id == null);
    try std.testing.expectEqual(@as(usize, 0), trace.warnings.items.len);
}

test "Pi thinking is private while public payloads keep envelope identity and exact raw is opt in" {
    const allocator = std.testing.allocator;
    var trace = try parseSessionTraceBytes(
        std.testing.io,
        allocator,
        "pi.jsonl",
        pi_test_trace,
        0,
        .{ .include_raw = true },
    );
    defer trace.deinit(allocator);
    const occurrence = trace.occurrences.items[4];
    try std.testing.expectEqualStrings("Inspecting", occurrence.text.?);
    try std.testing.expect(occurrence.message_visible and !occurrence.private);
    try std.testing.expect(std.mem.indexOf(u8, occurrence.payload_json.?, "PRIVATE_") == null);
    try std.testing.expect(std.mem.indexOf(u8, occurrence.raw_json.?, "PRIVATE_THOUGHT") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        occurrence.raw_json.?,
        "PRIVATE_PI_TOOL_SIGNATURE",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        occurrence.payload_json.?,
        "\"parentId\":\"u1\"",
    ) != null);
    const parts = try messageTextPartsFromPayloadAlloc(allocator, occurrence.payload_json.?);
    defer freeMessageTextParts(allocator, parts);
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqualStrings("Inspecting", parts[0].text);
    var raw_event = (try parseRawTraceEvent(allocator, "pi.jsonl", 5, occurrence.raw_json.?)).?;
    defer raw_event.deinit(allocator);
    try std.testing.expectEqual(TraceFormat.pi_session_jsonl, raw_event.format);
    try std.testing.expect(std.mem.indexOf(u8, raw_event.payload_json.?, "PRIVATE_") == null);
    const private_source =
        \\{"type":"session","version":3,"id":"private"}
        \\{"type":"message","id":"a1","parentId":null,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"PRIVATE_THOUGHT"}],"stopReason":"aborted"}}
    ;
    var private_trace = try parseSessionTraceBytes(
        std.testing.io,
        allocator,
        "private.jsonl",
        private_source,
        0,
        .{},
    );
    defer private_trace.deinit(allocator);
    const private_occurrence = private_trace.occurrences.items[1];
    try std.testing.expect(private_occurrence.private and !private_occurrence.message_visible);
    try std.testing.expect(private_occurrence.payload_json == null);
    try std.testing.expect(private_occurrence.raw_json == null);
    try std.testing.expect(private_trace.turns.items[0].final_answer == null);
}

test "Pi summary and selective full parsing preserve metadata without retaining omitted bodies" {
    const allocator = std.testing.allocator;
    var full = try parseSessionTraceBytes(
        std.testing.io,
        allocator,
        "pi.jsonl",
        pi_test_trace,
        0,
        .{
            .include_occurrences = false,
            .include_message_bodies = false,
            .max_tools = 0,
        },
    );
    defer full.deinit(allocator);
    var summary = try piTestSummary(allocator, pi_test_trace, .{ .include_raw = true });
    defer summary.deinit(allocator);
    try std.testing.expectEqualDeep(full.session, summary.session);
    try std.testing.expectEqual(@as(usize, 0), summary.turns.items.len);
    try std.testing.expectEqual(@as(usize, 0), summary.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), summary.occurrences.items.len);
    try std.testing.expectEqual(@as(usize, 0), full.occurrences.items.len);
    try std.testing.expectEqual(@as(usize, 0), full.tools.items.len);
    try std.testing.expectEqual(@as(i64, 1), full.turns.items[0].tool_count);
    try std.testing.expect(full.turns.items[0].user_message == null);
    try std.testing.expect(full.turns.items[0].final_answer == null);
    try std.testing.expectEqual(@as(usize, 0), full.token_events.items.len);
    var projected = try parseSessionTraceBytes(
        std.testing.io,
        allocator,
        "pi.jsonl",
        pi_test_trace,
        0,
        .{ .include_occurrence_payloads = false, .include_raw = true },
    );
    defer projected.deinit(allocator);
    try std.testing.expect(projected.occurrences.items[4].payload_json == null);
    try std.testing.expect(projected.occurrences.items[4].raw_json != null);
    try std.testing.expectEqualStrings("Inspecting", projected.occurrences.items[4].text.?);
}

test "Pi explicitly rejects requested Codex cumulative token event tuples in both parse routes" {
    try std.testing.expectError(
        error.PiCumulativeTokenEventsUnavailable,
        parseSessionTraceBytes(
            std.testing.io,
            std.testing.allocator,
            "pi.jsonl",
            pi_test_trace,
            0,
            .{ .include_token_events = true },
        ),
    );
    try std.testing.expectError(
        error.PiCumulativeTokenEventsUnavailable,
        piTestSummary(std.testing.allocator, pi_test_trace, .{ .include_token_events = true }),
    );
}

test "Pi version two branch settings follow parent ancestry and session names can be cleared" {
    const source =
        \\{"type":"session","version":2,"id":"branch-settings"}
        \\{"type":"model_change","id":"m1","parentId":null,"modelId":"first","provider":"one"}
        \\{"type":"thinking_level_change","id":"h1","parentId":"m1","thinkingLevel":"high"}
        \\{"type":"message","id":"u1","parentId":"h1","message":{"role":"user","content":"first"}}
        \\{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[],"stopReason":"stop"}}
        \\{"type":"model_change","id":"m2","parentId":"a1","modelId":"second","provider":"two"}
        \\{"type":"thinking_level_change","id":"l1","parentId":"m2","thinkingLevel":"low"}
        \\{"type":"message","id":"u2","parentId":"l1","message":{"role":"user","content":"second"}}
        \\{"type":"message","id":"u3","parentId":"a1","message":{"role":"user","content":"old branch"}}
        \\{"type":"session_info","id":"n1","parentId":"u3","name":"Old name"}
        \\{"type":"session_info","id":"n2","parentId":"n1","name":"  "}
    ;
    const allocator = std.testing.allocator;
    var full = try parseSessionTraceBytes(std.testing.io, allocator, "pi.jsonl", source, 0, .{});
    defer full.deinit(allocator);
    var summary = try piTestSummary(allocator, source, .{});
    defer summary.deinit(allocator);
    try std.testing.expectEqualDeep(full.session, summary.session);
    try std.testing.expectEqualStrings("second", full.turns.items[1].model.?);
    try std.testing.expectEqualStrings("low", full.turns.items[1].reasoning_effort.?);
    try std.testing.expectEqualStrings("first", full.turns.items[2].model.?);
    try std.testing.expectEqualStrings("high", full.turns.items[2].reasoning_effort.?);
    try std.testing.expectEqualStrings("first", full.session.model.?);
    try std.testing.expectEqualStrings("one", full.session.model_provider.?);
    try std.testing.expect(full.session.thread_name == null);
    try std.testing.expectEqualStrings("pi_inactive_branch", full.turns.items[1].status_reason.?);
    const missing_name_source = source ++
        "\n{\"type\":\"session_info\",\"id\":\"n3\",\"parentId\":\"n2\",\"name\":\"Named\"}\n" ++
        "{\"type\":\"session_info\",\"id\":\"n4\",\"parentId\":\"n3\"}";
    var cleared = try piTestSummary(allocator, missing_name_source, .{});
    defer cleared.deinit(allocator);
    try std.testing.expect(cleared.session.thread_name == null);
}

test "Pi legacy linear sessions tolerate malformed tails and retain unknown entries" {
    const source =
        \\{"type":"session","id":"legacy","timestamp":"2025-01-01T00:00:00Z"}
        \\{"type":"message","message":{"role":"user","content":"first"}}
        \\{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"interrupted"}],"stopReason":"aborted","errorMessage":"cancelled"}}
        \\{"type":"message","message":{"role":"user","content":"second"}}
        \\{"type":"message","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"failed"}}
        \\{"type":"message","message":{"role":"hookMessage","content":"legacy custom"}}
        \\{"type":"future_entry","opaque":"kept"}
        \\{"type":"message"
    ;
    const allocator = std.testing.allocator;
    var full = try parseSessionTraceBytes(std.testing.io, allocator, "pi.jsonl", source, 0, .{});
    defer full.deinit(allocator);
    var summary = try piTestSummary(allocator, source, .{});
    defer summary.deinit(allocator);
    try std.testing.expectEqualDeep(full.session, summary.session);
    try std.testing.expectEqual(@as(usize, 2), full.turns.items.len);
    try std.testing.expectEqual(TurnStatus.aborted, full.turns.items[0].status);
    try std.testing.expectEqual(TurnStatus.@"error", full.turns.items[1].status);
    try std.testing.expectEqualStrings("cancelled", full.turns.items[0].aborted_reason.?);
    try std.testing.expectEqualStrings("failed", full.turns.items[1].@"error".?);
    try std.testing.expectEqual(@as(usize, 1), full.warnings.items.len);
    try std.testing.expectEqual(@as(usize, 7), full.occurrences.items.len);
    try std.testing.expectEqual(@as(?i64, 2), full.occurrences.items[6].turn_index);
    try std.testing.expectEqual(@as(?i64, null), full.session.total_tokens);
}

test "Pi requires a validated first header and never synthesizes absent usage counters" {
    const invalid_header =
        \\{"type":"session","id":123}
        \\{"type":"session","version":3,"id":"later"}
    ;
    const allocator = std.testing.allocator;
    var other = try parseSessionTraceBytes(
        std.testing.io,
        allocator,
        "pi.jsonl",
        invalid_header,
        0,
        .{},
    );
    defer other.deinit(allocator);
    try std.testing.expectEqual(TraceFormat.unknown, other.session.source_format);
    const source =
        \\{"type":"session","version":3,"id":"partial-usage"}
        \\{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"question"}}
        \\{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[],"usage":{"input":2,"output":3,"cacheRead":0,"cacheWrite":0},"stopReason":"stop"}}
        \\{"type":"message","id":"a2","parentId":"u1","message":{"role":"assistant","content":[],"usage":{"input":-1,"output":"bad","cacheRead":0,"cacheWrite":0,"totalTokens":5},"stopReason":"stop"}}
    ;
    var partial = try parseSessionTraceBytes(std.testing.io, allocator, "pi.jsonl", source, 0, .{});
    defer partial.deinit(allocator);
    try std.testing.expectEqual(@as(?i64, null), partial.turns.items[0].reasoning_output_tokens);
    try std.testing.expectEqual(@as(?i64, 5), partial.session.total_tokens);
    try std.testing.expectEqual(@as(?i64, 2), partial.session.input_tokens);
    try std.testing.expectEqual(@as(?i64, 3), partial.session.output_tokens);
    try std.testing.expectEqual(@as(usize, 2), partial.warnings.items.len);
    var parsed_usage = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"input\":1}",
        .{},
    );
    defer parsed_usage.deinit();
    const absent_total = PiUsage.read(valueObject(parsed_usage.value).?);
    try std.testing.expect(absent_total.total_tokens == null);
    try std.testing.expect(absent_total.input_tokens == null);
}

test "Pi usage preserves provider totals while rejecting fractional and overflowing input" {
    const cases = [_]struct { json: []const u8, valid: bool, input: ?i64, total: ?i64 }{
        .{
            .json =
            \\{"input":1,"cacheRead":2,"cacheWrite":3,"output":4,"totalTokens":99}
            ,
            .valid = true,
            .input = 6,
            .total = 99,
        },
        .{
            .json =
            \\{"input":1.5,"cacheRead":0,"cacheWrite":0,"output":4,"totalTokens":5}
            ,
            .valid = false,
            .input = null,
            .total = 5,
        },
        .{
            .json =
            \\{"input":9223372036854775807,"cacheRead":1,"cacheWrite":0,"output":0,"totalTokens":9223372036854775807}
            ,
            .valid = false,
            .input = null,
            .total = std.math.maxInt(i64),
        },
        .{
            .json =
            \\{"input":1,"cacheRead":0,"cacheWrite":0,"output":4,"reasoning":5,"totalTokens":5}
            ,
            .valid = false,
            .input = 1,
            .total = 5,
        },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            case.json,
            .{},
        );
        defer parsed.deinit();
        const usage = PiUsage.read(valueObject(parsed.value).?);
        try std.testing.expectEqual(case.valid, usage.valid);
        try std.testing.expectEqual(case.input, usage.input_tokens);
        try std.testing.expectEqual(case.total, usage.total_tokens);
    }
}

const PiVisitorProbe = struct {
    source: []const u8,
    offset: usize = 0,
    lines: usize = 0,

    fn visit(self: *PiVisitorProbe, bytes: []const u8, line_number: usize) !void {
        const next = std.mem.indexOfScalarPos(u8, self.source, self.offset, '\n');
        const end = next orelse self.source.len;
        try std.testing.expectEqualStrings(self.source[self.offset..end], bytes);
        self.lines += 1;
        try std.testing.expectEqual(self.lines, line_number);
        self.offset = if (next != null) end + 1 else end;
    }
};

test "Pi full and summary visitors preserve physical bytes and streaming metrics" {
    const source = " \r\n" ++ pi_test_trace;
    const allocator = std.testing.allocator;
    var full_reader = std.Io.Reader.fixed(source);
    var summary_reader = std.Io.Reader.fixed(source);
    var full_probe = PiVisitorProbe{ .source = source };
    var summary_probe = PiVisitorProbe{ .source = source };
    var full_metrics = StreamMetrics{};
    var summary_metrics = StreamMetrics{};
    var full = try parseSessionTraceReaderWithVisitorMetrics(
        std.testing.io,
        allocator,
        "pi.jsonl",
        &full_reader,
        0,
        .{},
        &full_probe,
        PiVisitorProbe.visit,
        &full_metrics,
    );
    defer full.deinit(allocator);
    var summary = try parseSessionSummaryTraceReaderWithVisitorMetrics(
        std.testing.io,
        allocator,
        "pi.jsonl",
        &summary_reader,
        0,
        .{},
        &summary_probe,
        PiVisitorProbe.visit,
        &summary_metrics,
    );
    defer summary.deinit(allocator);
    try std.testing.expectEqualDeep(full_metrics, summary_metrics);
    try std.testing.expectEqual(@as(usize, source.len), full_metrics.bytes_read);
    try std.testing.expectEqual(@as(usize, 15), full_metrics.lines_seen);
    try std.testing.expectEqual(@as(usize, source.len), full_probe.offset);
    try std.testing.expectEqual(@as(usize, source.len), summary_probe.offset);
    try std.testing.expectEqual(@as(usize, 2), full.occurrences.items[0].line_number);
    try std.testing.expectEqual(@as(usize, 0), full.occurrences.items[0].ordinal);
    const expected_id = computeSourceEventId("pi.jsonl", 6, 4);
    try std.testing.expectEqualStrings(&expected_id, full.occurrences.items[4].sourceEventId());
}

test "Pi full and summary ownership survives every allocation failure" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkPiTraceAllocation,
        .{},
    );
}

fn checkPiTraceAllocation(allocator: std.mem.Allocator) !void {
    var full = try parseSessionTraceBytes(
        std.testing.io,
        allocator,
        "pi.jsonl",
        pi_test_trace,
        0,
        .{ .include_raw = true },
    );
    defer full.deinit(allocator);
    var summary = try piTestSummary(allocator, pi_test_trace, .{});
    defer summary.deinit(allocator);
    try std.testing.expectEqualDeep(full.session, summary.session);
    try std.testing.expectEqual(@as(usize, 2), full.turns.items.len);
}

test "parseRawTraceEvent detects newer event_msg" {
    const line =
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-04-01T00:00:00Z\"," ++
        "\"payload\":{\"type\":\"task_started\",\"turn_id\":\"t1\"}}";
    var event = (try parseRawTraceEvent(std.testing.allocator, "rollout.jsonl", 1, line)).?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(TraceFormat.new_044_plus, event.format);
    try std.testing.expectEqualStrings("event_msg", event.entry_type);
    try std.testing.expectEqualStrings("task_started", event.event_type.?);
}

test "canonical messages normalize and suppress repeated source carriers" {
    const source =
        "{\"type\":\"session_meta\"," ++
        "\"timestamp\":\"2026-07-13T00:00:00Z\"," ++
        "\"payload\":{\"id\":\"messages\"}}\n" ++
        "{\"type\":\"response_item\"," ++
        "\"timestamp\":\"2026-07-13T00:00:01Z\"," ++
        "\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"input_text\"," ++
        "\"text\":\"# AGENTS.md instructions for /repo\"}]}}\n" ++
        "{\"type\":\"response_item\"," ++
        "\"timestamp\":\"2026-07-13T00:00:02Z\"," ++
        "\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[" ++
        "{\"type\":\"output_text\"," ++
        "\"text\":\"Echo: prior\\n\\nAnswer\\r\\n\"}]}}\n" ++
        "{\"type\":\"event_msg\"," ++
        "\"timestamp\":\"2026-07-13T00:00:02Z\"," ++
        "\"payload\":{\"type\":\"agent_message\",\"message\":\"Answer\"}}\n" ++
        "{\"type\":\"response_item\"," ++
        "\"timestamp\":\"2026-07-13T00:00:03Z\"," ++
        "\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"input_text\",\"text\":\"Hello\\r\\n\"}]}}\n" ++
        "{\"type\":\"event_msg\"," ++
        "\"timestamp\":\"2026-07-13T00:00:03Z\"," ++
        "\"payload\":{\"type\":\"user_message\",\"message\":\"Hello\"}}\n";
    var trace = try parseSessionTraceBytes(
        std.testing.io,
        std.testing.allocator,
        "/tmp/messages.jsonl",
        source,
        nowRealtimeNs(std.testing.io),
        .{},
    );
    defer trace.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), trace.occurrences.items.len);
    try std.testing.expect(!trace.occurrences.items[1].message_visible);
    try std.testing.expect(trace.occurrences.items[2].message_visible);
    try std.testing.expectEqualStrings(
        "Answer",
        trace.occurrences.items[2].text.?,
    );
    try std.testing.expectEqualStrings(
        "2026-07-13T00:00:02+00:00",
        trace.occurrences.items[2].timestamp.?,
    );
    try std.testing.expect(!trace.occurrences.items[3].message_visible);
    try std.testing.expect(trace.occurrences.items[4].message_visible);
    try std.testing.expectEqualStrings(
        "Hello",
        trace.occurrences.items[4].text.?,
    );
    try std.testing.expect(!trace.occurrences.items[5].message_visible);
}

test "canonical messages preserve identical text across turns" {
    const source =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-07-13T00:00:00Z\"," ++
        "\"payload\":{\"id\":\"repeated-messages\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-07-13T00:00:02Z\"," ++
        "\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"input_text\",\"text\":\"yes\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-13T00:00:02Z\"," ++
        "\"payload\":{\"type\":\"user_message\",\"message\":\"yes\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-07-13T00:01:02Z\"," ++
        "\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"input_text\",\"text\":\"yes\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-13T00:01:02Z\"," ++
        "\"payload\":{\"type\":\"user_message\",\"message\":\"yes\"}}\n";
    var trace = try parseSessionTraceBytes(
        std.testing.io,
        std.testing.allocator,
        "/tmp/repeated-messages.jsonl",
        source,
        nowRealtimeNs(std.testing.io),
        .{},
    );
    defer trace.deinit(std.testing.allocator);

    try std.testing.expect(trace.occurrences.items[1].message_visible);
    try std.testing.expect(!trace.occurrences.items[2].message_visible);
    try std.testing.expect(trace.occurrences.items[3].message_visible);
    try std.testing.expect(!trace.occurrences.items[4].message_visible);
}

test "parseRawTraceEvent skips state and malformed lines" {
    try std.testing.expect((try parseRawTraceEvent(std.testing.allocator, "x", 1, "")) == null);
    try std.testing.expect((try parseRawTraceEvent(
        std.testing.allocator,
        "x",
        2,
        "{\"record_type\":\"state\"}",
    )) == null);
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
    const cwd = try std.process.currentPathAlloc(
        std.testing.io,
        allocator,
    );
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, relative });
}

test "trace file entry points use the supplied directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "session.jsonl",
        .data = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"supplied-dir\"}}\n",
    });
    inline for (.{ parseSessionTrace, parseSessionSummaryTrace }) |parse| {
        var trace = try parse(std.testing.io, tmp.dir, std.testing.allocator, "session.jsonl", .{});
        defer trace.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("supplied-dir", trace.session.session_id.?);
        try std.testing.expectEqualStrings("session.jsonl", trace.session.path);
    }
}

test "trace ongoing status uses the supplied clock at the threshold" {
    const FixedClock = struct {
        fn now(_: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            std.debug.assert(clock == .real);
            return .{ .nanoseconds = 120 * std.time.ns_per_s };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.now = FixedClock.now;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    const content = "{\"type\":\"event_msg\",\"payload\":" ++
        "{\"type\":\"task_started\",\"turn_id\":\"open\"}}\n";
    inline for (.{ parseSessionTraceReader, parseSessionSummaryTraceReader }) |parse| {
        for ([_]i128{ 60, 59 }) |modified_seconds| {
            var reader: std.Io.Reader = .fixed(content);
            var trace = try parse(
                io,
                std.testing.allocator,
                "session.jsonl",
                &reader,
                modified_seconds * std.time.ns_per_s,
                .{},
            );
            defer trace.deinit(std.testing.allocator);
            try std.testing.expectEqual(modified_seconds == 60, trace.session.is_ongoing);
            try std.testing.expectEqualStrings(
                if (modified_seconds == 60) "fresh_ongoing_turn" else "stale_ongoing_file",
                trace.session.status_reason.?,
            );
        }
    }
}

test "parseSessionTrace reconstructs new complete turn" {
    const path = try testPath(
        std.testing.allocator,
        "libs/trace_core/testdata/new_044_plus.jsonl",
    );
    defer std.testing.allocator.free(path);
    var trace = try parseSessionTrace(
        std.testing.io,
        std.Io.Dir.cwd(),
        std.testing.allocator,
        path,
        .{
            .ongoing_threshold_secs = 0,
            .include_token_events = true,
        },
    );
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new-session", trace.session.session_id.?);
    try std.testing.expectEqual(@as(usize, 1), trace.turns.items.len);
    try std.testing.expectEqual(TurnStatus.complete, trace.turns.items[0].status);
    try std.testing.expectEqual(@as(i64, 15), trace.turns.items[0].total_tokens.?);
    try std.testing.expect(trace.turns.items[0].has_compaction);
    try std.testing.expectEqual(@as(usize, 1), trace.tools.items.len);
    try std.testing.expectEqual(ToolKind.exec_command, trace.tools.items[0].kind);
    try std.testing.expectEqual(@as(usize, 1), trace.token_events.items.len);
    try std.testing.expectEqual(
        @as(i64, 1),
        trace.token_events.items[0].turn_index,
    );
    try std.testing.expectEqual(
        @as(i64, 15),
        trace.token_events.items[0].total_tokens.?,
    );
    try std.testing.expectEqualStrings(
        "sha256:",
        trace.occurrences
            .items[trace.token_events.items[0].occurrence_index]
            .sourceEventId()[0..7],
    );
}

test "lossless token events retain lineage, both usage tuples, and event settings" {
    const source =
        \\{"type":"session_meta","timestamp":"2026-07-13T00:00:00Z","payload":{"id":"worker","session_id":"root","parent_thread_id":"parent","model":"gpt-before"}}
        \\{"type":"event_msg","timestamp":"2026-07-13T00:00:01Z","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-after","service_tier":"priority"}}}
        \\{"type":"event_msg","timestamp":"2026-07-13T00:00:02Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":8,"output_tokens":3,"reasoning_output_tokens":1,"total_tokens":23},"last_token_usage":{"input_tokens":7,"cached_input_tokens":4,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":9}}}}
        \\
    ;
    var trace = try parseSessionTraceBytes(
        std.testing.io,
        std.testing.allocator,
        "/provenance/worker.jsonl",
        source,
        nowRealtimeNs(std.testing.io),
        .{
            .include_token_events = true,
            .include_occurrence_payloads = false,
        },
    );
    defer trace.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("worker", trace.session.session_id.?);
    try std.testing.expectEqualStrings("root", trace.session.root_session_id.?);
    try std.testing.expectEqualStrings("parent", trace.session.parent_session_id.?);
    try std.testing.expectEqualStrings("parent_thread_id", trace.session.parent_relation.?);
    try std.testing.expect(!trace.session.lineage_conflict);
    try std.testing.expectEqual(@as(usize, 1), trace.token_events.items.len);
    const event = trace.token_events.items[0];
    const occurrence = trace.occurrences.items[event.occurrence_index];
    try std.testing.expect(occurrence.payload_json == null);
    try std.testing.expect(occurrence.timestamp != null);
    try std.testing.expect(event.has_total_usage);
    try std.testing.expect(event.has_last_usage);
    try std.testing.expectEqual(@as(i64, 20), event.total_input_tokens.?);
    try std.testing.expectEqual(@as(i64, 7), event.last_input_tokens.?);
    try std.testing.expectEqualStrings("gpt-after", event.model.?);
    try std.testing.expectEqualStrings("priority", event.service_tier.?);
}

test "bytes-backed trace parsing preserves the exact assistant occurrence line" {
    const source =
        \\{"type":"session_meta","timestamp":"2026-07-13T00:00:00Z","payload":{"id":"session-bytes"}}
        \\{"type":"event_msg","timestamp":"2026-07-13T00:00:01Z","payload":{"type":"task_started","turn_id":"turn-one"}}
        \\{"type":"response_item","timestamp":"2026-07-13T00:00:02Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first"}]}}
        \\{"type":"event_msg","timestamp":"2026-07-13T00:00:03Z","payload":{"type":"agent_message","message":"selected"}}
        \\
    ;
    var trace = try parseSessionTraceBytes(
        std.testing.io,
        std.testing.allocator,
        "/provenance/only.jsonl",
        source,
        nowRealtimeNs(std.testing.io),
        .{ .include_raw = true },
    );
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), trace.turns.items[0].final_answer_line.?);
    try std.testing.expectEqualStrings("selected", trace.turns.items[0].final_answer.?);
    try std.testing.expectEqual(@as(i64, 1), trace.occurrences.items[2].turn_index.?);
    try std.testing.expectEqualStrings(
        "sha256:",
        trace.occurrences.items[2].sourceEventId()[0..7],
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        trace.occurrences.items[2].sourceEventId(),
        trace.occurrences.items[3].sourceEventId(),
    ));
    try std.testing.expectEqualStrings(
        "{\"type\":\"response_item\"," ++
            "\"timestamp\":\"2026-07-13T00:00:02Z\"," ++
            "\"payload\":{\"type\":\"message\",\"role\":\"assistant\"," ++
            "\"content\":[{\"type\":\"output_text\",\"text\":\"first\"}]}}",
        trace.occurrences.items[2].raw_json.?,
    );
    try std.testing.expectEqual(
        TraceFormat.new_044_plus,
        trace.occurrences.items[2].format,
    );
}

test "bounded tool retention still observes the retained call completion" {
    const source =
        \\{"type":"session_meta","timestamp":"2026-07-13T00:00:00Z","payload":{"id":"bounded-tools"}}
        \\{"type":"event_msg","timestamp":"2026-07-13T00:00:01Z","payload":{"type":"task_started","turn_id":"turn-one"}}
        \\{"type":"response_item","timestamp":"2026-07-13T00:00:02Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"omitted"}]}}
        \\{"type":"response_item","timestamp":"2026-07-13T00:00:03Z","payload":{"type":"function_call","name":"exec_command","call_id":"call-one","arguments":"{}"}}
        \\{"type":"response_item","timestamp":"2026-07-13T00:00:04Z","payload":{"type":"function_call","name":"exec_command","call_id":"call-two","arguments":"{}"}}
        \\{"type":"response_item","timestamp":"2026-07-13T00:00:05Z","payload":{"type":"function_call_output","call_id":"call-one","output":"done"}}
        \\
    ;
    var trace = try parseSessionTraceBytes(
        std.testing.io,
        std.testing.allocator,
        "/provenance/bounded.jsonl",
        source,
        nowRealtimeNs(std.testing.io),
        .{
            .include_occurrences = false,
            .include_message_bodies = false,
            .max_tools = 1,
        },
    );
    defer trace.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), trace.occurrences.items.len);
    try std.testing.expect(trace.turns.items[0].user_message == null);
    try std.testing.expectEqual(@as(usize, 1), trace.tools.items.len);
    try std.testing.expectEqualStrings("call-one", trace.tools.items[0].call_id.?);
    try std.testing.expectEqualStrings("done", trace.tools.items[0].output_text.?);
    try std.testing.expectEqual(
        ToolLifecycleStatus.completed,
        trace.tools.items[0].lifecycle_status,
    );
}

test "bounded tool retention preserves newest-turn query semantics" {
    const source =
        \\{"type":"session_meta","timestamp":"2026-07-13T00:00:00Z","payload":{"id":"bounded-newest-tools"}}
        \\{"type":"event_msg","timestamp":"2026-07-13T00:00:01Z","payload":{"type":"task_started","turn_id":"turn-one"}}
        \\{"type":"response_item","timestamp":"2026-07-13T00:00:02Z","payload":{"type":"function_call","name":"exec_command","call_id":"call-one","arguments":"{}"}}
        \\{"type":"event_msg","timestamp":"2026-07-13T00:00:03Z","payload":{"type":"task_complete","turn_id":"turn-one"}}
        \\{"type":"event_msg","timestamp":"2026-07-13T00:00:04Z","payload":{"type":"task_started","turn_id":"turn-two"}}
        \\{"type":"response_item","timestamp":"2026-07-13T00:00:05Z","payload":{"type":"function_call","name":"exec_command","call_id":"call-two","arguments":"{}"}}
        \\{"type":"response_item","timestamp":"2026-07-13T00:00:06Z","payload":{"type":"function_call_output","call_id":"call-two","output":"newest"}}
        \\{"type":"response_item","timestamp":"2026-07-13T00:00:07Z","payload":{"type":"function_call_output","call_id":"call-one","output":"late-old-output"}}
        \\
    ;
    var trace = try parseSessionTraceBytes(
        std.testing.io,
        std.testing.allocator,
        "/provenance/bounded-newest.jsonl",
        source,
        nowRealtimeNs(std.testing.io),
        .{
            .include_occurrences = false,
            .include_message_bodies = false,
            .max_tools = 1,
        },
    );
    defer trace.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), trace.tools.items.len);
    try std.testing.expectEqualStrings("call-two", trace.tools.items[0].call_id.?);
    try std.testing.expectEqualStrings("newest", trace.tools.items[0].output_text.?);
    try std.testing.expectEqualStrings("turn-two", trace.tools.items[0].turn_id.?);
    var tool_count: i64 = 0;
    for (trace.turns.items) |turn| tool_count += turn.tool_count;
    try std.testing.expectEqual(@as(i64, 2), tool_count);
}

test "canonical trace retains state and unknown carriers for exact consumers" {
    const source =
        "{\"record_type\":\"state\",\"payload\":{\"opaque\":true}}\n" ++
        "{\"type\":\"future_carrier\",\"payload\":{\"opaque\":true}}\n";
    var trace = try parseSessionTraceBytes(
        std.testing.io,
        std.testing.allocator,
        "/provenance/only.jsonl",
        source,
        nowRealtimeNs(std.testing.io),
        .{},
    );
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), trace.occurrences.items.len);
    try std.testing.expectEqualStrings("state", trace.occurrences.items[0].entry_type);
    try std.testing.expectEqualStrings("future_carrier", trace.occurrences.items[1].entry_type);
}

test "parseSessionSummaryTrace preserves session inventory fields" {
    const path = try testPath(
        std.testing.allocator,
        "libs/trace_core/testdata/new_044_plus.jsonl",
    );
    defer std.testing.allocator.free(path);
    var full = try parseSessionTrace(
        std.testing.io,
        std.Io.Dir.cwd(),
        std.testing.allocator,
        path,
        .{ .ongoing_threshold_secs = 0 },
    );
    defer full.deinit(std.testing.allocator);
    var summary = try parseSessionSummaryTrace(
        std.testing.io,
        std.Io.Dir.cwd(),
        std.testing.allocator,
        path,
        .{
            .ongoing_threshold_secs = 0,
        },
    );
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(full.session.session_id.?, summary.session.session_id.?);
    try std.testing.expectEqualStrings(full.session.start_time.?, summary.session.start_time.?);
    try std.testing.expectEqualStrings(full.session.end_time.?, summary.session.end_time.?);
    try std.testing.expectEqualStrings(full.session.cwd.?, summary.session.cwd.?);
    try std.testing.expectEqual(full.session.turn_count, summary.session.turn_count);
    try std.testing.expectEqual(full.session.total_tokens.?, summary.session.total_tokens.?);
    try std.testing.expectEqual(full.session.is_ongoing, summary.session.is_ongoing);
    try std.testing.expectEqualStrings(
        full.session.status_reason.?,
        summary.session.status_reason.?,
    );
}

test "first file-owner session metadata remains authoritative" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\{"type":"session_meta","timestamp":"2026-07-13T00:00:00Z","payload":{"id":"worker","cwd":"/worker","cli_version":"2","model":"worker-model","git":{"branch":"feature","commit_hash":"worker-commit"}}}
        \\{"type":"session_meta","timestamp":"2026-07-13T00:00:01Z","payload":{"id":"parent","cwd":"/parent","cli_version":"1","model":"parent-model","git":{"branch":"main","commit_hash":"parent-commit"}}}
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rollout-worker.jsonl", .data = source });
    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout-worker.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);

    var full = try parseSessionTrace(
        std.testing.io,
        std.Io.Dir.cwd(),
        std.testing.allocator,
        path,
        .{},
    );
    defer full.deinit(std.testing.allocator);
    var summary = try parseSessionSummaryTrace(
        std.testing.io,
        std.Io.Dir.cwd(),
        std.testing.allocator,
        path,
        .{},
    );
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
    const path = try testPath(
        std.testing.allocator,
        "libs/trace_core/testdata/old_2025_08_root_meta.jsonl",
    );
    defer std.testing.allocator.free(path);
    var trace = try parseSessionTrace(
        std.testing.io,
        std.Io.Dir.cwd(),
        std.testing.allocator,
        path,
        .{
            .ongoing_threshold_secs = 0,
        },
    );
    defer trace.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("old-session", trace.session.session_id.?);
    try std.testing.expectEqual(@as(usize, 2), trace.turns.items.len);
    try std.testing.expectEqualStrings("turn-1", trace.turns.items[0].turn_id);
    try std.testing.expectEqualStrings("turn-2", trace.turns.items[1].turn_id);
}

test "parseSessionTrace reports lifecycle and graph edges" {
    const path = try testPath(
        std.testing.allocator,
        "libs/trace_core/testdata/tools.jsonl",
    );
    defer std.testing.allocator.free(path);
    var trace = try parseSessionTrace(
        std.testing.io,
        std.Io.Dir.cwd(),
        std.testing.allocator,
        path,
        .{
            .ongoing_threshold_secs = 0,
        },
    );
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

const allocation_trace =
    \\{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"session","cwd":"/tmp","git":{"commit_hash":"abc"}}}
    \\{"timestamp":"2026-01-01T00:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}
    \\{"type":"event_msg","payload":{"type":"user_message","message":"first message"}}
    \\{"type":"response_item","payload":{"type":"function_call","call_id":"call","name":"exec_command","arguments":"{\"cmd\":\"echo hi\",\"cwd\":\"/tmp\"}"}}
    \\{"type":"event_msg","payload":{"type":"exec_command_end","call_id":"call","output":"hi","exit_code":0,"duration_ms":1}}
    \\{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}}}}
    \\{"type":"event_msg","payload":{"type":"collab_agent_spawn_end","call_id":"worker","new_thread_id":"child","prompt":"work","status":"running"}}
    \\{"timestamp":"2026-01-01T00:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}
    \\{bad
;

test "full trace propagates allocation failure and cleans every partial result" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkFullTraceAllocation,
        .{},
    );
}

fn checkFullTraceAllocation(allocator: std.mem.Allocator) !void {
    var trace = try parseSessionTraceBytes(
        std.testing.io,
        allocator,
        "trace.jsonl",
        allocation_trace,
        0,
        .{
            .include_raw = true,
            .include_token_events = true,
        },
    );
    defer trace.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), trace.turns.items.len);
    try std.testing.expectEqual(@as(usize, 2), trace.tools.items.len);
    try std.testing.expectEqual(@as(usize, 1), trace.warnings.items.len);
    try std.testing.expectEqualStrings("first message", trace.turns.items[0].user_message.?);
    try std.testing.expectEqualStrings("hi", trace.tools.items[0].output_text.?);
}

test "summary trace propagates allocation failure and cleans every partial result" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkSummaryAllocation,
        .{},
    );
}

fn checkSummaryAllocation(allocator: std.mem.Allocator) !void {
    var reader = std.Io.Reader.fixed(allocation_trace);
    var trace = try parseSessionSummaryTraceReader(
        std.testing.io,
        allocator,
        "trace.jsonl",
        &reader,
        0,
        .{},
    );
    defer trace.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1), trace.session.turn_count);
    try std.testing.expectEqual(@as(i64, 1), trace.session.spawned_worker_count);
}

test "raw event propagates allocation failure and cleans every acquired field" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkRawEventAllocation,
        .{},
    );
}

fn checkRawEventAllocation(allocator: std.mem.Allocator) !void {
    const line =
        \\{"timestamp":"2026-01-01T00:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}
    ;
    var event = (try parseRawTraceEvent(allocator, "trace.jsonl", 1, line)).?;
    defer event.deinit(allocator);
    try std.testing.expectEqualStrings("user_message", event.event_type.?);
}

test "parse scratch retains at most one MiB after small large small records" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var scratch = ParseScratch.init(counted.allocator());
    defer scratch.deinit();
    const first = (try scratch.parse("{\"value\":\"first\"}")).?;
    const owned = try std.testing.allocator.dupe(u8, stringField(first, "value").?);
    defer std.testing.allocator.free(owned);
    scratch.reset();
    try std.testing.expect(
        counted.allocated_bytes - counted.freed_bytes <= scratch_retention_limit,
    );

    var line = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer line.deinit();
    try line.writer.writeAll("{\"value\":\"");
    for (0..scratch_retention_limit + 1) |_| try line.writer.writeAll("\\u0061");
    try line.writer.writeAll("\"}");
    const large = (try scratch.parse(line.written())).?;
    try std.testing.expectEqual(scratch_retention_limit + 1, stringField(large, "value").?.len);
    try std.testing.expect(scratch.arena.queryCapacity() > scratch_retention_limit);
    scratch.reset();
    try std.testing.expect(
        counted.allocated_bytes - counted.freed_bytes <= scratch_retention_limit,
    );
    const last = (try scratch.parse("{\"value\":\"last\"}")).?;
    try std.testing.expectEqualStrings("last", stringField(last, "value").?);
    try std.testing.expectEqualStrings("first", owned);
}

test "scratch drops oversized storage if optional shrinking allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var scratch = ParseScratch.init(failing.allocator());
    defer scratch.deinit();
    const temporary = try scratch.arena.allocator().alloc(u8, scratch_retention_limit * 2);
    @memset(temporary, 0);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    scratch.reset();
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), scratch.arena.queryCapacity());
    failing.fail_index = std.math.maxInt(usize);
    const parsed = (try scratch.parse("{\"value\":\"after failed shrink\"}")).?;
    try std.testing.expectEqualStrings("after failed shrink", stringField(parsed, "value").?);
}

test "tool lookup preserves duplicate declarations and latest completion" {
    const input =
        \\{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn"}}
        \\{"type":"response_item","payload":{"type":"function_call","call_id":"call","name":"exec_command","arguments":"{}"}}
        \\{"type":"response_item","payload":{"type":"function_call_output","call_id":"call","output":"first"}}
        \\{"type":"response_item","payload":{"type":"function_call","call_id":"call","name":"replacement","arguments":"{}"}}
        \\{"type":"response_item","payload":{"type":"function_call_output","call_id":"call","output":"last"}}
    ;
    for ([_]?usize{ null, 1 }) |limit| {
        var trace = try parseSessionTraceBytes(
            std.testing.io,
            std.testing.allocator,
            "trace.jsonl",
            input,
            0,
            .{
                .max_tools = limit,
            },
        );
        defer trace.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), trace.tools.items.len);
        try std.testing.expectEqual(@as(i64, 1), trace.turns.items[0].tool_count);
        try std.testing.expectEqualStrings("exec_command", trace.tools.items[0].tool_name.?);
        try std.testing.expectEqualStrings("last", trace.tools.items[0].output_text.?);
        try std.testing.expectEqual(@as(?i64, 2), trace.tools.items[0].declared_line);
        try std.testing.expectEqual(@as(?i64, 5), trace.tools.items[0].finalized_line);
    }
}

test "tool lookup borrows stable row keys across growth and keeps latest matching row" {
    const allocator = std.testing.allocator;
    var trace = CanonicalSessionTrace{
        .session = try SessionRecord.init(allocator, "trace.jsonl"),
    };
    defer trace.deinit(allocator);
    var lookup = ToolLookup{ .enabled = true };
    defer lookup.deinit(allocator);
    var turn: ?usize = null;
    const turn_index = try startTurn(allocator, &trace, "trace.jsonl", &turn, "turn", null);
    for (0..96) |index| {
        var tool = try initToolRecord(allocator, &trace, turn_index, "same-call");
        var transferred = false;
        errdefer if (!transferred) tool.deinit(allocator);
        try trace.tools.append(allocator, tool);
        transferred = true;
        try lookup.remember(allocator, &trace);
        try std.testing.expectEqual(index, lookup.find(&trace, "same-call").?);
        try std.testing.expectEqual(index >= ToolLookup.scan_tools_max, lookup.promoted);
    }
    try std.testing.expectEqual(@as(?usize, null), lookup.find(&trace, "missing"));
}

test "tool lookup promotes without losing earlier rows or exposing partial state on OOM" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        exerciseToolLookupPromotion,
        .{},
    );
}

fn exerciseToolLookupPromotion(allocator: std.mem.Allocator) !void {
    var trace = CanonicalSessionTrace{
        .session = try SessionRecord.init(allocator, "trace.jsonl"),
    };
    defer trace.deinit(allocator);
    var lookup = ToolLookup{ .enabled = true };
    defer lookup.deinit(allocator);
    var current: ?usize = null;
    const turn = try startTurn(allocator, &trace, "trace.jsonl", &current, "turn", null);
    for (0..ToolLookup.scan_tools_max + 1) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "call-{d}", .{index});
        var tool = try initToolRecord(allocator, &trace, turn, name);
        trace.tools.append(allocator, tool) catch |err| {
            tool.deinit(allocator);
            return err;
        };
        lookup.remember(allocator, &trace) catch |err| {
            try std.testing.expect(!lookup.promoted);
            try std.testing.expectEqual(@as(?usize, 0), lookup.find(&trace, "call-0"));
            return err;
        };
        if (index < ToolLookup.scan_tools_max) {
            try std.testing.expectEqual(@as(u32, 0), lookup.by_call_id.capacity());
        }
    }
    try std.testing.expect(lookup.promoted);
    try std.testing.expectEqual(@as(?usize, 0), lookup.find(&trace, "call-0"));
    try std.testing.expectEqual(@as(?usize, 64), lookup.find(&trace, "call-64"));
    try std.testing.expectEqual(@as(?usize, null), lookup.find(&trace, "missing"));
}
