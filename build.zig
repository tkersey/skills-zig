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
    const core_delegate = b.createModule(.{
        .root_source_file = b.path("libs/core/src/delegate_helpers.zig"),
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
    const cas_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
        },
    });
    const cron_root = b.createModule(.{
        .root_source_file = b.path("apps/cron/scripts/cron.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
        },
    });
    const puff_root = b.createModule(.{
        .root_source_file = b.path("apps/puff/scripts/puff.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
        },
    });
    const learnings_root = b.createModule(.{
        .root_source_file = b.path("apps/learnings/scripts/learnings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
        },
    });
    const append_learning_root = b.createModule(.{
        .root_source_file = b.path("apps/learnings/scripts/append_learning.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
        },
    });

    const seq = addExecutable(b, "seq", seq_root);
    const seq_perf = addExecutable(b, "seq-perf", seq_perf_root);
    const bench_stats = addExecutable(b, "bench_stats", lift_bench_root);
    const perf_report = addExecutable(b, "perf_report", lift_report_root);
    const cas_smoke_check = addExecutable(b, "cas_smoke_check", cas_smoke_root);
    const cas_instance_runner = addExecutable(b, "cas_instance_runner", cas_runner_root);
    const cas = addExecutable(b, "cas", cas_root);
    const cron = addExecutable(b, "cron", cron_root);
    const puff = addExecutable(b, "puff", puff_root);
    const learnings = addExecutable(b, "learnings", learnings_root);
    const append_learning = addExecutable(b, "append_learning", append_learning_root);

    const seq_install = addInstallStep(b, seq);
    const seq_perf_install = addInstallStep(b, seq_perf);
    const bench_stats_install = addInstallStep(b, bench_stats);
    const perf_report_install = addInstallStep(b, perf_report);
    const cas_smoke_check_install = addInstallStep(b, cas_smoke_check);
    const cas_instance_runner_install = addInstallStep(b, cas_instance_runner);
    const cas_install = addInstallStep(b, cas);
    const cron_install = addInstallStep(b, cron);
    const puff_install = addInstallStep(b, puff);
    const learnings_install = addInstallStep(b, learnings);
    const append_learning_install = addInstallStep(b, append_learning);

    const install_all = b.getInstallStep();
    install_all.dependOn(&seq_install.step);
    install_all.dependOn(&seq_perf_install.step);
    install_all.dependOn(&bench_stats_install.step);
    install_all.dependOn(&perf_report_install.step);
    install_all.dependOn(&cas_smoke_check_install.step);
    install_all.dependOn(&cas_instance_runner_install.step);
    install_all.dependOn(&cas_install.step);
    install_all.dependOn(&cron_install.step);
    install_all.dependOn(&puff_install.step);
    install_all.dependOn(&learnings_install.step);
    install_all.dependOn(&append_learning_install.step);

    const build_seq = b.step("build-seq", "Build seq binaries");
    build_seq.dependOn(&seq_install.step);
    build_seq.dependOn(&seq_perf_install.step);

    const build_lift = b.step("build-lift", "Build lift binaries");
    build_lift.dependOn(&bench_stats_install.step);
    build_lift.dependOn(&perf_report_install.step);

    const build_cas = b.step("build-cas", "Build cas binaries");
    build_cas.dependOn(&cas_smoke_check_install.step);
    build_cas.dependOn(&cas_instance_runner_install.step);
    build_cas.dependOn(&cas_install.step);

    const build_cron = b.step("build-cron", "Build cron binaries");
    build_cron.dependOn(&cron_install.step);

    const build_puff = b.step("build-puff", "Build puff binaries");
    build_puff.dependOn(&puff_install.step);

    const build_learnings = b.step("build-learnings", "Build learnings binaries");
    build_learnings.dependOn(&learnings_install.step);
    build_learnings.dependOn(&append_learning_install.step);

    addRunStep(b, seq, "run-seq", "Run seq", &.{});
    addRunStep(b, bench_stats, "run-bench-stats", "Run bench_stats", &.{"--help"});
    addRunStep(b, cas_smoke_check, "run-cas-smoke-check", "Run cas_smoke_check", &.{"--help"});
}

fn addExecutable(
    b: *std.Build,
    name: []const u8,
    root_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });
    return exe;
}

fn addInstallStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
) *std.Build.Step.InstallArtifact {
    return b.addInstallArtifact(exe, .{});
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
