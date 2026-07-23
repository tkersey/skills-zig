const std = @import("std");

pub const Command = enum {
    skills_rank,
    skill_success_rank,
    skill_trend,
    skill_report,
    skill_audit,
    skill_evidence,
    skill_decision_audit,
    skill_contract,
    skill_decision_receipt,
    decision_capsule,
    skill_blocks,
    artifact_search,
    tool_audit,
    memory_inventory,
    message_search,
    message_audit,
    skill_cohort,
    tool_search,
    memory_extension_audit,
    token_window,
    workdir_report,
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
    token_cost,
    routing_gap,
    datasets,
    dataset_schema,
    query,
    adjudication_audit,
    resolve_churn_audit,
    review_compiler_audit,
    cas_review_audit,
    workflow_audit,
    workflow_overlap,
    session_tooling,
    query_diagnose,
    capabilities,
    sessions,
    turns,
    session_detail,
    tool_lifecycle,
    session_graph,
    tail,
    memory_provenance,
    memory_map,
    memory_history,
    opencode_prompts,
    opencode_events,
    goal_audit,
    index,
    actuation_audit,
    execution_policy_audit,
    policy_calibration,
    unknown,
};

pub const CommandDef = struct {
    name: []const u8,
    cmd: Command,
};

pub const command_defs = [_]CommandDef{
    .{ .name = "skills-rank", .cmd = .skills_rank },
    .{ .name = "skill-success-rank", .cmd = .skill_success_rank },
    .{ .name = "skill-trend", .cmd = .skill_trend },
    .{ .name = "skill-report", .cmd = .skill_report },
    .{ .name = "skill-audit", .cmd = .skill_audit },
    .{ .name = "skill-evidence", .cmd = .skill_evidence },
    .{ .name = "skill-decision-audit", .cmd = .skill_decision_audit },
    .{ .name = "skill-contract", .cmd = .skill_contract },
    .{ .name = "skill-decision-receipt", .cmd = .skill_decision_receipt },
    .{ .name = "decision-capsule", .cmd = .decision_capsule },
    .{ .name = "skill-blocks", .cmd = .skill_blocks },
    .{ .name = "artifact-search", .cmd = .artifact_search },
    .{ .name = "tool-audit", .cmd = .tool_audit },
    .{ .name = "memory-inventory", .cmd = .memory_inventory },
    .{ .name = "message-search", .cmd = .message_search },
    .{ .name = "message-audit", .cmd = .message_audit },
    .{ .name = "skill-cohort", .cmd = .skill_cohort },
    .{ .name = "tool-search", .cmd = .tool_search },
    .{ .name = "memory-extension-audit", .cmd = .memory_extension_audit },
    .{ .name = "token-window", .cmd = .token_window },
    .{ .name = "workdir-report", .cmd = .workdir_report },
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
    .{ .name = "token-cost", .cmd = .token_cost },
    .{ .name = "routing-gap", .cmd = .routing_gap },
    .{ .name = "datasets", .cmd = .datasets },
    .{ .name = "dataset-schema", .cmd = .dataset_schema },
    .{ .name = "query", .cmd = .query },
    .{ .name = "adjudication-audit", .cmd = .adjudication_audit },
    .{ .name = "resolve-churn-audit", .cmd = .resolve_churn_audit },
    .{ .name = "review-compiler-audit", .cmd = .review_compiler_audit },
    .{ .name = "cas-review-audit", .cmd = .cas_review_audit },
    .{ .name = "goal-audit", .cmd = .goal_audit },
    .{ .name = "workflow-audit", .cmd = .workflow_audit },
    .{ .name = "workflow-overlap", .cmd = .workflow_overlap },
    .{ .name = "session-tooling", .cmd = .session_tooling },
    .{ .name = "query-diagnose", .cmd = .query_diagnose },
    .{ .name = "capabilities", .cmd = .capabilities },
    .{ .name = "sessions", .cmd = .sessions },
    .{ .name = "turns", .cmd = .turns },
    .{ .name = "session-detail", .cmd = .session_detail },
    .{ .name = "tool-lifecycle", .cmd = .tool_lifecycle },
    .{ .name = "session-graph", .cmd = .session_graph },
    .{ .name = "tail", .cmd = .tail },
    .{ .name = "memory-provenance", .cmd = .memory_provenance },
    .{ .name = "memory-map", .cmd = .memory_map },
    .{ .name = "memory-history", .cmd = .memory_history },
    .{ .name = "opencode-prompts", .cmd = .opencode_prompts },
    .{ .name = "opencode-events", .cmd = .opencode_events },
    .{ .name = "index", .cmd = .index },
    .{ .name = "actuation-audit", .cmd = .actuation_audit },
    .{ .name = "execution-policy-audit", .cmd = .execution_policy_audit },
    .{ .name = "policy-calibration", .cmd = .policy_calibration },
};

pub fn parseCommand(arg: []const u8) Command {
    for (command_defs) |def| {
        if (std.mem.eql(u8, arg, def.name)) {
            return if (commandAvailable(def.cmd)) def.cmd else .unknown;
        }
    }
    return .unknown;
}

pub fn commandAvailable(_: Command) bool {
    return true;
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
        const expected: Command = if (commandAvailable(def.cmd)) def.cmd else .unknown;
        try std.testing.expectEqual(expected, parseCommand(def.name));
        try std.testing.expect(std.mem.eql(u8, def.name, commandName(def.cmd)));
    }
    try std.testing.expectEqual(Command.unknown, parseCommand("else"));
    try std.testing.expect(isHelpArg("--help"));
    try std.testing.expect(isHelpArg("-h"));
    try std.testing.expect(!isHelpArg("query"));
}
