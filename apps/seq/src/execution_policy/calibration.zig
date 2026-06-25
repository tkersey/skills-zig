const std = @import("std");
const retrace_core = @import("retrace_core");
const canonical_trace = retrace_core.canonical_trace;
const output = @import("../output/mod.zig");

pub const Summary = struct {
    transition_audits_json: []u8,
    predicted_facts: i64,
    observed_facts: i64,
    matched_facts: i64,
    missed_facts: i64,
    unexpected_facts: i64,
    transition_count: i64,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.transition_audits_json);
    }
};

pub fn analyze(allocator: std.mem.Allocator, trace: canonical_trace.CanonicalSessionTrace) !Summary {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;
    try writer.writeByte('[');
    var first = true;
    var totals = Totals{};

    for (trace.turns.items) |turn| {
        if (turn.user_message) |text| try collectFromText(allocator, writer, &first, &totals, text);
        if (turn.assistant_preview) |text| try collectFromText(allocator, writer, &first, &totals, text);
        if (turn.final_answer) |text| try collectFromText(allocator, writer, &first, &totals, text);
    }
    for (trace.tools.items) |tool| {
        if (tool.command_text) |text| try collectFromText(allocator, writer, &first, &totals, text);
        if (tool.input_text) |text| try collectFromText(allocator, writer, &first, &totals, text);
        if (tool.output_text) |text| try collectFromText(allocator, writer, &first, &totals, text);
    }

    try writer.writeByte(']');
    return .{
        .transition_audits_json = try writer_alloc.toOwnedSlice(),
        .predicted_facts = totals.predicted,
        .observed_facts = totals.observed,
        .matched_facts = totals.matched,
        .missed_facts = totals.missed,
        .unexpected_facts = totals.unexpected,
        .transition_count = totals.transitions,
    };
}

const Totals = struct {
    predicted: i64 = 0,
    observed: i64 = 0,
    matched: i64 = 0,
    missed: i64 = 0,
    unexpected: i64 = 0,
    transitions: i64 = 0,
};

fn collectFromText(allocator: std.mem.Allocator, writer: anytype, first: *bool, totals: *Totals, text: []const u8) !void {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, "ETR-v1")) |label| {
        search_from = label + "ETR-v1".len;
        const json = try extractObjectAfter(allocator, text, label) orelse continue;
        defer allocator.free(json);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const root = parsed.value.object;
        const predicted = try stringArray(allocator, root.get("predicted_effects"));
        defer allocator.free(predicted);
        const observed = if (root.get("observed")) |obs|
            if (obs == .object) try stringArray(allocator, obs.object.get("facts")) else try allocator.alloc([]const u8, 0)
        else
            try allocator.alloc([]const u8, 0);
        defer allocator.free(observed);
        const matched = countMatches(predicted, observed);
        const missed = @as(i64, @intCast(predicted.len)) - matched;
        const unexpected = @as(i64, @intCast(observed.len)) - matched;
        totals.predicted += @intCast(predicted.len);
        totals.observed += @intCast(observed.len);
        totals.matched += matched;
        totals.missed += missed;
        totals.unexpected += unexpected;
        totals.transitions += 1;

        if (!first.*) try writer.writeByte(',');
        first.* = false;
        try writer.writeAll("{\"transition_id\":");
        try output.writeJsonString(writer, stringField(root, "receipt_id") orelse stringField(root, "transition_id") orelse "etr");
        try writer.writeAll(",\"decision_id\":");
        try output.writeJsonString(writer, stringField(root, "decision_id") orelse "");
        try writer.writeAll(",\"action_id\":");
        try output.writeJsonString(writer, stringField(root, "action_id") orelse "");
        try writer.print(",\"predicted\":{d},\"observed\":{d},\"matches\":{d},\"misses\":{d},\"unexpected\":{d},\"valid\":true", .{
            predicted.len,
            observed.len,
            matched,
            missed,
            unexpected,
        });
        try writer.writeByte('}');
    }
}

fn stringArray(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    const v = value orelse return allocator.alloc([]const u8, 0);
    if (v != .array) return allocator.alloc([]const u8, 0);
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    for (v.array.items) |item| {
        if (item == .string) try out.append(allocator, item.string);
    }
    return out.toOwnedSlice(allocator);
}

fn countMatches(predicted_values: []const []const u8, observed_values: []const []const u8) i64 {
    var matches: i64 = 0;
    for (predicted_values) |predicted| {
        for (observed_values) |observed| {
            if (std.mem.eql(u8, predicted, observed)) {
                matches += 1;
                break;
            }
        }
    }
    return matches;
}

fn stringField(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = root.get(key) orelse return null;
    if (value == .string) return value.string;
    return null;
}

fn extractObjectAfter(allocator: std.mem.Allocator, text: []const u8, label: usize) !?[]u8 {
    const start = std.mem.indexOfScalarPos(u8, text, label, '{') orelse return null;
    const end = findJsonObjectEnd(text, start) orelse return null;
    return try allocator.dupe(u8, text[start .. end + 1]);
}

fn findJsonObjectEnd(text: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    var cursor = start;
    while (cursor < text.len) : (cursor += 1) {
        const c = text[cursor];
        if (in_string) {
            if (escape) escape = false else if (c == '\\') escape = true else if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') in_string = true else if (c == '{') depth += 1 else if (c == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return cursor;
        }
    }
    return null;
}

test "calibration emits transition audit counts" {
    var trace = canonical_trace.CanonicalSessionTrace{ .session = try canonical_trace.SessionRecord.init(std.testing.allocator, "/tmp/policy.jsonl") };
    defer trace.deinit(std.testing.allocator);
    try trace.turns.append(std.testing.allocator, .{
        .path = try std.testing.allocator.dupe(u8, "/tmp/policy.jsonl"),
        .turn_id = try std.testing.allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .assistant_preview = try std.testing.allocator.dupe(u8,
            \\ETR-v1 {"receipt_id":"t1","decision_id":"d","action_id":"a","predicted_effects":["fact:a","fact:b"],"observed":{"facts":["fact:a","fact:c"]},"state_after":{}}
        ),
    });
    var summary = try analyze(std.testing.allocator, trace);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), summary.matched_facts);
    try std.testing.expectEqual(@as(i64, 1), summary.missed_facts);
    try std.testing.expectEqual(@as(i64, 1), summary.unexpected_facts);
}
