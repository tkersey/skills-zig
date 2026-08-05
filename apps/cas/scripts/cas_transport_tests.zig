const std = @import("std");
const launch = @import("cas_app_server_launch.zig");
const websocket = @import("cas_websocket_transport.zig");

const UnixFixture = struct {
    path: []const u8,
    ready: std.atomic.Value(u8) = .init(0),

    fn serve(self: *UnixFixture) void {
        self.serveFallible() catch self.ready.store(2, .release);
    }

    fn serveFallible(self: *UnixFixture) !void {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const address = try std.Io.net.UnixAddress.init(self.path);
        var listener = try address.listen(io, .{});
        defer listener.deinit(io);
        self.ready.store(1, .release);
        var stream = try listener.accept(io);
        defer stream.close(io);
        var request: [16 * 1024]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, request[0..used], "\r\n\r\n") == null) {
            if (used == request.len) return error.RequestTooLarge;
            const incoming = try stream.socket.receive(io, request[used..]);
            if (incoming.data.len == 0) return error.EndOfStream;
            used += incoming.data.len;
        }
        if (!std.mem.startsWith(u8, request[0..used], "GET / HTTP/1.1\r\n") or
            std.mem.indexOf(u8, request[0..used], "\r\nHost: localhost\r\n") == null)
            return error.InvalidUnixHandshakeRequest;
        const key = fixtureHeader(request[0..used], "sec-websocket-key") orelse return error.MissingKey;
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(key);
        sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        sha1.final(&digest);
        var accept_buf: [28]u8 = undefined;
        const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);
        const response = try std.fmt.allocPrint(std.heap.page_allocator, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
        defer std.heap.page_allocator.free(response);
        var writer = stream.writer(io, &.{});
        try writer.interface.writeAll(response);
        try writer.interface.flush();
    }
};

fn fixtureHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

test "transport spellings and endpoint matrix are exact" {
    try std.testing.expectEqual(launch.RequestedTransport.auto, launch.RequestedTransport.parse("auto").?);
    try std.testing.expectEqual(launch.RequestedTransport.managed_websocket, launch.RequestedTransport.parse("managed-ws").?);
    try std.testing.expectEqual(launch.RequestedTransport.explicit_websocket, launch.RequestedTransport.parse("ws").?);
    try std.testing.expectEqual(launch.RequestedTransport.unix_socket, launch.RequestedTransport.parse("unix").?);
    try std.testing.expect(launch.RequestedTransport.parse("websocket") == null);
    _ = try launch.validateTransport(.stdio, null);
    _ = try launch.validateTransport(.managed_websocket, null);
    _ = try launch.validateTransport(.explicit_websocket, "ws://127.0.0.1:12/");
    _ = try launch.validateTransport(.unix_socket, "unix:///tmp/cas.sock");
    _ = try launch.validateTransport(.unix_socket, null);
    try std.testing.expectError(error.TransportEndpointForbidden, launch.validateTransport(.stdio, "ws://127.0.0.1:1"));
    try std.testing.expectError(error.TransportEndpointRequired, launch.validateTransport(.explicit_websocket, null));
    try std.testing.expectError(error.NonLoopbackWebSocketEndpoint, launch.validateTransport(.explicit_websocket, "ws://example.com:1"));
}

test "loopback families are accepted and remote inbound websocket is not" {
    for (&[_][]const u8{ "ws://localhost:1", "ws://localhost.:1", "ws://127.0.0.1:2", "ws://127.9.8.7:3", "ws://127.255.0.1:3", "ws://[::1]:4" }) |value| {
        try launch.validateInboundWebSocket(value);
    }
    try std.testing.expectError(error.NonLoopbackWebSocketEndpoint, launch.validateInboundWebSocket("ws://10.0.0.1:1"));
    try std.testing.expectError(error.WebSocketUserinfoForbidden, launch.validateInboundWebSocket("ws://user:secret@127.0.0.1:1"));
    try std.testing.expectError(error.WebSocketPortRequired, launch.validateInboundWebSocket("ws://127.0.0.1"));
    try std.testing.expectError(error.WebSocketPortZero, launch.validateInboundWebSocket("ws://127.0.0.1:0"));
    try std.testing.expectError(error.WebSocketQueryOrFragmentForbidden, launch.validateInboundWebSocket("ws://127.0.0.1:1/?secret=x"));
    try std.testing.expectError(error.WebSocketQueryOrFragmentForbidden, launch.validateInboundWebSocket("ws://127.0.0.1:1/#x"));
    try std.testing.expectError(error.InvalidWebSocketUrl, launch.validateInboundWebSocket("wss://localhost:1"));
    try std.testing.expectError(error.NonLoopbackWebSocketEndpoint, launch.validateInboundWebSocket("ws://127.evil:1"));
    try std.testing.expectError(error.NonLoopbackWebSocketEndpoint, launch.validateInboundWebSocket("ws://127.0.0.1.evil:1"));
    try std.testing.expectError(error.NonLoopbackWebSocketEndpoint, launch.validateInboundWebSocket("ws://127.:1"));
    try std.testing.expectError(error.UnsafeUrlByte, launch.validateInboundWebSocket("ws://127.0.0.1:1/a b"));
}

test "unix path resolution is lexical and bounded" {
    const relative = try launch.resolveUnixPathAlloc(std.testing.allocator, "/tmp/work", "run/cas.sock");
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings("/tmp/work/run/cas.sock", relative);
    const absolute = try launch.resolveUnixPathAlloc(std.testing.allocator, "/ignored", "/tmp/cas.sock");
    defer std.testing.allocator.free(absolute);
    try std.testing.expectEqualStrings("/tmp/cas.sock", absolute);
    var too_long: [104]u8 = @splat('x');
    try std.testing.expectError(error.UnixSocketPathTooLong, launch.validateUnixPath(&too_long));
}

test "code mode host enforces TLS remotely and never exposes secrets in identity" {
    var loopback = try launch.CodeModeHost.init(std.testing.allocator, "ws://user:secret@127.0.0.1:9090/path?token=hidden");
    defer loopback.deinit();
    try std.testing.expectEqualStrings("ws://127.0.0.1:9090", loopback.redacted_origin);
    try std.testing.expect(std.mem.indexOf(u8, loopback.redacted_origin, "secret") == null);
    var digest_hex: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 64), loopback.digestHex(&digest_hex).len);
    try std.testing.expectEqualStrings("ws://user:secret@127.0.0.1:9090/path?token=hidden", loopback.raw);

    var remote = try launch.CodeModeHost.init(std.testing.allocator, "wss://user:secret@example.com:443/mode?token=hidden");
    defer remote.deinit();
    try std.testing.expectEqualStrings("wss://example.com:443", remote.redacted_origin);
    try std.testing.expectError(error.InsecureRemoteCodeModeHost, launch.CodeModeHost.init(std.testing.allocator, "ws://example.com/mode"));
    try std.testing.expectError(error.UnsafeUrlByte, launch.CodeModeHost.init(std.testing.allocator, "wss://example.com/a\tb"));

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try launch.appendAppServerArgs(std.testing.allocator, &argv, false, "ws://127.0.0.1:0", &remote);
    try std.testing.expectEqualStrings("--code-mode-host", argv.items[3]);
    try std.testing.expectEqualStrings(remote.raw, argv.items[4]);
}

test "auto fallback is possible only pre-RPC after managed retirement" {
    try std.testing.expect(launch.autoMayFallback(.auto, .managed_websocket, .stdio, .before_first_rpc, true));
    try std.testing.expect(!launch.autoMayFallback(.auto, .managed_websocket, .stdio, .rpc_started, true));
    try std.testing.expect(!launch.autoMayFallback(.auto, .managed_websocket, .stdio, .before_first_rpc, false));
    try std.testing.expect(!launch.autoMayFallback(.explicit_websocket, .managed_websocket, .stdio, .before_first_rpc, true));
    try std.testing.expect(!launch.autoMayFallback(.auto, .explicit_websocket, .stdio, .before_first_rpc, true));
}

test "shared websocket bounds remain fixed" {
    try std.testing.expectEqual(@as(usize, 4 * 1024), websocket.max_endpoint_bytes);
    try std.testing.expectEqual(@as(usize, 16 * 1024), websocket.max_handshake_header_bytes);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), websocket.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 1024), websocket.max_fragments);
    try std.testing.expectEqual(@as(u32, 10_000), websocket.default_startup_timeout_ms);
}

test "unix websocket rejects an overlong socket before connect" {
    var too_long: [104]u8 = @splat('x');
    try std.testing.expectError(
        error.UnixSocketPathTooLong,
        websocket.Connection.connectUnix(std.testing.allocator, &too_long, 1),
    );
}

test "unix websocket performs RFC6455 upgrade on slash localhost" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "cas.sock" });
    defer std.testing.allocator.free(path);
    var fixture = UnixFixture{ .path = path };
    const thread = try std.Thread.spawn(.{}, UnixFixture.serve, .{&fixture});
    defer thread.join();
    for (0..100) |_| {
        const state = fixture.ready.load(.acquire);
        if (state == 1) break;
        if (state == 2) return error.UnixFixtureFailed;
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(10), .awake) catch {};
    } else return error.UnixFixtureTimeout;
    var connection = try websocket.Connection.connectUnix(std.testing.allocator, path, 2_000);
    defer connection.deinit();
    connection.close();
}

test "managed websocket asks Codex for port zero and reaches readiness" {
    const codex_bin_z = std.c.getenv("CODEX_BIN") orelse return error.SkipZigTest;
    const codex_bin = std.mem.span(codex_bin_z);
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var server = try websocket.startManagedLoopbackServer(
        std.testing.allocator,
        ".",
        codex_bin,
        .inherit,
        threaded.io(),
    );
    defer server.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, server.listen_url, "ws://127.0.0.1:"));
    try std.testing.expect(!std.mem.endsWith(u8, server.listen_url, ":0"));
    var connection = try websocket.Connection.connect(std.testing.allocator, server.listen_url, 2_000);
    defer connection.deinit();
    connection.close();
}

test "owner-lived managed websocket also resolves port zero before return" {
    const codex_bin_z = std.c.getenv("CODEX_BIN") orelse return error.SkipZigTest;
    const codex_bin = std.mem.span(codex_bin_z);
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const receipt_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "fresh", "receipts" });
    defer std.testing.allocator.free(receipt_dir);
    var server = try websocket.startOwnerLivedLoopbackServer(
        std.testing.allocator,
        ".",
        receipt_dir,
        codex_bin,
        .inherit,
        threaded.io(),
    );
    defer server.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.endsWith(u8, server.listen_url, ":0"));
    var connection = try websocket.Connection.connect(std.testing.allocator, server.listen_url, 2_000);
    defer connection.deinit();
    connection.close();
}
