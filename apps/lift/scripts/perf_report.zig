const std = @import("std");
const core_io = @import("core_io");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);

const UsageText =
    \\perf_report.zig
    \\
    \\Generate a performance report template in Markdown.
    \\
    \\Usage:
    \\  zig run codex/skills/lift/scripts/perf_report.zig -- [options]
    \\
    \\Options:
    \\  --title TEXT    Report title (default: Untitled)
    \\  --owner TEXT    Owner or team
    \\  --system TEXT   System or component
    \\  --output PATH   Output path (default: perf-report.md)
    \\  --help          Show help
    \\  --version       Show version
    \\  version         Show version
;

const Config = struct {
    title: []const u8 = "Untitled",
    owner: []const u8 = "",
    system: []const u8 = "",
    output: []const u8 = "perf-report.md",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (try core_cli.handleDefaultHelpAndVersion(argv, UsageText, Version)) return;

    const cfg = try parseArgs(argv);
    const report_date = try currentDateIso(allocator);
    defer allocator.free(report_date);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print(
        \\# Performance Report: {s}
        \\
        \\Date: {s}
        \\Owner: {s}
        \\System: {s}
        \\
        \\
    , .{ cfg.title, report_date, cfg.owner, cfg.system });

    try w.writeAll(
        \\## 1. Performance Contract
        \\
        \\- Metric:
        \\- Target:
        \\- Percentile:
        \\- Workload command:
        \\- Dataset:
        \\- Environment:
        \\- Constraints:
        \\
        \\## 2. Baseline
        \\
        \\- Measurement method:
        \\- Sample size:
        \\- Results (p50/p95/p99):
        \\- Notes:
        \\
        \\## 3. Bottleneck Evidence
        \\
        \\- Profile or trace summary:
        \\- Hot paths:
        \\- Bound classification (CPU/memory/I/O/lock/tail):
        \\
        \\## 4. Hypothesis
        \\
        \\- Cause:
        \\- Expected impact:
        \\- Risks:
        \\
        \\## 5. Experiment Plan
        \\
        \\- Change description:
        \\- Control variables:
        \\- Success criteria:
        \\
        \\## 6. Results
        \\
        \\- Variant measurements:
        \\- Delta vs baseline:
        \\- Confidence:
        \\
        \\## 7. Trade-offs
        \\
        \\- Correctness:
        \\- Maintainability:
        \\- Cost or resource impact:
        \\
        \\## 8. Regression Guard
        \\
        \\- Benchmark or budget:
        \\- Alert or threshold:
        \\
        \\## 9. Validation
        \\
        \\- Correctness command(s) -> pass/fail:
        \\- Performance command(s) -> numbers:
        \\
        \\## 10. Lift Compliance
        \\
        \\- mode (measured|unmeasured):
        \\- proof artifacts (bench + profile paths):
        \\
        \\## 11. Next Steps
        \\
        \\- Follow-up experiments:
        \\- Rollout plan:
        \\
    );

    try std.fs.cwd().writeFile(.{
        .sub_path = cfg.output,
        .data = out.items,
    });
    const success_message = try std.fmt.allocPrint(allocator, "Wrote {s}\n", .{cfg.output});
    defer allocator.free(success_message);
    try writeToStreamAllowBrokenPipe(std.fs.File.stdout(), success_message);
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
        if (std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            cfg.title = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--owner")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            cfg.owner = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--system")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            cfg.system = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            cfg.output = argv[i];
            continue;
        }
        return error.UnknownArg;
    }
    return cfg;
}

fn currentDateIso(allocator: std.mem.Allocator) ![]u8 {
    const now_sec: i64 = std.time.timestamp();
    const days: i64 = @divFloor(now_sec, 86_400);
    const date = civilFromDays(days);
    const year_u: u64 = @intCast(@max(date.year, 0));
    const month_u: u8 = @intCast(@max(date.month, 0));
    const day_u: u8 = @intCast(@max(date.day, 0));
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_u, month_u, day_u });
}

const Date = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn civilFromDays(days_since_unix_epoch: i64) Date {
    // Howard Hinnant's civil-from-days algorithm.
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365); // [0, 399]
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0,365]
    const mp = @divFloor(5 * doy + 2, 153); // [0,11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1,31]
    var m = mp + 3;
    if (m > 12) m -= 12;
    if (m <= 2) y += 1;
    return .{
        .year = y,
        .month = m,
        .day = d,
    };
}

fn writeToStreamAllowBrokenPipe(file: std.fs.File, bytes: []const u8) !void {
    return core_io.writeAllAllowBrokenPipe(file, bytes);
}

test "civil date conversion stable around epoch" {
    const epoch = civilFromDays(0);
    try std.testing.expectEqual(@as(i64, 1970), epoch.year);
    try std.testing.expectEqual(@as(i64, 1), epoch.month);
    try std.testing.expectEqual(@as(i64, 1), epoch.day);
}
