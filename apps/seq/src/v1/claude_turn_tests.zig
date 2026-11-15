const std = @import("std");
const trace_core = @import("trace_core");
const support = @import("claude_fixture_support.zig");

const testing = std.testing;
const Trace = trace_core.CanonicalSessionTrace;
const Turn = trace_core.TurnRecord;
const Status = trace_core.TurnStatus;

const main_path = "/projects/-work-demo/5e55f00d-0000-4000-8000-00000000c1a0.jsonl";

fn fixture(comptime name: []const u8) []const u8 {
    return @embedFile("fixtures/claude/" ++ name);
}

fn ts(comptime line: u32) []const u8 {
    return std.fmt.comptimePrint("2026-11-10T10:{d:0>2}:{d:0>2}.000Z", .{ line / 60, line % 60 });
}

fn load(bytes: []const u8, freshness: support.Freshness) !Trace {
    return support.parse(testing.allocator, main_path, bytes, freshness);
}

fn loadAt(path: []const u8, bytes: []const u8, freshness: support.Freshness) !Trace {
    return support.parse(testing.allocator, path, bytes, freshness);
}

fn expectText(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |want| {
        const got = actual orelse {
            std.debug.print("expected \"{s}\", found null\n", .{want});
            return error.TestExpectedEqual;
        };
        try testing.expectEqualStrings(want, got);
    } else if (actual) |got| {
        std.debug.print("expected null, found \"{s}\"\n", .{got});
        return error.TestExpectedEqual;
    }
}

fn turnAt(trace: *const Trace, index: i64) !*const Turn {
    for (trace.turns.items) |*turn| {
        if (turn.turn_index == index) return turn;
    }
    std.debug.print("missing turn {d}\n", .{index});
    return error.MissingTurn;
}

fn expectOutcome(turn: *const Turn, status: Status, reason: []const u8) !void {
    try expectText(reason, turn.status_reason);
    try testing.expectEqual(status, turn.status);
}

fn expectTurn(trace: *const Trace, index: i64, status: Status, reason: []const u8) !void {
    try expectOutcome(try turnAt(trace, index), status, reason);
}

fn occurrenceAt(trace: *const Trace, line: usize) !*const trace_core.TraceOccurrence {
    for (trace.occurrences.items) |*occurrence| {
        if (occurrence.line_number == line) return occurrence;
    }
    return error.MissingOccurrence;
}

fn isVisible(occurrence: *const trace_core.TraceOccurrence) bool {
    return occurrence.message_visible and occurrence.role != null and occurrence.text != null;
}

fn visibleCount(trace: *const Trace, role: ?[]const u8) usize {
    var count: usize = 0;
    for (trace.occurrences.items) |*occurrence| {
        if (!isVisible(occurrence)) continue;
        if (role) |want| {
            if (!std.mem.eql(u8, want, occurrence.role.?)) continue;
        }
        count += 1;
    }
    return count;
}

fn visibleWithText(trace: *const Trace, text: []const u8) usize {
    var count: usize = 0;
    for (trace.occurrences.items) |*occurrence| {
        if (isVisible(occurrence) and std.mem.eql(u8, text, occurrence.text.?)) count += 1;
    }
    return count;
}

fn expectHidden(trace: *const Trace, lines: []const usize) !void {
    for (lines) |line| {
        const occurrence = try occurrenceAt(trace, line);
        if (isVisible(occurrence)) {
            std.debug.print("line {d} is a visible message\n", .{line});
            return error.UnexpectedVisibleMessage;
        }
    }
}

fn tokenRows(trace: *const Trace, key: []const u8) usize {
    var count: usize = 0;
    for (trace.token_events.items) |*event| {
        if (event.request_key) |value| {
            if (std.mem.eql(u8, key, value)) count += 1;
        }
    }
    return count;
}

fn tokenRow(trace: *const Trace, key: []const u8) !*const trace_core.TokenEventRecord {
    for (trace.token_events.items) |*event| {
        if (event.request_key) |value| {
            if (std.mem.eql(u8, key, value)) return event;
        }
    }
    std.debug.print("missing token row {s}\n", .{key});
    return error.MissingTokenRow;
}

fn toolCount(trace: *const Trace, call: []const u8) usize {
    var count: usize = 0;
    for (trace.tools.items) |*tool| {
        if (tool.call_id) |value| {
            if (std.mem.eql(u8, call, value)) count += 1;
        }
    }
    return count;
}

fn toolByCall(trace: *const Trace, call: []const u8) !*const trace_core.ToolLifecycleRecord {
    for (trace.tools.items) |*tool| {
        if (tool.call_id) |value| {
            if (std.mem.eql(u8, call, value)) return tool;
        }
    }
    return error.MissingTool;
}

fn expectJsonString(json: ?[]const u8, field: []const u8, value: []const u8) !void {
    const text = json orelse return error.MissingJson;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |map| map,
        else => return error.ExpectedJsonObject,
    };
    const found = object.get(field) orelse return error.MissingJsonField;
    switch (found) {
        .string => |got| try testing.expectEqualStrings(value, got),
        else => return error.ExpectedJsonString,
    }
}

fn expectUnfinishedActive(bytes: []const u8, index: i64) !void {
    {
        var trace = try load(bytes, .fresh);
        defer trace.deinit(testing.allocator);
        const turn = try turnAt(&trace, index);
        try expectOutcome(turn, .ongoing, "fresh_ongoing_turn");
        try expectText(null, turn.completed_at);
    }
    var trace = try load(bytes, .stale);
    defer trace.deinit(testing.allocator);
    const turn = try turnAt(&trace, index);
    try expectOutcome(turn, .aborted, "stale_ongoing_file");
    try expectText(null, turn.completed_at);
}

fn expectBoth(bytes: []const u8, index: i64, status: Status, reason: []const u8) !void {
    inline for (.{ support.Freshness.fresh, support.Freshness.stale }) |freshness| {
        var trace = try load(bytes, freshness);
        defer trace.deinit(testing.allocator);
        try expectTurn(&trace, index, status, reason);
    }
}

test "turn inputs open turns only at replied and origin-bearing inputs" {
    var trace = try load(fixture("turn-inputs.jsonl"), .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), trace.turns.items.len);
    const ids = [_][]const u8{ "in-p1", "in-p2", "in-task", "in-sched", "in-p5" };
    const origins = [_][]const u8{ "human", "human", "task_notification", "scheduled", "human" };
    for (ids, origins, 1..) |id, origin, index| {
        const turn = try turnAt(&trace, @intCast(index));
        try testing.expectEqualStrings(id, turn.turn_id);
        try expectText(origin, turn.origin);
    }
    try expectText("first prompt", (try turnAt(&trace, 1)).user_message);
    try expectText(null, (try turnAt(&trace, 3)).user_message);
    try expectText(null, (try turnAt(&trace, 4)).user_message);
    try expectText("never answered", (try turnAt(&trace, 5)).user_message);
}

test "turn inputs hide echoes, outputs, markers and harness openings" {
    var trace = try load(fixture("turn-inputs.jsonl"), .fresh);
    defer trace.deinit(testing.allocator);
    try expectHidden(&trace, &.{ 4, 5, 6, 9, 10, 12 });
    for ([_]usize{ 1, 2, 7, 11, 13, 14 }) |line| {
        try testing.expect(isVisible(try occurrenceAt(&trace, line)));
    }
    try testing.expectEqual(@as(usize, 6), visibleCount(&trace, null));
    try testing.expectEqual(@as(usize, 3), visibleCount(&trace, "user"));
}

test "turn inputs outcomes follow the reply evidence" {
    var trace = try load(fixture("turn-inputs.jsonl"), .fresh);
    defer trace.deinit(testing.allocator);
    const first = try turnAt(&trace, 1);
    try expectOutcome(first, .complete, "claude_end_turn");
    try testing.expectEqual(@as(?i64, 1500), first.duration_ms);
    try expectText(ts(3), first.completed_at);
    const second = try turnAt(&trace, 2);
    try expectOutcome(second, .aborted, "claude_interrupted");
    try expectText("[Request interrupted by user]", second.aborted_reason);
    try expectTurn(&trace, 3, .complete, "claude_end_turn");
    try expectTurn(&trace, 4, .complete, "claude_end_turn");
    try expectUnfinishedActive(fixture("turn-inputs.jsonl"), 5);
}

test "turn outcomes end_turn, tool-ended and interrupted turns" {
    var trace = try load(fixture("turn-outcomes.jsonl"), .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), trace.turns.items.len);
    const first = try turnAt(&trace, 1);
    try expectOutcome(first, .complete, "claude_end_turn");
    try expectText("Answer one.", first.final_answer);
    try expectText(ts(2), first.completed_at);
    try expectText("claude-test-1", first.model);
    try expectText("high", first.reasoning_effort);
    try testing.expectEqual(@as(?i64, 10), first.input_tokens);
    try testing.expectEqual(@as(?i64, 7), first.output_tokens);
    try testing.expectEqual(@as(?i64, 17), first.total_tokens);
    const second = try turnAt(&trace, 2);
    try expectOutcome(second, .complete, "claude_tool_ended_turn");
    try expectJsonString(second.final_answer, "answer", "forty-two");
    try expectText(ts(6), second.completed_at);
    const third = try turnAt(&trace, 3);
    try expectOutcome(third, .aborted, "claude_interrupted");
    try expectText("[Request interrupted by user for tool use]", third.aborted_reason);
    try testing.expectEqual(@as(?i64, 4000), third.duration_ms);
    try expectText(ts(10), third.completed_at);
    const fourth = try turnAt(&trace, 4);
    try expectOutcome(fourth, .complete, "claude_text_end");
    try expectText("Legacy end.", fourth.final_answer);
    try expectText(ts(12), fourth.completed_at);
}

test "turn outcomes pending tool calls are ongoing, stale or superseded" {
    const bytes = fixture("turn-outcomes.jsonl");
    inline for (.{ support.Freshness.fresh, support.Freshness.stale }) |freshness| {
        var trace = try load(bytes, freshness);
        defer trace.deinit(testing.allocator);
        const fifth = try turnAt(&trace, 5);
        try expectOutcome(fifth, .aborted, "claude_superseded");
        try expectText("Let me check.", fifth.final_answer);
        try expectText(null, fifth.completed_at);
    }
    try expectUnfinishedActive(bytes, 6);
    var trace = try load(bytes, .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expect(trace.session.is_ongoing);
    try expectText("fresh_ongoing_turn", trace.session.status_reason);
}

test "turn-ending results: MCP end-turn key completes with no answer" {
    const bytes = fixture("turn-ending-results/mcp-end-turn.jsonl");
    try expectBoth(bytes, 1, .complete, "claude_tool_ended_turn");
    var trace = try load(bytes, .stale);
    defer trace.deinit(testing.allocator);
    const turn = try turnAt(&trace, 1);
    try expectText(null, turn.final_answer);
    try expectText(ts(3), turn.completed_at);
}

test "turn-ending results: errored StructuredOutput ends nothing" {
    const bytes = fixture("turn-ending-results/schema-error.jsonl");
    var trace = try load(bytes, .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), trace.turns.items.len);
    const turn = try turnAt(&trace, 1);
    try expectOutcome(turn, .complete, "claude_end_turn");
    try expectText("Final text.", turn.final_answer);
    try expectHidden(&trace, &.{5});
    try testing.expectEqual(@as(?i64, 1), (try occurrenceAt(&trace, 5)).turn_index);
}

test "turn-ending results: flagged error and turn limit" {
    try expectUnfinishedActive(fixture("turn-ending-results/flagged-error.jsonl"), 1);
    const bytes = fixture("turn-ending-results/max-turns.jsonl");
    try expectBoth(bytes, 1, .aborted, "claude_max_turns_reached");
    var trace = try load(bytes, .fresh);
    defer trace.deinit(testing.allocator);
    try expectText(ts(4), (try turnAt(&trace, 1)).completed_at);
}

test "terminal tool answer comes only from a structured_output attachment" {
    var trace = try load(fixture("terminal-tool-answer.jsonl"), .stale);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), trace.turns.items.len);
    const first = try turnAt(&trace, 1);
    try expectOutcome(first, .complete, "claude_tool_ended_turn");
    try expectJsonString(first.final_answer, "answer", "alpha");
    for ([_]i64{ 2, 3 }) |index| {
        const turn = try turnAt(&trace, index);
        try expectOutcome(turn, .complete, "claude_tool_ended_turn");
        try expectText(null, turn.final_answer);
    }
    const mcp = try toolByCall(&trace, "call-tt-3");
    try expectJsonString(mcp.arguments_json, "expression", "2+2");
    try expectText("4", mcp.output_text);
    const plain = try toolByCall(&trace, "call-tt-2");
    try expectJsonString(plain.arguments_json, "answer", "beta");
}

test "output limit recoveries end in the API error" {
    var trace = try load(fixture("output-limit.jsonl"), .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), trace.turns.items.len);
    const first = try turnAt(&trace, 1);
    try expectOutcome(first, .@"error", "claude_api_error");
    try expectText("API Error: response exceeded the output token maximum.", first.@"error");
    try expectText("Part one", first.final_answer);
    try expectText(ts(8), first.completed_at);
    try expectHidden(&trace, &.{ 3, 5, 7, 8 });
    const second = try turnAt(&trace, 2);
    try expectOutcome(second, .complete, "claude_max_tokens");
    try expectText("Short", second.final_answer);
    try expectText(ts(10), second.completed_at);
    try expectBoth(fixture("output-limit.jsonl"), 2, .complete, "claude_max_tokens");
}

const re_query_signs = [_][]const u8{
    fixture("re-query/end-turn-inflight.jsonl"),
    fixture("re-query/end-turn-retry.jsonl"),
    fixture("re-query/end-turn-hit.jsonl"),
    fixture("re-query/end-turn-cut.jsonl"),
    fixture("re-query/end-turn-enforce.jsonl"),
    fixture("re-query/max-tokens-inflight.jsonl"),
    fixture("re-query/max-tokens-retry.jsonl"),
    fixture("re-query/max-tokens-hit.jsonl"),
    fixture("re-query/max-tokens-cut.jsonl"),
    fixture("re-query/max-tokens-enforce.jsonl"),
};

test "re-query signs leave the turn unfinished with final request usage" {
    for (re_query_signs, 0..) |bytes, case| {
        errdefer std.debug.print("re-query case {d}\n", .{case});
        try expectUnfinishedActive(bytes, 1);
        var trace = try load(bytes, .stale);
        defer trace.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), trace.turns.items.len);
        const row = try tokenRow(&trace, "msg-rq-1");
        try expectText("final", row.usage_finality);
        try testing.expectEqual(@as(?i64, 9), row.output_tokens);
    }
}

test "re-query resolved by a later ending" {
    const later_end = fixture("re-query/later-end-turn.jsonl");
    try expectBoth(later_end, 1, .complete, "claude_end_turn");
    var trace = try load(later_end, .stale);
    defer trace.deinit(testing.allocator);
    try expectText("Recovered.", (try turnAt(&trace, 1)).final_answer);
    try expectBoth(fixture("re-query/later-api-error.jsonl"), 1, .@"error", "claude_api_error");
    try expectBoth(fixture("re-query/later-interrupt.jsonl"), 1, .aborted, "claude_interrupted");
    const max_turns = fixture("re-query/later-max-turns.jsonl");
    try expectBoth(max_turns, 1, .aborted, "claude_max_turns_reached");
}

test "re-query: a request before a later prompt and notices change nothing" {
    const bytes = fixture("re-query/request-then-prompt.jsonl");
    try expectBoth(bytes, 1, .complete, "claude_end_turn");
    try expectBoth(bytes, 2, .complete, "claude_end_turn");
    var trace = try load(bytes, .stale);
    defer trace.deinit(testing.allocator);
    try expectText(ts(3), (try turnAt(&trace, 1)).completed_at);
    const notices = fixture("re-query/notices.jsonl");
    try expectBoth(notices, 1, .complete, "claude_end_turn");
    var noticed = try load(notices, .fresh);
    defer noticed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), noticed.turns.items.len);
    const turn = try turnAt(&noticed, 1);
    try expectText("Done.", turn.final_answer);
    try expectText(ts(2), turn.completed_at);
}

test "unanswered replies open their own turns" {
    var trace = try load(fixture("unanswered-replies.jsonl"), .stale);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), trace.turns.items.len);
    const first = try turnAt(&trace, 1);
    try testing.expectEqualStrings("ur-p1", first.turn_id);
    try expectOutcome(first, .complete, "claude_text_end");
    try expectText("Answer.", first.final_answer);
    const second = try turnAt(&trace, 2);
    try testing.expectEqualStrings("ur-p2", second.turn_id);
    try expectOutcome(second, .@"error", "claude_api_error");
    try expectText("API Error: Repeated 529 Overloaded errors", second.@"error");
    try expectText(null, second.final_answer);
    const third = try turnAt(&trace, 3);
    try testing.expectEqualStrings("ur-p3", third.turn_id);
    try expectOutcome(third, .aborted, "claude_interrupted");
    try expectHidden(&trace, &.{ 9, 10 });
}

test "unanswered replies: worker error fallback and retry stop" {
    const worker_path = "/projects/-work-demo/agent-w0rk3r.jsonl";
    const bytes = fixture("unanswered-replies-worker.jsonl");
    var trace = try loadAt(worker_path, bytes, .stale);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), trace.turns.items.len);
    const turn = try turnAt(&trace, 1);
    try testing.expectEqualStrings("ur-we", turn.turn_id);
    try expectOutcome(turn, .@"error", "claude_api_error");
    try expectText(null, turn.origin);
    try expectText(null, turn.user_message);
    try expectUnfinishedActive(fixture("unanswered-replies-retry.jsonl"), 1);
}

test "synthetic API errors decide error outcomes" {
    var trace = try load(fixture("synthetic-api-error.jsonl"), .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), trace.turns.items.len);
    const first = try turnAt(&trace, 1);
    try expectOutcome(first, .@"error", "claude_api_error");
    try expectText("API Error: 500 internal server error", first.@"error");
    try expectText(ts(5), first.completed_at);
    try expectText("claude-test-1", first.model);
    try expectText("high", first.reasoning_effort);
    try expectText("Looking into it.", first.final_answer);
    const second = try turnAt(&trace, 2);
    try expectOutcome(second, .@"error", "claude_api_error");
    try expectText("API Error: authentication failed", second.@"error");
    try expectText(ts(7), second.completed_at);
    try expectText(null, second.model);
    try expectText(null, second.reasoning_effort);
    try expectText(null, second.final_answer);
}

test "synthetic placeholders establish nothing" {
    const bytes = fixture("synthetic-api-error.jsonl");
    var trace = try load(bytes, .fresh);
    defer trace.deinit(testing.allocator);
    const third = try turnAt(&trace, 3);
    try expectOutcome(third, .complete, "claude_end_turn");
    try expectText("Fine.", third.final_answer);
    try expectText(null, third.@"error");
    try expectText(ts(9), third.completed_at);
    try expectUnfinishedActive(bytes, 4);
    try expectHidden(&trace, &.{ 5, 7, 10, 13 });
    try testing.expectEqual(@as(usize, 3), trace.token_events.items.len);
    for (trace.token_events.items) |*event| {
        try testing.expect(!std.mem.eql(u8, "<synthetic>", event.model orelse ""));
    }
    for ([_][]const u8{ "msg-sy-1", "msg-sy-3", "msg-sy-4" }) |key| {
        try testing.expectEqual(@as(usize, 1), tokenRows(&trace, key));
    }
}

test "turn stop reasons complete under their own name" {
    var trace = try load(fixture("turn-stop-reasons.jsonl"), .stale);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 17), trace.turns.items.len);
    const complete = [_]struct { i64, []const u8, []const u8 }{
        .{ 1, "claude_end_turn", "r1" },
        .{ 2, "claude_max_tokens", "r2" },
        .{ 3, "claude_stop_sequence", "r3" },
        .{ 4, "claude_refusal", "r4" },
        .{ 5, "claude_model_context_window_exceeded", "r5" },
        .{ 6, "claude_brand_new_reason", "r6" },
        .{ 12, "claude_text_end", "r12" },
        .{ 13, "claude_text_end", "r13" },
        .{ 17, "claude_end_turn", "r17" },
    };
    for (complete) |case| {
        errdefer std.debug.print("stop-reason turn {d}\n", .{case[0]});
        const turn = try turnAt(&trace, case[0]);
        try expectOutcome(turn, .complete, case[1]);
        try expectText(case[2], turn.final_answer);
    }
    for ([_]i64{ 7, 8, 9, 10, 11, 14, 15 }) |index| {
        errdefer std.debug.print("stop-reason turn {d}\n", .{index});
        try expectTurn(&trace, index, .aborted, "claude_superseded");
    }
    try expectTurn(&trace, 16, .@"error", "claude_api_error");
}

test "turn stop reasons decide request finality independently" {
    var trace = try load(fixture("turn-stop-reasons.jsonl"), .fresh);
    defer trace.deinit(testing.allocator);
    const finals = [_][]const u8{
        "msg-sr-1", "msg-sr-7", "msg-sr-8", "msg-sr-9", "msg-sr-10", "msg-sr-11",
    };
    for (finals) |key| {
        errdefer std.debug.print("token row {s}\n", .{key});
        try expectText("final", (try tokenRow(&trace, key)).usage_finality);
    }
    const provisional = [_][]const u8{ "msg-sr-12", "msg-sr-13", "msg-sr-14", "msg-sr-15" };
    for (provisional) |key| {
        errdefer std.debug.print("token row {s}\n", .{key});
        try expectText("provisional", (try tokenRow(&trace, key)).usage_finality);
    }
}

test "legacy turns open only at answered inputs" {
    var trace = try load(fixture("legacy-turns.jsonl"), .stale);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), trace.turns.items.len);
    const first = try turnAt(&trace, 1);
    try testing.expectEqualStrings("lg-p1", first.turn_id);
    try expectText(null, first.origin);
    try expectText("q1", first.user_message);
    const second = try turnAt(&trace, 2);
    try testing.expectEqualStrings("lg-p2", second.turn_id);
    try expectText("q2", second.user_message);
    try expectOutcome(second, .complete, "claude_end_turn");
    try testing.expectEqual(@as(usize, 4), visibleCount(&trace, null));
    try expectHidden(&trace, &.{ 7, 8, 9 });

    var lone = try load(fixture("legacy-turns-lone.jsonl"), .stale);
    defer lone.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), lone.turns.items.len);
    try testing.expectEqual(@as(usize, 0), visibleCount(&lone, null));
    try testing.expectEqual(@as(usize, 1), lone.occurrences.items.len);
    try testing.expectEqualStrings("user", lone.occurrences.items[0].entry_type);
    try expectText("no_turns", lone.session.status_reason);
}

test "branch rewrite keeps both branches and aborts the inactive one" {
    const bytes = fixture("branch-rewrite.jsonl");
    try expectBoth(bytes, 2, .aborted, "claude_inactive_branch");
    var trace = try load(bytes, .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), trace.turns.items.len);
    const inactive = try turnAt(&trace, 2);
    try testing.expectEqualStrings("br-p2", inactive.turn_id);
    try expectText("Plan.", inactive.final_answer);
    const active = try turnAt(&trace, 3);
    try testing.expectEqualStrings("br-p2x", active.turn_id);
    try expectOutcome(active, .complete, "claude_end_turn");
    try expectText("Done.", active.final_answer);
    try testing.expectEqual(@as(usize, 2), visibleWithText(&trace, "Plan."));
    try testing.expectEqual(@as(usize, 2), visibleWithText(&trace, "q2"));
}

test "branch rewrite ownership follows the first physical occurrence" {
    var trace = try load(fixture("branch-rewrite.jsonl"), .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), toolCount(&trace, "call-br"));
    try testing.expectEqual(@as(?i64, 2), (try toolByCall(&trace, "call-br")).turn_index);
    try testing.expectEqual(@as(i64, 1), (try turnAt(&trace, 2)).tool_count);
    try testing.expectEqual(@as(i64, 0), (try turnAt(&trace, 3)).tool_count);
    try testing.expectEqual(@as(usize, 3), trace.token_events.items.len);
    const row = try tokenRow(&trace, "msg-br-2");
    try testing.expectEqual(@as(?i64, 2), row.turn_index);
    try testing.expectEqual(@as(?i64, 8), row.output_tokens);
    try expectText("final", row.usage_finality);
    try expectText("usable", row.quantity_state);
    const first = trace.occurrences.items[row.occurrence_index];
    try testing.expectEqual(@as(usize, 4), first.line_number);
    try testing.expectEqual(@as(?i64, 8), (try turnAt(&trace, 2)).output_tokens);
    try testing.expectEqual(@as(?i64, 4), (try turnAt(&trace, 3)).output_tokens);
}

test "assistant-only fallback turn" {
    const path = "/projects/-work-demo/agent-0ne11ne.jsonl";
    var trace = try loadAt(path, fixture("assistant-only-fallback.jsonl"), .stale);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), trace.turns.items.len);
    const turn = try turnAt(&trace, 1);
    try testing.expectEqualStrings("fb-a", turn.turn_id);
    try expectText(null, turn.origin);
    try expectText(null, turn.user_message);
    try expectText("Agent reply.", turn.final_answer);
    try testing.expectEqual(@as(usize, 1), visibleCount(&trace, "assistant"));
    try testing.expectEqual(@as(usize, 0), visibleCount(&trace, "user"));
}

test "inline sidechain last does not take the active leaf" {
    const bytes = fixture("inline-sidechain-last.jsonl");
    try expectUnfinishedActive(bytes, 1);
    var trace = try load(bytes, .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), trace.turns.items.len);
    try testing.expect(trace.session.is_ongoing);
    try testing.expectEqual(@as(usize, 2), visibleCount(&trace, null));
    try testing.expectEqual(@as(usize, 1), trace.tools.items.len);
    try testing.expectEqual(@as(usize, 1), toolCount(&trace, "call-is-t"));
    try testing.expectEqual(@as(usize, 6), trace.occurrences.items.len);
    for ([_]usize{ 3, 4, 5, 6 }) |line| {
        try testing.expectEqual(@as(?i64, null), (try occurrenceAt(&trace, line)).turn_index);
    }
    try testing.expectEqual(@as(usize, 3), trace.token_events.items.len);
    try testing.expectEqual(@as(?i64, 1), (try tokenRow(&trace, "msg-is-1")).turn_index);
    try testing.expectEqual(@as(?i64, null), (try tokenRow(&trace, "msg-is-s1")).turn_index);
    try testing.expectEqual(@as(?i64, null), (try tokenRow(&trace, "msg-is-s2")).turn_index);
}

test "turn paths: the active branch decides one turn" {
    const bytes = fixture("turn-paths.jsonl");
    try expectUnfinishedActive(bytes, 1);
    var trace = try load(bytes, .stale);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), trace.turns.items.len);
    try expectText("New text.", (try turnAt(&trace, 1)).final_answer);
}

test "turn paths: inactive turn reads its last-appended owned path" {
    const bytes = fixture("turn-paths-inactive.jsonl");
    try expectBoth(bytes, 2, .aborted, "claude_inactive_branch");
    var trace = try load(bytes, .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), trace.turns.items.len);
    try expectText("branch b", (try turnAt(&trace, 2)).final_answer);
    try testing.expectEqual(@as(?i64, null), (try turnAt(&trace, 2)).duration_ms);
    const first = try turnAt(&trace, 1);
    try expectOutcome(first, .complete, "claude_end_turn");
    try testing.expectEqual(@as(?i64, null), first.duration_ms);
    try expectText(ts(2), first.completed_at);
    const third = try turnAt(&trace, 3);
    try expectOutcome(third, .complete, "claude_end_turn");
    try testing.expectEqual(@as(?i64, 2500), third.duration_ms);
    try expectText(ts(9), third.completed_at);
}

test "turn paths: abandoned siblings and attachment siblings" {
    var sibling = try load(fixture("turn-paths-sibling.jsonl"), .stale);
    defer sibling.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), sibling.turns.items.len);
    const turn = try turnAt(&sibling, 1);
    try expectOutcome(turn, .complete, "claude_end_turn");
    try expectText("Answer.", turn.final_answer);
    try expectText(null, turn.@"error");
    try expectText(null, turn.aborted_reason);
    const attach = fixture("turn-paths-attach.jsonl");
    try expectBoth(attach, 1, .complete, "claude_tool_ended_turn");
    var attached = try load(attach, .fresh);
    defer attached.deinit(testing.allocator);
    try expectJsonString((try turnAt(&attached, 1)).final_answer, "answer", "x");
}

test "turn paths: another turn's or an unrelated result ends nothing" {
    const bytes = fixture("turn-paths-other-turn.jsonl");
    try expectBoth(bytes, 1, .aborted, "claude_superseded");
    try expectBoth(bytes, 2, .complete, "claude_end_turn");
}

test "turn paths: replayed declarations reuse an earlier result" {
    const replay = fixture("turn-paths-replay.jsonl");
    try expectBoth(replay, 1, .complete, "claude_tool_ended_turn");
    inline for (.{
        .{ "turn-paths-replay.jsonl", "call-tr" },
        .{ "turn-paths-requery.jsonl", "call-tq" },
    }) |case| {
        var trace = try load(fixture(case[0]), .fresh);
        defer trace.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), trace.turns.items.len);
        try testing.expectEqual(@as(usize, 1), toolCount(&trace, case[1]));
        try testing.expectEqual(@as(i64, 1), (try turnAt(&trace, 1)).tool_count);
    }
}

test "turn paths: a recovery prompt between result and replay voids the ending" {
    try expectUnfinishedActive(fixture("turn-paths-requery.jsonl"), 1);
}

test "repeated ownership stays with the first occurrence" {
    var trace = try load(fixture("repeated-ownership.jsonl"), .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), trace.turns.items.len);
    try testing.expectEqual(@as(usize, 1), tokenRows(&trace, "msg-ro-M"));
    const row = try tokenRow(&trace, "msg-ro-M");
    try testing.expectEqual(@as(?i64, 1), row.turn_index);
    try testing.expectEqual(@as(?i64, 12), row.output_tokens);
    try expectText("final", row.usage_finality);
    try expectText("usable", row.quantity_state);
    const first = trace.occurrences.items[row.occurrence_index];
    try testing.expectEqual(@as(usize, 2), first.line_number);
    try expectText(ts(2), first.timestamp);
    try testing.expectEqual(@as(usize, 1), toolCount(&trace, "call-ro-C"));
    try testing.expectEqual(@as(?i64, 1), (try toolByCall(&trace, "call-ro-C")).turn_index);
    try testing.expectEqual(@as(i64, 1), (try turnAt(&trace, 1)).tool_count);
    const later = try turnAt(&trace, 2);
    try testing.expectEqual(@as(i64, 0), later.tool_count);
    try testing.expect(later.output_tokens == null or later.output_tokens.? == 0);
    try testing.expectEqual(@as(?i64, 12), (try turnAt(&trace, 1)).output_tokens);
    try testing.expectEqual(@as(usize, 2), visibleWithText(&trace, "Same text."));
    try testing.expectEqualStrings("assistant", (try occurrenceAt(&trace, 6)).entry_type);
}

test "resume appends turns to the same session" {
    var trace = try load(fixture("resume.jsonl"), .stale);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), trace.turns.items.len);
    try testing.expectEqual(@as(i64, 2), trace.session.turn_count);
    try expectText("5e55f00d-0000-4000-8000-00000000c1a0", trace.session.session_id);
    const first = try turnAt(&trace, 1);
    try testing.expectEqualStrings("rs-p1", first.turn_id);
    try expectOutcome(first, .complete, "claude_end_turn");
    try testing.expectEqual(@as(?i64, 1000), first.duration_ms);
    try expectText(ts(4), first.completed_at);
    const second = try turnAt(&trace, 2);
    try testing.expectEqualStrings("rs-p2", second.turn_id);
    try expectOutcome(second, .complete, "claude_end_turn");
    try testing.expectEqual(@as(?i64, 2000), second.duration_ms);
    try expectText(ts(9), second.completed_at);
}

test "rewind aborts the inactive sibling branch" {
    const bytes = fixture("rewind.jsonl");
    try expectBoth(bytes, 2, .aborted, "claude_inactive_branch");
    var trace = try load(bytes, .fresh);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), trace.turns.items.len);
    try expectText("trying", (try turnAt(&trace, 2)).final_answer);
    try expectTurn(&trace, 1, .complete, "claude_end_turn");
    try expectTurn(&trace, 3, .complete, "claude_end_turn");
    try testing.expectEqualStrings("rw-p3", (try turnAt(&trace, 3)).turn_id);
}

test "compaction boundary is bridged inside its turn" {
    var trace = try load(fixture("compaction.jsonl"), .stale);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), trace.turns.items.len);
    const first = try turnAt(&trace, 1);
    try testing.expectEqualStrings("cp-p1", first.turn_id);
    try testing.expect(first.has_compaction);
    try expectOutcome(first, .complete, "claude_end_turn");
    try expectText("Continuing.", first.final_answer);
    const second = try turnAt(&trace, 2);
    try testing.expectEqualStrings("cp-p2", second.turn_id);
    try testing.expect(!second.has_compaction);
    try expectHidden(&trace, &.{5});
    try testing.expectEqual(@as(?i64, 1), (try occurrenceAt(&trace, 6)).turn_index);
}

const repeat_prompt =
    \\{"parentUuid":null,"isSidechain":false,"type":"user","uuid":"du-p1","timestamp":"2026-11-10T10:00:01.000Z","cwd":"/work/demo","sessionId":"5e55f00d-0000-4000-8000-00000000c1a0","version":"2.1.325","message":{"role":"user","content":"q1"},"turnOrigin":"human"}
    \\
;
const repeat_reply =
    \\{"parentUuid":"du-p1","isSidechain":false,"type":"assistant","uuid":"du-a1","timestamp":"2026-11-10T10:00:02.000Z","cwd":"/work/demo","sessionId":"5e55f00d-0000-4000-8000-00000000c1a0","version":"2.1.325","message":{"id":"msg-du-1","type":"message","role":"assistant","model":"claude-test-1","content":[{"type":"text","text":"one"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5}}}
    \\
;
const altered_reply =
    \\{"parentUuid":"du-p1","isSidechain":false,"type":"assistant","uuid":"du-a1","timestamp":"2026-11-10T10:00:02.000Z","cwd":"/work/demo","sessionId":"5e55f00d-0000-4000-8000-00000000c1a0","version":"2.1.325","message":{"id":"msg-du-1","type":"message","role":"assistant","model":"claude-test-1","content":[{"type":"text","text":"two"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":5}}}
    \\
;

fn duplicateUuidWarnings(trace: *const Trace, suffix: []const u8) usize {
    var count: usize = 0;
    for (trace.warnings.items) |warning| {
        if (std.mem.endsWith(u8, warning, suffix)) count += 1;
    }
    return count;
}

test "duplicate uuid warns only when a different record reuses it" {
    const warning = "duplicate Claude record uuid";
    const repeated = repeat_prompt ++ repeat_reply ++ repeat_reply ++ repeat_prompt;
    var same = try load(repeated, .stale);
    defer same.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), duplicateUuidWarnings(&same, warning));
    var changed = try load(repeat_prompt ++ repeat_reply ++ altered_reply ++ repeat_reply, .stale);
    defer changed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), duplicateUuidWarnings(&changed, warning));
    try testing.expectEqual(@as(usize, 1), duplicateUuidWarnings(&changed, ":3: " ++ warning));
}
