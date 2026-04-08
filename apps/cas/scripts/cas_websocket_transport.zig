const std = @import("std");

const builtin = @import("builtin");
const mem = std.mem;

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const loopback_host = "127.0.0.1";

pub const ManagedServer = struct {
    child: std.process.Child,
    listen_url: []u8,

    pub fn deinit(self: *ManagedServer, allocator: std.mem.Allocator) void {
        allocator.free(self.listen_url);
    }

    pub fn processId(self: *const ManagedServer) u64 {
        return switch (builtin.os.tag) {
            .windows => @intCast(@intFromPtr(self.child.id)),
            .wasi => 0,
            else => @intCast(self.child.id),
        };
    }

    pub fn kill(self: *ManagedServer) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    read_buf: std.ArrayList(u8) = .empty,

    pub fn connect(
        allocator: std.mem.Allocator,
        ws_url: []const u8,
        timeout_ms: u32,
    ) !Connection {
        const parsed = try parseWsUrl(ws_url);
        const address = try std.net.Address.parseIp(parsed.host, parsed.port);
        const started_ms = std.time.milliTimestamp();
        while (true) {
            const stream = std.net.tcpConnectToAddress(address) catch |err| {
                if (std.time.milliTimestamp() - started_ms >= timeout_ms) return err;
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            };

            handshakeClient(allocator, stream, parsed.host, parsed.port, parsed.path) catch |err| {
                stream.close();
                return err;
            };

            return .{
                .allocator = allocator,
                .stream = stream,
                .read_buf = .empty,
            };
        }
    }

    pub fn close(self: *Connection) void {
        self.stream.close();
    }

    pub fn deinit(self: *Connection) void {
        self.read_buf.deinit(self.allocator);
    }

    pub fn sendText(self: *Connection, payload: []const u8) !void {
        try writeClientFrame(self, 0x1, payload);
    }

    pub fn readTextAlloc(self: *Connection) !?[]u8 {
        var fragment_type: ?u8 = null;
        var fragmented: std.ArrayList(u8) = .empty;
        defer fragmented.deinit(self.allocator);

        while (true) {
            const frame = try self.readFrameAlloc();
            defer if (frame.payload) |owned| self.allocator.free(owned);

            switch (frame.opcode) {
                0x1, 0x2 => {
                    if (frame.fin) {
                        const owned = try self.allocator.dupe(u8, frame.payload.?);
                        return owned;
                    }
                    fragment_type = frame.opcode;
                    try fragmented.appendSlice(self.allocator, frame.payload.?);
                },
                0x0 => {
                    if (fragment_type == null) return error.WebSocketUnexpectedContinuation;
                    try fragmented.appendSlice(self.allocator, frame.payload.?);
                    if (frame.fin) {
                        const owned = try fragmented.toOwnedSlice(self.allocator);
                        return owned;
                    }
                },
                0x8 => return null,
                0x9 => try writeClientFrame(self, 0xA, frame.payload.?),
                0xA => {},
                else => return error.WebSocketUnexpectedOpcode,
            }
        }
    }

    const Frame = struct {
        fin: bool,
        opcode: u8,
        payload: ?[]u8,
    };

    fn readFrameAlloc(self: *Connection) !Frame {
        const first = try readByte(self);
        const second = try readByte(self);
        const fin = (first & 0x80) != 0;
        const opcode = first & 0x0F;
        const masked = (second & 0x80) != 0;

        var payload_len: u64 = second & 0x7F;
        if (payload_len == 126) {
            var extended: [2]u8 = undefined;
            _ = try self.stream.readAtLeast(&extended, extended.len);
            payload_len = mem.readInt(u16, &extended, .big);
        } else if (payload_len == 127) {
            var extended: [8]u8 = undefined;
            _ = try self.stream.readAtLeast(&extended, extended.len);
            payload_len = mem.readInt(u64, &extended, .big);
        }

        var mask: [4]u8 = undefined;
        if (masked) {
            _ = try self.stream.readAtLeast(&mask, mask.len);
        }

        const payload = if (payload_len == 0)
            try self.allocator.dupe(u8, "")
        else blk: {
            const owned = try self.allocator.alloc(u8, @intCast(payload_len));
            errdefer self.allocator.free(owned);
            _ = try self.stream.readAtLeast(owned, owned.len);
            if (masked) applyMask(&mask, owned);
            break :blk owned;
        };

        return .{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
        };
    }
};

pub fn startManagedLoopbackServer(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    codex_path: []const u8,
) !ManagedServer {
    var address = try std.net.Address.parseIp(loopback_host, 0);
    var listener = try address.listen(.{});
    const port = listener.listen_address.getPort();
    listener.stream.close();

    const listen_url = try std.fmt.allocPrint(allocator, "ws://{s}:{d}", .{ loopback_host, port });
    errdefer allocator.free(listen_url);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, codex_path);
    try argv.append(allocator, "app-server");
    try argv.append(allocator, "--listen");
    try argv.append(allocator, listen_url);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        child.pgid = 0;
    }
    try child.spawn();

    return .{
        .child = child,
        .listen_url = listen_url,
    };
}

pub fn processAlive(process_id: u64) bool {
    return switch (builtin.os.tag) {
        .windows => true,
        .wasi => false,
        else => blk: {
            const pid: std.posix.pid_t = @intCast(process_id);
            std.posix.kill(pid, 0) catch |err| switch (err) {
                error.ProcessNotFound => break :blk false,
                else => break :blk true,
            };
            break :blk true;
        },
    };
}

pub fn terminateProcess(process_id: u64) void {
    switch (builtin.os.tag) {
        .windows, .wasi => {},
        else => {
            const pid: std.posix.pid_t = @intCast(process_id);
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        },
    }
}

const ParsedWsUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseWsUrl(ws_url: []const u8) !ParsedWsUrl {
    if (!mem.startsWith(u8, ws_url, "ws://")) return error.InvalidWebSocketUrl;
    const remainder = ws_url["ws://".len..];
    const slash_idx = mem.indexOfScalar(u8, remainder, '/') orelse remainder.len;
    const authority = remainder[0..slash_idx];
    const path = if (slash_idx < remainder.len) remainder[slash_idx..] else "/";
    const authority_addr = try std.net.Address.parseIpAndPort(authority);
    const colon_idx = mem.lastIndexOfScalar(u8, authority, ':') orelse return error.InvalidWebSocketUrl;
    return .{
        .host = authority[0..colon_idx],
        .port = authority_addr.getPort(),
        .path = path,
    };
}

fn handshakeClient(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    host: []const u8,
    port: u16,
    path: []const u8,
) !void {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var key_buf: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buf, &random_bytes);

    const request = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\n\r\n",
        .{ path, host, port, key },
    );
    defer allocator.free(request);
    try stream.writeAll(request);

    var response_buf: std.ArrayList(u8) = .empty;
    defer response_buf.deinit(allocator);
    while (mem.indexOf(u8, response_buf.items, "\r\n\r\n") == null) {
        var tmp: [1024]u8 = undefined;
        const n = try stream.read(&tmp);
        if (n == 0) return error.WebSocketHandshakeClosed;
        try response_buf.appendSlice(allocator, tmp[0..n]);
    }

    const header_end = mem.indexOf(u8, response_buf.items, "\r\n\r\n").? + 4;
    const headers = response_buf.items[0..header_end];
    if (!mem.startsWith(u8, headers, "HTTP/1.1 101")) return error.WebSocketHandshakeRejected;
    const accept = headerValue(headers, "sec-websocket-accept") orelse return error.WebSocketMissingAccept;

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(websocket_guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var accept_buf: [28]u8 = undefined;
    const expected = std.base64.standard.Encoder.encode(&accept_buf, &digest);
    if (!std.ascii.eqlIgnoreCase(accept, expected)) return error.WebSocketInvalidAccept;
}

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon_idx = mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = mem.trim(u8, line[0..colon_idx], " \t");
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
        return mem.trim(u8, line[colon_idx + 1 ..], " \t");
    }
    return null;
}

fn writeClientFrame(self: *Connection, opcode: u8, payload: []const u8) !void {
    const payload_len = payload.len;
    var header: [14]u8 = undefined;
    var header_len: usize = 0;
    header[header_len] = 0x80 | (opcode & 0x0F);
    header_len += 1;

    if (payload_len <= 125) {
        header[header_len] = 0x80 | @as(u8, @intCast(payload_len));
        header_len += 1;
    } else if (payload_len <= std.math.maxInt(u16)) {
        header[header_len] = 0x80 | 126;
        header_len += 1;
        mem.writeInt(u16, header[header_len..][0..2], @intCast(payload_len), .big);
        header_len += 2;
    } else {
        header[header_len] = 0x80 | 127;
        header_len += 1;
        mem.writeInt(u64, header[header_len..][0..8], payload_len, .big);
        header_len += 8;
    }

    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);
    @memcpy(header[header_len .. header_len + 4], &mask);
    header_len += 4;

    try self.stream.writeAll(header[0..header_len]);
    if (payload_len == 0) return;
    const masked = try self.allocator.dupe(u8, payload);
    defer self.allocator.free(masked);
    applyMask(&mask, masked);
    try self.stream.writeAll(masked);
}

fn applyMask(mask: *const [4]u8, payload: []u8) void {
    for (payload, 0..) |byte, idx| {
        payload[idx] = byte ^ mask[idx & 3];
    }
}

fn readByte(self: *Connection) !u8 {
    var buf: [1]u8 = undefined;
    _ = try self.stream.readAtLeast(&buf, 1);
    return buf[0];
}
