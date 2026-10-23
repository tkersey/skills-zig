const std = @import("std");

pub const discovery_url = "https://auth.openai.com/.well-known/openid-configuration";
pub const token_url = "https://auth.openai.com/api/accounts/oauth/token";
pub const models_url = "https://api.openai.com/v1/models";
pub const response_bytes_max = 1024 * 1024;
pub const request_bytes_max = 128 * 1024;
pub const request_timeout_ms = 30_000;
const idle_connections_max = 2;

pub const Request = union(enum) {
    discovery,
    keys: []const u8,
    token: []const u8,
    revoke: struct { url: []const u8, form: []const u8 },
    models: []const u8,

    pub fn url(self: Request) []const u8 {
        return switch (self) {
            .discovery => discovery_url,
            .keys => |value| value,
            .token => token_url,
            .revoke => |value| value.url,
            .models => models_url,
        };
    }

    fn body(self: Request) ?[]const u8 {
        return switch (self) {
            .token => |value| value,
            .revoke => |value| value.form,
            else => null,
        };
    }

    pub fn validate(self: Request) !void {
        switch (self) {
            .keys => |value| try validateAuthUrl(value),
            .revoke => |value| try validateAuthUrl(value.url),
            .models => |value| {
                if (value.len == 0 or value.len > 32 * 1024) return error.InvalidAccessToken;
                for (value) |byte| if (byte <= 0x20 or byte >= 0x7f)
                    return error.InvalidAccessToken;
            },
            else => {},
        }
        if (self.body()) |value| {
            if (value.len == 0 or value.len > request_bytes_max) return error.RequestTooLarge;
        }
    }
};

pub fn validateAuthUrl(url: []const u8) !void {
    if (url.len > 2048 or !std.mem.startsWith(u8, url, "https://auth.openai.com/") or
        std.mem.indexOfAny(u8, url, "\\#\r\n\t ") != null) return error.InvalidAuthEndpoint;
}

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response) void {
        std.crypto.secureZero(u8, self.body);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Transport = struct {
    context: *anyopaque,
    request_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, Request) anyerror!Response,

    pub fn request(
        self: Transport,
        allocator: std.mem.Allocator,
        io: std.Io,
        value: Request,
    ) !Response {
        try value.validate();
        return self.request_fn(self.context, allocator, io, value);
    }
};

pub const Http = struct {
    session: ?*Session = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Http {
        const session = try allocator.create(Session);
        session.* = .{ .client = makeClient(allocator, io) };
        session.client.connection_pool.free_size = idle_connections_max;
        return .{ .session = session };
    }

    pub fn deinit(self: *Http) void {
        if (self.session) |session| {
            const allocator = session.client.allocator;
            session.client.deinit();
            allocator.destroy(session);
        }
        self.* = undefined;
    }

    pub fn transport(self: *Http) Transport {
        return .{ .context = self, .request_fn = request };
    }

    fn request(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        value: Request,
    ) !Response {
        const self: *Http = @ptrCast(@alignCast(context));
        return self.requestUri(
            allocator,
            io,
            value,
            try std.Uri.parse(value.url()),
            request_timeout_ms,
        );
    }

    fn requestUri(
        self: *Http,
        allocator: std.mem.Allocator,
        io: std.Io,
        value: Request,
        uri: std.Uri,
        timeout_ms: u32,
    ) !Response {
        std.debug.assert(timeout_ms > 0 and timeout_ms <= request_timeout_ms);
        var job = Job{
            .allocator = allocator,
            .io = io,
            .request = value,
            .uri = uri,
            .session = self.session,
        };
        defer if (job.response) |*response| response.deinit();
        var results: [2]Outcome = undefined;
        var select = std.Io.Select(Outcome).init(io, &results);
        defer select.cancelDiscard();
        try select.concurrent(.work, Job.run, .{&job});
        try select.concurrent(.timeout, waitTimeout, .{ io, timeout_ms });
        switch (try select.await()) {
            .work => |result| try result,
            .timeout => |result| {
                try result;
                return error.RequestTimedOut;
            },
        }
        select.cancelDiscard();
        const response = job.response orelse return error.MissingResponse;
        job.response = null;
        return response;
    }
};

const Outcome = union(enum) { work: anyerror!void, timeout: std.Io.Cancelable!void };

fn waitTimeout(io: std.Io, timeout_ms: u32) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(timeout_ms), .awake);
}

const Session = struct {
    mutex: std.Io.Mutex = .init,
    client: std.http.Client,

    fn run(self: *Session, job: *Job) !void {
        if (self.client.io.userdata != job.io.userdata or self.client.io.vtable != job.io.vtable)
            return error.HttpSessionIoMismatch;
        try self.mutex.lock(job.io);
        defer self.mutex.unlock(job.io);
        if (self.client.now != null) self.client.now = std.Io.Clock.real.now(job.io);
        if (job.request.body() != null) try self.discardIdle(job.io);
        job.exchange(&self.client, true) catch |err| {
            if (job.request.body() != null or !job.retry_idle_read) return err;
            try self.discardIdle(job.io);
            try job.exchange(&self.client, true);
        };
    }

    fn discardIdle(self: *Session, io: std.Io) !void {
        try self.client.connection_pool.resize(io, 0);
        self.client.connection_pool.free_size = idle_connections_max;
    }
};

fn makeClient(allocator: std.mem.Allocator, io: std.Io) std.http.Client {
    return .{ .allocator = allocator, .io = io, .read_buffer_size = 32 * 1024 };
}

const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
    uri: std.Uri,
    session: ?*Session,
    response: ?Response = null,
    retry_idle_read: bool = false,

    fn run(self: *Job) !void {
        if (self.session) |session| return session.run(self);
        var client = makeClient(self.allocator, self.io);
        defer client.deinit();
        try self.exchange(&client, false);
    }

    fn exchange(self: *Job, client: *std.http.Client, keep_alive: bool) !void {
        self.retry_idle_read = false;
        const idle = IdleConnections.capture(client);
        const bearer = switch (self.request) {
            .models => |token| try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token}),
            else => null,
        };
        defer if (bearer) |value| {
            std.crypto.secureZero(u8, value);
            self.allocator.free(value);
        };
        const payload = self.request.body();
        var options = requestOptions(payload, bearer);
        options.keep_alive = keep_alive;
        var request = try client.request(
            if (payload != null) .POST else .GET,
            self.uri,
            options,
        );
        var complete = false;
        defer finishRequest(&request, complete);
        var response = receiveResponseHead(&request, payload) catch |err| {
            self.retry_idle_read = idle.contains(request.connection) and
                idleConnectionClosed(&request, err);
            return err;
        };
        const status: u16 = @backingInt(response.head.status);
        if (status >= 300 and status < 400) return error.RedirectNotAllowed;
        var transfer: [4096]u8 = undefined;
        const body = try response.reader(&transfer).allocRemaining(
            self.allocator,
            .limited(response_bytes_max),
        );
        self.response = .{ .allocator = self.allocator, .status = status, .body = body };
        complete = true;
    }
};

fn receiveResponseHead(
    request: *std.http.Client.Request,
    payload: ?[]const u8,
) !std.http.Client.Response {
    if (payload) |value| {
        try sendRequestBody(request, value);
    } else try request.sendBodiless();
    return request.receiveHead(&.{});
}

const IdleConnections = struct {
    connections: [idle_connections_max]?*std.http.Client.Connection = @splat(null),

    fn capture(client: *std.http.Client) IdleConnections {
        var result: IdleConnections = .{};
        var next = client.connection_pool.free.first;
        for (&result.connections) |*connection| {
            const node = next orelse break;
            connection.* = @alignCast(@fieldParentPtr("pool_node", node));
            next = node.next;
        }
        std.debug.assert(next == null);
        return result;
    }

    fn contains(self: IdleConnections, connection: ?*std.http.Client.Connection) bool {
        const actual = connection orelse return false;
        for (self.connections) |previous| if (previous == actual) return true;
        return false;
    }
};

fn idleConnectionClosed(request: *std.http.Client.Request, err: anyerror) bool {
    if (err == error.HttpConnectionClosing) return true;
    const connection = request.connection orelse return false;
    if (connection.reader().buffered().len != 0) return false;
    const cause: anyerror = if (err == error.ReadFailed)
        connection.getReadError() orelse return false
    else if (err == error.WriteFailed)
        connection.stream_writer.err orelse return false
    else
        return false;
    return cause == error.ConnectionResetByPeer or cause == error.BrokenPipe or
        cause == error.SocketNotConnected;
}

fn finishRequest(request: *std.http.Client.Request, complete: bool) void {
    if (request.connection) |connection| {
        connection.closing = connection.closing or !complete;
        const reader = connection.reader();
        const writer = connection.writer();
        if (connection.closing) {
            std.crypto.secureZero(u8, reader.buffer);
            std.crypto.secureZero(u8, writer.buffer);
        } else {
            std.crypto.secureZero(u8, reader.buffer[0..reader.seek]);
            std.crypto.secureZero(u8, reader.buffer[reader.end..]);
            std.crypto.secureZero(u8, writer.buffer[writer.end..]);
        }
    }
    request.deinit();
}

fn requestOptions(payload: ?[]const u8, bearer: ?[]const u8) std.http.Client.RequestOptions {
    return .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .authorization = if (bearer) |value| .{ .override = value } else .omit,
            .content_type = if (payload != null)
                .{ .override = "application/x-www-form-urlencoded" }
            else
                .omit,
            .accept_encoding = .omit,
        },
    };
}

fn sendRequestBody(request: *std.http.Client.Request, body: []const u8) !void {
    request.transfer_encoding = .{ .content_length = body.len };
    var writer = try request.sendBodyUnflushed(&.{});
    try writer.writer.writeAll(body);
    try writer.end();
    try request.connection.?.flush();
}

pub const Discovery = struct {
    parsed: std.json.Parsed(Value),

    const Value = struct {
        issuer: []const u8,
        jwks_uri: []const u8,
        revocation_endpoint: []const u8,
    };

    pub fn parse(allocator: std.mem.Allocator, body: []const u8) !Discovery {
        if (body.len > response_bytes_max) return error.ResponseTooLarge;
        const parsed = try std.json.parseFromSlice(Value, allocator, body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        errdefer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.issuer, "https://auth.openai.com"))
            return error.InvalidIssuer;
        try validateAuthUrl(parsed.value.jwks_uri);
        try validateAuthUrl(parsed.value.revocation_endpoint);
        return .{ .parsed = parsed };
    }

    pub fn deinit(self: *Discovery) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

test "discovery cannot redirect credential or signing-key authority" {
    const allocator = std.testing.allocator;
    var valid = try Discovery.parse(allocator,
        \\{"issuer":"https://auth.openai.com","jwks_uri":"https://auth.openai.com/keys","revocation_endpoint":"https://auth.openai.com/revoke"}
    );
    defer valid.deinit();
    try std.testing.expectError(error.InvalidAuthEndpoint, Discovery.parse(allocator,
        \\{"issuer":"https://auth.openai.com","jwks_uri":"https://evil.example/keys","revocation_endpoint":"https://auth.openai.com/revoke"}
    ));
    for ([_][]const u8{
        "http://auth.openai.com/keys",
        "https://auth.openai.com.evil/keys",
        "https://auth.openai.com@evil/keys",
        "https://auth.openai.com/keys#fragment",
    }) |url| try std.testing.expectError(error.InvalidAuthEndpoint, validateAuthUrl(url));
}

test "transport validates bearer bytes before invoking an implementation" {
    try (Request{ .models = "synthetic-access" }).validate();
    try std.testing.expectError(error.InvalidAccessToken, (Request{ .models = "" }).validate());
    try std.testing.expectError(
        error.InvalidAccessToken,
        (Request{ .models = "token\r\nInjected: yes" }).validate(),
    );
}

const body_test_bytes = blk: {
    @setEvalBranchQuota(100000);
    var bytes: [8192]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = '!' + @as(u8, @intCast((index * 37 + index / 97) % 94));
    }
    break :blk bytes;
};

const BodyTestConnection = struct {
    connection: std.http.Client.Connection,
    wire: std.Io.Writer.Allocating,
    flushes: usize = 0,
    fail_write: bool = false,
    fail_final_flush: bool = false,

    fn init(client: *std.http.Client, buffer: []u8) BodyTestConnection {
        return .{
            .connection = .{
                .client = client,
                .stream_writer = .{
                    .io = client.io,
                    .stream = undefined,
                    .interface = .{
                        .buffer = buffer,
                        .vtable = &.{ .drain = drain, .flush = flush },
                    },
                },
                .stream_reader = undefined,
                .pool_node = .{},
                .port = 80,
                .host_len = 0,
                .proxied = false,
                .closing = false,
                .protocol = .plain,
            },
            .wire = .init(std.testing.allocator),
        };
    }

    fn fromWriter(writer: *std.Io.Writer) *BodyTestConnection {
        const stream: *std.Io.net.Stream.Writer = @fieldParentPtr("interface", writer);
        const connection: *std.http.Client.Connection = @fieldParentPtr("stream_writer", stream);
        return @fieldParentPtr("connection", connection);
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        const self = fromWriter(writer);
        if (self.fail_write and self.wire.written().len >= 256) return error.WriteFailed;
        if (writer.end != 0) {
            const count = @min(writer.end, 7);
            try self.wire.writer.writeAll(writer.buffered()[0..count]);
            return writer.consume(count);
        }
        for (data, 0..) |bytes, index| {
            if (index == data.len - 1 and splat == 0) break;
            if (bytes.len == 0) continue;
            const count = @min(bytes.len, 7);
            try self.wire.writer.writeAll(bytes[0..count]);
            return count;
        }
        return 0;
    }

    fn flush(writer: *std.Io.Writer) !void {
        const self = fromWriter(writer);
        self.flushes += 1;
        if (self.fail_final_flush and self.flushes == 2) return error.WriteFailed;
        try std.Io.Writer.defaultFlush(writer);
    }

    fn request(self: *BodyTestConnection) !std.http.Client.Request {
        const uri = try std.Uri.parse("http://example.invalid/token");
        return self.connection.client.request(.POST, uri, .{
            .connection = &self.connection,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        });
    }
};

test "request serialization emits only the explicit bearer authorization" {
    for ([_]?[]const u8{ "Bearer synthetic-access", null }) |bearer| {
        var client = std.http.Client{ .allocator = std.testing.allocator, .io = std.testing.io };
        defer client.deinit();
        var buffer: [512]u8 = undefined;
        var sink = BodyTestConnection.init(&client, &buffer);
        defer sink.wire.deinit();
        var options = requestOptions(null, bearer);
        options.connection = &sink.connection;
        var request = try client.request(.GET, try std.Uri.parse(models_url), options);
        try std.testing.expectEqual(.unhandled, request.redirect_behavior);
        try request.sendBodiless();
        const wire = sink.wire.written();
        try std.testing.expect(std.mem.startsWith(u8, wire, "GET /v1/models HTTP/1.1\r\n"));
        try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\n"));
        try std.testing.expectEqual(
            @as(usize, if (bearer != null) 1 else 0),
            std.mem.count(u8, wire, "authorization:"),
        );
        if (bearer != null) try std.testing.expect(
            std.mem.indexOf(u8, wire, "\r\nauthorization: Bearer synthetic-access\r\n") != null,
        );
    }
}

test "request body streaming preserves readonly bytes across short writes and flushes" {
    var client = std.http.Client{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var buffer: [512]u8 = undefined;
    var sink = BodyTestConnection.init(&client, &buffer);
    defer sink.wire.deinit();
    var request = try sink.request();
    const expected = try std.testing.allocator.dupe(u8, &body_test_bytes);
    defer std.testing.allocator.free(expected);
    try sendRequestBody(&request, &body_test_bytes);
    try std.testing.expectEqualSlices(u8, expected, &body_test_bytes);
    const wire = sink.wire.written();
    const body_start = (std.mem.indexOf(u8, wire, "\r\n\r\n") orelse
        return error.MissingHeaderTerminator) + 4;
    try std.testing.expect(
        std.mem.indexOf(u8, wire[0..body_start], "content-length: 8192\r\n") != null,
    );
    try std.testing.expectEqualSlices(u8, expected, wire[body_start..]);
    try std.testing.expectEqual(@as(usize, 2), sink.flushes);
}

test "request body streaming propagates short write and final flush failures" {
    for ([_]bool{ true, false }) |fail_write| {
        var client = std.http.Client{ .allocator = std.testing.allocator, .io = std.testing.io };
        defer client.deinit();
        var buffer: [512]u8 = undefined;
        var sink = BodyTestConnection.init(&client, &buffer);
        defer sink.wire.deinit();
        sink.fail_write = fail_write;
        sink.fail_final_flush = !fail_write;
        var request = try sink.request();
        try std.testing.expectError(error.WriteFailed, sendRequestBody(&request, &body_test_bytes));
        try std.testing.expectEqual(@as(usize, if (fail_write) 0 else 2), sink.flushes);
    }
}

const HttpTestReply = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "synthetic-secret",
    authorization: ?[]const u8 = null,
    incomplete: bool = false,
    close_after: bool = false,
    drop_response: bool = false,
};

const HttpTestServer = struct {
    server: std.Io.net.Server,
    replies: []const HttpTestReply,
    connections: usize = 0,
    requests: usize = 0,
    token_posts: usize = 0,

    fn open(replies: []const HttpTestReply) !HttpTestServer {
        std.debug.assert(replies.len > 0 and replies.len <= 16);
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        return .{
            .server = try address.listen(std.testing.io, .{
                .mode = .stream,
                .protocol = .tcp,
                .kernel_backlog = 16,
                .reuse_address = false,
            }),
            .replies = replies,
        };
    }

    fn uri(self: *HttpTestServer, buffer: []u8) !std.Uri {
        const url = try std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/test", .{
            self.server.socket.address.getPort(),
        });
        return std.Uri.parse(url);
    }

    fn run(self: *HttpTestServer) !void {
        for (0..self.replies.len) |_| {
            if (self.requests == self.replies.len) return;
            const stream = try self.server.accept(std.testing.io);
            defer stream.close(std.testing.io);
            self.connections += 1;
            try self.serve(stream);
        }
    }

    fn serve(self: *HttpTestServer, stream: std.Io.net.Stream) !void {
        var input: [4096]u8 = undefined;
        var output: [4096]u8 = undefined;
        var reader = stream.reader(std.testing.io, &input);
        var writer = stream.writer(std.testing.io, &output);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        for (0..self.replies.len) |_| {
            if (self.requests == self.replies.len) return;
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => return err,
            };
            const reply = self.replies[self.requests];
            try expectAuthorization(&request, reply.authorization);
            self.requests += 1;
            if (request.head.method == .POST) self.token_posts += 1;
            if (reply.drop_response) return;
            if (reply.incomplete) return incomplete(&writer.interface, reply.status);
            try request.respond(reply.body, .{ .status = reply.status });
            if (!request.head.keep_alive or reply.close_after) return;
        }
    }

    fn incomplete(writer: *std.Io.Writer, status: std.http.Status) !void {
        try writer.print("HTTP/1.1 {d} Test\r\nContent-Length: 1024\r\n\r\n", .{
            @backingInt(status),
        });
        try writer.flush();
        try std.testing.io.sleep(.fromSeconds(10), .awake);
    }

    fn expectAuthorization(request: *std.http.Server.Request, expected: ?[]const u8) !void {
        var found: ?[]const u8 = null;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                try std.testing.expect(found == null);
                found = header.value;
            }
        }
        if (expected) |value| {
            try std.testing.expectEqualStrings(
                value,
                found orelse return error.MissingAuthorization,
            );
        } else try std.testing.expect(found == null);
    }
};

fn expectPooledBuffersErased(http: *Http) !void {
    const session = http.session orelse return;
    var next = session.client.connection_pool.free.first;
    var remaining: usize = idle_connections_max;
    while (next) |node| {
        try std.testing.expect(remaining != 0);
        remaining -= 1;
        const connection: *std.http.Client.Connection =
            @alignCast(@fieldParentPtr("pool_node", node));
        for ([_][]const u8{ connection.reader().buffer, connection.writer().buffer }) |bytes| {
            try std.testing.expect(std.mem.indexOf(u8, bytes, "synthetic-secret") == null);
        }
        next = node.next;
    }
}

fn exerciseHttpSequence(reuse: bool) !usize {
    const replies = [_]HttpTestReply{
        .{}, .{}, .{}, .{ .authorization = "Bearer synthetic-secret" }, .{},
    };
    var fixture = try HttpTestServer.open(&replies);
    defer fixture.server.deinit(std.testing.io);
    var worker = try std.testing.io.concurrent(HttpTestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    var http = if (reuse) try Http.init(std.testing.allocator, std.testing.io) else Http{};
    defer http.deinit();
    const requests = [_]Request{
        .{ .token = "synthetic-secret" },
        .discovery,
        .{ .keys = "https://auth.openai.com/keys" },
        .{ .models = "synthetic-secret" },
        .discovery,
    };
    var uri_buffer: [64]u8 = undefined;
    const uri = try fixture.uri(&uri_buffer);
    for (requests) |request_value| {
        var response = try http.requestUri(
            std.testing.allocator,
            std.testing.io,
            request_value,
            uri,
            2_000,
        );
        defer response.deinit();
        try std.testing.expectEqualStrings("synthetic-secret", response.body);
        try expectPooledBuffersErased(&http);
    }
    try worker.await(std.testing.io);
    return fixture.connections;
}

test "owned HTTP sessions reuse connections without retaining request secrets" {
    try std.testing.expectEqual(@as(usize, 5), try exerciseHttpSequence(false));
    try std.testing.expectEqual(@as(usize, 1), try exerciseHttpSequence(true));
}

test "HTTP sessions close incomplete redirects without waiting for their body" {
    var fixture = try HttpTestServer.open(&.{.{ .status = .found, .incomplete = true }});
    defer fixture.server.deinit(std.testing.io);
    var worker = try std.testing.io.concurrent(HttpTestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    var http = try Http.init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    var uri_buffer: [64]u8 = undefined;
    try std.testing.expectError(error.RedirectNotAllowed, http.requestUri(
        std.testing.allocator,
        std.testing.io,
        .discovery,
        try fixture.uri(&uri_buffer),
        200,
    ));
    try std.testing.expectEqual(@as(usize, 0), http.session.?.client.connection_pool.free_len);
}

test "HTTP session timeout closes incomplete responses and releases its lock" {
    var fixture = try HttpTestServer.open(&.{.{ .incomplete = true }});
    defer fixture.server.deinit(std.testing.io);
    var worker = try std.testing.io.concurrent(HttpTestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    var http = try Http.init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    var uri_buffer: [64]u8 = undefined;
    try std.testing.expectError(error.RequestTimedOut, http.requestUri(
        std.testing.allocator,
        std.testing.io,
        .discovery,
        try fixture.uri(&uri_buffer),
        50,
    ));
    try std.testing.expectEqual(@as(usize, 0), http.session.?.client.connection_pool.free_len);
    try http.session.?.mutex.lock(std.testing.io);
    http.session.?.mutex.unlock(std.testing.io);
}

test "HTTP session admission retains caller I/O and bounded lock waiting" {
    var http = try Http.init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    var vtable = std.testing.io.vtable.*;
    const other_io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.HttpSessionIoMismatch, http.transport().request(
        std.testing.allocator,
        other_io,
        .discovery,
    ));
    try http.session.?.mutex.lock(std.testing.io);
    defer http.session.?.mutex.unlock(std.testing.io);
    try std.testing.expectError(error.RequestTimedOut, http.requestUri(
        std.testing.allocator,
        std.testing.io,
        .discovery,
        try std.Uri.parse(discovery_url),
        20,
    ));
}

test "HTTP session allocation failure has no hidden ownership" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Http.init(failing.allocator(), std.testing.io));
    var stateless: Http = .{};
    stateless.deinit();
}

test "HTTP token requests use fresh connections after silent idle closure without replay" {
    try expectClosedIdleRecovery(.{ .token = "synthetic-secret" }, 1);
    try expectClosedIdleRecovery(.{ .revoke = .{
        .url = "https://auth.openai.com/revoke",
        .form = "synthetic-secret",
    } }, 1);
}

test "HTTP read requests recover a silently closed idle connection once" {
    try expectClosedIdleRecovery(.discovery, 0);
    try expectClosedIdleRecovery(.{ .keys = "https://auth.openai.com/keys" }, 0);
}

test "HTTP token requests are never replayed after an uncertain response" {
    var fixture = try HttpTestServer.open(&.{.{ .drop_response = true }});
    defer fixture.server.deinit(std.testing.io);
    var worker = try std.testing.io.concurrent(HttpTestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    var http = try Http.init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    var uri_buffer: [64]u8 = undefined;
    try std.testing.expectError(error.HttpConnectionClosing, http.requestUri(
        std.testing.allocator,
        std.testing.io,
        .{ .token = "synthetic-secret" },
        try fixture.uri(&uri_buffer),
        200,
    ));
    try worker.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), fixture.token_posts);
    try std.testing.expectEqual(@as(usize, 1), fixture.connections);
}

test "HTTP idle recovery excludes partial response headers on connection reset" {
    var client = std.http.Client{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var output: [512]u8 = undefined;
    const partial = "HTTP/1.1 200 ";
    var input: [512]u8 = undefined;
    @memcpy(input[0..partial.len], partial);
    var sink = BodyTestConnection.init(&client, &output);
    defer sink.wire.deinit();
    sink.connection.stream_reader = .init(undefined, std.testing.io, &input);
    sink.connection.stream_reader.err = error.ConnectionResetByPeer;
    sink.connection.stream_reader.interface.end = partial.len;
    sink.connection.stream_reader.interface.vtable = &.{ .stream = struct {
        fn reset(
            _: *std.Io.Reader,
            _: *std.Io.Writer,
            _: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            return error.ReadFailed;
        }
    }.reset };
    var request = try client.request(.GET, try std.Uri.parse(discovery_url), .{
        .connection = &sink.connection,
        .redirect_behavior = .unhandled,
    });
    try std.testing.expectError(error.ReadFailed, receiveResponseHead(&request, null));
    try std.testing.expect(!idleConnectionClosed(&request, error.ReadFailed));
    sink.connection.stream_reader.interface.end = 0;
    try std.testing.expect(idleConnectionClosed(&request, error.ReadFailed));
}

fn expectClosedIdleRecovery(next_request: Request, expected_posts: usize) !void {
    var fixture = try HttpTestServer.open(&.{ .{ .close_after = true }, .{} });
    defer fixture.server.deinit(std.testing.io);
    var worker = try std.testing.io.concurrent(HttpTestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    var http = try Http.init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    var uri_buffer: [64]u8 = undefined;
    const uri = try fixture.uri(&uri_buffer);
    for ([_]Request{ .discovery, next_request }) |value| {
        var response = try http.requestUri(
            std.testing.allocator,
            std.testing.io,
            value,
            uri,
            2_000,
        );
        defer response.deinit();
        try std.testing.expectEqualStrings("synthetic-secret", response.body);
    }
    try worker.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), fixture.connections);
    try std.testing.expectEqual(@as(usize, 2), fixture.requests);
    try std.testing.expectEqual(expected_posts, fixture.token_posts);
}

test "HTTP session connections retain a stable client when its handle moves" {
    var fixture = try HttpTestServer.open(&.{ .{}, .{} });
    defer fixture.server.deinit(std.testing.io);
    var worker = try std.testing.io.concurrent(HttpTestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    var original = try Http.init(std.testing.allocator, std.testing.io);
    errdefer original.deinit();
    var uri_buffer: [64]u8 = undefined;
    const uri = try fixture.uri(&uri_buffer);
    var first = try original.requestUri(
        std.testing.allocator,
        std.testing.io,
        .discovery,
        uri,
        2_000,
    );
    first.deinit();
    var moved = original;
    original = .{};
    defer moved.deinit();
    var second = try moved.requestUri(
        std.testing.allocator,
        std.testing.io,
        .discovery,
        uri,
        2_000,
    );
    defer second.deinit();
    try std.testing.expectEqualStrings("synthetic-secret", second.body);
    try worker.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), fixture.connections);
}

test "HTTP sessions retain response limits and close rejected response connections" {
    const body = try std.testing.allocator.alloc(u8, response_bytes_max + 1);
    defer std.testing.allocator.free(body);
    @memset(body, 'x');
    for ([_]usize{ response_bytes_max, response_bytes_max + 1 }) |size| {
        var fixture = try HttpTestServer.open(&.{.{ .body = body[0..size] }});
        defer fixture.server.deinit(std.testing.io);
        var worker = try std.testing.io.concurrent(HttpTestServer.run, .{&fixture});
        defer _ = worker.cancel(std.testing.io) catch null;
        var http = try Http.init(std.testing.allocator, std.testing.io);
        defer http.deinit();
        var uri_buffer: [64]u8 = undefined;
        const response = http.requestUri(
            std.testing.allocator,
            std.testing.io,
            .discovery,
            try fixture.uri(&uri_buffer),
            2_000,
        );
        if (size == response_bytes_max) {
            var accepted = try response;
            defer accepted.deinit();
            try std.testing.expectEqual(size, accepted.body.len);
        } else {
            try std.testing.expectError(error.StreamTooLong, response);
            try std.testing.expectEqual(
                @as(usize, 0),
                http.session.?.client.connection_pool.free_len,
            );
        }
        try worker.await(std.testing.io);
    }
}
