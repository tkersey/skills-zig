const std = @import("std");
const App = @import("app.zig").App;
const config = @import("config.zig");
const domain = @import("domain.zig");
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
    cancelled: std.atomic.Value(bool) = .init(false),
    stop_cancelled: std.atomic.Value(bool) = .init(false),
    runtime: ?*Runtime,

    pub fn create(
        allocator: std.mem.Allocator,
        app: *App,
        registry: *sessions.Registry,
        broker: github.Broker,
        owner: []const u8,
        name: []const u8,
        number: u64,
        pull_request_id: []const u8,
        runtime: ?*Runtime,
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
            .runtime = runtime,
        };
        context.broker.cancelled = &context.cancelled;
        context.broker.stop_cancelled = &context.stop_cancelled;
        return context;
    }

    pub fn handler(self: *ToolDomainContext) sessions.AuthoritativeToolHandler {
        return .{
            .context = self,
            .handle = handleOpaque,
            .cancel = cancelOpaque,
            .deinit = deinitOpaque,
        };
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

    fn cancelOpaque(raw: *anyopaque) void {
        const self: *ToolDomainContext = @ptrCast(@alignCast(raw));
        self.cancelled.store(true, .release);
    }

    pub fn stopCancellationFlag(self: *ToolDomainContext) *std.atomic.Value(bool) {
        return &self.stop_cancelled;
    }

    pub fn combinedCancellationFlag(self: *ToolDomainContext) *std.atomic.Value(bool) {
        return &self.cancelled;
    }

    pub fn cancelForStop(self: *ToolDomainContext) void {
        self.stop_cancelled.store(true, .release);
        self.cancelled.store(true, .release);
    }

    fn handleOpaque(
        raw: *anyopaque,
        event_kind: []const u8,
        raw_json: []const u8,
        session_id: []const u8,
        result_allocator: std.mem.Allocator,
    ) ![]u8 {
        const self: *ToolDomainContext = @ptrCast(@alignCast(raw));
        defer self.cancelled.store(false, .release);
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
        const current_path = (try self.app.generation.resolveSessionCurrentPath(
            identity.path,
            identity.revision,
        )) orelse return error.ActionTargetsAnotherSession;
        try tools.validateAgainstSession(input, current_path);
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
            identity.revision,
        );
    }

    fn completeFile(self: *ToolDomainContext, session_id: []const u8) !void {
        const identity = try self.registry.sessionIdentity(session_id);
        defer identity.deinit();
        if (identity.status != .current) return error.NotOfficialCurrentSession;
        try requireReviewWorktree(
            self.runtime orelse return error.WorktreeAdmissionUnavailable,
        );
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
    base_fetch_source: ?worktree.FetchSource = null,
    fetch_source: ?worktree.FetchSource,
    custody: worktree.Custody,
    baseline: ?*worktree.Baseline = null,
    settings: ?*const config.Settings = null,
    launch_id: []const u8 = "embedded-test",
    stop_request_path: ?[]const u8 = null,
    stop_requested: bool = false,
    worktree_generation_valid: bool = true,
    refresh_epoch: RefreshEpochState = .current,
    refresh_override: ?*const fn (runtime: *Runtime) anyerror!void = null,
    tool_domain: ?*ToolDomainContext = null,
    local_domain_mutex: DomainMutex = .{},
};

pub const RefreshEpochState = enum {
    current,
    preparing,
    committed_reconciling,
    degraded,
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

fn commandAdmitted(
    refresh_epoch: RefreshEpochState,
    worktree_generation_valid: bool,
    command: []const u8,
) bool {
    if (isRecoveryCommand(command) or std.mem.eql(u8, command, "approval.resolve")) {
        return true;
    }
    return worktree_generation_valid and refresh_epoch == .current;
}

fn requireCommandAdmitted(runtime: *Runtime, command: []const u8) !void {
    const mutex = domainMutex(runtime);
    mutex.lock();
    defer mutex.unlock();
    if (!commandAdmitted(
        runtime.refresh_epoch,
        runtime.worktree_generation_valid,
        command,
    )) return error.WorktreeGenerationMismatch;
}

test "degraded refresh admits recovery commands only" {
    inline for (.{ "snapshot.get", "pr.refresh", "round.finish", "app.stop" }) |command| {
        try std.testing.expect(commandAdmitted(.degraded, true, command));
    }
    try std.testing.expect(commandAdmitted(.degraded, true, "approval.resolve"));
    inline for (.{ "file.open", "session.message", "action.confirm" }) |command| {
        try std.testing.expect(!commandAdmitted(.degraded, true, command));
    }
    try std.testing.expect(commandAdmitted(.current, true, "file.open"));
    try std.testing.expect(!commandAdmitted(.current, false, "file.open"));
}

fn invalidateActionGeneration(runtime: *Runtime) void {
    runtime.app.action_state_fresh = false;
    runtime.worktree_generation_valid = false;
}

fn actionValidationQuarantines(err: anyerror) bool {
    return err == error.PullRequestChanged;
}

fn actionTerminalQuarantines(status: tools.ActionStatus) bool {
    return status == .outcome_unknown;
}

fn requireReviewWorktree(runtime: *Runtime) !void {
    if (runtime.custody == .managed) return;
    worktree.requireReviewAdmission(
        runtime.broker.allocator,
        runtime.broker.io,
        runtime.custody,
        runtime.baseline orelse return error.MissingWorktreeBaseline,
    ) catch |err| {
        runtime.worktree_generation_valid = false;
        return err;
    };
}

pub const max_header_bytes = 32 * 1024;
pub const max_ws_message_bytes = 1024 * 1024;
const default_header_timeout_ms: u32 = 5_000;
const default_write_timeout_ms: u32 = 5_000;
const default_ws_frame_timeout_ms: u32 = 5_000;
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

test "generation-changing actions close both stale command surfaces" {
    var state = try App.init(std.testing.allocator, "head");
    defer state.deinit();
    var registry = sessions.Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    var runtime = Runtime{
        .app = &state,
        .registry = &registry,
        .broker = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .gh_path = "gh",
        },
        .owner = "o",
        .name = "r",
        .number = 1,
        .pull_request_id = "PR_1",
        .cwd = ".",
        .skill_path = "/skill",
        .repository_cwd = ".",
        .fetch_source = null,
        .custody = .{ .managed = "." },
    };
    invalidateActionGeneration(&runtime);
    try std.testing.expect(!state.action_state_fresh);
    try std.testing.expect(!runtime.worktree_generation_valid);
}

test "action broker quarantines every uncertified action generation" {
    try std.testing.expect(actionValidationQuarantines(error.PullRequestChanged));
    try std.testing.expect(!actionValidationQuarantines(error.GitHubActionTargetChanged));
    try std.testing.expect(actionTerminalQuarantines(.outcome_unknown));
    try std.testing.expect(!actionTerminalQuarantines(.succeeded));
    inline for (.{ "file.open", "session.message", "action.confirm" }) |command| {
        try std.testing.expect(!commandAdmitted(.current, false, command));
    }
    inline for (.{ "snapshot.get", "pr.refresh", "round.finish", "app.stop" }) |command| {
        try std.testing.expect(commandAdmitted(.current, false, command));
    }
}

test "action broker confirmation admission rejects reused worktree drift" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    for ([_][]const []const u8{
        &.{ "git", "init", "-q", root },
        &.{ "git", "-C", root, "add", "tracked" },
        &.{
            "git",
            "-C",
            root,
            "-c",
            "user.name=Synoptic",
            "-c",
            "user.email=synoptic@example.invalid",
            "commit",
            "-qm",
            "base",
        },
    }, 0..) |argv, index| {
        if (index == 1) try tmp.dir.writeFile(io, .{
            .sub_path = "tracked",
            .data = "base\n",
        });
        const result = try std.process.run(allocator, io, .{ .argv = argv });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
    }
    var baseline = try worktree.Baseline.capture(allocator, io, root);
    defer baseline.deinit();
    var state = try App.init(allocator, "head");
    defer state.deinit();
    var registry = sessions.Registry{ .allocator = allocator };
    defer registry.deinit();
    var runtime = Runtime{
        .app = &state,
        .registry = &registry,
        .broker = .{ .allocator = allocator, .io = io },
        .owner = "o",
        .name = "r",
        .number = 1,
        .pull_request_id = "PR_1",
        .cwd = root,
        .skill_path = "/skill",
        .repository_cwd = root,
        .fetch_source = null,
        .custody = .{ .reused_current = root },
        .baseline = &baseline,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "drift", .data = "unexpected\n" });
    try std.testing.expectError(
        error.ReusedCheckoutRefreshRequiresManagedMigration,
        requireReviewWorktree(&runtime),
    );
    try std.testing.expect(!runtime.worktree_generation_valid);
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
                runtime.app.synchronizeTabTurnStates(runtime.registry);
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
        const real = self.assetRealPathAlloc(target) catch |err| switch (err) {
            error.AssetNotFound => return writeResponse(
                self.io,
                stream,
                "404 Not Found",
                "text/plain",
                "not found",
                false,
            ),
            else => return err,
        };
        defer self.allocator.free(real);
        const body = self.readAssetAlloc(real) catch |err| switch (err) {
            error.AssetNotFound => return writeResponse(
                self.io,
                stream,
                "404 Not Found",
                "text/plain",
                "not found",
                false,
            ),
            error.AssetTooLarge => return writeResponse(
                self.io,
                stream,
                "413 Content Too Large",
                "text/plain",
                "asset too large",
                false,
            ),
            else => return err,
        };
        defer self.allocator.free(body);
        const content_type = if (std.mem.endsWith(u8, real, ".html"))
            "text/html; charset=utf-8"
        else if (std.mem.endsWith(u8, real, ".css")) "text/css" else "text/javascript";
        try writeResponse(self.io, stream, "200 OK", content_type, body, true);
    }

    fn assetRealPathAlloc(self: *Server, target: []const u8) ![]u8 {
        const clean = if (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?"))
            "index.html"
        else blk: {
            const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
            const p = target[0..end];
            const invalid = !std.mem.startsWith(u8, p, "/assets/") or
                std.mem.indexOf(u8, p, "..") != null or
                std.mem.indexOfScalar(u8, p, '\\') != null or
                std.mem.indexOfScalar(u8, p, '%') != null;
            if (invalid) return error.AssetNotFound;
            break :blk p["/assets/".len..];
        };
        const root = try std.fs.path.join(self.allocator, &.{ self.skill_root, "assets", "ui" });
        defer self.allocator.free(root);
        const root_real = std.Io.Dir.cwd().realPathFileAlloc(
            self.io,
            root,
            self.allocator,
        ) catch return error.AssetNotFound;
        defer self.allocator.free(root_real);
        const candidate = try std.fs.path.join(self.allocator, &.{ root_real, clean });
        defer self.allocator.free(candidate);
        const real = std.Io.Dir.cwd().realPathFileAlloc(
            self.io,
            candidate,
            self.allocator,
        ) catch return error.AssetNotFound;
        if (!pathConfined(root_real, real)) {
            self.allocator.free(real);
            return error.AssetNotFound;
        }
        return real;
    }

    fn readAssetAlloc(self: *Server, path: []const u8) ![]u8 {
        const stat = std.Io.Dir.cwd().statFile(
            self.io,
            path,
            .{ .follow_symlinks = false },
        ) catch return error.AssetNotFound;
        if (stat.kind != .file) return error.AssetNotFound;
        if (stat.size > 8 * 1024 * 1024) return error.AssetTooLarge;
        return std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(8 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.StreamTooLong => error.AssetTooLarge,
            else => err,
        };
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
            waitClientReadable(stream, config.visible_event_flush_ms) catch |err| switch (err) {
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
                else => return err,
            };
            const message = readClientTextAllocTimeout(
                self.allocator,
                self.io,
                stream,
                default_ws_frame_timeout_ms,
            ) catch |err| switch (err) {
                error.EndOfStream => return,
                error.WebSocketClosed => return,
                else => return err,
            };
            defer self.allocator.free(message);
            const reply = self.handleCommandAlloc(runtime, message) catch |err| error_reply: {
                const payload = try commandErrorPayloadAlloc(
                    self.allocator,
                    message,
                    @errorName(err),
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
        if (runtime.registry.peekPrimaryFailure()) |failure| {
            const payload = try std.fmt.allocPrint(
                self.allocator,
                "{{\"status\":\"failed\",\"reason\":{f}}}",
                .{std.json.fmt(failure.status, .{})},
            );
            defer self.allocator.free(payload);
            const envelope = try runtime.app.nextEnvelope("primary.status", payload);
            defer self.allocator.free(envelope);
            try writeServerText(self.io, stream, envelope);
            runtime.registry.acknowledgePrimaryFailure(failure.epoch);
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
        if (isSnapshotInvalidation(event)) {
            const envelope = try self.snapshotLocked(runtime);
            defer self.allocator.free(envelope);
            try writeServerText(self.io, stream, envelope);
            return;
        }
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
        if (event.session_id != null and isTurnProjectionEvent(event.method)) {
            runtime.app.synchronizeTabTurnStates(runtime.registry);
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

    fn isTurnProjectionEvent(method: []const u8) bool {
        return std.mem.eql(u8, method, "turn/started") or
            std.mem.eql(u8, method, "turn/completed") or
            std.mem.eql(u8, method, "turn/failed");
    }

    fn isSnapshotInvalidation(event: sessions.VisibleEvent) bool {
        return event.session_id == null and
            std.mem.eql(u8, event.method, "snapshot") and
            std.mem.eql(u8, event.raw_json, "{}");
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
        try requireCommandAdmitted(runtime, command);
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
            if (runtime.tool_domain) |tool_domain| tool_domain.cancelForStop();
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
        return self.snapshotLocked(runtime);
    }

    fn snapshotLocked(self: *Server, runtime: *Runtime) ![]u8 {
        return snapshotEnvelopeLockedAlloc(self.allocator, runtime.app, runtime.registry);
    }

    fn snapshotEnvelopeLockedAlloc(
        allocator: std.mem.Allocator,
        app: *App,
        registry: *sessions.Registry,
    ) ![]u8 {
        app.synchronizeTabTurnStates(registry);
        const body = try app.bootstrapAlloc();
        defer allocator.free(body);
        return app.nextEnvelope("snapshot", body);
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
        try requireReviewWorktree(runtime);
        const revision = @import("domain.zig").revisionFor(
            &runtime.app.generation,
            path,
        ) orelse return error.MissingRevision;
        const diff = runtime.app.generation.canonicalDiff(path) orelse
            return error.MissingCanonicalDiff;
        const threads = try runtime.app.generation.boundedUnresolvedThreadsJsonAlloc(
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
                runtime.registry.discardOpenedSession(opened.session_id) catch |retirement_error| {
                    return retirement_error;
                };
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
            var retirement_error: ?anyerror = null;
            if (!opened.reused) {
                runtime.registry.discardOpenedSession(opened.session_id) catch |failure| {
                    retirement_error = failure;
                };
            }
            runtime.app.rollbackOpenedFile(path, revision, opened.reused);
            if (retirement_error) |failure| return failure;
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
        requireReviewWorktree(runtime) catch |err| {
            mutex.unlock();
            return err;
        };
        runtime.app.initial_review_active = false;
        mutex.unlock();
        try runtime.registry.message(session_id, text);
        mutex.lock();
        defer mutex.unlock();
        runtime.app.setTabTurnActive(session_id, true);
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
            const mutex = domainMutex(runtime);
            mutex.lock();
            defer mutex.unlock();
            if (!runtime.worktree_generation_valid) {
                return error.WorktreeGenerationMismatch;
            }
            try requireReviewWorktree(runtime);
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
        try requireReviewWorktree(runtime);
        runtime.broker.validateAction(
            runtime.owner,
            runtime.name,
            runtime.number,
            runtime.pull_request_id,
            card,
        ) catch |err| {
            if (!definitiveActionValidationFailure(err)) return err;
            if (actionValidationQuarantines(err)) invalidateActionGeneration(runtime);
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
        if (actionTerminalQuarantines(terminal)) invalidateActionGeneration(runtime);
        try self.refreshActionEvidence(runtime, terminal);
        return self.actionStatusEnvelope(runtime, card_id, terminal);
    }

    fn commentAnchorValid(
        self: *Server,
        runtime: *Runtime,
        card: tools.ActionCard,
    ) !bool {
        _ = self;
        const diff = runtime.app.generation.canonicalDiff(card.target.current_path) orelse
            return false;
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
                    invalidateActionGeneration(runtime);
                    return;
                }
                copyRevisionEvidence(&runtime.app.generation, &generation) catch {
                    invalidateActionGeneration(runtime);
                    return;
                };
                runtime.registry.setGenerationEvidence(&generation) catch {
                    invalidateActionGeneration(runtime);
                    return;
                };
                const repository = std.fmt.allocPrint(
                    runtime.app.allocator,
                    "{s}/{s}",
                    .{ runtime.owner, runtime.name },
                ) catch {
                    invalidateActionGeneration(runtime);
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
                    invalidateActionGeneration(runtime);
                    return;
                };
                generation_owned = false;
                runtime.app.action_state_fresh = true;
            } else |_| {
                invalidateActionGeneration(runtime);
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
        runtime.refresh_epoch = .preparing;
        errdefer if (runtime.refresh_epoch == .preparing) {
            runtime.refresh_epoch = .current;
        };
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
            run(runtime) catch |err| {
                runtime.refresh_epoch = .degraded;
                return err;
            };
            runtime.refresh_epoch = .current;
            return;
        }
        var refreshed = try runtime.broker.readGenerationSnapshot(
            runtime.owner,
            runtime.name,
            runtime.number,
        );
        defer refreshed.metadata.deinit();
        var next = refreshed.generation;
        var next_owned = true;
        errdefer if (next_owned) next.deinit();
        var refresh_lease = self.beginRefreshWorktree(runtime, &next) catch |err| {
            if (runtime.refresh_epoch != .degraded) runtime.refresh_epoch = .current;
            return err;
        };
        const committed = self.finishRefresh(
            runtime,
            &refreshed,
            &next,
            &next_owned,
        ) catch |err| {
            if (locked) {
                mutex.unlock();
                locked = false;
            }
            refresh_lease.rollback() catch {
                runtime.worktree_generation_valid = false;
                runtime.app.action_state_fresh = false;
                runtime.refresh_epoch = .degraded;
                return error.ReusedCheckoutRollbackFailed;
            };
            runtime.refresh_epoch = .current;
            return err;
        };
        refresh_lease.commit();
        runtime.worktree_generation_valid = true;
        runtime.app.action_state_fresh = false;
        runtime.refresh_epoch = .committed_reconciling;
        self.reconcileCommittedRefresh(runtime, committed) catch |err| {
            runtime.app.action_state_fresh = false;
            runtime.refresh_epoch = .degraded;
            return err;
        };
        runtime.app.action_state_fresh = true;
        runtime.refresh_epoch = .current;
    }

    const CommittedRefresh = struct {
        allocator: std.mem.Allocator,
        primary_update: []u8,

        fn deinit(self: *CommittedRefresh) void {
            self.allocator.free(self.primary_update);
        }
    };

    fn finishRefresh(
        self: *Server,
        runtime: *Runtime,
        refreshed: *github.GenerationSnapshot,
        next: *@import("domain.zig").PrGeneration,
        next_owned: *bool,
    ) !CommittedRefresh {
        try github.rebindGenerationLineage(
            self.allocator,
            self.io,
            runtime.cwd,
            &runtime.app.generation,
            next,
        );
        const repository = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ runtime.owner, runtime.name },
        );
        defer self.allocator.free(repository);
        var app_plan = try runtime.app.prepareRefresh(next, .{
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
        defer app_plan.deinit();
        var registry_plan = try runtime.registry.prepareGenerationCommit(next);
        defer registry_plan.deinit();
        const primary_update = try self.primaryUpdateForMetadataAlloc(refreshed.metadata);
        errdefer self.allocator.free(primary_update);
        runtime.app.commitRefresh(&app_plan, next.*);
        next_owned.* = false;
        runtime.registry.commitGeneration(&registry_plan);
        return .{
            .allocator = self.allocator,
            .primary_update = primary_update,
        };
    }

    fn reconcileCommittedRefresh(
        self: *Server,
        runtime: *Runtime,
        committed_value: CommittedRefresh,
    ) !void {
        var committed = committed_value;
        defer committed.deinit();
        try self.applyRefreshExclusionBatch(runtime);
        try runtime.registry.setGenerationEvidence(&runtime.app.generation);
        try self.markChangedSessions(runtime, &runtime.app.generation);
        var file_metadata_pages = try runtime.app.generation.primaryFileMetadataPagesAlloc(
            self.allocator,
        );
        defer file_metadata_pages.deinit();
        try runtime.registry.updatePrimary(
            committed.primary_update,
            file_metadata_pages.items.items,
        );
    }

    fn beginRefreshWorktree(
        self: *Server,
        runtime: *Runtime,
        next: *@import("domain.zig").PrGeneration,
    ) !worktree.RefreshLease {
        var lease = try worktree.beginRefresh(
            self.allocator,
            self.io,
            runtime.custody,
            runtime.repository_cwd,
            next.head_oid,
            runtime.baseline orelse return error.MissingWorktreeBaseline,
            runtime.fetch_source,
        );
        github.hydrateRevisionKeysWithSources(
            self.allocator,
            self.io,
            runtime.cwd,
            .{ .base = runtime.base_fetch_source, .head = runtime.fetch_source },
            next,
        ) catch |err| {
            lease.rollback() catch {
                runtime.worktree_generation_valid = false;
                runtime.app.action_state_fresh = false;
                runtime.refresh_epoch = .degraded;
                return error.ReusedCheckoutRollbackFailed;
            };
            runtime.refresh_epoch = .current;
            return err;
        };
        return lease;
    }

    fn markChangedSessions(
        self: *Server,
        runtime: *Runtime,
        next: *const @import("domain.zig").PrGeneration,
    ) !void {
        for (runtime.app.tabs.items) |tab| {
            if (tab.status == .closed) continue;
            const current_path = (try next.resolveSessionCurrentPath(
                tab.path,
                tab.revision,
            )) orelse {
                const threads = try next.boundedUnresolvedThreadsJsonAlloc(
                    self.allocator,
                    tab.path,
                    null,
                    &.{},
                    false,
                );
                defer self.allocator.free(threads);
                try runtime.registry.markPathChangedAndInject(
                    tab.path,
                    tab.revision,
                    tab.path,
                    "deleted",
                    "This file was removed from the current pull request.",
                    threads,
                );
                continue;
            };
            const threads = try next.boundedUnresolvedThreadsJsonAlloc(
                self.allocator,
                current_path,
                null,
                &.{},
                false,
            );
            defer self.allocator.free(threads);
            const next_revision = @import("domain.zig").revisionFor(next, current_path) orelse
                return error.MissingRevision;
            const diff = next.canonicalDiff(current_path) orelse
                return error.MissingCanonicalDiff;
            try runtime.registry.markPathChangedAndInject(
                tab.path,
                tab.revision,
                current_path,
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
            if (outcomes.items.len > 0) {
                try runtime.registry.queueSnapshotInvalidationEventually();
            }
        }
    }

    fn primaryUpdateForMetadataAlloc(
        self: *Server,
        metadata: github.PullRequestMetadata,
    ) ![]u8 {
        const update_format = "The pull request was explicitly refreshed. Current tit" ++
            "le: {s}. Current body: {s}. Current state: {s}; draft: {}. Current base " ++
            "ref: {s} at {s}. Current head ref: {s} at {s}. Current changed files: " ++
            "the ordered bounded metadata pages injected immediately before this turn. " ++
            "Re-evaluate intent, invariants, and cross-file relationships from " ++
            "this generation and the synchronized shared worktree.";
        return std.fmt.allocPrint(
            self.allocator,
            update_format,
            .{
                metadata.title,
                metadata.body,
                metadata.state,
                metadata.is_draft,
                metadata.base_ref_name,
                metadata.base_oid,
                metadata.head_ref_name,
                metadata.head_oid,
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

fn waitClientReadable(stream: *std.Io.net.Stream, timeout_ms: u32) !void {
    var fds = [_]std.posix.pollfd{.{
        .fd = stream.socket.handle,
        .events = std.posix.POLL.IN | std.posix.POLL.ERR,
        .revents = 0,
    }};
    const timeout: i32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));
    if (try std.posix.poll(&fds, timeout) == 0) return error.Timeout;
    if ((fds[0].revents & std.posix.POLL.ERR) != 0) return error.ConnectionResetByPeer;
    if ((fds[0].revents & std.posix.POLL.HUP) != 0 and
        (fds[0].revents & std.posix.POLL.IN) == 0)
    {
        return error.EndOfStream;
    }
}

fn commandErrorPayloadAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    code: []const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        return std.fmt.allocPrint(allocator, "{{\"code\":{f}}}", .{std.json.fmt(code, .{})});
    };
    defer parsed.deinit();
    const request_id = switch (parsed.value) {
        .object => |root| switch (root.get("requestId") orelse .null) {
            .string => |value| if (value.len > 0 and value.len <= 128) value else null,
            else => null,
        },
        else => null,
    };
    if (request_id) |value| return std.fmt.allocPrint(
        allocator,
        "{{\"code\":{f},\"requestId\":{f}}}",
        .{ std.json.fmt(code, .{}), std.json.fmt(value, .{}) },
    );
    return std.fmt.allocPrint(allocator, "{{\"code\":{f}}}", .{std.json.fmt(code, .{})});
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
        registry.queueSystemEvent("file.excluded", payload) catch |err| switch (err) {
            error.VisibleEventLimitExceeded => return,
            else => return err,
        };
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
    current: *const @import("domain.zig").PrGeneration,
    generation: *@import("domain.zig").PrGeneration,
) !void {
    for (generation.files.items) |file| {
        const revision = @import("domain.zig").revisionFor(current, file.path) orelse
            return error.MissingRevision;
        try generation.setRevision(file.path, revision);
        try generation.setPreviousPath(file.path, current.previousPath(file.path));
        const canonical_diff = current.canonicalDiff(file.path) orelse
            return error.MissingCanonicalDiff;
        try generation.setCanonicalDiffEvidence(
            file.path,
            canonical_diff,
            current.diffState(file.path),
        );
        for (current.files.items) |*current_file| {
            if (!std.mem.eql(u8, current_file.path, file.path)) continue;
            try generation.inheritLineage(file.path, current_file);
            if (current_file.exclusion_reason) |reason| {
                try generation.setExclusion(
                    file.path,
                    reason,
                    current_file.exclusion_sync_error,
                );
            }
            break;
        }
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
        1004, 1005, 1006, 1015, 1016...1999 => true,
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

test "command errors preserve only bounded request correlation" {
    const allocator = std.testing.allocator;
    const correlated = try commandErrorPayloadAlloc(
        allocator,
        "{\"requestId\":\"msg-1\",\"type\":\"session.message\",\"payload\":{}}",
        "RequestFailed",
    );
    defer allocator.free(correlated);
    try std.testing.expectEqualStrings(
        "{\"code\":\"RequestFailed\",\"requestId\":\"msg-1\"}",
        correlated,
    );
    const uncorrelated = try commandErrorPayloadAlloc(
        allocator,
        "{\"requestId\":7}",
        "InvalidUiCommand",
    );
    defer allocator.free(uncorrelated);
    try std.testing.expectEqualStrings("{\"code\":\"InvalidUiCommand\"}", uncorrelated);
}

test "turn projection events always re-read registry-authoritative turn state" {
    try std.testing.expect(Server.isTurnProjectionEvent("turn/started"));
    try std.testing.expect(Server.isTurnProjectionEvent("turn/completed"));
    try std.testing.expect(Server.isTurnProjectionEvent("turn/failed"));
    try std.testing.expect(!Server.isTurnProjectionEvent("item/completed"));
}

test "static assets are not state-bearing authorization targets" {
    try std.testing.expect(!requiresToken("/assets/app.js"));
    try std.testing.expect(!requiresToken("/?token=launch"));
    try std.testing.expect(requiresToken("/api/bootstrap"));
    try std.testing.expect(requiresToken("/api/bootstrap?token=launch"));
    try std.testing.expect(!requiresToken("/api/bootstrap-impersonator"));
}

test "tool-domain server cancellation reaches in-flight GitHub effects" {
    var state = try App.init(std.testing.allocator, "head");
    defer state.deinit();
    var registry = sessions.Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    const context = try ToolDomainContext.create(
        std.testing.allocator,
        &state,
        &registry,
        .{ .allocator = std.testing.allocator, .io = std.testing.io },
        "owner",
        "repository",
        1,
        "PR_1",
        null,
    );
    const handler = context.handler();
    defer handler.deinit.?(handler.context);
    handler.cancel.?(handler.context);
    try std.testing.expect(context.cancelled.load(.acquire));
    try std.testing.expect(context.broker.cancelled.?.load(.acquire));
    try std.testing.expectError(
        error.UnsupportedAuthoritativeTool,
        handler.handle(
            handler.context,
            "unsupported",
            "{}",
            "ses-1",
            std.testing.allocator,
        ),
    );
    try std.testing.expect(!context.cancelled.load(.acquire));
    context.cancelForStop();
    try std.testing.expectError(
        error.UnsupportedAuthoritativeTool,
        handler.handle(
            handler.context,
            "unsupported",
            "{}",
            "ses-1",
            std.testing.allocator,
        ),
    );
    try std.testing.expect(!context.cancelled.load(.acquire));
    try std.testing.expect(context.stop_cancelled.load(.acquire));
    try std.testing.expectError(
        error.GitHubCallCancelled,
        context.broker.call("query Cancelled{viewer{login}}", "{}"),
    );
}

test "action refresh preserves local exclusion synchronization evidence" {
    const allocator = std.testing.allocator;
    var current = try @import("domain.zig").PrGeneration.initFull(
        allocator,
        "base",
        "head",
    );
    defer current.deinit();
    try current.addFile(.{
        .path = "vendor/fail.js",
        .viewed = .unviewed,
        .revision_key = "revision",
        .canonical_diff = "Synoptic did not inline this binary diff.",
        .diff_state = .binary,
        .exclusion_reason = "vendored",
        .exclusion_sync_error = "readback-failed",
    });
    var refreshed = try @import("domain.zig").PrGeneration.initFull(
        allocator,
        "base",
        "head",
    );
    defer refreshed.deinit();
    try refreshed.addFile(.{
        .path = "vendor/fail.js",
        .viewed = .unviewed,
        .revision_key = "placeholder",
    });
    try copyRevisionEvidence(&current, &refreshed);
    try std.testing.expectEqualStrings("revision", refreshed.files.items[0].revision_key);
    try std.testing.expectEqualStrings(
        "Synoptic did not inline this binary diff.",
        refreshed.canonicalDiff("vendor/fail.js").?,
    );
    try std.testing.expectEqual(
        @import("domain.zig").DiffDisplayState.binary,
        refreshed.diffState("vendor/fail.js"),
    );
    try std.testing.expectEqualStrings("vendored", refreshed.files.items[0].exclusion_reason.?);
    try std.testing.expectEqualStrings(
        "readback-failed",
        refreshed.files.items[0].exclusion_sync_error.?,
    );
}

test "exclusion notification capacity cannot fail committed reconciliation" {
    var registry = sessions.Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    for (0..sessions.max_visible_events) |_| {
        try registry.queueSystemEvent("status", "{}");
    }
    const outcome = try @import("app.zig").ExclusionOutcome.init(
        std.testing.allocator,
        "vendor/generated.js",
        "vendored",
        null,
    );
    defer outcome.deinit();

    try queueExclusionEvents(&registry, &.{outcome});
    try std.testing.expectEqual(
        sessions.max_visible_events,
        registry.visible_events.items.len,
    );
    try registry.queueSnapshotInvalidationEventually();
    try std.testing.expect(registry.pending_system_event != null);
    try registry.acknowledgeVisible();
    try std.testing.expect(registry.pending_system_event == null);
    const last = registry.visible_events.items[registry.visible_events.items.len - 1];
    try std.testing.expectEqualStrings("snapshot", last.method);
    try std.testing.expectEqualStrings("{}", last.raw_json);
    try std.testing.expect(Server.isSnapshotInvalidation(last));
}

test "snapshot invalidation materializes under one domain lock" {
    var app = try App.init(std.testing.allocator, "head");
    defer app.deinit();
    var registry = sessions.Registry{ .allocator = std.testing.allocator };
    defer registry.deinit();
    var mutex = DomainMutex{ .io = std.testing.io };
    mutex.lock();
    defer mutex.unlock();

    const envelope = try Server.snapshotEnvelopeLockedAlloc(
        std.testing.allocator,
        &app,
        &registry,
    );
    defer std.testing.allocator.free(envelope);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"type\":\"snapshot\"") != null);
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
        validateClosePayload(&.{ 0x03, 0xF8 }),
    );
    try std.testing.expectError(
        error.InvalidClientWebSocketFrame,
        validateClosePayload(&.{ 0x07, 0xCF }),
    );
    try validateClosePayload(&.{ 0x07, 0xD0 });
    try std.testing.expectError(
        error.InvalidClientWebSocketFrame,
        validateClosePayload(&.{ 0x03, 0xE8, 0xFF }),
    );
}
