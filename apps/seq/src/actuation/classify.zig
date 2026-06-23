const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;

pub const Options = struct {
    strict: bool = false,
};

pub const Result = struct {
    candidate: bool,
    true_run: bool,
    evidence_refs: [][]u8,
    contamination_flags: [][]u8,
    reason: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.evidence_refs);
        freeStringList(allocator, self.contamination_flags);
        allocator.free(self.reason);
    }
};

const Counts = struct {
    strong: usize = 0,
    weak: usize = 0,
};

pub fn classifyTrace(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, opts: Options) !Result {
    var evidence: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, evidence.items);
    var contamination: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, contamination.items);
    var counts = Counts{};

    const has_skill_read = traceHasActuatingSkillRead(trace);
    if (traceHasCommand(trace, "st compile aperture") and traceHasPatch(trace) and
        (traceHasCommand(trace, "gh pr create") or traceHasCommand(trace, "gh pr edit") or traceHasCommand(trace, "$ship")))
    {
        try addUnique(allocator, &evidence, "tool_sequence:canonical_plan_to_pr");
        counts.strong += 1;
    }

    for (trace.turns.items) |turn| {
        if (turn.user_message) |text| {
            try inspectText(allocator, &evidence, &contamination, &counts, "user", turn.turn_index, text, has_skill_read);
        }
        if (turn.final_answer orelse turn.assistant_preview) |text| {
            try inspectText(allocator, &evidence, &contamination, &counts, "assistant", turn.turn_index, text, has_skill_read);
        }
    }

    if (has_skill_read and hasAssistantDeclaration(trace)) {
        try addUnique(allocator, &evidence, "tool:skill_read_actuating");
        counts.strong += 1;
    }

    const candidate = counts.strong > 0 or (counts.weak > 0 and !opts.strict);
    const true_run = counts.strong > 0;
    const reason = if (true_run)
        "strong actuation evidence present"
    else if (counts.weak > 0 and opts.strict)
        "weak-only candidate excluded by strict classification"
    else if (counts.weak > 0)
        "weak actuation mention without durable activation evidence"
    else
        "no actuation evidence";

    return .{
        .candidate = candidate,
        .true_run = true_run,
        .evidence_refs = try evidence.toOwnedSlice(allocator),
        .contamination_flags = try contamination.toOwnedSlice(allocator),
        .reason = try allocator.dupe(u8, reason),
    };
}

fn inspectText(
    allocator: std.mem.Allocator,
    evidence: *std.ArrayList([]u8),
    contamination: *std.ArrayList([]u8),
    counts: *Counts,
    role: []const u8,
    turn_index: i64,
    text: []const u8,
    has_skill_read: bool,
) !void {
    const contaminated = try classifyContamination(allocator, contamination, text);
    if (contaminated) {
        counts.weak += 1;
        return;
    }
    if (contains(text, "actuation_frontier") or contains(text, "AFR-v1")) {
        try addEvidence(allocator, evidence, "turn", turn_index, role, "afr_v1");
        counts.strong += 1;
    }
    if (contains(text, "actuation_realization_handoff") or contains(text, "ARH-v1")) {
        try addEvidence(allocator, evidence, "turn", turn_index, role, "arh_v1");
        counts.strong += 1;
    }
    if (contains(text, "fixed_point_slice_result") or contains(text, "FPSR-v1")) {
        try addEvidence(allocator, evidence, "turn", turn_index, role, "fpsr_v1");
        counts.strong += 1;
    }
    if (contains(text, "ASR-v2") or contains(text, "actuation_summary")) {
        try addEvidence(allocator, evidence, "turn", turn_index, role, "asr_v2");
        counts.strong += 1;
    }
    if (contains(text, "skill_decision_receipt") and contains(text, "actuating")) {
        try addEvidence(allocator, evidence, "turn", turn_index, role, "sdr_v1_actuating");
        counts.strong += 1;
    }
    if (std.mem.eql(u8, role, "user") and contains(text, "$actuating")) {
        try addEvidence(allocator, evidence, "turn", turn_index, role, "explicit_user_actuating");
        counts.strong += 1;
        return;
    }
    if (std.mem.eql(u8, role, "assistant") and has_skill_read and assistantDeclaresActuating(text)) {
        try addEvidence(allocator, evidence, "turn", turn_index, role, "assistant_declared_actuating_with_skill_read");
        counts.strong += 1;
        return;
    }
    if (contains(text, "$actuating") or contains(text, "actuating")) {
        try addEvidence(allocator, evidence, "turn", turn_index, role, "generic_actuating_mention");
        counts.weak += 1;
    }
}

fn classifyContamination(allocator: std.mem.Allocator, contamination: *std.ArrayList([]u8), text: []const u8) !bool {
    var contaminated = false;
    if ((contains(text, "<skill>") or contains(text, "SKILL.md")) and contains(text, "actuating")) {
        try addUnique(allocator, contamination, "pasted_skill_block");
        contaminated = true;
    }
    if (contains(text, "SEQ-ACTUATION-AUDIT") or contains(text, "# SPEC: `seq actuation-audit`")) {
        try addUnique(allocator, contamination, "current_audit_prompt");
        contaminated = true;
    }
    if ((contains(text, "example") or contains(text, "documentation")) and contains(text, "$actuating")) {
        try addUnique(allocator, contamination, "documentation_or_example");
        contaminated = true;
    }
    if ((contains(text, "quoted prior report") or contains(text, "```")) and contains(text, "$actuating")) {
        try addUnique(allocator, contamination, "quoted_material");
        contaminated = true;
    }
    return contaminated;
}

fn hasAssistantDeclaration(trace: canonical_trace.CanonicalSessionTrace) bool {
    for (trace.turns.items) |turn| {
        const text = turn.final_answer orelse turn.assistant_preview orelse continue;
        if (assistantDeclaresActuating(text)) return true;
    }
    return false;
}

fn assistantDeclaresActuating(text: []const u8) bool {
    return contains(text, "using $actuating") or
        contains(text, "use $actuating") or
        contains(text, "using actuating") or
        contains(text, "actuating mode");
}

fn traceHasActuatingSkillRead(trace: canonical_trace.CanonicalSessionTrace) bool {
    for (trace.tools.items) |tool| {
        if (tool.command_text) |text| if (contains(text, "actuating/SKILL.md") or contains(text, "codex/skills/actuating")) return true;
        if (tool.input_text) |text| if (contains(text, "actuating/SKILL.md") or contains(text, "codex/skills/actuating")) return true;
        if (tool.arguments_json) |text| if (contains(text, "actuating/SKILL.md") or contains(text, "codex/skills/actuating")) return true;
    }
    return false;
}

fn traceHasCommand(trace: canonical_trace.CanonicalSessionTrace, needle: []const u8) bool {
    for (trace.tools.items) |tool| {
        if (tool.command_text) |text| if (contains(text, needle)) return true;
        if (tool.input_text) |text| if (contains(text, needle)) return true;
    }
    return false;
}

fn traceHasPatch(trace: canonical_trace.CanonicalSessionTrace) bool {
    for (trace.tools.items) |tool| {
        if (tool.kind == .patch_apply) return true;
        if (tool.patch_changes_json != null) return true;
        if (tool.tool_name) |name| if (contains(name, "apply_patch")) return true;
    }
    return false;
}

fn addEvidence(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), prefix: []const u8, turn_index: i64, role: []const u8, kind: []const u8) !void {
    const value = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}:{s}", .{ prefix, turn_index, role, kind });
    errdefer allocator.free(value);
    try addOwnedUnique(allocator, list, value);
}

fn addUnique(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try addOwnedUnique(allocator, list, owned);
}

fn addOwnedUnique(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) {
            allocator.free(value);
            return;
        }
    }
    try list.append(allocator, value);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}
