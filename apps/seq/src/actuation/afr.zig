const std = @import("std");

pub const ArtifactKind = enum { afr, arh, fpsr, asr, sdr, unknown };

pub const ArtifactRow = struct {
    kind: ArtifactKind,
    valid: bool,
    run_id: ?[]u8 = null,
    slice_id: ?[]u8 = null,
    gcr_id: ?[]u8 = null,
    afr_id: ?[]u8 = null,
    selected_route: ?[]u8 = null,
    errors: [][]u8 = &.{},

    pub fn deinit(self: *ArtifactRow, allocator: std.mem.Allocator) void {
        freeOpt(allocator, self.run_id);
        freeOpt(allocator, self.slice_id);
        freeOpt(allocator, self.gcr_id);
        freeOpt(allocator, self.afr_id);
        freeOpt(allocator, self.selected_route);
        freeStringList(allocator, self.errors);
    }
};

pub fn parseArtifact(allocator: std.mem.Allocator, text: []const u8) !ArtifactRow {
    var owned_embedded: ?[]u8 = null;
    defer if (owned_embedded) |json| allocator.free(json);
    const json_text = blk: {
        if (std.json.parseFromSlice(std.json.Value, allocator, text, .{})) |parsed_probe| {
            var probe = parsed_probe;
            probe.deinit();
            break :blk text;
        } else |_| {
            owned_embedded = try extractEmbeddedArtifactJson(allocator, text);
            break :blk owned_embedded orelse return invalidRow(allocator, .unknown, "json_parse_error");
        }
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
        return invalidRow(allocator, .unknown, "json_parse_error");
    };
    defer parsed.deinit();
    const root = object(parsed.value) orelse return invalidRow(allocator, .unknown, "root_not_object");
    if (root.get("actuation_frontier")) |value| return parseAfr(allocator, value);
    if (root.get("actuation_realization_handoff")) |value| return parseWrapped(allocator, .arh, value);
    if (root.get("fixed_point_slice_result")) |value| return parseWrapped(allocator, .fpsr, value);
    if (root.get("actuation_summary")) |value| return parseWrapped(allocator, .asr, value);
    if (root.get("skill_decision_receipt")) |value| return parseWrapped(allocator, .sdr, value);
    return invalidRow(allocator, .unknown, "unsupported_wrapper");
}

fn extractEmbeddedArtifactJson(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    const key_idx = firstWrapperIndex(text) orelse return null;
    var start = key_idx;
    while (start > 0) {
        start -= 1;
        if (text[start] == '{') break;
    } else return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var idx = start;
    while (idx < text.len) : (idx += 1) {
        const c = text[idx];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return try allocator.dupe(u8, text[start .. idx + 1]);
        }
    }
    return null;
}

fn firstWrapperIndex(text: []const u8) ?usize {
    var best: ?usize = null;
    for ([_][]const u8{
        "\"actuation_frontier\"",
        "\"actuation_realization_handoff\"",
        "\"fixed_point_slice_result\"",
        "\"actuation_summary\"",
        "\"skill_decision_receipt\"",
    }) |needle| {
        if (std.mem.indexOf(u8, text, needle)) |idx| {
            if (best == null or idx < best.?) best = idx;
        }
    }
    return best;
}

fn parseAfr(allocator: std.mem.Allocator, value: std.json.Value) !ArtifactRow {
    const obj = object(value) orelse return invalidRow(allocator, .afr, "wrapper_not_object");
    var errors: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, errors.items);
    const graph = if (obj.get("graph_binding")) |v| object(v) else null;
    const decision = if (obj.get("decision")) |v| object(v) else null;
    const run_id = try requiredString(allocator, &errors, obj, "run_id");
    errdefer freeOpt(allocator, run_id);
    const slice_id = try requiredString(allocator, &errors, obj, "slice_id");
    errdefer freeOpt(allocator, slice_id);
    const afr_id = try requiredString(allocator, &errors, obj, "afr_id");
    errdefer freeOpt(allocator, afr_id);
    const gcr_id = if (graph) |g| try requiredString(allocator, &errors, g, "gcr_id") else blk: {
        try addError(allocator, &errors, "graph_binding");
        break :blk null;
    };
    errdefer freeOpt(allocator, gcr_id);
    const selected_route = if (decision) |d| try requiredString(allocator, &errors, d, "selected_route") else blk: {
        try addError(allocator, &errors, "decision");
        break :blk null;
    };
    errdefer freeOpt(allocator, selected_route);
    return .{
        .kind = .afr,
        .valid = errors.items.len == 0,
        .run_id = run_id,
        .slice_id = slice_id,
        .gcr_id = gcr_id,
        .afr_id = afr_id,
        .selected_route = selected_route,
        .errors = try errors.toOwnedSlice(allocator),
    };
}

fn parseWrapped(allocator: std.mem.Allocator, kind: ArtifactKind, value: std.json.Value) !ArtifactRow {
    const obj = object(value) orelse return invalidRow(allocator, kind, "wrapper_not_object");
    var errors: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, errors.items);
    const run_id = try requiredString(allocator, &errors, obj, "run_id");
    errdefer freeOpt(allocator, run_id);
    const slice_id = try optionalString(allocator, obj, "slice_id");
    errdefer freeOpt(allocator, slice_id);
    const gcr_id = try optionalString(allocator, obj, "gcr_id");
    errdefer freeOpt(allocator, gcr_id);
    const afr_id = try optionalString(allocator, obj, "afr_id");
    errdefer freeOpt(allocator, afr_id);
    const selected_route = try optionalString(allocator, obj, "selected_route");
    errdefer freeOpt(allocator, selected_route);
    return .{
        .kind = kind,
        .valid = errors.items.len == 0,
        .run_id = run_id,
        .slice_id = slice_id,
        .gcr_id = gcr_id,
        .afr_id = afr_id,
        .selected_route = selected_route,
        .errors = try errors.toOwnedSlice(allocator),
    };
}

fn invalidRow(allocator: std.mem.Allocator, kind: ArtifactKind, code: []const u8) !ArtifactRow {
    var errors: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, errors.items);
    try addError(allocator, &errors, code);
    return .{ .kind = kind, .valid = false, .errors = try errors.toOwnedSlice(allocator) };
}

fn requiredString(allocator: std.mem.Allocator, errors: *std.ArrayList([]u8), obj: std.json.ObjectMap, key: []const u8) !?[]u8 {
    if (try optionalString(allocator, obj, key)) |value| return value;
    try addError(allocator, errors, key);
    return null;
}

fn optionalString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        else => null,
    };
}

fn object(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn addError(allocator: std.mem.Allocator, errors: *std.ArrayList([]u8), code: []const u8) !void {
    try errors.append(allocator, try allocator.dupe(u8, code));
}

fn freeOpt(allocator: std.mem.Allocator, value: ?[]u8) void {
    if (value) |v| allocator.free(v);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "afr parser validates wrapper identity and reports malformed records" {
    const text =
        \\{"actuation_frontier":{"run_id":"run","slice_id":"slice","afr_id":"afr","graph_binding":{"gcr_id":"gcr"},"decision":{"selected_route":"bounded_new_surface"}}}
    ;
    var row = try parseArtifact(std.testing.allocator, text);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(row.valid);
    try std.testing.expectEqual(ArtifactKind.afr, row.kind);

    var bad = try parseArtifact(std.testing.allocator, "{\"actuation_frontier\":{\"run_id\":\"run\"}}");
    defer bad.deinit(std.testing.allocator);
    try std.testing.expect(!bad.valid);
    try std.testing.expect(bad.errors.len > 0);
}

test "artifact parser recovers embedded decision receipt identity" {
    var row = try parseArtifact(std.testing.allocator, "{\"skill_decision_receipt\":{\"run_id\":\"run\",\"selected_route\":\"bounded_new_surface\"}}");
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(row.valid);
    try std.testing.expectEqual(ArtifactKind.sdr, row.kind);
}
