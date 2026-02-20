const std = @import("std");

pub const token_key_count: usize = 5;
pub const input_idx: usize = 0;
pub const cached_input_idx: usize = 1;
pub const output_idx: usize = 2;
pub const reasoning_output_idx: usize = 3;
pub const total_idx: usize = 4;

pub const SmallText = struct {
    len: u8 = 0,
    buf: [64]u8 = [_]u8{0} ** 64,

    pub fn fromSlice(text: []const u8) !SmallText {
        if (text.len > 64) return error.TextTooLong;
        var out = SmallText{};
        out.len = @intCast(text.len);
        @memcpy(out.buf[0..text.len], text);
        return out;
    }

    pub fn slice(self: *const SmallText) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Row = struct {
    path: []const u8,
    timestamp: ?SmallText = null,
    day: ?SmallText = null,
    week: ?SmallText = null,
    month: ?SmallText = null,
    model_context_window: ?i64 = null,
    total_input_tokens: ?i64 = null,
    total_cached_input_tokens: ?i64 = null,
    total_output_tokens: ?i64 = null,
    total_reasoning_output_tokens: ?i64 = null,
    total_total_tokens: ?i64 = null,
    last_input_tokens: ?i64 = null,
    last_cached_input_tokens: ?i64 = null,
    last_output_tokens: ?i64 = null,
    last_reasoning_output_tokens: ?i64 = null,
    last_total_tokens: ?i64 = null,
};

pub fn parseTokenEvents(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    dedupe: bool,
) !std.ArrayList(Row) {
    var rows = std.ArrayList(Row).empty;
    var prev_total_tokens: ?i64 = null;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const maybe_row = try parseTokenCountLine(line, path);
        const row = maybe_row orelse continue;

        if (dedupe and
            prev_total_tokens != null and
            row.total_total_tokens != null and
            prev_total_tokens.? == row.total_total_tokens.?)
        {
            continue;
        }

        if (row.total_total_tokens) |v| prev_total_tokens = v;
        try rows.append(allocator, row);
    }

    return rows;
}

pub fn parseTokenCountLine(line: []const u8, path: []const u8) !?Row {
    if (!std.mem.containsAtLeast(u8, line, 1, "event_msg")) return null;
    if (!std.mem.containsAtLeast(u8, line, 1, "token_count")) return null;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{}) catch return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    if (!fieldEq(root, "type", "event_msg")) return null;

    const payload = objectField(root, "payload") orelse return null;
    if (!fieldEq(payload, "type", "token_count")) return null;

    const info = objectField(payload, "info") orelse return null;

    var row = Row{ .path = path };

    if (stringField(root, "timestamp")) |ts| {
        row.timestamp = try SmallText.fromSlice(ts);
        if (ts.len >= 10) row.day = try SmallText.fromSlice(ts[0..10]);
        if (ts.len >= 7) row.month = try SmallText.fromSlice(ts[0..7]);
    }

    row.model_context_window = intField(info, "model_context_window");

    const total_usage = objectField(info, "total_token_usage");
    row.total_input_tokens = intFieldMaybe(total_usage, "input_tokens");
    row.total_cached_input_tokens = intFieldMaybe(total_usage, "cached_input_tokens");
    row.total_output_tokens = intFieldMaybe(total_usage, "output_tokens");
    row.total_reasoning_output_tokens = intFieldMaybe(total_usage, "reasoning_output_tokens");
    row.total_total_tokens = intFieldMaybe(total_usage, "total_tokens");

    const last_usage = objectField(info, "last_token_usage");
    row.last_input_tokens = intFieldMaybe(last_usage, "input_tokens");
    row.last_cached_input_tokens = intFieldMaybe(last_usage, "cached_input_tokens");
    row.last_output_tokens = intFieldMaybe(last_usage, "output_tokens");
    row.last_reasoning_output_tokens = intFieldMaybe(last_usage, "reasoning_output_tokens");
    row.last_total_tokens = intFieldMaybe(last_usage, "total_tokens");

    return row;
}

pub fn totalsTuple(row: Row) [token_key_count]?i64 {
    return .{
        row.total_input_tokens,
        row.total_cached_input_tokens,
        row.total_output_tokens,
        row.total_reasoning_output_tokens,
        row.total_total_tokens,
    };
}

fn fieldEq(obj: std.json.ObjectMap, key: []const u8, expected: []const u8) bool {
    const value = stringField(obj, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn objectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |inner| inner,
        else => null,
    };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn intFieldMaybe(obj: ?std.json.ObjectMap, key: []const u8) ?i64 {
    if (obj == null) return null;
    return intField(obj.?, key);
}
