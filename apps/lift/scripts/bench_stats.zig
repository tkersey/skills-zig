const std = @import("std");
const core_io = @import("core_io");

const UsageText =
    \\bench_stats.zig
    \\
    \\Summarize benchmark samples with basic statistics and percentiles.
    \\
    \\Usage:
    \\  zig run codex/skills/lift/scripts/bench_stats.zig -- [options]
    \\
    \\Options:
    \\  --input PATH   Input file path (default: stdin)
    \\  --scale F64    Scale factor (default: 1.0)
    \\  --unit TEXT    Unit label (default: empty)
    \\  --all          Parse all numbers in each line (default: first only)
    \\  --json         Emit JSON (numbers stay unformatted)
    \\  --help         Show help
;

const Config = struct {
    input_path: ?[]const u8 = null,
    scale: f64 = 1.0,
    unit: []const u8 = "",
    parse_all: bool = false,
    output_json: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var cfg = try parseArgs(argv);
    if (cfg.input_path != null and cfg.input_path.?.len == 0) cfg.input_path = null;

    const input_text = if (cfg.input_path) |path|
        try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize))
    else
        try std.fs.File.stdin().readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(input_text);

    var values: std.ArrayList(f64) = .empty;
    defer values.deinit(allocator);

    var lines = std.mem.splitScalar(u8, input_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        try parseNumbersFromLine(trimmed, cfg.parse_all, allocator, &values);
    }

    if (values.items.len == 0) {
        try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stdout(), "No numeric samples found.\n");
        std.process.exit(1);
    }

    for (values.items) |*v| v.* *= cfg.scale;

    std.mem.sort(f64, values.items, {}, comptime std.sort.asc(f64));

    const count = values.items.len;
    const min_v = values.items[0];
    const p50_v = percentile(values.items, 50.0);
    const p90_v = percentile(values.items, 90.0);
    const p95_v = percentile(values.items, 95.0);
    const p99_v = percentile(values.items, 99.0);
    const max_v = values.items[count - 1];
    const mean = computeMean(values.items);
    const median = computeMedian(values.items);
    const stdev = computePopulationStdDev(values.items, mean);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var writer = output.writer(allocator);

    if (cfg.output_json) {
        try writer.print(
            "{{\"count\":{d},\"min\":{d:.6},\"p50\":{d:.6},\"p90\":{d:.6},\"p95\":{d:.6},\"p99\":{d:.6},\"max\":{d:.6},\"mean\":{d:.6},\"median\":{d:.6},\"stdev\":{d:.6},\"unit\":\"{s}\"}}\n",
            .{ count, min_v, p50_v, p90_v, p95_v, p99_v, max_v, mean, median, stdev, cfg.unit },
        );
        try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stdout(), output.items);
        return;
    }

    try writer.print("count  : {d}\n", .{count});
    try printMetric(allocator, writer, "min", min_v, cfg.unit);
    try printMetric(allocator, writer, "p50", p50_v, cfg.unit);
    try printMetric(allocator, writer, "p90", p90_v, cfg.unit);
    try printMetric(allocator, writer, "p95", p95_v, cfg.unit);
    try printMetric(allocator, writer, "p99", p99_v, cfg.unit);
    try printMetric(allocator, writer, "max", max_v, cfg.unit);
    try printMetric(allocator, writer, "mean", mean, cfg.unit);
    try printMetric(allocator, writer, "median", median, cfg.unit);
    try printMetric(allocator, writer, "stdev", stdev, cfg.unit);

    try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stdout(), output.items);
}

fn parseArgs(argv: []const []const u8) !Config {
    var cfg = Config{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try core_io.writeToStreamAllowBrokenPipe(std.fs.File.stderr(), UsageText ++ "\n");
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            cfg.input_path = argv[i];
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
        return error.UnknownArg;
    }
    return cfg;
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

fn parseNumbersFromLine(
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
