const std = @import("std");
const canonical_json = @import("canonical_json.zig");
const canonical_trace = @import("canonical_trace.zig");

pub const BuiltRuntime = struct {
    json: []u8,
    fingerprint: []u8,

    pub fn deinit(self: *BuiltRuntime, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        allocator.free(self.fingerprint);
    }
};

pub fn buildFromTraceAlloc(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace, last_fixed_line: usize) !BuiltRuntime {
    var source = try canonical_trace.cutBoundContextAlloc(allocator, trace, last_fixed_line);
    defer source.deinit(allocator);
    const adapter_contract = try canonical_json.digestBytesAlloc(allocator, "codex-session-jsonl/v1");
    defer allocator.free(adapter_contract);
    const model_config = try std.fmt.allocPrint(allocator, "provider={s}\nmodel={s}\nreasoning_effort={s}\n", .{ source.model_provider orelse "unknown", source.model orelse "unknown", source.reasoning_effort orelse "unknown" });
    defer allocator.free(model_config);
    const model_fingerprint = try canonical_json.digestBytesAlloc(allocator, model_config);
    defer allocator.free(model_fingerprint);
    const context_basis = try std.fmt.allocPrint(allocator, "context_window={s}\ncompaction_identity={s}\n", .{ source.context_window_json orelse "unknown", source.compaction_identity orelse "unknown" });
    defer allocator.free(context_basis);
    const compaction_fingerprint: ?[]u8 = if (source.context_window_json != null or source.compaction_identity != null)
        try canonical_json.digestBytesAlloc(allocator, context_basis)
    else
        null;
    defer if (compaction_fingerprint) |value| allocator.free(value);
    const turn_context_fingerprint = try latestTurnContextFingerprintAlloc(allocator, trace, last_fixed_line);
    defer if (turn_context_fingerprint) |value| allocator.free(value);
    const tool_protocol = try canonical_json.digestBytesAlloc(allocator, "observable-tool-lifecycle/v1");
    defer allocator.free(tool_protocol);
    const base = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"hylo-runtime-contract/v1\",\"adapter\":{{\"id\":\"codex\",\"version\":{f},\"contract_fingerprint\":{f}}},\"model\":{{\"provider\":{f},\"model\":{f},\"reasoning_effort\":{f},\"configuration_fingerprint\":{f},\"seed_control\":\"unsupported\"}},\"context\":{{\"window\":null,\"compaction_policy_fingerprint\":{f},\"turn_context_fingerprint\":{f}}},\"tool_protocol_fingerprint\":{f},\"reconstruction_label\":\"paired_contemporary_counterfactual\",\"limitations\":[\"historical runtime binary and exact model snapshot unavailable\",\"effective turn policy is identity-bound but interpreted by the contemporary runtime\"],\"runtime_fingerprint\":\"\"}}",
        .{
            std.json.fmt(source.cli_version orelse "unknown", .{}),
            std.json.fmt(adapter_contract, .{}),
            std.json.fmt(source.model_provider orelse "unknown", .{}),
            std.json.fmt(source.model orelse "unknown", .{}),
            std.json.fmt(source.reasoning_effort orelse "unknown", .{}),
            std.json.fmt(model_fingerprint, .{}),
            std.json.fmt(compaction_fingerprint, .{}),
            std.json.fmt(turn_context_fingerprint, .{}),
            std.json.fmt(tool_protocol, .{}),
        },
    );
    defer allocator.free(base);
    const json = try canonical_json.finalizeFingerprintAlloc(allocator, base, "runtime_fingerprint");
    errdefer allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |map| map,
        else => return error.ExpectedObject,
    };
    const fingerprint = try allocator.dupe(u8, switch (object.get("runtime_fingerprint") orelse return error.FingerprintFieldMissing) {
        .string => |text| text,
        else => return error.FingerprintFieldMissing,
    });
    return .{ .json = json, .fingerprint = fingerprint };
}

pub fn validate(value: std.json.Value, allocator: std.mem.Allocator) !bool {
    const root = objectValue(value) orelse return false;
    // V1 has no typed authority artifact capable of proving an exact historical
    // runtime snapshot. Reserve that label rather than inferring it from prose.
    if (!hasExactKeys(root, &.{ "schema", "adapter", "model", "context", "tool_protocol_fingerprint", "reconstruction_label", "limitations", "runtime_fingerprint" }) or
        !equalsString(root, "schema", "hylo-runtime-contract/v1") or
        !canonical_json.isFingerprint(stringValue(root.get("tool_protocol_fingerprint")) orelse return false) or
        !equalsString(root, "reconstruction_label", "paired_contemporary_counterfactual")) return false;
    const adapter = objectValue(root.get("adapter") orelse return false) orelse return false;
    if (!hasExactKeys(adapter, &.{ "id", "version", "contract_fingerprint" }) or
        !nonblankString(adapter.get("id")) or
        !nonblankString(adapter.get("version")) or
        !canonical_json.isFingerprint(stringValue(adapter.get("contract_fingerprint")) orelse return false)) return false;
    const model = objectValue(root.get("model") orelse return false) orelse return false;
    if (!hasExactKeys(model, &.{ "provider", "model", "reasoning_effort", "configuration_fingerprint", "seed_control" }) or
        !nonblankString(model.get("provider")) or
        !nonblankString(model.get("model")) or
        !nonblankString(model.get("reasoning_effort")) or
        !canonical_json.isFingerprint(stringValue(model.get("configuration_fingerprint")) orelse return false) or
        !equalsString(model, "seed_control", "unsupported")) return false;
    const context = objectValue(root.get("context") orelse return false) orelse return false;
    if (!hasExactKeys(context, &.{ "window", "compaction_policy_fingerprint", "turn_context_fingerprint" }) or
        !optionalNonnegativeInteger(context.get("window")) or !optionalFingerprint(context.get("compaction_policy_fingerprint")) or
        !optionalFingerprint(context.get("turn_context_fingerprint"))) return false;
    const limitations = arrayValue(root.get("limitations")) orelse return false;
    if (limitations.items.len == 0) return false;
    for (limitations.items) |limitation| if (!nonblankString(limitation)) return false;
    return canonical_json.verifyFingerprintAlloc(allocator, value, "runtime_fingerprint");
}

fn latestTurnContextFingerprintAlloc(
    allocator: std.mem.Allocator,
    trace: canonical_trace.CanonicalSessionTrace,
    last_fixed_line: usize,
) !?[]u8 {
    var latest: ?[]u8 = null;
    errdefer if (latest) |value| allocator.free(value);
    for (trace.occurrences.items) |occurrence| {
        if (occurrence.line_number > last_fixed_line) break;
        if (!std.mem.eql(u8, occurrence.entry_type, "turn_context")) continue;
        const payload_json = occurrence.payload_json orelse continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch continue;
        defer parsed.deinit();
        const fingerprint = try canonical_json.digestValueAlloc(allocator, parsed.value);
        if (latest) |value| allocator.free(value);
        latest = fingerprint;
    }
    return latest;
}

test "runtime identity covers model identity" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/runtime.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, null, "session_meta", "session_meta", null, null, false));
    trace.occurrences.items[0].payload_json = try std.testing.allocator.dupe(u8, "{\"model\":\"model-a\"}");
    var first = try buildFromTraceAlloc(std.testing.allocator, trace, 1);
    defer first.deinit(std.testing.allocator);
    std.testing.allocator.free(trace.occurrences.items[0].payload_json.?);
    trace.occurrences.items[0].payload_json = try std.testing.allocator.dupe(u8, "{\"model\":\"model-b\"}");
    var second = try buildFromTraceAlloc(std.testing.allocator, trace, 1);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, first.fingerprint, second.fingerprint));
}

test "post-cut turn context cannot change runtime identity" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/runtime.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, null, "session_meta", "session_meta", null, null, false));
    trace.occurrences.items[0].payload_json = try std.testing.allocator.dupe(u8, "{\"id\":\"session\"}");
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 5, 0, "turn_context", "turn_context", null, null, false));
    trace.occurrences.items[1].payload_json = try std.testing.allocator.dupe(u8, "{\"model\":\"post-a\",\"cwd\":\"/a\"}");
    var first = try buildFromTraceAlloc(std.testing.allocator, trace, 1);
    defer first.deinit(std.testing.allocator);
    std.testing.allocator.free(trace.occurrences.items[1].payload_json.?);
    trace.occurrences.items[1].payload_json = try std.testing.allocator.dupe(u8, "{\"model\":\"post-b\",\"cwd\":\"/b\"}");
    var second = try buildFromTraceAlloc(std.testing.allocator, trace, 1);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.fingerprint, second.fingerprint);
}

test "runtime identity covers cut-bound reasoning effort" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/runtime-effort.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, null, "session_meta", "session_meta", null, null, false));
    trace.occurrences.items[0].payload_json = try std.testing.allocator.dupe(u8, "{\"model\":\"model-a\",\"model_provider\":\"provider\"}");
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 2, 0, "turn_context", "turn_context", null, null, false));
    trace.occurrences.items[1].payload_json = try std.testing.allocator.dupe(u8, "{\"effort\":\"low\"}");
    var first = try buildFromTraceAlloc(std.testing.allocator, trace, 2);
    defer first.deinit(std.testing.allocator);
    std.testing.allocator.free(trace.occurrences.items[1].payload_json.?);
    trace.occurrences.items[1].payload_json = try std.testing.allocator.dupe(u8, "{\"effort\":\"high\"}");
    var second = try buildFromTraceAlloc(std.testing.allocator, trace, 2);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, first.fingerprint, second.fingerprint));
}

test "runtime identity binds effective turn policy without promoting it to prompt text" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/runtime-policy.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 1, null, "session_meta", "session_meta", null, null, false));
    trace.occurrences.items[0].payload_json = try std.testing.allocator.dupe(u8, "{\"model\":\"model-a\",\"model_provider\":\"provider\"}");
    try trace.occurrences.append(std.testing.allocator, try canonical_trace.TraceOccurrence.init(std.testing.allocator, 2, 0, "turn_context", "turn_context", null, null, false));
    trace.occurrences.items[1].payload_json = try std.testing.allocator.dupe(u8, "{\"approval_policy\":\"never\",\"effort\":\"high\"}");
    var first = try buildFromTraceAlloc(std.testing.allocator, trace, 2);
    defer first.deinit(std.testing.allocator);
    std.testing.allocator.free(trace.occurrences.items[1].payload_json.?);
    trace.occurrences.items[1].payload_json = try std.testing.allocator.dupe(u8, "{\"approval_policy\":\"on-request\",\"effort\":\"high\"}");
    var second = try buildFromTraceAlloc(std.testing.allocator, trace, 2);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, first.fingerprint, second.fingerprint));
}

test "exact runtime reconstruction rejects unknown identity and unavailable evidence" {
    const base =
        "{\"schema\":\"hylo-runtime-contract/v1\",\"adapter\":{\"id\":\"codex\",\"version\":\"unknown\",\"contract_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"model\":{\"provider\":\"unknown\",\"model\":\"unknown\",\"reasoning_effort\":\"unknown\",\"configuration_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"seed_control\":\"unsupported\"},\"context\":{\"window\":null,\"compaction_policy_fingerprint\":null,\"turn_context_fingerprint\":null},\"tool_protocol_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"reconstruction_label\":\"exact_historical_reconstruction\",\"limitations\":[\"historical runtime unavailable\"],\"runtime_fingerprint\":\"\"}";
    const json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, base, "runtime_fingerprint");
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validate(parsed.value, std.testing.allocator)));
}

test "v1 reserves exact historical reconstruction even with complete-looking prose evidence" {
    const base =
        "{\"schema\":\"hylo-runtime-contract/v1\",\"adapter\":{\"id\":\"codex\",\"version\":\"1.0.0\",\"contract_fingerprint\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"model\":{\"provider\":\"provider\",\"model\":\"model\",\"reasoning_effort\":\"high\",\"configuration_fingerprint\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"seed_control\":\"unsupported\"},\"context\":{\"window\":200000,\"compaction_policy_fingerprint\":\"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"turn_context_fingerprint\":\"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"},\"tool_protocol_fingerprint\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"reconstruction_label\":\"exact_historical_reconstruction\",\"limitations\":[\"claimed exact by producer\"],\"runtime_fingerprint\":\"\"}";
    const json = try canonical_json.finalizeFingerprintAlloc(std.testing.allocator, base, "runtime_fingerprint");
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!(try validate(parsed.value, std.testing.allocator)));
}

fn objectValue(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => null,
    };
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    return if (value) |actual| switch (actual) {
        .string => |text| text,
        else => null,
    } else null;
}

fn arrayValue(value: ?std.json.Value) ?std.json.Array {
    return if (value) |actual| switch (actual) {
        .array => |array| array,
        else => null,
    } else null;
}

fn optionalNonnegativeInteger(value: ?std.json.Value) bool {
    return if (value) |actual| switch (actual) {
        .null => true,
        .integer => |integer| integer >= 0,
        else => false,
    } else false;
}

fn optionalFingerprint(value: ?std.json.Value) bool {
    return if (value) |actual| switch (actual) {
        .null => true,
        .string => |text| canonical_json.isFingerprint(text),
        else => false,
    } else false;
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
