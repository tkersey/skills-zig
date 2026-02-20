const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_path = b.createModule(.{
        .root_source_file = b.path("../../libs/core/src/path_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_path", .module = core_path },
        },
    });

    const exe = b.addExecutable(.{
        .name = "seq",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run seq");
    run_step.dependOn(&run_cmd.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_path", .module = core_path },
        },
    });

    const unit_tests = b.addTest(.{
        .root_module = tests_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const perf_mod = b.createModule(.{
        .root_source_file = b.path("src/perf_harness.zig"),
        .target = target,
        .optimize = optimize,
    });

    const perf_exe = b.addExecutable(.{
        .name = "seq-perf",
        .root_module = perf_mod,
    });
    b.installArtifact(perf_exe);

    const perf_run = b.addRunArtifact(perf_exe);
    perf_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| perf_run.addArgs(args);

    const bench_step = b.step("bench", "Run frozen workload performance harness");
    bench_step.dependOn(&perf_run.step);
}
