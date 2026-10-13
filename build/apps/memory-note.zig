const support = @import("../support.zig");
const BuildContext = support.BuildContext;
const SharedModules = support.SharedModules;
const AppSurface = support.AppSurface;

pub fn build(ctx: BuildContext, shared: SharedModules) AppSurface {
    const b = ctx.b;
    const memory_note_meta = support.addVersionModule(
        b,
        @embedFile("../../apps/memory-note/VERSION"),
    );
    const memory_note_root = ctx.module("apps/memory-note/scripts/memory_note.zig", &.{
        .{ .name = "core_calendar", .module = shared.calendar },
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "durable_store", .module = shared.durable },
        .{ .name = "app_meta", .module = memory_note_meta },
    });
    const memory_note = support.addInstalledExecutable(b, "memory-note", memory_note_root);
    const run_memory_note_tests = support.addTestStep(
        b,
        memory_note_root,
        "test-memory-note",
        "Run memory-note tests",
    );
    support.addRunStep(b, memory_note.exe, "run-memory-note", "Run memory-note");
    return support.appSurface(b, .{
        .path = b.path("apps/memory-note"),
        .build_step_name = "build-memory-note",
        .build_description = "Build memory-note binary",
        .build_deps = &.{&memory_note.install.step},
        .test_deps = &.{&run_memory_note_tests.step},
    });
}
