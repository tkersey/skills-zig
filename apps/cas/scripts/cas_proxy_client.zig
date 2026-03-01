const core_json = @import("core_json");
const std = @import("std");

pub const ClientOptions = struct {
    cwd: []const u8,
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
    read_only: bool = false,
    opt_out_notification_methods: []const []const u8 = &.{},
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    line_buf: std.ArrayList(u8) = .empty,
    next_request_id: i64 = 1,
    last_error: ?[]u8 = null,
    exec_approval: ?[]const u8,
    file_approval: ?[]const u8,
    read_only: bool,

    pub fn start(allocator: std.mem.Allocator, opts: ClientOptions) !Client {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);

        try argv.append(allocator, opts.codex_path);
        try argv.append(allocator, "app-server");

        var child = std.process.Child.init(argv.items, allocator);
        child.cwd = opts.cwd;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        const stdin_file = child.stdin orelse return error.ChildMissingStdin;
        const stdout_file = child.stdout orelse return error.ChildMissingStdout;

        var client = Client{
            .allocator = allocator,
            .child = child,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .line_buf = .empty,
            .next_request_id = 1,
            .last_error = null,
            .exec_approval = opts.exec_approval,
            .file_approval = opts.file_approval,
            .read_only = opts.read_only,
        };
        try client.handshake(opts);
        return client;
    }

    pub fn deinit(self: *Client) void {
        if (self.last_error) |owned| self.allocator.free(owned);
        self.last_error = null;
        self.line_buf.deinit(self.allocator);
    }

    pub fn close(self: *Client) void {
        self.stdin_file.close();
        _ = self.child.wait() catch {};
    }

    pub fn lastError(self: *const Client) ?[]const u8 {
        return self.last_error;
    }

    pub fn requestJson(self: *Client, method: []const u8, params_json: ?[]const u8) ![]u8 {
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

        const started_ms = std.time.milliTimestamp();
        const timeout_ms: i64 = 10_000;
        while (std.time.milliTimestamp() - started_ms < timeout_ms) {
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
        try self.stdin_file.writeAll(payload);
        try self.stdin_file.writeAll("\n");
    }

    fn autoHandleServerRequest(self: *Client, msg_obj: core_json.ObjectMap) !void {
        const method = core_json.stringField(msg_obj, "method") orelse return;

        const id = blk: {
            const id_val = msg_obj.get("id") orelse return;
            const parsed_id = core_json.intFromValue(id_val) orelse return;
            break :blk parsed_id;
        };

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

        if (std.mem.eql(u8, method, "execCommandApproval") or std.mem.eql(u8, method, "applyPatchApproval")) {
            try self.sendServerError(id, -32602, "Unsupported deprecated server request");
            return;
        }

        // Reject unknown server requests to avoid deadlocking request/response calls.
        try self.sendServerError(id, -32601, "Unsupported server request in native cas client");
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

    fn setLastErrorOwned(self: *Client, owned: []u8) void {
        if (self.last_error) |existing| self.allocator.free(existing);
        self.last_error = owned;
    }

    fn setLastError(self: *Client, text: []const u8) !void {
        const duped = try self.allocator.dupe(u8, text);
        self.setLastErrorOwned(duped);
    }

    fn readLineAlloc(self: *Client) !?[]u8 {
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

            var tmp: [4096]u8 = undefined;
            const n = try self.stdout_file.read(&tmp);
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
        .child = undefined,
        .stdin_file = undefined,
        .stdout_file = undefined,
        .line_buf = .empty,
        .next_request_id = 1,
        .last_error = null,
        .exec_approval = "auto",
        .file_approval = "auto",
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
        .child = undefined,
        .stdin_file = undefined,
        .stdout_file = undefined,
        .line_buf = .empty,
        .next_request_id = 1,
        .last_error = null,
        .exec_approval = "auto",
        .file_approval = "auto",
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
        .child = undefined,
        .stdin_file = undefined,
        .stdout_file = undefined,
        .line_buf = .empty,
        .next_request_id = 1,
        .last_error = null,
        .exec_approval = "auto",
        .file_approval = "auto",
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
