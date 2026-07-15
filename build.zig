const std = @import("std");
pub fn build(b: *std.Build) void {
    enforceRepoLocalInstallOnly(b);

    const target = b.standardTargetOptions(.{});
    const hctp_product_available = target.result.os.tag == .macos;
    const optimize = b.standardOptimizeOption(.{});

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
        .root_source_file = b.path("libs/core/src/perf_contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const durable_store = b.createModule(.{
        .root_source_file = b.path("libs/durable_store/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const retrace_core = b.createModule(.{
        .root_source_file = b.path("libs/retrace_core/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const hctp_fixtures = b.createModule(.{
        .root_source_file = b.path("testdata/hctp-v1/fixtures.zig"),
        .target = target,
        .optimize = optimize,
    });
    const execution_policy_core = b.createModule(.{
        .root_source_file = b.path("libs/execution_policy_core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const seq_bundle = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/bundle.zig"),
        .target = target,
        .optimize = optimize,
    });
    const seq_meta = addVersionModule(b, @embedFile("apps/seq/VERSION"));
    const seq_perf_cli = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/perf_cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_path", .module = core_path },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "retrace_core", .module = retrace_core },
            .{ .name = "execution_policy_core", .module = execution_policy_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = seq_meta },
        },
    });
    const lift_meta = addVersionModule(b, @embedFile("apps/lift/VERSION"));
    const cas_meta = addVersionModule(b, @embedFile("apps/cas/VERSION"));
    const cron_meta = addVersionModule(b, @embedFile("apps/cron/VERSION"));
    const ledger_meta = addVersionModule(b, @embedFile("apps/ledger/VERSION"));
    const memory_note_meta = addVersionModule(b, @embedFile("apps/memory-note/VERSION"));
    const img_meta = addVersionModule(b, @embedFile("apps/img/VERSION"));
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

    const seq_root = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_path", .module = core_path },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "retrace_core", .module = retrace_core },
            .{ .name = "execution_policy_core", .module = execution_policy_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = seq_meta },
        },
    });
    const seq_perf_root = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/perf_harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = seq_meta },
        },
    });
    const seq_tests_root = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_path", .module = core_path },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "retrace_core", .module = retrace_core },
            .{ .name = "execution_policy_core", .module = execution_policy_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = seq_meta },
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
    const cas_smoke_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_smoke_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cas_meta },
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
        },
    });
    const cas_session_inquiry_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_session_inquiry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "core_path", .module = core_path },
            .{ .name = "retrace_core", .module = retrace_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = cas_meta },
        },
    });
    const cas_trial_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_trial.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "retrace_core", .module = retrace_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
        },
    });
    const cas_trial_tests_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_trial.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "retrace_core", .module = retrace_core },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = cas_meta },
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
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
        },
    });
    const cas_proxy_client_root = b.createModule(.{
        .root_source_file = b.path("apps/cas/scripts/cas_proxy_client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_json", .module = core_json },
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
    const cron_root = b.createModule(.{
        .root_source_file = b.path("apps/cron/scripts/cron.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "app_meta", .module = cron_meta },
        },
    });
    const append_learning_root = b.createModule(.{
        .root_source_file = b.path("apps/learnings/scripts/append_learning.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_delegate", .module = core_delegate },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = ledger_meta },
        },
    });
    const learnings_root = b.createModule(.{
        .root_source_file = b.path("apps/learnings/scripts/learnings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "append_learning_cli", .module = append_learning_root },
            .{ .name = "core_delegate", .module = core_delegate },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = ledger_meta },
            .{ .name = "seq_bundle", .module = seq_bundle },
        },
    });
    const synesthesia_root = b.createModule(.{
        .root_source_file = b.path("apps/synesthesia/scripts/synesthesia.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = ledger_meta },
        },
    });
    const ledger_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/ledger.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "learnings_cli", .module = learnings_root },
            .{ .name = "synesthesia_cli", .module = synesthesia_root },
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = ledger_meta },
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hylo_cli_tests_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/hylo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = ledger_meta },
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_contract_tests_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/hctp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_fold_tests_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/hctp_fold.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_source_contract_module = b.createModule(.{
        .root_source_file = b.path("apps/seq/src/hctp_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_conformance_registration_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/hctp_conformance_registration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_conformance_execution_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/hctp_conformance_execution.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_conformance_grading_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/hctp_conformance_grading.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_conformance_retrace_holdout_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/hctp_conformance_retrace_holdout.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
            .{ .name = "retrace_core", .module = retrace_core },
            .{ .name = "hctp_source", .module = hctp_source_contract_module },
        },
    });
    const hctp_conformance_manifest_root = b.createModule(.{
        .root_source_file = b.path("testdata/hctp-v1/conformance_manifest.zig"),
        .target = target,
        .optimize = optimize,
    });
    const hctp_conformance_backend_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/hctp_conformance_backend.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core_cli", .module = core_cli },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "app_meta", .module = ledger_meta },
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
            .{ .name = "retrace_core", .module = retrace_core },
            .{ .name = "hctp_source", .module = hctp_source_contract_module },
        },
    });
    const hctp_legacy_compat_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/hctp_legacy_compat.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "durable_store", .module = durable_store }},
    });
    const hctp_integration_root = b.createModule(.{
        .root_source_file = b.path("apps/ledger/scripts/hctp_integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "hctp_fixtures", .module = hctp_fixtures },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_cas_fixture_executor_root = b.createModule(.{
        .root_source_file = b.path("testdata/hctp-v1/cas-fixture-executor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cas_session_inquiry", .module = cas_session_inquiry_root },
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_sealed_fixture_executor_root = b.createModule(.{
        .root_source_file = b.path("testdata/hctp-v1/sealed-cas-fixture-executor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "durable_store", .module = durable_store }},
    });
    const hctp_sealed_source_fixture_root = b.createModule(.{
        .root_source_file = b.path("testdata/hctp-v1/sealed-source-fixture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_sealed_grader_fixture_root = b.createModule(.{
        .root_source_file = b.path("testdata/hctp-v1/sealed-grader-fixture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_sealed_grade_materializer_fixture_root = b.createModule(.{
        .root_source_file = b.path("testdata/hctp-v1/sealed-grade-materializer-fixture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "retrace_core", .module = retrace_core },
        },
    });
    const hctp_sealed_role_driver_root = b.createModule(.{
        .root_source_file = b.path("testdata/hctp-v1/sealed-role-driver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "durable_store", .module = durable_store },
            .{ .name = "retrace_core", .module = retrace_core },
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
            .{ .name = "perf_contract", .module = core_perf_contract },
            .{ .name = "seq_perf_cli", .module = seq_perf_cli },
            .{ .name = "cron_cli", .module = cron_root },
        },
    });

    const seq = addExecutable(b, "seq", seq_root);
    seq.root_module.linkSystemLibrary("c", .{});
    seq.root_module.linkSystemLibrary("sqlite3", .{});
    const seq_perf = addExecutable(b, "seq-perf", seq_perf_root);
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
    const cas_trial = addExecutable(b, "cas_trial", cas_trial_root);
    cas_trial.root_module.linkSystemLibrary("c", .{});
    const hctp_cas_fixture_executor = addExecutable(b, "hctp-cas-fixture-executor", hctp_cas_fixture_executor_root);
    const hctp_sealed_fixture_executor = addExecutable(b, "hctp-sealed-cas-fixture-executor", hctp_sealed_fixture_executor_root);
    const hctp_sealed_source_fixture = addExecutable(b, "hctp-sealed-source-fixture", hctp_sealed_source_fixture_root);
    hctp_sealed_source_fixture.root_module.linkSystemLibrary("c", .{});
    const hctp_sealed_grader_fixture = addExecutable(b, "hctp-sealed-grader-fixture", hctp_sealed_grader_fixture_root);
    hctp_sealed_grader_fixture.root_module.linkSystemLibrary("c", .{});
    const hctp_sealed_grade_materializer_fixture = addExecutable(b, "hctp-sealed-grade-materializer-fixture", hctp_sealed_grade_materializer_fixture_root);
    hctp_sealed_grade_materializer_fixture.root_module.linkSystemLibrary("c", .{});
    const hctp_integration_paths = b.addOptions();
    hctp_integration_paths.addOptionPath("seq_path", seq.getEmittedBin());
    hctp_integration_paths.addOptionPath("cas_trial_path", cas_trial.getEmittedBin());
    hctp_integration_paths.addOptionPath("fixture_executor_path", hctp_cas_fixture_executor.getEmittedBin());
    hctp_integration_paths.addOptionPath("sealed_fixture_executor_path", hctp_sealed_fixture_executor.getEmittedBin());
    hctp_integration_paths.addOptionPath("sealed_source_fixture_path", hctp_sealed_source_fixture.getEmittedBin());
    hctp_integration_paths.addOptionPath("sealed_grader_fixture_path", hctp_sealed_grader_fixture.getEmittedBin());
    hctp_integration_paths.addOptionPath("sealed_grade_materializer_fixture_path", hctp_sealed_grade_materializer_fixture.getEmittedBin());
    hctp_integration_root.addOptions("hctp_integration_paths", hctp_integration_paths);
    const cas_conformance_suite = addExecutable(b, "cas_conformance_suite", cas_conformance_root);
    const cas_goal = addExecutable(b, "cas_goal", cas_goal_root);
    const cas_account = addExecutable(b, "cas_account", cas_account_root);
    const cas_budget_perf = addExecutable(b, "cas-perf-budget-governor", cas_budget_perf_root);
    const cas = addExecutable(b, "cas", cas_root);
    const cron = addExecutable(b, "cron", cron_root);
    cron.root_module.linkSystemLibrary("c", .{});
    cron.root_module.linkSystemLibrary("sqlite3", .{});
    const ledger = addExecutable(b, "ledger", ledger_root);
    const hctp_sealed_role_driver_paths = b.addOptions();
    hctp_sealed_role_driver_paths.addOptionPath("seq_path", seq.getEmittedBin());
    hctp_sealed_role_driver_paths.addOptionPath("cas_trial_path", cas_trial.getEmittedBin());
    hctp_sealed_role_driver_paths.addOptionPath("sealed_fixture_executor_path", hctp_sealed_fixture_executor.getEmittedBin());
    hctp_sealed_role_driver_paths.addOptionPath("sealed_source_fixture_path", hctp_sealed_source_fixture.getEmittedBin());
    hctp_sealed_role_driver_paths.addOptionPath("sealed_grader_fixture_path", hctp_sealed_grader_fixture.getEmittedBin());
    hctp_sealed_role_driver_paths.addOptionPath("sealed_grade_materializer_fixture_path", hctp_sealed_grade_materializer_fixture.getEmittedBin());
    hctp_sealed_role_driver_paths.addOptionPath("ledger_path", ledger.getEmittedBin());
    hctp_sealed_role_driver_root.addOptions("hctp_sealed_role_driver_paths", hctp_sealed_role_driver_paths);
    const hctp_sealed_role_driver = addExecutable(b, "hctp-sealed-role-driver", hctp_sealed_role_driver_root);
    hctp_sealed_role_driver.root_module.linkSystemLibrary("c", .{});
    hctp_integration_paths.addOptionPath("sealed_role_driver_path", hctp_sealed_role_driver.getEmittedBin());
    const hctp_legacy_paths = b.addOptions();
    hctp_legacy_paths.addOptionPath("ledger_path", ledger.getEmittedBin());
    hctp_legacy_paths.addOption([]const u8, "campaign_bytes", @embedFile("testdata/hctp-v1/legacy/campaign-v1.json"));
    hctp_legacy_paths.addOption([]const u8, "scenario_bytes", @embedFile("testdata/hctp-v1/legacy/scenarios.jsonl"));
    hctp_legacy_paths.addOption([]const u8, "event_bytes", @embedFile("testdata/hctp-v1/legacy/events-v1.jsonl"));
    hctp_legacy_paths.addOption([]const u8, "expected_progress_bytes", @embedFile("testdata/hctp-v1/legacy/expected-progress-v1.json"));
    hctp_legacy_paths.addOption([]const u8, "corpus_bytes", @embedFile("testdata/hctp-v1/legacy/corpus-v1.json"));
    hctp_legacy_compat_root.addOptions("hctp_legacy_paths", hctp_legacy_paths);
    hctp_integration_paths.addOptionPath("ledger_path", ledger.getEmittedBin());
    const memory_note = addExecutable(b, "memory-note", memory_note_root);
    const img = addExecutable(b, "img", img_root);
    const perf_hub = addExecutable(b, "perf_hub", perf_hub_root);

    const seq_install = addInstallStep(b, seq);
    const seq_perf_install = addInstallStep(b, seq_perf);
    const bench_stats_install = addInstallStep(b, bench_stats);
    const perf_report_install = addInstallStep(b, perf_report);
    const lift_bench_perf_install = addInstallStep(b, lift_bench_perf);
    const cas_smoke_check_install = addInstallStep(b, cas_smoke_check);
    const cas_instance_runner_install = addInstallStep(b, cas_instance_runner);
    const cas_review_session_install = addInstallStep(b, cas_review_session);
    const cas_session_inquiry_install = addInstallStep(b, cas_session_inquiry);
    const cas_trial_install = addInstallStep(b, cas_trial);
    const cas_conformance_suite_install = addInstallStep(b, cas_conformance_suite);
    const cas_goal_install = addInstallStep(b, cas_goal);
    const cas_account_install = addInstallStep(b, cas_account);
    const cas_budget_perf_install = addInstallStep(b, cas_budget_perf);
    const cas_install = addInstallStep(b, cas);
    const cron_install = addInstallStep(b, cron);
    const ledger_install = addInstallStep(b, ledger);
    const memory_note_install = addInstallStep(b, memory_note);
    const img_install = addInstallStep(b, img);
    const perf_hub_install = addInstallStep(b, perf_hub);

    const install_all = b.getInstallStep();
    install_all.dependOn(&seq_install.step);
    install_all.dependOn(&seq_perf_install.step);
    install_all.dependOn(&bench_stats_install.step);
    install_all.dependOn(&perf_report_install.step);
    install_all.dependOn(&lift_bench_perf_install.step);
    install_all.dependOn(&cas_smoke_check_install.step);
    install_all.dependOn(&cas_instance_runner_install.step);
    install_all.dependOn(&cas_review_session_install.step);
    install_all.dependOn(&cas_session_inquiry_install.step);
    if (hctp_product_available) install_all.dependOn(&cas_trial_install.step);
    install_all.dependOn(&cas_conformance_suite_install.step);
    install_all.dependOn(&cas_goal_install.step);
    install_all.dependOn(&cas_account_install.step);
    install_all.dependOn(&cas_budget_perf_install.step);
    install_all.dependOn(&cas_install.step);
    install_all.dependOn(&cron_install.step);
    install_all.dependOn(&ledger_install.step);
    install_all.dependOn(&memory_note_install.step);
    install_all.dependOn(&img_install.step);
    install_all.dependOn(&perf_hub_install.step);

    const run_seq_tests = addTestStepWithOptions(
        b,
        seq_tests_root,
        "test-seq",
        "Run seq tests",
        .{
            .link_libc = true,
            .sqlite = true,
            .cwd = b.path("apps/seq"),
        },
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
    const run_cas_trial_tests: ?*std.Build.Step.Run = if (hctp_product_available)
        addTestStepWithOptions(
            b,
            cas_trial_tests_root,
            "test-cas-trial",
            "Run macOS cas_trial tests",
            .{ .link_libc = true },
        )
    else
        null;
    if (hctp_product_available) {
        _ = addTestStepWithOptions(
            b,
            cas_trial_tests_root,
            "test-cas-trial-macos-runtime",
            "Run macOS CAS trial descriptor, cwd, timeout, and directly supervised process laws",
            .{
                .link_libc = true,
                .filters = &.{
                    "executor inherits only standard allowlisted descriptors",
                    "executor runs in the requested isolated cwd",
                    "executor deadline kills and reaps a hung child",
                    "zombie-only executor group is terminal after direct child reap",
                    "advisory group STOP permission failure skips census and still proves kill reap and absence",
                    "nonzero executor preserves the directly supervised terminal observation",
                },
            },
        );
    }
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
    const run_cas_cli_tests = addTestStepWithOptions(
        b,
        cas_root,
        "test-cas-cli",
        "Run cas dispatcher tests",
        .{ .link_libc = true },
    );
    const test_cas = b.step("test-cas", "Run all cas tests");
    test_cas.dependOn(&run_cas_budget_governor_tests.step);
    test_cas.dependOn(&run_cas_smoke_tests.step);
    test_cas.dependOn(&run_cas_runner_tests.step);
    test_cas.dependOn(&run_cas_review_session_tests.step);
    test_cas.dependOn(&run_cas_session_inquiry_tests.step);
    if (run_cas_trial_tests) |run_tests| test_cas.dependOn(&run_tests.step);
    test_cas.dependOn(&run_cas_conformance_tests.step);
    test_cas.dependOn(&run_cas_goal_tests.step);
    test_cas.dependOn(&run_cas_account_tests.step);
    test_cas.dependOn(&run_cas_proxy_client_tests.step);
    test_cas.dependOn(&run_cas_cli_tests.step);

    const run_cron_tests = addTestStepWithOptions(
        b,
        cron_root,
        "test-cron",
        "Run cron tests",
        .{
            .link_libc = true,
            .sqlite = true,
        },
    );

    const run_learnings_tests = addTestStep(
        b,
        learnings_root,
        "test-learnings",
        "Run learnings tests",
    );
    const run_append_learning_tests = addTestStep(
        b,
        append_learning_root,
        "test-append-learning",
        "Run append_learning tests",
    );
    const run_synesthesia_tests = addTestStep(
        b,
        synesthesia_root,
        "test-synesthesia",
        "Run internal ledger synesthesia-source tests",
    );
    const run_ledger_tests = addTestStep(
        b,
        ledger_root,
        "test-ledger",
        "Run ledger tests",
    );
    const hylo_test_filter = b.option(
        []const u8,
        "hylo-test-filter",
        "Override the focused HCTP test filter",
    ) orelse "proof";
    const run_hylo_proof_tests = addTestStepWithOptions(
        b,
        hylo_cli_tests_root,
        "test-hylo-proof",
        "Run HCTP-v1 proof bundle tests",
        .{ .filters = &.{hylo_test_filter} },
    );
    const run_hctp_contract_tests = addTestStep(
        b,
        hctp_contract_tests_root,
        "test-hylo-contracts",
        "Run HCTP-v1 contract tests",
    );
    const run_hctp_fold_tests = addTestStep(
        b,
        hctp_fold_tests_root,
        "test-hylo-fold",
        "Run HCTP-v1 fold tests",
    );
    const run_hctp_conformance_registration = addTestStep(
        b,
        hctp_conformance_registration_root,
        "test-hctp-conformance-registration",
        "Run HCTP-v1 registration conformance cases",
    );
    const run_hctp_conformance_execution = addTestStep(
        b,
        hctp_conformance_execution_root,
        "test-hctp-conformance-execution",
        "Run HCTP-v1 execution conformance cases",
    );
    const run_hctp_conformance_grading = addTestStep(
        b,
        hctp_conformance_grading_root,
        "test-hctp-conformance-grading",
        "Run HCTP-v1 grading and fold conformance cases",
    );
    const run_hctp_conformance_retrace_holdout = addTestStep(
        b,
        hctp_conformance_retrace_holdout_root,
        "test-hctp-conformance-retrace-holdout",
        "Run HCTP-v1 calibration, Retrace, and holdout conformance cases",
    );
    const run_hctp_conformance_manifest = addTestStepWithOptions(
        b,
        hctp_conformance_manifest_root,
        "test-hctp-conformance-manifest",
        "Validate the HCTP-v1 Section 36 conformance manifest",
        .{ .cwd = b.path(".") },
    );
    const run_hctp_conformance_hylo = addTestStepWithOptions(
        b,
        hylo_cli_tests_root,
        "test-hctp-conformance-hylo",
        "Run Hylo-owned HCTP-v1 conformance cases",
        .{ .filters = &.{"HCTP Section 36"} },
    );
    _ = run_hctp_conformance_hylo;
    const hctp_conformance_backend_tests = b.addTest(.{
        .root_module = hctp_conformance_backend_root,
        .filters = &.{ "HCTP", "36." },
        .test_runner = .{
            .path = b.path("testdata/hctp-v1/conformance_backend_runner.zig"),
            .mode = .simple,
        },
    });
    const run_hctp_conformance_memory = b.addRunArtifact(hctp_conformance_backend_tests);
    run_hctp_conformance_memory.setCwd(b.path("."));
    run_hctp_conformance_memory.setEnvironmentVariable("HCTP_CONFORMANCE_BACKEND", "memory");
    const test_hctp_conformance_memory = b.step(
        "test-hctp-conformance-memory",
        "Run all 71 HCTP-v1 Section 36 cases through the memory backend lane",
    );
    test_hctp_conformance_memory.dependOn(&run_hctp_conformance_memory.step);
    const run_hctp_conformance_persistent = b.addRunArtifact(hctp_conformance_backend_tests);
    run_hctp_conformance_persistent.setCwd(b.path("."));
    run_hctp_conformance_persistent.setEnvironmentVariable("HCTP_CONFORMANCE_BACKEND", "persistent");
    const test_hctp_conformance_persistent = b.step(
        "test-hctp-conformance-persistent",
        "Run all 71 HCTP-v1 Section 36 cases through the persistent backend lane",
    );
    test_hctp_conformance_persistent.dependOn(&run_hctp_conformance_persistent.step);
    const test_hctp_conformance_backends = b.step(
        "test-hctp-conformance-backends",
        "Run the complete HCTP-v1 Section 36 matrix through both EventStore lanes",
    );
    test_hctp_conformance_backends.dependOn(test_hctp_conformance_memory);
    test_hctp_conformance_backends.dependOn(test_hctp_conformance_persistent);
    const hctp_conformance_case_11_tests = b.addTest(.{
        .root_module = hctp_conformance_backend_root,
        .filters = &.{"HCTP EventStore case 11 focused selected-backend owner witness"},
    });
    const run_hctp_conformance_case_11_memory = b.addRunArtifact(hctp_conformance_case_11_tests);
    run_hctp_conformance_case_11_memory.setCwd(b.path("."));
    run_hctp_conformance_case_11_memory.setEnvironmentVariable("HCTP_CONFORMANCE_BACKEND", "memory");
    const run_hctp_conformance_case_11_persistent = b.addRunArtifact(hctp_conformance_case_11_tests);
    run_hctp_conformance_case_11_persistent.setCwd(b.path("."));
    run_hctp_conformance_case_11_persistent.setEnvironmentVariable("HCTP_CONFORMANCE_BACKEND", "persistent");
    const test_hctp_conformance_case_11_backends = b.step(
        "test-hctp-conformance-case-11-backends",
        "Run the Section 36 case 11 EventStore owner witness through memory and persistent reload",
    );
    test_hctp_conformance_case_11_backends.dependOn(&run_hctp_conformance_case_11_memory.step);
    test_hctp_conformance_case_11_backends.dependOn(&run_hctp_conformance_case_11_persistent.step);
    const run_hctp_legacy_compat = addTestStep(
        b,
        hctp_legacy_compat_root,
        "test-hylo-legacy-compat",
        "Verify frozen Ledger 0.7.2 Hylo bytes under the current parser and fold",
    );
    const hctp_integration_tests = b.addTest(.{ .root_module = hctp_integration_root });
    hctp_integration_tests.root_module.linkSystemLibrary("c", .{});
    const hctp_cas_fir_integration_tests = b.addTest(.{
        .root_module = hctp_integration_root,
        .filters = &.{"one historical Hylo lane normalizes one FIR"},
    });
    hctp_cas_fir_integration_tests.root_module.linkSystemLibrary("c", .{});
    const run_hctp_cas_fir_integration = b.addRunArtifact(hctp_cas_fir_integration_tests);
    const test_hctp_cas_fir_integration = b.step(
        "test-hctp-cas-fir-integration",
        "Run packaged CAS FIR through Retrace normalization and the production CAS trial adapter",
    );
    test_hctp_cas_fir_integration.dependOn(&run_hctp_cas_fir_integration.step);
    const hctp_cas_factor_materialization_tests = b.addTest(.{
        .root_module = hctp_integration_root,
        .filters = &.{"HCTP CAS factor materialization"},
    });
    hctp_cas_factor_materialization_tests.root_module.linkSystemLibrary("c", .{});
    const run_hctp_cas_factor_materialization = b.addRunArtifact(hctp_cas_factor_materialization_tests);
    const test_hctp_cas_factor_materialization = b.step(
        "test-hctp-cas-factor-materialization",
        "Run positive-sentinel immutable CAS factor materialization proof",
    );
    test_hctp_cas_factor_materialization.dependOn(&run_hctp_cas_factor_materialization.step);
    const hctp_cas_historical_failure_tests = b.addTest(.{
        .root_module = hctp_integration_root,
        .filters = &.{"HCTP end-to-end: historical executor failure terminalizes once without FIR or comparison"},
    });
    hctp_cas_historical_failure_tests.root_module.linkSystemLibrary("c", .{});
    const run_hctp_cas_historical_failure = b.addRunArtifact(hctp_cas_historical_failure_tests);
    const test_hctp_cas_historical_failure = b.step(
        "test-hctp-cas-historical-failure",
        "Run post-claim historical CAS failure terminalization proof",
    );
    test_hctp_cas_historical_failure.dependOn(&run_hctp_cas_historical_failure.step);
    const run_hctp_integration = b.addRunArtifact(hctp_integration_tests);
    const test_hctp_integration = b.step(
        "test-hctp-integration",
        "Run the actual CAS-to-Hylo and Retrace-to-Hylo HCTP integration proof",
    );
    test_hctp_integration.dependOn(&run_hctp_integration.step);
    const hctp_sealed_commitment_tests = b.addTest(.{
        .root_module = hctp_integration_root,
        .filters = &.{"HCTP sealed promotion Section 36 case 67 positive witness: supported holdout improvement is published"},
    });
    hctp_sealed_commitment_tests.root_module.linkSystemLibrary("c", .{});
    const run_hctp_sealed_commitments = b.addRunArtifact(hctp_sealed_commitment_tests);
    const test_hctp_sealed_commitments = b.step(
        "test-hctp-sealed-commitments",
        "Run the macOS sealed grade commitment/opening promotion proof",
    );
    test_hctp_sealed_commitments.dependOn(&run_hctp_sealed_commitments.step);
    const test_hctp_conformance = b.step(
        "test-hctp-conformance",
        "Run the numbered HCTP-v1 Section 36 suite and supporting owner invariants",
    );
    test_hctp_conformance.dependOn(&run_hctp_conformance_registration.step);
    test_hctp_conformance.dependOn(&run_hctp_conformance_execution.step);
    test_hctp_conformance.dependOn(&run_hctp_conformance_grading.step);
    test_hctp_conformance.dependOn(&run_hctp_conformance_retrace_holdout.step);
    test_hctp_conformance.dependOn(&run_hctp_conformance_manifest.step);
    test_hctp_conformance.dependOn(test_hctp_conformance_backends);
    const test_hylo = b.step("test-hylo", "Run HCTP-v1 contract and fold tests");
    test_hylo.dependOn(&run_hctp_contract_tests.step);
    test_hylo.dependOn(&run_hctp_fold_tests.step);
    test_hylo.dependOn(&run_hylo_proof_tests.step);
    test_hylo.dependOn(&run_hctp_legacy_compat.step);
    test_hylo.dependOn(test_hctp_conformance);
    test_hylo.dependOn(test_hctp_integration);
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
    const run_execution_policy_core_tests = addTestStep(
        b,
        execution_policy_core,
        "test-execution-policy-core",
        "Run execution_policy_core tests",
    );
    const run_retrace_core_tests = addTestStepWithOptions(
        b,
        retrace_core,
        "test-retrace-core",
        "Run Retrace core contract tests",
        .{ .cwd = b.path("apps/seq") },
    );

    const cas_build_deps: []const *std.Build.Step = if (hctp_product_available)
        &.{ &cas_smoke_check_install.step, &cas_instance_runner_install.step, &cas_review_session_install.step, &cas_session_inquiry_install.step, &cas_trial_install.step, &cas_conformance_suite_install.step, &cas_goal_install.step, &cas_account_install.step, &cas_budget_perf_install.step, &cas_install.step }
    else
        &.{ &cas_smoke_check_install.step, &cas_instance_runner_install.step, &cas_review_session_install.step, &cas_session_inquiry_install.step, &cas_conformance_suite_install.step, &cas_goal_install.step, &cas_account_install.step, &cas_budget_perf_install.step, &cas_install.step };
    const ledger_test_deps: []const *std.Build.Step = if (hctp_product_available)
        &.{ &run_ledger_tests.step, test_hylo, &run_synesthesia_tests.step }
    else
        &.{ &run_ledger_tests.step, &run_synesthesia_tests.step };

    const app_surfaces = [_]AppSurface{
        .{
            .path = b.path("apps/seq"),
            .build_step_name = "build-seq",
            .build_description = "Build seq binaries",
            .build_deps = &.{ &seq_install.step, &seq_perf_install.step },
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
            .path = b.path("apps/cron"),
            .build_step_name = "build-cron",
            .build_description = "Build cron binaries",
            .build_deps = &.{&cron_install.step},
            .test_deps = &.{&run_cron_tests.step},
        },
        .{
            .path = b.path("apps/learnings"),
            .build_step_name = "build-learnings",
            .build_description = "Run internal ledger learnings-source tests",
            .build_deps = &.{},
            .test_deps = &.{ &run_learnings_tests.step, &run_append_learning_tests.step },
        },
        .{
            .path = b.path("apps/synesthesia"),
            .build_step_name = "build-synesthesia",
            .build_description = "Run internal ledger synesthesia-source tests",
            .build_deps = &.{},
            .test_deps = &.{&run_synesthesia_tests.step},
        },
        .{
            .path = b.path("apps/ledger"),
            .build_step_name = "build-ledger",
            .build_description = "Build ledger binary",
            .build_deps = &.{&ledger_install.step},
            .test_deps = ledger_test_deps,
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

    const test_all = b.step("test", "Run all tests");
    for (app_surfaces) |surface| {
        for (surface.test_deps) |dep| test_all.dependOn(dep);
    }
    test_all.dependOn(&run_perf_hub_tests.step);
    test_all.dependOn(&run_durable_store_tests.step);
    test_all.dependOn(&run_execution_policy_core_tests.step);
    test_all.dependOn(&run_retrace_core_tests.step);

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
    if (hctp_product_available) {
        addRunStep(b, cas_trial, "run-cas-trial", "Run macOS cas_trial", &.{"--help"});
    }
    addRunStep(b, cas_goal, "run-cas-goal", "Run cas_goal", &.{"--help"});
    addRunStep(b, cas_account, "run-cas-account", "Run cas_account", &.{"--help"});
    addRunStepPrefixed(b, perf_hub, "perf-list-local", "List local perf cases", &.{"list"});
    addRunStepPrefixed(b, perf_hub, "perf-manifest-local", "Emit native perf manifest", &.{"manifest"});
    addRunStepPrefixed(b, perf_hub, "perf-audit-local", "Audit native perf coverage", &.{"audit"});
    addRunStepPrefixed(b, perf_hub, "perf-doctor-local", "Validate local perf coverage and setup", &.{"doctor"});
    addRunStepPrefixed(b, perf_hub, "perf-capture-local", "Capture local perf baselines", &.{"capture"});
    addRunStepPrefixed(b, perf_hub, "perf-compare-local", "Compare against local perf baselines", &.{"compare"});
    addRunStepPrefixed(b, perf_hub, "perf-report-local", "Summarize latest compare artifacts", &.{"report"});
    addRunStepPrefixed(b, perf_hub, "perf-accept-local", "Accept current baselines into the local ledger", &.{"accept"});
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
            b.path("libs/retrace_core"),
            b.path("build.zig"),
            b.path("testdata/hctp-v1"),
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
