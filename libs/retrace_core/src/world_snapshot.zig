const std = @import("std");
const canonical_json = @import("canonical_json.zig");
const canonical_trace = @import("canonical_trace.zig");

pub const BuiltWorld = struct {
    json: []u8,
    fingerprint: []u8,

    pub fn deinit(self: *BuiltWorld, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        allocator.free(self.fingerprint);
    }
};

pub fn buildFromTraceAlloc(
    allocator: std.mem.Allocator,
    trace: canonical_trace.CanonicalSessionTrace,
    last_fixed_line: usize,
    world_payload_json: ?[]const u8,
    cut_timestamp: []const u8,
    availability_fingerprint: []const u8,
    target_slot: []const u8,
    capture_requested: bool,
) !BuiltWorld {
    _ = world_payload_json;
    var context = try canonical_trace.cutBoundContextAlloc(allocator, trace, last_fixed_line);
    defer context.deinit(allocator);
    const source_basis = try std.fmt.allocPrint(
        allocator,
        "hylo-target-masked-world-source/v1\ncwd={s}\nhead={s}\n",
        .{ context.cwd orelse "unknown", context.git_commit_hash orelse "unknown" },
    );
    defer allocator.free(source_basis);
    const source_digest = try canonical_json.digestBytesAlloc(allocator, source_basis);
    defer allocator.free(source_digest);
    const world_id = try std.fmt.allocPrint(allocator, "world-{s}", .{source_digest[7..23]});
    defer allocator.free(world_id);
    const repository_identity = try std.fmt.allocPrint(allocator, "repo-{s}", .{source_digest[7..23]});
    defer allocator.free(repository_identity);
    const base = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-world-snapshot/v1\",\"world_id\":{f},\"repository\":{{\"root_identity\":{f},\"head_commit\":{f},\"head_tree\":null,\"index_tree\":null,\"working_tree_patch_fingerprint\":null,\"untracked_manifest_ref\":null,\"ignored_manifest_ref\":null,\"availability\":\"metadata_only\",\"target_mount_slots\":[{f}],\"target_roots_included\":false}},\"clock\":{{\"mode\":\"cut_bound_trace_timestamp\",\"instant\":{f},\"timezone\":\"source_declared_or_unknown\"}},\"environment\":{{\"locale\":null,\"variables\":[],\"secret_substitutions\":[]}},\"tool_registry\":{{\"fingerprint\":null,\"tools\":[]}},\"fixtures\":[],\"network\":{{\"mode\":\"deny_unless_fixture\",\"fixture_set_ref\":null}},\"external_effects\":{{\"mode\":\"deny\"}},\"source_world_state_fingerprint\":{f},\"availability_receipt_ref\":\"artifact:world-availability.json\",\"availability_fingerprint\":{f},\"capture_requested\":{},\"reconstruction\":{{\"class\":\"transcript_only\",\"limitations\":[\"historical repository byte snapshot unavailable\",\"index, staged, unstaged, untracked, ignored, submodule, and external fixture bytes unavailable\"]}},\"world_fingerprint\":\"\"}}",
        .{
            std.json.fmt(world_id, .{}),
            std.json.fmt(repository_identity, .{}),
            std.json.fmt(context.git_commit_hash orelse "unknown", .{}),
            std.json.fmt(target_slot, .{}),
            std.json.fmt(cut_timestamp, .{}),
            std.json.fmt(source_digest, .{}),
            std.json.fmt(availability_fingerprint, .{}),
            capture_requested,
        },
    );
    defer allocator.free(base);
    const json = try canonical_json.finalizeFingerprintAlloc(allocator, base, "world_fingerprint");
    errdefer allocator.free(json);
    const fingerprint = try fingerprintFromJsonAlloc(allocator, json, "world_fingerprint");
    return .{ .json = json, .fingerprint = fingerprint };
}

pub fn validate(value: std.json.Value, allocator: std.mem.Allocator) !bool {
    const root = switch (value) {
        .object => |map| map,
        else => return false,
    };
    if (!hasExactKeys(root, &.{ "schema", "world_id", "repository", "clock", "environment", "tool_registry", "fixtures", "network", "external_effects", "source_world_state_fingerprint", "availability_receipt_ref", "availability_fingerprint", "capture_requested", "reconstruction", "world_fingerprint" }) or
        !equalsString(root, "schema", "hylo-world-snapshot/v1") or
        !nonblankString(root.get("world_id")) or
        !equalsString(root, "availability_receipt_ref", "artifact:world-availability.json") or
        !canonical_json.isFingerprint(stringValue(root.get("availability_fingerprint")) orelse return false) or
        !canonical_json.isFingerprint(stringValue(root.get("source_world_state_fingerprint")) orelse return false) or
        boolValue(root.get("capture_requested")) == null) return false;
    const repository = objectValue(root.get("repository")) orelse return false;
    if (!hasExactKeys(repository, &.{ "root_identity", "head_commit", "head_tree", "index_tree", "working_tree_patch_fingerprint", "untracked_manifest_ref", "ignored_manifest_ref", "availability", "target_mount_slots", "target_roots_included" }) or
        !nonblankString(repository.get("root_identity")) or
        !nonblankString(repository.get("head_commit")) or
        !equalsString(repository, "availability", "metadata_only") or
        !isNull(repository.get("head_tree")) or !isNull(repository.get("index_tree")) or
        !isNull(repository.get("working_tree_patch_fingerprint")) or !isNull(repository.get("untracked_manifest_ref")) or
        !isNull(repository.get("ignored_manifest_ref")) or
        boolValue(repository.get("target_roots_included")) != false) return false;
    const slots = arrayValue(repository.get("target_mount_slots")) orelse return false;
    if (slots.items.len != 1) return false;
    for (slots.items) |slot| if (!startsWithString(slot, "skill://")) return false;
    const clock = objectValue(root.get("clock")) orelse return false;
    if (!hasExactKeys(clock, &.{ "mode", "instant", "timezone" }) or
        !equalsString(clock, "mode", "cut_bound_trace_timestamp") or !nonblankString(clock.get("instant")) or !nonblankString(clock.get("timezone"))) return false;
    const environment = objectValue(root.get("environment")) orelse return false;
    if (!hasExactKeys(environment, &.{ "locale", "variables", "secret_substitutions" }) or
        !optionalString(environment.get("locale")) or !emptyArray(environment.get("variables")) or !emptyArray(environment.get("secret_substitutions"))) return false;
    const tool_registry = objectValue(root.get("tool_registry")) orelse return false;
    if (!hasExactKeys(tool_registry, &.{ "fingerprint", "tools" }) or !isNull(tool_registry.get("fingerprint")) or !emptyArray(tool_registry.get("tools"))) return false;
    if (!emptyArray(root.get("fixtures"))) return false;
    const network = objectValue(root.get("network")) orelse return false;
    if (!hasExactKeys(network, &.{ "mode", "fixture_set_ref" }) or !equalsString(network, "mode", "deny_unless_fixture") or !isNull(network.get("fixture_set_ref"))) return false;
    const external_effects = objectValue(root.get("external_effects")) orelse return false;
    if (!hasExactKeys(external_effects, &.{"mode"}) or !equalsString(external_effects, "mode", "deny")) return false;
    const reconstruction = objectValue(root.get("reconstruction")) orelse return false;
    if (!hasExactKeys(reconstruction, &.{ "class", "limitations" }) or !equalsString(reconstruction, "class", "transcript_only")) return false;
    const limitations = arrayValue(reconstruction.get("limitations")) orelse return false;
    if (limitations.items.len == 0 or !allNonblankStrings(limitations)) return false;
    return canonical_json.verifyFingerprintAlloc(allocator, value, "world_fingerprint");
}

fn fingerprintFromJsonAlloc(allocator: std.mem.Allocator, json: []const u8, field: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |map| map,
        else => return error.ExpectedObject,
    };
    const value = switch (object.get(field) orelse return error.FingerprintFieldMissing) {
        .string => |text| text,
        else => return error.FingerprintFieldMissing,
    };
    return allocator.dupe(u8, value);
}

test "omitted opaque world observations do not claim identity coverage" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/world.jsonl") };
    defer trace.deinit(std.testing.allocator);
    const availability = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    var first = try buildFromTraceAlloc(std.testing.allocator, trace, 0, "{\"cwd\":\"/a\"}", "2026-07-13T00:00:00Z", availability, "skill://hylo", true);
    defer first.deinit(std.testing.allocator);
    var second = try buildFromTraceAlloc(std.testing.allocator, trace, 0, null, "2026-07-13T00:00:00Z", availability, "skill://hylo", true);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.fingerprint, second.fingerprint);
}

test "opaque world payload bytes cannot reintroduce target content into identity" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/world.jsonl") };
    defer trace.deinit(std.testing.allocator);
    const availability = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    var first = try buildFromTraceAlloc(std.testing.allocator, trace, 0, "{\"target\":\"old\"}", "2026-07-13T00:00:00Z", availability, "skill://hylo", true);
    defer first.deinit(std.testing.allocator);
    var second = try buildFromTraceAlloc(std.testing.allocator, trace, 0, "{\"target\":\"new\"}", "2026-07-13T00:00:00Z", availability, "skill://hylo", true);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.fingerprint, second.fingerprint);
}

test "world identity covers the cut-bound clock" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/world.jsonl") };
    defer trace.deinit(std.testing.allocator);
    const availability = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    var first = try buildFromTraceAlloc(std.testing.allocator, trace, 0, null, "2026-07-13T00:00:00Z", availability, "skill://hylo", true);
    defer first.deinit(std.testing.allocator);
    var second = try buildFromTraceAlloc(std.testing.allocator, trace, 0, null, "2026-07-13T00:00:01Z", availability, "skill://hylo", true);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, first.fingerprint, second.fingerprint));
}

test "world identity covers legacy top-level git commit metadata" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/world-git.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, null, "session_meta", "session_meta", null, null, false));
    trace.occurrences.items[0].payload_json = try std.testing.allocator.dupe(u8, "{\"cwd\":\"/repo\",\"git_commit_hash\":\"commit-a\"}");
    const availability = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    var first = try buildFromTraceAlloc(std.testing.allocator, trace, 1, null, "2026-07-13T00:00:00Z", availability, "skill://hylo", true);
    defer first.deinit(std.testing.allocator);
    std.testing.allocator.free(trace.occurrences.items[0].payload_json.?);
    trace.occurrences.items[0].payload_json = try std.testing.allocator.dupe(u8, "{\"cwd\":\"/repo\",\"git_commit_hash\":\"commit-b\"}");
    var second = try buildFromTraceAlloc(std.testing.allocator, trace, 1, null, "2026-07-13T00:00:00Z", availability, "skill://hylo", true);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, first.fingerprint, second.fingerprint));
}

test "world validation rejects untyped runner-visible fixtures after refingerprinting" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/world.jsonl") };
    defer trace.deinit(std.testing.allocator);
    const availability = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    var world = try buildFromTraceAlloc(std.testing.allocator, trace, 0, null, "2026-07-13T00:00:00Z", availability, "skill://hylo", true);
    defer world.deinit(std.testing.allocator);
    const mutated = try std.mem.replaceOwned(u8, std.testing.allocator, world.json, "\"fixtures\":[]", "\"fixtures\":[{\"answer\":\"future\"}]");
    defer std.testing.allocator.free(mutated);
    const refingerprinted = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, mutated, "world_fingerprint");
    defer std.testing.allocator.free(refingerprinted);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, refingerprinted, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validate(parsed.value, std.testing.allocator)));
}

fn objectValue(value: ?std.json.Value) ?std.json.ObjectMap {
    return if (value) |actual| switch (actual) {
        .object => |map| map,
        else => null,
    } else null;
}

fn arrayValue(value: ?std.json.Value) ?std.json.Array {
    return if (value) |actual| switch (actual) {
        .array => |array| array,
        else => null,
    } else null;
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

fn isNull(value: ?std.json.Value) bool {
    return if (value) |actual| switch (actual) {
        .null => true,
        else => false,
    } else false;
}

fn optionalString(value: ?std.json.Value) bool {
    return if (value) |actual| switch (actual) {
        .null, .string => true,
        else => false,
    } else false;
}

fn emptyArray(value: ?std.json.Value) bool {
    const array = arrayValue(value) orelse return false;
    return array.items.len == 0;
}

fn allNonblankStrings(array: std.json.Array) bool {
    for (array.items) |item| if (!nonblankString(item)) return false;
    return true;
}

fn hasExactKeys(object: std.json.ObjectMap, expected: []const []const u8) bool {
    if (object.count() != expected.len) return false;
    for (expected) |key| if (!object.contains(key)) return false;
    return true;
}

fn equalsString(object: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const actual = stringValue(object.get(key)) orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn nonblankString(value: ?std.json.Value) bool {
    const actual = stringValue(value) orelse return false;
    return std.mem.trim(u8, actual, " \t\r\n").len > 0;
}

fn startsWithString(value: std.json.Value, prefix: []const u8) bool {
    const actual = stringValue(value) orelse return false;
    return std.mem.startsWith(u8, actual, prefix);
}

fn oneOf(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}
