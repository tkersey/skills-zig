const std = @import("std");
const definition_core = @import("definition_core");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const projection_value = @import("projection_value.zig");
const protocol = @import("protocol.zig");
const ranked_relevance = @import("ranked_relevance.zig");
const reducer = @import("reducer.zig");
const replay = @import("replay.zig");
const state_reducer = @import("state_reducer.zig");
const storage = @import("storage.zig");

const Scalar = union(enum) {
    string: []u8,
    number: []u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null,

    fn deinit(self: *Scalar, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |value| allocator.free(value),
            .number => |value| allocator.free(value),
            else => {},
        }
        self.* = undefined;
    }
};

const SortedRow = struct {
    payload: []u8,
    keys: []Scalar,
    record_index: usize,
    row_id: ?[]u8,
    theme: ?[]u8,

    fn deinit(self: *SortedRow, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        for (self.keys) |*key| key.deinit(allocator);
        allocator.free(self.keys);
        if (self.row_id) |value| allocator.free(value);
        if (self.theme) |value| allocator.free(value);
        self.* = undefined;
    }
};

const Operand = union(enum) {
    constant: Scalar,
    parameter: []u8,

    fn deinit(self: *Operand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .constant => |*value| value.deinit(allocator),
            .parameter => |name| allocator.free(name),
        }
        self.* = undefined;
    }
};

const Predicate = struct {
    pointer: definition_core.json_pointer.Pointer,
    operand: Operand,

    fn deinit(self: *Predicate, allocator: std.mem.Allocator) void {
        self.pointer.deinit(allocator);
        self.operand.deinit(allocator);
        self.* = undefined;
    }
};

const PredicateSet = struct {
    predicates: []Predicate,

    fn deinit(self: *PredicateSet, allocator: std.mem.Allocator) void {
        for (self.predicates) |*predicate| predicate.deinit(allocator);
        allocator.free(self.predicates);
        self.* = undefined;
    }
};

const PredicateGroup = union(enum) {
    one: Predicate,
    any: []PredicateSet,

    fn deinit(self: *PredicateGroup, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .one => |*predicate| predicate.deinit(allocator),
            .any => |sets| {
                for (sets) |*set| set.deinit(allocator);
                allocator.free(sets);
            },
        }
        self.* = undefined;
    }
};

const Field = struct {
    name: []u8,
    pointer: definition_core.json_pointer.Pointer,

    fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.pointer.deinit(allocator);
        self.* = undefined;
    }
};

const Limit = union(enum) {
    fixed: usize,
    parameter: []u8,

    fn deinit(self: *Limit, allocator: std.mem.Allocator) void {
        if (self.* == .parameter) allocator.free(self.parameter);
        self.* = undefined;
    }
};

const SortOrder = enum {
    ascending,
    descending,
};

const SortSource = union(enum) {
    pointer: definition_core.json_pointer.Pointer,
    record_order,
    relevance_score,
};

const SortKey = struct {
    source: SortSource,
    order: SortOrder,

    fn deinit(self: *SortKey, allocator: std.mem.Allocator) void {
        if (self.source == .pointer) {
            self.source.pointer.deinit(allocator);
        }
        self.* = undefined;
    }
};

const RelevanceMode = enum {
    literal,
    tokens,
    ranked_tokens,
};

const Relevance = struct {
    paths: []definition_core.json_pointer.Pointer,
    parameter: []u8,
    mode: RelevanceMode,
    score_field: ?[]u8,
    ranked_plan: ?ranked_relevance.Plan,

    fn deinit(self: *Relevance, allocator: std.mem.Allocator) void {
        for (self.paths) |*path| path.deinit(allocator);
        allocator.free(self.paths);
        allocator.free(self.parameter);
        if (self.score_field) |field| allocator.free(field);
        if (self.ranked_plan) |*plan| plan.deinit(allocator);
        self.* = undefined;
    }
};

const PreparedRelevance = union(enum) {
    basic: []u8,
    ranked: ranked_relevance.Prepared,

    fn deinit(
        self: *PreparedRelevance,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.*) {
            .basic => |bytes| allocator.free(bytes),
            .ranked => |*prepared| prepared.deinit(allocator),
        }
        self.* = undefined;
    }
};

const max_fold_digest_fragments: usize = 32;
const max_fold_digest_literal_bytes: usize = 4096;
const max_fold_event_kind_counts: usize = 32;

const FoldDigestSource = enum {
    previous_event_chain,
    event_bytes,
    key,
    state,
    retained,
    event_chain,
};

const FoldDigestFragment = union(enum) {
    literal: []u8,
    source: FoldDigestSource,
    retained_text: definition_core.json_pointer.Pointer,

    fn deinit(
        self: *FoldDigestFragment,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.*) {
            .literal => |bytes| allocator.free(bytes),
            .retained_text => |*pointer| pointer.deinit(allocator),
            .source => {},
        }
        self.* = undefined;
    }
};

const FoldDigest = struct {
    fragments: []FoldDigestFragment,

    fn deinit(self: *FoldDigest, allocator: std.mem.Allocator) void {
        for (self.fragments) |*fragment| fragment.deinit(allocator);
        allocator.free(self.fragments);
        self.* = undefined;
    }
};

const FoldEventKindCount = struct {
    kind: []u8,
    field: []u8,

    fn deinit(
        self: *FoldEventKindCount,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.kind);
        allocator.free(self.field);
        self.* = undefined;
    }
};

const FoldEventChain = struct {
    field: []u8,
    digest: FoldDigest,

    fn deinit(self: *FoldEventChain, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        self.digest.deinit(allocator);
        self.* = undefined;
    }
};

const FoldSnapshot = struct {
    field: []u8,
    prior_field: []u8,
    prior_on: [][]u8,
    digest: FoldDigest,

    fn deinit(self: *FoldSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        allocator.free(self.prior_field);
        for (self.prior_on) |kind| allocator.free(kind);
        allocator.free(self.prior_on);
        self.digest.deinit(allocator);
        self.* = undefined;
    }
};

const KeyedHistory = struct {
    event_kind_counts: []FoldEventKindCount,
    event_chain: ?FoldEventChain,
    snapshot: ?FoldSnapshot,

    fn deinit(self: *KeyedHistory, allocator: std.mem.Allocator) void {
        for (self.event_kind_counts) |*count| count.deinit(allocator);
        allocator.free(self.event_kind_counts);
        if (self.event_chain) |*chain| chain.deinit(allocator);
        if (self.snapshot) |*snapshot| snapshot.deinit(allocator);
        self.* = undefined;
    }

    fn active(self: *const KeyedHistory) bool {
        return self.event_kind_counts.len != 0 or
            self.event_chain != null or
            self.snapshot != null;
    }
};

const KeyedFold = struct {
    key_field: []u8,
    state_field: []u8,
    retained_field: ?[]u8,
    event_count_field: ?[]u8,
    history: KeyedHistory,

    fn deinit(self: *KeyedFold, allocator: std.mem.Allocator) void {
        allocator.free(self.key_field);
        allocator.free(self.state_field);
        if (self.retained_field) |field| allocator.free(field);
        if (self.event_count_field) |field| allocator.free(field);
        self.history.deinit(allocator);
        self.* = undefined;
    }
};

const FoldHistoryEntry = struct {
    key_bytes: [256]u8 = undefined,
    key_len: u16,
    event_kind_counts: [max_fold_event_kind_counts]usize =
        [_]usize{0} ** max_fold_event_kind_counts,
    event_chain: [64]u8 = undefined,
    has_event_chain: bool = false,
    snapshot: [64]u8 = undefined,
    has_snapshot: bool = false,
    prior_snapshot: [64]u8 = undefined,
    has_prior_snapshot: bool = false,
    retained_text: []?[]u8,

    fn init(
        allocator: std.mem.Allocator,
        keyed: *const KeyedFold,
        view: reducer.EntryView,
    ) !FoldHistoryEntry {
        if (view.key.len == 0 or view.key.len > 256) {
            return error.FoldHistoryKeyBoundsExceeded;
        }
        const fragment_count = if (keyed.history.snapshot) |snapshot|
            snapshot.digest.fragments.len
        else
            0;
        const retained_text = try allocator.alloc(?[]u8, fragment_count);
        @memset(retained_text, null);
        errdefer {
            for (retained_text) |value| {
                if (value) |bytes| allocator.free(bytes);
            }
            allocator.free(retained_text);
        }
        if (keyed.history.snapshot) |snapshot| {
            var needs_retained = false;
            for (snapshot.digest.fragments) |fragment| {
                if (fragment == .retained_text) {
                    needs_retained = true;
                    break;
                }
            }
            if (needs_retained) {
                const retained = view.retained orelse
                    return error.FoldHistoryRetainedValueMissing;
                var parsed = try std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    retained,
                    .{
                        .duplicate_field_behavior = .@"error",
                        .parse_numbers = false,
                    },
                );
                defer parsed.deinit();
                for (snapshot.digest.fragments, 0..) |fragment, index| {
                    if (fragment != .retained_text) continue;
                    const selected = definition_core.json_pointer.lookup(
                        parsed.value,
                        fragment.retained_text,
                    ) orelse return error.FoldHistoryRetainedValueMissing;
                    retained_text[index] = try allocator.dupe(
                        u8,
                        try definition_core.json.string(selected),
                    );
                }
            }
        }
        var result: FoldHistoryEntry = .{
            .key_len = @intCast(view.key.len),
            .retained_text = retained_text,
        };
        @memcpy(result.key_bytes[0..view.key.len], view.key);
        return result;
    }

    fn deinit(
        self: *FoldHistoryEntry,
        allocator: std.mem.Allocator,
    ) void {
        for (self.retained_text) |value| {
            if (value) |bytes| allocator.free(bytes);
        }
        allocator.free(self.retained_text);
        self.* = undefined;
    }

    fn key(self: *const FoldHistoryEntry) []const u8 {
        return self.key_bytes[0..self.key_len];
    }
};

const FoldHistoryAccumulator = struct {
    allocator: std.mem.Allocator,
    keyed: *const KeyedFold,
    reducer_plan: *const reducer.Plan,
    entries: std.AutoHashMapUnmanaged([32]u8, FoldHistoryEntry) = .empty,
    records_seen: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        keyed: *const KeyedFold,
        reducer_plan: *const reducer.Plan,
    ) FoldHistoryAccumulator {
        return .{
            .allocator = allocator,
            .keyed = keyed,
            .reducer_plan = reducer_plan,
        };
    }

    fn deinit(self: *FoldHistoryAccumulator) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |history_entry| {
            history_entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn observeReplay(
        self: *FoldHistoryAccumulator,
        event: std.json.Value,
        raw: []const u8,
        replay_state: ?*const protocol.ReplayState,
    ) !void {
        const context = try foldHistoryContext(
            self.reducer_plan,
            event,
            replay_state,
        );
        const history_entry = try self.ensureEntry(context.key, context.view);
        try updateFoldHistory(
            self.keyed,
            history_entry,
            context.event_kind,
            context.view,
            raw,
        );
        if (self.records_seen == std.math.maxInt(usize)) {
            return error.FoldHistoryRecordCountOverflow;
        }
        self.records_seen += 1;
    }

    fn ensureEntry(
        self: *FoldHistoryAccumulator,
        key: []const u8,
        view: reducer.EntryView,
    ) !*FoldHistoryEntry {
        var key_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &key_digest, .{});
        if (self.entries.getPtr(key_digest)) |existing| {
            if (!std.mem.eql(u8, existing.key(), key)) {
                return error.FoldHistoryKeyDigestCollision;
            }
            return existing;
        }
        var initialized = try FoldHistoryEntry.init(
            self.allocator,
            self.keyed,
            view,
        );
        var owned = true;
        defer if (owned) initialized.deinit(self.allocator);
        const result = try self.entries.getOrPut(
            self.allocator,
            key_digest,
        );
        if (result.found_existing) {
            return error.FoldHistoryKeyDigestCollision;
        }
        result.value_ptr.* = initialized;
        owned = false;
        return result.value_ptr;
    }

    fn get(
        self: *const FoldHistoryAccumulator,
        key: []const u8,
    ) ?*const FoldHistoryEntry {
        var key_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &key_digest, .{});
        const history_entry = self.entries.getPtr(key_digest) orelse
            return null;
        if (!std.mem.eql(u8, history_entry.key(), key)) return null;
        return history_entry;
    }
};

const FoldHistoryContext = struct {
    key: []const u8,
    event_kind: []const u8,
    view: reducer.EntryView,
};

fn foldHistoryContext(
    plan: *const reducer.Plan,
    event: std.json.Value,
    replay_state: ?*const protocol.ReplayState,
) !FoldHistoryContext {
    const state = replay_state orelse
        return error.FoldHistoryReplayStateMissing;
    const key = try definition_core.json.string(
        definition_core.json_pointer.lookup(
            event,
            plan.key,
        ) orelse return error.FoldHistoryKeyMissing,
    );
    const event_kind_pointer = plan.event_kind orelse
        return error.FoldHistoryEventKindMissing;
    const event_kind = try definition_core.json.string(
        definition_core.json_pointer.lookup(
            event,
            event_kind_pointer,
        ) orelse return error.FoldHistoryEventKindMissing,
    );
    const view = state.reducer_state.get(key) orelse
        return error.FoldHistoryReducerStateMissing;
    return .{ .key = key, .event_kind = event_kind, .view = view };
}

fn updateFoldHistory(
    keyed: *const KeyedFold,
    entry: *FoldHistoryEntry,
    event_kind: []const u8,
    view: reducer.EntryView,
    raw: []const u8,
) !void {
    if (keyed.history.snapshot) |snapshot| {
        if (containsSortedBytes(snapshot.prior_on, event_kind)) {
            if (!entry.has_snapshot) {
                return error.FoldHistoryPriorSnapshotMissing;
            }
            @memcpy(&entry.prior_snapshot, &entry.snapshot);
            entry.has_prior_snapshot = true;
        }
    }
    for (keyed.history.event_kind_counts, 0..) |count, index| {
        if (!std.mem.eql(u8, count.kind, event_kind)) continue;
        if (entry.event_kind_counts[index] == std.math.maxInt(usize)) {
            return error.FoldHistoryEventCountOverflow;
        }
        entry.event_kind_counts[index] += 1;
    }
    if (keyed.history.event_chain) |chain| {
        entry.event_chain = digestFoldEventChain(chain.digest, entry, raw);
        entry.has_event_chain = true;
    }
    if (keyed.history.snapshot) |snapshot| {
        entry.snapshot = try digestFoldSnapshot(snapshot.digest, entry, view);
        entry.has_snapshot = true;
    }
}

const RetainedMeta = enum {
    record_count,
    head_digest,
    event_kind_counts,
};

const RetainedRegister = struct {
    index: u16,
    pointer: definition_core.json_pointer.Pointer,
    count: bool,

    fn deinit(
        self: *RetainedRegister,
        allocator: std.mem.Allocator,
    ) void {
        self.pointer.deinit(allocator);
        self.* = undefined;
    }
};

const RetainedSource = union(enum) {
    register: RetainedRegister,
    meta: RetainedMeta,

    fn deinit(self: *RetainedSource, allocator: std.mem.Allocator) void {
        if (self.* == .register) self.register.deinit(allocator);
        self.* = undefined;
    }
};

const RetainedField = struct {
    name: []u8,
    source: RetainedSource,

    fn deinit(self: *RetainedField, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.source.deinit(allocator);
        self.* = undefined;
    }
};

const RetainedFold = struct {
    fields: []RetainedField,

    fn deinit(self: *RetainedFold, allocator: std.mem.Allocator) void {
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        self.* = undefined;
    }
};

const Fold = union(enum) {
    keyed: KeyedFold,
    retained: RetainedFold,

    fn deinit(self: *Fold, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .keyed => |*fold| fold.deinit(allocator),
            .retained => |*fold| fold.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ExitPolicy = struct {
    matched: u8 = 0,
    unmatched: u8 = 0,
    failure: ?u8 = null,

    fn active(self: ExitPolicy) bool {
        return self.matched != 0 or self.unmatched != 0 or
            self.failure != null;
    }
};

pub const SourceScope = enum {
    resolved,
    matching,
};

pub const Projection = struct {
    name: []u8,
    slot_index: u16,
    source_scope: SourceScope,
    required_parameters: [][]u8,
    predicates: []PredicateGroup,
    fields: []Field,
    preserve_field_order: bool,
    raw: bool,
    value_path: ?definition_core.json_pointer.Pointer,
    constructed_value: ?projection_value.Value,
    single: bool,
    require_match: bool,
    sort_keys: []SortKey,
    relevance: ?Relevance,
    latest: ?definition_core.json_pointer.Pointer,
    limit: ?Limit,
    fold: ?Fold,
    exit_policy: ExitPolicy,

    fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.required_parameters) |name| allocator.free(name);
        allocator.free(self.required_parameters);
        for (self.predicates) |*predicate| predicate.deinit(allocator);
        allocator.free(self.predicates);
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        if (self.value_path) |*pointer| pointer.deinit(allocator);
        if (self.constructed_value) |*value| value.deinit(allocator);
        for (self.sort_keys) |*key| key.deinit(allocator);
        allocator.free(self.sort_keys);
        if (self.relevance) |*relevance| relevance.deinit(allocator);
        if (self.latest) |*pointer| pointer.deinit(allocator);
        if (self.limit) |*limit| limit.deinit(allocator);
        if (self.fold) |*fold| fold.deinit(allocator);
        self.* = undefined;
    }
};

pub const Plan = struct {
    projections: []Projection,
    max_records: usize,
    max_output_bytes: usize,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.projections) |*projection| projection.deinit(allocator);
        allocator.free(self.projections);
        self.* = undefined;
    }

    pub fn find(self: *const Plan, name: []const u8) ?*const Projection {
        var low: usize = 0;
        var high = self.projections.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.projections[mid].name, name)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return &self.projections[mid],
            }
        }
        return null;
    }
};

pub const Stats = struct {
    records_scanned: usize,
    records_matched: usize,
    records_emitted: usize,
};

pub const Result = struct {
    definition_id: []u8,
    definition_digest: [71]u8,
    projection: []u8,
    logical_ref: []u8,
    revision: []u8,
    payload: []u8,
    stats: Stats,
    limitations: [][]u8,
    max_output_bytes: usize,
    exit_code: u8,
    authority_granted: bool = false,
    storage_mutated: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.definition_id);
        allocator.free(self.projection);
        allocator.free(self.logical_ref);
        allocator.free(self.revision);
        allocator.free(self.payload);
        for (self.limitations) |limitation| allocator.free(limitation);
        allocator.free(self.limitations);
        self.* = undefined;
    }
};

const RowMetadata = struct {
    row_id: ?[]u8 = null,
    theme: ?[]u8 = null,

    fn deinit(self: *RowMetadata, allocator: std.mem.Allocator) void {
        if (self.row_id) |value| allocator.free(value);
        if (self.theme) |value| allocator.free(value);
        self.* = undefined;
    }
};

const SortedAccumulator = struct {
    allocator: std.mem.Allocator,
    projection: *const Projection,
    parameters: *const definition_core.parameters.Bindings,
    rows: std.ArrayList(SortedRow) = .empty,
    prepared_relevance: ?PreparedRelevance,
    referenced_ids: std.StringHashMap(void),
    records_seen: usize = 0,
    records_matched: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        projection: *const Projection,
        parameters: *const definition_core.parameters.Bindings,
    ) !SortedAccumulator {
        return .{
            .allocator = allocator,
            .projection = projection,
            .parameters = parameters,
            .prepared_relevance = if (projection.relevance) |relevance|
                try prepareRelevanceAlloc(
                    allocator,
                    relevance,
                    parameters,
                )
            else
                null,
            .referenced_ids = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *SortedAccumulator) void {
        for (self.rows.items) |*row| row.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        if (self.prepared_relevance) |*prepared| {
            prepared.deinit(self.allocator);
        }
        var iterator = self.referenced_ids.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.referenced_ids.deinit();
        self.* = undefined;
    }

    pub fn observe(
        self: *SortedAccumulator,
        value: std.json.Value,
    ) !void {
        return self.observeValue(value, null);
    }

    fn observeRaw(
        self: *SortedAccumulator,
        value: std.json.Value,
        raw: []const u8,
    ) !void {
        return self.observeValue(value, raw);
    }

    fn observeValue(
        self: *SortedAccumulator,
        value: std.json.Value,
        raw: ?[]const u8,
    ) !void {
        const record_index = self.records_seen;
        self.records_seen += 1;
        try self.trackReference(value);
        if (!matches(self.projection, value, self.parameters)) return;
        const relevance_score = (try self.score(value)) orelse return;
        self.records_matched += 1;
        const keys = try self.sortKeys(
            value,
            record_index,
            relevance_score,
        );
        errdefer {
            for (keys) |*key| key.deinit(self.allocator);
            self.allocator.free(keys);
        }
        const rendered_payload = try self.renderPayload(
            value,
            raw,
            relevance_score,
        );
        errdefer self.allocator.free(rendered_payload);
        var metadata = try self.rowMetadata(value);
        errdefer metadata.deinit(self.allocator);
        try self.rows.append(self.allocator, .{
            .payload = rendered_payload,
            .keys = keys,
            .record_index = record_index,
            .row_id = metadata.row_id,
            .theme = metadata.theme,
        });
        metadata.row_id = null;
        metadata.theme = null;
    }

    fn trackReference(
        self: *SortedAccumulator,
        value: std.json.Value,
    ) !void {
        const relevance = self.projection.relevance orelse return;
        const ranked = relevance.ranked_plan orelse return;
        if (!self.prepared_relevance.?.ranked.exclude_referenced) return;
        const reference = ranked_relevance.referencedId(
            ranked,
            value,
        ) orelse return;
        if (self.referenced_ids.contains(reference)) return;
        try self.referenced_ids.put(
            try self.allocator.dupe(u8, reference),
            {},
        );
    }

    fn score(
        self: *SortedAccumulator,
        value: std.json.Value,
    ) !?f64 {
        const relevance = self.projection.relevance orelse return 0.0;
        return relevanceScoreAlloc(
            self.allocator,
            relevance,
            &self.prepared_relevance.?,
            value,
        );
    }

    fn sortKeys(
        self: *SortedAccumulator,
        value: std.json.Value,
        record_index: usize,
        relevance_score: f64,
    ) ![]Scalar {
        const keys = try self.allocator.alloc(
            Scalar,
            self.projection.sort_keys.len,
        );
        var initialized: usize = 0;
        errdefer {
            for (keys[0..initialized]) |*key| key.deinit(self.allocator);
            self.allocator.free(keys);
        }
        for (self.projection.sort_keys, 0..) |sort_key, index| {
            keys[index] = try self.sortKey(
                sort_key,
                value,
                record_index,
                relevance_score,
            );
            initialized += 1;
            if (self.rows.items.len != 0 and
                !scalarKindsCompatible(
                    self.rows.items[0].keys[index],
                    keys[index],
                ))
            {
                return error.ProjectionOrderingTypeMismatch;
            }
        }
        return keys;
    }

    fn sortKey(
        self: *SortedAccumulator,
        sort_key: SortKey,
        value: std.json.Value,
        record_index: usize,
        relevance_score: f64,
    ) !Scalar {
        const key = switch (sort_key.source) {
            .record_order => Scalar{ .integer = @intCast(record_index) },
            .relevance_score => Scalar{ .float = relevance_score },
            .pointer => |pointer| try scalarFromJsonAlloc(
                self.allocator,
                definition_core.json_pointer.lookup(
                    value,
                    pointer,
                ) orelse return error.ProjectionSortFieldMissing,
            ),
        };
        switch (key) {
            .string, .number, .integer, .float => return key,
            else => {
                var owned = key;
                owned.deinit(self.allocator);
                return error.ProjectionSortScalarRequired;
            },
        }
    }

    fn renderPayload(
        self: *SortedAccumulator,
        value: std.json.Value,
        raw: ?[]const u8,
        relevance_score: f64,
    ) ![]u8 {
        if (self.projection.raw) {
            return self.allocator.dupe(
                u8,
                raw orelse return error.FusedRawProjectionUnsupported,
            );
        }
        if (self.projection.relevance) |relevance| {
            return projectedValueWithScoreAlloc(
                self.allocator,
                self.projection,
                value,
                relevance.score_field,
                relevance_score,
            );
        }
        return projectedValueAlloc(self.allocator, self.projection, value);
    }

    fn rowMetadata(
        self: *SortedAccumulator,
        value: std.json.Value,
    ) !RowMetadata {
        const relevance = self.projection.relevance orelse return .{};
        const ranked = relevance.ranked_plan orelse return .{};
        var result: RowMetadata = .{};
        errdefer result.deinit(self.allocator);
        if (self.prepared_relevance.?.ranked.exclude_referenced) {
            if (ranked_relevance.rowId(ranked, value)) |id| {
                result.row_id = try self.allocator.dupe(u8, id);
            }
        }
        result.theme = try ranked_relevance.themeAlloc(
            self.allocator,
            ranked,
            value,
        );
        return result;
    }

    fn write(
        self: *SortedAccumulator,
        writer: *std.Io.Writer,
        limit: usize,
        stats: *Stats,
    ) !void {
        std.sort.heap(
            SortedRow,
            self.rows.items,
            self.projection.sort_keys,
            lessSortedRow,
        );
        try writer.writeByte('[');
        var theme_counts = std.StringHashMap(usize).init(self.allocator);
        defer theme_counts.deinit();
        const max_per_theme = if (self.projection.relevance) |relevance|
            if (relevance.ranked_plan) |ranked|
                ranked_relevance.maxPerTheme(ranked)
            else
                null
        else
            null;
        var emitted: usize = 0;
        for (self.rows.items) |row| {
            if (emitted >= limit) break;
            if (row.row_id) |id| {
                if (self.referenced_ids.contains(id)) continue;
            }
            if (max_per_theme) |maximum| {
                if (row.theme) |theme| {
                    if (theme.len != 0) {
                        const count = theme_counts.get(theme) orelse 0;
                        if (count >= maximum) continue;
                        try theme_counts.put(theme, count + 1);
                    }
                }
            }
            if (emitted != 0) try writer.writeByte(',');
            try writer.writeAll(row.payload);
            emitted += 1;
        }
        try writer.writeByte(']');
        stats.records_matched = self.records_matched;
        stats.records_emitted = emitted;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
) !Plan {
    var projections: std.ArrayList(Projection) = .empty;
    errdefer {
        for (projections.items) |*projection| projection.deinit(allocator);
        projections.deinit(allocator);
    }
    for (definition_plan.projections) |source| {
        var compiled = try compileProjection(
            allocator,
            definition_plan,
            storage_plan,
            event_protocol,
            source,
        );
        errdefer compiled.deinit(allocator);
        try projections.append(allocator, compiled);
    }
    return .{
        .projections = try projections.toOwnedSlice(allocator),
        .max_records = definition_plan.bounds.max_records,
        .max_output_bytes = definition_plan.bounds.max_output_bytes,
    };
}

pub fn encodeCache(
    plan: *const Plan,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(14);
    try encoder.writeUsize(plan.max_records);
    try encoder.writeUsize(plan.max_output_bytes);
    try encoder.writeCount(plan.projections.len);
    for (plan.projections) |projection| {
        try encodeProjection(projection, encoder);
    }
}

fn encodeProjection(
    projection: Projection,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeBytes(projection.name);
    try encoder.writeU16(projection.slot_index);
    try encoder.writeEnum(projection.source_scope);
    try encodeProjectionParameters(projection.required_parameters, encoder);
    try encodeProjectionPredicates(projection.predicates, encoder);
    try encoder.writeBool(projection.preserve_field_order);
    try encoder.writeBool(projection.raw);
    try encoder.writeBool(projection.value_path != null);
    if (projection.value_path) |pointer| try encoder.writeBytes(pointer.raw);
    try encoder.writeBool(projection.constructed_value != null);
    if (projection.constructed_value) |value| {
        try projection_value.encodeCache(value, encoder);
    }
    try encoder.writeBool(projection.single);
    try encoder.writeBool(projection.require_match);
    try encoder.writeByte(projection.exit_policy.matched);
    try encoder.writeByte(projection.exit_policy.unmatched);
    try encoder.writeBool(projection.exit_policy.failure != null);
    if (projection.exit_policy.failure) |code| try encoder.writeByte(code);
    try encodeProjectionSort(projection.sort_keys, encoder);
    try encodeProjectionRelevance(projection.relevance, encoder);
    try encodeProjectionFields(projection.fields, encoder);
    try encoder.writeBool(projection.latest != null);
    if (projection.latest) |pointer| try encoder.writeBytes(pointer.raw);
    try encodeProjectionLimit(projection.limit, encoder);
    try encodeProjectionFold(projection.fold, encoder);
}

fn encodeProjectionParameters(
    parameters: []const []u8,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(parameters.len);
    for (parameters) |name| try encoder.writeBytes(name);
}

fn encodeProjectionPredicates(
    groups: []const PredicateGroup,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(groups.len);
    for (groups) |group| switch (group) {
        .one => |predicate| {
            try encoder.writeByte(0);
            try encodeCachePredicate(encoder, predicate);
        },
        .any => |sets| {
            try encoder.writeByte(1);
            try encoder.writeCount(sets.len);
            for (sets) |set| {
                try encoder.writeCount(set.predicates.len);
                for (set.predicates) |predicate| {
                    try encodeCachePredicate(encoder, predicate);
                }
            }
        },
    };
}

fn encodeProjectionSort(
    keys: []const SortKey,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(keys.len);
    for (keys) |key| {
        switch (key.source) {
            .pointer => |pointer| {
                try encoder.writeByte(0);
                try encoder.writeBytes(pointer.raw);
            },
            .record_order => try encoder.writeByte(1),
            .relevance_score => try encoder.writeByte(2),
        }
        try encoder.writeEnum(key.order);
    }
}

fn encodeProjectionRelevance(
    relevance: ?Relevance,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeBool(relevance != null);
    const value = relevance orelse return;
    try encoder.writeCount(value.paths.len);
    for (value.paths) |path| try encoder.writeBytes(path.raw);
    try encoder.writeBytes(value.parameter);
    try encoder.writeEnum(value.mode);
    try encoder.writeBool(value.score_field != null);
    if (value.score_field) |field| try encoder.writeBytes(field);
    try encoder.writeBool(value.ranked_plan != null);
    if (value.ranked_plan) |ranked| {
        try ranked_relevance.encodeCache(ranked, encoder);
    }
}

fn encodeProjectionFields(
    fields: []const Field,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(fields.len);
    for (fields) |field| {
        try encoder.writeBytes(field.name);
        try encoder.writeBytes(field.pointer.raw);
    }
}

fn encodeProjectionLimit(
    limit: ?Limit,
    encoder: *definition_core.cache.Encoder,
) !void {
    const value = limit orelse return encoder.writeByte(0);
    switch (value) {
        .fixed => |count| {
            try encoder.writeByte(1);
            try encoder.writeUsize(count);
        },
        .parameter => |name| {
            try encoder.writeByte(2);
            try encoder.writeBytes(name);
        },
    }
}

fn encodeProjectionFold(
    fold: ?Fold,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeBool(fold != null);
    const value = fold orelse return;
    switch (value) {
        .keyed => |keyed| {
            try encoder.writeByte(0);
            try encoder.writeBytes(keyed.key_field);
            try encoder.writeBytes(keyed.state_field);
            try encoder.writeOptionalBytes(keyed.retained_field);
            try encoder.writeOptionalBytes(keyed.event_count_field);
            try encodeKeyedHistory(&keyed.history, encoder);
        },
        .retained => |retained| try encodeRetainedFold(retained, encoder),
    }
}

fn encodeRetainedFold(
    retained: RetainedFold,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeByte(1);
    try encoder.writeCount(retained.fields.len);
    for (retained.fields) |field| {
        try encoder.writeBytes(field.name);
        switch (field.source) {
            .register => |register| {
                try encoder.writeByte(0);
                try encoder.writeU16(register.index);
                try encoder.writeBytes(register.pointer.raw);
                try encoder.writeBool(register.count);
            },
            .meta => |meta| {
                try encoder.writeByte(1);
                try encoder.writeEnum(meta);
            },
        }
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Plan {
    if (try decoder.readU16() != 14) {
        return error.LedgerProjectionCacheVersionMismatch;
    }
    const max_records = try decoder.readUsize();
    const max_output_bytes = try decoder.readUsize();
    if (max_records == 0 or max_records > 10_000_000 or
        max_output_bytes == 0 or max_output_bytes > 256 * 1024 * 1024)
    {
        return error.CacheProjectionBoundsInvalid;
    }
    const count = try decoder.readCount(128);
    const projections = try allocator.alloc(Projection, count);
    var initialized: usize = 0;
    errdefer {
        for (projections[0..initialized]) |*projection| {
            projection.deinit(allocator);
        }
        allocator.free(projections);
    }
    for (projections, 0..) |*projection, index| {
        projection.* = try decodeCacheProjection(
            allocator,
            decoder,
            max_output_bytes,
        );
        initialized += 1;
        if (index != 0 and std.mem.order(
            u8,
            projections[index - 1].name,
            projection.name,
        ) != .lt) return error.CacheProjectionsNotSorted;
    }
    for (projections) |projection| {
        if (projection.limit) |limit| switch (limit) {
            .fixed => |fixed| if (fixed == 0 or fixed > max_records) {
                return error.InvalidProjectionLimit;
            },
            .parameter => {},
        };
    }
    return .{
        .projections = projections,
        .max_records = max_records,
        .max_output_bytes = max_output_bytes,
    };
}

pub fn validateCachePlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
) !void {
    if (plan.max_records != definition_plan.bounds.max_records or
        plan.max_output_bytes != definition_plan.bounds.max_output_bytes)
    {
        return error.CacheProjectionPlanMismatch;
    }
    for (plan.projections) |projection| {
        try validateCachedProjection(
            projection,
            definition_plan,
            storage_plan,
            event_protocol,
        );
    }
}

fn validateCachedProjection(
    projection: Projection,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
) !void {
    if (projection.slot_index >= storage_plan.slots.len) {
        return error.CacheProjectionPlanMismatch;
    }
    try validateCachedRequiredParameters(projection, definition_plan);
    try validateCachedSourceScope(projection, storage_plan);
    try validateCachedFold(projection, definition_plan, event_protocol);
    try validateCachedPredicates(projection, definition_plan);
    try validateCachedLimitAndPolicy(projection, definition_plan);
    try validateCachedRelevance(projection, definition_plan);
    try validateCachedSortKeys(projection);
    try validateCachedShape(projection);
    try validateCachedFields(projection);
}

fn validateCachedRequiredParameters(
    projection: Projection,
    definition_plan: *const definition.Plan,
) !void {
    for (projection.required_parameters) |name| {
        if (definition_plan.parameter_declarations.find(name) == null) {
            return error.CacheProjectionPlanMismatch;
        }
    }
}

fn validateCachedSourceScope(
    projection: Projection,
    storage_plan: *const storage.Plan,
) !void {
    if (projection.source_scope != .matching) return;
    const source_slot = storage_plan.slots[projection.slot_index];
    if (source_slot.kind != .document or
        !storage.slotIsParameterized(source_slot) or
        projection.latest == null or projection.fold != null or
        projection.relevance != null or
        projection.sort_keys.len != 0 or
        projection.predicates.len != 0 or projection.limit != null)
    {
        return error.CacheProjectionPlanMismatch;
    }
}

fn validateCachedPredicates(
    projection: Projection,
    definition_plan: *const definition.Plan,
) !void {
    for (projection.predicates) |group| {
        switch (group) {
            .one => |predicate| try validateCachedPredicate(
                predicate,
                definition_plan,
            ),
            .any => |sets| try validateCachedPredicateSets(
                sets,
                definition_plan,
            ),
        }
    }
}

fn validateCachedPredicateSets(
    sets: []const PredicateSet,
    definition_plan: *const definition.Plan,
) !void {
    if (sets.len == 0 or sets.len > 64) {
        return error.CacheProjectionPlanMismatch;
    }
    for (sets) |set| {
        if (set.predicates.len == 0 or set.predicates.len > 64) {
            return error.CacheProjectionPlanMismatch;
        }
        for (set.predicates) |predicate| {
            try validateCachedPredicate(predicate, definition_plan);
        }
    }
}

fn validateCachedLimitAndPolicy(
    projection: Projection,
    definition_plan: *const definition.Plan,
) !void {
    if (projection.limit) |limit| switch (limit) {
        .fixed => {},
        .parameter => |name| {
            const declaration =
                definition_plan.parameter_declarations.find(name) orelse
                return error.CacheProjectionPlanMismatch;
            if (declaration.kind != .integer) {
                return error.CacheProjectionPlanMismatch;
            }
        },
    };
    if (projection.single and projection.limit != null) {
        return error.CacheProjectionPlanMismatch;
    }
    if (projection.require_match and !projection.single) {
        return error.CacheProjectionPlanMismatch;
    }
    try validateExitPolicy(projection.exit_policy);
    if (projection.single and projection.sort_keys.len != 0) {
        return error.CacheProjectionPlanMismatch;
    }
    if (projection.sort_keys.len != 0 and
        !definition_plan.requires(.sort))
    {
        return error.CacheProjectionPlanMismatch;
    }
}

fn validateCachedRelevance(
    projection: Projection,
    definition_plan: *const definition.Plan,
) !void {
    const relevance = projection.relevance orelse return;
    const declaration = definition_plan.parameter_declarations.find(
        relevance.parameter,
    ) orelse return error.CacheProjectionPlanMismatch;
    if (!definition_plan.requires(.relevance) or
        projection.sort_keys.len == 0 or
        declaration.kind != .string or
        relevance.paths.len == 0 or relevance.paths.len > 64 or
        (relevance.mode == .ranked_tokens) !=
            (relevance.ranked_plan != null) or
        relevance.score_field != null and projection.fields.len == 0 or
        projection.raw or projection.value_path != null or
        projection.constructed_value != null)
    {
        return error.CacheProjectionPlanMismatch;
    }
    if (relevance.ranked_plan) |ranked| {
        try ranked_relevance.validateCache(
            ranked,
            &definition_plan.parameter_declarations,
        );
    }
    const score_field = relevance.score_field orelse return;
    for (projection.fields) |field| {
        if (std.mem.eql(u8, score_field, field.name)) {
            return error.CacheProjectionFieldsNotUnique;
        }
    }
}

fn validateCachedSortKeys(projection: Projection) !void {
    for (projection.sort_keys) |key| {
        if (key.source == .relevance_score and projection.relevance == null) {
            return error.CacheProjectionPlanMismatch;
        }
    }
}

fn validateCachedShape(projection: Projection) !void {
    if ((projection.raw and
        (projection.fields.len != 0 or
            projection.value_path != null or
            projection.constructed_value != null)) or
        (projection.value_path != null and
            (projection.fields.len != 0 or
                projection.constructed_value != null)) or
        (projection.constructed_value != null and
            projection.fields.len != 0) or
        (projection.preserve_field_order and projection.fields.len == 0))
    {
        return error.CacheProjectionPlanMismatch;
    }
}

fn validateCachedFields(projection: Projection) !void {
    for (projection.fields, 0..) |field, index| {
        for (projection.fields[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, field.name)) {
                return error.CacheProjectionFieldsNotUnique;
            }
        }
        if (!projection.preserve_field_order and index != 0 and
            std.mem.order(
                u8,
                projection.fields[index - 1].name,
                field.name,
            ) != .lt)
        {
            return error.CacheProjectionFieldsNotSorted;
        }
    }
}

fn validateCachedFold(
    projection: Projection,
    definition_plan: *const definition.Plan,
    event_protocol: ?*const protocol.Plan,
) !void {
    const fold = projection.fold orelse return;
    if (projection.fields.len != 0 or
        projection.value_path != null or
        projection.latest != null or
        !definition_plan.requires(.fold) or
        event_protocol == null or
        event_protocol.?.target_slot_index != projection.slot_index)
    {
        return error.CacheProjectionPlanMismatch;
    }
    switch (fold) {
        .keyed => |keyed| try validateCachedKeyedFold(
            projection,
            definition_plan,
            event_protocol.?,
            keyed,
        ),
        .retained => |retained| try validateCachedRetainedFold(
            projection,
            definition_plan,
            event_protocol.?,
            retained,
        ),
    }
}

fn validateCachedKeyedFold(
    projection: Projection,
    definition_plan: *const definition.Plan,
    event_protocol: *const protocol.Plan,
    keyed: KeyedFold,
) !void {
    const keyed_plan = if (event_protocol.reducer_plan) |*value|
        value
    else
        return error.CacheProjectionPlanMismatch;
    if (keyed.retained_field != null and
        keyed_plan.retain_once == null and
        keyed_plan.retain_latest == null)
    {
        return error.CacheProjectionPlanMismatch;
    }
    try validateKeyedFoldFields(
        keyed.key_field,
        keyed.state_field,
        keyed.retained_field,
        keyed.event_count_field,
        &keyed.history,
        error.CacheProjectionPlanMismatch,
    );
    try validateKeyedHistory(
        &keyed.history,
        definition_plan,
        event_protocol,
        error.CacheProjectionPlanMismatch,
    );
    const composed = projection.predicates.len != 0 or
        projection.constructed_value != null;
    if (projection.constructed_value != null) {
        return validateConstructedKeyedFold(projection, keyed);
    }
    if (composed and
        (projection.raw or
            projection.value_path != null or
            projection.fields.len != 0))
    {
        return error.CacheProjectionPlanMismatch;
    }
}

fn validateConstructedKeyedFold(
    projection: Projection,
    keyed: KeyedFold,
) !void {
    if (projection.predicates.len != 1 or
        !projection.single or
        !projection.require_match or
        projection.raw or
        projection.limit != null or
        projection.predicates[0] != .one)
    {
        return error.CacheProjectionPlanMismatch;
    }
    const predicate = projection.predicates[0].one;
    if (predicate.operand != .parameter) {
        return error.CacheProjectionPlanMismatch;
    }
    var expected_path: [130]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &expected_path,
        "/{s}",
        .{keyed.key_field},
    );
    if (!std.mem.eql(u8, predicate.pointer.raw, path)) {
        return error.CacheProjectionPlanMismatch;
    }
}

fn validateCachedRetainedFold(
    projection: Projection,
    definition_plan: *const definition.Plan,
    event_protocol: *const protocol.Plan,
    retained: RetainedFold,
) !void {
    const plan = if (event_protocol.state_reducer_plan) |*value|
        value
    else
        return error.CacheProjectionPlanMismatch;
    if (projection.limit != null or
        projection.predicates.len != 0 or
        projection.raw or projection.single or
        projection.require_match or
        retained.fields.len == 0 or
        retained.fields.len > 256)
    {
        return error.CacheProjectionPlanMismatch;
    }
    if (projection.constructed_value != null and
        !definition_plan.requires(.@"export"))
    {
        return error.CacheProjectionPlanMismatch;
    }
    for (retained.fields, 0..) |field, index| {
        try definition_core.json.safeIdentifier(field.name, 128);
        if (index != 0 and std.mem.order(
            u8,
            retained.fields[index - 1].name,
            field.name,
        ) != .lt) return error.CacheProjectionFieldsNotSorted;
        if (field.source == .register and
            field.source.register.index >= state_reducer.registerCount(plan))
        {
            return error.CacheProjectionPlanMismatch;
        }
    }
}

fn decodeCacheProjection(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    max_output_bytes: usize,
) !Projection {
    const name = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(name);
    try definition_core.json.safeIdentifier(name, 128);
    const slot_index = try decoder.readU16();
    const source_scope = try decoder.readEnum(SourceScope);
    const required_parameters = try decodeRequiredParameters(
        allocator,
        decoder,
    );
    errdefer deinitNames(allocator, required_parameters);
    const predicates = try decodePredicateGroups(allocator, decoder);
    errdefer deinitPredicateGroups(allocator, predicates);
    var shape = try decodeProjectionShape(
        allocator,
        decoder,
        max_output_bytes,
    );
    errdefer shape.deinit(allocator);
    const sort_keys = try decodeSortKeys(allocator, decoder);
    errdefer deinitSortKeys(allocator, sort_keys);
    var relevance = try decodeRelevance(allocator, decoder);
    errdefer if (relevance) |*compiled| compiled.deinit(allocator);
    const fields = try decodeProjectionFields(
        allocator,
        decoder,
        shape.preserve_field_order,
    );
    errdefer deinitFields(allocator, fields);
    var latest = try decodeOptionalPointer(allocator, decoder);
    errdefer if (latest) |*pointer| pointer.deinit(allocator);
    var limit = try decodeProjectionLimit(allocator, decoder);
    errdefer if (limit) |*value| value.deinit(allocator);
    var fold = try decodeProjectionFold(allocator, decoder);
    errdefer if (fold) |*compiled| compiled.deinit(allocator);
    return .{
        .name = name,
        .slot_index = slot_index,
        .source_scope = source_scope,
        .required_parameters = required_parameters,
        .predicates = predicates,
        .fields = fields,
        .preserve_field_order = shape.preserve_field_order,
        .raw = shape.raw,
        .value_path = shape.value_path,
        .constructed_value = shape.constructed_value,
        .single = shape.single,
        .require_match = shape.require_match,
        .sort_keys = sort_keys,
        .relevance = relevance,
        .latest = latest,
        .limit = limit,
        .fold = fold,
        .exit_policy = shape.exit_policy,
    };
}

fn deinitNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

fn deinitPredicateGroups(
    allocator: std.mem.Allocator,
    groups: []PredicateGroup,
) void {
    for (groups) |*group| group.deinit(allocator);
    allocator.free(groups);
}

fn deinitSortKeys(
    allocator: std.mem.Allocator,
    keys: []SortKey,
) void {
    for (keys) |*key| key.deinit(allocator);
    allocator.free(keys);
}

fn deinitFields(allocator: std.mem.Allocator, fields: []Field) void {
    for (fields) |*field| field.deinit(allocator);
    allocator.free(fields);
}

fn decodeRequiredParameters(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![][]u8 {
    const count = try decoder.readCount(64);
    const names = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (names[0..initialized]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (names, 0..) |*name, index| {
        name.* = try decoder.readBytesAlloc(allocator, 128);
        initialized += 1;
        try definition_core.json.safeIdentifier(name.*, 128);
        if (index != 0 and
            std.mem.order(u8, names[index - 1], name.*) != .lt)
        {
            return error.CacheProjectionParametersNotSorted;
        }
    }
    return names;
}

fn decodePredicateGroups(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]PredicateGroup {
    const count = try decoder.readCount(64);
    const groups = try allocator.alloc(PredicateGroup, count);
    var initialized: usize = 0;
    errdefer {
        for (groups[0..initialized]) |*group| group.deinit(allocator);
        allocator.free(groups);
    }
    for (groups) |*group| {
        group.* = try decodePredicateGroup(allocator, decoder);
        initialized += 1;
    }
    return groups;
}

fn decodePredicateGroup(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !PredicateGroup {
    return switch (try decoder.readByte()) {
        0 => .{ .one = try decodeCachePredicate(allocator, decoder) },
        1 => .{ .any = try decodePredicateSets(allocator, decoder) },
        else => error.CacheProjectionPredicateGroupInvalid,
    };
}

fn decodePredicateSets(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]PredicateSet {
    const count = try decoder.readCount(64);
    if (count == 0) return error.CacheProjectionPredicatesInvalid;
    const sets = try allocator.alloc(PredicateSet, count);
    var initialized: usize = 0;
    errdefer {
        for (sets[0..initialized]) |*set| set.deinit(allocator);
        allocator.free(sets);
    }
    for (sets) |*set| {
        const predicate_count = try decoder.readCount(64);
        if (predicate_count == 0) {
            return error.CacheProjectionPredicatesInvalid;
        }
        const predicates = try allocator.alloc(Predicate, predicate_count);
        var predicate_initialized: usize = 0;
        errdefer {
            for (predicates[0..predicate_initialized]) |*predicate| {
                predicate.deinit(allocator);
            }
            allocator.free(predicates);
        }
        for (predicates) |*predicate| {
            predicate.* = try decodeCachePredicate(allocator, decoder);
            predicate_initialized += 1;
        }
        set.* = .{ .predicates = predicates };
        initialized += 1;
    }
    return sets;
}

const DecodedProjectionShape = struct {
    preserve_field_order: bool,
    raw: bool,
    value_path: ?definition_core.json_pointer.Pointer,
    constructed_value: ?projection_value.Value,
    single: bool,
    require_match: bool,
    exit_policy: ExitPolicy,

    fn deinit(
        self: *DecodedProjectionShape,
        allocator: std.mem.Allocator,
    ) void {
        if (self.value_path) |*pointer| pointer.deinit(allocator);
        if (self.constructed_value) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

fn decodeProjectionShape(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    max_output_bytes: usize,
) !DecodedProjectionShape {
    const preserve_field_order = try decoder.readBool();
    const raw = try decoder.readBool();
    var value_path = try decodeOptionalPointer(allocator, decoder);
    errdefer if (value_path) |*pointer| pointer.deinit(allocator);
    var constructed_value: ?projection_value.Value = null;
    errdefer if (constructed_value) |*value| value.deinit(allocator);
    if (try decoder.readBool()) {
        constructed_value = try projection_value.decodeCache(
            allocator,
            decoder,
            max_output_bytes,
        );
    }
    const single = try decoder.readBool();
    const require_match = try decoder.readBool();
    const exit_policy = ExitPolicy{
        .matched = try decoder.readByte(),
        .unmatched = try decoder.readByte(),
        .failure = if (try decoder.readBool())
            try decoder.readByte()
        else
            null,
    };
    try validateExitPolicy(exit_policy);
    return .{
        .preserve_field_order = preserve_field_order,
        .raw = raw,
        .value_path = value_path,
        .constructed_value = constructed_value,
        .single = single,
        .require_match = require_match,
        .exit_policy = exit_policy,
    };
}

fn decodeOptionalPointer(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?definition_core.json_pointer.Pointer {
    if (!try decoder.readBool()) return null;
    const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
    defer allocator.free(raw_pointer);
    return try definition_core.json_pointer.compile(
        allocator,
        raw_pointer,
    );
}

fn decodeSortKeys(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]SortKey {
    const count = try decoder.readCount(8);
    const keys = try allocator.alloc(SortKey, count);
    var initialized: usize = 0;
    errdefer {
        for (keys[0..initialized]) |*key| key.deinit(allocator);
        allocator.free(keys);
    }
    for (keys) |*key| {
        key.* = .{
            .source = try decodeSortSource(allocator, decoder),
            .order = try decoder.readEnum(SortOrder),
        };
        initialized += 1;
    }
    return keys;
}

fn decodeSortSource(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !SortSource {
    return switch (try decoder.readByte()) {
        0 => pointer: {
            const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
            defer allocator.free(raw_pointer);
            break :pointer .{ .pointer = try definition_core.json_pointer.compile(
                allocator,
                raw_pointer,
            ) };
        },
        1 => .record_order,
        2 => .relevance_score,
        else => error.CacheProjectionSortSourceInvalid,
    };
}

fn decodeRelevance(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?Relevance {
    if (!try decoder.readBool()) return null;
    const paths = try decodeRelevancePaths(allocator, decoder);
    errdefer {
        for (paths) |*path| path.deinit(allocator);
        allocator.free(paths);
    }
    const parameter = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(parameter);
    try definition_core.json.safeIdentifier(parameter, 128);
    const mode = try decoder.readEnum(RelevanceMode);
    const score_field = try decodeOptionalFieldName(allocator, decoder);
    errdefer if (score_field) |field| allocator.free(field);
    var ranked_plan = if (try decoder.readBool())
        try ranked_relevance.decodeCache(allocator, decoder)
    else
        null;
    errdefer if (ranked_plan) |*plan| plan.deinit(allocator);
    if ((mode == .ranked_tokens) != (ranked_plan != null)) {
        return error.CacheProjectionRelevanceInvalid;
    }
    return .{
        .paths = paths,
        .parameter = parameter,
        .mode = mode,
        .score_field = score_field,
        .ranked_plan = ranked_plan,
    };
}

fn decodeOptionalFieldName(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?[]u8 {
    if (!try decoder.readBool()) return null;
    const field = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(field);
    try definition_core.json.safeIdentifier(field, 128);
    return field;
}

fn decodeRelevancePaths(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]definition_core.json_pointer.Pointer {
    const count = try decoder.readCount(64);
    if (count == 0) return error.CacheProjectionRelevanceInvalid;
    const paths = try allocator.alloc(
        definition_core.json_pointer.Pointer,
        count,
    );
    var initialized: usize = 0;
    errdefer {
        for (paths[0..initialized]) |*path| path.deinit(allocator);
        allocator.free(paths);
    }
    for (paths) |*path| {
        const raw_path = try decoder.readBytesAlloc(allocator, 1024);
        defer allocator.free(raw_path);
        path.* = try definition_core.json_pointer.compile(
            allocator,
            raw_path,
        );
        initialized += 1;
    }
    return paths;
}

fn decodeProjectionFields(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    preserve_field_order: bool,
) ![]Field {
    const count = try decoder.readCount(256);
    const fields = try allocator.alloc(Field, count);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (fields, 0..) |*field, index| {
        const name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(name);
        try definition_core.json.safeIdentifier(name, 128);
        try validateDecodedFieldName(
            fields[0..index],
            name,
            preserve_field_order,
        );
        const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
        defer allocator.free(raw_pointer);
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            raw_pointer,
        );
        errdefer pointer.deinit(allocator);
        field.* = .{ .name = name, .pointer = pointer };
        initialized += 1;
    }
    return fields;
}

fn validateDecodedFieldName(
    fields: []const Field,
    name: []const u8,
    preserve_field_order: bool,
) !void {
    if (!preserve_field_order and fields.len != 0 and
        std.mem.order(u8, fields[fields.len - 1].name, name) != .lt)
    {
        return error.CacheProjectionFieldsNotSorted;
    }
    for (fields) |prior| {
        if (std.mem.eql(u8, prior.name, name)) {
            return error.CacheProjectionFieldsNotUnique;
        }
    }
}

fn decodeProjectionLimit(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?Limit {
    const limit: ?Limit = switch (try decoder.readByte()) {
        0 => null,
        1 => .{ .fixed = try decoder.readUsize() },
        2 => .{ .parameter = try decoder.readBytesAlloc(allocator, 128) },
        else => return error.CacheProjectionLimitInvalid,
    };
    errdefer if (limit) |value| {
        var owned = value;
        owned.deinit(allocator);
    };
    if (limit != null and limit.? == .parameter) {
        try definition_core.json.safeIdentifier(limit.?.parameter, 128);
    }
    return limit;
}

fn decodeProjectionFold(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?Fold {
    if (!try decoder.readBool()) return null;
    return switch (try decoder.readByte()) {
        0 => .{ .keyed = try decodeKeyedFold(allocator, decoder) },
        1 => .{ .retained = try decodeRetainedFold(allocator, decoder) },
        else => error.CacheProjectionFoldInvalid,
    };
}

fn decodeKeyedFold(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !KeyedFold {
    const key_field = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(key_field);
    try definition_core.json.safeIdentifier(key_field, 128);
    const state_field = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(state_field);
    try definition_core.json.safeIdentifier(state_field, 128);
    const retained_field = try decoder.readOptionalBytesAlloc(allocator, 128);
    errdefer if (retained_field) |field| allocator.free(field);
    const event_count_field =
        try decoder.readOptionalBytesAlloc(allocator, 128);
    errdefer if (event_count_field) |field| allocator.free(field);
    var history = try decodeKeyedHistory(allocator, decoder);
    errdefer history.deinit(allocator);
    try validateKeyedFoldFields(
        key_field,
        state_field,
        retained_field,
        event_count_field,
        &history,
        error.CacheProjectionFieldsConflict,
    );
    return .{
        .key_field = key_field,
        .state_field = state_field,
        .retained_field = retained_field,
        .event_count_field = event_count_field,
        .history = history,
    };
}

fn decodeRetainedFold(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !RetainedFold {
    const count = try decoder.readCount(256);
    if (count == 0) return error.CacheProjectionFieldsInvalid;
    const fields = try allocator.alloc(RetainedField, count);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (fields, 0..) |*field, index| {
        field.* = try decodeRetainedField(
            allocator,
            decoder,
            fields[0..index],
        );
        initialized += 1;
    }
    return .{ .fields = fields };
}

fn decodeRetainedField(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    prior: []const RetainedField,
) !RetainedField {
    const name = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(name);
    try definition_core.json.safeIdentifier(name, 128);
    if (prior.len != 0 and
        std.mem.order(u8, prior[prior.len - 1].name, name) != .lt)
    {
        return error.CacheProjectionFieldsNotSorted;
    }
    var source = try decodeRetainedSource(allocator, decoder);
    errdefer source.deinit(allocator);
    return .{ .name = name, .source = source };
}

fn decodeRetainedSource(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !RetainedSource {
    return switch (try decoder.readByte()) {
        0 => register: {
            const index = try decoder.readU16();
            const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
            defer allocator.free(raw_pointer);
            var pointer = try definition_core.json_pointer.compile(
                allocator,
                raw_pointer,
            );
            errdefer pointer.deinit(allocator);
            break :register .{ .register = .{
                .index = index,
                .pointer = pointer,
                .count = try decoder.readBool(),
            } };
        },
        1 => .{ .meta = try decoder.readEnum(RetainedMeta) },
        else => error.CacheProjectionSourceInvalid,
    };
}

fn validateExitPolicy(policy: ExitPolicy) !void {
    if (!policy.active()) return;
    if (policy.failure == null or policy.matched > 125 or
        policy.unmatched > 125 or policy.failure.? > 125 or
        policy.matched == policy.unmatched or
        policy.failure.? == policy.matched or
        policy.failure.? == policy.unmatched)
    {
        return error.CacheProjectionExitPolicyInvalid;
    }
}

fn encodeCacheScalar(
    encoder: *definition_core.cache.Encoder,
    value: Scalar,
) !void {
    switch (value) {
        .string => |text| {
            try encoder.writeByte(0);
            try encoder.writeBytes(text);
        },
        .integer => |number| {
            try encoder.writeByte(1);
            try encoder.writeI64(number);
        },
        .float => |number| {
            try encoder.writeByte(2);
            try encoder.writeF64(number);
        },
        .boolean => |flag| {
            try encoder.writeByte(3);
            try encoder.writeBool(flag);
        },
        .null => try encoder.writeByte(4),
        .number => |text| {
            try encoder.writeByte(5);
            try encoder.writeBytes(text);
        },
    }
}

fn encodeCachePredicate(
    encoder: *definition_core.cache.Encoder,
    predicate: Predicate,
) !void {
    try encoder.writeBytes(predicate.pointer.raw);
    switch (predicate.operand) {
        .constant => |value| {
            try encoder.writeByte(0);
            try encodeCacheScalar(encoder, value);
        },
        .parameter => |name| {
            try encoder.writeByte(1);
            try encoder.writeBytes(name);
        },
    }
}

fn decodeCachePredicate(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Predicate {
    const raw_pointer = try decoder.readBytesAlloc(allocator, 1024);
    defer allocator.free(raw_pointer);
    var pointer = try definition_core.json_pointer.compile(
        allocator,
        raw_pointer,
    );
    errdefer pointer.deinit(allocator);
    var operand: Operand = switch (try decoder.readByte()) {
        0 => .{ .constant = try decodeCacheScalar(allocator, decoder) },
        1 => .{ .parameter = try decoder.readBytesAlloc(
            allocator,
            128,
        ) },
        else => return error.CacheProjectionOperandInvalid,
    };
    errdefer operand.deinit(allocator);
    if (operand == .parameter) {
        try definition_core.json.safeIdentifier(operand.parameter, 128);
    }
    return .{
        .pointer = pointer,
        .operand = operand,
    };
}

fn validateCachedPredicate(
    predicate: Predicate,
    definition_plan: *const definition.Plan,
) !void {
    if (predicate.operand == .parameter and
        definition_plan.parameter_declarations.find(
            predicate.operand.parameter,
        ) == null)
    {
        return error.CacheProjectionPlanMismatch;
    }
}

fn decodeCacheScalar(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Scalar {
    return switch (try decoder.readByte()) {
        0 => .{ .string = try decoder.readBytesAlloc(
            allocator,
            4 * 1024 * 1024,
        ) },
        1 => .{ .integer = try decoder.readI64() },
        2 => blk: {
            const number = try decoder.readF64();
            if (!std.math.isFinite(number)) return error.CacheNumberInvalid;
            break :blk .{ .float = number };
        },
        3 => .{ .boolean = try decoder.readBool() },
        4 => .null,
        5 => number: {
            const text = try decoder.readBytesAlloc(allocator, 1024);
            errdefer allocator.free(text);
            if (definition_core.exact_number.parse(text) == null) {
                return error.CacheNumberInvalid;
            }
            break :number .{ .number = text };
        },
        else => error.CacheProjectionScalarInvalid,
    };
}

fn compileProjection(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
    source: definition.NamedPlan,
) !Projection {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source.canonical_config,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        },
    );
    defer parsed.deinit();
    const object = try definition_core.json.object(parsed.value);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "slot", "scope", "pipeline", "exit", "required_parameters" },
    );
    try definition_core.json.requireFields(object, &.{ "slot", "pipeline" });
    const slot_index = storage_plan.findSlot(
        try definition_core.json.requiredString(object, "slot"),
    ) orelse return error.UnknownProjectionSlot;
    const source_scope = try compileSourceScope(object.get("scope"));
    const steps = try definition_core.json.array(
        try definition_core.json.field(object, "pipeline"),
    );
    if (steps.items.len == 0 or steps.items.len > 64) {
        return error.InvalidProjectionPipeline;
    }
    var compiler = try ProjectionCompiler.init(
        allocator,
        definition_plan,
        storage_plan,
        event_protocol,
        slot_index,
        source_scope,
        object.get("required_parameters"),
        object.get("exit"),
    );
    defer compiler.deinit();
    for (steps.items) |step_value| {
        try compiler.applyStep(step_value);
    }
    try compiler.validate();
    return compiler.finish(source.name);
}

fn compileSourceScope(raw: ?std.json.Value) !SourceScope {
    const raw_scope = raw orelse return .resolved;
    const text = try definition_core.json.string(raw_scope);
    if (std.mem.eql(u8, text, "resolved")) return .resolved;
    if (std.mem.eql(u8, text, "matching")) return .matching;
    return error.UnsupportedProjectionSourceScope;
}

const ProjectionCompiler = struct {
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
    slot_index: usize,
    source_scope: SourceScope,
    required_parameters: [][]u8,
    predicates: std.ArrayList(PredicateGroup) = .empty,
    fields: []Field,
    sort_keys: []SortKey,
    relevance: ?Relevance = null,
    latest: ?definition_core.json_pointer.Pointer = null,
    limit: ?Limit = null,
    fold: ?Fold = null,
    value_path: ?definition_core.json_pointer.Pointer = null,
    constructed_value: ?projection_value.Value = null,
    exit_policy: ExitPolicy,
    selection_seen: bool = false,
    preserve_field_order: bool = false,
    raw_export: bool = false,
    single: bool = false,
    require_match: bool = false,
    finished: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        definition_plan: *const definition.Plan,
        storage_plan: *const storage.Plan,
        event_protocol: ?*const protocol.Plan,
        slot_index: usize,
        source_scope: SourceScope,
        raw_parameters: ?std.json.Value,
        raw_exit: ?std.json.Value,
    ) !ProjectionCompiler {
        const required_parameters =
            try compileRequiredProjectionParameters(
                allocator,
                definition_plan,
                raw_parameters,
            );
        errdefer deinitNames(allocator, required_parameters);
        const fields = try allocator.alloc(Field, 0);
        errdefer allocator.free(fields);
        const sort_keys = try allocator.alloc(SortKey, 0);
        errdefer allocator.free(sort_keys);
        return .{
            .allocator = allocator,
            .definition_plan = definition_plan,
            .storage_plan = storage_plan,
            .event_protocol = event_protocol,
            .slot_index = slot_index,
            .source_scope = source_scope,
            .required_parameters = required_parameters,
            .fields = fields,
            .sort_keys = sort_keys,
            .exit_policy = try compileExitPolicy(raw_exit),
        };
    }

    fn deinit(self: *ProjectionCompiler) void {
        if (self.finished) return;
        deinitNames(self.allocator, self.required_parameters);
        for (self.predicates.items) |*group| group.deinit(self.allocator);
        self.predicates.deinit(self.allocator);
        deinitFields(self.allocator, self.fields);
        deinitSortKeys(self.allocator, self.sort_keys);
        if (self.relevance) |*value| value.deinit(self.allocator);
        if (self.latest) |*value| value.deinit(self.allocator);
        if (self.limit) |*value| value.deinit(self.allocator);
        if (self.fold) |*value| value.deinit(self.allocator);
        if (self.value_path) |*value| value.deinit(self.allocator);
        if (self.constructed_value) |*value| value.deinit(self.allocator);
        self.* = undefined;
    }

    fn applyStep(
        self: *ProjectionCompiler,
        step_value: std.json.Value,
    ) !void {
        const step = try definition_core.json.object(step_value);
        const operator = try definition.Operator.parse(
            try definition_core.json.requiredString(step, "op"),
        );
        if (!self.definition_plan.requires(operator)) {
            return error.UndeclaredArtifactOperator;
        }
        switch (operator) {
            .filter, .id_lookup => try self.applyFilter(operator, step),
            .latest => try self.applyLatest(step),
            .select => try self.applySelect(step),
            .relevance => try self.applyRelevance(step),
            .sort => try self.applySort(step),
            .fold => try self.applyFold(step),
            .limit => try self.applyLimit(step),
            .@"export" => try self.applyExport(step),
            else => return error.UnsupportedProjectionOperator,
        }
    }

    fn applyFilter(
        self: *ProjectionCompiler,
        operator: definition.Operator,
        step: std.json.ObjectMap,
    ) !void {
        if (self.fold != null) {
            if (self.selection_seen or self.latest != null or
                self.limit != null or self.sort_keys.len != 0 or
                self.relevance != null or self.fold.? != .keyed or
                (operator == .id_lookup and self.predicates.items.len != 0))
            {
                return error.InvalidProjectionOperatorOrder;
            }
        } else if (self.selection_seen or self.latest != null or
            self.limit != null or self.sort_keys.len != 0 or
            self.relevance != null)
        {
            return error.InvalidProjectionOperatorOrder;
        }
        var predicate = try compilePredicateGroup(
            self.allocator,
            self.definition_plan,
            operator,
            step,
        );
        errdefer predicate.deinit(self.allocator);
        try self.predicates.append(self.allocator, predicate);
        if (operator != .id_lookup) return;
        if (self.single) return error.DuplicateProjectionCardinality;
        self.single = true;
        self.require_match = if (step.get("required")) |value|
            try definition_core.json.boolean(value)
        else
            false;
    }

    fn applyLatest(
        self: *ProjectionCompiler,
        step: std.json.ObjectMap,
    ) !void {
        if (self.selection_seen or self.latest != null or
            self.limit != null or self.fold != null or self.single or
            self.sort_keys.len != 0)
        {
            return error.InvalidProjectionOperatorOrder;
        }
        try definition_core.json.requireExactKeys(
            step,
            &.{ "op", "path", "required" },
        );
        self.latest = try definition_core.json_pointer.compile(
            self.allocator,
            try definition_core.json.requiredString(step, "path"),
        );
        self.single = true;
        self.require_match = if (step.get("required")) |value|
            try definition_core.json.boolean(value)
        else
            false;
    }

    fn applySelect(
        self: *ProjectionCompiler,
        step: std.json.ObjectMap,
    ) !void {
        if (self.selection_seen or self.limit != null or self.fold != null) {
            return error.InvalidProjectionOperatorOrder;
        }
        self.fields = try compileFields(
            self.allocator,
            try definition_core.json.object(
                try definition_core.json.field(step, "fields"),
            ),
            step,
        );
        self.selection_seen = true;
    }

    fn applyRelevance(
        self: *ProjectionCompiler,
        step: std.json.ObjectMap,
    ) !void {
        if (self.selection_seen or self.latest != null or
            self.limit != null or self.fold != null or self.single or
            self.sort_keys.len != 0 or self.relevance != null)
        {
            return error.InvalidProjectionOperatorOrder;
        }
        self.relevance = try compileRelevance(
            self.allocator,
            self.definition_plan,
            step,
        );
    }

    fn applySort(
        self: *ProjectionCompiler,
        step: std.json.ObjectMap,
    ) !void {
        if (self.selection_seen or self.latest != null or
            self.limit != null or self.fold != null or self.single or
            self.sort_keys.len != 0)
        {
            return error.InvalidProjectionOperatorOrder;
        }
        self.sort_keys = try compileSortKeys(
            self.allocator,
            try definition_core.json.array(
                try definition_core.json.field(step, "keys"),
            ),
            step,
        );
    }

    fn applyFold(
        self: *ProjectionCompiler,
        step: std.json.ObjectMap,
    ) !void {
        if (self.selection_seen or self.predicates.items.len != 0 or
            self.latest != null or self.limit != null or self.fold != null or
            self.sort_keys.len != 0)
        {
            return error.InvalidProjectionOperatorOrder;
        }
        const event_protocol = self.event_protocol orelse
            return error.FoldRequiresReducerSlot;
        if (event_protocol.target_slot_index != self.slot_index) {
            return error.FoldRequiresReducerSlot;
        }
        if (step.get("fields")) |fields_value| {
            self.fold = .{ .retained = try self.compileRetainedFoldStep(
                event_protocol,
                step,
                fields_value,
            ) };
        } else {
            self.fold = .{ .keyed = try self.compileKeyedFoldStep(
                event_protocol,
                step,
            ) };
        }
    }

    fn compileRetainedFoldStep(
        self: *ProjectionCompiler,
        event_protocol: *const protocol.Plan,
        step: std.json.ObjectMap,
        fields_value: std.json.Value,
    ) !RetainedFold {
        try definition_core.json.requireExactKeys(
            step,
            &.{ "op", "fields" },
        );
        const retained_plan =
            if (event_protocol.state_reducer_plan) |*value|
                value
            else
                return error.FoldRequiresRetainedReducer;
        return .{ .fields = try compileRetainedFields(
            self.allocator,
            retained_plan,
            try definition_core.json.object(fields_value),
        ) };
    }

    fn compileKeyedFoldStep(
        self: *ProjectionCompiler,
        event_protocol: *const protocol.Plan,
        step: std.json.ObjectMap,
    ) !KeyedFold {
        if (event_protocol.reducer_plan == null) {
            return error.FoldRequiresKeyedReducer;
        }
        try requireKeyedFoldStep(step);
        const key_field = try definition_core.json.requiredString(
            step,
            "key_field",
        );
        const state_field = try definition_core.json.requiredString(
            step,
            "state_field",
        );
        try definition_core.json.safeIdentifier(key_field, 128);
        try definition_core.json.safeIdentifier(state_field, 128);
        const retained_field = try compileOptionalFieldName(
            self.allocator,
            step,
            "retained_field",
        );
        errdefer if (retained_field) |field| self.allocator.free(field);
        const event_count_field = try compileOptionalFieldName(
            self.allocator,
            step,
            "event_count_field",
        );
        errdefer if (event_count_field) |field| self.allocator.free(field);
        try validateKeyedFoldFields(
            key_field,
            state_field,
            retained_field,
            event_count_field,
            null,
            error.ProjectionFieldsConflict,
        );
        if (retained_field != null and
            event_protocol.reducer_plan.?.retain_once == null and
            event_protocol.reducer_plan.?.retain_latest == null)
        {
            return error.FoldRetainedFieldRequiresRetainedValue;
        }
        var history = try compileKeyedHistory(
            self.allocator,
            self.definition_plan,
            event_protocol,
            step,
        );
        errdefer history.deinit(self.allocator);
        try validateKeyedFoldFields(
            key_field,
            state_field,
            retained_field,
            event_count_field,
            &history,
            error.ProjectionFieldsConflict,
        );
        return self.ownKeyedFold(
            key_field,
            state_field,
            retained_field,
            event_count_field,
            history,
        );
    }

    fn ownKeyedFold(
        self: *ProjectionCompiler,
        key_field: []const u8,
        state_field: []const u8,
        retained_field: ?[]u8,
        event_count_field: ?[]u8,
        history: KeyedHistory,
    ) !KeyedFold {
        const owned_key = try self.allocator.dupe(u8, key_field);
        errdefer self.allocator.free(owned_key);
        const owned_state = try self.allocator.dupe(u8, state_field);
        return .{
            .key_field = owned_key,
            .state_field = owned_state,
            .retained_field = retained_field,
            .event_count_field = event_count_field,
            .history = history,
        };
    }

    fn applyLimit(
        self: *ProjectionCompiler,
        step: std.json.ObjectMap,
    ) !void {
        if (self.limit != null or self.single) {
            return error.InvalidProjectionOperatorOrder;
        }
        self.limit = try compileLimit(
            self.allocator,
            self.definition_plan,
            step,
        );
    }

    fn applyExport(
        self: *ProjectionCompiler,
        step: std.json.ObjectMap,
    ) !void {
        if (self.selection_seen or self.limit != null) {
            return error.InvalidProjectionOperatorOrder;
        }
        if (self.fold) |compiled_fold| switch (compiled_fold) {
            .keyed => if (!self.single or self.predicates.items.len != 1) {
                return error.InvalidProjectionOperatorOrder;
            },
            .retained => if (self.single or self.predicates.items.len != 0) {
                return error.InvalidProjectionOperatorOrder;
            },
        };
        if (self.fold != null and step.get("value") == null) {
            return error.FoldExportRequiresConstructedValue;
        }
        if (step.get("fields")) |field_values| {
            try self.applyOrderedExport(step, field_values);
        } else if (step.get("path")) |path_value| {
            try self.applyPathExport(step, path_value);
        } else if (step.get("value")) |value| {
            try self.applyConstructedExport(step, value);
        } else {
            try definition_core.json.requireExactKeys(
                step,
                &.{ "op", "raw" },
            );
            self.raw_export = if (step.get("raw")) |value|
                try definition_core.json.boolean(value)
            else
                false;
        }
        self.selection_seen = true;
    }

    fn applyOrderedExport(
        self: *ProjectionCompiler,
        step: std.json.ObjectMap,
        field_values: std.json.Value,
    ) !void {
        try definition_core.json.requireExactKeys(
            step,
            &.{ "op", "fields" },
        );
        self.fields = try compileOrderedFields(
            self.allocator,
            try definition_core.json.array(field_values),
            step,
        );
        self.preserve_field_order = true;
    }

    fn applyPathExport(
        self: *ProjectionCompiler,
        step: std.json.ObjectMap,
        path_value: std.json.Value,
    ) !void {
        try definition_core.json.requireExactKeys(
            step,
            &.{ "op", "path" },
        );
        self.value_path = try definition_core.json_pointer.compile(
            self.allocator,
            try definition_core.json.string(path_value),
        );
    }

    fn applyConstructedExport(
        self: *ProjectionCompiler,
        step: std.json.ObjectMap,
        value: std.json.Value,
    ) !void {
        try definition_core.json.requireExactKeys(
            step,
            &.{ "op", "value" },
        );
        self.constructed_value = try projection_value.compile(
            self.allocator,
            value,
            self.definition_plan.bounds.max_output_bytes,
        );
    }

    fn validate(self: *const ProjectionCompiler) !void {
        if (self.fold != null and
            self.fold.? == .retained and self.limit != null)
        {
            return error.RetainedFoldRejectsLimit;
        }
        try self.validateMatching();
        try self.validateRelevance();
        try self.validateFold();
    }

    fn validateMatching(self: *const ProjectionCompiler) !void {
        if (self.source_scope != .matching) return;
        const source_slot = self.storage_plan.slots[self.slot_index];
        if (source_slot.kind != .document or
            !storage.slotIsParameterized(source_slot) or
            self.latest == null or self.fold != null or
            self.relevance != null or self.sort_keys.len != 0 or
            self.predicates.items.len != 0 or self.limit != null)
        {
            return error.InvalidMatchingProjection;
        }
    }

    fn validateRelevance(self: *const ProjectionCompiler) !void {
        if (self.relevance) |relevance| {
            if (self.sort_keys.len == 0 or self.raw_export or
                self.value_path != null or self.constructed_value != null)
            {
                return error.RelevanceRequiresSortedStructuredProjection;
            }
            if (relevance.score_field) |score_field| {
                if (self.fields.len == 0) {
                    return error.RelevanceScoreRequiresProjectionFields;
                }
                for (self.fields) |field| {
                    if (std.mem.eql(u8, score_field, field.name)) {
                        return error.ProjectionFieldsNotUnique;
                    }
                }
            }
        }
        for (self.sort_keys) |key| {
            if (key.source == .relevance_score and self.relevance == null) {
                return error.RelevanceSortRequiresRelevanceOperator;
            }
        }
    }

    fn validateFold(self: *const ProjectionCompiler) !void {
        const fold = self.fold orelse return;
        if (fold != .keyed and self.predicates.items.len != 0) {
            return error.InvalidFoldProjectionComposition;
        }
        if (self.constructed_value == null) {
            if (self.fields.len != 0 or
                self.value_path != null or self.raw_export)
            {
                return error.InvalidFoldProjectionComposition;
            }
            return;
        }
        switch (fold) {
            .keyed => |keyed| try self.validateConstructedKeyedFold(keyed),
            .retained => {
                if (self.predicates.items.len != 0 or self.single or
                    self.require_match or self.fields.len != 0 or
                    self.value_path != null or self.raw_export or
                    self.limit != null)
                {
                    return error.InvalidFoldProjectionComposition;
                }
            },
        }
    }

    fn validateConstructedKeyedFold(
        self: *const ProjectionCompiler,
        keyed: KeyedFold,
    ) !void {
        if (self.predicates.items.len != 1 or
            !self.single or !self.require_match or
            self.fields.len != 0 or self.value_path != null or
            self.raw_export or self.limit != null)
        {
            return error.InvalidFoldProjectionComposition;
        }
        if (self.predicates.items[0] != .one) {
            return error.FoldLookupRequiresSinglePredicate;
        }
        const predicate = self.predicates.items[0].one;
        if (predicate.operand != .parameter) {
            return error.FoldLookupRequiresParameter;
        }
        var expected_path: [130]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &expected_path,
            "/{s}",
            .{keyed.key_field},
        );
        if (!std.mem.eql(u8, predicate.pointer.raw, path)) {
            return error.FoldLookupMustUseKeyField;
        }
    }

    fn finish(
        self: *ProjectionCompiler,
        name: []const u8,
    ) !Projection {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const predicates =
            try self.predicates.toOwnedSlice(self.allocator);
        const result: Projection = .{
            .name = owned_name,
            .slot_index = @intCast(self.slot_index),
            .source_scope = self.source_scope,
            .required_parameters = self.required_parameters,
            .predicates = predicates,
            .fields = self.fields,
            .preserve_field_order = self.preserve_field_order,
            .raw = self.raw_export,
            .value_path = self.value_path,
            .constructed_value = self.constructed_value,
            .single = self.single,
            .require_match = self.require_match,
            .sort_keys = self.sort_keys,
            .relevance = self.relevance,
            .latest = self.latest,
            .limit = self.limit,
            .fold = self.fold,
            .exit_policy = self.exit_policy,
        };
        self.finished = true;
        return result;
    }
};

fn requireKeyedFoldStep(step: std.json.ObjectMap) !void {
    try definition_core.json.requireExactKeys(
        step,
        &.{
            "op",
            "key_field",
            "state_field",
            "retained_field",
            "event_count_field",
            "event_kind_counts",
            "event_chain",
            "snapshot",
        },
    );
    try definition_core.json.requireFields(
        step,
        &.{ "op", "key_field", "state_field" },
    );
}

fn compileExitPolicy(raw: ?std.json.Value) !ExitPolicy {
    const value = raw orelse return .{};
    const object = try definition_core.json.object(value);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "matched", "unmatched", "failure" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "matched", "unmatched", "failure" },
    );
    const matched = try projectionExitCode(
        try definition_core.json.unsigned(object.get("matched").?),
    );
    const unmatched = try projectionExitCode(
        try definition_core.json.unsigned(object.get("unmatched").?),
    );
    const failure = try projectionExitCode(
        try definition_core.json.unsigned(object.get("failure").?),
    );
    if (matched == unmatched or failure == matched or failure == unmatched) {
        return error.ProjectionExitCodesMustBeDistinct;
    }
    return .{
        .matched = matched,
        .unmatched = unmatched,
        .failure = failure,
    };
}

fn compileRequiredProjectionParameters(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    raw: ?std.json.Value,
) ![][]u8 {
    const value = raw orelse return allocator.alloc([]u8, 0);
    const items = try definition_core.json.array(value);
    if (items.items.len > 64) {
        return error.ProjectionRequiredParametersInvalid;
    }
    const names = try allocator.alloc([]u8, items.items.len);
    var initialized: usize = 0;
    errdefer {
        for (names[0..initialized]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (items.items) |item| {
        const name = try definition_core.json.string(item);
        if (definition_plan.parameter_declarations.find(name) == null) {
            return error.UnknownProjectionParameter;
        }
        names[initialized] = try allocator.dupe(u8, name);
        initialized += 1;
    }
    std.sort.heap([]u8, names, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    for (names[1..], 1..) |name, index| {
        if (std.mem.eql(u8, names[index - 1], name)) {
            return error.ProjectionRequiredParametersNotUnique;
        }
    }
    return names;
}

fn projectionExitCode(value: usize) !u8 {
    if (value > 125) return error.ProjectionExitCodeInvalid;
    return @intCast(value);
}

fn compilePredicateGroup(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    operator: definition.Operator,
    object: std.json.ObjectMap,
) !PredicateGroup {
    if (operator == .filter and object.get("any") != null) {
        try definition_core.json.requireExactKeys(
            object,
            &.{ "op", "any" },
        );
        const values = try definition_core.json.array(object.get("any").?);
        if (values.items.len == 0 or values.items.len > 64) {
            return error.InvalidProjectionPredicateGroup;
        }
        const sets = try allocator.alloc(PredicateSet, values.items.len);
        var initialized: usize = 0;
        errdefer {
            for (sets[0..initialized]) |*set| {
                set.deinit(allocator);
            }
            allocator.free(sets);
        }
        for (values.items) |value| {
            const branch = try definition_core.json.object(value);
            if (branch.get("all")) |raw_all| {
                try definition_core.json.requireExactKeys(
                    branch,
                    &.{"all"},
                );
                sets[initialized] = .{
                    .predicates = try compilePredicateSet(
                        allocator,
                        definition_plan,
                        try definition_core.json.array(raw_all),
                    ),
                };
            } else {
                var predicate = try compileScalarPredicate(
                    allocator,
                    definition_plan,
                    .filter,
                    branch,
                    false,
                );
                errdefer predicate.deinit(allocator);
                const singleton = try allocator.alloc(Predicate, 1);
                singleton[0] = predicate;
                sets[initialized] = .{ .predicates = singleton };
            }
            initialized += 1;
        }
        return .{ .any = sets };
    }
    return .{ .one = try compileScalarPredicate(
        allocator,
        definition_plan,
        operator,
        object,
        true,
    ) };
}

fn compilePredicateSet(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    values: std.json.Array,
) ![]Predicate {
    if (values.items.len == 0 or values.items.len > 64) {
        return error.InvalidProjectionPredicateGroup;
    }
    const predicates = try allocator.alloc(Predicate, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (predicates[0..initialized]) |*predicate| {
            predicate.deinit(allocator);
        }
        allocator.free(predicates);
    }
    for (values.items) |value| {
        predicates[initialized] = try compileScalarPredicate(
            allocator,
            definition_plan,
            .filter,
            try definition_core.json.object(value),
            false,
        );
        initialized += 1;
    }
    return predicates;
}

fn compileScalarPredicate(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    operator: definition.Operator,
    object: std.json.ObjectMap,
    has_operator: bool,
) !Predicate {
    const pointer = try definition_core.json_pointer.compile(
        allocator,
        try definition_core.json.requiredString(object, "path"),
    );
    errdefer {
        var owned = pointer;
        owned.deinit(allocator);
    }
    const operand: Operand = switch (operator) {
        .filter => blk: {
            try definition_core.json.requireExactKeys(
                object,
                if (has_operator)
                    &.{ "op", "path", "equals", "param" }
                else
                    &.{ "path", "equals", "param" },
            );
            const fixed = object.get("equals");
            const parameter = object.get("param");
            if ((fixed == null) == (parameter == null)) {
                return error.InvalidProjectionPredicate;
            }
            if (fixed) |value| {
                break :blk .{
                    .constant = try scalarFromJsonAlloc(allocator, value),
                };
            }
            const name = try definition_core.json.string(parameter.?);
            if (definition_plan.parameter_declarations.find(name) == null) {
                return error.UnknownProjectionParameter;
            }
            break :blk .{ .parameter = try allocator.dupe(u8, name) };
        },
        .id_lookup => blk: {
            if (!has_operator) return error.InvalidProjectionPredicate;
            try definition_core.json.requireExactKeys(
                object,
                &.{ "op", "path", "param", "required" },
            );
            const name = try definition_core.json.requiredString(
                object,
                "param",
            );
            if (definition_plan.parameter_declarations.find(name) == null) {
                return error.UnknownProjectionParameter;
            }
            break :blk .{ .parameter = try allocator.dupe(u8, name) };
        },
        else => unreachable,
    };
    return .{
        .pointer = pointer,
        .operand = operand,
    };
}

fn compileRelevance(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !Relevance {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "paths", "param", "mode", "score_field", "ranking" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "op", "paths", "param", "mode" },
    );
    const paths = try compileRelevancePaths(allocator, object);
    errdefer {
        for (paths) |*path| path.deinit(allocator);
        allocator.free(paths);
    }
    const raw_parameter = try relevanceParameter(definition_plan, object);
    const parameter = try allocator.dupe(u8, raw_parameter);
    errdefer allocator.free(parameter);
    const raw_mode = try definition_core.json.requiredString(object, "mode");
    const mode = try parseRelevanceMode(raw_mode);
    const score_field = try compileRelevanceScoreField(allocator, object);
    errdefer if (score_field) |field| allocator.free(field);
    var ranked_plan = if (object.get("ranking")) |value|
        try ranked_relevance.compile(
            allocator,
            value,
            &definition_plan.parameter_declarations,
        )
    else
        null;
    errdefer if (ranked_plan) |*plan| plan.deinit(allocator);
    if ((mode == .ranked_tokens) != (ranked_plan != null)) {
        return error.InvalidProjectionRelevanceMode;
    }
    return .{
        .paths = paths,
        .parameter = parameter,
        .mode = mode,
        .score_field = score_field,
        .ranked_plan = ranked_plan,
    };
}

fn compileRelevancePaths(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) ![]definition_core.json_pointer.Pointer {
    const values = try definition_core.json.array(
        try definition_core.json.field(object, "paths"),
    );
    if (values.items.len == 0 or values.items.len > 64) {
        return error.InvalidProjectionRelevancePaths;
    }
    const paths = try allocator.alloc(
        definition_core.json_pointer.Pointer,
        values.items.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (paths[0..initialized]) |*path| path.deinit(allocator);
        allocator.free(paths);
    }
    for (values.items, 0..) |value, index| {
        paths[index] = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.string(value),
        );
        initialized += 1;
    }
    return paths;
}

fn relevanceParameter(
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) ![]const u8 {
    const name = try definition_core.json.requiredString(object, "param");
    const declaration = definition_plan.parameter_declarations.find(name) orelse
        return error.UnknownProjectionParameter;
    if (declaration.kind != .string) {
        return error.ProjectionRelevanceParameterMustBeString;
    }
    return name;
}

fn parseRelevanceMode(raw: []const u8) !RelevanceMode {
    if (std.mem.eql(u8, raw, "literal")) return .literal;
    if (std.mem.eql(u8, raw, "tokens")) return .tokens;
    if (std.mem.eql(u8, raw, "ranked-tokens")) return .ranked_tokens;
    return error.InvalidProjectionRelevanceMode;
}

fn compileRelevanceScoreField(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !?[]u8 {
    const value = object.get("score_field") orelse return null;
    const raw = try definition_core.json.string(value);
    try definition_core.json.safeIdentifier(raw, 128);
    return try allocator.dupe(u8, raw);
}

fn compileSortKeys(
    allocator: std.mem.Allocator,
    values: std.json.Array,
    step: std.json.ObjectMap,
) ![]SortKey {
    try definition_core.json.requireExactKeys(step, &.{ "op", "keys" });
    if (values.items.len == 0 or values.items.len > 8) {
        return error.InvalidProjectionSortKeys;
    }
    const keys = try allocator.alloc(SortKey, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (keys[0..initialized]) |*key| key.deinit(allocator);
        allocator.free(keys);
    }
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "path", "meta", "order" },
        );
        const raw_path = object.get("path");
        const raw_meta = object.get("meta");
        if ((raw_path == null) == (raw_meta == null)) {
            return error.InvalidProjectionSortSource;
        }
        const source: SortSource = if (raw_path) |path|
            .{ .pointer = try definition_core.json_pointer.compile(
                allocator,
                try definition_core.json.string(path),
            ) }
        else meta: {
            const name = try definition_core.json.string(raw_meta.?);
            if (std.mem.eql(u8, name, "record-order")) {
                break :meta .record_order;
            }
            if (std.mem.eql(u8, name, "relevance-score")) {
                break :meta .relevance_score;
            }
            return error.InvalidProjectionSortSource;
        };
        errdefer if (source == .pointer) {
            var pointer = source.pointer;
            pointer.deinit(allocator);
        };
        const raw_order = try definition_core.json.requiredString(
            object,
            "order",
        );
        const order: SortOrder =
            if (std.mem.eql(u8, raw_order, "ascending"))
                .ascending
            else if (std.mem.eql(u8, raw_order, "descending"))
                .descending
            else
                return error.InvalidProjectionSortOrder;
        keys[index] = .{ .source = source, .order = order };
        initialized += 1;
    }
    return keys;
}

fn compileOptionalFieldName(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]u8 {
    const value = object.get(key) orelse return null;
    const name = try definition_core.json.string(value);
    try definition_core.json.safeIdentifier(name, 128);
    return try allocator.dupe(u8, name);
}

const FoldDigestContext = enum {
    event_chain,
    snapshot,
};

fn compileKeyedHistory(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    event_protocol: *const protocol.Plan,
    step: std.json.ObjectMap,
) !KeyedHistory {
    const event_kind_counts =
        if (step.get("event_kind_counts")) |raw|
            try compileFoldEventKindCounts(
                allocator,
                event_protocol,
                raw,
            )
        else
            try allocator.alloc(FoldEventKindCount, 0);
    errdefer {
        for (event_kind_counts) |*count| count.deinit(allocator);
        allocator.free(event_kind_counts);
    }
    var event_chain = if (step.get("event_chain")) |raw| blk: {
        if (!definition_plan.requires(.sha256)) {
            return error.UndeclaredArtifactOperator;
        }
        break :blk try compileFoldEventChain(allocator, raw);
    } else null;
    errdefer if (event_chain) |*chain| chain.deinit(allocator);
    var snapshot = if (step.get("snapshot")) |raw| blk: {
        if (!definition_plan.requires(.sha256)) {
            return error.UndeclaredArtifactOperator;
        }
        break :blk try compileFoldSnapshot(
            allocator,
            event_protocol,
            raw,
        );
    } else null;
    errdefer if (snapshot) |*compiled| compiled.deinit(allocator);
    if (snapshot != null and event_chain == null) {
        return error.FoldSnapshotRequiresEventChain;
    }
    const result: KeyedHistory = .{
        .event_kind_counts = event_kind_counts,
        .event_chain = event_chain,
        .snapshot = snapshot,
    };
    if (result.active()) {
        const reducer_plan = event_protocol.reducer_plan orelse
            return error.FoldHistoryRequiresKeyedReducer;
        if (reducer_plan.event_kind == null) {
            return error.FoldHistoryRequiresEventKind;
        }
    }
    return result;
}

fn compileFoldEventKindCounts(
    allocator: std.mem.Allocator,
    event_protocol: *const protocol.Plan,
    raw: std.json.Value,
) ![]FoldEventKindCount {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or
        values.items.len > max_fold_event_kind_counts)
    {
        return error.InvalidFoldEventKindCounts;
    }
    const counts = try allocator.alloc(
        FoldEventKindCount,
        values.items.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (counts[0..initialized]) |*count| count.deinit(allocator);
        allocator.free(counts);
    }
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "kind", "field" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "kind", "field" },
        );
        const kind = try definition_core.json.requiredString(
            object,
            "kind",
        );
        if (!containsEventKind(event_protocol.event_kinds, kind)) {
            return error.UnknownFoldEventKind;
        }
        const field = try definition_core.json.requiredString(
            object,
            "field",
        );
        try definition_core.json.safeIdentifier(field, 128);
        const owned_kind = try allocator.dupe(u8, kind);
        errdefer allocator.free(owned_kind);
        const owned_field = try allocator.dupe(u8, field);
        errdefer allocator.free(owned_field);
        counts[index] = .{
            .kind = owned_kind,
            .field = owned_field,
        };
        initialized += 1;
    }
    std.sort.heap(FoldEventKindCount, counts, {}, struct {
        fn lessThan(
            _: void,
            left: FoldEventKindCount,
            right: FoldEventKindCount,
        ) bool {
            return std.mem.lessThan(u8, left.kind, right.kind);
        }
    }.lessThan);
    for (counts[1..], 1..) |count, index| {
        if (std.mem.eql(u8, counts[index - 1].kind, count.kind)) {
            return error.DuplicateFoldEventKind;
        }
    }
    return counts;
}

fn compileFoldEventChain(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) !FoldEventChain {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "field", "fragments" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "field", "fragments" },
    );
    const field = try definition_core.json.requiredString(object, "field");
    try definition_core.json.safeIdentifier(field, 128);
    const owned_field = try allocator.dupe(u8, field);
    errdefer allocator.free(owned_field);
    return .{
        .field = owned_field,
        .digest = try compileFoldDigest(
            allocator,
            try definition_core.json.field(object, "fragments"),
            .event_chain,
        ),
    };
}

fn compileFoldSnapshot(
    allocator: std.mem.Allocator,
    event_protocol: *const protocol.Plan,
    raw: std.json.Value,
) !FoldSnapshot {
    const object = try definition_core.json.object(raw);
    try definition_core.json.requireExactKeys(
        object,
        &.{ "field", "prior_field", "prior_on", "fragments" },
    );
    try definition_core.json.requireFields(
        object,
        &.{ "field", "prior_field", "prior_on", "fragments" },
    );
    const field = try definition_core.json.requiredString(object, "field");
    const prior_field = try definition_core.json.requiredString(
        object,
        "prior_field",
    );
    try definition_core.json.safeIdentifier(field, 128);
    try definition_core.json.safeIdentifier(prior_field, 128);
    if (std.mem.eql(u8, field, prior_field)) {
        return error.ProjectionFieldsConflict;
    }
    const owned_field = try allocator.dupe(u8, field);
    errdefer allocator.free(owned_field);
    const owned_prior_field = try allocator.dupe(u8, prior_field);
    errdefer allocator.free(owned_prior_field);
    const prior_on = try compileFoldEventKindSet(
        allocator,
        event_protocol,
        try definition_core.json.field(object, "prior_on"),
    );
    errdefer {
        for (prior_on) |kind| allocator.free(kind);
        allocator.free(prior_on);
    }
    return .{
        .field = owned_field,
        .prior_field = owned_prior_field,
        .prior_on = prior_on,
        .digest = try compileFoldDigest(
            allocator,
            try definition_core.json.field(object, "fragments"),
            .snapshot,
        ),
    };
}

fn compileFoldEventKindSet(
    allocator: std.mem.Allocator,
    event_protocol: *const protocol.Plan,
    raw: std.json.Value,
) ![][]u8 {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or
        values.items.len > max_fold_event_kind_counts)
    {
        return error.InvalidFoldEventKindSet;
    }
    const result = try allocator.alloc([]u8, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values.items, 0..) |value, index| {
        const kind = try definition_core.json.string(value);
        if (!containsEventKind(event_protocol.event_kinds, kind)) {
            return error.UnknownFoldEventKind;
        }
        result[index] = try allocator.dupe(u8, kind);
        initialized += 1;
    }
    std.sort.heap([]u8, result, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    for (result[1..], 1..) |value, index| {
        if (std.mem.eql(u8, result[index - 1], value)) {
            return error.DuplicateFoldEventKind;
        }
    }
    return result;
}

fn compileFoldDigest(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    context: FoldDigestContext,
) !FoldDigest {
    const values = try definition_core.json.array(raw);
    if (values.items.len == 0 or
        values.items.len > max_fold_digest_fragments)
    {
        return error.InvalidFoldDigestFragments;
    }
    const fragments = try allocator.alloc(
        FoldDigestFragment,
        values.items.len,
    );
    var initialized: usize = 0;
    errdefer {
        for (fragments[0..initialized]) |*fragment| {
            fragment.deinit(allocator);
        }
        allocator.free(fragments);
    }
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "literal", "source", "retained_text" },
        );
        const source_count =
            @as(usize, @intFromBool(object.get("literal") != null)) +
            @as(usize, @intFromBool(object.get("source") != null)) +
            @as(usize, @intFromBool(object.get("retained_text") != null));
        if (source_count != 1) return error.InvalidFoldDigestFragment;
        if (object.get("literal")) |literal_value| {
            const literal = try definition_core.json.string(literal_value);
            if (literal.len > max_fold_digest_literal_bytes or
                !std.unicode.utf8ValidateSlice(literal))
            {
                return error.InvalidFoldDigestLiteral;
            }
            fragments[index] = .{
                .literal = try allocator.dupe(u8, literal),
            };
        } else if (object.get("source")) |source_value| {
            const source = try parseFoldDigestSource(
                try definition_core.json.string(source_value),
            );
            if (!foldDigestSourceAllowed(context, source)) {
                return error.FoldDigestSourceNotAllowed;
            }
            fragments[index] = .{ .source = source };
        } else {
            if (context != .snapshot) {
                return error.FoldDigestSourceNotAllowed;
            }
            fragments[index] = .{
                .retained_text = try definition_core.json_pointer.compile(
                    allocator,
                    try definition_core.json.string(
                        object.get("retained_text").?,
                    ),
                ),
            };
        }
        initialized += 1;
    }
    return .{ .fragments = fragments };
}

fn parseFoldDigestSource(raw: []const u8) !FoldDigestSource {
    if (std.mem.eql(u8, raw, "previous-event-chain")) {
        return .previous_event_chain;
    }
    if (std.mem.eql(u8, raw, "event-bytes")) return .event_bytes;
    if (std.mem.eql(u8, raw, "key")) return .key;
    if (std.mem.eql(u8, raw, "state")) return .state;
    if (std.mem.eql(u8, raw, "retained")) return .retained;
    if (std.mem.eql(u8, raw, "event-chain")) return .event_chain;
    return error.UnknownFoldDigestSource;
}

fn foldDigestSourceAllowed(
    context: FoldDigestContext,
    source: FoldDigestSource,
) bool {
    return switch (context) {
        .event_chain => source == .previous_event_chain or
            source == .event_bytes,
        .snapshot => source == .key or source == .state or
            source == .retained or source == .event_chain,
    };
}

fn containsEventKind(
    kinds: []const []u8,
    expected: []const u8,
) bool {
    for (kinds) |kind| {
        if (std.mem.eql(u8, kind, expected)) return true;
    }
    return false;
}

fn containsSortedBytes(
    values: []const []u8,
    expected: []const u8,
) bool {
    var low: usize = 0;
    var high = values.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, values[middle], expected)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return true,
        }
    }
    return false;
}

fn digestFoldEventChain(
    digest: FoldDigest,
    entry: *const FoldHistoryEntry,
    raw: []const u8,
) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (digest.fragments) |fragment| switch (fragment) {
        .literal => |literal| hasher.update(literal),
        .source => |source| switch (source) {
            .previous_event_chain => if (entry.has_event_chain) {
                hasher.update(&entry.event_chain);
            },
            .event_bytes => hasher.update(raw),
            else => unreachable,
        },
        .retained_text => unreachable,
    };
    var bytes: [32]u8 = undefined;
    hasher.final(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn digestFoldSnapshot(
    digest: FoldDigest,
    entry: *const FoldHistoryEntry,
    view: reducer.EntryView,
) ![64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (digest.fragments, 0..) |fragment, index| switch (fragment) {
        .literal => |literal| hasher.update(literal),
        .source => |source| switch (source) {
            .key => hasher.update(view.key),
            .state => hasher.update(view.state),
            .retained => hasher.update(
                view.retained orelse
                    return error.FoldHistoryRetainedValueMissing,
            ),
            .event_chain => {
                if (!entry.has_event_chain) {
                    return error.FoldHistoryEventChainMissing;
                }
                hasher.update(&entry.event_chain);
            },
            else => unreachable,
        },
        .retained_text => {
            hasher.update(
                entry.retained_text[index] orelse
                    return error.FoldHistoryRetainedValueMissing,
            );
        },
    };
    var bytes: [32]u8 = undefined;
    hasher.final(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn encodeKeyedHistory(
    history: *const KeyedHistory,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(history.event_kind_counts.len);
    for (history.event_kind_counts) |count| {
        try encoder.writeBytes(count.kind);
        try encoder.writeBytes(count.field);
    }
    try encoder.writeBool(history.event_chain != null);
    if (history.event_chain) |chain| {
        try encoder.writeBytes(chain.field);
        try encodeFoldDigest(chain.digest, encoder);
    }
    try encoder.writeBool(history.snapshot != null);
    if (history.snapshot) |snapshot| {
        try encoder.writeBytes(snapshot.field);
        try encoder.writeBytes(snapshot.prior_field);
        try encoder.writeCount(snapshot.prior_on.len);
        for (snapshot.prior_on) |kind| try encoder.writeBytes(kind);
        try encodeFoldDigest(snapshot.digest, encoder);
    }
}

fn encodeFoldDigest(
    digest: FoldDigest,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeCount(digest.fragments.len);
    for (digest.fragments) |fragment| switch (fragment) {
        .literal => |literal| {
            try encoder.writeByte(0);
            try encoder.writeBytes(literal);
        },
        .source => |source| {
            try encoder.writeByte(1);
            try encoder.writeEnum(source);
        },
        .retained_text => |pointer| {
            try encoder.writeByte(2);
            try encoder.writeBytes(pointer.raw);
        },
    };
}

fn decodeKeyedHistory(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !KeyedHistory {
    const event_kind_counts = try decodeFoldEventKindCounts(
        allocator,
        decoder,
    );
    errdefer deinitFoldEventKindCounts(allocator, event_kind_counts);
    var event_chain = try decodeFoldEventChain(allocator, decoder);
    errdefer if (event_chain) |*chain| chain.deinit(allocator);
    var snapshot = try decodeFoldSnapshot(allocator, decoder);
    errdefer if (snapshot) |*compiled| compiled.deinit(allocator);
    if (snapshot != null and event_chain == null) {
        return error.CacheFoldSnapshotRequiresEventChain;
    }
    return .{
        .event_kind_counts = event_kind_counts,
        .event_chain = event_chain,
        .snapshot = snapshot,
    };
}

fn deinitFoldEventKindCounts(
    allocator: std.mem.Allocator,
    counts: []FoldEventKindCount,
) void {
    for (counts) |*item| item.deinit(allocator);
    allocator.free(counts);
}

fn decodeFoldEventKindCounts(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![]FoldEventKindCount {
    const count = try decoder.readCount(max_fold_event_kind_counts);
    const items = try allocator.alloc(FoldEventKindCount, count);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    for (items, 0..) |*item, index| {
        const kind = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(kind);
        try definition_core.json.safeIdentifier(kind, 128);
        if (index != 0 and
            std.mem.order(u8, items[index - 1].kind, kind) != .lt)
        {
            return error.CacheFoldEventKindsNotSorted;
        }
        const field = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(field);
        try definition_core.json.safeIdentifier(field, 128);
        item.* = .{ .kind = kind, .field = field };
        initialized += 1;
    }
    return items;
}

fn decodeFoldEventChain(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?FoldEventChain {
    if (!try decoder.readBool()) return null;
    const field = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(field);
    try definition_core.json.safeIdentifier(field, 128);
    return .{
        .field = field,
        .digest = try decodeFoldDigest(
            allocator,
            decoder,
            .event_chain,
        ),
    };
}

fn decodeFoldSnapshot(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !?FoldSnapshot {
    if (!try decoder.readBool()) return null;
    const field = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(field);
    try definition_core.json.safeIdentifier(field, 128);
    const prior_field = try decoder.readBytesAlloc(allocator, 128);
    errdefer allocator.free(prior_field);
    try definition_core.json.safeIdentifier(prior_field, 128);
    if (std.mem.eql(u8, field, prior_field)) {
        return error.CacheProjectionFieldsConflict;
    }
    const prior_on = try decodeFoldPriorKinds(allocator, decoder);
    errdefer deinitNames(allocator, prior_on);
    return .{
        .field = field,
        .prior_field = prior_field,
        .prior_on = prior_on,
        .digest = try decodeFoldDigest(
            allocator,
            decoder,
            .snapshot,
        ),
    };
}

fn decodeFoldPriorKinds(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) ![][]u8 {
    const count = try decoder.readCount(max_fold_event_kind_counts);
    if (count == 0) return error.CacheFoldPriorKindsInvalid;
    const kinds = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (kinds[0..initialized]) |kind| allocator.free(kind);
        allocator.free(kinds);
    }
    for (kinds, 0..) |*kind, index| {
        kind.* = try decoder.readBytesAlloc(allocator, 128);
        initialized += 1;
        try definition_core.json.safeIdentifier(kind.*, 128);
        if (index != 0 and
            std.mem.order(u8, kinds[index - 1], kind.*) != .lt)
        {
            return error.CacheFoldPriorKindsNotSorted;
        }
    }
    return kinds;
}

fn decodeFoldDigest(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    context: FoldDigestContext,
) !FoldDigest {
    const count = try decoder.readCount(max_fold_digest_fragments);
    if (count == 0) return error.CacheFoldDigestFragmentsInvalid;
    const fragments = try allocator.alloc(FoldDigestFragment, count);
    var initialized: usize = 0;
    errdefer {
        for (fragments[0..initialized]) |*fragment| {
            fragment.deinit(allocator);
        }
        allocator.free(fragments);
    }
    for (fragments) |*fragment| {
        fragment.* = switch (try decoder.readByte()) {
            0 => literal: {
                const literal = try decoder.readBytesAlloc(
                    allocator,
                    max_fold_digest_literal_bytes,
                );
                errdefer allocator.free(literal);
                if (!std.unicode.utf8ValidateSlice(literal)) {
                    return error.CacheFoldDigestLiteralInvalid;
                }
                break :literal .{ .literal = literal };
            },
            1 => source: {
                const source = try decoder.readEnum(FoldDigestSource);
                if (!foldDigestSourceAllowed(context, source)) {
                    return error.CacheFoldDigestSourceInvalid;
                }
                break :source .{ .source = source };
            },
            2 => pointer: {
                if (context != .snapshot) {
                    return error.CacheFoldDigestSourceInvalid;
                }
                const raw = try decoder.readBytesAlloc(allocator, 1024);
                defer allocator.free(raw);
                break :pointer .{
                    .retained_text = try definition_core.json_pointer.compile(
                        allocator,
                        raw,
                    ),
                };
            },
            else => return error.CacheFoldDigestFragmentInvalid,
        };
        initialized += 1;
    }
    return .{ .fragments = fragments };
}

fn validateKeyedHistory(
    history: *const KeyedHistory,
    definition_plan: *const definition.Plan,
    event_protocol: *const protocol.Plan,
    comptime invalid: anyerror,
) !void {
    if ((history.event_chain != null or history.snapshot != null) and
        !definition_plan.requires(.sha256))
    {
        return invalid;
    }
    if (history.event_kind_counts.len > max_fold_event_kind_counts) {
        return invalid;
    }
    for (history.event_kind_counts, 0..) |count, index| {
        if (!containsEventKind(event_protocol.event_kinds, count.kind)) {
            return invalid;
        }
        try definition_core.json.safeIdentifier(count.field, 128);
        if (index != 0 and std.mem.order(
            u8,
            history.event_kind_counts[index - 1].kind,
            count.kind,
        ) != .lt) return invalid;
    }
    if (history.event_chain) |chain| {
        try definition_core.json.safeIdentifier(chain.field, 128);
        try validateFoldDigest(
            chain.digest,
            .event_chain,
            invalid,
        );
    }
    if (history.snapshot) |snapshot| {
        if (history.event_chain == null or snapshot.prior_on.len == 0 or
            snapshot.prior_on.len > max_fold_event_kind_counts)
        {
            return invalid;
        }
        try definition_core.json.safeIdentifier(snapshot.field, 128);
        try definition_core.json.safeIdentifier(
            snapshot.prior_field,
            128,
        );
        if (std.mem.eql(u8, snapshot.field, snapshot.prior_field)) {
            return invalid;
        }
        for (snapshot.prior_on, 0..) |kind, index| {
            if (!containsEventKind(event_protocol.event_kinds, kind)) {
                return invalid;
            }
            if (index != 0 and std.mem.order(
                u8,
                snapshot.prior_on[index - 1],
                kind,
            ) != .lt) return invalid;
        }
        try validateFoldDigest(snapshot.digest, .snapshot, invalid);
    }
}

fn validateFoldDigest(
    digest: FoldDigest,
    context: FoldDigestContext,
    comptime invalid: anyerror,
) !void {
    if (digest.fragments.len == 0 or
        digest.fragments.len > max_fold_digest_fragments)
    {
        return invalid;
    }
    for (digest.fragments) |fragment| switch (fragment) {
        .literal => |literal| {
            if (literal.len > max_fold_digest_literal_bytes or
                !std.unicode.utf8ValidateSlice(literal))
            {
                return invalid;
            }
        },
        .source => |source| {
            if (!foldDigestSourceAllowed(context, source)) return invalid;
        },
        .retained_text => |pointer| {
            if (context != .snapshot or
                pointer.raw.len > 1024)
            {
                return invalid;
            }
        },
    };
}

fn validateKeyedFoldFields(
    key_field: []const u8,
    state_field: []const u8,
    retained_field: ?[]const u8,
    event_count_field: ?[]const u8,
    history: ?*const KeyedHistory,
    comptime conflict: anyerror,
) !void {
    var fields: [4 + max_fold_event_kind_counts + 3][]const u8 =
        undefined;
    var count: usize = 0;
    fields[count] = key_field;
    count += 1;
    fields[count] = state_field;
    count += 1;
    if (retained_field) |field| {
        fields[count] = field;
        count += 1;
    }
    if (event_count_field) |field| {
        fields[count] = field;
        count += 1;
    }
    if (history) |configured| {
        for (configured.event_kind_counts) |item| {
            fields[count] = item.field;
            count += 1;
        }
        if (configured.event_chain) |chain| {
            fields[count] = chain.field;
            count += 1;
        }
        if (configured.snapshot) |snapshot| {
            fields[count] = snapshot.field;
            count += 1;
            fields[count] = snapshot.prior_field;
            count += 1;
        }
    }
    for (fields[0..count], 0..) |field, index| {
        try definition_core.json.safeIdentifier(field, 128);
        for (fields[0..index]) |prior| {
            if (std.mem.eql(u8, prior, field)) return conflict;
        }
    }
}

fn compileFields(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    step: std.json.ObjectMap,
) ![]Field {
    try definition_core.json.requireExactKeys(step, &.{ "op", "fields" });
    if (object.count() == 0 or object.count() > 256) {
        return error.InvalidProjectionFields;
    }
    var fields: std.ArrayList(Field) = .empty;
    errdefer {
        for (fields.items) |*field| field.deinit(allocator);
        fields.deinit(allocator);
    }
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try definition_core.json.safeIdentifier(entry.key_ptr.*, 128);
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.string(entry.value_ptr.*),
        );
        errdefer pointer.deinit(allocator);
        try fields.append(allocator, .{ .name = name, .pointer = pointer });
    }
    std.sort.heap(Field, fields.items, {}, struct {
        fn lessThan(_: void, left: Field, right: Field) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return fields.toOwnedSlice(allocator);
}

fn compileOrderedFields(
    allocator: std.mem.Allocator,
    values: std.json.Array,
    step: std.json.ObjectMap,
) ![]Field {
    try definition_core.json.requireExactKeys(step, &.{ "op", "fields" });
    if (values.items.len == 0 or values.items.len > 256) {
        return error.InvalidProjectionFields;
    }
    const fields = try allocator.alloc(Field, values.items.len);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |*field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (values.items, 0..) |value, index| {
        const object = try definition_core.json.object(value);
        try definition_core.json.requireExactKeys(
            object,
            &.{ "name", "path" },
        );
        try definition_core.json.requireFields(
            object,
            &.{ "name", "path" },
        );
        const raw_name = try definition_core.json.requiredString(
            object,
            "name",
        );
        try definition_core.json.safeIdentifier(raw_name, 128);
        for (fields[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, raw_name)) {
                return error.ProjectionFieldsNotUnique;
            }
        }
        const name = try allocator.dupe(u8, raw_name);
        errdefer allocator.free(name);
        var pointer = try definition_core.json_pointer.compile(
            allocator,
            try definition_core.json.requiredString(object, "path"),
        );
        errdefer pointer.deinit(allocator);
        fields[index] = .{ .name = name, .pointer = pointer };
        initialized += 1;
    }
    return fields;
}

fn compileRetainedFields(
    allocator: std.mem.Allocator,
    retained_plan: *const state_reducer.Plan,
    object: std.json.ObjectMap,
) ![]RetainedField {
    if (object.count() == 0 or object.count() > 256) {
        return error.InvalidProjectionFields;
    }
    var fields: std.ArrayList(RetainedField) = .empty;
    errdefer {
        for (fields.items) |*field| field.deinit(allocator);
        fields.deinit(allocator);
    }
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try definition_core.json.safeIdentifier(entry.key_ptr.*, 128);
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        const source_object = try definition_core.json.object(
            entry.value_ptr.*,
        );
        var source = try compileRetainedSource(
            allocator,
            retained_plan,
            source_object,
        );
        errdefer source.deinit(allocator);
        try fields.append(allocator, .{
            .name = name,
            .source = source,
        });
    }
    std.sort.heap(RetainedField, fields.items, {}, struct {
        fn lessThan(
            _: void,
            left: RetainedField,
            right: RetainedField,
        ) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return fields.toOwnedSlice(allocator);
}

fn compileRetainedSource(
    allocator: std.mem.Allocator,
    retained_plan: *const state_reducer.Plan,
    object: std.json.ObjectMap,
) !RetainedSource {
    if (object.get("register") != null) {
        return compileRetainedRegister(allocator, retained_plan, object);
    }
    try definition_core.json.requireExactKeys(object, &.{"meta"});
    try definition_core.json.requireFields(object, &.{"meta"});
    return .{ .meta = try parseRetainedMeta(
        try definition_core.json.requiredString(object, "meta"),
    ) };
}

fn compileRetainedRegister(
    allocator: std.mem.Allocator,
    retained_plan: *const state_reducer.Plan,
    object: std.json.ObjectMap,
) !RetainedSource {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "register", "path", "count" },
    );
    try definition_core.json.requireFields(object, &.{"register"});
    const register_name = try definition_core.json.requiredString(
        object,
        "register",
    );
    const register_index =
        state_reducer.registerIndex(retained_plan, register_name) orelse
        return error.UnknownProjectionRegister;
    const raw_path = if (object.get("path")) |raw|
        try definition_core.json.string(raw)
    else
        "";
    var pointer = try definition_core.json_pointer.compile(
        allocator,
        raw_path,
    );
    errdefer pointer.deinit(allocator);
    const count = if (object.get("count")) |raw|
        try definition_core.json.boolean(raw)
    else
        false;
    return .{ .register = .{
        .index = register_index,
        .pointer = pointer,
        .count = count,
    } };
}

fn parseRetainedMeta(raw: []const u8) !RetainedMeta {
    if (std.mem.eql(u8, raw, "record-count")) return .record_count;
    if (std.mem.eql(u8, raw, "head-digest")) return .head_digest;
    if (std.mem.eql(u8, raw, "event-kind-counts")) {
        return .event_kind_counts;
    }
    return error.UnknownProjectionMetadata;
}

fn compileLimit(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    object: std.json.ObjectMap,
) !Limit {
    try definition_core.json.requireExactKeys(
        object,
        &.{ "op", "count", "param" },
    );
    const fixed = object.get("count");
    const parameter = object.get("param");
    if ((fixed == null) == (parameter == null)) {
        return error.InvalidProjectionLimit;
    }
    if (fixed) |value| {
        const count = try definition_core.json.unsigned(value);
        if (count == 0 or count > definition_plan.bounds.max_records) {
            return error.InvalidProjectionLimit;
        }
        return .{ .fixed = count };
    }
    const name = try definition_core.json.string(parameter.?);
    const declaration = definition_plan.parameter_declarations.find(name) orelse
        return error.UnknownProjectionParameter;
    if (declaration.kind != .integer) {
        return error.ProjectionLimitParameterMustBeInteger;
    }
    return .{ .parameter = try allocator.dupe(u8, name) };
}

pub fn execute(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
    plan: *const Plan,
    projection_name: []const u8,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    const compiled = plan.find(projection_name) orelse
        return error.UnknownProjection;
    try requireProjectionParameters(compiled, parameters);
    if (compiled.source_scope == .matching) {
        return executeMatchingDocuments(
            allocator,
            definition_plan,
            storage_plan,
            event_protocol,
            plan,
            compiled,
            projection_name,
            repo_root,
            parameters,
        );
    }
    return executeResolvedProjection(
        allocator,
        definition_plan,
        storage_plan,
        event_protocol,
        plan,
        compiled,
        projection_name,
        repo_root,
        parameters,
    );
}

fn executeResolvedProjection(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
    plan: *const Plan,
    compiled: *const Projection,
    projection_name: []const u8,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    var resolved_storage =
        try storage.resolve(allocator, storage_plan, parameters);
    defer resolved_storage.deinit(allocator);
    const slot = resolved_storage.slot(compiled.slot_index);
    var fused_sorted = try initSortedAccumulator(
        allocator,
        compiled,
        slot,
        parameters,
    );
    defer if (fused_sorted) |*accumulator| accumulator.deinit();
    var fold_history =
        try initFoldHistory(allocator, compiled, event_protocol);
    defer if (fold_history) |*accumulator| accumulator.deinit();
    if (slot.kind == .event_log and
        (fold_history != null or fused_sorted != null))
    {
        const streamed = executeResolvedStreamProjection(
            allocator,
            definition_plan,
            event_protocol,
            plan,
            compiled,
            projection_name,
            repo_root,
            &slot,
            parameters,
            &fold_history,
            &fused_sorted,
        ) catch |err| switch (err) {
            error.ReplayRequiresMaterializedHistory => null,
            else => return err,
        };
        if (streamed) |result| return result;
    }
    var snapshot = try custody.readSlotOrMissing(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
    );
    defer snapshot.deinit(allocator);
    var replay_stats = try validateProjectionReplay(
        allocator,
        definition_plan,
        event_protocol,
        compiled,
        repo_root,
        &slot,
        &snapshot,
        parameters,
        if (fold_history) |*value| value else null,
        if (fused_sorted) |*value| value else null,
    );
    defer replay_stats.deinit(allocator);
    const effective_limit =
        try resolveLimit(compiled.limit, parameters, plan.max_records);
    return executeValidatedProjection(
        allocator,
        definition_plan,
        event_protocol,
        plan,
        compiled,
        projection_name,
        &slot,
        &snapshot,
        parameters,
        effective_limit,
        &replay_stats,
        &fold_history,
        &fused_sorted,
    );
}

fn executeResolvedStreamProjection(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    event_protocol: ?*const protocol.Plan,
    plan: *const Plan,
    compiled: *const Projection,
    projection_name: []const u8,
    repo_root: []const u8,
    slot: *const storage.ResolvedSlot,
    parameters: *const definition_core.parameters.Bindings,
    fold_history: *?FoldHistoryAccumulator,
    fused_sorted: *?SortedAccumulator,
) !?Result {
    var snapshot = try custody.readReplaySlotOrMissing(
        allocator,
        repo_root,
        definition_plan.id,
        slot.*,
    );
    defer snapshot.deinit(allocator);
    if (!snapshot.exists) return null;
    const protocol_required = event_protocol != null and
        event_protocol.?.target_slot_index == compiled.slot_index;
    var replay_stats = if (fold_history.*) |*accumulator|
        try replay.validateReplaySlotObserved(
            allocator,
            repo_root,
            definition_plan.id,
            slot.*,
            &snapshot,
            parameters,
            definition_plan.bounds.max_records,
            protocol_required,
            accumulator,
        )
    else if (fused_sorted.*) |*accumulator|
        try replay.validateReplaySlotObserved(
            allocator,
            repo_root,
            definition_plan.id,
            slot.*,
            &snapshot,
            parameters,
            definition_plan.bounds.max_records,
            protocol_required,
            accumulator,
        )
    else
        return error.StreamProjectionAccumulatorMissing;
    defer replay_stats.deinit(allocator);
    const effective_limit =
        try resolveLimit(compiled.limit, parameters, plan.max_records);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stats: Stats = .{
        .records_scanned = replay_stats.records_validated,
        .records_matched = 0,
        .records_emitted = 0,
    };
    if (compiled.fold != null) {
        try executeFoldProjection(
            allocator,
            event_protocol,
            compiled,
            &replay_stats,
            if (fold_history.*) |*value| value else null,
            parameters,
            effective_limit,
            plan.max_output_bytes,
            &output,
            &stats,
        );
    } else {
        const accumulator = if (fused_sorted.*) |*value| value else return error.StreamProjectionAccumulatorMissing;
        if (accumulator.records_seen != replay_stats.records_validated) {
            return error.StreamProjectionRecordCountMismatch;
        }
        try accumulator.write(
            &output.writer,
            effective_limit,
            &stats,
        );
    }
    if (output.written().len > plan.max_output_bytes) {
        return error.ProjectionOutputBoundsExceeded;
    }
    return try buildProjectionResult(
        allocator,
        definition_plan,
        compiled,
        projection_name,
        slot.relative_path,
        snapshot.revision,
        &output,
        stats,
    );
}

fn initSortedAccumulator(
    allocator: std.mem.Allocator,
    compiled: *const Projection,
    slot: storage.ResolvedSlot,
    parameters: *const definition_core.parameters.Bindings,
) !?SortedAccumulator {
    if (compiled.fold != null or slot.codec != .jsonl or
        compiled.sort_keys.len == 0 or compiled.raw)
    {
        return null;
    }
    return try SortedAccumulator.init(allocator, compiled, parameters);
}

fn executeValidatedProjection(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    event_protocol: ?*const protocol.Plan,
    plan: *const Plan,
    compiled: *const Projection,
    projection_name: []const u8,
    slot: *const storage.ResolvedSlot,
    snapshot: *const custody.SlotSnapshot,
    parameters: *const definition_core.parameters.Bindings,
    effective_limit: usize,
    replay_stats: *replay.Stats,
    fold_history: *?FoldHistoryAccumulator,
    fused_sorted: *?SortedAccumulator,
) !Result {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    if (compiled.fold != null) {
        try executeFoldProjection(
            allocator,
            event_protocol,
            compiled,
            replay_stats,
            if (fold_history.*) |*value| value else null,
            parameters,
            effective_limit,
            plan.max_output_bytes,
            &output,
            &stats,
        );
    } else {
        try executeStoredProjection(
            allocator,
            compiled,
            slot,
            snapshot,
            parameters,
            effective_limit,
            plan.max_records,
            replay_stats,
            fused_sorted,
            &output,
            &stats,
        );
    }
    if (output.written().len > plan.max_output_bytes) {
        return error.ProjectionOutputBoundsExceeded;
    }
    return buildProjectionResult(
        allocator,
        definition_plan,
        compiled,
        projection_name,
        slot.relative_path,
        snapshot.revision,
        &output,
        stats,
    );
}

fn requireProjectionParameters(
    compiled: *const Projection,
    parameters: *const definition_core.parameters.Bindings,
) !void {
    for (compiled.required_parameters) |name| {
        if (parameters.find(name) == null) {
            return error.MissingProjectionParameter;
        }
    }
}

fn initFoldHistory(
    allocator: std.mem.Allocator,
    compiled: *const Projection,
    event_protocol: ?*const protocol.Plan,
) !?FoldHistoryAccumulator {
    const fold = if (compiled.fold) |*value| value else return null;
    switch (fold.*) {
        .retained => return null,
        .keyed => |*keyed| {
            if (!keyed.history.active()) return null;
            const event_plan = event_protocol orelse
                return error.FoldReplayPlanMissing;
            const reducer_plan = if (event_plan.reducer_plan) |*value|
                value
            else
                return error.FoldReducerPlanMissing;
            return FoldHistoryAccumulator.init(
                allocator,
                keyed,
                reducer_plan,
            );
        },
    }
}

fn validateProjectionReplay(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    event_protocol: ?*const protocol.Plan,
    compiled: *const Projection,
    repo_root: []const u8,
    slot: *const storage.ResolvedSlot,
    snapshot: *const custody.SlotSnapshot,
    parameters: *const definition_core.parameters.Bindings,
    fold_history: ?*FoldHistoryAccumulator,
    fused_sorted: ?*SortedAccumulator,
) !replay.Stats {
    const protocol_required = event_protocol != null and
        event_protocol.?.target_slot_index == compiled.slot_index;
    if (!snapshot.exists) {
        if (slot.kind != .event_log) return error.FileNotFound;
        return .{
            .records_validated = 0,
            .definition_versions = 1,
            .protocol_state = if (protocol_required)
                protocol.ReplayState.init(event_protocol.?)
            else
                null,
        };
    }
    if (fold_history) |accumulator| {
        return replay.validateSlotObserved(
            allocator,
            repo_root,
            definition_plan.id,
            slot.*,
            snapshot,
            parameters,
            definition_plan.bounds.max_records,
            protocol_required,
            accumulator,
        );
    }
    if (fused_sorted) |accumulator| {
        return replay.validateSlotObserved(
            allocator,
            repo_root,
            definition_plan.id,
            slot.*,
            snapshot,
            parameters,
            definition_plan.bounds.max_records,
            protocol_required,
            accumulator,
        );
    }
    return replay.validateSlot(
        allocator,
        repo_root,
        definition_plan.id,
        slot.*,
        snapshot,
        parameters,
        definition_plan.bounds.max_records,
        protocol_required,
    );
}

fn executeFoldProjection(
    allocator: std.mem.Allocator,
    event_protocol: ?*const protocol.Plan,
    compiled: *const Projection,
    replay_stats: *replay.Stats,
    fold_history: ?*FoldHistoryAccumulator,
    parameters: *const definition_core.parameters.Bindings,
    effective_limit: usize,
    max_output_bytes: usize,
    output: *std.Io.Writer.Allocating,
    stats: *Stats,
) !void {
    const replay_state =
        if (replay_stats.protocol_state) |*protocol_state|
            protocol_state
        else
            return error.FoldReplayStateMissing;
    const event_plan = event_protocol orelse
        return error.FoldReplayPlanMissing;
    stats.records_scanned = replay_stats.records_validated;
    switch (compiled.fold.?) {
        .keyed => |keyed| try executeKeyedFoldProjection(
            allocator,
            compiled,
            &keyed,
            replay_state,
            fold_history,
            parameters,
            effective_limit,
            max_output_bytes,
            output,
            stats,
            replay_stats.records_validated,
        ),
        .retained => |retained| {
            const retained_plan =
                if (event_plan.state_reducer_plan) |*value|
                    value
                else
                    return error.FoldRetainedPlanMissing;
            try writeRetainedProjectionOutput(
                allocator,
                &output.writer,
                compiled,
                event_plan,
                retained_plan,
                replay_state,
                retained.fields,
                max_output_bytes,
            );
            stats.records_matched = 1;
            stats.records_emitted = 1;
        },
    }
}

fn executeKeyedFoldProjection(
    allocator: std.mem.Allocator,
    compiled: *const Projection,
    keyed: *const KeyedFold,
    replay_state: *protocol.ReplayState,
    fold_history: ?*FoldHistoryAccumulator,
    parameters: *const definition_core.parameters.Bindings,
    effective_limit: usize,
    max_output_bytes: usize,
    output: *std.Io.Writer.Allocating,
    stats: *Stats,
    records_validated: usize,
) !void {
    if (compiled.constructed_value != null) {
        stats.records_emitted = try writeConstructedKeyedFold(
            allocator,
            &output.writer,
            compiled,
            keyed,
            &replay_state.reducer_state,
            fold_history,
            parameters,
            max_output_bytes,
        );
        stats.records_matched = stats.records_emitted;
        return;
    }
    if (compiled.predicates.len != 0) {
        const filtered = try writeFilteredKeyedFold(
            allocator,
            output,
            compiled,
            keyed,
            &replay_state.reducer_state,
            fold_history,
            parameters,
            effective_limit,
            max_output_bytes,
        );
        stats.records_matched = filtered.matched;
        stats.records_emitted = filtered.emitted;
        return;
    }
    stats.records_matched = replay_state.reducer_state.count();
    stats.records_emitted = try writeCompleteKeyedFold(
        allocator,
        output,
        &replay_state.reducer_state,
        fold_history,
        keyed,
        effective_limit,
        max_output_bytes,
        records_validated,
    );
}

fn writeCompleteKeyedFold(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    state: *reducer.State,
    fold_history: ?*FoldHistoryAccumulator,
    keyed: *const KeyedFold,
    effective_limit: usize,
    max_output_bytes: usize,
    records_validated: usize,
) !usize {
    if (!keyed.history.active()) {
        return state.writeCanonicalRows(
            allocator,
            output,
            keyed.key_field,
            keyed.state_field,
            keyed.retained_field,
            keyed.event_count_field,
            effective_limit,
            max_output_bytes,
        );
    }
    const accumulator = fold_history orelse
        return error.FoldHistoryAccumulatorMissing;
    if (accumulator.records_seen != records_validated) {
        return error.FoldHistoryRecordCountMismatch;
    }
    return writeKeyedHistoryRows(
        allocator,
        output,
        state,
        accumulator,
        keyed,
        effective_limit,
        max_output_bytes,
        null,
    );
}

fn executeStoredProjection(
    allocator: std.mem.Allocator,
    compiled: *const Projection,
    slot: *const storage.ResolvedSlot,
    snapshot: *const custody.SlotSnapshot,
    parameters: *const definition_core.parameters.Bindings,
    effective_limit: usize,
    max_records: usize,
    replay_stats: *const replay.Stats,
    fused_sorted: *?SortedAccumulator,
    output: *std.Io.Writer.Allocating,
    stats: *Stats,
) !void {
    switch (slot.codec) {
        .json => try executeDocument(
            allocator,
            compiled,
            snapshot.content,
            parameters,
            effective_limit,
            &output.writer,
            stats,
        ),
        .jsonl => try executeJsonlProjection(
            allocator,
            compiled,
            snapshot.content,
            parameters,
            effective_limit,
            max_records,
            replay_stats,
            fused_sorted,
            output,
            stats,
        ),
        .text => try executeTextDocument(
            allocator,
            compiled,
            slot.*,
            snapshot,
            parameters,
            effective_limit,
            &output.writer,
            stats,
        ),
    }
}

fn executeJsonlProjection(
    allocator: std.mem.Allocator,
    compiled: *const Projection,
    content: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    effective_limit: usize,
    max_records: usize,
    replay_stats: *const replay.Stats,
    fused_sorted: *?SortedAccumulator,
    output: *std.Io.Writer.Allocating,
    stats: *Stats,
) !void {
    if (compiled.sort_keys.len == 0) {
        return executeJsonl(
            allocator,
            compiled,
            content,
            parameters,
            effective_limit,
            max_records,
            &output.writer,
            stats,
        );
    }
    if (fused_sorted.*) |*accumulator| {
        if (accumulator.records_seen == replay_stats.records_validated) {
            stats.records_scanned = replay_stats.records_validated;
            return accumulator.write(
                &output.writer,
                effective_limit,
                stats,
            );
        }
        accumulator.deinit();
        fused_sorted.* = null;
    }
    return executeSortedJsonl(
        allocator,
        compiled,
        content,
        parameters,
        effective_limit,
        max_records,
        &output.writer,
        stats,
    );
}

fn buildProjectionResult(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    compiled: *const Projection,
    projection_name: []const u8,
    logical_path: []const u8,
    snapshot_revision: []const u8,
    output: *std.Io.Writer.Allocating,
    stats: Stats,
) !Result {
    const payload = try output.toOwnedSlice();
    errdefer allocator.free(payload);
    const limitations = try allocator.alloc([]u8, 0);
    errdefer allocator.free(limitations);
    const definition_id = try allocator.dupe(u8, definition_plan.id);
    errdefer allocator.free(definition_id);
    const projection = try allocator.dupe(u8, projection_name);
    errdefer allocator.free(projection);
    const logical_ref = try allocator.dupe(u8, logical_path);
    errdefer allocator.free(logical_ref);
    const revision = try allocator.dupe(u8, snapshot_revision);
    errdefer allocator.free(revision);
    return .{
        .definition_id = definition_id,
        .definition_digest = definition_plan.closure_digest,
        .projection = projection,
        .logical_ref = logical_ref,
        .revision = revision,
        .payload = payload,
        .stats = stats,
        .limitations = limitations,
        .max_output_bytes = definition_plan.bounds.max_output_bytes,
        .exit_code = if (stats.records_matched != 0)
            compiled.exit_policy.matched
        else
            compiled.exit_policy.unmatched,
    };
}

fn executeMatchingDocuments(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
    plan: *const Plan,
    compiled: *const Projection,
    projection_name: []const u8,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    if (event_protocol != null) return error.MatchingProtocolProjectionUnsupported;
    const source_slot = storage_plan.slots[compiled.slot_index];
    const paths = try storage.enumerateMatchingPathsAlloc(
        allocator,
        repo_root,
        source_slot,
        plan.max_records,
    );
    defer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }
    if (paths.len == 0) {
        if (compiled.require_match) return error.ProjectionNotFound;
        return emptyMatchingResult(
            allocator,
            definition_plan,
            compiled,
            projection_name,
            source_slot.relative_path,
        );
    }
    const selected_path = paths[
        try latestMatchingPathIndex(
            allocator,
            definition_plan,
            source_slot,
            compiled.latest.?,
            repo_root,
            parameters,
            plan.max_records,
            paths,
        )
    ];
    return executeSelectedDocument(
        allocator,
        definition_plan,
        plan,
        compiled,
        projection_name,
        repo_root,
        parameters,
        source_slot,
        selected_path,
        paths.len,
    );
}

fn latestMatchingPathIndex(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    source_slot: storage.Slot,
    pointer: definition_core.json_pointer.Pointer,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    max_records: usize,
    paths: []const []u8,
) !usize {
    var selected_index: ?usize = null;
    var selected_key: ?Scalar = null;
    defer if (selected_key) |*key| key.deinit(allocator);
    for (paths, 0..) |path, path_index| {
        const resolved_slot = resolveMatchingSlot(source_slot, path);
        var snapshot = try custody.readSlot(
            allocator,
            repo_root,
            definition_plan.id,
            resolved_slot,
        );
        defer snapshot.deinit(allocator);
        var replay_stats = try replay.validateSlot(
            allocator,
            repo_root,
            definition_plan.id,
            resolved_slot,
            &snapshot,
            parameters,
            max_records,
            false,
        );
        defer replay_stats.deinit(allocator);
        const physical = try textDocumentPhysicalJsonAlloc(
            allocator,
            resolved_slot,
            &snapshot,
        );
        defer allocator.free(physical);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            physical,
            .{
                .duplicate_field_behavior = .@"error",
                .parse_numbers = false,
            },
        );
        defer parsed.deinit();
        const raw_key =
            definition_core.json_pointer.lookup(parsed.value, pointer) orelse
            continue;
        var key = try scalarFromJsonAlloc(allocator, raw_key);
        var key_owned = true;
        defer if (key_owned) key.deinit(allocator);
        if (selected_key != null and
            (try compareScalars(key, selected_key.?)) != .gt)
        {
            continue;
        }
        if (selected_key) |*prior| prior.deinit(allocator);
        selected_key = key;
        key_owned = false;
        selected_index = path_index;
    }
    return selected_index orelse error.ProjectionNotFound;
}

fn executeSelectedDocument(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    plan: *const Plan,
    compiled: *const Projection,
    projection_name: []const u8,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    source_slot: storage.Slot,
    selected_path: []const u8,
    path_count: usize,
) !Result {
    const resolved_slot = resolveMatchingSlot(source_slot, selected_path);
    var snapshot = try custody.readSlot(
        allocator,
        repo_root,
        definition_plan.id,
        resolved_slot,
    );
    defer snapshot.deinit(allocator);
    var replay_stats = try replay.validateSlot(
        allocator,
        repo_root,
        definition_plan.id,
        resolved_slot,
        &snapshot,
        parameters,
        definition_plan.bounds.max_records,
        false,
    );
    defer replay_stats.deinit(allocator);
    const effective_limit = try resolveLimit(
        compiled.limit,
        parameters,
        plan.max_records,
    );
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try executeTextDocument(
        allocator,
        compiled,
        resolved_slot,
        &snapshot,
        parameters,
        effective_limit,
        &output.writer,
        &stats,
    );
    stats.records_scanned = path_count;
    stats.records_matched = path_count;
    stats.records_emitted = 1;
    if (output.written().len > plan.max_output_bytes) {
        return error.ProjectionOutputBoundsExceeded;
    }
    return buildProjectionResult(
        allocator,
        definition_plan,
        compiled,
        projection_name,
        selected_path,
        snapshot.revision,
        &output,
        stats,
    );
}

fn resolveMatchingSlot(
    source: storage.Slot,
    selected_path: []const u8,
) storage.ResolvedSlot {
    return .{
        .name = source.name,
        .relative_path = selected_path,
        .owned_path = null,
        .kind = source.kind,
        .codec = source.codec,
        .max_bytes = source.max_bytes,
    };
}

fn emptyMatchingResult(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    compiled: *const Projection,
    projection_name: []const u8,
    logical_ref_template: []const u8,
) !Result {
    const definition_id = try allocator.dupe(u8, definition_plan.id);
    errdefer allocator.free(definition_id);
    const projection_name_owned = try allocator.dupe(u8, projection_name);
    errdefer allocator.free(projection_name_owned);
    const logical_ref = try allocator.dupe(u8, logical_ref_template);
    errdefer allocator.free(logical_ref);
    const revision = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        "",
    );
    errdefer allocator.free(revision);
    const payload = try allocator.dupe(u8, "null");
    errdefer allocator.free(payload);
    const limitations = try allocator.alloc([]u8, 0);
    errdefer allocator.free(limitations);
    return .{
        .definition_id = definition_id,
        .definition_digest = definition_plan.closure_digest,
        .projection = projection_name_owned,
        .logical_ref = logical_ref,
        .revision = revision,
        .payload = payload,
        .stats = .{
            .records_scanned = 0,
            .records_matched = 0,
            .records_emitted = 0,
        },
        .limitations = limitations,
        .max_output_bytes = definition_plan.bounds.max_output_bytes,
        .exit_code = compiled.exit_policy.unmatched,
    };
}

fn executeTextDocument(
    allocator: std.mem.Allocator,
    compiled: *const Projection,
    slot: storage.ResolvedSlot,
    snapshot: *const custody.SlotSnapshot,
    parameters: *const definition_core.parameters.Bindings,
    effective_limit: usize,
    writer: *std.Io.Writer,
    stats: *Stats,
) !void {
    const physical = try textDocumentPhysicalJsonAlloc(
        allocator,
        slot,
        snapshot,
    );
    defer allocator.free(physical);
    try executeDocument(
        allocator,
        compiled,
        physical,
        parameters,
        effective_limit,
        writer,
        stats,
    );
}

fn textDocumentPhysicalJsonAlloc(
    allocator: std.mem.Allocator,
    slot: storage.ResolvedSlot,
    snapshot: *const custody.SlotSnapshot,
) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(snapshot.content)) {
        return error.StoredDocumentNotUtf8;
    }
    var physical: std.Io.Writer.Allocating = .init(allocator);
    errdefer physical.deinit();
    try physical.writer.writeAll("{\"content\":");
    try definition_core.canonical_json.writeCanonicalString(
        &physical.writer,
        snapshot.content,
    );
    try physical.writer.writeAll(",\"logical_ref\":");
    try definition_core.canonical_json.writeCanonicalString(
        &physical.writer,
        slot.relative_path,
    );
    try physical.writer.writeAll(",\"path\":");
    try definition_core.canonical_json.writeCanonicalString(
        &physical.writer,
        snapshot.path,
    );
    try physical.writer.writeAll(",\"revision\":");
    try definition_core.canonical_json.writeCanonicalString(
        &physical.writer,
        snapshot.revision,
    );
    try physical.writer.writeByte('}');
    return physical.toOwnedSlice();
}

const KeyedHistoryFieldSource = union(enum) {
    key,
    state,
    retained,
    event_count,
    event_kind_count: usize,
    event_chain,
    snapshot,
    prior_snapshot,
};

const KeyedHistoryField = struct {
    name: []const u8,
    source: KeyedHistoryFieldSource,
};

fn writeConstructedKeyedFold(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    projection: *const Projection,
    keyed: *const KeyedFold,
    reducer_state: *reducer.State,
    accumulator: ?*const FoldHistoryAccumulator,
    parameters: *const definition_core.parameters.Bindings,
    max_output_bytes: usize,
) !usize {
    const constructed = projection.constructed_value orelse
        return error.FoldConstructedValueMissing;
    if (projection.predicates.len != 1 or
        projection.predicates[0] != .one or
        projection.predicates[0].one.operand != .parameter)
    {
        return error.FoldLookupRequiresParameter;
    }
    const operand = projection.predicates[0].one.operand.parameter;
    const bound = scalarFromBinding(parameters, operand) orelse
        return error.MissingParameter;
    const key = switch (bound) {
        .string => |value| value,
        else => return error.FoldLookupParameterMustBeString,
    };
    var row_array: std.Io.Writer.Allocating = .init(allocator);
    defer row_array.deinit();
    const emitted = try writeKeyedHistoryRows(
        allocator,
        &row_array,
        reducer_state,
        accumulator,
        keyed,
        1,
        max_output_bytes,
        key,
    );
    if (emitted == 0) return error.ProjectionNotFound;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        row_array.written(),
        .{
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        },
    );
    defer parsed.deinit();
    const rows = try definition_core.json.array(parsed.value);
    if (rows.items.len != 1) return error.FoldLookupCardinalityMismatch;
    try projection_value.write(
        allocator,
        writer,
        constructed,
        rows.items[0],
    );
    return 1;
}

const FilteredFoldCounts = struct {
    matched: usize,
    emitted: usize,
};

fn writeFilteredKeyedFold(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    projection: *const Projection,
    keyed: *const KeyedFold,
    reducer_state: *reducer.State,
    accumulator: ?*const FoldHistoryAccumulator,
    parameters: *const definition_core.parameters.Bindings,
    limit: usize,
    max_output_bytes: usize,
) !FilteredFoldCounts {
    var field_storage: [4 + max_fold_event_kind_counts + 3]KeyedHistoryField = undefined;
    const fields = keyedHistoryFields(&field_storage, keyed);
    const views = try reducer_state.sortedViewsAlloc(allocator);
    defer allocator.free(views);
    var matched: usize = 0;
    var emitted: usize = 0;
    try output.writer.writeByte('[');
    for (views) |view| {
        const history = if (accumulator) |configured|
            configured.get(view.key) orelse
                return error.FoldHistoryReducerStateMismatch
        else
            null;
        if (!try matchesKeyedFold(
            allocator,
            projection,
            fields,
            view,
            history,
            parameters,
        )) continue;
        matched += 1;
        if (emitted == limit) continue;
        if (emitted != 0) try output.writer.writeByte(',');
        try writeKeyedHistoryRow(
            &output.writer,
            fields,
            view,
            history,
        );
        emitted += 1;
        if (output.written().len > max_output_bytes) {
            return error.ProjectionOutputBoundsExceeded;
        }
    }
    try output.writer.writeByte(']');
    if (output.written().len > max_output_bytes) {
        return error.ProjectionOutputBoundsExceeded;
    }
    return .{ .matched = matched, .emitted = emitted };
}

fn matchesKeyedFold(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    fields: []const KeyedHistoryField,
    view: reducer.EntryView,
    history: ?*const FoldHistoryEntry,
    parameters: *const definition_core.parameters.Bindings,
) !bool {
    var parsed_retained: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_retained) |*parsed| parsed.deinit();
    if (projectionReferencesRetained(projection, fields)) {
        parsed_retained = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            view.retained orelse return false,
            .{
                .duplicate_field_behavior = .@"error",
                .parse_numbers = false,
            },
        );
    }
    const retained = if (parsed_retained) |parsed|
        parsed.value
    else
        null;
    for (projection.predicates) |group| {
        switch (group) {
            .one => |predicate| {
                if (!predicateMatchesKeyedFold(
                    predicate,
                    fields,
                    view,
                    history,
                    retained,
                    parameters,
                )) return false;
            },
            .any => |sets| {
                var group_matched = false;
                for (sets) |set| {
                    var set_matched = true;
                    for (set.predicates) |predicate| {
                        if (!predicateMatchesKeyedFold(
                            predicate,
                            fields,
                            view,
                            history,
                            retained,
                            parameters,
                        )) {
                            set_matched = false;
                            break;
                        }
                    }
                    if (set_matched) {
                        group_matched = true;
                        break;
                    }
                }
                if (!group_matched) return false;
            },
        }
    }
    return true;
}

fn projectionReferencesRetained(
    projection: *const Projection,
    fields: []const KeyedHistoryField,
) bool {
    for (projection.predicates) |group| switch (group) {
        .one => |predicate| {
            if (predicateReferencesRetained(predicate, fields)) return true;
        },
        .any => |sets| for (sets) |set| {
            for (set.predicates) |predicate| {
                if (predicateReferencesRetained(predicate, fields)) {
                    return true;
                }
            }
        },
    };
    return false;
}

fn predicateReferencesRetained(
    predicate: Predicate,
    fields: []const KeyedHistoryField,
) bool {
    if (predicate.pointer.segments.len == 0) return false;
    const field = findKeyedHistoryField(
        fields,
        predicate.pointer.segments[0],
    ) orelse return false;
    return field.source == .retained;
}

fn predicateMatchesKeyedFold(
    predicate: Predicate,
    fields: []const KeyedHistoryField,
    view: reducer.EntryView,
    history: ?*const FoldHistoryEntry,
    retained: ?std.json.Value,
    parameters: *const definition_core.parameters.Bindings,
) bool {
    if (predicate.pointer.segments.len == 0) return false;
    const field = findKeyedHistoryField(
        fields,
        predicate.pointer.segments[0],
    ) orelse return false;
    const expected = switch (predicate.operand) {
        .constant => |constant| constant,
        .parameter => |name| scalarFromBinding(parameters, name) orelse
            return false,
    };
    const tail = predicate.pointer.segments[1..];
    return switch (field.source) {
        .key => tail.len == 0 and scalarEqualsText(expected, view.key),
        .state => tail.len == 0 and scalarEqualsText(expected, view.state),
        .retained => blk: {
            const root = retained orelse break :blk false;
            const actual = lookupJsonSegments(root, tail) orelse
                break :blk false;
            break :blk scalarEqualsJson(expected, actual);
        },
        .event_count => tail.len == 0 and
            scalarEqualsCount(expected, view.event_count),
        .event_kind_count => |index| tail.len == 0 and
            scalarEqualsCount(
                expected,
                (history orelse return false).event_kind_counts[index],
            ),
        .event_chain => tail.len == 0 and scalarEqualsText(
            expected,
            &(history orelse return false).event_chain,
        ),
        .snapshot => tail.len == 0 and scalarEqualsText(
            expected,
            &(history orelse return false).snapshot,
        ),
        .prior_snapshot => blk: {
            if (tail.len != 0) break :blk false;
            const value = history orelse break :blk expected == .null;
            if (!value.has_prior_snapshot) break :blk expected == .null;
            break :blk scalarEqualsText(expected, &value.prior_snapshot);
        },
    };
}

fn findKeyedHistoryField(
    fields: []const KeyedHistoryField,
    name: []const u8,
) ?KeyedHistoryField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

fn lookupJsonSegments(
    root: std.json.Value,
    segments: []const []u8,
) ?std.json.Value {
    var current = root;
    for (segments) |segment| {
        current = switch (current) {
            .object => |object| object.get(segment) orelse return null,
            .array => |array| blk: {
                if (segment.len == 0 or
                    (segment.len > 1 and segment[0] == '0'))
                {
                    return null;
                }
                const index = std.fmt.parseInt(
                    usize,
                    segment,
                    10,
                ) catch return null;
                if (index >= array.items.len) return null;
                break :blk array.items[index];
            },
            else => return null,
        };
    }
    return current;
}

fn scalarEqualsText(expected: Scalar, actual: []const u8) bool {
    return expected == .string and
        std.mem.eql(u8, expected.string, actual);
}

fn scalarEqualsCount(expected: Scalar, actual: usize) bool {
    return expected == .integer and
        std.math.cast(usize, expected.integer) == actual;
}

fn writeKeyedHistoryRows(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    reducer_state: *reducer.State,
    accumulator: ?*const FoldHistoryAccumulator,
    keyed: *const KeyedFold,
    limit: usize,
    max_output_bytes: usize,
    only_key: ?[]const u8,
) !usize {
    var field_storage: [4 + max_fold_event_kind_counts + 3]KeyedHistoryField = undefined;
    const fields = keyedHistoryFields(&field_storage, keyed);
    var one_view: [1]reducer.EntryView = undefined;
    var allocated_views: ?[]reducer.EntryView = null;
    defer if (allocated_views) |views| allocator.free(views);
    const views: []reducer.EntryView = if (only_key) |key| selected: {
        one_view[0] = reducer_state.get(key) orelse {
            try output.writer.writeAll("[]");
            return 0;
        };
        break :selected &one_view;
    } else all: {
        allocated_views = try reducer_state.sortedViewsAlloc(allocator);
        break :all allocated_views.?;
    };
    const emitted = @min(limit, views.len);
    try output.writer.writeByte('[');
    for (views[0..emitted], 0..) |view, row_index| {
        if (row_index != 0) try output.writer.writeByte(',');
        const history = if (accumulator) |configured|
            configured.get(view.key) orelse
                return error.FoldHistoryReducerStateMismatch
        else
            null;
        try writeKeyedHistoryRow(
            &output.writer,
            fields,
            view,
            history,
        );
        if (output.written().len > max_output_bytes) {
            return error.ProjectionOutputBoundsExceeded;
        }
    }
    try output.writer.writeByte(']');
    if (output.written().len > max_output_bytes) {
        return error.ProjectionOutputBoundsExceeded;
    }
    return emitted;
}

fn keyedHistoryFields(
    storage_buffer: *[4 + max_fold_event_kind_counts + 3]KeyedHistoryField,
    keyed: *const KeyedFold,
) []KeyedHistoryField {
    var field_count: usize = 0;
    storage_buffer[field_count] = .{
        .name = keyed.key_field,
        .source = .key,
    };
    field_count += 1;
    storage_buffer[field_count] = .{
        .name = keyed.state_field,
        .source = .state,
    };
    field_count += 1;
    if (keyed.retained_field) |name| {
        storage_buffer[field_count] = .{
            .name = name,
            .source = .retained,
        };
        field_count += 1;
    }
    if (keyed.event_count_field) |name| {
        storage_buffer[field_count] = .{
            .name = name,
            .source = .event_count,
        };
        field_count += 1;
    }
    for (keyed.history.event_kind_counts, 0..) |count, index| {
        storage_buffer[field_count] = .{
            .name = count.field,
            .source = .{ .event_kind_count = index },
        };
        field_count += 1;
    }
    if (keyed.history.event_chain) |chain| {
        storage_buffer[field_count] = .{
            .name = chain.field,
            .source = .event_chain,
        };
        field_count += 1;
    }
    if (keyed.history.snapshot) |snapshot| {
        storage_buffer[field_count] = .{
            .name = snapshot.field,
            .source = .snapshot,
        };
        field_count += 1;
        storage_buffer[field_count] = .{
            .name = snapshot.prior_field,
            .source = .prior_snapshot,
        };
        field_count += 1;
    }
    const fields = storage_buffer[0..field_count];
    std.sort.heap(KeyedHistoryField, fields, {}, struct {
        fn lessThan(
            _: void,
            left: KeyedHistoryField,
            right: KeyedHistoryField,
        ) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    return fields;
}

fn writeKeyedHistoryRow(
    writer: *std.Io.Writer,
    fields: []const KeyedHistoryField,
    view: reducer.EntryView,
    history: ?*const FoldHistoryEntry,
) !void {
    try writer.writeByte('{');
    for (fields, 0..) |field, field_index| {
        if (field_index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            field.name,
        );
        try writer.writeByte(':');
        switch (field.source) {
            .key => try definition_core.canonical_json
                .writeCanonicalString(writer, view.key),
            .state => try definition_core.canonical_json
                .writeCanonicalString(writer, view.state),
            .retained => try writer.writeAll(
                view.retained orelse
                    return error.ReducerRetainedValueMissing,
            ),
            .event_count => try writer.print("{d}", .{view.event_count}),
            .event_kind_count => |index| try writer.print(
                "{d}",
                .{(history orelse
                    return error.FoldHistoryAccumulatorMissing)
                    .event_kind_counts[index]},
            ),
            .event_chain => {
                const value = history orelse
                    return error.FoldHistoryAccumulatorMissing;
                if (!value.has_event_chain) {
                    return error.FoldHistoryEventChainMissing;
                }
                try definition_core.canonical_json.writeCanonicalString(
                    writer,
                    &value.event_chain,
                );
            },
            .snapshot => {
                const value = history orelse
                    return error.FoldHistoryAccumulatorMissing;
                if (!value.has_snapshot) {
                    return error.FoldHistorySnapshotMissing;
                }
                try definition_core.canonical_json.writeCanonicalString(
                    writer,
                    &value.snapshot,
                );
            },
            .prior_snapshot => if ((history orelse
                return error.FoldHistoryAccumulatorMissing)
                .has_prior_snapshot)
                try definition_core.canonical_json.writeCanonicalString(
                    writer,
                    &(history.?).prior_snapshot,
                )
            else
                try writer.writeAll("null"),
        }
    }
    try writer.writeByte('}');
}

fn writeRetainedProjection(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    event_plan: *const protocol.Plan,
    retained_plan: *const state_reducer.Plan,
    replay_state: *const protocol.ReplayState,
    fields: []const RetainedField,
) !void {
    try writer.writeByte('{');
    for (fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            field.name,
        );
        try writer.writeByte(':');
        try writeRetainedField(
            allocator,
            writer,
            event_plan,
            retained_plan,
            replay_state,
            field.source,
        );
    }
    try writer.writeByte('}');
}

fn writeRetainedField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    event_plan: *const protocol.Plan,
    retained_plan: *const state_reducer.Plan,
    replay_state: *const protocol.ReplayState,
    source: RetainedSource,
) !void {
    switch (source) {
        .register => |register| try writeRetainedRegister(
            allocator,
            writer,
            retained_plan,
            replay_state,
            register,
        ),
        .meta => |meta| try writeRetainedMeta(
            writer,
            event_plan,
            replay_state,
            meta,
        ),
    }
}

fn writeRetainedRegister(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    retained_plan: *const state_reducer.Plan,
    replay_state: *const protocol.ReplayState,
    register: RetainedRegister,
) !void {
    const root = state_reducer.getByIndex(
        &replay_state.state_reducer_state,
        retained_plan,
        register.index,
    );
    const selected = if (root) |value|
        definition_core.json_pointer.lookup(value, register.pointer)
    else
        null;
    if (register.count) {
        const count = if (selected) |value|
            try retainedValueCount(value)
        else
            0;
        return writer.print("{d}", .{count});
    }
    if (selected) |value| {
        return definition_core.canonical_json.writeCanonicalJson(
            allocator,
            writer,
            value,
        );
    }
    return writer.writeAll("null");
}

fn writeRetainedMeta(
    writer: *std.Io.Writer,
    event_plan: *const protocol.Plan,
    replay_state: *const protocol.ReplayState,
    meta: RetainedMeta,
) !void {
    switch (meta) {
        .record_count => try writer.print(
            "{d}",
            .{replay_state.records},
        ),
        .head_digest => {
            if (replay_state.headDigest(event_plan)) |digest| {
                try definition_core.canonical_json.writeCanonicalString(
                    writer,
                    digest,
                );
            } else {
                try writer.writeAll("null");
            }
        },
        .event_kind_counts => try writeRetainedEventKindCounts(
            writer,
            event_plan,
            replay_state,
        ),
    }
}

fn writeRetainedEventKindCounts(
    writer: *std.Io.Writer,
    event_plan: *const protocol.Plan,
    replay_state: *const protocol.ReplayState,
) !void {
    try writer.writeByte('{');
    for (event_plan.event_kinds, 0..) |kind, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(writer, kind);
        try writer.writeByte(':');
        try writer.print("{d}", .{
            replay_state.eventKindCount(event_plan, index) orelse
                return error.EventKindCountMissing,
        });
    }
    try writer.writeByte('}');
}

fn writeRetainedProjectionOutput(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    projection: *const Projection,
    event_plan: *const protocol.Plan,
    retained_plan: *const state_reducer.Plan,
    replay_state: *const protocol.ReplayState,
    fields: []const RetainedField,
    max_output_bytes: usize,
) !void {
    const constructed = projection.constructed_value orelse {
        return writeRetainedProjection(
            allocator,
            writer,
            event_plan,
            retained_plan,
            replay_state,
            fields,
        );
    };
    var source: std.Io.Writer.Allocating = .init(allocator);
    defer source.deinit();
    try writeRetainedProjection(
        allocator,
        &source.writer,
        event_plan,
        retained_plan,
        replay_state,
        fields,
    );
    if (source.written().len > max_output_bytes) {
        return error.ProjectionOutputBoundsExceeded;
    }
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source.written(),
        .{
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        },
    );
    defer parsed.deinit();
    try projection_value.write(
        allocator,
        writer,
        constructed,
        parsed.value,
    );
}

fn retainedValueCount(value: std.json.Value) !usize {
    return switch (value) {
        .array => |items| items.items.len,
        .object => |items| items.count(),
        else => error.ProjectionCountRequiresCollection,
    };
}

fn executeDocument(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    limit: usize,
    writer: *std.Io.Writer,
    stats: *Stats,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        },
    );
    defer parsed.deinit();
    stats.records_scanned = 1;
    if (limit == 0 or !matches(projection, parsed.value, parameters)) {
        if (projection.require_match) return error.ProjectionNotFound;
        try writer.writeAll("null");
        return;
    }
    stats.records_matched = 1;
    stats.records_emitted = 1;
    if (projection.raw) {
        try writer.writeAll(std.mem.trim(u8, bytes, " \t\r\n"));
    } else {
        try writeProjectedValue(allocator, writer, projection, parsed.value);
    }
}

fn executeJsonl(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    limit: usize,
    max_records: usize,
    writer: *std.Io.Writer,
    stats: *Stats,
) !void {
    var latest_value: ?[]u8 = null;
    defer if (latest_value) |value| allocator.free(value);
    var latest_key: ?Scalar = null;
    defer if (latest_key) |*key| key.deinit(allocator);
    if (!projection.single) try writer.writeByte('[');
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (line.len == 0) continue;
        stats.records_scanned += 1;
        if (stats.records_scanned > max_records) {
            return error.ProjectionRecordBoundsExceeded;
        }
        const flow = try observeJsonlLine(
            allocator,
            line,
            projection,
            parameters,
            limit,
            writer,
            stats,
            &latest_value,
            &latest_key,
        );
        switch (flow) {
            .next => {},
            .stop => break,
            .complete => return,
        }
    }
    try finishJsonlProjection(
        projection,
        writer,
        stats,
        latest_value,
    );
}

const JsonlFlow = enum {
    next,
    stop,
    complete,
};

fn observeJsonlLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    projection: *const Projection,
    parameters: *const definition_core.parameters.Bindings,
    limit: usize,
    writer: *std.Io.Writer,
    stats: *Stats,
    latest_value: *?[]u8,
    latest_key: *?Scalar,
) !JsonlFlow {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        line,
        .{
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        },
    );
    defer parsed.deinit();
    if (!matches(projection, parsed.value, parameters)) return .next;
    stats.records_matched += 1;
    if (projection.latest) |pointer| {
        try updateLatestJsonl(
            allocator,
            projection,
            pointer,
            parsed.value,
            line,
            latest_value,
            latest_key,
        );
        return .next;
    }
    if (projection.single) {
        try writeJsonlValue(
            allocator,
            writer,
            projection,
            parsed.value,
            line,
        );
        stats.records_emitted = 1;
        return .complete;
    }
    if (stats.records_emitted == limit) return .stop;
    if (stats.records_emitted != 0) try writer.writeByte(',');
    try writeJsonlValue(
        allocator,
        writer,
        projection,
        parsed.value,
        line,
    );
    stats.records_emitted += 1;
    return .next;
}

fn updateLatestJsonl(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    pointer: definition_core.json_pointer.Pointer,
    value: std.json.Value,
    line: []const u8,
    latest_value: *?[]u8,
    latest_key: *?Scalar,
) !void {
    const raw_key =
        definition_core.json_pointer.lookup(value, pointer) orelse return;
    var key = try scalarFromJsonAlloc(allocator, raw_key);
    var key_owned = true;
    defer if (key_owned) key.deinit(allocator);
    if (latest_key.* != null and
        (try compareScalars(key, latest_key.*.?)) != .gt)
    {
        return;
    }
    if (latest_key.*) |*prior| prior.deinit(allocator);
    latest_key.* = key;
    key_owned = false;
    if (latest_value.*) |prior| allocator.free(prior);
    latest_value.* = if (projection.raw)
        try allocator.dupe(u8, line)
    else
        try projectedValueAlloc(allocator, projection, value);
}

fn writeJsonlValue(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    projection: *const Projection,
    value: std.json.Value,
    line: []const u8,
) !void {
    if (projection.raw) return writer.writeAll(line);
    return writeProjectedValue(allocator, writer, projection, value);
}

fn finishJsonlProjection(
    projection: *const Projection,
    writer: *std.Io.Writer,
    stats: *Stats,
    latest_value: ?[]u8,
) !void {
    if (latest_value) |value| {
        try writer.writeAll(value);
        stats.records_emitted = 1;
    } else if (projection.single) {
        if (projection.require_match) return error.ProjectionNotFound;
        try writer.writeAll("null");
    }
    if (!projection.single) try writer.writeByte(']');
}

fn executeSortedJsonl(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    limit: usize,
    max_records: usize,
    writer: *std.Io.Writer,
    stats: *Stats,
) !void {
    if (projection.single or projection.latest != null) {
        return error.InvalidSortedProjectionCardinality;
    }
    var accumulator = try SortedAccumulator.init(
        allocator,
        projection,
        parameters,
    );
    defer accumulator.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (line.len == 0) continue;
        stats.records_scanned += 1;
        if (stats.records_scanned > max_records) {
            return error.ProjectionRecordBoundsExceeded;
        }
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{
                .duplicate_field_behavior = .@"error",
                .parse_numbers = false,
            },
        );
        defer parsed.deinit();
        try accumulator.observeRaw(parsed.value, line);
    }
    try accumulator.write(writer, limit, stats);
}

fn lessSortedRow(
    keys: []const SortKey,
    left: SortedRow,
    right: SortedRow,
) bool {
    for (keys, 0..) |key, index| {
        const order = compareSortScalars(left.keys[index], right.keys[index]);
        if (order == .eq) continue;
        return switch (key.order) {
            .ascending => order == .lt,
            .descending => order == .gt,
        };
    }
    return left.record_index < right.record_index;
}

fn compareSortScalars(left: Scalar, right: Scalar) std.math.Order {
    if (left == .string and right == .string) {
        return std.mem.order(u8, left.string, right.string);
    }
    return definition_core.exact_number.orderValues(
        scalarNumberValue(left) orelse unreachable,
        scalarNumberValue(right) orelse unreachable,
    ) orelse unreachable;
}

fn matches(
    projection: *const Projection,
    value: std.json.Value,
    parameters: *const definition_core.parameters.Bindings,
) bool {
    for (projection.predicates) |group| {
        switch (group) {
            .one => |predicate| {
                if (!predicateMatches(predicate, value, parameters)) {
                    return false;
                }
            },
            .any => |sets| {
                var matched = false;
                for (sets) |set| {
                    var set_matched = true;
                    for (set.predicates) |predicate| {
                        if (!predicateMatches(
                            predicate,
                            value,
                            parameters,
                        )) {
                            set_matched = false;
                            break;
                        }
                    }
                    if (set_matched) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) return false;
            },
        }
    }
    return true;
}

fn predicateMatches(
    predicate: Predicate,
    value: std.json.Value,
    parameters: *const definition_core.parameters.Bindings,
) bool {
    const actual = definition_core.json_pointer.lookup(
        value,
        predicate.pointer,
    ) orelse return false;
    const expected = switch (predicate.operand) {
        .constant => |constant| constant,
        .parameter => |name| scalarFromBinding(parameters, name) orelse
            return false,
    };
    return scalarEqualsJson(expected, actual);
}

fn writeProjectedValue(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    projection: *const Projection,
    value: std.json.Value,
) !void {
    if (projection.constructed_value) |constructed| {
        try projection_value.write(
            allocator,
            writer,
            constructed,
            value,
        );
        return;
    }
    if (projection.value_path) |pointer| {
        const selected = definition_core.json_pointer.lookup(
            value,
            pointer,
        ) orelse return error.ProjectionFieldMissing;
        try std.json.Stringify.value(selected, .{}, writer);
        return;
    }
    if (projection.fields.len == 0) {
        try definition_core.canonical_json.writeCanonicalJson(
            allocator,
            writer,
            value,
        );
        return;
    }
    try writer.writeByte('{');
    for (projection.fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try definition_core.canonical_json.writeCanonicalString(
            writer,
            field.name,
        );
        try writer.writeByte(':');
        const selected = definition_core.json_pointer.lookup(
            value,
            field.pointer,
        ) orelse return error.ProjectionFieldMissing;
        if (projection.preserve_field_order) {
            try std.json.Stringify.value(selected, .{}, writer);
        } else {
            try definition_core.canonical_json.writeCanonicalJson(
                allocator,
                writer,
                selected,
            );
        }
    }
    try writer.writeByte('}');
}

fn projectedValueAlloc(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    value: std.json.Value,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeProjectedValue(allocator, &output.writer, projection, value);
    return output.toOwnedSlice();
}

fn projectedValueWithScoreAlloc(
    allocator: std.mem.Allocator,
    projection: *const Projection,
    value: std.json.Value,
    score_field: ?[]const u8,
    score: f64,
) ![]u8 {
    const field = score_field orelse
        return projectedValueAlloc(allocator, projection, value);
    const projected = try projectedValueAlloc(allocator, projection, value);
    defer allocator.free(projected);
    if (projected.len < 2 or projected[0] != '{' or
        projected[projected.len - 1] != '}')
    {
        return error.RelevanceScoreRequiresProjectionObject;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('{');
    try definition_core.canonical_json.writeCanonicalString(
        &output.writer,
        field,
    );
    try output.writer.print(":{d}", .{score});
    if (projected.len > 2) {
        try output.writer.writeByte(',');
        try output.writer.writeAll(projected[1 .. projected.len - 1]);
    }
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn prepareRelevanceAlloc(
    allocator: std.mem.Allocator,
    relevance: Relevance,
    parameters: *const definition_core.parameters.Bindings,
) !PreparedRelevance {
    const binding = parameters.find(relevance.parameter) orelse
        return error.MissingParameter;
    const query = switch (binding.value) {
        .string => |text| text,
        else => return error.ProjectionRelevanceParameterMustBeString,
    };
    if (query.len == 0) return error.ProjectionQueryEmpty;
    if (relevance.ranked_plan) |ranked| {
        return .{ .ranked = try ranked_relevance.prepare(
            allocator,
            ranked,
            query,
            parameters,
        ) };
    }
    const lower = try allocator.alloc(u8, query.len);
    for (query, 0..) |char, index| {
        lower[index] = asciiLower(char);
    }
    return .{ .basic = lower };
}

fn relevanceScoreAlloc(
    allocator: std.mem.Allocator,
    relevance: Relevance,
    prepared: *const PreparedRelevance,
    value: std.json.Value,
) !?f64 {
    if (relevance.ranked_plan) |ranked| {
        return ranked_relevance.score(
            allocator,
            ranked,
            &prepared.ranked,
            relevance.paths,
            value,
        );
    }
    const query_lower = prepared.basic;
    var search_text: std.Io.Writer.Allocating = .init(allocator);
    defer search_text.deinit();
    var emitted = false;
    for (relevance.paths) |path| {
        const selected = definition_core.json_pointer.lookup(
            value,
            path,
        ) orelse continue;
        if (emitted) try search_text.writer.writeByte(' ');
        switch (selected) {
            .string => |text| try search_text.writer.writeAll(text),
            else => try definition_core.canonical_json.writeCanonicalJson(
                allocator,
                &search_text.writer,
                selected,
            ),
        }
        emitted = true;
    }
    const haystack = search_text.written();
    const score = lexicalRelevanceScore(query_lower, haystack);
    return switch (relevance.mode) {
        .literal => if (containsAsciiFold(haystack, query_lower))
            @floatFromInt(score)
        else
            null,
        .tokens => if (score != 0) @floatFromInt(score) else null,
        .ranked_tokens => unreachable,
    };
}

fn lexicalRelevanceScore(
    query_lower: []const u8,
    haystack: []const u8,
) usize {
    var score: usize = 0;
    var tokens = std.mem.tokenizeAny(
        u8,
        query_lower,
        " \t\r\n,.;:/()[]{}<>\"'`",
    );
    while (tokens.next()) |token| {
        if (token.len < 2) continue;
        if (containsAsciiFold(haystack, token)) score += 1;
    }
    return score;
}

fn containsAsciiFold(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return true;
    if (needle_lower.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle_lower.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle_lower, 0..) |expected, offset| {
            if (asciiLower(haystack[start + offset]) != expected) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn asciiLower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

fn scalarFromJsonAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !Scalar {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .float = number },
        .number_string => |text| number: {
            const parsed = definition_core.exact_number.parse(text) orelse
                return error.ProjectionScalarRequired;
            if (definition_core.exact_number.toI64(parsed)) |integer| {
                break :number .{ .integer = integer };
            }
            break :number .{ .number = try allocator.dupe(u8, text) };
        },
        .bool => |flag| .{ .boolean = flag },
        .null => .null,
        else => error.ProjectionScalarRequired,
    };
}

fn scalarFromBinding(
    bindings: *const definition_core.parameters.Bindings,
    name: []const u8,
) ?Scalar {
    for (bindings.items) |binding| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        return switch (binding.value) {
            .string => |text| .{ .string = @constCast(text) },
            .integer => |number| .{ .integer = number },
            .boolean => |flag| .{ .boolean = flag },
            .digest,
            .timestamp,
            .safe_identifier,
            .relative_path,
            => |text| .{ .string = @constCast(text) },
        };
    }
    return null;
}

fn scalarEqualsJson(expected: Scalar, actual: std.json.Value) bool {
    return switch (expected) {
        .string => |text| actual == .string and
            std.mem.eql(u8, text, actual.string),
        .number, .integer, .float => definition_core.exact_number.valuesEqual(
            scalarNumberValue(expected).?,
            actual,
        ),
        .boolean => |flag| actual == .bool and actual.bool == flag,
        .null => actual == .null,
    };
}

fn compareScalars(left: Scalar, right: Scalar) !std.math.Order {
    if (left == .string and right == .string) {
        return std.mem.order(u8, left.string, right.string);
    }
    const left_number = scalarNumberValue(left) orelse
        return error.ProjectionOrderingTypeMismatch;
    const right_number = scalarNumberValue(right) orelse
        return error.ProjectionOrderingTypeMismatch;
    return definition_core.exact_number.orderValues(
        left_number,
        right_number,
    ) orelse error.ProjectionOrderingTypeMismatch;
}

fn scalarKindsCompatible(left: Scalar, right: Scalar) bool {
    if (left == .string or right == .string) {
        return left == .string and right == .string;
    }
    return scalarNumberValue(left) != null and scalarNumberValue(right) != null;
}

fn scalarNumberValue(value: Scalar) ?std.json.Value {
    return switch (value) {
        .number => |text| .{ .number_string = text },
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .float = number },
        else => null,
    };
}

fn resolveLimit(
    maybe_limit: ?Limit,
    parameters: *const definition_core.parameters.Bindings,
    max_records: usize,
) !usize {
    const limit = maybe_limit orelse return max_records;
    const value: usize = switch (limit) {
        .fixed => |count| count,
        .parameter => |name| blk: {
            for (parameters.items) |binding| {
                if (!std.mem.eql(u8, binding.name, name)) continue;
                break :blk switch (binding.value) {
                    .integer => |number| if (number > 0)
                        @intCast(number)
                    else
                        return error.InvalidProjectionLimit,
                    else => return error.ProjectionLimitParameterMustBeInteger,
                };
            }
            return error.MissingParameter;
        },
    };
    if (value == 0 or value > max_records) return error.InvalidProjectionLimit;
    return value;
}

const test_definition_schema =
    "{\"schema\":\"ledger-artifact-definition/v1\",\"owner\":\"example\",";
const test_event_input =
    "\"inputs\":{\"event\":{\"codec\":\"json\",\"max_bytes\":4096}}," ++
    "\"canonicalization\":{},\"shape\":{},";
const test_event_storage =
    "\"identity\":{},\"storage\":{\"kind\":\"event-log\",\"slots\":{" ++
    "\"events\":{\"path\":\"example/events.jsonl\",\"kind\":\"event-log\"," ++
    "\"codec\":\"jsonl\",\"max_bytes\":65536}}},";
const test_empty_operations = "\"operations\":{},";
const test_append_operation =
    "\"operations\":{\"append\":{\"effects\":[{\"op\":\"compare-and-append\"," ++
    "\"slot\":\"events\",\"input\":\"event\"}]}},";
const test_bounds_4 =
    "\"bounds\":{\"max_input_bytes\":4096,\"max_store_bytes\":65536," ++
    "\"max_records\":4,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":4}}";
const test_bounds_100 =
    "\"bounds\":{\"max_input_bytes\":4096,\"max_store_bytes\":65536," ++
    "\"max_records\":100,\"max_output_bytes\":4096,\"max_diagnostics\":8," ++
    "\"max_reducer_states\":16}}";

const cache_projection_definition =
    test_definition_schema ++
    "\"id\":\"example/projection\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"filter\",\"latest\",\"limit\",\"select\"]}," ++
    "\"parameters\":{\"kind\":{\"type\":\"string\",\"required\":false}}," ++
    test_event_input ++
    "\"constraints\":{\"laws\":[]}," ++
    test_event_storage ++
    test_empty_operations ++
    "\"projections\":{\"recent\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"filter\",\"path\":\"/kind\",\"param\":\"kind\"}," ++
    "{\"op\":\"select\",\"fields\":{\"kind\":\"/kind\",\"value\":\"/value\"}}," ++
    "{\"op\":\"limit\",\"count\":10}]}}," ++
    test_bounds_100;

const retained_projection_definition =
    test_definition_schema ++
    "\"id\":\"example/retained-export\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"append-only-log\",\"compare-and-append\",\"event-kinds\",\"export\"," ++
    "\"fold\",\"reducer\",\"replay\"]},\"parameters\":{}," ++
    test_event_input ++
    "\"constraints\":{\"laws\":[[\"append-only-log\",{\"input\":\"event\"}]," ++
    "[\"event-kinds\",{\"values\":[\"created\"]}]],\"state\":{" ++
    "\"mode\":\"retained\",\"event_kind\":\"/kind\",\"registers\":{" ++
    "\"current\":4096},\"sets\":{},\"admissions\":[{\"on\":\"created\"," ++
    "\"forbids\":[\"current\"],\"actions\":[[\"set\",\"current\"," ++
    "\"event#/body\"]]}]}}," ++
    test_event_storage ++
    test_append_operation ++
    "\"projections\":{\"facts\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"fold\",\"fields\":{\"current_id\":{\"register\":\"current\"," ++
    "\"path\":\"/id\"},\"event_count\":{\"meta\":\"record-count\"}}}," ++
    "{\"op\":\"export\",\"value\":{\"object\":[{\"name\":\"schema\"," ++
    "\"value\":{\"literal\":\"example-facts/v1\"}},{\"name\":\"rows\"," ++
    "\"value\":{\"array\":[{\"object\":[{\"name\":\"current_id\"," ++
    "\"value\":{\"path\":\"/current_id\"}},{\"name\":\"event_count\"," ++
    "\"value\":{\"path\":\"/event_count\"}}]}]}}]}}]}}," ++
    test_bounds_4;

const history_projection_definition =
    test_definition_schema ++
    "\"id\":\"example/history\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"append-only-log\",\"compare-and-append\",\"event-kinds\",\"fold\"," ++
    "\"reducer\",\"replay\",\"sha256\",\"transition-table\"]}," ++
    "\"parameters\":{}," ++ test_event_input ++
    "\"constraints\":{\"laws\":[[\"append-only-log\",{\"input\":\"event\"}]," ++
    "[\"event-kinds\",{\"values\":[\"capture\",\"status\"]}]," ++
    "[\"reducer\",{\"key\":\"/id\",\"on\":\"/status\"," ++
    "\"event_kind\":\"/kind\",\"retain_once\":\"/record\"}]," ++
    "[\"transition-table\",{\"states\":[\"active\",\"inactive\"]," ++
    "\"transitions\":[{\"from\":null,\"on\":\"active\",\"to\":\"active\"}," ++
    "{\"from\":\"active\",\"on\":\"inactive\",\"to\":\"inactive\"}]}]]}," ++
    test_event_storage ++ test_append_operation ++
    "\"projections\":{\"current\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"fold\",\"key_field\":\"id\",\"state_field\":\"status\"," ++
    "\"retained_field\":\"record\",\"event_count_field\":\"event_count\"," ++
    "\"event_kind_counts\":[{\"kind\":\"capture\"," ++
    "\"field\":\"capture_count\"},{\"kind\":\"status\"," ++
    "\"field\":\"status_count\"}],\"event_chain\":{\"field\":\"chain\"," ++
    "\"fragments\":[{\"literal\":\"generic-chain/v1\\n\"}," ++
    "{\"source\":\"previous-event-chain\"},{\"literal\":\"\\n\"}," ++
    "{\"source\":\"event-bytes\"}]},\"snapshot\":{\"field\":\"snapshot\"," ++
    "\"prior_field\":\"prior_snapshot\",\"prior_on\":[\"status\"]," ++
    "\"fragments\":[{\"literal\":\"generic-snapshot/v1\\n\"}," ++
    "{\"source\":\"key\"},{\"literal\":\"\\n\"},{\"source\":\"state\"}," ++
    "{\"literal\":\"\\n\"},{\"source\":\"retained\"}," ++
    "{\"literal\":\"\\n\"},{\"retained_text\":\"/repository_id\"}," ++
    "{\"literal\":\"\\n\"},{\"source\":\"event-chain\"}]}}]}}," ++
    test_bounds_4;

const gate_projection_definition =
    test_definition_schema ++
    "\"id\":\"example/gate\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"append-only-log\",\"compare-and-append\",\"event-kinds\",\"filter\"," ++
    "\"fold\",\"limit\",\"reducer\",\"replay\",\"transition-table\"]}," ++
    "\"parameters\":{\"artifact\":{\"type\":\"string\",\"required\":true}," ++
    "\"identity\":{\"type\":\"string\",\"required\":true}}," ++
    test_event_input ++
    "\"constraints\":{\"laws\":[[\"append-only-log\",{\"input\":\"event\"}]," ++
    "[\"event-kinds\",{\"values\":[\"capture\"]}]," ++
    "[\"reducer\",{\"key\":\"/id\",\"on\":\"/status\"," ++
    "\"event_kind\":\"/kind\",\"retain_once\":\"/record\"}]," ++
    "[\"transition-table\",{\"states\":[\"active\"]," ++
    "\"transitions\":[{\"from\":null,\"on\":\"active\",\"to\":\"active\"}]}]]}," ++
    test_event_storage ++ test_append_operation ++
    "\"projections\":{\"gate\":{\"slot\":\"events\"," ++
    "\"required_parameters\":[\"artifact\",\"identity\"],\"pipeline\":[" ++
    "{\"op\":\"fold\",\"key_field\":\"id\",\"state_field\":\"status\"," ++
    "\"retained_field\":\"record\"}," ++
    "{\"op\":\"filter\",\"path\":\"/status\",\"equals\":\"active\"}," ++
    "{\"op\":\"filter\",\"path\":\"/record/artifact\",\"param\":\"artifact\"}," ++
    "{\"op\":\"filter\",\"any\":[{\"all\":[" ++
    "{\"path\":\"/record/scope\",\"equals\":\"route\"}," ++
    "{\"path\":\"/record/route\",\"param\":\"identity\"}]}," ++
    "{\"all\":[{\"path\":\"/record/scope\",\"equals\":\"cluster\"}," ++
    "{\"path\":\"/record/cluster\",\"param\":\"identity\"}]}]}," ++
    "{\"op\":\"limit\",\"count\":1}],\"exit\":{\"matched\":2," ++
    "\"unmatched\":0,\"failure\":3}}}," ++
    test_bounds_4;

const exact_projection_definition =
    test_definition_schema ++
    "\"id\":\"example/exact-export\"," ++
    "\"requires\":{\"abi\":\"ledger-artifact-abi/v1\",\"operators\":[" ++
    "\"export\",\"id-lookup\",\"latest\",\"limit\",\"relevance\",\"sort\"]}," ++
    "\"parameters\":{\"id\":{\"type\":\"string\",\"required\":false}," ++
    "\"query\":{\"type\":\"string\",\"required\":false}}," ++
    test_event_input ++ "\"constraints\":{\"laws\":[]}," ++
    test_event_storage ++ test_empty_operations ++
    "\"projections\":{" ++
    "\"latest\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"latest\",\"path\":\"/record/id\"}," ++
    "{\"op\":\"export\",\"fields\":[" ++
    "{\"name\":\"operation\",\"path\":\"/record/operation\"}," ++
    "{\"name\":\"authority\",\"path\":\"/record/authority\"}]}]}," ++
    "\"nested\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"id-lookup\",\"path\":\"/record/id\",\"param\":\"id\"}," ++
    "{\"op\":\"export\",\"path\":\"/record\"}]}," ++
    "\"ordered\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"id-lookup\",\"path\":\"/record/id\",\"param\":\"id\"}," ++
    "{\"op\":\"export\",\"fields\":[" ++
    "{\"name\":\"operation\",\"path\":\"/record/operation\"}," ++
    "{\"name\":\"authority\",\"path\":\"/record/authority\"}," ++
    "{\"name\":\"metadata\",\"path\":\"/record/metadata\"}]}]}," ++
    "\"query\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"relevance\",\"paths\":[\"/record/operation\"," ++
    "\"/record/authority\"],\"param\":\"query\",\"mode\":\"literal\"}," ++
    "{\"op\":\"sort\",\"keys\":[{\"meta\":\"relevance-score\"," ++
    "\"order\":\"descending\"},{\"meta\":\"record-order\"," ++
    "\"order\":\"descending\"}]}," ++
    "{\"op\":\"export\",\"fields\":[" ++
    "{\"name\":\"operation\",\"path\":\"/record/operation\"}," ++
    "{\"name\":\"authority\",\"path\":\"/record/authority\"}]}," ++
    "{\"op\":\"limit\",\"count\":10}]}," ++
    "\"raw\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"id-lookup\",\"path\":\"/record/id\",\"param\":\"id\"}," ++
    "{\"op\":\"export\",\"raw\":true}]}," ++
    "\"recall\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"relevance\",\"paths\":[\"/record/operation\"," ++
    "\"/record/authority\"],\"param\":\"query\",\"mode\":\"tokens\"," ++
    "\"score_field\":\"score\"}," ++
    "{\"op\":\"sort\",\"keys\":[{\"meta\":\"relevance-score\"," ++
    "\"order\":\"descending\"},{\"meta\":\"record-order\"," ++
    "\"order\":\"descending\"}]}," ++
    "{\"op\":\"export\",\"fields\":[" ++
    "{\"name\":\"operation\",\"path\":\"/record/operation\"}," ++
    "{\"name\":\"authority\",\"path\":\"/record/authority\"}]}," ++
    "{\"op\":\"limit\",\"count\":10}]}," ++
    "\"recent\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"sort\",\"keys\":[{\"meta\":\"record-order\"," ++
    "\"order\":\"descending\"}]}," ++
    "{\"op\":\"export\",\"fields\":[" ++
    "{\"name\":\"operation\",\"path\":\"/record/operation\"}," ++
    "{\"name\":\"authority\",\"path\":\"/record/authority\"}]}," ++
    "{\"op\":\"limit\",\"count\":2}]}," ++
    "\"required\":{\"slot\":\"events\",\"pipeline\":[" ++
    "{\"op\":\"id-lookup\",\"path\":\"/record/id\",\"param\":\"id\"," ++
    "\"required\":true},{\"op\":\"export\",\"raw\":true}]}}," ++
    test_bounds_100;

const exact_rows =
    "{\"v\":1,\"record\":{\"id\":\"r1\",\"authority\":\"a1\"," ++
    "\"operation\":\"o1\",\"metadata\":{\"z\":\"last\",\"a\":\"first\"}}}\n" ++
    "{\"record\":{\"operation\":\"o2\",\"id\":\"r2\"," ++
    "\"authority\":\"a2\"},\"v\":1}\n";
const exact_ordered_output =
    "{\"operation\":\"o1\",\"authority\":\"a1\"," ++
    "\"metadata\":{\"z\":\"last\",\"a\":\"first\"}}";
const exact_raw_output =
    "{\"v\":1,\"record\":{\"id\":\"r1\",\"authority\":\"a1\"," ++
    "\"operation\":\"o1\",\"metadata\":{\"z\":\"last\",\"a\":\"first\"}}}";
const exact_nested_output =
    "{\"id\":\"r1\",\"authority\":\"a1\",\"operation\":\"o1\"," ++
    "\"metadata\":{\"z\":\"last\",\"a\":\"first\"}}";
const exact_recent_output =
    "[{\"operation\":\"o2\",\"authority\":\"a2\"}," ++
    "{\"operation\":\"o1\",\"authority\":\"a1\"}]";
const exact_query_output =
    "[{\"operation\":\"o2\",\"authority\":\"a2\"}]";
const exact_recall_output =
    "[{\"score\":1,\"operation\":\"o2\",\"authority\":\"a2\"}," ++
    "{\"score\":1,\"operation\":\"o1\",\"authority\":\"a1\"}]";
const exact_latest_output =
    "{\"operation\":\"o2\",\"authority\":\"a2\"}";

const ProjectionTestPlans = struct {
    tmp: std.testing.TmpDir,
    closure: definition_core.closure.Closure,
    definition_plan: definition.Plan,
    storage_plan: storage.Plan,
    protocol_plan: ?protocol.Plan,
    plan: Plan,
    cached: Plan,

    fn init(source: []const u8) !ProjectionTestPlans {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "protocol.json",
            .data = source,
        });
        var closure = try definition_core.closure.loadFromDir(
            std.testing.allocator,
            &tmp.dir,
            "protocol.json",
            .{},
        );
        errdefer closure.deinit(std.testing.allocator);
        var definition_plan = try definition.compile(
            std.testing.allocator,
            &closure,
            "protocol.json",
        );
        errdefer definition_plan.deinit(std.testing.allocator);
        var storage_plan = try storage.compile(
            std.testing.allocator,
            &definition_plan,
        );
        errdefer storage_plan.deinit(std.testing.allocator);
        var protocol_plan = try protocol.compile(
            std.testing.allocator,
            &definition_plan,
            &storage_plan,
        );
        errdefer if (protocol_plan) |*value| {
            value.deinit(std.testing.allocator);
        };
        var plan = try compile(
            std.testing.allocator,
            &definition_plan,
            &storage_plan,
            if (protocol_plan) |*value| value else null,
        );
        errdefer plan.deinit(std.testing.allocator);
        var cached = try cacheTestPlan(
            &plan,
            &definition_plan,
            &storage_plan,
            if (protocol_plan) |*value| value else null,
        );
        errdefer cached.deinit(std.testing.allocator);
        return .{
            .tmp = tmp,
            .closure = closure,
            .definition_plan = definition_plan,
            .storage_plan = storage_plan,
            .protocol_plan = protocol_plan,
            .plan = plan,
            .cached = cached,
        };
    }

    fn deinit(self: *ProjectionTestPlans) void {
        self.cached.deinit(std.testing.allocator);
        self.plan.deinit(std.testing.allocator);
        if (self.protocol_plan) |*value| {
            value.deinit(std.testing.allocator);
        }
        self.storage_plan.deinit(std.testing.allocator);
        self.definition_plan.deinit(std.testing.allocator);
        self.closure.deinit(std.testing.allocator);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn cacheTestPlan(
    plan: *const Plan,
    definition_plan: *const definition.Plan,
    storage_plan: *const storage.Plan,
    protocol_plan: ?*const protocol.Plan,
) !Plan {
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        64 * 1024,
    );
    defer encoder.deinit();
    try encodeCache(plan, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = definition_core.cache.Decoder.init(payload);
    var cached = try decodeCache(std.testing.allocator, &decoder);
    errdefer cached.deinit(std.testing.allocator);
    try decoder.finish();
    try validateCachePlan(
        &cached,
        definition_plan,
        storage_plan,
        protocol_plan,
    );
    return cached;
}

test "projection plan round trips through the bounded cache codec" {
    var plans = try ProjectionTestPlans.init(cache_projection_definition);
    defer plans.deinit();
    try std.testing.expectEqual(
        plans.plan.projections.len,
        plans.cached.projections.len,
    );
    try std.testing.expectEqualStrings(
        plans.plan.projections[0].name,
        plans.cached.projections[0].name,
    );
    try std.testing.expectEqual(
        plans.plan.projections[0].predicates.len,
        plans.cached.projections[0].predicates.len,
    );
    try std.testing.expectEqual(
        plans.plan.projections[0].fields.len,
        plans.cached.projections[0].fields.len,
    );
}

test "retained fold exports one bounded constructed relation" {
    var plans = try ProjectionTestPlans.init(
        retained_projection_definition,
    );
    defer plans.deinit();
    const facts = plans.cached.find("facts").?;
    const protocol_plan = &plans.protocol_plan.?;
    try std.testing.expect(facts.constructed_value != null);
    const retained = switch (facts.fold.?) {
        .retained => |value| value,
        .keyed => return error.TestExpectedRetainedFold,
    };
    var replay_state = protocol.ReplayState.init(protocol_plan);
    defer replay_state.deinit(std.testing.allocator);
    var event = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"kind\":\"created\",\"body\":{\"id\":\"item-1\"}}",
        .{},
    );
    defer event.deinit();
    try protocol.applyValue(
        std.testing.allocator,
        protocol_plan,
        &replay_state,
        event.value,
    );
    var output: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer output.deinit();
    try writeRetainedProjectionOutput(
        std.testing.allocator,
        &output.writer,
        facts,
        protocol_plan,
        &protocol_plan.state_reducer_plan.?,
        &replay_state,
        retained.fields,
        4096,
    );
    try std.testing.expectEqualStrings(
        "{\"schema\":\"example-facts/v1\"," ++
            "\"rows\":[{\"current_id\":\"item-1\",\"event_count\":1}]}",
        output.written(),
    );
}

test "keyed fold history compiles once and preserves exact replay digests" {
    var plans = try ProjectionTestPlans.init(
        history_projection_definition,
    );
    defer plans.deinit();
    const projection_plan = plans.cached.find("current").?;
    const keyed = switch (projection_plan.fold.?) {
        .keyed => |value| value,
        .retained => return error.TestExpectedKeyedFold,
    };
    try std.testing.expect(keyed.history.active());
    try std.testing.expectEqual(
        @as(usize, 2),
        keyed.history.event_kind_counts.len,
    );
    try verifyKeyedHistory(&plans, &keyed);
}

fn verifyKeyedHistory(
    plans: *ProjectionTestPlans,
    keyed: *const KeyedFold,
) !void {
    const protocol_plan = &plans.protocol_plan.?;
    const reducer_plan = &protocol_plan.reducer_plan.?;
    var accumulator = FoldHistoryAccumulator.init(
        std.testing.allocator,
        keyed,
        reducer_plan,
    );
    defer accumulator.deinit();
    var replay_state = protocol.ReplayState.init(protocol_plan);
    defer replay_state.deinit(std.testing.allocator);
    try applyHistoryEvents(protocol_plan, &replay_state, &accumulator);
    try expectHistoryDigests(&accumulator);
    try expectHistoryRows(&replay_state, &accumulator, keyed);
}

fn applyHistoryEvents(
    protocol_plan: *const protocol.Plan,
    replay_state: *protocol.ReplayState,
    accumulator: *FoldHistoryAccumulator,
) !void {
    const capture =
        "{\"kind\":\"capture\",\"id\":\"case-a\",\"status\":\"active\"," ++
        "\"record\":{\"repository_id\":\"repo/example\",\"x\":1}}";
    const status =
        "{\"kind\":\"status\",\"id\":\"case-a\",\"status\":\"inactive\"}";
    for ([_][]const u8{ capture, status }) |raw| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            raw,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        try protocol.applyValue(
            std.testing.allocator,
            protocol_plan,
            replay_state,
            parsed.value,
        );
        try accumulator.observeReplay(
            parsed.value,
            raw,
            replay_state,
        );
    }
}

fn expectHistoryDigests(accumulator: *const FoldHistoryAccumulator) !void {
    const history = accumulator.get("case-a").?;
    try std.testing.expectEqual(@as(usize, 1), history.event_kind_counts[0]);
    try std.testing.expectEqual(@as(usize, 1), history.event_kind_counts[1]);
    try std.testing.expectEqualStrings(
        "cc525ecd681ac944bbf7de0baaedf9c2f206f1212b19770187a8cd54d26fb1a7",
        &history.event_chain,
    );
    try std.testing.expectEqualStrings(
        "8cb3c1bb975df1ad3b58df5846687dc0c28563dd834f8ab6420632190f21851a",
        &history.prior_snapshot,
    );
    try std.testing.expectEqualStrings(
        "5c7891af5a74353974cd09a86ec4eec7cba9b3e80aef802199947cb60c1632f7",
        &history.snapshot,
    );
}

fn expectHistoryRows(
    replay_state: *protocol.ReplayState,
    accumulator: *FoldHistoryAccumulator,
    keyed: *const KeyedFold,
) !void {
    var output: std.Io.Writer.Allocating =
        .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        try writeKeyedHistoryRows(
            std.testing.allocator,
            &output,
            &replay_state.reducer_state,
            accumulator,
            keyed,
            4,
            4096,
            null,
        ),
    );
    try std.testing.expectEqualStrings(
        "[{\"capture_count\":1," ++
            "\"chain\":\"cc525ecd681ac944bbf7de0baaedf9c2f206f1212b19770187a8cd54d26fb1a7\"," ++
            "\"event_count\":2,\"id\":\"case-a\"," ++
            "\"prior_snapshot\":\"8cb3c1bb975df1ad3b58df5846687dc0" ++
            "c28563dd834f8ab6420632190f21851a\"," ++
            "\"record\":{\"repository_id\":\"repo/example\",\"x\":1}," ++
            "\"snapshot\":\"5c7891af5a74353974cd09a86ec4eec7cba9b3e80aef802199947cb60c1632f7\"," ++
            "\"status\":\"inactive\",\"status_count\":1}]",
        output.written(),
    );
}

test "keyed fold filters bounded disjunctions and declares exit semantics" {
    var plans = try ProjectionTestPlans.init(gate_projection_definition);
    defer plans.deinit();
    const gate = plans.cached.find("gate").?;
    try std.testing.expectEqual(@as(u8, 2), gate.exit_policy.matched);
    try std.testing.expectEqual(@as(u8, 0), gate.exit_policy.unmatched);
    try std.testing.expectEqual(@as(?u8, 3), gate.exit_policy.failure);
    try std.testing.expectEqual(@as(usize, 3), gate.predicates.len);
    try std.testing.expectEqual(
        @as(usize, 2),
        gate.required_parameters.len,
    );
    try std.testing.expectEqual(@as(usize, 2), gate.predicates[2].any.len);
    try verifyGateProjection(&plans, gate);
}

fn verifyGateProjection(
    plans: *ProjectionTestPlans,
    gate: *const Projection,
) !void {
    const protocol_plan = &plans.protocol_plan.?;
    var replay_state = protocol.ReplayState.init(protocol_plan);
    defer replay_state.deinit(std.testing.allocator);
    try applyGateEvents(protocol_plan, &replay_state);
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &plans.definition_plan.parameter_declarations,
        &.{
            .{ .name = "artifact", .raw_value = "sha256:a" },
            .{ .name = "identity", .raw_value = "route-a" },
        },
    );
    defer bindings.deinit(std.testing.allocator);
    const keyed = switch (gate.fold.?) {
        .keyed => |value| value,
        .retained => return error.TestExpectedKeyedFold,
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const counts = try writeFilteredKeyedFold(
        std.testing.allocator,
        &output,
        gate,
        &keyed,
        &replay_state.reducer_state,
        null,
        &bindings,
        1,
        4096,
    );
    try std.testing.expectEqual(@as(usize, 1), counts.matched);
    try std.testing.expectEqual(@as(usize, 1), counts.emitted);
    try std.testing.expectEqualStrings(
        "[{\"id\":\"case-a\",\"record\":{" ++
            "\"artifact\":\"sha256:a\",\"cluster\":\"cluster-a\"," ++
            "\"route\":\"route-a\",\"scope\":\"route\"}," ++
            "\"status\":\"active\"}]",
        output.written(),
    );
}

fn applyGateEvents(
    protocol_plan: *const protocol.Plan,
    replay_state: *protocol.ReplayState,
) !void {
    const route =
        "{\"kind\":\"capture\",\"id\":\"case-a\",\"status\":\"active\"," ++
        "\"record\":{\"artifact\":\"sha256:a\",\"cluster\":\"cluster-a\"," ++
        "\"route\":\"route-a\",\"scope\":\"route\"}}";
    const cluster =
        "{\"kind\":\"capture\",\"id\":\"case-b\",\"status\":\"active\"," ++
        "\"record\":{\"artifact\":\"sha256:a\",\"cluster\":\"cluster-a\"," ++
        "\"route\":\"route-a\",\"scope\":\"cluster\"}}";
    for ([_][]const u8{ route, cluster }) |raw| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            raw,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        try protocol.applyValue(
            std.testing.allocator,
            protocol_plan,
            replay_state,
            parsed.value,
        );
    }
}
test "exact lookup emits one definition-ordered or raw payload" {
    var plans = try ProjectionTestPlans.init(exact_projection_definition);
    defer plans.deinit();
    try expectExactProjectionShapes(&plans.cached);
    try verifyExactLookupOutputs(&plans);
    try verifyRelevanceOutputs(&plans);
    try verifyRequiredLookupFailure(&plans);
}

test "projected JSONL preserves precision-sensitive numeric tokens" {
    var plans = try ProjectionTestPlans.init(exact_projection_definition);
    defer plans.deinit();
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &plans.definition_plan.parameter_declarations,
        &.{.{ .name = "id", .raw_value = "precise" }},
    );
    defer bindings.deinit(std.testing.allocator);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try executeJsonl(
        std.testing.allocator,
        plans.cached.find("nested").?,
        "{\"record\":{\"id\":\"precise\"," ++
            "\"value\":9007199254740992.1}}\n",
        &bindings,
        1,
        1,
        &output.writer,
        &stats,
    );
    try std.testing.expectEqualStrings(
        "{\"id\":\"precise\",\"value\":9007199254740992.1}",
        output.written(),
    );
}

fn expectExactProjectionShapes(cached: *const Plan) !void {
    const ordered = cached.find("ordered").?;
    try std.testing.expect(ordered.single);
    try std.testing.expect(ordered.preserve_field_order);
    try std.testing.expect(!ordered.raw);
    try std.testing.expectEqualStrings("operation", ordered.fields[0].name);
    try std.testing.expectEqualStrings("authority", ordered.fields[1].name);
    try std.testing.expectEqualStrings("metadata", ordered.fields[2].name);
    const raw = cached.find("raw").?;
    try std.testing.expect(raw.single);
    try std.testing.expect(raw.raw);
    try std.testing.expectEqual(@as(usize, 0), raw.fields.len);
    const nested = cached.find("nested").?;
    try std.testing.expect(nested.single);
    try std.testing.expect(nested.value_path != null);
    try std.testing.expectEqualStrings("/record", nested.value_path.?.raw);
}

fn verifyExactLookupOutputs(plans: *ProjectionTestPlans) !void {
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &plans.definition_plan.parameter_declarations,
        &.{.{ .name = "id", .raw_value = "r1" }},
    );
    defer bindings.deinit(std.testing.allocator);
    try expectJsonlOutput(
        plans.cached.find("ordered").?,
        &bindings,
        exact_ordered_output,
        1,
        1,
    );
    try expectJsonlOutput(
        plans.cached.find("raw").?,
        &bindings,
        exact_raw_output,
        1,
        1,
    );
    try expectJsonlOutput(
        plans.cached.find("nested").?,
        &bindings,
        exact_nested_output,
        1,
        1,
    );
    const recent = plans.cached.find("recent").?;
    try std.testing.expect(recent.sort_keys[0].source == .record_order);
    try std.testing.expectEqual(.descending, recent.sort_keys[0].order);
    try expectSortedOutput(
        recent,
        &bindings,
        2,
        exact_recent_output,
        2,
        2,
        2,
    );
    const latest = plans.cached.find("latest").?;
    try std.testing.expect(latest.single);
    try expectJsonlOutput(latest, &bindings, exact_latest_output, 2, 1);
}

fn verifyRelevanceOutputs(plans: *ProjectionTestPlans) !void {
    var query = try definition_core.parameters.bind(
        std.testing.allocator,
        &plans.definition_plan.parameter_declarations,
        &.{.{ .name = "query", .raw_value = "O2 A2" }},
    );
    defer query.deinit(std.testing.allocator);
    const query_projection = plans.cached.find("query").?;
    try std.testing.expectEqual(
        RelevanceMode.literal,
        query_projection.relevance.?.mode,
    );
    try expectSortedOutput(
        query_projection,
        &query,
        10,
        exact_query_output,
        2,
        1,
        1,
    );
    var recall = try definition_core.parameters.bind(
        std.testing.allocator,
        &plans.definition_plan.parameter_declarations,
        &.{.{ .name = "query", .raw_value = "o1 a2" }},
    );
    defer recall.deinit(std.testing.allocator);
    const recall_projection = plans.cached.find("recall").?;
    try std.testing.expectEqualStrings(
        "score",
        recall_projection.relevance.?.score_field.?,
    );
    try expectSortedOutput(
        recall_projection,
        &recall,
        10,
        exact_recall_output,
        2,
        2,
        2,
    );
}

fn expectJsonlOutput(
    projection: *const Projection,
    bindings: *const definition_core.parameters.Bindings,
    expected: []const u8,
    scanned: usize,
    emitted: usize,
) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try executeJsonl(
        std.testing.allocator,
        projection,
        exact_rows,
        bindings,
        100,
        100,
        &output.writer,
        &stats,
    );
    try std.testing.expectEqualStrings(expected, output.written());
    try std.testing.expectEqual(scanned, stats.records_scanned);
    try std.testing.expectEqual(emitted, stats.records_emitted);
}

fn expectSortedOutput(
    projection: *const Projection,
    bindings: *const definition_core.parameters.Bindings,
    limit: usize,
    expected: []const u8,
    scanned: usize,
    matched: usize,
    emitted: usize,
) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try executeSortedJsonl(
        std.testing.allocator,
        projection,
        exact_rows,
        bindings,
        limit,
        100,
        &output.writer,
        &stats,
    );
    try std.testing.expectEqualStrings(expected, output.written());
    try std.testing.expectEqual(scanned, stats.records_scanned);
    try std.testing.expectEqual(matched, stats.records_matched);
    try std.testing.expectEqual(emitted, stats.records_emitted);
}

fn verifyRequiredLookupFailure(plans: *ProjectionTestPlans) !void {
    var bindings = try definition_core.parameters.bind(
        std.testing.allocator,
        &plans.definition_plan.parameter_declarations,
        &.{.{ .name = "id", .raw_value = "missing" }},
    );
    defer bindings.deinit(std.testing.allocator);
    const required = plans.cached.find("required").?;
    try std.testing.expect(required.require_match);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var stats: Stats = .{
        .records_scanned = 0,
        .records_matched = 0,
        .records_emitted = 0,
    };
    try std.testing.expectError(
        error.ProjectionNotFound,
        executeJsonl(
            std.testing.allocator,
            required,
            exact_rows,
            &bindings,
            100,
            100,
            &output.writer,
            &stats,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), stats.records_scanned);
}
