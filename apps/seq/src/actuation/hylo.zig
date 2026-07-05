const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const gcr = @import("gcr.zig");
const output = @import("../output/mod.zig");

pub const quality_state_count = 7;
pub const failure_class_count = 15;

pub const quality_state_names = [_][]const u8{
    "absent",
    "partial",
    "stale",
    "contradictory",
    "present_unverified",
    "present_verified",
    "present_and_closed",
};

pub const failure_class_names = [_][]const u8{
    "missing_alsr",
    "missing_hyl",
    "missing_unfold",
    "unfold_not_current",
    "mutation_without_unfold",
    "action_without_fold",
    "fold_without_current_artifact",
    "continue_without_next_seed",
    "terminal_without_stop_rule",
    "terminal_without_atcg",
    "parallel_fanout_without_fanin",
    "stale_hylo_after_diff_change",
    "resolve_without_review_fold",
    "raw_review_to_patch",
    "cached_cas_counted_as_fresh",
};

const QualityState = enum(u8) {
    absent = 0,
    partial = 1,
    stale = 2,
    contradictory = 3,
    present_unverified = 4,
    present_verified = 5,
    present_and_closed = 6,
};

const FailureClass = enum(u8) {
    missing_alsr = 0,
    missing_hyl = 1,
    missing_unfold = 2,
    unfold_not_current = 3,
    mutation_without_unfold = 4,
    action_without_fold = 5,
    fold_without_current_artifact = 6,
    continue_without_next_seed = 7,
    terminal_without_stop_rule = 8,
    terminal_without_atcg = 9,
    parallel_fanout_without_fanin = 10,
    stale_hylo_after_diff_change = 11,
    resolve_without_review_fold = 12,
    raw_review_to_patch = 13,
    cached_cas_counted_as_fresh = 14,
};

const TextStats = struct {
    alsr_count: usize = 0,
    hyl_count: usize = 0,
    hsr_step_count: usize = 0,
    unfold_count: usize = 0,
    action_count: usize = 0,
    fold_count: usize = 0,
    continue_count: usize = 0,
    next_state_count: usize = 0,
    terminal_fold_count: usize = 0,
    stop_rule_count: usize = 0,
    atcg_count: usize = 0,
    resume_packet_count: usize = 0,
    current_artifact_yes_count: usize = 0,
    current_artifact_no_count: usize = 0,
    stale_count: usize = 0,
    contradictory_count: usize = 0,
    parallel_frontier_count: usize = 0,
    fanin_count: usize = 0,
    review_marker_count: usize = 0,
    review_fold_count: usize = 0,
    raw_review_patch_count: usize = 0,
    direct_action_fused_count: usize = 0,
    controller_governed_count: usize = 0,
    cached_cas_counted_fresh_count: usize = 0,
    ship_effect_count: usize = 0,
    publication_boundary_count: usize = 0,

    fn anyGovernance(self: TextStats) bool {
        return self.alsr_count > 0 or self.hyl_count > 0 or self.hsr_step_count > 0 or self.resume_packet_count > 0 or self.directActionFused() or self.controllerGoverned();
    }

    fn directActionFused(self: TextStats) bool {
        return self.direct_action_fused_count > 0 and
            self.review_marker_count == 0 and
            self.parallel_frontier_count == 0 and
            self.ship_effect_count == 0;
    }

    fn controllerGoverned(self: TextStats) bool {
        return self.controller_governed_count > 0;
    }
};

pub const RunSummary = struct {
    true_run: bool = false,
    hylo_required: bool = false,
    alsr_present: bool = false,
    hyl_present: bool = false,
    hsr_step_count: usize = 0,
    mutations: usize = 0,
    mutations_with_unfold: usize = 0,
    actions_without_fold: usize = 0,
    continues_without_next_state: usize = 0,
    terminal_folds: usize = 0,
    atcg_after_terminal_fold: usize = 0,
    graph_bypass: bool = false,
    quality_state: []const u8 = "absent",
    failure_counts: [failure_class_count]usize = .{0} ** failure_class_count,
};

pub fn analyzeTrace(trace: canonical_trace.CanonicalSessionTrace, true_run: bool, graph: gcr.Analysis) RunSummary {
    var stats = TextStats{};
    scanTrace(trace, &stats);

    var summary = RunSummary{
        .true_run = true_run,
        .hylo_required = true_run and hyloRequired(stats, graph),
        .alsr_present = stats.alsr_count > 0,
        .hyl_present = stats.hyl_count > 0,
        .hsr_step_count = stats.hsr_step_count,
        .mutations = graph.material_mutations,
        .terminal_folds = stats.terminal_fold_count,
    };

    const unfold_capacity = @max(stats.unfold_count, stats.hsr_step_count);
    summary.mutations_with_unfold = @min(summary.mutations, unfold_capacity);
    if (stats.directActionFused() or stats.controllerGoverned()) summary.mutations_with_unfold = summary.mutations;
    summary.actions_without_fold = stats.action_count -| stats.fold_count;
    summary.continues_without_next_state = stats.continue_count -| stats.next_state_count;
    summary.atcg_after_terminal_fold = if (stats.terminal_fold_count > 0) @min(stats.terminal_fold_count, stats.atcg_count) else 0;
    if (summary.mutations > summary.mutations_with_unfold) summary.graph_bypass = true;
    if (!stats.anyGovernance() and graph.material_mutations_without_current_executable_gcr > 0) summary.graph_bypass = true;

    if (summary.hylo_required) {
        applyFailures(&summary, stats);
        summary.quality_state = qualityState(summary, stats);
    }

    return summary;
}

pub fn failureClassesJson(allocator: std.mem.Allocator, counts: [failure_class_count]usize) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeByte('{');
    var emitted: usize = 0;
    for (failure_class_names, 0..) |name, idx| {
        if (counts[idx] == 0) continue;
        if (emitted > 0) try writer.writeByte(',');
        try output.writeJsonString(writer, name);
        try writer.writeByte(':');
        try writer.print("{d}", .{counts[idx]});
        emitted += 1;
    }
    try writer.writeByte('}');
    return writer_alloc.toOwnedSlice();
}

pub fn failureClassListJson(allocator: std.mem.Allocator, counts: [failure_class_count]usize) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeByte('[');
    var emitted: usize = 0;
    for (failure_class_names, 0..) |name, idx| {
        if (counts[idx] == 0) continue;
        if (emitted > 0) try writer.writeByte(',');
        try output.writeJsonString(writer, name);
        emitted += 1;
    }
    try writer.writeByte(']');
    return writer_alloc.toOwnedSlice();
}

fn hyloRequired(stats: TextStats, graph: gcr.Analysis) bool {
    return graph.material_mutations > 0 or
        graph.gcrs.len > 0 or
        graph.projection.update_plan_calls > 0 or
        stats.anyGovernance();
}

fn scanTrace(trace: canonical_trace.CanonicalSessionTrace, stats: *TextStats) void {
    for (trace.turns.items) |turn| {
        if (turn.final_answer) |text| scanActiveText(text, stats);
        if (turn.assistant_preview) |text| scanActiveText(text, stats);
    }
    for (trace.tools.items) |tool| {
        if (toolOutputLooksLikeSkillRead(tool)) continue;
        if (tool.output_text) |text| scanActiveText(text, stats);
    }
}

fn scanActiveText(text: []const u8, stats: *TextStats) void {
    if (passiveSpecDiscussion(text)) return;

    stats.alsr_count += countAny(text, &.{
        "receipt_version: ALSR-v1",
        "\"receipt_version\":\"ALSR-v1\"",
        "\"receipt_version\": \"ALSR-v1\"",
    });
    stats.hyl_count += countAny(text, &.{
        "machine_version: HYL-v1",
        "\"machine_version\":\"HYL-v1\"",
        "\"machine_version\": \"HYL-v1\"",
    });
    const hsr_markers = countAny(text, &.{
        "receipt_version: HSR-v1",
        "\"receipt_version\":\"HSR-v1\"",
        "\"receipt_version\": \"HSR-v1\"",
    });
    stats.hsr_step_count += hsr_markers;
    if (hsr_markers > 0) {
        stats.unfold_count += if (containsAny(text, &.{ "unfold:", "\"unfold\"" })) hsr_markers else 0;
        stats.action_count += if (containsAny(text, &.{ "action:", "\"action\"" })) hsr_markers else 0;
        stats.fold_count += if (containsAny(text, &.{ "\n  fold:", "\nfold:", "\"fold\"" })) hsr_markers else 0;
    }

    stats.continue_count += countAny(text, &.{ "verdict: continue", "\"verdict\":\"continue\"", "\"verdict\": \"continue\"" });
    stats.next_state_count += countAny(text, &.{ "next_state_ref:", "\"next_state_ref\"" });
    stats.terminal_fold_count += countAny(text, &.{
        "verdict: complete",
        "\"verdict\":\"complete\"",
        "\"verdict\": \"complete\"",
        "produced: terminal",
        "\"produced\":\"terminal\"",
        "\"produced\": \"terminal\"",
    });
    stats.stop_rule_count += countAny(text, &.{ "stop_rule", "\"stop_rule\"" });
    stats.atcg_count += countAny(text, &.{"ATCG-v1"});
    stats.resume_packet_count += countAny(text, &.{"hylo_resume_packet:"});
    stats.current_artifact_yes_count += countAny(text, &.{ "current_artifact_bound: yes", "\"current_artifact_bound\":\"yes\"", "\"current_artifact_bound\": \"yes\"" });
    stats.current_artifact_no_count += countAny(text, &.{ "current_artifact_bound: no", "\"current_artifact_bound\":\"no\"", "\"current_artifact_bound\": \"no\"" });
    stats.stale_count += countAny(text, &.{ "blocked-loop-contract-stale", "stale_hylo_after_diff_change", "unfold_not_current" });
    stats.contradictory_count += countAny(text, &.{ "contradictory", "current_artifact_bound: no" });
    stats.parallel_frontier_count += countAny(text, &.{ "parallel_frontier", "subagent_spawn", "spawn_agent" });
    stats.fanin_count += countAny(text, &.{ "fan-in", "fan_in", "subagent_result", "fold results" });
    stats.review_marker_count += countAny(text, &.{ "$cas review", "review finding", "requested changes" });
    stats.review_fold_count += countAny(text, &.{ "$review-fold", "review-fold", "review_fold" });
    stats.raw_review_patch_count += countAny(text, &.{ "raw_review_to_patch", "Finding -> Patch" });
    stats.direct_action_fused_count += countAny(text, &.{ "direct_action_fused: yes", "direct_action fused exemption" });
    stats.controller_governed_count += countAny(text, &.{ "controller_governed_handoff: yes", "controller owns the work", "controller-owned" });
    stats.cached_cas_counted_fresh_count += countAny(text, &.{ "cached_cas_counted_as_fresh", "cas_receipt_cache_hit: yes\ncounted_as_fresh: yes" });
    stats.ship_effect_count += countAny(text, &.{ "ship_handoff:", "$ship", "gh pr create", "gh pr edit", "gh pr ready", "gh pr merge" });
    stats.publication_boundary_count += countAny(text, &.{ "publication_boundary: yes", "ship_result:", "ADD-v1" });
}

fn toolOutputLooksLikeSkillRead(tool: canonical_trace.ToolLifecycleRecord) bool {
    return toolFieldContains(tool.command_text, "SKILL.md") or
        toolFieldContains(tool.command_text, "/codex/skills/") or
        toolFieldContains(tool.input_text, "SKILL.md") or
        toolFieldContains(tool.arguments_json, "SKILL.md");
}

fn passiveSpecDiscussion(text: []const u8) bool {
    return contains(text, "Detection markers") or
        contains(text, "Quality states") or
        contains(text, "Anti-contamination") or
        contains(text, "# 01 - `seq actuation-audit") or
        contains(text, "# 02 - Regression Fixtures for Hylo Audits") or
        contains(text, "expected_detection:") or
        contains(text, "schema:") and contains(text, "receipt_version: HSR-v1");
}

fn applyFailures(summary: *RunSummary, stats: TextStats) void {
    const governance_exempt = stats.directActionFused() or stats.controllerGoverned();
    if (!governance_exempt and !summary.alsr_present) addFailure(summary, .missing_alsr);
    if (!governance_exempt and !summary.hyl_present) addFailure(summary, .missing_hyl);
    if (!governance_exempt and (summary.hsr_step_count == 0 or stats.unfold_count == 0)) addFailure(summary, .missing_unfold);
    if (stats.stale_count > 0) addFailure(summary, .stale_hylo_after_diff_change);
    if (!governance_exempt and summary.mutations > stats.unfold_count) addFailure(summary, .mutation_without_unfold);
    if (summary.actions_without_fold > 0) addFailure(summary, .action_without_fold);
    if (stats.current_artifact_no_count > 0) addFailure(summary, .fold_without_current_artifact);
    if (stats.stale_count > 0 or containsFailure(summary.*, .stale_hylo_after_diff_change)) addFailure(summary, .unfold_not_current);
    if (summary.continues_without_next_state > 0) addFailure(summary, .continue_without_next_seed);
    if (summary.terminal_folds > 0 and stats.stop_rule_count == 0) addFailure(summary, .terminal_without_stop_rule);
    if (summary.terminal_folds > 0 and summary.atcg_after_terminal_fold == 0) addFailure(summary, .terminal_without_atcg);
    if (stats.parallel_frontier_count > 0 and stats.fanin_count == 0) addFailure(summary, .parallel_fanout_without_fanin);
    if (stats.review_marker_count > 0 and summary.mutations > 0 and stats.review_fold_count == 0) addFailure(summary, .resolve_without_review_fold);
    if (stats.raw_review_patch_count > 0) addFailure(summary, .raw_review_to_patch);
    if (stats.cached_cas_counted_fresh_count > 0) addFailure(summary, .cached_cas_counted_as_fresh);
}

fn qualityState(summary: RunSummary, stats: TextStats) []const u8 {
    if (stats.contradictory_count > 0) return quality_state_names[@intFromEnum(QualityState.contradictory)];
    if (stats.stale_count > 0) return quality_state_names[@intFromEnum(QualityState.stale)];
    if ((stats.directActionFused() or stats.controllerGoverned()) and summary.terminal_folds > 0 and summary.atcg_after_terminal_fold > 0) return quality_state_names[@intFromEnum(QualityState.present_and_closed)];
    if (!summary.alsr_present and !summary.hyl_present and summary.hsr_step_count == 0) return quality_state_names[@intFromEnum(QualityState.absent)];
    if (!summary.alsr_present or !summary.hyl_present or summary.hsr_step_count == 0) return quality_state_names[@intFromEnum(QualityState.partial)];
    if (summary.terminal_folds > 0 and summary.atcg_after_terminal_fold > 0 and !containsFailure(summary, .terminal_without_atcg)) return quality_state_names[@intFromEnum(QualityState.present_and_closed)];
    if (stats.current_artifact_yes_count > 0 and summary.actions_without_fold == 0 and summary.continues_without_next_state == 0 and summary.mutations == summary.mutations_with_unfold) return quality_state_names[@intFromEnum(QualityState.present_verified)];
    return quality_state_names[@intFromEnum(QualityState.present_unverified)];
}

fn addFailure(summary: *RunSummary, failure: FailureClass) void {
    summary.failure_counts[@intFromEnum(failure)] += 1;
}

fn containsFailure(summary: RunSummary, failure: FailureClass) bool {
    return summary.failure_counts[@intFromEnum(failure)] > 0;
}

fn countAny(text: []const u8, needles: []const []const u8) usize {
    var total: usize = 0;
    for (needles) |needle| total += countOccurrences(text, needle);
    return total;
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (contains(text, needle)) return true;
    }
    return false;
}

fn countOccurrences(text: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const idx = std.ascii.indexOfIgnoreCase(text[cursor..], needle) orelse break;
        total += 1;
        cursor += idx + needle.len;
    }
    return total;
}

fn contains(text: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, needle) != null;
}

fn toolFieldContains(value: ?[]const u8, needle: []const u8) bool {
    if (value) |text| return contains(text, needle);
    return false;
}

test "hylo analyzer distinguishes active receipts from pasted spec prose" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/hylo.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/hylo.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "t1"),
        .turn_index = 1,
        .user_message = try std.testing.allocator.dupe(u8, "Detection markers: receipt_version: ALSR-v1 machine_version: HYL-v1 receipt_version: HSR-v1"),
        .final_answer = try std.testing.allocator.dupe(u8,
            \\agent_loop_scheme_receipt:
            \\  receipt_version: ALSR-v1
            \\actuation_hylomorphism:
            \\  machine_version: HYL-v1
            \\hylo_step_receipt:
            \\  receipt_version: HSR-v1
            \\  unfold:
            \\    produced: work_node
            \\  action:
            \\    effect: edit
            \\  fold:
            \\    verdict: complete
            \\    current_artifact_bound: yes
            \\  stop_rule:
            \\    success: done
            \\ATCG-v1:
            \\  can_mark_goal_complete: yes
        ),
    });
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/hylo.jsonl"), .kind = .patch_apply });
    var graph = try gcr.analyzeTrace(std.testing.allocator, trace);
    defer graph.deinit(std.testing.allocator);
    const summary = analyzeTrace(trace, true, graph);
    try std.testing.expect(summary.hylo_required);
    try std.testing.expect(summary.alsr_present);
    try std.testing.expect(summary.hyl_present);
    try std.testing.expectEqual(@as(usize, 1), summary.hsr_step_count);
    try std.testing.expectEqualStrings("present_and_closed", summary.quality_state);
}
