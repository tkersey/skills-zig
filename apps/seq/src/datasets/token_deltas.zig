const std = @import("std");
const token_events = @import("token_events.zig");

pub const Options = struct {
    include_base: bool = true,
    include_zero: bool = false,
    dedupe: bool = true,
};

pub const Row = struct {
    path: []const u8,
    thread_id: ?token_events.SmallText = null,
    root_session_id: ?token_events.SmallText = null,
    parent_thread_id: ?token_events.SmallText = null,
    model: ?token_events.SmallText = null,
    service_tier: ?token_events.SmallText = null,
    accounting_method: []const u8 = "legacy_adjacent_totals",
    timestamp: ?token_events.SmallText = null,
    day: ?token_events.SmallText = null,
    week: ?token_events.SmallText = null,
    month: ?token_events.SmallText = null,
    segment: u32 = 0,
    model_context_window: ?i64 = null,
    delta_input_tokens: ?i64 = null,
    delta_cached_input_tokens: ?i64 = null,
    delta_output_tokens: ?i64 = null,
    delta_reasoning_output_tokens: ?i64 = null,
    delta_total_tokens: ?i64 = null,
    total_input_tokens: ?i64 = null,
    total_cached_input_tokens: ?i64 = null,
    total_output_tokens: ?i64 = null,
    total_reasoning_output_tokens: ?i64 = null,
    total_total_tokens: ?i64 = null,
};

pub fn buildDeltas(
    allocator: std.mem.Allocator,
    events: []const token_events.Row,
    options: Options,
) !std.ArrayList(Row) {
    var rows = std.ArrayList(Row).empty;
    var segment: u32 = 0;
    var prev_totals: ?[token_events.token_key_count]?i64 = null;
    var prev_total_tokens: ?i64 = null;

    for (events) |event| {
        const totals = token_events.totalsTuple(event);
        const total_tokens = totals[token_events.total_idx] orelse continue;

        if (options.dedupe and prev_total_tokens != null and prev_total_tokens.? == total_tokens) {
            continue;
        }

        var deltas: [token_events.token_key_count]?i64 = .{ null, null, null, null, null };
        var accounting_method: []const u8 = "usage_transition";
        if (event.last_total_tokens != null) {
            deltas = token_events.lastTuple(event);
        } else if (prev_totals) |prev| {
            accounting_method = "legacy_adjacent_totals";
            if (prev_total_tokens != null and total_tokens < prev_total_tokens.?) {
                segment += 1;
                prev_totals = totals;
                prev_total_tokens = total_tokens;
                continue;
            }
            inline for (0..token_events.token_key_count) |idx| {
                const curr = totals[idx];
                const prior = prev[idx];
                if (curr != null and prior != null) {
                    const delta = curr.? - prior.?;
                    if (delta != 0) deltas[idx] = delta;
                }
            }
        } else if (options.include_base) {
            accounting_method = "legacy_adjacent_totals";
            deltas = totals;
        }

        prev_totals = totals;
        prev_total_tokens = total_tokens;

        const delta_total = deltas[token_events.total_idx] orelse 0;
        if (!options.include_zero and delta_total == 0) continue;

        try rows.append(allocator, .{
            .path = event.path,
            .thread_id = event.thread_id,
            .root_session_id = event.root_session_id,
            .parent_thread_id = event.parent_thread_id,
            .model = event.model,
            .service_tier = event.service_tier,
            .accounting_method = accounting_method,
            .timestamp = event.timestamp,
            .day = event.day,
            .week = event.week,
            .month = event.month,
            .segment = segment,
            .model_context_window = event.model_context_window,
            .delta_input_tokens = deltas[token_events.input_idx],
            .delta_cached_input_tokens = deltas[token_events.cached_input_idx],
            .delta_output_tokens = deltas[token_events.output_idx],
            .delta_reasoning_output_tokens = deltas[token_events.reasoning_output_idx],
            .delta_total_tokens = deltas[token_events.total_idx],
            .total_input_tokens = totals[token_events.input_idx],
            .total_cached_input_tokens = totals[token_events.cached_input_idx],
            .total_output_tokens = totals[token_events.output_idx],
            .total_reasoning_output_tokens = totals[token_events.reasoning_output_idx],
            .total_total_tokens = totals[token_events.total_idx],
        });
    }

    return rows;
}

test "legacy reset advances the segment without recounting its base" {
    const content =
        \\{"type":"event_msg","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}}}}
        \\{"type":"event_msg","timestamp":"2026-01-01T00:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":15}}}}
        \\{"type":"event_msg","timestamp":"2026-01-01T00:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":3}}}}
        \\{"type":"event_msg","timestamp":"2026-01-01T00:03:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":8}}}}
    ;

    var events = try token_events.parseTokenEvents(std.testing.allocator, "session.jsonl", content, true);
    defer events.deinit(std.testing.allocator);

    var deltas = try buildDeltas(std.testing.allocator, events.items, .{});
    defer deltas.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), deltas.items.len);
    try std.testing.expectEqual(@as(u32, 0), deltas.items[0].segment);
    try std.testing.expectEqual(@as(i64, 10), deltas.items[0].delta_total_tokens.?);
    try std.testing.expectEqual(@as(u32, 0), deltas.items[1].segment);
    try std.testing.expectEqual(@as(i64, 5), deltas.items[1].delta_total_tokens.?);
    try std.testing.expectEqual(@as(u32, 1), deltas.items[2].segment);
    try std.testing.expectEqual(@as(i64, 5), deltas.items[2].delta_total_tokens.?);
}
