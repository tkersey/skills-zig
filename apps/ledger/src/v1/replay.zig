const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const definition_archive = @import("definition_archive.zig");
const materialization = @import("materialization.zig");
const protocol = @import("protocol.zig");
const revision_archive = @import("revision_archive.zig");
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

fn streamReplaySupported(
    cache: *PlanCache,
    slot: storage.ResolvedSlot,
    rows: []const custody.BindingRow,
) bool {
    for (rows, 0..) |row, index| {
        const resolved = resolveEffect(cache, slot, row) catch return false;
        if (row.kind == .existing_store_binding) {
            if (index != 0 or resolved.effect.kind != .bind_existing) {
                return false;
            }
            continue;
        }
        switch (resolved.effect.kind) {
            .compare_append => {},
            .create_new => if (index != 0) return false,
            .compare_replace, .bind_existing => return false,
        }
    }
    return true;
}

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
    const Observer = @TypeOf(observer);
    const EventHash = std.crypto.hash.sha2.Sha256;
    const Validator = struct {
        allocator: std.mem.Allocator,
        cache: *PlanCache,
        slot: storage.ResolvedSlot,
        rows: []const custody.BindingRow,
        parameters: *const definition_core.parameters.Bindings,
        protocol_required: bool,
        max_records: usize,
        observer: Observer,
        row_index: usize = 0,
        protocol_state: ?protocol.ReplayState = null,
        row_hash: EventHash = EventHash.init(.{}),
        raw_bytes_observed: usize = 0,
        bound_prefix_hash: EventHash = EventHash.init(.{}),
        bound_prefix_verified: bool = false,

        fn observeRaw(
            context: *anyopaque,
            bytes: []const u8,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const observed_after = std.math.add(
                usize,
                self.raw_bytes_observed,
                bytes.len,
            ) catch return error.CurrentStoreBoundsExceeded;
            if (self.rows[0].kind == .existing_store_binding and
                !self.bound_prefix_verified)
            {
                const bound_end = self.rows[0].extent_end;
                if (self.rows[0].extent_start != 0 or
                    bound_end <= self.raw_bytes_observed)
                {
                    return error.StoreBindingExtentMismatch;
                }
                const remaining = bound_end - self.raw_bytes_observed;
                const hashed = @min(remaining, bytes.len);
                self.bound_prefix_hash.update(bytes[0..hashed]);
                if (hashed == remaining) {
                    var completed = self.bound_prefix_hash;
                    var digest: [EventHash.digest_length]u8 = undefined;
                    completed.final(&digest);
                    const hex = std.fmt.bytesToHex(digest, .lower);
                    var formatted: [71]u8 = undefined;
                    @memcpy(formatted[0..7], "sha256:");
                    @memcpy(formatted[7..], &hex);
                    if (!std.mem.eql(
                        u8,
                        &formatted,
                        self.rows[0].canonical_input_digest,
                    )) return error.HistoricalInputDigestMismatch;
                    self.bound_prefix_verified = true;
                }
            }
            self.raw_bytes_observed = observed_after;
        }

        fn visit(context: *anyopaque, record: durable_store.EventRecordView) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (record.ordinal == 0) return error.StoreBindingRecordCountMismatch;
            if (record.ordinal > self.max_records) {
                return error.CurrentStoreRecordBoundsExceeded;
            }
            const record_index: usize = @intCast(record.ordinal - 1);
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
            if (record_index == start) {
                self.row_hash = EventHash.init(.{});
                if (row.extent_start != record.extent_start) {
                    return error.StoreBindingExtentMismatch;
                }
            }
            const resolved = try resolveEffect(self.cache, self.slot, row);
            switch (resolved.effect.kind) {
                .compare_append => {
                    if (row.kind != .admission) {
                        return error.HistoricalEffectKindMismatch;
                    }
                    if (end != start + 1 or
                        row.extent_start != record.extent_start or
                        row.extent_end != record.extent_end)
                    {
                        return error.StoreBindingExtentMismatch;
                    }
                    self.row_hash.update(record.payload);
                },
                .create_new => {
                    if (row.kind != .admission or
                        self.row_index != 0 or start != 0 or
                        self.protocol_required)
                    {
                        return error.HistoricalEffectKindMismatch;
                    }
                    self.row_hash.update(record.payload);
                    self.row_hash.update("\n");
                },
                .bind_existing => {
                    if (row.kind != .existing_store_binding or
                        self.row_index != 0 or start != 0)
                    {
                        return error.HistoricalEffectKindMismatch;
                    }
                },
                .compare_replace => return error.HistoricalEffectKindMismatch,
            }
            try validateEventInput(
                self.allocator,
                &self.protocol_state,
                self.protocol_required,
                resolved,
                record.payload,
                self.parameters,
                row.kind == .admission,
                self.observer,
            );
            if (record_index + 1 == end) {
                if (resolved.effect.kind == .create_new and
                    row.extent_end != record.extent_end + 1)
                {
                    return error.StoreBindingExtentMismatch;
                }
                if (resolved.effect.kind == .bind_existing) {
                    self.row_index += 1;
                    return;
                }
                var digest: [EventHash.digest_length]u8 = undefined;
                self.row_hash.final(&digest);
                const hex = std.fmt.bytesToHex(digest, .lower);
                var formatted: [71]u8 = undefined;
                @memcpy(formatted[0..7], "sha256:");
                @memcpy(formatted[7..], &hex);
                if (!std.mem.eql(
                    u8,
                    &formatted,
                    row.canonical_input_digest,
                )) return error.HistoricalInputDigestMismatch;
                self.row_index += 1;
            }
        }
    };
    var validator = Validator{
        .allocator = allocator,
        .cache = cache,
        .slot = current_slot,
        .rows = rows,
        .parameters = parameters,
        .protocol_required = protocol_required,
        .max_records = current_max_records,
        .observer = observer,
    };
    errdefer if (validator.protocol_state) |*state| state.deinit(allocator);
    var backend = durable_store.PersistentEventStore.init(path);
    var summary = try backend.eventStore().scan(
        allocator,
        current_slot.max_bytes,
        .{
            .context = &validator,
            .visitFn = Validator.visit,
            .rawFn = Validator.observeRaw,
        },
    );
    defer summary.deinit(allocator);
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
    return .{
        .records_validated = summary.record_count,
        .protocol_state = validator.protocol_state,
        .append_context = summary.append_context,
    };
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
            if (resolved.effect.kind != .bind_existing) {
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
    if (record_end > resolved.archived.definition_plan.bounds.max_records) {
        return error.HistoricalRecordBoundsExceeded;
    }
    switch (row.kind) {
        .existing_store_binding => try validateExistingEvents(
            allocator,
            resolved,
            index,
            records[record_start..record_end],
            parameters,
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
            parameters,
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
    if (index != 0 or resolved.effect.kind != .bind_existing) {
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
        .bind_existing => return error.HistoricalEffectKindMismatch,
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
