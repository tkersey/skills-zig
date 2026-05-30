const app_meta = @import("app_meta");
const cas = @import("cas_proxy_client.zig");
const cas_websocket = @import("cas_websocket_transport.zig");
const core_cli = @import("core_cli");
const goal_core = @import("cas_goal_core.zig");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas_goal",
    .help_text = UsageText,
};

const UsageText =
    \\cas_goal
    \\
    \\Manage Codex app-server thread goals through the public v2 goal APIs.
    \\
    \\Usage:
    \\  cas_goal <resolve|get|set|clear|status|wait> --cwd DIR [options]
    \\
    \\Target selection:
    \\  --thread-id ID                      Select an exact thread.
    \\  --latest                           Select the latest non-ephemeral thread for --cwd.
    \\
    \\Operation options:
    \\  --objective TEXT                    Goal objective for set.
    \\  --status STATUS                     active|paused|blocked|usageLimited|budgetLimited|complete.
    \\  --token-budget N|null              Set or clear token budget.
    \\  --timeout-ms N                     Wait timeout (default: 600000).
    \\  --poll-ms N                        Wait poll interval (default: 1000).
    \\  --dry-run                          Print selected target and intended method without mutating.
    \\  --json                             Emit stable JSON output.
    \\  --hooks MODE                       Hook policy: inherit|off|require-observed (default: inherit).
    \\  --server-request-timeout-ms N      Forwarded server-request timeout.
    \\  --codex-path PATH                  Codex executable (default: codex).
    \\  --read-only                        Decline exec + file approvals.
    \\  --help                             Show help.
    \\  --version                          Show version.
    \\  version                            Show version.
    \\
    \\Examples:
    \\  cas goal resolve --cwd /repo --latest --json
    \\  cas goal set --cwd /repo --objective "finish the review" --json
    \\  cas goal clear --cwd /repo --latest --dry-run --json
    \\  cas goal wait --cwd /repo --thread-id thr_123 --timeout-ms 300000 --json
;

const ParsedArgs = goal_core.ParsedArgs;
const SelectedTarget = goal_core.SelectedTarget;
const GoalEnvelope = goal_core.GoalEnvelope;

const GoalClient = struct {
    client: cas.Client,
    managed_server: ?cas_websocket.ManagedServer = null,

    fn deinit(self: *GoalClient, allocator: std.mem.Allocator) void {
        self.client.close();
        self.client.deinit();
        if (self.managed_server) |*server| {
            server.kill();
            server.deinit(allocator);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    const opts = goal_core.parseArgs(allocator, argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    if (opts.show_version) return printVersion();
    if (opts.show_help) return printHelp();

    const cwd = opts.cwd orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingValue", "--cwd");
    };
    goal_core.validateArgs(opts) catch |err| {
        try fail(allocator, opts, @errorName(err), null, 2);
    };

    var goal_client = startGoalClient(allocator, opts, cwd, init.io) catch |err| {
        try fail(allocator, opts, "transportFailure", @errorName(err), 1);
    };
    defer goal_client.deinit(allocator);

    runCommand(allocator, opts, cwd, &goal_client.client) catch |err| {
        const detail = goal_client.client.lastError() orelse @errorName(err);
        try fail(allocator, opts, classifyError(detail), detail, 1);
    };
}

fn runCommand(allocator: std.mem.Allocator, opts: ParsedArgs, cwd: []const u8, client: *cas.Client) !void {
    switch (opts.command) {
        .resolve => {
            const target = try resolveTarget(allocator, client, opts, cwd, false);
            defer goal_core.freeTarget(allocator, target);
            try emitTarget(allocator, opts, target, null);
        },
        .get => try runGet(allocator, opts, cwd, client),
        .set => try runSet(allocator, opts, cwd, client),
        .clear => try runClear(allocator, opts, cwd, client),
        .status => try runStatus(allocator, opts, cwd, client),
        .wait => try runWait(allocator, opts, cwd, client),
    }
}

fn runGet(allocator: std.mem.Allocator, opts: ParsedArgs, cwd: []const u8, client: *cas.Client) !void {
    const target = try resolveTarget(allocator, client, opts, cwd, false);
    defer goal_core.freeTarget(allocator, target);
    if (opts.dry_run) return emitTarget(allocator, opts, target, "thread/goal/get");
    const goal = try requestGoalGet(allocator, client, target.thread_id.?);
    defer goal_core.freeGoalEnvelope(allocator, goal);
    try emitGoal(allocator, opts, target, goal, "ok", 0);
}

fn runSet(allocator: std.mem.Allocator, opts: ParsedArgs, cwd: []const u8, client: *cas.Client) !void {
    var target = try resolveTarget(allocator, client, opts, cwd, true);
    defer goal_core.freeTarget(allocator, target);
    if (opts.dry_run) return emitTarget(allocator, opts, target, if (target.would_create_thread) "thread/start + thread/goal/set" else "thread/goal/set");
    if (target.thread_id == null and target.would_create_thread) {
        target.thread_id = try createThread(allocator, client, cwd);
        target.created_thread = true;
        target.would_create_thread = false;
        target.selected_by = "created";
    }
    try requestGoalSet(allocator, client, target.thread_id.?, opts);
    const goal = try requestGoalGet(allocator, client, target.thread_id.?);
    defer goal_core.freeGoalEnvelope(allocator, goal);
    try emitGoal(allocator, opts, target, goal, "ok", 0);
}

fn runClear(allocator: std.mem.Allocator, opts: ParsedArgs, cwd: []const u8, client: *cas.Client) !void {
    const target = try resolveTarget(allocator, client, opts, cwd, false);
    defer goal_core.freeTarget(allocator, target);
    if (opts.dry_run) return emitTarget(allocator, opts, target, "thread/goal/clear");
    _ = try requestGoalGet(allocator, client, target.thread_id.?);
    const clear_json = try requestGoalClear(allocator, client, target.thread_id.?);
    defer allocator.free(clear_json);
    try emitClear(allocator, opts, target, clear_json);
}

fn runStatus(allocator: std.mem.Allocator, opts: ParsedArgs, cwd: []const u8, client: *cas.Client) !void {
    const target = try resolveTarget(allocator, client, opts, cwd, false);
    defer goal_core.freeTarget(allocator, target);
    if (opts.dry_run) return emitTarget(allocator, opts, target, "thread/goal/set");
    const before = try requestGoalGet(allocator, client, target.thread_id.?);
    defer goal_core.freeGoalEnvelope(allocator, before);
    if (std.mem.eql(u8, before.goal_json, "null")) try fail(allocator, opts, "goalNotFound", "status requires an existing goal", 3);
    try requestGoalSet(allocator, client, target.thread_id.?, opts);
    const goal = try requestGoalGet(allocator, client, target.thread_id.?);
    defer goal_core.freeGoalEnvelope(allocator, goal);
    try emitGoal(allocator, opts, target, goal, "ok", 0);
}

fn runWait(allocator: std.mem.Allocator, opts: ParsedArgs, cwd: []const u8, client: *cas.Client) !void {
    const target = try resolveTarget(allocator, client, opts, cwd, false);
    defer goal_core.freeTarget(allocator, target);
    if (opts.dry_run) return emitTarget(allocator, opts, target, "thread/resume + thread/goal/get");
    try resumeThread(allocator, client, target.thread_id.?);
    try waitForGoal(allocator, opts, client, target);
}

fn startGoalClient(allocator: std.mem.Allocator, opts: ParsedArgs, cwd: []const u8, io: std.Io) !GoalClient {
    const resolved_codex_path = cas.resolveExecutableAlloc(allocator, opts.codex_path) catch opts.codex_path;
    defer if (resolved_codex_path.ptr != opts.codex_path.ptr) allocator.free(resolved_codex_path);

    var managed_server: ?cas_websocket.ManagedServer = cas_websocket.startManagedLoopbackServer(allocator, cwd, resolved_codex_path, opts.hook_policy, io) catch null;
    const client = if (managed_server) |server|
        cas.Client.start(allocator, clientOptions(opts, cwd, io, resolved_codex_path, server.listen_url)) catch blk: {
            var owned_server = server;
            defer owned_server.deinit(allocator);
            owned_server.kill();
            managed_server = null;
            break :blk try cas.Client.start(allocator, clientOptions(opts, cwd, io, resolved_codex_path, null));
        }
    else
        try cas.Client.start(allocator, clientOptions(opts, cwd, io, resolved_codex_path, null));

    return .{ .client = client, .managed_server = managed_server };
}

fn clientOptions(opts: ParsedArgs, cwd: []const u8, io: std.Io, codex_path: []const u8, websocket_url: ?[]const u8) cas.ClientOptions {
    return .{
        .cwd = cwd,
        .io = io,
        .codex_path = codex_path,
        .client_name = "cas-goal",
        .client_title = "CAS Goal",
        .client_version = Version,
        .server_request_timeout_ms = opts.server_request_timeout_ms,
        .read_only = opts.read_only,
        .hook_policy = opts.hook_policy,
        .websocket_url = websocket_url,
    };
}

fn resolveTarget(allocator: std.mem.Allocator, client: *cas.Client, opts: ParsedArgs, cwd: []const u8, allow_create: bool) !SelectedTarget {
    if (opts.thread_id) |thread_id| {
        try ensureGoalReadable(allocator, client, thread_id);
        return .{ .thread_id = try allocator.dupe(u8, thread_id), .selected_by = "threadId" };
    }

    if (opts.latest) {
        const latest = try latestThreadTarget(allocator, client, cwd);
        if (latest.thread_id != null) return latest;
        if (allow_create) return .{ .thread_id = null, .selected_by = "create", .would_create_thread = true };
        return error.ThreadNotFound;
    }

    if (allow_create) return .{ .thread_id = null, .selected_by = "create", .would_create_thread = true };
    return error.MissingTargetSelector;
}

fn latestThreadTarget(allocator: std.mem.Allocator, client: *cas.Client, cwd: []const u8) !SelectedTarget {
    const params = try goal_core.buildThreadListParamsJson(allocator, cwd);
    defer allocator.free(params);
    const result_json = try client.requestJson("thread/list", params);
    defer allocator.free(result_json);
    return goal_core.parseLatestThreadTarget(allocator, result_json);
}

fn createThread(allocator: std.mem.Allocator, client: *cas.Client, cwd: []const u8) ![]u8 {
    const quoted_cwd = try goal_core.jsonStringAlloc(allocator, cwd);
    defer allocator.free(quoted_cwd);
    const params = try std.fmt.allocPrint(allocator, "{{\"cwd\":{s},\"experimentalRawEvents\":false}}", .{quoted_cwd});
    defer allocator.free(params);
    const result_json = try client.requestJson("thread/start", params);
    defer allocator.free(result_json);
    return goal_core.extractStartedThreadIdAlloc(allocator, result_json);
}

fn ensureGoalReadable(allocator: std.mem.Allocator, client: *cas.Client, thread_id: []const u8) !void {
    const result_json = try requestRawGoalGet(allocator, client, thread_id);
    allocator.free(result_json);
}

fn requestRawGoalGet(allocator: std.mem.Allocator, client: *cas.Client, thread_id: []const u8) ![]u8 {
    const params = try goal_core.buildThreadIdParamsJson(allocator, thread_id);
    defer allocator.free(params);
    return client.requestJson("thread/goal/get", params);
}

fn requestGoalGet(allocator: std.mem.Allocator, client: *cas.Client, thread_id: []const u8) !GoalEnvelope {
    const result_json = try requestRawGoalGet(allocator, client, thread_id);
    defer allocator.free(result_json);
    return goal_core.parseGoalEnvelope(allocator, result_json);
}

fn requestGoalSet(allocator: std.mem.Allocator, client: *cas.Client, thread_id: []const u8, opts: ParsedArgs) !void {
    const params = try goal_core.buildGoalSetParamsJson(allocator, thread_id, opts);
    defer allocator.free(params);
    const result_json = try client.requestJson("thread/goal/set", params);
    allocator.free(result_json);
}

fn requestGoalClear(allocator: std.mem.Allocator, client: *cas.Client, thread_id: []const u8) ![]u8 {
    const params = try goal_core.buildThreadIdParamsJson(allocator, thread_id);
    defer allocator.free(params);
    return client.requestJson("thread/goal/clear", params);
}

fn resumeThread(allocator: std.mem.Allocator, client: *cas.Client, thread_id: []const u8) !void {
    const params = try goal_core.buildThreadIdParamsJson(allocator, thread_id);
    defer allocator.free(params);
    const result_json = try client.requestJson("thread/resume", params);
    allocator.free(result_json);
}

fn waitForGoal(allocator: std.mem.Allocator, opts: ParsedArgs, client: *cas.Client, target: SelectedTarget) !void {
    const started_ms = millisNow();
    while (true) {
        const goal = try requestGoalGet(allocator, client, target.thread_id.?);
        defer goal_core.freeGoalEnvelope(allocator, goal);
        const status = goal.status orelse {
            try emitGoal(allocator, opts, target, goal, "goalCleared", 3);
            std.process.exit(3);
        };
        if (!std.mem.eql(u8, status, "active")) {
            const exit_code: u8 = if (std.mem.eql(u8, status, "complete")) 0 else 3;
            try emitGoal(allocator, opts, target, goal, status, exit_code);
            std.process.exit(exit_code);
        }
        if (millisNow() - started_ms >= opts.timeout_ms) try fail(allocator, opts, "timeout", "wait timed out before terminal goal status", 124);
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(opts.poll_ms), .awake) catch {};
    }
}

fn emitTarget(allocator: std.mem.Allocator, opts: ParsedArgs, target: SelectedTarget, request_method: ?[]const u8) !void {
    const thread_id_json = if (target.thread_id) |id| try goal_core.jsonStringAlloc(allocator, id) else try allocator.dupe(u8, "null");
    defer allocator.free(thread_id_json);
    const selected_by_json = try goal_core.jsonStringAlloc(allocator, target.selected_by);
    defer allocator.free(selected_by_json);
    const method_json = if (request_method) |method| try goal_core.jsonStringAlloc(allocator, method) else try allocator.dupe(u8, "null");
    defer allocator.free(method_json);
    const output = try std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"command\":\"{s}\",\"dryRun\":{},\"threadId\":{s},\"selectedBy\":{s},\"createdThread\":{},\"wouldCreateThread\":{},\"requestMethod\":{s}}}\n",
        .{ opts.command.text(), opts.dry_run, thread_id_json, selected_by_json, target.created_thread, target.would_create_thread, method_json },
    );
    defer allocator.free(output);
    try writeOutput(output);
}

fn emitGoal(allocator: std.mem.Allocator, opts: ParsedArgs, target: SelectedTarget, goal: GoalEnvelope, exit_reason: []const u8, exit_code: u8) !void {
    const thread_id_json = try goal_core.jsonStringAlloc(allocator, target.thread_id.?);
    defer allocator.free(thread_id_json);
    const selected_by_json = try goal_core.jsonStringAlloc(allocator, target.selected_by);
    defer allocator.free(selected_by_json);
    const exit_reason_json = try goal_core.jsonStringAlloc(allocator, exit_reason);
    defer allocator.free(exit_reason_json);
    const status_json = if (goal.status) |status| try goal_core.jsonStringAlloc(allocator, status) else try allocator.dupe(u8, "null");
    defer allocator.free(status_json);
    const output = try std.fmt.allocPrint(
        allocator,
        "{{\"ok\":{},\"command\":\"{s}\",\"threadId\":{s},\"selectedBy\":{s},\"createdThread\":{},\"status\":{s},\"exitReason\":{s},\"goal\":{s}}}\n",
        .{ exit_code == 0, opts.command.text(), thread_id_json, selected_by_json, target.created_thread, status_json, exit_reason_json, goal.goal_json },
    );
    defer allocator.free(output);
    try writeOutput(output);
}

fn emitClear(allocator: std.mem.Allocator, opts: ParsedArgs, target: SelectedTarget, clear_json: []const u8) !void {
    const cleared = goal_core.parseCleared(allocator, clear_json) catch false;
    const thread_id_json = try goal_core.jsonStringAlloc(allocator, target.thread_id.?);
    defer allocator.free(thread_id_json);
    const selected_by_json = try goal_core.jsonStringAlloc(allocator, target.selected_by);
    defer allocator.free(selected_by_json);
    const output = try std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"command\":\"{s}\",\"threadId\":{s},\"selectedBy\":{s},\"cleared\":{},\"exitReason\":\"ok\"}}\n",
        .{ opts.command.text(), thread_id_json, selected_by_json, cleared },
    );
    defer allocator.free(output);
    try writeOutput(output);
}

fn fail(allocator: std.mem.Allocator, opts: ParsedArgs, code: []const u8, detail: ?[]const u8, exit_code: u8) !noreturn {
    if (opts.json) {
        const code_json = try goal_core.jsonStringAlloc(allocator, code);
        defer allocator.free(code_json);
        const detail_json = if (detail) |raw| try goal_core.jsonStringAlloc(allocator, raw) else try allocator.dupe(u8, "null");
        defer allocator.free(detail_json);
        const output = try std.fmt.allocPrint(
            allocator,
            "{{\"ok\":false,\"command\":\"{s}\",\"exitReason\":{s},\"detail\":{s}}}\n",
            .{ opts.command.text(), code_json, detail_json },
        );
        defer allocator.free(output);
        try writeOutput(output);
    } else {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        if (detail) |raw| try stderr_writer.interface.print("cas_goal {s}: {s}: {s}\n", .{ opts.command.text(), code, raw }) else try stderr_writer.interface.print("cas_goal {s}: {s}\n", .{ opts.command.text(), code });
    }
    std.process.exit(exit_code);
}

fn classifyError(detail: []const u8) []const u8 {
    if (std.mem.indexOf(u8, detail, "ephemeral") != null) return "ephemeralThread";
    if (std.mem.indexOf(u8, detail, "goals feature is disabled") != null) return "goalsDisabled";
    if (std.mem.indexOf(u8, detail, "not found") != null) return "threadNotFound";
    if (std.mem.indexOf(u8, detail, "AmbiguousTarget") != null) return "ambiguousTarget";
    return "requestFailed";
}

fn writeOutput(output: []const u8) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll(output);
}

fn printVersion() !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try core_cli.printVersion(&stdout_writer.interface, Version);
}

fn printHelp() !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try core_cli.printHelpSurface(&stdout_writer.interface, HelpSurface, Version);
}

fn millisNow() i64 {
    return @intCast(@divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000));
}

test {
    _ = goal_core;
}
