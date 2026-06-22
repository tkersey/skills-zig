const std = @import("std");
const canonical_trace = @import("canonical_trace.zig");

pub const Anchor = struct {
    available: bool,
    keep_through_turn_index: ?i64 = null,
    drop_last_n_turns: ?i64 = null,
    anchor_digest: ?[]u8 = null,
    limitation: ?[]const u8 = null,

    pub fn deinit(self: *Anchor, allocator: std.mem.Allocator) void {
        if (self.anchor_digest) |value| allocator.free(value);
    }
};

pub const Anchors = struct {
    pre_decision: Anchor,
    post_decision_pre_outcome: Anchor,
    outcome_aware: Anchor,

    pub fn deinit(self: *Anchors, allocator: std.mem.Allocator) void {
        self.pre_decision.deinit(allocator);
        self.post_decision_pre_outcome.deinit(allocator);
        self.outcome_aware.deinit(allocator);
    }
};

pub fn compute(
    allocator: std.mem.Allocator,
    trace: canonical_trace.CanonicalSessionTrace,
    decision_turn_index: i64,
    first_outcome_turn_index: ?i64,
    outcome_boundary_ambiguous: bool,
) !Anchors {
    const total: i64 = @intCast(trace.turns.items.len);
    const pre = if (decision_turn_index <= 1)
        Anchor{ .available = false, .limitation = "empty_prefix_unavailable" }
    else
        try availableAnchor(allocator, trace, decision_turn_index - 1);

    const post = if (outcome_boundary_ambiguous)
        Anchor{ .available = false, .limitation = "outcome_boundary_ambiguous" }
    else blk: {
        const keep = if (first_outcome_turn_index) |idx| idx - 1 else decision_turn_index;
        break :blk try availableAnchor(allocator, trace, keep);
    };

    return .{
        .pre_decision = pre,
        .post_decision_pre_outcome = post,
        .outcome_aware = try availableAnchor(allocator, trace, total),
    };
}

pub fn availableAnchor(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, keep_through_turn_index: i64) !Anchor {
    const total: i64 = @intCast(trace.turns.items.len);
    return .{
        .available = true,
        .keep_through_turn_index = keep_through_turn_index,
        .drop_last_n_turns = total - keep_through_turn_index,
        .anchor_digest = try digestRetained(allocator, trace, keep_through_turn_index),
    };
}

pub fn sourceTurnDigest(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) ![]u8 {
    return digestRetained(allocator, trace, @intCast(trace.turns.items.len));
}

pub fn digestRetained(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, keep_through_turn_index: i64) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;

    try writer.print("turns:{d}\n", .{keep_through_turn_index});
    for (trace.turns.items) |turn| {
        if (turn.turn_index > keep_through_turn_index) continue;
        try writer.print("{d}|{s}|{s}|", .{ turn.turn_index, turn.turn_id, @tagName(turn.status) });
        if (turn.user_message) |value| try writeContentDigest(writer, value);
        try writer.writeByte('|');
        if (turn.final_answer) |value| try writeContentDigest(writer, value);
        try writer.writeByte('\n');
        for (trace.tools.items) |tool| {
            if (tool.turn_index == null or tool.turn_index.? != turn.turn_index) continue;
            try writer.print("tool|", .{});
            if (tool.call_id) |value| try writer.writeAll(value);
            try writer.writeByte('|');
            if (tool.tool_name) |value| try writer.writeAll(value);
            try writer.writeByte('|');
            try writer.writeAll(@tagName(tool.lifecycle_status));
            try writer.writeByte('|');
            if (tool.arguments_json) |value| try writeContentDigest(writer, value);
            try writer.writeByte('|');
            if (tool.input_text) |value| try writeContentDigest(writer, value);
            try writer.writeByte('|');
            if (tool.output_text) |value| try writeContentDigest(writer, value);
            try writer.writeByte('|');
            if (tool.command_text) |value| try writeContentDigest(writer, value);
            try writer.writeByte('|');
            if (tool.cwd) |value| try writeContentDigest(writer, value);
            try writer.writeByte('|');
            if (tool.patch_changes_json) |value| try writeContentDigest(writer, value);
            try writer.writeByte('|');
            if (tool.web_query) |value| try writeContentDigest(writer, value);
            try writer.writeByte('|');
            if (tool.web_url) |value| try writeContentDigest(writer, value);
            try writer.writeByte('|');
            if (tool.image_prompt) |value| try writeContentDigest(writer, value);
            try writer.writeByte('|');
            if (tool.exit_code) |value| try writer.print("{d}", .{value});
            try writer.writeByte('\n');
        }
    }
    const canonical = try writer_alloc.toOwnedSlice();
    defer allocator.free(canonical);
    return sha256Prefixed(allocator, canonical);
}

fn writeContentDigest(writer: anytype, text: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try writer.writeAll(hex[0..]);
}

fn sha256Prefixed(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

test "anchor arithmetic is one based" {
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "rollout.jsonl"),
    };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "rollout.jsonl"), .turn_id = try std.testing.allocator.dupe(u8, "t1"), .turn_index = 1, .status = .complete });
    try trace.turns.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "rollout.jsonl"), .turn_id = try std.testing.allocator.dupe(u8, "t2"), .turn_index = 2, .status = .complete });
    try trace.turns.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "rollout.jsonl"), .turn_id = try std.testing.allocator.dupe(u8, "t3"), .turn_index = 3, .status = .complete });

    var anchors = try compute(std.testing.allocator, trace, 2, 3, false);
    defer anchors.deinit(std.testing.allocator);
    try std.testing.expect(anchors.pre_decision.available);
    try std.testing.expectEqual(@as(i64, 1), anchors.pre_decision.keep_through_turn_index.?);
    try std.testing.expectEqual(@as(i64, 2), anchors.pre_decision.drop_last_n_turns.?);
    try std.testing.expectEqual(@as(i64, 2), anchors.post_decision_pre_outcome.keep_through_turn_index.?);
    try std.testing.expectEqual(@as(i64, 3), anchors.outcome_aware.keep_through_turn_index.?);
}

test "anchor digest changes when tool payload changes" {
    var trace_a = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "rollout.jsonl"),
    };
    defer trace_a.deinit(std.testing.allocator);
    try trace_a.turns.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "rollout.jsonl"), .turn_id = try std.testing.allocator.dupe(u8, "t1"), .turn_index = 1, .status = .complete });
    try trace_a.tools.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout.jsonl"),
        .turn_index = 1,
        .call_id = try std.testing.allocator.dupe(u8, "tool-1"),
        .tool_name = try std.testing.allocator.dupe(u8, "exec_command"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"cmd\":\"zig build test\"}"),
        .lifecycle_status = .completed,
    });

    var trace_b = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "rollout.jsonl"),
    };
    defer trace_b.deinit(std.testing.allocator);
    try trace_b.turns.append(std.testing.allocator, .{ .path = try std.testing.allocator.dupe(u8, "rollout.jsonl"), .turn_id = try std.testing.allocator.dupe(u8, "t1"), .turn_index = 1, .status = .complete });
    try trace_b.tools.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "rollout.jsonl"),
        .turn_index = 1,
        .call_id = try std.testing.allocator.dupe(u8, "tool-1"),
        .tool_name = try std.testing.allocator.dupe(u8, "exec_command"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"cmd\":\"zig build lint\"}"),
        .lifecycle_status = .completed,
    });

    const digest_a = try digestRetained(std.testing.allocator, trace_a, 1);
    defer std.testing.allocator.free(digest_a);
    const digest_b = try digestRetained(std.testing.allocator, trace_b, 1);
    defer std.testing.allocator.free(digest_b);
    try std.testing.expect(!std.mem.eql(u8, digest_a, digest_b));
}
