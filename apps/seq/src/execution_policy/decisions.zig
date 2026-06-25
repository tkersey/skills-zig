const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const output = @import("../output/mod.zig");

pub const Summary = struct {
    decision_ids_json: []u8,
    decision_count: i64,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.decision_ids_json);
    }
};

pub fn analyze(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) !Summary {
    var policy_id: []const u8 = "policy";
    var revision: []const u8 = "0";
    var state_id: []const u8 = "state";
    var ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }

    for (trace.turns.items) |turn| {
        if (turn.user_message) |text| try scanText(allocator, text, &policy_id, &revision, &state_id, &ids);
        if (turn.assistant_preview) |text| try scanText(allocator, text, &policy_id, &revision, &state_id, &ids);
        if (turn.final_answer) |text| try scanText(allocator, text, &policy_id, &revision, &state_id, &ids);
    }

    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeByte('[');
    for (ids.items, 0..) |id, idx| {
        if (idx != 0) try writer.writeByte(',');
        try output.writeJsonString(writer, id);
    }
    try writer.writeByte(']');
    return .{
        .decision_ids_json = try writer_alloc.toOwnedSlice(),
        .decision_count = @intCast(ids.items.len),
    };
}

fn scanText(
    allocator: std.mem.Allocator,
    text: []const u8,
    policy_id: *[]const u8,
    revision: *[]const u8,
    state_id: *[]const u8,
    ids: *std.ArrayList([]const u8),
) !void {
    if (std.mem.indexOf(u8, text, "\"policy_id\"")) |idx| policy_id.* = try fieldStringFrom(text[idx..], "policy_id") orelse policy_id.*;
    if (std.mem.indexOf(u8, text, "\"revision\"")) |idx| revision.* = numberStringFrom(text[idx..], "revision") orelse revision.*;
    if (std.mem.indexOf(u8, text, "\"state_id\"")) |idx| state_id.* = try fieldStringFrom(text[idx..], "state_id") orelse state_id.*;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, text, cursor, "\"decision_id\"")) |idx| {
        cursor = idx + "\"decision_id\"".len;
        const decision_id = try fieldStringFrom(text[idx..], "decision_id") orelse continue;
        const stable = try std.fmt.allocPrint(allocator, "{s}+{s}+{s}+{s}", .{ policy_id.*, revision.*, state_id.*, decision_id });
        try ids.append(allocator, stable);
    }
}

fn fieldStringFrom(allocator_text: []const u8, field: []const u8) !?[]const u8 {
    _ = field;
    const colon = std.mem.indexOfScalar(u8, allocator_text, ':') orelse return null;
    const after = std.mem.trim(u8, allocator_text[colon + 1 ..], " \t\r\n");
    if (after.len == 0 or after[0] != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, after, 1, '"') orelse return null;
    return after[1..end];
}

fn numberStringFrom(text: []const u8, field: []const u8) ?[]const u8 {
    _ = field;
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const after = std.mem.trim(u8, text[colon + 1 ..], " \t\r\n");
    var end: usize = 0;
    while (end < after.len and std.ascii.isDigit(after[end])) : (end += 1) {}
    if (end == 0) return null;
    return after[0..end];
}

test "decisions build stable retrace id from visible artifacts" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/policy.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .assistant_preview = try std.testing.allocator.dupe(u8, "{\"policy_id\":\"p\",\"revision\":2,\"state_id\":\"s\",\"decision_id\":\"d\"}"),
    });
    var summary = try analyze(std.testing.allocator, trace);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, summary.decision_ids_json, "p+2+s+d") != null);
}
