const std = @import("std");
const engine = @import("ledger_v1_core");
const definition_core = @import("definition_core");
const storage_root = @import("storage_root");
const durable_store = @import("durable_store");
const cli = @import("cli.zig");
const legacy = @import("host_legacy.zig");
const History = engine.preparation.History;
const limits: engine.preparation.HistoryBounds = .{
    .max_bytes = 2 * 1024 * 1024 * 1024,
    .max_files = 100000,
};

pub const Owner = struct {
    plan: *const engine.compiled_plan.PlanSet,
    parameters: *const definition_core.parameters.Bindings,
    definition: []const u8,
};

// Original custody remains the selection evidence even when native maintenance
// will replace a stale binding. The expected repair is only an in-memory native
// result, never a replacement source, archive, receipt, or transaction authority.
const Observation = struct {
    original: History = .{},
    binding_after: ?[]u8 = null,
    definition_after: ?engine.preparation.File = null,

    fn deinit(self: *Observation, allocator: std.mem.Allocator) void {
        self.original.deinit(allocator);
        if (self.binding_after) |bytes| allocator.free(bytes);
        if (self.definition_after) |file| {
            allocator.free(file.path);
            allocator.free(file.bytes);
            allocator.free(file.digest);
        }
        self.* = undefined;
    }

    fn image(self: *const Observation, files: *[3]engine.preparation.File) History {
        const binding = self.binding_after orelse return self.original;
        files.* = .{
            self.original.files.items[0],
            .{ .path = self.original.files.items[1].path, .bytes = binding, .digest = "" },
            self.definition_after.?,
        };
        return .{
            .exists = true,
            .files = .fromOwnedSlice(files),
            .binding_rows = 1,
        };
    }
};

pub fn maintenanceName(failure: []const u8) ![]const u8 {
    if (std.mem.eql(u8, failure, "InvalidStoreBinding") or
        std.mem.eql(u8, failure, "StoreSlotWithoutBinding")) return "bind-existing";
    if (std.mem.eql(u8, failure, "StoreBindingRecordCountMismatch") or
        std.mem.eql(u8, failure, "StoreBindingRevisionMismatch")) return "rebind-existing";
    return error.UnknownBindingFailure;
}

pub fn checkMaintenanceOperation(
    plan: *const engine.compiled_plan.PlanSet,
    owner: Owner,
    operation: []const u8,
) !void {
    if (!std.mem.eql(
        u8,
        &plan.definition_plan.closure_digest,
        &owner.plan.definition_plan.closure_digest,
    )) {
        return error.OwnerDefinitionChanged;
    }
    const store = &(plan.storage_plan orelse return error.UnsupportedBindingMaintenance);
    const declared = store.findOperation(operation) orelse
        return error.UnsupportedBindingMaintenance;
    const expected: engine.storage.EffectKind = if (std.mem.eql(u8, operation, "bind-existing"))
        .bind_existing
    else
        .rebind_existing;
    if (store.slots.len != 1 or declared.effects.len != 1 or
        declared.effects[0].kind != expected or declared.effects[0].slot_index != 0 or
        !std.mem.eql(
            u8,
            store.slots[0].relative_path,
            owner.plan.storage_plan.?.slots[0].relative_path,
        ))
    {
        return error.UnsupportedBindingMaintenance;
    }
}

fn resolved(slot: engine.storage.Slot) engine.storage.ResolvedSlot {
    return .{
        .name = slot.name,
        .relative_path = slot.relative_path,
        .owned_path = null,
        .kind = slot.kind,
        .codec = slot.codec,
        .max_bytes = @min(slot.max_bytes, limits.max_bytes),
        .layout = slot.layout,
    };
}

fn capture(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    scope: *storage_root.Scope,
    root: []const u8,
    owner: Owner,
    slot: engine.storage.Slot,
    retain_image: bool,
) !Observation {
    const history = engine.preparation.captureHistoryBounded(
        scope,
        allocator,
        root,
        &owner.plan.definition_plan,
        resolved(slot),
        owner.parameters,
        owner.plan.protocol_plan != null,
        limits,
        false,
    ) catch |err| {
        const operation = maintenanceName(@errorName(err)) catch return err;
        if (owner.plan.storage_plan.?.slots.len != 1) return error.OwnerCustodyRequiresMaintenance;
        return captureRepair(
            allocator,
            io,
            environment,
            scope,
            root,
            owner,
            slot,
            operation,
            retain_image,
        );
    };
    return .{ .original = history };
}

fn append(
    allocator: std.mem.Allocator,
    history: *History,
    path: []const u8,
    bytes: []const u8,
) !void {
    if (history.files.items.len == limits.max_files) return error.MigrationInventoryBoundExceeded;
    if (bytes.len > limits.max_bytes - history.bytes) return error.MigrationInventoryBoundExceeded;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const content = try allocator.dupe(u8, bytes);
    errdefer allocator.free(content);
    const digest = try definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
    errdefer allocator.free(digest);
    try history.files.append(allocator, .{
        .path = owned_path,
        .bytes = content,
        .digest = digest,
    });
    history.bytes += bytes.len;
}

fn relativeControl(
    allocator: std.mem.Allocator,
    scope: *storage_root.Scope,
    root: []const u8,
    path: []const u8,
) ![]u8 {
    const control = try std.fs.path.join(
        allocator,
        &.{ root, storage_root.controlComponent(scope) },
    );
    defer allocator.free(control);
    const relative = try std.fs.path.relativeAlloc(allocator, "/", null, control, path);
    errdefer allocator.free(relative);
    try legacy.relative(relative);
    return relative;
}

fn captureRepair(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    scope: *storage_root.Scope,
    root: []const u8,
    owner: Owner,
    slot: engine.storage.Slot,
    operation: []const u8,
    retain_image: bool,
) !Observation {
    var input_scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
    var plan = try cli.loadDefinitionWithCache(
        &input_scope,
        allocator,
        environment,
        owner.definition,
        .{ .kind = .transact, .name = operation },
        false,
    );
    defer plan.deinit(allocator);
    try checkMaintenanceOperation(&plan, owner, operation);
    const after = try engine.transaction.previewExistingBinding(
        scope,
        allocator,
        &plan.definition_plan,
        &(plan.validation_plan orelse return error.UnsupportedBindingMaintenance),
        &plan.storage_plan.?,
        if (plan.protocol_plan) |*protocol| protocol else null,
        operation,
        root,
        owner.parameters,
    );
    defer allocator.free(after);
    var archive = try engine.definition_archive.prepare(
        scope,
        allocator,
        root,
        plan.definition_plan.id,
        plan.entry_path,
        &plan.closure,
    );
    defer archive.deinit(allocator);
    var result: Observation = .{
        .original = try captureBefore(allocator, scope, root, owner, slot),
    };
    errdefer result.deinit(allocator);
    if (retain_image) {
        result.binding_after = try allocator.dupe(u8, after);
        const relative_definition = try relativeControl(allocator, scope, root, archive.path);
        errdefer allocator.free(relative_definition);
        const bytes = try allocator.dupe(u8, archive.content);
        errdefer allocator.free(bytes);
        result.definition_after = .{
            .path = relative_definition,
            .bytes = bytes,
            .digest = try definition_core.canonical_json.digestBytesAlloc(allocator, bytes),
        };
    }
    return result;
}

fn captureBefore(
    allocator: std.mem.Allocator,
    scope: *storage_root.Scope,
    root: []const u8,
    owner: Owner,
    slot: engine.storage.Slot,
) !History {
    var result: History = .{};
    errdefer result.deinit(allocator);
    const path = try std.fs.path.join(
        allocator,
        &.{ root, storage_root.controlComponent(scope), slot.relative_path },
    );
    defer allocator.free(path);
    const content = try durable_store.readRegularFileNoSymlink(
        scope.fs,
        allocator,
        path,
        resolved(slot).max_bytes,
    );
    defer allocator.free(content);
    const binding_path = try engine.custody.bindingPathAlloc(
        scope,
        allocator,
        root,
        slot.relative_path,
    );
    defer allocator.free(binding_path);
    var binding = try engine.custody.readBindingSnapshotBeforeReplay(
        scope,
        allocator,
        binding_path,
        owner.plan.definition_plan.id,
        slot.name,
        slot.relative_path,
        null,
    );
    defer binding.deinit(allocator);
    const relative_binding = try relativeControl(allocator, scope, root, binding_path);
    defer allocator.free(relative_binding);
    try append(allocator, &result, slot.relative_path, content);
    try append(allocator, &result, relative_binding, binding.bytes);
    result.exists = true;
    result.binding_rows = binding.rows.len;
    if (binding.exists) {
        // A stale tip is permitted only through the native maintenance preview.
        // Its observed chain and immutable dependencies still constrain selection.
        const snapshot: engine.custody.SlotSnapshot = .{
            .exists = true,
            .path = path,
            .content = content,
            .revision = result.files.items[0].digest,
            .binding = binding,
        };
        try captureDependencies(allocator, scope, root, owner, slot, &snapshot, &result);
    }
    return result;
}

fn captureDependencies(
    allocator: std.mem.Allocator,
    scope: *storage_root.Scope,
    root: []const u8,
    owner: Owner,
    slot: engine.storage.Slot,
    snapshot: *const engine.custody.SlotSnapshot,
    history: *History,
) !void {
    var dependencies = try engine.replay.collectHistoryDependencies(
        scope,
        allocator,
        root,
        owner.plan.definition_plan.id,
        resolved(slot),
        snapshot,
        limits.max_files - 2,
    );
    defer dependencies.deinit(allocator);
    for (dependencies.definitions) |digest| {
        const path = try engine.definition_archive.pathAlloc(scope, allocator, root, digest);
        defer allocator.free(path);
        const bytes = try scope.readFile(
            allocator,
            path,
            @min(engine.definition_archive.max_bytes, limits.max_bytes - history.bytes),
        );
        defer allocator.free(bytes);
        const relative = try relativeControl(allocator, scope, root, path);
        defer allocator.free(relative);
        try append(allocator, history, relative, bytes);
    }
    history.revision_offset = history.files.items.len;
    for (dependencies.revisions) |revision| {
        const path = try engine.revision_archive.pathAlloc(scope, allocator, root, revision.digest);
        defer allocator.free(path);
        const bytes = try engine.revision_archive.load(
            scope,
            allocator,
            root,
            revision.digest,
            @min(revision.max_bytes, limits.max_bytes - history.bytes),
        );
        defer allocator.free(bytes);
        const relative = try relativeControl(allocator, scope, root, path);
        defer allocator.free(relative);
        try append(allocator, history, relative, bytes);
    }
    history.epochs = try allocator.dupe(engine.replay.HistoryEpoch, dependencies.epochs);
}

fn completePrefix(before: []const u8, after: []const u8) bool {
    return std.mem.startsWith(u8, after, before) and
        (before.len == after.len or before.len == 0 or before[before.len - 1] == '\n');
}

fn coversOriginal(candidate: *const History, other: *const History) bool {
    if (!other.exists) return true;
    if (!candidate.exists) return false;
    if (other.binding_rows == 0) {
        return completePrefix(other.files.items[0].bytes, candidate.files.items[0].bytes);
    }
    return candidate.covers(other);
}

pub fn selectSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    snapshot: *const legacy.Inventory,
    owners: []const Owner,
) !?usize {
    const count = snapshot.sources.map.count();
    if (count == 0 or count > 128) return error.MigrationInventoryBoundExceeded;
    var covering: [128]bool = @splat(true);
    var present: [128]bool = @splat(false);
    for (owners) |owner| for (owner.plan.storage_plan.?.slots) |slot| {
        // Compare one slot's bounded source observations in memory, then release
        // their shared metadata before inspecting another slot or owner.
        var observations: std.ArrayList(Observation) = .empty;
        defer {
            for (observations.items) |*observation| observation.deinit(allocator);
            observations.deinit(allocator);
        }
        var bytes: usize = 0;
        var files: usize = 0;
        for (snapshot.sources.map.values()) |source| {
            var scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
            var observed = try capture(
                allocator,
                io,
                environment,
                &scope,
                source.workspace,
                owner,
                slot,
                false,
            );
            errdefer observed.deinit(allocator);
            if (observed.original.bytes > limits.max_bytes - bytes or
                observed.original.files.items.len > limits.max_files - files)
                return error.MigrationInventoryBoundExceeded;
            bytes += observed.original.bytes;
            files += observed.original.files.items.len;
            try observations.append(allocator, observed);
        }
        for (observations.items, 0..) |*candidate, index| {
            present[index] = present[index] or candidate.original.exists;
            for (observations.items) |*other| {
                if (!coversOriginal(&candidate.original, &other.original)) covering[index] = false;
            }
        }
    };
    var selected: ?usize = null;
    var any = false;
    for (snapshot.sources.map.values(), 0..) |candidate, index| {
        any = any or present[index];
        if (!covering[index] or !present[index]) continue;
        if (selected == null or std.mem.lessThan(
            u8,
            candidate.workspace,
            snapshot.sources.map.values()[selected.?].workspace,
        )) selected = index;
    }
    if (any and selected == null) return error.DivergentSelectedHistories;
    return selected;
}

pub fn requireCovered(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    owners: []const Owner,
    source: ?[]const u8,
    root: []const u8,
    id: []const u8,
    partial: bool,
    repair: bool,
) !void {
    const control = try storage_root.checkedRoot(allocator, io, root, id);
    defer control.close(io);
    for (owners) |owner| for (owner.plan.storage_plan.?.slots) |slot| {
        var input_scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
        var expected = if (source) |path|
            try capture(allocator, io, environment, &input_scope, path, owner, slot, true)
        else
            Observation{};
        defer expected.deinit(allocator);
        var scope = storage_root.Scope.init(.anchored(io, control));
        var actual = capture(
            allocator,
            io,
            environment,
            &scope,
            ".",
            owner,
            slot,
            true,
        ) catch |err| {
            if (!partial or !expected.original.exists) return err;
            switch (err) {
                error.FileNotFound,
                error.StoreSlotWithoutBinding,
                error.StoreBindingWithoutSlot,
                error.InvalidStoreBinding,
                error.StoreBindingRevisionMismatch,
                error.StoreBindingRecordCountMismatch,
                => {},
                else => return err,
            }
            // Interrupted copying may not yet form a valid native history. Only
            // exact existing members of the admitted original are resumable.
            try requirePartial(allocator, &scope, &expected.original);
            continue;
        };
        defer actual.deinit(allocator);
        if (partial and expected.original.exists and
            (!actual.original.exists or actual.binding_after != null))
        {
            try requirePartial(allocator, &scope, &expected.original);
            continue;
        }
        var expected_files: [3]engine.preparation.File = undefined;
        var actual_files: [3]engine.preparation.File = undefined;
        const expected_image = expected.image(&expected_files);
        const actual_image = actual.image(&actual_files);
        if (actual.binding_after != null and
            (!repair or !coversOriginal(&actual.original, &expected.original)))
            return error.AdditionalOrDivergentHistory;
        if (!actual_image.covers(&expected_image)) return error.AdditionalOrDivergentHistory;
    };
}

fn requirePartial(
    allocator: std.mem.Allocator,
    scope: *storage_root.Scope,
    expected: *const History,
) !void {
    for (expected.files.items) |file| {
        const bytes = durable_store.readRegularFileNoSymlink(
            scope.fs,
            allocator,
            file.path,
            file.bytes.len,
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, file.bytes)) return error.AdditionalOrDivergentHistory;
    }
}

test "migration history distinguishes admission identity and retains stale before lineage" {
    const allocator = std.testing.allocator;
    var short: History = .{ .exists = true, .binding_rows = 1 };
    defer short.deinit(allocator);
    try append(allocator, &short, "events.jsonl", "{\"id\":1}\n");
    try append(allocator, &short, ".bindings/events.jsonl", "request-one\n");
    try append(allocator, &short, ".definitions/one.json", "definition-one");
    var stale: History = .{ .exists = true, .binding_rows = 1 };
    defer stale.deinit(allocator);
    try append(allocator, &stale, "events.jsonl", "{\"id\":1}\n{\"id\":2}\n");
    try append(allocator, &stale, ".bindings/events.jsonl", "request-one\n");
    try append(allocator, &stale, ".definitions/one.json", "definition-one");
    try std.testing.expect(coversOriginal(&stale, &short));
    stale.files.items[1].bytes[8] = 't';
    try std.testing.expect(!coversOriginal(&stale, &short));
    stale.files.items[1].bytes[8] = 'o';
    stale.files.items[2].bytes[0] = 'D';
    try std.testing.expect(!coversOriginal(&stale, &short));
}

test "migration unbound evidence cannot cover or connect distinct native admissions" {
    const allocator = std.testing.allocator;
    var unbound: History = .{ .exists = true };
    defer unbound.deinit(allocator);
    try append(allocator, &unbound, "events.jsonl", "{\"id\":1}\n");
    try append(allocator, &unbound, ".bindings/events.jsonl", "");
    var bound: History = .{ .exists = true, .binding_rows = 1 };
    defer bound.deinit(allocator);
    try append(allocator, &bound, "events.jsonl", "{\"id\":1}\n");
    try append(allocator, &bound, ".bindings/events.jsonl", "request-one\n");
    try std.testing.expect(coversOriginal(&bound, &unbound));
    try std.testing.expect(!coversOriginal(&unbound, &bound));
    try std.testing.expect(coversOriginal(&unbound, &unbound));
}
