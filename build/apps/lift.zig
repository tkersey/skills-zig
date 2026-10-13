const std = @import("std");
const support = @import("../support.zig");
const BuildContext = support.BuildContext;
const SharedModules = support.SharedModules;
const AppSurface = support.AppSurface;

pub fn build(ctx: BuildContext, shared: SharedModules) AppSurface {
    const b = ctx.b;
    const lift_meta = support.addVersionModule(b, @embedFile("../../apps/lift/VERSION"));
    const lift_bench_root = ctx.module("apps/lift/scripts/bench_stats.zig", &.{
        .{ .name = "core_io", .module = shared.io },
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "app_meta", .module = lift_meta },
    });
    const lift_report_root = ctx.module("apps/lift/scripts/perf_report.zig", &.{
        .{ .name = "core_calendar", .module = shared.calendar },
        .{ .name = "core_io", .module = shared.io },
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "app_meta", .module = lift_meta },
    });
    const lift_bench_perf_root = ctx.module("apps/lift/scripts/perf_bench_stats.zig", &.{
        .{ .name = "core_io", .module = shared.io },
        .{ .name = "core_perf", .module = shared.perf },
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "app_meta", .module = lift_meta },
    });
    const bench_stats = support.addInstalledExecutable(b, "bench_stats", lift_bench_root);
    const perf_report = support.addInstalledExecutable(b, "perf_report", lift_report_root);
    const lift_bench_perf = support.addInstalledExecutable(
        b,
        "lift-perf-bench-stats",
        lift_bench_perf_root,
    );
    support.addBenchStep(
        b,
        lift_bench_perf.exe,
        "bench-lift-bench-stats",
        "Run bench_stats performance harness",
    );
    const test_lift = addLiftTests(b, lift_bench_root, lift_report_root, lift_bench_perf_root);
    support.addRunStep(b, bench_stats.exe, "run-bench-stats", "Run bench_stats");
    return support.appSurface(b, .{
        .path = b.path("apps/lift"),
        .build_step_name = "build-lift",
        .build_description = "Build lift binaries",
        .build_deps = &.{
            &bench_stats.install.step, &perf_report.install.step, &lift_bench_perf.install.step,
        },
        .test_deps = &.{test_lift},
    });
}

fn addLiftTests(
    b: *std.Build,
    lift_bench_root: *std.Build.Module,
    lift_report_root: *std.Build.Module,
    lift_bench_perf_root: *std.Build.Module,
) *std.Build.Step {
    const run_lift_bench_tests = support.addTestStep(
        b,
        lift_bench_root,
        "test-lift-bench-stats",
        "Run bench_stats tests",
    );
    const run_lift_report_tests = support.addTestStep(
        b,
        lift_report_root,
        "test-lift-perf-report",
        "Run perf_report tests",
    );
    const run_lift_bench_perf_tests = support.addTestStep(
        b,
        lift_bench_perf_root,
        "test-lift-perf-bench-stats",
        "Run perf_bench_stats tests",
    );
    const test_lift = b.step("test-lift", "Run all lift tests");
    test_lift.dependOn(&run_lift_bench_tests.step);
    test_lift.dependOn(&run_lift_report_tests.step);
    test_lift.dependOn(&run_lift_bench_perf_tests.step);
    return test_lift;
}
