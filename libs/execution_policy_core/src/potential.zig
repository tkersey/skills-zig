const std = @import("std");

pub const Relation = enum {
    improved,
    equal,
    worsened,
};

pub const Direction = enum {
    minimize,
    maximize,
};

pub const Dimension = struct {
    id: []const u8,
    direction: Direction,
    terminal_threshold: i64,
};

pub const PotentialComparison = struct {
    relation: Relation,
    first_difference: ?usize,
    terminal_threshold_met: bool = false,
};

pub fn comparePotential(before: []const i64, after: []const i64) PotentialComparison {
    const directions = [_]Direction{.minimize} ** 64;
    return comparePotentialDirected(directions[0..@min(directions.len, @max(before.len, after.len))], before, after, &.{});
}

pub fn comparePotentialDirected(directions: []const Direction, before: []const i64, after: []const i64, thresholds: []const i64) PotentialComparison {
    const len = @min(before.len, after.len);
    var index: usize = 0;
    while (index < len) : (index += 1) {
        if (before[index] == after[index]) continue;
        const direction = if (index < directions.len) directions[index] else .minimize;
        const improved = switch (direction) {
            .minimize => after[index] < before[index],
            .maximize => after[index] > before[index],
        };
        return .{
            .relation = if (improved) .improved else .worsened,
            .first_difference = index,
            .terminal_threshold_met = thresholdsMet(directions, after, thresholds),
        };
    }
    if (before.len == after.len) return .{
        .relation = .equal,
        .first_difference = null,
        .terminal_threshold_met = thresholdsMet(directions, after, thresholds),
    };
    return .{
        .relation = if (after.len < before.len) .improved else .worsened,
        .first_difference = len,
        .terminal_threshold_met = thresholdsMet(directions, after, thresholds),
    };
}

fn thresholdsMet(directions: []const Direction, values: []const i64, thresholds: []const i64) bool {
    if (thresholds.len == 0) return false;
    if (values.len < thresholds.len) return false;
    for (thresholds, 0..) |threshold, index| {
        const direction = if (index < directions.len) directions[index] else .minimize;
        switch (direction) {
            .minimize => if (values[index] > threshold) return false,
            .maximize => if (values[index] < threshold) return false,
        }
    }
    return true;
}

test "potential comparison detects first difference" {
    const comparison = comparePotential(&.{ 1, 3 }, &.{ 1, 4 });
    try std.testing.expectEqual(Relation.worsened, comparison.relation);
    try std.testing.expectEqual(@as(?usize, 1), comparison.first_difference);
}

test "directed potential comparison uses dimension order" {
    const comparison = comparePotentialDirected(&.{ .maximize, .minimize }, &.{ 1, 10 }, &.{ 2, 20 }, &.{ 2, 0 });
    try std.testing.expectEqual(Relation.improved, comparison.relation);
    try std.testing.expectEqual(@as(?usize, 0), comparison.first_difference);
    try std.testing.expect(!comparison.terminal_threshold_met);
}

test "potential terminal threshold status" {
    const comparison = comparePotentialDirected(&.{ .maximize, .minimize }, &.{ 1, 10 }, &.{ 2, 0 }, &.{ 2, 0 });
    try std.testing.expectEqual(Relation.improved, comparison.relation);
    try std.testing.expect(comparison.terminal_threshold_met);
}
