const std = @import("std");
const definition_core = @import("definition_core");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const definition_archive = @import("definition_archive.zig");
const materialization = @import("materialization.zig");
const storage = @import("storage.zig");
const validation = @import("validation.zig");

const ArchivedPlan = struct {
    digest: []u8,
    archive: definition_archive.Loaded,
    definition_plan: definition.Plan,
    validation_plan: validation.Plan,
    storage_plan: storage.Plan,

    fn deinit(self: *ArchivedPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.digest);
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
        const owned_digest = try self.allocator.dupe(u8, digest);
        errdefer self.allocator.free(owned_digest);
        try self.plans.append(self.allocator, .{
            .digest = owned_digest,
            .archive = archive,
            .definition_plan = definition_plan,
            .validation_plan = validation_plan,
            .storage_plan = storage_plan,
        });
        return &self.plans.items[self.plans.items.len - 1];
    }
};

pub const Stats = struct {
    records_validated: usize,
    definition_versions: usize,
};

pub fn validateSlot(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    slot: storage.Slot,
    snapshot: *const custody.SlotSnapshot,
) !Stats {
    var cache = PlanCache{
        .allocator = allocator,
        .repo_root = repo_root,
        .definition_id = definition_id,
    };
    defer cache.deinit();
    const records_validated = switch (slot.kind) {
        .event_log => try validateEventLog(
            allocator,
            &cache,
            slot,
            snapshot,
        ),
        .document => try validateDocument(
            allocator,
            &cache,
            slot,
            snapshot,
        ),
    };
    return .{
        .records_validated = records_validated,
        .definition_versions = cache.plans.items.len,
    };
}

fn validateEventLog(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    current_slot: storage.Slot,
    snapshot: *const custody.SlotSnapshot,
) !usize {
    var lines = std.mem.splitScalar(u8, snapshot.content, '\n');
    var row_index: usize = 0;
    while (lines.next()) |line_with_cr| {
        const line = std.mem.trim(u8, line_with_cr, " \t\r");
        if (line.len == 0) continue;
        if (row_index >= snapshot.binding.rows.len) {
            return error.StoreBindingRecordCountMismatch;
        }
        try validateBoundInput(
            allocator,
            cache,
            current_slot,
            snapshot.binding.rows[row_index],
            line,
            .compare_append,
        );
        row_index += 1;
    }
    if (row_index != snapshot.binding.rows.len) {
        return error.StoreBindingRecordCountMismatch;
    }
    return row_index;
}

fn validateDocument(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    current_slot: storage.Slot,
    snapshot: *const custody.SlotSnapshot,
) !usize {
    if (snapshot.binding.rows.len != 1) {
        return error.HistoricalDocumentReplayUnsupported;
    }
    const row = snapshot.binding.rows[0];
    const archived = try cache.get(row.definition_digest);
    const operation = archived.storage_plan.findOperation(row.operation) orelse
        return error.HistoricalOperationMissing;
    const effect = findEffectForSlot(
        &archived.storage_plan,
        operation,
        current_slot,
    ) orelse return error.HistoricalEffectMissing;
    if (effect.kind != .create_new and effect.kind != .compare_replace) {
        return error.HistoricalEffectKindMismatch;
    }
    try validateBoundInput(
        allocator,
        cache,
        current_slot,
        row,
        snapshot.content,
        effect.kind,
    );
    return 1;
}

fn validateBoundInput(
    allocator: std.mem.Allocator,
    cache: *PlanCache,
    current_slot: storage.Slot,
    row: custody.BindingRow,
    bytes: []const u8,
    expected_kind: storage.EffectKind,
) !void {
    const archived = try cache.get(row.definition_digest);
    const operation = archived.storage_plan.findOperation(row.operation) orelse
        return error.HistoricalOperationMissing;
    const effect = findEffectForSlot(
        &archived.storage_plan,
        operation,
        current_slot,
    ) orelse return error.HistoricalEffectMissing;
    if (effect.kind != expected_kind) return error.HistoricalEffectKindMismatch;
    const input = archived.definition_plan.inputs[effect.input_index];
    var execution = try validation.execute(
        allocator,
        &archived.validation_plan,
        &.{.{ .name = input.name, .bytes = bytes }},
    );
    defer execution.deinit();
    if (!execution.isValid()) return error.HistoricalArtifactInvalid;
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
    const digest = try definition_core.canonical_json.digestBytesAlloc(
        allocator,
        canonical,
    );
    defer allocator.free(digest);
    if (!std.mem.eql(u8, digest, row.canonical_input_digest)) {
        return error.HistoricalInputDigestMismatch;
    }
}

fn findEffectForSlot(
    storage_plan: *const storage.Plan,
    operation: *const storage.Operation,
    current_slot: storage.Slot,
) ?storage.Effect {
    for (operation.effects) |effect| {
        const historical_slot = storage_plan.slots[effect.slot_index];
        if (std.mem.eql(
            u8,
            historical_slot.name,
            current_slot.name,
        ) and std.mem.eql(
            u8,
            historical_slot.relative_path,
            current_slot.relative_path,
        )) return effect;
    }
    return null;
}
