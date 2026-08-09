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
    \\  --multi-agent-mode MODE             Removed: use Codex reasoning effort and canonical agent config.
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
    \\  --elicitation-response-json JSON    Exact full result for form/openai/form elicitation.
    \\  --dynamic-tool-response-json JSON   Exact result payload for item/tool/call.
    \\  --auth-refresh-response-file PATH   Owner-only JSON file, or - for stdin; never logged.
    \\  --attestation-response-file PATH    Owner-only JSON file, or - for stdin; never logged.
    \\  --experimental-api BOOL             Initialize experimentalApi (default: true).
    \\  --init-capabilities-json JSON       Bounded additive initialize capability object.
    \\  --codex-path PATH                   Codex executable path or name (default: codex).
    \\  --app-server-transport MODE         auto|stdio|managed-ws|ws|unix (default: auto).
    \\  --app-server-endpoint ENDPOINT      Required by ws; optional unix:// path for unix.
    \\  --code-mode-host URL                Outbound ws:// loopback or wss:// remote host.
    \\  --read-only                         Decline exec + file approvals.
    \\  --opt-out-notification-method M     Suppress notification method (repeatable).
    \\  --hooks MODE                        Hook policy: inherit|off|require-observed (default: inherit).
    \\  --client-prefix NAME                Instance client prefix (default: cas-instance).
    \\  --sample N                          Sample count in output (default: 3).
    \\  --raw-sample                        Include raw app-server result JSON for sampled responses.
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
    multi_agent_mode: ?cas.MultiAgentMode = null,
    state_file_dir: ?[]const u8 = null,
    request_timeout_ms: u32 = 30_000,
    server_request_timeout_ms: ?u32 = null,
    exec_approval: ?[]const u8 = null,
    file_approval: ?[]const u8 = null,
    permissions_approval: ?[]const u8 = null,
    request_user_input_response_json: ?[]const u8 = null,
    elicitation_action: ?[]const u8 = null,
    elicitation_content_json: ?[]const u8 = null,
    elicitation_response_json: ?[]const u8 = null,
    dynamic_tool_response_json: ?[]const u8 = null,
    auth_refresh_response_source: ?[]const u8 = null,
    attestation_response_source: ?[]const u8 = null,
    experimental_api: bool = true,
    additional_initialize_capabilities_json: ?[]const u8 = null,
    codex_path: []const u8 = "codex",
    requested_transport: cas.app_server_launch.RequestedTransport = .auto,
    transport_endpoint: ?[]const u8 = null,
    code_mode_host: ?[]const u8 = null,
    read_only: bool = false,
    opt_out_methods: []const []const u8 = &.{},
    hook_policy: cas.hooks.HookPolicy = .inherit,
    client_prefix: []const u8 = "cas-instance",
    sample: usize = 3,
    raw_sample: bool = false,
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
    raw_result: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

const InstanceSlot = struct {
    client: cas.Client,
    transport: []const u8,
    managed_server: ?cas_websocket.ManagedServer = null,
};

const CodeModeIdentity = struct {
    endpoint: []const u8,
    digest: []const u8,
};

fn clientOptions(
    opts: ParsedArgs,
    cwd: []const u8,
    codex_path: []const u8,
    client_name: []const u8,
    state_file: ?[]const u8,
    auth_refresh_response: ?[]const u8,
    attestation_response: ?[]const u8,
    code_mode_host: ?*const cas.app_server_launch.CodeModeHost,
) cas.ClientOptions {
    return .{
        .cwd = cwd,
        .state_file = state_file,
        .codex_path = codex_path,
        .client_name = client_name,
        .server_request_timeout_ms = opts.server_request_timeout_ms,
        .exec_approval = opts.exec_approval,
        .file_approval = opts.file_approval,
        .permissions_approval = opts.permissions_approval,
        .request_user_input_response_json = opts.request_user_input_response_json,
        .elicitation_action = opts.elicitation_action,
        .elicitation_content_json = opts.elicitation_content_json,
        .elicitation_response_json = opts.elicitation_response_json,
        .dynamic_tool_response_json = opts.dynamic_tool_response_json,
        .auth_refresh_response_json = auth_refresh_response,
        .attestation_response_json = attestation_response,
        .read_only = opts.read_only,
        .experimental_api = opts.experimental_api,
        .opt_out_notification_methods = opts.opt_out_methods,
        .additional_initialize_capabilities_json = opts.additional_initialize_capabilities_json,
        .hook_policy = opts.hook_policy,
        .code_mode_host = code_mode_host,
    };
}

fn startInstance(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: ParsedArgs,
    cwd: []const u8,
    codex_path: []const u8,
    selected_transport: cas.app_server_launch.ValidatedTransport,
    state_file: ?[]const u8,
    client_name: []const u8,
    auth_refresh_response: ?[]const u8,
    attestation_response: ?[]const u8,
    code_mode_host: ?*const cas.app_server_launch.CodeModeHost,
) !InstanceSlot {
    switch (selected_transport) {
        .auto => {
            var server = startManagedServer(
                allocator,
                io,
                cwd,
                codex_path,
                opts.hook_policy,
                code_mode_host,
            ) catch |err| {
                if (!cas.app_server_launch.autoMayFallback(
                    .auto,
                    .managed_websocket,
                    .stdio,
                    .before_first_rpc,
                    true,
                )) return err;
                var direct = clientOptions(
                    opts,
                    cwd,
                    codex_path,
                    client_name,
                    state_file,
                    auth_refresh_response,
                    attestation_response,
                    code_mode_host,
                );
                direct.io = io;
                direct.transport = .stdio;
                return .{ .client = try cas.Client.start(allocator, direct), .transport = "stdio" };
            };
            return finishManagedStart(
                allocator,
                io,
                opts,
                cwd,
                codex_path,
                state_file,
                client_name,
                auth_refresh_response,
                attestation_response,
                &server,
            );
        },
        .managed_websocket => {
            var server = try startManagedServer(
                allocator,
                io,
                cwd,
                codex_path,
                opts.hook_policy,
                code_mode_host,
            );
            return finishManagedStart(
                allocator,
                io,
                opts,
                cwd,
                codex_path,
                state_file,
                client_name,
                auth_refresh_response,
                attestation_response,
                &server,
            );
        },
        .stdio, .explicit_websocket, .unix_socket => {
            var direct = clientOptions(
                opts,
                cwd,
                codex_path,
                client_name,
                state_file,
                auth_refresh_response,
                attestation_response,
                code_mode_host,
            );
            direct.io = io;
            direct.transport = selected_transport;
            const identity: []const u8 = switch (selected_transport) {
                .stdio => "stdio",
                .explicit_websocket => "websocket",
                .unix_socket => "unix_socket",
                else => unreachable,
            };
            return .{ .client = try cas.Client.start(allocator, direct), .transport = identity };
        },
    }
}

fn startManagedServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    codex_path: []const u8,
    hook_policy: cas.hooks.HookPolicy,
    code_mode_host: ?*const cas.app_server_launch.CodeModeHost,
) !cas_websocket.ManagedServer {
    if (code_mode_host) |host| {
        return cas_websocket.startManagedLoopbackServerWithCodeModeHost(
            allocator,
            cwd,
            codex_path,
            hook_policy,
            host,
            io,
        );
    }
    return cas_websocket.startManagedLoopbackServer(allocator, cwd, codex_path, hook_policy, io);
}

fn finishManagedStart(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: ParsedArgs,
    cwd: []const u8,
    codex_path: []const u8,
    state_file: ?[]const u8,
    client_name: []const u8,
    auth_refresh_response: ?[]const u8,
    attestation_response: ?[]const u8,
    server: *cas_websocket.ManagedServer,
) !InstanceSlot {
    errdefer {
        server.kill();
        server.deinit(allocator);
    }
    var socket = clientOptions(
        opts,
        cwd,
        codex_path,
        client_name,
        state_file,
        auth_refresh_response,
        attestation_response,
        null,
    );
    socket.io = io;
    socket.websocket_url = server.listen_url;
    return .{
        .client = try cas.Client.start(allocator, socket),
        .transport = "managed_websocket",
        .managed_server = server.*,
    };
}

fn loadSecretCarrierAlloc(allocator: std.mem.Allocator, io: std.Io, source: []const u8) ![]u8 {
    if (std.mem.eql(u8, source, "-")) {
        var reader = std.Io.File.stdin().reader(io, &.{});
        return reader.interface.allocRemaining(
            allocator,
            .limited(cas.max_server_request_carrier_bytes),
        );
    }
    var file = if (std.fs.path.isAbsolute(source))
        try std.Io.Dir.openFileAbsolute(
            io,
            source,
            .{ .follow_symlinks = false, .allow_directory = false },
        )
    else
        try std.Io.Dir.cwd().openFile(
            io,
            source,
            .{ .follow_symlinks = false, .allow_directory = false },
        );
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidSecretCarrierFile;
    if (comptime std.posix.mode_t != u0) {
        const mode = stat.permissions.toMode();
        if (mode & 0o400 == 0 or mode & 0o077 != 0) return error.InsecureSecretCarrierPermissions;
    }
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(
        allocator,
        .limited(cas.max_server_request_carrier_bytes),
    );
}

fn wipeSecretCarrier(allocator: std.mem.Allocator, carrier: ?[]u8) void {
    if (carrier) |owned| {
        @memset(owned, 0);
        allocator.free(owned);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    const opts = parseArgs(allocator, argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), usageDetailForParseError(err));
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
    defer allocator.free(opts.opt_out_methods);

    if (opts.instances > 1 and opts.state_file_dir == null) {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.writeAll("Note: by default, state is derived from --cwd, so parallel instances may share it. Use --state-file-dir for per-instance state isolation.\n");
    }

    const params = try buildParamsJson(allocator, opts.method, opts.params_json, opts.params_file);
    defer allocator.free(params);
    const selected_transport = try cas.app_server_launch.validateTransport(
        opts.requested_transport,
        opts.transport_endpoint,
    );
    var code_mode_host: ?cas.app_server_launch.CodeModeHost = if (opts.code_mode_host) |raw|
        try cas.app_server_launch.CodeModeHost.init(allocator, raw)
    else
        null;
    defer if (code_mode_host) |*host| host.deinit();
    const resolved_codex_path = try cas.resolveExecutableAlloc(allocator, opts.codex_path);
    defer allocator.free(resolved_codex_path);
    const auth_refresh_response = if (opts.auth_refresh_response_source) |source|
        try loadSecretCarrierAlloc(allocator, init.io, source)
    else
        null;
    defer wipeSecretCarrier(allocator, auth_refresh_response);
    const attestation_response = if (opts.attestation_response_source) |source|
        try loadSecretCarrierAlloc(allocator, init.io, source)
    else
        null;
    defer wipeSecretCarrier(allocator, attestation_response);

    var validation_options = clientOptions(
        opts,
        cwd,
        resolved_codex_path,
        "cas-instance-validation",
        null,
        auth_refresh_response,
        attestation_response,
        if (code_mode_host) |*host| host else null,
    );
    validation_options.transport = selected_transport;
    try cas.validateClientOptions(allocator, validation_options);
    const hook_log_path = if (opts.hook_policy.shouldCaptureNotifications())
        try cas.hooks.defaultHookLogPathAlloc(allocator, "cas-instance-runner")
    else
        null;
    defer if (hook_log_path) |path| allocator.free(path);

    var captured_notifications: std.ArrayList([]u8) = .empty;
    defer {
        for (captured_notifications.items) |line| allocator.free(line);
        captured_notifications.deinit(allocator);
    }
    const notification_capture: ?*std.ArrayList([]u8) = if (opts.hook_policy.shouldCaptureNotifications()) &captured_notifications else null;

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

        slots[i] = startInstance(
            allocator,
            init.io,
            opts,
            cwd,
            resolved_codex_path,
            selected_transport,
            state_file,
            client_name,
            auth_refresh_response,
            attestation_response,
            if (code_mode_host) |*host| host else null,
        ) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
            try start_failures.append(allocator, .{
                .instance = instance_num,
                .@"error" = msg,
            });
            if (opts.verbose) {
                var stderr_writer = std.Io.File.stderr().writer(
                    std.Io.Threaded.global_single_threaded.io(),
                    &.{},
                );
                const stderr = &stderr_writer.interface;
                try stderr.print("[start:{d}] fail: {s}\n", .{ instance_num, msg });
            }
            continue;
        };
        if (opts.verbose) {
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stderr = &stderr_writer.interface;
            try stderr.print("[start:{d}] ok ({s})\n", .{ instance_num, slots[i].?.transport });
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
            if (slot.managed_server) |*server| {
                server.kill();
                server.deinit(allocator);
            }
            slots[i] = null;
        }

        const result_json = client.requestJsonCaptureNotifications(opts.method, params, notification_capture) catch |err| {
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
            .raw_result = if (opts.raw_sample) try allocator.dupe(u8, result_json) else null,
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
    const managed_websocket_count = countTransport(request_results.items, "managed_websocket");
    const websocket_count = countTransport(request_results.items, "websocket");
    const unix_socket_count = countTransport(request_results.items, "unix_socket");
    const stdio_count = countTransport(request_results.items, "stdio");
    const instances_started = request_results.items.len;
    const sample_results = request_results.items[0..@min(opts.sample, request_results.items.len)];
    var hook_accumulator = cas.hooks.HookAccumulator.init(opts.hook_policy, hook_log_path);
    try hook_accumulator.absorbLines(allocator, captured_notifications.items);
    const hook_summary = hook_accumulator.summary();
    var code_mode_digest_buffer: [64]u8 = undefined;
    const code_mode_identity: ?CodeModeIdentity = if (code_mode_host) |*host| .{
        .endpoint = host.redacted_origin,
        .digest = host.digestHex(&code_mode_digest_buffer),
    } else null;

    const payload = .{
        .demo = "cas-instance-runner",
        .cwd = cwd,
        .state_file_dir = opts.state_file_dir,
        .method = opts.method,
        .params = params,
        .requested_transport = transportName(opts.requested_transport),
        .code_mode_host = code_mode_identity,
        .requestedMultiAgentMode = @as(?[]const u8, null),
        .effectiveMultiAgentMode = @as(?[]const u8, null),
        .multiAgentModeSupport = cas.MultiAgentModeSupport.not_requested.asString(),
        .multiAgentModeMetricEligible = false,
        .instances_requested = opts.instances,
        .instances_started = instances_started,
        .start_failures = start_failures.items,
        .requests_ok = requests_ok,
        .requests_failed = requests_failed,
        .transport_counts = .{
            .managed_websocket = managed_websocket_count,
            .websocket = websocket_count,
            .unix_socket = unix_socket_count,
            .stdio = stdio_count,
        },
        .hookSummary = hook_summary,
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
        try stdout.print(
            "transport counts: managed_websocket={d}, websocket={d}, " ++
                "unix_socket={d}, stdio={d}\n",
            .{
                managed_websocket_count,
                websocket_count,
                unix_socket_count,
                stdio_count,
            },
        );
        try stdout.print("hooks: policy={s} observed={any} failure={s}\n", .{
            hook_summary.policy,
            hook_summary.observed,
            hook_summary.failureCode orelse "none",
        });
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

    const ok = requests_failed == 0 and start_failures.items.len == 0 and hook_summary.failureCode == null;
    std.process.exit(if (ok) 0 else 1);
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
        if (std.mem.eql(u8, arg, "--raw-sample")) {
            out.raw_sample = true;
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
        if (std.mem.eql(u8, arg, "--multi-agent-mode")) {
            out.multi_agent_mode = cas.MultiAgentMode.parse(value) orelse return error.InvalidMultiAgentMode;
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
        if (std.mem.eql(u8, arg, "--elicitation-response-json")) {
            var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, value, .{});
            defer parsed_json.deinit();
            out.elicitation_response_json = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dynamic-tool-response-json")) {
            var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, value, .{});
            defer parsed_json.deinit();
            out.dynamic_tool_response_json = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--auth-refresh-response-file")) {
            out.auth_refresh_response_source = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--attestation-response-file")) {
            out.attestation_response_source = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--experimental-api")) {
            out.experimental_api = parseBool(value) orelse return error.InvalidBoolean;
            continue;
        }
        if (std.mem.eql(u8, arg, "--init-capabilities-json")) {
            var parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, value, .{});
            defer parsed_json.deinit();
            if (parsed_json.value != .object) return error.InvalidInitializeCapabilities;
            out.additional_initialize_capabilities_json = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--codex-path")) {
            out.codex_path = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--app-server-transport")) {
            out.requested_transport = cas.app_server_launch.RequestedTransport.parse(value) orelse
                return error.InvalidTransport;
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
        if (std.mem.eql(u8, arg, "--opt-out-notification-method")) {
            try methods.append(allocator, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--hooks")) {
            out.hook_policy = cas.hooks.HookPolicy.parse(value) orelse return error.InvalidHooksPolicy;
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
    if (out.multi_agent_mode != null) return error.MultiAgentModeRemoved;
    if (std.mem.eql(u8, out.auth_refresh_response_source orelse "", "-") and
        std.mem.eql(u8, out.attestation_response_source orelse "", "-"))
    {
        return error.DuplicateSecretStdinSource;
    }
    _ = try cas.app_server_launch.validateTransport(
        out.requested_transport,
        out.transport_endpoint,
    );
    out.opt_out_methods = try methods.toOwnedSlice(allocator);
    return out;
}

fn parseBool(raw: []const u8) ?bool {
    if (std.mem.eql(u8, raw, "true")) return true;
    if (std.mem.eql(u8, raw, "false")) return false;
    return null;
}

fn transportName(transport: cas.app_server_launch.RequestedTransport) []const u8 {
    return switch (transport) {
        .auto => "auto",
        .stdio => "stdio",
        .managed_websocket => "managed-ws",
        .explicit_websocket => "ws",
        .unix_socket => "unix",
    };
}

fn usageDetailForParseError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MultiAgentModeRemoved => "Codex 0.145 ignores request-scoped multiAgentMode; configure [agents] " ++
            "in config.toml and use the current Codex reasoning-effort controls instead.",
        else => null,
    };
}

fn buildParamsJson(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: ?[]const u8,
    params_file: ?[]const u8,
) ![]u8 {
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
        "--hooks",
        "off",
        "--raw-sample",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(parsed.opt_out_methods);

    try std.testing.expectEqual(@as(?[]const u8, "/tmp/repo"), parsed.cwd);
    try std.testing.expectEqual(@as(usize, 4), parsed.instances);
    try std.testing.expectEqualStrings("thread/read", parsed.method);
    try std.testing.expect(parsed.raw_sample);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(@as(usize, 1), parsed.opt_out_methods.len);
    try std.testing.expectEqualStrings("thread/item/stream", parsed.opt_out_methods[0]);
    try std.testing.expectEqual(cas.hooks.HookPolicy.off, parsed.hook_policy);
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

test "parseArgs accepts typed transport initialization and secret sources" {
    const argv = [_][]const u8{
        "cas_instance_runner",
        "--cwd",
        "/tmp/repo",
        "--codex-path",
        "/opt/codex",
        "--app-server-transport",
        "unix",
        "--app-server-endpoint",
        "unix:///tmp/codex.sock",
        "--code-mode-host",
        "wss://code.example:443/path?credential=redacted-at-output",
        "--experimental-api",
        "false",
        "--init-capabilities-json",
        "{\"futureCapability\":true}",
        "--elicitation-response-json",
        "{\"action\":\"decline\"}",
        "--auth-refresh-response-file",
        "/secure/auth.json",
        "--attestation-response-file",
        "/secure/attestation.json",
    };
    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(parsed.opt_out_methods);
    try std.testing.expectEqual(
        cas.app_server_launch.RequestedTransport.unix_socket,
        parsed.requested_transport,
    );
    try std.testing.expectEqualStrings("unix:///tmp/codex.sock", parsed.transport_endpoint.?);
    try std.testing.expectEqualStrings("/opt/codex", parsed.codex_path);
    try std.testing.expect(!parsed.experimental_api);
    try std.testing.expectEqualStrings(
        "{\"futureCapability\":true}",
        parsed.additional_initialize_capabilities_json.?,
    );
    try std.testing.expectEqualStrings(
        "{\"action\":\"decline\"}",
        parsed.elicitation_response_json.?,
    );
    try std.testing.expectEqualStrings("/secure/auth.json", parsed.auth_refresh_response_source.?);
    try std.testing.expectEqualStrings(
        "/secure/attestation.json",
        parsed.attestation_response_source.?,
    );
}

test "parseArgs rejects ambiguous stdin secrets and incomplete explicit transport" {
    try std.testing.expectError(
        error.DuplicateSecretStdinSource,
        parseArgs(std.testing.allocator, &.{
            "cas_instance_runner",
            "--auth-refresh-response-file",
            "-",
            "--attestation-response-file",
            "-",
        }),
    );
    try std.testing.expectError(
        error.TransportEndpointRequired,
        parseArgs(std.testing.allocator, &.{
            "cas_instance_runner",
            "--app-server-transport",
            "ws",
        }),
    );
}

test "secret carrier files must be regular and owner only" {
    if (comptime std.posix.mode_t == u0) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const secure_path = try std.fs.path.join(std.testing.allocator, &.{ root, "secure.json" });
    defer std.testing.allocator.free(secure_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "secure.json", .data = "{\"token\":\"SECRET\"}" });
    var secure_file = try tmp.dir.openFile(io, "secure.json", .{});
    try secure_file.setPermissions(io, .fromMode(0o600));
    secure_file.close(io);
    const secure = try loadSecretCarrierAlloc(std.testing.allocator, io, secure_path);
    defer wipeSecretCarrier(std.testing.allocator, secure);
    try std.testing.expectEqualStrings("{\"token\":\"SECRET\"}", secure);

    const insecure_path = try std.fs.path.join(std.testing.allocator, &.{ root, "insecure.json" });
    defer std.testing.allocator.free(insecure_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "insecure.json", .data = "{}" });
    var insecure_file = try tmp.dir.openFile(io, "insecure.json", .{});
    try insecure_file.setPermissions(io, .fromMode(0o644));
    insecure_file.close(io);
    try std.testing.expectError(
        error.InsecureSecretCarrierPermissions,
        loadSecretCarrierAlloc(std.testing.allocator, io, insecure_path),
    );
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

test "parseArgs rejects removed multi-agent mode for turn start" {
    const argv = [_][]const u8{
        "cas_instance_runner",
        "--cwd",
        "/tmp/repo",
        "--method",
        "turn/start",
        "--multi-agent-mode",
        "proactive",
    };

    try std.testing.expectError(error.MultiAgentModeRemoved, parseArgs(std.testing.allocator, &argv));
}

test "parseArgs rejects removed multi-agent mode for thread list" {
    const argv = [_][]const u8{
        "cas_instance_runner",
        "--cwd",
        "/tmp/repo",
        "--method",
        "thread/list",
        "--multi-agent-mode",
        "proactive",
    };

    try std.testing.expectError(error.MultiAgentModeRemoved, parseArgs(std.testing.allocator, &argv));
}

test "buildParamsJson preserves caller-owned raw parameters" {
    const params = try buildParamsJson(
        std.testing.allocator,
        "turn/start",
        "{\"threadId\":\"thr_1\",\"input\":[]}",
        null,
    );
    defer std.testing.allocator.free(params);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, params, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("thr_1", obj.get("threadId").?.string);
    try std.testing.expect(obj.get("multiAgentMode") == null);
}

test "buildParamsJson leaves generic raw multiAgentMode caller-owned" {
    const params = try buildParamsJson(
        std.testing.allocator,
        "thread/start",
        "{\"multiAgentMode\":\"explicitRequestOnly\"}",
        null,
    );
    defer std.testing.allocator.free(params);
    try std.testing.expectEqualStrings(
        "{\"multiAgentMode\":\"explicitRequestOnly\"}",
        params,
    );
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
