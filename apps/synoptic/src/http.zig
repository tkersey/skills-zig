const std = @import("std");
const App = @import("app.zig").App;
const config = @import("config.zig");
const github = @import("github.zig");
const sessions = @import("sessions.zig");
const tools = @import("tools.zig");
const ui = @import("ui_protocol.zig");
const worktree = @import("worktree.zig");

const DomainMutex = struct {
    state: std.Io.Mutex = .init,
    io: ?std.Io = null,

    fn lock(self: *DomainMutex) void {
        self.state.lockUncancelable(self.io orelse unreachable);
    }

    fn unlock(self: *DomainMutex) void {
        self.state.unlock(self.io orelse unreachable);
    }
};

pub const ToolDomainContext = struct {
    allocator: std.mem.Allocator,
    app: *App,
    registry: *sessions.Registry,
    broker: github.Broker,
    owner: []const u8,
    name: []const u8,
    number: u64,
    pull_request_id: []const u8,
    mutex: DomainMutex,

    pub fn create(
        allocator: std.mem.Allocator,
        app: *App,
        registry: *sessions.Registry,
        broker: github.Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        pull_request_id: []const u8,
    ) !*ToolDomainContext {
        const context = try allocator.create(ToolDomainContext);
        context.* = .{
            .allocator = allocator,
            .app = app,
            .registry = registry,
            .broker = broker,
            .owner = owner,
            .name = name,
            .number = number,
            .pull_request_id = pull_request_id,
            .mutex = .{ .io = broker.io },
        };
        return context;
    }

    pub fn handler(self: *ToolDomainContext) sessions.AuthoritativeToolHandler {
        return .{ .context = self, .handle = handleOpaque, .deinit = deinitOpaque };
    }

    pub fn pendingActionCount(self: *ToolDomainContext) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.app.action_store.cards.items.len;
    }

    pub fn fileQueued(self: *ToolDomainContext, path: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.app.generation.queued(path);
    }

    pub fn lock(self: *ToolDomainContext) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *ToolDomainContext) void {
        self.mutex.unlock();
    }

    fn deinitOpaque(raw: *anyopaque) void {
        const self: *ToolDomainContext = @ptrCast(@alignCast(raw));
        self.allocator.destroy(self);
    }

    fn handleOpaque(
        raw: *anyopaque,
        event_kind: []const u8,
        raw_json: []const u8,
        session_id: []const u8,
        result_allocator: std.mem.Allocator,
    ) ![]u8 {
        const self: *ToolDomainContext = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (std.mem.eql(u8, event_kind, "action.prepared")) {
            const card = try self.prepareAction(raw_json, session_id);
            return std.fmt.allocPrint(
                result_allocator,
                "{{\"cardId\":{f}}}",
                .{std.json.fmt(card.id, .{})},
            );
        }
        if (std.mem.eql(u8, event_kind, "file.complete.requested")) {
            const receipt = try result_allocator.dupe(u8, "{\"status\":\"viewed\"}");
            errdefer result_allocator.free(receipt);
            try self.completeFile(session_id);
            return receipt;
        }
        if (std.mem.eql(u8, event_kind, "session.close.requested")) {
            const receipt = try result_allocator.dupe(u8, "{\"status\":\"closed\"}");
            errdefer result_allocator.free(receipt);
            try self.closeSession(session_id);
            return receipt;
        }
        return error.UnsupportedAuthoritativeTool;
    }

    fn prepareAction(
        self: *ToolDomainContext,
        raw_json: []const u8,
        session_id: []const u8,
    ) !tools.ActionCard {
        const input = try tools.decodePreparedAction(self.allocator, raw_json);
        defer input.deinit(self.allocator);
        const identity = try self.registry.sessionIdentity(session_id);
        defer identity.deinit();
        try tools.validateAgainstSession(input, identity.path);
        const repository = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.owner, self.name },
        );
        defer self.allocator.free(repository);
        const turn_id = try toolTurnIdAlloc(self.allocator, raw_json, identity.turn_id);
        defer self.allocator.free(turn_id);
        return self.app.prepareModelAction(
            session_id,
            turn_id,
            input,
            repository,
            self.number,
            self.pull_request_id,
            identity.path,
        );
    }

    fn completeFile(self: *ToolDomainContext, session_id: []const u8) !void {
        const identity = try self.registry.sessionIdentity(session_id);
        defer identity.deinit();
        if (identity.status != .current) return error.NotOfficialCurrentSession;
        try self.app.completeRevision(
            self.broker,
            self.owner,
            self.name,
            self.number,
            self.pull_request_id,
            identity.path,
            identity.revision,
        );
        try self.registry.markCompleted(session_id);
    }

    fn closeSession(self: *ToolDomainContext, session_id: []const u8) !void {
        try self.registry.closeSession(session_id);
        try self.app.closeTabById(session_id);
    }
};

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
    repository_cwd: []const u8,
    fetch_source: ?worktree.FetchSource,
    custody: worktree.Custody,
    baseline: ?*worktree.Baseline = null,
    settings: ?*const config.Settings = null,
    launch_id: []const u8 = "embedded-test",
    stop_request_path: ?[]const u8 = null,
    stop_requested: bool = false,
    worktree_generation_valid: bool = true,
    refresh_override: ?*const fn (runtime: *Runtime) anyerror!void = null,
    tool_domain: ?*ToolDomainContext = null,
    local_domain_mutex: DomainMutex = .{},
};

fn domainMutex(runtime: *Runtime) *DomainMutex {
    if (runtime.tool_domain) |context| return &context.mutex;
    if (runtime.local_domain_mutex.io == null) {
        runtime.local_domain_mutex.io = runtime.broker.io;
    }
    return &runtime.local_domain_mutex;
}

fn isRecoveryCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "snapshot.get") or
        std.mem.eql(u8, command, "pr.refresh") or
        std.mem.eql(u8, command, "round.finish") or
        std.mem.eql(u8, command, "app.stop");
}

pub const max_header_bytes = 32 * 1024;
pub const max_ws_message_bytes = 1024 * 1024;
const default_header_timeout_ms: u32 = 5_000;
const default_write_timeout_ms: u32 = 5_000;
const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

test "command approvals classify only exact decline and cancel as fail closed" {
    try std.testing.expect(Server.approvalDecisionFailsClosed(.{ .string = "decline" }));
    try std.testing.expect(Server.approvalDecisionFailsClosed(.{ .string = "cancel" }));
    try std.testing.expect(!Server.approvalDecisionFailsClosed(.{ .string = "accept" }));
    try std.testing.expect(!Server.approvalDecisionFailsClosed(.{
        .object = std.json.ObjectMap.empty,
    }));
}

fn clientConnectionError(err: anyerror) bool {
    return switch (err) {
        error.EndOfStream,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.HttpHeadersTooLarge,
        error.InvalidHttpRequest,
        error.InvalidClientWebSocketFrame,
        error.WebSocketMessageTooLarge,
        error.WebSocketClosed,
        error.Timeout,
        error.PartialFrameTimeout,
        => true,
        else => false,
    };
}

test "connection isolation never reclassifies an internal runtime failure" {
    try std.testing.expect(clientConnectionError(error.InvalidHttpRequest));
    try std.testing.expect(clientConnectionError(error.Timeout));
    try std.testing.expect(!clientConnectionError(error.OutOfMemory));
    try std.testing.expect(!clientConnectionError(error.MissingOriginSession));
}

test "transient action validation preserves a pending card" {
    try std.testing.expect(!definitiveActionValidationFailure(error.GitHubTransportAmbiguous));
    try std.testing.expect(!definitiveActionValidationFailure(error.InvalidGraphqlResponse));
    try std.testing.expect(definitiveActionValidationFailure(error.PullRequestChanged));
    try std.testing.expect(definitiveActionValidationFailure(error.GitHubActionTargetChanged));
}

test "session status payload binds its originating session" {
    const payload = try sessionStatusPayloadAlloc(
        std.testing.allocator,
        "ses-2",
        "interrupted",
    );
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"ses-2\",\"status\":\"interrupted\"}",
        payload,
    );
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    listener: std.Io.net.Server,
    token: [32]u8,
    skill_root: []u8,
    header_timeout_ms: u32 = default_header_timeout_ms,
    write_timeout_ms: u32 = default_write_timeout_ms,
    websocket_active: bool = false,

    pub fn bind(allocator: std.mem.Allocator, io: std.Io, skill_root: []const u8) !Server {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const listener = try address.listen(io, .{ .mode = .stream });
        var token: [32]u8 = undefined;
        io.random(&token);
        return .{
            .allocator = allocator,
            .io = io,
            .listener = listener,
            .token = token,
            .skill_root = try allocator.dupe(u8, skill_root),
        };
    }
    pub fn deinit(self: *Server) void {
        self.listener.deinit(self.io);
        self.allocator.free(self.skill_root);
    }
    pub fn port(self: *const Server) u16 {
        return self.listener.socket.address.getPort();
    }
    pub fn tokenHex(self: *const Server, out: *[64]u8) []const u8 {
        return std.fmt.bufPrint(out, "{x}", .{self.token}) catch |err| switch (err) {
            error.NoSpaceLeft => "",
        };
    }

    pub fn serveOne(self: *Server, runtime: *Runtime) !void {
        var stream = try self.listener.accept(self.io);
        defer stream.close(self.io);
        self.serveConnected(&stream, runtime) catch |err| {
            if (clientConnectionError(err)) return;
            return err;
        };
    }

    fn serveConnected(
        self: *Server,
        stream: *std.Io.net.Stream,
        runtime: *Runtime,
    ) !void {
        var buf: [max_header_bytes]u8 = undefined;
        var used: usize = 0;
        const deadline = std.Io.Clock.Timestamp.fromNow(
            self.io,
            .{ .raw = std.Io.Duration.fromMilliseconds(self.header_timeout_ms), .clock = .awake },
        );
        while (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n") == null) {
            if (used == buf.len) return error.HttpHeadersTooLarge;
            const got = try stream.socket.receiveTimeout(
                self.io,
                buf[used..],
                .{ .deadline = deadline },
            );
            if (got.data.len == 0) return error.EndOfStream;
            used += got.data.len;
        }
        const raw = buf[0..used];
        const target = requestTarget(raw) orelse return error.InvalidHttpRequest;
        var token_buf: [64]u8 = undefined;
        const token = self.tokenHex(&token_buf);
        if (std.mem.startsWith(u8, target, "/ws?")) {
            return self.upgradeWebSocket(stream, raw, token, runtime);
        }
        if (requiresToken(target)) {
            if (!authorized(target, raw, token)) return writeResponse(
                self.io,
                stream,
                "403 Forbidden",
                "text/plain",
                "forbidden",
                false,
            );
            const body = body: {
                const mutex = domainMutex(runtime);
                mutex.lock();
                defer mutex.unlock();
                break :body try runtime.app.bootstrapAlloc();
            };
            defer self.allocator.free(body);
            return writeResponse(self.io, stream, "200 OK", "application/json", body, true);
        }
        const health = std.mem.startsWith(u8, target, "/healthz") or
            std.mem.startsWith(u8, target, "/readyz");
        if (health) {
            const body = try std.fmt.allocPrint(
                self.allocator,
                "{{\"status\":\"ok\",\"launchId\":{f},\"pid\":{d}}}",
                .{ std.json.fmt(runtime.launch_id, .{}), std.c.getpid() },
            );
            defer self.allocator.free(body);
            return writeResponse(self.io, stream, "200 OK", "application/json", body, true);
        }
        return self.serveAsset(stream, target);
    }

    fn serveAsset(self: *Server, stream: *std.Io.net.Stream, target: []const u8) !void {
        const clean = if (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?"))
            "index.html"
        else blk: {
            const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
            const p = target[0..end];
            const invalid = !std.mem.startsWith(u8, p, "/assets/") or
                std.mem.indexOf(u8, p, "..") != null or
                std.mem.indexOfScalar(u8, p, '\\') != null or
                std.mem.indexOfScalar(u8, p, '%') != null;
            if (invalid) return writeResponse(
                self.io,
                stream,
                "404 Not Found",
                "text/plain",
                "not found",
                false,
            );
            break :blk p["/assets/".len..];
        };
        const root = try std.fs.path.join(self.allocator, &.{ self.skill_root, "assets", "ui" });
        defer self.allocator.free(root);
        const root_real = try std.Io.Dir.cwd().realPathFileAlloc(self.io, root, self.allocator);
        defer self.allocator.free(root_real);
        const candidate = try std.fs.path.join(self.allocator, &.{ root_real, clean });
        defer self.allocator.free(candidate);
        const real = std.Io.Dir.cwd().realPathFileAlloc(
            self.io,
            candidate,
            self.allocator,
        ) catch return writeResponse(
            self.io,
            stream,
            "404 Not Found",
            "text/plain",
            "not found",
            false,
        );
        defer self.allocator.free(real);
        if (!pathConfined(root_real, real)) return writeResponse(
            self.io,
            stream,
            "404 Not Found",
            "text/plain",
            "not found",
            false,
        );
        const body = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            real,
            self.allocator,
            .limited(8 * 1024 * 1024),
        );
        defer self.allocator.free(body);
        const content_type = if (std.mem.endsWith(u8, real, ".html"))
            "text/html; charset=utf-8"
        else if (std.mem.endsWith(u8, real, ".css")) "text/css" else "text/javascript";
        try writeResponse(self.io, stream, "200 OK", content_type, body, true);
    }

    fn upgradeWebSocket(
        self: *Server,
        stream: *std.Io.net.Stream,
        raw: []const u8,
        token: []const u8,
        runtime: *Runtime,
    ) !void {
        if (self.websocket_active) return writeResponse(
            self.io,
            stream,
            "409 Conflict",
            "text/plain",
            "websocket already connected",
            false,
        );
        const target = requestTarget(raw) orelse return error.InvalidHttpRequest;
        if (!authorized(target, raw, token) or !loopbackOrigin(raw, self.port())) {
            return writeResponse(
                self.io,
                stream,
                "403 Forbidden",
                "text/plain",
                "forbidden",
                false,
            );
        }
        const key = headerValue(raw, "sec-websocket-key") orelse return writeResponse(
            self.io,
            stream,
            "400 Bad Request",
            "text/plain",
            "missing websocket key",
            false,
        );
        const invalid_upgrade = !headerToken(raw, "upgrade", "websocket") or
            !headerToken(raw, "connection", "upgrade");
        if (invalid_upgrade) return writeResponse(
            self.io,
            stream,
            "400 Bad Request",
            "text/plain",
            "invalid upgrade",
            false,
        );
        self.websocket_active = true;
        defer self.websocket_active = false;
        try self.writeUpgradeResponse(stream, key);
        defer runtime.registry.declineAllApprovals("browser-disconnected");
        try self.serveWebSocket(stream, runtime);
    }

    fn writeUpgradeResponse(
        self: *Server,
        stream: *std.Io.net.Stream,
        key: []const u8,
    ) !void {
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(key);
        sha1.update(websocket_guid);
        var digest: [20]u8 = undefined;
        sha1.final(&digest);
        var enc: [28]u8 = undefined;
        const accept = std.base64.standard.Encoder.encode(&enc, &digest);
        const format = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket" ++
            "\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n";
        const response = try std.fmt.allocPrint(self.allocator, format, .{accept});
        defer self.allocator.free(response);
        const deadline = writeDeadline(self.io, self.write_timeout_ms);
        try writeStreamAllUntil(self.io, stream.*, response, deadline);
    }

    fn serveWebSocket(
        self: *Server,
        stream: *std.Io.net.Stream,
        runtime: *Runtime,
    ) !void {
        while (true) { // tiger: event-loop -- bounded by owner state or deadline.
            try self.servePendingConnection(runtime);
            const message = readClientTextAllocTimeout(
                self.allocator,
                self.io,
                stream,
                config.visible_event_flush_ms,
            ) catch |err| switch (err) {
                error.Timeout => {
                    try self.flushVisible(stream, runtime);
                    if (runtime.stop_request_path) |path| {
                        if (std.Io.Dir.cwd().access(self.io, path, .{})) |_| {
                            runtime.stop_requested = true;
                            return;
                        } else |_| {}
                    }
                    continue;
                },
                error.EndOfStream => return,
                error.WebSocketClosed => return,
                else => return err,
            };
            defer self.allocator.free(message);
            const reply = self.handleCommandAlloc(runtime, message) catch |err| error_reply: {
                const payload = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"code\":{f}}}",
                    .{std.json.fmt(@errorName(err), .{})},
                );
                defer self.allocator.free(payload);
                break :error_reply try runtime.app.nextEnvelope("error", payload);
            };
            defer self.allocator.free(reply);
            try writeServerText(self.io, stream, reply);
            try self.flushVisible(stream, runtime);
            if (runtime.stop_requested) return;
            if (runtime.stop_request_path) |path| {
                std.Io.Dir.cwd().access(self.io, path, .{}) catch continue;
                runtime.stop_requested = true;
                return;
            }
        }
    }

    fn servePendingConnection(self: *Server, runtime: *Runtime) anyerror!void {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.listener.socket.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.ERR,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, 0) == 0) return;
        if ((fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            return error.HttpListenerFailed;
        }
        var stream = try self.listener.accept(self.io);
        defer stream.close(self.io);
        self.serveConnected(&stream, runtime) catch |err| {
            if (clientConnectionError(err)) return;
            return err;
        };
    }

    fn flushVisible(self: *Server, stream: *std.Io.net.Stream, runtime: *Runtime) !void {
        const mutex = domainMutex(runtime);
        mutex.lock();
        defer mutex.unlock();
        const primary_ready = runtime.registry.primaryReady();
        if (primary_ready and !runtime.app.primary_ready) {
            runtime.app.primary_ready = true;
            const envelope = try runtime.app.nextEnvelope(
                "primary.status",
                "{\"status\":\"completed\"}",
            );
            defer self.allocator.free(envelope);
            try writeServerText(self.io, stream, envelope);
        }
        if (runtime.registry.takePrimaryFailure()) |failure| {
            const payload = try std.fmt.allocPrint(
                self.allocator,
                "{{\"status\":\"failed\",\"reason\":{f}}}",
                .{std.json.fmt(failure, .{})},
            );
            defer self.allocator.free(payload);
            const envelope = try runtime.app.nextEnvelope("primary.status", payload);
            defer self.allocator.free(envelope);
            try writeServerText(self.io, stream, envelope);
        }
        while (try runtime.registry.peekVisible(self.allocator)) |event| {
            defer event.deinit(self.allocator);
            try self.flushVisibleEvent(stream, runtime, event);
            try runtime.registry.acknowledgeVisible();
        }
    }

    fn flushVisibleEvent(
        self: *Server,
        stream: *std.Io.net.Stream,
        runtime: *Runtime,
        event: sessions.VisibleEvent,
    ) !void {
        if ((event.session_id == null and std.mem.eql(
            u8,
            event.method,
            "file.excluded",
        )) or std.mem.eql(
            u8,
            event.method,
            "approval.requested",
        ) or std.mem.eql(u8, event.method, "approval.resolved")) {
            const envelope = try runtime.app.nextEnvelope(event.method, event.raw_json);
            defer self.allocator.free(envelope);
            try writeServerText(self.io, stream, envelope);
            return;
        }
        if (std.mem.eql(u8, event.method, "action.prepared")) {
            return self.flushPreparedAction(stream, runtime, event);
        }
        if (std.mem.eql(u8, event.method, "file.complete.requested")) {
            return self.flushCompletedFile(stream, runtime, event);
        }
        if (std.mem.eql(u8, event.method, "session.close.requested")) {
            return self.flushClosedSession(stream, runtime, event);
        }
        const payload = try ui.visibleEventPayloadAlloc(
            self.allocator,
            event.session_id,
            event.method,
            event.raw_json,
        );
        defer self.allocator.free(payload);
        const envelope = try runtime.app.nextEnvelope("session.item.delta", payload);
        defer self.allocator.free(envelope);
        try writeServerText(self.io, stream, envelope);
    }

    fn flushPreparedAction(
        self: *Server,
        stream: *std.Io.net.Stream,
        runtime: *Runtime,
        event: sessions.VisibleEvent,
    ) !void {
        const session_id = event.session_id orelse return error.MissingOriginSession;
        const card_id = try receiptStringAlloc(self.allocator, event.raw_json, "cardId");
        defer self.allocator.free(card_id);
        const card = (try runtime.app.action_store.byId(card_id)).*;
        if (!std.mem.eql(u8, card.session_id, session_id)) return error.ActionTargetMismatch;
        if (card.supersedes) |id| {
            const superseded_payload = try std.fmt.allocPrint(
                self.allocator,
                "{{\"sessionId\":{f},\"id\":{f}}}",
                .{ std.json.fmt(event.session_id orelse "", .{}), std.json.fmt(id, .{}) },
            );
            defer self.allocator.free(superseded_payload);
            const superseded_envelope = try runtime.app.nextEnvelope(
                "action.superseded",
                superseded_payload,
            );
            defer self.allocator.free(superseded_envelope);
            try writeServerText(self.io, stream, superseded_envelope);
        }
        const card_payload = try tools.cardJsonAlloc(self.allocator, card);
        defer self.allocator.free(card_payload);
        const card_envelope = try runtime.app.nextEnvelope("action.prepared", card_payload);
        defer self.allocator.free(card_envelope);
        try writeServerText(self.io, stream, card_envelope);
    }

    fn flushCompletedFile(
        self: *Server,
        stream: *std.Io.net.Stream,
        runtime: *Runtime,
        event: sessions.VisibleEvent,
    ) !void {
        const session_id = event.session_id orelse return error.MissingOriginSession;
        const payload = try ui.visibleEventPayloadAlloc(
            self.allocator,
            session_id,
            event.method,
            event.raw_json,
        );
        defer self.allocator.free(payload);
        const envelope = try runtime.app.nextEnvelope("file.completed", payload);
        defer self.allocator.free(envelope);
        try writeServerText(self.io, stream, envelope);
    }

    fn flushClosedSession(
        self: *Server,
        stream: *std.Io.net.Stream,
        runtime: *Runtime,
        event: sessions.VisibleEvent,
    ) !void {
        const session_id = event.session_id orelse return error.MissingOriginSession;
        const payload = try ui.visibleEventPayloadAlloc(
            self.allocator,
            session_id,
            event.method,
            event.raw_json,
        );
        defer self.allocator.free(payload);
        const envelope = try runtime.app.nextEnvelope("session.closed", payload);
        defer self.allocator.free(envelope);
        try writeServerText(self.io, stream, envelope);
    }

    fn handleCommandAlloc(self: *Server, runtime: *Runtime, raw: []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidUiCommand,
        };
        const command = switch (root.get("type") orelse return error.InvalidUiCommand) {
            .string => |s| s,
            else => return error.InvalidUiCommand,
        };
        const payload = switch (root.get("payload") orelse return error.InvalidUiCommand) {
            .object => |o| o,
            else => return error.InvalidUiCommand,
        };
        if (!runtime.worktree_generation_valid and
            !isRecoveryCommand(command) and
            !std.mem.eql(u8, command, "approval.resolve"))
        {
            return error.WorktreeGenerationMismatch;
        }
        if (std.mem.eql(u8, command, "file.open")) return self.openFile(runtime, payload);
        if (std.mem.eql(u8, command, "session.close")) {
            return self.closeSession(runtime, payload);
        }
        if (std.mem.eql(u8, command, "session.message")) {
            return self.messageSession(runtime, payload);
        }
        if (std.mem.eql(u8, command, "session.interrupt")) {
            return self.interruptSession(runtime, payload);
        }
        if (std.mem.eql(u8, command, "approval.resolve")) {
            return self.resolveApproval(runtime, payload);
        }
        if (std.mem.eql(u8, command, "action.confirm")) {
            return self.confirmAction(runtime, payload);
        }
        if (std.mem.eql(u8, command, "action.reject")) return self.rejectAction(runtime, payload);
        if (std.mem.eql(u8, command, "snapshot.get")) return self.snapshot(runtime);
        if (std.mem.eql(u8, command, "pr.refresh")) {
            try self.refresh(runtime);
            const mutex = domainMutex(runtime);
            mutex.lock();
            defer mutex.unlock();
            return runtime.app.nextEnvelope("pr.refreshed", "{\"status\":\"reconciled\"}");
        }
        if (std.mem.eql(u8, command, "round.finish")) {
            try self.refresh(runtime);
            const mutex = domainMutex(runtime);
            mutex.lock();
            defer mutex.unlock();
            const round = runtime.app.finishRound();
            const body = try std.fmt.allocPrint(self.allocator, "{{\"round\":{d}}}", .{round});
            defer self.allocator.free(body);
            return runtime.app.nextEnvelope("round.finished", body);
        }
        if (std.mem.eql(u8, command, "app.stop")) {
            if (payload.count() != 0) return error.InvalidUiCommand;
            runtime.registry.declineAllApprovals("shutdown");
            runtime.stop_requested = true;
            const mutex = domainMutex(runtime);
            mutex.lock();
            defer mutex.unlock();
            return runtime.app.nextEnvelope("app.stopped", "{\"status\":\"stopping\"}");
        }
        return error.UnsupportedUiCommand;
    }

    fn snapshot(self: *Server, runtime: *Runtime) ![]u8 {
        const mutex = domainMutex(runtime);
        mutex.lock();
        defer mutex.unlock();
        const body = try runtime.app.bootstrapAlloc();
        defer self.allocator.free(body);
        return runtime.app.nextEnvelope("snapshot", body);
    }

    fn openFile(self: *Server, runtime: *Runtime, payload: std.json.ObjectMap) ![]u8 {
        const path = switch (payload.get("path") orelse return error.InvalidUiCommand) {
            .string => |s| s,
            else => return error.InvalidUiCommand,
        };
        const mutex = domainMutex(runtime);
        mutex.lock();
        defer mutex.unlock();
        if (!runtime.app.primary_ready) return error.PrimaryNotReady;
        if (!runtime.app.generation.queued(path)) return error.FileNotQueued;
        try self.requireReviewWorktree(runtime);
        const revision = @import("domain.zig").revisionFor(
            &runtime.app.generation,
            path,
        ) orelse return error.MissingRevision;
        const diff = try github.canonicalDiffAlloc(
            self.allocator,
            self.io,
            runtime.cwd,
            runtime.app.generation.base_oid,
            runtime.app.generation.head_oid,
            path,
        );
        defer self.allocator.free(diff);
        const threads = try runtime.app.generation.unresolvedThreadsJsonAlloc(
            self.allocator,
            path,
            null,
            &.{},
            false,
        );
        defer self.allocator.free(threads);
        const immediate = if (runtime.settings) |settings| settings.file_review_start_mode ==
            .immediate else true;
        const opened = try runtime.registry.openFile(
            self.io,
            runtime.cwd,
            path,
            revision,
            runtime.app.generation.base_oid,
            runtime.app.generation.head_oid,
            diff,
            threads,
            runtime.skill_path,
            immediate,
        );
        defer opened.deinit();
        return self.recordOpenedFile(runtime, path, revision, diff, immediate, opened);
    }

    fn recordOpenedFile(
        self: *Server,
        runtime: *Runtime,
        path: []const u8,
        revision: []const u8,
        diff: []const u8,
        immediate: bool,
        opened: sessions.OpenResult,
    ) ![]u8 {
        const event = runtime.app.openFile(path) catch |err| {
            if (!opened.reused) {
                runtime.registry.discardOpenedSession(opened.session_id);
            }
            return err;
        };
        self.allocator.free(event);
        runtime.app.recordOpenedSession(
            path,
            revision,
            opened.session_id,
            diff,
            opened.reused,
            immediate and !opened.reused,
        ) catch |err| {
            if (!opened.reused) {
                runtime.registry.discardOpenedSession(opened.session_id);
            }
            runtime.app.rollbackOpenedFile(path, revision, opened.reused);
            return err;
        };
        const body = try runtime.app.sessionOpenedPayloadAlloc(path, revision);
        defer self.allocator.free(body);
        return runtime.app.nextEnvelope("session.opened", body);
    }

    fn closeSession(self: *Server, runtime: *Runtime, payload: std.json.ObjectMap) ![]u8 {
        const session_id = payloadString(payload, "sessionId") orelse
            return error.InvalidUiCommand;
        const mutex = domainMutex(runtime);
        mutex.lock();
        defer mutex.unlock();
        try runtime.registry.closeSession(session_id);
        try runtime.app.closeTabById(session_id);
        const body = try sessionStatusPayloadAlloc(self.allocator, session_id, "closed");
        defer self.allocator.free(body);
        return runtime.app.nextEnvelope("session.closed", body);
    }

    fn messageSession(self: *Server, runtime: *Runtime, payload: std.json.ObjectMap) ![]u8 {
        const text = payloadString(payload, "text") orelse return error.InvalidUiCommand;
        const session_id = payloadString(payload, "sessionId") orelse
            return error.InvalidUiCommand;
        const mutex = domainMutex(runtime);
        mutex.lock();
        self.requireReviewWorktree(runtime) catch |err| {
            mutex.unlock();
            return err;
        };
        runtime.app.initial_review_active = false;
        mutex.unlock();
        try runtime.registry.message(session_id, text);
        mutex.lock();
        defer mutex.unlock();
        const body = try sessionStatusPayloadAlloc(
            self.allocator,
            session_id,
            "turn-started",
        );
        defer self.allocator.free(body);
        return runtime.app.nextEnvelope("session.status", body);
    }

    fn interruptSession(self: *Server, runtime: *Runtime, payload: std.json.ObjectMap) ![]u8 {
        const session_id = payloadString(payload, "sessionId") orelse
            return error.InvalidUiCommand;
        try runtime.registry.interrupt(session_id);
        const mutex = domainMutex(runtime);
        mutex.lock();
        defer mutex.unlock();
        const body = try sessionStatusPayloadAlloc(self.allocator, session_id, "interrupted");
        defer self.allocator.free(body);
        return runtime.app.nextEnvelope("session.status", body);
    }

    fn resolveApproval(self: *Server, runtime: *Runtime, payload: std.json.ObjectMap) ![]u8 {
        if (payload.count() != 2 and payload.count() != 3) return error.InvalidUiCommand;
        const session_id = payloadString(payload, "sessionId");
        if (payload.count() == 3 and session_id == null) return error.InvalidUiCommand;
        const approval_id = payloadString(payload, "approvalId") orelse
            return error.InvalidUiCommand;
        const decision = payload.get("decision") orelse return error.InvalidUiCommand;
        const choice_json = try stringifyValueAlloc(self.allocator, decision);
        defer self.allocator.free(choice_json);
        if (!approvalDecisionFailsClosed(decision)) {
            if (!runtime.worktree_generation_valid) return error.WorktreeGenerationMismatch;
            try self.requireReviewWorktree(runtime);
        }
        try runtime.registry.resolveApproval(session_id, approval_id, choice_json);
        const mutex = domainMutex(runtime);
        mutex.lock();
        defer mutex.unlock();
        return runtime.app.nextEnvelope(
            "session.status",
            "{\"status\":\"approval-resolving\"}",
        );
    }

    fn approvalDecisionFailsClosed(decision: std.json.Value) bool {
        return switch (decision) {
            .string => |choice| std.mem.eql(u8, choice, "decline") or
                std.mem.eql(u8, choice, "cancel"),
            else => false,
        };
    }

    fn confirmAction(self: *Server, runtime: *Runtime, payload: std.json.ObjectMap) ![]u8 {
        if (payload.count() != 1) return error.InvalidUiCommand;
        const mutex = domainMutex(runtime);
        mutex.lock();
        defer mutex.unlock();
        const card_id = payloadString(payload, "cardId") orelse return error.InvalidUiCommand;
        const card = (try runtime.app.action_store.pendingById(card_id)).*;
        runtime.broker.validateAction(
            runtime.owner,
            runtime.name,
            runtime.number,
            runtime.pull_request_id,
            card,
        ) catch |err| {
            if (!definitiveActionValidationFailure(err)) return err;
            try runtime.app.invalidateAction(card_id);
            const format = "{{\"id\":{f},\"status\":\"invalidated\",\"reason\":{f}}}";
            const status = try std.fmt.allocPrint(
                self.allocator,
                format,
                .{ std.json.fmt(card_id, .{}), std.json.fmt(@errorName(err), .{}) },
            );
            defer self.allocator.free(status);
            return runtime.app.nextEnvelope("action.status", status);
        };
        if (card.kind == .add_inline_comment) {
            if (!try self.commentAnchorValid(runtime, card)) {
                try runtime.app.invalidateAction(card_id);
                const format = "{{\"id\":{f},\"status\":\"invalidated\"," ++
                    "\"reason\":\"StaleCommentAnchor\"}}";
                const status = try std.fmt.allocPrint(
                    self.allocator,
                    format,
                    .{std.json.fmt(card_id, .{})},
                );
                defer self.allocator.free(status);
                return runtime.app.nextEnvelope("action.status", status);
            }
        }
        const terminal = try runtime.app.confirmAction(
            runtime.broker,
            runtime.owner,
            runtime.name,
            runtime.number,
            card_id,
        );
        try self.refreshActionEvidence(runtime, terminal);
        return self.actionStatusEnvelope(runtime, card_id, terminal);
    }

    fn requireReviewWorktree(self: *Server, runtime: *Runtime) !void {
        if (runtime.custody == .managed) return;
        worktree.requireReviewAdmission(
            self.allocator,
            self.io,
            runtime.custody,
            runtime.baseline orelse return error.MissingWorktreeBaseline,
        ) catch |err| {
            runtime.worktree_generation_valid = false;
            return err;
        };
    }

    fn commentAnchorValid(
        self: *Server,
        runtime: *Runtime,
        card: tools.ActionCard,
    ) !bool {
        const diff = try github.canonicalDiffAlloc(
            self.allocator,
            self.io,
            runtime.cwd,
            runtime.app.generation.base_oid,
            runtime.app.generation.head_oid,
            card.target.path.?,
        );
        defer self.allocator.free(diff);
        return github.validateDiffAnchor(
            diff,
            card.target.line.?,
            card.target.start_line,
            card.target.side orelse "RIGHT",
        );
    }

    fn refreshActionEvidence(
        self: *Server,
        runtime: *Runtime,
        terminal: tools.ActionStatus,
    ) !void {
        _ = self;
        if (terminal == .succeeded) {
            if (runtime.broker.readGenerationSnapshot(
                runtime.owner,
                runtime.name,
                runtime.number,
            )) |snapshot_value| {
                var refreshed = snapshot_value;
                defer refreshed.metadata.deinit();
                var generation = refreshed.generation;
                var generation_owned = true;
                defer if (generation_owned) generation.deinit();
                if (!std.mem.eql(
                    u8,
                    generation.base_oid,
                    runtime.app.generation.base_oid,
                ) or !std.mem.eql(
                    u8,
                    generation.head_oid,
                    runtime.app.generation.head_oid,
                )) {
                    runtime.app.action_state_fresh = false;
                    return;
                }
                copyRevisionEvidence(runtime, &generation) catch {
                    runtime.app.action_state_fresh = false;
                    return;
                };
                runtime.registry.setGenerationEvidence(&generation) catch {
                    runtime.app.action_state_fresh = false;
                    return;
                };
                const repository = std.fmt.allocPrint(
                    runtime.app.allocator,
                    "{s}/{s}",
                    .{ runtime.owner, runtime.name },
                ) catch {
                    runtime.app.action_state_fresh = false;
                    return;
                };
                defer runtime.app.allocator.free(repository);
                runtime.app.replaceGithubSnapshot(generation, .{
                    .repository = repository,
                    .number = runtime.number,
                    .title = refreshed.metadata.title,
                    .body = refreshed.metadata.body,
                    .url = refreshed.metadata.url,
                    .base_ref_name = refreshed.metadata.base_ref_name,
                    .base_ref_oid = refreshed.metadata.base_oid,
                    .head_ref_name = refreshed.metadata.head_ref_name,
                    .head_ref_oid = refreshed.metadata.head_oid,
                    .state = refreshed.metadata.state,
                    .is_draft = refreshed.metadata.is_draft,
                }) catch {
                    runtime.app.action_state_fresh = false;
                    return;
                };
                generation_owned = false;
                runtime.app.action_state_fresh = true;
            } else |_| {
                runtime.app.action_state_fresh = false;
            }
        }
    }

    fn actionStatusEnvelope(
        self: *Server,
        runtime: *Runtime,
        card_id: []const u8,
        terminal: tools.ActionStatus,
    ) ![]u8 {
        const status = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{f},\"status\":{f},\"stateFresh\":{}}}",
            .{
                std.json.fmt(card_id, .{}),
                std.json.fmt(tools.actionStatusName(terminal), .{}),
                runtime.app.action_state_fresh,
            },
        );
        defer self.allocator.free(status);
        return runtime.app.nextEnvelope("action.status", status);
    }

    fn rejectAction(self: *Server, runtime: *Runtime, payload: std.json.ObjectMap) ![]u8 {
        if (payload.count() != 1) return error.InvalidUiCommand;
        const mutex = domainMutex(runtime);
        mutex.lock();
        defer mutex.unlock();
        const card_id = payloadString(payload, "cardId") orelse return error.InvalidUiCommand;
        try runtime.app.rejectAction(card_id);
        const status = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{f},\"status\":\"rejected\"}}",
            .{std.json.fmt(card_id, .{})},
        );
        defer self.allocator.free(status);
        return runtime.app.nextEnvelope("action.status", status);
    }

    fn refresh(self: *Server, runtime: *Runtime) !void {
        try runtime.registry.beginSynchronization(self.io, sessions.safe_boundary_timeout_ms);
        var synchronizing = true;
        defer if (synchronizing) runtime.registry.endSynchronization();
        const mutex = domainMutex(runtime);
        mutex.lock();
        var locked = true;
        defer if (locked) mutex.unlock();
        if (runtime.refresh_override) |run| {
            mutex.unlock();
            locked = false;
            runtime.registry.endSynchronization();
            synchronizing = false;
            return run(runtime);
        }
        runtime.app.action_state_fresh = false;
        var refreshed = try runtime.broker.readGenerationSnapshot(
            runtime.owner,
            runtime.name,
            runtime.number,
        );
        defer refreshed.metadata.deinit();
        var next = refreshed.generation;
        var next_owned = true;
        errdefer if (next_owned) next.deinit();
        runtime.worktree_generation_valid = false;
        try self.refreshWorktree(runtime, &next);
        try self.refreshTabDiffs(runtime, &next);
        try self.markChangedSessions(runtime, &next);
        const repository = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ runtime.owner, runtime.name },
        );
        defer self.allocator.free(repository);
        try runtime.app.setPullRequest(.{
            .repository = repository,
            .number = runtime.number,
            .title = refreshed.metadata.title,
            .body = refreshed.metadata.body,
            .url = refreshed.metadata.url,
            .base_ref_name = refreshed.metadata.base_ref_name,
            .base_ref_oid = refreshed.metadata.base_oid,
            .head_ref_name = refreshed.metadata.head_ref_name,
            .head_ref_oid = refreshed.metadata.head_oid,
            .state = refreshed.metadata.state,
            .is_draft = refreshed.metadata.is_draft,
        });
        runtime.app.replaceGeneration(next);
        next_owned = false;
        try self.applyRefreshExclusionBatch(runtime);
        try runtime.registry.setGenerationEvidence(&runtime.app.generation);
        const primary_update = try self.primaryUpdateAlloc(runtime);
        defer self.allocator.free(primary_update);
        runtime.worktree_generation_valid = true;
        runtime.app.action_state_fresh = true;
        mutex.unlock();
        locked = false;
        runtime.registry.endSynchronization();
        synchronizing = false;
        try runtime.registry.updatePrimary(primary_update);
    }

    fn refreshWorktree(
        self: *Server,
        runtime: *Runtime,
        next: *@import("domain.zig").PrGeneration,
    ) !void {
        try worktree.synchronize(
            self.allocator,
            self.io,
            runtime.custody,
            runtime.repository_cwd,
            next.head_oid,
            runtime.baseline orelse return error.MissingWorktreeBaseline,
            runtime.fetch_source,
        );
        try github.hydrateRevisionKeys(
            self.allocator,
            self.io,
            runtime.cwd,
            runtime.fetch_source,
            next,
        );
    }

    fn refreshTabDiffs(
        self: *Server,
        runtime: *Runtime,
        next: *const @import("domain.zig").PrGeneration,
    ) !void {
        for (runtime.app.tabs.items) |tab| {
            if (tab.status == .closed) continue;
            if (@import("domain.zig").revisionFor(next, tab.path) == null) {
                try runtime.app.updateTabDiff(tab.path, null);
                continue;
            }
            const current_diff = github.canonicalDiffAlloc(
                self.allocator,
                self.io,
                runtime.cwd,
                next.base_oid,
                next.head_oid,
                tab.path,
            ) catch {
                try runtime.app.updateTabDiff(tab.path, null);
                continue;
            };
            defer self.allocator.free(current_diff);
            try runtime.app.updateTabDiff(tab.path, current_diff);
        }
    }

    fn markChangedSessions(
        self: *Server,
        runtime: *Runtime,
        next: *const @import("domain.zig").PrGeneration,
    ) !void {
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.allocator);
        for (runtime.app.generation.files.items) |file| {
            try appendUniquePath(self.allocator, &paths, file.path);
        }
        for (runtime.app.tabs.items) |tab| {
            if (tab.status != .closed) try appendUniquePath(self.allocator, &paths, tab.path);
        }
        for (paths.items) |path| {
            const threads = try next.unresolvedThreadsJsonAlloc(
                self.allocator,
                path,
                null,
                &.{},
                false,
            );
            defer self.allocator.free(threads);
            const next_revision = @import("domain.zig").revisionFor(next, path) orelse {
                try runtime.registry.markPathChangedAndInject(
                    path,
                    "deleted",
                    "This file was removed from the current pull request.",
                    threads,
                );
                continue;
            };
            const diff = try github.canonicalDiffAlloc(
                self.allocator,
                self.io,
                runtime.cwd,
                next.base_oid,
                next.head_oid,
                path,
            );
            defer self.allocator.free(diff);
            try runtime.registry.markPathChangedAndInject(
                path,
                next_revision,
                diff,
                threads,
            );
        }
    }

    fn applyRefreshExclusionBatch(self: *Server, runtime: *Runtime) !void {
        if (runtime.settings) |settings| {
            var outcomes = try runtime.app.applyAutomaticExclusions(
                settings,
                runtime.broker,
                runtime.owner,
                runtime.name,
                runtime.number,
                runtime.pull_request_id,
                runtime.cwd,
            );
            defer {
                for (outcomes.items) |outcome| outcome.deinit();
                outcomes.deinit(self.allocator);
            }
            try queueExclusionEvents(runtime.registry, outcomes.items);
        }
    }

    fn primaryUpdateAlloc(self: *Server, runtime: *Runtime) ![]u8 {
        var files: std.Io.Writer.Allocating = .init(self.allocator);
        defer files.deinit();
        try std.json.Stringify.value(runtime.app.generation.files.items, .{}, &files.writer);
        const header = runtime.app.pull_request orelse return error.MissingPullRequestHeader;
        const update_format = "The pull request was explicitly refreshed. Current tit" ++
            "le: {s}. Current body: {s}. Current state: {s}; draft: {}. Current base " ++
            "ref: {s} at {s}. Current head ref: {s} at {s}. Current changed files: " ++
            "{s}. Re-evaluate intent, invariants, and cross-file relationships from " ++
            "this generation and the synchronized shared worktree.";
        return std.fmt.allocPrint(
            self.allocator,
            update_format,
            .{
                header.title,
                header.body,
                header.state,
                header.is_draft,
                header.base_ref_name,
                header.base_ref_oid,
                header.head_ref_name,
                header.head_ref_oid,
                files.written(),
            },
        );
    }
};

fn definitiveActionValidationFailure(err: anyerror) bool {
    return switch (err) {
        error.ActionTargetMismatch,
        error.PullRequestChanged,
        error.CommentPathNotCurrent,
        error.GitHubActionTargetMissing,
        error.GitHubActionNotAuthorized,
        error.GitHubActionTargetChanged,
        error.ActionCommentSnapshotMissing,
        => true,
        else => false,
    };
}

pub fn queueExclusionEvents(
    registry: *sessions.Registry,
    outcomes: []const @import("app.zig").ExclusionOutcome,
) !void {
    for (outcomes) |outcome| {
        const state = if (outcome.sync_error == null) "viewed" else "sync-error";
        const payload = try std.fmt.allocPrint(
            registry.allocator,
            "{{\"path\":{f},\"reason\":{f},\"status\":{f},\"syncError\":{f}}}",
            .{
                std.json.fmt(outcome.path, .{}),
                std.json.fmt(outcome.reason, .{}),
                std.json.fmt(state, .{}),
                std.json.fmt(outcome.sync_error, .{}),
            },
        );
        defer registry.allocator.free(payload);
        try registry.queueSystemEvent("file.excluded", payload);
    }
}

fn payloadString(payload: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = payload.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn sessionStatusPayloadAlloc(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    status: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"sessionId\":{f},\"status\":{f}}}",
        .{ std.json.fmt(session_id, .{}), std.json.fmt(status, .{}) },
    );
}

fn toolTurnIdAlloc(
    allocator: std.mem.Allocator,
    raw_json: []const u8,
    fallback: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    if (parsed.value == .object) if (parsed.value.object.get("params")) |params| {
        if (params == .object) if (params.object.get("turnId")) |turn| {
            if (turn == .string) return allocator.dupe(u8, turn.string);
        };
    };
    return allocator.dupe(u8, fallback);
}

fn receiptStringAlloc(
    allocator: std.mem.Allocator,
    raw_json: []const u8,
    key: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthoritativeReceipt;
    const value = parsed.value.object.get(key) orelse return error.InvalidAuthoritativeReceipt;
    if (value != .string) return error.InvalidAuthoritativeReceipt;
    return allocator.dupe(u8, value.string);
}

fn appendUniquePath(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    for (paths.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try paths.append(allocator, path);
}

fn payloadBool(payload: std.json.ObjectMap, key: []const u8) ?bool {
    const value = payload.get(key) orelse return null;
    return switch (value) {
        .bool => |v| v,
        else => null,
    };
}

fn stringifyValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn pathConfined(root: []const u8, candidate: []const u8) bool {
    return std.mem.eql(u8, root, candidate) or (std.mem.startsWith(u8, candidate, root) and
        candidate.len > root.len and candidate[root.len] == std.fs.path.sep);
}

fn authorized(target: []const u8, raw: []const u8, token: []const u8) bool {
    if (queryToken(target)) |value| if (std.mem.eql(u8, value, token)) return true;
    return if (headerValue(raw, "authorization")) |v| std.mem.startsWith(u8, v, "Bearer ") and
        std.mem.eql(u8, v[7..], token) else false;
}

fn requiresToken(target: []const u8) bool {
    return std.mem.eql(u8, target, "/api/bootstrap") or
        std.mem.startsWith(u8, target, "/api/bootstrap?");
}
fn queryToken(target: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    var found: ?[]const u8 = null;
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
        if (std.mem.eql(u8, pair[0..eq], "token")) {
            if (found != null) return null;
            found = pair[eq + 1 ..];
        } else return null;
    }
    return found;
}

fn loopbackOrigin(raw: []const u8, port: u16) bool {
    const origin = headerValue(raw, "origin") orelse return false;
    var buf: [64]u8 = undefined;
    const expected = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}", .{port}) catch return false;
    return std.mem.eql(u8, origin, expected);
}

fn requestTarget(raw: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, raw, "\r\n") orelse return null;
    var it = std.mem.splitScalar(u8, raw[0..end], ' ');
    if (!std.mem.eql(u8, it.next() orelse return null, "GET")) return null;
    return it.next();
}
fn headerValue(raw: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const i = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(
            std.mem.trim(u8, line[0..i], " \t"),
            name,
        )) return std.mem.trim(u8, line[i + 1 ..], " \t");
    }
    return null;
}
fn headerToken(raw: []const u8, name: []const u8, token: []const u8) bool {
    const value = headerValue(raw, name) orelse return false;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token))
        return true;
    return false;
}

fn copyRevisionEvidence(
    runtime: *Runtime,
    generation: *@import("domain.zig").PrGeneration,
) !void {
    const current = &runtime.app.generation;
    for (generation.files.items) |file| {
        const revision = @import("domain.zig").revisionFor(current, file.path) orelse
            return error.MissingRevision;
        try generation.setRevision(file.path, revision);
    }
}

pub fn readClientTextAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
) ![]u8 {
    return readClientTextAllocTimeout(allocator, io, stream, null);
}
pub fn readClientTextAllocTimeout(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    timeout_ms: ?u32,
) ![]u8 {
    const deadline: ?std.Io.Clock.Timestamp = if (timeout_ms) |milliseconds|
        std.Io.Clock.Timestamp.fromNow(
            io,
            .{ .raw = std.Io.Duration.fromMilliseconds(milliseconds), .clock = .awake },
        )
    else
        null;
    var fragmented: std.ArrayList(u8) = .empty;
    defer fragmented.deinit(allocator);
    var fragment_count: usize = 0;
    while (true) { // tiger: event-loop -- bounded by deadline and message limit.
        const frame = readClientFrameAlloc(allocator, io, stream, deadline) catch |err| {
            if (fragment_count > 0 and err == error.Timeout) return error.PartialFrameTimeout;
            return err;
        };
        defer allocator.free(frame.payload);
        switch (frame.opcode) {
            0x1 => {
                if (fragment_count != 0) return error.InvalidClientWebSocketFrame;
                if (frame.fin) {
                    if (!std.unicode.utf8ValidateSlice(frame.payload)) {
                        return error.InvalidClientWebSocketFrame;
                    }
                    return allocator.dupe(u8, frame.payload);
                }
                fragment_count = 1;
                try fragmented.appendSlice(allocator, frame.payload);
            },
            0x0 => {
                if (fragment_count == 0) return error.InvalidClientWebSocketFrame;
                fragment_count += 1;
                if (fragment_count > 1024 or
                    fragmented.items.len > max_ws_message_bytes - frame.payload.len)
                {
                    return error.WebSocketMessageTooLarge;
                }
                try fragmented.appendSlice(allocator, frame.payload);
                if (frame.fin) {
                    if (!std.unicode.utf8ValidateSlice(fragmented.items)) {
                        return error.InvalidClientWebSocketFrame;
                    }
                    return fragmented.toOwnedSlice(allocator);
                }
            },
            0x8 => {
                try validateClosePayload(frame.payload);
                try writeServerFrame(io, stream, 0x8, true, frame.payload);
                return error.WebSocketClosed;
            },
            0x9 => try writeServerFrame(io, stream, 0xA, true, frame.payload),
            0xA => {},
            else => return error.InvalidClientWebSocketFrame,
        }
    }
}

fn validateClosePayload(payload: []const u8) !void {
    if (payload.len == 1) return error.InvalidClientWebSocketFrame;
    if (payload.len == 0) return;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (code < 1000 or code >= 5000 or switch (code) {
        1004, 1005, 1006, 1015 => true,
        else => false,
    }) return error.InvalidClientWebSocketFrame;
    if (!std.unicode.utf8ValidateSlice(payload[2..])) {
        return error.InvalidClientWebSocketFrame;
    }
}

const ClientFrame = struct { fin: bool, opcode: u8, payload: []u8 };

fn readClientFrameAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: *std.Io.net.Stream,
    deadline: ?std.Io.Clock.Timestamp,
) !ClientFrame {
    var head: [2]u8 = undefined;
    try readExactUntil(io, stream, &head, deadline);
    const fin = (head[0] & 0x80) != 0;
    const opcode = head[0] & 0x0f;
    if ((head[0] & 0x70) != 0 or (head[1] & 0x80) == 0) {
        return error.InvalidClientWebSocketFrame;
    }
    var len: u64 = head[1] & 0x7f;
    if (len == 126) {
        var b: [2]u8 = undefined;
        try readExactUntil(io, stream, &b, deadline);
        len = std.mem.readInt(u16, &b, .big);
        if (len < 126) return error.InvalidClientWebSocketFrame;
    } else if (len == 127) {
        var b: [8]u8 = undefined;
        try readExactUntil(io, stream, &b, deadline);
        len = std.mem.readInt(u64, &b, .big);
        if (len <= 65535) return error.InvalidClientWebSocketFrame;
    }
    const control = (opcode & 0x08) != 0;
    if (control and (!fin or len > 125)) return error.InvalidClientWebSocketFrame;
    if (len > max_ws_message_bytes) return error.WebSocketMessageTooLarge;
    var mask: [4]u8 = undefined;
    try readExactUntil(io, stream, &mask, deadline);
    const payload = try allocator.alloc(u8, @intCast(len));
    errdefer allocator.free(payload);
    try readExactUntil(io, stream, payload, deadline);
    for (payload, 0..) |*byte, i| byte.* ^= mask[i % 4];
    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}
fn readExactUntil(
    io: std.Io,
    stream: *std.Io.net.Stream,
    dest: []u8,
    deadline: ?std.Io.Clock.Timestamp,
) !void {
    var off: usize = 0;
    while (off < dest.len) {
        const got = if (deadline) |limit|
            stream.socket.receiveTimeout(io, dest[off..], .{ .deadline = limit }) catch |err| {
                if (err == error.Timeout and off > 0) return error.PartialFrameTimeout;
                return err;
            }
        else
            try stream.socket.receive(io, dest[off..]);
        if (got.data.len == 0) return error.EndOfStream;
        off += got.data.len;
    }
}
fn writeServerText(io: std.Io, stream: *std.Io.net.Stream, body: []const u8) !void {
    if (body.len == 0) return writeServerFrame(io, stream, 0x1, true, body);
    var offset: usize = 0;
    var first = true;
    while (offset < body.len) {
        const end = @min(offset + max_ws_message_bytes, body.len);
        try writeServerFrame(
            io,
            stream,
            if (first) 0x1 else 0x0,
            end == body.len,
            body[offset..end],
        );
        first = false;
        offset = end;
    }
}

fn writeServerFrame(
    io: std.Io,
    stream: *std.Io.net.Stream,
    opcode: u8,
    fin: bool,
    body: []const u8,
) !void {
    var header: [10]u8 = undefined;
    header[0] = (if (fin) @as(u8, 0x80) else 0) | opcode;
    const header_len: usize = if (body.len <= 125) blk: {
        header[1] = @intCast(body.len);
        break :blk 2;
    } else if (body.len <= std.math.maxInt(u16)) blk: {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(body.len), .big);
        break :blk 4;
    } else blk: {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], body.len, .big);
        break :blk 10;
    };
    const deadline = writeDeadline(io, default_write_timeout_ms);
    try writeStreamAllUntil(io, stream.*, header[0..header_len], deadline);
    try writeStreamAllUntil(io, stream.*, body, deadline);
}
fn writeResponse(
    io: std.Io,
    stream: *std.Io.net.Stream,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
    secure: bool,
) !void {
    var header: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&header);
    try writer.print("HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {" ++
        "d}\r\nConnection: close\r\nX-Content-Type-Options: nos" ++
        "niff\r\n", .{ status, content_type, body.len });
    if (secure) try writer.writeAll(
        "Content-Security-Policy: default-src 'self'; connect-s" ++
            "rc 'self' ws://127.0.0.1:*; object-src 'none'; base-ur" ++
            "i 'none'\r\n",
    );
    try writer.writeAll("\r\n");
    const deadline = writeDeadline(io, default_write_timeout_ms);
    try writeStreamAllUntil(io, stream.*, writer.buffered(), deadline);
    try writeStreamAllUntil(io, stream.*, body, deadline);
}

fn writeDeadline(io: std.Io, timeout_ms: u32) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(
        io,
        .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake },
    );
}

fn writeStreamAllUntil(
    io: std.Io,
    stream: std.Io.net.Stream,
    bytes: []const u8,
    deadline: std.Io.Clock.Timestamp,
) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining_ms = deadline.durationFromNow(io).raw.toMilliseconds();
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
            else => return error.HttpWriteFailed,
        }
    }
}

test "asset confinement rejects sibling prefix and traversal" {
    try std.testing.expect(pathConfined("/tmp/ui", "/tmp/ui/app.js"));
    try std.testing.expect(!pathConfined("/tmp/ui", "/tmp/ui-evil/app.js"));
}
test "token parsing is exact and unique" {
    try std.testing.expectEqualStrings("abc", queryToken("/ws?token=abc").?);
    try std.testing.expect(queryToken("/ws?x=1&token=abc") == null);
    try std.testing.expect(queryToken("/ws?token=abc&token=abc") == null);
}

test "static assets are not state-bearing authorization targets" {
    try std.testing.expect(!requiresToken("/assets/app.js"));
    try std.testing.expect(!requiresToken("/?token=launch"));
    try std.testing.expect(requiresToken("/api/bootstrap"));
    try std.testing.expect(requiresToken("/api/bootstrap?token=launch"));
    try std.testing.expect(!requiresToken("/api/bootstrap-impersonator"));
}

test "WebSocket close payload accepts only valid status and UTF-8 reason" {
    try validateClosePayload(&.{});
    try validateClosePayload(&.{ 0x03, 0xE8, 'o', 'k' });
    try std.testing.expectError(
        error.InvalidClientWebSocketFrame,
        validateClosePayload(&.{0x03}),
    );
    try std.testing.expectError(
        error.InvalidClientWebSocketFrame,
        validateClosePayload(&.{ 0x03, 0xED }),
    );
    try std.testing.expectError(
        error.InvalidClientWebSocketFrame,
        validateClosePayload(&.{ 0x03, 0xE8, 0xFF }),
    );
}
