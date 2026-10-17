const std = @import("std");
const build_support = @import("apps/seq/build_support.zig");
const support = @import("build/support.zig");
const BuildContext = support.BuildContext;
const SharedModules = support.SharedModules;
const AppSurface = support.AppSurface;

pub fn build(b: *std.Build) void {
    _ = build_support.installGuard(b, b.path("tools/install_guard.zig"));
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_support = b.createModule(.{
        .root_source_file = b.path("libs/core/src/testing_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ctx: BuildContext = .{
        .b = b,
        .target = target,
        .optimize = optimize,
        .test_support = test_support,
    };
    const shared = SharedModules.init(ctx);
    const seq = @import("build/apps/seq.zig").build(ctx, shared);
    const ledger = @import("build/apps/ledger.zig").build(ctx, shared);
    const cas = @import("build/apps/cas.zig").build(ctx, shared);
    const surfaces = [_]AppSurface{
        seq.surface,
        @import("build/apps/lift.zig").build(ctx, shared),
        cas.surface,
        ledger.surface,
        @import("build/apps/memory-note.zig").build(ctx, shared),
    };
    for (surfaces) |surface| {
        _ = support.addGroupedStep(
            b,
            surface.build_step_name,
            surface.build_description,
            surface.build_deps,
        );
    }
    const routine = b.step("test", "Run all routine application and core tests");
    for (surfaces) |surface| {
        for (surface.test_deps) |dep| routine.dependOn(dep);
    }
    const full = b.step("test-full", "Run routine tests and explicit slow qualification lanes");
    full.dependOn(routine);
    addSharedTests(ctx, shared, routine);
    addCoreTests(ctx, shared, routine);
    const install_guard_tests = support.addTestStep(
        b,
        ctx.module("tools/install_guard.zig", &.{}),
        "test-install-guard",
        "Test development install admission",
    );
    routine.dependOn(&install_guard_tests.step);
    addSlowTests(ctx, shared, full);
    addPerformance(ctx, shared, seq.core, ledger.core, cas.automation, routine);
    addLint(ctx, &surfaces);
}

fn addSharedTests(ctx: BuildContext, shared: SharedModules, routine: *std.Build.Step) void {
    const b = ctx.b;
    const run_durable_store_tests = support.addTestStep(
        b,
        shared.durable,
        "test-durable-store",
        "Run durable_store tests",
    );
    routine.dependOn(&run_durable_store_tests.step);
    const run_jsonl_core_tests = support.addTestStep(
        b,
        shared.jsonl,
        "test-jsonl-core",
        "Run shared JSONL framing tests",
    );
    routine.dependOn(&run_jsonl_core_tests.step);
    const run_definition_core_tests = support.addTestStep(
        b,
        shared.definitions,
        "test-definition-core",
        "Run passive-definition closure and canonicalization tests",
    );
    routine.dependOn(&run_definition_core_tests.step);
    const run_trace_core_tests = support.addTestStep(
        b,
        shared.trace,
        "test-trace-core",
        "Run canonical physical trace tests",
    );
    routine.dependOn(&run_trace_core_tests.step);
    const definition_core_guard_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/guards/definition-core-domain.sh",
    });
    const run_definition_core_guard = b.step(
        "test-definition-core-guard",
        "Reject domain vocabulary in the neutral definition library",
    );
    run_definition_core_guard.dependOn(&definition_core_guard_cmd.step);
    routine.dependOn(run_definition_core_guard);
}

fn addCoreTests(ctx: BuildContext, shared: SharedModules, routine: *std.Build.Step) void {
    const b = ctx.b;
    const core = b.step("test-core", "Run shared core helper tests");
    core.dependOn(&support.addTestStep(
        b,
        ctx.test_support,
        "test-core-testing",
        "Verify deterministic allocation fault injection",
    ).step);
    const run_calendar_tests = support.addTestStep(
        b,
        shared.calendar,
        "test-core-calendar",
        "Run shared civil calendar compatibility tests",
    );
    core.dependOn(&run_calendar_tests.step);
    core.dependOn(&support.addTestStep(
        b,
        shared.cli,
        "test-core-cli",
        "Run shared cli helper tests",
    ).step);
    core.dependOn(&support.addTestStep(
        b,
        shared.delegate,
        "test-core-delegate",
        "Run shared delegate helper tests",
    ).step);
    core.dependOn(&support.addTestStep(
        b,
        shared.json,
        "test-core-json",
        "Run shared json helper tests",
    ).step);
    core.dependOn(&support.addTestStep(
        b,
        shared.io,
        "test-core-io",
        "Run shared io helper tests",
    ).step);
    core.dependOn(&support.addTestStep(
        b,
        shared.path,
        "test-core-path",
        "Run shared path helper tests",
    ).step);
    core.dependOn(&support.addTestStep(
        b,
        shared.perf,
        "test-core-perf",
        "Run shared perf helper tests",
    ).step);
    routine.dependOn(core);
}

fn addSlowTests(ctx: BuildContext, shared: SharedModules, full: *std.Build.Step) void {
    const b = ctx.b;
    const jsonl_large_tests_root = ctx.fast().module(
        "libs/jsonl_core/tests/jsonl_stream_large.zig",
        &.{
            .{ .name = "jsonl_stream", .module = shared.jsonl_fast },
        },
    );
    const canonical_json_corpus_tests_root = ctx.fast().module(
        "libs/definition_core/tests/canonical_json_corpus.zig",
        &.{
            .{ .name = "canonical_json", .module = shared.canonical_fast },
        },
    );
    const run_jsonl_large_tests = support.addTestStep(
        b,
        jsonl_large_tests_root,
        "test-jsonl-core-large",
        "Run the greater-than-256-MiB streaming regression in ReleaseFast",
    );
    const test_jsonl_stream_large = b.step(
        "test-jsonl-stream-large",
        "Run the greater-than-256-MiB streaming regression in ReleaseFast",
    );
    test_jsonl_stream_large.dependOn(&run_jsonl_large_tests.step);
    full.dependOn(test_jsonl_stream_large);
    const run_canonical_json_corpus_tests = support.addTestStep(
        b,
        canonical_json_corpus_tests_root,
        "test-canonical-json-corpus",
        "Run the broad deterministic float corpus in ReleaseFast",
    );
    full.dependOn(&run_canonical_json_corpus_tests.step);
}

fn addPerformance(
    ctx: BuildContext,
    shared: SharedModules,
    seq_v1_core: *std.Build.Module,
    ledger_v1_core: *std.Build.Module,
    cas_automation_root: *std.Build.Module,
    routine: *std.Build.Step,
) void {
    const b = ctx.b;
    const perf_hub_root = ctx.module("tools/perf_hub.zig", &.{
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "core_perf", .module = shared.perf },
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "durable_store", .module = shared.durable },
        .{ .name = "perf_contract", .module = shared.perf_contract },
        .{ .name = "cas_automation_cli", .module = cas_automation_root },
        .{ .name = "seq_v1_core", .module = seq_v1_core },
    });
    const perf_hub = support.addInstalledExecutable(b, "perf_hub", perf_hub_root);
    const run_perf_hub_tests = support.addTestStep(
        b,
        perf_hub_root,
        "test-perf-hub",
        "Run perf_hub tests",
    );
    run_perf_hub_tests.setEnvironmentVariable("PERF_TEST_ZIG", b.graph.zig_exe);
    const replay_driver = b.addExecutable(.{
        .name = "seq-replay-driver-check",
        .root_module = ctx.module("tools/seq_replay_driver.zig", &.{
            .{ .name = "core_perf", .module = shared.perf },
            .{ .name = "definition_core", .module = shared.definitions },
            .{ .name = "seq_v1_core", .module = seq_v1_core },
        }),
    });
    run_perf_hub_tests.step.dependOn(&replay_driver.step);
    routine.dependOn(&run_perf_hub_tests.step);
    addDurableStorePerformance(ctx, shared, routine);
    addOptimizationTests(ctx, shared, ledger_v1_core, routine);
    addPerformanceRunSteps(b, perf_hub.exe);
}

fn addDurableStorePerformance(
    ctx: BuildContext,
    shared: SharedModules,
    routine: *std.Build.Step,
) void {
    const b = ctx.b;
    const durable_store_perf_root = ctx.fast().module("tools/durable_store_perf.zig", &.{
        .{ .name = "durable_store", .module = shared.durable_fast },
    });
    const durable_store_perf = support.addExecutable(
        b,
        "durable-store-perf",
        durable_store_perf_root,
    );
    support.addBenchStep(
        b,
        durable_store_perf,
        "perf-durable-store-local",
        "Measure durable_store scan and append resource use",
    );
    const run_durable_store_perf_tests = support.addTestStep(
        b,
        durable_store_perf_root,
        "test-durable-store-perf",
        "Run durable_store performance-contract tests",
    );
    routine.dependOn(&run_durable_store_perf_tests.step);
}

fn addOptimizationTests(
    ctx: BuildContext,
    shared: SharedModules,
    ledger_v1_core: *std.Build.Module,
    routine: *std.Build.Step,
) void {
    const driver = ctx.module("tools/optimization_driver.zig", &.{
        .{ .name = "core_perf", .module = shared.perf },
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "ledger_v1_core", .module = ledger_v1_core },
        .{ .name = "trace_core", .module = shared.trace },
    });
    const tests = support.addTestStepWithOptions(
        ctx.b,
        driver,
        "test-optimization-driver",
        "Run optimization workload and oracle tests",
        .{ .filters = &.{"optimization"} },
    );
    routine.dependOn(&tests.step);
}

fn addPerformanceRunSteps(b: *std.Build, perf_hub: *std.Build.Step.Compile) void {
    support.addRunStepPrefixed(b, perf_hub, "perf-list-local", "List local perf cases", &.{"list"});
    support.addRunStepPrefixed(
        b,
        perf_hub,
        "perf-manifest-local",
        "Emit native perf manifest",
        &.{"manifest"},
    );
    support.addRunStepPrefixed(
        b,
        perf_hub,
        "perf-audit-local",
        "Audit native perf coverage",
        &.{"audit"},
    );
    support.addRunStepPrefixed(
        b,
        perf_hub,
        "perf-doctor-local",
        "Validate local perf coverage and setup",
        &.{"doctor"},
    );
    support.addRunStepPrefixed(
        b,
        perf_hub,
        "perf-compare-local",
        "Run a sealed paired perf comparison",
        &.{"compare"},
    );
    support.addRunStepPrefixed(
        b,
        perf_hub,
        "perf-report-local",
        "Verify and summarize the current perf capsule",
        &.{"report"},
    );
}

fn addLint(ctx: BuildContext, app_surfaces: []const AppSurface) void {
    const b = ctx.b;
    const enable_zlinter = b.option(
        bool,
        "enable_zlinter",
        "Internal flag to run zlinter-backed lint directly",
    ) orelse false;
    const lint_step = b.step("lint", "Run zlinter checks");
    if (enable_zlinter) {
        lint_step.dependOn(buildLintStep(b, ctx.target, app_surfaces));
    } else {
        const lint_cmd = b.addSystemCommand(
            &.{
                b.graph.zig_exe, "build", "lint", "-Doptimize=fast", "-Denable_zlinter=true", "--",
            },
        );
        lint_cmd.addPassthruArgs();
        lint_step.dependOn(&lint_cmd.step);
    }
}

fn buildLintStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    app_surfaces: []const AppSurface,
) *std.Build.Step {
    const zlinter = @import("zlinter");
    var lint_builder = zlinter.builder(b, .{
        .target = target,
        .optimize = .fast,
    });
    for (app_surfaces) |surface| {
        lint_builder.addPaths(.{ .include_dirs = &.{surface.path} });
    }
    lint_builder.addPaths(.{
        .include_dirs = &.{
            b.path("build"),
            b.path("libs"),
            b.path("tools"),
        },
    });
    lint_builder.addPaths(.{ .include_files = &.{b.path("build.zig")} });
    lint_builder.addRule(.{ .builtin = .no_unused }, .{});
    const step = lint_builder.build();
    @import("tools/zlinter_compat.zig").apply(b, step);
    return step;
}
