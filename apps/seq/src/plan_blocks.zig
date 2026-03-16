const std = @import("std");

pub const SessionMeta = struct {
    cwd: ?[]u8 = null,

    pub fn deinit(self: SessionMeta, allocator: std.mem.Allocator) void {
        if (self.cwd) |value| allocator.free(value);
    }
};

pub const PlanBlock = struct {
    block: []u8,
    title: ?[]u8,
    iteration: ?[]u8,
    plan_index: usize,

    pub fn deinit(self: PlanBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.block);
        if (self.title) |value| allocator.free(value);
        if (self.iteration) |value| allocator.free(value);
    }
};

pub fn deinitPlanBlocks(allocator: std.mem.Allocator, rows: []PlanBlock) void {
    for (rows) |row| row.deinit(allocator);
    allocator.free(rows);
}

pub fn parseSessionMeta(allocator: std.mem.Allocator, jsonl: []const u8) !SessionMeta {
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, "\"type\":\"session_meta\"") == null and
            std.mem.indexOf(u8, trimmed, "\"type\": \"session_meta\"") == null) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();

        const payload = switch (parsed.value) {
            .object => |obj| obj.get("payload") orelse continue,
            else => continue,
        };
        const cwd = switch (payload) {
            .object => |obj| switch (obj.get("cwd") orelse continue) {
                .string => |value| value,
                else => continue,
            },
            else => continue,
        };
        return .{ .cwd = try allocator.dupe(u8, cwd) };
    }

    return .{};
}

pub fn extractPlanBlocks(allocator: std.mem.Allocator, text: []const u8) ![]PlanBlock {
    var rows: std.ArrayList(PlanBlock) = .empty;
    errdefer {
        for (rows.items) |row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    var next_index: usize = 1;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "<proposed_plan>")) |start| {
        const body_start = start + "<proposed_plan>".len;
        const end_start = std.mem.indexOfPos(u8, text, body_start, "</proposed_plan>") orelse {
            pos = body_start;
            continue;
        };
        const end = end_start + "</proposed_plan>".len;
        const inner = text[body_start..end_start];
        if (std.mem.trim(u8, inner, " \t\r\n").len == 0) {
            pos = end;
            continue;
        }

        try rows.append(allocator, .{
            .block = try allocator.dupe(u8, text[start..end]),
            .title = try firstHeadingLine(allocator, inner),
            .iteration = try firstIterationLine(allocator, inner),
            .plan_index = next_index,
        });
        next_index += 1;
        pos = end;
    }

    return rows.toOwnedSlice(allocator);
}

fn firstHeadingLine(allocator: std.mem.Allocator, inner: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, inner, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (trimmed[0] != '#') continue;
        return try allocator.dupe(u8, trimmed);
    }
    return null;
}

fn firstIterationLine(allocator: std.mem.Allocator, inner: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, inner, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (!std.mem.startsWith(u8, trimmed, "Iteration:")) continue;
        return try allocator.dupe(u8, trimmed);
    }
    return null;
}

test "extractPlanBlocks keeps only complete proposed_plan blocks" {
    const input =
        "prefix\n" ++
        "<proposed_plan>\nIteration: 4\n# First\nbody\n</proposed_plan>\n" ++
        "<proposed_plan>\nIteration: 5\n# Broken\n";
    const blocks = try extractPlanBlocks(std.testing.allocator, input);
    defer deinitPlanBlocks(std.testing.allocator, blocks);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("Iteration: 4", blocks[0].iteration.?);
    try std.testing.expectEqualStrings("# First", blocks[0].title.?);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].plan_index);
    try std.testing.expect(std.mem.indexOf(u8, blocks[0].block, "</proposed_plan>") != null);
}

test "extractPlanBlocks emits multiple blocks in order" {
    const input =
        "<proposed_plan>\nIteration: 1\n# A\n</proposed_plan>\n" ++
        "<proposed_plan>\nIteration: 2\n# B\n</proposed_plan>\n";
    const blocks = try extractPlanBlocks(std.testing.allocator, input);
    defer deinitPlanBlocks(std.testing.allocator, blocks);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].plan_index);
    try std.testing.expectEqual(@as(usize, 2), blocks[1].plan_index);
    try std.testing.expectEqualStrings("# B", blocks[1].title.?);
}

test "parseSessionMeta returns cwd from session_meta payload" {
    const jsonl =
        "{\"timestamp\":\"2026-03-10T14:19:28.680Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"019cd81d-bf7d-70c2-a0aa-0ac86535ff39\",\"cwd\":\"/Users/tk/workspace/tk/shift\"}}\n" ++
        "{\"timestamp\":\"2026-03-10T14:20:23.811Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}}\n";
    const meta = try parseSessionMeta(std.testing.allocator, jsonl);
    defer meta.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/Users/tk/workspace/tk/shift", meta.cwd.?);
}
