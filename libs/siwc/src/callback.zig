const std = @import("std");
const oauth = @import("oauth.zig");

const header_bytes_max = 16 * 1024;
const headers_count_max = 64;
const connections_count_max = 16;
const wait_timeout_ms: i64 = 10 * 60 * 1000;
const client_timeout_ms: i64 = 5 * 1000;
const callback_path = "/auth/callback";

const Limits = struct {
    wait_ms: i64 = wait_timeout_ms,
    client_ms: i64 = client_timeout_ms,
};

/// One pending authorization owns one loopback listener and one cancellation scope.
pub const Listener = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    server: std.Io.net.Server,
    redirect_uri: []u8,

    pub fn open(io: std.Io, allocator: std.mem.Allocator) !Listener {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try address.listen(io, .{
            .mode = .stream,
            .protocol = .tcp,
            .kernel_backlog = connections_count_max,
            .reuse_address = false,
        });
        errdefer server.deinit(io);
        const port = server.socket.address.getPort();
        std.debug.assert(port != 0);
        return .{
            .io = io,
            .allocator = allocator,
            .server = server,
            .redirect_uri = try allocator.print("http://127.0.0.1:{d}" ++ callback_path, .{port}),
        };
    }

    pub fn deinit(self: *Listener) void {
        self.server.deinit(self.io);
        self.allocator.free(self.redirect_uri);
        self.* = undefined;
    }

    pub fn wait(
        self: *Listener,
        expected_state: []const u8,
        existing_client_id: ?[]const u8,
    ) !oauth.Callback {
        return self.waitWithLimits(expected_state, existing_client_id, .{});
    }

    fn waitWithLimits(
        self: *Listener,
        expected_state: []const u8,
        existing_client_id: ?[]const u8,
        limits: Limits,
    ) !oauth.Callback {
        std.debug.assert(limits.wait_ms > 0 and limits.wait_ms <= wait_timeout_ms);
        std.debug.assert(limits.client_ms > 0 and limits.client_ms <= client_timeout_ms);
        var job = Job{
            .listener = self,
            .expected_state = expected_state,
            .existing_client_id = existing_client_id,
            .client_ms = limits.client_ms,
        };
        defer if (job.callback) |*value| value.deinit();
        var results: [2]Outcome = undefined;
        var select = std.Io.Select(Outcome).init(self.io, &results);
        // Join before reading or releasing the worker-owned callback, including timeout races.
        defer select.cancelDiscard();
        const deadline = deadlineAfter(self.io, limits.wait_ms);
        try select.concurrent(.work, Job.run, .{&job});
        try select.concurrent(.timeout, std.Io.Clock.Timestamp.wait, .{ deadline, self.io });
        switch (try select.await()) {
            .work => |result| try result,
            .timeout => |result| {
                try result;
                return error.CallbackTimedOut;
            },
        }
        select.cancelDiscard();
        const result = job.callback orelse return error.MissingCallback;
        job.callback = null;
        return result;
    }

    fn host(self: *const Listener) []const u8 {
        return self.redirect_uri["http://".len .. self.redirect_uri.len - callback_path.len];
    }
};

const Outcome = union(enum) { work: anyerror!void, timeout: std.Io.Cancelable!void };

const Job = struct {
    listener: *Listener,
    expected_state: []const u8,
    existing_client_id: ?[]const u8,
    client_ms: i64,
    callback: ?oauth.Callback = null,

    fn run(self: *Job) !void {
        const io = self.listener.io;
        for (0..connections_count_max) |_| {
            const stream = self.listener.server.accept(io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return err,
            };
            defer stream.close(io);
            try self.handle(stream, deadlineAfter(io, self.client_ms));
            if (self.callback != null) return;
        }
        return error.CallbackConnectionLimit;
    }

    fn handle(self: *Job, stream: std.Io.net.Stream, deadline: std.Io.Clock.Timestamp) !void {
        const io = self.listener.io;
        var buffer: [header_bytes_max]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        const request = readHeaders(io, stream, &buffer, deadline) catch |err| switch (err) {
            error.Canceled, error.ConcurrencyUnavailable => return err,
            else => {
                _ = try reply(io, stream, .invalid, deadline);
                return;
            },
        };
        const query = requestQuery(request, self.listener.host()) catch {
            _ = try reply(io, stream, .invalid, deadline);
            return;
        };
        self.callback = oauth.parseCallback(
            self.listener.allocator,
            query,
            self.expected_state,
            self.existing_client_id,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.AccessDenied => {
                _ = try reply(io, stream, .received, deadline);
                return err;
            },
            else => {
                _ = try reply(io, stream, .invalid, deadline);
                return;
            },
        };
        _ = try reply(io, stream, .received, deadline);
    }
};

fn deadlineAfter(io: std.Io, milliseconds: i64) std.Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromMilliseconds(milliseconds), .clock = .boot });
}

fn boundedOperation(
    io: std.Io,
    operation: std.Io.Operation,
    deadline: std.Io.Clock.Timestamp,
) !std.Io.Operation.Result {
    var storage: [1]std.Io.Operation.Storage = undefined;
    var batch: std.Io.Batch = .init(&storage);
    defer batch.cancel(io);
    batch.addAt(0, operation);
    try batch.awaitConcurrent(io, .{ .deadline = deadline });
    const completion = batch.next().?;
    std.debug.assert(completion.index == 0);
    return completion.result;
}

fn readBytes(
    io: std.Io,
    stream: std.Io.net.Stream,
    buffer: []u8,
    deadline: std.Io.Clock.Timestamp,
) !usize {
    std.debug.assert(buffer.len > 0);
    var buffers: [1][]u8 = .{buffer};
    const result = try (try boundedOperation(io, .{ .net_read = .{
        .socket_handle = stream.socket.handle,
        .data = &buffers,
    } }, deadline)).net_read;
    return result.data_len;
}

fn readHeaders(
    io: std.Io,
    stream: std.Io.net.Stream,
    buffer: *[header_bytes_max]u8,
    deadline: std.Io.Clock.Timestamp,
) ![]const u8 {
    var used: usize = 0;
    while (used < buffer.len) {
        const count = try readBytes(io, stream, buffer[used..], deadline);
        if (count == 0) return error.EndOfStream;
        used += count;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n") != null) return buffer[0..used];
    }
    return error.HeaderTooLarge;
}

fn writeBytes(
    io: std.Io,
    stream: std.Io.net.Stream,
    bytes: []const u8,
    deadline: std.Io.Clock.Timestamp,
) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const parts: [1][]const u8 = .{bytes[offset..]};
        const count = try (try boundedOperation(io, .{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = &parts,
        } }, deadline)).net_write;
        if (count == 0) return error.EndOfStream;
        std.debug.assert(count <= bytes.len - offset);
        offset += count;
    }
}

const Reply = enum { received, invalid };
const Delivery = enum { delivered, unavailable };

fn reply(
    io: std.Io,
    stream: std.Io.net.Stream,
    kind: Reply,
    deadline: std.Io.Clock.Timestamp,
) std.Io.Cancelable!Delivery {
    const response = switch (kind) {
        .received => responseBytes(
            "200 OK",
            "Sign-in response received. You may close this window.\n",
        ),
        .invalid => responseBytes("400 Bad Request", "Invalid sign-in request.\n"),
    };
    writeBytes(io, stream, response, deadline) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        // Browser display is informational; a disconnected peer cannot revoke a valid callback.
        else => return .unavailable,
    };
    return .delivered;
}

fn responseBytes(comptime status: []const u8, comptime body: []const u8) []const u8 {
    return "HTTP/1.1 " ++ status ++ "\r\n" ++
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "Cache-Control: no-store\r\n" ++
        "Referrer-Policy: no-referrer\r\n" ++
        "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n" ++
        "X-Content-Type-Options: nosniff\r\n" ++
        "Connection: close\r\nContent-Length: " ++ std.fmt.comptimePrint("{d}", .{body.len}) ++
        "\r\n\r\n" ++ body;
}

fn requestQuery(request: []const u8, expected_host: []const u8) ![]const u8 {
    if (request.len > header_bytes_max) return error.HeaderTooLarge;
    const end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return error.InvalidRequest;
    if (end + 4 != request.len) return error.UnexpectedBody;
    var lines = std.mem.splitSequence(u8, request[0..end], "\r\n");
    const query = try requestTarget(lines.next() orelse return error.InvalidRequest);
    var names: [headers_count_max][]const u8 = undefined;
    var names_count: usize = 0;
    var host_seen = false;
    while (lines.next()) |line| {
        if (names_count == names.len) return error.TooManyHeaders;
        const header = try parseHeader(line);
        for (names[0..names_count]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous, header.name)) return error.DuplicateHeader;
        }
        names[names_count] = header.name;
        names_count += 1;
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            if (!std.mem.eql(u8, header.value, expected_host)) return error.InvalidHost;
            host_seen = true;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(header.name, "upgrade")) return error.UnexpectedBody;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length") and
            !std.mem.eql(u8, header.value, "0")) return error.UnexpectedBody;
    }
    if (!host_seen) return error.MissingHost;
    return query;
}

fn requestTarget(line: []const u8) ![]const u8 {
    const prefix = "GET " ++ callback_path ++ "?";
    const suffix = " HTTP/1.1";
    if (!std.mem.startsWith(u8, line, prefix) or !std.mem.endsWith(u8, line, suffix))
        return error.InvalidTarget;
    if (line.len <= prefix.len + suffix.len) return error.InvalidTarget;
    const query = line[prefix.len .. line.len - suffix.len];
    for (query) |byte| {
        if (byte < 0x21 or byte > 0x7e or byte == '#') return error.InvalidTarget;
    }
    return query;
}

const Header = struct { name: []const u8, value: []const u8 };

fn parseHeader(line: []const u8) !Header {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
    if (colon == 0) return error.InvalidHeader;
    const name = line[0..colon];
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
            return error.InvalidHeader;
    }
    const raw_value = line[colon + 1 ..];
    for (raw_value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte > 0x7e) return error.InvalidHeader;
    }
    return .{ .name = name, .value = std.mem.trim(u8, raw_value, " \t") };
}

const TestServer = struct {
    listener: Listener,
    limits: Limits = .{ .wait_ms = 2_000, .client_ms = 200 },
    existing_client_id: ?[]const u8 = null,
    callback: ?oauth.Callback = null,

    fn open() !TestServer {
        return .{ .listener = try Listener.open(std.testing.io, std.testing.allocator) };
    }

    fn deinit(self: *TestServer) void {
        if (self.callback) |*value| value.deinit();
        self.listener.deinit();
    }

    fn run(self: *TestServer) !void {
        self.callback = try self.listener.waitWithLimits(
            "expected",
            self.existing_client_id,
            self.limits,
        );
    }
};

const TestRequest = struct {
    method: []const u8 = "GET",
    target: []const u8 = callback_path ++ "?code=secret-code&state=expected&client_id=oaiapp_one",
    host: ?[]const u8 = null,
    include_host: bool = true,
    headers: []const u8 = "",
    body: []const u8 = "",
};

fn testRequest(listener: *Listener, options: TestRequest) ![]u8 {
    const allocator = std.testing.allocator;
    const host = options.host orelse listener.host();
    const header = if (options.include_host) try allocator.print("Host: {s}\r\n", .{host}) else "";
    defer if (options.include_host) allocator.free(header);
    const request = try allocator.print("{s} {s} HTTP/1.1\r\n{s}{s}\r\n{s}", .{
        options.method, options.target, header, options.headers, options.body,
    });
    defer allocator.free(request);
    return testExchange(listener, request);
}

fn testExchange(listener: *Listener, request: []const u8) ![]u8 {
    const io = listener.io;
    const deadline = deadlineAfter(io, 2_000);
    const stream = try testConnect(listener, deadline);
    defer stream.close(io);
    try writeBytes(io, stream, request, deadline);
    var response: [1024]u8 = undefined;
    var used: usize = 0;
    while (used < response.len) {
        const count = try readBytes(io, stream, response[used..], deadline);
        if (count == 0) return std.testing.allocator.dupe(u8, response[0..used]);
        used += count;
    }
    return error.TestResponseTooLarge;
}

const TestConnection = struct {
    io: std.Io,
    address: std.Io.net.IpAddress,
    stream: ?std.Io.net.Stream = null,

    fn connect(self: *TestConnection) !void {
        self.stream = try self.address.connect(self.io, .{ .mode = .stream, .protocol = .tcp });
    }
};

fn testConnect(listener: *Listener, deadline: std.Io.Clock.Timestamp) !std.Io.net.Stream {
    const io = listener.io;
    var job = TestConnection{ .io = io, .address = listener.server.socket.address };
    defer if (job.stream) |stream| stream.close(io);
    var results: [2]Outcome = undefined;
    var select = std.Io.Select(Outcome).init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.work, TestConnection.connect, .{&job});
    try select.concurrent(.timeout, std.Io.Clock.Timestamp.wait, .{ deadline, io });
    switch (try select.await()) {
        .work => |result| try result,
        .timeout => |result| {
            try result;
            return error.TestConnectTimedOut;
        },
    }
    select.cancelDiscard();
    const stream = job.stream orelse return error.TestMissingStream;
    job.stream = null;
    return stream;
}

fn expectTestStatus(listener: *Listener, options: TestRequest, status: []const u8) !void {
    const response = try testRequest(listener, options);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.startsWith(u8, response, status));
    try std.testing.expect(std.mem.indexOf(u8, response, "secret-code") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "expected") == null);
}

test "loopback callback returns owned credentials and generic browser text" {
    var fixture = try TestServer.open();
    defer fixture.deinit();
    try std.testing.expectEqualSlices(
        u8,
        &.{ 127, 0, 0, 1 },
        &fixture.listener.server.socket.address.ip4.bytes,
    );
    try oauth.validateRedirect(fixture.listener.redirect_uri);
    var worker = try std.testing.io.concurrent(TestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    try expectTestStatus(&fixture.listener, .{}, "HTTP/1.1 200 OK\r\n");
    try worker.await(std.testing.io);
    const callback = fixture.callback orelse return error.TestMissingCallback;
    try std.testing.expectEqualStrings("secret-code", callback.code);
    try std.testing.expectEqualStrings("oaiapp_one", callback.client_id);
}

test "invalid local requests cannot replace the pending authorization" {
    var fixture = try TestServer.open();
    defer fixture.deinit();
    var worker = try std.testing.io.concurrent(TestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    const invalid = [_]TestRequest{
        .{ .target = callback_path ++ "?code=bad&state=wrong&client_id=oaiapp_one" },
        .{ .target = "/favicon.ico" },
        .{ .target = callback_path ++ "?code=bad&state=expected#fragment" },
        .{ .method = "POST" },
        .{ .host = "localhost:12345" },
        .{ .include_host = false },
        .{ .headers = "hOsT: 127.0.0.1:12345\r\n" },
        .{ .headers = "X-Test: one\r\nx-test: two\r\n" },
        .{ .headers = " Bad: folded\r\n" },
        .{ .headers = "X-Test: bad\x01value\r\n" },
        .{ .headers = "Transfer-Encoding: chunked\r\n" },
        .{ .headers = "Content-Length: 1\r\n", .body = "x" },
    };
    for (invalid) |request| {
        try expectTestStatus(&fixture.listener, request, "HTTP/1.1 400 Bad Request\r\n");
    }
    try expectTestStatus(
        &fixture.listener,
        .{ .headers = "Content-Length: 0\r\n" },
        "HTTP/1.1 200 OK\r\n",
    );
    try worker.await(std.testing.io);
    try std.testing.expectEqualStrings("secret-code", fixture.callback.?.code);
}

test "only an OAuth denial with the expected state ends the attempt" {
    var fixture = try TestServer.open();
    defer fixture.deinit();
    var worker = try std.testing.io.concurrent(TestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    try expectTestStatus(&fixture.listener, .{
        .target = callback_path ++ "?error=access_denied&state=wrong",
    }, "HTTP/1.1 400 Bad Request\r\n");
    try expectTestStatus(&fixture.listener, .{
        .target = callback_path ++ "?error=access_denied&state=expected",
    }, "HTTP/1.1 200 OK\r\n");
    try std.testing.expectError(error.AccessDenied, worker.await(std.testing.io));
    try std.testing.expect(fixture.callback == null);
}

test "callback timer cancels both idle acceptance and a stalled client" {
    var fixture = try TestServer.open();
    defer fixture.deinit();
    const limits: Limits = .{ .wait_ms = 20, .client_ms = 1_000 };
    try std.testing.expectError(
        error.CallbackTimedOut,
        fixture.listener.waitWithLimits("expected", null, limits),
    );
    const stream = try testConnect(&fixture.listener, deadlineAfter(std.testing.io, 1_000));
    defer stream.close(std.testing.io);
    try writeBytes(std.testing.io, stream, "GET /auth", deadlineAfter(std.testing.io, 1_000));
    try std.testing.expectError(
        error.CallbackTimedOut,
        fixture.listener.waitWithLimits("expected", null, limits),
    );
}

test "a stalled client cannot consume the entire authorization timeout" {
    var fixture = try TestServer.open();
    defer fixture.deinit();
    fixture.limits.client_ms = 20;
    const stalled = try testConnect(&fixture.listener, deadlineAfter(std.testing.io, 1_000));
    defer stalled.close(std.testing.io);
    var worker = try std.testing.io.concurrent(TestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    try expectTestStatus(&fixture.listener, .{}, "HTTP/1.1 200 OK\r\n");
    try worker.await(std.testing.io);
}

test "the callback connection budget terminates repeated invalid requests" {
    var fixture = try TestServer.open();
    defer fixture.deinit();
    var worker = try std.testing.io.concurrent(TestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    for (0..connections_count_max) |_| {
        try expectTestStatus(&fixture.listener, .{ .target = "/" }, "HTTP/1.1 400 Bad Request\r\n");
    }
    try std.testing.expectError(error.CallbackConnectionLimit, worker.await(std.testing.io));
}

test "a full unterminated header is rejected and a later callback can succeed" {
    var fixture = try TestServer.open();
    defer fixture.deinit();
    var worker = try std.testing.io.concurrent(TestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    const oversized: [header_bytes_max]u8 = @splat('x');
    const response = try testExchange(&fixture.listener, &oversized);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
    try expectTestStatus(&fixture.listener, .{}, "HTTP/1.1 200 OK\r\n");
    try worker.await(std.testing.io);
}

test "returning authorization keeps the selected registration" {
    var fixture = try TestServer.open();
    defer fixture.deinit();
    fixture.existing_client_id = "oaiapp_existing";
    var worker = try std.testing.io.concurrent(TestServer.run, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    try expectTestStatus(&fixture.listener, .{}, "HTTP/1.1 400 Bad Request\r\n");
    try expectTestStatus(&fixture.listener, .{
        .target = callback_path ++ "?code=secret-code&state=expected",
    }, "HTTP/1.1 200 OK\r\n");
    try worker.await(std.testing.io);
    try std.testing.expectEqualStrings("oaiapp_existing", fixture.callback.?.client_id);
}

test "HTTP header bytes and field counts have inclusive bounds" {
    const prefix = "GET /auth/callback?code=c&state=s HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:123\r\nPadding: ";
    for ([_]usize{ header_bytes_max - 1, header_bytes_max, header_bytes_max + 1 }) |size| {
        var buffer: [header_bytes_max + 1]u8 = @splat('x');
        @memcpy(buffer[0..prefix.len], prefix);
        @memcpy(buffer[size - 4 .. size], "\r\n\r\n");
        if (size <= header_bytes_max) {
            try std.testing.expectEqualStrings(
                "code=c&state=s",
                try requestQuery(buffer[0..size], "127.0.0.1:123"),
            );
        } else {
            try std.testing.expectError(
                error.HeaderTooLarge,
                requestQuery(buffer[0..size], "127.0.0.1:123"),
            );
        }
    }
    for ([_]usize{ headers_count_max - 1, headers_count_max, headers_count_max + 1 }) |count| {
        var buffer: [header_bytes_max]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writer.writeAll("GET /auth/callback?state=s HTTP/1.1\r\nHost: 127.0.0.1:123\r\n");
        for (1..count) |index| try writer.print("X-{d}: a\r\n", .{index});
        try writer.writeAll("\r\n");
        if (count <= headers_count_max) {
            try std.testing.expectEqualStrings(
                "state=s",
                try requestQuery(writer.buffered(), "127.0.0.1:123"),
            );
        } else {
            try std.testing.expectError(
                error.TooManyHeaders,
                requestQuery(writer.buffered(), "127.0.0.1:123"),
            );
        }
    }
}
