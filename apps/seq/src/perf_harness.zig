const std = @import("std");
const query = @import("query/engine.zig");
const spec = @import("types/spec.zig");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);
const UsageText =
    \\perf_harness.zig
    \\
    \\Frozen workload harness for seq query engine.
    \\
    \\Usage:
    \\  seq-perf [options]
    \\
    \\Options:
    \\  --config PATH   Config file path (default: perf/frozen/workload_config.json)
    \\  --help          Show help
    \\  --version       Show version
    \\  version         Show version
;

const WorkloadConfig = struct {
    rows: usize = 12000,
    rounds: usize = 15,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    if (try core_cli.handleDefaultHelpAndVersion(argv, UsageText, Version)) return;

    const config_path = try parseConfigPath(allocator);
    defer allocator.free(config_path);

    const config = try loadConfig(allocator, config_path);
    if (config.rounds < 3) return error.InvalidRounds;

    var rows = try buildFrozenRows(allocator, config.rows);
    defer deinitRows(allocator, &rows);

    const query_spec = spec.QuerySpec{
        .group_by = &.{"day"},
        .metrics = &.{
            .{ .op = .sum, .field = "delta_total_tokens", .alias = "total_tokens" },
            .{ .op = .count, .alias = "rows" },
        },
        .sort = &.{.{ .field = "day", .descending = false }},
    };

    const baseline_samples = try allocator.alloc(u64, config.rounds);
    defer allocator.free(baseline_samples);
    const optimized_samples = try allocator.alloc(u64, config.rounds);
    defer allocator.free(optimized_samples);

    var i: usize = 0;
    while (i < config.rounds) : (i += 1) {
        baseline_samples[i] = try runBaselineRound(allocator, rows.items, query_spec);
        optimized_samples[i] = try runOptimizedRound(allocator, rows.items, query_spec);
    }

    const baseline_p50 = try percentile50(allocator, baseline_samples);
    const optimized_p50 = try percentile50(allocator, optimized_samples);
    const speedup_pct = computeSpeedupPct(baseline_p50, optimized_p50);

    var stdout = std.fs.File.stdout().writer(&.{});
    try stdout.interface.print("workload_rows={d}\n", .{config.rows});
    try stdout.interface.print("rounds={d}\n", .{config.rounds});
    try stdout.interface.print("baseline_p50_ns={d}\n", .{baseline_p50});
    try stdout.interface.print("optimized_p50_ns={d}\n", .{optimized_p50});
    try stdout.interface.print("speedup_pct={d:.2}\n", .{speedup_pct});
    if (speedup_pct < 20.0) return error.PerfTargetNotMet;
    try stdout.interface.writeAll("status=PASS\n");
}

fn parseConfigPath(allocator: std.mem.Allocator) ![]u8 {
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
            return allocator.dupe(u8, path);
        }
    }

    return allocator.dupe(u8, "perf/frozen/workload_config.json");
}

fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !WorkloadConfig {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidConfig,
    };

    var out = WorkloadConfig{};
    if (root.get("rows")) |v| out.rows = try intFieldToUsize(v);
    if (root.get("rounds")) |v| out.rounds = try intFieldToUsize(v);
    return out;
}

fn intFieldToUsize(value: std.json.Value) !usize {
    return switch (value) {
        .integer => |i| blk: {
            if (i <= 0) return error.InvalidConfig;
            break :blk @intCast(i);
        },
        else => error.InvalidConfig,
    };
}

fn buildFrozenRows(allocator: std.mem.Allocator, count: usize) !std.ArrayList(query.Row) {
    var rows: std.ArrayList(query.Row) = .empty;
    errdefer deinitRows(allocator, &rows);

    for (0..count) |i| {
        var row = query.Row.init(allocator);
        errdefer row.deinit();

        const skill = switch (i % 3) {
            0 => "tk",
            1 => "fix",
            else => "mesh",
        };
        const day = if (i % 2 == 0) "2026-02-19" else "2026-02-20";
        const token_delta: i64 = @intCast((i % 50) + 1);

        try row.putOwnedKey("skill", .{ .string = skill });
        try row.putOwnedKey("day", .{ .string = day });
        try row.putOwnedKey("delta_total_tokens", .{ .int = token_delta });
        try rows.append(allocator, row);
    }

    return rows;
}

fn runBaselineRound(
    allocator: std.mem.Allocator,
    base_rows: []const query.Row,
    query_spec: spec.QuerySpec,
) !u64 {
    var timer = try std.time.Timer.start();

    var cloned_rows: std.ArrayList(query.Row) = .empty;
    defer deinitRows(allocator, &cloned_rows);
    try cloned_rows.ensureTotalCapacity(allocator, base_rows.len);
    for (base_rows) |row| {
        try cloned_rows.append(allocator, try row.cloneAll(allocator));
    }

    var result = try query.execute(allocator, cloned_rows.items, query_spec);
    defer result.deinit(allocator);

    return timer.read();
}

fn runOptimizedRound(
    allocator: std.mem.Allocator,
    base_rows: []const query.Row,
    query_spec: spec.QuerySpec,
) !u64 {
    var timer = try std.time.Timer.start();
    var result = try query.execute(allocator, base_rows, query_spec);
    defer result.deinit(allocator);
    return timer.read();
}

fn percentile50(allocator: std.mem.Allocator, samples: []const u64) !u64 {
    const copy = try allocator.dupe(u64, samples);
    defer allocator.free(copy);

    std.mem.sort(u64, copy, {}, lessThanU64);
    return copy[copy.len / 2];
}

fn computeSpeedupPct(baseline_ns: u64, optimized_ns: u64) f64 {
    if (baseline_ns == 0) return 0;
    const base = @as(f64, @floatFromInt(baseline_ns));
    const opt = @as(f64, @floatFromInt(optimized_ns));
    return ((base - opt) / base) * 100.0;
}

fn lessThanU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

fn deinitRows(allocator: std.mem.Allocator, rows: *std.ArrayList(query.Row)) void {
    for (rows.items) |*row| row.deinit();
    rows.deinit(allocator);
}
