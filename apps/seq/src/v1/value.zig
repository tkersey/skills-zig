const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    json: []const u8,
    null,
};

pub fn compareFloat(left: f64, right: f64) std.math.Order {
    if (left < right) return .lt;
    if (left > right) return .gt;
    return .eq;
}

pub fn compareIntegerFloat(left: i64, right: f64) std.math.Order {
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
