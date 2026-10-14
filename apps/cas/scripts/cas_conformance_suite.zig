const app_meta = @import("app_meta");
const builtin = @import("builtin");
const cas_proxy_client = @import("cas_proxy_client");
const cas_hooks = cas_proxy_client.hooks;
const core_cli = @import("core_cli");
const core_json = @import("core_json");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const MaxCommandOutputBytes = 8 * 1024 * 1024;
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas_conformance_suite",
    .help_text = UsageText,
};

const UsageText =
    \\cas_conformance_suite
    \\
    \\Run CAS-backed conformance checks for smoke preflight and retry policy.
    \\
    \\Usage:
    \\  cas_conformance_suite --cwd DIR [options]
    \\
    \\Required:
    \\  --cwd DIR                         Workspace for CAS smoke preflight.
    \\
    \\Options:
    \\  --scenario NAME                   Repeatable: overload_backoff, app_server_features.
    \\  --skip-smoke-check                Skip live cas_smoke_check preflight.
    \\  --smoke-binary PATH               Override cas_smoke_check binary path.
    \\  --preflight-binary PATH           Override cas_app_server_preflight binary path.
    \\  --codex-path PATH                 Exact Codex binary for app-server feature probes.
    \\  --hooks MODE                      Hook policy for smoke preflight: inherit|off|require-observed (default: inherit).
    \\  --backoff-base-ms N               Base retry delay for overload policy checks (default: 250).
    \\  --max-retries N                   Max overload retries before failure (default: 4).
    \\  --json                            Emit machine-readable JSON.
    \\  --help                            Show this help.
    \\  --version                         Show version.
    \\  version                           Show version.
;

const DefaultRetryPolicy = cas_proxy_client.OverloadRetryPolicy{};
const DefaultBackoffBaseMs: u32 = DefaultRetryPolicy.base_delay_ms;
const DefaultMaxRetries: u32 = DefaultRetryPolicy.max_retries;

const Scenario = enum {
    overload_backoff,
    app_server_features,

    fn parse(raw: []const u8) ?Scenario {
        if (std.mem.eql(
            u8,
            raw,
            "overload_backoff",
        ) or std.mem.eql(u8, raw, "overload-backoff")) return .overload_backoff;
        if (std.mem.eql(u8, raw, "app_server_features") or
            std.mem.eql(u8, raw, "app-server-features")) return .app_server_features;
        return null;
    }

    fn asString(self: Scenario) []const u8 {
        return switch (self) {
            .overload_backoff => "overload_backoff",
            .app_server_features => "app_server_features",
        };
    }

    fn mode(self: Scenario) []const u8 {
        return switch (self) {
            .overload_backoff => "integration",
            .app_server_features => "exact-runtime",
        };
    }
};

const DefaultScenarios = [_]Scenario{
    .overload_backoff,
};

const ParsedArgs = struct {
    cwd: ?[]const u8 = null,
    scenarios: []const Scenario = &.{},
    skip_smoke_check: bool = false,
    smoke_binary: ?[]const u8 = null,
    preflight_binary: ?[]const u8 = null,
    codex_path: ?[]const u8 = null,
    hook_policy: cas_hooks.HookPolicy = .inherit,
    backoff_base_ms: u32 = DefaultBackoffBaseMs,
    max_retries: u32 = DefaultMaxRetries,
    json: bool = false,
    show_help: bool = false,
    show_version: bool = false,
};

const Context = struct {
    io: std.Io,
    dir: std.Io.Dir,
    environ: *const std.process.Environ.Map,
    cwd: []const u8,
    smoke_binary: []const u8,
    preflight_binary: []const u8 = "cas_app_server_preflight",
    codex_path: ?[]const u8 = null,
    hook_policy: cas_hooks.HookPolicy,
    backoff_base_ms: u32,
    max_retries: u32,
};

const CommandCapture = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
};

const SmokePreflightResult = struct {
    status: []const u8,
    ok: bool,
    exit_code: i32,
    detail: []const u8,
    thread_id: ?[]const u8 = null,
};

const ScenarioResult = struct {
    name: []const u8,
    mode: []const u8,
    ok: bool,
    detail: []const u8,
    temp_root: []const u8 = "",
    items_total: usize = 0,
    items_ok: usize = 0,
    in_progress: usize = 0,
    missing_rows: usize = 0,
    attempts: u32 = 0,
    retries: u32 = 0,
    delays_ms: []const u32 = &.{},
};

pub fn main(init: std.process.Init) !void {
    const code = try run(init);
    if (code != 0) std.process.exit(code);
}

pub fn run(init: std.process.Init) !u8 {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var help_writer = std.Io.File.stdout().writer(io, &.{});
    if (try core_cli.handleDefaultHelpAndVersionSurface(
        &help_writer.interface,
        argv,
        HelpSurface,
        Version,
    )) return 0;
    const parsed = parseArgs(allocator, argv) catch |err| {
        return usageFailure(io, @errorName(err), null);
    };

    if (parsed.show_version) {
        var stdout_writer = std.Io.File.stdout().writer(
            io,
            &.{},
        );
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return 0;
    }

    if (parsed.show_help) {
        var stdout_writer = std.Io.File.stdout().writer(
            io,
            &.{},
        );
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return 0;
    }

    const cwd = parsed.cwd orelse {
        return usageFailure(io, "MissingValue", "--cwd");
    };

    var directory = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer directory.close(io);
    const ctx = Context{
        .io = io,
        .dir = directory,
        .environ = init.environ_map,
        .cwd = cwd,
        .smoke_binary = try resolveExecutable(
            io,
            directory,
            allocator,
            parsed.smoke_binary,
            "cas_smoke_check",
        ),
        .preflight_binary = try resolveExecutable(
            io,
            directory,
            allocator,
            parsed.preflight_binary,
            "cas_app_server_preflight",
        ),
        .codex_path = parsed.codex_path,
        .hook_policy = parsed.hook_policy,
        .backoff_base_ms = parsed.backoff_base_ms,
        .max_retries = parsed.max_retries,
    };

    return runScenarios(allocator, parsed, ctx);
}

fn runScenarios(allocator: std.mem.Allocator, parsed: ParsedArgs, ctx: Context) !u8 {
    const smoke_preflight = if (parsed.skip_smoke_check)
        SmokePreflightResult{
            .status = "skipped",
            .ok = true,
            .exit_code = 0,
            .detail = "skipped by flag",
        }
    else
        try runSmokePreflight(allocator, ctx);

    var results = std.ArrayList(ScenarioResult).empty;
    for (parsed.scenarios) |scenario| {
        try results.append(allocator, try executeScenario(allocator, ctx, scenario));
    }

    var overall_ok = std.mem.eql(u8, smoke_preflight.status, "pass") or std.mem.eql(
        u8,
        smoke_preflight.status,
        "skipped",
    );
    for (results.items) |result| {
        if (!result.ok) overall_ok = false;
    }

    try writeScenarioReport(
        ctx.io,
        parsed.json,
        ctx.cwd,
        smoke_preflight,
        results.items,
        overall_ok,
    );
    return if (overall_ok) 0 else 1;
}

fn writeScenarioReport(
    io: std.Io,
    json: bool,
    cwd: []const u8,
    smoke_preflight: SmokePreflightResult,
    results: []const ScenarioResult,
    overall_ok: bool,
) !void {
    var stdout_writer = std.Io.File.stdout().writer(
        io,
        &.{},
    );
    const stdout = &stdout_writer.interface;
    if (json) {
        const payload = .{
            .check = "cas-conformance-suite",
            .cwd = cwd,
            .ok = overall_ok,
            .smoke_preflight = smoke_preflight,
            .scenarios = results,
        };
        try std.json.Stringify.value(payload, .{ .whitespace = .indent_2 }, stdout);
        try stdout.writeAll("\n");
    } else {
        try stdout.writeAll("cas conformance suite\n");
        try stdout.print("cwd: {s}\n", .{cwd});
        try stdout.print("overall: {s}\n", .{if (overall_ok) "pass" else "fail"});
        try stdout.print(
            "smoke preflight: {s} ({s})\n",
            .{ smoke_preflight.status, smoke_preflight.detail },
        );
        for (results) |result| try writeScenarioRow(stdout, result);
    }
}

fn writeScenarioRow(stdout: *std.Io.Writer, result: ScenarioResult) !void {
    try stdout.print(
        "- {s} [{s}]: {s} ({s})",
        .{ result.name, result.mode, if (result.ok) "pass" else "fail", result.detail },
    );
    if (result.items_total > 0) {
        try stdout.print(
            " items={d}/{d}",
            .{ result.items_ok, result.items_total },
        );
    }
    if (result.in_progress > 0) {
        try stdout.print(" in_progress={d}", .{result.in_progress});
    }
    if (result.missing_rows > 0) {
        try stdout.print(" missing_rows={d}", .{result.missing_rows});
    }
    if (result.attempts > 0) {
        try stdout.print(" attempts={d}", .{result.attempts});
    }
    if (result.retries > 0) {
        try stdout.print(" retries={d}", .{result.retries});
    }
    if (result.delays_ms.len > 0) {
        try stdout.print(" delays_ms={any}", .{result.delays_ms});
    }
    if (result.temp_root.len > 0) {
        try stdout.print(" temp_root={s}", .{result.temp_root});
    }
    try stdout.writeByte('\n');
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    var out = ParsedArgs{};
    var scenarios: std.ArrayList(Scenario) = .empty;
    errdefer scenarios.deinit(allocator);

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
        if (std.mem.eql(u8, arg, "--skip-smoke-check")) {
            out.skip_smoke_check = true;
            continue;
        }
        i += 1;
        if (i >= argv.len) return error.MissingValue;
        const value = argv[i];

        if (std.mem.eql(u8, arg, "--scenario")) {
            const scenario = Scenario.parse(value) orelse return error.UnknownScenario;
            try scenarios.append(allocator, scenario);
            continue;
        }
        try parseValueArg(&out, arg, value);
    }

    if (scenarios.items.len == 0) {
        try scenarios.appendSlice(allocator, DefaultScenarios[0..]);
    }

    try cas_proxy_client.validateOverloadRetryPolicy(.{
        .max_retries = out.max_retries,
        .base_delay_ms = out.backoff_base_ms,
    });

    out.scenarios = try scenarios.toOwnedSlice(allocator);
    return out;
}

fn resolveExecutable(
    io: std.Io,
    directory: std.Io.Dir,
    allocator: std.mem.Allocator,
    explicit: ?[]const u8,
    fallback_name: []const u8,
) ![]const u8 {
    if (explicit) |path| return allocator.dupe(u8, path);

    const exe_dir = std.process.executableDirPathAlloc(
        io,
        allocator,
    ) catch null;
    if (exe_dir) |dir| {
        defer allocator.free(dir);
        const sibling = try allocator.print("{s}/{s}", .{ dir, fallback_name });
        if (pathExists(io, directory, sibling)) return sibling;
        allocator.free(sibling);
    }

    return allocator.dupe(u8, fallback_name);
}

fn pathExists(io: std.Io, directory: std.Io.Dir, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(
            io,
            path,
            .{},
        ) catch return false;
        return true;
    }
    directory.access(
        io,
        path,
        .{},
    ) catch return false;
    return true;
}

fn runCommandCapture(
    ctx: Context,
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    argv: []const []const u8,
) !CommandCapture {
    const io = ctx.io;
    if (argv.len == 0) return error.FileNotFound;
    const executable = if (std.mem.indexOfScalar(u8, argv[0], '/') != null)
        try allocator.dupe(u8, argv[0])
    else
        cas_proxy_client.resolveExecutableAlloc(
            allocator,
            io,
            ctx.dir,
            ctx.environ.get("PATH"),
            argv[0],
        ) catch |err| switch (err) {
            error.ExecutableNotFound, error.MissingExecutable => return error.FileNotFound,
            else => return err,
        };
    defer allocator.free(executable);
    const resolved_argv = try allocator.dupe([]const u8, argv);
    defer allocator.free(resolved_argv);
    resolved_argv[0] = executable;
    if (builtin.target.os.tag == .macos) return runCommandCapturePosixSpawn(
        ctx,
        allocator,
        cwd,
        resolved_argv,
    );

    const result = try std.process.run(allocator, io, .{
        .argv = resolved_argv,
        .environ_map = ctx.environ,
        .cwd = if (cwd) |path| .{ .path = path } else .{ .dir = ctx.dir },
        .stdout_limit = .limited(MaxCommandOutputBytes),
        .stderr_limit = .limited(MaxCommandOutputBytes / 2),
    });

    return .{
        .exit_code = switch (result.term) {
            .exited => |code| code,
            .signal => |signal| @intCast(@min(@as(u32, 128) + @backingInt(signal), @as(u32, 255))),
            .stopped, .unknown => 1,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn runCommandCapturePosixSpawn(
    ctx: Context,
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    argv: []const []const u8,
) !CommandCapture {
    const io = ctx.io;
    if (argv.len == 0) return error.FileNotFound;

    const temp_root = try makeTempRoot(io, allocator, "cas-capture");
    defer {
        cleanupTempRoot(io, temp_root);
        allocator.free(temp_root);
    }

    const stdout_path = try std.fs.path.join(allocator, &.{ temp_root, "stdout.txt" });
    defer allocator.free(stdout_path);
    const stderr_path = try std.fs.path.join(allocator, &.{ temp_root, "stderr.txt" });
    defer allocator.free(stderr_path);

    var stdout_file = try std.Io.Dir.createFileAbsolute(
        io,
        stdout_path,
        .{ .truncate = true, .read = true },
    );
    defer stdout_file.close(io);
    var stderr_file = try std.Io.Dir.createFileAbsolute(
        io,
        stderr_path,
        .{ .truncate = true, .read = true },
    );
    defer stderr_file.close(io);

    const exit_code = try spawnCapturedCommand(
        ctx.dir,
        ctx.environ,
        allocator,
        cwd,
        argv,
        stdout_file.handle,
        stderr_file.handle,
    );
    return .{
        .exit_code = exit_code,
        .stdout = try readFileAbsoluteAlloc(io, allocator, stdout_path, MaxCommandOutputBytes),
        .stderr = try readFileAbsoluteAlloc(io, allocator, stderr_path, MaxCommandOutputBytes / 2),
    };
}

fn posixSpawnError(rc: c_int) anyerror {
    const err: std.c.E = @fromBackingInt(@intCast(@as(u16, @intCast(rc))));
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
        const signal: u32 = @backingInt(std.posix.W.TERMSIG(status));
        return @intCast(@min(@as(u32, 128) + signal, @as(u32, 255)));
    }
    return 1;
}

fn readFileAbsoluteAlloc(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const base = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(
        io,
        parent,
        .{},
    );
    defer dir.close(io);
    return dir.readFileAlloc(
        io,
        base,
        allocator,
        .limited(max_bytes),
    );
}

fn runSmokePreflight(allocator: std.mem.Allocator, ctx: Context) !SmokePreflightResult {
    const argv = [_][]const u8{
        ctx.smoke_binary,
        "--cwd",
        ctx.cwd,
        "--hooks",
        ctx.hook_policy.asString(),
        "--json",
    };
    const capture = runCommandCapture(ctx, allocator, null, &argv) catch |err| {
        return .{
            .status = "fail",
            .ok = false,
            .exit_code = 1,
            .detail = try allocator.print(
                "unable to start cas_smoke_check: {s}",
                .{@errorName(err)},
            ),
        };
    };

    return parseSmokeCapture(allocator, capture);
}

fn parseSmokeCapture(allocator: std.mem.Allocator, capture: CommandCapture) !SmokePreflightResult {
    const stdout_trimmed = std.mem.trim(u8, capture.stdout, " \t\r\n");
    const stderr_trimmed = std.mem.trim(u8, capture.stderr, " \t\r\n");

    var detail = try commandSummary(allocator, capture);
    var ok = capture.exit_code == 0;
    var thread_id: ?[]const u8 = null;

    if (stdout_trimmed.len > 0) {
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            stdout_trimmed,
            .{},
        ) catch null;
        defer if (parsed) |*owned| owned.deinit();
        if (parsed) |report| {
            if (report.value == .object) {
                if (boolField(
                    report.value.object,
                    "ok",
                )) |parsed_ok| ok = parsed_ok and capture.exit_code == 0;
                if (core_json.stringField(
                    report.value.object,
                    "threadId",
                )) |value| thread_id = try allocator.dupe(u8, value);
                const checks_len = if (report.value.object.get("checks")) |checks_val|
                    switch (checks_val) {
                        .array => |arr| arr.items.len,
                        else => 0,
                    }
                else
                    0;
                detail = try allocator.print(
                    "smoke_check {s} (checks={d}{s})",
                    .{
                        if (ok) "pass" else "fail",
                        checks_len,
                        if (thread_id) |id| try allocator.print(
                            ", threadId={s}",
                            .{id},
                        ) else "",
                    },
                );
            }
        }
    } else if (stderr_trimmed.len > 0) {
        detail = try allocator.dupe(u8, stderr_trimmed);
    }

    return .{
        .status = if (ok) "pass" else "fail",
        .ok = ok,
        .exit_code = capture.exit_code,
        .detail = detail,
        .thread_id = thread_id,
    };
}

fn executeScenario(allocator: std.mem.Allocator, ctx: Context, scenario: Scenario) !ScenarioResult {
    const result = switch (scenario) {
        .overload_backoff => scenarioOverloadBackoff(allocator, ctx),
        .app_server_features => scenarioAppServerFeatures(allocator, ctx),
    } catch |err| ScenarioResult{
        .name = scenario.asString(),
        .mode = scenario.mode(),
        .ok = false,
        .detail = @errorName(err),
    };

    return result;
}

const app_server_feature_probe_ids = [_][]const u8{
    "thread-sections-round-trip",
    "paginated-fork",
    "ephemeral-fork",
    "external-import-history",
};

fn scenarioAppServerFeatures(allocator: std.mem.Allocator, ctx: Context) !ScenarioResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        ctx.preflight_binary,
        "preflight",
        "--cwd",
        ctx.cwd,
        "--profile",
        "full",
        "--app-server-transport",
        "stdio",
        "--json",
    });
    if (ctx.codex_path) |codex_path| {
        try argv.appendSlice(allocator, &.{ "--codex-path", codex_path });
    }
    const capture = try runCommandCapture(ctx, allocator, null, argv.items);
    const stdout_trimmed = std.mem.trim(u8, capture.stdout, " \t\r\n");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout_trimmed, .{}) catch
        return error.InvalidAppServerPreflightJson;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidAppServerPreflightJson,
    };
    if (!std.mem.eql(
        u8,
        core_json.stringField(root, "schema") orelse return error.InvalidAppServerPreflightJson,
        "cas-app-server-preflight/v1",
    ))
        return error.InvalidAppServerPreflightJson;
    const probes_value = root.get("behavioralProbes") orelse
        return error.InvalidAppServerPreflightJson;
    const probe_rows = switch (probes_value) {
        .array => |value| value,
        else => return error.InvalidAppServerPreflightJson,
    };
    const summary = summarizeAppServerFeatureProbes(probe_rows.items);
    const full_status = core_json.stringField(root, "status") orelse "unknown";
    return .{
        .name = Scenario.app_server_features.asString(),
        .mode = Scenario.app_server_features.mode(),
        .ok = summary.passed == app_server_feature_probe_ids.len and summary.missing == 0,
        .detail = try allocator.print(
            "live preflight feature probes {d}/{d} passed (full_status={s}, exit={d})",
            .{ summary.passed, app_server_feature_probe_ids.len, full_status, capture.exit_code },
        ),
        .items_total = app_server_feature_probe_ids.len,
        .items_ok = summary.passed,
        .missing_rows = summary.missing,
    };
}

const FeatureProbeSummary = struct {
    passed: usize = 0,
    missing: usize = 0,
};

fn summarizeAppServerFeatureProbes(rows: []const std.json.Value) FeatureProbeSummary {
    var summary: FeatureProbeSummary = .{};
    for (app_server_feature_probe_ids) |expected_id| {
        var found = false;
        for (rows) |row_value| {
            const row = switch (row_value) {
                .object => |value| value,
                else => continue,
            };
            const id = core_json.stringField(row, "id") orelse continue;
            if (!std.mem.eql(u8, id, expected_id)) continue;
            found = true;
            if (std.mem.eql(
                u8,
                core_json.stringField(row, "status") orelse "",
                "passed",
            )) summary.passed += 1;
            break;
        }
        if (!found) summary.missing += 1;
    }
    return summary;
}

fn scenarioOverloadBackoff(allocator: std.mem.Allocator, ctx: Context) !ScenarioResult {
    const io = ctx.io;
    const success_policy = cas_proxy_client.OverloadRetryPolicy{
        .max_retries = ctx.max_retries,
        .base_delay_ms = ctx.backoff_base_ms,
    };
    try cas_proxy_client.validateOverloadRetryPolicy(success_policy);
    if (success_policy.max_retries < 2) return error.InsufficientRetriesForConformanceFixture;

    const temp_root = try makeTempRoot(io, allocator, "cas-overload-conformance");
    defer {
        deleteTreeAbsolute(io, temp_root) catch |err| {
            std.log.warn(
                "failed to delete temporary conformance root {s}: {s}",
                .{ temp_root, @errorName(err) },
            );
        };
        allocator.free(temp_root);
    }
    const success = try runProductionRetryCase(
        ctx,
        allocator,
        ctx.io,
        temp_root,
        "success",
        success_policy,
    );
    const tiny_policy = cas_proxy_client.OverloadRetryPolicy{
        .max_retries = 2,
        .base_delay_ms = 1,
        .max_delay_ms = 4,
        .jitter_percent = 25,
    };
    const nonoverload = try runProductionRetryCase(
        ctx,
        allocator,
        ctx.io,
        temp_root,
        "nonoverload",
        tiny_policy,
    );
    const exhaustion = try runProductionRetryCase(
        ctx,
        allocator,
        ctx.io,
        temp_root,
        "exhaust",
        tiny_policy,
    );
    try validateRetryProofs(success, nonoverload, exhaustion, tiny_policy.max_retries);
    const delays = try allocator.dupe(u32, success.delays_ms[0..success.delay_count]);
    return .{
        .name = Scenario.overload_backoff.asString(),
        .mode = Scenario.overload_backoff.mode(),
        .ok = true,
        .detail = "production proxy retry loop passed success, non-overload, " ++
            "and exhaustion fixtures",
        .attempts = success.wire_attempts,
        .retries = success.retries,
        .delays_ms = delays,
    };
}

const RetryCaseProof = struct {
    wire_attempts: u32,
    retries: u32,
    delay_count: usize,
    delays_ms: [cas_proxy_client.max_overload_retries]u32,
    notifications: usize,
    observer_calls: usize,
    exhausted: bool,
};

const ConformanceSendObserver = struct {
    calls: usize = 0,

    fn count(context: *anyopaque) anyerror!void {
        const self: *ConformanceSendObserver = @ptrCast(@alignCast(context));
        self.calls += 1;
    }
};

fn retryFixtureScriptAlloc(
    allocator: std.mem.Allocator,
    mode: []const u8,
    log_path: []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.print(
        "#!/bin/sh\nset -eu\nmode='{s}'\nlog_path='{s}'\n",
        .{ mode, log_path },
    );
    try writer.writer.writeAll(
        \\attempt=0
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{"id":-1,"result":{}}'; continue ;;
        \\    *'"method":"initialized"'*) continue ;;
        \\  esac
        \\  id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  [ -n "$id" ] || exit 7
        \\  printf '%s\n' "$line" >> "$log_path"
        \\  attempt=$((attempt + 1))
        \\  if [ "$mode" = nonoverload ]; then
        \\    printf '{"id":%s,"error":{"code":-32603,"message":"internal"}}\n' "$id"
        \\  elif [ "$mode" = success ] && [ "$attempt" -ge 3 ]; then
        \\    printf '{"id":%s,"result":{"ok":true}}\n' "$id"
        \\  else
        \\    printf '{"method":"test/notification","params":{"attempt":%s}}\n' "$attempt"
        \\    printf '{"id":%s,"error":{"code":-32001,"message":"overloaded"}}\n' "$id"
        \\  fi
        \\done
        \\
    );
    return writer.toOwnedSlice();
}

fn runProductionRetryCase(
    ctx: Context,
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    mode: []const u8,
    policy: cas_proxy_client.OverloadRetryPolicy,
) !RetryCaseProof {
    const executable = try allocator.print("{s}/fake-codex-{s}", .{ root, mode });
    defer allocator.free(executable);
    const log_path = try allocator.print("{s}/requests-{s}.jsonl", .{ root, mode });
    defer allocator.free(log_path);
    const script = try retryFixtureScriptAlloc(allocator, mode, log_path);
    defer allocator.free(script);
    {
        var script_file = try std.Io.Dir.createFileAbsolute(io, executable, .{ .truncate = true });
        defer script_file.close(io);
        try script_file.writeStreamingAll(io, script);
        try script_file.setPermissions(io, .fromMode(0o755));
    }

    var telemetry: cas_proxy_client.OverloadRetryTelemetry = .{};
    const deadline_ms: i64 = @intCast(
        @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000) + 30_000,
    );
    var client = try cas_proxy_client.Client.start(allocator, .{
        .cwd = root,
        .io = io,
        .dir = ctx.dir,
        .environ = ctx.environ,
        .codex_path = executable,
        .request_deadline_ms = deadline_ms,
        .overload_retry_policy = policy,
        .overload_retry_seed = 17,
        .overload_retry_telemetry = &telemetry,
    });
    defer {
        client.close();
        client.deinit();
    }
    var observer = ConformanceSendObserver{};
    var notifications: std.ArrayList([]u8) = .empty;
    defer {
        for (notifications.items) |line| allocator.free(line);
        notifications.deinit(allocator);
    }
    try exerciseRetryRequest(allocator, &client, mode, &notifications, &observer);
    if (observer.calls != 1) return error.ObserverCallCountMismatch;
    for (telemetry.delays_ms[0..telemetry.delay_count]) |delay| {
        if (delay > policy.max_delay_ms) return error.RetryDelayOutOfBounds;
    }

    try verifyRetryWireLog(allocator, io, log_path, telemetry.wire_attempts);
    return .{
        .wire_attempts = telemetry.wire_attempts,
        .retries = telemetry.retries,
        .delay_count = telemetry.delay_count,
        .delays_ms = telemetry.delays_ms,
        .notifications = notifications.items.len,
        .observer_calls = observer.calls,
        .exhausted = telemetry.exhausted,
    };
}

fn commandSummary(allocator: std.mem.Allocator, capture: CommandCapture) ![]const u8 {
    const stdout_trimmed = std.mem.trim(u8, capture.stdout, " \t\r\n");
    const stderr_trimmed = std.mem.trim(u8, capture.stderr, " \t\r\n");
    if (stderr_trimmed.len > 0 and stdout_trimmed.len > 0) {
        return allocator.print(
            "exit={d} stderr={s}; stdout={s}",
            .{ capture.exit_code, stderr_trimmed, stdout_trimmed },
        );
    }
    if (stderr_trimmed.len > 0) {
        return allocator.print(
            "exit={d} stderr={s}",
            .{ capture.exit_code, stderr_trimmed },
        );
    }
    if (stdout_trimmed.len > 0) {
        return allocator.print(
            "exit={d} stdout={s}",
            .{ capture.exit_code, stdout_trimmed },
        );
    }
    return allocator.print("exit={d}", .{capture.exit_code});
}

fn boolField(obj: core_json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn makeTempRoot(io: std.Io, allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const base = "/tmp";
    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const candidate = try allocator.print(
            "{s}/{s}-{d}-{d}",
            .{ base, prefix, @divFloor(
                std.Io.Clock.real.now(io).nanoseconds,
                1_000_000_000,
            ), attempt },
        );
        std.Io.Dir.createDirAbsolute(
            io,
            candidate,
            @fromBackingInt(@intCast(0o700)),
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(candidate);
                continue;
            },
            else => return err,
        };
        return candidate;
    }
    return error.TempDirCreationFailed;
}

fn deleteTreeAbsolute(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    const base = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(
        io,
        parent,
        .{},
    );
    defer dir.close(io);
    try dir.deleteTree(io, base);
}

fn cleanupTempRoot(io: std.Io, path: []const u8) void {
    deleteTreeAbsolute(io, path) catch |err| {
        std.debug.print("failed to clean temporary root {s}: {s}\n", .{ path, @errorName(err) });
    };
}

test "parseArgs accepts scenarios and retry knobs" {
    const argv = [_][]const u8{
        "cas_conformance_suite",
        "--cwd",
        "/tmp/repo",
        "--scenario",
        "overload_backoff",
        "--preflight-binary",
        "/tmp/cas_app_server_preflight",
        "--codex-path",
        "/tmp/codex-0.146.0",
        "--skip-smoke-check",
        "--backoff-base-ms",
        "500",
        "--max-retries",
        "7",
        "--hooks",
        "off",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(parsed.scenarios);

    try std.testing.expectEqualStrings("/tmp/repo", parsed.cwd.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.scenarios.len);
    try std.testing.expectEqual(Scenario.overload_backoff, parsed.scenarios[0]);
    try std.testing.expectEqualStrings("/tmp/cas_app_server_preflight", parsed.preflight_binary.?);
    try std.testing.expectEqualStrings("/tmp/codex-0.146.0", parsed.codex_path.?);
    try std.testing.expect(parsed.skip_smoke_check);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(cas_hooks.HookPolicy.off, parsed.hook_policy);
    try std.testing.expectEqual(@as(u32, 500), parsed.backoff_base_ms);
    try std.testing.expectEqual(@as(u32, 7), parsed.max_retries);
}

test "makeTempRoot never aliases an existing same-second root" {
    const io = std.testing.io;
    const first = try makeTempRoot(io, std.testing.allocator, "cas-conformance-unique-test");
    defer std.testing.allocator.free(first);
    defer cleanupTempRoot(io, first);
    const second = try makeTempRoot(io, std.testing.allocator, "cas-conformance-unique-test");
    defer std.testing.allocator.free(second);
    defer cleanupTempRoot(io, second);

    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "feature probe summary consumes exact live preflight rows" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[{\"id\":\"thread-sections-round-trip\",\"status\":\"passed\"}," ++
            "{\"id\":\"paginated-fork\",\"status\":\"passed\"}," ++
            "{\"id\":\"ephemeral-fork\",\"status\":\"failed\"}," ++
            "{\"id\":\"external-import-history\",\"status\":\"passed\"}]",
        .{},
    );
    defer parsed.deinit();
    const summary = summarizeAppServerFeatureProbes(parsed.value.array.items);
    try std.testing.expectEqual(@as(usize, 3), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.missing);
}

test "parseArgs rejects unknown scenario" {
    const argv = [_][]const u8{
        "cas_conformance_suite",
        "--cwd",
        "/tmp/repo",
        "--scenario",
        "nope",
    };

    try std.testing.expectError(error.UnknownScenario, parseArgs(std.testing.allocator, &argv));
}

test "computeBackoffDelayMs grows monotonically" {
    const policy = cas_proxy_client.OverloadRetryPolicy{};
    const d0 = cas_proxy_client.overloadRetryDelayMs(policy, 0, 0);
    const d1 = cas_proxy_client.overloadRetryDelayMs(policy, 1, 0);
    const d2 = cas_proxy_client.overloadRetryDelayMs(policy, 2, 0);
    try std.testing.expect(d0 > 0);
    try std.testing.expect(d1 > d0);
    try std.testing.expect(d2 > d1);
}

test "overload classification delegates to structured proxy policy" {
    const cases = [_]struct { raw: []const u8, expected: bool }{
        .{ .raw = "{\"code\":-32001,\"message\":\"overloaded\"}", .expected = true },
        .{ .raw = "{\"code\":-32603,\"message\":\"overloaded\"}", .expected = false },
        .{ .raw = "\"server overloaded -32001\"", .expected = false },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            case.raw,
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectEqual(
            case.expected,
            cas_proxy_client.isStructuredOverloadError(parsed.value),
        );
    }
}

test "overload scenario route drives production proxy retry integration" {
    if (builtin.target.os.tag == .windows or
        builtin.target.os.tag == .wasi) return error.SkipZigTest;
    var environment = try std.testing.environ.createMap(std.testing.allocator);
    defer environment.deinit();
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer directory.close(std.testing.io);
    const ctx = Context{
        .io = std.testing.io,
        .dir = directory,
        .environ = &environment,
        .cwd = "/tmp",
        .smoke_binary = "unused",
        .hook_policy = .inherit,
        .backoff_base_ms = 1,
        .max_retries = 2,
    };
    const result = try executeScenario(std.testing.allocator, ctx, .overload_backoff);
    defer if (result.delays_ms.len != 0) std.testing.allocator.free(result.delays_ms);
    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("integration", result.mode);
    try std.testing.expectEqual(@as(u32, 3), result.attempts);
    try std.testing.expectEqual(@as(u32, 2), result.retries);
    try std.testing.expectEqual(@as(usize, 2), result.delays_ms.len);
}

fn parseValueArg(out: *ParsedArgs, arg: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, arg, "--cwd")) {
        out.cwd = value;
        return;
    }
    if (std.mem.eql(u8, arg, "--smoke-binary")) {
        out.smoke_binary = value;
        return;
    }
    if (std.mem.eql(u8, arg, "--preflight-binary")) {
        out.preflight_binary = value;
        return;
    }
    if (std.mem.eql(u8, arg, "--codex-path")) {
        out.codex_path = value;
        return;
    }
    if (std.mem.eql(u8, arg, "--hooks")) {
        out.hook_policy = cas_hooks.HookPolicy.parse(value) orelse
            return error.InvalidHooksPolicy;
        return;
    }
    if (std.mem.eql(u8, arg, "--backoff-base-ms")) {
        const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidBackoffBase;
        if (parsed == 0) return error.InvalidBackoffBase;
        out.backoff_base_ms = parsed;
        return;
    }
    if (std.mem.eql(u8, arg, "--max-retries")) {
        out.max_retries = std.fmt.parseInt(u32, value, 10) catch return error.InvalidMaxRetries;
        return;
    }
    return error.UnknownArg;
}

fn spawnCapturedCommand(
    directory: std.Io.Dir,
    environ: *const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    argv: []const []const u8,
    stdout_handle: std.posix.fd_t,
    stderr_handle: std.posix.fd_t,
) !u8 {
    var actions: std.c.posix_spawn_file_actions_t = undefined;
    if (std.c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnFileActionsFailed;
    defer {
        const destroyed = std.c.posix_spawn_file_actions_destroy(&actions);
        std.debug.assert(destroyed == 0);
    }
    if (std.c.posix_spawn_file_actions_adddup2(
        &actions,
        stdout_handle,
        std.posix.STDOUT_FILENO,
    ) != 0) return error.SpawnFileActionsFailed;
    if (std.c.posix_spawn_file_actions_adddup2(
        &actions,
        stderr_handle,
        std.posix.STDERR_FILENO,
    ) != 0) return error.SpawnFileActionsFailed;
    var cwd_storage: ?[:0]u8 = null;
    defer if (cwd_storage) |path| allocator.free(path);
    if (cwd) |path| {
        cwd_storage = try allocator.dupeSentinel(u8, path, 0);
        if (std.c.posix_spawn_file_actions_addchdir_np(
            &actions,
            cwd_storage.?.ptr,
        ) != 0) return error.SpawnFileActionsFailed;
    } else if (std.c.posix_spawn_file_actions_addfchdir_np(&actions, directory.handle) != 0) {
        return error.SpawnFileActionsFailed;
    }
    var argv_buf = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    defer allocator.free(argv_buf);
    var arg_storage = try allocator.alloc([:0]u8, argv.len);
    var arg_count: usize = 0;
    defer {
        for (arg_storage[0..arg_count]) |arg| allocator.free(arg);
        allocator.free(arg_storage);
    }
    for (argv, 0..) |arg, i| {
        arg_storage[i] = try allocator.dupeSentinel(u8, arg, 0);
        arg_count += 1;
        argv_buf[i] = arg_storage[i].ptr;
    }
    var pid: std.c.pid_t = undefined;
    // Keep the temporary POSIX environment under one owner, including partial
    // construction failure (Zig 0.17 frees a partial pointer-array extent).
    var environment_arena = std.heap.ArenaAllocator.init(allocator);
    defer environment_arena.deinit();
    const environment = try environ.createPosixBlock(environment_arena.allocator(), .{});
    const envp = environment.slice.ptr;
    const spawn_rc = std.c.posix_spawn(&pid, argv_buf[0].?, &actions, null, argv_buf.ptr, envp);
    if (spawn_rc != 0) return posixSpawnError(spawn_rc);
    return waitCapturedCommand(pid);
}

fn waitCapturedCommand(pid: std.c.pid_t) !u8 {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    // The owned child determines termination; interruptions only retry the wait.
    while (true) { // tiger: event-loop
        switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
            .SUCCESS => break,
            .INTR => continue,
            .CHILD => return error.NoChildProcess,
            else => return error.WaitFailed,
        }
    }
    return statusToExitCode(@bitCast(status));
}

fn validateRetryProofs(
    success: RetryCaseProof,
    nonoverload: RetryCaseProof,
    exhaustion: RetryCaseProof,
    max_retries: u32,
) !void {
    if (success.wire_attempts != 3 or
        success.retries != 2 or
        success.notifications != 2 or
        success.observer_calls != 1)
    {
        return error.InvalidSuccessRetryProof;
    }
    if (nonoverload.wire_attempts != 1 or
        nonoverload.retries != 0 or
        nonoverload.observer_calls != 1)
    {
        return error.InvalidNonOverloadProof;
    }
    if (exhaustion.wire_attempts != max_retries + 1 or
        exhaustion.retries != max_retries or
        !exhaustion.exhausted or
        exhaustion.observer_calls != 1)
    {
        return error.InvalidExhaustionProof;
    }
}

fn exerciseRetryRequest(
    allocator: std.mem.Allocator,
    client: *cas_proxy_client.Client,
    mode: []const u8,
    notifications: *std.ArrayList([]u8),
    observer: *ConformanceSendObserver,
) !void {
    if (std.mem.eql(u8, mode, "success")) {
        const result = try client.requestJsonCaptureNotificationsWithSendObserver(
            "conformance/retry",
            "{\"value\":7}",
            notifications,
            .{ .context = observer, .before_send = ConformanceSendObserver.count },
        );
        defer allocator.free(result);
        if (!std.mem.eql(u8, result, "{\"ok\":true}") or client.lastError() != null) {
            return error.InvalidSuccessRetryProof;
        }
    } else {
        const result = client.requestJsonWithSendObserver(
            "conformance/retry",
            "{\"value\":7}",
            .{ .context = observer, .before_send = ConformanceSendObserver.count },
        );
        if (result) |owned| {
            allocator.free(owned);
            return error.ExpectedRequestFailure;
        } else |err| if (err != error.RequestFailed) return err;
    }
}

fn verifyRetryWireLog(
    allocator: std.mem.Allocator,
    io: std.Io,
    log_path: []const u8,
    wire_attempts: u32,
) !void {
    const requests = try readFileAbsoluteAlloc(io, allocator, log_path, 64 * 1024);
    defer allocator.free(requests);
    var lines = std.mem.tokenizeScalar(u8, requests, '\n');
    var index: i64 = 1;
    while (lines.next()) |line| : (index += 1) {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidRetryRequest,
        };
        if (core_json.intField(object, "id") != index) return error.NonFreshRetryRequestId;
        if (!std.mem.eql(
            u8,
            core_json.stringField(object, "method") orelse return error.InvalidRetryRequest,
            "conformance/retry",
        )) return error.InvalidRetryRequest;
        const params = core_json.objectField(object, "params") orelse
            return error.InvalidRetryRequest;
        if (core_json.intField(params, "value") != 7) return error.InvalidRetryRequest;
    }
    if (index - 1 != wire_attempts) return error.RetryAttemptCountMismatch;
}

fn usageFailure(io: std.Io, code: []const u8, detail: ?[]const u8) u8 {
    var writer = std.Io.File.stderr().writer(io, &.{});
    core_cli.printUsageFailureWithHelp(
        &writer.interface,
        HelpSurface,
        Version,
        code,
        detail,
    ) catch return 1;
    return 2;
}
