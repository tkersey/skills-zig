const std = @import("std");
const trace_core = @import("trace_core");
const support = @import("claude_fixture_support.zig");

const testing = std.testing;
const Trace = trace_core.CanonicalSessionTrace;
const Event = trace_core.TokenEventRecord;

const Q = struct { in: i64, cached: i64, creation: i64, out: i64, total: i64 };

fn q(in: i64, cached: i64, creation: i64, out: i64, total: i64) Q {
    return .{ .in = in, .cached = cached, .creation = creation, .out = out, .total = total };
}

fn fixture(comptime rel: []const u8) []const u8 {
    return @embedFile("fixtures/claude/" ++ rel);
}

fn inDir(comptime dir: []const u8, comptime id: []const u8) []const u8 {
    return fixture(dir ++ "/" ++ id ++ ".jsonl");
}

fn timestampOf(trace: *const Trace, event: *const Event) ?[]const u8 {
    return trace.occurrences.items[event.occurrence_index].timestamp;
}

fn load(stem: []const u8, bytes: []const u8) !Trace {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/fx/projects/-tmp-fx-proj/{s}.jsonl", .{stem});
    return support.parse(testing.allocator, path, bytes, .stale);
}

fn expectText(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |value| {
        try testing.expect(actual != null);
        try testing.expectEqualStrings(value, actual.?);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), actual);
    }
}

fn lineOf(trace: *const Trace, event: *const Event) usize {
    return trace.occurrences.items[event.occurrence_index].line_number;
}

fn keyed(trace: *const Trace, key: []const u8) !*const Event {
    var found: ?*const Event = null;
    for (trace.token_events.items) |*event| {
        const request_key = event.request_key orelse continue;
        if (!std.mem.eql(u8, request_key, key)) continue;
        if (found != null) return error.DuplicateRequestRow;
        found = event;
    }
    return found orelse error.MissingRequestRow;
}

fn unkeyedAt(trace: *const Trace, line: usize) !*const Event {
    for (trace.token_events.items) |*event| {
        if (event.request_key == null and lineOf(trace, event) == line) return event;
    }
    return error.MissingDiagnosticRow;
}

fn unkeyedCount(trace: *const Trace) usize {
    var count: usize = 0;
    for (trace.token_events.items) |event| {
        if (event.request_key == null) count += 1;
    }
    return count;
}

fn turnOf(trace: *const Trace, turn_id: []const u8) !*const trace_core.TurnRecord {
    for (trace.turns.items) |*turn| {
        if (std.mem.eql(u8, turn.turn_id, turn_id)) return turn;
    }
    return error.MissingTurn;
}

fn expectOwner(trace: *const Trace, event: *const Event, turn_id: []const u8) !void {
    const turn = try turnOf(trace, turn_id);
    try testing.expectEqual(@as(?i64, turn.turn_index), event.turn_index);
}

fn expectRow(trace: *const Trace, key: []const u8, record: ?[]const u8, line: usize) !*const Event {
    const event = try keyed(trace, key);
    try expectText(record, event.request_record);
    try testing.expectEqual(line, lineOf(trace, event));
    return event;
}

fn expectPerRequest(event: *const Event) !void {
    try expectText("per-request", event.usage_model);
    try testing.expect(!event.has_total_usage);
    try testing.expectEqual(@as(?u64, null), event.persisted_ordinal);
    try testing.expectEqual(@as(?i64, null), event.total_input_tokens);
    try testing.expectEqual(@as(?i64, null), event.total_cached_input_tokens);
    try testing.expectEqual(@as(?i64, null), event.total_output_tokens);
    try testing.expectEqual(@as(?i64, null), event.total_reasoning_output_tokens);
    try testing.expectEqual(@as(?i64, null), event.total_total_tokens);
}

fn expectQuantity(event: *const Event, want: Q) !void {
    try testing.expectEqual(@as(?i64, want.in), event.input_tokens);
    try testing.expectEqual(@as(?i64, want.cached), event.cached_input_tokens);
    try testing.expectEqual(@as(?i64, want.creation), event.cache_creation_input_tokens);
    try testing.expectEqual(@as(?i64, want.out), event.output_tokens);
    try testing.expectEqual(@as(?i64, want.total), event.total_tokens);
    try testing.expectEqual(@as(?i64, want.in), event.last_input_tokens);
    try testing.expectEqual(@as(?i64, want.cached), event.last_cached_input_tokens);
    try testing.expectEqual(@as(?i64, want.out), event.last_output_tokens);
    try testing.expectEqual(@as(?i64, want.total), event.last_total_tokens);
}

fn expectUsable(event: *const Event, finality: []const u8, want: Q) !void {
    try expectText("usable", event.quantity_state);
    try expectText(finality, event.usage_finality);
    try testing.expect(event.has_last_usage);
    try expectPerRequest(event);
    try expectQuantity(event, want);
}

fn expectNoCounters(event: *const Event) !void {
    try testing.expectEqual(@as(?i64, null), event.input_tokens);
    try testing.expectEqual(@as(?i64, null), event.cached_input_tokens);
    try testing.expectEqual(@as(?i64, null), event.cache_creation_input_tokens);
    try testing.expectEqual(@as(?i64, null), event.output_tokens);
    try testing.expectEqual(@as(?i64, null), event.reasoning_output_tokens);
    try testing.expectEqual(@as(?i64, null), event.total_tokens);
    try testing.expectEqual(@as(?i64, null), event.last_input_tokens);
    try testing.expectEqual(@as(?i64, null), event.last_output_tokens);
    try testing.expectEqual(@as(?i64, null), event.last_total_tokens);
}

fn expectUnanswered(trace: *const Trace, line: usize, record: []const u8) !void {
    const event = try unkeyedAt(trace, line);
    try expectText(record, event.request_record);
    try expectText(null, event.quantity_state);
    try expectText(null, event.usage_finality);
    try testing.expect(!event.has_last_usage);
    try expectPerRequest(event);
    try expectNoCounters(event);
}

fn expectSession(trace: *const Trace, in: ?i64, out: ?i64, total: ?i64) !void {
    try testing.expectEqual(in, trace.session.input_tokens);
    try testing.expectEqual(out, trace.session.output_tokens);
    try testing.expectEqual(total, trace.session.total_tokens);
}

fn expectTurn(trace: *const Trace, id: []const u8, in: ?i64, out: ?i64, total: ?i64) !void {
    const turn = try turnOf(trace, id);
    try testing.expectEqual(in, turn.input_tokens);
    try testing.expectEqual(out, turn.output_tokens);
    try testing.expectEqual(total, turn.total_tokens);
}

fn expectState(trace: *const Trace, key: []const u8, state: []const u8) !void {
    try expectText(state, (try keyed(trace, key)).quantity_state);
}

fn expectRecord(trace: *const Trace, key: []const u8, record: ?[]const u8) !void {
    try expectText(record, (try keyed(trace, key)).request_record);
}

const parent_id = "b1000000-0000-4000-8000-000000000001";
const child_id = "b2000000-0000-4000-8000-000000000002";
const grandchild_id = "b3000000-0000-4000-8000-000000000003";
const parent_bytes = inDir("fork-parent", parent_id);
const child_bytes = inDir("fork-child", child_id);
const grandchild_bytes =
    inDir("fork-grandchild", grandchild_id);

const q_p1: Q = q(44, 0, 40, 6, 50);
const q_p2: Q = q(53, 40, 8, 9, 62);
const q_c1: Q = q(68, 53, 9, 4, 72);
const q_g1: Q = q(79, 68, 4, 3, 82);

test "request-records: every answered request is here with normalized final usage" {
    const bytes = fixture("request-records.jsonl");
    var trace = try load("a1000000-0000-4000-8000-000000000001", bytes);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), trace.token_events.items.len);
    const first = try expectRow(&trace, "msg_rr1", "here", 3);
    try expectUsable(first, "final", q(123, 100, 20, 7, 130));
    try testing.expectEqual(@as(?i64, 2), first.reasoning_output_tokens);
    try expectText("claude-test-model", first.model);
    try expectText("standard", first.service_tier);
    try expectOwner(&trace, first, "rr-u1");
    const second = try expectRow(&trace, "msg_rr2", "here", 7);
    try expectUsable(second, "final", q(132, 120, 10, 5, 137));
    try testing.expectEqual(@as(?i64, null), second.reasoning_output_tokens);
    try expectOwner(&trace, second, "rr-u1");
    try expectSession(&trace, 255, 12, 267);
    try testing.expectEqual(@as(?i64, 220), trace.session.cached_input_tokens);
    try testing.expectEqual(@as(i64, 2), trace.session.token_usage_observation_count);
    try expectTurn(&trace, "rr-u1", 255, 12, 267);
    try testing.expectEqual(@as(?i64, 220), (try turnOf(&trace, "rr-u1")).cached_input_tokens);
}

test "fork chain: copied block is elsewhere and own requests are here" {
    var parent = try load(parent_id, parent_bytes);
    defer parent.deinit(testing.allocator);
    try expectUsable(try expectRow(&parent, "msg_p1", "here", 3), "final", q_p1);
    try expectUsable(try expectRow(&parent, "msg_p2", "here", 6), "final", q_p2);
    try testing.expectEqual(@as(usize, 2), parent.token_events.items.len);

    var child = try load(child_id, child_bytes);
    defer child.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), child.token_events.items.len);
    try expectUsable(try expectRow(&child, "msg_p1", "elsewhere", 3), "final", q_p1);
    try expectUsable(try expectRow(&child, "msg_p2", "elsewhere", 5), "final", q_p2);
    try expectUsable(try expectRow(&child, "msg_c1", "here", 8), "final", q_c1);
    try expectSession(&child, 165, 19, 184);
    try testing.expectEqual(@as(?i64, 93), child.session.cached_input_tokens);
    try testing.expectEqual(@as(i64, 3), child.session.token_usage_observation_count);

    var grandchild = try load(grandchild_id, grandchild_bytes);
    defer grandchild.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), grandchild.token_events.items.len);
    try expectUsable(try expectRow(&grandchild, "msg_p1", "elsewhere", 3), "final", q_p1);
    try expectUsable(try expectRow(&grandchild, "msg_p2", "elsewhere", 5), "final", q_p2);
    try expectUsable(try expectRow(&grandchild, "msg_c1", "elsewhere", 7), "final", q_c1);
    try expectUsable(try expectRow(&grandchild, "msg_g1", "here", 10), "final", q_g1);
    try expectSession(&grandchild, 244, 22, 266);
    try testing.expectEqual(@as(i64, 4), grandchild.session.token_usage_observation_count);
}

test "fork-no-stamp and fork-no-request: copies before own requests or with none" {
    const stamp_id = "b4000000-0000-4000-8000-000000000004";
    var stamp = try load(stamp_id, inDir("fork-no-stamp", stamp_id));
    defer stamp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), stamp.token_events.items.len);
    _ = try expectRow(&stamp, "msg_ns1", "elsewhere", 2);
    _ = try expectRow(&stamp, "msg_ns2", "here", 5);

    const none_id = "b5000000-0000-4000-8000-000000000005";
    var none = try load(none_id, inDir("fork-no-request", none_id));
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), none.token_events.items.len);
    const first = try expectRow(&none, "msg_nr1", "unplaced", 3);
    try expectUsable(first, "final", q(12, 0, 10, 3, 15));
    const second = try expectRow(&none, "msg_nr2", "unplaced", 5);
    try expectUsable(second, "final", q(16, 12, 1, 4, 20));
}

test "trimmed: preserved response is unplaced and the later request is here" {
    const id = "b6000000-0000-4000-8000-000000000006";
    var trace = try load(id, inDir("trimmed", id));
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), trace.token_events.items.len);
    const kept = try expectRow(&trace, "msg_tr1", "unplaced", 1);
    try expectUsable(kept, "final", q(15, 10, 2, 4, 19));
    const own = try expectRow(&trace, "msg_tr2", "here", 6);
    try expectUsable(own, "final", q(20, 15, 3, 5, 25));
    try expectSession(&trace, 35, 9, 44);
}

test "fork-after-compaction: preserved copies are elsewhere with iteration usage" {
    const id = "b7000000-0000-4000-8000-000000000007";
    const bytes = inDir("fork-after-compaction", id);
    var trace = try load(id, bytes);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), trace.token_events.items.len);
    const one = try expectRow(&trace, "msg_fa1", "elsewhere", 4);
    try expectUsable(one, "final", q(60, 50, 6, 9, 69));
    const two = try expectRow(&trace, "msg_fa2", "elsewhere", 5);
    try expectUsable(two, "final", q(62, 59, 2, 3, 65));
    const own = try expectRow(&trace, "msg_fa3", "here", 8);
    try expectUsable(own, "final", q(69, 62, 5, 8, 77));
    try expectOwner(&trace, one, "fa-b1");
    try expectOwner(&trace, two, "fa-b1");
    try expectOwner(&trace, own, "fa-u1");
    try expectText(null, (try turnOf(&trace, "fa-b1")).origin);
    try expectTurn(&trace, "fa-b1", 122, 12, 134);
    try expectTurn(&trace, "fa-u1", 69, 8, 77);
    try expectSession(&trace, 191, 20, 211);
}

test "compacted-untrimmed, request-gap and request-order" {
    var untrimmed = try load(
        "b8000000-0000-4000-8000-000000000008",
        fixture("compacted-untrimmed.jsonl"),
    );
    defer untrimmed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), untrimmed.token_events.items.len);
    _ = try expectRow(&untrimmed, "msg_cu1", "here", 3);
    _ = try expectRow(&untrimmed, "msg_cu2", "here", 8);

    var gap = try load(
        "b9000000-0000-4000-8000-000000000009",
        fixture("request-gap.jsonl"),
    );
    defer gap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), gap.token_events.items.len);
    _ = try expectRow(&gap, "msg_g1", "here", 3);
    const unmatched = try expectRow(&gap, "msg_g2", "unplaced", 5);
    try expectUsable(unmatched, "final", q(7, 5, 1, 3, 10));
    _ = try expectRow(&gap, "msg_g3", "here", 8);

    var order = try load(
        "ba000000-0000-4000-8000-00000000000a",
        fixture("request-order.jsonl"),
    );
    defer order.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), order.token_events.items.len);
    _ = try expectRow(&order, "msg_o1", "unplaced", 2);
    _ = try expectRow(&order, "msg_o2", "here", 6);
}

test "request-link-conflict: inconsistent links are unplaced and stay countable" {
    const id = "bb000000-0000-4000-8000-00000000000b";
    var trace = try load(id, inDir("request-link-conflict", id));
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 9), trace.token_events.items.len);
    try testing.expectEqual(@as(usize, 0), unkeyedCount(&trace));
    const same = q(5, 0, 4, 2, 7);
    const conflicts = [_]struct { []const u8, usize }{
        .{ "msg_m1", 3 },  .{ "msg_m2", 8 },  .{ "msg_m3", 11 }, .{ "msg_m4", 14 },
        .{ "msg_m5", 16 }, .{ "msg_m6", 20 }, .{ "msg_m7", 22 }, .{ "msg_m9", 25 },
    };
    for (conflicts) |case| {
        try expectUsable(try expectRow(&trace, case[0], "unplaced", case[1]), "final", same);
    }
    try expectUsable(try expectRow(&trace, "msg_m8", "here", 28), "final", same);
}

const version_tail = "-0000-4000-8000-00000000000c";

test "request-version: inferred elsewhere needs a usable version of at least 2.1.319" {
    const Case = struct { []const u8, []const u8, []const u8 };
    const cases = [_]Case{
        .{ "bc000001" ++ version_tail, fixture("request-version/v-current.jsonl"), "elsewhere" },
        .{ "bc000002" ++ version_tail, fixture("request-version/v-old.jsonl"), "unplaced" },
        .{ "bc000003" ++ version_tail, fixture("request-version/v-missing.jsonl"), "unplaced" },
        .{ "bc000004" ++ version_tail, fixture("request-version/v-malformed.jsonl"), "unplaced" },
    };
    for (cases) |case| {
        var trace = try load(case[0], case[1]);
        defer trace.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), trace.token_events.items.len);
        _ = try expectRow(&trace, "msg_v0", case[2], 2);
        _ = try expectRow(&trace, "msg_v1", "here", 5);
    }
    var here = try load(
        "bc000005-0000-4000-8000-00000000000c",
        fixture("request-version/v-here-without-version.jsonl"),
    );
    defer here.deinit(testing.allocator);
    _ = try expectRow(&here, "msg_vh1", "here", 3);
    var bare = try load(
        "bc000006-0000-4000-8000-00000000000c",
        fixture("request-version/v-no-reference.jsonl"),
    );
    defer bare.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), bare.token_events.items.len);
    const row = try expectRow(&bare, "msg_vn1", null, 2);
    try expectUsable(row, "final", q(4, 0, 3, 2, 6));
}

test "unanswered-request: attempts are null-key diagnostics dated by their records" {
    const id = "bd000000-0000-4000-8000-00000000000d";
    var trace = try load(id, inDir("unanswered-request", id));
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), trace.token_events.items.len);
    try testing.expectEqual(@as(usize, 2), unkeyedCount(&trace));
    const first = try expectRow(&trace, "msg_ua1", "here", 3);
    try expectUsable(first, "final", q(22, 0, 20, 3, 25));
    const resent = try expectRow(&trace, "msg_ua2", "here", 7);
    try expectUsable(resent, "final", q(29, 22, 4, 5, 34));
    try expectUnanswered(&trace, 5, "here");
    try expectUnanswered(&trace, 9, "here");
    const dropped = try unkeyedAt(&trace, 5);
    const failed = try unkeyedAt(&trace, 9);
    try expectText("2026-11-01T17:00:04.000Z", timestampOf(&trace, dropped));
    try expectText("2026-11-01T17:00:08.000Z", timestampOf(&trace, failed));
    try expectSession(&trace, 51, 8, 59);
    try testing.expectEqual(@as(i64, 2), trace.session.token_usage_observation_count);
}

test "missing-message-id: invalid response diagnostic beside an unanswered request" {
    const id = "be000000-0000-4000-8000-00000000000e";
    var trace = try load(id, inDir("missing-message-id", id));
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), trace.token_events.items.len);
    try testing.expect(trace.warnings.items.len >= 1);
    const answered = try expectRow(&trace, "msg_mm0", "here", 3);
    try expectUsable(answered, "final", q(12, 0, 10, 4, 16));
    const invalid = try unkeyedAt(&trace, 6);
    try expectText("invalid", invalid.quantity_state);
    try expectText(null, invalid.usage_finality);
    try expectText("here", invalid.request_record);
    try testing.expect(invalid.has_last_usage);
    try expectPerRequest(invalid);
    try expectNoCounters(invalid);
    try expectOwner(&trace, invalid, "mm-u1");
    try expectUnanswered(&trace, 8, "here");
    try expectSession(&trace, null, null, null);
    try expectTurn(&trace, "mm-u1", null, null, null);
}

test "token-row-flags: usage-object presence sets has_last_usage for every row kind" {
    const id = "bf000000-0000-4000-8000-00000000000f";
    var trace = try load(id, inDir("token-row-flags", id));
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), trace.token_events.items.len);
    for (trace.token_events.items) |*event| try expectPerRequest(event);
    const plain = try expectRow(&trace, "msg_tf1", "here", 3);
    try expectUsable(plain, "final", q(1, 0, 0, 2, 3));
    const absent = try expectRow(&trace, "msg_tf2", "here", 6);
    try testing.expect(!absent.has_last_usage);
    try expectText("missing", absent.quantity_state);
    try expectText("final", absent.usage_finality);
    try expectNoCounters(absent);
    const negative = try expectRow(&trace, "msg_tf3", "here", 9);
    try testing.expect(negative.has_last_usage);
    try expectText("invalid", negative.quantity_state);
    const bare = try unkeyedAt(&trace, 11);
    try testing.expect(!bare.has_last_usage);
    try expectText("invalid", bare.quantity_state);
    try expectText(null, bare.request_record);
    const counted = try unkeyedAt(&trace, 13);
    try testing.expect(counted.has_last_usage);
    try expectText("invalid", counted.quantity_state);
    try expectNoCounters(counted);
    try expectUnanswered(&trace, 15, "here");
}

test "request-turn-owner: the first physical response owns the request row" {
    const bytes = fixture("request-turn-owner/owner.jsonl");
    var trace = try load("c1000000-0000-4000-8000-000000000011", bytes);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), trace.token_events.items.len);
    const shared = try expectRow(&trace, "msg_owk", null, 4);
    try expectUsable(shared, "final", q(10, 0, 0, 100, 110));
    try expectOwner(&trace, shared, "ow-u1");
    const rewritten = try turnOf(&trace, "ow-u1r");
    try testing.expect(rewritten.turn_index != (try turnOf(&trace, "ow-u1")).turn_index);
    try expectOwner(&trace, try expectRow(&trace, "msg_oww", null, 7), "ow-u1r");
    try expectOwner(&trace, try expectRow(&trace, "msg_ow0", null, 2), "ow-u0");
    const side = try expectRow(&trace, "msg_sc1", null, 9);
    try testing.expectEqual(@as(?i64, null), side.turn_index);
    try expectUsable(side, "final", q(7, 0, 0, 3, 10));
    try expectTurn(&trace, "ow-u0", 5, 2, 7);
    try expectTurn(&trace, "ow-u1", 10, 100, 110);
    try expectTurn(&trace, "ow-u1r", 1, 1, 2);
    try expectSession(&trace, 23, 106, 129);
}

test "request-turn-owner: legacy observation compatibility" {
    const bytes = fixture("request-turn-owner/legacy-compat.jsonl");
    var trace = try load("c2000000-0000-4000-8000-000000000012", bytes);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), trace.token_events.items.len);
    try expectState(&trace, "msg_fp", "invalid");
    try expectState(&trace, "msg_ff", "invalid");
    try expectState(&trace, "msg_in", "invalid");
    const same = q(4, 0, 0, 10, 14);
    const growing = try expectRow(&trace, "msg_pp", null, 8);
    try expectUsable(growing, "provisional", same);
    try expectOwner(&trace, growing, "c-u3");
    const replayed = try expectRow(&trace, "msg_pq", null, 11);
    try expectUsable(replayed, "provisional", same);
    try expectOwner(&trace, replayed, "c-u4");
    try expectSession(&trace, null, null, null);
}

test "empty-stop-reason: an empty string reason is provisional and compatible" {
    const bytes = fixture("empty-stop-reason.jsonl");
    var trace = try load("c3000000-0000-4000-8000-000000000013", bytes);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), trace.token_events.items.len);
    const row = try expectRow(&trace, "msg_es", null, 2);
    try expectUsable(row, "provisional", q(6, 0, 0, 10, 16));
    try expectOwner(&trace, row, "es-u1");
}

test "request-finality: any recorded non-empty reason finalizes request usage" {
    const bytes = fixture("request-finality.jsonl");
    var trace = try load("c4000000-0000-4000-8000-000000000014", bytes);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 7), trace.token_events.items.len);
    const Case = struct { []const u8, ?[]const u8, usize, []const u8, Q };
    const cases = [_]Case{
        .{ "msg_rf1", "here", 3, "final", q(3, 0, 2, 3, 6) },
        .{ "msg_rf2", "here", 6, "final", q(4, 2, 1, 4, 8) },
        .{ "msg_rf3", "here", 8, "final", q(5, 3, 1, 5, 10) },
        .{ "msg_rf4", "here", 11, "provisional", q(6, 4, 1, 6, 12) },
        .{ "msg_rf5", "here", 14, "provisional", q(7, 5, 1, 7, 14) },
        .{ "msg_rf6", null, 16, "provisional", q(8, 6, 1, 8, 16) },
        .{ "msg_rf7", null, 18, "provisional", q(9, 7, 1, 9, 18) },
    };
    for (cases) |case| {
        try expectUsable(try expectRow(&trace, case[0], case[1], case[2]), case[3], case[4]);
    }
}

test "legacy-stream: no references, last snapshot usage, provisional without a reason" {
    const bytes = fixture("legacy-stream.jsonl");
    var trace = try load("c5000000-0000-4000-8000-000000000015", bytes);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), trace.token_events.items.len);
    const stream = try expectRow(&trace, "msg_ls1", null, 2);
    try expectUsable(stream, "provisional", q(108, 100, 0, 15, 123));
    try expectOwner(&trace, stream, "ls-u1");
    const ended = try expectRow(&trace, "msg_ls2", null, 6);
    try expectUsable(ended, "final", q(3, 0, 0, 9, 12));
}

test "legacy copies: each holder emits one row per request with the same usage" {
    const q1: Q = q(4, 0, 0, 6, 10);
    const q2: Q = q(5, 0, 0, 7, 12);
    var a = try load("c6000000-0000-4000-8000-000000000016", fixture("legacy-copy-a.jsonl"));
    defer a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), a.token_events.items.len);
    try expectUsable(try expectRow(&a, "msg_lc1", null, 2), "final", q1);
    try expectUsable(try expectRow(&a, "msg_lc2", null, 4), "final", q2);
    try expectSession(&a, 9, 13, 22);
    var b = try load("c7000000-0000-4000-8000-000000000017", fixture("legacy-copy-b.jsonl"));
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), b.token_events.items.len);
    try expectUsable(try expectRow(&b, "msg_lc1", null, 2), "final", q1);
    try expectUsable(try expectRow(&b, "msg_lc2", null, 4), "final", q2);
    const own = try expectRow(&b, "msg_lc3", null, 6);
    try expectUsable(own, "final", q(6, 0, 0, 8, 14));
    try expectSession(&b, 15, 21, 36);
}

test "iterations: message and compaction entries sum; reasoning needs whole coverage" {
    const bytes = fixture("iterations.jsonl");
    var trace = try load("c8000000-0000-4000-8000-000000000018", bytes);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), trace.token_events.items.len);
    const mixed = try expectRow(&trace, "msg_it1", "here", 3);
    try expectUsable(mixed, "final", q(30, 0, 0, 12, 42));
    try testing.expectEqual(@as(?i64, null), mixed.reasoning_output_tokens);
    const compaction = try expectRow(&trace, "msg_it2", "here", 6);
    try expectUsable(compaction, "final", q(40, 0, 0, 6, 46));
    try testing.expectEqual(@as(?i64, null), compaction.reasoning_output_tokens);
    try expectState(&trace, "msg_it3", "invalid");
    const message = try expectRow(&trace, "msg_it4", "here", 12);
    try expectUsable(message, "final", q(8, 0, 0, 4, 12));
    try testing.expectEqual(@as(?i64, 2), message.reasoning_output_tokens);
    try expectTurn(&trace, "it-u1", 30, 12, 42);
    try expectTurn(&trace, "it-u3", null, null, null);
    try expectSession(&trace, null, null, null);
}

test "unsupported-iterations and quantity-validation" {
    const unsupported_id = "c9000000-0000-4000-8000-000000000019";
    var unsupported = try load(unsupported_id, inDir("unsupported-iterations", unsupported_id));
    defer unsupported.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), unsupported.token_events.items.len);
    for ([_][]const u8{ "msg_ua", "msg_uf", "msg_uk", "msg_um" }) |key| {
        try expectState(&unsupported, key, "unsupported");
        try expectRecord(&unsupported, key, "here");
    }
    const fine = try keyed(&unsupported, "msg_uok");
    try expectUsable(fine, "final", q(5, 0, 0, 2, 7));
    try expectSession(&unsupported, null, null, null);

    const quantity_id = "ca000000-0000-4000-8000-00000000001a";
    var quantity = try load(quantity_id, inDir("quantity-validation", quantity_id));
    defer quantity.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), quantity.token_events.items.len);
    for ([_][]const u8{ "msg_qn", "msg_qf", "msg_qo", "msg_qc" }) |key| {
        try expectState(&quantity, key, "invalid");
    }
    const ok = try expectRow(&quantity, "msg_qk", "here", 16);
    try expectUsable(ok, "final", q(6, 2, 3, 4, 10));
    try expectSession(&quantity, null, null, null);
}

const shared_ref_id = "cb000000-0000-4000-8000-00000000001b";
const shared_ref_bytes =
    \\{"type":"user","uuid":"sr-u1","parentUuid":null,"isSidechain":false,"sessionId":"cb000000-0000-4000-8000-00000000001b","timestamp":"2026-11-01T19:00:00.000Z","cwd":"/tmp/fx-proj","version":"2.1.325","message":{"role":"user","content":"Do the task."},"turnOrigin":"human"}
    \\{"type":"api-request","id":"rq-s","sessionId":"cb000000-0000-4000-8000-00000000001b","timestamp":"2026-11-01T19:00:01.000Z","version":"2.1.325"}
    \\{"type":"assistant","uuid":"sr-a1","parentUuid":"sr-u1","isSidechain":false,"sessionId":"cb000000-0000-4000-8000-00000000001b","timestamp":"2026-11-01T19:00:02.000Z","cwd":"/tmp/fx-proj","version":"2.1.325","message":{"model":"claude-test-model","type":"message","role":"assistant","id":"msg_s1","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":4,"output_tokens":2},"content":[{"type":"text","text":"One."}]},"requestRef":"rq-s","apiBlockIndex":0}
    \\{"type":"assistant","uuid":"sr-a2","parentUuid":"sr-a1","isSidechain":false,"sessionId":"cb000000-0000-4000-8000-00000000001b","timestamp":"2026-11-01T19:00:02.000Z","cwd":"/tmp/fx-proj","version":"2.1.325","message":{"model":"claude-test-model","type":"message","role":"assistant","id":"msg_s1","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":4,"output_tokens":2},"content":[{"type":"text","text":"Two."}]},"apiBlockIndex":1}
    \\{"type":"user","uuid":"sr-u2","parentUuid":"sr-a2","isSidechain":false,"sessionId":"cb000000-0000-4000-8000-00000000001b","timestamp":"2026-11-01T19:00:03.000Z","cwd":"/tmp/fx-proj","version":"2.1.325","message":{"role":"user","content":"Again."},"turnOrigin":"human"}
    \\{"type":"assistant","uuid":"sr-a3","parentUuid":"sr-u2","isSidechain":false,"sessionId":"cb000000-0000-4000-8000-00000000001b","timestamp":"2026-11-01T19:00:04.000Z","cwd":"/tmp/fx-proj","version":"2.1.325","message":{"model":"claude-test-model","type":"message","role":"assistant","id":"msg_s2","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":4,"output_tokens":2},"content":[{"type":"text","text":"Three."}]},"requestRef":"rq-s","apiBlockIndex":0}
    \\
;

test "shared request ref: a mixed earlier message still unplaces a consistent holder" {
    var trace = try load(shared_ref_id, shared_ref_bytes);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), trace.token_events.items.len);
    const same = q(5, 0, 4, 2, 7);
    try expectUsable(try expectRow(&trace, "msg_s1", "unplaced", 3), "final", same);
    try expectUsable(try expectRow(&trace, "msg_s2", "unplaced", 6), "final", same);
}
