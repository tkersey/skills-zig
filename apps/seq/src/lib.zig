const std = @import("std");

pub const Command = enum {
    skills_rank,
    skill_trend,
    skill_report,
    skill_blocks,
    artifact_search,
    role_breakdown,
    occurrence_export,
    orchestration_concurrency,
    find_session,
    plan_search,
    reply_latency,
    session_prompts,
    report_bundle,
    section_audit,
    token_usage,
    routing_gap,
    datasets,
    dataset_schema,
    query,
    session_tooling,
    query_diagnose,
    opencode_prompts,
    opencode_events,
    unknown,
};

pub const CommandDef = struct {
    name: []const u8,
    cmd: Command,
};

const command_defs = [_]CommandDef{
    .{ .name = "skills-rank", .cmd = .skills_rank },
    .{ .name = "skill-trend", .cmd = .skill_trend },
    .{ .name = "skill-report", .cmd = .skill_report },
    .{ .name = "skill-blocks", .cmd = .skill_blocks },
    .{ .name = "artifact-search", .cmd = .artifact_search },
    .{ .name = "role-breakdown", .cmd = .role_breakdown },
    .{ .name = "occurrence-export", .cmd = .occurrence_export },
    .{ .name = "orchestration-concurrency", .cmd = .orchestration_concurrency },
    .{ .name = "find-session", .cmd = .find_session },
    .{ .name = "plan-search", .cmd = .plan_search },
    .{ .name = "reply-latency", .cmd = .reply_latency },
    .{ .name = "session-prompts", .cmd = .session_prompts },
    .{ .name = "report-bundle", .cmd = .report_bundle },
    .{ .name = "section-audit", .cmd = .section_audit },
    .{ .name = "token-usage", .cmd = .token_usage },
    .{ .name = "routing-gap", .cmd = .routing_gap },
    .{ .name = "datasets", .cmd = .datasets },
    .{ .name = "dataset-schema", .cmd = .dataset_schema },
    .{ .name = "query", .cmd = .query },
    .{ .name = "session-tooling", .cmd = .session_tooling },
    .{ .name = "query-diagnose", .cmd = .query_diagnose },
    .{ .name = "opencode-prompts", .cmd = .opencode_prompts },
    .{ .name = "opencode-events", .cmd = .opencode_events },
};

pub fn parseCommand(arg: []const u8) Command {
    for (command_defs) |def| {
        if (std.mem.eql(u8, arg, def.name)) return def.cmd;
    }
    return .unknown;
}

pub fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn commandName(cmd: Command) []const u8 {
    for (command_defs) |def| {
        if (def.cmd == cmd) return def.name;
    }
    return "unknown";
}

pub fn commandNames() []const CommandDef {
    return command_defs[0..];
}

test "parseCommand recognizes full CLI surface" {
    for (command_defs) |def| {
        try std.testing.expectEqual(def.cmd, parseCommand(def.name));
        try std.testing.expect(std.mem.eql(u8, def.name, commandName(def.cmd)));
    }
    try std.testing.expectEqual(Command.unknown, parseCommand("else"));
    try std.testing.expect(isHelpArg("--help"));
    try std.testing.expect(isHelpArg("-h"));
    try std.testing.expect(!isHelpArg("query"));
}
