const std = @import("std");
const App = @import("app.zig").App;
const github = @import("github.zig");
const sessions = @import("sessions.zig");

pub const Runtime = struct {
    app: *App,
    registry: *sessions.Registry,
    broker: github.Broker,
    owner: []const u8,
    name: []const u8,
    number: u64,
    pull_request_id: []const u8,
    cwd: []const u8,
    skill_path: []const u8,
};

pub const max_header_bytes = 32 * 1024;
pub const max_ws_message_bytes = 1024 * 1024;
const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    listener: std.Io.net.Server,
    token: [32]u8,
    skill_root: []u8,

    pub fn bind(allocator: std.mem.Allocator, io: std.Io, skill_root: []const u8) !Server {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const listener = try address.listen(io, .{ .mode = .stream });
        var token: [32]u8 = undefined; io.random(&token);
        return .{ .allocator = allocator, .io = io, .listener = listener, .token = token, .skill_root = try allocator.dupe(u8, skill_root) };
    }
    pub fn deinit(self: *Server) void { self.listener.deinit(self.io); self.allocator.free(self.skill_root); }
    pub fn port(self: *const Server) u16 { return self.listener.socket.address.getPort(); }
    pub fn tokenHex(self: *const Server, out: *[64]u8) []const u8 { return std.fmt.bufPrint(out, "{x}", .{self.token}) catch unreachable; }

    pub fn serveOne(self: *Server, runtime: *Runtime) !void {
        var stream = try self.listener.accept(self.io); defer stream.close(self.io);
        var buf: [max_header_bytes]u8 = undefined; var used: usize = 0;
        while (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n") == null) {
            if (used == buf.len) return error.HttpHeadersTooLarge;
            const got = try stream.socket.receive(self.io, buf[used..]); if (got.data.len == 0) return error.EndOfStream; used += got.data.len;
        }
        const raw = buf[0..used];
        const target = requestTarget(raw) orelse return error.InvalidHttpRequest;
        var token_buf: [64]u8 = undefined; const token = self.tokenHex(&token_buf);
        if (std.mem.startsWith(u8, target, "/ws?")) return self.upgradeWebSocket(&stream, raw, token, runtime);
        if (!authorized(target, raw, token)) return writeResponse(self.io, &stream, "403 Forbidden", "text/plain", "forbidden", false);
        if (std.mem.startsWith(u8, target, "/api/bootstrap")) {
            const body = try runtime.app.bootstrapAlloc(); defer self.allocator.free(body);
            return writeResponse(self.io, &stream, "200 OK", "application/json", body, true);
        }
        if (std.mem.startsWith(u8, target, "/healthz") or std.mem.startsWith(u8, target, "/readyz"))
            return writeResponse(self.io, &stream, "200 OK", "application/json", "{\"status\":\"ok\"}", true);
        return self.serveAsset(&stream, target);
    }

    fn serveAsset(self: *Server, stream: *std.Io.net.Stream, target: []const u8) !void {
        const clean = if (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?")) "index.html" else blk: {
            const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
            const p = target[0..end];
            if (!std.mem.startsWith(u8, p, "/assets/") or std.mem.indexOf(u8, p, "..") != null or std.mem.indexOfScalar(u8, p, '\\') != null or std.mem.indexOfScalar(u8, p, '%') != null) return writeResponse(self.io, stream, "404 Not Found", "text/plain", "not found", false);
            break :blk p["/assets/".len..];
        };
        const root = try std.fs.path.join(self.allocator, &.{ self.skill_root, "assets", "ui" }); defer self.allocator.free(root);
        const root_real = try std.Io.Dir.cwd().realPathFileAlloc(self.io, root, self.allocator); defer self.allocator.free(root_real);
        const candidate = try std.fs.path.join(self.allocator, &.{ root_real, clean }); defer self.allocator.free(candidate);
        const real = std.Io.Dir.cwd().realPathFileAlloc(self.io, candidate, self.allocator) catch return writeResponse(self.io, stream, "404 Not Found", "text/plain", "not found", false);
        defer self.allocator.free(real);
        if (!pathConfined(root_real, real)) return writeResponse(self.io, stream, "404 Not Found", "text/plain", "not found", false);
        const body = try std.Io.Dir.cwd().readFileAlloc(self.io, real, self.allocator, .limited(8 * 1024 * 1024)); defer self.allocator.free(body);
        const content_type = if (std.mem.endsWith(u8, real, ".html")) "text/html; charset=utf-8" else if (std.mem.endsWith(u8, real, ".css")) "text/css" else "text/javascript";
        try writeResponse(self.io, stream, "200 OK", content_type, body, true);
    }

    fn upgradeWebSocket(self: *Server, stream: *std.Io.net.Stream, raw: []const u8, token: []const u8, runtime: *Runtime) !void {
        const target = requestTarget(raw) orelse return error.InvalidHttpRequest;
        if (!authorized(target, raw, token) or !loopbackOrigin(raw, self.port())) return writeResponse(self.io, stream, "403 Forbidden", "text/plain", "forbidden", false);
        const key = headerValue(raw, "sec-websocket-key") orelse return writeResponse(self.io, stream, "400 Bad Request", "text/plain", "missing websocket key", false);
        if (!headerToken(raw, "upgrade", "websocket") or !headerToken(raw, "connection", "upgrade")) return writeResponse(self.io, stream, "400 Bad Request", "text/plain", "invalid upgrade", false);
        var sha1 = std.crypto.hash.Sha1.init(.{}); sha1.update(key); sha1.update(websocket_guid); var digest: [20]u8 = undefined; sha1.final(&digest);
        var enc: [28]u8 = undefined; const accept = std.base64.standard.Encoder.encode(&enc, &digest);
        const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}); defer self.allocator.free(response);
        var writer = stream.writer(self.io, &.{}); try writer.interface.writeAll(response); try writer.interface.flush();
        for (0..64) |_| {
            const message = readClientTextAlloc(self.allocator, self.io, stream) catch return;
            defer self.allocator.free(message);
            const reply = self.handleCommandAlloc(runtime, message) catch |err| error_reply: {
                const payload = try std.fmt.allocPrint(self.allocator, "{{\"code\":{f}}}", .{std.json.fmt(@errorName(err), .{})}); defer self.allocator.free(payload);
                break :error_reply try runtime.app.nextEnvelope("error", payload);
            };
            defer self.allocator.free(reply);
            try writeServerText(self.io, stream, reply);
        }
    }

    fn handleCommandAlloc(self: *Server, runtime: *Runtime, raw: []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}); defer parsed.deinit();
        const root = switch (parsed.value) { .object => |o| o, else => return error.InvalidUiCommand };
        const command = switch (root.get("type") orelse return error.InvalidUiCommand) { .string => |s| s, else => return error.InvalidUiCommand };
        const payload = switch (root.get("payload") orelse return error.InvalidUiCommand) { .object => |o| o, else => return error.InvalidUiCommand };
        if (std.mem.eql(u8, command, "file.open")) {
            const path = switch (payload.get("path") orelse return error.InvalidUiCommand) { .string => |s| s, else => return error.InvalidUiCommand };
            const event = try runtime.app.openFile(path); self.allocator.free(event);
            const revision = runtime.app.official_revision orelse return error.MissingRevision;
            const reused = try runtime.registry.openFile(runtime.cwd, path, revision, runtime.app.generation.base_oid, runtime.app.generation.head_oid, payloadString(payload, "diff") orelse "", payloadString(payload, "threads") orelse "[]", runtime.skill_path);
            return runtime.app.nextEnvelope("session.opened", if (reused) "{\"initialReview\":false,\"reused\":true}" else "{\"initialReview\":true,\"reused\":false}");
        }
        if (std.mem.eql(u8, command, "session.close")) {
            runtime.app.close();
            return runtime.app.nextEnvelope("session.closed", "{}");
        }
        if (std.mem.eql(u8, command, "session.message")) { runtime.app.initial_review_active = false; try runtime.registry.message(payloadString(payload, "text") orelse return error.InvalidUiCommand, false); return runtime.app.nextEnvelope("session.status", "{\"status\":\"turn-started\"}"); }
        if (std.mem.eql(u8, command, "session.interrupt")) { try runtime.registry.interrupt(); return runtime.app.nextEnvelope("session.status", "{\"status\":\"interrupted\"}"); }
        if (std.mem.eql(u8, command, "action.prepare")) { try runtime.app.prepareInline(payloadString(payload, "path") orelse return error.InvalidUiCommand, @intCast(payload.get("line").?.integer), payloadString(payload, "body") orelse return error.InvalidUiCommand, true); return runtime.app.nextEnvelope("action.prepared", "{\"id\":\"act-1\",\"status\":\"pending\"}"); }
        if (std.mem.eql(u8, command, "action.confirm")) { try runtime.app.confirmInline(runtime.broker, runtime.pull_request_id, runtime.app.generation.head_oid); return runtime.app.nextEnvelope("action.status", "{\"id\":\"act-1\",\"status\":\"succeeded\"}"); }
        if (std.mem.eql(u8, command, "file.complete")) { const path = payloadString(payload, "path") orelse return error.InvalidUiCommand; try runtime.app.complete(runtime.broker, runtime.owner, runtime.name, runtime.number, runtime.pull_request_id, path, true); return runtime.app.nextEnvelope("file.completed", "{}"); }
        if (std.mem.eql(u8, command, "snapshot.get")) { const snapshot = try runtime.app.bootstrapAlloc(); defer self.allocator.free(snapshot); return runtime.app.nextEnvelope("snapshot", snapshot); }
        return error.UnsupportedUiCommand;
    }
};

fn payloadString(payload: std.json.ObjectMap, key: []const u8) ?[]const u8 { const value = payload.get(key) orelse return null; return switch (value) { .string => |s| s, else => null }; }

pub fn pathConfined(root: []const u8, candidate: []const u8) bool {
    return std.mem.eql(u8, root, candidate) or (std.mem.startsWith(u8, candidate, root) and candidate.len > root.len and candidate[root.len] == std.fs.path.sep);
}

fn authorized(target: []const u8, raw: []const u8, token: []const u8) bool {
    if (queryToken(target)) |value| if (std.mem.eql(u8, value, token)) return true;
    return if (headerValue(raw, "authorization")) |v| std.mem.startsWith(u8, v, "Bearer ") and std.mem.eql(u8, v[7..], token) else false;
}
fn queryToken(target: []const u8) ?[]const u8 { const q = std.mem.indexOfScalar(u8, target, '?') orelse return null; var it = std.mem.splitScalar(u8, target[q + 1 ..], '&'); var found: ?[]const u8 = null; while (it.next()) |pair| { const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null; if (std.mem.eql(u8, pair[0..eq], "token")) { if (found != null) return null; found = pair[eq + 1 ..]; } else return null; } return found; }

fn loopbackOrigin(raw: []const u8, port: u16) bool {
    const origin = headerValue(raw, "origin") orelse return false;
    var buf: [64]u8 = undefined; const expected = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}", .{port}) catch return false;
    return std.mem.eql(u8, origin, expected);
}

fn requestTarget(raw: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, raw, "\r\n") orelse return null;
    var it = std.mem.splitScalar(u8, raw[0..end], ' '); if (!std.mem.eql(u8, it.next() orelse return null, "GET")) return null;
    return it.next();
}
fn headerValue(raw: []const u8, name: []const u8) ?[]const u8 { var lines = std.mem.splitSequence(u8, raw, "\r\n"); _ = lines.next(); while (lines.next()) |line| { if (line.len == 0) break; const i = std.mem.indexOfScalar(u8, line, ':') orelse continue; if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..i], " \t"), name)) return std.mem.trim(u8, line[i+1..], " \t"); } return null; }
fn headerToken(raw: []const u8, name: []const u8, token: []const u8) bool { const value = headerValue(raw, name) orelse return false; var it = std.mem.splitScalar(u8, value, ','); while (it.next()) |part| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true; return false; }

pub fn readClientTextAlloc(allocator: std.mem.Allocator, io: std.Io, stream: *std.Io.net.Stream) ![]u8 {
    var head: [2]u8 = undefined; try readExact(io, stream, &head);
    if ((head[0] & 0x80) == 0 or (head[0] & 0x70) != 0 or (head[0] & 0x0f) != 1 or (head[1] & 0x80) == 0) return error.InvalidClientWebSocketFrame;
    var len: u64 = head[1] & 0x7f;
    if (len == 126) { var b: [2]u8 = undefined; try readExact(io, stream, &b); len = std.mem.readInt(u16, &b, .big); if (len < 126) return error.InvalidClientWebSocketFrame; }
    else if (len == 127) { var b: [8]u8 = undefined; try readExact(io, stream, &b); len = std.mem.readInt(u64, &b, .big); if (len <= 65535) return error.InvalidClientWebSocketFrame; }
    if (len > max_ws_message_bytes) return error.WebSocketMessageTooLarge;
    var mask: [4]u8 = undefined; try readExact(io, stream, &mask);
    const payload = try allocator.alloc(u8, @intCast(len)); errdefer allocator.free(payload); try readExact(io, stream, payload);
    for (payload, 0..) |*byte, i| byte.* ^= mask[i % 4];
    if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidClientWebSocketFrame;
    return payload;
}
fn readExact(io: std.Io, stream: *std.Io.net.Stream, dest: []u8) !void { var off: usize = 0; while (off < dest.len) { const got = try stream.socket.receive(io, dest[off..]); if (got.data.len == 0) return error.EndOfStream; off += got.data.len; } }
fn writeServerText(io: std.Io, stream: *std.Io.net.Stream, body: []const u8) !void {
    if (body.len > max_ws_message_bytes) return error.FrameTooLarge;
    var writer = stream.writer(io, &.{}); try writer.interface.writeByte(0x81);
    if (body.len <= 125) try writer.interface.writeByte(@intCast(body.len))
    else if (body.len <= std.math.maxInt(u16)) { try writer.interface.writeByte(126); var len: [2]u8 = undefined; std.mem.writeInt(u16, &len, @intCast(body.len), .big); try writer.interface.writeAll(&len); }
    else { try writer.interface.writeByte(127); var len: [8]u8 = undefined; std.mem.writeInt(u64, &len, body.len, .big); try writer.interface.writeAll(&len); }
    try writer.interface.writeAll(body); try writer.interface.flush();
}
fn writeResponse(io: std.Io, stream: *std.Io.net.Stream, status: []const u8, content_type: []const u8, body: []const u8, secure: bool) !void { var writer = stream.writer(io, &.{}); try writer.interface.print("HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n", .{status, content_type, body.len}); if (secure) try writer.interface.writeAll("Content-Security-Policy: default-src 'self'; connect-src 'self' ws://127.0.0.1:*; object-src 'none'; base-uri 'none'\r\n"); try writer.interface.writeAll("\r\n"); try writer.interface.writeAll(body); try writer.interface.flush(); }

test "asset confinement rejects sibling prefix and traversal" {
    try std.testing.expect(pathConfined("/tmp/ui", "/tmp/ui/app.js"));
    try std.testing.expect(!pathConfined("/tmp/ui", "/tmp/ui-evil/app.js"));
}
test "token parsing is exact and unique" {
    try std.testing.expectEqualStrings("abc", queryToken("/ws?token=abc").?);
    try std.testing.expect(queryToken("/ws?x=1&token=abc") == null);
    try std.testing.expect(queryToken("/ws?token=abc&token=abc") == null);
}
