const std = @import("std");
const governor = @import("budget_governor.zig");
const core_perf = @import("core_perf");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);
const UsageText =
    \\perf_budget_governor.zig
    \\
    \\Performance harness for budget_governor.
    \\
    \\Usage:
    \\  cas-perf-budget-governor [options]
    \\
    \\Options:
    \\  --config PATH               Override config file path.
    \\  --artifact PATH             Read/write benchmark artifact.
    \\  --trend-tolerance-pct N     Override trend tolerance percent.
    \\  --report-only               Skip failure gates.
    \\  --help                      Show help.
    \\  --version                   Show version.
    \\  version                     Show version.
;

const PerfConfig = struct {
    iterations: usize = 20_000,
    rounds: usize = 9,
    max_p95_ns_per_eval: u64 = 120_000,
    max_p50_alloc_calls_per_eval: u64 = 120,
    trend_tolerance_pct: f64 = 20.0,
};

const CliOptions = struct {
    config_path: []u8,
    artifact_path: ?[]u8 = null,
    trend_tolerance_override: ?f64 = null,
    report_only: bool = false,
};

const RoundStats = struct {
    elapsed_ns: u64,
    eval_count: usize,
    alloc_calls: u64,
};

const PerfSummary = struct {
    rounds: usize,
    eval_count: usize,
    p50_ns_per_eval: u64,
    p95_ns_per_eval: u64,
    p50_alloc_calls_per_eval: u64,
};

const BenchmarkArtifact = struct {
    p95_ns_per_eval: u64,
    p50_alloc_calls_per_eval: u64,
};

const sample_payloads = [_][]const u8{
    \\{
    \\  "rateLimitsByLimitId": {
    \\    "codex": {
    \\      "limitId": "codex",
    \\      "primary": { "usedPercent": 50, "resetsAt": 2000, "windowDurationMins": 10080 },
    \\      "secondary": { "usedPercent": 80, "resetsAt": 1200, "windowDurationMins": 300 }
    \\    }
    \\  }
    \\}
    ,
    \\{
    \\  "rateLimitsByLimitId": {
    \\    "codex": {
    \\      "limitId": "codex",
    \\      "primary": { "usedPercent": 93, "resetsAt": 1710000000, "windowDurationMins": 10080 },
    \\      "secondary": { "usedPercent": 86, "resetsAt": 1700003600, "windowDurationMins": 300 }
    \\    }
    \\  }
    \\}
    ,
    \\{
    \\  "rateLimits": {
    \\    "limitId": "fallback",
    \\    "primary": { "usedPercent": 12, "resetsAt": 1700007200, "windowDurationMins": 300 }
    \\  }
    \\}
    ,
};

const CountingAllocator = core_perf.CountingAllocator;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    if (try core_cli.handleDefaultHelpAndVersion(argv, UsageText, Version)) return;

    var cli = try parseCliOptions(allocator);
    defer freeCliOptions(allocator, &cli);

    const config = try loadConfig(allocator, cli.config_path);
    if (config.rounds < 3) return error.InvalidRounds;
    if (config.iterations < 100) return error.InvalidIterations;

    const summary = try benchmarkGovernor(allocator, config.iterations, config.rounds);
    const trend_tolerance_pct = cli.trend_tolerance_override orelse config.trend_tolerance_pct;
    const previous_artifact = if (cli.artifact_path) |artifact_path|
        try loadArtifact(allocator, artifact_path)
    else
        null;

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("rounds={d}\n", .{summary.rounds});
    try stdout.print("eval_count={d}\n", .{summary.eval_count});
    try stdout.print("p50_ns_per_eval={d}\n", .{summary.p50_ns_per_eval});
    try stdout.print("p95_ns_per_eval={d}\n", .{summary.p95_ns_per_eval});
    try stdout.print("p50_alloc_calls_per_eval={d}\n", .{summary.p50_alloc_calls_per_eval});
    if (previous_artifact) |artifact| {
        try stdout.print("trend_previous_p95_ns_per_eval={d}\n", .{artifact.p95_ns_per_eval});
        try stdout.print("trend_previous_p50_alloc_calls_per_eval={d}\n", .{artifact.p50_alloc_calls_per_eval});
        try stdout.print("trend_tolerance_pct={d:.2}\n", .{trend_tolerance_pct});
    }

    if (!cli.report_only) {
        if (summary.p95_ns_per_eval > config.max_p95_ns_per_eval) return error.PerfGateFailed;
        if (summary.p50_alloc_calls_per_eval > config.max_p50_alloc_calls_per_eval) return error.AllocGateFailed;
        if (previous_artifact) |artifact| {
            try enforceTrendGate(summary, artifact, trend_tolerance_pct);
        }
    }

    if (cli.artifact_path) |artifact_path| {
        try writeArtifact(artifact_path, summary);
    }
    try stdout.writeAll("status=PASS\n");
}

fn parseCliOptions(allocator: std.mem.Allocator) !CliOptions {
    var out = CliOptions{
        .config_path = try allocator.dupe(u8, "perf/budget_governor/workload_config.json"),
    };

    var args = std.process.args();
    _ = args.next();

    while (args.next()) |arg| {
        if (core_cli.isHelpArg(arg)) {
            var stdout_writer = std.fs.File.stdout().writer(&.{});
            const stdout = &stdout_writer.interface;
            try core_cli.printHelpWithVersion(stdout, UsageText, Version);
            std.process.exit(0);
        }
        if (core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) {
            var stdout_writer = std.fs.File.stdout().writer(&.{});
            const stdout = &stdout_writer.interface;
            try core_cli.printVersion(stdout, Version);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--config")) {
            const path = args.next() orelse return error.MissingConfigPath;
            allocator.free(out.config_path);
            out.config_path = try allocator.dupe(u8, path);
            continue;
        }
        if (std.mem.eql(u8, arg, "--artifact")) {
            const path = args.next() orelse return error.MissingArtifactPath;
            if (out.artifact_path) |existing| allocator.free(existing);
            out.artifact_path = try allocator.dupe(u8, path);
            continue;
        }
        if (std.mem.eql(u8, arg, "--trend-tolerance-pct")) {
            const value = args.next() orelse return error.MissingTrendTolerance;
            out.trend_tolerance_override = try std.fmt.parseFloat(f64, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--report-only")) {
            out.report_only = true;
            continue;
        }

        return error.UnknownArgument;
    }

    return out;
}

fn freeCliOptions(allocator: std.mem.Allocator, cli: *CliOptions) void {
    allocator.free(cli.config_path);
    if (cli.artifact_path) |path| allocator.free(path);
}

fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !PerfConfig {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidConfig,
    };

    var out = PerfConfig{};
    if (root.get("iterations")) |v| out.iterations = try core_perf.intFieldToUsize(v);
    if (root.get("rounds")) |v| out.rounds = try core_perf.intFieldToUsize(v);
    if (root.get("max_p95_ns_per_eval")) |v| out.max_p95_ns_per_eval = try core_perf.intFieldToU64(v);
    if (root.get("max_p50_alloc_calls_per_eval")) |v| out.max_p50_alloc_calls_per_eval = try core_perf.intFieldToU64(v);
    if (root.get("trend_tolerance_pct")) |v| out.trend_tolerance_pct = try core_perf.floatFieldToF64(v);
    return out;
}

fn benchmarkGovernor(allocator: std.mem.Allocator, iterations: usize, rounds: usize) !PerfSummary {
    const ns_per_eval_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(ns_per_eval_samples);
    const alloc_calls_per_eval_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(alloc_calls_per_eval_samples);

    var eval_count: ?usize = null;
    for (0..rounds) |i| {
        const round = try runRound(iterations);
        const eval_count_u64: u64 = @intCast(round.eval_count);
        if (eval_count_u64 == 0) return error.EmptyRound;
        ns_per_eval_samples[i] = @divFloor(round.elapsed_ns, eval_count_u64);
        alloc_calls_per_eval_samples[i] = @divFloor(round.alloc_calls, eval_count_u64);
        eval_count = round.eval_count;
    }

    return .{
        .rounds = rounds,
        .eval_count = eval_count orelse 0,
        .p50_ns_per_eval = try core_perf.percentileU64(allocator, ns_per_eval_samples, 50),
        .p95_ns_per_eval = try core_perf.percentileU64(allocator, ns_per_eval_samples, 95),
        .p50_alloc_calls_per_eval = try core_perf.percentileU64(allocator, alloc_calls_per_eval_samples, 50),
    };
}

fn runRound(iterations: usize) !RoundStats {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();

    var counting = CountingAllocator.init(gpa_state.allocator());
    const alloc = counting.allocator();

    var timer = try std.time.Timer.start();
    var ok_count: usize = 0;
    for (0..iterations) |i| {
        const payload = sample_payloads[i % sample_payloads.len];
        const out = try governor.computeBudgetGovernorFromSlice(alloc, payload, 1_700_000_000);
        if (out.ok) ok_count += 1;
    }
    const elapsed_ns = timer.read();
    if (ok_count == 0) return error.AllEvaluationsFailed;

    return .{
        .elapsed_ns = elapsed_ns,
        .eval_count = iterations,
        .alloc_calls = counting.stats.totalCalls(),
    };
}

fn enforceTrendGate(summary: PerfSummary, previous: BenchmarkArtifact, tolerance_pct: f64) !void {
    const max_p95_ns_per_eval = core_perf.allowedUpperBoundWithTolerance(previous.p95_ns_per_eval, tolerance_pct);
    const max_p50_alloc_calls_per_eval = core_perf.allowedUpperBoundWithTolerance(previous.p50_alloc_calls_per_eval, tolerance_pct);

    if (summary.p95_ns_per_eval > max_p95_ns_per_eval) return error.TrendRegression;
    if (summary.p50_alloc_calls_per_eval > max_p50_alloc_calls_per_eval) return error.TrendRegression;
}

fn loadArtifact(allocator: std.mem.Allocator, path: []const u8) !?BenchmarkArtifact {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    const p95_value = root.get("p95_ns_per_eval") orelse return null;
    const alloc_calls_value = root.get("p50_alloc_calls_per_eval") orelse return null;

    return .{
        .p95_ns_per_eval = core_perf.valueToU64(p95_value) orelse return null,
        .p50_alloc_calls_per_eval = core_perf.valueToU64(alloc_calls_value) orelse return null,
    };
}

fn writeArtifact(path: []const u8, summary: PerfSummary) !void {
    if (std.fs.path.dirname(path)) |dir_path| {
        if (dir_path.len > 0) try std.fs.cwd().makePath(dir_path);
    }

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var writer = file.writer(&.{});
    const out = &writer.interface;
    try out.print(
        "{{\n  \"captured_unix_s\": {d},\n  \"p95_ns_per_eval\": {d},\n  \"p50_alloc_calls_per_eval\": {d}\n}}\n",
        .{
            std.time.timestamp(),
            summary.p95_ns_per_eval,
            summary.p50_alloc_calls_per_eval,
        },
    );
}

test "enforceTrendGate accepts values within tolerance" {
    const previous = BenchmarkArtifact{
        .p95_ns_per_eval = 1000,
        .p50_alloc_calls_per_eval = 10,
    };
    const summary = PerfSummary{
        .rounds = 9,
        .eval_count = 100,
        .p50_ns_per_eval = 900,
        .p95_ns_per_eval = 1150,
        .p50_alloc_calls_per_eval = 11,
    };
    try enforceTrendGate(summary, previous, 20.0);
}

test "enforceTrendGate rejects values outside tolerance" {
    const previous = BenchmarkArtifact{
        .p95_ns_per_eval = 1000,
        .p50_alloc_calls_per_eval = 10,
    };
    const summary = PerfSummary{
        .rounds = 9,
        .eval_count = 100,
        .p50_ns_per_eval = 900,
        .p95_ns_per_eval = 1250,
        .p50_alloc_calls_per_eval = 13,
    };
    try std.testing.expectError(error.TrendRegression, enforceTrendGate(summary, previous, 20.0));
}
