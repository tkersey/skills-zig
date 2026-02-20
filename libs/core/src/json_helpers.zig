const std = @import("std");

pub const ObjectMap = std.json.ObjectMap;

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
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
            if (!std.math.isFinite(f)) break :blk null;
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
