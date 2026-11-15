const std = @import("std");
const parser = @import("claude_parser.zig");
const core = @import("root.zig");

const Record = parser.Record;
const TurnStatus = core.TurnStatus;

pub const TurnPlan = struct {
    anchor: u32,
    fallback: bool,
};

pub const Graph = struct {
    modeled: []bool,
    parent: []?u32,
    bridged: []bool,
    owner: []?u32,
    turns: []TurnPlan,
    active_leaf: ?u32,
    active_turn: ?u32,
    on_active: []bool,
    active_chain: []u32,
    duplicate_uuid_lines: []usize,
    missing_uuid_lines: []usize,
    inline_sidechain_records: usize,
};

pub fn build(
    arena: std.mem.Allocator,
    records: []const Record,
    standalone_worker: bool,
) !Graph {
    const count = records.len;
    var graph = Graph{
        .modeled = try arena.alloc(bool, count),
        .parent = try arena.alloc(?u32, count),
        .bridged = try arena.alloc(bool, count),
        .owner = try arena.alloc(?u32, count),
        .turns = &.{},
        .active_leaf = null,
        .active_turn = null,
        .on_active = try arena.alloc(bool, count),
        .active_chain = &.{},
        .duplicate_uuid_lines = &.{},
        .missing_uuid_lines = &.{},
        .inline_sidechain_records = 0,
    };
    @memset(graph.bridged, false);
    @memset(graph.on_active, false);
    @memset(graph.owner, null);
    for (records, 0..) |record, index| {
        const conversation = record.kind.isConversation();
        const inline_sidechain = conversation and record.sidechain and !standalone_worker;
        graph.modeled[index] = conversation and !inline_sidechain;
        if (inline_sidechain) graph.inline_sidechain_records += 1;
    }
    var uuids = try indexUuids(arena, records, &graph);
    defer uuids.deinit(arena);
    resolveParents(records, &graph, &uuids);
    try assignTurns(arena, records, &graph);
    try markActive(arena, &graph);
    return graph;
}

fn indexUuids(
    arena: std.mem.Allocator,
    records: []const Record,
    graph: *Graph,
) !std.StringHashMapUnmanaged(u32) {
    var uuids: std.StringHashMapUnmanaged(u32) = .empty;
    var duplicates: std.ArrayList(usize) = .empty;
    var missing: std.ArrayList(usize) = .empty;
    for (records, 0..) |record, index| {
        if (!record.kind.isConversation()) continue;
        const uuid = record.uuid orelse {
            try missing.append(arena, record.line);
            continue;
        };
        if (!graph.modeled[index]) continue;
        const entry = try uuids.getOrPut(arena, uuid);
        if (entry.found_existing) {
            try duplicates.append(arena, record.line);
        } else {
            entry.value_ptr.* = @intCast(index);
        }
    }
    graph.duplicate_uuid_lines = duplicates.items;
    graph.missing_uuid_lines = missing.items;
    return uuids;
}

fn resolveParents(
    records: []const Record,
    graph: *Graph,
    uuids: *const std.StringHashMapUnmanaged(u32),
) void {
    for (records, 0..) |record, index| {
        graph.parent[index] = null;
        if (!graph.modeled[index]) continue;
        if (record.parent) |parent_uuid| {
            graph.parent[index] = earlier(uuids, parent_uuid, index);
            continue;
        }
        if (!record.isCompactBoundary()) continue;
        const logical = record.logical_parent orelse continue;
        graph.parent[index] = earlier(uuids, logical, index);
        graph.bridged[index] = graph.parent[index] != null;
    }
}

fn earlier(uuids: *const std.StringHashMapUnmanaged(u32), uuid: []const u8, index: usize) ?u32 {
    const found = uuids.get(uuid) orelse return null;
    return if (found < index) found else null;
}

fn assignTurns(arena: std.mem.Allocator, records: []const Record, graph: *Graph) !void {
    const count = records.len;
    const nearest_input = try arena.alloc(?u32, count);
    const chain_root = try arena.alloc(u32, count);
    const opening = try arena.alloc(bool, count);
    @memset(opening, false);
    for (records, 0..) |record, index| {
        const position: u32 = @intCast(index);
        nearest_input[index] = null;
        chain_root[index] = position;
        if (!graph.modeled[index]) continue;
        if (record.isInput() and record.origin != null) opening[index] = true;
        const parent = graph.parent[index] orelse continue;
        chain_root[index] = chain_root[parent];
        nearest_input[index] = if (records[parent].isInput()) parent else nearest_input[parent];
    }
    for (records, 0..) |record, index| {
        if (!graph.modeled[index] or !record.isReply()) continue;
        if (nearest_input[index]) |input| opening[input] = true;
    }
    const anchors = try arena.alloc(bool, count);
    @memset(anchors, false);
    const open_owner = try arena.alloc(?u32, count);
    for (records, 0..) |record, index| {
        open_owner[index] = null;
        if (!graph.modeled[index]) continue;
        open_owner[index] = if (opening[index])
            @intCast(index)
        else if (graph.parent[index]) |parent| open_owner[parent] else null;
        const orphan_reply = record.isModelResponse() or record.api_error;
        if (orphan_reply and open_owner[index] == null) anchors[chain_root[index]] = true;
    }
    var turns: std.ArrayList(TurnPlan) = .empty;
    for (records, 0..) |_, index| {
        if (!graph.modeled[index]) continue;
        if (opening[index] or anchors[index]) {
            graph.owner[index] = @intCast(turns.items.len);
            try turns.append(arena, .{ .anchor = @intCast(index), .fallback = !opening[index] });
        } else if (graph.parent[index]) |parent| {
            graph.owner[index] = graph.owner[parent];
        }
    }
    graph.turns = turns.items;
}

fn markActive(arena: std.mem.Allocator, graph: *Graph) !void {
    var leaf: ?u32 = null;
    for (graph.modeled, 0..) |modeled, index| {
        if (modeled) leaf = @intCast(index);
    }
    graph.active_leaf = leaf;
    var chain: std.ArrayList(u32) = .empty;
    var cursor = leaf;
    while (cursor) |index| {
        graph.on_active[index] = true;
        try chain.append(arena, index);
        cursor = graph.parent[index];
    }
    std.mem.reverse(u32, chain.items);
    graph.active_chain = chain.items;
    if (leaf) |index| graph.active_turn = graph.owner[index];
}

pub const Freshness = struct {
    fresh: bool,
    request_in_flight: bool,
};

pub const Outcome = struct {
    status: TurnStatus = .ongoing,
    reason: []const u8 = "",
    completed_at: ?[]const u8 = null,
    duration_ms: ?i64 = null,
    error_text: ?[]const u8 = null,
    aborted_reason: ?[]const u8 = null,
    final_answer: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    has_compaction: bool = false,
};

pub const TurnIndex = struct {
    owned: [][]u32,
    paths: [][]u32,
};

pub fn indexTurns(arena: std.mem.Allocator, graph: *const Graph) !TurnIndex {
    const turn_count = graph.turns.len;
    var owned_lists = try arena.alloc(std.ArrayList(u32), turn_count);
    for (owned_lists) |*list| list.* = .empty;
    for (graph.owner, 0..) |owner, index| {
        const turn = owner orelse continue;
        try owned_lists[turn].append(arena, @intCast(index));
    }
    const owned = try arena.alloc([]u32, turn_count);
    for (owned_lists, 0..) |list, turn| owned[turn] = list.items;
    const paths = try arena.alloc([]u32, turn_count);
    for (graph.turns, 0..) |plan, turn| {
        paths[turn] = try selectedPath(arena, graph, plan, @intCast(turn), owned[turn]);
    }
    return .{ .owned = owned, .paths = paths };
}

fn selectedPath(
    arena: std.mem.Allocator,
    graph: *const Graph,
    plan: TurnPlan,
    turn: u32,
    owned: []const u32,
) ![]u32 {
    var path: std.ArrayList(u32) = .empty;
    if (graph.on_active[plan.anchor]) {
        for (graph.active_chain) |index| {
            if (graph.owner[index] == turn) try path.append(arena, index);
        }
        return path.items;
    }
    var cursor: ?u32 = owned[owned.len - 1];
    while (cursor) |index| {
        try path.append(arena, index);
        if (index == plan.anchor) break;
        cursor = graph.parent[index];
    }
    std.mem.reverse(u32, path.items);
    return path.items;
}

const Evidence = struct {
    last_response: ?u32 = null,
    message_lines: []const u32 = &.{},
    after: []const u32 = &.{},
    re_query_after: ?u32 = null,
};

pub fn evaluate(
    arena: std.mem.Allocator,
    records: []const Record,
    graph: *const Graph,
    index: *const TurnIndex,
    turn: u32,
    freshness: Freshness,
) !Outcome {
    const path = index.paths[turn];
    const owned = index.owned[turn];
    const active = graph.active_turn == turn;
    const in_flight = active and freshness.request_in_flight;
    const evidence = try gatherEvidence(arena, records, path, in_flight);
    var outcome = Outcome{};
    if (evidence.last_response) |last| {
        outcome.model = records[last].model;
        outcome.effort = records[last].effort;
    }
    for (owned) |position| {
        const record = records[position];
        if (record.isTurnDuration()) outcome.duration_ms = record.duration_ms;
        if (record.isCompactBoundary() and graph.bridged[position]) outcome.has_compaction = true;
    }
    const decision = try decide(arena, records, owned, evidence);
    if (decision) |decided| {
        outcome.status = decided.status;
        outcome.reason = decided.reason;
        outcome.completed_at = completedAt(records, owned, decided.record);
        outcome.error_text = decided.error_text;
        outcome.aborted_reason = decided.aborted_reason;
        outcome.final_answer = try answerFor(arena, records, path, owned, evidence, decided);
        return outcome;
    }
    outcome.final_answer = try lastTextAnswer(arena, records, path);
    const anchor = graph.turns[turn].anchor;
    if (active) {
        outcome.status = if (freshness.fresh) .ongoing else .aborted;
        outcome.reason = if (freshness.fresh) "fresh_ongoing_turn" else "stale_ongoing_file";
    } else {
        outcome.status = .aborted;
        outcome.reason = if (graph.on_active[anchor])
            "claude_superseded"
        else
            "claude_inactive_branch";
    }
    return outcome;
}

fn gatherEvidence(
    arena: std.mem.Allocator,
    records: []const Record,
    path: []const u32,
    request_in_flight: bool,
) !Evidence {
    var evidence = Evidence{ .after = path };
    var position = path.len;
    while (position > 0) {
        position -= 1;
        if (records[path[position]].isModelResponse()) {
            evidence.last_response = path[position];
            evidence.after = path[position + 1 ..];
            break;
        }
    }
    if (evidence.last_response) |last| {
        evidence.message_lines = try messageLines(arena, records, path, last);
    }
    for (evidence.after) |candidate| {
        const record = records[candidate];
        if (record.isRetryNotice() or record.isReQueryPrompt()) evidence.re_query_after = candidate;
    }
    if (request_in_flight) evidence.re_query_after = std.math.maxInt(u32);
    return evidence;
}

fn messageLines(
    arena: std.mem.Allocator,
    records: []const Record,
    path: []const u32,
    last: u32,
) ![]const u32 {
    const id = records[last].message_id.present() orelse {
        const single = try arena.alloc(u32, 1);
        single[0] = last;
        return single;
    };
    var lines: std.ArrayList(u32) = .empty;
    for (path) |position| {
        const record = records[position];
        if (!record.isModelResponse()) continue;
        if (parser.eql(record.message_id.present(), id)) try lines.append(arena, position);
    }
    return lines.items;
}

const Decision = struct {
    status: TurnStatus,
    reason: []const u8,
    record: u32,
    error_text: ?[]const u8 = null,
    aborted_reason: ?[]const u8 = null,
    ending_call: ?[]const u8 = null,
    by_response: bool = false,
};

fn decide(
    arena: std.mem.Allocator,
    records: []const Record,
    owned: []const u32,
    evidence: Evidence,
) !?Decision {
    const floor = evidence.re_query_after;
    if (lastAfter(records, evidence.after, floor, isInterruption)) |found| {
        return .{
            .status = .aborted,
            .reason = "claude_interrupted",
            .record = found,
            .aborted_reason = records[found].text,
        };
    }
    if (lastAfter(records, evidence.after, floor, isApiError)) |found| {
        return .{
            .status = .@"error",
            .reason = "claude_api_error",
            .record = found,
            .error_text = records[found].text,
        };
    }
    if (endingResult(records, owned, evidence, floor)) |ending| {
        return .{
            .status = .complete,
            .reason = "claude_tool_ended_turn",
            .record = ending.record,
            .ending_call = ending.call_id,
        };
    }
    if (lastAfter(records, evidence.after, floor, isTurnLimit)) |found| {
        return .{ .status = .aborted, .reason = "claude_max_turns_reached", .record = found };
    }
    if (floor != null) return null;
    const last = evidence.last_response orelse return null;
    const response = records[last];
    if (response.stop.recorded()) |stop| {
        if (declaresCall(records, evidence.message_lines)) return null;
        if (parser.oneOf(stop, &.{ "tool_use", "pause_turn", "compaction" })) return null;
        const reason = try std.fmt.allocPrint(arena, "claude_{s}", .{stop});
        return .{ .status = .complete, .reason = reason, .record = last, .by_response = true };
    }
    const legacy_text_end = response.hasText() and
        (response.stop == .absent or response.stop == .null_value);
    if (!legacy_text_end) return null;
    return .{
        .status = .complete,
        .reason = "claude_text_end",
        .record = last,
        .by_response = true,
    };
}

fn isInterruption(record: Record) bool {
    return record.interruption;
}

fn isApiError(record: Record) bool {
    return record.api_error;
}

fn isTurnLimit(record: Record) bool {
    return record.kind == .attachment and parser.eql(record.subtype, "max_turns_reached");
}

fn lastAfter(
    records: []const Record,
    candidates: []const u32,
    floor: ?u32,
    comptime predicate: fn (Record) bool,
) ?u32 {
    var found: ?u32 = null;
    for (candidates) |position| {
        if (floor) |limit| if (position <= limit) continue;
        if (predicate(records[position])) found = position;
    }
    return found;
}

fn declaresCall(records: []const Record, lines: []const u32) bool {
    for (lines) |position| {
        for (records[position].blocks) |block| if (block.kind == .tool_use) return true;
    }
    return false;
}

fn declaredCall(records: []const Record, lines: []const u32, call_id: []const u8) ?parser.Block {
    for (lines) |position| {
        for (records[position].blocks) |block| {
            if (block.kind == .tool_use and parser.eql(block.call_id, call_id)) return block;
        }
    }
    return null;
}

const Ending = struct { record: u32, call_id: []const u8 };

fn endingResult(
    records: []const Record,
    owned: []const u32,
    evidence: Evidence,
    floor: ?u32,
) ?Ending {
    if (evidence.last_response == null) return null;
    var found: ?Ending = null;
    for (owned) |position| {
        if (floor) |limit| if (position <= limit) continue;
        for (records[position].results) |result| {
            if (!result.ends_turn) continue;
            if (declaredCall(records, evidence.message_lines, result.call_id) == null) continue;
            found = .{ .record = position, .call_id = result.call_id };
        }
    }
    return found;
}

fn completedAt(records: []const Record, owned: []const u32, deciding: u32) ?[]const u8 {
    var completed = records[deciding].timestamp;
    for (owned) |position| {
        if (position > deciding and records[position].isTurnDuration()) {
            completed = records[position].timestamp;
        }
    }
    return completed;
}

fn answerFor(
    arena: std.mem.Allocator,
    records: []const Record,
    path: []const u32,
    owned: []const u32,
    evidence: Evidence,
    decision: Decision,
) !?[]const u8 {
    if (decision.ending_call) |call_id| {
        for (owned) |position| {
            const record = records[position];
            if (record.kind != .attachment or !parser.eql(record.subtype, "structured_output")) {
                continue;
            }
            if (!parser.eql(record.call_ref, call_id)) continue;
            const block = declaredCall(records, evidence.message_lines, call_id) orelse return null;
            return block.input_json;
        }
        return null;
    }
    if (decision.by_response) return assemble(arena, records, evidence.message_lines);
    return lastTextAnswer(arena, records, path);
}

fn lastTextAnswer(
    arena: std.mem.Allocator,
    records: []const Record,
    path: []const u32,
) !?[]const u8 {
    var position = path.len;
    while (position > 0) {
        position -= 1;
        const record = records[path[position]];
        if (!record.isModelResponse() or !record.hasText()) continue;
        const lines = try messageLines(arena, records, path, path[position]);
        return assemble(arena, records, lines);
    }
    return null;
}

const Keyed = struct { key: ?i64, block: parser.Block };

pub fn assemble(
    arena: std.mem.Allocator,
    records: []const Record,
    lines: []const u32,
) !?[]const u8 {
    var entries: std.ArrayList(Keyed) = .empty;
    var all_keyed = true;
    for (lines) |position| {
        const record = records[position];
        if (record.block_index) |key| {
            if (record.blocks.len != 1) return null;
            try entries.append(arena, .{ .key = key, .block = record.blocks[0] });
        } else {
            all_keyed = false;
            for (record.blocks) |block| try entries.append(arena, .{ .key = null, .block = block });
        }
    }
    if (all_keyed) {
        std.mem.sort(Keyed, entries.items, {}, lessKey);
        if (conflicting(entries.items)) return null;
    }
    var text: std.ArrayList(u8) = .empty;
    var found = false;
    var previous_key: ?i64 = null;
    for (entries.items, 0..) |entry, position| {
        if (all_keyed and position > 0 and entry.key == previous_key) continue;
        previous_key = entry.key;
        if (entry.block.kind != .text) continue;
        try text.appendSlice(arena, entry.block.text);
        found = true;
    }
    return if (found) text.items else null;
}

fn lessKey(_: void, left: Keyed, right: Keyed) bool {
    return left.key.? < right.key.?;
}

fn conflicting(entries: []const Keyed) bool {
    for (entries[0..entries.len -| 1], 0..) |entry, position| {
        const next = entries[position + 1];
        if (entry.key != next.key) continue;
        if (entry.block.kind != next.block.kind) return true;
        if (!std.mem.eql(u8, entry.block.text, next.block.text)) return true;
        if (!std.meta.eql(entry.block.call_id != null, next.block.call_id != null)) return true;
        if (entry.block.call_id) |id| if (!std.mem.eql(u8, id, next.block.call_id.?)) return true;
    }
    return false;
}
