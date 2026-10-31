const std = @import("std");
const storage_root = @import("storage_root");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const definition = @import("definition.zig");
const definition_archive = @import("definition_archive.zig");
const custody = @import("custody.zig");
const replay = @import("replay.zig");
const revision_archive = @import("revision_archive.zig");
const storage = @import("storage.zig");
const transaction = @import("transaction.zig");
const work = @import("preparation_work.zig");
const space = @import("preparation_space.zig");

pub const Limits = struct {
    max_bytes: usize = 64 * 1024 * 1024,
    max_files: usize = 512,
    max_read_bytes: usize = 1024 * 1024 * 1024,

    pub fn validate(self: Limits) !void {
        if (self.max_bytes == 0 or self.max_bytes > 1024 * 1024 * 1024 or
            self.max_files < 2 or self.max_files > 1023 or
            self.max_read_bytes == 0 or self.max_read_bytes > 16 * 1024 * 1024 * 1024)
        {
            return error.InvalidPreparationBound;
        }
    }
};

pub const Source = struct {
    root: []const u8,
    store_id: ?[]const u8 = null,
    archive: bool = false,
};

pub const Options = struct {
    apply: bool = false,
    confirm_no_legacy_writers: bool = false,
    limits: Limits = .{},
};

pub const Observation = struct {
    root: []const u8,
    store_id: ?[]const u8,
    archive: bool,
    revision: ?[]u8,
    records: usize,
    selected_bytes: usize,
};

pub const Result = struct {
    schema: []const u8 = "ledger-preparation-result/v1",
    store_root: ?[]const u8 = null,
    store_id: ?[]const u8 = null,
    owner: []const u8,
    outcome: []const u8,
    phase: []const u8 = "inspection",
    storage_mutated: ?bool = false,
    authority_granted: bool = false,
    limits: Limits,
    bytes_read: usize = 0,
    file_reads: usize = 0,
    selected_bytes: usize = 0,
    staged_bytes: ?usize = 0,
    write_scope: []const u8 = "selected-preparation-payload",
    native_bytes_written: ?usize = null,
    peak_additional_working_bytes: ?usize = null,
    reclaimed_bytes: usize = 0,
    prior_preparation: ?work.Report = null,
    estimated_peak_additional_bytes: usize = 0,
    free_bytes: ?u64 = null,
    records: usize = 0,
    transaction_id: ?[]u8 = null,
    error_code: ?[]const u8 = null,
    read_scope: []const u8 = "preparation-operation-including-native-recovery",
    invocation_input_bytes: ?usize = null,
    observations: []Observation,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.transaction_id) |id| allocator.free(id);
        for (self.observations) |observation| {
            if (observation.revision) |revision| allocator.free(revision);
        }
        allocator.free(self.observations);
        self.* = undefined;
    }
};

const OpenedSource = struct {
    source: Source,
    root: std.Io.Dir,
    control: ?std.Io.Dir,

    fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        source: Source,
        budget: *storage_root.ReadBudget,
    ) !OpenedSource {
        if (std.mem.indexOf(u8, source.root, "/.preparation/") != null or
            std.mem.endsWith(u8, source.root, "/.preparation"))
        {
            return error.PreparationWorkspaceIsNotSource;
        }
        const root = try storage_root.openRoot(io, source.root);
        errdefer root.close(io);
        const control = if (source.store_id) |id|
            try storage_root.checkedRootBudgeted(allocator, io, source.root, id, budget)
        else
            root.openDir(io, ".ledger", .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
        return .{ .source = source, .root = root, .control = control };
    }

    fn deinit(self: *OpenedSource, io: std.Io) void {
        if (self.control) |control| control.close(io);
        self.root.close(io);
        self.* = undefined;
    }

    fn revalidate(
        self: *const OpenedSource,
        io: std.Io,
        allocator: std.mem.Allocator,
        budget: *storage_root.ReadBudget,
    ) !void {
        var current = try OpenedSource.open(io, allocator, self.source, budget);
        defer current.deinit(io);
        if ((try self.root.stat(io)).inode != (try current.root.stat(io)).inode) {
            return error.PreparationSourceChanged;
        }
        if (self.control) |control| {
            const present = current.control orelse return error.PreparationSourceChanged;
            if ((try control.stat(io)).inode != (try present.stat(io)).inode) {
                return error.PreparationSourceChanged;
            }
        } else if (current.control != null) return error.PreparationSourceChanged;
    }
};

pub fn execute(
    scope: *storage_root.Scope,
    selection: *const storage_root.Selection,
    allocator: std.mem.Allocator,
    plan: *const definition.Plan,
    store: *const storage.Plan,
    parameters: *const definition_core.parameters.Bindings,
    protocol_required: bool,
    sources: []const Source,
    options: Options,
) !Result {
    if (!storage_root.isActive(scope)) return error.PreparationRequiresManagedTarget;
    const slot = try selectedSlot(store);
    try options.limits.validate();
    if (sources.len > 32) return error.PreparationSourceBoundExceeded;
    var budget: storage_root.ReadBudget = .{
        .max_bytes = options.limits.max_read_bytes,
        .max_files = options.limits.max_files * 16,
    };
    const previous_budget = scope.fs.read_budget;
    scope.fs.read_budget = &budget;
    defer scope.fs.read_budget = previous_budget;
    var execution: Execution = .{
        .scope = scope,
        .selection = selection,
        .allocator = allocator,
        .plan = plan,
        .slot = slot,
        .parameters = parameters,
        .protocol_required = protocol_required,
        .options = options,
        .budget = &budget,
        .result = .{
            .owner = plan.id,
            .outcome = "empty",
            .limits = options.limits,
            .observations = try allocator.alloc(Observation, 0),
        },
    };
    defer execution.deinit();
    errdefer execution.result.deinit(allocator);
    execution.run(sources) catch |err| execution.recordFailure(err);
    return execution.finish();
}

const Execution = struct {
    scope: *storage_root.Scope,
    selection: *const storage_root.Selection,
    allocator: std.mem.Allocator,
    plan: *const definition.Plan,
    slot: storage.ResolvedSlot,
    parameters: *const definition_core.parameters.Bindings,
    protocol_required: bool,
    options: Options,
    budget: *storage_root.ReadBudget,
    result: Result,
    workspace: ?work.Workspace = null,
    target: History = .{},
    missing_binding: ?custody.BindingSnapshot = null,
    opened: std.ArrayList(OpenedSource) = .empty,
    histories: std.ArrayList(History) = .empty,
    observations: std.ArrayList(Observation) = .empty,
    best: ?usize = null,
    target_covers: bool = true,

    fn run(self: *Execution, sources: []const Source) !void {
        try self.selection.revalidateBudgeted(self.allocator, self.budget);
        if (try self.resolvePriorWork()) {
            self.target = try self.readTarget();
            try self.admitSources(sources);
            try self.decide();
        }
        const previous_phase = self.result.phase;
        self.result.phase = "target-revalidation";
        try self.selection.revalidateBudgeted(self.allocator, self.budget);
        self.result.phase = previous_phase;
    }

    fn recordFailure(self: *Execution, err: anyerror) void {
        self.result.error_code = @errorName(err);
        self.result.outcome = if (self.result.transaction_id != null)
            "committed-with-later-failure"
        else if (err == error.LockBusy or err == error.EventStoreBusy)
            "busy"
        else if (std.mem.eql(u8, self.result.phase, "publication") or
            std.mem.eql(u8, self.result.phase, "recovery") or
            std.mem.startsWith(u8, self.result.phase, "prior-"))
            "recovery-required"
        else
            failureOutcome(err);
    }

    fn deinit(self: *Execution) void {
        if (self.workspace) |*workspace| workspace.deinit();
        self.target.deinit(self.allocator);
        if (self.missing_binding) |*binding| binding.deinit(self.allocator);
        for (self.histories.items) |*history| history.deinit(self.allocator);
        self.histories.deinit(self.allocator);
        for (self.opened.items) |*source| source.deinit(self.scope.fs.io);
        self.opened.deinit(self.allocator);
        for (self.observations.items) |observation| {
            if (observation.revision) |revision| self.allocator.free(revision);
        }
        self.observations.deinit(self.allocator);
    }

    fn finish(self: *Execution) !Result {
        const observations = try self.observations.toOwnedSlice(self.allocator);
        self.allocator.free(self.result.observations);
        self.result.observations = observations;
        self.result.bytes_read = self.budget.bytes;
        self.result.file_reads = self.budget.files;
        self.result.storage_mutated = self.scope.mutation_state;
        if (self.workspace) |workspace| self.result.reclaimed_bytes = workspace.reclaimed_bytes;
        return self.result;
    }

    fn resolvePriorWork(self: *Execution) !bool {
        self.result.phase = "prior-inspection";
        var needed = try durable_store.countPendingTransactions(
            self.scope.fs,
            self.allocator,
            ".transactions",
        ) != 0;
        if (!needed) {
            var observation: ?work.Report = null;
            defer self.retainPriorObservation(observation);
            try work.inspectObserved(self.scope, self.allocator, self.options.limits, &observation);
            const existing = observation.?;
            needed = existing.phase != .absent and existing.phase != .finalized;
        }
        if (!needed) {
            self.result.phase = "preparation";
            return true;
        }
        if (!self.options.apply) {
            self.result.outcome = "recovery-required";
            return false;
        }
        try self.acquireWorkspace();
        return true;
    }

    fn acquireWorkspace(self: *Execution) !void {
        if (self.workspace != null) return;
        self.workspace = try work.Workspace.acquire(self.scope, self.allocator);
        self.result.phase = "recovery";
        if (try transaction.recoverRepositoryTransactions(self.scope, self.allocator, ".")) {
            transaction.markStorageMutated(self.scope);
        }
        self.result.phase = "prior-reconciliation";
        var observation: ?work.Report = null;
        defer self.retainPriorObservation(observation);
        try self.workspace.?.reconcileObserved(self.options.limits, true, &observation);
        self.result.phase = "preparation";
    }

    fn retainPriorObservation(self: *Execution, observation: ?work.Report) void {
        const observed = observation orelse return;
        self.result.prior_preparation = observed;
        if (std.mem.startsWith(u8, self.result.phase, "prior-")) {
            self.result.phase = switch (observed.activity) {
                .inspection => "prior-inspection",
                .cleanup => "prior-cleanup",
            };
        }
    }

    fn capture(self: *Execution, scope: *storage_root.Scope, coordinated: bool) !History {
        return captureHistory(
            scope,
            self.allocator,
            ".",
            self.plan,
            self.slot,
            self.parameters,
            self.protocol_required,
            self.options.limits,
            coordinated,
        );
    }

    fn readTarget(self: *Execution) !History {
        return self.capture(self.scope, false) catch |err| switch (err) {
            error.StoreBindingWithoutSlot => self.readMissingTarget(),
            else => err,
        };
    }

    fn readMissingTarget(self: *Execution) !History {
        const path = try custody.bindingPathAlloc(
            self.scope,
            self.allocator,
            ".",
            self.slot.relative_path,
        );
        defer self.allocator.free(path);
        var locks = try durable_store.acquireCasReadLockPair(
            self.scope.fs,
            self.allocator,
            self.slot.relative_path,
            path,
        );
        errdefer locks.deinit();
        self.missing_binding = try custody.readBindingSnapshotBeforeReplay(
            self.scope,
            self.allocator,
            path,
            self.plan.id,
            self.slot.name,
            self.slot.relative_path,
            null,
        );
        try requireMissing(self.scope, self.slot.relative_path);
        if (!self.missing_binding.?.exists) return error.PreparationTargetChanged;
        return .{ .read_custody = locks };
    }

    fn admitSources(self: *Execution, sources: []const Source) !void {
        try self.opened.ensureTotalCapacity(self.allocator, sources.len);
        try self.histories.ensureTotalCapacity(self.allocator, sources.len);
        for (sources) |source| try self.admitSource(source);
        try self.revalidateSources();
        try self.selection.revalidateBudgeted(self.allocator, self.budget);
    }

    fn admitSource(self: *Execution, source: Source) !void {
        self.opened.appendAssumeCapacity(try OpenedSource.open(
            self.scope.fs.io,
            self.allocator,
            source,
            self.budget,
        ));
        const current = &self.opened.items[self.opened.items.len - 1];
        var history = try self.captureSource(current);
        errdefer history.deinit(self.allocator);
        if (source.archive) try validateArchive(
            self.scope.fs.io,
            self.allocator,
            source,
            &history,
            self.budget,
        );
        const index = self.histories.items.len;
        if (self.best) |selected| {
            if (history.covers(&self.histories.items[selected])) {
                self.best = index;
            } else if (!self.histories.items[selected].covers(&history)) {
                return error.PreparationDivergentHistory;
            }
        } else self.best = index;
        const revision = if (history.exists)
            try self.allocator.dupe(u8, history.files.items[0].digest)
        else
            null;
        errdefer if (revision) |value| self.allocator.free(value);
        try self.observations.append(self.allocator, .{
            .root = source.root,
            .store_id = source.store_id,
            .archive = source.archive,
            .revision = revision,
            .records = history.records,
            .selected_bytes = history.bytes,
        });
        self.target_covers = self.target_covers and self.target.covers(&history);
        self.histories.appendAssumeCapacity(history);
    }

    fn captureSource(self: *Execution, source: *const OpenedSource) !History {
        if (source.control) |control| {
            var scope: storage_root.Scope = .{
                .fs = self.scope.fs.reanchor(control),
            };
            if (!source.source.archive) try durable_store.ensureNoPendingTransactions(
                scope.fs,
                self.allocator,
                ".transactions",
            );
            return self.capture(
                &scope,
                !self.options.confirm_no_legacy_writers and !source.source.archive,
            );
        }
        if (!self.options.confirm_no_legacy_writers and !source.source.archive) {
            return error.PreparationRequiresQuiescence;
        }
        return .{};
    }

    fn revalidateSources(self: *Execution) !void {
        for (self.opened.items, self.histories.items) |*source, *history| {
            try source.revalidate(self.scope.fs.io, self.allocator, self.budget);
            if (source.control) |control| {
                var scope: storage_root.Scope = .{
                    .fs = self.scope.fs.reanchor(control),
                };
                try recheckHistory(&scope, self.allocator, self.slot, history);
            }
            if (source.source.archive) try validateArchive(
                self.scope.fs.io,
                self.allocator,
                source.source,
                history,
                self.budget,
            );
        }
    }

    fn decide(self: *Execution) !void {
        if (self.target.exists and self.target_covers) {
            self.result.outcome = "covered";
            self.result.selected_bytes = self.target.bytes;
            self.result.records = self.target.records;
            return;
        }
        const selected = self.best orelse {
            if (self.missing_binding != null) return error.PreparationRequiredSourceMissing;
            return;
        };
        const chosen = &self.histories.items[selected];
        if (self.target.exists) {
            if (!chosen.covers(&self.target)) return error.PreparationDivergentHistory;
            self.result.outcome = "reconciliation-required";
            return;
        }
        if (!chosen.exists) {
            if (self.missing_binding != null) return error.PreparationRequiredSourceMissing;
            return;
        }
        if (self.missing_binding) |binding| {
            if (!std.mem.eql(u8, binding.bytes, chosen.files.items[1].bytes) or
                binding.last_revision == null or
                !std.mem.eql(u8, binding.last_revision.?, chosen.files.items[0].digest))
            {
                return error.PreparationBindingConflict;
            }
        }
        self.result.outcome = "ready";
        self.result.selected_bytes = chosen.bytes;
        self.result.records = chosen.records;
        self.result.estimated_peak_additional_bytes = try space.peakAdditionalBytes(chosen.bytes);
        self.result.free_bytes = space.availableBytes(self.scope.fs.directory());
        if (self.options.apply) try self.install(chosen);
    }

    fn install(self: *Execution, chosen: *const History) !void {
        if (self.result.free_bytes) |available| {
            if (available < self.result.estimated_peak_additional_bytes) {
                return error.InsufficientPreparationSpace;
            }
        }
        releaseHistoryLocks(&self.target);
        try self.acquireWorkspace();
        var refreshed = self.capture(self.scope, false) catch |err| switch (err) {
            error.StoreBindingWithoutSlot => History{},
            else => return err,
        };
        defer refreshed.deinit(self.allocator);
        if (refreshed.exists) {
            self.result.outcome = if (refreshed.covers(chosen))
                "covered"
            else
                "reconciliation-required";
            return;
        }
        releaseHistoryLocks(&refreshed);
        const provenance = try std.json.Stringify.valueAlloc(
            self.allocator,
            self.observations.items,
            .{},
        );
        defer self.allocator.free(provenance);
        self.result.phase = "capture";
        self.result.staged_bytes = null;
        try self.workspace.?.stage(chosen, provenance, self.options.limits);
        self.result.staged_bytes = chosen.bytes;
        try self.revalidateSources();
        try self.selection.revalidateBudgeted(self.allocator, self.budget);
        self.result.phase = "publication";
        self.result.transaction_id = try publish(
            self.scope,
            self.allocator,
            chosen,
            &self.workspace.?,
        );
        self.result.outcome = "prepared";
        self.result.phase = "committed";
        self.finishInstallation(chosen) catch |err| {
            self.result.outcome = "committed-with-later-failure";
            self.result.error_code = @errorName(err);
        };
    }

    fn finishInstallation(self: *Execution, chosen: *const History) !void {
        self.result.phase = "verification";
        var installed = try self.capture(self.scope, true);
        defer installed.deinit(self.allocator);
        if (!installed.covers(chosen) or !chosen.covers(&installed)) {
            return error.PreparationInstalledHistoryMismatch;
        }
        self.result.phase = "cleanup";
        _ = try self.workspace.?.reconcile(self.options.limits, true);
        self.result.phase = "committed";
    }
};

fn failureOutcome(err: anyerror) []const u8 {
    return switch (err) {
        error.LockBusy, error.EventStoreBusy => "busy",
        error.TransactionRecoveryRequired, error.PreparationOwnershipUnknown => "recovery-required",
        error.PreparationDivergentHistory,
        error.PreparationBindingConflict,
        => "reconciliation-required",
        error.ReadBudgetExceeded,
        error.ReadFileBudgetExceeded,
        error.PreparationFileBoundExceeded,
        error.PreparationSpaceBoundExceeded,
        error.TooManyFiles,
        error.FileTooBig,
        => "incomplete",
        error.UnsupportedPreparationLayout => "unsupported",
        else => "failure",
    };
}

fn releaseHistoryLocks(history: *History) void {
    if (history.read_custody) |*locks| {
        locks.deinit();
        history.read_custody = null;
    }
}

fn requireMissing(scope: *storage_root.Scope, path: []const u8) !void {
    const stat = scope.fs.directory().statFile(
        scope.fs.io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    _ = stat;
    return error.PreparationSourceChanged;
}

fn recheckHistory(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    slot: storage.ResolvedSlot,
    history: *const History,
) !void {
    if (!history.exists) {
        try requireMissing(scope, slot.relative_path);
        const binding = try custody.bindingPathAlloc(scope, allocator, ".", slot.relative_path);
        defer allocator.free(binding);
        try requireMissing(scope, binding);
    }
    for (history.files.items) |file| {
        const bytes = try scope.readFile(allocator, file.path, file.bytes.len);
        defer allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, file.bytes)) return error.PreparationSourceChanged;
    }
}

fn publish(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    history: *const History,
    workspace: *const work.Workspace,
) ![]u8 {
    const control_root = try std.fs.path.join(
        allocator,
        &.{ ".", storage_root.controlComponent(scope) },
    );
    defer allocator.free(control_root);
    const transactions = try std.fs.path.join(allocator, &.{ control_root, ".transactions" });
    defer allocator.free(transactions);
    const counter = try std.fs.path.join(allocator, &.{ control_root, ".fencing.counter" });
    defer allocator.free(counter);
    const operation_path = try std.fs.path.join(allocator, &.{ control_root, work.record_path });
    defer allocator.free(operation_path);
    const mutations = try allocator.alloc(
        durable_store.TransactionMutation,
        history.files.items.len + 1,
    );
    defer allocator.free(mutations);
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    try paths.ensureTotalCapacity(allocator, history.files.items.len);
    for (history.files.items, 0..) |file, index| {
        const path = try std.fs.path.join(allocator, &.{ control_root, file.path });
        paths.appendAssumeCapacity(path);
        mutations[index] = try selectedMutation(scope, allocator, path, file);
    }
    mutations[mutations.len - 1] = try workspace.publicationMutation();
    mutations[mutations.len - 1].path = operation_path;
    transaction.markStorageMutationUnknown(scope);
    var receipt = try durable_store.commitTextTransaction(
        scope.fs,
        allocator,
        transactions,
        mutations,
        .{
            .owner = .{
                .process_id = 0,
                .session_id = "ledger-preparation-v1",
                .executor = "ledger",
            },
            .fencing_counter_path = counter,
            .reject_symlinks = true,
        },
    );
    defer receipt.deinit(allocator);
    transaction.markStorageMutated(scope);
    const transaction_id = @constCast(receipt.transaction_id);
    receipt.transaction_id = &.{};
    return transaction_id;
}

fn selectedMutation(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    path: []const u8,
    file: File,
) !durable_store.TransactionMutation {
    const existing = scope.readFile(allocator, file.path, file.bytes.len) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| allocator.free(bytes);
    if (existing) |bytes| {
        if (!std.mem.eql(u8, bytes, file.bytes)) return error.PreparationTargetConflict;
    }
    return .{
        .path = path,
        .text = file.bytes,
        .expectation = .{
            .expected_exists = existing != null,
            .expected_digest = if (existing != null) file.digest else null,
        },
        .content_mode = .raw,
        .action = if (existing != null) .check_only else .write,
        .max_bytes = @max(file.bytes.len, 1),
    };
}

fn validateArchive(
    io: std.Io,
    allocator: std.mem.Allocator,
    source: Source,
    history: *const History,
    budget: *storage_root.ReadBudget,
) !void {
    if (!history.exists) return error.PreparationArchiveEvidenceMissing;
    const basename = std.fs.path.basename(source.root);
    if (!std.mem.startsWith(u8, basename, "worktree-")) return error.InvalidPreparationArchive;
    const index = basename[9..];
    _ = std.fmt.parseInt(usize, index, 10) catch return error.InvalidPreparationArchive;
    const parent = std.fs.path.dirname(source.root) orelse return error.InvalidPreparationArchive;
    const archive_parent = std.fs.path.dirname(parent) orelse
        return error.InvalidPreparationArchive;
    if (!std.mem.eql(u8, std.fs.path.basename(archive_parent), "legacy-archive")) {
        return error.InvalidPreparationArchive;
    }
    var directory = try storage_root.openRoot(io, parent);
    defer directory.close(io);
    var scope: storage_root.Scope = .{ .fs = .{
        .io = io,
        .root = .{ .pinned = directory },
        .read_budget = budget,
    } };
    const bytes = try scope.readFile(allocator, "manifest.json", 32 * 1024 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const object = try definition_core.json.object(parsed.value);
    const schema = try definition_core.json.requiredString(object, "schema");
    if (!std.mem.eql(u8, schema, "ledger-legacy-archive/v1")) {
        return error.InvalidPreparationArchive;
    }
    const sources = try definition_core.json.object(
        object.get("sources") orelse return error.InvalidPreparationArchive,
    );
    const selected = try definition_core.json.object(
        sources.get(index) orelse return error.InvalidPreparationArchive,
    );
    const entries = try definition_core.json.object(
        selected.get("entries") orelse return error.InvalidPreparationArchive,
    );
    for (history.files.items) |file| {
        const path = try allocator.print(".ledger/{s}", .{file.path});
        defer allocator.free(path);
        const entry = try definition_core.json.object(
            entries.get(path) orelse return error.PreparationArchiveEvidenceMissing,
        );
        if (!std.mem.eql(u8, try definition_core.json.requiredString(entry, "kind"), "file") or
            !std.mem.eql(
                u8,
                try definition_core.json.requiredString(entry, "sha256"),
                file.digest[7..],
            ))
        {
            return error.PreparationArchiveEvidenceMismatch;
        }
        const size = entry.get("size") orelse return error.PreparationArchiveEvidenceMissing;
        if (size != .integer or size.integer < 0 or size.integer != file.bytes.len) {
            return error.PreparationArchiveEvidenceMismatch;
        }
    }
}

pub const File = struct {
    path: []u8,
    bytes: []u8,
    digest: []u8,

    fn deinit(self: *File, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.bytes);
        allocator.free(self.digest);
        self.* = undefined;
    }
};

pub const History = struct {
    files: std.ArrayList(File) = .empty,
    read_custody: ?durable_store.CasReadLockPair = null,
    bytes: usize = 0,
    records: usize = 0,
    exists: bool = false,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        if (self.read_custody) |*locks| locks.deinit();
        for (self.files.items) |*file| file.deinit(allocator);
        self.files.deinit(allocator);
        self.* = undefined;
    }

    fn append(
        self: *History,
        allocator: std.mem.Allocator,
        path: []const u8,
        bytes: []const u8,
        limits: Limits,
    ) !void {
        if (self.files.items.len == limits.max_files) return error.PreparationFileBoundExceeded;
        if (bytes.len > limits.max_bytes - self.bytes) return error.PreparationSpaceBoundExceeded;
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_bytes = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned_bytes);
        const digest = try definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
        errdefer allocator.free(digest);
        try self.files.append(allocator, .{
            .path = owned_path,
            .bytes = owned_bytes,
            .digest = digest,
        });
        self.bytes += bytes.len;
    }

    pub fn covers(self: *const History, other: *const History) bool {
        if (!other.exists) return true;
        if (!self.exists) return false;
        if (!completePrefix(other.files.items[0].bytes, self.files.items[0].bytes)) return false;
        if (!completePrefix(other.files.items[1].bytes, self.files.items[1].bytes)) return false;
        for (other.files.items[2..]) |required| {
            var found = false;
            for (self.files.items[2..]) |candidate| {
                if (!std.mem.eql(u8, required.path, candidate.path)) continue;
                if (!std.mem.eql(u8, required.bytes, candidate.bytes)) return false;
                found = true;
                break;
            }
            if (!found) return false;
        }
        return true;
    }
};

pub fn selectedSlot(plan: *const storage.Plan) !storage.ResolvedSlot {
    if (plan.slots.len != 1) return error.UnsupportedPreparationLayout;
    const slot = plan.slots[0];
    if (slot.kind != .event_log or slot.codec != .jsonl or slot.layout != .monolithic or
        std.mem.indexOfScalar(u8, slot.relative_path, '{') != null)
    {
        return error.UnsupportedPreparationLayout;
    }
    return .{
        .name = slot.name,
        .relative_path = slot.relative_path,
        .owned_path = null,
        .kind = slot.kind,
        .codec = slot.codec,
        .max_bytes = slot.max_bytes,
        .layout = slot.layout,
    };
}

pub fn captureHistory(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    plan: *const definition.Plan,
    slot: storage.ResolvedSlot,
    parameters: *const definition_core.parameters.Bindings,
    protocol_required: bool,
    limits: Limits,
    require_coordination: bool,
) !History {
    try limits.validate();
    var bounded_slot = slot;
    bounded_slot.max_bytes = @min(slot.max_bytes, limits.max_bytes);
    var snapshot = try custody.readSlotOrMissing(
        scope,
        allocator,
        repo_root,
        plan.id,
        bounded_slot,
    );
    defer snapshot.deinit(allocator);
    if (require_coordination and
        (snapshot.read_custody == null or snapshot.read_custody.?.count != 2))
    {
        return error.PreparationRequiresQuiescence;
    }
    var result: History = .{};
    errdefer result.deinit(allocator);
    result.read_custody = snapshot.read_custody;
    snapshot.read_custody = null;
    if (!snapshot.exists) return result;
    var stats = try replay.validateSlot(
        scope,
        allocator,
        repo_root,
        plan.id,
        bounded_slot,
        &snapshot,
        parameters,
        plan.bounds.max_records,
        protocol_required,
    );
    defer stats.deinit(allocator);
    try captureSnapshotFiles(
        scope,
        allocator,
        repo_root,
        slot,
        &snapshot,
        limits,
        &result,
    );
    try captureMetadata(
        scope,
        allocator,
        repo_root,
        plan.id,
        bounded_slot,
        &snapshot,
        limits,
        &result,
    );
    result.records = stats.records_validated;
    result.exists = true;
    return result;
}

fn captureSnapshotFiles(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    slot: storage.ResolvedSlot,
    snapshot: *const custody.SlotSnapshot,
    limits: Limits,
    result: *History,
) !void {
    try result.append(allocator, slot.relative_path, snapshot.content, limits);
    const path = try custody.bindingPathAlloc(scope, allocator, repo_root, slot.relative_path);
    defer allocator.free(path);
    try result.append(
        allocator,
        try controlRelative(scope, repo_root, path),
        snapshot.binding.bytes,
        limits,
    );
}

fn captureMetadata(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    definition_id: []const u8,
    slot: storage.ResolvedSlot,
    snapshot: *const custody.SlotSnapshot,
    limits: Limits,
    result: *History,
) !void {
    var dependencies = try replay.collectHistoryDependencies(
        scope,
        allocator,
        repo_root,
        definition_id,
        slot,
        snapshot,
        limits.max_files - 2,
    );
    defer dependencies.deinit(allocator);
    for (dependencies.definitions) |digest| {
        const path = try definition_archive.pathAlloc(scope, allocator, repo_root, digest);
        defer allocator.free(path);
        const bytes = try scope.readFile(
            allocator,
            path,
            @min(definition_archive.max_bytes, limits.max_bytes - result.bytes),
        );
        defer allocator.free(bytes);
        try result.append(allocator, try controlRelative(scope, repo_root, path), bytes, limits);
    }
    for (dependencies.revisions) |revision| {
        const path = try revision_archive.pathAlloc(scope, allocator, repo_root, revision.digest);
        defer allocator.free(path);
        const bytes = try revision_archive.load(
            scope,
            allocator,
            repo_root,
            revision.digest,
            @min(revision.max_bytes, limits.max_bytes - result.bytes),
        );
        defer allocator.free(bytes);
        try result.append(allocator, try controlRelative(scope, repo_root, path), bytes, limits);
    }
}

fn controlRelative(
    scope: *const storage_root.Scope,
    root: []const u8,
    path: []const u8,
) ![]const u8 {
    if (storage_root.isActive(scope)) {
        var relative = path;
        while (std.mem.startsWith(u8, relative, "./")) relative = relative[2..];
        return relative;
    }
    if (!std.mem.startsWith(u8, path, root)) return error.InvalidPreparationPath;
    var relative = path[root.len..];
    if (!std.mem.startsWith(u8, relative, "/.ledger/")) return error.InvalidPreparationPath;
    relative = relative[9..];
    return relative;
}

fn completePrefix(prefix: []const u8, full: []const u8) bool {
    if (!std.mem.startsWith(u8, full, prefix)) return false;
    return prefix.len == full.len or prefix.len == 0 or prefix[prefix.len - 1] == '\n';
}

test "preparation prefix requires complete records and compatible native metadata" {
    const allocator = std.testing.allocator;
    var short: History = .{ .exists = true };
    defer short.deinit(allocator);
    var long: History = .{ .exists = true };
    defer long.deinit(allocator);
    try short.append(allocator, "events.jsonl", "{\"id\":1}\n", .{});
    try short.append(allocator, ".bindings/history.jsonl", "binding-one\n", .{});
    try short.append(allocator, ".definitions/one.json", "definition-one", .{});
    try long.append(allocator, "events.jsonl", "{\"id\":1}\n{\"id\":2}\n", .{});
    try long.append(allocator, ".bindings/history.jsonl", "binding-one\nbinding-two\n", .{});
    try long.append(allocator, ".definitions/one.json", "definition-one", .{});
    try std.testing.expect(long.covers(&short));
    try std.testing.expect(!short.covers(&long));
    long.files.items[2].bytes[0] = 'X';
    try std.testing.expect(!long.covers(&short));
    try std.testing.expect(!completePrefix("{\"id\":1}", "{\"id\":1}\n"));
}
