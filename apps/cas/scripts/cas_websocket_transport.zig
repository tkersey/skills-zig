const std = @import("std");

const builtin = @import("builtin");
const hooks = @import("cas_hook_policy.zig");
const mem = std.mem;

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const loopback_host = "127.0.0.1";

pub const ManagedServer = struct {
    child: std.process.Child,
    listen_url: []u8,
    owner_control: ?std.Io.File = null,
    stopped: bool = false,

    pub fn deinit(self: *ManagedServer, allocator: std.mem.Allocator) void {
        if (self.owner_control != null) self.kill();
        allocator.free(self.listen_url);
    }

    pub fn processId(self: *const ManagedServer) u64 {
        const child_id = self.child.id orelse return 0;
        return switch (builtin.os.tag) {
            .windows => @intCast(@intFromPtr(child_id)),
            .wasi => 0,
            else => @intCast(child_id),
        };
    }

    pub fn kill(self: *ManagedServer) void {
        if (self.stopped) return;
        self.stopped = true;
        const io = std.Io.Threaded.global_single_threaded.io();
        if (self.owner_control) |control| {
            control.close(io);
            self.owner_control = null;
            _ = self.child.wait(io) catch {
                self.child.kill(io);
                return;
            };
            return;
        }
        self.child.kill(io);
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    read_buf: std.ArrayList(u8) = .empty,
    usable: bool = true,

    pub fn connect(
        allocator: std.mem.Allocator,
        ws_url: []const u8,
        timeout_ms: u32,
    ) !Connection {
        const parsed = try parseWsUrl(ws_url);
        const address = try std.Io.net.IpAddress.parse(parsed.host, parsed.port);
        const io = std.Io.Threaded.global_single_threaded.io();
        const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
        while (true) {
            const stream = address.connect(io, .{ .mode = .stream }) catch |err| {
                const now_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
                if (now_ms - started_ms >= timeout_ms) return err;
                std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
                continue;
            };

            handshakeClient(allocator, stream, parsed.host, parsed.port, parsed.path) catch |err| {
                stream.close(io);
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
        if (!self.usable) return;
        self.usable = false;
        self.stream.close(std.Io.Threaded.global_single_threaded.io());
    }

    pub fn poison(self: *Connection) void {
        self.close();
        self.read_buf.clearRetainingCapacity();
    }

    pub fn deinit(self: *Connection) void {
        self.read_buf.deinit(self.allocator);
    }

    pub fn sendText(self: *Connection, payload: []const u8) !void {
        if (!self.usable) return error.ConnectionPoisoned;
        try writeClientFrame(self, 0x1, payload, null);
    }

    pub fn sendTextTimeout(self: *Connection, payload: []const u8, timeout_ms: u32) !void {
        if (!self.usable) return error.ConnectionPoisoned;
        const io = std.Io.Threaded.global_single_threaded.io();
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        });
        writeClientFrame(self, 0x1, payload, deadline) catch |err| switch (err) {
            error.Timeout => {
                self.poison();
                return error.Timeout;
            },
            else => return err,
        };
    }

    pub fn readTextAlloc(self: *Connection) !?[]u8 {
        if (!self.usable) return error.ConnectionPoisoned;
        return self.readTextAllocUntil(null);
    }

    pub fn readTextAllocTimeout(self: *Connection, timeout_ms: u32) !?[]u8 {
        if (!self.usable) return error.ConnectionPoisoned;
        const io = std.Io.Threaded.global_single_threaded.io();
        const duration = std.Io.Clock.Duration{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        };
        const deadline = std.Io.Clock.Timestamp.fromNow(
            io,
            duration,
        );
        return self.readTextAllocUntil(deadline) catch |err| switch (err) {
            error.Timeout => {
                self.poison();
                return error.Timeout;
            },
            else => return err,
        };
    }

    fn readTextAllocUntil(
        self: *Connection,
        deadline: ?std.Io.Clock.Timestamp,
    ) !?[]u8 {
        var fragment_type: ?u8 = null;
        var fragmented: std.ArrayList(u8) = .empty;
        defer fragmented.deinit(self.allocator);

        while (true) {
            const frame = try self.readFrameAlloc(deadline);
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
                0x9 => try writeClientFrame(self, 0xA, frame.payload.?, deadline),
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

    fn readFrameAlloc(
        self: *Connection,
        deadline: ?std.Io.Clock.Timestamp,
    ) !Frame {
        const first = try readByte(self, deadline);
        const second = try readByte(self, deadline);
        const fin = (first & 0x80) != 0;
        const opcode = first & 0x0F;
        const masked = (second & 0x80) != 0;

        var payload_len: u64 = second & 0x7F;
        if (payload_len == 126) {
            var extended: [2]u8 = undefined;
            try readStreamExact(self.stream, &extended, deadline);
            payload_len = mem.readInt(u16, &extended, .big);
        } else if (payload_len == 127) {
            var extended: [8]u8 = undefined;
            try readStreamExact(self.stream, &extended, deadline);
            payload_len = mem.readInt(u64, &extended, .big);
        }

        var mask: [4]u8 = undefined;
        if (masked) {
            try readStreamExact(self.stream, &mask, deadline);
        }

        const payload = if (payload_len == 0)
            try self.allocator.dupe(u8, "")
        else blk: {
            const owned = try self.allocator.alloc(u8, @intCast(payload_len));
            errdefer self.allocator.free(owned);
            try readStreamExact(self.stream, owned, deadline);
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
    hook_policy: hooks.HookPolicy,
    io: std.Io,
) !ManagedServer {
    return startManagedLoopbackServerWithOwnership(
        allocator,
        cwd,
        codex_path,
        hook_policy,
        false,
        io,
    );
}

pub fn startOwnerLivedLoopbackServer(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    codex_path: []const u8,
    hook_policy: hooks.HookPolicy,
    io: std.Io,
) !ManagedServer {
    return startManagedLoopbackServerWithOwnership(
        allocator,
        cwd,
        codex_path,
        hook_policy,
        true,
        io,
    );
}

fn startManagedLoopbackServerWithOwnership(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    codex_path: []const u8,
    hook_policy: hooks.HookPolicy,
    owner_lived: bool,
    io: std.Io,
) !ManagedServer {
    try hooks.ensureLaunchSupportsPolicy(allocator, io, codex_path, cwd, hook_policy);

    var address = try std.Io.net.IpAddress.parse(loopback_host, 0);
    var listener = try address.listen(io, .{ .mode = .stream });
    const port = listener.socket.address.getPort();
    listener.deinit(io);

    const listen_url = try std.fmt.allocPrint(allocator, "ws://{s}:{d}", .{ loopback_host, port });
    errdefer allocator.free(listen_url);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, codex_path);
    try hooks.appendAppServerArgs(allocator, &argv, hook_policy, listen_url);

    if (owner_lived) {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            return error.OwnerLivedManagedServerUnsupported;
        }
        return spawnOwnerPipeManagedServer(
            allocator,
            cwd,
            argv.items,
            listen_url,
            io,
        );
    }

    const child = try spawnDetachedProcess(allocator, cwd, argv.items, io);

    return .{
        .child = child,
        .listen_url = listen_url,
    };
}

const owner_watchdog_script =
    \\child=0
    \\cleanup() {
    \\  if [ "$child" -gt 0 ] 2>/dev/null; then
    \\    kill "$child" 2>/dev/null || true
    \\    attempts=0
    \\    while kill -0 "$child" 2>/dev/null && [ "$attempts" -lt 20 ]; do
    \\      sleep 0.05
    \\      attempts=$((attempts + 1))
    \\    done
    \\    kill -KILL "$child" 2>/dev/null || true
    \\    wait "$child" 2>/dev/null || true
    \\  fi
    \\}
    \\trap cleanup EXIT HUP INT TERM
    \\"$@" &
    \\child=$!
    \\while IFS= read -r _; do :; done
;

fn spawnOwnerPipeManagedServer(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    server_argv: []const []const u8,
    listen_url: []u8,
    io: std.Io,
) !ManagedServer {
    var watchdog_argv: std.ArrayList([]const u8) = .empty;
    defer watchdog_argv.deinit(allocator);
    try watchdog_argv.appendSlice(allocator, &.{
        "/bin/sh",
        "-c",
        owner_watchdog_script,
        "cas-app-server-watchdog",
    });
    try watchdog_argv.appendSlice(allocator, server_argv);

    if (builtin.os.tag == .macos and builtin.link_libc) {
        return spawnOwnerPipeManagedServerPosix(
            allocator,
            cwd,
            watchdog_argv.items,
            listen_url,
        );
    }

    var child = try std.process.spawn(io, .{
        .argv = watchdog_argv.items,
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    });
    const owner_control = child.stdin orelse {
        child.kill(io);
        return error.ChildMissingStdin;
    };
    child.stdin = null;
    return .{
        .child = child,
        .listen_url = listen_url,
        .owner_control = owner_control,
    };
}

fn spawnOwnerPipeManagedServerPosix(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    watchdog_argv: []const []const u8,
    listen_url: []u8,
) !ManagedServer {
    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.SystemResources;
    var read_open = true;
    var write_open = true;
    defer if (read_open) {
        _ = std.c.close(pipe_fds[0]);
    };
    errdefer if (write_open) {
        _ = std.c.close(pipe_fds[1]);
    };
    const write_fd_flags = std.c.fcntl(pipe_fds[1], std.c.F.GETFD);
    if (write_fd_flags < 0 or
        std.c.fcntl(
            pipe_fds[1],
            std.c.F.SETFD,
            write_fd_flags | std.c.FD_CLOEXEC,
        ) < 0)
    {
        return error.SystemResources;
    }

    var actions: std.c.posix_spawn_file_actions_t = undefined;
    if (std.c.posix_spawn_file_actions_init(&actions) != 0) {
        return error.SpawnFileActionsFailed;
    }
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);

    const cwd_storage = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_storage);
    if (std.c.posix_spawn_file_actions_addchdir_np(&actions, cwd_storage.ptr) != 0) {
        return error.SpawnFileActionsFailed;
    }
    if (pipe_fds[0] != 0 and
        (std.c.posix_spawn_file_actions_adddup2(&actions, pipe_fds[0], 0) != 0 or
            std.c.posix_spawn_file_actions_addclose(&actions, pipe_fds[0]) != 0))
    {
        return error.SpawnFileActionsFailed;
    }
    if (pipe_fds[1] != 0 and
        std.c.posix_spawn_file_actions_addclose(&actions, pipe_fds[1]) != 0)
    {
        return error.SpawnFileActionsFailed;
    }
    const write_null: c_int = @bitCast(std.c.O{ .ACCMODE = .WRONLY });
    if (std.c.posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", write_null, 0) != 0 or
        std.c.posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", write_null, 0) != 0)
    {
        return error.SpawnFileActionsFailed;
    }

    var argv_buf = try allocator.allocSentinel(?[*:0]const u8, watchdog_argv.len, null);
    defer allocator.free(argv_buf);
    var arg_storage = try allocator.alloc([:0]u8, watchdog_argv.len);
    var arg_count: usize = 0;
    defer {
        for (arg_storage[0..arg_count]) |arg| allocator.free(arg);
        allocator.free(arg_storage);
    }
    for (watchdog_argv, 0..) |arg, i| {
        arg_storage[i] = try allocator.dupeZ(u8, arg);
        arg_count += 1;
        argv_buf[i] = arg_storage[i].ptr;
    }

    var pid: std.c.pid_t = undefined;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const spawn_rc = std.c.posix_spawn(
        &pid,
        argv_buf[0].?,
        &actions,
        null,
        argv_buf.ptr,
        envp,
    );
    if (spawn_rc != 0) return posixSpawnError(spawn_rc);

    _ = std.c.close(pipe_fds[0]);
    read_open = false;
    write_open = false;
    return .{
        .child = .{
            .id = pid,
            .thread_handle = {},
            .stdin = null,
            .stdout = null,
            .stderr = null,
            .request_resource_usage_statistics = false,
        },
        .listen_url = listen_url,
        .owner_control = .{
            .handle = pipe_fds[1],
            .flags = .{ .nonblocking = false },
        },
    };
}

pub fn spawnDetachedProcess(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    io: std.Io,
) !std.process.Child {
    if (builtin.os.tag == .macos and builtin.link_libc) return spawnManagedServerPosix(allocator, cwd, argv);
    return std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    });
}

fn spawnManagedServerPosix(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) !std.process.Child {
    if (argv.len == 0) return error.FileNotFound;

    var actions: std.c.posix_spawn_file_actions_t = undefined;
    if (std.c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFileActionsFailed;
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);

    const cwd_storage = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_storage);
    if (std.c.posix_spawn_file_actions_addchdir_np(&actions, cwd_storage.ptr) != 0) return error.SpawnFileActionsFailed;
    const read_null: c_int = @bitCast(std.c.O{ .ACCMODE = .RDONLY });
    const write_null: c_int = @bitCast(std.c.O{ .ACCMODE = .WRONLY });
    if (std.c.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", read_null, 0) != 0) return error.SpawnFileActionsFailed;
    if (std.c.posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", write_null, 0) != 0) return error.SpawnFileActionsFailed;
    if (std.c.posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", write_null, 0) != 0) return error.SpawnFileActionsFailed;

    var argv_buf = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    defer allocator.free(argv_buf);
    var arg_storage = try allocator.alloc([:0]u8, argv.len);
    var arg_count: usize = 0;
    defer {
        for (arg_storage[0..arg_count]) |arg| allocator.free(arg);
        allocator.free(arg_storage);
    }
    for (argv, 0..) |arg, i| {
        arg_storage[i] = try allocator.dupeZ(u8, arg);
        arg_count += 1;
        argv_buf[i] = arg_storage[i].ptr;
    }

    var pid: std.c.pid_t = undefined;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const spawn_rc = if (std.mem.indexOfScalar(u8, argv[0], '/') == null)
        std.c.posix_spawnp(&pid, argv_buf[0].?, &actions, null, argv_buf.ptr, envp)
    else
        std.c.posix_spawn(&pid, argv_buf[0].?, &actions, null, argv_buf.ptr, envp);
    if (spawn_rc != 0) return posixSpawnError(spawn_rc);

    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
}

fn posixSpawnError(rc: c_int) anyerror {
    const err: std.c.E = @enumFromInt(@as(u16, @intCast(rc)));
    return switch (err) {
        .NOMEM, .@"2BIG" => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOEXEC => error.InvalidExe,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        else => error.SpawnFailed,
    };
}

pub fn processAlive(process_id: u64) bool {
    return switch (builtin.os.tag) {
        .windows => true,
        .wasi => false,
        else => blk: {
            const pid: std.posix.pid_t = @intCast(process_id);
            std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
                error.ProcessNotFound => break :blk false,
                else => break :blk true,
            };
            break :blk true;
        },
    };
}

pub fn waitForProcessExit(process_id: u64, timeout_ms: u32) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const started_ms = @divFloor(
        std.Io.Clock.awake.now(io).nanoseconds,
        1_000_000,
    );
    while (processAlive(process_id)) {
        const now_ms = @divFloor(
            std.Io.Clock.awake.now(io).nanoseconds,
            1_000_000,
        );
        if (now_ms - started_ms >= timeout_ms) return false;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return true;
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
    const authority_addr = try std.Io.net.IpAddress.parseLiteral(authority);
    const colon_idx = mem.lastIndexOfScalar(u8, authority, ':') orelse return error.InvalidWebSocketUrl;
    return .{
        .host = authority[0..colon_idx],
        .port = authority_addr.getPort(),
        .path = path,
    };
}

fn handshakeClient(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    host: []const u8,
    port: u16,
    path: []const u8,
) !void {
    var random_bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&random_bytes);
    var key_buf: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buf, &random_bytes);

    const request = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\n\r\n",
        .{ path, host, port, key },
    );
    defer allocator.free(request);
    const io = std.Io.Threaded.global_single_threaded.io();
    var stream_writer = stream.writer(io, &.{});
    try stream_writer.interface.writeAll(request);
    try stream_writer.interface.flush();

    var response_buf: std.ArrayList(u8) = .empty;
    defer response_buf.deinit(allocator);
    while (mem.indexOf(u8, response_buf.items, "\r\n\r\n") == null) {
        var tmp: [1]u8 = undefined;
        var stream_reader = stream.reader(io, &.{});
        const n = try stream_reader.interface.readSliceShort(tmp[0..]);
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

fn writeClientFrame(
    self: *Connection,
    opcode: u8,
    payload: []const u8,
    deadline: ?std.Io.Clock.Timestamp,
) !void {
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
    std.Io.Threaded.global_single_threaded.io().random(&mask);
    @memcpy(header[header_len .. header_len + 4], &mask);
    header_len += 4;

    try writeStreamAllUntil(self.stream, header[0..header_len], deadline);
    if (payload_len == 0) {
        return;
    }
    const masked = try self.allocator.dupe(u8, payload);
    defer self.allocator.free(masked);
    applyMask(&mask, masked);
    try writeStreamAllUntil(self.stream, masked, deadline);
}

fn writeStreamAllUntil(
    stream: std.Io.net.Stream,
    bytes: []const u8,
    deadline: ?std.Io.Clock.Timestamp,
) !void {
    if (deadline == null) {
        var stream_writer = stream.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        try stream_writer.interface.writeAll(bytes);
        try stream_writer.interface.flush();
        return;
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining_ms = deadline.?.durationFromNow(io).raw.toMilliseconds();
        if (remaining_ms <= 0) return error.Timeout;
        var fds = [_]std.posix.pollfd{.{
            .fd = stream.socket.handle,
            .events = std.posix.POLL.OUT | std.posix.POLL.ERR,
            .revents = 0,
        }};
        const poll_timeout: i32 = @intCast(@min(remaining_ms, std.math.maxInt(i32)));
        if (try std.posix.poll(&fds, poll_timeout) == 0) return error.Timeout;
        if ((fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            return error.ConnectionResetByPeer;
        }

        var iov = [_]std.posix.iovec_const{.{
            .base = bytes[offset..].ptr,
            .len = bytes.len - offset,
        }};
        var msg: std.posix.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        const rc = std.posix.system.sendmsg(
            stream.socket.handle,
            &msg,
            std.posix.MSG.NOSIGNAL | std.posix.MSG.DONTWAIT,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => offset += @intCast(rc),
            .INTR, .AGAIN => continue,
            .PIPE, .CONNRESET, .NOTCONN => return error.ConnectionResetByPeer,
            else => return error.WebSocketWriteFailed,
        }
    }
}

fn applyMask(mask: *const [4]u8, payload: []u8) void {
    for (payload, 0..) |byte, idx| {
        payload[idx] = byte ^ mask[idx & 3];
    }
}

fn readByte(self: *Connection, deadline: ?std.Io.Clock.Timestamp) !u8 {
    var buf: [1]u8 = undefined;
    try readStreamExact(self.stream, &buf, deadline);
    return buf[0];
}

fn readStreamExact(
    stream: std.Io.net.Stream,
    dest: []u8,
    deadline: ?std.Io.Clock.Timestamp,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var offset: usize = 0;
    while (offset < dest.len) {
        const incoming = if (deadline) |value|
            try stream.socket.receiveTimeout(
                io,
                dest[offset..],
                .{ .deadline = value },
            )
        else
            try stream.socket.receive(io, dest[offset..]);
        if (incoming.data.len == 0) return error.EndOfStream;
        offset += incoming.data.len;
    }
}

test "websocket read deadline bounds a stalled live socket" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var listen_address = try std.Io.net.IpAddress.parse(loopback_host, 0);
    var listener = try listen_address.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    const peer_address = try std.Io.net.IpAddress.parse(loopback_host, port);
    const client_stream = try peer_address.connect(io, .{ .mode = .stream });
    var server_stream = try listener.accept(io);
    defer server_stream.close(io);

    var connection = Connection{
        .allocator = std.testing.allocator,
        .stream = client_stream,
        .read_buf = .empty,
    };
    defer {
        connection.close();
        connection.deinit();
    }
    var server_writer = server_stream.writer(io, &.{});
    try server_writer.interface.writeAll(&.{ 0x81, 0x05, 'h', 'e' });
    try server_writer.interface.flush();

    const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
    try std.testing.expectError(error.Timeout, connection.readTextAllocTimeout(50));
    try std.testing.expectError(error.ConnectionPoisoned, connection.readTextAlloc());
    const elapsed_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000) - started_ms;
    try std.testing.expect(elapsed_ms < 1_000);
}

test "websocket write deadline expires before a frame crosses the socket" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var listen_address = try std.Io.net.IpAddress.parse(loopback_host, 0);
    var listener = try listen_address.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    const peer_address = try std.Io.net.IpAddress.parse(loopback_host, port);
    const client_stream = try peer_address.connect(io, .{ .mode = .stream });
    var server_stream = try listener.accept(io);
    defer server_stream.close(io);

    var connection = Connection{
        .allocator = std.testing.allocator,
        .stream = client_stream,
        .read_buf = .empty,
    };
    defer {
        connection.close();
        connection.deinit();
    }

    try std.testing.expectError(error.Timeout, connection.sendTextTimeout("payload", 0));
    try std.testing.expectError(error.ConnectionPoisoned, connection.sendText("retry"));
}

test "owner-lived watchdog retires its exact server when owner control closes" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const pid_path = try std.fs.path.join(allocator, &.{ root, "server.pid" });
    defer allocator.free(pid_path);
    const listen_url = try allocator.dupe(u8, "ws://127.0.0.1:1");
    errdefer allocator.free(listen_url);
    var managed = try spawnOwnerPipeManagedServer(
        allocator,
        root,
        &.{
            "/bin/sh",
            "-c",
            "printf '%s\\n' \"$$\" > \"$1\"; while :; do sleep 1; done",
            "cas-owner-lived-test-server",
            pid_path,
        },
        listen_url,
        io,
    );
    defer managed.deinit(allocator);
    const watchdog_pid = managed.processId();

    var server_pid: ?u64 = null;
    for (0..100) |_| {
        const pid_bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            pid_path,
            allocator,
            .limited(64),
        ) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        };
        defer allocator.free(pid_bytes);
        server_pid = try std.fmt.parseInt(
            u64,
            std.mem.trim(u8, pid_bytes, " \t\r\n"),
            10,
        );
        break;
    }
    try std.testing.expect(server_pid != null);
    try std.testing.expect(processAlive(watchdog_pid));
    try std.testing.expect(processAlive(server_pid.?));

    managed.kill();
    try std.testing.expect(waitForProcessExit(watchdog_pid, 2_000));
    try std.testing.expect(waitForProcessExit(server_pid.?, 2_000));
}
