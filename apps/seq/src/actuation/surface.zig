const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;

pub const Churn = struct {
    apply_patch_calls: usize = 0,
    gross_insertions: usize = 0,
    gross_deletions: usize = 0,
};

pub const ShipMode = enum { ready, draft, update_existing, promote_draft, blocked, none };

pub const ShipSummary = struct {
    requested: bool = false,
    mode: ShipMode = .none,
    ship_without_current_full_proof: bool = false,
    land_or_merge_inside_actuating: bool = false,
};

pub fn churnFromTrace(trace: canonical_trace.CanonicalSessionTrace) Churn {
    var churn = Churn{};
    for (trace.tools.items) |tool| {
        if (tool.patch_success == false) continue;
        if (tool.kind == .patch_apply or tool.patch_changes_json != null or toolContains(tool, "apply_patch")) churn.apply_patch_calls += 1;
        if (tool.patch_changes_json) |json| {
            churn.gross_insertions += countNumberAfter(json, "\"added\":");
            churn.gross_deletions += countNumberAfter(json, "\"removed\":");
        }
    }
    return churn;
}

pub fn shipFromTrace(trace: canonical_trace.CanonicalSessionTrace, has_current_full_proof: bool) ShipSummary {
    var summary = ShipSummary{};
    for (trace.tools.items) |tool| {
        if (toolContains(tool, "gh pr create") or toolContains(tool, "$ship")) {
            summary.requested = true;
            summary.mode = if (toolContains(tool, "--draft")) .draft else .ready;
        }
        if (toolContains(tool, "gh pr edit") or toolContains(tool, "gh pr update")) {
            summary.requested = true;
            summary.mode = .update_existing;
        }
        if (toolContains(tool, "gh pr ready")) {
            summary.requested = true;
            summary.mode = .promote_draft;
        }
        if (toolContains(tool, "gh pr merge")) summary.land_or_merge_inside_actuating = true;
    }
    summary.ship_without_current_full_proof = summary.requested and !has_current_full_proof;
    return summary;
}

fn countNumberAfter(text: []const u8, needle: []const u8) usize {
    const idx = std.mem.indexOf(u8, text, needle) orelse return 0;
    var pos = idx + needle.len;
    while (pos < text.len and text[pos] == ' ') : (pos += 1) {}
    const start = pos;
    while (pos < text.len and std.ascii.isDigit(text[pos])) : (pos += 1) {}
    if (pos == start) return 0;
    return std.fmt.parseUnsigned(usize, text[start..pos], 10) catch 0;
}

fn toolContains(tool: canonical_trace.ToolLifecycleRecord, needle: []const u8) bool {
    if (tool.command_text) |text| if (contains(text, needle)) return true;
    if (tool.input_text) |text| if (contains(text, needle)) return true;
    if (tool.tool_name) |text| if (contains(text, needle)) return true;
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "surface analyzer separates churn from ship state" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/run.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/run.jsonl"), .kind = .patch_apply, .patch_changes_json = try std.testing.allocator.dupe(u8, "{\"added\":3,\"removed\":1}") });
    try trace.tools.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "/tmp/run.jsonl"), .kind = .exec_command, .command_text = try std.testing.allocator.dupe(u8, "gh pr create --draft") });
    const churn = churnFromTrace(trace);
    try std.testing.expectEqual(@as(usize, 1), churn.apply_patch_calls);
    try std.testing.expectEqual(@as(usize, 3), churn.gross_insertions);
    const ship = shipFromTrace(trace, false);
    try std.testing.expect(ship.requested);
    try std.testing.expectEqual(ShipMode.draft, ship.mode);
    try std.testing.expect(ship.ship_without_current_full_proof);
}
