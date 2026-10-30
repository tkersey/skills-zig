const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const storage_root = @import("storage_root");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const replay = @import("replay.zig");
const storage = @import("storage.zig");
const storage_capture = @import("storage_capture.zig");
const definition_archive = @import("definition_archive.zig");
const revision_archive = @import("revision_archive.zig");
const protocol = @import("protocol.zig");
const storage_sources = @import("storage_sources.zig");
const validation = @import("validation.zig");
const transaction = @import("transaction.zig");

pub fn selectBoundHistory(
    snapshots: []const *const DeclaredSnapshot,
    established_target: ?usize,
) !usize {
    if (snapshots.len == 0) return error.NoPreparationSources;
    if (snapshots.len > storage_sources.max_sources) return error.TooManySources;
    if (established_target) |target| {
        if (target >= snapshots.len) return error.InvalidPreparationTarget;
    }
    for (snapshots) |snapshot| {
        if (snapshot.role != .source) return error.PreparationTargetIsNotSource;
        if (!snapshot.coordinated()) return error.PreparationSourceUncoordinated;
        try requireSameSelection(snapshots[0], snapshot);
    }
    var selected = established_target orelse 0;
    if (established_target == null) {
        for (snapshots[1..], 1..) |candidate, index| {
            if (!coversBoundHistory(snapshots[selected], candidate) and
                coversBoundHistory(candidate, snapshots[selected]))
            {
                selected = index;
            }
        }
    }
    for (snapshots) |snapshot| {
        if (!coversBoundHistory(snapshots[selected], snapshot)) {
            return error.PreparationReconciliationRequired;
        }
    }
    return selected;
}

fn requireSameSelection(left: *const DeclaredSnapshot, right: *const DeclaredSnapshot) !void {
    if (!std.mem.eql(u8, left.definition_id, right.definition_id) or
        !std.mem.eql(u8, &left.definition_digest, &right.definition_digest) or
        !std.mem.eql(u8, &left.parameter_digest, &right.parameter_digest) or
        left.resolved.slot_count != right.resolved.slot_count)
    {
        return error.PreparationDefinitionMismatch;
    }
    for (left.resolved.slotSlice(), right.resolved.slotSlice()) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or
            !std.mem.eql(u8, a.relative_path, b.relative_path) or
            a.kind != b.kind or a.codec != b.codec or a.layout != b.layout)
        {
            return error.PreparationDefinitionMismatch;
        }
    }
}

pub const HistorySlot = struct {
    exists: bool,
    content: []const u8 = "",
    binding_bytes: ?[]const u8 = null,
    binding_rows: usize = 0,

    pub fn fromSnapshot(snapshot: *const custody.SlotSnapshot) HistorySlot {
        return .{
            .exists = snapshot.exists,
            .content = snapshot.content,
            .binding_bytes = if (snapshot.binding.exists) snapshot.binding.bytes else null,
            .binding_rows = snapshot.binding.rows.len,
        };
    }
};

pub fn coversHistorySlot(kind: storage.SlotKind, cover: HistorySlot, source: HistorySlot) bool {
    if (!source.exists) return true;
    if (!cover.exists) return false;
    const source_binding = source.binding_bytes orelse return if (kind == .event_log)
        completeRecordPrefix(cover.content, source.content)
    else
        std.mem.eql(u8, cover.content, source.content);
    const cover_binding = cover.binding_bytes orelse return false;
    if (cover.binding_rows < source.binding_rows) return false;
    if (!completeRecordPrefix(cover_binding, source_binding)) return false;
    return cover.binding_rows != source.binding_rows or
        std.mem.eql(u8, cover.content, source.content);
}

fn coversBoundHistory(longer: *const DeclaredSnapshot, shorter: *const DeclaredSnapshot) bool {
    for (longer.slots, shorter.slots, 0..) |*cover, *source, index| {
        if (!coversHistorySlot(
            longer.resolved.slot(index).kind,
            HistorySlot.fromSnapshot(cover),
            HistorySlot.fromSnapshot(source),
        )) return false;
    }
    return true;
}

fn completeRecordPrefix(longer: []const u8, shorter: []const u8) bool {
    if (!std.mem.startsWith(u8, longer, shorter)) return false;
    if (shorter.len == longer.len) return true;
    const prior = std.mem.trimEnd(u8, shorter, " \t\r");
    if (prior.len == 0 or prior[prior.len - 1] == '\n') return true;
    for (longer[shorter.len..]) |byte| {
        if (byte == '\n') return true;
        if (byte != ' ' and byte != '\t' and byte != '\r') return false;
    }
    return true;
}

pub const FileDependency = struct {
    path: []const u8,
    max_bytes: usize,
    identity: union(enum) { content: []const u8, definition_closure: []const u8, native_recovery },

    pub fn validateCaptured(
        self: FileDependency,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        if (bytes.len > self.max_bytes) return error.CaptureLimitExceeded;
        switch (self.identity) {
            .native_recovery => {},
            .content => |expected| {
                const actual = try definition_core.canonical_json.digestBytesAlloc(
                    allocator,
                    bytes,
                );
                defer allocator.free(actual);
                if (!std.mem.eql(u8, expected, actual)) return error.PreparationSourceChanged;
            },
            .definition_closure => |expected| {
                var archive = try definition_archive.parse(allocator, bytes, expected);
                defer archive.deinit(allocator);
            },
        }
    }
};

pub const BudgetContext = struct {
    budget: *durable_store.ReservationBudget,
    budget_id: []const u8,
    store_id: []const u8,
};

pub const LoadOptions = struct {
    max_snapshot_bytes: usize,
    binding_operation: ?[]const u8 = null,
    budget: ?BudgetContext = null,
};

pub const RecoveryCoverage = enum { uncoordinated, transaction_root_only, supplied_budget_store };

const RecoverySnapshot = union(enum) {
    native: durable_store.TransactionDependencySnapshot,
    budget: durable_store.ReservationDependencySnapshot,

    fn deinit(self: *RecoverySnapshot, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .native => |*snapshot| snapshot.deinit(allocator),
            .budget => |*snapshot| snapshot.deinit(allocator),
        }
        self.* = undefined;
    }

    fn transactions(
        self: *const RecoverySnapshot,
    ) *const durable_store.TransactionDependencySnapshot {
        return switch (self.*) {
            .native => |*snapshot| snapshot,
            .budget => |*snapshot| &snapshot.transactions,
        };
    }

    fn remainingBytes(self: *const RecoverySnapshot, maximum: usize) !usize {
        if (self.* == .budget and self.budget.pending) {
            return error.PreparationSourceRecoveryRequired;
        }
        const metadata_bytes = switch (self.*) {
            .native => |snapshot| snapshot.journal_bytes_read,
            .budget => |snapshot| snapshot.metadata_bytes_read,
        };
        if (metadata_bytes > maximum) return error.PreparationSnapshotLimitExceeded;
        return maximum - metadata_bytes;
    }
};

pub const DeclaredSnapshot = struct {
    role: enum { source, target } = .source,
    source: *const storage_root.SourceRoot,
    resolved: storage.ResolvedPlan,
    slots: []custody.SlotSnapshot,
    scope: ?storage_root.Scope,
    definition_id: []const u8,
    definition_digest: [71]u8,
    parameter_digest: [71]u8,
    snapshot_bytes: usize = 0,
    recovery: ?RecoverySnapshot = null,
    capture_limit: usize,

    pub fn loadForApply(
        allocator: std.mem.Allocator,
        source: *storage_root.SourceRoot,
        artifact: *const definition.Plan,
        store: *const storage.Plan,
        parameters: *const definition_core.parameters.Bindings,
        max_snapshot_bytes: usize,
        storage_mutated: *bool,
    ) !DeclaredSnapshot {
        return loadForApplyWithContext(allocator, source, artifact, store, parameters, .{
            .max_snapshot_bytes = max_snapshot_bytes,
        }, storage_mutated);
    }

    pub fn loadForApplyWithContext(
        allocator: std.mem.Allocator,
        source: *storage_root.SourceRoot,
        artifact: *const definition.Plan,
        store: *const storage.Plan,
        parameters: *const definition_core.parameters.Bindings,
        options: LoadOptions,
        storage_mutated: *bool,
    ) !DeclaredSnapshot {
        try validateContext(source, options);
        var resolved = try resolvePreparationSlots(allocator, store, parameters);
        defer resolved.deinit(allocator);
        try source.prepareControlForApply(storage_mutated);
        var scope = source.scope().?;
        for (resolved.slotSlice()) |slot| {
            const binding = try custody.bindingPathAlloc(
                &scope,
                allocator,
                ".",
                slot.relative_path,
            );
            defer allocator.free(binding);
            try ensureAdvisory(allocator, scope.fs, slot.relative_path, storage_mutated);
            try ensureAdvisory(allocator, scope.fs, binding, storage_mutated);
        }
        const transactions_path = try std.fs.path.join(
            allocator,
            &.{ ".", storage_root.controlComponent(&scope), ".transactions" },
        );
        defer allocator.free(transactions_path);
        try durable_store.ensureTransactionDependencyCoordination(
            scope.fs,
            allocator,
            transactions_path,
            storage_mutated,
        );
        var snapshot = try loadWithContext(
            allocator,
            source,
            artifact,
            store,
            parameters,
            options,
        );
        errdefer snapshot.deinit(allocator);
        if (!snapshot.coordinated()) return error.PreparationSourceUncoordinated;
        return snapshot;
    }

    pub fn load(
        allocator: std.mem.Allocator,
        source: *const storage_root.SourceRoot,
        artifact: *const definition.Plan,
        store: *const storage.Plan,
        parameters: *const definition_core.parameters.Bindings,
        max_snapshot_bytes: usize,
    ) !DeclaredSnapshot {
        return loadWithContext(
            allocator,
            source,
            artifact,
            store,
            parameters,
            .{ .max_snapshot_bytes = max_snapshot_bytes },
        );
    }

    pub fn loadWithAdmission(
        allocator: std.mem.Allocator,
        source: *const storage_root.SourceRoot,
        artifact: *const definition.Plan,
        store: *const storage.Plan,
        parameters: *const definition_core.parameters.Bindings,
        max_snapshot_bytes: usize,
        operation_name: []const u8,
    ) !DeclaredSnapshot {
        return loadWithContext(allocator, source, artifact, store, parameters, .{
            .max_snapshot_bytes = max_snapshot_bytes,
            .binding_operation = operation_name,
        });
    }

    pub fn loadWithContext(
        allocator: std.mem.Allocator,
        source: *const storage_root.SourceRoot,
        artifact: *const definition.Plan,
        store: *const storage.Plan,
        parameters: *const definition_core.parameters.Bindings,
        options: LoadOptions,
    ) !DeclaredSnapshot {
        try validateContext(source, options);
        const operation = if (options.binding_operation) |name|
            store.findOperation(name) orelse return error.PreparationBindingOperationNotFound
        else
            null;
        return loadInternal(
            allocator,
            source,
            artifact,
            store,
            parameters,
            options,
            operation,
            null,
        );
    }

    fn loadInternal(
        allocator: std.mem.Allocator,
        source: *const storage_root.SourceRoot,
        artifact: *const definition.Plan,
        store: *const storage.Plan,
        parameters: *const definition_core.parameters.Bindings,
        options: LoadOptions,
        admission: ?*const storage.Operation,
        restoration: ?[]const RestorationInput,
    ) !DeclaredSnapshot {
        const max_snapshot_bytes = options.max_snapshot_bytes;
        var resolved = try resolvePreparationSlots(allocator, store, parameters);
        errdefer resolved.deinit(allocator);
        var event_protocol = try protocol.compile(allocator, artifact, store);
        defer if (event_protocol) |*plan| plan.deinit(allocator);
        const validator: SourceValidation = .{
            .artifact = artifact,
            .store = store,
            .parameters = parameters,
            .event_protocol = if (event_protocol) |*plan| plan else null,
            .admission = admission,
            .restoration = restoration,
        };
        if (restoration) |inputs| try validateRestorationInputs(resolved.slotSlice(), inputs);
        var scope = source.scope();
        var recovery = if (scope) |authority|
            try loadRecovery(allocator, source, authority, &resolved, options)
        else
            null;
        errdefer if (recovery) |*held| held.deinit(allocator);
        var remaining = if (recovery) |*held|
            try held.remainingBytes(max_snapshot_bytes)
        else
            max_snapshot_bytes;
        const slots = try allocator.alloc(
            custody.SlotSnapshot,
            if (scope == null) 0 else resolved.slot_count,
        );
        var initialized: usize = 0;
        errdefer {
            for (slots[0..initialized]) |*slot| slot.deinit(allocator);
            allocator.free(slots);
        }
        for (slots, 0..) |*snapshot, index| {
            snapshot.* = try validator.readSlot(
                &scope.?,
                allocator,
                resolved.slot(index),
                index,
                &remaining,
            );
            initialized += 1;
        }
        return .{
            .role = if (restoration == null) .source else .target,
            .source = source,
            .resolved = resolved,
            .slots = slots,
            .scope = scope,
            .definition_id = artifact.id,
            .definition_digest = artifact.closure_digest,
            .parameter_digest = parameters.values_digest,
            .snapshot_bytes = max_snapshot_bytes - remaining,
            .recovery = recovery,
            .capture_limit = max_snapshot_bytes,
        };
    }

    pub fn deinit(self: *DeclaredSnapshot, allocator: std.mem.Allocator) void {
        for (self.slots) |*slot| slot.deinit(allocator);
        allocator.free(self.slots);
        if (self.recovery) |*held| held.deinit(allocator);
        self.resolved.deinit(allocator);
        self.* = undefined;
    }

    pub fn releaseCustody(self: *DeclaredSnapshot, allocator: std.mem.Allocator) void {
        for (self.slots) |*slot| {
            if (slot.read_custody) |*held| held.deinit();
            slot.read_custody = null;
        }
        if (self.recovery) |*held| held.deinit(allocator);
        self.recovery = null;
    }

    pub fn coordinated(self: *const DeclaredSnapshot) bool {
        if (self.scope == null or self.recovery == null) return false;
        if (self.recovery.?.transactions().coordination != .retained_read_custody) return false;
        for (self.slots) |slot| {
            const locks = slot.read_custody orelse return false;
            if (locks.count != 2) return false;
        }
        return true;
    }

    pub fn publicationDependency(
        self: *DeclaredSnapshot,
    ) !*durable_store.TransactionDependencySnapshot {
        if (!self.coordinated()) return error.PreparationSourceUncoordinated;
        return switch (self.recovery.?) {
            .native => |*snapshot| snapshot,
            .budget => |*snapshot| &snapshot.transactions,
        };
    }

    pub fn recoveryCoverage(self: *const DeclaredSnapshot) RecoveryCoverage {
        if (!self.coordinated()) return .uncoordinated;
        return switch (self.recovery.?) {
            .native => .transaction_root_only,
            .budget => .supplied_budget_store,
        };
    }

    pub fn visitFiles(
        self: *DeclaredSnapshot,
        allocator: std.mem.Allocator,
        visitor: anytype,
    ) !void {
        if (self.role != .source) return error.PreparationTargetIsNotSource;
        if (!self.coordinated()) return error.PreparationSourceUncoordinated;
        try self.requireSettledRecovery();
        for (self.slots, 0..) |snapshot, index| {
            if (!snapshot.exists) continue;
            const slot = self.resolved.slot(index);
            try visitor.visit(FileDependency{
                .path = slot.relative_path,
                .max_bytes = slot.max_bytes,
                .identity = .{ .content = snapshot.revision },
            });
            if (!snapshot.binding.exists) continue;
            const binding = try custody.bindingPathAlloc(
                &self.scope.?,
                allocator,
                ".",
                slot.relative_path,
            );
            defer allocator.free(binding);
            try visitor.visit(FileDependency{
                .path = controlRelative(binding),
                .max_bytes = custody.binding_max_bytes,
                .identity = .{ .content = snapshot.binding.digest.? },
            });
            var adapter = ArchiveVisitor(@TypeOf(visitor)){
                .scope = &self.scope.?,
                .allocator = allocator,
                .visitor = visitor,
            };
            try replay.visitBindingDependencies(
                &self.scope.?,
                allocator,
                ".",
                self.definition_id,
                slot,
                snapshot.binding.rows,
                &adapter,
            );
        }
        for (self.recovery.?.transactions().transactions) |record| {
            for (record.entries) |dependency| {
                if (!dependency.present) continue;
                try visitor.visit(FileDependency{
                    .path = controlRelative(dependency.path),
                    .max_bytes = self.capture_limit,
                    .identity = .native_recovery,
                });
            }
        }
    }
    fn requireSettledRecovery(self: *const DeclaredSnapshot) !void {
        for (self.recovery.?.transactions().transactions) |record| {
            if (record.state != .committed) return error.PreparationSourceRecoveryRequired;
            var committed = false;
            for (record.entries) |dependency| {
                if (dependency.kind == .reservation_pin and self.recovery.? == .native) {
                    return error.PreparationBudgetContextRequired;
                }
                if (dependency.kind == .commit_marker) committed = dependency.present;
            }
            if (!committed) return error.PreparationSourceRecoveryRequired;
        }
    }

    pub fn visitRecoveryEvidence(self: *const DeclaredSnapshot, visitor: anytype) !void {
        if (!self.coordinated()) return error.PreparationSourceUncoordinated;
        try self.requireSettledRecovery();
        if (self.recovery.? == .budget) {
            for (self.recovery.?.budget.evidence) |evidence| {
                try visitor.visitEvidence(evidence.bytes);
            }
        }
    }
};

pub const Publication = struct {
    arena: std.heap.ArenaAllocator,
    source: @FieldType(durable_store.TransactionPublicationCustody, "source"),
    custody: ?durable_store.TransactionPublicationCustody,
    checks: []const durable_store.TransactionMutation,

    pub fn acquire(
        allocator: std.mem.Allocator,
        snapshots: []const *DeclaredSnapshot,
    ) !Publication {
        var result = try prepare(allocator, snapshots);
        errdefer result.deinit(allocator);
        try result.acquireCustody(allocator, snapshots);
        return result;
    }

    pub fn prepare(
        allocator: std.mem.Allocator,
        snapshots: []const *DeclaredSnapshot,
    ) !Publication {
        if (snapshots.len == 0) return error.NoPreparationSources;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const source = (try snapshots[0].publicationDependency()).source;
        var checks: std.ArrayList(durable_store.TransactionMutation) = .empty;
        for (snapshots) |snapshot| {
            const dependency = try snapshot.publicationDependency();
            if (!std.meta.eql(source, dependency.source)) return error.PreparationSourceChanged;
            try snapshot.requireSettledRecovery();
            try snapshot.source.revalidateControl();
            for (snapshot.slots, 0..) |slot, index| {
                try appendCheck(
                    owned,
                    &checks,
                    slot.path,
                    slot.exists,
                    slot.revision,
                    slot.content.len,
                );
                const binding = try custody.bindingPathAlloc(
                    &snapshot.scope.?,
                    owned,
                    ".",
                    snapshot.resolved.slot(index).relative_path,
                );
                try appendCheck(
                    owned,
                    &checks,
                    binding,
                    slot.binding.exists,
                    slot.binding.digest,
                    slot.binding.bytes.len,
                );
            }
        }
        return .{ .arena = arena, .source = source, .custody = null, .checks = checks.items };
    }

    pub fn acquireCustody(
        self: *Publication,
        allocator: std.mem.Allocator,
        snapshots: []const *DeclaredSnapshot,
    ) !void {
        if (self.custody != null) return error.PreparationSourceCoordinated;
        const dependencies = try allocator.alloc(
            *durable_store.TransactionDependencySnapshot,
            snapshots.len,
        );
        defer allocator.free(dependencies);
        for (snapshots, dependencies) |snapshot, *dependency| {
            dependency.* = try snapshot.publicationDependency();
            if (!std.meta.eql(self.source, dependency.*.source)) {
                return error.PreparationSourceChanged;
            }
        }
        self.custody = try durable_store.TransactionPublicationCustody.acquire(
            allocator,
            dependencies,
        );
        for (snapshots) |snapshot| {
            for (snapshot.slots) |*slot| {
                if (slot.read_custody) |*read_custody| read_custody.deinit();
                slot.read_custody = null;
            }
        }
    }

    pub fn deinit(self: *Publication, allocator: std.mem.Allocator) void {
        self.releaseCustody(allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn releaseCustody(self: *Publication, allocator: std.mem.Allocator) void {
        if (self.custody) |*held| held.deinit(allocator);
        self.custody = null;
    }

    pub fn nativeCustody(
        self: *const Publication,
    ) !*const durable_store.TransactionPublicationCustody {
        return if (self.custody) |*held| held else error.PreparationSourceUncoordinated;
    }

    pub fn reacquire(
        self: *Publication,
        allocator: std.mem.Allocator,
        snapshot: *DeclaredSnapshot,
    ) !void {
        if (self.custody != null) return error.PreparationSourceCoordinated;
        var next = try acquire(allocator, &.{snapshot});
        errdefer next.deinit(allocator);
        if (!std.meta.eql(self.source, next.source)) return error.PreparationSourceChanged;
        if (self.checks.len != next.checks.len) return error.PreparationSourceChanged;
        for (self.checks) |expected| {
            var found = false;
            for (next.checks) |current| {
                if (!std.mem.eql(u8, expected.path, current.path)) continue;
                if (!sameExpectation(expected, current)) return error.PreparationSourceChanged;
                found = true;
                break;
            }
            if (!found) return error.PreparationSourceChanged;
        }
        self.deinit(allocator);
        self.* = next;
    }

    pub fn include(
        self: *const Publication,
        allocator: std.mem.Allocator,
        mutations: *std.ArrayList(durable_store.TransactionMutation),
    ) !void {
        for (self.checks) |check| {
            var found = false;
            for (mutations.items) |mutation| {
                if (!std.mem.eql(u8, mutation.path, check.path)) continue;
                if (!sameExpectation(mutation, check)) return error.PreparationSourceChanged;
                found = true;
            }
            if (!found) try mutations.append(allocator, check);
        }
    }

    fn appendCheck(
        allocator: std.mem.Allocator,
        checks: *std.ArrayList(durable_store.TransactionMutation),
        path: []const u8,
        exists: bool,
        digest: ?[]const u8,
        size: usize,
    ) !void {
        const check: durable_store.TransactionMutation = .{
            .path = path,
            .text = "",
            .expectation = .{
                .expected_exists = exists,
                .expected_digest = if (exists) digest else null,
            },
            .content_mode = .raw,
            .max_bytes = size,
            .action = .check_only,
        };
        for (checks.items) |prior| {
            if (!std.mem.eql(u8, prior.path, path)) continue;
            if (!sameExpectation(prior, check)) return error.PreparationSourceChanged;
            return;
        }
        var owned = check;
        owned.path = try allocator.dupe(u8, path);
        if (check.expectation.expected_digest) |value| {
            owned.expectation.expected_digest = try allocator.dupe(u8, value);
        }
        try checks.append(allocator, owned);
    }

    fn sameExpectation(
        a: durable_store.TransactionMutation,
        b: durable_store.TransactionMutation,
    ) bool {
        if (a.expectation.expected_exists != b.expectation.expected_exists) return false;
        const left = a.expectation.expected_digest;
        const right = b.expectation.expected_digest;
        if ((left == null) != (right == null)) return false;
        return if (left) |value| std.mem.eql(u8, value, right.?) else true;
    }
};

fn validateContext(source: *const storage_root.SourceRoot, options: LoadOptions) !void {
    if (options.budget) |context| {
        if (source.store_id) |store_id| {
            if (!std.mem.eql(u8, context.store_id, store_id)) {
                return error.PreparationBudgetStoreMismatch;
            }
        }
    }
}

fn loadRecovery(
    allocator: std.mem.Allocator,
    source: *const storage_root.SourceRoot,
    scope: storage_root.Scope,
    resolved: *const storage.ResolvedPlan,
    options: LoadOptions,
) !?RecoverySnapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const control_path = try storage_root.controlPathAlloc(&scope, temporary, ".");
    const paths = try temporary.alloc([]const u8, resolved.slot_count * 2);
    for (resolved.slotSlice(), 0..) |slot, index| {
        paths[index * 2] = try std.fs.path.join(temporary, &.{ control_path, slot.relative_path });
        var authority = scope;
        paths[index * 2 + 1] = try custody.bindingPathAlloc(
            &authority,
            temporary,
            ".",
            slot.relative_path,
        );
    }
    const transactions_path = try std.fs.path.join(temporary, &.{ control_path, ".transactions" });
    const location: durable_store.TransactionDependencyLocation = .{
        .recorded_control_root = try std.fs.path.join(temporary, &.{ source.locator, ".ledger" }),
    };
    if (options.budget) |context| {
        return .{ .budget = try context.budget.snapshotDependencies(
            allocator,
            scope.fs,
            transactions_path,
            paths,
            location,
            .{
                .budget_id = context.budget_id,
                .store_id = context.store_id,
                .limits = .{ .journal_bytes = options.max_snapshot_bytes },
            },
        ) };
    }
    return .{ .native = durable_store.snapshotTransactionDependenciesAt(
        scope.fs,
        allocator,
        transactions_path,
        paths,
        location,
        .{ .journal_bytes = options.max_snapshot_bytes },
    ) catch |err| switch (err) {
        error.FileNotFound, error.TransactionDependencyCoordinationUnavailable => return null,
        error.TransactionDependencyBudgetContextRequired => {
            return error.PreparationBudgetContextRequired;
        },
        else => return err,
    } };
}

pub const RestorationInput = struct {
    slot_name: []const u8,
    content: []const u8,
};

pub const TargetSnapshot = struct {
    observed: DeclaredSnapshot,

    pub fn load(
        allocator: std.mem.Allocator,
        source: *const storage_root.SourceRoot,
        artifact: *const definition.Plan,
        store: *const storage.Plan,
        parameters: *const definition_core.parameters.Bindings,
        inputs: []const RestorationInput,
        options: LoadOptions,
    ) !TargetSnapshot {
        try validateContext(source, options);
        const operation = if (options.binding_operation) |name|
            store.findOperation(name) orelse return error.PreparationBindingOperationNotFound
        else
            null;
        var observed = try DeclaredSnapshot.loadInternal(
            allocator,
            source,
            artifact,
            store,
            parameters,
            options,
            operation,
            inputs,
        );
        errdefer observed.deinit(allocator);
        if (!observed.coordinated()) return error.PreparationSourceUncoordinated;
        try observed.requireSettledRecovery();
        return .{ .observed = observed };
    }

    pub fn releaseForPublication(
        self: *TargetSnapshot,
        allocator: std.mem.Allocator,
    ) !Publication {
        return Publication.acquire(allocator, &.{&self.observed});
    }

    pub fn deinit(self: *TargetSnapshot, allocator: std.mem.Allocator) void {
        self.observed.deinit(allocator);
        self.* = undefined;
    }
};

fn validateRestorationInputs(
    slots: []const storage.ResolvedSlot,
    inputs: []const RestorationInput,
) !void {
    if (inputs.len > slots.len) return error.InvalidRestorationInput;
    for (inputs, 0..) |input, index| {
        for (inputs[0..index]) |prior| {
            if (std.mem.eql(u8, prior.slot_name, input.slot_name)) {
                return error.InvalidRestorationInput;
            }
        }
        var found = false;
        for (slots) |slot| {
            if (std.mem.eql(u8, slot.name, input.slot_name)) found = true;
        }
        if (!found) return error.InvalidRestorationInput;
    }
}

const SourceValidation = struct {
    artifact: *const definition.Plan,
    store: *const storage.Plan,
    parameters: *const definition_core.parameters.Bindings,
    event_protocol: ?*const protocol.Plan,
    admission: ?*const storage.Operation,
    restoration: ?[]const RestorationInput = null,

    fn readSlot(
        self: SourceValidation,
        scope: *storage_root.Scope,
        allocator: std.mem.Allocator,
        slot: storage.ResolvedSlot,
        index: usize,
        remaining: *usize,
    ) !custody.SlotSnapshot {
        var limited_slot = slot;
        limited_slot.max_bytes = @min(limited_slot.max_bytes, remaining.*);
        var snapshot = custody.readPreparationSlot(
            scope,
            allocator,
            ".",
            self.artifact.id,
            limited_slot,
        ) catch |err| switch (err) {
            error.StoreBindingWithoutSlot => try self.restoreSlot(
                scope,
                allocator,
                limited_slot,
                index,
            ),
            else => return err,
        };
        errdefer snapshot.deinit(allocator);
        const bytes = std.math.add(
            usize,
            snapshot.content.len,
            snapshot.binding.bytes.len,
        ) catch return error.PreparationSnapshotLimitExceeded;
        if (bytes > remaining.*) return error.PreparationSnapshotLimitExceeded;
        remaining.* -= bytes;
        try self.validate(scope, allocator, slot, index, &snapshot);
        return snapshot;
    }

    fn restoreSlot(
        self: SourceValidation,
        scope: *storage_root.Scope,
        allocator: std.mem.Allocator,
        slot: storage.ResolvedSlot,
        index: usize,
    ) !custody.SlotSnapshot {
        const inputs = self.restoration orelse return error.StoreBindingWithoutSlot;
        for (inputs) |input| {
            if (!std.mem.eql(u8, input.slot_name, slot.name)) continue;
            const inspected = try inspectRestoration(
                scope,
                allocator,
                self.artifact,
                ".",
                slot,
                self.parameters,
                input.content,
                if (self.event_protocol) |plan| plan.target_slot_index == index else false,
            );
            allocator.free(inspected.binding_path);
            return inspected.candidate;
        }
        return error.RestorationCandidateRequired;
    }

    fn validate(
        self: SourceValidation,
        scope: *storage_root.Scope,
        allocator: std.mem.Allocator,
        slot: storage.ResolvedSlot,
        index: usize,
        snapshot: *const custody.SlotSnapshot,
    ) !void {
        if (!snapshot.exists) return;
        if (!snapshot.binding.exists) {
            return validateUnboundSlot(
                allocator,
                self.artifact,
                self.store,
                slot,
                @intCast(index),
                self.event_protocol,
                snapshot.content,
                self.parameters,
                self.admission,
            );
        }
        var stats = try replay.validateSlot(
            scope,
            allocator,
            ".",
            self.artifact.id,
            slot,
            snapshot,
            self.parameters,
            self.artifact.bounds.max_records,
            if (self.event_protocol) |plan| plan.target_slot_index == index else false,
        );
        stats.deinit(allocator);
    }
};

fn validateUnboundSlot(
    allocator: std.mem.Allocator,
    artifact: *const definition.Plan,
    store: *const storage.Plan,
    slot: storage.ResolvedSlot,
    index: u16,
    event_protocol: ?*const protocol.Plan,
    bytes: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    admission: ?*const storage.Operation,
) !void {
    const selected = try selectBindingOperation(store, index, admission);
    var law = try validation.compile(allocator, artifact);
    defer law.deinit(allocator);
    _ = try transaction.validateUnboundContent(
        allocator,
        artifact,
        &law,
        selected.effect,
        slot,
        event_protocol,
        bytes,
        parameters,
    );
}

pub const BindingSelection = struct { operation: *const storage.Operation, effect: storage.Effect };

pub fn selectBindingOperation(
    store: *const storage.Plan,
    index: u16,
    admission: ?*const storage.Operation,
) !BindingSelection {
    var selected: ?BindingSelection = null;
    if (admission) |operation| {
        if (try bindingEffect(operation, index)) |effect| {
            selected = .{ .operation = operation, .effect = effect };
        }
    } else {
        for (store.operations) |*operation| {
            const effect = bindingEffect(operation, index) catch continue;
            if (effect) |candidate| {
                if (selected != null) return error.PreparationBindingOperationAmbiguous;
                selected = .{ .operation = operation, .effect = candidate };
            }
        }
    }
    return selected orelse error.PreparationBindingOperationMissingSlot;
}

fn bindingEffect(operation: *const storage.Operation, index: u16) !?storage.Effect {
    var selected: ?storage.Effect = null;
    for (operation.effects) |effect| {
        if (effect.kind != .bind_existing) return error.PreparationRequiresBindExisting;
        if (effect.slot_index == index) selected = effect;
    }
    return selected;
}

fn ensureAdvisory(
    allocator: std.mem.Allocator,
    fs: durable_store.Fs,
    path: []const u8,
    storage_mutated: *bool,
) !void {
    if (try durable_store.casAdvisoryLockExists(fs, allocator, path)) return;
    try durable_store.ensureDirectoryPathNoSymlinksObserved(
        fs,
        std.fs.path.dirname(path) orelse ".",
        storage_mutated,
    );
    const lock = durable_store.acquireCasAdvisoryLockObserved(
        fs,
        allocator,
        path,
        storage_mutated,
    ) catch |err| switch (err) {
        error.LockBusy => {
            if (try durable_store.casAdvisoryLockExists(fs, allocator, path)) return;
            return err;
        },
        else => return err,
    };
    lock.close(fs.io);
}

fn resolvePreparationSlots(
    allocator: std.mem.Allocator,
    store: *const storage.Plan,
    parameters: *const definition_core.parameters.Bindings,
) !storage.ResolvedPlan {
    var resolved = try storage.resolve(allocator, store, parameters);
    errdefer resolved.deinit(allocator);
    for (resolved.slotSlice()) |slot| {
        if (slot.isSegmented() or slot.owned_path != null) {
            return error.UnsupportedPreparationLayout;
        }
    }
    return resolved;
}

fn ArchiveVisitor(comptime Visitor: type) type {
    return struct {
        scope: *storage_root.Scope,
        allocator: std.mem.Allocator,
        visitor: Visitor,

        pub fn visit(self: *@This(), dependency: replay.Dependency) !void {
            const path = switch (dependency) {
                .definition_closure => |digest| try definition_archive.pathAlloc(
                    self.scope,
                    self.allocator,
                    ".",
                    digest,
                ),
                .revision => |revision| try revision_archive.pathAlloc(
                    self.scope,
                    self.allocator,
                    ".",
                    revision.digest,
                ),
            };
            defer self.allocator.free(path);
            try self.visitor.visit(FileDependency{
                .path = controlRelative(path),
                .max_bytes = switch (dependency) {
                    .definition_closure => definition_archive.max_bytes,
                    .revision => |revision| revision.max_bytes,
                },
                .identity = switch (dependency) {
                    .definition_closure => |digest| .{ .definition_closure = digest },
                    .revision => |revision| .{ .content = revision.digest },
                },
            });
        }
    };
}

fn controlRelative(path: []const u8) []const u8 {
    var remaining = path;
    while (std.mem.startsWith(u8, remaining, "./")) remaining = remaining[2..];
    return remaining;
}

pub fn captureControlFile(
    source: *const storage_root.SourceRoot,
    relative_path: []const u8,
    destination: *std.Io.Writer,
    max_bytes: u64,
    scratch: []u8,
) !storage_capture.Result {
    const file = try source.openControlFile(relative_path);
    defer file.close(source.io);
    if ((try file.stat(source.io)).size > max_bytes) return error.CaptureLimitExceeded;
    var reader = file.reader(source.io, &.{});
    return storage_capture.copy(&reader.interface, destination, max_bytes, scratch) catch |err| {
        if (err == error.ReadFailed) return reader.err orelse err;
        return err;
    };
}

pub const Restoration = struct {
    candidate: custody.SlotSnapshot,
    binding_path: []u8,
    records_validated: usize,
    max_bytes: usize,

    pub fn deinit(self: *Restoration, allocator: std.mem.Allocator) void {
        self.candidate.deinit(allocator);
        allocator.free(self.binding_path);
        self.* = undefined;
    }

    pub fn releaseForPublication(self: *Restoration) [2]durable_store.TransactionMutation {
        if (self.candidate.read_custody) |*read_custody| read_custody.deinit();
        self.candidate.read_custody = null;
        return .{
            .{
                .path = self.candidate.path,
                .text = self.candidate.content,
                .expectation = .{ .expected_exists = false },
                .content_mode = .raw,
                .max_bytes = self.max_bytes,
                .expected_digest_after = self.candidate.revision,
            },
            .{
                .path = self.binding_path,
                .text = "",
                .expectation = .{
                    .expected_exists = true,
                    .expected_digest = self.candidate.binding.digest.?,
                },
                .content_mode = .raw,
                .max_bytes = custody.binding_max_bytes,
                .action = .check_only,
            },
        };
    }
};

pub fn inspectRestoration(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    repo_root: []const u8,
    slot: storage.ResolvedSlot,
    parameters: *const definition_core.parameters.Bindings,
    candidate_bytes: []const u8,
    protocol_required: bool,
) !Restoration {
    var restoration = try readRestorationCandidate(
        scope,
        allocator,
        definition_plan.id,
        repo_root,
        slot,
        candidate_bytes,
    );
    errdefer restoration.deinit(allocator);
    var stats = try replay.validateSlot(
        scope,
        allocator,
        repo_root,
        definition_plan.id,
        slot,
        &restoration.candidate,
        parameters,
        definition_plan.bounds.max_records,
        protocol_required,
    );
    defer stats.deinit(allocator);
    restoration.records_validated = stats.records_validated;
    return restoration;
}

fn readRestorationCandidate(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    definition_id: []const u8,
    repo_root: []const u8,
    slot: storage.ResolvedSlot,
    candidate_bytes: []const u8,
) !Restoration {
    if (!storage_root.validRepoRoot(scope, repo_root)) return error.RepositoryRootNotAbsolute;
    if (slot.isSegmented() or slot.owned_path != null) {
        return error.UnsupportedPreparationLayout;
    }
    if (candidate_bytes.len > slot.max_bytes) return error.FileTooBig;
    const path = try std.fs.path.join(
        allocator,
        &.{ repo_root, storage_root.controlComponent(scope), slot.relative_path },
    );
    errdefer allocator.free(path);
    const binding_path = try custody.bindingPathAlloc(
        scope,
        allocator,
        repo_root,
        slot.relative_path,
    );
    errdefer allocator.free(binding_path);
    var read_custody = try durable_store.acquireCasReadLockPair(
        scope.fs,
        allocator,
        path,
        binding_path,
    );
    errdefer read_custody.deinit();
    if (read_custody.count != 2) return error.PreparationSourceUncoordinated;
    try requireAbsentSlot(scope, path);
    const content = try allocator.dupe(u8, candidate_bytes);
    errdefer allocator.free(content);
    const revision = try definition_core.canonical_json.digestBytesAlloc(allocator, content);
    errdefer allocator.free(revision);
    var binding = try custody.readBindingSnapshot(
        scope,
        allocator,
        binding_path,
        definition_id,
        slot.name,
        slot.relative_path,
        revision,
        null,
    );
    errdefer binding.deinit(allocator);
    if (!binding.exists) return error.RestorationBindingMissing;
    const candidate = custody.SlotSnapshot{
        .exists = false,
        .path = path,
        .content = content,
        .revision = revision,
        .binding = binding,
        .read_custody = read_custody,
    };
    return .{
        .candidate = candidate,
        .binding_path = binding_path,
        .records_validated = 0,
        .max_bytes = slot.max_bytes,
    };
}

fn requireAbsentSlot(scope: *storage_root.Scope, path: []const u8) !void {
    try durable_store.rejectSymlinkComponents(scope.fs, path);
    _ = scope.fs.directory().statFile(
        scope.fs.io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    return error.RestorationTargetPresent;
}

test "history coverage preserves binding authority and complete record boundaries" {
    const absent: HistorySlot = .{ .exists = false };
    const raw: HistorySlot = .{ .exists = true, .content = "a" };
    const extension: HistorySlot = .{ .exists = true, .content = "a \r\nb\n" };
    const partial: HistorySlot = .{ .exists = true, .content = "ab\n" };
    try std.testing.expect(coversHistorySlot(.event_log, extension, raw));
    try std.testing.expect(!coversHistorySlot(.event_log, partial, raw));
    try std.testing.expect(!coversHistorySlot(.document, extension, raw));
    try std.testing.expect(coversHistorySlot(.document, raw, raw));
    try std.testing.expect(coversHistorySlot(.event_log, raw, absent));
    try std.testing.expect(!coversHistorySlot(.event_log, absent, raw));
    const bound: HistorySlot = .{
        .exists = true,
        .content = "a",
        .binding_bytes = "old\n",
        .binding_rows = 1,
    };
    const successor: HistorySlot = .{
        .exists = true,
        .content = "replacement",
        .binding_bytes = "old\nnew\n",
        .binding_rows = 2,
    };
    try std.testing.expect(coversHistorySlot(.document, successor, bound));
    try std.testing.expect(!coversHistorySlot(.event_log, raw, bound));
    try std.testing.expect(coversHistorySlot(.event_log, bound, raw));
    var same_rows = bound;
    same_rows.content = "different";
    try std.testing.expect(!coversHistorySlot(.document, same_rows, bound));
    var divergent = successor;
    divergent.binding_bytes = "other\nnew\n";
    try std.testing.expect(!coversHistorySlot(.document, divergent, bound));
}
