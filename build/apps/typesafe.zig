const support = @import("../support.zig");
const BuildContext = support.BuildContext;
const SharedModules = support.SharedModules;
const AppSurface = support.AppSurface;

pub fn build(ctx: BuildContext, shared: SharedModules) AppSurface {
    const b = ctx.b;
    const meta = support.addVersionModule(b, @embedFile("../../apps/typesafe/VERSION"));
    const root = ctx.module("apps/typesafe/src/main.zig", &.{
        .{ .name = "core_io", .module = shared.io },
        .{ .name = "app_meta", .module = meta },
    });
    const cli = support.addInstalledExecutable(b, "typesafe", root);
    const tests = support.addTestStep(b, root, "test-typesafe", "Run TypeSafe CLI tests");
    support.addRunStep(b, cli.exe, "run-typesafe", "Run TypeSafe CLI");
    return support.appSurface(b, .{
        .path = b.path("apps/typesafe"),
        .build_step_name = "build-typesafe",
        .build_description = "Build typesafe binary",
        .build_deps = &.{&cli.install.step},
        .test_deps = &.{&tests.step},
    });
}
