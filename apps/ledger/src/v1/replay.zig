const std = @import("std");
const definition_core = @import("definition_core");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const definition_archive = @import("definition_archive.zig");
const materialization = @import("materialization.zig");
const protocol = @import("protocol.zig");
const revision_archive = @import("revision_archive.zig");
const storage = @import("storage.zig");
const validation = @import("validation.zig");

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

    fn deinit(self: *PlanCache) void {
        for (self.plans.items) |*plan| plan.deinit(self.allocator);
        self.plans.deinit(self.allocator);
        self.* = undefined;
    }

    fn get(self: *PlanCache, digest: []const u8) !*const ArchivedPlan {
        for (self.plans.items) |*plan| {
            if (std.mem.eql(u8, plan.digest, digest)) return plan;
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
        try self.plans.append(self.allocator, .{
            .digest = owned_digest,
            .archive = archive,
            .definition_plan = definition_plan,
            .validation_plan = validation_plan,
            .storage_plan = storage_plan,
            .protocol_plan = protocol_plan,
        });
        return &self.plans.items[self.plans.items.len - 1];
    }
};

pub const Stats = struct {
    records_validated: usize,
    definition_versions: usize,
    protocol_state: ?protocol.ReplayState,

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
    };
}

const HistoryResult = struct {
    records_validated: usize,
    protocol_state: ?protocol.ReplayState,
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
    var records: std.ArrayList([]const u8) = .empty;
    defer records.deinit(allocator);
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
    if (current_max_records) |limit| {
        if (records.items.len > limit) {
            return error.CurrentStoreRecordBoundsExceeded;
        }
    }
    var expected_start: usize = 0;
    var protocol_state: ?protocol.ReplayState = null;
    errdefer if (protocol_state) |*state| state.deinit(allocator);
    for (rows, 0..) |row, index| {
        const record_start = row.record_start orelse
            return error.StoreBindingRecordRangeMissing;
        const record_end = row.record_end orelse
            return error.StoreBindingRecordRangeMissing;
        if (record_start != expected_start or
            record_end > records.items.len)
        {
            return error.StoreBindingRecordCountMismatch;
        }
        try validateBoundExtent(
            allocator,
            row,
            content,
            content_revision,
        );
        const resolved = try resolveEffect(cache, current_slot, row);
        if (record_end > resolved.archived.definition_plan.bounds.max_records) {
            return error.HistoricalRecordBoundsExceeded;
        }
        switch (row.kind) {
            .existing_store_binding => {
                if (index != 0 or resolved.effect.kind != .bind_existing) {
                    return error.HistoricalEffectKindMismatch;
                }
                for (records.items[record_start..record_end]) |record| {
                    try validateEventInput(
                        allocator,
                        &protocol_state,
                        protocol_required,
                        resolved,
                        record,
                        parameters,
                        false,
                        observer,
                    );
                }
            },
            .admission => switch (resolved.effect.kind) {
                .compare_append => {
                    if (record_end != record_start + 1) {
                        return error.StoreBindingRecordCountMismatch;
                    }
                    try validateEventInput(
                        allocator,
                        &protocol_state,
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
                        record_end != records.items.len or
                        row.extent_start != 0 or
                        row.extent_end != content.len)
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
            },
        }
        expected_start = record_end;
    }
    if (expected_start != records.items.len) {
        return error.StoreBindingRecordCountMismatch;
    }
    if (protocol_required and protocol_state == null) {
        return error.HistoricalProtocolBindingMismatch;
    }
    return .{
        .records_validated = records.items.len,
        .protocol_state = protocol_state,
    };
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
    const historical_plan = if (resolved.archived.protocol_plan) |*plan|
        if (plan.target_slot_index == resolved.effect.slot_index)
            plan
        else
            null
    else
        null;
    if ((historical_plan != null) != protocol_required) {
        return error.HistoricalProtocolBindingMismatch;
    }
    if (resolved.effect.event) |*event_materialization| {
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
        const canonical_event = switch (event_materialization.mode) {
            .chained => try definition_core.canonical_json.canonicalJsonAlloc(
                allocator,
                parsed.value,
            ),
            .plain => try protocol.canonicalPlainStoredEventAlloc(
                allocator,
                event_materialization,
                parsed.value,
            ),
        };
        defer allocator.free(canonical_event);
        if (!std.mem.eql(u8, canonical_event, bytes)) {
            return error.HistoricalArtifactNotCanonical;
        }
        const reconstructed = switch (event_materialization.mode) {
            .chained => chained: {
                const plan = historical_plan orelse
                    return error.HistoricalProtocolBindingMismatch;
                if (plan.mode != .chained) {
                    return error.HistoricalProtocolBindingMismatch;
                }
                if (protocol_state.* == null) {
                    protocol_state.* = protocol.ReplayState.init(plan);
                }
                break :chained try protocol.reconstructInputAlloc(
                    allocator,
                    plan,
                    &protocol_state.*.?,
                    event_materialization,
                    parsed.value,
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
                break :plain try protocol.reconstructPlainInputAlloc(
                    allocator,
                    event_materialization,
                    parsed.value,
                );
            },
        };
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
        return;
    }
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
