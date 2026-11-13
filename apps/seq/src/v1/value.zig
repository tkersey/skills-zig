const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    json: []const u8,
    null,
};

const Kind = enum(u2) { text, number, boolean, null };

fn kind(value: Value) Kind {
    return switch (value) {
        .string, .json => .text,
        .integer, .float => .number,
        .boolean => .boolean,
        .null => .null,
    };
}

fn text(value: Value) []const u8 {
    return switch (value) {
        .string, .json => |bytes| bytes,
        else => unreachable,
    };
}

fn isNan(value: Value) bool {
    return value == .float and std.math.isNan(value.float);
}

pub fn equal(left: Value, right: Value, ignore_case: bool) bool {
    if (left == .null or right == .null) return left == .null and right == .null;
    if (ignore_case and kind(left) == .text and kind(right) == .text) {
        return std.ascii.eqlIgnoreCase(text(left), text(right));
    }
    const ordered = compare(left, right) orelse return false;
    return ordered == .eq;
}

pub fn compare(left: Value, right: Value) ?std.math.Order {
    const left_kind = kind(left);
    if (left_kind != kind(right)) return null;
    return switch (left_kind) {
        .text => std.mem.order(u8, text(left), text(right)),
        .number => if (isNan(left) or isNan(right)) null else numberOrder(left, right),
        .boolean => std.math.order(
            @intFromBool(left.boolean),
            @intFromBool(right.boolean),
        ),
        .null => null,
    };
}

pub const Relation = enum { lt, le, gt, ge };

pub fn holds(left: Value, right: Value, relation: Relation) bool {
    const ordered = compare(left, right) orelse return false;
    return switch (relation) {
        .lt => ordered == .lt,
        .le => ordered != .gt,
        .gt => ordered == .gt,
        .ge => ordered != .lt,
    };
}

pub fn order(left: Value, right: Value) std.math.Order {
    const left_kind = kind(left);
    const right_kind = kind(right);
    if (left_kind != right_kind) {
        return std.math.order(@backingInt(left_kind), @backingInt(right_kind));
    }
    if (isNan(left) or isNan(right)) {
        return std.math.order(@intFromBool(isNan(left)), @intFromBool(isNan(right)));
    }
    return compare(left, right) orelse .eq;
}

pub fn sortOrder(
    left: Value,
    right: Value,
    descending: bool,
    nulls_first: bool,
) std.math.Order {
    if (left == .null or right == .null) {
        if (left == .null and right == .null) return .eq;
        return if ((left == .null) == nulls_first) .lt else .gt;
    }
    const ordered = order(left, right);
    return if (descending) ordered.invert() else ordered;
}

fn numberOrder(left: Value, right: Value) std.math.Order {
    return switch (left) {
        .integer => |left_number| switch (right) {
            .integer => |right_number| std.math.order(left_number, right_number),
            .float => |right_number| compareIntegerFloat(left_number, right_number),
            else => unreachable,
        },
        .float => |left_number| switch (right) {
            .integer => |right_number| compareIntegerFloat(right_number, left_number).invert(),
            .float => |right_number| compareFloat(left_number, right_number),
            else => unreachable,
        },
        else => unreachable,
    };
}

fn compareFloat(left: f64, right: f64) std.math.Order {
    std.debug.assert(!std.math.isNan(left) and !std.math.isNan(right));
    if (left < right) return .lt;
    if (left > right) return .gt;
    return .eq;
}

fn compareIntegerFloat(left: i64, right: f64) std.math.Order {
    std.debug.assert(!std.math.isNan(right));
    const integer_min: f64 = -9_223_372_036_854_775_808.0;
    const integer_limit: f64 = 9_223_372_036_854_775_808.0;
    if (right < integer_min) return .gt;
    if (right >= integer_limit) return .lt;
    const truncated: i64 = @intFromFloat(right);
    const integer_order = std.math.order(left, truncated);
    if (integer_order != .eq) return integer_order;
    if (right > 0 and right != @trunc(right)) return .lt;
    if (right < 0 and right != @trunc(right)) return .gt;
    return .eq;
}

test "numeric order is exact and transitive beyond float precision" {
    const low: Value = .{ .integer = 9_007_199_254_740_992 };
    const high: Value = .{ .integer = 9_007_199_254_740_993 };
    const float_low: Value = .{ .float = 9_007_199_254_740_992.0 };
    try std.testing.expectEqual(std.math.Order.lt, order(low, high));
    try std.testing.expectEqual(std.math.Order.eq, order(low, float_low));
    try std.testing.expectEqual(std.math.Order.lt, order(float_low, high));
    try std.testing.expectEqual(std.math.Order.gt, order(high, float_low));
    try std.testing.expect(equal(low, float_low, false));
    try std.testing.expect(!equal(high, float_low, false));
    try std.testing.expectEqual(
        std.math.Order.lt,
        order(.{ .integer = std.math.maxInt(i64) }, .{ .float = 9.3e18 }),
    );
    try std.testing.expectEqual(
        std.math.Order.gt,
        order(.{ .integer = std.math.minInt(i64) }, .{ .float = -9.3e18 }),
    );
    try std.testing.expect(equal(.{ .float = 0.0 }, .{ .float = -0.0 }, false));
}

test "NaN is incomparable to predicates and ordered last among numbers" {
    const nan: Value = .{ .float = std.math.nan(f64) };
    const one: Value = .{ .integer = 1 };
    const infinity: Value = .{ .float = std.math.inf(f64) };
    try std.testing.expectEqual(@as(?std.math.Order, null), compare(nan, one));
    try std.testing.expectEqual(@as(?std.math.Order, null), compare(one, nan));
    try std.testing.expect(!equal(nan, nan, false));
    try std.testing.expect(!equal(one, nan, false));
    try std.testing.expectEqual(std.math.Order.gt, order(nan, one));
    try std.testing.expectEqual(std.math.Order.gt, order(nan, infinity));
    try std.testing.expectEqual(std.math.Order.lt, order(one, nan));
    try std.testing.expectEqual(std.math.Order.eq, order(nan, nan));
    try std.testing.expectEqual(std.math.Order.lt, order(nan, .{ .boolean = false }));
    inline for (.{ Relation.lt, Relation.le, Relation.gt, Relation.ge }) |relation| {
        try std.testing.expect(!holds(nan, one, relation));
        try std.testing.expect(!holds(one, nan, relation));
        try std.testing.expect(!holds(.null, one, relation));
        try std.testing.expect(!holds(.{ .string = "1" }, one, relation));
    }
    try std.testing.expect(holds(one, .{ .float = 1.0 }, .le));
    try std.testing.expect(holds(one, .{ .float = 1.0 }, .ge));
    try std.testing.expect(!holds(one, .{ .float = 1.0 }, .lt));
}

test "kinds are incomparable to predicates and totally ordered for sorting" {
    const text_value: Value = .{ .string = "a" };
    const json_value: Value = .{ .json = "a" };
    const number: Value = .{ .integer = 1 };
    const flag: Value = .{ .boolean = false };
    try std.testing.expectEqual(@as(?std.math.Order, null), compare(text_value, number));
    try std.testing.expectEqual(@as(?std.math.Order, null), compare(number, flag));
    try std.testing.expectEqual(@as(?std.math.Order, null), compare(.null, .null));
    try std.testing.expect(equal(text_value, json_value, false));
    try std.testing.expect(equal(.{ .string = "A" }, json_value, true));
    try std.testing.expect(equal(.null, .null, false));
    try std.testing.expect(!equal(.null, number, false));
    try std.testing.expectEqual(std.math.Order.lt, order(text_value, number));
    try std.testing.expectEqual(std.math.Order.lt, order(number, flag));
    try std.testing.expectEqual(std.math.Order.gt, order(flag, text_value));
    try std.testing.expectEqual(std.math.Order.lt, order(flag, .{ .boolean = true }));
}

test "sort order places nulls by position regardless of direction" {
    const null_value: Value = .null;
    const number: Value = .{ .integer = 1 };
    const larger: Value = .{ .integer = 2 };
    try std.testing.expectEqual(std.math.Order.gt, sortOrder(null_value, number, false, false));
    try std.testing.expectEqual(std.math.Order.gt, sortOrder(null_value, number, true, false));
    try std.testing.expectEqual(std.math.Order.lt, sortOrder(null_value, number, true, true));
    try std.testing.expectEqual(std.math.Order.lt, sortOrder(null_value, number, false, true));
    try std.testing.expectEqual(std.math.Order.gt, sortOrder(number, larger, true, false));
    try std.testing.expectEqual(std.math.Order.lt, sortOrder(number, larger, false, false));
    try std.testing.expectEqual(std.math.Order.eq, sortOrder(null_value, null_value, true, true));
}
