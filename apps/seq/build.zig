const std = @import("std");

pub fn build(b: *std.Build) void {
    enforceRepoLocalInstallOnly(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_path = b.createModule(.{
        .root_source_file = b.path("../../libs/core/src/path_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_perf = b.createModule(.{
        .root_source_file = b.path("../../libs/core/src/perf_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_cli = b.createModule(.{
        .root_source_file = b.path("../../libs/core/src/cli_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const seq_meta = addVersionModule(b, @embedFile("VERSION"));

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_path", .module = core_path },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = seq_meta },
        },
    });

    const exe = b.addExecutable(.{
        .name = "seq",
        .root_module = root_module,
    });
    exe.linkLibC();
    exe.root_module.linkSystemLibrary("sqlite3", .{});

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
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = seq_meta },
        },
    });

    const unit_tests = b.addTest(.{
        .root_module = tests_mod,
    });
    unit_tests.linkLibC();
    unit_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const perf_mod = b.createModule(.{
        .root_source_file = b.path("src/perf_harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = seq_meta },
        },
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

    const parser_perf_mod = b.createModule(.{
        .root_source_file = b.path("src/perf_parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_perf", .module = core_perf },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = seq_meta },
        },
    });

    const parser_perf_exe = b.addExecutable(.{
        .name = "seq-perf-parser",
        .root_module = parser_perf_mod,
    });
    b.installArtifact(parser_perf_exe);

    const parser_perf_run = b.addRunArtifact(parser_perf_exe);
    parser_perf_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| parser_perf_run.addArgs(args);

    const parser_bench_step = b.step("bench-parser", "Run token parser performance harness");
    parser_bench_step.dependOn(&parser_perf_run.step);
}

fn addVersionModule(b: *std.Build, raw_version: []const u8) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "version", std.mem.trim(u8, raw_version, " \t\r\n"));
    return options.createModule();
}

fn enforceRepoLocalInstallOnly(b: *std.Build) void {
    const expected_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    defer b.allocator.free(expected_prefix);

    const expected_exe_dir = b.pathJoin(&.{ expected_prefix, "bin" });
    defer b.allocator.free(expected_exe_dir);

    if (b.dest_dir != null or
        !std.mem.eql(u8, b.install_prefix, expected_prefix) or
        !std.mem.eql(u8, b.install_path, expected_prefix) or
        !std.mem.eql(u8, b.exe_dir, expected_exe_dir))
    {
        std.debug.panic(
            "skills-zig forbids external installs; ship CLIs via the Homebrew tap release flow only. expected install_prefix={s} exe_dir={s}; got install_prefix={s} exe_dir={s} dest_dir={?s}",
            .{ expected_prefix, expected_exe_dir, b.install_prefix, b.exe_dir, b.dest_dir },
        );
    }
}
