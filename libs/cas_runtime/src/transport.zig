//! Canonical launch and endpoint policy for reusable app-server consumers.

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

pub fn defaultUnixPathAlloc(
    allocator: std.mem.Allocator,
    codex_home: ?[]const u8,
    home: ?[]const u8,
) ![]u8 {
    return switch (@import("builtin").os.tag) {
        .windows, .wasi => error.UnixSocketUnsupported,
        else => blk: {
            if (codex_home) |value| {
                break :blk std.fs.path.join(
                    allocator,
                    &.{ value, "app-server-control", "app-server-control.sock" },
                );
            }
            const home_value = home orelse
                return error.HomeNotSet;
            break :blk std.fs.path.join(
                allocator,
                &.{ home_value, ".codex", "app-server-control", "app-server-control.sock" },
            );
        },
    };
}

/// Resolves from the invocation directory, trying packaged siblings before PATH.
/// File existence is sufficient here; spawning owns executable-permission checks.
pub fn resolveExecutableAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path_env: ?[]const u8,
    raw: []const u8,
) ![]u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return error.MissingExecutable;

    if (std.mem.indexOfScalar(u8, value, '/') != null) {
        return try resolveCandidateAlloc(allocator, io, dir, value) orelse error.ExecutableNotFound;
    }

    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => null,
    };
    if (exe_dir) |directory| {
        defer allocator.free(directory);
        const sibling = try allocator.print("{s}/{s}", .{ directory, value });
        errdefer allocator.free(sibling);
        if (try pathExists(io, dir, sibling)) return sibling;
        allocator.free(sibling);
    }

    var iter = std.mem.splitScalar(u8, path_env orelse return error.ExecutableNotFound, ':');
    while (iter.next()) |directory| {
        if (directory.len == 0) continue;
        const candidate = try allocator.print("{s}/{s}", .{ directory, value });
        errdefer allocator.free(candidate);
        if (try pathExists(io, dir, candidate)) {
            if (std.fs.path.isAbsolute(candidate)) return candidate;
            const root_path = dir.realPathFileAlloc(io, ".", allocator) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => return err,
                else => {
                    allocator.free(candidate);
                    continue;
                },
            };
            defer allocator.free(root_path);
            const absolute = try std.fs.path.join(allocator, &.{ root_path, candidate });
            allocator.free(candidate);
            return absolute;
        }
        allocator.free(candidate);
    }

    return error.ExecutableNotFound;
}

fn resolveCandidateAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) !?[]u8 {
    const resolved = dir.realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => return null,
    };
    defer allocator.free(resolved);
    return try allocator.dupe(u8, resolved);
}

fn pathExists(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    dir.access(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return err,
        else => return false,
    };
    return true;
}

test "default Unix path uses supplied home values and preserves precedence" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        try std.testing.expectError(error.UnixSocketUnsupported, defaultUnixPathAlloc(
            std.testing.allocator,
            "/codex",
            "/home",
        ));
        return;
    }
    const cases = .{
        .{ @as(?[]const u8, "/codex"), @as(?[]const u8, "/home"), "/codex/app-server-control/app-server-control.sock" },
        .{ @as(?[]const u8, null), @as(?[]const u8, "/home"), "/home/.codex/app-server-control/app-server-control.sock" },
        .{ @as(?[]const u8, ""), @as(?[]const u8, "/home"), "app-server-control/app-server-control.sock" },
    };
    inline for (cases) |case| {
        const actual = try defaultUnixPathAlloc(std.testing.allocator, case[0], case[1]);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case[2], actual);
    }
    try std.testing.expectError(error.HomeNotSet, defaultUnixPathAlloc(std.testing.allocator, null, null));
}

test "executable resolution uses independent supplied directories and PATH values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    const name = "cas-explicit-path-fixture";
    for ([_]std.Io.Dir{ first.dir, second.dir }) |dir| {
        try dir.writeFile(io, .{ .sub_path = name, .data = "fixture" });
        const absolute = try dir.realPathFileAlloc(io, name, allocator);
        defer allocator.free(absolute);
        const by_path = try resolveExecutableAlloc(allocator, io, dir, ":missing:.:", name);
        defer allocator.free(by_path);
        const by_path_real = try dir.realPathFileAlloc(io, by_path, allocator);
        defer allocator.free(by_path_real);
        try std.testing.expect(std.fs.path.isAbsolute(by_path));
        try std.testing.expectEqualStrings(absolute, by_path_real);
        const by_slash = try resolveExecutableAlloc(allocator, io, dir, null, "./" ++ name);
        defer allocator.free(by_slash);
        try std.testing.expectEqualStrings(absolute, by_slash);
        try std.testing.expectError(error.ExecutableNotFound, resolveExecutableAlloc(allocator, io, dir, "::", name));
        try std.testing.expectError(error.ExecutableNotFound, resolveExecutableAlloc(allocator, io, dir, null, name));
    }
}

test "PATH executable resolution preserves symlink spelling" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.createDir(io, "target", .default_dir);
    try dir.dir.writeFile(io, .{ .sub_path = "target/cas-symlink-fixture", .data = "fixture" });
    try dir.dir.symLink(io, "target", "alias", .{ .is_directory = true });
    const root_path = try dir.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    const path_env = try std.fs.path.join(allocator, &.{ root_path, "alias" });
    defer allocator.free(path_env);
    const expected = try std.fs.path.join(allocator, &.{ path_env, "cas-symlink-fixture" });
    defer allocator.free(expected);
    for ([_][]const u8{ "alias", path_env }) |path| {
        const resolved = try resolveExecutableAlloc(allocator, io, dir.dir, path, "cas-symlink-fixture");
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings(expected, resolved);
    }
}

test "executable resolution propagates supplied I/O cancellation" {
    const Canceled = struct {
        fn realPath(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: []u8) std.Io.Dir.RealPathFileError!usize {
            return error.Canceled;
        }

        fn access(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.AccessOptions) std.Io.Dir.AccessError!void {
            return error.Canceled;
        }
    };
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var vtable = std.testing.io.vtable.*;
    vtable.dirRealPathFile = Canceled.realPath;
    vtable.dirAccess = Canceled.access;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.Canceled, resolveExecutableAlloc(std.testing.allocator, io, dir.dir, null, "./codex"));
    try std.testing.expectError(error.Canceled, resolveExecutableAlloc(std.testing.allocator, io, dir.dir, ".", "codex"));
}

test "executable resolution propagates allocation failure" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "cas-allocation-fixture", .data = "fixture" });
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExecutableAllocations,
        .{dir.dir},
    );
}

fn exerciseExecutableAllocations(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    const slash = try resolveExecutableAlloc(allocator, std.testing.io, dir, null, "./cas-allocation-fixture");
    defer allocator.free(slash);
    const path = try resolveExecutableAlloc(allocator, std.testing.io, dir, ".", "cas-allocation-fixture");
    defer allocator.free(path);
    try std.testing.expect(std.fs.path.isAbsolute(slash));
    try std.testing.expect(std.fs.path.isAbsolute(path));
}

pub const CodeModeHost = struct {
    allocator: std.mem.Allocator,
    raw: []u8,
    redacted_origin: []u8,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,

    pub fn init(allocator: std.mem.Allocator, raw: []const u8) !CodeModeHost {
        if (raw.len == 0 or raw.len > max_endpoint_bytes) return error.InvalidCodeModeHost;
        try rejectUnsafeUrlBytes(raw);
        const authority = try codeModeAuthority(raw);
        if (authority.secure) {
            // Remote Code Mode is allowed only over TLS.
        } else if (!isLoopbackHost(authority.host)) {
            return error.InsecureRemoteCodeModeHost;
        }
        const raw_owned = try allocator.dupe(u8, raw);
        errdefer allocator.free(raw_owned);
        const origin = try allocator.print("{s}://{s}", .{
            if (authority.secure) "https" else "http",
            authority.authority,
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

const CodeModeAuthority = struct {
    secure: bool,
    authority: []const u8,
    host: []const u8,
};

fn codeModeAuthority(raw: []const u8) !CodeModeAuthority {
    const secure = std.mem.startsWith(u8, raw, "https://");
    const prefix_len: usize = if (secure)
        "https://".len
    else if (std.mem.startsWith(u8, raw, "http://"))
        "http://".len
    else
        return error.InvalidCodeModeHost;
    const remainder = raw[prefix_len..];
    const end = std.mem.indexOfAny(u8, remainder, "/?#") orelse remainder.len;
    const authority = remainder[0..end];
    if (authority.len == 0) return error.InvalidCodeModeHost;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) {
        return error.CodeModeHostUserinfoForbidden;
    }
    if (end != remainder.len and !std.mem.eql(u8, remainder[end..], "/")) {
        return error.CodeModeHostRootRequired;
    }
    const host = if (authority[0] == '[') blk: {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse
            return error.InvalidCodeModeHost;
        const suffix = authority[close + 1 ..];
        if (suffix.len > 0) {
            if (suffix[0] != ':' or suffix.len == 1) return error.InvalidCodeModeHost;
            const port = std.fmt.parseInt(u16, suffix[1..], 10) catch
                return error.InvalidCodeModeHost;
            if (port == 0) return error.InvalidCodeModeHost;
        }
        break :blk authority[0 .. close + 1];
    } else blk: {
        const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
        if (colon) |index| {
            if (std.mem.indexOfScalar(u8, authority[0..index], ':') != null or
                index + 1 == authority.len)
            {
                return error.InvalidCodeModeHost;
            }
            const port = std.fmt.parseInt(u16, authority[index + 1 ..], 10) catch
                return error.InvalidCodeModeHost;
            if (port == 0) return error.InvalidCodeModeHost;
            break :blk authority[0..index];
        }
        break :blk authority;
    };
    if (host.len == 0) return error.InvalidCodeModeHost;
    return .{ .secure = secure, .authority = authority, .host = host };
}

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
