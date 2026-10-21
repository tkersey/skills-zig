const std = @import("std");
const support = @import("../support.zig");
const BuildContext = support.BuildContext;
const SharedModules = support.SharedModules;
const AppSurface = support.AppSurface;

pub fn build(ctx: BuildContext, shared: SharedModules) AppSurface {
    const b = ctx.b;
    const core = b.addModule("siwc", .{
        .root_source_file = b.path("libs/siwc/src/root.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{
            .{ .name = "core_io", .module = shared.io },
            .{ .name = "durable_store", .module = shared.durable },
            .{ .name = "test_support", .module = ctx.test_support },
        },
    });
    core.linkSystemLibrary("c", .{});
    const meta = support.addVersionModule(b, @embedFile("../../apps/siwc/VERSION"));
    const cli = ctx.module("apps/siwc/src/main.zig", &.{
        .{ .name = "siwc", .module = core },
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "app_meta", .module = meta },
    });
    const executable = support.addInstalledExecutable(b, "siwc", cli);
    support.addRunStep(b, executable.exe, "run-siwc", "Run Sign in with ChatGPT");
    const core_tests = support.addTestStep(b, core, "test-siwc-core", "Test SIWC authentication");
    const cli_tests = support.addTestStep(b, cli, "test-siwc-cli", "Test SIWC command admission");
    const process_gate = b.addSystemCommand(&.{"bash"});
    process_gate.addFileArg(b.path("apps/siwc/scripts/command_surface_gate.sh"));
    process_gate.addArtifactArg(executable.exe);
    process_gate.addFileArg(b.path("apps/siwc/VERSION"));
    process_gate.has_side_effects = true;
    const process_tests = b.step("test-siwc-process", "Test SIWC executable process behavior");
    process_tests.dependOn(&process_gate.step);
    const tests = b.step("test-siwc", "Run SIWC authentication and command tests");
    tests.dependOn(&core_tests.step);
    tests.dependOn(&cli_tests.step);
    tests.dependOn(process_tests);
    return support.appSurface(b, .{
        .path = b.path("apps/siwc"),
        .build_step_name = "build-siwc",
        .build_description = "Build Sign in with ChatGPT CLI",
        .build_deps = &.{&executable.install.step},
        .test_deps = &.{tests},
    });
}
