const std = @import("std");
const core_io = @import("core_io");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);

const UsageText =
    \\bench_stats.zig
    \\
    \\Summarize benchmark samples with basic statistics and percentiles.
    \\
    \\Usage:
    \\  zig run codex/skills/lift/scripts/bench_stats.zig -- [options]
    \\
    \\Options:
    \\  --input PATH       Input file path (default: stdin)
    \\  --compare PATH     Variant input path for baseline-vs-variant mode
    \\  --scale F64        Scale factor (default: 1.0)
    \\  --unit TEXT        Unit label (default: empty)
    \\  --all              Parse all numbers in each line (default: first only)
    \\  --json             Emit JSON (numbers stay unformatted)
    \\  --ci-samples N     Compare-mode bootstrap sample count (default: 1000; 0 disables)
    \\  --ci-alpha F64     Compare-mode CI alpha (default: 0.05)
    \\  --seed I64         Compare-mode bootstrap RNG seed
    \\  --help             Show help
    \\  --version          Show version
    \\  version            Show version
;

const Config = struct {
    input_path: ?[]const u8 = null,
    compare_path: ?[]const u8 = null,
    scale: f64 = 1.0,
    unit: []const u8 = "",
    parse_all: bool = false,
    output_json: bool = false,
    ci_samples: ?usize = null,
    ci_alpha: f64 = 0.05,
    seed: ?u64 = null,
};

const Report = struct {
    count: usize,
    min: f64,
    p50: f64,
    p90: f64,
    p95: f64,
    p99: f64,
    max: f64,
    mean: f64,
    median: f64,
    stdev: f64,
    unit: []const u8,
};

const DeltaReport = struct {
    min: f64,
    p50: f64,
    p90: f64,
    p95: f64,
    p99: f64,
    max: f64,
    mean: f64,
    median: f64,
    stdev: f64,
};

const DeltaPctReport = struct {
    min: ?f64,
    p50: ?f64,
    p90: ?f64,
    p95: ?f64,
    p99: ?f64,
    max: ?f64,
    mean: ?f64,
    median: ?f64,
    stdev: ?f64,
};

const CiInterval = struct {
    lo: f64,
    hi: f64,
};

const CiDelta = struct {
    p50: ?CiInterval = null,
    p95: ?CiInterval = null,
    p99: ?CiInterval = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (try core_cli.handleDefaultHelpAndVersion(argv, UsageText, Version)) return;

    var cfg = try parseArgs(argv);
    if (cfg.input_path != null and cfg.input_path.?.len == 0) cfg.input_path = null;
    if (cfg.compare_path != null and cfg.compare_path.?.len == 0) cfg.compare_path = null;

    if (cfg.compare_path) |compare_path| {
        const ci_samples = cfg.ci_samples orelse 1000;
        if (!(cfg.ci_alpha > 0.0 and cfg.ci_alpha < 1.0)) {
            try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stderr(), "error: --ci-alpha must be in (0, 1)\n");
            std.process.exit(2);
        }

        const baseline_text = if (cfg.input_path) |path|
            try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize))
        else
            try std.fs.File.stdin().readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(baseline_text);
        const variant_text = try std.fs.cwd().readFileAlloc(allocator, compare_path, std.math.maxInt(usize));
        defer allocator.free(variant_text);

        var baseline_values: std.ArrayList(f64) = .empty;
        defer baseline_values.deinit(allocator);
        var variant_values: std.ArrayList(f64) = .empty;
        defer variant_values.deinit(allocator);

        try parseValuesFromText(baseline_text, cfg.parse_all, cfg.scale, allocator, &baseline_values);
        try parseValuesFromText(variant_text, cfg.parse_all, cfg.scale, allocator, &variant_values);

        if (baseline_values.items.len == 0) {
            try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stdout(), "No numeric baseline samples found.\n");
            std.process.exit(1);
        }
        if (variant_values.items.len == 0) {
            try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stdout(), "No numeric variant samples found.\n");
            std.process.exit(1);
        }

        const baseline_report = computeReport(baseline_values.items, cfg.unit);
        const variant_report = computeReport(variant_values.items, cfg.unit);
        const delta = computeDelta(baseline_report, variant_report);
        const delta_pct = computeDeltaPct(baseline_report, delta);

        var ci: CiDelta = .{};
        if (ci_samples > 0) {
            const seed = cfg.seed orelse defaultSeed();
            var prng = std.Random.DefaultPrng.init(seed);
            ci.p50 = try bootstrapCiDelta(
                allocator,
                baseline_values.items,
                variant_values.items,
                50.0,
                ci_samples,
                cfg.ci_alpha,
                &prng,
            );
            ci.p95 = try bootstrapCiDelta(
                allocator,
                baseline_values.items,
                variant_values.items,
                95.0,
                ci_samples,
                cfg.ci_alpha,
                &prng,
            );
            ci.p99 = try bootstrapCiDelta(
                allocator,
                baseline_values.items,
                variant_values.items,
                99.0,
                ci_samples,
                cfg.ci_alpha,
                &prng,
            );
        }

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        var writer = output.writer(allocator);

        if (cfg.output_json) {
            try writeCompareJson(
                writer,
                baseline_report,
                variant_report,
                delta,
                delta_pct,
                ci_samples,
                cfg.ci_alpha,
                ci,
            );
            try writer.writeAll("\n");
            try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stdout(), output.items);
            return;
        }

        try printReportBlock(allocator, writer, "baseline", baseline_report, cfg.unit);
        try writer.writeAll("\n");
        try printReportBlock(allocator, writer, "variant", variant_report, cfg.unit);
        try writer.writeAll("\n");
        try writer.writeAll("delta (variant - baseline)\n");
        try printDeltaMetric(allocator, writer, "min", delta.min, delta_pct.min, cfg.unit);
        try printDeltaMetric(allocator, writer, "p50", delta.p50, delta_pct.p50, cfg.unit);
        try printDeltaMetric(allocator, writer, "p90", delta.p90, delta_pct.p90, cfg.unit);
        try printDeltaMetric(allocator, writer, "p95", delta.p95, delta_pct.p95, cfg.unit);
        try printDeltaMetric(allocator, writer, "p99", delta.p99, delta_pct.p99, cfg.unit);
        try printDeltaMetric(allocator, writer, "max", delta.max, delta_pct.max, cfg.unit);
        try printDeltaMetric(allocator, writer, "mean", delta.mean, delta_pct.mean, cfg.unit);
        try printDeltaMetric(allocator, writer, "median", delta.median, delta_pct.median, cfg.unit);
        try printDeltaMetric(allocator, writer, "stdev", delta.stdev, delta_pct.stdev, cfg.unit);

        if (ci.p50 != null and ci.p95 != null and ci.p99 != null) {
            const ci_pct: u32 = @intFromFloat(@round((1.0 - cfg.ci_alpha) * 100.0));
            try writer.print("\nci{d} (bootstrap; samples={d})\n", .{ ci_pct, ci_samples });
            try printCiMetric(allocator, writer, "p50", ci.p50.?, cfg.unit);
            try printCiMetric(allocator, writer, "p95", ci.p95.?, cfg.unit);
            try printCiMetric(allocator, writer, "p99", ci.p99.?, cfg.unit);
        }

        try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stdout(), output.items);
        return;
    }

    const input_text = if (cfg.input_path) |path|
        try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize))
    else
        try std.fs.File.stdin().readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(input_text);

    var values: std.ArrayList(f64) = .empty;
    defer values.deinit(allocator);
    try parseValuesFromText(input_text, cfg.parse_all, cfg.scale, allocator, &values);

    if (values.items.len == 0) {
        try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stdout(), "No numeric samples found.\n");
        std.process.exit(1);
    }

    const report = computeReport(values.items, cfg.unit);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var writer = output.writer(allocator);

    if (cfg.output_json) {
        try writeReportJson(writer, report);
        try writer.writeAll("\n");
        try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stdout(), output.items);
        return;
    }

    try writer.print("count  : {d}\n", .{report.count});
    try printMetric(allocator, writer, "min", report.min, cfg.unit);
    try printMetric(allocator, writer, "p50", report.p50, cfg.unit);
    try printMetric(allocator, writer, "p90", report.p90, cfg.unit);
    try printMetric(allocator, writer, "p95", report.p95, cfg.unit);
    try printMetric(allocator, writer, "p99", report.p99, cfg.unit);
    try printMetric(allocator, writer, "max", report.max, cfg.unit);
    try printMetric(allocator, writer, "mean", report.mean, cfg.unit);
    try printMetric(allocator, writer, "median", report.median, cfg.unit);
    try printMetric(allocator, writer, "stdev", report.stdev, cfg.unit);

    try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stdout(), output.items);
}

fn parseArgs(argv: []const []const u8) !Config {
    var cfg = Config{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
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
        if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            cfg.input_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--compare")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            cfg.compare_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--scale")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            cfg.scale = std.fmt.parseFloat(f64, argv[i]) catch return error.InvalidScale;
            continue;
        }
        if (std.mem.eql(u8, arg, "--unit")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            cfg.unit = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            cfg.parse_all = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            cfg.output_json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ci-samples")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            const parsed = std.fmt.parseInt(i64, argv[i], 10) catch return error.InvalidCiSamples;
            if (parsed < 0) return error.InvalidCiSamples;
            cfg.ci_samples = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--ci-alpha")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            cfg.ci_alpha = std.fmt.parseFloat(f64, argv[i]) catch return error.InvalidCiAlpha;
            continue;
        }
        if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            const parsed = std.fmt.parseInt(i64, argv[i], 10) catch return error.InvalidSeed;
            cfg.seed = @bitCast(parsed);
            continue;
        }
        return error.UnknownArg;
    }
    return cfg;
}

fn parseValuesFromText(
    input_text: []const u8,
    parse_all: bool,
    scale: f64,
    allocator: std.mem.Allocator,
    values: *std.ArrayList(f64),
) !void {
    var lines = std.mem.splitScalar(u8, input_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        try parseNumbersFromLine(trimmed, parse_all, allocator, values);
    }
    for (values.items) |*v| v.* *= scale;
}

fn isNumberStart(line: []const u8, idx: usize) bool {
    const c = line[idx];
    if (std.ascii.isDigit(c)) return true;
    if (c == '.') {
        return idx + 1 < line.len and std.ascii.isDigit(line[idx + 1]);
    }
    if (c == '+' or c == '-') {
        if (idx + 1 >= line.len) return false;
        const n = line[idx + 1];
        if (std.ascii.isDigit(n)) return true;
        return n == '.' and idx + 2 < line.len and std.ascii.isDigit(line[idx + 2]);
    }
    return false;
}

fn isNumberBodyChar(c: u8) bool {
    return std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-';
}

pub fn parseNumbersFromLine(
    line: []const u8,
    parse_all: bool,
    allocator: std.mem.Allocator,
    values: *std.ArrayList(f64),
) !void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (!isNumberStart(line, i)) continue;
        var j = i + 1;
        while (j < line.len and isNumberBodyChar(line[j])) : (j += 1) {}
        const token = line[i..j];
        const parsed = std.fmt.parseFloat(f64, token) catch continue;
        try values.append(allocator, parsed);
        if (!parse_all) return;
        i = j;
        if (i == 0) break;
        i -= 1;
    }
}

fn percentile(sorted_values: []const f64, p: f64) f64 {
    if (sorted_values.len == 0) return 0.0;
    if (sorted_values.len == 1) return sorted_values[0];

    const k = (@as(f64, @floatFromInt(sorted_values.len - 1))) * (p / 100.0);
    const f = std.math.floor(k);
    const c = std.math.ceil(k);

    if (f == c) {
        return sorted_values[@as(usize, @intFromFloat(k))];
    }

    const fi: usize = @intFromFloat(f);
    const ci: usize = @intFromFloat(c);
    return sorted_values[fi] + (sorted_values[ci] - sorted_values[fi]) * (k - f);
}

fn defaultSeed() u64 {
    const ts: i64 = @intCast(std.time.nanoTimestamp());
    return @bitCast(ts);
}

fn computeReport(values: []f64, unit: []const u8) Report {
    std.mem.sort(f64, values, {}, comptime std.sort.asc(f64));
    const mean = computeMean(values);
    return .{
        .count = values.len,
        .min = values[0],
        .p50 = percentile(values, 50.0),
        .p90 = percentile(values, 90.0),
        .p95 = percentile(values, 95.0),
        .p99 = percentile(values, 99.0),
        .max = values[values.len - 1],
        .mean = mean,
        .median = computeMedian(values),
        .stdev = computePopulationStdDev(values, mean),
        .unit = unit,
    };
}

fn computeDelta(baseline: Report, variant: Report) DeltaReport {
    return .{
        .min = variant.min - baseline.min,
        .p50 = variant.p50 - baseline.p50,
        .p90 = variant.p90 - baseline.p90,
        .p95 = variant.p95 - baseline.p95,
        .p99 = variant.p99 - baseline.p99,
        .max = variant.max - baseline.max,
        .mean = variant.mean - baseline.mean,
        .median = variant.median - baseline.median,
        .stdev = variant.stdev - baseline.stdev,
    };
}

fn toPct(delta: f64, baseline: f64) ?f64 {
    if (baseline == 0.0) return null;
    return (delta / baseline) * 100.0;
}

fn computeDeltaPct(baseline: Report, delta: DeltaReport) DeltaPctReport {
    return .{
        .min = toPct(delta.min, baseline.min),
        .p50 = toPct(delta.p50, baseline.p50),
        .p90 = toPct(delta.p90, baseline.p90),
        .p95 = toPct(delta.p95, baseline.p95),
        .p99 = toPct(delta.p99, baseline.p99),
        .max = toPct(delta.max, baseline.max),
        .mean = toPct(delta.mean, baseline.mean),
        .median = toPct(delta.median, baseline.median),
        .stdev = toPct(delta.stdev, baseline.stdev),
    };
}

fn bootstrapCiDelta(
    allocator: std.mem.Allocator,
    baseline: []const f64,
    variant: []const f64,
    stat_pct: f64,
    samples: usize,
    alpha: f64,
    prng: *std.Random.DefaultPrng,
) !CiInterval {
    if (samples == 0) return error.InvalidBootstrapSamples;
    if (baseline.len == 0 or variant.len == 0) return error.EmptyInput;

    var deltas = try allocator.alloc(f64, samples);
    defer allocator.free(deltas);
    const baseline_sample = try allocator.alloc(f64, baseline.len);
    defer allocator.free(baseline_sample);
    const variant_sample = try allocator.alloc(f64, variant.len);
    defer allocator.free(variant_sample);

    var random = prng.random();
    for (0..samples) |sample_idx| {
        for (baseline_sample) |*slot| {
            slot.* = baseline[random.uintLessThan(usize, baseline.len)];
        }
        for (variant_sample) |*slot| {
            slot.* = variant[random.uintLessThan(usize, variant.len)];
        }

        std.mem.sort(f64, baseline_sample, {}, comptime std.sort.asc(f64));
        std.mem.sort(f64, variant_sample, {}, comptime std.sort.asc(f64));
        const baseline_stat = percentile(baseline_sample, stat_pct);
        const variant_stat = percentile(variant_sample, stat_pct);
        deltas[sample_idx] = variant_stat - baseline_stat;
    }

    std.mem.sort(f64, deltas, {}, comptime std.sort.asc(f64));
    return .{
        .lo = percentile(deltas, (alpha / 2.0) * 100.0),
        .hi = percentile(deltas, (1.0 - (alpha / 2.0)) * 100.0),
    };
}

fn computeMean(values: []const f64) f64 {
    if (values.len == 0) return 0.0;
    var total: f64 = 0.0;
    for (values) |v| total += v;
    return total / @as(f64, @floatFromInt(values.len));
}

fn computeMedian(values: []const f64) f64 {
    if (values.len == 0) return 0.0;
    const mid = values.len / 2;
    if (values.len % 2 == 1) return values[mid];
    return (values[mid - 1] + values[mid]) / 2.0;
}

fn computePopulationStdDev(values: []const f64, mean: f64) f64 {
    if (values.len <= 1) return 0.0;
    var acc: f64 = 0.0;
    for (values) |v| {
        const d = v - mean;
        acc += d * d;
    }
    const variance = acc / @as(f64, @floatFromInt(values.len));
    return std.math.sqrt(variance);
}

fn formatValue(allocator: std.mem.Allocator, value: f64, unit: []const u8) ![]u8 {
    if (unit.len == 0) return std.fmt.allocPrint(allocator, "{d:.6}", .{value});
    return std.fmt.allocPrint(allocator, "{d:.6} {s}", .{ value, unit });
}

fn formatDeltaValue(allocator: std.mem.Allocator, value: f64, unit: []const u8) ![]u8 {
    if (value >= 0.0) {
        if (unit.len == 0) return std.fmt.allocPrint(allocator, "+{d:.6}", .{value});
        return std.fmt.allocPrint(allocator, "+{d:.6} {s}", .{ value, unit });
    }
    if (unit.len == 0) return std.fmt.allocPrint(allocator, "{d:.6}", .{value});
    return std.fmt.allocPrint(allocator, "{d:.6} {s}", .{ value, unit });
}

fn formatPct(allocator: std.mem.Allocator, value: ?f64) ![]u8 {
    if (value == null) return allocator.dupe(u8, "n/a");
    if (value.? >= 0.0) return std.fmt.allocPrint(allocator, "+{d:.3}%", .{value.?});
    return std.fmt.allocPrint(allocator, "{d:.3}%", .{value.?});
}

fn printMetric(
    allocator: std.mem.Allocator,
    writer: anytype,
    name: []const u8,
    value: f64,
    unit: []const u8,
) !void {
    const rendered = try formatValue(allocator, value, unit);
    defer allocator.free(rendered);
    try writer.print("{s:<7}: {s}\n", .{ name, rendered });
}

fn printReportBlock(
    allocator: std.mem.Allocator,
    writer: anytype,
    title: []const u8,
    report: Report,
    unit: []const u8,
) !void {
    try writer.print("{s}\n", .{title});
    try writer.print("count  : {d}\n", .{report.count});
    try printMetric(allocator, writer, "min", report.min, unit);
    try printMetric(allocator, writer, "p50", report.p50, unit);
    try printMetric(allocator, writer, "p90", report.p90, unit);
    try printMetric(allocator, writer, "p95", report.p95, unit);
    try printMetric(allocator, writer, "p99", report.p99, unit);
    try printMetric(allocator, writer, "max", report.max, unit);
    try printMetric(allocator, writer, "mean", report.mean, unit);
    try printMetric(allocator, writer, "median", report.median, unit);
    try printMetric(allocator, writer, "stdev", report.stdev, unit);
}

fn printDeltaMetric(
    allocator: std.mem.Allocator,
    writer: anytype,
    name: []const u8,
    delta_value: f64,
    delta_pct: ?f64,
    unit: []const u8,
) !void {
    const rendered_delta = try formatDeltaValue(allocator, delta_value, unit);
    defer allocator.free(rendered_delta);
    const rendered_pct = try formatPct(allocator, delta_pct);
    defer allocator.free(rendered_pct);
    try writer.print("{s:<6}: {s} ({s})\n", .{ name, rendered_delta, rendered_pct });
}

fn printCiMetric(
    allocator: std.mem.Allocator,
    writer: anytype,
    name: []const u8,
    interval: CiInterval,
    unit: []const u8,
) !void {
    const lo = try formatValue(allocator, interval.lo, unit);
    defer allocator.free(lo);
    const hi = try formatValue(allocator, interval.hi, unit);
    defer allocator.free(hi);
    try writer.print("{s:<6}: [{s}, {s}]\n", .{ name, lo, hi });
}

fn writeReportJson(writer: anytype, report: Report) !void {
    try writer.writeAll("{");
    try writer.print("\"count\":{d}", .{report.count});
    try writer.print(",\"min\":{d:.6}", .{report.min});
    try writer.print(",\"p50\":{d:.6}", .{report.p50});
    try writer.print(",\"p90\":{d:.6}", .{report.p90});
    try writer.print(",\"p95\":{d:.6}", .{report.p95});
    try writer.print(",\"p99\":{d:.6}", .{report.p99});
    try writer.print(",\"max\":{d:.6}", .{report.max});
    try writer.print(",\"mean\":{d:.6}", .{report.mean});
    try writer.print(",\"median\":{d:.6}", .{report.median});
    try writer.print(",\"stdev\":{d:.6}", .{report.stdev});
    try writer.writeAll(",\"unit\":");
    try writeJsonString(writer, report.unit);
    try writer.writeAll("}");
}

fn writeDeltaJson(writer: anytype, delta: DeltaReport) !void {
    try writer.writeAll("{");
    try writer.print("\"min\":{d:.6}", .{delta.min});
    try writer.print(",\"p50\":{d:.6}", .{delta.p50});
    try writer.print(",\"p90\":{d:.6}", .{delta.p90});
    try writer.print(",\"p95\":{d:.6}", .{delta.p95});
    try writer.print(",\"p99\":{d:.6}", .{delta.p99});
    try writer.print(",\"max\":{d:.6}", .{delta.max});
    try writer.print(",\"mean\":{d:.6}", .{delta.mean});
    try writer.print(",\"median\":{d:.6}", .{delta.median});
    try writer.print(",\"stdev\":{d:.6}", .{delta.stdev});
    try writer.writeAll("}");
}

fn writeOptionalPct(writer: anytype, value: ?f64) !void {
    if (value) |pct| {
        try writer.print("{d:.6}", .{pct});
        return;
    }
    try writer.writeAll("null");
}

fn writeDeltaPctJson(writer: anytype, delta_pct: DeltaPctReport) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"min\":");
    try writeOptionalPct(writer, delta_pct.min);
    try writer.writeAll(",\"p50\":");
    try writeOptionalPct(writer, delta_pct.p50);
    try writer.writeAll(",\"p90\":");
    try writeOptionalPct(writer, delta_pct.p90);
    try writer.writeAll(",\"p95\":");
    try writeOptionalPct(writer, delta_pct.p95);
    try writer.writeAll(",\"p99\":");
    try writeOptionalPct(writer, delta_pct.p99);
    try writer.writeAll(",\"max\":");
    try writeOptionalPct(writer, delta_pct.max);
    try writer.writeAll(",\"mean\":");
    try writeOptionalPct(writer, delta_pct.mean);
    try writer.writeAll(",\"median\":");
    try writeOptionalPct(writer, delta_pct.median);
    try writer.writeAll(",\"stdev\":");
    try writeOptionalPct(writer, delta_pct.stdev);
    try writer.writeAll("}");
}

fn writeCiDeltaJson(writer: anytype, ci: CiDelta) !void {
    try writer.writeAll("{");
    var first = true;
    if (ci.p50) |interval| {
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll("\"p50\":");
        try writeCiIntervalJson(writer, interval);
    }
    if (ci.p95) |interval| {
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll("\"p95\":");
        try writeCiIntervalJson(writer, interval);
    }
    if (ci.p99) |interval| {
        if (!first) try writer.writeAll(",");
        first = false;
        try writer.writeAll("\"p99\":");
        try writeCiIntervalJson(writer, interval);
    }
    try writer.writeAll("}");
}

fn writeCiIntervalJson(writer: anytype, interval: CiInterval) !void {
    try writer.print("{{\"lo\":{d:.6},\"hi\":{d:.6}}}", .{ interval.lo, interval.hi });
}

fn writeCompareJson(
    writer: anytype,
    baseline: Report,
    variant: Report,
    delta: DeltaReport,
    delta_pct: DeltaPctReport,
    ci_samples: usize,
    ci_alpha: f64,
    ci: CiDelta,
) !void {
    try writer.writeAll("{\"baseline\":");
    try writeReportJson(writer, baseline);
    try writer.writeAll(",\"variant\":");
    try writeReportJson(writer, variant);
    try writer.writeAll(",\"delta\":");
    try writeDeltaJson(writer, delta);
    try writer.writeAll(",\"delta_pct\":");
    try writeDeltaPctJson(writer, delta_pct);
    try writer.print(",\"ci\":{{\"samples\":{d},\"alpha\":{d:.6},\"delta\":", .{ ci_samples, ci_alpha });
    try writeCiDeltaJson(writer, ci);
    try writer.writeAll("}");
    try writer.writeAll("}");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "percentile interpolation" {
    const data = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), percentile(&data, 50), 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.7), percentile(&data, 90), 0.000_001);
}

test "parse numbers first only" {
    var list: std.ArrayList(f64) = .empty;
    defer list.deinit(std.testing.allocator);
    try parseNumbersFromLine("p50=1.5 p95=2.5", false, std.testing.allocator, &list);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 50), list.items[0], 0.000_001);
}

test "parse numbers all values" {
    var list: std.ArrayList(f64) = .empty;
    defer list.deinit(std.testing.allocator);
    try parseNumbersFromLine("a 1.5 b -2.25 c 3", true, std.testing.allocator, &list);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), list.items[0], 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, -2.25), list.items[1], 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), list.items[2], 0.000_001);
}

test "parse args enables json output" {
    const argv = [_][]const u8{ "bench_stats.zig", "--json" };
    const cfg = try parseArgs(&argv);
    try std.testing.expect(cfg.output_json);
}

test "parse args compare mode with CI settings" {
    const argv = [_][]const u8{
        "bench_stats.zig",
        "--input",
        "baseline.txt",
        "--compare",
        "variant.txt",
        "--ci-samples",
        "2000",
        "--ci-alpha",
        "0.1",
        "--seed",
        "7",
    };
    const cfg = try parseArgs(&argv);
    try std.testing.expectEqualStrings("baseline.txt", cfg.input_path.?);
    try std.testing.expectEqualStrings("variant.txt", cfg.compare_path.?);
    try std.testing.expectEqual(@as(usize, 2000), cfg.ci_samples.?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), cfg.ci_alpha, 0.000_001);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, 7))), cfg.seed.?);
}

test "delta percent handles zero baseline as null" {
    const baseline = Report{
        .count = 1,
        .min = 0.0,
        .p50 = 1.0,
        .p90 = 1.0,
        .p95 = 1.0,
        .p99 = 1.0,
        .max = 1.0,
        .mean = 1.0,
        .median = 1.0,
        .stdev = 1.0,
        .unit = "",
    };
    const variant = Report{
        .count = 1,
        .min = 2.0,
        .p50 = 2.0,
        .p90 = 2.0,
        .p95 = 2.0,
        .p99 = 2.0,
        .max = 2.0,
        .mean = 2.0,
        .median = 2.0,
        .stdev = 2.0,
        .unit = "",
    };
    const delta = computeDelta(baseline, variant);
    const pct = computeDeltaPct(baseline, delta);
    try std.testing.expect(pct.min == null);
    try std.testing.expect(pct.p50 != null);
}

test "bootstrap CI returns ordered interval" {
    var prng = std.Random.DefaultPrng.init(42);
    const baseline = [_]f64{ 1, 2, 3, 4, 5 };
    const variant = [_]f64{ 2, 3, 4, 5, 6 };
    const ci = try bootstrapCiDelta(
        std.testing.allocator,
        &baseline,
        &variant,
        95.0,
        200,
        0.05,
        &prng,
    );
    try std.testing.expect(ci.lo <= ci.hi);
}

test "compare json output is valid json" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const writer = out.writer(std.testing.allocator);

    const baseline = Report{
        .count = 3,
        .min = 10.0,
        .p50 = 12.0,
        .p90 = 14.0,
        .p95 = 14.5,
        .p99 = 14.9,
        .max = 15.0,
        .mean = 12.0,
        .median = 12.0,
        .stdev = 2.0,
        .unit = "ms",
    };
    const variant = Report{
        .count = 3,
        .min = 9.0,
        .p50 = 11.0,
        .p90 = 13.0,
        .p95 = 13.5,
        .p99 = 13.9,
        .max = 14.0,
        .mean = 11.0,
        .median = 11.0,
        .stdev = 2.0,
        .unit = "ms",
    };

    const delta = computeDelta(baseline, variant);
    const delta_pct = computeDeltaPct(baseline, delta);
    try writeCompareJson(writer, baseline, variant, delta, delta_pct, 0, 0.05, .{});

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.items, .{});
    defer parsed.deinit();
}

fn parseLineWithAlloc(alloc: std.mem.Allocator, line: []const u8) !void {
    var list: std.ArrayList(f64) = .empty;
    defer list.deinit(alloc);
    try parseNumbersFromLine(line, true, alloc, &list);
}

test "allocation failures parse line" {
    const line = "p50=1.234 p95=2.345 p99=3.456";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseLineWithAlloc, .{line});
}

fn fuzzParseLineTarget(_: void, input: []const u8) !void {
    var list: std.ArrayList(f64) = .empty;
    defer list.deinit(std.testing.allocator);
    _ = parseNumbersFromLine(input, true, std.testing.allocator, &list) catch {};
}

test "fuzz parse numbers from arbitrary input" {
    try std.testing.fuzz({}, fuzzParseLineTarget, .{});
}
