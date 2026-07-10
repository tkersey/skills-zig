const std = @import("std");
const token_events = @import("token_events.zig");
const token_deltas = @import("token_deltas.zig");

pub const Verdict = enum {
    valid,
    estimated,
    invalid,

    pub fn label(self: Verdict) []const u8 {
        return switch (self) {
            .valid => "valid",
            .estimated => "estimated",
            .invalid => "invalid",
        };
    }
};

pub const Audit = struct {
    verdict: Verdict = .valid,
    files_scanned: i64 = 0,
    root_lineages: i64 = 0,
    worker_files: i64 = 0,
    lineage_edges_resolved: i64 = 0,
    missing_parent_threads: i64 = 0,
    lineage_cycles: i64 = 0,
    raw_token_count_events: i64 = 0,
    raw_token_count_info_null_events: i64 = 0,
    raw_token_count_without_total_events: i64 = 0,
    raw_last_total_tokens: i64 = 0,
    owned_transitions: i64 = 0,
    duplicate_emissions_excluded: i64 = 0,
    duplicate_total_nonzero_last_events: i64 = 0,
    duplicate_last_tokens_excluded: i64 = 0,
    conflicting_duplicate_emissions: i64 = 0,
    ancestor_replay_transitions_excluded: i64 = 0,
    sibling_collision_transitions_retained: i64 = 0,
    cross_root_collision_transitions_retained: i64 = 0,
    stream_switches: i64 = 0,
    true_resets: i64 = 0,
    ambiguous_transitions: i64 = 0,
    invalid_transitions: i64 = 0,
    legacy_total_only_events: i64 = 0,
    adjacency_total_tokens: i64 = 0,
    owned_total_tokens: i64 = 0,
    corpus_path_digest: [64]u8 = [_]u8{'0'} ** 64,

    pub fn finalize(self: *Audit) void {
        self.verdict = if (self.invalid_transitions > 0 or self.lineage_cycles > 0)
            .invalid
        else if (self.legacy_total_only_events > 0 or
            self.missing_parent_threads > 0 or
            self.ambiguous_transitions > 0 or
            self.conflicting_duplicate_emissions > 0)
            .estimated
        else
            .valid;
    }

    pub fn auditMinusLastTokens(self: Audit) i64 {
        return self.owned_total_tokens - self.raw_last_total_tokens;
    }

    pub fn legacyInflationTokens(self: Audit) i64 {
        return self.adjacency_total_tokens - self.owned_total_tokens;
    }
};

pub const Projection = struct {
    rows: std.ArrayList(token_deltas.Row) = .empty,
    audit: Audit = .{},

    pub fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
    }
};

const TupleKey = struct {
    mask: u8 = 0,
    values: [token_events.token_key_count]i64 = [_]i64{0} ** token_events.token_key_count,
};

const TransitionKey = struct {
    predecessor: TupleKey,
    total: TupleKey,
};

const Candidate = struct {
    key: TransitionKey,
    event: token_events.Row,
    deltas: [token_events.token_key_count]?i64,
    segment: u32,
    method: []const u8,
};

const Thread = struct {
    path: []const u8,
    trace: token_events.Trace,
    candidates: std.ArrayList(Candidate) = .empty,
    candidate_keys: std.AutoHashMap(TransitionKey, void),

    fn init(allocator: std.mem.Allocator, path: []const u8, trace: token_events.Trace) Thread {
        return .{
            .path = path,
            .trace = trace,
            .candidate_keys = std.AutoHashMap(TransitionKey, void).init(allocator),
        };
    }

    fn deinit(self: *Thread, allocator: std.mem.Allocator) void {
        self.trace.deinit(allocator);
        self.candidates.deinit(allocator);
        self.candidate_keys.deinit();
    }
};

fn tupleKey(values: [token_events.token_key_count]?i64) TupleKey {
    var out = TupleKey{};
    inline for (0..token_events.token_key_count) |idx| {
        if (values[idx]) |value| {
            out.mask |= @as(u8, 1) << @intCast(idx);
            out.values[idx] = value;
        }
    }
    return out;
}

fn zeroTupleLike(value: TupleKey) TupleKey {
    return .{ .mask = value.mask };
}

fn tupleTotal(value: TupleKey) ?i64 {
    const bit = @as(u8, 1) << @intCast(token_events.total_idx);
    if (value.mask & bit == 0) return null;
    return value.values[token_events.total_idx];
}

fn tupleIsZero(value: TupleKey) bool {
    inline for (0..token_events.token_key_count) |idx| {
        const bit = @as(u8, 1) << @intCast(idx);
        if (value.mask & bit != 0 and value.values[idx] != 0) return false;
    }
    return true;
}

fn deriveTransition(
    totals: [token_events.token_key_count]?i64,
    last: [token_events.token_key_count]?i64,
) ?struct { key: TransitionKey, deltas: [token_events.token_key_count]?i64 } {
    if (totals[token_events.total_idx] == null or last[token_events.total_idx] == null) return null;
    var predecessor: [token_events.token_key_count]?i64 = .{null} ** token_events.token_key_count;
    var deltas: [token_events.token_key_count]?i64 = .{null} ** token_events.token_key_count;
    inline for (0..token_events.token_key_count) |idx| {
        if (last[idx] != null and totals[idx] == null) return null;
        if (totals[idx]) |total| {
            if (total < 0) return null;
            if (last[idx]) |delta| {
                if (delta < 0 or delta > total) return null;
                predecessor[idx] = total - delta;
                deltas[idx] = delta;
            }
        }
    }
    return .{
        .key = .{
            .predecessor = tupleKey(predecessor),
            .total = tupleKey(totals),
        },
        .deltas = deltas,
    };
}

fn tupleDelta(current: TupleKey, previous: TupleKey) [token_events.token_key_count]?i64 {
    var out: [token_events.token_key_count]?i64 = .{null} ** token_events.token_key_count;
    inline for (0..token_events.token_key_count) |idx| {
        const bit = @as(u8, 1) << @intCast(idx);
        if (current.mask & bit != 0 and previous.mask & bit != 0) {
            const delta = current.values[idx] - previous.values[idx];
            if (delta != 0) out[idx] = delta;
        }
    }
    return out;
}

fn observeAdjacencyCompatibility(audit: *Audit, event: token_events.Row, previous: *?i64) void {
    const total = event.total_total_tokens orelse return;
    if (previous.*) |prior| {
        if (total == prior) return;
        audit.adjacency_total_tokens += if (total < prior) total else total - prior;
    } else {
        audit.adjacency_total_tokens += total;
    }
    previous.* = total;
}

fn processThreadCandidates(
    allocator: std.mem.Allocator,
    thread: *Thread,
    audit: *Audit,
) !void {
    var seen_totals = std.AutoHashMap(TupleKey, TransitionKey).init(allocator);
    defer seen_totals.deinit();
    var seen_transitions = std.AutoHashMap(TransitionKey, void).init(allocator);
    defer seen_transitions.deinit();

    var last_head: ?TupleKey = null;
    var segment: u32 = 0;
    var adjacency_previous: ?i64 = null;

    for (thread.trace.rows.items) |event| {
        if (event.info_is_null) {
            audit.raw_token_count_info_null_events += 1;
            continue;
        }
        audit.raw_token_count_events += 1;
        observeAdjacencyCompatibility(audit, event, &adjacency_previous);
        if (event.last_total_tokens) |last_total| audit.raw_last_total_tokens += last_total;

        const totals = token_events.totalsTuple(event);
        const total_key = tupleKey(totals);
        if (tupleTotal(total_key) == null) {
            audit.raw_token_count_without_total_events += 1;
            continue;
        }

        if (seen_totals.get(total_key)) |prior_key| {
            audit.duplicate_emissions_excluded += 1;
            if ((event.last_total_tokens orelse 0) != 0) {
                audit.duplicate_total_nonzero_last_events += 1;
                audit.duplicate_last_tokens_excluded += event.last_total_tokens.?;
            }
            if (deriveTransition(totals, token_events.lastTuple(event))) |derived| {
                if (!std.meta.eql(prior_key, derived.key)) audit.conflicting_duplicate_emissions += 1;
            }
            continue;
        }

        if (event.last_total_tokens != null) {
            const derived = deriveTransition(totals, token_events.lastTuple(event)) orelse {
                audit.invalid_transitions += 1;
                continue;
            };
            if (seen_transitions.contains(derived.key)) {
                audit.duplicate_emissions_excluded += 1;
                continue;
            }

            if (tupleIsZero(derived.key.predecessor)) {
                if (last_head != null) {
                    audit.true_resets += 1;
                    segment += 1;
                }
            } else {
                if (seen_totals.contains(derived.key.predecessor)) {
                    if (last_head != null and !std.meta.eql(last_head.?, derived.key.predecessor)) {
                        audit.stream_switches += 1;
                    }
                } else {
                    audit.ambiguous_transitions += 1;
                }
            }

            try thread.candidates.append(allocator, .{
                .key = derived.key,
                .event = event,
                .deltas = derived.deltas,
                .segment = segment,
                .method = "lineage_owned_usage_transition",
            });
            try thread.candidate_keys.put(derived.key, {});
            try seen_transitions.put(derived.key, {});
            try seen_totals.put(total_key, derived.key);
            last_head = total_key;
            continue;
        }

        audit.legacy_total_only_events += 1;
        const previous = last_head;
        if (previous) |prior| {
            const prior_total = tupleTotal(prior) orelse 0;
            const current_total = tupleTotal(total_key).?;
            if (current_total < prior_total) {
                audit.true_resets += 1;
                segment += 1;
                last_head = total_key;
                const reset_key = TransitionKey{ .predecessor = zeroTupleLike(total_key), .total = total_key };
                try seen_totals.put(total_key, reset_key);
                continue;
            }
        }

        const predecessor = if (previous) |prior| prior else zeroTupleLike(total_key);
        const key = TransitionKey{ .predecessor = predecessor, .total = total_key };
        const deltas = if (previous) |prior| tupleDelta(total_key, prior) else totals;
        try thread.candidates.append(allocator, .{
            .key = key,
            .event = event,
            .deltas = deltas,
            .segment = segment,
            .method = "legacy_adjacent_totals",
        });
        try thread.candidate_keys.put(key, {});
        try seen_transitions.put(key, {});
        try seen_totals.put(total_key, key);
        last_head = total_key;
    }
}

fn smallTextSlice(value: *const ?token_events.SmallText) ?[]const u8 {
    if (value.*) |*text| return text.slice();
    return null;
}

fn rootsEqual(lhs: Thread, rhs: Thread) bool {
    const left = smallTextSlice(&lhs.trace.meta.root_session_id) orelse smallTextSlice(&lhs.trace.meta.thread_id) orelse lhs.path;
    const right = smallTextSlice(&rhs.trace.meta.root_session_id) orelse smallTextSlice(&rhs.trace.meta.thread_id) orelse rhs.path;
    return std.mem.eql(u8, left, right);
}

fn ancestorContainsTransition(
    threads: []const Thread,
    id_map: *const std.StringHashMap(usize),
    start_index: usize,
    key: TransitionKey,
) bool {
    var current_index = start_index;
    var steps: usize = 0;
    while (steps <= threads.len) : (steps += 1) {
        const current = threads[current_index];
        var next_index: ?usize = null;
        if (smallTextSlice(&current.trace.meta.parent_thread_id)) |parent_id| {
            next_index = id_map.get(parent_id);
        }
        if (next_index == null) {
            if (smallTextSlice(&current.trace.meta.root_session_id)) |root_id| {
                const root_index = id_map.get(root_id);
                if (root_index != null and root_index.? != current_index) next_index = root_index;
            }
        }
        const ancestor_index = next_index orelse return false;
        if (threads[ancestor_index].candidate_keys.contains(key)) return true;
        current_index = ancestor_index;
    }
    return false;
}

fn lineageHasCycle(
    threads: []const Thread,
    id_map: *const std.StringHashMap(usize),
    start_index: usize,
) bool {
    var current_index = start_index;
    var steps: usize = 0;
    while (steps <= threads.len) : (steps += 1) {
        const parent_id = smallTextSlice(&threads[current_index].trace.meta.parent_thread_id) orelse return false;
        current_index = id_map.get(parent_id) orelse return false;
    }
    return true;
}

fn appendOwnedRow(
    allocator: std.mem.Allocator,
    projection: *Projection,
    thread: Thread,
    candidate: Candidate,
) !void {
    const delta_total = candidate.deltas[token_events.total_idx] orelse 0;
    if (delta_total == 0) return;
    const event = candidate.event;
    try projection.rows.append(allocator, .{
        .path = event.path,
        .thread_id = thread.trace.meta.thread_id,
        .root_session_id = thread.trace.meta.root_session_id,
        .parent_thread_id = thread.trace.meta.parent_thread_id,
        .model = event.model,
        .service_tier = event.service_tier,
        .accounting_method = candidate.method,
        .timestamp = event.timestamp,
        .day = event.day,
        .week = event.week,
        .month = event.month,
        .segment = candidate.segment,
        .model_context_window = event.model_context_window,
        .delta_input_tokens = candidate.deltas[token_events.input_idx],
        .delta_cached_input_tokens = candidate.deltas[token_events.cached_input_idx],
        .delta_output_tokens = candidate.deltas[token_events.output_idx],
        .delta_reasoning_output_tokens = candidate.deltas[token_events.reasoning_output_idx],
        .delta_total_tokens = candidate.deltas[token_events.total_idx],
        .total_input_tokens = event.total_input_tokens,
        .total_cached_input_tokens = event.total_cached_input_tokens,
        .total_output_tokens = event.total_output_tokens,
        .total_reasoning_output_tokens = event.total_reasoning_output_tokens,
        .total_total_tokens = event.total_total_tokens,
    });
    projection.audit.owned_transitions += 1;
    projection.audit.owned_total_tokens += delta_total;
}

fn pathLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn setCorpusPathDigest(allocator: std.mem.Allocator, audit: *Audit, paths: []const []const u8) !void {
    const sorted = try allocator.dupe([]const u8, paths);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, pathLessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (sorted) |path| {
        hasher.update(path);
        hasher.update(&.{0});
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    audit.corpus_path_digest = std.fmt.bytesToHex(digest, .lower);
}

pub fn buildProjectionFromPaths(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) !Projection {
    var projection = Projection{};
    errdefer projection.deinit(allocator);
    try setCorpusPathDigest(allocator, &projection.audit, paths);

    var threads: std.ArrayList(Thread) = .empty;
    defer {
        for (threads.items) |*thread| thread.deinit(allocator);
        threads.deinit(allocator);
    }

    for (paths) |path| {
        const trace = try token_events.parseTokenTraceFileWithOptions(allocator, path, .{
            .dedupe = false,
            .derive_timestamp_fields = true,
            .include_null_info = true,
        });
        try threads.append(allocator, Thread.init(allocator, path, trace));
    }
    projection.audit.files_scanned = @intCast(threads.items.len);

    for (threads.items) |*thread| try processThreadCandidates(allocator, thread, &projection.audit);

    var id_map: std.StringHashMap(usize) = .init(allocator);
    defer id_map.deinit();
    var roots: std.StringHashMap(void) = .init(allocator);
    defer roots.deinit();
    for (threads.items, 0..) |*thread, index| {
        if (smallTextSlice(&thread.trace.meta.thread_id)) |thread_id| {
            if (id_map.contains(thread_id)) {
                projection.audit.invalid_transitions += 1;
            } else {
                try id_map.put(thread_id, index);
            }
        }
        const root = smallTextSlice(&thread.trace.meta.root_session_id) orelse
            smallTextSlice(&thread.trace.meta.thread_id) orelse
            thread.path;
        try roots.put(root, {});
    }
    projection.audit.root_lineages = @intCast(roots.count());

    for (threads.items, 0..) |thread, index| {
        if (smallTextSlice(&thread.trace.meta.parent_thread_id)) |parent_id| {
            projection.audit.worker_files += 1;
            if (id_map.contains(parent_id)) {
                projection.audit.lineage_edges_resolved += 1;
            } else {
                projection.audit.missing_parent_threads += 1;
            }
        }
        if (lineageHasCycle(threads.items, &id_map, index)) projection.audit.lineage_cycles += 1;
    }

    var first_owner = std.AutoHashMap(TransitionKey, usize).init(allocator);
    defer first_owner.deinit();
    for (threads.items, 0..) |thread, thread_index| {
        for (thread.candidates.items) |candidate| {
            if (ancestorContainsTransition(threads.items, &id_map, thread_index, candidate.key)) {
                projection.audit.ancestor_replay_transitions_excluded += 1;
                continue;
            }
            if (first_owner.get(candidate.key)) |prior_index| {
                if (rootsEqual(thread, threads.items[prior_index])) {
                    projection.audit.sibling_collision_transitions_retained += 1;
                } else {
                    projection.audit.cross_root_collision_transitions_retained += 1;
                }
            } else {
                try first_owner.put(candidate.key, thread_index);
            }
            try appendOwnedRow(allocator, &projection, thread, candidate);
        }
    }

    projection.audit.finalize();
    return projection;
}

pub fn buildProjectionForSelection(
    allocator: std.mem.Allocator,
    selected_paths: []const []const u8,
    corpus_paths: []const []const u8,
) !Projection {
    var included: std.StringHashMap(void) = .init(allocator);
    defer included.deinit();
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(allocator);

    for (selected_paths) |path| {
        if (!included.contains(path)) {
            try included.put(path, {});
            try frontier.append(allocator, path);
        }
    }

    var cursor: usize = 0;
    while (cursor < frontier.items.len) : (cursor += 1) {
        const path = frontier.items[cursor];
        const meta = try token_events.parseTraceMetaFile(allocator, path);
        var ancestor_id = smallTextSlice(&meta.parent_thread_id);
        if (ancestor_id == null) {
            const thread_id = smallTextSlice(&meta.thread_id);
            const root_id = smallTextSlice(&meta.root_session_id);
            if (root_id != null and (thread_id == null or !std.mem.eql(u8, root_id.?, thread_id.?))) ancestor_id = root_id;
        }
        if (ancestor_id) |id| {
            for (corpus_paths) |candidate_path| {
                if (std.mem.indexOf(u8, std.fs.path.basename(candidate_path), id) == null) continue;
                if (!included.contains(candidate_path)) {
                    try included.put(candidate_path, {});
                    try frontier.append(allocator, candidate_path);
                }
                break;
            }
        }
    }
    return buildProjectionFromPaths(allocator, frontier.items);
}

test "lineage ownership excludes replay and retains identical sibling transitions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    const parent =
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"parent\",\"session_id\":\"parent\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":8,\"cached_input_tokens\":2,\"output_tokens\":2,\"reasoning_output_tokens\":0,\"total_tokens\":10},\"last_token_usage\":{\"input_tokens\":8,\"cached_input_tokens\":2,\"output_tokens\":2,\"reasoning_output_tokens\":0,\"total_tokens\":10}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:01:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":16,\"cached_input_tokens\":4,\"output_tokens\":4,\"reasoning_output_tokens\":0,\"total_tokens\":20},\"last_token_usage\":{\"input_tokens\":8,\"cached_input_tokens\":2,\"output_tokens\":2,\"reasoning_output_tokens\":0,\"total_tokens\":10}}}}\n";
    const child_template =
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"CHILD\",\"session_id\":\"parent\",\"parent_thread_id\":\"parent\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:02:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":8,\"cached_input_tokens\":2,\"output_tokens\":2,\"reasoning_output_tokens\":0,\"total_tokens\":10},\"last_token_usage\":{\"input_tokens\":8,\"cached_input_tokens\":2,\"output_tokens\":2,\"reasoning_output_tokens\":0,\"total_tokens\":10}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:02:01Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":16,\"cached_input_tokens\":4,\"output_tokens\":4,\"reasoning_output_tokens\":0,\"total_tokens\":20},\"last_token_usage\":{\"input_tokens\":8,\"cached_input_tokens\":2,\"output_tokens\":2,\"reasoning_output_tokens\":0,\"total_tokens\":10}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:03:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":20,\"cached_input_tokens\":5,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":25},\"last_token_usage\":{\"input_tokens\":4,\"cached_input_tokens\":1,\"output_tokens\":1,\"reasoning_output_tokens\":0,\"total_tokens\":5}}}}\n";

    try tmp.dir.writeFile(io, .{ .sub_path = "parent.jsonl", .data = parent });
    const child_a = try std.mem.replaceOwned(u8, std.testing.allocator, child_template, "CHILD", "child-a");
    defer std.testing.allocator.free(child_a);
    const child_b = try std.mem.replaceOwned(u8, std.testing.allocator, child_template, "CHILD", "child-b");
    defer std.testing.allocator.free(child_b);
    try tmp.dir.writeFile(io, .{ .sub_path = "child-a.jsonl", .data = child_a });
    try tmp.dir.writeFile(io, .{ .sub_path = "child-b.jsonl", .data = child_b });

    const parent_path = try tmp.dir.realPathFileAlloc(io, "parent.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(parent_path);
    const child_a_path = try tmp.dir.realPathFileAlloc(io, "child-a.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(child_a_path);
    const child_b_path = try tmp.dir.realPathFileAlloc(io, "child-b.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(child_b_path);
    const paths = [_][]const u8{ parent_path, child_a_path, child_b_path };

    var projection = try buildProjectionFromPaths(std.testing.allocator, paths[0..]);
    defer projection.deinit(std.testing.allocator);
    try std.testing.expectEqual(Verdict.valid, projection.audit.verdict);
    try std.testing.expectEqual(@as(i64, 30), projection.audit.owned_total_tokens);
    try std.testing.expectEqual(@as(i64, 4), projection.audit.ancestor_replay_transitions_excluded);
    try std.testing.expectEqual(@as(i64, 1), projection.audit.sibling_collision_transitions_retained);
    try std.testing.expectEqual(@as(usize, 4), projection.rows.items.len);
}

test "modern interleaved lanes use predecessor transitions instead of reset bases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const content =
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"root\",\"session_id\":\"root\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":100},\"last_token_usage\":{\"total_tokens\":100}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:01:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":120},\"last_token_usage\":{\"total_tokens\":20}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:02:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":110},\"last_token_usage\":{\"total_tokens\":10}}}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:03:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":130},\"last_token_usage\":{\"total_tokens\":10}}}}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "interleaved.jsonl", .data = content });
    const path = try tmp.dir.realPathFileAlloc(io, "interleaved.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const paths = [_][]const u8{path};
    var projection = try buildProjectionFromPaths(std.testing.allocator, paths[0..]);
    defer projection.deinit(std.testing.allocator);

    try std.testing.expectEqual(Verdict.valid, projection.audit.verdict);
    try std.testing.expectEqual(@as(i64, 140), projection.audit.owned_total_tokens);
    try std.testing.expectEqual(@as(i64, 2), projection.audit.stream_switches);
    try std.testing.expectEqual(@as(i64, 0), projection.audit.true_resets);
    try std.testing.expectEqual(@as(i64, 0), projection.audit.ambiguous_transitions);
}

test "invalid modern transition fails the accounting verdict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const content =
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"root\",\"session_id\":\"root\"}}\n" ++
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-10T00:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":5},\"last_token_usage\":{\"total_tokens\":7}}}}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "invalid.jsonl", .data = content });
    const path = try tmp.dir.realPathFileAlloc(io, "invalid.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const paths = [_][]const u8{path};
    var projection = try buildProjectionFromPaths(std.testing.allocator, paths[0..]);
    defer projection.deinit(std.testing.allocator);
    try std.testing.expectEqual(Verdict.invalid, projection.audit.verdict);
    try std.testing.expectEqual(@as(usize, 0), projection.rows.items.len);
}
