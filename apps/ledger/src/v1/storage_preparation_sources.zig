const std = @import("std");
const durable_store = @import("durable_store");
const storage_root = @import("storage_root");
const definition_core = @import("definition_core");
const definition = @import("definition.zig");
const storage = @import("storage.zig");
const sources = @import("storage_sources.zig");
const admission = @import("storage_source_admission.zig");
const preparation = @import("storage_preparation.zig");
const bundle = @import("storage_bundle.zig");
const transport = @import("storage_transport.zig");
const installation = @import("storage_admission.zig");

pub const Budget = struct {
    source_id: []const u8,
    context: preparation.BudgetContext,
};

pub const Limits = struct {
    bundle: bundle.Limits,
    evidence_bytes: usize,
    snapshot_bytes: usize,
    capture_bytes: u64,
};

pub const Options = struct {
    closure: *const definition_core.Closure,
    entry_path: []const u8,
    target: bundle.Target,
    limits: Limits,
    budgets: []const Budget = &.{},
    established_source_id: ?[]const u8 = null,
    binding_operation: ?[]const u8 = null,
};

pub const Work = struct {
    evidence_bytes: usize = 0,
    snapshot_bytes: usize = 0,
    captured_bytes: u64 = 0,
};

pub const ReservedOptions = struct {
    sources: Options,
    publication: bundle.PublishOptions,
    operation_id: []const u8,
    action: enum { preserve, install } = .preserve,
};

pub fn install(
    allocator: std.mem.Allocator,
    io: std.Io,
    manifest: []const u8,
    parameters: *const definition_core.parameters.Bindings,
    target: *const storage_root.SourceRoot,
    options: ReservedOptions,
    expected: installation.ExpectedProjection,
) !bundle.Published {
    if (options.action != .install) return error.PreparationActionMismatch;
    try validateReservationOptions(target, options);
    var plan = try sources.parseWithLimits(
        allocator,
        manifest,
        sourceLimits(options.sources.limits),
    );
    defer plan.deinit();
    if (plan.sources.len == 0) return error.NoPreparationSources;
    _ = try validateOptions(plan.sources, options.sources);
    var artifact = try definition.compile(
        allocator,
        options.sources.closure,
        options.sources.entry_path,
    );
    defer artifact.deinit(allocator);
    var store = try storage.compile(allocator, &artifact);
    defer store.deinit(allocator);
    installation.validateExpectedProjection(allocator, &artifact, &store, expected) catch |err| {
        return failedExpectedProjection(
            allocator,
            target,
            &artifact,
            &store,
            parameters,
            options,
            err,
        );
    };
    const context = try installationContext(allocator, plan.sources, parameters, options.sources);
    defer allocator.free(context);
    var pending: PendingReservation = .{ .target = target, .options = options };
    try pending.acquire(allocator, &artifact, &store, parameters);
    defer pending.value.?.deinit();
    const configuration: installation.InstallOptions = .{
        .publication = options.publication,
        .binding_operation = options.sources.binding_operation,
        .expected_projection = expected,
        .context_digest = context,
    };
    if (try installation.resumeInstallation(
        allocator,
        target,
        parameters,
        configuration,
        &pending.value.?,
    )) |result| return result;
    try pending.value.?.associateSource(allocator, target, options.publication);
    var held = try Reserved.open(allocator, io, manifest, parameters, target, options);
    defer held.deinit();
    return held.install(target, parameters, configuration);
}

fn failedExpectedProjection(
    allocator: std.mem.Allocator,
    target: *const storage_root.SourceRoot,
    artifact: *const definition.Plan,
    store: *const storage.Plan,
    parameters: *const definition_core.parameters.Bindings,
    options: ReservedOptions,
    failure: anyerror,
) !bundle.Published {
    const request: durable_store.ReservationRequest = .{
        .budget_id = options.publication.budget_id,
        .store_id = target.store_id orelse return error.UnmanagedBundleTarget,
        .operation_id = options.operation_id,
        .charge = try installation.installationCharge(
            allocator,
            artifact,
            store,
            parameters,
            options.sources.target,
            options.sources.limits.bundle,
        ),
    };
    try target.revalidateControl();
    const receipt = (try options.publication.budget.observedOutcome(
        allocator,
        (target.scope() orelse return error.StorageRootMissing).fs,
        request,
    )) orelse return failure;
    if (receipt.semantic == .committed) {
        return .{ .receipt = receipt, .verification_error = failure };
    }
    receipt.transaction.deinit(allocator);
    return failure;
}

fn validateReservationOptions(
    target: *const storage_root.SourceRoot,
    options: ReservedOptions,
) !void {
    if (!std.mem.eql(u8, options.sources.target.store_id, target.store_id orelse "") or
        !std.meta.eql(options.sources.limits.bundle, options.publication.limits))
    {
        return error.PreparationReservationMismatch;
    }
}

fn installationContext(
    allocator: std.mem.Allocator,
    descriptors: []const sources.Source,
    parameters: *const definition_core.parameters.Bindings,
    options: Options,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const normalized = try owned.dupe(sources.Source, descriptors);
    for (normalized) |*source| {
        const observations = try owned.dupe(sources.Observation, source.observations);
        std.mem.sort(sources.Observation, observations, {}, observationLessThan);
        source.observations = observations;
    }
    std.mem.sort(sources.Source, normalized, {}, sourceLessThan);
    const encoded = try std.json.Stringify.valueAlloc(owned, .{
        .schema = "ledger-preparation-request/v1",
        .action = "install",
        .scope = "declared",
        .sources = normalized,
        .definition_digest = options.closure.digestSlice(),
        .definition_entry_path = options.entry_path,
        .parameter_digest = parameters.values_digest[0..],
        .target = options.target,
        .established_source_id = options.established_source_id,
        .binding_operation = options.binding_operation,
    }, .{ .emit_null_optional_fields = false });
    return definition_core.canonical_json.digestBytesAlloc(allocator, encoded);
}

fn sourceLessThan(_: void, a: sources.Source, b: sources.Source) bool {
    return std.mem.lessThan(u8, a.source_id, b.source_id);
}

fn observationLessThan(_: void, a: sources.Observation, b: sources.Observation) bool {
    return std.mem.lessThan(u8, a.observation_id, b.observation_id);
}

pub const Reserved = struct {
    declared: Declared,
    reservation: bundle.Reservation,
    action: @FieldType(ReservedOptions, "action"),
    snapshot_bytes: usize,
    publication: ?preparation.Publication = null,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        manifest: []const u8,
        parameters: *const definition_core.parameters.Bindings,
        target: *const storage_root.SourceRoot,
        options: ReservedOptions,
    ) !Reserved {
        try validateReservationOptions(target, options);
        var pending: PendingReservation = .{ .target = target, .options = options };
        errdefer if (pending.value) |*value| value.deinit();
        const declared = try Declared.openInternal(
            allocator,
            io,
            manifest,
            parameters,
            options.sources,
            &pending,
        );
        return .{
            .declared = declared,
            .reservation = pending.value.?,
            .action = options.action,
            .snapshot_bytes = options.sources.limits.snapshot_bytes,
        };
    }

    pub fn publish(
        self: *const Reserved,
        target: *const storage_root.SourceRoot,
        options: bundle.PublishOptions,
    ) !bundle.Published {
        if (self.action != .preserve) return error.PreparationActionMismatch;
        try self.declared.revalidate();
        return bundle.publishReservedCaptured(
            self.declared.allocator,
            target,
            &self.declared.captured,
            options,
            &self.reservation,
        );
    }

    pub fn install(
        self: *Reserved,
        target: *const storage_root.SourceRoot,
        parameters: *const definition_core.parameters.Bindings,
        options: installation.InstallOptions,
    ) !bundle.Published {
        if (self.action != .install) return error.PreparationActionMismatch;
        try self.declared.revalidate();
        var configuration = options;
        if (try self.recoverInstallation(target, parameters, options)) |result| return result;
        if (configuration.publication.preparation == null) {
            if (self.publication == null) {
                try self.declared.releaseTargetInto(target, &self.publication);
            }
            configuration.publication.preparation = if (self.publication) |*held| held else null;
        }
        errdefer if (self.publication) |*held| held.releaseCustody(self.declared.allocator);
        const result = try installation.installCaptured(
            self.declared.allocator,
            target,
            &self.declared.captured,
            parameters,
            configuration,
            &self.reservation,
        );
        if (result.receipt.semantic != .committed or result.receipt.accounting_error != null) {
            if (self.publication) |*held| held.releaseCustody(self.declared.allocator);
        }
        return result;
    }

    fn recoverInstallation(
        self: *Reserved,
        target: *const storage_root.SourceRoot,
        parameters: *const definition_core.parameters.Bindings,
        options: installation.InstallOptions,
    ) !?bundle.Published {
        const held = if (self.publication) |*value| value else return null;
        if (held.custody != null) return null;
        if (options.publication.preparation != null) {
            return error.PreparationSourceCoordinated;
        }
        switch (try installation.reconcileCaptured(
            self.declared.allocator,
            target,
            &self.declared.captured,
            parameters,
            options,
            &self.reservation,
        )) {
            .terminal => |result| return result,
            .ready => |receipt| self.reservation.receipt = receipt,
        }
        var snapshot = try preparation.DeclaredSnapshot.loadWithContext(
            self.declared.allocator,
            target,
            &self.declared.artifact,
            &self.declared.store,
            parameters,
            .{
                .max_snapshot_bytes = self.snapshot_bytes,
                .binding_operation = options.binding_operation,
                .budget = .{
                    .budget = self.reservation.budget,
                    .budget_id = self.reservation.request.budget_id,
                    .store_id = self.reservation.request.store_id,
                },
            },
        );
        defer snapshot.deinit(self.declared.allocator);
        try held.reacquire(self.declared.allocator, &snapshot);
        return null;
    }

    pub fn deinit(self: *Reserved) void {
        if (self.publication) |*held| held.deinit(self.declared.allocator);
        self.declared.deinit();
        self.reservation.deinit();
        self.* = undefined;
    }
};

const PendingReservation = struct {
    target: *const storage_root.SourceRoot,
    options: ReservedOptions,
    value: ?bundle.Reservation = null,

    fn acquire(
        self: *PendingReservation,
        allocator: std.mem.Allocator,
        artifact: *const definition.Plan,
        store: *const storage.Plan,
        parameters: *const definition_core.parameters.Bindings,
    ) !void {
        self.value = switch (self.options.action) {
            .preserve => try bundle.Reservation.acquire(
                allocator,
                self.target,
                self.options.operation_id,
                self.options.publication,
            ),
            .install => try bundle.Reservation.acquireCharge(
                allocator,
                self.target,
                self.options.operation_id,
                self.options.publication,
                try installation.installationCharge(
                    allocator,
                    artifact,
                    store,
                    parameters,
                    self.options.sources.target,
                    self.options.sources.limits.bundle,
                ),
            ),
        };
    }
};

pub const Declared = struct {
    allocator: std.mem.Allocator,
    plan: sources.Plan,
    artifact: definition.Plan,
    store: storage.Plan,
    inputs: []Input,
    captured: bundle.Captured,
    work: Work,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        manifest: []const u8,
        parameters: *const definition_core.parameters.Bindings,
        options: Options,
    ) !Declared {
        return openInternal(allocator, io, manifest, parameters, options, null);
    }

    fn openInternal(
        allocator: std.mem.Allocator,
        io: std.Io,
        manifest: []const u8,
        parameters: *const definition_core.parameters.Bindings,
        options: Options,
        reservation: ?*PendingReservation,
    ) !Declared {
        var plan = try sources.parseWithLimits(allocator, manifest, sourceLimits(options.limits));
        errdefer plan.deinit();
        if (plan.sources.len == 0) return error.NoPreparationSources;
        const established = try validateOptions(plan.sources, options);
        var artifact = try definition.compile(allocator, options.closure, options.entry_path);
        errdefer artifact.deinit(allocator);
        var store = try storage.compile(allocator, &artifact);
        errdefer store.deinit(allocator);
        const inputs = try allocator.alloc(Input, plan.sources.len);
        errdefer allocator.free(inputs);
        var initialized: usize = 0;
        errdefer for (inputs[0..initialized]) |*input| input.deinit(allocator);
        if (reservation) |pending| {
            try pending.acquire(allocator, &artifact, &store, parameters);
        }
        var work: Work = .{};
        for (plan.sources, inputs) |descriptor, *input| {
            try input.open(allocator, io, descriptor, options, &work);
            initialized += 1;
            try input.capture(allocator, &artifact, &store, parameters, options, &work);
        }
        const captures = try allocator.alloc(*const bundle.Captured, inputs.len);
        defer allocator.free(captures);
        for (inputs, captures) |*input, *capture| capture.* = input.captured();
        var captured = try transport.merge(allocator, captures, parameters, .{
            .target = options.target,
            .limits = options.limits.bundle,
            .max_input_bytes = try mergeInputLimit(inputs.len, options.limits),
            .established_input = established,
            .binding_operation = options.binding_operation,
        });
        errdefer captured.deinit();
        for (inputs) |*input| try input.revalidate();
        return .{
            .allocator = allocator,
            .plan = plan,
            .artifact = artifact,
            .store = store,
            .inputs = inputs,
            .captured = captured,
            .work = work,
        };
    }

    pub fn revalidate(self: *const Declared) !void {
        for (self.inputs) |*input| try input.revalidate();
    }

    pub fn releaseTargetForPublication(
        self: *Declared,
        target: *const storage_root.SourceRoot,
    ) !preparation.Publication {
        return (try self.releaseTargetIfPresent(target)) orelse
            error.PreparationTargetIsNotSource;
    }

    fn releaseTargetIfPresent(
        self: *Declared,
        target: *const storage_root.SourceRoot,
    ) !?preparation.Publication {
        var result: ?preparation.Publication = null;
        errdefer if (result) |*held| held.deinit(self.allocator);
        try self.releaseTargetInto(target, &result);
        return result;
    }

    fn releaseTargetInto(
        self: *Declared,
        target: *const storage_root.SourceRoot,
        publication: *?preparation.Publication,
    ) !void {
        if (publication.* != null) return error.PreparationSourceCoordinated;
        try self.revalidate();
        try target.revalidateControl();
        const identity = try durable_store.openDirectoryIdentity(target.io, target.directory);
        var snapshots: std.ArrayList(*preparation.DeclaredSnapshot) = .empty;
        defer snapshots.deinit(self.allocator);
        for (self.inputs) |*input| {
            switch (input.*) {
                .live => |*live| {
                    const root = &live.admitted.root;
                    const candidate = try durable_store.openDirectoryIdentity(
                        root.io,
                        root.directory,
                    );
                    if (std.meta.eql(identity, candidate)) {
                        try snapshots.append(self.allocator, &live.snapshot.?);
                    }
                },
                .transported => {},
            }
        }
        if (snapshots.items.len == 0) return;
        publication.* = try preparation.Publication.prepare(self.allocator, snapshots.items);
        publication.*.?.acquireCustody(self.allocator, snapshots.items) catch |err| {
            for (snapshots.items) |snapshot| snapshot.releaseCustody(self.allocator);
            return err;
        };
    }

    pub fn deinit(self: *Declared) void {
        self.captured.deinit();
        for (self.inputs) |*input| input.deinit(self.allocator);
        self.allocator.free(self.inputs);
        self.store.deinit(self.allocator);
        self.artifact.deinit(self.allocator);
        self.plan.deinit();
        self.* = undefined;
    }
};

const Live = struct {
    admitted: admission.RootAdmission,
    snapshot: ?preparation.DeclaredSnapshot = null,
    captured: ?bundle.Captured = null,

    fn deinit(self: *Live, allocator: std.mem.Allocator) void {
        if (self.captured) |*captured| captured.deinit();
        if (self.snapshot) |*snapshot| snapshot.deinit(allocator);
        self.admitted.deinit();
    }
};

const Input = union(enum) {
    live: Live,
    transported: transport.Loaded,

    fn open(
        self: *Input,
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: sources.Source,
        options: Options,
        work: *Work,
    ) !void {
        if (descriptor.kind == .@"preservation-bundle") {
            var limits = options.limits.bundle;
            limits.payload_bytes = @min(
                limits.payload_bytes,
                options.limits.capture_bytes - work.captured_bytes,
            );
            self.* = .{ .transported = try transport.Loaded.open(
                allocator,
                io,
                descriptor,
                limits,
            ) };
        } else {
            self.* = .{ .live = .{ .admitted = try admission.RootAdmission.open(
                allocator,
                io,
                descriptor,
                .{
                    .sources = sourceLimits(options.limits),
                    .evidence_bytes = options.limits.evidence_bytes - work.evidence_bytes,
                },
            ) } };
            work.evidence_bytes += self.live.admitted.evidence_bytes_read;
        }
    }

    fn capture(
        self: *Input,
        allocator: std.mem.Allocator,
        artifact: *const definition.Plan,
        store: *const storage.Plan,
        parameters: *const definition_core.parameters.Bindings,
        options: Options,
        work: *Work,
    ) !void {
        switch (self.*) {
            .live => |*live| {
                live.snapshot = try preparation.DeclaredSnapshot.loadWithContext(
                    allocator,
                    &live.admitted.root,
                    artifact,
                    store,
                    parameters,
                    .{
                        .max_snapshot_bytes = options.limits.snapshot_bytes - work.snapshot_bytes,
                        .binding_operation = options.binding_operation,
                        .budget = budgetFor(options.budgets, live.admitted.descriptor().source_id),
                    },
                );
                work.snapshot_bytes += live.snapshot.?.snapshot_bytes;
                var limits = options.limits.bundle;
                limits.payload_bytes = @min(
                    limits.payload_bytes,
                    options.limits.capture_bytes - work.captured_bytes,
                );
                live.captured = try bundle.captureDeclared(allocator, &live.snapshot.?, .{
                    .closure = options.closure,
                    .entry_path = options.entry_path,
                    .target = options.target,
                    .evidence = &live.admitted,
                    .limits = limits,
                });
            },
            .transported => {},
        }
        const captured_input = self.captured();
        for (captured_input.files) |file| {
            if (file.content.len > options.limits.capture_bytes - work.captured_bytes) {
                return error.CaptureLimitExceeded;
            }
            work.captured_bytes += file.content.len;
        }
        var manifest = try bundle.parse(allocator, captured_input.manifest, options.limits.bundle);
        defer manifest.deinit();
        const selected = manifest.description;
        if (!std.mem.eql(u8, selected.definition_id, artifact.id) or
            !std.mem.eql(u8, selected.definition_digest, options.closure.digestSlice()) or
            !std.mem.eql(u8, selected.definition_entry_path, options.entry_path))
        {
            return error.PreparationDefinitionMismatch;
        }
    }

    fn captured(self: *const Input) *const bundle.Captured {
        return switch (self.*) {
            .live => |*live| &live.captured.?,
            .transported => |*loaded| &loaded.captured,
        };
    }

    fn revalidate(self: *const Input) !void {
        switch (self.*) {
            .live => |*live| try live.admitted.revalidate(),
            .transported => |*loaded| try loaded.revalidate(),
        }
    }

    fn deinit(self: *Input, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .live => |*live| live.deinit(allocator),
            .transported => |*loaded| loaded.deinit(),
        }
    }
};

fn sourceLimits(limits: Limits) sources.Limits {
    return .{
        .sources = limits.bundle.sources,
        .observations = limits.bundle.observations,
        .manifest_bytes = limits.bundle.manifest_bytes,
    };
}

fn budgetFor(budgets: []const Budget, source_id: []const u8) ?preparation.BudgetContext {
    for (budgets) |budget| {
        if (std.mem.eql(u8, budget.source_id, source_id)) return budget.context;
    }
    return null;
}

fn validateOptions(descriptors: []const sources.Source, options: Options) !?usize {
    var established: ?usize = null;
    if (options.established_source_id) |id| {
        for (descriptors, 0..) |descriptor, index| {
            if (std.mem.eql(u8, id, descriptor.source_id)) established = index;
        }
        if (established == null) return error.InvalidPreparationTarget;
    }
    if (options.budgets.len > descriptors.len) return error.InvalidPreparationBudgetContext;
    for (options.budgets, 0..) |budget, index| {
        for (options.budgets[0..index]) |prior| {
            if (std.mem.eql(u8, prior.source_id, budget.source_id)) {
                return error.InvalidPreparationBudgetContext;
            }
        }
        var found = false;
        for (descriptors) |descriptor| {
            if (!std.mem.eql(u8, descriptor.source_id, budget.source_id)) continue;
            if (descriptor.kind == .@"preservation-bundle") {
                return error.InvalidPreparationBudgetContext;
            }
            found = true;
        }
        if (!found) return error.InvalidPreparationBudgetContext;
    }
    _ = try mergeInputLimit(descriptors.len, options.limits);
    return established;
}

fn mergeInputLimit(count: usize, limits: Limits) !u64 {
    const manifests = std.math.mul(u64, count, limits.bundle.manifest_bytes) catch
        return error.CaptureLimitExceeded;
    return std.math.add(u64, limits.capture_bytes, manifests) catch
        return error.CaptureLimitExceeded;
}
