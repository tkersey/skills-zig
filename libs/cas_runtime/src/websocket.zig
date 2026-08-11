const std = @import("std");

const builtin = @import("builtin");
const launch = @import("transport.zig");
const hooks = @import("cas_hook_policy");
const mem = std.mem;

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const loopback_host = "127.0.0.1";

pub const max_endpoint_bytes = launch.max_endpoint_bytes;
pub const max_handshake_header_bytes: usize = 16 * 1024;
pub const max_message_bytes: usize = 8 * 1024 * 1024;
pub const max_fragments: usize = 1024;
pub const max_startup_stderr_line_bytes: usize = 4 * 1024;
pub const max_startup_stderr_bytes: usize = 64 * 1024;
pub const max_readyz_bytes: usize = 1024;
pub const default_startup_timeout_ms = launch.default_startup_timeout_ms;

pub const owner_watchdog_shutdown_grace_ms: u32 = 1_000;

pub const ManagedServer = struct {
    child: std.process.Child,
    listen_url: []u8,
    owner_control: ?std.Io.File = null,
    shutdown_receipt_path: ?[]u8 = null,
    shutdown_receipt_token: ?[]u8 = null,
    process_group_id: ?u64 = null,
    boot_id: ?[]u8 = null,
    stopped: bool = false,
    stderr_drainer: ?*StderrDrainer = null,

    pub fn deinit(self: *ManagedServer, allocator: std.mem.Allocator) void {
        if (!self.stopped) self.kill();
        if (self.stderr_drainer) |drainer| {
            drainer.joinAndDestroy();
            self.stderr_drainer = null;
        }
        if (self.shutdown_receipt_token) |value| allocator.free(value);
        if (self.shutdown_receipt_path) |value| allocator.free(value);
        if (self.boot_id) |value| allocator.free(value);
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

    pub fn shutdownReceiptPath(self: *const ManagedServer) ?[]const u8 {
        return self.shutdown_receipt_path;
    }

    pub fn shutdownReceiptToken(self: *const ManagedServer) ?[]const u8 {
        return self.shutdown_receipt_token;
    }

    pub fn processGroupId(self: *const ManagedServer) ?u64 {
        return self.process_group_id;
    }

    pub fn bootId(self: *const ManagedServer) ?[]const u8 {
        return self.boot_id;
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
            };
            if (self.process_group_id) |process_group_id| retireProcessGroup(process_group_id);
        } else {
            if (self.process_group_id) |process_group_id| {
                forceKillProcessGroup(process_group_id);
                _ = self.child.wait(io) catch self.child.kill(io);
                _ = waitForProcessGroupExit(process_group_id, owner_watchdog_shutdown_grace_ms);
            } else {
                self.child.kill(io);
            }
        }
        if (self.stderr_drainer) |drainer| {
            drainer.joinAndDestroy();
            self.stderr_drainer = null;
        }
    }
};

const StderrDrainer = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    thread: std.Thread,

    fn start(allocator: std.mem.Allocator, file: std.Io.File) !*StderrDrainer {
        const state = try allocator.create(StderrDrainer);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .file = file,
            .thread = undefined,
        };
        state.thread = try std.Thread.spawn(.{}, drain, .{state});
        return state;
    }

    fn drain(self: *StderrDrainer) void {
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var buffer: [4096]u8 = undefined;
        var reader = self.file.reader(io, &.{});
        while (reader.interface.readSliceShort(&buffer) catch 0 != 0) {}
        self.file.close(io);
    }

    fn joinAndDestroy(self: *StderrDrainer) void {
        self.thread.join();
        self.allocator.destroy(self);
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    read_buf: std.ArrayList(u8) = .empty,
    write_mutex: std.atomic.Mutex = .unlocked,
    usable: std.atomic.Value(bool) = .init(true),

    pub fn connect(
        allocator: std.mem.Allocator,
        ws_url: []const u8,
        timeout_ms: u32,
    ) !Connection {
        if (ws_url.len == 0 or ws_url.len > max_endpoint_bytes) return error.InvalidWebSocketUrl;
        try launch.validateInboundWebSocket(ws_url);
        const parsed = try parseWsUrl(ws_url);
        const address = try std.Io.net.IpAddress.parse(parsed.host, parsed.port);
        const io = std.Io.Threaded.global_single_threaded.io();
        const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        });
        while (true) { // tiger: event-loop -- bounded by owner state or deadline.
            const stream = address.connect(io, .{ .mode = .stream }) catch |err| {
                const now_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
                if (now_ms - started_ms >= timeout_ms) return err;
                std.Io.sleep(io, .fromMilliseconds(50), .awake) catch |ignored_error| {
                    switch (ignored_error) {
                        else => {},
                    }
                };
                continue;
            };

            handshakeClient(
                allocator,
                stream,
                parsed.host_header,
                parsed.port,
                parsed.path,
                deadline,
            ) catch |err| {
                stream.close(io);
                return switch (err) {
                    error.Timeout => error.ConnectionTimedOut,
                    else => err,
                };
            };

            return .{
                .allocator = allocator,
                .stream = stream,
                .read_buf = .empty,
            };
        }
    }

    pub fn connectUnix(
        allocator: std.mem.Allocator,
        socket_path: []const u8,
        timeout_ms: u32,
    ) !Connection {
        try launch.validateUnixPath(socket_path);
        const address = try std.Io.net.UnixAddress.init(socket_path);
        const io = std.Io.Threaded.global_single_threaded.io();
        const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        });
        while (true) { // tiger: event-loop -- bounded by timeout_ms.
            const stream = address.connect(io) catch |err| switch (err) {
                error.FileNotFound, error.WouldBlock => {
                    const now_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
                    if (now_ms - started_ms >= timeout_ms) return err;
                    std.Io.sleep(
                        io,
                        .fromMilliseconds(25),
                        .awake,
                    ) catch |sleep_err| switch (sleep_err) {
                        else => {},
                    };
                    continue;
                },
                else => return err,
            };
            handshakeClient(allocator, stream, "localhost", 0, "/", deadline) catch |err| {
                stream.close(io);
                return switch (err) {
                    error.Timeout => error.ConnectionTimedOut,
                    else => err,
                };
            };
            return .{ .allocator = allocator, .stream = stream, .read_buf = .empty };
        }
    }

    pub fn close(self: *Connection) void {
        if (self.usable.cmpxchgStrong(true, false, .acq_rel, .acquire) != null) return;
        while (!self.write_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.write_mutex.unlock();
        self.stream.close(std.Io.Threaded.global_single_threaded.io());
    }

    pub fn poison(self: *Connection) void {
        self.close();
    }

    pub fn deinit(self: *Connection) void {
        self.read_buf.deinit(self.allocator);
    }

    pub fn sendText(self: *Connection, payload: []const u8) !void {
        if (!self.usable.load(.acquire)) return error.ConnectionPoisoned;
        if (payload.len > max_message_bytes) return error.WebSocketMessageTooLarge;
        writeClientFrame(self, 0x1, payload, null) catch |err| {
            self.poison();
            return err;
        };
    }

    pub fn sendTextTimeout(self: *Connection, payload: []const u8, timeout_ms: u32) !void {
        if (!self.usable.load(.acquire)) return error.ConnectionPoisoned;
        if (payload.len > max_message_bytes) return error.WebSocketMessageTooLarge;
        const io = std.Io.Threaded.global_single_threaded.io();
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        });
        writeClientFrame(self, 0x1, payload, deadline) catch |err| switch (err) {
            error.WebSocketWriteLockTimeout => return error.Timeout,
            else => {
                self.poison();
                return err;
            },
        };
    }

    pub fn readTextAlloc(self: *Connection) !?[]u8 {
        if (!self.usable.load(.acquire)) return error.ConnectionPoisoned;
        return self.readTextAllocUntil(null);
    }

    pub fn readTextAllocTimeout(self: *Connection, timeout_ms: u32) !?[]u8 {
        if (!self.usable.load(.acquire)) return error.ConnectionPoisoned;
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
        var fragment_count: usize = 0;
        var fragmented: std.ArrayList(u8) = .empty;
        defer fragmented.deinit(self.allocator);

        while (true) { // tiger: event-loop -- bounded by owner state or deadline.
            const frame = self.readFrameAlloc(deadline) catch |err| {
                self.poison();
                return err;
            };
            defer if (frame.payload) |owned| self.allocator.free(owned);

            const outcome = try self.handleDataFrame(
                frame,
                &fragment_type,
                &fragment_count,
                &fragmented,
                deadline,
            );
            switch (outcome) {
                .continue_read => {},
                .closed => return null,
                .message => |message| return message,
            }
        }
    }

    const FrameOutcome = union(enum) { continue_read, closed, message: []u8 };

    fn handleDataFrame(
        self: *Connection,
        frame: Frame,
        fragment_type: *?u8,
        fragment_count: *usize,
        fragmented: *std.ArrayList(u8),
        deadline: ?std.Io.Clock.Timestamp,
    ) !FrameOutcome {
        switch (frame.opcode) {
            0x1 => {
                if (fragment_type.* != null) {
                    return self.protocolFailure(error.WebSocketInvalidFragmentSequence);
                }
                if (frame.fin) {
                    if (!std.unicode.utf8ValidateSlice(frame.payload.?))
                        return self.protocolFailure(error.WebSocketInvalidUtf8);
                    const owned = try self.allocator.dupe(u8, frame.payload.?);
                    return .{ .message = owned };
                }
                fragment_type.* = frame.opcode;
                fragment_count.* = 1;
                fragmented.appendSlice(self.allocator, frame.payload.?) catch |err|
                    return self.protocolFailure(err);
            },
            0x2 => return self.protocolFailure(error.WebSocketBinaryMessageUnsupported),
            0x0 => {
                if (fragment_type.* == null) {
                    return self.protocolFailure(error.WebSocketUnexpectedContinuation);
                }
                fragment_count.* += 1;
                if (fragment_count.* > max_fragments) {
                    return self.protocolFailure(error.WebSocketTooManyFragments);
                }
                if (fragmented.items.len > max_message_bytes - frame.payload.?.len) {
                    return self.protocolFailure(error.WebSocketMessageTooLarge);
                }
                fragmented.appendSlice(self.allocator, frame.payload.?) catch |err|
                    return self.protocolFailure(err);
                if (frame.fin) {
                    if (!std.unicode.utf8ValidateSlice(fragmented.items))
                        return self.protocolFailure(error.WebSocketInvalidUtf8);
                    const owned = fragmented.toOwnedSlice(self.allocator) catch |err|
                        return self.protocolFailure(err);
                    return .{ .message = owned };
                }
            },
            0x8 => {
                if (!validClosePayload(frame.payload.?))
                    return self.protocolFailure(error.WebSocketInvalidClosePayload);
                writeClientFrame(self, 0x8, frame.payload.?, deadline) catch |err| {
                    self.poison();
                    return err;
                };
                self.close();
                return .closed;
            },
            0x9 => writeClientFrame(self, 0xA, frame.payload.?, deadline) catch |err| {
                self.poison();
                return err;
            },
            0xA => {},
            else => return self.protocolFailure(error.WebSocketUnexpectedOpcode),
        }
        return .continue_read;
    }

    fn protocolFailure(self: *Connection, err: anyerror) anyerror {
        self.poison();
        return err;
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
        if ((first & 0x70) != 0) return self.protocolFailure(error.WebSocketReservedBitsSet);
        const fin = (first & 0x80) != 0;
        const opcode = first & 0x0F;
        const masked = (second & 0x80) != 0;
        if (masked) return self.protocolFailure(error.WebSocketMaskedServerFrame);

        var payload_len: u64 = second & 0x7F;
        if (payload_len == 126) {
            var extended: [2]u8 = undefined;
            try readStreamExact(self.stream, &extended, deadline);
            payload_len = mem.readInt(u16, &extended, .big);
            if (payload_len < 126) return self.protocolFailure(error.WebSocketInvalidPayloadLength);
        } else if (payload_len == 127) {
            var extended: [8]u8 = undefined;
            try readStreamExact(self.stream, &extended, deadline);
            if ((extended[0] & 0x80) != 0) {
                return self.protocolFailure(error.WebSocketInvalidPayloadLength);
            }
            payload_len = mem.readInt(u64, &extended, .big);
            if (payload_len <= std.math.maxInt(u16)) {
                return self.protocolFailure(error.WebSocketInvalidPayloadLength);
            }
        }

        const control = (opcode & 0x08) != 0;
        if (control and (!fin or payload_len > 125)) {
            return self.protocolFailure(error.WebSocketInvalidControlFrame);
        }
        if (opcode == 0x8 and payload_len == 1) {
            return self.protocolFailure(error.WebSocketInvalidClosePayload);
        }
        if (payload_len > max_message_bytes) {
            return self.protocolFailure(error.WebSocketMessageTooLarge);
        }
        if (payload_len > std.math.maxInt(usize)) {
            return self.protocolFailure(error.WebSocketMessageTooLarge);
        }

        const payload = if (payload_len == 0)
            try self.allocator.dupe(u8, "")
        else blk: {
            const owned = try self.allocator.alloc(u8, @intCast(payload_len));
            errdefer self.allocator.free(owned);
            try readStreamExact(self.stream, owned, deadline);
            break :blk owned;
        };

        return .{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
        };
    }
};

fn validClosePayload(payload: []const u8) bool {
    if (payload.len == 0) return true;
    if (payload.len == 1) return false;
    const code = (@as(u16, payload[0]) << 8) | payload[1];
    if (code < 1000 or code >= 5000) return false;
    if (code == 1004 or code == 1005 or code == 1006 or code == 1015) return false;
    if (code >= 1016 and code < 2000) return false;
    return std.unicode.utf8ValidateSlice(payload[2..]);
}

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
        null,
        codex_path,
        hook_policy,
        false,
        null,
        io,
    );
}

pub fn startManagedLoopbackServerWithCodeModeHost(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    codex_path: []const u8,
    hook_policy: hooks.HookPolicy,
    code_mode_host: *const launch.CodeModeHost,
    io: std.Io,
) !ManagedServer {
    return startManagedLoopbackServerWithOwnership(
        allocator,
        cwd,
        null,
        codex_path,
        hook_policy,
        false,
        code_mode_host,
        io,
    );
}

pub fn startOwnerLivedLoopbackServer(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    receipt_dir: []const u8,
    codex_path: []const u8,
    hook_policy: hooks.HookPolicy,
    io: std.Io,
) !ManagedServer {
    return startManagedLoopbackServerWithOwnership(
        allocator,
        cwd,
        receipt_dir,
        codex_path,
        hook_policy,
        true,
        null,
        io,
    );
}

pub fn startOwnerLivedLoopbackServerWithCodeModeHost(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    receipt_dir: []const u8,
    codex_path: []const u8,
    hook_policy: hooks.HookPolicy,
    code_mode_host: *const launch.CodeModeHost,
    io: std.Io,
) !ManagedServer {
    return startManagedLoopbackServerWithOwnership(
        allocator,
        cwd,
        receipt_dir,
        codex_path,
        hook_policy,
        true,
        code_mode_host,
        io,
    );
}

fn startManagedLoopbackServerWithOwnership(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    receipt_dir: ?[]const u8,
    codex_path: []const u8,
    hook_policy: hooks.HookPolicy,
    owner_lived: bool,
    code_mode_host: ?*const launch.CodeModeHost,
    io: std.Io,
) !ManagedServer {
    try hooks.ensureLaunchSupportsPolicy(allocator, io, codex_path, cwd, hook_policy);

    const requested_listen_url = "ws://127.0.0.1:0";

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, codex_path);
    try launch.appendAppServerArgs(
        allocator,
        &argv,
        hook_policy == .off,
        requested_listen_url,
        code_mode_host,
    );

    if (owner_lived) return startOwnerLivedServer(
        allocator,
        cwd,
        receipt_dir,
        argv.items,
        requested_listen_url,
        io,
    );
    return startOrdinaryServer(allocator, cwd, argv.items, io);
}

fn startOwnerLivedServer(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    receipt_dir: ?[]const u8,
    argv: []const []const u8,
    requested_listen_url: []const u8,
    io: std.Io,
) !ManagedServer {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.OwnerLivedManagedServerUnsupported;
    }
    const owner_receipt_dir = receipt_dir orelse return error.MissingOwnerLivedReceiptDirectory;
    try std.Io.Dir.cwd().createDirPath(io, owner_receipt_dir);
    const capture_path = try std.fmt.allocPrint(
        allocator,
        "{s}/cas-app-server-startup-{d}.log",
        .{ owner_receipt_dir, std.Io.Clock.real.now(io).nanoseconds },
    );
    defer allocator.free(capture_path);
    defer std.Io.Dir.deleteFileAbsolute(io, capture_path) catch |err| switch (err) {
        else => {},
    };
    const mkfifo = try std.process.run(allocator, io, .{
        .argv = &.{ "/usr/bin/mkfifo", capture_path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(mkfifo.stdout);
    defer allocator.free(mkfifo.stderr);
    const fifo_ok = switch (mkfifo.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!fifo_ok) return error.ManagedStartupPipeCreateFailed;
    var managed = try spawnOwnerPipeManagedServer(
        allocator,
        cwd,
        owner_receipt_dir,
        argv,
        try allocator.dupe(u8, requested_listen_url),
        capture_path,
        io,
    );
    errdefer {
        managed.kill();
        managed.deinit(allocator);
    }
    const startup_pipe = try std.Io.Dir.openFileAbsolute(io, capture_path, .{});
    var pipe_owned = true;
    errdefer if (pipe_owned) startup_pipe.close(io);
    const startup = try readManagedStartup(allocator, startup_pipe, default_startup_timeout_ms);
    defer allocator.free(startup.readyz_url);
    try requireReady(startup.readyz_url, default_startup_timeout_ms);
    managed.stderr_drainer = try StderrDrainer.start(allocator, startup_pipe);
    pipe_owned = false;
    allocator.free(managed.listen_url);
    managed.listen_url = startup.listen_url;
    return managed;
}

fn startOrdinaryServer(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    io: std.Io,
) !ManagedServer {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    });
    const process_group_id: ?u64 = switch (builtin.os.tag) {
        .windows, .wasi => null,
        else => if (child.id) |value| @intCast(value) else null,
    };
    errdefer {
        if (process_group_id) |group_id| {
            forceKillProcessGroup(group_id);
            _ = child.wait(io) catch child.kill(io);
            _ = waitForProcessGroupExit(group_id, owner_watchdog_shutdown_grace_ms);
        } else {
            child.kill(io);
        }
    }
    const stderr_file = child.stderr orelse return error.ChildMissingStderr;
    child.stderr = null;
    var stderr_owned = true;
    errdefer if (stderr_owned) stderr_file.close(io);
    const startup = try readManagedStartup(allocator, stderr_file, default_startup_timeout_ms);
    errdefer allocator.free(startup.listen_url);
    defer allocator.free(startup.readyz_url);
    try requireReady(startup.readyz_url, default_startup_timeout_ms);
    const drainer = try StderrDrainer.start(allocator, stderr_file);
    stderr_owned = false;
    return .{
        .child = child,
        .listen_url = startup.listen_url,
        .stderr_drainer = drainer,
        .process_group_id = process_group_id,
    };
}

const ManagedStartup = struct { listen_url: []u8, readyz_url: []u8 };

fn readManagedStartup(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    timeout_ms: u32,
) !ManagedStartup {
    const io = std.Io.Threaded.global_single_threaded.io();
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(timeout_ms),
        .clock = .awake,
    });
    var total: usize = 0;
    var listening: ?[]u8 = null;
    errdefer if (listening) |owned| allocator.free(owned);
    var readyz: ?[]u8 = null;
    errdefer if (readyz) |owned| allocator.free(owned);
    for (0..16) |_| {
        var line_buf: [max_startup_stderr_line_bytes]u8 = undefined;
        const line = try readFdLine(file, &line_buf, deadline);
        total += line.len + 1;
        if (total > max_startup_stderr_bytes) return error.ManagedStartupOutputTooLarge;
        if (std.mem.startsWith(u8, line, "  listening on: ")) {
            const value = line["  listening on: ".len..];
            try launch.validateInboundWebSocket(value);
            if (!std.mem.startsWith(u8, value, "ws://127.0.0.1:") or
                std.mem.endsWith(u8, value, ":0"))
            {
                return error.InvalidManagedListenAddress;
            }
            if (listening != null) return error.DuplicateManagedListenAddress;
            listening = try allocator.dupe(u8, value);
        } else if (std.mem.startsWith(u8, line, "  readyz: ")) {
            const value = line["  readyz: ".len..];
            if (value.len > max_startup_stderr_line_bytes) return error.ManagedStartupLineTooLong;
            if (readyz != null) return error.DuplicateManagedReadyzAddress;
            readyz = try allocator.dupe(u8, value);
        }
        if (listening != null and readyz != null) {
            const listen_port = portSuffix(listening.?) orelse
                return error.InvalidManagedListenAddress;
            const ready_port = httpLoopbackPort(readyz.?) orelse
                return error.InvalidManagedReadyzAddress;
            if (listen_port != ready_port) return error.ManagedStartupPortMismatch;
            return .{ .listen_url = listening.?, .readyz_url = readyz.? };
        }
    }
    return error.ManagedStartupIncomplete;
}

fn readFdLine(file: std.Io.File, buffer: []u8, deadline: std.Io.Clock.Timestamp) ![]const u8 {
    var used: usize = 0;
    const io = std.Io.Threaded.global_single_threaded.io();
    while (true) { // tiger: event-loop -- bounded by deadline and buffer length.
        const remaining_ms = deadline.durationFromNow(io).raw.toMilliseconds();
        if (remaining_ms <= 0) return error.Timeout;
        var fds = [_]std.posix.pollfd{.{
            .fd = file.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR,
            .revents = 0,
        }};
        if (try std.posix.poll(
            &fds,
            @intCast(@min(remaining_ms, std.math.maxInt(i32))),
        ) == 0) return error.Timeout;
        var byte: [1]u8 = undefined;
        const count = try std.posix.read(file.handle, &byte);
        if (count == 0) return error.EndOfStream;
        if (byte[0] == '\n') return std.mem.trimEnd(u8, buffer[0..used], "\r");
        if (used == buffer.len) return error.ManagedStartupLineTooLong;
        buffer[used] = byte[0];
        used += 1;
    }
}

fn portSuffix(url: []const u8) ?u16 {
    const colon = std.mem.lastIndexOfScalar(u8, url, ':') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, url, colon + 1, '/') orelse url.len;
    return std.fmt.parseInt(u16, url[colon + 1 .. end], 10) catch null;
}

fn httpLoopbackPort(url: []const u8) ?u16 {
    if (!std.mem.startsWith(u8, url, "http://127.0.0.1:")) return null;
    return portSuffix(url);
}

fn requireReady(url: []const u8, timeout_ms: u32) !void {
    if (url.len == 0) return;
    if (url.len > max_readyz_bytes) return error.ManagedReadyzResponseTooLarge;
    const port = httpLoopbackPort(url) orelse return error.InvalidManagedReadyzAddress;
    const address = try std.Io.net.IpAddress.parse(loopback_host, port);
    const io = std.Io.Threaded.global_single_threaded.io();
    const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
    while (true) { // tiger: event-loop -- bounded by timeout_ms.
        const now_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
        if (now_ms - started_ms >= timeout_ms) return error.Timeout;
        const remaining: u32 = @intCast(timeout_ms - @as(u32, @intCast(now_ms - started_ms)));
        checkReadyOnce(address, remaining) catch {
            std.Io.sleep(io, .fromMilliseconds(25), .awake) catch |sleep_err| switch (sleep_err) {
                else => {},
            };
            continue;
        };
        return;
    }
}

fn checkReadyOnce(address: std.Io.net.IpAddress, timeout_ms: u32) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(timeout_ms),
        .clock = .awake,
    });
    try writeStreamAllUntil(
        stream,
        "GET /readyz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        deadline,
    );
    var response: [max_readyz_bytes]u8 = undefined;
    var used: usize = 0;
    while (true) { // tiger: event-loop -- bounded by response length and deadline.
        if (used == response.len) return error.ManagedReadyzResponseTooLarge;
        const incoming = try stream.socket.receiveTimeout(
            io,
            response[used..],
            .{ .deadline = deadline },
        );
        if (incoming.data.len == 0) break;
        used += incoming.data.len;
    }
    const bytes = response[0..used];
    const header_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse
        return error.ManagedReadyzMalformed;
    const status_line_end = std.mem.indexOf(u8, bytes[0..header_end], "\r\n") orelse
        return error.ManagedReadyzMalformed;
    const status_line = bytes[0..status_line_end];
    if ((!std.mem.startsWith(u8, status_line, "HTTP/1.1 200 ") and
        !std.mem.eql(u8, status_line, "HTTP/1.1 200")) and
        (!std.mem.startsWith(u8, status_line, "HTTP/1.0 200 ") and
            !std.mem.eql(u8, status_line, "HTTP/1.0 200")))
        return error.ManagedReadyzRejected;
    if (bytes[header_end + 4 ..].len != 0) return error.ManagedReadyzNonEmptyBody;
}

const owner_watchdog_script =
    \\receipt_path=$1
    \\receipt_token=$2
    \\startup_capture=$3
    \\shift 3
    \\child=0
    \\set -m 2>/dev/null || true
    \\cleanup() {
    \\  if [ "$child" -gt 0 ] 2>/dev/null; then
    \\    kill -TERM -- "-$child" 2>/dev/null || kill "$child" 2>/dev/null || true
    \\    attempts=0
    \\    while kill -0 "$child" 2>/dev/null && [ "$attempts" -lt 20 ]; do
    \\      sleep 0.05
    \\      attempts=$((attempts + 1))
    \\    done
    \\    kill -KILL -- "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || true
    \\    wait "$child" 2>/dev/null || true
    \\  fi
    \\  if [ ! -e "$receipt_path" ]; then
    \\    umask 077
    \\    receipt_tmp="${receipt_path}.tmp.$$"
    \\    printf '{"schema":"CAS-WDR-v1","token":"%s"}\n' "$receipt_token" >"$receipt_tmp" &&
    \\      mv -n "$receipt_tmp" "$receipt_path" 2>/dev/null || true
    \\    rm -f "$receipt_tmp" 2>/dev/null || true
    \\  fi
    \\}
    \\trap cleanup EXIT HUP INT TERM
    \\"$@" 2>"$startup_capture" &
    \\child=$!
    \\while IFS= read -r _; do :; done
;

fn spawnOwnerPipeManagedServer(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    receipt_dir: []const u8,
    server_argv: []const []const u8,
    listen_url: []u8,
    startup_capture_path: ?[]const u8,
    io: std.Io,
) !ManagedServer {
    try std.Io.Dir.cwd().createDirPath(io, receipt_dir);
    const boot_id = try currentBootIdAlloc(allocator);
    errdefer allocator.free(boot_id);
    var receipt_random: [16]u8 = undefined;
    io.random(&receipt_random);
    const receipt_hex = std.fmt.bytesToHex(receipt_random, .lower);
    const shutdown_receipt_token = try std.fmt.allocPrint(
        allocator,
        "{s}",
        .{&receipt_hex},
    );
    errdefer allocator.free(shutdown_receipt_token);
    const shutdown_receipt_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.json",
        .{ receipt_dir, &receipt_hex },
    );
    errdefer allocator.free(shutdown_receipt_path);

    return spawnOwnerPipeWithReceipt(
        allocator,
        cwd,
        server_argv,
        listen_url,
        startup_capture_path,
        io,
        boot_id,
        shutdown_receipt_path,
        shutdown_receipt_token,
    );
}

fn spawnOwnerPipeWithReceipt(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    server_argv: []const []const u8,
    listen_url: []u8,
    startup_capture_path: ?[]const u8,
    io: std.Io,
    boot_id: []u8,
    shutdown_receipt_path: []u8,
    shutdown_receipt_token: []u8,
) !ManagedServer {
    var watchdog_argv: std.ArrayList([]const u8) = .empty;
    defer watchdog_argv.deinit(allocator);
    try watchdog_argv.appendSlice(allocator, &.{
        "/bin/sh",
        "-c",
        owner_watchdog_script,
        "cas-app-server-watchdog",
        shutdown_receipt_path,
        shutdown_receipt_token,
        startup_capture_path orelse "/dev/null",
    });
    try watchdog_argv.appendSlice(allocator, server_argv);

    if (builtin.os.tag == .macos and builtin.link_libc) {
        return spawnOwnerPipeManagedServerPosix(
            allocator,
            cwd,
            watchdog_argv.items,
            listen_url,
            shutdown_receipt_path,
            shutdown_receipt_token,
            boot_id,
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
        .shutdown_receipt_path = shutdown_receipt_path,
        .shutdown_receipt_token = shutdown_receipt_token,
        .process_group_id = switch (builtin.os.tag) {
            .windows, .wasi => null,
            else => if (child.id) |value| @intCast(value) else null,
        },
        .boot_id = boot_id,
    };
}

fn spawnOwnerPipeManagedServerPosix(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    watchdog_argv: []const []const u8,
    listen_url: []u8,
    shutdown_receipt_path: []u8,
    shutdown_receipt_token: []u8,
    boot_id: []u8,
) !ManagedServer {
    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.SystemResources;
    var read_open = true;
    var write_open = true;
    defer closeFdIf(read_open, pipe_fds[0]);
    errdefer closeFdIf(write_open, pipe_fds[1]);
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

    var attributes: std.c.posix_spawnattr_t = undefined;
    if (std.c.posix_spawnattr_init(&attributes) != 0) {
        return error.SpawnAttributesFailed;
    }
    defer _ = std.c.posix_spawnattr_destroy(&attributes);
    const group_flags = std.c.posix_spawnattr_setflags(&attributes, .{ .SETPGROUP = true });
    if (group_flags != 0 or posix_spawnattr_setpgroup(&attributes, 0) != 0) {
        return error.SpawnAttributesFailed;
    }

    try configureSpawnActions(allocator, cwd, pipe_fds, &actions);
    const pid = try posixSpawnArgv(allocator, watchdog_argv, &actions, &attributes);

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
        .shutdown_receipt_path = shutdown_receipt_path,
        .shutdown_receipt_token = shutdown_receipt_token,
        .process_group_id = @intCast(pid),
        .boot_id = boot_id,
    };
}

fn closeFdIf(open: bool, fd: std.c.fd_t) void {
    if (open) _ = std.c.close(fd);
}

fn configureSpawnActions(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    pipe_fds: [2]std.c.fd_t,
    actions: *std.c.posix_spawn_file_actions_t,
) !void {
    const cwd_storage = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_storage);
    if (std.c.posix_spawn_file_actions_addchdir_np(actions, cwd_storage.ptr) != 0) {
        return error.SpawnFileActionsFailed;
    }
    if (pipe_fds[0] != 0 and
        (std.c.posix_spawn_file_actions_adddup2(actions, pipe_fds[0], 0) != 0 or
            std.c.posix_spawn_file_actions_addclose(actions, pipe_fds[0]) != 0))
    {
        return error.SpawnFileActionsFailed;
    }
    if (pipe_fds[1] != 0 and
        std.c.posix_spawn_file_actions_addclose(actions, pipe_fds[1]) != 0)
    {
        return error.SpawnFileActionsFailed;
    }
    const write_null: c_int = @bitCast(std.c.O{ .ACCMODE = .WRONLY });
    if (std.c.posix_spawn_file_actions_addopen(actions, 1, "/dev/null", write_null, 0) != 0 or
        std.c.posix_spawn_file_actions_addopen(actions, 2, "/dev/null", write_null, 0) != 0)
    {
        return error.SpawnFileActionsFailed;
    }
}

fn posixSpawnArgv(
    allocator: std.mem.Allocator,
    source_argv: []const []const u8,
    actions: *std.c.posix_spawn_file_actions_t,
    attributes: *std.c.posix_spawnattr_t,
) !std.c.pid_t {
    var argv = try allocator.allocSentinel(?[*:0]const u8, source_argv.len, null);
    defer allocator.free(argv);
    var storage = try allocator.alloc([:0]u8, source_argv.len);
    var count: usize = 0;
    defer {
        for (storage[0..count]) |arg| allocator.free(arg);
        allocator.free(storage);
    }
    for (source_argv, 0..) |arg, index| {
        storage[index] = try allocator.dupeZ(u8, arg);
        count += 1;
        argv[index] = storage[index].ptr;
    }
    var pid: std.c.pid_t = undefined;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const rc = std.c.posix_spawn(&pid, argv[0].?, actions, attributes, argv.ptr, envp);
    if (rc != 0) return posixSpawnError(rc);
    return pid;
}

extern "c" fn posix_spawnattr_setpgroup(
    attr: *std.c.posix_spawnattr_t,
    process_group: std.c.pid_t,
) c_int;

pub fn spawnDetachedProcess(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    io: std.Io,
) !std.process.Child {
    if (builtin.os.tag == .macos and builtin.link_libc) {
        return spawnManagedServerPosix(allocator, cwd, argv);
    }
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
    if (std.c.posix_spawn_file_actions_addchdir_np(&actions, cwd_storage.ptr) != 0) {
        return error.SpawnFileActionsFailed;
    }
    const read_null: c_int = @bitCast(std.c.O{ .ACCMODE = .RDONLY });
    const write_null: c_int = @bitCast(std.c.O{ .ACCMODE = .WRONLY });
    if (std.c.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", read_null, 0) != 0)
        return error.SpawnFileActionsFailed;
    if (std.c.posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", write_null, 0) != 0)
        return error.SpawnFileActionsFailed;
    if (std.c.posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", write_null, 0) != 0)
        return error.SpawnFileActionsFailed;

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
            const pid = std.math.cast(std.posix.pid_t, process_id) orelse
                break :blk true;
            std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
                error.ProcessNotFound => break :blk false,
                else => break :blk true,
            };
            break :blk true;
        },
    };
}

pub fn processGroupAlive(process_group_id: u64) bool {
    return switch (builtin.os.tag) {
        .windows, .wasi => true,
        else => blk: {
            const positive = std.math.cast(std.posix.pid_t, process_group_id) orelse
                break :blk true;
            std.posix.kill(-positive, @enumFromInt(0)) catch |err| switch (err) {
                error.ProcessNotFound => break :blk false,
                else => break :blk true,
            };
            break :blk true;
        },
    };
}

pub fn waitForProcessGroupExit(process_group_id: u64, timeout_ms: u32) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const started_ms = @divFloor(
        std.Io.Clock.awake.now(io).nanoseconds,
        1_000_000,
    );
    while (processGroupAlive(process_group_id)) {
        const now_ms = @divFloor(
            std.Io.Clock.awake.now(io).nanoseconds,
            1_000_000,
        );
        if (now_ms - started_ms >= timeout_ms) return false;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |err| switch (err) {
            else => {},
        };
    }
    return true;
}

fn retireProcessGroup(process_group_id: u64) void {
    switch (builtin.os.tag) {
        .windows, .wasi => return,
        else => {
            const positive = std.math.cast(std.posix.pid_t, process_group_id) orelse return;
            std.posix.kill(-positive, std.posix.SIG.TERM) catch |err| switch (err) {
                error.ProcessNotFound => return,
                else => {},
            };
            if (waitForProcessGroupExit(process_group_id, owner_watchdog_shutdown_grace_ms)) return;
            std.posix.kill(-positive, std.posix.SIG.KILL) catch |err| switch (err) {
                else => {},
            };
            _ = waitForProcessGroupExit(process_group_id, owner_watchdog_shutdown_grace_ms);
        },
    }
}

pub fn forceKillProcessGroup(process_group_id: u64) void {
    switch (builtin.os.tag) {
        .windows, .wasi => return,
        else => {
            const positive = std.math.cast(std.posix.pid_t, process_group_id) orelse return;
            std.posix.kill(-positive, std.posix.SIG.KILL) catch |err| switch (err) {
                else => {},
            };
        },
    }
}

pub fn currentBootIdAlloc(allocator: std.mem.Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .macos => blk: {
            if (!builtin.link_libc) return error.SystemBootIdentityUnsupported;
            var boot_time: std.c.timeval = undefined;
            var boot_time_len: usize = @sizeOf(std.c.timeval);
            if (std.c.sysctlbyname(
                "kern.boottime",
                &boot_time,
                &boot_time_len,
                null,
                0,
            ) != 0 or boot_time_len != @sizeOf(std.c.timeval)) {
                return error.SystemBootIdentityUnavailable;
            }
            break :blk try std.fmt.allocPrint(
                allocator,
                "darwin:{d}:{d}",
                .{ boot_time.sec, boot_time.usec },
            );
        },
        .linux => blk: {
            const io = std.Io.Threaded.global_single_threaded.io();
            var file = try std.Io.Dir.openFileAbsolute(
                io,
                "/proc/sys/kernel/random/boot_id",
                .{},
            );
            defer file.close(io);
            var reader = file.reader(io, &.{});
            var raw: [256]u8 = undefined;
            const raw_len = try reader.interface.readSliceShort(&raw);
            const trimmed = std.mem.trim(u8, raw[0..raw_len], " \t\r\n");
            if (trimmed.len == 0) return error.SystemBootIdentityUnavailable;
            break :blk try allocator.dupe(u8, trimmed);
        },
        else => error.SystemBootIdentityUnsupported,
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
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |err| switch (err) {
            else => {},
        };
    }
    return true;
}

pub fn terminateProcess(process_id: u64) void {
    switch (builtin.os.tag) {
        .windows, .wasi => {},
        else => {
            const pid: std.posix.pid_t = @intCast(process_id);
            std.posix.kill(pid, std.posix.SIG.TERM) catch |ignored_error| {
                switch (ignored_error) {
                    else => {},
                }
            };
        },
    }
}

const ParsedWsUrl = struct {
    host: []const u8,
    host_header: []const u8,
    port: u16,
    path: []const u8,
};

fn parseWsUrl(ws_url: []const u8) !ParsedWsUrl {
    if (!mem.startsWith(u8, ws_url, "ws://")) return error.InvalidWebSocketUrl;
    const remainder = ws_url["ws://".len..];
    const slash_idx = mem.indexOfScalar(u8, remainder, '/') orelse remainder.len;
    const authority = remainder[0..slash_idx];
    const path = if (slash_idx < remainder.len) remainder[slash_idx..] else "/";
    const colon_idx = mem.lastIndexOfScalar(u8, authority, ':') orelse
        return error.InvalidWebSocketUrl;
    const port = std.fmt.parseInt(
        u16,
        authority[colon_idx + 1 ..],
        10,
    ) catch return error.InvalidWebSocketUrl;
    const raw_host = authority[0..colon_idx];
    const host = if (raw_host.len >= 2 and raw_host[0] == '[' and raw_host[raw_host.len - 1] == ']')
        raw_host[1 .. raw_host.len - 1]
    else if (std.ascii.eqlIgnoreCase(raw_host, "localhost") or
        std.ascii.eqlIgnoreCase(raw_host, "localhost."))
        "127.0.0.1"
    else
        raw_host;
    return .{
        .host = host,
        .host_header = raw_host,
        .port = port,
        .path = path,
    };
}

fn handshakeClient(
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    host: []const u8,
    port: u16,
    path: []const u8,
    deadline: ?std.Io.Clock.Timestamp,
) !void {
    var random_bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&random_bytes);
    var key_buf: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buf, &random_bytes);

    const request = try handshakeRequestAlloc(allocator, host, port, path, key);
    defer allocator.free(request);
    try writeStreamAllUntil(stream, request, deadline);

    var response_buf: std.ArrayList(u8) = .empty;
    defer response_buf.deinit(allocator);
    while (mem.indexOf(u8, response_buf.items, "\r\n\r\n") == null) {
        if (response_buf.items.len >= max_handshake_header_bytes) {
            return error.WebSocketHandshakeHeadersTooLarge;
        }
        var tmp: [1]u8 = undefined;
        readStreamExact(stream, &tmp, deadline) catch |err| switch (err) {
            error.EndOfStream => return error.WebSocketHandshakeClosed,
            else => return err,
        };
        try response_buf.append(allocator, tmp[0]);
    }

    try validateHandshakeResponse(response_buf.items, key);
}

fn handshakeRequestAlloc(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    key: []const u8,
) ![]u8 {
    const host_line = if (port == 0)
        try allocator.dupe(u8, host)
    else
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
    defer allocator.free(host_line);
    return std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n\r\n",
        .{ path, host_line, key },
    );
}

fn validateHandshakeResponse(response: []const u8, key: []const u8) !void {
    const header_end = mem.indexOf(u8, response, "\r\n\r\n").? + 4;
    const headers = response[0..header_end];
    const status_line_end = mem.indexOf(u8, headers, "\r\n") orelse
        return error.WebSocketHandshakeRejected;
    const status_line = headers[0..status_line_end];
    if (!mem.startsWith(u8, status_line, "HTTP/1.1 101 ") and
        !mem.eql(u8, status_line, "HTTP/1.1 101")) return error.WebSocketHandshakeRejected;
    const upgrade = headerValue(headers, "upgrade") orelse return error.WebSocketMissingUpgrade;
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return error.WebSocketInvalidUpgrade;
    const connection = headerValue(headers, "connection") orelse
        return error.WebSocketMissingConnection;
    if (!headerHasToken(connection, "upgrade")) return error.WebSocketInvalidConnection;
    const accept = headerValue(
        headers,
        "sec-websocket-accept",
    ) orelse return error.WebSocketMissingAccept;

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(websocket_guid);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    var accept_buf: [28]u8 = undefined;
    const expected = std.base64.standard.Encoder.encode(&accept_buf, &digest);
    if (!mem.eql(u8, accept, expected)) return error.WebSocketInvalidAccept;
}

fn headerHasToken(value: []const u8, expected: []const u8) bool {
    var tokens = mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(mem.trim(u8, token, " \t"), expected)) return true;
    }
    return false;
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
    const io = std.Io.Threaded.global_single_threaded.io();
    while (!self.write_mutex.tryLock()) {
        if (deadline) |limit| {
            if (limit.durationFromNow(io).raw.nanoseconds <= 0) {
                return error.WebSocketWriteLockTimeout;
            }
        }
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch |ignored_error| {
            switch (ignored_error) {
                else => {},
            }
        };
    }
    defer self.write_mutex.unlock();
    if (!self.usable.load(.acquire)) return error.ConnectionPoisoned;
    if (deadline) |limit| {
        if (limit.durationFromNow(io).raw.nanoseconds <= 0) return error.Timeout;
    }
    const payload_len = payload.len;
    const masked = if (payload_len == 0) null else try self.allocator.dupe(u8, payload);
    defer if (masked) |owned| self.allocator.free(owned);

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
    if (masked) |owned| applyMask(&mask, owned);
    @memcpy(header[header_len .. header_len + 4], &mask);
    header_len += 4;

    try writeStreamAllUntil(self.stream, header[0..header_len], deadline);
    if (payload_len == 0) {
        return;
    }
    try writeStreamAllUntil(self.stream, masked.?, deadline);
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

fn expectRawServerFrameError(comptime expected: anyerror, bytes: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var listen_address = try std.Io.net.IpAddress.parse(loopback_host, 0);
    var listener = try listen_address.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    const peer_address = try std.Io.net.IpAddress.parse(loopback_host, port);
    const client_stream = try peer_address.connect(io, .{ .mode = .stream });
    var server_stream = try listener.accept(io);
    defer server_stream.close(io);
    var writer = server_stream.writer(io, &.{});
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    var connection = Connection{ .allocator = std.testing.allocator, .stream = client_stream };
    defer connection.deinit();
    try std.testing.expectError(expected, connection.readTextAllocTimeout(500));
    try std.testing.expect(!connection.usable.load(.acquire));
}

fn expectRawServerClose(bytes: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var listen_address = try std.Io.net.IpAddress.parse(loopback_host, 0);
    var listener = try listen_address.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    const peer_address = try std.Io.net.IpAddress.parse(loopback_host, port);
    const client_stream = try peer_address.connect(io, .{ .mode = .stream });
    var server_stream = try listener.accept(io);
    defer server_stream.close(io);
    var writer = server_stream.writer(io, &.{});
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    var connection = Connection{ .allocator = std.testing.allocator, .stream = client_stream };
    defer connection.deinit();
    try std.testing.expect((try connection.readTextAllocTimeout(500)) == null);
    try std.testing.expect(!connection.usable.load(.acquire));
    try std.testing.expectError(error.ConnectionPoisoned, connection.sendText("after-close"));
}

test "server frame protocol violations poison before allocation" {
    try expectRawServerFrameError(error.WebSocketReservedBitsSet, &.{ 0xC1, 0x00 });
    try expectRawServerFrameError(error.WebSocketMaskedServerFrame, &.{ 0x81, 0x80 });
    try expectRawServerFrameError(error.WebSocketBinaryMessageUnsupported, &.{ 0x82, 0x00 });
    try expectRawServerFrameError(error.WebSocketInvalidControlFrame, &.{ 0x09, 0x00 });
    try expectRawServerFrameError(error.WebSocketUnexpectedContinuation, &.{ 0x80, 0x00 });
    try expectRawServerFrameError(
        error.WebSocketMessageTooLarge,
        &.{ 0x81, 0x7F, 0, 0, 0, 0, 0, 128, 0, 1 },
    );
    try expectRawServerFrameError(
        error.WebSocketInvalidPayloadLength,
        &.{ 0x81, 0x7F, 0x80, 0, 0, 0, 0, 0, 0, 1 },
    );
    try expectRawServerFrameError(error.WebSocketInvalidPayloadLength, &.{ 0x81, 0x7E, 0, 1, 'x' });
    try expectRawServerFrameError(
        error.WebSocketInvalidPayloadLength,
        &.{ 0x81, 0x7F, 0, 0, 0, 0, 0, 0, 0, 126 },
    );
    try expectRawServerFrameError(error.WebSocketInvalidClosePayload, &.{ 0x88, 0x01, 0x00 });
    try expectRawServerFrameError(error.WebSocketInvalidClosePayload, &.{ 0x88, 0x02, 0x03, 0xEE });
    try expectRawServerFrameError(
        error.WebSocketInvalidClosePayload,
        &.{ 0x88, 0x03, 0x03, 0xE8, 0xFF },
    );
    try expectRawServerFrameError(error.WebSocketInvalidUtf8, &.{ 0x81, 0x01, 0xFF });

    var fragments: [2 * (max_fragments + 1)]u8 = undefined;
    fragments[0] = 0x01;
    fragments[1] = 0x00;
    for (1..max_fragments + 1) |index| {
        fragments[index * 2] = 0x00;
        fragments[index * 2 + 1] = 0x00;
    }
    try expectRawServerFrameError(error.WebSocketTooManyFragments, &fragments);
    try expectRawServerClose(&.{ 0x88, 0x02, 0x03, 0xE8 });
}

test "client write mutex acquisition obeys the caller deadline" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var listen_address = try std.Io.net.IpAddress.parse(loopback_host, 0);
    var listener = try listen_address.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    const peer_address = try std.Io.net.IpAddress.parse(
        loopback_host,
        listener.socket.address.getPort(),
    );
    const client_stream = try peer_address.connect(io, .{ .mode = .stream });
    var server_stream = try listener.accept(io);
    defer server_stream.close(io);
    var connection = Connection{ .allocator = std.testing.allocator, .stream = client_stream };
    defer connection.deinit();
    while (!connection.write_mutex.tryLock()) std.atomic.spinLoopHint();
    defer connection.write_mutex.unlock();
    try std.testing.expectError(error.Timeout, connection.sendTextTimeout("blocked", 5));
    try std.testing.expect(connection.usable.load(.acquire));
}

const ConnectionCloseProbe = struct {
    connection: *Connection,
    release_writer: std.atomic.Value(bool) = .init(false),
    writer_locked: std.atomic.Value(bool) = .init(false),
    close_finished: std.atomic.Value(bool) = .init(false),

    fn holdWriter(self: *ConnectionCloseProbe) void {
        while (!self.connection.write_mutex.tryLock()) std.atomic.spinLoopHint();
        self.writer_locked.store(true, .release);
        while (!self.release_writer.load(.acquire)) std.atomic.spinLoopHint();
        self.connection.write_mutex.unlock();
    }

    fn close(self: *ConnectionCloseProbe) void {
        self.connection.close();
        self.close_finished.store(true, .release);
    }
};

test "connection close serializes with the active frame writer" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var listen_address = try std.Io.net.IpAddress.parse(loopback_host, 0);
    var listener = try listen_address.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    const peer_address = try std.Io.net.IpAddress.parse(
        loopback_host,
        listener.socket.address.getPort(),
    );
    const client_stream = try peer_address.connect(io, .{ .mode = .stream });
    var server_stream = try listener.accept(io);
    defer server_stream.close(io);
    var connection = Connection{ .allocator = std.testing.allocator, .stream = client_stream };
    defer connection.deinit();
    var probe = ConnectionCloseProbe{ .connection = &connection };
    const writer = try std.Thread.spawn(.{}, ConnectionCloseProbe.holdWriter, .{&probe});
    while (!probe.writer_locked.load(.acquire)) std.atomic.spinLoopHint();
    const closer = try std.Thread.spawn(.{}, ConnectionCloseProbe.close, .{&probe});
    try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    try std.testing.expect(!probe.close_finished.load(.acquire));
    probe.release_writer.store(true, .release);
    writer.join();
    closer.join();
    try std.testing.expect(probe.close_finished.load(.acquire));
}

test "websocket endpoint parsing separates socket host from exact Host authority" {
    const localhost = try parseWsUrl("ws://localhost.:41/");
    try std.testing.expectEqualStrings("127.0.0.1", localhost.host);
    try std.testing.expectEqualStrings("localhost.", localhost.host_header);
    const ipv6 = try parseWsUrl("ws://[::1]:42/");
    try std.testing.expectEqualStrings("::1", ipv6.host);
    try std.testing.expectEqualStrings("[::1]", ipv6.host_header);
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

test "websocket HTTP upgrade shares the finite connection deadline" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var listen_address = try std.Io.net.IpAddress.parse(loopback_host, 0);
    var listener = try listen_address.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    const peer_address = try std.Io.net.IpAddress.parse(loopback_host, port);
    const client_stream = try peer_address.connect(io, .{ .mode = .stream });
    defer client_stream.close(io);
    var server_stream = try listener.accept(io);
    defer server_stream.close(io);

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromMilliseconds(50),
        .clock = .awake,
    });
    const started_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
    try std.testing.expectError(
        error.Timeout,
        handshakeClient(std.testing.allocator, client_stream, loopback_host, port, "/", deadline),
    );
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
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const pid_path = try std.fs.path.join(allocator, &.{ root, "server.pid" });
    defer allocator.free(pid_path);
    const listen_url = try allocator.dupe(u8, "ws://127.0.0.1:1");
    var managed = spawnOwnerPipeManagedServer(
        allocator,
        root,
        root,
        &.{
            "/bin/sh",
            "-c",
            "sleep 600 & descendant=$!; pid_tmp=\"$1.tmp\"; " ++
                "printf '%s %s\\n' \"$$\" \"$descendant\" > \"$pid_tmp\"; " ++
                "mv \"$pid_tmp\" \"$1\"; while :; do sleep 1; done",
            "cas-owner-lived-test-server",
            pid_path,
        },
        listen_url,
        null,
        io,
    ) catch |err| {
        allocator.free(listen_url);
        return err;
    };
    defer managed.deinit(allocator);
    const watchdog_pid = managed.processId();
    try std.testing.expectEqual(watchdog_pid, managed.processGroupId().?);
    try std.testing.expect(managed.bootId().?.len > 0);

    const process_ids = try awaitOwnerProcessIds(allocator, io, pid_path);
    const server_pid = process_ids.server;
    const descendant_pid = process_ids.descendant;
    try std.testing.expect(processAlive(watchdog_pid));
    try std.testing.expect(processAlive(server_pid));
    try std.testing.expect(processAlive(descendant_pid));
    const receipt_path = managed.shutdownReceiptPath().?;
    const receipt_token = managed.shutdownReceiptToken().?;
    try std.testing.expectEqualStrings(root, std.fs.path.dirname(receipt_path).?);

    managed.kill();
    try std.testing.expect(waitForProcessExit(watchdog_pid, 2_000));
    try std.testing.expect(waitForProcessExit(server_pid, 2_000));
    try std.testing.expect(waitForProcessExit(descendant_pid, 2_000));
    try std.testing.expect(waitForProcessGroupExit(managed.processGroupId().?, 2_000));
    try verifyShutdownReceipt(allocator, io, receipt_path, receipt_token);
}

const OwnerProcessIds = struct { server: u64, descendant: u64 };

fn awaitOwnerProcessIds(
    allocator: std.mem.Allocator,
    io: std.Io,
    pid_path: []const u8,
) !OwnerProcessIds {
    for (0..500) |_| {
        const pid_bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            pid_path,
            allocator,
            .limited(64),
        ) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |err| switch (err) {
                else => {},
            };
            continue;
        };
        defer allocator.free(pid_bytes);
        var pid_fields = std.mem.tokenizeAny(u8, pid_bytes, " \t\r\n");
        const server_pid = try std.fmt.parseInt(
            u64,
            pid_fields.next() orelse return error.InvalidPidFixture,
            10,
        );
        const descendant_pid = try std.fmt.parseInt(
            u64,
            pid_fields.next() orelse return error.InvalidPidFixture,
            10,
        );
        return .{ .server = server_pid, .descendant = descendant_pid };
    }
    return error.InvalidPidFixture;
}

fn verifyShutdownReceipt(
    allocator: std.mem.Allocator,
    io: std.Io,
    receipt_path: []const u8,
    receipt_token: []const u8,
) !void {
    const receipt = try std.Io.Dir.cwd().readFileAlloc(
        io,
        receipt_path,
        allocator,
        .limited(4096),
    );
    defer allocator.free(receipt);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, receipt, .{});
    defer parsed.deinit();
    const receipt_object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidShutdownReceipt,
    };
    try std.testing.expectEqualStrings(
        "CAS-WDR-v1",
        receipt_object.get("schema").?.string,
    );
    try std.testing.expectEqualStrings(
        receipt_token,
        receipt_object.get("token").?.string,
    );
}

test "ordinary managed teardown retires its process group descendants" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const pid_path = try std.fs.path.join(allocator, &.{ root, "ordinary.pid" });
    defer allocator.free(pid_path);
    const script =
        "trap '' TERM; sleep 600 & descendant=$!; pid_tmp=\"$1.tmp\"; " ++
        "printf '%s %s\\n' \"$$\" \"$descendant\" > \"$pid_tmp\"; " ++
        "mv \"$pid_tmp\" \"$1\"; wait";
    const child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", script, "cas-ordinary-managed-test", pid_path },
        .cwd = .{ .path = root },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const child_pid: u64 = @intCast(child.id.?);
    var managed = ManagedServer{
        .child = child,
        .listen_url = try allocator.dupe(u8, "ws://127.0.0.1:1"),
        .process_group_id = child_pid,
    };
    var deinitialized = false;
    defer if (!deinitialized) managed.deinit(allocator);

    var server_pid: ?u64 = null;
    var descendant_pid: ?u64 = null;
    for (0..500) |_| {
        const pid_bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            pid_path,
            allocator,
            .limited(64),
        ) catch {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch |err| switch (err) {
                else => {},
            };
            continue;
        };
        defer allocator.free(pid_bytes);
        var fields = std.mem.tokenizeAny(u8, pid_bytes, " \t\r\n");
        server_pid = try std.fmt.parseInt(
            u64,
            fields.next() orelse return error.InvalidPidFixture,
            10,
        );
        descendant_pid = try std.fmt.parseInt(
            u64,
            fields.next() orelse return error.InvalidPidFixture,
            10,
        );
        break;
    }
    try std.testing.expectEqual(child_pid, server_pid.?);
    try std.testing.expect(processAlive(descendant_pid.?));

    managed.deinit(allocator);
    deinitialized = true;
    try std.testing.expect(waitForProcessExit(server_pid.?, 2_000));
    try std.testing.expect(waitForProcessExit(descendant_pid.?, 2_000));
    try std.testing.expect(waitForProcessGroupExit(child_pid, 2_000));
}

test "ordinary managed startup failure retires its process group descendants" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "malformed-codex" });
    defer allocator.free(executable);
    const pid_path = try std.fs.path.join(allocator, &.{ root, "malformed.pid" });
    defer allocator.free(pid_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n" ++
            "set -eu\n" ++
            "sleep 600 & descendant=$!\n" ++
            "printf '%s %s\\n' \"$$\" \"$descendant\" > '{s}'\n" ++
            "i=0\n" ++
            "while [ \"$i\" -lt 16 ]; do " ++
            "printf 'malformed\\n' >&2; i=$((i + 1)); done\n" ++
            "wait\n",
        .{pid_path},
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "malformed-codex", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        executable,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );

    try std.testing.expectError(
        error.ManagedStartupIncomplete,
        startManagedLoopbackServer(allocator, root, executable, .inherit, io),
    );

    const pid_bytes = try tmp.dir.readFileAlloc(io, "malformed.pid", allocator, .limited(64));
    defer allocator.free(pid_bytes);
    var fields = std.mem.tokenizeAny(u8, pid_bytes, " \t\r\n");
    const server_pid = try std.fmt.parseInt(
        u64,
        fields.next() orelse return error.InvalidPidFixture,
        10,
    );
    const descendant_pid = try std.fmt.parseInt(
        u64,
        fields.next() orelse return error.InvalidPidFixture,
        10,
    );
    try std.testing.expect(waitForProcessExit(server_pid, 2_000));
    try std.testing.expect(waitForProcessExit(descendant_pid, 2_000));
    try std.testing.expect(waitForProcessGroupExit(server_pid, 2_000));
}
