const std = @import("std");

pub const DuplicatePolicy = enum { first, reject };

pub fn selectTurn(
    turns: []const std.json.Value,
    expected: []const u8,
    comptime duplicates: DuplicatePolicy,
) error{DuplicateTurn}!?std.json.ObjectMap {
    var selected: ?std.json.ObjectMap = null;
    for (turns) |value| {
        if (value != .object) continue;
        const id = value.object.get("id") orelse continue;
        if (id != .string or !std.mem.eql(u8, id.string, expected)) continue;
        if (duplicates == .first) return value.object;
        if (selected != null) return error.DuplicateTurn;
        selected = value.object;
    }
    return selected;
}

pub fn clearNotifications(
    allocator: std.mem.Allocator,
    notifications: *std.ArrayList([]u8),
) void {
    for (notifications.items) |line| allocator.free(line);
    notifications.clearRetainingCapacity();
}

test "selected turn preserves first-match and unique-match policies" {
    const raw = "[null,{}, {\"id\":1},{\"id\":\"other\"}," ++
        "{\"id\":\"selected\",\"status\":\"first\"}," ++
        "{\"id\":\"selected\",\"status\":\"second\"}]";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const turns = parsed.value.array.items;
    try std.testing.expect(try selectTurn(turns, "missing", .first) == null);
    try std.testing.expect(try selectTurn(turns, "missing", .reject) == null);
    const first = (try selectTurn(turns, "selected", .first)).?;
    try std.testing.expectEqualStrings("first", first.get("status").?.string);
    const unique = (try selectTurn(turns[0..5], "selected", .reject)).?;
    try std.testing.expectEqualStrings("first", unique.get("status").?.string);
    try std.testing.expectError(error.DuplicateTurn, selectTurn(turns, "selected", .reject));
}

test "notification clearing retains capacity and owns every captured line" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkNotificationOwnership,
        .{},
    );
}

fn checkNotificationOwnership(allocator: std.mem.Allocator) !void {
    var notifications: std.ArrayList([]u8) = .empty;
    defer {
        clearNotifications(allocator, &notifications);
        notifications.deinit(allocator);
    }
    for (0..3) |_| {
        for (0..8) |_| {
            const line = try allocator.dupe(u8, "captured notification");
            notifications.append(allocator, line) catch |err| {
                allocator.free(line);
                return err;
            };
        }
        const capacity = notifications.capacity;
        clearNotifications(allocator, &notifications);
        try std.testing.expectEqual(@as(usize, 0), notifications.items.len);
        try std.testing.expectEqual(capacity, notifications.capacity);
    }
}
