const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_json = b.createModule(.{
        .root_source_file = b.path("libs/core/src/json_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_io = b.createModule(.{
        .root_source_file = b.path("libs/core/src/io_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_path = b.createModule(.{
        .root_source_file = b.path("libs/core/src/path_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });

    const seq_root = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_path", .module = core_path },
        },
    });
    const seq_perf_root = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/perf_harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lift_bench_root = b.createModule(.{
        .root_source_file = b.path("apps/lift/scripts/bench_stats.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_io", .module = core_io },
        },
    });
    const lift_report_root = b.createModule(.{
        .root_source_file = b.path("apps/lift/scripts/perf_report.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_io", .module = core_io },
        },
    });
    const cas_smoke_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_smoke_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
        },
    });
    const cas_runner_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_instance_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
        },
    });

    const seq = addInstalledExecutable(b, "seq", seq_root);
    const seq_perf = addInstalledExecutable(b, "seq-perf", seq_perf_root);
    const bench_stats = addInstalledExecutable(b, "bench_stats", lift_bench_root);
    const perf_report = addInstalledExecutable(b, "perf_report", lift_report_root);
    const cas_smoke_check = addInstalledExecutable(b, "cas_smoke_check", cas_smoke_root);
    const cas_instance_runner = addInstalledExecutable(b, "cas_instance_runner", cas_runner_root);

    const build_seq = b.step("build-seq", "Build seq binaries");
    build_seq.dependOn(&seq.step);
    build_seq.dependOn(&seq_perf.step);

    const build_lift = b.step("build-lift", "Build lift binaries");
    build_lift.dependOn(&bench_stats.step);
    build_lift.dependOn(&perf_report.step);

    const build_cas = b.step("build-cas", "Build cas binaries");
    build_cas.dependOn(&cas_smoke_check.step);
    build_cas.dependOn(&cas_instance_runner.step);

    addRunStep(b, seq, "run-seq", "Run seq", &.{});
    addRunStep(b, bench_stats, "run-bench-stats", "Run bench_stats", &.{"--help"});
    addRunStep(b, cas_smoke_check, "run-cas-smoke-check", "Run cas_smoke_check", &.{"--help"});
}

fn addInstalledExecutable(
    b: *std.Build,
    name: []const u8,
    root_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });
    b.installArtifact(exe);
    return exe;
}

fn addRunStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
    default_args: []const []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    } else if (default_args.len > 0) {
        run_cmd.addArgs(default_args);
    }

    const run_step = b.step(step_name, description);
    run_step.dependOn(&run_cmd.step);
}
