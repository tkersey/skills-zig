const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const render = @import("render.zig");

pub const Summary = struct {
    unknowns_json: []u8,
    critical_unknowns: i64,
    resolved_unknowns: i64,
    premature_mutations: i64,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.unknowns_json);
    }
};

pub fn analyze(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) !Summary {
    var first_visible: ?i64 = null;
    var first_resolver: ?i64 = null;
    var first_evidence: ?i64 = null;
    var mutation_before_resolution: i64 = 0;
    var resolved = false;
    var blocked = false;

    for (trace.turns.items) |turn| {
        const text = turn.user_message orelse turn.assistant_preview orelse turn.final_answer orelse "";
        if (text.len == 0) continue;
        scanUnknownText(text, turn.turn_index, &first_visible, &first_resolver, &first_evidence, &resolved, &blocked);
    }
    for (trace.tools.items) |tool| {
        const turn_index = tool.turn_index orelse 0;
        if (tool.command_text) |text| {
            scanUnknownText(text, turn_index, &first_visible, &first_resolver, &first_evidence, &resolved, &blocked);
            if ((contains(text, "apply_patch") or contains(text, "git commit")) and first_visible != null and first_evidence == null) mutation_before_resolution += 1;
            if (first_resolver == null and contains(text, "rg ")) first_resolver = turn_index;
        }
        if (tool.input_text) |text| scanUnknownText(text, turn_index, &first_visible, &first_resolver, &first_evidence, &resolved, &blocked);
        if (tool.output_text) |text| {
            scanUnknownText(text, turn_index, &first_visible, &first_resolver, &first_evidence, &resolved, &blocked);
        }
        if (tool.patch_success == true and first_visible != null and first_evidence == null) mutation_before_resolution += 1;
    }

    const state = if (resolved) "resolved" else if (blocked) "blocked" else if (first_visible != null) "open" else "absent";
    const finding = if (mutation_before_resolution > 0) &[_][]const u8{"premature_implementation_before_critical_unknown"} else &[_][]const u8{};
    const findings_json = try render.stringArrayJson(allocator, finding);
    defer allocator.free(findings_json);
    const unknowns_json = try std.fmt.allocPrint(
        allocator,
        "{{\"first_visible\":{d},\"first_selected_resolver_action\":{d},\"first_evidence_produced\":{d},\"state\":\"{s}\",\"actions_elapsed\":{d},\"implementation_actions_before_resolution\":{d},\"findings\":{s}}}",
        .{
            first_visible orelse 0,
            first_resolver orelse 0,
            first_evidence orelse 0,
            state,
            if (first_visible != null and first_evidence != null) first_evidence.? - first_visible.? else 0,
            mutation_before_resolution,
            findings_json,
        },
    );
    return .{
        .unknowns_json = unknowns_json,
        .critical_unknowns = if (first_visible != null) 1 else 0,
        .resolved_unknowns = if (resolved) 1 else 0,
        .premature_mutations = mutation_before_resolution,
    };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn scanUnknownText(
    text: []const u8,
    turn_index: i64,
    first_visible: *?i64,
    first_resolver: *?i64,
    first_evidence: *?i64,
    resolved: *bool,
    blocked: *bool,
) void {
    if (first_visible.* == null and contains(text, "critical unknown")) first_visible.* = turn_index;
    if (first_resolver.* == null and (contains(text, "resolver action") or contains(text, "probe"))) first_resolver.* = turn_index;
    if (first_evidence.* == null and (contains(text, "evidence produced") or contains(text, "resolved_unknowns") or contains(text, "unknown:") and contains(text, "resolved"))) first_evidence.* = turn_index;
    if (contains(text, "critical unknown") and contains(text, "blocked")) blocked.* = true;
    if (contains(text, "resolved_unknowns") or contains(text, "critical unknown resolved")) resolved.* = true;
}

test "unknowns flags premature mutation before evidence" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/policy.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .assistant_preview = try std.testing.allocator.dupe(u8, "critical unknown: API shape"),
    });
    try trace.tools.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy.jsonl"),
        .turn_index = 2,
        .command_text = try std.testing.allocator.dupe(u8, "apply_patch"),
    });
    var summary = try analyze(std.testing.allocator, trace);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), summary.premature_mutations);
}
