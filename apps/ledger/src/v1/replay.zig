const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const definition_archive = @import("definition_archive.zig");
const materialization = @import("materialization.zig");
const protocol = @import("protocol.zig");
const revision_archive = @import("revision_archive.zig");
const segmented_event_log = @import("segmented_event_log.zig");
const storage = @import("storage.zig");
const validation = @import("validation.zig");

pub const max_historical_definition_versions: usize = 128;
pub const max_historical_definition_bytes: usize = 16 * 1024 * 1024;

const ArchivedPlan = struct {
    digest: []u8,
    archive: definition_archive.Loaded,
    definition_plan: definition.Plan,
    validation_plan: validation.Plan,
    storage_plan: storage.Plan,
    protocol_plan: ?protocol.Plan,

    fn deinit(self: *ArchivedPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.digest);
        if (self.protocol_plan) |*plan| plan.deinit(allocator);
        self.storage_plan.deinit(allocator);
        self.validation_plan.deinit(allocator);
        self.definition_plan.deinit(allocator);
        self.archive.deinit(allocator);
        self.* = undefined;
    }
};

const PlanCache = struct {
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    plans: std.ArrayList(ArchivedPlan) = .empty,
    indices: std.StringHashMapUnmanaged(usize) = .empty,
    definition_bytes: usize = 0,

    fn deinit(self: *PlanCache) void {
        self.indices.deinit(self.allocator);
        for (self.plans.items) |*plan| plan.deinit(self.allocator);
        self.plans.deinit(self.allocator);
        self.* = undefined;
    }

    fn get(self: *PlanCache, digest: []const u8) !*const ArchivedPlan {
        if (self.indices.get(digest)) |index| {
            return &self.plans.items[index];
        }
        if (self.plans.items.len >= max_historical_definition_versions) {
            return error.HistoricalDefinitionVersionBoundExceeded;
        }
        var archive = try definition_archive.load(
            self.allocator,
            self.repo_root,
            digest,
        );
        errdefer archive.deinit(self.allocator);
        if (!std.mem.eql(u8, archive.definition_id, self.definition_id)) {
            return error.DefinitionArchiveOwnerMismatch;
        }
        const next_definition_bytes = std.math.add(
            usize,
            self.definition_bytes,
            archive.closure.total_definition_bytes,
        ) catch return error.HistoricalDefinitionBytesBoundExceeded;
        if (next_definition_bytes > max_historical_definition_bytes) {
            return error.HistoricalDefinitionBytesBoundExceeded;
        }
        var definition_plan = try definition.compile(
            self.allocator,
            &archive.closure,
            archive.entry_path,
        );
        errdefer definition_plan.deinit(self.allocator);
        var validation_plan = try validation.compile(
            self.allocator,
            &definition_plan,
        );
        errdefer validation_plan.deinit(self.allocator);
        var storage_plan = try storage.compile(
            self.allocator,
            &definition_plan,
        );
        errdefer storage_plan.deinit(self.allocator);
        var protocol_plan = try protocol.compile(
            self.allocator,
            &definition_plan,
            &storage_plan,
        );
        errdefer if (protocol_plan) |*plan| plan.deinit(self.allocator);
        const owned_digest = try self.allocator.dupe(u8, digest);
        errdefer self.allocator.free(owned_digest);
        const index = self.plans.items.len;
        try self.plans.append(self.allocator, .{
            .digest = owned_digest,
            .archive = archive,
            .definition_plan = definition_plan,
            .validation_plan = validation_plan,
            .storage_plan = storage_plan,
            .protocol_plan = protocol_plan,
        });
        errdefer {
            var removed = self.plans.pop().?;
            removed.deinit(self.allocator);
        }
        try self.indices.put(self.allocator, owned_digest, index);
        self.definition_bytes = next_definition_bytes;
        return &self.plans.items[index];
    }
};

pub const Stats = struct {
    records_validated: usize,
    definition_versions: usize,
    protocol_state: ?protocol.ReplayState,
    append_context: ?durable_store.EventAppendContext = null,

    pub fn deinit(self: *Stats, allocator: std.mem.Allocator) void {
        if (self.protocol_state) |*state| state.deinit(allocator);
        self.* = undefined;
    }

    pub fn takeProtocolState(self: *Stats) ?protocol.ReplayState {
        const result = self.protocol_state;
        self.protocol_state = null;
        return result;
    }
};

const IgnoreRecords = struct {
    pub fn observe(_: *@This(), _: std.json.Value) !void {}
};

fn notifyObserver(
    observer: anytype,
    value: std.json.Value,
    raw: []const u8,
    replay_state: ?*const protocol.ReplayState,
) !void {
    const Observer = @TypeOf(observer.*);
    if (@hasDecl(Observer, "observeReplay")) {
        try observer.observeReplay(value, raw, replay_state);
    } else {
        try observer.observe(value);
    }
}

pub fn validateSlot(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    slot: storage.ResolvedSlot,
    snapshot: *const custody.SlotSnapshot,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: usize,
    protocol_required: bool,
) !Stats {
    var observer: IgnoreRecords = .{};
    return validateSlotObserved(
        allocator,
        repo_root,
        definition_id,
        slot,
        snapshot,
        parameters,
        current_max_records,
        protocol_required,
        &observer,
    );
}

pub fn validateSlotObserved(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    slot: storage.ResolvedSlot,
    snapshot: *const custody.SlotSnapshot,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: usize,
    protocol_required: bool,
    observer: anytype,
) !Stats {
    if (current_max_records == 0 or current_max_records > 10_000_000) {
        return error.InvalidReplayRecordBound;
    }
    var cache = PlanCache{
        .allocator = allocator,
        .repo_root = repo_root,
        .definition_id = definition_id,
    };
    defer cache.deinit();
    const history = try validateHistory(
        allocator,
        &cache,
        slot,
        snapshot,
        parameters,
        current_max_records,
        protocol_required,
        observer,
    );
    return .{
        .records_validated = history.records_validated,
        .definition_versions = cache.plans.items.len,
        .protocol_state = history.protocol_state,
        .append_context = history.append_context,
    };
}

pub fn validateReplaySlot(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    slot: storage.ResolvedSlot,
    snapshot: *const custody.ReplaySlot,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: usize,
    protocol_required: bool,
) !Stats {
    var observer: IgnoreRecords = .{};
    return validateReplaySlotObserved(
        allocator,
        repo_root,
        definition_id,
        slot,
        snapshot,
        parameters,
        current_max_records,
        protocol_required,
        &observer,
    );
}

pub fn validateReplaySlotObserved(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    slot: storage.ResolvedSlot,
    snapshot: *const custody.ReplaySlot,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: usize,
    protocol_required: bool,
    observer: anytype,
) !Stats {
    if (slot.kind != .event_log) return error.StreamReplayRequiresEventLog;
    if (snapshot.read_custody == null) {
        return error.ReplayRequiresMaterializedHistory;
    }
    if (current_max_records == 0 or current_max_records > 10_000_000) {
        return error.InvalidReplayRecordBound;
    }
    if (!snapshot.exists or snapshot.binding.rows.len == 0) {
        return error.InvalidStoreBinding;
    }
    var cache = PlanCache{
        .allocator = allocator,
        .repo_root = repo_root,
        .definition_id = definition_id,
    };
    defer cache.deinit();
    for (snapshot.binding.rows) |row| _ = try cache.get(row.definition_digest);
    if (!streamReplaySupported(&cache, slot, snapshot.binding.rows)) {
        return error.ReplayRequiresMaterializedHistory;
    }
    const history = try validateStreamedEventEpoch(
        allocator,
        &cache,
        slot,
        snapshot.binding.rows,
        snapshot.path,
        snapshot.revision,
        parameters,
        current_max_records,
        protocol_required,
        observer,
    );
    return .{
        .records_validated = history.records_validated,
        .definition_versions = cache.plans.items.len,
        .protocol_state = history.protocol_state,
        .append_context = history.append_context,
    };
}

pub fn validateSegmentedSnapshot(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    slot: storage.ResolvedSlot,
    snapshot: *const segmented_event_log.Snapshot,
    binding: *const custody.BindingSnapshot,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: usize,
    protocol_required: bool,
) !Stats {
    var observer: IgnoreRecords = .{};
    return validateSegmentedSnapshotObserved(
        allocator,
        repo_root,
        definition_id,
        slot,
        snapshot,
        binding,
        parameters,
        current_max_records,
        protocol_required,
        &observer,
    );
}

pub fn validateSegmentedSnapshotObserved(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    slot: storage.ResolvedSlot,
    snapshot: *const segmented_event_log.Snapshot,
    binding: *const custody.BindingSnapshot,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: usize,
    protocol_required: bool,
    observer: anytype,
) !Stats {
    if (!slot.isSegmented() or slot.kind != .event_log) {
        return error.SegmentedReplayRequiresSegmentedEventLog;
    }
    if (!snapshot.head.checkpoint_exists) {
        return error.SegmentedReplayCheckpointMissing;
    }
    if (current_max_records == 0 or current_max_records > 10_000_000) {
        return error.InvalidReplayRecordBound;
    }
    var cache = PlanCache{
        .allocator = allocator,
        .repo_root = repo_root,
        .definition_id = definition_id,
    };
    defer cache.deinit();
    var decoded = try decodeReplayCheckpoint(
        allocator,
        &cache,
        snapshot.checkpoint_bytes,
    );
    defer decoded.deinit(allocator);
    if (decoded.state.records != snapshot.head.checkpoint_event_records) {
        return error.SegmentedCheckpointRecordMismatch;
    }
    for (binding.rows) |row| _ = try cache.get(row.definition_digest);
    try requireAppendOnlyRows(&cache, slot, binding.rows);
    const total_records = std.math.cast(
        usize,
        snapshot.head.total_event_records,
    ) orelse return error.CurrentStoreRecordBoundsExceeded;
    if (total_records > current_max_records) {
        return error.CurrentStoreRecordBoundsExceeded;
    }
    if (snapshot.event_bytes.len == 0) {
        if (binding.rows.len != 0) return error.InvalidStoreBinding;
        return segmentedCheckpointOnlyStats(&cache, &decoded);
    }
    return validateSegmentedActive(
        allocator,
        &cache,
        slot,
        snapshot,
        binding,
        parameters,
        current_max_records,
        protocol_required,
        observer,
        total_records,
        &decoded,
    );
}

fn validateSegmentedActive(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    slot: storage.ResolvedSlot,
    snapshot: *const segmented_event_log.Snapshot,
    binding: *const custody.BindingSnapshot,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: usize,
    protocol_required: bool,
    observer: anytype,
    total_records: usize,
    decoded: *protocol.DecodedCheckpoint,
) !Stats {
    var backend = try activeMemoryStore(
        allocator,
        slot.relative_path,
        snapshot.event_bytes,
    );
    defer backend.deinit();
    var validator = StreamEventValidator{
        .allocator = allocator,
        .cache = cache,
        .slot = slot,
        .rows = binding.rows,
        .parameters = parameters,
        .protocol_required = protocol_required,
        .max_records = current_max_records,
        .observer = eraseReplayObserver(observer),
        .record_offset = @intCast(snapshot.head.checkpoint_event_records),
        .extent_offset = @intCast(snapshot.head.checkpoint_event_bytes),
        .protocol_state = decoded.state,
        .raw_bytes_observed = @intCast(snapshot.head.checkpoint_event_bytes),
    };
    decoded.state = .{ .next_sequence = 0 };
    defer if (validator.historical_parameters) |*bindings| {
        bindings.deinit(allocator);
    };
    errdefer if (validator.protocol_state) |*state| state.deinit(allocator);
    var summary = try backend.eventStore().scan(
        allocator,
        segmented_event_log.event_segment_bytes,
        .{
            .context = &validator,
            .visitFn = StreamEventValidator.visit,
            .rawFn = StreamEventValidator.observeRaw,
        },
    );
    defer summary.deinit(allocator);
    try validateSegmentedSummary(&validator, binding.rows, &summary, snapshot);
    const protocol_state = validator.protocol_state;
    validator.protocol_state = null;
    return .{
        .records_validated = total_records,
        .definition_versions = cache.plans.items.len,
        .protocol_state = protocol_state,
        .append_context = null,
    };
}

fn decodeReplayCheckpoint(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    bytes: []const u8,
) !protocol.DecodedCheckpoint {
    var identity = try protocol.decodeCheckpoint(allocator, null, bytes);
    defer identity.deinit(allocator);
    const archived = try cache.get(identity.definition_digest);
    const plan = if (archived.protocol_plan) |*value|
        value
    else
        return error.HistoricalProtocolBindingMismatch;
    return protocol.decodeCheckpoint(allocator, plan, bytes);
}

fn requireAppendOnlyRows(
    cache: *PlanCache,
    slot: storage.ResolvedSlot,
    rows: []const custody.BindingRow,
) !void {
    for (rows) |row| {
        const resolved = try resolveEffect(cache, slot, row);
        if (row.kind != .admission or
            resolved.effect.kind != .compare_append)
        {
            return error.HistoricalEffectKindMismatch;
        }
    }
}

fn segmentedCheckpointOnlyStats(
    cache: *const PlanCache,
    decoded: *protocol.DecodedCheckpoint,
) Stats {
    const state = decoded.state;
    decoded.state = .{ .next_sequence = 0 };
    return .{
        .records_validated = state.records,
        .definition_versions = cache.plans.items.len,
        .protocol_state = state,
        .append_context = null,
    };
}

fn activeMemoryStore(
    allocator: std.mem.Allocator,
    logical_ref: []const u8,
    bytes: []const u8,
) !durable_store.MemoryEventStore {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') {
        return error.InvalidSegmentedActiveEventFile;
    }
    var result = durable_store.MemoryEventStore.init(allocator, logical_ref);
    errdefer result.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!std.mem.eql(u8, line, std.mem.trim(u8, line, " \t\r"))) {
            return error.InvalidSegmentedActiveEventFile;
        }
        const owned = try allocator.dupe(u8, line);
        result.records.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    result.exists = true;
    return result;
}

fn validateSegmentedSummary(
    validator: *const StreamEventValidator,
    rows: []const custody.BindingRow,
    summary: *const durable_store.EventScanSummary,
    snapshot: *const segmented_event_log.Snapshot,
) !void {
    if (!summary.exists or summary.record_count != snapshot.head.event_records) {
        return error.SegmentedActiveRecordMismatch;
    }
    if (validator.row_index != rows.len or rows.len == 0) {
        return error.StoreBindingRecordCountMismatch;
    }
    const expected_end = std.math.add(
        usize,
        validator.record_offset,
        summary.record_count,
    ) catch return error.StoreBindingRecordCountMismatch;
    if (rows[rows.len - 1].record_end != expected_end) {
        return error.StoreBindingRecordCountMismatch;
    }
}

fn streamReplaySupported(
    cache: *PlanCache,
    slot: storage.ResolvedSlot,
    rows: []const custody.BindingRow,
) bool {
    for (rows, 0..) |row, index| {
        const resolved = resolveEffect(cache, slot, row) catch return false;
        if (row.kind == .existing_store_binding) {
            if (index != 0 or !resolved.effect.kind.isBinding()) {
                return false;
            }
            continue;
        }
        switch (resolved.effect.kind) {
            .compare_append => {},
            .create_new => if (index != 0) return false,
            .compare_replace, .bind_existing, .rebind_existing => return false,
        }
    }
    return true;
}

const EventHash = std.crypto.hash.sha2.Sha256;

const ReplayObserver = struct {
    context: *anyopaque,
    observe_fn: *const fn (
        context: *anyopaque,
        value: std.json.Value,
        raw: []const u8,
        replay_state: ?*const protocol.ReplayState,
    ) anyerror!void,

    pub fn observeReplay(
        self: *ReplayObserver,
        value: std.json.Value,
        raw: []const u8,
        replay_state: ?*const protocol.ReplayState,
    ) !void {
        try self.observe_fn(self.context, value, raw, replay_state);
    }
};

fn eraseReplayObserver(observer: anytype) ReplayObserver {
    const Observer = @TypeOf(observer.*);
    const Adapter = struct {
        fn observe(
            context: *anyopaque,
            value: std.json.Value,
            raw: []const u8,
            replay_state: ?*const protocol.ReplayState,
        ) !void {
            const concrete: *Observer = @ptrCast(@alignCast(context));
            if (@hasDecl(Observer, "observeReplay")) {
                try concrete.observeReplay(value, raw, replay_state);
            } else {
                try concrete.observe(value);
            }
        }
    };
    return .{ .context = observer, .observe_fn = Adapter.observe };
}

const StreamEventValidator = struct {
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    slot: storage.ResolvedSlot,
    rows: []const custody.BindingRow,
    parameters: *const definition_core.parameters.Bindings,
    protocol_required: bool,
    max_records: usize,
    observer: ReplayObserver,
    row_index: usize = 0,
    record_offset: usize = 0,
    extent_offset: usize = 0,
    protocol_state: ?protocol.ReplayState = null,
    row_hash: EventHash = EventHash.init(.{}),
    raw_bytes_observed: usize = 0,
    bound_prefix_hash: EventHash = EventHash.init(.{}),
    bound_prefix_verified: bool = false,
    historical_parameters: ?definition_core.parameters.Bindings = null,
    historical_parameters_index: ?usize = null,
    resolved_effect: ?ResolvedEffect = null,
    row_parameters: ?*const definition_core.parameters.Bindings = null,

    fn parametersForRow(
        self: *StreamEventValidator,
        resolved: ResolvedEffect,
        row: custody.BindingRow,
    ) !*const definition_core.parameters.Bindings {
        const environment = row.parameter_environment orelse
            return self.parameters;
        if (self.historical_parameters_index != self.row_index) {
            if (self.historical_parameters) |*prior| {
                prior.deinit(self.allocator);
            }
            self.historical_parameters =
                try definition_core.parameters.fromCanonicalJson(
                    self.allocator,
                    &resolved.archived.definition_plan.parameter_declarations,
                    environment,
                );
            self.historical_parameters_index = self.row_index;
        }
        return &self.historical_parameters.?;
    }

    fn observeRaw(context: *anyopaque, bytes: []const u8) !void {
        const self: *StreamEventValidator = @ptrCast(@alignCast(context));
        const observed_after = std.math.add(
            usize,
            self.raw_bytes_observed,
            bytes.len,
        ) catch return error.CurrentStoreBoundsExceeded;
        if (self.rows[0].kind == .existing_store_binding and
            !self.bound_prefix_verified)
        {
            try self.observeBoundPrefix(bytes);
        }
        self.raw_bytes_observed = observed_after;
    }

    fn observeBoundPrefix(
        self: *StreamEventValidator,
        bytes: []const u8,
    ) !void {
        const row = self.rows[0];
        const bound_end = row.extent_end;
        if (row.extent_start != 0 or bound_end <= self.raw_bytes_observed) {
            return error.StoreBindingExtentMismatch;
        }
        const remaining = bound_end - self.raw_bytes_observed;
        const hashed = @min(remaining, bytes.len);
        self.bound_prefix_hash.update(bytes[0..hashed]);
        if (hashed != remaining) return;
        var completed = self.bound_prefix_hash;
        var digest: [EventHash.digest_length]u8 = undefined;
        completed.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        var formatted: [71]u8 = undefined;
        @memcpy(formatted[0..7], "sha256:");
        @memcpy(formatted[7..], &hex);
        if (!std.mem.eql(u8, &formatted, row.canonical_input_digest)) {
            return error.HistoricalInputDigestMismatch;
        }
        self.bound_prefix_verified = true;
    }

    fn visit(
        context: *anyopaque,
        record: durable_store.EventRecordView,
    ) !void {
        const self: *StreamEventValidator = @ptrCast(@alignCast(context));
        if (record.ordinal == 0) return error.StoreBindingRecordCountMismatch;
        const global_ordinal = std.math.add(
            u64,
            @intCast(self.record_offset),
            record.ordinal,
        ) catch return error.CurrentStoreRecordBoundsExceeded;
        if (global_ordinal > @as(u64, @intCast(self.max_records))) {
            return error.CurrentStoreRecordBoundsExceeded;
        }
        const record_index: usize = @intCast(global_ordinal - 1);
        const row = try self.rowForRecord(record_index);
        const start = row.record_start.?;
        const end = row.record_end.?;
        if (record_index == start) try self.beginRow(row, record);
        const resolved = self.resolved_effect orelse
            return error.StoreBindingRecordRangeMissing;
        try self.verifyEffectRecord(resolved, row, start, end, record);
        try validateEventInput(
            self.allocator,
            &self.protocol_state,
            self.protocol_required,
            resolved,
            record.payload,
            self.row_parameters orelse
                return error.StoreBindingRecordRangeMissing,
            row.kind == .admission,
            &self.observer,
        );
        if (record_index + 1 == end) {
            try self.finishRow(resolved, row, record);
        }
    }

    fn rowForRecord(
        self: *StreamEventValidator,
        record_index: usize,
    ) !custody.BindingRow {
        if (self.row_index >= self.rows.len) {
            return error.StoreBindingRecordCountMismatch;
        }
        const row = self.rows[self.row_index];
        const start = row.record_start orelse
            return error.StoreBindingRecordRangeMissing;
        const end = row.record_end orelse
            return error.StoreBindingRecordRangeMissing;
        if (record_index < start or record_index >= end) {
            return error.StoreBindingRecordCountMismatch;
        }
        return row;
    }

    fn beginRow(
        self: *StreamEventValidator,
        row: custody.BindingRow,
        record: durable_store.EventRecordView,
    ) !void {
        self.row_hash = EventHash.init(.{});
        const extent_start = std.math.add(
            usize,
            self.extent_offset,
            record.extent_start,
        ) catch return error.StoreBindingExtentMismatch;
        if (row.extent_start != extent_start) {
            return error.StoreBindingExtentMismatch;
        }
        self.resolved_effect = try resolveEffect(self.cache, self.slot, row);
        self.row_parameters = try self.parametersForRow(
            self.resolved_effect.?,
            row,
        );
    }

    fn verifyEffectRecord(
        self: *StreamEventValidator,
        resolved: ResolvedEffect,
        row: custody.BindingRow,
        start: usize,
        end: usize,
        record: durable_store.EventRecordView,
    ) !void {
        switch (resolved.effect.kind) {
            .compare_append => {
                if (row.kind != .admission) {
                    return error.HistoricalEffectKindMismatch;
                }
                const extent_start = std.math.add(
                    usize,
                    self.extent_offset,
                    record.extent_start,
                ) catch return error.StoreBindingExtentMismatch;
                const extent_end = std.math.add(
                    usize,
                    self.extent_offset,
                    record.extent_end,
                ) catch return error.StoreBindingExtentMismatch;
                if (end != start + 1 or
                    row.extent_start != extent_start or
                    row.extent_end != extent_end)
                {
                    return error.StoreBindingExtentMismatch;
                }
                self.row_hash.update(record.payload);
            },
            .create_new => {
                if (row.kind != .admission or self.row_index != 0 or
                    start != 0 or self.protocol_required)
                {
                    return error.HistoricalEffectKindMismatch;
                }
                self.row_hash.update(record.payload);
                self.row_hash.update("\n");
            },
            .bind_existing, .rebind_existing => if (row.kind != .existing_store_binding or
                self.row_index != 0 or start != 0)
            {
                return error.HistoricalEffectKindMismatch;
            },
            .compare_replace => return error.HistoricalEffectKindMismatch,
        }
    }

    fn finishRow(
        self: *StreamEventValidator,
        resolved: ResolvedEffect,
        row: custody.BindingRow,
        record: durable_store.EventRecordView,
    ) !void {
        if (resolved.effect.kind == .create_new) {
            const extent_end = std.math.add(
                usize,
                self.extent_offset,
                record.extent_end,
            ) catch return error.StoreBindingExtentMismatch;
            if (extent_end == std.math.maxInt(usize) or
                row.extent_end != extent_end + 1)
            {
                return error.StoreBindingExtentMismatch;
            }
        }
        if (resolved.effect.kind.isBinding()) {
            self.advanceRow();
            return;
        }
        var digest: [EventHash.digest_length]u8 = undefined;
        self.row_hash.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        var formatted: [71]u8 = undefined;
        @memcpy(formatted[0..7], "sha256:");
        @memcpy(formatted[7..], &hex);
        if (!std.mem.eql(u8, &formatted, row.canonical_input_digest)) {
            return error.HistoricalInputDigestMismatch;
        }
        self.advanceRow();
    }

    fn advanceRow(self: *StreamEventValidator) void {
        self.resolved_effect = null;
        self.row_parameters = null;
        self.row_index += 1;
    }
};

fn validateStreamedEventEpoch(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    current_slot: storage.ResolvedSlot,
    rows: []const custody.BindingRow,
    path: []const u8,
    content_revision: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: usize,
    protocol_required: bool,
    observer: anytype,
) !HistoryResult {
    const binding_covered_by_store_revision =
        rows.len == 1 and
        rows[0].kind == .existing_store_binding and
        rows[0].extent_start == 0 and
        std.mem.eql(
            u8,
            rows[0].canonical_input_digest,
            content_revision,
        );
    var validator = StreamEventValidator{
        .allocator = allocator,
        .cache = cache,
        .slot = current_slot,
        .rows = rows,
        .parameters = parameters,
        .protocol_required = protocol_required,
        .max_records = current_max_records,
        .observer = eraseReplayObserver(observer),
        .bound_prefix_verified = binding_covered_by_store_revision,
    };
    defer if (validator.historical_parameters) |*bindings| {
        bindings.deinit(allocator);
    };
    errdefer if (validator.protocol_state) |*state| state.deinit(allocator);
    var backend = durable_store.PersistentEventStore.init(path);
    var summary = try backend.eventStore().scan(
        allocator,
        current_slot.max_bytes,
        .{
            .context = &validator,
            .visitFn = StreamEventValidator.visit,
            .rawFn = StreamEventValidator.observeRaw,
        },
    );
    defer summary.deinit(allocator);
    try validateStreamSummary(
        &validator,
        rows,
        &summary,
        content_revision,
        current_max_records,
        protocol_required,
    );
    return .{
        .records_validated = summary.record_count,
        .protocol_state = validator.protocol_state,
        .append_context = summary.append_context,
    };
}

fn validateStreamSummary(
    validator: *const StreamEventValidator,
    rows: []const custody.BindingRow,
    summary: *const durable_store.EventScanSummary,
    content_revision: []const u8,
    current_max_records: usize,
    protocol_required: bool,
) !void {
    if (!summary.exists or summary.record_count == 0) {
        return error.HistoricalArtifactInvalid;
    }
    if (summary.record_count > current_max_records) {
        return error.CurrentStoreRecordBoundsExceeded;
    }
    if (validator.row_index != rows.len or
        rows[rows.len - 1].record_end.? != summary.record_count)
    {
        return error.StoreBindingRecordCountMismatch;
    }
    if (!std.mem.eql(u8, summary.revision, content_revision)) {
        return error.HistoricalRevisionMismatch;
    }
    if (rows[0].kind == .existing_store_binding and
        !validator.bound_prefix_verified)
    {
        return error.HistoricalInputDigestMismatch;
    }
    if (protocol_required and validator.protocol_state == null) {
        return error.HistoricalProtocolBindingMismatch;
    }
}

const HistoryResult = struct {
    records_validated: usize,
    protocol_state: ?protocol.ReplayState,
    append_context: ?durable_store.EventAppendContext = null,
};

fn validateHistory(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    current_slot: storage.ResolvedSlot,
    snapshot: *const custody.SlotSnapshot,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: usize,
    protocol_required: bool,
    observer: anytype,
) !HistoryResult {
    if (snapshot.binding.rows.len == 0) return error.InvalidStoreBinding;
    var epoch_start: usize = 0;
    for (snapshot.binding.rows, 0..) |row, index| {
        const resolved = try resolveEffect(cache, current_slot, row);
        if (row.kind == .admission and
            resolved.effect.kind == .compare_replace)
        {
            if (protocol_required) {
                return error.ProtocolHistoryMustBeAppendOnly;
            }
            if (index == epoch_start) {
                return error.HistoricalReplaceWithoutState;
            }
            const prior_revision = row.revision_before orelse
                return error.HistoricalReplaceWithoutState;
            const prior_content = try revision_archive.load(
                allocator,
                cache.repo_root,
                prior_revision,
                resolved.slot.max_bytes,
            );
            defer allocator.free(prior_content);
            var ignored: IgnoreRecords = .{};
            _ = try validateEpoch(
                allocator,
                cache,
                current_slot,
                snapshot.binding.rows[epoch_start..index],
                prior_content,
                prior_revision,
                parameters,
                null,
                false,
                &ignored,
            );
            epoch_start = index;
        }
    }
    return validateEpoch(
        allocator,
        cache,
        current_slot,
        snapshot.binding.rows[epoch_start..],
        snapshot.content,
        snapshot.revision,
        parameters,
        current_max_records,
        protocol_required,
        observer,
    );
}

const ResolvedEffect = struct {
    archived: *const ArchivedPlan,
    effect: storage.Effect,
    slot: storage.Slot,
};

fn resolveEffect(
    cache: *PlanCache,
    current_slot: storage.ResolvedSlot,
    row: custody.BindingRow,
) !ResolvedEffect {
    const archived = try cache.get(row.definition_digest);
    const operation = archived.storage_plan.findOperation(
        row.operation,
    ) orelse return error.HistoricalOperationMissing;
    const effect = findEffectForSlot(
        &archived.storage_plan,
        operation,
        current_slot,
    ) orelse return error.HistoricalEffectMissing;
    const historical_slot = archived.storage_plan.slots[effect.slot_index];
    if (historical_slot.kind != current_slot.kind or
        historical_slot.codec != current_slot.codec)
    {
        return error.HistoricalSlotShapeMismatch;
    }
    return .{
        .archived = archived,
        .effect = effect,
        .slot = historical_slot,
    };
}

fn validateEpoch(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    current_slot: storage.ResolvedSlot,
    rows: []const custody.BindingRow,
    content: []const u8,
    content_revision: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: ?usize,
    protocol_required: bool,
    observer: anytype,
) !HistoryResult {
    if (rows.len == 0) return error.InvalidStoreBinding;
    if (!std.mem.eql(
        u8,
        content_revision,
        rows[rows.len - 1].revision_after,
    )) {
        return error.HistoricalRevisionMismatch;
    }
    return switch (current_slot.kind) {
        .document => if (protocol_required)
            error.ProtocolRequiresEventLogStorage
        else
            .{
                .records_validated = try validateDocumentEpoch(
                    allocator,
                    cache,
                    current_slot,
                    rows,
                    content,
                    content_revision,
                ),
                .protocol_state = null,
            },
        .event_log => validateEventEpoch(
            allocator,
            cache,
            current_slot,
            rows,
            content,
            content_revision,
            parameters,
            current_max_records,
            protocol_required,
            observer,
        ),
    };
}

fn validateDocumentEpoch(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    current_slot: storage.ResolvedSlot,
    rows: []const custody.BindingRow,
    content: []const u8,
    content_revision: []const u8,
) !usize {
    if (rows.len != 1) return error.HistoricalDocumentReplayInvalid;
    const row = rows[0];
    try validateBoundExtent(
        allocator,
        row,
        content,
        content_revision,
    );
    if (row.record_start != null or row.record_end != null or
        row.extent_start != 0 or row.extent_end != content.len)
    {
        return error.StoreBindingExtentMismatch;
    }
    const resolved = try resolveEffect(cache, current_slot, row);
    switch (row.kind) {
        .existing_store_binding => {
            if (!resolved.effect.kind.isBinding()) {
                return error.HistoricalEffectKindMismatch;
            }
        },
        .admission => if (resolved.effect.kind != .create_new and
            resolved.effect.kind != .compare_replace)
        {
            return error.HistoricalEffectKindMismatch;
        },
    }
    try validateInput(
        allocator,
        resolved.archived,
        resolved.effect,
        content,
        row.kind == .admission,
    );
    return 1;
}

fn validateEventEpoch(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    current_slot: storage.ResolvedSlot,
    rows: []const custody.BindingRow,
    content: []const u8,
    content_revision: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    current_max_records: ?usize,
    protocol_required: bool,
    observer: anytype,
) !HistoryResult {
    const records = try eventRecordsAlloc(allocator, content);
    defer allocator.free(records);
    if (current_max_records) |limit| {
        if (records.len > limit) {
            return error.CurrentStoreRecordBoundsExceeded;
        }
    }
    var expected_start: usize = 0;
    var protocol_state: ?protocol.ReplayState = null;
    errdefer if (protocol_state) |*state| state.deinit(allocator);
    for (rows, 0..) |row, index| {
        expected_start = try validateEventRow(
            allocator,
            cache,
            current_slot,
            row,
            index,
            expected_start,
            records,
            content,
            content_revision,
            parameters,
            protocol_required,
            &protocol_state,
            observer,
        );
    }
    if (expected_start != records.len) {
        return error.StoreBindingRecordCountMismatch;
    }
    if (protocol_required and protocol_state == null) {
        return error.HistoricalProtocolBindingMismatch;
    }
    return .{
        .records_validated = records.len,
        .protocol_state = protocol_state,
    };
}

fn eventRecordsAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
) ![][]const u8 {
    var records: std.ArrayList([]const u8) = .empty;
    errdefer records.deinit(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (line.len == 0) continue;
        if (records.items.len == 10_000_000) {
            return error.HistoricalRecordBoundsExceeded;
        }
        try records.append(allocator, line);
    }
    if (records.items.len == 0) return error.HistoricalArtifactInvalid;
    return records.toOwnedSlice(allocator);
}

fn validateEventRow(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    current_slot: storage.ResolvedSlot,
    row: custody.BindingRow,
    index: usize,
    expected_start: usize,
    records: []const []const u8,
    content: []const u8,
    content_revision: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    protocol_required: bool,
    protocol_state: *?protocol.ReplayState,
    observer: anytype,
) !usize {
    const record_start = row.record_start orelse
        return error.StoreBindingRecordRangeMissing;
    const record_end = row.record_end orelse
        return error.StoreBindingRecordRangeMissing;
    if (record_start != expected_start or record_end > records.len) {
        return error.StoreBindingRecordCountMismatch;
    }
    try validateBoundExtent(allocator, row, content, content_revision);
    const resolved = try resolveEffect(cache, current_slot, row);
    var historical_parameters = if (row.parameter_environment) |environment|
        try definition_core.parameters.fromCanonicalJson(
            allocator,
            &resolved.archived.definition_plan.parameter_declarations,
            environment,
        )
    else
        null;
    defer if (historical_parameters) |*bindings| bindings.deinit(allocator);
    const row_parameters = if (historical_parameters) |*bindings|
        bindings
    else
        parameters;
    if (record_end > resolved.archived.definition_plan.bounds.max_records) {
        return error.HistoricalRecordBoundsExceeded;
    }
    switch (row.kind) {
        .existing_store_binding => try validateExistingEvents(
            allocator,
            resolved,
            index,
            records[record_start..record_end],
            row_parameters,
            protocol_required,
            protocol_state,
            observer,
        ),
        .admission => try validateAdmittedEvents(
            allocator,
            resolved,
            row,
            index,
            record_start,
            record_end,
            records.len,
            content,
            row_parameters,
            protocol_required,
            protocol_state,
            observer,
        ),
    }
    return record_end;
}

fn validateExistingEvents(
    allocator: std.mem.Allocator,
    resolved: ResolvedEffect,
    index: usize,
    records: []const []const u8,
    parameters: *const definition_core.parameters.Bindings,
    protocol_required: bool,
    protocol_state: *?protocol.ReplayState,
    observer: anytype,
) !void {
    if (index != 0 or !resolved.effect.kind.isBinding()) {
        return error.HistoricalEffectKindMismatch;
    }
    for (records) |record| {
        try validateEventInput(
            allocator,
            protocol_state,
            protocol_required,
            resolved,
            record,
            parameters,
            false,
            observer,
        );
    }
}

fn validateAdmittedEvents(
    allocator: std.mem.Allocator,
    resolved: ResolvedEffect,
    row: custody.BindingRow,
    index: usize,
    record_start: usize,
    record_end: usize,
    record_count: usize,
    content: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    protocol_required: bool,
    protocol_state: *?protocol.ReplayState,
    observer: anytype,
) !void {
    switch (resolved.effect.kind) {
        .compare_append => {
            if (record_end != record_start + 1) {
                return error.StoreBindingRecordCountMismatch;
            }
            try validateEventInput(
                allocator,
                protocol_state,
                protocol_required,
                resolved,
                content[row.extent_start..row.extent_end],
                parameters,
                true,
                observer,
            );
        },
        .create_new, .compare_replace => {
            if (index != 0 or record_start != 0 or
                record_end != record_count or
                row.extent_start != 0 or row.extent_end != content.len)
            {
                return error.StoreBindingExtentMismatch;
            }
            try validateInput(
                allocator,
                resolved.archived,
                resolved.effect,
                content,
                true,
            );
            if (protocol_required) {
                return error.ProtocolHistoryMustBeAppendOnly;
            }
        },
        .bind_existing, .rebind_existing => return error.HistoricalEffectKindMismatch,
    }
}

fn validateBoundExtent(
    allocator: std.mem.Allocator,
    row: custody.BindingRow,
    content: []const u8,
    content_revision: []const u8,
) !void {
    if (row.extent_start > row.extent_end or
        row.extent_end > content.len)
    {
        return error.StoreBindingExtentMismatch;
    }
    if (row.extent_start == 0 and row.extent_end == content.len) {
        // Custody and the revision archive already verified this digest
        // against the complete content.
        if (!std.mem.eql(
            u8,
            content_revision,
            row.canonical_input_digest,
        )) {
            return error.HistoricalInputDigestMismatch;
        }
        return;
    }
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        content[row.extent_start..row.extent_end],
    );
    defer allocator.free(digest);
    if (!std.mem.eql(u8, digest, row.canonical_input_digest)) {
        return error.HistoricalInputDigestMismatch;
    }
}

fn validateInput(
    allocator: std.mem.Allocator,
    archived: *const ArchivedPlan,
    effect: storage.Effect,
    bytes: []const u8,
    require_canonical: bool,
) !void {
    const input = archived.definition_plan.inputs[effect.input_index];
    var execution = try validation.execute(
        allocator,
        &archived.validation_plan,
        &.{.{ .name = input.name, .bytes = bytes }},
    );
    defer execution.deinit();
    if (!execution.isValid()) return error.HistoricalArtifactInvalid;
    if (!require_canonical) return;
    const canonical = try materialization.canonicalizeInputAlloc(
        allocator,
        &execution,
        effect.input_index,
        input.codec,
    );
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) {
        return error.HistoricalArtifactNotCanonical;
    }
}

fn validateEventInput(
    allocator: std.mem.Allocator,
    protocol_state: *?protocol.ReplayState,
    protocol_required: bool,
    resolved: ResolvedEffect,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    require_canonical: bool,
    observer: anytype,
) !void {
    const input =
        resolved.archived.definition_plan.inputs[resolved.effect.input_index];
    const historical_plan = historicalProtocolPlan(resolved);
    if ((historical_plan != null) != protocol_required) {
        return error.HistoricalProtocolBindingMismatch;
    }
    if (resolved.effect.event) |*event_materialization| {
        return validateMaterializedEvent(
            allocator,
            protocol_state,
            historical_plan,
            resolved,
            input,
            event_materialization,
            bytes,
            parameters,
            require_canonical,
            observer,
        );
    }
    try validateRawEvent(
        allocator,
        protocol_state,
        historical_plan,
        resolved,
        input,
        bytes,
        parameters,
        require_canonical,
        observer,
    );
}

fn historicalProtocolPlan(
    resolved: ResolvedEffect,
) ?*const protocol.Plan {
    const plan = if (resolved.archived.protocol_plan) |*value| value else return null;
    if (plan.target_slot_index != resolved.effect.slot_index) return null;
    return plan;
}

fn validateMaterializedEvent(
    allocator: std.mem.Allocator,
    protocol_state: *?protocol.ReplayState,
    historical_plan: ?*const protocol.Plan,
    resolved: ResolvedEffect,
    input: definition.Input,
    materialization_plan: *const storage.EventMaterialization,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    require_canonical: bool,
    observer: anytype,
) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed.deinit();
    const canonical_event = try canonicalStoredEventAlloc(
        allocator,
        materialization_plan,
        parsed.value,
    );
    defer allocator.free(canonical_event);
    if (require_canonical and !std.mem.eql(u8, canonical_event, bytes)) {
        return error.HistoricalArtifactNotCanonical;
    }
    const reconstructed = try reconstructStoredEventAlloc(
        allocator,
        protocol_state,
        historical_plan,
        materialization_plan,
        parsed.value,
    );
    defer allocator.free(reconstructed);
    var execution = try validation.execute(
        allocator,
        &resolved.archived.validation_plan,
        &.{.{ .name = input.name, .bytes = reconstructed }},
    );
    defer execution.deinit();
    if (!execution.isValid()) return error.HistoricalArtifactInvalid;
    if (historical_plan) |plan| {
        try protocol.applyValueBound(
            allocator,
            plan,
            &protocol_state.*.?,
            parsed.value,
            parameters,
        );
    }
    try notifyObserver(
        observer,
        parsed.value,
        bytes,
        if (protocol_state.*) |*state| state else null,
    );
}

fn canonicalStoredEventAlloc(
    allocator: std.mem.Allocator,
    materialization_plan: *const storage.EventMaterialization,
    value: std.json.Value,
) ![]u8 {
    return switch (materialization_plan.mode) {
        .chained => definition_core.canonical_json.canonicalJsonAlloc(
            allocator,
            value,
        ),
        .plain => protocol.canonicalPlainStoredEventAlloc(
            allocator,
            materialization_plan,
            value,
        ),
    };
}

fn reconstructStoredEventAlloc(
    allocator: std.mem.Allocator,
    protocol_state: *?protocol.ReplayState,
    historical_plan: ?*const protocol.Plan,
    materialization_plan: *const storage.EventMaterialization,
    value: std.json.Value,
) ![]u8 {
    return switch (materialization_plan.mode) {
        .chained => chained: {
            const plan = historical_plan orelse
                return error.HistoricalProtocolBindingMismatch;
            if (plan.mode != .chained) {
                return error.HistoricalProtocolBindingMismatch;
            }
            if (protocol_state.* == null) {
                protocol_state.* = protocol.ReplayState.init(plan);
            }
            break :chained protocol.reconstructInputAlloc(
                allocator,
                plan,
                &protocol_state.*.?,
                materialization_plan,
                value,
            );
        },
        .plain => plain: {
            if (historical_plan) |plan| {
                if (plan.mode != .plain) {
                    return error.HistoricalProtocolBindingMismatch;
                }
                if (protocol_state.* == null) {
                    protocol_state.* = protocol.ReplayState.init(plan);
                }
            }
            break :plain protocol.reconstructPlainInputAlloc(
                allocator,
                if (protocol_state.*) |*state| state else null,
                materialization_plan,
                value,
            );
        },
    };
}

fn validateRawEvent(
    allocator: std.mem.Allocator,
    protocol_state: *?protocol.ReplayState,
    historical_plan: ?*const protocol.Plan,
    resolved: ResolvedEffect,
    input: definition.Input,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    require_canonical: bool,
    observer: anytype,
) !void {
    var execution = try validation.execute(
        allocator,
        &resolved.archived.validation_plan,
        &.{.{ .name = input.name, .bytes = bytes }},
    );
    defer execution.deinit();
    if (!execution.isValid()) return error.HistoricalArtifactInvalid;
    if (require_canonical) {
        const canonical = try materialization.canonicalizeInputAlloc(
            allocator,
            &execution,
            resolved.effect.input_index,
            input.codec,
        );
        defer allocator.free(canonical);
        if (!std.mem.eql(u8, canonical, bytes)) {
            return error.HistoricalArtifactNotCanonical;
        }
    }
    if (historical_plan) |plan| {
        const event = execution.inputJson(resolved.effect.input_index) orelse
            return error.HistoricalProtocolInputMustBeJson;
        if (protocol_state.* == null) {
            protocol_state.* = protocol.ReplayState.init(plan);
        }
        try protocol.applyValueBound(
            allocator,
            plan,
            &protocol_state.*.?,
            event,
            parameters,
        );
        try notifyObserver(
            observer,
            event,
            bytes,
            if (protocol_state.*) |*state| state else null,
        );
    } else if (execution.inputJson(resolved.effect.input_index)) |event| {
        try notifyObserver(observer, event, bytes, null);
    }
}

fn findEffectForSlot(
    storage_plan: *const storage.Plan,
    operation: *const storage.Operation,
    current_slot: storage.ResolvedSlot,
) ?storage.Effect {
    for (operation.effects) |effect| {
        const historical_slot = storage_plan.slots[effect.slot_index];
        if (std.mem.eql(
            u8,
            historical_slot.name,
            current_slot.name,
        ) and storage.pathTemplateMatches(
            historical_slot,
            current_slot.relative_path,
        )) return effect;
    }
    return null;
}
