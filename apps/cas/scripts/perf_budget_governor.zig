const std = @import("std");
const governor = @import("budget_governor.zig");
const core_perf = @import("core_perf");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas-perf-budget-governor",
    .help_text = UsageText,
};
const UsageText =
    \\cas-perf-budget-governor
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
    action: enum { run, help, version } = .run,
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

pub fn main(init: std.process.Init) !void {
    const code = try run(init);
    if (code != 0) std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const dir = std.Io.Dir.cwd();
    var help_writer = std.Io.File.stdout().writer(io, &.{});
    var error_writer = std.Io.File.stderr().writer(io, &.{});
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(
        &help_writer.interface,
        argv,
        HelpSurface,
        Version,
    )) return 0;

    var cli = parseCliOptions(allocator, argv) catch |err| {
        try core_cli.printUsageFailureWithHelp(
            &error_writer.interface,
            HelpSurface,
            Version,
            @errorName(err),
            null,
        );
        return 2;
    };
    defer freeCliOptions(allocator, &cli);
    switch (cli.action) {
        .help => {
            try core_cli.printHelpSurface(&help_writer.interface, HelpSurface, Version);
            return 0;
        },
        .version => {
            try core_cli.printVersion(&help_writer.interface, Version);
            return 0;
        },
        .run => {},
    }

    const config = loadConfig(io, dir, allocator, cli.config_path) catch |err| {
        try core_cli.printUsageFailureWithHelp(
            &error_writer.interface,
            HelpSurface,
            Version,
            @errorName(err),
            cli.config_path,
        );
        return 2;
    };
    if (config.rounds < 3 or config.iterations < 100) {
        try core_cli.printUsageFailureWithHelp(
            &error_writer.interface,
            HelpSurface,
            Version,
            if (config.rounds < 3) "InvalidRounds" else "InvalidIterations",
            cli.config_path,
        );
        return 2;
    }

    return runBenchmark(io, dir, allocator, cli, config);
}

fn runBenchmark(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    cli: CliOptions,
    config: PerfConfig,
) !u8 {
    const summary = try benchmarkGovernor(io, allocator, config.iterations, config.rounds);
    const trend_tolerance_pct = cli.trend_tolerance_override orelse config.trend_tolerance_pct;
    const previous_artifact = if (cli.artifact_path) |artifact_path|
        try loadArtifact(io, dir, allocator, artifact_path)
    else
        null;

    var stdout_writer = std.Io.File.stdout().writer(
        io,
        &.{},
    );
    const stdout = &stdout_writer.interface;
    try stdout.print("rounds={d}\n", .{summary.rounds});
    try stdout.print("eval_count={d}\n", .{summary.eval_count});
    try stdout.print("p50_ns_per_eval={d}\n", .{summary.p50_ns_per_eval});
    try stdout.print("p95_ns_per_eval={d}\n", .{summary.p95_ns_per_eval});
    try stdout.print("p50_alloc_calls_per_eval={d}\n", .{summary.p50_alloc_calls_per_eval});
    if (previous_artifact) |artifact| {
        try stdout.print("trend_previous_p95_ns_per_eval={d}\n", .{artifact.p95_ns_per_eval});
        try stdout.print(
            "trend_previous_p50_alloc_calls_per_eval={d}\n",
            .{artifact.p50_alloc_calls_per_eval},
        );
        try stdout.print("trend_tolerance_pct={d:.2}\n", .{trend_tolerance_pct});
    }

    if (!cli.report_only) {
        if (summary.p95_ns_per_eval > config.max_p95_ns_per_eval) return error.PerfGateFailed;
        if (summary.p50_alloc_calls_per_eval > config.max_p50_alloc_calls_per_eval)
            return error.AllocGateFailed;
        if (previous_artifact) |artifact| {
            try enforceTrendGate(summary, artifact, trend_tolerance_pct);
        }
    }

    if (cli.artifact_path) |artifact_path| {
        try writeArtifact(io, dir, artifact_path, summary);
    }
    try stdout.writeAll("status=PASS\n");
    return 0;
}

fn parseCliOptions(allocator: std.mem.Allocator, argv: []const []const u8) !CliOptions {
    var out = CliOptions{
        .config_path = try allocator.dupe(u8, "perf/budget_governor/workload_config.json"),
    };

    errdefer freeCliOptions(allocator, &out);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (core_cli.isHelpArg(arg)) {
            out.action = .help;
            return out;
        }
        if (core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) {
            out.action = .version;
            return out;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= argv.len) return error.MissingConfigPath;
            const path = argv[i];
            const owned = try allocator.dupe(u8, path);
            allocator.free(out.config_path);
            out.config_path = owned;
            continue;
        }
        if (std.mem.eql(u8, arg, "--artifact")) {
            i += 1;
            if (i >= argv.len) return error.MissingArtifactPath;
            const path = argv[i];
            const owned = try allocator.dupe(u8, path);
            if (out.artifact_path) |existing| allocator.free(existing);
            out.artifact_path = owned;
            continue;
        }
        if (std.mem.eql(u8, arg, "--trend-tolerance-pct")) {
            i += 1;
            if (i >= argv.len) return error.MissingTrendTolerance;
            const value = argv[i];
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

fn loadConfig(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    path: []const u8,
) !PerfConfig {
    const data = try dir.readFileAlloc(
        io,
        path,
        allocator,
        .limited(1 * 1024 * 1024),
    );
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
    if (root.get("max_p95_ns_per_eval")) |v|
        out.max_p95_ns_per_eval = try core_perf.intFieldToU64(v);
    if (root.get("max_p50_alloc_calls_per_eval")) |v|
        out.max_p50_alloc_calls_per_eval = try core_perf.intFieldToU64(v);
    if (root.get("trend_tolerance_pct")) |v|
        out.trend_tolerance_pct = try core_perf.floatFieldToF64(v);
    return out;
}

fn benchmarkGovernor(
    io: std.Io,
    allocator: std.mem.Allocator,
    iterations: usize,
    rounds: usize,
) !PerfSummary {
    const ns_per_eval_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(ns_per_eval_samples);
    const alloc_calls_per_eval_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(alloc_calls_per_eval_samples);

    var eval_count: ?usize = null;
    for (0..rounds) |i| {
        const round = try runRound(io, iterations);
        const eval_count_u64: u64 = @intCast(round.eval_count);
        if (eval_count_u64 == 0) return error.EmptyRound;
        ns_per_eval_samples[i] = @divFloor(round.elapsed_ns, eval_count_u64);
        alloc_calls_per_eval_samples[i] = @divFloor(round.alloc_calls, eval_count_u64);
        eval_count = round.eval_count;
    }

    const latency = try core_perf.percentilesU64(allocator, ns_per_eval_samples, &.{ 50, 95 });
    return .{
        .rounds = rounds,
        .eval_count = eval_count orelse 0,
        .p50_ns_per_eval = latency[0],
        .p95_ns_per_eval = latency[1],
        .p50_alloc_calls_per_eval = try core_perf.percentileU64(
            allocator,
            alloc_calls_per_eval_samples,
            50,
        ),
    };
}

fn runRound(io: std.Io, iterations: usize) !RoundStats {
    var gpa_state: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer std.debug.assert(gpa_state.deinit() == 0);

    var counting = CountingAllocator.init(gpa_state.allocator());
    const alloc = counting.allocator();

    const start_ns =
        std.Io.Clock.awake.now(io).nanoseconds;
    var ok_count: usize = 0;
    for (0..iterations) |i| {
        const payload = sample_payloads[i % sample_payloads.len];
        var out = try governor.computeBudgetGovernorFromSlice(alloc, payload, 1_700_000_000);
        defer out.deinit();
        if (out.value.ok) ok_count += 1;
    }
    const elapsed_ns: u64 = @intCast(@max(
        std.Io.Clock.awake.now(io).nanoseconds - start_ns,
        1,
    ));
    if (ok_count == 0) return error.AllEvaluationsFailed;

    return .{
        .elapsed_ns = elapsed_ns,
        .eval_count = iterations,
        .alloc_calls = counting.stats.totalCalls(),
    };
}

fn enforceTrendGate(summary: PerfSummary, previous: BenchmarkArtifact, tolerance_pct: f64) !void {
    const max_p95_ns_per_eval = core_perf.allowedUpperBoundWithTolerance(
        previous.p95_ns_per_eval,
        tolerance_pct,
    );
    const max_p50_alloc_calls_per_eval = core_perf.allowedUpperBoundWithTolerance(
        previous.p50_alloc_calls_per_eval,
        tolerance_pct,
    );

    if (summary.p95_ns_per_eval > max_p95_ns_per_eval) return error.TrendRegression;
    if (summary.p50_alloc_calls_per_eval > max_p50_alloc_calls_per_eval)
        return error.TrendRegression;
}

fn loadArtifact(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    path: []const u8,
) !?BenchmarkArtifact {
    const data = dir.readFileAlloc(
        io,
        path,
        allocator,
        .limited(1 * 1024 * 1024),
    ) catch |err| switch (err) {
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

fn writeArtifact(io: std.Io, dir: std.Io.Dir, path: []const u8, summary: PerfSummary) !void {
    if (std.fs.path.dirname(path)) |dir_path| {
        if (dir_path.len > 0) try dir.createDirPath(io, dir_path);
    }

    const file = try dir.createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var writer = file.writer(io, &.{});
    const out = &writer.interface;
    try out.print(
        "{{\n  \"captured_unix_s\": {d},\n  \"p95_ns_per_eval\": {d},\n  \"" ++
            "p50_alloc_calls_per_eval\": {d}\n}}\n",
        .{
            @as(
                i64,
                @intCast(@divFloor(
                    std.Io.Clock.real.now(io).nanoseconds,
                    1_000_000_000,
                )),
            ),
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

test "benchmarkGovernor summarizes captured rounds and retains empty-round errors" {
    const summary = try benchmarkGovernor(std.testing.io, std.testing.allocator, 1, 3);
    try std.testing.expectEqual(@as(usize, 3), summary.rounds);
    try std.testing.expectEqual(@as(usize, 1), summary.eval_count);
    try std.testing.expect(summary.p50_ns_per_eval <= summary.p95_ns_per_eval);
    try std.testing.expect(summary.p50_alloc_calls_per_eval > 0);
    try std.testing.expectError(
        error.EmptySamples,
        benchmarkGovernor(std.testing.io, std.testing.allocator, 1, 0),
    );
}
