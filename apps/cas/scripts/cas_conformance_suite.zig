const app_meta = @import("app_meta");
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
    \\Run CAS-backed swarm conformance checks for smoke preflight, durable claims, mesh reconciliation, and retry policy.
    \\
    \\Usage:
    \\  cas_conformance_suite --cwd DIR [options]
    \\
    \\Required:
    \\  --cwd DIR                         Workspace for CAS smoke preflight.
    \\
    \\Options:
    \\  --scenario NAME                   Repeatable: claim_safe_wave|stale_claim_reclaim|mesh_row_accountability|overload_backoff.
    \\  --skip-smoke-check                Skip live cas_smoke_check preflight.
    \\  --keep-temp                       Keep per-scenario temp roots even on success.
    \\  --st-binary PATH                  Override st binary path.
    \\  --smoke-binary PATH               Override cas_smoke_check binary path.
    \\  --backoff-base-ms N               Base retry delay for overload policy checks (default: 250).
    \\  --max-retries N                   Max overload retries before failure (default: 4).
    \\  --overload-script TOKENS          Comma-separated synthetic outcomes (default: overload,overload,success).
    \\  --json                            Emit machine-readable JSON.
    \\  --help                            Show this help.
    \\  --version                         Show version.
    \\  version                           Show version.
;

const DefaultBackoffBaseMs: u32 = 250;
const DefaultMaxRetries: u32 = 4;
const DefaultOverloadScript = [_][]const u8{ "overload", "overload", "success" };

const Scenario = enum {
    claim_safe_wave,
    stale_claim_reclaim,
    mesh_row_accountability,
    overload_backoff,

    fn parse(raw: []const u8) ?Scenario {
        if (std.mem.eql(u8, raw, "claim_safe_wave") or std.mem.eql(u8, raw, "claim-safe-wave")) return .claim_safe_wave;
        if (std.mem.eql(u8, raw, "stale_claim_reclaim") or std.mem.eql(u8, raw, "stale-claim-reclaim")) return .stale_claim_reclaim;
        if (std.mem.eql(u8, raw, "mesh_row_accountability") or std.mem.eql(u8, raw, "mesh-row-accountability")) return .mesh_row_accountability;
        if (std.mem.eql(u8, raw, "overload_backoff") or std.mem.eql(u8, raw, "overload-backoff")) return .overload_backoff;
        return null;
    }

    fn asString(self: Scenario) []const u8 {
        return switch (self) {
            .claim_safe_wave => "claim_safe_wave",
            .stale_claim_reclaim => "stale_claim_reclaim",
            .mesh_row_accountability => "mesh_row_accountability",
            .overload_backoff => "overload_backoff",
        };
    }

    fn mode(self: Scenario) []const u8 {
        return switch (self) {
            .overload_backoff => "synthetic",
            else => "local",
        };
    }
};

const DefaultScenarios = [_]Scenario{
    .claim_safe_wave,
    .stale_claim_reclaim,
    .mesh_row_accountability,
    .overload_backoff,
};

const ParsedArgs = struct {
    cwd: ?[]const u8 = null,
    scenarios: []const Scenario = &.{},
    skip_smoke_check: bool = false,
    keep_temp: bool = false,
    st_binary: ?[]const u8 = null,
    smoke_binary: ?[]const u8 = null,
    backoff_base_ms: u32 = DefaultBackoffBaseMs,
    max_retries: u32 = DefaultMaxRetries,
    overload_script: []const []const u8 = &.{},
    json: bool = false,
    show_help: bool = false,
    show_version: bool = false,
};

const Context = struct {
    cwd: []const u8,
    st_binary: []const u8,
    smoke_binary: []const u8,
    keep_temp: bool,
    backoff_base_ms: u32,
    max_retries: u32,
    overload_script: []const []const u8,
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

const RetryOutcome = enum {
    overload,
    success,
    fail,

    fn parse(raw: []const u8) ?RetryOutcome {
        if (std.mem.eql(u8, raw, "overload")) return .overload;
        if (std.mem.eql(u8, raw, "success")) return .success;
        if (std.mem.eql(u8, raw, "fail")) return .fail;
        return null;
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    const parsed = parseArgs(allocator, argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    if (parsed.show_version) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }

    if (parsed.show_help) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    const cwd = parsed.cwd orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingValue", "--cwd");
    };

    const ctx = Context{
        .cwd = cwd,
        .st_binary = try resolveExecutable(allocator, parsed.st_binary, "st"),
        .smoke_binary = try resolveExecutable(allocator, parsed.smoke_binary, "cas_smoke_check"),
        .keep_temp = parsed.keep_temp,
        .backoff_base_ms = parsed.backoff_base_ms,
        .max_retries = parsed.max_retries,
        .overload_script = parsed.overload_script,
    };

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

    var overall_ok = std.mem.eql(u8, smoke_preflight.status, "pass") or std.mem.eql(u8, smoke_preflight.status, "skipped");
    for (results.items) |result| {
        if (!result.ok) overall_ok = false;
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    if (parsed.json) {
        const payload = .{
            .check = "cas-conformance-suite",
            .cwd = cwd,
            .ok = overall_ok,
            .smoke_preflight = smoke_preflight,
            .scenarios = results.items,
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
        for (results.items) |result| {
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
    }

    std.process.exit(if (overall_ok) 0 else 1);
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    var out = ParsedArgs{};
    var scenarios: std.ArrayList(Scenario) = .empty;
    var overload_script: std.ArrayList([]const u8) = .empty;

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
        if (std.mem.eql(u8, arg, "--keep-temp")) {
            out.keep_temp = true;
            continue;
        }

        i += 1;
        if (i >= argv.len) return error.MissingValue;
        const value = argv[i];

        if (std.mem.eql(u8, arg, "--cwd")) {
            out.cwd = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--scenario")) {
            const scenario = Scenario.parse(value) orelse return error.UnknownScenario;
            try scenarios.append(allocator, scenario);
            continue;
        }
        if (std.mem.eql(u8, arg, "--st-binary")) {
            out.st_binary = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--smoke-binary")) {
            out.smoke_binary = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--backoff-base-ms")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidBackoffBase;
            out.backoff_base_ms = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-retries")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed < 0) return error.InvalidMaxRetries;
            out.max_retries = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--overload-script")) {
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |token_raw| {
                const token = std.mem.trim(u8, token_raw, " \t\r\n");
                if (token.len == 0) continue;
                _ = RetryOutcome.parse(token) orelse return error.InvalidOverloadScript;
                try overload_script.append(allocator, token);
            }
            continue;
        }
        return error.UnknownArg;
    }

    if (scenarios.items.len == 0) {
        try scenarios.appendSlice(allocator, DefaultScenarios[0..]);
    }
    if (overload_script.items.len == 0) {
        try overload_script.appendSlice(allocator, DefaultOverloadScript[0..]);
    }

    out.scenarios = try scenarios.toOwnedSlice(allocator);
    out.overload_script = try overload_script.toOwnedSlice(allocator);
    return out;
}

fn resolveExecutable(allocator: std.mem.Allocator, explicit: ?[]const u8, fallback_name: []const u8) ![]const u8 {
    if (explicit) |path| return allocator.dupe(u8, path);

    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch null;
    if (exe_dir) |dir| {
        defer allocator.free(dir);
        const sibling = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, fallback_name });
        if (pathExists(sibling)) return sibling;
        allocator.free(sibling);
    }

    return allocator.dupe(u8, fallback_name);
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn runCommandCapture(allocator: std.mem.Allocator, cwd: ?[]const u8, argv: []const []const u8) !CommandCapture {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout_data = try child.stdout.?.readToEndAlloc(allocator, MaxCommandOutputBytes);
    const stderr_data = try child.stderr.?.readToEndAlloc(allocator, MaxCommandOutputBytes / 2);
    const term = try child.wait();

    return .{
        .exit_code = switch (term) {
            .Exited => |code| code,
            .Signal => |signal| @intCast(@min(@as(u32, 128) + signal, @as(u32, 255))),
            .Stopped, .Unknown => 1,
        },
        .stdout = stdout_data,
        .stderr = stderr_data,
    };
}

fn runSmokePreflight(allocator: std.mem.Allocator, ctx: Context) !SmokePreflightResult {
    const argv = [_][]const u8{ ctx.smoke_binary, "--cwd", ctx.cwd, "--json" };
    const capture = runCommandCapture(allocator, null, &argv) catch |err| {
        return .{
            .status = "fail",
            .ok = false,
            .exit_code = 1,
            .detail = try std.fmt.allocPrint(allocator, "unable to start cas_smoke_check: {s}", .{@errorName(err)}),
        };
    };

    const stdout_trimmed = std.mem.trim(u8, capture.stdout, " \t\r\n");
    const stderr_trimmed = std.mem.trim(u8, capture.stderr, " \t\r\n");

    var detail = try commandSummary(allocator, capture);
    var ok = capture.exit_code == 0;
    var thread_id: ?[]const u8 = null;

    if (stdout_trimmed.len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout_trimmed, .{}) catch null;
        defer if (parsed) |*owned| owned.deinit();
        if (parsed) |report| {
            if (report.value == .object) {
                if (boolField(report.value.object, "ok")) |parsed_ok| ok = parsed_ok and capture.exit_code == 0;
                if (core_json.stringField(report.value.object, "threadId")) |value| thread_id = value;
                const checks_len = if (report.value.object.get("checks")) |checks_val|
                    switch (checks_val) {
                        .array => |arr| arr.items.len,
                        else => 0,
                    }
                else
                    0;
                detail = try std.fmt.allocPrint(
                    allocator,
                    "smoke_check {s} (checks={d}{s})",
                    .{
                        if (ok) "pass" else "fail",
                        checks_len,
                        if (thread_id) |id| try std.fmt.allocPrint(allocator, ", threadId={s}", .{id}) else "",
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
    const needs_temp = scenario != .overload_backoff;
    const temp_root = if (needs_temp) try makeTempRoot(allocator, scenario.asString()) else "";

    var result = switch (scenario) {
        .claim_safe_wave => scenarioClaimSafeWave(allocator, ctx, temp_root),
        .stale_claim_reclaim => scenarioStaleClaimReclaim(allocator, ctx, temp_root),
        .mesh_row_accountability => scenarioMeshRowAccountability(allocator, ctx, temp_root),
        .overload_backoff => scenarioOverloadBackoff(allocator, ctx),
    } catch |err| ScenarioResult{
        .name = scenario.asString(),
        .mode = scenario.mode(),
        .ok = false,
        .detail = try std.fmt.allocPrint(allocator, "unexpected error: {s}", .{@errorName(err)}),
    };

    if (needs_temp) {
        if (ctx.keep_temp or !result.ok) {
            result.temp_root = temp_root;
        } else {
            deleteTreeAbsolute(temp_root) catch {};
            result.temp_root = "";
        }
    }

    return result;
}

fn scenarioClaimSafeWave(allocator: std.mem.Allocator, ctx: Context, temp_root: []const u8) !ScenarioResult {
    const plan_path = try std.fs.path.join(allocator, &.{ temp_root, "st-plan.jsonl" });
    const orchplan_path = try std.fs.path.join(allocator, &.{ temp_root, "claim-safe-wave.yaml" });
    try writeTextFile(allocator, orchplan_path,
        \\schema_version: 1
        \\kind: OrchPlan
        \\tasks:
        \\  - id: cfg
        \\    title: Update config loader
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["src/config/**"]
        \\    location: ["src/config/index.ts"]
        \\    validation: ["npm test -w config"]
        \\  - id: ui
        \\    title: Update settings UI
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["src/ui/**"]
        \\    location: ["src/ui/Settings.tsx"]
        \\    validation: ["npm test -w ui"]
        \\waves:
        \\  - id: w1
        \\    tasks: [cfg, ui]
    );

    if (try runStExitNonZero(allocator, ctx, &.{ "import-orchplan", "--file", plan_path, "--input", orchplan_path, "--replace" })) |detail| {
        return failedScenario(.claim_safe_wave, detail);
    }
    if (try runStExitNonZero(allocator, ctx, &.{ "claim", "--file", plan_path, "--ids", "cfg,ui", "--executor", "teams", "--wave", "w1" })) |detail| {
        return failedScenario(.claim_safe_wave, detail);
    }
    if (try runStExitNonZero(allocator, ctx, &.{ "set-runtime", "--file", plan_path, "--id", "cfg", "--substrate", "spawn_agent", "--thread-id", "thread-cfg" })) |detail| {
        return failedScenario(.claim_safe_wave, detail);
    }
    if (try runStExitNonZero(allocator, ctx, &.{ "set-runtime", "--file", plan_path, "--id", "ui", "--substrate", "spawn_agent", "--thread-id", "thread-ui" })) |detail| {
        return failedScenario(.claim_safe_wave, detail);
    }

    const show_capture = try runStShowAll(allocator, ctx, plan_path);
    if (show_capture.exit_code != 0) return failedScenario(.claim_safe_wave, try commandSummary(allocator, show_capture));

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, show_capture.stdout, .{});
    defer parsed.deinit();
    const items = try itemsArray(parsed.value);
    const cfg = findItemObject(items, "cfg") orelse return failedScenario(.claim_safe_wave, "missing cfg item after claim-safe wave run");
    const ui = findItemObject(items, "ui") orelse return failedScenario(.claim_safe_wave, "missing ui item after claim-safe wave run");

    const ok =
        stringFieldEquals(cfg, "status", "in_progress") and
        stringFieldEquals(ui, "status", "in_progress") and
        stringFieldEquals(cfg, "claim_state", "held") and
        stringFieldEquals(ui, "claim_state", "held") and
        stringFieldEquals(cfg, "executor_state", "running") and
        stringFieldEquals(ui, "executor_state", "running") and
        stringFieldEquals(cfg, "source", "") == false and
        boolField(cfg, "in_plan") == true and
        boolField(ui, "in_plan") == true and
        stringArrayContains(cfg, "lock_roots", "src/config") and
        stringArrayContains(ui, "lock_roots", "src/ui");

    if (!ok) {
        return failedScenario(
            .claim_safe_wave,
            try std.fmt.allocPrint(allocator, "expected two disjoint held running claims, got in_progress={d}", .{countItemsWithStatus(items, "in_progress")}),
        );
    }

    return .{
        .name = Scenario.claim_safe_wave.asString(),
        .mode = Scenario.claim_safe_wave.mode(),
        .ok = true,
        .detail = "two disjoint tasks reached in_progress under held claims",
        .items_total = items.len,
        .items_ok = 2,
        .in_progress = countItemsWithStatus(items, "in_progress"),
    };
}

fn scenarioStaleClaimReclaim(allocator: std.mem.Allocator, ctx: Context, temp_root: []const u8) !ScenarioResult {
    const plan_path = try std.fs.path.join(allocator, &.{ temp_root, "st-plan.jsonl" });
    const orchplan_path = try std.fs.path.join(allocator, &.{ temp_root, "stale-claim.yaml" });
    try writeTextFile(allocator, orchplan_path,
        \\schema_version: 1
        \\kind: OrchPlan
        \\tasks:
        \\  - id: api
        \\    title: Add health endpoint
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["src/api/**"]
        \\    validation: ["npm test -w api"]
        \\waves:
        \\  - id: w1
        \\    tasks: [api]
    );

    if (try runStExitNonZero(allocator, ctx, &.{ "import-orchplan", "--file", plan_path, "--input", orchplan_path, "--replace" })) |detail| {
        return failedScenario(.stale_claim_reclaim, detail);
    }
    if (try runStExitNonZero(allocator, ctx, &.{ "claim", "--file", plan_path, "--ids", "api", "--executor", "teams", "--wave", "w1", "--lease-seconds", "60" })) |detail| {
        return failedScenario(.stale_claim_reclaim, detail);
    }
    if (try runStExitNonZero(allocator, ctx, &.{ "set-runtime", "--file", plan_path, "--id", "api", "--substrate", "spawn_agent", "--thread-id", "thread-api" })) |detail| {
        return failedScenario(.stale_claim_reclaim, detail);
    }
    if (try runStExitNonZero(allocator, ctx, &.{ "reclaim-stale", "--file", plan_path, "--now", "2099-01-01T00:00:00Z" })) |detail| {
        return failedScenario(.stale_claim_reclaim, detail);
    }

    const show_capture = try runStShowAll(allocator, ctx, plan_path);
    if (show_capture.exit_code != 0) return failedScenario(.stale_claim_reclaim, try commandSummary(allocator, show_capture));

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, show_capture.stdout, .{});
    defer parsed.deinit();
    const items = try itemsArray(parsed.value);
    const api = findItemObject(items, "api") orelse return failedScenario(.stale_claim_reclaim, "missing api item after reclaim-stale run");

    const ok =
        stringFieldEquals(api, "status", "pending") and
        stringFieldEquals(api, "claim_state", "stale") and
        boolField(api, "claim_stale") == true and
        stringFieldEquals(api, "executor_state", "stale") and
        core_json.objectField(api, "runtime") == null;

    if (!ok) return failedScenario(.stale_claim_reclaim, "reclaim-stale did not leave the claim stale and non-running");

    return .{
        .name = Scenario.stale_claim_reclaim.asString(),
        .mode = Scenario.stale_claim_reclaim.mode(),
        .ok = true,
        .detail = "expired held claim was reclaimed and returned to pending",
        .items_total = items.len,
        .items_ok = 1,
    };
}

fn scenarioMeshRowAccountability(allocator: std.mem.Allocator, ctx: Context, temp_root: []const u8) !ScenarioResult {
    const plan_path = try std.fs.path.join(allocator, &.{ temp_root, "st-plan.jsonl" });
    const orchplan_path = try std.fs.path.join(allocator, &.{ temp_root, "mesh-accountability.yaml" });
    const results_path = try std.fs.path.join(allocator, &.{ temp_root, "mesh-results.csv" });
    try writeTextFile(allocator, orchplan_path,
        \\schema_version: 1
        \\kind: OrchPlan
        \\tasks:
        \\  - id: api
        \\    title: Add health endpoint
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["src/api/**"]
        \\    validation: ["npm test -w api"]
        \\  - id: docs
        \\    title: Document health endpoint
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["docs/**"]
        \\    validation: ["npm test -w docs"]
        \\waves:
        \\  - id: w1
        \\    tasks: [api, docs]
    );
    try writeTextFile(allocator, results_path,
        \\task_id,proof_status,proof_evidence,decision
        \\api,pass,mesh-proof.txt,proof_complete
    );

    if (try runStExitNonZero(allocator, ctx, &.{ "import-orchplan", "--file", plan_path, "--input", orchplan_path, "--replace" })) |detail| {
        return failedScenario(.mesh_row_accountability, detail);
    }
    if (try runStExitNonZero(allocator, ctx, &.{ "claim", "--file", plan_path, "--ids", "api,docs", "--executor", "mesh", "--wave", "w1" })) |detail| {
        return failedScenario(.mesh_row_accountability, detail);
    }
    if (try runStExitNonZero(allocator, ctx, &.{ "set-runtime", "--file", plan_path, "--id", "api", "--substrate", "spawn_agents_on_csv", "--row-id", "api" })) |detail| {
        return failedScenario(.mesh_row_accountability, detail);
    }
    if (try runStExitNonZero(allocator, ctx, &.{ "set-runtime", "--file", plan_path, "--id", "docs", "--substrate", "spawn_agents_on_csv", "--row-id", "docs" })) |detail| {
        return failedScenario(.mesh_row_accountability, detail);
    }
    if (try runStExitNonZero(allocator, ctx, &.{ "import-mesh-results", "--file", plan_path, "--input", results_path })) |detail| {
        return failedScenario(.mesh_row_accountability, detail);
    }

    const show_capture = try runStShowAll(allocator, ctx, plan_path);
    if (show_capture.exit_code != 0) return failedScenario(.mesh_row_accountability, try commandSummary(allocator, show_capture));

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, show_capture.stdout, .{});
    defer parsed.deinit();
    const items = try itemsArray(parsed.value);
    const api = findItemObject(items, "api") orelse return failedScenario(.mesh_row_accountability, "missing api item after mesh reconciliation");
    const docs = findItemObject(items, "docs") orelse return failedScenario(.mesh_row_accountability, "missing docs item after mesh reconciliation");

    const ok =
        stringFieldEquals(api, "status", "completed") and
        stringFieldEquals(api, "claim_state", "released") and
        stringFieldEquals(api, "executor_state", "released") and
        stringFieldEquals(core_json.objectField(api, "proof").?, "state", "pass") and
        stringFieldEquals(docs, "status", "in_progress") and
        stringFieldEquals(docs, "claim_state", "held") and
        stringFieldEquals(docs, "executor_state", "running");

    if (!ok) {
        return failedScenario(.mesh_row_accountability, "mesh reconciliation did not preserve outstanding missing rows");
    }

    return .{
        .name = Scenario.mesh_row_accountability.asString(),
        .mode = Scenario.mesh_row_accountability.mode(),
        .ok = true,
        .detail = "one mesh row reconciled and one missing row stayed non-terminal",
        .items_total = items.len,
        .items_ok = 1,
        .in_progress = countItemsWithStatus(items, "in_progress"),
        .missing_rows = 1,
    };
}

fn scenarioOverloadBackoff(allocator: std.mem.Allocator, ctx: Context) !ScenarioResult {
    var delays = std.ArrayList(u32).empty;
    var retries: u32 = 0;
    var attempts: u32 = 0;

    for (ctx.overload_script) |token| {
        const outcome = RetryOutcome.parse(token) orelse {
            return failedScenario(.overload_backoff, try std.fmt.allocPrint(allocator, "unknown overload outcome token: {s}", .{token}));
        };
        attempts += 1;
        switch (outcome) {
            .overload => {
                if (retries >= ctx.max_retries) {
                    return .{
                        .name = Scenario.overload_backoff.asString(),
                        .mode = Scenario.overload_backoff.mode(),
                        .ok = false,
                        .detail = "overload retries exceeded max_retries before success",
                        .attempts = attempts,
                        .retries = retries,
                        .delays_ms = try delays.toOwnedSlice(allocator),
                    };
                }
                try delays.append(allocator, computeBackoffDelayMs(ctx.backoff_base_ms, retries));
                retries += 1;
            },
            .success => {
                return .{
                    .name = Scenario.overload_backoff.asString(),
                    .mode = Scenario.overload_backoff.mode(),
                    .ok = true,
                    .detail = "synthetic overload script converged under bounded retries",
                    .attempts = attempts,
                    .retries = retries,
                    .delays_ms = try delays.toOwnedSlice(allocator),
                };
            },
            .fail => {
                return .{
                    .name = Scenario.overload_backoff.asString(),
                    .mode = Scenario.overload_backoff.mode(),
                    .ok = false,
                    .detail = "synthetic script hit a non-retryable failure before success",
                    .attempts = attempts,
                    .retries = retries,
                    .delays_ms = try delays.toOwnedSlice(allocator),
                };
            },
        }
    }

    return .{
        .name = Scenario.overload_backoff.asString(),
        .mode = Scenario.overload_backoff.mode(),
        .ok = false,
        .detail = "synthetic overload script ended without a terminal success",
        .attempts = attempts,
        .retries = retries,
        .delays_ms = try delays.toOwnedSlice(allocator),
    };
}

fn runStExitNonZero(allocator: std.mem.Allocator, ctx: Context, args: []const []const u8) !?[]const u8 {
    const capture = try runStCommand(allocator, ctx, args);
    if (capture.exit_code == 0) return null;
    return try commandSummary(allocator, capture);
}

fn runStShowAll(allocator: std.mem.Allocator, ctx: Context, plan_path: []const u8) !CommandCapture {
    return runStCommand(allocator, ctx, &.{ "show", "--file", plan_path, "--surface", "all", "--format", "json" });
}

fn runStCommand(allocator: std.mem.Allocator, ctx: Context, args: []const []const u8) !CommandCapture {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, ctx.st_binary);
    try argv.appendSlice(allocator, args);
    return runCommandCapture(allocator, null, argv.items);
}

fn commandSummary(allocator: std.mem.Allocator, capture: CommandCapture) ![]const u8 {
    const stdout_trimmed = std.mem.trim(u8, capture.stdout, " \t\r\n");
    const stderr_trimmed = std.mem.trim(u8, capture.stderr, " \t\r\n");
    if (stderr_trimmed.len > 0 and stdout_trimmed.len > 0) {
        return std.fmt.allocPrint(
            allocator,
            "exit={d} stderr={s}; stdout={s}",
            .{ capture.exit_code, stderr_trimmed, stdout_trimmed },
        );
    }
    if (stderr_trimmed.len > 0) {
        return std.fmt.allocPrint(allocator, "exit={d} stderr={s}", .{ capture.exit_code, stderr_trimmed });
    }
    if (stdout_trimmed.len > 0) {
        return std.fmt.allocPrint(allocator, "exit={d} stdout={s}", .{ capture.exit_code, stdout_trimmed });
    }
    return std.fmt.allocPrint(allocator, "exit={d}", .{capture.exit_code});
}

fn failedScenario(scenario: Scenario, detail: []const u8) ScenarioResult {
    return .{
        .name = scenario.asString(),
        .mode = scenario.mode(),
        .ok = false,
        .detail = detail,
    };
}

fn itemsArray(root_value: std.json.Value) ![]const std.json.Value {
    const root_obj = switch (root_value) {
        .object => |obj| obj,
        else => return error.InvalidShowOutput,
    };
    const items_val = root_obj.get("items") orelse return error.InvalidShowOutput;
    return switch (items_val) {
        .array => |arr| arr.items,
        else => error.InvalidShowOutput,
    };
}

fn findItemObject(items: []const std.json.Value, id: []const u8) ?core_json.ObjectMap {
    for (items) |item| {
        if (item != .object) continue;
        if (core_json.stringField(item.object, "id")) |item_id| {
            if (std.mem.eql(u8, item_id, id)) return item.object;
        }
    }
    return null;
}

fn boolField(obj: core_json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn stringFieldEquals(obj: core_json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const value = core_json.stringField(obj, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn stringArrayContains(obj: core_json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const value = obj.get(key) orelse return false;
    const arr = switch (value) {
        .array => |list| list.items,
        else => return false,
    };
    for (arr) |entry| {
        if (entry != .string) continue;
        if (std.mem.eql(u8, entry.string, expected)) return true;
    }
    return false;
}

fn countItemsWithStatus(items: []const std.json.Value, status: []const u8) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item != .object) continue;
        if (core_json.stringField(item.object, "status")) |item_status| {
            if (std.mem.eql(u8, item_status, status)) count += 1;
        }
    }
    return count;
}

fn computeBackoffDelayMs(base_ms: u32, retry_index: u32) u32 {
    const capped_retry = @min(retry_index, @as(u32, 10));
    const multiplier: u64 = @as(u64, 1) << @intCast(capped_retry);
    const base_delay = @as(u64, base_ms) * multiplier;
    const jitter = (@as(u64, base_ms) / 4) * (@as(u64, (retry_index % 3) + 1));
    return @intCast(@min(base_delay + jitter, @as(u64, std.math.maxInt(u32))));
}

fn isOverloadErrorText(text: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, text, .{}) catch null;
    defer if (parsed) |*owned| owned.deinit();
    if (parsed) |value| {
        if (value.value == .object) {
            if (core_json.intField(value.value.object, "code")) |code| {
                if (code == -32001) return true;
            }
            if (core_json.objectField(value.value.object, "error")) |err_obj| {
                if (core_json.intField(err_obj, "code")) |code| {
                    if (code == -32001) return true;
                }
            }
        }
    }
    return containsCaseInsensitive(text, "server overloaded") or
        containsCaseInsensitive(text, "retry later") or
        containsCaseInsensitive(text, "-32001");
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

fn makeTempRoot(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const base = std.posix.getenv("TMPDIR") orelse "/tmp";
    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const candidate = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}-{d}-{d}",
            .{ base, prefix, std.time.timestamp(), attempt },
        );
        std.fs.makeDirAbsolute(candidate) catch |err| switch (err) {
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

fn deleteTreeAbsolute(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    const base = std.fs.path.basename(path);
    var dir = try std.fs.openDirAbsolute(parent, .{});
    defer dir.close();
    try dir.deleteTree(base);
}

fn writeTextFile(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    try ensureParentPath(path);
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(text);
        return;
    }

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(text);
    _ = allocator;
}

fn ensureParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;

    if (std.fs.path.isAbsolute(parent)) {
        const rel = std.mem.trimLeft(u8, parent, "/");
        if (rel.len == 0) return;
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        try root.makePath(rel);
        return;
    }

    try std.fs.cwd().makePath(parent);
}

test "parseArgs accepts scenarios and retry knobs" {
    const argv = [_][]const u8{
        "cas_conformance_suite",
        "--cwd",
        "/tmp/repo",
        "--scenario",
        "claim_safe_wave",
        "--scenario",
        "overload_backoff",
        "--skip-smoke-check",
        "--keep-temp",
        "--backoff-base-ms",
        "500",
        "--max-retries",
        "7",
        "--overload-script",
        "overload,success",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(parsed.scenarios);
    defer std.testing.allocator.free(parsed.overload_script);

    try std.testing.expectEqualStrings("/tmp/repo", parsed.cwd.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.scenarios.len);
    try std.testing.expectEqual(Scenario.claim_safe_wave, parsed.scenarios[0]);
    try std.testing.expectEqual(Scenario.overload_backoff, parsed.scenarios[1]);
    try std.testing.expect(parsed.skip_smoke_check);
    try std.testing.expect(parsed.keep_temp);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(@as(u32, 500), parsed.backoff_base_ms);
    try std.testing.expectEqual(@as(u32, 7), parsed.max_retries);
    try std.testing.expectEqual(@as(usize, 2), parsed.overload_script.len);
    try std.testing.expectEqualStrings("overload", parsed.overload_script[0]);
    try std.testing.expectEqualStrings("success", parsed.overload_script[1]);
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
    const d0 = computeBackoffDelayMs(250, 0);
    const d1 = computeBackoffDelayMs(250, 1);
    const d2 = computeBackoffDelayMs(250, 2);
    try std.testing.expect(d0 > 0);
    try std.testing.expect(d1 > d0);
    try std.testing.expect(d2 > d1);
}

test "isOverloadErrorText handles structured and text forms" {
    try std.testing.expect(isOverloadErrorText("{\"code\":-32001,\"message\":\"Server overloaded; retry later.\"}"));
    try std.testing.expect(isOverloadErrorText("{\"error\":{\"code\":-32001,\"message\":\"retry later\"}}"));
    try std.testing.expect(isOverloadErrorText("server overloaded; retry later"));
    try std.testing.expect(!isOverloadErrorText("{\"code\":-32601,\"message\":\"method not found\"}"));
}
