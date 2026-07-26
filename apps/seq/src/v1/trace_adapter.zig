const std = @import("std");
const trace_core = @import("trace_core");
const execution = @import("execution.zig");
const physical = @import("physical.zig");

pub const Options = struct {
    ongoing_threshold_secs: i64 = 60,
};

pub const Observation = struct {
    trace: trace_core.CanonicalSessionTrace,
    result: execution.Result,
    metrics: trace_core.StreamMetrics,

    pub fn deinit(self: *Observation, allocator: std.mem.Allocator) void {
        self.trace.deinit(allocator);
        self.* = undefined;
    }
};

pub fn observeFile(
    allocator: std.mem.Allocator,
    program: *const execution.Program,
    path: []const u8,
    options: Options,
    output: []execution.Value,
) !Observation {
    const relation = switch (program.source) {
        .physical => |value| value,
        .external => return error.ObservationRequiresExternalInput,
    };
    if (!supported(relation)) return error.UnsupportedTracePhysicalRelation;

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var reader = file.reader(io, &.{});
    var metrics = trace_core.StreamMetrics{};
    const parse_options = traceParseOptions(
        relation,
        program.source_field_indices,
        options,
    );
    var trace = if (relation == .sessions)
        try trace_core.parseSessionSummaryTraceReaderWithVisitorMetrics(
            allocator,
            path,
            &reader.interface,
            stat.mtime.nanoseconds,
            parse_options,
            {},
            ignoreLine,
            &metrics,
        )
    else
        try trace_core.parseSessionTraceReaderWithVisitorMetrics(
            allocator,
            path,
            &reader.interface,
            stat.mtime.nanoseconds,
            parse_options,
            {},
            ignoreLine,
            &metrics,
        );
    errdefer trace.deinit(allocator);

    return .{
        .trace = trace,
        .result = try observeTrace(program, &trace, output),
        .metrics = metrics,
    };
}

pub fn observeTrace(
    program: *const execution.Program,
    trace: *const trace_core.CanonicalSessionTrace,
    output: []execution.Value,
) !execution.Result {
    const relation = switch (program.source) {
        .physical => |value| value,
        .external => return error.ObservationRequiresExternalInput,
    };
    var runner = try execution.Runner.init(program, output);
    var row: [256]execution.Value = undefined;

    switch (relation) {
        .sessions => {
            try fillSession(
                row[0..program.source_width],
                program.source_field_indices,
                trace.session,
            );
            _ = try runner.feed(row[0..program.source_width]);
        },
        .source_events => for (trace.occurrences.items) |*occurrence| {
            try fillSourceEvent(
                row[0..program.source_width],
                program.source_field_indices,
                trace.session,
                occurrence,
            );
            if (try runner.feed(row[0..program.source_width]) == .stop) break;
        },
        .turns => for (trace.turns.items) |turn| {
            try fillTurn(
                row[0..program.source_width],
                program.source_field_indices,
                turn,
            );
            if (try runner.feed(row[0..program.source_width]) == .stop) break;
        },
        .messages => for (trace.occurrences.items) |*occurrence| {
            if (occurrence.role == null or occurrence.text == null) continue;
            try fillMessage(
                row[0..program.source_width],
                program.source_field_indices,
                trace.session,
                occurrence,
            );
            if (try runner.feed(row[0..program.source_width]) == .stop) break;
        },
        .tool_invocations => for (trace.tools.items) |tool| {
            if (tool.declared_line == null) continue;
            const occurrence = if (containsField(
                program.source_field_indices,
                12,
            ))
                occurrenceAtLine(trace, tool.declared_line.?)
            else
                null;
            try fillToolInvocation(
                row[0..program.source_width],
                program.source_field_indices,
                tool,
                occurrence,
            );
            if (try runner.feed(row[0..program.source_width]) == .stop) break;
        },
        .tool_results => for (trace.tools.items) |tool| {
            if (tool.finalized_line == null) continue;
            const occurrence = if (containsField(
                program.source_field_indices,
                10,
            ))
                occurrenceAtLine(trace, tool.finalized_line.?)
            else
                null;
            try fillToolResult(
                row[0..program.source_width],
                program.source_field_indices,
                tool,
                occurrence,
            );
            if (try runner.feed(row[0..program.source_width]) == .stop) break;
        },
        .tool_lifecycle => for (trace.tools.items) |tool| {
            try fillToolLifecycle(
                row[0..program.source_width],
                program.source_field_indices,
                tool,
            );
            if (try runner.feed(row[0..program.source_width]) == .stop) break;
        },
        .session_edges => for (trace.graph_edges.items) |edge| {
            try fillSessionEdge(
                row[0..program.source_width],
                program.source_field_indices,
                edge,
            );
            if (try runner.feed(row[0..program.source_width]) == .stop) break;
        },
        .token_events => for (trace.token_events.items) |event| {
            if (event.occurrence_index >= trace.occurrences.items.len) {
                return error.TokenEventOccurrenceMissing;
            }
            try fillTokenEvent(
                row[0..program.source_width],
                program.source_field_indices,
                trace.session,
                &trace.occurrences.items[event.occurrence_index],
                event,
            );
            if (try runner.feed(row[0..program.source_width]) == .stop) break;
        },
        .structured_documents,
        .structured_values,
        => return error.UnsupportedTracePhysicalRelation,
    }
    return runner.result();
}

fn supported(relation: physical.Relation) bool {
    return switch (relation) {
        .sessions,
        .source_events,
        .turns,
        .messages,
        .tool_invocations,
        .tool_results,
        .tool_lifecycle,
        .session_edges,
        .token_events,
        => true,
        .structured_documents,
        .structured_values,
        => false,
    };
}

fn traceParseOptions(
    relation: physical.Relation,
    demanded_fields: []const u16,
    options: Options,
) trace_core.TraceParseOptions {
    return .{
        .ongoing_threshold_secs = options.ongoing_threshold_secs,
        .include_raw = relation == .source_events and
            containsField(demanded_fields, 8),
        .include_occurrences = relation == .source_events or
            relation == .messages or
            relation == .token_events or
            (relation == .tool_invocations and
                containsField(demanded_fields, 12)) or
            (relation == .tool_results and
                containsField(demanded_fields, 10)),
        .include_token_events = relation == .token_events,
        .include_message_bodies = relation == .turns and
            (containsField(demanded_fields, 9) or
                containsField(demanded_fields, 10)),
    };
}

fn containsField(fields: []const u16, wanted: u16) bool {
    for (fields) |field| if (field == wanted) return true;
    return false;
}

fn ignoreLine(_: void, _: []const u8, _: usize) !void {}

fn fillSourceEvent(
    row: []execution.Value,
    fields: []const u16,
    session: trace_core.SessionRecord,
    occurrence: *const trace_core.TraceOccurrence,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = occurrence.sourceEventId() },
            1 => optionalString(session.session_id),
            2 => .{ .string = session.path },
            3 => try usizeInteger(occurrence.line_number),
            4 => .{ .string = occurrence.entry_type },
            5 => optionalString(occurrence.event_type),
            6 => optionalString(occurrence.timestamp),
            7 => optionalJson(occurrence.payload_json),
            8 => optionalJson(occurrence.raw_json),
            9 => .{ .string = @tagName(occurrence.format) },
            10 => optionalInteger(occurrence.turn_index),
            11 => optionalString(occurrence.role),
            12 => optionalString(occurrence.text),
            13 => .{ .boolean = occurrence.private },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillSession(
    row: []execution.Value,
    fields: []const u16,
    session: trace_core.SessionRecord,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(session.session_id),
            1 => .{ .string = session.path },
            2 => optionalString(session.start_time),
            3 => optionalString(session.end_time),
            4 => optionalString(session.cwd),
            5 => optionalString(session.git_branch),
            6 => optionalString(session.git_commit_hash),
            7 => optionalString(session.git_repository_url),
            8 => optionalString(session.originator),
            9 => optionalString(session.cli_version),
            10 => optionalString(session.model),
            11 => optionalString(session.model_provider),
            12 => optionalString(session.thread_name),
            13 => .{ .integer = session.turn_count },
            14 => optionalInteger(session.total_tokens),
            15 => optionalInteger(session.input_tokens),
            16 => optionalInteger(session.cached_input_tokens),
            17 => optionalInteger(session.output_tokens),
            18 => optionalInteger(session.reasoning_output_tokens),
            19 => .{ .boolean = session.is_ongoing },
            20 => optionalString(session.status_reason),
            21 => .{ .boolean = session.is_external_worker },
            22 => .{ .boolean = session.is_inline_worker },
            23 => .{ .integer = session.spawned_worker_count },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillMessage(
    row: []execution.Value,
    fields: []const u16,
    session: trace_core.SessionRecord,
    occurrence: *const trace_core.TraceOccurrence,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => .{ .string = occurrence.sourceEventId() },
            1 => optionalString(session.session_id),
            2 => optionalInteger(occurrence.turn_index),
            3 => optionalString(occurrence.role),
            4 => optionalString(occurrence.text),
            5 => optionalString(occurrence.timestamp),
            6 => .{ .string = occurrence.sourceEventId() },
            7 => .{ .string = session.path },
            8 => .{ .boolean = occurrence.private },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillTurn(
    row: []execution.Value,
    fields: []const u16,
    turn: trace_core.TurnRecord,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(turn.session_id),
            1 => .{ .string = turn.path },
            2 => .{ .string = turn.turn_id },
            3 => .{ .integer = turn.turn_index },
            4 => optionalString(turn.started_at),
            5 => optionalString(turn.completed_at),
            6 => optionalInteger(turn.duration_ms),
            7 => .{ .string = @tagName(turn.status) },
            8 => optionalString(turn.status_reason),
            9 => optionalString(turn.user_message),
            10 => optionalString(turn.final_answer),
            11 => optionalString(turn.model),
            12 => optionalString(turn.cwd),
            13 => optionalString(turn.reasoning_effort),
            14 => optionalInteger(turn.input_tokens),
            15 => optionalInteger(turn.cached_input_tokens),
            16 => optionalInteger(turn.output_tokens),
            17 => optionalInteger(turn.reasoning_output_tokens),
            18 => optionalInteger(turn.total_tokens),
            19 => .{ .integer = turn.tool_count },
            20 => .{ .boolean = turn.has_compaction },
            21 => optionalString(turn.thread_name),
            22 => optionalString(turn.@"error"),
            23 => optionalString(turn.aborted_reason),
            24 => .{ .integer = turn.spawned_worker_count },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillToolInvocation(
    row: []execution.Value,
    fields: []const u16,
    tool: trace_core.ToolLifecycleRecord,
    occurrence: ?*const trace_core.TraceOccurrence,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(tool.call_id),
            1 => optionalString(tool.session_id),
            2 => optionalString(tool.turn_id),
            3 => optionalInteger(tool.turn_index),
            4 => optionalString(tool.started_at),
            5 => .{ .string = @tagName(tool.kind) },
            6 => optionalString(tool.tool_name),
            7 => optionalString(tool.namespace),
            8 => optionalJson(tool.arguments_json),
            9 => optionalString(tool.input_text),
            10 => optionalString(tool.command_text),
            11 => optionalString(tool.cwd),
            12 => if (occurrence) |value|
                .{ .string = value.sourceEventId() }
            else
                .null,
            13 => .{ .string = tool.path },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillToolResult(
    row: []execution.Value,
    fields: []const u16,
    tool: trace_core.ToolLifecycleRecord,
    occurrence: ?*const trace_core.TraceOccurrence,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(tool.call_id),
            1 => optionalString(tool.session_id),
            2 => optionalString(tool.turn_id),
            3 => optionalInteger(tool.turn_index),
            4 => optionalString(tool.completed_at),
            5 => optionalString(tool.output_text),
            6 => optionalInteger(tool.exit_code),
            7 => optionalInteger(tool.duration_ms),
            8 => optionalBoolean(tool.patch_success),
            9 => optionalJson(tool.patch_changes_json),
            10 => if (occurrence) |value|
                .{ .string = value.sourceEventId() }
            else
                .null,
            11 => .{ .string = tool.path },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillToolLifecycle(
    row: []execution.Value,
    fields: []const u16,
    tool: trace_core.ToolLifecycleRecord,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(tool.call_id),
            1 => optionalString(tool.session_id),
            2 => optionalString(tool.turn_id),
            3 => optionalInteger(tool.turn_index),
            4 => optionalString(tool.started_at),
            5 => optionalString(tool.completed_at),
            6 => .{ .string = @tagName(tool.kind) },
            7 => optionalString(tool.tool_name),
            8 => optionalString(tool.namespace),
            9 => optionalJson(tool.arguments_json),
            10 => optionalString(tool.input_text),
            11 => optionalString(tool.output_text),
            12 => optionalString(tool.command_text),
            13 => optionalString(tool.cwd),
            14 => optionalInteger(tool.exit_code),
            15 => optionalInteger(tool.duration_ms),
            16 => .{ .string = @tagName(tool.lifecycle_status) },
            17 => optionalInteger(tool.declared_line),
            18 => optionalInteger(tool.finalized_line),
            19 => .{ .string = tool.path },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillSessionEdge(
    row: []execution.Value,
    fields: []const u16,
    edge: trace_core.SessionGraphEdge,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(edge.parent_session_id),
            1 => optionalString(edge.worker_session_id),
            2 => .{ .string = edge.parent_path },
            3 => optionalString(edge.worker_path),
            4 => optionalString(edge.call_id),
            5 => optionalString(edge.agent_nickname),
            6 => optionalString(edge.agent_role),
            7 => optionalString(edge.model),
            8 => optionalString(edge.reasoning_effort),
            9 => optionalString(edge.spawned_at),
            10 => optionalString(edge.worker_status),
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn fillTokenEvent(
    row: []execution.Value,
    fields: []const u16,
    session: trace_core.SessionRecord,
    occurrence: *const trace_core.TraceOccurrence,
    event: trace_core.TokenEventRecord,
) !void {
    for (fields, 0..) |field, index| {
        row[index] = switch (field) {
            0 => optionalString(session.session_id),
            1 => .{ .integer = event.turn_index },
            2 => optionalString(occurrence.timestamp),
            3 => optionalInteger(event.input_tokens),
            4 => optionalInteger(event.cached_input_tokens),
            5 => optionalInteger(event.output_tokens),
            6 => optionalInteger(event.reasoning_output_tokens),
            7 => optionalInteger(event.total_tokens),
            8 => .{ .string = occurrence.sourceEventId() },
            9 => .{ .string = session.path },
            else => return error.InvalidTracePhysicalFieldIndex,
        };
    }
}

fn occurrenceAtLine(
    trace: *const trace_core.CanonicalSessionTrace,
    line_number: i64,
) ?*const trace_core.TraceOccurrence {
    const wanted = std.math.cast(usize, line_number) orelse return null;
    var low: usize = 0;
    var high = trace.occurrences.items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = &trace.occurrences.items[middle];
        if (candidate.line_number < wanted) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low == trace.occurrences.items.len or
        trace.occurrences.items[low].line_number != wanted)
    {
        return null;
    }
    return &trace.occurrences.items[low];
}

fn optionalString(value: ?[]const u8) execution.Value {
    return if (value) |text| .{ .string = text } else .null;
}

fn optionalJson(value: ?[]const u8) execution.Value {
    return if (value) |json| .{ .json = json } else .null;
}

fn optionalInteger(value: ?i64) execution.Value {
    return if (value) |number| .{ .integer = number } else .null;
}

fn optionalBoolean(value: ?bool) execution.Value {
    return if (value) |flag| .{ .boolean = flag } else .null;
}

fn usizeInteger(value: usize) !execution.Value {
    return .{
        .integer = std.math.cast(i64, value) orelse
            return error.TraceIntegerOverflow,
    };
}

test "trace adapter scans demanded session columns in one file pass" {
    const definition_core = @import("definition_core");
    const definition = @import("definition.zig");
    const plan = @import("plan.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/sessions","requires":{"abi":"seq-observation-abi/v1","operators":["scan","filter","project"]},"parameters":{},"selectors":["path"],"relations":[{"name":"sessions","fields":["session_id","path","model","turn_count"]}],"inputs":[],"pipeline":[{"op":"scan","relation":"sessions","as":"source"},{"op":"filter","input":"source","as":"matched","where":[{"field":"model","op":"exact","value":"gpt-test"}]},{"op":"project","input":"matched","as":"rows","fields":["session_id","turn_count"]}],"projections":{"rows":{"relation":"rows","schema":"example-session-rows/v1","fields":["session_id","turn_count"],"renderers":["json"]}},"bounds":{"max_rows":10,"max_output_bytes":4096,"max_fold_states":2}}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "rollout.jsonl",
        .data =
        \\{"timestamp":"2026-07-26T10:00:00Z","type":"session_meta","payload":{"id":"session-1","model":"gpt-test","cwd":"/repo"}}
        \\{"timestamp":"2026-07-26T10:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        \\{"timestamp":"2026-07-26T10:00:02Z","type":"event_msg","payload":{"type":"agent_message","message":"observed"}}
        \\{"timestamp":"2026-07-26T10:00:03Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
        \\
        ,
    });
    var closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "observation.json",
        .{},
    );
    defer closure.deinit(std.testing.allocator);
    var definition_plan = try definition.compile(
        std.testing.allocator,
        &closure,
        "observation.json",
    );
    defer definition_plan.deinit(std.testing.allocator);
    var native_plan = try plan.compile(
        std.testing.allocator,
        &definition_plan,
    );
    defer native_plan.deinit(std.testing.allocator);
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &definition_plan.parameter_declarations,
        &.{},
    );
    defer bindings.deinit(std.testing.allocator);
    var program = try execution.compile(
        std.testing.allocator,
        &definition_plan,
        &native_plan,
        &bindings,
        "rows",
    );
    defer program.deinit(std.testing.allocator);

    const path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(path);
    var output: [2]execution.Value = undefined;
    var observation = try observeFile(
        std.testing.allocator,
        &program,
        path,
        .{ .ongoing_threshold_secs = 0 },
        &output,
    );
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), observation.metrics.lines_seen);
    try std.testing.expectEqual(@as(usize, 1), observation.result.row_count);
    try std.testing.expectEqualStrings(
        "session-1",
        observation.result.rows().row(0)[0].string,
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        observation.result.rows().row(0)[1].integer,
    );

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "events.json",
        .data =
        \\{"schema":"seq-observation-definition/v1","id":"example/events","requires":{"abi":"seq-observation-abi/v1","operators":["scan","filter","project"]},"parameters":{},"selectors":["path"],"relations":[{"name":"source_events","fields":["source_event_id","event_type","role","text","raw_json","turn_index"]}],"inputs":[],"pipeline":[{"op":"scan","relation":"source_events","as":"source"},{"op":"filter","input":"source","as":"matched","where":[{"field":"event_type","op":"exact","value":"agent_message"}]},{"op":"project","input":"matched","as":"rows","fields":["source_event_id","role","text","raw_json","turn_index"]}],"projections":{"rows":{"relation":"rows","schema":"example-event-rows/v1","fields":["source_event_id","role","text","raw_json","turn_index"],"renderers":["json"]}},"bounds":{"max_rows":10,"max_output_bytes":4096,"max_fold_states":2}}
        ,
    });
    var event_closure = try definition_core.closure.loadFromDir(
        std.testing.allocator,
        &tmp.dir,
        "events.json",
        .{},
    );
    defer event_closure.deinit(std.testing.allocator);
    var event_definition = try definition.compile(
        std.testing.allocator,
        &event_closure,
        "events.json",
    );
    defer event_definition.deinit(std.testing.allocator);
    var event_plan = try plan.compile(
        std.testing.allocator,
        &event_definition,
    );
    defer event_plan.deinit(std.testing.allocator);
    var event_bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &event_definition.parameter_declarations,
        &.{},
    );
    defer event_bindings.deinit(std.testing.allocator);
    var event_program = try execution.compile(
        std.testing.allocator,
        &event_definition,
        &event_plan,
        &event_bindings,
        "rows",
    );
    defer event_program.deinit(std.testing.allocator);

    var event_output: [5]execution.Value = undefined;
    var events = try observeFile(
        std.testing.allocator,
        &event_program,
        path,
        .{ .ongoing_threshold_secs = 0 },
        &event_output,
    );
    defer events.deinit(std.testing.allocator);
    const event_row = events.result.rows().row(0);
    try std.testing.expectEqual(@as(usize, 1), events.result.row_count);
    try std.testing.expectEqualStrings("sha256:", event_row[0].string[0..7]);
    try std.testing.expectEqualStrings("assistant", event_row[1].string);
    try std.testing.expectEqualStrings("observed", event_row[2].string);
    try std.testing.expectEqualStrings(
        "{\"timestamp\":\"2026-07-26T10:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"observed\"}}",
        event_row[3].json,
    );
    try std.testing.expectEqual(@as(i64, 1), event_row[4].integer);
}
