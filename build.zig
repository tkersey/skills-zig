const std = @import("std");
const cas_build = @import("apps/cas/build_support.zig");
pub fn build(b: *std.Build) void {
    enforceRepoLocalInstallOnly(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const cas_release = cas_build.Options.init(b);

    const core_json = b.createModule(.{
        .root_source_file = b.path("libs/core/src/json_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_io = b.createModule(.{
        .root_source_file = b.path("libs/core/src/io_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_path = b.createModule(.{
        .root_source_file = b.path("libs/core/src/path_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_cli = b.createModule(.{
        .root_source_file = b.path("libs/core/src/cli_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_delegate = b.createModule(.{
        .root_source_file = b.path("libs/core/src/delegate_helpers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
        },
    });
    const core_perf = b.createModule(.{
        .root_source_file = b.path("libs/core/src/perf_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_perf_contract = b.createModule(.{
        .root_source_file = b.path("tools/perf_contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const jsonl_core = b.createModule(.{
        .root_source_file = b.path("libs/jsonl_core/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const durable_store = b.createModule(.{
        .root_source_file = b.path("libs/durable_store/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jsonl_core", .module = jsonl_core },
        },
    });
    const definition_compat = b.createModule(.{
        .root_source_file = b.path("libs/definition_compat/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const definition_core = b.createModule(.{
        .root_source_file = b.path("libs/definition_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "definition_compat", .module = definition_compat },
        },
    });
    const trace_core = b.createModule(.{
        .root_source_file = b.path("libs/trace_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jsonl_core", .module = jsonl_core },
        },
    });
    const jsonl_stream_release_fast = b.createModule(.{
        .root_source_file = b.path("libs/jsonl_core/src/lib.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const durable_store_release_fast = b.createModule(.{
        .root_source_file = b.path("libs/durable_store/src/lib.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "jsonl_core", .module = jsonl_stream_release_fast },
        },
    });
    const canonical_json_release_fast = b.createModule(.{
        .root_source_file = b.path("libs/definition_core/src/canonical_json.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const jsonl_large_tests_root = b.createModule(.{
        .root_source_file = b.path("libs/jsonl_core/tests/jsonl_stream_large.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "jsonl_stream", .module = jsonl_stream_release_fast },
        },
    });
    const canonical_json_corpus_tests_root = b.createModule(.{
        .root_source_file = b.path("libs/definition_core/tests/canonical_json_corpus.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "canonical_json", .module = canonical_json_release_fast },
        },
    });
    const seq_v1_core = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/v1/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "definition_core", .module = definition_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "jsonl_core", .module = jsonl_core },
            .{ .name = "trace_core", .module = trace_core },
            .{
                .name = "seq_time",
                .module = b.createModule(.{
                    .root_source_file = b.path("apps/seq/src/time_utils.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            },
        },
    });
    const ledger_v1_core = b.createModule(.{
        .root_source_file = b.path("apps/ledger/src/v1/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "definition_core", .module = definition_core },
            .{ .name = "durable_store", .module = durable_store },
        },
    });
    const seq_meta = addVersionModule(b, @embedFile("apps/seq/VERSION"));
    const seq_root = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/v1/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
        .imports = &.{
            .{ .name = "app_meta", .module = seq_meta },
            .{ .name = "definition_core", .module = definition_core },
            .{ .name = "seq_v1_core", .module = seq_v1_core },
        },
    });
    const lift_meta = addVersionModule(b, @embedFile("apps/lift/VERSION"));
    const cas_meta = addVersionModule(b, @embedFile("apps/cas/VERSION"));
    const ledger_meta = addVersionModule(b, @embedFile("apps/ledger/VERSION"));
    const memory_note_meta = addVersionModule(b, @embedFile("apps/memory-note/VERSION"));
    const img_meta = addVersionModule(b, @embedFile("apps/img/VERSION"));
    const ledger_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/src/v1/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
        .imports = &.{
            .{ .name = "app_meta", .module = ledger_meta },
            .{ .name = "definition_core", .module = definition_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "ledger_v1_core", .module = ledger_v1_core },
        },
    });
    const img_atlas = b.createModule(.{
        .root_source_file = b.path("apps/img/assets/atlas.zig"),
        .target = target,
        .optimize = optimize,
    });

    const img_root = b.createModule(.{
        .root_source_file = b.path("apps/img/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app_meta", .module = img_meta },
            .{ .name = "img_atlas", .module = img_atlas },
        },
    });
    const img_tests_root = b.createModule(.{
        .root_source_file = b.path("apps/img/src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "img_atlas", .module = img_atlas },
        },
    });

    const lift_bench_root = b.createModule(.{
        .root_source_file = b.path("apps/lift/scripts/bench_stats.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = lift_meta },
        },
    });
    const lift_report_root = b.createModule(.{
        .root_source_file = b.path("apps/lift/scripts/perf_report.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = lift_meta },
        },
    });
    const lift_bench_perf_root = b.createModule(.{
        .root_source_file = b.path("apps/lift/scripts/perf_bench_stats.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_perf", .module = core_perf },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = lift_meta },
        },
    });
    const cas_hook_policy_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_hook_policy.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
        },
    });
    const cas_runtime_root = b.createModule(.{
        .root_source_file = b.path("libs/cas_runtime/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "cas_hook_policy", .module = cas_hook_policy_root },
        },
    });
    const core_json_release_safe = b.createModule(.{
        .root_source_file = b.path("libs/core/src/json_helpers.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const cas_hook_policy_release_safe = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_hook_policy.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "core_json", .module = core_json_release_safe },
        },
    });
    const cas_runtime_release_safe = b.createModule(.{
        .root_source_file = b.path("libs/cas_runtime/src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "core_json", .module = core_json_release_safe },
            .{ .name = "cas_hook_policy", .module = cas_hook_policy_release_safe },
        },
    });
    const synoptic_version = std.mem.trim(
        u8,
        @embedFile("apps/synoptic/VERSION"),
        " \t\r\n",
    );
    const synoptic_meta = addVersionModule(b, synoptic_version);
    const synoptic_root = b.createModule(.{
        .root_source_file = b.path("apps/synoptic/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast,
        .imports = &.{
            .{ .name = "app_meta", .module = synoptic_meta },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
        },
    });
    const synoptic_tests_root = b.createModule(.{
        .root_source_file = b.path("apps/synoptic/src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app_meta", .module = synoptic_meta },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
        },
    });
    const synoptic_release_safe_root = b.createModule(.{
        .root_source_file = b.path("apps/synoptic/src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "app_meta", .module = synoptic_meta },
            .{ .name = "cas_runtime", .module = cas_runtime_release_safe },
        },
    });
    const cas_proxy_client_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_proxy_client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
        },
    });
    const cas_smoke_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_smoke_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
        },
    });
    const cas_runner_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_instance_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
        },
    });
    const cas_review_session_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_review_session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "core_path", .module = core_path },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
        },
    });
    const cas_session_inquiry_anchor_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_session_inquiry_anchor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cas_session_inquiry_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_session_inquiry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "core_path", .module = core_path },
            .{ .name = "definition_core", .module = definition_core },
            .{ .name = "trace_core", .module = trace_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
            .{
                .name = "cas_session_inquiry_anchor",
                .module = cas_session_inquiry_anchor_root,
            },
        },
    });
    const cas_conformance_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_conformance_suite.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
        },
    });
    const cas_goal_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_goal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
        },
    });
    const cas_account_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_account.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_runtime", .module = cas_runtime_root },
        },
    });
    const cas_transport_tests_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_transport_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
        },
    });
    const cas_app_server_contract_data = b.addOptions();
    cas_app_server_contract_data.addOption(
        []const u8,
        "json",
        @embedFile("apps/cas/contracts/codex-app-server-capabilities-v1.json"),
    );
    const cas_app_server_contract_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_app_server_contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "cas_app_server_contract_data",
                .module = cas_app_server_contract_data.createModule(),
            },
            .{ .name = "definition_core", .module = definition_core },
            .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
        },
    });
    const cas_app_server_probes_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_app_server_probes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cas_app_server_contract", .module = cas_app_server_contract_root },
            .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
            .{
                .name = "cas_session_inquiry_anchor",
                .module = cas_session_inquiry_anchor_root,
            },
        },
    });
    const cas_app_server_preflight_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_app_server_preflight.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "cas_app_server_contract", .module = cas_app_server_contract_root },
            .{ .name = "cas_app_server_probes", .module = cas_app_server_probes_root },
            .{ .name = "cas_proxy_client", .module = cas_proxy_client_root },
        },
    });
    const cas_budget_governor_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/budget_governor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
        },
    });
    const cas_budget_perf_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/perf_budget_governor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_io", .module = core_io },
            .{ .name = "core_perf", .module = core_perf },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
        },
    });
    const cas_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
        },
    });
    const cas_automation_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_automation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
        },
    });
    const memory_note_root = b.createModule(.{
        .root_source_file = b.path("apps/memory-note/scripts/memory_note.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = memory_note_meta },
        },
    });
    const perf_hub_root = b.createModule(.{
        .root_source_file = b.path("tools/perf_hub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "core_perf", .module = core_perf },
            .{ .name = "definition_core", .module = definition_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "perf_contract", .module = core_perf_contract },
            .{ .name = "cas_automation_cli", .module = cas_automation_root },
            .{ .name = "seq_v1_core", .module = seq_v1_core },
        },
    });
    const durable_store_perf_root = b.createModule(.{
        .root_source_file = b.path("tools/durable_store_perf.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "durable_store", .module = durable_store_release_fast },
        },
    });

    const seq = addExecutable(b, "seq", seq_root);
    const bench_stats = addExecutable(b, "bench_stats", lift_bench_root);
    const perf_report = addExecutable(b, "perf_report", lift_report_root);
    const lift_bench_perf = addExecutable(b, "lift-perf-bench-stats", lift_bench_perf_root);
    const cas_smoke_check = addExecutable(b, "cas_smoke_check", cas_smoke_root);
    const cas_instance_runner = addExecutable(b, "cas_instance_runner", cas_runner_root);
    cas_instance_runner.root_module.linkSystemLibrary("c", .{});
    const cas_review_session = addExecutable(b, "cas_review_session", cas_review_session_root);
    cas_review_session.root_module.linkSystemLibrary("c", .{});
    const cas_session_inquiry = addExecutable(b, "cas_session_inquiry", cas_session_inquiry_root);
    cas_session_inquiry.root_module.linkSystemLibrary("c", .{});
    const cas_conformance_suite = addExecutable(b, "cas_conformance_suite", cas_conformance_root);
    const cas_goal = addExecutable(b, "cas_goal", cas_goal_root);
    const cas_account = addExecutable(b, "cas_account", cas_account_root);
    const cas_app_server_preflight = addExecutable(
        b,
        "cas_app_server_preflight",
        cas_app_server_preflight_root,
    );
    cas_app_server_preflight.root_module.linkSystemLibrary("c", .{});
    const cas_code_mode_host_fixture = addExecutable(
        b,
        "cas_code_mode_host_fixture",
        cas_transport_tests_root,
    );
    cas_code_mode_host_fixture.root_module.linkSystemLibrary("c", .{});
    const cas_budget_perf = addExecutable(b, "cas-perf-budget-governor", cas_budget_perf_root);
    const cas = addExecutable(b, "cas", cas_root);
    const cas_automation = addExecutable(b, "cas_automation", cas_automation_root);
    const synoptic = addExecutable(b, "synoptic", synoptic_root);
    synoptic.root_module.linkSystemLibrary("c", .{});
    const synoptic_release_safe = addExecutable(
        b,
        "synoptic-release-safe",
        synoptic_release_safe_root,
    );
    synoptic_release_safe.root_module.linkSystemLibrary("c", .{});
    cas_release.configureAutomation(cas_automation.root_module, target.result.os.tag);
    cas_release.configureExecutables(&.{
        cas,
        cas_account,
        cas_app_server_preflight,
        cas_automation,
        cas_smoke_check,
        cas_instance_runner,
        cas_review_session,
        cas_session_inquiry,
        cas_conformance_suite,
        cas_goal,
        cas_budget_perf,
    });
    const ledger = addExecutable(b, "ledger", ledger_root);
    const memory_note = addExecutable(b, "memory-note", memory_note_root);
    const img = addExecutable(b, "img", img_root);
    const perf_hub = addExecutable(b, "perf_hub", perf_hub_root);
    const durable_store_perf = addExecutable(b, "durable-store-perf", durable_store_perf_root);

    const seq_install = addInstallStep(b, seq);
    const bench_stats_install = addInstallStep(b, bench_stats);
    const perf_report_install = addInstallStep(b, perf_report);
    const lift_bench_perf_install = addInstallStep(b, lift_bench_perf);
    const cas_smoke_check_install = addInstallStep(b, cas_smoke_check);
    const cas_instance_runner_install = addInstallStep(b, cas_instance_runner);
    const cas_review_session_install = addInstallStep(b, cas_review_session);
    const cas_session_inquiry_install = addInstallStep(b, cas_session_inquiry);
    const cas_conformance_suite_install = addInstallStep(b, cas_conformance_suite);
    const cas_goal_install = addInstallStep(b, cas_goal);
    const cas_account_install = addInstallStep(b, cas_account);
    const cas_app_server_preflight_install = addInstallStep(b, cas_app_server_preflight);
    const cas_code_mode_host_fixture_install = addInstallStep(
        b,
        cas_code_mode_host_fixture,
    );
    const build_cas_code_mode_host_fixture = b.step(
        "build-cas-code-mode-host-fixture",
        "Build the deterministic CAS Code Mode host fixture",
    );
    build_cas_code_mode_host_fixture.dependOn(&cas_code_mode_host_fixture_install.step);
    const cas_budget_perf_install = addInstallStep(b, cas_budget_perf);
    const cas_install = addInstallStep(b, cas);
    const cas_automation_install = addInstallStep(b, cas_automation);
    const synoptic_install = addInstallStep(b, synoptic);
    const synoptic_release_safe_install = addInstallStep(b, synoptic_release_safe);
    const ledger_install = addInstallStep(b, ledger);
    const memory_note_install = addInstallStep(b, memory_note);
    const img_install = addInstallStep(b, img);
    const perf_hub_install = addInstallStep(b, perf_hub);

    const install_all = b.getInstallStep();
    install_all.dependOn(&seq_install.step);
    install_all.dependOn(&bench_stats_install.step);
    install_all.dependOn(&perf_report_install.step);
    install_all.dependOn(&lift_bench_perf_install.step);
    install_all.dependOn(&cas_smoke_check_install.step);
    install_all.dependOn(&cas_instance_runner_install.step);
    install_all.dependOn(&cas_review_session_install.step);
    install_all.dependOn(&cas_session_inquiry_install.step);
    install_all.dependOn(&cas_conformance_suite_install.step);
    install_all.dependOn(&cas_goal_install.step);
    install_all.dependOn(&cas_account_install.step);
    install_all.dependOn(&cas_app_server_preflight_install.step);
    install_all.dependOn(&cas_budget_perf_install.step);
    install_all.dependOn(&cas_install.step);
    install_all.dependOn(&cas_automation_install.step);
    if (installsSynopticByDefault(target.result.os.tag)) {
        install_all.dependOn(&synoptic_install.step);
    }
    install_all.dependOn(&ledger_install.step);
    install_all.dependOn(&memory_note_install.step);
    install_all.dependOn(&img_install.step);
    install_all.dependOn(&perf_hub_install.step);

    const run_seq_tests = addTestStep(
        b,
        seq_root,
        "test-seq",
        "Run Seq 1.0 command and observation tests",
    );

    addBenchStep(
        b,
        lift_bench_perf,
        "bench-lift-bench-stats",
        "Run bench_stats performance harness",
    );
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

    addBenchStep(
        b,
        cas_budget_perf,
        "bench-cas-budget-governor",
        "Run budget_governor performance harness",
    );
    addBenchStep(
        b,
        durable_store_perf,
        "perf-durable-store-local",
        "Measure durable_store scan and append resource use",
    );

    const run_cas_budget_governor_tests = addTestStep(
        b,
        cas_budget_governor_root,
        "test-cas-budget-governor",
        "Run budget_governor tests",
    );
    const run_cas_smoke_tests = addTestStep(
        b,
        cas_smoke_root,
        "test-cas-smoke-check",
        "Run cas_smoke_check tests",
    );
    const run_cas_runner_tests = addTestStepWithOptions(
        b,
        cas_runner_root,
        "test-cas-instance-runner",
        "Run cas_instance_runner tests",
        .{ .link_libc = true },
    );
    const run_cas_review_session_tests = addTestStepWithOptions(
        b,
        cas_review_session_root,
        "test-cas-review-session",
        "Run cas_review_session tests",
        .{ .link_libc = true },
    );
    const run_cas_session_inquiry_tests = addTestStepWithOptions(
        b,
        cas_session_inquiry_root,
        "test-cas-session-inquiry",
        "Run cas_session_inquiry tests",
        .{ .link_libc = true },
    );
    const run_cas_session_inquiry_anchor_tests = addTestStep(
        b,
        cas_session_inquiry_anchor_root,
        "test-cas-session-inquiry-anchor",
        "Run CAS session inquiry anchor kernel tests",
    );
    const run_cas_conformance_tests = addTestStep(
        b,
        cas_conformance_root,
        "test-cas-conformance-suite",
        "Run cas_conformance_suite tests",
    );
    const run_cas_goal_tests = addTestStep(
        b,
        cas_goal_root,
        "test-cas-goal",
        "Run cas_goal tests",
    );
    const run_cas_account_tests = addTestStep(
        b,
        cas_account_root,
        "test-cas-account",
        "Run cas_account tests",
    );
    const run_cas_proxy_client_tests = addTestStep(
        b,
        cas_proxy_client_root,
        "test-cas-proxy-client",
        "Run cas_proxy_client tests",
    );
    const run_cas_runtime_tests = addTestStepWithOptions(
        b,
        cas_runtime_root,
        "test-cas-runtime",
        "Run reusable CAS app-server runtime tests",
        .{ .link_libc = true },
    );
    const run_cas_runtime_falsifier_tests = addTestStepWithOptions(
        b,
        cas_runtime_root,
        "test-cas-runtime-falsifiers",
        "Run CAS runtime actor falsifier tests",
        .{
            .link_libc = true,
            .filters = &.{"actor falsifier"},
        },
    );
    const run_cas_transport_tests = addTestStepWithOptions(
        b,
        cas_transport_tests_root,
        "test-cas-transport",
        "Run CAS app-server transport kernel tests",
        .{ .link_libc = true },
    );
    const run_cas_app_server_contract_tests = addTestStep(
        b,
        cas_app_server_contract_root,
        "test-cas-app-server-contract",
        "Run CAS app-server structural contract tests",
    );
    const run_cas_app_server_probes_tests = addTestStep(
        b,
        cas_app_server_probes_root,
        "test-cas-app-server-probes",
        "Run CAS app-server behavioral probe tests",
    );
    const run_cas_app_server_preflight_tests = addTestStepWithOptions(
        b,
        cas_app_server_preflight_root,
        "test-cas-app-server-preflight",
        "Run CAS app-server preflight CLI tests",
        .{ .link_libc = true },
    );
    const run_cas_cli_tests = addTestStepWithOptions(
        b,
        cas_root,
        "test-cas-cli",
        "Run cas dispatcher tests",
        .{ .link_libc = true },
    );
    const run_cas_dispatch_runtime_linux: ?*std.Build.Step = if (b.graph.host.result.os.tag == .linux and target.result.os.tag == .linux) cas_dispatch_runtime_linux: {
        const cas_dispatch_run = b.addSystemCommand(
            &.{ b.getInstallPath(.bin, "cas"), "review", "--help" },
        );
        cas_dispatch_run.step.dependOn(&cas_install.step);
        cas_dispatch_run.step.dependOn(&cas_review_session_install.step);
        cas_dispatch_run.expectStdOutMatch("cas review");

        const cas_dispatch_step = b.step("test-cas-dispatch-runtime-linux", "Verify the Linux cas dispatcher launches its sibling executable");
        cas_dispatch_step.dependOn(&cas_dispatch_run.step);
        break :cas_dispatch_runtime_linux cas_dispatch_step;
    } else cas_dispatch_runtime_linux_unavailable: {
        break :cas_dispatch_runtime_linux_unavailable null;
    }; // cas_dispatch_runtime_linux is intentionally absent off native Linux.
    const test_cas = b.step("test-cas", "Run all cas tests");
    test_cas.dependOn(&run_cas_budget_governor_tests.step);
    test_cas.dependOn(&run_cas_smoke_tests.step);
    test_cas.dependOn(&run_cas_runner_tests.step);
    test_cas.dependOn(&run_cas_review_session_tests.step);
    test_cas.dependOn(&run_cas_session_inquiry_tests.step);
    test_cas.dependOn(&run_cas_session_inquiry_anchor_tests.step);
    test_cas.dependOn(&run_cas_conformance_tests.step);
    test_cas.dependOn(&run_cas_goal_tests.step);
    test_cas.dependOn(&run_cas_account_tests.step);
    test_cas.dependOn(&run_cas_runtime_tests.step);
    test_cas.dependOn(&run_cas_runtime_falsifier_tests.step);
    test_cas.dependOn(&run_cas_proxy_client_tests.step);
    test_cas.dependOn(&run_cas_transport_tests.step);
    test_cas.dependOn(&run_cas_app_server_contract_tests.step);
    test_cas.dependOn(&run_cas_app_server_probes_tests.step);
    test_cas.dependOn(&run_cas_app_server_preflight_tests.step);
    test_cas.dependOn(&run_cas_cli_tests.step);
    if (run_cas_dispatch_runtime_linux) |run| test_cas.dependOn(run);

    const run_cas_automation_tests = addTestStepWithOptions(
        b,
        cas_automation_root,
        "test-cas-automation",
        "Run cas automation tests",
        .{
            .link_libc = true,
            .sqlite = cas_release.usesSystemSqlite(),
        },
    );
    test_cas.dependOn(&run_cas_automation_tests.step);

    const run_synoptic_tests = addTestStepWithOptions(
        b,
        synoptic_tests_root,
        "test-synoptic-unit",
        "Run Synoptic unit and vertical state tests",
        .{ .link_libc = true },
    );
    run_synoptic_tests.step.dependOn(&synoptic_install.step);
    const run_synoptic_falsifiers = addTestStepWithOptions(
        b,
        synoptic_tests_root,
        "test-synoptic-falsifiers-only",
        "Run Synoptic security and authority falsifiers",
        .{ .link_libc = true, .filters = &.{"falsifier"} },
    );
    const run_synoptic_e2e = addTestStepWithOptions(
        b,
        synoptic_tests_root,
        "test-synoptic-e2e-only",
        "Run the bounded Synoptic lifecycle fixture",
        .{ .link_libc = true, .filters = &.{"e2e"} },
    );
    run_synoptic_e2e.step.dependOn(&synoptic_install.step);
    const run_synoptic_action_broker = addTestStepWithOptions(
        b,
        synoptic_tests_root,
        "test-synoptic-action-broker-only",
        "Run Synoptic typed and transparent GitHub action broker tests",
        .{ .link_libc = true, .filters = &.{"action broker"} },
    );
    const run_synoptic_session_context = addTestStepWithOptions(
        b,
        synoptic_tests_root,
        "test-synoptic-session-context-only",
        "Run installed-schema and authoritative session-context tests",
        .{ .link_libc = true, .filters = &.{"session context"} },
    );
    run_synoptic_session_context.step.dependOn(&synoptic_install.step);
    const run_synoptic_worktree_integrity = addTestStepWithOptions(
        b,
        synoptic_tests_root,
        "test-synoptic-worktree-integrity-only",
        "Run Synoptic custody cleanup and command-quiescence tests",
        .{ .link_libc = true, .filters = &.{"worktree integrity"} },
    );
    run_synoptic_worktree_integrity.step.dependOn(&synoptic_install.step);
    const run_synoptic_exclusions_config = addTestStepWithOptions(
        b,
        synoptic_tests_root,
        "test-synoptic-exclusions-config-only",
        "Run Synoptic config, exclusion synchronization, and start-mode tests",
        .{ .link_libc = true, .filters = &.{"exclusions config"} },
    );
    run_synoptic_exclusions_config.step.dependOn(&synoptic_install.step);
    const run_synoptic_command_approvals = addTestStepWithOptions(
        b,
        synoptic_tests_root,
        "test-synoptic-command-approvals-only",
        "Run Synoptic command and permission approval authority fixtures",
        .{ .link_libc = true, .filters = &.{"command approvals"} },
    );
    run_synoptic_command_approvals.step.dependOn(&synoptic_install.step);
    const run_synoptic_ui_domain = addTestStepWithOptions(
        b,
        synoptic_tests_root,
        "test-synoptic-ui-domain-only",
        "Run Synoptic owned PR, queue, tab, and canonical diff payload fixtures",
        .{ .link_libc = true, .filters = &.{"ui domain"} },
    );
    run_synoptic_ui_domain.step.dependOn(&synoptic_install.step);
    const test_synoptic = b.step(
        "test-synoptic",
        "Run the complete Synoptic test root once",
    );
    test_synoptic.dependOn(&run_synoptic_tests.step);
    const synoptic_version_smoke = b.addRunArtifact(synoptic);
    synoptic_version_smoke.addArg("--version");
    synoptic_version_smoke.expectStdOutEqual(b.fmt(
        "synoptic {s}\n",
        .{synoptic_version},
    ));
    synoptic_version_smoke.step.dependOn(&synoptic_install.step);
    test_synoptic.dependOn(&synoptic_version_smoke.step);
    const synoptic_usage =
        \\Usage:
        \\  synoptic launch [--pr SELECTOR] --cwd PATH --skill-root PATH [--json]
        \\  synoptic capabilities [--format json]
        \\  synoptic version
        \\  synoptic status [--json]
        \\  synoptic stop [--json]
        \\
    ;
    const synoptic_help_smoke = b.addRunArtifact(synoptic);
    synoptic_help_smoke.addArg("--help");
    synoptic_help_smoke.expectStdOutEqual(synoptic_usage);
    synoptic_help_smoke.expectStdErrEqual("");
    synoptic_help_smoke.step.dependOn(&synoptic_install.step);
    test_synoptic.dependOn(&synoptic_help_smoke.step);
    const synoptic_no_args_smoke = b.addRunArtifact(synoptic);
    synoptic_no_args_smoke.expectStdErrEqual(synoptic_usage);
    synoptic_no_args_smoke.expectExitCode(2);
    synoptic_no_args_smoke.step.dependOn(&synoptic_install.step);
    test_synoptic.dependOn(&synoptic_no_args_smoke.step);
    const synoptic_invalid_command_smoke = b.addRunArtifact(synoptic);
    synoptic_invalid_command_smoke.addArg("not-a-command");
    synoptic_invalid_command_smoke.expectStdErrEqual(synoptic_usage);
    synoptic_invalid_command_smoke.expectExitCode(2);
    synoptic_invalid_command_smoke.step.dependOn(&synoptic_install.step);
    test_synoptic.dependOn(&synoptic_invalid_command_smoke.step);
    const test_synoptic_falsifiers = b.step(
        "test-synoptic-falsifiers",
        "Run Synoptic falsifiers",
    );
    test_synoptic_falsifiers.dependOn(&run_synoptic_falsifiers.step);
    const test_synoptic_e2e = b.step(
        "test-synoptic-e2e",
        "Run the real masked-WebSocket fake-Codex/fake-GitHub product fixture",
    );
    test_synoptic_e2e.dependOn(&run_synoptic_e2e.step);
    const test_synoptic_action_broker = b.step(
        "test-synoptic-action-broker",
        "Run typed action and bounded transparent GraphQL fixtures",
    );
    test_synoptic_action_broker.dependOn(&run_synoptic_action_broker.step);
    const test_synoptic_session_context = b.step(
        "test-synoptic-session-context",
        "Run installed-schema and authoritative session-context fixtures",
    );
    test_synoptic_session_context.dependOn(&run_synoptic_session_context.step);
    const test_synoptic_worktree_integrity = b.step(
        "test-synoptic-worktree-integrity",
        "Run safe-boundary and custody-integrity fixtures",
    );
    test_synoptic_worktree_integrity.dependOn(&run_synoptic_worktree_integrity.step);
    const test_synoptic_exclusions_config = b.step(
        "test-synoptic-exclusions-config",
        "Run config precedence, exclusion sync, and session start-mode fixtures",
    );
    test_synoptic_exclusions_config.dependOn(&run_synoptic_exclusions_config.step);
    const test_synoptic_command_approvals = b.step(
        "test-synoptic-command-approvals",
        "Run server-request approval routing and cleanup fixtures",
    );
    test_synoptic_command_approvals.dependOn(&run_synoptic_command_approvals.step);
    const test_synoptic_ui_domain = b.step(
        "test-synoptic-ui-domain",
        "Run owned browser-domain payload and diff continuity fixtures",
    );
    test_synoptic_ui_domain.dependOn(&run_synoptic_ui_domain.step);
    const release_synoptic_safe = b.step(
        "release-synoptic-safe",
        "Build Synoptic with ReleaseSafe optimization",
    );
    release_synoptic_safe.dependOn(&synoptic_release_safe_install.step);

    const cas_automation_oracle = b.addSystemCommand(&.{"sh"});
    cas_automation_oracle.addFileArg(b.path("apps/cas/testdata/automation/cron-0.2.13/verify.sh"));
    cas_automation_oracle.addFileArg(b.path("zig-out/bin/cas"));
    cas_automation_oracle.addArg("automation");
    cas_automation_oracle.step.dependOn(&cas_install.step);
    cas_automation_oracle.step.dependOn(&cas_automation_install.step);
    cas_automation_oracle.expectStdOutMatch("cron-0.2.13 automation oracle: pass");
    test_cas.dependOn(&cas_automation_oracle.step);

    const run_ledger_tests = addTestStep(
        b,
        ledger_root,
        "test-ledger-cli",
        "Run Ledger 1.0 command and artifact tests",
    );
    const test_ledger = b.step("test-ledger", "Run ledger tests");
    test_ledger.dependOn(&run_ledger_tests.step);
    const run_memory_note_tests = addTestStep(
        b,
        memory_note_root,
        "test-memory-note",
        "Run memory-note tests",
    );
    const run_img_tests = addTestStep(
        b,
        img_tests_root,
        "test-img",
        "Run img tests",
    );
    const run_perf_hub_tests = addTestStep(
        b,
        perf_hub_root,
        "test-perf-hub",
        "Run perf_hub tests",
    );
    const run_durable_store_tests = addTestStep(
        b,
        durable_store,
        "test-durable-store",
        "Run durable_store tests",
    );
    const run_durable_store_perf_tests = addTestStep(
        b,
        durable_store_perf_root,
        "test-durable-store-perf",
        "Run durable_store performance-contract tests",
    );
    const run_jsonl_core_tests = addTestStep(
        b,
        jsonl_core,
        "test-jsonl-core",
        "Run shared JSONL framing tests",
    );
    const run_definition_core_tests = addTestStep(
        b,
        definition_core,
        "test-definition-core",
        "Run passive-definition closure and canonicalization tests",
    );
    const definition_core_guard_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/guards/definition-core-domain.sh",
    });
    const run_definition_core_guard = b.step(
        "test-definition-core-guard",
        "Reject domain vocabulary in the neutral definition library",
    );
    run_definition_core_guard.dependOn(&definition_core_guard_cmd.step);
    const run_trace_core_tests = addTestStep(
        b,
        trace_core,
        "test-trace-core",
        "Run canonical physical trace tests",
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
    seq_cli_smoke_cmd.addArtifactArg(seq);
    const run_seq_cli_smoke = b.step(
        "test-seq-cli-smoke",
        "Run Seq 1.0 definition and observation smoke tests",
    );
    run_seq_cli_smoke.dependOn(&seq_cli_smoke_cmd.step);
    const run_ledger_core_tests = addTestStep(
        b,
        ledger_v1_core,
        "test-ledger-core",
        "Run Ledger 1.1 artifact-definition compiler tests",
    );
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
    const ledger_cli_smoke_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/test-ledger-cli.sh",
    });
    ledger_cli_smoke_cmd.addArtifactArg(ledger);
    const run_ledger_cli_smoke = b.step(
        "test-ledger-cli-smoke",
        "Run Ledger 1.1 definition, validation, and materialization smoke tests",
    );
    run_ledger_cli_smoke.dependOn(&ledger_cli_smoke_cmd.step);
    test_ledger.dependOn(&run_ledger_core_tests.step);
    test_ledger.dependOn(run_ledger_cli_smoke);
    const release_ledger_safe = b.step(
        "release-ledger-safe",
        "Run the Ledger release-safety gate",
    );
    release_ledger_safe.dependOn(&ledger_install.step);
    release_ledger_safe.dependOn(&run_ledger_core_tests.step);
    release_ledger_safe.dependOn(&run_ledger_tests.step);
    release_ledger_safe.dependOn(run_ledger_cli_smoke);
    release_ledger_safe.dependOn(&run_ledger_segmented_tests.step);
    release_ledger_safe.dependOn(&run_ledger_segmented_falsifiers.step);
    const ledger_command_surface = b.addSystemCommand(&.{
        "bash",
        "apps/ledger/scripts/release/command_surface_gate.sh",
    });
    ledger_command_surface.addArtifactArg(ledger);
    release_ledger_safe.dependOn(&ledger_command_surface.step);
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

    const cas_build_deps: []const *std.Build.Step =
        &.{
            &cas_smoke_check_install.step,
            &cas_instance_runner_install.step,
            &cas_review_session_install.step,
            &cas_session_inquiry_install.step,
            &cas_conformance_suite_install.step,
            &cas_goal_install.step,
            &cas_account_install.step,
            &cas_app_server_preflight_install.step,
            &cas_budget_perf_install.step,
            &cas_install.step,
            &cas_automation_install.step,
        };
    const synoptic_aggregate_test_deps: []const *std.Build.Step =
        if (target.result.os.tag == .macos) &.{test_synoptic} else &.{};
    const app_surfaces = [_]AppSurface{
        .{
            .path = b.path("apps/seq"),
            .build_step_name = "build-seq",
            .build_description = "Build seq binary",
            .build_deps = &.{&seq_install.step},
            .test_deps = &.{&run_seq_tests.step},
        },
        .{
            .path = b.path("apps/lift"),
            .build_step_name = "build-lift",
            .build_description = "Build lift binaries",
            .build_deps = &.{ &bench_stats_install.step, &perf_report_install.step, &lift_bench_perf_install.step },
            .test_deps = &.{test_lift},
        },
        .{
            .path = b.path("apps/cas"),
            .build_step_name = "build-cas",
            .build_description = "Build cas binaries",
            .build_deps = cas_build_deps,
            .test_deps = &.{test_cas},
        },
        .{
            .path = b.path("apps/synoptic"),
            .build_step_name = "build-synoptic",
            .build_description = "Build the native Synoptic executable",
            .build_deps = &.{&synoptic_install.step},
            .test_deps = synoptic_aggregate_test_deps,
        },
        .{
            .path = b.path("apps/ledger"),
            .build_step_name = "build-ledger",
            .build_description = "Build ledger binary",
            .build_deps = &.{&ledger_install.step},
            .test_deps = &.{&run_ledger_tests.step},
        },
        .{
            .path = b.path("apps/memory-note"),
            .build_step_name = "build-memory-note",
            .build_description = "Build memory-note binary",
            .build_deps = &.{&memory_note_install.step},
            .test_deps = &.{&run_memory_note_tests.step},
        },
        .{
            .path = b.path("apps/img"),
            .build_step_name = "build-img",
            .build_description = "Build img binary",
            .build_deps = &.{&img_install.step},
            .test_deps = &.{&run_img_tests.step},
        },
    };

    for (app_surfaces) |surface| {
        _ = addGroupedStep(b, surface.build_step_name, surface.build_description, surface.build_deps);
    }

    const test_all = b.step("test", "Run all routine application and core tests");
    for (app_surfaces) |surface| {
        for (surface.test_deps) |dep| test_all.dependOn(dep);
    }
    test_all.dependOn(&run_perf_hub_tests.step);
    test_all.dependOn(&run_durable_store_tests.step);
    test_all.dependOn(&run_durable_store_perf_tests.step);
    test_all.dependOn(&run_jsonl_core_tests.step);
    test_all.dependOn(&run_definition_core_tests.step);
    test_all.dependOn(run_definition_core_guard);
    test_all.dependOn(&run_trace_core_tests.step);
    test_all.dependOn(&run_seq_core_tests.step);
    test_all.dependOn(run_seq_cli_smoke);
    test_all.dependOn(&run_ledger_core_tests.step);
    test_all.dependOn(run_ledger_cli_smoke);

    const test_full = b.step("test-full", "Run routine tests and explicit slow qualification lanes");
    test_full.dependOn(test_all);
    test_full.dependOn(&run_canonical_json_corpus_tests.step);

    const enable_zlinter = b.option(
        bool,
        "enable_zlinter",
        "Internal flag to run zlinter-backed lint directly",
    ) orelse false;
    const lint_step = b.step("lint", "Run zlinter checks");
    if (enable_zlinter) {
        lint_step.dependOn(buildLintStep(b, target, &app_surfaces));
    } else {
        const lint_cmd = b.addSystemCommand(&.{ "zig", "build", "lint", "-Doptimize=ReleaseFast", "-Denable_zlinter=true" });
        if (b.args) |args| {
            lint_cmd.addArg("--");
            lint_cmd.addArgs(args);
        }
        lint_step.dependOn(&lint_cmd.step);
    }

    addRunStep(b, seq, "run-seq", "Run seq", &.{});
    addRunStep(b, ledger, "run-ledger", "Run ledger", &.{"--help"});
    addRunStep(b, memory_note, "run-memory-note", "Run memory-note", &.{"--help"});
    addRunStep(b, img, "run-img", "Run img", &.{"--help"});
    addRunStep(b, bench_stats, "run-bench-stats", "Run bench_stats", &.{"--help"});
    addRunStep(b, cas_smoke_check, "run-cas-smoke-check", "Run cas_smoke_check", &.{"--help"});
    addRunStep(b, cas_conformance_suite, "run-cas-conformance-suite", "Run cas_conformance_suite", &.{"--help"});
    addRunStep(b, cas_session_inquiry, "run-cas-session-inquiry", "Run cas_session_inquiry", &.{"--help"});
    addRunStep(b, cas_goal, "run-cas-goal", "Run cas_goal", &.{"--help"});
    addRunStep(b, cas_account, "run-cas-account", "Run cas_account", &.{"--help"});
    addRunStepPrefixed(b, perf_hub, "perf-list-local", "List local perf cases", &.{"list"});
    addRunStepPrefixed(b, perf_hub, "perf-manifest-local", "Emit native perf manifest", &.{"manifest"});
    addRunStepPrefixed(b, perf_hub, "perf-audit-local", "Audit native perf coverage", &.{"audit"});
    addRunStepPrefixed(b, perf_hub, "perf-doctor-local", "Validate local perf coverage and setup", &.{"doctor"});
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

fn installsSynopticByDefault(os_tag: std.Target.Os.Tag) bool {
    return os_tag == .macos;
}

test "default install admits Synoptic only for macOS targets" {
    try std.testing.expect(installsSynopticByDefault(.macos));
    try std.testing.expect(!installsSynopticByDefault(.linux));
    try std.testing.expect(!installsSynopticByDefault(.windows));
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

fn addInstallStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
) *std.Build.Step.InstallArtifact {
    return b.addInstallArtifact(exe, .{});
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
            "skills-zig forbids external installs; ship CLIs via the Homebrew tap release flow only. expected install_prefix={s} exe_dir={s}; got install_prefix={s} exe_dir={s} dest_dir={?s}",
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
