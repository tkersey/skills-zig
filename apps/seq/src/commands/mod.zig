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
};

const Options = struct {
    format: output.Format = .table,
    format_set: bool = false,
    help: bool = false,
    root: ?[]const u8 = null,
    out_path: ?[]const u8 = null,
    dataset: ?[]const u8 = null,
    spec_text: ?[]const u8 = null,
    skill: ?[]const u8 = null,
    bucket: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    sections: ?[]const u8 = null,
    limit: usize = 0,
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

    const sessions_root = try resolveSessionsRoot(allocator, opts.root);
    defer allocator.free(sessions_root);

    switch (cmd) {
        .skills_rank => try cmdSkillsRank(allocator, sessions_root, opts),
        .skill_trend => try cmdSkillTrend(allocator, sessions_root, opts),
        .skill_report => try cmdSkillReport(allocator, sessions_root, opts),
        .role_breakdown => try cmdRoleBreakdown(allocator, sessions_root, opts),
        .occurrence_export => try cmdOccurrenceExport(allocator, sessions_root, opts),
        .find_session => try cmdFindSession(allocator, sessions_root, opts),
        .session_prompts => try cmdSessionPrompts(allocator, sessions_root, opts),
        .report_bundle => try cmdReportBundle(allocator, sessions_root, opts),
        .section_audit => try cmdSectionAudit(allocator, sessions_root, opts),
        .token_usage => try cmdTokenUsage(allocator, sessions_root, opts),
        .datasets => try cmdDatasets(allocator, opts),
        .dataset_schema => try cmdDatasetSchema(allocator, opts),
        .query => try cmdQuery(allocator, sessions_root, opts),
        .unknown => return error.InvalidCommand,
    }
}

fn printCommandHelp(cmd: lib.Command) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    const common =
        \\shared options:
        \\  --root <path>
        \\  --roles <csv>
        \\  --since <iso-ts>
        \\  --until <iso-ts>
        \\  --output <path>
        \\  --skills-dir <path> (repeatable)
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
        .find_session =>
        \\usage: seq find-session --prompt <text> [--limit N] [--format table|json|csv|jsonl]
        ,
        .session_prompts =>
        \\usage: seq session-prompts [--session-id <id>|--path <jsonl>|--current] [--limit N] [--format table|json|csv|jsonl]
        ,
        .report_bundle =>
        \\usage: seq report-bundle [--top N] [--skills <csv>] [--sections <csv>]
        ,
        .section_audit =>
        \\usage: seq section-audit --sections <csv>
        ,
        .token_usage =>
        \\usage: seq token-usage [--top N]
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
        .unknown =>
        \\usage: seq <command> --help
        ,
    };

    try stdout.writeAll(body);
    try stdout.writeByte('\n');
    try stdout.writeAll(common);
    try stdout.writeByte('\n');
}

fn validateFormatForCommand(cmd: lib.Command, fmt: output.Format) !void {
    switch (cmd) {
        .skills_rank, .skill_trend, .skill_report, .role_breakdown, .report_bundle, .section_audit, .datasets, .dataset_schema => {
            if (fmt == .jsonl) return error.InvalidFormatForCommand;
        },
        .occurrence_export => {
            if (fmt == .table) return error.InvalidFormatForCommand;
        },
        .find_session, .session_prompts, .query, .token_usage => {},
        .unknown => return error.InvalidCommand,
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

    var rows = try collectDatasetRows(allocator, dataset_name, sessions_root);
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

    var rows = try collectDatasetRows(allocator, "skill_mentions", sessions_root);
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

    var occ_rows = try collectDatasetRows(allocator, "skill_mentions", sessions_root);
    defer deinitQueryRows(allocator, &occ_rows);

    var grouped = try query.execute(allocator, occ_rows.items, query_spec);
    defer grouped.deinit(allocator);
    var known_skills = try loadKnownSkillNames(allocator);
    defer deinitStringSet(allocator, &known_skills);

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
        if (!known_skills.contains(skill_scalar.string)) continue;
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

fn cmdSessionPrompts(allocator: std.mem.Allocator, sessions_root: []const u8, opts: Options) !void {
    const where = [_]spec.WhereClause{
        .{
            .field = "role",
            .op = .eq,
            .value = .{ .scalar = .{ .string = "user" } },
        },
    };
    const select = [_][]const u8{ "timestamp", "path", "text" };
    const query_spec = spec.QuerySpec{
        .where = where[0..],
        .select = select[0..],
        .sort = &.{.{ .field = "timestamp", .descending = false }},
        .limit = opts.limit,
    };
    try runDatasetQuery(allocator, "messages", sessions_root, query_spec, opts.format, opts.out_path, select[0..]);
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
    var rows = try collectDatasetRows(allocator, "messages", sessions_root);
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

fn runDatasetQuery(
    allocator: std.mem.Allocator,
    dataset_name: []const u8,
    sessions_root: []const u8,
    query_spec: spec.QuerySpec,
    fmt: output.Format,
    out_path: ?[]const u8,
    columns_opt: ?[]const []const u8,
) !void {
    var rows = try collectDatasetRows(allocator, dataset_name, sessions_root);
    defer deinitQueryRows(allocator, &rows);

    var result = try query.execute(allocator, rows.items, query_spec);
    defer result.deinit(allocator);

    const cols = if (columns_opt) |c| c else if (query_spec.select.len > 0) query_spec.select else null;
    try output.writeOutput(allocator, fmt, result.rows.items, cols, out_path);
}

fn collectDatasetRows(
    allocator: std.mem.Allocator,
    dataset_name: []const u8,
    sessions_root: []const u8,
) !std.ArrayList(query.Row) {
    var rows: std.ArrayList(query.Row) = .empty;
    errdefer deinitQueryRows(allocator, &rows);

    if (std.mem.eql(u8, dataset_name, "messages")) {
        try collectMessagesRows(allocator, sessions_root, &rows);
    } else if (std.mem.eql(u8, dataset_name, "skill_mentions")) {
        try collectSkillMentionsRows(allocator, sessions_root, &rows);
    } else if (std.mem.eql(u8, dataset_name, "token_events")) {
        try collectTokenEventsRows(allocator, sessions_root, &rows);
    } else if (std.mem.eql(u8, dataset_name, "token_deltas")) {
        try collectTokenDeltasRows(allocator, sessions_root, &rows);
    } else if (std.mem.eql(u8, dataset_name, "token_sessions")) {
        try collectTokenSessionsRows(allocator, sessions_root, &rows);
    } else if (std.mem.eql(u8, dataset_name, "tool_calls")) {
        try collectToolCallsRows(allocator, sessions_root, &rows);
    } else if (std.mem.eql(u8, dataset_name, "memory_files")) {
        try collectMemoryFilesRows(allocator, &rows);
    } else {
        return error.UnknownDataset;
    }

    return rows;
}

fn collectMessagesRows(
    allocator: std.mem.Allocator,
    sessions_root: []const u8,
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root);
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
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root);
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
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root);
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
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root);
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
    out_rows: *std.ArrayList(query.Row),
) !void {
    var paths = try collectJsonlPaths(allocator, sessions_root);
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
    out_rows: *std.ArrayList(query.Row),
) !void {
    var parsed = try datasets.tool_calls.collect(allocator, sessions_root);
    defer datasets.tool_calls.deinitRows(allocator, &parsed);

    for (parsed.items) |row| {
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
    out_rows: *std.ArrayList(query.Row),
) !void {
    var parsed = try datasets.memory_files.collect(allocator, .{});
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

fn loadKnownSkillNames(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var out: std.StringHashMap(void) = .init(allocator);
    errdefer deinitStringSet(allocator, &out);

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (home) |h| allocator.free(h);
    if (home == null) return out;

    const roots = [_][]const u8{
        ".dotfiles/codex/skills",
        ".codex/skills",
    };

    for (roots) |suffix| {
        const dir_path = try std.fs.path.join(allocator, &.{ home.?, suffix });
        defer allocator.free(dir_path);

        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (out.contains(entry.name)) continue;
            const dup = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(dup);
            try out.put(dup, {});
        }
    }

    return out;
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
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.format = try output.Format.parse(args[i]);
            opts.format_set = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.root = args[i];
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
        } else if (std.mem.eql(u8, arg, "--sections")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            opts.sections = args[i];
        } else if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "--max") or std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i >= args.len) return error.MissingArgValue;
            const n = try std.fmt.parseInt(i64, args[i], 10);
            if (n < 0) return error.InvalidLimit;
            opts.limit = @intCast(n);
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

fn collectJsonlPaths(allocator: std.mem.Allocator, root_abs: []const u8) !std.ArrayList([]u8) {
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

test "parse options supports common flags" {
    const args = [_][]const u8{ "--format", "jsonl", "--root", "~/sessions", "--max", "7", "--help" };
    const opts = try parseOptions(args[0..]);
    try std.testing.expectEqual(output.Format.jsonl, opts.format);
    try std.testing.expect(opts.format_set);
    try std.testing.expectEqualStrings("~/sessions", opts.root.?);
    try std.testing.expectEqual(@as(usize, 7), opts.limit);
    try std.testing.expect(opts.help);
}
