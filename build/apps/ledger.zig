const std = @import("std");
const support = @import("../support.zig");
const BuildContext = support.BuildContext;
const SharedModules = support.SharedModules;
const DefinitionApp = support.DefinitionApp;
const InstalledExecutable = support.InstalledExecutable;

pub fn build(ctx: BuildContext, shared: SharedModules) DefinitionApp {
    const b = ctx.b;
    const modules = createLedgerModules(ctx, shared);
    const ledger_storage_root = modules.storage_root;
    const ledger_v1_core = modules.core;
    const ledger_meta = modules.meta;
    const ledger_root = modules.root;
    ledger_root.strip = ctx.optimize == .fast;
    const ledger = support.addInstalledExecutable(b, "ledger", ledger_root);
    const ledger_anchor_probe_step = addLedgerRootAnchorProbe(
        ctx,
        shared,
        ledger_meta,
        ledger_v1_core,
        ledger_storage_root,
    );
    const run_ledger_tests = support.addTestStep(
        b,
        ledger_root,
        "test-ledger-cli",
        "Run Ledger 1.0 command and artifact tests",
    );
    run_ledger_tests.step.dependOn(addLedgerPanicProbe(ctx, ledger_root));
    const run_storage_root_tests = support.addTestStep(
        b,
        ledger_storage_root,
        "test-ledger-storage-root",
        "Run managed Ledger root admission tests",
    );
    const run_ledger_core_tests = support.addTestStep(
        b,
        ledger_v1_core,
        "test-ledger-core",
        "Run Ledger 1.1 artifact-definition compiler tests",
    );
    const run_ledger_cli_smoke = addLedgerCliSmoke(b, ledger.exe);
    const test_ledger = b.step("test-ledger", "Run ledger tests");
    test_ledger.dependOn(&run_ledger_tests.step);
    test_ledger.dependOn(&run_storage_root_tests.step);
    test_ledger.dependOn(&run_ledger_core_tests.step);
    test_ledger.dependOn(run_ledger_cli_smoke);
    test_ledger.dependOn(ledger_anchor_probe_step);
    addLedgerReleaseGate(ctx, ledger, ledger_v1_core, &.{
        &run_ledger_tests.step,      &run_storage_root_tests.step,
        &run_ledger_core_tests.step, run_ledger_cli_smoke,
        ledger_anchor_probe_step,
    });
    support.addRunStep(b, ledger.exe, "run-ledger", "Run ledger");
    return .{
        .core = ledger_v1_core,
        .surface = support.appSurface(b, .{
            .path = b.path("apps/ledger"),
            .build_step_name = "build-ledger",
            .build_description = "Build ledger binary",
            .build_deps = &.{&ledger.install.step},
            .test_deps = &.{
                &run_ledger_tests.step,      &run_storage_root_tests.step,
                &run_ledger_core_tests.step, run_ledger_cli_smoke,
                ledger_anchor_probe_step,
            },
        }),
    };
}

const LedgerModules = struct {
    storage_root: *std.Build.Module,
    core: *std.Build.Module,
    meta: *std.Build.Module,
    root: *std.Build.Module,
};

fn addLedgerPanicProbe(ctx: BuildContext, product: *std.Build.Module) *std.Build.Step {
    const b = ctx.b;
    const root = ctx.fast().module("apps/ledger/src/v1/panic_probe.zig", &.{});
    var imports = product.import_table.iterator();
    while (imports.next()) |entry| root.addImport(entry.key_ptr.*, entry.value_ptr.*);
    const executable = support.addExecutable(b, "ledger-panic-probe", root);
    const run = b.addRunArtifact(executable);
    run.addCheck(.{ .expect_term = .{ .signal = switch (ctx.target.result.cpu.arch) {
        .aarch64 => .TRAP,
        else => .ILL,
    } } });
    run.expectStdErrEqual("ledger panic probe");
    run.expectStdOutEqual("");
    const step = b.step("test-ledger-panic", "Exercise the shipped panic callback");
    step.dependOn(&run.step);
    return step;
}

fn createLedgerModules(ctx: BuildContext, shared: SharedModules) LedgerModules {
    const storage_root = ctx.module("apps/ledger/src/v1/storage_root.zig", &.{
        .{ .name = "durable_store", .module = shared.durable },
    });
    const core = ctx.module("apps/ledger/src/v1/root.zig", &.{
        .{ .name = "core_calendar", .module = shared.calendar },
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "durable_store", .module = shared.durable },
        .{ .name = "storage_root", .module = storage_root },
    });
    const meta = support.addVersionModule(ctx.b, @embedFile("../../apps/ledger/VERSION"));
    const root = ctx.module("apps/ledger/src/v1/main.zig", &.{
        .{ .name = "app_meta", .module = meta },
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "durable_store", .module = shared.durable },
        .{ .name = "ledger_v1_core", .module = core },
        .{ .name = "storage_root", .module = storage_root },
    });
    return .{ .storage_root = storage_root, .core = core, .meta = meta, .root = root };
}

fn addLedgerRootAnchorProbe(
    ctx: BuildContext,
    shared: SharedModules,
    ledger_meta: *std.Build.Module,
    ledger_v1_core: *std.Build.Module,
    ledger_storage_root: *std.Build.Module,
) *std.Build.Step {
    const b = ctx.b;
    const probe_root = ctx.module("apps/ledger/src/v1/root_anchor_probe.zig", &.{
        .{ .name = "app_meta", .module = ledger_meta },
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "durable_store", .module = shared.durable },
        .{ .name = "ledger_v1_core", .module = ledger_v1_core },
        .{ .name = "storage_root", .module = ledger_storage_root },
    });
    const probe = support.addExecutable(b, "ledger-root-anchor-probe", probe_root);
    const run_probe = b.addRunArtifact(probe);
    const step = b.step(
        "test-ledger-root-anchor",
        "Verify managed custody remains pinned after a root swap",
    );
    step.dependOn(&run_probe.step);
    return step;
}

fn addLedgerCliSmoke(b: *std.Build, ledger: *std.Build.Step.Compile) *std.Build.Step {
    const smoke_cmd = b.addSystemCommand(&.{ "bash", "scripts/test-ledger-cli.sh" });
    smoke_cmd.addArtifactArg(ledger);
    const step = b.step(
        "test-ledger-cli-smoke",
        "Run Ledger 1.1 definition, validation, and materialization smoke tests",
    );
    step.dependOn(&smoke_cmd.step);
    return step;
}

fn addLedgerReleaseGate(
    ctx: BuildContext,
    ledger: InstalledExecutable,
    ledger_v1_core: *std.Build.Module,
    routine: []const *std.Build.Step,
) void {
    const b = ctx.b;
    const run_ledger_segmented_tests = support.addTestStepWithOptions(
        b,
        ledger_v1_core,
        "test-ledger-segmented",
        "Run Ledger segmented event-log tests",
        .{ .filters = &.{"segmented"} },
    );
    const run_ledger_segmented_falsifiers = support.addTestStepWithOptions(
        b,
        ledger_v1_core,
        "test-ledger-segmented-falsifiers",
        "Run Ledger segmented event-log falsifiers",
        .{ .filters = &.{"segmented falsifier"} },
    );
    const release_ledger_safe = b.step(
        "release-ledger-safe",
        "Run the Ledger release-safety gate",
    );
    release_ledger_safe.dependOn(&ledger.install.step);
    for (routine) |step| release_ledger_safe.dependOn(step);
    release_ledger_safe.dependOn(&run_ledger_segmented_tests.step);
    release_ledger_safe.dependOn(&run_ledger_segmented_falsifiers.step);
    const ledger_command_surface = b.addSystemCommand(&.{
        "bash",
        "apps/ledger/scripts/release/command_surface_gate.sh",
    });
    ledger_command_surface.addArtifactArg(ledger.exe);
    release_ledger_safe.dependOn(&ledger_command_surface.step);
}
