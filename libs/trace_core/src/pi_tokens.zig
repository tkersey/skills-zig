//! Per-request token accounting for persisted Pi assistant messages.
//!
//! Pi writes each model response as one `message` entry whose message role is
//! `assistant`, so one such entry is one request. Standalone compaction and
//! branch-summary entries are distinct entry types; callers never pass them
//! here, so their usage is never counted as a request.

const std = @import("std");
const usage = @import("claude_usage.zig");

pub const Quantity = usage.Quantity;
pub const QuantityState = usage.QuantityState;

const Counter = enum { input, cache_read, cache_write, output, total };

const counter_fields = [_][]const u8{ "input", "cacheRead", "cacheWrite", "output", "totalTokens" };

comptime {
    std.debug.assert(counter_fields.len == @typeInfo(Counter).@"enum".field_names.len);
}

/// Pi's copy paths (`/fork`, `/clone`, `--fork` and `/import`) rewrite at most an
/// entry's `parentId`, so its `id` and `timestamp` identify one request in every
/// copy. Entry IDs are eight hex digits checked for collisions only within one
/// file; the persisted append instant separates equal IDs in unrelated sessions.
/// Provider response IDs are not identities: OpenAI-compatible servers such as
/// Ollama answer with `chatcmpl-<0..998>`, which repeats across requests.
/// Returns null when the entry carries no usable identity.
pub fn requestKeyAlloc(allocator: std.mem.Allocator, root: std.json.ObjectMap) !?[]u8 {
    const id = stringField(root, "id") orelse return null;
    const timestamp = stringField(root, "timestamp") orelse return null;
    if (id.len == 0 or timestamp.len == 0) return null;
    // The separator splits at the first '@', so an ID containing it is ambiguous.
    if (std.mem.indexOfScalar(u8, id, '@') != null) return null;
    return try std.fmt.allocPrint(allocator, "{s}@{s}", .{ id, timestamp });
}

/// Pi records `pending` while a response streams and `deferred` while the
/// provider holds it. Any other recorded stop reason ends the response.
pub fn isFinal(message: std.json.ObjectMap) bool {
    const reason = stringField(message, "stopReason") orelse return false;
    if (reason.len == 0) return false;
    return !std.mem.eql(u8, reason, "pending") and !std.mem.eql(u8, reason, "deferred");
}

/// Classifies `message.usage` before reducing it. Normalized input is
/// `input + cacheRead + cacheWrite`; reported `reasoning` and `cacheWrite1h` are
/// subsets of `output` and `cacheWrite`; `totalTokens` must equal input + output.
pub fn readQuantity(message: std.json.ObjectMap) Quantity {
    const object = switch (message.get("usage") orelse return .{}) {
        .null => return .{},
        .object => |value| value,
        else => return .{ .state = .unsupported },
    };
    var values: [counter_fields.len]i64 = @splat(0);
    var result = Quantity{ .present = true, .state = readCounters(object, &values) };
    if (result.state != .usable) return result;
    result.state = normalize(&result, object, values);
    return result;
}

fn readCounters(object: std.json.ObjectMap, values: *[counter_fields.len]i64) QuantityState {
    var missing = false;
    var invalid = false;
    for (counter_fields, values) |field, *value| switch (usage.counter(object, field)) {
        .absent => missing = true,
        .invalid => invalid = true,
        .value => |count| value.* = count,
    };
    for ([_][]const u8{ "reasoning", "cacheWrite1h" }) |field| {
        if (usage.counter(object, field) == .invalid) invalid = true;
    }
    if (invalid) return .invalid;
    return if (missing) .missing else .usable;
}

fn normalize(
    result: *Quantity,
    object: std.json.ObjectMap,
    values: [counter_fields.len]i64,
) QuantityState {
    const cache_read = values[@backingInt(Counter.cache_read)];
    const cache_write = values[@backingInt(Counter.cache_write)];
    const output = values[@backingInt(Counter.output)];
    const cached = std.math.add(i64, cache_read, cache_write) catch return .invalid;
    result.input = std.math.add(i64, values[@backingInt(Counter.input)], cached) catch
        return .invalid;
    result.total = std.math.add(i64, result.input, output) catch return .invalid;
    result.cached = cache_read;
    result.cache_creation = cache_write;
    result.output = output;
    result.reasoning = optionalCounter(object, "reasoning");
    if (result.total != values[@backingInt(Counter.total)]) return .invalid;
    if (result.reasoning) |reasoning| if (reasoning > output) return .invalid;
    if (optionalCounter(object, "cacheWrite1h")) |hour| if (hour > cache_write) return .invalid;
    return .usable;
}

fn optionalCounter(object: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (usage.counter(object, field)) {
        .value => |count| count,
        .absent, .invalid => null,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn quantityFromUsage(usage_json: []const u8) !Quantity {
    const allocator = std.testing.allocator;
    const text = try std.fmt.allocPrint(allocator, "{{\"usage\":{s}}}", .{usage_json});
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return readQuantity(parsed.value.object);
}

test "Pi usage folds both cache categories into input and keeps reasoning inside output" {
    const reported = try quantityFromUsage(
        \\{"input":10,"cacheRead":3,"cacheWrite":4,"output":2,"reasoning":1,"totalTokens":19,"cacheWrite1h":4,"cost":{"total":0.1}}
    );
    try std.testing.expectEqual(QuantityState.usable, reported.state);
    try std.testing.expect(reported.present);
    try std.testing.expectEqual(@as(i64, 17), reported.input);
    try std.testing.expectEqual(@as(i64, 3), reported.cached);
    try std.testing.expectEqual(@as(i64, 4), reported.cache_creation);
    try std.testing.expectEqual(@as(i64, 2), reported.output);
    try std.testing.expectEqual(@as(i64, 19), reported.total);
    try std.testing.expectEqual(@as(?i64, 1), reported.reasoning);
    const unreported = try quantityFromUsage(
        \\{"input":20,"cacheRead":0,"cacheWrite":0,"output":4,"totalTokens":24,"reasoning":null}
    );
    try std.testing.expectEqual(QuantityState.usable, unreported.state);
    try std.testing.expectEqual(@as(?i64, null), unreported.reasoning);
}

test "Pi usage states classify absent, unreadable, and contradictory counters" {
    const base = "{\"input\":1,\"cacheRead\":0,\"cacheWrite\":2,\"output\":3";
    const Case = struct { usage: []const u8, state: QuantityState, present: bool = true };
    const cases = [_]Case{
        .{ .usage = "null", .state = .missing, .present = false },
        .{ .usage = "\"6\"", .state = .unsupported, .present = false },
        .{ .usage = "[1,2]", .state = .unsupported, .present = false },
        .{ .usage = base ++ "}", .state = .missing },
        .{ .usage = base ++ ",\"totalTokens\":6}", .state = .usable },
        .{ .usage = base ++ ",\"totalTokens\":5}", .state = .invalid },
        .{ .usage = base ++ ",\"totalTokens\":-6}", .state = .invalid },
        .{ .usage = base ++ ",\"totalTokens\":6.5}", .state = .invalid },
        .{ .usage = base ++ ",\"totalTokens\":\"6\"}", .state = .invalid },
        .{ .usage = base ++ ",\"totalTokens\":6,\"reasoning\":3}", .state = .usable },
        .{ .usage = base ++ ",\"totalTokens\":6,\"reasoning\":4}", .state = .invalid },
        .{ .usage = base ++ ",\"totalTokens\":6,\"reasoning\":-1}", .state = .invalid },
        .{ .usage = base ++ ",\"totalTokens\":6,\"cacheWrite1h\":2}", .state = .usable },
        .{ .usage = base ++ ",\"totalTokens\":6,\"cacheWrite1h\":3}", .state = .invalid },
        .{ .usage = "{\"input\":-1,\"output\":3}", .state = .invalid },
        .{
            .usage = "{\"input\":9223372036854775807,\"cacheRead\":1,\"cacheWrite\":0," ++
                "\"output\":0,\"totalTokens\":9223372036854775807}",
            .state = .invalid,
        },
    };
    try std.testing.expectEqual(QuantityState.missing, (try quantityFromUsage("{}")).state);
    for (cases) |case| {
        const quantity = try quantityFromUsage(case.usage);
        try std.testing.expectEqual(case.state, quantity.state);
        try std.testing.expectEqual(case.present, quantity.present);
    }
    var absent = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer absent.deinit();
    try std.testing.expectEqualDeep(Quantity{}, readQuantity(absent.value.object));
}

test "Pi finality follows the recorded stop reason and request keys need a full identity" {
    const allocator = std.testing.allocator;
    const Case = struct { json: []const u8, final: bool = false, key: ?[]const u8 = null };
    const cases = [_]Case{
        .{
            .json = "{\"id\":\"a1\",\"timestamp\":\"t\",\"stopReason\":\"toolUse\"}",
            .final = true,
            .key = "a1@t",
        },
        .{
            .json = "{\"id\":\"a1\",\"timestamp\":\"t\",\"stopReason\":\"aborted\"}",
            .final = true,
            .key = "a1@t",
        },
        .{ .json = "{\"id\":\"a1\",\"stopReason\":\"pending\"}" },
        .{ .json = "{\"timestamp\":\"t\",\"stopReason\":\"deferred\"}" },
        .{ .json = "{\"id\":\"a@1\",\"timestamp\":\"t\",\"stopReason\":\"\"}" },
        .{ .json = "{\"id\":\"\",\"timestamp\":\"t\",\"stopReason\":null}" },
        .{ .json = "{\"id\":7,\"timestamp\":\"t\",\"stopReason\":1}" },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.final, isFinal(parsed.value.object));
        const key = try requestKeyAlloc(allocator, parsed.value.object);
        defer if (key) |value| allocator.free(value);
        if (case.key) |expected| {
            try std.testing.expectEqualStrings(expected, key.?);
        } else {
            try std.testing.expect(key == null);
        }
    }
}
