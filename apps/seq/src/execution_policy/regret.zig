const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const render = @import("render.zig");

pub const Summary = struct {
    regret_candidates_json: []u8,
    candidate_count: i64,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.regret_candidates_json);
    }
};

pub fn analyze(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) !Summary {
    var classes: std.ArrayList([]const u8) = .empty;
    defer classes.deinit(allocator);
    for (trace.turns.items) |turn| {
        if (turn.user_message) |text| try scanText(allocator, &classes, text);
        if (turn.assistant_preview) |text| try scanText(allocator, &classes, text);
        if (turn.final_answer) |text| try scanText(allocator, &classes, text);
    }
    for (trace.tools.items) |tool| {
        if (tool.command_text) |text| try scanText(allocator, &classes, text);
        if (tool.input_text) |text| try scanText(allocator, &classes, text);
        if (tool.output_text) |text| try scanText(allocator, &classes, text);
    }
    if (classes.items.len == 0) try classes.append(allocator, "insufficient_evidence");
    return .{
        .regret_candidates_json = try render.stringArrayJson(allocator, classes.items),
        .candidate_count = @intCast(classes.items.len),
    };
}

fn scanText(allocator: std.mem.Allocator, classes: *std.ArrayList([]const u8), text: []const u8) !void {
    if (contains(text, "lower cost") or contains(text, "lower_cost_equal_outcome_candidate")) try addUnique(allocator, classes, "lower_cost_equal_outcome_candidate");
    if (contains(text, "higher information") or contains(text, "higher_information_candidate")) try addUnique(allocator, classes, "higher_information_candidate");
    if (contains(text, "lower risk") or contains(text, "lower_risk_candidate")) try addUnique(allocator, classes, "lower_risk_candidate");
    if (contains(text, "selected action model failed") or contains(text, "selected_action_model_failed")) try addUnique(allocator, classes, "selected_action_model_failed");
    if (contains(text, "no regret signal") or contains(text, "no_regret_signal")) try addUnique(allocator, classes, "no_regret_signal");
}

fn addUnique(allocator: std.mem.Allocator, classes: *std.ArrayList([]const u8), value: []const u8) !void {
    for (classes.items) |item| if (std.mem.eql(u8, item, value)) return;
    try classes.append(allocator, value);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "regret candidate remains observational class" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/policy.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .assistant_preview = try std.testing.allocator.dupe(u8, "higher_information_candidate only, no causal certainty"),
    });
    var summary = try analyze(std.testing.allocator, trace);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, summary.regret_candidates_json, "higher_information_candidate") != null);
}
