const std = @import("std");

pub fn build(b: *std.Build) void {
    enforceRepoLocalInstallOnly(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const jsonl_core = b.createModule(.{
        .root_source_file = b.path("../../libs/jsonl_core/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const durable_store = b.createModule(.{
        .root_source_file = b.path("../../libs/durable_store/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jsonl_core", .module = jsonl_core },
        },
    });
    const definition_core = b.createModule(.{
        .root_source_file = b.path("../../libs/definition_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const trace_core = b.createModule(.{
        .root_source_file = b.path("../../libs/trace_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jsonl_core", .module = jsonl_core },
        },
    });
    const seq_time = b.createModule(.{
        .root_source_file = b.path("src/time_utils.zig"),
        .target = target,
        .optimize = optimize,
    });
    const seq_core = b.createModule(.{
        .root_source_file = b.path("src/v1/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "definition_core", .module = definition_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "jsonl_core", .module = jsonl_core },
            .{ .name = "trace_core", .module = trace_core },
            .{ .name = "seq_time", .module = seq_time },
        },
    });
    const seq_meta = addVersionModule(b, @embedFile("VERSION"));
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/v1/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
        .imports = &.{
            .{ .name = "app_meta", .module = seq_meta },
            .{ .name = "definition_core", .module = definition_core },
            .{ .name = "seq_v1_core", .module = seq_core },
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
    const run_step = b.step("run", "Run Seq");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run Seq 1.0 tests");
    test_step.dependOn(&run_unit_tests.step);
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
