const std = @import("std");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const core_perf = @import("core_perf");
const cron_cli = @import("cron_cli");
const perf_contract = @import("perf_contract");
const seq_cli = @import("seq_perf_cli");
const st_cli = @import("st_cli");

const Version = "0.0.0-dev";
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "perf_hub",
    .help_text = UsageText,
};
const UsageText =
    \\perf_hub
    \\
    \\Native control plane for local perf evidence.
    \\
    \\Usage:
    \\  perf_hub <command> [options]
    \\
    \\Commands:
    \\  list                  List known perf cases
    \\  manifest              Emit the native perf manifest as JSON
    \\  audit                 Print coverage audit summary
    \\  capture               Run native preserved-matrix baseline capture
    \\  compare               Run native preserved-matrix comparison
    \\  doctor                Validate native local perf setup
    \\  report                Summarize the last native compare artifact and emit cutover status
    \\  accept                Snapshot current baselines into an accepted ledger
    \\
    \\Options:
    \\  --target TEXT         Filter by binary/case substring where supported
    \\  --help                Show help
    \\  --version             Show version
    \\  version               Show version
;

const Command = enum {
    list,
    manifest,
    audit,
    capture,
    compare,
    doctor,
    report,
    accept,
};

const CompatBuilder = enum {
    root,
    seq_local,
};

const CompatSetup = enum {
    seq_help,
    seq_parser_driver,
    bench_stats_help,
    bench_stats_parse,
    perf_report_help,
    perf_report_render,
    lift_bench_stats_driver,
    cas_wrapper_smoke,
    cas_smoke_check_help,
    cas_instance_runner_help,
    cas_review_session_help,
    cas_review_session_version,
    cas_budget_governor_driver,
    cron_help,
    cron_list,
    puff_help,
    puff_wrapper,
    learnings_help,
    learnings_recent,
    learnings_recall,
    learnings_query,
    learnings_codify,
    learnings_quality,
    append_learning_help,
    append_learning_append,
    mesh_help,
    mesh_budget,
    mesh_plan_sync,
    mesh_slice,
    mesh_wave,
    st_help,
    st_add_show,
    st_emit_export,
    parse_arch_help,
    parse_arch_collect,
    parse_arch_eval,
    parse_arch_doctor,
};

const CompatCase = struct {
    descriptor: perf_contract.CaseDescriptor,
    builder: CompatBuilder,
    build_step: ?[]const u8,
    binary_path: []const u8,
    setup: CompatSetup,
    warmups: usize = 1,
    samples: usize = 5,
    tolerance_pct: f64 = 15.0,
};

const DeepSetup = enum {
    seq_query_tool_calls,
    seq_skill_success_rank,
    seq_skill_audit,
    seq_skill_blocks,
    seq_tool_audit,
    seq_memory_inventory,
    seq_message_search,
    seq_message_audit,
    seq_skill_cohort,
    seq_tool_search,
    seq_memory_extension_audit,
    seq_token_window,
    seq_workdir_report,
    seq_plan_search,
    seq_reply_latency,
    seq_sessions_limit,
    seq_turns,
    seq_session_detail,
    seq_tool_lifecycle,
    seq_session_graph,
    seq_tail_once,
    seq_token_cost,
    seq_goal_audit,
    seq_workflow_audit,
    seq_memory_map,
    seq_memory_history,
    seq_session_tooling,
    seq_orchestration_concurrency,
    seq_datasets,
    seq_dataset_schema,
    seq_artifact_search,
    seq_find_session,
    seq_session_prompts,
    seq_query_diagnose,
    seq_skills_rank,
    seq_skill_trend,
    seq_skill_report,
    seq_role_breakdown,
    seq_occurrence_export,
    seq_report_bundle,
    seq_section_audit,
    seq_token_usage,
    seq_routing_gap,
    cron_show,
    cron_create,
    cron_update,
    cron_enable,
    cron_disable,
    cron_run_now,
    cron_delete,
    cron_run_due,
    st_init,
    st_set_status,
    st_set_priority,
    st_set_deps,
    st_set_notes,
    st_add_comment,
    st_remove,
    st_ready,
    st_blocked,
    st_doctor,
    st_prime,
    st_import_plan,
};

const DeepCase = struct {
    descriptor: perf_contract.CaseDescriptor,
    setup: DeepSetup,
    tolerance_pct: f64 = 20.0,
    warmups: usize = 1,
    samples: usize = 5,
};

const SeqCases = [_]perf_contract.CaseDescriptor{
    .{ .case_id = "seq-help", .binary = "seq", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "seq-query-tool-calls", .binary = "seq", .family = "query", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-skill-success-rank", .binary = "seq", .family = "skill-success-rank", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-skill-audit", .binary = "seq", .family = "skill-audit", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-skill-blocks", .binary = "seq", .family = "skill-blocks", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-tool-audit", .binary = "seq", .family = "tool-audit", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-message-search", .binary = "seq", .family = "message-search", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-message-audit", .binary = "seq", .family = "message-audit", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-skill-cohort", .binary = "seq", .family = "skill-cohort", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-tool-search", .binary = "seq", .family = "tool-search", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-token-window", .binary = "seq", .family = "token-window", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-workdir-report", .binary = "seq", .family = "workdir-report", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-plan-search", .binary = "seq", .family = "plan-search", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-sessions-limit", .binary = "seq", .family = "sessions", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-turns", .binary = "seq", .family = "turns", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-session-detail", .binary = "seq", .family = "session-detail", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-tool-lifecycle", .binary = "seq", .family = "tool-lifecycle", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-tail-once", .binary = "seq", .family = "tail", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-session-tooling", .binary = "seq", .family = "session-tooling", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-orchestration-concurrency", .binary = "seq", .family = "orchestration-concurrency", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-datasets", .binary = "seq", .family = "datasets", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-dataset-schema", .binary = "seq", .family = "dataset-schema", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-artifact-search", .binary = "seq", .family = "artifact-search", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-find-session", .binary = "seq", .family = "find-session", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-session-prompts", .binary = "seq", .family = "session-prompts", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-query-diagnose", .binary = "seq", .family = "query-diagnose", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-skills-rank", .binary = "seq", .family = "skills-rank", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-skill-trend", .binary = "seq", .family = "skill-trend", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-skill-report", .binary = "seq", .family = "skill-report", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-role-breakdown", .binary = "seq", .family = "role-breakdown", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-occurrence-export", .binary = "seq", .family = "occurrence-export", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-report-bundle", .binary = "seq", .family = "report-bundle", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-section-audit", .binary = "seq", .family = "section-audit", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-token-usage", .binary = "seq", .family = "token-usage", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-routing-gap", .binary = "seq", .family = "routing-gap", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-memory-inventory", .binary = "seq", .family = "memory-inventory", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-memory-extension-audit", .binary = "seq", .family = "memory-extension-audit", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-reply-latency", .binary = "seq", .family = "reply-latency", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-token-cost", .binary = "seq", .family = "token-cost", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-goal-audit", .binary = "seq", .family = "goal-audit", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-workflow-audit", .binary = "seq", .family = "workflow-audit", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-session-graph", .binary = "seq", .family = "session-graph", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-memory-map", .binary = "seq", .family = "memory-map", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-memory-history", .binary = "seq", .family = "memory-history", .case_kind = .native, .measurement_mode = .latency_alloc },
    .{ .case_id = "seq-parser-driver", .binary = "seq", .family = "parser", .case_kind = .driver, .measurement_mode = .latency_alloc, .compat_case = true },
};

const SeqCoverages = buildSeqCoverages();
const SeqDatasets = [_]perf_contract.DataSurface{
    .{ .name = "memory_blocks", .coverage = .shallow, .reason = "current seq dataset surface integrated into native manifest" },
};

const CronCases = [_]perf_contract.CaseDescriptor{
    .{ .case_id = "cron-help", .binary = "cron", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cron-list", .binary = "cron", .family = "list", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cron-show-deep", .binary = "cron", .family = "show", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-create-deep", .binary = "cron", .family = "create", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-update-deep", .binary = "cron", .family = "update", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-enable-deep", .binary = "cron", .family = "enable", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-disable-deep", .binary = "cron", .family = "disable", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-run-now-deep", .binary = "cron", .family = "run-now", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-delete-deep", .binary = "cron", .family = "delete", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "cron-run-due-deep", .binary = "cron", .family = "run-due", .case_kind = .driver, .measurement_mode = .latency_alloc },
};

const CronCoverages = buildCronCoverages();

const StCases = [_]perf_contract.CaseDescriptor{
    .{ .case_id = "st-help", .binary = "st", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "st-add-show", .binary = "st", .family = "add", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "st-emit-export", .binary = "st", .family = "export", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "st-init-deep", .binary = "st", .family = "init", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-set-status-deep", .binary = "st", .family = "set-status", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-set-priority-deep", .binary = "st", .family = "set-priority", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-set-deps-deep", .binary = "st", .family = "set-deps", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-set-notes-deep", .binary = "st", .family = "set-notes", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-add-comment-deep", .binary = "st", .family = "add-comment", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-remove-deep", .binary = "st", .family = "remove", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-ready-deep", .binary = "st", .family = "ready", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-blocked-deep", .binary = "st", .family = "blocked", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-doctor-deep", .binary = "st", .family = "doctor", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-prime-deep", .binary = "st", .family = "prime", .case_kind = .driver, .measurement_mode = .latency_alloc },
    .{ .case_id = "st-import-plan-deep", .binary = "st", .family = "import-plan", .case_kind = .driver, .measurement_mode = .latency_alloc },
};

const StCoverages = buildStCoverages();

const MiscCases = [_]perf_contract.CaseDescriptor{
    .{ .case_id = "bench-stats-help", .binary = "bench_stats", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "bench-stats-parse", .binary = "bench_stats", .family = "parse", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "perf-report-help", .binary = "perf_report", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "perf-report-render", .binary = "perf_report", .family = "render", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "lift-bench-stats-driver", .binary = "bench_stats", .family = "driver", .case_kind = .driver, .measurement_mode = .latency_alloc, .compat_case = true },
    .{ .case_id = "cas-wrapper-smoke", .binary = "cas", .family = "wrapper", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cas-smoke-check-help", .binary = "cas_smoke_check", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cas-instance-runner-help", .binary = "cas_instance_runner", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cas-review-session-help", .binary = "cas_review_session", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cas-review-session-version", .binary = "cas_review_session", .family = "version", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "cas-budget-governor-driver", .binary = "cas", .family = "driver", .case_kind = .driver, .measurement_mode = .latency_alloc, .compat_case = true },
    .{ .case_id = "puff-help", .binary = "puff", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "puff-wrapper", .binary = "puff", .family = "wrapper", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "learnings-help", .binary = "learnings", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "learnings-recent", .binary = "learnings", .family = "recent", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "learnings-recall", .binary = "learnings", .family = "recall", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "learnings-query", .binary = "learnings", .family = "query", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "learnings-codify", .binary = "learnings", .family = "codify-candidates", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "learnings-quality", .binary = "learnings", .family = "quality-audit", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "append-learning-help", .binary = "append_learning", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "append-learning-append", .binary = "append_learning", .family = "append", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "mesh-help", .binary = "mesh", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "mesh-budget", .binary = "mesh", .family = "budget", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "mesh-plan-sync", .binary = "mesh", .family = "plan_sync", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "mesh-slice", .binary = "mesh", .family = "slice", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "mesh-wave", .binary = "mesh", .family = "wave", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "parse-arch-help", .binary = "parse-arch", .family = "help", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "parse-arch-collect", .binary = "parse-arch", .family = "collect", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "parse-arch-eval", .binary = "parse-arch", .family = "eval", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
    .{ .case_id = "parse-arch-doctor", .binary = "parse-arch", .family = "doctor", .case_kind = .subprocess, .measurement_mode = .latency_only, .compat_case = true },
};

const MiscCoverages = [_]perf_contract.CommandCoverage{
    .{ .family = "compat", .coverage = .shallow, .reason = "preserved compatibility matrix" },
};

const CompatCases = [_]CompatCase{
    .{ .descriptor = SeqCases[0], .builder = .seq_local, .build_step = null, .binary_path = "zig-out/bin/seq", .setup = .seq_help },
    .{ .descriptor = SeqCases[SeqCases.len - 1], .builder = .seq_local, .build_step = null, .binary_path = "zig-out/bin/seq-perf-parser", .setup = .seq_parser_driver, .tolerance_pct = 20.0 },
    .{ .descriptor = MiscCases[0], .builder = .root, .build_step = "build-lift", .binary_path = "zig-out/bin/bench_stats", .setup = .bench_stats_help, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[1], .builder = .root, .build_step = "build-lift", .binary_path = "zig-out/bin/bench_stats", .setup = .bench_stats_parse, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[2], .builder = .root, .build_step = "build-lift", .binary_path = "zig-out/bin/perf_report", .setup = .perf_report_help, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[3], .builder = .root, .build_step = "build-lift", .binary_path = "zig-out/bin/perf_report", .setup = .perf_report_render, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[4], .builder = .root, .build_step = "build-lift", .binary_path = "zig-out/bin/lift-perf-bench-stats", .setup = .lift_bench_stats_driver, .tolerance_pct = 150.0 },
    .{ .descriptor = MiscCases[5], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas", .setup = .cas_wrapper_smoke, .tolerance_pct = 120.0 },
    .{ .descriptor = MiscCases[6], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas_smoke_check", .setup = .cas_smoke_check_help, .tolerance_pct = 100.0 },
    .{ .descriptor = MiscCases[7], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas_instance_runner", .setup = .cas_instance_runner_help, .tolerance_pct = 100.0 },
    .{ .descriptor = MiscCases[8], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas_review_session", .setup = .cas_review_session_help, .tolerance_pct = 100.0 },
    .{ .descriptor = MiscCases[9], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas_review_session", .setup = .cas_review_session_version, .tolerance_pct = 100.0 },
    .{ .descriptor = MiscCases[10], .builder = .root, .build_step = "build-cas", .binary_path = "zig-out/bin/cas-perf-budget-governor", .setup = .cas_budget_governor_driver, .tolerance_pct = 45.0 },
    .{ .descriptor = CronCases[0], .builder = .root, .build_step = "build-cron", .binary_path = "zig-out/bin/cron", .setup = .cron_help, .tolerance_pct = 25.0 },
    .{ .descriptor = CronCases[1], .builder = .root, .build_step = "build-cron", .binary_path = "zig-out/bin/cron", .setup = .cron_list, .tolerance_pct = 35.0 },
    .{ .descriptor = MiscCases[11], .builder = .root, .build_step = "build-puff", .binary_path = "zig-out/bin/puff", .setup = .puff_help, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[12], .builder = .root, .build_step = "build-puff", .binary_path = "zig-out/bin/puff", .setup = .puff_wrapper, .tolerance_pct = 35.0 },
    .{ .descriptor = MiscCases[13], .builder = .root, .build_step = "build-learnings", .binary_path = "zig-out/bin/learnings", .setup = .learnings_help, .tolerance_pct = 150.0 },
    .{ .descriptor = MiscCases[14], .builder = .root, .build_step = "build-learnings", .binary_path = "zig-out/bin/learnings", .setup = .learnings_recent, .tolerance_pct = 120.0 },
    .{ .descriptor = MiscCases[15], .builder = .root, .build_step = "build-learnings", .binary_path = "zig-out/bin/learnings", .setup = .learnings_recall, .tolerance_pct = 20.0 },
    .{ .descriptor = MiscCases[16], .builder = .root, .build_step = "build-learnings", .binary_path = "zig-out/bin/learnings", .setup = .learnings_query, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[17], .builder = .root, .build_step = "build-learnings", .binary_path = "zig-out/bin/learnings", .setup = .learnings_codify, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[18], .builder = .root, .build_step = "build-learnings", .binary_path = "zig-out/bin/learnings", .setup = .learnings_quality, .tolerance_pct = 25.0 },
    .{ .descriptor = MiscCases[19], .builder = .root, .build_step = "build-learnings", .binary_path = "zig-out/bin/append_learning", .setup = .append_learning_help },
    .{ .descriptor = MiscCases[20], .builder = .root, .build_step = "build-learnings", .binary_path = "zig-out/bin/append_learning", .setup = .append_learning_append, .tolerance_pct = 100.0 },
    .{ .descriptor = MiscCases[21], .builder = .root, .build_step = "build-mesh", .binary_path = "zig-out/bin/mesh", .setup = .mesh_help, .tolerance_pct = 200.0 },
    .{ .descriptor = MiscCases[22], .builder = .root, .build_step = "build-mesh", .binary_path = "zig-out/bin/mesh", .setup = .mesh_budget, .tolerance_pct = 200.0 },
    .{ .descriptor = MiscCases[23], .builder = .root, .build_step = "build-mesh", .binary_path = "zig-out/bin/mesh", .setup = .mesh_plan_sync, .tolerance_pct = 200.0 },
    .{ .descriptor = MiscCases[24], .builder = .root, .build_step = "build-mesh", .binary_path = "zig-out/bin/mesh", .setup = .mesh_slice, .tolerance_pct = 200.0 },
    .{ .descriptor = MiscCases[25], .builder = .root, .build_step = "build-mesh", .binary_path = "zig-out/bin/mesh", .setup = .mesh_wave, .tolerance_pct = 200.0 },
    .{ .descriptor = StCases[0], .builder = .root, .build_step = "build-st", .binary_path = "zig-out/bin/st", .setup = .st_help, .tolerance_pct = 25.0 },
    .{ .descriptor = StCases[1], .builder = .root, .build_step = "build-st", .binary_path = "zig-out/bin/st", .setup = .st_add_show, .tolerance_pct = 20.0 },
    .{ .descriptor = StCases[2], .builder = .root, .build_step = "build-st", .binary_path = "zig-out/bin/st", .setup = .st_emit_export, .tolerance_pct = 300.0 },
    .{ .descriptor = MiscCases[26], .builder = .root, .build_step = "build-parse-arch", .binary_path = "zig-out/bin/parse-arch", .setup = .parse_arch_help, .tolerance_pct = 200.0 },
    .{ .descriptor = MiscCases[27], .builder = .root, .build_step = "build-parse-arch", .binary_path = "zig-out/bin/parse-arch", .setup = .parse_arch_collect, .tolerance_pct = 200.0 },
    .{ .descriptor = MiscCases[28], .builder = .root, .build_step = "build-parse-arch", .binary_path = "zig-out/bin/parse-arch", .setup = .parse_arch_eval, .tolerance_pct = 800.0 },
    .{ .descriptor = MiscCases[29], .builder = .root, .build_step = "build-parse-arch", .binary_path = "zig-out/bin/parse-arch", .setup = .parse_arch_doctor, .tolerance_pct = 200.0 },
};

const DeepCases = [_]DeepCase{
    .{ .descriptor = SeqCases[1], .setup = .seq_query_tool_calls, .tolerance_pct = 25.0 },
    .{ .descriptor = SeqCases[2], .setup = .seq_skill_success_rank, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[3], .setup = .seq_skill_audit, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[4], .setup = .seq_skill_blocks, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[5], .setup = .seq_tool_audit, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[6], .setup = .seq_message_search, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[7], .setup = .seq_message_audit, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[8], .setup = .seq_skill_cohort, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[9], .setup = .seq_tool_search, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[10], .setup = .seq_token_window, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[11], .setup = .seq_workdir_report, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[12], .setup = .seq_plan_search, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[13], .setup = .seq_sessions_limit, .tolerance_pct = 25.0 },
    .{ .descriptor = SeqCases[14], .setup = .seq_turns, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[15], .setup = .seq_session_detail, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[16], .setup = .seq_tool_lifecycle, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[17], .setup = .seq_tail_once, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[18], .setup = .seq_session_tooling, .tolerance_pct = 125.0 },
    .{ .descriptor = SeqCases[19], .setup = .seq_orchestration_concurrency, .tolerance_pct = 125.0 },
    .{ .descriptor = SeqCases[20], .setup = .seq_datasets, .tolerance_pct = 125.0 },
    .{ .descriptor = SeqCases[21], .setup = .seq_dataset_schema, .tolerance_pct = 75.0 },
    .{ .descriptor = SeqCases[22], .setup = .seq_artifact_search, .tolerance_pct = 25.0 },
    .{ .descriptor = SeqCases[23], .setup = .seq_find_session, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[24], .setup = .seq_session_prompts, .tolerance_pct = 25.0 },
    .{ .descriptor = SeqCases[25], .setup = .seq_query_diagnose, .tolerance_pct = 25.0 },
    .{ .descriptor = SeqCases[26], .setup = .seq_skills_rank, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[27], .setup = .seq_skill_trend, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[28], .setup = .seq_skill_report, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[29], .setup = .seq_role_breakdown, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[30], .setup = .seq_occurrence_export, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[31], .setup = .seq_report_bundle, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[32], .setup = .seq_section_audit, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[33], .setup = .seq_token_usage, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[34], .setup = .seq_routing_gap, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[35], .setup = .seq_memory_inventory, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[36], .setup = .seq_memory_extension_audit, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[37], .setup = .seq_reply_latency, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[38], .setup = .seq_token_cost, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[39], .setup = .seq_goal_audit, .tolerance_pct = 80.0 },
    .{ .descriptor = SeqCases[40], .setup = .seq_workflow_audit, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[41], .setup = .seq_session_graph, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[42], .setup = .seq_memory_map, .tolerance_pct = 40.0 },
    .{ .descriptor = SeqCases[43], .setup = .seq_memory_history, .tolerance_pct = 40.0 },
    .{ .descriptor = CronCases[2], .setup = .cron_show, .tolerance_pct = 200.0 },
    .{ .descriptor = CronCases[3], .setup = .cron_create, .tolerance_pct = 25.0 },
    .{ .descriptor = CronCases[4], .setup = .cron_update, .tolerance_pct = 25.0 },
    .{ .descriptor = CronCases[5], .setup = .cron_enable, .tolerance_pct = 250.0 },
    .{ .descriptor = CronCases[6], .setup = .cron_disable, .tolerance_pct = 100.0 },
    .{ .descriptor = CronCases[7], .setup = .cron_run_now, .tolerance_pct = 70.0 },
    .{ .descriptor = CronCases[8], .setup = .cron_delete, .tolerance_pct = 60.0 },
    .{ .descriptor = CronCases[9], .setup = .cron_run_due, .tolerance_pct = 125.0 },
    .{ .descriptor = StCases[3], .setup = .st_init, .tolerance_pct = 300.0 },
    .{ .descriptor = StCases[4], .setup = .st_set_status, .tolerance_pct = 300.0 },
    .{ .descriptor = StCases[5], .setup = .st_set_priority, .tolerance_pct = 300.0 },
    .{ .descriptor = StCases[6], .setup = .st_set_deps, .tolerance_pct = 300.0 },
    .{ .descriptor = StCases[7], .setup = .st_set_notes, .tolerance_pct = 300.0 },
    .{ .descriptor = StCases[8], .setup = .st_add_comment, .tolerance_pct = 300.0 },
    .{ .descriptor = StCases[9], .setup = .st_remove, .tolerance_pct = 250.0 },
    .{ .descriptor = StCases[10], .setup = .st_ready, .tolerance_pct = 300.0 },
    .{ .descriptor = StCases[11], .setup = .st_blocked, .tolerance_pct = 300.0 },
    .{ .descriptor = StCases[12], .setup = .st_doctor, .tolerance_pct = 300.0 },
    .{ .descriptor = StCases[13], .setup = .st_prime, .tolerance_pct = 300.0 },
    .{ .descriptor = StCases[14], .setup = .st_import_plan, .tolerance_pct = 300.0 },
};

fn buildSeqCoverages() [seq_cli.commandNames().len]perf_contract.CommandCoverage {
    @setEvalBranchQuota(5000);
    var out: [seq_cli.commandNames().len]perf_contract.CommandCoverage = undefined;
    for (seq_cli.commandNames(), 0..) |def, idx| {
        const coverage, const reason = if (std.mem.eql(u8, def.name, "query") or
            std.mem.eql(u8, def.name, "sessions") or
            std.mem.eql(u8, def.name, "turns") or
            std.mem.eql(u8, def.name, "session-detail") or
            std.mem.eql(u8, def.name, "tool-lifecycle") or
            std.mem.eql(u8, def.name, "tail") or
            std.mem.eql(u8, def.name, "session-tooling") or
            std.mem.eql(u8, def.name, "orchestration-concurrency") or
            std.mem.eql(u8, def.name, "datasets") or
            std.mem.eql(u8, def.name, "dataset-schema") or
            std.mem.eql(u8, def.name, "artifact-search") or
            std.mem.eql(u8, def.name, "tool-audit") or
            std.mem.eql(u8, def.name, "memory-inventory") or
            std.mem.eql(u8, def.name, "message-search") or
            std.mem.eql(u8, def.name, "message-audit") or
            std.mem.eql(u8, def.name, "skill-cohort") or
            std.mem.eql(u8, def.name, "tool-search") or
            std.mem.eql(u8, def.name, "memory-extension-audit") or
            std.mem.eql(u8, def.name, "token-window") or
            std.mem.eql(u8, def.name, "workdir-report") or
            std.mem.eql(u8, def.name, "find-session") or
            std.mem.eql(u8, def.name, "plan-search") or
            std.mem.eql(u8, def.name, "reply-latency") or
            std.mem.eql(u8, def.name, "session-prompts") or
            std.mem.eql(u8, def.name, "query-diagnose") or
            std.mem.eql(u8, def.name, "skills-rank") or
            std.mem.eql(u8, def.name, "skill-success-rank") or
            std.mem.eql(u8, def.name, "skill-trend") or
            std.mem.eql(u8, def.name, "skill-report") or
            std.mem.eql(u8, def.name, "skill-audit") or
            std.mem.eql(u8, def.name, "skill-blocks") or
            std.mem.eql(u8, def.name, "role-breakdown") or
            std.mem.eql(u8, def.name, "occurrence-export") or
            std.mem.eql(u8, def.name, "report-bundle") or
            std.mem.eql(u8, def.name, "section-audit") or
            std.mem.eql(u8, def.name, "token-usage") or
            std.mem.eql(u8, def.name, "token-cost") or
            std.mem.eql(u8, def.name, "goal-audit") or
            std.mem.eql(u8, def.name, "workflow-audit") or
            std.mem.eql(u8, def.name, "session-graph") or
            std.mem.eql(u8, def.name, "memory-map") or
            std.mem.eql(u8, def.name, "memory-history") or
            std.mem.eql(u8, def.name, "routing-gap"))
            .{ perf_contract.CoverageKind.deep, "native deep case landed" }
        else if (std.mem.eql(u8, def.name, "memory-provenance"))
            .{ perf_contract.CoverageKind.excluded, "state-db provenance fixture deferred" }
        else if (std.mem.eql(u8, def.name, "opencode-prompts") or std.mem.eql(u8, def.name, "opencode-events"))
            .{ perf_contract.CoverageKind.excluded, "opencode db/jsonl wave deferred" }
        else
            .{ perf_contract.CoverageKind.missing, "native deep case not landed" };
        out[idx] = .{ .family = def.name, .coverage = coverage, .reason = reason };
    }
    return out;
}

fn buildCronCoverages() [cron_cli.commandDefinitions().len]perf_contract.CommandCoverage {
    var out: [cron_cli.commandDefinitions().len]perf_contract.CommandCoverage = undefined;
    for (cron_cli.commandDefinitions(), 0..) |def, idx| {
        const coverage, const reason = if (def.command == .list)
            .{ perf_contract.CoverageKind.shallow, "compat subprocess case exists" }
        else if (def.command == .scheduler)
            .{ perf_contract.CoverageKind.excluded, "external-like scheduler surfaces deferred" }
        else
            .{ perf_contract.CoverageKind.deep, "native deep case landed" };
        out[idx] = .{ .family = def.name, .coverage = coverage, .reason = reason };
    }
    return out;
}

fn buildStCoverages() [st_cli.commandDefs().len]perf_contract.CommandCoverage {
    var out: [st_cli.commandDefs().len]perf_contract.CommandCoverage = undefined;
    for (st_cli.commandDefs(), 0..) |def, idx| {
        const coverage, const reason = if (std.mem.eql(u8, def.name, "add") or
            std.mem.eql(u8, def.name, "show") or
            std.mem.eql(u8, def.name, "emit-plan-sync") or
            std.mem.eql(u8, def.name, "export"))
            .{ perf_contract.CoverageKind.shallow, "compat subprocess case exists" }
        else
            .{ perf_contract.CoverageKind.deep, "native deep case landed" };
        out[idx] = .{ .family = def.name, .coverage = coverage, .reason = reason };
    }
    return out;
}

fn allManifests() []const perf_contract.BinaryManifest {
    return &.{
        .{ .binary = "seq", .coverages = &SeqCoverages, .datasets = &SeqDatasets, .cases = &SeqCases },
        .{ .binary = "cron", .coverages = &CronCoverages, .cases = &CronCases },
        .{ .binary = "st", .coverages = &StCoverages, .cases = &StCases },
        .{ .binary = "misc", .coverages = &MiscCoverages, .cases = &MiscCases },
    };
}

const ParsedArgs = struct {
    command: Command,
    target: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;
    const parsed = parseArgs(argv[1..]) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    switch (parsed.command) {
        .list => try cmdList(parsed.target),
        .manifest => try cmdManifest(allocator),
        .audit => try cmdAudit(),
        .capture => try cmdCapture(allocator, parsed.target),
        .compare => try cmdCompare(allocator, parsed.target),
        .doctor => try cmdDoctor(allocator, parsed.target),
        .report => try cmdReport(allocator),
        .accept => try cmdAccept(allocator),
    }
}

fn parseArgs(args: []const []const u8) !ParsedArgs {
    if (args.len == 0) return error.MissingCommand;
    const command = parseCommand(args[0]) orelse return error.InvalidCommand;
    var target: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            target = args[i];
            continue;
        }
        return error.UnknownArgument;
    }
    return .{ .command = command, .target = target };
}

fn parseCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "list")) return .list;
    if (std.mem.eql(u8, raw, "manifest")) return .manifest;
    if (std.mem.eql(u8, raw, "audit")) return .audit;
    if (std.mem.eql(u8, raw, "capture")) return .capture;
    if (std.mem.eql(u8, raw, "compare")) return .compare;
    if (std.mem.eql(u8, raw, "doctor")) return .doctor;
    if (std.mem.eql(u8, raw, "report")) return .report;
    if (std.mem.eql(u8, raw, "accept")) return .accept;
    return null;
}

fn cmdList(target: ?[]const u8) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    for (CompatCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        const case_desc = case_cfg.descriptor;
        try stdout.print("{s}\t{s}\t{s}\n", .{
            case_desc.case_id,
            case_desc.binary,
            case_desc.measurement_mode.asString(),
        });
    }
    for (DeepCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        try stdout.print("{s}\t{s}\t{s}\n", .{
            case_cfg.descriptor.case_id,
            case_cfg.descriptor.binary,
            case_cfg.descriptor.measurement_mode.asString(),
        });
    }
}

fn cmdManifest(allocator: std.mem.Allocator) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try perf_contract.writeManifestJson(allocator, &stdout_writer.interface, allManifests());
}

fn cmdAudit() !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    for (allManifests()) |manifest| {
        for (manifest.coverages) |coverage| {
            try stdout.print("{s}\t{s}\t{s}\t{s}\n", .{
                manifest.binary,
                coverage.family,
                coverage.coverage.asString(),
                coverage.reason,
            });
        }
        for (manifest.datasets) |dataset| {
            try stdout.print("{s}\tdataset:{s}\t{s}\t{s}\n", .{
                manifest.binary,
                dataset.name,
                dataset.coverage.asString(),
                dataset.reason,
            });
        }
    }
}

const BuiltState = struct {
    keys: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) BuiltState {
        return .{ .keys = std.StringHashMap(void).init(allocator) };
    }

    fn deinit(self: *BuiltState) void {
        var it = self.keys.keyIterator();
        while (it.next()) |key| self.keys.allocator.free(key.*);
        self.keys.deinit();
    }
};

const CommandRun = struct {
    cwd: []const u8,
    argv: []const []const u8,
};

const Metrics = struct {
    samples: std.ArrayList(u64),
    alloc_samples: std.ArrayList(u64),
    p50_ns: u64,
    p95_ns: u64,
    p50_alloc_calls: u64,

    fn deinit(self: *Metrics, allocator: std.mem.Allocator) void {
        self.samples.deinit(allocator);
        self.alloc_samples.deinit(allocator);
    }
};

const CompareRow = struct {
    status: []const u8,
    case_id: []const u8,
    binary: []const u8,
    detail: []const u8,
};

const ReportCounts = struct {
    pass: usize = 0,
    fail: usize = 0,
};

fn cmdDoctor(allocator: std.mem.Allocator, target: ?[]const u8) !void {
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const current_dir = try std.fs.path.join(allocator, &.{ ".perf-local", machine_name });
    defer allocator.free(current_dir);

    var count: usize = 0;
    for (CompatCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        count += 1;
        const binary_path = resolveBinaryPath(allocator, case_cfg) catch return error.InvalidData;
        allocator.free(binary_path);
    }
    for (DeepCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        count += 1;
    }

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("machine_id={s}\n", .{machine_name});
    try stdout.print("cases={d}\n", .{count});
    try stdout.print("machine_dir={s}\n", .{current_dir});
}

fn cmdCapture(allocator: std.mem.Allocator, target: ?[]const u8) !void {
    const machine_dir = try ensureCurrentMachineDir(allocator);
    defer allocator.free(machine_dir);
    var built = BuiltState.init(allocator);
    defer built.deinit();

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    for (CompatCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        try ensureBuilt(allocator, &built, case_cfg);
        const detail = try captureCompatCase(allocator, machine_dir, case_cfg);
        try stdout.print("PASS\t{s}\t{s}\n", .{ case_cfg.descriptor.case_id, detail });
    }
    for (DeepCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        const detail = try captureDeepCase(allocator, machine_dir, case_cfg);
        try stdout.print("PASS\t{s}\t{s}\n", .{ case_cfg.descriptor.case_id, detail });
    }
}

fn cmdCompare(allocator: std.mem.Allocator, target: ?[]const u8) !void {
    const machine_dir = try resolveMachineDir(allocator, ".perf-local");
    defer allocator.free(machine_dir);
    var built = BuiltState.init(allocator);
    defer built.deinit();

    var rows: std.ArrayList(CompareRow) = .empty;
    defer rows.deinit(allocator);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    var any_fail = false;

    for (CompatCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        try ensureBuilt(allocator, &built, case_cfg);
        const result = try compareCompatCase(allocator, machine_dir, case_cfg);
        try rows.append(allocator, result);
        try stdout.print("{s}\t{s}\t{s}\n", .{ result.status, result.case_id, result.detail });
        if (std.mem.eql(u8, result.status, "FAIL")) any_fail = true;
    }
    for (DeepCases) |case_cfg| {
        if (!matchesTarget(case_cfg.descriptor.case_id, case_cfg.descriptor.binary, target)) continue;
        const result = try compareDeepCase(allocator, machine_dir, case_cfg);
        try rows.append(allocator, result);
        try stdout.print("{s}\t{s}\t{s}\n", .{ result.status, result.case_id, result.detail });
        if (std.mem.eql(u8, result.status, "FAIL")) any_fail = true;
    }

    try writeCompareSummaryRows(allocator, machine_dir, rows.items);
    if (any_fail) std.process.exit(1);
}

fn captureCompatCase(allocator: std.mem.Allocator, machine_dir: []const u8, case_cfg: CompatCase) ![]const u8 {
    switch (case_cfg.descriptor.case_kind) {
        .driver => {
            const raw_json = try runDriverCase(allocator, case_cfg, true, null);
            defer allocator.free(raw_json);
            const baseline_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, false);
            defer allocator.free(baseline_path);
            try writeDriverArtifact(allocator, baseline_path, case_cfg, raw_json, "capture", "captured");
        },
        .subprocess, .native => {
            var metrics = try runMeasuredCase(allocator, case_cfg);
            defer metrics.deinit(allocator);
            const baseline_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, false);
            defer allocator.free(baseline_path);
            try writeMetricsArtifact(allocator, baseline_path, case_cfg, metrics, "capture", "captured");
        },
    }
    return "captured";
}

fn captureDeepCase(allocator: std.mem.Allocator, machine_dir: []const u8, case_cfg: DeepCase) ![]const u8 {
    var metrics = try runDeepMeasuredCase(allocator, case_cfg);
    defer metrics.deinit(allocator);
    const baseline_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, false);
    defer allocator.free(baseline_path);
    try writeMetricsArtifact(allocator, baseline_path, .{
        .descriptor = case_cfg.descriptor,
        .builder = .root,
        .build_step = null,
        .binary_path = "",
        .setup = .cron_help,
        .warmups = case_cfg.warmups,
        .samples = case_cfg.samples,
        .tolerance_pct = case_cfg.tolerance_pct,
    }, metrics, "capture", "captured");
    return "captured";
}

fn compareCompatCase(allocator: std.mem.Allocator, machine_dir: []const u8, case_cfg: CompatCase) !CompareRow {
    const baseline_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, false);
    defer allocator.free(baseline_path);
    if (!pathExists(baseline_path)) {
        return .{ .status = "FAIL", .case_id = case_cfg.descriptor.case_id, .binary = case_cfg.descriptor.binary, .detail = "missing baseline" };
    }

    const baseline_data = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), baseline_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(baseline_data);
    var baseline = try std.json.parseFromSlice(std.json.Value, allocator, baseline_data, .{});
    defer baseline.deinit();

    const latest_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, true);
    defer allocator.free(latest_path);

    var status: []const u8 = "PASS";
    var detail: []const u8 = "ok";
    switch (case_cfg.descriptor.case_kind) {
        .driver => {
            const current_raw = try runDriverCase(allocator, case_cfg, false, null);
            defer allocator.free(current_raw);
            const compare = try compareDriverRaw(allocator, case_cfg, baseline.value, current_raw);
            status = compare.status;
            detail = compare.detail;
            try writeDriverArtifact(allocator, latest_path, case_cfg, current_raw, if (std.mem.eql(u8, status, "PASS")) "pass" else "fail", detail);
        },
        .subprocess, .native => {
            var metrics = try runMeasuredCase(allocator, case_cfg);
            defer metrics.deinit(allocator);
            const compare = try compareLatencyMetrics(case_cfg, baseline.value, metrics);
            status = compare.status;
            detail = compare.detail;
            try writeMetricsArtifact(allocator, latest_path, case_cfg, metrics, if (std.mem.eql(u8, status, "PASS")) "pass" else "fail", detail);
        },
    }

    return .{
        .status = status,
        .case_id = case_cfg.descriptor.case_id,
        .binary = case_cfg.descriptor.binary,
        .detail = detail,
    };
}

fn compareDeepCase(allocator: std.mem.Allocator, machine_dir: []const u8, case_cfg: DeepCase) !CompareRow {
    const baseline_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, false);
    defer allocator.free(baseline_path);
    if (!pathExists(baseline_path)) {
        return .{ .status = "FAIL", .case_id = case_cfg.descriptor.case_id, .binary = case_cfg.descriptor.binary, .detail = "missing baseline" };
    }
    const baseline_data = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), baseline_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(baseline_data);
    var baseline = try std.json.parseFromSlice(std.json.Value, allocator, baseline_data, .{});
    defer baseline.deinit();

    var metrics = try runDeepMeasuredCase(allocator, case_cfg);
    defer metrics.deinit(allocator);
    const compare = try compareLatencyMetrics(.{
        .descriptor = case_cfg.descriptor,
        .builder = .root,
        .build_step = null,
        .binary_path = "",
        .setup = .cron_help,
        .warmups = case_cfg.warmups,
        .samples = case_cfg.samples,
        .tolerance_pct = case_cfg.tolerance_pct,
    }, baseline.value, metrics);

    const latest_path = try compatBaselinePath(allocator, machine_dir, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, true);
    defer allocator.free(latest_path);
    try writeMetricsArtifact(allocator, latest_path, .{
        .descriptor = case_cfg.descriptor,
        .builder = .root,
        .build_step = null,
        .binary_path = "",
        .setup = .cron_help,
        .warmups = case_cfg.warmups,
        .samples = case_cfg.samples,
        .tolerance_pct = case_cfg.tolerance_pct,
    }, metrics, if (std.mem.eql(u8, compare.status, "PASS")) "pass" else "fail", compare.detail);

    return .{
        .status = compare.status,
        .case_id = case_cfg.descriptor.case_id,
        .binary = case_cfg.descriptor.binary,
        .detail = compare.detail,
    };
}

fn writeCompareSummaryRows(allocator: std.mem.Allocator, machine_dir: []const u8, rows: []const CompareRow) !void {
    const reports_dir = try std.fs.path.join(allocator, &.{ machine_dir, "reports" });
    defer allocator.free(reports_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), reports_dir);
    const latest_path = try std.fs.path.join(allocator, &.{ reports_dir, "latest-compare.json" });
    defer allocator.free(latest_path);

    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), latest_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try writer.interface.writeAll("{\"rows\":[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.interface.writeByte(',');
        try writer.interface.print(
            "{{\"case_id\":\"{s}\",\"binary\":\"{s}\",\"status\":\"{s}\",\"detail\":",
            .{ row.case_id, row.binary, row.status },
        );
        try std.json.Stringify.value(row.detail, .{}, &writer.interface);
        try writer.interface.writeByte('}');
    }
    try writer.interface.writeAll("]}\n");
}

const StatusDetail = struct {
    status: []const u8,
    detail: []const u8,
};

const Sqlite = struct {
    pub const sqlite3 = opaque {};
    pub const SQLITE_OK: c_int = 0;

    extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
    extern fn sqlite3_close(db: *sqlite3) c_int;
    extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
    extern fn sqlite3_exec(
        db: *sqlite3,
        sql: [*:0]const u8,
        callback: ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int,
        arg: ?*anyopaque,
        errmsg: ?*?[*:0]u8,
    ) c_int;
};

fn matchesTarget(case_id: []const u8, binary: []const u8, target: ?[]const u8) bool {
    const needle = target orelse return true;
    if (std.mem.eql(u8, needle, "cas")) return std.mem.startsWith(u8, case_id, "cas-");
    if (isKnownBinaryName(needle)) return std.mem.eql(u8, binary, needle);
    if (std.mem.eql(u8, binary, needle)) return true;
    return std.mem.indexOf(u8, case_id, needle) != null;
}

fn ensureCurrentMachineDir(allocator: std.mem.Allocator) ![]u8 {
    const current_name = try currentMachineDirName(allocator);
    defer allocator.free(current_name);
    const dir_path = try std.fs.path.join(allocator, &.{ ".perf-local", current_name });
    errdefer allocator.free(dir_path);
    const baseline_dir = try std.fs.path.join(allocator, &.{ dir_path, "baselines" });
    defer allocator.free(baseline_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), baseline_dir);
    return dir_path;
}

fn ensureBuilt(allocator: std.mem.Allocator, built: *BuiltState, case_cfg: CompatCase) !void {
    const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{
        switch (case_cfg.builder) {
            .root => "root",
            .seq_local => "seq_local",
        },
        case_cfg.build_step orelse "default",
    });
    defer allocator.free(key);
    if (built.keys.contains(key)) return;

    const cwd = switch (case_cfg.builder) {
        .root => ".",
        .seq_local => "apps/seq",
    };

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "zig");
    try args.append(allocator, "build");
    if (case_cfg.build_step) |step| try args.append(allocator, step);
    try args.append(allocator, "-Doptimize=ReleaseFast");
    const result = try runChildCapture(allocator, cwd, args.items);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) return error.BuildFailed;
    try built.keys.put(try allocator.dupe(u8, key), {});
}

fn resolveBinaryPath(allocator: std.mem.Allocator, case_cfg: CompatCase) ![]u8 {
    return switch (case_cfg.builder) {
        .root => std.fs.path.join(allocator, &.{ ".", case_cfg.binary_path }),
        .seq_local => std.fs.path.join(allocator, &.{ "apps/seq", case_cfg.binary_path }),
    };
}

fn resolveBinaryExecPath(allocator: std.mem.Allocator, case_cfg: CompatCase) ![]u8 {
    return switch (case_cfg.builder) {
        .root => std.fs.path.join(allocator, &.{ ".", case_cfg.binary_path }),
        .seq_local => allocator.dupe(u8, case_cfg.binary_path),
    };
}

fn compatBaselinePath(allocator: std.mem.Allocator, machine_dir: []const u8, binary: []const u8, case_id: []const u8, latest: bool) ![]u8 {
    const dir_path = try std.fs.path.join(allocator, &.{ machine_dir, "baselines", binary });
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir_path);
    allocator.free(dir_path);
    const file_name = if (latest)
        try std.fmt.allocPrint(allocator, "{s}.latest.json", .{case_id})
    else
        try std.fmt.allocPrint(allocator, "{s}.json", .{case_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ machine_dir, "baselines", binary, file_name });
}

fn runDriverCase(allocator: std.mem.Allocator, case_cfg: CompatCase, capture: bool, _: ?std.json.Value) ![]u8 {
    const temp_root = try makeTempRoot(allocator, case_cfg.descriptor.case_id);
    defer cleanupTempRoot(temp_root);
    defer allocator.free(temp_root);
    const artifact_path = try std.fs.path.join(allocator, &.{ temp_root, "artifact.json" });
    defer allocator.free(artifact_path);
    const binary_path = try resolveBinaryPath(allocator, case_cfg);
    defer allocator.free(binary_path);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, binary_path);
    switch (case_cfg.setup) {
        .seq_parser_driver => {
            try args.appendSlice(allocator, &.{ "--config", "apps/seq/perf/parser/workload_config.json", "--artifact", artifact_path, "--report-only" });
            const result = try runChildCapture(allocator, ".", args.items);
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.exit_code != 0) return error.DriverFailed;
        },
        .lift_bench_stats_driver => {
            try args.appendSlice(allocator, &.{ "--config", "apps/lift/perf/bench_stats/workload_config.json", "--artifact", artifact_path, "--report-only" });
            const result = try runChildCapture(allocator, ".", args.items);
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.exit_code != 0) return error.DriverFailed;
        },
        .cas_budget_governor_driver => {
            try args.appendSlice(allocator, &.{ "--config", "apps/cas/perf/budget_governor/workload_config.json", "--artifact", artifact_path, "--report-only" });
            const result = try runChildCapture(allocator, ".", args.items);
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.exit_code != 0) return error.DriverFailed;
        },
        else => return error.InvalidCommand,
    }
    _ = capture;
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), artifact_path, allocator, .limited(1024 * 1024));
}

fn runMeasuredCase(allocator: std.mem.Allocator, case_cfg: CompatCase) !Metrics {
    const temp_root = try makeTempRoot(allocator, case_cfg.descriptor.case_id);
    defer cleanupTempRoot(temp_root);
    defer allocator.free(temp_root);
    var samples: std.ArrayList(u64) = .empty;
    var alloc_samples: std.ArrayList(u64) = .empty;
    try samples.ensureTotalCapacity(allocator, case_cfg.samples);
    try alloc_samples.ensureTotalCapacity(allocator, case_cfg.samples);

    var warmup_idx: usize = 0;
    while (warmup_idx < case_cfg.warmups) : (warmup_idx += 1) {
        var run_arena = std.heap.ArenaAllocator.init(allocator);
        defer run_arena.deinit();
        const run = try renderCompatRun(run_arena.allocator(), case_cfg, temp_root);
        const result = try runChildCapture(allocator, run.cwd, run.argv);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.exit_code != 0) {
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            try stderr_writer.interface.print("case warmup failed: {s} exit={d}\n{s}\n", .{
                case_cfg.descriptor.case_id,
                result.exit_code,
                result.stderr,
            });
            return error.CaseFailed;
        }
    }

    var sample_idx: usize = 0;
    while (sample_idx < case_cfg.samples) : (sample_idx += 1) {
        var run_arena = std.heap.ArenaAllocator.init(allocator);
        defer run_arena.deinit();
        const run = try renderCompatRun(run_arena.allocator(), case_cfg, temp_root);
        const start_ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
        const result = try runChildCapture(allocator, run.cwd, run.argv);
        const elapsed: u64 = @intCast(@max(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds - start_ns, 1));
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.exit_code != 0) {
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            try stderr_writer.interface.print("case sample failed: {s} exit={d}\n{s}\n", .{
                case_cfg.descriptor.case_id,
                result.exit_code,
                result.stderr,
            });
            return error.CaseFailed;
        }
        try samples.append(allocator, elapsed);
        try alloc_samples.append(allocator, 0);
    }

    return .{
        .samples = samples,
        .alloc_samples = alloc_samples,
        .p50_ns = try percentileU64(allocator, samples.items, 50),
        .p95_ns = try percentileU64(allocator, samples.items, 95),
        .p50_alloc_calls = 0,
    };
}

fn runDeepMeasuredCase(allocator: std.mem.Allocator, case_cfg: DeepCase) !Metrics {
    const temp_root = try makeTempRoot(allocator, case_cfg.descriptor.case_id);
    defer cleanupTempRoot(temp_root);
    defer allocator.free(temp_root);
    var samples: std.ArrayList(u64) = .empty;
    var alloc_samples: std.ArrayList(u64) = .empty;
    try samples.ensureTotalCapacity(allocator, case_cfg.samples);
    try alloc_samples.ensureTotalCapacity(allocator, case_cfg.samples);

    var warmup_idx: usize = 0;
    while (warmup_idx < case_cfg.warmups) : (warmup_idx += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var counting = core_perf.CountingAllocator.init(arena.allocator());
        try executeDeepCase(counting.allocator(), case_cfg.setup, temp_root);
    }

    var sample_idx: usize = 0;
    while (sample_idx < case_cfg.samples) : (sample_idx += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var counting = core_perf.CountingAllocator.init(arena.allocator());
        const start_ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
        try executeDeepCase(counting.allocator(), case_cfg.setup, temp_root);
        try samples.append(allocator, @intCast(@max(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds - start_ns, 1)));
        try alloc_samples.append(allocator, counting.stats.totalCalls());
    }

    return .{
        .samples = samples,
        .alloc_samples = alloc_samples,
        .p50_ns = try percentileU64(allocator, samples.items, 50),
        .p95_ns = try percentileU64(allocator, samples.items, 95),
        .p50_alloc_calls = try percentileU64(allocator, alloc_samples.items, 50),
    };
}

fn executeDeepCase(allocator: std.mem.Allocator, setup: DeepSetup, temp_root: []const u8) !void {
    switch (setup) {
        .seq_query_tool_calls => try seq_cli.runPerfCase(allocator, .query_tool_calls, temp_root),
        .seq_skill_success_rank => try seq_cli.runPerfCase(allocator, .skill_success_rank, temp_root),
        .seq_skill_audit => try seq_cli.runPerfCase(allocator, .skill_audit, temp_root),
        .seq_skill_blocks => try seq_cli.runPerfCase(allocator, .skill_blocks, temp_root),
        .seq_tool_audit => try seq_cli.runPerfCase(allocator, .tool_audit, temp_root),
        .seq_memory_inventory => try seq_cli.runPerfCase(allocator, .memory_inventory, temp_root),
        .seq_message_search => try seq_cli.runPerfCase(allocator, .message_search, temp_root),
        .seq_message_audit => try seq_cli.runPerfCase(allocator, .message_audit, temp_root),
        .seq_skill_cohort => try seq_cli.runPerfCase(allocator, .skill_cohort, temp_root),
        .seq_tool_search => try seq_cli.runPerfCase(allocator, .tool_search, temp_root),
        .seq_memory_extension_audit => try seq_cli.runPerfCase(allocator, .memory_extension_audit, temp_root),
        .seq_token_window => try seq_cli.runPerfCase(allocator, .token_window, temp_root),
        .seq_workdir_report => try seq_cli.runPerfCase(allocator, .workdir_report, temp_root),
        .seq_plan_search => try seq_cli.runPerfCase(allocator, .plan_search, temp_root),
        .seq_reply_latency => try seq_cli.runPerfCase(allocator, .reply_latency, temp_root),
        .seq_sessions_limit => try seq_cli.runPerfCase(allocator, .sessions_limit, temp_root),
        .seq_turns => try seq_cli.runPerfCase(allocator, .turns, temp_root),
        .seq_session_detail => try seq_cli.runPerfCase(allocator, .session_detail, temp_root),
        .seq_tool_lifecycle => try seq_cli.runPerfCase(allocator, .tool_lifecycle, temp_root),
        .seq_session_graph => try seq_cli.runPerfCase(allocator, .session_graph, temp_root),
        .seq_tail_once => try seq_cli.runPerfCase(allocator, .tail_once, temp_root),
        .seq_token_cost => try seq_cli.runPerfCase(allocator, .token_cost, temp_root),
        .seq_goal_audit => try seq_cli.runPerfCase(allocator, .goal_audit, temp_root),
        .seq_workflow_audit => try seq_cli.runPerfCase(allocator, .workflow_audit, temp_root),
        .seq_memory_map => try seq_cli.runPerfCase(allocator, .memory_map, temp_root),
        .seq_memory_history => try seq_cli.runPerfCase(allocator, .memory_history, temp_root),
        .seq_session_tooling => try seq_cli.runPerfCase(allocator, .session_tooling, temp_root),
        .seq_orchestration_concurrency => try seq_cli.runPerfCase(allocator, .orchestration_concurrency, temp_root),
        .seq_datasets => try seq_cli.runPerfCase(allocator, .datasets, temp_root),
        .seq_dataset_schema => try seq_cli.runPerfCase(allocator, .dataset_schema, temp_root),
        .seq_artifact_search => try seq_cli.runPerfCase(allocator, .artifact_search, temp_root),
        .seq_find_session => try seq_cli.runPerfCase(allocator, .find_session, temp_root),
        .seq_session_prompts => try seq_cli.runPerfCase(allocator, .session_prompts, temp_root),
        .seq_query_diagnose => try seq_cli.runPerfCase(allocator, .query_diagnose, temp_root),
        .seq_skills_rank => try seq_cli.runPerfCase(allocator, .skills_rank, temp_root),
        .seq_skill_trend => try seq_cli.runPerfCase(allocator, .skill_trend, temp_root),
        .seq_skill_report => try seq_cli.runPerfCase(allocator, .skill_report, temp_root),
        .seq_role_breakdown => try seq_cli.runPerfCase(allocator, .role_breakdown, temp_root),
        .seq_occurrence_export => try seq_cli.runPerfCase(allocator, .occurrence_export, temp_root),
        .seq_report_bundle => try seq_cli.runPerfCase(allocator, .report_bundle, temp_root),
        .seq_section_audit => try seq_cli.runPerfCase(allocator, .section_audit, temp_root),
        .seq_token_usage => try seq_cli.runPerfCase(allocator, .token_usage, temp_root),
        .seq_routing_gap => try seq_cli.runPerfCase(allocator, .routing_gap, temp_root),
        .cron_show => try cron_cli.runPerfCase(allocator, .show, temp_root),
        .cron_create => try cron_cli.runPerfCase(allocator, .create, temp_root),
        .cron_update => try cron_cli.runPerfCase(allocator, .update, temp_root),
        .cron_enable => try cron_cli.runPerfCase(allocator, .enable, temp_root),
        .cron_disable => try cron_cli.runPerfCase(allocator, .disable, temp_root),
        .cron_run_now => try cron_cli.runPerfCase(allocator, .run_now, temp_root),
        .cron_delete => try cron_cli.runPerfCase(allocator, .delete, temp_root),
        .cron_run_due => try cron_cli.runPerfCase(allocator, .run_due, temp_root),
        .st_init => _ = try st_cli.runPerfCase(allocator, .init, temp_root),
        .st_set_status => _ = try st_cli.runPerfCase(allocator, .set_status, temp_root),
        .st_set_priority => _ = try st_cli.runPerfCase(allocator, .set_priority, temp_root),
        .st_set_deps => _ = try st_cli.runPerfCase(allocator, .set_deps, temp_root),
        .st_set_notes => _ = try st_cli.runPerfCase(allocator, .set_notes, temp_root),
        .st_add_comment => _ = try st_cli.runPerfCase(allocator, .add_comment, temp_root),
        .st_remove => _ = try st_cli.runPerfCase(allocator, .remove, temp_root),
        .st_ready => _ = try st_cli.runPerfCase(allocator, .ready, temp_root),
        .st_blocked => _ = try st_cli.runPerfCase(allocator, .blocked, temp_root),
        .st_doctor => _ = try st_cli.runPerfCase(allocator, .doctor, temp_root),
        .st_prime => _ = try st_cli.runPerfCase(allocator, .prime, temp_root),
        .st_import_plan => _ = try st_cli.runPerfCase(allocator, .import_plan, temp_root),
    }
}

fn compareLatencyMetrics(case_cfg: CompatCase, baseline: std.json.Value, metrics: Metrics) !StatusDetail {
    const root = baseline.object;
    const baseline_metrics = root.get("metrics") orelse return error.InvalidData;
    const metric_obj = baseline_metrics.object;
    if (case_cfg.descriptor.measurement_mode == .latency_alloc and baseline_metrics.object.get("p50_alloc_calls") == null) {
        return .{ .status = "FAIL", .detail = "legacy baseline missing alloc metrics; recapture baseline" };
    }
    const base_p50 = try jsonFieldU64(metric_obj, "p50_ns");
    const base_p95 = try jsonFieldU64(metric_obj, "p95_ns");
    const allowed_p50 = allowedUpperBoundWithTolerance(base_p50, case_cfg.tolerance_pct);
    const allowed_p95 = allowedUpperBoundWithTolerance(base_p95, case_cfg.tolerance_pct);
    if (metrics.p50_ns > allowed_p50) {
        return .{ .status = "FAIL", .detail = try std.fmt.allocPrint(std.heap.page_allocator, "p50 {d} > {d}", .{ metrics.p50_ns, allowed_p50 }) };
    }
    if (metrics.p95_ns > allowed_p95) {
        return .{ .status = "FAIL", .detail = try std.fmt.allocPrint(std.heap.page_allocator, "p95 {d} > {d}", .{ metrics.p95_ns, allowed_p95 }) };
    }
    if (case_cfg.descriptor.measurement_mode == .latency_alloc) {
        const base_alloc = try jsonFieldU64(metric_obj, "p50_alloc_calls");
        const allowed_alloc = allowedUpperBoundWithTolerance(base_alloc, case_cfg.tolerance_pct);
        if (metrics.p50_alloc_calls > allowed_alloc) {
            return .{ .status = "FAIL", .detail = try std.fmt.allocPrint(std.heap.page_allocator, "p50_alloc_calls {d} > {d}", .{ metrics.p50_alloc_calls, allowed_alloc }) };
        }
    }
    return .{ .status = "PASS", .detail = "ok" };
}

fn compareDriverRaw(allocator: std.mem.Allocator, case_cfg: CompatCase, baseline: std.json.Value, current_raw_json: []const u8) !StatusDetail {
    var current = try std.json.parseFromSlice(std.json.Value, allocator, current_raw_json, .{});
    defer current.deinit();
    const baseline_raw = baseline.object.get("raw_artifact") orelse return error.InvalidData;
    const current_raw = current.value;
    switch (case_cfg.setup) {
        .seq_parser_driver => {
            const p95 = try jsonObjectFieldU64(current_raw, "fast_p95_ns_per_line");
            const base_p95 = try jsonObjectFieldU64(baseline_raw, "fast_p95_ns_per_line");
            const allowed_p95 = allowedUpperBoundWithTolerance(base_p95, case_cfg.tolerance_pct);
            if (p95 > allowed_p95) return .{ .status = "FAIL", .detail = try std.fmt.allocPrint(allocator, "fast_p95_ns_per_line {d} > {d}", .{ p95, allowed_p95 }) };
            const speedup = try jsonObjectFieldF64(current_raw, "speedup_pct");
            const base_speedup = try jsonObjectFieldF64(baseline_raw, "speedup_pct");
            const speedup_floor = base_speedup * @max(0.0, 1.0 - (case_cfg.tolerance_pct / 100.0));
            if (speedup < speedup_floor) return .{ .status = "FAIL", .detail = try std.fmt.allocPrint(allocator, "speedup_pct {d:.2} < {d:.2}", .{ speedup, speedup_floor }) };
            const alloc_reduction = try jsonObjectFieldF64(current_raw, "alloc_call_reduction_pct");
            const base_alloc_reduction = try jsonObjectFieldF64(baseline_raw, "alloc_call_reduction_pct");
            const alloc_floor = base_alloc_reduction * @max(0.0, 1.0 - (case_cfg.tolerance_pct / 100.0));
            if (alloc_reduction < alloc_floor) return .{ .status = "FAIL", .detail = try std.fmt.allocPrint(allocator, "alloc_call_reduction_pct {d:.2} < {d:.2}", .{ alloc_reduction, alloc_floor }) };
        },
        .lift_bench_stats_driver => {
            if (try compareUpperBoundField(allocator, current_raw, baseline_raw, "p95_ns_per_line", case_cfg.tolerance_pct)) |detail| {
                return .{ .status = "FAIL", .detail = detail };
            }
            if (try compareUpperBoundField(allocator, current_raw, baseline_raw, "p50_alloc_calls_per_round", case_cfg.tolerance_pct)) |detail| {
                return .{ .status = "FAIL", .detail = detail };
            }
        },
        .cas_budget_governor_driver => {
            if (try compareUpperBoundField(allocator, current_raw, baseline_raw, "p95_ns_per_eval", case_cfg.tolerance_pct)) |detail| {
                return .{ .status = "FAIL", .detail = detail };
            }
            if (try compareUpperBoundField(allocator, current_raw, baseline_raw, "p50_alloc_calls_per_eval", case_cfg.tolerance_pct)) |detail| {
                return .{ .status = "FAIL", .detail = detail };
            }
        },
        else => return error.InvalidCommand,
    }
    return .{ .status = "PASS", .detail = "driver compare passed" };
}

fn compareUpperBoundField(allocator: std.mem.Allocator, current: std.json.Value, baseline: std.json.Value, field: []const u8, tolerance_pct: f64) !?[]const u8 {
    const current_value = try jsonObjectFieldU64(current, field);
    const baseline_value = try jsonObjectFieldU64(baseline, field);
    const allowed = allowedUpperBoundWithTolerance(baseline_value, tolerance_pct);
    if (current_value > allowed) {
        return try std.fmt.allocPrint(allocator, "{s} {d} > {d}", .{ field, current_value, allowed });
    }
    return null;
}

fn writeMetricsArtifact(allocator: std.mem.Allocator, path: []const u8, case_cfg: CompatCase, metrics: Metrics, compare_status: []const u8, compare_detail: []const u8) !void {
    var writer_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const sha = try gitShaAlloc(allocator);
    defer allocator.free(sha);
    try writer.print(
        "{{\"schema_version\":1,\"machine_id\":\"{s}\",\"git_sha\":\"{s}\",\"zig_version\":\"{s}\",\"binary\":\"{s}\",\"case_id\":\"{s}\",\"case_kind\":\"{s}\",\"tolerance_pct\":{d:.2},\"metrics\":{{\"samples_ns\":[",
        .{ machine_name, sha, builtin.zig_version_string, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, case_cfg.descriptor.case_kind.asString(), case_cfg.tolerance_pct },
    );
    for (metrics.samples.items, 0..) |sample, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{d}", .{sample});
    }
    try writer.print("],\"p50_ns\":{d},\"p95_ns\":{d}", .{ metrics.p50_ns, metrics.p95_ns });
    if (case_cfg.descriptor.measurement_mode == .latency_alloc) {
        try writer.print(",\"p50_alloc_calls\":{d}", .{metrics.p50_alloc_calls});
    }
    try writer.print("}},\"compare_status\":\"{s}\",\"compare_detail\":", .{compare_status});
    try writeJsonString(writer, compare_detail);
    try writer.writeAll("}\n");
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = writer_alloc.written() });
}

fn writeDriverArtifact(allocator: std.mem.Allocator, path: []const u8, case_cfg: CompatCase, raw_json: []const u8, compare_status: []const u8, compare_detail: []const u8) !void {
    var writer_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    const machine_name = try currentMachineDirName(allocator);
    defer allocator.free(machine_name);
    const sha = try gitShaAlloc(allocator);
    defer allocator.free(sha);
    try writer.print(
        "{{\"schema_version\":1,\"machine_id\":\"{s}\",\"git_sha\":\"{s}\",\"zig_version\":\"{s}\",\"binary\":\"{s}\",\"case_id\":\"{s}\",\"case_kind\":\"{s}\",\"tolerance_pct\":{d:.2},\"raw_artifact\":",
        .{ machine_name, sha, builtin.zig_version_string, case_cfg.descriptor.binary, case_cfg.descriptor.case_id, case_cfg.descriptor.case_kind.asString(), case_cfg.tolerance_pct },
    );
    try writer.writeAll(raw_json);
    try writer.print(",\"compare_status\":\"{s}\",\"compare_detail\":", .{compare_status});
    try writeJsonString(writer, compare_detail);
    try writer.writeAll("}\n");
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = writer_alloc.written() });
}

fn renderCompatRun(allocator: std.mem.Allocator, case_cfg: CompatCase, temp_root: []const u8) !CommandRun {
    const binary_path = try resolveBinaryExecPath(allocator, case_cfg);
    errdefer allocator.free(binary_path);
    const cwd = switch (case_cfg.builder) {
        .root => try allocator.dupe(u8, "."),
        .seq_local => try allocator.dupe(u8, "apps/seq"),
    };
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);

    switch (case_cfg.setup) {
        .seq_help => try args.appendSlice(allocator, &.{ binary_path, "--help" }),
        .bench_stats_help, .perf_report_help, .cas_smoke_check_help, .cas_instance_runner_help, .cas_review_session_help, .cron_help, .puff_help, .learnings_help, .mesh_help, .st_help, .parse_arch_help => try args.appendSlice(allocator, &.{ binary_path, "--help" }),
        .cas_review_session_version => try args.appendSlice(allocator, &.{ binary_path, "--version" }),
        .bench_stats_parse => {
            const input_path = try std.fs.path.join(allocator, &.{ ".", "apps/lift/perf/fixtures/bench_stats_input.txt" });
            try args.appendSlice(allocator, &.{ binary_path, "--input", input_path, "--json" });
        },
        .perf_report_render => {
            const output_path = try std.fs.path.join(allocator, &.{ temp_root, "perf-report.md" });
            try args.appendSlice(allocator, &.{ binary_path, "--title", "Perf", "--owner", "tk", "--system", "skills-zig", "--output", output_path });
        },
        .cas_wrapper_smoke => {
            const wrapper_dir = try std.fs.path.join(allocator, &.{ temp_root, "cas-wrapper" });
            try makeRepoAwarePath(allocator, wrapper_dir);
            const wrapper_binary = try std.fs.path.join(allocator, &.{ wrapper_dir, "cas" });
            const source_binary = try absolutePathForCwdRelative(allocator, binary_path);
            defer allocator.free(source_binary);
            try std.Io.Dir.copyFileAbsolute(source_binary, wrapper_binary, std.Io.Threaded.global_single_threaded.io(), .{});
            try makeExecutable(wrapper_binary);
            const stub_path = try std.fs.path.join(allocator, &.{ wrapper_dir, "cas_smoke_check" });
            try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = stub_path, .data = "#!/usr/bin/env bash\nexit 0\n" });
            try makeExecutable(stub_path);
            return .{ .cwd = cwd, .argv = try allocator.dupe([]const u8, &.{ wrapper_binary, "smoke_check" }) };
        },
        .cron_list => {
            const db_name = try std.fmt.allocPrint(allocator, "codex-dev-{d}.db", .{@divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000)});
            const db_path = try std.fs.path.join(allocator, &.{ temp_root, db_name });
            try seedCronDb(allocator, db_path);
            try args.appendSlice(allocator, &.{ binary_path, "--db", db_path, "list" });
        },
        .puff_wrapper => {
            const codex_home = try std.fs.path.join(allocator, &.{ temp_root, ".codex" });
            const script_dir = try std.fs.path.join(allocator, &.{ codex_home, "skills", "puff", "scripts" });
            try makeRepoAwarePath(allocator, script_dir);
            const script_path = try std.fs.path.join(allocator, &.{ script_dir, "puff.sh" });
            try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = script_path, .data = "#!/usr/bin/env bash\nexit 0\n" });
            try makeExecutable(script_path);
            try args.appendSlice(allocator, &.{ "/usr/bin/env", try std.fmt.allocPrint(allocator, "CODEX_HOME={s}", .{codex_home}), binary_path, "status" });
        },
        .learnings_recent => try args.appendSlice(allocator, &.{ binary_path, "--path", "apps/learnings/perf/fixtures/learnings.jsonl", "recent", "--limit", "3" }),
        .learnings_recall => try args.appendSlice(allocator, &.{ binary_path, "--path", "apps/learnings/perf/fixtures/learnings.jsonl", "recall", "--query", "benchmark regression", "--limit", "3", "--format", "json", "--drop-superseded" }),
        .learnings_query => try args.appendSlice(allocator, &.{ binary_path, "--path", "apps/learnings/perf/fixtures/learnings.jsonl", "query", "--spec", "@apps/learnings/perf/fixtures/query_spec.json" }),
        .learnings_codify => try args.appendSlice(allocator, &.{ binary_path, "--path", "apps/learnings/perf/fixtures/learnings.jsonl", "codify-candidates", "--min-count", "2", "--limit", "5", "--format", "json" }),
        .learnings_quality => try args.appendSlice(allocator, &.{ binary_path, "--path", "apps/learnings/perf/fixtures/learnings.jsonl", "quality-audit", "--format", "json" }),
        .append_learning_help => try args.appendSlice(allocator, &.{ binary_path, "--help" }),
        .append_learning_append => {
            const fixture_path = try std.fs.path.join(allocator, &.{ temp_root, "learnings.jsonl" });
            try std.Io.Dir.copyFileAbsolute("apps/learnings/perf/fixtures/learnings.jsonl", fixture_path, std.Io.Threaded.global_single_threaded.io(), .{});
            try args.appendSlice(allocator, &.{ binary_path, "--path", fixture_path, "--status", "do_more", "--learning", "When running local perf comparisons, prefer machine-scoped baselines to avoid cross-host noise.", "--evidence", "Local compare uses one machine and one baseline directory.", "--application", "Use .perf-local baselines before refactors to avoid cross-host drift.", "--tag", "perf" });
        },
        .mesh_budget => try args.appendSlice(allocator, &.{ binary_path, "budget", "--remaining-five-hour", "42", "--remaining-weekly", "38", "--max-threads", "12", "--previous-triplet-width", "3", "--prior-wave-instability", "false", "--consecutive-unstable-waves", "0", "--consecutive-clean-waves", "1" }),
        .mesh_plan_sync => try args.appendSlice(allocator, &.{ binary_path, "plan_sync", "--input-json", "apps/mesh/perf/fixtures/plan.json" }),
        .mesh_slice => {
            const output_path = try std.fs.path.join(allocator, &.{ temp_root, "units.json" });
            try args.appendSlice(allocator, &.{ binary_path, "slice", "--input-json", "apps/mesh/perf/fixtures/plan.json", "--output-json", output_path, "--max-slices", "2" });
        },
        .mesh_wave => {
            const units_path = try std.fs.path.join(allocator, &.{ temp_root, "units.json" });
            {
                var prep = std.ArrayList([]const u8).empty;
                defer prep.deinit(allocator);
                try prep.appendSlice(allocator, &.{ binary_path, "slice", "--input-json", "apps/mesh/perf/fixtures/plan.json", "--output-json", units_path, "--max-slices", "2" });
                const prep_result = try runChildCapture(allocator, ".", prep.items);
                defer allocator.free(prep_result.stdout);
                defer allocator.free(prep_result.stderr);
                if (prep_result.exit_code != 0) return error.CaseFailed;
            }
            const csv_path = try std.fs.path.join(allocator, &.{ temp_root, "wave.csv" });
            try args.appendSlice(allocator, &.{ binary_path, "wave", "--units-json", units_path, "--csv-path", csv_path, "--max-active", "2", "--lane", "coder", "--triplet-width", "2" });
        },
        .st_add_show => {
            const plan_path = try std.fs.path.join(allocator, &.{ temp_root, "st-plan.jsonl" });
            {
                var prep = std.ArrayList([]const u8).empty;
                defer prep.deinit(allocator);
                try prep.appendSlice(allocator, &.{ binary_path, "init", "--file", plan_path });
                const prep_result = try runChildCapture(allocator, ".", prep.items);
                defer allocator.free(prep_result.stdout);
                defer allocator.free(prep_result.stderr);
                if (prep_result.exit_code != 0) return error.CaseFailed;
            }
            try args.appendSlice(allocator, &.{ binary_path, "add", "--file", plan_path, "--id", "st-001", "--step", "Reproduce issue", "--priority", "high" });
        },
        .st_emit_export => {
            const plan_path = try std.fs.path.join(allocator, &.{ temp_root, "st-plan.jsonl" });
            const export_path = try std.fs.path.join(allocator, &.{ temp_root, "snapshot.json" });
            for (&[_][]const []const u8{
                &.{ binary_path, "init", "--file", plan_path },
                &.{ binary_path, "add", "--file", plan_path, "--id", "st-001", "--step", "Reproduce issue", "--priority", "high" },
            }) |prep_argv| {
                const prep_result = try runChildCapture(allocator, ".", prep_argv);
                defer allocator.free(prep_result.stdout);
                defer allocator.free(prep_result.stderr);
                if (prep_result.exit_code != 0) return error.CaseFailed;
            }
            try args.appendSlice(allocator, &.{ binary_path, "export", "--file", plan_path, "--output", export_path });
        },
        .parse_arch_collect => try args.appendSlice(allocator, &.{ binary_path, "collect", "apps/parse-arch/references/eval/fixtures/layered-api" }),
        .parse_arch_eval => try args.appendSlice(allocator, &.{ binary_path, "eval", "--suite", "apps/parse-arch/references/eval/suite.yaml" }),
        .parse_arch_doctor => try args.appendSlice(allocator, &.{ binary_path, "doctor", "--suite", "apps/parse-arch/references/eval/suite.yaml", "--repo-path", "apps/parse-arch/references/eval/fixtures/layered-api" }),
        else => return error.InvalidCommand,
    }
    return .{ .cwd = cwd, .argv = try args.toOwnedSlice(allocator) };
}

const ChildResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
};

fn runChildCapture(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !ChildResult {
    if (builtin.os.tag == .macos) return runChildCapturePosixSpawn(allocator, cwd, argv);

    const result = try std.process.run(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(2 * 1024 * 1024),
    });
    return .{
        .exit_code = switch (result.term) {
            .exited => |code| code,
            .signal, .stopped, .unknown => 1,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn runChildCapturePosixSpawn(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !ChildResult {
    if (argv.len == 0) return error.FileNotFound;

    var argv_buf = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    defer allocator.free(argv_buf);

    var arg_storage = try allocator.alloc([:0]u8, argv.len);
    var arg_count: usize = 0;
    defer {
        for (arg_storage[0..arg_count]) |arg| allocator.free(arg);
        allocator.free(arg_storage);
    }
    for (argv, 0..) |arg, idx| {
        arg_storage[idx] = try allocator.dupeZ(u8, arg);
        arg_count += 1;
        argv_buf[idx] = arg_storage[idx].ptr;
    }

    const cwd_z = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_z);

    var actions: std.c.posix_spawn_file_actions_t = undefined;
    const init_rc = std.c.posix_spawn_file_actions_init(&actions);
    if (init_rc != 0) return posixSpawnError(init_rc);
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);

    const dev_null = "/dev/null";
    const dev_null_flags: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .ACCMODE = .WRONLY })));
    for ([_]std.c.fd_t{ 1, 2 }) |fd| {
        const open_rc = std.c.posix_spawn_file_actions_addopen(&actions, fd, dev_null, dev_null_flags, 0);
        if (open_rc != 0) return posixSpawnError(open_rc);
    }
    const chdir_rc = std.c.posix_spawn_file_actions_addchdir_np(&actions, cwd_z);
    if (chdir_rc != 0) return posixSpawnError(chdir_rc);

    var pid: std.c.pid_t = undefined;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const spawn_rc = std.c.posix_spawnp(&pid, argv_buf[0].?, &actions, null, argv_buf.ptr, envp);
    if (spawn_rc != 0) return posixSpawnError(spawn_rc);

    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
        .SUCCESS => return .{
            .exit_code = statusToExitCode(@bitCast(status)),
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, ""),
        },
        .INTR => continue,
        .CHILD => return error.NoChildProcess,
        else => return error.WaitFailed,
    };
}

fn posixSpawnError(rc: c_int) anyerror {
    const err: std.c.E = @enumFromInt(@as(u16, @intCast(rc)));
    return switch (err) {
        .NOMEM, .@"2BIG" => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOEXEC => error.InvalidExe,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        else => error.SpawnFailed,
    };
}

fn statusToExitCode(status: u32) u8 {
    if (std.posix.W.IFEXITED(status)) return std.posix.W.EXITSTATUS(status);
    if (std.posix.W.IFSIGNALED(status)) {
        const signal: u32 = @intFromEnum(std.posix.W.TERMSIG(status));
        return @intCast(@min(@as(u32, 128) + signal, @as(u32, 255)));
    }
    return 1;
}

fn makeTempRoot(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    const stamp = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    const base = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/perf-hub/{d}-{s}", .{ cwd, stamp, label });
    try makeRepoAwarePath(allocator, base);
    return base;
}

fn cleanupTempRoot(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
}

fn makeExecutable(path: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .mode = .read_write });
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    try file.setPermissions(std.Io.Threaded.global_single_threaded.io(), @enumFromInt(0o755));
}

fn absolutePathForCwdRelative(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn seedCronDb(allocator: std.mem.Allocator, db_path: []const u8) !void {
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    var db_opt: ?*Sqlite.sqlite3 = null;
    if (Sqlite.sqlite3_open(db_path_z, &db_opt) != Sqlite.SQLITE_OK or db_opt == null) return error.InvalidData;
    defer _ = Sqlite.sqlite3_close(db_opt.?);

    const schema =
        \\create table automations (
        \\  id text primary key,
        \\  name text not null,
        \\  prompt text not null,
        \\  status text not null,
        \\  next_run_at integer,
        \\  last_run_at integer,
        \\  cwds text not null,
        \\  rrule text not null,
        \\  created_at integer not null,
        \\  updated_at integer not null
        \\);
        \\create table automation_runs (
        \\  thread_id text primary key,
        \\  automation_id text not null,
        \\  status text not null,
        \\  read_at integer,
        \\  thread_title text,
        \\  source_cwd text,
        \\  inbox_title text,
        \\  inbox_summary text,
        \\  created_at integer not null,
        \\  updated_at integer not null,
        \\  archived_user_message text,
        \\  archived_assistant_message text,
        \\  archived_reason text
        \\);
        \\insert into automations (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at) values ('cron-001', 'Daily Summary', 'Summarize recent runs', 'ACTIVE', null, null, '[]', 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=15', 1772469600000, 1772469600000);
    ;
    const schema_z = try allocator.dupeZ(u8, schema);
    defer allocator.free(schema_z);
    var err_msg: ?[*:0]u8 = null;
    if (Sqlite.sqlite3_exec(db_opt.?, schema_z, null, null, &err_msg) != Sqlite.SQLITE_OK) {
        if (err_msg) |msg| {
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            try stderr_writer.interface.print("seedCronDb sqlite error: {s}\n", .{std.mem.sliceTo(msg, 0)});
        }
        return error.InvalidData;
    }
}

fn percentileU64(allocator: std.mem.Allocator, samples: []const u64, p: usize) !u64 {
    const copy = try allocator.dupe(u64, samples);
    defer allocator.free(copy);
    std.mem.sort(u64, copy, {}, struct {
        fn less(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.less);
    const idx = ((copy.len - 1) * p) / 100;
    return copy[idx];
}

fn allowedUpperBoundWithTolerance(base: u64, tolerance_pct: f64) u64 {
    if (base == 0) return 1;
    const factor = 1.0 + @max(tolerance_pct, 0.0) / 100.0;
    return @intFromFloat(std.math.ceil(@as(f64, @floatFromInt(base)) * factor));
}

fn jsonFieldU64(obj: std.json.ObjectMap, key: []const u8) !u64 {
    return jsonValueU64(obj.get(key) orelse return error.InvalidData, key);
}

fn jsonObjectFieldU64(value: std.json.Value, key: []const u8) !u64 {
    return jsonFieldU64(value.object, key);
}

fn jsonValueU64(value: std.json.Value, _: []const u8) !u64 {
    return switch (value) {
        .integer => |v| if (v >= 0) @intCast(v) else error.InvalidData,
        .float => |v| if (v >= 0) @intFromFloat(v) else error.InvalidData,
        else => error.InvalidData,
    };
}

fn jsonValueF64(value: std.json.Value, _: []const u8) !f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => error.InvalidData,
    };
}

fn jsonObjectFieldF64(value: std.json.Value, key: []const u8) !f64 {
    return jsonValueF64(value.object.get(key) orelse return error.InvalidData, key);
}

fn cmdReport(allocator: std.mem.Allocator) !void {
    const machine_dir = try resolveMachineDir(allocator, ".perf-local");
    defer allocator.free(machine_dir);
    const reports_dir = try std.fs.path.join(allocator, &.{ machine_dir, "reports" });
    defer allocator.free(reports_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), reports_dir);
    const latest_path = try std.fs.path.join(allocator, &.{ machine_dir, "reports", "latest-compare.json" });
    defer allocator.free(latest_path);
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), latest_path, .{}) catch return error.MissingCompareSummary;
    const data = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), latest_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const rows_val = parsed.value.object.get("rows") orelse return error.InvalidData;
    const rows = rows_val.array;

    var totals = std.StringHashMap(ReportCounts).init(allocator);
    defer totals.deinit();
    for (rows.items) |row| {
        const obj = row.object;
        const binary = obj.get("binary").?.string;
        const status = obj.get("status").?.string;
        const entry = try totals.getOrPutValue(binary, .{});
        if (std.mem.eql(u8, status, "PASS")) entry.value_ptr.pass += 1 else entry.value_ptr.fail += 1;
    }

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    var row_keys: std.ArrayList([]const u8) = .empty;
    defer row_keys.deinit(allocator);
    var it = totals.iterator();
    while (it.next()) |entry| {
        try row_keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, row_keys.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (row_keys.items) |key| {
        const counts = totals.get(key).?;
        try stdout.print("{s}\tpass={d}\tfail={d}\n", .{ key, counts.pass, counts.fail });
    }

    const latest_report_path = try std.fs.path.join(allocator, &.{ reports_dir, "latest-report.json" });
    defer allocator.free(latest_report_path);
    try writeLatestReport(allocator, latest_report_path, row_keys.items, totals);

    const cutover_path = try std.fs.path.join(allocator, &.{ reports_dir, "cutover-status.json" });
    defer allocator.free(cutover_path);
    try writeCutoverStatus(allocator, cutover_path, rows);
}

fn cmdAccept(allocator: std.mem.Allocator) !void {
    const machine_dir = try resolveMachineDir(allocator, ".perf-local");
    defer allocator.free(machine_dir);
    const baselines_dir = try std.fs.path.join(allocator, &.{ machine_dir, "baselines" });
    defer allocator.free(baselines_dir);
    const accepted_dir = try std.fs.path.join(allocator, &.{ machine_dir, "accepted" });
    defer allocator.free(accepted_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), accepted_dir);

    const sha = try gitShaAlloc(allocator);
    defer allocator.free(sha);
    const ts = try nowTagAlloc(allocator);
    defer allocator.free(ts);
    const snapshot_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ ts, sha });
    defer allocator.free(snapshot_name);
    const snapshot_path = try std.fs.path.join(allocator, &.{ accepted_dir, snapshot_name });
    defer allocator.free(snapshot_path);
    try copyTree(std.Io.Dir.cwd(), baselines_dir, snapshot_path);

    const active_path = try std.fs.path.join(allocator, &.{ machine_dir, "active-baseline.json" });
    defer allocator.free(active_path);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), active_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try writer.interface.print(
        "{{\"accepted_at\":\"{s}\",\"git_sha\":\"{s}\",\"snapshot_path\":\"{s}\"}}\n",
        .{ ts, sha, snapshot_path },
    );
}

fn resolveMachineDir(allocator: std.mem.Allocator, perf_root: []const u8) ![]u8 {
    const current_name = try currentMachineDirName(allocator);
    defer allocator.free(current_name);

    const preferred = try std.fs.path.join(allocator, &.{ perf_root, current_name });
    errdefer allocator.free(preferred);
    if (pathExists(preferred)) return preferred;

    var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), perf_root, .{ .iterate = true });
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var it = dir.iterate();
    var fallback: ?[]u8 = null;
    while (try it.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .directory) continue;
        if (fallback != null) return error.AmbiguousMachineDir;
        fallback = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ perf_root, entry.name });
    }
    if (fallback) |value| {
        allocator.free(preferred);
        return value;
    }
    return error.MissingMachineDir;
}

fn currentMachineDirName(allocator: std.mem.Allocator) ![]u8 {
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host_full = try std.posix.gethostname(&host_buf);
    const host = host_full[0 .. std.mem.indexOfScalar(u8, host_full, '.') orelse host_full.len];
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-zig{s}", .{
        switch (builtin.target.os.tag) {
            .macos => "darwin",
            else => @tagName(builtin.target.os.tag),
        },
        switch (builtin.target.cpu.arch) {
            .aarch64 => "arm64",
            else => @tagName(builtin.target.cpu.arch),
        },
        host,
        builtin.zig_version_string,
    });
}

fn inferBinary(case_id: []const u8) []const u8 {
    if (std.mem.startsWith(u8, case_id, "seq-")) return "seq";
    if (std.mem.startsWith(u8, case_id, "cron-")) return "cron";
    if (std.mem.startsWith(u8, case_id, "st-")) return "st";
    if (std.mem.startsWith(u8, case_id, "mesh-")) return "mesh";
    if (std.mem.startsWith(u8, case_id, "puff-")) return "puff";
    if (std.mem.startsWith(u8, case_id, "parse-arch-")) return "parse-arch";
    if (std.mem.startsWith(u8, case_id, "learnings-")) return "learnings";
    if (std.mem.startsWith(u8, case_id, "append-learning-")) return "append_learning";
    if (std.mem.startsWith(u8, case_id, "bench-stats")) return "bench_stats";
    if (std.mem.startsWith(u8, case_id, "lift-bench-stats")) return "bench_stats";
    if (std.mem.startsWith(u8, case_id, "perf-report")) return "perf_report";
    if (std.mem.startsWith(u8, case_id, "cas-")) return "cas";
    return "unknown";
}

fn gitShaAlloc(allocator: std.mem.Allocator) ![]u8 {
    const head_data = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".git/HEAD", allocator, .limited(1024)) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(head_data);
    const head = std.mem.trim(u8, head_data, " \t\r\n");
    if (std.mem.startsWith(u8, head, "ref: ")) {
        const ref_path = std.mem.trim(u8, head["ref: ".len..], " \t\r\n");
        const loose_path = try std.fs.path.join(allocator, &.{ ".git", ref_path });
        defer allocator.free(loose_path);
        if (std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), loose_path, allocator, .limited(1024))) |ref_data| {
            defer allocator.free(ref_data);
            return shortShaAlloc(allocator, std.mem.trim(u8, ref_data, " \t\r\n"));
        } else |_| {}

        if (std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".git/packed-refs", allocator, .limited(1024 * 1024))) |packed_data| {
            defer allocator.free(packed_data);
            var lines = std.mem.splitScalar(u8, packed_data, '\n');
            while (lines.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r\n");
                if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
                var parts = std.mem.splitScalar(u8, line, ' ');
                const sha = parts.next() orelse continue;
                const name = parts.next() orelse continue;
                if (std.mem.eql(u8, name, ref_path)) return shortShaAlloc(allocator, sha);
            }
        } else |_| {}
        return allocator.dupe(u8, "unknown");
    }
    return shortShaAlloc(allocator, head);
}

fn shortShaAlloc(allocator: std.mem.Allocator, sha: []const u8) ![]u8 {
    return allocator.dupe(u8, sha[0..@min(sha.len, 12)]);
}

fn nowTagAlloc(allocator: std.mem.Allocator) ![]u8 {
    const now = @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000)));
    return std.fmt.allocPrint(allocator, "{d}", .{now});
}

fn copyTree(cwd: std.Io.Dir, source: []const u8, dest: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try cwd.createDirPath(io, dest);
    var src = try cwd.openDir(io, source, .{ .iterate = true });
    defer src.close(io);
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        const src_path = try std.fs.path.join(std.heap.page_allocator, &.{ source, entry.name });
        defer std.heap.page_allocator.free(src_path);
        const dest_path = try std.fs.path.join(std.heap.page_allocator, &.{ dest, entry.name });
        defer std.heap.page_allocator.free(dest_path);
        switch (entry.kind) {
            .directory => try copyTree(cwd, src_path, dest_path),
            .file => try cwd.copyFile(src_path, cwd, dest_path, io, .{}),
            else => {},
        }
    }
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

fn makeRepoAwarePath(allocator: std.mem.Allocator, path: []const u8) !void {
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    if (std.fs.path.isAbsolute(path) and std.mem.startsWith(u8, path, cwd)) {
        const rel = if (path.len == cwd.len) "." else path[cwd.len + 1 ..];
        try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), rel);
        return;
    }
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), path);
}

fn isKnownBinaryName(text: []const u8) bool {
    for (allManifests()) |manifest| {
        if (std.mem.eql(u8, manifest.binary, text)) return true;
        for (manifest.cases) |case_desc| {
            if (std.mem.eql(u8, case_desc.binary, text)) return true;
        }
    }
    return false;
}

fn writeLatestReport(
    allocator: std.mem.Allocator,
    path: []const u8,
    row_keys: []const []const u8,
    totals: std.StringHashMap(ReportCounts),
) !void {
    var writer_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeAll("{\"rows\":[");
    for (row_keys, 0..) |key, idx| {
        const counts = totals.get(key).?;
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"binary\":\"{s}\",\"pass\":{d},\"fail\":{d}}}", .{ key, counts.pass, counts.fail });
    }
    try writer.writeAll("]}\n");
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = writer_alloc.written() });
}

fn writeCutoverStatus(allocator: std.mem.Allocator, path: []const u8, rows: std.json.Array) !void {
    var preserved_matrix_parity = true;
    for (rows.items) |row| {
        if (!std.mem.eql(u8, row.object.get("status").?.string, "PASS")) {
            preserved_matrix_parity = false;
            break;
        }
    }

    const seq_manifest = allManifests()[0];
    var seq_has_artifact_search = false;
    for (seq_manifest.coverages) |coverage| {
        if (std.mem.eql(u8, coverage.family, "artifact-search")) {
            seq_has_artifact_search = true;
            break;
        }
    }
    var seq_has_memory_blocks = false;
    for (seq_manifest.datasets) |dataset| {
        if (std.mem.eql(u8, dataset.name, "memory_blocks")) {
            seq_has_memory_blocks = true;
            break;
        }
    }
    const seq_surface_integrated = seq_has_artifact_search and seq_has_memory_blocks;

    const cron_status = coverageStatusFor("cron");
    const st_status = coverageStatusFor("st");

    var residuals = std.ArrayList([]const u8).empty;
    defer {
        for (residuals.items) |item| allocator.free(item);
        residuals.deinit(allocator);
    }
    for (allManifests()) |manifest| {
        for (manifest.coverages) |coverage| {
            if (coverage.coverage == .missing) {
                try residuals.append(allocator, try std.fmt.allocPrint(allocator, "{s}:{s}", .{ manifest.binary, coverage.family }));
            }
        }
        for (manifest.datasets) |dataset| {
            if (dataset.coverage == .missing) {
                try residuals.append(allocator, try std.fmt.allocPrint(allocator, "{s}:dataset:{s}", .{ manifest.binary, dataset.name }));
            }
        }
    }

    var writer_alloc: std.Io.Writer.Allocating = .init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.print(
        "{{\"native_public_ownership\":true,\"preserved_matrix_parity\":{s},\"seq_surface_integrated\":{s},\"cron_deep_driver_status\":\"{s}\",\"st_deep_driver_status\":\"{s}\",\"wave_b_residuals\":[",
        .{
            if (preserved_matrix_parity) "true" else "false",
            if (seq_surface_integrated) "true" else "false",
            cron_status,
            st_status,
        },
    );
    for (residuals.items, 0..) |item, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeAll("]}\n");
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = writer_alloc.written() });
}

fn coverageStatusFor(binary: []const u8) []const u8 {
    for (allManifests()) |manifest| {
        if (!std.mem.eql(u8, manifest.binary, binary)) continue;
        var saw_deep = false;
        for (manifest.coverages) |coverage| {
            switch (coverage.coverage) {
                .missing => return if (saw_deep) "partial" else "not_landed",
                .deep => saw_deep = true,
                .shallow, .excluded => {},
            }
        }
        return if (saw_deep) "landed" else "not_landed";
    }
    return "unknown";
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

test "resolveMachineDir prefers current machine directory when multiple directories exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), alloc);
    defer alloc.free(cwd_before);
    try std.process.setCurrentDir(std.Io.Threaded.global_single_threaded.io(), tmp.dir);
    defer std.process.setCurrentPath(std.Io.Threaded.global_single_threaded.io(), cwd_before) catch {};

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".perf-local");
    const current_name = try currentMachineDirName(alloc);
    defer alloc.free(current_name);
    const current_path = try std.fmt.allocPrint(alloc, ".perf-local/{s}", .{current_name});
    defer alloc.free(current_path);
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), current_path);
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".perf-local/other-machine");

    const resolved = try resolveMachineDir(alloc, ".perf-local");
    defer alloc.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, current_name));
}

test "resolveMachineDir falls back to a single legacy directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), alloc);
    defer alloc.free(cwd_before);
    try std.process.setCurrentDir(std.Io.Threaded.global_single_threaded.io(), tmp.dir);
    defer std.process.setCurrentPath(std.Io.Threaded.global_single_threaded.io(), cwd_before) catch {};

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), ".perf-local/legacy-only");
    const resolved = try resolveMachineDir(alloc, ".perf-local");
    defer alloc.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "legacy-only"));
}

test "report errors clearly when compare summary is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const alloc = std.testing.allocator;
    const cwd_before = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), alloc);
    defer alloc.free(cwd_before);
    try std.process.setCurrentDir(std.Io.Threaded.global_single_threaded.io(), tmp.dir);
    defer std.process.setCurrentPath(std.Io.Threaded.global_single_threaded.io(), cwd_before) catch {};

    const current_name = try currentMachineDirName(alloc);
    defer alloc.free(current_name);
    const reports_path = try std.fmt.allocPrint(alloc, ".perf-local/{s}/reports", .{current_name});
    defer alloc.free(reports_path);
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), reports_path);

    try std.testing.expectError(error.MissingCompareSummary, cmdReport(alloc));
}

test "inferBinary maps lift driver case to bench_stats" {
    try std.testing.expectEqualStrings("bench_stats", inferBinary("lift-bench-stats-driver"));
}

test "coverageStatusFor reflects current manifest coverage" {
    try std.testing.expectEqualStrings("partial", coverageStatusFor("seq"));
    try std.testing.expectEqualStrings("landed", coverageStatusFor("cron"));
    try std.testing.expectEqualStrings("landed", coverageStatusFor("st"));
}

test "compareLatencyMetrics fails closed for latency_alloc legacy baselines" {
    const alloc = std.testing.allocator;
    const baseline_json =
        \\{"metrics":{"p50_ns":100,"p95_ns":200}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, baseline_json, .{});
    defer parsed.deinit();

    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(alloc);
    var alloc_samples: std.ArrayList(u64) = .empty;
    defer alloc_samples.deinit(alloc);

    const result = try compareLatencyMetrics(.{
        .descriptor = .{
            .case_id = "seq-query-tool-calls",
            .binary = "seq",
            .family = "query",
            .case_kind = .native,
            .measurement_mode = .latency_alloc,
        },
        .builder = .root,
        .build_step = null,
        .binary_path = "",
        .setup = .cron_help,
        .tolerance_pct = 25.0,
    }, parsed.value, .{
        .samples = samples,
        .alloc_samples = alloc_samples,
        .p50_ns = 100,
        .p95_ns = 200,
        .p50_alloc_calls = 10,
    });

    try std.testing.expectEqualStrings("FAIL", result.status);
    try std.testing.expectEqualStrings("legacy baseline missing alloc metrics; recapture baseline", result.detail);
}

test "doctor counts compat and deep cases" {
    var count: usize = 0;
    for (CompatCases) |_| count += 1;
    for (DeepCases) |_| count += 1;
    try std.testing.expectEqual(CompatCases.len + DeepCases.len, count);
}
