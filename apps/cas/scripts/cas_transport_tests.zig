const std = @import("std");
const proxy = @import("cas_proxy_client");
const launch = proxy.app_server_launch;
const websocket = proxy.websocket_transport;

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 3) return error.InvalidFixtureArguments;
    try serveCodeModeHostFixture(init.gpa, init.io, argv[1], argv[2]);
}

fn serveCodeModeHostFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    ready_path: []const u8,
    evidence_path: []const u8,
) !void {
    var listen_address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try listen_address.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    const url = try std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}/", .{port});
    defer allocator.free(url);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ready_path, .data = url });

    var stream = try listener.accept(io);
    defer stream.close(io);
    var request: [16 * 1024]u8 = undefined;
    var used: usize = 0;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromMilliseconds(10_000),
        .clock = .awake,
    });
    while (std.mem.indexOf(u8, request[0..used], "\r\n\r\n") == null) {
        if (used == request.len) return error.RequestTooLarge;
        const incoming = try stream.socket.receiveTimeout(
            io,
            request[used..],
            .{ .deadline = deadline },
        );
        if (incoming.data.len == 0) return error.EndOfStream;
        used += incoming.data.len;
    }
    if (!std.mem.startsWith(u8, request[0..used], "GET / HTTP/1.1\r\n")) {
        return error.InvalidCodeModeHostHandshakeRequest;
    }
    const key = fixtureHeader(request[0..used], "sec-websocket-key") orelse
        return error.MissingKey;
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var accept_buf: [28]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);
    const response = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    defer allocator.free(response);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(response);
    try writer.interface.flush();
    try serveCodeModeProtocol(allocator, io, &stream, evidence_path);
}

const max_code_mode_fixture_message_bytes: usize = 8 * 1024 * 1024;

const CodeModeFixtureState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    evidence_path: []const u8,
    evidence: *std.Io.Writer.Allocating,
    session_id: *?[]u8,
    execute_seen: *bool,
};

fn serveCodeModeProtocol(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    evidence_path: []const u8,
) !void {
    var evidence: std.Io.Writer.Allocating = .init(allocator);
    defer evidence.deinit();
    var session_id: ?[]u8 = null;
    defer if (session_id) |value| allocator.free(value);
    var execute_seen = false;

    for (0..8) |_| {
        const raw = readCodeModeClientJsonAlloc(allocator, io, stream) catch |err| {
            if (execute_seen and err == error.EndOfStream) return;
            return err;
        };
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidCodeModeProtocolMessage,
        };
        var state: CodeModeFixtureState = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .evidence_path = evidence_path,
            .evidence = &evidence,
            .session_id = &session_id,
            .execute_seen = &execute_seen,
        };
        if (try handleCodeModeMessage(&state, root)) return;
    }
    return error.CodeModeFixtureRequestLimitExceeded;
}

fn handleCodeModeMessage(
    state: *CodeModeFixtureState,
    root: std.json.ObjectMap,
) !bool {
    const message_type = jsonObjectString(root, "type") orelse
        return error.InvalidCodeModeProtocolMessage;
    if (std.mem.eql(u8, message_type, "connection/hello")) {
        try state.evidence.writer.writeAll("connection/hello\n");
        try writeCodeModeServerJson(
            state.allocator,
            state.io,
            state.stream,
            "{\"type\":\"connection/ready\"," ++
                "\"selectedVersion\":1,\"capabilities\":[]}",
        );
        return false;
    }
    if (!std.mem.eql(u8, message_type, "operation/request")) {
        return error.InvalidCodeModeProtocolMessage;
    }
    const id = jsonObjectInt(root, "id") orelse
        return error.InvalidCodeModeProtocolMessage;
    const request_value = root.get("request") orelse
        return error.InvalidCodeModeProtocolMessage;
    const request_object = switch (request_value) {
        .object => |value| value,
        else => return error.InvalidCodeModeProtocolMessage,
    };
    const method = jsonObjectString(request_object, "method") orelse
        return error.InvalidCodeModeProtocolMessage;
    const request_session_id = jsonObjectString(request_object, "sessionId") orelse
        return error.InvalidCodeModeProtocolMessage;
    if (std.mem.eql(u8, method, "session/open")) {
        try handleCodeModeSessionOpen(state, id, request_session_id);
        return false;
    }
    if (state.session_id.* == null or
        !std.mem.eql(u8, state.session_id.*.?, request_session_id))
    {
        return error.CodeModeSessionMismatch;
    }
    if (std.mem.eql(u8, method, "session/execute")) {
        try handleCodeModeExecute(state, id, request_object);
        return false;
    }
    if (std.mem.eql(u8, method, "session/shutdown")) {
        try handleCodeModeShutdown(state, id, request_session_id);
        return true;
    }
    return error.UnsupportedCodeModeFixtureRequest;
}

fn handleCodeModeSessionOpen(
    state: *CodeModeFixtureState,
    id: i64,
    request_session_id: []const u8,
) !void {
    if (state.session_id.* != null) return error.DuplicateCodeModeSession;
    state.session_id.* = try state.allocator.dupe(u8, request_session_id);
    try state.evidence.writer.writeAll("session/open\n");
    const response_json = try codeModeSessionResponseAlloc(
        state.allocator,
        id,
        "session/ready",
        "sessionId",
        request_session_id,
    );
    defer state.allocator.free(response_json);
    try writeCodeModeServerJson(state.allocator, state.io, state.stream, response_json);
}

fn handleCodeModeExecute(
    state: *CodeModeFixtureState,
    id: i64,
    request_object: std.json.ObjectMap,
) !void {
    const execute_value = request_object.get("request") orelse
        return error.InvalidCodeModeExecuteRequest;
    const execute_object = switch (execute_value) {
        .object => |value| value,
        else => return error.InvalidCodeModeExecuteRequest,
    };
    const source = jsonObjectString(execute_object, "source") orelse
        return error.InvalidCodeModeExecuteRequest;
    const nonce = codeModeNonceFromSource(source) orelse
        return error.MissingCodeModeProbeNonce;
    try state.evidence.writer.print("session/execute {s}\n", .{nonce});
    const started = try codeModeSessionResponseAlloc(
        state.allocator,
        id,
        "execution/started",
        "cellId",
        "cas-code-mode-cell",
    );
    defer state.allocator.free(started);
    try writeCodeModeServerJson(state.allocator, state.io, state.stream, started);
    const initial = try codeModeInitialResponseAlloc(state.allocator, id, nonce);
    defer state.allocator.free(initial);
    try writeCodeModeServerJson(state.allocator, state.io, state.stream, initial);
    state.execute_seen.* = true;
    try writeCodeModeEvidence(state);
}

fn handleCodeModeShutdown(
    state: *CodeModeFixtureState,
    id: i64,
    request_session_id: []const u8,
) !void {
    try state.evidence.writer.writeAll("session/shutdown\n");
    const response_json = try codeModeSessionResponseAlloc(
        state.allocator,
        id,
        "session/closed",
        "sessionId",
        request_session_id,
    );
    defer state.allocator.free(response_json);
    try writeCodeModeServerJson(state.allocator, state.io, state.stream, response_json);
    if (!state.execute_seen.*) return error.CodeModeExecuteNotObserved;
    try writeCodeModeEvidence(state);
}

fn writeCodeModeEvidence(state: *CodeModeFixtureState) !void {
    const evidence_bytes = try state.evidence.toOwnedSlice();
    defer state.allocator.free(evidence_bytes);
    try std.Io.Dir.cwd().writeFile(state.io, .{
        .sub_path = state.evidence_path,
        .data = evidence_bytes,
    });
}

fn jsonObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonObjectInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn codeModeNonceFromSource(source: []const u8) ?[]const u8 {
    const marker = "CAS_CODE_MODE_PROBE_";
    const start = std.mem.indexOf(u8, source, marker) orelse return null;
    var end = start + marker.len;
    while (end < source.len and std.ascii.isHex(source[end])) end += 1;
    if (end == start + marker.len) return null;
    return source[start..end];
}

fn codeModeSessionResponseAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    response_type: []const u8,
    identity_key: []const u8,
    identity_value: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"type\":\"operation/response\",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(",\"result\":{\"status\":\"ok\",\"value\":{\"type\":");
    try std.json.Stringify.value(response_type, .{}, &output.writer);
    try output.writer.writeByte(',');
    try std.json.Stringify.value(identity_key, .{}, &output.writer);
    try output.writer.writeByte(':');
    try std.json.Stringify.value(identity_value, .{}, &output.writer);
    try output.writer.writeAll("}}}");
    return output.toOwnedSlice();
}

fn codeModeInitialResponseAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    nonce: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"type\":\"execute/initialResponse\",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    try output.writer.writeAll(
        ",\"result\":{\"status\":\"ok\",\"value\":{\"Result\":" ++
            "{\"cell_id\":\"cas-code-mode-cell\",\"content_items\":[" ++
            "{\"type\":\"input_text\",\"text\":",
    );
    try std.json.Stringify.value(nonce, .{}, &output.writer);
    try output.writer.writeAll("}],\"error_text\":null}}}}");
    return output.toOwnedSlice();
}

fn readCodeModeClientJsonAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
) ![]u8 {
    var header: [2]u8 = undefined;
    try receiveExact(io, stream, &header);
    if (header[0] != 0x82 or header[1] & 0x80 == 0) {
        return error.InvalidCodeModeWebSocketFrame;
    }
    var payload_length: usize = header[1] & 0x7f;
    if (payload_length == 126) {
        var extended: [2]u8 = undefined;
        try receiveExact(io, stream, &extended);
        payload_length = std.mem.readInt(u16, &extended, .big);
    } else if (payload_length == 127) {
        var extended: [8]u8 = undefined;
        try receiveExact(io, stream, &extended);
        const length_u64 = std.mem.readInt(u64, &extended, .big);
        if (length_u64 > max_code_mode_fixture_message_bytes) {
            return error.CodeModeWebSocketFrameTooLarge;
        }
        payload_length = @intCast(length_u64);
    }
    if (payload_length < 4 or payload_length > max_code_mode_fixture_message_bytes) {
        return error.CodeModeWebSocketFrameTooLarge;
    }
    var mask: [4]u8 = undefined;
    try receiveExact(io, stream, &mask);
    const framed = try allocator.alloc(u8, payload_length);
    defer allocator.free(framed);
    try receiveExact(io, stream, framed);
    for (framed, 0..) |*byte, index| byte.* ^= mask[index % mask.len];
    const json_length: usize = std.mem.readInt(u32, framed[0..4], .little);
    if (json_length != framed.len - 4) return error.InvalidCodeModeProtocolFrame;
    return allocator.dupe(u8, framed[4..]);
}

fn writeCodeModeServerJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    json: []const u8,
) !void {
    const protocol_length = 4 + json.len;
    if (protocol_length > max_code_mode_fixture_message_bytes) {
        return error.CodeModeWebSocketFrameTooLarge;
    }
    var header: [10]u8 = undefined;
    header[0] = 0x82;
    const header_length: usize = if (protocol_length <= 125) blk: {
        header[1] = @intCast(protocol_length);
        break :blk 2;
    } else if (protocol_length <= std.math.maxInt(u16)) blk: {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(protocol_length), .big);
        break :blk 4;
    } else blk: {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], protocol_length, .big);
        break :blk 10;
    };
    var length_prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_prefix, @intCast(json.len), .little);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(header[0..header_length]);
    try writer.interface.writeAll(&length_prefix);
    try writer.interface.writeAll(json);
    try writer.interface.flush();
    _ = allocator;
}

fn receiveExact(
    io: std.Io,
    stream: *std.Io.net.Stream,
    destination: []u8,
) !void {
    var used: usize = 0;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromMilliseconds(15_000),
        .clock = .awake,
    });
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
        const key = fixtureHeader(
            request[0..used],
            "sec-websocket-key",
        ) orelse return error.MissingKey;
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(key);
        sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        sha1.final(&digest);
        var accept_buf: [28]u8 = undefined;
        const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);
        const response = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept},
        );
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
    try std.testing.expectEqual(
        launch.RequestedTransport.auto,
        launch.RequestedTransport.parse("auto").?,
    );
    try std.testing.expectEqual(
        launch.RequestedTransport.managed_websocket,
        launch.RequestedTransport.parse("managed-ws").?,
    );
    try std.testing.expectEqual(
        launch.RequestedTransport.explicit_websocket,
        launch.RequestedTransport.parse("ws").?,
    );
    try std.testing.expectEqual(
        launch.RequestedTransport.unix_socket,
        launch.RequestedTransport.parse("unix").?,
    );
    try std.testing.expect(launch.RequestedTransport.parse("websocket") == null);
    try std.testing.expectEqualStrings(
        "managed-ws",
        launch.RequestedTransport.managed_websocket.asString(),
    );
    _ = try launch.validateTransport(.stdio, null);
    _ = try launch.validateTransport(.managed_websocket, null);
    _ = try launch.validateTransport(.explicit_websocket, "ws://127.0.0.1:12/");
    _ = try launch.validateTransport(.unix_socket, "unix:///tmp/cas.sock");
    _ = try launch.validateTransport(.unix_socket, null);
    try std.testing.expectError(
        error.TransportEndpointForbidden,
        launch.validateTransport(.stdio, "ws://127.0.0.1:1"),
    );
    try std.testing.expectError(
        error.TransportEndpointRequired,
        launch.validateTransport(.explicit_websocket, null),
    );
    try std.testing.expectError(
        error.NonLoopbackWebSocketEndpoint,
        launch.validateTransport(.explicit_websocket, "ws://example.com:1"),
    );
}

test "loopback families are accepted and remote inbound websocket is not" {
    for (&[_][]const u8{
        "ws://localhost:1",
        "ws://localhost.:1",
        "ws://127.0.0.1:2",
        "ws://127.9.8.7:3",
        "ws://127.255.0.1:3",
        "ws://[::1]:4",
    }) |value| {
        try launch.validateInboundWebSocket(value);
    }
    try std.testing.expectError(
        error.NonLoopbackWebSocketEndpoint,
        launch.validateInboundWebSocket("ws://10.0.0.1:1"),
    );
    try std.testing.expectError(
        error.WebSocketUserinfoForbidden,
        launch.validateInboundWebSocket("ws://user:secret@127.0.0.1:1"),
    );
    try std.testing.expectError(
        error.WebSocketPortRequired,
        launch.validateInboundWebSocket("ws://127.0.0.1"),
    );
    try std.testing.expectError(
        error.WebSocketPortZero,
        launch.validateInboundWebSocket("ws://127.0.0.1:0"),
    );
    try std.testing.expectError(
        error.WebSocketQueryOrFragmentForbidden,
        launch.validateInboundWebSocket("ws://127.0.0.1:1/?secret=x"),
    );
    try std.testing.expectError(
        error.WebSocketQueryOrFragmentForbidden,
        launch.validateInboundWebSocket("ws://127.0.0.1:1/#x"),
    );
    try std.testing.expectError(
        error.InvalidWebSocketUrl,
        launch.validateInboundWebSocket("wss://localhost:1"),
    );
    try std.testing.expectError(
        error.NonLoopbackWebSocketEndpoint,
        launch.validateInboundWebSocket("ws://127.evil:1"),
    );
    try std.testing.expectError(
        error.NonLoopbackWebSocketEndpoint,
        launch.validateInboundWebSocket("ws://127.0.0.1.evil:1"),
    );
    try std.testing.expectError(
        error.NonLoopbackWebSocketEndpoint,
        launch.validateInboundWebSocket("ws://127.:1"),
    );
    try std.testing.expectError(
        error.UnsafeUrlByte,
        launch.validateInboundWebSocket("ws://127.0.0.1:1/a b"),
    );
}

test "unix path resolution is lexical and bounded" {
    const relative = try launch.resolveUnixPathAlloc(
        std.testing.allocator,
        "/tmp/work",
        "run/cas.sock",
    );
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings("/tmp/work/run/cas.sock", relative);
    const absolute = try launch.resolveUnixPathAlloc(
        std.testing.allocator,
        "/ignored",
        "/tmp/cas.sock",
    );
    defer std.testing.allocator.free(absolute);
    try std.testing.expectEqualStrings("/tmp/cas.sock", absolute);
    var too_long: [104]u8 = @splat('x');
    try std.testing.expectError(error.UnixSocketPathTooLong, launch.validateUnixPath(&too_long));
}

test "code mode host accepts only released HTTP root endpoints" {
    var loopback = try launch.CodeModeHost.init(
        std.testing.allocator,
        "http://127.0.0.1:9090/",
    );
    defer loopback.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:9090", loopback.redacted_origin);
    var digest_hex: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 64), loopback.digestHex(&digest_hex).len);
    try std.testing.expectEqualStrings("http://127.0.0.1:9090/", loopback.raw);

    var remote = try launch.CodeModeHost.init(
        std.testing.allocator,
        "https://example.com:443/",
    );
    defer remote.deinit();
    try std.testing.expectEqualStrings("https://example.com:443", remote.redacted_origin);
    try std.testing.expectError(
        error.InsecureRemoteCodeModeHost,
        launch.CodeModeHost.init(std.testing.allocator, "http://example.com/"),
    );
    try std.testing.expectError(
        error.UnsafeUrlByte,
        launch.CodeModeHost.init(std.testing.allocator, "https://example.com/a\tb"),
    );
    try std.testing.expectError(
        error.CodeModeHostUserinfoForbidden,
        launch.CodeModeHost.init(std.testing.allocator, "https://user:secret@example.com/"),
    );
    try std.testing.expectError(
        error.CodeModeHostRootRequired,
        launch.CodeModeHost.init(std.testing.allocator, "https://example.com/code-mode"),
    );
    try std.testing.expectError(
        error.InvalidCodeModeHost,
        launch.CodeModeHost.init(std.testing.allocator, "wss://example.com/"),
    );
    try std.testing.expectError(
        error.InvalidCodeModeHost,
        launch.CodeModeHost.init(std.testing.allocator, "https://example.com:invalid/"),
    );
    try std.testing.expectError(
        error.InvalidCodeModeHost,
        launch.CodeModeHost.init(std.testing.allocator, "https://example.com:/"),
    );
    try std.testing.expectError(
        error.InvalidCodeModeHost,
        launch.CodeModeHost.init(std.testing.allocator, "https://::1/"),
    );

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try launch.appendAppServerArgs(
        std.testing.allocator,
        &argv,
        false,
        "ws://127.0.0.1:0",
        &remote,
    );
    try std.testing.expectEqualStrings("--code-mode-host", argv.items[3]);
    try std.testing.expectEqualStrings(remote.raw, argv.items[4]);
}

test "auto fallback is possible only pre-RPC after managed retirement" {
    try std.testing.expect(launch.autoMayFallback(
        .auto,
        .managed_websocket,
        .stdio,
        .before_first_rpc,
        true,
    ));
    try std.testing.expect(!launch.autoMayFallback(
        .auto,
        .managed_websocket,
        .stdio,
        .rpc_started,
        true,
    ));
    try std.testing.expect(!launch.autoMayFallback(
        .auto,
        .managed_websocket,
        .stdio,
        .before_first_rpc,
        false,
    ));
    try std.testing.expect(!launch.autoMayFallback(
        .explicit_websocket,
        .managed_websocket,
        .stdio,
        .before_first_rpc,
        true,
    ));
    try std.testing.expect(!launch.autoMayFallback(
        .auto,
        .explicit_websocket,
        .stdio,
        .before_first_rpc,
        true,
    ));
}

test "shared websocket bounds remain fixed" {
    try std.testing.expectEqual(@as(usize, 4 * 1024), websocket.max_endpoint_bytes);
    try std.testing.expectEqual(
        @as(usize, 16 * 1024),
        websocket.max_handshake_header_bytes,
    );
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
    const root = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        ".",
        std.testing.allocator,
    );
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
        std.Io.sleep(
            std.Io.Threaded.global_single_threaded.io(),
            .fromMilliseconds(10),
            .awake,
        ) catch |err| switch (err) {
            else => {},
        };
    } else return error.UnixFixtureTimeout;
    var connection = try websocket.Connection.connectUnix(
        std.testing.allocator,
        path,
        2_000,
    );
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
    try std.testing.expect(std.mem.startsWith(
        u8,
        server.listen_url,
        "ws://127.0.0.1:",
    ));
    try std.testing.expect(!std.mem.endsWith(u8, server.listen_url, ":0"));
    var connection = try websocket.Connection.connect(
        std.testing.allocator,
        server.listen_url,
        2_000,
    );
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
    const receipt_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "fresh", "receipts" },
    );
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
    var connection = try websocket.Connection.connect(
        std.testing.allocator,
        server.listen_url,
        2_000,
    );
    defer connection.deinit();
    connection.close();
}

fn providerRequestFakeCodexScriptAlloc(
    allocator: std.mem.Allocator,
    method: []const u8,
    evidence_path: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n" ++
            "set -eu\n" ++
            "evidence='{s}'\n" ++
            "while IFS= read -r line; do\n" ++
            "  case \"$line\" in\n" ++
            "    *'\"method\":\"initialize\"'*) " ++
            "printf '%s\\n' '{{\"id\":-1,\"result\":{{}}}}'; continue ;;\n" ++
            "    *'\"method\":\"initialized\"'*) continue ;;\n" ++
            "    *'\"method\":\"test/provider\"'*)\n" ++
            "      printf '%s\\n' " ++
            "'{{\"id\":\"provider-1\",\"method\":\"{s}\"," ++
            "\"params\":{{\"token\":\"SECRET_SENTINEL\"}}}}'\n" ++
            "      IFS= read -r reply || exit 8\n" ++
            "      printf '%s\\n' \"$reply\" > \"$evidence.tmp\"\n" ++
            "      mv \"$evidence.tmp\" \"$evidence\"\n" ++
            "      continue ;;\n" ++
            "  esac\n" ++
            "done\n",
        .{ evidence_path, method },
    );
}

fn runProviderRequestUnavailableCase(method: []const u8) !void {
    if (@import("builtin").os.tag == .windows or
        @import("builtin").os.tag == .wasi)
    {
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "provider-codex" });
    defer allocator.free(executable);
    const evidence_path = try std.fs.path.join(allocator, &.{ root, "reply.json" });
    defer allocator.free(evidence_path);
    const script = try providerRequestFakeCodexScriptAlloc(
        allocator,
        method,
        evidence_path,
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "provider-codex", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        executable,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );

    var client = try proxy.Client.start(allocator, .{
        .cwd = root,
        .io = io,
        .codex_path = executable,
    });
    defer {
        client.close();
        client.deinit();
    }
    if (std.mem.eql(u8, method, "account/chatgptAuthTokens/refresh")) {
        try std.testing.expectError(
            error.ChatGptAuthTokensRefreshProviderUnavailable,
            client.requestJson("test/provider", "{}"),
        );
    } else {
        try std.testing.expectError(
            error.AttestationProviderUnavailable,
            client.requestJson("test/provider", "{}"),
        );
    }
    const evidence = try readPublishedProviderEvidenceAlloc(allocator, io, tmp.dir);
    defer allocator.free(evidence);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "\"code\":-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence, "SECRET_SENTINEL") == null);
}

fn readPublishedProviderEvidenceAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
) ![]u8 {
    for (0..100) |_| {
        return dir.readFileAlloc(
            io,
            "reply.json",
            allocator,
            .limited(4 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.sleep(io, .fromMilliseconds(5), .awake);
                continue;
            },
            else => return err,
        };
    }
    return error.ProviderEvidenceNotPublished;
}

test "provider server requests reply once and preserve exact route errors" {
    try runProviderRequestUnavailableCase("account/chatgptAuthTokens/refresh");
    try runProviderRequestUnavailableCase("attestation/generate");
}
