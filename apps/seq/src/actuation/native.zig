const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const time_utils = @import("../time_utils.zig");

pub const dataset_version = "SEQ-ACTUATION-NATIVE-v1";
pub const provenance = "call-id-joined-tool-output";

pub const RecordKind = enum {
    transition,
    error_record,
    closure_decision,
    bootstrap,

    pub fn label(self: RecordKind) []const u8 {
        return switch (self) {
            .transition => "transition",
            .error_record => "error",
            .closure_decision => "closure-decision",
            .bootstrap => "bootstrap",
        };
    }
};

pub const CommandKind = enum {
    open,
    prepare,
    record,
    execute,
    observe,
    abort,
    supersede,
    state,
    close,
    decide,
    doctor,
    path,
    bootstrap,

    pub fn label(self: CommandKind) []const u8 {
        return @tagName(self);
    }

    fn parse(raw: []const u8) ?CommandKind {
        inline for (@typeInfo(CommandKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

const Invocation = struct {
    command: CommandKind,
    run_id: ?[]const u8 = null,

    fn deinit(self: *Invocation, allocator: std.mem.Allocator) void {
        if (self.run_id) |run_id| allocator.free(run_id);
    }
};

pub const Record = struct {
    kind: RecordKind,
    command: CommandKind,
    call_id: []u8,
    timestamp: ?[]u8,
    run_id: ?[]u8,
    goal_id: ?[]u8,
    generation_id: ?[]u8,
    generation_kind: ?[]u8,
    predecessor_generation_id: ?[]u8,
    reserved_successor_generation_id: ?[]u8,
    event_digest: ?[]u8,
    artifact_digest: ?[]u8,
    passed: ?bool,
    exit_code: ?i64,
    error_name: ?[]u8,
    decision_id: ?[]u8,
    decision_verdict: ?[]u8,
    valid_join: bool,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        freeOpt(allocator, self.timestamp);
        freeOpt(allocator, self.run_id);
        freeOpt(allocator, self.goal_id);
        freeOpt(allocator, self.generation_id);
        freeOpt(allocator, self.generation_kind);
        freeOpt(allocator, self.predecessor_generation_id);
        freeOpt(allocator, self.reserved_successor_generation_id);
        freeOpt(allocator, self.event_digest);
        freeOpt(allocator, self.artifact_digest);
        freeOpt(allocator, self.error_name);
        freeOpt(allocator, self.decision_id);
        freeOpt(allocator, self.decision_verdict);
    }
};

pub const Generation = struct {
    run_id: []u8,
    goal_id: ?[]u8 = null,
    generation_id: ?[]u8 = null,
    generation_kind: []u8,
    predecessor_generation_id: ?[]u8 = null,
    reserved_successor_generation_id: ?[]u8 = null,
    transition_count: usize = 0,
    open_count: usize = 0,
    close_count: usize = 0,
    supersede_count: usize = 0,
    abort_count: usize = 0,
    error_count: usize = 0,
    failed_observations: usize = 0,
    closure_decision_count: usize = 0,
    lifecycle_status: []u8,
    lineage_status: []u8,
    uncertainty: []u8,
    identity_initialized: bool = false,
    identity_conflict: bool = false,

    pub fn deinit(self: *Generation, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        freeOpt(allocator, self.goal_id);
        freeOpt(allocator, self.generation_id);
        allocator.free(self.generation_kind);
        freeOpt(allocator, self.predecessor_generation_id);
        freeOpt(allocator, self.reserved_successor_generation_id);
        allocator.free(self.lifecycle_status);
        allocator.free(self.lineage_status);
        allocator.free(self.uncertainty);
    }

    pub fn legacy(self: Generation) bool {
        return std.mem.eql(u8, self.generation_kind, "legacy-v1");
    }
};

pub const Summary = struct {
    transition_results: usize = 0,
    represented_run_ids: usize = 0,
    opens: usize = 0,
    closes: usize = 0,
    supersedes: usize = 0,
    aborts: usize = 0,
    opened_without_terminal: usize = 0,
    errors: usize = 0,
    failed_observations: usize = 0,
    closure_decision_rows: usize = 0,
    unique_closure_decisions: usize = 0,
    closure_decision_runs: usize = 0,
    bootstrap_invocations: usize = 0,
    invalid_v2_lineages: usize = 0,
    duplicate_edges: usize = 0,
    unclosed_terminal_v2_runs: usize = 0,
    invalid_joins: usize = 0,
};

pub const Analysis = struct {
    records: []Record,
    generations: []Generation,
    summary: Summary,
    strict_failure: bool,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        for (self.records) |*record| record.deinit(allocator);
        allocator.free(self.records);
        for (self.generations) |*generation| generation.deinit(allocator);
        allocator.free(self.generations);
    }
};

pub const AnalyzeOptions = struct {
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
};

const ToolEvidence = struct {
    call_id: []const u8,
    timestamp: ?[]const u8 = null,
    input_text: ?[]const u8 = null,
    command_text: ?[]const u8 = null,
    arguments_json: ?[]const u8 = null,
    output_text: []const u8,
};

const RawCall = struct {
    call_id: []u8,
    timestamp: ?[]u8 = null,
    input_text: ?[]u8 = null,
    command_text: ?[]u8 = null,
    arguments_json: ?[]u8 = null,

    fn deinit(self: *RawCall, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        freeOpt(allocator, self.timestamp);
        freeOpt(allocator, self.input_text);
        freeOpt(allocator, self.command_text);
        freeOpt(allocator, self.arguments_json);
    }
};

pub fn analyzeTrace(
    allocator: std.mem.Allocator,
    trace: canonical_trace.CanonicalSessionTrace,
) !Analysis {
    return analyzeTraceWithOptions(allocator, trace, .{});
}

pub fn analyzeTraceWithOptions(
    allocator: std.mem.Allocator,
    trace: canonical_trace.CanonicalSessionTrace,
    options: AnalyzeOptions,
) !Analysis {
    var records = try collectRecords(allocator, trace, options);
    errdefer deinitRecords(allocator, &records);
    var generations: std.ArrayList(Generation) = .empty;
    errdefer deinitGenerations(allocator, &generations);
    var summary = Summary{};
    try summarizeRecords(allocator, records.items, &generations, &summary);
    const session_terminal = sessionEndsWithinWindow(trace, options);
    try validateGenerations(
        allocator,
        generations.items,
        session_terminal,
        options.since_ms != null,
        &summary,
    );
    return .{
        .records = try records.toOwnedSlice(allocator),
        .generations = try generations.toOwnedSlice(allocator),
        .summary = summary,
        .strict_failure = strictFailure(summary),
    };
}

fn collectRecords(
    allocator: std.mem.Allocator,
    trace: canonical_trace.CanonicalSessionTrace,
    options: AnalyzeOptions,
) !std.ArrayList(Record) {
    var records: std.ArrayList(Record) = .empty;
    errdefer deinitRecords(allocator, &records);
    const used_raw_trace = appendRawTraceRecords(
        allocator,
        &records,
        trace.session.path,
        options,
    ) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    if (!used_raw_trace) try appendCanonicalRecords(allocator, &records, trace, options);
    return records;
}

fn appendCanonicalRecords(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    trace: canonical_trace.CanonicalSessionTrace,
    options: AnalyzeOptions,
) !void {
    for (trace.tools.items) |tool| {
        const call_id = tool.call_id orelse continue;
        const output_text = tool.output_text orelse continue;
        try appendToolRecords(allocator, records, .{
            .call_id = call_id,
            .timestamp = tool.completed_at orelse tool.started_at,
            .input_text = tool.input_text,
            .command_text = tool.command_text,
            .arguments_json = tool.arguments_json,
            .output_text = output_text,
        }, options);
    }
}

fn summarizeRecords(
    allocator: std.mem.Allocator,
    records: []const Record,
    generations: *std.ArrayList(Generation),
    summary: *Summary,
) !void {
    var decision_ids = std.StringHashMap(void).init(allocator);
    defer decision_ids.deinit();
    var decision_runs = std.StringHashMap(void).init(allocator);
    defer decision_runs.deinit();
    for (records) |record| try summarizeRecord(
        allocator,
        generations,
        summary,
        &decision_ids,
        &decision_runs,
        record,
    );
    summary.unique_closure_decisions = decision_ids.count();
    summary.closure_decision_runs = decision_runs.count();
    summary.represented_run_ids = generations.items.len;
}

fn strictFailure(summary: Summary) bool {
    return summary.invalid_v2_lineages > 0 or
        summary.duplicate_edges > 0 or
        summary.unclosed_terminal_v2_runs > 0 or
        summary.invalid_joins > 0;
}

fn sessionEndsWithinWindow(
    trace: canonical_trace.CanonicalSessionTrace,
    options: AnalyzeOptions,
) bool {
    if (trace.session.is_ongoing) return false;
    const end_time = trace.session.end_time orelse return false;
    const end_time_ms = time_utils.parseIsoTimestampMillis(end_time) orelse return false;
    return if (options.until_ms) |until_ms| end_time_ms <= until_ms else true;
}

fn summarizeRecord(
    allocator: std.mem.Allocator,
    generations: *std.ArrayList(Generation),
    summary: *Summary,
    decision_ids: *std.StringHashMap(void),
    decision_runs: *std.StringHashMap(void),
    record: Record,
) !void {
    if (!record.valid_join) {
        summary.invalid_joins += 1;
        return;
    }
    switch (record.kind) {
        .transition => try summarizeTransition(allocator, generations, summary, record),
        .error_record => {
            summary.errors += 1;
            const run_id = record.run_id orelse return;
            const generation = findGeneration(generations, run_id) orelse return;
            generation.error_count += 1;
        },
        .closure_decision => {
            summary.closure_decision_rows += 1;
            if (record.decision_id) |decision_id| try decision_ids.put(decision_id, {});
            const run_id = record.run_id orelse return;
            try decision_runs.put(run_id, {});
            const generation = findGeneration(generations, run_id) orelse return;
            generation.closure_decision_count += 1;
        },
        .bootstrap => summary.bootstrap_invocations += 1,
    }
}

fn summarizeTransition(
    allocator: std.mem.Allocator,
    generations: *std.ArrayList(Generation),
    summary: *Summary,
    record: Record,
) !void {
    summary.transition_results += 1;
    const run_id = record.run_id orelse return;
    const generation = try findOrCreateGeneration(allocator, generations, run_id);
    generation.transition_count += 1;
    try mergeIdentity(allocator, generation, record);
    switch (record.command) {
        .open => {
            generation.open_count += 1;
            summary.opens += 1;
        },
        .close => {
            generation.close_count += 1;
            summary.closes += 1;
        },
        .supersede => {
            generation.supersede_count += 1;
            summary.supersedes += 1;
        },
        .abort => {
            generation.abort_count += 1;
            summary.aborts += 1;
        },
        else => {},
    }
    if (record.passed == false) {
        generation.failed_observations += 1;
        summary.failed_observations += 1;
    }
}

fn appendToolRecords(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    tool: ToolEvidence,
    options: AnalyzeOptions,
) !void {
    if (!timestampInBounds(tool.timestamp, options)) return;
    var command_texts: std.ArrayList([]u8) = .empty;
    defer {
        for (command_texts.items) |text| allocator.free(text);
        command_texts.deinit(allocator);
    }
    try collectToolCommandTexts(allocator, &command_texts, tool);
    var invocations: std.ArrayList(Invocation) = .empty;
    defer {
        for (invocations.items) |*invocation| invocation.deinit(allocator);
        invocations.deinit(allocator);
    }
    for (command_texts.items) |command_text| {
        try appendInvocations(allocator, &invocations, command_text);
    }
    if (invocations.items.len == 0) return;
    const bootstrap_invocations = invocationCount(invocations.items, .bootstrap);
    try scanOutput(
        allocator,
        records,
        invocations.items,
        tool.call_id,
        tool.timestamp,
        tool.output_text,
    );
    var remaining_bootstraps = bootstrap_invocations;
    while (remaining_bootstraps > 0) : (remaining_bootstraps -= 1) {
        try records.append(allocator, .{
            .kind = .bootstrap,
            .command = .bootstrap,
            .call_id = try allocator.dupe(u8, tool.call_id),
            .timestamp = try dupOpt(allocator, tool.timestamp),
            .run_id = null,
            .goal_id = null,
            .generation_id = null,
            .generation_kind = null,
            .predecessor_generation_id = null,
            .reserved_successor_generation_id = null,
            .event_digest = null,
            .artifact_digest = null,
            .passed = null,
            .exit_code = null,
            .error_name = null,
            .decision_id = null,
            .decision_verdict = null,
            .valid_join = true,
        });
    }
}

fn appendRawTraceRecords(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    path: []const u8,
    options: AnalyzeOptions,
) !bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const content = try reader.interface.allocRemaining(allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(content);

    var calls = std.StringHashMap(RawCall).init(allocator);
    defer {
        var values = calls.valueIterator();
        while (values.next()) |call| call.deinit(allocator);
        calls.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const root = valueObject(parsed.value) orelse continue;
        const payload = objectField(root, "payload") orelse root;
        const payload_type = stringField(payload, "type") orelse
            inferRawPayloadType(payload) orelse continue;
        const timestamp = stringField(root, "timestamp") orelse stringField(payload, "timestamp");
        if (std.mem.eql(u8, payload_type, "function_call") or
            std.mem.eql(u8, payload_type, "custom_tool_call"))
        {
            try rememberRawCall(allocator, &calls, payload, timestamp);
            continue;
        }
        if (!std.mem.eql(u8, payload_type, "function_call_output") and
            !std.mem.eql(u8, payload_type, "custom_tool_call_output")) continue;
        const call_id = stringField(payload, "call_id") orelse
            stringField(payload, "id") orelse continue;
        const output_text = try rawToolOutputTextAlloc(allocator, payload);
        defer allocator.free(output_text);
        const call = calls.getPtr(call_id);
        if (call == null) continue;
        try appendToolRecords(allocator, records, .{
            .call_id = call_id,
            .timestamp = timestamp orelse call.?.timestamp,
            .input_text = call.?.input_text,
            .command_text = call.?.command_text,
            .arguments_json = call.?.arguments_json,
            .output_text = output_text,
        }, options);
    }
    return true;
}

fn inferRawPayloadType(payload: std.json.ObjectMap) ?[]const u8 {
    if (payload.get("call_id") == null) return null;
    if (payload.get("arguments") != null) return "function_call";
    if (payload.get("output") != null) return "function_call_output";
    return null;
}

fn rememberRawCall(
    allocator: std.mem.Allocator,
    calls: *std.StringHashMap(RawCall),
    payload: std.json.ObjectMap,
    timestamp: ?[]const u8,
) !void {
    const call_id = stringField(payload, "call_id") orelse stringField(payload, "id") orelse return;
    var call = RawCall{
        .call_id = try allocator.dupe(u8, call_id),
        .timestamp = try dupOpt(allocator, timestamp),
        .input_text = try dupOpt(allocator, stringField(payload, "input")),
        .arguments_json = try dupOpt(allocator, stringField(payload, "arguments")),
        .command_text = try dupOpt(
            allocator,
            stringField(payload, "command") orelse stringField(payload, "cmd"),
        ),
    };
    errdefer call.deinit(allocator);
    if (call.command_text == null) {
        if (call.arguments_json) |arguments| {
            call.command_text = try jsonCommandTextAlloc(allocator, arguments);
        }
    }
    if (calls.fetchRemove(call_id)) |removed| {
        var prior = removed.value;
        prior.deinit(allocator);
    }
    try calls.put(call.call_id, call);
}

fn jsonCommandTextAlloc(allocator: std.mem.Allocator, arguments: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        arguments,
        .{},
    ) catch return null;
    defer parsed.deinit();
    const object = valueObject(parsed.value) orelse return null;
    return dupOpt(
        allocator,
        stringField(object, "cmd") orelse
            stringField(object, "command") orelse
            stringField(object, "chars"),
    );
}

fn rawToolOutputTextAlloc(allocator: std.mem.Allocator, payload: std.json.ObjectMap) ![]u8 {
    for ([_][]const u8{ "output", "aggregated_output", "stdout" }) |key| {
        if (stringField(payload, key)) |text| return allocator.dupe(u8, text);
        const raw = payload.get(key) orelse continue;
        const parts = switch (raw) {
            .array => |array| array,
            else => continue,
        };
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        for (parts.items) |part| {
            const object = valueObject(part) orelse continue;
            const text = stringField(object, "text") orelse continue;
            if (out.items.len > 0) try out.append(allocator, 0x1e);
            try out.appendSlice(allocator, text);
        }
        return out.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, "");
}

fn timestampInBounds(timestamp: ?[]const u8, options: AnalyzeOptions) bool {
    if (options.since_ms == null and options.until_ms == null) return true;
    const value = timestamp orelse return false;
    const value_ms = time_utils.parseIsoTimestampMillis(value) orelse return false;
    if (options.since_ms) |since_ms| if (value_ms < since_ms) return false;
    if (options.until_ms) |until_ms| if (value_ms > until_ms) return false;
    return true;
}

fn scanOutput(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    invocations: []const Invocation,
    call_id: []const u8,
    timestamp: ?[]const u8,
    text: []const u8,
) !void {
    var parts = std.mem.splitScalar(u8, text, 0x1e);
    while (parts.next()) |part| {
        var lines = std.mem.splitScalar(u8, part, '\n');
        while (lines.next()) |line| {
            const candidate = std.mem.trim(u8, line, " \t\r");
            if (candidate.len == 0) continue;
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                candidate,
                .{},
            ) catch continue;
            defer parsed.deinit();
            const object = valueObject(parsed.value) orelse continue;
            _ = try appendRecognizedRecord(
                allocator,
                records,
                invocations,
                call_id,
                timestamp,
                object,
            );
        }
    }
}

fn appendRecognizedRecord(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    invocations: []const Invocation,
    call_id: []const u8,
    timestamp: ?[]const u8,
    object: std.json.ObjectMap,
) !bool {
    if (stringField(object, "schema")) |schema| {
        if (std.mem.eql(u8, schema, "actuation-transition-result/v1")) {
            return appendTransitionRecord(
                allocator,
                records,
                invocations,
                call_id,
                timestamp,
                object,
            );
        }
        if (std.mem.eql(u8, schema, "actuation-error/v1")) {
            try appendErrorRecord(
                allocator,
                records,
                invocations,
                call_id,
                timestamp,
                object,
            );
            return true;
        }
        if (std.mem.eql(u8, schema, "ledger-bootstrap-ready/v1")) {
            return true;
        }
    }
    const decision = objectField(object, "closure_decision") orelse return false;
    if (!std.mem.eql(u8, stringField(decision, "version") orelse "", "closure-decision/v1")) {
        return false;
    }
    try appendDecisionRecord(
        allocator,
        records,
        hasInvocation(
            invocations,
            .decide,
            stringField(decision, "run_id"),
        ),
        call_id,
        timestamp,
        decision,
    );
    return true;
}

fn appendTransitionRecord(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    invocations: []const Invocation,
    call_id: []const u8,
    timestamp: ?[]const u8,
    object: std.json.ObjectMap,
) !bool {
    const output_command = CommandKind.parse(stringField(object, "command") orelse "");
    const fallback = firstNonBootstrapInvocation(invocations);
    const record_command = output_command orelse
        if (fallback) |value| value.command else return false;
    try records.append(allocator, .{
        .kind = .transition,
        .command = record_command,
        .call_id = try allocator.dupe(u8, call_id),
        .timestamp = try dupOpt(allocator, timestamp),
        .run_id = try dupOpt(allocator, stringField(object, "run_id")),
        .goal_id = try dupOpt(allocator, stringField(object, "goal_id")),
        .generation_id = try dupOpt(allocator, stringField(object, "generation_id")),
        .generation_kind = try dupOpt(allocator, stringField(object, "generation_kind")),
        .predecessor_generation_id = try dupOpt(
            allocator,
            stringField(object, "predecessor_generation_id"),
        ),
        .reserved_successor_generation_id = try dupOpt(
            allocator,
            stringField(object, "reserved_successor_generation_id"),
        ),
        .event_digest = try dupOpt(allocator, stringField(object, "event_digest")),
        .artifact_digest = try dupOpt(allocator, stringField(object, "artifact_digest")),
        .passed = boolField(object, "passed"),
        .exit_code = intField(object, "exit_code"),
        .error_name = null,
        .decision_id = null,
        .decision_verdict = null,
        .valid_join = if (output_command) |command|
            hasInvocation(invocations, command, stringField(object, "run_id"))
        else
            false,
    });
    return true;
}

fn appendErrorRecord(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    invocations: []const Invocation,
    call_id: []const u8,
    timestamp: ?[]const u8,
    object: std.json.ObjectMap,
) !void {
    const matched = uniqueNonBootstrapInvocation(invocations);
    try records.append(allocator, .{
        .kind = .error_record,
        .command = if (matched) |value| value.command else .state,
        .call_id = try allocator.dupe(u8, call_id),
        .timestamp = try dupOpt(allocator, timestamp),
        .run_id = try dupOpt(allocator, if (matched) |value| value.run_id else null),
        .goal_id = null,
        .generation_id = null,
        .generation_kind = null,
        .predecessor_generation_id = null,
        .reserved_successor_generation_id = null,
        .event_digest = null,
        .artifact_digest = null,
        .passed = null,
        .exit_code = null,
        .error_name = try dupOpt(allocator, stringField(object, "error")),
        .decision_id = null,
        .decision_verdict = null,
        .valid_join = matched != null,
    });
}

fn appendDecisionRecord(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    actuation_eligible: bool,
    call_id: []const u8,
    timestamp: ?[]const u8,
    decision: std.json.ObjectMap,
) !void {
    try records.append(allocator, .{
        .kind = .closure_decision,
        .command = .decide,
        .call_id = try allocator.dupe(u8, call_id),
        .timestamp = try dupOpt(allocator, timestamp),
        .run_id = try dupOpt(allocator, stringField(decision, "run_id")),
        .goal_id = null,
        .generation_id = null,
        .generation_kind = null,
        .predecessor_generation_id = null,
        .reserved_successor_generation_id = null,
        .event_digest = null,
        .artifact_digest = null,
        .passed = null,
        .exit_code = null,
        .error_name = null,
        .decision_id = try dupOpt(allocator, stringField(decision, "decision_id")),
        .decision_verdict = try dupOpt(allocator, stringField(decision, "verdict")),
        .valid_join = actuation_eligible,
    });
}

fn collectToolCommandTexts(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList([]u8),
    tool: ToolEvidence,
) !void {
    if (tool.input_text) |input| {
        try appendJsCallProperties(allocator, commands, input, "tools.exec_command", "cmd");
        try appendJsCallProperties(allocator, commands, input, "tools.write_stdin", "chars");
        try appendJsShorthandCommands(allocator, commands, input, "tools.exec_command", "cmd");
        try appendJsShorthandCommands(allocator, commands, input, "tools.write_stdin", "chars");
    }
    if (commands.items.len == 0) {
        if (tool.command_text) |command| {
            try commands.append(allocator, try allocator.dupe(u8, command));
        }
    }
}

fn hasInvocation(
    invocations: []const Invocation,
    command: CommandKind,
    run_id: ?[]const u8,
) bool {
    for (invocations) |invocation| {
        if (invocation.command != command) continue;
        if (command == .open) return true;
        const output_run_id = run_id orelse continue;
        const invocation_run_id = invocation.run_id orelse continue;
        if (std.mem.eql(u8, output_run_id, invocation_run_id)) return true;
    }
    return false;
}

fn appendJsShorthandCommands(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList([]u8),
    source: []const u8,
    marker: []const u8,
    property: []const u8,
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, marker)) |start| {
        const after_marker = start + marker.len;
        const end = std.mem.indexOfPos(u8, source, after_marker, "tools.") orelse source.len;
        if (hasJsShorthandProperty(source[after_marker..end], property)) {
            if (try latestJsAssignedStringAlloc(
                allocator,
                source[0..start],
                property,
            )) |command| {
                const resolved = try resolveJsTemplateAlloc(
                    allocator,
                    source[0..start],
                    command,
                );
                allocator.free(command);
                try commands.append(allocator, resolved);
            }
            if (std.mem.eql(u8, property, "cmd")) {
                try appendJsCommandArrayStrings(allocator, commands, source[0..end]);
            }
        }
        cursor = after_marker;
    }
}

fn hasJsShorthandProperty(source: []const u8, property: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, property)) |index| {
        const before_ok = index == 0 or
            (!std.ascii.isAlphanumeric(source[index - 1]) and source[index - 1] != '_');
        var position = index + property.len;
        const after_name_ok = position == source.len or
            (!std.ascii.isAlphanumeric(source[position]) and source[position] != '_');
        while (position < source.len and std.ascii.isWhitespace(source[position])) position += 1;
        if (before_ok and after_name_ok and position < source.len and
            (source[position] == ',' or source[position] == '}'))
        {
            return true;
        }
        cursor = index + property.len;
    }
    return false;
}

fn latestJsAssignedStringAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    name: []const u8,
) !?[]u8 {
    var latest: ?[]u8 = null;
    errdefer if (latest) |value| allocator.free(value);
    for ([_][]const u8{ "const ", "let ", "var " }) |declaration| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, source, cursor, declaration)) |start| {
            const name_start = start + declaration.len;
            if (!std.mem.startsWith(u8, source[name_start..], name)) {
                cursor = name_start;
                continue;
            }
            var position = name_start + name.len;
            if (position < source.len and
                (std.ascii.isAlphanumeric(source[position]) or source[position] == '_'))
            {
                cursor = position;
                continue;
            }
            while (position < source.len and std.ascii.isWhitespace(source[position])) {
                position += 1;
            }
            if (position >= source.len or source[position] != '=') {
                cursor = position;
                continue;
            }
            position += 1;
            while (position < source.len and std.ascii.isWhitespace(source[position])) {
                position += 1;
            }
            if (std.mem.startsWith(u8, source[position..], "String.raw")) {
                position += "String.raw".len;
                while (position < source.len and std.ascii.isWhitespace(source[position])) {
                    position += 1;
                }
            }
            const decoded = try jsStringLiteralAtAlloc(allocator, source, position) orelse {
                cursor = position;
                continue;
            };
            if (latest) |value| allocator.free(value);
            latest = decoded.value;
            cursor = decoded.end;
        }
    }
    return latest;
}

fn appendJsCommandArrayStrings(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList([]u8),
    source: []const u8,
) !void {
    for ([_][]const u8{ "cmds", "commands" }) |name| {
        const map_marker = try std.fmt.allocPrint(allocator, "{s}.map", .{name});
        defer allocator.free(map_marker);
        const loop_marker = try std.fmt.allocPrint(allocator, "of {s}", .{name});
        defer allocator.free(loop_marker);
        if (std.mem.indexOf(u8, source, map_marker) == null and
            std.mem.indexOf(u8, source, loop_marker) == null)
        {
            continue;
        }
        const declaration = try std.fmt.allocPrint(allocator, "const {s}", .{name});
        defer allocator.free(declaration);
        const start = std.mem.indexOf(u8, source, declaration) orelse continue;
        const equals = std.mem.indexOfPos(u8, source, start + declaration.len, "=") orelse continue;
        const array_start = std.mem.indexOfPos(u8, source, equals + 1, "[") orelse continue;
        const array_end = jsArrayEnd(source, array_start) orelse continue;
        var position = array_start + 1;
        while (position < array_end) {
            if (!isJsStringQuote(source[position])) {
                position += 1;
                continue;
            }
            const decoded = try jsStringLiteralAtAlloc(allocator, source, position) orelse {
                position += 1;
                continue;
            };
            const resolved = try resolveJsTemplateAlloc(
                allocator,
                source[0..array_start],
                decoded.value,
            );
            allocator.free(decoded.value);
            try commands.append(allocator, resolved);
            position = decoded.end;
        }
    }
}

fn resolveJsTemplateAlloc(
    allocator: std.mem.Allocator,
    source_prefix: []const u8,
    template: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var position: usize = 0;
    while (std.mem.indexOfPos(u8, template, position, "${")) |start| {
        try out.appendSlice(allocator, template[position..start]);
        const end = std.mem.indexOfPos(u8, template, start + 2, "}") orelse {
            try out.appendSlice(allocator, template[start..]);
            return out.toOwnedSlice(allocator);
        };
        const name = std.mem.trim(u8, template[start + 2 .. end], " \t\r\n");
        const resolved = if (isJsIdentifier(name))
            try latestJsAssignedStringAlloc(allocator, source_prefix, name)
        else
            null;
        if (resolved) |value| {
            defer allocator.free(value);
            try out.appendSlice(allocator, value);
        } else {
            try out.appendSlice(allocator, "$dynamic");
        }
        position = end + 1;
    }
    try out.appendSlice(allocator, template[position..]);
    return out.toOwnedSlice(allocator);
}

fn isJsIdentifier(value: []const u8) bool {
    if (value.len == 0 or
        (!std.ascii.isAlphabetic(value[0]) and value[0] != '_' and value[0] != '$'))
    {
        return false;
    }
    for (value[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '$') return false;
    }
    return true;
}

const DecodedJsString = struct {
    value: []u8,
    end: usize,
};

fn jsStringLiteralAtAlloc(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
) !?DecodedJsString {
    if (start >= source.len or !isJsStringQuote(source[start])) return null;
    const quote = source[start];
    var position = start + 1;
    var escaped = false;
    while (position < source.len) : (position += 1) {
        const byte = source[position];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte != quote) continue;
        const value = if (quote == '"') blk: {
            var parsed = std.json.parseFromSlice(
                []const u8,
                allocator,
                source[start .. position + 1],
                .{},
            ) catch return null;
            defer parsed.deinit();
            break :blk try allocator.dupe(u8, parsed.value);
        } else try unescapeJsLiteral(allocator, source[start + 1 .. position]);
        return .{ .value = value, .end = position + 1 };
    }
    return null;
}

fn jsArrayEnd(source: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var position = start;
    while (position < source.len) {
        if (isJsStringQuote(source[position])) {
            const quote = source[position];
            position += 1;
            var escaped = false;
            while (position < source.len) : (position += 1) {
                if (escaped) {
                    escaped = false;
                } else if (source[position] == '\\') {
                    escaped = true;
                } else if (source[position] == quote) {
                    break;
                }
            }
        } else if (source[position] == '[') {
            depth += 1;
        } else if (source[position] == ']') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return position;
        }
        position += 1;
    }
    return null;
}

fn appendJsCallProperties(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList([]u8),
    source: []const u8,
    marker: []const u8,
    property: []const u8,
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, marker)) |start| {
        const after_marker = start + marker.len;
        const end = std.mem.indexOfPos(u8, source, after_marker, "tools.") orelse source.len;
        if (try jsStringPropertyAlloc(
            allocator,
            source[0..start],
            source[after_marker..end],
            property,
        )) |command| {
            try commands.append(allocator, command);
        }
        cursor = after_marker;
    }
}

fn jsStringPropertyAlloc(
    allocator: std.mem.Allocator,
    source_prefix: []const u8,
    source: []const u8,
    property: []const u8,
) !?[]u8 {
    const start = jsPropertyValueStart(source, property) orelse return null;
    if (start >= source.len or !isJsStringQuote(source[start])) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var position = start;
    while (position < source.len) {
        while (position < source.len and std.ascii.isWhitespace(source[position])) position += 1;
        if (position >= source.len) break;
        if (isJsStringQuote(source[position])) {
            const decoded = try jsStringLiteralAtAlloc(
                allocator,
                source,
                position,
            ) orelse return null;
            defer allocator.free(decoded.value);
            const resolved = try resolveJsTemplateAlloc(
                allocator,
                source_prefix,
                decoded.value,
            );
            defer allocator.free(resolved);
            try out.appendSlice(allocator, resolved);
            position = decoded.end;
        } else {
            const name_end = jsIdentifierEnd(source, position) orelse break;
            const name = source[position..name_end];
            const value = try latestJsAssignedStringAlloc(allocator, source_prefix, name);
            if (value) |resolved| {
                defer allocator.free(resolved);
                try out.appendSlice(allocator, resolved);
            } else {
                try out.appendSlice(allocator, "$dynamic");
            }
            position = name_end;
        }
        while (position < source.len and std.ascii.isWhitespace(source[position])) position += 1;
        if (position >= source.len or source[position] != '+') break;
        position += 1;
    }
    return @as(?[]u8, try out.toOwnedSlice(allocator));
}

fn jsPropertyValueStart(
    source: []const u8,
    property: []const u8,
) ?usize {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, property)) |index| {
        const before_ok = index == 0 or
            (!std.ascii.isAlphanumeric(source[index - 1]) and source[index - 1] != '_');
        var position = index + property.len;
        if (index > 0 and (source[index - 1] == '"' or source[index - 1] == '\'') and
            position < source.len and source[position] == source[index - 1])
        {
            position += 1;
        }
        while (position < source.len and std.ascii.isWhitespace(source[position])) position += 1;
        if (!before_ok or position >= source.len or source[position] != ':') {
            cursor = index + property.len;
            continue;
        }
        position += 1;
        while (position < source.len and std.ascii.isWhitespace(source[position])) position += 1;
        return position;
    }
    return null;
}

fn jsIdentifierEnd(source: []const u8, start: usize) ?usize {
    if (start >= source.len or
        (!std.ascii.isAlphabetic(source[start]) and source[start] != '_' and source[start] != '$'))
    {
        return null;
    }
    var end = start + 1;
    while (end < source.len and
        (std.ascii.isAlphanumeric(source[end]) or source[end] == '_' or source[end] == '$'))
    {
        end += 1;
    }
    return end;
}

fn isJsStringQuote(byte: u8) bool {
    return byte == '"' or byte == '\'' or byte == '`';
}

fn unescapeJsLiteral(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        if (source[index] != '\\' or index + 1 >= source.len) {
            try out.append(allocator, source[index]);
            continue;
        }
        index += 1;
        try out.append(allocator, switch (source[index]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => source[index],
        });
    }
    return out.toOwnedSlice(allocator);
}

fn appendInvocations(
    allocator: std.mem.Allocator,
    invocations: *std.ArrayList(Invocation),
    command_text: []const u8,
) !void {
    const resolved = try resolveShellRunVariablesAlloc(allocator, command_text);
    defer allocator.free(resolved);
    var start: usize = 0;
    var index: usize = 0;
    while (index <= resolved.len) : (index += 1) {
        const boundary = isCommandBoundary(resolved, index);
        if (!boundary) continue;
        const segment = std.mem.trim(u8, resolved[start..index], " \t\r");
        if (classifySegment(segment)) |invocation| {
            var owned = invocation;
            owned.run_id = try dupOpt(allocator, invocation.run_id);
            errdefer if (owned.run_id) |run_id| allocator.free(run_id);
            try invocations.append(allocator, owned);
        }
        if (index < resolved.len and resolved[index] == '&') index += 1;
        start = index + 1;
    }
}

fn resolveShellRunVariablesAlloc(
    allocator: std.mem.Allocator,
    command_text: []const u8,
) ![]u8 {
    var resolved = try std.mem.replaceOwned(u8, allocator, command_text, "\\\n", " ");
    errdefer allocator.free(resolved);
    for ([_][]const u8{ "run_id", "run" }) |name| {
        const value = shellAssignedValue(command_text, name) orelse continue;
        const braced = try std.fmt.allocPrint(allocator, "${{{s}}}", .{name});
        defer allocator.free(braced);
        const with_braced = try std.mem.replaceOwned(u8, allocator, resolved, braced, value);
        allocator.free(resolved);
        resolved = with_braced;
        const plain = try std.fmt.allocPrint(allocator, "${s}", .{name});
        defer allocator.free(plain);
        const with_plain = try std.mem.replaceOwned(u8, allocator, resolved, plain, value);
        allocator.free(resolved);
        resolved = with_plain;
    }
    return resolved;
}

fn shellAssignedValue(command_text: []const u8, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, command_text, cursor, name)) |start| {
        const before_ok = start == 0 or std.ascii.isWhitespace(command_text[start - 1]) or
            command_text[start - 1] == ';';
        var position = start + name.len;
        if (!before_ok or position >= command_text.len or command_text[position] != '=') {
            cursor = start + name.len;
            continue;
        }
        position += 1;
        const value_start = if (position < command_text.len and
            (command_text[position] == '\'' or command_text[position] == '"'))
        blk: {
            const quote = command_text[position];
            position += 1;
            const quoted_start = position;
            const end = std.mem.indexOfScalarPos(
                u8,
                command_text,
                position,
                quote,
            ) orelse return null;
            position = end;
            break :blk quoted_start;
        } else position;
        var value_end = position;
        while (value_end < command_text.len and
            !std.ascii.isWhitespace(command_text[value_end]) and command_text[value_end] != ';' and
            command_text[value_end] != '\'' and command_text[value_end] != '"')
        {
            value_end += 1;
        }
        const value = command_text[value_start..value_end];
        if (value.len == 0 or std.mem.indexOfScalar(u8, value, '$') != null) return null;
        if (found) |prior| if (!std.mem.eql(u8, prior, value)) return null;
        found = value;
        cursor = value_end;
    }
    return found;
}

fn isCommandBoundary(command_text: []const u8, index: usize) bool {
    if (index == command_text.len) return true;
    if (command_text[index] == '\n' or command_text[index] == ';') return true;
    if (command_text[index] == '|') {
        return index + 1 == command_text.len or command_text[index + 1] != '|';
    }
    return index + 1 < command_text.len and command_text[index] == '&' and
        command_text[index + 1] == '&';
}

fn classifySegment(segment: []const u8) ?Invocation {
    if (segment.len == 0) return null;
    var tokens = std.mem.tokenizeAny(u8, segment, " \t\r");
    var executable = tokens.next() orelse return null;
    if (std.mem.eql(u8, executable, "if") or
        std.mem.eql(u8, executable, "then") or
        std.mem.eql(u8, executable, "do"))
    {
        executable = tokens.next() orelse return null;
    }
    while (std.mem.indexOfScalar(u8, executable, '=') != null and
        std.mem.indexOf(u8, executable, "$(") == null)
    {
        executable = tokens.next() orelse return null;
    }
    const raw_base = std.fs.path.basename(std.mem.trim(u8, executable, "('"));
    if (std.mem.eql(u8, raw_base, "ensure-ledger")) {
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "--help") or std.mem.eql(u8, token, "-h")) return null;
        }
        return .{ .command = .bootstrap };
    }
    const runtime_wrapper = std.mem.eql(u8, raw_base, "ledger-runtime");
    const subshell_ledger = std.mem.indexOf(u8, executable, "$(ledger") != null;
    if (!runtime_wrapper and !subshell_ledger and !std.mem.eql(u8, raw_base, "ledger")) return null;
    var source_actuation = false;
    var command: ?CommandKind = null;
    var run_id: ?[]const u8 = null;
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "--source")) {
            source_actuation = std.mem.eql(u8, tokens.next() orelse return null, "actuation");
            continue;
        }
        if (std.mem.eql(u8, token, "--source=actuation")) {
            source_actuation = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--run")) {
            const run_token = tokens.next() orelse break;
            run_id = normalizeRunId(run_token);
            continue;
        }
        if (std.mem.startsWith(u8, token, "--run=")) {
            run_id = normalizeRunId(token["--run=".len..]);
            continue;
        }
        const command_token = std.mem.trim(u8, token, "'\"()\\;");
        if (command == null) command = CommandKind.parse(command_token);
    }
    if (!source_actuation or command == null or command == .bootstrap) return null;
    return .{ .command = command.?, .run_id = run_id };
}

fn normalizeRunId(raw: []const u8) ?[]const u8 {
    const normalized = std.mem.trim(u8, raw, "'\"()\\");
    if (normalized.len == 0 or std.mem.indexOfScalar(u8, normalized, '$') != null) return null;
    return normalized;
}

fn firstNonBootstrapInvocation(invocations: []const Invocation) ?Invocation {
    for (invocations) |invocation| if (invocation.command != .bootstrap) return invocation;
    return null;
}

fn uniqueNonBootstrapInvocation(invocations: []const Invocation) ?Invocation {
    var matched: ?Invocation = null;
    for (invocations) |invocation| {
        if (invocation.command == .bootstrap) continue;
        if (matched != null) return null;
        matched = invocation;
    }
    return matched;
}

fn invocationCount(invocations: []const Invocation, command: CommandKind) usize {
    var count: usize = 0;
    for (invocations) |invocation| if (invocation.command == command) {
        count += 1;
    };
    return count;
}

fn findOrCreateGeneration(
    allocator: std.mem.Allocator,
    generations: *std.ArrayList(Generation),
    run_id: []const u8,
) !*Generation {
    for (generations.items) |*generation| {
        if (std.mem.eql(u8, generation.run_id, run_id)) return generation;
    }
    try generations.append(allocator, .{
        .run_id = try allocator.dupe(u8, run_id),
        .generation_kind = try allocator.dupe(u8, "legacy-v1"),
        .lifecycle_status = try allocator.dupe(u8, "observed-without-open"),
        .lineage_status = try allocator.dupe(u8, "legacy-v1"),
        .uncertainty = try allocator.dupe(u8, "legacy-v1 lineage is not inferred"),
    });
    return &generations.items[generations.items.len - 1];
}

fn findGeneration(generations: *std.ArrayList(Generation), run_id: []const u8) ?*Generation {
    for (generations.items) |*generation| {
        if (std.mem.eql(u8, generation.run_id, run_id)) return generation;
    }
    return null;
}

fn mergeIdentity(allocator: std.mem.Allocator, generation: *Generation, record: Record) !void {
    const kind = record.generation_kind orelse {
        if (generation.identity_initialized) generation.identity_conflict = true;
        return;
    };
    if (generation.identity_initialized) {
        if (!std.mem.eql(u8, generation.generation_kind, kind) or
            !optionalEql(generation.goal_id, record.goal_id) or
            !optionalEql(generation.generation_id, record.generation_id) or
            !optionalEql(generation.predecessor_generation_id, record.predecessor_generation_id))
        {
            generation.identity_conflict = true;
        }
        if (record.reserved_successor_generation_id) |reservation| {
            if (generation.reserved_successor_generation_id) |existing| {
                if (!std.mem.eql(u8, existing, reservation)) generation.identity_conflict = true;
            } else {
                generation.reserved_successor_generation_id = try allocator.dupe(u8, reservation);
            }
        } else if (generation.reserved_successor_generation_id != null) {
            generation.identity_conflict = true;
        }
        return;
    }

    const kind_copy = try allocator.dupe(u8, kind);
    errdefer allocator.free(kind_copy);
    const goal_id = try dupOpt(allocator, record.goal_id);
    errdefer freeOpt(allocator, goal_id);
    const generation_id = try dupOpt(allocator, record.generation_id);
    errdefer freeOpt(allocator, generation_id);
    const predecessor_generation_id = try dupOpt(allocator, record.predecessor_generation_id);
    errdefer freeOpt(allocator, predecessor_generation_id);
    const reserved_successor_generation_id = try dupOpt(
        allocator,
        record.reserved_successor_generation_id,
    );
    errdefer freeOpt(allocator, reserved_successor_generation_id);

    allocator.free(generation.generation_kind);
    generation.generation_kind = kind_copy;
    generation.goal_id = goal_id;
    generation.generation_id = generation_id;
    generation.predecessor_generation_id = predecessor_generation_id;
    generation.reserved_successor_generation_id = reserved_successor_generation_id;
    generation.identity_initialized = true;
}

const GenerationIndexes = struct {
    generation_ids: std.StringHashMap(usize),
    predecessor_edges: std.StringHashMap(usize),
    goal_roots: std.StringHashMap(usize),

    fn init(allocator: std.mem.Allocator) GenerationIndexes {
        return .{
            .generation_ids = std.StringHashMap(usize).init(allocator),
            .predecessor_edges = std.StringHashMap(usize).init(allocator),
            .goal_roots = std.StringHashMap(usize).init(allocator),
        };
    }

    fn deinit(self: *GenerationIndexes) void {
        self.generation_ids.deinit();
        self.predecessor_edges.deinit();
        self.goal_roots.deinit();
    }
};

fn validateGenerations(
    allocator: std.mem.Allocator,
    generations: []Generation,
    session_terminal: bool,
    start_bounded: bool,
    summary: *Summary,
) !void {
    const invalid_flags = try allocator.alloc(bool, generations.len);
    defer allocator.free(invalid_flags);
    @memset(invalid_flags, false);
    var indexes = GenerationIndexes.init(allocator);
    defer indexes.deinit();
    for (generations, 0..) |generation, index| {
        try validateGenerationShape(
            generation,
            index,
            session_terminal,
            start_bounded,
            invalid_flags,
            &indexes,
            summary,
        );
    }
    for (generations, 0..) |*generation, index| {
        try projectGenerationState(
            allocator,
            generations,
            generation,
            index,
            start_bounded,
            invalid_flags,
            &indexes,
        );
    }
    for (invalid_flags) |invalid| if (invalid) {
        summary.invalid_v2_lineages += 1;
    };
}

fn validateGenerationShape(
    generation: Generation,
    index: usize,
    session_terminal: bool,
    start_bounded: bool,
    invalid_flags: []bool,
    indexes: *GenerationIndexes,
    summary: *Summary,
) !void {
    const terminal_count = generation.close_count + generation.supersede_count;
    if (generation.open_count > 0 and terminal_count == 0) {
        summary.opened_without_terminal += 1;
    }
    if (generation.legacy()) return;
    var invalid = generation.open_count > 1 or terminal_count > 1 or
        (generation.open_count == 0 and !start_bounded) or
        generation.generation_id == null or generation.goal_id == null or
        generation.identity_conflict;
    if (!validGenerationKind(generation.generation_kind)) invalid = true;
    if (try duplicateGenerationIdentity(generation, index, invalid_flags, indexes)) {
        invalid = true;
    }
    if (try invalidGenerationRelation(generation, index, invalid_flags, indexes, summary)) {
        invalid = true;
    }
    if (session_terminal and generation.open_count == 1 and terminal_count == 0) {
        summary.unclosed_terminal_v2_runs += 1;
        invalid = true;
    }
    if (invalid) invalid_flags[index] = true;
}

fn duplicateGenerationIdentity(
    generation: Generation,
    index: usize,
    invalid_flags: []bool,
    indexes: *GenerationIndexes,
) !bool {
    const generation_id = generation.generation_id orelse return false;
    if (indexes.generation_ids.get(generation_id)) |prior_index| {
        invalid_flags[prior_index] = true;
        return true;
    }
    try indexes.generation_ids.put(generation_id, index);
    return false;
}

fn invalidGenerationRelation(
    generation: Generation,
    index: usize,
    invalid_flags: []bool,
    indexes: *GenerationIndexes,
    summary: *Summary,
) !bool {
    if (std.mem.eql(u8, generation.generation_kind, "implementation")) {
        if (generation.predecessor_generation_id != null) return true;
        const goal_id = generation.goal_id orelse return false;
        if (indexes.goal_roots.get(goal_id)) |prior_index| {
            invalid_flags[prior_index] = true;
            return true;
        }
        try indexes.goal_roots.put(goal_id, index);
        return false;
    }
    const predecessor = generation.predecessor_generation_id orelse return true;
    if (indexes.predecessor_edges.get(predecessor)) |prior_index| {
        summary.duplicate_edges += 1;
        invalid_flags[prior_index] = true;
        return true;
    }
    try indexes.predecessor_edges.put(predecessor, index);
    return false;
}

fn projectGenerationState(
    allocator: std.mem.Allocator,
    generations: []Generation,
    generation: *Generation,
    index: usize,
    start_bounded: bool,
    invalid_flags: []bool,
    indexes: *GenerationIndexes,
) !void {
    try replaceOwned(allocator, &generation.lifecycle_status, lifecycleLabel(generation.*));
    if (generation.legacy()) return;
    try setLineage(allocator, generation, "v2-checked", "none");
    if (generation.identity_conflict) {
        try replaceOwned(allocator, &generation.lineage_status, "identity-conflict");
    } else if (generation.predecessor_generation_id) |predecessor| {
        try projectPredecessor(
            allocator,
            generations,
            generation,
            index,
            predecessor,
            invalid_flags,
            indexes,
        );
    }
    if (!invalid_flags[index] and generation.open_count == 0 and start_bounded) {
        try setLineage(
            allocator,
            generation,
            "generation-open-outside-window",
            "the generation open was not observed after the selected lower bound",
        );
    }
    if (invalid_flags[index] and std.mem.eql(u8, generation.lineage_status, "v2-checked")) {
        try replaceOwned(allocator, &generation.lineage_status, "invalid-v2");
    }
}

fn projectPredecessor(
    allocator: std.mem.Allocator,
    generations: []Generation,
    generation: *Generation,
    index: usize,
    predecessor: []const u8,
    invalid_flags: []bool,
    indexes: *GenerationIndexes,
) !void {
    const predecessor_index = indexes.generation_ids.get(predecessor) orelse {
        try setLineage(
            allocator,
            generation,
            "predecessor-outside-session",
            "predecessor may exist in another selected session; " ++
                "cross-session lineage was not joined",
        );
        return;
    };
    if (validPredecessor(generations[predecessor_index], generation.*)) return;
    const status = if (std.mem.eql(u8, generation.generation_kind, "recovery"))
        "invalid-predecessor-reservation"
    else
        "invalid-predecessor-terminal";
    try setLineage(allocator, generation, status, "none");
    invalid_flags[index] = true;
}

fn validPredecessor(predecessor: Generation, generation: Generation) bool {
    if (!optionalEql(predecessor.goal_id, generation.goal_id)) return false;
    if (std.mem.eql(u8, generation.generation_kind, "recovery")) {
        return predecessor.supersede_count == 1 and predecessor.close_count == 0 and
            optionalEql(
                predecessor.reserved_successor_generation_id,
                generation.generation_id,
            );
    }
    return predecessor.close_count == 1 and predecessor.supersede_count == 0 and
        predecessor.reserved_successor_generation_id == null;
}

fn lifecycleLabel(generation: Generation) []const u8 {
    if (generation.supersede_count > 0) return "superseded";
    if (generation.close_count > 0) return "closed";
    if (generation.open_count > 0 and generation.abort_count > 0) return "open-after-abort";
    if (generation.open_count > 0) return "open";
    return "observed-without-open";
}

fn setLineage(
    allocator: std.mem.Allocator,
    generation: *Generation,
    status: []const u8,
    uncertainty: []const u8,
) !void {
    try replaceOwned(allocator, &generation.lineage_status, status);
    try replaceOwned(allocator, &generation.uncertainty, uncertainty);
}

fn replaceOwned(
    allocator: std.mem.Allocator,
    current: *[]u8,
    replacement: []const u8,
) !void {
    allocator.free(current.*);
    current.* = try allocator.dupe(u8, replacement);
}

fn validGenerationKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "implementation") or
        std.mem.eql(u8, kind, "review-repair") or
        std.mem.eql(u8, kind, "terminal-proof") or
        std.mem.eql(u8, kind, "recovery");
}

fn jsonObjectEnd(text: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var index = start;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        if (byte == '"') {
            in_string = true;
        } else if (byte == '{') {
            depth += 1;
        } else if (byte == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return index + 1;
        }
    }
    return null;
}

fn optionalEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn valueObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn objectField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return valueObject(value);
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn intField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn dupOpt(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn freeOpt(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |text| allocator.free(text);
}

fn deinitRecords(allocator: std.mem.Allocator, records: *std.ArrayList(Record)) void {
    for (records.items) |*record| record.deinit(allocator);
    records.deinit(allocator);
}

fn deinitGenerations(allocator: std.mem.Allocator, generations: *std.ArrayList(Generation)) void {
    for (generations.items) |*generation| generation.deinit(allocator);
    generations.deinit(allocator);
}

const TransitionFixture = struct {
    schema: []const u8 = "actuation-transition-result/v1",
    command: []const u8,
    run_id: []const u8,
    goal_id: ?[]const u8 = null,
    generation_id: ?[]const u8 = null,
    generation_kind: ?[]const u8 = null,
    predecessor_generation_id: ?[]const u8 = null,
    reserved_successor_generation_id: ?[]const u8 = null,
    event_digest: ?[]const u8 = null,
    artifact_digest: ?[]const u8 = null,
};

const bootstrap_fixture_json =
    "{\"schema\":\"ledger-bootstrap-ready/v1\"," ++
    "\"status\":\"ready\",\"path\":\"/bin/ledger\",\"action\":\"none\"}";

fn appendTransitionFixture(
    trace: *canonical_trace.CanonicalSessionTrace,
    call_id: []const u8,
    shell_command: []const u8,
    fixture: TransitionFixture,
) !void {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try std.json.Stringify.value(fixture, .{}, &output.writer);
    try trace.tools.append(std.testing.allocator, try fixtureTool(
        std.testing.allocator,
        call_id,
        shell_command,
        output.written(),
    ));
}

fn appendEdgeFixture(
    trace: *canonical_trace.CanonicalSessionTrace,
    run_id: []const u8,
    command: []const u8,
    generation_id: []const u8,
    predecessor_generation_id: ?[]const u8,
) !void {
    const allocator = std.testing.allocator;
    const call_id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ run_id, command });
    defer allocator.free(call_id);
    const shell_command = try std.fmt.allocPrint(
        allocator,
        "ledger {s} --source actuation --run {s}",
        .{ command, run_id },
    );
    defer allocator.free(shell_command);
    try appendTransitionFixture(trace, call_id, shell_command, .{
        .command = command,
        .run_id = run_id,
        .goal_id = "goal-edges",
        .generation_id = generation_id,
        .generation_kind = if (predecessor_generation_id == null)
            "implementation"
        else
            "review-repair",
        .predecessor_generation_id = predecessor_generation_id,
    });
}

fn sessionRecord(path: []const u8) !canonical_trace.SessionRecord {
    return canonical_trace.SessionRecord.init(std.testing.allocator, path);
}

test "native audit joins exact actuation and bootstrap calls while ignoring pasted prose" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.session_id = try std.testing.allocator.dupe(u8, "session-native");
    trace.session.end_time = try std.testing.allocator.dupe(u8, "2026-07-16T00:01:00Z");
    try appendTransitionFixture(
        &trace,
        "call-open",
        "ledger open --source actuation --json open.json",
        .{
            .command = "open",
            .run_id = "run-1",
            .goal_id = "goal-1",
            .generation_id = "generation-1",
            .generation_kind = "implementation",
        },
    );
    try appendTransitionFixture(
        &trace,
        "call-close",
        "ledger close --source actuation --run run-1",
        .{
            .command = "close",
            .run_id = "run-1",
            .goal_id = "goal-1",
            .generation_id = "generation-1",
            .generation_kind = "implementation",
        },
    );
    try trace.tools.append(std.testing.allocator, try fixtureTool(
        std.testing.allocator,
        "call-bootstrap",
        "codex/skills/ledger/scripts/ensure-ledger",
        bootstrap_fixture_json,
    ));
    try appendTransitionFixture(
        &trace,
        "call-cat",
        "cat transcript.txt",
        .{ .command = "open", .run_id = "fake" },
    );
    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.summary.transition_results);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.represented_run_ids);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.bootstrap_invocations);
    try std.testing.expect(!analysis.strict_failure);

    const after_fixture = time_utils.parseIsoTimestampMillis("2026-07-16T00:00:01Z").?;
    var filtered = try analyzeTraceWithOptions(
        std.testing.allocator,
        trace,
        .{ .since_ms = after_fixture },
    );
    defer filtered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), filtered.summary.transition_results);
    try std.testing.expectEqual(@as(usize, 0), filtered.summary.bootstrap_invocations);
}

test "native audit joins custom tool calls to array-shaped raw outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        "{\"timestamp\":\"2026-07-16T00:00:00Z\",\"type\":\"response_item\"," ++
        "\"payload\":{\"type\":\"custom_tool_call\",\"call_id\":\"call-raw\"," ++
        "\"command\":\"ledger open --source actuation --json open.json\"}}\n" ++
        "{\"timestamp\":\"2026-07-16T00:00:01Z\",\"type\":\"response_item\"," ++
        "\"payload\":{\"type\":\"custom_tool_call_output\",\"call_id\":\"call-raw\"," ++
        "\"output\":[{\"type\":\"input_text\",\"text\":\"Script completed\"}," ++
        "{\"type\":\"input_text\",\"text\":\"{\\\"schema\\\":" ++
        "\\\"actuation-transition-result/v1\\\",\\\"command\\\":\\\"open\\\"," ++
        "\\\"run_id\\\":\\\"run-raw\\\",\\\"goal_id\\\":\\\"goal-raw\\\"," ++
        "\\\"generation_id\\\":\\\"generation-raw\\\"," ++
        "\\\"generation_kind\\\":\\\"implementation\\\"," ++
        "\\\"predecessor_generation_id\\\":null," ++
        "\\\"reserved_successor_generation_id\\\":null}\"}]}}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rollout-raw.jsonl", .data = source });
    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout-raw.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, path),
    };
    defer trace.deinit(std.testing.allocator);

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.transition_results);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.opens);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.represented_run_ids);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_joins);
    try std.testing.expectEqualStrings("run-raw", analysis.generations[0].run_id);
}

test "native audit parses direct write stdin chars from raw function arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        "{\"timestamp\":\"2026-07-16T00:00:00Z\",\"type\":\"response_item\"," ++
        "\"payload\":{\"type\":\"function_call\",\"call_id\":\"call-raw-stdin\"," ++
        "\"arguments\":\"{\\\"session_id\\\":7,\\\"chars\\\":\\\"ledger state " ++
        "--source actuation --run run-raw-stdin\\\\n\\\"}\"}}\n" ++
        "{\"timestamp\":\"2026-07-16T00:00:01Z\",\"type\":\"response_item\"," ++
        "\"payload\":{\"type\":\"function_call_output\"," ++
        "\"call_id\":\"call-raw-stdin\",\"output\":\"{\\\"schema\\\":" ++
        "\\\"actuation-transition-result/v1\\\",\\\"command\\\":\\\"state\\\"," ++
        "\\\"run_id\\\":\\\"run-raw-stdin\\\"}\"}}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rollout-stdin.jsonl", .data = source });
    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout-stdin.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, path),
    };
    defer trace.deinit(std.testing.allocator);

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.transition_results);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_joins);
}

test "native audit ignores pasted and echoed native JSON without a parsed invocation" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-pasted.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    const input =
        "const r = await tools.exec_command({" ++
        "cmd:\"printf '%s\\n' 'ledger close --source actuation'\"});";
    const output =
        "{\"schema\":\"actuation-transition-result/v1\"," ++
        "\"command\":\"close\",\"run_id\":\"pasted-run\"}";
    try trace.tools.append(
        std.testing.allocator,
        try fixtureJsTool(std.testing.allocator, "call-pasted", input, output),
    );

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.records.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_joins);
    try std.testing.expect(!analysis.strict_failure);
}

test "native audit parses dynamic command arrays and direct write stdin chars" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-js-carriers.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    const dynamic_input =
        "const cmds=[\"ledger close --source actuation --run run-dynamic\"];" ++
        "for(const cmd of cmds){await tools.exec_command({cmd,workdir:\"/tmp\"});}";
    const dynamic_output =
        "{\"schema\":\"actuation-transition-result/v1\"," ++
        "\"command\":\"close\",\"run_id\":\"run-dynamic\"}";
    try trace.tools.append(
        std.testing.allocator,
        try fixtureJsTool(
            std.testing.allocator,
            "call-dynamic",
            dynamic_input,
            dynamic_output,
        ),
    );
    const stdin_input =
        "const r=await tools.write_stdin({session_id:7," ++
        "chars:\"ledger state --source actuation --run run-stdin\\n\"});";
    const stdin_output =
        "{\"schema\":\"actuation-transition-result/v1\"," ++
        "\"command\":\"state\",\"run_id\":\"run-stdin\"}";
    try trace.tools.append(
        std.testing.allocator,
        try fixtureJsTool(
            std.testing.allocator,
            "call-stdin",
            stdin_input,
            stdin_output,
        ),
    );
    const subshell_input =
        "const r=await tools.exec_command({cmd:\"res=$(/opt/bin/ledger " ++
        "--source actuation --run run-subshell prepare)\\n\"});";
    const subshell_output =
        "{\"schema\":\"actuation-transition-result/v1\"," ++
        "\"command\":\"prepare\",\"run_id\":\"run-subshell\"}";
    try trace.tools.append(
        std.testing.allocator,
        try fixtureJsTool(
            std.testing.allocator,
            "call-subshell",
            subshell_input,
            subshell_output,
        ),
    );
    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), analysis.summary.transition_results);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_joins);
}

test "native audit resolves dynamic templates and concatenated run ids" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-js-expressions.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    const template_input =
        "const base=\"ledger --source actuation\";" ++
        "const run=\"run-template\";" ++
        "const r=await tools.exec_command({" ++
        "cmd:`${base} execute --run ${run} --capability ${cap}`});";
    const template_output =
        "{\"schema\":\"actuation-transition-result/v1\"," ++
        "\"command\":\"execute\",\"run_id\":\"run-template\"}";
    try trace.tools.append(
        std.testing.allocator,
        try fixtureJsTool(
            std.testing.allocator,
            "call-template",
            template_input,
            template_output,
        ),
    );
    const concatenated_input =
        "const run=\"run-concatenated\";" ++
        "const r=await tools.exec_command({" ++
        "cmd:\"ledger --source actuation prepare --run \"+run});";
    const concatenated_output =
        "{\"schema\":\"actuation-transition-result/v1\"," ++
        "\"command\":\"prepare\",\"run_id\":\"run-concatenated\"}";
    try trace.tools.append(
        std.testing.allocator,
        try fixtureJsTool(
            std.testing.allocator,
            "call-concatenated",
            concatenated_input,
            concatenated_output,
        ),
    );

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.summary.transition_results);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_joins);
}

test "native audit rejects an output command that mismatches the parsed invocation" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-mismatched-command.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    const output =
        "{\"schema\":\"actuation-transition-result/v1\"," ++
        "\"command\":\"close\",\"run_id\":\"run-mismatch\"}";
    try trace.tools.append(
        std.testing.allocator,
        try fixtureTool(
            std.testing.allocator,
            "call-mismatch",
            "ledger state --source actuation --run run-mismatch",
            output,
        ),
    );

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.transition_results);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.invalid_joins);
    try std.testing.expect(analysis.strict_failure);
}

test "native audit attributes errors only to one exact actuation invocation" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-error-attribution.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    const output = "{\"schema\":\"actuation-error/v1\",\"error\":\"InvalidPhase\"}";
    try trace.tools.append(
        std.testing.allocator,
        try fixtureTool(
            std.testing.allocator,
            "call-error-unique",
            "ledger state --source actuation --run run-error",
            output,
        ),
    );
    try trace.tools.append(
        std.testing.allocator,
        try fixtureTool(
            std.testing.allocator,
            "call-error-ambiguous",
            "ledger state --source actuation --run run-error\n" ++
                "ledger close --source actuation --run run-error",
            output,
        ),
    );

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.errors);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.invalid_joins);
    try std.testing.expect(analysis.strict_failure);
}

test "native audit requires exact post-open and decision run ids" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-run-joins.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    try trace.tools.append(
        std.testing.allocator,
        try fixtureTool(
            std.testing.allocator,
            "call-generated-open",
            "ledger open --source actuation --json open.json",
            "{\"schema\":\"actuation-transition-result/v1\"," ++
                "\"command\":\"open\",\"run_id\":\"run-generated\"}",
        ),
    );
    try trace.tools.append(
        std.testing.allocator,
        try fixtureTool(
            std.testing.allocator,
            "call-missing-run",
            "ledger state --source actuation",
            "{\"schema\":\"actuation-transition-result/v1\"," ++
                "\"command\":\"state\",\"run_id\":\"run-generated\"}",
        ),
    );
    try trace.tools.append(
        std.testing.allocator,
        try fixtureTool(
            std.testing.allocator,
            "call-wrong-run",
            "ledger state --source actuation --run run-other",
            "{\"schema\":\"actuation-transition-result/v1\"," ++
                "\"command\":\"state\",\"run_id\":\"run-generated\"}",
        ),
    );
    const decision_output =
        "{\"closure_decision\":{\"version\":\"closure-decision/v1\"," ++
        "\"run_id\":\"run-generated\",\"decision_id\":\"decision-1\"," ++
        "\"verdict\":\"complete\"}}";
    try trace.tools.append(
        std.testing.allocator,
        try fixtureTool(
            std.testing.allocator,
            "call-decision-missing-run",
            "ledger decide --source actuation",
            decision_output,
        ),
    );

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.transition_results);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.closure_decision_rows);
    try std.testing.expectEqual(@as(usize, 3), analysis.summary.invalid_joins);
    try std.testing.expect(analysis.strict_failure);
}

test "native audit resolves literal shell run bindings before exact join" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-shell-run.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    try trace.tools.append(
        std.testing.allocator,
        try fixtureTool(
            std.testing.allocator,
            "call-shell-run",
            "set -e\nrun='run-shell'\n" ++
                "ledger state --source actuation --run \"$run\"",
            "{\"schema\":\"actuation-transition-result/v1\"," ++
                "\"command\":\"state\",\"run_id\":\"run-shell\"}",
        ),
    );
    try trace.tools.append(
        std.testing.allocator,
        try fixtureTool(
            std.testing.allocator,
            "call-shell-continuation",
            "ledger prepare --source actuation \\\n  --run run-continuation",
            "{\"schema\":\"actuation-transition-result/v1\"," ++
                "\"command\":\"prepare\",\"run_id\":\"run-continuation\"}",
        ),
    );

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.summary.transition_results);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_joins);
}

test "native audit ignores a raw native result without an originating call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        "{\"timestamp\":\"2026-07-16T00:00:01Z\",\"type\":\"response_item\"," ++
        "\"payload\":{\"type\":\"custom_tool_call_output\"," ++
        "\"call_id\":\"call-orphan\",\"output\":[{\"type\":\"input_text\"," ++
        "\"text\":\"{\\\"schema\\\":\\\"actuation-transition-result/v1\\\"," ++
        "\\\"command\\\":\\\"close\\\",\\\"run_id\\\":\\\"run-orphan\\\"}\"}]}}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rollout-orphan.jsonl", .data = source });
    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout-orphan.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, path),
    };
    defer trace.deinit(std.testing.allocator);

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.transition_results);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_joins);
    try std.testing.expect(!analysis.strict_failure);

    const after_orphan = time_utils.parseIsoTimestampMillis("2026-07-16T00:00:02Z").?;
    var filtered = try analyzeTraceWithOptions(
        std.testing.allocator,
        trace,
        .{ .since_ms = after_orphan },
    );
    defer filtered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), filtered.summary.invalid_joins);
    try std.testing.expect(!filtered.strict_failure);
}

test "native audit keeps operation abort nonterminal and accepts a closed ordinary successor" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-successor.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.session_id = try std.testing.allocator.dupe(u8, "session-successor");
    trace.session.end_time = try std.testing.allocator.dupe(u8, "2026-07-16T00:01:00Z");
    try appendEdgeFixture(&trace, "run-root", "open", "generation-root", null);
    try appendEdgeFixture(&trace, "run-root", "close", "generation-root", null);
    try appendEdgeFixture(
        &trace,
        "run-repair",
        "open",
        "generation-repair",
        "generation-root",
    );
    try appendEdgeFixture(
        &trace,
        "run-repair",
        "abort",
        "generation-repair",
        "generation-root",
    );
    try appendEdgeFixture(
        &trace,
        "run-repair",
        "close",
        "generation-repair",
        "generation-root",
    );
    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.summary.represented_run_ids);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.aborts);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_v2_lineages);
    try std.testing.expectEqualStrings("closed", analysis.generations[1].lifecycle_status);
    try std.testing.expect(!analysis.strict_failure);
}

test "native audit ignores bootstrap-shaped output without an exact invocation" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-bootstrap.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.session_id = try std.testing.allocator.dupe(u8, "session-bootstrap");
    try trace.tools.append(std.testing.allocator, try fixtureTool(
        std.testing.allocator,
        "call-search",
        "rg ensure-ledger codex/skills",
        bootstrap_fixture_json,
    ));
    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.bootstrap_invocations);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_joins);
    try std.testing.expect(!analysis.strict_failure);
}

test "native command parsing accepts JSON-quoted property names" {
    const command = try jsStringPropertyAlloc(
        std.testing.allocator,
        "",
        "{\"cmd\":\"/opt/skills/ensure-ledger && ledger --version\"}",
        "cmd",
    );
    defer if (command) |value| std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("/opt/skills/ensure-ledger && ledger --version", command.?);
}

test "native audit accepts only a reserved recovery successor after supersede" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-recovery.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.session_id = try std.testing.allocator.dupe(u8, "session-recovery");
    trace.session.end_time = try std.testing.allocator.dupe(u8, "2026-07-16T00:01:00Z");
    try appendTransitionFixture(
        &trace,
        "call-root-open",
        "ledger open --source actuation --json root.json",
        .{
            .command = "open",
            .run_id = "run-root",
            .goal_id = "goal-2",
            .generation_id = "generation-root",
            .generation_kind = "implementation",
        },
    );
    try appendTransitionFixture(
        &trace,
        "call-root-supersede",
        "ledger supersede --source actuation --run run-root --json supersede.json",
        .{
            .command = "supersede",
            .run_id = "run-root",
            .goal_id = "goal-2",
            .generation_id = "generation-root",
            .generation_kind = "implementation",
            .reserved_successor_generation_id = "generation-recovery",
        },
    );
    try appendTransitionFixture(
        &trace,
        "call-recovery-open",
        "ledger open --source actuation --json recovery.json",
        .{
            .command = "open",
            .run_id = "run-recovery",
            .goal_id = "goal-2",
            .generation_id = "generation-recovery",
            .generation_kind = "recovery",
            .predecessor_generation_id = "generation-root",
        },
    );
    try appendTransitionFixture(
        &trace,
        "call-recovery-close",
        "ledger close --source actuation --run run-recovery",
        .{
            .command = "close",
            .run_id = "run-recovery",
            .goal_id = "goal-2",
            .generation_id = "generation-recovery",
            .generation_kind = "recovery",
            .predecessor_generation_id = "generation-root",
        },
    );
    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_v2_lineages);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.duplicate_edges);
    try std.testing.expect(!analysis.strict_failure);
}

test "native audit treats a generation open before the lower bound as uncertainty" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-open-outside-window.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.end_time = try std.testing.allocator.dupe(u8, "2026-07-16T00:01:00Z");
    try appendTransitionFixture(
        &trace,
        "call-close-inside-window",
        "ledger close --source actuation --run run-window",
        .{
            .command = "close",
            .run_id = "run-window",
            .goal_id = "goal-window",
            .generation_id = "generation-window",
            .generation_kind = "implementation",
        },
    );

    const since = time_utils.parseIsoTimestampMillis("2026-07-15T00:00:00Z").?;
    var bounded = try analyzeTraceWithOptions(
        std.testing.allocator,
        trace,
        .{ .since_ms = since },
    );
    defer bounded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), bounded.summary.invalid_v2_lineages);
    try std.testing.expectEqualStrings(
        "generation-open-outside-window",
        bounded.generations[0].lineage_status,
    );
    try std.testing.expect(!bounded.strict_failure);

    var unbounded = try analyzeTrace(std.testing.allocator, trace);
    defer unbounded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), unbounded.summary.invalid_v2_lineages);
    try std.testing.expect(unbounded.strict_failure);
}

test "native audit rejects conflicting identity for one run" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-conflict.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.end_time = try std.testing.allocator.dupe(u8, "2026-07-16T00:01:00Z");
    try appendTransitionFixture(
        &trace,
        "call-open",
        "ledger open --source actuation --json open.json",
        .{
            .command = "open",
            .run_id = "run-conflict",
            .goal_id = "goal-conflict",
            .generation_id = "generation-original",
            .generation_kind = "implementation",
        },
    );
    try appendTransitionFixture(
        &trace,
        "call-close",
        "ledger close --source actuation --run run-conflict",
        .{
            .command = "close",
            .run_id = "run-conflict",
            .goal_id = "goal-conflict",
            .generation_id = "generation-tampered",
            .generation_kind = "implementation",
        },
    );
    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.invalid_v2_lineages);
    try std.testing.expectEqualStrings("identity-conflict", analysis.generations[0].lineage_status);
    try std.testing.expect(analysis.strict_failure);
}

test "native audit rejects duplicate roots and terminal unclosed generations" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-roots.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.end_time = try std.testing.allocator.dupe(u8, "2026-07-16T00:01:00Z");
    try appendTransitionFixture(
        &trace,
        "call-root-a-open",
        "ledger open --source actuation --json root-a.json",
        .{
            .command = "open",
            .run_id = "root-a",
            .goal_id = "goal-roots",
            .generation_id = "generation-root-a",
            .generation_kind = "implementation",
        },
    );
    try appendTransitionFixture(
        &trace,
        "call-root-a-close",
        "ledger close --source actuation --run root-a",
        .{
            .command = "close",
            .run_id = "root-a",
            .goal_id = "goal-roots",
            .generation_id = "generation-root-a",
            .generation_kind = "implementation",
        },
    );
    try appendTransitionFixture(
        &trace,
        "call-root-b-open",
        "ledger open --source actuation --json root-b.json",
        .{
            .command = "open",
            .run_id = "root-b",
            .goal_id = "goal-roots",
            .generation_id = "generation-root-b",
            .generation_kind = "implementation",
        },
    );
    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.summary.invalid_v2_lineages);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.unclosed_terminal_v2_runs);
    try std.testing.expect(analysis.strict_failure);
}

test "native audit does not treat an ongoing session as terminal" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-ongoing.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.is_ongoing = true;
    trace.session.end_time = try std.testing.allocator.dupe(u8, "2026-07-16T00:01:00Z");
    try appendTransitionFixture(
        &trace,
        "call-ongoing-open",
        "ledger open --source actuation --json ongoing.json",
        .{
            .command = "open",
            .run_id = "run-ongoing",
            .goal_id = "goal-ongoing",
            .generation_id = "generation-ongoing",
            .generation_kind = "implementation",
        },
    );

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.opened_without_terminal);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.unclosed_terminal_v2_runs);
    try std.testing.expect(!analysis.strict_failure);
}

test "native audit treats an upper-window truncation as nonterminal" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-upper-window.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.end_time = try std.testing.allocator.dupe(u8, "2026-07-16T00:02:00Z");
    try appendTransitionFixture(
        &trace,
        "call-window-open",
        "ledger open --source actuation --json window.json",
        .{
            .command = "open",
            .run_id = "run-upper-window",
            .goal_id = "goal-upper-window",
            .generation_id = "generation-upper-window",
            .generation_kind = "implementation",
        },
    );
    const until = time_utils.parseIsoTimestampMillis("2026-07-16T00:01:00Z").?;
    var bounded = try analyzeTraceWithOptions(
        std.testing.allocator,
        trace,
        .{ .until_ms = until },
    );
    defer bounded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), bounded.summary.unclosed_terminal_v2_runs);
    try std.testing.expect(!bounded.strict_failure);

    var unbounded = try analyzeTrace(std.testing.allocator, trace);
    defer unbounded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), unbounded.summary.unclosed_terminal_v2_runs);
    try std.testing.expect(unbounded.strict_failure);
}

test "native audit marks an unjoined cross-session predecessor as uncertainty" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-cross-session.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.end_time = try std.testing.allocator.dupe(u8, "2026-07-16T00:01:00Z");
    try appendEdgeFixture(
        &trace,
        "run-cross-session",
        "open",
        "generation-cross-session",
        "generation-in-another-session",
    );
    try appendEdgeFixture(
        &trace,
        "run-cross-session",
        "close",
        "generation-cross-session",
        "generation-in-another-session",
    );

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "predecessor-outside-session",
        analysis.generations[0].lineage_status,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        analysis.generations[0].uncertainty,
        "cross-session lineage was not joined",
    ) != null);
    try std.testing.expectEqual(@as(usize, 0), analysis.summary.invalid_v2_lineages);
    try std.testing.expect(!analysis.strict_failure);
}

test "native audit rejects duplicate successor edges" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-edges.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    trace.session.end_time = try std.testing.allocator.dupe(u8, "2026-07-16T00:01:00Z");
    try appendEdgeFixture(&trace, "root", "open", "generation-root", null);
    try appendEdgeFixture(&trace, "root", "close", "generation-root", null);
    try appendEdgeFixture(
        &trace,
        "repair-a",
        "open",
        "generation-repair-a",
        "generation-root",
    );
    try appendEdgeFixture(
        &trace,
        "repair-a",
        "close",
        "generation-repair-a",
        "generation-root",
    );
    try appendEdgeFixture(
        &trace,
        "repair-b",
        "open",
        "generation-repair-b",
        "generation-root",
    );
    try appendEdgeFixture(
        &trace,
        "repair-b",
        "close",
        "generation-repair-b",
        "generation-root",
    );
    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.duplicate_edges);
    try std.testing.expectEqual(@as(usize, 2), analysis.summary.invalid_v2_lineages);
    try std.testing.expect(analysis.strict_failure);
}

test "native audit reports session bootstrap invocations without inferring workflow identity" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-bootstraps.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    for ([_][]const u8{ "bootstrap-a", "bootstrap-b" }) |call_id| {
        try trace.tools.append(std.testing.allocator, try fixtureTool(
            std.testing.allocator,
            call_id,
            "codex/skills/ledger/scripts/ensure-ledger",
            bootstrap_fixture_json,
        ));
    }
    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.summary.bootstrap_invocations);
    try std.testing.expect(!analysis.strict_failure);
}

test "native audit counts bootstrap invocations rather than repeated output rows" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try sessionRecord("/tmp/native-bootstrap-output.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    const repeated_output = bootstrap_fixture_json ++ "\n" ++ bootstrap_fixture_json;
    try trace.tools.append(
        std.testing.allocator,
        try fixtureTool(
            std.testing.allocator,
            "bootstrap-repeated-output",
            "codex/skills/ledger/scripts/ensure-ledger",
            repeated_output,
        ),
    );

    var analysis = try analyzeTrace(std.testing.allocator, trace);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), analysis.summary.bootstrap_invocations);
    try std.testing.expectEqual(@as(usize, 1), analysis.records.len);
}

fn fixtureTool(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    command: []const u8,
    tool_output: []const u8,
) !canonical_trace.ToolLifecycleRecord {
    return .{
        .path = try allocator.dupe(u8, "/tmp/native.jsonl"),
        .call_id = try allocator.dupe(u8, call_id),
        .command_text = try allocator.dupe(u8, command),
        .output_text = try allocator.dupe(u8, tool_output),
        .completed_at = try allocator.dupe(u8, "2026-07-16T00:00:00Z"),
        .lifecycle_status = .completed,
    };
}

fn fixtureJsTool(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    input: []const u8,
    tool_output: []const u8,
) !canonical_trace.ToolLifecycleRecord {
    return .{
        .path = try allocator.dupe(u8, "/tmp/native.jsonl"),
        .call_id = try allocator.dupe(u8, call_id),
        .input_text = try allocator.dupe(u8, input),
        .output_text = try allocator.dupe(u8, tool_output),
        .completed_at = try allocator.dupe(u8, "2026-07-16T00:00:00Z"),
        .lifecycle_status = .completed,
    };
}
