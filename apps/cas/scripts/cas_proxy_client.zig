const core_json = @import("core_json");
pub const hooks = @import("cas_hook_policy.zig");
const std = @import("std");
const websocket_transport = @import("cas_websocket_transport.zig");

pub const TransportKind = enum {
    stdio,
    websocket,
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
    server_request_timeout_ms: ?u32 = null,
    exec_approval: ?[]const u8 = null,
    file_approval: ?[]const u8 = null,
    permissions_approval: ?[]const u8 = null,
    request_user_input_response_json: ?[]const u8 = null,
    elicitation_action: ?[]const u8 = null,
    elicitation_content_json: ?[]const u8 = null,
    dynamic_tool_response_json: ?[]const u8 = null,
    read_only: bool = false,
    opt_out_notification_methods: []const []const u8 = &.{},
    hook_policy: hooks.HookPolicy = .inherit,
    websocket_url: ?[]const u8 = null,
    websocket_connect_timeout_ms: u32 = 10_000,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),
    transport_kind: TransportKind,
    child: ?std.process.Child,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    websocket: ?websocket_transport.Connection,
    line_buf: std.ArrayList(u8) = .empty,
    next_request_id: i64 = 1,
    last_error: ?[]u8 = null,
    exec_approval: ?[]const u8,
    file_approval: ?[]const u8,
    permissions_approval: ?[]const u8,
    request_user_input_response_json: ?[]const u8,
    elicitation_action: ?[]const u8,
    elicitation_content_json: ?[]const u8,
    dynamic_tool_response_json: ?[]const u8,
    read_only: bool,
    blocking_server_request_count: u64 = 0,
    request_deadline_ms: ?i64 = null,

    pub fn start(allocator: std.mem.Allocator, opts: ClientOptions) !Client {
        if (opts.websocket_url) |url| {
            return startWebsocket(allocator, opts, url);
        }

        return startStdio(allocator, opts);
    }

    fn startStdio(allocator: std.mem.Allocator, opts: ClientOptions) !Client {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);

        const resolved_codex_path = try resolveExecutableAlloc(allocator, opts.codex_path);
        defer allocator.free(resolved_codex_path);
        try hooks.ensureLaunchSupportsPolicy(allocator, opts.io, resolved_codex_path, opts.cwd, opts.hook_policy);

        try argv.append(allocator, resolved_codex_path);
        try hooks.appendAppServerArgs(allocator, &argv, opts.hook_policy, null);

        const io = opts.io;
        const child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = opts.cwd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });

        const stdin_file = child.stdin orelse return error.ChildMissingStdin;
        const stdout_file = child.stdout orelse return error.ChildMissingStdout;

        var client = Client{
            .allocator = allocator,
            .io = io,
            .transport_kind = .stdio,
            .child = child,
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
            .dynamic_tool_response_json = opts.dynamic_tool_response_json,
            .read_only = opts.read_only,
            .blocking_server_request_count = 0,
        };
        try client.handshake(opts);
        return client;
    }

    fn startWebsocket(allocator: std.mem.Allocator, opts: ClientOptions, url: []const u8) !Client {
        var websocket = try websocket_transport.Connection.connect(allocator, url, opts.websocket_connect_timeout_ms);
        errdefer {
            websocket.close();
            websocket.deinit();
        }

        var client = Client{
            .allocator = allocator,
            .io = opts.io,
            .transport_kind = .websocket,
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
            .dynamic_tool_response_json = opts.dynamic_tool_response_json,
            .read_only = opts.read_only,
            .blocking_server_request_count = 0,
        };
        try client.handshake(opts);
        return client;
    }

    pub fn deinit(self: *Client) void {
        if (self.last_error) |owned| self.allocator.free(owned);
        self.last_error = null;
        self.line_buf.deinit(self.allocator);
        if (self.websocket) |*websocket| websocket.deinit();
    }

    pub fn close(self: *Client) void {
        if (self.websocket) |*websocket| websocket.close();
        if (self.child) |*child| {
            child.kill(self.io);
        }
    }

    pub fn lastError(self: *const Client) ?[]const u8 {
        return self.last_error;
    }

    pub fn blockingServerRequestCount(self: *const Client) u64 {
        return self.blocking_server_request_count;
    }

    pub fn requestJson(self: *Client, method: []const u8, params_json: ?[]const u8) ![]u8 {
        return self.requestJsonCaptureNotifications(method, params_json, null);
    }

    pub fn requestJsonCaptureNotifications(
        self: *Client,
        method: []const u8,
        params_json: ?[]const u8,
        notification_lines: ?*std.ArrayList([]u8),
    ) ![]u8 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.sendRequest(request_id, method, params_json);

        while (true) {
            const line = (try self.readLineAlloc()) orelse return error.AppServerClosed;
            defer self.allocator.free(line);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const msg_obj = switch (parsed.value) {
                .object => |obj| obj,
                else => continue,
            };

            try self.autoHandleServerRequest(msg_obj);

            if (notification_lines) |lines| {
                if (isNotificationMessage(msg_obj)) {
                    try lines.append(self.allocator, try self.allocator.dupe(u8, line));
                }
            }

            const response_id = blk: {
                const id_val = msg_obj.get("id") orelse break :blk null;
                break :blk core_json.intFromValue(id_val);
            };
            if (response_id == null or response_id.? != request_id) continue;

            if (msg_obj.get("error")) |err_val| {
                const err_json = try core_json.stringifyAlloc(self.allocator, err_val);
                self.setLastErrorOwned(err_json);
                return error.RequestFailed;
            }
            if (msg_obj.get("result")) |result_val| {
                return core_json.stringifyAlloc(self.allocator, result_val);
            }
            return error.InvalidAppServerResponse;
        }
    }

    pub fn swapRequestDeadlineMs(self: *Client, deadline_ms: ?i64) ?i64 {
        const previous = self.request_deadline_ms;
        self.request_deadline_ms = deadline_ms;
        return previous;
    }

    fn isNotificationMessage(msg_obj: core_json.ObjectMap) bool {
        return core_json.stringField(msg_obj, "method") != null and msg_obj.get("id") == null;
    }

    fn handshake(self: *Client, opts: ClientOptions) !void {
        const handshake_id: i64 = -1;

        const client_name = opts.client_name orelse "cas-zig";
        const client_title = opts.client_title orelse "CAS Zig Client";
        const client_version = opts.client_version orelse "0.1.0";

        if (opts.opt_out_notification_methods.len > 0) {
            const InitWithOptOut = struct {
                method: []const u8,
                id: i64,
                params: struct {
                    clientInfo: struct {
                        name: []const u8,
                        title: []const u8,
                        version: []const u8,
                    },
                    capabilities: struct {
                        experimentalApi: bool,
                        optOutNotificationMethods: []const []const u8,
                    },
                },
            };
            const initialize = InitWithOptOut{
                .method = "initialize",
                .id = handshake_id,
                .params = .{
                    .clientInfo = .{
                        .name = client_name,
                        .title = client_title,
                        .version = client_version,
                    },
                    .capabilities = .{
                        .experimentalApi = true,
                        .optOutNotificationMethods = opts.opt_out_notification_methods,
                    },
                },
            };
            try self.sendToServer(initialize);
        } else {
            const InitNoOptOut = struct {
                method: []const u8,
                id: i64,
                params: struct {
                    clientInfo: struct {
                        name: []const u8,
                        title: []const u8,
                        version: []const u8,
                    },
                    capabilities: struct {
                        experimentalApi: bool,
                    },
                },
            };
            const initialize = InitNoOptOut{
                .method = "initialize",
                .id = handshake_id,
                .params = .{
                    .clientInfo = .{
                        .name = client_name,
                        .title = client_title,
                        .version = client_version,
                    },
                    .capabilities = .{
                        .experimentalApi = true,
                    },
                },
            };
            try self.sendToServer(initialize);
        }

        const started_ms = monotonicMillis();
        const timeout_ms: i64 = 10_000;
        while (monotonicMillis() - started_ms < timeout_ms) {
            const line = (try self.readLineAlloc()) orelse return error.AppServerClosed;
            defer self.allocator.free(line);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
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

            const Initialized = struct {
                method: []const u8,
            };
            try self.sendToServer(Initialized{ .method = "initialized" });
            return;
        }

        try self.setLastError("Handshake timed out waiting for initialize response");
        return error.HandshakeTimeout;
    }

    fn sendRequest(self: *Client, request_id: i64, method: []const u8, params_json: ?[]const u8) !void {
        if (params_json) |raw| {
            var parsed_params = try std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{});
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
            try self.sendToServer(req);
        } else {
            const ReqNoParams = struct {
                method: []const u8,
                id: i64,
            };
            const req = ReqNoParams{
                .method = method,
                .id = request_id,
            };
            try self.sendToServer(req);
        }
    }

    fn sendToServer(self: *Client, msg: anytype) !void {
        var payload_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload_writer.deinit();
        try std.json.Stringify.value(msg, .{}, &payload_writer.writer);
        const payload = payload_writer.written();
        switch (self.transport_kind) {
            .stdio => {
                try self.stdin_file.?.writeStreamingAll(self.io, payload);
                try self.stdin_file.?.writeStreamingAll(self.io, "\n");
            },
            .websocket => try self.websocket.?.sendText(payload),
        }
    }

    fn autoHandleServerRequest(self: *Client, msg_obj: core_json.ObjectMap) !void {
        const method = core_json.stringField(msg_obj, "method") orelse return;

        const id = blk: {
            const id_val = msg_obj.get("id") orelse return;
            const parsed_id = core_json.intFromValue(id_val) orelse return;
            break :blk parsed_id;
        };

        if (isBlockingServerRequest(method)) self.blocking_server_request_count += 1;

        if (std.mem.eql(u8, method, "item/commandExecution/requestApproval")) {
            const decision = self.resolveExecDecision();
            if (std.mem.eql(u8, decision, "acceptForSession")) {
                const params_obj = core_json.objectField(msg_obj, "params");
                if (self.resolveAutoExecDecision(params_obj)) |available_decision| {
                    try self.sendApprovalDecisionValue(id, available_decision);
                    return;
                }
            }
            try self.sendApprovalDecision(id, decision);
            return;
        }

        if (std.mem.eql(u8, method, "item/fileChange/requestApproval")) {
            const decision = self.resolveFileDecision();
            try self.sendApprovalDecision(id, decision);
            return;
        }

        if (std.mem.eql(u8, method, "item/permissions/requestApproval")) {
            try self.handlePermissionsRequest(id, msg_obj);
            return;
        }

        if (std.mem.eql(u8, method, "item/tool/requestUserInput")) {
            try self.handleRequestUserInput(id, msg_obj);
            return;
        }

        if (std.mem.eql(u8, method, "mcpServer/elicitation/request")) {
            try self.handleMcpElicitation(id);
            return;
        }

        if (std.mem.eql(u8, method, "item/tool/call")) {
            try self.handleDynamicToolCall(id);
            return;
        }

        if (std.mem.eql(u8, method, "execCommandApproval") or std.mem.eql(u8, method, "applyPatchApproval")) {
            try self.sendServerError(id, -32602, "Unsupported deprecated server request");
            return;
        }

        // Reject unknown server requests to avoid deadlocking request/response calls.
        try self.sendServerError(id, -32601, "Unsupported server request in native cas client");
    }

    fn isBlockingServerRequest(method: []const u8) bool {
        return std.mem.eql(u8, method, "item/commandExecution/requestApproval") or
            std.mem.eql(u8, method, "item/fileChange/requestApproval") or
            std.mem.eql(u8, method, "item/permissions/requestApproval") or
            std.mem.eql(u8, method, "item/tool/requestUserInput") or
            std.mem.eql(u8, method, "mcpServer/elicitation/request") or
            std.mem.eql(u8, method, "item/tool/call") or
            std.mem.eql(u8, method, "execCommandApproval") or
            std.mem.eql(u8, method, "applyPatchApproval");
    }

    fn sendApprovalDecision(self: *Client, id: i64, decision: []const u8) !void {
        const Response = struct {
            id: i64,
            result: struct {
                decision: []const u8,
            },
        };
        try self.sendToServer(Response{
            .id = id,
            .result = .{ .decision = decision },
        });
    }

    fn sendApprovalDecisionValue(self: *Client, id: i64, decision: std.json.Value) !void {
        const Response = struct {
            id: i64,
            result: struct {
                decision: std.json.Value,
            },
        };
        try self.sendToServer(Response{
            .id = id,
            .result = .{ .decision = decision },
        });
    }

    fn sendResultRawJson(self: *Client, id: i64, result_json: []const u8) !void {
        var payload_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload_writer.deinit();

        try payload_writer.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(id, .{}, &payload_writer.writer);
        try payload_writer.writer.writeAll(",\"result\":");
        try payload_writer.writer.writeAll(result_json);
        try payload_writer.writer.writeAll("}");

        const payload = payload_writer.written();
        switch (self.transport_kind) {
            .stdio => {
                try self.stdin_file.?.writeStreamingAll(self.io, payload);
                try self.stdin_file.?.writeStreamingAll(self.io, "\n");
            },
            .websocket => try self.websocket.?.sendText(payload),
        }
    }

    fn sendServerError(self: *Client, id: i64, code: i64, message: []const u8) !void {
        const Response = struct {
            id: i64,
            @"error": struct {
                code: i64,
                message: []const u8,
            },
        };
        try self.sendToServer(Response{
            .id = id,
            .@"error" = .{
                .code = code,
                .message = message,
            },
        });
    }

    fn resolveExecDecision(self: *const Client) []const u8 {
        if (self.read_only) return "decline";
        if (self.exec_approval) |decision| {
            if (!std.mem.eql(u8, decision, "auto")) return decision;
        }
        return "acceptForSession";
    }

    fn resolveAutoExecDecision(self: *const Client, params_obj: ?core_json.ObjectMap) ?std.json.Value {
        _ = self;
        const params = params_obj orelse return null;
        const available_val = params.get("availableDecisions") orelse return null;
        const decisions = switch (available_val) {
            .array => |arr| arr.items,
            else => return null,
        };

        var accept_for_session: ?std.json.Value = null;
        var accept: ?std.json.Value = null;
        var accept_with_execpolicy_amendment: ?std.json.Value = null;
        var apply_network_policy_amendment: ?std.json.Value = null;
        var decline: ?std.json.Value = null;
        var cancel: ?std.json.Value = null;

        for (decisions) |decision| {
            switch (decision) {
                .string => |decision_tag| {
                    if (std.mem.eql(u8, decision_tag, "acceptForSession")) {
                        accept_for_session = decision;
                    } else if (std.mem.eql(u8, decision_tag, "accept")) {
                        accept = decision;
                    } else if (std.mem.eql(u8, decision_tag, "decline")) {
                        decline = decision;
                    } else if (std.mem.eql(u8, decision_tag, "cancel")) {
                        cancel = decision;
                    }
                },
                .object => |decision_obj| {
                    if (decision_obj.get("acceptWithExecpolicyAmendment") != null) {
                        accept_with_execpolicy_amendment = decision;
                    } else if (decision_obj.get("applyNetworkPolicyAmendment") != null) {
                        apply_network_policy_amendment = decision;
                    }
                },
                else => {},
            }
        }

        return accept_for_session orelse
            accept orelse
            accept_with_execpolicy_amendment orelse
            apply_network_policy_amendment orelse
            decline orelse
            cancel;
    }

    fn resolveFileDecision(self: *const Client) []const u8 {
        if (self.read_only) return "decline";
        if (self.file_approval) |decision| {
            if (!std.mem.eql(u8, decision, "auto")) return decision;
        }
        return "acceptForSession";
    }

    fn handlePermissionsRequest(self: *Client, id: i64, msg_obj: core_json.ObjectMap) !void {
        const params_obj = core_json.objectField(msg_obj, "params");
        const mode = self.resolvePermissionsApproval();
        if (mode == .deny or params_obj == null) {
            try self.sendResultRawJson(id, "{\"permissions\":{},\"scope\":\"turn\"}");
            return;
        }

        const permissions_val = params_obj.?.get("permissions") orelse {
            try self.sendResultRawJson(id, "{\"permissions\":{},\"scope\":\"turn\"}");
            return;
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
        defer self.allocator.free(response_json);
        try self.sendResultRawJson(id, response_json);
    }

    fn handleRequestUserInput(self: *Client, id: i64, msg_obj: core_json.ObjectMap) !void {
        if (self.request_user_input_response_json) |raw| {
            try self.sendResultRawJson(id, raw);
            return;
        }

        const params_obj = core_json.objectField(msg_obj, "params") orelse {
            try self.sendResultRawJson(id, "{\"answers\":{}}");
            return;
        };
        const questions_val = params_obj.get("questions") orelse {
            try self.sendResultRawJson(id, "{\"answers\":{}}");
            return;
        };
        const questions = switch (questions_val) {
            .array => |arr| arr.items,
            else => {
                try self.sendResultRawJson(id, "{\"answers\":{}}");
                return;
            },
        };

        var result_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer result_writer.deinit();

        try result_writer.writer.writeAll("{\"answers\":{");
        var first_question = true;
        for (questions) |question| {
            const question_obj = switch (question) {
                .object => |obj| obj,
                else => continue,
            };
            const question_id = core_json.stringField(question_obj, "id") orelse continue;
            const answer = defaultRequestUserInputAnswer(question_obj);
            if (!first_question) try result_writer.writer.writeAll(",");
            first_question = false;
            try std.json.Stringify.value(question_id, .{}, &result_writer.writer);
            try result_writer.writer.writeAll(":{\"answers\":[");
            try std.json.Stringify.value(answer, .{}, &result_writer.writer);
            try result_writer.writer.writeAll("]}");
        }
        try result_writer.writer.writeAll("}}");

        const result_json = result_writer.written();
        try self.sendResultRawJson(id, result_json);
    }

    fn handleMcpElicitation(self: *Client, id: i64) !void {
        const action = self.resolveElicitationAction();
        const content_json = self.elicitation_content_json orelse "null";
        const response_json = switch (action) {
            .accept => try std.fmt.allocPrint(
                self.allocator,
                "{{\"action\":\"accept\",\"content\":{s},\"_meta\":null}}",
                .{content_json},
            ),
            .decline => try self.allocator.dupe(u8, "{\"action\":\"decline\",\"content\":null,\"_meta\":null}"),
            .cancel => try self.allocator.dupe(u8, "{\"action\":\"cancel\",\"content\":null,\"_meta\":null}"),
        };
        defer self.allocator.free(response_json);
        try self.sendResultRawJson(id, response_json);
    }

    fn handleDynamicToolCall(self: *Client, id: i64) !void {
        const response_json = self.dynamic_tool_response_json orelse
            "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"Unsupported dynamic tool call in native CAS client\"}],\"success\":false}";
        try self.sendResultRawJson(id, response_json);
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

    fn defaultRequestUserInputAnswer(question_obj: core_json.ObjectMap) []const u8 {
        const options_val = question_obj.get("options") orelse return "";
        const options = switch (options_val) {
            .array => |arr| arr.items,
            else => return "",
        };
        for (options) |option| {
            const option_obj = switch (option) {
                .object => |obj| obj,
                else => continue,
            };
            if (core_json.stringField(option_obj, "label")) |label| return label;
        }
        return "";
    }

    fn setLastErrorOwned(self: *Client, owned: []u8) void {
        if (self.last_error) |existing| self.allocator.free(existing);
        self.last_error = owned;
    }

    fn setLastError(self: *Client, text: []const u8) !void {
        const duped = try self.allocator.dupe(u8, text);
        self.setLastErrorOwned(duped);
    }

    fn readLineAlloc(self: *Client) !?[]u8 {
        if (self.transport_kind == .websocket) {
            const deadline_ms = self.request_deadline_ms orelse
                return try self.websocket.?.readTextAlloc();
            const remaining_ms = deadline_ms - monotonicMillis();
            if (remaining_ms <= 0) return error.ConnectionTimedOut;
            return self.websocket.?.readTextAllocTimeout(@intCast(remaining_ms)) catch |err| switch (err) {
                error.Timeout => error.ConnectionTimedOut,
                else => err,
            };
        }

        while (true) {
            if (std.mem.indexOfScalar(u8, self.line_buf.items, '\n')) |nl_idx| {
                const line = try self.allocator.dupe(u8, self.line_buf.items[0..nl_idx]);
                const keep_from = nl_idx + 1;
                const keep_len = self.line_buf.items.len - keep_from;
                if (keep_len > 0) {
                    std.mem.copyForwards(u8, self.line_buf.items[0..keep_len], self.line_buf.items[keep_from..]);
                }
                self.line_buf.items.len = keep_len;
                return line;
            }

            var tmp: [1]u8 = undefined;
            var reader = self.stdout_file.?.reader(self.io, &.{});
            const n = try reader.interface.readSliceShort(tmp[0..]);
            if (n == 0) {
                if (self.line_buf.items.len == 0) return null;
                const tail = try self.allocator.dupe(u8, self.line_buf.items);
                self.line_buf.items.len = 0;
                return tail;
            }
            try self.line_buf.appendSlice(self.allocator, tmp[0..n]);
        }
    }
};

pub fn resolveExecutableAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return error.MissingExecutable;

    if (std.mem.indexOfScalar(u8, value, '/') != null) {
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), value, .{}) catch return error.ExecutableNotFound;
        return allocator.dupe(u8, value);
    }

    const exe_dir = std.process.executableDirPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator) catch null;
    if (exe_dir) |dir| {
        defer allocator.free(dir);
        const sibling = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, value });
        errdefer allocator.free(sibling);
        if (pathExists(sibling)) return sibling;
        allocator.free(sibling);
    }

    const path_env = std.Io.Threaded.global_single_threaded.environString("PATH") orelse return error.ExecutableNotFound;
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, value });
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
        std.Io.Dir.accessAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
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
        .exec_approval = "auto",
        .file_approval = "auto",
        .permissions_approval = null,
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = false,
    };
    defer client.line_buf.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("acceptForSession", client.resolveExecDecision());
    try std.testing.expectEqualStrings("acceptForSession", client.resolveFileDecision());

    client.exec_approval = "decline";
    client.file_approval = "accept";
    try std.testing.expectEqualStrings("decline", client.resolveExecDecision());
    try std.testing.expectEqualStrings("accept", client.resolveFileDecision());

    client.read_only = true;
    try std.testing.expectEqualStrings("decline", client.resolveExecDecision());
    try std.testing.expectEqualStrings("decline", client.resolveFileDecision());
}

test "resolveAutoExecDecision prefers acceptForSession when available" {
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
        .exec_approval = "auto",
        .file_approval = "auto",
        .permissions_approval = null,
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = false,
    };
    defer client.line_buf.deinit(std.testing.allocator);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"availableDecisions\":[\"decline\",\"accept\",\"acceptForSession\"]}",
        .{},
    );
    defer parsed.deinit();

    const choice = client.resolveAutoExecDecision(parsed.value.object) orelse return error.TestExpectedEqual;
    switch (choice) {
        .string => |value| try std.testing.expectEqualStrings("acceptForSession", value),
        else => return error.TestExpectedEqual,
    }
}

test "resolveAutoExecDecision falls back to amendment object before decline" {
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
        .exec_approval = "auto",
        .file_approval = "auto",
        .permissions_approval = null,
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = false,
    };
    defer client.line_buf.deinit(std.testing.allocator);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"availableDecisions\":[\"decline\",{\"acceptWithExecpolicyAmendment\":{\"profile\":\"safe\"}}]}",
        .{},
    );
    defer parsed.deinit();

    const choice = client.resolveAutoExecDecision(parsed.value.object) orelse return error.TestExpectedEqual;
    try std.testing.expect(choice == .object);
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
        .exec_approval = "auto",
        .file_approval = "auto",
        .permissions_approval = "grant-session",
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = false,
    };
    defer client.line_buf.deinit(std.testing.allocator);

    try std.testing.expectEqual(Client.PermissionsApproval.grant_session, client.resolvePermissionsApproval());
    client.permissions_approval = "grant-turn";
    try std.testing.expectEqual(Client.PermissionsApproval.grant_turn, client.resolvePermissionsApproval());
    client.read_only = true;
    try std.testing.expectEqual(Client.PermissionsApproval.deny, client.resolvePermissionsApproval());
}

test "defaultRequestUserInputAnswer prefers first option label" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"id\":\"choice\",\"options\":[{\"label\":\"Alpha\",\"description\":\"first\"},{\"label\":\"Beta\",\"description\":\"second\"}]}",
        .{},
    );
    defer parsed.deinit();

    const answer = Client.defaultRequestUserInputAnswer(parsed.value.object);
    try std.testing.expectEqualStrings("Alpha", answer);
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
        .exec_approval = "auto",
        .file_approval = "auto",
        .permissions_approval = null,
        .request_user_input_response_json = null,
        .elicitation_action = null,
        .elicitation_content_json = null,
        .dynamic_tool_response_json = null,
        .read_only = false,
    };
    defer client.line_buf.deinit(std.testing.allocator);

    try std.testing.expectEqual(Client.McpElicitationResponseAction.decline, client.resolveElicitationAction());
    client.elicitation_action = "accept";
    try std.testing.expectEqual(Client.McpElicitationResponseAction.accept, client.resolveElicitationAction());
    client.elicitation_action = "cancel";
    try std.testing.expectEqual(Client.McpElicitationResponseAction.cancel, client.resolveElicitationAction());
}
