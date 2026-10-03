const std = @import("std");

/// Each install operation, not just the aggregate install step, depends on this
/// admission step. Its side-effect flag prevents cached admission of new paths.
pub fn installGuard(b: *std.Build, source: std.Build.LazyPath) *std.Build.Step {
    const executable = b.addExecutable(.{
        .name = "install-guard",
        .root_module = b.createModule(.{
            .root_source_file = source,
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const run = b.addRunArtifact(executable);
    run.addDirectoryArg2(b.path("zig-out"), .{ .make_absolute = true });
    run.addDirectoryArg2(b.graph.path(.install_prefix, ""), .{ .make_absolute = true });
    run.addDirectoryArg2(b.graph.path(.install_bin, ""), .{ .make_absolute = true });
    run.has_side_effects = true;
    const step = b.step("check-local-install", "Reject redirected development installs");
    step.dependOn(&run.step);
    b.getUninstallStep().dependOn(step);
    return step;
}

pub fn guardInstall(b: *std.Build, install: *std.Build.Step.InstallArtifact) void {
    install.step.dependOn(&b.top_level_steps.get("check-local-install").?.step);
}
