const app_meta = @import("app_meta");
const cas = @import("cas_proxy_client.zig");
const core_cli = @import("core_cli");
const std = @import("std");
const websocket = @import("cas_websocket_transport.zig");

const launch = cas.app_server_launch;

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
    \\  --codex-path PATH                Codex executable for CAS-owned launches (default: codex).
    \\  --app-server-transport MODE      auto|stdio|managed-ws|ws|unix (default: auto).
    \\  --app-server-endpoint ENDPOINT   Required for ws; optional unix:// path for unix.
    \\  --code-mode-host WS_URL          Outbound Code Mode host (CAS-owned launches only).
    \\  --thread-id THREAD_ID            Existing thread id to reuse (optional).
    \\  --request-timeout-ms N           Timeout per request (accepted for parity).
    \\  --opt-out-notification-method M  Suppress notification method (repeatable).
    \\  --hooks MODE                     Hook policy: inherit|off|require-observed (default: inherit).
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
    codex_path: []const u8 = "codex",
    requested_transport: launch.RequestedTransport = .auto,
    transport_endpoint: ?[]const u8 = null,
    code_mode_host: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    request_timeout_ms: u32 = 15_000,
    opt_out_methods: []const []const u8 = &.{},
    hook_policy: cas.hooks.HookPolicy = .inherit,
    json: bool = false,
    show_help: bool = false,
    show_version: bool = false,
};

const AcquiredClient = struct {
    allocator: std.mem.Allocator,
    client: cas.Client,
    managed_server: ?websocket.ManagedServer = null,
    selected_transport: launch.RequestedTransport,
    endpoint_identity: []u8,
    codex_path_identity: ?[]u8 = null,

    fn deinit(self: *AcquiredClient) void {
        self.client.close();
        self.client.deinit();
        if (self.managed_server) |*server| server.deinit(self.allocator);
        if (self.codex_path_identity) |owned| self.allocator.free(owned);
        self.allocator.free(self.endpoint_identity);
    }
};

const CodeModeHostReport = struct {
    endpoint: []const u8,
    digest: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    const parsed = parseArgs(allocator, argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    defer allocator.free(parsed.opt_out_methods);

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

    const validated_transport = launch.validateTransport(
        parsed.requested_transport,
        parsed.transport_endpoint,
    ) catch |err| {
        core_cli.exitUsageFailure(
            HelpSurface,
            Version,
            @errorName(err),
            "--app-server-transport/--app-server-endpoint",
        );
    };
    var code_mode_host = if (parsed.code_mode_host) |raw|
        launch.CodeModeHost.init(allocator, raw) catch |err| {
            core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), "--code-mode-host");
        }
    else
        null;
    defer if (code_mode_host) |*host| host.deinit();

    var acquired = acquireClient(
        allocator,
        init.io,
        cwd,
        parsed,
        validated_transport,
        if (code_mode_host) |*host| host else null,
    ) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), "app-server transport");
    };
    defer acquired.deinit();

    var checks: std.ArrayList(CheckResult) = .empty;
    defer checks.deinit(allocator);

    const hook_log_path = if (parsed.hook_policy.shouldCaptureNotifications())
        try cas.hooks.defaultHookLogPathAlloc(allocator, "cas-smoke-check")
    else
        null;
    defer if (hook_log_path) |path| allocator.free(path);

    var captured_notifications: std.ArrayList([]u8) = .empty;
    defer {
        for (captured_notifications.items) |line| allocator.free(line);
        captured_notifications.deinit(allocator);
    }
    const notification_capture: ?*std.ArrayList([]u8) = if (parsed.hook_policy.shouldCaptureNotifications()) &captured_notifications else null;

    var thread_id = parsed.thread_id;
    const client = &acquired.client;

    // Check 1: experimentalFeature/list succeeds.
    {
        const maybe_result = client.requestJsonCaptureNotifications("experimentalFeature/list", "{\"cursor\":null,\"limit\":1}", notification_capture) catch |err| blk: {
            try checks.append(allocator, .{
                .name = "experimentalFeature/list",
                .ok = false,
                .detail = try errorSummary(allocator, client, err),
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
                const start_json = client.requestJsonCaptureNotifications("thread/start", start_params, notification_capture) catch |err| {
                    const summary = try errorSummary(allocator, client, err);
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

            const resume_json = client.requestJsonCaptureNotifications("thread/resume", resume_params, notification_capture) catch |err| {
                const summary = try errorSummary(allocator, client, err);
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

            const turn_start_json = client.requestJsonCaptureNotifications("turn/start", turn_start_params, notification_capture) catch |err| blk: {
                const summary = try errorSummary(allocator, client, err);
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

        if (parsed.hook_policy == .require_observed) {
            if (notification_capture) |captured| {
                if (thread_id != null) {
                    const drain_params = try stringifyAnyAlloc(allocator, .{
                        .threadId = thread_id.?,
                        .includeTurns = false,
                    });
                    defer allocator.free(drain_params);
                    var attempts: usize = 0;
                    while (attempts < 12 and !hasCapturedCompletedHookNotification(allocator, captured.items)) : (attempts += 1) {
                        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromSeconds(1), .awake) catch {};
                        const drain_json = client.requestJsonCaptureNotifications("thread/read", drain_params, captured) catch null;
                        if (drain_json) |json| allocator.free(json);
                    }
                }
            }
        }

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

            const maybe_interrupt_json = client.requestJsonCaptureNotifications("turn/interrupt", interrupt_params, notification_capture) catch |err| blk: {
                const summary = try errorSummary(allocator, client, err);
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

            const maybe_steer_json = client.requestJsonCaptureNotifications("turn/steer", steer_params, notification_capture) catch |err| blk: {
                const summary = try errorSummary(allocator, client, err);
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
    var hook_accumulator = cas.hooks.HookAccumulator.init(parsed.hook_policy, hook_log_path);
    try hook_accumulator.absorbLines(allocator, captured_notifications.items);
    const hook_summary = hook_accumulator.summary();
    if (hook_summary.failureCode != null) overall_ok = false;

    var code_mode_digest: [64]u8 = undefined;
    const code_mode_report: ?CodeModeHostReport = if (code_mode_host) |*host| .{
        .endpoint = host.redacted_origin,
        .digest = host.digestHex(&code_mode_digest),
    } else null;

    if (parsed.json) {
        const report = .{
            .check = "cas-smoke-check",
            .cwd = cwd,
            .codexPath = acquired.codex_path_identity,
            .transport = .{
                .selected = acquired.selected_transport.asString(),
                .endpoint = acquired.endpoint_identity,
            },
            .codeModeHost = code_mode_report,
            .threadId = thread_id,
            .ok = overall_ok,
            .hookSummary = hook_summary,
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
        try stdout.print(
            "codexPath: {s}\n",
            .{acquired.codex_path_identity orelse "external-endpoint"},
        );
        try stdout.print("transport: {s} ({s})\n", .{
            acquired.selected_transport.asString(),
            acquired.endpoint_identity,
        });
        if (code_mode_report) |identity| {
            try stdout.print(
                "codeModeHost: {s} (sha256:{s})\n",
                .{ identity.endpoint, identity.digest },
            );
        }
        try stdout.print("threadId: {s}\n", .{thread_id orelse "n/a"});
        try stdout.print("overall: {s}\n", .{if (overall_ok) "pass" else "fail"});
        try stdout.print("hooks: policy={s} observed={any} failure={s}\n", .{
            hook_summary.policy,
            hook_summary.observed,
            hook_summary.failureCode orelse "none",
        });
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
    errdefer methods.deinit(allocator);

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
        if (std.mem.eql(u8, arg, "--codex-path")) {
            out.codex_path = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--app-server-transport")) {
            out.requested_transport = launch.RequestedTransport.parse(value) orelse
                return error.InvalidAppServerTransport;
            continue;
        }
        if (std.mem.eql(u8, arg, "--app-server-endpoint")) {
            out.transport_endpoint = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--code-mode-host")) {
            out.code_mode_host = value;
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
        if (std.mem.eql(u8, arg, "--hooks")) {
            out.hook_policy = cas.hooks.HookPolicy.parse(value) orelse return error.InvalidHooksPolicy;
            continue;
        }
        return error.UnknownArg;
    }

    out.opt_out_methods = try methods.toOwnedSlice(allocator);
    return out;
}

fn baseClientOptions(
    io: std.Io,
    cwd: []const u8,
    parsed: ParsedArgs,
) cas.ClientOptions {
    return .{
        .cwd = cwd,
        .io = io,
        .opt_out_notification_methods = parsed.opt_out_methods,
        .hook_policy = parsed.hook_policy,
        .websocket_connect_timeout_ms = parsed.request_timeout_ms,
    };
}

fn acquireClient(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    parsed: ParsedArgs,
    transport: launch.ValidatedTransport,
    code_mode_host: ?*const launch.CodeModeHost,
) !AcquiredClient {
    return switch (transport) {
        .stdio => acquireStdio(allocator, io, cwd, parsed, code_mode_host),
        .managed_websocket => acquireManaged(allocator, io, cwd, parsed, code_mode_host),
        .explicit_websocket => |url| blk: {
            if (code_mode_host != null) return error.CodeModeHostRequiresManagedLaunch;
            var options = baseClientOptions(io, cwd, parsed);
            options.transport = .{ .explicit_websocket = url };
            const endpoint_identity = try allocator.dupe(u8, url);
            errdefer allocator.free(endpoint_identity);
            break :blk .{
                .allocator = allocator,
                .client = try cas.Client.start(allocator, options),
                .selected_transport = .explicit_websocket,
                .endpoint_identity = endpoint_identity,
            };
        },
        .unix_socket => |maybe_path| blk: {
            if (code_mode_host != null) return error.CodeModeHostRequiresManagedLaunch;
            const path = if (maybe_path) |path|
                try launch.resolveUnixPathAlloc(allocator, cwd, path)
            else
                try launch.defaultUnixPathAlloc(allocator);
            defer allocator.free(path);
            const endpoint_identity = try std.fmt.allocPrint(allocator, "unix://{s}", .{path});
            errdefer allocator.free(endpoint_identity);
            var options = baseClientOptions(io, cwd, parsed);
            options.transport = .{ .unix_socket = path };
            break :blk .{
                .allocator = allocator,
                .client = try cas.Client.start(allocator, options),
                .selected_transport = .unix_socket,
                .endpoint_identity = endpoint_identity,
            };
        },
        .auto => blk: {
            const managed_server = startManaged(
                allocator,
                io,
                cwd,
                parsed,
                code_mode_host,
            ) catch |err| {
                if (!launch.autoMayFallback(
                    .auto,
                    .managed_websocket,
                    .stdio,
                    .before_first_rpc,
                    true,
                )) return err;
                break :blk acquireStdio(
                    allocator,
                    io,
                    cwd,
                    parsed,
                    code_mode_host,
                );
            };
            // From this point Client.start performs initialize, so a failure is
            // observable protocol work and must not trigger a transport retry.
            break :blk connectManaged(allocator, io, cwd, parsed, managed_server);
        },
    };
}

fn acquireStdio(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    parsed: ParsedArgs,
    code_mode_host: ?*const launch.CodeModeHost,
) !AcquiredClient {
    const resolved_codex_path = try cas.resolveExecutableAlloc(allocator, parsed.codex_path);
    defer allocator.free(resolved_codex_path);
    const endpoint_identity = try allocator.dupe(u8, "stdio://");
    errdefer allocator.free(endpoint_identity);
    const codex_path_identity = try allocator.dupe(u8, resolved_codex_path);
    errdefer allocator.free(codex_path_identity);
    var options = baseClientOptions(io, cwd, parsed);
    options.codex_path = resolved_codex_path;
    options.transport = .stdio;
    options.code_mode_host = code_mode_host;
    return .{
        .allocator = allocator,
        .client = try cas.Client.start(allocator, options),
        .selected_transport = .stdio,
        .endpoint_identity = endpoint_identity,
        .codex_path_identity = codex_path_identity,
    };
}

fn acquireManaged(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    parsed: ParsedArgs,
    code_mode_host: ?*const launch.CodeModeHost,
) !AcquiredClient {
    const server = try startManaged(allocator, io, cwd, parsed, code_mode_host);
    return connectManaged(allocator, io, cwd, parsed, server);
}

fn startManaged(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    parsed: ParsedArgs,
    code_mode_host: ?*const launch.CodeModeHost,
) !websocket.ManagedServer {
    const resolved_codex_path = try cas.resolveExecutableAlloc(allocator, parsed.codex_path);
    defer allocator.free(resolved_codex_path);
    return if (code_mode_host) |host|
        websocket.startManagedLoopbackServerWithCodeModeHost(
            allocator,
            cwd,
            resolved_codex_path,
            parsed.hook_policy,
            host,
            io,
        )
    else
        websocket.startManagedLoopbackServer(
            allocator,
            cwd,
            resolved_codex_path,
            parsed.hook_policy,
            io,
        );
}

fn connectManaged(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    parsed: ParsedArgs,
    server_value: websocket.ManagedServer,
) !AcquiredClient {
    var server = server_value;
    errdefer server.deinit(allocator);
    const endpoint_identity = try allocator.dupe(u8, server.listen_url);
    errdefer allocator.free(endpoint_identity);
    const resolved_codex_path = try cas.resolveExecutableAlloc(allocator, parsed.codex_path);
    defer allocator.free(resolved_codex_path);
    const codex_path_identity = try allocator.dupe(u8, resolved_codex_path);
    errdefer allocator.free(codex_path_identity);
    var options = baseClientOptions(io, cwd, parsed);
    options.websocket_url = server.listen_url;
    return .{
        .allocator = allocator,
        .client = try cas.Client.start(allocator, options),
        .managed_server = server,
        .selected_transport = .managed_websocket,
        .endpoint_identity = endpoint_identity,
        .codex_path_identity = codex_path_identity,
    };
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

fn hasCapturedCompletedHookNotification(allocator: std.mem.Allocator, lines: []const []u8) bool {
    for (lines) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        if (cas.stringField(root, "method")) |method| {
            if (std.mem.eql(u8, method, "hook/completed")) return true;
        }
    }
    return false;
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
        "--codex-path",
        "/opt/codex-0.146.0",
        "--app-server-transport",
        "unix",
        "--app-server-endpoint",
        "unix:///tmp/cas.sock",
        "--code-mode-host",
        "wss://example.com/code?token=redacted",
        "--thread-id",
        "thr_123",
        "--request-timeout-ms",
        "45000",
        "--opt-out-notification-method",
        "thread/item/stream",
        "--hooks",
        "require-observed",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(parsed.opt_out_methods);

    try std.testing.expectEqual(@as(?[]const u8, "/tmp/repo"), parsed.cwd);
    try std.testing.expectEqualStrings("/opt/codex-0.146.0", parsed.codex_path);
    try std.testing.expectEqual(launch.RequestedTransport.unix_socket, parsed.requested_transport);
    try std.testing.expectEqualStrings("unix:///tmp/cas.sock", parsed.transport_endpoint.?);
    try std.testing.expectEqualStrings(
        "wss://example.com/code?token=redacted",
        parsed.code_mode_host.?,
    );
    try std.testing.expectEqual(@as(?[]const u8, "thr_123"), parsed.thread_id);
    try std.testing.expectEqual(@as(u32, 45_000), parsed.request_timeout_ms);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(@as(usize, 1), parsed.opt_out_methods.len);
    try std.testing.expectEqualStrings("thread/item/stream", parsed.opt_out_methods[0]);
    try std.testing.expectEqual(cas.hooks.HookPolicy.require_observed, parsed.hook_policy);
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
