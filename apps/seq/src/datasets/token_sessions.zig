const std = @import("std");
const token_events = @import("token_events.zig");

pub const Row = struct {
    path: []const u8,
    start: ?token_events.SmallText = null,
    end: ?token_events.SmallText = null,
    max_at: ?token_events.SmallText = null,
    day: ?token_events.SmallText = null,
    week: ?token_events.SmallText = null,
    month: ?token_events.SmallText = null,
    total_input_tokens: ?i64 = null,
    total_cached_input_tokens: ?i64 = null,
    total_output_tokens: ?i64 = null,
    total_reasoning_output_tokens: ?i64 = null,
    total_total_tokens: ?i64 = null,
};

pub fn summarizeSession(path: []const u8, events: []const token_events.Row) ?Row {
    var start: ?token_events.SmallText = null;
    var end: ?token_events.SmallText = null;
    var max_at: ?token_events.SmallText = null;
    var day: ?token_events.SmallText = null;
    var week: ?token_events.SmallText = null;
    var month: ?token_events.SmallText = null;
    var max_total_tokens: ?i64 = null;
    var max_totals: ?[token_events.token_key_count]?i64 = null;

    for (events) |event| {
        const total_tokens = event.total_total_tokens orelse continue;

        if (event.timestamp) |timestamp| {
            if (start == null) {
                start = timestamp;
                day = event.day;
                week = event.week;
                month = event.month;
            }
            end = timestamp;
        }

        if (max_total_tokens == null or total_tokens > max_total_tokens.?) {
            max_total_tokens = total_tokens;
            max_totals = token_events.totalsTuple(event);
            max_at = event.timestamp;
        }
    }

    const totals = max_totals orelse return null;
    return .{
        .path = path,
        .start = start,
        .end = end,
        .max_at = max_at,
        .day = day,
        .week = week,
        .month = month,
        .total_input_tokens = totals[token_events.input_idx],
        .total_cached_input_tokens = totals[token_events.cached_input_idx],
        .total_output_tokens = totals[token_events.output_idx],
        .total_reasoning_output_tokens = totals[token_events.reasoning_output_idx],
        .total_total_tokens = totals[token_events.total_idx],
    };
}

pub fn summarizeFromContent(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
) !?Row {
    var events = try token_events.parseTokenEvents(allocator, path, content, false);
    defer events.deinit(allocator);
    return summarizeSession(path, events.items);
}

pub fn summarizeFromFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) !?Row {
    var events = try token_events.parseTokenEventsFile(allocator, path, false);
    defer events.deinit(allocator);
    return summarizeSession(path, events.items);
}
