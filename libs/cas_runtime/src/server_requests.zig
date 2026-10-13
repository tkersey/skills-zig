const std = @import("std");
const core_json = @import("core_json");

pub const max_server_request_carrier_bytes: usize = 1024 * 1024;

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

    pub fn parse(method: []const u8) ServerRequestHandlerKind {
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

pub const JsonRpcId = union(enum) {
    integer: i64,
    string: []const u8,

    pub fn parse(value: std.json.Value) ?JsonRpcId {
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

pub const ServerReply = union(enum) {
    result_json: []u8,
    server_error: ErrorReply,

    pub fn deinit(reply: *ServerReply, allocator: std.mem.Allocator) void {
        switch (reply.*) {
            .result_json => |owned| allocator.free(owned),
            .server_error => {},
        }
    }
};

pub fn serverReplyPayloadAlloc(
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

/// A borrowed view of configured response policy. It owns neither the transport
/// nor request correlation; Client owns emission and terminal failure handling.
pub const Policy = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
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

    pub fn resolveExecDecision(self: *const Policy) []const u8 {
        if (self.read_only) return "decline";
        if (self.exec_approval) |decision| return decision;
        return "decline";
    }

    pub fn resolveFileDecision(self: *const Policy) []const u8 {
        if (self.read_only) return "decline";
        if (self.file_approval) |decision| {
            if (!std.mem.eql(u8, decision, "auto")) return decision;
        }
        return "decline";
    }

    pub fn prepareServerReply(
        self: *const Policy,
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
            .current_time_read => .{ .result_json = try self.allocator.print(
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

    fn prepareCommandApproval(self: *const Policy, msg_obj: core_json.ObjectMap) !ServerReply {
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

    fn preparePermissionsResult(self: *const Policy, msg_obj: core_json.ObjectMap) ![]u8 {
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
        const response_json = try self.allocator.print(
            "{{\"permissions\":{s},\"scope\":\"{s}\"}}",
            .{ permissions_json, switch (mode) {
                .grant_turn => "turn",
                .grant_session => "session",
                .deny => "turn",
            } },
        );
        return response_json;
    }

    fn prepareUserInputResult(self: *const Policy) ![]u8 {
        if (self.request_user_input_response_json) |raw| {
            return self.allocator.dupe(u8, raw);
        }
        return self.allocator.dupe(u8, "{\"answers\":{}}");
    }

    pub fn prepareMcpElicitationResult(self: *const Policy, msg_obj: core_json.ObjectMap) ![]u8 {
        const params_obj = core_json.objectField(msg_obj, "params");
        const mode = if (params_obj) |params| core_json.stringField(params, "mode") else null;
        const action = self.resolveElicitationAction();
        const accepts_exact_content = if (mode) |value|
            std.mem.eql(u8, value, "form") or std.mem.eql(u8, value, "openai/form")
        else
            false;
        if (!accepts_exact_content) {
            const conservative_action: []const u8 = if (action == .cancel) "cancel" else "decline";
            return self.allocator.print(
                "{{\"action\":\"{s}\",\"content\":null,\"_meta\":null}}",
                .{conservative_action},
            );
        }
        if (self.elicitation_response_json) |raw| return self.allocator.dupe(u8, raw);
        const content_json = self.elicitation_content_json orelse "null";
        return switch (action) {
            .accept => self.allocator.print(
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

    pub const PermissionsApproval = enum {
        deny,
        grant_turn,
        grant_session,
    };

    pub fn resolvePermissionsApproval(self: *const Policy) PermissionsApproval {
        if (self.read_only) return .deny;
        if (self.permissions_approval) |decision| {
            if (std.mem.eql(u8, decision, "grant-session")) return .grant_session;
            if (std.mem.eql(u8, decision, "grant-turn")) return .grant_turn;
        }
        return .deny;
    }

    pub const McpElicitationResponseAction = enum {
        accept,
        decline,
        cancel,
    };

    pub fn resolveElicitationAction(self: *const Policy) McpElicitationResponseAction {
        if (self.elicitation_action) |action| {
            if (std.mem.eql(u8, action, "accept")) return .accept;
            if (std.mem.eql(u8, action, "cancel")) return .cancel;
        }
        return .decline;
    }
};

pub fn hasExactOpenaiFormPolicy(
    response_json: ?[]const u8,
    elicitation_action: ?[]const u8,
    content_json: ?[]const u8,
) bool {
    if (response_json != null) return true;
    const action = elicitation_action orelse return false;
    if (std.mem.eql(u8, action, "decline") or std.mem.eql(u8, action, "cancel")) return true;
    return std.mem.eql(u8, action, "accept") and content_json != null;
}

pub fn validateServerRequestOptions(
    allocator: std.mem.Allocator,
    opts: Policy,
    server_request_timeout_ms: ?u32,
) !void {
    if (server_request_timeout_ms != null) return error.UnsupportedServerRequestTimeout;
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
    if (raw.len > max_server_request_carrier_bytes) return error.ServerRequestCarrierTooLarge;
    return std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return error.InvalidServerRequestCarrierJson;
}
