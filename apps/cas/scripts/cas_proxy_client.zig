const std = @import("std");
const core_json = @import("core_json");

pub const ClientOptions = struct {
    cwd: []const u8,
    proxy_script: ?[]const u8 = null,
    state_file: ?[]const u8 = null,
    client_name: ?[]const u8 = null,
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

    const request_loop_event_types = [_][]const u8{
        "cas/fromServer",
        "cas/error",
    };
    const ready_loop_event_types = [_][]const u8{
        "cas/ready",
        "cas/error",
    };

    pub fn start(allocator: std.mem.Allocator, opts: ClientOptions) !Client {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);

        const proxy_script = if (opts.proxy_script) |path| path else try discoverProxyPath(allocator, opts.cwd);
        defer if (opts.proxy_script == null) allocator.free(proxy_script);

        try argv.append(allocator, "node");
        try argv.append(allocator, proxy_script);
        try argv.append(allocator, "--cwd");
        try argv.append(allocator, opts.cwd);

        if (opts.state_file) |state_file| {
            try argv.append(allocator, "--state-file");
            try argv.append(allocator, state_file);
        }
        if (opts.client_name) |client_name| {
            try argv.append(allocator, "--client-name");
            try argv.append(allocator, client_name);
        }
        if (opts.server_request_timeout_ms) |timeout_ms| {
            const timeout_text = try std.fmt.allocPrint(allocator, "{d}", .{timeout_ms});
            defer allocator.free(timeout_text);
            try argv.append(allocator, "--server-request-timeout-ms");
            try argv.append(allocator, timeout_text);
        }
        if (opts.read_only) {
            try argv.append(allocator, "--read-only");
        }
        if (opts.exec_approval) |decision| {
            try argv.append(allocator, "--exec-approval");
            try argv.append(allocator, decision);
        }
        if (opts.file_approval) |decision| {
            try argv.append(allocator, "--file-approval");
            try argv.append(allocator, decision);
        }
        for (opts.opt_out_notification_methods) |method| {
            try argv.append(allocator, "--opt-out-notification-method");
            try argv.append(allocator, method);
        }

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
        };
        try client.waitForReady();
        return client;
    }

    pub fn deinit(self: *Client) void {
        if (self.last_error) |owned| self.allocator.free(owned);
        self.last_error = null;
        self.line_buf.deinit(self.allocator);
    }

    pub fn close(self: *Client) void {
        const exit_msg = "{\"type\":\"cas/exit\"}";
        _ = self.stdin_file.writeAll(exit_msg) catch {};
        _ = self.stdin_file.writeAll("\n") catch {};
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
            const line = (try self.readLineAlloc()) orelse return error.ProxyClosed;
            defer self.allocator.free(line);
            if (!shouldAttemptEventParse(line, request_loop_event_types[0..])) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const event_obj = switch (parsed.value) {
                .object => |obj| obj,
                else => continue,
            };

            const event_type = core_json.stringField(event_obj, "type") orelse continue;
            if (std.mem.eql(u8, event_type, "cas/error")) {
                if (core_json.stringField(event_obj, "message")) |msg| {
                    try self.setLastError(msg);
                }
                continue;
            }

            if (!std.mem.eql(u8, event_type, "cas/fromServer")) continue;
            const kind = core_json.stringField(event_obj, "kind") orelse continue;
            if (!std.mem.eql(u8, kind, "response")) continue;
            const id = core_json.intField(event_obj, "id") orelse continue;
            if (id != request_id) continue;

            const msg_val = event_obj.get("msg") orelse return error.InvalidProxyResponse;
            const msg_obj = switch (msg_val) {
                .object => |obj| obj,
                else => return error.InvalidProxyResponse,
            };

            if (msg_obj.get("error")) |err_val| {
                const err_json = try core_json.stringifyAlloc(self.allocator, err_val);
                self.setLastErrorOwned(err_json);
                return error.RequestFailed;
            }
            if (msg_obj.get("result")) |result_val| {
                return core_json.stringifyAlloc(self.allocator, result_val);
            }
            return error.InvalidProxyResponse;
        }
    }

    fn sendRequest(self: *Client, request_id: i64, method: []const u8, params_json: ?[]const u8) !void {
        const client_request_id = try std.fmt.allocPrint(self.allocator, "cas-zig-{d}", .{request_id});
        defer self.allocator.free(client_request_id);

        var payload_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload_writer.deinit();

        if (params_json) |raw| {
            var parsed_params = try std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{});
            defer parsed_params.deinit();

            const ReqWithParams = struct {
                type: []const u8,
                clientRequestId: []const u8,
                id: i64,
                method: []const u8,
                params: std.json.Value,
            };
            const req = ReqWithParams{
                .type = "cas/request",
                .clientRequestId = client_request_id,
                .id = request_id,
                .method = method,
                .params = parsed_params.value,
            };
            try std.json.Stringify.value(req, .{}, &payload_writer.writer);
        } else {
            const ReqNoParams = struct {
                type: []const u8,
                clientRequestId: []const u8,
                id: i64,
                method: []const u8,
            };
            const req = ReqNoParams{
                .type = "cas/request",
                .clientRequestId = client_request_id,
                .id = request_id,
                .method = method,
            };
            try std.json.Stringify.value(req, .{}, &payload_writer.writer);
        }

        const payload = payload_writer.written();
        try self.stdin_file.writeAll(payload);
        try self.stdin_file.writeAll("\n");
    }

    fn waitForReady(self: *Client) !void {
        while (true) {
            const line = (try self.readLineAlloc()) orelse return error.ProxyClosedBeforeReady;
            defer self.allocator.free(line);
            if (!shouldAttemptEventParse(line, ready_loop_event_types[0..])) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const event_obj = switch (parsed.value) {
                .object => |obj| obj,
                else => continue,
            };

            const event_type = core_json.stringField(event_obj, "type") orelse continue;
            if (std.mem.eql(u8, event_type, "cas/ready")) return;
            if (std.mem.eql(u8, event_type, "cas/error")) {
                if (core_json.stringField(event_obj, "message")) |msg| try self.setLastError(msg);
            }
        }
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

    fn shouldAttemptEventParse(line: []const u8, expected_types: []const []const u8) bool {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return false;
        if (trimmed[0] != '{') return false;
        if (!std.mem.containsAtLeast(u8, trimmed, 1, "\"type\"")) return false;
        if (!std.mem.containsAtLeast(u8, trimmed, 1, "cas/")) return false;
        for (expected_types) |event_type| {
            if (std.mem.containsAtLeast(u8, trimmed, 1, event_type)) return true;
        }
        return false;
    }
};

fn discoverProxyPath(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const from_cwd = try std.fmt.allocPrint(allocator, "{s}/codex/skills/cas/scripts/cas_proxy.mjs", .{cwd});
    if (pathExists(from_cwd)) return from_cwd;
    allocator.free(from_cwd);

    if (std.posix.getenv("CODEX_HOME")) |codex_home_ptr| {
        const codex_home = codex_home_ptr;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/skills/cas/scripts/cas_proxy.mjs", .{codex_home});
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }

    if (std.posix.getenv("CLAUDE_HOME")) |claude_home_ptr| {
        const claude_home = claude_home_ptr;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/skills/cas/scripts/cas_proxy.mjs", .{claude_home});
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }

    if (pathExists("codex/skills/cas/scripts/cas_proxy.mjs")) {
        return allocator.dupe(u8, "codex/skills/cas/scripts/cas_proxy.mjs");
    }
    if (pathExists("cas_proxy.mjs")) {
        return allocator.dupe(u8, "cas_proxy.mjs");
    }
    return allocator.dupe(u8, "cas_proxy.mjs");
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
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
