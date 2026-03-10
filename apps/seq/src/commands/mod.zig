const std = @import("std");
const lib = @import("../lib.zig");
const datasets = @import("../datasets/mod.zig");
const query = @import("../query/engine.zig");
const spec = @import("../types/spec.zig");
const output = @import("../output/mod.zig");

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
        .fields = &.{ "path", "timestamp", "day", "week", "month", "kind", "tool", "call_id", "arguments_len", "input_len", "status" },
    },
    .{
        .name = "memory_files",
        .description = "File-based memories under ~/.codex/memories",
        .fields = &.{ "path", "relative_path", "name", "category", "extension", "size_bytes", "modified_at", "preview" },
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
    next_actions: bool = false,
    latest: bool = false,
    fail_on_floor: bool = false,
    fail_on_mesh_truth: bool = false,
    fail_on_hang: bool = false,
    strict_hang: bool = true,
    root: ?[]const u8 = null,
    path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    dataset: ?[]const u8 = null,
    spec_text: ?[]const u8 = null,
    skill: ?[]const u8 = null,
    bucket: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    roles_csv: ?[]const u8 = null,
    contains: ?[]const u8 = null,
    regex: ?[]const u8 = null,
    role: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    status: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    part_type: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    session: ?[]const u8 = null,
    select_text: ?[]const u8 = null,
    sort_text: ?[]const u8 = null,
    group_by_text: ?[]const u8 = null,
    metric_text: ?[]const u8 = null,
    opencode_db_path: ?[]const u8 = null,
    opencode_path: ?[]const u8 = null,
    opencode_source_text: ?[]const u8 = null,
    include_raw: bool = false,
    strip_skill_blocks: bool = false,
    no_dedupe_exact: bool = false,
    sections: ?[]const u8 = null,
    cue_spec_text: ?[]const u8 = null,
    discovery_skills: ?[]const u8 = null,
    limit: usize = 0,
    floor_threshold: i64 = 3,
    threshold_ms: i64 = 10_000,
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
        .skill_trend => try cmdSkillTrend(allocator, sessions_root, opts),
        .skill_report => try cmdSkillReport(allocator, sessions_root, opts),
        .role_breakdown => try cmdRoleBreakdown(allocator, sessions_root, opts),
        .occurrence_export => try cmdOccurrenceExport(allocator, sessions_root, opts),
        .orchestration_concurrency => try cmdOrchestrationConcurrency(allocator, sessions_root, opts),
        .find_session => try cmdFindSession(allocator, sessions_root, opts),
        .session_prompts => try cmdSessionPrompts(allocator, sessions_root, opts),
        .report_bundle => try cmdReportBundle(allocator, sessions_root, opts),
        .section_audit => try cmdSectionAudit(allocator, sessions_root, opts),
        .token_usage => try cmdTokenUsage(allocator, sessions_root, opts),
        .routing_gap => try cmdRoutingGap(allocator, sessions_root, opts),
        .datasets => try cmdDatasets(allocator, opts),
        .dataset_schema => try cmdDatasetSchema(allocator, opts),
        .query => try cmdQuery(allocator, sessions_root, opts),
        .session_tooling => try cmdSessionTooling(allocator, sessions_root, opts),
        .query_diagnose => try cmdQueryDiagnose(allocator, sessions_root, opts),
        .opencode_prompts => try cmdOpencodePrompts(allocator, sessions_root, opts),
        .opencode_events => try cmdOpencodeEvents(allocator, sessions_root, opts),
        .unknown => return error.InvalidCommand,
    }
}

fn printCommandHelp(cmd: lib.Command) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
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
        \\usage: seq skills-rank [--format table|json|csv] [--max N]
        ,
        .skill_trend =>
        \\usage: seq skill-trend --skill <name> [--bucket day|week|month] [--format table|json|csv] [--max N]
        ,
        .skill_report =>
        \\usage: seq skill-report --skill <name>
        ,
        .role_breakdown =>
        \\usage: seq role-breakdown [--format table|json|csv] [--max N]
        ,
        .occurrence_export =>
        \\usage: seq occurrence-export [--skill <name>] [--format jsonl|json|csv] [--max N]
        ,
        .orchestration_concurrency =>
        \\usage: seq orchestration-concurrency [--session-id <id>|--path <jsonl>] [--format table|json|csv|jsonl] [--floor-threshold N] [--fail-on-floor] [--fail-on-mesh-truth]
        ,
        .find_session =>
        \\usage: seq find-session --prompt <text> [--limit N] [--format table|json|csv|jsonl]
        ,
        .session_prompts =>
        \\usage: seq session-prompts [--session-id <id>|--path <jsonl>|--current] [--roles <csv>] [--strip-skill-blocks] [--no-dedupe-exact] [--limit N] [--format table|json|csv|jsonl]
        \\extra options:
        \\  --path <path>              Inspect exactly one rollout/session JSONL file
        \\  --session-id <id>          Resolve exactly one session file by session id substring
        \\  --current                  Resolve current session via CODEX_THREAD_ID
        \\  --roles <csv>              user | assistant | user,assistant
        \\  --strip-skill-blocks       Remove <skill>...</skill> envelopes before output
        \\  --no-dedupe-exact          Keep duplicated role+text rows
        ,
        .report_bundle =>
        \\usage: seq report-bundle [--top N]
        ,
        .section_audit =>
        \\usage: seq section-audit --sections <csv>
        ,
        .token_usage =>
        \\usage: seq token-usage [--top N]
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
        .session_tooling =>
        \\usage: seq session-tooling [--session-id <id>|--path <jsonl>] [--group-by executable|command|tool] [--summary] [--limit N] [--format table|json|csv|jsonl]
        ,
        .query_diagnose =>
        \\usage: seq query-diagnose [--session-id <id>|--path <jsonl>] [--threshold-ms N] [--strict-hang] [--fail-on-hang] [--next-actions] [--summary] [--format table|json|csv|jsonl]
        ,
        .opencode_prompts =>
        \\usage: seq opencode-prompts [--spec <json|@path>] [--contains <text>] [--regex <expr>] [--session <id|slug>] [--since <epoch-ms|iso>] [--until <epoch-ms|iso>] [--latest] [--mode <name>] [--part-type <name>] [--group-by <csv>] [--metric <csv>] [--select <csv>] [--sort <csv>] [--source auto|db|jsonl] [--opencode-db-path <path>] [--opencode-path <path>] [--include-raw] [--limit N] [--format table|json|csv|jsonl]
        ,
        .opencode_events =>
        \\usage: seq opencode-events [--spec <json|@path>] [--contains <text>] [--regex <expr>] [--session <id|slug>] [--since <epoch-ms|iso>] [--until <epoch-ms|iso>] [--latest] [--role <name>] [--mode <name>] [--part-type <name>] [--tool <name>] [--status <name>] [--group-by <csv>] [--metric <csv>] [--select <csv>] [--sort <csv>] [--source auto|db|jsonl] [--opencode-db-path <path>] [--opencode-path <path>] [--include-raw] [--limit N] [--format table|json|csv|jsonl]
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
    var stderr_writer = std.fs.File.stderr().writer(&.{});
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

fn validateFormatForCommand(cmd: lib.Command, fmt: output.Format) !void {
    switch (cmd) {
        .skills_rank, .skill_trend, .skill_report, .role_breakdown, .report_bundle, .section_audit, .datasets, .dataset_schema => {
            if (fmt == .jsonl) return error.InvalidFormatForCommand;
        },
        .occurrence_export => {
            if (fmt == .table) return error.InvalidFormatForCommand;
        },
        .orchestration_concurrency, .find_session, .session_prompts, .query, .token_usage, .routing_gap, .session_tooling, .query_diagnose, .opencode_prompts, .opencode_events => {},
        .unknown => return error.InvalidCommand,
    }
}

fn validateCommandOptions(cmd: lib.Command, opts: Options) !void {
    const supports_path = switch (cmd) {
        .orchestration_concurrency, .session_prompts, .session_tooling, .query_diagnose => true,
        else => false,
    };
    const supports_session_id = switch (cmd) {
        .orchestration_concurrency, .session_prompts, .session_tooling => true,
        else => false,
    };
    const supports_current = cmd == .session_prompts;
    const supports_roles_csv = cmd == .session_prompts;
    const supports_strip_skill_blocks = cmd == .session_prompts;
    const supports_no_dedupe_exact = cmd == .session_prompts;
    const supports_summary = switch (cmd) {
        .session_tooling, .query_diagnose => true,
        else => false,
    };
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
        .skill_trend, .skill_report, .occurrence_export => true,
        else => false,
    };
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
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_regex = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_role = cmd == .opencode_events;
    const supports_tool = cmd == .opencode_events;
    const supports_status = cmd == .opencode_events;
    const supports_mode = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_part_type = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_since = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_until = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_session = switch (cmd) {
        .opencode_prompts, .opencode_events => true,
        else => false,
    };
    const supports_group_by = switch (cmd) {
        .session_tooling, .opencode_prompts, .opencode_events => true,
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
        .opencode_prompts, .opencode_events => true,
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
        .opencode_prompts, .opencode_events => true,
        else => false,
    };

    try ensureOptionAllowed(opts.path != null, supports_path, "--path", cmd);
    try ensureOptionAllowed(opts.session_id != null, supports_session_id, "--session-id", cmd);
    try ensureOptionAllowed(opts.current, supports_current, "--current", cmd);
    try ensureOptionAllowed(opts.roles_csv != null, supports_roles_csv, "--roles", cmd);
    try ensureOptionAllowed(opts.strip_skill_blocks, supports_strip_skill_blocks, "--strip-skill-blocks", cmd);
    try ensureOptionAllowed(opts.no_dedupe_exact, supports_no_dedupe_exact, "--no-dedupe-exact", cmd);
    try ensureOptionAllowed(opts.summary, supports_summary, "--summary", cmd);
    try ensureOptionAllowed(opts.next_actions, supports_next_actions, "--next-actions", cmd);
    try ensureOptionAllowed(opts.latest, supports_latest, "--latest", cmd);
    try ensureOptionAllowed(opts.floor_threshold != 3, supports_floor_threshold, "--floor-threshold", cmd);
    try ensureOptionAllowed(opts.fail_on_floor, supports_fail_on_floor, "--fail-on-floor", cmd);
    try ensureOptionAllowed(opts.fail_on_mesh_truth, supports_fail_on_mesh_truth, "--fail-on-mesh-truth", cmd);
    try ensureOptionAllowed(opts.fail_on_hang, supports_fail_on_hang, "--fail-on-hang", cmd);
    try ensureOptionAllowed(opts.threshold_ms != 10_000, supports_threshold_ms, "--threshold-ms", cmd);
    try ensureOptionAllowed(!opts.strict_hang, supports_strict_hang, "--no-strict-hang", cmd);
    try ensureOptionAllowed(opts.skill != null, supports_skill, "--skill", cmd);
    try ensureOptionAllowed(opts.bucket != null, supports_bucket, "--bucket", cmd);
    try ensureOptionAllowed(opts.prompt != null, supports_prompt, "--prompt", cmd);
    try ensureOptionAllowed(opts.sections != null, supports_sections, "--sections", cmd);
    try ensureOptionAllowed(opts.cue_spec_text != null, supports_cue_spec, "--cue-spec", cmd);
    try ensureOptionAllowed(opts.discovery_skills != null, supports_discovery_skills, "--discovery-skills", cmd);
    try ensureOptionAllowed(opts.dataset != null, supports_dataset, "--dataset", cmd);
    try ensureOptionAllowed(opts.spec_text != null, supports_spec_text, "--spec", cmd);
    try ensureOptionAllowed(opts.contains != null, supports_contains, "--contains", cmd);
    try ensureOptionAllowed(opts.regex != null, supports_regex, "--regex", cmd);
    try ensureOptionAllowed(opts.role != null, supports_role, "--role", cmd);
    try ensureOptionAllowed(opts.tool != null, supports_tool, "--tool", cmd);
    try ensureOptionAllowed(opts.status != null, supports_status, "--status", cmd);
    try ensureOptionAllowed(opts.mode != null, supports_mode, "--mode", cmd);
    try ensureOptionAllowed(opts.part_type != null, supports_part_type, "--part-type", cmd);
    try ensureOptionAllowed(opts.since != null, supports_since, "--since", cmd);
    try ensureOptionAllowed(opts.until != null, supports_until, "--until", cmd);
    try ensureOptionAllowed(opts.session != null, supports_session, "--session", cmd);
    try ensureOptionAllowed(opts.group_by_text != null, supports_group_by, "--group-by", cmd);
    try ensureOptionAllowed(opts.metric_text != null, supports_metric, "--metric", cmd);
    try ensureOptionAllowed(opts.select_text != null, supports_select, "--select", cmd);
    try ensureOptionAllowed(opts.sort_text != null, supports_sort, "--sort", cmd);
    try ensureOptionAllowed(opts.opencode_db_path != null, supports_opencode_db_path, "--opencode-db-path", cmd);
    try ensureOptionAllowed(opts.opencode_path != null, supports_opencode_path, "--opencode-path", cmd);
    try ensureOptionAllowed(opts.opencode_source_text != null, supports_opencode_source, "--source", cmd);
    try ensureOptionAllowed(opts.include_raw, supports_include_raw, "--include-raw", cmd);
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
    try output.writeOutput(allocator, fmt, result.rows.items, cols_opt, opts.out_path);
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
    const query_spec = spec.QuerySpec{
        .group_by = &.{"skill"},
        .metrics = &.{.{ .op = .count, .alias = "count" }},
        .sort = &.{.{ .field = "count", .descending = true }},
        .limit = opts.limit,
    };
    try runDatasetQuery(allocator, "skill_mentions", sessions_root, query_spec, opts.format, opts.out_path, null);
}

fn cmdSkillTrend(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const skill_name = opts.skill orelse return error.MissingSkillArg;
    const bucket = opts.bucket orelse "day";
    const group_by = [_][]const u8{bucket};
    const where = [_]spec.WhereClause{
        .{ .field = "skill", .op = .eq, .value = .{ .scalar = .{ .string = skill_name } } },
    };
    const query_spec = spec.QuerySpec{
        .where = where[0..],
        .group_by = group_by[0..],
        .metrics = &.{.{ .op = .count, .alias = "count" }},
        .sort = &.{.{ .field = bucket, .descending = false }},
    };

    var rows = try collectDatasetRows(allocator, "skill_mentions", sessions_root, &.{}, &.{});
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
    var where_buf: [1]spec.WhereClause = undefined;
    where_buf[0] = .{
        .field = "skill",
        .op = .eq,
        .value = .{ .scalar = .{ .string = skill_name } },
    };
    const where_slice = where_buf[0..1];
    const select = [_][]const u8{ "path", "timestamp", "role", "skill", "types", "snippet" };
    const query_spec = spec.QuerySpec{
        .where = where_slice,
        .select = select[0..],
        .sort = &.{.{ .field = "timestamp", .descending = false }},
        .limit = opts.limit,
    };
    try runDatasetQuery(allocator, "skill_mentions", sessions_root, query_spec, opts.format, opts.out_path, select[0..]);
}

fn cmdRoleBreakdown(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const query_spec = spec.QuerySpec{
        .group_by = &.{ "skill", "role" },
        .metrics = &.{.{ .op = .count, .alias = "count" }},
    };

    var occ_rows = try collectDatasetRows(allocator, "skill_mentions", sessions_root, &.{}, &.{});
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
    var where_buf: [1]spec.WhereClause = undefined;
    var where_slice: []const spec.WhereClause = &.{};
    if (opts.skill) |skill_name| {
        where_buf[0] = .{
            .field = "skill",
            .op = .eq,
            .value = .{ .scalar = .{ .string = skill_name } },
        };
        where_slice = where_buf[0..1];
    }
    const select = [_][]const u8{ "path", "timestamp", "role", "skill", "types", "snippet" };
    const query_spec = spec.QuerySpec{
        .where = where_slice,
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
    var input_paths = try resolveOrchestrationInputPaths(allocator, sessions_root, opts);
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

    const file = std.fs.openFileAbsolute(absolute, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch return null;
    defer allocator.free(content);

    var rows: i64 = 0;
    var seen_header = false;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
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

    var paths = try collectJsonlPaths(allocator, sessions_root, null);
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
    command_text: ?[]u8 = null,
    primary_executable: ?[]u8 = null,
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
        if (self.command_text) |value| allocator.free(value);
        if (self.primary_executable) |value| allocator.free(value);
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
        var rows = try buildSessionToolingSummaryRows(allocator, records.items, mode);
        defer deinitQueryRows(allocator, &rows);
        if (opts.limit > 0 and rows.items.len > opts.limit) {
            rows.items.len = opts.limit;
        }
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

    const max_rows = if (opts.limit > 0 and opts.limit < records.items.len) opts.limit else records.items.len;
    for (records.items[0..max_rows]) |record| {
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
        const dataset_hint = try extractDatasetHint(allocator, record.command_text);
        defer if (dataset_hint) |hint| allocator.free(hint);
        try putOptionalString(&row, "dataset_hint", dataset_hint);
        try row.putOwnedKey("unresolved", .{ .bool = unresolved });
        try row.putOwnedKey("threshold_exceeded", .{ .bool = threshold_exceeded });
        try row.putOwnedKey("hang_flag", .{ .bool = hang_flag });
        try putOptionalInt(&row, "pty_session_id", record.pty_session_id);
        try row.putOwnedKey("resolution_state", .{ .string = queryResolutionState(record) });
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
        if (opts.limit > 0 and out_rows.items.len > opts.limit) {
            out_rows.items.len = opts.limit;
        }
        if (opts.next_actions) {
            const cols = [_][]const u8{ "query_call_id", "session_id", "path", "started_at", "ended_at", "duration_ms", "dataset_hint", "unresolved", "threshold_exceeded", "hang_flag", "pty_session_id", "resolution_state", "query_invocation", "next_action" };
            try output.writeOutput(allocator, opts.format, out_rows.items, cols[0..], opts.out_path);
        } else {
            const cols = [_][]const u8{ "query_call_id", "session_id", "path", "started_at", "ended_at", "duration_ms", "dataset_hint", "unresolved", "threshold_exceeded", "hang_flag", "pty_session_id", "resolution_state", "query_invocation" };
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
    var input_paths = try resolveOrchestrationInputPaths(allocator, sessions_root, opts);
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
                if (std.mem.eql(u8, tool_name, "shell")) {
                    if (stdJsonStringField(payload, "input")) |input_text| {
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
    return std.mem.indexOf(u8, record.command_text.?, "seq query") != null;
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
    const where = [_]spec.WhereClause{
        .{
            .field = "text",
            .op = .contains,
            .value = .{ .scalar = .{ .string = prompt } },
        },
    };
    const select = [_][]const u8{ "path", "timestamp", "role", "text" };
    const query_spec = spec.QuerySpec{
        .where = where[0..],
        .select = select[0..],
        .sort = &.{.{ .field = "timestamp", .descending = true }},
        .limit = opts.limit,
    };
    try runDatasetQuery(allocator, "messages", sessions_root, query_spec, opts.format, opts.out_path, select[0..]);
}

fn currentSessionIdFromEnv(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "CODEX_THREAD_ID") catch {
        printCliError("error: --current requires CODEX_THREAD_ID in the environment\n", .{});
        return error.CurrentSessionUnavailable;
    };
}

fn resolveSessionPromptInputPaths(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    opts: Options,
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
        const file = std.fs.openFileAbsolute(absolute, .{}) catch {
            allocator.free(absolute);
            return error.SessionNotFound;
        };
        file.close();
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

    var paths = try collectJsonlPaths(allocator, sessions_root, null);
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
    var input_paths = try resolveSessionPromptInputPaths(allocator, sessions_root, opts);
    defer freePathList(allocator, &input_paths);

    var rows = try collectSessionPromptRows(allocator, input_paths.items, parse_options);
    defer deinitQueryRows(allocator, &rows);

    const select = [_][]const u8{ "timestamp", "path", "role", "text" };
    const query_spec = spec.QuerySpec{
        .select = select[0..],
        .sort = &.{.{ .field = "timestamp", .descending = false }},
        .limit = opts.limit,
    };
    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    try output.writeOutput(allocator, opts.format, result.rows.items, select[0..], opts.out_path);
}

fn cmdReportBundle(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const query_spec = spec.QuerySpec{
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
    var rows = try collectDatasetRows(allocator, "messages", sessions_root, &.{}, &.{});
    defer deinitQueryRows(allocator, &rows);

    const select = [_][]const u8{ "role", "text" };
    const identity_spec = spec.QuerySpec{ .select = select[0..] };
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

fn cmdTokenUsage(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const query_spec = spec.QuerySpec{
        .group_by = &.{"day"},
        .metrics = &.{
            .{ .op = .sum, .field = "delta_total_tokens", .alias = "total_tokens" },
            .{ .op = .count, .alias = "rows" },
        },
        .sort = &.{.{ .field = "day", .descending = false }},
        .limit = opts.limit,
    };
    try runDatasetQuery(allocator, "token_deltas", sessions_root, query_spec, opts.format, opts.out_path, null);
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

    var skill_rows = try collectDatasetRows(allocator, "skill_mentions", sessions_root, &.{}, &.{});
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

    var message_rows = try collectDatasetRows(allocator, "messages", sessions_root, &.{}, &.{});
    defer deinitQueryRows(allocator, &message_rows);

    var out_rows: std.ArrayList(query.Row) = .empty;
    defer deinitQueryRows(allocator, &out_rows);

    var total_cue_sessions: std.StringHashMap(void) = .init(allocator);
    defer deinitStringSet(allocator, &total_cue_sessions);
    var total_invoked_sessions: std.StringHashMap(void) = .init(allocator);
    defer deinitStringSet(allocator, &total_invoked_sessions);
    var total_cue_messages: i64 = 0;

    for (cue_specs) |cue| {
        const where = [_]spec.WhereClause{
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
            .where = where[0..],
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
    eq_day: ?[]const u8 = null,
    min_day: ?[]const u8 = null,
    min_inclusive: bool = true,
    max_day: ?[]const u8 = null,
    max_inclusive: bool = true,

    fn hasAny(self: SessionDayPathFilter) bool {
        return self.eq_day != null or self.min_day != null or self.max_day != null;
    }
};

fn isSessionFileDataset(dataset_name: []const u8) bool {
    return std.mem.eql(u8, dataset_name, "messages") or
        std.mem.eql(u8, dataset_name, "skill_mentions") or
        std.mem.eql(u8, dataset_name, "token_events") or
        std.mem.eql(u8, dataset_name, "token_deltas") or
        std.mem.eql(u8, dataset_name, "token_sessions") or
        std.mem.eql(u8, dataset_name, "tool_calls");
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

fn updateMinDay(filter: *SessionDayPathFilter, day: []const u8, inclusive: bool) void {
    const current = filter.min_day orelse {
        filter.min_day = day;
        filter.min_inclusive = inclusive;
        return;
    };
    const order = std.mem.order(u8, day, current);
    if (order == .gt) {
        filter.min_day = day;
        filter.min_inclusive = inclusive;
    } else if (order == .eq and !inclusive and filter.min_inclusive) {
        filter.min_inclusive = false;
    }
}

fn updateMaxDay(filter: *SessionDayPathFilter, day: []const u8, inclusive: bool) void {
    const current = filter.max_day orelse {
        filter.max_day = day;
        filter.max_inclusive = inclusive;
        return;
    };
    const order = std.mem.order(u8, day, current);
    if (order == .lt) {
        filter.max_day = day;
        filter.max_inclusive = inclusive;
    } else if (order == .eq and !inclusive and filter.max_inclusive) {
        filter.max_inclusive = false;
    }
}

fn deriveSessionDayPathFilter(dataset_name: []const u8, query_where: []const spec.WhereClause) ?SessionDayPathFilter {
    if (!isSessionFileDataset(dataset_name)) return null;

    var filter = SessionDayPathFilter{};
    for (query_where) |clause| {
        if (!std.mem.eql(u8, clause.field, "day")) continue;

        switch (clause.op) {
            .eq => {
                const where_value = clause.value orelse continue;
                switch (where_value) {
                    .scalar => |scalar| {
                        const day = scalarDayLiteral(scalar) orelse continue;
                        filter.eq_day = day;
                    },
                    else => {},
                }
            },
            .gte => {
                const where_value = clause.value orelse continue;
                switch (where_value) {
                    .scalar => |scalar| {
                        const day = scalarDayLiteral(scalar) orelse continue;
                        updateMinDay(&filter, day, true);
                    },
                    else => {},
                }
            },
            .gt => {
                const where_value = clause.value orelse continue;
                switch (where_value) {
                    .scalar => |scalar| {
                        const day = scalarDayLiteral(scalar) orelse continue;
                        updateMinDay(&filter, day, false);
                    },
                    else => {},
                }
            },
            .lte => {
                const where_value = clause.value orelse continue;
                switch (where_value) {
                    .scalar => |scalar| {
                        const day = scalarDayLiteral(scalar) orelse continue;
                        updateMaxDay(&filter, day, true);
                    },
                    else => {},
                }
            },
            .lt => {
                const where_value = clause.value orelse continue;
                switch (where_value) {
                    .scalar => |scalar| {
                        const day = scalarDayLiteral(scalar) orelse continue;
                        updateMaxDay(&filter, day, false);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    if (!filter.hasAny()) return null;
    return filter;
}

fn dayMatchesFilter(filter: SessionDayPathFilter, day: []const u8) bool {
    if (!isValidDayLiteral(day)) return true;
    if (filter.eq_day) |eq_day| {
        if (!std.mem.eql(u8, day, eq_day)) return false;
    }
    if (filter.min_day) |min_day| {
        const order = std.mem.order(u8, day, min_day);
        if (order == .lt) return false;
        if (order == .eq and !filter.min_inclusive) return false;
    }
    if (filter.max_day) |max_day| {
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
    } else if (std.mem.eql(u8, dataset_name, "memory_files")) {
        try collectMemoryFilesRows(allocator, query_params, &rows);
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
    var parsed = try datasets.tool_calls.collect(allocator, sessions_root);
    defer datasets.tool_calls.deinitRows(allocator, &parsed);

    for (parsed.items) |row| {
        if (day_filter) |filter| {
            if (row.day) |day| {
                if (!dayMatchesFilter(filter, day)) continue;
            }
        }
        var qrow = query.Row.init(allocator);
        try qrow.putOwnedKey("path", .{ .string = row.path });
        try putOptionalString(&qrow, "timestamp", row.timestamp);
        try putOptionalString(&qrow, "day", row.day);
        try putOptionalString(&qrow, "week", row.week);
        try putOptionalString(&qrow, "month", row.month);
        try qrow.putOwnedKey("kind", .{ .string = row.kind });
        try putOptionalString(&qrow, "tool", row.tool);
        try putOptionalString(&qrow, "call_id", row.call_id);
        if (row.arguments_len) |v| {
            try qrow.putOwnedKey("arguments_len", .{ .int = @intCast(v) });
        } else {
            try qrow.putOwnedKey("arguments_len", .null);
        }
        if (row.input_len) |v| {
            try qrow.putOwnedKey("input_len", .{ .int = @intCast(v) });
        } else {
            try qrow.putOwnedKey("input_len", .null);
        }
        try putOptionalString(&qrow, "status", row.status);
        try out_rows.append(allocator, qrow);
    }
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
        } else if (std.mem.eql(u8, arg, "--bucket")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.bucket = args[i];
        } else if (std.mem.eql(u8, arg, "--prompt")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--roles")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.roles_csv = args[i];
        } else if (std.mem.eql(u8, arg, "--contains")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.contains = args[i];
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
        } else if (std.mem.eql(u8, arg, "--since")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.since = args[i];
        } else if (std.mem.eql(u8, arg, "--until")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.until = args[i];
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
        } else if (std.mem.eql(u8, arg, "--select")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.select_text = args[i];
        } else if (std.mem.eql(u8, arg, "--sort")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.sort_text = args[i];
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
        } else if (std.mem.eql(u8, arg, "--strip-skill-blocks")) {
            opts.strip_skill_blocks = true;
        } else if (std.mem.eql(u8, arg, "--no-dedupe-exact")) {
            opts.no_dedupe_exact = true;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            opts.summary = true;
        } else if (std.mem.eql(u8, arg, "--next-actions")) {
            opts.next_actions = true;
        } else if (std.mem.eql(u8, arg, "--latest")) {
            opts.latest = true;
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

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, expanded });
}

fn expandHomePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~")) {
        return std.process.getEnvVarOwned(allocator, "HOME");
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    return allocator.dupe(u8, path);
}

fn collectJsonlPaths(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    day_filter: ?SessionDayPathFilter,
) !std.ArrayList([]u8) {
    var out = std.ArrayList([]u8).empty;
    errdefer freePathList(allocator, &out);

    var root_dir = std.fs.openDirAbsolute(root_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out,
        else => return err,
    };
    defer root_dir.close();

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
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

fn loadSpecText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len > 1 and raw[0] == '@') {
        return std.fs.cwd().readFileAlloc(allocator, raw[1..], 2 * 1024 * 1024);
    }
    return allocator.dupe(u8, raw);
}

fn readFileAllocOrSkip(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch null;
}

fn freePathList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |path| allocator.free(path);
    list.deinit(allocator);
}

fn lessThanString(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn deinitQueryRows(allocator: std.mem.Allocator, rows: *std.ArrayList(query.Row)) void {
    for (rows.items) |*row| row.deinit();
    rows.deinit(allocator);
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

    try tmp.dir.makePath("2026/02/26");
    try tmp.dir.makePath("2026/02/27");
    try tmp.dir.makePath("2026/03/01");

    try tmp.dir.writeFile(.{ .sub_path = "2026/02/26/a.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "2026/02/27/b.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "2026/03/01/c.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "2026/03/01/notes.txt", .data = "ignore\n" });

    const root_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_abs);

    const filter = SessionDayPathFilter{
        .min_day = "2026-02-27",
        .min_inclusive = true,
    };
    var paths = try collectJsonlPaths(std.testing.allocator, root_abs, filter);
    defer freePathList(std.testing.allocator, &paths);

    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, paths.items[0], 1, "/2026/02/27/") or std.mem.containsAtLeast(u8, paths.items[1], 1, "/2026/02/27/"));
    try std.testing.expect(std.mem.containsAtLeast(u8, paths.items[0], 1, "/2026/03/01/") or std.mem.containsAtLeast(u8, paths.items[1], 1, "/2026/03/01/"));
}

test "summarizeSessionConcurrency computes configured and effective maxima" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "wave-a.csv",
        .data =
        \\id,objective
        \\U01,a
        \\U02,b
        \\U03,c
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "wave-b.csv",
        .data =
        \\id,objective
        \\U11,x
        ,
    });

    const root_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
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

    try tmp.dir.writeFile(.{
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

    try tmp.dir.writeFile(.{
        .sub_path = "rollout-2026-03-02T00-00-00-019caeb9-23af-7de2-985b-3d954b4df213.jsonl",
        .data = session_content,
    });

    const root_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
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
        "--status",
        "completed",
        "--mode",
        "normal",
        "--part-type",
        "file",
        "--session",
        "ses_abc",
        "--since",
        "1772700000000",
        "--until",
        "2026-03-05T00:00:00Z",
        "--group-by",
        "mode",
        "--metric",
        "count::count",
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
        "--include-raw",
        "--strip-skill-blocks",
        "--no-dedupe-exact",
        "--summary",
        "--next-actions",
        "--current",
        "--latest",
        "--strict-hang",
        "--threshold-ms",
        "12000",
        "--fail-on-hang",
        "--help",
    };
    const opts = try parseOptions(args[0..]);
    try std.testing.expectEqual(output.Format.jsonl, opts.format);
    try std.testing.expect(opts.format_set);
    try std.testing.expectEqualStrings("~/sessions", opts.root.?);
    try std.testing.expectEqualStrings("/tmp/session.jsonl", opts.path.?);
    try std.testing.expectEqualStrings("019ca0e5-0beb-7740-a9bc-81664d994266", opts.session_id.?);
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
    try std.testing.expectEqualStrings("completed", opts.status.?);
    try std.testing.expectEqualStrings("normal", opts.mode.?);
    try std.testing.expectEqualStrings("file", opts.part_type.?);
    try std.testing.expectEqualStrings("ses_abc", opts.session.?);
    try std.testing.expectEqualStrings("1772700000000", opts.since.?);
    try std.testing.expectEqualStrings("2026-03-05T00:00:00Z", opts.until.?);
    try std.testing.expectEqualStrings("mode", opts.group_by_text.?);
    try std.testing.expectEqualStrings("count::count", opts.metric_text.?);
    try std.testing.expectEqualStrings("mode,input_len", opts.select_text.?);
    try std.testing.expectEqualStrings("-count,mode", opts.sort_text.?);
    try std.testing.expectEqualStrings("/tmp/opencode.db", opts.opencode_db_path.?);
    try std.testing.expectEqualStrings("/tmp/prompt-history.jsonl", opts.opencode_path.?);
    try std.testing.expectEqualStrings("db", opts.opencode_source_text.?);
    try std.testing.expect(opts.include_raw);
    try std.testing.expect(opts.strip_skill_blocks);
    try std.testing.expect(opts.no_dedupe_exact);
    try std.testing.expect(opts.summary);
    try std.testing.expect(opts.next_actions);
    try std.testing.expect(opts.current);
    try std.testing.expect(opts.latest);
    try std.testing.expect(opts.strict_hang);
    try std.testing.expectEqual(@as(i64, 12000), opts.threshold_ms);
    try std.testing.expect(opts.fail_on_hang);
    try std.testing.expect(opts.help);
}

test "parseOptions rejects unknown option" {
    const args = [_][]const u8{"--bogus"};
    try std.testing.expectError(error.UnknownArgument, parseOptions(args[0..]));
}

test "validateCommandOptions rejects unsupported path on skill-report" {
    const opts = Options{ .path = "/tmp/session.jsonl" };
    try std.testing.expectError(error.UnsupportedOption, validateCommandOptions(.skill_report, opts));
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

    const file = try std.fs.openFileAbsolute(output_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 1 * 1024 * 1024);
}

test "session-prompts resolves a single targeted file and supports role filters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("2026/03/10");
    const target_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Before\\n<skill>\\n<name>seq</name>\\n</skill>\\nAfter\"}]}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:01Z\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Echo: prompt\\n\\nAnswer\"}]}}\n";
    const other_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2025-10-20T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Older session\"}]}}\n";

    const target_rel = "2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000010.jsonl";
    const other_rel = "2026/03/10/rollout-2025-10-20T10-00-00-019a0000-0000-7000-8000-000000000011.jsonl";
    try tmp.dir.writeFile(.{ .sub_path = target_rel, .data = target_content });
    try tmp.dir.writeFile(.{ .sub_path = other_rel, .data = other_content });

    const root_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
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

    try tmp.dir.makePath("2026/03/10");
    const session_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-10T10:00:00Z\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"repeat\"}]}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-03-10T10:00:01Z\",\"payload\":{\"type\":\"user_message\",\"message\":\"repeat\"}}\n";
    const session_rel = "2026/03/10/rollout-2026-03-10T10-00-00-019c0000-0000-7000-8000-000000000012.jsonl";
    try tmp.dir.writeFile(.{ .sub_path = session_rel, .data = session_content });

    const root_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
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

test "session-tooling summary groups by primary executable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("2026/03/05");
    const session_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:00Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"q1\",\"arguments\":\"{\\\"cmd\\\":\\\"seq query --spec @spec.json\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:12Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"q1\",\"output\":\"Chunk ID: aa\\nWall time: 12.250 seconds\\nProcess running with session ID 77\\nOutput:\\n\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:01:00Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"e1\",\"arguments\":\"{\\\"cmd\\\":\\\"rg -n foo\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:01:01Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"e1\",\"output\":\"Chunk ID: bb\\nWall time: 0.050 seconds\\nProcess exited with code 0\\nOutput:\\n\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:02:00Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"e2\",\"arguments\":\"{\\\"cmd\\\":\\\"jq .\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:02:01Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"e2\",\"output\":\"Chunk ID: cc\\nWall time: 0.090 seconds\\nProcess exited with code 2\\nOutput:\\n\"}}\n";
    try tmp.dir.writeFile(.{
        .sub_path = "2026/03/05/rollout-2026-03-05T00-00-00-019c0000-0000-7000-8000-000000000001.jsonl",
        .data = session_content,
    });

    const root_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
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

test "query-diagnose flags strict hangs and supports fail-on-hang" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("2026/03/05");
    const session_content =
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:00Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"call_id\":\"q1\",\"arguments\":\"{\\\"cmd\\\":\\\"seq query --spec @spec.json\\\"}\"}}\n" ++
        "{\"type\":\"response_item\",\"timestamp\":\"2026-03-05T10:00:12Z\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"q1\",\"output\":\"Chunk ID: aa\\nWall time: 12.250 seconds\\nProcess running with session ID 77\\nOutput:\\n\"}}\n";
    try tmp.dir.writeFile(.{
        .sub_path = "2026/03/05/rollout-2026-03-05T00-00-00-019c0000-0000-7000-8000-000000000002.jsonl",
        .data = session_content,
    });

    const root_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
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
