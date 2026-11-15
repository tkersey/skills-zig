const std = @import("std");
const trace_core = @import("trace_core");
const support = @import("claude_fixture_support.zig");
const native = @import("native.zig");
const trace_adapter = @import("trace_adapter.zig");

const testing = std.testing;
const allocator = testing.allocator;
const Trace = trace_core.CanonicalSessionTrace;
const fixture_root = "fixtures/claude/";

fn embedTree(
    comptime base: []const u8,
    comptime names: []const []const u8,
) [names.len]support.TreeFile {
    var files: [names.len]support.TreeFile = undefined;
    inline for (names, 0..) |name, index| {
        files[index] = .{ .path = name, .bytes = @embedFile(fixture_root ++ base ++ name) };
    }
    return files;
}

fn parseFixture(comptime name: []const u8, path: []const u8) !Trace {
    return support.parse(allocator, path, @embedFile(fixture_root ++ name), .stale);
}

fn parseFile(dir: std.Io.Dir, path: []const u8) !Trace {
    return trace_core.parseSessionTrace(testing.io, dir, allocator, path, support.options());
}

fn expectString(expected: []const u8, actual: ?[]const u8) !void {
    try testing.expect(actual != null);
    try testing.expectEqualStrings(expected, actual.?);
}

fn contains(haystack: ?[]const u8, needle: []const u8) bool {
    const text = haystack orelse return false;
    return std.mem.indexOf(u8, text, needle) != null;
}

fn findTool(trace: *const Trace, call_id: []const u8) ?*const trace_core.ToolLifecycleRecord {
    for (trace.tools.items) |*tool| {
        if (tool.call_id) |id| if (std.mem.eql(u8, id, call_id)) return tool;
    }
    return null;
}

fn visibleCount(trace: *const Trace, role: []const u8) usize {
    var count: usize = 0;
    for (trace.occurrences.items) |occurrence| {
        if (!occurrence.message_visible or occurrence.text == null) continue;
        const actual = occurrence.role orelse continue;
        if (std.mem.eql(u8, actual, role)) count += 1;
    }
    return count;
}

fn visibleWith(trace: *const Trace, needle: []const u8) ?*const trace_core.TraceOccurrence {
    for (trace.occurrences.items) |*occurrence| {
        if (!occurrence.message_visible or occurrence.role == null) continue;
        if (contains(occurrence.text, needle)) return occurrence;
    }
    return null;
}

fn occurrenceAt(trace: *const Trace, line: usize) *const trace_core.TraceOccurrence {
    for (trace.occurrences.items) |*occurrence| {
        if (occurrence.line_number == line) return occurrence;
    }
    @panic("missing occurrence");
}

fn exposes(trace: *const Trace, needle: []const u8) bool {
    for (trace.occurrences.items) |occurrence| {
        if (contains(occurrence.payload_json, needle) or contains(occurrence.text, needle)) {
            return true;
        }
    }
    for (trace.turns.items) |turn| {
        if (contains(turn.final_answer, needle) or contains(turn.user_message, needle)) {
            return true;
        }
    }
    return false;
}

fn withoutLines(bytes: []const u8, needle: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.indexOf(u8, line, needle) != null) continue;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn swapFirstAndLast(bytes: []const u8) ![]u8 {
    const first_end = std.mem.indexOfScalar(u8, bytes, '\n').? + 1;
    const trimmed = std.mem.trimEnd(u8, bytes, "\n");
    const last_start = std.mem.lastIndexOfScalar(u8, trimmed, '\n').? + 1;
    return std.mem.concat(allocator, u8, &.{
        trimmed[last_start..],
        "\n",
        bytes[first_end..last_start],
        bytes[0..first_end],
    });
}

const session_id = "5e551000-0000-4000-8000-000000000001";
const session_path = "projects/-work-alpha/" ++ session_id ++ ".jsonl";

test "session fixture: headerless start yields Claude session identity" {
    var trace = try parseFixture("session.jsonl", session_path);
    defer trace.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.claude, trace.source);
    try testing.expectEqual(@as(usize, 0), trace.warnings.items.len);
    const session = trace.session;
    try testing.expectEqual(trace_core.TraceFormat.claude_code_jsonl, session.source_format);
    try expectString(session_id, session.session_id);
    try expectString("claude-code", session.originator);
    try expectString("2026-11-10T10:00:00.000Z", session.start_time);
    try expectString("2026-11-10T10:01:02.000Z", session.end_time);
    try expectString("/work/alpha", session.cwd);
    try expectString("main", session.git_branch);
    try expectString("2.1.325", session.cli_version);
    try expectString("claude-test-two", session.model);
    try expectString("priority", session.service_tier);
    try testing.expect(session.git_commit_hash == null);
    try testing.expect(session.git_repository_url == null);
    try testing.expect(session.model_provider == null);
    try testing.expect(session.parent_session_id == null);
    try testing.expect(session.forked_from_session_id == null);
    try testing.expect(session.parent_relation == null);
    try testing.expect(!session.is_external_worker);
    try testing.expect(!session.is_inline_worker);
    try testing.expectEqual(@as(i64, 2), session.turn_count);
}

test "session fixture: each turn reads its own records" {
    var trace = try parseFixture("session.jsonl", session_path);
    defer trace.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), trace.turns.items.len);
    const first = support.turnByIndex(&trace, 1);
    try testing.expectEqualStrings("rec-s01", first.turn_id);
    try expectString("2026-11-10T10:00:00.000Z", first.started_at);
    try expectString("/work/alpha", first.cwd);
    try expectString("claude-test-one", first.model);
    try expectString("high", first.reasoning_effort);
    try expectString("human", first.origin);
    try expectString("List the files", first.user_message);
    try testing.expectEqual(trace_core.TurnStatus.complete, first.status);
    try expectString("claude_end_turn", first.status_reason);
    try testing.expectEqual(@as(?i64, 5000), first.duration_ms);
    try expectString("2026-11-10T10:00:05.000Z", first.completed_at);
    try testing.expectEqual(@as(i64, 1), first.tool_count);
    const answer = first.final_answer orelse return error.TestExpectedAnswer;
    const one = std.mem.indexOf(u8, answer, "FIRST-BLOCK") orelse return error.TestMissingBlock;
    const two = std.mem.indexOf(u8, answer, "SECOND-BLOCK") orelse return error.TestMissingBlock;
    try testing.expect(one < two);
    const second = support.turnByIndex(&trace, 2);
    try testing.expectEqualStrings("rec-s08", second.turn_id);
    try expectString("2026-11-10T10:01:00.000Z", second.started_at);
    try expectString("/work/beta", second.cwd);
    try expectString("claude-test-two", second.model);
    try expectString("low", second.reasoning_effort);
    try expectString("You are welcome.", second.final_answer);
    try testing.expectEqual(@as(i64, 0), second.tool_count);
}

test "session fixture: messages, tool pair and source events" {
    var trace = try parseFixture("session.jsonl", session_path);
    defer trace.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), visibleCount(&trace, "user"));
    try testing.expectEqual(@as(usize, 3), visibleCount(&trace, "assistant"));
    const first_block = visibleWith(&trace, "FIRST-BLOCK") orelse return error.TestMissing;
    try expectString("rec-s05", first_block.message_id);
    try testing.expect(visibleWith(&trace, "SECOND-BLOCK") != null);
    try testing.expect(visibleWith(&trace, "a.txt\nb.txt") == null);
    try testing.expect(!exposes(&trace, "THINKING-SENTINEL"));
    try testing.expectEqual(@as(usize, 9), trace.occurrences.items.len);
    for (trace.occurrences.items) |occurrence| {
        try testing.expectEqual(trace_core.TraceFormat.claude_code_jsonl, occurrence.format);
    }
    try testing.expectEqualStrings("user", occurrenceAt(&trace, 1).entry_type);
    try expectString("user", occurrenceAt(&trace, 1).event_type);
    try expectString("assistant", occurrenceAt(&trace, 2).event_type);
    try testing.expectEqualStrings("system", occurrenceAt(&trace, 7).entry_type);
    try expectString("turn_duration", occurrenceAt(&trace, 7).event_type);
    try testing.expectEqual(@as(usize, 1), trace.tools.items.len);
    const tool = findTool(&trace, "toolu_s1") orelse return error.TestMissingTool;
    try expectString("Bash", tool.tool_name);
    try testing.expectEqual(trace_core.ToolKind.exec_command, tool.kind);
    try expectString("ls", tool.command_text);
    try testing.expect(contains(tool.arguments_json, "List files"));
    try testing.expect(tool.input_text == null);
    try expectString("2026-11-10T10:00:01.500Z", tool.started_at);
    try expectString("/work/alpha/tool", tool.cwd);
    try expectString("a.txt\nb.txt", tool.output_text);
    try expectString("2026-11-10T10:00:02.000Z", tool.completed_at);
    try testing.expectEqual(trace_core.ToolLifecycleStatus.completed, tool.lifecycle_status);
    try testing.expect(tool.exit_code == null);
    try testing.expect(tool.duration_ms == null);
    try testing.expectEqual(@as(?i64, 1), tool.turn_index);
}

test "session fixture: discovery prefix fixes identity" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try support.writeTree(tmp.dir, &.{.{
        .path = session_path,
        .bytes = @embedFile(fixture_root ++ "session.jsonl"),
    }});
    var identity = try trace_adapter.discoverSessionIdentity(
        testing.io,
        tmp.dir,
        allocator,
        session_path,
        .{},
        "/work/beta",
    );
    defer identity.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.claude, identity.source);
    try expectString(session_id, identity.session_id);
    try expectString("2026-11-10T10:00:00.000Z", identity.start_time);
    try testing.expect(identity.bytes_read > 0);
    try testing.expect(!identity.repo_matches);
    try testing.expect(identity.parent_session_id == null);
}

const tools_path = "projects/-w/5e551000-0000-4000-8000-000000000002.jsonl";

test "tools fixture: kinds come from the existing vocabulary" {
    var trace = try parseFixture("tools.jsonl", tools_path);
    defer trace.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), trace.warnings.items.len);
    const Kind = trace_core.ToolKind;
    const cases = [_]struct { call: []const u8, kind: Kind }{
        .{ .call = "toolu_bash_fail", .kind = .exec_command },
        .{ .call = "toolu_bash_ok", .kind = .exec_command },
        .{ .call = "toolu_edit", .kind = .patch_apply },
        .{ .call = "toolu_write", .kind = .patch_apply },
        .{ .call = "toolu_notebook", .kind = .patch_apply },
        .{ .call = "toolu_agent", .kind = .spawn_agent },
        .{ .call = "toolu_task", .kind = .spawn_agent },
        .{ .call = "toolu_web", .kind = .web_search },
        .{ .call = "toolu_mcp", .kind = .mcp_tool },
        .{ .call = "toolu_read", .kind = .unknown },
    };
    for (cases) |case| {
        const tool = findTool(&trace, case.call) orelse return error.TestMissingTool;
        try testing.expectEqual(case.kind, tool.kind);
        try testing.expect(tool.input_text == null);
        try testing.expectEqual(@as(?i64, 1), tool.turn_index);
    }
    const mcp = findTool(&trace, "toolu_mcp").?;
    try expectString("fixture_server", mcp.namespace);
    try expectString("mcp__fixture_server__lookup", mcp.tool_name);
    const edit = findTool(&trace, "toolu_edit").?;
    try testing.expect(contains(edit.arguments_json, "\"old_string\""));
    try testing.expect(edit.command_text == null);
    try testing.expectEqual(@as(i64, 10), support.turnByIndex(&trace, 1).tool_count);
}

test "tools fixture: error results, output parts and exit codes" {
    var trace = try parseFixture("tools.jsonl", tools_path);
    defer trace.deinit(allocator);
    const failed = findTool(&trace, "toolu_bash_fail") orelse return error.TestMissingTool;
    try testing.expectEqual(trace_core.ToolLifecycleStatus.failed, failed.lifecycle_status);
    try testing.expectEqual(@as(?i64, 1), failed.exit_code);
    try expectString("false", failed.command_text);
    try expectString("2026-11-10T11:00:02.000Z", failed.completed_at);
    const ok = findTool(&trace, "toolu_bash_ok") orelse return error.TestMissingTool;
    try testing.expectEqual(trace_core.ToolLifecycleStatus.completed, ok.lifecycle_status);
    try testing.expect(ok.exit_code == null);
    try testing.expect(ok.duration_ms == null);
    try expectString("ok", ok.output_text);
    const mcp = findTool(&trace, "toolu_mcp") orelse return error.TestMissingTool;
    try testing.expect(contains(mcp.output_text, "part one"));
    try testing.expect(contains(mcp.output_text, "part two"));
    try testing.expect(mcp.output_parts_json != null);
    try testing.expect(findTool(&trace, "toolu_orphan") != null);
    try testing.expect(visibleWith(&trace, "no call") == null);
}

test "one-line message: a legacy line keeps both blocks in array order" {
    const path = "projects/-w/5e551000-0000-4000-8000-000000000003.jsonl";
    var trace = try parseFixture("one-line-message.jsonl", path);
    defer trace.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), trace.warnings.items.len);
    const message = visibleWith(&trace, "ALPHA-BLOCK") orelse return error.TestMissing;
    const text = message.text.?;
    const alpha = std.mem.indexOf(u8, text, "ALPHA-BLOCK").?;
    const beta = std.mem.indexOf(u8, text, "BETA-BLOCK") orelse return error.TestMissingBlock;
    try testing.expect(alpha < beta);
    try expectString("assistant", message.role);
    try testing.expect(visibleWith(&trace, "CHECKING-TEXT") != null);
    const tool = findTool(&trace, "toolu_o1") orelse return error.TestMissingTool;
    try testing.expectEqual(trace_core.ToolKind.exec_command, tool.kind);
    try expectString("/w", tool.output_text);
    try testing.expectEqual(@as(usize, 1), trace.turns.items.len);
    const turn = support.turnByIndex(&trace, 1);
    try testing.expectEqual(trace_core.TurnStatus.complete, turn.status);
    try expectString("claude_text_end", turn.status_reason);
    const answer = turn.final_answer orelse return error.TestExpectedAnswer;
    const answer_alpha = std.mem.indexOf(u8, answer, "ALPHA-BLOCK") orelse
        return error.TestMissingBlock;
    const answer_beta = std.mem.indexOf(u8, answer, "BETA-BLOCK") orelse
        return error.TestMissingBlock;
    try testing.expect(answer_alpha < answer_beta);
    try testing.expect(turn.origin == null);
    try expectString("Go", turn.user_message);
}

test "titles: latest custom title wins, else latest generated title" {
    const path = "projects/-w/5e551000-0000-4000-8000-000000000004.jsonl";
    const bytes = @embedFile(fixture_root ++ "titles.jsonl");
    var trace = try support.parse(allocator, path, bytes, .stale);
    defer trace.deinit(allocator);
    try expectString("Named second", trace.session.thread_name);
    try expectString("Named second", support.turnByIndex(&trace, 1).thread_name);
    const generated_only = try withoutLines(bytes, "custom-title");
    defer allocator.free(generated_only);
    var generated = try support.parse(allocator, path, generated_only, .stale);
    defer generated.deinit(allocator);
    try expectString("Generated two", generated.session.thread_name);
    const untitled = try withoutLines(generated_only, "ai-title");
    defer allocator.free(untitled);
    var bare = try support.parse(allocator, path, untitled, .stale);
    defer bare.deinit(allocator);
    try testing.expect(bare.session.thread_name == null);
}

test "private types: unmodeled records, request bodies and thinking expose no payload" {
    const path = "projects/-w/5e551000-0000-4000-8000-000000000005.jsonl";
    var trace = try parseFixture("private-types.jsonl", path);
    defer trace.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.claude, trace.source);
    try testing.expectEqual(@as(usize, 0), trace.warnings.items.len);
    for ([_]usize{ 1, 3, 6, 7 }) |line| {
        const occurrence = occurrenceAt(&trace, line);
        try testing.expect(occurrence.private);
        try testing.expect(occurrence.payload_json == null);
        try testing.expect(occurrence.text == null);
        try testing.expect(!occurrence.message_visible);
        try testing.expect(occurrence.raw_json != null);
    }
    try testing.expectEqualStrings("session-owner", occurrenceAt(&trace, 1).entry_type);
    try testing.expect(occurrenceAt(&trace, 1).event_type == null);
    try testing.expectEqualStrings("api-request", occurrenceAt(&trace, 3).entry_type);
    try testing.expectEqualStrings("mystery-record", occurrenceAt(&trace, 7).entry_type);
    for ([_][]const u8{
        "OWNER-SENTINEL", "REQUEST-BODY-SENTINEL", "THINKING-SENTINEL",
        "COST-SENTINEL",  "UNKNOWN-SENTINEL",
    }) |needle| {
        try testing.expect(!exposes(&trace, needle));
    }
    try testing.expect(visibleWith(&trace, "Visible answer") != null);
    try expectString("Visible answer", support.turnByIndex(&trace, 1).final_answer);
}

test "metadata-first: known metadata classifies and the prefix sets start time" {
    const path = "projects/-work-meta/metadata-first.jsonl";
    var trace = try parseFixture("metadata-first.jsonl", path);
    defer trace.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.claude, trace.source);
    try testing.expectEqual(@as(usize, 0), trace.warnings.items.len);
    try expectString("5e551000-0000-4000-8000-000000000006", trace.session.session_id);
    try expectString("2026-11-10T14:00:03.000Z", trace.session.start_time);
    try expectString("2026-11-10T15:00:00.000Z", trace.session.end_time);
    try expectString("/work/meta", trace.session.cwd);
    try testing.expectEqual(@as(usize, 6), trace.occurrences.items.len);
    try testing.expectEqualStrings("summary", occurrenceAt(&trace, 1).entry_type);
    try testing.expectEqualStrings("file-history-snapshot", occurrenceAt(&trace, 3).entry_type);
    for ([_][]const u8{ "summary", "queue-operation", "file-history-snapshot" }) |kind| {
        const single = try std.mem.concat(allocator, u8, &.{
            try firstLineOfType(@embedFile(fixture_root ++ "metadata-first.jsonl"), kind),
            "\n",
        });
        defer allocator.free(single);
        var alone = try support.parse(allocator, path, single, .stale);
        defer alone.deinit(allocator);
        try testing.expectEqual(trace_core.TraceSource.claude, alone.source);
        try testing.expectEqual(@as(usize, 0), alone.turns.items.len);
    }
}

fn firstLineOfType(bytes: []const u8, kind: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var buffer: [64]u8 = undefined;
        const marker = try std.fmt.bufPrint(&buffer, "\"type\":\"{s}\"", .{kind});
        if (std.mem.indexOf(u8, line, marker) != null) return line;
    }
    @panic("missing line");
}

test "unknown-first: unknown types stay neutral whatever fields they carry" {
    const path = "projects/-work-unknown/unknown-first.jsonl";
    const bytes = @embedFile(fixture_root ++ "unknown-first.jsonl");
    var trace = try support.parse(allocator, path, bytes, .stale);
    defer trace.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.claude, trace.source);
    try testing.expectEqual(@as(usize, 0), trace.warnings.items.len);
    try expectString("5e551000-0000-4000-8000-000000000007", trace.session.session_id);
    try expectString("/work/unknown", trace.session.cwd);
    try expectString("2026-11-10T15:00:00.000Z", trace.session.start_time);
    for ([_]usize{ 1, 2, 3, 4 }) |line| {
        const occurrence = occurrenceAt(&trace, line);
        try testing.expect(occurrence.private);
        try testing.expect(occurrence.payload_json == null);
    }
    try testing.expectEqual(@as(usize, 1), trace.turns.items.len);
    const neutral_only = try withoutLines(bytes, "rec-k0");
    defer allocator.free(neutral_only);
    try testing.expectError(
        error.UnclassifiedSessionFormat,
        support.parse(allocator, path, neutral_only, .stale),
    );
}

test "no-signature: empty and blank files keep rows; unknown-only input fails" {
    for ([_][]const u8{
        @embedFile(fixture_root ++ "no-signature/empty.jsonl"),
        @embedFile(fixture_root ++ "no-signature/blank.jsonl"),
    }) |bytes| {
        var trace = try support.parse(allocator, "no-signature/empty.jsonl", bytes, .stale);
        defer trace.deinit(allocator);
        try testing.expectEqual(trace_core.TraceSource.none, trace.source);
        try testing.expect(trace.session.session_id == null);
        try testing.expectEqual(@as(usize, 0), trace.warnings.items.len);
        try testing.expectEqual(@as(usize, 0), trace.turns.items.len);
    }
    const Case = struct { bytes: []const u8, source: trace_core.TraceSource };
    for ([_]Case{
        .{ .bytes = @embedFile(fixture_root ++ "no-signature/claude.jsonl"), .source = .claude },
        .{ .bytes = @embedFile(fixture_root ++ "no-signature/codex.jsonl"), .source = .codex },
        .{ .bytes = @embedFile(fixture_root ++ "no-signature/pi.jsonl"), .source = .pi },
    }) |case| {
        var trace = try support.parseSummary(allocator, "beside.jsonl", case.bytes, .stale);
        defer trace.deinit(allocator);
        try testing.expectEqual(case.source, trace.source);
    }
    const unknown = @embedFile(fixture_root ++ "no-signature/unknown-only.jsonl");
    try testing.expectError(
        error.UnclassifiedSessionFormat,
        support.parse(allocator, "no-signature/unknown-only.jsonl", unknown, .stale),
    );
    try testing.expectError(
        error.UnclassifiedSessionFormat,
        support.parseSummary(allocator, "no-signature/unknown-only.jsonl", unknown, .stale),
    );
}

test "late-signature: a neutral prefix falls back to Codex; a late Claude record fails" {
    const codex = @embedFile(fixture_root ++ "late-signature/neutral-codex.jsonl");
    var trace = try support.parse(allocator, "late/neutral-codex.jsonl", codex, .stale);
    defer trace.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.codex, trace.source);
    for ([_][]const u8{
        @embedFile(fixture_root ++ "late-signature/neutral-claude.jsonl"),
        @embedFile(fixture_root ++ "late-signature/codex-then-claude.jsonl"),
    }) |bytes| {
        try testing.expectError(
            error.UnsupportedSessionFormat,
            support.parse(allocator, "late/claude.jsonl", bytes, .stale),
        );
    }
}

test "mixed: a contradictory signature after the decision fails" {
    const bytes = @embedFile(fixture_root ++ "mixed.jsonl");
    const path = "projects/-w/5e551000-0000-4000-8000-000000000008.jsonl";
    try testing.expectError(
        error.UnsupportedSessionFormat,
        support.parse(allocator, path, bytes, .stale),
    );
    try testing.expectError(
        error.UnsupportedSessionFormat,
        support.parseSummary(allocator, path, bytes, .stale),
    );
    const reversed = try swapFirstAndLast(bytes);
    defer allocator.free(reversed);
    try testing.expectError(
        error.UnsupportedSessionFormat,
        support.parse(allocator, path, reversed, .stale),
    );
}

test "legacy-origin: filename identity wins over a stale recorded sessionId" {
    const stem = "5e551000-0000-4000-8000-000000000009";
    var trace = try parseFixture("legacy-origin.jsonl", "projects/-w/" ++ stem ++ ".jsonl");
    defer trace.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.claude, trace.source);
    try testing.expectEqual(@as(usize, 0), trace.warnings.items.len);
    try expectString(stem, trace.session.session_id);
    try testing.expect(!trace.session.lineage_conflict);
    try testing.expect(trace.session.parent_session_id == null);
    try testing.expect(trace.session.forked_from_session_id == null);
    try testing.expectEqual(@as(usize, 2), trace.turns.items.len);
    var unnamed = try parseFixture("legacy-origin.jsonl", "projects/-w/legacy-origin.jsonl");
    defer unnamed.deinit(allocator);
    try expectString("5e551000-0000-4000-8000-00000000000a", unnamed.session.session_id);
}

test "missing-cwd: a transcript without conversation survives discovery, misses --repo" {
    const name = "5e551000-0000-4000-8000-00000000000b.jsonl";
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = comptime embedTree("missing-cwd/", &.{name});
    try support.writeTree(tmp.dir, &files);
    var identity = try trace_adapter.discoverSessionIdentity(
        testing.io,
        tmp.dir,
        allocator,
        name,
        .{},
        "/work",
    );
    defer identity.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.claude, identity.source);
    try testing.expect(identity.repo_matches);
    try expectString(name[0 .. name.len - ".jsonl".len], identity.session_id);
    try testing.expect(identity.start_time == null);
    var trace = try parseFile(tmp.dir, name);
    defer trace.deinit(allocator);
    try testing.expect(trace.session.cwd == null);
    try testing.expectEqual(@as(usize, 0), trace.warnings.items.len);
    try expectString("No conversation", trace.session.thread_name);
    try testing.expect(!native.sessionMetadataPasses(trace.session, .{ .repo = "/work" }));
    try testing.expect(native.sessionMetadataPasses(trace.session, .{}));
}

const root_w = "d0000000-0000-4000-8000-000000000001";
const agent_w = "a1b2c3d4e5f600001";
const worker_w = root_w ++ "/agent-" ++ agent_w;

fn edgeWithCall(trace: *const Trace, call: []const u8) ?*const trace_core.SessionGraphEdge {
    for (trace.graph_edges.items) |*edge| {
        if (edge.call_id) |id| if (std.mem.eql(u8, id, call)) return edge;
    }
    return null;
}

test "worker: sidecar toolUseId gives child-side and spawner-side edge rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = comptime embedTree("worker/", &.{
        "proj/" ++ root_w ++ ".jsonl",
        "proj/" ++ root_w ++ "/subagents/agent-" ++ agent_w ++ ".jsonl",
        "proj/" ++ root_w ++ "/subagents/agent-" ++ agent_w ++ ".meta.json",
    });
    try support.writeTree(tmp.dir, &files);
    var root = try parseFile(tmp.dir, files[0].path);
    defer root.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), root.warnings.items.len);
    try expectString(root_w, root.session.session_id);
    try testing.expect(!root.session.is_external_worker);
    try testing.expectEqual(@as(i64, 1), root.session.spawned_worker_count);
    try testing.expectEqual(@as(i64, 1), support.turnByIndex(&root, 1).spawned_worker_count);
    try testing.expectEqual(@as(usize, 0), root.claude_limitations.unlocated_spawn_count);
    try testing.expectEqual(@as(usize, 1), root.graph_edges.items.len);
    const spawn = edgeWithCall(&root, "toolu_spawn_w") orelse return error.TestMissingEdge;
    try expectString(root_w, spawn.parent_session_id);
    try expectString(worker_w, spawn.worker_session_id);
    try testing.expect(spawn.spawned_at != null);
    var worker = try parseFile(tmp.dir, files[1].path);
    defer worker.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), worker.warnings.items.len);
    try expectString(worker_w, worker.session.session_id);
    try expectString(root_w, worker.session.root_session_id);
    try expectString(root_w, worker.session.control_parent_session_id);
    try testing.expect(worker.session.is_external_worker);
    try testing.expect(!worker.session.is_inline_worker);
    try testing.expect(!worker.session.lineage_conflict);
    try testing.expect(worker.session.parent_session_id == null);
    try testing.expect(!worker.claude_limitations.worker_parent_unread);
    try testing.expect(!worker.claude_limitations.worker_parent_missing);
    try testing.expect(worker.claude_sidecar != null and worker.claude_sidecar.?.present);
    try testing.expectEqual(@as(usize, 1), worker.graph_edges.items.len);
    const child = edgeWithCall(&worker, "toolu_spawn_w") orelse return error.TestMissingEdge;
    try expectString(root_w, child.parent_session_id);
    try expectString(worker_w, child.worker_session_id);
    try testing.expectEqual(@as(usize, 1), worker.turns.items.len);
    try testing.expectEqual(trace_core.TurnStatus.complete, worker.turns.items[0].status);
}

const root_n = "d0000000-0000-4000-8000-000000000002";

test "nested-worker: parentAgentId gives the intermediate parent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = "proj/" ++ root_n ++ "/subagents/";
    const files = comptime embedTree("nested-worker/", &.{
        "proj/" ++ root_n ++ ".jsonl",
        base ++ "agent-aaaa0000000000001.jsonl",
        base ++ "agent-aaaa0000000000001.meta.json",
        base ++ "agent-bbbb0000000000002.jsonl",
        base ++ "agent-bbbb0000000000002.meta.json",
    });
    try support.writeTree(tmp.dir, &files);
    const outer_id = root_n ++ "/agent-aaaa0000000000001";
    const inner_id = root_n ++ "/agent-bbbb0000000000002";
    var outer = try parseFile(tmp.dir, files[1].path);
    defer outer.deinit(allocator);
    try expectString(outer_id, outer.session.session_id);
    try expectString(root_n, outer.session.control_parent_session_id);
    try expectString(root_n, outer.session.root_session_id);
    try testing.expectEqual(@as(usize, 1), outer.graph_edges.items.len);
    const outer_child = edgeWithCall(&outer, "toolu_outer") orelse return error.TestMissingEdge;
    try expectString(root_n, outer_child.parent_session_id);
    try testing.expect(edgeWithCall(&outer, "toolu_inner") == null);
    try testing.expectEqual(@as(i64, 0), outer.session.spawned_worker_count);
    try testing.expectEqual(@as(usize, 0), outer.claude_limitations.unlocated_spawn_count);
    var inner = try parseFile(tmp.dir, files[3].path);
    defer inner.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), inner.warnings.items.len);
    try expectString(inner_id, inner.session.session_id);
    try expectString(root_n, inner.session.root_session_id);
    try expectString(outer_id, inner.session.control_parent_session_id);
    try testing.expect(!inner.session.lineage_conflict);
    try testing.expect(!inner.claude_limitations.worker_parent_missing);
    const child = edgeWithCall(&inner, "toolu_inner") orelse return error.TestMissingEdge;
    try expectString(outer_id, child.parent_session_id);
    try expectString(inner_id, child.worker_session_id);
    var root = try parseFile(tmp.dir, files[0].path);
    defer root.deinit(allocator);
    const spawn = edgeWithCall(&root, "toolu_outer") orelse return error.TestMissingEdge;
    try expectString(outer_id, spawn.worker_session_id);
}

const root_h = "d0000000-0000-4000-8000-000000000003";

test "harness-worker: a sidecar with neither field has the root parent and no edge" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = "proj/" ++ root_h ++ "/subagents/";
    const files = comptime embedTree("harness-worker/", &.{
        "proj/" ++ root_h ++ ".jsonl",
        base ++ "agent-cccc0000000000003.jsonl",
        base ++ "agent-cccc0000000000003.meta.json",
    });
    try support.writeTree(tmp.dir, &files);
    var worker = try parseFile(tmp.dir, files[1].path);
    defer worker.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), worker.warnings.items.len);
    try expectString(root_h ++ "/agent-cccc0000000000003", worker.session.session_id);
    try expectString(root_h, worker.session.control_parent_session_id);
    try expectString(root_h, worker.session.root_session_id);
    try testing.expect(worker.session.is_external_worker);
    try testing.expect(!worker.session.lineage_conflict);
    try testing.expect(!worker.claude_limitations.worker_parent_unread);
    try testing.expectEqual(@as(usize, 0), worker.graph_edges.items.len);
    try testing.expectEqual(@as(usize, 1), worker.turns.items.len);
    try testing.expect(worker.turns.items[0].user_message == null);
    try testing.expectEqual(@as(usize, 0), visibleCount(&worker, "user"));
    var root = try parseFile(tmp.dir, files[0].path);
    defer root.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), root.graph_edges.items.len);
    try testing.expectEqual(@as(i64, 0), root.session.spawned_worker_count);
}

const root_u = "d0000000-0000-4000-8000-000000000004";

test "worker-unread-meta: unread sidecars give a null parent and keep root membership" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = "proj/" ++ root_u ++ "/subagents/";
    const files = comptime embedTree("worker-unread-meta/", &.{
        "proj/" ++ root_u ++ ".jsonl",
        base ++ "agent-dddd0000000000001.jsonl",
        base ++ "agent-dddd0000000000002.jsonl",
        base ++ "agent-dddd0000000000003.jsonl",
        base ++ "agent-dddd0000000000003.meta.json",
        base ++ "agent-dddd0000000000004.jsonl",
        base ++ "agent-dddd0000000000004.meta.json",
    });
    try support.writeTree(tmp.dir, &files);
    const padding = try allocator.alloc(u8, 70 * 1024);
    defer allocator.free(padding);
    @memset(padding, 'x');
    const oversized = try std.mem.concat(allocator, u8, &.{
        "{\"agentType\":\"general-purpose\",\"toolUseId\":\"toolu_big\",\"pad\":\"",
        padding,
        "\"}",
    });
    defer allocator.free(oversized);
    try support.writeTree(tmp.dir, &.{.{
        .path = base ++ "agent-dddd0000000000002.meta.json",
        .bytes = oversized,
    }});
    for ([_][]const u8{ "1", "2", "3", "4" }) |suffix| {
        const path = try std.mem.concat(allocator, u8, &.{
            base, "agent-dddd000000000000", suffix, ".jsonl",
        });
        defer allocator.free(path);
        var worker = try parseFile(tmp.dir, path);
        defer worker.deinit(allocator);
        const expected = try std.mem.concat(allocator, u8, &.{
            root_u, "/agent-dddd000000000000", suffix,
        });
        defer allocator.free(expected);
        try expectString(expected, worker.session.session_id);
        try expectString(root_u, worker.session.root_session_id);
        try testing.expect(worker.session.is_external_worker);
        try testing.expect(worker.session.control_parent_session_id == null);
        try testing.expect(worker.session.lineage_conflict);
        try testing.expect(worker.claude_limitations.worker_parent_unread);
        try testing.expectEqual(@as(usize, 0), worker.warnings.items.len);
        if (suffix[0] != '4') try testing.expectEqual(@as(usize, 0), worker.graph_edges.items.len);
    }
}

const root_m = "d0000000-0000-4000-8000-000000000005";

test "worker-missing-parent: an absent named parent is kept and counted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = "proj/" ++ root_m ++ "/subagents/";
    const files = comptime embedTree("worker-missing-parent/", &.{
        "proj/" ++ root_m ++ ".jsonl",
        base ++ "agent-eeee0000000000001.jsonl",
        base ++ "agent-eeee0000000000001.meta.json",
    });
    try support.writeTree(tmp.dir, &files);
    var worker = try parseFile(tmp.dir, files[1].path);
    defer worker.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), worker.warnings.items.len);
    try expectString(root_m ++ "/agent-eeee0000000000001", worker.session.session_id);
    try expectString(root_m, worker.session.root_session_id);
    const parent = root_m ++ "/agent-ffff0000000000009";
    try expectString(parent, worker.session.control_parent_session_id);
    try testing.expect(worker.session.lineage_conflict);
    try testing.expect(worker.claude_limitations.worker_parent_missing);
    try testing.expect(!worker.claude_limitations.worker_parent_unread);
}

const root_c = "d0000000-0000-4000-8000-000000000006";

fn expectConflictedWorker(dir: std.Io.Dir, path: []const u8, expected_id: []const u8) !void {
    var worker = try parseFile(dir, path);
    defer worker.deinit(allocator);
    try testing.expect(worker.warnings.items.len > 0);
    try expectString(expected_id, worker.session.session_id);
    try expectString(root_c, worker.session.root_session_id);
    try testing.expect(worker.session.is_external_worker);
    try testing.expect(worker.session.lineage_conflict);
    try testing.expect(worker.token_events.items.len > 0);
    for (worker.token_events.items) |event| {
        try expectString("unplaced", event.request_record);
    }
}

test "worker-identity-conflict: contradictions warn, keep identity, unplace every row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = "proj/" ++ root_c ++ "/subagents/";
    const files = comptime embedTree("worker-identity-conflict/", &.{
        "proj/" ++ root_c ++ ".jsonl",
        base ++ "agent-abab0000000000001.jsonl",
        base ++ "agent-abab0000000000001.meta.json",
        base ++ "agent-abab0000000000002.jsonl",
        base ++ "agent-abab0000000000002.meta.json",
        "proj/agent-abab0000000000003.jsonl",
    });
    try support.writeTree(tmp.dir, &files);
    try expectConflictedWorker(tmp.dir, files[1].path, root_c ++ "/agent-abab0000000000001");
    try expectConflictedWorker(tmp.dir, files[3].path, root_c ++ "/agent-abab0000000000002");
    try expectConflictedWorker(tmp.dir, files[5].path, root_c ++ "/agent-abab0000000000003");
    var current = try parseFile(tmp.dir, files[1].path);
    defer current.deinit(allocator);
    var unanswered: usize = 0;
    for (current.token_events.items) |event| {
        if (event.request_key == null and event.quantity_state == null) unanswered += 1;
    }
    try testing.expectEqual(@as(usize, 1), unanswered);
    var root = try parseFile(tmp.dir, files[0].path);
    defer root.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), root.warnings.items.len);
    try testing.expect(!root.session.lineage_conflict);
}

const root_l = "d0000000-0000-4000-8000-000000000007";

test "legacy-worker: flat layout takes its root from sessionId; no unauthored edge" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = comptime embedTree("legacy-worker/", &.{
        "proj/" ++ root_l ++ ".jsonl",
        "proj/agent-9a8b7c6d.jsonl",
    });
    try support.writeTree(tmp.dir, &files);
    var worker = try parseFile(tmp.dir, files[1].path);
    defer worker.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), worker.warnings.items.len);
    try expectString(root_l ++ "/agent-9a8b7c6d", worker.session.session_id);
    try expectString(root_l, worker.session.root_session_id);
    try expectString(root_l, worker.session.control_parent_session_id);
    try testing.expect(worker.session.is_external_worker);
    try testing.expect(!worker.session.lineage_conflict);
    try testing.expect(!worker.claude_limitations.worker_parent_unread);
    try testing.expectEqual(@as(usize, 0), worker.graph_edges.items.len);
    var root = try parseFile(tmp.dir, files[0].path);
    defer root.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), root.warnings.items.len);
    try testing.expectEqual(@as(usize, 0), root.graph_edges.items.len);
    try testing.expectEqual(@as(i64, 0), root.session.spawned_worker_count);
    try testing.expectEqual(@as(usize, 1), root.claude_limitations.unlocated_spawn_count);
    const spawn = findTool(&root, "toolu_legacy") orelse return error.TestMissingTool;
    try testing.expectEqual(trace_core.ToolKind.spawn_agent, spawn.kind);
}

const window_names = [_][]const u8{
    "e0000000-0000-4000-8000-000000000001.jsonl",
    "e0000000-0000-4000-8000-000000000002.jsonl",
    "e0000000-0000-4000-8000-000000000003.jsonl",
    "e0000000-0000-4000-8000-000000000004.jsonl",
};
const ms_2026_11_10: i64 = 1_794_268_800_000;
const ms_2026_11_07: i64 = 1_794_009_600_000;
const ms_2026_11_08_noon: i64 = 1_794_139_200_000;
const ms_2026_11_01: i64 = 1_793_491_200_000;

const WindowFixture = struct {
    tmp: testing.TmpDir,
    config: [:0]u8,
    projects: []u8,
    environment: std.process.Environ.Map,

    fn init() !WindowFixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        inline for (window_names, 0..) |name, index| {
            const path = "config/projects/-work-time/" ++ name;
            try support.writeTree(tmp.dir, &.{.{
                .path = path,
                .bytes = @embedFile(fixture_root ++ "time-window/projects/-work-time/" ++ name),
            }});
            const modified_ms = if (index == 0) ms_2026_11_07 else ms_2026_11_08_noon;
            var file = try tmp.dir.openFile(testing.io, path, .{ .mode = .read_write });
            defer file.close(testing.io);
            try file.setTimestamps(testing.io, .{ .modify_timestamp = .{
                .new = .{ .nanoseconds = @as(i96, modified_ms) * std.time.ns_per_ms },
            } });
        }
        const config = try tmp.dir.realPathFileAlloc(testing.io, "config", allocator);
        errdefer allocator.free(config);
        const projects = try std.fs.path.join(allocator, &.{ config, "projects" });
        errdefer allocator.free(projects);
        var environment = std.process.Environ.Map.init(allocator);
        errdefer environment.deinit();
        try environment.put("CLAUDE_CONFIG_DIR", config);
        try environment.put("HOME", config);
        return .{ .tmp = tmp, .config = config, .projects = projects, .environment = environment };
    }

    fn deinit(self: *WindowFixture) void {
        self.environment.deinit();
        allocator.free(self.projects);
        allocator.free(self.config);
        self.tmp.cleanup();
    }

    fn resolve(self: *WindowFixture, options: native.Options) ![]bool {
        var effective = options;
        effective.environment = &self.environment;
        var paths = try native.resolveTargetPaths(
            allocator,
            testing.io,
            std.Io.Dir.cwd(),
            effective,
            false,
        );
        defer native.freePaths(allocator, &paths);
        const kept = try allocator.alloc(bool, window_names.len);
        @memset(kept, false);
        for (paths.items) |path| {
            for (window_names, 0..) |name, index| {
                if (std.mem.eql(u8, std.fs.path.basename(path), name)) kept[index] = true;
            }
        }
        return kept;
    }
};

test "time-window: since prunes by modification time on the live default root only" {
    var fixture = try WindowFixture.init();
    defer fixture.deinit();
    const live = try fixture.resolve(.{ .source = .claude_code, .since_ms = ms_2026_11_10 });
    defer allocator.free(live);
    try testing.expectEqualSlices(bool, &.{ false, true, true, true }, live);
    const explicit = try fixture.resolve(.{ .root = fixture.projects, .since_ms = ms_2026_11_10 });
    defer allocator.free(explicit);
    try testing.expectEqualSlices(bool, &.{ true, true, true, true }, explicit);
    const near = try fixture.resolve(.{
        .source = .claude_code,
        .since_ms = ms_2026_11_10 - std.time.ms_per_day,
    });
    defer allocator.free(near);
    try testing.expectEqualSlices(bool, &.{ true, true, true, true }, near);
}

test "time-window: until prunes by earliest prefix timestamp with a two-day margin" {
    var fixture = try WindowFixture.init();
    defer fixture.deinit();
    const live = try fixture.resolve(.{ .source = .claude_code, .until_ms = ms_2026_11_01 });
    defer allocator.free(live);
    try testing.expectEqualSlices(bool, &.{ true, false, true, true }, live);
    const explicit = try fixture.resolve(.{ .root = fixture.projects, .until_ms = ms_2026_11_01 });
    defer allocator.free(explicit);
    try testing.expectEqualSlices(bool, &.{ true, false, true, true }, explicit);
    const later = try fixture.resolve(.{
        .source = .claude_code,
        .until_ms = ms_2026_11_01 + std.time.ms_per_day,
    });
    defer allocator.free(later);
    try testing.expectEqualSlices(bool, &.{ true, true, true, true }, later);
}

test "time-window: explicit paths and native exact session targets bypass pruning" {
    var fixture = try WindowFixture.init();
    defer fixture.deinit();
    const pruned = try std.fs.path.join(allocator, &.{
        fixture.projects, "-work-time", window_names[1],
    });
    defer allocator.free(pruned);
    const by_path = try fixture.resolve(.{ .path = pruned, .until_ms = ms_2026_11_01 });
    defer allocator.free(by_path);
    try testing.expectEqualSlices(bool, &.{ false, true, false, false }, by_path);
    const by_id = try fixture.resolve(.{
        .source = .claude_code,
        .session_id = "e0000000-0000-4000-8000-000000000002",
        .until_ms = ms_2026_11_01,
    });
    defer allocator.free(by_id);
    try testing.expectEqualSlices(bool, &.{ false, true, false, false }, by_id);
    const stale = try std.fs.path.join(allocator, &.{
        fixture.projects, "-work-time", window_names[0],
    });
    defer allocator.free(stale);
    const stale_path = try fixture.resolve(.{
        .path = stale,
        .since_ms = ms_2026_11_10,
    });
    defer allocator.free(stale_path);
    try testing.expectEqualSlices(bool, &.{ true, false, false, false }, stale_path);
}

const r8 = "f0000000-0000-4000-8000-000000000008";
const r9 = "f0000000-0000-4000-8000-000000000009";
const scope_base = "projects/-work-scope/";
const scope_files = embedTree("accounting-scopes/", &.{
    scope_base ++ r8 ++ ".jsonl",
    scope_base ++ r8 ++ "/subagents/agent-s1.jsonl",
    scope_base ++ r8 ++ "/subagents/agent-s1.meta.json",
    scope_base ++ r8 ++ "/subagents/agent-s2.jsonl.zst",
    scope_base ++ r8 ++ "/subagents/agent-s2.meta.json",
    scope_base ++ r9 ++ ".jsonl.zst",
    scope_base ++ "agent-l1.jsonl",
    scope_base ++ "agent-u1.jsonl",
    scope_base ++ "rollout-codex.jsonl",
});

fn expectFamily(
    dir: std.Io.Dir,
    selected: []const u8,
    expected: []const []const u8,
    min_opened: usize,
) !void {
    var discovery = native.FamilyDiscovery{};
    var family = (try native.claudeFamilyPathsAlloc(
        allocator,
        testing.io,
        dir,
        selected,
        &discovery,
    )) orelse return error.TestExpectedFamily;
    defer native.freePaths(allocator, &family);
    try testing.expectEqual(expected.len, family.items.len);
    for (expected) |wanted| {
        var found = false;
        for (family.items) |path| found = found or std.mem.eql(u8, path, wanted);
        if (!found) std.debug.print("missing family member {s}\n", .{wanted});
        try testing.expect(found);
    }
    try testing.expect(discovery.bytes > 0);
    try testing.expect(discovery.opened >= min_opened);
}

test "accounting-scopes: a Claude path admits its session family" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try support.writeTree(tmp.dir, &scope_files);
    const current_family = [_][]const u8{
        scope_files[0].path, scope_files[1].path, scope_files[3].path,
    };
    try expectFamily(tmp.dir, scope_files[0].path, &current_family, 3);
    try expectFamily(tmp.dir, scope_files[1].path, &current_family, 3);
    try expectFamily(tmp.dir, scope_files[3].path, &current_family, 3);
    const legacy_family = [_][]const u8{ scope_files[5].path, scope_files[6].path };
    try expectFamily(tmp.dir, scope_files[5].path, &legacy_family, 3);
    try expectFamily(tmp.dir, scope_files[6].path, &legacy_family, 3);
    var discovery = native.FamilyDiscovery{};
    const codex = try native.claudeFamilyPathsAlloc(
        allocator,
        testing.io,
        tmp.dir,
        scope_files[8].path,
        &discovery,
    );
    try testing.expect(codex == null);
}

test "accounting-scopes: native commands resolve one file and worker IDs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try support.writeTree(tmp.dir, &scope_files);
    const projects = try tmp.dir.realPathFileAlloc(testing.io, "projects", allocator);
    defer allocator.free(projects);
    const Case = struct { options: native.Options, expected: []const u8 };
    const main_name = r8 ++ ".jsonl";
    const main_path = try std.fs.path.join(allocator, &.{ projects, "-work-scope", main_name });
    defer allocator.free(main_path);
    const cases = [_]Case{
        .{ .options = .{ .path = main_path }, .expected = r8 ++ ".jsonl" },
        .{ .options = .{ .root = projects, .session_id = r8 }, .expected = r8 ++ ".jsonl" },
        .{
            .options = .{ .root = projects, .session_id = r8 ++ "/agent-s1" },
            .expected = "agent-s1.jsonl",
        },
        .{
            .options = .{ .root = projects, .session_id = r8 ++ "/agent-s2" },
            .expected = "agent-s2.jsonl.zst",
        },
        .{
            .options = .{ .root = projects, .session_id = r9 ++ "/agent-l1" },
            .expected = "agent-l1.jsonl",
        },
        .{ .options = .{ .root = projects, .session_id = r9 }, .expected = r9 ++ ".jsonl.zst" },
    };
    for (cases) |case| {
        var paths = try native.resolveTargetPaths(
            allocator,
            testing.io,
            std.Io.Dir.cwd(),
            case.options,
            false,
        );
        defer native.freePaths(allocator, &paths);
        try testing.expectEqual(@as(usize, 1), paths.items.len);
        try testing.expectEqualStrings(case.expected, std.fs.path.basename(paths.items[0]));
    }
}

const current_claude = "c1000000-0000-4000-8000-0000000000c1";
const current_codex = "019a0000-0000-7000-8000-00000000c0de";
const current_files = embedTree("current-environment/", &.{
    "claude/projects/-work-current/" ++ current_claude ++ ".jsonl",
    "codex/sessions/2026/11/10/rollout-2026-11-10T16-00-00-" ++ current_codex ++ ".jsonl",
    "pi/session.jsonl",
});

fn currentEnvironment(base: []const u8, mask: u3) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(allocator);
    errdefer environment.deinit();
    const home = try std.fs.path.join(allocator, &.{ base, "home" });
    defer allocator.free(home);
    const codex = try std.fs.path.join(allocator, &.{ base, "codex" });
    defer allocator.free(codex);
    const claude = try std.fs.path.join(allocator, &.{ base, "claude" });
    defer allocator.free(claude);
    const pi = try std.fs.path.join(allocator, &.{ base, "pi", "session.jsonl" });
    defer allocator.free(pi);
    try environment.put("HOME", home);
    try environment.put("CODEX_HOME", codex);
    try environment.put("CLAUDE_CONFIG_DIR", claude);
    if (mask & 1 != 0) try environment.put("CODEX_THREAD_ID", current_codex);
    if (mask & 2 != 0) try environment.put("PI_SESSION_FILE", pi);
    if (mask & 4 != 0) try environment.put("CLAUDE_CODE_SESSION_ID", current_claude);
    return environment;
}

fn currentExpectation(mask: u3, source: ?native.Source) union(enum) {
    file: []const u8,
    ambiguous,
    unavailable,
} {
    const names = [_][]const u8{
        std.fs.path.basename(current_files[1].path),
        "session.jsonl",
        current_claude ++ ".jsonl",
    };
    if (source) |selected| {
        const bit: u2 = switch (selected) {
            .codex => 0,
            .pi => 1,
            .claude_code => 2,
        };
        if (mask & (@as(u3, 1) << bit) == 0) return .unavailable;
        return .{ .file = names[bit] };
    }
    if (@popCount(mask) > 1) return .ambiguous;
    if (mask == 0) return .unavailable;
    return .{ .file = names[@ctz(mask)] };
}

test "current-environment: every hint-family combination with and without --source" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try support.writeTree(tmp.dir, &current_files);
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(base);
    const sources = [_]?native.Source{ null, .codex, .claude_code, .pi };
    for (0..8) |raw_mask| {
        const mask: u3 = @intCast(raw_mask);
        var environment = try currentEnvironment(base, mask);
        defer environment.deinit();
        for (sources) |source| {
            const options = native.Options{
                .current = true,
                .source = source,
                .environment = &environment,
            };
            const outcome = native.resolveTargetPaths(
                allocator,
                testing.io,
                std.Io.Dir.cwd(),
                options,
                true,
            );
            switch (currentExpectation(mask, source)) {
                .file => |name| {
                    var paths = try outcome;
                    defer native.freePaths(allocator, &paths);
                    try testing.expectEqual(@as(usize, 1), paths.items.len);
                    try testing.expectEqualStrings(name, std.fs.path.basename(paths.items[0]));
                },
                .ambiguous => try testing.expectError(error.AmbiguousCurrentSessionSource, outcome),
                .unavailable => {
                    if (outcome) |paths_value| {
                        var paths = paths_value;
                        native.freePaths(allocator, &paths);
                        return error.TestExpectedError;
                    } else |err| try testing.expect(err != error.AmbiguousCurrentSessionSource);
                },
            }
        }
    }
}

test "default roots: Claude root follows CLAUDE_CONFIG_DIR and is never inferred" {
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("HOME", "/user");
    const options = native.Options{ .environment = &environment };
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    const home_root = try native.resolveSourceRootAlloc(allocator, options, .claude_code, io, cwd);
    defer allocator.free(home_root);
    try testing.expectEqualStrings("/user/.claude/projects", home_root);
    try environment.put("CLAUDE_CONFIG_DIR", "/config/claude");
    const config_root = try native.resolveSourceRootAlloc(
        allocator,
        options,
        .claude_code,
        io,
        cwd,
    );
    defer allocator.free(config_root);
    try testing.expectEqualStrings("/config/claude/projects", config_root);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try support.writeTree(tmp.dir, &.{.{
        .path = "home/.claude/projects/-w/" ++ session_id ++ ".jsonl",
        .bytes = @embedFile(fixture_root ++ "session.jsonl"),
    }});
    try tmp.dir.createDirPath(io, "home/.codex/sessions");
    const home = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home);
    var local = std.process.Environ.Map.init(allocator);
    defer local.deinit();
    try local.put("HOME", home);
    const implicit_options = native.Options{ .environment = &local };
    var implicit = try native.resolveTargetPaths(allocator, io, cwd, implicit_options, false);
    defer native.freePaths(allocator, &implicit);
    try testing.expectEqual(@as(usize, 0), implicit.items.len);
    var selected = try native.resolveTargetPaths(
        allocator,
        io,
        cwd,
        .{ .environment = &local, .source = .claude_code },
        false,
    );
    defer native.freePaths(allocator, &selected);
    try testing.expectEqual(@as(usize, 1), selected.items.len);
}

test "discovery prefix: a seed beyond 256 lines leaves prefix-only fields unset" {
    const source = @embedFile(fixture_root ++ "metadata-first.jsonl");
    const queue = try firstLineOfType(source, "queue-operation");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    for (0..300) |_| {
        try bytes.appendSlice(allocator, queue);
        try bytes.append(allocator, '\n');
    }
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"rec-m0") == null) continue;
        if (std.mem.indexOf(u8, line, "file-history-snapshot") != null) continue;
        try bytes.appendSlice(allocator, line);
        try bytes.append(allocator, '\n');
    }
    const path = "projects/-work-meta/bounded.jsonl";
    var trace = try support.parse(allocator, path, bytes.items, .stale);
    defer trace.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.claude, trace.source);
    try expectString("5e551000-0000-4000-8000-000000000006", trace.session.session_id);
    try expectString("2026-11-10T14:00:05.000Z", trace.session.start_time);
    try expectString("2026-11-10T15:00:00.000Z", trace.session.end_time);
    try testing.expect(trace.session.cwd == null);
    try testing.expect(trace.session.git_branch == null);
    try testing.expect(trace.session.cli_version == null);
    try testing.expectEqual(@as(usize, 1), trace.turns.items.len);
}

test "worker discovery identity comes from the path and the sidecar" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = "proj/" ++ root_n ++ "/subagents/";
    const files = comptime embedTree("nested-worker/", &.{
        base ++ "agent-bbbb0000000000002.jsonl",
        base ++ "agent-bbbb0000000000002.meta.json",
        base ++ "agent-aaaa0000000000001.jsonl",
    });
    try support.writeTree(tmp.dir, &files);
    var identity = try trace_adapter.discoverSessionIdentity(
        testing.io,
        tmp.dir,
        allocator,
        files[0].path,
        .{},
        null,
    );
    defer identity.deinit(allocator);
    try testing.expectEqual(trace_core.TraceSource.claude, identity.source);
    try expectString(root_n ++ "/agent-bbbb0000000000002", identity.session_id);
    try expectString(root_n, identity.root_session_id);
    const parent = root_n ++ "/agent-aaaa0000000000001";
    try expectString(parent, identity.control_parent_session_id);
    try testing.expect(!identity.lineage_conflict);
    try testing.expect(identity.sidecar_mtime_ns != null);
    try testing.expect(identity.parent_session_id == null);
}

test "session status, titles and modeled metadata payloads" {
    var session = try parseFixture("session.jsonl", session_path);
    defer session.deinit(allocator);
    try expectString("claude_end_turn", session.session.status_reason);
    try testing.expect(!session.session.is_ongoing);
    const path = "projects/-w/5e551000-0000-4000-8000-000000000004.jsonl";
    var titles = try parseFixture("titles.jsonl", path);
    defer titles.deinit(allocator);
    for ([_]usize{ 2, 3, 5, 6 }) |line| {
        const occurrence = occurrenceAt(&titles, line);
        try testing.expect(!occurrence.private);
        try testing.expect(occurrence.payload_json != null);
        try testing.expect(!occurrence.message_visible);
    }
    try testing.expectEqualStrings("custom-title", occurrenceAt(&titles, 3).entry_type);
}

test "session selection: a stale recorded sessionId does not name the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const stem = "5e551000-0000-4000-8000-000000000009";
    try support.writeTree(tmp.dir, &.{.{
        .path = "projects/-w/" ++ stem ++ ".jsonl",
        .bytes = @embedFile(fixture_root ++ "legacy-origin.jsonl"),
    }});
    const projects = try tmp.dir.realPathFileAlloc(testing.io, "projects", allocator);
    defer allocator.free(projects);
    const cwd = std.Io.Dir.cwd();
    var named = try native.resolveTargetPaths(allocator, testing.io, cwd, .{
        .root = projects,
        .session_id = stem,
    }, true);
    defer native.freePaths(allocator, &named);
    try testing.expectEqualStrings(stem ++ ".jsonl", std.fs.path.basename(named.items[0]));
    try testing.expectError(error.SessionNotFound, native.resolveTargetPaths(
        allocator,
        testing.io,
        cwd,
        .{ .root = projects, .session_id = "5e551000-0000-4000-8000-00000000000a" },
        true,
    ));
}

test "current Claude session in a worker family resolves the root transcript" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try support.writeTree(tmp.dir, &scope_files);
    const config = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(config);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("HOME", config);
    try environment.put("CLAUDE_CONFIG_DIR", config);
    try environment.put("CLAUDE_CODE_SESSION_ID", r8);
    var paths = try native.resolveTargetPaths(allocator, testing.io, std.Io.Dir.cwd(), .{
        .current = true,
        .source = .claude_code,
        .environment = &environment,
    }, true);
    defer native.freePaths(allocator, &paths);
    try testing.expectEqualStrings(r8 ++ ".jsonl", std.fs.path.basename(paths.items[0]));
}
