const support = @import("../support.zig");
const BuildContext = support.BuildContext;
const SharedModules = support.SharedModules;
const AppSurface = support.AppSurface;

pub fn build(ctx: BuildContext, shared: SharedModules) AppSurface {
    const b = ctx.b;
    const exact_number = ctx.module("libs/definition_core/src/exact_number.zig", &.{});
    const core = ctx.module("apps/assay/src/root.zig", &.{
        .{ .name = "exact_number", .module = exact_number },
        .{ .name = "core_cli", .module = shared.cli },
    });
    const meta = support.addVersionModule(b, @embedFile("../../apps/assay/VERSION"));
    const cli = ctx.module("apps/assay/src/main.zig", &.{
        .{ .name = "assay", .module = core },
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "app_meta", .module = meta },
    });
    const executable = support.addInstalledExecutable(b, "assay", cli);
    support.addRunStep(b, executable.exe, "run-assay", "Run the Assay assessment kernel");
    const core_tests = support.addTestStep(b, core, "test-assay-core", "Test Assay kernel");
    const cli_tests = support.addTestStep(b, cli, "test-assay-cli", "Test Assay entry point");
    const smoke = b.addSystemCommand(&.{"python3"});
    smoke.addFileArg(b.path("apps/assay/scripts/cli_smoke.py"));
    smoke.addArtifactArg(executable.exe);
    smoke.addFileArg(b.path("apps/assay/VERSION"));
    smoke.has_side_effects = true;
    const smoke_step = b.step("test-assay-cli-smoke", "Test Assay executable process behavior");
    smoke_step.dependOn(&smoke.step);
    const acceptance = b.addSystemCommand(&.{"python3"});
    acceptance.addFileArg(b.path("apps/assay/scripts/codec_acceptance.py"));
    acceptance.addArtifactArg(executable.exe);
    acceptance.addDirectoryArg(b.path("apps/assay/fixtures/codec"));
    acceptance.has_side_effects = true;
    const acceptance_step = b.step(
        "test-assay-acceptance",
        "Run the Assay retained codec separating-control suite",
    );
    acceptance_step.dependOn(&acceptance.step);
    const tests = b.step("test-assay", "Run Assay kernel, entry point, and process tests");
    tests.dependOn(&core_tests.step);
    tests.dependOn(&cli_tests.step);
    tests.dependOn(smoke_step);
    tests.dependOn(acceptance_step);
    return support.appSurface(b, .{
        .path = b.path("apps/assay"),
        .build_step_name = "build-assay",
        .build_description = "Build Assay CLI",
        .build_deps = &.{&executable.install.step},
        .test_deps = &.{tests},
    });
}
