comptime {
    _ = @import("lib.zig");
    _ = @import("tests/correctness_golden.zig");
    _ = @import("tests/fuzz_regression.zig");
    _ = @import("tests/allocation_failure.zig");
    _ = @import("types/spec.zig");
    _ = @import("query/mod.zig");
    _ = @import("query/engine.zig");
    _ = @import("output/mod.zig");
    _ = @import("commands/mod.zig");
    _ = @import("datasets/mod.zig");
    _ = @import("datasets/messages.zig");
    _ = @import("datasets/skill_mentions.zig");
    _ = @import("datasets/token_events.zig");
    _ = @import("datasets/token_deltas.zig");
    _ = @import("datasets/token_sessions.zig");
    _ = @import("datasets/tool_calls.zig");
    _ = @import("datasets/memory_files.zig");
    _ = @import("perf_parser.zig");
    _ = @import("main.zig");
}

const std = @import("std");
const lib = @import("lib.zig");

test "bootstrap parse coverage" {
    try std.testing.expectEqual(lib.Command.skills_rank, lib.parseCommand("skills-rank"));
    try std.testing.expectEqual(lib.Command.skill_trend, lib.parseCommand("skill-trend"));
    try std.testing.expectEqual(lib.Command.skill_report, lib.parseCommand("skill-report"));
    try std.testing.expectEqual(lib.Command.role_breakdown, lib.parseCommand("role-breakdown"));
    try std.testing.expectEqual(lib.Command.occurrence_export, lib.parseCommand("occurrence-export"));
    try std.testing.expectEqual(lib.Command.find_session, lib.parseCommand("find-session"));
    try std.testing.expectEqual(lib.Command.session_prompts, lib.parseCommand("session-prompts"));
    try std.testing.expectEqual(lib.Command.report_bundle, lib.parseCommand("report-bundle"));
    try std.testing.expectEqual(lib.Command.section_audit, lib.parseCommand("section-audit"));
    try std.testing.expectEqual(lib.Command.token_usage, lib.parseCommand("token-usage"));
    try std.testing.expectEqual(lib.Command.routing_gap, lib.parseCommand("routing-gap"));
    try std.testing.expectEqual(lib.Command.datasets, lib.parseCommand("datasets"));
    try std.testing.expectEqual(lib.Command.dataset_schema, lib.parseCommand("dataset-schema"));
    try std.testing.expectEqual(lib.Command.query, lib.parseCommand("query"));
    try std.testing.expectEqual(lib.Command.unknown, lib.parseCommand("invalid"));
}
