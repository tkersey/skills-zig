const std = @import("std");

pub const max_endpoint_bytes: usize = 4 * 1024;
pub const default_startup_timeout_ms: u32 = 10_000;

pub const RequestedTransport = enum {
    auto,
    stdio,
    managed_websocket,
    explicit_websocket,
    unix_socket,

    pub fn parse(raw: []const u8) ?RequestedTransport {
        if (std.mem.eql(u8, raw, "auto")) return .auto;
        if (std.mem.eql(u8, raw, "stdio")) return .stdio;
        if (std.mem.eql(u8, raw, "managed-ws")) return .managed_websocket;
        if (std.mem.eql(u8, raw, "ws")) return .explicit_websocket;
        if (std.mem.eql(u8, raw, "unix")) return .unix_socket;
        return null;
    }

    pub fn asString(self: RequestedTransport) []const u8 {
        return switch (self) {
            .auto => "auto",
            .stdio => "stdio",
            .managed_websocket => "managed-ws",
            .explicit_websocket => "ws",
            .unix_socket => "unix",
        };
    }
};

pub const ValidatedTransport = union(RequestedTransport) {
    auto,
    stdio,
    managed_websocket,
    explicit_websocket: []const u8,
    unix_socket: ?[]const u8,
};

pub fn validateTransport(
    requested: RequestedTransport,
    endpoint: ?[]const u8,
) !ValidatedTransport {
    if (endpoint) |value| {
        if (value.len == 0 or value.len > max_endpoint_bytes) {
            return error.InvalidTransportEndpoint;
        }
    }
    return switch (requested) {
        .auto => if (endpoint == null) .auto else error.TransportEndpointForbidden,
        .stdio => if (endpoint == null) .stdio else error.TransportEndpointForbidden,
        .managed_websocket => if (endpoint == null)
            .managed_websocket
        else
            error.TransportEndpointForbidden,
        .explicit_websocket => blk: {
            const value = endpoint orelse return error.TransportEndpointRequired;
            try validateInboundWebSocket(value);
            break :blk .{ .explicit_websocket = value };
        },
        .unix_socket => blk: {
            const value = endpoint orelse break :blk .{ .unix_socket = null };
            const path = try unixPath(value);
            try validateUnixPath(path);
            break :blk .{ .unix_socket = path };
        },
    };
}

pub const FallbackPhase = enum { before_first_rpc, rpc_started };

pub fn autoMayFallback(
    requested: RequestedTransport,
    failed: RequestedTransport,
    to: RequestedTransport,
    phase: FallbackPhase,
    managed_retired: bool,
) bool {
    return requested == .auto and
        failed == .managed_websocket and
        to == .stdio and
        phase == .before_first_rpc and
        managed_retired;
}

pub fn validateInboundWebSocket(raw: []const u8) !void {
    try rejectUnsafeUrlBytes(raw);
    const prefix_len: usize = if (std.mem.startsWith(u8, raw, "ws://")) 5 else 0;
    const remainder = raw[prefix_len..];
    const authority_end = std.mem.indexOfAny(u8, remainder, "/?#") orelse remainder.len;
    if (std.mem.indexOfAny(u8, remainder, "?#") != null) {
        return error.WebSocketQueryOrFragmentForbidden;
    }
    if (std.mem.indexOfScalar(u8, remainder[0..authority_end], '@') != null) {
        return error.WebSocketUserinfoForbidden;
    }
    const authority = try websocketAuthority(raw, false);
    if (!isLoopbackHost(authority.host)) return error.NonLoopbackWebSocketEndpoint;
    const port = authorityPort(authority.authority_no_userinfo) orelse
        return error.WebSocketPortRequired;
    if (port == 0) return error.WebSocketPortZero;
}

pub fn isLoopbackHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, "localhost.") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]") or
        std.mem.eql(u8, host, "::1") or
        isIpv4Loopback(host);
}

fn isIpv4Loopback(host: []const u8) bool {
    var parts = std.mem.splitScalar(u8, host, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (count >= 4 or part.len == 0) return false;
        const octet = std.fmt.parseInt(u8, part, 10) catch return false;
        if (count == 0 and octet != 127) return false;
    }
    return count == 4;
}

pub fn unixPath(raw: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, raw, "unix://")) return error.InvalidUnixEndpoint;
    const path = raw["unix://".len..];
    if (path.len == 0) return error.InvalidUnixEndpoint;
    return path;
}

pub fn validateUnixPath(path: []const u8) !void {
    if (path.len == 0 or path.len > max_endpoint_bytes) return error.InvalidUnixEndpoint;
    // Darwin and Linux sockaddr_un have different limits. Reject before the
    // platform syscall so callers get one deterministic failure.
    if (path.len >= 104) return error.UnixSocketPathTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidUnixEndpoint;
}

pub fn resolveUnixPathAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    path: []const u8,
) ![]u8 {
    try validateUnixPath(path);
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

pub fn defaultUnixPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    return switch (@import("builtin").os.tag) {
        .windows, .wasi => error.UnixSocketUnsupported,
        else => blk: {
            const environ = std.Io.Threaded.global_single_threaded.environ.process_environ;
            if (std.process.Environ.getPosix(environ, "CODEX_HOME")) |value| {
                break :blk std.fs.path.join(
                    allocator,
                    &.{ value, "app-server-control", "app-server-control.sock" },
                );
            }
            const home = std.process.Environ.getPosix(environ, "HOME") orelse
                return error.HomeNotSet;
            break :blk std.fs.path.join(
                allocator,
                &.{ home, ".codex", "app-server-control", "app-server-control.sock" },
            );
        },
    };
}

pub const CodeModeHost = struct {
    allocator: std.mem.Allocator,
    raw: []u8,
    redacted_origin: []u8,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,

    pub fn init(allocator: std.mem.Allocator, raw: []const u8) !CodeModeHost {
        if (raw.len == 0 or raw.len > max_endpoint_bytes) return error.InvalidCodeModeHost;
        try rejectUnsafeUrlBytes(raw);
        const authority = try websocketAuthority(raw, true);
        if (authority.secure) {
            // Remote Code Mode is allowed only over TLS.
        } else if (!isLoopbackHost(authority.host)) {
            return error.InsecureRemoteCodeModeHost;
        }
        const raw_owned = try allocator.dupe(u8, raw);
        errdefer allocator.free(raw_owned);
        const origin = try std.fmt.allocPrint(allocator, "{s}://{s}", .{
            if (authority.secure) "wss" else "ws",
            authority.authority_no_userinfo,
        });
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
        return .{
            .allocator = allocator,
            .raw = raw_owned,
            .redacted_origin = origin,
            .digest = digest,
        };
    }

    pub fn deinit(self: *CodeModeHost) void {
        @memset(self.raw, 0);
        self.allocator.free(self.raw);
        self.allocator.free(self.redacted_origin);
    }

    pub fn digestHex(self: *const CodeModeHost, out: *[64]u8) []const u8 {
        _ = std.fmt.bufPrint(out, "{x}", .{self.digest}) catch |err| switch (err) {
            error.NoSpaceLeft => unreachable,
        };
        return out;
    }
};

fn rejectUnsafeUrlBytes(raw: []const u8) !void {
    for (raw) |byte| if (byte <= 0x20 or byte == 0x7f) return error.UnsafeUrlByte;
}

fn authorityPort(authority: []const u8) ?u16 {
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return null;
    if (colon + 1 == authority.len) return null;
    return std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch null;
}

const Authority = struct {
    secure: bool,
    host: []const u8,
    authority_no_userinfo: []const u8,
};

fn websocketAuthority(raw: []const u8, allow_secure: bool) !Authority {
    const secure = std.mem.startsWith(u8, raw, "wss://");
    const prefix_len: usize = if (secure)
        6
    else if (std.mem.startsWith(u8, raw, "ws://"))
        5
    else
        return error.InvalidWebSocketUrl;
    if (secure and !allow_secure) return error.InvalidWebSocketUrl;
    const remainder = raw[prefix_len..];
    const end = std.mem.indexOfAny(u8, remainder, "/?#") orelse remainder.len;
    var authority = remainder[0..end];
    if (authority.len == 0) return error.InvalidWebSocketUrl;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (authority.len == 0) return error.InvalidWebSocketUrl;
    const host = if (authority[0] == '[') blk: {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse
            return error.InvalidWebSocketUrl;
        break :blk authority[0 .. close + 1];
    } else blk: {
        const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
        break :blk if (colon) |index| authority[0..index] else authority;
    };
    if (host.len == 0) return error.InvalidWebSocketUrl;
    return .{
        .secure = secure,
        .host = host,
        .authority_no_userinfo = authority,
    };
}

pub fn appendAppServerArgs(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    disable_hooks: bool,
    listen_url: ?[]const u8,
    code_mode_host: ?*const CodeModeHost,
) !void {
    // Keep both app-server endpoints explicit in one argv builder. `--listen`
    // is the inbound CAS transport; `--code-mode-host` is Codex's outbound
    // connection and must never be substituted for the listener.
    try argv.append(allocator, "app-server");
    if (disable_hooks) try argv.appendSlice(allocator, &.{ "--disable", "codex_hooks" });
    if (listen_url) |value| try argv.appendSlice(allocator, &.{ "--listen", value });
    if (code_mode_host) |host| try argv.appendSlice(allocator, &.{ "--code-mode-host", host.raw });
}
