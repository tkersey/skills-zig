const std = @import("std");
const cas = @import("cas_proxy_client.zig");

const UsageText =
    \\cas_smoke_check.zig
    \\
    \\Smoke-check cas support for key app-server APIs.
    \\
    \\Usage:
    \\  zig run codex/skills/cas/scripts/cas_smoke_check.zig -- --cwd DIR [options]
    \\
    \\Required:
    \\  --cwd DIR                        Workspace for cas/app-server.
    \\
    \\Options:
    \\  --thread-id THREAD_ID            Existing thread id to reuse (optional).
    \\  --request-timeout-ms N           Timeout per request (accepted for parity).
    \\  --opt-out-notification-method M  Suppress notification method (repeatable).
    \\  --json                           Emit machine-readable JSON report.
    \\  --help                           Show this help.
;

const CheckResult = struct {
    name: []const u8,
    ok: bool,
    detail: []const u8,
};

const ParsedArgs = struct {
    cwd: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    request_timeout_ms: u32 = 15_000,
    opt_out_methods: []const []const u8 = &.{},
    json: bool = false,
    show_help: bool = false,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = parseArgs(allocator) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}\n{s}\n", .{@errorName(err), UsageText});
        return;
    };

    if (parsed.show_help) {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}\n", .{UsageText});
        return;
    }

    const cwd = parsed.cwd orelse {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("Missing --cwd\n{s}\n", .{UsageText});
        std.process.exit(2);
    };

    var checks: std.ArrayList(CheckResult) = .empty;
    defer checks.deinit(allocator);

    var thread_id = parsed.thread_id;
    var client = try cas.Client.start(allocator, .{
        .cwd = cwd,
        .opt_out_notification_methods = parsed.opt_out_methods,
    });
    defer {
        client.close();
        client.deinit();
    }

    _ = parsed.request_timeout_ms;

    // Check 1: experimentalFeature/list succeeds.
    {
        const maybe_result = client.requestJson("experimentalFeature/list", "{\"cursor\":null,\"limit\":1}") catch |err| blk: {
            try checks.append(allocator, .{
                .name = "experimentalFeature/list",
                .ok = false,
                .detail = try errorSummary(allocator, &client, err),
            });
            break :blk null;
        };

        if (maybe_result) |result_json| {
            defer allocator.free(result_json);
            const rows = try countDataRows(allocator, result_json);
            const rows_text = if (rows) |r| try std.fmt.allocPrint(allocator, "{d}", .{r}) else "unknown";
            try checks.append(allocator, .{
                .name = "experimentalFeature/list",
                .ok = true,
                .detail = try std.fmt.allocPrint(allocator, "ok (rows={s})", .{rows_text}),
            });
        }
    }

    // Check 2: thread/resume method is wired.
    {
        var thread_resume_ok = true;
        var detail: []const u8 = "ok";

        const maybe_resumed = blk: {
            if (thread_id == null) {
                const start_params = try stringifyAnyAlloc(allocator, .{
                    .cwd = cwd,
                    .experimentalRawEvents = false,
                });
                defer allocator.free(start_params);
                const start_json = client.requestJson("thread/start", start_params) catch |err| {
                    const summary = try errorSummary(allocator, &client, err);
                    if (isMethodUnavailableError(summary)) {
                        thread_resume_ok = false;
                        detail = try std.fmt.allocPrint(allocator, "method unavailable: {s}", .{summary});
                    } else {
                        detail = try std.fmt.allocPrint(allocator, "method reached server: {s}", .{summary});
                    }
                    break :blk null;
                };
                defer allocator.free(start_json);
                thread_id = try extractThreadId(allocator, start_json);
            }

            const resolved_thread_id = thread_id orelse {
                thread_resume_ok = false;
                detail = "thread/start did not return thread.id";
                break :blk null;
            };

            const resume_params = try stringifyAnyAlloc(allocator, .{
                .threadId = resolved_thread_id,
            });
            defer allocator.free(resume_params);

            const resume_json = client.requestJson("thread/resume", resume_params) catch |err| {
                const summary = try errorSummary(allocator, &client, err);
                if (isMethodUnavailableError(summary)) {
                    thread_resume_ok = false;
                    detail = try std.fmt.allocPrint(allocator, "method unavailable: {s}", .{summary});
                } else {
                    detail = try std.fmt.allocPrint(allocator, "method reached server: {s}", .{summary});
                }
                break :blk null;
            };
            defer allocator.free(resume_json);
            break :blk try extractThreadId(allocator, resume_json);
        };

        if (thread_resume_ok and maybe_resumed != null and thread_id != null) {
            const resumed = maybe_resumed.?;
            if (!std.mem.eql(u8, resumed, thread_id.?)) {
                thread_resume_ok = false;
                detail = try std.fmt.allocPrint(allocator, "thread/resume returned unexpected thread id: {s}", .{resumed});
            }
        }

        try checks.append(allocator, .{
            .name = "thread/resume",
            .ok = thread_resume_ok,
            .detail = detail,
        });
    }

    // Check 3: turn/steer method is wired; precondition failures are acceptable.
    {
        var steer_ok = true;
        var steer_detail: []const u8 = "ok";

        if (thread_id == null) {
            steer_ok = false;
            steer_detail = "no threadId available for turn/steer check";
        } else {
            const expected_turn_id = try std.fmt.allocPrint(allocator, "cas-smoke-{d}", .{std.time.timestamp()});
            defer allocator.free(expected_turn_id);

            const steer_params = try stringifyAnyAlloc(allocator, .{
                .threadId = thread_id.?,
                .expectedTurnId = expected_turn_id,
                .input = [_]struct {
                    type: []const u8,
                    text: []const u8,
                    text_elements: []const []const u8,
                }{
                    .{
                        .type = "text",
                        .text = "cas smoke-check turn steer",
                        .text_elements = &.{},
                    },
                },
            });
            defer allocator.free(steer_params);

            const maybe_steer_json = client.requestJson("turn/steer", steer_params) catch |err| blk: {
                const summary = try errorSummary(allocator, &client, err);
                if (isMethodUnavailableError(summary)) {
                    steer_ok = false;
                    steer_detail = try std.fmt.allocPrint(allocator, "method unavailable: {s}", .{summary});
                } else {
                    steer_detail = try std.fmt.allocPrint(allocator, "method reached server (expected precondition rejection): {s}", .{summary});
                }
                break :blk null;
            };
            if (maybe_steer_json) |steer_json| allocator.free(steer_json);
        }

        try checks.append(allocator, .{
            .name = "turn/steer",
            .ok = steer_ok,
            .detail = steer_detail,
        });
    }

    var overall_ok = true;
    for (checks.items) |check| {
        if (!check.ok) overall_ok = false;
    }

    if (parsed.json) {
        const report = .{
            .check = "cas-smoke-check",
            .cwd = cwd,
            .threadId = thread_id,
            .ok = overall_ok,
            .checks = checks.items,
        };
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeAll("\n");
    } else {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas smoke-check\n", .{});
        try stdout.print("cwd: {s}\n", .{cwd});
        try stdout.print("threadId: {s}\n", .{thread_id orelse "n/a"});
        try stdout.print("overall: {s}\n", .{if (overall_ok) "pass" else "fail"});
        for (checks.items) |check| {
            try stdout.print("- {s}: {s} ({s})\n", .{
                check.name,
                if (check.ok) "pass" else "fail",
                check.detail,
            });
        }
    }

    std.process.exit(if (overall_ok) 0 else 1);
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
        if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
            continue;
        }

        i += 1;
        if (i >= argv.len) return error.MissingValue;
        const value = argv[i];

        if (std.mem.eql(u8, arg, "--cwd")) {
            out.cwd = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--thread-id")) {
            out.thread_id = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--request-timeout-ms")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidTimeout;
            out.request_timeout_ms = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--opt-out-notification-method")) {
            try methods.append(allocator, value);
            continue;
        }
        return error.UnknownArg;
    }

    out.opt_out_methods = try methods.toOwnedSlice(allocator);
    return out;
}

fn stringifyAnyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn countDataRows(allocator: std.mem.Allocator, result_json: []const u8) !?usize {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };
    const data_val = root_obj.get("data") orelse return null;
    return switch (data_val) {
        .array => |a| a.items.len,
        else => null,
    };
}

fn extractThreadId(allocator: std.mem.Allocator, result_json: []const u8) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };
    const thread_val = root_obj.get("thread") orelse return null;
    const thread_obj = switch (thread_val) {
        .object => |obj| obj,
        else => return null,
    };
    const id_val = thread_obj.get("id") orelse return null;
    const id = switch (id_val) {
        .string => |s| s,
        else => return null,
    };
    return try allocator.dupe(u8, id);
}

fn errorSummary(allocator: std.mem.Allocator, client: *cas.Client, err: anyerror) ![]const u8 {
    if (client.lastError()) |detail| return detail;
    return std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
}

fn isMethodUnavailableError(text: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, text, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    if (parsed) |p| {
        if (p.value == .object) {
            if (cas.intField(p.value.object, "code")) |code| {
                if (code == -32601) return true;
            }
        }
    }
    return containsCaseInsensitive(text, "method not found") or
        containsCaseInsensitive(text, "unknown method") or
        containsCaseInsensitive(text, "unrecognized method");
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}
