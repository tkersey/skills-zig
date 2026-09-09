const core_calendar = @import("core_calendar");
const std = @import("std");
const core_io = @import("core_io");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "perf_report",
    .help_text = UsageText,
};

const UsageText =
    \\perf_report
    \\
    \\Generate a performance report template in Markdown.
    \\
    \\Usage:
    \\  perf_report [options]
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

const ReportBody =
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
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    const cfg = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    const report_date = try currentDateIso(allocator);
    defer allocator.free(report_date);

    const output = try renderReportAlloc(allocator, cfg, report_date);
    defer allocator.free(output);

    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = cfg.output,
        .data = output,
    });
    const success_message = try std.fmt.allocPrint(allocator, "Wrote {s}\n", .{cfg.output});
    defer allocator.free(success_message);
    try writeToStreamAllowBrokenPipe(std.Io.File.stdout(), success_message);
}

fn renderReportAlloc(allocator: std.mem.Allocator, cfg: Config, report_date: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\# Performance Report: {s}
        \\
        \\Date: {s}
        \\Owner: {s}
        \\System: {s}
        \\
        \\
    ++ ReportBody, .{ cfg.title, report_date, cfg.owner, cfg.system });
}

fn parseArgs(argv: []const []const u8) !Config {
    var cfg = Config{};

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (core_cli.isHelpArg(arg)) {
            var stdout_writer = std.Io.File.stdout().writer(
                std.Io.Threaded.global_single_threaded.io(),
                &.{},
            );
            const stdout = &stdout_writer.interface;
            try core_cli.printHelpSurface(stdout, HelpSurface, Version);
            std.process.exit(0);
        }
        if (core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) {
            var stdout_writer = std.Io.File.stdout().writer(
                std.Io.Threaded.global_single_threaded.io(),
                &.{},
            );
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
    const now_sec: i64 = @intCast(@divFloor(
        std.Io.Clock.real.now(core_io.defaultIo()).nanoseconds,
        1_000_000_000,
    ));
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
    const date = core_calendar.civilFromDays(days_since_unix_epoch, .legacy_negative_era);
    return .{
        .year = @intCast(date.year),
        .month = @intCast(date.month),
        .day = @intCast(date.day),
    };
}

fn writeToStreamAllowBrokenPipe(file: std.Io.File, bytes: []const u8) !void {
    return core_io.writeAllAllowBrokenPipe(file, bytes);
}

test "civil date conversion stable around epoch" {
    const epoch = civilFromDays(0);
    try std.testing.expectEqual(@as(i64, 1970), epoch.year);
    try std.testing.expectEqual(@as(i64, 1), epoch.month);
    try std.testing.expectEqual(@as(i64, 1), epoch.day);
}

fn renderReportWithAllocator(allocator: std.mem.Allocator) !void {
    const output = try renderReportAlloc(
        allocator,
        .{ .title = "Example", .owner = "Team", .system = "CLI" },
        "2026-09-07",
    );
    defer allocator.free(output);
    try std.testing.expect(std.mem.startsWith(
        u8,
        output,
        "# Performance Report: Example\n\nDate: 2026-09-07\nOwner: Team\nSystem: CLI\n",
    ));
    try std.testing.expect(std.mem.indexOf(u8, output, "## 1. Performance Contract\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "- Rollout plan:\n"));
}

test "CLI report renderer retains its complete header and body under allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        renderReportWithAllocator,
        .{},
    );
}
