const std = @import("std");
const cas_build = @import("apps/cas/build_support.zig");

pub fn build(b: *std.Build) void {
    enforceRepoLocalInstallOnly(b);
    const ctx: BuildContext = .{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };
    const cas_release = cas_build.Options.init(b);
    const shared = SharedModules.init(ctx);
    const seq = buildSeq(ctx, shared);
    const ledger = buildLedger(ctx, shared);
    const cas = buildCas(ctx, shared, cas_release);
    const surfaces = [_]AppSurface{
        seq.surface,
        buildLift(ctx, shared),
        cas.surface,
        ledger.surface,
        buildMemoryNote(ctx, shared),
        buildImg(ctx),
    };
    for (surfaces) |surface| {
        _ = addGroupedStep(
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
    addSlowTests(ctx, shared, full);
    addPerformance(ctx, shared, seq.core, ledger.core, cas.automation, routine);
    addLint(ctx, &surfaces);
}

const BuildContext = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    fn module(
        self: BuildContext,
        path: []const u8,
        imports: []const std.Build.Module.Import,
    ) *std.Build.Module {
        return self.b.createModule(.{
            .root_source_file = self.b.path(path),
            .target = self.target,
            .optimize = self.optimize,
            .imports = imports,
        });
    }

    fn fast(self: BuildContext) BuildContext {
        var result = self;
        result.optimize = .ReleaseFast;
        return result;
    }
};

const SharedModules = struct {
    calendar: *std.Build.Module,
    json: *std.Build.Module,
    io: *std.Build.Module,
    path: *std.Build.Module,
    cli: *std.Build.Module,
    delegate: *std.Build.Module,
    perf: *std.Build.Module,
    perf_contract: *std.Build.Module,
    jsonl: *std.Build.Module,
    durable: *std.Build.Module,
    compat: *std.Build.Module,
    definitions: *std.Build.Module,
    trace: *std.Build.Module,
    jsonl_fast: *std.Build.Module,
    durable_fast: *std.Build.Module,
    canonical_fast: *std.Build.Module,

    fn init(ctx: BuildContext) SharedModules {
        const core_calendar = ctx.module("libs/core/src/calendar.zig", &.{});
        const core_json = ctx.module("libs/core/src/json_helpers.zig", &.{});
        const core_io = ctx.module("libs/core/src/io_helpers.zig", &.{});
        const core_path = ctx.module("libs/core/src/path_helpers.zig", &.{});
        const core_cli = ctx.module("libs/core/src/cli_helpers.zig", &.{});
        const core_delegate = ctx.module("libs/core/src/delegate_helpers.zig", &.{
            .{ .name = "core_cli", .module = core_cli },
        });
        const core_perf = ctx.module("libs/core/src/perf_helpers.zig", &.{});
        const core_perf_contract = ctx.module("tools/perf_contract.zig", &.{});
        const jsonl_core = ctx.module("libs/jsonl_core/src/lib.zig", &.{});
        const durable_store = ctx.module("libs/durable_store/src/lib.zig", &.{
            .{ .name = "jsonl_core", .module = jsonl_core },
        });
        const definition_compat = ctx.module("libs/definition_compat/src/root.zig", &.{});
        const definition_core = ctx.module("libs/definition_core/src/root.zig", &.{
            .{ .name = "definition_compat", .module = definition_compat },
        });
        const trace_core = ctx.module("libs/trace_core/src/root.zig", &.{
            .{ .name = "jsonl_core", .module = jsonl_core },
        });
        const jsonl_fast = ctx.fast().module("libs/jsonl_core/src/lib.zig", &.{});
        const durable_fast = ctx.fast().module("libs/durable_store/src/lib.zig", &.{
            .{ .name = "jsonl_core", .module = jsonl_fast },
        });
        const canonical_fast = ctx.fast().module(
            "libs/definition_core/src/canonical_json.zig",
            &.{},
        );
        return .{
            .jsonl_fast = jsonl_fast,
            .durable_fast = durable_fast,
            .canonical_fast = canonical_fast,
            .calendar = core_calendar,
            .json = core_json,
            .io = core_io,
            .path = core_path,
            .cli = core_cli,
            .delegate = core_delegate,
            .perf = core_perf,
            .perf_contract = core_perf_contract,
            .jsonl = jsonl_core,
            .durable = durable_store,
            .compat = definition_compat,
            .definitions = definition_core,
            .trace = trace_core,
        };
    }
};

const DefinitionApp = struct {
    surface: AppSurface,
    core: *std.Build.Module,
};

fn buildSeq(ctx: BuildContext, shared: SharedModules) DefinitionApp {
    const b = ctx.b;
    const seq_time = ctx.module("apps/seq/src/time_utils.zig", &.{
        .{ .name = "core_calendar", .module = shared.calendar },
    });
    const seq_v1_core = ctx.module("apps/seq/src/v1/root.zig", &.{
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "durable_store", .module = shared.durable },
        .{ .name = "jsonl_core", .module = shared.jsonl },
        .{ .name = "trace_core", .module = shared.trace },
        .{ .name = "seq_time", .module = seq_time },
    });
    const seq_meta = addVersionModule(b, @embedFile("apps/seq/VERSION"));
    const seq_root = ctx.module("apps/seq/src/v1/main.zig", &.{
        .{ .name = "app_meta", .module = seq_meta },
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "seq_v1_core", .module = seq_v1_core },
    });
    seq_root.strip = ctx.optimize == .ReleaseFast;
    const seq = addInstalledExecutable(b, "seq", seq_root);
    const run_seq_tests = addTestStep(
        b,
        seq_root,
        "test-seq",
        "Run Seq 1.0 command and observation tests",
    );
    const run_seq_core_tests = addTestStep(
        b,
        seq_v1_core,
        "test-seq-core",
        "Run Seq 1.0 observation-definition compiler tests",
    );
    const seq_cli_smoke_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/test-seq-cli.sh",
    });
    seq_cli_smoke_cmd.addArtifactArg(seq.exe);
    const run_seq_cli_smoke = b.step(
        "test-seq-cli-smoke",
        "Run Seq 1.0 definition and observation smoke tests",
    );
    run_seq_cli_smoke.dependOn(&seq_cli_smoke_cmd.step);
    addRunStep(b, seq.exe, "run-seq", "Run seq", &.{});
    return .{
        .core = seq_v1_core,
        .surface = appSurface(b, .{
            .path = b.path("apps/seq"),
            .build_step_name = "build-seq",
            .build_description = "Build seq binary",
            .build_deps = &.{&seq.install.step},
            .test_deps = &.{ &run_seq_tests.step, &run_seq_core_tests.step, run_seq_cli_smoke },
        }),
    };
}

fn buildLedger(ctx: BuildContext, shared: SharedModules) DefinitionApp {
    const b = ctx.b;
    const ledger_v1_core = ctx.module("apps/ledger/src/v1/root.zig", &.{
        .{ .name = "core_calendar", .module = shared.calendar },
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "durable_store", .module = shared.durable },
    });
    const ledger_meta = addVersionModule(b, @embedFile("apps/ledger/VERSION"));
    const ledger_root = ctx.module("apps/ledger/src/v1/main.zig", &.{
        .{ .name = "app_meta", .module = ledger_meta },
        .{ .name = "definition_core", .module = shared.definitions },
        .{ .name = "durable_store", .module = shared.durable },
        .{ .name = "ledger_v1_core", .module = ledger_v1_core },
    });
    ledger_root.strip = ctx.optimize == .ReleaseFast;
    const ledger = addInstalledExecutable(b, "ledger", ledger_root);
    const run_ledger_tests = addTestStep(
        b,
        ledger_root,
        "test-ledger-cli",
        "Run Ledger 1.0 command and artifact tests",
    );
    const run_ledger_core_tests = addTestStep(
        b,
        ledger_v1_core,
        "test-ledger-core",
        "Run Ledger 1.1 artifact-definition compiler tests",
    );
    const ledger_cli_smoke_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/test-ledger-cli.sh",
    });
    ledger_cli_smoke_cmd.addArtifactArg(ledger.exe);
    const run_ledger_cli_smoke = b.step(
        "test-ledger-cli-smoke",
        "Run Ledger 1.1 definition, validation, and materialization smoke tests",
    );
    run_ledger_cli_smoke.dependOn(&ledger_cli_smoke_cmd.step);
    const test_ledger = b.step("test-ledger", "Run ledger tests");
    test_ledger.dependOn(&run_ledger_tests.step);
    test_ledger.dependOn(&run_ledger_core_tests.step);
    test_ledger.dependOn(run_ledger_cli_smoke);
    addLedgerReleaseGate(ctx, ledger, ledger_v1_core, &.{
        &run_ledger_tests.step, &run_ledger_core_tests.step, run_ledger_cli_smoke,
    });
    addRunStep(b, ledger.exe, "run-ledger", "Run ledger", &.{"--help"});
    return .{
        .core = ledger_v1_core,
        .surface = appSurface(b, .{
            .path = b.path("apps/ledger"),
            .build_step_name = "build-ledger",
            .build_description = "Build ledger binary",
            .build_deps = &.{&ledger.install.step},
            .test_deps = &.{
                &run_ledger_tests.step, &run_ledger_core_tests.step, run_ledger_cli_smoke,
            },
        }),
    };
}

fn addLedgerReleaseGate(
    ctx: BuildContext,
    ledger: InstalledExecutable,
    ledger_v1_core: *std.Build.Module,
    routine: []const *std.Build.Step,
) void {
    const b = ctx.b;
    const run_ledger_segmented_tests = addTestStepWithOptions(
        b,
        ledger_v1_core,
        "test-ledger-segmented",
        "Run Ledger segmented event-log tests",
        .{ .filters = &.{"segmented"} },
    );
    const run_ledger_segmented_falsifiers = addTestStepWithOptions(
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

fn buildMemoryNote(ctx: BuildContext, shared: SharedModules) AppSurface {
    const b = ctx.b;
    const memory_note_meta = addVersionModule(b, @embedFile("apps/memory-note/VERSION"));
    const memory_note_root = ctx.module("apps/memory-note/scripts/memory_note.zig", &.{
        .{ .name = "core_calendar", .module = shared.calendar },
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "durable_store", .module = shared.durable },
        .{ .name = "app_meta", .module = memory_note_meta },
    });
    const memory_note = addInstalledExecutable(b, "memory-note", memory_note_root);
    const run_memory_note_tests = addTestStep(
        b,
        memory_note_root,
        "test-memory-note",
        "Run memory-note tests",
    );
    addRunStep(b, memory_note.exe, "run-memory-note", "Run memory-note", &.{"--help"});
    return appSurface(b, .{
        .path = b.path("apps/memory-note"),
        .build_step_name = "build-memory-note",
        .build_description = "Build memory-note binary",
        .build_deps = &.{&memory_note.install.step},
        .test_deps = &.{&run_memory_note_tests.step},
    });
}

fn buildImg(ctx: BuildContext) AppSurface {
    const b = ctx.b;
    const img_meta = addVersionModule(b, @embedFile("apps/img/VERSION"));
    const img_atlas = ctx.module("apps/img/assets/atlas.zig", &.{});
    const img_root = ctx.module("apps/img/src/main.zig", &.{
        .{ .name = "app_meta", .module = img_meta },
        .{ .name = "img_atlas", .module = img_atlas },
    });
    const img_tests_root = ctx.module("apps/img/src/tests.zig", &.{
        .{ .name = "img_atlas", .module = img_atlas },
    });
    const img = addInstalledExecutable(b, "img", img_root);
    const run_img_tests = addTestStep(
        b,
        img_tests_root,
        "test-img",
        "Run img tests",
    );
    addRunStep(b, img.exe, "run-img", "Run img", &.{"--help"});
    return appSurface(b, .{
        .path = b.path("apps/img"),
        .build_step_name = "build-img",
        .build_description = "Build img binary",
        .build_deps = &.{&img.install.step},
        .test_deps = &.{&run_img_tests.step},
    });
}

fn buildLift(ctx: BuildContext, shared: SharedModules) AppSurface {
    const b = ctx.b;
    const lift_meta = addVersionModule(b, @embedFile("apps/lift/VERSION"));
    const lift_bench_root = ctx.module("apps/lift/scripts/bench_stats.zig", &.{
        .{ .name = "core_io", .module = shared.io },
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "app_meta", .module = lift_meta },
    });
    const lift_report_root = ctx.module("apps/lift/scripts/perf_report.zig", &.{
        .{ .name = "core_calendar", .module = shared.calendar },
        .{ .name = "core_io", .module = shared.io },
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "app_meta", .module = lift_meta },
    });
    const lift_bench_perf_root = ctx.module("apps/lift/scripts/perf_bench_stats.zig", &.{
        .{ .name = "core_io", .module = shared.io },
        .{ .name = "core_perf", .module = shared.perf },
        .{ .name = "core_cli", .module = shared.cli },
        .{ .name = "app_meta", .module = lift_meta },
    });
    const bench_stats = addInstalledExecutable(b, "bench_stats", lift_bench_root);
    const perf_report = addInstalledExecutable(b, "perf_report", lift_report_root);
    const lift_bench_perf = addInstalledExecutable(
        b,
        "lift-perf-bench-stats",
        lift_bench_perf_root,
    );
    addBenchStep(
        b,
        lift_bench_perf.exe,
        "bench-lift-bench-stats",
        "Run bench_stats performance harness",
    );
    const test_lift = addLiftTests(b, lift_bench_root, lift_report_root, lift_bench_perf_root);
    addRunStep(b, bench_stats.exe, "run-bench-stats", "Run bench_stats", &.{"--help"});
    return appSurface(b, .{
        .path = b.path("apps/lift"),
        .build_step_name = "build-lift",
        .build_description = "Build lift binaries",
        .build_deps = &.{
            &bench_stats.install.step, &perf_report.install.step, &lift_bench_perf.install.step,
        },
        .test_deps = &.{test_lift},
    });
}

fn addLiftTests(
    b: *std.Build,
    lift_bench_root: *std.Build.Module,
    lift_report_root: *std.Build.Module,
    lift_bench_perf_root: *std.Build.Module,
) *std.Build.Step {
    const run_lift_bench_tests = addTestStep(
        b,
        lift_bench_root,
        "test-lift-bench-stats",
        "Run bench_stats tests",
    );
    const run_lift_report_tests = addTestStep(
        b,
        lift_report_root,
        "test-lift-perf-report",
        "Run perf_report tests",
    );
    const run_lift_bench_perf_tests = addTestStep(
        b,
        lift_bench_perf_root,
        "test-lift-perf-bench-stats",
        "Run perf_bench_stats tests",
    );
    const test_lift = b.step("test-lift", "Run all lift tests");
    test_lift.dependOn(&run_lift_bench_tests.step);
    test_lift.dependOn(&run_lift_report_tests.step);
    test_lift.dependOn(&run_lift_bench_perf_tests.step);
    return test_lift;
}

const CasRuntimeModules = struct {
    runtime: *std.Build.Module,
    proxy: *std.Build.Module,
    anchor: *std.Build.Module,
    contract: *std.Build.Module,
    probes: *std.Build.Module,
    transport_tests: *std.Build.Module,

    fn init(ctx: BuildContext, shared: SharedModules) CasRuntimeModules {
        const cas_runtime_root = ctx.module("libs/cas_runtime/src/root.zig", &.{
            .{ .name = "core_json", .module = shared.json },
        });
        const cas_proxy_client_root = ctx.module("apps/cas/scripts/cas_proxy_client.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
        });
        const cas_session_inquiry_anchor_root = ctx.module(
            "apps/cas/scripts/cas_session_inquiry_anchor.zig",
            &.{},
        );
        const b = ctx.b;
        const cas_app_server_contract_data = b.addOptions();
        cas_app_server_contract_data.addOption(
            []const u8,
            "json",
            @embedFile("apps/cas/contracts/codex-app-server-capabilities-v2.json"),
        );
        const cas_app_server_contract_root = ctx.module(
            "apps/cas/scripts/cas_app_server_contract.zig",
            &.{
                .{
                    .name = "cas_app_server_contract_data",
                    .module = cas_app_server_contract_data.createModule(),
                },
                .{ .name = "definition_core", .module = shared.definitions },
                .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
            },
        );
        const cas_app_server_probes_root = ctx.module(
            "apps/cas/scripts/cas_app_server_probes.zig",
            &.{
                .{ .name = "cas_app_server_contract", .module = cas_app_server_contract_root },
                .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
                .{
                    .name = "cas_session_inquiry_anchor",
                    .module = cas_session_inquiry_anchor_root,
                },
            },
        );
        const cas_transport_tests_root = ctx.module("apps/cas/scripts/cas_transport_tests.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
        });
        return .{
            .runtime = cas_runtime_root,
            .proxy = cas_proxy_client_root,
            .anchor = cas_session_inquiry_anchor_root,
            .contract = cas_app_server_contract_root,
            .probes = cas_app_server_probes_root,
            .transport_tests = cas_transport_tests_root,
        };
    }
};

const CasCommandModules = struct {
    smoke: *std.Build.Module,
    runner: *std.Build.Module,
    review: *std.Build.Module,
    inquiry: *std.Build.Module,
    conformance: *std.Build.Module,
    goal: *std.Build.Module,
    account: *std.Build.Module,

    fn init(
        ctx: BuildContext,
        shared: SharedModules,
        runtime: CasRuntimeModules,
        cas_meta: *std.Build.Module,
    ) CasCommandModules {
        const cas_smoke_root = ctx.module("apps/cas/scripts/cas_smoke_check.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
        });
        const cas_runner_root = ctx.module("apps/cas/scripts/cas_instance_runner.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
        });
        const cas_review_session_root = ctx.module("apps/cas/scripts/cas_review_session.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "core_path", .module = shared.path },
            .{ .name = "durable_store", .module = shared.durable },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
        });
        const cas_session_inquiry_root = inquiryModule(ctx, shared, runtime, cas_meta);
        const cas_conformance_root = ctx.module("apps/cas/scripts/cas_conformance_suite.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_proxy_client", .module = runtime.proxy },
        });
        const cas_goal_root = ctx.module("apps/cas/scripts/cas_goal.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
        });
        const cas_account_root = ctx.module("apps/cas/scripts/cas_account.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_io", .module = shared.io },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
        });
        return .{
            .smoke = cas_smoke_root,
            .runner = cas_runner_root,
            .review = cas_review_session_root,
            .inquiry = cas_session_inquiry_root,
            .conformance = cas_conformance_root,
            .goal = cas_goal_root,
            .account = cas_account_root,
        };
    }

    fn inquiryModule(
        ctx: BuildContext,
        shared: SharedModules,
        runtime: CasRuntimeModules,
        cas_meta: *std.Build.Module,
    ) *std.Build.Module {
        return ctx.module("apps/cas/scripts/cas_session_inquiry.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "core_path", .module = shared.path },
            .{ .name = "definition_core", .module = shared.definitions },
            .{ .name = "trace_core", .module = shared.trace },
            .{ .name = "durable_store", .module = shared.durable },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = runtime.runtime },
            .{
                .name = "cas_session_inquiry_anchor",
                .module = runtime.anchor,
            },
        });
    }
};

const CasAdminModules = struct {
    preflight: *std.Build.Module,
    budget: *std.Build.Module,
    budget_perf: *std.Build.Module,
    dispatcher: *std.Build.Module,
    automation: *std.Build.Module,

    fn init(
        ctx: BuildContext,
        shared: SharedModules,
        runtime: CasRuntimeModules,
        cas_meta: *std.Build.Module,
    ) CasAdminModules {
        const cas_app_server_preflight_root = ctx.module(
            "apps/cas/scripts/cas_app_server_preflight.zig",
            &.{
                .{ .name = "app_meta", .module = cas_meta },
                .{ .name = "cas_app_server_contract", .module = runtime.contract },
                .{ .name = "cas_app_server_probes", .module = runtime.probes },
                .{ .name = "cas_proxy_client", .module = runtime.proxy },
            },
        );
        const cas_budget_governor_root = ctx.module("apps/cas/scripts/budget_governor.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_io", .module = shared.io },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
        });
        const cas_budget_perf_root = ctx.module("apps/cas/scripts/perf_budget_governor.zig", &.{
            .{ .name = "core_json", .module = shared.json },
            .{ .name = "core_io", .module = shared.io },
            .{ .name = "core_perf", .module = shared.perf },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
        });
        const cas_root = ctx.module("apps/cas/scripts/cas.zig", &.{
            .{ .name = "core_delegate", .module = shared.delegate },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
        });
        const cas_automation_root = ctx.module("apps/cas/scripts/cas_automation.zig", &.{
            .{ .name = "core_calendar", .module = shared.calendar },
            .{ .name = "core_delegate", .module = shared.delegate },
            .{ .name = "core_cli", .module = shared.cli },
            .{ .name = "app_meta", .module = cas_meta },
        });
        return .{
            .preflight = cas_app_server_preflight_root,
            .budget = cas_budget_governor_root,
            .budget_perf = cas_budget_perf_root,
            .dispatcher = cas_root,
            .automation = cas_automation_root,
        };
    }
};

const CasBuild = struct {
    surface: AppSurface,
    automation: *std.Build.Module,
};

fn buildCas(ctx: BuildContext, shared: SharedModules, release: cas_build.Options) CasBuild {
    const b = ctx.b;
    const meta = addVersionModule(b, @embedFile("apps/cas/VERSION"));
    const runtime = CasRuntimeModules.init(ctx, shared);
    const commands = CasCommandModules.init(ctx, shared, runtime, meta);
    const admin = CasAdminModules.init(ctx, shared, runtime, meta);
    const artifacts = CasArtifacts.init(ctx, commands, admin, release);
    const tests = b.step("test-cas", "Run all cas tests");
    addCasCommandTests(b, commands, tests);
    addCasRuntimeTests(b, runtime, tests);
    addCasAdminTests(ctx, admin, artifacts, release, tests);
    addCasRunSteps(b, artifacts);
    return .{
        .automation = admin.automation,
        .surface = appSurface(b, .{
            .path = b.path("apps/cas"),
            .build_step_name = "build-cas",
            .build_description = "Build cas binaries",
            .build_deps = &.{
                &artifacts.smoke.install.step,       &artifacts.runner.install.step,
                &artifacts.review.install.step,      &artifacts.inquiry.install.step,
                &artifacts.conformance.install.step, &artifacts.goal.install.step,
                &artifacts.account.install.step,     &artifacts.preflight.install.step,
                &artifacts.budget_perf.install.step, &artifacts.dispatcher.install.step,
                &artifacts.automation.install.step,
            },
            .test_deps = &.{tests},
        }),
    };
}

const CasArtifacts = struct {
    smoke: InstalledExecutable,
    runner: InstalledExecutable,
    review: InstalledExecutable,
    inquiry: InstalledExecutable,
    conformance: InstalledExecutable,
    goal: InstalledExecutable,
    account: InstalledExecutable,
    preflight: InstalledExecutable,
    budget_perf: InstalledExecutable,
    dispatcher: InstalledExecutable,
    automation: InstalledExecutable,

    fn init(
        ctx: BuildContext,
        commands: CasCommandModules,
        admin: CasAdminModules,
        release: cas_build.Options,
    ) CasArtifacts {
        const b = ctx.b;
        const result: CasArtifacts = .{
            .smoke = addInstalledExecutable(b, "cas_smoke_check", commands.smoke),
            .runner = addInstalledExecutable(b, "cas_instance_runner", commands.runner),
            .review = addInstalledExecutable(b, "cas_review_session", commands.review),
            .inquiry = addInstalledExecutable(b, "cas_session_inquiry", commands.inquiry),
            .conformance = addInstalledExecutable(b, "cas_conformance_suite", commands.conformance),
            .goal = addInstalledExecutable(b, "cas_goal", commands.goal),
            .account = addInstalledExecutable(b, "cas_account", commands.account),
            .preflight = addInstalledExecutable(b, "cas_app_server_preflight", admin.preflight),
            .budget_perf = addInstalledExecutable(b, "cas-perf-budget-governor", admin.budget_perf),
            .dispatcher = addInstalledExecutable(b, "cas", admin.dispatcher),
            .automation = addInstalledExecutable(b, "cas_automation", admin.automation),
        };
        result.runner.exe.root_module.linkSystemLibrary("c", .{});
        result.review.exe.root_module.linkSystemLibrary("c", .{});
        result.inquiry.exe.root_module.linkSystemLibrary("c", .{});
        result.preflight.exe.root_module.linkSystemLibrary("c", .{});
        release.configureAutomation(result.automation.exe.root_module, ctx.target.result.os.tag);
        release.configureExecutables(&.{
            result.dispatcher.exe,
            result.account.exe,
            result.preflight.exe,
            result.automation.exe,
            result.smoke.exe,
            result.runner.exe,
            result.review.exe,
            result.inquiry.exe,
            result.conformance.exe,
            result.goal.exe,
            result.budget_perf.exe,
        });
        addBenchStep(
            b,
            result.budget_perf.exe,
            "bench-cas-budget-governor",
            "Run budget_governor performance harness",
        );
        return result;
    }
};

fn addCasCommandTests(
    b: *std.Build,
    commands: CasCommandModules,
    tests: *std.Build.Step,
) void {
    const run_cas_smoke_tests = addTestStep(
        b,
        commands.smoke,
        "test-cas-smoke-check",
        "Run cas_smoke_check tests",
    );
    tests.dependOn(&run_cas_smoke_tests.step);
    const run_cas_runner_tests = addTestStepWithOptions(
        b,
        commands.runner,
        "test-cas-instance-runner",
        "Run cas_instance_runner tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_runner_tests.step);
    const run_cas_review_session_tests = addTestStepWithOptions(
        b,
        commands.review,
        "test-cas-review-session",
        "Run cas_review_session tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_review_session_tests.step);
    const run_cas_session_inquiry_tests = addTestStepWithOptions(
        b,
        commands.inquiry,
        "test-cas-session-inquiry",
        "Run cas_session_inquiry tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_session_inquiry_tests.step);
    const run_cas_conformance_tests = addTestStep(
        b,
        commands.conformance,
        "test-cas-conformance-suite",
        "Run cas_conformance_suite tests",
    );
    tests.dependOn(&run_cas_conformance_tests.step);
    const run_cas_goal_tests = addTestStep(
        b,
        commands.goal,
        "test-cas-goal",
        "Run cas_goal tests",
    );
    tests.dependOn(&run_cas_goal_tests.step);
    const run_cas_account_tests = addTestStep(
        b,
        commands.account,
        "test-cas-account",
        "Run cas_account tests",
    );
    tests.dependOn(&run_cas_account_tests.step);
}

fn addCasRuntimeTests(b: *std.Build, runtime: CasRuntimeModules, tests: *std.Build.Step) void {
    const run_cas_runtime_tests = addTestStepWithOptions(
        b,
        runtime.runtime,
        "test-cas-runtime",
        "Run reusable CAS app-server runtime tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_runtime_tests.step);
    const run_cas_runtime_falsifier_tests = addTestStepWithOptions(
        b,
        runtime.runtime,
        "test-cas-runtime-falsifiers",
        "Run CAS runtime actor falsifier tests",
        .{
            .link_libc = true,
            .filters = &.{"actor falsifier"},
        },
    );
    tests.dependOn(&run_cas_runtime_falsifier_tests.step);
    const run_cas_proxy_client_tests = addTestStep(
        b,
        runtime.proxy,
        "test-cas-proxy-client",
        "Run cas_proxy_client tests",
    );
    tests.dependOn(&run_cas_proxy_client_tests.step);
    const run_cas_transport_tests = addTestStepWithOptions(
        b,
        runtime.transport_tests,
        "test-cas-transport",
        "Run CAS app-server transport kernel tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_transport_tests.step);
    const run_cas_session_inquiry_anchor_tests = addTestStep(
        b,
        runtime.anchor,
        "test-cas-session-inquiry-anchor",
        "Run CAS session inquiry anchor kernel tests",
    );
    tests.dependOn(&run_cas_session_inquiry_anchor_tests.step);
    const run_cas_app_server_contract_tests = addTestStep(
        b,
        runtime.contract,
        "test-cas-app-server-contract",
        "Run CAS app-server structural contract tests",
    );
    tests.dependOn(&run_cas_app_server_contract_tests.step);
    const run_cas_app_server_probes_tests = addTestStep(
        b,
        runtime.probes,
        "test-cas-app-server-probes",
        "Run CAS app-server behavioral probe tests",
    );
    tests.dependOn(&run_cas_app_server_probes_tests.step);
}

fn addCasAdminTests(
    ctx: BuildContext,
    admin: CasAdminModules,
    artifacts: CasArtifacts,
    release: cas_build.Options,
    tests: *std.Build.Step,
) void {
    const b = ctx.b;
    const run_cas_budget_governor_tests = addTestStep(
        b,
        admin.budget,
        "test-cas-budget-governor",
        "Run budget_governor tests",
    );
    run_cas_budget_governor_tests.step.dependOn(&addCasBudgetGovernorSmoke(b, admin.budget).step);
    tests.dependOn(&run_cas_budget_governor_tests.step);
    const run_cas_app_server_preflight_tests = addTestStepWithOptions(
        b,
        admin.preflight,
        "test-cas-app-server-preflight",
        "Run CAS app-server preflight CLI tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_app_server_preflight_tests.step);
    const run_cas_cli_tests = addTestStepWithOptions(
        b,
        admin.dispatcher,
        "test-cas-cli",
        "Run cas dispatcher tests",
        .{ .link_libc = true },
    );
    tests.dependOn(&run_cas_cli_tests.step);
    const run_cas_automation_tests = addTestStepWithOptions(
        b,
        admin.automation,
        "test-cas-automation",
        "Run cas automation tests",
        .{
            .link_libc = true,
            .sqlite = release.usesSystemSqlite(),
        },
    );
    tests.dependOn(&run_cas_automation_tests.step);
    addCasDispatcherTest(ctx, artifacts, tests);
    const oracle = b.addSystemCommand(&.{"sh"});
    oracle.addFileArg(b.path("apps/cas/testdata/automation/cron-0.2.13/verify.sh"));
    oracle.addFileArg(b.path("zig-out/bin/cas"));
    oracle.addArg("automation");
    oracle.step.dependOn(&artifacts.dispatcher.install.step);
    oracle.step.dependOn(&artifacts.automation.install.step);
    oracle.expectStdOutMatch("cron-0.2.13 automation oracle: pass");
    tests.dependOn(&oracle.step);
}

fn addCasBudgetGovernorSmoke(
    b: *std.Build,
    root_module: *std.Build.Module,
) *std.Build.Step.Run {
    const exe = addExecutable(b, "cas-budget-governor-smoke", root_module);
    const smoke = b.addRunArtifact(exe);
    smoke.addArgs(&.{ "--now-sec", "1000" });
    smoke.setStdIn(.{
        .bytes = "{\"rateLimits\":{\"limitId\":\"smoke\",\"primary\":{\"usedPercent\":50," ++
            "\"resetsAt\":2800,\"windowDurationMins\":60}}}",
    });
    smoke.stdio_limit = .limited(4096);
    smoke.expectStdOutEqual(
        "{\"ok\":true,\"bucketSource\":\"single_bucket\",\"bucketKey\":null," ++
            "\"limitId\":\"smoke\"," ++
            "\"limitName\":null,\"planType\":null,\"windowKind\":\"primary\",\"nowSec\":1000," ++
            "\"usedPercent\":50,\"resetsAt\":2800,\"windowDurationMins\":60," ++
            "\"remainingMins\":30," ++
            "\"elapsedPercent\":50,\"deltaPercent\":0,\"tier\":\"on_track\"," ++
            "\"tierReason\":\"delta_lt_10\",\"pacingOk\":true,\"pacingReason\":\"ok\"," ++
            "\"effectiveTier\":\"on_track\",\"primary\":{\"usedPercent\":50,\"resetsAt\":2800," ++
            "\"windowDurationMins\":60,\"remainingMins\":30,\"elapsedPercent\":50," ++
            "\"deltaPercent\":0,\"tier\":\"on_track\",\"tierReason\":\"delta_lt_10\"," ++
            "\"pacingOk\":true,\"pacingReason\":\"ok\",\"effectiveTier\":\"on_track\"}," ++
            "\"secondary\":null}\n",
    );
    smoke.expectStdErrEqual("");
    const help = b.addRunArtifact(exe);
    help.addArg("--help");
    help.stdio_limit = .limited(4096);
    help.expectStdOutMatch("budget_governor [options] < input.json");
    help.expectStdErrEqual("");
    smoke.step.dependOn(&help.step);
    return smoke;
}

fn addCasDispatcherTest(ctx: BuildContext, artifacts: CasArtifacts, tests: *std.Build.Step) void {
    const b = ctx.b;
    // This lane is intentionally absent off native Linux.
    if (b.graph.host.result.os.tag != .linux or ctx.target.result.os.tag != .linux) return;
    const run = b.addSystemCommand(&.{ b.getInstallPath(.bin, "cas"), "review", "--help" });
    run.step.dependOn(&artifacts.dispatcher.install.step);
    run.step.dependOn(&artifacts.review.install.step);
    run.expectStdOutMatch("cas review");
    const step = b.step(
        "test-cas-dispatch-runtime-linux",
        "Verify the Linux cas dispatcher launches its sibling executable",
    );
    step.dependOn(&run.step);
    tests.dependOn(step);
}

fn addCasRunSteps(b: *std.Build, artifacts: CasArtifacts) void {
    addRunStep(b, artifacts.smoke.exe, "run-cas-smoke-check", "Run cas_smoke_check", &.{"--help"});
    addRunStep(
        b,
        artifacts.conformance.exe,
        "run-cas-conformance-suite",
        "Run cas_conformance_suite",
        &.{"--help"},
    );
    addRunStep(
        b,
        artifacts.inquiry.exe,
        "run-cas-session-inquiry",
        "Run cas_session_inquiry",
        &.{"--help"},
    );
    addRunStep(b, artifacts.goal.exe, "run-cas-goal", "Run cas_goal", &.{"--help"});
    addRunStep(b, artifacts.account.exe, "run-cas-account", "Run cas_account", &.{"--help"});
}

fn addSharedTests(ctx: BuildContext, shared: SharedModules, routine: *std.Build.Step) void {
    const b = ctx.b;
    const run_durable_store_tests = addTestStep(
        b,
        shared.durable,
        "test-durable-store",
        "Run durable_store tests",
    );
    routine.dependOn(&run_durable_store_tests.step);
    const run_jsonl_core_tests = addTestStep(
        b,
        shared.jsonl,
        "test-jsonl-core",
        "Run shared JSONL framing tests",
    );
    routine.dependOn(&run_jsonl_core_tests.step);
    const run_definition_core_tests = addTestStep(
        b,
        shared.definitions,
        "test-definition-core",
        "Run passive-definition closure and canonicalization tests",
    );
    routine.dependOn(&run_definition_core_tests.step);
    const run_trace_core_tests = addTestStep(
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
    const run_calendar_tests = addTestStep(
        b,
        shared.calendar,
        "test-core-calendar",
        "Run shared civil calendar compatibility tests",
    );
    core.dependOn(&run_calendar_tests.step);
    core.dependOn(&addTestStep(b, shared.cli, "test-core-cli", "Run shared cli helper tests").step);
    core.dependOn(&addTestStep(
        b,
        shared.delegate,
        "test-core-delegate",
        "Run shared delegate helper tests",
    ).step);
    core.dependOn(&addTestStep(
        b,
        shared.json,
        "test-core-json",
        "Run shared json helper tests",
    ).step);
    core.dependOn(&addTestStep(b, shared.io, "test-core-io", "Run shared io helper tests").step);
    core.dependOn(&addTestStep(
        b,
        shared.path,
        "test-core-path",
        "Run shared path helper tests",
    ).step);
    core.dependOn(&addTestStep(
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
    const run_jsonl_large_tests = addTestStep(
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
    const run_canonical_json_corpus_tests = addTestStep(
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
    const perf_hub = addInstalledExecutable(b, "perf_hub", perf_hub_root);
    const run_perf_hub_tests = addTestStep(
        b,
        perf_hub_root,
        "test-perf-hub",
        "Run perf_hub tests",
    );
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
    const durable_store_perf = addExecutable(b, "durable-store-perf", durable_store_perf_root);
    addBenchStep(
        b,
        durable_store_perf,
        "perf-durable-store-local",
        "Measure durable_store scan and append resource use",
    );
    const run_durable_store_perf_tests = addTestStep(
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
    const tests = addTestStepWithOptions(
        ctx.b,
        driver,
        "test-optimization-driver",
        "Run optimization workload and oracle tests",
        .{ .filters = &.{"optimization"} },
    );
    routine.dependOn(&tests.step);
}

fn addPerformanceRunSteps(b: *std.Build, perf_hub: *std.Build.Step.Compile) void {
    addRunStepPrefixed(b, perf_hub, "perf-list-local", "List local perf cases", &.{"list"});
    addRunStepPrefixed(
        b,
        perf_hub,
        "perf-manifest-local",
        "Emit native perf manifest",
        &.{"manifest"},
    );
    addRunStepPrefixed(b, perf_hub, "perf-audit-local", "Audit native perf coverage", &.{"audit"});
    addRunStepPrefixed(
        b,
        perf_hub,
        "perf-doctor-local",
        "Validate local perf coverage and setup",
        &.{"doctor"},
    );
    addRunStepPrefixed(
        b,
        perf_hub,
        "perf-compare-local",
        "Run a sealed paired perf comparison",
        &.{"compare"},
    );
    addRunStepPrefixed(
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
            &.{ "zig", "build", "lint", "-Doptimize=ReleaseFast", "-Denable_zlinter=true" },
        );
        if (b.args) |args| {
            lint_cmd.addArg("--");
            lint_cmd.addArgs(args);
        }
        lint_step.dependOn(&lint_cmd.step);
    }
}

fn addExecutable(
    b: *std.Build,
    name: []const u8,
    root_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });
    return exe;
}

const InstalledExecutable = struct {
    exe: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
};

fn addInstalledExecutable(
    b: *std.Build,
    name: []const u8,
    root: *std.Build.Module,
) InstalledExecutable {
    const exe = addExecutable(b, name, root);
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    return .{ .exe = exe, .install = install };
}

fn addRunStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
    default_args: []const []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    } else if (default_args.len > 0) {
        run_cmd.addArgs(default_args);
    }

    const run_step = b.step(step_name, description);
    run_step.dependOn(&run_cmd.step);
}

fn addRunStepPrefixed(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
    fixed_args: []const []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addArgs(fixed_args);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step(step_name, description);
    run_step.dependOn(&run_cmd.step);
}

fn addBenchStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const step = b.step(step_name, description);
    step.dependOn(&run_cmd.step);
}

const AppSurface = struct {
    path: std.Build.LazyPath,
    build_step_name: []const u8,
    build_description: []const u8,
    build_deps: []const *std.Build.Step,
    test_deps: []const *std.Build.Step,
};

fn appSurface(b: *std.Build, value: AppSurface) AppSurface {
    var result = value;
    // Helpers return these slices; the build arena must own their backing arrays.
    result.build_deps = b.allocator.dupe(*std.Build.Step, value.build_deps) catch @panic("OOM");
    result.test_deps = b.allocator.dupe(*std.Build.Step, value.test_deps) catch @panic("OOM");
    return result;
}

fn addGroupedStep(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    deps: []const *std.Build.Step,
) *std.Build.Step {
    const step = b.step(step_name, description);
    for (deps) |dep| step.dependOn(dep);
    return step;
}

fn addTestStep(
    b: *std.Build,
    root_module: *std.Build.Module,
    step_name: []const u8,
    description: []const u8,
) *std.Build.Step.Run {
    return addTestStepWithOptions(b, root_module, step_name, description, .{});
}

const TestStepOptions = struct {
    link_libc: bool = false,
    sqlite: bool = false,
    cwd: ?std.Build.LazyPath = null,
    filters: []const []const u8 = &.{},
};

fn addTestStepWithOptions(
    b: *std.Build,
    root_module: *std.Build.Module,
    step_name: []const u8,
    description: []const u8,
    options: TestStepOptions,
) *std.Build.Step.Run {
    const tests = b.addTest(.{ .root_module = root_module, .filters = options.filters });
    if (options.link_libc) {
        tests.root_module.linkSystemLibrary("c", .{});
        if (options.sqlite) tests.root_module.linkSystemLibrary("sqlite3", .{});
    }
    const run_tests = b.addRunArtifact(tests);
    if (options.cwd) |cwd| run_tests.setCwd(cwd);
    if (b.args) |args| run_tests.addArgs(args);
    const step = b.step(step_name, description);
    step.dependOn(&run_tests.step);
    return run_tests;
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
            "skills-zig forbids external installs; ship CLIs via the Homebrew tap release flow " ++
                "only. expected install_prefix={s} exe_dir={s}; got install_prefix={s} " ++
                "exe_dir={s} dest_dir={?s}",
            .{ expected_prefix, expected_exe_dir, b.install_prefix, b.exe_dir, b.dest_dir },
        );
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
        .optimize = .ReleaseFast,
    });
    for (app_surfaces) |surface| {
        lint_builder.addPaths(.{ .include = &.{surface.path} });
    }
    lint_builder.addPaths(.{
        .include = &.{
            b.path("libs/core"),
            b.path("libs/jsonl_core"),
            b.path("libs/trace_core"),
            b.path("build.zig"),
            b.path("tools"),
        },
        // `zlinter` routes `@cImport` files through `zls` translate-c, which
        // currently emits spurious stderr for this one seq helper on 0.16.
        .exclude = &.{
            b.path("apps/seq/src/time_utils.zig"),
        },
    });
    lint_builder.addRule(.{ .builtin = .no_unused }, .{});
    return lint_builder.build();
}
