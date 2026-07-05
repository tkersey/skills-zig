const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const render = @import("render.zig");

pub const Summary = struct {
    source_current: []u8,
    regime: []u8,
    runtime_states_json: []u8,
    active_or_stale: []u8,
    materializations: i64,
    gcr_coverage: []u8,
    lineage_violations_json: []u8,
    outcome_levels_json: []u8,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.source_current);
        allocator.free(self.regime);
        allocator.free(self.runtime_states_json);
        allocator.free(self.active_or_stale);
        allocator.free(self.gcr_coverage);
        allocator.free(self.lineage_violations_json);
        allocator.free(self.outcome_levels_json);
    }
};

const Counters = struct {
    gcr: i64 = 0,
    materializations: i64 = 0,
    mutations: i64 = 0,
    terminal_mentions: i64 = 0,
    proof_mentions: i64 = 0,
    delivery_mentions: i64 = 0,
    source_stale_mentions: i64 = 0,
};

pub fn analyze(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, true_run: bool) !Summary {
    var counters = Counters{};
    scanTrace(trace, &counters);

    const source_current = if (counters.source_stale_mentions > 0) "stale" else "not_audited";
    const active_or_stale = if (trace.session.is_ongoing) "active" else "stale_or_completed";
    const gcr_coverage = if (counters.gcr > 0) "present" else if (true_run) "missing" else "not_applicable";

    const runtime_states = if (true_run)
        &[_][]const u8{"policy_runtime_observed"}
    else
        &[_][]const u8{"no_policy_runtime_terminal"};
    const lineage_violations = if (true_run and counters.mutations > 0 and counters.gcr == 0)
        &[_][]const u8{"mutation_without_epg_eps_epd_lineage"}
    else if (counters.source_stale_mentions > 0)
        &[_][]const u8{"source_stale_policy_execution"}
    else
        &[_][]const u8{};
    const outcome_levels = try outcomeLevels(allocator, counters, true_run);
    defer allocator.free(outcome_levels);

    return .{
        .source_current = try allocator.dupe(u8, source_current),
        .regime = try allocator.dupe(u8, if (true_run) "policy_runtime" else "unclassified"),
        .runtime_states_json = try render.stringArrayJson(allocator, runtime_states),
        .active_or_stale = try allocator.dupe(u8, active_or_stale),
        .materializations = counters.materializations,
        .gcr_coverage = try allocator.dupe(u8, gcr_coverage),
        .lineage_violations_json = try render.stringArrayJson(allocator, lineage_violations),
        .outcome_levels_json = try render.stringArrayJson(allocator, outcome_levels),
    };
}

fn outcomeLevels(allocator: std.mem.Allocator, counters: Counters, true_run: bool) ![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(allocator);
    if (true_run) try items.append(allocator, "selection_valid");
    if (counters.gcr > 0) try items.append(allocator, "materialization_valid");
    if (counters.mutations > 0) try items.append(allocator, "action_result_valid");
    if (true_run and counters.materializations > 0) try items.append(allocator, "transition_valid");
    if (counters.terminal_mentions > 0 and counters.proof_mentions > 0) try items.append(allocator, "policy_terminal_success");
    if (counters.delivery_mentions > 0) try items.append(allocator, "delivery_success");
    return try items.toOwnedSlice(allocator);
}

fn scanTrace(trace: canonical_trace.CanonicalSessionTrace, counters: *Counters) void {
    for (trace.turns.items) |turn| {
        if (turn.user_message) |text| scanText(text, counters);
        if (turn.assistant_preview) |text| scanText(text, counters);
        if (turn.final_answer) |text| scanText(text, counters);
    }
    for (trace.tools.items) |tool| {
        if (tool.command_text) |text| scanText(text, counters);
        if (tool.input_text) |text| scanText(text, counters);
        if (tool.output_text) |text| scanText(text, counters);
        if (tool.command_text) |text| {
            if (contains(text, "apply_patch") or contains(text, "git commit")) counters.mutations += 1;
        }
        if (tool.patch_success == true) counters.mutations += 1;
    }
}

fn scanText(text: []const u8, counters: *Counters) void {
    if (contains(text, "graph_control_receipt") or contains(text, "GCR-v1")) counters.gcr += 1;
    if (contains(text, "selected_task_ids") or contains(text, "materialization")) counters.materializations += 1;
    if (contains(text, "terminal") or contains(text, "policy_terminal_success")) counters.terminal_mentions += 1;
    if (contains(text, "proof") or contains(text, "tests passed") or contains(text, "Build Summary")) counters.proof_mentions += 1;
    if (contains(text, "https://github.com/") or contains(text, "pr_url") or contains(text, "delivery_success")) counters.delivery_mentions += 1;
    if (contains(text, "source-stale") or contains(text, "source_stale") or contains(text, "stale policy")) counters.source_stale_mentions += 1;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "lineage separates terminal proof from delivery success" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/policy.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .final_answer = try std.testing.allocator.dupe(u8, "policy terminal success with proof, PR https://github.com/tkersey/skills-zig/pull/1"),
    });
    var summary = try analyze(std.testing.allocator, trace, true);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, summary.outcome_levels_json, "policy_terminal_success") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.outcome_levels_json, "delivery_success") != null);
}
