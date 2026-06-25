const std = @import("std");
const lib = @import("../lib.zig");
const output = @import("../output/mod.zig");

pub const FlagValueKind = enum {
    bool,
    string,
    int,
    duration,
    csv,
    format,
    path,
    json_or_at_file,
};

pub const FlagSpec = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    value_kind: FlagValueKind,
    required: bool = false,
    help: []const u8,
};

pub const CommandSpec = struct {
    name: []const u8,
    command: lib.Command,
    summary: []const u8,
    usage: []const u8,
    examples: []const []const u8 = &.{},
    flags: []const FlagSpec = &.{},
    default_format: output.Format = .table,
    allowed_formats: []const output.Format = &.{ .table, .json, .csv, .jsonl },
};

const query_flags = [_]FlagSpec{
    .{ .name = "--spec", .value_kind = .json_or_at_file, .required = true, .help = "Query spec JSON or @file" },
    .{ .name = "--root", .value_kind = .path, .help = "Codex sessions root" },
    .{ .name = "--stats", .value_kind = .bool, .help = "Emit SeqStats counters" },
};

const session_flags = [_]FlagSpec{
    .{ .name = "--root", .value_kind = .path, .help = "Codex sessions root" },
    .{ .name = "--limit", .value_kind = .int, .help = "Maximum rows" },
    .{ .name = "--stats", .value_kind = .bool, .help = "Emit SeqStats counters" },
};

const skill_decision_audit_flags = [_]FlagSpec{
    .{ .name = "--skill", .value_kind = .string, .required = true, .help = "Target skill name" },
    .{ .name = "--root", .value_kind = .path, .help = "Codex sessions root" },
    .{ .name = "--session-id", .value_kind = .string, .help = "Scan one session by id" },
    .{ .name = "--path", .value_kind = .path, .help = "Scan one rollout JSONL path" },
    .{ .name = "--repo", .value_kind = .path, .help = "Filter by repository root" },
    .{ .name = "--workdir", .value_kind = .path, .help = "Filter by workdir" },
    .{ .name = "--last", .value_kind = .duration, .help = "Relative window" },
    .{ .name = "--since", .value_kind = .string, .help = "Inclusive start timestamp" },
    .{ .name = "--until", .value_kind = .string, .help = "Inclusive end timestamp" },
    .{ .name = "--mode", .value_kind = .string, .help = "summary, episodes, misses, clauses, outcomes, tune-packet, or delta" },
    .{ .name = "--causality", .value_kind = .string, .help = "explicit, strong, associated, or any" },
    .{ .name = "--format", .value_kind = .format, .help = "Output format" },
};

const skill_contract_flags = [_]FlagSpec{
    .{ .name = "--file", .value_kind = .path, .help = "Contract file for validate" },
    .{ .name = "--skill", .value_kind = .string, .help = "Skill name for show/scaffold" },
    .{ .name = "--skill-root", .value_kind = .path, .help = "Skill root for show" },
    .{ .name = "--kind", .value_kind = .string, .help = "Contract kind for scaffold" },
    .{ .name = "--output", .value_kind = .path, .help = "Output path for scaffold" },
    .{ .name = "--format", .value_kind = .format, .help = "Output format" },
};

const skill_decision_receipt_flags = [_]FlagSpec{
    .{ .name = "--file", .value_kind = .path, .required = true, .help = "Receipt file for validate" },
    .{ .name = "--format", .value_kind = .format, .help = "Output format" },
};

const decision_capsule_flags = [_]FlagSpec{
    .{ .name = "--session-id", .value_kind = .string, .help = "Source session id" },
    .{ .name = "--path", .value_kind = .path, .help = "Source rollout JSONL path, or capsule path in validate mode" },
    .{ .name = "--decision-id", .value_kind = .string, .help = "Select a specific decision id" },
    .{ .name = "--turn-id", .value_kind = .string, .help = "Select a decision turn id" },
    .{ .name = "--turn-index", .value_kind = .int, .help = "Select a one-based decision turn index" },
    .{ .name = "--skill", .value_kind = .string, .help = "Filter by visible skill reference" },
    .{ .name = "--contains", .value_kind = .string, .help = "Filter visible candidate text" },
    .{ .name = "--regex", .value_kind = .string, .help = "Filter visible candidate text by pattern text" },
    .{ .name = "--mode", .value_kind = .string, .help = "capsule, candidates, anchors, or validate" },
    .{ .name = "--anchor", .value_kind = .string, .help = "pre, post, outcome, or all" },
    .{ .name = "--outcome-policy", .value_kind = .string, .help = "explicit, conservative, or none" },
    .{ .name = "--include-workers", .value_kind = .bool, .help = "Reserve worker lineage fields when available" },
    .{ .name = "--include-excerpts", .value_kind = .bool, .help = "Allow bounded visible excerpts" },
    .{ .name = "--excerpt-chars", .value_kind = .int, .help = "Maximum excerpt characters" },
    .{ .name = "--format", .value_kind = .format, .help = "Output format" },
};

const actuation_audit_flags = [_]FlagSpec{
    .{ .name = "--root", .value_kind = .path, .help = "Codex sessions root" },
    .{ .name = "--session-id", .value_kind = .string, .help = "Scan one session by id" },
    .{ .name = "--path", .value_kind = .path, .help = "Scan one rollout JSONL path" },
    .{ .name = "--repo", .value_kind = .path, .help = "Require repo/workdir lineage under this path" },
    .{ .name = "--workdir", .value_kind = .path, .help = "Require session/tool cwd under this path" },
    .{ .name = "--since", .value_kind = .string, .help = "Inclusive start timestamp" },
    .{ .name = "--until", .value_kind = .string, .help = "Inclusive end timestamp" },
    .{ .name = "--last", .value_kind = .duration, .help = "Relative time window" },
    .{ .name = "--exclude-current", .value_kind = .bool, .help = "Exclude the current CODEX_THREAD_ID session" },
    .{ .name = "--include-workers", .value_kind = .bool, .help = "Include linked worker sessions" },
    .{ .name = "--mode", .value_kind = .string, .help = "summary, runs, slices, proof, compactions, decisions, or report" },
    .{ .name = "--strict", .value_kind = .bool, .help = "Exit 2 on actuation control violations" },
    .{ .name = "--include-excerpts", .value_kind = .bool, .help = "Allow bounded sanitized excerpts" },
    .{ .name = "--format", .value_kind = .format, .help = "Output format" },
};

const execution_policy_audit_flags = [_]FlagSpec{
    .{ .name = "--root", .value_kind = .path, .help = "Codex sessions root" },
    .{ .name = "--session-id", .value_kind = .string, .help = "Scan one session by id" },
    .{ .name = "--path", .value_kind = .path, .help = "Scan one rollout JSONL path" },
    .{ .name = "--repo", .value_kind = .path, .help = "Require repo/workdir lineage under this path" },
    .{ .name = "--since", .value_kind = .string, .help = "Inclusive start timestamp" },
    .{ .name = "--until", .value_kind = .string, .help = "Inclusive end timestamp" },
    .{ .name = "--last", .value_kind = .duration, .help = "Relative time window" },
    .{ .name = "--exclude-current", .value_kind = .bool, .help = "Exclude the current CODEX_THREAD_ID session" },
    .{ .name = "--include-workers", .value_kind = .bool, .help = "Include linked worker sessions" },
    .{ .name = "--policy-root", .value_kind = .path, .help = "Policy artifact root" },
    .{ .name = "--mode", .value_kind = .string, .help = "summary, runs, policies, transitions, calibration, regret, proof, or report" },
    .{ .name = "--strict", .value_kind = .bool, .help = "Exit 2 on current-protocol execution policy violations" },
    .{ .name = "--format", .value_kind = .format, .help = "Output format" },
};

const st_workspace_audit_flags = [_]FlagSpec{
    .{ .name = "--root", .value_kind = .path, .help = "Codex sessions root" },
    .{ .name = "--repo", .value_kind = .path, .help = "Require repo/workspace lineage under this path" },
    .{ .name = "--workspace-root", .value_kind = .path, .help = ".ledger/st workspace artifact root" },
    .{ .name = "--workspace-id", .value_kind = .string, .help = "Filter one workspace id" },
    .{ .name = "--plan", .value_kind = .string, .help = "Filter one plan id" },
    .{ .name = "--session-id", .value_kind = .string, .help = "Filter one session id" },
    .{ .name = "--since", .value_kind = .string, .help = "Inclusive start timestamp" },
    .{ .name = "--until", .value_kind = .string, .help = "Inclusive end timestamp" },
    .{ .name = "--last", .value_kind = .duration, .help = "Relative time window" },
    .{ .name = "--exclude-current", .value_kind = .bool, .help = "Exclude the current CODEX_THREAD_ID session" },
    .{ .name = "--mode", .value_kind = .string, .help = "summary, workspaces, plans, claims, sessions, apertures, gcr, changesets, proof, integration, evidence, or report" },
    .{ .name = "--strict", .value_kind = .bool, .help = "Exit 2 on P0/P1 findings or artifact inconsistency" },
    .{ .name = "--format", .value_kind = .format, .help = "Output format" },
};

pub fn commandNames() []const lib.CommandDef {
    return lib.commandNames();
}

pub fn parseCommand(name: []const u8) lib.Command {
    return lib.parseCommand(name);
}

pub fn commandName(command: lib.Command) []const u8 {
    return lib.commandName(command);
}

pub fn commandSpec(command: lib.Command) ?CommandSpec {
    if (command == .unknown) return null;
    const name = lib.commandName(command);
    if (std.mem.eql(u8, name, "unknown")) return null;
    return .{
        .name = name,
        .command = command,
        .summary = summaryFor(command),
        .usage = usageFor(command),
        .flags = flagsFor(command),
        .default_format = defaultFormatFor(command),
        .allowed_formats = allowedFormatsFor(command),
    };
}

fn summaryFor(command: lib.Command) []const u8 {
    return switch (command) {
        .query => "Run a dataset query spec over local session artifacts",
        .skill_decision_audit => "Compile deterministic per-skill decision episodes and STE-v1 evidence",
        .decision_capsule => "Freeze one visible historical decision as DCP-v2",
        .actuation_audit => "Audit plan-to-PR actuation control, frontier, proof, compaction, and ship lineage",
        .execution_policy_audit => "Audit EPG-guided planning/execution policy runtime lineage and calibration",
        .st_workspace_audit => "Audit .ledger/st multi-plan workspace claims, projections, GCR, changesets, proof, and legacy writes",
        .skill_contract => "Validate, show, or scaffold SKDC-v1 decision contracts",
        .skill_decision_receipt => "Validate SDR-v1 skill decision receipts",
        .capabilities => "Print seq feature capability flags",
        .sessions => "List canonical session summaries",
        .turns => "List canonical session turns",
        .tool_lifecycle => "List canonical tool lifecycle records",
        .tail => "Tail the current or selected session",
        else => lib.commandName(command),
    };
}

fn usageFor(command: lib.Command) []const u8 {
    return switch (command) {
        .query => "seq query --spec <json|@path> [--root <path>] [--stats]",
        .skill_decision_audit => "seq skill-decision-audit --skill <name> (--session-id <id>|--path <jsonl>|--repo <path>|--workdir <path>|--last <duration>|--since <iso>|--until <iso>)",
        .decision_capsule => "seq decision-capsule (--session-id <id>|--path <jsonl>) [--decision-id <id>|--turn-id <id>|--turn-index N] [--mode capsule|candidates|anchors|validate]",
        .actuation_audit => "seq actuation-audit --root <path> (--session-id <id>|--path <jsonl>|(--repo <path>|--workdir <path>) (--last <duration>|--since <iso>|--until <iso>))",
        .execution_policy_audit => "seq execution-policy-audit --root <path> (--session-id <id>|--path <jsonl>|--repo <path>|--last <duration>|--since <iso>|--until <iso>)",
        .st_workspace_audit => "seq st-workspace-audit [--root <path>] [--repo <path>] [--workspace-root <path>] [--workspace-id <id>] [--plan <plan-id>] [--session-id <id>]",
        .skill_contract => "seq skill-contract validate --file <path>",
        .skill_decision_receipt => "seq skill-decision-receipt validate --file <path>",
        .capabilities => "seq capabilities [--format json]",
        .sessions => "seq sessions [--root <path>] [--limit N] [--stats]",
        else => "seq <command> [options]",
    };
}

fn flagsFor(command: lib.Command) []const FlagSpec {
    return switch (command) {
        .query => query_flags[0..],
        .skill_decision_audit => skill_decision_audit_flags[0..],
        .decision_capsule => decision_capsule_flags[0..],
        .actuation_audit => actuation_audit_flags[0..],
        .execution_policy_audit => execution_policy_audit_flags[0..],
        .st_workspace_audit => st_workspace_audit_flags[0..],
        .skill_contract => skill_contract_flags[0..],
        .skill_decision_receipt => skill_decision_receipt_flags[0..],
        .sessions => session_flags[0..],
        else => &.{},
    };
}

fn defaultFormatFor(command: lib.Command) output.Format {
    return switch (command) {
        .query => .jsonl,
        .capabilities => .table,
        .decision_capsule => .json,
        .actuation_audit => .table,
        .execution_policy_audit => .table,
        .st_workspace_audit => .table,
        .skill_decision_audit => .table,
        .sessions => .table,
        else => .table,
    };
}

fn allowedFormatsFor(command: lib.Command) []const output.Format {
    return switch (command) {
        .session_graph => &.{ .table, .json, .jsonl, .dot },
        .decision_capsule => &.{ .table, .json, .csv, .jsonl, .markdown },
        .actuation_audit => &.{ .table, .json, .csv, .jsonl, .markdown },
        .execution_policy_audit => &.{ .table, .json, .csv, .jsonl, .markdown },
        .st_workspace_audit => &.{ .table, .json, .csv, .jsonl, .markdown },
        .skill_decision_audit => &.{ .table, .json, .csv, .jsonl, .markdown },
        .capabilities, .skill_contract, .skill_decision_receipt => &.{ .table, .json, .csv, .jsonl },
        .session_detail => &.{ .json, .markdown },
        .tail => &.{ .table, .jsonl },
        else => &.{ .table, .json, .csv, .jsonl },
    };
}

test "registry covers every command and parses names" {
    var seen = std.AutoHashMap(lib.Command, void).init(std.testing.allocator);
    defer seen.deinit();

    for (commandNames()) |def| {
        const entry = commandSpec(def.cmd) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(def.cmd, parseCommand(entry.name));
        try std.testing.expect(std.mem.eql(u8, entry.name, commandName(def.cmd)));
        try std.testing.expect(entry.usage.len > 0);
        try std.testing.expect(entry.summary.len > 0);
        try seen.put(def.cmd, {});
    }

    inline for (std.meta.fields(lib.Command)) |field| {
        const command: lib.Command = @enumFromInt(field.value);
        if (command == .unknown) continue;
        try std.testing.expect(seen.contains(command));
    }
}

test "registry exposes listed flags for query and sessions" {
    const query = commandSpec(.query) orelse return error.TestExpectedEqual;
    try std.testing.expect(query.flags.len >= 2);
    try std.testing.expect(std.mem.eql(u8, query.flags[0].name, "--spec"));
    try std.testing.expect(query.flags[0].required);

    const sessions = commandSpec(.sessions) orelse return error.TestExpectedEqual;
    var has_stats = false;
    for (sessions.flags) |flag| {
        if (std.mem.eql(u8, flag.name, "--stats")) has_stats = true;
    }
    try std.testing.expect(has_stats);
}

test "registry exposes actuation-audit command surface" {
    const spec = commandSpec(.actuation_audit) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.eql(u8, spec.name, "actuation-audit"));
    try std.testing.expectEqual(output.Format.table, spec.default_format);

    var has_include_workers = false;
    var has_strict = false;
    for (spec.flags) |flag| {
        if (std.mem.eql(u8, flag.name, "--include-workers")) has_include_workers = true;
        if (std.mem.eql(u8, flag.name, "--strict")) has_strict = true;
    }
    try std.testing.expect(has_include_workers);
    try std.testing.expect(has_strict);
}

test "registry exposes execution-policy-audit command surface" {
    const spec = commandSpec(.execution_policy_audit) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.eql(u8, spec.name, "execution-policy-audit"));
    try std.testing.expectEqual(output.Format.table, spec.default_format);

    var has_policy_root = false;
    var has_include_workers = false;
    var has_strict = false;
    for (spec.flags) |flag| {
        if (std.mem.eql(u8, flag.name, "--policy-root")) has_policy_root = true;
        if (std.mem.eql(u8, flag.name, "--include-workers")) has_include_workers = true;
        if (std.mem.eql(u8, flag.name, "--strict")) has_strict = true;
    }
    try std.testing.expect(has_policy_root);
    try std.testing.expect(has_include_workers);
    try std.testing.expect(has_strict);
}
