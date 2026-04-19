const app_meta = @import("app_meta");
const cas = @import("cas_proxy_client.zig");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas_smoke_check",
    .help_text = UsageText,
};

const UsageText =
    \\cas_smoke_check
    \\
    \\Smoke-check cas support for key app-server APIs.
    \\
    \\Usage:
    \\  cas_smoke_check --cwd DIR [options]
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
    \\  --version                        Show version.
    \\  version                          Show version.
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
    show_version: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    const parsed = parseArgs(allocator, argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    if (parsed.show_version) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }

    if (parsed.show_help) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    const cwd = parsed.cwd orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingValue", "--cwd");
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

    // Check 3: turn/start returns a turn id for a resumed thread.
    {
        var turn_start_ok = true;
        var turn_start_detail: []const u8 = "ok";
        var started_turn_id: ?[]const u8 = null;

        if (thread_id == null) {
            turn_start_ok = false;
            turn_start_detail = "no threadId available for turn/start check";
        } else {
            const turn_start_params = try stringifyAnyAlloc(allocator, .{
                .threadId = thread_id.?,
                .input = [_]struct {
                    type: []const u8,
                    text: []const u8,
                }{
                    .{
                        .type = "text",
                        .text = "cas smoke-check turn start",
                    },
                },
            });
            defer allocator.free(turn_start_params);

            const turn_start_json = client.requestJson("turn/start", turn_start_params) catch |err| blk: {
                const summary = try errorSummary(allocator, &client, err);
                if (isMethodUnavailableError(summary)) {
                    turn_start_ok = false;
                    turn_start_detail = try std.fmt.allocPrint(allocator, "method unavailable: {s}", .{summary});
                } else {
                    turn_start_detail = try std.fmt.allocPrint(allocator, "method reached server: {s}", .{summary});
                }
                break :blk null;
            };

            if (turn_start_json) |json| {
                defer allocator.free(json);
                started_turn_id = try extractTurnId(allocator, json);
                if (started_turn_id == null) {
                    turn_start_ok = false;
                    turn_start_detail = "turn/start did not return turn.id";
                }
            }
        }

        try checks.append(allocator, .{
            .name = "turn/start",
            .ok = turn_start_ok,
            .detail = turn_start_detail,
        });

        // Check 4: turn/interrupt method is wired; race/precondition failures are acceptable.
        var interrupt_ok = true;
        var interrupt_detail: []const u8 = "ok";

        if (thread_id == null or started_turn_id == null) {
            interrupt_ok = false;
            interrupt_detail = "no active turnId available for turn/interrupt check";
        } else {
            const interrupt_params = try stringifyAnyAlloc(allocator, .{
                .threadId = thread_id.?,
                .turnId = started_turn_id.?,
            });
            defer allocator.free(interrupt_params);

            const maybe_interrupt_json = client.requestJson("turn/interrupt", interrupt_params) catch |err| blk: {
                const summary = try errorSummary(allocator, &client, err);
                if (isMethodUnavailableError(summary)) {
                    interrupt_ok = false;
                    interrupt_detail = try std.fmt.allocPrint(allocator, "method unavailable: {s}", .{summary});
                } else {
                    interrupt_detail = try std.fmt.allocPrint(allocator, "method reached server (expected race/precondition rejection): {s}", .{summary});
                }
                break :blk null;
            };
            if (maybe_interrupt_json) |interrupt_json| allocator.free(interrupt_json);
        }

        try checks.append(allocator, .{
            .name = "turn/interrupt",
            .ok = interrupt_ok,
            .detail = interrupt_detail,
        });
    }

    // Check 5: turn/steer method is wired; precondition failures are acceptable.
    {
        var steer_ok = true;
        var steer_detail: []const u8 = "ok";

        if (thread_id == null) {
            steer_ok = false;
            steer_detail = "no threadId available for turn/steer check";
        } else {
            const expected_turn_id = try std.fmt.allocPrint(allocator, "cas-smoke-{d}", .{@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000)});
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
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeAll("\n");
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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

fn extractTurnId(allocator: std.mem.Allocator, result_json: []const u8) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };
    const turn_val = root_obj.get("turn") orelse return null;
    const turn_obj = switch (turn_val) {
        .object => |obj| obj,
        else => return null,
    };
    const id_val = turn_obj.get("id") orelse return null;
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

test "parseArgs accepts core options and collects opt-out methods" {
    const argv = [_][]const u8{
        "cas_smoke_check",
        "--cwd",
        "/tmp/repo",
        "--thread-id",
        "thr_123",
        "--request-timeout-ms",
        "45000",
        "--opt-out-notification-method",
        "thread/item/stream",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(parsed.opt_out_methods);

    try std.testing.expectEqual(@as(?[]const u8, "/tmp/repo"), parsed.cwd);
    try std.testing.expectEqual(@as(?[]const u8, "thr_123"), parsed.thread_id);
    try std.testing.expectEqual(@as(u32, 45_000), parsed.request_timeout_ms);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(@as(usize, 1), parsed.opt_out_methods.len);
    try std.testing.expectEqualStrings("thread/item/stream", parsed.opt_out_methods[0]);
}

test "extractTurnId reads nested turn id" {
    const turn_id = try extractTurnId(
        std.testing.allocator,
        "{\"turn\":{\"id\":\"turn_123\",\"status\":\"inProgress\"}}",
    );
    defer if (turn_id) |id| std.testing.allocator.free(id);

    try std.testing.expect(turn_id != null);
    try std.testing.expectEqualStrings("turn_123", turn_id.?);
}

test "parseArgs rejects non-positive request timeout" {
    const argv = [_][]const u8{
        "cas_smoke_check",
        "--cwd",
        "/tmp/repo",
        "--request-timeout-ms",
        "0",
    };

    try std.testing.expectError(error.InvalidTimeout, parseArgs(std.testing.allocator, &argv));
}

test "usage text references installed binary" {
    try std.testing.expect(std.mem.indexOf(u8, UsageText, "zig run codex/skills") == null);
    try std.testing.expect(std.mem.indexOf(u8, UsageText, "cas_smoke_check --cwd DIR [options]") != null);
}

test "countDataRows and extractThreadId parse expected fields" {
    const rows = try countDataRows(std.testing.allocator, "{\"data\":[{\"id\":\"a\"},{\"id\":\"b\"}]}");
    try std.testing.expectEqual(@as(?usize, 2), rows);

    const thread_id = try extractThreadId(std.testing.allocator, "{\"thread\":{\"id\":\"thr_abc\"}}");
    defer if (thread_id) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(thread_id != null);
    try std.testing.expectEqualStrings("thr_abc", thread_id.?);
}

test "isMethodUnavailableError handles structured and text errors" {
    try std.testing.expect(isMethodUnavailableError("{\"code\":-32601,\"message\":\"Method not found\"}"));
    try std.testing.expect(isMethodUnavailableError("UNKNOWN METHOD thread/resume"));
    try std.testing.expect(!isMethodUnavailableError("{\"code\":-32000,\"message\":\"server error\"}"));
}
