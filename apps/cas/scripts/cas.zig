const builtin = @import("builtin");
const std = @import("std");
const delegate = @import("core_delegate");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas",
    .help_text = UsageText,
};

const CapabilitiesText =
    \\session_inquiry_v1=true
    \\dcp_v1=true
    \\dcp_v2=true
    \\cas_rer_opaque_request_binding_v1=true
    \\cas_workflow_bound_owner_lived_review_v1=true
    \\cas_review_scoped_instructions_v1=true
    \\cas_app_server_contract_v2=true
    \\cas_app_server_schema_probe_v1=true
    \\cas_app_server_thread_sections_v1=true
    \\cas_app_server_stateful_session_v1=true
    \\cas_app_server_daemon_v1=true
    \\cas_app_server_authenticated_websocket_listener_v1=true
    \\cas_app_server_grpc_code_mode_host_v1=true
    \\cas_app_server_structured_errors_v1=true
    \\cas_app_server_paginated_fork_v1=true
    \\cas_app_server_ephemeral_paginated_fork_v1=true
    \\cas_app_server_executor_skill_resources_v1=true
    \\cas_app_server_external_import_history_v1=true
    \\cas_structured_review_v1=true
    \\cas_automation_v1=true
;

const CapabilitiesJson =
    \\{
    \\  "cas_capabilities": {
    \\    "features": {
    \\      "session_inquiry_v1": true,
    \\      "dcp_v1": true,
    \\      "dcp_v2": true,
    \\      "rip_v1": true,
    \\      "fir_v1": true,
    \\      "exact_fork_rollback_anchor": true,
    \\      "ephemeral_fork": true,
    \\      "read_only_inquiry": true,
    \\      "detached_inquiry": true,
    \\      "cas_rer_opaque_request_binding_v1": true,
    \\      "cas_workflow_bound_owner_lived_review_v1": true,
    \\      "cas_review_scoped_instructions_v1": true,
    \\      "cas_app_server_contract_v2": true,
    \\      "cas_app_server_schema_probe_v1": true,
    \\      "cas_app_server_thread_sections_v1": true,
    \\      "cas_app_server_stateful_session_v1": true,
    \\      "cas_app_server_daemon_v1": true,
    \\      "cas_app_server_authenticated_websocket_listener_v1": true,
    \\      "cas_app_server_grpc_code_mode_host_v1": true,
    \\      "cas_app_server_structured_errors_v1": true,
    \\      "cas_app_server_paginated_fork_v1": true,
    \\      "cas_app_server_ephemeral_paginated_fork_v1": true,
    \\      "cas_app_server_executor_skill_resources_v1": true,
    \\      "cas_app_server_external_import_history_v1": true,
    \\      "cas_structured_review_v1": true,
    \\      "cas_automation_v1": true
    \\    }
    \\  }
    \\}
;

const CurrentContractCapabilities = [_][]const u8{
    "cas_app_server_thread_sections_v1",
    "cas_app_server_stateful_session_v1",
    "cas_app_server_daemon_v1",
    "cas_app_server_authenticated_websocket_listener_v1",
    "cas_app_server_grpc_code_mode_host_v1",
    "cas_app_server_structured_errors_v1",
    "cas_app_server_paginated_fork_v1",
    "cas_app_server_ephemeral_paginated_fork_v1",
    "cas_app_server_executor_skill_resources_v1",
    "cas_app_server_external_import_history_v1",
    "cas_structured_review_v1",
};

const UsageText =
    \\cas
    \\
    \\CAS dispatcher for subcommand-style usage.
    \\
    \\Usage:
    \\  cas <subcommand> [args...]
    \\
    \\Subcommands:
    \\  account                            Run cas_account.
    \\  app-server                         Inspect or preflight the Codex app-server.
    \\  automation                         Manage Codex automations.
    \\  capabilities                       Print compiled CAS feature flags.
    \\  conformance     | conformance-suite  Run cas_conformance_suite.
    \\  goal                                 Run cas_goal.
    \\  instance_runner | instance-runner   Run cas_instance_runner.
    \\  review                              Run tuple-bound review attempts.
    \\  session_inquiry | session-inquiry   Run cas_session_inquiry.
    \\  smoke_check     | smoke-check       Run cas_smoke_check.
    \\
    \\Examples:
    \\  cas automation --help
    \\  cas capabilities --json
    \\  cas account status --cwd /path/to/repo --json
    \\  cas app-server schema --profile core --json
    \\  cas app-server preflight --profile core --app-server-transport stdio --json
    \\  cas app-server session --listen stdio://
    \\  cas app-server daemon version
    \\  cas conformance --cwd /path/to/repo --json
    \\  cas goal resolve --cwd /path/to/repo --latest --json
    \\  cas instance_runner --cwd /path/to/repo --instances 4
    \\  cas review run --cwd /path/to/repo --base main --json
    \\  cas review start --cwd /path/to/repo --uncommitted --json
    \\  cas review wait --cwd /path/to/repo --latest --json
    \\  cas session_inquiry preflight --json
    \\  cas smoke_check --cwd /path/to/repo --json
    \\
    \\Options:
    \\  --help                              Show this help.
    \\  --version | version                 Show version.
;

const InstalledBinarySet =
    "cas, cas_account, cas_automation, cas_smoke_check, cas_instance_runner, " ++
    "cas_review_session, cas_session_inquiry, cas_conformance_suite, cas_goal, " ++
    "cas_app_server_preflight";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len <= 1 or delegate.isHelpRequested(argv) or std.mem.eql(u8, argv[1], "help")) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    if (delegate.isVersionRequested(argv)) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }

    if (std.mem.eql(u8, argv[1], "capabilities")) {
        try printCapabilities(argv[2..]);
        return;
    }

    if (std.mem.eql(u8, argv[1], "app-server") and argv.len > 2 and
        (std.mem.eql(u8, argv[2], "session") or std.mem.eql(u8, argv[2], "daemon")))
    {
        const exit_code = runAppServerDelegate(allocator, init.io, argv[2..]) catch |err| {
            var stderr_writer = std.Io.File.stderr().writer(
                std.Io.Threaded.global_single_threaded.io(),
                &.{},
            );
            try stderr_writer.interface.print(
                "failed to launch Codex app-server: {s}\n",
                .{@errorName(err)},
            );
            std.process.exit(1);
        };
        std.process.exit(exit_code);
    }

    const target_name = resolveTarget(argv[1]) orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "UnknownSubcommand", argv[1]);
    };

    const target_exec = blk: {
        const exe_dir = std.process.executableDirPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator) catch null;
        if (exe_dir) |dir| break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, target_name });
        break :blk try allocator.dupe(u8, target_name);
    };

    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);
    try child_argv.append(allocator, target_exec);
    try child_argv.appendSlice(allocator, argv[2..]);

    const exit_code = runCommand(allocator, init.io, child_argv.items) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print(
            "failed to launch {s}: {s}\ninstall or expose the compiled CAS binary set beside `cas` ({s})\n",
            .{ target_name, @errorName(err), InstalledBinarySet },
        );
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

fn runAppServerDelegate(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
) !u8 {
    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);
    try appendAppServerDelegateArgs(allocator, &child_argv, args);
    return runCommand(allocator, io, child_argv.items);
}

fn appendAppServerDelegateArgs(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    args: []const []const u8,
) !void {
    if (args.len == 0 or
        (!std.mem.eql(u8, args[0], "session") and !std.mem.eql(u8, args[0], "daemon")))
    {
        return error.InvalidAppServerDelegate;
    }
    var codex_path: []const u8 = "codex";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--codex-path")) continue;
        if (i + 1 >= args.len) return error.MissingCodexPath;
        codex_path = args[i + 1];
        i += 1;
    }
    try out.appendSlice(allocator, &.{ codex_path, "app-server" });
    if (std.mem.eql(u8, args[0], "daemon")) try out.append(allocator, "daemon");
    i = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--codex-path")) {
            i += 1;
            continue;
        }
        try out.append(allocator, args[i]);
    }
}

fn runCommand(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (builtin.os.tag == .macos) return runCommandPosixSpawn(allocator, args);

    var child = try std.process.spawn(io, .{
        .argv = args,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(@as(u32, 128) + @intFromEnum(signal), @as(u32, 255))),
        .stopped, .unknown => 1,
    };
}

fn runCommandPosixSpawn(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) return error.FileNotFound;

    var argv_buf = try allocator.allocSentinel(?[*:0]const u8, args.len, null);
    defer allocator.free(argv_buf);

    var arg_storage = try allocator.alloc([:0]u8, args.len);
    var arg_count: usize = 0;
    defer {
        for (arg_storage[0..arg_count]) |arg| allocator.free(arg);
        allocator.free(arg_storage);
    }

    for (args, 0..) |arg, i| {
        arg_storage[i] = try allocator.dupeZ(u8, arg);
        arg_count += 1;
        argv_buf[i] = arg_storage[i].ptr;
    }

    var pid: std.c.pid_t = undefined;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const spawn_rc = if (std.mem.indexOfScalar(u8, args[0], '/') == null)
        std.c.posix_spawnp(&pid, argv_buf[0].?, null, null, argv_buf.ptr, envp)
    else
        std.c.posix_spawn(&pid, argv_buf[0].?, null, null, argv_buf.ptr, envp);
    if (spawn_rc != 0) return posixSpawnError(spawn_rc);

    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
        .SUCCESS => return statusToExitCode(@bitCast(status)),
        .INTR => continue,
        .CHILD => return error.NoChildProcess,
        else => return error.WaitFailed,
    };
}

fn posixSpawnError(rc: c_int) anyerror {
    const err: std.c.E = @enumFromInt(@as(u16, @intCast(rc)));
    return switch (err) {
        .NOMEM, .@"2BIG" => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOEXEC => error.InvalidExe,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        else => error.SpawnFailed,
    };
}

fn statusToExitCode(status: u32) u8 {
    if (std.posix.W.IFEXITED(status)) return std.posix.W.EXITSTATUS(status);
    if (std.posix.W.IFSIGNALED(status)) {
        const signal: u32 = @intFromEnum(std.posix.W.TERMSIG(status));
        return @intCast(@min(@as(u32, 128) + signal, @as(u32, 255)));
    }
    return 1;
}

fn resolveTarget(subcommand: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, subcommand, "account")) {
        return "cas_account";
    }
    if (std.mem.eql(u8, subcommand, "automation")) {
        return "cas_automation";
    }
    if (std.mem.eql(u8, subcommand, "app-server")) {
        return "cas_app_server_preflight";
    }
    if (std.mem.eql(u8, subcommand, "conformance") or std.mem.eql(u8, subcommand, "conformance-suite") or std.mem.eql(u8, subcommand, "conformance_suite")) {
        return "cas_conformance_suite";
    }
    if (std.mem.eql(u8, subcommand, "goal")) {
        return "cas_goal";
    }
    if (std.mem.eql(u8, subcommand, "instance_runner") or std.mem.eql(u8, subcommand, "instance-runner")) {
        return "cas_instance_runner";
    }
    if (std.mem.eql(u8, subcommand, "review")) {
        return "cas_review_session";
    }
    if (std.mem.eql(u8, subcommand, "session_inquiry") or std.mem.eql(u8, subcommand, "session-inquiry")) {
        return "cas_session_inquiry";
    }
    if (std.mem.eql(u8, subcommand, "smoke_check") or std.mem.eql(u8, subcommand, "smoke-check")) {
        return "cas_smoke_check";
    }
    return null;
}

fn printCapabilities(args: []const []const u8) !void {
    var json = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (core_cli.isHelpArg(arg)) {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            try stdout.writeAll(
                \\cas capabilities
                \\
                \\Usage:
                \\  cas capabilities [--json]
                \\
            );
            return;
        } else {
            core_cli.exitUsageFailure(HelpSurface, Version, "UnknownFlag", arg);
        }
    }
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try writeCapabilities(stdout, json);
}

fn writeCapabilities(writer: *std.Io.Writer, json: bool) !void {
    try writer.writeAll(if (json) CapabilitiesJson else CapabilitiesText);
    try writer.writeByte('\n');
}

test "resolveTarget supports supported subcommands" {
    try std.testing.expectEqualStrings("cas_account", resolveTarget("account").?);
    try std.testing.expectEqualStrings("cas_automation", resolveTarget("automation").?);
    try std.testing.expectEqualStrings("cas_app_server_preflight", resolveTarget("app-server").?);
    try std.testing.expect(resolveTarget("cron") == null);
    try std.testing.expectEqualStrings("cas_conformance_suite", resolveTarget("conformance").?);
    try std.testing.expectEqualStrings("cas_conformance_suite", resolveTarget("conformance-suite").?);
    try std.testing.expectEqualStrings("cas_goal", resolveTarget("goal").?);
    try std.testing.expectEqualStrings("cas_instance_runner", resolveTarget("instance_runner").?);
    try std.testing.expectEqualStrings("cas_instance_runner", resolveTarget("instance-runner").?);
    try std.testing.expectEqualStrings("cas_review_session", resolveTarget("review").?);
    try std.testing.expect(resolveTarget("review_session") == null);
    try std.testing.expect(resolveTarget("review-session") == null);
    try std.testing.expectEqualStrings("cas_session_inquiry", resolveTarget("session_inquiry").?);
    try std.testing.expectEqualStrings("cas_session_inquiry", resolveTarget("session-inquiry").?);
    try std.testing.expect(resolveTarget("trial") == null);
    try std.testing.expectEqualStrings("cas_smoke_check", resolveTarget("smoke_check").?);
    try std.testing.expectEqualStrings("cas_smoke_check", resolveTarget("smoke-check").?);
    try std.testing.expect(resolveTarget("unknown") == null);
}

test "app-server session and daemon delegate without version pinning" {
    var session: std.ArrayList([]const u8) = .empty;
    defer session.deinit(std.testing.allocator);
    try appendAppServerDelegateArgs(
        std.testing.allocator,
        &session,
        &.{ "session", "--codex-path", "/opt/codex", "--listen", "stdio://" },
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "/opt/codex", "app-server", "--listen", "stdio://" },
        session.items,
    );

    var daemon: std.ArrayList([]const u8) = .empty;
    defer daemon.deinit(std.testing.allocator);
    try appendAppServerDelegateArgs(
        std.testing.allocator,
        &daemon,
        &.{ "daemon", "version", "--codex-path", "codex-next" },
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "codex-next", "app-server", "daemon", "version" },
        daemon.items,
    );
    try std.testing.expectError(
        error.MissingCodexPath,
        appendAppServerDelegateArgs(
            std.testing.allocator,
            &daemon,
            &.{ "session", "--codex-path" },
        ),
    );
}

test "review dispatcher advertises only the current public route" {
    try std.testing.expect(std.mem.indexOf(u8, UsageText, "cas review run") != null);
    try std.testing.expect(std.mem.indexOf(u8, UsageText, "cas review start") != null);
    try std.testing.expect(std.mem.indexOf(u8, UsageText, "cas review wait") != null);
    const retired_routes = [_][]const u8{
        "review_session",
        "review-session",
        "cas review current",
        "cas review list",
        "cas review import",
        "cas review inspect",
        "cas review validate-record",
    };
    for (retired_routes) |retired| {
        try std.testing.expect(std.mem.indexOf(u8, UsageText, retired) == null);
    }
}

test "capabilities advertise only current review boundary features" {
    var text_output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text_output.deinit();
    try writeCapabilities(&text_output.writer, false);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_output.written(),
        "cas_rer_opaque_request_binding_v1=true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_output.written(),
        "cas_workflow_bound_owner_lived_review_v1=true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_output.written(),
        "cas_review_scoped_instructions_v1=true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_output.written(),
        "cas_app_server_contract_v2=true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_output.written(),
        "cas_app_server_schema_probe_v1=true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output.written(), "cas_codex_0145_") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_output.written(),
        "cas_automation_v1=true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_output.written(),
        "cas_rer_workflow_binding_v1",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_output.written(),
        "cas_review_history_v2",
    ) == null);
    try std.testing.expect(std.mem.indexOf(u8, text_output.written(), "dcp_v2=true") != null);

    var json_output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json_output.deinit();
    try writeCapabilities(&json_output.writer, true);
    try std.testing.expect(std.mem.indexOf(u8, json_output.written(), "\"cas_rer_opaque_request_binding_v1\": true") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json_output.written(),
        "\"cas_workflow_bound_owner_lived_review_v1\": true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output.written(), "\"cas_review_scoped_instructions_v1\": true") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json_output.written(),
        "\"cas_app_server_contract_v2\": true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json_output.written(),
        "\"cas_app_server_schema_probe_v1\": true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output.written(), "cas_codex_0145_") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json_output.written(),
        "\"cas_automation_v1\": true",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json_output.written(),
        "cas_rer_workflow_binding_v1",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json_output.written(),
        "cas_review_history_v2",
    ) == null);
    try std.testing.expect(std.mem.indexOf(u8, json_output.written(), "\"dcp_v2\": true") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output.written(), .{});
    defer parsed.deinit();
    const features = parsed.value.object.get("cas_capabilities").?.object.get("features").?.object;
    try std.testing.expect(features.get("cas_rer_opaque_request_binding_v1").?.bool);
    try std.testing.expect(features.get("cas_workflow_bound_owner_lived_review_v1").?.bool);
    try std.testing.expect(features.get("cas_review_scoped_instructions_v1").?.bool);
    try std.testing.expect(features.get("cas_app_server_contract_v2").?.bool);
    try std.testing.expect(features.get("cas_app_server_schema_probe_v1").?.bool);
    try std.testing.expect(features.get("cas_automation_v1").?.bool);
    try std.testing.expect(features.get("cas_rer_workflow_binding_v1") == null);
    try std.testing.expect(features.get("cas_review_history_v2") == null);
    try std.testing.expect(features.get("dcp_v2").?.bool);
}

test "capabilities publish current contract features" {
    var text_output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer text_output.deinit();
    try writeCapabilities(&text_output.writer, false);

    var json_output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer json_output.deinit();
    try writeCapabilities(&json_output.writer, true);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json_output.written(),
        .{},
    );
    defer parsed.deinit();
    const features = parsed.value.object.get("cas_capabilities").?.object
        .get("features").?.object;
    for (CurrentContractCapabilities) |capability| {
        try std.testing.expect(std.mem.indexOf(
            u8,
            text_output.written(),
            capability,
        ) != null);
        try std.testing.expect(features.get(capability).?.bool);
    }
}
