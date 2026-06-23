const std = @import("std");
const artifacts = @import("afr.zig");

pub const RealizationRow = struct {
    handoff_valid: bool,
    result_valid: bool,
    identity_match: bool,
    route_match: bool,
    return_to_frontier: bool,
    errors: [][]u8,

    pub fn deinit(self: *RealizationRow, allocator: std.mem.Allocator) void {
        for (self.errors) |value| allocator.free(value);
        allocator.free(self.errors);
    }
};

pub fn analyzeHandoffResult(allocator: std.mem.Allocator, handoff_text: []const u8, result_text: []const u8) !RealizationRow {
    var handoff = try artifacts.parseArtifact(allocator, handoff_text);
    defer handoff.deinit(allocator);
    var result = try artifacts.parseArtifact(allocator, result_text);
    defer result.deinit(allocator);
    var errors: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, errors.items);
    const identity_match = optEql(handoff.run_id, result.run_id) and optEql(handoff.slice_id, result.slice_id) and optEql(handoff.gcr_id, result.gcr_id) and optEql(handoff.afr_id, result.afr_id);
    const route_match = optEql(handoff.selected_route, result.selected_route);
    if (!identity_match) try addError(allocator, &errors, "identity_mismatch");
    if (!route_match) try addError(allocator, &errors, "route_mismatch");
    return .{
        .handoff_valid = handoff.valid,
        .result_valid = result.valid,
        .identity_match = identity_match,
        .route_match = route_match,
        .return_to_frontier = contains(result_text, "\"result\":\"return_to_frontier\"") or contains(result_text, "\"result\": \"return_to_frontier\""),
        .errors = try errors.toOwnedSlice(allocator),
    };
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn addError(allocator: std.mem.Allocator, errors: *std.ArrayList([]u8), code: []const u8) !void {
    try errors.append(allocator, try allocator.dupe(u8, code));
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "realization checks identity route and return to frontier" {
    const handoff =
        \\{"actuation_realization_handoff":{"run_id":"run","slice_id":"slice","gcr_id":"gcr","afr_id":"afr","selected_route":"bounded_new_surface"}}
    ;
    const result =
        \\{"fixed_point_slice_result":{"run_id":"run","slice_id":"slice","gcr_id":"gcr","afr_id":"afr","selected_route":"bounded_new_surface","result":"return_to_frontier"}}
    ;
    var row = try analyzeHandoffResult(std.testing.allocator, handoff, result);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(row.identity_match);
    try std.testing.expect(row.route_match);
    try std.testing.expect(row.return_to_frontier);
}

test "realization reports mismatched route" {
    var row = try analyzeHandoffResult(
        std.testing.allocator,
        "{\"actuation_realization_handoff\":{\"run_id\":\"run\",\"selected_route\":\"a\"}}",
        "{\"fixed_point_slice_result\":{\"run_id\":\"run\",\"selected_route\":\"b\"}}",
    );
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(!row.route_match);
}
