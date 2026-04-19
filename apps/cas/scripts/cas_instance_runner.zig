const app_meta = @import("app_meta");
const cas = @import("cas_proxy_client.zig");
const cas_websocket = @import("cas_websocket_transport.zig");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas_instance_runner",
    .help_text = UsageText,
};

const UsageText =
    \\cas_instance_runner
    \\
    \\Run many cas sessions and execute one request per instance.
    \\
    \\Usage:
    \\  cas_instance_runner --cwd DIR [options]
    \\
    \\Required:
    \\  --cwd DIR
    \\
    \\Options:
    \\  --instances N                       Number of instances (default: 12).
    \\  --method NAME                       App-server method (default: thread/list).
    \\  --params-json JSON                  Params as inline JSON.
    \\  --params-file PATH                  Params from JSON file.
    \\  --state-file-dir DIR                Per-instance state files (optional).
    \\  --request-timeout-ms N              Accepted for parity.
    \\  --server-request-timeout-ms N       Forwarded server-request timeout.
    \\  --exec-approval VALUE               auto|accept|acceptForSession|decline|cancel.
    \\  --file-approval VALUE               auto|accept|acceptForSession|decline|cancel.
    \\  --permissions-approval VALUE        deny|grant-turn|grant-session.
    \\  --request-user-input-response-json JSON
    \\                                      Exact result payload for item/tool/requestUserInput.
    \\  --elicitation-action VALUE          decline|cancel|accept.
    \\  --elicitation-content-json JSON     Content payload when elicitation action is accept.
    \\  --dynamic-tool-response-json JSON   Exact result payload for item/tool/call.
    \\  --read-only                         Decline exec + file approvals.
    \\  --opt-out-notification-method M     Suppress notification method (repeatable).
    \\  --client-prefix NAME                Instance client prefix (default: cas-instance).
    \\  --sample N                          Sample count in output (default: 3).
    \\  --json                              Emit JSON.
    \\  --verbose                           Emit per-instance status to stderr.
    \\  --help                              Show help.
    \\  --version                           Show version.
    \\  version                             Show version.
    \\
    \\Examples:
    \\  --method thread/list --params-json '{"cursor":null,"limit":1,"searchTerm":"rollback"}'
    \\  --method thread/unsubscribe --params-json '{"threadId":"thr_123"}'
;

const ParsedArgs = struct {
    cwd: ?[]const u8 = null,
    instances: usize = 12,
    method: []const u8 = "thread/list",
    params_json: ?[]const u8 = null,
    params_file: ?[]const u8 = null,
    state_file_dir: ?[]const u8 = null,
    request_timeout_ms: u32 = 30_000,
    server_request_timeout_ms: ?u32 = null,
    exec_approval: ?[]const u8 = null,
    file_approval: ?[]const u8 = null,
    permissions_approval: ?[]const u8 = null,
    request_user_input_response_json: ?[]const u8 = null,
    elicitation_action: ?[]const u8 = null,
    elicitation_content_json: ?[]const u8 = null,
    dynamic_tool_response_json: ?[]const u8 = null,
    read_only: bool = false,
    opt_out_methods: []const []const u8 = &.{},
    client_prefix: []const u8 = "cas-instance",
    sample: usize = 3,
    json: bool = false,
    verbose: bool = false,
    show_help: bool = false,
    show_version: bool = false,
};

const StartFailure = struct {
    instance: usize,
    @"error": []const u8,
};

const RequestResult = struct {
    instance: usize,
    ok: bool,
    transport: []const u8,
    summary: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

const InstanceSlot = struct {
    client: cas.Client,
    transport: []const u8,
    managed_server: ?cas_websocket.ManagedServer = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    const opts = parseArgs(allocator, argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    if (opts.show_version) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }

    if (opts.show_help) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    const cwd = opts.cwd orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingValue", "--cwd");
    };

    if (opts.instances > 1 and opts.state_file_dir == null) {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.writeAll("Note: by default, state is derived from --cwd, so parallel instances may share it. Use --state-file-dir for per-instance state isolation.\n");
    }

    const params = try buildParamsJson(allocator, opts.method, opts.params_json, opts.params_file);
    defer allocator.free(params);
    _ = opts.request_timeout_ms;
    const resolved_codex_path = cas.resolveExecutableAlloc(allocator, "codex") catch "codex";

    var slots = try allocator.alloc(?InstanceSlot, opts.instances);
    defer allocator.free(slots);
    for (slots) |*slot| slot.* = null;

    var start_failures: std.ArrayList(StartFailure) = .empty;
    defer start_failures.deinit(allocator);
    var request_results: std.ArrayList(RequestResult) = .empty;
    defer request_results.deinit(allocator);

    const started_at = @divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000);

    // Phase 1: start all clients.
    var i: usize = 0;
    while (i < opts.instances) : (i += 1) {
        const instance_num = i + 1;
        const state_file = if (opts.state_file_dir) |dir|
            try std.fmt.allocPrint(allocator, "{s}/{s}-{d}.json", .{ dir, opts.client_prefix, instance_num })
        else
            null;
        defer if (state_file) |owned| allocator.free(owned);

        const client_name = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ opts.client_prefix, instance_num });
        defer allocator.free(client_name);

        var transport: []const u8 = "stdio";
        var managed_server: ?cas_websocket.ManagedServer = cas_websocket.startManagedLoopbackServer(
            allocator,
            cwd,
            resolved_codex_path,
        ) catch null;

        const client = if (managed_server) |server|
            cas.Client.start(allocator, .{
                .cwd = cwd,
                .state_file = state_file,
                .client_name = client_name,
                .server_request_timeout_ms = opts.server_request_timeout_ms,
                .exec_approval = opts.exec_approval,
                .file_approval = opts.file_approval,
                .permissions_approval = opts.permissions_approval,
                .request_user_input_response_json = opts.request_user_input_response_json,
                .elicitation_action = opts.elicitation_action,
                .elicitation_content_json = opts.elicitation_content_json,
                .dynamic_tool_response_json = opts.dynamic_tool_response_json,
                .read_only = opts.read_only,
                .opt_out_notification_methods = opts.opt_out_methods,
                .websocket_url = server.listen_url,
            }) catch blk: {
                var owned_server = server;
                owned_server.kill();
                managed_server = null;
                break :blk cas.Client.start(allocator, .{
                    .cwd = cwd,
                    .state_file = state_file,
                    .client_name = client_name,
                    .server_request_timeout_ms = opts.server_request_timeout_ms,
                    .exec_approval = opts.exec_approval,
                    .file_approval = opts.file_approval,
                    .permissions_approval = opts.permissions_approval,
                    .request_user_input_response_json = opts.request_user_input_response_json,
                    .elicitation_action = opts.elicitation_action,
                    .elicitation_content_json = opts.elicitation_content_json,
                    .dynamic_tool_response_json = opts.dynamic_tool_response_json,
                    .read_only = opts.read_only,
                    .opt_out_notification_methods = opts.opt_out_methods,
                }) catch |err| {
                    const msg = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
                    try start_failures.append(allocator, .{
                        .instance = instance_num,
                        .@"error" = msg,
                    });
                    if (opts.verbose) {
                        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                        const stderr = &stderr_writer.interface;
                        try stderr.print("[start:{d}] fail: {s}\n", .{ instance_num, msg });
                    }
                    continue;
                };
            }
        else
            cas.Client.start(allocator, .{
                .cwd = cwd,
                .state_file = state_file,
                .client_name = client_name,
                .server_request_timeout_ms = opts.server_request_timeout_ms,
                .exec_approval = opts.exec_approval,
                .file_approval = opts.file_approval,
                .permissions_approval = opts.permissions_approval,
                .request_user_input_response_json = opts.request_user_input_response_json,
                .elicitation_action = opts.elicitation_action,
                .elicitation_content_json = opts.elicitation_content_json,
                .dynamic_tool_response_json = opts.dynamic_tool_response_json,
                .read_only = opts.read_only,
                .opt_out_notification_methods = opts.opt_out_methods,
            }) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
                try start_failures.append(allocator, .{
                    .instance = instance_num,
                    .@"error" = msg,
                });
                if (opts.verbose) {
                    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                    const stderr = &stderr_writer.interface;
                    try stderr.print("[start:{d}] fail: {s}\n", .{ instance_num, msg });
                }
                continue;
            };

        if (managed_server != null) transport = "websocket";
        slots[i] = .{
            .client = client,
            .transport = transport,
            .managed_server = managed_server,
        };
        if (opts.verbose) {
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stderr = &stderr_writer.interface;
            try stderr.print("[start:{d}] ok ({s})\n", .{ instance_num, transport });
        }
    }
    const after_start = monotonicMillis();

    // Phase 2: run requests for started clients.
    i = 0;
    while (i < opts.instances) : (i += 1) {
        const instance_num = i + 1;
        if (slots[i] == null) continue;
        var slot = slots[i].?;
        var client = slot.client;
        defer {
            client.close();
            client.deinit();
            if (slot.managed_server) |*server| server.kill();
            slots[i] = null;
        }

        const result_json = client.requestJson(opts.method, params) catch |err| {
            const summary = if (client.lastError()) |detail|
                try allocator.dupe(u8, detail)
            else
                try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
            try request_results.append(allocator, .{
                .instance = instance_num,
                .ok = false,
                .transport = slot.transport,
                .@"error" = summary,
            });
            if (opts.verbose) {
                var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                const stderr = &stderr_writer.interface;
                try stderr.print("[request:{d}] fail ({s}): {s}\n", .{ instance_num, slot.transport, summary });
            }
            continue;
        };
        defer allocator.free(result_json);

        const summary = try summarizeResult(allocator, opts.method, result_json);
        try request_results.append(allocator, .{
            .instance = instance_num,
            .ok = true,
            .transport = slot.transport,
            .summary = summary,
        });
        if (opts.verbose) {
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stderr = &stderr_writer.interface;
            try stderr.print("[request:{d}] ok ({s})\n", .{ instance_num, slot.transport });
        }
    }
    const after_requests = monotonicMillis();

    const requests_ok = countRequestSuccess(request_results.items);
    const requests_failed = request_results.items.len - requests_ok;
    const websocket_count = countTransport(request_results.items, "websocket");
    const stdio_count = countTransport(request_results.items, "stdio");
    const instances_started = request_results.items.len;
    const sample_results = request_results.items[0..@min(opts.sample, request_results.items.len)];

    const payload = .{
        .demo = "cas-instance-runner",
        .cwd = cwd,
        .state_file_dir = opts.state_file_dir,
        .method = opts.method,
        .params = params,
        .instances_requested = opts.instances,
        .instances_started = instances_started,
        .start_failures = start_failures.items,
        .requests_ok = requests_ok,
        .requests_failed = requests_failed,
        .transport_counts = .{
            .websocket = websocket_count,
            .stdio = stdio_count,
        },
        .timing_ms = .{
            .start_all_clients = after_start - started_at,
            .run_all_requests = after_requests - after_start,
            .total = after_requests - started_at,
        },
        .sample_results = sample_results,
    };

    if (opts.json) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try std.json.Stringify.value(payload, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeAll("\n");
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_instance_runner summary\n", .{});
        try stdout.print("cwd: {s}\n", .{cwd});
        try stdout.print("method: {s}\n", .{opts.method});
        try stdout.print("instances requested: {d}\n", .{opts.instances});
        try stdout.print("instances started:   {d}\n", .{instances_started});
        try stdout.print("requests ok:      {d}\n", .{requests_ok});
        try stdout.print("requests failed:  {d}\n", .{requests_failed});
        try stdout.print("transport counts: websocket={d}, stdio={d}\n", .{ websocket_count, stdio_count });
        try stdout.print("timing ms: start={d}, request={d}, total={d}\n", .{
            after_start - started_at,
            after_requests - after_start,
            after_requests - started_at,
        });
        if (sample_results.len > 0) {
            try stdout.writeAll("sample results:\n");
            for (sample_results) |sample| {
                if (sample.ok) {
                    try stdout.print("- instance {d}: ok ({s}) {s}\n", .{
                        sample.instance,
                        sample.transport,
                        sample.summary orelse "{}",
                    });
                } else {
                    try stdout.print("- instance {d}: fail ({s}) {s}\n", .{
                        sample.instance,
                        sample.transport,
                        sample.@"error" orelse "unknown",
                    });
                }
            }
        }
    }

    const ok = requests_failed == 0 and start_failures.items.len == 0;
    std.process.exit(if (ok) 0 else 1);
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    var out = ParsedArgs{};
    var methods: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (core_cli.isHelpArg(arg)) {
            out.show_help = true;
            continue;
        }
        if (core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) {
            out.show_version = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--read-only")) {
            out.read_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            out.verbose = true;
            continue;
        }

        i += 1;
        if (i >= argv.len) return error.MissingValue;
        const value = argv[i];

        if (std.mem.eql(u8, arg, "--cwd")) {
            out.cwd = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--instances")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidInstances;
            out.instances = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--method")) {
            out.method = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--params-json")) {
            out.params_json = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--params-file")) {
            out.params_file = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--state-file-dir")) {
            out.state_file_dir = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--request-timeout-ms")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidTimeout;
            out.request_timeout_ms = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--server-request-timeout-ms")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed < 0) return error.InvalidServerTimeout;
            out.server_request_timeout_ms = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--exec-approval")) {
            out.exec_approval = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--file-approval")) {
            out.file_approval = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--permissions-approval")) {
            out.permissions_approval = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--request-user-input-response-json")) {
            var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, value, .{});
            defer parsed_json.deinit();
            out.request_user_input_response_json = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--elicitation-action")) {
            out.elicitation_action = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--elicitation-content-json")) {
            var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, value, .{});
            defer parsed_json.deinit();
            out.elicitation_content_json = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dynamic-tool-response-json")) {
            var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, value, .{});
            defer parsed_json.deinit();
            out.dynamic_tool_response_json = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--opt-out-notification-method")) {
            try methods.append(allocator, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--client-prefix")) {
            out.client_prefix = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sample")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed < 0) return error.InvalidSample;
            out.sample = @intCast(parsed);
            continue;
        }
        return error.UnknownArg;
    }

    if (out.params_json != null and out.params_file != null) return error.DuplicateParamsSource;
    out.opt_out_methods = try methods.toOwnedSlice(allocator);
    return out;
}

fn buildParamsJson(allocator: std.mem.Allocator, method: []const u8, params_json: ?[]const u8, params_file: ?[]const u8) ![]u8 {
    if (params_json) |raw| {
        var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed_json.deinit();
        return allocator.dupe(u8, raw);
    }
    if (params_file) |path| {
        const raw = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(4 * 1024 * 1024));
        var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed_json.deinit();
        return raw;
    }
    if (std.mem.eql(u8, method, "thread/list")) {
        return allocator.dupe(u8, "{\"cursor\":null,\"limit\":1}");
    }
    return allocator.dupe(u8, "{}");
}

fn summarizeResult(allocator: std.mem.Allocator, method: []const u8, result_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return std.fmt.allocPrint(allocator, "{{\"value\":{s}}}", .{result_json}),
    };

    if (std.mem.eql(u8, method, "thread/list")) {
        const data_val = root_obj.get("data") orelse return allocator.dupe(u8, "{\"firstThreadId\":null,\"rows\":0}");
        const arr = switch (data_val) {
            .array => |a| a,
            else => return allocator.dupe(u8, "{\"firstThreadId\":null,\"rows\":0}"),
        };
        var first_thread_id: ?[]const u8 = null;
        if (arr.items.len > 0) {
            switch (arr.items[0]) {
                .object => |first_obj| {
                    if (first_obj.get("id")) |id_val| {
                        first_thread_id = switch (id_val) {
                            .string => |s| s,
                            else => null,
                        };
                    }
                },
                else => {},
            }
        }
        return stringifyAnyAlloc(allocator, .{
            .firstThreadId = first_thread_id,
            .rows = arr.items.len,
        });
    }

    if (std.mem.eql(u8, method, "thread/read")) {
        const thread_val = root_obj.get("thread") orelse return allocator.dupe(u8, "{\"threadId\":null,\"turns\":null}");
        const thread_obj = switch (thread_val) {
            .object => |o| o,
            else => return allocator.dupe(u8, "{\"threadId\":null,\"turns\":null}"),
        };
        const thread_id = if (thread_obj.get("id")) |id_val|
            switch (id_val) {
                .string => |s| s,
                else => null,
            }
        else
            null;
        const turns_count = if (thread_obj.get("turns")) |turns_val|
            switch (turns_val) {
                .array => |arr| @as(?usize, arr.items.len),
                else => null,
            }
        else
            null;
        return stringifyAnyAlloc(allocator, .{
            .threadId = thread_id,
            .turns = turns_count,
        });
    }

    if (std.mem.eql(u8, method, "thread/unsubscribe")) {
        const status = if (root_obj.get("status")) |status_val|
            switch (status_val) {
                .string => |s| s,
                else => null,
            }
        else
            null;
        return stringifyAnyAlloc(allocator, .{
            .status = status,
        });
    }

    if (std.mem.eql(u8, method, "turn/start")) {
        const turn_val = root_obj.get("turn") orelse return allocator.dupe(u8, "{\"turnId\":null,\"status\":null}");
        const turn_obj = switch (turn_val) {
            .object => |o| o,
            else => return allocator.dupe(u8, "{\"turnId\":null,\"status\":null}"),
        };
        const turn_id = if (turn_obj.get("id")) |id_val|
            switch (id_val) {
                .string => |s| s,
                else => null,
            }
        else
            null;
        const status = if (turn_obj.get("status")) |status_val|
            switch (status_val) {
                .string => |s| s,
                else => null,
            }
        else
            null;
        return stringifyAnyAlloc(allocator, .{
            .turnId = turn_id,
            .status = status,
        });
    }

    // Generic object summary: first 8 keys.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"keys\":[");
    var written: usize = 0;
    var it = root_obj.iterator();
    while (it.next()) |entry| {
        if (written >= 8) break;
        if (written > 0) try out.writer.writeAll(",");
        try std.json.Stringify.value(entry.key_ptr.*, .{}, &out.writer);
        written += 1;
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn monotonicMillis() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000));
}

fn countRequestSuccess(items: []const RequestResult) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.ok) count += 1;
    }
    return count;
}

fn countTransport(items: []const RequestResult, transport: []const u8) usize {
    var count: usize = 0;
    for (items) |item| {
        if (std.mem.eql(u8, item.transport, transport)) count += 1;
    }
    return count;
}

fn stringifyAnyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "parseArgs accepts core options and collects opt-out methods" {
    const argv = [_][]const u8{
        "cas_instance_runner",
        "--cwd",
        "/tmp/repo",
        "--instances",
        "4",
        "--method",
        "thread/read",
        "--opt-out-notification-method",
        "thread/item/stream",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(parsed.opt_out_methods);

    try std.testing.expectEqual(@as(?[]const u8, "/tmp/repo"), parsed.cwd);
    try std.testing.expectEqual(@as(usize, 4), parsed.instances);
    try std.testing.expectEqualStrings("thread/read", parsed.method);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(@as(usize, 1), parsed.opt_out_methods.len);
    try std.testing.expectEqualStrings("thread/item/stream", parsed.opt_out_methods[0]);
}

test "parseArgs accepts extended server request controls" {
    const argv = [_][]const u8{
        "cas_instance_runner",
        "--cwd",
        "/tmp/repo",
        "--permissions-approval",
        "grant-session",
        "--request-user-input-response-json",
        "{\"answers\":{\"mode\":{\"answers\":[\"fast\"]}}}",
        "--elicitation-action",
        "accept",
        "--elicitation-content-json",
        "{\"confirmed\":true}",
        "--dynamic-tool-response-json",
        "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"ok\"}],\"success\":true}",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(parsed.opt_out_methods);

    try std.testing.expectEqual(@as(?[]const u8, "grant-session"), parsed.permissions_approval);
    try std.testing.expectEqual(@as(?[]const u8, "{\"answers\":{\"mode\":{\"answers\":[\"fast\"]}}}"), parsed.request_user_input_response_json);
    try std.testing.expectEqual(@as(?[]const u8, "accept"), parsed.elicitation_action);
    try std.testing.expectEqual(@as(?[]const u8, "{\"confirmed\":true}"), parsed.elicitation_content_json);
    try std.testing.expectEqual(@as(?[]const u8, "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"ok\"}],\"success\":true}"), parsed.dynamic_tool_response_json);
}

test "parseArgs rejects duplicate parameter sources" {
    const argv = [_][]const u8{
        "cas_instance_runner",
        "--cwd",
        "/tmp/repo",
        "--params-json",
        "{}",
        "--params-file",
        "params.json",
    };

    try std.testing.expectError(error.DuplicateParamsSource, parseArgs(std.testing.allocator, &argv));
}

test "summarizeResult returns thread/list compact summary" {
    const summary = try summarizeResult(
        std.testing.allocator,
        "thread/list",
        "{\"data\":[{\"id\":\"thr_1\"},{\"id\":\"thr_2\"}]}",
    );
    defer std.testing.allocator.free(summary);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, summary, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(@as(?i64, 2), cas.intField(parsed.value.object, "rows"));
    try std.testing.expectEqualStrings("thr_1", cas.stringField(parsed.value.object, "firstThreadId").?);
}

test "summarizeResult returns turn/start compact summary" {
    const summary = try summarizeResult(
        std.testing.allocator,
        "turn/start",
        "{\"turn\":{\"id\":\"turn_1\",\"status\":\"inProgress\"}}",
    );
    defer std.testing.allocator.free(summary);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, summary, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("turn_1", cas.stringField(parsed.value.object, "turnId").?);
    try std.testing.expectEqualStrings("inProgress", cas.stringField(parsed.value.object, "status").?);
}
