const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const storage_root = @import("storage_root");
const bundle = @import("storage_bundle.zig");
const preparation = @import("storage_preparation.zig");
const sources = @import("storage_sources.zig");
const definition = @import("definition.zig");
const definition_archive = @import("definition_archive.zig");
const revision_archive = @import("revision_archive.zig");
const custody = @import("custody.zig");
const storage = @import("storage.zig");
const protocol = @import("protocol.zig");
const replay = @import("replay.zig");
const validation = @import("validation.zig");
const transaction = @import("transaction.zig");
const doctor = @import("doctor.zig");
const projection = @import("projection.zig");

pub const File = struct {
    path: []const u8,
    content: ?[]const u8,
    content_id: ?[]const u8,
    class: durable_store.ReservationTargetClass,
};

pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    identity: []const u8,
    bundle_identity: []const u8,
    definition_digest: []const u8,
    context_digest: ?[]const u8 = null,
    target: bundle.Target,
    files: []const File,
    records_validated: usize,

    pub fn deinit(self: *Candidate) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const InspectionSlot = struct {
    name: []const u8,
    relative_path: []const u8,
    kind: storage.SlotKind,
    codec: definition.Codec,
    layout: storage.SlotLayout,
};

pub const SourceHistory = struct {
    source_id: []const u8,
    history: []const preparation.HistorySlot,
};

pub const Inspection = struct {
    arena: std.heap.ArenaAllocator,
    captured: *const bundle.Captured,
    definition_id: []const u8,
    definition_digest: []const u8,
    definition_entry_path: []const u8,
    parameter_digest: []const u8,
    slots: []const InspectionSlot,
    primary_history: []const preparation.HistorySlot,
    sources: []const SourceHistory,

    pub fn deinit(self: *Inspection) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn covers(
        self: *const Inspection,
        cover_history: []const preparation.HistorySlot,
        other: *const Inspection,
        source_history: []const preparation.HistorySlot,
    ) !bool {
        if (!std.mem.eql(u8, self.definition_id, other.definition_id) or
            !std.mem.eql(u8, self.definition_digest, other.definition_digest) or
            !std.mem.eql(u8, self.definition_entry_path, other.definition_entry_path) or
            !std.mem.eql(u8, self.parameter_digest, other.parameter_digest) or
            self.slots.len != other.slots.len or cover_history.len != self.slots.len or
            source_history.len != other.slots.len)
        {
            return error.PreparationDefinitionMismatch;
        }
        for (self.slots, other.slots) |left, right| {
            if (!std.mem.eql(u8, left.name, right.name) or
                !std.mem.eql(u8, left.relative_path, right.relative_path) or
                left.kind != right.kind or left.codec != right.codec or left.layout != right.layout)
            {
                return error.PreparationDefinitionMismatch;
            }
        }
        for (self.slots, cover_history, source_history) |slot, cover, source| {
            if (!preparation.coversHistorySlot(slot.kind, cover, source)) return false;
        }
        return true;
    }
};

pub const Options = struct {
    limits: bundle.Limits,
    context_digest: ?[]const u8 = null,
    binding_operation: ?[]const u8 = null,
    expected_projection: ?ExpectedProjection = null,
};

pub const ApplyOptions = struct {
    publication: bundle.PublishOptions,
    binding_operation: ?[]const u8 = null,
};

pub const ExpectedProjection = struct {
    name: []const u8,
    payload: []const u8,
    exit_code: u8,
};

pub const InstallOptions = struct {
    publication: bundle.PublishOptions,
    context_digest: ?[]const u8 = null,
    binding_operation: ?[]const u8 = null,
    expected_projection: ExpectedProjection,
};

pub fn installationCharge(
    allocator: std.mem.Allocator,
    artifact: *const definition.Plan,
    store: *const storage.Plan,
    parameters: *const definition_core.parameters.Bindings,
    target: bundle.Target,
    limits: bundle.Limits,
) !durable_store.ReservationCharge {
    var resolved = try storage.resolve(allocator, store, parameters);
    defer resolved.deinit(allocator);
    var event_protocol = try protocol.compile(allocator, artifact, store);
    defer if (event_protocol) |*plan| plan.deinit(allocator);
    var generated: u64 = 0;
    for (resolved.slotSlice(), 0..) |slot, index| {
        if (slot.isSegmented() or slot.owned_path != null) {
            return error.UnsupportedPreparationLayout;
        }
        var maximum: u64 = 0;
        for (store.operations) |*operation| {
            _ = preparation.selectBindingOperation(store, @intCast(index), operation) catch
                continue;
            const bound = transaction.unboundBindingSizeBound(
                allocator,
                artifact,
                slot,
                operation.name,
                parameters,
                if (event_protocol) |*plan| plan else null,
                @intCast(index),
            ) catch |err| switch (err) {
                error.ReplayParameterMissing => continue,
                error.StoreBindingTooLarge => custody.binding_max_bytes,
                else => return err,
            };
            maximum = @max(maximum, bound);
        }
        generated = try std.math.add(u64, generated, maximum);
    }
    const receipt = try renderPreparationReceipt(
        allocator,
        &artifact.closure_digest,
        &artifact.closure_digest,
        target,
        &artifact.closure_digest,
    );
    defer allocator.free(receipt);
    const metadata = try std.math.add(
        u64,
        try std.math.add(u64, limits.payload_bytes, limits.manifest_bytes),
        try std.math.add(u64, generated, receipt.len),
    );
    return durable_store.ReservationBudget.transactionCharge(
        try std.math.add(u64, metadata, limits.payload_bytes),
        metadata,
    );
}

pub const InstallationState = union(enum) {
    ready: durable_store.ReservationReceipt,
    terminal: bundle.Published,
};

pub fn resumeInstallation(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    parameters: *const definition_core.parameters.Bindings,
    options: InstallOptions,
    reservation: *bundle.Reservation,
) !?bundle.Published {
    if (options.publication.preparation != null) return error.PreparationSourceCoordinated;
    try reservation.validate(target, options.publication);
    const fs = target.scope().?.fs;
    const receipt = options.publication.budget.reconcile(
        allocator,
        fs,
        reservation.request,
        options.publication.free_space,
    ) catch |err| switch (err) {
        error.ReservationUnbound => return null,
        else => return err,
    };
    if (receipt.semantic == .recovery_required or receipt.accounting_error != null) {
        return .{ .receipt = receipt };
    }
    if (receipt.semantic == .aborted and receipt.accounting_error == null) {
        defer receipt.transaction.deinit(allocator);
        reservation.receipt = try options.publication.budget.restartAborted(
            allocator,
            fs,
            reservation.request,
            options.publication.free_space,
        );
        return null;
    }
    var result: bundle.Published = .{ .receipt = receipt };
    if (receipt.semantic == .committed) {
        verifyResumedInstallation(
            allocator,
            target,
            parameters,
            options,
            reservation,
            receipt,
        ) catch |err| {
            result.verification_error = err;
        };
    }
    return result;
}

const PreparationReceipt = struct {
    parsed: std.json.Parsed(std.json.Value),
    bundle_identity: []const u8,
    admission_identity: []const u8,
    target: bundle.Target,
    context_digest: ?[]const u8,

    fn deinit(self: *PreparationReceipt) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

fn verifyResumedInstallation(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    parameters: *const definition_core.parameters.Bindings,
    options: InstallOptions,
    reservation: *const bundle.Reservation,
    receipt: durable_store.ReservedTransactionReceipt,
) !void {
    const path = try resumedReceiptPath(allocator, target, receipt);
    defer allocator.free(path);
    var recorded = try readPreparationReceipt(
        allocator,
        target,
        path,
        options.publication.limits.manifest_bytes,
    );
    defer recorded.deinit();
    var captured = try bundle.loadPublished(
        allocator,
        target,
        recorded.bundle_identity,
        options.publication.limits,
    );
    defer captured.deinit();
    var candidate = try prepare(allocator, &captured, parameters, .{
        .limits = options.publication.limits,
        .context_digest = options.context_digest,
        .binding_operation = options.binding_operation,
        .expected_projection = options.expected_projection,
    });
    defer candidate.deinit();
    try authenticateResumedCandidate(allocator, target, reservation, receipt, recorded, &candidate);
    var active = try Publication.init(allocator, target, &candidate);
    defer active.deinit();
    var preservation = try bundle.Publication.init(
        allocator,
        target,
        &captured,
        options.publication.limits,
    );
    defer preservation.deinit();
    const result = finishInstallation(
        &active,
        &preservation,
        parameters,
        options.expected_projection,
        receipt,
    );
    if (result.verification_error) |err| return err;
}

fn resumedReceiptPath(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    receipt: durable_store.ReservedTransactionReceipt,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const scope = target.scope() orelse return error.StorageRootMissing;
    const control = try storage_root.controlPathAlloc(&scope, temporary, ".");
    var dependencies = try durable_store.inspectTransactionDependencies(
        scope.fs,
        allocator,
        receipt.transaction.transaction_dir,
    );
    defer dependencies.deinit(allocator);
    const directory = try std.fs.path.join(temporary, &.{ control, ".preparations" });
    var found: ?[]const u8 = null;
    for (dependencies.entries) |entry| {
        if (entry.kind != .target) continue;
        const parent = std.fs.path.dirname(entry.path) orelse continue;
        if (!std.mem.eql(u8, parent, directory)) continue;
        const leaf = std.fs.path.basename(entry.path);
        if (leaf.len != 69 or !std.mem.endsWith(u8, leaf, ".json")) {
            return error.InvalidPreparationReceipt;
        }
        const identity = try temporary.print("sha256:{s}", .{leaf[0..64]});
        try definition_core.json.digest(identity);
        if (found != null) return error.InvalidPreparationReceipt;
        found = leaf;
    }
    return std.fs.path.join(allocator, &.{ ".preparations", found orelse
        return error.PreparationPublicationIncomplete });
}

fn readPreparationReceipt(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    path: []const u8,
    maximum: usize,
) !PreparationReceipt {
    const file = try target.openControlFile(path);
    defer file.close(target.io);
    var reader = file.reader(target.io, &.{});
    reader.mode = .positional_simple;
    const bytes = try reader.interface.allocRemaining(allocator, .limited(maximum));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    errdefer parsed.deinit();
    const json = definition_core.json;
    const root = try json.object(parsed.value);
    const required = [_][]const u8{ "schema", "bundle_identity", "admission_identity", "target" };
    const allowed = required ++ [_][]const u8{"context_digest"};
    try json.requireExactKeys(root, &allowed);
    try json.requireFields(root, &required);
    if (!std.mem.eql(u8, try json.requiredString(root, "schema"), "ledger-preparation-commit/v1")) {
        return error.InvalidPreparationReceipt;
    }
    const bundle_identity = try json.requiredString(root, "bundle_identity");
    const admission_identity = try json.requiredString(root, "admission_identity");
    const context_digest = try json.optionalString(root, "context_digest");
    try json.digest(bundle_identity);
    try json.digest(admission_identity);
    if (context_digest) |digest| try json.digest(digest);
    const leaf = std.fs.path.basename(path);
    if (!std.mem.eql(u8, leaf[0..64], admission_identity[7..])) {
        return error.InvalidPreparationReceipt;
    }
    const destination = try json.object(try json.field(root, "target"));
    const target_keys = &.{ "store_id", "generation" };
    try json.requireExactKeys(destination, target_keys);
    try json.requireFields(destination, target_keys);
    return .{
        .parsed = parsed,
        .bundle_identity = bundle_identity,
        .admission_identity = admission_identity,
        .context_digest = context_digest,
        .target = .{
            .store_id = try json.requiredString(destination, "store_id"),
            .generation = try json.requiredString(destination, "generation"),
        },
    };
}

fn authenticateResumedCandidate(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    reservation: *const bundle.Reservation,
    receipt: durable_store.ReservedTransactionReceipt,
    recorded: PreparationReceipt,
    candidate: *const Candidate,
) !void {
    if (!std.mem.eql(u8, recorded.admission_identity, candidate.identity) or
        !std.mem.eql(u8, recorded.target.store_id, candidate.target.store_id) or
        !std.mem.eql(u8, recorded.target.generation, candidate.target.generation) or
        !std.mem.eql(u8, candidate.target.store_id, reservation.request.store_id))
    {
        return error.ReservationIdentityMismatch;
    }
    if ((recorded.context_digest == null) != (candidate.context_digest == null)) {
        return error.ReservationIdentityMismatch;
    }
    if (recorded.context_digest) |digest| {
        if (!std.mem.eql(u8, digest, candidate.context_digest.?)) {
            return error.ReservationIdentityMismatch;
        }
    }
    var identity: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(candidate.identity, &identity, .{});
    const authenticated = (try reservation.budget.observedPublication(
        allocator,
        target.scope().?.fs,
        reservation.request,
        identity,
    )) orelse return error.ReservationRecoveryRequired;
    defer authenticated.transaction.deinit(allocator);
    if (authenticated.semantic != .committed or !std.mem.eql(
        u8,
        authenticated.transaction.transaction_id,
        receipt.transaction.transaction_id,
    )) return error.ReservationIdentityMismatch;
}

pub fn reconcileCaptured(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    captured: *const bundle.Captured,
    parameters: *const definition_core.parameters.Bindings,
    options: InstallOptions,
    reservation: *const bundle.Reservation,
) !InstallationState {
    if (options.publication.preparation != null) return error.PreparationSourceCoordinated;
    var candidate = try prepare(allocator, captured, parameters, .{
        .limits = options.publication.limits,
        .context_digest = options.context_digest,
        .binding_operation = options.binding_operation,
        .expected_projection = options.expected_projection,
    });
    defer candidate.deinit();
    var active = try Publication.init(allocator, target, &candidate);
    defer active.deinit();
    var preservation = try bundle.Publication.init(
        allocator,
        target,
        captured,
        options.publication.limits,
    );
    defer preservation.deinit();
    var identity: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(candidate.identity, &identity, .{});
    return switch (try reservation.beginPublication(
        allocator,
        target,
        options.publication,
        identity,
    )) {
        .ready => |receipt| .{ .ready = receipt },
        .terminal => |receipt| .{ .terminal = finishInstallation(
            &active,
            &preservation,
            parameters,
            options.expected_projection,
            receipt,
        ) },
    };
}

pub fn installCaptured(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    captured: *const bundle.Captured,
    parameters: *const definition_core.parameters.Bindings,
    options: InstallOptions,
    reservation: *const bundle.Reservation,
) !bundle.Published {
    var candidate = try prepare(allocator, captured, parameters, .{
        .limits = options.publication.limits,
        .context_digest = options.context_digest,
        .binding_operation = options.binding_operation,
        .expected_projection = options.expected_projection,
    });
    defer candidate.deinit();
    var active = try Publication.init(allocator, target, &candidate);
    defer active.deinit();
    var preservation = try bundle.Publication.init(
        allocator,
        target,
        captured,
        options.publication.limits,
    );
    defer preservation.deinit();
    var identity: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(candidate.identity, &identity, .{});
    const receipt = switch (try reservation.beginPublication(
        allocator,
        target,
        options.publication,
        identity,
    )) {
        .terminal => |receipt| receipt,
        .ready => |ready| try active.commitInstallation(
            &preservation,
            reservation,
            ready,
            identity,
            options.publication,
        ),
    };
    return finishInstallation(
        &active,
        &preservation,
        parameters,
        options.expected_projection,
        receipt,
    );
}

fn finishInstallation(
    active: *Publication,
    preservation: *bundle.Publication,
    parameters: *const definition_core.parameters.Bindings,
    expected: ExpectedProjection,
    receipt: durable_store.ReservedTransactionReceipt,
) bundle.Published {
    var result = active.finish(receipt);
    if (receipt.semantic == .committed) {
        preservation.verify() catch |err| {
            if (result.verification_error == null) result.verification_error = err;
        };
        validatePublishedHistory(
            active.scratch,
            active.target,
            active.candidate,
            parameters,
            expected,
        ) catch |err| {
            if (result.verification_error == null) result.verification_error = err;
        };
    }
    return result;
}

pub fn applyPublished(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    identity: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    options: ApplyOptions,
) !bundle.Published {
    var captured = try bundle.loadPublished(
        allocator,
        target,
        identity,
        options.publication.limits,
    );
    defer captured.deinit();
    var candidate = try prepare(allocator, &captured, parameters, .{
        .limits = options.publication.limits,
        .binding_operation = options.binding_operation,
    });
    defer candidate.deinit();
    const store_id = target.store_id orelse return error.UnmanagedBundleTarget;
    if (!std.mem.eql(u8, store_id, candidate.target.store_id)) return error.BundleIdentityMismatch;
    var publication = try Publication.init(allocator, target, &candidate);
    defer publication.deinit();
    var result = try publication.commit(options.publication);
    if (result.receipt.semantic == .committed and result.verification_error == null) {
        validatePublishedHistory(allocator, target, &candidate, parameters, null) catch |err| {
            result.verification_error = err;
        };
    }
    return result;
}

fn validatePublishedHistory(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    candidate: *const Candidate,
    parameters: *const definition_core.parameters.Bindings,
    expected: ?ExpectedProjection,
) !void {
    var scope = target.scope() orelse return error.StorageRootMissing;
    var archived = try definition_archive.load(
        &scope,
        allocator,
        ".",
        candidate.definition_digest,
    );
    defer archived.deinit(allocator);
    var plans = try Plans.init(allocator, &archived, parameters, null);
    defer plans.deinit(allocator);
    var result = try doctor.execute(
        &scope,
        allocator,
        &plans.artifact,
        &plans.store,
        if (plans.event_protocol) |*plan| plan else null,
        ".",
        parameters,
    );
    defer result.deinit(allocator);
    if (!result.healthy) return error.PreparationPublishedHistoryUnhealthy;
    if (expected) |selected| {
        try verifyExpectedProjection(&scope, allocator, &plans, parameters, selected);
    }
    try target.revalidateControl();
}

fn verifyExpectedProjection(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    plans: *Plans,
    parameters: *const definition_core.parameters.Bindings,
    expected: ExpectedProjection,
) !void {
    var compiled = try compileExpectedProjection(allocator, plans, expected);
    defer compiled.deinit(allocator);
    var actual = try projection.execute(
        scope,
        allocator,
        &plans.artifact,
        &plans.store,
        if (plans.event_protocol) |*plan| plan else null,
        &compiled,
        expected.name,
        ".",
        parameters,
    );
    defer actual.deinit(allocator);
    if (actual.exit_code != expected.exit_code or
        !std.mem.eql(u8, actual.payload, expected.payload))
    {
        return error.PreparationProjectionMismatch;
    }
}

fn compileExpectedProjection(
    allocator: std.mem.Allocator,
    plans: *Plans,
    expected: ExpectedProjection,
) !projection.Plan {
    return compileExpected(
        allocator,
        &plans.artifact,
        &plans.store,
        if (plans.event_protocol) |*plan| plan else null,
        expected,
    );
}

pub fn validateExpectedProjection(
    allocator: std.mem.Allocator,
    artifact: *const definition.Plan,
    store: *const storage.Plan,
    expected: ExpectedProjection,
) !void {
    var event_protocol = try protocol.compile(allocator, artifact, store);
    defer if (event_protocol) |*plan| plan.deinit(allocator);
    var compiled = try compileExpected(
        allocator,
        artifact,
        store,
        if (event_protocol) |*plan| plan else null,
        expected,
    );
    compiled.deinit(allocator);
}

fn compileExpected(
    allocator: std.mem.Allocator,
    artifact: *const definition.Plan,
    store: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
    expected: ExpectedProjection,
) !projection.Plan {
    if (expected.payload.len > artifact.bounds.max_output_bytes) {
        return error.ProjectionOutputTooLarge;
    }
    var compiled = try projection.compile(
        allocator,
        artifact,
        store,
        event_protocol,
    );
    errdefer compiled.deinit(allocator);
    _ = compiled.find(expected.name) orelse return error.UnknownProjection;
    return compiled;
}

const Publication = struct {
    arena: std.heap.ArenaAllocator,
    scratch: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    candidate: *const Candidate,
    control_path: []const u8,
    transactions_path: []const u8,
    receipt_file: File,
    mutations: std.ArrayList(durable_store.TransactionMutation) = .empty,
    classes: std.ArrayList(durable_store.ReservationTargetClassification) = .empty,

    fn commitInstallation(
        self: *Publication,
        preservation: *bundle.Publication,
        reservation: *const bundle.Reservation,
        ready: durable_store.ReservationReceipt,
        identity: [32]u8,
        configuration: bundle.PublishOptions,
    ) !durable_store.ReservedTransactionReceipt {
        try self.plan();
        try preservation.planWrites();
        const owned = self.arena.allocator();
        try self.mutations.appendSlice(owned, preservation.mutations.items);
        try self.classes.append(owned, .{
            .path = preservation.manifest_target,
            .class = .metadata,
        });
        if (configuration.preparation) |held| try held.include(owned, &self.mutations);
        return configuration.budget.commitReserved(
            self.scratch,
            self.target.scope().?.fs,
            self.transactions_path,
            self.mutations.items,
            .{
                .request = reservation.request,
                .reservation = ready,
                .free_space = configuration.free_space,
                .target_classes = self.classes.items,
                .transaction = .{ .owner = configuration.owner },
                .custody = if (configuration.preparation) |held| try held.nativeCustody() else null,
                .publication_identity = identity,
            },
        );
    }

    fn commit(self: *Publication, configuration: bundle.PublishOptions) !bundle.Published {
        const allocator = self.scratch;
        const scope = self.target.scope() orelse return error.StorageRootMissing;
        const request: durable_store.ReservationRequest = .{
            .budget_id = configuration.budget_id,
            .store_id = self.candidate.target.store_id,
            .operation_id = self.candidate.identity,
            .charge = try self.charge(),
        };
        const prior = if (configuration.preparation != null)
            try configuration.budget.observedOutcome(allocator, scope.fs, request)
        else
            configuration.budget.reconcile(
                allocator,
                scope.fs,
                request,
                configuration.free_space,
            ) catch |err| switch (err) {
                error.ReservationNotFound, error.ReservationUnbound => null,
                else => return err,
            };
        if (prior) |receipt| {
            if (receipt.semantic != .aborted or receipt.accounting_error != null or
                configuration.preparation != null)
            {
                return self.finish(receipt);
            }
        }
        defer if (prior) |receipt| {
            var owned = receipt;
            owned.transaction.deinit(allocator);
        };
        try self.plan();
        if (configuration.preparation) |held| {
            try held.include(self.arena.allocator(), &self.mutations);
        }
        const reserved = if (prior != null)
            try configuration.budget.restartAborted(
                allocator,
                scope.fs,
                request,
                configuration.free_space,
            )
        else
            try configuration.budget.reserve(allocator, request, configuration.free_space);
        const receipt = try configuration.budget.commitReserved(
            allocator,
            scope.fs,
            self.transactions_path,
            self.mutations.items,
            .{
                .request = request,
                .reservation = reserved,
                .free_space = configuration.free_space,
                .target_classes = self.classes.items,
                .transaction = .{ .owner = configuration.owner },
                .custody = if (configuration.preparation) |held| try held.nativeCustody() else null,
            },
        );
        return self.finish(receipt);
    }

    fn init(
        allocator: std.mem.Allocator,
        target: *const storage_root.SourceRoot,
        candidate: *const Candidate,
    ) !Publication {
        try target.revalidateControl();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const scope = target.scope() orelse return error.StorageRootMissing;
        const control_path = try storage_root.controlPathAlloc(&scope, owned, ".");
        const receipt = try renderPreparationReceipt(
            owned,
            candidate.bundle_identity,
            candidate.identity,
            candidate.target,
            candidate.context_digest,
        );
        const file: File = .{
            .path = try owned.print(".preparations/{s}.json", .{candidate.identity[7..]}),
            .content = receipt,
            .content_id = try definition_core.canonical_json.digestBytesAlloc(owned, receipt),
            .class = .metadata,
        };
        const transactions_path = try std.fs.path.join(owned, &.{ control_path, ".transactions" });
        return .{
            .arena = arena,
            .scratch = allocator,
            .target = target,
            .candidate = candidate,
            .control_path = control_path,
            .transactions_path = transactions_path,
            .receipt_file = file,
        };
    }

    fn deinit(self: *Publication) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn charge(self: *const Publication) !durable_store.ReservationCharge {
        var total: u64 = self.receipt_file.content.?.len;
        var metadata = total;
        for (self.candidate.files) |file| {
            const length = if (file.content) |bytes| bytes.len else 0;
            total = try std.math.add(u64, total, length);
            if (file.class == .metadata) metadata = try std.math.add(u64, metadata, length);
        }
        return durable_store.ReservationBudget.transactionCharge(total, metadata);
    }

    fn plan(self: *Publication) !void {
        for (self.candidate.files) |file| try self.planFile(file);
        try self.planFile(self.receipt_file);
    }

    fn planFile(self: *Publication, file: File) !void {
        const exists = try self.existingMatches(file);
        const path = try std.fs.path.join(
            self.arena.allocator(),
            &.{ self.control_path, file.path },
        );
        try self.classes.append(self.arena.allocator(), .{ .path = path, .class = file.class });
        try self.mutations.append(self.arena.allocator(), .{
            .path = path,
            .text = if (!exists) file.content orelse "" else "",
            .expectation = .{
                .expected_exists = exists,
                .expected_digest = if (exists) file.content_id else null,
            },
            .content_mode = .raw,
            .max_bytes = if (file.content) |bytes| bytes.len else 0,
            .action = if (exists or file.content == null) .check_only else .write,
            .expected_digest_after = file.content_id,
        });
    }

    fn existingMatches(self: *Publication, file: File) !bool {
        const opened = self.target.openControlFile(file.path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer opened.close(self.target.io);
        const expected = file.content orelse return error.PreparationReconciliationRequired;
        var reader = opened.reader(self.target.io, &.{});
        reader.mode = .positional_simple;
        const bytes = reader.interface.allocRemaining(
            self.scratch,
            .limited(expected.len),
        ) catch |err| {
            if (err == error.StreamTooLong) return error.PreparationReconciliationRequired;
            return err;
        };
        defer self.scratch.free(bytes);
        if (!std.mem.eql(u8, expected, bytes)) return error.PreparationReconciliationRequired;
        return true;
    }

    fn verify(self: *Publication) !void {
        try self.target.revalidateControl();
        for (self.candidate.files) |file| {
            if ((try self.existingMatches(file)) != (file.content != null)) {
                return error.PreparationPublicationIncomplete;
            }
        }
        if (!try self.existingMatches(self.receipt_file)) {
            return error.PreparationPublicationIncomplete;
        }
    }

    fn finish(
        self: *Publication,
        receipt: durable_store.ReservedTransactionReceipt,
    ) bundle.Published {
        var result: bundle.Published = .{ .receipt = receipt };
        if (receipt.semantic == .committed) {
            self.verify() catch |err| {
                result.verification_error = err;
            };
        }
        return result;
    }
};

fn renderPreparationReceipt(
    allocator: std.mem.Allocator,
    bundle_identity: []const u8,
    admission_identity: []const u8,
    target: bundle.Target,
    context_digest: ?[]const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ledger-preparation-commit/v1",
        .bundle_identity = bundle_identity,
        .admission_identity = admission_identity,
        .target = target,
        .context_digest = context_digest,
    }, .{ .emit_null_optional_fields = false });
}

pub fn prepare(
    allocator: std.mem.Allocator,
    captured: *const bundle.Captured,
    parameters: *const definition_core.parameters.Bindings,
    options: Options,
) !Candidate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var validated = try validateCaptured(
        allocator,
        arena.allocator(),
        captured,
        parameters,
        options,
        true,
    );
    defer validated.deinit();
    const description = validated.manifest.description;
    const files = try validated.builder.files.toOwnedSlice(arena.allocator());
    std.mem.sort(File, files, {}, fileLessThan);
    const owned_identity = try arena.allocator().dupe(u8, captured.identity);
    const target: bundle.Target = .{
        .store_id = try arena.allocator().dupe(u8, description.target.store_id),
        .generation = try arena.allocator().dupe(u8, description.target.generation),
    };
    const context_digest = if (options.context_digest) |value| context: {
        try definition_core.json.digest(value);
        break :context try arena.allocator().dupe(u8, value);
    } else null;
    const identity = try candidateIdentity(
        arena.allocator(),
        owned_identity,
        target,
        files,
        context_digest,
    );
    const definition_digest = try arena.allocator().dupe(u8, description.definition_digest);
    return .{
        .arena = arena,
        .identity = identity,
        .bundle_identity = owned_identity,
        .definition_digest = definition_digest,
        .context_digest = context_digest,
        .target = target,
        .files = files,
        .records_validated = validated.builder.records_validated,
    };
}

pub fn inspectCaptured(
    allocator: std.mem.Allocator,
    captured: *const bundle.Captured,
    parameters: *const definition_core.parameters.Bindings,
    options: Options,
) !Inspection {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var validated = try validateCaptured(
        allocator,
        arena.allocator(),
        captured,
        parameters,
        options,
        false,
    );
    defer validated.deinit();
    const description = validated.manifest.description;
    var inspection: Inspection = .{
        .arena = undefined,
        .captured = captured,
        .definition_id = try arena.allocator().dupe(u8, description.definition_id),
        .definition_digest = try arena.allocator().dupe(u8, description.definition_digest),
        .definition_entry_path = try arena.allocator().dupe(u8, description.definition_entry_path),
        .parameter_digest = try arena.allocator().dupe(u8, description.parameter_digest),
        .slots = validated.slots,
        .primary_history = try validated.builder.histories.toOwnedSlice(arena.allocator()),
        .sources = try validated.builder.source_histories.toOwnedSlice(arena.allocator()),
    };
    inspection.arena = arena;
    return inspection;
}

const Validated = struct {
    manifest: bundle.Manifest,
    builder: Builder,
    slots: []const InspectionSlot,

    fn deinit(self: *Validated) void {
        self.builder.deinit();
        self.manifest.deinit();
    }
};

fn validateCaptured(
    scratch: std.mem.Allocator,
    owned: std.mem.Allocator,
    captured: *const bundle.Captured,
    parameters: *const definition_core.parameters.Bindings,
    options: Options,
    retain_output: bool,
) !Validated {
    var manifest = try bundle.parse(scratch, captured.manifest, options.limits);
    errdefer manifest.deinit();
    const description = manifest.description;
    if (description.scope != .declared) return error.UnsupportedPreparationScope;
    if (!std.mem.eql(u8, manifest.digest, captured.identity) or
        !std.mem.eql(u8, description.parameter_digest, &parameters.values_digest))
    {
        return error.BundleIdentityMismatch;
    }
    if (!retain_output and description.sources.len == 0) return error.UnsupportedBundleLineage;
    var builder = try Builder.init(owned, scratch, captured, description);
    errdefer builder.deinit();
    builder.retain_output = retain_output;
    const path = try definition_archive.relativePathAlloc(scratch, description.definition_digest);
    defer scratch.free(path);
    const bytes = try builder.require(path, .metadata);
    var archived = try definition_archive.parse(scratch, bytes, description.definition_digest);
    defer archived.deinit(scratch);
    if (!std.mem.eql(u8, archived.definition_id, description.definition_id) or
        !std.mem.eql(u8, archived.entry_path, description.definition_entry_path))
    {
        return error.PreparationDefinitionMismatch;
    }
    var plans = try Plans.init(scratch, &archived, parameters, options.binding_operation);
    defer plans.deinit(scratch);
    if (options.expected_projection) |expected| {
        var compiled = try compileExpectedProjection(scratch, &plans, expected);
        compiled.deinit(scratch);
    }
    for (plans.resolved.slotSlice(), 0..) |slot, index| {
        try builder.admitSlot(&plans, parameters, slot, @intCast(index));
    }
    try builder.verifyOrigins(&plans, parameters, description.sources);
    return .{
        .manifest = manifest,
        .builder = builder,
        .slots = if (retain_output)
            &.{}
        else
            try inspectionSlots(owned, plans.resolved.slotSlice()),
    };
}

fn inspectionSlots(
    allocator: std.mem.Allocator,
    resolved: []const storage.ResolvedSlot,
) ![]const InspectionSlot {
    const slots = try allocator.alloc(InspectionSlot, resolved.len);
    for (resolved, slots) |slot, *copy| {
        copy.* = .{
            .name = try allocator.dupe(u8, slot.name),
            .relative_path = try allocator.dupe(u8, slot.relative_path),
            .kind = slot.kind,
            .codec = slot.codec,
            .layout = slot.layout,
        };
    }
    return slots;
}

const Plans = struct {
    artifact: definition.Plan,
    store: storage.Plan,
    resolved: storage.ResolvedPlan,
    law: validation.Plan,
    event_protocol: ?protocol.Plan,
    admission_name: ?[]const u8,

    fn init(
        allocator: std.mem.Allocator,
        archived: *const definition_archive.Loaded,
        parameters: *const definition_core.parameters.Bindings,
        admission_name: ?[]const u8,
    ) !Plans {
        var artifact = try definition.compile(allocator, &archived.closure, archived.entry_path);
        errdefer artifact.deinit(allocator);
        var store = try storage.compile(allocator, &artifact);
        errdefer store.deinit(allocator);
        var resolved = try storage.resolve(allocator, &store, parameters);
        errdefer resolved.deinit(allocator);
        for (resolved.slotSlice()) |slot| {
            if (slot.isSegmented() or slot.owned_path != null) {
                return error.UnsupportedPreparationLayout;
            }
        }
        var law = try validation.compile(allocator, &artifact);
        errdefer law.deinit(allocator);
        return .{
            .artifact = artifact,
            .store = store,
            .resolved = resolved,
            .law = law,
            .event_protocol = try protocol.compile(allocator, &artifact, &store),
            .admission_name = admission_name,
        };
    }

    fn deinit(self: *Plans, allocator: std.mem.Allocator) void {
        if (self.event_protocol) |*plan| plan.deinit(allocator);
        self.law.deinit(allocator);
        self.resolved.deinit(allocator);
        self.store.deinit(allocator);
        self.artifact.deinit(allocator);
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    captured: *const bundle.Captured,
    index: std.StringHashMap(usize),
    contents: std.StringHashMap([]const u8),
    files: std.ArrayList(File) = .empty,
    output: std.StringHashMapUnmanaged(usize) = .empty,
    records_validated: usize = 0,
    histories: std.ArrayList(preparation.HistorySlot) = .empty,
    source_histories: std.ArrayList(SourceHistory) = .empty,
    retain_output: bool = true,

    fn init(
        allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        captured: *const bundle.Captured,
        description: bundle.Description,
    ) !Builder {
        var builder = try initFiles(allocator, scratch, captured, description.files);
        errdefer builder.deinit();
        try bundle.verifyEvidence(scratch, description, builder.contents);
        return builder;
    }

    fn initFiles(
        allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        captured: *const bundle.Captured,
        descriptors: []const bundle.File,
    ) !Builder {
        if (descriptors.len != captured.files.len) return error.BundleIdentityMismatch;
        var index = std.StringHashMap(usize).init(scratch);
        errdefer index.deinit();
        var contents = std.StringHashMap([]const u8).init(scratch);
        errdefer contents.deinit();
        for (captured.files, 0..) |file, position| {
            const descriptor = try bundle.validateCapturedFile(scratch, descriptors, file);
            if ((try index.getOrPut(descriptor.path)).found_existing) {
                return error.BundleIdentityMismatch;
            }
            index.getPtr(descriptor.path).?.* = position;
            try contents.put(descriptor.content_id, file.content);
        }
        return .{
            .allocator = allocator,
            .scratch = scratch,
            .captured = captured,
            .index = index,
            .contents = contents,
        };
    }

    fn deinit(self: *Builder) void {
        self.index.deinit();
        self.contents.deinit();
    }

    fn verifyOrigins(
        self: *Builder,
        plans: *Plans,
        parameters: *const definition_core.parameters.Bindings,
        origins: []const bundle.SourceWitness,
    ) !void {
        for (origins) |origin| try self.verifyOrigin(plans, parameters, origin);
    }

    fn verifyOrigin(
        self: *Builder,
        plans: *Plans,
        parameters: *const definition_core.parameters.Bindings,
        origin: bundle.SourceWitness,
    ) !void {
        var arena = std.heap.ArenaAllocator.init(self.scratch);
        defer arena.deinit();
        const files = try arena.allocator().alloc(bundle.CapturedFile, origin.files.len);
        for (origin.files, files) |descriptor, *file| {
            file.* = .{
                .descriptor = descriptor,
                .content = self.contents.get(descriptor.content_id) orelse
                    return error.PreparationDependencyMissing,
            };
        }
        var captured = self.captured.*;
        captured.files = files;
        var builder = try initFiles(arena.allocator(), self.scratch, &captured, origin.files);
        defer builder.deinit();
        builder.retain_output = false;
        for (plans.resolved.slotSlice(), 0..) |slot, index| {
            try builder.admitSlot(plans, parameters, slot, @intCast(index));
            if (!preparation.coversHistorySlot(
                slot.kind,
                self.histories.items[index],
                builder.histories.items[index],
            )) return error.PreparationReconciliationRequired;
        }
        if (!self.retain_output) {
            try self.source_histories.append(self.allocator, .{
                .source_id = try self.allocator.dupe(u8, origin.subject.source_id),
                .history = try self.allocator.dupe(
                    preparation.HistorySlot,
                    builder.histories.items,
                ),
            });
        }
    }

    fn require(
        self: *Builder,
        path: []const u8,
        class: durable_store.ReservationTargetClass,
    ) ![]const u8 {
        const position = self.index.get(path) orelse return error.PreparationDependencyMissing;
        const bytes = self.captured.files[position].content;
        try self.add(path, bytes, class);
        return bytes;
    }

    fn add(
        self: *Builder,
        path: []const u8,
        content: ?[]const u8,
        class: durable_store.ReservationTargetClass,
    ) !void {
        if (!self.retain_output) return;
        if (self.output.get(path)) |index| {
            const existing = self.files.items[index];
            if (existing.class != class or (existing.content == null) != (content == null)) {
                return error.PreparationDependencyConflict;
            }
            if (content) |bytes| {
                if (!std.mem.eql(u8, existing.content.?, bytes)) {
                    return error.PreparationDependencyConflict;
                }
            }
            return;
        }
        const owned_path = try self.allocator.dupe(u8, path);
        try self.output.put(self.allocator, owned_path, self.files.items.len);
        try self.files.append(self.allocator, .{
            .path = owned_path,
            .content = if (content) |bytes| try self.allocator.dupe(u8, bytes) else null,
            .content_id = if (content) |bytes|
                try definition_core.canonical_json.digestBytesAlloc(self.allocator, bytes)
            else
                null,
            .class = class,
        });
    }

    fn admitSlot(
        self: *Builder,
        plans: *Plans,
        parameters: *const definition_core.parameters.Bindings,
        slot: storage.ResolvedSlot,
        slot_index: u16,
    ) !void {
        const binding_path = try custody.bindingRelativePathAlloc(self.scratch, slot.relative_path);
        defer self.scratch.free(binding_path);
        const binding_index = self.index.get(binding_path);
        const file_index = self.index.get(slot.relative_path) orelse {
            if (binding_index != null) return error.StoreBindingWithoutSlot;
            try self.histories.append(self.allocator, .{ .exists = false });
            try self.add(slot.relative_path, null, .payload);
            return self.add(binding_path, null, .metadata);
        };
        const bytes = self.captured.files[file_index].content;
        if (bytes.len > slot.max_bytes) return error.FileTooBig;
        const original_bindings = if (binding_index) |index|
            self.captured.files[index].content
        else
            null;
        const generated_bindings = if (original_bindings == null)
            try self.renderBinding(plans, parameters, slot, slot_index, bytes)
        else
            null;
        defer if (generated_bindings) |owned| self.scratch.free(owned);
        const bindings = original_bindings orelse generated_bindings.?;
        var snapshot = try capturedSnapshot(
            self.scratch,
            plans.artifact.id,
            slot,
            bytes,
            bindings,
        );
        defer snapshot.deinit(self.scratch);
        var stats = try replay.validateCapturedSlot(
            self.scratch,
            plans.artifact.id,
            slot,
            &snapshot.value,
            parameters,
            plans.artifact.bounds.max_records,
            if (plans.event_protocol) |plan| plan.target_slot_index == slot_index else false,
            .{ .context = self, .read = readDependency },
        );
        defer stats.deinit(self.scratch);
        self.records_validated = try std.math.add(
            usize,
            self.records_validated,
            stats.records_validated,
        );
        try self.histories.append(self.allocator, .{
            .exists = true,
            .content = bytes,
            .binding_bytes = original_bindings,
            .binding_rows = if (original_bindings != null) snapshot.value.binding.rows.len else 0,
        });
        try self.add(slot.relative_path, bytes, .payload);
        try self.add(binding_path, bindings, .metadata);
    }

    fn renderBinding(
        self: *Builder,
        plans: *Plans,
        parameters: *const definition_core.parameters.Bindings,
        slot: storage.ResolvedSlot,
        index: u16,
        content: []const u8,
    ) ![]u8 {
        const admission = if (plans.admission_name) |name|
            plans.store.findOperation(name) orelse return error.PreparationBindingOperationNotFound
        else
            null;
        const selected = try preparation.selectBindingOperation(&plans.store, index, admission);
        return transaction.renderUnboundBinding(
            self.scratch,
            &plans.artifact,
            &plans.law,
            selected.effect,
            slot,
            if (plans.event_protocol) |*plan| plan else null,
            selected.operation.name,
            content,
            parameters,
        );
    }

    fn readDependency(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        dependency: replay.Dependency,
    ) ![]u8 {
        const self: *Builder = @ptrCast(@alignCast(context.?));
        const path = switch (dependency) {
            .definition_closure => |digest| try definition_archive.relativePathAlloc(
                allocator,
                digest,
            ),
            .revision => |revision| try revision_archive.relativePathAlloc(
                allocator,
                revision.digest,
            ),
        };
        defer allocator.free(path);
        const content = try self.require(path, switch (dependency) {
            .definition_closure => .metadata,
            .revision => .payload,
        });
        return allocator.dupe(u8, content);
    }
};

const CapturedSnapshot = struct {
    value: custody.SlotSnapshot,

    fn deinit(self: *CapturedSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.value.revision);
        self.value.binding.deinit(allocator);
        self.* = undefined;
    }
};

fn capturedSnapshot(
    allocator: std.mem.Allocator,
    definition_id: []const u8,
    slot: storage.ResolvedSlot,
    bytes: []const u8,
    bindings: []const u8,
) !CapturedSnapshot {
    const revision = try definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
    errdefer allocator.free(revision);
    return .{ .value = .{
        .exists = true,
        .path = @constCast(slot.relative_path),
        .content = @constCast(bytes),
        .revision = revision,
        .binding = try custody.parseBindingSnapshot(
            allocator,
            bindings,
            definition_id,
            slot.name,
            slot.relative_path,
            revision,
        ),
    } };
}

fn fileLessThan(_: void, left: File, right: File) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

pub fn candidateIdentity(
    allocator: std.mem.Allocator,
    bundle_identity: []const u8,
    target: bundle.Target,
    files: []const File,
    context_digest: ?[]const u8,
) ![]u8 {
    if (context_digest) |digest| try definition_core.json.digest(digest);
    const Descriptor = struct {
        path: []const u8,
        content_id: ?[]const u8,
        bytes: usize,
        class: durable_store.ReservationTargetClass,
    };
    const descriptors = try allocator.alloc(Descriptor, files.len);
    defer allocator.free(descriptors);
    for (files, descriptors) |file, *descriptor| {
        descriptor.* = .{
            .path = file.path,
            .content_id = file.content_id,
            .bytes = if (file.content) |bytes| bytes.len else 0,
            .class = file.class,
        };
    }
    const encoded = if (context_digest) |context| try std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ledger-preparation-admission/v1",
        .bundle_identity = bundle_identity,
        .target = target,
        .files = descriptors,
        .context_digest = context,
    }, .{}) else try std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ledger-preparation-admission/v1",
        .bundle_identity = bundle_identity,
        .target = target,
        .files = descriptors,
    }, .{});
    defer allocator.free(encoded);
    return definition_core.canonical_json.digestBytesAlloc(allocator, encoded);
}
