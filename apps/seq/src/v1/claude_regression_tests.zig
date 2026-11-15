const std = @import("std");
const trace_core = @import("trace_core");
const support = @import("claude_fixture_support.zig");
const native = @import("native.zig");
const trace_adapter = @import("trace_adapter.zig");

const testing = std.testing;
const allocator = testing.allocator;
const Trace = trace_core.CanonicalSessionTrace;
const twin_root = "7f000000-0000-4000-8000-000000000001";
const twin_worker = "agent-a7f0000000000001";

fn twinFiles() [5]support.TreeFile {
    const base = "fixtures/claude/twin/";
    const root = "claude/proj/" ++ twin_root ++ ".jsonl";
    const worker = "claude/proj/" ++ twin_root ++ "/subagents/" ++ twin_worker;
    return .{
        .{ .path = root, .bytes = @embedFile(base ++ root) },
        .{ .path = worker ++ ".jsonl", .bytes = @embedFile(base ++ worker ++ ".jsonl") },
        .{ .path = worker ++ ".meta.json", .bytes = @embedFile(base ++ worker ++ ".meta.json") },
        .{ .path = "codex/root.jsonl", .bytes = @embedFile(base ++ "codex/root.jsonl") },
        .{ .path = "codex/worker.jsonl", .bytes = @embedFile(base ++ "codex/worker.jsonl") },
    };
}

fn parseIn(dir: std.Io.Dir, path: []const u8) !Trace {
    return trace_core.parseSessionTrace(testing.io, dir, allocator, path, support.options());
}

fn expectOptional(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected == null or actual == null) {
        return testing.expect(expected == null and actual == null);
    }
    try testing.expectEqualStrings(expected.?, actual.?);
}

fn visibleRows(
    trace: *const Trace,
    rows: *std.ArrayList(*const trace_core.TraceOccurrence),
) !void {
    for (trace.occurrences.items) |*row| {
        if (row.message_visible) try rows.append(allocator, row);
    }
}

fn expectSameMessages(left: *const Trace, right: *const Trace) !void {
    var left_rows: std.ArrayList(*const trace_core.TraceOccurrence) = .empty;
    defer left_rows.deinit(allocator);
    var right_rows: std.ArrayList(*const trace_core.TraceOccurrence) = .empty;
    defer right_rows.deinit(allocator);
    try visibleRows(left, &left_rows);
    try visibleRows(right, &right_rows);
    try testing.expectEqual(left_rows.items.len, right_rows.items.len);
    for (left_rows.items, right_rows.items) |a, b| {
        try expectOptional(a.role, b.role);
        try expectOptional(a.text, b.text);
    }
}

fn expectSameTurns(left: *const Trace, right: *const Trace) !void {
    try testing.expectEqual(left.turns.items.len, right.turns.items.len);
    for (left.turns.items, right.turns.items) |a, b| {
        try testing.expectEqual(a.status, b.status);
        try expectOptional(a.final_answer, b.final_answer);
        try expectOptional(a.user_message, b.user_message);
        try expectOptional(a.reasoning_effort, b.reasoning_effort);
    }
}

fn expectSameTools(left: *const Trace, right: *const Trace) !void {
    try testing.expectEqual(left.tools.items.len, right.tools.items.len);
    for (left.tools.items, right.tools.items) |a, b| {
        try testing.expectEqual(a.kind, b.kind);
        try testing.expectEqual(a.lifecycle_status, b.lifecycle_status);
        try expectOptional(a.call_id, b.call_id);
        try expectOptional(a.command_text, b.command_text);
        try expectOptional(a.output_text, b.output_text);
    }
}

test "twins: Claude and Codex give the same conversation, answers, tools and parentage" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = twinFiles();
    try support.writeTree(tmp.dir, &files);
    var claude_root = try parseIn(tmp.dir, files[0].path);
    defer claude_root.deinit(allocator);
    var codex_root = try parseIn(tmp.dir, files[3].path);
    defer codex_root.deinit(allocator);
    const answer = claude_root.turns.items[0].final_answer.?;
    try testing.expectEqualStrings("There are two files: a and b.", answer);
    try expectSameMessages(&claude_root, &codex_root);
    try expectSameTurns(&claude_root, &codex_root);
    try expectSameTools(&claude_root, &codex_root);
    var claude_worker = try parseIn(tmp.dir, files[1].path);
    defer claude_worker.deinit(allocator);
    var codex_worker = try parseIn(tmp.dir, files[4].path);
    defer codex_worker.deinit(allocator);
    try expectSameMessages(&claude_worker, &codex_worker);
    try expectSameTurns(&claude_worker, &codex_worker);
    try expectOptional(claude_worker.session.control_parent_session_id, twin_root);
    try expectOptional(codex_worker.session.control_parent_session_id, twin_root);
}

const neutral_prefix =
    \\{"type":"vendor-note","note":"x"}
    \\{"type":"session_meta","payload":{"id":"late"}}
    \\{"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}
    \\
;

fn discover(dir: std.Io.Dir, path: []const u8) !trace_adapter.SessionIdentity {
    return trace_adapter.discoverSessionIdentity(testing.io, dir, allocator, path, .{}, null);
}

test "discovery: a neutral first record before Codex records classifies as the body does" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try support.writeTree(tmp.dir, &.{
        .{ .path = "neutral.jsonl", .bytes = neutral_prefix },
        .{ .path = "opencode/prompt-history.jsonl", .bytes = "{\"input\":\"hello\"}\n" },
    });
    var neutral = try discover(tmp.dir, "neutral.jsonl");
    defer neutral.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.codex, neutral.source);
    var body = try parseIn(tmp.dir, "neutral.jsonl");
    defer body.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.codex, body.source);
    var opencode = try discover(tmp.dir, "opencode/prompt-history.jsonl");
    defer opencode.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.none, opencode.source);
}

const allow_list_source =
    \\{"type":"user","uuid":"p1","parentUuid":null,"sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:00Z","turnOrigin":"human","secretTop":"SECRET-TOP","message":{"role":"user","content":[{"type":"image","source":"SECRET-IMAGE"},{"type":"text","text":"hi","extra":"SECRET-EXTRA"}]}}
    \\{"type":"assistant","uuid":"p2","parentUuid":"p1","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","message":{"id":"m","role":"assistant","model":"x","stop_reason":"end_turn","secret":"SECRET-MESSAGE","usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1,"server_tool_use":{"note":"SECRET-USAGE"}},"content":[{"type":"thinking","thinking":"SECRET-THINKING"},{"type":"server_tool_use","id":"x","input":"SECRET-SERVER"},{"type":"text","text":"ok"}]}}
    \\{"type":"attachment","uuid":"p3","parentUuid":"p2","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:02Z","attachment":{"type":"hook","data":"SECRET-ATTACHMENT"}}
    \\
;

test "payloads: only modeled fields, blocks and usage counters are exposed" {
    var trace = try support.parse(allocator, "allow.jsonl", allow_list_source, .stale);
    defer trace.deinit(allocator);
    for (trace.occurrences.items) |occurrence| {
        const payload = occurrence.payload_json orelse continue;
        try testing.expect(std.mem.indexOf(u8, payload, "SECRET") == null);
    }
    try testing.expectEqualStrings("hi", trace.occurrences.items[0].text.?);
    try testing.expect(trace.occurrences.items[2].event_type == null);
}

const prompt_line =
    \\{"type":"user","uuid":"q1","parentUuid":null,"sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:00Z","turnOrigin":"human","message":{"role":"user","content":"go"}}
    \\
;

const tool_source = prompt_line ++
    \\{"type":"assistant","uuid":"q2","parentUuid":"q1","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","message":{"id":"m1","role":"assistant","model":"x","stop_reason":"tool_use","content":[{"type":"tool_use","id":"c1","name":"Bash","input":{"command":"ls"}}]}}
    \\{"type":"user","uuid":"q3","parentUuid":"q2","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"c1","content":"a"}]}}
    \\
;

test "tools: Claude output parts report process_results as an array" {
    var trace = try support.parse(allocator, "tools.jsonl", tool_source, .stale);
    defer trace.deinit(allocator);
    const parts = trace.tools.items[0].output_parts_json.?;
    try testing.expect(std.mem.indexOf(u8, parts, "\"process_results\":[]") != null);
}

const sidechain_duplicate = prompt_line ++
    \\{"type":"user","uuid":"q1","parentUuid":null,"sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","isSidechain":true,"message":{"role":"user","content":"side"}}
    \\
;

test "warnings: a uuid reused by an inline sidechain record is diagnosed" {
    var trace = try support.parse(allocator, "dup.jsonl", sidechain_duplicate, .stale);
    defer trace.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), trace.warnings.items.len);
}

const pending_text = prompt_line ++
    \\{"type":"assistant","uuid":"q2","parentUuid":"q1","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","message":{"id":"m1","role":"assistant","model":"x","stop_reason":null,"content":[{"type":"text","text":"running"},{"type":"tool_use","id":"c1","name":"Bash","input":{"command":"ls"}}]}}
    \\
;

test "turns: legacy text that also declares a pending call stays unfinished" {
    var trace = try support.parse(allocator, "pending.jsonl", pending_text, .stale);
    defer trace.deinit(allocator);
    try testing.expectEqual(trace_core.TurnStatus.aborted, trace.turns.items[0].status);
    try testing.expectEqualStrings("stale_ongoing_file", trace.turns.items[0].status_reason.?);
}

const keyed_conflict = prompt_line ++
    \\{"type":"assistant","uuid":"q2","parentUuid":"q1","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","apiBlockIndex":0,"message":{"id":"m1","role":"assistant","model":"x","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"alpha"}]}}
    \\{"type":"assistant","uuid":"q3","parentUuid":"q2","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","apiBlockIndex":0,"message":{"id":"m1","role":"assistant","model":"x","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"beta"}]}}
    \\{"type":"assistant","uuid":"q4","parentUuid":"q3","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","apiBlockIndex":1,"message":{"id":"m1","role":"assistant","model":"x","stop_reason":"end_turn","content":[{"type":"text","text":"answer"}]}}
    \\
;

const mixed_conflict = prompt_line ++
    \\{"type":"assistant","uuid":"q2","parentUuid":"q1","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","apiBlockIndex":0,"message":{"id":"m1","role":"assistant","model":"x","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"alpha"}]}}
    \\{"type":"assistant","uuid":"q3","parentUuid":"q2","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","apiBlockIndex":0,"message":{"id":"m1","role":"assistant","model":"x","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"beta"}]}}
    \\{"type":"assistant","uuid":"q4","parentUuid":"q3","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","message":{"id":"m1","role":"assistant","model":"x","stop_reason":"end_turn","content":[{"type":"text","text":"answer"}]}}
    \\
;

const agreeing_keys = prompt_line ++
    \\{"type":"assistant","uuid":"q2","parentUuid":"q1","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","apiBlockIndex":0,"message":{"id":"m1","role":"assistant","model":"x","stop_reason":"end_turn","content":[{"type":"text","text":"answer"}]}}
    \\{"type":"assistant","uuid":"q3","parentUuid":"q2","sessionId":"s","cwd":"/w","timestamp":"2026-11-01T00:00:01Z","apiBlockIndex":0,"message":{"id":"m1","role":"assistant","model":"x","stop_reason":"end_turn","content":[{"type":"text","text":"answer"}]}}
    \\
;

test "answers: one block index with different content voids the answer, keyed or mixed" {
    for ([_][]const u8{ keyed_conflict, mixed_conflict }) |source| {
        var trace = try support.parse(allocator, "conflict.jsonl", source, .stale);
        defer trace.deinit(allocator);
        try testing.expect(trace.turns.items[0].final_answer == null);
    }
    var trace = try support.parse(allocator, "agree.jsonl", agreeing_keys, .stale);
    defer trace.deinit(allocator);
    try testing.expectEqualStrings("answer", trace.turns.items[0].final_answer.?);
}

const underscore_kinds = prompt_line ++
    \\{"type":"api_request","id":"r","sessionId":"s","timestamp":"2026-11-01T00:00:01Z"}
    \\{"type":"custom_title","customTitle":"wrong","sessionId":"s"}
    \\
;

test "record kinds: underscore spellings stay unknown and private" {
    var trace = try support.parse(allocator, "kinds.jsonl", underscore_kinds, .stale);
    defer trace.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), trace.token_events.items.len);
    try testing.expect(trace.session.thread_name == null);
    try testing.expect(trace.occurrences.items[1].private and trace.occurrences.items[2].private);
}

const worker_root = "d0000000-0000-4000-8000-000000000001";
const worker_base = "fixtures/claude/worker/proj/";
const worker_name = worker_root ++ "/subagents/agent-a1b2c3d4e5f600001";

fn workerTree() [3]support.TreeFile {
    const root = worker_root ++ ".jsonl";
    return .{
        .{ .path = "proj/" ++ root, .bytes = @embedFile(worker_base ++ root) },
        .{
            .path = "proj/" ++ worker_name ++ ".jsonl",
            .bytes = @embedFile(worker_base ++ worker_name ++ ".jsonl"),
        },
        .{
            .path = "proj/" ++ worker_name ++ ".meta.json",
            .bytes = @embedFile(worker_base ++ worker_name ++ ".meta.json"),
        },
    };
}

test "discovery facts: a body parse reuses supplied facts instead of rereading the sidecar" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = workerTree();
    try support.writeTree(tmp.dir, &files);
    var supplied = trace_core.claude_parser.Discovery{ .sidecar = .parsed, .parent_present = true };
    var parent = "zz00000000000001".*;
    supplied.parent_agent = &parent;
    var options = support.options();
    options.claude_discovery = &supplied;
    const path = files[1].path;
    var trace = try trace_core.parseSessionTrace(testing.io, tmp.dir, allocator, path, options);
    defer trace.deinit(allocator);
    try testing.expectEqualStrings(
        worker_root ++ "/agent-zz00000000000001",
        trace.session.control_parent_session_id.?,
    );
    try testing.expectEqual(@as(usize, 0), trace.claude_discovery_bytes);
    var fresh = try parseIn(tmp.dir, path);
    defer fresh.deinit(allocator);
    try testing.expectEqualStrings(worker_root, fresh.session.control_parent_session_id.?);
    try testing.expect(fresh.claude_discovery_bytes > 0);
}

test "spawn edges: summary and full parses count the same admitted spawns" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = workerTree();
    try support.writeTree(tmp.dir, &files);
    var full = try parseIn(tmp.dir, files[0].path);
    defer full.deinit(allocator);
    var summary = try trace_core.parseSessionSummaryTrace(
        testing.io,
        tmp.dir,
        allocator,
        files[0].path,
        support.options(),
    );
    defer summary.deinit(allocator);
    const counted = summary.session.spawned_worker_count;
    try testing.expectEqual(full.session.spawned_worker_count, counted);
    try testing.expectEqual(@as(i64, 1), counted);
}

fn renderGraph(dir: std.Io.Dir, root: []const u8) ![]u8 {
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const argv = [_][]const u8{ "--root", root, "--format", "dot" };
    _ = try native.run(
        allocator,
        &environment,
        .session_graph,
        &argv,
        &output.writer,
        testing.io,
        dir,
        null,
    );
    return allocator.dupe(u8, output.written());
}

test "session graph: agreeing spawner and sidecar assertions render one edge" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = workerTree();
    try support.writeTree(tmp.dir, &files);
    const root = try tmp.dir.realPathFileAlloc(testing.io, "proj", allocator);
    defer allocator.free(root);
    const text = try renderGraph(tmp.dir, root);
    defer allocator.free(text);
    const worker = worker_root ++ "/agent-a1b2c3d4e5f600001";
    const edge = "\"" ++ worker_root ++ "\" -> \"" ++ worker ++ "\";\n";
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, edge));
    try testing.expect(std.mem.indexOf(u8, text, "contradiction") == null);
}

fn setModified(dir: std.Io.Dir, path: []const u8, seconds: i64) !void {
    const file = try dir.openFile(testing.io, path, .{ .mode = .read_write });
    defer file.close(testing.io);
    const stamp: std.Io.Timestamp = .{ .nanoseconds = @as(i96, seconds) * std.time.ns_per_s };
    try file.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = stamp } });
}

const untimed_transcript =
    \\{"type":"summary","summary":"s","leafUuid":"x"}
    \\
;

test "time pruning: since never prunes a Claude file without a prefix timestamp" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const untimed = "projects/p/e0000000-0000-4000-8000-000000000001.jsonl";
    const timed = "projects/p/e0000000-0000-4000-8000-000000000002.jsonl";
    try support.writeTree(tmp.dir, &.{
        .{ .path = untimed, .bytes = untimed_transcript },
        .{ .path = timed, .bytes = prompt_line },
    });
    try setModified(tmp.dir, untimed, 1_600_000_000);
    try setModified(tmp.dir, timed, 1_600_000_000);
    const config = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(config);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("CLAUDE_CONFIG_DIR", config);
    var reads = native.DiscoveryReads{};
    var paths = try native.resolveTargetPaths(allocator, testing.io, tmp.dir, .{
        .source = .claude_code,
        .since_ms = 1_790_000_000_000,
        .environment = &environment,
        .discovery_reads = &reads,
    }, false);
    defer native.freePaths(allocator, &paths);
    try testing.expectEqual(@as(usize, 1), paths.items.len);
    try testing.expect(std.mem.endsWith(u8, paths.items[0], untimed));
    try testing.expectEqual(@as(usize, 2), reads.opened);
    try testing.expect(reads.bytes > 0);
}
