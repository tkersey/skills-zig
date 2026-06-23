const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;

pub const CompactionSummary = struct {
    compactions: usize = 0,
    compactions_with_resume_artifact: usize = 0,
    skill_reads_after_compaction: usize = 0,
    rediscovery_tool_calls: usize = 0,

    pub fn resumeCoverageRatio(self: CompactionSummary) f64 {
        if (self.compactions == 0) return 0;
        return @as(f64, @floatFromInt(self.compactions_with_resume_artifact)) / @as(f64, @floatFromInt(self.compactions));
    }
};

pub fn analyzeTrace(trace: canonical_trace.CanonicalSessionTrace) CompactionSummary {
    var summary = CompactionSummary{};
    for (trace.turns.items) |turn| {
        if (!turn.has_compaction) continue;
        summary.compactions += 1;
        var saw_resume = false;
        for (trace.tools.items) |tool| {
            if ((tool.turn_index orelse -1) <= turn.turn_index) continue;
            if (isResumeArtifact(tool)) saw_resume = true;
            if (isSkillRead(tool)) summary.skill_reads_after_compaction += 1;
            if (isRediscovery(tool)) summary.rediscovery_tool_calls += 1;
            if (isMutation(tool)) break;
        }
        if (saw_resume) summary.compactions_with_resume_artifact += 1;
    }
    return summary;
}

fn isResumeArtifact(tool: canonical_trace.ToolLifecycleRecord) bool {
    return toolContains(tool, "ASR-v2") or toolContains(tool, "AFR-v1") or toolContains(tool, "actuation_summary") or toolContains(tool, "graph_control_receipt");
}

fn isSkillRead(tool: canonical_trace.ToolLifecycleRecord) bool {
    return toolContains(tool, "SKILL.md") or toolContains(tool, "codex/skills/");
}

fn isRediscovery(tool: canonical_trace.ToolLifecycleRecord) bool {
    return toolContains(tool, "rg ") or toolContains(tool, "sed -n") or toolContains(tool, "update_plan");
}

fn isMutation(tool: canonical_trace.ToolLifecycleRecord) bool {
    return tool.kind == .patch_apply or tool.patch_changes_json != null;
}

fn toolContains(tool: canonical_trace.ToolLifecycleRecord, needle: []const u8) bool {
    if (tool.command_text) |text| if (contains(text, needle)) return true;
    if (tool.input_text) |text| if (contains(text, needle)) return true;
    if (tool.output_text) |text| if (contains(text, needle)) return true;
    if (tool.tool_name) |text| if (contains(text, needle)) return true;
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "compaction analyzer tracks resume artifact and skill reads" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/run.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/run.jsonl"), .turn_id = try std.testing.allocator.dupe(u8, "t1"), .turn_index = 1, .has_compaction = true });
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/run.jsonl"), .turn_index = 2, .kind = .exec_command, .command_text = try std.testing.allocator.dupe(u8, "sed -n '1,20p' actuating/SKILL.md"), .output_text = try std.testing.allocator.dupe(u8, "ASR-v2") });
    const summary = analyzeTrace(trace);
    try std.testing.expectEqual(@as(usize, 1), summary.compactions);
    try std.testing.expectEqual(@as(usize, 1), summary.compactions_with_resume_artifact);
    try std.testing.expectEqual(@as(usize, 1), summary.skill_reads_after_compaction);
}
