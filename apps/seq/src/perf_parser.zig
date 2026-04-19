const std = @import("std");
const token_events = @import("datasets/token_events.zig");
const core_perf = @import("core_perf");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "seq-perf-parser",
    .help_text = UsageText,
};
const UsageText =
    \\perf_parser.zig
    \\
    \\Performance harness for seq token parser.
    \\
    \\Usage:
    \\  seq-perf-parser [options]
    \\
    \\Options:
    \\  --config PATH               Override config file path.
    \\  --artifact PATH             Read/write benchmark artifact.
    \\  --real-corpus-dir PATH      Benchmark using corpus JSONL files.
    \\  --trend-tolerance-pct N     Override trend tolerance percent.
    \\  --report-only               Skip failure gates.
    \\  --help                      Show help.
    \\  --version                   Show version.
    \\  version                     Show version.
;

const ParserPerfConfig = struct {
    lines: usize = 20_000,
    rounds: usize = 9,
    min_speedup_pct: f64 = 10.0,
    min_alloc_reduction_pct: f64 = 60.0,
    trend_tolerance_pct: f64 = 20.0,
};

const CliOptions = struct {
    config_path: []u8,
    artifact_path: ?[]u8 = null,
    real_corpus_dir: ?[]u8 = null,
    trend_tolerance_override: ?f64 = null,
    report_only: bool = false,
};

const RoundStats = struct {
    elapsed_ns: u64,
    row_count: usize,
    alloc_calls: u64,
    alloc_bytes: u64,
};

const PerfSummary = struct {
    mode: []const u8,
    rounds: usize,
    baseline_rows: usize,
    fast_rows: usize,
    baseline_p50_ns: u64,
    fast_p50_ns: u64,
    speedup_pct: f64,
    baseline_p50_alloc_calls: u64,
    fast_p50_alloc_calls: u64,
    alloc_call_reduction_pct: f64,
    baseline_p50_alloc_bytes: u64,
    fast_p50_alloc_bytes: u64,
    alloc_bytes_reduction_pct: f64,
    baseline_p50_ns_per_line: u64,
    baseline_p95_ns_per_line: u64,
    fast_p50_ns_per_line: u64,
    fast_p95_ns_per_line: u64,
};

const BenchmarkArtifact = struct {
    speedup_pct: f64,
    alloc_call_reduction_pct: f64,
    fast_p95_ns_per_line: u64,
};

const BaselineRow = struct {
    total_tokens: ?i64 = null,
};

const CountingAllocator = core_perf.CountingAllocator;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    var cli = try parseCliOptions(allocator, argv);
    defer freeCliOptions(allocator, &cli);

    const config = try loadConfig(allocator, cli.config_path);
    if (config.rounds < 3) return error.InvalidRounds;
    if (config.lines < 100) return error.InvalidLineCount;

    const mode: []const u8 = if (cli.real_corpus_dir != null) "corpus" else "synthetic";

    const content = if (cli.real_corpus_dir) |corpus_dir|
        try loadRealCorpusJsonl(allocator, corpus_dir)
    else
        try buildSyntheticTokenEvents(allocator, config.lines);
    defer allocator.free(content);

    const summary = try benchmarkParser(allocator, content, mode, config.rounds);

    const trend_tolerance_pct = cli.trend_tolerance_override orelse config.trend_tolerance_pct;
    const previous_artifact = if (cli.artifact_path) |artifact_path|
        try loadArtifact(allocator, artifact_path)
    else
        null;

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    try stdout.print("mode={s}\n", .{summary.mode});
    try stdout.print("rounds={d}\n", .{summary.rounds});
    try stdout.print("baseline_rows={d}\n", .{summary.baseline_rows});
    try stdout.print("fast_rows={d}\n", .{summary.fast_rows});
    try stdout.print("baseline_p50_ns={d}\n", .{summary.baseline_p50_ns});
    try stdout.print("fast_p50_ns={d}\n", .{summary.fast_p50_ns});
    try stdout.print("speedup_pct={d:.2}\n", .{summary.speedup_pct});
    try stdout.print("baseline_p50_alloc_calls={d}\n", .{summary.baseline_p50_alloc_calls});
    try stdout.print("fast_p50_alloc_calls={d}\n", .{summary.fast_p50_alloc_calls});
    try stdout.print("alloc_call_reduction_pct={d:.2}\n", .{summary.alloc_call_reduction_pct});
    try stdout.print("baseline_p50_alloc_bytes={d}\n", .{summary.baseline_p50_alloc_bytes});
    try stdout.print("fast_p50_alloc_bytes={d}\n", .{summary.fast_p50_alloc_bytes});
    try stdout.print("alloc_bytes_reduction_pct={d:.2}\n", .{summary.alloc_bytes_reduction_pct});
    try stdout.print("baseline_p50_ns_per_line={d}\n", .{summary.baseline_p50_ns_per_line});
    try stdout.print("baseline_p95_ns_per_line={d}\n", .{summary.baseline_p95_ns_per_line});
    try stdout.print("fast_p50_ns_per_line={d}\n", .{summary.fast_p50_ns_per_line});
    try stdout.print("fast_p95_ns_per_line={d}\n", .{summary.fast_p95_ns_per_line});

    if (previous_artifact) |artifact| {
        try stdout.print("trend_previous_speedup_pct={d:.2}\n", .{artifact.speedup_pct});
        try stdout.print("trend_previous_alloc_call_reduction_pct={d:.2}\n", .{artifact.alloc_call_reduction_pct});
        try stdout.print("trend_tolerance_pct={d:.2}\n", .{trend_tolerance_pct});
    }

    if (!cli.report_only) {
        if (summary.speedup_pct < config.min_speedup_pct) return error.SpeedupGateFailed;
        if (summary.alloc_call_reduction_pct < config.min_alloc_reduction_pct) return error.AllocGateFailed;

        if (previous_artifact) |artifact| {
            try enforceTrendGate(summary, artifact, trend_tolerance_pct);
        }
    }

    if (cli.artifact_path) |artifact_path| {
        try writeArtifact(artifact_path, summary);
    }

    try stdout.writeAll("status=PASS\n");
}

fn parseCliOptions(allocator: std.mem.Allocator, argv: []const []const u8) !CliOptions {
    var out = CliOptions{
        .config_path = try allocator.dupe(u8, "perf/parser/workload_config.json"),
    };

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= argv.len) return error.MissingConfigPath;
            const path = argv[i];
            allocator.free(out.config_path);
            out.config_path = try allocator.dupe(u8, path);
            continue;
        }
        if (std.mem.eql(u8, arg, "--artifact")) {
            i += 1;
            if (i >= argv.len) return error.MissingArtifactPath;
            const path = argv[i];
            if (out.artifact_path) |existing| allocator.free(existing);
            out.artifact_path = try allocator.dupe(u8, path);
            continue;
        }
        if (std.mem.eql(u8, arg, "--real-corpus-dir")) {
            i += 1;
            if (i >= argv.len) return error.MissingCorpusPath;
            const path = argv[i];
            if (out.real_corpus_dir) |existing| allocator.free(existing);
            out.real_corpus_dir = try allocator.dupe(u8, path);
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
    if (cli.real_corpus_dir) |path| allocator.free(path);
}

fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !ParserPerfConfig {
    const data = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
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

    var out = ParserPerfConfig{};
    if (root.get("lines")) |v| out.lines = try core_perf.intFieldToUsize(v);
    if (root.get("rounds")) |v| out.rounds = try core_perf.intFieldToUsize(v);
    if (root.get("min_speedup_pct")) |v| out.min_speedup_pct = try core_perf.floatFieldToF64(v);
    if (root.get("min_alloc_reduction_pct")) |v| out.min_alloc_reduction_pct = try core_perf.floatFieldToF64(v);
    if (root.get("trend_tolerance_pct")) |v| out.trend_tolerance_pct = try core_perf.floatFieldToF64(v);
    return out;
}

fn benchmarkParser(
    allocator: std.mem.Allocator,
    content: []const u8,
    mode: []const u8,
    rounds: usize,
) !PerfSummary {
    const baseline_ns_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(baseline_ns_samples);
    const fast_ns_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(fast_ns_samples);

    const baseline_alloc_call_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(baseline_alloc_call_samples);
    const fast_alloc_call_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(fast_alloc_call_samples);

    const baseline_alloc_byte_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(baseline_alloc_byte_samples);
    const fast_alloc_byte_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(fast_alloc_byte_samples);

    const baseline_ns_per_line_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(baseline_ns_per_line_samples);
    const fast_ns_per_line_samples = try allocator.alloc(u64, rounds);
    defer allocator.free(fast_ns_per_line_samples);

    var row_count_baseline: ?usize = null;
    var row_count_fast: ?usize = null;

    for (0..rounds) |i| {
        const baseline = try runBaselineRound(content);
        const fast = try runFastRound(content);
        if (baseline.row_count != fast.row_count) return error.RowCountMismatch;
        if (baseline.row_count == 0) return error.EmptyRows;

        const row_count_u64: u64 = @intCast(baseline.row_count);

        baseline_ns_samples[i] = baseline.elapsed_ns;
        fast_ns_samples[i] = fast.elapsed_ns;
        baseline_alloc_call_samples[i] = baseline.alloc_calls;
        fast_alloc_call_samples[i] = fast.alloc_calls;
        baseline_alloc_byte_samples[i] = baseline.alloc_bytes;
        fast_alloc_byte_samples[i] = fast.alloc_bytes;
        baseline_ns_per_line_samples[i] = @divFloor(baseline.elapsed_ns, row_count_u64);
        fast_ns_per_line_samples[i] = @divFloor(fast.elapsed_ns, row_count_u64);

        row_count_baseline = baseline.row_count;
        row_count_fast = fast.row_count;
    }

    const baseline_p50_ns = try core_perf.percentileU64(allocator, baseline_ns_samples, 50);
    const fast_p50_ns = try core_perf.percentileU64(allocator, fast_ns_samples, 50);
    const speedup_pct = reductionPct(baseline_p50_ns, fast_p50_ns);

    const baseline_p50_alloc_calls = try core_perf.percentileU64(allocator, baseline_alloc_call_samples, 50);
    const fast_p50_alloc_calls = try core_perf.percentileU64(allocator, fast_alloc_call_samples, 50);
    const alloc_call_reduction_pct = reductionPct(baseline_p50_alloc_calls, fast_p50_alloc_calls);

    const baseline_p50_alloc_bytes = try core_perf.percentileU64(allocator, baseline_alloc_byte_samples, 50);
    const fast_p50_alloc_bytes = try core_perf.percentileU64(allocator, fast_alloc_byte_samples, 50);
    const alloc_bytes_reduction_pct = reductionPct(baseline_p50_alloc_bytes, fast_p50_alloc_bytes);

    return .{
        .mode = mode,
        .rounds = rounds,
        .baseline_rows = row_count_baseline orelse 0,
        .fast_rows = row_count_fast orelse 0,
        .baseline_p50_ns = baseline_p50_ns,
        .fast_p50_ns = fast_p50_ns,
        .speedup_pct = speedup_pct,
        .baseline_p50_alloc_calls = baseline_p50_alloc_calls,
        .fast_p50_alloc_calls = fast_p50_alloc_calls,
        .alloc_call_reduction_pct = alloc_call_reduction_pct,
        .baseline_p50_alloc_bytes = baseline_p50_alloc_bytes,
        .fast_p50_alloc_bytes = fast_p50_alloc_bytes,
        .alloc_bytes_reduction_pct = alloc_bytes_reduction_pct,
        .baseline_p50_ns_per_line = try core_perf.percentileU64(allocator, baseline_ns_per_line_samples, 50),
        .baseline_p95_ns_per_line = try core_perf.percentileU64(allocator, baseline_ns_per_line_samples, 95),
        .fast_p50_ns_per_line = try core_perf.percentileU64(allocator, fast_ns_per_line_samples, 50),
        .fast_p95_ns_per_line = try core_perf.percentileU64(allocator, fast_ns_per_line_samples, 95),
    };
}

fn enforceTrendGate(summary: PerfSummary, previous: BenchmarkArtifact, tolerance_pct: f64) !void {
    const factor = 1.0 - (tolerance_pct / 100.0);
    const min_speedup = previous.speedup_pct * factor;
    const min_alloc_reduction = previous.alloc_call_reduction_pct * factor;

    if (summary.speedup_pct < min_speedup) return error.TrendRegression;
    if (summary.alloc_call_reduction_pct < min_alloc_reduction) return error.TrendRegression;
}

fn loadArtifact(allocator: std.mem.Allocator, path: []const u8) !?BenchmarkArtifact {
    const data = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
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

    const speedup_value = root.get("speedup_pct") orelse return null;
    const alloc_value = root.get("alloc_call_reduction_pct") orelse return null;
    const p95_value = root.get("fast_p95_ns_per_line") orelse return null;

    return .{
        .speedup_pct = core_perf.valueToF64(speedup_value) orelse return null,
        .alloc_call_reduction_pct = core_perf.valueToF64(alloc_value) orelse return null,
        .fast_p95_ns_per_line = core_perf.valueToU64(p95_value) orelse return null,
    };
}

fn writeArtifact(path: []const u8, summary: PerfSummary) !void {
    if (std.fs.path.dirname(path)) |dir_path| {
        if (dir_path.len > 0) try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir_path);
    }

    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    var writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const out = &writer.interface;
    try out.print(
        "{{\n  \"mode\": \"{s}\",\n  \"captured_unix_s\": {d},\n  \"speedup_pct\": {d:.6},\n  \"alloc_call_reduction_pct\": {d:.6},\n  \"fast_p95_ns_per_line\": {d}\n}}\n",
        .{
            summary.mode,
            @divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, std.time.ns_per_s),
            summary.speedup_pct,
            summary.alloc_call_reduction_pct,
            summary.fast_p95_ns_per_line,
        },
    );
}

fn loadRealCorpusJsonl(allocator: std.mem.Allocator, dir_path: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), dir_path, .{ .iterate = true });
    defer dir.close(std.Io.Threaded.global_single_threaded.io());

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var file_count: usize = 0;
    while (try walker.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;

        const content = try dir.readFileAlloc(
            std.Io.Threaded.global_single_threaded.io(),
            entry.path,
            allocator,
            .limited(64 * 1024 * 1024),
        );
        defer allocator.free(content);
        try out.appendSlice(allocator, content);
        if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        file_count += 1;
    }

    if (file_count == 0) return error.CorpusEmpty;
    return out.toOwnedSlice(allocator);
}

fn runFastRound(content: []const u8) !RoundStats {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();

    var counting = CountingAllocator.init(gpa_state.allocator());
    const alloc = counting.allocator();

    const start_ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    var rows = try token_events.parseTokenEventsWithOptions(alloc, "parser-perf.jsonl", content, .{
        .dedupe = true,
        .derive_timestamp_fields = false,
    });
    const elapsed_ns: u64 = @intCast(@max(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds - start_ns, 1));
    const row_count = rows.items.len;
    rows.deinit(alloc);

    return .{
        .elapsed_ns = elapsed_ns,
        .row_count = row_count,
        .alloc_calls = counting.stats.totalCalls(),
        .alloc_bytes = counting.stats.totalRequestedBytes(),
    };
}

fn runBaselineRound(content: []const u8) !RoundStats {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();

    var counting = CountingAllocator.init(gpa_state.allocator());
    const alloc = counting.allocator();

    const start_ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    const row_count = try parseBaselineTokenEvents(alloc, content, true);
    const elapsed_ns: u64 = @intCast(@max(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds - start_ns, 1));

    return .{
        .elapsed_ns = elapsed_ns,
        .row_count = row_count,
        .alloc_calls = counting.stats.totalCalls(),
        .alloc_bytes = counting.stats.totalRequestedBytes(),
    };
}

fn buildSyntheticTokenEvents(allocator: std.mem.Allocator, line_count: usize) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    for (0..line_count) |i| {
        const total_tokens: i64 = @intCast(5000 + (i / 2));
        const input_tokens = total_tokens - 6;
        const cached_tokens: i64 = @intCast(i % 11);
        const output_tokens: i64 = @intCast(2 + (i % 7));
        const reasoning_tokens: i64 = @intCast(i % 4);
        const last_total_tokens = output_tokens + reasoning_tokens + 1;
        const minute = i % 60;

        try writeSyntheticTokenEventLine(
            &writer.writer,
            minute,
            input_tokens,
            cached_tokens,
            output_tokens,
            reasoning_tokens,
            total_tokens,
            @divTrunc(input_tokens, 2),
            @divTrunc(cached_tokens, 2),
            output_tokens,
            reasoning_tokens,
            last_total_tokens,
        );
    }

    return writer.toOwnedSlice();
}

fn writeSyntheticTokenEventLine(
    writer: anytype,
    minute: usize,
    total_input_tokens: i64,
    total_cached_tokens: i64,
    total_output_tokens: i64,
    total_reasoning_tokens: i64,
    total_tokens: i64,
    last_input_tokens: i64,
    last_cached_tokens: i64,
    last_output_tokens: i64,
    last_reasoning_tokens: i64,
    last_total_tokens: i64,
) !void {
    try writer.writeAll("{\"type\":\"event_msg\",\"timestamp\":\"2026-02-19T10:");
    try writer.print("{d:0>2}", .{minute});
    try writer.writeAll(":00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"model_context_window\":200000,\"total_token_usage\":{\"input_tokens\":");
    try writer.print("{d}", .{total_input_tokens});
    try writer.writeAll(",\"cached_input_tokens\":");
    try writer.print("{d}", .{total_cached_tokens});
    try writer.writeAll(",\"output_tokens\":");
    try writer.print("{d}", .{total_output_tokens});
    try writer.writeAll(",\"reasoning_output_tokens\":");
    try writer.print("{d}", .{total_reasoning_tokens});
    try writer.writeAll(",\"total_tokens\":");
    try writer.print("{d}", .{total_tokens});
    try writer.writeAll("},\"last_token_usage\":{\"input_tokens\":");
    try writer.print("{d}", .{last_input_tokens});
    try writer.writeAll(",\"cached_input_tokens\":");
    try writer.print("{d}", .{last_cached_tokens});
    try writer.writeAll(",\"output_tokens\":");
    try writer.print("{d}", .{last_output_tokens});
    try writer.writeAll(",\"reasoning_output_tokens\":");
    try writer.print("{d}", .{last_reasoning_tokens});
    try writer.writeAll(",\"total_tokens\":");
    try writer.print("{d}", .{last_total_tokens});
    try writer.writeAll("}}}}\n");
}

fn parseBaselineTokenEvents(allocator: std.mem.Allocator, content: []const u8, dedupe: bool) !usize {
    var row_count: usize = 0;
    var prev_total_tokens: ?i64 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const maybe_row = try parseBaselineTokenCountLine(allocator, line);
        const row = maybe_row orelse continue;

        if (dedupe and
            prev_total_tokens != null and
            row.total_tokens != null and
            prev_total_tokens.? == row.total_tokens.?)
        {
            continue;
        }

        if (row.total_tokens) |v| prev_total_tokens = v;
        row_count += 1;
    }

    return row_count;
}

fn parseBaselineTokenCountLine(allocator: std.mem.Allocator, line: []const u8) !?BaselineRow {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "event_msg")) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "token_count")) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "payload")) return null;
    if (trimmed[0] != '{') return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), trimmed, .{}) catch return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    if (!stdJsonFieldEq(root, "type", "event_msg")) return null;
    const payload = stdJsonObjectField(root, "payload") orelse return null;
    if (!stdJsonFieldEq(payload, "type", "token_count")) return null;
    const info = stdJsonObjectField(payload, "info") orelse return null;

    const total_usage = stdJsonObjectField(info, "total_token_usage");
    return .{ .total_tokens = stdJsonIntFieldMaybe(total_usage, "total_tokens") };
}

fn stdJsonFieldEq(obj: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const value = stdJsonStringField(obj, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn stdJsonObjectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |inner| inner,
        else => null,
    };
}

fn stdJsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn stdJsonIntField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn stdJsonIntFieldMaybe(obj: ?std.json.ObjectMap, key: []const u8) ?i64 {
    if (obj == null) return null;
    return stdJsonIntField(obj.?, key);
}

fn reductionPct(baseline: u64, fast: u64) f64 {
    if (baseline == 0) return 0;
    const baseline_f = @as(f64, @floatFromInt(baseline));
    const fast_f = @as(f64, @floatFromInt(fast));
    return ((baseline_f - fast_f) / baseline_f) * 100.0;
}

fn testSummary(speedup_pct: f64, alloc_call_reduction_pct: f64) PerfSummary {
    return .{
        .mode = "synthetic",
        .rounds = 9,
        .baseline_rows = 1,
        .fast_rows = 1,
        .baseline_p50_ns = 10,
        .fast_p50_ns = 5,
        .speedup_pct = speedup_pct,
        .baseline_p50_alloc_calls = 10,
        .fast_p50_alloc_calls = 1,
        .alloc_call_reduction_pct = alloc_call_reduction_pct,
        .baseline_p50_alloc_bytes = 10,
        .fast_p50_alloc_bytes = 1,
        .alloc_bytes_reduction_pct = 90.0,
        .baseline_p50_ns_per_line = 10,
        .baseline_p95_ns_per_line = 10,
        .fast_p50_ns_per_line = 5,
        .fast_p95_ns_per_line = 5,
    };
}

test "parseBaselineTokenCountLine accepts token_count rows without total_token_usage" {
    const line =
        \\{"type":"event_msg","timestamp":"2026-02-19T10:10:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":3}}}}
    ;

    const row = try parseBaselineTokenCountLine(std.testing.allocator, line);
    try std.testing.expect(row != null);
    try std.testing.expectEqual(@as(?i64, null), row.?.total_tokens);
}

test "enforceTrendGate accepts values within tolerance" {
    const previous = BenchmarkArtifact{
        .speedup_pct = 100.0,
        .alloc_call_reduction_pct = 90.0,
        .fast_p95_ns_per_line = 5000,
    };
    const summary = testSummary(85.0, 73.0);
    try enforceTrendGate(summary, previous, 20.0);
}

test "enforceTrendGate rejects regression below tolerance" {
    const previous = BenchmarkArtifact{
        .speedup_pct = 100.0,
        .alloc_call_reduction_pct = 90.0,
        .fast_p95_ns_per_line = 5000,
    };
    const summary = testSummary(79.0, 71.0);
    try std.testing.expectError(error.TrendRegression, enforceTrendGate(summary, previous, 20.0));
}
