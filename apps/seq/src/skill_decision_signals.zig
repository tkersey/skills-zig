const std = @import("std");

pub const SignalKind = enum {
    explicit_user_activation,
    assistant_declared_activation,
    injected_skill_block,
    skill_file_read,
    target_lens_use,
    raw_mention,
    receipt,
    trigger_cue,
    selected_route,
    rejected_route,
    prevented_action,
    scope_narrowing,
    proof_change,
    block_or_escalation,
    required_artifact,
    success_signal,
    failure_signal,
    tool_action,
    validation_pass,
    validation_fail,
    commit,
    push,
    pr,
    review_reopen,
    reversal,
    closure,
    session_stop,
    worker_link,
};

pub fn signalKindName(kind: SignalKind) []const u8 {
    return @tagName(kind);
}

pub fn classifySkillMention(role: []const u8, types: []const u8) SignalKind {
    if (std.mem.indexOf(u8, types, "block") != null) return .injected_skill_block;
    if (std.mem.eql(u8, role, "user")) return .explicit_user_activation;
    if (std.mem.eql(u8, role, "assistant")) return .assistant_declared_activation;
    return .raw_mention;
}

pub fn confidenceForSignal(kind: SignalKind) f64 {
    return switch (kind) {
        .explicit_user_activation, .assistant_declared_activation, .receipt => 1.0,
        .injected_skill_block, .skill_file_read, .target_lens_use => 0.8,
        .raw_mention => 0.2,
        else => 0.6,
    };
}

pub fn contaminationFlags(text: []const u8) []const u8 {
    if (std.mem.indexOf(u8, text, "SEQ-SKILL-DECISION-v1") != null or
        std.mem.indexOf(u8, text, "skill-decision-audit") != null)
    {
        return "current_audit_prompt";
    }
    if (std.mem.indexOf(u8, text, "skill_decision_contract:") != null or
        std.mem.indexOf(u8, text, "\"skill_decision_contract\"") != null)
    {
        return "contract_example";
    }
    return "";
}

pub fn skillFromSkillFileReadText(text: []const u8) ?[]const u8 {
    const marker = "SKILL.md";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, text, cursor, marker)) |idx| {
        var end = idx;
        while (end > 0 and isPathSep(text[end - 1])) : (end -= 1) {}
        var start = end;
        while (start > 0 and !isPathSep(text[start - 1]) and text[start - 1] != '"' and text[start - 1] != '\'') : (start -= 1) {}
        if (end > start) return text[start..end];
        cursor = idx + marker.len;
    }
    return null;
}

pub fn nextDollarSkill(text: []const u8, start: usize) ?struct { skill: []const u8, end: usize } {
    var cursor = start;
    while (std.mem.indexOfScalarPos(u8, text, cursor, '$')) |idx| {
        const name_start = idx + 1;
        var end = name_start;
        while (end < text.len and isSkillNameChar(text[end])) : (end += 1) {}
        if (end > name_start) return .{ .skill = text[name_start..end], .end = end };
        cursor = idx + 1;
    }
    return null;
}

fn isSkillNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
}

fn isPathSep(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

test "classifies skill mentions without treating blocks as activation" {
    try std.testing.expectEqual(SignalKind.explicit_user_activation, classifySkillMention("user", "dollar"));
    try std.testing.expectEqual(SignalKind.assistant_declared_activation, classifySkillMention("assistant", "dollar"));
    try std.testing.expectEqual(SignalKind.injected_skill_block, classifySkillMention("user", "block,dollar"));
}

test "extracts skill names from dollar tokens and skill file reads" {
    const first = nextDollarSkill("use $team-patterns now", 0).?;
    try std.testing.expect(std.mem.eql(u8, first.skill, "team-patterns"));
    const skill = skillFromSkillFileReadText("/Users/tk/.dotfiles/codex/skills/team-patterns/SKILL.md").?;
    try std.testing.expect(std.mem.eql(u8, skill, "team-patterns"));
}
