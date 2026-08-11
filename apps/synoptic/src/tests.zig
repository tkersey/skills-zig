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
    try state.generation.addFile(
        .{ .path = "src/a.zig", .viewed = .unviewed, .revision_key = "r1" },
    );
    try std.testing.expectError(error.PrimaryNotReady, state.openFile("src/a.zig"));
    state.primary_ready = true;
    const event = try state.openFile("src/a.zig");
    defer std.testing.allocator.free(event);
    try std.testing.expect(std.mem.indexOf(
        u8,
        event,
        "session.opened",
    ) != null);
    state.initial_review_active = false;
    const input = tools.PreparedActionInput{
        .slot = @constCast("finding-1"),
        .kind = .add_inline_comment,
        .effect_summary = @constCast("Add a comment"),
        .payload_json = @constCast("{}"),
        .path = @constCast("src/a.zig"),
        .line = 12,
        .body = @constCast("Could this fail?"),
    };
    _ = try state.prepareModelAction("s", "t", input, "o/r", 1, "PR_1", "src/a.zig");
    try std.testing.expectEqual(tools.ActionStatus.pending, state.pending.?.status);
    state.close();
    try std.testing.expect(state.generation.queued("src/a.zig"));
}

test "comment mutation cards own the server-observed body snapshot" {
    var state = try app.App.init(std.testing.allocator, "h");
    defer state.deinit();
    const comments = [_]domain.ReviewComment{.{
        .id = "C_1",
        .body = "observed body",
        .created_at = "2026-01-01T00:00:00Z",
        .url = "https://example/C_1",
        .author = "viewer",
        .viewer_did_author = true,
        .review_id = "R_1",
        .review_state = "COMMENTED",
    }};
    try state.generation.addThread(.{
        .id = "T_1",
        .path = "a.zig",
        .comments = &comments,
    });
    const card = try state.prepareModelAction("s", "t", .{
        .slot = @constCast("update"),
        .kind = .update_comment,
        .effect_summary = @constCast("Update C_1"),
        .payload_json = @constCast("{}"),
        .comment_id = @constCast("C_1"),
        .body = @constCast("replacement body"),
    }, "o/r", 1, "PR_1", "a.zig");
    try std.testing.expectEqualStrings(
        "observed body",
        card.target.comment_body_snapshot.?,
    );
    try std.testing.expectEqualStrings("replacement body", card.body.?);
}

test "complete GitHub snapshot replacement refreshes all PR metadata" {
    var state = try app.App.init(std.testing.allocator, "old-head");
    defer state.deinit();
    try state.setPullRequest(.{
        .repository = "o/r",
        .number = 1,
        .title = "Old title",
        .body = "Old body",
        .url = "https://example/old",
        .base_ref_name = "old-base",
        .base_ref_oid = "old-base-oid",
        .head_ref_name = "old-head",
        .head_ref_oid = "old-head",
        .state = "OPEN",
        .is_draft = false,
    });
    var next = try domain.PrGeneration.initFull(
        std.testing.allocator,
        "new-base-oid",
        "new-head-oid",
    );
    var next_owned = true;
    errdefer if (next_owned) next.deinit();
    try next.addFile(.{ .path = "new.zig", .viewed = .unviewed, .revision_key = "r2" });
    try state.replaceGithubSnapshot(next, .{
        .repository = "o/r",
        .number = 1,
        .title = "New title",
        .body = "New body",
        .url = "https://example/new",
        .base_ref_name = "main",
        .base_ref_oid = "new-base-oid",
        .head_ref_name = "feature",
        .head_ref_oid = "new-head-oid",
        .state = "CLOSED",
        .is_draft = true,
    });
    next_owned = false;
    const header = state.pull_request.?;
    try std.testing.expectEqualStrings("New title", header.title);
    try std.testing.expectEqualStrings("New body", header.body);
    try std.testing.expectEqualStrings("https://example/new", header.url);
    try std.testing.expectEqualStrings("main", header.base_ref_name);
    try std.testing.expectEqualStrings("new-base-oid", header.base_ref_oid);
    try std.testing.expectEqualStrings("feature", header.head_ref_name);
    try std.testing.expectEqualStrings("new-head-oid", header.head_ref_oid);
    try std.testing.expectEqualStrings("CLOSED", header.state);
    try std.testing.expect(header.is_draft);
    try std.testing.expect(state.generation.queued("new.zig"));
}

test "session context unresolved assigned-file evidence preserves complete comments" {
    const raw =
        "{\"data\":{\"repository\":{\"pullRequest\":{\"reviewTh" ++
        "reads\":{\"nodes\":[{\"id\":\"T1\",\"path\":\"a.zig\"," ++
        "\"line\":7,\"startLine\":6,\"diffSide\":\"RIGHT\",\"st" ++
        "artDiffSide\":\"RIGHT\",\"subjectType\":\"LINE\",\"isR" ++
        "esolved\":false,\"isOutdated\":false,\"viewerCanReply" ++
        "\":true,\"viewerCanResolve\":true,\"viewerCanUnresolve" ++
        "\":false,\"comments\":{\"nodes\":[{\"id\":\"C1\",\"bod" ++
        "y\":\"risk evidence\",\"createdAt\":\"2026-01-01T00:00" ++
        ":00Z\",\"url\":\"https://example/C1\",\"author\":{\"lo" ++
        "gin\":\"reviewer\"},\"viewerDidAuthor\":true,\"pullReq" ++
        "uestReview\":{\"id\":\"R1\",\"state\":\"COMMENTED\"}}]" ++
        "}}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":" ++
        "null}}}}}}";
    var generation = try domain.PrGeneration.initFull(std.testing.allocator, "b", "h");
    defer generation.deinit();
    try github.loadThreads(std.testing.allocator, raw, &generation);
    const evidence = try generation.unresolvedThreadsJsonAlloc(
        std.testing.allocator,
        "a.zig",
        null,
        &.{},
        false,
    );
    defer std.testing.allocator.free(evidence);
    inline for (
        .{ "T1", "C1", "risk evidence", "reviewer", "viewer_can_reply", "review_state" },
    ) |needle| try std.testing.expect(std.mem.indexOf(
        u8,
        evidence,
        needle,
    ) != null);
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
    try std.testing.expectError(
        error.InitialReviewActionForbidden,
        tools.authorizeTool(.initial_review, true),
    );
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
    try std.testing.expect(std.mem.indexOf(
        u8,
        one,
        "\"seq\":1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        two,
        "\"seq\":2",
    ) != null);
}
test "model prepared payload is decoded into owned immutable action input" {
    const raw =
        "{\"params\":{\"threadId\":\"file-1\",\"arguments\":{\"" ++
        "slot\":\"finding-1\",\"kind\":\"add_inline_comment\"," ++
        "\"effectSummary\":\"Add an inline comment on a.zig lin" ++
        "e 7\",\"payload\":{\"path\":\"a.zig\",\"line\":7,\"sid" ++
        "e\":\"RIGHT\",\"body\":\"Could this fail?\"}}}}";
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
    const input = tools.PreparedActionInput{
        .slot = @constCast("reply"),
        .kind = .reply_thread,
        .effect_summary = @constCast("Reply to thread T_1"),
        .payload_json = @constCast("{\"threadId\":\"T_1\",\"body\":\"reply\"}"),
        .thread_id = @constCast("T_1"),
        .body = @constCast("reply"),
    };
    const card = try store.prepare(
        "ses-9",
        "turn-4",
        input,
        .{
            .repository = "o/r",
            .pull_request = 2,
            .pull_request_id = "PR_2",
            .head_oid = "head",
            .session_path = "a.zig",
        },
    );
    const encoded = try tools.cardJsonAlloc(std.testing.allocator, card.*);
    defer std.testing.allocator.free(encoded);
    inline for (
        .{
            "synoptic-github-action/v1",
            "Reply to thread T_1",
            "T_1",
            "ses-9",
            "turn-4",
            "\"payload\":{\"threadId\":\"T_1\"",
        },
    ) |needle| try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        needle,
    ) != null);
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
    const first_action = tools.PreparedActionInput{
        .slot = @constCast("finding-1"),
        .kind = .add_inline_comment,
        .effect_summary = @constCast("First"),
        .payload_json = @constCast("{}"),
        .path = @constCast("a"),
        .line = 1,
        .body = @constCast("first"),
    };
    const replacement_action = tools.PreparedActionInput{
        .slot = @constCast("finding-1"),
        .kind = .add_inline_comment,
        .effect_summary = @constCast("Replacement"),
        .payload_json = @constCast("{}"),
        .path = @constCast("a"),
        .line = 2,
        .body = @constCast("replacement"),
    };
    _ = try state.prepareModelAction("s", "t1", first_action, "o/r", 1, "PR_1", "a");
    _ = try state.prepareModelAction("s", "t2", replacement_action, "o/r", 1, "PR_1", "a");
    try std.testing.expectEqual(
        tools.ActionStatus.superseded,
        state.action_store.cards.items[0].status,
    );
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
    try std.testing.expectEqual(
        domain.SessionStatus.current,
        state.tabs.items[state.tabs.items.len - 1].status,
    );
    try std.testing.expectEqual(@as(u64, 2), state.finishRound());
}

test "ui domain bootstrap owns PR queue tab diff and reconnect state" {
    var state = try app.App.init(std.testing.allocator, "h1");
    defer state.deinit();
    try state.setPullRequest(
        .{
            .repository = "o/r",
            .number = 7,
            .title = "Review me",
            .body = "",
            .url = "https://github.com/o/r/pull/7",
            .base_ref_name = "main",
            .base_ref_oid = "b1",
            .head_ref_name = "feature",
            .head_ref_oid = "h1",
            .state = "OPEN",
            .is_draft = true,
        },
    );
    try state.generation.addFile(
        .{
            .path = "a.zig",
            .additions = 4,
            .deletions = 2,
            .change_type = "MODIFIED",
            .viewed = .unviewed,
            .revision_key = "r1",
            .exclusion_reason = "generated",
            .exclusion_sync_error = "readback-failed",
        },
    );
    state.primary_ready = true;
    const provisional = try state.openFile("a.zig");
    defer std.testing.allocator.free(provisional);
    try state.recordOpenedSession("a.zig", "r1", "ses-1", "@@ -1 +1 @@\n-old\n+new\n", false, true);

    const initial = try state.bootstrapAlloc();
    defer std.testing.allocator.free(initial);
    try expectInitialUiPayload(initial);

    const opened = try state.sessionOpenedPayloadAlloc("a.zig", "r1");
    defer std.testing.allocator.free(opened);
    try expectOpenedUiPayload(opened);

    try state.updateTabDiff("a.zig", "@@ -1 +1 @@\n-new\n+newer\n");
    var refreshed = try domain.PrGeneration.initFull(std.testing.allocator, "b2", "h2");
    try refreshed.addFile(.{ .path = "a.zig", .viewed = .unviewed, .revision_key = "r2" });
    try state.updatePullRequestGeneration("b2", "h2");
    state.replaceGeneration(refreshed);
    const reconnect = try state.bootstrapAlloc();
    defer std.testing.allocator.free(reconnect);
    try expectReconnectUiPayload(reconnect);

    try state.updateTabDiff("a.zig", null);
    const removed = try domain.PrGeneration.initFull(std.testing.allocator, "b3", "h3");
    try state.updatePullRequestGeneration("b3", "h3");
    state.replaceGeneration(removed);
    const unavailable = try state.bootstrapAlloc();
    defer std.testing.allocator.free(unavailable);
    try std.testing.expect(std.mem.indexOf(
        u8,
        unavailable,
        "\"diff\":{\"state\":\"unavailable\",\"text\":null}",
    ) != null);
}

test "tab closure uses session identity when revisions share a path" {
    var state = try app.App.init(std.testing.allocator, "h1");
    defer state.deinit();
    try state.generation.addFile(.{
        .path = "a.zig",
        .viewed = .unviewed,
        .revision_key = "r1",
    });
    state.primary_ready = true;
    const first = try state.openFile("a.zig");
    defer std.testing.allocator.free(first);
    try state.recordOpenedSession("a.zig", "r1", "session-r1", "diff-1", false, true);
    var next = try domain.PrGeneration.initFull(std.testing.allocator, "base", "h2");
    try next.addFile(.{ .path = "a.zig", .viewed = .unviewed, .revision_key = "r2" });
    state.replaceGeneration(next);
    const second = try state.openFile("a.zig");
    defer std.testing.allocator.free(second);
    try state.recordOpenedSession("a.zig", "r2", "session-r2", "diff-2", false, true);

    try state.closeTabById("session-r1");
    try std.testing.expectEqual(domain.SessionStatus.closed, state.tabs.items[0].status);
    try std.testing.expectEqual(domain.SessionStatus.current, state.tabs.items[1].status);
}

fn expectInitialUiPayload(initial: []const u8) !void {
    inline for (
        .{
            "\"repository\":\"o/r\"",
            "\"number\":7",
            "\"title\":\"Review me\"",
            "\"isDraft\":true",
            "\"changeType\":\"MODIFIED\"",
            "\"viewedState\":\"UNVIEWED\"",
            "\"revisionKey\":\"r1\"",
            "\"activeSessionId\":\"ses-1\"",
            "\"currentRevisionSession\":true",
            "\"exclusionReason\":\"generated\"",
            "\"exclusionSyncError\":\"readback-failed\"",
            "\"state\":\"text\"",
            "+new",
        },
    ) |needle|
        try std.testing.expect(std.mem.indexOf(
            u8,
            initial,
            needle,
        ) != null);
}

fn expectOpenedUiPayload(opened: []const u8) !void {
    inline for (
        .{
            "\"path\":\"a.zig\"",
            "\"revisionKey\":\"r1\"",
            "\"sessionId\":\"ses-1\"",
            "\"reused\":false",
            "\"initialReview\":true",
            "+new",
        },
    ) |needle| try std.testing.expect(std.mem.indexOf(
        u8,
        opened,
        needle,
    ) != null);
}

fn expectReconnectUiPayload(reconnect: []const u8) !void {
    inline for (
        .{
            "\"baseRefOid\":\"b2\"",
            "\"headRefOid\":\"h2\"",
            "\"status\":\"stale_origin\"",
            "+newer",
        },
    ) |needle| try std.testing.expect(std.mem.indexOf(
        u8,
        reconnect,
        needle,
    ) != null);
}

const NetworkFixture = struct {
    server: *http.Server,
    runtime: *http.Runtime,
    failed: std.atomic.Value(bool) = .init(false),

    fn serve(self: *NetworkFixture) void {
        self.server.serveOne(self.runtime) catch self.failed.store(true, .release);
    }
};

fn sendMaskedText(io: std.Io, stream: *std.Io.net.Stream, text: []const u8) !void {
    return sendMaskedFrame(io, stream, 0x1, text);
}

fn sendMaskedFrame(
    io: std.Io,
    stream: *std.Io.net.Stream,
    opcode: u8,
    payload_bytes: []const u8,
) !void {
    if (payload_bytes.len > 125) return error.TestFrameTooLarge;
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    var header = [2]u8{ 0x80 | opcode, 0x80 | @as(u8, @intCast(payload_bytes.len)) };
    var payload: [125]u8 = undefined;
    for (payload_bytes, 0..) |byte, i| payload[i] = byte ^ mask[i % mask.len];
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(&mask);
    try writer.interface.writeAll(payload[0..payload_bytes.len]);
    try writer.interface.flush();
}

fn receiveExact(io: std.Io, stream: *std.Io.net.Stream, destination: []u8) !void {
    var used: usize = 0;
    const deadline = std.Io.Clock.Timestamp.fromNow(
        io,
        .{ .raw = .fromMilliseconds(10_000), .clock = .awake },
    );
    while (used < destination.len) {
        const incoming = try stream.socket.receiveTimeout(
            io,
            destination[used..],
            .{ .deadline = deadline },
        );
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

fn expectServerCloseEcho(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    expected: []const u8,
) !void {
    var header: [2]u8 = undefined;
    try receiveExact(io, stream, &header);
    if (header[0] != 0x88 or header[1] & 0x80 != 0 or
        @as(usize, header[1]) != expected.len)
    {
        return error.InvalidServerFrame;
    }
    const payload = try allocator.alloc(u8, expected.len);
    defer allocator.free(payload);
    try receiveExact(io, stream, payload);
    try std.testing.expectEqualSlices(u8, expected, payload);
}

fn readUntil(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    needle: []const u8,
) ![]u8 {
    for (0..16) |_| {
        const frame = try readServerText(allocator, io, stream);
        if (std.mem.indexOf(
            u8,
            frame,
            needle,
        ) != null) return frame;
        allocator.free(frame);
    }
    return error.ExpectedWebSocketEventMissing;
}

const fake_codex_script =
    \\#!/bin/sh
    \\set -eu
    \\if [ "${1:-}" = "--version" ]; then printf '%s\n' 'codex-test 1.0.0'; exit 0; fi
    \\if [ "${1:-}" = "app-server" ] && [ "${2:-}" = "generate-json-schema" ]; then
    \\  out=''
    \\  while [ "$#" -gt 0 ]; do if [ "$1" = "--out" ] || [ "$1" = "-o" ]; then shift; out="$1"; fi; shift; done
    \\  mkdir -p "$out/v2"
    \\  printf '%s' '{"methods":["initialize","initialized","thread/start","thread/fork","turn/start","turn/steer","turn/interrupt","thread/inject_items","item/tool/call","item/commandExecution/requestApproval","item/fileChange/requestApproval","item/permissions/requestApproval"]}' > "$out/codex_app_server_protocol.schemas.json"
    \\  cp "$out/codex_app_server_protocol.schemas.json" "$out/codex_app_server_protocol.v2.schemas.json"
    \\  printf '%s' '{"lastTurnId":{},"ephemeral":{},"approvalPolicy":{},"sandbox":{}}' > "$out/v2/ThreadForkParams.json"
    \\  printf '%s' '{"dynamicTools":{},"approvalPolicy":{},"sandbox":{}}' > "$out/v2/ThreadStartParams.json"
    \\  printf '%s' '{"SkillUserInput":{"required":["name","path","type"]}}' > "$out/v2/TurnStartParams.json"
    \\  for f in ThreadStartedNotification TurnStartedNotification TurnCompletedNotification ItemStartedNotification AgentMessageDeltaNotification; do printf '%s' '{}' > "$out/v2/$f.json"; done
    \\  printf '%s' '{"properties":{"threadId":{},"availableDecisions":{}},"required":["threadId"]}' > "$out/CommandExecutionRequestApprovalParams.json"
    \\  printf '%s' '{"properties":{"decision":{}},"required":["decision"],"values":["accept","acceptForSession","decline","cancel"]}' > "$out/CommandExecutionRequestApprovalResponse.json"
    \\  printf '%s' '{"properties":{"decision":{}},"required":["decision"],"values":["decline"]}' > "$out/FileChangeRequestApprovalResponse.json"
    \\  printf '%s' '{"properties":{"threadId":{},"permissions":{}},"required":["threadId","permissions"]}' > "$out/PermissionsRequestApprovalParams.json"
    \\  printf '%s' '{"properties":{"permissions":{},"scope":{}},"required":["permissions"],"values":["turn","session"]}' > "$out/PermissionsRequestApprovalResponse.json"
    \\  exit 0
    \\fi
    \\case " $* " in
    \\  *' --listen'*)
    \\    i=0
    \\    while [ "$i" -lt 16 ]; do
    \\      echo 'managed fake unsupported' >&2
    \\      i=$((i + 1))
    \\    done
    \\    exit 2
    \\    ;;
    \\esac
    \\forks=0
    \\primary_turns=0
    \\while IFS= read -r line; do
    \\  printf '%s\n' "$line" >> "$0.log"
    \\  case "$line" in
    \\    *'"method":"initialize"'*) printf '%s\n' '{"id":-1,"result":{}}'; continue ;;
    \\    *'"method":"initialized"'*) continue ;;
    \\    *'"id":"tool-'*) continue ;;
    \\    *'"id":"approval-command"'*) printf '%s' "$line" | grep -q '"decision":"accept"'; printf '%s\n' '{"method":"turn/completed","params":{"threadId":"file-1","turn":{"id":"file-turn","status":"completed"}}}'; continue ;;
    \\    *'"id":"approval-file-change"'*) printf '%s' "$line" | grep -q '"decision":"decline"'; printf '%s\n' '{"method":"turn/completed","params":{"threadId":"file-1","turn":{"id":"file-turn","status":"completed"}}}'; continue ;;
    \\    *'"id":"approval-primary"'*) printf '%s' "$line" | grep -Eq '"decision":"(accept|decline)"'; printf '%s\n' '{"method":"turn/completed","params":{"threadId":"primary","turn":{"id":"primary-turn","status":"completed"}}}'; continue ;;
    \\  esac
    \\  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  case "$line" in
    \\    *'"method":"thread/start"'*) printf '{"id":%s,"result":{"thread":{"id":"primary"}}}\n' "$id" ;;
    \\    *'"method":"thread/fork"'*) forks=$((forks + 1)); printf '{"id":%s,"result":{"thread":{"id":"file-%s"}}}\n' "$id" "$forks" ;;
    \\    *'"method":"thread/inject_items"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
    \\    *'"method":"turn/interrupt"'*)
    \\      if printf '%s' "$line" | grep -q 'fail-interrupt'; then
    \\        printf '{"id":%s,"error":{"code":-32000,"message":"interrupt failed"}}\n' "$id"
    \\        continue
    \\      fi
    \\      printf '{"id":%s,"result":{}}\n' "$id" ;;
    \\    *'"method":"turn/start"'*)
    \\      if printf '%s' "$line" | grep -q '"threadId":"primary"'; then
    \\        primary_turns=$((primary_turns + 1))
    \\        printf '{"id":%s,"result":{"turn":{"id":"primary-turn"}}}\n' "$id"
    \\        if [ "$primary_turns" -gt 1 ]; then
    \\          printf '%s\n' '{"id":"approval-primary","method":"item/commandExecution/requestApproval","params":{"threadId":"primary","turnId":"primary-turn","itemId":"primary-cmd","startedAtMs":1,"command":"git log --oneline","availableDecisions":["accept","decline"]}}'
    \\          continue
    \\        fi
    \\        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"primary","turn":{"id":"primary-turn","status":"completed"}}}'
    \\      else
    \\        thread_id=$(printf '%s\n' "$line" | sed -n 's/.*"threadId":"\([^"]*\)".*/\1/p')
    \\        if printf '%s' "$line" | grep -q 'prepare the comment'; then
    \\          printf '{"id":"tool-prepare","method":"item/tool/call","params":{"threadId":"%s","tool":"synoptic.prepare_github_action","arguments":{"slot":"finding-1","kind":"add_inline_comment","effectSummary":"Add an inline comment on a.zig line 1","payload":{"path":"a.zig","line":1,"side":"RIGHT","body":"Could this fail?"}}}}\n' "$thread_id"
    \\        fi
    \\        printf '{"id":%s,"result":{"turn":{"id":"file-turn"}}}\n' "$id"
    \\        if printf '%s' "$line" | grep -q 'complete this file'; then
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
    \\        printf '{"method":"turn/completed","params":{"threadId":"%s","turn":{"id":"file-turn","status":"completed"}}}\n' "$thread_id"
    \\      fi ;;
    \\    *) printf '{"id":%s,"result":{}}\n' "$id" ;;
    \\  esac
    \\done
;

fn fakeCodexScript() []const u8 {
    return fake_codex_script;
}

fn fakeGhScriptAlloc(
    allocator: std.mem.Allocator,
    log_path: []const u8,
    state_path: []const u8,
    base: []const u8,
    head: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
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
        \\if grep -q 'SynopticPullRequest' "$input"; then viewed=UNVIEWED; [ -f "$state" ] && viewed=VIEWED; printf '{{"data":{{"repository":{{"pullRequest":{{"id":"PR_1","number":1,"url":"https://github.com/o/r/pull/1","title":"Fixture PR","body":"","state":"OPEN","isDraft":false,"baseRefName":"main","baseRefOid":"{s}","headRefName":"feature","headRefOid":"{s}","files":{{"nodes":[{{"path":"a.zig","additions":1,"deletions":1,"changeType":"MODIFIED","viewerViewedState":"%s"}},{{"path":"b.zig","additions":1,"deletions":1,"changeType":"MODIFIED","viewerViewedState":"UNVIEWED"}}],"pageInfo":{{"hasNextPage":false,"endCursor":null}}}}}}}}}}}}\n' "$viewed"; exit 0; fi
        \\if grep -q 'SynopticReviewThreads' "$input"; then printf '%s\n' '{{"data":{{"repository":{{"pullRequest":{{"baseRefOid":"{s}","headRefOid":"{s}","reviewThreads":{{"nodes":[],"pageInfo":{{"hasNextPage":false,"endCursor":null}}}}}}}}}}}}'; exit 0; fi
        \\if grep -q 'SynopticFileState' "$input"; then viewed=UNVIEWED; [ -f "$state" ] && viewed=VIEWED; printf '{{"data":{{"repository":{{"pullRequest":{{"headRefOid":"{s}","files":{{"nodes":[{{"path":"a.zig","viewerViewedState":"%s"}},{{"path":"b.zig","viewerViewedState":"UNVIEWED"}}],"pageInfo":{{"hasNextPage":false,"endCursor":null}}}}}}}}}}}}\n' "$viewed"; exit 0; fi
        \\if grep -q 'SynopticAnchor' "$input"; then printf '%s\n' '{{"data":{{"repository":{{"pullRequest":{{"headRefOid":"{s}","files":{{"nodes":[{{"path":"a.zig"}},{{"path":"b.zig"}}],"pageInfo":{{"hasNextPage":false,"endCursor":null}}}}}}}}}}}}'; exit 0; fi
        \\printf '%s\n' '{{"data":{{}}}}'
        \\
    ,
        .{ log_path, state_path, base, head, base, head, head, head },
    );
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
        \\if grep -q 'SynopticReconcile' "$input"; then now=$(date -u +%Y-%m-%dT%H:%M:%SZ); printf '{"data":{"repository":{"pullRequest":{"headRefOid":"h","reviewThreads":{"nodes":[{"id":"T_new","path":"a.zig","line":1,"startLine":null,"diffSide":"RIGHT","startDiffSide":null,"isResolved":false,"comments":{"nodes":[{"id":"C_new","body":"body","createdAt":"%s","viewerDidAuthor":true}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}\n' "$now"; exit 0; fi
        \\if grep -q 'SynopticAddInlineComment' "$input"; then exit 1; fi
        \\printf '%s\n' '{"data":{}}'
        \\
    ;
    return std.mem.replaceOwned(u8, allocator, template, "__LOG__", log_path);
}

const action_inputs = [_]tools.PreparedActionInput{
    .{
        .slot = @constCast("reply"),
        .kind = .reply_thread,
        .effect_summary = @constCast("Reply to thread T_1"),
        .payload_json = @constCast("{}"),
        .thread_id = @constCast("T_1"),
        .body = @constCast("reply"),
    },
    .{
        .slot = @constCast("resolve"),
        .kind = .resolve_thread,
        .effect_summary = @constCast("Resolve thread T_1"),
        .payload_json = @constCast("{}"),
        .thread_id = @constCast("T_1"),
    },
    .{
        .slot = @constCast("unresolve"),
        .kind = .unresolve_thread,
        .effect_summary = @constCast("Unresolve thread T_1"),
        .payload_json = @constCast("{}"),
        .thread_id = @constCast("T_1"),
    },
    .{
        .slot = @constCast("update"),
        .kind = .update_comment,
        .effect_summary = @constCast("Update comment C_1"),
        .payload_json = @constCast("{}"),
        .comment_id = @constCast("C_1"),
        .body = @constCast("updated"),
    },
    .{
        .slot = @constCast("delete"),
        .kind = .delete_comment,
        .effect_summary = @constCast("Delete comment C_1"),
        .payload_json = @constCast("{}"),
        .comment_id = @constCast("C_1"),
    },
    .{
        .slot = @constCast("unmark"),
        .kind = .unmark_viewed,
        .effect_summary = @constCast("Return a.zig to the unviewed queue"),
        .payload_json = @constCast("{}"),
        .path = @constCast("a.zig"),
    },
    .{
        .slot = @constCast("transparent"),
        .kind = .graphql,
        .effect_summary = @constCast("Add a PR note"),
        .payload_json = @constCast("{}"),
        .operation_name = @constCast("AddReviewNote"),
        .document = @constCast(
            "mutation AddReviewNote($input:AddCommentInput!){" ++
                "addComment(input:$input){clientMutationId}}",
        ),
        .variables = @constCast("{\"input\":{\"subjectId\":\"PR_1\",\"body\":\"note\"}}"),
    },
};

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
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "fake-gh-actions", .data = script },
    );
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        gh_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );

    const authoritative = tools.AuthoritativeTarget{
        .repository = "o/r",
        .pull_request = 1,
        .pull_request_id = "PR_1",
        .head_oid = "h",
        .session_path = "a.zig",
        .comment_body_snapshot = "old",
    };
    var store = tools.ActionStore{ .allocator = allocator };
    defer store.deinit();
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_path };
    for (action_inputs, 0..) |input, i| {
        const source = try std.fmt.allocPrint(
            allocator,
            "turn-{d}",
            .{i},
        );
        defer allocator.free(source);
        const card = try store.prepare("ses-1", source, input, authoritative);
        try broker.validateAction("o", "r", 1, "PR_1", card.*);
        try broker.executeAction(card.*);
        if (card.kind == .unmark_viewed) try std.testing.expect(try broker.viewedStateAfterMutation(
            "o",
            "r",
            1,
            "h",
            "a.zig",
            false,
        ));
    }
    var tampered = store.cards.items[store.cards.items.len - 1];
    var tampered_graphql = tampered.graphql.?;
    tampered_graphql.document =
        "mutation AddReviewNote($input:AddCommentInput!){hidden" ++
        ":addComment(input:$input){clientMutationId}}";
    tampered.graphql = tampered_graphql;
    try std.testing.expectError(error.GraphqlAliasForbidden, broker.executeAction(tampered));
    try verifyActionLog(allocator, io, log_path);
    try verifyUnmarkAction(allocator, broker, authoritative);
}

test "comment action validation rejects a changed body found by nested pagination" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh-comment-change" });
    defer allocator.free(gh_path);
    const script =
        \\#!/bin/sh
        \\set -eu
        \\input=$(mktemp)
        \\trap 'rm -f "$input"' EXIT
        \\cat > "$input"
        \\if grep -q 'SynopticAnchor' "$input"; then
        \\  printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"h","files":{"nodes":[{"path":"a.zig"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'; exit 0
        \\fi
        \\if grep -q 'SynopticActionAuthority' "$input"; then
        \\  printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"h","reviewThreads":{"nodes":[{"id":"T_1","path":"a.zig","viewerCanReply":true,"viewerCanResolve":true,"viewerCanUnresolve":true,"comments":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'; exit 0
        \\fi
        \\if grep -q 'SynopticThreadComments' "$input"; then
        \\  printf '%s\n' '{"data":{"node":{"comments":{"nodes":[{"id":"C_1","body":"changed elsewhere","viewerDidAuthor":true}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'; exit 0
        \\fi
        \\printf '%s\n' '{"data":{}}'
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh-comment-change", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        gh_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    var store = tools.ActionStore{ .allocator = allocator };
    defer store.deinit();
    const card = try store.prepare("ses", "turn", .{
        .slot = @constCast("delete"),
        .kind = .delete_comment,
        .effect_summary = @constCast("Delete C_1"),
        .payload_json = @constCast("{}"),
        .comment_id = @constCast("C_1"),
    }, .{
        .repository = "o/r",
        .pull_request = 1,
        .pull_request_id = "PR_1",
        .head_oid = "h",
        .session_path = "a.zig",
        .comment_body_snapshot = "observed body",
    });
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_path };
    try std.testing.expectError(
        error.GitHubActionTargetChanged,
        broker.validateAction("o", "r", 1, "PR_1", card.*),
    );
}

fn verifyActionLog(allocator: std.mem.Allocator, io: std.Io, log_path: []const u8) !void {
    const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    try std.testing.expectEqual(
        std.mem.count(u8, log, "ARGV:api graphql --hostname github.com --input -"),
        std.mem.count(u8, log, "ARGV:"),
    );
    inline for (
        .{
            "SynopticReply",
            "SynopticResolveThread",
            "SynopticUnresolveThread",
            "SynopticUpdateComment",
            "SynopticDeleteComment",
            "SynopticUnmarkFileViewed",
            "mutation AddReviewNote",
        },
    ) |needle| try std.testing.expect(std.mem.indexOf(
        u8,
        log,
        needle,
    ) != null);
    inline for (
        .{
            "\"pullRequestReviewThreadId\":\"T_1\"",
            "\"pullRequestReviewCommentId\":\"C_1\"",
            "\"subjectId\":\"PR_1\"",
            "\"path\":\"a.zig\"",
        },
    ) |needle| try std.testing.expect(std.mem.indexOf(
        u8,
        log,
        needle,
    ) != null);
}

fn verifyUnmarkAction(
    allocator: std.mem.Allocator,
    broker: github.Broker,
    authoritative: tools.AuthoritativeTarget,
) !void {
    var state = try app.App.init(allocator, "h");
    defer state.deinit();
    try state.generation.addFile(.{ .path = "a.zig", .viewed = .viewed, .revision_key = "r" });
    const unmark = action_inputs[5];
    const unmark_card = try state.action_store.prepare(
        "ses-unmark",
        "turn-unmark",
        unmark,
        authoritative,
    );
    try broker.validateAction("o", "r", 1, "PR_1", unmark_card.*);
    try std.testing.expectEqual(
        tools.ActionStatus.succeeded,
        try state.confirmAction(broker, "o", "r", 1, unmark_card.id),
    );
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
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "fake-gh-ambiguous", .data = script },
    );
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        gh_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_path };
    var state = try app.App.init(allocator, "h");
    defer state.deinit();
    try state.generation.addFile(.{ .path = "a.zig", .viewed = .unviewed, .revision_key = "r" });
    try verifyAmbiguousActions(allocator, io, broker, &state, log_path);
}

test "malformed successful mutation response remains transport ambiguous" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh-malformed" });
    defer allocator.free(gh_path);
    const script =
        \\#!/bin/sh
        \\cat >/dev/null
        \\printf '{'
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh-malformed", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        gh_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_path };
    try std.testing.expectError(
        error.GitHubTransportAmbiguous,
        broker.call(graphql.add_inline_comment_mutation, "{}"),
    );
    try std.testing.expectError(
        error.InvalidGraphqlResponse,
        broker.call(graphql.anchor_query, "{}"),
    );
}

test "duplicate inline comment reconciliation remains unknown" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh-duplicate" });
    defer allocator.free(gh_path);
    const script =
        \\#!/bin/sh
        \\set -eu
        \\input=$(mktemp)
        \\trap 'rm -f "$input"' EXIT
        \\cat > "$input"
        \\now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        \\json='{"data":{"repository":{"pullRequest":{"headRefOid":"h",'
        \\json=$json'"reviewThreads":{"nodes":[{"id":"T","path":"a.zig",'
        \\json=$json'"line":1,"startLine":null,"diffSide":"RIGHT",'
        \\json=$json'"startDiffSide":null,"comments":{"nodes":['
        \\json=$json'{"id":"C1","body":"body","createdAt":"%s",'
        \\json=$json'"viewerDidAuthor":true},{"id":"C2","body":"body",'
        \\json=$json'"createdAt":"%s","viewerDidAuthor":true}],'
        \\json=$json'"pageInfo":{"hasNextPage":false,"endCursor":null}}}],'
        \\json=$json'"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
        \\printf "$json\\n" "$now" "$now"
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh-duplicate", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        gh_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    var store = tools.ActionStore{ .allocator = allocator };
    defer store.deinit();
    const card = try store.prepare("ses", "turn", .{
        .slot = @constCast("finding"),
        .kind = .add_inline_comment,
        .effect_summary = @constCast("comment"),
        .payload_json = @constCast("{}"),
        .path = @constCast("a.zig"),
        .line = 1,
        .body = @constCast("body"),
    }, .{
        .repository = "o/r",
        .pull_request = 1,
        .pull_request_id = "PR_1",
        .head_oid = "h",
        .session_path = "a.zig",
    });
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh_path };
    try std.testing.expect(!try broker.reconcileAction("o", "r", 1, card.*, 0));
}

test "ambiguous complete-file mutation succeeds only through viewed readback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh-complete" });
    defer allocator.free(gh_path);
    const state_path = try std.fs.path.join(allocator, &.{ root, "viewed" });
    defer allocator.free(state_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nset -eu\ninput=$(mktemp)\ntrap 'rm -f \"$input\"' EXIT\n" ++
            "cat > \"$input\"\nif grep -q SynopticMarkFileViewed \"$input\"; then " ++
            "printf viewed > {s}; exit 1; fi\n" ++
            "if grep -q SynopticAnchor \"$input\"; then printf '%s\\n' '" ++
            "{{\"data\":{{\"repository\":{{\"pullRequest\":{{\"headRefOid\":\"head\"," ++
            "\"files\":{{\"nodes\":[{{\"path\":\"a.zig\"}}],\"pageInfo\":" ++
            "{{\"hasNextPage\":false,\"endCursor\":null}}}}}}}}}}}}'; exit 0; fi\n" ++
            "if grep -q SynopticFileState \"$input\"; then test -f {s}; printf '%s\\n' '" ++
            "{{\"data\":{{\"repository\":{{\"pullRequest\":{{\"headRefOid\":\"head\"," ++
            "\"files\":{{\"nodes\":[{{\"path\":\"a.zig\",\"viewerViewedState\":" ++
            "\"VIEWED\"}}],\"pageInfo\":{{\"hasNextPage\":false,\"endCursor\":null}}" ++
            "}}}}}}}}}}'; exit 0; fi\nprintf '%s\\n' '{{\"data\":{{}}}}'\n",
        .{ state_path, state_path },
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh-complete", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        gh_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    var state = try app.App.init(allocator, "head");
    defer state.deinit();
    try state.generation.addFile(.{
        .path = "a.zig",
        .viewed = .unviewed,
        .revision_key = "r1",
    });
    state.primary_ready = true;
    const opened = try state.openFile("a.zig");
    allocator.free(opened);
    try state.recordOpenedSession("a.zig", "r1", "session-1", "", false, true);
    try state.completeRevision(
        .{ .allocator = allocator, .io = io, .gh_path = gh_path },
        "o",
        "r",
        1,
        "PR_1",
        "a.zig",
        "r1",
    );
    try std.testing.expect(!state.generation.queued("a.zig"));
    const completed = try state.bootstrapAlloc();
    defer allocator.free(completed);
    try std.testing.expect(std.mem.indexOf(u8, completed, "\"completedTabOpen\":true") != null);
    try state.closeTabById("session-1");
    const closed = try state.bootstrapAlloc();
    defer allocator.free(closed);
    try std.testing.expect(std.mem.indexOf(u8, closed, "\"completedTabOpen\":false") != null);
}

fn verifyAmbiguousActions(
    allocator: std.mem.Allocator,
    io: std.Io,
    broker: github.Broker,
    state: *app.App,
    log_path: []const u8,
) !void {
    const input = tools.PreparedActionInput{
        .slot = @constCast("finding"),
        .kind = .add_inline_comment,
        .effect_summary = @constCast("Add the inline comment"),
        .payload_json = @constCast("{}"),
        .path = @constCast("a.zig"),
        .line = 1,
        .side = @constCast("RIGHT"),
        .body = @constCast("body"),
    };
    const card = try state.action_store.prepare(
        "ses-1",
        "turn-2",
        input,
        .{
            .repository = "o/r",
            .pull_request = 1,
            .pull_request_id = "PR_1",
            .head_oid = "h",
            .session_path = "a.zig",
        },
    );
    try broker.validateAction("o", "r", 1, "PR_1", card.*);
    try std.testing.expectEqual(
        tools.ActionStatus.succeeded,
        try state.confirmAction(broker, "o", "r", 1, card.id),
    );
    const unmatched_input = tools.PreparedActionInput{
        .slot = @constCast("finding-2"),
        .kind = .add_inline_comment,
        .effect_summary = @constCast("Add the other inline comment"),
        .payload_json = @constCast("{}"),
        .path = @constCast("a.zig"),
        .line = 1,
        .side = @constCast("RIGHT"),
        .body = @constCast("different body"),
    };
    const unmatched = try state.action_store.prepare(
        "ses-1",
        "turn-3",
        unmatched_input,
        .{
            .repository = "o/r",
            .pull_request = 1,
            .pull_request_id = "PR_1",
            .head_oid = "h",
            .session_path = "a.zig",
        },
    );
    try broker.validateAction("o", "r", 1, "PR_1", unmatched.*);
    try std.testing.expectEqual(
        tools.ActionStatus.outcome_unknown,
        try state.confirmAction(broker, "o", "r", 1, unmatched.id),
    );
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
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "fake-gh-update-reconcile", .data = script },
    );
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        gh_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );

    var store = tools.ActionStore{ .allocator = allocator };
    defer store.deinit();
    const card = try store.prepare("ses-update", "turn-update", .{
        .slot = @constCast("update"),
        .kind = .update_comment,
        .effect_summary = @constCast("Update comment C_new"),
        .payload_json = @constCast("{}"),
        .comment_id = @constCast("C_new"),
        .body = @constCast("body"),
    }, .{
        .repository = "o/r",
        .pull_request = 1,
        .pull_request_id = "PR_1",
        .head_oid = "h",
        .session_path = "a.zig",
    });
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
    }, .{
        .repository = "o/r",
        .pull_request = 1,
        .pull_request_id = "PR_1",
        .head_oid = "h",
        .session_path = "a.zig",
    });
    try std.testing.expect(!try broker.reconcileAction("o", "r", 1, wrong_body.*, 0));
}

fn runGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
) ![]u8 {
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
    const exclusions_json = "{\"schema\":\"synoptic-exclusions/v1\",\"rules\":[{\"r" ++
        "eason\":\"lockfile\",\"globs\":[\"package-lock.json\"]" ++
        "},{\"reason\":\"vendored\",\"globs\":[\"vendor/**\"]}," ++
        "{\"reason\":\"snapshot\",\"globs\":[\"**/__snapshots__" ++
        "/**\"]}]}";
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "skill/assets/exclusions.json", .data = exclusions_json },
    );
    const xdg_config = "[file_review]\nstart_mode = \"idle\"\n[browser]\nopen " ++
        "= false\n[worktree]\nprefer_current_pr_checkout = fals" ++
        "e\n[exclusions]\nenabled = true\nadditional_globs = [" ++
        "\"docs/generated/**\"]\nremoved_default_globs = [\"pac" ++
        "kage-lock.json\"]\n";
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "xdg/synoptic/config.toml", .data = xdg_config },
    );
    const home_config = "[file_review]\nstart_mode = \"immediate\"\n[browser]\n" ++
        "open = true\n";
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "home/.config/synoptic/config.toml", .data = home_config },
    );
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
    try std.testing.expectEqualStrings(
        "vendored",
        settings.classify("vendor/lib/a.js", "@@ text").?,
    );
    try std.testing.expectEqualStrings(
        "configured-glob",
        settings.classify("docs/generated/api.md", "@@ text").?,
    );
    try std.testing.expectEqualStrings(
        "binary",
        settings.classify("assets/photo.dat", "GIT binary patch").?,
    );
    try std.testing.expect(settings.classify("src/very-large.zig", "@@ ordinary source") == null);
    settings.exclusions_enabled = false;
    try std.testing.expect(settings.classify("vendor/lib/a.js", "GIT binary patch") == null);
}

test "config can force managed worktree without weakening cleanliness" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "repo/a.zig", .data = "clean\n" },
    );
    const repo = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo);
    for (
        [_][]const []const u8{
            &.{ "git", "init", "-q" },
            &.{ "git", "config", "user.email", "synoptic@example.test" },
            &.{ "git", "config", "user.name", "Synoptic Test" },
            &.{ "git", "switch", "-qc", "feature" },
            &.{ "git", "add", "." },
            &.{ "git", "commit", "-qm", "head" },
        },
    ) |argv| {
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

const CommitPair = struct {
    allocator: std.mem.Allocator,
    base: []u8,
    head: []u8,
    fn deinit(self: CommitPair) void {
        self.allocator.free(self.base);
        self.allocator.free(self.head);
    }
};

fn prepareExclusionRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    root: []const u8,
) !CommitPair {
    try tmp.dir.writeFile(io, .{ .sub_path = "package-lock.json", .data = "base\n" });
    try tmp.dir.createDirPath(io, "vendor");
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/fail.js", .data = "base\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/ambiguous.js", .data = "base\n" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/large.zig", .data = "base\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try runGit(allocator, io, root, argv));
    const base_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const changed_paths = .{
        "package-lock.json",
        "vendor/fail.js",
        "vendor/ambiguous.js",
        "src/large.zig",
    };
    inline for (changed_paths) |path| {
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "head\n" });
    }
    allocator.free(try runGit(allocator, io, root, &.{ "git", "add", "." }));
    allocator.free(try runGit(allocator, io, root, &.{ "git", "commit", "-qm", "head" }));
    const head_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    return .{
        .allocator = allocator,
        .base = try allocator.dupe(u8, std.mem.trim(u8, base_raw, "\r\n")),
        .head = try allocator.dupe(u8, std.mem.trim(u8, head_raw, "\r\n")),
    };
}

const ExclusionGh = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    log_path: []u8,
    state_path: []u8,
    fn deinit(self: ExclusionGh) void {
        self.allocator.free(self.path);
        self.allocator.free(self.log_path);
        self.allocator.free(self.state_path);
    }
};

fn installExclusionGh(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    root: []const u8,
    head: []const u8,
) !ExclusionGh {
    const state_path = try std.fs.path.join(allocator, &.{ root, "gh.state" });
    errdefer allocator.free(state_path);
    const log_path = try std.fs.path.join(allocator, &.{ root, "gh.log" });
    errdefer allocator.free(log_path);
    const gh_path = try std.fs.path.join(allocator, &.{ root, "fake-gh" });
    errdefer allocator.free(gh_path);
    const format = "#!/bin/sh\nset -eu\ninput=$(cat)\nprintf '%s\\n%s\\n' " ++
        "\"$*\" \"$input\" >> {s}\nif printf '%s' \"$input\" | grep -q" ++
        " SynopticMarkFileViewed; then\n  if printf '%s' \"$input\" | grep" ++
        " -q 'vendor/fail.js'; then exit 1; fi\n  if printf '%s' \"$input" ++
        "\" | grep -q 'vendor/ambiguous.js'; then printf '%s\\n' ambi" ++
        "guous >> {s}; exit 1; fi\n  printf '%s\\n' package >> {s}\n  " ++
        "printf '%s\\n' '{{\"data\":{{\"markFileAsViewed\":{{\"pullReq" ++
        "uest\":{{\"id\":\"PR_1\"}}}}}}}}'\n  exit 0\nfi\npackage_view" ++
        "ed=UNVIEWED\nambiguous_viewed=UNVIEWED\n[ -f {s} ] && grep" ++
        " -q package {s} && package_viewed=VIEWED\n[ -f {s} ] && grep" ++
        " -q ambiguous {s} && ambiguous_viewed=VIEWED\nif printf '%s' \"$input" ++
        "\" | grep -q '\"after\":\"page-2\"'; then\n  printf '{{\"data\"" ++
        ":{{\"repository\":{{\"pullRequest\":{{\"headRefOid\":\"{s}\",\"fi" ++
        "les\":{{\"nodes\":[{{\"path\":\"vendor/ambiguous.js\",\"viewer" ++
        "ViewedState\":\"%s\"}},{{\"path\":\"src/large.zig\",\"viewerView" ++
        "edState\":\"UNVIEWED\"}}],\"pageInfo\":{{\"hasNextPage\":false," ++
        "\"endCursor\":null}}}}}}}}}}}}\\n' \"$ambiguous_viewed\"\nelse\n  " ++
        "printf '{{\"data\":{{\"repository\":{{\"pullRequest\":{{\"headRefOid\"" ++
        ":\"{s}\",\"files\":{{\"nodes\":[{{\"path\":\"package-lock.json\"" ++
        ",\"viewerViewedState\":\"%s\"}},{{\"path\":\"vendor/fail.js\",\"v" ++
        "iewerViewedState\":\"UNVIEWED\"}}],\"pageInfo\":{{\"hasNextPage\":" ++
        "true,\"endCursor\":\"page-2\"}}}}}}}}}}}}\\n' \"$package_viewed\"\nfi\n";
    const script = try std.fmt.allocPrint(
        allocator,
        format,
        .{
            log_path,
            state_path,
            state_path,
            state_path,
            state_path,
            state_path,
            state_path,
            head,
            head,
        },
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        gh_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    return .{
        .allocator = allocator,
        .path = gh_path,
        .log_path = log_path,
        .state_path = state_path,
    };
}

test "exclusions config mutation readback and failure retention across generations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skill/assets");
    const exclusions_json = "{\"schema\":\"synoptic-exclusions/v1\",\"rules\":[{\"r" ++
        "eason\":\"lockfile\",\"globs\":[\"package-lock.json\"]" ++
        "},{\"reason\":\"vendored\",\"globs\":[\"vendor/**\"]}]" ++
        "}";
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "skill/assets/exclusions.json", .data = exclusions_json },
    );
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const commits = try prepareExclusionRepo(allocator, io, &tmp, root);
    defer commits.deinit();
    const base = commits.base;
    const head = commits.head;
    const gh = try installExclusionGh(allocator, io, &tmp, root, head);
    defer gh.deinit();
    const skill = try std.fs.path.join(allocator, &.{ root, "skill" });
    defer allocator.free(skill);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var settings = try config.Settings.load(allocator, io, &environment, skill);
    defer settings.deinit();
    var state = try app.App.init(allocator, head);
    defer state.deinit();
    var generation = try domain.PrGeneration.initFull(allocator, base, head);
    try generation.addFile(
        .{ .path = "package-lock.json", .viewed = .unviewed, .revision_key = "r1" },
    );
    try generation.addFile(
        .{ .path = "vendor/fail.js", .viewed = .unviewed, .revision_key = "r2" },
    );
    try generation.addFile(
        .{ .path = "vendor/ambiguous.js", .viewed = .unviewed, .revision_key = "r3" },
    );
    try generation.addFile(.{ .path = "src/large.zig", .viewed = .unviewed, .revision_key = "r4" });
    state.replaceGeneration(generation);
    const broker = github.Broker{ .allocator = allocator, .io = io, .gh_path = gh.path };
    try verifyExclusionState(
        allocator,
        io,
        &state,
        &settings,
        broker,
        gh.log_path,
        root,
        base,
        head,
    );
}

fn verifyExclusionState(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *app.App,
    settings: *config.Settings,
    broker: github.Broker,
    log_path: []const u8,
    root: []const u8,
    base: []const u8,
    head: []const u8,
) !void {
    var outcomes = try state.applyAutomaticExclusions(settings, broker, "o", "r", 1, "PR_1", root);
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
    const log = try std.Io.Dir.cwd().readFileAlloc(
        io,
        log_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(
        u8,
        log,
        "api graphql --hostname github.com --input -",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        log,
        "synoptic-auto-exclusion",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, log, "mutation SynopticMarkFileViewed"),
    );
    try std.testing.expectEqual(
        @as(usize, 4),
        std.mem.count(u8, log, "query SynopticFileState"),
    );

    var refreshed = try domain.PrGeneration.initFull(allocator, base, head);
    try refreshed.addFile(
        .{ .path = "package-lock.json", .viewed = .unviewed, .revision_key = "r4" },
    );
    state.replaceGeneration(refreshed);
    var refreshed_outcomes = try state.applyAutomaticExclusions(
        settings,
        broker,
        "o",
        "r",
        1,
        "PR_1",
        root,
    );
    defer {
        for (refreshed_outcomes.items) |outcome| outcome.deinit();
        refreshed_outcomes.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), refreshed_outcomes.items.len);
    try std.testing.expect(!state.generation.queued("package-lock.json"));
}

const SessionFixturePaths = struct {
    allocator: std.mem.Allocator,
    codex: []u8,
    skill: []u8,
    fn deinit(self: SessionFixturePaths) void {
        self.allocator.free(self.codex);
        self.allocator.free(self.skill);
    }
};

fn installSessionFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    root: []const u8,
) !SessionFixturePaths {
    try tmp.dir.createDirPath(io, "skill/references");
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/SKILL.md", .data = "skill" });
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "skill/references/file-review.md", .data = "file role" },
    );
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "skill/references/github-actions.md", .data = "actions" },
    );
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "skill/references/untrusted-repository-content.md", .data = "untrusted" },
    );
    const codex = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    errdefer allocator.free(codex);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-codex", .data = fakeCodexScript() });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        codex,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    return .{
        .allocator = allocator,
        .codex = codex,
        .skill = try std.fs.path.join(allocator, &.{ root, "skill", "SKILL.md" }),
    };
}

test "exclusions config immediate and idle sessions preserve canonical context" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const paths = try installSessionFixture(allocator, io, &tmp, root);
    defer paths.deinit();
    try verifySessionModes(allocator, io, root, paths);
}

test "file session receives every later revision and active close interrupts its turn" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const paths = try installSessionFixture(allocator, io, &tmp, root);
    defer paths.deinit();
    var registry = try sessions.Registry.start(allocator, io, root, paths.codex);
    defer registry.deinit();
    registry.primary_thread_id = try allocator.dupe(u8, "primary");
    registry.latest_primary_turn_id = try allocator.dupe(u8, "primary-turn");
    const opened = try registry.openFile(
        io,
        root,
        "a.zig",
        "r1",
        "base",
        "head",
        "@@ -1 +1 @@\n-old\n+new\n",
        "[]",
        paths.skill,
        true,
    );
    defer opened.deinit();
    try registry.markPathChangedAndInject("a.zig", "r2", "+revision two");
    try registry.markPathChangedAndInject("a.zig", "r3", "+revision three");
    try std.testing.expectEqualStrings("r3", registry.sessions.items[0].last_injected_revision);
    registry.sessions.items[0].turn_active = true;
    try registry.closeSession(opened.session_id);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{paths.codex});
    defer allocator.free(log_path);
    const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, log, "thread/inject_items"));
    try std.testing.expect(std.mem.indexOf(u8, log, "turn/interrupt") != null);
}

test "local close finalizes when best-effort turn interruption fails" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const paths = try installSessionFixture(allocator, io, &tmp, root);
    defer paths.deinit();
    var registry = try sessions.Registry.start(allocator, io, root, paths.codex);
    defer registry.deinit();
    registry.primary_thread_id = try allocator.dupe(u8, "primary");
    registry.latest_primary_turn_id = try allocator.dupe(u8, "primary-turn");
    const opened = try registry.openFile(
        io,
        root,
        "close.zig",
        "r1",
        "base",
        "head",
        "canonical close diff",
        "[]",
        paths.skill,
        false,
    );
    defer opened.deinit();
    allocator.free(registry.sessions.items[0].turn_id);
    registry.sessions.items[0].turn_id = try allocator.dupe(u8, "fail-interrupt");
    registry.sessions.items[0].turn_active = true;

    try registry.closeSession(opened.session_id);
    try std.testing.expectEqual(
        sessions.SessionStatus.closed,
        registry.sessions.items[0].status,
    );
    try std.testing.expect(!registry.sessions.items[0].turn_active);
}

fn verifySessionModes(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    paths: SessionFixturePaths,
) !void {
    var registry = try sessions.Registry.start(allocator, io, root, paths.codex);
    defer registry.deinit();
    registry.primary_thread_id = try allocator.dupe(u8, "primary");
    registry.latest_primary_turn_id = try allocator.dupe(u8, "primary-turn");
    const idle = try registry.openFile(
        io,
        root,
        "idle.zig",
        "r1",
        "base",
        "head",
        "canonical idle diff",
        "[]",
        paths.skill,
        false,
    );
    defer idle.deinit();
    var identity = try registry.sessionIdentity(idle.session_id);
    try std.testing.expectEqualStrings("", identity.turn_id);
    identity.deinit();
    try registry.message(idle.session_id, "review it");
    try std.testing.expect(registry.sessions.items[0].human_authority == null);
    identity = try registry.sessionIdentity(idle.session_id);
    try std.testing.expect(identity.turn_id.len > 0);
    identity.deinit();
    const immediate = try registry.openFile(
        io,
        root,
        "immediate.zig",
        "r2",
        "base",
        "head",
        "canonical immediate diff",
        "[]",
        paths.skill,
        true,
    );
    defer immediate.deinit();
    const log_path = try std.fmt.allocPrint(
        allocator,
        "{s}.log",
        .{paths.codex},
    );
    defer allocator.free(log_path);
    const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(
        u8,
        log,
        "canonical idle diff",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        log,
        "review it",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        log,
        "canonical immediate diff",
    ) != null);
}

test "worktree integrity managed cleanup restores tracked and removes only review artifacts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = ".gitignore", .data = ".zig-cache/\n" },
    );
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "tracked.txt", .data = "selected\n" },
    );
    for (
        [_][]const []const u8{
            &.{ "git", "init", "-q" },
            &.{ "git", "config", "user.email", "synoptic@example.test" },
            &.{ "git", "config", "user.name", "Synoptic Test" },
            &.{ "git", "add", ".gitignore", "tracked.txt" },
            &.{ "git", "commit", "-qm", "selected" },
        },
    ) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    try tmp.dir.createDirPath(io, ".zig-cache/preexisting");
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = ".zig-cache/preexisting/keep", .data = "keep" },
    );
    var baseline = try worktree.Baseline.capture(allocator, io, root);
    defer baseline.deinit();
    const selected = try allocator.dupe(u8, baseline.head_oid);
    defer allocator.free(selected);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "tracked.txt", .data = "review mutation\n" },
    );
    try tmp.dir.createDirPath(io, ".zig-cache/review");
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = ".zig-cache/review/output", .data = "artifact" },
    );
    try worktree.reconcileShutdown(allocator, io, .{ .managed = root }, selected, &baseline);
    const tracked = try tmp.dir.readFileAlloc(io, "tracked.txt", allocator, .limited(1024));
    defer allocator.free(tracked);
    try std.testing.expectEqualStrings("selected\n", tracked);
    _ = try tmp.dir.statFile(io, ".zig-cache/preexisting/keep", .{});
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io, ".zig-cache/review/output", .{}),
    );
}

test "worktree integrity reused contamination blocks without cleanup" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = ".gitignore", .data = "ignored/\n" },
    );
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "tracked.txt", .data = "selected\n" },
    );
    for (
        [_][]const []const u8{
            &.{ "git", "init", "-q" },
            &.{ "git", "config", "user.email", "synoptic@example.test" },
            &.{ "git", "config", "user.name", "Synoptic Test" },
            &.{ "git", "add", "." },
            &.{ "git", "commit", "-qm", "selected" },
        },
    ) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    try tmp.dir.createDirPath(io, "ignored");
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "ignored/before", .data = "before" },
    );
    var baseline = try worktree.Baseline.capture(allocator, io, root);
    defer baseline.deinit();
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "ignored/after", .data = "after" },
    );
    try std.testing.expectError(
        error.ReusedCheckoutRefreshRequiresManagedMigration,
        worktree.reconcileShutdown(
            allocator,
            io,
            .{ .reused_current = root },
            baseline.head_oid,
            &baseline,
        ),
    );
    _ = try tmp.dir.statFile(io, "ignored/after", .{});
}

test "worktree integrity managed cleanup rejects same-tree HEAD movement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "tracked.txt", .data = "same tree\n" },
    );
    for (
        [_][]const []const u8{
            &.{ "git", "init", "-q" },
            &.{ "git", "config", "user.email", "synoptic@example.test" },
            &.{ "git", "config", "user.name", "Synoptic Test" },
            &.{ "git", "add", "." },
            &.{ "git", "commit", "-qm", "selected" },
        },
    ) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    var baseline = try worktree.Baseline.capture(allocator, io, root);
    defer baseline.deinit();
    const selected = try allocator.dupe(u8, baseline.head_oid);
    defer allocator.free(selected);
    const output = try runGit(
        allocator,
        io,
        root,
        &.{ "git", "commit", "--allow-empty", "-qm", "same tree other identity" },
    );
    allocator.free(output);
    try std.testing.expectError(
        error.ManagedWorktreeCleanupIncomplete,
        worktree.reconcileShutdown(allocator, io, .{ .managed = root }, selected, &baseline),
    );
}

fn prepareSyncRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    source: []const u8,
) !CommitPair {
    try tmp.dir.writeFile(io, .{ .sub_path = "source/.gitignore", .data = "artifacts/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "source/tracked.txt", .data = "base\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| allocator.free(try runGit(allocator, io, source, argv));
    const base_raw = try runGit(allocator, io, source, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    try tmp.dir.writeFile(io, .{ .sub_path = "source/tracked.txt", .data = "head\n" });
    allocator.free(try runGit(allocator, io, source, &.{ "git", "add", "tracked.txt" }));
    allocator.free(try runGit(allocator, io, source, &.{ "git", "commit", "-qm", "head" }));
    const head_raw = try runGit(allocator, io, source, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    return .{
        .allocator = allocator,
        .base = try allocator.dupe(u8, std.mem.trim(u8, base_raw, "\r\n")),
        .head = try allocator.dupe(u8, std.mem.trim(u8, head_raw, "\r\n")),
    };
}

test "worktree integrity Git object hydration discovers a non-origin remote" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "source");
    try tmp.dir.createDirPath(io, "consumer");
    const source = try tmp.dir.realPathFileAlloc(io, "source", allocator);
    defer allocator.free(source);
    const consumer = try tmp.dir.realPathFileAlloc(io, "consumer", allocator);
    defer allocator.free(consumer);
    const commits = try prepareSyncRepo(allocator, io, &tmp, source);
    defer commits.deinit();
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "remote", "add", "upstream", source },
        &.{ "git", "fetch", "--no-tags", "upstream", commits.base },
        &.{ "git", "checkout", "-qb", "feature", "FETCH_HEAD" },
    }) |argv| allocator.free(try runGit(allocator, io, consumer, argv));
    const missing = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "cat-file", "-e", commits.head },
        .cwd = .{ .path = consumer },
    });
    defer allocator.free(missing.stdout);
    defer allocator.free(missing.stderr);
    try std.testing.expect(missing.term != .exited or missing.term.exited != 0);

    try worktree.ensureObjectAvailable(allocator, io, consumer, commits.head);
    allocator.free(try runGit(
        allocator,
        io,
        consumer,
        &.{ "git", "cat-file", "-e", commits.head },
    ));
}

test "worktree integrity managed synchronization cleans then advances detached head" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "source");
    const source = try tmp.dir.realPathFileAlloc(io, "source", allocator);
    defer allocator.free(source);
    const commits = try prepareSyncRepo(allocator, io, &tmp, source);
    defer commits.deinit();
    const base = commits.base;
    const head = commits.head;
    var output = try runGit(allocator, io, source, &.{ "git", "remote", "add", "origin", source });
    allocator.free(output);
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const managed = try std.fs.path.join(allocator, &.{ tmp_root, "managed-sync" });
    defer allocator.free(managed);
    output = try runGit(
        allocator,
        io,
        source,
        &.{ "git", "worktree", "add", "--detach", managed, base },
    );
    allocator.free(output);
    var baseline = try worktree.Baseline.capture(allocator, io, managed);
    defer baseline.deinit();
    const managed_tracked = try std.fs.path.join(allocator, &.{ managed, "tracked.txt" });
    defer allocator.free(managed_tracked);
    try std.Io.Dir.cwd().writeFile(
        io,
        .{ .sub_path = managed_tracked, .data = "review mutation\n" },
    );
    const artifact_dir = try std.fs.path.join(allocator, &.{ managed, "artifacts" });
    defer allocator.free(artifact_dir);
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    const artifact = try std.fs.path.join(allocator, &.{ artifact_dir, "output" });
    defer allocator.free(artifact);
    try std.Io.Dir.cwd().writeFile(
        io,
        .{ .sub_path = artifact, .data = "artifact" },
    );
    try worktree.synchronize(allocator, io, .{ .managed = managed }, source, head, &baseline);
    try std.testing.expectEqualStrings(head, baseline.head_oid);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io, artifact, .{}));
}

fn installPostMergeWitness(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    root: []const u8,
) !void {
    try tmp.dir.writeFile(io, .{
        .sub_path = ".git/hooks/post-merge",
        .data = "#!/bin/sh\nprintf hook > post-merge-ran\n",
    });
    const hook_path = try std.fs.path.join(allocator, &.{ root, ".git/hooks/post-merge" });
    defer allocator.free(hook_path);
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        hook_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
}

test "worktree integrity reused checkout advances only by clean fast forward" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "base\n" });
    for (
        [_][]const []const u8{
            &.{ "git", "init", "-q" },
            &.{ "git", "config", "user.email", "synoptic@example.test" },
            &.{ "git", "config", "user.name", "Synoptic Test" },
            &.{ "git", "add", "." },
            &.{ "git", "commit", "-qm", "base" },
        },
    ) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    const base_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const base = std.mem.trim(u8, base_raw, "\r\n");
    var output = try runGit(allocator, io, root, &.{ "git", "switch", "-qc", "upstream" });
    allocator.free(output);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "tracked.txt", .data = "head\n" },
    );
    for (
        [_][]const []const u8{
            &.{ "git", "add", "tracked.txt" },
            &.{ "git", "commit", "-qm", "head" },
        },
    ) |argv| {
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
    try installPostMergeWitness(allocator, io, &tmp, root);
    var baseline = try worktree.Baseline.capture(allocator, io, root);
    defer baseline.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "drift\n" });
    try std.testing.expectError(
        error.ReusedCheckoutRefreshRequiresManagedMigration,
        worktree.requireReviewAdmission(
            allocator,
            io,
            .{ .reused_current = root },
            &baseline,
        ),
    );
    output = try runGit(allocator, io, root, &.{ "git", "restore", "tracked.txt" });
    allocator.free(output);
    try worktree.synchronize(allocator, io, .{ .reused_current = root }, root, head, &baseline);
    try std.testing.expectEqualStrings(head, baseline.head_oid);
    try std.testing.expectEqualStrings("feature", baseline.branch.?);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io, "post-merge-ran", .{}),
    );
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
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "fake-codex", .data = fakeCodexScript() },
    );
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        codex_path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
    var registry = try sessions.Registry.start(allocator, io, root, codex_path);
    defer registry.deinit();
    registry.primary_thread_id = try allocator.dupe(u8, "primary");
    registry.primary_start_turn_id = try allocator.dupe(u8, "primary-turn");
    registry.primary_turn_active = true;
    try registry.beginSynchronization(io, 200);
    registry.endSynchronization();
    const log_path = try std.fmt.allocPrint(
        allocator,
        "{s}.log",
        .{codex_path},
    );
    defer allocator.free(log_path);
    const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(
        u8,
        log,
        "\"method\":\"turn/interrupt\"",
    ) != null);
}

test "worktree integrity dirty launch selects managed custody" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    const repo = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "repo/tracked.txt", .data = "head\n" },
    );
    for (
        [_][]const []const u8{
            &.{ "git", "init", "-q" },
            &.{ "git", "config", "user.email", "synoptic@example.test" },
            &.{ "git", "config", "user.name", "Synoptic Test" },
            &.{ "git", "switch", "-qc", "feature" },
            &.{ "git", "add", "." },
            &.{ "git", "commit", "-qm", "head" },
        },
    ) |argv| {
        const output = try runGit(allocator, io, repo, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    const output = try runGit(allocator, io, repo, &.{ "git", "remote", "add", "origin", repo });
    allocator.free(output);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "repo/tracked.txt", .data = "dirty\n" },
    );
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const managed = try std.fs.path.join(allocator, &.{ tmp_root, "managed" });
    defer allocator.free(managed);
    const custody = try worktree.select(allocator, io, repo, "feature", head, managed, true);
    defer allocator.free(custody.path());
    try std.testing.expect(custody == .managed);
    var baseline = try worktree.Baseline.capture(allocator, io, custody.path());
    defer baseline.deinit();
    try worktree.reconcileShutdown(allocator, io, custody, head, &baseline);
    try worktree.retireManaged(allocator, io, custody, repo);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, managed, .{}),
    );
}

test "worktree integrity ignored launch artifact selects managed custody" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/ignored");
    const repo = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(repo);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/tracked.txt", .data = "head\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.gitignore", .data = "ignored/\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "switch", "-qc", "feature" },
        &.{ "git", "add", "." },
        &.{ "git", "commit", "-qm", "head" },
    }) |argv| {
        const output = try runGit(allocator, io, repo, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = std.mem.trim(u8, head_raw, "\r\n");
    const remote = try runGit(allocator, io, repo, &.{ "git", "remote", "add", "origin", repo });
    allocator.free(remote);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/ignored/before", .data = "owned\n" });
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_root);
    const managed = try std.fs.path.join(allocator, &.{ tmp_root, "managed-ignored" });
    defer allocator.free(managed);
    const custody = try worktree.select(allocator, io, repo, "feature", head, managed, true);
    defer allocator.free(custody.path());
    try std.testing.expect(custody == .managed);
    try worktree.retireManaged(allocator, io, custody, repo);
    _ = try tmp.dir.statFile(io, "repo/ignored/before", .{});
}

fn fakeLifecycleGhScriptAlloc(
    allocator: std.mem.Allocator,
    base: []const u8,
    head: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
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
        \\  printf '%s' '{{"data":{{"repository":{{"pullRequest":{{"baseRefOid":"{s}","headRefOid":"{s}",'
        \\  printf '%s' '"reviewThreads":{{"nodes":[],"pageInfo":'
        \\  printf '%s\n' '{{"hasNextPage":false,"endCursor":null}}}}}}}}}}}}'; exit 0
        \\fi
        \\printf '%s\n' '{{"data":{{}}}}'
        \\
    ,
        .{ base, head, base, head },
    );
}

fn runLifecycleCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) ![]u8 {
    const result = try std.process.run(
        allocator,
        io,
        .{ .argv = argv, .environ_map = environment },
    );
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("lifecycle command failed: {s}\nstdout:\n{s}\nstderr:\n" ++
            "{s}\n", .{ argv[1], result.stdout, result.stderr });
        allocator.free(result.stdout);
        return error.LifecycleCommandFailed;
    }
    return result.stdout;
}

fn bestEffortLifecycleStop(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    binary: []const u8,
) void {
    const result = std.process.run(
        allocator,
        io,
        .{ .argv = &.{ binary, "stop", "--json" }, .environ_map = environment },
    ) catch return;
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
    const slash = std.mem.indexOfScalarPos(u8, url, prefix.len, '/') orelse
        return error.InvalidLaunchReceipt;
    const token_marker = "?token=";
    const marker = std.mem.indexOf(
        u8,
        url[slash..],
        token_marker,
    ) orelse return error.InvalidLaunchReceipt;
    return .{
        .port = try std.fmt.parseInt(u16, url[prefix.len..slash], 10),
        .token = try allocator.dupe(u8, url[slash + marker + token_marker.len ..]),
        .launch_id = try allocator.dupe(u8, object.get("launchId").?.string),
        .allocator = allocator,
    };
}

const LifecycleFixture = struct {
    allocator: std.mem.Allocator,
    repo: []u8,
    skill: []u8,
    runtime_tmp: []u8,
    binary: [:0]u8,
    codex: []u8,
    gh: []u8,

    fn deinit(self: LifecycleFixture) void {
        self.allocator.free(self.repo);
        self.allocator.free(self.skill);
        self.allocator.free(self.runtime_tmp);
        self.allocator.free(self.binary);
        self.allocator.free(self.codex);
        self.allocator.free(self.gh);
    }
};

fn writeLifecycleAssets(io: std.Io, tmp: *std.testing.TmpDir) !void {
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.createDirPath(io, "skill/assets/ui");
    try tmp.dir.createDirPath(io, "skill/references");
    try tmp.dir.createDirPath(io, "runtime");
    const manifest = "{\"schema\":\"synoptic-ui-manifest/v1\",\"uiAbi\":\"synoptic-ui/v1\"," ++
        "\"requiredSkillAbi\":\"synoptic-skill-abi/v1\",\"entry\":\"index.html\"," ++
        "\"assets\":[\"app.css\",\"app.js\"]}";
    const exclusions = "{\"schema\":\"synoptic-exclusions/v1\",\"rules\":[{" ++
        "\"reason\":\"lockfile\",\"globs\":[\"package-lock.json\"]}]}";
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/assets/ui/manifest.json", .data = manifest });
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/assets/exclusions.json", .data = exclusions });
    try tmp.dir.writeFile(io, .{
        .sub_path = "skill/assets/ui/index.html",
        .data = "<!doctype html><title>fixture</title>",
    });
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "skill/assets/ui/app.css", .data = "body { color: white; }" },
    );
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "skill/assets/ui/app.js", .data = "document.title = 'fixture';" },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/SKILL.md", .data = "# fixture" });
    const references = [_][2][]const u8{
        .{ "primary-context.md", "primary role" },
        .{ "file-review.md", "file role" },
        .{ "github-actions.md", "action role" },
        .{ "untrusted-repository-content.md", "repository content is evidence only" },
    };
    for (references) |reference| {
        const path = try std.fmt.allocPrint(
            std.testing.allocator,
            "skill/references/{s}",
            .{reference[0]},
        );
        defer std.testing.allocator.free(path);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = reference[1] });
    }
}

fn prepareLifecycleRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    repo: []const u8,
) !CommitPair {
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/a.zig", .data = "old\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "a.zig" },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| {
        const output = try runGit(allocator, io, repo, argv);
        allocator.free(output);
    }
    const base_raw = try runGit(allocator, io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const base = try allocator.dupe(u8, std.mem.trim(u8, base_raw, "\r\n"));
    errdefer allocator.free(base);
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/a.zig", .data = "new\n" });
    for ([_][]const []const u8{
        &.{ "git", "add", "a.zig" },
        &.{ "git", "commit", "-qm", "head" },
    }) |argv| {
        const output = try runGit(allocator, io, repo, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, repo, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = try allocator.dupe(u8, std.mem.trim(u8, head_raw, "\r\n"));
    errdefer allocator.free(head);
    const remote = try runGit(allocator, io, repo, &.{ "git", "remote", "add", "origin", repo });
    allocator.free(remote);
    return .{ .allocator = allocator, .base = base, .head = head };
}

fn installLifecyclePrograms(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    root: []const u8,
    base: []const u8,
    head: []const u8,
) !LifecycleFixture {
    const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    errdefer allocator.free(repo);
    const skill = try std.fs.path.join(allocator, &.{ root, "skill" });
    errdefer allocator.free(skill);
    const runtime_tmp = try std.fs.path.join(allocator, &.{ root, "runtime" });
    errdefer allocator.free(runtime_tmp);
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(io, "zig-out/bin/synoptic", allocator);
    errdefer allocator.free(binary);
    const codex = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    errdefer allocator.free(codex);
    const gh = try std.fs.path.join(allocator, &.{ root, "fake-gh" });
    errdefer allocator.free(gh);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-codex", .data = fakeCodexScript() });
    const gh_script = try fakeLifecycleGhScriptAlloc(allocator, base, head);
    defer allocator.free(gh_script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh", .data = gh_script });
    for ([_][]const u8{ codex, gh }) |path| {
        try std.Io.Dir.cwd().setFilePermissions(
            io,
            path,
            std.Io.File.Permissions.fromMode(0o755),
            .{},
        );
    }
    return .{
        .allocator = allocator,
        .repo = repo,
        .skill = skill,
        .runtime_tmp = runtime_tmp,
        .binary = binary,
        .codex = codex,
        .gh = gh,
    };
}

fn lifecycleLaunch(
    fixture: LifecycleFixture,
    io: std.Io,
    environment: *const std.process.Environ.Map,
) ![]u8 {
    return runLifecycleCommand(
        fixture.allocator,
        io,
        environment,
        &.{
            fixture.binary,
            "launch",
            "--cwd",
            fixture.repo,
            "--skill-root",
            fixture.skill,
            "--pr",
            "https://github.com/o/r/pull/1",
            "--no-browser",
            "--json",
        },
    );
}

fn verifyLifecycleStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    fixture: LifecycleFixture,
    address: ReceiptAddress,
) !void {
    const status = try runLifecycleCommand(
        allocator,
        io,
        environment,
        &.{ fixture.binary, "status", "--json" },
    );
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"status\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, address.launch_id) != null);
    const current_path = try std.fs.path.join(
        allocator,
        &.{ fixture.runtime_tmp, "synoptic", "current.json" },
    );
    defer allocator.free(current_path);
    const operational = try std.Io.Dir.cwd().readFileAlloc(
        io,
        current_path,
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(operational);
    try std.testing.expect(std.mem.indexOf(u8, operational, "\"tabs\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, operational, "\"actions\"") == null);
}

fn lifecycleUrl(
    allocator: std.mem.Allocator,
    address: ReceiptAddress,
    path: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/{s}?token={s}",
        .{ address.port, path, address.token },
    );
}

fn waitLifecyclePrimary(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    address: ReceiptAddress,
) !void {
    const url = try lifecycleUrl(allocator, address, "api/bootstrap");
    defer allocator.free(url);
    for (0..200) |_| {
        const payload = try runLifecycleCommand(
            allocator,
            io,
            environment,
            &.{ "/usr/bin/curl", "-fsS", url },
        );
        defer allocator.free(payload);
        if (std.mem.indexOf(u8, payload, "\"primaryReady\":true") != null) return;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |sleep_error| {
            switch (sleep_error) {
                else => {},
            }
        };
    }
    return error.PrimaryNotReady;
}

fn verifyLifecycleHttp(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    address: ReceiptAddress,
) !void {
    const index_url = try lifecycleUrl(allocator, address, "");
    defer allocator.free(index_url);
    const index = try runLifecycleCommand(
        allocator,
        io,
        environment,
        &.{ "/usr/bin/curl", "-fsS", index_url },
    );
    defer allocator.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "fixture") != null);
    const asset_url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/assets/app.js",
        .{address.port},
    );
    defer allocator.free(asset_url);
    const asset = try runLifecycleCommand(
        allocator,
        io,
        environment,
        &.{ "/usr/bin/curl", "-fsS", asset_url },
    );
    defer allocator.free(asset);
    try std.testing.expect(std.mem.indexOf(u8, asset, "document.title") != null);
    const unauthenticated = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}/api/bootstrap",
        .{address.port},
    );
    defer allocator.free(unauthenticated);
    const status = try runLifecycleCommand(
        allocator,
        io,
        environment,
        &.{
            "/usr/bin/curl",
            "-sS",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            unauthenticated,
        },
    );
    defer allocator.free(status);
    try std.testing.expectEqualStrings("403", status);
}

fn verifyLifecycleWebSocket(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: ReceiptAddress,
) !void {
    const socket_address = try std.Io.net.IpAddress.parse("127.0.0.1", address.port);
    var stream = try socket_address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const request = try std.fmt.allocPrint(
        allocator,
        "GET /ws?token={s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nO" ++
            "rigin: http://127.0.0.1:{d}\r\nUpgrade: websocket\r\nC" ++
            "onnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZ" ++
            "SBub25jZQ==\r\n\r\n",
        .{ address.token, address.port, address.port },
    );
    defer allocator.free(request);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var handshake: [1024]u8 = undefined;
    const incoming = try stream.socket.receive(io, &handshake);
    try std.testing.expect(std.mem.indexOf(u8, incoming.data, "101 Switching Protocols") != null);
    try sendMaskedText(io, &stream, "{\"type\":\"file.open\",\"payload\":{\"path\":\"a.zig" ++
        "\",\"diff\":\"BROWSER-SPOOF-DIFF\",\"threads\":\"BROWSER-SPOOF-THREADS\"}}");
    const opened = try readUntil(allocator, io, &stream, "\"type\":\"session.opened\"");
    defer allocator.free(opened);
    const review = try readUntil(allocator, io, &stream, "turn/completed");
    defer allocator.free(review);
    try sendMaskedText(io, &stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId" ++
        "\":\"ses-1\",\"text\":\"prepare the comment\",\"active\":false}}");
    const prepared = try readUntil(allocator, io, &stream, "\"type\":\"action.prepared\"");
    defer allocator.free(prepared);
    try sendMaskedText(io, &stream, "{\"type\":\"app.stop\",\"payload\":{}}");
    const quit = try readUntil(allocator, io, &stream, "\"type\":\"app.stopped\"");
    defer allocator.free(quit);
}

fn waitLifecycleStopped(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    binary: []const u8,
) !void {
    for (0..200) |_| {
        const status = try runLifecycleCommand(
            allocator,
            io,
            environment,
            &.{ binary, "status", "--json" },
        );
        defer allocator.free(status);
        if (std.mem.indexOf(u8, status, "\"status\":\"stopped\"") != null) return;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |sleep_error| {
            switch (sleep_error) {
                else => {},
            }
        };
    }
    return error.ProcessStillRunning;
}

fn verifyLifecycleRestart(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    fixture: LifecycleFixture,
    first_id: []const u8,
) !void {
    const second = try lifecycleLaunch(fixture, io, environment);
    defer allocator.free(second);
    var address = try receiptAddress(allocator, second);
    defer address.deinit();
    try std.testing.expect(!std.mem.eql(u8, first_id, address.launch_id));
    const url = try lifecycleUrl(allocator, address, "api/bootstrap");
    defer allocator.free(url);
    const bootstrap = try runLifecycleCommand(
        allocator,
        io,
        environment,
        &.{ "/usr/bin/curl", "-fsS", url },
    );
    defer allocator.free(bootstrap);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap, "\"tabs\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap, "\"actions\":[]") != null);
    const stopped = try runLifecycleCommand(
        allocator,
        io,
        environment,
        &.{ fixture.binary, "stop", "--json" },
    );
    defer allocator.free(stopped);
    try std.testing.expect(std.mem.indexOf(u8, stopped, "\"status\":\"stopped\"") != null);
}

fn verifyLifecycleFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *std.process.Environ.Map,
    fixture: LifecycleFixture,
) !void {
    try environment.put("SYNOPTIC_GH", "/definitely/missing/synoptic-gh");
    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            fixture.binary,
            "launch",
            "--cwd",
            fixture.repo,
            "--skill-root",
            fixture.skill,
            "--pr",
            "https://github.com/o/r/pull/1",
            "--no-browser",
            "--json",
        },
        .environ_map = environment,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.stderr,
        "\"schema\":\"synoptic-launch-error/v1\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.stderr,
        "\"reason\":\"ExecutableNotFound\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Install codex and gh") != null);
}

fn verifyLifecycleStaleStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    fixture: LifecycleFixture,
) !void {
    const runtime_root = try std.fs.path.join(
        allocator,
        &.{ fixture.runtime_tmp, "synoptic" },
    );
    defer allocator.free(runtime_root);
    const current_path = try std.fs.path.join(allocator, &.{ runtime_root, "current.json" });
    defer allocator.free(current_path);
    const stale = try std.fmt.allocPrint(
        allocator,
        "{{\"runtimeSchema\":\"synoptic-runtime/v1\",\"launchId\"" ++
            ":\"000000000000000000000000000000000000000000000000\"," ++
            "\"runtimeRoot\":{f},\"executable\":{f},\"url\":\"http:" ++
            "//127.0.0.1:1/?token=stale\",\"pid\":{d}}}",
        .{
            std.json.fmt(runtime_root, .{}),
            std.json.fmt(fixture.binary, .{}),
            std.c.getpid(),
        },
    );
    defer allocator.free(stale);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = current_path, .data = stale });
    const status = try runLifecycleCommand(
        allocator,
        io,
        environment,
        &.{ fixture.binary, "status", "--json" },
    );
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"status\":\"stopped\"") != null);
}

test "e2e child lifecycle reconstructs without semantic recovery" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try writeLifecycleAssets(io, &tmp);
    const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo);
    const commits = try prepareLifecycleRepo(allocator, io, &tmp, repo);
    defer commits.deinit();
    const fixture = try installLifecyclePrograms(
        allocator,
        io,
        &tmp,
        root,
        commits.base,
        commits.head,
    );
    defer fixture.deinit();
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("PATH", "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin");
    try environment.put("HOME", root);
    try environment.put("TMPDIR", fixture.runtime_tmp);
    try environment.put("SYNOPTIC_GH", fixture.gh);
    try environment.put("SYNOPTIC_CODEX", fixture.codex);
    defer bestEffortLifecycleStop(allocator, io, &environment, fixture.binary);
    const first = try lifecycleLaunch(fixture, io, &environment);
    defer allocator.free(first);
    var address = try receiptAddress(allocator, first);
    defer address.deinit();
    try verifyLifecycleStatus(allocator, io, &environment, fixture, address);
    try waitLifecyclePrimary(allocator, io, &environment, address);
    try verifyLifecycleHttp(allocator, io, &environment, address);
    try verifyLifecycleWebSocket(allocator, io, address);
    try waitLifecycleStopped(allocator, io, &environment, fixture.binary);
    try verifyLifecycleRestart(
        allocator,
        io,
        &environment,
        fixture,
        address.launch_id,
    );
    try verifyLifecycleStaleStatus(allocator, io, &environment, fixture);
    try verifyLifecycleFailure(allocator, io, &environment, fixture);
}

fn injectedRefresh(runtime: *http.Runtime) !void {
    try worktree.requireManagedRefresh(runtime.custody);
    var next = try domain.PrGeneration.initFull(
        runtime.app.allocator,
        runtime.app.generation.base_oid,
        runtime.app.generation.head_oid,
    );
    errdefer next.deinit();
    try next.addFile(.{ .path = "a.zig", .viewed = .unviewed, .revision_key = "r2" });
    try next.addFile(.{ .path = "b.zig", .viewed = .unviewed, .revision_key = "b1" });
    try runtime.app.updateTabDiff("a.zig", "@@ -1 +1 @@\n+refreshed\n");
    try runtime.registry.markPathChangedAndInject("a.zig", "r2", "@@ -1 +1 @@\n+refreshed\n");
    try runtime.app.updatePullRequestGeneration(next.base_oid, next.head_oid);
    runtime.app.replaceGeneration(next);
    try runtime.registry.setGenerationEvidence(&runtime.app.generation);
    try runtime.registry.updatePrimary("fixture refresh");
}

const WsPrograms = struct {
    allocator: std.mem.Allocator,
    codex: []u8,
    gh: []u8,
    gh_log: []u8,
    skill: []u8,

    fn deinit(self: WsPrograms) void {
        self.allocator.free(self.codex);
        self.allocator.free(self.gh);
        self.allocator.free(self.gh_log);
        self.allocator.free(self.skill);
    }
};

fn prepareWsRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    root: []const u8,
) !CommitPair {
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "old-b\n" });
    for ([_][]const []const u8{
        &.{ "git", "init", "-q" },
        &.{ "git", "config", "user.email", "synoptic@example.test" },
        &.{ "git", "config", "user.name", "Synoptic Test" },
        &.{ "git", "add", "a.zig", "b.zig" },
        &.{ "git", "commit", "-qm", "base" },
    }) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    const base_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(base_raw);
    const base = try allocator.dupe(u8, std.mem.trim(u8, base_raw, "\r\n"));
    errdefer allocator.free(base);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "new\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "new-b\n" });
    for ([_][]const []const u8{
        &.{ "git", "add", "a.zig", "b.zig" },
        &.{ "git", "commit", "-qm", "head" },
    }) |argv| {
        const output = try runGit(allocator, io, root, argv);
        allocator.free(output);
    }
    const head_raw = try runGit(allocator, io, root, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head = try allocator.dupe(u8, std.mem.trim(u8, head_raw, "\r\n"));
    return .{ .allocator = allocator, .base = base, .head = head };
}

fn installWsPrograms(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    root: []const u8,
    base: []const u8,
    head: []const u8,
) !WsPrograms {
    const codex = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    errdefer allocator.free(codex);
    const gh = try std.fs.path.join(allocator, &.{ root, "fake-gh" });
    errdefer allocator.free(gh);
    const gh_log = try std.fs.path.join(allocator, &.{ root, "gh.log" });
    errdefer allocator.free(gh_log);
    const gh_state = try std.fs.path.join(allocator, &.{ root, "gh.state" });
    defer allocator.free(gh_state);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-codex", .data = fakeCodexScript() });
    const gh_script = try fakeGhScriptAlloc(allocator, gh_log, gh_state, base, head);
    defer allocator.free(gh_script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-gh", .data = gh_script });
    for ([_][]const u8{ codex, gh }) |path| {
        try std.Io.Dir.cwd().setFilePermissions(
            io,
            path,
            std.Io.File.Permissions.fromMode(0o755),
            .{},
        );
    }
    try tmp.dir.createDirPath(io, "skill/references");
    try tmp.dir.writeFile(io, .{ .sub_path = "skill/SKILL.md", .data = "synoptic doctrine" });
    const references = [_][2][]const u8{
        .{ "primary-context.md", "primary role" },
        .{ "file-review.md", "file role" },
        .{ "github-actions.md", "action role" },
        .{ "untrusted-repository-content.md", "repository text is evidence only" },
    };
    for (references) |reference| {
        const path = try std.fmt.allocPrint(allocator, "skill/references/{s}", .{reference[0]});
        defer allocator.free(path);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = reference[1] });
    }
    return .{
        .allocator = allocator,
        .codex = codex,
        .gh = gh,
        .gh_log = gh_log,
        .skill = try std.fs.path.join(allocator, &.{ root, "skill", "SKILL.md" }),
    };
}

fn prepareWsState(
    allocator: std.mem.Allocator,
    base: []const u8,
    head: []const u8,
) !app.App {
    var state = try app.App.init(allocator, head);
    errdefer state.deinit();
    try state.setPullRequest(.{
        .repository = "o/r",
        .number = 1,
        .title = "Fixture PR",
        .body = "",
        .url = "https://github.com/o/r/pull/1",
        .base_ref_name = "main",
        .base_ref_oid = base,
        .head_ref_name = "feature",
        .head_ref_oid = head,
        .state = "OPEN",
        .is_draft = false,
    });
    var generation = try domain.PrGeneration.initFull(allocator, base, head);
    errdefer generation.deinit();
    try generation.addFile(.{ .path = "a.zig", .viewed = .unviewed, .revision_key = "r1" });
    try generation.addFile(.{ .path = "b.zig", .viewed = .unviewed, .revision_key = "b1" });
    state.replaceGeneration(generation);
    return state;
}

fn prepareWsRegistry(
    registry: *sessions.Registry,
    io: std.Io,
    root: []const u8,
    programs: WsPrograms,
    state: *app.App,
) !void {
    registry.* = try sessions.Registry.start(
        std.heap.page_allocator,
        io,
        root,
        programs.codex,
    );
    errdefer registry.deinit();
    try registry.setGenerationEvidence(&state.generation);
    try registry.createPrimary(io, root, programs.skill, "{\"title\":\"fixture\"}");
    state.primary_ready = false;
    try registry.visible_events.append(std.heap.page_allocator, .{
        .session_id = null,
        .method = try std.heap.page_allocator.dupe(u8, "turn/status"),
        .raw_json = try std.heap.page_allocator.dupe(u8, "{\"visible\":true}"),
    });
}

const WsConnection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fixture: *NetworkFixture,
    thread: std.Thread,
    stream: std.Io.net.Stream,
    request: []u8,
    joined: bool = false,

    fn deinit(self: *WsConnection) void {
        if (!self.joined) {
            self.stream.close(self.io);
            self.thread.join();
        }
        self.allocator.destroy(self.fixture);
        self.allocator.free(self.request);
    }
};

fn connectWs(
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *http.Server,
    runtime: *http.Runtime,
) !WsConnection {
    const fixture = try allocator.create(NetworkFixture);
    errdefer allocator.destroy(fixture);
    fixture.* = .{ .server = server, .runtime = runtime };
    const thread = try std.Thread.spawn(.{}, NetworkFixture.serve, .{fixture});
    errdefer thread.join();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", server.port());
    var stream = try address.connect(io, .{ .mode = .stream });
    errdefer stream.close(io);
    var token_buf: [64]u8 = undefined;
    const request = try std.fmt.allocPrint(
        allocator,
        "GET /ws?token={s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nO" ++
            "rigin: http://127.0.0.1:{d}\r\nUpgrade: websocket\r\nC" ++
            "onnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZ" ++
            "SBub25jZQ==\r\n\r\n",
        .{ server.tokenHex(&token_buf), server.port(), server.port() },
    );
    errdefer allocator.free(request);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var handshake: [1024]u8 = undefined;
    const incoming = try stream.socket.receive(io, &handshake);
    try std.testing.expect(std.mem.indexOf(u8, incoming.data, "101 Switching Protocols") != null);
    return .{
        .allocator = allocator,
        .io = io,
        .fixture = fixture,
        .thread = thread,
        .stream = stream,
        .request = request,
    };
}

fn verifySlowHeaderIsolation(
    io: std.Io,
    server: *http.Server,
    runtime: *http.Runtime,
) !void {
    server.header_timeout_ms = 10;
    var fixture = NetworkFixture{ .server = server, .runtime = runtime };
    const thread = try std.Thread.spawn(.{}, NetworkFixture.serve, .{&fixture});
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", server.port());
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll("GET /");
    try writer.interface.flush();
    thread.join();
    try std.testing.expect(!fixture.failed.load(.acquire));
}

fn wsRead(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    needle: []const u8,
) ![]u8 {
    return readUntil(allocator, io, stream, needle);
}

fn verifyWsStartup(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *app.App,
    stream: *std.Io.net.Stream,
) !void {
    const status = try wsRead(allocator, io, stream, "\"type\":\"primary.status\"");
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"status\":\"completed\"") != null);
    try std.testing.expect(state.primary_ready);
    const autonomous = try wsRead(allocator, io, stream, "\\\"visible\\\":true");
    defer allocator.free(autonomous);
    try std.testing.expect(std.mem.indexOf(u8, autonomous, "session.item.delta") != null);
    try sendMaskedText(io, stream, "{\"type\":\"snapshot.get\",\"payload\":{}}");
    const snapshot = try wsRead(allocator, io, stream, "\"type\":\"snapshot\"");
    defer allocator.free(snapshot);
    for ([_][]const u8{
        "a.zig",
        "\"repository\":\"o/r\"",
        "\"changeType\":\"MODIFIED\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, snapshot, needle) != null);
    }
}

fn verifyHealthWhileWebSocketActive(io: std.Io, server: *http.Server) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", server.port());
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    try writer.interface.flush();
    var response: [2048]u8 = undefined;
    const deadline = std.Io.Clock.Timestamp.fromNow(
        io,
        .{ .raw = .fromSeconds(2), .clock = .awake },
    );
    var used: usize = 0;
    while (std.mem.indexOf(u8, response[0..used], "\"status\":\"ok\"") == null) {
        const incoming = try stream.socket.receiveTimeout(
            io,
            response[used..],
            .{ .deadline = deadline },
        );
        if (incoming.data.len == 0) break;
        used += incoming.data.len;
        if (used == response.len) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, response[0..used], "200 OK") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, response[0..used], "\"status\":\"ok\"") != null,
    );
}

fn verifyWsOpen(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    codex: []const u8,
) ![]u8 {
    try sendMaskedText(io, stream, "{\"type\":\"file.open\",\"payload\":{\"path\":\"a.zig" ++
        "\",\"diff\":\"BROWSER-SPOOF-DIFF\",\"threads\":\"BROWSER-SPOOF-THREADS\"}}");
    const opened = try wsRead(allocator, io, stream, "\"type\":\"session.opened\"");
    defer allocator.free(opened);
    for ([_][]const u8{ "ses-1", "\"revisionKey\":\"r1\"", "+new" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, opened, needle) != null);
    }
    const review = try wsRead(allocator, io, stream, "review visible");
    defer allocator.free(review);
    const completed = try wsRead(allocator, io, stream, "turn/completed");
    defer allocator.free(completed);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{codex});
    errdefer allocator.free(log_path);
    const log = try std.Io.Dir.cwd().readFileAlloc(
        io,
        log_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "BROWSER-SPOOF-DIFF") == null);
    try std.testing.expect(std.mem.indexOf(u8, log, "BROWSER-SPOOF-THREADS") == null);
    for ([_][]const u8{
        "primary role",
        "file role",
        "repository text is evidence only",
        "\"name\":\"synoptic\"",
        "search_unresolved_threads",
        "prepare_github_action",
        "complete_file_review",
        "close_session",
        "\"approvalPolicy\":\"on-request\"",
        "\"sandbox\":\"read-only\"",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, log, needle) != null);
    }
    return log_path;
}

fn verifyWsSearch(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    log_path: []const u8,
) !void {
    try sendMaskedText(io, stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId" ++
        "\":\"ses-1\",\"text\":\"search cross-file\",\"active\":false}}");
    const started = try wsRead(allocator, io, stream, "turn-started");
    defer allocator.free(started);
    const completed = try wsRead(allocator, io, stream, "turn/completed");
    defer allocator.free(completed);
    for (0..100) |_| {
        const log = try std.Io.Dir.cwd().readFileAlloc(
            io,
            log_path,
            allocator,
            .limited(1024 * 1024),
        );
        defer allocator.free(log);
        const called = std.mem.indexOf(u8, log, "\"id\":\"tool-search\"") != null;
        const succeeded = std.mem.indexOf(u8, log, "\"success\":true") != null;
        if (called and succeeded) return;
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch |sleep_error| {
            switch (sleep_error) {
                else => {},
            }
        };
    }
    return error.SearchToolNotObserved;
}

fn resolveWsApproval(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
) !void {
    const cases = [_][2][]const u8{
        .{ "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId\":\"ses-1\"," ++
            "\"approvalId\":\"apr-999\",\"decision\":\"accept\"}}", "UnknownApproval" },
        .{ "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId\":\"ses-2\"," ++
            "\"approvalId\":\"apr-1\",\"decision\":\"accept\"}}", "CrossSessionApproval" },
        .{ "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId\":\"ses-1\"," ++
            "\"approvalId\":\"apr-1\",\"decision\":\"invented\"}}", "ApprovalDecisionNotOffered" },
    };
    for (cases) |case| {
        try sendMaskedText(io, stream, case[0]);
        const rejected = try wsRead(allocator, io, stream, case[1]);
        defer allocator.free(rejected);
    }
    try sendMaskedText(io, stream, "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId" ++
        "\":\"ses-1\",\"approvalId\":\"apr-1\",\"decision\":\"accept\"}}");
    const resolved = try wsRead(allocator, io, stream, "\"type\":\"approval.resolved\"");
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "\"decision\":\"accept\"") != null);
    const completed = try wsRead(allocator, io, stream, "turn/completed");
    defer allocator.free(completed);
    try sendMaskedText(io, stream, "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId" ++
        "\":\"ses-1\",\"approvalId\":\"apr-1\",\"decision\":\"accept\"}}");
    const duplicate = try wsRead(allocator, io, stream, "ApprovalAlreadyResolved");
    defer allocator.free(duplicate);
}

fn verifyWsApprovals(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    log_path: []const u8,
) !void {
    try sendMaskedText(io, stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId" ++
        "\":\"ses-1\",\"text\":\"run approved command\",\"active\":false}}");
    const started = try wsRead(allocator, io, stream, "turn-started");
    defer allocator.free(started);
    const approval = try wsRead(allocator, io, stream, "\"type\":\"approval.requested\"");
    defer allocator.free(approval);
    for ([_][]const u8{ "apr-1", "make test", "\"decisions\":[\"accept\",\"decline\"]" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, approval, needle) != null);
    }
    try resolveWsApproval(allocator, io, stream);
    try sendMaskedText(io, stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId" ++
        "\":\"ses-1\",\"text\":\"attempt file change\",\"active\":false}}");
    const change_started = try wsRead(allocator, io, stream, "turn-started");
    defer allocator.free(change_started);
    const change_completed = try wsRead(allocator, io, stream, "turn/completed");
    defer allocator.free(change_completed);
    const log = try std.Io.Dir.cwd().readFileAlloc(
        io,
        log_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(log);
    for ([_][]const u8{
        "\"id\":\"approval-command\",\"result\":{\"decision\":\"accept\"}",
        "\"id\":\"approval-file-change\",\"result\":{\"decision\":\"decline\"}",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, log, needle) != null);
    }
}

fn verifyWsAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    state: *app.App,
    gh_log: []const u8,
    head: []const u8,
    tool_domain: *http.ToolDomainContext,
) !void {
    try sendMaskedText(io, stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId" ++
        "\":\"ses-1\",\"text\":\"prepare the comment\",\"active\":false}}");
    const started = try wsRead(allocator, io, stream, "turn-started");
    defer allocator.free(started);
    for (0..200) |_| {
        if (tool_domain.pendingActionCount() == 1) break;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |err| switch (err) {
            else => {},
        };
    }
    try std.testing.expectEqual(@as(usize, 1), tool_domain.pendingActionCount());
    const card = try wsRead(allocator, io, stream, "\"type\":\"action.prepared\"");
    defer allocator.free(card);
    try std.testing.expect(std.mem.indexOf(u8, card, "Could this fail?") != null);
    try std.testing.expectEqual(@as(usize, 1), state.action_store.cards.items.len);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openFileAbsolute(io, gh_log, .{ .allow_directory = false }),
    );
    try sendMaskedText(
        io,
        stream,
        "{\"type\":\"action.confirm\",\"payload\":{\"cardId\":\"act-1\"}}",
    );
    const confirmed = try wsRead(allocator, io, stream, "\"status\":\"succeeded\"");
    defer allocator.free(confirmed);
    const log = try std.Io.Dir.cwd().readFileAlloc(io, gh_log, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    for ([_][]const u8{
        "ARGV:api graphql --hostname github.com --input -",
        "SynopticAddInlineComment",
        "\"path\":\"a.zig\"",
        "\"side\":\"RIGHT\"",
        "Could this fail?",
        head,
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, log, needle) != null);
    }
}

fn verifyWsCompletion(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    state: *app.App,
    tool_domain: *http.ToolDomainContext,
) !void {
    try sendMaskedText(io, stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId" ++
        "\":\"ses-1\",\"text\":\"complete this file\",\"active\":false}}");
    const started = try wsRead(allocator, io, stream, "turn-started");
    defer allocator.free(started);
    for (0..200) |_| {
        if (!tool_domain.fileQueued("a.zig")) break;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |err| switch (err) {
            else => {},
        };
    }
    try std.testing.expect(!tool_domain.fileQueued("a.zig"));
    const completed = try wsRead(allocator, io, stream, "\"type\":\"file.completed\"");
    defer allocator.free(completed);
    try std.testing.expect(!state.generation.queued("a.zig"));
    try std.testing.expectEqual(domain.SessionStatus.completed, state.tabs.items[0].status);
    try sendMaskedText(io, stream, "{\"type\":\"snapshot.get\",\"payload\":{}}");
    const snapshot = try wsRead(allocator, io, stream, "\"type\":\"snapshot\"");
    defer allocator.free(snapshot);
    for ([_][]const u8{
        "\"queue\":[{\"path\":\"b.zig\"",
        "\"status\":\"completed\"",
        "+new",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, snapshot, needle) != null);
    }
}

fn verifyWsCloseSecond(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    state: *app.App,
    gh_log: []const u8,
) !void {
    try sendMaskedText(io, stream, "{\"type\":\"file.open\",\"payload\":{\"path\":\"b.zig\"}}");
    const opened = try wsRead(allocator, io, stream, "ses-2");
    defer allocator.free(opened);
    const review = try wsRead(allocator, io, stream, "review visible");
    defer allocator.free(review);
    const completed = try wsRead(allocator, io, stream, "turn/completed");
    defer allocator.free(completed);
    try sendMaskedText(io, stream, "{\"type\":\"session.message\",\"payload\":{\"sessionId" ++
        "\":\"ses-2\",\"text\":\"close this session\",\"active\":false}}");
    const started = try wsRead(allocator, io, stream, "turn-started");
    defer allocator.free(started);
    const closed = try wsRead(allocator, io, stream, "\"type\":\"session.closed\"");
    defer allocator.free(closed);
    try std.testing.expect(state.generation.queued("b.zig"));
    try std.testing.expectEqual(domain.SessionStatus.closed, state.tabs.items[1].status);
    const log = try std.Io.Dir.cwd().readFileAlloc(io, gh_log, allocator, .limited(1024 * 1024));
    defer allocator.free(log);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, log, "SynopticMarkFileViewed"),
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, log, "SynopticFileState"));
}

fn verifyWsRefresh(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    state: *app.App,
    registry: *sessions.Registry,
) !void {
    try sendMaskedText(io, stream, "{\"type\":\"pr.refresh\",\"payload\":{}}");
    const refreshed = try wsRead(allocator, io, stream, "\"type\":\"pr.refreshed\"");
    defer allocator.free(refreshed);
    const approval = try wsRead(allocator, io, stream, "\"ownerKind\":\"primary\"");
    defer allocator.free(approval);
    try std.testing.expect(std.mem.indexOf(u8, approval, "\"sessionId\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, approval, "git log --oneline") != null);
    try sendMaskedText(io, stream, "{\"type\":\"approval.resolve\",\"payload\":{\"sessionId" ++
        "\":\"ses-1\",\"approvalId\":\"apr-2\",\"decision\":\"accept\"}}");
    const spoof = try wsRead(allocator, io, stream, "CrossSessionApproval");
    defer allocator.free(spoof);
    try sendMaskedText(io, stream, "{\"type\":\"approval.resolve\",\"payload\":{\"approvalId" ++
        "\":\"apr-2\",\"decision\":\"accept\"}}");
    const resolved = try wsRead(allocator, io, stream, "\"type\":\"approval.resolved\"");
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "\"ownerKind\":\"primary\"") != null);
    try std.testing.expect(state.generation.queued("a.zig"));
    try std.testing.expectEqual(domain.SessionStatus.stale_origin, state.tabs.items[0].status);
    try std.testing.expectEqual(
        sessions.SessionStatus.stale_origin,
        registry.sessions.items[0].status,
    );
}

fn verifyWsRound(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    state: *app.App,
) !void {
    try sendMaskedText(io, stream, "{\"type\":\"file.open\",\"payload\":{\"path\":\"a.zig\"}}");
    const opened = try wsRead(allocator, io, stream, "ses-3");
    defer allocator.free(opened);
    const review = try wsRead(allocator, io, stream, "review visible");
    defer allocator.free(review);
    try std.testing.expectEqual(
        domain.SessionStatus.current,
        state.tabs.items[state.tabs.items.len - 1].status,
    );
    try sendMaskedText(io, stream, "{\"type\":\"round.finish\",\"payload\":{}}");
    const finished = try wsRead(allocator, io, stream, "\"type\":\"round.finished\"");
    defer allocator.free(finished);
    try std.testing.expect(std.mem.indexOf(u8, finished, "\"round\":2") != null);
    const pending = try wsRead(allocator, io, stream, "\"ownerKind\":\"primary\"");
    defer allocator.free(pending);
}

fn waitWsDisconnectDecline(
    allocator: std.mem.Allocator,
    io: std.Io,
    log_path: []const u8,
) !void {
    for (0..400) |_| {
        const log = try std.Io.Dir.cwd().readFileAlloc(
            io,
            log_path,
            allocator,
            .limited(1024 * 1024),
        );
        defer allocator.free(log);
        const needle = "\"id\":\"approval-primary\",\"result\":{\"decision\":\"decline\"}";
        if (std.mem.indexOf(u8, log, needle) != null) return;
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch |sleep_error| {
            switch (sleep_error) {
                else => {},
            }
        };
    }
    return error.PrimaryApprovalNotDeclined;
}

fn verifyWsReconnect(
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *http.Server,
    runtime: *http.Runtime,
    request: []const u8,
) !void {
    var connection = try connectWs(allocator, io, server, runtime);
    defer connection.deinit();
    try sendMaskedText(io, &connection.stream, "{\"type\":\"snapshot.get\",\"payload\":{}}");
    const snapshot = try wsRead(allocator, io, &connection.stream, "\"type\":\"snapshot\"");
    defer allocator.free(snapshot);
    for ([_][]const u8{
        "\"round\":2",
        "\"status\":\"stale_origin\"",
        "+refreshed",
        "act-1",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, snapshot, needle) != null);
    }
    _ = request;
    try sendMaskedText(io, &connection.stream, "{\"type\":\"app.stop\",\"payload\":{}}");
    const stopped = try wsRead(allocator, io, &connection.stream, "\"type\":\"app.stopped\"");
    defer allocator.free(stopped);
    try std.testing.expect(runtime.stop_requested);
    try std.testing.expect(!connection.fixture.failed.load(.acquire));
}

fn prepareWsRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    programs: WsPrograms,
    state: *app.App,
    registry: *sessions.Registry,
) !http.Runtime {
    var runtime = http.Runtime{
        .app = state,
        .registry = registry,
        .broker = .{ .allocator = allocator, .io = io, .gh_path = programs.gh },
        .owner = "o",
        .name = "r",
        .number = 1,
        .pull_request_id = "PR_1",
        .cwd = root,
        .skill_path = programs.skill,
        .repository_cwd = root,
        .custody = .{ .managed = root },
        .refresh_override = injectedRefresh,
    };
    const context = try http.ToolDomainContext.create(
        allocator,
        state,
        registry,
        runtime.broker,
        runtime.owner,
        runtime.name,
        runtime.number,
        runtime.pull_request_id,
    );
    try registry.setAuthoritativeToolHandler(context.handler());
    runtime.tool_domain = context;
    return runtime;
}

test "e2e masked websocket streams normalized review and action events" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const commits = try prepareWsRepo(allocator, io, &tmp, root);
    defer commits.deinit();
    var state = try prepareWsState(allocator, commits.base, commits.head);
    defer state.deinit();
    const programs = try installWsPrograms(
        allocator,
        io,
        &tmp,
        root,
        commits.base,
        commits.head,
    );
    defer programs.deinit();
    var registry: sessions.Registry = undefined;
    try prepareWsRegistry(&registry, io, root, programs, &state);
    defer registry.deinit();
    var server = try http.Server.bind(allocator, io, "/does-not-serve-assets-in-this-test");
    defer server.deinit();
    var runtime = try prepareWsRuntime(allocator, io, root, programs, &state, &registry);
    const tool_domain = runtime.tool_domain.?;
    try verifySlowHeaderIsolation(io, &server, &runtime);
    var connection = try connectWs(allocator, io, &server, &runtime);
    defer connection.deinit();
    try verifyWsStartup(allocator, io, &state, &connection.stream);
    try verifyHealthWhileWebSocketActive(io, &server);
    const log_path = try verifyWsOpen(allocator, io, &connection.stream, programs.codex);
    defer allocator.free(log_path);
    try verifyWsSearch(allocator, io, &connection.stream, log_path);
    try verifyWsApprovals(allocator, io, &connection.stream, log_path);
    try verifyWsAction(
        allocator,
        io,
        &connection.stream,
        &state,
        programs.gh_log,
        commits.head,
        tool_domain,
    );
    try verifyWsCompletion(allocator, io, &connection.stream, &state, tool_domain);
    try verifyWsCloseSecond(allocator, io, &connection.stream, &state, programs.gh_log);
    try verifyWsRefresh(allocator, io, &connection.stream, &state, &registry);
    try verifyWsRound(allocator, io, &connection.stream, &state);
    const close_payload = [_]u8{ 0x03, 0xE8, 'b', 'y', 'e' };
    try sendMaskedFrame(io, &connection.stream, 0x8, &close_payload);
    try expectServerCloseEcho(allocator, io, &connection.stream, &close_payload);
    connection.thread.join();
    connection.joined = true;
    try waitWsDisconnectDecline(allocator, io, log_path);
    try verifyWsReconnect(allocator, io, &server, &runtime, connection.request);
    try std.testing.expect(!connection.fixture.failed.load(.acquire));
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
