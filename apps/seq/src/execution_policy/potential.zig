const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const render = @import("render.zig");

pub const Summary = struct {
    potential_gate: []u8,
    potential_findings_json: []u8,
    proof_required: i64,
    proof_passed: i64,
    proof_stale: i64,
    proof_missing: i64,
    strict_findings_json: []u8,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.potential_gate);
        allocator.free(self.potential_findings_json);
        allocator.free(self.strict_findings_json);
    }
};

pub fn analyze(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, true_run: bool) !Summary {
    var saw_potential = false;
    var improved = false;
    var worsened = false;
    var terminal = false;
    var proof = false;
    var stale = false;
    var missing = false;
    var no_expected_improvement = false;
    var metric_gaming = false;

    for (trace.turns.items) |turn| {
        if (turn.user_message) |text| scanText(text, &saw_potential, &improved, &worsened, &terminal, &proof, &stale, &missing, &no_expected_improvement, &metric_gaming);
        if (turn.assistant_preview) |text| scanText(text, &saw_potential, &improved, &worsened, &terminal, &proof, &stale, &missing, &no_expected_improvement, &metric_gaming);
        if (turn.final_answer) |text| scanText(text, &saw_potential, &improved, &worsened, &terminal, &proof, &stale, &missing, &no_expected_improvement, &metric_gaming);
    }
    for (trace.tools.items) |tool| {
        if (tool.command_text) |text| scanText(text, &saw_potential, &improved, &worsened, &terminal, &proof, &stale, &missing, &no_expected_improvement, &metric_gaming);
        if (tool.input_text) |text| scanText(text, &saw_potential, &improved, &worsened, &terminal, &proof, &stale, &missing, &no_expected_improvement, &metric_gaming);
        if (tool.output_text) |text| scanText(text, &saw_potential, &improved, &worsened, &terminal, &proof, &stale, &missing, &no_expected_improvement, &metric_gaming);
    }

    const findings = try collectFindings(allocator, worsened, no_expected_improvement, metric_gaming);
    defer allocator.free(findings);
    const strict = try collectStrict(allocator, true_run, terminal, proof, stale, missing, worsened);
    defer allocator.free(strict);

    return .{
        .potential_gate = try allocator.dupe(u8, potentialGate(saw_potential, improved, worsened)),
        .potential_findings_json = try render.stringArrayJson(allocator, findings),
        .proof_required = if (terminal or true_run) 1 else 0,
        .proof_passed = if (proof) 1 else 0,
        .proof_stale = if (stale) 1 else 0,
        .proof_missing = if ((terminal or true_run) and (!proof or missing)) 1 else 0,
        .strict_findings_json = try render.stringArrayJson(allocator, strict),
    };
}

fn potentialGate(saw_potential: bool, improved: bool, worsened: bool) []const u8 {
    if (worsened) return "worsened";
    if (improved) return "strict_improvement_observed";
    if (saw_potential) return "observed_unclassified";
    return "not_observed";
}

fn scanText(
    text: []const u8,
    saw_potential: *bool,
    improved: *bool,
    worsened: *bool,
    terminal: *bool,
    proof: *bool,
    stale: *bool,
    missing: *bool,
    no_expected_improvement: *bool,
    metric_gaming: *bool,
) void {
    if (contains(text, "potential")) saw_potential.* = true;
    if (contains(text, "strict lexicographic improvement") or contains(text, "potential improved")) improved.* = true;
    if (contains(text, "worsened dimension") or contains(text, "potential worsened")) worsened.* = true;
    if (contains(text, "terminal") or contains(text, "success_terminal")) terminal.* = true;
    if (contains(text, "proof passed") or contains(text, "tests passed") or contains(text, "Build Summary")) proof.* = true;
    if (contains(text, "proof stale") or contains(text, "stale proof")) stale.* = true;
    if (contains(text, "proof missing") or contains(text, "missing proof")) missing.* = true;
    if (contains(text, "no expected improvement")) no_expected_improvement.* = true;
    if (contains(text, "metric gaming")) metric_gaming.* = true;
}

fn collectFindings(allocator: std.mem.Allocator, worsened: bool, no_expected_improvement: bool, metric_gaming: bool) ![]const []const u8 {
    var findings: std.ArrayList([]const u8) = .empty;
    defer findings.deinit(allocator);
    if (worsened) try findings.append(allocator, "earliest_worsened_dimension");
    if (no_expected_improvement) try findings.append(allocator, "ordinary_action_without_expected_improvement");
    if (metric_gaming) try findings.append(allocator, "metric_gaming_candidate");
    return try findings.toOwnedSlice(allocator);
}

fn collectStrict(allocator: std.mem.Allocator, true_run: bool, terminal: bool, proof: bool, stale: bool, missing: bool, worsened: bool) ![]const []const u8 {
    var findings: std.ArrayList([]const u8) = .empty;
    defer findings.deinit(allocator);
    if (terminal and (!proof or missing)) try findings.append(allocator, "success_terminal_without_proof");
    if (true_run and stale) try findings.append(allocator, "source_stale_policy_execution");
    if (true_run and worsened) try findings.append(allocator, "invalid_etr_state_transition");
    return try findings.toOwnedSlice(allocator);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "terminal without proof is strict" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/policy.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .assistant_preview = try std.testing.allocator.dupe(u8, "success_terminal reached; proof missing"),
    });
    var summary = try analyze(std.testing.allocator, trace, true);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, summary.strict_findings_json, "success_terminal_without_proof") != null);
}
