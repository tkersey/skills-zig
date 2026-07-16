const std = @import("std");
const canonical_json = @import("canonical_json.zig");
const canonical_trace = @import("canonical_trace.zig");
const counterfactual_cut = @import("counterfactual_cut.zig");

pub const BuiltAvailability = struct {
    json: []u8,
    fingerprint: []u8,
    fidelity_class: []const u8,
    replay_eligible: bool,

    pub fn deinit(self: *BuiltAvailability, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        allocator.free(self.fingerprint);
    }
};

pub fn buildFromTraceAlloc(
    allocator: std.mem.Allocator,
    trace: canonical_trace.CanonicalSessionTrace,
    cut: counterfactual_cut.Cut,
    world_occurrence: ?canonical_trace.TraceOccurrence,
    target_slot: []const u8,
) !BuiltAvailability {
    const session_meta = firstOccurrenceAtOrBefore(trace, "session_meta", cut.last_fixed_line);
    const cut_timestamp = latestTimestampAtOrBefore(trace, cut.last_fixed_line) orelse "unknown";
    const world_class = if (world_occurrence != null) "direct_pre_cut" else "unknown";
    const world_carrier = if (world_occurrence) |occurrence| occurrence.entry_type else "world_state";
    const world_source_ref = if (world_occurrence) |occurrence|
        try std.fmt.allocPrint(allocator, "rollout:line-{d}", .{occurrence.line_number})
    else
        try allocator.dupe(u8, "unavailable");
    defer allocator.free(world_source_ref);
    const world_line: ?usize = if (world_occurrence) |occurrence| occurrence.line_number else null;
    const session_source_ref = if (session_meta) |occurrence|
        try std.fmt.allocPrint(allocator, "rollout:line-{d}", .{occurrence.line_number})
    else
        try allocator.dupe(u8, "unavailable");
    defer allocator.free(session_source_ref);
    const session_line: ?usize = if (session_meta) |occurrence| occurrence.line_number else null;

    const base = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-world-availability-receipt/v1\",\"cut_event_ref\":\"line:{d}\",\"cut_timestamp\":{f},\"items\":[{{\"item_id\":\"primary-session-metadata\",\"carrier\":\"repository_metadata\",\"source_ref\":{f},\"observed_line\":{f},\"availability_class\":{f},\"critical\":true,\"included\":{},\"fidelity_consequence\":\"metadata_only\"}},{{\"item_id\":\"latest-world-state\",\"carrier\":{f},\"source_ref\":{f},\"observed_line\":{f},\"availability_class\":{f},\"critical\":false,\"included\":false,\"fidelity_consequence\":\"payload_omitted\"}},{{\"item_id\":\"historical-repository-bytes\",\"carrier\":\"repository_bytes\",\"source_ref\":\"unavailable\",\"observed_line\":null,\"availability_class\":\"unknown\",\"critical\":true,\"included\":false,\"fidelity_consequence\":\"transcript_only\"}},{{\"item_id\":\"target-slot-mask\",\"carrier\":\"target_mount_slot\",\"source_ref\":{f},\"observed_line\":null,\"availability_class\":\"runtime_owned\",\"critical\":true,\"included\":true,\"fidelity_consequence\":\"target_bytes_excluded\"}}],\"fidelity_class\":\"transcript_only\",\"replay_eligible\":false,\"limitations\":[\"historical repository byte snapshot unavailable\",\"pre-cut world payload omitted because no target-free typed projection is available\",\"index, staged, unstaged, untracked, ignored, submodule, and fixture bytes unavailable\"],\"availability_fingerprint\":\"\"}}",
        .{
            cut.last_fixed_line,
            std.json.fmt(cut_timestamp, .{}),
            std.json.fmt(session_source_ref, .{}),
            std.json.fmt(session_line, .{}),
            std.json.fmt(if (session_meta != null) "direct_pre_cut" else "unknown", .{}),
            session_meta != null,
            std.json.fmt(world_carrier, .{}),
            std.json.fmt(world_source_ref, .{}),
            std.json.fmt(world_line, .{}),
            std.json.fmt(world_class, .{}),
            std.json.fmt(target_slot, .{}),
        },
    );
    defer allocator.free(base);
    const json = try canonical_json.finalizeFingerprintAlloc(allocator, base, "availability_fingerprint");
    errdefer allocator.free(json);
    const fingerprint = try fingerprintFromJsonAlloc(allocator, json, "availability_fingerprint");
    return .{ .json = json, .fingerprint = fingerprint, .fidelity_class = "transcript_only", .replay_eligible = false };
}

pub fn validate(value: std.json.Value, allocator: std.mem.Allocator) !bool {
    const root = object(value) catch return false;
    if (!hasExactKeys(root, &.{ "schema", "cut_event_ref", "cut_timestamp", "items", "fidelity_class", "replay_eligible", "limitations", "availability_fingerprint" }) or
        !equalsString(root, "schema", "hylo-world-availability-receipt/v1") or
        parseLineRef(stringValue(root.get("cut_event_ref")) orelse return false) == null or
        !nonblankString(root.get("cut_timestamp")) or
        !oneOf(stringValue(root.get("fidelity_class")) orelse return false, &.{ "exact_reconstruction", "controlled_replay", "workspace_snapshot", "tool_tape_replay", "transcript_only", "diagnostic_only", "unusable" })) return false;
    const cut_line = parseLineRef(stringValue(root.get("cut_event_ref")).?).?;
    const replay_eligible = boolValue(root.get("replay_eligible")) orelse return false;
    const items = arrayValue(root.get("items")) orelse return false;
    var has_primary_metadata = false;
    var has_world_state = false;
    var has_repository_bytes = false;
    var has_target_mask = false;
    var has_unknown_critical = false;
    for (items.items) |item_value| {
        const item = object(item_value) catch return false;
        if (!hasExactKeys(item, &.{ "item_id", "carrier", "source_ref", "observed_line", "availability_class", "critical", "included", "fidelity_consequence" }) or
            !nonblankString(item.get("item_id")) or
            !nonblankString(item.get("carrier")) or
            !nonblankString(item.get("source_ref")) or
            !nonblankString(item.get("fidelity_consequence"))) return false;
        const availability_class = stringValue(item.get("availability_class")) orelse return false;
        if (!oneOf(availability_class, &.{ "direct_pre_cut", "immutable_pre_cut_reconstruction", "evidence_bound_fixture", "runtime_owned", "post_cut", "unknown" })) return false;
        const critical = boolValue(item.get("critical")) orelse return false;
        const included = boolValue(item.get("included")) orelse return false;
        const observed_line = optionalInt(item.get("observed_line")) catch return false;
        const source_ref = stringValue(item.get("source_ref")).?;
        if (std.mem.indexOf(u8, source_ref, "custody") != null or std.mem.indexOf(u8, source_ref, "sealed") != null or
            std.mem.indexOf(u8, source_ref, "..") != null) return false;
        if (observed_line) |line| {
            if (line == 0) return false;
            const expected_ref = try std.fmt.allocPrint(allocator, "rollout:line-{d}", .{line});
            defer allocator.free(expected_ref);
            if (!std.mem.eql(u8, source_ref, expected_ref)) return false;
            if (line > cut_line and included) return false;
            if (std.mem.eql(u8, availability_class, "direct_pre_cut") and line > cut_line) return false;
        } else if (std.mem.eql(u8, availability_class, "direct_pre_cut")) return false;
        if (std.mem.eql(u8, availability_class, "unknown") and
            (!std.mem.eql(u8, source_ref, "unavailable") or observed_line != null or included)) return false;
        if (included and (std.mem.eql(u8, availability_class, "post_cut") or std.mem.eql(u8, availability_class, "unknown"))) return false;
        if (critical and std.mem.eql(u8, availability_class, "unknown")) has_unknown_critical = true;
        const item_id = stringValue(item.get("item_id")).?;
        const carrier = stringValue(item.get("carrier")).?;
        if (std.mem.eql(u8, item_id, "primary-session-metadata")) {
            if (has_primary_metadata or !std.mem.eql(u8, carrier, "repository_metadata")) return false;
            has_primary_metadata = true;
        } else if (std.mem.eql(u8, item_id, "latest-world-state")) {
            if (has_world_state or !oneOf(carrier, &.{ "world_state", "turn_context" })) return false;
            has_world_state = true;
        } else if (std.mem.eql(u8, item_id, "historical-repository-bytes")) {
            if (has_repository_bytes or !std.mem.eql(u8, carrier, "repository_bytes") or !critical or included or
                !std.mem.eql(u8, availability_class, "unknown")) return false;
            has_repository_bytes = true;
        } else if (std.mem.eql(u8, item_id, "target-slot-mask")) {
            if (has_target_mask or !std.mem.eql(u8, carrier, "target_mount_slot") or
                !std.mem.eql(u8, availability_class, "runtime_owned") or !included or
                !std.mem.startsWith(u8, stringValue(item.get("source_ref")).?, "skill://")) return false;
            has_target_mask = true;
        } else return false;
    }
    const limitations = arrayValue(root.get("limitations")) orelse return false;
    if (!has_primary_metadata or !has_world_state or !has_repository_bytes or !has_target_mask or
        limitations.items.len == 0 or !allNonblankStrings(limitations) or
        !equalsString(root, "fidelity_class", "transcript_only") or replay_eligible or
        (has_unknown_critical and replay_eligible)) return false;
    return canonical_json.verifyFingerprintAlloc(allocator, value, "availability_fingerprint");
}

fn firstOccurrenceAtOrBefore(trace: canonical_trace.CanonicalSessionTrace, entry_type: []const u8, line: usize) ?canonical_trace.TraceOccurrence {
    for (trace.occurrences.items) |occurrence| {
        if (occurrence.line_number > line) break;
        if (std.mem.eql(u8, occurrence.entry_type, entry_type)) return occurrence;
    }
    return null;
}

pub fn latestTimestampAtOrBefore(trace: canonical_trace.CanonicalSessionTrace, line: usize) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (trace.occurrences.items) |occurrence| {
        if (occurrence.line_number > line) break;
        if (occurrence.timestamp) |timestamp| result = timestamp;
    }
    return result;
}

fn fingerprintFromJsonAlloc(allocator: std.mem.Allocator, json: []const u8, field: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    return allocator.dupe(u8, stringValue(root.get(field)) orelse return error.FingerprintFieldMissing);
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ExpectedObject,
    };
}

fn hasExactKeys(object_map: std.json.ObjectMap, expected: []const []const u8) bool {
    if (object_map.count() != expected.len) return false;
    for (expected) |key| if (!object_map.contains(key)) return false;
    return true;
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    return if (value) |actual| switch (actual) {
        .string => |text| text,
        else => null,
    } else null;
}

fn boolValue(value: ?std.json.Value) ?bool {
    return if (value) |actual| switch (actual) {
        .bool => |boolean| boolean,
        else => null,
    } else null;
}

fn optionalInt(value: ?std.json.Value) !?usize {
    return if (value) |actual| switch (actual) {
        .null => null,
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidInteger,
        else => error.InvalidInteger,
    } else error.MissingField;
}

fn arrayValue(value: ?std.json.Value) ?std.json.Array {
    return if (value) |actual| switch (actual) {
        .array => |array| array,
        else => null,
    } else null;
}

fn equalsString(object_map: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const actual = stringValue(object_map.get(key)) orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn nonblankString(value: ?std.json.Value) bool {
    const actual = stringValue(value) orelse return false;
    return std.mem.trim(u8, actual, " \t\r\n").len > 0;
}

fn oneOf(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn allNonblankStrings(array: std.json.Array) bool {
    for (array.items) |item| if (!nonblankString(item)) return false;
    return true;
}

fn parseLineRef(value: []const u8) ?usize {
    if (!std.mem.startsWith(u8, value, "line:")) return null;
    const line = std.fmt.parseInt(usize, value["line:".len..], 10) catch return null;
    return if (line == 0) null else line;
}

test "availability rejects a post-cut included carrier even with a recomputed fingerprint" {
    const base =
        "{\"schema\":\"hylo-world-availability-receipt/v1\",\"cut_event_ref\":\"line:5\",\"cut_timestamp\":\"2026-07-13T00:00:00Z\",\"items\":[{\"item_id\":\"target-slot-mask\",\"carrier\":\"target_mount_slot\",\"source_ref\":\"skill://hylo\",\"observed_line\":null,\"availability_class\":\"runtime_owned\",\"critical\":true,\"included\":true,\"fidelity_consequence\":\"target_bytes_excluded\"},{\"item_id\":\"late\",\"carrier\":\"repository_bytes\",\"source_ref\":\"rollout:line-9\",\"observed_line\":9,\"availability_class\":\"post_cut\",\"critical\":true,\"included\":true,\"fidelity_consequence\":\"unusable\"}],\"fidelity_class\":\"unusable\",\"replay_eligible\":false,\"limitations\":[],\"availability_fingerprint\":\"\"}";
    const json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, base, "availability_fingerprint");
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validate(parsed.value, std.testing.allocator)));
}

test "availability rejects custody references in runner-visible carriers" {
    const base =
        "{\"schema\":\"hylo-world-availability-receipt/v1\",\"cut_event_ref\":\"line:5\",\"cut_timestamp\":\"2026-07-13T00:00:00Z\",\"items\":[{\"item_id\":\"primary-session-metadata\",\"carrier\":\"repository_metadata\",\"source_ref\":\"custody:historical-response.sealed.json\",\"observed_line\":1,\"availability_class\":\"direct_pre_cut\",\"critical\":true,\"included\":true,\"fidelity_consequence\":\"metadata_only\"},{\"item_id\":\"latest-world-state\",\"carrier\":\"turn_context\",\"source_ref\":\"rollout:line-2\",\"observed_line\":2,\"availability_class\":\"direct_pre_cut\",\"critical\":false,\"included\":false,\"fidelity_consequence\":\"payload_omitted\"},{\"item_id\":\"historical-repository-bytes\",\"carrier\":\"repository_bytes\",\"source_ref\":\"unavailable\",\"observed_line\":null,\"availability_class\":\"unknown\",\"critical\":true,\"included\":false,\"fidelity_consequence\":\"transcript_only\"},{\"item_id\":\"target-slot-mask\",\"carrier\":\"target_mount_slot\",\"source_ref\":\"skill://hylo\",\"observed_line\":null,\"availability_class\":\"runtime_owned\",\"critical\":true,\"included\":true,\"fidelity_consequence\":\"target_bytes_excluded\"}],\"fidelity_class\":\"transcript_only\",\"replay_eligible\":false,\"limitations\":[\"repository bytes unavailable\"],\"availability_fingerprint\":\"\"}";
    const json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, base, "availability_fingerprint");
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validate(parsed.value, std.testing.allocator)));
}
