const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const render = @import("render.zig");

pub const Summary = struct {
    shield_findings_json: []u8,
    strict_findings_json: []u8,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.shield_findings_json);
        allocator.free(self.strict_findings_json);
    }
};

pub fn analyze(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) !Summary {
    var shielded_candidate = false;
    var intervention = false;
    var missing_required_atom = false;
    var mutation_despite_shield = false;
    var absent_rule = false;
    var response = false;

    for (trace.turns.items) |turn| {
        if (turn.user_message) |text| scanText(text, &shielded_candidate, &intervention, &missing_required_atom, &mutation_despite_shield, &absent_rule, &response);
        if (turn.assistant_preview) |text| scanText(text, &shielded_candidate, &intervention, &missing_required_atom, &mutation_despite_shield, &absent_rule, &response);
        if (turn.final_answer) |text| scanText(text, &shielded_candidate, &intervention, &missing_required_atom, &mutation_despite_shield, &absent_rule, &response);
    }
    for (trace.tools.items) |tool| {
        if (tool.command_text) |text| scanText(text, &shielded_candidate, &intervention, &missing_required_atom, &mutation_despite_shield, &absent_rule, &response);
        if (tool.input_text) |text| scanText(text, &shielded_candidate, &intervention, &missing_required_atom, &mutation_despite_shield, &absent_rule, &response);
        if (tool.output_text) |text| scanText(text, &shielded_candidate, &intervention, &missing_required_atom, &mutation_despite_shield, &absent_rule, &response);
    }

    const findings = try collectFindings(allocator, shielded_candidate, intervention, missing_required_atom, mutation_despite_shield, absent_rule, response);
    defer allocator.free(findings);
    const strict = if (mutation_despite_shield) &[_][]const u8{"mutation_despite_shield"} else &[_][]const u8{};

    return .{
        .shield_findings_json = try render.stringArrayJson(allocator, findings),
        .strict_findings_json = try render.stringArrayJson(allocator, strict),
    };
}

fn scanText(
    text: []const u8,
    shielded_candidate: *bool,
    intervention: *bool,
    missing_required_atom: *bool,
    mutation_despite_shield: *bool,
    absent_rule: *bool,
    response: *bool,
) void {
    if (contains(text, "shielded candidate")) shielded_candidate.* = true;
    if (contains(text, "shield intervention") or contains(text, "shield block")) intervention.* = true;
    if (contains(text, "missing required atom")) missing_required_atom.* = true;
    if (contains(text, "mutation despite shield")) mutation_despite_shield.* = true;
    if (contains(text, "shield rule absent") or contains(text, "absent shield rule")) absent_rule.* = true;
    if (contains(text, "return_to_spec") or contains(text, "rollback") or contains(text, "blocked by shield")) response.* = true;
}

fn collectFindings(
    allocator: std.mem.Allocator,
    shielded_candidate: bool,
    intervention: bool,
    missing_required_atom: bool,
    mutation_despite_shield: bool,
    absent_rule: bool,
    response: bool,
) ![]const []const u8 {
    var findings: std.ArrayList([]const u8) = .empty;
    defer findings.deinit(allocator);
    if (shielded_candidate) try findings.append(allocator, "shielded_candidate");
    if (intervention) try findings.append(allocator, "shield_intervention");
    if (missing_required_atom) try findings.append(allocator, "selected_action_missing_required_atom");
    if (mutation_despite_shield) try findings.append(allocator, "mutation_despite_shield");
    if (absent_rule) try findings.append(allocator, "shield_rule_absent_for_risky_action");
    if (response) try findings.append(allocator, "return_block_rollback_response");
    return try findings.toOwnedSlice(allocator);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "shielded candidate alone is not strict" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/policy.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .assistant_preview = try std.testing.allocator.dupe(u8, "shielded candidate considered"),
    });
    var summary = try analyze(std.testing.allocator, trace);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, summary.shield_findings_json, "shielded_candidate") != null);
    try std.testing.expectEqualStrings("[]", summary.strict_findings_json);
}
