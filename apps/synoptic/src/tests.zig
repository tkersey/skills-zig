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
    try state.prepareInline("src/a.zig", 12, "Could this fail?", true);
    try std.testing.expectEqual(tools.ActionStatus.pending, state.pending.?.status);
    state.close();
    try std.testing.expect(state.generation.queued("src/a.zig"));
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
    try std.testing.expectError(error.InitialReviewActionForbidden, state.prepareInline("a", 1, "body", true));
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
    const raw = "{\"params\":{\"threadId\":\"file-1\",\"arguments\":{\"slot\":\"finding-1\",\"path\":\"a.zig\",\"line\":7,\"body\":\"Could this fail?\"}}}";
    const input = try tools.decodePreparedAction(std.testing.allocator, raw);
    defer input.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("finding-1", input.slot);
    try std.testing.expectEqual(@as(u32, 7), input.line);
}
test "browser protocol exposes action confirmation but not preparation or completion bypasses" {
    try std.testing.expect(ui.commandAllowed("action.confirm"));
    try std.testing.expect(!ui.commandAllowed("action.prepare"));
    try std.testing.expect(!ui.commandAllowed("file.complete"));
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
    try state.prepareInline("a", 1, "first", true);
    try state.prepareInline("a", 2, "replacement", true);
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
    \\forks=0
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"method":"initialize"'*) printf '%s\n' '{"id":-1,"result":{}}'; continue ;;
    \\    *'"method":"initialized"'*) continue ;;
    \\    *'"id":"tool-'*) continue ;;
    \\  esac
    \\  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  case "$line" in
    \\    *'"method":"thread/start"'*) printf '{"id":%s,"result":{"thread":{"id":"primary"}}}\n' "$id" ;;
    \\    *'"method":"thread/fork"'*) forks=$((forks + 1)); printf '{"id":%s,"result":{"thread":{"id":"file-%s"}}}\n' "$id" "$forks" ;;
    \\    *'"method":"thread/inject_items"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
    \\    *'"method":"turn/interrupt"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
    \\    *'"method":"turn/start"'*)
    \\      if printf '%s' "$line" | grep -q '"threadId":"primary"'; then
    \\        printf '{"id":%s,"result":{"turn":{"id":"primary-turn"}}}\n' "$id"
    \\        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"primary","turn":{"id":"primary-turn"}}}'
    \\      else
    \\        thread_id=$(printf '%s\n' "$line" | sed -n 's/.*"threadId":"\([^"]*\)".*/\1/p')
    \\        printf '{"id":%s,"result":{"turn":{"id":"file-turn"}}}\n' "$id"
    \\        if printf '%s' "$line" | grep -q 'prepare the comment'; then
    \\          printf '{"id":"tool-prepare","method":"item/tool/call","params":{"threadId":"%s","tool":"synoptic.prepare_github_action","arguments":{"slot":"finding-1","path":"a.zig","line":1,"body":"Could this fail?"}}}\n' "$thread_id"
    \\        elif printf '%s' "$line" | grep -q 'complete this file'; then
    \\          printf '{"id":"tool-complete","method":"item/tool/call","params":{"threadId":"%s","tool":"synoptic.complete_file_review","arguments":{}}}\n' "$thread_id"
    \\        elif printf '%s' "$line" | grep -q 'close this session'; then
    \\          printf '{"id":"tool-close","method":"item/tool/call","params":{"threadId":"%s","tool":"synoptic.close_session","arguments":{}}}\n' "$thread_id"
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

fn runGit(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.GitFixtureFailed;
    }
    return result.stdout;
}

fn injectedRefresh(runtime: *http.Runtime) !void {
    try worktree.requireManagedRefresh(runtime.custody);
    var next = try domain.PrGeneration.initFull(runtime.app.allocator, runtime.app.generation.base_oid, "refreshed-head");
    errdefer next.deinit();
    try next.addFile(.{ .path = "a.zig", .viewed = .unviewed, .revision_key = "r2" });
    try next.addFile(.{ .path = "b.zig", .viewed = .unviewed, .revision_key = "b1" });
    try runtime.registry.markPathChangedAndInject("a.zig", "r2", "@@ -1 +1 @@\n+refreshed\n");
    runtime.app.replaceGeneration(next);
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
    try std.testing.expect(!registry.primaryReady());
    try registry.createPrimary(root);
    var spins: usize = 0;
    while (!registry.primaryReady() and spins < 100) : (spins += 1) std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    try std.testing.expect(registry.primaryReady());
    state.primary_ready = true;
    try registry.visible_events.append(std.heap.page_allocator, .{ .session_id = null, .method = try std.heap.page_allocator.dupe(u8, "turn/status"), .raw_json = try std.heap.page_allocator.dupe(u8, "{\"visible\":true}") });
    var server = try http.Server.bind(allocator, io, "/does-not-serve-assets-in-this-test");
    defer server.deinit();
    var runtime = http.Runtime{ .app = &state, .registry = &registry, .broker = .{ .allocator = allocator, .io = io, .gh_path = gh_path }, .owner = "o", .name = "r", .number = 1, .pull_request_id = "PR_1", .cwd = root, .skill_path = "/skill/SKILL.md", .repository_cwd = root, .custody = .{ .managed = root }, .refresh_override = injectedRefresh };
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
