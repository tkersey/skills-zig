const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const render = @import("render.zig");

pub const Summary = struct {
    horizon_violations_json: []u8,
    strict_findings_json: []u8,
    gcr_materializations: i64,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.horizon_violations_json);
        allocator.free(self.strict_findings_json);
    }
};

pub fn analyze(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, true_run: bool) !Summary {
    var saw_gcr = false;
    var mutation_actions: i64 = 0;
    var materializations: i64 = 0;
    var dormant = false;
    var too_many_mutations = false;
    var mismatch = false;
    var mutually_exclusive = false;
    var conditional_future = false;

    for (trace.turns.items) |turn| {
        if (turn.user_message) |text| scanGovernanceText(text, &saw_gcr, &materializations, &dormant, &too_many_mutations, &mismatch, &mutually_exclusive, &conditional_future);
        if (turn.assistant_preview) |text| scanGovernanceText(text, &saw_gcr, &materializations, &dormant, &too_many_mutations, &mismatch, &mutually_exclusive, &conditional_future);
        if (turn.final_answer) |text| scanGovernanceText(text, &saw_gcr, &materializations, &dormant, &too_many_mutations, &mismatch, &mutually_exclusive, &conditional_future);
    }
    for (trace.tools.items) |tool| {
        if (tool.command_text) |text| {
            scanGovernanceText(text, &saw_gcr, &materializations, &dormant, &too_many_mutations, &mismatch, &mutually_exclusive, &conditional_future);
            if (contains(text, "apply_patch") or contains(text, "git commit")) mutation_actions += 1;
        }
        if (tool.input_text) |text| scanGovernanceText(text, &saw_gcr, &materializations, &dormant, &too_many_mutations, &mismatch, &mutually_exclusive, &conditional_future);
        if (tool.output_text) |text| scanGovernanceText(text, &saw_gcr, &materializations, &dormant, &too_many_mutations, &mismatch, &mutually_exclusive, &conditional_future);
        if (tool.patch_success == true) mutation_actions += 1;
    }

    const horizon = try collectHorizonFindings(allocator, dormant, too_many_mutations, mismatch, mutually_exclusive, conditional_future);
    defer allocator.free(horizon);
    const strict = try collectStrictFindings(allocator, true_run, saw_gcr, mutation_actions, horizon);
    defer allocator.free(strict);

    return .{
        .horizon_violations_json = try render.stringArrayJson(allocator, horizon),
        .strict_findings_json = try render.stringArrayJson(allocator, strict),
        .gcr_materializations = materializations,
    };
}

fn scanGovernanceText(
    text: []const u8,
    saw_gcr: *bool,
    materializations: *i64,
    dormant: *bool,
    too_many_mutations: *bool,
    mismatch: *bool,
    mutually_exclusive: *bool,
    conditional_future: *bool,
) void {
    if (contains(text, "graph_control_receipt") or contains(text, "GCR-v1")) saw_gcr.* = true;
    if (contains(text, "selected_task_ids") or contains(text, "st compile aperture")) materializations.* += 1;
    if (contains(text, "dormant") and contains(text, "materialized")) dormant.* = true;
    if (contains(text, "more mutating actions") or contains(text, "too many active mutating")) too_many_mutations.* = true;
    if (contains(text, "materialized action differs") or contains(text, "EPD/GCR mismatch") or contains(text, "materialization mismatch")) mismatch.* = true;
    if (contains(text, "mutually exclusive")) mutually_exclusive.* = true;
    if (contains(text, "conditional future work")) conditional_future.* = true;
}

fn collectHorizonFindings(
    allocator: std.mem.Allocator,
    dormant: bool,
    too_many_mutations: bool,
    mismatch: bool,
    mutually_exclusive: bool,
    conditional_future: bool,
) ![]const []const u8 {
    var findings: std.ArrayList([]const u8) = .empty;
    defer findings.deinit(allocator);
    if (dormant) try findings.append(allocator, "dormant_policy_action_materialized");
    if (too_many_mutations) try findings.append(allocator, "mutating_action_limit_exceeded");
    if (mismatch) try findings.append(allocator, "materialization_gcr_action_mismatch");
    if (mutually_exclusive) try findings.append(allocator, "mutually_exclusive_branch_materialization");
    if (conditional_future) try findings.append(allocator, "native_plan_conditional_future_work");
    return try findings.toOwnedSlice(allocator);
}

fn collectStrictFindings(allocator: std.mem.Allocator, true_run: bool, saw_gcr: bool, mutation_actions: i64, horizon: []const []const u8) ![]const []const u8 {
    var findings: std.ArrayList([]const u8) = .empty;
    defer findings.deinit(allocator);
    if (true_run and mutation_actions > 0 and !saw_gcr) try findings.append(allocator, "mutation_without_epg_eps_epd_lineage");
    for (horizon) |finding| {
        if (std.mem.eql(u8, finding, "materialization_gcr_action_mismatch")) try findings.append(allocator, "materialization_gcr_action_mismatch");
        if (std.mem.eql(u8, finding, "dormant_policy_action_materialized") or
            std.mem.eql(u8, finding, "mutating_action_limit_exceeded") or
            std.mem.eql(u8, finding, "mutually_exclusive_branch_materialization") or
            std.mem.eql(u8, finding, "native_plan_conditional_future_work"))
        {
            try findings.append(allocator, "commitment_horizon_violation");
        }
    }
    return try findings.toOwnedSlice(allocator);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "horizon classifies mismatch as strict finding" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/policy.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .assistant_preview = try std.testing.allocator.dupe(u8, "materialized action differs from EPD"),
    });
    var summary = try analyze(std.testing.allocator, trace, true);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, summary.strict_findings_json, "materialization_gcr_action_mismatch") != null);
}
