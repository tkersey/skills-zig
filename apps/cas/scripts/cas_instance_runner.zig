const std = @import("std");
const cas = @import("cas_proxy_client.zig");

const UsageText =
    \\cas_instance_runner.zig
    \\
    \\Run many cas sessions and execute one request per instance.
    \\
    \\Usage:
    \\  zig run codex/skills/cas/scripts/cas_instance_runner.zig -- --cwd DIR [options]
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
    \\  --read-only                         Decline exec + file approvals.
    \\  --opt-out-notification-method M     Suppress notification method (repeatable).
    \\  --client-prefix NAME                Instance client prefix (default: cas-instance).
    \\  --sample N                          Sample count in output (default: 3).
    \\  --json                              Emit JSON.
    \\  --verbose                           Emit per-instance status to stderr.
    \\  --help                              Show help.
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
    read_only: bool = false,
    opt_out_methods: []const []const u8 = &.{},
    client_prefix: []const u8 = "cas-instance",
    sample: usize = 3,
    json: bool = false,
    verbose: bool = false,
    show_help: bool = false,
};

const StartFailure = struct {
    instance: usize,
    @"error": []const u8,
};

const RequestResult = struct {
    instance: usize,
    ok: bool,
    summary: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opts = parseArgs(allocator) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}\n{s}\n", .{@errorName(err), UsageText});
        std.process.exit(2);
    };

    if (opts.show_help) {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}\n", .{UsageText});
        return;
    }

    const cwd = opts.cwd orelse {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("Missing --cwd\n{s}\n", .{UsageText});
        std.process.exit(2);
    };

    if (opts.instances > 1 and opts.state_file_dir == null) {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.writeAll("Note: by default, state is derived from --cwd, so parallel instances may share it. Use --state-file-dir for per-instance state isolation.\n");
    }

    const params = try buildParamsJson(allocator, opts.method, opts.params_json, opts.params_file);
    defer allocator.free(params);
    _ = opts.request_timeout_ms;

    var slots = try allocator.alloc(?cas.Client, opts.instances);
    defer allocator.free(slots);
    for (slots) |*slot| slot.* = null;

    var start_failures: std.ArrayList(StartFailure) = .empty;
    defer start_failures.deinit(allocator);
    var request_results: std.ArrayList(RequestResult) = .empty;
    defer request_results.deinit(allocator);

    const started_at = std.time.milliTimestamp();

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

        const client = cas.Client.start(allocator, .{
            .cwd = cwd,
            .state_file = state_file,
            .client_name = client_name,
            .server_request_timeout_ms = opts.server_request_timeout_ms,
            .exec_approval = opts.exec_approval,
            .file_approval = opts.file_approval,
            .read_only = opts.read_only,
            .opt_out_notification_methods = opts.opt_out_methods,
        }) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
            try start_failures.append(allocator, .{
                .instance = instance_num,
                .@"error" = msg,
            });
            if (opts.verbose) {
                var stderr_writer = std.fs.File.stderr().writer(&.{});
                const stderr = &stderr_writer.interface;
                try stderr.print("[start:{d}] fail: {s}\n", .{ instance_num, msg });
            }
            continue;
        };

        slots[i] = client;
        if (opts.verbose) {
            var stderr_writer = std.fs.File.stderr().writer(&.{});
            const stderr = &stderr_writer.interface;
            try stderr.print("[start:{d}] ok\n", .{instance_num});
        }
    }
    const after_start = std.time.milliTimestamp();

    // Phase 2: run requests for started clients.
    i = 0;
    while (i < opts.instances) : (i += 1) {
        const instance_num = i + 1;
        if (slots[i] == null) continue;
        var client = slots[i].?;
        defer {
            client.close();
            client.deinit();
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
                .@"error" = summary,
            });
            if (opts.verbose) {
                var stderr_writer = std.fs.File.stderr().writer(&.{});
                const stderr = &stderr_writer.interface;
                try stderr.print("[request:{d}] fail: {s}\n", .{ instance_num, summary });
            }
            continue;
        };
        defer allocator.free(result_json);

        const summary = try summarizeResult(allocator, opts.method, result_json);
        try request_results.append(allocator, .{
            .instance = instance_num,
            .ok = true,
            .summary = summary,
        });
        if (opts.verbose) {
            var stderr_writer = std.fs.File.stderr().writer(&.{});
            const stderr = &stderr_writer.interface;
            try stderr.print("[request:{d}] ok\n", .{instance_num});
        }
    }
    const after_requests = std.time.milliTimestamp();

    const requests_ok = countRequestSuccess(request_results.items);
    const requests_failed = request_results.items.len - requests_ok;
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
        .timing_ms = .{
            .start_all_clients = after_start - started_at,
            .run_all_requests = after_requests - after_start,
            .total = after_requests - started_at,
        },
        .sample_results = sample_results,
    };

    if (opts.json) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try std.json.Stringify.value(payload, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeAll("\n");
    } else {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_instance_runner summary\n", .{});
        try stdout.print("cwd: {s}\n", .{cwd});
        try stdout.print("method: {s}\n", .{opts.method});
        try stdout.print("instances requested: {d}\n", .{opts.instances});
        try stdout.print("instances started:   {d}\n", .{instances_started});
        try stdout.print("requests ok:      {d}\n", .{requests_ok});
        try stdout.print("requests failed:  {d}\n", .{requests_failed});
        try stdout.print("timing ms: start={d}, request={d}, total={d}\n", .{
            after_start - started_at,
            after_requests - after_start,
            after_requests - started_at,
        });
        if (sample_results.len > 0) {
            try stdout.writeAll("sample results:\n");
            for (sample_results) |sample| {
                if (sample.ok) {
                    try stdout.print("- instance {d}: ok {s}\n", .{
                        sample.instance,
                        sample.summary orelse "{}",
                    });
                } else {
                    try stdout.print("- instance {d}: fail {s}\n", .{
                        sample.instance,
                        sample.@"error" orelse "unknown",
                    });
                }
            }
        }
    }

    const ok = requests_failed == 0 and start_failures.items.len == 0;
    std.process.exit(if (ok) 0 else 1);
}

fn parseArgs(allocator: std.mem.Allocator) !ParsedArgs {
    const argv = try std.process.argsAlloc(allocator);

    var out = ParsedArgs{};
    var methods: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            out.show_help = true;
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
        _ = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        return allocator.dupe(u8, raw);
    }
    if (params_file) |path| {
        const raw = try std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
        _ = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
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

fn countRequestSuccess(items: []const RequestResult) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.ok) count += 1;
    }
    return count;
}

fn stringifyAnyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}
