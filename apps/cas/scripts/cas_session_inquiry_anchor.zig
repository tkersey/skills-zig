const std = @import("std");

pub const BoundaryKind = enum {
    before_turn_id,
    last_turn_id,
};

pub const Boundary = struct {
    kind: BoundaryKind,
    turn_id: []const u8,
};

pub const AnchorIdentity = struct {
    count: u64,
    digest: []const u8,
};

pub fn selectBoundary(
    turn_ids: []const []const u8,
    completed_boundaries: []const bool,
    keep_count_raw: u64,
) error{ SourceStale, DecisionAnchorUnavailable }!Boundary {
    if (turn_ids.len != completed_boundaries.len) return error.SourceStale;
    const keep_count = std.math.cast(usize, keep_count_raw) orelse
        return error.SourceStale;
    if (keep_count > turn_ids.len) return error.SourceStale;
    if (keep_count == 0) {
        if (turn_ids.len == 0) return error.SourceStale;
        return .{ .kind = .before_turn_id, .turn_id = turn_ids[0] };
    }
    if (!completed_boundaries[keep_count - 1]) {
        return error.DecisionAnchorUnavailable;
    }
    return .{
        .kind = .last_turn_id,
        .turn_id = turn_ids[keep_count - 1],
    };
}

pub fn exactAnchorMatches(expected: AnchorIdentity, observed: AnchorIdentity) bool {
    return expected.digest.len > 0 and
        observed.digest.len > 0 and
        expected.count == observed.count and
        std.mem.eql(u8, expected.digest, observed.digest);
}

test "anchor boundary selects exact exclusive and inclusive turn ids" {
    const turn_ids = [_][]const u8{ "turn-1", "turn-2", "turn-active" };
    const completed = [_]bool{ true, true, false };

    const before = try selectBoundary(&turn_ids, &completed, 0);
    try std.testing.expectEqual(BoundaryKind.before_turn_id, before.kind);
    try std.testing.expectEqualStrings("turn-1", before.turn_id);

    const through = try selectBoundary(&turn_ids, &completed, 2);
    try std.testing.expectEqual(BoundaryKind.last_turn_id, through.kind);
    try std.testing.expectEqualStrings("turn-2", through.turn_id);
}

test "anchor boundary rejects stale and incomplete histories" {
    const turn_ids = [_][]const u8{ "turn-1", "turn-active" };
    const completed = [_]bool{ true, false };

    try std.testing.expectError(
        error.DecisionAnchorUnavailable,
        selectBoundary(&turn_ids, &completed, 2),
    );
    try std.testing.expectError(
        error.SourceStale,
        selectBoundary(&turn_ids, &completed, 3),
    );
    try std.testing.expectError(
        error.SourceStale,
        selectBoundary(&turn_ids, completed[0..1], 1),
    );
    try std.testing.expectError(
        error.SourceStale,
        selectBoundary(&.{}, &.{}, 0),
    );
}

test "opaque anchor identity requires exact count and digest" {
    const expected = AnchorIdentity{ .count = 2, .digest = "sha256:anchor" };
    try std.testing.expect(exactAnchorMatches(expected, expected));
    try std.testing.expect(!exactAnchorMatches(expected, .{
        .count = 1,
        .digest = expected.digest,
    }));
    try std.testing.expect(!exactAnchorMatches(expected, .{
        .count = expected.count,
        .digest = "sha256:other",
    }));
    try std.testing.expect(!exactAnchorMatches(
        .{ .count = 0, .digest = "" },
        .{ .count = 0, .digest = "" },
    ));
}
