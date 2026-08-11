const core_json = @import("core_json");
pub const hooks = @import("cas_hook_policy");
pub const app_server_launch = @import("transport.zig");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const std = @import("std");
pub const websocket_transport = @import("websocket.zig");

const max_interleaved_messages: usize = 4096;
const max_captured_notifications: usize = 1024;
const max_captured_notification_bytes: usize = 16 * 1024 * 1024;
const default_request_timeout_ms: i64 = 30_000;
const handshake_timeout_ms: i64 = 10_000;
pub const max_server_request_carrier_bytes: usize = 1024 * 1024;
pub const max_initialize_capabilities_bytes: usize = 64 * 1024;
pub const max_codex_enable_features: usize = 16;

pub const InitializeCapabilityBuilder = struct {
    experimental_api: bool = true,
    opt_out_notification_methods: []const []const u8 = &.{},
    mcp_server_openai_form_elicitation: bool = false,
    request_attestation: bool = false,
    additional_json: ?[]const u8 = null,

    const max_additional_fields: usize = 64;
    const max_notification_methods: usize = 256;
    const max_method_bytes: usize = 1024;

    pub fn validate(self: InitializeCapabilityBuilder, allocator: std.mem.Allocator) !void {
        if (self.opt_out_notification_methods.len > max_notification_methods) {
            return error.InitializeCapabilitiesTooLarge;
        }
        for (self.opt_out_notification_methods) |method| {
            if (method.len == 0 or method.len > max_method_bytes) {
                return error.InvalidInitializeCapabilities;
            }
        }
        const raw = self.additional_json orelse return;
        if (raw.len > max_initialize_capabilities_bytes) {
            return error.InitializeCapabilitiesTooLarge;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
            return error.InvalidInitializeCapabilities;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidInitializeCapabilities,
        };
        if (object.count() > max_additional_fields) return error.InitializeCapabilitiesTooLarge;
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.*.len == 0 or isTypedCapability(entry.key_ptr.*))
                return error.DuplicateInitializeCapabilityOwner;
        }
    }

    pub fn buildAlloc(self: InitializeCapabilityBuilder, allocator: std.mem.Allocator) ![]u8 {
        try self.validate(allocator);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const writer = &output.writer;
        try writer.writeAll("{\"experimentalApi\":");
        try std.json.Stringify.value(self.experimental_api, .{}, writer);
        try writer.writeAll(",\"optOutNotificationMethods\":");
        try std.json.Stringify.value(self.opt_out_notification_methods, .{}, writer);
        try writer.writeAll(",\"mcpServerOpenaiFormElicitation\":");
        try std.json.Stringify.value(self.mcp_server_openai_form_elicitation, .{}, writer);
        try writer.writeAll(",\"requestAttestation\":");
        try std.json.Stringify.value(self.request_attestation, .{}, writer);

        if (self.additional_json) |raw| {
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
            defer parsed.deinit();
            var iterator = parsed.value.object.iterator();
            while (iterator.next()) |entry| {
                try writer.writeByte(',');
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try std.json.Stringify.value(entry.value_ptr.*, .{}, writer);
            }
        }
        try writer.writeByte('}');
        if (output.written().len > max_initialize_capabilities_bytes) {
            return error.InitializeCapabilitiesTooLarge;
        }
        return output.toOwnedSlice();
    }

    fn isTypedCapability(key: []const u8) bool {
        return std.mem.eql(u8, key, "experimentalApi") or
            std.mem.eql(u8, key, "optOutNotificationMethods") or
            std.mem.eql(u8, key, "mcpServerOpenaiFormElicitation") or
            std.mem.eql(u8, key, "requestAttestation");
    }
};

pub const ServerRequestHandlerKind = enum {
    command_execution_approval,
    file_change_approval,
    permissions_approval,
    request_user_input,
    mcp_elicitation,
    dynamic_tool_call,
    auth_tokens_refresh,
    attestation_generate,
    current_time_read,
    apply_patch_approval,
    exec_command_approval,
    unknown,

    fn parse(method: []const u8) ServerRequestHandlerKind {
        return if (serverRequestHandler(method)) |descriptor| descriptor.kind else .unknown;
    }
};

pub const ServerRequestHandlerDescriptor = struct {
    method: []const u8,
    policy: []const u8,
    kind: ServerRequestHandlerKind,
};

pub const server_request_handler_descriptors = [_]ServerRequestHandlerDescriptor{
    .{
        .method = "item/commandExecution/requestApproval",
        .policy = "configured-approval-or-decline",
        .kind = .command_execution_approval,
    },
    .{
        .method = "item/fileChange/requestApproval",
        .policy = "configured-approval-or-decline",
        .kind = .file_change_approval,
    },
    .{
        .method = "item/tool/requestUserInput",
        .policy = "exact-response-or-decline",
        .kind = .request_user_input,
    },
    .{
        .method = "mcpServer/elicitation/request",
        .policy = "mode-aware-exact-response-or-decline",
        .kind = .mcp_elicitation,
    },
    .{
        .method = "item/permissions/requestApproval",
        .policy = "configured-approval-or-decline",
        .kind = .permissions_approval,
    },
    .{
        .method = "item/tool/call",
        .policy = "configured-tool-handler-or-error",
        .kind = .dynamic_tool_call,
    },
    .{
        .method = "account/chatgptAuthTokens/refresh",
        .policy = "exact-secret-provider-or-typed-error",
        .kind = .auth_tokens_refresh,
    },
    .{
        .method = "attestation/generate",
        .policy = "exact-attestation-provider-or-typed-error",
        .kind = .attestation_generate,
    },
    .{
        .method = "applyPatchApproval",
        .policy = "deprecated-reject",
        .kind = .apply_patch_approval,
    },
    .{
        .method = "execCommandApproval",
        .policy = "deprecated-reject",
        .kind = .exec_command_approval,
    },
    .{ .method = "currentTime/read", .policy = "exact-unix-seconds", .kind = .current_time_read },
};

pub fn serverRequestHandler(method: []const u8) ?ServerRequestHandlerDescriptor {
    for (server_request_handler_descriptors) |descriptor| {
        if (std.mem.eql(u8, method, descriptor.method)) return descriptor;
    }
    return null;
}

pub const max_overload_retries: u32 = 16;
pub const max_overload_delay_ms: u32 = 4_000;
pub const max_overload_jitter_percent: u8 = 25;

pub const OverloadRetryPolicy = struct {
    max_retries: u32 = 4,
    base_delay_ms: u32 = 250,
    max_delay_ms: u32 = max_overload_delay_ms,
    jitter_percent: u8 = max_overload_jitter_percent,
};

pub const OverloadRetryTelemetry = struct {
    wire_attempts: u32 = 0,
    overload_responses: u32 = 0,
    retries: u32 = 0,
    delay_count: u32 = 0,
    delays_ms: [max_overload_retries]u32 = @splat(0),
    exhausted: bool = false,

    pub fn reset(self: *OverloadRetryTelemetry) void {
        self.* = .{};
    }
};

pub fn validateOverloadRetryPolicy(policy: OverloadRetryPolicy) !void {
    if (policy.max_retries > max_overload_retries) return error.InvalidOverloadRetryPolicy;
    if (policy.base_delay_ms == 0 or policy.base_delay_ms > max_overload_delay_ms) {
        return error.InvalidOverloadRetryPolicy;
    }
    if (policy.max_delay_ms == 0 or policy.max_delay_ms > max_overload_delay_ms) {
        return error.InvalidOverloadRetryPolicy;
    }
    if (policy.base_delay_ms > policy.max_delay_ms) return error.InvalidOverloadRetryPolicy;
    if (policy.jitter_percent > max_overload_jitter_percent) {
        return error.InvalidOverloadRetryPolicy;
    }
}

fn resolveOverloadRetrySeed(explicit: ?u64, io: std.Io) !u64 {
    if (explicit) |seed| return seed;
    var seed: u64 = undefined;
    try std.Io.randomSecure(io, std.mem.asBytes(&seed));
    return seed;
}

pub fn overloadRetryDelayMs(policy: OverloadRetryPolicy, retry_index: u32, seed: u64) u32 {
    std.debug.assert(retry_index < max_overload_retries);
    const shift: u6 = @intCast(@min(retry_index, 31));
    const exponential = @min(
        @as(u64, policy.base_delay_ms) << shift,
        @as(u64, policy.max_delay_ms),
    );
    const jitter_limit = exponential * policy.jitter_percent / 100;
    const retry_bytes = std.mem.asBytes(&retry_index);
    const sample = std.hash.Wyhash.hash(seed, retry_bytes);
    const jitter = if (jitter_limit == 0) 0 else sample % (jitter_limit + 1);
    return @intCast(@min(exponential + jitter, @as(u64, policy.max_delay_ms)));
}

pub fn isStructuredOverloadError(error_value: std.json.Value) bool {
    const object = switch (error_value) {
        .object => |value| value,
        else => return false,
    };
    return core_json.intField(object, "code") == -32001;
}

pub const TransportKind = enum {
    stdio,
    websocket,
    unix_socket,

    pub fn text(self: TransportKind) []const u8 {
        return switch (self) {
            .stdio => "stdio",
            .websocket => "websocket",
            .unix_socket => "unix_socket",
        };
    }
};

pub const MultiAgentMode = enum {
    explicit_request_only,
    proactive,

    pub fn parse(raw: []const u8) ?MultiAgentMode {
        if (std.mem.eql(u8, raw, "explicit-request-only")) return .explicit_request_only;
        if (std.mem.eql(u8, raw, "proactive")) return .proactive;
        return null;
    }

    pub fn configValue(self: MultiAgentMode) []const u8 {
        return switch (self) {
            .explicit_request_only => "explicit-request-only",
            .proactive => "proactive",
        };
    }

    pub fn wireValue(self: MultiAgentMode) []const u8 {
        return switch (self) {
            .explicit_request_only => "explicitRequestOnly",
            .proactive => "proactive",
        };
    }
};

pub const MultiAgentModeSupport = enum {
    not_requested,
    proven,
    unproven,
    unsupported,

    pub fn asString(self: MultiAgentModeSupport) []const u8 {
        return switch (self) {
            .not_requested => "not_requested",
            .proven => "proven",
            .unproven => "unproven",
            .unsupported => "unsupported",
        };
    }
};

pub const ClientOptions = struct {
    cwd: []const u8,
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),
    // Kept for API compatibility with prior Node-backed client.
    proxy_script: ?[]const u8 = null,
    state_file: ?[]const u8 = null,
    codex_path: []const u8 = "codex",
    client_name: ?[]const u8 = null,
    client_title: ?[]const u8 = null,
    client_version: ?[]const u8 = null,
    // Reserved for a future transport-level server-request deadline. Server
    // requests are currently resolved synchronously before the read loop
    // advances, so this value is rejected instead of being silently ignored.
    server_request_timeout_ms: ?u32 = null,
    exec_approval: ?[]const u8 = null,
    file_approval: ?[]const u8 = null,
    permissions_approval: ?[]const u8 = null,
    request_user_input_response_json: ?[]const u8 = null,
    elicitation_action: ?[]const u8 = null,
    elicitation_content_json: ?[]const u8 = null,
    elicitation_response_json: ?[]const u8 = null,
    dynamic_tool_response_json: ?[]const u8 = null,
    auth_refresh_response_json: ?[]const u8 = null,
    attestation_response_json: ?[]const u8 = null,
    read_only: bool = false,
    experimental_api: bool = true,
    opt_out_notification_methods: []const []const u8 = &.{},
    additional_initialize_capabilities_json: ?[]const u8 = null,
    hook_policy: hooks.HookPolicy = .inherit,
    websocket_url: ?[]const u8 = null,
    // Typed transport selection. websocket_url remains an internal
    // compatibility carrier until route call sites migrate.
    transport: ?app_server_launch.ValidatedTransport = null,
    code_mode_host: ?*const app_server_launch.CodeModeHost = null,
    websocket_connect_timeout_ms: u32 = 10_000,
    request_deadline_ms: ?i64 = null,
    overload_retry_policy: OverloadRetryPolicy = .{},
    overload_retry_seed: ?u64 = null,
    overload_retry_telemetry: ?*OverloadRetryTelemetry = null,
    child_environment: ?*const std.process.Environ.Map = null,
    // Internal diagnostic launches may enable an exact bounded Codex feature
    // set before the app-server subcommand. Socket transports point at an
    // already launched server and therefore reject this carrier.
    codex_enable_features: []const []const u8 = &.{},
};

pub const RequestSendObserver = struct {
    context: *anyopaque,
    before_send: *const fn (context: *anyopaque) anyerror!void,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),
    transport_kind: TransportKind,
    child: ?std.process.Child,
    process_group_id: ?u64 = null,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    websocket: ?websocket_transport.Connection,
    line_buf: std.ArrayList(u8) = .empty,
    next_request_id: i64 = 1,
    last_error: ?[]u8 = null,
    last_unsupported_server_request: ?[]u8 = null,
    exec_approval: ?[]const u8,
    file_approval: ?[]const u8,
    permissions_approval: ?[]const u8,
    request_user_input_response_json: ?[]const u8,
    elicitation_action: ?[]const u8,
    elicitation_content_json: ?[]const u8,
    elicitation_response_json: ?[]const u8 = null,
    dynamic_tool_response_json: ?[]const u8,
    auth_refresh_response_json: ?[]const u8 = null,
    attestation_response_json: ?[]const u8 = null,
    read_only: bool,
    initialize_response_json: ?[]u8 = null,
    blocking_server_request_count: u64 = 0,
    request_deadline_ms: ?i64 = null,
    request_send_started: bool = false,
    transport_identity: []const u8 = "stdio",
    overload_retry_policy: OverloadRetryPolicy = .{},
    overload_retry_seed: u64 = 0,
    overload_retry_telemetry: ?*OverloadRetryTelemetry = null,

    pub fn start(allocator: std.mem.Allocator, opts: ClientOptions) !Client {
        try validateClientOptions(allocator, opts);
        // Resolve every fallible launch-independent input before acquiring a
        // child process or socket. The helpers accept only the resolved value.
        const overload_retry_seed = try resolveOverloadRetrySeed(opts.overload_retry_seed, opts.io);
        if (opts.transport) |transport| switch (transport) {
            .stdio => return startStdio(allocator, opts, overload_retry_seed),
            .explicit_websocket => |url| return startWebsocket(
                allocator,
                opts,
                overload_retry_seed,
                url,
                .websocket,
            ),
            .unix_socket => |maybe_path| {
                if (maybe_path) |path| {
                    const resolved = try app_server_launch.resolveUnixPathAlloc(
                        allocator,
                        opts.cwd,
                        path,
                    );
                    defer allocator.free(resolved);
                    return startUnix(allocator, opts, overload_retry_seed, resolved);
                }
                const path = try app_server_launch.defaultUnixPathAlloc(allocator);
                defer allocator.free(path);
                return startUnix(allocator, opts, overload_retry_seed, path);
            },
            .auto, .managed_websocket => return error.TransportLaunchRequired,
        };
        if (opts.websocket_url) |url| {
            return startWebsocket(allocator, opts, overload_retry_seed, url, .websocket);
        }

        return startStdio(allocator, opts, overload_retry_seed);
    }

    /// Starts the compatibility client, completes initialize/initialized, then
    /// transfers transport ownership to the permanent-reader actor.
    pub fn startActor(
        allocator: std.mem.Allocator,
        opts: ClientOptions,
        actor_options: ActorOptions,
    ) !Actor {
        const synchronous = try Client.start(allocator, opts);
        return Actor.initOwned(allocator, synchronous, actor_options);
    }

    fn startStdio(
        allocator: std.mem.Allocator,
        opts: ClientOptions,
        overload_retry_seed: u64,
    ) !Client {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);

        const resolved_codex_path = try resolveExecutableAlloc(allocator, opts.codex_path);
        defer allocator.free(resolved_codex_path);
        try hooks.ensureLaunchSupportsPolicy(
            allocator,
            opts.io,
            resolved_codex_path,
            opts.cwd,
            opts.hook_policy,
        );

        try argv.append(allocator, resolved_codex_path);
        try appendCodexEnableFeatureArgs(allocator, &argv, opts.codex_enable_features);
        try app_server_launch.appendAppServerArgs(
            allocator,
            &argv,
            opts.hook_policy == .off,
            null,
            opts.code_mode_host,
        );

        const io = opts.io;
        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = opts.cwd },
            .environ_map = opts.child_environment,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
        });
        const process_group_id: ?u64 = switch (builtin.os.tag) {
            .windows, .wasi => null,
            else => @intCast(child.id.?),
        };
        var child_owned = true;
        errdefer if (child_owned) {
            retireStdioChild(io, &child, process_group_id);
        };

        const stdin_file = child.stdin orelse return error.ChildMissingStdin;
        const stdout_file = child.stdout orelse return error.ChildMissingStdout;

        var client = initStdioClient(
            allocator,
            io,
            child,
            process_group_id,
            stdin_file,
            stdout_file,
            opts,
            overload_retry_seed,
        );
        child_owned = false;
        errdefer {
            client.close();
            client.deinit();
        }
        try client.handshake(opts);
        return client;
    }

    fn initStdioClient(
        allocator: std.mem.Allocator,
        io: std.Io,
        child: std.process.Child,
        process_group_id: ?u64,
        stdin_file: std.Io.File,
        stdout_file: std.Io.File,
        opts: ClientOptions,
        overload_retry_seed: u64,
    ) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .transport_kind = .stdio,
            .child = child,
            .process_group_id = process_group_id,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .websocket = null,
            .line_buf = .empty,
            .next_request_id = 1,
            .last_error = null,
            .exec_approval = opts.exec_approval,
            .file_approval = opts.file_approval,
            .permissions_approval = opts.permissions_approval,
            .request_user_input_response_json = opts.request_user_input_response_json,
            .elicitation_action = opts.elicitation_action,
            .elicitation_content_json = opts.elicitation_content_json,
            .elicitation_response_json = opts.elicitation_response_json,
            .dynamic_tool_response_json = opts.dynamic_tool_response_json,
            .auth_refresh_response_json = opts.auth_refresh_response_json,
            .attestation_response_json = opts.attestation_response_json,
            .read_only = opts.read_only,
            .blocking_server_request_count = 0,
            .request_deadline_ms = opts.request_deadline_ms,
            .transport_identity = "stdio",
            .overload_retry_policy = opts.overload_retry_policy,
            .overload_retry_seed = overload_retry_seed,
            .overload_retry_telemetry = opts.overload_retry_telemetry,
        };
    }

    fn startWebsocket(
        allocator: std.mem.Allocator,
        opts: ClientOptions,
        overload_retry_seed: u64,
        url: []const u8,
        kind: TransportKind,
    ) !Client {
        const websocket = try websocket_transport.Connection.connect(
            allocator,
            url,
            opts.websocket_connect_timeout_ms,
        );

        return startSocketConnection(
            allocator,
            opts,
            overload_retry_seed,
            websocket,
            kind,
        );
    }

    fn startUnix(
        allocator: std.mem.Allocator,
        opts: ClientOptions,
        overload_retry_seed: u64,
        path: []const u8,
    ) !Client {
        const websocket = try websocket_transport.Connection.connectUnix(
            allocator,
            path,
            opts.websocket_connect_timeout_ms,
        );
        return startSocketConnection(
            allocator,
            opts,
            overload_retry_seed,
            websocket,
            .unix_socket,
        );
    }

    fn startSocketConnection(
        allocator: std.mem.Allocator,
        opts: ClientOptions,
        overload_retry_seed: u64,
        websocket: websocket_transport.Connection,
        kind: TransportKind,
    ) !Client {
        var client = Client{
            .allocator = allocator,
            .io = opts.io,
            .transport_kind = kind,
            .child = null,
            .stdin_file = null,
            .stdout_file = null,
            .websocket = websocket,
            .line_buf = .empty,
            .next_request_id = 1,
            .last_error = null,
            .exec_approval = opts.exec_approval,
            .file_approval = opts.file_approval,
            .permissions_approval = opts.permissions_approval,
            .request_user_input_response_json = opts.request_user_input_response_json,
            .elicitation_action = opts.elicitation_action,
            .elicitation_content_json = opts.elicitation_content_json,
            .elicitation_response_json = opts.elicitation_response_json,
            .dynamic_tool_response_json = opts.dynamic_tool_response_json,
            .auth_refresh_response_json = opts.auth_refresh_response_json,
            .attestation_response_json = opts.attestation_response_json,
            .read_only = opts.read_only,
            .blocking_server_request_count = 0,
            .request_deadline_ms = opts.request_deadline_ms,
            .transport_identity = kind.text(),
            .overload_retry_policy = opts.overload_retry_policy,
            .overload_retry_seed = overload_retry_seed,
            .overload_retry_telemetry = opts.overload_retry_telemetry,
        };
        errdefer {
            client.close();
            client.deinit();
        }
        try client.handshake(opts);
        return client;
    }

    pub fn deinit(self: *Client) void {
        if (self.last_error) |owned| self.allocator.free(owned);
        self.last_error = null;
        if (self.last_unsupported_server_request) |owned| self.allocator.free(owned);
        self.last_unsupported_server_request = null;
        if (self.initialize_response_json) |owned| self.allocator.free(owned);
        self.initialize_response_json = null;
        self.line_buf.deinit(self.allocator);
        if (self.websocket) |*websocket| websocket.deinit();
    }

    pub fn transportIdentity(self: *const Client) []const u8 {
        return self.transport_identity;
    }

    pub fn initializeResponseJson(self: *const Client) ?[]const u8 {
        return self.initialize_response_json;
    }

    pub fn close(self: *Client) void {
        if (self.websocket) |*websocket| websocket.close();
        const process_group_id = self.process_group_id;
        self.process_group_id = null;
        if (self.child) |*child| {
            retireStdioChild(self.io, child, process_group_id);
        } else if (process_group_id) |group_id| {
            websocket_transport.forceKillProcessGroup(group_id);
            _ = websocket_transport.waitForProcessGroupExit(
                group_id,
                websocket_transport.owner_watchdog_shutdown_grace_ms,
            );
        }
    }

    pub fn lastError(self: *const Client) ?[]const u8 {
        return self.last_error;
    }

    pub fn blockingServerRequestCount(self: *const Client) u64 {
        return self.blocking_server_request_count;
    }

    pub fn lastUnsupportedServerRequest(self: *const Client) ?[]const u8 {
        return self.last_unsupported_server_request;
    }

    pub fn requestJson(self: *Client, method: []const u8, params_json: ?[]const u8) ![]u8 {
        return self.requestJsonCaptureNotificationsInternal(method, params_json, null, null);
    }

    pub fn requestJsonWithSendObserver(
        self: *Client,
        method: []const u8,
        params_json: ?[]const u8,
        send_observer: RequestSendObserver,
    ) ![]u8 {
        return self.requestJsonCaptureNotificationsInternal(
            method,
            params_json,
            null,
            send_observer,
        );
    }

    pub fn requestJsonCaptureNotifications(
        self: *Client,
        method: []const u8,
        params_json: ?[]const u8,
        notification_lines: ?*std.ArrayList([]u8),
    ) ![]u8 {
        return self.requestJsonCaptureNotificationsInternal(
            method,
            params_json,
            notification_lines,
            null,
        );
    }

    pub fn requestJsonCaptureNotificationsWithSendObserver(
        self: *Client,
        method: []const u8,
        params_json: ?[]const u8,
        notification_lines: *std.ArrayList([]u8),
        send_observer: RequestSendObserver,
    ) ![]u8 {
        return self.requestJsonCaptureNotificationsInternal(
            method,
            params_json,
            notification_lines,
            send_observer,
        );
    }

    fn requestJsonCaptureNotificationsInternal(
        self: *Client,
        method: []const u8,
        params_json: ?[]const u8,
        notification_lines: ?*std.ArrayList([]u8),
        send_observer: ?RequestSendObserver,
    ) ![]u8 {
        try validateOverloadRetryPolicy(self.overload_retry_policy);
        const previous_deadline_ms = self.request_deadline_ms;
        if (previous_deadline_ms == null) {
            self.request_deadline_ms = monotonicMillis() + default_request_timeout_ms;
        }
        defer self.request_deadline_ms = previous_deadline_ms;
        self.request_send_started = false;
        if (self.overload_retry_telemetry) |telemetry| telemetry.reset();
        var captured_notification_bytes = try capturedNotificationBytes(notification_lines);
        var interleaved: usize = 0;
        var retry_index: u32 = 0;
        // The retry policy and request deadline bound this request-attempt loop.
        while (true) { // tiger: event-loop
            if (monotonicMillis() >= self.request_deadline_ms.?) return error.ConnectionTimedOut;
            const request_id = self.next_request_id;
            self.next_request_id += 1;
            if (self.overload_retry_telemetry) |telemetry| telemetry.wire_attempts += 1;

            try self.sendRequest(
                request_id,
                method,
                params_json,
                if (retry_index == 0) send_observer else null,
            );
            const response = try self.awaitRequestAttempt(
                request_id,
                notification_lines,
                &captured_notification_bytes,
                &interleaved,
            );
            switch (response) {
                .success => |result| {
                    self.clearLastError();
                    return result;
                },
                .rpc_error => |rpc_error| {
                    self.setLastErrorOwned(rpc_error.json);
                    if (!rpc_error.retryable_overload) return error.RequestFailed;
                    try self.waitForOverloadRetry(retry_index);
                    retry_index += 1;
                },
            }
        }
    }

    fn waitForOverloadRetry(self: *Client, retry_index: u32) !void {
        if (self.overload_retry_telemetry) |telemetry| telemetry.overload_responses += 1;
        if (retry_index >= self.overload_retry_policy.max_retries) {
            if (self.overload_retry_telemetry) |telemetry| telemetry.exhausted = true;
            return error.RequestFailed;
        }
        const delay_ms = overloadRetryDelayMs(
            self.overload_retry_policy,
            retry_index,
            self.overload_retry_seed,
        );
        if (self.overload_retry_telemetry) |telemetry| {
            telemetry.delays_ms[telemetry.delay_count] = delay_ms;
            telemetry.delay_count += 1;
            telemetry.retries += 1;
        }
        const remaining_ms = self.request_deadline_ms.? - monotonicMillis();
        if (remaining_ms <= 0 or delay_ms > remaining_ms) return error.ConnectionTimedOut;
        try std.Io.sleep(self.io, .fromMilliseconds(delay_ms), .awake);
    }

    fn capturedNotificationBytes(notification_lines: ?*std.ArrayList([]u8)) !usize {
        const lines = notification_lines orelse return 0;
        if (lines.items.len > max_captured_notifications) {
            return error.AppServerNotificationLimitExceeded;
        }
        var total: usize = 0;
        for (lines.items) |line| {
            total = try addCapturedNotificationBytes(total, line.len);
        }
        return total;
    }

    const RequestAttemptResponse = union(enum) {
        success: []u8,
        rpc_error: struct {
            json: []u8,
            retryable_overload: bool,
        },
    };

    fn awaitRequestAttempt(
        self: *Client,
        request_id: i64,
        notification_lines: ?*std.ArrayList([]u8),
        captured_notification_bytes: *usize,
        interleaved: *usize,
    ) !RequestAttemptResponse {
        // The explicit interleaving cap below bounds this response-routing loop.
        while (true) { // tiger: event-loop
            interleaved.* += 1;
            if (interleaved.* > max_interleaved_messages) {
                return error.AppServerInterleavingLimitExceeded;
            }
            const line = (try self.readLineAlloc()) orelse return error.AppServerClosed;
            defer self.allocator.free(line);

            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                line,
                .{},
            ) catch continue;
            defer parsed.deinit();
            const msg_obj = switch (parsed.value) {
                .object => |obj| obj,
                else => continue,
            };

            try self.autoHandleServerRequest(msg_obj);

            if (notification_lines) |lines| {
                if (isNotificationMessage(msg_obj)) {
                    if (lines.items.len >= max_captured_notifications) {
                        return error.AppServerNotificationLimitExceeded;
                    }
                    const updated_bytes = try addCapturedNotificationBytes(
                        captured_notification_bytes.*,
                        line.len,
                    );
                    try lines.append(self.allocator, try self.allocator.dupe(u8, line));
                    captured_notification_bytes.* = updated_bytes;
                }
            }

            const response_id = blk: {
                const id_val = msg_obj.get("id") orelse break :blk null;
                break :blk core_json.intFromValue(id_val);
            };
            if (response_id == null or response_id.? != request_id) continue;

            if (msg_obj.get("error")) |err_val| {
                return .{ .rpc_error = .{
                    .json = try core_json.stringifyAlloc(self.allocator, err_val),
                    .retryable_overload = isStructuredOverloadError(err_val),
                } };
            }
            if (msg_obj.get("result")) |result_val| {
                return .{ .success = try core_json.stringifyAlloc(self.allocator, result_val) };
            }
            return error.InvalidAppServerResponse;
        }
    }

    pub fn swapRequestDeadlineMs(self: *Client, deadline_ms: ?i64) ?i64 {
        const previous = self.request_deadline_ms;
        self.request_deadline_ms = deadline_ms;
        return previous;
    }

    pub fn lastRequestSendStarted(self: *const Client) bool {
        return self.request_send_started;
    }

    fn isNotificationMessage(msg_obj: core_json.ObjectMap) bool {
        return core_json.stringField(msg_obj, "method") != null and msg_obj.get("id") == null;
    }

    fn handshake(self: *Client, opts: ClientOptions) !void {
        const handshake_id: i64 = -1;
        const previous_deadline_ms = self.request_deadline_ms;
        const bounded_handshake_deadline = monotonicMillis() + handshake_timeout_ms;
        if (previous_deadline_ms == null or previous_deadline_ms.? > bounded_handshake_deadline)
            self.request_deadline_ms = bounded_handshake_deadline;
        defer self.request_deadline_ms = previous_deadline_ms;

        const client_name = opts.client_name orelse "cas-zig";
        const client_title = opts.client_title orelse "CAS Zig Client";
        const client_version = opts.client_version orelse "0.1.0";
        const capabilities = try initializeCapabilities(opts).buildAlloc(self.allocator);
        defer self.allocator.free(capabilities);
        const initialize = try initializePayloadAlloc(
            self.allocator,
            handshake_id,
            client_name,
            client_title,
            client_version,
            capabilities,
        );
        defer self.allocator.free(initialize);
        try self.sendPayload(initialize, null);

        while (monotonicMillis() < self.request_deadline_ms.?) {
            const line = (try self.readLineAlloc()) orelse return error.AppServerClosed;
            defer self.allocator.free(line);

            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                line,
                .{},
            ) catch continue;
            defer parsed.deinit();
            const msg_obj = switch (parsed.value) {
                .object => |obj| obj,
                else => continue,
            };

            try self.autoHandleServerRequest(msg_obj);

            const response_id = blk: {
                const id_val = msg_obj.get("id") orelse break :blk null;
                break :blk core_json.intFromValue(id_val);
            };
            if (response_id == null or response_id.? != handshake_id) continue;

            if (msg_obj.get("error")) |err_val| {
                const err_json = try core_json.stringifyAlloc(self.allocator, err_val);
                self.setLastErrorOwned(err_json);
                return error.HandshakeFailed;
            }
            const result = msg_obj.get("result") orelse return error.InvalidAppServerResponse;
            if (self.initialize_response_json) |owned| self.allocator.free(owned);
            self.initialize_response_json = try core_json.stringifyAlloc(self.allocator, result);

            const Initialized = struct {
                method: []const u8,
            };
            try self.sendToServer(Initialized{ .method = "initialized" }, null);
            return;
        }

        try self.setLastError("Handshake timed out waiting for initialize response");
        return error.HandshakeTimeout;
    }

    fn sendRequest(
        self: *Client,
        request_id: i64,
        method: []const u8,
        params_json: ?[]const u8,
        send_observer: ?RequestSendObserver,
    ) !void {
        if (params_json) |raw| {
            if (raw.len > websocket_transport.max_message_bytes) {
                return error.AppServerMessageTooLarge;
            }
            var parsed_params = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                raw,
                .{},
            );
            defer parsed_params.deinit();

            const ReqWithParams = struct {
                method: []const u8,
                id: i64,
                params: std.json.Value,
            };
            const req = ReqWithParams{
                .method = method,
                .id = request_id,
                .params = parsed_params.value,
            };
            try self.sendToServer(req, send_observer);
        } else {
            const ReqNoParams = struct {
                method: []const u8,
                id: i64,
            };
            const req = ReqNoParams{
                .method = method,
                .id = request_id,
            };
            try self.sendToServer(req, send_observer);
        }
    }

    fn sendToServer(
        self: *Client,
        msg: anytype,
        send_observer: ?RequestSendObserver,
    ) !void {
        var payload_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload_writer.deinit();
        try std.json.Stringify.value(msg, .{}, &payload_writer.writer);
        try self.sendPayload(payload_writer.written(), send_observer);
    }

    fn sendPayload(
        self: *Client,
        payload: []const u8,
        send_observer: ?RequestSendObserver,
    ) !void {
        if (payload.len > websocket_transport.max_message_bytes) {
            return error.AppServerMessageTooLarge;
        }
        switch (self.transport_kind) {
            .stdio => {
                if (send_observer) |observer| try observer.before_send(observer.context);
                self.request_send_started = true;
                const deadline_ms = self.request_deadline_ms orelse
                    monotonicMillis() + default_request_timeout_ms;
                writeFileAllUntil(self.stdin_file.?, payload, deadline_ms) catch |err| {
                    self.close();
                    return err;
                };
                writeFileAllUntil(self.stdin_file.?, "\n", deadline_ms) catch |err| {
                    self.close();
                    return err;
                };
            },
            .websocket, .unix_socket => try self.sendWebSocket(payload, send_observer),
        }
    }

    const max_exact_response_bytes: usize = max_server_request_carrier_bytes;

    const JsonRpcId = union(enum) {
        integer: i64,
        string: []const u8,

        fn parse(value: std.json.Value) ?JsonRpcId {
            return switch (value) {
                .integer => |id| .{ .integer = id },
                .string => |id| .{ .string = id },
                else => null,
            };
        }
    };

    const ServerRequestMethod = ServerRequestHandlerKind;

    const ErrorReply = struct {
        code: i64,
        message: []const u8,
    };

    const ServerReply = union(enum) {
        result_json: []u8,
        server_error: ErrorReply,

        fn deinit(reply: *ServerReply, allocator: std.mem.Allocator) void {
            switch (reply.*) {
                .result_json => |owned| allocator.free(owned),
                .server_error => {},
            }
        }
    };

    fn autoHandleServerRequest(self: *Client, msg_obj: core_json.ObjectMap) !void {
        const method = core_json.stringField(msg_obj, "method") orelse return;
        const request_method = ServerRequestMethod.parse(method);
        const id_value = msg_obj.get("id") orelse {
            if (request_method != .unknown) return error.MalformedServerRequest;
            return;
        };
        const id = JsonRpcId.parse(id_value) orelse {
            if (request_method != .unknown) return error.MalformedServerRequest;
            return;
        };
        self.blocking_server_request_count += 1;

        var reply = try self.prepareServerReply(request_method, msg_obj);
        defer reply.deinit(self.allocator);
        self.emitServerReply(id, reply) catch {
            // A failed reply is terminal for this connection: continuing could
            // strand the peer's request while this client reads another frame.
            try self.poisonServerRequestReply();
            return error.ServerRequestReplyFailed;
        };
        switch (request_method) {
            .auth_tokens_refresh => if (self.auth_refresh_response_json == null)
                return error.ChatGptAuthTokensRefreshProviderUnavailable,
            .attestation_generate => if (self.attestation_response_json == null)
                return error.AttestationProviderUnavailable,
            .unknown => {
                if (self.last_unsupported_server_request) |owned| self.allocator.free(owned);
                self.last_unsupported_server_request = try self.allocator.dupe(u8, method);
                return error.UnsupportedServerRequest;
            },
            else => {},
        }
    }

    fn poisonServerRequestReply(self: *Client) !void {
        self.close();
        try self.setLastError("server request reply write failed");
    }

    fn emitServerReply(self: *Client, id: JsonRpcId, reply: ServerReply) !void {
        const payload = try serverReplyPayloadAlloc(self.allocator, id, reply);
        defer self.allocator.free(payload);
        switch (self.transport_kind) {
            .stdio => {
                const deadline_ms = self.request_deadline_ms orelse
                    monotonicMillis() + default_request_timeout_ms;
                try writeFileAllUntil(self.stdin_file.?, payload, deadline_ms);
                try writeFileAllUntil(self.stdin_file.?, "\n", deadline_ms);
            },
            .websocket, .unix_socket => try self.sendWebSocket(payload, null),
        }
    }

    fn serverReplyPayloadAlloc(
        allocator: std.mem.Allocator,
        id: JsonRpcId,
        reply: ServerReply,
    ) ![]u8 {
        var payload_writer: std.Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();

        try payload_writer.writer.writeAll("{\"id\":");
        switch (id) {
            .integer => |integer| try std.json.Stringify.value(
                integer,
                .{},
                &payload_writer.writer,
            ),
            .string => |string| try std.json.Stringify.value(string, .{}, &payload_writer.writer),
        }
        switch (reply) {
            .result_json => |result_json| {
                try payload_writer.writer.writeAll(",\"result\":");
                try payload_writer.writer.writeAll(result_json);
            },
            .server_error => |server_error| {
                try payload_writer.writer.writeAll(",\"error\":");
                try std.json.Stringify.value(server_error, .{}, &payload_writer.writer);
            },
        }
        try payload_writer.writer.writeAll("}");
        return allocator.dupe(u8, payload_writer.written());
    }

    fn sendWebSocket(
        self: *Client,
        payload: []const u8,
        send_observer: ?RequestSendObserver,
    ) !void {
        const deadline_ms = self.request_deadline_ms orelse
            monotonicMillis() + default_request_timeout_ms;
        var remaining_ms = deadline_ms - monotonicMillis();
        if (remaining_ms <= 0) return error.ConnectionTimedOut;
        if (send_observer) |observer| {
            try observer.before_send(observer.context);
            // Crossing the durable observer boundary owns every subsequent
            // outcome, including a deadline that expires before socket write.
            self.request_send_started = true;
        }
        remaining_ms = deadline_ms - monotonicMillis();
        if (remaining_ms <= 0) return error.ConnectionTimedOut;
        if (send_observer == null) self.request_send_started = true;
        self.websocket.?.sendTextTimeout(payload, @intCast(remaining_ms)) catch |err| switch (err) {
            error.Timeout => return error.ConnectionTimedOut,
            else => return err,
        };
    }

    fn resolveExecDecision(self: *const Client) []const u8 {
        if (self.read_only) return "decline";
        if (self.exec_approval) |decision| return decision;
        return "decline";
    }

    fn resolveFileDecision(self: *const Client) []const u8 {
        if (self.read_only) return "decline";
        if (self.file_approval) |decision| {
            if (!std.mem.eql(u8, decision, "auto")) return decision;
        }
        return "decline";
    }

    fn prepareServerReply(
        self: *Client,
        method: ServerRequestMethod,
        msg_obj: core_json.ObjectMap,
    ) !ServerReply {
        return switch (method) {
            .command_execution_approval => try self.prepareCommandApproval(msg_obj),
            .file_change_approval => .{
                .result_json = try approvalResultAlloc(
                    self.allocator,
                    self.resolveFileDecision(),
                ),
            },
            .permissions_approval => .{ .result_json = try self.preparePermissionsResult(msg_obj) },
            .request_user_input => .{ .result_json = try self.prepareUserInputResult() },
            .mcp_elicitation => .{ .result_json = try self.prepareMcpElicitationResult(msg_obj) },
            .dynamic_tool_call => if (self.dynamic_tool_response_json) |raw|
                .{ .result_json = try self.allocator.dupe(u8, raw) }
            else
                .{ .server_error = .{
                    .code = -32603,
                    .message = "dynamic tool response provider unavailable",
                } },
            .auth_tokens_refresh => if (self.auth_refresh_response_json) |raw|
                .{ .result_json = try self.allocator.dupe(u8, raw) }
            else
                .{ .server_error = .{
                    .code = -32603,
                    .message = "chatgpt auth token refresh provider unavailable",
                } },
            .attestation_generate => if (self.attestation_response_json) |raw|
                .{ .result_json = try self.allocator.dupe(u8, raw) }
            else
                .{ .server_error = .{
                    .code = -32603,
                    .message = "attestation provider unavailable",
                } },
            .current_time_read => .{ .result_json = try std.fmt.allocPrint(
                self.allocator,
                "{{\"currentTimeAt\":{d}}}",
                .{@as(i64, @intCast(@divFloor(
                    std.Io.Clock.real.now(self.io).nanoseconds,
                    1_000_000_000,
                )))},
            ) },
            .apply_patch_approval, .exec_command_approval => .{
                .result_json = try self.allocator.dupe(
                    u8,
                    "{\"decision\":{\"denied\":{\"rejection\":" ++
                        "\"deprecated approval request is unsupported\"}}}",
                ),
            },
            .unknown => .{ .server_error = .{
                .code = -32601,
                .message = "unsupported server request in native cas client",
            } },
        };
    }

    fn prepareCommandApproval(self: *Client, msg_obj: core_json.ObjectMap) !ServerReply {
        _ = msg_obj;
        const decision = self.resolveExecDecision();
        return .{ .result_json = try approvalResultAlloc(self.allocator, decision) };
    }

    fn approvalResultAlloc(allocator: std.mem.Allocator, decision: []const u8) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        try writer.writer.writeAll("{\"decision\":");
        try std.json.Stringify.value(decision, .{}, &writer.writer);
        try writer.writer.writeAll("}");
        return allocator.dupe(u8, writer.written());
    }

    fn preparePermissionsResult(self: *Client, msg_obj: core_json.ObjectMap) ![]u8 {
        const params_obj = core_json.objectField(msg_obj, "params");
        const mode = self.resolvePermissionsApproval();
        if (mode == .deny or params_obj == null) {
            return self.allocator.dupe(u8, "{\"permissions\":{},\"scope\":\"turn\"}");
        }

        const permissions_val = params_obj.?.get("permissions") orelse {
            return self.allocator.dupe(u8, "{\"permissions\":{},\"scope\":\"turn\"}");
        };
        const permissions_json = try core_json.stringifyAlloc(self.allocator, permissions_val);
        defer self.allocator.free(permissions_json);
        const response_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"permissions\":{s},\"scope\":\"{s}\"}}",
            .{ permissions_json, switch (mode) {
                .grant_turn => "turn",
                .grant_session => "session",
                .deny => "turn",
            } },
        );
        return response_json;
    }

    fn prepareUserInputResult(self: *Client) ![]u8 {
        if (self.request_user_input_response_json) |raw| {
            return self.allocator.dupe(u8, raw);
        }
        return self.allocator.dupe(u8, "{\"answers\":{}}");
    }

    fn prepareMcpElicitationResult(self: *Client, msg_obj: core_json.ObjectMap) ![]u8 {
        const params_obj = core_json.objectField(msg_obj, "params");
        const mode = if (params_obj) |params| core_json.stringField(params, "mode") else null;
        const action = self.resolveElicitationAction();
        const accepts_exact_content = if (mode) |value|
            std.mem.eql(u8, value, "form") or std.mem.eql(u8, value, "openai/form")
        else
            false;
        if (!accepts_exact_content) {
            const conservative_action: []const u8 = if (action == .cancel) "cancel" else "decline";
            return std.fmt.allocPrint(
                self.allocator,
                "{{\"action\":\"{s}\",\"content\":null,\"_meta\":null}}",
                .{conservative_action},
            );
        }
        if (self.elicitation_response_json) |raw| return self.allocator.dupe(u8, raw);
        const content_json = self.elicitation_content_json orelse "null";
        return switch (action) {
            .accept => std.fmt.allocPrint(
                self.allocator,
                "{{\"action\":\"accept\",\"content\":{s},\"_meta\":null}}",
                .{content_json},
            ),
            .decline => self.allocator.dupe(
                u8,
                "{\"action\":\"decline\",\"content\":null,\"_meta\":null}",
            ),
            .cancel => self.allocator.dupe(
                u8,
                "{\"action\":\"cancel\",\"content\":null,\"_meta\":null}",
            ),
        };
    }

    const PermissionsApproval = enum {
        deny,
        grant_turn,
        grant_session,
    };

    fn resolvePermissionsApproval(self: *const Client) PermissionsApproval {
        if (self.read_only) return .deny;
        if (self.permissions_approval) |decision| {
            if (std.mem.eql(u8, decision, "grant-session")) return .grant_session;
            if (std.mem.eql(u8, decision, "grant-turn")) return .grant_turn;
        }
        return .deny;
    }

    const McpElicitationResponseAction = enum {
        accept,
        decline,
        cancel,
    };

    fn resolveElicitationAction(self: *const Client) McpElicitationResponseAction {
        if (self.elicitation_action) |action| {
            if (std.mem.eql(u8, action, "accept")) return .accept;
            if (std.mem.eql(u8, action, "cancel")) return .cancel;
        }
        return .decline;
    }

    fn setLastErrorOwned(self: *Client, owned: []u8) void {
        if (self.last_error) |existing| self.allocator.free(existing);
        self.last_error = owned;
    }

    fn clearLastError(self: *Client) void {
        if (self.last_error) |existing| self.allocator.free(existing);
        self.last_error = null;
    }

    fn setLastError(self: *Client, text: []const u8) !void {
        const duped = try self.allocator.dupe(u8, text);
        self.setLastErrorOwned(duped);
    }

    fn readLineAlloc(self: *Client) !?[]u8 {
        switch (self.transport_kind) {
            .websocket, .unix_socket => {
                const deadline_ms = self.request_deadline_ms orelse
                    return try self.websocket.?.readTextAlloc();
                const remaining_ms = deadline_ms - monotonicMillis();
                if (remaining_ms <= 0) return error.ConnectionTimedOut;
                return self.websocket.?.readTextAllocTimeout(
                    @intCast(remaining_ms),
                ) catch |err| switch (err) {
                    error.Timeout => return error.ConnectionTimedOut,
                    else => err,
                };
            },
            .stdio => {},
        }

        while (true) { // tiger: event-loop -- bounded by owner state or deadline.
            if (std.mem.indexOfScalar(u8, self.line_buf.items, '\n')) |nl_idx| {
                const line = try self.allocator.dupe(u8, self.line_buf.items[0..nl_idx]);
                const keep_from = nl_idx + 1;
                const keep_len = self.line_buf.items.len - keep_from;
                if (keep_len > 0) {
                    std.mem.copyForwards(
                        u8,
                        self.line_buf.items[0..keep_len],
                        self.line_buf.items[keep_from..],
                    );
                }
                self.line_buf.items.len = keep_len;
                return line;
            }

            var tmp: [1]u8 = undefined;
            if (self.request_deadline_ms) |deadline_ms| {
                try waitFileReadableUntil(self.stdout_file.?, deadline_ms);
            }
            var reader = self.stdout_file.?.reader(self.io, &.{});
            const n = try reader.interface.readSliceShort(tmp[0..]);
            if (n == 0) {
                if (self.line_buf.items.len == 0) return null;
                const tail = try self.allocator.dupe(u8, self.line_buf.items);
                self.line_buf.items.len = 0;
                return tail;
            }
            if (self.line_buf.items.len > websocket_transport.max_message_bytes - n) {
                self.close();
                return error.AppServerMessageTooLarge;
            }
            try self.line_buf.appendSlice(self.allocator, tmp[0..n]);
        }
    }
};

pub const max_actor_outbound_queue: usize = 1024;
pub const max_actor_subscriptions: usize = 64;
pub const max_actor_server_request_queue: usize = 128;

pub const ActorOptions = struct {
    outbound_queue_capacity: usize = 128,
    server_request_queue_capacity: usize = 32,
    default_request_timeout_ms: u32 = 30_000,
    server_request_timeout_ms: u32 = 30_000,
    overload_retry_policy: OverloadRetryPolicy = .{},
    overload_retry_seed: ?u64 = null,
    server_request_handler: ?protocol.ServerRequestHandler = null,
};

const ActorMutex = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *ActorMutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *ActorMutex) void {
        self.state.unlock();
    }
};

const ActorPending = struct {
    done: bool = false,
    is_error: bool = false,
    response_json: ?[]u8 = null,
};

const ActorOutbound = struct {
    payload: []u8,
    deadline_ms: i64,
};

const ActorServerRequest = struct {
    id_json: []u8,
    method: []u8,
    raw_json: []u8,
    deadline_ms: i64,

    fn deinit(self: ActorServerRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.id_json);
        allocator.free(self.method);
        allocator.free(self.raw_json);
    }
};

const ActorState = struct {
    allocator: std.mem.Allocator,
    client: Client,
    mutex: ActorMutex = .{},
    terminal: protocol.TerminalState = .running,
    transport_closed: bool = false,
    outbound: std.ArrayList(ActorOutbound) = .empty,
    outbound_capacity: usize,
    server_requests: std.ArrayList(ActorServerRequest) = .empty,
    server_request_capacity: usize,
    server_request_timeout_ms: u32,
    pending: std.AutoHashMap(i64, *ActorPending),
    subscriptions: std.ArrayList(protocol.NotificationHandler) = .empty,
    server_request_handler: ?protocol.ServerRequestHandler,
    next_request_id: i64 = 1,
    default_request_timeout_ms: u32,
    overload_retry_policy: OverloadRetryPolicy,
    overload_retry_seed: u64,
    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    handler_thread: ?std.Thread = null,

    fn deinit(self: *ActorState) void {
        for (self.outbound.items) |item| self.allocator.free(item.payload);
        self.outbound.deinit(self.allocator);
        for (self.server_requests.items) |item| item.deinit(self.allocator);
        self.server_requests.deinit(self.allocator);
        self.pending.deinit();
        self.subscriptions.deinit(self.allocator);
        self.client.deinit();
    }
};

/// Owner-lived app-server actor. Exactly one reader owns response routing;
/// callers may issue concurrent requests while the bounded writer queue owns
/// all transport writes.
pub const Actor = struct {
    state: *ActorState,

    fn initOwned(
        allocator: std.mem.Allocator,
        synchronous: Client,
        options: ActorOptions,
    ) !Actor {
        var owned_client = synchronous;
        var client_owned = true;
        errdefer if (client_owned) {
            owned_client.close();
            owned_client.deinit();
        };
        if (options.outbound_queue_capacity == 0 or
            options.outbound_queue_capacity > max_actor_outbound_queue or
            options.server_request_queue_capacity == 0 or
            options.server_request_queue_capacity > max_actor_server_request_queue or
            options.default_request_timeout_ms == 0 or
            options.server_request_timeout_ms == 0)
        {
            return error.InvalidActorOptions;
        }
        try validateOverloadRetryPolicy(options.overload_retry_policy);
        const seed = try resolveOverloadRetrySeed(options.overload_retry_seed, owned_client.io);

        const state = try allocator.create(ActorState);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .client = owned_client,
            .outbound_capacity = options.outbound_queue_capacity,
            .server_request_capacity = options.server_request_queue_capacity,
            .server_request_timeout_ms = options.server_request_timeout_ms,
            .pending = std.AutoHashMap(i64, *ActorPending).init(allocator),
            .server_request_handler = options.server_request_handler,
            .default_request_timeout_ms = options.default_request_timeout_ms,
            .overload_retry_policy = options.overload_retry_policy,
            .overload_retry_seed = seed,
        };
        client_owned = false;
        // The synchronous client deadline is request-scoped. The actor owns
        // deadlines per pending request instead of sharing one transport field.
        state.client.request_deadline_ms = null;

        state.writer_thread = std.Thread.spawn(.{}, actorWriterMain, .{state}) catch |err| {
            state.client.close();
            state.deinit();
            return err;
        };
        state.handler_thread = std.Thread.spawn(.{}, actorHandlerMain, .{state}) catch |err| {
            actorSetTerminal(state, .stopped);
            actorCloseTransportOnce(state);
            state.writer_thread.?.join();
            state.deinit();
            return err;
        };
        state.reader_thread = std.Thread.spawn(.{}, actorReaderMain, .{state}) catch |err| {
            actorSetTerminal(state, .stopped);
            actorCloseTransportOnce(state);
            state.writer_thread.?.join();
            state.handler_thread.?.join();
            state.deinit();
            return err;
        };
        return .{ .state = state };
    }

    pub fn deinit(self: *Actor) void {
        const state = self.state;
        actorSetTerminal(state, .stopped);
        // Closing the underlying transport releases a reader blocked in I/O.
        actorCloseTransportOnce(state);
        if (state.writer_thread) |thread| thread.join();
        if (state.reader_thread) |thread| thread.join();
        if (state.handler_thread) |thread| thread.join();
        state.deinit();
        state.allocator.destroy(state);
        self.* = undefined;
    }

    pub fn terminalState(self: *const Actor) protocol.TerminalState {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        return self.state.terminal;
    }

    pub fn subscribe(
        self: *Actor,
        subscription: protocol.NotificationHandler,
    ) !void {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        if (self.state.terminal != .running) return actorTerminalError(self.state.terminal);
        if (self.state.subscriptions.items.len >= max_actor_subscriptions) {
            return error.NotificationSubscriptionLimitExceeded;
        }
        try self.state.subscriptions.append(self.state.allocator, subscription);
    }

    pub fn setServerRequestHandler(
        self: *Actor,
        handler: ?protocol.ServerRequestHandler,
    ) !void {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        if (self.state.terminal != .running) return actorTerminalError(self.state.terminal);
        self.state.server_request_handler = handler;
    }

    pub fn requestJson(
        self: *Actor,
        method: []const u8,
        params_json: ?[]const u8,
        timeout_ms: ?u32,
    ) ![]u8 {
        const budget_ms = timeout_ms orelse self.state.default_request_timeout_ms;
        if (budget_ms == 0) return error.InvalidRequestDeadline;
        const deadline = monotonicMillis() + @as(i64, budget_ms);
        var retry_index: u32 = 0;
        while (true) { // tiger: event-loop -- bounded by owner state or deadline.
            const remaining_ms = deadline - monotonicMillis();
            if (remaining_ms <= 0) return error.RequestDeadlineExceeded;
            const response = try self.requestOnce(
                method,
                params_json,
                @intCast(remaining_ms),
            );
            if (!response.is_error) return response.json;

            const retryable = actorResponseIsOverload(self.state.allocator, response.json);
            if (!retryable or retry_index >= self.state.overload_retry_policy.max_retries) {
                self.state.allocator.free(response.json);
                return error.RequestFailed;
            }
            self.state.allocator.free(response.json);
            const delay_ms = overloadRetryDelayMs(
                self.state.overload_retry_policy,
                retry_index,
                self.state.overload_retry_seed,
            );
            if (@as(i64, delay_ms) >= deadline - monotonicMillis()) {
                return error.RequestDeadlineExceeded;
            }
            try std.Io.sleep(self.state.client.io, .fromMilliseconds(delay_ms), .awake);
            retry_index += 1;
        }
    }

    const Response = struct {
        json: []u8,
        is_error: bool,
    };

    fn requestOnce(
        self: *Actor,
        method: []const u8,
        params_json: ?[]const u8,
        timeout_ms: u32,
    ) !Response {
        if (timeout_ms == 0) return error.InvalidRequestDeadline;
        const deadline = monotonicMillis() + @as(i64, timeout_ms);
        var pending: ActorPending = .{};

        self.state.mutex.lock();
        if (self.state.terminal != .running) {
            const terminal = self.state.terminal;
            self.state.mutex.unlock();
            return actorTerminalError(terminal);
        }
        const request_id = self.state.next_request_id;
        self.state.next_request_id += 1;
        self.state.pending.put(request_id, &pending) catch |err| {
            self.state.mutex.unlock();
            return err;
        };
        self.state.mutex.unlock();
        errdefer {
            self.state.mutex.lock();
            _ = self.state.pending.remove(request_id);
            self.state.mutex.unlock();
        }

        const payload = try actorRequestPayloadAlloc(
            self.state.allocator,
            request_id,
            method,
            params_json,
        );
        try actorEnqueueOwned(self.state, payload, deadline);

        while (true) { // tiger: event-loop -- bounded by owner state or deadline.
            self.state.mutex.lock();
            if (pending.done) {
                _ = self.state.pending.remove(request_id);
                const result = Response{
                    .json = pending.response_json.?,
                    .is_error = pending.is_error,
                };
                self.state.mutex.unlock();
                return result;
            }
            if (self.state.terminal != .running) {
                _ = self.state.pending.remove(request_id);
                const terminal = self.state.terminal;
                self.state.mutex.unlock();
                return actorTerminalError(terminal);
            }
            if (monotonicMillis() >= deadline) {
                _ = self.state.pending.remove(request_id);
                self.state.mutex.unlock();
                return error.RequestDeadlineExceeded;
            }
            self.state.mutex.unlock();
            try std.Io.sleep(self.state.client.io, .fromMilliseconds(2), .awake);
        }
    }
};

fn actorWriterMain(state: *ActorState) void {
    while (true) { // tiger: event-loop -- bounded by owner state or deadline.
        state.mutex.lock();
        if (state.terminal != .running and state.outbound.items.len == 0) {
            state.mutex.unlock();
            return;
        }
        const maybe_item: ?ActorOutbound = if (state.outbound.items.len == 0)
            null
        else
            state.outbound.orderedRemove(0);
        state.mutex.unlock();

        if (maybe_item) |item| {
            defer state.allocator.free(item.payload);
            if (actorOutboundExpired(item)) continue;
            const previous_deadline = state.client.swapRequestDeadlineMs(item.deadline_ms);
            defer _ = state.client.swapRequestDeadlineMs(previous_deadline);
            state.client.sendPayload(item.payload, null) catch {
                actorSetTerminal(state, .poisoned);
                actorCloseTransportOnce(state);
                return;
            };
        } else {
            std.Io.sleep(state.client.io, .fromMilliseconds(2), .awake) catch {
                actorSetTerminal(state, .poisoned);
                actorCloseTransportOnce(state);
                return;
            };
        }
    }
}

fn actorOutboundExpired(item: ActorOutbound) bool {
    return monotonicMillis() >= item.deadline_ms;
}

fn actorHandlerMain(state: *ActorState) void {
    while (true) { // tiger: event-loop -- bounded by owner state or deadline.
        state.mutex.lock();
        if (state.terminal != .running) {
            state.mutex.unlock();
            return;
        }
        const maybe_work: ?ActorServerRequest = if (state.server_requests.items.len == 0)
            null
        else
            state.server_requests.orderedRemove(0);
        state.mutex.unlock();

        if (maybe_work) |work| {
            defer work.deinit(state.allocator);
            actorHandleServerRequest(state, work) catch |err| switch (err) {
                error.RequestDeadlineExceeded => continue,
                else => {
                    actorSetTerminal(state, .poisoned);
                    actorCloseTransportOnce(state);
                    return;
                },
            };
        } else {
            std.Io.sleep(state.client.io, .fromMilliseconds(2), .awake) catch {
                actorSetTerminal(state, .poisoned);
                actorCloseTransportOnce(state);
                return;
            };
        }
    }
}

fn actorReaderMain(state: *ActorState) void {
    while (true) { // tiger: event-loop -- bounded by owner state or deadline.
        state.mutex.lock();
        const running = state.terminal == .running;
        state.mutex.unlock();
        if (!running) return;

        const maybe_line = state.client.readLineAlloc() catch {
            actorSetTerminal(state, .disconnected);
            actorCloseTransportOnce(state);
            return;
        };
        const line = maybe_line orelse {
            actorSetTerminal(state, .disconnected);
            actorCloseTransportOnce(state);
            return;
        };
        defer state.allocator.free(line);
        actorRouteLine(state, line) catch {
            actorSetTerminal(state, .poisoned);
            actorCloseTransportOnce(state);
            return;
        };
    }
}

fn actorRouteLine(state: *ActorState, line: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, state.allocator, line, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidAppServerEnvelope,
    };
    const method = core_json.stringField(object, "method");
    const id_value = object.get("id");

    if (method != null and id_value == null) {
        try actorDispatchNotification(state, method.?, line);
        return;
    }
    if (method != null and id_value != null) {
        try actorDispatchServerRequest(state, method.?, id_value.?, line);
        return;
    }

    const response_id = id_value orelse return error.InvalidAppServerEnvelope;
    const integer_id = core_json.intFromValue(response_id) orelse
        return error.InvalidAppServerEnvelope;
    const response_value = object.get("result") orelse object.get("error") orelse
        return error.InvalidAppServerEnvelope;
    const response_json = try core_json.stringifyAlloc(state.allocator, response_value);
    errdefer state.allocator.free(response_json);

    state.mutex.lock();
    defer state.mutex.unlock();
    const pending = state.pending.get(integer_id) orelse {
        state.allocator.free(response_json);
        return;
    };
    pending.response_json = response_json;
    pending.is_error = object.get("error") != null;
    pending.done = true;
}

fn actorDispatchNotification(
    state: *ActorState,
    method: []const u8,
    line: []const u8,
) !void {
    state.mutex.lock();
    const subscriptions = state.allocator.dupe(
        protocol.NotificationHandler,
        state.subscriptions.items,
    ) catch |err| {
        state.mutex.unlock();
        return err;
    };
    state.mutex.unlock();
    defer state.allocator.free(subscriptions);
    const notification = protocol.Notification{ .method = method, .raw_json = line };
    for (subscriptions) |subscription| subscription.handle(subscription.context, notification);
}

fn actorDispatchServerRequest(
    state: *ActorState,
    method: []const u8,
    id_value: std.json.Value,
    line: []const u8,
) !void {
    switch (id_value) {
        .integer, .string => {},
        else => return error.InvalidAppServerEnvelope,
    }
    const deadline_ms = monotonicMillis() + @as(i64, state.server_request_timeout_ms);
    state.mutex.lock();
    const handler = state.server_request_handler;
    const queue_full = state.server_requests.items.len >= state.server_request_capacity;
    state.mutex.unlock();
    if (handler == null) return actorEnqueueServerError(
        state,
        id_value,
        -32601,
        "server request handler unavailable",
        deadline_ms,
    );
    if (queue_full) return actorEnqueueServerError(
        state,
        id_value,
        -32000,
        "server request queue is full",
        deadline_ms,
    );

    var work = ActorServerRequest{
        .id_json = try core_json.stringifyAlloc(state.allocator, id_value),
        .method = undefined,
        .raw_json = undefined,
        .deadline_ms = deadline_ms,
    };
    errdefer state.allocator.free(work.id_json);
    work.method = try state.allocator.dupe(u8, method);
    errdefer state.allocator.free(work.method);
    work.raw_json = try state.allocator.dupe(u8, line);
    errdefer state.allocator.free(work.raw_json);

    state.mutex.lock();
    if (state.terminal != .running) {
        const terminal = state.terminal;
        state.mutex.unlock();
        return actorTerminalError(terminal);
    }
    state.server_requests.append(state.allocator, work) catch |err| {
        state.mutex.unlock();
        return err;
    };
    state.mutex.unlock();
}

fn actorHandleServerRequest(state: *ActorState, work: ActorServerRequest) !void {
    if (monotonicMillis() >= work.deadline_ms) return error.RequestDeadlineExceeded;
    var parsed_id = try std.json.parseFromSlice(
        std.json.Value,
        state.allocator,
        work.id_json,
        .{},
    );
    defer parsed_id.deinit();
    const request_id: protocol.RequestId = switch (parsed_id.value) {
        .integer => |value| .{ .integer = value },
        .string => |value| .{ .string = value },
        else => return error.InvalidAppServerEnvelope,
    };
    state.mutex.lock();
    const handler = state.server_request_handler;
    state.mutex.unlock();
    const configured = handler orelse return actorEnqueueServerError(
        state,
        parsed_id.value,
        -32601,
        "server request handler unavailable",
        work.deadline_ms,
    );
    const request = protocol.ServerRequest{
        .id = request_id,
        .method = work.method,
        .raw_json = work.raw_json,
        .deadline_ms = work.deadline_ms,
    };
    const result_json = configured.handle(configured.context, request, state.allocator) catch
        return actorEnqueueServerError(
            state,
            parsed_id.value,
            -32603,
            "server request handler failed",
            work.deadline_ms,
        );
    defer state.allocator.free(result_json);
    const payload = try actorServerResultPayloadAlloc(
        state.allocator,
        parsed_id.value,
        result_json,
    );
    try actorEnqueueOwned(state, payload, work.deadline_ms);
}

fn actorEnqueueServerError(
    state: *ActorState,
    id_value: std.json.Value,
    code: i64,
    message: []const u8,
    deadline_ms: i64,
) !void {
    var output: std.Io.Writer.Allocating = .init(state.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"id\":");
    try std.json.Stringify.value(id_value, .{}, &output.writer);
    try output.writer.writeAll(",\"error\":{\"code\":");
    try std.json.Stringify.value(code, .{}, &output.writer);
    try output.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(message, .{}, &output.writer);
    try output.writer.writeAll("}}");
    try actorEnqueueOwned(
        state,
        try state.allocator.dupe(u8, output.written()),
        deadline_ms,
    );
}

fn actorServerResultPayloadAlloc(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    result_json: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"id\":");
    try std.json.Stringify.value(id_value, .{}, &output.writer);
    try output.writer.writeAll(",\"result\":");
    try output.writer.writeAll(result_json);
    try output.writer.writeByte('}');
    return allocator.dupe(u8, output.written());
}

fn actorRequestPayloadAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    method: []const u8,
    params_json: ?[]const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"method\":");
    try std.json.Stringify.value(method, .{}, &output.writer);
    try output.writer.writeAll(",\"id\":");
    try std.json.Stringify.value(id, .{}, &output.writer);
    if (params_json) |raw| {
        if (raw.len > websocket_transport.max_message_bytes) return error.AppServerMessageTooLarge;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        try output.writer.writeAll(",\"params\":");
        try std.json.Stringify.value(parsed.value, .{}, &output.writer);
    }
    try output.writer.writeByte('}');
    return allocator.dupe(u8, output.written());
}

fn actorEnqueueOwned(state: *ActorState, payload: []u8, deadline_ms: i64) !void {
    const owned = payload;
    errdefer state.allocator.free(owned);
    while (true) { // tiger: event-loop -- bounded by owner state or deadline.
        state.mutex.lock();
        if (state.terminal != .running) {
            const terminal = state.terminal;
            state.mutex.unlock();
            return actorTerminalError(terminal);
        }
        if (monotonicMillis() >= deadline_ms) {
            state.mutex.unlock();
            return error.RequestDeadlineExceeded;
        }
        if (state.outbound.items.len < state.outbound_capacity) {
            state.outbound.append(state.allocator, .{
                .payload = owned,
                .deadline_ms = deadline_ms,
            }) catch |err| {
                state.mutex.unlock();
                return err;
            };
            state.mutex.unlock();
            return;
        }
        state.mutex.unlock();
        try std.Io.sleep(state.client.io, .fromMilliseconds(2), .awake);
    }
}

fn actorSetTerminal(state: *ActorState, terminal: protocol.TerminalState) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.terminal == .running) state.terminal = terminal;
}

fn actorCloseTransportOnce(state: *ActorState) void {
    state.mutex.lock();
    if (state.transport_closed) {
        state.mutex.unlock();
        return;
    }
    state.transport_closed = true;
    state.mutex.unlock();
    state.client.close();
}

fn actorTerminalError(terminal: protocol.TerminalState) anyerror {
    return switch (terminal) {
        .running => error.ActorNotTerminal,
        .poisoned => error.ActorPoisoned,
        .disconnected => error.ActorDisconnected,
        .stopped => error.ActorStopped,
    };
}

fn actorResponseIsOverload(allocator: std.mem.Allocator, raw: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return false;
    defer parsed.deinit();
    return isStructuredOverloadError(parsed.value);
}

fn retireStdioChild(
    io: std.Io,
    child: *std.process.Child,
    process_group_id: ?u64,
) void {
    if (process_group_id) |group_id| websocket_transport.forceKillProcessGroup(group_id);
    child.kill(io);
    if (process_group_id) |group_id| {
        _ = websocket_transport.waitForProcessGroupExit(
            group_id,
            websocket_transport.owner_watchdog_shutdown_grace_ms,
        );
    }
}

pub fn validateClientOptions(allocator: std.mem.Allocator, opts: ClientOptions) !void {
    try validateServerRequestOptions(allocator, opts);
    try initializeCapabilities(opts).validate(allocator);
    try validateTransportOptions(opts);
    try validateOverloadRetryPolicy(opts.overload_retry_policy);
    try validateCodexEnableFeatures(opts);
}

fn validateCodexEnableFeatures(opts: ClientOptions) !void {
    if (opts.codex_enable_features.len > max_codex_enable_features) {
        return error.TooManyCodexEnableFeatures;
    }
    if (opts.codex_enable_features.len != 0) {
        if (opts.websocket_url != null) return error.CodexEnableFeaturesRequireStdio;
        if (opts.transport) |transport| {
            if (transport != .stdio) return error.CodexEnableFeaturesRequireStdio;
        }
    }
    for (opts.codex_enable_features) |feature| {
        if (feature.len == 0 or feature.len > 128) return error.InvalidCodexEnableFeature;
        for (feature) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-')
            return error.InvalidCodexEnableFeature;
    }
}

fn appendCodexEnableFeatureArgs(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    features: []const []const u8,
) !void {
    for (features) |feature| {
        try argv.append(allocator, "--enable");
        try argv.append(allocator, feature);
    }
}

fn addCapturedNotificationBytes(current: usize, additional: usize) !usize {
    if (current > max_captured_notification_bytes or
        additional > max_captured_notification_bytes - current)
        return error.AppServerNotificationBytesLimitExceeded;
    return current + additional;
}

fn waitFileReadableUntil(file: std.Io.File, deadline_ms: i64) !void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi)
        return error.StdioDeadlineUnsupported;
    try waitFileEventUntil(
        file,
        deadline_ms,
        std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP,
    );
}

fn waitFileWritableUntil(file: std.Io.File, deadline_ms: i64) !void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi)
        return error.StdioDeadlineUnsupported;
    try waitFileEventUntil(
        file,
        deadline_ms,
        std.posix.POLL.OUT | std.posix.POLL.ERR | std.posix.POLL.HUP,
    );
}

fn waitFileEventUntil(file: std.Io.File, deadline_ms: i64, events: i16) !void {
    const remaining_ms = deadline_ms - monotonicMillis();
    if (remaining_ms <= 0) return error.ConnectionTimedOut;
    var fds = [_]std.posix.pollfd{.{
        .fd = file.handle,
        .events = events,
        .revents = 0,
    }};
    const timeout: i32 = @intCast(@min(remaining_ms, std.math.maxInt(i32)));
    if (try std.posix.poll(&fds, timeout) == 0) return error.ConnectionTimedOut;
    if ((fds[0].revents & std.posix.POLL.NVAL) != 0) return error.AppServerClosed;
}

fn writeFileAllUntil(file: std.Io.File, bytes: []const u8, deadline_ms: i64) !void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi)
        return error.StdioDeadlineUnsupported;

    // The kernel terminates this EINTR retry with a non-INTR result.
    const original_flags: usize = while (true) { // tiger: event-loop
        const rc = std.posix.system.fcntl(file.handle, std.posix.F.GETFL, @as(usize, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            else => return error.AppServerWriteFailed,
        }
    };
    const nonblocking_flags = original_flags |
        @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
    // The kernel terminates this EINTR retry with a non-INTR result.
    while (true) { // tiger: event-loop
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.SETFL,
            nonblocking_flags,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.AppServerWriteFailed,
        }
    }
    defer _ = std.posix.system.fcntl(file.handle, std.posix.F.SETFL, original_flags);

    var offset: usize = 0;
    while (offset < bytes.len) {
        try waitFileWritableUntil(file, deadline_ms);
        const rc = std.posix.system.write(file.handle, bytes[offset..].ptr, bytes.len - offset);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const written: usize = @intCast(rc);
                if (written == 0) return error.AppServerClosed;
                offset += written;
            },
            .INTR, .AGAIN => continue,
            .PIPE => return error.AppServerClosed,
            else => return error.AppServerWriteFailed,
        }
    }
}

fn validateTransportOptions(opts: ClientOptions) !void {
    if (opts.transport != null and opts.websocket_url != null) {
        return error.ConflictingTransportOptions;
    }
    if (opts.code_mode_host == null) return;
    if (opts.websocket_url != null) return error.CodeModeHostRequiresManagedLaunch;
    if (opts.transport) |transport| switch (transport) {
        .explicit_websocket, .unix_socket => return error.CodeModeHostRequiresManagedLaunch,
        else => {},
    };
}

fn initializeCapabilities(opts: ClientOptions) InitializeCapabilityBuilder {
    return .{
        .experimental_api = opts.experimental_api,
        .opt_out_notification_methods = opts.opt_out_notification_methods,
        .mcp_server_openai_form_elicitation = hasExactOpenaiFormPolicy(opts),
        .request_attestation = opts.attestation_response_json != null,
        .additional_json = opts.additional_initialize_capabilities_json,
    };
}

fn initializePayloadAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    client_name: []const u8,
    client_title: []const u8,
    client_version: []const u8,
    capabilities_json: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("{\"method\":\"initialize\",\"id\":");
    try std.json.Stringify.value(id, .{}, writer);
    try writer.writeAll(",\"params\":{\"clientInfo\":{\"name\":");
    try std.json.Stringify.value(client_name, .{}, writer);
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(client_title, .{}, writer);
    try writer.writeAll(",\"version\":");
    try std.json.Stringify.value(client_version, .{}, writer);
    try writer.writeAll("},\"capabilities\":");
    try writer.writeAll(capabilities_json);
    try writer.writeAll("}}");
    if (output.written().len > websocket_transport.max_message_bytes) {
        return error.AppServerMessageTooLarge;
    }
    return output.toOwnedSlice();
}

fn hasExactOpenaiFormPolicy(opts: ClientOptions) bool {
    if (opts.elicitation_response_json != null) return true;
    const action = opts.elicitation_action orelse return false;
    if (std.mem.eql(u8, action, "decline") or std.mem.eql(u8, action, "cancel")) return true;
    return std.mem.eql(u8, action, "accept") and opts.elicitation_content_json != null;
}

fn validateServerRequestOptions(allocator: std.mem.Allocator, opts: ClientOptions) !void {
    if (opts.server_request_timeout_ms != null) return error.UnsupportedServerRequestTimeout;
    if (opts.elicitation_response_json != null and
        (opts.elicitation_action != null or opts.elicitation_content_json != null))
    {
        return error.ConflictingElicitationResponsePolicies;
    }
    try validateChoice(opts.exec_approval, &.{ "accept", "acceptForSession", "decline", "cancel" });
    try validateChoice(
        opts.file_approval,
        &.{ "auto", "accept", "acceptForSession", "decline", "cancel" },
    );
    try validateChoice(opts.permissions_approval, &.{ "grant-turn", "grant-session", "deny" });
    try validateChoice(opts.elicitation_action, &.{ "accept", "decline", "cancel" });

    if (opts.request_user_input_response_json) |raw| try validateUserInputCarrier(allocator, raw);
    if (opts.elicitation_content_json) |raw| try validateElicitationContent(allocator, raw);
    if (opts.elicitation_action) |action| {
        if (std.mem.eql(u8, action, "accept") and opts.elicitation_content_json == null) {
            return error.MissingElicitationContent;
        }
    }
    if (opts.elicitation_response_json) |raw| try validateElicitationCarrier(allocator, raw);
    if (opts.dynamic_tool_response_json) |raw| try validateDynamicToolCarrier(allocator, raw);
    if (opts.auth_refresh_response_json) |raw| try validateAuthRefreshCarrier(allocator, raw);
    if (opts.attestation_response_json) |raw| try validateAttestationCarrier(allocator, raw);
}

fn validateUserInputCarrier(allocator: std.mem.Allocator, raw: []const u8) !void {
    var parsed = try parseExactCarrier(allocator, raw);
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidRequestUserInputResponse,
    };
    const answers = object.get("answers") orelse return error.InvalidRequestUserInputResponse;
    const answers_object = switch (answers) {
        .object => |value| value,
        else => return error.InvalidRequestUserInputResponse,
    };
    var answer_iterator = answers_object.iterator();
    while (answer_iterator.next()) |entry| {
        const answer_object = switch (entry.value_ptr.*) {
            .object => |value| value,
            else => return error.InvalidRequestUserInputResponse,
        };
        const answer_values = answer_object.get("answers") orelse
            return error.InvalidRequestUserInputResponse;
        const answer_array = switch (answer_values) {
            .array => |value| value.items,
            else => return error.InvalidRequestUserInputResponse,
        };
        for (answer_array) |answer| {
            if (answer != .string) return error.InvalidRequestUserInputResponse;
        }
    }
}

fn validateElicitationContent(allocator: std.mem.Allocator, raw: []const u8) !void {
    var parsed = try parseExactCarrier(allocator, raw);
    defer parsed.deinit();
    if (parsed.value == .null) return error.InvalidElicitationContent;
}

fn validateElicitationCarrier(allocator: std.mem.Allocator, raw: []const u8) !void {
    var parsed = try parseExactCarrier(allocator, raw);
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidElicitationResponse,
    };
    const action = core_json.stringField(object, "action") orelse
        return error.InvalidElicitationResponse;
    const accepts = std.mem.eql(u8, action, "accept");
    const declines = std.mem.eql(u8, action, "decline");
    const cancels = std.mem.eql(u8, action, "cancel");
    if (!accepts and !declines and !cancels) return error.InvalidElicitationResponse;
    const content = object.get("content");
    if (accepts and (content == null or content.? == .null)) {
        return error.InvalidElicitationResponse;
    }
    if (!accepts and content != null and content.? != .null) {
        return error.InvalidElicitationResponse;
    }
    // `_meta` is intentionally unconstrained by the generated schema and is
    // preserved byte-for-byte by the full response carrier.
}

fn validateDynamicToolCarrier(allocator: std.mem.Allocator, raw: []const u8) !void {
    var parsed = try parseExactCarrier(allocator, raw);
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidDynamicToolResponse,
    };
    const content_items = object.get("contentItems") orelse
        return error.InvalidDynamicToolResponse;
    const success = object.get("success") orelse return error.InvalidDynamicToolResponse;
    const items = switch (content_items) {
        .array => |value| value.items,
        else => return error.InvalidDynamicToolResponse,
    };
    if (success != .bool) return error.InvalidDynamicToolResponse;
    for (items) |item| {
        const item_object = switch (item) {
            .object => |value| value,
            else => return error.InvalidDynamicToolResponse,
        };
        const item_type = core_json.stringField(item_object, "type") orelse
            return error.InvalidDynamicToolResponse;
        const required_field = if (std.mem.eql(u8, item_type, "inputText"))
            "text"
        else if (std.mem.eql(u8, item_type, "inputImage"))
            "imageUrl"
        else if (std.mem.eql(u8, item_type, "inputAudio"))
            "audioUrl"
        else
            return error.InvalidDynamicToolResponse;
        const required_value = item_object.get(required_field) orelse
            return error.InvalidDynamicToolResponse;
        if (required_value != .string) return error.InvalidDynamicToolResponse;
    }
}

fn validateAuthRefreshCarrier(allocator: std.mem.Allocator, raw: []const u8) !void {
    var parsed = try parseExactCarrier(allocator, raw);
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidAuthRefreshResponse,
    };
    const access_token = core_json.stringField(object, "accessToken") orelse
        return error.InvalidAuthRefreshResponse;
    const account_id = core_json.stringField(object, "chatgptAccountId") orelse
        return error.InvalidAuthRefreshResponse;
    if (access_token.len == 0 or account_id.len == 0) return error.InvalidAuthRefreshResponse;
    if (object.get("chatgptPlanType")) |plan| switch (plan) {
        .null, .string => {},
        else => return error.InvalidAuthRefreshResponse,
    };
}

fn validateAttestationCarrier(allocator: std.mem.Allocator, raw: []const u8) !void {
    var parsed = try parseExactCarrier(allocator, raw);
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidAttestationResponse,
    };
    const token = core_json.stringField(object, "token") orelse
        return error.InvalidAttestationResponse;
    if (token.len == 0) return error.InvalidAttestationResponse;
}

fn validateChoice(value: ?[]const u8, allowed: []const []const u8) !void {
    const raw = value orelse return;
    for (allowed) |candidate| {
        if (std.mem.eql(u8, raw, candidate)) return;
    }
    return error.InvalidServerRequestPolicy;
}

fn parseExactCarrier(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !std.json.Parsed(std.json.Value) {
    if (raw.len > Client.max_exact_response_bytes) return error.ServerRequestCarrierTooLarge;
    return std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return error.InvalidServerRequestCarrierJson;
}

pub fn resolveExecutableAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return error.MissingExecutable;

    if (std.mem.indexOfScalar(u8, value, '/') != null) {
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), value, .{}) catch
            return error.ExecutableNotFound;
        return allocator.dupe(u8, value);
    }

    const exe_dir =
        std.process.executableDirPathAlloc(
            std.Io.Threaded.global_single_threaded.io(),
            allocator,
        ) catch null;
    if (exe_dir) |dir| {
        defer allocator.free(dir);
        const sibling = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ dir, value },
        );
        errdefer allocator.free(sibling);
        if (pathExists(sibling)) return sibling;
        allocator.free(sibling);
    }

    const path_env = std.Io.Threaded.global_single_threaded.environString("PATH") orelse
        return error.ExecutableNotFound;
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ dir, value },
        );
        errdefer allocator.free(candidate);
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }

    return error.ExecutableNotFound;
}

fn monotonicMillis() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000));
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch
            return false;
        return true;
    }
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch
        return false;
    return true;
}

pub const ObjectMap = core_json.ObjectMap;

pub fn stringifyValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return core_json.stringifyValueAlloc(allocator, value);
}

pub fn objectField(obj: ObjectMap, key: []const u8) ?ObjectMap {
    return core_json.objectField(obj, key);
}

pub fn stringField(obj: ObjectMap, key: []const u8) ?[]const u8 {
    return core_json.stringField(obj, key);
}

pub fn intField(obj: ObjectMap, key: []const u8) ?i64 {
    return core_json.intField(obj, key);
}

fn serverRequestTestClient() Client {
    return .{
        .allocator = std.testing.allocator,
        .transport_kind = .stdio,
        .child = null,
        .stdin_file = null,
        .stdout_file = null,
        .websocket = null,
        .line_buf = .empty,
        .next_request_id = 1,
        .last_error = null,
        .exec_approval = null,
        .file_approval = null,
        .permissions_approval = null,
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = false,
    };
}

test "server reply payload preserves integer and string request ids" {
    const result = Client.ServerReply{ .result_json = try std.testing.allocator.dupe(u8, "{}") };
    defer std.testing.allocator.free(result.result_json);
    const integer_payload = try Client.serverReplyPayloadAlloc(
        std.testing.allocator,
        .{ .integer = 42 },
        result,
    );
    defer std.testing.allocator.free(integer_payload);
    try std.testing.expectEqualStrings("{\"id\":42,\"result\":{}}", integer_payload);

    const string_payload = try Client.serverReplyPayloadAlloc(
        std.testing.allocator,
        .{ .string = "req-7" },
        result,
    );
    defer std.testing.allocator.free(string_payload);
    try std.testing.expectEqualStrings("{\"id\":\"req-7\",\"result\":{}}", string_payload);
}

test "all contracted server request methods and unknown have one typed reply" {
    const cases = [_]struct { []const u8, Client.ServerRequestMethod }{
        .{ "item/commandExecution/requestApproval", .command_execution_approval },
        .{ "item/fileChange/requestApproval", .file_change_approval },
        .{ "item/permissions/requestApproval", .permissions_approval },
        .{ "item/tool/requestUserInput", .request_user_input },
        .{ "mcpServer/elicitation/request", .mcp_elicitation },
        .{ "item/tool/call", .dynamic_tool_call },
        .{ "account/chatgptAuthTokens/refresh", .auth_tokens_refresh },
        .{ "attestation/generate", .attestation_generate },
        .{ "currentTime/read", .current_time_read },
        .{ "applyPatchApproval", .apply_patch_approval },
        .{ "execCommandApproval", .exec_command_approval },
        .{ "future/serverRequest", .unknown },
    };
    var client = serverRequestTestClient();
    defer client.line_buf.deinit(std.testing.allocator);

    for (cases) |case| {
        try std.testing.expectEqual(case[1], Client.ServerRequestMethod.parse(case[0]));
        const raw = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"id\":1,\"method\":\"{s}\",\"params\":{{\"mode\":\"form\",\"permissions\":{{}}}}}}",
            .{case[0]},
        );
        defer std.testing.allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
        defer parsed.deinit();
        var reply = try client.prepareServerReply(case[1], parsed.value.object);
        defer reply.deinit(std.testing.allocator);
        const payload = try Client.serverReplyPayloadAlloc(
            std.testing.allocator,
            .{ .integer = 1 },
            reply,
        );
        defer std.testing.allocator.free(payload);
        try std.testing.expect(std.mem.startsWith(u8, payload, "{\"id\":1,"));
        try std.testing.expect(std.mem.endsWith(u8, payload, "}"));
    }
}

test "server request defaults never invent approval or user input" {
    var client = serverRequestTestClient();
    defer client.line_buf.deinit(std.testing.allocator);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"params":{"availableDecisions":["acceptForSession",{"acceptWithExecpolicyAmendment":{"profile":"unsafe"}}],"questions":[{"id":"q","options":[{"label":"invented"}]}]}}
    ,
        .{},
    );
    defer parsed.deinit();

    var command = try client.prepareServerReply(.command_execution_approval, parsed.value.object);
    defer command.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"decision\":\"decline\"}", command.result_json);
    var user_input = try client.prepareServerReply(.request_user_input, parsed.value.object);
    defer user_input.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"answers\":{}}", user_input.result_json);
    try std.testing.expect(std.mem.indexOf(u8, user_input.result_json, "invented") == null);
}

test "mcp elicitation is mode aware and url never accepts" {
    var client = serverRequestTestClient();
    defer client.line_buf.deinit(std.testing.allocator);
    client.elicitation_action = "accept";
    client.elicitation_content_json = "{\"answer\":\"exact\"}";

    var form = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"params\":{\"mode\":\"openai/form\"}}",
        .{},
    );
    defer form.deinit();
    const form_result = try client.prepareMcpElicitationResult(form.value.object);
    defer std.testing.allocator.free(form_result);
    try std.testing.expect(std.mem.indexOf(u8, form_result, "\"action\":\"accept\"") != null);

    var url = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"params\":{\"mode\":\"url\",\"url\":\"https://secret.example/token\"}}",
        .{},
    );
    defer url.deinit();
    const url_result = try client.prepareMcpElicitationResult(url.value.object);
    defer std.testing.allocator.free(url_result);
    try std.testing.expect(std.mem.indexOf(u8, url_result, "\"action\":\"decline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, url_result, "secret.example") == null);

    var future = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"params\":{\"mode\":\"future/mode\"}}",
        .{},
    );
    defer future.deinit();
    const future_result = try client.prepareMcpElicitationResult(future.value.object);
    defer std.testing.allocator.free(future_result);
    try std.testing.expect(std.mem.indexOf(u8, future_result, "\"action\":\"decline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, future_result, "exact") == null);
}

test "auth and attestation failures do not echo secret request data" {
    var client = serverRequestTestClient();
    defer client.line_buf.deinit(std.testing.allocator);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"params\":{\"token\":\"SECRET_SENTINEL\"}}",
        .{},
    );
    defer parsed.deinit();
    for ([_]Client.ServerRequestMethod{ .auth_tokens_refresh, .attestation_generate }) |method| {
        var reply = try client.prepareServerReply(method, parsed.value.object);
        defer reply.deinit(std.testing.allocator);
        const payload = try Client.serverReplyPayloadAlloc(
            std.testing.allocator,
            .{ .string = "secret-test" },
            reply,
        );
        defer std.testing.allocator.free(payload);
        try std.testing.expect(std.mem.indexOf(u8, payload, "SECRET_SENTINEL") == null);
        try std.testing.expect(std.mem.indexOf(u8, payload, "\"code\":-32603") != null);
    }
}

test "provider failures reply once then terminate the affected route" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var sink = try tmp.dir.createFile(io, "replies", .{});
    defer sink.close(io);
    var client = serverRequestTestClient();
    defer client.deinit();
    client.io = io;
    client.stdin_file = sink;

    var auth = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"id":1,"method":"account/chatgptAuthTokens/refresh","params":{"token":"SECRET"}}
    ,
        .{},
    );
    defer auth.deinit();
    try std.testing.expectError(
        error.ChatGptAuthTokensRefreshProviderUnavailable,
        client.autoHandleServerRequest(auth.value.object),
    );

    var attestation = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"id\":2,\"method\":\"attestation/generate\",\"params\":{}}",
        .{},
    );
    defer attestation.deinit();
    try std.testing.expectError(
        error.AttestationProviderUnavailable,
        client.autoHandleServerRequest(attestation.value.object),
    );
    try std.testing.expectEqual(@as(u64, 2), client.blockingServerRequestCount());
}

test "stdio handshake failure reaps the spawned app-server" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    defer allocator.free(executable);
    const pid_path = try std.fs.path.join(allocator, &.{ root, "pid" });
    defer allocator.free(pid_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n" ++
            "set -eu\n" ++
            "printf '%s' \"$$\" > '{s}'\n" ++
            "printf '%s\\n' '{{\"id\":\"boot-1\",\"method\":" ++
            "\"future/serverRequest\",\"params\":{{}}}}'\n" ++
            "while IFS= read -r _; do :; done\n",
        .{pid_path},
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-codex", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        executable,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );

    try std.testing.expectError(error.UnsupportedServerRequest, Client.start(allocator, .{
        .cwd = root,
        .io = io,
        .codex_path = executable,
    }));

    const pid_bytes = try tmp.dir.readFileAlloc(io, "pid", allocator, .limited(64));
    defer allocator.free(pid_bytes);
    const process_id = try std.fmt.parseInt(u64, std.mem.trim(u8, pid_bytes, " \t\r\n"), 10);
    try std.testing.expect(!websocket_transport.processAlive(process_id));
}

test "stdio request deadline bounds a silent live app-server and reaps it" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "silent-codex" });
    defer allocator.free(executable);
    const pid_path = try std.fs.path.join(allocator, &.{ root, "silent.pid" });
    defer allocator.free(pid_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n" ++
            "set -eu\n" ++
            "sleep 600 &\n" ++
            "sleep_pid=$!\n" ++
            "printf '%s %s\\n' \"$$\" \"$sleep_pid\" > '{s}'\n" ++
            "while IFS= read -r _; do wait \"$sleep_pid\"; done\n",
        .{pid_path},
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "silent-codex", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        executable,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );

    const started_ms = monotonicMillis();
    try std.testing.expectError(error.ConnectionTimedOut, Client.start(allocator, .{
        .cwd = root,
        .io = io,
        .codex_path = executable,
        .request_deadline_ms = started_ms + 100,
    }));
    try std.testing.expect(monotonicMillis() - started_ms < 1_000);

    const pid_bytes = try tmp.dir.readFileAlloc(io, "silent.pid", allocator, .limited(64));
    defer allocator.free(pid_bytes);
    var pid_fields = std.mem.tokenizeAny(u8, pid_bytes, " \t\r\n");
    const shell_process_id = try std.fmt.parseInt(
        u64,
        pid_fields.next() orelse return error.InvalidPidFixture,
        10,
    );
    const sleep_process_id = try std.fmt.parseInt(
        u64,
        pid_fields.next() orelse return error.InvalidPidFixture,
        10,
    );
    try std.testing.expect(!websocket_transport.processAlive(shell_process_id));
    try std.testing.expect(!websocket_transport.processAlive(sleep_process_id));
}

test "stdio request deadline bounds a blocked write and reaps the app-server" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "blocked-codex" });
    defer allocator.free(executable);
    const pid_path = try std.fs.path.join(allocator, &.{ root, "blocked.pid" });
    defer allocator.free(pid_path);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n" ++
            "set -eu\n" ++
            "sleep 600 &\n" ++
            "sleep_pid=$!\n" ++
            "printf '%s %s\\n' \"$$\" \"$sleep_pid\" > '{s}'\n" ++
            "wait \"$sleep_pid\"\n",
        .{pid_path},
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked-codex", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        executable,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );

    const large_title = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(large_title);
    @memset(large_title, 'x');
    const started_ms = monotonicMillis();
    try std.testing.expectError(error.ConnectionTimedOut, Client.start(allocator, .{
        .cwd = root,
        .io = io,
        .codex_path = executable,
        .client_title = large_title,
        .request_deadline_ms = started_ms + 200,
    }));
    try std.testing.expect(monotonicMillis() - started_ms < 1_000);

    const pid_bytes = try tmp.dir.readFileAlloc(io, "blocked.pid", allocator, .limited(64));
    defer allocator.free(pid_bytes);
    var pid_fields = std.mem.tokenizeAny(u8, pid_bytes, " \t\r\n");
    const shell_process_id = try std.fmt.parseInt(
        u64,
        pid_fields.next() orelse return error.InvalidPidFixture,
        10,
    );
    const sleep_process_id = try std.fmt.parseInt(
        u64,
        pid_fields.next() orelse return error.InvalidPidFixture,
        10,
    );
    try std.testing.expect(!websocket_transport.processAlive(shell_process_id));
    try std.testing.expect(!websocket_transport.processAlive(sleep_process_id));
}

test "unknown server request replies then records exact method and terminates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var sink = try tmp.dir.createFile(io, "replies", .{});
    defer sink.close(io);
    var client = serverRequestTestClient();
    defer client.deinit();
    client.io = io;
    client.stdin_file = sink;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"id\":\"future-1\",\"method\":\"future/serverRequest\",\"params\":{}}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.UnsupportedServerRequest,
        client.autoHandleServerRequest(parsed.value.object),
    );
    try std.testing.expectEqualStrings(
        "future/serverRequest",
        client.lastUnsupportedServerRequest().?,
    );
}

test "known server request with missing or invalid id terminates instead of deadlocking" {
    var client = serverRequestTestClient();
    defer client.deinit();

    var missing = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"method\":\"currentTime/read\",\"params\":{}}",
        .{},
    );
    defer missing.deinit();
    try std.testing.expectError(
        error.MalformedServerRequest,
        client.autoHandleServerRequest(missing.value.object),
    );

    var invalid = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"id\":{},\"method\":\"currentTime/read\",\"params\":{}}",
        .{},
    );
    defer invalid.deinit();
    try std.testing.expectError(
        error.MalformedServerRequest,
        client.autoHandleServerRequest(invalid.value.object),
    );
}

test "current time reply is whole unix seconds" {
    var client = serverRequestTestClient();
    defer client.line_buf.deinit(std.testing.allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer parsed.deinit();
    const before = @as(i64, @intCast(@divFloor(
        std.Io.Clock.real.now(client.io).nanoseconds,
        1_000_000_000,
    )));
    var reply = try client.prepareServerReply(.current_time_read, parsed.value.object);
    defer reply.deinit(std.testing.allocator);
    const after = @as(i64, @intCast(@divFloor(
        std.Io.Clock.real.now(client.io).nanoseconds,
        1_000_000_000,
    )));
    var value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        reply.result_json,
        .{},
    );
    defer value.deinit();
    const observed = core_json.intField(value.value.object, "currentTimeAt") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(observed >= before and observed <= after);
}

test "deprecated approval methods return schema-valid denial results" {
    var client = serverRequestTestClient();
    defer client.line_buf.deinit(std.testing.allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer parsed.deinit();
    for ([_]Client.ServerRequestMethod{ .apply_patch_approval, .exec_command_approval }) |method| {
        var reply = try client.prepareServerReply(method, parsed.value.object);
        defer reply.deinit(std.testing.allocator);
        var result = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            reply.result_json,
            .{},
        );
        defer result.deinit();
        const decision = core_json.objectField(result.value.object, "decision") orelse
            return error.TestExpectedEqual;
        const denied = core_json.objectField(decision, "denied") orelse
            return error.TestExpectedEqual;
        try std.testing.expect(core_json.stringField(denied, "rejection") != null);
    }
}

test "openai form capability requires an exact configured response policy" {
    try std.testing.expect(!hasExactOpenaiFormPolicy(.{ .cwd = "." }));
    try std.testing.expect(hasExactOpenaiFormPolicy(.{
        .cwd = ".",
        .elicitation_action = "decline",
    }));
    try std.testing.expect(!hasExactOpenaiFormPolicy(.{
        .cwd = ".",
        .elicitation_action = "accept",
    }));
    try std.testing.expect(hasExactOpenaiFormPolicy(.{
        .cwd = ".",
        .elicitation_action = "accept",
        .elicitation_content_json = "{}",
    }));
    try std.testing.expect(hasExactOpenaiFormPolicy(.{
        .cwd = ".",
        .elicitation_response_json = "{\"action\":\"decline\"}",
    }));
}

test "initialize capability builder has one typed owner and preserves additive fields" {
    const builder = InitializeCapabilityBuilder{
        .experimental_api = false,
        .opt_out_notification_methods = &.{ "thread/started", "item/started" },
        .mcp_server_openai_form_elicitation = true,
        .request_attestation = true,
        .additional_json = "{\"futureCapability\":{\"enabled\":true}}",
    };
    const raw = try builder.buildAlloc(std.testing.allocator);
    defer std.testing.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(false, object.get("experimentalApi").?.bool);
    try std.testing.expectEqual(true, object.get("mcpServerOpenaiFormElicitation").?.bool);
    try std.testing.expectEqual(true, object.get("requestAttestation").?.bool);
    try std.testing.expectEqual(
        @as(usize, 2),
        object.get("optOutNotificationMethods").?.array.items.len,
    );
    try std.testing.expect(object.get("futureCapability") != null);

    try std.testing.expectError(
        error.DuplicateInitializeCapabilityOwner,
        (InitializeCapabilityBuilder{
            .additional_json = "{\"requestAttestation\":false}",
        }).validate(std.testing.allocator),
    );
    try std.testing.expectError(
        error.InvalidInitializeCapabilities,
        (InitializeCapabilityBuilder{
            .additional_json = "{\"future\":1,\"future\":2}",
        }).validate(std.testing.allocator),
    );
    try std.testing.expect(!initializeCapabilities(.{ .cwd = "." }).request_attestation);
    try std.testing.expect(initializeCapabilities(.{
        .cwd = ".",
        .attestation_response_json = "{\"token\":\"exact\"}",
    }).request_attestation);
}

test "initialize payload carries the single capability object" {
    const capabilities = try (InitializeCapabilityBuilder{
        .mcp_server_openai_form_elicitation = true,
        .request_attestation = true,
    }).buildAlloc(std.testing.allocator);
    defer std.testing.allocator.free(capabilities);
    const payload = try initializePayloadAlloc(
        std.testing.allocator,
        -1,
        "cas-test",
        "CAS Test",
        "0.4.0",
        capabilities,
    );
    defer std.testing.allocator.free(payload);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const params = core_json.objectField(parsed.value.object, "params") orelse
        return error.TestExpectedEqual;
    const actual = core_json.objectField(params, "capabilities") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 4), actual.count());
    try std.testing.expectEqual(true, actual.get("requestAttestation").?.bool);
}

test "auth refresh and attestation providers return only exact validated carriers" {
    const auth =
        "{ \"accessToken\":\"SECRET_ACCESS\", \"chatgptAccountId\":\"acct\", " ++
        "\"chatgptPlanType\":\"ent26\", \"future\":true }";
    const attestation = "{ \"token\":\"SECRET_ATTESTATION\", \"future\":1 }";
    try validateServerRequestOptions(std.testing.allocator, .{
        .cwd = ".",
        .auth_refresh_response_json = auth,
        .attestation_response_json = attestation,
    });
    var client = serverRequestTestClient();
    defer client.line_buf.deinit(std.testing.allocator);
    client.auth_refresh_response_json = auth;
    client.attestation_response_json = attestation;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer parsed.deinit();
    var auth_reply = try client.prepareServerReply(.auth_tokens_refresh, parsed.value.object);
    defer auth_reply.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(auth, auth_reply.result_json);
    var attestation_reply = try client.prepareServerReply(
        .attestation_generate,
        parsed.value.object,
    );
    defer attestation_reply.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(attestation, attestation_reply.result_json);

    try std.testing.expectError(
        error.InvalidAuthRefreshResponse,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .auth_refresh_response_json = "{\"accessToken\":\"x\"}",
        }),
    );
    try std.testing.expectError(
        error.InvalidAttestationResponse,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .attestation_response_json = "{\"token\":\"\"}",
        }),
    );
}

test "server request reply write failure poisons the client" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "read-only-sink", .data = "" });
    var read_only_sink = try tmp.dir.openFile(io, "read-only-sink", .{ .mode = .read_only });
    defer read_only_sink.close(io);

    var client = serverRequestTestClient();
    defer client.deinit();
    client.io = io;
    client.stdin_file = read_only_sink;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"id\":\"write-failure\",\"method\":\"currentTime/read\",\"params\":{}}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.ServerRequestReplyFailed,
        client.autoHandleServerRequest(parsed.value.object),
    );
    try std.testing.expectEqualStrings("server request reply write failed", client.lastError().?);
}

test "exact input response carriers are shape checked before launch" {
    try std.testing.expectError(
        error.InvalidServerRequestPolicy,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .exec_approval = "auto",
        }),
    );
    try std.testing.expectError(
        error.InvalidServerRequestCarrierJson,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .request_user_input_response_json = "{",
        }),
    );
    try std.testing.expectError(
        error.InvalidRequestUserInputResponse,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .request_user_input_response_json = "{\"answers\":[]}",
        }),
    );
    try std.testing.expectError(
        error.InvalidRequestUserInputResponse,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .request_user_input_response_json = "{\"answers\":{\"q\":{\"answers\":[\"yes\",1]}}}",
        }),
    );
    try validateServerRequestOptions(std.testing.allocator, .{
        .cwd = ".",
        .request_user_input_response_json = "{\"answers\":{\"q\":{\"answers\":[\"yes\",\"no\"]}}}",
    });
}

test "exact dynamic response carriers are bounded and shape checked before launch" {
    try std.testing.expectError(
        error.InvalidDynamicToolResponse,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .dynamic_tool_response_json = "{\"success\":true}",
        }),
    );
    try std.testing.expectError(
        error.InvalidDynamicToolResponse,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .dynamic_tool_response_json = "{\"contentItems\":[" ++
                "{\"type\":\"futureItem\",\"text\":\"x\"}]," ++
                "\"success\":true}",
        }),
    );
    try std.testing.expectError(
        error.InvalidDynamicToolResponse,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .dynamic_tool_response_json = "{\"contentItems\":[" ++
                "{\"type\":\"inputImage\",\"imageUrl\":1}]," ++
                "\"success\":true}",
        }),
    );
    try validateServerRequestOptions(std.testing.allocator, .{
        .cwd = ".",
        .dynamic_tool_response_json = "{\"contentItems\":[" ++
            "{\"type\":\"inputText\",\"text\":\"t\"}," ++
            "{\"type\":\"inputImage\",\"imageUrl\":\"file:///i\"}," ++
            "{\"type\":\"inputAudio\",\"audioUrl\":\"file:///a\"}]," ++
            "\"success\":true}",
    });
    const oversized = try std.testing.allocator.alloc(u8, Client.max_exact_response_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.ServerRequestCarrierTooLarge,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .elicitation_content_json = oversized,
        }),
    );
    try std.testing.expectError(
        error.UnsupportedServerRequestTimeout,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .server_request_timeout_ms = 1,
        }),
    );
}

test "full MCP response carrier preserves opaque meta and never crosses url or future modes" {
    const exact =
        "{ \"action\": \"accept\", \"content\": {\"answer\":42}, " ++
        "\"_meta\": {\"opaque\":[1,2]} }";
    try validateServerRequestOptions(std.testing.allocator, .{
        .cwd = ".",
        .elicitation_response_json = exact,
    });
    var client = serverRequestTestClient();
    defer client.line_buf.deinit(std.testing.allocator);
    client.elicitation_response_json = exact;

    var form = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"params\":{\"mode\":\"form\"}}",
        .{},
    );
    defer form.deinit();
    const form_result = try client.prepareMcpElicitationResult(form.value.object);
    defer std.testing.allocator.free(form_result);
    try std.testing.expectEqualStrings(exact, form_result);

    var url = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"params\":{\"mode\":\"url\"}}",
        .{},
    );
    defer url.deinit();
    const url_result = try client.prepareMcpElicitationResult(url.value.object);
    defer std.testing.allocator.free(url_result);
    try std.testing.expect(std.mem.indexOf(u8, url_result, "\"action\":\"decline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, url_result, "opaque") == null);

    var future = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"params\":{\"mode\":\"future/form\"}}",
        .{},
    );
    defer future.deinit();
    const future_result = try client.prepareMcpElicitationResult(future.value.object);
    defer std.testing.allocator.free(future_result);
    try std.testing.expect(std.mem.indexOf(u8, future_result, "opaque") == null);
}

test "full MCP response carrier rejects malformed actions content and policy conflicts" {
    const invalid = [_][]const u8{
        "{}",
        "{\"action\":\"future\"}",
        "{\"action\":\"accept\"}",
        "{\"action\":\"decline\",\"content\":{}}",
        "{\"action\":1}",
    };
    for (invalid) |raw| {
        try std.testing.expectError(
            error.InvalidElicitationResponse,
            validateServerRequestOptions(std.testing.allocator, .{
                .cwd = ".",
                .elicitation_response_json = raw,
            }),
        );
    }
    try std.testing.expectError(
        error.ConflictingElicitationResponsePolicies,
        validateServerRequestOptions(std.testing.allocator, .{
            .cwd = ".",
            .elicitation_action = "decline",
            .elicitation_response_json = "{\"action\":\"decline\"}",
        }),
    );
}

test "expired request deadline remains pre-send" {
    var client = Client{
        .allocator = std.testing.allocator,
        .transport_kind = .websocket,
        .child = null,
        .stdin_file = null,
        .stdout_file = null,
        .websocket = null,
        .line_buf = .empty,
        .next_request_id = 1,
        .last_error = null,
        .exec_approval = null,
        .file_approval = null,
        .permissions_approval = null,
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = true,
        .request_deadline_ms = monotonicMillis() - 1,
    };
    defer client.line_buf.deinit(std.testing.allocator);

    try std.testing.expectError(error.ConnectionTimedOut, client.sendWebSocket("{}", null));
    try std.testing.expect(!client.lastRequestSendStarted());
}

const SendObserverProbe = struct {
    calls: usize = 0,

    fn count(context: *anyopaque) anyerror!void {
        const probe: *SendObserverProbe = @ptrCast(@alignCast(context));
        probe.calls += 1;
    }

    fn failBeforeSend(context: *anyopaque) anyerror!void {
        const probe: *SendObserverProbe = @ptrCast(@alignCast(context));
        probe.calls += 1;
        return error.SendBoundaryPersistenceFailed;
    }

    fn expireDeadlineAfterPersistence(context: *anyopaque) anyerror!void {
        const probe: *SendObserverProbe = @ptrCast(@alignCast(context));
        probe.calls += 1;
        std.Io.sleep(
            std.Io.Threaded.global_single_threaded.io(),
            .fromMilliseconds(100),
            .awake,
        ) catch |err| switch (err) {
            else => {},
        };
    }
};

fn retryFakeCodexScriptAlloc(
    allocator: std.mem.Allocator,
    mode: []const u8,
    request_log_path: []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.print(
        "#!/bin/sh\nset -eu\nmode='{s}'\nrequest_log='{s}'\n",
        .{ mode, request_log_path },
    );
    try writer.writer.writeAll(
        \\attempt=0
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{"id":-1,"result":{}}'; continue ;;
        \\    *'"method":"initialized"'*) continue ;;
        \\  esac
        \\  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  [ -n "$id" ] || exit 7
        \\  printf '%s\n' "$line" >> "$request_log"
        \\  attempt=$((attempt + 1))
        \\  if [ "$mode" = nonoverload ]; then
        \\    printf '{"id":%s,"error":{"code":-32603,"message":"internal"}}\n' "$id"
        \\    continue
        \\  fi
        \\  if [ "$mode" = failure_then_success ]; then
        \\    if [ "$attempt" -eq 1 ]; then
        \\      printf '{"id":%s,"error":{"code":-32603,"message":"internal"}}\n' "$id"
        \\    else
        \\      printf '{"id":%s,"result":{"ok":true}}\n' "$id"
        \\    fi
        \\    continue
        \\  fi
        \\  if [ "$mode" = success ] && [ "$attempt" -ge 3 ]; then
        \\    printf '{"id":%s,"result":{"ok":true}}\n' "$id"
        \\    continue
        \\  fi
        \\  printf '{"method":"test/notification","params":{"attempt":%s}}\n' "$attempt"
        \\  printf '{"id":%s,"error":{"code":-32001,"message":"overloaded"}}\n' "$id"
        \\done
        \\
    );
    return writer.toOwnedSlice();
}

fn runRetryIntegrationCase(mode: []const u8) !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "retry-codex" });
    defer allocator.free(executable);
    const request_log_path = try std.fs.path.join(allocator, &.{ root, "requests.jsonl" });
    defer allocator.free(request_log_path);
    const script = try retryFakeCodexScriptAlloc(allocator, mode, request_log_path);
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "retry-codex", .data = script });
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        executable,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );

    const policy = OverloadRetryPolicy{
        .max_retries = if (std.mem.eql(u8, mode, "exhaust")) 2 else 4,
        .base_delay_ms = 1,
        .max_delay_ms = 4,
        .jitter_percent = 25,
    };
    var telemetry: OverloadRetryTelemetry = .{};
    var client = try Client.start(allocator, .{
        .cwd = root,
        .io = io,
        .codex_path = executable,
        .request_deadline_ms = monotonicMillis() + 2_000,
        .overload_retry_policy = policy,
        .overload_retry_seed = 17,
        .overload_retry_telemetry = &telemetry,
    });
    try std.testing.expectEqual(@as(u64, 17), client.overload_retry_seed);
    defer {
        client.close();
        client.deinit();
    }
    var observer = SendObserverProbe{};
    var notifications: std.ArrayList([]u8) = .empty;
    defer {
        for (notifications.items) |line| allocator.free(line);
        notifications.deinit(allocator);
    }

    try verifyRetryOutcome(
        allocator,
        mode,
        policy,
        &client,
        &telemetry,
        &observer,
        &notifications,
    );
    if (!std.mem.eql(u8, mode, "failure_then_success")) {
        try std.testing.expectEqual(@as(usize, 1), observer.calls);
    }
    try verifyRetryRequests(allocator, io, &tmp, mode, telemetry.wire_attempts);
}

fn verifyRetryOutcome(
    allocator: std.mem.Allocator,
    mode: []const u8,
    policy: OverloadRetryPolicy,
    client: *Client,
    telemetry: *OverloadRetryTelemetry,
    observer: *SendObserverProbe,
    notifications: *std.ArrayList([]u8),
) !void {
    if (std.mem.eql(u8, mode, "success")) {
        const result = try client.requestJsonCaptureNotificationsWithSendObserver(
            "test/retry",
            "{\"value\":7}",
            notifications,
            .{ .context = observer, .before_send = SendObserverProbe.count },
        );
        defer allocator.free(result);
        try std.testing.expectEqualStrings("{\"ok\":true}", result);
        try std.testing.expectEqual(@as(u32, 3), telemetry.wire_attempts);
        try std.testing.expectEqual(@as(u32, 2), telemetry.overload_responses);
        try std.testing.expectEqual(@as(u32, 2), telemetry.retries);
        try std.testing.expectEqual(@as(u32, 2), telemetry.delay_count);
        try std.testing.expect(!telemetry.exhausted);
        try std.testing.expectEqual(@as(usize, 2), notifications.items.len);
        try std.testing.expect(client.lastError() == null);
    } else if (std.mem.eql(u8, mode, "failure_then_success")) {
        try std.testing.expectError(
            error.RequestFailed,
            client.requestJson("test/retry", "{\"value\":7}"),
        );
        try std.testing.expect(client.lastError() != null);
        const result = try client.requestJson("test/retry", "{\"value\":7}");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("{\"ok\":true}", result);
        try std.testing.expect(client.lastError() == null);
    } else {
        try std.testing.expectError(
            error.RequestFailed,
            client.requestJsonWithSendObserver(
                "test/retry",
                "{\"value\":7}",
                .{ .context = observer, .before_send = SendObserverProbe.count },
            ),
        );
        if (std.mem.eql(u8, mode, "nonoverload")) {
            try std.testing.expectEqual(@as(u32, 1), telemetry.wire_attempts);
            try std.testing.expectEqual(@as(u32, 0), telemetry.retries);
            try std.testing.expect(!telemetry.exhausted);
        } else {
            try std.testing.expectEqual(@as(u32, policy.max_retries + 1), telemetry.wire_attempts);
            try std.testing.expectEqual(policy.max_retries, telemetry.retries);
            try std.testing.expect(telemetry.exhausted);
        }
    }
}

fn verifyRetryRequests(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    mode: []const u8,
    wire_attempts: u32,
) !void {
    const requests = try tmp.dir.readFileAlloc(
        io,
        "requests.jsonl",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(requests);
    var lines = std.mem.tokenizeScalar(u8, requests, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        try std.testing.expect(std.mem.indexOf(u8, line, "\"method\":\"test/retry\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"params\":{\"value\":7}") != null);
        const expected_id = try std.fmt.allocPrint(
            allocator,
            "\"id\":{d}",
            .{index + 1},
        );
        defer allocator.free(expected_id);
        try std.testing.expect(std.mem.indexOf(u8, line, expected_id) != null);
    }
    const expected_requests: usize = if (std.mem.eql(u8, mode, "failure_then_success"))
        2
    else
        wire_attempts;
    try std.testing.expectEqual(expected_requests, index);
}

test "production retry owns structured overload classification deadlines and telemetry" {
    try runRetryIntegrationCase("success");
    try runRetryIntegrationCase("nonoverload");
    try runRetryIntegrationCase("exhaust");
    try runRetryIntegrationCase("failure_then_success");
}

test "overload retry policy validation and deterministic jitter are bounded" {
    try validateOverloadRetryPolicy(.{});
    try std.testing.expectError(
        error.InvalidOverloadRetryPolicy,
        validateOverloadRetryPolicy(.{ .max_retries = max_overload_retries + 1 }),
    );
    try std.testing.expectError(
        error.InvalidOverloadRetryPolicy,
        validateOverloadRetryPolicy(.{ .base_delay_ms = 0 }),
    );
    try std.testing.expectError(
        error.InvalidOverloadRetryPolicy,
        validateOverloadRetryPolicy(.{
            .max_delay_ms = max_overload_delay_ms + 1,
        }),
    );
    try std.testing.expectError(
        error.InvalidOverloadRetryPolicy,
        validateOverloadRetryPolicy(.{
            .jitter_percent = max_overload_jitter_percent + 1,
        }),
    );
    const policy = OverloadRetryPolicy{};
    const delay = overloadRetryDelayMs(policy, 0, 42);
    try std.testing.expectEqual(delay, overloadRetryDelayMs(policy, 0, 42));
    try std.testing.expect(delay >= policy.base_delay_ms);
    try std.testing.expect(delay <= policy.base_delay_ms + policy.base_delay_ms / 4);

    var direct = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"code\":-32001}",
        .{},
    );
    defer direct.deinit();
    try std.testing.expect(isStructuredOverloadError(direct.value));
    var nested = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"error\":{\"code\":-32001}}",
        .{},
    );
    defer nested.deinit();
    try std.testing.expect(!isStructuredOverloadError(nested.value));

    const first_default = try resolveOverloadRetrySeed(null, std.testing.io);
    var saw_distinct_default = false;
    for (0..8) |_| {
        if (try resolveOverloadRetrySeed(null, std.testing.io) != first_default) {
            saw_distinct_default = true;
        }
    }
    try std.testing.expect(saw_distinct_default);
    try std.testing.expectEqual(@as(u64, 42), try resolveOverloadRetrySeed(42, std.testing.io));
}

fn actorFakeCodexScriptAlloc(
    allocator: std.mem.Allocator,
    mode: []const u8,
    reply_log_path: []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.print(
        "#!/bin/sh\nset -eu\nmode='{s}'\nreply_log='{s}'\n",
        .{ mode, reply_log_path },
    );
    try writer.writer.writeAll(
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{"id":-1,"result":{}}'; continue ;;
        \\    *'"method":"initialized"'*) break ;;
        \\  esac
        \\done
        \\if [ "$mode" = concurrent ]; then
        \\  IFS= read -r first
        \\  IFS= read -r second
        \\  first_id=$(printf '%s\n' "$first" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  second_id=$(printf '%s\n' "$second" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  first_method=$(printf '%s\n' "$first" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
        \\  second_method=$(printf '%s\n' "$second" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
        \\  printf '{"id":%s,"result":{"method":"%s"}}\n' "$second_id" "$second_method"
        \\  printf '%s\n' '{"method":"turn/started","params":{}}'
        \\  printf '{"id":%s,"result":{"method":"%s"}}\n' "$first_id" "$first_method"
        \\  while IFS= read -r ignored; do :; done
        \\  exit 0
        \\fi
        \\if [ "$mode" = nested_server_request ]; then
        \\  IFS= read -r request
        \\  request_id=$(printf '%s\n' "$request" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  printf '%s\n' '{"id":"tool-nested","method":"item/tool/call","params":{"tool":"nested"}}'
        \\  IFS= read -r nested
        \\  nested_id=$(printf '%s\n' "$nested" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  printf '{"id":%s,"result":{"nested":true}}\n' "$nested_id"
        \\  IFS= read -r reply
        \\  printf '%s\n' "$reply" > "$reply_log"
        \\  printf '{"id":%s,"result":{"ok":true}}\n' "$request_id"
        \\  while IFS= read -r ignored; do :; done
        \\  exit 0
        \\fi
        \\if [ "$mode" = server_request ]; then
        \\  IFS= read -r request
        \\  request_id=$(printf '%s\n' "$request" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  printf '%s\n' '{"id":"tool-1","method":"item/tool/call","params":{"tool":"synoptic"}}'
        \\  IFS= read -r reply
        \\  printf '%s\n' "$reply" > "$reply_log"
        \\  printf '{"id":%s,"result":{"ok":true}}\n' "$request_id"
        \\  while IFS= read -r ignored; do :; done
        \\  exit 0
        \\fi
        \\attempt=0
        \\while IFS= read -r request; do
        \\  request_id=$(printf '%s\n' "$request" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  if [ "$mode" = poison ]; then printf '%s\n' 'not-json'; sleep 5; exit 0; fi
        \\  if [ "$mode" = deadline ]; then sleep 5; exit 0; fi
        \\  attempt=$((attempt + 1))
        \\  if [ "$attempt" -lt 3 ]; then
        \\    printf '{"id":%s,"error":{"code":-32001,"message":"overloaded"}}\n' "$request_id"
        \\  else
        \\    printf '{"id":%s,"result":{"attempt":%s}}\n' "$request_id" "$attempt"
        \\  fi
        \\done
        \\
    );
    return writer.toOwnedSlice();
}

const ActorFixture = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    executable: []u8,
    reply_log: []u8,

    fn init(allocator: std.mem.Allocator, mode: []const u8) !ActorFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const io = std.testing.io;
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(root);
        const executable = try std.fs.path.join(allocator, &.{ root, "actor-codex" });
        errdefer allocator.free(executable);
        const reply_log = try std.fs.path.join(allocator, &.{ root, "reply.json" });
        errdefer allocator.free(reply_log);
        const script = try actorFakeCodexScriptAlloc(allocator, mode, reply_log);
        defer allocator.free(script);
        try tmp.dir.writeFile(io, .{ .sub_path = "actor-codex", .data = script });
        try std.Io.Dir.cwd().setFilePermissions(
            io,
            executable,
            std.Io.File.Permissions.fromMode(0o755),
            .{},
        );
        return .{
            .allocator = allocator,
            .tmp = tmp,
            .root = root,
            .executable = executable,
            .reply_log = reply_log,
        };
    }

    fn deinit(self: *ActorFixture) void {
        self.allocator.free(self.reply_log);
        self.allocator.free(self.executable);
        self.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn start(self: *ActorFixture, options: ActorOptions) !Actor {
        return Client.startActor(self.allocator, .{
            .cwd = self.root,
            .io = std.testing.io,
            .codex_path = self.executable,
        }, options);
    }
};

const ActorCall = struct {
    actor: *Actor,
    method: []const u8,
    result: ?[]u8 = null,
    failure: ?anyerror = null,

    fn run(self: *ActorCall) void {
        self.result = self.actor.requestJson(self.method, "{}", 2_000) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const NotificationProbe = struct {
    mutex: ActorMutex = .{},
    count: usize = 0,

    fn observe(context: *anyopaque, notification: protocol.Notification) void {
        const self: *NotificationProbe = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, notification.method, "turn/started")) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count += 1;
    }
};

const ServerRequestProbe = struct {
    calls: usize = 0,

    fn handle(
        context: *anyopaque,
        request: protocol.ServerRequest,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *ServerRequestProbe = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings("item/tool/call", request.method);
        self.calls += 1;
        return allocator.dupe(u8, "{\"handled\":true}");
    }
};

const NestedServerRequestProbe = struct {
    actor: *Actor,
    nested_completed: bool = false,

    fn handle(
        context: *anyopaque,
        request: protocol.ServerRequest,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *NestedServerRequestProbe = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings("item/tool/call", request.method);
        const nested = try self.actor.requestJson("actor/nested", "{}", 2_000);
        defer allocator.free(nested);
        try std.testing.expect(std.mem.indexOf(u8, nested, "\"nested\":true") != null);
        self.nested_completed = true;
        return allocator.dupe(u8, "{\"handled\":\"nested\"}");
    }
};

test "actor falsifier permanent reader correlates concurrent reversed responses and notifications" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try ActorFixture.init(allocator, "concurrent");
    defer fixture.deinit();
    var actor = try fixture.start(.{ .outbound_queue_capacity = 2 });
    defer actor.deinit();
    var notifications = NotificationProbe{};
    try actor.subscribe(.{ .context = &notifications, .handle = NotificationProbe.observe });

    var first = ActorCall{ .actor = &actor, .method = "actor/first" };
    var second = ActorCall{ .actor = &actor, .method = "actor/second" };
    const first_thread = try std.Thread.spawn(.{}, ActorCall.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, ActorCall.run, .{&second});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.failure == null);
    try std.testing.expect(second.failure == null);
    defer allocator.free(first.result.?);
    defer allocator.free(second.result.?);
    try std.testing.expect(std.mem.indexOf(u8, first.result.?, "actor/first") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.result.?, "actor/second") != null);
    notifications.mutex.lock();
    defer notifications.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 1), notifications.count);
}

test "actor falsifier dispatches server requests through configured handler and bounded writer" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try ActorFixture.init(allocator, "server_request");
    defer fixture.deinit();
    var probe = ServerRequestProbe{};
    var actor = try fixture.start(.{
        .outbound_queue_capacity = 1,
        .server_request_handler = .{ .context = &probe, .handle = ServerRequestProbe.handle },
    });
    defer actor.deinit();
    const result = try actor.requestJson("actor/server-request", "{}", 2_000);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    const reply = try fixture.tmp.dir.readFileAlloc(
        std.testing.io,
        "reply.json",
        allocator,
        .limited(4 * 1024),
    );
    defer allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"id\":\"tool-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"handled\":true") != null);
}

test "actor falsifier nested request in server handler cannot deadlock permanent reader" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try ActorFixture.init(allocator, "nested_server_request");
    defer fixture.deinit();
    var actor = try fixture.start(.{
        .outbound_queue_capacity = 2,
        .server_request_queue_capacity = 1,
    });
    defer actor.deinit();
    var probe = NestedServerRequestProbe{ .actor = &actor };
    try actor.setServerRequestHandler(.{
        .context = &probe,
        .handle = NestedServerRequestProbe.handle,
    });
    const result = try actor.requestJson("actor/original", "{}", 3_000);
    defer allocator.free(result);
    try std.testing.expect(probe.nested_completed);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"ok\":true") != null);
    const reply = try fixture.tmp.dir.readFileAlloc(
        std.testing.io,
        "reply.json",
        allocator,
        .limited(4 * 1024),
    );
    defer allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"id\":\"tool-nested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"handled\":\"nested\"") != null);
}

test "actor falsifier retries only structured overload and honors per-request deadline" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var overload_fixture = try ActorFixture.init(allocator, "overload");
    defer overload_fixture.deinit();
    var overload_actor = try overload_fixture.start(.{
        .overload_retry_policy = .{
            .max_retries = 2,
            .base_delay_ms = 1,
            .max_delay_ms = 2,
            .jitter_percent = 0,
        },
        .overload_retry_seed = 7,
    });
    defer overload_actor.deinit();
    const result = try overload_actor.requestJson("actor/overload", null, 2_000);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"attempt\":3") != null);

    var deadline_fixture = try ActorFixture.init(allocator, "deadline");
    defer deadline_fixture.deinit();
    var deadline_actor = try deadline_fixture.start(.{});
    defer deadline_actor.deinit();
    try std.testing.expectError(
        error.RequestDeadlineExceeded,
        deadline_actor.requestJson("actor/deadline", null, 20),
    );
}

test "actor falsifier malformed envelope poisons instead of losing correlation" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try ActorFixture.init(allocator, "poison");
    defer fixture.deinit();
    var actor = try fixture.start(.{});
    defer actor.deinit();
    try std.testing.expectError(
        error.ActorPoisoned,
        actor.requestJson("actor/poison", null, 2_000),
    );
    try std.testing.expectEqual(protocol.TerminalState.poisoned, actor.terminalState());
}

test "actor falsifier rejects zero and unbounded queues before ownership transfer" {
    var client = serverRequestTestClient();
    try std.testing.expectError(
        error.InvalidActorOptions,
        Actor.initOwned(std.testing.allocator, client, .{ .outbound_queue_capacity = 0 }),
    );
    client = serverRequestTestClient();
    try std.testing.expectError(
        error.InvalidActorOptions,
        Actor.initOwned(std.testing.allocator, client, .{
            .outbound_queue_capacity = max_actor_outbound_queue + 1,
        }),
    );
}

test "actor falsifier saturated stalled writer consumes the request deadline" {
    const allocator = std.testing.allocator;
    var state = ActorState{
        .allocator = allocator,
        .client = serverRequestTestClient(),
        .outbound_capacity = 1,
        .server_request_capacity = 1,
        .server_request_timeout_ms = 100,
        .pending = std.AutoHashMap(i64, *ActorPending).init(allocator),
        .server_request_handler = null,
        .default_request_timeout_ms = 100,
        .overload_retry_policy = .{},
        .overload_retry_seed = 1,
    };
    defer state.deinit();
    try state.outbound.append(allocator, .{
        .payload = try allocator.dupe(u8, "stalled"),
        .deadline_ms = monotonicMillis() + 1_000,
    });
    var actor = Actor{ .state = &state };
    const started = monotonicMillis();
    try std.testing.expectError(
        error.RequestDeadlineExceeded,
        actor.requestJson("actor/blocked", null, 20),
    );
    try std.testing.expect(monotonicMillis() - started < 500);
    try std.testing.expectEqual(@as(usize, 0), state.pending.count());
}

test "actor falsifier expired outbound work is never eligible for transport" {
    const item = ActorOutbound{
        .payload = @constCast("expired"),
        .deadline_ms = monotonicMillis() - 1,
    };
    try std.testing.expect(actorOutboundExpired(item));
}

test "actor falsifier expired server work never invokes its handler" {
    const allocator = std.testing.allocator;
    var probe = ServerRequestProbe{};
    var state = ActorState{
        .allocator = allocator,
        .client = serverRequestTestClient(),
        .outbound_capacity = 1,
        .server_request_capacity = 1,
        .server_request_timeout_ms = 100,
        .pending = std.AutoHashMap(i64, *ActorPending).init(allocator),
        .server_request_handler = .{ .context = &probe, .handle = ServerRequestProbe.handle },
        .default_request_timeout_ms = 100,
        .overload_retry_policy = .{},
        .overload_retry_seed = 1,
    };
    defer state.deinit();
    const work = ActorServerRequest{
        .id_json = try allocator.dupe(u8, "1"),
        .method = try allocator.dupe(u8, "item/tool/call"),
        .raw_json = try allocator.dupe(u8, "{}"),
        .deadline_ms = monotonicMillis() - 1,
    };
    defer work.deinit(allocator);
    try std.testing.expectError(
        error.RequestDeadlineExceeded,
        actorHandleServerRequest(&state, work),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(protocol.TerminalState.running, state.terminal);
}

test "actor falsifier releases an uncorrelated late response" {
    const allocator = std.testing.allocator;
    var state = ActorState{
        .allocator = allocator,
        .client = serverRequestTestClient(),
        .outbound_capacity = 1,
        .server_request_capacity = 1,
        .server_request_timeout_ms = 100,
        .pending = std.AutoHashMap(i64, *ActorPending).init(allocator),
        .server_request_handler = null,
        .default_request_timeout_ms = 100,
        .overload_retry_policy = .{},
        .overload_retry_seed = 1,
    };
    defer state.deinit();
    try actorRouteLine(&state, "{\"id\":99,\"result\":{\"late\":true}}");
    try std.testing.expectEqual(@as(usize, 0), state.pending.count());
}

test "transport acquisition helpers require an already resolved retry seed" {
    const stdio_info = @typeInfo(@TypeOf(Client.startStdio)).@"fn";
    const websocket_info = @typeInfo(@TypeOf(Client.startWebsocket)).@"fn";
    const unix_info = @typeInfo(@TypeOf(Client.startUnix)).@"fn";
    try std.testing.expect(stdio_info.params[2].type.? == u64);
    try std.testing.expect(websocket_info.params[2].type.? == u64);
    try std.testing.expect(unix_info.params[2].type.? == u64);
}

test "transport kinds preserve unix identity and frame behavior" {
    try std.testing.expect(TransportKind.websocket != TransportKind.unix_socket);
    try std.testing.expectEqualStrings("websocket", @tagName(TransportKind.websocket));
    try std.testing.expectEqualStrings("unix_socket", @tagName(TransportKind.unix_socket));
    inline for (.{ TransportKind.websocket, TransportKind.unix_socket }) |kind| {
        var client = Client{
            .allocator = std.testing.allocator,
            .transport_kind = kind,
            .child = null,
            .stdin_file = null,
            .stdout_file = null,
            .websocket = null,
            .line_buf = .empty,
            .next_request_id = 1,
            .last_error = null,
            .exec_approval = null,
            .file_approval = null,
            .permissions_approval = null,
            .request_user_input_response_json = null,
            .elicitation_action = null,
            .elicitation_content_json = null,
            .dynamic_tool_response_json = null,
            .read_only = true,
            .request_deadline_ms = monotonicMillis() - 1,
        };
        defer client.line_buf.deinit(std.testing.allocator);
        try std.testing.expectError(error.ConnectionTimedOut, client.readLineAlloc());
        try std.testing.expectError(error.ConnectionTimedOut, client.sendPayload("{}", null));
        try std.testing.expectError(
            error.ConnectionTimedOut,
            client.emitServerReply(.{ .integer = 1 }, .{
                .server_error = .{ .code = -32601, .message = "unsupported" },
            }),
        );
    }
    try std.testing.expectEqualStrings("websocket", TransportKind.websocket.text());
    try std.testing.expectEqualStrings("unix_socket", TransportKind.unix_socket.text());
}

test "request send observer runs before transport send attribution" {
    var client = Client{
        .allocator = std.testing.allocator,
        .transport_kind = .stdio,
        .child = null,
        .stdin_file = null,
        .stdout_file = null,
        .websocket = null,
        .line_buf = .empty,
        .next_request_id = 1,
        .last_error = null,
        .exec_approval = null,
        .file_approval = null,
        .permissions_approval = null,
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = true,
    };
    defer client.line_buf.deinit(std.testing.allocator);
    var probe = SendObserverProbe{};

    try std.testing.expectError(
        error.SendBoundaryPersistenceFailed,
        client.sendToServer(.{ .method = "review/start" }, .{
            .context = &probe,
            .before_send = SendObserverProbe.failBeforeSend,
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(!client.lastRequestSendStarted());
}

test "request send ownership survives deadline expiry after durable observer" {
    var client = Client{
        .allocator = std.testing.allocator,
        .transport_kind = .websocket,
        .child = null,
        .stdin_file = null,
        .stdout_file = null,
        .websocket = null,
        .line_buf = .empty,
        .next_request_id = 1,
        .last_error = null,
        .exec_approval = null,
        .file_approval = null,
        .permissions_approval = null,
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = true,
        .request_deadline_ms = monotonicMillis() + 50,
    };
    defer client.line_buf.deinit(std.testing.allocator);
    var probe = SendObserverProbe{};

    try std.testing.expectError(
        error.ConnectionTimedOut,
        client.sendToServer(.{ .method = "review/start" }, .{
            .context = &probe,
            .before_send = SendObserverProbe.expireDeadlineAfterPersistence,
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(client.lastRequestSendStarted());
}

test "code mode host cannot be silently ignored by existing endpoint transports" {
    var host = try app_server_launch.CodeModeHost.init(
        std.testing.allocator,
        "ws://127.0.0.1:9911",
    );
    defer host.deinit();
    try std.testing.expectError(
        error.CodeModeHostRequiresManagedLaunch,
        validateTransportOptions(.{
            .cwd = ".",
            .code_mode_host = &host,
            .transport = .{ .explicit_websocket = "ws://127.0.0.1:1" },
        }),
    );
    try std.testing.expectError(
        error.CodeModeHostRequiresManagedLaunch,
        validateTransportOptions(.{
            .cwd = ".",
            .code_mode_host = &host,
            .transport = .{ .unix_socket = null },
        }),
    );
    try std.testing.expectError(
        error.ConflictingTransportOptions,
        validateTransportOptions(.{
            .cwd = ".",
            .websocket_url = "ws://127.0.0.1:1",
            .transport = .stdio,
        }),
    );
}

test "diagnostic Codex feature arguments are bounded and stdio-only" {
    const allocator = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "codex");
    try appendCodexEnableFeatureArgs(
        allocator,
        &argv,
        &.{ "deferred_executor", "executor_capability_discovery" },
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "codex", "--enable", "deferred_executor", "--enable", "executor_capability_discovery" },
        argv.items,
    );
    try validateClientOptions(allocator, .{
        .cwd = ".",
        .codex_enable_features = &.{ "deferred_executor", "executor_capability_discovery" },
        .transport = .stdio,
    });
    try std.testing.expectError(error.InvalidCodexEnableFeature, validateClientOptions(allocator, .{
        .cwd = ".",
        .codex_enable_features = &.{"../feature"},
    }));
    try std.testing.expectError(
        error.CodexEnableFeaturesRequireStdio,
        validateClientOptions(allocator, .{
            .cwd = ".",
            .codex_enable_features = &.{"deferred_executor"},
            .transport = .{ .explicit_websocket = "ws://127.0.0.1:1" },
        }),
    );
}

test "notification capture has an aggregate byte bound" {
    try std.testing.expectEqual(
        max_captured_notification_bytes,
        try addCapturedNotificationBytes(max_captured_notification_bytes - 1, 1),
    );
    try std.testing.expectError(
        error.AppServerNotificationBytesLimitExceeded,
        addCapturedNotificationBytes(max_captured_notification_bytes, 1),
    );
}

test "resolveExecDecision honors read_only and explicit approvals" {
    var client = Client{
        .allocator = std.testing.allocator,
        .transport_kind = .stdio,
        .child = null,
        .stdin_file = null,
        .stdout_file = null,
        .websocket = null,
        .line_buf = .empty,
        .next_request_id = 1,
        .last_error = null,
        .exec_approval = "acceptForSession",
        .file_approval = null,
        .permissions_approval = null,
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = false,
    };
    defer client.line_buf.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("acceptForSession", client.resolveExecDecision());
    try std.testing.expectEqualStrings("decline", client.resolveFileDecision());

    client.exec_approval = "decline";
    client.file_approval = "accept";
    try std.testing.expectEqualStrings("decline", client.resolveExecDecision());
    try std.testing.expectEqualStrings("accept", client.resolveFileDecision());

    client.read_only = true;
    try std.testing.expectEqualStrings("decline", client.resolveExecDecision());
    try std.testing.expectEqualStrings("decline", client.resolveFileDecision());
}

test "resolvePermissionsApproval honors explicit grants and read_only" {
    var client = Client{
        .allocator = std.testing.allocator,
        .transport_kind = .stdio,
        .child = null,
        .stdin_file = null,
        .stdout_file = null,
        .websocket = null,
        .line_buf = .empty,
        .next_request_id = 1,
        .last_error = null,
        .exec_approval = null,
        .file_approval = "auto",
        .permissions_approval = "grant-session",
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = false,
    };
    defer client.line_buf.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        Client.PermissionsApproval.grant_session,
        client.resolvePermissionsApproval(),
    );
    client.permissions_approval = "grant-turn";
    try std.testing.expectEqual(
        Client.PermissionsApproval.grant_turn,
        client.resolvePermissionsApproval(),
    );
    client.read_only = true;
    try std.testing.expectEqual(
        Client.PermissionsApproval.deny,
        client.resolvePermissionsApproval(),
    );
}

test "resolveElicitationAction defaults to decline" {
    var client = Client{
        .allocator = std.testing.allocator,
        .transport_kind = .stdio,
        .child = null,
        .stdin_file = null,
        .stdout_file = null,
        .websocket = null,
        .line_buf = .empty,
        .next_request_id = 1,
        .last_error = null,
        .exec_approval = null,
        .file_approval = "auto",
        .permissions_approval = null,
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = false,
    };
    defer client.line_buf.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        Client.McpElicitationResponseAction.decline,
        client.resolveElicitationAction(),
    );
    client.elicitation_action = "accept";
    try std.testing.expectEqual(
        Client.McpElicitationResponseAction.accept,
        client.resolveElicitationAction(),
    );
    client.elicitation_action = "cancel";
    try std.testing.expectEqual(
        Client.McpElicitationResponseAction.cancel,
        client.resolveElicitationAction(),
    );
}
