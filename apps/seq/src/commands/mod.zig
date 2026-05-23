const std = @import("std");
const lib = @import("../lib.zig");
const datasets = @import("../datasets/mod.zig");
const plan_blocks = @import("../plan_blocks.zig");
const query = @import("../query/engine.zig");
const spec = @import("../types/spec.zig");
const output = @import("../output/mod.zig");
const time_utils = @import("../time_utils.zig");
const canonical_trace = @import("../canonical_trace.zig");
const token_cost = @import("../token_cost.zig");

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn getEnvVarOwned(allocator: std.mem.Allocator, comptime key: [:0]const u8) ![]u8 {
    const value = std.c.getenv(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(value));
}

pub const DatasetMeta = struct {
    name: []const u8,
    description: []const u8,
    fields: []const []const u8,
};

pub const dataset_meta = [_]DatasetMeta{
    .{
        .name = "messages",
        .description = "Messages (user/assistant) with timestamps and text",
        .fields = &.{ "path", "timestamp", "day", "week", "month", "role", "text", "text_len" },
    },
    .{
        .name = "skill_mentions",
        .description = "Skill mentions via <skill> blocks and $skill tokens",
        .fields = &.{ "path", "timestamp", "day", "week", "month", "role", "skill", "types", "snippet" },
    },
    .{
        .name = "token_events",
        .description = "Raw token_count events",
        .fields = &.{
            "path",
            "timestamp",
            "day",
            "week",
            "month",
            "model_context_window",
            "total_input_tokens",
            "total_cached_input_tokens",
            "total_output_tokens",
            "total_reasoning_output_tokens",
            "total_total_tokens",
            "last_input_tokens",
            "last_cached_input_tokens",
            "last_output_tokens",
            "last_reasoning_output_tokens",
            "last_total_tokens",
        },
    },
    .{
        .name = "token_deltas",
        .description = "Token deltas derived from total_token_usage changes",
        .fields = &.{
            "path",
            "timestamp",
            "day",
            "week",
            "month",
            "segment",
            "model_context_window",
            "delta_input_tokens",
            "delta_cached_input_tokens",
            "delta_output_tokens",
            "delta_reasoning_output_tokens",
            "delta_total_tokens",
            "total_input_tokens",
            "total_cached_input_tokens",
            "total_output_tokens",
            "total_reasoning_output_tokens",
            "total_total_tokens",
        },
    },
    .{
        .name = "token_sessions",
        .description = "One row per session file: max total_token_usage",
        .fields = &.{
            "path",
            "start",
            "end",
            "max_at",
            "day",
            "week",
            "month",
            "total_input_tokens",
            "total_cached_input_tokens",
            "total_output_tokens",
            "total_reasoning_output_tokens",
            "total_total_tokens",
        },
    },
    .{
        .name = "tool_calls",
        .description = "Tool calls (function_call/custom_tool_call)",
        .fields = &.{
            "path",
            "timestamp",
            "day",
            "week",
            "month",
            "kind",
            "tool",
            "call_id",
            "arguments_len",
            "input_len",
            "status",
            "arguments_text",
            "input_text",
            "command_text",
            "primary_executable",
            "workdir",
            "parse_error",
        },
    },
    .{
        .name = "tool_invocations",
        .description = "Lifecycle-enriched tool invocations parsed from rollout JSONL",
        .fields = &.{
            "path",
            "session_id",
            "timestamp",
            "end_timestamp",
            "day",
            "week",
            "month",
            "call_id",
            "tool_name",
            "invocation_kind",
            "arguments_text",
            "input_text",
            "command_text",
            "primary_executable",
            "workdir",
            "pty_session_id",
            "wall_time_ms",
            "exit_code",
            "running_state",
            "unresolved",
            "parse_error",
        },
    },
    .{
        .name = "tool_call_args",
        .description = "Flattened tool-call argument leaves parsed from JSON arguments/input payloads",
        .fields = &.{
            "path",
            "session_id",
            "timestamp",
            "day",
            "week",
            "month",
            "call_id",
            "tool_name",
            "invocation_kind",
            "payload_source",
            "arg_path",
            "value_kind",
            "value_text",
            "value_number",
            "value_bool",
            "is_null",
            "array_index",
            "parse_error",
        },
    },
    .{
        .name = "sessions",
        .description = "Canonical Codex session traces",
        .fields = &.{ "session_id", "path", "date_group", "start_time", "end_time", "cwd", "git_branch", "git_commit_hash", "git_repository_url", "originator", "cli_version", "model", "model_provider", "thread_name", "turn_count", "total_tokens", "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "is_ongoing", "status_reason", "is_external_worker", "is_inline_worker", "spawned_worker_count" },
    },
    .{
        .name = "turns",
        .description = "Canonical Codex turn traces",
        .fields = &.{ "session_id", "path", "turn_id", "turn_index", "started_at", "completed_at", "duration_ms", "status", "status_reason", "user_message", "user_preview", "final_answer", "assistant_preview", "model", "cwd", "reasoning_effort", "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens", "tool_count", "has_compaction", "thread_name", "error", "aborted_reason", "spawned_worker_count" },
    },
    .{
        .name = "tool_lifecycle",
        .description = "Canonical Codex tool lifecycle records",
        .fields = &.{ "session_id", "path", "turn_id", "turn_index", "call_id", "kind", "tool_name", "namespace", "arguments_json", "input_text", "output_text", "command_text", "cwd", "exit_code", "duration_ms", "mcp_server", "mcp_tool", "patch_success", "patch_changes_json", "web_query", "web_url", "image_prompt", "lifecycle_status", "declared_line", "finalized_line" },
    },
    .{
        .name = "session_graph_edges",
        .description = "Canonical Codex worker/session graph edges",
        .fields = &.{ "parent_session_id", "worker_session_id", "parent_path", "worker_path", "call_id", "agent_nickname", "agent_role", "model", "reasoning_effort", "spawned_at", "prompt_preview", "worker_status" },
    },
    .{
        .name = "workflow_signals",
        .description = "Session-derived workflow, skill, agent, tool, and outcome signals with source provenance",
        .fields = &.{ "path", "session_id", "timestamp", "role", "source_kind", "signal_kind", "name", "outcome_kind", "snippet", "contamination_flags" },
    },
    .{
        .name = "goal_runs",
        .description = "One row per Codex /goal run observed through goal tool outputs",
        .fields = &.{
            "path",
            "session_id",
            "thread_id",
            "timestamp",
            "day",
            "week",
            "month",
            "objective",
            "objective_kind",
            "status",
            "created_at",
            "updated_at",
            "time_used_seconds",
            "tokens_used",
            "remaining_tokens",
            "completion_budget_report",
            "review_invocation_count",
            "has_review_objective",
            "has_resolve_objective",
            "missing_duration",
            "parse_error",
            "contamination_flags",
        },
    },
    .{
        .name = "memory_files",
        .description = "File-based memories under ~/.codex/memories",
        .fields = &.{ "path", "relative_path", "name", "category", "extension", "size_bytes", "modified_at", "preview" },
    },
    .{
        .name = "memory_blocks",
        .description = "Heading-delimited memory markdown blocks under ~/.codex/memories",
        .fields = &.{ "path", "relative_path", "doc_kind", "heading_path", "title", "body", "preview", "updated_at", "thread_id", "rollout_path", "keywords" },
    },
    .{
        .name = "memory_stage1_outputs",
        .description = "Codex memory stage-1 outputs joined with thread metadata from the local state DB",
        .fields = &.{ "thread_id", "source_updated_at", "generated_at", "rollout_slug", "usage_count", "last_usage", "selected_for_phase2", "selected_for_phase2_source_updated_at", "rollout_path", "cwd", "git_branch", "source", "title", "memory_mode" },
    },
    .{
        .name = "memory_extensions",
        .description = "Live memory extension directories under ~/.codex/memories/extensions",
        .fields = &.{ "extension_name", "instructions_path", "has_instructions", "modified_at", "size_bytes" },
    },
    .{
        .name = "opencode_prompts",
        .description = "Prompt rows mined from Opencode DB (with JSONL fallback)",
        .fields = &.{
            "source_kind",
            "source_path",
            "source_record_index",
            "session_id",
            "session_slug",
            "session_directory",
            "message_id",
            "message_parent_id",
            "role",
            "mode",
            "prompt_text",
            "prompt_len",
            "prompt_from_summary",
            "prompt_truncated",
            "parts_count",
            "text_parts_count",
            "file_parts_count",
            "part_types",
            "file_paths",
            "time_created_epoch_ms",
            "time_created_iso",
            "time_updated_epoch_ms",
            "time_updated_iso",
            "raw_message_json",
            "raw_parts_json",
        },
    },
    .{
        .name = "opencode_events",
        .description = "Message/part event rows mined from Opencode DB (with JSONL fallback)",
        .fields = &.{
            "source_kind",
            "source_path",
            "source_record_index",
            "session_id",
            "session_slug",
            "session_directory",
            "message_id",
            "message_parent_id",
            "part_id",
            "event_index",
            "role",
            "mode",
            "agent",
            "model_id",
            "provider_id",
            "part_type",
            "tool_name",
            "tool_status",
            "call_id",
            "tool_start_epoch_ms",
            "tool_end_epoch_ms",
            "tool_duration_ms",
            "tool_exit_code",
            "tool_command",
            "tool_output_len",
            "part_time_start_epoch_ms",
            "part_time_end_epoch_ms",
            "has_reasoning_encrypted_content",
            "text",
            "text_len",
            "filename",
            "file_path",
            "mime",
            "time_created_epoch_ms",
            "time_created_iso",
            "time_updated_epoch_ms",
            "time_updated_iso",
            "raw_message_json",
            "raw_part_json",
        },
    },
    .{
        .name = "opencode_tool_calls",
        .description = "Tool-call rows derived from opencode_events",
        .fields = &.{
            "source_kind",
            "source_path",
            "source_record_index",
            "session_id",
            "session_slug",
            "session_directory",
            "message_id",
            "message_parent_id",
            "part_id",
            "event_index",
            "role",
            "mode",
            "agent",
            "model_id",
            "provider_id",
            "tool_name",
            "tool_status",
            "call_id",
            "tool_start_epoch_ms",
            "tool_end_epoch_ms",
            "tool_duration_ms",
            "tool_exit_code",
            "tool_command",
            "tool_output_len",
            "time_created_epoch_ms",
            "time_created_iso",
            "time_updated_epoch_ms",
            "time_updated_iso",
        },
    },
    .{
        .name = "opencode_sessions",
        .description = "Session rollups derived from opencode_events",
        .fields = &.{
            "source_kind",
            "source_path",
            "session_id",
            "session_slug",
            "session_directory",
            "message_count",
            "event_count",
            "tool_event_count",
            "reasoning_event_count",
            "text_event_count",
            "file_event_count",
            "patch_event_count",
            "first_event_epoch_ms",
            "last_event_epoch_ms",
            "duration_ms",
            "last_update_epoch_ms",
        },
    },
};

const Options = struct {
    format: output.Format = .table,
    format_set: bool = false,
    help: bool = false,
    current: bool = false,
    summary: bool = false,
    audit: bool = false,
    show_query: bool = false,
    exclude_current: bool = false,
    next_actions: bool = false,
    latest: bool = false,
    ongoing: bool = false,
    completed: bool = false,
    include_tools: bool = false,
    once: bool = false,
    fail_on_floor: bool = false,
    fail_on_mesh_truth: bool = false,
    fail_on_hang: bool = false,
    strict_hang: bool = true,
    root: ?[]const u8 = null,
    path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    rollout_summary_file: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    dataset: ?[]const u8 = null,
    spec_text: ?[]const u8 = null,
    skill: ?[]const u8 = null,
    history_text: ?[]const u8 = null,
    bucket: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    kind_text: ?[]const u8 = null,
    surface_text: ?[]const u8 = null,
    follow_text: ?[]const u8 = null,
    roles_csv: ?[]const u8 = null,
    contains: ?[]const u8 = null,
    contains_any_text: ?[]const u8 = null,
    contains_all_text: ?[]const u8 = null,
    regex: ?[]const u8 = null,
    role: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    executable_text: ?[]const u8 = null,
    workdir_text: ?[]const u8 = null,
    repo_text: ?[]const u8 = null,
    status: ?[]const u8 = null,
    worker_kind_text: ?[]const u8 = null,
    events_text: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    part_type: ?[]const u8 = null,
    timezone_text: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    last_text: ?[]const u8 = null,
    session: ?[]const u8 = null,
    select_text: ?[]const u8 = null,
    sort_text: ?[]const u8 = null,
    group_by_text: ?[]const u8 = null,
    metric_text: ?[]const u8 = null,
    pricing_text: ?[]const u8 = null,
    model_text: ?[]const u8 = null,
    reasoning_effort_text: ?[]const u8 = null,
    pricing_file: ?[]const u8 = null,
    usd_per_credit_text: ?[]const u8 = null,
    trace_text: ?[]const u8 = null,
    state_db_path: ?[]const u8 = null,
    memory_root_text: ?[]const u8 = null,
    extensions_root_text: ?[]const u8 = null,
    opencode_db_path: ?[]const u8 = null,
    opencode_path: ?[]const u8 = null,
    opencode_source_text: ?[]const u8 = null,
    include_raw: bool = false,
    include_body: bool = false,
    stats: bool = false,
    refresh_pricing: bool = false,
    offline: bool = false,
    force_fast: bool = false,
    force_standard: bool = false,
    strip_skill_blocks: bool = false,
    no_dedupe_exact: bool = false,
    sections: ?[]const u8 = null,
    cue_spec_text: ?[]const u8 = null,
    discovery_skills: ?[]const u8 = null,
    limit: usize = 0,
    floor_threshold: i64 = 3,
    threshold_ms: i64 = 10_000,
    window_hours: i64 = 24,
    duration_gte_seconds: ?i64 = null,
    poll_ms: i64 = 500,
    debounce_ms: i64 = 300,
    workflow: ?[]const u8 = null,
};

pub fn run(
    allocator: std.mem.Allocator,
    cmd: lib.Command,
    args: []const []const u8,
) !void {
    const opts = try parseOptions(args);
    if (opts.help) {
        try printCommandHelp(cmd);
        return;
    }
    if (opts.format_set) try validateFormatForCommand(cmd, opts.format);
    try validateCommandOptions(cmd, opts);

    const sessions_root = try resolveSessionsRoot(allocator, opts.root);
    defer allocator.free(sessions_root);

    switch (cmd) {
        .skills_rank => try cmdSkillsRank(allocator, sessions_root, opts),
        .skill_success_rank => try cmdSkillSuccessRank(allocator, sessions_root, opts),
        .skill_trend => try cmdSkillTrend(allocator, sessions_root, opts),
        .skill_report => try cmdSkillReport(allocator, sessions_root, opts),
        .skill_audit => try QueryLiftCommands.cmdSkillAudit(allocator, sessions_root, opts),
        .skill_blocks => try cmdSkillBlocks(allocator, sessions_root, opts),
        .artifact_search => try cmdArtifactSearch(allocator, sessions_root, opts),
        .tool_audit => try QueryLiftCommands.cmdToolAudit(allocator, sessions_root, opts),
        .memory_inventory => try QueryLiftCommands.cmdMemoryInventory(allocator, sessions_root, opts),
        .message_search => try QueryLiftCommands.cmdMessageSearch(allocator, sessions_root, opts),
        .message_audit => try QueryLiftCommands.cmdMessageAudit(allocator, sessions_root, opts),
        .skill_cohort => try QueryLiftCommands.cmdSkillCohort(allocator, sessions_root, opts),
        .tool_search => try QueryLiftCommands.cmdToolSearch(allocator, sessions_root, opts),
        .memory_extension_audit => try QueryLiftCommands.cmdMemoryExtensionAudit(allocator, sessions_root, opts),
        .token_window => try QueryLiftCommands.cmdTokenWindow(allocator, sessions_root, opts),
        .workdir_report => try QueryLiftCommands.cmdWorkdirReport(allocator, sessions_root, opts),
        .role_breakdown => try cmdRoleBreakdown(allocator, sessions_root, opts),
        .occurrence_export => try cmdOccurrenceExport(allocator, sessions_root, opts),
        .orchestration_concurrency => try cmdOrchestrationConcurrency(allocator, sessions_root, opts),
        .find_session => try cmdFindSession(allocator, sessions_root, opts),
        .plan_search => try cmdPlanSearch(allocator, sessions_root, opts),
        .reply_latency => try cmdReplyLatency(allocator, sessions_root, opts),
        .session_prompts => try cmdSessionPrompts(allocator, sessions_root, opts),
        .report_bundle => try cmdReportBundle(allocator, sessions_root, opts),
        .section_audit => try cmdSectionAudit(allocator, sessions_root, opts),
        .token_usage => try cmdTokenUsage(allocator, sessions_root, opts),
        .token_cost => try cmdTokenCost(allocator, sessions_root, opts),
        .routing_gap => try cmdRoutingGap(allocator, sessions_root, opts),
        .datasets => try cmdDatasets(allocator, opts),
        .dataset_schema => try cmdDatasetSchema(allocator, opts),
        .query => try cmdQuery(allocator, sessions_root, opts),
        .goal_audit => try QueryLiftCommands.cmdGoalAudit(allocator, sessions_root, opts),
        .workflow_audit => try cmdWorkflowAudit(allocator, sessions_root, opts),
        .session_tooling => try cmdSessionTooling(allocator, sessions_root, opts),
        .query_diagnose => try cmdQueryDiagnose(allocator, sessions_root, opts),
        .memory_provenance => try cmdMemoryProvenance(allocator, opts),
        .memory_map => try cmdMemoryMap(allocator, opts),
        .memory_history => try cmdMemoryHistory(allocator, opts),
        .opencode_prompts => try cmdOpencodePrompts(allocator, sessions_root, opts),
        .opencode_events => try cmdOpencodeEvents(allocator, sessions_root, opts),
        .sessions => try cmdTraceSessions(allocator, sessions_root, opts),
        .turns => try cmdTraceTurns(allocator, sessions_root, opts),
        .session_detail => try cmdTraceSessionDetail(allocator, sessions_root, opts),
        .tool_lifecycle => try cmdTraceToolLifecycle(allocator, sessions_root, opts),
        .session_graph => try cmdTraceSessionGraph(allocator, sessions_root, opts),
        .tail => try cmdTraceTail(allocator, sessions_root, opts),
        .unknown => return error.InvalidCommand,
    }
}

fn printCommandHelp(cmd: lib.Command) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    const common =
        \\shared options:
        \\  --format <table|json|csv|jsonl>
        \\  --root <path> (session datasets)
        \\  --output <path>
        \\  --limit|--max|--top <N>
    ;

    const body = switch (cmd) {
        .skills_rank =>
        \\usage: seq skills-rank [--since <iso>] [--until <iso>] [--format table|json|csv] [--max N]
        ,
        .skill_success_rank =>
        \\usage: seq skill-success-rank [--skill <name>] [--mode summary|sessions] [--last <Nm|Nh|Nd>|--since <iso>] [--until <iso>] [--limit N] [--format table|json|csv|jsonl]
        ,
        .skill_trend =>
        \\usage: seq skill-trend --skill <name> [--bucket day|week|month] [--since <iso>] [--until <iso>] [--format table|json|csv] [--max N]
        ,
        .skill_report =>
        \\usage: seq skill-report --skill <name> [--since <iso>] [--until <iso>]
        ,
        .skill_audit =>
        \\usage: seq skill-audit [--skill <name>] [--mode summary|mentions|trend] [--roles <csv>] [--since <iso>] [--until <iso>] [--limit N] [--format table|json|csv|jsonl]
        ,
        .skill_blocks =>
        \\usage: seq skill-blocks --skill <name> [--history <distinct|all|latest>] [--session-id <id>|--path <jsonl>|--current] [--since <iso>] [--until <iso>] [--limit N] [--format json|jsonl]
        ,
        .artifact_search =>
        \\usage: seq artifact-search [--contains <text>|--regex <expr>] [--kind <auto|session|memory|orchestration|tooling|prompt>] [--surface <auto|messages|tool_calls|memory_blocks>] [--roles <csv>] [--tool <name>] [--workdir <path>] [--session-id <id>|--path <jsonl>] [--since <iso>] [--until <iso>] [--follow <none|auto>] [--strip-skill-blocks] [--no-dedupe-exact] [--stats] [--limit N] [--format table|json|csv|jsonl]
        ,
        .tool_audit =>
        \\usage: seq tool-audit [--mode summary|rows|args|unresolved] [--group-by executable|tool|session|workdir|command] [--tool <name>] [--executable <name>] [--workdir <path>] [--contains <text>] [--since <iso>] [--until <iso>] [--limit N] [--format table|json|csv|jsonl]
        ,
        .memory_inventory =>
        \\usage: seq memory-inventory [--mode categories|files|blocks|stage1|extensions] [--memory-root <path>] [--extensions-root <path>] [--state-db-path <path>] [--contains <text>|--regex <expr>] [--limit N] [--format table|json|csv|jsonl]
        ,
        .message_search =>
        \\usage: seq message-search [--contains <text>|--regex <expr>|--contains-any <csv>|--contains-all <csv>] [--roles <csv>] [--since <iso>] [--until <iso>] [--limit N] [--format table|json|csv|jsonl]
        ,
        .message_audit =>
        \\usage: seq message-audit [--mode summary|rows|sessions] [--contains <text>|--regex <expr>|--contains-any <csv>|--contains-all <csv>] [--roles <csv>] [--since <iso>] [--until <iso>] [--exclude-current] [--show-query] [--limit N] [--format table|json|csv|jsonl]
        ,
        .skill_cohort =>
        \\usage: seq skill-cohort [--skill <name>] [--mode summary|cohort|mentions] [--roles <csv>] [--contains <text>|--regex <expr>|--contains-any <csv>] [--since <iso>] [--until <iso>] [--exclude-current] [--show-query] [--limit N] [--format table|json|csv|jsonl]
        ,
        .tool_search =>
        \\usage: seq tool-search [--mode rows|summary|args] [--group-by executable|tool|session|workdir|command] [--tool <name>] [--executable <name>] [--workdir <path>] [--contains <text>|--regex <expr>] [--since <iso>] [--until <iso>] [--exclude-current] [--show-query] [--limit N] [--format table|json|csv|jsonl]
        ,
        .memory_extension_audit =>
        \\usage: seq memory-extension-audit [--mode summary|rows] [--extensions-root <path>] [--contains <text>|--regex <expr>] [--show-query] [--limit N] [--format table|json|csv|jsonl]
        ,
        .token_window =>
        \\usage: seq token-window [--mode summary|rows] [--window-hours N] [--since <iso>] [--until <iso>] [--path <jsonl>] [--exclude-current] [--show-query] [--format table|json|csv|jsonl]
        ,
        .workdir_report =>
        \\usage: seq workdir-report [--workdir <path>] [--mode summary|sessions] [--contains <text>] [--contains-any <csv>] [--since <iso>] [--until <iso>] [--limit N] [--format table|json|csv|jsonl]
        ,
        .role_breakdown =>
        \\usage: seq role-breakdown [--since <iso>] [--until <iso>] [--format table|json|csv] [--max N]
        ,
        .occurrence_export =>
        \\usage: seq occurrence-export [--skill <name>] [--since <iso>] [--until <iso>] [--format jsonl|json|csv] [--max N]
        ,
        .orchestration_concurrency =>
        \\usage: seq orchestration-concurrency [--session-id <id>|--path <jsonl>] [--format table|json|csv|jsonl] [--floor-threshold N] [--fail-on-floor] [--fail-on-mesh-truth]
        ,
        .find_session =>
        \\usage: seq find-session --prompt <text> [--since <iso>] [--until <iso>] [--limit N] [--format table|json|csv|jsonl]
        ,
        .plan_search =>
        \\usage: seq plan-search [--repo <path>] [--session-id <id>|--path <jsonl>] [--since <iso>] [--until <iso>] [--contains <text>|--regex <expr>] [--sort timestamp|-timestamp] [--include-body] [--stats] [--limit N] [--format table|json|csv|jsonl]
        \\extra options:
        \\  --repo <path>             Match session_meta cwd against this repo root or one of its descendants
        \\  --path <path>             Inspect exactly one rollout/session JSONL file
        \\  --session-id <id>         Resolve exactly one session file by session id substring
        \\  --contains <text>         Filter title+plan body by case-insensitive substring
        \\  --regex <expr>            Filter title+plan body by the artifact-search regex subset
        \\  --sort timestamp|-timestamp
        \\                           Order oldest-first or newest-first (default: -timestamp)
        \\  --include-body            Include the exact <proposed_plan> block in output rows
        \\  --stats                   Emit scan counters and filter-usage flags
        ,
        .reply_latency =>
        \\usage: seq reply-latency [--session-id <id>|--path <jsonl>|--current] [--mode single-message|contiguous] [--since <iso>] [--until <iso>] [--limit N] [--format table|json|csv|jsonl]
        \\extra options:
        \\  --path <path>              Inspect exactly one rollout/session JSONL file
        \\  --session-id <id>          Resolve exactly one session file by session id substring
        \\  --current                  Resolve current session via CODEX_THREAD_ID
        \\  --mode <name>              single-message (default) | contiguous
        ,
        .session_prompts =>
        \\usage: seq session-prompts [--session-id <id>|--path <jsonl>|--current] [--roles <csv>] [--since <iso>] [--until <iso>] [--strip-skill-blocks] [--no-dedupe-exact] [--limit N] [--format table|json|csv|jsonl]
        \\extra options:
        \\  --path <path>              Inspect exactly one rollout/session JSONL file
        \\  --session-id <id>          Resolve exactly one session file by session id substring
        \\  --current                  Resolve current session via CODEX_THREAD_ID
        \\  --roles <csv>              user | assistant | user,assistant
        \\  --strip-skill-blocks       Remove <skill>...</skill> envelopes before output
        \\  --no-dedupe-exact          Keep duplicated role+text rows
        ,
        .report_bundle =>
        \\usage: seq report-bundle [--since <iso>] [--until <iso>] [--top N]
        ,
        .section_audit =>
        \\usage: seq section-audit --sections <csv> [--since <iso>] [--until <iso>]
        ,
        .token_usage =>
        \\usage: seq token-usage [--last <Nm|Nh|Nd>|--since <iso>] [--until <iso>] [--path <jsonl>|--session-id <id>] [--group-by day|path] [--tz utc|local|+HH:MM|-HH:MM] [--summary] [--audit] [--top N] [--format table|json|csv|jsonl]
        \\extra options:
        \\  --last <duration>          Rolling window ending at --until or now; examples: 90m, 24h, 7d
        \\  --path <path>              Restrict the report to one rollout/session JSONL file
        \\  --session-id <id>          Restrict the report to one session file by session id substring
        \\  --group-by <name>          day (default) | path
        \\  --tz <name>                utc (default) | local | +HH:MM | -HH:MM
        \\  --summary                  Emit one summary row with totals and averages
        \\  --audit                    Emit self-auditing token accounting proof fields
        ,
        .token_cost =>
        \\usage: seq token-cost [--last <Nm|Nh|Nd>|--since <iso>] [--until <iso>] [--path <jsonl>|--session-id <id>] [--group-by day|path|model|fast_mode] [--tz utc|local|+HH:MM|-HH:MM] [--summary] [--audit] [--pricing codex|api] [--model <name>] [--pricing-file <json>] [--refresh-pricing] [--offline] [--usd-per-credit <amount>] [--force-fast|--force-standard] [--format table|json|csv|jsonl]
        \\extra options:
        \\  --last <duration>           Rolling window ending at --until or now; examples: 90m, 24h, 7d
        \\  --pricing <kind>            codex (default credit pricing) | api (exact OpenAI API USD pricing)
        \\  --model <name>              Override trace model when pricing API rates
        \\  --pricing-file <json>       Load rates from an explicit JSON pricing file
        \\  --refresh-pricing           Refresh current OpenAI Codex pricing into the user cache
        \\  --offline                   Do not use network refresh; require explicit/bundled pricing
        \\  --usd-per-credit <amount>   Convert estimated credits to USD using this user-supplied rate
        \\  --force-fast                Price all supported rows with fast-mode multipliers and mark source override
        \\  --force-standard            Price all rows at standard rate and mark source override
        ,
        .routing_gap =>
        \\usage: seq routing-gap --cue-spec <json|@path> [--discovery-skills <csv>] [--format table|json|csv|jsonl]
        ,
        .datasets =>
        \\usage: seq datasets
        ,
        .dataset_schema =>
        \\usage: seq dataset-schema --dataset <name>
        ,
        .query =>
        \\usage: seq query --spec <json|@path>
        ,
        .goal_audit =>
        \\usage: seq goal-audit [--mode summary|rows] [--workflow review|resolve|review,resolve] [--duration-gte <seconds|minutes|hours>] [--status <name>] [--contains <text>] [--since <iso>] [--until <iso>] [--path <jsonl>|--session-id <id>] [--exclude-current] [--show-query] [--limit N] [--format table|json|csv|jsonl]
        ,
        .workflow_audit =>
        \\usage: seq workflow-audit --workflow <name> [--mode summary|signals|outcomes|sessions|report] [--since <iso>] [--until <iso>] [--workdir <path>] [--limit N] [--format table|json|markdown]
        ,
        .session_tooling =>
        \\usage: seq session-tooling [--session-id <id>|--path <jsonl>] [--since <iso>] [--until <iso>] [--group-by executable|command|tool] [--summary] [--limit N] [--format table|json|csv|jsonl]
        ,
        .query_diagnose =>
        \\usage: seq query-diagnose [--session-id <id>|--path <jsonl>] [--since <iso>] [--until <iso>] [--threshold-ms N] [--strict-hang] [--fail-on-hang] [--next-actions] [--summary] [--format table|json|csv|jsonl]
        ,
        .memory_provenance =>
        \\usage: seq memory-provenance (--thread-id <id> | --rollout-summary-file <path>) [--state-db-path <path>] [--memory-root <path>] [--extensions-root <path>] [--trace none|auto|always] [--format table|json|csv|jsonl]
        ,
        .memory_map =>
        \\usage: seq memory-map (--thread-id <id> | --contains <text> | --regex <expr>) [--memory-root <path>] [--extensions-root <path>] [--since <iso>] [--until <iso>] [--trace none|auto|always] [--limit N] [--format table|json|csv|jsonl]
        ,
        .memory_history =>
        \\usage: seq memory-history (--thread-id <id> | --contains <text> | --regex <expr>) [--state-db-path <path>] [--memory-root <path>] [--extensions-root <path>] [--since <iso>] [--until <iso>] [--trace none|auto|always] [--limit N] [--format table|json|csv|jsonl]
        ,
        .opencode_prompts =>
        \\usage: seq opencode-prompts [--spec <json|@path>] [--contains <text>] [--regex <expr>] [--session <id|slug>] [--since <epoch-ms|iso>] [--until <epoch-ms|iso>] [--latest] [--mode <name>] [--part-type <name>] [--group-by <csv>] [--metric <csv>] [--select <csv>] [--sort <csv>] [--source auto|db|jsonl] [--opencode-db-path <path>] [--opencode-path <path>] [--include-raw] [--limit N] [--format table|json|csv|jsonl]
        ,
        .opencode_events =>
        \\usage: seq opencode-events [--spec <json|@path>] [--contains <text>] [--regex <expr>] [--session <id|slug>] [--since <epoch-ms|iso>] [--until <epoch-ms|iso>] [--latest] [--role <name>] [--mode <name>] [--part-type <name>] [--tool <name>] [--status <name>] [--group-by <csv>] [--metric <csv>] [--select <csv>] [--sort <csv>] [--source auto|db|jsonl] [--opencode-db-path <path>] [--opencode-path <path>] [--include-raw] [--limit N] [--format table|json|csv|jsonl]
        ,
        .sessions =>
        \\usage: seq sessions [--root <path>] [--since <iso>] [--until <iso>] [--repo <path>] [--contains <text>] [--ongoing|--completed] [--worker-kind all|none|inline|external] [--limit N] [--format table|json|jsonl]
        ,
        .turns =>
        \\usage: seq turns [--path <jsonl>|--session-id <id>|--root <path>] [--since <iso>] [--until <iso>] [--status complete|aborted|ongoing|error] [--contains <text>] [--include-tools] [--limit N] [--format table|json|jsonl]
        ,
        .session_detail =>
        \\usage: seq session-detail (--path <jsonl>|--session-id <id>) [--include-tools] [--format json|markdown]
        ,
        .tool_lifecycle =>
        \\usage: seq tool-lifecycle (--path <jsonl>|--session-id <id>) [--include-raw] [--format table|json|jsonl]
        ,
        .session_graph =>
        \\usage: seq session-graph --session-id <id> [--root <path>] [--include-tools] [--format table|json|dot]
        ,
        .tail =>
        \\usage: seq tail (--current|--path <jsonl>|--session-id <id>) [--events raw,turns,tools,tokens,status] [--poll-ms N] [--debounce-ms N] [--once] [--format table|jsonl]
        ,
        .unknown =>
        \\usage: seq <command> --help
        ,
    };

    try stdout.writeAll(body);
    try stdout.writeByte('\n');
    try stdout.writeAll(common);
    try stdout.writeByte('\n');
}

fn printCliError(comptime fmt: []const u8, args: anytype) void {
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stderr = &stderr_writer.interface;
    stderr.print(fmt, args) catch {};
}

fn unsupportedOption(option: []const u8, cmd: lib.Command) !void {
    printCliError("error: option {s} is not supported for {s}\n", .{ option, @tagName(cmd) });
    return error.UnsupportedOption;
}

fn ensureOptionAllowed(flag_set: bool, allowed: bool, option: []const u8, cmd: lib.Command) !void {
    if (flag_set and !allowed) {
        try unsupportedOption(option, cmd);
    }
}

fn commandSupportsSummary(cmd: lib.Command) bool {
    const name = @tagName(cmd);
    return std.mem.eql(u8, name, "session_tooling") or
        std.mem.eql(u8, name, "query_diagnose") or
        std.mem.eql(u8, name, "token_usage") or
        std.mem.eql(u8, name, "token_cost") or
        std.mem.eql(u8, name, "goal_audit");
}

fn validateFormatForCommand(cmd: lib.Command, fmt: output.Format) !void {
    switch (cmd) {
        .skills_rank, .skill_trend, .skill_report, .role_breakdown, .report_bundle, .section_audit, .datasets, .dataset_schema => {
            if (fmt == .jsonl or fmt == .markdown or fmt == .dot) return error.InvalidFormatForCommand;
        },
        .skill_blocks => {
            if (fmt != .json and fmt != .jsonl) return error.InvalidFormatForCommand;
        },
        .occurrence_export => {
            if (fmt == .table or fmt == .markdown or fmt == .dot) return error.InvalidFormatForCommand;
        },
        .session_detail => {
            if (fmt != .json and fmt != .markdown) return error.InvalidFormatForCommand;
        },
        .session_graph => {
            if (fmt == .csv or fmt == .markdown) return error.InvalidFormatForCommand;
        },
        .workflow_audit => {
            if (fmt == .csv or fmt == .jsonl or fmt == .dot) return error.InvalidFormatForCommand;
        },
        .sessions, .turns, .tool_lifecycle, .tail => {
            if (fmt == .csv or fmt == .markdown or fmt == .dot) return error.InvalidFormatForCommand;
        },
        .query => {},
        .artifact_search, .tool_audit, .memory_inventory, .message_search, .message_audit, .skill_cohort, .tool_search, .memory_extension_audit, .token_window, .workdir_report, .orchestration_concurrency, .find_session, .plan_search, .reply_latency, .session_prompts, .token_usage, .token_cost, .routing_gap, .session_tooling, .query_diagnose, .memory_provenance, .memory_map, .memory_history, .opencode_prompts, .opencode_events, .skill_audit, .skill_success_rank, .goal_audit => {
            if (fmt == .markdown or fmt == .dot) return error.InvalidFormatForCommand;
        },
        .unknown => return error.InvalidCommand,
    }
}

fn validateCommandOptions(cmd: lib.Command, opts: Options) !void {
    const supports_current = cmd == .session_prompts or cmd == .reply_latency or cmd == .skill_blocks or cmd == .tail;
    const supports_roles_csv = cmd == .session_prompts or cmd == .artifact_search or cmd == .skill_audit or cmd == .message_search or cmd == .message_audit or cmd == .skill_cohort;
    const supports_strip_skill_blocks = cmd == .session_prompts or cmd == .artifact_search;
    const supports_no_dedupe_exact = cmd == .session_prompts or cmd == .artifact_search;
    const supports_audit = cmd == .token_usage or cmd == .token_cost;
    const supports_next_actions = cmd == .query_diagnose;
    const supports_latest = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_floor_threshold = cmd == .orchestration_concurrency;
    const supports_fail_on_floor = cmd == .orchestration_concurrency;
    const supports_fail_on_mesh_truth = cmd == .orchestration_concurrency;
    const supports_fail_on_hang = cmd == .query_diagnose;
    const supports_threshold_ms = cmd == .query_diagnose;
    const supports_strict_hang = cmd == .query_diagnose;
    const supports_skill = switch (cmd) {
        .skill_trend, .skill_report, .skill_audit, .skill_success_rank, .skill_cohort, .occurrence_export, .skill_blocks => true,
        else => false,
    };
    const supports_workflow = cmd == .workflow_audit or cmd == .goal_audit;
    const supports_history = cmd == .skill_blocks;
    const supports_bucket = cmd == .skill_trend;
    const supports_prompt = cmd == .find_session;
    const supports_sections = cmd == .section_audit;
    const supports_cue_spec = cmd == .routing_gap;
    const supports_discovery_skills = cmd == .routing_gap;
    const supports_dataset = cmd == .dataset_schema;
    const supports_spec_text = switch (cmd) {
        .query, .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_contains = switch (cmd) {
        .artifact_search, .tool_audit, .memory_inventory, .message_search, .message_audit, .skill_cohort, .tool_search, .memory_extension_audit, .workdir_report, .plan_search, .memory_map, .memory_history, .opencode_prompts, .opencode_events, .sessions, .turns, .goal_audit => true,
        else => false,
    };
    const supports_contains_any = cmd == .message_search or cmd == .message_audit or cmd == .skill_cohort or cmd == .workdir_report;
    const supports_contains_all = cmd == .message_search or cmd == .message_audit;
    const supports_regex = switch (cmd) {
        .artifact_search, .memory_inventory, .message_search, .message_audit, .skill_cohort, .tool_search, .memory_extension_audit, .plan_search, .memory_map, .memory_history, .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_role = cmd == .opencode_events;
    const supports_tool = cmd == .opencode_events or cmd == .artifact_search or cmd == .tool_audit or cmd == .tool_search;
    const supports_executable = cmd == .tool_audit or cmd == .tool_search;
    const supports_workdir = cmd == .artifact_search or cmd == .tool_audit or cmd == .tool_search or cmd == .workdir_report or cmd == .workflow_audit;
    const supports_repo = cmd == .plan_search or cmd == .sessions;
    const supports_status = cmd == .opencode_events or cmd == .turns or cmd == .goal_audit;
    const supports_mode = switch (cmd) {
        .opencode_prompts, .opencode_events, .reply_latency, .skill_audit, .skill_success_rank, .message_audit, .skill_cohort, .tool_audit, .tool_search, .memory_inventory, .memory_extension_audit, .token_window, .workdir_report, .workflow_audit, .goal_audit => true,
        else => false,
    };
    const supports_kind = cmd == .artifact_search;
    const supports_surface = cmd == .artifact_search;
    const supports_follow = cmd == .artifact_search;
    const supports_stats = cmd == .artifact_search or cmd == .plan_search;
    const supports_include_body = cmd == .plan_search;
    const supports_part_type = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_since = switch (cmd) {
        .skills_rank,
        .skill_success_rank,
        .skill_trend,
        .skill_report,
        .skill_audit,
        .role_breakdown,
        .occurrence_export,
        .find_session,
        .artifact_search,
        .tool_audit,
        .message_search,
        .message_audit,
        .skill_cohort,
        .tool_search,
        .workdir_report,
        .plan_search,
        .reply_latency,
        .session_prompts,
        .report_bundle,
        .section_audit,
        .token_usage,
        .token_cost,
        .token_window,
        .session_tooling,
        .query_diagnose,
        .workflow_audit,
        .goal_audit,
        .memory_map,
        .memory_history,
        .skill_blocks,
        .opencode_prompts,
        .opencode_events,
        .sessions,
        .turns,
        => true,
        else => false,
    };
    const supports_until = switch (cmd) {
        .skills_rank,
        .skill_success_rank,
        .skill_trend,
        .skill_report,
        .skill_audit,
        .role_breakdown,
        .occurrence_export,
        .find_session,
        .artifact_search,
        .tool_audit,
        .message_search,
        .message_audit,
        .skill_cohort,
        .tool_search,
        .workdir_report,
        .plan_search,
        .reply_latency,
        .session_prompts,
        .report_bundle,
        .section_audit,
        .token_usage,
        .token_cost,
        .token_window,
        .session_tooling,
        .query_diagnose,
        .workflow_audit,
        .goal_audit,
        .memory_map,
        .memory_history,
        .skill_blocks,
        .opencode_prompts,
        .opencode_events,
        .sessions,
        .turns,
        => true,
        else => false,
    };
    const supports_session = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_group_by = switch (cmd) {
        .session_tooling, .tool_audit, .tool_search, .opencode_prompts, .opencode_events, .token_usage, .token_cost => true,
        else => false,
    };
    const supports_timezone = switch (cmd) {
        .token_usage, .token_cost => true,
        else => false,
    };
    const supports_metric = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_select = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_sort = switch (cmd) {
        .plan_search, .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_opencode_db_path = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_opencode_path = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_opencode_source = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_include_raw = switch (cmd) {
        .opencode_prompts, .opencode_events, .session_detail, .tool_lifecycle, .tail => true,
        else => false,
    };
    const supports_thread_id = cmd == .memory_provenance or cmd == .memory_map or cmd == .memory_history;
    const supports_rollout_summary_file = cmd == .memory_provenance;
    const supports_trace = cmd == .memory_provenance or cmd == .memory_map or cmd == .memory_history;
    const supports_show_query = switch (cmd) {
        .skill_audit,
        .tool_audit,
        .memory_inventory,
        .message_search,
        .message_audit,
        .skill_cohort,
        .tool_search,
        .memory_extension_audit,
        .token_window,
        .workdir_report,
        .goal_audit,
        => true,
        else => false,
    };
    const supports_exclude_current = switch (cmd) {
        .message_audit, .skill_cohort, .tool_search, .token_window, .goal_audit => true,
        else => false,
    };
    const supports_window_hours = cmd == .token_window;
    const supports_duration_gte = cmd == .goal_audit;
    const supports_last = cmd == .token_usage or cmd == .token_cost or cmd == .skill_success_rank;
    const supports_token_cost_options = cmd == .token_cost;

    try ensureOptionAllowed(opts.path != null, commandSupportsPath(cmd), "--path", cmd);
    try ensureOptionAllowed(opts.session_id != null, commandSupportsSessionId(cmd), "--session-id", cmd);
    try ensureOptionAllowed(opts.current, supports_current, "--current", cmd);
    try ensureOptionAllowed(opts.roles_csv != null, supports_roles_csv, "--roles", cmd);
    try ensureOptionAllowed(opts.strip_skill_blocks, supports_strip_skill_blocks, "--strip-skill-blocks", cmd);
    try ensureOptionAllowed(opts.no_dedupe_exact, supports_no_dedupe_exact, "--no-dedupe-exact", cmd);
    try ensureOptionAllowed(opts.summary, commandSupportsSummary(cmd), "--summary", cmd);
    try ensureOptionAllowed(opts.audit, supports_audit, "--audit", cmd);
    try ensureOptionAllowed(opts.show_query, supports_show_query, "--show-query", cmd);
    try ensureOptionAllowed(opts.exclude_current, supports_exclude_current, "--exclude-current", cmd);
    try ensureOptionAllowed(opts.next_actions, supports_next_actions, "--next-actions", cmd);
    try ensureOptionAllowed(opts.latest, supports_latest, "--latest", cmd);
    try ensureOptionAllowed(opts.floor_threshold != 3, supports_floor_threshold, "--floor-threshold", cmd);
    try ensureOptionAllowed(opts.fail_on_floor, supports_fail_on_floor, "--fail-on-floor", cmd);
    try ensureOptionAllowed(opts.fail_on_mesh_truth, supports_fail_on_mesh_truth, "--fail-on-mesh-truth", cmd);
    try ensureOptionAllowed(opts.fail_on_hang, supports_fail_on_hang, "--fail-on-hang", cmd);
    try ensureOptionAllowed(opts.threshold_ms != 10_000, supports_threshold_ms, "--threshold-ms", cmd);
    try ensureOptionAllowed(opts.window_hours != 24, supports_window_hours, "--window-hours", cmd);
    try ensureOptionAllowed(opts.duration_gte_seconds != null, supports_duration_gte, "--duration-gte", cmd);
    try ensureOptionAllowed(!opts.strict_hang, supports_strict_hang, "--no-strict-hang", cmd);
    try ensureOptionAllowed(opts.skill != null, supports_skill, "--skill", cmd);
    try ensureOptionAllowed(opts.workflow != null, supports_workflow, "--workflow", cmd);
    try ensureOptionAllowed(opts.history_text != null, supports_history, "--history", cmd);
    try ensureOptionAllowed(opts.bucket != null, supports_bucket, "--bucket", cmd);
    try ensureOptionAllowed(opts.prompt != null, supports_prompt, "--prompt", cmd);
    try ensureOptionAllowed(opts.sections != null, supports_sections, "--sections", cmd);
    try ensureOptionAllowed(opts.cue_spec_text != null, supports_cue_spec, "--cue-spec", cmd);
    try ensureOptionAllowed(opts.discovery_skills != null, supports_discovery_skills, "--discovery-skills", cmd);
    try ensureOptionAllowed(opts.dataset != null, supports_dataset, "--dataset", cmd);
    try ensureOptionAllowed(opts.spec_text != null, supports_spec_text, "--spec", cmd);
    try ensureOptionAllowed(opts.contains != null, supports_contains, "--contains", cmd);
    try ensureOptionAllowed(opts.contains_any_text != null, supports_contains_any, "--contains-any", cmd);
    try ensureOptionAllowed(opts.contains_all_text != null, supports_contains_all, "--contains-all", cmd);
    try ensureOptionAllowed(opts.regex != null, supports_regex, "--regex", cmd);
    try ensureOptionAllowed(opts.role != null, supports_role, "--role", cmd);
    try ensureOptionAllowed(opts.tool != null, supports_tool, "--tool", cmd);
    try ensureOptionAllowed(opts.executable_text != null, supports_executable, "--executable", cmd);
    try ensureOptionAllowed(opts.workdir_text != null, supports_workdir, "--workdir", cmd);
    try ensureOptionAllowed(opts.repo_text != null, supports_repo, "--repo", cmd);
    try ensureOptionAllowed(opts.status != null, supports_status, "--status", cmd);
    try ensureOptionAllowed(opts.mode != null, supports_mode, "--mode", cmd);
    try ensureOptionAllowed(opts.kind_text != null, supports_kind, "--kind", cmd);
    try ensureOptionAllowed(opts.surface_text != null, supports_surface, "--surface", cmd);
    try ensureOptionAllowed(opts.follow_text != null, supports_follow, "--follow", cmd);
    try ensureOptionAllowed(opts.stats, supports_stats, "--stats", cmd);
    try ensureOptionAllowed(opts.include_body, supports_include_body, "--include-body", cmd);
    try ensureOptionAllowed(opts.part_type != null, supports_part_type, "--part-type", cmd);
    try ensureOptionAllowed(opts.timezone_text != null, supports_timezone, "--tz", cmd);
    try ensureOptionAllowed(opts.since != null, supports_since, "--since", cmd);
    try ensureOptionAllowed(opts.until != null, supports_until, "--until", cmd);
    try ensureOptionAllowed(opts.last_text != null, supports_last, "--last", cmd);
    try ensureOptionAllowed(opts.session != null, supports_session, "--session", cmd);
    try ensureOptionAllowed(opts.group_by_text != null, supports_group_by, "--group-by", cmd);
    try ensureOptionAllowed(opts.metric_text != null, supports_metric, "--metric", cmd);
    try ensureOptionAllowed(opts.select_text != null, supports_select, "--select", cmd);
    try ensureOptionAllowed(opts.sort_text != null, supports_sort, "--sort", cmd);
    try ensureOptionAllowed(opts.opencode_db_path != null, supports_opencode_db_path, "--opencode-db-path", cmd);
    try ensureOptionAllowed(opts.opencode_path != null, supports_opencode_path, "--opencode-path", cmd);
    try ensureOptionAllowed(opts.opencode_source_text != null, supports_opencode_source, "--source", cmd);
    try ensureOptionAllowed(opts.include_raw, supports_include_raw, "--include-raw", cmd);
    try ensureOptionAllowed(opts.ongoing, cmd == .sessions, "--ongoing", cmd);
    try ensureOptionAllowed(opts.completed, cmd == .sessions, "--completed", cmd);
    try ensureOptionAllowed(opts.include_tools, cmd == .turns or cmd == .session_detail, "--include-tools", cmd);
    try ensureOptionAllowed(opts.once, cmd == .tail, "--once", cmd);
    try ensureOptionAllowed(opts.worker_kind_text != null, cmd == .sessions, "--worker-kind", cmd);
    try ensureOptionAllowed(opts.events_text != null, cmd == .tail, "--events", cmd);
    try ensureOptionAllowed(opts.poll_ms != 500, cmd == .tail, "--poll-ms", cmd);
    try ensureOptionAllowed(opts.debounce_ms != 300, cmd == .tail, "--debounce-ms", cmd);
    try ensureOptionAllowed(opts.thread_id != null, supports_thread_id, "--thread-id", cmd);
    try ensureOptionAllowed(opts.rollout_summary_file != null, supports_rollout_summary_file, "--rollout-summary-file", cmd);
    try ensureOptionAllowed(opts.trace_text != null, supports_trace, "--trace", cmd);
    try ensureOptionAllowed(opts.state_db_path != null, commandSupportsStateDbPath(cmd), "--state-db-path", cmd);
    try ensureOptionAllowed(opts.memory_root_text != null, commandSupportsMemoryRoot(cmd), "--memory-root", cmd);
    try ensureOptionAllowed(opts.extensions_root_text != null, commandSupportsExtensionsRoot(cmd), "--extensions-root", cmd);
    try ensureOptionAllowed(opts.pricing_text != null, supports_token_cost_options, "--pricing", cmd);
    try ensureOptionAllowed(opts.model_text != null, supports_token_cost_options, "--model", cmd);
    try ensureOptionAllowed(opts.reasoning_effort_text != null, supports_token_cost_options, "--reasoning-effort", cmd);
    try ensureOptionAllowed(opts.pricing_file != null, supports_token_cost_options, "--pricing-file", cmd);
    try ensureOptionAllowed(opts.usd_per_credit_text != null, supports_token_cost_options, "--usd-per-credit", cmd);
    try ensureOptionAllowed(opts.refresh_pricing, supports_token_cost_options, "--refresh-pricing", cmd);
    try ensureOptionAllowed(opts.offline, supports_token_cost_options, "--offline", cmd);
    try ensureOptionAllowed(opts.force_fast, supports_token_cost_options, "--force-fast", cmd);
    try ensureOptionAllowed(opts.force_standard, supports_token_cost_options, "--force-standard", cmd);

    if (opts.ongoing and opts.completed) return error.InvalidModeArg;
    if (opts.force_fast and opts.force_standard) return error.InvalidModeArg;
    if (opts.last_text != null and opts.since != null) {
        printCliError("error: --last cannot be combined with --since\n", .{});
        return error.InvalidModeArg;
    }
    if (opts.worker_kind_text) |text| {
        if (!isValidTraceWorkerKind(text)) return error.InvalidModeArg;
    }
    if (cmd == .turns) {
        if (opts.status) |text| {
            if (!isValidTraceTurnStatus(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .skill_audit) {
        if (opts.mode) |text| {
            if (!isValidSkillAuditMode(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .message_audit) {
        if (opts.mode) |text| {
            if (!isValidMessageAuditMode(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .skill_cohort) {
        if (opts.mode) |text| {
            if (!isValidSkillCohortMode(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .tool_audit) {
        if (opts.mode) |text| {
            if (!isValidToolAuditMode(text)) return error.InvalidModeArg;
        }
        if (opts.group_by_text) |text| {
            if (!isValidToolAuditGroupBy(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .tool_search) {
        if (opts.mode) |text| {
            if (!isValidToolSearchMode(text)) return error.InvalidModeArg;
        }
        if (opts.group_by_text) |text| {
            if (!isValidToolAuditGroupBy(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .memory_inventory) {
        if (opts.mode) |text| {
            if (!isValidMemoryInventoryMode(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .memory_extension_audit) {
        if (opts.mode) |text| {
            if (!isValidMemoryExtensionAuditMode(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .token_window) {
        if (opts.mode) |text| {
            if (!isValidTokenWindowMode(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .workdir_report) {
        if (opts.mode) |text| {
            if (!isValidWorkdirReportMode(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .workflow_audit) {
        if (opts.mode) |text| {
            if (!isValidWorkflowAuditMode(text)) return error.InvalidModeArg;
        }
    }
    if (cmd == .goal_audit) {
        if (opts.mode) |text| {
            if (!isValidGoalAuditMode(text)) return error.InvalidModeArg;
        }
        if (opts.workflow) |text| {
            if (!isValidGoalAuditWorkflowCsv(text)) return error.InvalidModeArg;
        }
    }
    if (opts.events_text) |text| _ = try parseTailEventMask(text);
}

fn commandSupportsPath(cmd: lib.Command) bool {
    return switch (cmd) {
        .artifact_search,
        .orchestration_concurrency,
        .plan_search,
        .reply_latency,
        .session_prompts,
        .session_tooling,
        .query_diagnose,
        .skill_blocks,
        .token_usage,
        .token_cost,
        .token_window,
        .goal_audit,
        .turns,
        .session_detail,
        .tool_lifecycle,
        .session_graph,
        .tail,
        => true,
        else => false,
    };
}

fn commandSupportsSessionId(cmd: lib.Command) bool {
    return switch (cmd) {
        .artifact_search,
        .orchestration_concurrency,
        .plan_search,
        .reply_latency,
        .session_prompts,
        .session_tooling,
        .skill_blocks,
        .token_usage,
        .token_cost,
        .goal_audit,
        .turns,
        .session_detail,
        .tool_lifecycle,
        .session_graph,
        .tail,
        => true,
        else => false,
    };
}

fn commandSupportsStateDbPath(cmd: lib.Command) bool {
    return cmd == .memory_provenance or cmd == .memory_history or cmd == .memory_inventory;
}

fn commandSupportsMemoryRoot(cmd: lib.Command) bool {
    return cmd == .memory_provenance or cmd == .memory_map or cmd == .memory_history or cmd == .memory_inventory;
}

fn commandSupportsExtensionsRoot(cmd: lib.Command) bool {
    return cmd == .memory_provenance or cmd == .memory_map or cmd == .memory_history or cmd == .memory_inventory or cmd == .memory_extension_audit;
}

const trace_session_columns = [_][]const u8{ "start_time", "end_time", "status", "session_id", "thread_name", "cwd", "git_branch", "model", "turn_count", "total_tokens", "worker_kind", "spawned_worker_count", "path" };
const trace_turn_columns = [_][]const u8{ "started_at", "duration_ms", "status", "turn_index", "user_preview", "assistant_preview", "model", "tool_count", "total_tokens", "path" };
const trace_turn_tool_columns = [_][]const u8{ "started_at", "duration_ms", "status", "turn_index", "user_preview", "assistant_preview", "model", "tool_count", "total_tokens", "tools_json", "path" };
const trace_tool_columns = [_][]const u8{ "turn_index", "kind", "tool_name", "lifecycle_status", "exit_code", "duration_ms", "cwd", "command_text", "mcp_server", "mcp_tool", "call_id" };
const trace_graph_columns = [_][]const u8{ "parent_session_id", "worker_session_id", "agent_nickname", "agent_role", "model", "worker_status", "spawned_at", "worker_path" };
const trace_tail_columns = [_][]const u8{ "event", "session_id", "turn_id", "turn_index", "kind", "lifecycle_status", "duration_ms", "total_tokens", "path", "line_number", "entry_type", "event_type", "status_reason" };

const TailEventMask = struct {
    raw: bool = false,
    turns: bool = false,
    tools: bool = false,
    tokens: bool = false,
    status: bool = false,

    fn default() TailEventMask {
        return .{ .turns = true, .tools = true, .tokens = true, .status = true };
    }
};

fn isValidTraceWorkerKind(text: []const u8) bool {
    return std.mem.eql(u8, text, "all") or
        std.mem.eql(u8, text, "none") or
        std.mem.eql(u8, text, "inline") or
        std.mem.eql(u8, text, "external");
}

fn isValidTraceTurnStatus(text: []const u8) bool {
    return std.mem.eql(u8, text, "complete") or
        std.mem.eql(u8, text, "aborted") or
        std.mem.eql(u8, text, "ongoing") or
        std.mem.eql(u8, text, "error");
}

fn isValidSkillAuditMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "summary") or
        std.mem.eql(u8, text, "mentions") or
        std.mem.eql(u8, text, "trend");
}

fn isValidMessageAuditMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "summary") or
        std.mem.eql(u8, text, "rows") or
        std.mem.eql(u8, text, "sessions");
}

fn isValidSkillCohortMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "summary") or
        std.mem.eql(u8, text, "cohort") or
        std.mem.eql(u8, text, "mentions");
}

fn isValidToolAuditMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "summary") or
        std.mem.eql(u8, text, "rows") or
        std.mem.eql(u8, text, "args") or
        std.mem.eql(u8, text, "unresolved");
}

fn isValidToolSearchMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "rows") or
        std.mem.eql(u8, text, "summary") or
        std.mem.eql(u8, text, "args");
}

fn isValidToolAuditGroupBy(text: []const u8) bool {
    return std.mem.eql(u8, text, "executable") or
        std.mem.eql(u8, text, "tool") or
        std.mem.eql(u8, text, "session") or
        std.mem.eql(u8, text, "workdir") or
        std.mem.eql(u8, text, "command");
}

fn isValidMemoryInventoryMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "categories") or
        std.mem.eql(u8, text, "files") or
        std.mem.eql(u8, text, "blocks") or
        std.mem.eql(u8, text, "stage1") or
        std.mem.eql(u8, text, "extensions");
}

fn isValidMemoryExtensionAuditMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "summary") or
        std.mem.eql(u8, text, "rows");
}

fn isValidTokenWindowMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "summary") or
        std.mem.eql(u8, text, "rows");
}

fn isValidWorkdirReportMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "summary") or
        std.mem.eql(u8, text, "sessions");
}

fn isValidWorkflowAuditMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "summary") or
        std.mem.eql(u8, text, "signals") or
        std.mem.eql(u8, text, "outcomes") or
        std.mem.eql(u8, text, "sessions") or
        std.mem.eql(u8, text, "report");
}

fn isValidGoalAuditMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "summary") or
        std.mem.eql(u8, text, "rows");
}

fn isValidGoalAuditWorkflowCsv(text: []const u8) bool {
    var split = std.mem.splitScalar(u8, text, ',');
    var seen = false;
    while (split.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) return false;
        if (!std.mem.eql(u8, part, "review") and
            !std.mem.eql(u8, part, "resolve") and
            !std.mem.eql(u8, part, "other")) return false;
        seen = true;
    }
    return seen;
}

fn parseTailEventMask(raw_opt: ?[]const u8) !TailEventMask {
    const raw = raw_opt orelse return TailEventMask.default();
    var mask = TailEventMask{};
    var split = std.mem.splitScalar(u8, raw, ',');
    while (split.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "raw")) {
            mask.raw = true;
        } else if (std.mem.eql(u8, part, "turns")) {
            mask.turns = true;
        } else if (std.mem.eql(u8, part, "tools")) {
            mask.tools = true;
        } else if (std.mem.eql(u8, part, "tokens")) {
            mask.tokens = true;
        } else if (std.mem.eql(u8, part, "status")) {
            mask.status = true;
        } else {
            return error.InvalidModeArg;
        }
    }
    return mask;
}

fn traceParseOptions(opts: Options) canonical_trace.TraceParseOptions {
    return .{ .include_raw = opts.include_raw };
}

fn collectTraceRolloutPaths(allocator: std.mem.Allocator, sessions_root: []const u8) !std.ArrayList([]u8) {
    var paths = try collectJsonlPaths(allocator, sessions_root, null);
    errdefer freePathList(allocator, &paths);

    var write_idx: usize = 0;
    for (paths.items) |path| {
        const base = std.fs.path.basename(path);
        if (std.mem.startsWith(u8, base, "rollout-") and std.mem.endsWith(u8, base, ".jsonl")) {
            paths.items[write_idx] = path;
            write_idx += 1;
        } else {
            allocator.free(path);
        }
    }
    paths.items.len = write_idx;
    return paths;
}

fn resolveTraceTargetPaths(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
    require_single: bool,
) !std.ArrayList([]u8) {
    if (opts.path) |single_path| {
        var out: std.ArrayList([]u8) = .empty;
        errdefer freePathList(allocator, &out);
        try out.append(allocator, try toAbsolutePath(allocator, single_path));
        return out;
    }

    var paths = try collectTraceRolloutPaths(allocator, sessions_root);
    errdefer freePathList(allocator, &paths);

    if (opts.current) {
        var best_index: ?usize = null;
        var best_ts: ?[]u8 = null;
        defer if (best_ts) |ts| allocator.free(ts);
        var best_ongoing = false;
        for (paths.items, 0..) |path, idx| {
            var parsed = canonical_trace.parseSessionTrace(allocator, path, traceParseOptions(opts)) catch continue;
            defer parsed.deinit(allocator);
            const ts = parsed.session.start_time orelse parsed.session.end_time orelse "";
            const better = best_index == null or
                (parsed.session.is_ongoing and !best_ongoing) or
                (parsed.session.is_ongoing == best_ongoing and (best_ts == null or compareNormalizedTimestamp(ts, best_ts.?) == .gt));
            if (better) {
                best_index = idx;
                if (best_ts) |old| allocator.free(old);
                best_ts = try allocator.dupe(u8, ts);
                best_ongoing = parsed.session.is_ongoing;
            }
        }
        const keep = best_index orelse return error.SessionNotFound;
        var out: std.ArrayList([]u8) = .empty;
        errdefer freePathList(allocator, &out);
        for (paths.items, 0..) |path, idx| {
            if (idx == keep) {
                try out.append(allocator, try allocator.dupe(u8, path));
            }
        }
        freePathList(allocator, &paths);
        return out;
    }

    if (opts.session_id) |wanted| {
        var write_idx: usize = 0;
        for (paths.items) |path| {
            var parsed = canonical_trace.parseSessionTrace(allocator, path, traceParseOptions(opts)) catch {
                allocator.free(path);
                continue;
            };
            defer parsed.deinit(allocator);
            const matches = if (parsed.session.session_id) |id|
                std.mem.containsAtLeast(u8, id, 1, wanted)
            else
                std.mem.containsAtLeast(u8, path, 1, wanted);
            if (matches) {
                paths.items[write_idx] = path;
                write_idx += 1;
            } else {
                allocator.free(path);
            }
        }
        paths.items.len = write_idx;
    }

    if (require_single) {
        if (paths.items.len == 0) return error.SessionNotFound;
        if (paths.items.len > 1) {
            printCliError("error: trace selector matched more than one session file\n", .{});
            return error.AmbiguousSessionTarget;
        }
    }
    return paths;
}

fn traceContains(haystack_opt: ?[]const u8, needle: []const u8) bool {
    const haystack = haystack_opt orelse return false;
    return containsIgnoreCaseAscii(haystack, needle);
}

fn traceTextContainsAnySession(session: canonical_trace.SessionRecord, needle: []const u8) bool {
    return traceContains(session.session_id, needle) or
        traceContains(session.thread_name, needle) or
        traceContains(session.cwd, needle) or
        traceContains(session.git_branch, needle) or
        traceContains(session.model, needle) or
        traceContains(session.path, needle);
}

fn traceTextContainsAnyTurn(turn: canonical_trace.TurnRecord, needle: []const u8) bool {
    return traceContains(turn.user_message, needle) or
        traceContains(turn.user_preview, needle) or
        traceContains(turn.final_answer, needle) or
        traceContains(turn.assistant_preview, needle) or
        traceContains(turn.model, needle) or
        traceContains(turn.path, needle);
}

fn traceSessionPassesOptions(session: canonical_trace.SessionRecord, opts: Options) bool {
    const ts = session.start_time orelse session.end_time;
    if ((opts.since != null or opts.until != null) and !timestampSatisfiesBounds(ts, opts)) return false;
    if (opts.repo_text) |repo| {
        const cwd = session.cwd orelse return false;
        if (!std.mem.eql(u8, cwd, repo) and !std.mem.startsWith(u8, cwd, repo)) return false;
    }
    if (opts.contains) |needle| {
        if (!traceTextContainsAnySession(session, needle)) return false;
    }
    if (opts.ongoing and !session.is_ongoing) return false;
    if (opts.completed and session.is_ongoing) return false;
    if (opts.worker_kind_text) |worker_kind| {
        if (std.mem.eql(u8, worker_kind, "all")) return true;
        if (std.mem.eql(u8, worker_kind, "none")) return !session.is_inline_worker and !session.is_external_worker;
        if (std.mem.eql(u8, worker_kind, "inline")) return session.is_inline_worker;
        if (std.mem.eql(u8, worker_kind, "external")) return session.is_external_worker;
        return false;
    }
    return true;
}

fn traceTurnPassesOptions(turn: canonical_trace.TurnRecord, opts: Options) bool {
    const ts = turn.started_at orelse turn.completed_at;
    if ((opts.since != null or opts.until != null) and !timestampSatisfiesBounds(ts, opts)) return false;
    if (opts.status) |status| {
        if (!std.mem.eql(u8, @tagName(turn.status), status)) return false;
    }
    if (opts.contains) |needle| {
        if (!traceTextContainsAnyTurn(turn, needle)) return false;
    }
    return true;
}

fn putOptionalBool(row: *query.Row, field: []const u8, value: ?bool) !void {
    if (value) |v| {
        try row.putOwnedKey(field, .{ .bool = v });
    } else {
        try row.putOwnedKey(field, .null);
    }
}

fn appendTraceSessionRow(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    session: canonical_trace.SessionRecord,
) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();

    try putOptionalString(&row, "session_id", session.session_id);
    try row.putOwnedKey("path", .{ .string = session.path });
    try putOptionalString(&row, "date_group", session.date_group);
    try putOptionalString(&row, "start_time", session.start_time);
    try putOptionalString(&row, "end_time", session.end_time);
    try putOptionalString(&row, "cwd", session.cwd);
    try putOptionalString(&row, "git_branch", session.git_branch);
    try putOptionalString(&row, "git_commit_hash", session.git_commit_hash);
    try putOptionalString(&row, "git_repository_url", session.git_repository_url);
    try putOptionalString(&row, "originator", session.originator);
    try putOptionalString(&row, "cli_version", session.cli_version);
    try putOptionalString(&row, "model", session.model);
    try putOptionalString(&row, "model_provider", session.model_provider);
    try putOptionalString(&row, "thread_name", session.thread_name);
    try row.putOwnedKey("turn_count", .{ .int = session.turn_count });
    try putOptionalInt(&row, "total_tokens", session.total_tokens);
    try putOptionalInt(&row, "input_tokens", session.input_tokens);
    try putOptionalInt(&row, "cached_input_tokens", session.cached_input_tokens);
    try putOptionalInt(&row, "output_tokens", session.output_tokens);
    try putOptionalInt(&row, "reasoning_output_tokens", session.reasoning_output_tokens);
    try row.putOwnedKey("is_ongoing", .{ .bool = session.is_ongoing });
    try putOptionalString(&row, "status_reason", session.status_reason);
    try row.putOwnedKey("status", .{ .string = if (session.is_ongoing) "ongoing" else "completed" });
    try row.putOwnedKey("is_external_worker", .{ .bool = session.is_external_worker });
    try row.putOwnedKey("is_inline_worker", .{ .bool = session.is_inline_worker });
    try row.putOwnedKey("worker_kind", .{ .string = if (session.is_external_worker) "external" else if (session.is_inline_worker) "inline" else "none" });
    try row.putOwnedKey("spawned_worker_count", .{ .int = session.spawned_worker_count });
    try out_rows.append(allocator, row);
}

fn appendTraceTurnRow(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    turn: canonical_trace.TurnRecord,
) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putOptionalString(&row, "session_id", turn.session_id);
    try row.putOwnedKey("path", .{ .string = turn.path });
    try row.putOwnedKey("turn_id", .{ .string = turn.turn_id });
    try row.putOwnedKey("turn_index", .{ .int = turn.turn_index });
    try putOptionalString(&row, "started_at", turn.started_at);
    try putOptionalString(&row, "completed_at", turn.completed_at);
    try putOptionalInt(&row, "duration_ms", turn.duration_ms);
    try row.putOwnedKey("status", .{ .string = @tagName(turn.status) });
    try putOptionalString(&row, "status_reason", turn.status_reason);
    try putOptionalString(&row, "user_message", turn.user_message);
    try putOptionalString(&row, "user_preview", turn.user_preview);
    try putOptionalString(&row, "final_answer", turn.final_answer);
    try putOptionalString(&row, "assistant_preview", turn.assistant_preview);
    try putOptionalString(&row, "model", turn.model);
    try putOptionalString(&row, "cwd", turn.cwd);
    try putOptionalString(&row, "reasoning_effort", turn.reasoning_effort);
    try putOptionalInt(&row, "input_tokens", turn.input_tokens);
    try putOptionalInt(&row, "cached_input_tokens", turn.cached_input_tokens);
    try putOptionalInt(&row, "output_tokens", turn.output_tokens);
    try putOptionalInt(&row, "reasoning_output_tokens", turn.reasoning_output_tokens);
    try putOptionalInt(&row, "total_tokens", turn.total_tokens);
    try row.putOwnedKey("tool_count", .{ .int = turn.tool_count });
    try row.putOwnedKey("has_compaction", .{ .bool = turn.has_compaction });
    try putOptionalString(&row, "thread_name", turn.thread_name);
    try putOptionalString(&row, "error", turn.@"error");
    try putOptionalString(&row, "aborted_reason", turn.aborted_reason);
    try row.putOwnedKey("spawned_worker_count", .{ .int = turn.spawned_worker_count });
    try out_rows.append(allocator, row);
}

fn traceToolsJsonForTurn(
    allocator: std.mem.Allocator,
    tools: []const canonical_trace.ToolLifecycleRecord,
    turn_index: i64,
) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeByte('[');
    var emitted: usize = 0;
    for (tools) |tool| {
        if (tool.turn_index == null or tool.turn_index.? != turn_index) continue;
        if (emitted > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try output.writeJsonString(writer, "call_id");
        try writer.writeByte(':');
        if (tool.call_id) |value| try output.writeJsonString(writer, value) else try writer.writeAll("null");
        try writer.writeByte(',');
        try output.writeJsonString(writer, "kind");
        try writer.writeByte(':');
        try output.writeJsonString(writer, @tagName(tool.kind));
        try writer.writeByte(',');
        try output.writeJsonString(writer, "tool_name");
        try writer.writeByte(':');
        if (tool.tool_name) |value| try output.writeJsonString(writer, value) else try writer.writeAll("null");
        try writer.writeByte(',');
        try output.writeJsonString(writer, "lifecycle_status");
        try writer.writeByte(':');
        try output.writeJsonString(writer, @tagName(tool.lifecycle_status));
        try writer.writeByte('}');
        emitted += 1;
    }
    try writer.writeByte(']');
    return writer_alloc.toOwnedSlice();
}

fn appendTraceToolRow(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    tool: canonical_trace.ToolLifecycleRecord,
) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putOptionalString(&row, "session_id", tool.session_id);
    try row.putOwnedKey("path", .{ .string = tool.path });
    try putOptionalString(&row, "turn_id", tool.turn_id);
    try putOptionalInt(&row, "turn_index", tool.turn_index);
    try putOptionalString(&row, "call_id", tool.call_id);
    try row.putOwnedKey("kind", .{ .string = @tagName(tool.kind) });
    try putOptionalString(&row, "tool_name", tool.tool_name);
    try putOptionalString(&row, "namespace", tool.namespace);
    try putOptionalString(&row, "arguments_json", tool.arguments_json);
    try putOptionalString(&row, "input_text", tool.input_text);
    try putOptionalString(&row, "output_text", tool.output_text);
    try putOptionalString(&row, "command_text", tool.command_text);
    try putOptionalString(&row, "cwd", tool.cwd);
    try putOptionalInt(&row, "exit_code", tool.exit_code);
    try putOptionalInt(&row, "duration_ms", tool.duration_ms);
    try putOptionalString(&row, "mcp_server", tool.mcp_server);
    try putOptionalString(&row, "mcp_tool", tool.mcp_tool);
    try putOptionalBool(&row, "patch_success", tool.patch_success);
    try putOptionalString(&row, "patch_changes_json", tool.patch_changes_json);
    try putOptionalString(&row, "web_query", tool.web_query);
    try putOptionalString(&row, "web_url", tool.web_url);
    try putOptionalString(&row, "image_prompt", tool.image_prompt);
    try row.putOwnedKey("lifecycle_status", .{ .string = @tagName(tool.lifecycle_status) });
    try putOptionalInt(&row, "declared_line", tool.declared_line);
    try putOptionalInt(&row, "finalized_line", tool.finalized_line);
    try out_rows.append(allocator, row);
}

fn appendTraceGraphRow(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    edge: canonical_trace.SessionGraphEdge,
) !void {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    try putOptionalString(&row, "parent_session_id", edge.parent_session_id);
    try putOptionalString(&row, "worker_session_id", edge.worker_session_id);
    try row.putOwnedKey("parent_path", .{ .string = edge.parent_path });
    try putOptionalString(&row, "worker_path", edge.worker_path);
    try putOptionalString(&row, "call_id", edge.call_id);
    try putOptionalString(&row, "agent_nickname", edge.agent_nickname);
    try putOptionalString(&row, "agent_role", edge.agent_role);
    try putOptionalString(&row, "model", edge.model);
    try putOptionalString(&row, "reasoning_effort", edge.reasoning_effort);
    try putOptionalString(&row, "spawned_at", edge.spawned_at);
    try putOptionalString(&row, "prompt_preview", edge.prompt_preview);
    try putOptionalString(&row, "worker_status", edge.worker_status);
    try out_rows.append(allocator, row);
}

fn collectTraceDatasetRowsWithOptions(
    allocator: std.mem.Allocator,
    dataset_name: []const u8,
    sessions_root: []const u8,
    opts: Options,
) !std.ArrayList(query.Row) {
    var rows: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &rows);
    var paths = try resolveTraceTargetPaths(allocator, sessions_root, opts, false);
    defer freePathList(allocator, &paths);

    var inline_worker_ids = std.StringHashMap(void).init(allocator);
    defer {
        var id_it = inline_worker_ids.keyIterator();
        while (id_it.next()) |key| allocator.free(key.*);
        inline_worker_ids.deinit();
    }

    if (std.mem.eql(u8, dataset_name, "sessions")) {
        for (paths.items) |path| {
            var parsed = canonical_trace.parseSessionTrace(allocator, path, traceParseOptions(opts)) catch continue;
            defer parsed.deinit(allocator);
            for (parsed.graph_edges.items) |edge| {
                if (edge.worker_session_id) |id| {
                    if (!inline_worker_ids.contains(id)) {
                        try inline_worker_ids.put(try allocator.dupe(u8, id), {});
                    }
                }
            }
        }
    }

    for (paths.items) |path| {
        var parsed = canonical_trace.parseSessionTrace(allocator, path, traceParseOptions(opts)) catch continue;
        defer parsed.deinit(allocator);

        if (std.mem.eql(u8, dataset_name, "sessions")) {
            if (parsed.session.session_id) |id| {
                if (inline_worker_ids.contains(id)) parsed.session.is_inline_worker = true;
            }
            if (traceSessionPassesOptions(parsed.session, opts)) try appendTraceSessionRow(allocator, &rows, parsed.session);
        } else if (std.mem.eql(u8, dataset_name, "turns")) {
            for (parsed.turns.items) |turn| {
                if (traceTurnPassesOptions(turn, opts)) {
                    try appendTraceTurnRow(allocator, &rows, turn);
                    if (opts.include_tools) {
                        const tools_json = try traceToolsJsonForTurn(allocator, parsed.tools.items, turn.turn_index);
                        defer allocator.free(tools_json);
                        try rows.items[rows.items.len - 1].putOwnedKey("tools_json", .{ .string = tools_json });
                    }
                }
            }
        } else if (std.mem.eql(u8, dataset_name, "tool_lifecycle")) {
            for (parsed.tools.items) |tool| try appendTraceToolRow(allocator, &rows, tool);
        } else if (std.mem.eql(u8, dataset_name, "session_graph_edges")) {
            for (parsed.graph_edges.items) |edge| try appendTraceGraphRow(allocator, &rows, edge);
        } else {
            return error.UnknownDataset;
        }
    }
    return rows;
}

fn collectTraceDatasetRowsFromParams(
    allocator: std.mem.Allocator,
    dataset_name: []const u8,
    sessions_root: []const u8,
    query_params: []const spec.ParamSpec,
) !std.ArrayList(query.Row) {
    var opts = Options{};
    if (paramString(query_params, "root")) |root| {
        const resolved = try resolveSessionsRoot(allocator, root);
        defer allocator.free(resolved);
        return collectTraceDatasetRowsWithOptions(allocator, dataset_name, resolved, opts);
    }
    if (paramString(query_params, "path")) |path| opts.path = path;
    if (paramString(query_params, "session_id")) |id| opts.session_id = id;
    if (paramBool(query_params, "include_raw")) |flag| opts.include_raw = flag;
    return collectTraceDatasetRowsWithOptions(allocator, dataset_name, sessions_root, opts);
}

fn runTraceRows(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(query.Row),
    opts: Options,
    default_sort_field: []const u8,
    columns: []const []const u8,
) !void {
    const sort = [_]spec.SortSpec{.{ .field = default_sort_field, .descending = true }};
    const query_spec = spec.QuerySpec{
        .sort = sort[0..],
        .limit = opts.limit,
    };
    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);
    try output.writeOutput(allocator, opts.format, result.rows.items, columns, opts.out_path);
}

fn cmdTraceSessions(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var rows = try collectTraceDatasetRowsWithOptions(allocator, "sessions", sessions_root, opts);
    defer deinitQueryRows(allocator, &rows);
    try runTraceRows(allocator, &rows, opts, "start_time", trace_session_columns[0..]);
}

fn cmdTraceTurns(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var rows = try collectTraceDatasetRowsWithOptions(allocator, "turns", sessions_root, opts);
    defer deinitQueryRows(allocator, &rows);
    const columns = if (opts.include_tools) trace_turn_tool_columns[0..] else trace_turn_columns[0..];
    try runTraceRows(allocator, &rows, opts, "started_at", columns);
}

fn cmdTraceToolLifecycle(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var rows = try collectTraceDatasetRowsWithOptions(allocator, "tool_lifecycle", sessions_root, opts);
    defer deinitQueryRows(allocator, &rows);
    try runTraceRows(allocator, &rows, opts, "turn_index", trace_tool_columns[0..]);
}

fn writeTextOutput(text: []const u8, out_path: ?[]const u8) !void {
    if (out_path) |path| {
        try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = text });
        return;
    }
    var stdout = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout.interface.writeAll(text);
}

fn writeTraceGraphDotRows(allocator: std.mem.Allocator, rows: []const query.Row, out_path: ?[]const u8) !void {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeAll("digraph codex_sessions {\n");
    for (rows) |row| {
        const parent = switch (row.valueOrNull("parent_session_id")) {
            .string => |s| s,
            else => "",
        };
        const worker = switch (row.valueOrNull("worker_session_id")) {
            .string => |s| s,
            else => "",
        };
        if (parent.len == 0 or worker.len == 0) continue;
        try writer.writeAll("  ");
        try output.writeJsonString(writer, parent);
        try writer.writeAll(" -> ");
        try output.writeJsonString(writer, worker);
        try writer.writeAll(" [label=");
        const nickname = switch (row.valueOrNull("agent_nickname")) {
            .string => |s| s,
            else => "",
        };
        const role = switch (row.valueOrNull("agent_role")) {
            .string => |s| s,
            else => "",
        };
        const label = try std.fmt.allocPrint(allocator, "{s} / {s}", .{ nickname, role });
        defer allocator.free(label);
        try output.writeJsonString(writer, label);
        try writer.writeAll("];\n");
    }
    try writer.writeAll("}\n");
    const rendered = try writer_alloc.toOwnedSlice();
    defer allocator.free(rendered);
    try writeTextOutput(rendered, out_path);
}

fn writeRowsJsonArray(writer: anytype, rows: []const query.Row, columns: []const []const u8, pretty_indent: []const u8) !void {
    try writer.writeAll("[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeByte('\n');
        try writer.writeAll(pretty_indent);
        try output.writeJsonObject(writer, row, columns, true, "    ");
    }
    if (rows.len > 0) try writer.writeByte('\n');
    try writer.writeAll("  ]");
}

fn cmdTraceSessionDetail(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var paths = try resolveTraceTargetPaths(allocator, sessions_root, opts, true);
    defer freePathList(allocator, &paths);

    var parsed = try canonical_trace.parseSessionTrace(allocator, paths.items[0], traceParseOptions(opts));
    defer parsed.deinit(allocator);

    if (opts.format == .markdown) {
        var writer_alloc = std.Io.Writer.Allocating.init(allocator);
        defer writer_alloc.deinit();
        const writer = &writer_alloc.writer;
        try writer.print("# {s}\n\n", .{parsed.session.thread_name orelse parsed.session.session_id orelse "Codex session"});
        try writer.print("- session_id: {s}\n- path: {s}\n- status: {s}\n- turns: {d}\n- total_tokens: {d}\n\n", .{
            parsed.session.session_id orelse "",
            parsed.session.path,
            parsed.session.status_reason orelse "",
            parsed.turns.items.len,
            parsed.session.total_tokens orelse 0,
        });
        for (parsed.turns.items) |turn| {
            try writer.print("## Turn {d} ({s})\n\n", .{ turn.turn_index, @tagName(turn.status) });
            if (turn.user_preview) |text| try writer.print("- user: {s}\n", .{text});
            if (turn.assistant_preview) |text| try writer.print("- assistant: {s}\n", .{text});
            if (turn.total_tokens) |tokens| try writer.print("- tokens: {d}\n", .{tokens});
            try writer.print("- tools: {d}\n\n", .{turn.tool_count});
            if (opts.include_tools and turn.tool_count > 0) {
                for (parsed.tools.items) |tool| {
                    if (tool.turn_index == null or tool.turn_index.? != turn.turn_index) continue;
                    try writer.print("  - {s} {s}", .{ @tagName(tool.kind), @tagName(tool.lifecycle_status) });
                    if (tool.tool_name) |name| try writer.print(" `{s}`", .{name});
                    if (tool.call_id) |call_id| try writer.print(" ({s})", .{call_id});
                    try writer.writeByte('\n');
                }
                try writer.writeByte('\n');
            }
        }
        const rendered = try writer_alloc.toOwnedSlice();
        defer allocator.free(rendered);
        try writeTextOutput(rendered, opts.out_path);
        return;
    }

    var session_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &session_rows);
    var turn_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &turn_rows);
    var tool_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &tool_rows);
    var graph_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &graph_rows);
    try appendTraceSessionRow(allocator, &session_rows, parsed.session);
    for (parsed.turns.items) |turn| try appendTraceTurnRow(allocator, &turn_rows, turn);
    for (parsed.tools.items) |tool| try appendTraceToolRow(allocator, &tool_rows, tool);
    for (parsed.graph_edges.items) |edge| try appendTraceGraphRow(allocator, &graph_rows, edge);

    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeAll("{\n  \"session\": ");
    try output.writeJsonObject(writer, session_rows.items[0], findDatasetMeta("sessions").?.fields, true, "    ");
    try writer.writeAll(",\n  \"turns\": ");
    try writeRowsJsonArray(writer, turn_rows.items, findDatasetMeta("turns").?.fields, "    ");
    try writer.writeAll(",\n  \"tools\": ");
    try writeRowsJsonArray(writer, tool_rows.items, findDatasetMeta("tool_lifecycle").?.fields, "    ");
    try writer.writeAll(",\n  \"graph_edges\": ");
    try writeRowsJsonArray(writer, graph_rows.items, findDatasetMeta("session_graph_edges").?.fields, "    ");
    try writer.writeAll(",\n  \"warnings\": [");
    for (parsed.warnings.items, 0..) |warning, idx| {
        if (idx > 0) try writer.writeAll(", ");
        try output.writeJsonString(writer, warning);
    }
    try writer.writeAll("]\n}\n");
    const rendered = try writer_alloc.toOwnedSlice();
    defer allocator.free(rendered);
    try writeTextOutput(rendered, opts.out_path);
}

fn cmdTraceSessionGraph(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var rows = try collectTraceDatasetRowsWithOptions(allocator, "session_graph_edges", sessions_root, opts);
    defer deinitQueryRows(allocator, &rows);
    if (opts.format == .dot) {
        try writeTraceGraphDotRows(allocator, rows.items, opts.out_path);
        return;
    }
    try runTraceRows(allocator, &rows, opts, "spawned_at", trace_graph_columns[0..]);
}

fn appendTailStatusRows(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    parsed: canonical_trace.CanonicalSessionTrace,
    mask: TailEventMask,
    turn_start: usize,
    tool_start: usize,
    emit_status: bool,
) !void {
    if (mask.status and emit_status) {
        var status_row = query.Row.init(allocator);
        errdefer status_row.deinit();
        try status_row.putOwnedKey("event", .{ .string = "status" });
        try putOptionalString(&status_row, "session_id", parsed.session.session_id);
        try status_row.putOwnedKey("path", .{ .string = parsed.session.path });
        try status_row.putOwnedKey("is_ongoing", .{ .bool = parsed.session.is_ongoing });
        try putOptionalString(&status_row, "status_reason", parsed.session.status_reason);
        try out_rows.append(allocator, status_row);
    }

    for (parsed.turns.items[turn_start..]) |turn| {
        if (!mask.turns and !(mask.tokens and turn.total_tokens != null)) continue;
        var row = query.Row.init(allocator);
        errdefer row.deinit();
        const event_name = if (mask.tokens and !mask.turns and turn.total_tokens != null)
            "token_count"
        else if (turn.status == .complete)
            "turn_complete"
        else
            "turn_status";
        try row.putOwnedKey("event", .{ .string = event_name });
        try putOptionalString(&row, "session_id", turn.session_id);
        try row.putOwnedKey("turn_id", .{ .string = turn.turn_id });
        try row.putOwnedKey("turn_index", .{ .int = turn.turn_index });
        try row.putOwnedKey("path", .{ .string = turn.path });
        try putOptionalInt(&row, "duration_ms", turn.duration_ms);
        try putOptionalInt(&row, "total_tokens", turn.total_tokens);
        try putOptionalString(&row, "status_reason", turn.status_reason);
        try out_rows.append(allocator, row);
    }

    if (!mask.tools) return;
    for (parsed.tools.items[tool_start..]) |tool| {
        var row = query.Row.init(allocator);
        errdefer row.deinit();
        try row.putOwnedKey("event", .{ .string = if (tool.lifecycle_status == .completed or tool.lifecycle_status == .failed) "tool_complete" else "tool_status" });
        try putOptionalString(&row, "session_id", tool.session_id);
        try putOptionalString(&row, "turn_id", tool.turn_id);
        try putOptionalInt(&row, "turn_index", tool.turn_index);
        try row.putOwnedKey("path", .{ .string = tool.path });
        try row.putOwnedKey("kind", .{ .string = @tagName(tool.kind) });
        try row.putOwnedKey("lifecycle_status", .{ .string = @tagName(tool.lifecycle_status) });
        try putOptionalInt(&row, "duration_ms", tool.duration_ms);
        try out_rows.append(allocator, row);
    }
}

fn appendTailRawRows(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    path: []const u8,
    start_line_exclusive: usize,
) !usize {
    const content = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(content);
    var last_seen = start_line_exclusive;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    while (line_it.next()) |line| {
        line_number += 1;
        if (line_number <= start_line_exclusive) continue;
        var event = try canonical_trace.parseRawTraceEvent(allocator, path, line_number, line) orelse continue;
        defer event.deinit(allocator);
        last_seen = line_number;
        var row = query.Row.init(allocator);
        errdefer row.deinit();
        try row.putOwnedKey("event", .{ .string = "raw" });
        try row.putOwnedKey("path", .{ .string = event.path });
        try row.putOwnedKey("line_number", .{ .int = @intCast(event.line_number) });
        try row.putOwnedKey("entry_type", .{ .string = event.entry_type });
        try putOptionalString(&row, "event_type", event.event_type);
        try putOptionalString(&row, "timestamp", event.timestamp);
        try out_rows.append(allocator, row);
    }
    return last_seen;
}

fn cmdTraceTail(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var paths = try resolveTraceTargetPaths(allocator, sessions_root, opts, true);
    defer freePathList(allocator, &paths);
    const mask = try parseTailEventMask(opts.events_text);

    var last_raw_line: usize = 0;
    var last_turn_count: usize = 0;
    var last_tool_count: usize = 0;
    var emitted_status = false;
    while (true) {
        var rows: std.ArrayList(query.Row) = .empty;
        defer deinitQueryRows(allocator, &rows);

        if (mask.raw) last_raw_line = try appendTailRawRows(allocator, &rows, paths.items[0], last_raw_line);

        var parsed = try canonical_trace.parseSessionTrace(allocator, paths.items[0], traceParseOptions(opts));
        defer parsed.deinit(allocator);
        try appendTailStatusRows(allocator, &rows, parsed, mask, last_turn_count, last_tool_count, !emitted_status);
        last_turn_count = parsed.turns.items.len;
        last_tool_count = parsed.tools.items.len;
        emitted_status = true;

        if (rows.items.len > 0) try output.writeOutput(allocator, opts.format, rows.items, trace_tail_columns[0..], opts.out_path);
        if (opts.once) break;
        try std.Io.sleep(defaultIo(), std.Io.Duration.fromMilliseconds(@max(opts.poll_ms, 1)), .awake);
    }
}

fn cmdDatasets(allocator: std.mem.Allocator, opts: Options) !void {
    var rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &rows);

    for (dataset_meta) |meta| {
        var row = query.Row.init(allocator);
        try row.putOwnedKey("dataset", .{ .string = meta.name });
        try row.putOwnedKey("description", .{ .string = meta.description });
        try rows.append(allocator, row);
    }

    const cols = [_][]const u8{ "dataset", "description" };
    try output.writeOutput(allocator, opts.format, rows.items, cols[0..], opts.out_path);
}

fn cmdDatasetSchema(allocator: std.mem.Allocator, opts: Options) !void {
    const name = opts.dataset orelse return error.MissingDatasetArg;
    const meta = findDatasetMeta(name) orelse return error.UnknownDataset;

    var rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &rows);

    for (meta.fields, 0..) |field, idx| {
        var row = query.Row.init(allocator);
        try row.putOwnedKey("dataset", .{ .string = meta.name });
        try row.putOwnedKey("field", .{ .string = field });
        try row.putOwnedKey("index", .{ .int = @intCast(idx) });
        try rows.append(allocator, row);
    }

    const cols = [_][]const u8{ "dataset", "field", "index" };
    try output.writeOutput(allocator, opts.format, rows.items, cols[0..], opts.out_path);
}

fn cmdQuery(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const raw_spec = opts.spec_text orelse return error.MissingSpecArg;
    const spec_text = try loadSpecText(allocator, raw_spec);
    defer allocator.free(spec_text);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), spec_text, .{});
    defer parsed.deinit();

    const query_spec = try spec.parseQuerySpecValue(arena.allocator(), parsed.value);
    const dataset_name = blk: {
        const root_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidSpec,
        };
        if (root_obj.get("dataset")) |value| switch (value) {
            .string => |text| break :blk text,
            else => return error.InvalidSpec,
        };
        break :blk opts.dataset orelse "messages";
    };

    const fmt = blk: {
        const root_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidSpec,
        };
        if (root_obj.get("format")) |value| switch (value) {
            .string => |text| break :blk try output.Format.parse(text),
            else => return error.InvalidSpec,
        };
        if (opts.format_set) break :blk opts.format;
        break :blk if (query_spec.group_by.len > 0) output.Format.table else output.Format.jsonl;
    };

    var rows = try collectDatasetRowsForSpec(allocator, dataset_name, sessions_root, query_spec);
    defer deinitQueryRows(allocator, &rows);

    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    const cols_opt: ?[]const []const u8 = if (query_spec.select.len > 0) query_spec.select else null;
    if (fmt == .dot and std.mem.eql(u8, dataset_name, "session_graph_edges")) {
        try writeTraceGraphDotRows(allocator, result.rows.items, opts.out_path);
        return;
    }
    if (fmt == .dot or fmt == .markdown) return error.InvalidFormatForCommand;
    try output.writeOutput(allocator, fmt, result.rows.items, cols_opt, opts.out_path);
}

const workflow_audit_summary_columns = [_][]const u8{ "source_kind", "signal_kind", "name", "outcome_kind", "mentions", "sessions" };
const workflow_audit_signal_columns = [_][]const u8{ "timestamp", "path", "source_kind", "signal_kind", "name", "outcome_kind", "snippet", "contamination_flags" };
const workflow_audit_outcome_columns = [_][]const u8{ "outcome_kind", "mentions", "sessions" };
const workflow_audit_session_columns = [_][]const u8{ "path", "signals", "first_seen", "last_seen" };

const StringSet = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) StringSet {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *StringSet) void {
        var it = self.map.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.map.deinit();
    }

    fn put(self: *StringSet, text: []const u8) !void {
        if (self.map.contains(text)) return;
        const copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(copy);
        try self.map.put(copy, {});
    }

    fn contains(self: *const StringSet, text: []const u8) bool {
        return self.map.contains(text);
    }

    fn count(self: *const StringSet) usize {
        return self.map.count();
    }
};

fn cmdWorkflowAudit(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const workflow = opts.workflow orelse return error.MissingWorkflowArg;
    const mode = opts.mode orelse "summary";
    const fmt = if (opts.format_set)
        opts.format
    else if (std.mem.eql(u8, mode, "report"))
        output.Format.markdown
    else
        output.Format.table;

    var rows = try collectWorkflowAuditRows(allocator, sessions_root, opts);
    defer deinitQueryRows(allocator, &rows);

    if (fmt == .markdown and std.mem.eql(u8, mode, "report")) {
        try writeWorkflowAuditMarkdown(allocator, workflow, rows.items, opts.out_path);
        return;
    }

    const query_spec = try workflowAuditQueryForMode(mode, opts.limit);
    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    if (fmt == .markdown) {
        try writeWorkflowAuditModeMarkdown(allocator, workflow, mode, result.rows.items, workflowAuditColumnsForMode(mode) orelse return error.InvalidModeArg, opts.out_path);
        return;
    }

    try output.writeOutput(allocator, fmt, result.rows.items, workflowAuditColumnsForMode(mode), opts.out_path);
}

fn workflowAuditQueryForMode(mode: []const u8, limit: usize) !spec.QuerySpec {
    if (std.mem.eql(u8, mode, "summary")) {
        return .{
            .group_by = workflow_audit_summary_columns[0..4],
            .metrics = &.{
                .{ .op = .count, .alias = "mentions" },
                .{ .op = .count_distinct, .field = "path", .alias = "sessions" },
            },
            .sort = &.{.{ .field = "mentions", .descending = true }},
            .limit = if (limit > 0) limit else 50,
        };
    }

    if (std.mem.eql(u8, mode, "signals")) {
        return .{
            .select = workflow_audit_signal_columns[0..],
            .sort = &.{.{ .field = "timestamp", .descending = true }},
            .limit = if (limit > 0) limit else 100,
        };
    }

    if (std.mem.eql(u8, mode, "outcomes")) {
        return .{
            .where = &.{.{
                .field = "signal_kind",
                .op = .eq,
                .value = .{ .scalar = .{ .string = "outcome" } },
            }},
            .group_by = &.{"outcome_kind"},
            .metrics = &.{
                .{ .op = .count, .alias = "mentions" },
                .{ .op = .count_distinct, .field = "path", .alias = "sessions" },
            },
            .sort = &.{.{ .field = "mentions", .descending = true }},
            .limit = if (limit > 0) limit else 20,
        };
    }

    if (std.mem.eql(u8, mode, "sessions")) {
        return .{
            .group_by = &.{"path"},
            .metrics = &.{
                .{ .op = .count, .alias = "signals" },
                .{ .op = .min, .field = "timestamp", .alias = "first_seen" },
                .{ .op = .max, .field = "timestamp", .alias = "last_seen" },
            },
            .sort = &.{.{ .field = "signals", .descending = true }},
            .limit = if (limit > 0) limit else 50,
        };
    }

    if (std.mem.eql(u8, mode, "report")) {
        return .{
            .select = workflow_audit_signal_columns[0..],
            .sort = &.{.{ .field = "timestamp", .descending = true }},
            .limit = if (limit > 0) limit else 100,
        };
    }

    return error.InvalidModeArg;
}

fn workflowAuditColumnsForMode(mode: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, mode, "summary")) return workflow_audit_summary_columns[0..];
    if (std.mem.eql(u8, mode, "signals")) return workflow_audit_signal_columns[0..];
    if (std.mem.eql(u8, mode, "outcomes")) return workflow_audit_outcome_columns[0..];
    if (std.mem.eql(u8, mode, "sessions")) return workflow_audit_session_columns[0..];
    if (std.mem.eql(u8, mode, "report")) return workflow_audit_signal_columns[0..];
    return null;
}

fn collectWorkflowAuditRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
) !std.ArrayList(query.Row) {
    const workflow = opts.workflow orelse return error.MissingWorkflowArg;

    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    try appendSessionTimeBounds(allocator, &where, opts);

    const signal_query = spec.QuerySpec{ .where = where.items };
    var collected = try collectDatasetRowsForSpec(allocator, "workflow_signals", sessions_root, signal_query);
    defer deinitQueryRows(allocator, &collected);

    var filtered = try query.execute(allocator, collected.items, signal_query);
    defer filtered.deinit(allocator);

    var workdir_paths = StringSet.init(allocator);
    var has_workdir_filter = false;
    defer if (has_workdir_filter) workdir_paths.deinit();
    if (opts.workdir_text != null) {
        has_workdir_filter = true;
        try collectWorkdirSessionPaths(allocator, sessions_root, opts, &workdir_paths);
    }

    var cohort_paths = StringSet.init(allocator);
    defer cohort_paths.deinit();
    for (filtered.rows.items) |row| {
        const path = scalarString(row.valueOrNull("path")) orelse continue;
        if (has_workdir_filter and !workdir_paths.contains(path)) continue;
        if (!isWorkflowCohortSignal(row, workflow)) continue;
        try cohort_paths.put(path);
    }

    var out: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &out);
    for (filtered.rows.items) |row| {
        const path = scalarString(row.valueOrNull("path")) orelse continue;
        if (!cohort_paths.contains(path)) continue;
        if (has_workdir_filter and !workdir_paths.contains(path)) continue;
        try out.append(allocator, try row.cloneAll(allocator));
    }

    return out;
}

fn collectWorkdirSessionPaths(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
    out: *StringSet,
) !void {
    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);

    if (opts.workdir_text) |value| try where.append(allocator, .{
        .field = "cwd",
        .op = .eq,
        .value = .{ .scalar = .{ .string = value } },
    });
    if (opts.since) |value| try where.append(allocator, .{
        .field = "start_time",
        .op = .gte,
        .value = .{ .scalar = .{ .string = value } },
    });
    if (opts.until) |value| try where.append(allocator, .{
        .field = "start_time",
        .op = .lte,
        .value = .{ .scalar = .{ .string = value } },
    });

    const session_query = spec.QuerySpec{ .where = where.items };
    var collected = try collectDatasetRowsForSpec(allocator, "sessions", sessions_root, session_query);
    defer deinitQueryRows(allocator, &collected);

    var filtered = try query.execute(allocator, collected.items, session_query);
    defer filtered.deinit(allocator);

    for (filtered.rows.items) |row| {
        const path = scalarString(row.valueOrNull("path")) orelse continue;
        try out.put(path);
    }
}

fn isWorkflowCohortSignal(row: query.Row, workflow: []const u8) bool {
    const name = scalarString(row.valueOrNull("name")) orelse return false;
    if (!std.mem.eql(u8, name, workflow)) return false;
    const signal_kind = scalarString(row.valueOrNull("signal_kind")) orelse return false;
    return std.mem.eql(u8, signal_kind, "workflow_mention") or
        std.mem.eql(u8, signal_kind, "skill_mention");
}

fn writeWorkflowAuditMarkdown(
    allocator: std.mem.Allocator,
    workflow: []const u8,
    rows: []const query.Row,
    out_path: ?[]const u8,
) !void {
    var sessions = StringSet.init(allocator);
    defer sessions.deinit();
    for (rows) |row| {
        if (scalarString(row.valueOrNull("path"))) |path| try sessions.put(path);
    }

    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;

    try writer.print("# seq workflow-audit: {s}\n\n", .{workflow});
    try writer.print("- cohort_sessions: {d}\n", .{sessions.count()});
    try writer.print("- cohort_signals: {d}\n\n", .{rows.len});

    try writer.writeAll("## Signal Summary\n\n");
    try writeWorkflowAuditMarkdownSection(allocator, writer, rows, "summary");

    try writer.writeAll("\n## Outcomes\n\n");
    try writeWorkflowAuditMarkdownSection(allocator, writer, rows, "outcomes");

    try writer.writeAll("\n## Sessions\n\n");
    try writeWorkflowAuditMarkdownSection(allocator, writer, rows, "sessions");

    const rendered = try writer_alloc.toOwnedSlice();
    defer allocator.free(rendered);
    try writeTextOutput(rendered, out_path);
}

fn writeWorkflowAuditMarkdownSection(
    allocator: std.mem.Allocator,
    writer: anytype,
    rows: []const query.Row,
    mode: []const u8,
) !void {
    const query_spec = try workflowAuditQueryForMode(mode, 10);
    var result = try query.execute(allocator, rows, query_spec);
    defer result.deinit(allocator);

    try writeMarkdownTable(writer, result.rows.items, workflowAuditColumnsForMode(mode) orelse &.{});
}

fn writeWorkflowAuditModeMarkdown(
    allocator: std.mem.Allocator,
    workflow: []const u8,
    mode: []const u8,
    rows: []const query.Row,
    columns: []const []const u8,
    out_path: ?[]const u8,
) !void {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;

    try writer.print("# seq workflow-audit: {s} ({s})\n\n", .{ workflow, mode });
    try writeMarkdownTable(writer, rows, columns);

    const rendered = try writer_alloc.toOwnedSlice();
    defer allocator.free(rendered);
    try writeTextOutput(rendered, out_path);
}

fn writeMarkdownTable(writer: anytype, rows: []const query.Row, columns: []const []const u8) !void {
    if (columns.len == 0) {
        try writer.writeAll("(no columns)\n");
        return;
    }
    if (rows.len == 0) {
        try writer.writeAll("(no results)\n");
        return;
    }

    try writer.writeAll("|");
    for (columns) |column| {
        try writer.writeByte(' ');
        try writeEscapedMarkdownCell(writer, column);
        try writer.writeAll(" |");
    }
    try writer.writeByte('\n');

    try writer.writeAll("|");
    for (columns) |_| try writer.writeAll(" --- |");
    try writer.writeByte('\n');

    for (rows) |row| {
        try writer.writeAll("|");
        for (columns) |column| {
            try writer.writeByte(' ');
            try writeMarkdownScalar(writer, row.valueOrNull(column));
            try writer.writeAll(" |");
        }
        try writer.writeByte('\n');
    }
}

fn writeMarkdownScalar(writer: anytype, value: spec.Scalar) !void {
    switch (value) {
        .null => {},
        .bool => |flag| try writer.print("{}", .{flag}),
        .int => |number| try writer.print("{d}", .{number}),
        .float => |number| try writer.print("{d}", .{number}),
        .string => |text| try writeEscapedMarkdownCell(writer, text),
    }
}

fn writeEscapedMarkdownCell(writer: anytype, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '|', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(ch);
            },
            '\n', '\r' => try writer.writeByte(' '),
            else => try writer.writeByte(ch),
        }
    }
}

const QueryLiftCommands = struct {
    const skill_audit_summary_columns = [_][]const u8{ "skill", "mentions", "sessions", "first_seen", "last_seen" };
    const skill_audit_mentions_columns = [_][]const u8{ "timestamp", "role", "skill", "types", "snippet", "path" };
    const skill_audit_trend_columns = [_][]const u8{ "day", "mentions", "sessions" };
    const tool_audit_summary_columns = [_][]const u8{ "tool_name", "calls", "sessions", "avg_wall_ms", "max_wall_ms" };
    const tool_audit_row_columns = [_][]const u8{ "timestamp", "tool_name", "primary_executable", "workdir", "exit_code", "wall_time_ms", "command_text", "path" };
    const tool_audit_arg_columns = [_][]const u8{ "tool_name", "arg_path", "count" };
    const memory_inventory_category_columns = [_][]const u8{ "category", "extension", "files", "bytes", "latest_modified" };
    const memory_inventory_file_columns = [_][]const u8{ "relative_path", "category", "extension", "size_bytes", "modified_at", "preview" };
    const memory_inventory_block_columns = [_][]const u8{ "doc_kind", "title", "updated_at", "thread_id", "relative_path", "preview" };
    const memory_inventory_stage1_columns = [_][]const u8{ "generated_at", "last_usage", "cwd", "title", "thread_id", "rollout_path" };
    const memory_inventory_extension_columns = [_][]const u8{ "extension_name", "has_instructions", "modified_at", "size_bytes", "instructions_path" };
    const message_search_columns = [_][]const u8{ "timestamp", "role", "text", "path" };
    const message_audit_summary_columns = [_][]const u8{ "role", "messages", "sessions", "chars", "first_seen", "last_seen" };
    const message_audit_row_columns = [_][]const u8{ "timestamp", "role", "text_len", "text", "path" };
    const message_audit_session_columns = [_][]const u8{ "path", "messages", "chars", "first_seen", "last_seen" };
    const skill_cohort_summary_columns = [_][]const u8{ "skill", "mentions", "sessions", "first_seen", "last_seen" };
    const skill_cohort_mention_columns = [_][]const u8{ "timestamp", "role", "skill", "types", "snippet", "path" };
    const skill_cohort_columns = [_][]const u8{ "cohort_skill", "skill", "mentions", "sessions", "cohort_sessions", "first_seen", "last_seen" };
    const tool_search_row_columns = [_][]const u8{ "timestamp", "tool_name", "primary_executable", "workdir", "exit_code", "wall_time_ms", "command_text", "arguments_text", "input_text", "path" };
    const tool_search_summary_columns = [_][]const u8{ "primary_executable", "calls", "sessions", "avg_wall_ms", "max_wall_ms" };
    const tool_search_arg_columns = [_][]const u8{ "tool_name", "arg_path", "value_kind", "value_text", "count" };
    const memory_extension_summary_columns = [_][]const u8{ "row_kind", "extensions", "with_instructions", "without_instructions", "total_bytes", "provenance_status", "causality_claimed" };
    const memory_extension_row_columns = [_][]const u8{ "extension_name", "has_instructions", "modified_at", "size_bytes", "instructions_path", "provenance_status", "causality_claimed" };
    const token_window_summary_columns = [_][]const u8{ "window_hours", "window_start", "window_end", "observed_end", "total_tokens", "rows", "path_count", "source_dataset", "sorted_by", "since", "until" };
    const token_window_row_columns = [_][]const u8{ "timestamp", "delta_total_tokens", "path", "segment", "model_context_window" };
    const workdir_report_summary_columns = [_][]const u8{ "cwd", "sessions", "turns", "total_tokens", "first_seen", "last_seen" };
    const workdir_report_session_columns = [_][]const u8{ "start_time", "end_time", "cwd", "model", "total_tokens", "path" };
    const goal_audit_row_columns = [_][]const u8{
        "timestamp",
        "objective_kind",
        "status",
        "time_used_seconds",
        "tokens_used",
        "review_invocation_count",
        "objective",
        "thread_id",
        "session_id",
        "path",
        "missing_duration",
        "contamination_flags",
    };
    const goal_audit_summary_columns = [_][]const u8{ "objective_kind", "runs", "sessions", "review_invocations", "max_time_used_seconds" };

    fn appendTimeBoundsForField(
        allocator: std.mem.Allocator,
        where_out: *std.ArrayList(spec.WhereClause),
        field: []const u8,
        opts: Options,
    ) !void {
        if (opts.since) |value| try where_out.append(allocator, .{
            .field = field,
            .op = .gte,
            .value = .{ .scalar = .{ .string = value } },
        });
        if (opts.until) |value| try where_out.append(allocator, .{
            .field = field,
            .op = .lte,
            .value = .{ .scalar = .{ .string = value } },
        });
    }

    fn appendOptionalStringEq(
        allocator: std.mem.Allocator,
        where_out: *std.ArrayList(spec.WhereClause),
        field: []const u8,
        value_opt: ?[]const u8,
    ) !void {
        if (value_opt) |value| try where_out.append(allocator, .{
            .field = field,
            .op = .eq,
            .value = .{ .scalar = .{ .string = value } },
        });
    }

    fn appendOptionalContains(
        allocator: std.mem.Allocator,
        where_out: *std.ArrayList(spec.WhereClause),
        field: []const u8,
        value_opt: ?[]const u8,
    ) !void {
        if (value_opt) |value| try where_out.append(allocator, .{
            .field = field,
            .op = .contains,
            .value = .{ .scalar = .{ .string = value } },
            .case_insensitive = true,
        });
    }

    fn appendOptionalRegex(
        allocator: std.mem.Allocator,
        where_out: *std.ArrayList(spec.WhereClause),
        field: []const u8,
        value_opt: ?[]const u8,
    ) !void {
        if (value_opt) |value| try where_out.append(allocator, .{
            .field = field,
            .op = .regex,
            .value = .{ .scalar = .{ .string = value } },
            .case_insensitive = true,
        });
    }

    fn appendCsvContainsAny(
        allocator: std.mem.Allocator,
        where_out: *std.ArrayList(spec.WhereClause),
        field: []const u8,
        raw_opt: ?[]const u8,
    ) !?[]spec.Scalar {
        const raw = raw_opt orelse return null;
        var values: std.ArrayList(spec.Scalar) = .empty;
        defer values.deinit(allocator);

        var split = std.mem.splitScalar(u8, raw, ',');
        while (split.next()) |part_raw| {
            const part = std.mem.trim(u8, part_raw, " \t\r\n");
            if (part.len == 0) continue;
            try values.append(allocator, .{ .string = part });
        }
        if (values.items.len == 0) return error.InvalidModeArg;
        const owned = try values.toOwnedSlice(allocator);
        try where_out.append(allocator, .{
            .field = field,
            .op = .contains_any,
            .value = .{ .list = owned },
            .case_insensitive = true,
        });
        return owned;
    }

    fn appendCsvContainsAll(
        allocator: std.mem.Allocator,
        where_out: *std.ArrayList(spec.WhereClause),
        field: []const u8,
        raw_opt: ?[]const u8,
    ) !void {
        const raw = raw_opt orelse return;
        var added = false;
        var split = std.mem.splitScalar(u8, raw, ',');
        while (split.next()) |part_raw| {
            const part = std.mem.trim(u8, part_raw, " \t\r\n");
            if (part.len == 0) continue;
            added = true;
            try where_out.append(allocator, .{
                .field = field,
                .op = .contains,
                .value = .{ .scalar = .{ .string = part } },
                .case_insensitive = true,
            });
        }
        if (!added) return error.InvalidModeArg;
    }

    fn appendRolesWhere(
        allocator: std.mem.Allocator,
        where_out: *std.ArrayList(spec.WhereClause),
        raw_opt: ?[]const u8,
    ) !?[]spec.Scalar {
        const raw = raw_opt orelse return null;
        var values: std.ArrayList(spec.Scalar) = .empty;
        defer values.deinit(allocator);

        var split = std.mem.splitScalar(u8, raw, ',');
        while (split.next()) |part_raw| {
            const part = std.mem.trim(u8, part_raw, " \t\r\n");
            if (part.len == 0) continue;
            if (!std.mem.eql(u8, part, "user") and !std.mem.eql(u8, part, "assistant")) {
                printCliError("error: invalid --roles value {s}\n", .{part});
                return error.InvalidModeArg;
            }
            try values.append(allocator, .{ .string = part });
        }
        if (values.items.len == 0) return error.InvalidModeArg;
        const owned = try values.toOwnedSlice(allocator);
        try where_out.append(allocator, .{
            .field = "role",
            .op = .in,
            .value = .{ .list = owned },
        });
        return owned;
    }

    fn queryLimit(opts: Options, default_limit: usize) usize {
        return if (opts.limit == 0) default_limit else opts.limit;
    }

    fn runQueryLiftDataset(
        allocator: std.mem.Allocator,
        dataset_name: []const u8,
        sessions_root: []const u8,
        query_spec: spec.QuerySpec,
        opts: Options,
        columns: []const []const u8,
    ) !void {
        if (opts.show_query) return writeGeneratedQuerySpec(allocator, dataset_name, query_spec, opts.out_path);
        return runDatasetQuery(allocator, dataset_name, sessions_root, query_spec, opts.format, opts.out_path, columns);
    }

    fn appendCurrentSessionExclusion(
        allocator: std.mem.Allocator,
        sessions_root: []const u8,
        where_out: *std.ArrayList(spec.WhereClause),
        opts: Options,
    ) !?[]u8 {
        if (!opts.exclude_current) return null;
        const path = try resolveCurrentSessionPathForExclusion(allocator, sessions_root);
        errdefer allocator.free(path);
        try where_out.append(allocator, .{
            .field = "path",
            .op = .neq,
            .value = .{ .scalar = .{ .string = path } },
        });
        return path;
    }

    fn resolveCurrentSessionPathForExclusion(allocator: std.mem.Allocator, sessions_root: []const u8) ![]u8 {
        const thread_id = getEnvVarOwned(allocator, "CODEX_THREAD_ID") catch {
            printCliError("error: --exclude-current requires CODEX_THREAD_ID in the environment\n", .{});
            return error.CurrentSessionUnavailable;
        };
        defer allocator.free(thread_id);

        var paths = try collectTraceRolloutPaths(allocator, sessions_root);
        defer freePathList(allocator, &paths);

        for (paths.items) |path| {
            var parsed = canonical_trace.parseSessionTrace(allocator, path, .{}) catch continue;
            defer parsed.deinit(allocator);
            if (parsed.session.session_id) |id| {
                if (std.mem.eql(u8, id, thread_id) or std.mem.containsAtLeast(u8, id, 1, thread_id)) {
                    return allocator.dupe(u8, path);
                }
            }
            if (std.mem.containsAtLeast(u8, path, 1, thread_id)) {
                return allocator.dupe(u8, path);
            }
        }

        printCliError("error: --exclude-current could not resolve CODEX_THREAD_ID {s} under sessions root {s}\n", .{ thread_id, sessions_root });
        return error.CurrentSessionUnavailable;
    }

    fn writeGeneratedQuerySpec(
        allocator: std.mem.Allocator,
        dataset_name: []const u8,
        query_spec: spec.QuerySpec,
        out_path: ?[]const u8,
    ) !void {
        var writer_alloc = std.Io.Writer.Allocating.init(allocator);
        defer writer_alloc.deinit();
        const writer = &writer_alloc.writer;

        try writer.writeAll("{\n  \"dataset\": ");
        try output.writeJsonString(writer, dataset_name);
        try writer.writeAll(",\n  \"where\": ");
        try writeWhereJson(writer, query_spec.where);
        try writer.writeAll(",\n  \"group_by\": ");
        try writeStringArrayJson(writer, query_spec.group_by);
        try writer.writeAll(",\n  \"metrics\": ");
        try writeMetricsJson(writer, query_spec.metrics);
        try writer.writeAll(",\n  \"select\": ");
        try writeStringArrayJson(writer, query_spec.select);
        try writer.writeAll(",\n  \"sort\": ");
        try writeSortJson(writer, query_spec.sort);
        try writer.writeAll(",\n  \"params\": ");
        try writeParamsJson(writer, query_spec.params);
        try writer.print(",\n  \"limit\": {d}\n}}\n", .{query_spec.limit});

        const rendered = try writer_alloc.toOwnedSlice();
        defer allocator.free(rendered);
        if (out_path) |path| {
            if (std.fs.path.dirname(path)) |dir| {
                if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(defaultIo(), dir);
            }
            try std.Io.Dir.cwd().writeFile(defaultIo(), .{ .sub_path = path, .data = rendered });
            return;
        }

        var stdout = std.Io.File.stdout().writer(defaultIo(), &.{});
        try stdout.interface.writeAll(rendered);
    }

    fn writeWhereJson(writer: anytype, clauses: []const spec.WhereClause) !void {
        try writer.writeByte('[');
        for (clauses, 0..) |clause, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll("{\"field\":");
            try output.writeJsonString(writer, clause.field);
            try writer.writeAll(",\"op\":");
            try output.writeJsonString(writer, @tagName(clause.op));
            if (clause.value) |value| {
                try writer.writeAll(",\"value\":");
                try writeWhereValueJson(writer, value);
            }
            if (clause.case_insensitive) try writer.writeAll(",\"case_insensitive\":true");
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
    }

    fn writeWhereValueJson(writer: anytype, value: spec.WhereValue) !void {
        switch (value) {
            .scalar => |scalar| try output.writeScalarJson(writer, scalar),
            .list => |items| try writeScalarArrayJson(writer, items),
        }
    }

    fn writeScalarArrayJson(writer: anytype, items: []const spec.Scalar) !void {
        try writer.writeByte('[');
        for (items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(", ");
            try output.writeScalarJson(writer, item);
        }
        try writer.writeByte(']');
    }

    fn writeStringArrayJson(writer: anytype, items: []const []const u8) !void {
        try writer.writeByte('[');
        for (items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(", ");
            try output.writeJsonString(writer, item);
        }
        try writer.writeByte(']');
    }

    fn writeMetricsJson(writer: anytype, metrics: []const spec.MetricSpec) !void {
        try writer.writeByte('[');
        for (metrics, 0..) |metric, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll("{\"op\":");
            try output.writeJsonString(writer, @tagName(metric.op));
            if (metric.field) |field| {
                try writer.writeAll(",\"field\":");
                try output.writeJsonString(writer, field);
            }
            if (metric.alias) |alias| {
                try writer.writeAll(",\"as\":");
                try output.writeJsonString(writer, alias);
            }
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
    }

    fn writeSortJson(writer: anytype, sort_items: []const spec.SortSpec) !void {
        try writer.writeByte('[');
        for (sort_items, 0..) |sort_item, i| {
            if (i > 0) try writer.writeAll(", ");
            if (sort_item.descending) {
                try writer.writeByte('"');
                try writer.writeByte('-');
                for (sort_item.field) |c| {
                    if (c == '"' or c == '\\') try writer.writeByte('\\');
                    try writer.writeByte(c);
                }
                try writer.writeByte('"');
            } else {
                try output.writeJsonString(writer, sort_item.field);
            }
        }
        try writer.writeByte(']');
    }

    fn writeParamsJson(writer: anytype, params: []const spec.ParamSpec) !void {
        try writer.writeByte('{');
        for (params, 0..) |param, i| {
            if (i > 0) try writer.writeAll(", ");
            try output.writeJsonString(writer, param.key);
            try writer.writeByte(':');
            try output.writeScalarJson(writer, param.value);
        }
        try writer.writeByte('}');
    }

    fn cmdSkillAudit(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const mode = opts.mode orelse "summary";
        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        try appendOptionalStringEq(allocator, &where, "skill", opts.skill);
        try appendSessionTimeBounds(allocator, &where, opts);
        const role_values = try appendRolesWhere(allocator, &where, opts.roles_csv);
        defer if (role_values) |values| allocator.free(values);

        if (std.mem.eql(u8, mode, "summary")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .group_by = &.{"skill"},
                .metrics = &.{
                    .{ .op = .count, .alias = "mentions" },
                    .{ .op = .count_distinct, .field = "path", .alias = "sessions" },
                    .{ .op = .min, .field = "timestamp", .alias = "first_seen" },
                    .{ .op = .max, .field = "timestamp", .alias = "last_seen" },
                },
                .sort = &.{.{ .field = "mentions", .descending = true }},
                .limit = queryLimit(opts, 20),
            };
            return runQueryLiftDataset(allocator, "skill_mentions", sessions_root, query_spec, opts, skill_audit_summary_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "mentions")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .select = skill_audit_mentions_columns[0..],
                .sort = &.{.{ .field = "timestamp", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "skill_mentions", sessions_root, query_spec, opts, skill_audit_mentions_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "trend")) {
            if (opts.skill == null) return error.MissingSkillArg;
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .group_by = &.{"day"},
                .metrics = &.{
                    .{ .op = .count, .alias = "mentions" },
                    .{ .op = .count_distinct, .field = "path", .alias = "sessions" },
                },
                .sort = &.{.{ .field = "day", .descending = false }},
                .limit = opts.limit,
            };
            return runQueryLiftDataset(allocator, "skill_mentions", sessions_root, query_spec, opts, skill_audit_trend_columns[0..]);
        }

        return error.InvalidModeArg;
    }

    fn toolAuditGroupField(raw_opt: ?[]const u8) ![]const u8 {
        const raw = raw_opt orelse "tool";
        if (std.mem.eql(u8, raw, "tool")) return "tool_name";
        if (std.mem.eql(u8, raw, "executable")) return "primary_executable";
        if (std.mem.eql(u8, raw, "session")) return "session_id";
        if (std.mem.eql(u8, raw, "workdir")) return "workdir";
        if (std.mem.eql(u8, raw, "command")) return "command_text";
        return error.InvalidModeArg;
    }

    fn cmdToolAudit(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const mode = opts.mode orelse "summary";
        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        try appendTimeBoundsForField(allocator, &where, "timestamp", opts);
        try appendOptionalStringEq(allocator, &where, "tool_name", opts.tool);
        try appendOptionalStringEq(allocator, &where, "primary_executable", opts.executable_text);
        try appendOptionalStringEq(allocator, &where, "workdir", opts.workdir_text);
        try appendOptionalContains(allocator, &where, "command_text", opts.contains);

        if (std.mem.eql(u8, mode, "summary")) {
            const group_field = try toolAuditGroupField(opts.group_by_text);
            const group_by = [_][]const u8{group_field};
            var columns = [_][]const u8{ group_field, "calls", "sessions", "avg_wall_ms", "max_wall_ms" };
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .group_by = group_by[0..],
                .metrics = &.{
                    .{ .op = .count, .alias = "calls" },
                    .{ .op = .count_distinct, .field = "session_id", .alias = "sessions" },
                    .{ .op = .avg, .field = "wall_time_ms", .alias = "avg_wall_ms" },
                    .{ .op = .max, .field = "wall_time_ms", .alias = "max_wall_ms" },
                },
                .sort = &.{.{ .field = "calls", .descending = true }},
                .limit = queryLimit(opts, 20),
            };
            return runQueryLiftDataset(allocator, "tool_invocations", sessions_root, query_spec, opts, columns[0..]);
        }

        if (std.mem.eql(u8, mode, "rows") or std.mem.eql(u8, mode, "unresolved")) {
            if (std.mem.eql(u8, mode, "unresolved")) {
                try where.append(allocator, .{ .field = "unresolved", .op = .eq, .value = .{ .scalar = .{ .bool = true } } });
            }
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .select = tool_audit_row_columns[0..],
                .sort = &.{.{ .field = "timestamp", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "tool_invocations", sessions_root, query_spec, opts, tool_audit_row_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "args")) {
            var arg_where: std.ArrayList(spec.WhereClause) = .empty;
            defer arg_where.deinit(allocator);
            try appendTimeBoundsForField(allocator, &arg_where, "timestamp", opts);
            try appendOptionalStringEq(allocator, &arg_where, "tool_name", opts.tool);
            try appendOptionalContains(allocator, &arg_where, "value_text", opts.contains);
            const query_spec = spec.QuerySpec{
                .where = arg_where.items,
                .group_by = &.{ "tool_name", "arg_path" },
                .metrics = &.{.{ .op = .count, .alias = "count" }},
                .sort = &.{.{ .field = "count", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "tool_call_args", sessions_root, query_spec, opts, tool_audit_arg_columns[0..]);
        }

        return error.InvalidModeArg;
    }

    fn appendMemoryParams(
        allocator: std.mem.Allocator,
        params: *std.ArrayList(spec.ParamSpec),
        opts: Options,
        include_preview: bool,
    ) !void {
        if (opts.memory_root_text) |memory_root| try params.append(allocator, .{ .key = "memory_root", .value = .{ .string = memory_root } });
        if (opts.state_db_path) |state_db_path| try params.append(allocator, .{ .key = "state_db_path", .value = .{ .string = state_db_path } });
        if (opts.extensions_root_text) |extensions_root| try params.append(allocator, .{ .key = "extensions_root", .value = .{ .string = extensions_root } });
        if (include_preview) try params.append(allocator, .{ .key = "include_preview", .value = .{ .bool = true } });
    }

    fn cmdMemoryInventory(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const mode = opts.mode orelse "categories";
        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        var params: std.ArrayList(spec.ParamSpec) = .empty;
        defer params.deinit(allocator);

        if (std.mem.eql(u8, mode, "categories")) {
            try appendMemoryParams(allocator, &params, opts, false);
            try appendOptionalContains(allocator, &where, "relative_path", opts.contains);
            try appendOptionalRegex(allocator, &where, "relative_path", opts.regex);
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .params = params.items,
                .group_by = &.{ "category", "extension" },
                .metrics = &.{
                    .{ .op = .count, .alias = "files" },
                    .{ .op = .sum, .field = "size_bytes", .alias = "bytes" },
                    .{ .op = .max, .field = "modified_at", .alias = "latest_modified" },
                },
                .sort = &.{.{ .field = "files", .descending = true }},
                .limit = opts.limit,
            };
            return runQueryLiftDataset(allocator, "memory_files", sessions_root, query_spec, opts, memory_inventory_category_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "files")) {
            try appendMemoryParams(allocator, &params, opts, true);
            try appendOptionalContains(allocator, &where, "relative_path", opts.contains);
            try appendOptionalRegex(allocator, &where, "relative_path", opts.regex);
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .params = params.items,
                .select = memory_inventory_file_columns[0..],
                .sort = &.{.{ .field = "modified_at", .descending = true }},
                .limit = queryLimit(opts, 100),
            };
            return runQueryLiftDataset(allocator, "memory_files", sessions_root, query_spec, opts, memory_inventory_file_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "blocks")) {
            try appendMemoryParams(allocator, &params, opts, false);
            try appendOptionalContains(allocator, &where, "body", opts.contains);
            try appendOptionalRegex(allocator, &where, "body", opts.regex);
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .params = params.items,
                .select = memory_inventory_block_columns[0..],
                .sort = &.{.{ .field = "updated_at", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "memory_blocks", sessions_root, query_spec, opts, memory_inventory_block_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "stage1")) {
            try appendMemoryParams(allocator, &params, opts, false);
            try appendOptionalContains(allocator, &where, "title", opts.contains);
            try appendOptionalRegex(allocator, &where, "title", opts.regex);
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .params = params.items,
                .select = memory_inventory_stage1_columns[0..],
                .sort = &.{.{ .field = "generated_at", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "memory_stage1_outputs", sessions_root, query_spec, opts, memory_inventory_stage1_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "extensions")) {
            try appendMemoryParams(allocator, &params, opts, false);
            try appendOptionalContains(allocator, &where, "extension_name", opts.contains);
            try appendOptionalRegex(allocator, &where, "extension_name", opts.regex);
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .params = params.items,
                .select = memory_inventory_extension_columns[0..],
                .sort = &.{.{ .field = "extension_name", .descending = false }},
                .limit = opts.limit,
            };
            return runQueryLiftDataset(allocator, "memory_extensions", sessions_root, query_spec, opts, memory_inventory_extension_columns[0..]);
        }

        return error.InvalidModeArg;
    }

    fn cmdMessageSearch(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        if (opts.contains == null and opts.regex == null and opts.contains_any_text == null and opts.contains_all_text == null) {
            return error.MissingContainsArg;
        }
        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        try appendSessionTimeBounds(allocator, &where, opts);
        const role_values = try appendRolesWhere(allocator, &where, opts.roles_csv);
        defer if (role_values) |values| allocator.free(values);
        try appendOptionalContains(allocator, &where, "text", opts.contains);
        const contains_any_values = try appendCsvContainsAny(allocator, &where, "text", opts.contains_any_text);
        defer if (contains_any_values) |values| allocator.free(values);
        try appendCsvContainsAll(allocator, &where, "text", opts.contains_all_text);
        try appendOptionalRegex(allocator, &where, "text", opts.regex);

        const query_spec = spec.QuerySpec{
            .where = where.items,
            .select = message_search_columns[0..],
            .sort = &.{.{ .field = "timestamp", .descending = true }},
            .limit = queryLimit(opts, 50),
        };
        try runQueryLiftDataset(allocator, "messages", sessions_root, query_spec, opts, message_search_columns[0..]);
    }

    fn appendMessageAuditFilters(
        allocator: std.mem.Allocator,
        sessions_root: []const u8,
        where: *std.ArrayList(spec.WhereClause),
        opts: Options,
    ) !?[]u8 {
        try appendSessionTimeBounds(allocator, where, opts);
        const exclude_path = try appendCurrentSessionExclusion(allocator, sessions_root, where, opts);
        errdefer if (exclude_path) |path| allocator.free(path);
        const role_values = try appendRolesWhere(allocator, where, opts.roles_csv);
        defer if (role_values) |values| allocator.free(values);
        try appendOptionalContains(allocator, where, "text", opts.contains);
        const contains_any_values = try appendCsvContainsAny(allocator, where, "text", opts.contains_any_text);
        defer if (contains_any_values) |values| allocator.free(values);
        try appendCsvContainsAll(allocator, where, "text", opts.contains_all_text);
        try appendOptionalRegex(allocator, where, "text", opts.regex);
        return exclude_path;
    }

    fn cmdMessageAudit(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const mode = opts.mode orelse "summary";
        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        const exclude_path = try appendMessageAuditFilters(allocator, sessions_root, &where, opts);
        defer if (exclude_path) |path| allocator.free(path);

        if (std.mem.eql(u8, mode, "summary")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .group_by = &.{"role"},
                .metrics = &.{
                    .{ .op = .count, .alias = "messages" },
                    .{ .op = .count_distinct, .field = "path", .alias = "sessions" },
                    .{ .op = .sum, .field = "text_len", .alias = "chars" },
                    .{ .op = .min, .field = "timestamp", .alias = "first_seen" },
                    .{ .op = .max, .field = "timestamp", .alias = "last_seen" },
                },
                .sort = &.{.{ .field = "messages", .descending = true }},
                .limit = queryLimit(opts, 20),
            };
            return runQueryLiftDataset(allocator, "messages", sessions_root, query_spec, opts, message_audit_summary_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "rows")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .select = message_audit_row_columns[0..],
                .sort = &.{.{ .field = "timestamp", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "messages", sessions_root, query_spec, opts, message_audit_row_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "sessions")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .group_by = &.{"path"},
                .metrics = &.{
                    .{ .op = .count, .alias = "messages" },
                    .{ .op = .sum, .field = "text_len", .alias = "chars" },
                    .{ .op = .min, .field = "timestamp", .alias = "first_seen" },
                    .{ .op = .max, .field = "timestamp", .alias = "last_seen" },
                },
                .sort = &.{.{ .field = "messages", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "messages", sessions_root, query_spec, opts, message_audit_session_columns[0..]);
        }

        return error.InvalidModeArg;
    }

    fn appendSkillCohortFilters(
        allocator: std.mem.Allocator,
        sessions_root: []const u8,
        where: *std.ArrayList(spec.WhereClause),
        opts: Options,
        include_exact_skill: bool,
    ) !?[]u8 {
        try appendSessionTimeBounds(allocator, where, opts);
        const exclude_path = try appendCurrentSessionExclusion(allocator, sessions_root, where, opts);
        errdefer if (exclude_path) |path| allocator.free(path);
        const role_values = try appendRolesWhere(allocator, where, opts.roles_csv);
        defer if (role_values) |values| allocator.free(values);
        if (include_exact_skill) try appendOptionalStringEq(allocator, where, "skill", opts.skill);
        const contains_any_values = try appendCsvContainsAny(allocator, where, "skill", opts.contains_any_text);
        defer if (contains_any_values) |values| allocator.free(values);
        try appendOptionalContains(allocator, where, "snippet", opts.contains);
        try appendOptionalRegex(allocator, where, "snippet", opts.regex);
        return exclude_path;
    }

    fn cmdSkillCohort(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const mode = opts.mode orelse "cohort";
        if (std.mem.eql(u8, mode, "cohort")) return cmdSkillCohortCohortMode(allocator, sessions_root, opts);

        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        const exclude_path = try appendSkillCohortFilters(allocator, sessions_root, &where, opts, true);
        defer if (exclude_path) |path| allocator.free(path);

        if (std.mem.eql(u8, mode, "summary")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .group_by = &.{"skill"},
                .metrics = &.{
                    .{ .op = .count, .alias = "mentions" },
                    .{ .op = .count_distinct, .field = "path", .alias = "sessions" },
                    .{ .op = .min, .field = "timestamp", .alias = "first_seen" },
                    .{ .op = .max, .field = "timestamp", .alias = "last_seen" },
                },
                .sort = &.{.{ .field = "mentions", .descending = true }},
                .limit = queryLimit(opts, 20),
            };
            return runQueryLiftDataset(allocator, "skill_mentions", sessions_root, query_spec, opts, skill_cohort_summary_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "mentions")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .select = skill_cohort_mention_columns[0..],
                .sort = &.{.{ .field = "timestamp", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "skill_mentions", sessions_root, query_spec, opts, skill_cohort_mention_columns[0..]);
        }

        return error.InvalidModeArg;
    }

    const SkillCohortAggregate = struct {
        mentions: i64 = 0,
        sessions: StringSet,
        first_seen: ?[]u8 = null,
        last_seen: ?[]u8 = null,

        fn init(allocator: std.mem.Allocator) SkillCohortAggregate {
            return .{ .sessions = StringSet.init(allocator) };
        }

        fn deinit(self: *SkillCohortAggregate, allocator: std.mem.Allocator) void {
            self.sessions.deinit();
            if (self.first_seen) |value| allocator.free(value);
            if (self.last_seen) |value| allocator.free(value);
        }
    };

    fn updateSkillCohortTimestamp(
        allocator: std.mem.Allocator,
        aggregate: *SkillCohortAggregate,
        timestamp: []const u8,
    ) !void {
        if (aggregate.first_seen == null or compareNormalizedTimestamp(timestamp, aggregate.first_seen.?) == .lt) {
            if (aggregate.first_seen) |old| allocator.free(old);
            aggregate.first_seen = try allocator.dupe(u8, timestamp);
        }
        if (aggregate.last_seen == null or compareNormalizedTimestamp(timestamp, aggregate.last_seen.?) == .gt) {
            if (aggregate.last_seen) |old| allocator.free(old);
            aggregate.last_seen = try allocator.dupe(u8, timestamp);
        }
    }

    fn cmdSkillCohortCohortMode(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const cohort_skill = opts.skill orelse return error.MissingSkillArg;
        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        const exclude_path = try appendSkillCohortFilters(allocator, sessions_root, &where, opts, false);
        defer if (exclude_path) |path| allocator.free(path);
        const base_query = spec.QuerySpec{
            .where = where.items,
            .select = skill_cohort_mention_columns[0..],
            .sort = &.{.{ .field = "timestamp", .descending = false }},
        };
        if (opts.show_query) return writeGeneratedQuerySpec(allocator, "skill_mentions", base_query, opts.out_path);

        var rows = try collectDatasetRowsForSpec(allocator, "skill_mentions", sessions_root, base_query);
        defer deinitQueryRows(allocator, &rows);

        var target_paths = StringSet.init(allocator);
        defer target_paths.deinit();
        for (rows.items) |row| {
            const skill = scalarString(row.valueOrNull("skill")) orelse continue;
            if (!std.mem.eql(u8, skill, cohort_skill)) continue;
            const path = scalarString(row.valueOrNull("path")) orelse continue;
            try target_paths.put(path);
        }

        var aggregates = std.StringHashMap(SkillCohortAggregate).init(allocator);
        defer {
            var it = aggregates.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            aggregates.deinit();
        }

        for (rows.items) |row| {
            const path = scalarString(row.valueOrNull("path")) orelse continue;
            if (!target_paths.contains(path)) continue;
            const skill = scalarString(row.valueOrNull("skill")) orelse continue;
            const key = try allocator.dupe(u8, skill);
            const gop = try aggregates.getOrPut(key);
            if (gop.found_existing) {
                allocator.free(key);
            } else {
                gop.value_ptr.* = SkillCohortAggregate.init(allocator);
            }
            gop.value_ptr.mentions += 1;
            try gop.value_ptr.sessions.put(path);
            if (scalarString(row.valueOrNull("timestamp"))) |timestamp| {
                try updateSkillCohortTimestamp(allocator, gop.value_ptr, timestamp);
            }
        }

        var out_rows: std.ArrayList(query.Row) = .empty;
        defer deinitQueryRows(allocator, &out_rows);

        var it = aggregates.iterator();
        while (it.next()) |entry| {
            var out = query.Row.init(allocator);
            try out.putOwnedKey("cohort_skill", .{ .string = cohort_skill });
            try out.putOwnedKey("skill", .{ .string = entry.key_ptr.* });
            try out.putOwnedKey("mentions", .{ .int = entry.value_ptr.mentions });
            try out.putOwnedKey("sessions", .{ .int = @intCast(entry.value_ptr.sessions.count()) });
            try out.putOwnedKey("cohort_sessions", .{ .int = @intCast(target_paths.count()) });
            if (entry.value_ptr.first_seen) |value| {
                try out.putOwnedKey("first_seen", .{ .string = value });
            } else {
                try out.putOwnedKey("first_seen", .null);
            }
            if (entry.value_ptr.last_seen) |value| {
                try out.putOwnedKey("last_seen", .{ .string = value });
            } else {
                try out.putOwnedKey("last_seen", .null);
            }
            try out_rows.append(allocator, out);
        }

        var result = try query.execute(allocator, out_rows.items, .{
            .sort = &.{.{ .field = "mentions", .descending = true }},
            .limit = queryLimit(opts, 50),
        });
        defer result.deinit(allocator);
        try output.writeOutput(allocator, opts.format, result.rows.items, skill_cohort_columns[0..], opts.out_path);
    }

    fn cmdToolSearch(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const mode = opts.mode orelse "rows";
        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        try appendTimeBoundsForField(allocator, &where, "timestamp", opts);
        const exclude_path = try appendCurrentSessionExclusion(allocator, sessions_root, &where, opts);
        defer if (exclude_path) |path| allocator.free(path);
        try appendOptionalStringEq(allocator, &where, "tool_name", opts.tool);
        try appendOptionalStringEq(allocator, &where, "primary_executable", opts.executable_text);
        try appendOptionalStringEq(allocator, &where, "workdir", opts.workdir_text);
        try appendOptionalContains(allocator, &where, "command_text", opts.contains);
        try appendOptionalRegex(allocator, &where, "command_text", opts.regex);

        if (std.mem.eql(u8, mode, "rows")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .select = tool_search_row_columns[0..],
                .sort = &.{.{ .field = "timestamp", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "tool_invocations", sessions_root, query_spec, opts, tool_search_row_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "summary")) {
            const group_field = try toolAuditGroupField(opts.group_by_text);
            const group_by = [_][]const u8{group_field};
            var columns = [_][]const u8{ group_field, "calls", "sessions", "avg_wall_ms", "max_wall_ms" };
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .group_by = group_by[0..],
                .metrics = &.{
                    .{ .op = .count, .alias = "calls" },
                    .{ .op = .count_distinct, .field = "session_id", .alias = "sessions" },
                    .{ .op = .avg, .field = "wall_time_ms", .alias = "avg_wall_ms" },
                    .{ .op = .max, .field = "wall_time_ms", .alias = "max_wall_ms" },
                },
                .sort = &.{.{ .field = "calls", .descending = true }},
                .limit = queryLimit(opts, 20),
            };
            return runQueryLiftDataset(allocator, "tool_invocations", sessions_root, query_spec, opts, columns[0..]);
        }

        if (std.mem.eql(u8, mode, "args")) {
            var arg_where: std.ArrayList(spec.WhereClause) = .empty;
            defer arg_where.deinit(allocator);
            try appendTimeBoundsForField(allocator, &arg_where, "timestamp", opts);
            const arg_exclude_path = try appendCurrentSessionExclusion(allocator, sessions_root, &arg_where, opts);
            defer if (arg_exclude_path) |path| allocator.free(path);
            try appendOptionalStringEq(allocator, &arg_where, "tool_name", opts.tool);
            try appendOptionalContains(allocator, &arg_where, "value_text", opts.contains);
            try appendOptionalRegex(allocator, &arg_where, "value_text", opts.regex);
            const query_spec = spec.QuerySpec{
                .where = arg_where.items,
                .group_by = &.{ "tool_name", "arg_path", "value_kind", "value_text" },
                .metrics = &.{.{ .op = .count, .alias = "count" }},
                .sort = &.{.{ .field = "count", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "tool_call_args", sessions_root, query_spec, opts, tool_search_arg_columns[0..]);
        }

        return error.InvalidModeArg;
    }

    fn appendGoalWorkflowWhere(
        allocator: std.mem.Allocator,
        where_out: *std.ArrayList(spec.WhereClause),
        raw_opt: ?[]const u8,
    ) !?[]spec.Scalar {
        const raw = raw_opt orelse return null;
        var values: std.ArrayList(spec.Scalar) = .empty;
        defer values.deinit(allocator);

        var split = std.mem.splitScalar(u8, raw, ',');
        while (split.next()) |part_raw| {
            const part = std.mem.trim(u8, part_raw, " \t\r\n");
            if (part.len == 0) continue;
            try values.append(allocator, .{ .string = part });
        }
        if (values.items.len == 0) return error.InvalidModeArg;
        const owned = try values.toOwnedSlice(allocator);
        try where_out.append(allocator, .{
            .field = "objective_kind",
            .op = .in,
            .value = .{ .list = owned },
        });
        return owned;
    }

    fn cmdGoalAudit(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const mode = if (opts.summary) "summary" else opts.mode orelse "summary";
        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);

        try appendTimeBoundsForField(allocator, &where, "timestamp", opts);
        const path_filter = if (opts.path) |path| try toAbsolutePath(allocator, path) else null;
        defer if (path_filter) |path| allocator.free(path);
        try appendOptionalStringEq(allocator, &where, "path", path_filter);
        try appendOptionalContains(allocator, &where, "path", opts.session_id);
        const workflow_values = try appendGoalWorkflowWhere(allocator, &where, opts.workflow);
        defer if (workflow_values) |values| allocator.free(values);
        try appendOptionalStringEq(allocator, &where, "status", opts.status);
        try appendOptionalContains(allocator, &where, "objective", opts.contains);
        if (opts.duration_gte_seconds) |seconds| {
            try where.append(allocator, .{
                .field = "time_used_seconds",
                .op = .gte,
                .value = .{ .scalar = .{ .int = seconds } },
            });
        }
        const exclude_path = try appendCurrentSessionExclusion(allocator, sessions_root, &where, opts);
        defer if (exclude_path) |path| allocator.free(path);

        if (std.mem.eql(u8, mode, "rows")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .select = goal_audit_row_columns[0..],
                .sort = &.{.{ .field = "timestamp", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "goal_runs", sessions_root, query_spec, opts, goal_audit_row_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "summary")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .group_by = &.{"objective_kind"},
                .metrics = &.{
                    .{ .op = .count, .alias = "runs" },
                    .{ .op = .count_distinct, .field = "session_id", .alias = "sessions" },
                    .{ .op = .sum, .field = "review_invocation_count", .alias = "review_invocations" },
                    .{ .op = .max, .field = "time_used_seconds", .alias = "max_time_used_seconds" },
                },
                .sort = &.{.{ .field = "runs", .descending = true }},
                .limit = queryLimit(opts, 20),
            };
            return runQueryLiftDataset(allocator, "goal_runs", sessions_root, query_spec, opts, goal_audit_summary_columns[0..]);
        }

        return error.InvalidModeArg;
    }

    fn buildMemoryExtensionQuery(
        allocator: std.mem.Allocator,
        opts: Options,
        mode: []const u8,
        where: *std.ArrayList(spec.WhereClause),
        params: *std.ArrayList(spec.ParamSpec),
    ) !spec.QuerySpec {
        try appendMemoryParams(allocator, params, opts, false);
        try appendOptionalContains(allocator, where, "extension_name", opts.contains);
        try appendOptionalRegex(allocator, where, "extension_name", opts.regex);
        if (std.mem.eql(u8, mode, "rows")) {
            return .{
                .where = where.items,
                .params = params.items,
                .select = memory_inventory_extension_columns[0..],
                .sort = &.{.{ .field = "extension_name", .descending = false }},
                .limit = queryLimit(opts, 100),
            };
        }
        return .{
            .where = where.items,
            .params = params.items,
            .select = memory_inventory_extension_columns[0..],
            .sort = &.{.{ .field = "extension_name", .descending = false }},
        };
    }

    fn cmdMemoryExtensionAudit(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const mode = opts.mode orelse "rows";
        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        var params: std.ArrayList(spec.ParamSpec) = .empty;
        defer params.deinit(allocator);
        const query_spec = try buildMemoryExtensionQuery(allocator, opts, mode, &where, &params);
        if (opts.show_query) return writeGeneratedQuerySpec(allocator, "memory_extensions", query_spec, opts.out_path);

        var collected = try collectDatasetRowsForSpec(allocator, "memory_extensions", sessions_root, query_spec);
        defer deinitQueryRows(allocator, &collected);

        var result = try query.execute(allocator, collected.items, query_spec);
        defer result.deinit(allocator);

        if (std.mem.eql(u8, mode, "rows")) {
            var out_rows: std.ArrayList(query.Row) = .empty;
            defer deinitQueryRows(allocator, &out_rows);
            for (result.rows.items) |row| {
                var out = try row.cloneSelected(allocator, memory_inventory_extension_columns[0..]);
                errdefer out.deinit();
                try out.putOwnedKey("provenance_status", .{ .string = "inventory_only" });
                try out.putOwnedKey("causality_claimed", .{ .bool = false });
                try out_rows.append(allocator, out);
            }
            return output.writeOutput(allocator, opts.format, out_rows.items, memory_extension_row_columns[0..], opts.out_path);
        }

        if (std.mem.eql(u8, mode, "summary")) {
            var extensions: i64 = 0;
            var with_instructions: i64 = 0;
            var total_bytes: i64 = 0;
            for (result.rows.items) |row| {
                extensions += 1;
                switch (row.valueOrNull("has_instructions")) {
                    .bool => |flag| {
                        if (flag) with_instructions += 1;
                    },
                    else => {},
                }
                switch (row.valueOrNull("size_bytes")) {
                    .int => |n| total_bytes += n,
                    else => {},
                }
            }
            var out_rows: std.ArrayList(query.Row) = .empty;
            defer deinitQueryRows(allocator, &out_rows);
            var out = query.Row.init(allocator);
            try out.putOwnedKey("row_kind", .{ .string = "summary" });
            try out.putOwnedKey("extensions", .{ .int = extensions });
            try out.putOwnedKey("with_instructions", .{ .int = with_instructions });
            try out.putOwnedKey("without_instructions", .{ .int = extensions - with_instructions });
            try out.putOwnedKey("total_bytes", .{ .int = total_bytes });
            try out.putOwnedKey("provenance_status", .{ .string = "inventory_only" });
            try out.putOwnedKey("causality_claimed", .{ .bool = false });
            try out_rows.append(allocator, out);
            return output.writeOutput(allocator, opts.format, out_rows.items, memory_extension_summary_columns[0..], opts.out_path);
        }

        return error.InvalidModeArg;
    }

    const TokenWindowPoint = struct {
        row_index: usize,
        timestamp: []const u8,
        timestamp_ms: i64,
        delta_total_tokens: i64,
        path: []const u8,
    };

    fn tokenWindowPointLess(_: void, lhs: TokenWindowPoint, rhs: TokenWindowPoint) bool {
        if (lhs.timestamp_ms == rhs.timestamp_ms) return std.mem.order(u8, lhs.path, rhs.path) == .lt;
        return lhs.timestamp_ms < rhs.timestamp_ms;
    }

    const TokenWindowBest = struct {
        left: usize = 0,
        right: usize = 0,
        total_tokens: i64 = 0,
        rows: usize = 0,
    };

    fn computeBestTokenWindow(points: []const TokenWindowPoint, window_ms: i64) TokenWindowBest {
        var best = TokenWindowBest{};
        if (points.len == 0) return best;
        var left: usize = 0;
        var total: i64 = 0;
        for (points, 0..) |point, right| {
            total += point.delta_total_tokens;
            while (left <= right and point.timestamp_ms - points[left].timestamp_ms >= window_ms) {
                total -= points[left].delta_total_tokens;
                left += 1;
            }
            const row_count = right - left + 1;
            if (row_count > 0 and (best.rows == 0 or total > best.total_tokens)) {
                best = .{
                    .left = left,
                    .right = right,
                    .total_tokens = total,
                    .rows = row_count,
                };
            }
        }
        return best;
    }

    fn tokenWindowPathCount(allocator: std.mem.Allocator, points: []const TokenWindowPoint, best: TokenWindowBest) !usize {
        if (best.rows == 0) return 0;
        var paths = StringSet.init(allocator);
        defer paths.deinit();
        var idx = best.left;
        while (idx <= best.right) : (idx += 1) {
            try paths.put(points[idx].path);
        }
        return paths.count();
    }

    fn cmdTokenWindow(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const mode = opts.mode orelse "summary";
        if (opts.window_hours > @divFloor(std.math.maxInt(i64), 3_600_000)) return error.InvalidLimit;
        const window_ms = opts.window_hours * 3_600_000;

        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        try appendTimeBoundsForField(allocator, &where, "timestamp", opts);
        const path_filter = if (opts.path) |path| try toAbsolutePath(allocator, path) else null;
        defer if (path_filter) |path| allocator.free(path);
        try appendOptionalStringEq(allocator, &where, "path", path_filter);
        const exclude_path = try appendCurrentSessionExclusion(allocator, sessions_root, &where, opts);
        defer if (exclude_path) |path| allocator.free(path);
        const query_spec = spec.QuerySpec{
            .where = where.items,
            .select = token_window_row_columns[0..],
            .sort = &.{.{ .field = "timestamp", .descending = false }},
        };
        if (opts.show_query) return writeGeneratedQuerySpec(allocator, "token_deltas", query_spec, opts.out_path);

        var collected = try collectDatasetRowsForSpec(allocator, "token_deltas", sessions_root, query_spec);
        defer deinitQueryRows(allocator, &collected);

        var filtered = try query.execute(allocator, collected.items, query_spec);
        defer filtered.deinit(allocator);

        var points: std.ArrayList(TokenWindowPoint) = .empty;
        defer points.deinit(allocator);
        for (filtered.rows.items, 0..) |row, idx| {
            const timestamp = scalarString(row.valueOrNull("timestamp")) orelse continue;
            const timestamp_ms = time_utils.parseIsoTimestampMillis(timestamp) orelse continue;
            const delta = switch (row.valueOrNull("delta_total_tokens")) {
                .int => |value| value,
                else => continue,
            };
            const path = scalarString(row.valueOrNull("path")) orelse "";
            try points.append(allocator, .{
                .row_index = idx,
                .timestamp = timestamp,
                .timestamp_ms = timestamp_ms,
                .delta_total_tokens = delta,
                .path = path,
            });
        }
        std.mem.sort(TokenWindowPoint, points.items, {}, tokenWindowPointLess);
        const best = computeBestTokenWindow(points.items, window_ms);

        if (std.mem.eql(u8, mode, "rows")) {
            var out_rows: std.ArrayList(query.Row) = .empty;
            defer deinitQueryRows(allocator, &out_rows);
            if (best.rows > 0) {
                var idx = best.left;
                while (idx <= best.right) : (idx += 1) {
                    const source = filtered.rows.items[points.items[idx].row_index];
                    try out_rows.append(allocator, try source.cloneSelected(allocator, token_window_row_columns[0..]));
                }
            }
            return output.writeOutput(allocator, opts.format, out_rows.items, token_window_row_columns[0..], opts.out_path);
        }

        if (std.mem.eql(u8, mode, "summary")) {
            const path_count = try tokenWindowPathCount(allocator, points.items, best);
            var out_rows: std.ArrayList(query.Row) = .empty;
            defer deinitQueryRows(allocator, &out_rows);
            var out = query.Row.init(allocator);
            try out.putOwnedKey("window_hours", .{ .int = opts.window_hours });
            if (best.rows > 0) {
                const start = points.items[best.left].timestamp;
                const observed_end = points.items[best.right].timestamp;
                try out.putOwnedKey("window_start", .{ .string = start });
                try out.putOwnedKey("window_end", .{ .string = observed_end });
                try out.putOwnedKey("observed_end", .{ .string = observed_end });
            } else {
                try out.putOwnedKey("window_start", .null);
                try out.putOwnedKey("window_end", .null);
                try out.putOwnedKey("observed_end", .null);
            }
            try out.putOwnedKey("total_tokens", .{ .int = best.total_tokens });
            try out.putOwnedKey("rows", .{ .int = @intCast(best.rows) });
            try out.putOwnedKey("path_count", .{ .int = @intCast(path_count) });
            try out.putOwnedKey("source_dataset", .{ .string = "token_deltas" });
            try out.putOwnedKey("sorted_by", .{ .string = "timestamp_ascending" });
            if (opts.since) |value| {
                try out.putOwnedKey("since", .{ .string = value });
            } else {
                try out.putOwnedKey("since", .null);
            }
            if (opts.until) |value| {
                try out.putOwnedKey("until", .{ .string = value });
            } else {
                try out.putOwnedKey("until", .null);
            }
            try out_rows.append(allocator, out);
            return output.writeOutput(allocator, opts.format, out_rows.items, token_window_summary_columns[0..], opts.out_path);
        }

        return error.InvalidModeArg;
    }

    fn cmdWorkdirReport(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
        const mode = opts.mode orelse "summary";
        var where: std.ArrayList(spec.WhereClause) = .empty;
        defer where.deinit(allocator);
        try appendTimeBoundsForField(allocator, &where, "start_time", opts);
        try appendOptionalStringEq(allocator, &where, "cwd", opts.workdir_text);
        try appendOptionalContains(allocator, &where, "cwd", opts.contains);
        const contains_any_values = try appendCsvContainsAny(allocator, &where, "cwd", opts.contains_any_text);
        defer if (contains_any_values) |values| allocator.free(values);

        if (std.mem.eql(u8, mode, "summary")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .group_by = &.{"cwd"},
                .metrics = &.{
                    .{ .op = .count, .alias = "sessions" },
                    .{ .op = .sum, .field = "turn_count", .alias = "turns" },
                    .{ .op = .sum, .field = "total_tokens", .alias = "total_tokens" },
                    .{ .op = .min, .field = "start_time", .alias = "first_seen" },
                    .{ .op = .max, .field = "start_time", .alias = "last_seen" },
                },
                .sort = &.{.{ .field = "sessions", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "sessions", sessions_root, query_spec, opts, workdir_report_summary_columns[0..]);
        }

        if (std.mem.eql(u8, mode, "sessions")) {
            const query_spec = spec.QuerySpec{
                .where = where.items,
                .select = workdir_report_session_columns[0..],
                .sort = &.{.{ .field = "start_time", .descending = true }},
                .limit = queryLimit(opts, 50),
            };
            return runQueryLiftDataset(allocator, "sessions", sessions_root, query_spec, opts, workdir_report_session_columns[0..]);
        }

        return error.InvalidModeArg;
    }
};

const ArtifactKind = enum {
    auto,
    session,
    memory,
    orchestration,
    tooling,
    prompt,
};

const ArtifactSurface = enum {
    auto,
    messages,
    tool_calls,
    memory_blocks,
};

const ArtifactFollow = enum {
    none,
    auto,
};

const MemoryTrace = enum {
    none,
    auto,
    always,
};

const ArtifactStats = struct {
    surfaces_scanned: i64 = 0,
    candidate_files: i64 = 0,
    files_opened: i64 = 0,
    rows_examined: i64 = 0,
    rows_emitted: i64 = 0,
    duration_ms: i64 = 0,
    used_time_bounds: bool = false,
    used_targeted_session: bool = false,
};

fn cmdArtifactSearch(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const query_text = opts.contains orelse opts.regex orelse return error.MissingContainsArg;
    const use_regex = opts.regex != null;
    const kind = try parseArtifactKind(opts.kind_text);
    const surface = try parseArtifactSurface(opts.surface_text);
    const follow = try parseArtifactFollow(opts.follow_text);
    _ = follow;

    const start_ms = @divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000);
    var stats = ArtifactStats{
        .used_time_bounds = opts.since != null or opts.until != null,
        .used_targeted_session = opts.path != null or opts.session_id != null,
    };

    var hit_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &hit_rows);

    if (shouldSearchSurface(kind, surface, .memory_blocks)) {
        stats.surfaces_scanned += 1;
        try searchMemoryBlockHits(allocator, query_text, use_regex, &stats, &hit_rows);
    }
    if (shouldSearchSurface(kind, surface, .messages)) {
        stats.surfaces_scanned += 1;
        try searchMessageHits(allocator, sessions_root, opts, query_text, use_regex, &stats, &hit_rows);
    }
    if (shouldSearchSurface(kind, surface, .tool_calls)) {
        stats.surfaces_scanned += 1;
        try searchToolCallHits(allocator, sessions_root, opts, query_text, use_regex, &stats, &hit_rows);
    }

    const duration_delta = @divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000) - start_ms;
    stats.duration_ms = @intCast(@max(duration_delta, 0));

    const limit = if (opts.limit == 0) 20 else opts.limit;
    const sort = [_]spec.SortSpec{
        .{ .field = "score", .descending = true },
        .{ .field = "timestamp", .descending = true },
    };
    const select_base = [_][]const u8{
        "surface",
        "path",
        "session_id",
        "timestamp",
        "label",
        "snippet",
        "match_kind",
        "score",
        "next_action_kind",
        "next_action",
    };
    const select_with_stats = [_][]const u8{
        "surface",
        "path",
        "session_id",
        "timestamp",
        "label",
        "snippet",
        "match_kind",
        "score",
        "next_action_kind",
        "next_action",
        "surfaces_scanned",
        "candidate_files",
        "files_opened",
        "rows_examined",
        "rows_emitted",
        "duration_ms",
        "used_time_bounds",
        "used_targeted_session",
    };
    const query_spec = spec.QuerySpec{
        .sort = sort[0..],
        .limit = limit,
        .select = if (opts.stats) select_with_stats[0..] else select_base[0..],
    };
    var result = try query.execute(allocator, hit_rows.items, query_spec);
    defer result.deinit(allocator);

    stats.rows_emitted = @intCast(result.rows.items.len);
    if (opts.stats) {
        for (result.rows.items) |*row| try attachArtifactStats(row, stats);
    }

    const cols = if (opts.stats) select_with_stats[0..] else select_base[0..];
    try output.writeOutput(allocator, opts.format, result.rows.items, cols, opts.out_path);
}

fn parseArtifactKind(raw_opt: ?[]const u8) !ArtifactKind {
    const raw = raw_opt orelse return .auto;
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "session")) return .session;
    if (std.mem.eql(u8, raw, "memory")) return .memory;
    if (std.mem.eql(u8, raw, "orchestration")) return .orchestration;
    if (std.mem.eql(u8, raw, "tooling")) return .tooling;
    if (std.mem.eql(u8, raw, "prompt")) return .prompt;
    return error.InvalidModeArg;
}

fn parseArtifactSurface(raw_opt: ?[]const u8) !ArtifactSurface {
    const raw = raw_opt orelse return .auto;
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "messages")) return .messages;
    if (std.mem.eql(u8, raw, "tool_calls")) return .tool_calls;
    if (std.mem.eql(u8, raw, "memory_blocks")) return .memory_blocks;
    return error.InvalidDatasetArg;
}

fn parseArtifactFollow(raw_opt: ?[]const u8) !ArtifactFollow {
    const raw = raw_opt orelse return .auto;
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "none")) return .none;
    return error.InvalidModeArg;
}

fn parseMemoryTrace(raw_opt: ?[]const u8) !MemoryTrace {
    const raw = raw_opt orelse return .auto;
    if (std.mem.eql(u8, raw, "none")) return .none;
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "always")) return .always;
    return error.InvalidModeArg;
}

fn shouldSearchSurface(kind: ArtifactKind, chosen: ArtifactSurface, candidate: ArtifactSurface) bool {
    if (chosen != .auto) return chosen == candidate;
    return switch (kind) {
        .memory => candidate == .memory_blocks,
        .orchestration, .tooling => candidate == .tool_calls,
        .prompt, .session => candidate == .messages or candidate == .tool_calls,
        .auto => true,
    };
}

fn parseArtifactMessageOptions(opts: Options) !datasets.messages.ParseOptions {
    var next = opts;
    if (next.roles_csv == null) next.roles_csv = "user,assistant";
    return parseSessionPromptMessageOptions(next);
}

fn searchMessageHits(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
    query_text: []const u8,
    use_regex: bool,
    stats: *ArtifactStats,
    out_rows: *std.ArrayList(query.Row),
) !void {
    const parse_options = try parseArtifactMessageOptions(opts);
    const day_filter = deriveSessionDayPathFilterFromOptions(opts);
    var input_paths = try resolveSessionPromptInputPaths(allocator, sessions_root, opts, day_filter);
    defer freePathList(allocator, &input_paths);
    stats.candidate_files += @intCast(input_paths.items.len);

    for (input_paths.items) |path| {
        const content = try readFileAllocOrSkip(allocator, path);
        if (content == null) continue;
        defer allocator.free(content.?);
        stats.files_opened += 1;

        const parsed = try datasets.messages.parseJsonl(allocator, path, content.?, parse_options);
        defer datasets.messages.freeRows(allocator, parsed);
        stats.rows_examined += @intCast(parsed.len);

        for (parsed) |row| {
            const score = try matchScoreForText(allocator, query_text, use_regex, &.{row.text});
            if (score == null) continue;
            const session_id = inferSessionIdFromPath(row.path);
            const next_action = try std.fmt.allocPrint(
                allocator,
                "seq session-prompts --session-id {s} --roles user,assistant --strip-skill-blocks --limit 40 --format jsonl",
                .{session_id},
            );
            defer allocator.free(next_action);
            try appendArtifactHit(
                allocator,
                out_rows,
                "messages",
                row.path,
                session_id,
                row.timestamp,
                row.role,
                row.text,
                if (use_regex) "regex" else "contains",
                score.?,
                "session-prompts",
                next_action,
            );
        }
    }
}

fn searchToolCallHits(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
    query_text: []const u8,
    use_regex: bool,
    stats: *ArtifactStats,
    out_rows: *std.ArrayList(query.Row),
) !void {
    const day_filter = deriveSessionDayPathFilterFromOptions(opts);
    var input_paths = try resolveOrchestrationInputPaths(allocator, sessions_root, opts, day_filter);
    defer freePathList(allocator, &input_paths);
    stats.candidate_files += @intCast(input_paths.items.len);

    for (input_paths.items) |session_path| {
        stats.files_opened += 1;
        var records: std.ArrayList(InvocationRecord) = .empty;
        defer deinitInvocationRecords(allocator, &records);
        try collectInvocationRecordsFromSession(allocator, session_path, &records);
        stats.rows_examined += @intCast(records.items.len);

        for (records.items) |record| {
            if (opts.tool) |required_tool| {
                if (record.tool_name == null or !std.mem.eql(u8, record.tool_name.?, required_tool)) continue;
            }
            if (opts.workdir_text) |required_workdir| {
                if (record.workdir == null or !std.mem.eql(u8, record.workdir.?, required_workdir)) continue;
            }
            const tool_name = record.tool_name orelse "";
            const command_text = record.command_text orelse "";
            const workdir = record.workdir orelse "";
            const arguments_text = record.arguments_text orelse "";
            const input_text = record.input_text orelse "";
            const score = try matchScoreForText(allocator, query_text, use_regex, &.{ tool_name, command_text, workdir, arguments_text, input_text });
            if (score == null) continue;

            const is_orchestration = std.mem.eql(u8, tool_name, "spawn_agent") or
                std.mem.eql(u8, tool_name, "spawn_agents_on_csv") or
                std.mem.eql(u8, tool_name, "wait") or
                std.mem.eql(u8, tool_name, "close_agent") or
                std.mem.eql(u8, tool_name, "update_plan");
            const next_action_kind = if (is_orchestration) "orchestration-concurrency" else "session-tooling";
            const next_action = if (is_orchestration)
                try std.fmt.allocPrint(allocator, "seq orchestration-concurrency --path {s} --format table", .{session_path})
            else
                try std.fmt.allocPrint(allocator, "seq session-tooling --path {s} --summary --group-by command --format table", .{session_path});
            defer allocator.free(next_action);
            const label = if (tool_name.len > 0) tool_name else "tool_call";
            const snippet = if (command_text.len > 0) command_text else if (arguments_text.len > 0) arguments_text else input_text;
            try appendArtifactHit(
                allocator,
                out_rows,
                "tool_calls",
                record.path,
                record.session_id,
                record.start_ts,
                label,
                snippet,
                if (use_regex) "regex" else "contains",
                score.?,
                next_action_kind,
                next_action,
            );
        }
    }
}

fn searchMemoryBlockHits(
    allocator: std.mem.Allocator,
    query_text: []const u8,
    use_regex: bool,
    stats: *ArtifactStats,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var parsed = try datasets.memory_blocks.collect(allocator, .{});
    defer datasets.memory_blocks.deinitRows(allocator, &parsed);
    stats.candidate_files += @intCast(parsed.items.len);
    stats.files_opened += @intCast(parsed.items.len);
    stats.rows_examined += @intCast(parsed.items.len);

    for (parsed.items) |row| {
        const keywords = row.keywords orelse "";
        const score = try matchScoreForText(allocator, query_text, use_regex, &.{ row.title, row.heading_path, row.body, keywords, row.relative_path });
        if (score == null) continue;
        const session_id = if (row.rollout_path) |rollout_path| inferSessionIdFromPath(rollout_path) else "";
        const next_action_kind = if (row.rollout_path != null) "session-prompts" else "none";
        const next_action = if (row.rollout_path) |rollout_path|
            try std.fmt.allocPrint(allocator, "seq session-prompts --path {s} --roles user,assistant --strip-skill-blocks --limit 40 --format jsonl", .{rollout_path})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(next_action);
        try appendArtifactHit(
            allocator,
            out_rows,
            "memory_blocks",
            row.path,
            session_id,
            row.updated_at,
            row.title,
            row.preview,
            if (use_regex) "regex" else "contains",
            score.?,
            next_action_kind,
            next_action,
        );
    }
}

fn matchScoreForText(
    allocator: std.mem.Allocator,
    query_text: []const u8,
    use_regex: bool,
    haystacks: []const []const u8,
) !?i64 {
    for (haystacks) |haystack| {
        if (haystack.len == 0) continue;
        if (use_regex) {
            const score = try regexScore(allocator, haystack, query_text);
            if (score != null) return score;
        } else if (containsIgnoreCaseAscii(haystack, query_text)) {
            if (eqlIgnoreCaseAscii(haystack, query_text)) return 140;
            if (startsWithIgnoreCaseAscii(haystack, query_text)) return 120;
            return 100;
        }
    }
    return null;
}

const ArtifactRegexMode = enum { exact, prefix, suffix, contains };
const ArtifactRegexAtom = struct {
    mode: ArtifactRegexMode,
    text: []const u8,
};

fn regexScore(allocator: std.mem.Allocator, haystack: []const u8, pattern: []const u8) !?i64 {
    const atoms = try compileArtifactRegexAtoms(allocator, pattern);
    defer allocator.free(atoms);
    for (atoms) |atom| {
        if (artifactRegexAtomMatch(haystack, atom)) {
            return switch (atom.mode) {
                .exact => 140,
                .prefix, .suffix => 120,
                .contains => 100,
            };
        }
    }
    return null;
}

fn compileArtifactRegexAtoms(allocator: std.mem.Allocator, pattern: []const u8) ![]const ArtifactRegexAtom {
    var atoms: std.ArrayList(ArtifactRegexAtom) = .empty;
    defer atoms.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= pattern.len) : (i += 1) {
        if (i < pattern.len and pattern[i] != '|') continue;
        const part = pattern[start..i];
        try atoms.append(allocator, try compileArtifactRegexAtom(part));
        start = i + 1;
    }
    return atoms.toOwnedSlice(allocator);
}

fn compileArtifactRegexAtom(part: []const u8) !ArtifactRegexAtom {
    if (std.mem.indexOfScalar(u8, part, '\\') != null) return error.UnsupportedRegexConstruct;
    var inner = part;
    const anchored_start = inner.len > 0 and inner[0] == '^';
    if (anchored_start) inner = inner[1..];
    const anchored_end = inner.len > 0 and inner[inner.len - 1] == '$';
    if (anchored_end) inner = inner[0 .. inner.len - 1];
    for (inner) |c| switch (c) {
        '.', '*', '+', '?', '[', ']', '(', ')', '{', '}' => return error.UnsupportedRegexConstruct,
        else => {},
    };
    return .{
        .mode = if (anchored_start and anchored_end)
            .exact
        else if (anchored_start)
            .prefix
        else if (anchored_end)
            .suffix
        else
            .contains,
        .text = inner,
    };
}

fn artifactRegexAtomMatch(haystack: []const u8, atom: ArtifactRegexAtom) bool {
    return switch (atom.mode) {
        .exact => eqlIgnoreCaseAscii(haystack, atom.text),
        .prefix => startsWithIgnoreCaseAscii(haystack, atom.text),
        .suffix => endsWithIgnoreCaseAscii(haystack, atom.text),
        .contains => containsIgnoreCaseAscii(haystack, atom.text),
    };
}

fn appendArtifactHit(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    surface: []const u8,
    path: []const u8,
    session_id: []const u8,
    timestamp: ?[]const u8,
    label: []const u8,
    snippet: []const u8,
    match_kind: []const u8,
    score: i64,
    next_action_kind: []const u8,
    next_action: []const u8,
) !void {
    var row = query.Row.init(allocator);
    try row.putOwnedKey("surface", .{ .string = surface });
    try row.putOwnedKey("path", .{ .string = path });
    if (session_id.len > 0) {
        try row.putOwnedKey("session_id", .{ .string = session_id });
    } else {
        try row.putOwnedKey("session_id", .null);
    }
    try putOptionalString(&row, "timestamp", timestamp);
    try row.putOwnedKey("label", .{ .string = label });
    try row.putOwnedKey("snippet", .{ .string = snippet[0..@min(snippet.len, 240)] });
    try row.putOwnedKey("match_kind", .{ .string = match_kind });
    try row.putOwnedKey("score", .{ .int = score });
    try row.putOwnedKey("next_action_kind", .{ .string = next_action_kind });
    if (next_action.len > 0) {
        try row.putOwnedKey("next_action", .{ .string = next_action });
    } else {
        try row.putOwnedKey("next_action", .null);
    }
    try out_rows.append(allocator, row);
}

fn attachArtifactStats(row: *query.Row, stats: ArtifactStats) !void {
    try row.putOwnedKey("surfaces_scanned", .{ .int = stats.surfaces_scanned });
    try row.putOwnedKey("candidate_files", .{ .int = stats.candidate_files });
    try row.putOwnedKey("files_opened", .{ .int = stats.files_opened });
    try row.putOwnedKey("rows_examined", .{ .int = stats.rows_examined });
    try row.putOwnedKey("rows_emitted", .{ .int = stats.rows_emitted });
    try row.putOwnedKey("duration_ms", .{ .int = stats.duration_ms });
    try row.putOwnedKey("used_time_bounds", .{ .bool = stats.used_time_bounds });
    try row.putOwnedKey("used_targeted_session", .{ .bool = stats.used_targeted_session });
}

fn cmdMemoryProvenance(allocator: std.mem.Allocator, opts: Options) !void {
    if (opts.thread_id == null and opts.rollout_summary_file == null) {
        printCliError("error: memory-provenance requires --thread-id or --rollout-summary-file\n", .{});
        return error.MissingThreadIdArg;
    }
    if (opts.thread_id != null and opts.rollout_summary_file != null) {
        printCliError("error: memory-provenance accepts exactly one of --thread-id or --rollout-summary-file\n", .{});
        return error.InvalidSessionTarget;
    }

    const trace = try parseMemoryTrace(opts.trace_text);

    var stage1_rows = try datasets.memory_stage1_outputs.collect(allocator, .{ .state_db_path = opts.state_db_path });
    defer datasets.memory_stage1_outputs.deinitRows(allocator, &stage1_rows);
    var memory_rows = try datasets.memory_blocks.collect(allocator, .{ .memory_root = opts.memory_root_text });
    defer datasets.memory_blocks.deinitRows(allocator, &memory_rows);
    var extension_rows = try datasets.memory_extensions.collect(allocator, .{ .extensions_root = opts.extensions_root_text });
    defer datasets.memory_extensions.deinitRows(allocator, &extension_rows);

    const target_thread_id = if (opts.thread_id) |thread_id|
        thread_id
    else
        try resolveThreadIdFromRolloutSummary(memory_rows.items, opts.rollout_summary_file.?);

    const stage1_row = findMemoryStage1OutputRow(stage1_rows.items, target_thread_id) orelse {
        printCliError("error: no stage1 memory row for thread {s}\n", .{target_thread_id});
        return error.SessionNotFound;
    };

    const rollout_summary_row = findRolloutSummaryRow(memory_rows.items, target_thread_id, stage1_row.rollout_path, opts.rollout_summary_file);
    if (rollout_summary_row == null) {
        printCliError("error: no rollout summary artifact for thread {s}\n", .{target_thread_id});
        return error.SessionNotFound;
    }
    const current_surfaces = try collectCurrentSurfacesSummary(allocator, memory_rows.items, target_thread_id, stage1_row.rollout_path, rollout_summary_row);
    defer allocator.free(current_surfaces);
    const active_extensions = try collectActiveExtensionsSummary(allocator, extension_rows.items);
    defer allocator.free(active_extensions);

    const next_action = try std.fmt.allocPrint(
        allocator,
        "seq session-prompts --path {s} --roles user,assistant --strip-skill-blocks --limit 40 --format jsonl",
        .{stage1_row.rollout_path},
    );
    defer allocator.free(next_action);

    const state_db_path = try datasets.codex_state_sqlite.resolveDefaultDbPath(allocator, opts.state_db_path);
    defer allocator.free(state_db_path);

    var rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &rows);

    var row = query.Row.init(allocator);
    const evidence_ref = try std.fmt.allocPrint(allocator, "stage1_outputs:{s}", .{stage1_row.thread_id});
    defer allocator.free(evidence_ref);
    try row.putOwnedKey("thread_id", .{ .string = stage1_row.thread_id });
    try putOptionalString(&row, "introduced_at", stage1_row.generated_at);
    try putOptionalString(&row, "source_updated_at", stage1_row.source_updated_at);
    try putOptionalString(&row, "generated_at", stage1_row.generated_at);
    try putOptionalInt(&row, "usage_count", stage1_row.usage_count);
    try putOptionalString(&row, "last_usage", stage1_row.last_usage);
    try row.putOwnedKey("selected_for_phase2", .{ .bool = stage1_row.selected_for_phase2 });
    if (rollout_summary_row) |summary_row| {
        try row.putOwnedKey("rollout_summary_file", .{ .string = summary_row.relative_path });
    } else {
        try row.putOwnedKey("rollout_summary_file", .null);
    }
    try row.putOwnedKey("rollout_path", .{ .string = stage1_row.rollout_path });
    try row.putOwnedKey("cwd", .{ .string = stage1_row.cwd });
    try putOptionalString(&row, "git_branch", stage1_row.git_branch);
    try row.putOwnedKey("current_surfaces", .{ .string = current_surfaces });
    try row.putOwnedKey("active_extensions", .{ .string = active_extensions });
    if (shouldExpandMemoryTrace(trace, true) and rollout_summary_row != null) {
        try row.putOwnedKey("rollout_summary_preview", .{ .string = rollout_summary_row.?.preview });
    } else {
        try row.putOwnedKey("rollout_summary_preview", .null);
    }
    try row.putOwnedKey("path", .{ .string = state_db_path });
    try row.putOwnedKey("evidence_ref", .{ .string = evidence_ref });
    try row.putOwnedKey("next_action_kind", .{ .string = "session-prompts" });
    try row.putOwnedKey("next_action", .{ .string = next_action });
    try row.putOwnedKey("warnings", .null);
    try rows.append(allocator, row);

    const cols = [_][]const u8{
        "thread_id",
        "introduced_at",
        "source_updated_at",
        "generated_at",
        "usage_count",
        "last_usage",
        "selected_for_phase2",
        "rollout_summary_file",
        "rollout_path",
        "cwd",
        "git_branch",
        "current_surfaces",
        "active_extensions",
        "rollout_summary_preview",
        "evidence_ref",
        "next_action_kind",
        "next_action",
        "warnings",
    };
    try output.writeOutput(allocator, opts.format, rows.items, cols[0..], opts.out_path);
}

fn cmdMemoryMap(allocator: std.mem.Allocator, opts: Options) !void {
    if (opts.thread_id == null and opts.contains == null and opts.regex == null) {
        printCliError("error: memory-map requires --thread-id or --contains/--regex\n", .{});
        return error.MissingContainsArg;
    }

    const trace = try parseMemoryTrace(opts.trace_text);
    const use_regex = opts.regex != null;
    const query_text = opts.contains orelse opts.regex;

    var memory_rows = try datasets.memory_blocks.collect(allocator, .{ .memory_root = opts.memory_root_text });
    defer datasets.memory_blocks.deinitRows(allocator, &memory_rows);

    var rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &rows);

    if (opts.thread_id) |thread_id| {
        var stage1_rows = try datasets.memory_stage1_outputs.collect(allocator, .{ .state_db_path = opts.state_db_path });
        defer datasets.memory_stage1_outputs.deinitRows(allocator, &stage1_rows);
        const stage1_row = findMemoryStage1OutputRow(stage1_rows.items, thread_id) orelse {
            printCliError("error: no stage1 memory row for thread {s}\n", .{thread_id});
            return error.SessionNotFound;
        };
        const state_db_path = try datasets.codex_state_sqlite.resolveDefaultDbPath(allocator, opts.state_db_path);
        defer allocator.free(state_db_path);

        const preview = try std.fmt.allocPrint(
            allocator,
            "selected_for_phase2={s} cwd={s}",
            .{ if (stage1_row.selected_for_phase2) "true" else "false", stage1_row.cwd },
        );
        defer allocator.free(preview);

        try appendMemoryMapRow(
            allocator,
            &rows,
            "stage1_outputs",
            state_db_path,
            null,
            "stage1_outputs row",
            stage1_row.thread_id,
            stage1_row.rollout_path,
            "thread_id",
            preview,
            try std.fmt.allocPrint(allocator, "stage1_outputs:{s}", .{stage1_row.thread_id}),
            "session-prompts",
            try std.fmt.allocPrint(allocator, "seq session-prompts --path {s} --roles user,assistant --strip-skill-blocks --limit 40 --format jsonl", .{stage1_row.rollout_path}),
        );

        const rollout_summary_row = findRolloutSummaryRow(memory_rows.items, thread_id, stage1_row.rollout_path, null);
        for (memory_rows.items) |block_row| {
            if (!memoryBlockMatchesThread(block_row, thread_id, stage1_row.rollout_path, rollout_summary_row)) continue;
            const next_action_kind: []const u8 = if (block_row.rollout_path != null) "session-prompts" else "none";
            const next_action = if (block_row.rollout_path) |rollout_path|
                try std.fmt.allocPrint(allocator, "seq session-prompts --path {s} --roles user,assistant --strip-skill-blocks --limit 40 --format jsonl", .{rollout_path})
            else
                try allocator.dupe(u8, "");
            try appendMemoryMapRow(
                allocator,
                &rows,
                block_row.doc_kind,
                block_row.path,
                if (block_row.heading_path.len > 0) block_row.heading_path else null,
                block_row.title,
                block_row.thread_id,
                block_row.rollout_path,
                "thread_id",
                if (shouldExpandMemoryTrace(trace, true)) block_row.preview else "",
                try buildMemoryBlockEvidenceRef(allocator, block_row),
                next_action_kind,
                next_action,
            );
        }
    } else {
        const match_kind = if (use_regex) "regex" else "contains";
        for (memory_rows.items) |block_row| {
            if (!timestampSatisfiesBounds(block_row.updated_at, opts)) continue;
            const keywords = block_row.keywords orelse "";
            const score = try matchScoreForText(allocator, query_text.?, use_regex, &.{ block_row.title, block_row.heading_path, block_row.body, keywords, block_row.relative_path });
            if (score == null) continue;
            const next_action_kind: []const u8 = if (block_row.rollout_path != null) "session-prompts" else "none";
            const next_action = if (block_row.rollout_path) |rollout_path|
                try std.fmt.allocPrint(allocator, "seq session-prompts --path {s} --roles user,assistant --strip-skill-blocks --limit 40 --format jsonl", .{rollout_path})
            else
                try allocator.dupe(u8, "");
            try appendMemoryMapRow(
                allocator,
                &rows,
                block_row.doc_kind,
                block_row.path,
                if (block_row.heading_path.len > 0) block_row.heading_path else null,
                block_row.title,
                block_row.thread_id,
                block_row.rollout_path,
                match_kind,
                block_row.preview,
                try buildMemoryBlockEvidenceRef(allocator, block_row),
                next_action_kind,
                next_action,
            );
            try rows.items[rows.items.len - 1].putOwnedKey("score", .{ .int = score.? });
            try putOptionalString(&rows.items[rows.items.len - 1], "updated_at", block_row.updated_at);
        }
    }

    const select_targeted = [_][]const u8{ "surface", "path", "heading_path", "title", "thread_id", "rollout_path", "match_kind", "preview", "evidence_ref", "next_action_kind", "next_action" };
    const select_search = [_][]const u8{ "surface", "path", "heading_path", "title", "thread_id", "rollout_path", "match_kind", "score", "updated_at", "preview", "evidence_ref", "next_action_kind", "next_action" };
    const select: []const []const u8 = if (opts.thread_id != null) select_targeted[0..] else select_search[0..];

    if (opts.thread_id == null) {
        const sort = [_]spec.SortSpec{
            .{ .field = "score", .descending = true },
            .{ .field = "updated_at", .descending = true },
        };
        const limit = if (opts.limit == 0) 20 else opts.limit;
        const query_spec = spec.QuerySpec{
            .sort = sort[0..],
            .limit = limit,
            .select = select[0..],
        };
        var result = try query.execute(allocator, rows.items, query_spec);
        defer result.deinit(allocator);
        try output.writeOutput(allocator, opts.format, result.rows.items, select[0..], opts.out_path);
    } else {
        try output.writeOutput(allocator, opts.format, rows.items, select[0..], opts.out_path);
    }
}

fn cmdMemoryHistory(allocator: std.mem.Allocator, opts: Options) !void {
    if (opts.thread_id == null and opts.contains == null and opts.regex == null) {
        printCliError("error: memory-history requires --thread-id or --contains/--regex\n", .{});
        return error.MissingContainsArg;
    }

    const trace = try parseMemoryTrace(opts.trace_text);
    var rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &rows);

    if (opts.thread_id) |thread_id| {
        var stage1_rows = try datasets.memory_stage1_outputs.collect(allocator, .{ .state_db_path = opts.state_db_path });
        defer datasets.memory_stage1_outputs.deinitRows(allocator, &stage1_rows);
        var memory_rows = try datasets.memory_blocks.collect(allocator, .{ .memory_root = opts.memory_root_text });
        defer datasets.memory_blocks.deinitRows(allocator, &memory_rows);

        const stage1_row = findMemoryStage1OutputRow(stage1_rows.items, thread_id) orelse {
            printCliError("error: no stage1 memory row for thread {s}\n", .{thread_id});
            return error.SessionNotFound;
        };
        const rollout_summary_row = findRolloutSummaryRow(memory_rows.items, thread_id, stage1_row.rollout_path, null);

        var event_count: i64 = 0;
        if (timestampSatisfiesBounds(stage1_row.generated_at, opts)) event_count += 1;
        if (stage1_row.source_updated_at != null and !optionalStringsEqual(stage1_row.source_updated_at, stage1_row.generated_at) and timestampSatisfiesBounds(stage1_row.source_updated_at, opts)) event_count += 1;
        if (timestampSatisfiesBounds(stage1_row.last_usage, opts)) event_count += 1;
        if (rollout_summary_row != null and timestampSatisfiesBounds(rollout_summary_row.?.updated_at, opts)) event_count += 1;

        var summary_row = query.Row.init(allocator);
        try summary_row.putOwnedKey("row_order", .{ .int = 0 });
        const summary_evidence = try std.fmt.allocPrint(allocator, "stage1_outputs:{s}", .{stage1_row.thread_id});
        defer allocator.free(summary_evidence);
        const summary_next_action = try std.fmt.allocPrint(allocator, "seq session-prompts --path {s} --roles user,assistant --strip-skill-blocks --limit 40 --format jsonl", .{stage1_row.rollout_path});
        defer allocator.free(summary_next_action);
        try summary_row.putOwnedKey("row_kind", .{ .string = "summary" });
        try summary_row.putOwnedKey("thread_id", .{ .string = stage1_row.thread_id });
        try summary_row.putOwnedKey("summary", .{ .string = "observed_evidence_timeline" });
        try summary_row.putOwnedKey("event_count", .{ .int = event_count });
        try summary_row.putOwnedKey("evidence_ref", .{ .string = summary_evidence });
        try summary_row.putOwnedKey("next_action_kind", .{ .string = "session-prompts" });
        try summary_row.putOwnedKey("next_action", .{ .string = summary_next_action });
        try rows.append(allocator, summary_row);

        if (timestampSatisfiesBounds(stage1_row.generated_at, opts)) {
            const preview = try std.fmt.allocPrint(allocator, "generated_at={s}", .{stage1_row.generated_at.?});
            defer allocator.free(preview);
            try appendMemoryHistoryEvent(allocator, &rows, "stage1_generated", stage1_row.generated_at.?, stage1_row.thread_id, stage1_row.rollout_path, try std.fmt.allocPrint(allocator, "stage1_outputs:{s}", .{stage1_row.thread_id}), preview);
        }
        if (stage1_row.source_updated_at) |source_updated_at| {
            if (!optionalStringsEqual(stage1_row.source_updated_at, stage1_row.generated_at) and timestampSatisfiesBounds(stage1_row.source_updated_at, opts)) {
                const preview = try std.fmt.allocPrint(allocator, "source_updated_at={s}", .{source_updated_at});
                defer allocator.free(preview);
                try appendMemoryHistoryEvent(allocator, &rows, "stage1_source_updated", source_updated_at, stage1_row.thread_id, stage1_row.rollout_path, try std.fmt.allocPrint(allocator, "stage1_outputs:{s}", .{stage1_row.thread_id}), preview);
            }
        }
        if (stage1_row.last_usage) |last_usage| {
            if (timestampSatisfiesBounds(stage1_row.last_usage, opts)) {
                const preview = try std.fmt.allocPrint(allocator, "last_usage={s}", .{last_usage});
                defer allocator.free(preview);
                try appendMemoryHistoryEvent(allocator, &rows, "stage1_last_usage", last_usage, stage1_row.thread_id, stage1_row.rollout_path, try std.fmt.allocPrint(allocator, "stage1_outputs:{s}", .{stage1_row.thread_id}), preview);
            }
        }
        if (rollout_summary_row) |summary_block| {
            if (timestampSatisfiesBounds(summary_block.updated_at, opts)) {
                try appendMemoryHistoryEvent(
                    allocator,
                    &rows,
                    "rollout_summary_updated",
                    summary_block.updated_at.?,
                    stage1_row.thread_id,
                    stage1_row.rollout_path,
                    try buildMemoryBlockEvidenceRef(allocator, summary_block.*),
                    if (shouldExpandMemoryTrace(trace, true)) summary_block.preview else "rollout_summary_updated",
                );
            }
        }
    } else {
        const use_regex = opts.regex != null;
        const query_text = opts.contains orelse opts.regex orelse unreachable;
        var memory_rows = try datasets.memory_blocks.collect(allocator, .{ .memory_root = opts.memory_root_text });
        defer datasets.memory_blocks.deinitRows(allocator, &memory_rows);

        var event_count: i64 = 0;
        for (memory_rows.items) |block_row| {
            if (!timestampSatisfiesBounds(block_row.updated_at, opts)) continue;
            const keywords = block_row.keywords orelse "";
            const score = try matchScoreForText(allocator, query_text, use_regex, &.{ block_row.title, block_row.heading_path, block_row.body, keywords, block_row.relative_path });
            if (score == null) continue;
            event_count += 1;
        }

        var summary_row = query.Row.init(allocator);
        try summary_row.putOwnedKey("row_order", .{ .int = 0 });
        const topic_next_action = try std.fmt.allocPrint(allocator, "seq artifact-search --contains {s} --kind memory --format table", .{query_text});
        defer allocator.free(topic_next_action);
        try summary_row.putOwnedKey("row_kind", .{ .string = "summary" });
        try summary_row.putOwnedKey("thread_id", .null);
        try summary_row.putOwnedKey("summary", .{ .string = "topic_artifact_timeline" });
        try summary_row.putOwnedKey("event_count", .{ .int = event_count });
        try summary_row.putOwnedKey("evidence_ref", .{ .string = "memory_blocks:topic-search" });
        try summary_row.putOwnedKey("next_action_kind", .{ .string = "artifact-search" });
        try summary_row.putOwnedKey("next_action", .{ .string = topic_next_action });
        try rows.append(allocator, summary_row);

        for (memory_rows.items) |block_row| {
            if (!timestampSatisfiesBounds(block_row.updated_at, opts)) continue;
            const keywords = block_row.keywords orelse "";
            const score = try matchScoreForText(allocator, query_text, use_regex, &.{ block_row.title, block_row.heading_path, block_row.body, keywords, block_row.relative_path });
            if (score == null) continue;
            try appendMemoryHistoryEvent(
                allocator,
                &rows,
                "artifact_match",
                block_row.updated_at.?,
                block_row.thread_id,
                block_row.rollout_path,
                try buildMemoryBlockEvidenceRef(allocator, block_row),
                block_row.preview,
            );
            try rows.items[rows.items.len - 1].putOwnedKey("score", .{ .int = score.? });
        }
    }

    const cols = [_][]const u8{ "row_kind", "timestamp", "change_kind", "thread_id", "summary", "preview", "evidence_ref", "next_action_kind", "next_action", "event_count", "score" };
    const limit = if (opts.limit == 0) 200 else opts.limit;
    var ordered: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &ordered);
    for (rows.items) |row| {
        if (scalarStringEq(row.valueOrNull("row_kind"), "summary")) {
            try ordered.append(allocator, try row.cloneSelected(allocator, cols[0..]));
        }
    }
    var event_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &event_rows);
    for (rows.items) |row| {
        if (!scalarStringEq(row.valueOrNull("row_kind"), "summary")) {
            try event_rows.append(allocator, try row.cloneSelected(allocator, cols[0..]));
        }
    }
    std.mem.sort(query.Row, event_rows.items, {}, historyRowLessThan);

    const remaining = if (limit > ordered.items.len) limit - ordered.items.len else 0;
    const emit_count = @min(remaining, event_rows.items.len);
    for (event_rows.items[0..emit_count]) |row| {
        try ordered.append(allocator, try row.cloneAll(allocator));
    }

    try output.writeOutput(allocator, opts.format, ordered.items, cols[0..], opts.out_path);
}

fn historyRowLessThan(_: void, lhs: query.Row, rhs: query.Row) bool {
    const lhs_ts = switch (lhs.valueOrNull("timestamp")) {
        .string => |text| text,
        else => "",
    };
    const rhs_ts = switch (rhs.valueOrNull("timestamp")) {
        .string => |text| text,
        else => "",
    };
    const order = compareNormalizedTimestamp(lhs_ts, rhs_ts);
    if (order != .eq) return order == .lt;
    const lhs_ref = switch (lhs.valueOrNull("evidence_ref")) {
        .string => |text| text,
        else => "",
    };
    const rhs_ref = switch (rhs.valueOrNull("evidence_ref")) {
        .string => |text| text,
        else => "",
    };
    return std.mem.order(u8, lhs_ref, rhs_ref) == .lt;
}

fn resolveThreadIdFromRolloutSummary(
    rows: []const datasets.memory_blocks.Row,
    input_path: []const u8,
) ![]const u8 {
    if (!std.mem.containsAtLeast(u8, input_path, 1, "/") and !std.fs.path.isAbsolute(input_path)) {
        printCliError("error: --rollout-summary-file requires a full relative or absolute path\n", .{});
        return error.SessionNotFound;
    }
    if (findUniqueRolloutSummaryMatch(rows, input_path, .exact)) |row| {
        if (row.thread_id != null) return row.thread_id.?;
    }
    printCliError("error: could not resolve rollout summary path {s}\n", .{input_path});
    return error.SessionNotFound;
}

const RolloutSummaryMatchMode = enum {
    exact,
    basename,
};

fn findUniqueRolloutSummaryMatch(
    rows: []const datasets.memory_blocks.Row,
    input_path: []const u8,
    mode: RolloutSummaryMatchMode,
) ?*const datasets.memory_blocks.Row {
    const input_base = std.fs.path.basename(input_path);
    var match: ?*const datasets.memory_blocks.Row = null;
    for (rows) |*row| {
        if (!std.mem.eql(u8, row.doc_kind, "rollout_summary")) continue;
        const matches = switch (mode) {
            .exact => std.mem.eql(u8, row.path, input_path) or std.mem.eql(u8, row.relative_path, input_path),
            .basename => std.mem.eql(u8, std.fs.path.basename(row.relative_path), input_base),
        };
        if (!matches) continue;
        if (match != null) {
            const same_file = std.mem.eql(u8, match.?.relative_path, row.relative_path);
            if (!same_file) {
                printCliError("error: rollout summary selector {s} is ambiguous; use the full relative or absolute path\n", .{input_path});
                return null;
            }
            if (row.heading_path.len < match.?.heading_path.len) {
                match = row;
            }
            continue;
        }
        match = row;
    }
    return match;
}

fn findMemoryStage1OutputRow(
    rows: []const datasets.memory_stage1_outputs.Row,
    thread_id: []const u8,
) ?*const datasets.memory_stage1_outputs.Row {
    for (rows) |*row| {
        if (std.mem.eql(u8, row.thread_id, thread_id)) return row;
    }
    return null;
}

fn findRolloutSummaryRow(
    rows: []const datasets.memory_blocks.Row,
    thread_id: []const u8,
    rollout_path: []const u8,
    rollout_summary_file_opt: ?[]const u8,
) ?*const datasets.memory_blocks.Row {
    for (rows) |*row| {
        if (!std.mem.eql(u8, row.doc_kind, "rollout_summary")) continue;
        if (row.thread_id != null and std.mem.eql(u8, row.thread_id.?, thread_id)) return row;
        if (row.rollout_path != null and std.mem.eql(u8, row.rollout_path.?, rollout_path)) return row;
    }
    if (rollout_summary_file_opt) |input_path| {
        if (findUniqueRolloutSummaryMatch(rows, input_path, .exact)) |row| return row;
    }
    return null;
}

fn memoryBlockMatchesThread(
    row: datasets.memory_blocks.Row,
    thread_id: []const u8,
    rollout_path: []const u8,
    rollout_summary_row: ?*const datasets.memory_blocks.Row,
) bool {
    if (row.thread_id != null and std.mem.eql(u8, row.thread_id.?, thread_id)) return true;
    if (row.rollout_path != null and std.mem.eql(u8, row.rollout_path.?, rollout_path)) return true;
    const summary_row = rollout_summary_row orelse return false;
    if (std.mem.eql(u8, row.relative_path, summary_row.relative_path)) return true;
    if (!std.mem.eql(u8, row.doc_kind, "memory_registry") and !std.mem.eql(u8, row.doc_kind, "memory_summary") and !std.mem.eql(u8, row.doc_kind, "memory_doc")) return false;
    const summary_base = std.fs.path.basename(summary_row.relative_path);
    return containsIgnoreCaseAscii(row.body, thread_id) and
        (containsIgnoreCaseAscii(row.body, summary_row.relative_path) or containsIgnoreCaseAscii(row.body, summary_base));
}

fn collectCurrentSurfacesSummary(
    allocator: std.mem.Allocator,
    rows: []const datasets.memory_blocks.Row,
    thread_id: []const u8,
    rollout_path: []const u8,
    rollout_summary_row: ?*const datasets.memory_blocks.Row,
) ![]u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(allocator);

    try labels.append(allocator, "stage1_outputs");
    for (rows) |row| {
        if (!memoryBlockMatchesThread(row, thread_id, rollout_path, rollout_summary_row)) continue;
        const label = if (std.mem.eql(u8, row.doc_kind, "memory_registry"))
            "memory_registry"
        else if (std.mem.eql(u8, row.doc_kind, "memory_summary"))
            "memory_summary"
        else if (std.mem.eql(u8, row.doc_kind, "memory_skill"))
            "memory_skill"
        else if (std.mem.eql(u8, row.doc_kind, "rollout_summary"))
            "rollout_summary"
        else
            "memory_doc";
        var already = false;
        for (labels.items) |existing| {
            if (std.mem.eql(u8, existing, label)) {
                already = true;
                break;
            }
        }
        if (!already) try labels.append(allocator, label);
    }

    return joinStringList(allocator, labels.items);
}

fn collectActiveExtensionsSummary(
    allocator: std.mem.Allocator,
    rows: []const datasets.memory_extensions.Row,
) ![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    for (rows) |row| {
        if (row.has_instructions) try names.append(allocator, row.extension_name);
    }
    return joinStringList(allocator, names.items);
}

fn joinStringList(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    if (items.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (items, 0..) |item, idx| {
        if (idx > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, item);
    }
    return out.toOwnedSlice(allocator);
}

fn buildMemoryBlockEvidenceRef(allocator: std.mem.Allocator, row: datasets.memory_blocks.Row) ![]u8 {
    if (row.heading_path.len > 0) {
        return std.fmt.allocPrint(allocator, "memory_blocks:{s}#{s}", .{ row.relative_path, row.heading_path });
    }
    return std.fmt.allocPrint(allocator, "memory_blocks:{s}", .{row.relative_path});
}

fn appendMemoryMapRow(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    surface: []const u8,
    path: []const u8,
    heading_path: ?[]const u8,
    title: []const u8,
    thread_id: ?[]const u8,
    rollout_path: ?[]const u8,
    match_kind: []const u8,
    preview: []const u8,
    evidence_ref: []const u8,
    next_action_kind: []const u8,
    next_action: []const u8,
) !void {
    defer allocator.free(evidence_ref);
    defer allocator.free(next_action);
    var row = query.Row.init(allocator);
    try row.putOwnedKey("surface", .{ .string = surface });
    try row.putOwnedKey("path", .{ .string = path });
    try putOptionalString(&row, "heading_path", heading_path);
    try row.putOwnedKey("title", .{ .string = title });
    try putOptionalString(&row, "thread_id", thread_id);
    try putOptionalString(&row, "rollout_path", rollout_path);
    try row.putOwnedKey("match_kind", .{ .string = match_kind });
    try row.putOwnedKey("preview", .{ .string = preview });
    try row.putOwnedKey("evidence_ref", .{ .string = evidence_ref });
    try row.putOwnedKey("next_action_kind", .{ .string = next_action_kind });
    if (next_action.len > 0) {
        try row.putOwnedKey("next_action", .{ .string = next_action });
    } else {
        try row.putOwnedKey("next_action", .null);
    }
    try out_rows.append(allocator, row);
}

fn appendMemoryHistoryEvent(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    change_kind: []const u8,
    timestamp: []const u8,
    thread_id: ?[]const u8,
    rollout_path: ?[]const u8,
    evidence_ref: []const u8,
    preview: []const u8,
) !void {
    defer allocator.free(evidence_ref);
    var row = query.Row.init(allocator);
    try row.putOwnedKey("row_order", .{ .int = 1 });
    try row.putOwnedKey("row_kind", .{ .string = "event" });
    try row.putOwnedKey("timestamp", .{ .string = timestamp });
    try row.putOwnedKey("change_kind", .{ .string = change_kind });
    try putOptionalString(&row, "thread_id", thread_id);
    try row.putOwnedKey("summary", .null);
    try row.putOwnedKey("preview", .{ .string = preview });
    try row.putOwnedKey("evidence_ref", .{ .string = evidence_ref });
    if (rollout_path) |path| {
        const next_action = try std.fmt.allocPrint(allocator, "seq session-prompts --path {s} --roles user,assistant --strip-skill-blocks --limit 40 --format jsonl", .{path});
        defer allocator.free(next_action);
        try row.putOwnedKey("next_action_kind", .{ .string = "session-prompts" });
        try row.putOwnedKey("next_action", .{ .string = next_action });
    } else {
        try row.putOwnedKey("next_action_kind", .{ .string = "none" });
        try row.putOwnedKey("next_action", .null);
    }
    try row.putOwnedKey("event_count", .null);
    try row.putOwnedKey("score", .null);
    try out_rows.append(allocator, row);
}

fn shouldExpandMemoryTrace(trace: MemoryTrace, specific_target: bool) bool {
    return switch (trace) {
        .none => false,
        .always => true,
        .auto => specific_target,
    };
}

fn optionalStringsEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (eqlIgnoreCaseAscii(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn startsWithIgnoreCaseAscii(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return eqlIgnoreCaseAscii(haystack[0..prefix.len], prefix);
}

fn endsWithIgnoreCaseAscii(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) return false;
    return eqlIgnoreCaseAscii(haystack[haystack.len - suffix.len ..], suffix);
}

fn eqlIgnoreCaseAscii(lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.eqlIgnoreCase(lhs, rhs);
}

fn cmdOpencodePrompts(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var query_spec = spec.QuerySpec{};
    var fmt: output.Format = if (opts.format_set) opts.format else output.Format.jsonl;

    if (opts.spec_text) |raw_spec| {
        const spec_text = try loadSpecText(allocator, raw_spec);
        defer allocator.free(spec_text);

        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), spec_text, .{});
        defer parsed.deinit();

        query_spec = try spec.parseQuerySpecValue(arena.allocator(), parsed.value);
        const root_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidSpec,
        };
        if (root_obj.get("dataset")) |dataset_value| switch (dataset_value) {
            .string => |dataset_name| {
                if (!std.mem.eql(u8, dataset_name, "opencode_prompts")) return error.InvalidDatasetArg;
            },
            else => return error.InvalidSpec,
        };
        if (!opts.format_set) {
            if (root_obj.get("format")) |fmt_value| switch (fmt_value) {
                .string => |text| fmt = try output.Format.parse(text),
                else => return error.InvalidSpec,
            } else {
                fmt = if (query_spec.group_by.len > 0) output.Format.table else output.Format.jsonl;
            }
        }
    } else if (!opts.format_set) {
        fmt = output.Format.jsonl;
    }

    query_spec = try applyOpencodePromptConvenienceFilters(arena.allocator(), query_spec, opts);
    query_spec.params = try mergeOpencodeParams(arena.allocator(), query_spec.params, opts);

    var rows = try collectDatasetRowsForSpec(allocator, "opencode_prompts", sessions_root, query_spec);
    defer deinitQueryRows(allocator, &rows);

    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    const cols_opt: ?[]const []const u8 = if (query_spec.select.len > 0) query_spec.select else null;
    try output.writeOutput(allocator, fmt, result.rows.items, cols_opt, opts.out_path);
}

fn cmdOpencodeEvents(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var query_spec = spec.QuerySpec{};
    var fmt: output.Format = if (opts.format_set) opts.format else output.Format.jsonl;

    if (opts.spec_text) |raw_spec| {
        const spec_text = try loadSpecText(allocator, raw_spec);
        defer allocator.free(spec_text);

        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), spec_text, .{});
        defer parsed.deinit();

        query_spec = try spec.parseQuerySpecValue(arena.allocator(), parsed.value);
        const root_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidSpec,
        };
        if (root_obj.get("dataset")) |dataset_value| switch (dataset_value) {
            .string => |dataset_name| {
                if (!std.mem.eql(u8, dataset_name, "opencode_events")) return error.InvalidDatasetArg;
            },
            else => return error.InvalidSpec,
        };
        if (!opts.format_set) {
            if (root_obj.get("format")) |fmt_value| switch (fmt_value) {
                .string => |text| fmt = try output.Format.parse(text),
                else => return error.InvalidSpec,
            } else {
                fmt = if (query_spec.group_by.len > 0) output.Format.table else output.Format.jsonl;
            }
        }
    } else if (!opts.format_set) {
        fmt = output.Format.jsonl;
    }

    query_spec = try applyOpencodeEventConvenienceFilters(arena.allocator(), query_spec, opts);
    query_spec.params = try mergeOpencodeParams(arena.allocator(), query_spec.params, opts);

    var rows = try collectDatasetRowsForSpec(allocator, "opencode_events", sessions_root, query_spec);
    defer deinitQueryRows(allocator, &rows);

    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    const cols_opt: ?[]const []const u8 = if (query_spec.select.len > 0) query_spec.select else null;
    try output.writeOutput(allocator, fmt, result.rows.items, cols_opt, opts.out_path);
}

fn cmdSkillsRank(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    try appendSessionTimeBounds(allocator, &where, opts);
    const query_spec = spec.QuerySpec{
        .where = where.items,
        .group_by = &.{"skill"},
        .metrics = &.{.{ .op = .count, .alias = "count" }},
        .sort = &.{.{ .field = "count", .descending = true }},
        .limit = opts.limit,
    };
    try runDatasetQuery(allocator, "skill_mentions", sessions_root, query_spec, opts.format, opts.out_path, null);
}

const SkillSuccessWindow = struct {
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
};

const SkillOutcome = struct {
    positive_bits: u8 = 0,
    blocked: bool = false,
};

const OUTCOME_TEST: u8 = 1 << 0;
const OUTCOME_PROOF: u8 = 1 << 1;
const OUTCOME_COMMIT: u8 = 1 << 2;
const OUTCOME_PR: u8 = 1 << 3;
const OUTCOME_CLOSURE: u8 = 1 << 4;

const SkillSuccessAggregate = struct {
    skill: []const u8,
    raw_mentions: i64 = 0,
    raw_sessions: StringSet,
    called_sessions: StringSet,
    assistant_sessions: StringSet,
    successful_sessions: i64 = 0,
    used_sessions: i64 = 0,
    blocked_sessions: i64 = 0,
    first_seen: ?[]u8 = null,
    last_seen: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, skill: []const u8) SkillSuccessAggregate {
        return .{
            .skill = skill,
            .raw_sessions = StringSet.init(allocator),
            .called_sessions = StringSet.init(allocator),
            .assistant_sessions = StringSet.init(allocator),
        };
    }

    fn deinit(self: *SkillSuccessAggregate, allocator: std.mem.Allocator) void {
        self.raw_sessions.deinit();
        self.called_sessions.deinit();
        self.assistant_sessions.deinit();
        if (self.first_seen) |value| allocator.free(value);
        if (self.last_seen) |value| allocator.free(value);
    }
};

fn cmdSkillSuccessRank(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const mode = opts.mode orelse "summary";
    if (!std.mem.eql(u8, mode, "summary") and !std.mem.eql(u8, mode, "sessions")) {
        return error.InvalidModeArg;
    }

    const window = try resolveSkillSuccessWindow(opts);
    var outcomes = std.StringHashMap(SkillOutcome).init(allocator);
    defer {
        var out_it = outcomes.iterator();
        while (out_it.next()) |entry| allocator.free(entry.key_ptr.*);
        outcomes.deinit();
    }

    var aggregates = std.StringHashMap(SkillSuccessAggregate).init(allocator);
    defer deinitSkillSuccessAggregates(allocator, &aggregates);

    const path_filter = skillSuccessDayFilter(window);
    var paths = try collectJsonlPaths(allocator, sessions_root, path_filter);
    defer freePathList(allocator, &paths);

    for (paths.items) |path| {
        const content = try readFileAllocOrSkip(allocator, path);
        if (content == null) continue;
        defer allocator.free(content.?);

        try collectSkillSuccessOutcomesForPath(allocator, &outcomes, path, content.?, window);
        try collectSkillSuccessMentionsForPath(allocator, &aggregates, path, content.?, window, opts.skill);
    }

    try computeSkillSuccessCounts(&aggregates, &outcomes);

    if (std.mem.eql(u8, mode, "sessions")) {
        return writeSkillSuccessSessionRows(allocator, &aggregates, &outcomes, opts);
    }
    return writeSkillSuccessSummaryRows(allocator, &aggregates, opts);
}

fn resolveSkillSuccessWindow(opts: Options) !SkillSuccessWindow {
    const until_ms = try parseSkillSuccessBoundMillis(opts.until, "--until");
    if (opts.last_text) |raw| {
        const duration_ms = try parseLastWindowMillis(raw);
        const anchor_ms = until_ms orelse currentUnixMillis();
        return .{
            .since_ms = anchor_ms - duration_ms,
            .until_ms = anchor_ms,
        };
    }
    return .{
        .since_ms = try parseSkillSuccessBoundMillis(opts.since, "--since"),
        .until_ms = until_ms,
    };
}

fn parseSkillSuccessBoundMillis(raw_opt: ?[]const u8, flag_name: []const u8) !?i64 {
    const raw = raw_opt orelse return null;
    return time_utils.parseIsoTimestampMillis(raw) orelse blk: {
        printCliError("error: skill-success-rank {s} must be an ISO-8601 timestamp with timezone\n", .{flag_name});
        break :blk error.InvalidTimestampArg;
    };
}

fn skillSuccessDayFilter(window: SkillSuccessWindow) ?SessionDayPathFilter {
    return deriveSessionDayPathFilterFromWindow(.{
        .since_ms = window.since_ms,
        .until_ms = window.until_ms,
    });
}

fn skillSuccessTimestampInWindow(timestamp: ?[]const u8, window: SkillSuccessWindow) bool {
    if (window.since_ms == null and window.until_ms == null) return true;
    const text = timestamp orelse return false;
    const ts_ms = time_utils.parseIsoTimestampMillis(text) orelse return false;
    if (window.since_ms) |since_ms| {
        if (ts_ms < since_ms) return false;
    }
    if (window.until_ms) |until_ms| {
        if (ts_ms > until_ms) return false;
    }
    return true;
}

fn collectSkillSuccessOutcomesForPath(
    allocator: std.mem.Allocator,
    outcomes: *std.StringHashMap(SkillOutcome),
    path: []const u8,
    content: []const u8,
    window: SkillSuccessWindow,
) !void {
    const messages = try datasets.messages.parseJsonl(allocator, path, content, .{
        .strip_skill_blocks = true,
        .dedupe_by_role_and_text = true,
    });
    defer datasets.messages.freeRows(allocator, messages);

    var outcome = outcomes.get(path) orelse SkillOutcome{};
    for (messages) |message| {
        if (!skillSuccessTimestampInWindow(message.timestamp, window)) continue;
        const detected = skillSuccessOutcomeForText(message.text);
        outcome.positive_bits |= detected.positive_bits;
        outcome.blocked = outcome.blocked or detected.blocked;
    }
    if (outcome.positive_bits != 0 or outcome.blocked) {
        const gop = try outcomes.getOrPut(path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, path);
        }
        gop.value_ptr.* = outcome;
    }
}

fn skillSuccessOutcomeForText(text: []const u8) SkillOutcome {
    var out = SkillOutcome{};
    if (containsAnyIgnoreCaseAscii(text, &.{ "zig build test", "tests pass", "test passed" })) out.positive_bits |= OUTCOME_TEST;
    if (containsAnyIgnoreCaseAscii(text, &.{ "proof", "validated", "validation" })) out.positive_bits |= OUTCOME_PROOF;
    if (containsAnyIgnoreCaseAscii(text, &.{ "commit ", "committed", "pushed" })) out.positive_bits |= OUTCOME_COMMIT;
    if (containsAnyIgnoreCaseAscii(text, &.{ "PR #", "pull request", "gh pr" })) out.positive_bits |= OUTCOME_PR;
    if (containsAnyIgnoreCaseAscii(text, &.{ "closure", "fixed point", "fixed-point" })) out.positive_bits |= OUTCOME_CLOSURE;
    out.blocked = containsAnyIgnoreCaseAscii(text, &.{ "blocked", "failed", "error:" });
    return out;
}

fn containsAnyIgnoreCaseAscii(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCaseAscii(text, needle)) return true;
    }
    return false;
}

fn collectSkillSuccessMentionsForPath(
    allocator: std.mem.Allocator,
    aggregates: *std.StringHashMap(SkillSuccessAggregate),
    path: []const u8,
    content: []const u8,
    window: SkillSuccessWindow,
    skill_filter: ?[]const u8,
) !void {
    const mentions = try datasets.skill_mentions.parseJsonl(allocator, path, content, .{});
    defer datasets.skill_mentions.freeRows(allocator, mentions);

    for (mentions) |mention| {
        if (!skillSuccessTimestampInWindow(mention.timestamp, window)) continue;
        if (skill_filter) |filter| {
            if (!std.mem.eql(u8, mention.skill, filter)) continue;
        }

        const aggregate = try getOrPutSkillSuccessAggregate(allocator, aggregates, mention.skill);
        aggregate.raw_mentions += 1;
        try aggregate.raw_sessions.put(mention.path);
        if (std.mem.eql(u8, mention.role, "user")) {
            try aggregate.called_sessions.put(mention.path);
        } else if (std.mem.eql(u8, mention.role, "assistant")) {
            try aggregate.assistant_sessions.put(mention.path);
        }
        try observeSkillSuccessTimestamp(allocator, aggregate, mention.timestamp);
    }
}

fn getOrPutSkillSuccessAggregate(
    allocator: std.mem.Allocator,
    aggregates: *std.StringHashMap(SkillSuccessAggregate),
    skill: []const u8,
) !*SkillSuccessAggregate {
    if (aggregates.getPtr(skill)) |existing| return existing;
    const key = try allocator.dupe(u8, skill);
    errdefer allocator.free(key);
    try aggregates.put(key, SkillSuccessAggregate.init(allocator, key));
    return aggregates.getPtr(key).?;
}

fn observeSkillSuccessTimestamp(
    allocator: std.mem.Allocator,
    aggregate: *SkillSuccessAggregate,
    timestamp: ?[]const u8,
) !void {
    if (timestamp == null) return;
    if (aggregate.first_seen == null or compareOptionalTimestamp(timestamp, aggregate.first_seen) == .lt) {
        try replaceOptionalString(allocator, &aggregate.first_seen, timestamp);
    }
    if (aggregate.last_seen == null or compareOptionalTimestamp(timestamp, aggregate.last_seen) == .gt) {
        try replaceOptionalString(allocator, &aggregate.last_seen, timestamp);
    }
}

fn computeSkillSuccessCounts(
    aggregates: *std.StringHashMap(SkillSuccessAggregate),
    outcomes: *const std.StringHashMap(SkillOutcome),
) !void {
    var it = aggregates.iterator();
    while (it.next()) |entry| {
        var successful: i64 = 0;
        var used: i64 = 0;
        var blocked: i64 = 0;
        var path_it = entry.value_ptr.called_sessions.map.keyIterator();
        while (path_it.next()) |path_ptr| {
            const path = path_ptr.*;
            const outcome = outcomes.get(path) orelse SkillOutcome{};
            const has_positive = outcome.positive_bits != 0;
            if (has_positive) successful += 1;
            if (entry.value_ptr.assistant_sessions.contains(path) or has_positive) used += 1;
            if (outcome.blocked) blocked += 1;
        }
        entry.value_ptr.successful_sessions = successful;
        entry.value_ptr.used_sessions = used;
        entry.value_ptr.blocked_sessions = blocked;
    }
}

fn deinitSkillSuccessAggregates(
    allocator: std.mem.Allocator,
    aggregates: *std.StringHashMap(SkillSuccessAggregate),
) void {
    var it = aggregates.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
        allocator.free(entry.key_ptr.*);
    }
    aggregates.deinit();
}

fn writeSkillSuccessSummaryRows(
    allocator: std.mem.Allocator,
    aggregates: *std.StringHashMap(SkillSuccessAggregate),
    opts: Options,
) !void {
    var values: std.ArrayList(*SkillSuccessAggregate) = .empty;
    defer values.deinit(allocator);
    var it = aggregates.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.successful_sessions == 0 and entry.value_ptr.used_sessions == 0) continue;
        try values.append(allocator, entry.value_ptr);
    }
    std.mem.sort(*SkillSuccessAggregate, values.items, {}, skillSuccessSummaryLessThan);

    const limit = if (opts.limit > 0) @min(opts.limit, values.items.len) else values.items.len;
    var rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &rows);
    for (values.items[0..limit], 0..) |aggregate, idx| {
        var row = query.Row.init(allocator);
        errdefer row.deinit();
        try row.putOwnedKey("rank", .{ .int = @intCast(idx + 1) });
        try row.putOwnedKey("skill", .{ .string = aggregate.skill });
        try row.putOwnedKey("successful_sessions", .{ .int = aggregate.successful_sessions });
        try row.putOwnedKey("used_sessions", .{ .int = aggregate.used_sessions });
        try row.putOwnedKey("called_sessions", .{ .int = @intCast(aggregate.called_sessions.count()) });
        try row.putOwnedKey("assistant_used_sessions", .{ .int = @intCast(aggregate.assistant_sessions.count()) });
        try row.putOwnedKey("blocked_sessions", .{ .int = aggregate.blocked_sessions });
        try row.putOwnedKey("raw_sessions", .{ .int = @intCast(aggregate.raw_sessions.count()) });
        try row.putOwnedKey("raw_mentions", .{ .int = aggregate.raw_mentions });
        try putOptionalString(&row, "first_seen", aggregate.first_seen);
        try putOptionalString(&row, "last_seen", aggregate.last_seen);
        try rows.append(allocator, row);
    }

    const columns = [_][]const u8{
        "rank",
        "skill",
        "successful_sessions",
        "used_sessions",
        "called_sessions",
        "assistant_used_sessions",
        "blocked_sessions",
        "raw_sessions",
        "raw_mentions",
        "first_seen",
        "last_seen",
    };
    try output.writeOutput(allocator, opts.format, rows.items, columns[0..], opts.out_path);
}

fn skillSuccessSummaryLessThan(_: void, lhs: *SkillSuccessAggregate, rhs: *SkillSuccessAggregate) bool {
    if (lhs.successful_sessions != rhs.successful_sessions) return lhs.successful_sessions > rhs.successful_sessions;
    if (lhs.used_sessions != rhs.used_sessions) return lhs.used_sessions > rhs.used_sessions;
    const lhs_called: i64 = @intCast(lhs.called_sessions.count());
    const rhs_called: i64 = @intCast(rhs.called_sessions.count());
    if (lhs_called != rhs_called) return lhs_called > rhs_called;
    return std.mem.order(u8, lhs.skill, rhs.skill) == .lt;
}

fn writeSkillSuccessSessionRows(
    allocator: std.mem.Allocator,
    aggregates: *std.StringHashMap(SkillSuccessAggregate),
    outcomes: *const std.StringHashMap(SkillOutcome),
    opts: Options,
) !void {
    var rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &rows);

    var it = aggregates.iterator();
    while (it.next()) |entry| {
        var path_it = entry.value_ptr.called_sessions.map.keyIterator();
        while (path_it.next()) |path_ptr| {
            const path = path_ptr.*;
            const outcome = outcomes.get(path) orelse SkillOutcome{};
            const successful = outcome.positive_bits != 0;
            const used = entry.value_ptr.assistant_sessions.contains(path) or successful;

            var row = query.Row.init(allocator);
            errdefer row.deinit();
            try row.putOwnedKey("skill", .{ .string = entry.value_ptr.skill });
            try row.putOwnedKey("successful", .{ .bool = successful });
            try row.putOwnedKey("used", .{ .bool = used });
            try row.putOwnedKey("blocked", .{ .bool = outcome.blocked });
            try row.putOwnedKey("assistant_mentioned", .{ .bool = entry.value_ptr.assistant_sessions.contains(path) });
            const outcome_text = try skillSuccessOutcomeTextAlloc(allocator, outcome);
            defer allocator.free(outcome_text);
            try row.putOwnedKey("outcomes", .{ .string = outcome_text });
            try row.putOwnedKey("path", .{ .string = path });
            try rows.append(allocator, row);
        }
    }

    const query_spec = spec.QuerySpec{
        .sort = &.{
            .{ .field = "successful", .descending = true },
            .{ .field = "skill", .descending = false },
            .{ .field = "path", .descending = false },
        },
        .limit = opts.limit,
    };
    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    const columns = [_][]const u8{ "skill", "successful", "used", "blocked", "assistant_mentioned", "outcomes", "path" };
    try output.writeOutput(allocator, opts.format, result.rows.items, columns[0..], opts.out_path);
}

fn skillSuccessOutcomeTextAlloc(allocator: std.mem.Allocator, outcome: SkillOutcome) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    if ((outcome.positive_bits & OUTCOME_TEST) != 0) try parts.append(allocator, "test");
    if ((outcome.positive_bits & OUTCOME_PROOF) != 0) try parts.append(allocator, "proof");
    if ((outcome.positive_bits & OUTCOME_COMMIT) != 0) try parts.append(allocator, "commit");
    if ((outcome.positive_bits & OUTCOME_PR) != 0) try parts.append(allocator, "pr");
    if ((outcome.positive_bits & OUTCOME_CLOSURE) != 0) try parts.append(allocator, "closure");
    if (outcome.blocked) try parts.append(allocator, "blocked");
    if (parts.items.len == 0) return allocator.dupe(u8, "");

    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    for (parts.items, 0..) |part, idx| {
        if (idx > 0) try writer.writeByte('+');
        try writer.writeAll(part);
    }
    return writer_alloc.toOwnedSlice();
}

fn cmdSkillTrend(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const skill_name = opts.skill orelse return error.MissingSkillArg;
    const bucket = opts.bucket orelse "day";
    const group_by = [_][]const u8{bucket};
    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    try where.append(allocator, .{ .field = "skill", .op = .eq, .value = .{ .scalar = .{ .string = skill_name } } });
    try appendSessionTimeBounds(allocator, &where, opts);
    const query_spec = spec.QuerySpec{
        .where = where.items,
        .group_by = group_by[0..],
        .metrics = &.{.{ .op = .count, .alias = "count" }},
        .sort = &.{.{ .field = bucket, .descending = false }},
    };

    var rows = try collectDatasetRows(allocator, "skill_mentions", sessions_root, &.{}, where.items);
    defer deinitQueryRows(allocator, &rows);

    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    const start_idx: usize = if (opts.limit > 0 and result.rows.items.len > opts.limit)
        result.rows.items.len - opts.limit
    else
        0;

    var out_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &out_rows);

    for (result.rows.items[start_idx..]) |row| {
        var out = query.Row.init(allocator);
        try out.putOwnedKey("bucket", row.valueOrNull(bucket));
        try out.putOwnedKey("count", row.valueOrNull("count"));
        try out_rows.append(allocator, out);
    }

    const cols = [_][]const u8{ "bucket", "count" };
    try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
}

fn cmdSkillReport(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const skill_name = opts.skill orelse return error.MissingSkillArg;
    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    try where.append(allocator, .{
        .field = "skill",
        .op = .eq,
        .value = .{ .scalar = .{ .string = skill_name } },
    });
    try appendSessionTimeBounds(allocator, &where, opts);
    const select = [_][]const u8{ "path", "timestamp", "role", "skill", "types", "snippet" };
    const query_spec = spec.QuerySpec{
        .where = where.items,
        .select = select[0..],
        .sort = &.{.{ .field = "timestamp", .descending = false }},
        .limit = opts.limit,
    };
    try runDatasetQuery(allocator, "skill_mentions", sessions_root, query_spec, opts.format, opts.out_path, select[0..]);
}
const SkillBlockHistory = enum {
    distinct,
    all,
    latest,

    fn parse(raw_opt: ?[]const u8) !SkillBlockHistory {
        const raw = raw_opt orelse return .distinct;
        if (std.mem.eql(u8, raw, "distinct")) return .distinct;
        if (std.mem.eql(u8, raw, "all")) return .all;
        if (std.mem.eql(u8, raw, "latest")) return .latest;
        printCliError("error: invalid --history value {s}; expected distinct, all, or latest\n", .{raw});
        return error.InvalidModeArg;
    }
};

const ROLE_USER: u8 = 1;
const ROLE_ASSISTANT: u8 = 2;

const SkillBlockAggregate = struct {
    skill: []u8,
    skill_path: ?[]u8,
    block_hash: []u8,
    block_text: []u8,
    first_seen_timestamp: ?[]u8,
    first_seen_path: []u8,
    last_seen_timestamp: ?[]u8,
    last_seen_path: []u8,
    occurrence_count: usize,
    roles_mask: u8,

    fn deinit(self: SkillBlockAggregate, allocator: std.mem.Allocator) void {
        allocator.free(self.skill);
        if (self.skill_path) |v| allocator.free(v);
        allocator.free(self.block_hash);
        allocator.free(self.block_text);
        if (self.first_seen_timestamp) |v| allocator.free(v);
        allocator.free(self.first_seen_path);
        if (self.last_seen_timestamp) |v| allocator.free(v);
        allocator.free(self.last_seen_path);
    }
};

fn compareOptionalTimestamp(lhs: ?[]const u8, rhs: ?[]const u8) std.math.Order {
    if (lhs == null and rhs == null) return .eq;
    if (lhs == null) return .gt;
    if (rhs == null) return .lt;
    var lhs_buf: [64]u8 = undefined;
    var rhs_buf: [64]u8 = undefined;
    const lhs_norm = if (lhs.?.len > 0 and lhs.?[lhs.?.len - 1] == 'Z' and lhs.?.len + 5 <= lhs_buf.len) blk: {
        @memcpy(lhs_buf[0 .. lhs.?.len - 1], lhs.?[0 .. lhs.?.len - 1]);
        @memcpy(lhs_buf[lhs.?.len - 1 .. lhs.?.len + 5], "+00:00");
        break :blk lhs_buf[0 .. lhs.?.len + 5];
    } else lhs.?;
    const rhs_norm = if (rhs.?.len > 0 and rhs.?[rhs.?.len - 1] == 'Z' and rhs.?.len + 5 <= rhs_buf.len) blk: {
        @memcpy(rhs_buf[0 .. rhs.?.len - 1], rhs.?[0 .. rhs.?.len - 1]);
        @memcpy(rhs_buf[rhs.?.len - 1 .. rhs.?.len + 5], "+00:00");
        break :blk rhs_buf[0 .. rhs.?.len + 5];
    } else rhs.?;
    return std.mem.order(u8, lhs_norm, rhs_norm);
}

fn roleMaskFromText(role: []const u8) u8 {
    if (std.mem.eql(u8, role, "user")) return ROLE_USER;
    if (std.mem.eql(u8, role, "assistant")) return ROLE_ASSISTANT;
    return 0;
}

fn rolesString(allocator: std.mem.Allocator, mask: u8) ![]u8 {
    return switch (mask) {
        ROLE_ASSISTANT => allocator.dupe(u8, "assistant"),
        ROLE_USER => allocator.dupe(u8, "user"),
        ROLE_USER | ROLE_ASSISTANT => allocator.dupe(u8, "assistant,user"),
        else => allocator.dupe(u8, ""),
    };
}

fn skillBlockAllLessThan(_: void, lhs: datasets.skill_blocks.SkillBlockRow, rhs: datasets.skill_blocks.SkillBlockRow) bool {
    const order = compareOptionalTimestamp(lhs.timestamp, rhs.timestamp);
    return switch (order) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, lhs.path, rhs.path) == .lt,
    };
}

fn skillBlockDistinctLessThan(_: void, lhs: SkillBlockAggregate, rhs: SkillBlockAggregate) bool {
    const order = compareOptionalTimestamp(lhs.first_seen_timestamp, rhs.first_seen_timestamp);
    return switch (order) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, lhs.block_hash, rhs.block_hash) == .lt,
    };
}

fn cloneOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    if (value) |v| return try allocator.dupe(u8, v);
    return null;
}

fn replaceOptionalString(allocator: std.mem.Allocator, slot: *?[]u8, value: ?[]const u8) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = try cloneOptionalString(allocator, value);
}

fn replaceString(allocator: std.mem.Allocator, slot: *[]u8, value: []const u8) !void {
    allocator.free(slot.*);
    slot.* = try allocator.dupe(u8, value);
}

fn buildSkillBlockAggregate(
    allocator: std.mem.Allocator,
    row: datasets.skill_blocks.SkillBlockRow,
) !SkillBlockAggregate {
    return .{
        .skill = try allocator.dupe(u8, row.skill),
        .skill_path = try cloneOptionalString(allocator, row.skill_path),
        .block_hash = try allocator.dupe(u8, row.block_hash),
        .block_text = try allocator.dupe(u8, row.block_text),
        .first_seen_timestamp = try cloneOptionalString(allocator, row.timestamp),
        .first_seen_path = try allocator.dupe(u8, row.path),
        .last_seen_timestamp = try cloneOptionalString(allocator, row.timestamp),
        .last_seen_path = try allocator.dupe(u8, row.path),
        .occurrence_count = 1,
        .roles_mask = roleMaskFromText(row.role),
    };
}

fn aggregateSkillBlockRows(
    allocator: std.mem.Allocator,
    raw_rows: []const datasets.skill_blocks.SkillBlockRow,
) !std.ArrayList(SkillBlockAggregate) {
    var aggregates: std.ArrayList(SkillBlockAggregate) = .empty;
    errdefer {
        for (aggregates.items) |row| row.deinit(allocator);
        aggregates.deinit(allocator);
    }

    var index_by_hash = std.StringHashMap(usize).init(allocator);
    defer index_by_hash.deinit();

    for (raw_rows) |row| {
        if (index_by_hash.get(row.block_hash)) |idx| {
            var agg = &aggregates.items[idx];
            agg.occurrence_count += 1;
            agg.roles_mask |= roleMaskFromText(row.role);

            if (compareOptionalTimestamp(row.timestamp, agg.first_seen_timestamp) == .lt) {
                try replaceOptionalString(allocator, &agg.first_seen_timestamp, row.timestamp);
                try replaceString(allocator, &agg.first_seen_path, row.path);
            }
            if (compareOptionalTimestamp(row.timestamp, agg.last_seen_timestamp) != .lt) {
                try replaceOptionalString(allocator, &agg.last_seen_timestamp, row.timestamp);
                try replaceString(allocator, &agg.last_seen_path, row.path);
            }
            continue;
        }

        const agg = try buildSkillBlockAggregate(allocator, row);
        try aggregates.append(allocator, agg);
        try index_by_hash.put(row.block_hash, aggregates.items.len - 1);
    }

    return aggregates;
}

fn collectSkillBlockRows(
    allocator: std.mem.Allocator,
    input_paths: []const []u8,
    opts: Options,
) !std.ArrayList(datasets.skill_blocks.SkillBlockRow) {
    const skill_name = opts.skill orelse return error.MissingSkillArg;
    var rows: std.ArrayList(datasets.skill_blocks.SkillBlockRow) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    for (input_paths) |path| {
        const content = try readFileAllocOrSkip(allocator, path);
        if (content == null) continue;
        defer allocator.free(content.?);

        const parsed = try datasets.skill_blocks.parseJsonl(allocator, path, content.?, .{});
        for (parsed) |row| {
            if (!std.mem.eql(u8, row.skill, skill_name) or !timestampSatisfiesBounds(row.timestamp, opts)) {
                row.deinit(allocator);
                continue;
            }
            try rows.append(allocator, row);
        }
        allocator.free(parsed);
    }

    return rows;
}

fn rawSkillBlockRowsToQueryRows(
    allocator: std.mem.Allocator,
    raw_rows: []const datasets.skill_blocks.SkillBlockRow,
) !std.ArrayList(query.Row) {
    var out: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &out);

    for (raw_rows) |row| {
        var qrow = query.Row.init(allocator);
        try qrow.putOwnedKey("path", .{ .string = row.path });
        try putOptionalString(&qrow, "timestamp", row.timestamp);
        try putOptionalString(&qrow, "day", row.day);
        try putOptionalString(&qrow, "week", row.week);
        try putOptionalString(&qrow, "month", row.month);
        try qrow.putOwnedKey("role", .{ .string = row.role });
        try qrow.putOwnedKey("skill", .{ .string = row.skill });
        try putOptionalString(&qrow, "skill_path", row.skill_path);
        try qrow.putOwnedKey("block_hash", .{ .string = row.block_hash });
        try qrow.putOwnedKey("block_text", .{ .string = row.block_text });
        try out.append(allocator, qrow);
    }

    return out;
}

fn aggregatedSkillBlockRowsToQueryRows(
    allocator: std.mem.Allocator,
    aggregates: []const SkillBlockAggregate,
) !std.ArrayList(query.Row) {
    var out: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &out);

    for (aggregates) |row| {
        var qrow = query.Row.init(allocator);
        errdefer qrow.deinit();
        const roles = try rolesString(allocator, row.roles_mask);
        defer allocator.free(roles);

        try qrow.putOwnedKey("skill", .{ .string = row.skill });
        try putOptionalString(&qrow, "skill_path", row.skill_path);
        try qrow.putOwnedKey("block_hash", .{ .string = row.block_hash });
        try qrow.putOwnedKey("block_text", .{ .string = row.block_text });
        try putOptionalString(&qrow, "first_seen_timestamp", row.first_seen_timestamp);
        try qrow.putOwnedKey("first_seen_path", .{ .string = row.first_seen_path });
        try putOptionalString(&qrow, "last_seen_timestamp", row.last_seen_timestamp);
        try qrow.putOwnedKey("last_seen_path", .{ .string = row.last_seen_path });
        try qrow.putOwnedKey("occurrence_count", .{ .int = @intCast(row.occurrence_count) });
        try qrow.putOwnedKey("roles", .{ .string = roles });
        try out.append(allocator, qrow);
    }

    return out;
}

fn cmdSkillBlocks(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const history = try SkillBlockHistory.parse(opts.history_text);
    const day_filter = deriveSessionDayPathFilterFromOptions(opts);
    var input_paths = try resolveSessionPromptInputPaths(allocator, sessions_root, opts, day_filter);
    defer freePathList(allocator, &input_paths);

    var raw_rows = try collectSkillBlockRows(allocator, input_paths.items, opts);
    defer {
        for (raw_rows.items) |row| row.deinit(allocator);
        raw_rows.deinit(allocator);
    }

    if (history == .all) {
        std.mem.sort(datasets.skill_blocks.SkillBlockRow, raw_rows.items, {}, skillBlockAllLessThan);
        const start_idx: usize = if (opts.limit > 0 and raw_rows.items.len > opts.limit) 0 else 0;
        const end_idx: usize = if (opts.limit > 0 and raw_rows.items.len > opts.limit) opts.limit else raw_rows.items.len;
        var out_rows = try rawSkillBlockRowsToQueryRows(allocator, raw_rows.items[start_idx..end_idx]);
        defer deinitQueryRows(allocator, &out_rows);
        const cols = [_][]const u8{ "path", "timestamp", "day", "week", "month", "role", "skill", "skill_path", "block_hash", "block_text" };
        try output.writeOutput(allocator, if (opts.format_set) opts.format else .jsonl, out_rows.items, cols[0..], opts.out_path);
        return;
    }

    var aggregates = try aggregateSkillBlockRows(allocator, raw_rows.items);
    defer {
        for (aggregates.items) |row| row.deinit(allocator);
        aggregates.deinit(allocator);
    }
    std.mem.sort(SkillBlockAggregate, aggregates.items, {}, skillBlockDistinctLessThan);

    var aggregate_slice = aggregates.items;
    if (history == .latest and aggregates.items.len > 0) {
        aggregate_slice = aggregates.items[aggregates.items.len - 1 ..];
    } else if (history == .distinct and opts.limit > 0 and aggregates.items.len > opts.limit) {
        aggregate_slice = aggregates.items[0..opts.limit];
    }

    var out_rows = try aggregatedSkillBlockRowsToQueryRows(allocator, aggregate_slice);
    defer deinitQueryRows(allocator, &out_rows);
    const cols = [_][]const u8{
        "skill",
        "skill_path",
        "block_hash",
        "block_text",
        "first_seen_timestamp",
        "first_seen_path",
        "last_seen_timestamp",
        "last_seen_path",
        "occurrence_count",
        "roles",
    };
    try output.writeOutput(allocator, if (opts.format_set) opts.format else .jsonl, out_rows.items, cols[0..], opts.out_path);
}

fn cmdRoleBreakdown(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    try appendSessionTimeBounds(allocator, &where, opts);
    const query_spec = spec.QuerySpec{
        .where = where.items,
        .group_by = &.{ "skill", "role" },
        .metrics = &.{.{ .op = .count, .alias = "count" }},
    };

    var occ_rows = try collectDatasetRows(allocator, "skill_mentions", sessions_root, &.{}, where.items);
    defer deinitQueryRows(allocator, &occ_rows);

    var grouped = try query.execute(allocator, occ_rows.items, query_spec);
    defer grouped.deinit(allocator);

    const Counts = struct {
        skill: []u8,
        user: i64 = 0,
        assistant: i64 = 0,
    };

    var totals: std.ArrayList(Counts) = .empty;
    defer {
        for (totals.items) |entry| allocator.free(entry.skill);
        totals.deinit(allocator);
    }

    for (grouped.rows.items) |row| {
        const skill_scalar = row.valueOrNull("skill");
        const role_scalar = row.valueOrNull("role");
        const count_scalar = row.valueOrNull("count");
        if (skill_scalar != .string or role_scalar != .string) continue;
        const count = scalarAsInt(count_scalar) orelse 0;

        var idx_opt: ?usize = null;
        for (totals.items, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.skill, skill_scalar.string)) {
                idx_opt = idx;
                break;
            }
        }

        if (idx_opt == null) {
            try totals.append(allocator, .{ .skill = try allocator.dupe(u8, skill_scalar.string) });
            idx_opt = totals.items.len - 1;
        }

        const idx = idx_opt.?;
        if (std.mem.eql(u8, role_scalar.string, "user")) {
            totals.items[idx].user += count;
        } else if (std.mem.eql(u8, role_scalar.string, "assistant")) {
            totals.items[idx].assistant += count;
        }
    }

    std.mem.sort(Counts, totals.items, {}, struct {
        fn lessThan(_: void, lhs: Counts, rhs: Counts) bool {
            const lhs_total = lhs.user + lhs.assistant;
            const rhs_total = rhs.user + rhs.assistant;
            if (lhs_total != rhs_total) return lhs_total > rhs_total;
            return std.mem.order(u8, lhs.skill, rhs.skill) == .lt;
        }
    }.lessThan);

    const max_rows = if (opts.limit > 0 and totals.items.len > opts.limit) opts.limit else totals.items.len;
    var out_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &out_rows);

    for (totals.items[0..max_rows]) |entry| {
        var out = query.Row.init(allocator);
        try out.putOwnedKey("skill", .{ .string = entry.skill });
        try out.putOwnedKey("user", .{ .int = entry.user });
        try out.putOwnedKey("assistant", .{ .int = entry.assistant });
        try out.putOwnedKey("total", .{ .int = entry.user + entry.assistant });
        try out_rows.append(allocator, out);
    }

    const cols = [_][]const u8{ "skill", "user", "assistant", "total" };
    try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
}

fn cmdOccurrenceExport(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    if (opts.skill) |skill_name| {
        try where.append(allocator, .{
            .field = "skill",
            .op = .eq,
            .value = .{ .scalar = .{ .string = skill_name } },
        });
    }
    try appendSessionTimeBounds(allocator, &where, opts);
    const select = [_][]const u8{ "path", "timestamp", "role", "skill", "types", "snippet" };
    const query_spec = spec.QuerySpec{
        .where = where.items,
        .select = select[0..],
        .sort = &.{.{ .field = "timestamp", .descending = false }},
        .limit = opts.limit,
    };
    const fmt = if (opts.format_set) opts.format else output.Format.jsonl;
    try runDatasetQuery(allocator, "skill_mentions", sessions_root, query_spec, fmt, opts.out_path, select[0..]);
}

const ConcurrencySummary = struct {
    session_id: []const u8,
    session_path: []const u8,
    spawn_calls: i64 = 0,
    spawn_substrate: []const u8 = "none",
    spawn_agent_calls: i64 = 0,
    wait_calls: i64 = 0,
    close_agent_calls: i64 = 0,
    max_configured_concurrency: ?i64 = null,
    max_configured_occurrences: i64 = 0,
    max_effective_concurrency: ?i64 = null,
    max_effective_occurrences: i64 = 0,
    csv_rows_known: i64 = 0,
    csv_rows_missing: i64 = 0,
    max_observed_csv_rows: ?i64 = null,
    serialized_wait_calls: i64 = 0,

    fn observe(self: *ConcurrencySummary, configured_concurrency: i64, csv_rows: ?i64) void {
        self.spawn_calls += 1;
        self.refreshSubstrate();
        updateMaxCounter(
            &self.max_configured_concurrency,
            &self.max_configured_occurrences,
            configured_concurrency,
        );

        if (csv_rows) |row_count| {
            self.csv_rows_known += 1;
            if (self.max_observed_csv_rows == null or row_count > self.max_observed_csv_rows.?) {
                self.max_observed_csv_rows = row_count;
            }
            const effective = if (configured_concurrency < row_count) configured_concurrency else row_count;
            if (effective < configured_concurrency) {
                self.serialized_wait_calls += 1;
            }
            updateMaxCounter(
                &self.max_effective_concurrency,
                &self.max_effective_occurrences,
                effective,
            );
        } else {
            self.csv_rows_missing += 1;
        }
    }

    fn mergeFrom(self: *ConcurrencySummary, other: ConcurrencySummary) void {
        self.spawn_calls += other.spawn_calls;
        self.spawn_agent_calls += other.spawn_agent_calls;
        self.wait_calls += other.wait_calls;
        self.close_agent_calls += other.close_agent_calls;
        self.csv_rows_known += other.csv_rows_known;
        self.csv_rows_missing += other.csv_rows_missing;
        self.serialized_wait_calls += other.serialized_wait_calls;
        if (other.max_observed_csv_rows) |other_max| {
            if (self.max_observed_csv_rows == null or other_max > self.max_observed_csv_rows.?) {
                self.max_observed_csv_rows = other_max;
            }
        }
        mergeMaxCounter(
            &self.max_configured_concurrency,
            &self.max_configured_occurrences,
            other.max_configured_concurrency,
            other.max_configured_occurrences,
        );
        mergeMaxCounter(
            &self.max_effective_concurrency,
            &self.max_effective_occurrences,
            other.max_effective_concurrency,
            other.max_effective_occurrences,
        );
        self.refreshSubstrate();
    }

    fn hasSignals(self: ConcurrencySummary) bool {
        return self.spawn_calls > 0 or self.spawn_agent_calls > 0 or self.wait_calls > 0 or self.close_agent_calls > 0;
    }

    fn meshTruthVerdict(self: ConcurrencySummary) bool {
        return self.spawn_calls > 0;
    }

    fn refreshSubstrate(self: *ConcurrencySummary) void {
        if (self.spawn_calls > 0 and self.spawn_agent_calls > 0) {
            self.spawn_substrate = "mixed";
            return;
        }
        if (self.spawn_calls > 0) {
            self.spawn_substrate = "spawn_agents_on_csv";
            return;
        }
        if (self.spawn_agent_calls > 0) {
            self.spawn_substrate = "spawn_agent";
            return;
        }
        self.spawn_substrate = "none";
    }
};

const SpawnAgentsInvocation = struct {
    max_concurrency: i64,
    csv_path: ?[]u8,

    fn deinit(self: SpawnAgentsInvocation, allocator: std.mem.Allocator) void {
        if (self.csv_path) |path| allocator.free(path);
    }
};

const FloorEvaluation = struct {
    applicable: bool,
    result: []const u8,
};

fn cmdOrchestrationConcurrency(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
) !void {
    var input_paths = try resolveOrchestrationInputPaths(allocator, sessions_root, opts, null);
    defer freePathList(allocator, &input_paths);

    var out_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &out_rows);

    var total = ConcurrencySummary{
        .session_id = "__all__",
        .session_path = "-",
    };
    var included_sessions: usize = 0;
    var floor_failed = false;
    var mesh_truth_failed = false;

    for (input_paths.items) |session_path| {
        const summary = try summarizeSessionConcurrency(allocator, session_path);
        const explicit_target = opts.path != null or opts.session_id != null;
        if (!summary.hasSignals() and !explicit_target) continue;

        included_sessions += 1;
        total.mergeFrom(summary);
        const floor_eval = evaluateFloor(summary, opts.floor_threshold);
        if (floor_eval.applicable and std.mem.eql(u8, floor_eval.result, "fail")) {
            floor_failed = true;
        }
        if (!summary.meshTruthVerdict()) {
            mesh_truth_failed = true;
        }

        var row = query.Row.init(allocator);
        try row.putOwnedKey("session_id", .{ .string = summary.session_id });
        try row.putOwnedKey("path", .{ .string = summary.session_path });
        try row.putOwnedKey("spawn_substrate", .{ .string = summary.spawn_substrate });
        try row.putOwnedKey("mesh_truth_verdict", .{ .bool = summary.meshTruthVerdict() });
        try row.putOwnedKey("spawn_calls", .{ .int = summary.spawn_calls });
        try row.putOwnedKey("spawn_agent_calls", .{ .int = summary.spawn_agent_calls });
        try row.putOwnedKey("wait_calls", .{ .int = summary.wait_calls });
        try row.putOwnedKey("close_agent_calls", .{ .int = summary.close_agent_calls });
        try putOptionalInt(&row, "max_configured_concurrency", summary.max_configured_concurrency);
        try row.putOwnedKey("max_configured_occurrences", .{ .int = summary.max_configured_occurrences });
        try putOptionalInt(&row, "max_effective_concurrency", summary.max_effective_concurrency);
        try putOptionalInt(&row, "effective_peak", summary.max_effective_concurrency);
        try row.putOwnedKey("max_effective_occurrences", .{ .int = summary.max_effective_occurrences });
        try row.putOwnedKey("csv_rows_known", .{ .int = summary.csv_rows_known });
        try row.putOwnedKey("csv_rows_missing", .{ .int = summary.csv_rows_missing });
        try row.putOwnedKey("serialized_wait_calls", .{ .int = summary.serialized_wait_calls });
        if (summary.csv_rows_known > 0) {
            const ratio = @as(f64, @floatFromInt(summary.serialized_wait_calls)) / @as(f64, @floatFromInt(summary.csv_rows_known));
            try row.putOwnedKey("serialized_wait_ratio", .{ .float = ratio });
        } else {
            try row.putOwnedKey("serialized_wait_ratio", .null);
        }
        try row.putOwnedKey("floor_threshold", .{ .int = opts.floor_threshold });
        try row.putOwnedKey("floor_applicable", .{ .bool = floor_eval.applicable });
        try row.putOwnedKey("floor_result", .{ .string = floor_eval.result });
        try out_rows.append(allocator, row);
    }

    if (included_sessions == 0) return error.NoOrchestrationSignals;
    if (included_sessions > 1) {
        const floor_eval = evaluateFloor(total, opts.floor_threshold);
        if (floor_eval.applicable and std.mem.eql(u8, floor_eval.result, "fail")) {
            floor_failed = true;
        }
        if (!total.meshTruthVerdict()) {
            mesh_truth_failed = true;
        }
        var row = query.Row.init(allocator);
        try row.putOwnedKey("session_id", .{ .string = total.session_id });
        try row.putOwnedKey("path", .{ .string = total.session_path });
        try row.putOwnedKey("spawn_substrate", .{ .string = total.spawn_substrate });
        try row.putOwnedKey("mesh_truth_verdict", .{ .bool = total.meshTruthVerdict() });
        try row.putOwnedKey("spawn_calls", .{ .int = total.spawn_calls });
        try row.putOwnedKey("spawn_agent_calls", .{ .int = total.spawn_agent_calls });
        try row.putOwnedKey("wait_calls", .{ .int = total.wait_calls });
        try row.putOwnedKey("close_agent_calls", .{ .int = total.close_agent_calls });
        try putOptionalInt(&row, "max_configured_concurrency", total.max_configured_concurrency);
        try row.putOwnedKey("max_configured_occurrences", .{ .int = total.max_configured_occurrences });
        try putOptionalInt(&row, "max_effective_concurrency", total.max_effective_concurrency);
        try putOptionalInt(&row, "effective_peak", total.max_effective_concurrency);
        try row.putOwnedKey("max_effective_occurrences", .{ .int = total.max_effective_occurrences });
        try row.putOwnedKey("csv_rows_known", .{ .int = total.csv_rows_known });
        try row.putOwnedKey("csv_rows_missing", .{ .int = total.csv_rows_missing });
        try row.putOwnedKey("serialized_wait_calls", .{ .int = total.serialized_wait_calls });
        if (total.csv_rows_known > 0) {
            const ratio = @as(f64, @floatFromInt(total.serialized_wait_calls)) / @as(f64, @floatFromInt(total.csv_rows_known));
            try row.putOwnedKey("serialized_wait_ratio", .{ .float = ratio });
        } else {
            try row.putOwnedKey("serialized_wait_ratio", .null);
        }
        try row.putOwnedKey("floor_threshold", .{ .int = opts.floor_threshold });
        try row.putOwnedKey("floor_applicable", .{ .bool = floor_eval.applicable });
        try row.putOwnedKey("floor_result", .{ .string = floor_eval.result });
        try out_rows.append(allocator, row);
    }

    const cols = [_][]const u8{
        "session_id",
        "path",
        "spawn_substrate",
        "mesh_truth_verdict",
        "spawn_calls",
        "spawn_agent_calls",
        "wait_calls",
        "close_agent_calls",
        "max_configured_concurrency",
        "max_configured_occurrences",
        "max_effective_concurrency",
        "effective_peak",
        "max_effective_occurrences",
        "csv_rows_known",
        "csv_rows_missing",
        "serialized_wait_calls",
        "serialized_wait_ratio",
        "floor_threshold",
        "floor_applicable",
        "floor_result",
    };
    try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
    if (opts.fail_on_floor and floor_failed) return error.ConcurrencyFloorFailed;
    if (opts.fail_on_mesh_truth and mesh_truth_failed) return error.MeshTruthFailed;
}

fn evaluateFloor(summary: ConcurrencySummary, threshold: i64) FloorEvaluation {
    if (summary.max_observed_csv_rows == null or summary.max_observed_csv_rows.? < threshold) {
        return .{ .applicable = false, .result = "not_applicable" };
    }
    const peak = summary.max_effective_concurrency orelse return .{ .applicable = true, .result = "fail" };
    if (peak >= threshold) return .{ .applicable = true, .result = "pass" };
    return .{ .applicable = true, .result = "fail" };
}

fn summarizeSessionConcurrency(
    allocator: std.mem.Allocator,
    session_path: []const u8,
) !ConcurrencySummary {
    var summary = ConcurrencySummary{
        .session_id = inferSessionIdFromPath(session_path),
        .session_path = session_path,
    };

    const content_opt = try readFileAllocOrSkip(allocator, session_path);
    if (content_opt == null) return summary;
    defer allocator.free(content_opt.?);

    var lines = std.mem.splitScalar(u8, content_opt.?, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.containsAtLeast(u8, trimmed, 1, "\"type\":\"function_call\"")) {
            if (std.mem.containsAtLeast(u8, trimmed, 1, "\"name\":\"spawn_agent\"")) {
                summary.spawn_agent_calls += 1;
            } else if (std.mem.containsAtLeast(u8, trimmed, 1, "\"name\":\"wait\"")) {
                summary.wait_calls += 1;
            } else if (std.mem.containsAtLeast(u8, trimmed, 1, "\"name\":\"close_agent\"")) {
                summary.close_agent_calls += 1;
            }
        }

        if (!std.mem.containsAtLeast(u8, trimmed, 1, "spawn_agents_on_csv")) continue;

        const invocation_opt = try parseSpawnAgentsInvocation(allocator, trimmed);
        if (invocation_opt == null) continue;
        const invocation = invocation_opt.?;
        defer invocation.deinit(allocator);

        const csv_rows = if (invocation.csv_path) |csv_path|
            try countCsvDataRows(allocator, csv_path)
        else
            null;

        summary.observe(invocation.max_concurrency, csv_rows);
    }

    summary.refreshSubstrate();
    return summary;
}

fn parseSpawnAgentsInvocation(
    allocator: std.mem.Allocator,
    line: []const u8,
) !?SpawnAgentsInvocation {
    if (line.len == 0 or line[0] != '{') return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{}) catch return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };
    if (!stdJsonFieldEq(root, "type", "response_item")) return null;

    const payload = stdJsonObjectField(root, "payload") orelse return null;
    if (!stdJsonFieldEq(payload, "type", "function_call")) return null;
    if (!stdJsonFieldEq(payload, "name", "spawn_agents_on_csv")) return null;

    const arguments_text = stdJsonStringField(payload, "arguments") orelse return null;
    const arguments_parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), arguments_text, .{}) catch return null;
    defer arguments_parsed.deinit();

    const arguments_obj = switch (arguments_parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    const configured =
        stdJsonIntField(arguments_obj, "max_concurrency") orelse
        stdJsonIntField(arguments_obj, "max_workers") orelse
        16;

    return .{
        .max_concurrency = if (configured < 1) 1 else configured,
        .csv_path = if (stdJsonStringField(arguments_obj, "csv_path")) |path|
            try allocator.dupe(u8, path)
        else
            null,
    };
}

fn countCsvDataRows(allocator: std.mem.Allocator, csv_path: []const u8) !?i64 {
    const absolute = try toAbsolutePath(allocator, csv_path);
    defer allocator.free(absolute);

    const file = std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), absolute, .{}) catch return null;
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    const content = reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024)) catch return null;
    defer allocator.free(content);

    var rows: i64 = 0;
    var seen_header = false;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (!seen_header) {
            seen_header = true;
            continue;
        }
        rows += 1;
    }
    return if (seen_header) rows else 0;
}

fn resolveOrchestrationInputPaths(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
    day_filter: ?SessionDayPathFilter,
) !std.ArrayList([]u8) {
    if (opts.path) |single_path| {
        var out: std.ArrayList([]u8) = .empty;
        errdefer freePathList(allocator, &out);

        const absolute = try toAbsolutePath(allocator, single_path);
        try out.append(allocator, absolute);

        if (opts.session_id) |wanted| {
            if (!std.mem.containsAtLeast(u8, absolute, 1, wanted)) {
                return error.SessionNotFound;
            }
        }
        return out;
    }

    var paths = try collectJsonlPaths(allocator, sessions_root, day_filter);
    errdefer freePathList(allocator, &paths);

    if (opts.session_id) |wanted| {
        var write_idx: usize = 0;
        for (paths.items) |path| {
            if (std.mem.containsAtLeast(u8, path, 1, wanted)) {
                paths.items[write_idx] = path;
                write_idx += 1;
            } else {
                allocator.free(path);
            }
        }
        paths.items.len = write_idx;
        if (paths.items.len == 0) return error.SessionNotFound;
    }

    return paths;
}

const InvocationKind = enum {
    function_call,
    custom_tool_call,
};

const InvocationRecord = struct {
    path: []u8,
    session_id: []u8,
    start_ts: ?[]u8 = null,
    end_ts: ?[]u8 = null,
    call_id: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    invocation_kind: InvocationKind,
    arguments_text: ?[]u8 = null,
    input_text: ?[]u8 = null,
    command_text: ?[]u8 = null,
    primary_executable: ?[]u8 = null,
    workdir: ?[]u8 = null,
    status_text: ?[]u8 = null,
    pty_session_id: ?i64 = null,
    output_seen: bool = false,
    output_running: bool = false,
    output_exited: bool = false,
    exit_code: ?i64 = null,
    wall_time_ms: ?i64 = null,
    parse_error: bool = false,

    fn deinit(self: *InvocationRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.session_id);
        if (self.start_ts) |value| allocator.free(value);
        if (self.end_ts) |value| allocator.free(value);
        if (self.call_id) |value| allocator.free(value);
        if (self.tool_name) |value| allocator.free(value);
        if (self.arguments_text) |value| allocator.free(value);
        if (self.input_text) |value| allocator.free(value);
        if (self.command_text) |value| allocator.free(value);
        if (self.primary_executable) |value| allocator.free(value);
        if (self.workdir) |value| allocator.free(value);
        if (self.status_text) |value| allocator.free(value);
    }

    fn unresolved(self: InvocationRecord) bool {
        return std.mem.eql(u8, self.runningState(), "running_unresolved") or
            std.mem.eql(u8, self.runningState(), "unresolved_no_output");
    }

    fn runningState(self: InvocationRecord) []const u8 {
        if (self.invocation_kind == .custom_tool_call) return "not_applicable";
        if (!self.output_seen) return "unresolved_no_output";
        if (self.output_running and !self.output_exited) return "running_unresolved";
        if (self.output_running and self.output_exited) return "running_then_resolved";
        if (self.output_exited) return "completed";
        return "output_without_state";
    }

    fn invocationKindText(self: InvocationRecord) []const u8 {
        return switch (self.invocation_kind) {
            .function_call => "function_call",
            .custom_tool_call => "custom_tool_call",
        };
    }
};

const OutputMarkers = struct {
    saw_running: bool = false,
    saw_exited: bool = false,
    pty_session_id: ?i64 = null,
    exit_code: ?i64 = null,
    wall_time_ms: ?i64 = null,
};

const GoalToolCall = struct {
    name: []u8,
    timestamp: ?[]u8 = null,

    fn deinit(self: *GoalToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.timestamp) |value| allocator.free(value);
    }
};

const GoalAggregate = struct {
    path: []u8,
    session_id: []u8,
    thread_id: ?[]u8 = null,
    timestamp: ?[]u8 = null,
    objective: ?[]u8 = null,
    status: ?[]u8 = null,
    created_at: ?i64 = null,
    updated_at: ?i64 = null,
    time_used_seconds: ?i64 = null,
    tokens_used: ?i64 = null,
    remaining_tokens: ?i64 = null,
    completion_budget_report: ?[]u8 = null,
    review_invocation_count: i64 = 0,
    parse_error: bool = false,

    fn init(allocator: std.mem.Allocator, path: []const u8) !GoalAggregate {
        return .{
            .path = try allocator.dupe(u8, path),
            .session_id = try allocator.dupe(u8, inferSessionIdFromPath(path)),
        };
    }

    fn deinit(self: *GoalAggregate, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.session_id);
        if (self.thread_id) |value| allocator.free(value);
        if (self.timestamp) |value| allocator.free(value);
        if (self.objective) |value| allocator.free(value);
        if (self.status) |value| allocator.free(value);
        if (self.completion_budget_report) |value| allocator.free(value);
    }

    fn updateString(
        self: *GoalAggregate,
        allocator: std.mem.Allocator,
        comptime field_name: []const u8,
        value_opt: ?[]const u8,
    ) !void {
        const value = value_opt orelse return;
        if (std.mem.eql(u8, field_name, "thread_id")) {
            if (self.thread_id) |old| allocator.free(old);
            self.thread_id = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, field_name, "objective")) {
            if (self.objective) |old| allocator.free(old);
            self.objective = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, field_name, "status")) {
            if (self.status) |old| allocator.free(old);
            self.status = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, field_name, "completion_budget_report")) {
            if (self.completion_budget_report) |old| allocator.free(old);
            self.completion_budget_report = try allocator.dupe(u8, value);
        }
    }

    fn observeTimestamp(self: *GoalAggregate, allocator: std.mem.Allocator, timestamp_opt: ?[]const u8) !void {
        const timestamp = timestamp_opt orelse return;
        if (self.timestamp == null or compareNormalizedTimestamp(timestamp, self.timestamp.?) == .lt) {
            if (self.timestamp) |old| allocator.free(old);
            self.timestamp = try allocator.dupe(u8, timestamp);
        }
    }
};

const ToolingGroupMode = enum {
    executable,
    command,
    tool,
};

const ToolingSummaryBucket = struct {
    key: []u8,
    count: i64 = 0,
    error_count: i64 = 0,
    running_count: i64 = 0,
    durations_ms: std.ArrayList(i64) = .empty,

    fn deinit(self: *ToolingSummaryBucket, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.durations_ms.deinit(allocator);
    }
};

fn cmdSessionTooling(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
) !void {
    var records = try collectInvocationRecords(allocator, sessions_root, opts);
    defer deinitInvocationRecords(allocator, &records);

    if (opts.summary) {
        const mode = try parseToolingGroupMode(opts.group_by_text);
        var filtered: std.ArrayList(InvocationRecord) = .empty;
        defer filtered.deinit(allocator);
        for (records.items) |record| {
            if (!timestampSatisfiesBounds(record.start_ts, opts)) continue;
            try filtered.append(allocator, record);
        }
        var rows = try buildSessionToolingSummaryRows(allocator, filtered.items, mode);
        defer deinitQueryRows(allocator, &rows);
        trimQueryRows(&rows, opts.limit);
        const cols = [_][]const u8{
            "group_key",
            "count",
            "error_count",
            "running_count",
            "p95_wall_time_ms",
        };
        try output.writeOutput(allocator, opts.format, rows.items, cols[0..], opts.out_path);
        return;
    }

    var out_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &out_rows);

    var emitted: usize = 0;
    for (records.items) |record| {
        if (!timestampSatisfiesBounds(record.start_ts, opts)) continue;
        if (opts.limit > 0 and emitted >= opts.limit) break;
        var row = query.Row.init(allocator);
        try row.putOwnedKey("session_id", .{ .string = record.session_id });
        try row.putOwnedKey("path", .{ .string = record.path });
        try putOptionalString(&row, "timestamp", record.start_ts);
        try putOptionalString(&row, "end_timestamp", record.end_ts);
        try putOptionalString(&row, "call_id", record.call_id);
        try putOptionalString(&row, "tool_name", record.tool_name);
        try row.putOwnedKey("invocation_kind", .{ .string = record.invocationKindText() });
        try putOptionalString(&row, "command_text", record.command_text);
        try putOptionalString(&row, "primary_executable", record.primary_executable);
        try putOptionalInt(&row, "pty_session_id", record.pty_session_id);
        try putOptionalInt(&row, "wall_time_ms", record.wall_time_ms);
        try putOptionalInt(&row, "exit_code", record.exit_code);
        try row.putOwnedKey("running_state", .{ .string = record.runningState() });
        try row.putOwnedKey("unresolved", .{ .bool = record.unresolved() });
        try out_rows.append(allocator, row);
        emitted += 1;
    }

    const cols = [_][]const u8{
        "session_id",
        "path",
        "timestamp",
        "end_timestamp",
        "call_id",
        "tool_name",
        "invocation_kind",
        "command_text",
        "primary_executable",
        "pty_session_id",
        "wall_time_ms",
        "exit_code",
        "running_state",
        "unresolved",
    };
    try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
}

fn cmdQueryDiagnose(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
) !void {
    var records = try collectInvocationRecords(allocator, sessions_root, opts);
    defer deinitInvocationRecords(allocator, &records);

    var query_total: i64 = 0;
    var hang_count: i64 = 0;
    var unresolved_count: i64 = 0;
    var duration_values: std.ArrayList(i64) = .empty;
    defer duration_values.deinit(allocator);

    var out_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &out_rows);

    for (records.items) |record| {
        if (!timestampSatisfiesBounds(record.start_ts, opts)) continue;
        if (!isSeqQueryInvocation(record)) continue;
        query_total += 1;

        const unresolved = record.unresolved();
        const threshold_exceeded = if (record.wall_time_ms) |wall_time|
            wall_time >= opts.threshold_ms
        else
            false;
        const hang_flag = if (opts.strict_hang)
            unresolved and threshold_exceeded
        else
            unresolved or threshold_exceeded;
        const diagnosis = if (unresolved and threshold_exceeded)
            "actual_slow_query"
        else if (unresolved and std.mem.eql(u8, record.runningState(), "running_unresolved"))
            "polling_unresolved"
        else if (unresolved)
            "unresolved_no_output"
        else if (threshold_exceeded)
            "slow_but_completed"
        else
            "completed";
        if (hang_flag) hang_count += 1;
        if (unresolved) unresolved_count += 1;
        if (record.wall_time_ms) |wall_time| {
            try duration_values.append(allocator, wall_time);
        }

        if (opts.summary) continue;

        var row = query.Row.init(allocator);
        try row.putOwnedKey("query_call_id", .{ .string = record.call_id orelse "-" });
        try row.putOwnedKey("session_id", .{ .string = record.session_id });
        try row.putOwnedKey("path", .{ .string = record.path });
        try putOptionalString(&row, "started_at", record.start_ts);
        try putOptionalString(&row, "ended_at", record.end_ts);
        try putOptionalInt(&row, "duration_ms", record.wall_time_ms);
        try row.putOwnedKey("command_class", .{ .string = queryCommandClass(record.command_text) });
        const dataset_hint = try extractDatasetHint(allocator, record.command_text);
        defer if (dataset_hint) |hint| allocator.free(hint);
        try putOptionalString(&row, "dataset_hint", dataset_hint);
        try row.putOwnedKey("unresolved", .{ .bool = unresolved });
        try row.putOwnedKey("threshold_exceeded", .{ .bool = threshold_exceeded });
        try row.putOwnedKey("hang_flag", .{ .bool = hang_flag });
        try putOptionalInt(&row, "pty_session_id", record.pty_session_id);
        try row.putOwnedKey("resolution_state", .{ .string = queryResolutionState(record) });
        try row.putOwnedKey("diagnosis", .{ .string = diagnosis });
        try putOptionalString(&row, "query_invocation", record.command_text);
        if (opts.next_actions) {
            const next_action = try buildNextAction(allocator, record, hang_flag);
            defer if (next_action) |value| allocator.free(value);
            try putOptionalString(&row, "next_action", next_action);
        }
        try out_rows.append(allocator, row);
    }

    if (opts.summary) {
        var row = query.Row.init(allocator);
        try row.putOwnedKey("queries_total", .{ .int = query_total });
        try row.putOwnedKey("hangs_total", .{ .int = hang_count });
        try row.putOwnedKey("unresolved_total", .{ .int = unresolved_count });
        try putOptionalInt(&row, "p50_duration_ms", try percentileDuration(allocator, duration_values.items, 50));
        try putOptionalInt(&row, "p95_duration_ms", try percentileDuration(allocator, duration_values.items, 95));
        try row.putOwnedKey("threshold_ms", .{ .int = opts.threshold_ms });
        try row.putOwnedKey("strict_hang", .{ .bool = opts.strict_hang });
        if (opts.next_actions and hang_count > 0) {
            const next_action = try std.fmt.allocPrint(
                allocator,
                "seq session-tooling --root {s} --summary --group-by executable --format table",
                .{sessions_root},
            );
            defer allocator.free(next_action);
            try row.putOwnedKey("next_action", .{ .string = next_action });
        } else if (opts.next_actions) {
            try row.putOwnedKey("next_action", .{ .string = "none" });
        }
        try out_rows.append(allocator, row);

        if (opts.next_actions) {
            const cols = [_][]const u8{ "queries_total", "hangs_total", "unresolved_total", "p50_duration_ms", "p95_duration_ms", "threshold_ms", "strict_hang", "next_action" };
            try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
        } else {
            const cols = [_][]const u8{ "queries_total", "hangs_total", "unresolved_total", "p50_duration_ms", "p95_duration_ms", "threshold_ms", "strict_hang" };
            try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
        }
    } else {
        trimQueryRows(&out_rows, opts.limit);
        if (opts.next_actions) {
            const cols = [_][]const u8{ "query_call_id", "session_id", "path", "started_at", "ended_at", "duration_ms", "command_class", "dataset_hint", "unresolved", "threshold_exceeded", "hang_flag", "pty_session_id", "resolution_state", "diagnosis", "query_invocation", "next_action" };
            try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
        } else {
            const cols = [_][]const u8{ "query_call_id", "session_id", "path", "started_at", "ended_at", "duration_ms", "command_class", "dataset_hint", "unresolved", "threshold_exceeded", "hang_flag", "pty_session_id", "resolution_state", "diagnosis", "query_invocation" };
            try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
        }
    }

    if (opts.fail_on_hang and hang_count > 0) return error.QueryHangDetected;
}

fn parseToolingGroupMode(raw_text: ?[]const u8) !ToolingGroupMode {
    const raw = raw_text orelse return .executable;
    const first = if (std.mem.indexOfScalar(u8, raw, ',')) |idx|
        raw[0..idx]
    else
        raw;
    const trimmed = std.mem.trim(u8, first, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "executable")) return .executable;
    if (std.mem.eql(u8, trimmed, "command")) return .command;
    if (std.mem.eql(u8, trimmed, "tool")) return .tool;
    return error.InvalidGroupBy;
}

fn buildSessionToolingSummaryRows(
    allocator: std.mem.Allocator,
    records: []const InvocationRecord,
    mode: ToolingGroupMode,
) !std.ArrayList(query.Row) {
    var bucket_index = std.StringHashMap(usize).init(allocator);
    defer bucket_index.deinit();

    var buckets: std.ArrayList(ToolingSummaryBucket) = .empty;
    defer {
        for (buckets.items) |*bucket| bucket.deinit(allocator);
        buckets.deinit(allocator);
    }

    for (records) |record| {
        if (mode != .tool and record.command_text == null) continue;
        const key_text = switch (mode) {
            .executable => record.primary_executable orelse "unknown",
            .command => record.command_text orelse "unknown",
            .tool => record.tool_name orelse "unknown",
        };

        const index = if (bucket_index.get(key_text)) |existing|
            existing
        else blk: {
            const key_copy = try allocator.dupe(u8, key_text);
            errdefer allocator.free(key_copy);
            const idx = buckets.items.len;
            try buckets.append(allocator, .{ .key = key_copy });
            try bucket_index.put(key_copy, idx);
            break :blk idx;
        };

        var bucket = &buckets.items[index];
        bucket.count += 1;
        if (record.exit_code != null and record.exit_code.? != 0) {
            bucket.error_count += 1;
        }
        if (record.unresolved()) {
            bucket.running_count += 1;
        }
        if (record.wall_time_ms) |wall_time| {
            try bucket.durations_ms.append(allocator, wall_time);
        }
    }

    std.mem.sort(ToolingSummaryBucket, buckets.items, {}, lessToolingSummaryBucket);

    var out_rows: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &out_rows);

    for (buckets.items) |*bucket| {
        var row = query.Row.init(allocator);
        try row.putOwnedKey("group_key", .{ .string = bucket.key });
        try row.putOwnedKey("count", .{ .int = bucket.count });
        try row.putOwnedKey("error_count", .{ .int = bucket.error_count });
        try row.putOwnedKey("running_count", .{ .int = bucket.running_count });
        try putOptionalInt(&row, "p95_wall_time_ms", try percentileDuration(allocator, bucket.durations_ms.items, 95));
        try out_rows.append(allocator, row);
    }

    return out_rows;
}

fn lessToolingSummaryBucket(_: void, a: ToolingSummaryBucket, b: ToolingSummaryBucket) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn percentileDuration(
    allocator: std.mem.Allocator,
    values: []const i64,
    percentile: usize,
) !?i64 {
    if (values.len == 0) return null;
    const copy = try allocator.alloc(i64, values.len);
    defer allocator.free(copy);
    @memcpy(copy, values);
    std.mem.sort(i64, copy, {}, lessI64);
    const n = copy.len;
    const rank = (n * percentile + 99) / 100;
    const index = if (rank == 0) 0 else rank - 1;
    return copy[index];
}

fn lessI64(_: void, a: i64, b: i64) bool {
    return a < b;
}

fn collectInvocationRecords(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
) !std.ArrayList(InvocationRecord) {
    const day_filter = deriveSessionDayPathFilterFromOptions(opts);
    var input_paths = try resolveOrchestrationInputPaths(allocator, sessions_root, opts, day_filter);
    defer freePathList(allocator, &input_paths);

    var records: std.ArrayList(InvocationRecord) = .empty;
    errdefer deinitInvocationRecords(allocator, &records);

    for (input_paths.items) |session_path| {
        try collectInvocationRecordsFromSession(allocator, session_path, &records);
    }

    return records;
}

fn collectInvocationRecordsForRoot(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
) !std.ArrayList(InvocationRecord) {
    var input_paths = try collectJsonlPaths(allocator, sessions_root, day_filter);
    defer freePathList(allocator, &input_paths);

    var records: std.ArrayList(InvocationRecord) = .empty;
    errdefer deinitInvocationRecords(allocator, &records);

    for (input_paths.items) |session_path| {
        try collectInvocationRecordsFromSession(allocator, session_path, &records);
    }

    return records;
}

fn collectInvocationRecordsFromSession(
    allocator: std.mem.Allocator,
    session_path: []const u8,
    out: *std.ArrayList(InvocationRecord),
) !void {
    const content_opt = try readFileAllocOrSkip(allocator, session_path);
    if (content_opt == null) return;
    defer allocator.free(content_opt.?);

    var call_indices = std.StringHashMap(usize).init(allocator);
    defer call_indices.deinit();

    var lines = std.mem.splitScalar(u8, content_opt.?, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '{') continue;
        if (!std.mem.containsAtLeast(u8, trimmed, 1, "\"type\":\"response_item\"")) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), trimmed, .{}) catch continue;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        if (!stdJsonFieldEq(root, "type", "response_item")) continue;

        const payload = stdJsonObjectField(root, "payload") orelse continue;
        const payload_type = stdJsonStringField(payload, "type") orelse continue;
        const timestamp = stdJsonStringField(root, "timestamp");

        if (std.mem.eql(u8, payload_type, "function_call") or std.mem.eql(u8, payload_type, "custom_tool_call")) {
            const invocation_kind: InvocationKind = if (std.mem.eql(u8, payload_type, "function_call")) .function_call else .custom_tool_call;
            const tool_name = stdJsonStringField(payload, "name") orelse continue;

            var record = InvocationRecord{
                .path = try allocator.dupe(u8, session_path),
                .session_id = try allocator.dupe(u8, inferSessionIdFromPath(session_path)),
                .invocation_kind = invocation_kind,
            };
            errdefer record.deinit(allocator);

            if (timestamp) |value| {
                record.start_ts = try allocator.dupe(u8, value);
            }
            record.tool_name = try allocator.dupe(u8, tool_name);

            if (stdJsonStringField(payload, "call_id")) |call_id| {
                record.call_id = try allocator.dupe(u8, call_id);
            }

            if (invocation_kind == .function_call) {
                if (stdJsonStringField(payload, "arguments")) |arguments_text| {
                    try applyFunctionCallArguments(allocator, &record, arguments_text);
                }
            } else {
                if (stdJsonStringField(payload, "status")) |status_text| {
                    record.status_text = try allocator.dupe(u8, status_text);
                }
                if (stdJsonStringField(payload, "input")) |input_text| {
                    record.input_text = try allocator.dupe(u8, input_text);
                    if (std.mem.eql(u8, tool_name, "shell")) {
                        record.command_text = try allocator.dupe(u8, input_text);
                        record.primary_executable = try extractPrimaryExecutable(allocator, input_text);
                    }
                }
            }

            const index = out.items.len;
            try out.append(allocator, record);
            if (record.call_id) |call_id| {
                try call_indices.put(call_id, index);
            }
            continue;
        }

        if (!std.mem.eql(u8, payload_type, "function_call_output")) continue;
        const call_id = stdJsonStringField(payload, "call_id") orelse continue;
        const index = call_indices.get(call_id) orelse continue;
        var record = &out.items[index];
        record.output_seen = true;
        if (timestamp) |value| {
            if (record.end_ts) |current| allocator.free(current);
            record.end_ts = try allocator.dupe(u8, value);
        }

        const output_text = stdJsonStringField(payload, "output") orelse continue;
        const markers = parseOutputMarkers(output_text);
        if (markers.saw_running) record.output_running = true;
        if (markers.saw_exited) record.output_exited = true;
        if (markers.pty_session_id) |session_id| record.pty_session_id = session_id;
        if (markers.exit_code) |exit_code| record.exit_code = exit_code;
        if (markers.wall_time_ms) |wall_time| record.wall_time_ms = wall_time;
    }
}

fn applyFunctionCallArguments(
    allocator: std.mem.Allocator,
    record: *InvocationRecord,
    arguments_text: []const u8,
) !void {
    record.arguments_text = try allocator.dupe(u8, arguments_text);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), arguments_text, .{}) catch {
        record.parse_error = true;
        return;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => {
            record.parse_error = true;
            return;
        },
    };

    if (stdJsonStringField(obj, "cmd")) |cmd_text| {
        record.command_text = try allocator.dupe(u8, cmd_text);
        record.primary_executable = try extractPrimaryExecutable(allocator, cmd_text);
    }
    if (stdJsonStringField(obj, "workdir")) |workdir| {
        record.workdir = try allocator.dupe(u8, workdir);
    }
    if (stdJsonIntField(obj, "session_id")) |session_id| {
        record.pty_session_id = session_id;
    } else if (stdJsonStringField(obj, "session_id")) |session_text| {
        if (std.fmt.parseInt(i64, session_text, 10) catch null) |session_id| {
            record.pty_session_id = session_id;
        }
    }
}

fn extractPrimaryExecutable(allocator: std.mem.Allocator, command_text: []const u8) !?[]u8 {
    var it = std.mem.tokenizeAny(u8, command_text, " \t\r\n;|&(){}");
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n\"'");
        if (token.len == 0) continue;
        if (isShellNoiseToken(token)) continue;
        if (looksLikeEnvAssignment(token)) continue;
        if (token[0] == '-') continue;
        if (token.len == 1 and std.ascii.isAlphabetic(token[0])) continue;
        if (!std.ascii.isAlphanumeric(token[0]) and token[0] != '/' and token[0] != '.') continue;
        if (isAllDigits(token)) continue;

        const basename = if (std.mem.lastIndexOfScalar(u8, token, '/')) |idx|
            if (idx + 1 < token.len) token[idx + 1 ..] else token
        else
            token;
        if (basename.len == 0) continue;
        const executable = try allocator.dupe(u8, basename);
        return executable;
    }
    return null;
}

fn isShellNoiseToken(token: []const u8) bool {
    const keywords = [_][]const u8{
        "if",
        "then",
        "else",
        "elif",
        "fi",
        "for",
        "while",
        "do",
        "done",
        "case",
        "esac",
        "in",
        "function",
        "time",
        "set",
        "export",
        "local",
        "readonly",
        "declare",
        "typeset",
        "env",
        "[",
        "]",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, token, keyword)) return true;
    }
    return false;
}

fn isAllDigits(token: []const u8) bool {
    if (token.len == 0) return false;
    for (token) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn looksLikeEnvAssignment(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '=')) |idx| {
        if (idx == 0) return false;
        if (token[0] == '-' or token[0] == '/') return false;
        return true;
    }
    return false;
}

fn parseOutputMarkers(output_text: []const u8) OutputMarkers {
    var out = OutputMarkers{};
    out.wall_time_ms = parseWallTimeMs(output_text);
    out.pty_session_id = parseSignedIntAfterPrefix(output_text, "Process running with session ID ");
    out.exit_code = parseSignedIntAfterPrefix(output_text, "Process exited with code ");
    out.saw_running = out.pty_session_id != null or std.mem.indexOf(u8, output_text, "Process running with session ID ") != null;
    out.saw_exited = out.exit_code != null or std.mem.indexOf(u8, output_text, "Process exited with code ") != null;
    return out;
}

fn parseWallTimeMs(output_text: []const u8) ?i64 {
    const prefix = "Wall time:";
    const prefix_index = std.mem.indexOf(u8, output_text, prefix) orelse return null;
    var cursor = prefix_index + prefix.len;
    while (cursor < output_text.len and std.ascii.isWhitespace(output_text[cursor])) : (cursor += 1) {}
    const suffix_rel = std.mem.indexOf(u8, output_text[cursor..], "seconds") orelse return null;
    const seconds_text = std.mem.trim(u8, output_text[cursor .. cursor + suffix_rel], " \t");
    if (seconds_text.len == 0) return null;
    const seconds = std.fmt.parseFloat(f64, seconds_text) catch return null;
    if (!std.math.isFinite(seconds) or seconds < 0) return null;
    return @intFromFloat(seconds * 1000.0);
}

fn parseSignedIntAfterPrefix(text: []const u8, prefix: []const u8) ?i64 {
    const index = std.mem.indexOf(u8, text, prefix) orelse return null;
    var cursor = index + prefix.len;
    while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
    if (cursor >= text.len) return null;

    var end = cursor;
    if (text[end] == '-' or text[end] == '+') end += 1;
    const digits_start = end;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (digits_start == end) return null;
    return std.fmt.parseInt(i64, text[cursor..end], 10) catch null;
}

fn isSeqQueryInvocation(record: InvocationRecord) bool {
    if (record.invocation_kind != .function_call) return false;
    if (record.tool_name == null or !std.mem.eql(u8, record.tool_name.?, "exec_command")) return false;
    if (record.command_text == null) return false;
    return std.mem.indexOf(u8, record.command_text.?, "seq query") != null or
        std.mem.indexOf(u8, record.command_text.?, "seq artifact-search") != null;
}

fn queryCommandClass(command_text_opt: ?[]const u8) []const u8 {
    const command_text = command_text_opt orelse return "query";
    if (std.mem.indexOf(u8, command_text, "seq artifact-search") != null) return "artifact_search";
    return "query";
}

fn extractDatasetHint(allocator: std.mem.Allocator, command_text_opt: ?[]const u8) !?[]u8 {
    const command_text = command_text_opt orelse return null;
    const patterns = [_][]const u8{
        "\"dataset\":\"",
        "\"dataset\": \"",
        "\\\"dataset\\\":\\\"",
        "\\\"dataset\\\": \\\"",
    };
    for (patterns) |pattern| {
        const index = std.mem.indexOf(u8, command_text, pattern) orelse continue;
        const start = index + pattern.len;
        var end = start;
        while (end < command_text.len) : (end += 1) {
            const ch = command_text[end];
            if (ch == '"' or ch == '\\' or ch == '\'' or std.ascii.isWhitespace(ch) or ch == ',') break;
        }
        if (end > start) {
            const dataset = try allocator.dupe(u8, command_text[start..end]);
            return dataset;
        }
    }
    return null;
}

fn queryResolutionState(record: InvocationRecord) []const u8 {
    if (record.parse_error) return "parse_error";
    return record.runningState();
}

fn buildNextAction(
    allocator: std.mem.Allocator,
    record: InvocationRecord,
    hang_flag: bool,
) !?[]u8 {
    if (!hang_flag) return null;
    const state = queryResolutionState(record);
    if (std.mem.eql(u8, state, "running_unresolved")) {
        const action = try std.fmt.allocPrint(
            allocator,
            "seq session-tooling --path {s} --summary --group-by executable --format table",
            .{record.path},
        );
        return action;
    }
    if (std.mem.eql(u8, state, "unresolved_no_output")) {
        const action = try std.fmt.allocPrint(
            allocator,
            "seq session-tooling --path {s} --summary --group-by tool --format table",
            .{record.path},
        );
        return action;
    }
    if (std.mem.eql(u8, queryCommandClass(record.command_text), "query")) {
        const action = try std.fmt.allocPrint(
            allocator,
            "seq artifact-search --contains <text> --since <iso> --limit 20 --format table",
            .{},
        );
        return action;
    }
    const action = try std.fmt.allocPrint(
        allocator,
        "seq query-diagnose --path {s} --format table",
        .{record.path},
    );
    return action;
}

fn deinitInvocationRecords(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(InvocationRecord),
) void {
    for (records.items) |*record| record.deinit(allocator);
    records.deinit(allocator);
}

fn inferSessionIdFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.endsWith(u8, base, ".jsonl")) base[0 .. base.len - ".jsonl".len] else base;
    if (stem.len >= 36) {
        const candidate = stem[stem.len - 36 ..];
        if (isUuidLike(candidate)) return candidate;
    }
    if (std.mem.lastIndexOfScalar(u8, stem, '-')) |idx| {
        if (idx + 1 < stem.len) return stem[idx + 1 ..];
    }
    return stem;
}

fn isUuidLike(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |ch, idx| {
        const is_dash = idx == 8 or idx == 13 or idx == 18 or idx == 23;
        if (is_dash) {
            if (ch != '-') return false;
            continue;
        }
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn updateMaxCounter(max_value: *?i64, occurrences: *i64, candidate: i64) void {
    if (max_value.* == null or candidate > max_value.*.?) {
        max_value.* = candidate;
        occurrences.* = 1;
        return;
    }
    if (candidate == max_value.*.?) occurrences.* += 1;
}

fn mergeMaxCounter(
    max_value: *?i64,
    occurrences: *i64,
    incoming_value: ?i64,
    incoming_occurrences: i64,
) void {
    if (incoming_value == null or incoming_occurrences == 0) return;
    if (max_value.* == null or incoming_value.? > max_value.*.?) {
        max_value.* = incoming_value;
        occurrences.* = incoming_occurrences;
        return;
    }
    if (incoming_value.? == max_value.*.?) {
        occurrences.* += incoming_occurrences;
    }
}

fn cmdFindSession(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const prompt = opts.prompt orelse return error.MissingPromptArg;
    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    try where.append(allocator, .{
        .field = "text",
        .op = .contains,
        .value = .{ .scalar = .{ .string = prompt } },
    });
    try appendSessionTimeBounds(allocator, &where, opts);
    const select = [_][]const u8{ "path", "timestamp", "role", "text" };
    const query_spec = spec.QuerySpec{
        .where = where.items,
        .select = select[0..],
        .sort = &.{.{ .field = "timestamp", .descending = true }},
        .limit = opts.limit,
    };
    try runDatasetQuery(allocator, "messages", sessions_root, query_spec, opts.format, opts.out_path, select[0..]);
}

const PlanSearchStats = struct {
    candidate_files: i64 = 0,
    files_opened: i64 = 0,
    messages_examined: i64 = 0,
    plan_blocks_found: i64 = 0,
    rows_emitted: i64 = 0,
    duration_ms: i64 = 0,
    used_repo_filter: bool = false,
    used_time_bounds: bool = false,
    used_targeted_session: bool = false,
};

fn cmdPlanSearch(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const start_ms = @divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000);
    const repo_root = try resolvePlanSearchRepoRoot(allocator, opts);
    defer if (repo_root) |value| allocator.free(value);

    if (repo_root == null and opts.path == null and opts.session_id == null) {
        printCliError("error: plan-search requires --repo, --session-id, --path, or a current cwd inside a git repo\n", .{});
        return error.MissingRepoArg;
    }

    var stats = PlanSearchStats{
        .used_repo_filter = repo_root != null,
        .used_time_bounds = opts.since != null or opts.until != null,
        .used_targeted_session = opts.path != null or opts.session_id != null,
    };

    const day_filter = deriveSessionDayPathFilterFromOptions(opts);
    var input_paths = try resolveSessionPromptInputPaths(allocator, sessions_root, opts, day_filter);
    defer freePathList(allocator, &input_paths);
    stats.candidate_files = @intCast(input_paths.items.len);

    const parse_options = datasets.messages.ParseOptions{
        .include_user = false,
        .include_assistant = true,
        .strip_echo_assistant = true,
        .skip_meta_user_messages = true,
        .dedupe_by_role_and_text = false,
        .strip_skill_blocks = false,
    };

    var rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &rows);

    for (input_paths.items) |path| {
        const content = try readFileAllocOrSkip(allocator, path);
        if (content == null) continue;
        defer allocator.free(content.?);
        stats.files_opened += 1;

        const meta = try plan_blocks.parseSessionMeta(allocator, content.?);
        defer meta.deinit(allocator);

        if (repo_root) |required_repo| {
            const cwd = meta.cwd orelse continue;
            if (!try pathMatchesRepoScope(allocator, required_repo, cwd)) continue;
        }

        const parsed = try datasets.messages.parseJsonl(allocator, path, content.?, parse_options);
        defer datasets.messages.freeRows(allocator, parsed);
        stats.messages_examined += @intCast(parsed.len);

        const session_id = inferSessionIdFromPath(path);
        for (parsed) |message_row| {
            if (!timestampSatisfiesBounds(message_row.timestamp, opts)) continue;

            const blocks = try plan_blocks.extractPlanBlocks(allocator, message_row.text);
            defer plan_blocks.deinitPlanBlocks(allocator, blocks);
            stats.plan_blocks_found += @intCast(blocks.len);

            for (blocks) |block| {
                if (!try planSearchMatchesFilters(allocator, opts, block.title, block.block)) continue;

                var qrow = query.Row.init(allocator);
                try qrow.putOwnedKey("path", .{ .string = path });
                try qrow.putOwnedKey("session_id", .{ .string = session_id });
                try putOptionalString(&qrow, "timestamp", message_row.timestamp);
                try putOptionalString(&qrow, "cwd", meta.cwd);
                try putOptionalString(&qrow, "title", block.title);
                try putOptionalString(&qrow, "iteration", block.iteration);
                try qrow.putOwnedKey("plan_index", .{ .int = @intCast(block.plan_index) });
                try qrow.putOwnedKey("plan_len", .{ .int = @intCast(block.block.len) });
                if (opts.include_body) {
                    try qrow.putOwnedKey("plan_block", .{ .string = block.block });
                }
                try rows.append(allocator, qrow);
            }
        }
    }

    const duration_delta = @divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000) - start_ms;
    stats.duration_ms = @intCast(@max(duration_delta, 0));

    const descending = try parsePlanSearchDescending(opts.sort_text);
    const sort = [_]spec.SortSpec{
        .{ .field = "timestamp", .descending = descending },
        .{ .field = "path", .descending = false },
        .{ .field = "plan_index", .descending = false },
    };
    const limit = if (opts.limit == 0) 20 else opts.limit;
    const select_base = [_][]const u8{
        "timestamp",
        "session_id",
        "cwd",
        "iteration",
        "title",
        "path",
        "plan_index",
        "plan_len",
    };
    const select_with_body = [_][]const u8{
        "timestamp",
        "session_id",
        "cwd",
        "iteration",
        "title",
        "path",
        "plan_index",
        "plan_len",
        "plan_block",
    };
    const select_with_stats = [_][]const u8{
        "timestamp",
        "session_id",
        "cwd",
        "iteration",
        "title",
        "path",
        "plan_index",
        "plan_len",
        "candidate_files",
        "files_opened",
        "messages_examined",
        "plan_blocks_found",
        "rows_emitted",
        "duration_ms",
        "used_repo_filter",
        "used_time_bounds",
        "used_targeted_session",
    };
    const select_with_body_and_stats = [_][]const u8{
        "timestamp",
        "session_id",
        "cwd",
        "iteration",
        "title",
        "path",
        "plan_index",
        "plan_len",
        "plan_block",
        "candidate_files",
        "files_opened",
        "messages_examined",
        "plan_blocks_found",
        "rows_emitted",
        "duration_ms",
        "used_repo_filter",
        "used_time_bounds",
        "used_targeted_session",
    };

    const select = if (opts.include_body and opts.stats)
        select_with_body_and_stats[0..]
    else if (opts.include_body)
        select_with_body[0..]
    else if (opts.stats)
        select_with_stats[0..]
    else
        select_base[0..];

    const query_spec = spec.QuerySpec{
        .sort = sort[0..],
        .limit = limit,
        .select = select,
    };
    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    stats.rows_emitted = @intCast(result.rows.items.len);
    if (opts.stats) {
        for (result.rows.items) |*row| try attachPlanSearchStats(row, stats);
    }

    try output.writeOutput(allocator, opts.format, result.rows.items, select, opts.out_path);
}

fn parsePlanSearchDescending(raw_opt: ?[]const u8) !bool {
    const raw = raw_opt orelse return true;
    if (std.mem.eql(u8, raw, "-timestamp")) return true;
    if (std.mem.eql(u8, raw, "timestamp")) return false;
    printCliError("error: plan-search only supports --sort timestamp or --sort -timestamp\n", .{});
    return error.InvalidSortArg;
}

fn resolvePlanSearchRepoRoot(allocator: std.mem.Allocator, opts: Options) !?[]u8 {
    if (opts.repo_text) |raw_repo| {
        const repo = try resolveExplicitRepoRoot(allocator, raw_repo);
        return repo;
    }
    if (opts.path != null or opts.session_id != null) return null;
    return resolveImplicitCurrentRepoRoot(allocator);
}

fn resolveExplicitRepoRoot(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const normalized = try normalizeRepoMatchPath(allocator, raw_path);
    if (pathHasGitMarker(normalized)) return normalized;

    var current = try allocator.dupe(u8, normalized);
    defer allocator.free(current);
    while (parentPathOrNull(current)) |parent| {
        allocator.free(current);
        current = try allocator.dupe(u8, parent);
        if (pathHasGitMarker(current)) {
            allocator.free(normalized);
            return current;
        }
    }
    return normalized;
}

fn resolveImplicitCurrentRepoRoot(allocator: std.mem.Allocator) !?[]u8 {
    var current = try normalizeRepoMatchPath(allocator, ".");
    while (true) {
        if (pathHasGitMarker(current)) return current;
        const parent = parentPathOrNull(current) orelse {
            allocator.free(current);
            return null;
        };
        allocator.free(current);
        current = try allocator.dupe(u8, parent);
    }
}

fn normalizeRepoMatchPath(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const absolute = try toAbsolutePath(allocator, raw_path);
    defer allocator.free(absolute);

    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(defaultIo(), absolute, allocator) catch null;
    if (canonical) |value| {
        defer allocator.free(value);
        return trimTrailingPathSeparatorsAlloc(allocator, value);
    }
    return trimTrailingPathSeparatorsAlloc(allocator, absolute);
}

fn trimTrailingPathSeparatorsAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var end = path.len;
    while (end > 1 and isPathSep(path[end - 1])) : (end -= 1) {}
    return allocator.dupe(u8, path[0..end]);
}

fn parentPathOrNull(path: []const u8) ?[]const u8 {
    const parent = std.fs.path.dirname(path) orelse return null;
    if (parent.len == 0 or std.mem.eql(u8, parent, path)) return null;
    return parent;
}

fn pathHasGitMarker(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var dir = std.Io.Dir.openDirAbsolute(defaultIo(), path, .{}) catch return false;
    defer dir.close(defaultIo());
    dir.access(defaultIo(), ".git", .{}) catch return false;
    return true;
}

fn pathMatchesRepoScope(allocator: std.mem.Allocator, repo_root: []const u8, candidate_path: []const u8) !bool {
    const normalized_candidate = try normalizeRepoMatchPath(allocator, candidate_path);
    defer allocator.free(normalized_candidate);
    return isPathEqualOrDescendant(repo_root, normalized_candidate);
}

fn isPathEqualOrDescendant(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    if (root.len == 1 and isPathSep(root[0])) return std.fs.path.isAbsolute(candidate);
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len <= root.len) return false;
    return isPathSep(candidate[root.len]);
}

fn planSearchMatchesFilters(
    allocator: std.mem.Allocator,
    opts: Options,
    title: ?[]const u8,
    block: []const u8,
) !bool {
    const query_text = opts.contains orelse opts.regex orelse return true;
    const score = try matchScoreForText(allocator, query_text, opts.regex != null, &.{ title orelse "", block });
    return score != null;
}

fn attachPlanSearchStats(row: *query.Row, stats: PlanSearchStats) !void {
    try row.putOwnedKey("candidate_files", .{ .int = stats.candidate_files });
    try row.putOwnedKey("files_opened", .{ .int = stats.files_opened });
    try row.putOwnedKey("messages_examined", .{ .int = stats.messages_examined });
    try row.putOwnedKey("plan_blocks_found", .{ .int = stats.plan_blocks_found });
    try row.putOwnedKey("rows_emitted", .{ .int = stats.rows_emitted });
    try row.putOwnedKey("duration_ms", .{ .int = stats.duration_ms });
    try row.putOwnedKey("used_repo_filter", .{ .bool = stats.used_repo_filter });
    try row.putOwnedKey("used_time_bounds", .{ .bool = stats.used_time_bounds });
    try row.putOwnedKey("used_targeted_session", .{ .bool = stats.used_targeted_session });
}

fn currentSessionIdFromEnv(allocator: std.mem.Allocator) ![]u8 {
    return getEnvVarOwned(allocator, "CODEX_THREAD_ID") catch {
        printCliError("error: --current requires CODEX_THREAD_ID in the environment\n", .{});
        return error.CurrentSessionUnavailable;
    };
}

fn resolveSessionPromptInputPaths(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
    day_filter: ?SessionDayPathFilter,
) !std.ArrayList([]u8) {
    const selector_count: usize =
        @intFromBool(opts.path != null) +
        @intFromBool(opts.session_id != null) +
        @intFromBool(opts.current);
    if (selector_count > 1) {
        printCliError("error: use at most one of --path, --session-id, or --current\n", .{});
        return error.InvalidSessionTarget;
    }

    if (opts.path) |single_path| {
        var out: std.ArrayList([]u8) = .empty;
        errdefer freePathList(allocator, &out);

        const absolute = try toAbsolutePath(allocator, single_path);
        const file = std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), absolute, .{}) catch {
            allocator.free(absolute);
            return error.SessionNotFound;
        };
        file.close(std.Io.Threaded.global_single_threaded.io());
        try out.append(allocator, absolute);
        return out;
    }

    const wanted_id = if (opts.current)
        try currentSessionIdFromEnv(allocator)
    else if (opts.session_id) |explicit|
        try allocator.dupe(u8, explicit)
    else
        null;
    defer if (wanted_id) |value| allocator.free(value);

    var paths = try collectJsonlPaths(allocator, sessions_root, day_filter);
    errdefer freePathList(allocator, &paths);

    if (wanted_id) |wanted| {
        var write_idx: usize = 0;
        for (paths.items) |path| {
            if (std.mem.containsAtLeast(u8, path, 1, wanted)) {
                paths.items[write_idx] = path;
                write_idx += 1;
            } else {
                allocator.free(path);
            }
        }
        paths.items.len = write_idx;
        if (paths.items.len == 0) return error.SessionNotFound;
        if (paths.items.len > 1) {
            printCliError("error: session selector matched more than one file\n", .{});
            return error.AmbiguousSessionTarget;
        }
    }

    return paths;
}

fn parseSessionPromptMessageOptions(opts: Options) !datasets.messages.ParseOptions {
    var include_user = false;
    var include_assistant = false;
    const roles_text = opts.roles_csv orelse "user";
    var split = std.mem.splitScalar(u8, roles_text, ',');
    while (split.next()) |raw_role| {
        const role = std.mem.trim(u8, raw_role, " \t\r\n");
        if (role.len == 0) continue;
        if (std.mem.eql(u8, role, "user")) {
            include_user = true;
        } else if (std.mem.eql(u8, role, "assistant")) {
            include_assistant = true;
        } else {
            printCliError("error: invalid --roles value {s}\n", .{role});
            return error.InvalidRoleArg;
        }
    }

    if (!include_user and !include_assistant) {
        printCliError("error: --roles must include user, assistant, or both\n", .{});
        return error.InvalidRoleArg;
    }

    return .{
        .include_user = include_user,
        .include_assistant = include_assistant,
        .strip_echo_assistant = true,
        .skip_meta_user_messages = true,
        .dedupe_by_role_and_text = !opts.no_dedupe_exact,
        .strip_skill_blocks = opts.strip_skill_blocks,
    };
}

const ReplyLatencyMode = enum {
    single_message,
    contiguous,

    fn parse(raw: ?[]const u8) !ReplyLatencyMode {
        const value = raw orelse return .single_message;
        if (std.mem.eql(u8, value, "single-message")) return .single_message;
        if (std.mem.eql(u8, value, "contiguous")) return .contiguous;
        printCliError("error: invalid --mode value {s}; expected single-message or contiguous\n", .{value});
        return error.InvalidModeArg;
    }

    fn cliName(self: ReplyLatencyMode) []const u8 {
        return switch (self) {
            .single_message => "single-message",
            .contiguous => "contiguous",
        };
    }
};

const ReplyLatencyPending = struct {
    start_timestamp: []const u8,
    start_epoch_ms: i64,
    user_messages: i64,
    user_text_len_total: i64,
    preview_parts: std.ArrayList([]const u8),

    fn init(
        allocator: std.mem.Allocator,
        start_timestamp: []const u8,
        start_epoch_ms: i64,
        first_text: []const u8,
        first_len: usize,
    ) !ReplyLatencyPending {
        var preview_parts: std.ArrayList([]const u8) = .empty;
        errdefer preview_parts.deinit(allocator);
        try preview_parts.append(allocator, first_text);
        return .{
            .start_timestamp = start_timestamp,
            .start_epoch_ms = start_epoch_ms,
            .user_messages = 1,
            .user_text_len_total = @intCast(first_len),
            .preview_parts = preview_parts,
        };
    }

    fn appendUser(self: *ReplyLatencyPending, allocator: std.mem.Allocator, text: []const u8, text_len: usize) !void {
        self.user_messages += 1;
        self.user_text_len_total += @intCast(text_len);
        try self.preview_parts.append(allocator, text);
    }

    fn deinit(self: *ReplyLatencyPending, allocator: std.mem.Allocator) void {
        self.preview_parts.deinit(allocator);
    }
};

fn collectSessionPromptRows(
    allocator: std.mem.Allocator,
    input_paths: []const []u8,
    parse_options: datasets.messages.ParseOptions,
) !std.ArrayList(query.Row) {
    var rows: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &rows);

    for (input_paths) |path| {
        const content = try readFileAllocOrSkip(allocator, path);
        if (content == null) continue;
        defer allocator.free(content.?);

        const parsed = try datasets.messages.parseJsonl(allocator, path, content.?, parse_options);
        defer datasets.messages.freeRows(allocator, parsed);

        for (parsed) |row| {
            var qrow = query.Row.init(allocator);
            try putOptionalString(&qrow, "timestamp", row.timestamp);
            try qrow.putOwnedKey("path", .{ .string = row.path });
            try qrow.putOwnedKey("role", .{ .string = row.role });
            try qrow.putOwnedKey("text", .{ .string = row.text });
            try rows.append(allocator, qrow);
        }
    }

    return rows;
}

fn cmdSessionPrompts(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const parse_options = try parseSessionPromptMessageOptions(opts);
    const day_filter = deriveSessionDayPathFilterFromOptions(opts);
    var input_paths = try resolveSessionPromptInputPaths(allocator, sessions_root, opts, day_filter);
    defer freePathList(allocator, &input_paths);

    var rows = try collectSessionPromptRows(allocator, input_paths.items, parse_options);
    defer deinitQueryRows(allocator, &rows);

    const select = [_][]const u8{ "timestamp", "path", "role", "text" };
    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    try appendSessionTimeBounds(allocator, &where, opts);
    const query_spec = spec.QuerySpec{
        .where = where.items,
        .select = select[0..],
        .sort = &.{.{ .field = "timestamp", .descending = false }},
        .limit = opts.limit,
    };
    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    try output.writeOutput(allocator, opts.format, result.rows.items, select[0..], opts.out_path);
}

fn cmdReplyLatency(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const mode = try ReplyLatencyMode.parse(opts.mode);
    const parse_options = datasets.messages.ParseOptions{
        .include_user = true,
        .include_assistant = true,
        .strip_echo_assistant = true,
        .skip_meta_user_messages = true,
        .dedupe_by_role_and_text = false,
        .strip_skill_blocks = false,
    };

    // Do not day-filter by session path: long-lived sessions can produce reply spans days after the file's path date.
    var input_paths = try resolveSessionPromptInputPaths(allocator, sessions_root, opts, null);
    defer freePathList(allocator, &input_paths);

    var rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &rows);

    for (input_paths.items) |path| {
        const content = try readFileAllocOrSkip(allocator, path);
        if (content == null) continue;
        defer allocator.free(content.?);

        const parsed = try datasets.messages.parseJsonl(allocator, path, content.?, parse_options);
        defer datasets.messages.freeRows(allocator, parsed);

        try appendReplyLatencyRowsForSession(allocator, path, parsed, mode, opts, &rows);
    }

    const columns = [_][]const u8{
        "path",
        "session_id",
        "turn_index",
        "start_timestamp",
        "end_timestamp",
        "duration_seconds",
        "duration_human",
        "mode",
        "user_messages",
        "user_text_len_total",
        "user_preview",
        "assistant_preview",
    };
    const sort = [_]spec.SortSpec{
        .{ .field = "duration_seconds", .descending = true },
        .{ .field = "start_timestamp", .descending = true },
        .{ .field = "path", .descending = false },
        .{ .field = "turn_index", .descending = false },
    };
    const query_spec = spec.QuerySpec{
        .select = columns[0..],
        .sort = sort[0..],
        .limit = if (opts.limit == 0) 10 else opts.limit,
    };
    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    try output.writeOutput(allocator, opts.format, result.rows.items, columns[0..], opts.out_path);
}

fn appendReplyLatencyRowsForSession(
    allocator: std.mem.Allocator,
    path: []const u8,
    parsed: []const datasets.messages.MessageRow,
    mode: ReplyLatencyMode,
    opts: Options,
    out_rows: *std.ArrayList(query.Row),
) !void {
    const session_id = inferSessionIdFromPath(path);
    var turn_index: i64 = 0;
    var pending: ?ReplyLatencyPending = null;
    var previous_role: ?[]const u8 = null;
    var previous_text: ?[]const u8 = null;
    var previous_epoch_ms: ?i64 = null;
    defer if (pending) |*value| value.deinit(allocator);

    for (parsed) |row| {
        const row_epoch_ms = if (row.timestamp) |timestamp| parseIsoTimestampMillis(timestamp) else null;
        if (isAdjacentMirroredDuplicate(previous_role, previous_text, previous_epoch_ms, row.role, row.text, row_epoch_ms)) {
            continue;
        }
        previous_role = row.role;
        previous_text = row.text;
        previous_epoch_ms = row_epoch_ms;

        if (std.mem.eql(u8, row.role, "user")) {
            const start_timestamp = row.timestamp orelse {
                if (pending) |*value| {
                    value.deinit(allocator);
                    pending = null;
                }
                continue;
            };
            const start_epoch_ms = row_epoch_ms orelse {
                if (pending) |*value| {
                    value.deinit(allocator);
                    pending = null;
                }
                continue;
            };

            if (pending) |*value| {
                try value.appendUser(allocator, row.text, row.text_len);
            } else {
                pending = try ReplyLatencyPending.init(
                    allocator,
                    start_timestamp,
                    start_epoch_ms,
                    row.text,
                    row.text_len,
                );
            }
            continue;
        }

        if (!std.mem.eql(u8, row.role, "assistant")) continue;
        if (pending == null) continue;

        const end_timestamp = row.timestamp orelse {
            pending.?.deinit(allocator);
            pending = null;
            continue;
        };
        const end_epoch_ms = row_epoch_ms orelse {
            pending.?.deinit(allocator);
            pending = null;
            continue;
        };

        const should_emit = switch (mode) {
            .single_message => pending.?.user_messages == 1,
            .contiguous => true,
        };
        if (should_emit) {
            turn_index += 1;
            if (timestampSatisfiesBounds(pending.?.start_timestamp, opts)) {
                try appendReplyLatencyRow(
                    allocator,
                    out_rows,
                    path,
                    session_id,
                    turn_index,
                    pending.?,
                    end_timestamp,
                    end_epoch_ms,
                    row.text,
                    mode,
                );
            }
        }

        pending.?.deinit(allocator);
        pending = null;
    }
}

fn isAdjacentMirroredDuplicate(
    previous_role: ?[]const u8,
    previous_text: ?[]const u8,
    previous_epoch_ms: ?i64,
    role: []const u8,
    text: []const u8,
    epoch_ms: ?i64,
) bool {
    const last_role = previous_role orelse return false;
    const last_text = previous_text orelse return false;
    if (!std.mem.eql(u8, last_role, role)) return false;
    if (!std.mem.eql(u8, last_text, text)) return false;

    if (previous_epoch_ms == null and epoch_ms == null) return true;
    if (previous_epoch_ms) |last_ms| {
        if (epoch_ms) |current_ms| {
            const diff = current_ms - last_ms;
            return diff >= -1 and diff <= 1;
        }
    }
    return false;
}

fn appendReplyLatencyRow(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    path: []const u8,
    session_id: []const u8,
    turn_index: i64,
    pending: ReplyLatencyPending,
    end_timestamp: []const u8,
    end_epoch_ms: i64,
    assistant_text: []const u8,
    mode: ReplyLatencyMode,
) !void {
    const duration_ms = end_epoch_ms - pending.start_epoch_ms;
    if (duration_ms < 0) return;

    const user_preview = try buildJoinedPreviewAlloc(allocator, pending.preview_parts.items, 160);
    defer allocator.free(user_preview);
    const assistant_preview = try buildCollapsedPreviewAlloc(allocator, assistant_text, 120);
    defer allocator.free(assistant_preview);
    const duration_human = try formatDurationHumanAlloc(allocator, duration_ms);
    defer allocator.free(duration_human);

    var row = query.Row.init(allocator);
    errdefer row.deinit();

    try row.putOwnedKey("path", .{ .string = path });
    try row.putOwnedKey("session_id", .{ .string = session_id });
    try row.putOwnedKey("turn_index", .{ .int = turn_index });
    try row.putOwnedKey("start_timestamp", .{ .string = pending.start_timestamp });
    try row.putOwnedKey("end_timestamp", .{ .string = end_timestamp });
    try row.putOwnedKey("duration_seconds", .{ .float = @as(f64, @floatFromInt(duration_ms)) / 1000.0 });
    try row.putOwnedKey("duration_human", .{ .string = duration_human });
    try row.putOwnedKey("mode", .{ .string = mode.cliName() });
    try row.putOwnedKey("user_messages", .{ .int = pending.user_messages });
    try row.putOwnedKey("user_text_len_total", .{ .int = pending.user_text_len_total });
    try row.putOwnedKey("user_preview", .{ .string = user_preview });
    try row.putOwnedKey("assistant_preview", .{ .string = assistant_preview });
    try out_rows.append(allocator, row);
}

fn cmdReportBundle(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    try appendSessionTimeBounds(allocator, &where, opts);
    const query_spec = spec.QuerySpec{
        .where = where.items,
        .group_by = &.{"skill"},
        .metrics = &.{
            .{ .op = .count, .alias = "mentions" },
            .{ .op = .count_distinct, .field = "path", .alias = "sessions" },
        },
        .sort = &.{.{ .field = "mentions", .descending = true }},
        .limit = if (opts.limit == 0) 20 else opts.limit,
    };
    try runDatasetQuery(allocator, "skill_mentions", sessions_root, query_spec, opts.format, opts.out_path, null);
}

fn cmdSectionAudit(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    try appendSessionTimeBounds(allocator, &where, opts);
    var rows = try collectDatasetRows(allocator, "messages", sessions_root, &.{}, where.items);
    defer deinitQueryRows(allocator, &rows);

    const select = [_][]const u8{ "role", "text" };
    const identity_spec = spec.QuerySpec{ .where = where.items, .select = select[0..] };
    var result = try query.execute(allocator, rows.items, identity_spec);
    defer result.deinit(allocator);

    const sections_text = opts.sections orelse return error.MissingSectionsArg;
    var section_split = std.mem.splitScalar(u8, sections_text, ',');

    var out_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &out_rows);

    while (section_split.next()) |raw_section| {
        const section = std.mem.trim(u8, raw_section, " \t\r\n");
        if (section.len == 0) continue;

        var hits: i64 = 0;
        for (result.rows.items) |row| {
            const text = row.valueOrNull("text");
            if (text == .string and std.mem.indexOf(u8, text.string, section) != null) {
                hits += 1;
            }
        }

        var out = query.Row.init(allocator);
        try out.putOwnedKey("section", .{ .string = section });
        try out.putOwnedKey("matches", .{ .int = hits });
        try out_rows.append(allocator, out);
    }

    const cols = [_][]const u8{ "section", "matches" };
    try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
}

const TokenUsageGroupBy = enum {
    day,
    path,

    fn parse(raw_opt: ?[]const u8) !TokenUsageGroupBy {
        const raw = raw_opt orelse return .day;
        if (std.mem.eql(u8, raw, "day")) return .day;
        if (std.mem.eql(u8, raw, "path")) return .path;
        printCliError("error: token-usage --group-by must be day or path\n", .{});
        return error.InvalidGroupByArg;
    }

    fn fieldName(self: TokenUsageGroupBy) []const u8 {
        return switch (self) {
            .day => "day",
            .path => "path",
        };
    }
};

const TokenUsageBucket = struct {
    key: []u8,
    total_tokens: i64 = 0,
    input_tokens: i64 = 0,
    cached_input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    reasoning_output_tokens: i64 = 0,
    rows: i64 = 0,
};

const TokenUsageAudit = struct {
    files_scanned: i64 = 0,
    raw_token_count_events: i64 = 0,
    raw_token_count_info_null_events: i64 = 0,
    raw_token_count_without_total_events: i64 = 0,
    duplicate_total_events: i64 = 0,
    duplicate_total_nonzero_last_events: i64 = 0,
    duplicate_last_tokens_excluded: i64 = 0,
    reset_events: i64 = 0,
    naive_last_total_tokens: i64 = 0,

    fn observeEvents(self: *TokenUsageAudit, events: []const datasets.token_events.Row, since_ms: ?i64, until_ms: ?i64, timezone: time_utils.TimeZone) void {
        var prev_total_tokens: ?i64 = null;
        for (events) |event| {
            const ts_ms = tokenUsageEventTimestampMillis(event) orelse continue;
            if (!timestampMillisSatisfiesBounds(ts_ms, since_ms, until_ms, timezone)) continue;

            if (event.info_is_null) {
                self.raw_token_count_info_null_events += 1;
                continue;
            }

            self.raw_token_count_events += 1;
            if (event.last_total_tokens) |last| self.naive_last_total_tokens += last;

            const total = event.total_total_tokens orelse {
                self.raw_token_count_without_total_events += 1;
                continue;
            };

            if (prev_total_tokens) |prev| {
                if (total == prev) {
                    self.duplicate_total_events += 1;
                    if ((event.last_total_tokens orelse 0) != 0) {
                        self.duplicate_total_nonzero_last_events += 1;
                        self.duplicate_last_tokens_excluded += event.last_total_tokens.?;
                    }
                } else if (total < prev) {
                    self.reset_events += 1;
                }
            }
            prev_total_tokens = total;
        }
    }
};

fn cmdTokenUsage(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const group_by = try TokenUsageGroupBy.parse(opts.group_by_text);
    const timezone = try time_utils.parseTimeZone(opts.timezone_text);
    const timezone_label = try time_utils.timeZoneLabelAlloc(allocator, timezone);
    defer allocator.free(timezone_label);

    const window = try resolveTokenCommandWindow(opts);

    const day_filter = deriveSessionDayPathFilterFromWindow(window);
    var paths = try resolveSessionPromptInputPaths(allocator, sessions_root, opts, day_filter);
    defer freePathList(allocator, &paths);

    var buckets: std.ArrayList(TokenUsageBucket) = .empty;
    var bucket_index: std.StringHashMap(usize) = .init(allocator);
    defer deinitTokenUsageBuckets(allocator, &buckets, &bucket_index);
    var daily_buckets: std.ArrayList(TokenUsageBucket) = .empty;
    var daily_bucket_index: std.StringHashMap(usize) = .init(allocator);
    defer deinitTokenUsageBuckets(allocator, &daily_buckets, &daily_bucket_index);

    var included_paths: std.StringHashMap(void) = .init(allocator);
    defer deinitStringSet(allocator, &included_paths);

    var audit = TokenUsageAudit{ .files_scanned = @intCast(paths.items.len) };
    var total_tokens: i64 = 0;
    var input_tokens: i64 = 0;
    var cached_input_tokens: i64 = 0;
    var output_tokens: i64 = 0;
    var reasoning_output_tokens: i64 = 0;
    var total_rows: i64 = 0;
    var min_day_buf: [10]u8 = undefined;
    var max_day_buf: [10]u8 = undefined;
    var have_day_bounds = false;

    for (paths.items) |path| {
        var events = try datasets.token_events.parseTokenEventsFileWithOptions(allocator, path, .{
            .dedupe = !opts.audit,
            .derive_timestamp_fields = true,
            .include_null_info = opts.audit,
        });
        defer events.deinit(allocator);
        if (opts.audit) audit.observeEvents(events.items, window.since_ms, window.until_ms, timezone);
        var deltas = try datasets.token_deltas.buildDeltas(allocator, events.items, .{});
        defer deltas.deinit(allocator);

        for (deltas.items) |row| {
            const ts_text = row.timestamp orelse continue;
            const ts_ms = time_utils.parseIsoTimestampMillis(ts_text.slice()) orelse continue;
            if (!timestampMillisSatisfiesBounds(ts_ms, window.since_ms, window.until_ms, timezone)) continue;

            const delta_total = row.delta_total_tokens orelse continue;
            const delta_input = row.delta_input_tokens orelse 0;
            const delta_cached_input = row.delta_cached_input_tokens orelse 0;
            const delta_output = row.delta_output_tokens orelse 0;
            const delta_reasoning_output = row.delta_reasoning_output_tokens orelse 0;

            var day_buf: [10]u8 = undefined;
            const local_day = tokenUsageDayKeyFromMillis(ts_ms, timezone, &day_buf) orelse continue;
            if (!have_day_bounds) {
                @memcpy(min_day_buf[0..], local_day);
                @memcpy(max_day_buf[0..], local_day);
                have_day_bounds = true;
            } else {
                if (std.mem.order(u8, local_day, min_day_buf[0..]) == .lt) @memcpy(min_day_buf[0..], local_day);
                if (std.mem.order(u8, local_day, max_day_buf[0..]) == .gt) @memcpy(max_day_buf[0..], local_day);
            }

            try addTokenUsageBucket(allocator, &daily_bucket_index, &daily_buckets, local_day, row);
            const bucket_key = switch (group_by) {
                .day => local_day,
                .path => path,
            };
            try addTokenUsageBucket(allocator, &bucket_index, &buckets, bucket_key, row);
            try addToStringSet(allocator, &included_paths, path);
            total_tokens += delta_total;
            input_tokens += delta_input;
            cached_input_tokens += delta_cached_input;
            output_tokens += delta_output;
            reasoning_output_tokens += delta_reasoning_output;
            total_rows += 1;
        }
    }

    switch (group_by) {
        .day => std.mem.sort(TokenUsageBucket, buckets.items, {}, tokenUsageBucketLessDayAsc),
        .path => std.mem.sort(TokenUsageBucket, buckets.items, {}, tokenUsageBucketLessTotalDesc),
    }
    std.mem.sort(TokenUsageBucket, daily_buckets.items, {}, tokenUsageBucketLessDayAsc);

    var out_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &out_rows);

    if (opts.summary) {
        try appendTokenUsageSummaryRow(
            allocator,
            &out_rows,
            opts,
            sessions_root,
            group_by,
            timezone_label,
            total_tokens,
            input_tokens,
            cached_input_tokens,
            output_tokens,
            reasoning_output_tokens,
            total_rows,
            included_paths.count(),
            daily_buckets.items,
            have_day_bounds,
            if (have_day_bounds) min_day_buf[0..] else null,
            if (have_day_bounds) max_day_buf[0..] else null,
            window.since_ms,
            window.until_ms,
            timezone,
            if (opts.audit) audit else null,
        );
        const summary_cols = [_][]const u8{
            "scope_kind",
            "scope_target",
            "group_by",
            "tz",
            "total_tokens",
            "input_tokens",
            "cached_input_tokens",
            "uncached_input_tokens",
            "output_tokens",
            "reasoning_output_tokens",
            "calendar_days",
            "active_days",
            "average_tokens_per_calendar_day",
            "average_tokens_per_active_day",
            "median_tokens_per_active_day",
            "first_day",
            "last_day",
            "partial_current_day",
            "path_count",
            "rows",
        };
        const summary_audit_cols = [_][]const u8{
            "row_kind",
            "scope_kind",
            "scope_target",
            "group_by",
            "tz",
            "total_tokens",
            "input_tokens",
            "cached_input_tokens",
            "uncached_input_tokens",
            "output_tokens",
            "reasoning_output_tokens",
            "calendar_days",
            "active_days",
            "average_tokens_per_calendar_day",
            "average_tokens_per_active_day",
            "median_tokens_per_active_day",
            "first_day",
            "last_day",
            "partial_current_day",
            "path_count",
            "rows",
            "audit_version",
            "audit_method",
            "files_scanned",
            "files_with_counted_tokens",
            "raw_token_count_events",
            "raw_token_count_info_null_events",
            "raw_token_count_without_total_events",
            "counted_delta_rows",
            "duplicate_total_events",
            "duplicate_total_nonzero_last_events",
            "duplicate_last_tokens_excluded",
            "reset_events",
            "audit_total_tokens",
            "naive_last_total_tokens",
            "naive_overcount_tokens",
            "requested_span_days",
            "observed_span_days",
            "bucket_days",
        };
        const cols = if (opts.audit) summary_audit_cols[0..] else summary_cols[0..];
        try output.writeOutput(allocator, opts.format, out_rows.items, cols, opts.out_path);
        return;
    }

    for (buckets.items) |bucket| {
        var qrow = query.Row.init(allocator);
        if (opts.audit) try qrow.putOwnedKey("row_kind", .{ .string = "bucket" });
        try qrow.putOwnedKey(group_by.fieldName(), .{ .string = bucket.key });
        try qrow.putOwnedKey("total_tokens", .{ .int = bucket.total_tokens });
        try qrow.putOwnedKey("rows", .{ .int = bucket.rows });
        if (group_by == .path or opts.timezone_text != null) {
            try qrow.putOwnedKey("tz", .{ .string = timezone_label });
            try qrow.putOwnedKey("scope_kind", .{ .string = tokenUsageScopeKind(opts, group_by) });
        }
        try out_rows.append(allocator, qrow);
    }

    trimQueryRows(&out_rows, opts.limit);
    if (opts.audit) {
        try appendTokenUsageAuditRow(
            allocator,
            &out_rows,
            group_by,
            timezone_label,
            total_tokens,
            input_tokens,
            cached_input_tokens,
            output_tokens,
            reasoning_output_tokens,
            total_rows,
            included_paths.count(),
            daily_buckets.items,
            if (have_day_bounds) min_day_buf[0..] else null,
            if (have_day_bounds) max_day_buf[0..] else null,
            window.since_ms,
            window.until_ms,
            timezone,
            audit,
        );
    }
    const day_cols_extended = [_][]const u8{ "day", "total_tokens", "rows", "tz", "scope_kind" };
    const day_cols_legacy = [_][]const u8{ "day", "rows", "total_tokens" };
    const path_cols = [_][]const u8{ "path", "total_tokens", "rows", "tz", "scope_kind" };
    const day_audit_cols = [_][]const u8{
        "row_kind",
        "day",
        "total_tokens",
        "rows",
        "tz",
        "scope_kind",
        "audit_version",
        "audit_method",
        "files_scanned",
        "files_with_counted_tokens",
        "raw_token_count_events",
        "raw_token_count_info_null_events",
        "raw_token_count_without_total_events",
        "counted_delta_rows",
        "duplicate_total_events",
        "duplicate_total_nonzero_last_events",
        "duplicate_last_tokens_excluded",
        "reset_events",
        "audit_total_tokens",
        "naive_last_total_tokens",
        "naive_overcount_tokens",
        "requested_span_days",
        "observed_span_days",
        "bucket_days",
    };
    const path_audit_cols = [_][]const u8{
        "row_kind",
        "path",
        "total_tokens",
        "rows",
        "tz",
        "scope_kind",
        "audit_version",
        "audit_method",
        "files_scanned",
        "files_with_counted_tokens",
        "raw_token_count_events",
        "raw_token_count_info_null_events",
        "raw_token_count_without_total_events",
        "counted_delta_rows",
        "duplicate_total_events",
        "duplicate_total_nonzero_last_events",
        "duplicate_last_tokens_excluded",
        "reset_events",
        "audit_total_tokens",
        "naive_last_total_tokens",
        "naive_overcount_tokens",
        "requested_span_days",
        "observed_span_days",
        "bucket_days",
    };
    const cols: []const []const u8 = if (opts.audit) switch (group_by) {
        .day => day_audit_cols[0..],
        .path => path_audit_cols[0..],
    } else switch (group_by) {
        .day => if (opts.timezone_text != null) day_cols_extended[0..] else day_cols_legacy[0..],
        .path => path_cols[0..],
    };
    try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
}

const TokenCostGroupBy = enum {
    day,
    path,
    model,
    fast_mode,

    fn parse(raw_opt: ?[]const u8) !TokenCostGroupBy {
        const raw = raw_opt orelse return .day;
        if (std.mem.eql(u8, raw, "day")) return .day;
        if (std.mem.eql(u8, raw, "path")) return .path;
        if (std.mem.eql(u8, raw, "model")) return .model;
        if (std.mem.eql(u8, raw, "fast_mode")) return .fast_mode;
        printCliError("error: token-cost --group-by must be day, path, model, or fast_mode\n", .{});
        return error.InvalidGroupByArg;
    }

    fn fieldName(self: TokenCostGroupBy) []const u8 {
        return switch (self) {
            .day => "day",
            .path => "path",
            .model => "model",
            .fast_mode => "fast_mode",
        };
    }
};

const TokenCostPricingKind = enum {
    codex,
    api,

    fn parse(raw_opt: ?[]const u8) !TokenCostPricingKind {
        const raw = raw_opt orelse return .codex;
        if (std.ascii.eqlIgnoreCase(raw, "codex")) return .codex;
        if (std.ascii.eqlIgnoreCase(raw, "api")) return .api;
        printCliError("error: token-cost --pricing must be codex or api\n", .{});
        return error.InvalidModeArg;
    }

    fn label(self: TokenCostPricingKind) []const u8 {
        return switch (self) {
            .codex => "codex",
            .api => "api",
        };
    }
};

const TokenCostBucket = struct {
    key: []u8,
    rows: i64 = 0,
    priced_rows: i64 = 0,
    unpriced_rows: i64 = 0,
    input_tokens: i64 = 0,
    cached_input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    reasoning_output_tokens: i64 = 0,
    total_tokens: i64 = 0,
    credits: f64 = 0,
    api_usd: f64 = 0,
    api_input_usd: f64 = 0,
    api_cached_input_usd: f64 = 0,
    api_output_usd: f64 = 0,
    api_long_context_surcharge_usd: f64 = 0,
    long_context_priced_rows: i64 = 0,
    unpriced_tokens: i64 = 0,
    priced_fast_credits: f64 = 0,
    priced_standard_credits: f64 = 0,
    priced_standard_assumption_credits: f64 = 0,
    fast_mode_label: []const u8 = "",
    fast_mode_source: []const u8 = "",
    model_source: []const u8 = "",
    cost_confidence: []const u8 = "",
};

const TokenCostTraceMeta = struct {
    model: ?[]u8 = null,
    fast_mode: token_cost.FastMode = .unknown,

    fn deinit(self: TokenCostTraceMeta, allocator: std.mem.Allocator) void {
        if (self.model) |value| allocator.free(value);
    }
};

fn cmdTokenCost(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const group_by = try TokenCostGroupBy.parse(opts.group_by_text);
    const pricing_kind = try TokenCostPricingKind.parse(opts.pricing_text);
    const timezone = try time_utils.parseTimeZone(opts.timezone_text);
    const timezone_label = try time_utils.timeZoneLabelAlloc(allocator, timezone);
    defer allocator.free(timezone_label);
    const window = try resolveTokenCommandWindow(opts);
    const usd_per_credit = if (pricing_kind == .codex) try parseUsdPerCredit(opts.usd_per_credit_text) else blk: {
        if (opts.usd_per_credit_text != null) {
            printCliError("error: --usd-per-credit is only valid with --pricing codex\n", .{});
            return error.InvalidModeArg;
        }
        break :blk null;
    };
    const pricing = if (pricing_kind == .codex) try loadTokenCostPricing(allocator, opts) else token_cost.bundledPricing();
    defer token_cost.deinitPricing(allocator, pricing);
    const api_pricing = if (pricing_kind == .api) try loadTokenCostApiPricing(allocator, opts) else token_cost.bundledApiPricing();
    defer token_cost.deinitApiPricing(allocator, api_pricing);

    const day_filter = deriveSessionDayPathFilterFromWindow(window);
    var paths = try resolveSessionPromptInputPaths(allocator, sessions_root, opts, day_filter);
    defer freePathList(allocator, &paths);

    var buckets: std.ArrayList(TokenCostBucket) = .empty;
    var bucket_index: std.StringHashMap(usize) = .init(allocator);
    defer deinitTokenCostBuckets(allocator, &buckets, &bucket_index);

    var total = TokenCostBucket{ .key = undefined };

    for (paths.items) |path| {
        const meta = try loadTokenCostTraceMeta(allocator, path, opts);
        defer meta.deinit(allocator);
        const model_name = opts.model_text orelse meta.model;
        const model_source: []const u8 = if (opts.model_text != null) "override" else if (meta.model != null) "trace" else "missing";
        var events = try datasets.token_events.parseTokenEventsFileWithOptions(allocator, path, .{
            .dedupe = !opts.audit,
            .derive_timestamp_fields = true,
            .include_null_info = opts.audit,
        });
        defer events.deinit(allocator);
        var deltas = try datasets.token_deltas.buildDeltas(allocator, events.items, .{});
        defer deltas.deinit(allocator);

        for (deltas.items) |row| {
            const ts_text = row.timestamp orelse continue;
            const ts_ms = time_utils.parseIsoTimestampMillis(ts_text.slice()) orelse continue;
            if (!timestampMillisSatisfiesBounds(ts_ms, window.since_ms, window.until_ms, timezone)) continue;

            var day_buf: [10]u8 = undefined;
            const local_day = tokenUsageDayKeyFromMillis(ts_ms, timezone, &day_buf) orelse continue;
            const usage = token_cost.Usage{
                .input_tokens = row.delta_input_tokens orelse 0,
                .cached_input_tokens = row.delta_cached_input_tokens orelse 0,
                .output_tokens = row.delta_output_tokens orelse 0,
            };
            const long_context = if (pricing_kind == .api and model_name != null)
                if (token_cost.findApiRate(api_pricing, model_name.?)) |rate|
                    token_cost.apiModelHasLongContext(rate, usage.input_tokens)
                else
                    false
            else
                false;
            const estimate = switch (pricing_kind) {
                .codex => token_cost.estimate(pricing, model_name, usage, meta.fast_mode),
                .api => token_cost.estimateApi(api_pricing, model_name, usage, long_context),
            };

            const key = switch (group_by) {
                .day => local_day,
                .path => path,
                .model => model_name orelse "unknown",
                .fast_mode => meta.fast_mode.label(),
            };
            try addTokenCostBucket(allocator, &bucket_index, &buckets, key, row, estimate, meta.fast_mode, model_source);
            addTokenCostTotals(&total, row, estimate, meta.fast_mode, model_source);
        }
    }

    if (pricing_kind == .api and total.unpriced_rows > 0) {
        printCliError("error: token-cost --pricing api requires an exact known API model; pass --model <name>. Bundled supported models: gpt-5.5, gpt-5.4, gpt-5.4-mini\n", .{});
        return error.ApiPricingModelRequired;
    }

    switch (group_by) {
        .day => std.mem.sort(TokenCostBucket, buckets.items, {}, tokenCostBucketLessKeyAsc),
        .path, .model, .fast_mode => std.mem.sort(TokenCostBucket, buckets.items, {}, tokenCostBucketLessCreditsDesc),
    }

    var out_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &out_rows);

    if (opts.summary) {
        var qrow = query.Row.init(allocator);
        try putTokenCostCommonFields(allocator, &qrow, total, usd_per_credit, pricing, api_pricing, pricing_kind, opts, group_by, timezone_label);
        try qrow.putOwnedKey("row_kind", .{ .string = "summary" });
        try qrow.putOwnedKey("scope_kind", .{ .string = tokenCostScopeKind(opts, group_by) });
        try qrow.putOwnedKey("scope_target", .{ .string = tokenUsageScopeTarget(opts, sessions_root) });
        try out_rows.append(allocator, qrow);
        const cols = [_][]const u8{
            "row_kind",
            "scope_kind",
            "scope_target",
            "group_by",
            "tz",
            "credits_estimate",
            "usd_estimate",
            "api_input_usd",
            "api_cached_input_usd",
            "api_output_usd",
            "api_long_context_surcharge_usd",
            "long_context_priced_rows",
            "rows",
            "priced_rows",
            "unpriced_rows",
            "input_tokens",
            "cached_input_tokens",
            "output_tokens",
            "reasoning_output_tokens",
            "total_tokens",
            "fast_mode",
            "fast_mode_source",
            "model_source",
            "cost_confidence",
            "priced_fast_credits",
            "priced_standard_credits",
            "priced_standard_assumption_credits",
            "unpriced_tokens",
            "pricing_source_url",
            "pricing_fetched_at",
            "pricing_kind",
            "reasoning_effort",
            "usd_per_credit",
        };
        try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
        return;
    }

    for (buckets.items) |bucket| {
        var qrow = query.Row.init(allocator);
        try qrow.putOwnedKey(group_by.fieldName(), .{ .string = bucket.key });
        try putTokenCostCommonFields(allocator, &qrow, bucket, usd_per_credit, pricing, api_pricing, pricing_kind, opts, group_by, timezone_label);
        try out_rows.append(allocator, qrow);
    }
    trimQueryRows(&out_rows, opts.limit);
    const cols = [_][]const u8{
        group_by.fieldName(),
        "credits_estimate",
        "usd_estimate",
        "api_input_usd",
        "api_cached_input_usd",
        "api_output_usd",
        "api_long_context_surcharge_usd",
        "long_context_priced_rows",
        "rows",
        "priced_rows",
        "unpriced_rows",
        "input_tokens",
        "cached_input_tokens",
        "output_tokens",
        "reasoning_output_tokens",
        "total_tokens",
        "fast_mode",
        "fast_mode_source",
        "model_source",
        "cost_confidence",
        "unpriced_tokens",
        "pricing_source_url",
        "pricing_fetched_at",
        "pricing_kind",
        "reasoning_effort",
        "usd_per_credit",
        "group_by",
        "tz",
    };
    try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
}

fn parseUsdPerCredit(raw_opt: ?[]const u8) !?f64 {
    const raw = raw_opt orelse return null;
    const value = try std.fmt.parseFloat(f64, raw);
    if (value <= 0) return error.InvalidLimit;
    return value;
}

const TokenCommandWindow = struct {
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
    last_ms: ?i64 = null,
};

fn resolveTokenCommandWindow(opts: Options) !TokenCommandWindow {
    const until_ms = try parseTokenUsageBoundMillis(opts.until, "--until");
    if (opts.last_text) |raw| {
        const duration_ms = try parseLastWindowMillis(raw);
        const anchor_ms = until_ms orelse currentUnixMillis();
        return .{
            .since_ms = anchor_ms - duration_ms,
            .until_ms = anchor_ms,
            .last_ms = duration_ms,
        };
    }
    return .{
        .since_ms = try parseTokenUsageBoundMillis(opts.since, "--since"),
        .until_ms = until_ms,
    };
}

fn parseLastWindowMillis(raw: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len < 2) {
        printCliError("error: --last must be a positive duration like 24h, 90m, or 7d\n", .{});
        return error.InvalidLimit;
    }
    const unit = trimmed[trimmed.len - 1];
    const number_text = trimmed[0 .. trimmed.len - 1];
    if (number_text.len == 0) return error.InvalidLimit;
    const value = try std.fmt.parseInt(i64, number_text, 10);
    if (value < 1) return error.InvalidLimit;
    const multiplier: i64 = switch (unit) {
        'm' => 60_000,
        'h' => 3_600_000,
        'd' => 86_400_000,
        else => {
            printCliError("error: --last duration unit must be m, h, or d\n", .{});
            return error.InvalidLimit;
        },
    };
    return std.math.mul(i64, value, multiplier) catch error.InvalidLimit;
}

fn currentUnixMillis() i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000));
}

fn loadTokenCostPricing(allocator: std.mem.Allocator, opts: Options) !token_cost.Pricing {
    if (opts.pricing_file) |path| return token_cost.loadPricingFile(allocator, path);
    if (opts.refresh_pricing) {
        if (opts.offline) return error.InvalidModeArg;
        return refreshTokenCostPricing(allocator);
    }
    return token_cost.bundledPricing();
}

fn loadTokenCostApiPricing(allocator: std.mem.Allocator, opts: Options) !token_cost.ApiPricing {
    if (opts.pricing_file) |path| return token_cost.loadApiPricingFile(allocator, path);
    if (opts.refresh_pricing) {
        if (opts.offline) return error.InvalidModeArg;
        return refreshTokenCostApiPricing(allocator);
    }
    return token_cost.bundledApiPricing();
}

fn refreshTokenCostApiPricing(allocator: std.mem.Allocator) !token_cost.ApiPricing {
    const capture_allocator = std.heap.page_allocator;
    var client = std.http.Client{ .allocator = capture_allocator, .io = defaultIo() };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(capture_allocator);
    defer body.deinit();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    const result = try client.fetch(.{
        .location = .{ .url = token_cost.OfficialApiPricingUrl },
        .response_writer = &body.writer,
        .redirect_buffer = redirect_buffer[0..],
    });
    if (result.status != .ok) {
        return error.PricingRefreshFailed;
    }
    const pricing_text = try body.toOwnedSlice();
    defer capture_allocator.free(pricing_text);
    return token_cost.parseOfficialApiPricingText(allocator, pricing_text, "refreshed") catch
        refreshTokenCostApiPricingFromModelDocs(allocator);
}

fn refreshTokenCostApiPricingFromModelDocs(allocator: std.mem.Allocator) !token_cost.ApiPricing {
    const bundled = token_cost.bundledApiPricing();
    var rates: std.ArrayList(token_cost.ApiModelRate) = .empty;
    errdefer {
        for (rates.items) |rate| allocator.free(rate.model);
        rates.deinit(allocator);
    }

    for (bundled.rates) |base_rate| {
        const url = apiModelDocUrl(base_rate.model) orelse return error.InvalidPricingFile;
        const body = try fetchTextUrl(std.heap.page_allocator, url);
        defer std.heap.page_allocator.free(body);
        const parsed = try parseLastThreeDollarAmounts(body);
        try rates.append(allocator, .{
            .model = try allocator.dupe(u8, base_rate.model),
            .input_usd_per_million = parsed[0],
            .cached_input_usd_per_million = parsed[1],
            .output_usd_per_million = parsed[2],
            .long_context_threshold_input_tokens = base_rate.long_context_threshold_input_tokens,
            .long_context_input_multiplier = base_rate.long_context_input_multiplier,
            .long_context_cached_input_multiplier = base_rate.long_context_cached_input_multiplier,
            .long_context_output_multiplier = base_rate.long_context_output_multiplier,
        });
    }

    return .{
        .rates = try rates.toOwnedSlice(allocator),
        .source = .refreshed,
        .source_url = try allocator.dupe(u8, "https://developers.openai.com/api/docs/models/"),
        .fetched_at = try allocator.dupe(u8, "refreshed"),
    };
}

fn fetchTextUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator, .io = defaultIo() };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(allocator);
    errdefer body.deinit();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .redirect_buffer = redirect_buffer[0..],
    });
    if (result.status != .ok) return error.PricingRefreshFailed;
    return body.toOwnedSlice();
}

fn apiModelDocUrl(model: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, model, "gpt-5.5")) return "https://developers.openai.com/api/docs/models/gpt-5.5/";
    if (std.mem.eql(u8, model, "gpt-5.4")) return "https://developers.openai.com/api/docs/models/gpt-5.4/";
    if (std.mem.eql(u8, model, "gpt-5.4-mini")) return "https://developers.openai.com/api/docs/models/gpt-5.4-mini/";
    return null;
}

fn parseLastThreeDollarAmounts(text: []const u8) ![3]f64 {
    var last: [3]f64 = .{ 0, 0, 0 };
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, idx, '$')) |dollar_idx| {
        var end = dollar_idx + 1;
        const number_start = end;
        while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.')) end += 1;
        if (end > number_start) {
            last[0] = last[1];
            last[1] = last[2];
            last[2] = try std.fmt.parseFloat(f64, text[number_start..end]);
            count += 1;
        }
        idx = @max(end, dollar_idx + 1);
    }
    if (count < 3) return error.InvalidPricingFile;
    return last;
}

fn refreshTokenCostPricing(allocator: std.mem.Allocator) !token_cost.Pricing {
    const capture_allocator = std.heap.page_allocator;
    var client = std.http.Client{ .allocator = capture_allocator, .io = defaultIo() };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(capture_allocator);
    defer body.deinit();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    const result = try client.fetch(.{
        .location = .{ .url = token_cost.OfficialRateCardUrl },
        .response_writer = &body.writer,
        .redirect_buffer = redirect_buffer[0..],
    });
    if (result.status != .ok) {
        return error.PricingRefreshFailed;
    }
    const rate_card_text = try body.toOwnedSlice();
    defer capture_allocator.free(rate_card_text);
    const pricing = try token_cost.parseOfficialRateCardText(allocator, rate_card_text, "refreshed");
    try writeTokenCostPricingCache(allocator, pricing);
    return pricing;
}

fn writeTokenCostPricingCache(allocator: std.mem.Allocator, pricing: token_cost.Pricing) !void {
    const cache_path = try tokenCostCachePath(allocator);
    defer allocator.free(cache_path);
    var rendered = std.Io.Writer.Allocating.init(allocator);
    defer rendered.deinit();
    const writer = &rendered.writer;
    try writer.print("{{\"source_url\":\"{s}\",\"fetched_at\":\"{s}\",\"models\":[", .{ pricing.source_url, pricing.fetched_at });
    for (pricing.rates, 0..) |rate, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"model\":\"{s}\",\"input_credits_per_million\":{d},\"cached_input_credits_per_million\":{d},\"output_credits_per_million\":{d}", .{
            rate.model,
            rate.input_credits_per_million,
            rate.cached_input_credits_per_million,
            rate.output_credits_per_million,
        });
        if (rate.fast_multiplier) |mult| try writer.print(",\"fast_multiplier\":{d}", .{mult});
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
    const bytes = try rendered.toOwnedSlice();
    defer allocator.free(bytes);
    if (std.fs.path.dirname(cache_path)) |dir| try std.Io.Dir.cwd().createDirPath(defaultIo(), dir);
    try std.Io.Dir.cwd().writeFile(defaultIo(), .{ .sub_path = cache_path, .data = bytes });
}

fn tokenCostCachePath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |value| {
        return std.fs.path.join(allocator, &.{ std.mem.span(value), "seq", "pricing", "codex-pricing.json" });
    }
    const home = std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
    const root = try std.fs.path.join(allocator, &.{ std.mem.span(home), ".cache" });
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "seq", "pricing", "codex-pricing.json" });
}

fn loadTokenCostTraceMeta(allocator: std.mem.Allocator, path: []const u8, opts: Options) !TokenCostTraceMeta {
    var out = TokenCostTraceMeta{};
    if (opts.force_fast) out.fast_mode = .override_fast;
    if (opts.force_standard) out.fast_mode = .override_standard;
    var trace = canonical_trace.parseSessionTrace(allocator, path, .{}) catch null;
    if (trace) |*parsed| {
        defer parsed.deinit(allocator);
        if (parsed.session.model) |model| out.model = try allocator.dupe(u8, model);
    }
    if (opts.force_fast or opts.force_standard) return out;
    const content_opt = try readFileAllocOrSkip(allocator, path);
    defer if (content_opt) |content| allocator.free(content);
    const content = content_opt orelse return out;
    out.fast_mode = detectFastModeEvidence(content);
    return out;
}

fn detectFastModeEvidence(content: []const u8) token_cost.FastMode {
    if (std.mem.containsAtLeast(u8, content, 1, "\"fast_mode\":true") or
        std.mem.containsAtLeast(u8, content, 1, "\"fast_mode\": true") or
        std.mem.containsAtLeast(u8, content, 1, "\"service_tier\":\"fast\"") or
        std.mem.containsAtLeast(u8, content, 1, "\"service_tier\": \"fast\""))
    {
        return .explicit_fast;
    }
    if (std.mem.containsAtLeast(u8, content, 1, "\"fast_mode\":false") or
        std.mem.containsAtLeast(u8, content, 1, "\"fast_mode\": false") or
        std.mem.containsAtLeast(u8, content, 1, "\"service_tier\":\"standard\"") or
        std.mem.containsAtLeast(u8, content, 1, "\"service_tier\": \"standard\""))
    {
        return .explicit_standard;
    }
    return .unknown;
}

fn addTokenCostBucket(
    allocator: std.mem.Allocator,
    index: *std.StringHashMap(usize),
    buckets: *std.ArrayList(TokenCostBucket),
    key: []const u8,
    row: datasets.token_deltas.Row,
    estimate: token_cost.Estimate,
    fast_mode: token_cost.FastMode,
    model_source: []const u8,
) !void {
    if (index.get(key)) |existing_idx| {
        addTokenCostTotals(&buckets.items[existing_idx], row, estimate, fast_mode, model_source);
        return;
    }
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try buckets.append(allocator, .{ .key = owned_key });
    errdefer {
        const popped = buckets.pop().?;
        allocator.free(popped.key);
    }
    try index.put(owned_key, buckets.items.len - 1);
    addTokenCostTotals(&buckets.items[buckets.items.len - 1], row, estimate, fast_mode, model_source);
}

fn addTokenCostTotals(bucket: *TokenCostBucket, row: datasets.token_deltas.Row, estimate: token_cost.Estimate, fast_mode: token_cost.FastMode, model_source: []const u8) void {
    bucket.rows += 1;
    bucket.input_tokens += row.delta_input_tokens orelse 0;
    bucket.cached_input_tokens += row.delta_cached_input_tokens orelse 0;
    bucket.output_tokens += row.delta_output_tokens orelse 0;
    bucket.reasoning_output_tokens += row.delta_reasoning_output_tokens orelse 0;
    const delta_total = row.delta_total_tokens orelse 0;
    bucket.total_tokens += delta_total;
    mergeTokenCostLabel(&bucket.fast_mode_label, fast_mode.label());
    mergeTokenCostLabel(&bucket.fast_mode_source, fast_mode.source());
    mergeTokenCostLabel(&bucket.model_source, model_source);
    mergeTokenCostLabel(&bucket.cost_confidence, estimate.confidence);
    if (estimate.priced) {
        bucket.priced_rows += 1;
        bucket.credits += estimate.credits;
        bucket.api_usd += estimate.api_usd;
        bucket.api_input_usd += estimate.api_input_usd;
        bucket.api_cached_input_usd += estimate.api_cached_input_usd;
        bucket.api_output_usd += estimate.api_output_usd;
        bucket.api_long_context_surcharge_usd += estimate.api_long_context_surcharge_usd;
        if (estimate.long_context_applied) bucket.long_context_priced_rows += 1;
        switch (fast_mode) {
            .explicit_fast, .override_fast => bucket.priced_fast_credits += estimate.credits,
            .unknown => bucket.priced_standard_assumption_credits += estimate.credits,
            .explicit_standard, .override_standard => bucket.priced_standard_credits += estimate.credits,
        }
    } else {
        bucket.unpriced_rows += 1;
        if (delta_total > 0) bucket.unpriced_tokens += delta_total;
    }
}

fn mergeTokenCostLabel(field: *[]const u8, value: []const u8) void {
    if (field.*.len == 0) {
        field.* = value;
    } else if (!std.mem.eql(u8, field.*, value)) {
        field.* = "mixed";
    }
}

fn putTokenCostCommonFields(
    allocator: std.mem.Allocator,
    row: *query.Row,
    bucket: TokenCostBucket,
    usd_per_credit: ?f64,
    pricing: token_cost.Pricing,
    api_pricing: token_cost.ApiPricing,
    pricing_kind: TokenCostPricingKind,
    opts: Options,
    group_by: TokenCostGroupBy,
    timezone_label: []const u8,
) !void {
    _ = allocator;
    if (pricing_kind == .codex) {
        try row.putOwnedKey("credits_estimate", .{ .float = bucket.credits });
        if (usd_per_credit) |rate| {
            try row.putOwnedKey("usd_estimate", .{ .float = bucket.credits * rate });
            try row.putOwnedKey("usd_per_credit", .{ .float = rate });
        } else {
            try row.putOwnedKey("usd_estimate", .null);
            try row.putOwnedKey("usd_per_credit", .null);
        }
    } else {
        try row.putOwnedKey("credits_estimate", .null);
        try row.putOwnedKey("usd_estimate", .{ .float = bucket.api_usd });
        try row.putOwnedKey("usd_per_credit", .null);
    }
    try row.putOwnedKey("api_input_usd", if (pricing_kind == .api) .{ .float = bucket.api_input_usd } else .null);
    try row.putOwnedKey("api_cached_input_usd", if (pricing_kind == .api) .{ .float = bucket.api_cached_input_usd } else .null);
    try row.putOwnedKey("api_output_usd", if (pricing_kind == .api) .{ .float = bucket.api_output_usd } else .null);
    try row.putOwnedKey("api_long_context_surcharge_usd", if (pricing_kind == .api) .{ .float = bucket.api_long_context_surcharge_usd } else .null);
    try row.putOwnedKey("long_context_priced_rows", if (pricing_kind == .api) .{ .int = bucket.long_context_priced_rows } else .null);
    try row.putOwnedKey("rows", .{ .int = bucket.rows });
    try row.putOwnedKey("priced_rows", .{ .int = bucket.priced_rows });
    try row.putOwnedKey("unpriced_rows", .{ .int = bucket.unpriced_rows });
    try row.putOwnedKey("input_tokens", .{ .int = bucket.input_tokens });
    try row.putOwnedKey("cached_input_tokens", .{ .int = bucket.cached_input_tokens });
    try row.putOwnedKey("output_tokens", .{ .int = bucket.output_tokens });
    try row.putOwnedKey("reasoning_output_tokens", .{ .int = bucket.reasoning_output_tokens });
    try row.putOwnedKey("total_tokens", .{ .int = bucket.total_tokens });
    try row.putOwnedKey("unpriced_tokens", .{ .int = bucket.unpriced_tokens });
    try row.putOwnedKey("pricing_source_url", .{ .string = if (pricing_kind == .api) api_pricing.source_url else pricing.source_url });
    try row.putOwnedKey("pricing_fetched_at", .{ .string = if (pricing_kind == .api) api_pricing.fetched_at else pricing.fetched_at });
    try row.putOwnedKey("pricing_kind", .{ .string = pricing_kind.label() });
    try row.putOwnedKey("reasoning_effort", .{ .string = opts.reasoning_effort_text orelse "not_priced_separately" });
    try row.putOwnedKey("fast_mode", .{ .string = if (bucket.fast_mode_label.len == 0) "n/a" else bucket.fast_mode_label });
    try row.putOwnedKey("fast_mode_source", .{ .string = if (bucket.fast_mode_source.len == 0) "n/a" else bucket.fast_mode_source });
    try row.putOwnedKey("model_source", .{ .string = if (bucket.model_source.len == 0) "n/a" else bucket.model_source });
    try row.putOwnedKey("cost_confidence", .{ .string = if (bucket.cost_confidence.len == 0) "n/a" else bucket.cost_confidence });
    try row.putOwnedKey("group_by", .{ .string = group_by.fieldName() });
    try row.putOwnedKey("tz", .{ .string = timezone_label });
    if (opts.audit or opts.summary) {
        try row.putOwnedKey("priced_fast_credits", .{ .float = bucket.priced_fast_credits });
        try row.putOwnedKey("priced_standard_credits", .{ .float = bucket.priced_standard_credits });
        try row.putOwnedKey("priced_standard_assumption_credits", .{ .float = bucket.priced_standard_assumption_credits });
    }
}

fn deinitTokenCostBuckets(
    allocator: std.mem.Allocator,
    buckets: *std.ArrayList(TokenCostBucket),
    index: *std.StringHashMap(usize),
) void {
    for (buckets.items) |bucket| allocator.free(bucket.key);
    buckets.deinit(allocator);
    index.deinit();
}

fn tokenCostBucketLessKeyAsc(_: void, lhs: TokenCostBucket, rhs: TokenCostBucket) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn tokenCostBucketLessCreditsDesc(_: void, lhs: TokenCostBucket, rhs: TokenCostBucket) bool {
    if (lhs.credits != rhs.credits) return lhs.credits > rhs.credits;
    if (lhs.api_usd != rhs.api_usd) return lhs.api_usd > rhs.api_usd;
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn tokenCostScopeKind(opts: Options, group_by: TokenCostGroupBy) []const u8 {
    if (group_by == .path) return "grouped_paths";
    if (group_by == .model) return "grouped_models";
    if (group_by == .fast_mode) return "grouped_fast_modes";
    if (opts.path != null) return "path";
    if (opts.session_id != null) return "session";
    return "corpus";
}

fn parseTokenUsageBoundMillis(raw_opt: ?[]const u8, flag_name: []const u8) !?i64 {
    const raw = raw_opt orelse return null;
    return time_utils.parseIsoTimestampMillis(raw) orelse blk: {
        printCliError("error: token-usage {s} must be an ISO-8601 timestamp with timezone\n", .{flag_name});
        break :blk error.InvalidTimestampArg;
    };
}

fn tokenUsageEventTimestampMillis(event: datasets.token_events.Row) ?i64 {
    const timestamp = event.timestamp orelse return null;
    return time_utils.parseIsoTimestampMillis(timestamp.slice());
}

fn timestampMillisSatisfiesBounds(ts_ms: i64, since_ms: ?i64, until_ms: ?i64, timezone: time_utils.TimeZone) bool {
    if (since_ms) |value| {
        if (ts_ms < value) return false;
    }
    if (until_ms) |value| {
        if (tokenUsageIsLocalDayBoundary(value, timezone)) {
            if (ts_ms >= value) return false;
            return true;
        }
        if (ts_ms > value) return false;
    }
    return true;
}

fn tokenUsageDayKeyFromMillis(ts_ms: i64, timezone: time_utils.TimeZone, out: *[10]u8) ?[]const u8 {
    const date = time_utils.dateFromTimestampMillis(ts_ms, timezone) orelse return null;
    time_utils.formatDateInto(date, out);
    return out[0..];
}

fn tokenUsageRequestedSpanDays(since_ms: ?i64, until_ms: ?i64, timezone: time_utils.TimeZone) ?i64 {
    const start_ms = since_ms orelse return null;
    const end_ms = until_ms orelse return null;
    const start_date = time_utils.dateFromTimestampMillis(start_ms, timezone) orelse return null;
    const end_date = time_utils.dateFromTimestampMillis(end_ms, timezone) orelse return null;
    var days = time_utils.daysBetweenInclusive(start_date, end_date);
    if (days > 0 and tokenUsageIsLocalDayBoundary(end_ms, timezone)) days -= 1;
    return @max(days, 0);
}

fn tokenUsageIsLocalDayBoundary(ts_ms: i64, timezone: time_utils.TimeZone) bool {
    const current = time_utils.dateFromTimestampMillis(ts_ms, timezone) orelse return false;
    const prior = time_utils.dateFromTimestampMillis(ts_ms - 1, timezone) orelse return false;
    return current.year != prior.year or current.month != prior.month or current.day != prior.day;
}

fn tokenUsageObservedSpanDays(min_day: ?[]const u8, max_day: ?[]const u8) ?i64 {
    const start_text = min_day orelse return null;
    const end_text = max_day orelse return null;
    const start_date = time_utils.parseDayLiteral(start_text) orelse return null;
    const end_date = time_utils.parseDayLiteral(end_text) orelse return null;
    return time_utils.daysBetweenInclusive(start_date, end_date);
}

fn addTokenUsageBucket(
    allocator: std.mem.Allocator,
    index: *std.StringHashMap(usize),
    buckets: *std.ArrayList(TokenUsageBucket),
    key: []const u8,
    row: datasets.token_deltas.Row,
) !void {
    if (index.get(key)) |existing_idx| {
        addTokenUsageBucketTotals(&buckets.items[existing_idx], row);
        return;
    }

    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try buckets.append(allocator, .{ .key = owned_key });
    errdefer {
        const popped = buckets.pop().?;
        allocator.free(popped.key);
    }
    try index.put(owned_key, buckets.items.len - 1);
    addTokenUsageBucketTotals(&buckets.items[buckets.items.len - 1], row);
}

fn addTokenUsageBucketTotals(bucket: *TokenUsageBucket, row: datasets.token_deltas.Row) void {
    bucket.total_tokens += row.delta_total_tokens orelse 0;
    bucket.input_tokens += row.delta_input_tokens orelse 0;
    bucket.cached_input_tokens += row.delta_cached_input_tokens orelse 0;
    bucket.output_tokens += row.delta_output_tokens orelse 0;
    bucket.reasoning_output_tokens += row.delta_reasoning_output_tokens orelse 0;
    bucket.rows += 1;
}

fn uncachedInputTokens(input_tokens: i64, cached_input_tokens: i64) i64 {
    return @max(input_tokens - cached_input_tokens, 0);
}

fn deinitTokenUsageBuckets(
    allocator: std.mem.Allocator,
    buckets: *std.ArrayList(TokenUsageBucket),
    index: *std.StringHashMap(usize),
) void {
    for (buckets.items) |bucket| allocator.free(bucket.key);
    buckets.deinit(allocator);
    index.deinit();
}

fn tokenUsageBucketLessDayAsc(_: void, lhs: TokenUsageBucket, rhs: TokenUsageBucket) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn tokenUsageBucketLessTotalDesc(_: void, lhs: TokenUsageBucket, rhs: TokenUsageBucket) bool {
    if (lhs.total_tokens != rhs.total_tokens) return lhs.total_tokens > rhs.total_tokens;
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn tokenUsageScopeKind(opts: Options, group_by: TokenUsageGroupBy) []const u8 {
    if (group_by == .path) return "grouped_paths";
    if (opts.path != null) return "path";
    if (opts.session_id != null) return "session";
    return "corpus";
}

fn tokenUsageScopeTarget(opts: Options, sessions_root: []const u8) []const u8 {
    if (opts.path) |value| return value;
    if (opts.session_id) |value| return value;
    return sessions_root;
}

fn appendTokenUsageSummaryRow(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    opts: Options,
    sessions_root: []const u8,
    group_by: TokenUsageGroupBy,
    timezone_label: []const u8,
    total_tokens: i64,
    input_tokens: i64,
    cached_input_tokens: i64,
    output_tokens: i64,
    reasoning_output_tokens: i64,
    total_rows: i64,
    path_count: usize,
    daily_buckets: []const TokenUsageBucket,
    have_day_bounds: bool,
    min_day: ?[]const u8,
    max_day: ?[]const u8,
    since_ms: ?i64,
    until_ms: ?i64,
    timezone: time_utils.TimeZone,
    audit: ?TokenUsageAudit,
) !void {
    _ = have_day_bounds;
    var row = query.Row.init(allocator);

    if (audit != null) try row.putOwnedKey("row_kind", .{ .string = "summary" });
    const scope_kind = tokenUsageScopeKind(opts, group_by);
    try row.putOwnedKey("scope_kind", .{ .string = scope_kind });
    try row.putOwnedKey("scope_target", .{ .string = tokenUsageScopeTarget(opts, sessions_root) });
    try row.putOwnedKey("group_by", .{ .string = group_by.fieldName() });
    try row.putOwnedKey("tz", .{ .string = timezone_label });
    try row.putOwnedKey("total_tokens", .{ .int = total_tokens });
    try row.putOwnedKey("input_tokens", .{ .int = input_tokens });
    try row.putOwnedKey("cached_input_tokens", .{ .int = cached_input_tokens });
    try row.putOwnedKey("uncached_input_tokens", .{ .int = uncachedInputTokens(input_tokens, cached_input_tokens) });
    try row.putOwnedKey("output_tokens", .{ .int = output_tokens });
    try row.putOwnedKey("reasoning_output_tokens", .{ .int = reasoning_output_tokens });
    try row.putOwnedKey("path_count", .{ .int = @intCast(path_count) });
    try row.putOwnedKey("rows", .{ .int = total_rows });

    const start_day = try tokenUsageSummaryBoundaryDayAlloc(allocator, since_ms, timezone, min_day);
    defer if (start_day) |value| allocator.free(value);
    const end_day = try tokenUsageSummaryEndBoundaryDayAlloc(allocator, until_ms, timezone, max_day);
    defer if (end_day) |value| allocator.free(value);

    if (start_day) |value| try row.putOwnedKey("first_day", .{ .string = value });
    if (end_day) |value| try row.putOwnedKey("last_day", .{ .string = value });

    const active_days_count: i64 = @intCast(daily_buckets.len);
    try row.putOwnedKey("active_days", .{ .int = active_days_count });

    var calendar_days: i64 = 0;
    if (start_day) |start_text| {
        if (end_day) |end_text| {
            const start_date = time_utils.parseDayLiteral(start_text) orelse null;
            const end_date = time_utils.parseDayLiteral(end_text) orelse null;
            if (start_date != null and end_date != null) {
                calendar_days = time_utils.daysBetweenInclusive(start_date.?, end_date.?);
            }
        }
    }
    try row.putOwnedKey("calendar_days", .{ .int = calendar_days });

    if (calendar_days > 0) {
        try row.putOwnedKey("average_tokens_per_calendar_day", .{ .float = @as(f64, @floatFromInt(total_tokens)) / @as(f64, @floatFromInt(calendar_days)) });
    }
    if (active_days_count > 0) {
        try row.putOwnedKey("average_tokens_per_active_day", .{ .float = @as(f64, @floatFromInt(total_tokens)) / @as(f64, @floatFromInt(active_days_count)) });
        try row.putOwnedKey("median_tokens_per_active_day", .{ .float = try tokenUsageMedianActiveDay(allocator, daily_buckets) });
    }

    var now_day_buf: [10]u8 = undefined;
    const now_day = tokenUsageDayKeyFromMillis(@as(i64, @intCast(@divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000))), timezone, &now_day_buf);
    const partial_current_day = if (end_day) |value|
        if (now_day) |current| std.mem.eql(u8, value, current) else false
    else
        false;
    try row.putOwnedKey("partial_current_day", .{ .bool = partial_current_day });

    if (audit) |audit_value| {
        try putTokenUsageAuditFields(
            allocator,
            &row,
            audit_value,
            total_tokens,
            total_rows,
            @intCast(path_count),
            daily_buckets,
            min_day,
            max_day,
            since_ms,
            until_ms,
            timezone,
        );
    }

    try out_rows.append(allocator, row);
}

fn appendTokenUsageAuditRow(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    group_by: TokenUsageGroupBy,
    timezone_label: []const u8,
    total_tokens: i64,
    input_tokens: i64,
    cached_input_tokens: i64,
    output_tokens: i64,
    reasoning_output_tokens: i64,
    total_rows: i64,
    path_count: usize,
    daily_buckets: []const TokenUsageBucket,
    min_day: ?[]const u8,
    max_day: ?[]const u8,
    since_ms: ?i64,
    until_ms: ?i64,
    timezone: time_utils.TimeZone,
    audit: TokenUsageAudit,
) !void {
    _ = input_tokens;
    _ = cached_input_tokens;
    _ = output_tokens;
    _ = reasoning_output_tokens;
    var row = query.Row.init(allocator);
    try row.putOwnedKey("row_kind", .{ .string = "audit" });
    try row.putOwnedKey(group_by.fieldName(), .null);
    try row.putOwnedKey("total_tokens", .{ .int = total_tokens });
    try row.putOwnedKey("rows", .{ .int = total_rows });
    try row.putOwnedKey("tz", .{ .string = timezone_label });
    try row.putOwnedKey("scope_kind", .{ .string = "audit" });
    try putTokenUsageAuditFields(
        allocator,
        &row,
        audit,
        total_tokens,
        total_rows,
        @intCast(path_count),
        daily_buckets,
        min_day,
        max_day,
        since_ms,
        until_ms,
        timezone,
    );
    try out_rows.append(allocator, row);
}

fn putTokenUsageAuditFields(
    allocator: std.mem.Allocator,
    row: *query.Row,
    audit: TokenUsageAudit,
    total_tokens: i64,
    total_rows: i64,
    path_count: i64,
    daily_buckets: []const TokenUsageBucket,
    min_day: ?[]const u8,
    max_day: ?[]const u8,
    since_ms: ?i64,
    until_ms: ?i64,
    timezone: time_utils.TimeZone,
) !void {
    const naive_overcount = if (audit.naive_last_total_tokens > total_tokens) audit.naive_last_total_tokens - total_tokens else 0;
    try row.putOwnedKey("audit_version", .{ .int = 1 });
    try row.putOwnedKey("audit_method", .{ .string = "monotonic_total_token_usage_deltas" });
    try row.putOwnedKey("files_scanned", .{ .int = audit.files_scanned });
    try row.putOwnedKey("files_with_counted_tokens", .{ .int = path_count });
    try row.putOwnedKey("raw_token_count_events", .{ .int = audit.raw_token_count_events + audit.raw_token_count_info_null_events });
    try row.putOwnedKey("raw_token_count_info_null_events", .{ .int = audit.raw_token_count_info_null_events });
    try row.putOwnedKey("raw_token_count_without_total_events", .{ .int = audit.raw_token_count_without_total_events });
    try row.putOwnedKey("counted_delta_rows", .{ .int = total_rows });
    try row.putOwnedKey("duplicate_total_events", .{ .int = audit.duplicate_total_events });
    try row.putOwnedKey("duplicate_total_nonzero_last_events", .{ .int = audit.duplicate_total_nonzero_last_events });
    try row.putOwnedKey("duplicate_last_tokens_excluded", .{ .int = audit.duplicate_last_tokens_excluded });
    try row.putOwnedKey("reset_events", .{ .int = audit.reset_events });
    try row.putOwnedKey("audit_total_tokens", .{ .int = total_tokens });
    try row.putOwnedKey("naive_last_total_tokens", .{ .int = audit.naive_last_total_tokens });
    try row.putOwnedKey("naive_overcount_tokens", .{ .int = naive_overcount });
    if (tokenUsageRequestedSpanDays(since_ms, until_ms, timezone)) |days| {
        try row.putOwnedKey("requested_span_days", .{ .int = days });
    } else {
        try row.putOwnedKey("requested_span_days", .null);
    }
    if (tokenUsageObservedSpanDays(min_day, max_day)) |days| {
        try row.putOwnedKey("observed_span_days", .{ .int = days });
    } else {
        try row.putOwnedKey("observed_span_days", .null);
    }
    try row.putOwnedKey("bucket_days", .{ .int = @intCast(daily_buckets.len) });
    _ = allocator;
}

fn tokenUsageSummaryBoundaryDayAlloc(
    allocator: std.mem.Allocator,
    bound_ms: ?i64,
    timezone: time_utils.TimeZone,
    fallback_day: ?[]const u8,
) !?[]u8 {
    if (bound_ms) |value| {
        const date = time_utils.dateFromTimestampMillis(value, timezone) orelse return null;
        var buf: [10]u8 = undefined;
        time_utils.formatDateInto(date, &buf);
        return try allocator.dupe(u8, buf[0..]);
    }
    const fallback = fallback_day orelse return null;
    return try allocator.dupe(u8, fallback);
}

fn tokenUsageSummaryEndBoundaryDayAlloc(
    allocator: std.mem.Allocator,
    bound_ms: ?i64,
    timezone: time_utils.TimeZone,
    fallback_day: ?[]const u8,
) !?[]u8 {
    if (bound_ms) |value| {
        const effective_ms = if (tokenUsageIsLocalDayBoundary(value, timezone)) value - 1 else value;
        const date = time_utils.dateFromTimestampMillis(effective_ms, timezone) orelse return null;
        var buf: [10]u8 = undefined;
        time_utils.formatDateInto(date, &buf);
        return try allocator.dupe(u8, buf[0..]);
    }
    const fallback = fallback_day orelse return null;
    return try allocator.dupe(u8, fallback);
}

fn tokenUsageMedianActiveDay(
    allocator: std.mem.Allocator,
    buckets: []const TokenUsageBucket,
) !f64 {
    if (buckets.len == 0) return 0;

    var totals = try allocator.alloc(i64, buckets.len);
    defer allocator.free(totals);
    for (buckets, 0..) |bucket, idx| totals[idx] = bucket.total_tokens;
    std.mem.sort(i64, totals, {}, std.sort.asc(i64));

    const mid = totals.len / 2;
    if (@mod(totals.len, 2) == 1) return @floatFromInt(totals[mid]);
    return (@as(f64, @floatFromInt(totals[mid - 1])) + @as(f64, @floatFromInt(totals[mid]))) / 2.0;
}

const CueSpec = struct {
    name: []u8,
    pattern: []u8,
    case_insensitive: bool,
};

fn cmdRoutingGap(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const cue_spec_text = opts.cue_spec_text orelse return error.MissingCueSpecArg;
    const cue_specs = try parseCueSpecJson(allocator, cue_spec_text);
    defer freeCueSpecs(allocator, cue_specs);

    var discovery_skills = try parseDiscoverySkills(allocator, opts.discovery_skills);
    defer deinitStringSet(allocator, &discovery_skills);

    var where: std.ArrayList(spec.WhereClause) = .empty;
    defer where.deinit(allocator);
    try appendSessionTimeBounds(allocator, &where, opts);

    var skill_rows = try collectDatasetRows(allocator, "skill_mentions", sessions_root, &.{}, where.items);
    defer deinitQueryRows(allocator, &skill_rows);

    var invoked_sessions: std.StringHashMap(void) = .init(allocator);
    defer deinitStringSet(allocator, &invoked_sessions);

    for (skill_rows.items) |row| {
        const skill = row.valueOrNull("skill");
        const path = row.valueOrNull("path");
        if (skill != .string or path != .string) continue;
        if (!discovery_skills.contains(skill.string)) continue;
        try addToStringSet(allocator, &invoked_sessions, path.string);
    }

    var message_rows = try collectDatasetRows(allocator, "messages", sessions_root, &.{}, where.items);
    defer deinitQueryRows(allocator, &message_rows);

    var out_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &out_rows);

    var total_cue_sessions: std.StringHashMap(void) = .init(allocator);
    defer deinitStringSet(allocator, &total_cue_sessions);
    var total_invoked_sessions: std.StringHashMap(void) = .init(allocator);
    defer deinitStringSet(allocator, &total_invoked_sessions);
    var total_cue_messages: i64 = 0;

    for (cue_specs) |cue| {
        const cue_where = [_]spec.WhereClause{
            .{
                .field = "role",
                .op = .eq,
                .value = .{ .scalar = .{ .string = "user" } },
            },
            .{
                .field = "text",
                .op = .regex,
                .value = .{ .scalar = .{ .string = cue.pattern } },
                .case_insensitive = cue.case_insensitive,
            },
        };

        const query_spec = spec.QuerySpec{
            .where = cue_where[0..],
            .select = &.{"path"},
        };
        var matched = try query.execute(allocator, message_rows.items, query_spec);
        defer matched.deinit(allocator);

        const cue_message_count: i64 = @intCast(matched.rows.items.len);
        total_cue_messages += cue_message_count;

        var cue_sessions: std.StringHashMap(void) = .init(allocator);
        defer deinitStringSet(allocator, &cue_sessions);

        for (matched.rows.items) |matched_row| {
            const path = matched_row.valueOrNull("path");
            if (path != .string) continue;
            try addToStringSet(allocator, &cue_sessions, path.string);
            try addToStringSet(allocator, &total_cue_sessions, path.string);
        }

        const invoked_count = try countIntersectionAndFill(
            allocator,
            &cue_sessions,
            &invoked_sessions,
            &total_invoked_sessions,
        );
        const cue_session_count = cue_sessions.count();
        const gap_count = cue_session_count - invoked_count;
        const rate_pct: spec.Scalar = if (cue_session_count == 0)
            .null
        else
            .{ .float = (@as(f64, @floatFromInt(invoked_count)) * 100.0) / @as(f64, @floatFromInt(cue_session_count)) };

        var out = query.Row.init(allocator);
        try out.putOwnedKey("cue", .{ .string = cue.name });
        try out.putOwnedKey("pattern", .{ .string = cue.pattern });
        try out.putOwnedKey("cue_messages", .{ .int = cue_message_count });
        try out.putOwnedKey("cue_sessions", .{ .int = @intCast(cue_session_count) });
        try out.putOwnedKey("invoked_sessions", .{ .int = @intCast(invoked_count) });
        try out.putOwnedKey("gap_sessions", .{ .int = @intCast(gap_count) });
        try out.putOwnedKey("invoked_rate_pct", rate_pct);
        try out_rows.append(allocator, out);
    }

    const total_cue_count = total_cue_sessions.count();
    const total_invoked_count = total_invoked_sessions.count();
    const total_rate_pct: spec.Scalar = if (total_cue_count == 0)
        .null
    else
        .{ .float = (@as(f64, @floatFromInt(total_invoked_count)) * 100.0) / @as(f64, @floatFromInt(total_cue_count)) };

    var summary = query.Row.init(allocator);
    try summary.putOwnedKey("cue", .{ .string = "__all__" });
    try summary.putOwnedKey("pattern", .{ .string = "-" });
    try summary.putOwnedKey("cue_messages", .{ .int = total_cue_messages });
    try summary.putOwnedKey("cue_sessions", .{ .int = @intCast(total_cue_count) });
    try summary.putOwnedKey("invoked_sessions", .{ .int = @intCast(total_invoked_count) });
    try summary.putOwnedKey("gap_sessions", .{ .int = @intCast(total_cue_count - total_invoked_count) });
    try summary.putOwnedKey("invoked_rate_pct", total_rate_pct);
    try out_rows.append(allocator, summary);

    const cols = [_][]const u8{
        "cue",
        "pattern",
        "cue_messages",
        "cue_sessions",
        "invoked_sessions",
        "gap_sessions",
        "invoked_rate_pct",
    };
    try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
}

fn parseCueSpecJson(allocator: std.mem.Allocator, raw: []const u8) ![]CueSpec {
    const text = try loadSpecText(allocator, raw);
    defer allocator.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();

    const cue_values = switch (parsed.value) {
        .array => |arr| arr.items,
        .object => |obj| blk: {
            const cues_value = obj.get("cues") orelse return error.InvalidCueSpec;
            switch (cues_value) {
                .array => |arr| break :blk arr.items,
                else => return error.InvalidCueSpec,
            }
        },
        else => return error.InvalidCueSpec,
    };
    if (cue_values.len == 0) return error.InvalidCueSpec;

    var out: std.ArrayList(CueSpec) = .empty;
    defer out.deinit(allocator);
    errdefer {
        for (out.items) |cue| {
            allocator.free(cue.name);
            allocator.free(cue.pattern);
        }
    }

    for (cue_values) |cue_value| {
        const cue_obj = switch (cue_value) {
            .object => |obj| obj,
            else => return error.InvalidCueSpec,
        };
        const name = cue_obj.get("name") orelse return error.InvalidCueSpec;
        const pattern = cue_obj.get("pattern") orelse return error.InvalidCueSpec;

        const name_text = switch (name) {
            .string => |v| v,
            else => return error.InvalidCueSpec,
        };
        const pattern_text = switch (pattern) {
            .string => |v| v,
            else => return error.InvalidCueSpec,
        };
        const case_insensitive = if (cue_obj.get("case_insensitive")) |ci| switch (ci) {
            .bool => |v| v,
            else => return error.InvalidCueSpec,
        } else false;

        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name_text),
            .pattern = try allocator.dupe(u8, pattern_text),
            .case_insensitive = case_insensitive,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn freeCueSpecs(allocator: std.mem.Allocator, cues: []const CueSpec) void {
    for (cues) |cue| {
        allocator.free(cue.name);
        allocator.free(cue.pattern);
    }
    allocator.free(cues);
}

fn parseDiscoverySkills(
    allocator: std.mem.Allocator,
    raw_opt: ?[]const u8,
) !std.StringHashMap(void) {
    const defaults = "grill-me,prove-it,complexity-mitigator,invariant-ace,tk";
    const raw = raw_opt orelse defaults;

    var set: std.StringHashMap(void) = .init(allocator);
    errdefer deinitStringSet(allocator, &set);

    var split = std.mem.splitScalar(u8, raw, ',');
    while (split.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t\r\n");
        if (trimmed.len == 0) continue;
        try addToStringSet(allocator, &set, trimmed);
    }
    if (set.count() == 0) return error.InvalidDiscoverySkills;
    return set;
}

fn addToStringSet(
    allocator: std.mem.Allocator,
    set: *std.StringHashMap(void),
    text: []const u8,
) !void {
    if (set.contains(text)) return;
    const key = try allocator.dupe(u8, text);
    errdefer allocator.free(key);
    try set.put(key, {});
}

fn countIntersectionAndFill(
    allocator: std.mem.Allocator,
    lhs: *const std.StringHashMap(void),
    rhs: *const std.StringHashMap(void),
    out_union: *std.StringHashMap(void),
) !usize {
    var count: usize = 0;
    var it = lhs.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!rhs.contains(key)) continue;
        count += 1;
        try addToStringSet(allocator, out_union, key);
    }
    return count;
}

const SessionDayPathFilter = struct {
    eq_buf: [10]u8 = undefined,
    min_buf: [10]u8 = undefined,
    max_buf: [10]u8 = undefined,
    has_eq_day: bool = false,
    has_min_day: bool = false,
    min_inclusive: bool = true,
    has_max_day: bool = false,
    max_inclusive: bool = true,

    fn hasAny(self: SessionDayPathFilter) bool {
        return self.has_eq_day or self.has_min_day or self.has_max_day;
    }

    fn eqDay(self: *const SessionDayPathFilter) ?[]const u8 {
        return if (self.has_eq_day) self.eq_buf[0..] else null;
    }

    fn minDay(self: *const SessionDayPathFilter) ?[]const u8 {
        return if (self.has_min_day) self.min_buf[0..] else null;
    }

    fn maxDay(self: *const SessionDayPathFilter) ?[]const u8 {
        return if (self.has_max_day) self.max_buf[0..] else null;
    }

    fn setEqDay(self: *SessionDayPathFilter, day: []const u8) void {
        std.mem.copyForwards(u8, self.eq_buf[0..], day[0..10]);
        self.has_eq_day = true;
    }

    fn setMinDay(self: *SessionDayPathFilter, day: []const u8, inclusive: bool) void {
        std.mem.copyForwards(u8, self.min_buf[0..], day[0..10]);
        self.has_min_day = true;
        self.min_inclusive = inclusive;
    }

    fn setMaxDay(self: *SessionDayPathFilter, day: []const u8, inclusive: bool) void {
        std.mem.copyForwards(u8, self.max_buf[0..], day[0..10]);
        self.has_max_day = true;
        self.max_inclusive = inclusive;
    }
};

fn isSessionFileDataset(dataset_name: []const u8) bool {
    return std.mem.eql(u8, dataset_name, "messages") or
        std.mem.eql(u8, dataset_name, "skill_mentions") or
        std.mem.eql(u8, dataset_name, "token_events") or
        std.mem.eql(u8, dataset_name, "token_deltas") or
        std.mem.eql(u8, dataset_name, "token_sessions") or
        std.mem.eql(u8, dataset_name, "tool_calls") or
        std.mem.eql(u8, dataset_name, "tool_invocations") or
        std.mem.eql(u8, dataset_name, "tool_call_args") or
        std.mem.eql(u8, dataset_name, "goal_runs") or
        std.mem.eql(u8, dataset_name, "sessions") or
        std.mem.eql(u8, dataset_name, "turns") or
        std.mem.eql(u8, dataset_name, "tool_lifecycle") or
        std.mem.eql(u8, dataset_name, "session_graph_edges") or
        std.mem.eql(u8, dataset_name, "workflow_signals");
}

fn isValidDayLiteral(text: []const u8) bool {
    if (text.len != 10) return false;
    return std.ascii.isDigit(text[0]) and
        std.ascii.isDigit(text[1]) and
        std.ascii.isDigit(text[2]) and
        std.ascii.isDigit(text[3]) and
        text[4] == '-' and
        std.ascii.isDigit(text[5]) and
        std.ascii.isDigit(text[6]) and
        text[7] == '-' and
        std.ascii.isDigit(text[8]) and
        std.ascii.isDigit(text[9]);
}

fn scalarDayLiteral(value: spec.Scalar) ?[]const u8 {
    return switch (value) {
        .string => |text| if (isValidDayLiteral(text)) text else null,
        else => null,
    };
}

fn scalarTimestampDayLiteral(value: spec.Scalar) ?[]const u8 {
    return switch (value) {
        .string => |text| if (text.len >= 10 and isValidDayLiteral(text[0..10])) text[0..10] else null,
        else => null,
    };
}

fn shiftDayLiteral(allocator: std.mem.Allocator, day: []const u8, delta: i32) !?[]u8 {
    var date = parseTimestampDate(day) orelse return null;
    var remaining = delta;
    if (remaining > 0) {
        while (remaining > 0) : (remaining -= 1) {
            if (date.day < daysInMonthForCommands(date.year, date.month)) {
                date.day += 1;
            } else if (date.month < 12) {
                date.month += 1;
                date.day = 1;
            } else {
                date.year += 1;
                date.month = 1;
                date.day = 1;
            }
        }
    } else if (remaining < 0) {
        while (remaining < 0) : (remaining += 1) {
            if (date.day > 1) {
                date.day -= 1;
            } else if (date.month > 1) {
                date.month -= 1;
                date.day = daysInMonthForCommands(date.year, date.month);
            } else {
                date.year -= 1;
                date.month = 12;
                date.day = 31;
            }
        }
    }

    const year_u: u32 = @intCast(@max(date.year, 0));
    const shifted = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_u, date.month, date.day });
    return shifted;
}

fn updateMinDay(filter: *SessionDayPathFilter, day: []const u8, inclusive: bool) void {
    const current = filter.minDay() orelse {
        filter.setMinDay(day, inclusive);
        return;
    };
    const order = std.mem.order(u8, day, current);
    if (order == .gt) {
        filter.setMinDay(day, inclusive);
    } else if (order == .eq and !inclusive and filter.min_inclusive) {
        filter.min_inclusive = false;
    }
}

fn updateMaxDay(filter: *SessionDayPathFilter, day: []const u8, inclusive: bool) void {
    const current = filter.maxDay() orelse {
        filter.setMaxDay(day, inclusive);
        return;
    };
    const order = std.mem.order(u8, day, current);
    if (order == .lt) {
        filter.setMaxDay(day, inclusive);
    } else if (order == .eq and !inclusive and filter.max_inclusive) {
        filter.max_inclusive = false;
    }
}

fn deriveSessionDayPathFilter(dataset_name: []const u8, query_where: []const spec.WhereClause) ?SessionDayPathFilter {
    if (!isSessionFileDataset(dataset_name)) return null;

    var filter = SessionDayPathFilter{};
    for (query_where) |clause| {
        const where_value = clause.value orelse continue;
        const scalar = switch (where_value) {
            .scalar => |value| value,
            else => continue,
        };

        if (std.mem.eql(u8, clause.field, "day")) {
            const day = scalarDayLiteral(scalar) orelse continue;
            switch (clause.op) {
                .eq => filter.setEqDay(day),
                .gte => updateMinDay(&filter, day, true),
                .gt => updateMinDay(&filter, day, false),
                .lte => updateMaxDay(&filter, day, true),
                .lt => updateMaxDay(&filter, day, false),
                else => {},
            }
            continue;
        }

        if (!std.mem.eql(u8, clause.field, "timestamp")) continue;
        const day = scalarTimestampDayLiteral(scalar) orelse continue;
        const coarse_min = shiftDayLiteral(std.heap.page_allocator, day, -1) catch null;
        const coarse_max = shiftDayLiteral(std.heap.page_allocator, day, 1) catch null;
        defer if (coarse_min) |value| std.heap.page_allocator.free(value);
        defer if (coarse_max) |value| std.heap.page_allocator.free(value);

        switch (clause.op) {
            .eq => {
                if (coarse_min) |value| updateMinDay(&filter, value, true);
                if (coarse_max) |value| updateMaxDay(&filter, value, true);
            },
            .gte, .gt => {
                if (coarse_min) |value| updateMinDay(&filter, value, true);
            },
            .lte, .lt => {
                if (coarse_max) |value| updateMaxDay(&filter, value, true);
            },
            else => {},
        }
    }

    if (!filter.hasAny()) return null;
    return filter;
}

fn appendSessionTimeWhere(
    allocator: std.mem.Allocator,
    where_out: *std.ArrayList(spec.WhereClause),
    op: spec.WhereOp,
    raw_value: []const u8,
) !void {
    try where_out.append(allocator, .{
        .field = "timestamp",
        .op = op,
        .value = .{ .scalar = .{ .string = raw_value } },
    });
}

fn appendSessionTimeBounds(
    allocator: std.mem.Allocator,
    where_out: *std.ArrayList(spec.WhereClause),
    opts: Options,
) !void {
    if (opts.since) |value| try appendSessionTimeWhere(allocator, where_out, .gte, value);
    if (opts.until) |value| try appendSessionTimeWhere(allocator, where_out, .lte, value);
}

fn timestampSatisfiesBounds(ts_opt: ?[]const u8, opts: Options) bool {
    const ts = ts_opt orelse return false;
    if (opts.since) |raw_since| {
        if (compareNormalizedTimestamp(ts, raw_since) == .lt) return false;
    }
    if (opts.until) |raw_until| {
        if (compareNormalizedTimestamp(ts, raw_until) == .gt) return false;
    }
    return true;
}

fn compareNormalizedTimestamp(lhs: []const u8, raw_rhs: []const u8) std.math.Order {
    if (time_utils.compareIsoInstants(lhs, raw_rhs)) |order| return order;

    var buffer: [64]u8 = undefined;
    const rhs = if (raw_rhs.len > 0 and raw_rhs[raw_rhs.len - 1] == 'Z' and raw_rhs.len + 5 <= buffer.len) blk: {
        @memcpy(buffer[0 .. raw_rhs.len - 1], raw_rhs[0 .. raw_rhs.len - 1]);
        @memcpy(buffer[raw_rhs.len - 1 .. raw_rhs.len + 5], "+00:00");
        break :blk buffer[0 .. raw_rhs.len + 5];
    } else raw_rhs;
    return std.mem.order(u8, lhs, rhs);
}

fn deriveSessionDayPathFilterFromOptions(opts: Options) ?SessionDayPathFilter {
    var where: [2]spec.WhereClause = undefined;
    var len: usize = 0;
    if (opts.since) |value| {
        where[len] = .{
            .field = "timestamp",
            .op = .gte,
            .value = .{ .scalar = .{ .string = value } },
        };
        len += 1;
    }
    if (opts.until) |value| {
        where[len] = .{
            .field = "timestamp",
            .op = .lte,
            .value = .{ .scalar = .{ .string = value } },
        };
        len += 1;
    }
    return deriveSessionDayPathFilter("messages", where[0..len]);
}

fn deriveSessionDayPathFilterFromWindow(window: TokenCommandWindow) ?SessionDayPathFilter {
    var filter = SessionDayPathFilter{};
    if (window.since_ms) |value| {
        var day_buf: [10]u8 = undefined;
        const day = tokenUsageDayKeyFromMillis(value, .utc, &day_buf) orelse return null;
        const coarse_min = shiftDayLiteral(std.heap.page_allocator, day, -1) catch null;
        defer if (coarse_min) |owned| std.heap.page_allocator.free(owned);
        if (coarse_min) |owned| updateMinDay(&filter, owned, true);
    }
    if (window.until_ms) |value| {
        var day_buf: [10]u8 = undefined;
        const day = tokenUsageDayKeyFromMillis(value, .utc, &day_buf) orelse return null;
        const coarse_max = shiftDayLiteral(std.heap.page_allocator, day, 1) catch null;
        defer if (coarse_max) |owned| std.heap.page_allocator.free(owned);
        if (coarse_max) |owned| updateMaxDay(&filter, owned, true);
    }
    return if (filter.hasAny()) filter else null;
}

fn dayMatchesFilter(filter: SessionDayPathFilter, day: []const u8) bool {
    if (!isValidDayLiteral(day)) return true;
    if (filter.eqDay()) |eq_day| {
        if (!std.mem.eql(u8, day, eq_day)) return false;
    }
    if (filter.minDay()) |min_day| {
        const order = std.mem.order(u8, day, min_day);
        if (order == .lt) return false;
        if (order == .eq and !filter.min_inclusive) return false;
    }
    if (filter.maxDay()) |max_day| {
        const order = std.mem.order(u8, day, max_day);
        if (order == .gt) return false;
        if (order == .eq and !filter.max_inclusive) return false;
    }
    return true;
}

fn isPathSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn extractPathDay(path: []const u8, out: *[10]u8) bool {
    if (path.len < 10) return false;

    var i: usize = 0;
    while (i + 10 <= path.len) : (i += 1) {
        if (i > 0 and !isPathSep(path[i - 1])) continue;
        if (i + 10 < path.len and !isPathSep(path[i + 10])) continue;
        if (!std.ascii.isDigit(path[i + 0]) or
            !std.ascii.isDigit(path[i + 1]) or
            !std.ascii.isDigit(path[i + 2]) or
            !std.ascii.isDigit(path[i + 3])) continue;
        if (!isPathSep(path[i + 4])) continue;
        if (!std.ascii.isDigit(path[i + 5]) or !std.ascii.isDigit(path[i + 6])) continue;
        if (!isPathSep(path[i + 7])) continue;
        if (!std.ascii.isDigit(path[i + 8]) or !std.ascii.isDigit(path[i + 9])) continue;

        out[0] = path[i + 0];
        out[1] = path[i + 1];
        out[2] = path[i + 2];
        out[3] = path[i + 3];
        out[4] = '-';
        out[5] = path[i + 5];
        out[6] = path[i + 6];
        out[7] = '-';
        out[8] = path[i + 8];
        out[9] = path[i + 9];
        return true;
    }

    return false;
}

fn runDatasetQuery(
    allocator: std.mem.Allocator,
    dataset_name: []const u8,
    sessions_root: []const u8,
    query_spec: spec.QuerySpec,
    fmt: output.Format,
    out_path: ?[]const u8,
    columns_opt: ?[]const []const u8,
) !void {
    var rows = try collectDatasetRowsForSpec(allocator, dataset_name, sessions_root, query_spec);
    defer deinitQueryRows(allocator, &rows);

    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    const cols = if (columns_opt) |c| c else if (query_spec.select.len > 0) query_spec.select else null;
    try output.writeOutput(allocator, fmt, result.rows.items, cols, out_path);
}

fn collectDatasetRowsForSpec(
    allocator: std.mem.Allocator,
    dataset_name: []const u8,
    sessions_root: []const u8,
    query_spec: spec.QuerySpec,
) !std.ArrayList(query.Row) {
    if (query_spec.joins.len > 0) {
        var rows = try collectDatasetRows(allocator, dataset_name, sessions_root, query_spec.params, query_spec.where);
        errdefer deinitQueryRows(allocator, &rows);

        for (query_spec.joins) |join_spec| {
            var right_rows = try collectRowsForJoin(allocator, rows.items, join_spec, sessions_root);
            defer deinitQueryRows(allocator, &right_rows);

            var filtered_right = try query.execute(allocator, right_rows.items, .{ .where = join_spec.where });
            defer filtered_right.deinit(allocator);

            const joined = try joinQueryRows(allocator, rows.items, filtered_right.rows.items, join_spec);
            deinitQueryRows(allocator, &rows);
            rows = joined;
        }

        return rows;
    }

    if (std.mem.eql(u8, dataset_name, "opencode_prompts")) {
        return collectOpencodePromptRowsFromSpec(allocator, query_spec);
    }
    if (std.mem.eql(u8, dataset_name, "opencode_events")) {
        return collectOpencodeEventRowsFromSpec(allocator, query_spec);
    }
    if (std.mem.eql(u8, dataset_name, "opencode_tool_calls")) {
        return collectOpencodeToolCallRowsFromSpec(allocator, query_spec);
    }
    if (std.mem.eql(u8, dataset_name, "opencode_sessions")) {
        return collectOpencodeSessionRowsFromSpec(allocator, query_spec);
    }
    return collectDatasetRows(allocator, dataset_name, sessions_root, query_spec.params, query_spec.where);
}

fn collectRowsForJoin(
    allocator: std.mem.Allocator,
    left_rows: []const query.Row,
    join_spec: spec.JoinSpec,
    sessions_root: []const u8,
) !std.ArrayList(query.Row) {
    if (canCollectJoinByLeftPaths(join_spec)) {
        return collectJoinRowsByLeftPaths(allocator, left_rows, join_spec, sessions_root);
    }
    return collectDatasetRows(allocator, join_spec.dataset, sessions_root, join_spec.params, join_spec.where);
}

fn canCollectJoinByLeftPaths(join_spec: spec.JoinSpec) bool {
    if (!std.mem.eql(u8, join_spec.dataset, "sessions")) return false;
    if (!std.mem.eql(u8, join_spec.right, "path")) return false;
    for (join_spec.params) |param| {
        if (std.mem.eql(u8, param.key, "path") or
            std.mem.eql(u8, param.key, "session_id") or
            std.mem.eql(u8, param.key, "root"))
        {
            return false;
        }
    }
    return true;
}

fn collectJoinRowsByLeftPaths(
    allocator: std.mem.Allocator,
    left_rows: []const query.Row,
    join_spec: spec.JoinSpec,
    sessions_root: []const u8,
) !std.ArrayList(query.Row) {
    var paths = StringSet.init(allocator);
    defer paths.deinit();
    for (left_rows) |row| {
        const path = scalarString(row.valueOrNull(join_spec.left)) orelse continue;
        if (path.len > 0) try paths.put(path);
    }

    var out: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &out);

    var it = paths.map.keyIterator();
    while (it.next()) |path| {
        try appendJoinRowsForPath(allocator, &out, join_spec, sessions_root, path.*);
    }

    return out;
}

fn appendJoinRowsForPath(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(query.Row),
    join_spec: spec.JoinSpec,
    sessions_root: []const u8,
    path: []const u8,
) !void {
    var params: std.ArrayList(spec.ParamSpec) = .empty;
    defer params.deinit(allocator);
    try params.appendSlice(allocator, join_spec.params);
    try params.append(allocator, .{ .key = "path", .value = .{ .string = path } });

    var collected = try collectDatasetRows(allocator, join_spec.dataset, sessions_root, params.items, join_spec.where);
    defer deinitQueryRows(allocator, &collected);
    for (collected.items) |row| {
        try out.append(allocator, try row.cloneAll(allocator));
    }
}

fn joinQueryRows(
    allocator: std.mem.Allocator,
    left_rows: []const query.Row,
    right_rows: []const query.Row,
    join_spec: spec.JoinSpec,
) !std.ArrayList(query.Row) {
    var right_index = std.StringHashMap(std.ArrayList(usize)).init(allocator);
    defer {
        var it = right_index.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        right_index.deinit();
    }

    for (right_rows, 0..) |row, idx| {
        const key = try scalarJoinKey(allocator, row.valueOrNull(join_spec.right));
        const gop = try right_index.getOrPut(key);
        if (gop.found_existing) {
            allocator.free(key);
        } else {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(allocator, idx);
    }

    var out: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &out);

    for (left_rows) |left| {
        const key = try scalarJoinKey(allocator, left.valueOrNull(join_spec.left));
        defer allocator.free(key);

        if (right_index.get(key)) |matches| {
            for (matches.items) |right_idx| {
                var joined = try left.cloneAll(allocator);
                errdefer joined.deinit();
                try appendPrefixedFields(allocator, &joined, right_rows[right_idx], join_spec.prefix orelse join_spec.dataset);
                try out.append(allocator, joined);
            }
            continue;
        }

        if (join_spec.type == .left) {
            try out.append(allocator, try left.cloneAll(allocator));
        }
    }

    return out;
}

fn appendPrefixedFields(
    allocator: std.mem.Allocator,
    row: *query.Row,
    source: query.Row,
    prefix: []const u8,
) !void {
    var it = source.fields.iterator();
    while (it.next()) |entry| {
        const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, entry.key_ptr.* });
        defer allocator.free(key);
        try row.putOwnedKey(key, entry.value_ptr.*);
    }
}

fn scalarJoinKey(allocator: std.mem.Allocator, value: spec.Scalar) ![]u8 {
    return switch (value) {
        .null => allocator.dupe(u8, "n:"),
        .bool => |flag| std.fmt.allocPrint(allocator, "b:{}", .{flag}),
        .int => |number| std.fmt.allocPrint(allocator, "i:{d}", .{number}),
        .float => |number| std.fmt.allocPrint(allocator, "f:{d}", .{number}),
        .string => |text| std.fmt.allocPrint(allocator, "s:{s}", .{text}),
    };
}

fn collectDatasetRows(
    allocator: std.mem.Allocator,
    dataset_name: []const u8,
    sessions_root: []const u8,
    query_params: []const spec.ParamSpec,
    query_where: []const spec.WhereClause,
) !std.ArrayList(query.Row) {
    var rows: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &rows);

    const day_filter = deriveSessionDayPathFilter(dataset_name, query_where);

    if (std.mem.eql(u8, dataset_name, "messages")) {
        try collectMessagesRows(allocator, sessions_root, day_filter, &rows);
    } else if (std.mem.eql(u8, dataset_name, "skill_mentions")) {
        try collectSkillMentionsRows(allocator, sessions_root, day_filter, &rows);
    } else if (std.mem.eql(u8, dataset_name, "token_events")) {
        try collectTokenEventsRows(allocator, sessions_root, day_filter, &rows);
    } else if (std.mem.eql(u8, dataset_name, "token_deltas")) {
        try collectTokenDeltasRows(allocator, sessions_root, day_filter, &rows);
    } else if (std.mem.eql(u8, dataset_name, "token_sessions")) {
        try collectTokenSessionsRows(allocator, sessions_root, day_filter, &rows);
    } else if (std.mem.eql(u8, dataset_name, "tool_calls")) {
        try collectToolCallsRows(allocator, sessions_root, day_filter, &rows);
    } else if (std.mem.eql(u8, dataset_name, "tool_invocations")) {
        try collectToolInvocationRows(allocator, sessions_root, day_filter, &rows);
    } else if (std.mem.eql(u8, dataset_name, "tool_call_args")) {
        try collectToolCallArgRows(allocator, sessions_root, day_filter, &rows);
    } else if (std.mem.eql(u8, dataset_name, "goal_runs")) {
        try collectGoalRunRows(allocator, sessions_root, day_filter, &rows);
    } else if (std.mem.eql(u8, dataset_name, "sessions") or
        std.mem.eql(u8, dataset_name, "turns") or
        std.mem.eql(u8, dataset_name, "tool_lifecycle") or
        std.mem.eql(u8, dataset_name, "session_graph_edges"))
    {
        const derived = try collectTraceDatasetRowsFromParams(allocator, dataset_name, sessions_root, query_params);
        rows = derived;
    } else if (std.mem.eql(u8, dataset_name, "workflow_signals")) {
        try collectWorkflowSignalRows(allocator, sessions_root, day_filter, &rows);
    } else if (std.mem.eql(u8, dataset_name, "memory_files")) {
        try collectMemoryFilesRows(allocator, query_params, &rows);
    } else if (std.mem.eql(u8, dataset_name, "memory_blocks")) {
        try collectMemoryBlocksRows(allocator, query_params, &rows);
    } else if (std.mem.eql(u8, dataset_name, "memory_stage1_outputs")) {
        try collectMemoryStage1OutputRows(allocator, query_params, &rows);
    } else if (std.mem.eql(u8, dataset_name, "memory_extensions")) {
        try collectMemoryExtensionRows(allocator, query_params, &rows);
    } else if (std.mem.eql(u8, dataset_name, "opencode_prompts")) {
        try collectOpencodePromptRows(allocator, query_params, &rows);
    } else if (std.mem.eql(u8, dataset_name, "opencode_events")) {
        try collectOpencodeEventRows(allocator, query_params, &rows);
    } else if (std.mem.eql(u8, dataset_name, "opencode_tool_calls")) {
        const empty_query = spec.QuerySpec{ .params = query_params };
        const derived = try collectOpencodeToolCallRowsFromSpec(allocator, empty_query);
        rows = derived;
    } else if (std.mem.eql(u8, dataset_name, "opencode_sessions")) {
        const empty_query = spec.QuerySpec{ .params = query_params };
        const derived = try collectOpencodeSessionRowsFromSpec(allocator, empty_query);
        rows = derived;
    } else {
        return error.UnknownDataset;
    }

    return rows;
}

fn collectMessagesRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root, day_filter);
    defer freePathList(allocator, &paths);

    for (paths.items) |path| {
        const content = try readFileAllocOrSkip(allocator, path);
        if (content == null) continue;
        defer allocator.free(content.?);

        const parsed = try datasets.messages.parseJsonl(allocator, path, content.?, .{});
        defer datasets.messages.freeRows(allocator, parsed);

        for (parsed) |row| {
            var qrow = query.Row.init(allocator);
            try qrow.putOwnedKey("path", .{ .string = row.path });
            try putOptionalString(&qrow, "timestamp", row.timestamp);
            try putOptionalString(&qrow, "day", row.day);
            try putOptionalString(&qrow, "week", row.week);
            try putOptionalString(&qrow, "month", row.month);
            try qrow.putOwnedKey("role", .{ .string = row.role });
            try qrow.putOwnedKey("text", .{ .string = row.text });
            try qrow.putOwnedKey("text_len", .{ .int = @intCast(row.text_len) });
            try out_rows.append(allocator, qrow);
        }
    }
}

fn collectSkillMentionsRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root, day_filter);
    defer freePathList(allocator, &paths);

    for (paths.items) |path| {
        const content = try readFileAllocOrSkip(allocator, path);
        if (content == null) continue;
        defer allocator.free(content.?);

        const parsed = try datasets.skill_mentions.parseJsonl(allocator, path, content.?, .{});
        defer datasets.skill_mentions.freeRows(allocator, parsed);

        for (parsed) |row| {
            var qrow = query.Row.init(allocator);
            try qrow.putOwnedKey("path", .{ .string = row.path });
            try putOptionalString(&qrow, "timestamp", row.timestamp);
            try putOptionalString(&qrow, "day", row.day);
            try putOptionalString(&qrow, "week", row.week);
            try putOptionalString(&qrow, "month", row.month);
            try qrow.putOwnedKey("role", .{ .string = row.role });
            try qrow.putOwnedKey("skill", .{ .string = row.skill });
            try qrow.putOwnedKey("types", .{ .string = row.types });
            try qrow.putOwnedKey("snippet", .{ .string = row.snippet });
            try out_rows.append(allocator, qrow);
        }
    }
}

fn collectWorkflowSignalRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root, day_filter);
    defer freePathList(allocator, &paths);

    for (paths.items) |path| {
        const content = try readFileAllocOrSkip(allocator, path);
        if (content == null) continue;
        defer allocator.free(content.?);

        const messages = try datasets.messages.parseJsonl(allocator, path, content.?, .{
            .strip_skill_blocks = true,
            .dedupe_by_role_and_text = true,
        });
        defer datasets.messages.freeRows(allocator, messages);

        for (messages) |row| {
            try appendDollarWorkflowSignals(allocator, out_rows, row);
            try appendOutcomeSignals(allocator, out_rows, row);
        }

        const mentions = try datasets.skill_mentions.parseJsonl(allocator, path, content.?, .{
            .include_blocks = false,
            .include_dollars = true,
            .skip_dollar_in_skill_block = true,
            .dedupe_adjacent = true,
        });
        defer datasets.skill_mentions.freeRows(allocator, mentions);

        for (mentions) |row| {
            try appendWorkflowSignalRow(
                allocator,
                out_rows,
                row.path,
                null,
                row.timestamp,
                row.role,
                sourceKindForRole(row.role),
                "skill_mention",
                row.skill,
                null,
                row.snippet,
                "cleaned",
            );
        }
    }

    var tool_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &tool_rows);
    try collectToolInvocationRows(allocator, sessions_root, day_filter, &tool_rows);
    for (tool_rows.items) |row| {
        const tool_name = scalarString(row.valueOrNull("tool_name")) orelse continue;
        try appendWorkflowSignalRow(
            allocator,
            out_rows,
            scalarString(row.valueOrNull("path")) orelse "",
            scalarString(row.valueOrNull("session_id")),
            scalarString(row.valueOrNull("timestamp")),
            null,
            "tool_trace",
            "tool_call",
            tool_name,
            null,
            scalarString(row.valueOrNull("command_text")) orelse tool_name,
            "none",
        );
    }

    for (paths.items) |path| {
        try appendWorkflowGraphSignalsForPath(allocator, sessions_root, path, out_rows);
    }
}

fn appendWorkflowGraphSignalsForPath(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    path: []const u8,
    out_rows: *std.ArrayList(query.Row),
) !void {
    const graph_params = [_]spec.ParamSpec{.{ .key = "path", .value = .{ .string = path } }};
    var graph_rows = try collectTraceDatasetRowsFromParams(allocator, "session_graph_edges", sessions_root, graph_params[0..]);
    defer deinitQueryRows(allocator, &graph_rows);
    for (graph_rows.items) |row| {
        const role = scalarString(row.valueOrNull("agent_role")) orelse continue;
        try appendWorkflowSignalRow(
            allocator,
            out_rows,
            scalarString(row.valueOrNull("parent_path")) orelse "",
            scalarString(row.valueOrNull("parent_session_id")),
            scalarString(row.valueOrNull("spawned_at")),
            null,
            "session_graph",
            "agent_role",
            role,
            null,
            scalarString(row.valueOrNull("prompt_preview")) orelse role,
            "none",
        );
    }
}

fn appendDollarWorkflowSignals(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    row: datasets.messages.MessageRow,
) !void {
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, row.text, pos, '$')) |dollar| {
        var end = dollar + 1;
        while (end < row.text.len and isSignalNameChar(row.text[end])) : (end += 1) {}
        defer pos = end;
        if (end == dollar + 1) continue;
        const name = row.text[dollar + 1 .. end];
        try appendWorkflowSignalRow(
            allocator,
            out_rows,
            row.path,
            null,
            row.timestamp,
            row.role,
            sourceKindForRole(row.role),
            "workflow_mention",
            name,
            null,
            row.text,
            "cleaned",
        );
    }
}

fn appendOutcomeSignals(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    row: datasets.messages.MessageRow,
) !void {
    const outcomes = [_]struct {
        kind: []const u8,
        needles: []const []const u8,
    }{
        .{ .kind = "test", .needles = &.{ "zig build test", "tests pass", "test passed" } },
        .{ .kind = "proof", .needles = &.{ "proof", "validated", "validation" } },
        .{ .kind = "commit", .needles = &.{ "commit ", "committed", "pushed" } },
        .{ .kind = "pr", .needles = &.{ "PR #", "pull request", "gh pr" } },
        .{ .kind = "blocked", .needles = &.{ "blocked", "failed", "error:" } },
        .{ .kind = "closure", .needles = &.{ "closure", "fixed point", "fixed-point" } },
    };

    for (outcomes) |outcome| {
        var matched = false;
        for (outcome.needles) |needle| {
            if (containsIgnoreCaseAscii(row.text, needle)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;
        try appendWorkflowSignalRow(
            allocator,
            out_rows,
            row.path,
            null,
            row.timestamp,
            row.role,
            sourceKindForRole(row.role),
            "outcome",
            outcome.kind,
            outcome.kind,
            row.text,
            "cleaned",
        );
    }
}

fn appendWorkflowSignalRow(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    path: []const u8,
    session_id: ?[]const u8,
    timestamp: ?[]const u8,
    role: ?[]const u8,
    source_kind: []const u8,
    signal_kind: []const u8,
    name: []const u8,
    outcome_kind: ?[]const u8,
    snippet: []const u8,
    contamination_flags: []const u8,
) !void {
    var qrow = query.Row.init(allocator);
    errdefer qrow.deinit();
    try qrow.putOwnedKey("path", .{ .string = path });
    try putOptionalString(&qrow, "session_id", session_id);
    try putOptionalString(&qrow, "timestamp", timestamp);
    try putOptionalString(&qrow, "role", role);
    try qrow.putOwnedKey("source_kind", .{ .string = source_kind });
    try qrow.putOwnedKey("signal_kind", .{ .string = signal_kind });
    try qrow.putOwnedKey("name", .{ .string = name });
    try putOptionalString(&qrow, "outcome_kind", outcome_kind);
    try qrow.putOwnedKey("snippet", .{ .string = snippet[0..@min(snippet.len, 240)] });
    try qrow.putOwnedKey("contamination_flags", .{ .string = contamination_flags });
    try out_rows.append(allocator, qrow);
}

fn sourceKindForRole(role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "user")) return "user_prompt";
    if (std.mem.eql(u8, role, "assistant")) return "assistant_text";
    return "text";
}

fn isSignalNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_';
}

fn scalarString(value: spec.Scalar) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn collectTokenEventsRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root, day_filter);
    defer freePathList(allocator, &paths);

    for (paths.items) |path| {
        var parsed = try datasets.token_events.parseTokenEventsFile(allocator, path, true);
        defer parsed.deinit(allocator);

        for (parsed.items) |row| {
            var qrow = query.Row.init(allocator);
            try qrow.putOwnedKey("path", .{ .string = row.path });
            try putSmallText(&qrow, "timestamp", row.timestamp);
            try putSmallText(&qrow, "day", row.day);
            try putSmallText(&qrow, "week", row.week);
            try putSmallText(&qrow, "month", row.month);
            try putOptionalInt(&qrow, "model_context_window", row.model_context_window);
            try putOptionalInt(&qrow, "total_input_tokens", row.total_input_tokens);
            try putOptionalInt(&qrow, "total_cached_input_tokens", row.total_cached_input_tokens);
            try putOptionalInt(&qrow, "total_output_tokens", row.total_output_tokens);
            try putOptionalInt(&qrow, "total_reasoning_output_tokens", row.total_reasoning_output_tokens);
            try putOptionalInt(&qrow, "total_total_tokens", row.total_total_tokens);
            try putOptionalInt(&qrow, "last_input_tokens", row.last_input_tokens);
            try putOptionalInt(&qrow, "last_cached_input_tokens", row.last_cached_input_tokens);
            try putOptionalInt(&qrow, "last_output_tokens", row.last_output_tokens);
            try putOptionalInt(&qrow, "last_reasoning_output_tokens", row.last_reasoning_output_tokens);
            try putOptionalInt(&qrow, "last_total_tokens", row.last_total_tokens);
            try out_rows.append(allocator, qrow);
        }
    }
}

fn collectTokenDeltasRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root, day_filter);
    defer freePathList(allocator, &paths);

    for (paths.items) |path| {
        var events = try datasets.token_events.parseTokenEventsFile(allocator, path, true);
        defer events.deinit(allocator);
        var deltas = try datasets.token_deltas.buildDeltas(allocator, events.items, .{});
        defer deltas.deinit(allocator);

        for (deltas.items) |row| {
            var qrow = query.Row.init(allocator);
            try qrow.putOwnedKey("path", .{ .string = row.path });
            try putSmallText(&qrow, "timestamp", row.timestamp);
            try putSmallText(&qrow, "day", row.day);
            try putSmallText(&qrow, "week", row.week);
            try putSmallText(&qrow, "month", row.month);
            try qrow.putOwnedKey("segment", .{ .int = @intCast(row.segment) });
            try putOptionalInt(&qrow, "model_context_window", row.model_context_window);
            try putOptionalInt(&qrow, "delta_input_tokens", row.delta_input_tokens);
            try putOptionalInt(&qrow, "delta_cached_input_tokens", row.delta_cached_input_tokens);
            try putOptionalInt(&qrow, "delta_output_tokens", row.delta_output_tokens);
            try putOptionalInt(&qrow, "delta_reasoning_output_tokens", row.delta_reasoning_output_tokens);
            try putOptionalInt(&qrow, "delta_total_tokens", row.delta_total_tokens);
            try putOptionalInt(&qrow, "total_input_tokens", row.total_input_tokens);
            try putOptionalInt(&qrow, "total_cached_input_tokens", row.total_cached_input_tokens);
            try putOptionalInt(&qrow, "total_output_tokens", row.total_output_tokens);
            try putOptionalInt(&qrow, "total_reasoning_output_tokens", row.total_reasoning_output_tokens);
            try putOptionalInt(&qrow, "total_total_tokens", row.total_total_tokens);
            try out_rows.append(allocator, qrow);
        }
    }
}

fn collectTokenSessionsRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root, day_filter);
    defer freePathList(allocator, &paths);

    for (paths.items) |path| {
        const maybe_row = try datasets.token_sessions.summarizeFromFile(allocator, path);
        const row = maybe_row orelse continue;

        var qrow = query.Row.init(allocator);
        try qrow.putOwnedKey("path", .{ .string = row.path });
        try putSmallText(&qrow, "start", row.start);
        try putSmallText(&qrow, "end", row.end);
        try putSmallText(&qrow, "max_at", row.max_at);
        try putSmallText(&qrow, "day", row.day);
        try putSmallText(&qrow, "week", row.week);
        try putSmallText(&qrow, "month", row.month);
        try putOptionalInt(&qrow, "total_input_tokens", row.total_input_tokens);
        try putOptionalInt(&qrow, "total_cached_input_tokens", row.total_cached_input_tokens);
        try putOptionalInt(&qrow, "total_output_tokens", row.total_output_tokens);
        try putOptionalInt(&qrow, "total_reasoning_output_tokens", row.total_reasoning_output_tokens);
        try putOptionalInt(&qrow, "total_total_tokens", row.total_total_tokens);
        try out_rows.append(allocator, qrow);
    }
}

fn collectToolCallsRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var records = try collectInvocationRecordsForRoot(allocator, sessions_root, day_filter);
    defer deinitInvocationRecords(allocator, &records);

    for (records.items) |record| {
        var qrow = query.Row.init(allocator);
        const week = try timestampWeekAlloc(allocator, record.start_ts);
        defer if (week) |value| allocator.free(value);
        try qrow.putOwnedKey("path", .{ .string = record.path });
        try putOptionalString(&qrow, "timestamp", record.start_ts);
        try putOptionalString(&qrow, "day", timestampDaySlice(record.start_ts));
        try putOptionalString(&qrow, "week", week);
        try putOptionalString(&qrow, "month", timestampMonthSlice(record.start_ts));
        try qrow.putOwnedKey("kind", .{ .string = record.invocationKindText() });
        try putOptionalString(&qrow, "tool", record.tool_name);
        try putOptionalString(&qrow, "call_id", record.call_id);
        if (record.arguments_text) |v| {
            try qrow.putOwnedKey("arguments_len", .{ .int = @intCast(v.len) });
            try qrow.putOwnedKey("arguments_text", .{ .string = v });
        } else {
            try qrow.putOwnedKey("arguments_len", .null);
            try qrow.putOwnedKey("arguments_text", .null);
        }
        if (record.input_text) |v| {
            try qrow.putOwnedKey("input_len", .{ .int = @intCast(v.len) });
            try qrow.putOwnedKey("input_text", .{ .string = v });
        } else {
            try qrow.putOwnedKey("input_len", .null);
            try qrow.putOwnedKey("input_text", .null);
        }
        try putOptionalString(&qrow, "status", record.status_text);
        try putOptionalString(&qrow, "command_text", record.command_text);
        try putOptionalString(&qrow, "primary_executable", record.primary_executable);
        try putOptionalString(&qrow, "workdir", record.workdir);
        try qrow.putOwnedKey("parse_error", .{ .bool = record.parse_error });
        try out_rows.append(allocator, qrow);
    }
}

fn collectToolInvocationRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var records = try collectInvocationRecordsForRoot(allocator, sessions_root, day_filter);
    defer deinitInvocationRecords(allocator, &records);

    for (records.items) |record| {
        var qrow = query.Row.init(allocator);
        const week = try timestampWeekAlloc(allocator, record.start_ts);
        defer if (week) |value| allocator.free(value);
        try qrow.putOwnedKey("path", .{ .string = record.path });
        try qrow.putOwnedKey("session_id", .{ .string = record.session_id });
        try putOptionalString(&qrow, "timestamp", record.start_ts);
        try putOptionalString(&qrow, "end_timestamp", record.end_ts);
        try putOptionalString(&qrow, "day", timestampDaySlice(record.start_ts));
        try putOptionalString(&qrow, "week", week);
        try putOptionalString(&qrow, "month", timestampMonthSlice(record.start_ts));
        try putOptionalString(&qrow, "call_id", record.call_id);
        try putOptionalString(&qrow, "tool_name", record.tool_name);
        try qrow.putOwnedKey("invocation_kind", .{ .string = record.invocationKindText() });
        try putOptionalString(&qrow, "arguments_text", record.arguments_text);
        try putOptionalString(&qrow, "input_text", record.input_text);
        try putOptionalString(&qrow, "command_text", record.command_text);
        try putOptionalString(&qrow, "primary_executable", record.primary_executable);
        try putOptionalString(&qrow, "workdir", record.workdir);
        try putOptionalInt(&qrow, "pty_session_id", record.pty_session_id);
        try putOptionalInt(&qrow, "wall_time_ms", record.wall_time_ms);
        try putOptionalInt(&qrow, "exit_code", record.exit_code);
        try qrow.putOwnedKey("running_state", .{ .string = record.runningState() });
        try qrow.putOwnedKey("unresolved", .{ .bool = record.unresolved() });
        try qrow.putOwnedKey("parse_error", .{ .bool = record.parse_error });
        try out_rows.append(allocator, qrow);
    }
}

fn collectGoalRunRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root, day_filter);
    defer freePathList(allocator, &paths);

    for (paths.items) |path| {
        try collectGoalRunRowsFromSession(allocator, path, out_rows);
    }
}

fn collectGoalRunRowsFromSession(
    allocator: std.mem.Allocator,
    session_path: []const u8,
    out_rows: *std.ArrayList(query.Row),
) !void {
    const content_opt = try readFileAllocOrSkip(allocator, session_path);
    if (content_opt == null) return;
    defer allocator.free(content_opt.?);

    var goal_calls = std.StringHashMap(GoalToolCall).init(allocator);
    defer {
        var it = goal_calls.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        goal_calls.deinit();
    }

    var aggregates = std.StringHashMap(GoalAggregate).init(allocator);
    defer {
        var it = aggregates.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        aggregates.deinit();
    }

    var review_invocation_count: i64 = 0;

    var lines = std.mem.splitScalar(u8, content_opt.?, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '{') continue;
        if (!std.mem.containsAtLeast(u8, trimmed, 1, "\"type\":\"response_item\"")) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), trimmed, .{}) catch continue;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        if (!stdJsonFieldEq(root, "type", "response_item")) continue;

        const payload = stdJsonObjectField(root, "payload") orelse continue;
        const payload_type = stdJsonStringField(payload, "type") orelse continue;
        const timestamp = stdJsonStringField(root, "timestamp");

        if (std.mem.eql(u8, payload_type, "function_call")) {
            const tool_name = stdJsonStringField(payload, "name") orelse continue;
            if (std.mem.eql(u8, tool_name, "get_goal") or
                std.mem.eql(u8, tool_name, "update_goal") or
                std.mem.eql(u8, tool_name, "create_goal"))
            {
                const call_id = stdJsonStringField(payload, "call_id") orelse continue;
                const key = try allocator.dupe(u8, call_id);
                errdefer allocator.free(key);
                var call = GoalToolCall{
                    .name = try allocator.dupe(u8, tool_name),
                    .timestamp = if (timestamp) |value| try allocator.dupe(u8, value) else null,
                };
                errdefer call.deinit(allocator);
                const gop = try goal_calls.getOrPut(key);
                if (gop.found_existing) {
                    allocator.free(key);
                    gop.value_ptr.deinit(allocator);
                }
                gop.value_ptr.* = call;
                continue;
            }

            if (std.mem.eql(u8, tool_name, "exec_command")) {
                if (stdJsonStringField(payload, "arguments")) |arguments_text| {
                    if (try functionCallArgumentsContainCodexReview(allocator, arguments_text)) {
                        review_invocation_count += 1;
                    }
                }
            }
            continue;
        }

        if (!std.mem.eql(u8, payload_type, "function_call_output")) continue;
        const call_id = stdJsonStringField(payload, "call_id") orelse continue;
        const call = goal_calls.get(call_id) orelse continue;
        const output_text = stdJsonStringField(payload, "output") orelse continue;
        const goal_timestamp: ?[]const u8 = if (call.timestamp) |value| value else timestamp;
        try applyGoalToolOutput(allocator, &aggregates, session_path, goal_timestamp, output_text);
    }

    const review_invocation_key = goalAggregateReviewInvocationKey(&aggregates);

    var it = aggregates.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.review_invocation_count = if (review_invocation_key) |key|
            if (std.mem.eql(u8, entry.key_ptr.*, key)) review_invocation_count else 0
        else
            0;
        try appendGoalAggregateRow(allocator, out_rows, entry.value_ptr.*);
    }
}

fn goalAggregateReviewInvocationKey(aggregates: *std.StringHashMap(GoalAggregate)) ?[]const u8 {
    var selected_key: ?[]const u8 = null;
    var selected_rank: u8 = 0;

    var it = aggregates.iterator();
    while (it.next()) |entry| {
        const objective_kind = classifyGoalObjective(entry.value_ptr.objective);
        const rank: u8 = if (!entry.value_ptr.parse_error and
            (std.mem.eql(u8, objective_kind, "review") or std.mem.eql(u8, objective_kind, "resolve")))
            3
        else if (!entry.value_ptr.parse_error)
            2
        else
            1;
        if (rank > selected_rank) {
            selected_rank = rank;
            selected_key = entry.key_ptr.*;
        }
    }

    return selected_key;
}

fn goalAggregateForKey(
    allocator: std.mem.Allocator,
    aggregates: *std.StringHashMap(GoalAggregate),
    key_text: []const u8,
    session_path: []const u8,
) !*GoalAggregate {
    const key = try allocator.dupe(u8, key_text);
    errdefer allocator.free(key);
    const gop = try aggregates.getOrPut(key);
    if (gop.found_existing) {
        allocator.free(key);
    } else {
        gop.value_ptr.* = try GoalAggregate.init(allocator, session_path);
    }
    return gop.value_ptr;
}

fn applyGoalToolOutput(
    allocator: std.mem.Allocator,
    aggregates: *std.StringHashMap(GoalAggregate),
    session_path: []const u8,
    timestamp: ?[]const u8,
    output_text: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), output_text, .{}) catch {
        var aggregate = try goalAggregateForKey(allocator, aggregates, session_path, session_path);
        aggregate.parse_error = true;
        try aggregate.observeTimestamp(allocator, timestamp);
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            var aggregate = try goalAggregateForKey(allocator, aggregates, session_path, session_path);
            aggregate.parse_error = true;
            try aggregate.observeTimestamp(allocator, timestamp);
            return;
        },
    };
    const goal = stdJsonObjectField(root, "goal") orelse {
        var aggregate = try goalAggregateForKey(allocator, aggregates, session_path, session_path);
        aggregate.parse_error = true;
        try aggregate.observeTimestamp(allocator, timestamp);
        return;
    };

    const thread_id = stdJsonStringField(goal, "threadId");
    var aggregate = try goalAggregateForKey(allocator, aggregates, thread_id orelse session_path, session_path);
    try aggregate.observeTimestamp(allocator, timestamp);
    try aggregate.updateString(allocator, "thread_id", thread_id);
    try aggregate.updateString(allocator, "objective", stdJsonStringField(goal, "objective"));
    try aggregate.updateString(allocator, "status", stdJsonStringField(goal, "status"));
    if (stdJsonIntField(goal, "createdAt")) |value| {
        if (aggregate.created_at == null or value < aggregate.created_at.?) aggregate.created_at = value;
    }
    if (stdJsonIntField(goal, "updatedAt")) |value| {
        if (aggregate.updated_at == null or value > aggregate.updated_at.?) aggregate.updated_at = value;
    }
    if (stdJsonIntField(goal, "timeUsedSeconds")) |value| {
        if (aggregate.time_used_seconds == null or value > aggregate.time_used_seconds.?) aggregate.time_used_seconds = value;
    }
    if (stdJsonIntField(goal, "tokensUsed")) |value| {
        if (aggregate.tokens_used == null or value > aggregate.tokens_used.?) aggregate.tokens_used = value;
    }
    aggregate.remaining_tokens = stdJsonIntField(root, "remainingTokens");
    try aggregate.updateString(allocator, "completion_budget_report", stdJsonStringField(root, "completionBudgetReport"));
}

fn appendGoalAggregateRow(
    allocator: std.mem.Allocator,
    out_rows: *std.ArrayList(query.Row),
    aggregate: GoalAggregate,
) !void {
    var qrow = query.Row.init(allocator);
    const week = try timestampWeekAlloc(allocator, aggregate.timestamp);
    defer if (week) |value| allocator.free(value);
    const objective_kind = classifyGoalObjective(aggregate.objective);
    const contamination_flags = goalContaminationFlags(aggregate, objective_kind);

    try qrow.putOwnedKey("path", .{ .string = aggregate.path });
    try qrow.putOwnedKey("session_id", .{ .string = aggregate.session_id });
    try putOptionalString(&qrow, "thread_id", aggregate.thread_id);
    try putOptionalString(&qrow, "timestamp", aggregate.timestamp);
    try putOptionalString(&qrow, "day", timestampDaySlice(aggregate.timestamp));
    try putOptionalString(&qrow, "week", week);
    try putOptionalString(&qrow, "month", timestampMonthSlice(aggregate.timestamp));
    try putOptionalString(&qrow, "objective", aggregate.objective);
    try qrow.putOwnedKey("objective_kind", .{ .string = objective_kind });
    try putOptionalString(&qrow, "status", aggregate.status);
    try putOptionalInt(&qrow, "created_at", aggregate.created_at);
    try putOptionalInt(&qrow, "updated_at", aggregate.updated_at);
    try putOptionalInt(&qrow, "time_used_seconds", aggregate.time_used_seconds);
    try putOptionalInt(&qrow, "tokens_used", aggregate.tokens_used);
    try putOptionalInt(&qrow, "remaining_tokens", aggregate.remaining_tokens);
    try putOptionalString(&qrow, "completion_budget_report", aggregate.completion_budget_report);
    try qrow.putOwnedKey("review_invocation_count", .{ .int = aggregate.review_invocation_count });
    try qrow.putOwnedKey("has_review_objective", .{ .bool = std.mem.eql(u8, objective_kind, "review") });
    try qrow.putOwnedKey("has_resolve_objective", .{ .bool = std.mem.eql(u8, objective_kind, "resolve") });
    try qrow.putOwnedKey("missing_duration", .{ .bool = aggregate.time_used_seconds == null });
    try qrow.putOwnedKey("parse_error", .{ .bool = aggregate.parse_error });
    try qrow.putOwnedKey("contamination_flags", .{ .string = contamination_flags });
    try out_rows.append(allocator, qrow);
}

fn classifyGoalObjective(objective_opt: ?[]const u8) []const u8 {
    const objective = objective_opt orelse return "other";
    if (containsIgnoreCaseAscii(objective, "$resolve")) return "resolve";
    if (containsIgnoreCaseAscii(objective, "codex review") or
        containsIgnoreCaseAscii(objective, "review loop") or
        containsIgnoreCaseAscii(objective, "native review") or
        containsIgnoreCaseAscii(objective, "review driver") or
        containsIgnoreCaseAscii(objective, "clean review"))
    {
        return "review";
    }
    return "other";
}

fn goalContaminationFlags(aggregate: GoalAggregate, objective_kind: []const u8) []const u8 {
    if (aggregate.parse_error) return "parse_error";
    if (std.mem.eql(u8, objective_kind, "review") and aggregate.review_invocation_count == 0) {
        return "review_objective_without_invocation";
    }
    if (std.mem.eql(u8, objective_kind, "other") and aggregate.review_invocation_count > 0) {
        return "review_invocations_without_review_objective";
    }
    return "none";
}

fn functionCallArgumentsContainCodexReview(allocator: std.mem.Allocator, arguments_text: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), arguments_text, .{}) catch return false;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return false,
    };
    const cmd_text = stdJsonStringField(obj, "cmd") orelse return false;
    return isCodexReviewInvocation(allocator, cmd_text);
}

fn isCodexReviewInvocation(allocator: std.mem.Allocator, command_text: []const u8) !bool {
    const primary = try extractPrimaryExecutable(allocator, command_text);
    defer if (primary) |value| allocator.free(value);
    if (primary) |exe| {
        const blocked = [_][]const u8{ "rg", "grep", "git", "jq", "seq", "sed", "awk", "python", "python3" };
        for (blocked) |blocked_exe| {
            if (std.mem.eql(u8, exe, blocked_exe)) return false;
        }
    }

    var saw_codex = false;
    var saw_review = false;
    var saw_help = false;
    var it = std.mem.tokenizeAny(u8, command_text, " \t\r\n;|&(){}");
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n\"'");
        if (token.len == 0) continue;
        const basename = if (std.mem.lastIndexOfScalar(u8, token, '/')) |idx|
            if (idx + 1 < token.len) token[idx + 1 ..] else token
        else
            token;
        if (!saw_codex) {
            if (std.mem.eql(u8, basename, "codex")) saw_codex = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--help") or std.mem.eql(u8, token, "-h") or std.mem.eql(u8, token, "help")) {
            saw_help = true;
        } else if (std.mem.eql(u8, token, "review")) {
            saw_review = true;
        }
    }
    return saw_codex and saw_review and !saw_help;
}

fn collectToolCallArgRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    day_filter: ?SessionDayPathFilter,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var records = try collectInvocationRecordsForRoot(allocator, sessions_root, day_filter);
    defer deinitInvocationRecords(allocator, &records);

    for (records.items) |record| {
        const payload_text = if (record.arguments_text != null)
            record.arguments_text.?
        else if (record.input_text != null)
            record.input_text.?
        else
            continue;
        const payload_source = if (record.arguments_text != null) "arguments" else "input";
        try appendFlattenedArgRows(allocator, record, payload_text, payload_source, out_rows);
    }
}

fn appendFlattenedArgRows(
    allocator: std.mem.Allocator,
    record: InvocationRecord,
    payload_text: []const u8,
    payload_source: []const u8,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), payload_text, .{}) catch {
        try appendParseErrorArgRow(allocator, record, payload_source, out_rows);
        return;
    };
    defer parsed.deinit();

    try appendJsonValueArgRows(allocator, record, payload_source, "", parsed.value, null, out_rows);
}

fn appendParseErrorArgRow(
    allocator: std.mem.Allocator,
    record: InvocationRecord,
    payload_source: []const u8,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var qrow = query.Row.init(allocator);
    const week = try timestampWeekAlloc(allocator, record.start_ts);
    defer if (week) |value| allocator.free(value);
    try qrow.putOwnedKey("path", .{ .string = record.path });
    try qrow.putOwnedKey("session_id", .{ .string = record.session_id });
    try putOptionalString(&qrow, "timestamp", record.start_ts);
    try putOptionalString(&qrow, "day", timestampDaySlice(record.start_ts));
    try putOptionalString(&qrow, "week", week);
    try putOptionalString(&qrow, "month", timestampMonthSlice(record.start_ts));
    try putOptionalString(&qrow, "call_id", record.call_id);
    try putOptionalString(&qrow, "tool_name", record.tool_name);
    try qrow.putOwnedKey("invocation_kind", .{ .string = record.invocationKindText() });
    try qrow.putOwnedKey("payload_source", .{ .string = payload_source });
    try qrow.putOwnedKey("arg_path", .{ .string = "_parse_error" });
    try qrow.putOwnedKey("value_kind", .{ .string = "parse_error" });
    try qrow.putOwnedKey("value_text", .null);
    try qrow.putOwnedKey("value_number", .null);
    try qrow.putOwnedKey("value_bool", .null);
    try qrow.putOwnedKey("is_null", .{ .bool = false });
    try qrow.putOwnedKey("array_index", .null);
    try qrow.putOwnedKey("parse_error", .{ .bool = true });
    try out_rows.append(allocator, qrow);
}

fn appendJsonValueArgRows(
    allocator: std.mem.Allocator,
    record: InvocationRecord,
    payload_source: []const u8,
    prefix: []const u8,
    value: std.json.Value,
    array_index: ?i64,
    out_rows: *std.ArrayList(query.Row),
) !void {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const next_prefix = if (prefix.len == 0)
                    entry.key_ptr.*
                else
                    try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, entry.key_ptr.* });
                defer if (prefix.len != 0) allocator.free(next_prefix);
                try appendJsonValueArgRows(allocator, record, payload_source, next_prefix, entry.value_ptr.*, null, out_rows);
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |item, idx| {
                const next_prefix = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ prefix, idx });
                defer allocator.free(next_prefix);
                try appendJsonValueArgRows(allocator, record, payload_source, next_prefix, item, @intCast(idx), out_rows);
            }
        },
        else => try appendScalarArgRow(allocator, record, payload_source, prefix, value, array_index, out_rows),
    }
}

fn appendScalarArgRow(
    allocator: std.mem.Allocator,
    record: InvocationRecord,
    payload_source: []const u8,
    arg_path: []const u8,
    value: std.json.Value,
    array_index: ?i64,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var qrow = query.Row.init(allocator);
    const week = try timestampWeekAlloc(allocator, record.start_ts);
    defer if (week) |v| allocator.free(v);
    try qrow.putOwnedKey("path", .{ .string = record.path });
    try qrow.putOwnedKey("session_id", .{ .string = record.session_id });
    try putOptionalString(&qrow, "timestamp", record.start_ts);
    try putOptionalString(&qrow, "day", timestampDaySlice(record.start_ts));
    try putOptionalString(&qrow, "week", week);
    try putOptionalString(&qrow, "month", timestampMonthSlice(record.start_ts));
    try putOptionalString(&qrow, "call_id", record.call_id);
    try putOptionalString(&qrow, "tool_name", record.tool_name);
    try qrow.putOwnedKey("invocation_kind", .{ .string = record.invocationKindText() });
    try qrow.putOwnedKey("payload_source", .{ .string = payload_source });
    try qrow.putOwnedKey("arg_path", .{ .string = if (arg_path.len == 0) "_" else arg_path });
    try putOptionalInt(&qrow, "array_index", array_index);
    try qrow.putOwnedKey("parse_error", .{ .bool = false });

    switch (value) {
        .string => |text| {
            try qrow.putOwnedKey("value_kind", .{ .string = "string" });
            try qrow.putOwnedKey("value_text", .{ .string = text });
            try qrow.putOwnedKey("value_number", .null);
            try qrow.putOwnedKey("value_bool", .null);
            try qrow.putOwnedKey("is_null", .{ .bool = false });
        },
        .integer => |num| {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{num});
            defer allocator.free(rendered);
            try qrow.putOwnedKey("value_kind", .{ .string = "integer" });
            try qrow.putOwnedKey("value_text", .{ .string = rendered });
            try qrow.putOwnedKey("value_number", .{ .int = num });
            try qrow.putOwnedKey("value_bool", .null);
            try qrow.putOwnedKey("is_null", .{ .bool = false });
        },
        .float => |num| {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{num});
            defer allocator.free(rendered);
            try qrow.putOwnedKey("value_kind", .{ .string = "float" });
            try qrow.putOwnedKey("value_text", .{ .string = rendered });
            try qrow.putOwnedKey("value_number", .{ .float = num });
            try qrow.putOwnedKey("value_bool", .null);
            try qrow.putOwnedKey("is_null", .{ .bool = false });
        },
        .bool => |flag| {
            try qrow.putOwnedKey("value_kind", .{ .string = "bool" });
            try qrow.putOwnedKey("value_text", .{ .string = if (flag) "true" else "false" });
            try qrow.putOwnedKey("value_number", .null);
            try qrow.putOwnedKey("value_bool", .{ .bool = flag });
            try qrow.putOwnedKey("is_null", .{ .bool = false });
        },
        .null => {
            try qrow.putOwnedKey("value_kind", .{ .string = "null" });
            try qrow.putOwnedKey("value_text", .null);
            try qrow.putOwnedKey("value_number", .null);
            try qrow.putOwnedKey("value_bool", .null);
            try qrow.putOwnedKey("is_null", .{ .bool = true });
        },
        else => unreachable,
    }

    try out_rows.append(allocator, qrow);
}

fn collectMemoryFilesRows(
    allocator: std.mem.Allocator,
    query_params: []const spec.ParamSpec,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var options = datasets.memory_files.Options{};
    if (paramString(query_params, "memory_root")) |memory_root| {
        options.memory_root = memory_root;
    }
    if (paramBool(query_params, "include_preview")) |include_preview| {
        options.include_preview = include_preview;
    }

    var parsed = try datasets.memory_files.collect(allocator, options);
    defer datasets.memory_files.deinitRows(allocator, &parsed);

    for (parsed.items) |row| {
        var qrow = query.Row.init(allocator);
        try qrow.putOwnedKey("path", .{ .string = row.path });
        try qrow.putOwnedKey("relative_path", .{ .string = row.relative_path });
        try qrow.putOwnedKey("name", .{ .string = row.name });
        try qrow.putOwnedKey("category", .{ .string = row.category });
        try qrow.putOwnedKey("extension", .{ .string = row.extension });
        try qrow.putOwnedKey("size_bytes", .{ .int = @intCast(row.size_bytes) });
        try qrow.putOwnedKey("modified_at", .{ .string = row.modified_at });
        try putOptionalString(&qrow, "preview", row.preview);
        try out_rows.append(allocator, qrow);
    }
}

fn collectMemoryBlocksRows(
    allocator: std.mem.Allocator,
    query_params: []const spec.ParamSpec,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var options = datasets.memory_blocks.Options{};
    if (paramString(query_params, "memory_root")) |memory_root| {
        options.memory_root = memory_root;
    }

    var parsed = try datasets.memory_blocks.collect(allocator, options);
    defer datasets.memory_blocks.deinitRows(allocator, &parsed);

    for (parsed.items) |row| {
        var qrow = query.Row.init(allocator);
        try qrow.putOwnedKey("path", .{ .string = row.path });
        try qrow.putOwnedKey("relative_path", .{ .string = row.relative_path });
        try qrow.putOwnedKey("doc_kind", .{ .string = row.doc_kind });
        try qrow.putOwnedKey("heading_path", .{ .string = row.heading_path });
        try qrow.putOwnedKey("title", .{ .string = row.title });
        try qrow.putOwnedKey("body", .{ .string = row.body });
        try qrow.putOwnedKey("preview", .{ .string = row.preview });
        try putOptionalString(&qrow, "updated_at", row.updated_at);
        try putOptionalString(&qrow, "thread_id", row.thread_id);
        try putOptionalString(&qrow, "rollout_path", row.rollout_path);
        try putOptionalString(&qrow, "keywords", row.keywords);
        try out_rows.append(allocator, qrow);
    }
}

fn collectMemoryStage1OutputRows(
    allocator: std.mem.Allocator,
    query_params: []const spec.ParamSpec,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var options = datasets.memory_stage1_outputs.Options{};
    if (paramString(query_params, "state_db_path")) |state_db_path| {
        options.state_db_path = state_db_path;
    }

    var parsed = try datasets.memory_stage1_outputs.collect(allocator, options);
    defer datasets.memory_stage1_outputs.deinitRows(allocator, &parsed);

    for (parsed.items) |row| {
        var qrow = query.Row.init(allocator);
        try qrow.putOwnedKey("thread_id", .{ .string = row.thread_id });
        try putOptionalString(&qrow, "source_updated_at", row.source_updated_at);
        try putOptionalString(&qrow, "generated_at", row.generated_at);
        try putOptionalString(&qrow, "rollout_slug", row.rollout_slug);
        try putOptionalInt(&qrow, "usage_count", row.usage_count);
        try putOptionalString(&qrow, "last_usage", row.last_usage);
        try qrow.putOwnedKey("selected_for_phase2", .{ .bool = row.selected_for_phase2 });
        try putOptionalString(&qrow, "selected_for_phase2_source_updated_at", row.selected_for_phase2_source_updated_at);
        try qrow.putOwnedKey("rollout_path", .{ .string = row.rollout_path });
        try qrow.putOwnedKey("cwd", .{ .string = row.cwd });
        try putOptionalString(&qrow, "git_branch", row.git_branch);
        try qrow.putOwnedKey("source", .{ .string = row.source });
        try qrow.putOwnedKey("title", .{ .string = row.title });
        try qrow.putOwnedKey("memory_mode", .{ .string = row.memory_mode });
        try out_rows.append(allocator, qrow);
    }
}

fn collectMemoryExtensionRows(
    allocator: std.mem.Allocator,
    query_params: []const spec.ParamSpec,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var options = datasets.memory_extensions.Options{};
    if (paramString(query_params, "extensions_root")) |extensions_root| {
        options.extensions_root = extensions_root;
    }

    var parsed = try datasets.memory_extensions.collect(allocator, options);
    defer datasets.memory_extensions.deinitRows(allocator, &parsed);

    for (parsed.items) |row| {
        var qrow = query.Row.init(allocator);
        try qrow.putOwnedKey("extension_name", .{ .string = row.extension_name });
        try putOptionalString(&qrow, "instructions_path", row.instructions_path);
        try qrow.putOwnedKey("has_instructions", .{ .bool = row.has_instructions });
        try putOptionalString(&qrow, "modified_at", row.modified_at);
        if (row.size_bytes) |value| {
            try qrow.putOwnedKey("size_bytes", .{ .int = @intCast(value) });
        } else {
            try qrow.putOwnedKey("size_bytes", .null);
        }
        try out_rows.append(allocator, qrow);
    }
}

fn collectOpencodePromptRows(
    allocator: std.mem.Allocator,
    query_params: []const spec.ParamSpec,
    out_rows: *std.ArrayList(query.Row),
) !void {
    const spec_view = spec.QuerySpec{ .params = query_params };
    const rows = try collectOpencodePromptRowsFromSpec(allocator, spec_view);
    out_rows.* = rows;
}

fn collectOpencodePromptRowsFromSpec(
    allocator: std.mem.Allocator,
    query_spec: spec.QuerySpec,
) !std.ArrayList(query.Row) {
    var out_rows: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &out_rows);

    var options = datasets.opencode_prompts.Options{};
    if (paramString(query_spec.params, "opencode_db_path")) |opencode_db_path| {
        options.opencode_db_path = opencode_db_path;
    }
    if (paramString(query_spec.params, "opencode_path")) |opencode_path| {
        options.opencode_path = opencode_path;
    }
    if (paramString(query_spec.params, "source")) |source_text| {
        options.source = try datasets.opencode_sqlite.Source.parse(source_text);
    }
    if (paramBool(query_spec.params, "include_raw")) |include_raw| {
        options.include_raw = include_raw;
    }
    if (paramBool(query_spec.params, "include_summary_fallback")) |include_summary_fallback| {
        options.include_summary_fallback = include_summary_fallback;
    }
    applyOpencodePromptPushdown(&options, query_spec);

    var parsed = try datasets.opencode_prompts.collect(allocator, options);
    defer datasets.opencode_prompts.deinitRows(allocator, &parsed);

    for (parsed.items) |row| {
        var qrow = query.Row.init(allocator);
        try qrow.putOwnedKey("source_kind", .{ .string = row.source_kind });
        try qrow.putOwnedKey("source_path", .{ .string = row.source_path });
        try qrow.putOwnedKey("source_record_index", .{ .int = row.source_record_index });
        try putOptionalString(&qrow, "session_id", row.session_id);
        try putOptionalString(&qrow, "session_slug", row.session_slug);
        try putOptionalString(&qrow, "session_directory", row.session_directory);
        try putOptionalString(&qrow, "message_id", row.message_id);
        try putOptionalString(&qrow, "message_parent_id", row.message_parent_id);
        try qrow.putOwnedKey("role", .{ .string = row.role });
        try putOptionalString(&qrow, "mode", row.mode);
        try qrow.putOwnedKey("prompt_text", .{ .string = row.prompt_text });
        try qrow.putOwnedKey("prompt_len", .{ .int = @intCast(row.prompt_len) });
        try qrow.putOwnedKey("prompt_from_summary", .{ .bool = row.prompt_from_summary });
        try qrow.putOwnedKey("prompt_truncated", .{ .bool = row.prompt_truncated });
        try qrow.putOwnedKey("parts_count", .{ .int = @intCast(row.parts_count) });
        try qrow.putOwnedKey("text_parts_count", .{ .int = @intCast(row.text_parts_count) });
        try qrow.putOwnedKey("file_parts_count", .{ .int = @intCast(row.file_parts_count) });
        try qrow.putOwnedKey("part_types", .{ .string = row.part_types });
        try qrow.putOwnedKey("file_paths", .{ .string = row.file_paths });
        try putOptionalInt(&qrow, "time_created_epoch_ms", row.time_created_epoch_ms);
        try putOptionalString(&qrow, "time_created_iso", row.time_created_iso);
        try putOptionalInt(&qrow, "time_updated_epoch_ms", row.time_updated_epoch_ms);
        try putOptionalString(&qrow, "time_updated_iso", row.time_updated_iso);
        try putOptionalString(&qrow, "raw_message_json", row.raw_message_json);
        try putOptionalString(&qrow, "raw_parts_json", row.raw_parts_json);
        try out_rows.append(allocator, qrow);
    }

    return out_rows;
}

fn collectOpencodeEventRows(
    allocator: std.mem.Allocator,
    query_params: []const spec.ParamSpec,
    out_rows: *std.ArrayList(query.Row),
) !void {
    const spec_view = spec.QuerySpec{ .params = query_params };
    const rows = try collectOpencodeEventRowsFromSpec(allocator, spec_view);
    out_rows.* = rows;
}

fn collectOpencodeEventRowsFromSpec(
    allocator: std.mem.Allocator,
    query_spec: spec.QuerySpec,
) !std.ArrayList(query.Row) {
    var out_rows: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &out_rows);

    var options = datasets.opencode_events.Options{};
    if (paramString(query_spec.params, "opencode_db_path")) |opencode_db_path| {
        options.opencode_db_path = opencode_db_path;
    }
    if (paramString(query_spec.params, "opencode_path")) |opencode_path| {
        options.opencode_path = opencode_path;
    }
    if (paramString(query_spec.params, "source")) |source_text| {
        options.source = try datasets.opencode_sqlite.Source.parse(source_text);
    }
    if (paramBool(query_spec.params, "include_raw")) |include_raw| {
        options.include_raw = include_raw;
    }
    applyOpencodeEventPushdown(&options, query_spec);

    var parsed = try datasets.opencode_events.collect(allocator, options);
    defer datasets.opencode_events.deinitRows(allocator, &parsed);

    for (parsed.items) |row| {
        var qrow = query.Row.init(allocator);
        try qrow.putOwnedKey("source_kind", .{ .string = row.source_kind });
        try qrow.putOwnedKey("source_path", .{ .string = row.source_path });
        try qrow.putOwnedKey("source_record_index", .{ .int = row.source_record_index });
        try putOptionalString(&qrow, "session_id", row.session_id);
        try putOptionalString(&qrow, "session_slug", row.session_slug);
        try putOptionalString(&qrow, "session_directory", row.session_directory);
        try putOptionalString(&qrow, "message_id", row.message_id);
        try putOptionalString(&qrow, "message_parent_id", row.message_parent_id);
        try putOptionalString(&qrow, "part_id", row.part_id);
        try qrow.putOwnedKey("event_index", .{ .int = row.event_index });
        try qrow.putOwnedKey("role", .{ .string = row.role });
        try putOptionalString(&qrow, "mode", row.mode);
        try putOptionalString(&qrow, "agent", row.agent);
        try putOptionalString(&qrow, "model_id", row.model_id);
        try putOptionalString(&qrow, "provider_id", row.provider_id);
        try putOptionalString(&qrow, "part_type", row.part_type);
        try putOptionalString(&qrow, "tool_name", row.tool_name);
        try putOptionalString(&qrow, "tool_status", row.tool_status);
        try putOptionalString(&qrow, "call_id", row.call_id);
        try putOptionalInt(&qrow, "tool_start_epoch_ms", row.tool_start_epoch_ms);
        try putOptionalInt(&qrow, "tool_end_epoch_ms", row.tool_end_epoch_ms);
        try putOptionalInt(&qrow, "tool_duration_ms", row.tool_duration_ms);
        try putOptionalInt(&qrow, "tool_exit_code", row.tool_exit_code);
        try putOptionalString(&qrow, "tool_command", row.tool_command);
        if (row.tool_output_len) |value| {
            try qrow.putOwnedKey("tool_output_len", .{ .int = @intCast(value) });
        } else {
            try qrow.putOwnedKey("tool_output_len", .null);
        }
        try putOptionalInt(&qrow, "part_time_start_epoch_ms", row.part_time_start_epoch_ms);
        try putOptionalInt(&qrow, "part_time_end_epoch_ms", row.part_time_end_epoch_ms);
        try qrow.putOwnedKey("has_reasoning_encrypted_content", .{ .bool = row.has_reasoning_encrypted_content });
        try putOptionalString(&qrow, "text", row.text);
        if (row.text_len) |value| {
            try qrow.putOwnedKey("text_len", .{ .int = @intCast(value) });
        } else {
            try qrow.putOwnedKey("text_len", .null);
        }
        try putOptionalString(&qrow, "filename", row.filename);
        try putOptionalString(&qrow, "file_path", row.file_path);
        try putOptionalString(&qrow, "mime", row.mime);
        try putOptionalInt(&qrow, "time_created_epoch_ms", row.time_created_epoch_ms);
        try putOptionalString(&qrow, "time_created_iso", row.time_created_iso);
        try putOptionalInt(&qrow, "time_updated_epoch_ms", row.time_updated_epoch_ms);
        try putOptionalString(&qrow, "time_updated_iso", row.time_updated_iso);
        try putOptionalString(&qrow, "raw_message_json", row.raw_message_json);
        try putOptionalString(&qrow, "raw_part_json", row.raw_part_json);
        try out_rows.append(allocator, qrow);
    }

    return out_rows;
}

fn collectOpencodeToolCallRowsFromSpec(
    allocator: std.mem.Allocator,
    query_spec: spec.QuerySpec,
) !std.ArrayList(query.Row) {
    var events = try collectOpencodeEventRowsFromSpec(allocator, query_spec);
    defer deinitQueryRows(allocator, &events);

    var out_rows: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &out_rows);

    const fields = [_][]const u8{
        "source_kind",
        "source_path",
        "source_record_index",
        "session_id",
        "session_slug",
        "session_directory",
        "message_id",
        "message_parent_id",
        "part_id",
        "event_index",
        "role",
        "mode",
        "agent",
        "model_id",
        "provider_id",
        "tool_name",
        "tool_status",
        "call_id",
        "tool_start_epoch_ms",
        "tool_end_epoch_ms",
        "tool_duration_ms",
        "tool_exit_code",
        "tool_command",
        "tool_output_len",
        "time_created_epoch_ms",
        "time_created_iso",
        "time_updated_epoch_ms",
        "time_updated_iso",
    };

    for (events.items) |row| {
        if (!scalarStringEq(row.valueOrNull("part_type"), "tool")) continue;
        const out = try row.cloneSelected(allocator, fields[0..]);
        try out_rows.append(allocator, out);
    }

    return out_rows;
}

fn collectOpencodeSessionRowsFromSpec(
    allocator: std.mem.Allocator,
    query_spec: spec.QuerySpec,
) !std.ArrayList(query.Row) {
    var events = try collectOpencodeEventRowsFromSpec(allocator, query_spec);
    defer deinitQueryRows(allocator, &events);

    for (events.items) |*row| {
        const part_type = row.valueOrNull("part_type");
        try row.putOwnedKey("is_tool", .{ .int = if (scalarStringEq(part_type, "tool")) 1 else 0 });
        try row.putOwnedKey("is_reasoning", .{ .int = if (scalarStringEq(part_type, "reasoning")) 1 else 0 });
        try row.putOwnedKey("is_text", .{ .int = if (scalarStringEq(part_type, "text")) 1 else 0 });
        try row.putOwnedKey("is_file", .{ .int = if (scalarStringEq(part_type, "file")) 1 else 0 });
        try row.putOwnedKey("is_patch", .{ .int = if (scalarStringEq(part_type, "patch")) 1 else 0 });
    }

    const group_by = [_][]const u8{
        "source_kind",
        "source_path",
        "session_id",
        "session_slug",
        "session_directory",
    };
    const metrics = [_]spec.MetricSpec{
        .{ .op = .count_distinct, .field = "message_id", .alias = "message_count" },
        .{ .op = .count, .alias = "event_count" },
        .{ .op = .sum, .field = "is_tool", .alias = "tool_event_count" },
        .{ .op = .sum, .field = "is_reasoning", .alias = "reasoning_event_count" },
        .{ .op = .sum, .field = "is_text", .alias = "text_event_count" },
        .{ .op = .sum, .field = "is_file", .alias = "file_event_count" },
        .{ .op = .sum, .field = "is_patch", .alias = "patch_event_count" },
        .{ .op = .min, .field = "time_created_epoch_ms", .alias = "first_event_epoch_ms" },
        .{ .op = .max, .field = "time_created_epoch_ms", .alias = "last_event_epoch_ms" },
        .{ .op = .max, .field = "time_updated_epoch_ms", .alias = "last_update_epoch_ms" },
    };
    const session_query = spec.QuerySpec{
        .group_by = group_by[0..],
        .metrics = metrics[0..],
    };

    var grouped = try query.execute(allocator, events.items, session_query);
    defer grouped.deinit(allocator);

    var out_rows: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &out_rows);

    for (grouped.rows.items) |row| {
        var out = query.Row.init(allocator);
        try out.putOwnedKey("source_kind", row.valueOrNull("source_kind"));
        try out.putOwnedKey("source_path", row.valueOrNull("source_path"));
        try out.putOwnedKey("session_id", row.valueOrNull("session_id"));
        try out.putOwnedKey("session_slug", row.valueOrNull("session_slug"));
        try out.putOwnedKey("session_directory", row.valueOrNull("session_directory"));
        try out.putOwnedKey("message_count", row.valueOrNull("message_count"));
        try out.putOwnedKey("event_count", row.valueOrNull("event_count"));
        try out.putOwnedKey("tool_event_count", row.valueOrNull("tool_event_count"));
        try out.putOwnedKey("reasoning_event_count", row.valueOrNull("reasoning_event_count"));
        try out.putOwnedKey("text_event_count", row.valueOrNull("text_event_count"));
        try out.putOwnedKey("file_event_count", row.valueOrNull("file_event_count"));
        try out.putOwnedKey("patch_event_count", row.valueOrNull("patch_event_count"));
        try out.putOwnedKey("first_event_epoch_ms", row.valueOrNull("first_event_epoch_ms"));
        try out.putOwnedKey("last_event_epoch_ms", row.valueOrNull("last_event_epoch_ms"));
        try out.putOwnedKey("last_update_epoch_ms", row.valueOrNull("last_update_epoch_ms"));

        const first_ms = scalarAsInt(row.valueOrNull("first_event_epoch_ms"));
        const last_ms = scalarAsInt(row.valueOrNull("last_event_epoch_ms"));
        if (first_ms != null and last_ms != null and last_ms.? >= first_ms.?) {
            try out.putOwnedKey("duration_ms", .{ .int = last_ms.? - first_ms.? });
        } else {
            try out.putOwnedKey("duration_ms", .null);
        }
        try out_rows.append(allocator, out);
    }

    return out_rows;
}

fn applyOpencodePromptPushdown(options: *datasets.opencode_prompts.Options, query_spec: spec.QuerySpec) void {
    if (whereStringEq(query_spec.where, "session_id")) |value| options.session_id = value;
    if (whereStringEq(query_spec.where, "session_slug")) |value| options.session_slug = value;
    if (whereStringEq(query_spec.where, "message_id")) |value| options.message_id = value;
    if (whereStringEq(query_spec.where, "mode")) |value| options.mode = value;

    const range = whereEpochMsRange(query_spec.where, "time_created_epoch_ms");
    if (range.min_ms) |min_ms| options.time_created_min_ms = min_ms;
    if (range.max_ms) |max_ms| options.time_created_max_ms = max_ms;

    if (query_spec.group_by.len == 0 and query_spec.limit > 0) {
        if (isTimeSort(query_spec.sort)) |descending| {
            options.order_desc = descending;
            options.limit = query_spec.limit;
        }
    }
}

fn applyOpencodeEventPushdown(options: *datasets.opencode_events.Options, query_spec: spec.QuerySpec) void {
    if (whereStringEq(query_spec.where, "session_id")) |value| options.session_id = value;
    if (whereStringEq(query_spec.where, "session_slug")) |value| options.session_slug = value;
    if (whereStringEq(query_spec.where, "message_id")) |value| options.message_id = value;
    if (whereStringEq(query_spec.where, "role")) |value| options.role = value;
    if (whereStringEq(query_spec.where, "mode")) |value| options.mode = value;
    if (whereStringEq(query_spec.where, "part_type")) |value| options.part_type = value;
    if (whereStringEq(query_spec.where, "tool_name")) |value| options.tool_name = value;
    if (whereStringEq(query_spec.where, "tool_status")) |value| options.tool_status = value;

    const range = whereEpochMsRange(query_spec.where, "time_created_epoch_ms");
    if (range.min_ms) |min_ms| options.time_created_min_ms = min_ms;
    if (range.max_ms) |max_ms| options.time_created_max_ms = max_ms;

    if (query_spec.group_by.len == 0 and query_spec.limit > 0) {
        if (isTimeSort(query_spec.sort)) |descending| {
            options.order_desc = descending;
            options.limit = query_spec.limit;
        }
    }
}

fn putOptionalString(row: *query.Row, field: []const u8, value: ?[]const u8) !void {
    if (value) |text| {
        try row.putOwnedKey(field, .{ .string = text });
    } else {
        try row.putOwnedKey(field, .null);
    }
}

fn putOptionalInt(row: *query.Row, field: []const u8, value: ?i64) !void {
    if (value) |v| {
        try row.putOwnedKey(field, .{ .int = v });
    } else {
        try row.putOwnedKey(field, .null);
    }
}

fn scalarAsInt(value: spec.Scalar) ?i64 {
    return switch (value) {
        .int => |v| v,
        .float => |v| @intFromFloat(v),
        else => null,
    };
}

fn scalarStringEq(value: spec.Scalar, expected: []const u8) bool {
    return switch (value) {
        .string => |text| std.mem.eql(u8, text, expected),
        else => false,
    };
}

fn whereStringEq(where: []const spec.WhereClause, field: []const u8) ?[]const u8 {
    var out: ?[]const u8 = null;
    for (where) |clause| {
        if (!std.mem.eql(u8, clause.field, field)) continue;
        if (clause.op != .eq) continue;
        const where_value = clause.value orelse continue;
        switch (where_value) {
            .scalar => |scalar| switch (scalar) {
                .string => |text| out = text,
                else => {},
            },
            else => {},
        }
    }
    return out;
}

const EpochMsRange = struct {
    min_ms: ?i64 = null,
    max_ms: ?i64 = null,
};

fn whereEpochMsRange(where: []const spec.WhereClause, field: []const u8) EpochMsRange {
    var out = EpochMsRange{};
    for (where) |clause| {
        if (!std.mem.eql(u8, clause.field, field)) continue;
        const where_value = clause.value orelse continue;
        const scalar = switch (where_value) {
            .scalar => |v| v,
            else => continue,
        };
        const value = scalarAsInt(scalar) orelse continue;
        switch (clause.op) {
            .gte => {
                if (out.min_ms == null or value > out.min_ms.?) out.min_ms = value;
            },
            .gt => {
                if (value < std.math.maxInt(i64)) {
                    const adjusted = value + 1;
                    if (out.min_ms == null or adjusted > out.min_ms.?) out.min_ms = adjusted;
                }
            },
            .lte => {
                if (out.max_ms == null or value < out.max_ms.?) out.max_ms = value;
            },
            .lt => {
                if (value > std.math.minInt(i64)) {
                    const adjusted = value - 1;
                    if (out.max_ms == null or adjusted < out.max_ms.?) out.max_ms = adjusted;
                }
            },
            .eq => {
                out.min_ms = value;
                out.max_ms = value;
            },
            else => {},
        }
    }
    return out;
}

fn isTimeSort(sort: []const spec.SortSpec) ?bool {
    if (sort.len == 0) return null;
    if (!std.mem.eql(u8, sort[0].field, "time_created_epoch_ms")) return null;
    return sort[0].descending;
}

fn paramString(params: []const spec.ParamSpec, key: []const u8) ?[]const u8 {
    const value = spec.paramValue(params, key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn paramBool(params: []const spec.ParamSpec, key: []const u8) ?bool {
    const value = spec.paramValue(params, key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        .int => |number| number != 0,
        .string => |text| blk: {
            if (std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1")) break :blk true;
            if (std.ascii.eqlIgnoreCase(text, "false") or std.mem.eql(u8, text, "0")) break :blk false;
            break :blk null;
        },
        else => null,
    };
}

fn mergeOpencodeParams(
    allocator: std.mem.Allocator,
    base_params: []const spec.ParamSpec,
    opts: Options,
) ![]const spec.ParamSpec {
    var out: std.ArrayList(spec.ParamSpec) = .empty;
    defer out.deinit(allocator);

    for (base_params) |entry| {
        if (opts.opencode_db_path != null and std.mem.eql(u8, entry.key, "opencode_db_path")) continue;
        if (opts.opencode_path != null and std.mem.eql(u8, entry.key, "opencode_path")) continue;
        if (opts.opencode_source_text != null and std.mem.eql(u8, entry.key, "source")) continue;
        if (opts.include_raw and std.mem.eql(u8, entry.key, "include_raw")) continue;
        try out.append(allocator, entry);
    }

    if (opts.opencode_db_path) |path| {
        try out.append(allocator, .{
            .key = "opencode_db_path",
            .value = .{ .string = try allocator.dupe(u8, path) },
        });
    }
    if (opts.opencode_path) |path| {
        try out.append(allocator, .{
            .key = "opencode_path",
            .value = .{ .string = try allocator.dupe(u8, path) },
        });
    }
    if (opts.opencode_source_text) |source| {
        try out.append(allocator, .{
            .key = "source",
            .value = .{ .string = try allocator.dupe(u8, source) },
        });
    }
    if (opts.include_raw) {
        try out.append(allocator, .{
            .key = "include_raw",
            .value = .{ .bool = true },
        });
    }

    return out.toOwnedSlice(allocator);
}

fn applyOpencodePromptConvenienceFilters(
    allocator: std.mem.Allocator,
    base: spec.QuerySpec,
    opts: Options,
) !spec.QuerySpec {
    var where_out: std.ArrayList(spec.WhereClause) = .empty;
    defer where_out.deinit(allocator);
    try where_out.appendSlice(allocator, base.where);

    if (opts.contains) |value| {
        try where_out.append(allocator, .{
            .field = "prompt_text",
            .op = .contains,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.regex) |value| {
        try where_out.append(allocator, .{
            .field = "prompt_text",
            .op = .regex,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.mode) |value| {
        try where_out.append(allocator, .{
            .field = "mode",
            .op = .eq,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.part_type) |value| {
        try where_out.append(allocator, .{
            .field = "part_types",
            .op = .contains,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.session) |value| {
        const field_name = if (std.mem.startsWith(u8, value, "ses_")) "session_id" else "session_slug";
        try where_out.append(allocator, .{
            .field = field_name,
            .op = .eq,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.since) |value| {
        try appendTimeWhere(allocator, &where_out, "time_created_epoch_ms", "time_created_iso", .gte, value);
    }
    if (opts.until) |value| {
        try appendTimeWhere(allocator, &where_out, "time_created_epoch_ms", "time_created_iso", .lte, value);
    }

    const group_by_out = if (opts.group_by_text) |csv|
        try parseCsvStringList(allocator, csv)
    else
        base.group_by;
    const select_out = if (opts.select_text) |csv|
        try parseCsvStringList(allocator, csv)
    else
        base.select;
    var sort_out = if (opts.sort_text) |csv|
        try parseCsvSortList(allocator, csv)
    else
        base.sort;
    const metrics_out = if (opts.metric_text) |csv|
        try parseCsvMetricList(allocator, csv)
    else
        base.metrics;

    if (opts.latest or (group_by_out.len == 0 and sort_out.len == 0)) {
        sort_out = try defaultRecentSort(allocator);
    }

    const limit_out = if (opts.latest and opts.limit == 0 and base.limit == 0)
        @as(usize, 1)
    else if (opts.limit > 0)
        opts.limit
    else
        base.limit;

    return .{
        .where = try where_out.toOwnedSlice(allocator),
        .group_by = group_by_out,
        .metrics = metrics_out,
        .select = select_out,
        .sort = sort_out,
        .params = base.params,
        .limit = limit_out,
    };
}

fn applyOpencodeEventConvenienceFilters(
    allocator: std.mem.Allocator,
    base: spec.QuerySpec,
    opts: Options,
) !spec.QuerySpec {
    var where_out: std.ArrayList(spec.WhereClause) = .empty;
    defer where_out.deinit(allocator);
    try where_out.appendSlice(allocator, base.where);

    if (opts.contains) |value| {
        try where_out.append(allocator, .{
            .field = "text",
            .op = .contains,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.regex) |value| {
        try where_out.append(allocator, .{
            .field = "text",
            .op = .regex,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.role) |value| {
        try where_out.append(allocator, .{
            .field = "role",
            .op = .eq,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.mode) |value| {
        try where_out.append(allocator, .{
            .field = "mode",
            .op = .eq,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.part_type) |value| {
        try where_out.append(allocator, .{
            .field = "part_type",
            .op = .eq,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.tool) |value| {
        try where_out.append(allocator, .{
            .field = "tool_name",
            .op = .eq,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.status) |value| {
        try where_out.append(allocator, .{
            .field = "tool_status",
            .op = .eq,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.session) |value| {
        const field_name = if (std.mem.startsWith(u8, value, "ses_")) "session_id" else "session_slug";
        try where_out.append(allocator, .{
            .field = field_name,
            .op = .eq,
            .value = .{ .scalar = .{ .string = try allocator.dupe(u8, value) } },
        });
    }
    if (opts.since) |value| {
        try appendTimeWhere(allocator, &where_out, "time_created_epoch_ms", "time_created_iso", .gte, value);
    }
    if (opts.until) |value| {
        try appendTimeWhere(allocator, &where_out, "time_created_epoch_ms", "time_created_iso", .lte, value);
    }

    const group_by_out = if (opts.group_by_text) |csv|
        try parseCsvStringList(allocator, csv)
    else
        base.group_by;
    const select_out = if (opts.select_text) |csv|
        try parseCsvStringList(allocator, csv)
    else
        base.select;
    var sort_out = if (opts.sort_text) |csv|
        try parseCsvSortList(allocator, csv)
    else
        base.sort;
    const metrics_out = if (opts.metric_text) |csv|
        try parseCsvMetricList(allocator, csv)
    else
        base.metrics;

    if (opts.latest or (group_by_out.len == 0 and sort_out.len == 0)) {
        sort_out = try defaultRecentSort(allocator);
    }

    const limit_out = if (opts.latest and opts.limit == 0 and base.limit == 0)
        @as(usize, 1)
    else if (opts.limit > 0)
        opts.limit
    else
        base.limit;

    return .{
        .where = try where_out.toOwnedSlice(allocator),
        .group_by = group_by_out,
        .metrics = metrics_out,
        .select = select_out,
        .sort = sort_out,
        .params = base.params,
        .limit = limit_out,
    };
}

fn appendTimeWhere(
    allocator: std.mem.Allocator,
    where_out: *std.ArrayList(spec.WhereClause),
    epoch_field: []const u8,
    iso_field: []const u8,
    op: spec.WhereOp,
    raw_value: []const u8,
) !void {
    if (parseEpochMs(raw_value)) |epoch_ms| {
        try where_out.append(allocator, .{
            .field = epoch_field,
            .op = op,
            .value = .{ .scalar = .{ .int = epoch_ms } },
        });
        return;
    }
    try where_out.append(allocator, .{
        .field = iso_field,
        .op = op,
        .value = .{ .scalar = .{ .string = try allocator.dupe(u8, raw_value) } },
    });
}

fn parseEpochMs(raw: []const u8) ?i64 {
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

fn defaultRecentSort(allocator: std.mem.Allocator) ![]const spec.SortSpec {
    const out = try allocator.alloc(spec.SortSpec, 1);
    out[0] = .{
        .field = try allocator.dupe(u8, "time_created_epoch_ms"),
        .descending = true,
    };
    return out;
}

fn parseCsvStringList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);

    var split = std.mem.splitScalar(u8, raw, ',');
    while (split.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return out.toOwnedSlice(allocator);
}

fn parseCsvSortList(allocator: std.mem.Allocator, raw: []const u8) ![]const spec.SortSpec {
    var out: std.ArrayList(spec.SortSpec) = .empty;
    defer out.deinit(allocator);

    var split = std.mem.splitScalar(u8, raw, ',');
    while (split.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        const descending = trimmed[0] == '-';
        const field = if (descending) trimmed[1..] else trimmed;
        if (field.len == 0) return error.InvalidSort;
        try out.append(allocator, .{
            .field = try allocator.dupe(u8, field),
            .descending = descending,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn parseCsvMetricList(allocator: std.mem.Allocator, raw: []const u8) ![]const spec.MetricSpec {
    var out: std.ArrayList(spec.MetricSpec) = .empty;
    defer out.deinit(allocator);

    var split = std.mem.splitScalar(u8, raw, ',');
    while (split.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ':');
        const op_text = parts.next() orelse return error.InvalidMetricOp;
        const field_text = parts.next();
        const alias_text = parts.next();

        try out.append(allocator, .{
            .op = try spec.MetricOp.parse(op_text),
            .field = if (field_text) |field|
                if (field.len == 0) null else try allocator.dupe(u8, field)
            else
                null,
            .alias = if (alias_text) |alias|
                if (alias.len == 0) null else try allocator.dupe(u8, alias)
            else
                null,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn stdJsonFieldEq(obj: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const value = stdJsonStringField(obj, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn stdJsonObjectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |inner| inner,
        else => null,
    };
}

fn stdJsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn stdJsonIntField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return stdJsonValueToI64(value);
}

fn stdJsonValueToI64(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        .float => |number| blk: {
            const min = @as(f64, @floatFromInt(std.math.minInt(i64)));
            const max = @as(f64, @floatFromInt(std.math.maxInt(i64)));
            if (!std.math.isFinite(number)) break :blk null;
            if (number < min or number > max) break :blk null;
            break :blk @intFromFloat(number);
        },
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn deinitStringSet(allocator: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var it = set.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    set.deinit();
}

fn putSmallText(
    row: *query.Row,
    field: []const u8,
    value: ?datasets.token_events.SmallText,
) !void {
    if (value) |text| {
        try row.putOwnedKey(field, .{ .string = text.slice() });
    } else {
        try row.putOwnedKey(field, .null);
    }
}

fn parseOptions(args: []const []const u8) !Options {
    var opts = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--current")) {
            opts.current = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.format = try output.Format.parse(args[i]);
            opts.format_set = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.root = args[i];
        } else if (std.mem.eql(u8, arg, "--path")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.path = args[i];
        } else if (std.mem.eql(u8, arg, "--session-id")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.session_id = args[i];
        } else if (std.mem.eql(u8, arg, "--thread-id")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.thread_id = args[i];
        } else if (std.mem.eql(u8, arg, "--rollout-summary-file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.rollout_summary_file = args[i];
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.out_path = args[i];
        } else if (std.mem.eql(u8, arg, "--dataset")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.dataset = args[i];
        } else if (std.mem.eql(u8, arg, "--spec")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.spec_text = args[i];
        } else if (std.mem.eql(u8, arg, "--skill")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.skill = args[i];
        } else if (std.mem.eql(u8, arg, "--workflow")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.workflow = args[i];
        } else if (std.mem.eql(u8, arg, "--history")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.history_text = args[i];
        } else if (std.mem.eql(u8, arg, "--bucket")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.bucket = args[i];
        } else if (std.mem.eql(u8, arg, "--prompt")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--kind")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.kind_text = args[i];
        } else if (std.mem.eql(u8, arg, "--surface")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.surface_text = args[i];
        } else if (std.mem.eql(u8, arg, "--follow")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.follow_text = args[i];
        } else if (std.mem.eql(u8, arg, "--roles")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.roles_csv = args[i];
        } else if (std.mem.eql(u8, arg, "--contains")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.contains = args[i];
        } else if (std.mem.eql(u8, arg, "--contains-any")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.contains_any_text = args[i];
        } else if (std.mem.eql(u8, arg, "--contains-all")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.contains_all_text = args[i];
        } else if (std.mem.eql(u8, arg, "--regex")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.regex = args[i];
        } else if (std.mem.eql(u8, arg, "--role")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.role = args[i];
        } else if (std.mem.eql(u8, arg, "--tool")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.tool = args[i];
        } else if (std.mem.eql(u8, arg, "--executable")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.executable_text = args[i];
        } else if (std.mem.eql(u8, arg, "--workdir")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.workdir_text = args[i];
        } else if (std.mem.eql(u8, arg, "--repo")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.repo_text = args[i];
        } else if (std.mem.eql(u8, arg, "--status")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.status = args[i];
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.mode = args[i];
        } else if (std.mem.eql(u8, arg, "--part-type")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.part_type = args[i];
        } else if (std.mem.eql(u8, arg, "--tz")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.timezone_text = args[i];
        } else if (std.mem.eql(u8, arg, "--since")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.since = args[i];
        } else if (std.mem.eql(u8, arg, "--until")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.until = args[i];
        } else if (std.mem.eql(u8, arg, "--last")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.last_text = args[i];
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.session = args[i];
        } else if (std.mem.eql(u8, arg, "--group-by")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.group_by_text = args[i];
        } else if (std.mem.eql(u8, arg, "--metric")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.metric_text = args[i];
        } else if (std.mem.eql(u8, arg, "--pricing")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.pricing_text = args[i];
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.model_text = args[i];
        } else if (std.mem.eql(u8, arg, "--reasoning-effort")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.reasoning_effort_text = args[i];
        } else if (std.mem.eql(u8, arg, "--pricing-file")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.pricing_file = args[i];
        } else if (std.mem.eql(u8, arg, "--usd-per-credit")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.usd_per_credit_text = args[i];
        } else if (std.mem.eql(u8, arg, "--select")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.select_text = args[i];
        } else if (std.mem.eql(u8, arg, "--sort")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.sort_text = args[i];
        } else if (std.mem.eql(u8, arg, "--trace")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.trace_text = args[i];
        } else if (std.mem.eql(u8, arg, "--state-db-path")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.state_db_path = args[i];
        } else if (std.mem.eql(u8, arg, "--memory-root")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.memory_root_text = args[i];
        } else if (std.mem.eql(u8, arg, "--extensions-root")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.extensions_root_text = args[i];
        } else if (std.mem.eql(u8, arg, "--opencode-db-path")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.opencode_db_path = args[i];
        } else if (std.mem.eql(u8, arg, "--opencode-path")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.opencode_path = args[i];
        } else if (std.mem.eql(u8, arg, "--source")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.opencode_source_text = args[i];
        } else if (std.mem.eql(u8, arg, "--include-raw")) {
            opts.include_raw = true;
        } else if (std.mem.eql(u8, arg, "--include-parts")) {
            opts.include_raw = true;
        } else if (std.mem.eql(u8, arg, "--include-body")) {
            opts.include_body = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            opts.stats = true;
        } else if (std.mem.eql(u8, arg, "--refresh-pricing")) {
            opts.refresh_pricing = true;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            opts.offline = true;
        } else if (std.mem.eql(u8, arg, "--force-fast")) {
            opts.force_fast = true;
        } else if (std.mem.eql(u8, arg, "--force-standard")) {
            opts.force_standard = true;
        } else if (std.mem.eql(u8, arg, "--strip-skill-blocks")) {
            opts.strip_skill_blocks = true;
        } else if (std.mem.eql(u8, arg, "--no-dedupe-exact")) {
            opts.no_dedupe_exact = true;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            opts.summary = true;
        } else if (std.mem.eql(u8, arg, "--audit")) {
            opts.audit = true;
        } else if (std.mem.eql(u8, arg, "--show-query")) {
            opts.show_query = true;
        } else if (std.mem.eql(u8, arg, "--exclude-current")) {
            opts.exclude_current = true;
        } else if (std.mem.eql(u8, arg, "--next-actions")) {
            opts.next_actions = true;
        } else if (std.mem.eql(u8, arg, "--latest")) {
            opts.latest = true;
        } else if (std.mem.eql(u8, arg, "--ongoing")) {
            opts.ongoing = true;
        } else if (std.mem.eql(u8, arg, "--completed")) {
            opts.completed = true;
        } else if (std.mem.eql(u8, arg, "--include-tools")) {
            opts.include_tools = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            opts.once = true;
        } else if (std.mem.eql(u8, arg, "--strict-hang")) {
            opts.strict_hang = true;
        } else if (std.mem.eql(u8, arg, "--no-strict-hang")) {
            opts.strict_hang = false;
        } else if (std.mem.eql(u8, arg, "--sections")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.sections = args[i];
        } else if (std.mem.eql(u8, arg, "--cue-spec")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.cue_spec_text = args[i];
        } else if (std.mem.eql(u8, arg, "--discovery-skills")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.discovery_skills = args[i];
        } else if (std.mem.eql(u8, arg, "--floor-threshold")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            const n = try std.fmt.parseInt(i64, args[i], 10);
            if (n < 1) return error.InvalidLimit;
            opts.floor_threshold = n;
        } else if (std.mem.eql(u8, arg, "--fail-on-floor")) {
            opts.fail_on_floor = true;
        } else if (std.mem.eql(u8, arg, "--fail-on-mesh-truth")) {
            opts.fail_on_mesh_truth = true;
        } else if (std.mem.eql(u8, arg, "--fail-on-hang")) {
            opts.fail_on_hang = true;
        } else if (std.mem.eql(u8, arg, "--threshold-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            const n = try std.fmt.parseInt(i64, args[i], 10);
            if (n < 1) return error.InvalidLimit;
            opts.threshold_ms = n;
        } else if (std.mem.eql(u8, arg, "--window-hours")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            const n = try std.fmt.parseInt(i64, args[i], 10);
            if (n < 1) return error.InvalidLimit;
            opts.window_hours = n;
        } else if (std.mem.eql(u8, arg, "--duration-gte")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.duration_gte_seconds = try parseDurationSeconds(args[i]);
        } else if (std.mem.eql(u8, arg, "--worker-kind")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.worker_kind_text = args[i];
        } else if (std.mem.eql(u8, arg, "--events")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.events_text = args[i];
        } else if (std.mem.eql(u8, arg, "--poll-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            const n = try std.fmt.parseInt(i64, args[i], 10);
            if (n < 1) return error.InvalidLimit;
            opts.poll_ms = n;
        } else if (std.mem.eql(u8, arg, "--debounce-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            const n = try std.fmt.parseInt(i64, args[i], 10);
            if (n < 1) return error.InvalidLimit;
            opts.debounce_ms = n;
        } else if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "--max") or std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            const n = try std.fmt.parseInt(i64, args[i], 10);
            if (n < 0) return error.InvalidLimit;
            opts.limit = @intCast(n);
        } else {
            printCliError("error: unknown option {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    return opts;
}

fn parseDurationSeconds(raw: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidLimit;
    const unit = trimmed[trimmed.len - 1];
    const has_unit = unit == 's' or unit == 'm' or unit == 'h';
    const number_text = if (has_unit) trimmed[0 .. trimmed.len - 1] else trimmed;
    if (number_text.len == 0) return error.InvalidLimit;
    const value = try std.fmt.parseInt(i64, number_text, 10);
    if (value < 1) return error.InvalidLimit;
    return switch (unit) {
        'h' => std.math.mul(i64, value, 3600) catch return error.InvalidLimit,
        'm' => std.math.mul(i64, value, 60) catch return error.InvalidLimit,
        else => value,
    };
}

fn findDatasetMeta(name: []const u8) ?DatasetMeta {
    for (dataset_meta) |meta| {
        if (std.mem.eql(u8, meta.name, name)) return meta;
    }
    return null;
}

fn resolveSessionsRoot(allocator: std.mem.Allocator, root_opt: ?[]const u8) ![]u8 {
    const root = root_opt orelse "~/.codex/sessions";
    return toAbsolutePath(allocator, root);
}

fn toAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const expanded = try expandHomePath(allocator, path);
    defer allocator.free(expanded);

    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);

    const cwd = try std.process.currentPathAlloc(defaultIo(), allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, expanded });
}

fn expandHomePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~")) {
        const home = std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
        return allocator.dupe(u8, std.mem.span(home));
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
        return std.fs.path.join(allocator, &.{ std.mem.span(home), path[2..] });
    }
    return allocator.dupe(u8, path);
}

fn collectJsonlPaths(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    day_filter: ?SessionDayPathFilter,
) !std.ArrayList([]u8) {
    if (day_filter) |filter| {
        if (try collectJsonlPathsFromBoundedDayDirs(allocator, root_abs, filter)) |bounded| {
            return bounded;
        }
    }

    var out = std.ArrayList([]u8).empty;
    errdefer freePathList(allocator, &out);

    var root_dir = std.Io.Dir.openDirAbsolute(defaultIo(), root_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out,
        else => return err,
    };
    defer root_dir.close(defaultIo());

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
        const abs = try std.fs.path.join(allocator, &.{ root_abs, entry.path });
        if (day_filter) |filter| {
            var day_buf: [10]u8 = undefined;
            if (extractPathDay(abs, &day_buf)) {
                if (!dayMatchesFilter(filter, day_buf[0..])) {
                    allocator.free(abs);
                    continue;
                }
            }
        }
        try out.append(allocator, abs);
    }
    std.mem.sort([]u8, out.items, {}, lessThanString);
    return out;
}

fn collectJsonlPathsFromBoundedDayDirs(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    filter: SessionDayPathFilter,
) !?std.ArrayList([]u8) {
    const start_day = filter.eqDay() orelse filter.minDay() orelse return null;
    const end_day = filter.eqDay() orelse filter.maxDay() orelse return null;
    const start_date = time_utils.parseDayLiteral(start_day) orelse return null;
    const end_date = time_utils.parseDayLiteral(end_day) orelse return null;
    const day_count = time_utils.daysBetweenInclusive(start_date, end_date);
    if (day_count < 1 or day_count > 45) return null;

    var out = std.ArrayList([]u8).empty;
    errdefer freePathList(allocator, &out);

    var current = try allocator.dupe(u8, start_day);
    defer allocator.free(current);
    while (true) {
        if (dayMatchesFilter(filter, current)) {
            const rel = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ current[0..4], current[5..7], current[8..10] });
            defer allocator.free(rel);
            const day_root = try std.fs.path.join(allocator, &.{ root_abs, rel });
            defer allocator.free(day_root);
            try appendJsonlPathsUnderExistingDir(allocator, &out, day_root);
        }
        if (std.mem.eql(u8, current, end_day)) break;
        const next = (try shiftDayLiteral(allocator, current, 1)) orelse break;
        defer allocator.free(next);
        @memcpy(current[0..10], next[0..10]);
    }

    std.mem.sort([]u8, out.items, {}, lessThanString);
    return out;
}

fn appendJsonlPathsUnderExistingDir(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    dir_abs: []const u8,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(defaultIo(), dir_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(defaultIo());

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(defaultIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".jsonl")) continue;
        const abs = try std.fs.path.join(allocator, &.{ dir_abs, entry.path });
        errdefer allocator.free(abs);
        try out.append(allocator, abs);
    }
}

fn loadSpecText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len > 1 and raw[0] == '@') {
        return std.Io.Dir.cwd().readFileAlloc(defaultIo(), raw[1..], allocator, .limited(2 * 1024 * 1024));
    }
    return allocator.dupe(u8, raw);
}

fn readFileAllocOrSkip(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(256 * 1024 * 1024)) catch null;
}

fn freePathList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |path| allocator.free(path);
    list.deinit(allocator);
}

fn lessThanString(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const TimestampDate = struct {
    year: i32,
    month: u8,
    day: u8,
};

fn timestampDaySlice(ts_opt: ?[]const u8) ?[]const u8 {
    const ts = ts_opt orelse return null;
    if (ts.len < 10) return null;
    return ts[0..10];
}

fn timestampMonthSlice(ts_opt: ?[]const u8) ?[]const u8 {
    const ts = ts_opt orelse return null;
    if (ts.len < 7) return null;
    return ts[0..7];
}

fn parseTimestampDate(ts: []const u8) ?TimestampDate {
    if (ts.len < 10) return null;
    if (ts[4] != '-' or ts[7] != '-') return null;
    const year = std.fmt.parseInt(i32, ts[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, ts[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, ts[8..10], 10) catch return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonthForCommands(year, month)) return null;
    return .{ .year = year, .month = month, .day = day };
}

fn isLeapYearForCommands(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

fn daysInMonthForCommands(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYearForCommands(year)) 29 else 28,
        else => 0,
    };
}

fn dayOfYearForCommands(date: TimestampDate) u16 {
    var total: u16 = 0;
    var m: u8 = 1;
    while (m < date.month) : (m += 1) total += daysInMonthForCommands(date.year, m);
    return total + date.day;
}

fn weekdayMondayOneForCommands(date: TimestampDate) u8 {
    var y = date.year;
    if (date.month < 3) y -= 1;
    const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const month_idx: usize = @intCast(date.month - 1);
    const weekday_sun_zero = @mod(y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + t[month_idx] + date.day, 7);
    if (weekday_sun_zero == 0) return 7;
    return @intCast(weekday_sun_zero);
}

fn isoWeeksInYearForCommands(year: i32) u8 {
    const jan1 = TimestampDate{ .year = year, .month = 1, .day = 1 };
    const jan1_weekday = weekdayMondayOneForCommands(jan1);
    if (jan1_weekday == 4 or (jan1_weekday == 3 and isLeapYearForCommands(year))) return 53;
    return 52;
}

fn isoWeekAndYearForCommands(date: TimestampDate) struct { year: i32, week: u8 } {
    const doy: i32 = dayOfYearForCommands(date);
    const dow: i32 = weekdayMondayOneForCommands(date);

    var week = @divFloor(doy - dow + 10, 7);
    var iso_year = date.year;
    if (week < 1) {
        iso_year -= 1;
        week = isoWeeksInYearForCommands(iso_year);
    } else {
        const weeks_in_year = isoWeeksInYearForCommands(iso_year);
        if (week > weeks_in_year) {
            iso_year += 1;
            week = 1;
        }
    }
    return .{ .year = iso_year, .week = @intCast(week) };
}

fn timestampWeekAlloc(allocator: std.mem.Allocator, ts_opt: ?[]const u8) !?[]u8 {
    const ts = ts_opt orelse return null;
    const date = parseTimestampDate(ts) orelse return null;
    const iso = isoWeekAndYearForCommands(date);
    const iso_year_u: u32 = @intCast(@max(iso.year, 0));
    const week = try std.fmt.allocPrint(allocator, "{d:0>4}-W{d:0>2}", .{ iso_year_u, iso.week });
    return week;
}

fn deinitQueryRows(allocator: std.mem.Allocator, rows: *std.ArrayList(query.Row)) void {
    for (rows.items) |*row| row.deinit();
    rows.deinit(allocator);
}

fn trimQueryRows(rows: *std.ArrayList(query.Row), limit: usize) void {
    if (limit == 0 or rows.items.len <= limit) return;
    var idx = rows.items.len;
    while (idx > limit) {
        idx -= 1;
        rows.items[idx].deinit();
    }
    rows.items.len = limit;
}

fn previewPushByte(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    max_len: usize,
    truncated: *bool,
    byte: u8,
) !void {
    if (truncated.*) return;
    if (out.items.len >= max_len) {
        truncated.* = true;
        return;
    }
    try out.append(allocator, byte);
}

fn previewPushSlice(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    max_len: usize,
    truncated: *bool,
) !void {
    for (text) |byte| {
        try previewPushByte(allocator, out, max_len, truncated, byte);
        if (truncated.*) return;
    }
}

fn appendCollapsedPreview(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    max_len: usize,
    truncated: *bool,
) !void {
    var saw_visible = false;
    var pending_space = false;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (saw_visible) pending_space = true;
            continue;
        }
        if (pending_space and out.items.len > 0) {
            try previewPushByte(allocator, out, max_len, truncated, ' ');
            if (truncated.*) return;
        }
        pending_space = false;
        saw_visible = true;
        try previewPushByte(allocator, out, max_len, truncated, byte);
        if (truncated.*) return;
    }
}

fn finalizePreview(allocator: std.mem.Allocator, out: *std.ArrayList(u8), max_len: usize, truncated: bool) ![]u8 {
    if (truncated and max_len > 0) {
        const ellipsis = "...";
        const keep_len = if (max_len > ellipsis.len) max_len - ellipsis.len else 0;
        if (out.items.len > keep_len) out.items.len = keep_len;
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        try out.appendSlice(allocator, ellipsis);
    }
    return out.toOwnedSlice(allocator);
}

fn buildCollapsedPreviewAlloc(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var truncated = false;
    try appendCollapsedPreview(allocator, &out, text, max_len, &truncated);
    return finalizePreview(allocator, &out, max_len, truncated);
}

fn buildJoinedPreviewAlloc(allocator: std.mem.Allocator, parts: []const []const u8, max_len: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var truncated = false;
    for (parts, 0..) |part, idx| {
        if (idx > 0 and !truncated) {
            try previewPushSlice(allocator, &out, " | ", max_len, &truncated);
        }
        if (truncated) break;
        try appendCollapsedPreview(allocator, &out, part, max_len, &truncated);
        if (truncated) break;
    }
    return finalizePreview(allocator, &out, max_len, truncated);
}

fn formatDurationHumanAlloc(allocator: std.mem.Allocator, duration_ms: i64) ![]u8 {
    const safe_ms = @max(duration_ms, 0);
    const total_seconds = @divFloor(safe_ms, 1000);
    const millis: u16 = @intCast(@mod(safe_ms, 1000));
    const hours = @divFloor(total_seconds, 3600);
    const minutes = @divFloor(@mod(total_seconds, 3600), 60);
    const seconds = @mod(total_seconds, 60);
    if (hours > 0) {
        return std.fmt.allocPrint(allocator, "{d}h {d}m {d}.{d:0>3}s", .{ hours, minutes, seconds, millis });
    }
    if (minutes > 0) {
        return std.fmt.allocPrint(allocator, "{d}m {d}.{d:0>3}s", .{ minutes, seconds, millis });
    }
    return std.fmt.allocPrint(allocator, "{d}.{d:0>3}s", .{ seconds, millis });
}

fn parseIsoTimestampMillis(ts: []const u8) ?i64 {
    return time_utils.parseIsoTimestampMillis(ts);
}

test "deriveSessionDayPathFilter honors day bounds for session datasets" {
    const where = [_]spec.WhereClause{
        .{
            .field = "day",
            .op = .gte,
            .value = .{ .scalar = .{ .string = "2026-02-27" } },
        },
        .{
            .field = "day",
            .op = .lt,
            .value = .{ .scalar = .{ .string = "2026-03-03" } },
        },
    };

    const filter = deriveSessionDayPathFilter("skill_mentions", where[0..]) orelse return error.TestExpectedEqual;
    try std.testing.expect(dayMatchesFilter(filter, "2026-02-27"));
    try std.testing.expect(dayMatchesFilter(filter, "2026-03-02"));
    try std.testing.expect(!dayMatchesFilter(filter, "2026-02-26"));
    try std.testing.expect(!dayMatchesFilter(filter, "2026-03-03"));
}

test "collectJsonlPaths applies day filter pushdown on path dates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/02/26");
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/02/27");
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/01");

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "2026/02/26/a.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "2026/02/27/b.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "2026/03/01/c.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "2026/03/01/notes.txt", .data = "ignore\n" });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);

    var filter = SessionDayPathFilter{};
    filter.setMinDay("2026-02-27", true);
    var paths = try collectJsonlPaths(std.testing.allocator, root_abs, filter);
    defer freePathList(std.testing.allocator, &paths);

    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, paths.items[0], 1, "/2026/02/27/") or std.mem.containsAtLeast(u8, paths.items[1], 1, "/2026/02/27/"));
    try std.testing.expect(std.mem.containsAtLeast(u8, paths.items[0], 1, "/2026/03/01/") or std.mem.containsAtLeast(u8, paths.items[1], 1, "/2026/03/01/"));
}

test "deriveSessionDayPathFilter widens timestamp bounds for safe path pushdown" {
    const where = [_]spec.WhereClause{
        .{
            .field = "timestamp",
            .op = .gte,
            .value = .{ .scalar = .{ .string = "2026-03-09T00:00:00Z" } },
        },
        .{
            .field = "timestamp",
            .op = .lte,
            .value = .{ .scalar = .{ .string = "2026-03-10T23:59:59Z" } },
        },
    };

    const filter = deriveSessionDayPathFilter("messages", where[0..]) orelse return error.TestExpectedEqual;
    try std.testing.expect(dayMatchesFilter(filter, "2026-03-08"));
    try std.testing.expect(dayMatchesFilter(filter, "2026-03-09"));
    try std.testing.expect(dayMatchesFilter(filter, "2026-03-10"));
    try std.testing.expect(dayMatchesFilter(filter, "2026-03-11"));
    try std.testing.expect(!dayMatchesFilter(filter, "2026-03-07"));
    try std.testing.expect(!dayMatchesFilter(filter, "2026-03-12"));
}

test "tool invocation datasets expose command text and flattened args" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/09");
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "2026/03/09/sample.jsonl",
        .data =
        \\{"type":"response_item","timestamp":"2026-03-09T04:01:05Z","payload":{"type":"function_call","name":"exec_command","call_id":"call-1","arguments":"{\"cmd\":\"learnings recall --query \\\"Commit and push the changes for $st\\\" --limit 5 --drop-superseded\",\"workdir\":\"/Users/tk/.dotfiles\",\"yield_time_ms\":1000}"}}
        \\{"type":"response_item","timestamp":"2026-03-09T04:01:06Z","payload":{"type":"function_call_output","call_id":"call-1","output":"Chunk ID: aa\nWall time: 0.050 seconds\nProcess exited with code 0\nOutput:\n"}}
        \\
        ,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);

    var invocation_rows = try collectDatasetRows(std.testing.allocator, "tool_invocations", root_abs, &.{}, &.{});
    defer deinitQueryRows(std.testing.allocator, &invocation_rows);
    try std.testing.expectEqual(@as(usize, 1), invocation_rows.items.len);
    const tool_name = invocation_rows.items[0].valueOrNull("tool_name");
    try std.testing.expect(tool_name == .string and std.mem.eql(u8, tool_name.string, "exec_command"));
    const workdir = invocation_rows.items[0].valueOrNull("workdir");
    try std.testing.expect(workdir == .string and std.mem.eql(u8, workdir.string, "/Users/tk/.dotfiles"));
    const command_text = invocation_rows.items[0].valueOrNull("command_text");
    try std.testing.expect(command_text == .string and std.mem.indexOf(u8, command_text.string, "learnings recall") != null);

    var arg_rows = try collectDatasetRows(std.testing.allocator, "tool_call_args", root_abs, &.{}, &.{});
    defer deinitQueryRows(std.testing.allocator, &arg_rows);
    try std.testing.expect(arg_rows.items.len >= 2);
}

test "summarizeSessionConcurrency computes configured and effective maxima" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "wave-a.csv",
        .data =
        \\id,objective
        \\U01,a
        \\U02,b
        \\U03,c
        ,
    });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "wave-b.csv",
        .data =
        \\id,objective
        \\U11,x
        ,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);

    const csv_a = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "wave-a.csv" });
    defer std.testing.allocator.free(csv_a);
    const csv_b = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "wave-b.csv" });
    defer std.testing.allocator.free(csv_b);

    const line_a = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"type\":\"response_item\",\"payload\":{{\"type\":\"function_call\",\"name\":\"spawn_agents_on_csv\",\"arguments\":\"{{\\\"csv_path\\\":\\\"{s}\\\",\\\"max_concurrency\\\":5}}\"}}}}\n",
        .{csv_a},
    );
    defer std.testing.allocator.free(line_a);
    const line_b = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"type\":\"response_item\",\"payload\":{{\"type\":\"function_call\",\"name\":\"spawn_agents_on_csv\",\"arguments\":\"{{\\\"csv_path\\\":\\\"{s}\\\",\\\"max_workers\\\":5}}\"}}}}\n",
        .{csv_b},
    );
    defer std.testing.allocator.free(line_b);
    const line_c =
        "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"spawn_agents_on_csv\",\"arguments\":\"{\\\"max_concurrency\\\":2}\"}}\n";

    const session_content = try std.mem.concat(std.testing.allocator, u8, &.{ line_a, line_b, line_c });
    defer std.testing.allocator.free(session_content);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "rollout-2026-02-28T00-00-00-019ca0e5-0beb-7740-a9bc-81664d994266.jsonl",
        .data = session_content,
    });

    const session_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "rollout-2026-02-28T00-00-00-019ca0e5-0beb-7740-a9bc-81664d994266.jsonl" });
    defer std.testing.allocator.free(session_path);

    const summary = try summarizeSessionConcurrency(std.testing.allocator, session_path);
    try std.testing.expectEqualStrings("019ca0e5-0beb-7740-a9bc-81664d994266", summary.session_id);
    try std.testing.expectEqual(@as(i64, 3), summary.spawn_calls);
    try std.testing.expectEqualStrings("spawn_agents_on_csv", summary.spawn_substrate);
    try std.testing.expectEqual(@as(i64, 0), summary.spawn_agent_calls);
    try std.testing.expectEqual(@as(i64, 0), summary.wait_calls);
    try std.testing.expectEqual(@as(i64, 0), summary.close_agent_calls);
    try std.testing.expectEqual(@as(?i64, 5), summary.max_configured_concurrency);
    try std.testing.expectEqual(@as(i64, 2), summary.max_configured_occurrences);
    try std.testing.expectEqual(@as(?i64, 3), summary.max_effective_concurrency);
    try std.testing.expectEqual(@as(i64, 1), summary.max_effective_occurrences);
    try std.testing.expectEqual(@as(i64, 2), summary.csv_rows_known);
    try std.testing.expectEqual(@as(i64, 1), summary.csv_rows_missing);
    try std.testing.expectEqual(@as(?i64, 3), summary.max_observed_csv_rows);
    try std.testing.expectEqual(@as(i64, 2), summary.serialized_wait_calls);

    const floor_eval = evaluateFloor(summary, 3);
    try std.testing.expect(floor_eval.applicable);
    try std.testing.expectEqualStrings("pass", floor_eval.result);
}

test "summarizeSessionConcurrency reports mesh truth false for spawn_agent-only sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_content =
        "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"spawn_agent\",\"arguments\":\"{\\\"agent_type\\\":\\\"awaiter\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"wait\",\"arguments\":\"{\\\"ids\\\":[\\\"A\\\"]}\"}}\n" ++
        "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"close_agent\",\"arguments\":\"{\\\"id\\\":\\\"A\\\"}\"}}\n";

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "rollout-2026-03-02T00-00-00-019caeb9-23af-7de2-985b-3d954b4df213.jsonl",
        .data = session_content,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const session_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "rollout-2026-03-02T00-00-00-019caeb9-23af-7de2-985b-3d954b4df213.jsonl" });
    defer std.testing.allocator.free(session_path);

    const summary = try summarizeSessionConcurrency(std.testing.allocator, session_path);
    try std.testing.expectEqual(@as(i64, 0), summary.spawn_calls);
    try std.testing.expectEqual(@as(i64, 1), summary.spawn_agent_calls);
    try std.testing.expectEqual(@as(i64, 1), summary.wait_calls);
    try std.testing.expectEqual(@as(i64, 1), summary.close_agent_calls);
    try std.testing.expectEqualStrings("spawn_agent", summary.spawn_substrate);
    try std.testing.expect(!summary.meshTruthVerdict());

    const floor_eval = evaluateFloor(summary, 3);
    try std.testing.expect(!floor_eval.applicable);
    try std.testing.expectEqualStrings("not_applicable", floor_eval.result);
}

test "evaluateFloor reports not_applicable when runnable floor is not met" {
    const summary = ConcurrencySummary{
        .session_id = "s",
        .session_path = "p",
        .spawn_calls = 1,
        .max_observed_csv_rows = 2,
        .max_effective_concurrency = 2,
    };
    const floor_eval = evaluateFloor(summary, 3);
    try std.testing.expect(!floor_eval.applicable);
    try std.testing.expectEqualStrings("not_applicable", floor_eval.result);
}

test "parse options supports common flags" {
    const args = [_][]const u8{
        "--format",
        "jsonl",
        "--root",
        "~/sessions",
        "--path",
        "/tmp/session.jsonl",
        "--session-id",
        "019ca0e5-0beb-7740-a9bc-81664d994266",
        "--floor-threshold",
        "4",
        "--fail-on-floor",
        "--fail-on-mesh-truth",
        "--max",
        "7",
        "--cue-spec",
        "@cues.json",
        "--discovery-skills",
        "grill-me,prove-it",
        "--roles",
        "user,assistant",
        "--contains",
        "needle",
        "--regex",
        "^foo",
        "--role",
        "assistant",
        "--tool",
        "bash",
        "--repo",
        "/Users/tk/workspace/tk/shift",
        "--status",
        "completed",
        "--mode",
        "normal",
        "--part-type",
        "file",
        "--tz",
        "local",
        "--session",
        "ses_abc",
        "--since",
        "1772700000000",
        "--until",
        "2026-03-05T00:00:00Z",
        "--last",
        "24h",
        "--group-by",
        "mode",
        "--metric",
        "count::count",
        "--pricing",
        "api",
        "--model",
        "gpt-5.5",
        "--reasoning-effort",
        "high",
        "--select",
        "mode,input_len",
        "--sort",
        "-count,mode",
        "--opencode-db-path",
        "/tmp/opencode.db",
        "--opencode-path",
        "/tmp/prompt-history.jsonl",
        "--source",
        "db",
        "--history",
        "distinct",
        "--include-raw",
        "--include-body",
        "--strip-skill-blocks",
        "--no-dedupe-exact",
        "--summary",
        "--audit",
        "--show-query",
        "--exclude-current",
        "--next-actions",
        "--current",
        "--latest",
        "--strict-hang",
        "--threshold-ms",
        "12000",
        "--window-hours",
        "6",
        "--duration-gte",
        "2h",
        "--fail-on-hang",
        "--help",
    };
    const opts = try parseOptions(args[0..]);
    try std.testing.expectEqual(output.Format.jsonl, opts.format);
    try std.testing.expect(opts.format_set);
    try std.testing.expectEqualStrings("~/sessions", opts.root.?);
    try std.testing.expectEqualStrings("/tmp/session.jsonl", opts.path.?);
    try std.testing.expectEqualStrings("019ca0e5-0beb-7740-a9bc-81664d994266", opts.session_id.?);
    try std.testing.expectEqualStrings("distinct", opts.history_text.?);
    try std.testing.expectEqual(@as(i64, 4), opts.floor_threshold);
    try std.testing.expect(opts.fail_on_floor);
    try std.testing.expect(opts.fail_on_mesh_truth);
    try std.testing.expectEqual(@as(usize, 7), opts.limit);
    try std.testing.expectEqualStrings("@cues.json", opts.cue_spec_text.?);
    try std.testing.expectEqualStrings("grill-me,prove-it", opts.discovery_skills.?);
    try std.testing.expectEqualStrings("user,assistant", opts.roles_csv.?);
    try std.testing.expectEqualStrings("needle", opts.contains.?);
    try std.testing.expectEqualStrings("^foo", opts.regex.?);
    try std.testing.expectEqualStrings("assistant", opts.role.?);
    try std.testing.expectEqualStrings("bash", opts.tool.?);
    try std.testing.expectEqualStrings("/Users/tk/workspace/tk/shift", opts.repo_text.?);
    try std.testing.expectEqualStrings("completed", opts.status.?);
    try std.testing.expectEqualStrings("normal", opts.mode.?);
    try std.testing.expectEqualStrings("file", opts.part_type.?);
    try std.testing.expectEqualStrings("local", opts.timezone_text.?);
    try std.testing.expectEqualStrings("ses_abc", opts.session.?);
    try std.testing.expectEqualStrings("1772700000000", opts.since.?);
    try std.testing.expectEqualStrings("2026-03-05T00:00:00Z", opts.until.?);
    try std.testing.expectEqualStrings("24h", opts.last_text.?);
    try std.testing.expectEqualStrings("mode", opts.group_by_text.?);
    try std.testing.expectEqualStrings("count::count", opts.metric_text.?);
    try std.testing.expectEqualStrings("api", opts.pricing_text.?);
    try std.testing.expectEqualStrings("gpt-5.5", opts.model_text.?);
    try std.testing.expectEqualStrings("high", opts.reasoning_effort_text.?);
    try std.testing.expectEqualStrings("mode,input_len", opts.select_text.?);
    try std.testing.expectEqualStrings("-count,mode", opts.sort_text.?);
    try std.testing.expectEqualStrings("/tmp/opencode.db", opts.opencode_db_path.?);
    try std.testing.expectEqualStrings("/tmp/prompt-history.jsonl", opts.opencode_path.?);
    try std.testing.expectEqualStrings("db", opts.opencode_source_text.?);
    try std.testing.expect(opts.include_raw);
    try std.testing.expect(opts.include_body);
    try std.testing.expect(opts.strip_skill_blocks);
    try std.testing.expect(opts.no_dedupe_exact);
    try std.testing.expect(opts.summary);
    try std.testing.expect(opts.audit);
    try std.testing.expect(opts.show_query);
    try std.testing.expect(opts.exclude_current);
    try std.testing.expect(opts.next_actions);
    try std.testing.expect(opts.current);
    try std.testing.expect(opts.latest);
    try std.testing.expect(opts.strict_hang);
    try std.testing.expectEqual(@as(i64, 12000), opts.threshold_ms);
    try std.testing.expectEqual(@as(i64, 6), opts.window_hours);
    try std.testing.expectEqual(@as(i64, 7200), opts.duration_gte_seconds.?);
    try std.testing.expect(opts.fail_on_hang);
    try std.testing.expect(opts.help);
}

test "token-usage summary rebuckets by timezone and computes averages from exact bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/26");
    const session_rel = "2026/03/26/rollout-2026-03-26T00-00-00-019c0000-0000-7000-8000-000000000099.jsonl";
    const session_content =
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T00:10:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":4,\"cached_input_tokens\":1,\"output_tokens\":1,\"reasoning_output_tokens\":0,\"total_tokens\":5}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T07:10:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":2,\"output_tokens\":2,\"reasoning_output_tokens\":1,\"total_tokens\":12}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-27T00:20:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":16,\"cached_input_tokens\":4,\"output_tokens\":4,\"reasoning_output_tokens\":2,\"total_tokens\":20}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-27T08:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":25,\"cached_input_tokens\":5,\"output_tokens\":5,\"reasoning_output_tokens\":3,\"total_tokens\":30}}}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "token-usage-summary.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--since",
        "2026-03-26T00:00:00-07:00",
        "--until",
        "2026-03-27T23:59:59-07:00",
        "--tz",
        "-07:00",
        "--summary",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .token_usage, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"total_tokens\": 25") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"input_tokens\": 21") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"cached_input_tokens\": 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"uncached_input_tokens\": 17") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"output_tokens\": 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"reasoning_output_tokens\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"calendar_days\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"active_days\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"average_tokens_per_calendar_day\": 12.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"average_tokens_per_active_day\": 12.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"median_tokens_per_active_day\": 12.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"first_day\": \"2026-03-26\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"last_day\": \"2026-03-27\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"partial_current_day\": false") != null);
}

test "token command window resolves --last against explicit until" {
    const opts = Options{
        .last_text = "24h",
        .until = "2026-03-27T08:00:00Z",
    };
    const window = try resolveTokenCommandWindow(opts);
    try std.testing.expectEqual(@as(?i64, time_utils.parseIsoTimestampMillis("2026-03-26T08:00:00Z").?), window.since_ms);
    try std.testing.expectEqual(@as(?i64, time_utils.parseIsoTimestampMillis("2026-03-27T08:00:00Z").?), window.until_ms);
    try std.testing.expectEqual(@as(?i64, 86_400_000), window.last_ms);
}

test "token-usage audit summary reports duplicate/reset/null/missing-total proof fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/26");
    const session_rel = "2026/03/26/rollout-2026-03-26T00-00-00-019c0000-0000-7000-8000-000000000100.jsonl";
    const session_content =
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T07:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":null}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T07:10:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":10},\"last_token_usage\":{\"total_tokens\":10}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T07:11:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":10},\"last_token_usage\":{\"total_tokens\":7}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T07:12:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":4}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T07:13:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":25},\"last_token_usage\":{\"total_tokens\":15}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T07:14:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":5},\"last_token_usage\":{\"total_tokens\":5}}}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "token-usage-audit-summary.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",    root_abs,
        "--since",   "2026-03-26T00:00:00-07:00",
        "--until",   "2026-03-27T00:00:00-07:00",
        "--tz",      "-07:00",
        "--summary", "--audit",
        "--format",  "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .token_usage, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"row_kind\": \"summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"total_tokens\": 30") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"calendar_days\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"last_day\": \"2026-03-26\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"rows\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"raw_token_count_events\": 6") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"raw_token_count_info_null_events\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"raw_token_count_without_total_events\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"duplicate_total_events\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"duplicate_total_nonzero_last_events\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"duplicate_last_tokens_excluded\": 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"reset_events\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"audit_total_tokens\": 30") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"naive_last_total_tokens\": 41") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"naive_overcount_tokens\": 11") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"requested_span_days\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"observed_span_days\": 1") != null);
}

test "token-usage audit grouped output appends aggregate audit row after trimming buckets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/26");
    const session_rel = "2026/03/26/rollout-2026-03-26T00-00-00-019c0000-0000-7000-8000-000000000101.jsonl";
    const session_content =
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T07:10:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":10},\"last_token_usage\":{\"total_tokens\":10}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T07:11:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":10},\"last_token_usage\":{\"total_tokens\":7}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-26T07:13:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":25},\"last_token_usage\":{\"total_tokens\":15}}}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "token-usage-audit-grouped.jsonl" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",  root_abs,
        "--since", "2026-03-26T00:00:00-07:00",
        "--until", "2026-03-27T00:00:00-07:00",
        "--tz",    "-07:00",
        "--audit", "--top",
        "1",       "--format",
        "jsonl",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .token_usage, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"row_kind\":\"bucket\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"row_kind\":\"audit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"audit_total_tokens\":25") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"duplicate_last_tokens_excluded\":7") != null);
}

test "token-cost summary applies explicit fast multiplier and user USD conversion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/05/13");
    const session_rel = "2026/05/13/rollout-token-cost-fast.jsonl";
    const session_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-13T10:00:00Z\",\"payload\":{\"model\":\"gpt-5.4\"}}\n" ++
        "{\"type\":\"turn_context\",\"timestamp\":\"2026-05-13T10:00:01Z\",\"payload\":{\"model\":\"gpt-5.4\",\"service_tier\":\"fast\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-13T10:00:02Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000000,\"cached_input_tokens\":250000,\"output_tokens\":100000,\"reasoning_output_tokens\":0,\"total_tokens\":1100000}}}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "token-cost-fast.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",    root_abs,
        "--summary", "--usd-per-credit",
        "0.01",      "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .token_cost, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"credits_estimate\": 171.875") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"usd_estimate\": 1.71875") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"fast_mode\": \"fast\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"fast_mode_source\": \"trace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"cost_confidence\": \"trace_fast\"") != null);
}

test "token-cost marks missing fast evidence as standard assumption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/05/13");
    const session_rel = "2026/05/13/rollout-token-cost-unknown.jsonl";
    const session_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-13T10:00:00Z\",\"payload\":{\"model\":\"gpt-5.5\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-13T10:00:02Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":100,\"output_tokens\":100,\"total_tokens\":1200}}}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "token-cost-unknown.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",    root_abs,
        "--summary", "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .token_cost, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"usd_estimate\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"fast_mode\": \"unknown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"fast_mode_source\": \"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"cost_confidence\": \"standard_assumption\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"priced_standard_assumption_credits\": 0.18875") != null);
}

test "token-cost summary counts unpriced tokens once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/05/13");
    const session_rel = "2026/05/13/rollout-token-cost-unpriced.jsonl";
    const session_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-13T10:00:00Z\",\"payload\":{\"model\":\"unknown-model\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-13T10:00:02Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":100,\"output_tokens\":100,\"total_tokens\":1200}}}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "token-cost-unpriced.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",    root_abs,
        "--summary", "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .token_cost, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"priced_rows\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"unpriced_rows\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"unpriced_tokens\": 1200") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"unpriced_tokens\": 2400") == null);
}

test "token-cost api pricing uses explicit model override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/05/22");
    const session_rel = "2026/05/22/rollout-token-cost-api-override.jsonl";
    const session_content =
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-22T10:00:02Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":100,\"output_tokens\":100,\"reasoning_output_tokens\":10,\"total_tokens\":1100}}}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "token-cost-api-override.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",    root_abs,
        "--summary", "--pricing",
        "api",       "--model",
        "gpt-5.5",   "--reasoning-effort",
        "high",      "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .token_cost, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"pricing_kind\": \"api\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"usd_estimate\": 0.0075") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"credits_estimate\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"model_source\": \"override\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"reasoning_effort\": \"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"cost_confidence\": \"api_exact\"") != null);
}

test "token-cost api pricing fails closed without exact model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/05/22");
    const session_rel = "2026/05/22/rollout-token-cost-api-missing-model.jsonl";
    const session_content =
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-22T10:00:02Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":100,\"output_tokens\":100,\"total_tokens\":1100}}}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "token-cost-api-missing-model.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--summary",
        "--pricing",
        "api",
        "--format",
        "json",
    };
    try std.testing.expectError(error.ApiPricingModelRequired, runCommandWithOutput(std.testing.allocator, .token_cost, args[0..], output_path));
}

test "token-cost api pricing reports GPT-5.5 long-context surcharge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/05/22");
    const session_rel = "2026/05/22/rollout-token-cost-api-long-context.jsonl";
    const session_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-22T10:00:00Z\",\"payload\":{\"model\":\"gpt-5.5\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-22T10:00:02Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":300000,\"cached_input_tokens\":0,\"output_tokens\":20000,\"reasoning_output_tokens\":5000,\"total_tokens\":320000}}}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "token-cost-api-long-context.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",    root_abs,
        "--summary", "--pricing",
        "api",       "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .token_cost, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"usd_estimate\": 3.9") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"api_long_context_surcharge_usd\": 1.799") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"long_context_priced_rows\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"cost_confidence\": \"api_exact_long_context\"") != null);
}

test "parseOptions rejects unknown option" {
    const args = [_][]const u8{"--bogus"};
    try std.testing.expectError(error.UnknownArgument, parseOptions(args[0..]));
}

test "validateCommandOptions rejects unsupported path on skill-report" {
    const opts = Options{ .path = "/tmp/session.jsonl" };
    try std.testing.expectError(error.UnsupportedOption, validateCommandOptions(.skill_report, opts));
}

test "validateCommandOptions rejects unsupported audit on skill-report" {
    const opts = Options{ .audit = true };
    try std.testing.expectError(error.UnsupportedOption, validateCommandOptions(.skill_report, opts));
}

test "validateFormatForCommand rejects table for skill-blocks" {
    try std.testing.expectError(error.InvalidFormatForCommand, validateFormatForCommand(.skill_blocks, .table));
}

fn runCommandWithOutput(
    allocator: std.mem.Allocator,
    cmd: lib.Command,
    args: []const []const u8,
    output_path: []const u8,
) ![]u8 {
    var all_args: std.ArrayList([]const u8) = .empty;
    defer all_args.deinit(allocator);
    try all_args.appendSlice(allocator, args);
    try all_args.append(allocator, "--output");
    try all_args.append(allocator, output_path);

    try run(allocator, cmd, all_args.items);

    const file = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), output_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(1 * 1024 * 1024));
}

test "query-lift commands run over session fixtures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "sessions/2026/05/01");
    const session_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-01T10:00:00Z\",\"payload\":{\"id\":\"lift-session\",\"cwd\":\"/repo\",\"model\":\"gpt-5\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-01T10:00:01Z\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-1\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-01T10:00:02Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Need $seq release workflow\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-01T10:00:03Z\",\"payload\":{\"type\":\"agent_message\",\"message\":\"Use $zig too\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-01T10:00:04Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"exec-1\",\"arguments\":\"{\\\"cmd\\\":\\\"zig build test-seq\\\",\\\"cwd\\\":\\\"/repo\\\"}\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-01T10:00:05Z\",\"payload\":{\"type\":\"exec_command_end\",\"turn_id\":\"turn-1\",\"call_id\":\"exec-1\",\"command\":\"zig build test-seq\",\"cwd\":\"/repo\",\"exit_code\":0,\"duration_ms\":12,\"stdout\":\"ok\",\"status\":\"completed\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-05-01T10:00:06Z\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-1\",\"duration_ms\":4000}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "sessions/2026/05/01/rollout-lift-session.jsonl",
        .data = session_content,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "sessions", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "query-lift.jsonl" });
    defer std.testing.allocator.free(output_path);

    {
        const got = try runCommandWithOutput(std.testing.allocator, .skill_audit, &.{ "--root", root_abs, "--skill", "seq", "--format", "jsonl" }, output_path);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "\"skill\":\"seq\"") != null);
    }
    {
        const got = try runCommandWithOutput(std.testing.allocator, .message_search, &.{ "--root", root_abs, "--contains", "release workflow", "--format", "jsonl" }, output_path);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "release workflow") != null);
    }
    {
        const got = try runCommandWithOutput(std.testing.allocator, .tool_audit, &.{ "--root", root_abs, "--tool", "exec_command", "--format", "jsonl" }, output_path);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "\"tool_name\":\"exec_command\"") != null);
    }
    {
        const got = try runCommandWithOutput(std.testing.allocator, .workdir_report, &.{ "--root", root_abs, "--workdir", "/repo", "--format", "jsonl" }, output_path);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "\"cwd\":\"/repo\"") != null);
    }
}

test "query joins session datasets by path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "sessions/2026/05/02");
    const session_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-02T10:00:00Z\",\"payload\":{\"id\":\"join-session\",\"cwd\":\"/repo/seq\",\"model\":\"gpt-5\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-02T10:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"workflow needle for joins\"}]}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "sessions/2026/05/02/rollout-join-session.jsonl",
        .data = session_content,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "sessions", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "query-join.jsonl" });
    defer std.testing.allocator.free(output_path);

    const join_spec =
        \\{"dataset":"messages","joins":[{"dataset":"sessions","left":"path","right":"path","type":"left","prefix":"session"}],"where":[{"field":"text","op":"contains","value":"workflow needle"}],"select":["role","session.cwd","text"],"format":"jsonl"}
    ;
    const got = try runCommandWithOutput(std.testing.allocator, .query, &.{ "--root", root_abs, "--spec", join_spec }, output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"session.cwd\":\"/repo/seq\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "workflow needle for joins") != null);
}

test "workflow_signals strips skill blocks and preserves source kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "sessions/2026/05/03");
    const session_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-03T10:00:00Z\",\"payload\":{\"id\":\"signal-session\",\"cwd\":\"/repo/seq\",\"model\":\"gpt-5\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-03T10:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Use $seq for this audit\\n<skill>\\n<name>fixed-point-driver</name>\\n</skill>\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-03T10:00:02Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Validation proof: zig build test passed\"}]}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "sessions/2026/05/03/rollout-signal-session.jsonl",
        .data = session_content,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "sessions", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "workflow-signals.jsonl" });
    defer std.testing.allocator.free(output_path);

    const signal_spec =
        \\{"dataset":"workflow_signals","select":["source_kind","signal_kind","name","outcome_kind","contamination_flags"],"sort":["signal_kind","name"],"format":"jsonl"}
    ;
    const got = try runCommandWithOutput(std.testing.allocator, .query, &.{ "--root", root_abs, "--spec", signal_spec }, output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"source_kind\":\"user_prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"signal_kind\":\"workflow_mention\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"name\":\"seq\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"signal_kind\":\"outcome\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"outcome_kind\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "fixed-point-driver") == null);
}

test "workflow-audit reports a workflow cohort without cross-session contamination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "sessions/2026/05/04");
    const target_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-04T10:00:00Z\",\"payload\":{\"id\":\"workflow-target\",\"cwd\":\"/repo/target\",\"model\":\"gpt-5\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-04T10:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Use $fixed-point-driver with $seq\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-04T10:00:02Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Validation proof: zig build test passed\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-04T10:00:03Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"exec-1\",\"arguments\":\"{\\\"cmd\\\":\\\"zig build test-seq\\\",\\\"cwd\\\":\\\"/repo/target\\\"}\"}}\n";
    const other_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-04T11:00:00Z\",\"payload\":{\"id\":\"workflow-other\",\"cwd\":\"/repo/other\",\"model\":\"gpt-5\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-04T11:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Use $seq only\"}]}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "sessions/2026/05/04/rollout-workflow-target.jsonl",
        .data = target_content,
    });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "sessions/2026/05/04/rollout-workflow-other.jsonl",
        .data = other_content,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "sessions", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "workflow-audit.out" });
    defer std.testing.allocator.free(output_path);

    {
        const got = try runCommandWithOutput(std.testing.allocator, .workflow_audit, &.{ "--root", root_abs, "--workflow", "fixed-point-driver", "--mode", "signals", "--workdir", "/repo/target", "--format", "json" }, output_path);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "workflow-target") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "workflow-other") == null);
        try std.testing.expect(std.mem.indexOf(u8, got, "\"signal_kind\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "\"outcome\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "\"tool_trace\"") != null);
    }

    {
        const got = try runCommandWithOutput(std.testing.allocator, .workflow_audit, &.{ "--root", root_abs, "--workflow", "fixed-point-driver", "--mode", "report" }, output_path);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "# seq workflow-audit: fixed-point-driver") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "## Signal Summary") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "cohort_sessions: 1") != null);
    }

    {
        const got = try runCommandWithOutput(std.testing.allocator, .workflow_audit, &.{ "--root", root_abs, "--workflow", "fixed-point-driver", "--mode", "report", "--format", "json", "--limit", "1" }, output_path);
        defer std.testing.allocator.free(got);
        const first_timestamp = std.mem.indexOf(u8, got, "\"timestamp\"") orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOfPos(u8, got, first_timestamp + 1, "\"timestamp\"") == null);
    }

    {
        const got = try runCommandWithOutput(std.testing.allocator, .workflow_audit, &.{ "--root", root_abs, "--workflow", "fixed-point-driver", "--mode", "signals", "--format", "markdown", "--limit", "1" }, output_path);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "# seq workflow-audit: fixed-point-driver (signals)") != null);
        try std.testing.expect(std.mem.indexOf(u8, got, "## Outcomes") == null);
        const first_row = std.mem.indexOf(u8, got, "| 2026-") orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOfPos(u8, got, first_row + 1, "| 2026-") == null);
    }
}

test "skill-success-rank counts called skills with positive outcomes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "sessions/2026/05/05");
    const prove_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-05T10:00:00Z\",\"payload\":{\"id\":\"prove-session\",\"cwd\":\"/repo/seq\",\"model\":\"gpt-5\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-05T10:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Use $prove-it on this claim\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-05T10:00:02Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Using `prove-it` for the driver.\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-05T10:00:03Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Proof complete. Validation passed and committed.\"}]}}\n";
    const base_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-05T11:00:00Z\",\"payload\":{\"id\":\"base-session\",\"cwd\":\"/repo/seq\",\"model\":\"gpt-5\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-05T11:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Run codex review --base main. Proof available.\"}]}}\n";
    const blocked_content =
        "{\"type\":\"session_meta\",\"timestamp\":\"2026-05-05T12:00:00Z\",\"payload\":{\"id\":\"blocked-session\",\"cwd\":\"/repo/seq\",\"model\":\"gpt-5\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-05T12:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Use $cas\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-05-05T12:00:02Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Blocked waiting for credentials.\"}]}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "sessions/2026/05/05/rollout-prove-session.jsonl",
        .data = prove_content,
    });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "sessions/2026/05/05/rollout-base-session.jsonl",
        .data = base_content,
    });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "sessions/2026/05/05/rollout-blocked-session.jsonl",
        .data = blocked_content,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "sessions", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const summary_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "skill-success-summary.json" });
    defer std.testing.allocator.free(summary_out);

    const summary = try runCommandWithOutput(std.testing.allocator, .skill_success_rank, &.{ "--root", root_abs, "--since", "2026-05-05T00:00:00Z", "--until", "2026-05-06T00:00:00Z", "--format", "json" }, summary_out);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"skill\": \"prove-it\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"successful_sessions\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"skill\": \"base\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"skill\": \"cas\"") == null);

    const sessions_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "skill-success-sessions.jsonl" });
    defer std.testing.allocator.free(sessions_out);
    const sessions = try runCommandWithOutput(std.testing.allocator, .skill_success_rank, &.{ "--root", root_abs, "--skill", "cas", "--mode", "sessions", "--format", "jsonl" }, sessions_out);
    defer std.testing.allocator.free(sessions);
    try std.testing.expect(std.mem.indexOf(u8, sessions, "\"skill\":\"cas\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sessions, "\"successful\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, sessions, "\"blocked\":true") != null);
}

test "memory-inventory summarizes memory file categories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "mem/rollout_summaries");
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "mem/MEMORY.md", .data = "# Memory\n" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "mem/rollout_summaries/example.md", .data = "# Summary\n" });

    const memory_root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "mem", std.testing.allocator);
    defer std.testing.allocator.free(memory_root);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ memory_root, "memory-inventory.jsonl" });
    defer std.testing.allocator.free(output_path);

    const got = try runCommandWithOutput(std.testing.allocator, .memory_inventory, &.{ "--memory-root", memory_root, "--format", "jsonl" }, output_path);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"category\":\"rollout_summaries\"") != null);
}

test "session-prompts resolves a single targeted file and supports role filters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/10");
    const target_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Before\\n<skill>\\n<name>seq</name>\\n</skill>\\nAfter\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Echo: prompt\\n\\nAnswer\"}]}}\n";
    const other_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2025-10-20T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Older session\"}]}}\n";

    const target_rel = "2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000010.jsonl";
    const other_rel = "2026/03/10/rollout-2025-10-20T10-00-00-019a0000-0000-7000-8000-000000000011.jsonl";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = target_rel, .data = target_content });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = other_rel, .data = other_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const target_abs = try std.fs.path.join(std.testing.allocator, &.{ root_abs, target_rel });
    defer std.testing.allocator.free(target_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "session-prompts.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--path",
        target_abs,
        "--roles",
        "user,assistant",
        "--strip-skill-blocks",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .session_prompts, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, target_abs) != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Older session") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"role\": \"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Before\\n\\nAfter") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Echo:") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"text\": \"Answer\"") != null);
}

test "session-prompts preserves duplicates when no-dedupe-exact is set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/10");
    const session_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"repeat\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-10T10:00:01Z\",\"payload\":{\"type\":\"user_message\",\"message\":\"repeat\"}}\n";
    const session_rel = "2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000012.jsonl";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "session-prompts-dupes.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--session-id",
        "019c0000-0000-7000-8000-000000000012",
        "--no-dedupe-exact",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .session_prompts, args[0..], output_path);
    defer std.testing.allocator.free(got);

    const first = std.mem.indexOf(u8, got, "\"text\": \"repeat\"") orelse unreachable;
    try std.testing.expect(std.mem.indexOfPos(u8, got, first + 1, "\"text\": \"repeat\"") != null);
}

test "reply-latency defaults to single-message mode with clipped previews" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/10");
    const session_rel = "2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000030.jsonl";
    const session_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Single longest\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:01:30.250Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"First reply\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:02:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Part one\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-10T10:02:05Z\",\"payload\":{\"type\":\"user_message\",\"message\":\"Part two\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:03:10.500Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Grouped reply\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:03:20Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Quick prompt\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-10T10:03:25.125Z\",\"payload\":{\"type\":\"agent_message\",\"message\":\"Echo: prior question\\n\\nReply after echo\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:03:30Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"repeat\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-10T10:03:31Z\",\"payload\":{\"type\":\"user_message\",\"message\":\"repeat\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:03:45Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Duplicate reply\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:04:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Trailing user\"}]}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const session_abs = try std.fs.path.join(std.testing.allocator, &.{ root_abs, session_rel });
    defer std.testing.allocator.free(session_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "reply-latency-default.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--path",
        session_abs,
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .reply_latency, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"mode\": \"single-message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"turn_index\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"turn_index\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"duration_seconds\": 90.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"duration_seconds\": 5.125") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"user_preview\": \"Single longest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"assistant_preview\": \"Reply after echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Part one | Part two") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "repeat | repeat") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Trailing user") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Echo:") == null);
}

test "reply-latency contiguous mode preserves multi-message blocks and filters by start timestamp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/10");
    const session_rel = "2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000031.jsonl";
    const session_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Before window\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:10Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Skip me\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:02:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Part one\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-10T10:02:05Z\",\"payload\":{\"type\":\"user_message\",\"message\":\"Part two\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:03:10.500Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Grouped reply\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:03:20Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Quick prompt\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:03:25.125Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Quick reply\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:03:30Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"repeat\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-10T10:03:31Z\",\"payload\":{\"type\":\"user_message\",\"message\":\"repeat\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:03:45Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Duplicate reply\"}]}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "reply-latency-contiguous.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--mode",
        "contiguous",
        "--since",
        "2026-03-10T10:02:00Z",
        "--until",
        "2026-03-10T10:03:29Z",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .reply_latency, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"mode\": \"contiguous\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"turn_index\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"turn_index\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"user_preview\": \"Part one | Part two\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"duration_seconds\": 70.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"user_preview\": \"Quick prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Duplicate reply") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Before window") == null);
}

test "reply-latency skips invalid and incomplete turns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/10");
    const session_rel = "2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000032.jsonl";
    const session_content =
        "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"missing start\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:10Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"should skip\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:01:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"missing end\"}]}}\n" ++
        "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"still skip\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:02:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"valid\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:02:02.250Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"kept\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:03:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"trailing\"}]}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "reply-latency-invalid.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--mode",
        "contiguous",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .reply_latency, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"user_preview\": \"valid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"duration_seconds\": 2.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "missing start") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "missing end") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "trailing") == null);
}

test "plan-search extracts strict proposed_plan blocks from a targeted file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/10");
    const session_rel = "2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000013.jsonl";
    const session_content =
        "{\"timestamp\":\"2026-03-10T10:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"019c0000-0000-7000-8000-000000000013\",\"cwd\":\"/Users/tk/workspace/tk/shift\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Echo: prompt\\n\\n<proposed_plan>\\nIteration: 4\\n# First\\nBody\\n</proposed_plan>\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:02Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"<proposed_plan>\\nIteration: 5\\n# Broken\"}]}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const session_abs = try std.fs.path.join(std.testing.allocator, &.{ root_abs, session_rel });
    defer std.testing.allocator.free(session_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "plan-search.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--path",
        session_abs,
        "--include-body",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .plan_search, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"title\": \"# First\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"iteration\": \"Iteration: 4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"plan_index\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"plan_block\": \"<proposed_plan>\\nIteration: 4\\n# First\\nBody\\n</proposed_plan>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Echo:") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Broken") == null);
}

test "plan-search applies repo filter, stats, and chronological sort" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "sessions/2026/03/10");
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "sessions/2026/03/11");
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "repos/repo-a");
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "repos/repo-b");

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const sessions_abs = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "sessions" });
    defer std.testing.allocator.free(sessions_abs);
    const repo_a = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "repos/repo-a" });
    defer std.testing.allocator.free(repo_a);
    const repo_a_nested = try std.fmt.allocPrint(std.testing.allocator, "{s}/nested", .{repo_a});
    defer std.testing.allocator.free(repo_a_nested);
    const repo_b = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "repos/repo-b" });
    defer std.testing.allocator.free(repo_b);

    const session_a_rel = "sessions/2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000014.jsonl";
    const session_b_rel = "sessions/2026/03/11/rollout-2026-03-11T10-00-00-019c0000-0000-7000-8000-000000000015.jsonl";
    const session_other_rel = "sessions/2026/03/11/rollout-2026-03-11T10-01-00-019c0000-0000-7000-8000-000000000016.jsonl";
    const session_a_content = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"timestamp\":\"2026-03-10T10:00:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"019c0000-0000-7000-8000-000000000014\",\"cwd\":\"{s}\"}}}}\n" ++
            "{{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:01Z\",\"payload\":{{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"<proposed_plan>\\nIteration: 1\\n# Older\\n</proposed_plan>\"}}]}}}}\n",
        .{repo_a},
    );
    defer std.testing.allocator.free(session_a_content);
    const session_b_content = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"timestamp\":\"2026-03-11T10:00:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"019c0000-0000-7000-8000-000000000015\",\"cwd\":\"{s}\"}}}}\n" ++
            "{{\"type\":\"response_item\",\"timestamp\":\"2026-03-11T10:00:01Z\",\"payload\":{{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"<proposed_plan>\\nIteration: 2\\n# Newer\\n</proposed_plan>\"}}]}}}}\n",
        .{repo_a_nested},
    );
    defer std.testing.allocator.free(session_b_content);
    const session_other_content = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"timestamp\":\"2026-03-11T10:01:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"019c0000-0000-7000-8000-000000000016\",\"cwd\":\"{s}\"}}}}\n" ++
            "{{\"type\":\"response_item\",\"timestamp\":\"2026-03-11T10:01:01Z\",\"payload\":{{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"<proposed_plan>\\nIteration: 9\\n# OtherRepo\\n</proposed_plan>\"}}]}}}}\n",
        .{repo_b},
    );
    defer std.testing.allocator.free(session_other_content);
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = session_a_rel,
        .data = session_a_content,
    });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = session_b_rel,
        .data = session_b_content,
    });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = session_other_rel,
        .data = session_other_content,
    });

    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "plan-search-stats.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        sessions_abs,
        "--repo",
        repo_a,
        "--sort",
        "timestamp",
        "--stats",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .plan_search, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "OtherRepo") == null);
    const older_idx = std.mem.indexOf(u8, got, "\"title\": \"# Older\"") orelse unreachable;
    const newer_idx = std.mem.indexOf(u8, got, "\"title\": \"# Newer\"") orelse unreachable;
    try std.testing.expect(older_idx < newer_idx);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"used_repo_filter\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"plan_blocks_found\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"candidate_files\": 3") != null);
}

test "session-tooling summary groups by primary executable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/05");
    const session_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:00Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"q1\",\"arguments\":\"{\\\"cmd\\\":\\\"seq query --spec @spec.json\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:12Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"q1\",\"output\":\"Chunk ID: aa\\nWall time: 12.250 seconds\\nProcess running with session ID 77\\nOutput:\\n\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:01:00Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"e1\",\"arguments\":\"{\\\"cmd\\\":\\\"rg -n foo\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:01:01Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"e1\",\"output\":\"Chunk ID: bb\\nWall time: 0.050 seconds\\nProcess exited with code 0\\nOutput:\\n\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:02:00Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"e2\",\"arguments\":\"{\\\"cmd\\\":\\\"jq .\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:02:01Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"e2\",\"output\":\"Chunk ID: cc\\nWall time: 0.090 seconds\\nProcess exited with code 2\\nOutput:\\n\"}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "2026/03/05/rollout-2026-03-05T00-00-00-019c0000-0000-7000-8000-000000000001.jsonl",
        .data = session_content,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "session-tooling-summary.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--summary",
        "--group-by",
        "executable",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .session_tooling, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"group_key\": \"seq\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"group_key\": \"rg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"group_key\": \"jq\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"error_count\": 1") != null);
}

test "goal_runs aggregates goal outputs and excludes review search contamination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/05/12");
    const session_content =
        "{\"timestamp\":\"2026-05-12T13:31:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"019e1c61-d92f-7dd2-b39f-976f70452d2a\",\"cwd\":\"/repo\",\"model\":\"gpt-test\"}}\n" ++
        "{\"timestamp\":\"2026-05-12T13:31:06Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"get_goal\",\"arguments\":\"{}\",\"call_id\":\"goal-1\"}}\n" ++
        "{\"timestamp\":\"2026-05-12T13:31:07Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"goal-1\",\"output\":\"{\\\"goal\\\":{\\\"threadId\\\":\\\"019e1c61-d92f-7dd2-b39f-976f70452d2a\\\",\\\"objective\\\":\\\"Run codex review until clean\\\",\\\"status\\\":\\\"active\\\",\\\"tokensUsed\\\":100,\\\"timeUsedSeconds\\\":12,\\\"createdAt\\\":1778592653,\\\"updatedAt\\\":1778592666},\\\"remainingTokens\\\":null,\\\"completionBudgetReport\\\":null}\"}}\n" ++
        "{\"timestamp\":\"2026-05-12T13:32:06Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"get_goal\",\"arguments\":\"{}\",\"call_id\":\"goal-other\"}}\n" ++
        "{\"timestamp\":\"2026-05-12T13:32:07Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"goal-other\",\"output\":\"{\\\"goal\\\":{\\\"threadId\\\":\\\"other-goal-thread\\\",\\\"objective\\\":\\\"Draft release notes\\\",\\\"status\\\":\\\"active\\\",\\\"tokensUsed\\\":40,\\\"timeUsedSeconds\\\":60,\\\"createdAt\\\":1778592700,\\\"updatedAt\\\":1778592760},\\\"remainingTokens\\\":null,\\\"completionBudgetReport\\\":null}\"}}\n" ++
        "{\"timestamp\":\"2026-05-12T13:35:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"review-1\",\"arguments\":\"{\\\"cmd\\\":\\\"codex review --base main\\\",\\\"workdir\\\":\\\"/repo\\\"}\"}}\n" ++
        "{\"timestamp\":\"2026-05-12T13:35:01Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"review-1\",\"output\":\"Chunk ID: aa\\nWall time: 1.000 seconds\\nProcess exited with code 0\\nOutput:\\n\"}}\n" ++
        "{\"timestamp\":\"2026-05-12T13:36:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"search-1\",\"arguments\":\"{\\\"cmd\\\":\\\"rg -n \\\\\\\"codex review\\\\\\\" .\\\",\\\"workdir\\\":\\\"/repo\\\"}\"}}\n" ++
        "{\"timestamp\":\"2026-05-12T13:37:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"help-1\",\"arguments\":\"{\\\"cmd\\\":\\\"codex review --help\\\",\\\"workdir\\\":\\\"/repo\\\"}\"}}\n" ++
        "{\"timestamp\":\"2026-05-12T15:31:06Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"update_goal\",\"arguments\":\"{\\\"status\\\":\\\"complete\\\"}\",\"call_id\":\"goal-2\"}}\n" ++
        "{\"timestamp\":\"2026-05-12T15:31:07Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"goal-2\",\"output\":\"{\\\"goal\\\":{\\\"threadId\\\":\\\"019e1c61-d92f-7dd2-b39f-976f70452d2a\\\",\\\"objective\\\":\\\"Run codex review until clean\\\",\\\"status\\\":\\\"complete\\\",\\\"tokensUsed\\\":200,\\\"timeUsedSeconds\\\":7200,\\\"createdAt\\\":1778592653,\\\"updatedAt\\\":1778599866},\\\"remainingTokens\\\":321,\\\"completionBudgetReport\\\":\\\"Goal achieved.\\\"}\"}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "2026/05/12/rollout-2026-05-12T06-30-35-019e1c61-d92f-7dd2-b39f-976f70452d2a.jsonl",
        .data = session_content,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);

    var rows = try collectDatasetRows(std.testing.allocator, "goal_runs", root_abs, &.{}, &.{});
    defer deinitQueryRows(std.testing.allocator, &rows);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    var found_review_row = false;
    var found_other_row = false;
    for (rows.items) |row| {
        if (scalarStringEq(row.valueOrNull("objective_kind"), "review")) {
            found_review_row = true;
            try std.testing.expect(scalarStringEq(row.valueOrNull("status"), "complete"));
            try std.testing.expectEqual(@as(i64, 7200), scalarAsInt(row.valueOrNull("time_used_seconds")).?);
            try std.testing.expectEqual(@as(i64, 1), scalarAsInt(row.valueOrNull("review_invocation_count")).?);
            try std.testing.expect(scalarStringEq(row.valueOrNull("contamination_flags"), "none"));
        } else if (scalarStringEq(row.valueOrNull("objective_kind"), "other")) {
            found_other_row = true;
            try std.testing.expectEqual(@as(i64, 0), scalarAsInt(row.valueOrNull("review_invocation_count")).?);
            try std.testing.expect(scalarStringEq(row.valueOrNull("contamination_flags"), "none"));
        }
    }
    try std.testing.expect(found_review_row);
    try std.testing.expect(found_other_row);

    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "goal-audit.json" });
    defer std.testing.allocator.free(output_path);
    const args = [_][]const u8{
        "--root",
        root_abs,
        "--workflow",
        "review,resolve",
        "--duration-gte",
        "2h",
        "--summary",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .goal_audit, args[0..], output_path);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"objective_kind\": \"review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"runs\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"review_invocations\": 1") != null);
}

test "query-diagnose flags strict hangs and supports fail-on-hang" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/05");
    const session_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:00Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"q1\",\"arguments\":\"{\\\"cmd\\\":\\\"seq query --spec @spec.json\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:12Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"q1\",\"output\":\"Chunk ID: aa\\nWall time: 12.250 seconds\\nProcess running with session ID 77\\nOutput:\\n\"}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "2026/03/05/rollout-2026-03-05T00-00-00-019c0000-0000-7000-8000-000000000002.jsonl",
        .data = session_content,
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "query-diagnose.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--threshold-ms",
        "10000",
        "--next-actions",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .query_diagnose, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"query_call_id\": \"q1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"hang_flag\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"resolution_state\": \"running_unresolved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"next_action\": \"seq session-tooling --path ") != null);

    const fail_args = [_][]const u8{
        "--root",
        root_abs,
        "--threshold-ms",
        "10000",
        "--fail-on-hang",
        "--format",
        "json",
        "--output",
        output_path,
    };
    try std.testing.expectError(error.QueryHangDetected, run(std.testing.allocator, .query_diagnose, fail_args[0..]));
}

test "query-lift commands run representative dataset wrappers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "sessions/2026/03/05");
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "memories/rollout_summaries");
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "memories/extensions/querylift");
    const session_content =
        "{\"timestamp\":\"2026-03-05T09:59:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"019c0000-0000-7000-8000-000000000101\",\"cwd\":\"/tmp/query-lift-repo\",\"model\":\"gpt-test\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Find this query lift needle with $plan\\n<skill>\\n<name>seq</name>\\n</skill>\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Using seq\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:02Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"q1\",\"arguments\":\"{\\\"cmd\\\":\\\"seq query --spec @spec.json\\\",\\\"workdir\\\":\\\"/tmp/query-lift-repo\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:03Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"q1\",\"output\":\"Chunk ID: aa\\nWall time: 0.120 seconds\\nProcess exited with code 0\\nOutput:\\n\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-05T10:00:04Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":10}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-05T10:30:04Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":25}}}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "sessions/2026/03/05/rollout-2026-03-05T00-00-00-019c0000-0000-7000-8000-000000000101.jsonl",
        .data = session_content,
    });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "memories/MEMORY.md",
        .data = "# Query Lift\n\nReusable seq command notes.\n",
    });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "memories/rollout_summaries/query-lift.md",
        .data = "# Query Lift Rollout\n\nrollout_path=/tmp/query-lift.jsonl\n",
    });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "memories/extensions/querylift/instructions.md",
        .data = "# Query Lift Extension\n",
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const sessions_abs = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "sessions" });
    defer std.testing.allocator.free(sessions_abs);
    const memories_abs = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "memories" });
    defer std.testing.allocator.free(memories_abs);

    const skill_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "skill-audit.json" });
    defer std.testing.allocator.free(skill_out);
    const skill_args = [_][]const u8{ "--root", sessions_abs, "--skill", "seq", "--format", "json" };
    const skill_got = try runCommandWithOutput(std.testing.allocator, .skill_audit, skill_args[0..], skill_out);
    defer std.testing.allocator.free(skill_got);
    try std.testing.expect(std.mem.indexOf(u8, skill_got, "\"skill\": \"seq\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill_got, "\"mentions\": 1") != null);

    const tool_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "tool-audit.json" });
    defer std.testing.allocator.free(tool_out);
    const tool_args = [_][]const u8{ "--root", sessions_abs, "--tool", "exec_command", "--group-by", "executable", "--format", "json" };
    const tool_got = try runCommandWithOutput(std.testing.allocator, .tool_audit, tool_args[0..], tool_out);
    defer std.testing.allocator.free(tool_got);
    try std.testing.expect(std.mem.indexOf(u8, tool_got, "\"primary_executable\": \"seq\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_got, "\"calls\": 1") != null);

    const memory_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "memory-inventory.json" });
    defer std.testing.allocator.free(memory_out);
    const memory_args = [_][]const u8{ "--memory-root", memories_abs, "--format", "json" };
    const memory_got = try runCommandWithOutput(std.testing.allocator, .memory_inventory, memory_args[0..], memory_out);
    defer std.testing.allocator.free(memory_got);
    try std.testing.expect(std.mem.indexOf(u8, memory_got, "\"category\": \"root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory_got, "\"category\": \"rollout_summaries\"") != null);

    const message_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "message-search.json" });
    defer std.testing.allocator.free(message_out);
    const message_args = [_][]const u8{ "--root", sessions_abs, "--contains", "query lift needle", "--roles", "user", "--format", "json" };
    const message_got = try runCommandWithOutput(std.testing.allocator, .message_search, message_args[0..], message_out);
    defer std.testing.allocator.free(message_got);
    try std.testing.expect(std.mem.indexOf(u8, message_got, "query lift needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, message_got, "\"role\": \"assistant\"") == null);

    const workdir_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "workdir-report.json" });
    defer std.testing.allocator.free(workdir_out);
    const workdir_args = [_][]const u8{ "--root", sessions_abs, "--workdir", "/tmp/query-lift-repo", "--format", "json" };
    const workdir_got = try runCommandWithOutput(std.testing.allocator, .workdir_report, workdir_args[0..], workdir_out);
    defer std.testing.allocator.free(workdir_got);
    try std.testing.expect(std.mem.indexOf(u8, workdir_got, "\"cwd\": \"/tmp/query-lift-repo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, workdir_got, "\"sessions\": 1") != null);

    const message_audit_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "message-audit.json" });
    defer std.testing.allocator.free(message_audit_out);
    const message_audit_args = [_][]const u8{ "--root", sessions_abs, "--contains", "query lift needle", "--format", "json" };
    const message_audit_got = try runCommandWithOutput(std.testing.allocator, .message_audit, message_audit_args[0..], message_audit_out);
    defer std.testing.allocator.free(message_audit_got);
    try std.testing.expect(std.mem.indexOf(u8, message_audit_got, "\"messages\": 1") != null);

    const skill_cohort_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "skill-cohort.json" });
    defer std.testing.allocator.free(skill_cohort_out);
    const skill_cohort_args = [_][]const u8{ "--root", sessions_abs, "--skill", "seq", "--format", "json" };
    const skill_cohort_got = try runCommandWithOutput(std.testing.allocator, .skill_cohort, skill_cohort_args[0..], skill_cohort_out);
    defer std.testing.allocator.free(skill_cohort_got);
    try std.testing.expect(std.mem.indexOf(u8, skill_cohort_got, "\"cohort_skill\": \"seq\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill_cohort_got, "\"skill\": \"seq\"") != null);

    const tool_search_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "tool-search.json" });
    defer std.testing.allocator.free(tool_search_out);
    const tool_search_args = [_][]const u8{ "--root", sessions_abs, "--contains", "seq query", "--format", "json" };
    const tool_search_got = try runCommandWithOutput(std.testing.allocator, .tool_search, tool_search_args[0..], tool_search_out);
    defer std.testing.allocator.free(tool_search_got);
    try std.testing.expect(std.mem.indexOf(u8, tool_search_got, "\"primary_executable\": \"seq\"") != null);

    const extension_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "memory-extension-audit.json" });
    defer std.testing.allocator.free(extension_out);
    const extensions_abs = try std.fs.path.join(std.testing.allocator, &.{ memories_abs, "extensions" });
    defer std.testing.allocator.free(extensions_abs);
    const extension_args = [_][]const u8{ "--extensions-root", extensions_abs, "--mode", "rows", "--format", "json" };
    const extension_got = try runCommandWithOutput(std.testing.allocator, .memory_extension_audit, extension_args[0..], extension_out);
    defer std.testing.allocator.free(extension_got);
    try std.testing.expect(std.mem.indexOf(u8, extension_got, "\"extension_name\": \"querylift\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, extension_got, "\"provenance_status\": \"inventory_only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, extension_got, "\"causality_claimed\": false") != null);

    const token_window_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "token-window.json" });
    defer std.testing.allocator.free(token_window_out);
    const token_window_args = [_][]const u8{ "--root", sessions_abs, "--window-hours", "1", "--format", "json" };
    const token_window_got = try runCommandWithOutput(std.testing.allocator, .token_window, token_window_args[0..], token_window_out);
    defer std.testing.allocator.free(token_window_got);
    try std.testing.expect(std.mem.indexOf(u8, token_window_got, "\"source_dataset\": \"token_deltas\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, token_window_got, "\"total_tokens\": 25") != null);

    const show_query_out = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "show-query.json" });
    defer std.testing.allocator.free(show_query_out);
    const show_query_args = [_][]const u8{ "--root", sessions_abs, "--contains", "query lift needle", "--show-query", "--format", "json" };
    const show_query_got = try runCommandWithOutput(std.testing.allocator, .message_audit, show_query_args[0..], show_query_out);
    defer std.testing.allocator.free(show_query_got);
    try std.testing.expect(std.mem.indexOf(u8, show_query_got, "\"dataset\": \"messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_query_got, "\"field\":\"text\"") != null);
}

test "skill-blocks distinct returns one aggregated version with metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/10");
    const session_rel = "2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000020.jsonl";
    const session_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"<skill>\\n<name>accretive</name>\\n<path>/tmp/accretive/SKILL.md</path>\\n# one\\n</skill>\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:01:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"<skill>\\n<name>accretive</name>\\n<path>/tmp/accretive/SKILL.md</path>\\n# one\\n</skill>\"}]}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "skill-blocks-distinct.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--skill",
        "accretive",
        "--session-id",
        "019c0000-0000-7000-8000-000000000020",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .skill_blocks, args[0..], output_path);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "\"occurrence_count\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"roles\": \"assistant,user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"first_seen_timestamp\": \"2026-03-10T10:00:00+00:00\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"last_seen_timestamp\": \"2026-03-10T10:01:00+00:00\"") != null);
}

test "skill-blocks history all preserves duplicate occurrences" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "2026/03/10");
    const session_rel = "2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000021.jsonl";
    const session_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"<skill>\\n<name>accretive</name>\\n# one\\n</skill>\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-10T10:00:01Z\",\"payload\":{\"type\":\"user_message\",\"message\":\"<skill>\\n<name>accretive</name>\\n# one\\n</skill>\"}}\n";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "skill-blocks-all.json" });
    defer std.testing.allocator.free(output_path);

    const args = [_][]const u8{
        "--root",
        root_abs,
        "--skill",
        "accretive",
        "--history",
        "all",
        "--session-id",
        "019c0000-0000-7000-8000-000000000021",
        "--format",
        "json",
    };
    const got = try runCommandWithOutput(std.testing.allocator, .skill_blocks, args[0..], output_path);
    defer std.testing.allocator.free(got);

    const needle = "\"skill\": \"accretive\"";
    try std.testing.expect(std.mem.indexOf(u8, got, needle) != null);
    try std.testing.expect(std.mem.count(u8, got, needle) == 2);
}
