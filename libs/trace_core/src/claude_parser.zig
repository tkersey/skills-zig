const std = @import("std");
const core = @import("root.zig");
const usage = @import("claude_usage.zig");

const CanonicalSessionTrace = core.CanonicalSessionTrace;
const TraceOccurrence = core.TraceOccurrence;
const TraceParseOptions = core.TraceParseOptions;
pub const Quantity = usage.Quantity;
pub const QuantityState = usage.QuantityState;

pub const prefix_lines_max: usize = 256;
pub const prefix_bytes_max: usize = 4 * 1024 * 1024;
pub const sidecar_bytes_max: usize = 64 * 1024;
pub const request_record_version_min = Version{ .major = 2, .minor = 1, .patch = 319 };
pub const adapter_id = "claude-code-transcript-jsonl/v1";

pub const Signature = enum { neutral, codex, pi, claude };

const conversation_types = [_][]const u8{ "user", "assistant", "system", "attachment" };

const session_metadata_types = [_][]const u8{
    "api-request",     "api-request-blob", "api-request-shape", "session-owner",
    "atis-latch",      "last-prompt",      "mode",              "permission-mode",
    "queue-operation", "agent-name",       "tools-used",        "pr-link",
    "cost-state",      "worktree-state",   "relocated",
};

const codex_types = [_][]const u8{
    "session_meta", "turn_context", "compacted", "event_msg", "response_item",
};

const re_query_prefixes = [_][]const u8{
    "Output token limit hit",
    "Your response was cut off because it exceeded the output token limit",
    "[structured-output-enforce]",
};

const visible_origins = [_][]const u8{ "human", "sdk", "peer" };

pub fn signature(root: std.json.ObjectMap, line_number: usize) Signature {
    if (line_number == 1 and isPiHeader(root)) return .pi;
    if (isClaudeSignature(root)) return .claude;
    if (isCodexSignature(root)) return .codex;
    return .neutral;
}

fn isPiHeader(root: std.json.ObjectMap) bool {
    return eql(stringField(root, "type"), "session") and stringField(root, "id") != null;
}

pub fn isClaudeSignature(root: std.json.ObjectMap) bool {
    const entry_type = stringField(root, "type") orelse return false;
    if (oneOf(entry_type, &conversation_types)) {
        return stringField(root, "uuid") != null and stringField(root, "sessionId") != null;
    }
    if (std.mem.eql(u8, entry_type, "summary")) return stringField(root, "leafUuid") != null;
    if (oneOf(entry_type, &.{ "file-history-snapshot", "file-history-delta" })) {
        return stringField(root, "messageId") != null;
    }
    const field: []const u8 = if (std.mem.eql(u8, entry_type, "custom-title"))
        "customTitle"
    else if (std.mem.eql(u8, entry_type, "ai-title"))
        "aiTitle"
    else if (std.mem.eql(u8, entry_type, "continued-in"))
        "continuedInSessionId"
    else if (oneOf(entry_type, &session_metadata_types))
        "sessionId"
    else
        return false;
    if (stringField(root, field) == null) return false;
    if (std.mem.eql(u8, entry_type, "api-request") and root.get("id") == null) return false;
    return std.mem.eql(u8, field, "sessionId") or stringField(root, "sessionId") != null;
}

fn isCodexSignature(root: std.json.ObjectMap) bool {
    if (root.get("type")) |value| {
        const entry_type = switch (value) {
            .string => |text| text,
            else => return false,
        };
        return oneOf(entry_type, &codex_types) and objectField(root, "payload") != null;
    }
    if (root.get("payload")) |payload| return payload == .object;
    if (root.get("id") != null and root.get("timestamp") != null) return true;
    if (root.get("call_id") != null) {
        return (root.get("arguments") != null and root.get("name") != null) or
            root.get("output") != null;
    }
    if (root.get("role") != null and root.get("content") != null) return true;
    return root.get("encrypted_content") != null;
}

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(text: []const u8) ?Version {
        var parts = std.mem.splitScalar(u8, text, '.');
        const major = parseNumber(parts.next() orelse return null) orelse return null;
        const minor = parseNumber(parts.next() orelse return null) orelse return null;
        const patch = parseNumber(parts.next() orelse return null) orelse return null;
        if (parts.next() != null) return null;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    fn parseNumber(text: []const u8) ?u32 {
        if (text.len == 0) return null;
        for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
        return std.fmt.parseUnsigned(u32, text, 10) catch null;
    }

    pub fn atLeast(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch >= other.patch;
    }
};

pub fn recordsRequests(version: ?[]const u8) bool {
    const text = version orelse return false;
    const parsed = Version.parse(text) orelse return false;
    return parsed.atLeast(request_record_version_min);
}

pub const Kind = enum {
    user,
    assistant,
    system,
    attachment,
    api_request,
    custom_title,
    ai_title,
    continued_in,
    summary,
    other,

    fn fromType(entry_type: ?[]const u8) Kind {
        const text = entry_type orelse return .other;
        if (std.mem.eql(u8, text, "api-request")) return .api_request;
        if (std.mem.eql(u8, text, "custom-title")) return .custom_title;
        if (std.mem.eql(u8, text, "ai-title")) return .ai_title;
        if (std.mem.eql(u8, text, "continued-in")) return .continued_in;
        return std.meta.stringToEnum(Kind, text) orelse .other;
    }

    pub fn isConversation(self: Kind) bool {
        return switch (self) {
            .user, .assistant, .system, .attachment => true,
            else => false,
        };
    }

    fn modeledPayload(self: Kind) bool {
        return switch (self) {
            .user, .assistant, .system, .attachment => true,
            .summary, .custom_title, .ai_title, .continued_in => true,
            .api_request, .other => false,
        };
    }
};

pub const Text = union(enum) {
    absent,
    malformed,
    value: []const u8,

    fn read(root: std.json.ObjectMap, key: []const u8) Text {
        const raw = root.get(key) orelse return .absent;
        return switch (raw) {
            .string => |text| if (text.len == 0) .malformed else .{ .value = text },
            else => .malformed,
        };
    }

    pub fn present(self: Text) ?[]const u8 {
        return switch (self) {
            .value => |text| text,
            else => null,
        };
    }
};

pub const StopReason = union(enum) {
    absent,
    null_value,
    malformed,
    value: []const u8,

    fn read(message: std.json.ObjectMap) StopReason {
        const raw = message.get("stop_reason") orelse return .absent;
        return switch (raw) {
            .null => .null_value,
            .string => |text| if (text.len == 0) .malformed else .{ .value = text },
            else => .malformed,
        };
    }

    pub fn recorded(self: StopReason) ?[]const u8 {
        return switch (self) {
            .value => |text| text,
            else => null,
        };
    }
};

pub const BlockKind = enum { text, tool_use, other };

pub const Block = struct {
    kind: BlockKind,
    text: []const u8 = "",
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input_json: ?[]const u8 = null,
    command: ?[]const u8 = null,
    agent_role: ?[]const u8 = null,
    agent_nickname: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const OutputPart = struct {
    pointer: []const u8,
    text: []const u8,
};

pub const ResultBlock = struct {
    call_id: []const u8,
    is_error: bool,
    text: []const u8,
    first_text: ?[]const u8,
    parts: []const OutputPart,
    ends_turn: bool,
    spawned_agent: ?[]const u8 = null,
    worker_status: ?[]const u8 = null,
    resolved_model: ?[]const u8 = null,
};

pub const Record = struct {
    line: usize,
    end_offset: usize,
    occurrence: ?usize = null,
    kind: Kind,
    timestamp: ?[]const u8 = null,
    uuid: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    logical_parent: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    version: ?[]const u8 = null,
    sidechain: bool = false,
    meta: bool = false,
    subtype: ?[]const u8 = null,
    text: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    tool_result: bool = false,
    compact_summary: bool = false,
    interruption: bool = false,
    synthetic: bool = false,
    api_error: bool = false,
    model: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    message_id: Text = .absent,
    request_ref: Text = .absent,
    stop: StopReason = .absent,
    block_index: ?i64 = null,
    blocks: []const Block = &.{},
    quantity: Quantity = .{},
    duration_ms: ?i64 = null,
    preserved: ?[]const []const u8 = null,
    call_ref: ?[]const u8 = null,
    results: []const ResultBlock = &.{},
    request_id: Text = .absent,
    title: ?[]const u8 = null,

    pub fn isModelResponse(self: Record) bool {
        return self.kind == .assistant and !self.synthetic;
    }

    pub fn isReply(self: Record) bool {
        return self.isModelResponse() or self.api_error or self.interruption;
    }

    pub fn isInput(self: Record) bool {
        if (self.kind != .user) return false;
        if (self.tool_result or self.compact_summary or self.interruption) return false;
        return !self.meta or self.origin != null;
    }

    pub fn isReQueryPrompt(self: Record) bool {
        if (self.kind != .user or !self.meta or self.origin != null) return false;
        const text = self.text orelse return false;
        for (re_query_prefixes) |prefix| {
            if (std.mem.startsWith(u8, text, prefix)) return true;
        }
        return false;
    }

    pub fn isRetryNotice(self: Record) bool {
        return self.kind == .system and eql(self.subtype, "api_error");
    }

    pub fn isTurnDuration(self: Record) bool {
        return self.kind == .system and eql(self.subtype, "turn_duration");
    }

    pub fn isCompactBoundary(self: Record) bool {
        return self.kind == .system and eql(self.subtype, "compact_boundary");
    }

    pub fn hasText(self: Record) bool {
        for (self.blocks) |block| if (block.kind == .text) return true;
        return false;
    }

    pub fn visibleOrigin(self: Record) bool {
        const origin = self.origin orelse return true;
        return oneOf(origin, &visible_origins);
    }
};

pub const Extractor = struct {
    arena: std.mem.Allocator,

    pub fn record(
        self: Extractor,
        root: std.json.ObjectMap,
        line_number: usize,
        end_offset: usize,
    ) !Record {
        const entry_type = stringField(root, "type");
        var result = Record{
            .line = line_number,
            .end_offset = end_offset,
            .kind = Kind.fromType(entry_type),
        };
        result.timestamp = try self.dup(stringField(root, "timestamp"));
        result.session_id = try self.dup(stringField(root, "sessionId"));
        result.agent_id = try self.dup(stringField(root, "agentId"));
        if (result.kind.isConversation()) try self.conversation(&result, root);
        switch (result.kind) {
            .user => try self.user(&result, root),
            .assistant => try self.assistant(&result, root),
            .system => try self.system(&result, root),
            .attachment => try self.attachment(&result, root),
            .api_request => result.request_id = try self.dupText(Text.read(root, "id")),
            .custom_title => result.title = try self.dup(stringField(root, "customTitle")),
            .ai_title => result.title = try self.dup(stringField(root, "aiTitle")),
            .summary => result.text = try self.dup(stringField(root, "summary")),
            else => {},
        }
        return result;
    }

    fn conversation(self: Extractor, result: *Record, root: std.json.ObjectMap) !void {
        result.uuid = try self.dup(stringField(root, "uuid"));
        result.parent = try self.dup(stringField(root, "parentUuid"));
        result.logical_parent = try self.dup(stringField(root, "logicalParentUuid"));
        result.cwd = try self.dup(stringField(root, "cwd"));
        result.git_branch = try self.dup(stringField(root, "gitBranch"));
        result.version = try self.dup(stringField(root, "version"));
        result.sidechain = boolField(root, "isSidechain") orelse false;
        result.meta = boolField(root, "isMeta") orelse false;
        result.subtype = try self.dup(stringField(root, "subtype"));
    }

    fn user(self: Extractor, result: *Record, root: std.json.ObjectMap) !void {
        result.origin = try self.dup(stringField(root, "turnOrigin"));
        result.compact_summary = boolField(root, "isCompactSummary") orelse false;
        const message = objectField(root, "message") orelse return;
        result.text = try self.messageText(message);
        if (result.text) |text| {
            result.interruption = std.mem.startsWith(u8, text, "[Request interrupted");
        }
        const content = valueArray(message.get("content") orelse return) orelse return;
        var results: std.ArrayList(ResultBlock) = .empty;
        for (content.items, 0..) |item, index| {
            const block = valueObject(item) orelse continue;
            if (!eql(stringField(block, "type"), "tool_result")) continue;
            result.tool_result = true;
            const call_id = stringField(block, "tool_use_id") orelse continue;
            try results.append(self.arena, try self.resultBlock(root, block, call_id, index));
        }
        if (results.items.len == 1) try self.spawnResult(&results.items[0], root);
        result.results = results.items;
    }

    fn resultBlock(
        self: Extractor,
        root: std.json.ObjectMap,
        block: std.json.ObjectMap,
        call_id: []const u8,
        index: usize,
    ) !ResultBlock {
        const is_error = boolField(block, "is_error") orelse false;
        const mcp_end = if (objectField(root, "mcpMeta")) |mcp|
            if (objectField(mcp, "_meta")) |meta| boolField(meta, "claude/endTurn") orelse false else false
        else
            false;
        const flagged = boolField(root, "toolEndsTurn") orelse false;
        var parts: std.ArrayList(OutputPart) = .empty;
        var text: std.ArrayList(u8) = .empty;
        var first_text: ?[]const u8 = null;
        if (block.get("content")) |content| switch (content) {
            .string => |value| {
                try text.appendSlice(self.arena, value);
                first_text = value;
                try parts.append(self.arena, try self.pointer(index, null, value));
            },
            .array => |items| for (items.items, 0..) |item, part_index| {
                const part = valueObject(item) orelse continue;
                if (!eql(stringField(part, "type"), "text")) continue;
                const value = stringField(part, "text") orelse continue;
                if (first_text == null) first_text = value else try text.append(self.arena, '\n');
                try text.appendSlice(self.arena, value);
                try parts.append(self.arena, try self.pointer(index, part_index, value));
            },
            else => {},
        };
        return .{
            .call_id = try self.arena.dupe(u8, call_id),
            .is_error = is_error,
            .text = text.items,
            .first_text = try self.dup(first_text),
            .parts = parts.items,
            .ends_turn = !is_error and (flagged or mcp_end),
        };
    }

    fn pointer(self: Extractor, index: usize, part: ?usize, text: []const u8) !OutputPart {
        const path = if (part) |value|
            try std.fmt.allocPrint(self.arena, "/message/content/{d}/content/{d}/text", .{
                index, value,
            })
        else
            try std.fmt.allocPrint(self.arena, "/message/content/{d}/content", .{index});
        return .{ .pointer = path, .text = try self.arena.dupe(u8, text) };
    }

    fn spawnResult(self: Extractor, result: *ResultBlock, root: std.json.ObjectMap) !void {
        const detail = objectField(root, "toolUseResult") orelse return;
        result.spawned_agent = try self.dup(stringField(detail, "agentId"));
        result.worker_status = try self.dup(stringField(detail, "status"));
        result.resolved_model = try self.dup(stringField(detail, "resolvedModel"));
    }

    fn assistant(self: Extractor, result: *Record, root: std.json.ObjectMap) !void {
        result.effort = try self.dup(stringField(root, "effort"));
        result.request_ref = try self.dupText(Text.read(root, "requestRef"));
        result.block_index = if (root.get("apiBlockIndex")) |value| switch (value) {
            .integer => |index| index,
            else => null,
        } else null;
        const message = objectField(root, "message") orelse return;
        const model = stringField(message, "model");
        result.synthetic = eql(model, "<synthetic>");
        result.api_error = result.synthetic and (boolField(root, "isApiErrorMessage") orelse false);
        result.model = try self.dup(model);
        result.message_id = try self.dupText(Text.read(message, "id"));
        result.stop = StopReason.read(message);
        if (result.stop == .value) result.stop = .{ .value = try self.arena.dupe(u8, result.stop.value) };
        if (objectField(message, "usage")) |raw_usage| {
            result.service_tier = try self.dup(stringField(raw_usage, "service_tier"));
        }
        result.quantity = usage.read(message);
        result.text = try self.messageText(message);
        result.blocks = try self.blocks(message);
    }

    fn blocks(self: Extractor, message: std.json.ObjectMap) ![]const Block {
        const content = valueArray(message.get("content") orelse return &.{}) orelse return &.{};
        var result: std.ArrayList(Block) = .empty;
        for (content.items) |item| {
            const block = valueObject(item) orelse {
                try result.append(self.arena, .{ .kind = .other });
                continue;
            };
            const block_type = stringField(block, "type") orelse "";
            if (std.mem.eql(u8, block_type, "text")) {
                const text = stringField(block, "text") orelse "";
                try result.append(self.arena, .{ .kind = .text, .text = try self.arena.dupe(u8, text) });
            } else if (std.mem.eql(u8, block_type, "tool_use")) {
                try result.append(self.arena, try self.toolUse(block));
            } else {
                try result.append(self.arena, .{ .kind = .other });
            }
        }
        return result.items;
    }

    fn toolUse(self: Extractor, block: std.json.ObjectMap) !Block {
        var result = Block{
            .kind = .tool_use,
            .call_id = try self.dup(stringField(block, "id")),
            .name = try self.dup(stringField(block, "name")),
        };
        const input = block.get("input") orelse return result;
        result.input_json = try std.json.Stringify.valueAlloc(self.arena, input, .{});
        const object = valueObject(input) orelse return result;
        result.command = try self.dup(stringField(object, "command"));
        result.agent_role = try self.dup(stringField(object, "subagent_type"));
        result.agent_nickname = try self.dup(stringField(object, "description"));
        result.model = try self.dup(stringField(object, "model"));
        return result;
    }

    fn system(self: Extractor, result: *Record, root: std.json.ObjectMap) !void {
        result.duration_ms = integerField(root, "durationMs");
        const metadata = objectField(root, "compactMetadata") orelse return;
        const preserved = objectField(metadata, "preservedMessages") orelse return;
        const uuids = valueArray(preserved.get("uuids") orelse return) orelse return;
        var list: std.ArrayList([]const u8) = .empty;
        for (uuids.items) |item| switch (item) {
            .string => |text| try list.append(self.arena, try self.arena.dupe(u8, text)),
            else => {},
        };
        result.preserved = list.items;
    }

    fn attachment(self: Extractor, result: *Record, root: std.json.ObjectMap) !void {
        const detail = objectField(root, "attachment") orelse return;
        result.subtype = try self.dup(stringField(detail, "type"));
        if (eql(result.subtype, "structured_output")) {
            result.call_ref = try self.dup(stringField(detail, "toolUseID"));
        }
    }

    fn messageText(self: Extractor, message: std.json.ObjectMap) !?[]const u8 {
        const content = message.get("content") orelse return null;
        switch (content) {
            .string => |text| return try self.arena.dupe(u8, text),
            .array => |items| {
                var text: std.ArrayList(u8) = .empty;
                var found = false;
                for (items.items) |item| {
                    const block = valueObject(item) orelse continue;
                    if (!eql(stringField(block, "type"), "text")) continue;
                    const value = stringField(block, "text") orelse continue;
                    try text.appendSlice(self.arena, value);
                    found = true;
                }
                return if (found) text.items else null;
            },
            else => return null,
        }
    }

    fn dup(self: Extractor, value: ?[]const u8) !?[]const u8 {
        return if (value) |text| try self.arena.dupe(u8, text) else null;
    }

    fn dupText(self: Extractor, value: Text) !Text {
        return switch (value) {
            .value => |text| .{ .value = try self.arena.dupe(u8, text) },
            else => value,
        };
    }
};

pub fn payloadJsonAlloc(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) !?[]u8 {
    const kind = Kind.fromType(stringField(root, "type"));
    if (!kind.modeledPayload()) return null;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var projected: std.json.ObjectMap = .empty;
    const fields: []const []const u8 = switch (kind) {
        .summary => &.{ "type", "summary", "leafUuid" },
        .custom_title => &.{ "type", "customTitle", "sessionId" },
        .ai_title => &.{ "type", "aiTitle", "sessionId" },
        .continued_in => &.{ "type", "continuedInSessionId", "sessionId", "timestamp" },
        else => &conversation_payload_fields,
    };
    for (fields) |field| {
        if (root.get(field)) |value| try projected.put(arena, field, value);
    }
    if (kind.isConversation()) try projectConversation(arena, root, &projected);
    return try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = projected }, .{});
}

const conversation_payload_fields = [_][]const u8{
    "type",                    "uuid",        "parentUuid",       "logicalParentUuid",
    "sessionId",               "timestamp",   "cwd",              "gitBranch",
    "version",                 "isSidechain", "isMeta",           "agentId",
    "subtype",                 "turnOrigin",  "isCompactSummary", "isApiErrorMessage",
    "requestId",               "requestRef",  "apiBlockIndex",    "effort",
    "toolEndsTurn",            "durationMs",  "retryAttempt",     "maxRetries",
    "sourceToolAssistantUUID",
};

fn projectConversation(
    arena: std.mem.Allocator,
    root: std.json.ObjectMap,
    projected: *std.json.ObjectMap,
) !void {
    if (objectField(root, "attachment")) |detail| {
        var attachment: std.json.ObjectMap = .empty;
        if (detail.get("type")) |value| try attachment.put(arena, "type", value);
        if (detail.get("toolUseID")) |value| try attachment.put(arena, "toolUseID", value);
        try projected.put(arena, "attachment", .{ .object = attachment });
    }
    const message = objectField(root, "message") orelse return;
    var public_message: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "role", "model", "id", "stop_reason", "usage" }) |field| {
        if (message.get(field)) |value| try public_message.put(arena, field, value);
    }
    if (message.get("content")) |content| switch (content) {
        .array => |items| {
            var public_items = std.json.Array.init(arena);
            for (items.items) |item| {
                if (valueObject(item)) |block| {
                    const block_type = stringField(block, "type") orelse "";
                    if (oneOf(block_type, &.{ "thinking", "redacted_thinking" })) continue;
                }
                try public_items.append(item);
            }
            try public_message.put(arena, "content", .{ .array = public_items });
        },
        else => try public_message.put(arena, "content", content),
    };
    try projected.put(arena, "message", .{ .object = public_message });
}

pub fn eql(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |text| std.mem.eql(u8, text, expected) else false;
}

pub fn oneOf(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

pub fn stringField(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (root.get(key) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

pub fn objectField(root: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return valueObject(root.get(key) orelse return null);
}

pub fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

pub fn valueArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

pub fn boolField(root: std.json.ObjectMap, key: []const u8) ?bool {
    return switch (root.get(key) orelse return null) {
        .bool => |flag| flag,
        else => null,
    };
}

pub fn integerField(root: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (root.get(key) orelse return null) {
        .integer => |value| value,
        else => null,
    };
}

const turns_mod = @import("claude_turns.zig");
const tokens_mod = @import("claude_tokens.zig");

pub const Sidecar = struct {
    present: bool,
    digest: [71]u8,
    mtime_ns: i128,
};

pub const Limitations = struct {
    inline_sidechain_records: usize = 0,
    unlocated_spawn_count: usize = 0,
    worker_parent_unread: bool = false,
    worker_parent_missing: bool = false,
};

const PathIdentity = struct {
    stem: []const u8,
    agent: ?[]const u8 = null,
    current_layout: bool = false,
    layout_root: ?[]const u8 = null,

    fn read(path: []const u8) PathIdentity {
        const name = std.fs.path.basename(path);
        const stem = if (std.mem.endsWith(u8, name, ".jsonl.zst"))
            name[0 .. name.len - ".jsonl.zst".len]
        else if (std.mem.endsWith(u8, name, ".jsonl"))
            name[0 .. name.len - ".jsonl".len]
        else
            name;
        var identity = PathIdentity{ .stem = stem };
        if (!std.mem.startsWith(u8, stem, "agent-") or stem.len == "agent-".len) return identity;
        identity.agent = stem["agent-".len..];
        const directory = std.fs.path.dirname(path) orelse return identity;
        if (!std.mem.eql(u8, std.fs.path.basename(directory), "subagents")) return identity;
        const session_directory = std.fs.path.dirname(directory) orelse return identity;
        identity.current_layout = true;
        identity.layout_root = std.fs.path.basename(session_directory);
        return identity;
    }
};

pub fn isUuid(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) {
            return false;
        }
    }
    return true;
}

const Prefix = struct {
    done: bool = false,
    first_session_id: ?[]const u8 = null,
    seed: ?usize = null,
    earliest: ?[]const u8 = null,
    earliest_ms: ?i64 = null,

    fn observe(self: *Prefix, record: Record, index: usize) void {
        if (self.done) return;
        if (record.line > prefix_lines_max or record.end_offset > prefix_bytes_max) {
            self.done = true;
            return;
        }
        if (self.first_session_id == null) self.first_session_id = record.session_id;
        if (record.timestamp) |timestamp| self.noteTimestamp(timestamp);
        const seed = record.kind.isConversation() and record.session_id != null and
            record.cwd != null and record.timestamp != null;
        if (seed) {
            self.seed = index;
            self.done = true;
        }
    }

    fn noteTimestamp(self: *Prefix, timestamp: []const u8) void {
        const millis = timestampMillis(timestamp);
        if (self.earliest == null) {
            self.earliest = timestamp;
            self.earliest_ms = millis;
            return;
        }
        const candidate = millis orelse return;
        if (self.earliest_ms == null or candidate < self.earliest_ms.?) {
            self.earliest = timestamp;
            self.earliest_ms = candidate;
        }
    }
};

pub const ClaudeParser = struct {
    allocator: std.mem.Allocator,
    trace: *CanonicalSessionTrace,
    options: TraceParseOptions,
    summary: bool,
    arena_state: std.heap.ArenaAllocator,
    records: std.ArrayList(Record) = .empty,
    prefix: Prefix = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        trace: *CanonicalSessionTrace,
        options: TraceParseOptions,
        summary: bool,
    ) ClaudeParser {
        return .{
            .allocator = allocator,
            .trace = trace,
            .options = options,
            .summary = summary,
            .arena_state = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *ClaudeParser) void {
        self.arena_state.deinit();
    }

    fn arena(self: *ClaudeParser) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn apply(
        self: *ClaudeParser,
        root: std.json.ObjectMap,
        line_number: usize,
        end_offset: usize,
        line: []const u8,
    ) !void {
        const extractor = Extractor{ .arena = self.arena() };
        var record = try extractor.record(root, line_number, end_offset);
        if (!self.summary and self.options.include_occurrences) {
            record.occurrence = try self.appendOccurrence(root, record, line);
        }
        self.prefix.observe(record, self.records.items.len);
        try self.records.append(self.arena(), record);
    }

    fn appendOccurrence(
        self: *ClaudeParser,
        root: std.json.ObjectMap,
        record: Record,
        line: []const u8,
    ) !usize {
        const entry_type = stringField(root, "type") orelse "unknown";
        const message = objectField(root, "message");
        const role = if (message) |value| stringField(value, "role") else null;
        const modeled = record.kind.modeledPayload();
        var occurrence = try TraceOccurrence.init(
            self.allocator,
            self.trace.session.path,
            line_number_of(record),
            self.trace.occurrences.items.len,
            null,
            entry_type,
            record.subtype orelse role,
            role,
            if (modeled) record.text orelse record.title else null,
            !modeled,
        );
        errdefer occurrence.deinit(self.allocator);
        occurrence.format = .claude_code_jsonl;
        occurrence.message_visible = false;
        occurrence.timestamp = try dupOpt(self.allocator, record.timestamp);
        if (self.options.include_occurrence_payloads and modeled) {
            occurrence.payload_json = try payloadJsonAlloc(self.allocator, root);
        }
        if (self.options.include_raw) occurrence.raw_json = try self.allocator.dupe(u8, line);
        try self.trace.occurrences.append(self.allocator, occurrence);
        return self.trace.occurrences.items.len - 1;
    }

    fn line_number_of(record: Record) usize {
        return record.line;
    }

    pub fn finish(self: *ClaudeParser, io: std.Io, source_mtime_ns: i128) !void {
        const records = self.records.items;
        var session = &self.trace.session;
        session.source_format = .claude_code_jsonl;
        try replaceOpt(self.allocator, &session.originator, "claude-code");
        const identity = try self.resolveIdentity(io);
        const graph = try turns_mod.build(self.arena(), records, identity.worker);
        self.trace.claude_limitations.inline_sidechain_records = graph.inline_sidechain_records;
        for (graph.missing_uuid_lines) |line| try self.warn(line, "Claude conversation record without uuid");
        for (graph.duplicate_uuid_lines) |line| try self.warn(line, "duplicate Claude record uuid");
        const accounting = try tokens_mod.account(self.arena(), records, identity.conflict);
        for (accounting.rows) |row| {
            if (row.kind == .invalid_id) {
                try self.warn(records[row.record].line, "Claude response without a message id");
            }
        }
        const as_of_ns = self.options.as_of_ns orelse std.Io.Clock.real.now(io).nanoseconds;
        const age_secs = @divTrunc(as_of_ns - source_mtime_ns, std.time.ns_per_s);
        const freshness = turns_mod.Freshness{
            .fresh = age_secs <= self.options.ongoing_threshold_secs,
            .request_in_flight = accounting.request_in_flight,
        };
        const index = try turns_mod.indexTurns(self.arena(), &graph);
        const outcomes = try self.arena().alloc(turns_mod.Outcome, graph.turns.len);
        for (outcomes, 0..) |*outcome, turn| {
            outcome.* = try turns_mod.evaluate(self.arena(), records, &graph, &index, @intCast(turn), freshness);
        }
        try self.applySessionFields(&graph, outcomes, accounting);
        if (!self.summary) {
            try self.emitTurns(&graph, outcomes, accounting);
            try self.emitTools(&graph, accounting, identity);
            try self.updateOccurrences(&graph);
            if (self.options.include_token_events) try self.emitTokenEvents(&graph, accounting);
        } else {
            try self.countSpawnEdges(&graph, accounting);
        }
    }

    const Identity = struct {
        worker: bool = false,
        conflict: bool = false,
        agent: ?[]const u8 = null,
        root: ?[]const u8 = null,
        sidecar_call: ?[]const u8 = null,
    };

    fn resolveIdentity(self: *ClaudeParser, io: std.Io) !Identity {
        const path_identity = PathIdentity.read(self.trace.session.path);
        const session = &self.trace.session;
        var identity = Identity{ .worker = path_identity.agent != null, .agent = path_identity.agent };
        try self.applyPrefixFields();
        const agent = path_identity.agent orelse {
            const id = if (isUuid(path_identity.stem)) path_identity.stem else self.prefix.first_session_id;
            try replaceNullable(self.allocator, &session.session_id, id);
            try replaceNullable(self.allocator, &session.root_session_id, id);
            identity.root = id;
            return identity;
        };
        identity.root = if (path_identity.current_layout)
            path_identity.layout_root
        else
            self.prefix.first_session_id;
        session.is_external_worker = true;
        if (identity.root) |root| {
            const id = try std.fmt.allocPrint(self.allocator, "{s}/agent-{s}", .{ root, agent });
            freeOpt(self.allocator, session.session_id);
            session.session_id = id;
            try replaceOpt(self.allocator, &session.root_session_id, root);
        }
        try self.checkWorkerRecords(&identity);
        if (path_identity.current_layout) {
            try self.applySidecar(io, &identity);
        } else {
            try replaceNullable(self.allocator, &session.control_parent_session_id, identity.root);
            if (identity.root) |root| {
                try self.requireParent(io, std.fs.path.dirname(session.path) orelse ".", root);
            }
        }
        return identity;
    }

    fn applyPrefixFields(self: *ClaudeParser) !void {
        const session = &self.trace.session;
        try replaceNullable(self.allocator, &session.start_time, self.prefix.earliest);
        const seed = self.records.items[self.prefix.seed orelse return];
        try replaceNullable(self.allocator, &session.cwd, seed.cwd);
        try replaceNullable(self.allocator, &session.git_branch, seed.git_branch);
        try replaceNullable(self.allocator, &session.cli_version, seed.version);
    }

    fn checkWorkerRecords(self: *ClaudeParser, identity: *Identity) !void {
        for (self.records.items) |record| {
            if (!record.kind.isConversation()) continue;
            const root_mismatch = if (record.session_id) |value|
                identity.root == null or !std.mem.eql(u8, value, identity.root.?)
            else
                false;
            const agent_mismatch = if (record.agent_id) |value|
                !std.mem.eql(u8, value, identity.agent.?)
            else
                false;
            if (!root_mismatch and !agent_mismatch) continue;
            identity.conflict = true;
            self.trace.session.lineage_conflict = true;
            try self.warn(record.line, "Claude worker record contradicts its discovery identity");
        }
    }

    fn applySidecar(self: *ClaudeParser, io: std.Io, identity: *Identity) !void {
        const session = &self.trace.session;
        const read = try self.readSidecar(io, identity.agent.?);
        const fields = read orelse {
            session.lineage_conflict = true;
            self.trace.claude_limitations.worker_parent_unread = true;
            return;
        };
        identity.sidecar_call = fields.tool_use;
        const root = identity.root orelse return;
        const directory = std.fs.path.dirname(session.path) orelse ".";
        if (fields.parent_agent) |parent| {
            const id = try std.fmt.allocPrint(self.allocator, "{s}/agent-{s}", .{ root, parent });
            freeOpt(self.allocator, session.control_parent_session_id);
            session.control_parent_session_id = id;
            const stem = try std.fmt.allocPrint(self.arena(), "agent-{s}", .{parent});
            try self.requireParent(io, directory, stem);
        } else {
            try replaceOpt(self.allocator, &session.control_parent_session_id, root);
            const session_directory = std.fs.path.dirname(directory) orelse ".";
            try self.requireParent(io, std.fs.path.dirname(session_directory) orelse ".", root);
        }
    }

    fn requireParent(self: *ClaudeParser, io: std.Io, directory: []const u8, stem: []const u8) !void {
        for ([_][]const u8{ ".jsonl", ".jsonl.zst" }) |extension| {
            const name = try std.mem.concat(self.arena(), u8, &.{ stem, extension });
            const path = try std.fs.path.join(self.arena(), &.{ directory, name });
            const handle = self.options.sidecar_dir orelse std.Io.Dir.cwd();
            const stat = (if (std.fs.path.isAbsolute(path))
                std.Io.Dir.cwd().statFile(io, path, .{})
            else
                handle.statFile(io, path, .{})) catch continue;
            if (stat.kind == .file) return;
        }
        self.trace.session.lineage_conflict = true;
        self.trace.claude_limitations.worker_parent_missing = true;
    }

    const SidecarFields = struct {
        parent_agent: ?[]const u8 = null,
        tool_use: ?[]const u8 = null,
    };

    fn readSidecar(self: *ClaudeParser, io: std.Io, agent: []const u8) !?SidecarFields {
        const directory = std.fs.path.dirname(self.trace.session.path) orelse ".";
        const name = try std.fmt.allocPrint(self.arena(), "agent-{s}.meta.json", .{agent});
        const sidecar_path = try std.fs.path.join(self.arena(), &.{ directory, name });
        const directory_handle = self.options.sidecar_dir orelse std.Io.Dir.cwd();
        const opened = if (std.fs.path.isAbsolute(sidecar_path))
            std.Io.Dir.openFileAbsolute(io, sidecar_path, .{})
        else
            directory_handle.openFile(io, sidecar_path, .{});
        const file = opened catch {
            self.trace.claude_sidecar = .{ .present = false, .digest = digestOf(""), .mtime_ns = 0 };
            return null;
        };
        defer file.close(io);
        const stat = try file.stat(io);
        const mtime_ns = stat.mtime.nanoseconds;
        if (stat.size > sidecar_bytes_max) {
            self.trace.claude_sidecar = .{ .present = true, .digest = digestOf(""), .mtime_ns = mtime_ns };
            return null;
        }
        var reader = file.reader(io, &.{});
        const limit: std.Io.Limit = .limited(sidecar_bytes_max);
        const bytes = reader.interface.allocRemaining(self.arena(), limit) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                self.trace.claude_sidecar = .{ .present = true, .digest = digestOf(""), .mtime_ns = mtime_ns };
                return null;
            },
        };
        self.trace.claude_sidecar = .{ .present = true, .digest = digestOf(bytes), .mtime_ns = mtime_ns };
        return parseSidecar(self.arena(), bytes);
    }

    fn parseSidecar(arena_allocator: std.mem.Allocator, bytes: []const u8) !?SidecarFields {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena_allocator, bytes, .{}) catch |err|
            switch (err) {
                error.OutOfMemory => return err,
                else => return null,
            };
        const object = valueObject(value) orelse return null;
        var fields = SidecarFields{};
        if (object.get("parentAgentId")) |raw| {
            fields.parent_agent = switch (raw) {
                .string => |text| text,
                else => return null,
            };
        }
        if (object.get("toolUseId")) |raw| {
            fields.tool_use = switch (raw) {
                .string => |text| text,
                else => return null,
            };
        }
        return fields;
    }

    fn applySessionFields(
        self: *ClaudeParser,
        graph: *const turns_mod.Graph,
        outcomes: []const turns_mod.Outcome,
        accounting: tokens_mod.Accounting,
    ) !void {
        const session = &self.trace.session;
        var latest_ms: ?i64 = null;
        var custom_title: ?[]const u8 = null;
        var ai_title: ?[]const u8 = null;
        for (self.records.items) |record| {
            if (record.timestamp) |timestamp| {
                const millis = timestampMillis(timestamp);
                if (session.end_time == null or (millis != null and (latest_ms == null or millis.? >= latest_ms.?))) {
                    try replaceOpt(self.allocator, &session.end_time, timestamp);
                    if (millis) |value| latest_ms = value;
                }
            }
            if (record.kind == .custom_title and record.title != null) custom_title = record.title;
            if (record.kind == .ai_title and record.title != null) ai_title = record.title;
            if (record.isModelResponse()) {
                if (record.model) |model| try replaceOpt(self.allocator, &session.model, model);
                try replaceNullable(self.allocator, &session.service_tier, record.service_tier);
            }
        }
        try replaceNullable(self.allocator, &session.thread_name, custom_title orelse ai_title);
        session.turn_count = @intCast(graph.turns.len);
        var summer = tokens_mod.Summer{};
        var observations: i64 = 0;
        for (accounting.rows) |row| {
            summer.add(row);
            if (row.kind == .answered and row.has_last_usage) observations += 1;
        }
        applyTotals(session, summer.totals());
        session.token_usage_observation_count = observations;
        const active = graph.active_turn orelse if (graph.turns.len > 0) graph.turns.len - 1 else null;
        const reason = if (active) |turn| outcomes[turn].reason else "no_turns";
        try replaceOpt(self.allocator, &session.status_reason, reason);
        session.is_ongoing = if (graph.active_turn) |turn| outcomes[turn].status == .ongoing else false;
    }

    fn applyTotals(target: anytype, totals: tokens_mod.Totals) void {
        target.input_tokens = totals.input;
        target.cached_input_tokens = totals.cached;
        target.output_tokens = totals.output;
        target.reasoning_output_tokens = totals.reasoning;
        target.total_tokens = totals.total;
    }

    fn emitTurns(
        self: *ClaudeParser,
        graph: *const turns_mod.Graph,
        outcomes: []const turns_mod.Outcome,
        accounting: tokens_mod.Accounting,
    ) !void {
        const records = self.records.items;
        const summers = try self.arena().alloc(tokens_mod.Summer, graph.turns.len);
        for (summers) |*summer| summer.* = .{};
        for (accounting.rows) |row| {
            if (row.kind == .unanswered) continue;
            const turn = graph.owner[row.record] orelse continue;
            summers[turn].add(row);
        }
        try self.trace.turns.ensureUnusedCapacity(self.allocator, graph.turns.len);
        for (graph.turns, 0..) |plan, turn| {
            const anchor = records[plan.anchor];
            const outcome = outcomes[turn];
            var record = core.TurnRecord{
                .path = try self.allocator.dupe(u8, self.trace.session.path),
                .turn_id = &.{},
                .turn_index = @intCast(turn + 1),
                .status = outcome.status,
            };
            errdefer record.deinit(self.allocator);
            record.turn_id = if (anchor.uuid) |uuid|
                try self.allocator.dupe(u8, uuid)
            else
                try std.fmt.allocPrint(self.allocator, "claude-line-{d}", .{anchor.line});
            try self.fillTurn(&record, plan, anchor, outcome);
            applyTotals(&record, summers[turn].totals());
            self.trace.turns.appendAssumeCapacity(record);
        }
    }

    fn fillTurn(
        self: *ClaudeParser,
        record: *core.TurnRecord,
        plan: turns_mod.TurnPlan,
        anchor: Record,
        outcome: turns_mod.Outcome,
    ) !void {
        const allocator = self.allocator;
        record.session_id = try dupOpt(allocator, self.trace.session.session_id);
        record.started_at = try dupOpt(allocator, anchor.timestamp);
        record.cwd = try dupOpt(allocator, anchor.cwd);
        record.thread_name = try dupOpt(allocator, self.trace.session.thread_name);
        if (!plan.fallback) {
            record.origin = try dupOpt(allocator, anchor.origin);
            if (anchor.visibleOrigin() and self.options.include_message_bodies) {
                if (anchor.text) |text| {
                    record.user_message = try allocator.dupe(u8, text);
                    record.user_preview = try core.previewAlloc(allocator, text);
                }
            }
        }
        record.status_reason = try allocator.dupe(u8, outcome.reason);
        record.completed_at = try dupOpt(allocator, outcome.completed_at);
        record.duration_ms = outcome.duration_ms;
        record.@"error" = try dupOpt(allocator, outcome.error_text);
        record.aborted_reason = try dupOpt(allocator, outcome.aborted_reason);
        record.model = try dupOpt(allocator, outcome.model);
        record.reasoning_effort = try dupOpt(allocator, outcome.effort);
        record.has_compaction = outcome.has_compaction;
        if (self.options.include_message_bodies) {
            if (outcome.final_answer) |answer| {
                record.final_answer = try allocator.dupe(u8, answer);
                record.assistant_preview = try core.previewAlloc(allocator, answer);
            }
        }
    }

    const Spawn = struct {
        declaration: u32,
        block: Block,
        result: ?ResultBlock = null,
    };

    fn collectSpawns(self: *ClaudeParser, graph: *const turns_mod.Graph) ![]Spawn {
        var spawns: std.ArrayList(Spawn) = .empty;
        var by_call: std.StringHashMapUnmanaged(usize) = .empty;
        for (self.records.items, 0..) |record, index| {
            if (!graph.modeled[index]) continue;
            if (record.isModelResponse()) {
                for (record.blocks) |block| {
                    if (block.kind != .tool_use) continue;
                    const call_id = block.call_id orelse continue;
                    if (!oneOf(block.name orelse "", &.{ "Agent", "Task" })) continue;
                    const entry = try by_call.getOrPut(self.arena(), call_id);
                    if (entry.found_existing) continue;
                    entry.value_ptr.* = spawns.items.len;
                    try spawns.append(self.arena(), .{ .declaration = @intCast(index), .block = block });
                }
            }
            for (record.results) |result| {
                const position = by_call.get(result.call_id) orelse continue;
                if (spawns.items[position].result == null) spawns.items[position].result = result;
            }
        }
        return spawns.items;
    }

    fn spawnedChild(spawn: Spawn) ?[]const u8 {
        const result = spawn.result orelse return null;
        if (result.is_error) return null;
        return result.spawned_agent;
    }

    fn countSpawnEdges(
        self: *ClaudeParser,
        graph: *const turns_mod.Graph,
        accounting: tokens_mod.Accounting,
    ) !void {
        for (try self.collectSpawns(graph)) |spawn| {
            if (spawnedChild(spawn) == null) continue;
            if (accounting.here_records[spawn.declaration]) {
                self.trace.session.spawned_worker_count += 1;
            } else {
                self.trace.claude_limitations.unlocated_spawn_count += 1;
            }
        }
    }

    fn emitEdges(
        self: *ClaudeParser,
        graph: *const turns_mod.Graph,
        accounting: tokens_mod.Accounting,
        identity: Identity,
    ) !void {
        const session = &self.trace.session;
        if (identity.sidecar_call) |call_id| {
            try self.appendEdge(.{
                .parent_session_id = session.control_parent_session_id,
                .worker_session_id = session.session_id,
                .worker_path = session.path,
                .call_id = call_id,
            });
        }
        for (try self.collectSpawns(graph)) |spawn| {
            const agent = spawnedChild(spawn) orelse continue;
            if (!accounting.here_records[spawn.declaration]) {
                self.trace.claude_limitations.unlocated_spawn_count += 1;
                continue;
            }
            const root = session.root_session_id orelse continue;
            const worker = try std.fmt.allocPrint(self.arena(), "{s}/agent-{s}", .{ root, agent });
            const result = spawn.result.?;
            try self.appendEdge(.{
                .parent_session_id = session.session_id,
                .worker_session_id = worker,
                .parent_path = session.path,
                .call_id = spawn.block.call_id,
                .agent_role = spawn.block.agent_role,
                .agent_nickname = spawn.block.agent_nickname,
                .model = result.resolved_model orelse spawn.block.model,
                .spawned_at = self.records.items[spawn.declaration].timestamp,
                .worker_status = result.worker_status,
            });
            session.spawned_worker_count += 1;
            if (graph.owner[spawn.declaration]) |turn| {
                self.trace.turns.items[turn].spawned_worker_count += 1;
            }
        }
    }

    const EdgeFields = struct {
        parent_session_id: ?[]const u8 = null,
        worker_session_id: ?[]const u8 = null,
        parent_path: ?[]const u8 = null,
        worker_path: ?[]const u8 = null,
        call_id: ?[]const u8 = null,
        agent_role: ?[]const u8 = null,
        agent_nickname: ?[]const u8 = null,
        model: ?[]const u8 = null,
        spawned_at: ?[]const u8 = null,
        worker_status: ?[]const u8 = null,
    };

    fn appendEdge(self: *ClaudeParser, fields: EdgeFields) !void {
        var edge = core.SessionGraphEdge{};
        errdefer edge.deinit(self.allocator);
        inline for (@typeInfo(EdgeFields).@"struct".field_names) |name| {
            @field(edge, name) = try dupOpt(self.allocator, @field(fields, name));
        }
        try self.trace.graph_edges.append(self.allocator, edge);
    }

    fn emitTools(
        self: *ClaudeParser,
        graph: *const turns_mod.Graph,
        accounting: tokens_mod.Accounting,
        identity: Identity,
    ) !void {
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        var finalized: std.StringHashMapUnmanaged(void) = .empty;
        for (self.records.items, 0..) |record, index| {
            if (!graph.modeled[index]) continue;
            const turn = graph.owner[index];
            if (record.isModelResponse()) {
                for (record.blocks) |block| {
                    if (block.kind != .tool_use) continue;
                    const call_id = block.call_id orelse continue;
                    const entry = try declared.getOrPut(self.arena(), call_id);
                    if (entry.found_existing) continue;
                    try self.declareTool(record, block, call_id, turn);
                }
            }
            for (record.results) |result| {
                const entry = try finalized.getOrPut(self.arena(), result.call_id);
                if (entry.found_existing) continue;
                try self.finalizeTool(record, result, turn);
            }
        }
        for (self.trace.tools.items) |*tool| {
            if (tool.lifecycle_status == .declared) tool.lifecycle_status = .unresolved;
            try core.finishToolOutputParts(self.allocator, tool);
        }
        try self.emitEdges(graph, accounting, identity);
    }

    fn newTool(self: *ClaudeParser, call_id: []const u8, turn: ?u32) !core.ToolLifecycleRecord {
        var tool = core.ToolLifecycleRecord{ .path = try self.allocator.dupe(u8, self.trace.session.path) };
        errdefer tool.deinit(self.allocator);
        tool.session_id = try dupOpt(self.allocator, self.trace.session.session_id);
        tool.call_id = try self.allocator.dupe(u8, call_id);
        if (turn) |position| {
            const owner = self.trace.turns.items[position];
            tool.turn_index = owner.turn_index;
            tool.turn_id = try self.allocator.dupe(u8, owner.turn_id);
        }
        return tool;
    }

    fn declareTool(
        self: *ClaudeParser,
        record: Record,
        block: Block,
        call_id: []const u8,
        turn: ?u32,
    ) !void {
        var tool = try self.newTool(call_id, turn);
        var owned = true;
        errdefer if (owned) tool.deinit(self.allocator);
        const name = block.name orelse "unknown";
        tool.tool_name = try self.allocator.dupe(u8, name);
        tool.kind = toolKind(name);
        tool.namespace = try core.namespaceFromName(self.allocator, name);
        tool.arguments_json = try dupOpt(self.allocator, block.input_json);
        if (std.mem.eql(u8, name, "Bash")) tool.command_text = try dupOpt(self.allocator, block.command);
        tool.started_at = try dupOpt(self.allocator, record.timestamp);
        tool.cwd = try dupOpt(self.allocator, record.cwd);
        tool.lifecycle_status = .declared;
        tool.declared_line = @intCast(record.line);
        try self.trace.tools.append(self.allocator, tool);
        owned = false;
        if (turn) |position| self.trace.turns.items[position].tool_count += 1;
        try core.retainNewestTools(self.allocator, self.trace, self.options.max_tools);
    }

    fn findTool(self: *ClaudeParser, call_id: []const u8) ?usize {
        var position = self.trace.tools.items.len;
        while (position > 0) {
            position -= 1;
            const existing = self.trace.tools.items[position].call_id orelse continue;
            if (std.mem.eql(u8, existing, call_id)) return position;
        }
        return null;
    }

    fn finalizeTool(self: *ClaudeParser, record: Record, result: ResultBlock, turn: ?u32) !void {
        if (self.trace.omitted_tool_call_ids.contains(result.call_id)) return;
        const position = self.findTool(result.call_id) orelse blk: {
            var tool = try self.newTool(result.call_id, turn);
            errdefer tool.deinit(self.allocator);
            tool.lifecycle_status = .inferred;
            try self.trace.tools.append(self.allocator, tool);
            if (turn) |owner| self.trace.turns.items[owner].tool_count += 1;
            try core.retainNewestTools(self.allocator, self.trace, self.options.max_tools);
            break :blk self.findTool(result.call_id) orelse return;
        };
        const tool = &self.trace.tools.items[position];
        try replaceOpt(self.allocator, &tool.output_text, result.text);
        try replaceNullable(self.allocator, &tool.completed_at, record.timestamp);
        tool.finalized_line = @intCast(record.line);
        if (result.is_error and eql(tool.tool_name, "Bash")) tool.exit_code = reportedExitCode(result.first_text);
        tool.lifecycle_status = if (result.is_error) .failed else .completed;
        if (!self.options.include_tool_output_parts) return;
        const source_event_id = if (record.occurrence) |occurrence|
            self.trace.occurrences.items[occurrence].sourceEventId()
        else
            null;
        for (result.parts) |part| {
            const json = try std.json.Stringify.valueAlloc(self.allocator, .{
                .source_event_id = source_event_id,
                .line_number = record.line,
                .timestamp = record.timestamp,
                .payload_pointer = part.pointer,
                .text = part.text,
                .process_results = [_]u8{},
            }, .{});
            errdefer self.allocator.free(json);
            try tool.output_parts.append(self.allocator, json);
        }
    }

    fn updateOccurrences(self: *ClaudeParser, graph: *const turns_mod.Graph) !void {
        for (self.records.items, 0..) |record, index| {
            const position = record.occurrence orelse continue;
            const occurrence = &self.trace.occurrences.items[position];
            const turn = if (graph.modeled[index]) graph.owner[index] else null;
            occurrence.turn_index = if (turn) |value| @intCast(value + 1) else null;
            if (!graph.modeled[index]) continue;
            const visible_response = record.isModelResponse() and record.hasText();
            const opening = if (turn) |value|
                graph.turns[value].anchor == index and !graph.turns[value].fallback
            else
                false;
            const visible_input = opening and record.visibleOrigin() and record.text != null;
            occurrence.message_visible = visible_response or visible_input;
            if (occurrence.message_visible) occurrence.message_id = try dupOpt(self.allocator, record.uuid);
        }
    }

    fn emitTokenEvents(
        self: *ClaudeParser,
        graph: *const turns_mod.Graph,
        accounting: tokens_mod.Accounting,
    ) !void {
        for (accounting.rows) |row| {
            const record = self.records.items[row.record];
            const occurrence = record.occurrence orelse continue;
            var event = core.TokenEventRecord{ .occurrence_index = occurrence, .turn_index = null };
            errdefer event.deinit(self.allocator);
            if (row.kind != .unanswered) {
                if (graph.owner[row.record]) |turn| event.turn_index = @intCast(turn + 1);
                event.model = try dupOpt(self.allocator, record.model);
                event.service_tier = try dupOpt(self.allocator, record.service_tier);
            }
            event.has_last_usage = row.has_last_usage;
            event.usage_model = "per-request";
            event.request_key = try dupOpt(self.allocator, row.key);
            event.request_record = if (row.authorship) |value| @tagName(value) else null;
            event.usage_finality = if (row.finality) |value| @tagName(value) else null;
            event.quantity_state = if (row.kind == .unanswered) null else @tagName(row.quantity.state);
            if (row.quantity.usable()) fillCounters(&event, row.quantity);
            try self.trace.token_events.append(self.allocator, event);
        }
    }

    fn fillCounters(event: *core.TokenEventRecord, quantity: Quantity) void {
        event.input_tokens = quantity.input;
        event.cached_input_tokens = quantity.cached;
        event.output_tokens = quantity.output;
        event.reasoning_output_tokens = quantity.reasoning;
        event.total_tokens = quantity.total;
        event.last_input_tokens = quantity.input;
        event.last_cached_input_tokens = quantity.cached;
        event.last_output_tokens = quantity.output;
        event.last_reasoning_output_tokens = quantity.reasoning;
        event.last_total_tokens = quantity.total;
        event.cache_creation_input_tokens = quantity.cache_creation;
    }

    fn warn(self: *ClaudeParser, line: usize, description: []const u8) !void {
        const warning = try std.fmt.allocPrint(
            self.allocator,
            "{s}:{d}: {s}",
            .{ self.trace.session.path, line, description },
        );
        errdefer self.allocator.free(warning);
        try self.trace.warnings.append(self.allocator, warning);
    }
};

pub fn toolKind(name: []const u8) core.ToolKind {
    if (std.mem.eql(u8, name, "Bash")) return .exec_command;
    if (oneOf(name, &.{ "Edit", "Write", "NotebookEdit" })) return .patch_apply;
    if (oneOf(name, &.{ "Agent", "Task" })) return .spawn_agent;
    if (std.mem.eql(u8, name, "WebSearch")) return .web_search;
    if (std.mem.startsWith(u8, name, "mcp__")) return .mcp_tool;
    return .unknown;
}

pub fn reportedExitCode(first_text: ?[]const u8) ?i64 {
    const text = first_text orelse return null;
    const prefix = "Exit code ";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const rest = text[prefix.len..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const digits = std.mem.trimEnd(u8, rest[0..end], "\r");
    return std.fmt.parseInt(i64, digits, 10) catch null;
}

fn digestOf(bytes: []const u8) [71]u8 {
    var raw: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    const hex = std.fmt.bytesToHex(raw, .lower);
    var encoded: [71]u8 = undefined;
    @memcpy(encoded[0..7], "sha256:");
    @memcpy(encoded[7..], &hex);
    return encoded;
}

pub fn timestampMillis(text: []const u8) ?i64 {
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T') return null;
    if (text[13] != ':' or text[16] != ':') return null;
    const year = std.fmt.parseInt(i32, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    var position: usize = 19;
    var millis: i64 = 0;
    if (text[position] == '.') {
        position += 1;
        var digits: usize = 0;
        while (position < text.len and std.ascii.isDigit(text[position])) : (position += 1) {
            if (digits < 3) millis = millis * 10 + (text[position] - '0');
            digits += 1;
        }
        if (digits == 0) return null;
        while (digits < 3) : (digits += 1) millis *= 10;
    }
    const offset = zoneOffsetSeconds(text[position..]) orelse return null;
    const days = daysFromCivil(year, month, day);
    const seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset;
    return seconds * 1000 + millis;
}

fn zoneOffsetSeconds(zone: []const u8) ?i64 {
    if (zone.len == 1 and zone[0] == 'Z') return 0;
    if (zone.len != 6 or zone[3] != ':') return null;
    const sign: i64 = switch (zone[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const hours = std.fmt.parseInt(i64, zone[1..3], 10) catch return null;
    const minutes = std.fmt.parseInt(i64, zone[4..6], 10) catch return null;
    if (hours > 23 or minutes > 59) return null;
    return sign * (hours * 3600 + minutes * 60);
}

fn daysFromCivil(year_in: i32, month: u8, day: u8) i64 {
    const year: i64 = if (month <= 2) year_in - 1 else year_in;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

fn dupOpt(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn freeOpt(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |text| allocator.free(text);
}

fn replaceOpt(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    const replacement = try allocator.dupe(u8, value);
    freeOpt(allocator, slot.*);
    slot.* = replacement;
}

fn replaceNullable(allocator: std.mem.Allocator, slot: *?[]u8, value: ?[]const u8) !void {
    if (value) |text| {
        try replaceOpt(allocator, slot, text);
    } else {
        freeOpt(allocator, slot.*);
        slot.* = null;
    }
}

test "timestamps convert to epoch milliseconds" {
    try std.testing.expectEqual(@as(?i64, 0), timestampMillis("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(
        @as(?i64, 1_794_678_204_397),
        timestampMillis("2026-11-14T17:43:24.397Z"),
    );
    try std.testing.expectEqual(@as(?i64, null), timestampMillis("2026-11-14"));
}

test "reported exit codes require the complete leading line" {
    try std.testing.expectEqual(@as(?i64, 2), reportedExitCode("Exit code 2\nboom"));
    try std.testing.expectEqual(@as(?i64, -1), reportedExitCode("Exit code -1"));
    try std.testing.expectEqual(@as(?i64, null), reportedExitCode("Exit code 2x"));
    try std.testing.expectEqual(@as(?i64, null), reportedExitCode("boom"));
}

pub fn isPrefixSeed(root: std.json.ObjectMap) bool {
    const kind = Kind.fromType(stringField(root, "type"));
    return kind.isConversation() and stringField(root, "sessionId") != null and
        stringField(root, "cwd") != null and stringField(root, "timestamp") != null;
}
