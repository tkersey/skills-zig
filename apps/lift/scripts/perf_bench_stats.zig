const std = @import("std");
const bench_stats = @import("bench_stats.zig");
const core_perf = @import("core_perf");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "lift-perf-bench-stats",
    .help_text = UsageText,
};
const UsageText =
    \\lift-perf-bench-stats
    \\
    \\Performance harness for bench_stats parser.
    \\
    \\Usage:
    \\  lift-perf-bench-stats [options]
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
    iterations: usize = 25_000,
    rounds: usize = 9,
    max_p95_ns_per_line: u64 = 2_000,
    max_p50_alloc_calls_per_round: u64 = 40,
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
    line_count: usize,
    alloc_calls: u64,
};

const PerfSummary = struct {
    rounds: usize,
    line_count: usize,
    p50_ns_per_line: u64,
    p95_ns_per_line: u64,
    p50_alloc_calls_per_round: u64,
};

const BenchmarkArtifact = struct {
    p95_ns_per_line: u64,
    p50_alloc_calls_per_round: u64,
};

const sample_lines = [_][]const u8{
    "p50=1.245ms p95=3.120ms p99=4.980ms",
    "throughput=12450.5 req/s",
    "latency_us=992.4 retries=1",
    "alloc_bytes=4096 peak=8192",
};

const sample_value_counts = [_]usize{ 3, 1, 2, 2 };

const CountingAllocator = core_perf.CountingAllocator;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    var cli = parseCliOptions(allocator) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    defer freeCliOptions(allocator, &cli);

    const config = loadConfig(allocator, cli.config_path) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), cli.config_path);
    };
    if (config.rounds < 3) core_cli.exitUsageFailure(HelpSurface, Version, "InvalidRounds", cli.config_path);
    if (config.iterations < 100) core_cli.exitUsageFailure(HelpSurface, Version, "InvalidIterations", cli.config_path);

    const summary = try benchmarkBenchStats(allocator, config.iterations, config.rounds);
    const trend_tolerance_pct = cli.trend_tolerance_override orelse config.trend_tolerance_pct;
    const previous_artifact = if (cli.artifact_path) |artifact_path|
        try loadArtifact(allocator, artifact_path)
    else
        null;

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("rounds={d}\n", .{summary.rounds});
    try stdout.print("line_count={d}\n", .{summary.line_count});
    try stdout.print("p50_ns_per_line={d}\n", .{summary.p50_ns_per_line});
    try stdout.print("p95_ns_per_line={d}\n", .{summary.p95_ns_per_line});
    try stdout.print("p50_alloc_calls_per_round={d}\n", .{summary.p50_alloc_calls_per_round});
    if (previous_artifact) |artifact| {
        try stdout.print("trend_previous_p95_ns_per_line={d}\n", .{artifact.p95_ns_per_line});
        try stdout.print("trend_previous_p50_alloc_calls_per_round={d}\n", .{artifact.p50_alloc_calls_per_round});
        try stdout.print("trend_tolerance_pct={d:.2}\n", .{trend_tolerance_pct});
    }

    if (!cli.report_only) {
        if (summary.p95_ns_per_line > config.max_p95_ns_per_line) return error.PerfGateFailed;
        if (summary.p50_alloc_calls_per_round > config.max_p50_alloc_calls_per_round) return error.AllocGateFailed;
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
        .config_path = try allocator.dupe(u8, "perf/bench_stats/workload_config.json"),
    };

    var args = std.process.args();
    _ = args.next();

    while (args.next()) |arg| {
        if (core_cli.isHelpArg(arg)) {
            var stdout_writer = std.fs.File.stdout().writer(&.{});
            const stdout = &stdout_writer.interface;
            try core_cli.printHelpSurface(stdout, HelpSurface, Version);
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
    if (root.get("max_p95_ns_per_line")) |v| out.max_p95_ns_per_line = try core_perf.intFieldToU64(v);
    if (root.get("max_p50_alloc_calls_per_round")) |v| out.max_p50_alloc_calls_per_round = try core_perf.intFieldToU64(v);
    if (root.get("trend_tolerance_pct")) |v| out.trend_tolerance_pct = try core_perf.floatFieldToF64(v);
    return out;
}

fn benchmarkBenchStats(allocator: std.mem.Allocator, iterations: usize, rounds: usize) !PerfSummary {
    var ns_per_line_samples: std.ArrayList(u64) = .empty;
    defer ns_per_line_samples.deinit(allocator);
    try ns_per_line_samples.ensureTotalCapacity(allocator, rounds);

    var alloc_calls_samples: std.ArrayList(u64) = .empty;
    defer alloc_calls_samples.deinit(allocator);
    try alloc_calls_samples.ensureTotalCapacity(allocator, rounds);

    var line_count: usize = 0;
    var round_idx: usize = 0;
    while (round_idx < rounds) : (round_idx += 1) {
        const stats = try runRound(allocator, iterations);
        line_count = stats.line_count;
        try ns_per_line_samples.append(allocator, divideRounded(stats.elapsed_ns, stats.line_count));
        try alloc_calls_samples.append(allocator, stats.alloc_calls);
    }

    std.mem.sort(u64, ns_per_line_samples.items, {}, comptime std.sort.asc(u64));
    std.mem.sort(u64, alloc_calls_samples.items, {}, comptime std.sort.asc(u64));

    return .{
        .rounds = rounds,
        .line_count = line_count,
        .p50_ns_per_line = percentileNearestRank(ns_per_line_samples.items, 50.0),
        .p95_ns_per_line = percentileNearestRank(ns_per_line_samples.items, 95.0),
        .p50_alloc_calls_per_round = percentileNearestRank(alloc_calls_samples.items, 50.0),
    };
}

fn runRound(allocator: std.mem.Allocator, iterations: usize) !RoundStats {
    var counting = CountingAllocator.init(allocator);
    const bench_allocator = counting.allocator();

    var values: std.ArrayList(f64) = .empty;
    defer values.deinit(bench_allocator);
    try values.ensureTotalCapacity(bench_allocator, expectedParsedValueCount(iterations));

    const start_ns = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const line = sample_lines[i % sample_lines.len];
        try bench_stats.parseNumbersFromLine(line, true, bench_allocator, &values);
    }
    std.mem.sort(f64, values.items, {}, comptime std.sort.asc(f64));
    const elapsed_ns_signed = std.time.nanoTimestamp() - start_ns;
    const elapsed_ns: u64 = @intCast(if (elapsed_ns_signed > 0) elapsed_ns_signed else 1);

    return .{
        .elapsed_ns = elapsed_ns,
        .line_count = iterations,
        .alloc_calls = counting.stats.totalCalls(),
    };
}

fn expectedParsedValueCount(iterations: usize) usize {
    const full_cycles = iterations / sample_lines.len;
    const remainder = iterations % sample_lines.len;

    var total: usize = full_cycles * 8;
    var i: usize = 0;
    while (i < remainder) : (i += 1) {
        total += sample_value_counts[i];
    }
    return total;
}

fn divideRounded(numerator: u64, denominator: usize) u64 {
    if (denominator == 0) return 0;
    const denominator_u64: u64 = @intCast(denominator);
    return (numerator + (denominator_u64 / 2)) / denominator_u64;
}

fn percentileNearestRank(sorted: []const u64, percentile: f64) u64 {
    if (sorted.len == 0) return 0;
    const pct = std.math.clamp(percentile, 0.0, 100.0);
    const rank_f = std.math.ceil((pct / 100.0) * @as(f64, @floatFromInt(sorted.len)));
    var rank: usize = @intFromFloat(rank_f);
    if (rank == 0) rank = 1;
    if (rank > sorted.len) rank = sorted.len;
    return sorted[rank - 1];
}

fn enforceTrendGate(summary: PerfSummary, previous: BenchmarkArtifact, tolerance_pct: f64) !void {
    const allowed_p95 = allowedWithTolerance(previous.p95_ns_per_line, tolerance_pct);
    if (summary.p95_ns_per_line > allowed_p95) return error.TrendPerfGateFailed;

    const allowed_allocs = allowedWithTolerance(previous.p50_alloc_calls_per_round, tolerance_pct);
    if (summary.p50_alloc_calls_per_round > allowed_allocs) return error.TrendAllocGateFailed;
}

fn allowedWithTolerance(base: u64, tolerance_pct: f64) u64 {
    return core_perf.allowedUpperBoundWithTolerance(base, tolerance_pct);
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
        else => return error.InvalidArtifact,
    };

    const p95_val = root.get("p95_ns_per_line") orelse return error.InvalidArtifact;
    const alloc_val = root.get("p50_alloc_calls_per_round") orelse return error.InvalidArtifact;

    return .{
        .p95_ns_per_line = try core_perf.intFieldToU64(p95_val),
        .p50_alloc_calls_per_round = try core_perf.intFieldToU64(alloc_val),
    };
}

fn writeArtifact(path: []const u8, summary: PerfSummary) !void {
    var payload: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(
        &payload,
        "{{\"p95_ns_per_line\":{d},\"p50_alloc_calls_per_round\":{d}}}\n",
        .{ summary.p95_ns_per_line, summary.p50_alloc_calls_per_round },
    );
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = rendered,
    });
}

test "trend gate accepts within tolerance" {
    const summary = PerfSummary{
        .rounds = 9,
        .line_count = 1_000,
        .p50_ns_per_line = 410,
        .p95_ns_per_line = 500,
        .p50_alloc_calls_per_round = 24,
    };
    const previous = BenchmarkArtifact{
        .p95_ns_per_line = 480,
        .p50_alloc_calls_per_round = 20,
    };
    try enforceTrendGate(summary, previous, 25.0);
}

test "trend gate rejects p95 regression" {
    const summary = PerfSummary{
        .rounds = 9,
        .line_count = 1_000,
        .p50_ns_per_line = 450,
        .p95_ns_per_line = 800,
        .p50_alloc_calls_per_round = 20,
    };
    const previous = BenchmarkArtifact{
        .p95_ns_per_line = 500,
        .p50_alloc_calls_per_round = 20,
    };
    try std.testing.expectError(error.TrendPerfGateFailed, enforceTrendGate(summary, previous, 20.0));
}

test "trend gate rejects alloc regression" {
    const summary = PerfSummary{
        .rounds = 9,
        .line_count = 1_000,
        .p50_ns_per_line = 450,
        .p95_ns_per_line = 500,
        .p50_alloc_calls_per_round = 30,
    };
    const previous = BenchmarkArtifact{
        .p95_ns_per_line = 500,
        .p50_alloc_calls_per_round = 20,
    };
    try std.testing.expectError(error.TrendAllocGateFailed, enforceTrendGate(summary, previous, 20.0));
}

test "benchmark summary has sane values" {
    const summary = try benchmarkBenchStats(std.testing.allocator, 500, 3);
    try std.testing.expectEqual(@as(usize, 3), summary.rounds);
    try std.testing.expectEqual(@as(usize, 500), summary.line_count);
    try std.testing.expect(summary.p95_ns_per_line >= summary.p50_ns_per_line);
}
