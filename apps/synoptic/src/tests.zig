const std = @import("std");
const app = @import("app.zig");
const config = @import("config.zig");
const domain = @import("domain.zig");
const github = @import("github.zig");
const graphql = @import("graphql.zig");
const http = @import("http.zig");
const main = @import("main.zig");
const pr = @import("pr.zig");
const sessions = @import("sessions.zig");
const tools = @import("tools.zig");
const ui = @import("ui_protocol.zig");
const worktree = @import("worktree.zig");

test "vertical state path gates primary, streams session, and retains completed tab" {
    var state = try app.App.init(std.testing.allocator, "head");
    defer state.deinit();
    try state.generation.addFile(.{ .path = "src/a.zig", .viewed = .unviewed, .revision_key = "r1" });
    try std.testing.expectError(error.PrimaryNotReady, state.openFile("src/a.zig"));
    state.primary_ready = true;
    const event = try state.openFile("src/a.zig");
    defer std.testing.allocator.free(event);
    try std.testing.expect(std.mem.indexOf(u8, event, "session.opened") != null);
    state.initial_review_active = false;
    const input = tools.PreparedActionInput{ .slot = @constCast("finding-1"), .kind = .add_inline_comment, .effect_summary = @constCast("Add a comment"), .payload_json = @constCast("{}"), .path = @constCast("src/a.zig"), .line = 12, .body = @constCast("Could this fail?") };
    _ = try state.prepareModelAction("s", "t", input, "o/r", 1, "PR_1", "src/a.zig");
    try std.testing.expectEqual(tools.ActionStatus.pending, state.pending.?.status);
    state.close();
    try std.testing.expect(state.generation.queued("src/a.zig"));
}

test "session context unresolved assigned-file evidence preserves complete comments" {
    const raw = "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"nodes\":[{\"id\":\"T1\",\"path\":\"a.zig\",\"line\":7,\"startLine\":6,\"diffSide\":\"RIGHT\",\"startDiffSide\":\"RIGHT\",\"subjectType\":\"LINE\",\"isResolved\":false,\"isOutdated\":false,\"viewerCanReply\":true,\"viewerCanResolve\":true,\"viewerCanUnresolve\":false,\"comments\":{\"nodes\":[{\"id\":\"C1\",\"body\":\"risk evidence\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"url\":\"https://example/C1\",\"author\":{\"login\":\"reviewer\"},\"viewerDidAuthor\":true,\"pullRequestReview\":{\"id\":\"R1\",\"state\":\"COMMENTED\"}}]}}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}}";
    var generation = try domain.PrGeneration.initFull(std.testing.allocator, "b", "h");
    defer generation.deinit();
    try github.loadThreads(std.testing.allocator, raw, &generation);
    const evidence = try generation.unresolvedThreadsJsonAlloc(std.testing.allocator, "a.zig", null, &.{}, false);
    defer std.testing.allocator.free(evidence);
    inline for (.{ "T1", "C1", "risk evidence", "reviewer", "viewer_can_reply", "review_state" }) |needle| try std.testing.expect(std.mem.indexOf(u8, evidence, needle) != null);
}

test "falsifier initial review cannot prepare action" {
    try std.testing.expect(!tools.initialReviewMayPrepareAction(true, true));
}
test "falsifier action tool is rejected during initial review" {
    var state = try app.App.init(std.testing.allocator, "head");
    defer state.deinit();
    try state.generation.addFile(.{ .path = "a", .viewed = .unviewed, .revision_key = "r" });
    state.primary_ready = true;
    const event = try state.openFile("a");
    defer std.testing.allocator.free(event);
    try std.testing.expectError(error.InitialReviewActionForbidden, tools.authorizeTool(.initial_review, true));
}
test "falsifier token is not optional" {
    try std.testing.expect(!http.pathConfined("/tmp/ui", "/tmp/ui2/index.html"));
}
test "App owns one monotonic UI sequence across event classes" {
    var state = try app.App.init(std.testing.allocator, "head");
    defer state.deinit();
    const one = try state.nextEnvelope("a", "{}");
    defer std.testing.allocator.free(one);
    const two = try state.nextEnvelope("b", "{}");
    defer std.testing.allocator.free(two);
    try std.testing.expect(std.mem.indexOf(u8, one, "\"seq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, two, "\"seq\":2") != null);
}
test "model prepared payload is decoded into owned immutable action input" {
    const raw = "{\"params\":{\"threadId\":\"file-1\",\"arguments\":{\"slot\":\"finding-1\",\"kind\":\"add_inline_comment\",\"effectSummary\":\"Add an inline comment on a.zig line 7\",\"payload\":{\"path\":\"a.zig\",\"line\":7,\"side\":\"RIGHT\",\"body\":\"Could this fail?\"}}}}";
    const input = try tools.decodePreparedAction(std.testing.allocator, raw);
    defer input.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("finding-1", input.slot);
    try std.testing.expectEqual(@as(u32, 7), input.line);
}
test "browser protocol exposes action confirmation but not preparation or completion bypasses" {
    try std.testing.expect(ui.commandAllowed("action.confirm"));
    try std.testing.expect(ui.commandAllowed("action.reject"));
    try std.testing.expect(!ui.commandAllowed("action.prepare"));
    try std.testing.expect(!ui.commandAllowed("file.complete"));
    try std.testing.expect(ui.commandAllowed("app.stop"));
}
test "action cards serialize exact effect target payload and rejection terminality" {
    var store = tools.ActionStore{ .allocator = std.testing.allocator };
    defer store.deinit();
    const input = tools.PreparedActionInput{ .slot = @constCast("reply"), .kind = .reply_thread, .effect_summary = @constCast("Reply to thread T_1"), .payload_json = @constCast("{\"threadId\":\"T_1\",\"body\":\"reply\"}"), .thread_id = @constCast("T_1"), .body = @constCast("reply") };
    const card = try store.prepare("ses-9", "turn-4", input, .{ .repository = "o/r", .pull_request = 2, .pull_request_id = "PR_2", .head_oid = "head", .session_path = "a.zig" });
    const encoded = try tools.cardJsonAlloc(std.testing.allocator, card.*);
    defer std.testing.allocator.free(encoded);
    inline for (.{ "synoptic-github-action/v1", "Reply to thread T_1", "T_1", "ses-9", "turn-4", "\"payload\":{\"threadId\":\"T_1\"" }) |needle| try std.testing.expect(std.mem.indexOf(u8, encoded, needle) != null);
    try store.reject(card.id);
    try std.testing.expectEqual(tools.ActionStatus.rejected, store.cards.items[0].status);
    try std.testing.expectError(error.ActionNotPending, store.beginExecute(card.id));
}
test "e2e domain lifecycle preserves queue tabs supersession and changed revision" {
    var state = try app.App.init(std.testing.allocator, "h1");
    defer state.deinit();
    try state.generation.addFile(.{ .path = "a", .viewed = .unviewed, .revision_key = "r1" });
    try state.generation.addFile(.{ .path = "b", .viewed = .unviewed, .revision_key = "b1" });
    try std.testing.expectError(error.PrimaryNotReady, state.openFile("a"));
    state.primary_ready = true;
    const opened = try state.openFile("a");
    defer std.testing.allocator.free(opened);
    state.initial_review_active = false;
    const first_action = tools.PreparedActionInput{ .slot = @constCast("finding-1"), .kind = .add_inline_comment, .effect_summary = @constCast("First"), .payload_json = @constCast("{}"), .path = @constCast("a"), .line = 1, .body = @constCast("first") };
    const replacement_action = tools.PreparedActionInput{ .slot = @constCast("finding-1"), .kind = .add_inline_comment, .effect_summary = @constCast("Replacement"), .payload_json = @constCast("{}"), .path = @constCast("a"), .line = 2, .body = @constCast("replacement") };
    _ = try state.prepareModelAction("s", "t1", first_action, "o/r", 1, "PR_1", "a");
    _ = try state.prepareModelAction("s", "t2", replacement_action, "o/r", 1, "PR_1", "a");
    try std.testing.expectEqual(tools.ActionStatus.superseded, state.action_store.cards.items[0].status);
    const second = try state.openFile("b");
    defer std.testing.allocator.free(second);
    state.close();
    try std.testing.expect(state.generation.queued("a"));
    try std.testing.expect(state.generation.queued("b"));
    var next = try domain.PrGeneration.initFull(std.testing.allocator, "base", "h2");
    try next.addFile(.{ .path = "a", .viewed = .unviewed, .revision_key = "r2" });
    try next.addFile(.{ .path = "b", .viewed = .unviewed, .revision_key = "b1" });
    state.replaceGeneration(next);
    const reopened = try state.openFile("a");
    defer std.testing.allocator.free(reopened);
    try std.testing.expectEqual(domain.SessionStatus.stale_origin, state.tabs.items[0].status);
    try std.testing.expectEqual(domain.SessionStatus.current, state.tabs.items[state.tabs.items.len - 1].status);
    try std.testing.expectEqual(@as(u64, 2), state.finishRound());
}

const NetworkFixture = struct {
    server: *http.Server,
    runtime: *http.Runtime,
    failed: std.atomic.Value(bool) = .init(false),

    fn serve(self: *NetworkFixture) void {
        self.server.serveOne(self.runtime) catch |err| switch (err) {
            error.EndOfStream, error.ConnectionResetByPeer => {},
            else => self.failed.store(true, .release),
        };
    }
};

fn sendMaskedText(io: std.Io, stream: *std.Io.net.Stream, text: []const u8) !void {
    if (text.len > 125) return error.TestFrameTooLarge;
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    var header = [2]u8{ 0x81, 0x80 | @as(u8, @intCast(text.len)) };
    var payload: [125]u8 = undefined;
    for (text, 0..) |byte, i| payload[i] = byte ^ mask[i % mask.len];
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(&mask);
    try writer.interface.writeAll(payload[0..text.len]);
    try writer.interface.flush();
}

fn receiveExact(io: std.Io, stream: *std.Io.net.Stream, destination: []u8) !void {
    var used: usize = 0;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(2_000), .clock = .awake });
    while (used < destination.len) {
        const incoming = try stream.socket.receiveTimeout(io, destination[used..], .{ .deadline = deadline });
        if (incoming.data.len == 0) return error.EndOfStream;
        used += incoming.data.len;
    }
}

fn readServerText(allocator: std.mem.Allocator, io: std.Io, stream: *std.Io.net.Stream) ![]u8 {
    var header: [2]u8 = undefined;
    try receiveExact(io, stream, &header);
    if (header[0] != 0x81 or header[1] & 0x80 != 0) return error.InvalidServerFrame;
    var len: usize = header[1] & 0x7f;
    if (len == 126) {
        var extended: [2]u8 = undefined;
        try receiveExact(io, stream, &extended);
        len = std.mem.readInt(u16, &extended, .big);
    }
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
    try receiveExact(io, stream, payload);
    return payload;
}

fn readUntil(allocator: std.mem.Allocator, io: std.Io, stream: *std.Io.net.Stream, needle: []const u8) ![]u8 {
    for (0..16) |_| {
        const frame = try readServerText(allocator, io, stream);
        if (std.mem.indexOf(u8, frame, needle) != null) return frame;
        allocator.free(frame);
    }
    return error.ExpectedWebSocketEventMissing;
}

fn fakeCodexScript() []const u8 {
    return
    \\#!/bin/sh
    \\set -eu
    \\if [ "${1:-}" = "--version" ]; then printf '%s\n' 'codex-test 1.0.0'; exit 0; fi
    \\if [ "${1:-}" = "app-server" ] && [ "${2:-}" = "generate-json-schema" ]; then
    \\  out=''
    \\  while [ "$#" -gt 0 ]; do if [ "$1" = "--out" ] || [ "$1" = "-o" ]; then shift; out="$1"; fi; shift; done
    \\  mkdir -p "$out/v2"
    \\  printf '%s' '{"methods":["initialize","initialized","thread/start","thread/fork","turn/start","turn/steer","turn/interrupt","thread/inject_items","item/tool/call","item/commandExecution/requestApproval","item/fileChange/requestApproval","item/permissions/requestApproval"]}' > "$out/codex_app_server_protocol.schemas.json"
    \\  cp "$out/codex_app_server_protocol.schemas.json" "$out/codex_app_server_protocol.v2.schemas.json"
    \\  printf '%s' '{"lastTurnId":{},"ephemeral":{}}' > "$out/v2/ThreadForkParams.json"
    \\  printf '%s' '{"dynamicTools":{}}' > "$out/v2/ThreadStartParams.json"
    \\  printf '%s' '{"SkillUserInput":{"required":["name","path","type"]}}' > "$out/v2/TurnStartParams.json"
    \\  for f in ThreadStartedNotification TurnStartedNotification ItemStartedNotification AgentMessageDeltaNotification; do printf '%s' '{}' > "$out/v2/$f.json"; done
    \\  printf '%s' '{"properties":{"threadId":{},"availableDecisions":{}},"required":["threadId"]}' > "$out/CommandExecutionRequestApprovalParams.json"
    \\  printf '%s' '{"properties":{"decision":{}},"required":["decision"],"values":["accept","acceptForSession","decline","cancel"]}' > "$out/CommandExecutionRequestApprovalResponse.json"
    \\  printf '%s' '{"properties":{"decision":{}},"required":["decision"],"values":["decline"]}' > "$out/FileChangeRequestApprovalResponse.json"
    \\  printf '%s' '{"properties":{"threadId":{},"permissions":{}},"required":["threadId","permissions"]}' > "$out/PermissionsRequestApprovalParams.json"
    \\  printf '%s' '{"properties":{"permissions":{},"scope":{}},"required":["permissions"],"values":["turn","session"]}' > "$out/PermissionsRequestApprovalResponse.json"
    \\  exit 0
    \\fi
    \\forks=0
    \\primary_turns=0
    \\while IFS= read -r line; do
    \\  printf '%s\n' "$line" >> "$0.log"
    \\  case "$line" in
    \\    *'"method":"initialize"'*) printf '%s\n' '{"id":-1,"result":{}}'; continue ;;
    \\    *'"method":"initialized"'*) continue ;;
    \\    *'"id":"tool-'*) continue ;;
    \\    *'"id":"approval-command"'*) printf '%s' "$line" | grep -q '"decision":"accept"'; printf '%s\n' '{"method":"turn/completed","params":{"threadId":"file-1","turn":{"id":"file-turn"}}}'; continue ;;
    \\    *'"id":"approval-file-change"'*) printf '%s' "$line" | grep -q '"decision":"decline"'; printf '%s\n' '{"method":"turn/completed","params":{"threadId":"file-1","turn":{"id":"file-turn"}}}'; continue ;;
    \\    *'"id":"approval-primary"'*) printf '%s' "$line" | grep -Eq '"decision":"(accept|decline)"'; printf '%s\n' '{"method":"turn/completed","params":{"threadId":"primary","turn":{"id":"primary-turn"}}}'; continue ;;
    \\  esac
    \\  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  case "$line" in
    \\    *'"method":"thread/start"'*) printf '{"id":%s,"result":{"thread":{"id":"primary"}}}\n' "$id" ;;
    \\    *'"method":"thread/fork"'*) forks=$((forks + 1)); printf '{"id":%s,"result":{"thread":{"id":"file-%s"}}}\n' "$id" "$forks" ;;
    \\    *'"method":"thread/inject_items"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
    \\    *'"method":"turn/interrupt"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
    \\    *'"method":"turn/start"'*)
    \\      if printf '%s' "$line" | grep -q '"threadId":"primary"'; then
    \\        primary_turns=$((primary_turns + 1))
    \\        printf '{"id":%s,"result":{"turn":{"id":"primary-turn"}}}\n' "$id"
    \\        if [ "$primary_turns" -gt 1 ]; then
    \\          printf '%s\n' '{"id":"approval-primary","method":"item/commandExecution/requestApproval","params":{"threadId":"primary","turnId":"primary-turn","itemId":"primary-cmd","startedAtMs":1,"command":"git log --oneline","availableDecisions":["accept","decline"]}}'
    \\          continue
    \\        fi
    \\        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"primary","turn":{"id":"primary-turn"}}}'
    \\      else
    \\        thread_id=$(printf '%s\n' "$line" | sed -n 's/.*"threadId":"\([^"]*\)".*/\1/p')
    \\        printf '{"id":%s,"result":{"turn":{"id":"file-turn"}}}\n' "$id"
    \\        if printf '%s' "$line" | grep -q 'prepare the comment'; then
    \\          printf '{"id":"tool-prepare","method":"item/tool/call","params":{"threadId":"%s","tool":"synoptic.prepare_github_action","arguments":{"slot":"finding-1","kind":"add_inline_comment","effectSummary":"Add an inline comment on a.zig line 1","payload":{"path":"a.zig","line":1,"side":"RIGHT","body":"Could this fail?"}}}}\n' "$thread_id"
    \\        elif printf '%s' "$line" | grep -q 'complete this file'; then
    \\          printf '{"id":"tool-complete","method":"item/tool/call","params":{"threadId":"%s","tool":"synoptic.complete_file_review","arguments":{}}}\n' "$thread_id"
    \\        elif printf '%s' "$line" | grep -q 'close this session'; then
    \\          printf '{"id":"tool-close","method":"item/tool/call","params":{"threadId":"%s","tool":"synoptic.close_session","arguments":{}}}\n' "$thread_id"
    \\        elif printf '%s' "$line" | grep -q 'search cross-file'; then
    \\          printf '{"id":"tool-search","method":"item/tool/call","params":{"threadId":"%s","tool":"synoptic.search_unresolved_threads","arguments":{"query":"risk","paths":[],"includeWholePullRequest":true}}}\n' "$thread_id"
    \\        elif printf '%s' "$line" | grep -q 'run approved command'; then
    \\          printf '{"id":"approval-command","method":"item/commandExecution/requestApproval","params":{"threadId":"%s","turnId":"file-turn","itemId":"cmd-1","startedAtMs":1,"command":"make test","availableDecisions":["accept","decline"]}}\n' "$thread_id"
    \\          continue
    \\        elif printf '%s' "$line" | grep -q 'attempt file change'; then
    \\          printf '{"id":"approval-file-change","method":"item/fileChange/requestApproval","params":{"threadId":"%s","turnId":"file-turn","itemId":"patch-1","reason":"write"}}\n' "$thread_id"
    \\          continue
    \\        else
    \\          printf '{"method":"item/agentMessage/delta","params":{"threadId":"%s","delta":"review visible"}}\n' "$thread_id"
    \\        fi
    \\        printf '{"method":"turn/completed","params":{"threadId":"%s","turn":{"id":"file-turn"}}}\n' "$thread_id"
    \\      fi ;;
    \\    *) printf '{"id":%s,"result":{}}\n' "$id" ;;
    \\  esac
    \\done
    ;
}

fn fakeGhScriptAlloc(allocator: std.mem.Allocator, log_path: []const u8, state_path: []const u8, head: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\set -eu
        \\log='{s}'
        \\state='{s}'
        \\printf 'ARGV:%s\n' "$*" >> "$log"
        \\input=$(mktemp)
        \\trap 'rm -f "$input"' EXIT
        \\cat > "$input"
        \\printf 'STDIN:' >> "$log"; cat "$input" >> "$log"; printf '\n' >> "$log"
        \\if grep -q 'SynopticAddInlineComment' "$input"; then printf '%s\n' '{{"data":{{"addPullRequestReview":{{"pullRequestReview":{{"id":"review-1","url":"https://example/review"}}}}}}}}'; exit 0; fi
        \\if grep -q 'SynopticMarkFileViewed' "$input"; then printf '%s\n' viewed > "$state"; printf '%s\n' '{{"data":{{"markFileAsViewed":{{"pullRequest":{{"id":"PR_1"}}}}}}}}'; exit 0; fi
        \\if grep -q 'SynopticFileState' "$input"; then viewed=UNVIEWED; [ -f "$state" ] && viewed=VIEWED; printf '{{"data":{{"repository":{{"pullRequest":{{"headRefOid":"{s}","files":{{"nodes":[{{"path":"a.zig","viewerViewedState":"%s"}},{{"path":"b.zig","viewerViewedState":"UNVIEWED"}}],"pageInfo":{{"hasNextPage":false,"endCursor":null}}}}}}}}}}}}\n' "$viewed"; exit 0; fi
        \\if grep -q 'SynopticAnchor' "$input"; then printf '%s\n' '{{"data":{{"repository":{{"pullRequest":{{"headRefOid":"{s}","files":{{"nodes":[{{"path":"a.zig"}},{{"path":"b.zig"}}],"pageInfo":{{"hasNextPage":false,"endCursor":null}}}}}}}}}}}}'; exit 0; fi
        \\printf '%s\n' '{{"data":{{}}}}'
        \\
    , .{ log_path, state_path, head, head });
}

fn fakeActionGhScriptAlloc(allocator: std.mem.Allocator, log_path: []const u8) ![]u8 {
    const template =
        \\#!/bin/sh
        \\set -eu
        \\log='__LOG__'
        \\input=$(mktemp)
        \\trap 'rm -f "$input"' EXIT
        \\cat > "$input"
        \\printf 'ARGV:%s\nSTDIN:' "$*" >> "$log"; cat "$input" >> "$log"; printf '\n' >> "$log"
        \\if grep -q 'SynopticActionAuthority' "$input"; then
        \\  printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"h","reviewThreads":{"nodes":[{"id":"T_1","path":"a.zig","viewerCanReply":true,"viewerCanResolve":true,"viewerCanUnresolve":true,"comments":{"nodes":[{"id":"C_1","body":"old","viewerDidAuthor":true}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'; exit 0
        \\fi
        \\if grep -q 'SynopticAnchor' "$input"; then
        \\  printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"h","files":{"nodes":[{"path":"a.zig"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'; exit 0
        \\fi
        \\if grep -q 'SynopticFileState' "$input"; then
        \\  printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"h","files":{"nodes":[{"path":"a.zig","viewerViewedState":"UNVIEWED"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'; exit 0
        \\fi
        \\printf '%s\n' '{"data":{"ok":{"clientMutationId":"accepted"}}}'
        \\
    ;
    return std.mem.replaceOwned(u8, allocator, template, "__LOG__", log_path);
}

fn fakeAmbiguousGhScriptAlloc(allocator: std.mem.Allocator, log_path: []const u8) ![]u8 {
    const template =
        \\#!/bin/sh
        \\set -eu
        \\log='__LOG__'
        \\input=$(mktemp)
        \\trap 'rm -f "$input"' EXIT
        \\cat > "$input"
        \\cat "$input" >> "$log"; printf '\n' >> "$log"
        \\if grep -q 'SynopticAnchor' "$input"; then printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"h","files":{"nodes":[{"path":"a.zig"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'; exit 0; fi
        \\if grep -q 'SynopticReconcile' "$input"; then now=$(date -u +%Y-%m-%dT%H:%M:%SZ); printf '{"data":{"repository":{"pullRequest":{"headRefOid":"h","reviewThreads":{"nodes":[{"id":"T_new","path":"a.zig","line":1,"isResolved":false,"comments":{"nodes":[{"id":"C_new","body":"body","createdAt":"%s","viewerDidAuthor":true}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}\n' "$now"; exit 0; fi
        \\if grep -q 'SynopticAddInlineComment' "$input"; then exit 1; fi
        \\printf '%s\n' '{"data":{}}'
        \\
    ;
    return std.mem.replaceOwned(u8, allocator, template, "__LOG__", log_path);
}

test "action broker typed and transparent matrix uses fixed argv and exact stdin" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh-actions" });
    defer allocator.free(gh_path);
    const log_path = try std.fs.path.join(allocator, &.{ root, "actions.log" });
    defer allocator.free(log_path);
    const script = try fakeActionGhScriptAlloc(allocator, log_path);
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh-actions", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(io, gh_path, std.Io.File.Permissions.fromMode(0o755), .{});

    const authoritative = tools.AuthoritativeTarget{ .repository = "o/r", .pull_request = 1, .pull_request_id = "PR_1", .head_oid = "h", .session_path = "a.zig" };
    var store = tools.ActionStore{ .allocator = allocator };
    defer store.deinit();
    const inputs = [_]tools.PreparedActionInput{
        .{ .slot = @constCast("reply"), .kind = .reply_thread, .effect_summary = @constCast("Reply to thread T_1"), .payload_json = @constCast("{}"), .thread_id = @constCast("T_1"), .body = @constCast("reply") },
        .{ .slot = @constCast("resolve"), .kind = .resolve_thread, .effect_summary = @constCast("Resolve thread T_1"), .payload_json = @constCast("{}"), .thread_id = @constCast("T_1") },
        .{ .slot = @constCast("unresolve"), .kind = .unresolve_thread, .effect_summary = @constCast("Unresolve thread T_1"), .payload_json = @constCast("{}"), .thread_id = @constCast("T_1") },
        .{ .slot = @constCast("update"), .kind = .update_comment, .effect_summary = @constCast("Update comment C_1"), .payload_json = @constCast("{}"), .comment_id = @constCast("C_1"), .body = @constCast("updated") },
        .{ .slot = @constCast("delete"), .kind = .delete_comment, .effect_summary = @constCast("Delete comment C_1"), .payload_json = @constCast("{}"), .comment_id = @constCast("C_1") },
        .{ .slot = @constCast("unmark"), .kind = .unmark_viewed, .effect_summary = @constCast("Return a.zig to the unviewed queue"), .payload_json = @constCast("{}"), .path = @constCast("a.zig") },
        .{ .slot = @constCast("transparent"), .kind = .graphql, .effect_summary = @constCast("Add a PR note"), .payload_json = @constCast("{}"), .operation_name = @constCast("AddReviewNote"), .document = @constCast("mutation AddReviewNote($input:AddCommentInput!){addComment(input:$input){clientMutationId}}"), .variables = @constCast("{\"input\":{\"subjectId\":\"PR_1\",\"body\":\"note\"}}") },
    };
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_path };
    for (inputs, 0..) |input, i| {
        const source = try std.fmt.allocPrint(allocator, "turn-{d}", .{i});
        defer allocator.free(source);
        const card = try store.prepare("ses-1", source, input, authoritative);
        try broker.validateAction("o", "r", 1, "PR_1", card.*);
        try broker.executeAction(card.*);
        if (card.kind == .unmark_viewed) try std.testing.expect(try broker.viewedStateAfterMutation("o", "r", 1, "h", "a.zig", false));
    }
    var tampered = store.cards.items[store.cards.items.len - 1];
    var tampered_graphql = tampered.graphql.?;
    tampered_graphql.document = "mutation AddReviewNote($input:AddCommentInput!){hidden:addComment(input:$input){clientMutationId}}";
    tampered.graphql = tampered_graphql;
    try std.testing.expectError(error.GraphqlAliasForbidden, broker.executeAction(tampered));
    const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    try std.testing.expectEqual(std.mem.count(u8, log, "ARGV:api graphql --hostname github.com --input -"), std.mem.count(u8, log, "ARGV:"));
    inline for (.{ "SynopticReply", "SynopticResolveThread", "SynopticUnresolveThread", "SynopticUpdateComment", "SynopticDeleteComment", "SynopticUnmarkFileViewed", "mutation AddReviewNote" }) |needle| try std.testing.expect(std.mem.indexOf(u8, log, needle) != null);
    inline for (.{ "\"pullRequestReviewThreadId\":\"T_1\"", "\"pullRequestReviewCommentId\":\"C_1\"", "\"subjectId\":\"PR_1\"", "\"path\":\"a.zig\"" }) |needle| try std.testing.expect(std.mem.indexOf(u8, log, needle) != null);

    var state = try app.App.init(allocator, "h");
    defer state.deinit();
    try state.generation.addFile(.{ .path = "a.zig", .viewed = .viewed, .revision_key = "r" });
    const unmark = inputs[5];
    const unmark_card = try state.action_store.prepare("ses-unmark", "turn-unmark", unmark, authoritative);
    try broker.validateAction("o", "r", 1, "PR_1", unmark_card.*);
    try std.testing.expectEqual(tools.ActionStatus.succeeded, try state.confirmAction(broker, "o", "r", 1, unmark_card.id));
    try std.testing.expect(state.generation.queued("a.zig"));
}

test "action broker reconciles an ambiguous mutation once without retry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh-ambiguous" });
    defer allocator.free(gh_path);
    const log_path = try std.fs.path.join(allocator, &.{ root, "ambiguous.log" });
    defer allocator.free(log_path);
    const script = try fakeAmbiguousGhScriptAlloc(allocator, log_path);
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh-ambiguous", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(io, gh_path, std.Io.File.Permissions.fromMode(0o755), .{});
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_path };
    var state = try app.App.init(allocator, "h");
    defer state.deinit();
    try state.generation.addFile(.{ .path = "a.zig", .viewed = .unviewed, .revision_key = "r" });
    const input = tools.PreparedActionInput{ .slot = @constCast("finding"), .kind = .add_inline_comment, .effect_summary = @constCast("Add the inline comment"), .payload_json = @constCast("{}"), .path = @constCast("a.zig"), .line = 1, .side = @constCast("RIGHT"), .body = @constCast("body") };
    const card = try state.action_store.prepare("ses-1", "turn-2", input, .{ .repository = "o/r", .pull_request = 1, .pull_request_id = "PR_1", .head_oid = "h", .session_path = "a.zig" });
    try broker.validateAction("o", "r", 1, "PR_1", card.*);
    try std.testing.expectEqual(tools.ActionStatus.succeeded, try state.confirmAction(broker, "o", "r", 1, card.id));
    const unmatched_input = tools.PreparedActionInput{ .slot = @constCast("finding-2"), .kind = .add_inline_comment, .effect_summary = @constCast("Add the other inline comment"), .payload_json = @constCast("{}"), .path = @constCast("a.zig"), .line = 1, .side = @constCast("RIGHT"), .body = @constCast("different body") };
    const unmatched = try state.action_store.prepare("ses-1", "turn-3", unmatched_input, .{ .repository = "o/r", .pull_request = 1, .pull_request_id = "PR_1", .head_oid = "h", .session_path = "a.zig" });
    try broker.validateAction("o", "r", 1, "PR_1", unmatched.*);
    try std.testing.expectEqual(tools.ActionStatus.outcome_unknown, try state.confirmAction(broker, "o", "r", 1, unmatched.id));
    const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, log, "SynopticAddInlineComment"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, log, "SynopticReconcile"));
}

test "updated comment reconciliation matches identity author and body regardless of creation age" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh-update-reconcile" });
    defer allocator.free(gh_path);
    const log_path = try std.fs.path.join(allocator, &.{ root, "update-reconcile.log" });
    defer allocator.free(log_path);
    const script = try fakeAmbiguousGhScriptAlloc(allocator, log_path);
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh-update-reconcile", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(io, gh_path, std.Io.File.Permissions.fromMode(0o755), .{});

    var store = tools.ActionStore{ .allocator = allocator };
    defer store.deinit();
    const card = try store.prepare("ses-update", "turn-update", .{
        .slot = @constCast("update"),
        .kind = .update_comment,
        .effect_summary = @constCast("Update comment C_new"),
        .payload_json = @constCast("{}"),
        .comment_id = @constCast("C_new"),
        .body = @constCast("body"),
    }, .{ .repository = "o/r", .pull_request = 1, .pull_request_id = "PR_1", .head_oid = "h", .session_path = "a.zig" });
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_path };
    // The fixture's createdAt is current, while the mutation start is far in
    // the future. Updates reconcile from immutable identity and final state,
    // not from the comment's original creation timestamp.
    try std.testing.expect(try broker.reconcileAction("o", "r", 1, card.*, 4_102_444_800));

    const wrong_body = try store.prepare("ses-update", "turn-update-2", .{
        .slot = @constCast("update-other"),
        .kind = .update_comment,
        .effect_summary = @constCast("Update comment C_new differently"),
        .payload_json = @constCast("{}"),
        .comment_id = @constCast("C_new"),
        .body = @constCast("other body"),
    }, .{ .repository = "o/r", .pull_request = 1, .pull_request_id = "PR_1", .head_oid = "h", .session_path = "a.zig" });
    try std.testing.expect(!try broker.reconcileAction("o", "r", 1, wrong_body.*, 0));
}

fn runGit(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.GitFixtureFailed;
    }
    return result.stdout;
}

test "exclusions config XDG precedence and strong classification" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skill/assets");
    try tmp.dir.createDirPath(io, "xdg/synoptic");
    try tmp.dir.createDirPath(io, "home/.config/synoptic");
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/assets/exclusions.json", .data = "{\"schema\":\"synoptic-exclusions/v1\",\"rules\":[{\"reason\":\"lockfile\",\"globs\":[\"package-lock.json\"]},{\"reason\":\"vendored\",\"globs\":[\"vendor/**\"]},{\"reason\":\"snapshot\",\"globs\":[\"**/__snapshots__/**\"]}]}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "xdg/synoptic/config.toml", .data = "[file_review]\nstart_mode = \"idle\"\n[browser]\nopen = false\n[worktree]\nprefer_current_pr_checkout = false\n[exclusions]\nenabled = true\nadditional_globs = [\"docs/generated/**\"]\nremoved_default_globs = [\"package-lock.json\"]\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/synoptic/config.toml", .data = "[file_review]\nstart_mode = \"immediate\"\n[browser]\nopen = true\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const skill = try std.fs.path.join(allocator, &.{ root, "skill" });
    defer allocator.free(skill);
    const xdg = try std.fs.path.join(allocator, &.{ root, "xdg" });
    defer allocator.free(xdg);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("XDG_CONFIG_HOME", xdg);
    try environment.put("HOME", home);
    var settings = try config.Settings.load(allocator, io, &environment, skill);
    defer settings.deinit();
    try std.testing.expectEqual(config.FileReviewStartMode.idle, settings.file_review_start_mode);
    try std.testing.expect(!settings.browser_open);
    try std.testing.expect(!settings.worktree_prefer_current_pr_checkout);
    try std.testing.expect(settings.classify("package-lock.json", "@@ text") == null);
    try std.testing.expectEqualStrings("vendored", settings.classify("vendor/lib/a.js", "@@ text").?);
    try std.testing.expectEqualStrings("configured-glob", settings.classify("docs/generated/api.md", "@@ text").?);
    try std.testing.expectEqualStrings("binary", settings.classify("assets/photo.dat", "GIT binary patch").?);
    try std.testing.expect(settings.classify("src/very-large.zig", "@@ ordinary source") == null);
    settings.exclusions_enabled = false;
    try std.testing.expect(settings.classify("vendor/lib/a.js", "GIT binary patch") == null);
}

test "exclusions config worktree preference can force managed custody without weakening cleanliness" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/a.zig", .data = "clean\n" });
    const repo = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo);
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.email", "synoptic@example.test" }, &.{ "git", "config", "user.name", "Synoptic Test" }, &.{ "git", "switch", "-qc", "feature" }, &.{ "git", "add", "." }, &.{ "git", "commit", "-qm", "head" } }) |argv| {
        const output = try runGit(allocator, io, repo, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    const output = try runGit(allocator, io, repo, &.{ "git", "remote", "add", "origin", repo });
    allocator.free(output);
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const unused = try std.fs.path.join(allocator, &.{ root, "unused" });
    defer allocator.free(unused);
    const reused = try worktree.select(allocator, io, repo, "feature", head, unused, true);
    defer allocator.free(reused.path());
    try std.testing.expect(reused == .reused_current);
    const managed_path = try std.fs.path.join(allocator, &.{ root, "managed" });
    defer allocator.free(managed_path);
    const managed = try worktree.select(allocator, io, repo, "feature", head, managed_path, false);
    defer allocator.free(managed.path());
    try std.testing.expect(managed == .managed);
}

test "exclusions config mutation readback and failure retention across generations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skill/assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/assets/exclusions.json", .data = "{\"schema\":\"synoptic-exclusions/v1\",\"rules\":[{\"reason\":\"lockfile\",\"globs\":[\"package-lock.json\"]},{\"reason\":\"vendored\",\"globs\":[\"vendor/**\"]}]}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "package-lock.json", .data = "base\n" });
    try tmp.dir.createDirPath(io, "vendor");
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/fail.js", .data = "base\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/ambiguous.js", .data = "base\n" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/large.zig", .data = "base\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.email", "synoptic@example.test" }, &.{ "git", "config", "user.name", "Synoptic Test" }, &.{ "git", "add", "." }, &.{ "git", "commit", "-qm", "base" } }) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    const base_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "package-lock.json", .data = "head\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/fail.js", .data = "head\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/ambiguous.js", .data = "head\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/large.zig", .data = "head\n" });
    for ([_][]const []const u8{ &.{ "git", "add", "." }, &.{ "git", "commit", "-qm", "head" } }) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    const state_path = try std.fs.path.join(allocator, &.{ root, "gh.state" });
    defer allocator.free(state_path);
    const log_path = try std.fs.path.join(allocator, &.{ root, "gh.log" });
    defer allocator.free(log_path);
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh" });
    defer allocator.free(gh_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nset -eu\ninput=$(cat)\nprintf '%s\\n%s\\n' \"$*\" \"$input\" >> {s}\nif printf '%s' \"$input\" | grep -q SynopticMarkFileViewed; then\n  if printf '%s' \"$input\" | grep -q 'vendor/fail.js'; then exit 1; fi\n  if printf '%s' \"$input\" | grep -q 'vendor/ambiguous.js'; then printf '%s\\n' ambiguous >> {s}; exit 1; fi\n  printf '%s\\n' package >> {s}\n  printf '%s\\n' '{{\"data\":{{\"markFileAsViewed\":{{\"pullRequest\":{{\"id\":\"PR_1\"}}}}}}}}'\n  exit 0\nfi\npackage_viewed=UNVIEWED\nambiguous_viewed=UNVIEWED\n[ -f {s} ] && grep -q package {s} && package_viewed=VIEWED\n[ -f {s} ] && grep -q ambiguous {s} && ambiguous_viewed=VIEWED\nprintf '{{\"data\":{{\"repository\":{{\"pullRequest\":{{\"headRefOid\":\"{s}\",\"files\":{{\"nodes\":[{{\"path\":\"package-lock.json\",\"viewerViewedState\":\"%s\"}},{{\"path\":\"vendor/fail.js\",\"viewerViewedState\":\"UNVIEWED\"}},{{\"path\":\"vendor/ambiguous.js\",\"viewerViewedState\":\"%s\"}},{{\"path\":\"src/large.zig\",\"viewerViewedState\":\"UNVIEWED\"}}],\"pageInfo\":{{\"hasNextPage\":false,\"endCursor\":null}}}}}}}}}}}}\\n' \"$package_viewed\" \"$ambiguous_viewed\"\n",
        .{ log_path, state_path, state_path, state_path, state_path, state_path, state_path, head },
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(io, gh_path, std.Io.File.Permissions.fromMode(0o755), .{});
    const skill = try std.fs.path.join(allocator, &.{ root, "skill" });
    defer allocator.free(skill);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var settings = try config.Settings.load(allocator, io, &environment, skill);
    defer settings.deinit();
    var state = try app.App.init(allocator, head);
    defer state.deinit();
    var generation = try domain.PrGeneration.initFull(allocator, base, head);
    try generation.addFile(.{ .path = "package-lock.json", .viewed = .unviewed, .revision_key = "r1" });
    try generation.addFile(.{ .path = "vendor/fail.js", .viewed = .unviewed, .revision_key = "r2" });
    try generation.addFile(.{ .path = "vendor/ambiguous.js", .viewed = .unviewed, .revision_key = "r3" });
    try generation.addFile(.{ .path = "src/large.zig", .viewed = .unviewed, .revision_key = "r4" });
    state.replaceGeneration(generation);
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_path };
    var outcomes = try state.applyAutomaticExclusions(&settings, broker, "o", "r", 1, "PR_1", root);
    defer {
        for (outcomes.items) |outcome| outcome.deinit();
        outcomes.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 3), outcomes.items.len);
    try std.testing.expect(!state.generation.queued("package-lock.json"));
    try std.testing.expect(state.generation.queued("vendor/fail.js"));
    try std.testing.expect(!state.generation.queued("vendor/ambiguous.js"));
    try std.testing.expect(state.generation.queued("src/large.zig"));
    try std.testing.expect(state.generation.files.items[1].exclusion_sync_error != null);
    try std.testing.expect(state.generation.files.items[2].exclusion_sync_error == null);
    const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "api graphql --hostname github.com --input -") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "synoptic-auto-exclusion") != null);

    var refreshed = try domain.PrGeneration.initFull(allocator, base, head);
    try refreshed.addFile(.{ .path = "package-lock.json", .viewed = .unviewed, .revision_key = "r4" });
    state.replaceGeneration(refreshed);
    var refreshed_outcomes = try state.applyAutomaticExclusions(&settings, broker, "o", "r", 1, "PR_1", root);
    defer {
        for (refreshed_outcomes.items) |outcome| outcome.deinit();
        refreshed_outcomes.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), refreshed_outcomes.items.len);
    try std.testing.expect(!state.generation.queued("package-lock.json"));
}

test "exclusions config immediate and idle sessions preserve canonical context" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.createDirPath(io, "skill/references");
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/SKILL.md", .data = "skill" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/file-review.md", .data = "file role" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/github-actions.md", .data = "actions" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/untrusted-repository-content.md", .data = "untrusted" });
    const codex_path = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    defer allocator.free(codex_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-codex", .data = fakeCodexScript() });
    try std.Io.Dir.cwd().setFilePermissions(io, codex_path, std.Io.File.Permissions.fromMode(0o755), .{});
    const skill_path = try std.fs.path.join(allocator, &.{ root, "skill", "SKILL.md" });
    defer allocator.free(skill_path);
    var registry = try sessions.Registry.start(allocator, io, root, codex_path);
    defer registry.deinit();
    registry.primary_thread_id = try allocator.dupe(u8, "primary");
    registry.latest_primary_turn_id = try allocator.dupe(u8, "primary-turn");
    const idle = try registry.openFile(io, root, "idle.zig", "r1", "base", "head", "canonical idle diff", "[]", skill_path, false);
    defer idle.deinit();
    var identity = try registry.sessionIdentity(idle.session_id);
    try std.testing.expectEqualStrings("", identity.turn_id);
    identity.deinit();
    try registry.markHumanInstruction(idle.session_id, "post this comment");
    try registry.message(idle.session_id, "review it", false);
    try std.testing.expect(registry.sessions.items[0].human_authority == null);
    identity = try registry.sessionIdentity(idle.session_id);
    try std.testing.expect(identity.turn_id.len > 0);
    identity.deinit();
    const immediate = try registry.openFile(io, root, "immediate.zig", "r2", "base", "head", "canonical immediate diff", "[]", skill_path, true);
    defer immediate.deinit();
    const log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{codex_path});
    defer allocator.free(log_path);
    const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "canonical idle diff") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "review it") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "canonical immediate diff") != null);
}

test "worktree integrity managed cleanup restores tracked and removes only review artifacts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = ".zig-cache/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "selected\n" });
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.email", "synoptic@example.test" }, &.{ "git", "config", "user.name", "Synoptic Test" }, &.{ "git", "add", ".gitignore", "tracked.txt" }, &.{ "git", "commit", "-qm", "selected" } }) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    try tmp.dir.createDirPath(io, ".zig-cache/preexisting");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/preexisting/keep", .data = "keep" });
    var baseline = try worktree.Baseline.capture(allocator, io, root);
    defer baseline.deinit();
    const selected = try allocator.dupe(u8, baseline.head_oid);
    defer allocator.free(selected);
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "review mutation\n" });
    try tmp.dir.createDirPath(io, ".zig-cache/review");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/review/output", .data = "artifact" });
    try worktree.reconcileShutdown(allocator, io, .{ .managed = root }, selected, &baseline);
    const tracked = try tmp.dir.readFileAlloc(io, "tracked.txt", allocator, .limited(1024));
    defer allocator.free(tracked);
    try std.testing.expectEqualStrings("selected\n", tracked);
    _ = try tmp.dir.statFile(io, ".zig-cache/preexisting/keep", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".zig-cache/review/output", .{}));
}

test "worktree integrity reused contamination blocks without cleanup" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "ignored/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "selected\n" });
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.email", "synoptic@example.test" }, &.{ "git", "config", "user.name", "Synoptic Test" }, &.{ "git", "add", "." }, &.{ "git", "commit", "-qm", "selected" } }) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    try tmp.dir.createDirPath(io, "ignored");
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored/before", .data = "before" });
    var baseline = try worktree.Baseline.capture(allocator, io, root);
    defer baseline.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored/after", .data = "after" });
    try std.testing.expectError(error.ReusedCheckoutRefreshRequiresManagedMigration, worktree.reconcileShutdown(allocator, io, .{ .reused_current = root }, baseline.head_oid, &baseline));
    _ = try tmp.dir.statFile(io, "ignored/after", .{});
}

test "worktree integrity managed cleanup rejects same-tree HEAD movement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "same tree\n" });
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.email", "synoptic@example.test" }, &.{ "git", "config", "user.name", "Synoptic Test" }, &.{ "git", "add", "." }, &.{ "git", "commit", "-qm", "selected" } }) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    var baseline = try worktree.Baseline.capture(allocator, io, root);
    defer baseline.deinit();
    const selected = try allocator.dupe(u8, baseline.head_oid);
    defer allocator.free(selected);
    const output = try runGit(allocator, io, root, &.{ "git", "commit", "--allow-empty", "-qm", "same tree other identity" });
    allocator.free(output);
    try std.testing.expectError(error.ManagedWorktreeCleanupIncomplete, worktree.reconcileShutdown(allocator, io, .{ .managed = root }, selected, &baseline));
}

test "worktree integrity managed synchronization cleans then advances detached head" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "source");
    const source = try tmp.dir.realPathFileAlloc(io, "source", allocator);
    defer allocator.free(source);
    try tmp.dir.writeFile(io, .{ .sub_path = "source/.gitignore", .data = "artifacts/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "source/tracked.txt", .data = "base\n" });
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.email", "synoptic@example.test" }, &.{ "git", "config", "user.name", "Synoptic Test" }, &.{ "git", "add", "." }, &.{ "git", "commit", "-qm", "base" } }) |argv| {
        const output = try runGit(allocator, io, source, argv);
        allocator.free(output);
    }
    const base_raw = try runGit(allocator, io, source, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "source/tracked.txt", .data = "head\n" });
    for ([_][]const []const u8{ &.{ "git", "add", "tracked.txt" }, &.{ "git", "commit", "-qm", "head" } }) |argv| {
        const output = try runGit(allocator, io, source, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, source, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    var output = try runGit(allocator, io, source, &.{ "git", "remote", "add", "origin", source });
    allocator.free(output);
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const managed = try std.fs.path.join(allocator, &.{ tmp_root, "managed-sync" });
    defer allocator.free(managed);
    output = try runGit(allocator, io, source, &.{ "git", "worktree", "add", "--detach", managed, base });
    allocator.free(output);
    var baseline = try worktree.Baseline.capture(allocator, io, managed);
    defer baseline.deinit();
    const managed_tracked = try std.fs.path.join(allocator, &.{ managed, "tracked.txt" });
    defer allocator.free(managed_tracked);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = managed_tracked, .data = "review mutation\n" });
    const artifact_dir = try std.fs.path.join(allocator, &.{ managed, "artifacts" });
    defer allocator.free(artifact_dir);
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    const artifact = try std.fs.path.join(allocator, &.{ artifact_dir, "output" });
    defer allocator.free(artifact);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = artifact, .data = "artifact" });
    try worktree.synchronize(allocator, io, .{ .managed = managed }, source, head, &baseline);
    try std.testing.expectEqualStrings(head, baseline.head_oid);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io, artifact, .{}));
}

test "worktree integrity reused checkout advances only by clean fast forward" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.email", "synoptic@example.test" }, &.{ "git", "config", "user.name", "Synoptic Test" }, &.{ "git", "add", "." }, &.{ "git", "commit", "-qm", "base" } }) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    const base_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    var output = try runGit(allocator, io, root, &.{ "git", "switch", "-qc", "upstream" });
    allocator.free(output);
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "head\n" });
    for ([_][]const []const u8{ &.{ "git", "add", "tracked.txt" }, &.{ "git", "commit", "-qm", "head" } }) |argv| {
        output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    output = try runGit(allocator, io, root, &.{ "git", "switch", "-qc", "feature", base });
    allocator.free(output);
    output = try runGit(allocator, io, root, &.{ "git", "remote", "add", "origin", root });
    allocator.free(output);
    var baseline = try worktree.Baseline.capture(allocator, io, root);
    defer baseline.deinit();
    try worktree.synchronize(allocator, io, .{ .reused_current = root }, root, head, &baseline);
    try std.testing.expectEqualStrings(head, baseline.head_oid);
    try std.testing.expectEqualStrings("feature", baseline.branch.?);
}

test "worktree integrity safe boundary interrupts active turns before mutation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const codex_path = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    defer allocator.free(codex_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-codex", .data = fakeCodexScript() });
    try std.Io.Dir.cwd().setFilePermissions(io, codex_path, std.Io.File.Permissions.fromMode(0o755), .{});
    var registry = try sessions.Registry.start(allocator, io, root, codex_path);
    defer registry.deinit();
    registry.primary_thread_id = try allocator.dupe(u8, "primary");
    registry.primary_start_turn_id = try allocator.dupe(u8, "primary-turn");
    registry.primary_turn_active = true;
    try registry.beginSynchronization(io, 200);
    registry.endSynchronization();
    const log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{codex_path});
    defer allocator.free(log_path);
    const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"method\":\"turn/interrupt\"") != null);
}

test "worktree integrity dirty launch selects managed custody" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    const repo = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/tracked.txt", .data = "head\n" });
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.email", "synoptic@example.test" }, &.{ "git", "config", "user.name", "Synoptic Test" }, &.{ "git", "switch", "-qc", "feature" }, &.{ "git", "add", "." }, &.{ "git", "commit", "-qm", "head" } }) |argv| {
        const output = try runGit(allocator, io, repo, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    const output = try runGit(allocator, io, repo, &.{ "git", "remote", "add", "origin", repo });
    allocator.free(output);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/tracked.txt", .data = "dirty\n" });
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const managed = try std.fs.path.join(allocator, &.{ tmp_root, "managed" });
    defer allocator.free(managed);
    const custody = try worktree.select(allocator, io, repo, "feature", head, managed, true);
    defer allocator.free(custody.path());
    try std.testing.expect(custody == .managed);
}

fn fakeLifecycleGhScriptAlloc(allocator: std.mem.Allocator, base: []const u8, head: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\set -eu
        \\if [ "${{1:-}}" = auth ]; then exit 0; fi
        \\input=$(mktemp)
        \\trap 'rm -f "$input"' EXIT
        \\cat > "$input"
        \\if grep -q 'SynopticPullRequest' "$input"; then
        \\  printf '%s\n' '{{"data":{{"repository":{{"id":"R_1","nameWithOwner":"o/r","pullRequest":{{"id":"PR_1","number":1,"url":"https://github.com/o/r/pull/1","title":"fixture","body":"body","state":"OPEN","isDraft":false,"baseRefName":"main","baseRefOid":"{s}","headRefName":"feature","headRefOid":"{s}","files":{{"nodes":[{{"path":"a.zig","additions":1,"deletions":1,"changeType":"MODIFIED","viewerViewedState":"UNVIEWED"}}],"pageInfo":{{"hasNextPage":false,"endCursor":null}}}}}}}}}}}}'; exit 0
        \\fi
        \\if grep -q 'SynopticReviewThreads' "$input"; then
        \\  printf '%s\n' '{{"data":{{"repository":{{"pullRequest":{{"reviewThreads":{{"nodes":[],"pageInfo":{{"hasNextPage":false,"endCursor":null}}}}}}}}}}}}'; exit 0
        \\fi
        \\printf '%s\n' '{{"data":{{}}}}'
        \\
    , .{ base, head });
}

fn runLifecycleCommand(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .environ_map = environment });
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("lifecycle command failed: {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ argv[1], result.stdout, result.stderr });
        allocator.free(result.stdout);
        return error.LifecycleCommandFailed;
    }
    return result.stdout;
}

fn bestEffortLifecycleStop(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, binary: []const u8) void {
    const result = std.process.run(allocator, io, .{ .argv = &.{ binary, "stop", "--json" }, .environ_map = environment }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

const ReceiptAddress = struct {
    port: u16,
    token: []u8,
    launch_id: []u8,
    allocator: std.mem.Allocator,
    fn deinit(self: *ReceiptAddress) void {
        self.allocator.free(self.token);
        self.allocator.free(self.launch_id);
    }
};

fn receiptAddress(allocator: std.mem.Allocator, raw: []const u8) !ReceiptAddress {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const url = object.get("url").?.string;
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidLaunchReceipt;
    const slash = std.mem.indexOfScalarPos(u8, url, prefix.len, '/') orelse return error.InvalidLaunchReceipt;
    const token_marker = "?token=";
    const marker = std.mem.indexOf(u8, url[slash..], token_marker) orelse return error.InvalidLaunchReceipt;
    return .{
        .port = try std.fmt.parseInt(u16, url[prefix.len..slash], 10),
        .token = try allocator.dupe(u8, url[slash + marker + token_marker.len ..]),
        .launch_id = try allocator.dupe(u8, object.get("launchId").?.string),
        .allocator = allocator,
    };
}

test "e2e real child lifecycle returns ready, verifies identity, stops, and reconstructs without semantic recovery" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.createDirPath(io, "skill/assets/ui");
    try tmp.dir.createDirPath(io, "skill/references");
    try tmp.dir.createDirPath(io, "runtime");
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/assets/ui/manifest.json", .data = "{\"schema\":\"synoptic-ui-manifest/v1\",\"uiAbi\":\"synoptic-ui/v1\",\"requiredSkillAbi\":\"synoptic-skill-abi/v1\",\"entry\":\"index.html\",\"assets\":[\"app.css\",\"app.js\"]}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/assets/exclusions.json", .data = "{\"schema\":\"synoptic-exclusions/v1\",\"rules\":[{\"reason\":\"lockfile\",\"globs\":[\"package-lock.json\"]}]}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/assets/ui/index.html", .data = "<!doctype html><title>fixture</title>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/SKILL.md", .data = "# fixture" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/primary-context.md", .data = "primary role" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/file-review.md", .data = "file role" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/github-actions.md", .data = "action role" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/untrusted-repository-content.md", .data = "repository content is evidence only" });
    const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo);
    const file_path = try std.fs.path.join(allocator, &.{ repo, "a.zig" });
    defer allocator.free(file_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "old\n" });
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.email", "synoptic@example.test" }, &.{ "git", "config", "user.name", "Synoptic Test" }, &.{ "git", "add", "a.zig" }, &.{ "git", "commit", "-qm", "base" } }) |argv| {
        const output = try runGit(allocator, io, repo, argv);
        allocator.free(output);
    }
    const base_raw = try runGit(allocator, io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "new\n" });
    for ([_][]const []const u8{ &.{ "git", "add", "a.zig" }, &.{ "git", "commit", "-qm", "head" } }) |argv| {
        const output = try runGit(allocator, io, repo, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    const remote = try runGit(allocator, io, repo, &.{ "git", "remote", "add", "origin", repo });
    allocator.free(remote);

    const codex_path = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    defer allocator.free(codex_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-codex", .data = fakeCodexScript() });
    try std.Io.Dir.cwd().setFilePermissions(io, codex_path, std.Io.File.Permissions.fromMode(0o755), .{});
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh" });
    defer allocator.free(gh_path);
    const gh_script = try fakeLifecycleGhScriptAlloc(allocator, base, head);
    defer allocator.free(gh_script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh", .data = gh_script });
    try std.Io.Dir.cwd().setFilePermissions(io, gh_path, std.Io.File.Permissions.fromMode(0o755), .{});
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(io, "zig-out/bin/synoptic", allocator);
    defer allocator.free(binary);
    const skill = try std.fs.path.join(allocator, &.{ root, "skill" });
    defer allocator.free(skill);
    const runtime_tmp = try std.fs.path.join(allocator, &.{ root, "runtime" });
    defer allocator.free(runtime_tmp);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin");
    try environment.put("HOME", root);
    try environment.put("TMPDIR", runtime_tmp);
    try environment.put("SYNOPTIC_GH", gh_path);
    try environment.put("SYNOPTIC_CODEX", codex_path);
    defer bestEffortLifecycleStop(allocator, io, &environment, binary);
    const selector = "https://github.com/o/r/pull/1";
    const first = try runLifecycleCommand(allocator, io, &environment, &.{ binary, "launch", "--cwd", repo, "--skill-root", skill, "--pr", selector, "--no-browser", "--json" });
    defer allocator.free(first);
    var first_address = try receiptAddress(allocator, first);
    defer first_address.deinit();
    const status_running = try runLifecycleCommand(allocator, io, &environment, &.{ binary, "status", "--json" });
    defer allocator.free(status_running);
    try std.testing.expect(std.mem.indexOf(u8, status_running, "\"status\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_running, first_address.launch_id) != null);
    const current_path = try std.fs.path.join(allocator, &.{ runtime_tmp, "synoptic", "current.json" });
    defer allocator.free(current_path);
    const operational = try std.Io.Dir.cwd().readFileAlloc(io, current_path, allocator, .limited(64 * 1024));
    defer allocator.free(operational);
    try std.testing.expect(std.mem.indexOf(u8, operational, "\"tabs\"") == null and std.mem.indexOf(u8, operational, "\"actions\"") == null);

    const first_bootstrap_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/bootstrap?token={s}", .{ first_address.port, first_address.token });
    defer allocator.free(first_bootstrap_url);
    var primary_ready = false;
    for (0..200) |_| {
        const bootstrap = try runLifecycleCommand(allocator, io, &environment, &.{ "/usr/bin/curl", "-fsS", first_bootstrap_url });
        if (std.mem.indexOf(u8, bootstrap, "\"primaryReady\":true") != null) primary_ready = true;
        allocator.free(bootstrap);
        if (primary_ready) break;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(primary_ready);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", first_address.port);
    var stream = try address.connect(io, .{ .mode = .stream });
    const request = try std.fmt.allocPrint(allocator, "GET /ws?token={s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nOrigin: http://127.0.0.1:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", .{ first_address.token, first_address.port, first_address.port });
    defer allocator.free(request);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var handshake: [1024]u8 = undefined;
    const incoming = try stream.socket.receive(io, &handshake);
    try std.testing.expect(std.mem.indexOf(u8, incoming.data, "101 Switching Protocols") != null);
    try sendMaskedText(io, &stream, "{\"type\":\"file.open\",\"payload\":{\"path\":\"a.zig\",\"diff\":\"BROWSER-SPOOF-DIFF\",\"threads\":\"BROWSER-SPOOF-THREADS\"}}");
    const opened = try readUntil(allocator, io, &stream, "\"type\":\"session.opened\"");
    defer allocator.free(opened);
    const review = try readUntil(allocator, io, &stream, "turn/completed");
    defer allocator.free(review);
    try sendMaskedText(io, &stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId\":\"ses-1\",\"text\":\"prepare the comment\",\"active\":false}}");
    const prepared = try readUntil(allocator, io, &stream, "\"type\":\"action.prepared\"");
    defer allocator.free(prepared);
    try sendMaskedText(io, &stream, "{\"type\":\"app.stop\",\"payload\":{}}");
    const quit = try readUntil(allocator, io, &stream, "\"type\":\"app.stopped\"");
    defer allocator.free(quit);
    stream.close(io);
    var stopped_seen = false;
    for (0..200) |_| {
        const stopped_status = try runLifecycleCommand(allocator, io, &environment, &.{ binary, "status", "--json" });
        defer allocator.free(stopped_status);
        if (std.mem.indexOf(u8, stopped_status, "\"status\":\"stopped\"") != null) {
            stopped_seen = true;
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(stopped_seen);

    const second = try runLifecycleCommand(allocator, io, &environment, &.{ binary, "launch", "--cwd", repo, "--skill-root", skill, "--pr", selector, "--no-browser", "--json" });
    defer allocator.free(second);
    var second_address = try receiptAddress(allocator, second);
    defer second_address.deinit();
    try std.testing.expect(!std.mem.eql(u8, first_address.launch_id, second_address.launch_id));
    const bootstrap_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api/bootstrap?token={s}", .{ second_address.port, second_address.token });
    defer allocator.free(bootstrap_url);
    const bootstrap = try runLifecycleCommand(allocator, io, &environment, &.{ "/usr/bin/curl", "-fsS", bootstrap_url });
    defer allocator.free(bootstrap);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap, "\"tabs\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap, "\"actions\":[]") != null);
    const stopped = try runLifecycleCommand(allocator, io, &environment, &.{ binary, "stop", "--json" });
    defer allocator.free(stopped);
    try std.testing.expect(std.mem.indexOf(u8, stopped, "\"status\":\"stopped\"") != null);

    const runtime_root_path = try std.fs.path.join(allocator, &.{ runtime_tmp, "synoptic" });
    defer allocator.free(runtime_root_path);
    const stale = try std.fmt.allocPrint(allocator, "{{\"runtimeSchema\":\"synoptic-runtime/v1\",\"launchId\":\"000000000000000000000000000000000000000000000000\",\"runtimeRoot\":{f},\"executable\":{f},\"url\":\"http://127.0.0.1:1/?token=stale\",\"pid\":{d}}}", .{ std.json.fmt(runtime_root_path, .{}), std.json.fmt(binary, .{}), std.c.getpid() });
    defer allocator.free(stale);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = current_path, .data = stale });
    const stale_status = try runLifecycleCommand(allocator, io, &environment, &.{ binary, "status", "--json" });
    defer allocator.free(stale_status);
    try std.testing.expect(std.mem.indexOf(u8, stale_status, "\"status\":\"stopped\"") != null);

    try environment.put("SYNOPTIC_GH", "/definitely/missing/synoptic-gh");
    const failed = try std.process.run(allocator, io, .{ .argv = &.{ binary, "launch", "--cwd", repo, "--skill-root", skill, "--pr", selector, "--no-browser", "--json" }, .environ_map = &environment });
    defer allocator.free(failed.stdout);
    defer allocator.free(failed.stderr);
    try std.testing.expect(failed.term == .exited and failed.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, failed.stderr, "\"schema\":\"synoptic-launch-error/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed.stderr, "\"reason\":\"ExecutableNotFound\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed.stderr, "Install codex and gh") != null);
}

fn injectedRefresh(runtime: *http.Runtime) !void {
    try worktree.requireManagedRefresh(runtime.custody);
    var next = try domain.PrGeneration.initFull(runtime.app.allocator, runtime.app.generation.base_oid, runtime.app.generation.head_oid);
    errdefer next.deinit();
    try next.addFile(.{ .path = "a.zig", .viewed = .unviewed, .revision_key = "r2" });
    try next.addFile(.{ .path = "b.zig", .viewed = .unviewed, .revision_key = "b1" });
    try runtime.registry.markPathChangedAndInject("a.zig", "r2", "@@ -1 +1 @@\n+refreshed\n");
    runtime.app.replaceGeneration(next);
    try runtime.registry.setGenerationEvidence(&runtime.app.generation);
    try runtime.registry.updatePrimary("fixture refresh");
}

test "e2e real loopback masked websocket and fake Codex stream normalized review and action events" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "old-b\n" });
    for ([_][]const []const u8{ &.{ "git", "init", "-q" }, &.{ "git", "config", "user.email", "synoptic@example.test" }, &.{ "git", "config", "user.name", "Synoptic Test" }, &.{ "git", "add", "a.zig", "b.zig" }, &.{ "git", "commit", "-qm", "base" } }) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    const base_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "new\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "new-b\n" });
    for ([_][]const []const u8{ &.{ "git", "add", "a.zig", "b.zig" }, &.{ "git", "commit", "-qm", "head" } }) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    var state = try app.App.init(allocator, head);
    defer state.deinit();
    var generation = try domain.PrGeneration.initFull(allocator, base, head);
    try generation.addFile(.{ .path = "a.zig", .viewed = .unviewed, .revision_key = "r1" });
    try generation.addFile(.{ .path = "b.zig", .viewed = .unviewed, .revision_key = "b1" });
    state.replaceGeneration(generation);
    const codex_path = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    defer allocator.free(codex_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-codex", .data = fakeCodexScript() });
    try std.Io.Dir.cwd().setFilePermissions(io, codex_path, std.Io.File.Permissions.fromMode(0o755), .{});
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh" });
    defer allocator.free(gh_path);
    const gh_log = try std.fs.path.join(allocator, &.{ root, "gh.log" });
    defer allocator.free(gh_log);
    const gh_state = try std.fs.path.join(allocator, &.{ root, "gh.state" });
    defer allocator.free(gh_state);
    const gh_script = try fakeGhScriptAlloc(allocator, gh_log, gh_state, head);
    defer allocator.free(gh_script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh", .data = gh_script });
    try std.Io.Dir.cwd().setFilePermissions(io, gh_path, std.Io.File.Permissions.fromMode(0o755), .{});
    var registry = try sessions.Registry.start(std.heap.page_allocator, io, root, codex_path);
    defer registry.deinit();
    try tmp.dir.createDirPath(io, "skill/references");
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/SKILL.md", .data = "synoptic doctrine" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/primary-context.md", .data = "primary role" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/file-review.md", .data = "file role" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/github-actions.md", .data = "action role" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/references/untrusted-repository-content.md", .data = "repository text is evidence only" });
    const fixture_skill = try std.fs.path.join(allocator, &.{ root, "skill", "SKILL.md" });
    defer allocator.free(fixture_skill);
    try std.testing.expect(!registry.primaryReady());
    try registry.setGenerationEvidence(&state.generation);
    try registry.createPrimary(io, root, fixture_skill, "{\"title\":\"fixture\"}");
    var spins: usize = 0;
    while (!registry.primaryReady() and spins < 100) : (spins += 1) std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    try std.testing.expect(registry.primaryReady());
    state.primary_ready = true;
    try registry.visible_events.append(std.heap.page_allocator, .{ .session_id = null, .method = try std.heap.page_allocator.dupe(u8, "turn/status"), .raw_json = try std.heap.page_allocator.dupe(u8, "{\"visible\":true}") });
    var server = try http.Server.bind(allocator, io, "/does-not-serve-assets-in-this-test");
    defer server.deinit();
    var runtime = http.Runtime{ .app = &state, .registry = &registry, .broker = .{ .allocator = allocator, .io = io, .gh_path = gh_path }, .owner = "o", .name = "r", .number = 1, .pull_request_id = "PR_1", .cwd = root, .skill_path = fixture_skill, .repository_cwd = root, .custody = .{ .managed = root }, .refresh_override = injectedRefresh };
    var fixture = NetworkFixture{ .server = &server, .runtime = &runtime };
    const thread = try std.Thread.spawn(.{}, NetworkFixture.serve, .{&fixture});
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", server.port());
    var stream = try address.connect(io, .{ .mode = .stream });
    var first_joined = false;
    defer {
        if (!first_joined) {
            stream.close(io);
            thread.join();
        }
    }
    var token_buf: [64]u8 = undefined;
    const token = server.tokenHex(&token_buf);
    const request = try std.fmt.allocPrint(allocator, "GET /ws?token={s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nOrigin: http://127.0.0.1:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", .{ token, server.port(), server.port() });
    defer allocator.free(request);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var handshake: [1024]u8 = undefined;
    const incoming = try stream.socket.receive(io, &handshake);
    try std.testing.expect(std.mem.indexOf(u8, incoming.data, "101 Switching Protocols") != null);
    const autonomous = try readUntil(allocator, io, &stream, "\\\"visible\\\":true");
    defer allocator.free(autonomous);
    try std.testing.expect(std.mem.indexOf(u8, autonomous, "session.item.delta") != null);
    try std.testing.expect(std.mem.indexOf(u8, autonomous, "\\\"visible\\\":true") != null);
    try sendMaskedText(io, &stream, "{\"type\":\"snapshot.get\",\"payload\":{}}");
    const snapshot = try readUntil(allocator, io, &stream, "\"type\":\"snapshot\"");
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "a.zig") != null);
    try sendMaskedText(io, &stream, "{\"type\":\"file.open\",\"payload\":{\"path\":\"a.zig\",\"diff\":\"@@ -1 +1 @@\\n+x\",\"threads\":\"[]\"}}");
    const opened = try readUntil(allocator, io, &stream, "\"type\":\"session.opened\"");
    defer allocator.free(opened);
    try std.testing.expect(std.mem.indexOf(u8, opened, "session.opened") != null);
    try std.testing.expect(std.mem.indexOf(u8, opened, "ses-1") != null);
    const review = try readUntil(allocator, io, &stream, "review visible");
    defer allocator.free(review);
    try std.testing.expect(std.mem.indexOf(u8, review, "review visible") != null);
    const review_complete = try readUntil(allocator, io, &stream, "turn/completed");
    defer allocator.free(review_complete);
    const codex_log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{codex_path});
    defer allocator.free(codex_log_path);
    const codex_log = try std.Io.Dir.cwd().readFileAlloc(io, codex_log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(codex_log);
    try std.testing.expect(std.mem.indexOf(u8, codex_log, "BROWSER-SPOOF-DIFF") == null);
    try std.testing.expect(std.mem.indexOf(u8, codex_log, "BROWSER-SPOOF-THREADS") == null);
    inline for (.{ "primary role", "file role", "repository text is evidence only", "\"name\":\"synoptic\"", "search_unresolved_threads", "prepare_github_action", "complete_file_review", "close_session" }) |needle| try std.testing.expect(std.mem.indexOf(u8, codex_log, needle) != null);
    try sendMaskedText(io, &stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId\":\"ses-1\",\"text\":\"search cross-file\",\"active\":false}}");
    const search_started = try readUntil(allocator, io, &stream, "turn-started");
    defer allocator.free(search_started);
    const search_completed = try readUntil(allocator, io, &stream, "turn/completed");
    defer allocator.free(search_completed);
    var search_seen = false;
    for (0..100) |_| {
        const fresh_log = try std.Io.Dir.cwd().readFileAlloc(io, codex_log_path, allocator, .limited(1024 * 1024));
        defer allocator.free(fresh_log);
        if (std.mem.indexOf(u8, fresh_log, "\"id\":\"tool-search\"") != null and std.mem.indexOf(u8, fresh_log, "\"success\":true") != null) {
            search_seen = true;
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(search_seen);
    try sendMaskedText(io, &stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId\":\"ses-1\",\"text\":\"run approved command\",\"active\":false}}");
    const approval_turn = try readUntil(allocator, io, &stream, "turn-started");
    defer allocator.free(approval_turn);
    const approval = try readUntil(allocator, io, &stream, "\"type\":\"approval.requested\"");
    defer allocator.free(approval);
    try std.testing.expect(std.mem.indexOf(u8, approval, "apr-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, approval, "make test") != null);
    try std.testing.expect(std.mem.indexOf(u8, approval, "\"decisions\":[\"accept\",\"decline\"]") != null);
    try sendMaskedText(io, &stream, "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId\":\"ses-1\",\"approvalId\":\"apr-999\",\"decision\":\"accept\"}}");
    const unknown_approval = try readUntil(allocator, io, &stream, "UnknownApproval");
    defer allocator.free(unknown_approval);
    try sendMaskedText(io, &stream, "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId\":\"ses-2\",\"approvalId\":\"apr-1\",\"decision\":\"accept\"}}");
    const cross_session = try readUntil(allocator, io, &stream, "CrossSessionApproval");
    defer allocator.free(cross_session);
    try sendMaskedText(io, &stream, "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId\":\"ses-1\",\"approvalId\":\"apr-1\",\"decision\":\"invented\"}}");
    const invented = try readUntil(allocator, io, &stream, "ApprovalDecisionNotOffered");
    defer allocator.free(invented);
    try sendMaskedText(io, &stream, "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId\":\"ses-1\",\"approvalId\":\"apr-1\",\"decision\":\"accept\"}}");
    const resolved = try readUntil(allocator, io, &stream, "\"type\":\"approval.resolved\"");
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "\"decision\":\"accept\"") != null);
    const approval_complete = try readUntil(allocator, io, &stream, "turn/completed");
    defer allocator.free(approval_complete);
    try sendMaskedText(io, &stream, "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId\":\"ses-1\",\"approvalId\":\"apr-1\",\"decision\":\"accept\"}}");
    const duplicate = try readUntil(allocator, io, &stream, "ApprovalAlreadyResolved");
    defer allocator.free(duplicate);
    try sendMaskedText(io, &stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId\":\"ses-1\",\"text\":\"attempt file change\",\"active\":false}}");
    const file_change_turn = try readUntil(allocator, io, &stream, "turn-started");
    defer allocator.free(file_change_turn);
    const file_change_complete = try readUntil(allocator, io, &stream, "turn/completed");
    defer allocator.free(file_change_complete);
    const approval_log = try std.Io.Dir.cwd().readFileAlloc(io, codex_log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(approval_log);
    try std.testing.expect(std.mem.indexOf(u8, approval_log, "\"id\":\"approval-command\",\"result\":{\"decision\":\"accept\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, approval_log, "\"id\":\"approval-file-change\",\"result\":{\"decision\":\"decline\"}") != null);
    try sendMaskedText(io, &stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId\":\"ses-1\",\"text\":\"prepare the comment\",\"active\":false}}");
    const status = try readUntil(allocator, io, &stream, "turn-started");
    defer allocator.free(status);
    const card = try readUntil(allocator, io, &stream, "\"type\":\"action.prepared\"");
    defer allocator.free(card);
    try std.testing.expect(std.mem.indexOf(u8, card, "Could this fail?") != null);
    try std.testing.expectEqual(@as(usize, 1), state.action_store.cards.items.len);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io, gh_log, .{ .allow_directory = false }));
    try sendMaskedText(io, &stream, "{\"type\":\"action.confirm\",\"payload\":{\"cardId\":\"act-1\"}}");
    const confirmed = try readUntil(allocator, io, &stream, "\"status\":\"succeeded\"");
    defer allocator.free(confirmed);
    const first_log = try std.Io.Dir.cwd().readFileAlloc(io, gh_log, allocator, .limited(1024 * 1024));
    defer allocator.free(first_log);
    try std.testing.expect(std.mem.indexOf(u8, first_log, "ARGV:api graphql --hostname github.com --input -") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_log, "SynopticAddInlineComment") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_log, "\"path\":\"a.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_log, "\"side\":\"RIGHT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_log, "Could this fail?") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_log, head) != null);

    try sendMaskedText(io, &stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId\":\"ses-1\",\"text\":\"complete this file\",\"active\":false}}");
    const completion_turn = try readUntil(allocator, io, &stream, "turn-started");
    defer allocator.free(completion_turn);
    const completed = try readUntil(allocator, io, &stream, "\"type\":\"file.completed\"");
    defer allocator.free(completed);
    try std.testing.expect(!state.generation.queued("a.zig"));
    try std.testing.expectEqual(domain.SessionStatus.completed, state.tabs.items[0].status);
    try sendMaskedText(io, &stream, "{\"type\":\"snapshot.get\",\"payload\":{}}");
    const completed_snapshot = try readUntil(allocator, io, &stream, "\"type\":\"snapshot\"");
    defer allocator.free(completed_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, completed_snapshot, "\"queue\":[{\"path\":\"b.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, completed_snapshot, "\"status\":\"completed\"") != null);

    try sendMaskedText(io, &stream, "{\"type\":\"file.open\",\"payload\":{\"path\":\"b.zig\",\"diff\":\"@@ -1 +1 @@\\n+new-b\",\"threads\":\"[]\"}}");
    const opened_b = try readUntil(allocator, io, &stream, "ses-2");
    defer allocator.free(opened_b);
    const review_b = try readUntil(allocator, io, &stream, "review visible");
    defer allocator.free(review_b);
    const review_b_complete = try readUntil(allocator, io, &stream, "turn/completed");
    defer allocator.free(review_b_complete);
    try sendMaskedText(io, &stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId\":\"ses-2\",\"text\":\"close this session\",\"active\":false}}");
    const close_turn = try readUntil(allocator, io, &stream, "turn-started");
    defer allocator.free(close_turn);
    const closed = try readUntil(allocator, io, &stream, "\"type\":\"session.closed\"");
    defer allocator.free(closed);
    try std.testing.expect(state.generation.queued("b.zig"));
    try std.testing.expectEqual(domain.SessionStatus.closed, state.tabs.items[1].status);
    const final_log = try std.Io.Dir.cwd().readFileAlloc(io, gh_log, allocator, .limited(1024 * 1024));
    defer allocator.free(final_log);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, final_log, "SynopticMarkFileViewed"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, final_log, "SynopticFileState"));

    try sendMaskedText(io, &stream, "{\"type\":\"pr.refresh\",\"payload\":{}}");
    const refreshed = try readUntil(allocator, io, &stream, "\"type\":\"pr.refreshed\"");
    defer allocator.free(refreshed);
    const primary_approval = try readUntil(allocator, io, &stream, "\"ownerKind\":\"primary\"");
    defer allocator.free(primary_approval);
    try std.testing.expect(std.mem.indexOf(u8, primary_approval, "\"sessionId\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, primary_approval, "git log --oneline") != null);
    try sendMaskedText(io, &stream, "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId\":\"ses-1\",\"approvalId\":\"apr-2\",\"decision\":\"accept\"}}");
    const primary_spoof = try readUntil(allocator, io, &stream, "CrossSessionApproval");
    defer allocator.free(primary_spoof);
    try sendMaskedText(io, &stream, "{\"type\":\"approval.resolve\",\"payload\":{\"approvalId\":\"apr-2\",\"decision\":\"accept\"}}");
    const primary_resolved = try readUntil(allocator, io, &stream, "\"type\":\"approval.resolved\"");
    defer allocator.free(primary_resolved);
    try std.testing.expect(std.mem.indexOf(u8, primary_resolved, "\"ownerKind\":\"primary\"") != null);
    try std.testing.expect(state.generation.queued("a.zig"));
    try std.testing.expectEqual(domain.SessionStatus.stale_origin, state.tabs.items[0].status);
    try std.testing.expectEqual(sessions.SessionStatus.stale_origin, registry.sessions.items[0].status);
    try sendMaskedText(io, &stream, "{\"type\":\"file.open\",\"payload\":{\"path\":\"a.zig\",\"diff\":\"@@ -1 +1 @@\\n+refreshed\",\"threads\":\"[]\"}}");
    const reopened_a = try readUntil(allocator, io, &stream, "ses-3");
    defer allocator.free(reopened_a);
    const refreshed_review = try readUntil(allocator, io, &stream, "review visible");
    defer allocator.free(refreshed_review);
    try std.testing.expectEqual(domain.SessionStatus.current, state.tabs.items[state.tabs.items.len - 1].status);
    try sendMaskedText(io, &stream, "{\"type\":\"round.finish\",\"payload\":{}}");
    const round_finished = try readUntil(allocator, io, &stream, "\"type\":\"round.finished\"");
    defer allocator.free(round_finished);
    try std.testing.expect(std.mem.indexOf(u8, round_finished, "\"round\":2") != null);

    stream.close(io);
    thread.join();
    first_joined = true;
    var disconnect_declined = false;
    for (0..100) |_| {
        const disconnect_log = try std.Io.Dir.cwd().readFileAlloc(io, codex_log_path, allocator, .limited(1024 * 1024));
        defer allocator.free(disconnect_log);
        if (std.mem.indexOf(u8, disconnect_log, "\"id\":\"approval-primary\",\"result\":{\"decision\":\"decline\"}") != null) {
            disconnect_declined = true;
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(disconnect_declined);
    var reconnect_fixture = NetworkFixture{ .server = &server, .runtime = &runtime };
    const reconnect_thread = try std.Thread.spawn(.{}, NetworkFixture.serve, .{&reconnect_fixture});
    var reconnect = try address.connect(io, .{ .mode = .stream });
    defer {
        reconnect.close(io);
        reconnect_thread.join();
    }
    var reconnect_writer = reconnect.writer(io, &.{});
    try reconnect_writer.interface.writeAll(request);
    try reconnect_writer.interface.flush();
    const reconnect_handshake = try reconnect.socket.receive(io, &handshake);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_handshake.data, "101 Switching Protocols") != null);
    try sendMaskedText(io, &reconnect, "{\"type\":\"snapshot.get\",\"payload\":{}}");
    const reconnect_snapshot = try readUntil(allocator, io, &reconnect, "\"type\":\"snapshot\"");
    defer allocator.free(reconnect_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_snapshot, "\"round\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_snapshot, "\"status\":\"stale_origin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_snapshot, "act-1") != null);
    try sendMaskedText(io, &reconnect, "{\"type\":\"app.stop\",\"payload\":{}}");
    const stopped = try readUntil(allocator, io, &reconnect, "\"type\":\"app.stopped\"");
    defer allocator.free(stopped);
    try std.testing.expect(runtime.stop_requested);
    try std.testing.expect(!fixture.failed.load(.acquire));
    try std.testing.expect(!reconnect_fixture.failed.load(.acquire));
}
test {
    _ = config;
    _ = domain;
    _ = github;
    _ = graphql;
    _ = main;
    _ = pr;
    _ = sessions;
    _ = ui;
    _ = worktree;
}
