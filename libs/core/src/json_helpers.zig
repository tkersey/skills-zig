const std = @import("std");

pub const ObjectMap = std.json.ObjectMap;

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn objectField(obj: ObjectMap, key: []const u8) ?ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |inner| inner,
        else => null,
    };
}

pub fn stringField(obj: ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

pub fn intFromValue(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |n| n,
        .float => |f| blk: {
            if (!std.math.isFinite(f) or f < -0x1p63 or f >= 0x1p63) break :blk null;
            const rounded = std.math.round(f);
            if (rounded != f) break :blk null;
            break :blk @intFromFloat(rounded);
        },
        else => null,
    };
}

pub fn intField(obj: ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return intFromValue(value);
}

pub fn stringifyValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return stringifyAlloc(allocator, value);
}

test "integer conversion requires finite integral values inside i64" {
    try std.testing.expectEqual(@as(?i64, 42), intFromValue(.{ .float = 42.0 }));
    try std.testing.expectEqual(@as(?i64, -42), intFromValue(.{ .float = -42.0 }));
    try std.testing.expectEqual(@as(?i64, null), intFromValue(.{ .float = 42.5 }));
    const invalid = [_]f64{ 0x1p63, -0x1p64, std.math.inf(f64), std.math.nan(f64) };
    for (invalid) |value| {
        try std.testing.expectEqual(@as(?i64, null), intFromValue(.{ .float = value }));
    }
    try std.testing.expectEqual(
        @as(?i64, std.math.minInt(i64)),
        intFromValue(.{ .float = -0x1p63 }),
    );
}

test "JSON serialization preserves output and allocator errors" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkStringifyAllocation,
        .{},
    );
}

fn checkStringifyAllocation(allocator: std.mem.Allocator) !void {
    const output = try stringifyAlloc(allocator, .{ .string = "quoted" });
    defer allocator.free(output);
    try std.testing.expectEqualStrings("\"quoted\"", output);
}
