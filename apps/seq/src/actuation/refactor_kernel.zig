const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const gcr = @import("gcr.zig");

pub const Result = struct {
    formal_decision_present: bool = false,
    outcome_present: bool = false,
    explicit_phrase_present: bool = false,
    selected_route_present: bool = false,
    next_resolution_mode_present: bool = false,
    accepted_liability_markers: usize = 0,
    owner_boundary_markers: usize = 0,
    review_fold_markers: usize = 0,
    cas_bottleneck_markers: usize = 0,
    patch_calls: usize = 0,
    update_plan_calls: usize = 0,
    mutations_without_graph_control: usize = 0,
    graph_bypass: bool = false,
    potential_hidden_kernel: bool = false,
    classification: []const u8 = "none",
    confidence: []const u8 = "none",
    reasons: [][]u8 = &.{},

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.reasons) |reason| allocator.free(reason);
        allocator.free(self.reasons);
    }
};

const TextStats = struct {
    explicit_phrase: usize = 0,
    aer: usize = 0,
    rko: usize = 0,
    selected_route: usize = 0,
    next_resolution_mode: usize = 0,
    accepted_liabilities: usize = 0,
    owner_boundary: usize = 0,
    review_fold: usize = 0,
    cas_bottleneck: usize = 0,
};

pub fn analyzeTrace(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, true_run: bool) !Result {
    var graph = try gcr.analyzeTrace(allocator, trace);
    defer graph.deinit(allocator);

    var stats = TextStats{};
    scanTrace(trace, &stats);

    var reasons: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, reasons.items);

    const formal = stats.aer > 0 and (stats.selected_route > 0 or stats.next_resolution_mode > 0);
    const outcome = stats.rko > 0;
    const graph_bypass = graph.material_mutations_without_current_executable_gcr > 0;
    const review_pressure = stats.accepted_liabilities > 0 or stats.review_fold > 0 or stats.cas_bottleneck > 0;
    const broad_patch_burst = graph.material_mutations >= 20 or (graph.material_mutations >= 5 and graph.projection.update_plan_calls >= 2);
    const explicit_hidden = stats.explicit_phrase > 0 and graph_bypass and !formal;
    const inferred_hidden = graph_bypass and !formal and broad_patch_burst and review_pressure;

    if (graph_bypass) try addReason(allocator, &reasons, "graph_bypass");
    if (graph.material_mutations_without_current_executable_gcr > 0) try addReason(allocator, &reasons, "mutations_without_graph_control");
    if (broad_patch_burst) try addReason(allocator, &reasons, "broad_patch_burst");
    if (review_pressure) try addReason(allocator, &reasons, "review_pressure_or_liability_markers");
    if (stats.explicit_phrase > 0) try addReason(allocator, &reasons, "explicit_refactor_kernel_phrase");
    if (formal) try addReason(allocator, &reasons, "aer_refactor_kernel_decision_present");
    if (outcome) try addReason(allocator, &reasons, "rko_outcome_present");
    if (stats.cas_bottleneck > 0) try addReason(allocator, &reasons, "cas_or_github_terminal_drag");

    const classification: []const u8 = if (formal and outcome and !graph_bypass)
        "governed_refactor_kernel"
    else if (formal and !outcome)
        "refactor_kernel_decision_missing_outcome"
    else if (explicit_hidden)
        "potential_hidden_refactor_kernel_explicit"
    else if (inferred_hidden)
        "potential_hidden_refactor_kernel_inferred"
    else if (graph_bypass and broad_patch_burst)
        "large_graph_bypass_unclassified"
    else if (graph_bypass)
        "ordinary_graph_bypass"
    else
        "none";

    const confidence: []const u8 = if (std.mem.eql(u8, classification, "governed_refactor_kernel"))
        "formal"
    else if (explicit_hidden)
        "high"
    else if (inferred_hidden)
        "medium"
    else if (graph_bypass)
        "low"
    else
        "none";

    return .{
        .formal_decision_present = formal,
        .outcome_present = outcome,
        .explicit_phrase_present = stats.explicit_phrase > 0,
        .selected_route_present = stats.selected_route > 0,
        .next_resolution_mode_present = stats.next_resolution_mode > 0,
        .accepted_liability_markers = stats.accepted_liabilities,
        .owner_boundary_markers = stats.owner_boundary,
        .review_fold_markers = stats.review_fold,
        .cas_bottleneck_markers = stats.cas_bottleneck,
        .patch_calls = graph.material_mutations,
        .update_plan_calls = graph.projection.update_plan_calls,
        .mutations_without_graph_control = graph.material_mutations_without_current_executable_gcr,
        .graph_bypass = graph_bypass,
        .potential_hidden_kernel = true_run and (explicit_hidden or inferred_hidden),
        .classification = classification,
        .confidence = confidence,
        .reasons = try reasons.toOwnedSlice(allocator),
    };
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
    stats.explicit_phrase += countAny(text, &.{
        "refactor-kernel",
        "refactor_kernel",
        "next refactor kernel patch",
    });
    stats.aer += countAny(text, &.{
        "actuation_escalation_receipt",
        "AER-v1",
    });
    stats.rko += countAny(text, &.{
        "refactor_kernel_outcome",
        "RKO-v1",
    });
    stats.selected_route += countAny(text, &.{
        "selected_route: refactor-kernel",
        "\"selected_route\":\"refactor-kernel\"",
        "\"selected_route\": \"refactor-kernel\"",
    });
    stats.next_resolution_mode += countAny(text, &.{
        "next_resolution_mode: refactor-kernel",
        "\"next_resolution_mode\":\"refactor-kernel\"",
        "\"next_resolution_mode\": \"refactor-kernel\"",
    });
    stats.accepted_liabilities += countAny(text, &.{
        "accepted_liabilities",
        "accepted liabilities",
        "accepted-liability",
    });
    stats.owner_boundary += countAny(text, &.{
        "owner_boundary",
        "owner boundary",
        "owner-boundary",
    });
    stats.review_fold += countAny(text, &.{
        "review_fold_ref",
        "review-fold",
        "$review-fold",
    });
    stats.cas_bottleneck += countAny(text, &.{
        "CAS can produce",
        "blocked-cas-resource-exhausted",
        "CAS resource",
        "GitHub review",
        "review threads still unresolved",
    });
}

fn passiveSpecDiscussion(text: []const u8) bool {
    return contains(text, "What To Change Next") or
        contains(text, "Candidate score:") or
        contains(text, "Refactor Kernel Effectiveness Audit") or
        contains(text, "schema:") and contains(text, "refactor_kernel_outcome");
}

fn toolOutputLooksLikeSkillRead(tool: canonical_trace.ToolLifecycleRecord) bool {
    return toolFieldContains(tool.command_text, "SKILL.md") or
        toolFieldContains(tool.command_text, "/codex/skills/") or
        toolFieldContains(tool.input_text, "SKILL.md") or
        toolFieldContains(tool.arguments_json, "SKILL.md");
}

fn toolFieldContains(value: ?[]const u8, needle: []const u8) bool {
    if (value) |text| return contains(text, needle);
    return false;
}

fn addReason(allocator: std.mem.Allocator, reasons: *std.ArrayList([]u8), reason: []const u8) !void {
    for (reasons.items) |existing| {
        if (std.mem.eql(u8, existing, reason)) return;
    }
    try reasons.append(allocator, try allocator.dupe(u8, reason));
}

fn countAny(text: []const u8, needles: []const []const u8) usize {
    var total: usize = 0;
    for (needles) |needle| total += countOccurrences(text, needle);
    return total;
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

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn fixtureTrace(allocator: std.mem.Allocator, assistant_text: []const u8) !canonical_trace.CanonicalSessionTrace {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(allocator, "/tmp/rk.jsonl") };
    errdefer trace.deinit(allocator);
    trace.session.session_id = try allocator.dupe(u8, "rk-session-1");
    try trace.turns.append(allocator, .{
        .path = try allocator.dupe(u8, "/tmp/rk.jsonl"),
        .turn_id = try allocator.dupe(u8, "t1"),
        .turn_index = 1,
        .user_message = try allocator.dupe(u8, "/goal $actuating review-closeout"),
        .final_answer = try allocator.dupe(u8, assistant_text),
    });
    return trace;
}

test "refactor-kernel signal classifier finds explicit graph-bypass side channel" {
    var trace = try fixtureTrace(std.testing.allocator,
        \\I am applying the next refactor-kernel patch now.
        \\The accepted liabilities share one owner_boundary and review-fold class.
        \\CAS can produce a usable review receipt later.
    );
    defer trace.deinit(std.testing.allocator);
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/rk.jsonl"), .kind = .patch_apply });
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/rk.jsonl"), .kind = .patch_apply });
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/rk.jsonl"), .kind = .patch_apply });
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/rk.jsonl"), .kind = .patch_apply });
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/rk.jsonl"), .kind = .patch_apply });

    var result = try analyzeTrace(std.testing.allocator, trace, true);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.graph_bypass);
    try std.testing.expect(result.potential_hidden_kernel);
    try std.testing.expectEqualStrings("potential_hidden_refactor_kernel_explicit", result.classification);
    try std.testing.expectEqualStrings("high", result.confidence);
}

test "refactor-kernel signal classifier recognizes governed AER plus RKO" {
    var trace = try fixtureTrace(std.testing.allocator,
        \\actuation_escalation_receipt:
        \\  version: AER-v1
        \\  selected_route: refactor-kernel
        \\  next_resolution_mode: refactor-kernel
        \\  owner_boundary: codex/skills/review-fold
        \\  accepted_liabilities: []
        \\refactor_kernel_outcome:
        \\  version: RKO-v1
        \\  governance:
        \\    graph_bypass: no
    );
    defer trace.deinit(std.testing.allocator);

    var result = try analyzeTrace(std.testing.allocator, trace, true);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.formal_decision_present);
    try std.testing.expect(result.outcome_present);
    try std.testing.expect(!result.potential_hidden_kernel);
    try std.testing.expectEqualStrings("governed_refactor_kernel", result.classification);
}
