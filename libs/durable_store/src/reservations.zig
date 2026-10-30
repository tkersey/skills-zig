const std = @import("std");
const Fs = @import("fs_authority.zig").Fs;
const filesystem = @import("filesystem.zig");
const PrivateDirectory = @import("private_directory.zig").PrivateDirectory;
const publication = @import("staged_file.zig");
const transactions = @import("transactions.zig");
const codec = @import("record_codec.zig");

pub const TargetClass = enum { payload, metadata };

pub const TargetClassification = struct {
    path: []const u8,
    class: TargetClass,
};

pub const ClassifiedWrite = struct {
    path: []const u8,
    class: TargetClass,
    before_bytes: u64,
    after_bytes: u64,
};

pub const Binding = struct {
    transaction_id: []const u8,
    transaction_dir: []const u8,
    intent_digest: [32]u8,
    request_digest: [32]u8,
    final_state_digest: [32]u8,
    root_identity: filesystem.OpenDirectoryIdentity,
    before_bytes: u64,
    after_bytes: u64,
    target_class: TargetClass,
    target_usage_digest: [32]u8,
    before_metadata_bytes: u64,
    after_metadata_bytes: u64,
    publication_identity: ?[32]u8 = null,

    pub fn jsonStringify(self: Binding, output: *std.json.Stringify) !void {
        try output.beginObject();
        inline for (@typeInfo(Binding).@"struct".field_names) |field_name| {
            if (comptime !std.mem.eql(u8, field_name, "publication_identity")) {
                try output.objectField(field_name);
                try output.write(@field(self, field_name));
            }
        }
        if (self.publication_identity) |identity| {
            try output.objectField("publication_identity");
            try output.write(identity);
        }
        try output.endObject();
    }
};

pub const CommitOptions = struct {
    request: Request,
    reservation: Receipt,
    free_space: FreeSpaceObservation,
    target_class: TargetClass = .payload,
    target_classes: []const TargetClassification = &.{},
    transaction: codec.AcquireOptions,
    custody: ?*const transactions.TransactionPublicationCustody = null,
    publication_identity: ?[32]u8 = null,
};

pub const TerminalRecord = struct {
    schema: []const u8,
    budget_id: []const u8,
    store_id: []const u8,
    operation_id: []const u8,
    charge: Charge,
    binding: Binding,
    outcome: @FieldType(transactions.TransactionTerminal, "state"),
    generation: u64,
    added: Charge,
    removed: Charge,
    native_metadata_bytes: u64,
    terminal_bytes: u64,

    fn request(self: TerminalRecord) Request {
        return .{
            .budget_id = self.budget_id,
            .store_id = self.store_id,
            .operation_id = self.operation_id,
            .charge = self.charge,
        };
    }
};

pub const Charge = struct {
    logical_total: u64,
    staging: u64,
    metadata: u64,

    pub const zero: Charge = .{ .logical_total = 0, .staging = 0, .metadata = 0 };

    fn add(left: Charge, right: Charge) !Charge {
        return .{
            .logical_total = try sum(left.logical_total, right.logical_total),
            .staging = try sum(left.staging, right.staging),
            .metadata = try sum(left.metadata, right.metadata),
        };
    }

    fn within(self: Charge, limit: Charge) bool {
        return self.logical_total <= limit.logical_total and self.staging <= limit.staging and
            self.metadata <= limit.metadata;
    }

    fn equal(left: Charge, right: Charge) bool {
        return left.logical_total == right.logical_total and left.staging == right.staging and
            left.metadata == right.metadata;
    }

    fn physicalPeak(self: Charge) !u64 {
        try self.validate();
        return self.logical_total;
    }

    fn validate(self: Charge) !void {
        if (try sum(self.staging, self.metadata) > self.logical_total) {
            return error.InvalidReservationCharge;
        }
    }
};

pub const Policy = struct {
    limits: Charge,
    free_space_scope_id: []const u8,
    minimum_free_bytes: u64,
    recovery_reserve_bytes: u64,
    max_observation_age_ms: u64,
};

pub const Store = struct {
    store_id: []const u8,
    used: Charge,
    limits: Charge,
    association: ?transactions.TransactionBudgetSource = null,
};

pub const FreeSpaceObservation = struct {
    scope_id: []const u8,
    available_bytes: u64,
    observed_at_ms: u64,
};

pub const Request = struct {
    budget_id: []const u8,
    store_id: []const u8,
    operation_id: []const u8,
    charge: Charge,
};

pub const Restart = struct {
    terminal_generation: u64,
    terminal_digest: [32]u8,
    terminal_bytes: u64,
    final_state_digest: [32]u8,
    root_identity: filesystem.OpenDirectoryIdentity,
    publication_identity: ?[32]u8 = null,
};

pub const Record = struct {
    store_id: []const u8,
    operation_id: []const u8,
    charge: Charge,
    generation: u64,
    binding: ?Binding = null,
    preparing_record: ?[]const u8 = null,
    target_usage: []const ClassifiedWrite = &.{},
    restart: ?Restart = null,
};

pub const Receipt = struct {
    generation: u64,
    policy_generation: u64,
    charge: Charge,
    reused: bool,
    status: enum { reserved, committed, aborted } = .reserved,
};

pub const State = struct {
    schema: []const u8,
    budget_id: []const u8,
    generation: u64,
    policy_generation: u64,
    policy: Policy,
    stores: []const Store,
    reservations: []const Record,
};

pub const Snapshot = struct {
    parsed: std.json.Parsed(State),
    used: Charge,
    reserved: Charge,
    control_reserved: Charge = Budget.control_charge,

    pub fn deinit(self: *Snapshot) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const DependencyOptions = struct {
    budget_id: []const u8,
    store_id: []const u8,
    limits: transactions.TransactionDependencyLimits = .{},
};

pub const DependencyEvidence = struct {
    kind: enum { reservation_terminal, budget_association },
    transaction_id: []const u8,
    bytes: []const u8,
};

pub const DependencySnapshot = struct {
    transactions: transactions.TransactionDependencySnapshot,
    budget_id: []const u8,
    store_id: []const u8,
    budget_generation: u64,
    budget_root_identity: filesystem.OpenDirectoryIdentity,
    pending: bool = false,
    unbound_reservations: usize = 0,
    disjoint_intents: usize = 0,
    pending_intents: usize = 0,
    settled_transactions: usize = 0,
    metadata_bytes_read: usize = 0,
    budget_bytes_read: usize = 0,
    evidence: []const DependencyEvidence = &.{},
    coverage: enum { supplied_budget_store } = .supplied_budget_store,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *DependencySnapshot, allocator: std.mem.Allocator) void {
        self.transactions.deinit(allocator);
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Budget = struct {
    root: PrivateDirectory,

    pub const max_state_bytes = 1024 * 1024;
    pub const max_stores = 128;
    pub const max_reservations = 1024;
    pub const max_identity_bytes = 256;
    pub const max_terminal_bytes = 16 * 1024;
    pub const association_charge: Charge = .{
        .logical_total = 2 * transactions.transaction_budget_association_max_bytes,
        .staging = transactions.transaction_budget_association_max_bytes,
        .metadata = transactions.transaction_budget_association_max_bytes,
    };
    pub const control_charge: Charge = .{
        .logical_total = 4 * max_state_bytes + max_terminal_bytes + 8192 +
            max_stores * association_charge.logical_total,
        .staging = 2 * max_state_bytes + max_terminal_bytes +
            max_stores * association_charge.staging,
        .metadata = 2 * max_state_bytes + 8192 + max_stores * association_charge.metadata,
    };
    const state_leaf = "reservations.json";
    const staging_leaf = "reservation-staging";
    const lock_leaf = "budget-control";
    const terminal_leaf = "reservation-terminal";
    const accounting_leaf = "accounting-transactions";

    pub fn open(fs: Fs, path: []const u8) !Budget {
        return .{ .root = try PrivateDirectory.open(fs, path, .read_only) };
    }

    pub fn deinit(self: *Budget) void {
        self.root.deinit();
        self.* = undefined;
    }

    pub fn initialize(
        fs: Fs,
        allocator: std.mem.Allocator,
        path: []const u8,
        budget_id: []const u8,
        policy: Policy,
        stores: []const Store,
        free: FreeSpaceObservation,
    ) !Budget {
        const state: State = .{
            .schema = "durable-reservation-budget/v1",
            .budget_id = budget_id,
            .generation = 1,
            .policy_generation = 1,
            .policy = policy,
            .stores = stores,
            .reservations = &.{},
        };
        try validateState(state);
        try admitGrowth(fs, state, free);
        var self = try Budget.open(fs, path);
        errdefer self.deinit();
        var lock = try self.exclusive(allocator);
        defer lock.close(fs.io);
        if (try filesystem.statRegularFileNoSymlink(self.authority(), state_leaf) != null) {
            return error.ReservationBudgetExists;
        }
        var staging = try self.root.openChild(staging_leaf, .create);
        defer staging.deinit();
        var terminals = try self.root.openChild(terminal_leaf, .create);
        defer terminals.deinit();
        var accounting = try self.root.openChild(accounting_leaf, .create);
        defer accounting.deinit();
        try self.publish(allocator, state);
        return self;
    }

    pub fn inspect(self: *Budget, allocator: std.mem.Allocator) !Snapshot {
        if (!try filesystem.casAdvisoryLockExists(self.authority(), allocator, lock_leaf)) {
            return error.ReservationCoordinationUnavailable;
        }
        var locks = try filesystem.acquireCasReadLockPair(
            self.authority(),
            allocator,
            lock_leaf,
            lock_leaf,
        );
        defer locks.deinit();
        if (locks.count != 1) return error.ReservationCoordinationUnavailable;
        const path = try self.absoluteChild(allocator, accounting_leaf);
        defer allocator.free(path);
        if (try transactions.countPendingTransactions(self.authority(), allocator, path) != 0) {
            return error.ReservationRecoveryRequired;
        }
        return self.load(allocator);
    }

    pub fn snapshotDependencies(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        transactions_dir: []const u8,
        selected_paths: []const []const u8,
        location: ?transactions.TransactionDependencyLocation,
        options: DependencyOptions,
    ) !DependencySnapshot {
        const ceilings: transactions.TransactionDependencyLimits = .{};
        if (options.limits.journal_bytes > ceilings.journal_bytes) return error.ReservationLimit;
        var remaining = options.limits.journal_bytes;
        var discovery = try self.inspectDependencyBudget(allocator, &remaining);
        defer discovery.deinit();
        try validateDependencyContext(discovery.parsed.value, options);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const preparations = try dependencyPreparations(
            arena.allocator(),
            discovery.parsed.value,
            options.store_id,
            options.limits.preparations,
        );
        const budget_discovery_bytes = options.limits.journal_bytes - remaining;
        var limits = options.limits;
        limits.journal_bytes = remaining;
        var native = try transactions.snapshotTransactionDependenciesWithBudgetAt(
            store_fs,
            allocator,
            transactions_dir,
            selected_paths,
            location,
            preparations,
            try self.dependencyContext(options),
            limits,
        );
        errdefer native.deinit(allocator);
        remaining -= native.journal_bytes_read;
        const before_reread = remaining;
        var current = try self.inspectDependencyBudget(allocator, &remaining);
        defer current.deinit();
        try validateDependencyContext(current.parsed.value, options);
        try validateSourceAssociation(allocator, current.parsed.value, options, native);
        var result: DependencySnapshot = .{
            .transactions = native,
            .budget_id = try arena.allocator().dupe(u8, options.budget_id),
            .store_id = try arena.allocator().dupe(u8, options.store_id),
            .budget_generation = current.parsed.value.generation,
            .budget_root_identity = try filesystem.openDirectoryIdentity(
                self.root.io,
                self.root.directory,
            ),
            .budget_bytes_read = budget_discovery_bytes + before_reread - remaining,
            .arena = arena,
        };
        arena = .init(allocator);
        errdefer result.arena.deinit();
        try self.finishDependencySnapshot(
            allocator,
            current.parsed.value,
            options,
            &remaining,
            &result,
        );
        result.metadata_bytes_read = options.limits.journal_bytes - remaining;
        return result;
    }

    fn dependencyContext(
        self: *Budget,
        options: DependencyOptions,
    ) !transactions.TransactionBudgetContext {
        return .{
            .budget_id = options.budget_id,
            .store_id = options.store_id,
            .budget_root = try filesystem.openDirectoryIdentity(self.root.io, self.root.directory),
        };
    }

    fn inspectDependencyBudget(
        self: *Budget,
        allocator: std.mem.Allocator,
        remaining: *usize,
    ) !Snapshot {
        if (!try filesystem.casAdvisoryLockExists(self.authority(), allocator, lock_leaf)) {
            return error.ReservationCoordinationUnavailable;
        }
        var locks = try filesystem.acquireCasReadLockPair(
            self.authority(),
            allocator,
            lock_leaf,
            lock_leaf,
        );
        defer locks.deinit();
        if (locks.count != 1) return error.ReservationCoordinationUnavailable;
        if (try transactions.countPendingTransactionsWithReadBudget(
            self.authority(),
            allocator,
            accounting_leaf,
            remaining,
        ) != 0) return error.ReservationRecoveryRequired;
        return self.loadWithReadBudget(allocator, remaining);
    }

    fn finishDependencySnapshot(
        self: *Budget,
        allocator: std.mem.Allocator,
        state: State,
        options: DependencyOptions,
        remaining: *usize,
        result: *DependencySnapshot,
    ) !void {
        var checks_remaining = options.limits.identity_checks -
            result.transactions.identity_checks_used;
        for (state.reservations) |row| {
            if (!std.mem.eql(u8, row.store_id, options.store_id)) continue;
            if (row.binding == null) {
                result.unbound_reservations += 1;
                continue;
            }
            const preparation = try dependencyPreparation(
                result.arena.allocator(),
                state.budget_id,
                row,
            );
            if (preparation.preparation.record.len > remaining.*) return error.ReservationLimit;
            remaining.* -= preparation.preparation.record.len;
            if (try result.transactions.preparationIntersects(
                allocator,
                preparation,
                &checks_remaining,
            )) {
                result.pending_intents += 1;
                result.pending = true;
            } else result.disjoint_intents += 1;
        }
        var evidence: std.ArrayList(DependencyEvidence) = .empty;
        for (result.transactions.transactions) |transaction| {
            if (transaction.state != .committed and transaction.state != .aborted) {
                result.pending = true;
            }
            var publication_view = (try result.transactions.readPublication(
                allocator,
                transaction,
                remaining,
            )) orelse continue;
            defer publication_view.deinit(allocator);
            try self.inspectDependencyPublication(
                state,
                remaining,
                result,
                publication_view,
                &evidence,
            );
        }
        if (result.transactions.budget_association) |bytes| {
            try evidence.append(result.arena.allocator(), .{
                .kind = .budget_association,
                .transaction_id = "",
                .bytes = try result.arena.allocator().dupe(u8, bytes),
            });
        }
        result.evidence = try evidence.toOwnedSlice(result.arena.allocator());
    }

    fn inspectDependencyPublication(
        self: *Budget,
        state: State,
        remaining: *usize,
        result: *DependencySnapshot,
        publication_view: transactions.TransactionDependencyPublication,
        evidence: *std.ArrayList(DependencyEvidence),
    ) !void {
        const allocator = result.arena.allocator();
        var pin = try parseReservationPin(allocator, publication_view.pin);
        defer pin.deinit();
        if (!std.mem.eql(u8, pin.value.budget_id, result.budget_id) or
            !std.mem.eql(u8, pin.value.store_id, result.store_id))
        {
            return error.ReservationIdentityMismatch;
        }
        for (state.reservations) |row| {
            if (!std.mem.eql(u8, row.operation_id, pin.value.operation_id)) continue;
            const binding = row.binding orelse return error.ReservationRecoveryRequired;
            if (!std.mem.eql(u8, row.store_id, result.store_id)) {
                return error.ReservationIdentityMismatch;
            }
            try result.transactions.validatePublicationBinding(
                allocator,
                publication_view,
                binding.transaction_dir,
                binding.intent_digest,
                binding.root_identity,
            );
            const expected = try renderPin(
                allocator,
                .{
                    .budget_id = result.budget_id,
                    .store_id = row.store_id,
                    .operation_id = row.operation_id,
                    .charge = row.charge,
                },
                binding,
            );
            if (!std.mem.eql(u8, expected, publication_view.pin)) {
                return error.ReservationIdentityMismatch;
            }
            result.pending = true;
            return;
        }
        try self.inspectDependencyTerminal(
            state,
            remaining,
            result,
            publication_view,
            pin.value,
            evidence,
        );
    }

    fn inspectDependencyTerminal(
        self: *Budget,
        state: State,
        remaining: *usize,
        result: *DependencySnapshot,
        publication_view: transactions.TransactionDependencyPublication,
        pin: ReservationPin,
        evidence: *std.ArrayList(DependencyEvidence),
    ) !void {
        const allocator = result.arena.allocator();
        const bytes = try self.readDependencyTerminal(allocator, pin, remaining);
        var terminal = try parseTerminalBytes(allocator, bytes);
        defer terminal.deinit();
        const row = terminal.value;
        const expected = try renderPin(allocator, row.request(), row.binding);
        if (!std.mem.eql(u8, expected, publication_view.pin) or
            !std.mem.eql(u8, row.binding.transaction_id, publication_view.transaction_id))
        {
            return error.ReservationIdentityMismatch;
        }
        try result.transactions.validatePublicationBinding(
            allocator,
            publication_view,
            row.binding.transaction_dir,
            row.binding.intent_digest,
            row.binding.root_identity,
        );
        _ = try terminalReceipt(state, row);
        if ((row.outcome == .committed and publication_view.state != .committed) or
            (row.outcome == .aborted and publication_view.state != .aborted))
        {
            return error.ReservationRecoveryRequired;
        }
        try evidence.append(
            allocator,
            .{
                .kind = .reservation_terminal,
                .transaction_id = try allocator.dupe(
                    u8,
                    publication_view.transaction_id,
                ),
                .bytes = bytes,
            },
        );
        result.settled_transactions += 1;
    }

    fn readDependencyTerminal(
        self: *Budget,
        allocator: std.mem.Allocator,
        pin: ReservationPin,
        remaining: *usize,
    ) ![]u8 {
        var dir = try self.root.openChild(terminal_leaf, .read_only);
        defer dir.deinit();
        const name = terminalName(.{
            .budget_id = pin.budget_id,
            .store_id = pin.store_id,
            .operation_id = pin.operation_id,
            .charge = .zero,
        });
        return readBudgetDependencyBytes(
            &dir,
            allocator,
            &name,
            max_terminal_bytes,
            remaining,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.ReservationRecoveryRequired,
            else => return err,
        };
    }

    pub fn reserve(
        self: *Budget,
        allocator: std.mem.Allocator,
        request: Request,
        free: FreeSpaceObservation,
    ) !Receipt {
        return self.change(allocator, request, free, .reserve);
    }

    pub fn extend(
        self: *Budget,
        allocator: std.mem.Allocator,
        request: Request,
        free: FreeSpaceObservation,
    ) !Receipt {
        return self.change(allocator, request, free, .extend);
    }

    pub fn transactionCharge(after_bytes: u64, after_metadata_bytes: u64) !Charge {
        if (after_metadata_bytes > after_bytes) return error.InvalidReservationCharge;
        const overhead = try sum(
            transactions.reserved_transaction_metadata_max_bytes,
            max_terminal_bytes,
        );
        return .{
            .logical_total = try sum(try sum(after_bytes, after_bytes), overhead),
            .staging = after_bytes,
            .metadata = try sum(overhead, after_metadata_bytes),
        };
    }

    pub fn commitReserved(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        transactions_dir: []const u8,
        mutations: []const codec.TransactionMutation,
        options: CommitOptions,
    ) !transactions.ControlledTransactionReceipt {
        if (!std.fs.path.isAbsolute(transactions_dir) and !store_fs.isPinned()) {
            return error.NotAbsolute;
        }
        if (options.custody) |custody| try custody.validate(store_fs, transactions_dir);
        const digest = try requestDigest(mutations, options);
        const prior = try self.committedRetry(
            allocator,
            store_fs,
            transactions_dir,
            options,
            digest,
        );
        if (prior) |result| return result;
        try self.associateSource(allocator, store_fs, transactions_dir, options);
        if (try self.resumeBoundCommit(allocator, store_fs, options, digest)) |result| {
            return result;
        }
        return self.commitUnbound(
            allocator,
            store_fs,
            transactions_dir,
            mutations,
            options,
            digest,
        );
    }
    fn resumeBoundCommit(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        options: CommitOptions,
        digest: [32]u8,
    ) !?transactions.ControlledTransactionReceipt {
        var reconcile_bound = false;
        {
            var lock = try self.exclusive(allocator);
            defer lock.close(self.root.io);
            var snapshot = try self.load(allocator);
            defer snapshot.deinit();
            if (try self.readEffectiveTerminal(
                allocator,
                snapshot.parsed.value,
                options.request,
            )) |terminal| {
                defer terminal.deinit();
                try requirePublicationIdentity(
                    terminal.value.binding.publication_identity,
                    options.publication_identity,
                );
                if (!std.mem.eql(u8, &digest, &terminal.value.binding.request_digest)) {
                    return error.ReservationIdentityMismatch;
                }
                try transactions.validatePublicationRoot(
                    store_fs,
                    terminal.value.binding.transaction_dir,
                    terminal.value.binding.root_identity,
                );
                _ = try terminalReceipt(snapshot.parsed.value, terminal.value);
                return try terminalResult(allocator, terminal.value);
            }
            const row = try validateReservation(
                snapshot.parsed.value,
                options.request,
                options.reservation,
            );
            if (row.restart) |restart| {
                try requirePublicationIdentity(
                    restart.publication_identity,
                    options.publication_identity,
                );
            }
            if (row.binding) |binding| {
                try requirePublicationIdentity(
                    binding.publication_identity,
                    options.publication_identity,
                );
                if (!std.meta.eql(binding.request_digest, digest)) {
                    return error.ReservationIdentityMismatch;
                }
                reconcile_bound = true;
            }
        }
        if (reconcile_bound) {
            if (options.custody != null) return error.ReservationRecoveryRequired;
            return try self.reconcilePublicationIdentity(
                allocator,
                store_fs,
                options.request,
                options.free_space,
                options.publication_identity,
            );
        }
        return null;
    }

    fn committedRetry(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        transactions_dir: []const u8,
        options: CommitOptions,
        digest: [32]u8,
    ) !?transactions.ControlledTransactionReceipt {
        const prior = try self.readCommitTerminal(allocator, store_fs, options, digest) orelse
            return null;
        var result = prior.result;
        errdefer result.transaction.deinit(allocator);
        if (prior.source) |source| {
            transactions.validateTransactionBudgetAt(
                store_fs,
                allocator,
                transactions_dir,
                source,
                try self.dependencyContext(.{
                    .budget_id = options.request.budget_id,
                    .store_id = options.request.store_id,
                }),
            ) catch |err| {
                if (err == error.TransactionReservationMismatch) return err;
                result.failure = err;
            };
        } else result.failure = error.TransactionDependencyBudgetMismatch;
        return result;
    }

    fn readCommitTerminal(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        options: CommitOptions,
        digest: [32]u8,
    ) !?struct {
        result: transactions.ControlledTransactionReceipt,
        source: ?transactions.TransactionBudgetSource,
    } {
        var lock = try self.exclusive(allocator);
        defer lock.close(self.root.io);
        var snapshot = try self.load(allocator);
        defer snapshot.deinit();
        const state = snapshot.parsed.value;
        const terminal = try self.readEffectiveTerminal(allocator, state, options.request) orelse
            return null;
        defer terminal.deinit();
        try requirePublicationIdentity(
            terminal.value.binding.publication_identity,
            options.publication_identity,
        );
        if (!std.meta.eql(digest, terminal.value.binding.request_digest)) {
            return error.ReservationIdentityMismatch;
        }
        try transactions.validatePublicationRoot(
            store_fs,
            terminal.value.binding.transaction_dir,
            terminal.value.binding.root_identity,
        );
        _ = try terminalReceipt(state, terminal.value);
        return .{
            .result = try terminalResult(allocator, terminal.value),
            .source = (try findStore(state, options.request.store_id)).association,
        };
    }

    fn commitUnbound(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        transactions_dir: []const u8,
        mutations: []const codec.TransactionMutation,
        options: CommitOptions,
        digest: [32]u8,
    ) !transactions.ControlledTransactionReceipt {
        var custody = try transactions.TransactionBudgetCustody.acquireRead(
            store_fs,
            allocator,
            transactions_dir,
        );
        defer custody.deinit();
        try custody.validate(allocator, try self.dependencyContext(.{
            .budget_id = options.request.budget_id,
            .store_id = options.request.store_id,
        }));
        var context: PublicationContext = .{
            .budget = self,
            .store_fs = store_fs,
            .allocator = allocator,
            .options = options,
            .request_digest = digest,
            .source = custody.source,
        };
        defer context.deinit();
        return transactions.commitTextTransactionControlled(
            store_fs,
            allocator,
            transactions_dir,
            mutations,
            options.transaction,
            .{ .publication = context.hooks(), .custody = options.custody },
        );
    }

    pub fn associateSource(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        transactions_dir: []const u8,
        options: CommitOptions,
    ) !void {
        const admission = try self.associationAdmission(allocator, options);
        if (options.custody) |held| {
            const expected = admission.source orelse return error.ReservationAssociationRequired;
            if (!std.meta.eql(expected, held.source)) return error.TransactionReservationMismatch;
            return self.validateHeldAssociation(
                allocator,
                store_fs,
                transactions_dir,
                options,
                expected,
            );
        }
        var custody = try transactions.TransactionBudgetCustody.acquire(
            store_fs,
            allocator,
            transactions_dir,
            admission.source,
        );
        defer custody.deinit();
        {
            var lock = try self.exclusive(allocator);
            defer lock.close(self.root.io);
            var snapshot = try self.load(allocator);
            defer snapshot.deinit();
            var state = snapshot.parsed.value;
            if (!std.mem.eql(u8, state.budget_id, options.request.budget_id)) {
                return error.ReservationIdentityMismatch;
            }
            const store = try findStore(state, options.request.store_id);
            if (store.association) |source| {
                if (!std.meta.eql(source, custody.source)) {
                    return error.TransactionReservationMismatch;
                }
                if (!admission.terminal) try self.syncState();
            } else {
                _ = try validateReservation(state, options.request, options.reservation);
                try custody.requireUnassociated();
                const stores = try allocator.dupe(Store, state.stores);
                defer allocator.free(stores);
                for (stores) |*candidate| {
                    if (std.mem.eql(u8, candidate.store_id, store.store_id)) {
                        candidate.association = custody.source;
                    }
                }
                state.stores = stores;
                state.generation = try sum(state.generation, 1);
                try admitGrowth(self.authority(), state, options.free_space);
                try self.publish(allocator, state);
            }
        }
        try self.publishSourceAssociation(allocator, &custody, options, admission.terminal);
    }

    fn publishSourceAssociation(
        self: *Budget,
        allocator: std.mem.Allocator,
        custody: *transactions.TransactionBudgetCustody,
        options: CommitOptions,
        terminal: bool,
    ) !void {
        const context = try self.dependencyContext(.{
            .budget_id = options.request.budget_id,
            .store_id = options.request.store_id,
        });
        if (terminal) return custody.validate(allocator, context);
        var storage_mutated = false;
        try transactions.ensureTransactionDependencyCoordination(
            Fs.anchored(custody.fs.io, custody.directory),
            allocator,
            ".",
            &storage_mutated,
        );
        try custody.publish(allocator, context);
    }

    fn validateHeldAssociation(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        transactions_dir: []const u8,
        options: CommitOptions,
        expected: transactions.TransactionBudgetSource,
    ) !void {
        return transactions.validateTransactionBudgetAt(
            store_fs,
            allocator,
            transactions_dir,
            expected,
            try self.dependencyContext(.{
                .budget_id = options.request.budget_id,
                .store_id = options.request.store_id,
            }),
        );
    }

    fn associationAdmission(
        self: *Budget,
        allocator: std.mem.Allocator,
        options: CommitOptions,
    ) !struct {
        source: ?transactions.TransactionBudgetSource,
        terminal: bool,
    } {
        var lock = try self.exclusive(allocator);
        defer lock.close(self.root.io);
        var snapshot = try self.load(allocator);
        defer snapshot.deinit();
        const state = snapshot.parsed.value;
        if (try self.readEffectiveTerminal(allocator, state, options.request)) |terminal| {
            defer terminal.deinit();
            _ = try terminalReceipt(state, terminal.value);
            return .{
                .source = (try findStore(state, options.request.store_id)).association,
                .terminal = true,
            };
        }
        _ = try validateReservation(state, options.request, options.reservation);
        return .{
            .source = (try findStore(state, options.request.store_id)).association,
            .terminal = false,
        };
    }

    pub fn observedOutcome(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        request: Request,
    ) !?transactions.ControlledTransactionReceipt {
        return self.observePublication(allocator, store_fs, request, null);
    }

    pub fn observedPublication(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        request: Request,
        identity: [32]u8,
    ) !?transactions.ControlledTransactionReceipt {
        return self.observePublication(allocator, store_fs, request, identity);
    }

    fn observePublication(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        request: Request,
        identity: ?[32]u8,
    ) !?transactions.ControlledTransactionReceipt {
        var lock = try self.exclusive(allocator);
        defer lock.close(self.root.io);
        var snapshot = try self.load(allocator);
        defer snapshot.deinit();
        try validateRecordPublication(snapshot.parsed.value, request, identity);
        const terminal = try self.readEffectiveTerminal(
            allocator,
            snapshot.parsed.value,
            request,
        ) orelse
            return null;
        defer terminal.deinit();
        try validatePublicationIdentity(terminal.value.binding.publication_identity, identity);
        try transactions.validatePublicationRoot(
            store_fs,
            terminal.value.binding.transaction_dir,
            terminal.value.binding.root_identity,
        );
        _ = try terminalReceipt(snapshot.parsed.value, terminal.value);
        return try terminalResult(allocator, terminal.value);
    }

    pub fn reconcile(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        request: Request,
        free: FreeSpaceObservation,
    ) !transactions.ControlledTransactionReceipt {
        return self.reconcilePublicationIdentity(allocator, store_fs, request, free, null);
    }

    pub fn reconcilePublication(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        request: Request,
        free: FreeSpaceObservation,
        identity: [32]u8,
    ) !transactions.ControlledTransactionReceipt {
        return self.reconcilePublicationIdentity(allocator, store_fs, request, free, identity);
    }

    fn reconcilePublicationIdentity(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        request: Request,
        free: FreeSpaceObservation,
        identity: ?[32]u8,
    ) !transactions.ControlledTransactionReceipt {
        var lock = try self.exclusive(allocator);
        var locked = true;
        defer if (locked) lock.close(self.root.io);
        var snapshot = try self.load(allocator);
        defer snapshot.deinit();
        try validateRecordPublication(snapshot.parsed.value, request, identity);
        if (try self.readEffectiveTerminal(allocator, snapshot.parsed.value, request)) |terminal| {
            defer terminal.deinit();
            const binding = terminal.value.binding;
            const root = binding.root_identity;
            try validatePublicationIdentity(binding.publication_identity, identity);
            try transactions.validatePublicationRoot(store_fs, binding.transaction_dir, root);
            _ = try terminalReceipt(snapshot.parsed.value, terminal.value);
            return terminalResult(allocator, terminal.value);
        }
        const row = (try findRecord(snapshot.parsed.value, request)) orelse
            return error.ReservationNotFound;
        const binding = row.binding orelse return error.ReservationUnbound;
        var context: PublicationContext = .{
            .budget = self,
            .store_fs = store_fs,
            .allocator = allocator,
            .options = .{
                .request = request,
                .reservation = receipt(snapshot.parsed.value, row, true),
                .free_space = free,
                .target_class = binding.target_class,
                .transaction = .{ .owner = accountingOwner(request) },
                .publication_identity = binding.publication_identity,
            },
            .request_digest = binding.request_digest,
            .binding = binding,
            .preparing_record = row.preparing_record,
            .target_usage = row.target_usage,
            .pin = try renderPin(allocator, request, binding),
        };
        defer context.deinit();
        var result = try pendingResult(allocator, binding);
        errdefer result.transaction.deinit(allocator);
        locked = false;
        lock.close(self.root.io);
        const recovered = transactions.recoverTransactionWithPublication(
            store_fs,
            allocator,
            binding.transaction_dir,
            context.hooks(),
        ) catch |err| {
            result.failure = err;
            if (context.terminal_seen) |terminal| {
                result.semantic = if (terminal == .committed) .committed else .aborted;
                result.transaction.state = if (terminal == .committed) .committed else .aborted;
                if (!context.accounted) result.accounting_error = err;
            }
            return result;
        };
        recovered.deinit(allocator);
        const terminal = context.terminal_seen orelse return error.TransactionRecoveryRequired;
        result.semantic = if (terminal == .committed) .committed else .aborted;
        result.transaction.state = if (terminal == .committed) .committed else .aborted;
        return result;
    }

    pub fn restartAborted(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        request: Request,
        free: FreeSpaceObservation,
    ) !Receipt {
        return self.restartPublication(allocator, store_fs, request, free, null);
    }

    pub fn restartAbortedPublication(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        request: Request,
        free: FreeSpaceObservation,
        identity: [32]u8,
    ) !Receipt {
        return self.restartPublication(allocator, store_fs, request, free, identity);
    }

    fn restartPublication(
        self: *Budget,
        allocator: std.mem.Allocator,
        store_fs: Fs,
        request: Request,
        free: FreeSpaceObservation,
        identity: ?[32]u8,
    ) !Receipt {
        const prior = initial: {
            var lock = try self.exclusive(allocator);
            defer lock.close(self.root.io);
            var snapshot = try self.load(allocator);
            defer snapshot.deinit();
            const terminal = (try self.readTerminal(allocator, request)) orelse
                return error.ReservationNotFound;
            errdefer terminal.deinit();
            try validatePublicationIdentity(terminal.value.binding.publication_identity, identity);
            try transactions.validatePublicationRoot(
                store_fs,
                terminal.value.binding.transaction_dir,
                terminal.value.binding.root_identity,
            );
            if (try findRecord(snapshot.parsed.value, request)) |row| {
                try validateRestartTerminal(row, terminal.value);
                terminal.deinit();
                return receipt(snapshot.parsed.value, row, true);
            }
            const previous = try terminalReceipt(snapshot.parsed.value, terminal.value);
            if (terminal.value.outcome == .committed) {
                terminal.deinit();
                return previous;
            }
            break :initial terminal;
        };
        defer prior.deinit();
        const pin = try renderPin(allocator, request, prior.value.binding);
        defer allocator.free(pin);
        var retirement = try transactions.prepareAbortedTransactionRetirement(
            store_fs,
            allocator,
            prior.value.binding.transaction_dir,
            .{
                .root_identity = prior.value.binding.root_identity,
                .intent_digest = prior.value.binding.intent_digest,
                .pin = pin,
                .metadata_bytes = prior.value.native_metadata_bytes,
            },
        );
        defer retirement.deinit();
        var lock = try self.exclusive(allocator);
        defer lock.close(self.root.io);
        return self.rearmAborted(allocator, request, free, prior.value, &retirement);
    }

    fn rearmAborted(
        self: *Budget,
        allocator: std.mem.Allocator,
        request: Request,
        free: FreeSpaceObservation,
        prior: TerminalRecord,
        retirement: *transactions.AbortedTransactionRetirement,
    ) !Receipt {
        var snapshot = try self.load(allocator);
        defer snapshot.deinit();
        var state = snapshot.parsed.value;
        const terminal = (try self.readTerminal(allocator, request)) orelse
            return error.ReservationRecoveryRequired;
        defer terminal.deinit();
        if (!std.meta.eql(try hashValue(prior), try hashValue(terminal.value))) {
            return error.ReservationChanged;
        }
        if (try findRecord(state, request)) |row| {
            try validateRestartTerminal(row, prior);
            return receipt(state, row, true);
        }
        _ = try terminalReceipt(state, prior);
        if (state.reservations.len == max_reservations) return error.ReservationLimit;
        const rows = try allocator.alloc(Record, state.reservations.len + 1);
        defer allocator.free(rows);
        @memcpy(rows[0..state.reservations.len], state.reservations);
        state.generation = try sum(state.generation, 1);
        const row: Record = .{
            .store_id = request.store_id,
            .operation_id = request.operation_id,
            .charge = request.charge,
            .generation = state.generation,
            .restart = .{
                .terminal_generation = prior.generation,
                .terminal_digest = try hashValue(prior),
                .terminal_bytes = prior.terminal_bytes,
                .final_state_digest = prior.binding.final_state_digest,
                .root_identity = prior.binding.root_identity,
                .publication_identity = prior.binding.publication_identity,
            },
        };
        rows[rows.len - 1] = row;
        state.reservations = rows;
        const stores = try allocator.dupe(Store, state.stores);
        defer allocator.free(stores);
        for (stores) |*store| {
            if (!std.mem.eql(u8, store.store_id, request.store_id)) continue;
            store.used = try subtractCharge(store.used, .{
                .logical_total = prior.native_metadata_bytes,
                .staging = 0,
                .metadata = prior.native_metadata_bytes,
            });
        }
        state.stores = stores;
        try admitGrowth(self.authority(), state, free);
        try retirement.finish();
        try self.publish(allocator, state);
        return receipt(state, row, false);
    }

    fn readEffectiveTerminal(
        self: *Budget,
        allocator: std.mem.Allocator,
        state: State,
        request: Request,
    ) !?std.json.Parsed(TerminalRecord) {
        const row = try findRecord(state, request);
        const terminal = try self.readTerminal(allocator, request);
        if (row != null and row.?.restart != null) {
            const old = terminal orelse return error.ReservationRecoveryRequired;
            defer old.deinit();
            try validateRestartTerminal(row.?, old.value);
            return null;
        }
        return terminal;
    }

    pub fn updatePolicy(
        self: *Budget,
        allocator: std.mem.Allocator,
        budget_id: []const u8,
        expected_generation: u64,
        policy: Policy,
        store_limits: []const Charge,
    ) !void {
        var lock = try self.exclusive(allocator);
        defer lock.close(self.root.io);
        var snapshot = try self.load(allocator);
        defer snapshot.deinit();
        var state = snapshot.parsed.value;
        if (!std.mem.eql(u8, state.budget_id, budget_id)) return error.ReservationIdentityMismatch;
        if (state.generation != expected_generation) return error.ReservationChanged;
        if (store_limits.len != state.stores.len) return error.ReservationIdentityMismatch;
        if (!std.mem.eql(u8, policy.free_space_scope_id, state.policy.free_space_scope_id)) {
            return error.ReservationIdentityMismatch;
        }
        const stores = try allocator.dupe(Store, state.stores);
        defer allocator.free(stores);
        for (stores, store_limits) |*store, limits| store.limits = limits;
        state.stores = stores;
        state.policy = policy;
        state.generation = try sum(state.generation, 1);
        state.policy_generation = state.generation;
        try validateState(state);
        try self.publish(allocator, state);
    }

    fn authority(self: *Budget) Fs {
        return .anchored(self.root.io, self.root.directory);
    }

    fn exclusive(self: *Budget, allocator: std.mem.Allocator) !std.Io.File {
        const lock = try filesystem.acquireCasAdvisoryLock(self.authority(), allocator, lock_leaf);
        errdefer lock.close(self.root.io);
        if (try filesystem.statRegularFileNoSymlink(self.authority(), state_leaf) != null) {
            try self.recoverAccounting(allocator);
        }
        return lock;
    }

    fn absoluteChild(self: *Budget, allocator: std.mem.Allocator, child: []const u8) ![]u8 {
        const root = try self.root.directory.realPathFileAlloc(self.root.io, ".", allocator);
        defer allocator.free(root);
        return std.fs.path.join(allocator, &.{ root, child });
    }

    fn recoverAccounting(self: *Budget, allocator: std.mem.Allocator) !void {
        const path = try self.absoluteChild(allocator, accounting_leaf);
        defer allocator.free(path);
        try transactions.recoverAndCompactTransactions(self.authority(), allocator, path);
    }

    fn readTerminal(
        self: *Budget,
        allocator: std.mem.Allocator,
        request: Request,
    ) !?std.json.Parsed(TerminalRecord) {
        var dir = try self.root.openChild(terminal_leaf, .read_only);
        defer dir.deinit();
        const name = terminalName(request);
        const bytes = dir.readAlloc(allocator, &name, max_terminal_bytes) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(bytes);
        const parsed = try parseTerminalBytes(allocator, bytes);
        errdefer parsed.deinit();
        const row = parsed.value;
        if (!std.mem.eql(u8, row.budget_id, request.budget_id) or
            !std.mem.eql(u8, row.store_id, request.store_id) or
            !std.mem.eql(u8, row.operation_id, request.operation_id) or
            !row.charge.equal(request.charge)) return error.ReservationIdentityMismatch;
        return parsed;
    }

    fn commitAccounting(
        self: *Budget,
        allocator: std.mem.Allocator,
        state: State,
        terminal: TerminalRecord,
        restart: ?Restart,
    ) !void {
        const state_bytes = try std.json.Stringify.valueAlloc(allocator, state, .{});
        defer allocator.free(state_bytes);
        if (state_bytes.len > max_state_bytes) return error.ReservationLimit;
        const terminal_bytes = try std.json.Stringify.valueAlloc(allocator, terminal, .{});
        defer allocator.free(terminal_bytes);
        if (terminal_bytes.len != terminal.terminal_bytes) return error.ReservationCorrupt;
        const current = try self.root.readAlloc(allocator, state_leaf, max_state_bytes);
        defer allocator.free(current);
        const expected = try codec.digestBytesAlloc(allocator, current);
        defer allocator.free(expected);
        const state_path = try self.absoluteChild(allocator, state_leaf);
        defer allocator.free(state_path);
        const name = terminalName(terminal.request());
        const terminal_path = try std.fs.path.join(allocator, &.{ terminal_leaf, &name });
        defer allocator.free(terminal_path);
        const destination = try self.absoluteChild(allocator, terminal_path);
        defer allocator.free(destination);
        const journals = try self.absoluteChild(allocator, accounting_leaf);
        defer allocator.free(journals);
        const old_digest = if (restart) |prior|
            try allocator.print("sha256:{s}", .{std.fmt.bytesToHex(prior.terminal_digest, .lower)})
        else
            null;
        defer if (old_digest) |digest| allocator.free(digest);
        const mutations = [_]codec.TransactionMutation{
            .{
                .path = state_path,
                .text = state_bytes,
                .expectation = .{ .expected_exists = true, .expected_digest = expected },
                .content_mode = .raw,
                .max_bytes = max_state_bytes,
            },
            .{
                .path = destination,
                .text = terminal_bytes,
                .expectation = .{
                    .expected_exists = restart != null,
                    .expected_digest = old_digest,
                },
                .content_mode = .raw,
                .max_bytes = max_terminal_bytes,
            },
        };
        const result = try transactions.commitTextTransactionControlled(
            self.authority(),
            allocator,
            journals,
            &mutations,
            .{ .owner = accountingOwner(terminal.request()) },
            .{ .wait_for_compatibility_locks = false, .private_outputs = true },
        );
        result.transaction.deinit(allocator);
        try self.recoverAccounting(allocator);
    }

    fn load(self: *Budget, allocator: std.mem.Allocator) !Snapshot {
        const bytes = try self.root.readAlloc(allocator, state_leaf, max_state_bytes);
        defer allocator.free(bytes);
        return parseBudgetSnapshot(allocator, bytes);
    }

    fn loadWithReadBudget(
        self: *Budget,
        allocator: std.mem.Allocator,
        remaining: *usize,
    ) !Snapshot {
        const bytes = try readBudgetDependencyBytes(
            &self.root,
            allocator,
            state_leaf,
            max_state_bytes,
            remaining,
        );
        defer allocator.free(bytes);
        return parseBudgetSnapshot(allocator, bytes);
    }

    fn change(
        self: *Budget,
        allocator: std.mem.Allocator,
        request: Request,
        free: FreeSpaceObservation,
        mode: enum { reserve, extend },
    ) !Receipt {
        var lock = try self.exclusive(allocator);
        defer lock.close(self.root.io);
        var snapshot = try self.load(allocator);
        defer snapshot.deinit();
        var state = snapshot.parsed.value;
        if (try self.readEffectiveTerminal(allocator, snapshot.parsed.value, request)) |terminal| {
            defer terminal.deinit();
            if (mode == .extend) return error.ReservationTerminal;
            return try terminalReceipt(state, terminal.value);
        }
        const existing = try findRecord(state, request);
        if (existing) |row| {
            if (row.charge.equal(request.charge)) {
                try self.syncState();
                return receipt(state, row, true);
            }
            if (mode != .extend) return error.ReservationExtensionRequired;
            if (row.binding != null) return error.ReservationAlreadyBound;
            if (!row.charge.within(request.charge)) return error.ReservationReductionUnsupported;
        } else if (mode == .extend) return error.ReservationNotFound;
        const count = state.reservations.len + @intFromBool(existing == null);
        if (count > max_reservations) return error.ReservationLimit;
        const rows = try allocator.alloc(Record, count);
        defer allocator.free(rows);
        @memcpy(rows[0..state.reservations.len], state.reservations);
        state.generation = try sum(state.generation, 1);
        const row: Record = .{
            .operation_id = request.operation_id,
            .store_id = request.store_id,
            .charge = request.charge,
            .generation = state.generation,
        };
        if (existing != null) {
            for (rows) |*candidate| {
                if (std.mem.eql(u8, candidate.operation_id, request.operation_id)) {
                    candidate.* = row;
                }
            }
        } else rows[count - 1] = row;
        state.reservations = rows;
        try admitGrowth(self.authority(), state, free);
        try self.publish(allocator, state);
        return receipt(state, row, false);
    }

    fn publish(self: *Budget, allocator: std.mem.Allocator, state: State) !void {
        const bytes = try std.json.Stringify.valueAlloc(allocator, state, .{});
        defer allocator.free(bytes);
        if (bytes.len > max_state_bytes) return error.ReservationLimit;
        var staging = try self.root.openChild(staging_leaf, .read_only);
        defer staging.deinit();
        try requireEmptyStaging(self.root.io, staging.directory);
        const outcome = publication.publishReplacement(
            self.root.io,
            staging.directory,
            self.root.directory,
            state_leaf,
            &.{bytes},
            .{
                .permissions = .fromMode(0o600),
                .durability = .file_and_directories_synced,
            },
        );
        switch (outcome) {
            .complete => {},
            .not_published => |failure| return failure.cause,
            .publication_unknown => return error.ReservationPublicationUnknown,
            .published_unsynced => return error.ReservationDurabilityUncertain,
        }
    }

    fn syncState(self: *Budget) !void {
        const file = try self.root.directory.openFile(self.root.io, state_leaf, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
        defer file.close(self.root.io);
        try file.sync(self.root.io);
        try filesystem.syncDirectoryHandle(self.authority(), &self.root.directory);
    }
};

fn validateSourceAssociation(
    allocator: std.mem.Allocator,
    state: State,
    options: DependencyOptions,
    native: transactions.TransactionDependencySnapshot,
) !void {
    const store = try findStore(state, options.store_id);
    if ((store.association == null) != (native.budget_association == null)) {
        return error.TransactionDependencyBudgetMismatch;
    }
    if (native.budget_association) |bytes| {
        const parsed = try std.json.parseFromSlice(struct {
            schema: []const u8,
            context: transactions.TransactionBudgetContext,
            source: transactions.TransactionBudgetSource,
        }, allocator, bytes, .{});
        defer parsed.deinit();
        if (!std.meta.eql(store.association.?, parsed.value.source)) {
            return error.TransactionDependencyBudgetMismatch;
        }
    }
}

fn validateDependencyContext(state: State, options: DependencyOptions) !void {
    if (!std.mem.eql(u8, state.budget_id, options.budget_id)) {
        return error.ReservationIdentityMismatch;
    }
    _ = try findStore(state, options.store_id);
}

fn dependencyPreparations(
    allocator: std.mem.Allocator,
    state: State,
    store_id: []const u8,
    maximum: usize,
) ![]transactions.TransactionDependencyPreparation {
    var result: std.ArrayList(transactions.TransactionDependencyPreparation) = .empty;
    errdefer result.deinit(allocator);
    for (state.reservations) |row| {
        if (!std.mem.eql(u8, row.store_id, store_id) or row.binding == null) continue;
        if (result.items.len == maximum) return error.ReservationLimit;
        try result.append(allocator, try dependencyPreparation(allocator, state.budget_id, row));
    }
    return result.toOwnedSlice(allocator);
}

fn dependencyPreparation(
    allocator: std.mem.Allocator,
    budget_id: []const u8,
    row: Record,
) !transactions.TransactionDependencyPreparation {
    const binding = row.binding orelse return error.ReservationUnbound;
    return .{
        .transaction_dir = binding.transaction_dir,
        .preparation = .{
            .record = row.preparing_record orelse return error.ReservationCorrupt,
            .intent_digest = binding.intent_digest,
            .root_identity = binding.root_identity,
        },
        .pin = try renderPin(
            allocator,
            .{
                .budget_id = budget_id,
                .store_id = row.store_id,
                .operation_id = row.operation_id,
                .charge = row.charge,
            },
            binding,
        ),
    };
}

fn readBudgetDependencyBytes(
    directory: *const PrivateDirectory,
    allocator: std.mem.Allocator,
    leaf: []const u8,
    maximum: usize,
    remaining: *usize,
) ![]u8 {
    const bytes = directory.readAlloc(allocator, leaf, @min(maximum, remaining.*)) catch |err|
        switch (err) {
            error.FileTooBig => return error.ReservationLimit,
            else => return err,
        };
    remaining.* -= bytes.len;
    return bytes;
}

fn parseBudgetSnapshot(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    const parsed = try std.json.parseFromSlice(State, allocator, bytes, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    try validateState(parsed.value);
    return .{
        .parsed = parsed,
        .used = try usedTotal(parsed.value),
        .reserved = try reservedTotal(
            parsed.value,
            null,
        ),
    };
}

fn parseTerminalBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(TerminalRecord) {
    const parsed = try std.json.parseFromSlice(TerminalRecord, allocator, bytes, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    const row = parsed.value;
    if (!std.mem.eql(u8, row.schema, "durable-reservation-terminal/v1") or
        row.terminal_bytes != bytes.len or row.generation == 0)
    {
        return error.ReservationCorrupt;
    }
    try validateBinding(row.binding);
    try row.charge.validate();
    try row.added.validate();
    try row.removed.validate();
    return parsed;
}

const ReservationPin = struct {
    schema: []const u8,
    budget_id: []const u8,
    store_id: []const u8,
    operation_id: []const u8,
    binding_digest: [32]u8,
};

fn parseReservationPin(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(ReservationPin) {
    if (bytes.len > transactions.reservation_pin_max_bytes) return error.ReservationLimit;
    const parsed = try std.json.parseFromSlice(ReservationPin, allocator, bytes, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schema, "durable-reservation-pin/v1")) {
        return error.ReservationCorrupt;
    }
    try validateIdentity(parsed.value.budget_id);
    try validateIdentity(parsed.value.store_id);
    try validateIdentity(parsed.value.operation_id);
    return parsed;
}

const PublicationContext = struct {
    budget: *Budget,
    store_fs: Fs,
    allocator: std.mem.Allocator,
    options: CommitOptions,
    request_digest: [32]u8,
    source: ?transactions.TransactionBudgetSource = null,
    binding: ?Binding = null,
    preparing_record: ?[]const u8 = null,
    target_usage: []const ClassifiedWrite = &.{},
    owns_target_usage: bool = false,
    pin: []u8 = &.{},
    guard: ?std.Io.File = null,
    guarded_snapshot: ?Snapshot = null,
    terminal_seen: ?@FieldType(transactions.TransactionTerminal, "state") = null,
    accounted: bool = false,

    fn hooks(self: *PublicationContext) transactions.TransactionPublicationHooks {
        return .{
            .context = self,
            .bind = bind,
            .acquire = acquire,
            .settled = settled,
            .release = release,
            .expected_pin = if (self.pin.len == 0) null else self.pin,
            .preparation = if (self.preparing_record) |record| .{
                .record = record,
                .root_identity = self.binding.?.root_identity,
                .intent_digest = self.binding.?.intent_digest,
            } else null,
        };
    }

    fn deinit(self: *PublicationContext) void {
        release(self);
        self.allocator.free(self.pin);
        if (self.owns_target_usage) self.allocator.free(self.target_usage);
    }

    fn cast(raw: *anyopaque) *PublicationContext {
        return @ptrCast(@alignCast(raw));
    }

    fn validateSourceBinding(
        self: *const PublicationContext,
        state: State,
        view: transactions.TransactionPublicationView,
    ) !void {
        const store = try findStore(state, self.options.request.store_id);
        const source = self.source orelse return error.TransactionReservationMismatch;
        if (!std.meta.eql(store.association, self.source) or
            !std.meta.eql(source.control_root, view.root_identity) or
            !std.meta.eql(source.transaction_root, view.transaction_root_identity orelse
                return error.TransactionReservationMismatch))
        {
            return error.TransactionReservationMismatch;
        }
    }

    fn bind(raw: *anyopaque, view: transactions.TransactionPublicationView) ![]const u8 {
        const self = cast(raw);
        var lock = try self.budget.exclusive(self.allocator);
        defer lock.close(self.budget.root.io);
        var snapshot = try self.budget.load(self.allocator);
        defer snapshot.deinit();
        var state = snapshot.parsed.value;
        const request = self.options.request;
        const row = try validateReservation(state, request, self.options.reservation);
        try self.validateSourceBinding(state, view);
        if (row.binding != null) return error.ReservationAlreadyBound;
        for (state.reservations) |other| {
            if (other.binding != null and std.mem.eql(u8, other.store_id, request.store_id)) {
                return error.ReservationStoreBusy;
            }
        }
        self.target_usage = try classifyWrites(self.allocator, self.options, view.targets);
        self.owns_target_usage = true;
        const usage = try classifiedTotals(self.target_usage);
        const binding: Binding = .{
            .transaction_id = view.transaction_id,
            .transaction_dir = view.transaction_dir,
            .intent_digest = view.intent_digest,
            .request_digest = self.request_digest,
            .final_state_digest = try finalStateDigest(self.options, view.targets),
            .root_identity = view.root_identity,
            .before_bytes = view.before_bytes orelse return error.TransactionCorrupt,
            .after_bytes = view.after_bytes orelse return error.TransactionCorrupt,
            .target_class = self.options.target_class,
            .target_usage_digest = try hashValue(self.target_usage),
            .before_metadata_bytes = usage.before_metadata,
            .after_metadata_bytes = usage.after_metadata,
            .publication_identity = self.options.publication_identity,
        };
        if (row.restart) |prior| {
            if (!std.meta.eql(binding.final_state_digest, prior.final_state_digest) or
                !std.meta.eql(binding.root_identity, prior.root_identity) or
                !std.meta.eql(binding.publication_identity, prior.publication_identity))
            {
                return error.ReservationIdentityMismatch;
            }
        }
        try validateBinding(binding);
        try validateClassifiedWrites(binding, self.target_usage);
        try admitTransactionCharge(request.charge, binding);
        const store = try findStore(state, request.store_id);
        if (store.used.logical_total < binding.before_bytes or
            store.used.metadata < binding.before_metadata_bytes)
        {
            return error.ReservationAccountingMismatch;
        }
        try validateFreeSpace(self.budget.authority(), state, self.options.free_space);
        const rows = try self.allocator.dupe(Record, state.reservations);
        defer self.allocator.free(rows);
        for (rows) |*candidate| {
            if (std.mem.eql(u8, candidate.operation_id, request.operation_id)) {
                candidate.binding = binding;
                candidate.preparing_record = view.preparing_record orelse
                    return error.TransactionCorrupt;
                candidate.target_usage = self.target_usage;
            }
        }
        self.pin = try renderPin(self.allocator, request, binding);
        state.reservations = rows;
        state.generation = try sum(state.generation, 1);
        try self.budget.publish(self.allocator, state);
        self.binding = binding;
        return self.pin;
    }

    fn acquire(raw: *anyopaque, view: transactions.TransactionPublicationView) !void {
        const self = cast(raw);
        if (self.guard != null) return error.ReservationCorrupt;
        const binding = self.binding orelse return error.ReservationUnbound;
        try validateView(binding, view);
        self.guard = try self.budget.exclusive(self.allocator);
        errdefer release(raw);
        self.guarded_snapshot = try self.budget.load(self.allocator);
        const state = self.guarded_snapshot.?.parsed.value;
        const row = try validateReservation(state, self.options.request, self.options.reservation);
        const current = row.binding orelse return error.ReservationUnbound;
        if (!std.meta.eql(try hashValue(current), try hashValue(binding))) {
            return error.ReservationChanged;
        }
        try validateFreeSpace(self.budget.authority(), state, self.options.free_space);
        try self.budget.syncState();
    }

    fn release(raw: *anyopaque) void {
        const self = cast(raw);
        if (self.guarded_snapshot) |*snapshot| snapshot.deinit();
        self.guarded_snapshot = null;
        if (self.guard) |lock| lock.close(self.budget.root.io);
        self.guard = null;
    }

    fn validateTerminalUsage(
        self: *PublicationContext,
        state: @FieldType(transactions.TransactionTerminal, "state"),
    ) !void {
        try validateClassifiedWrites(self.binding.?, self.target_usage);
        for (self.target_usage) |target| {
            const stat = try filesystem.statRegularFileNoSymlink(self.store_fs, target.path);
            const actual = if (stat) |file| file.size else 0;
            const expected = if (state == .committed) target.after_bytes else target.before_bytes;
            if (actual != expected) return error.ReservationAccountingMismatch;
        }
    }

    fn settled(raw: *anyopaque, terminal: transactions.TransactionTerminal) !void {
        const self = cast(raw);
        if (self.guard == null or self.guarded_snapshot == null) return error.ReservationCorrupt;
        const binding = self.binding orelse return error.ReservationUnbound;
        try validateView(binding, terminal.view);
        self.terminal_seen = terminal.state;
        switch (terminal.usage) {
            .committed_intent => {
                if (terminal.state != .committed) return error.ReservationAccountingMismatch;
                try validateClassifiedWrites(binding, self.target_usage);
            },
            .observed => |bytes| {
                const expected = if (terminal.state == .committed)
                    binding.after_bytes
                else
                    binding.before_bytes;
                if (bytes != expected) return error.ReservationAccountingMismatch;
                try self.validateTerminalUsage(terminal.state);
            },
        }
        const active = (try findRecord(
            self.guarded_snapshot.?.parsed.value,
            self.options.request,
        )) orelse return error.ReservationNotFound;
        var state = self.guarded_snapshot.?.parsed.value;
        const rows = try self.allocator.alloc(Record, state.reservations.len - 1);
        defer self.allocator.free(rows);
        var count: usize = 0;
        for (state.reservations) |row| {
            if (std.mem.eql(u8, row.operation_id, self.options.request.operation_id)) continue;
            if (count == rows.len) return error.ReservationCorrupt;
            rows[count] = row;
            count += 1;
        }
        if (count != rows.len) return error.ReservationCorrupt;
        state.reservations = rows;
        state.generation = try sum(state.generation, 1);
        const evidence = try terminalEvidence(
            self.allocator,
            self.options.request,
            binding,
            terminal,
            state.generation,
            active.restart,
        );
        const stores = try self.allocator.dupe(Store, state.stores);
        defer self.allocator.free(stores);
        for (stores) |*store| {
            if (!std.mem.eql(u8, store.store_id, self.options.request.store_id)) continue;
            store.used = try subtractCharge(store.used, evidence.removed);
            store.used = try store.used.add(evidence.added);
        }
        state.stores = stores;
        try validateState(state);
        try self.budget.commitAccounting(self.allocator, state, evidence, active.restart);
        self.accounted = true;
    }
};

fn validateRestartTerminal(row: Record, terminal: TerminalRecord) !void {
    const restart = row.restart orelse return error.ReservationRecoveryRequired;
    if (terminal.outcome != .aborted or row.generation <= terminal.generation or
        restart.terminal_generation != terminal.generation or
        restart.terminal_bytes != terminal.terminal_bytes or
        !std.meta.eql(restart.terminal_digest, try hashValue(terminal)) or
        !std.meta.eql(restart.final_state_digest, terminal.binding.final_state_digest) or
        !std.meta.eql(restart.publication_identity, terminal.binding.publication_identity) or
        !std.meta.eql(restart.root_identity, terminal.binding.root_identity))
    {
        return error.ReservationRecoveryRequired;
    }
}

fn validateReservation(state: State, request: Request, expected: Receipt) !Record {
    const row = (try findRecord(state, request)) orelse return error.ReservationNotFound;
    if (expected.status != .reserved or state.policy_generation != expected.policy_generation or
        row.generation != expected.generation or !row.charge.equal(request.charge) or
        !row.charge.equal(expected.charge)) return error.ReservationChanged;
    return row;
}

fn validateRecordPublication(state: State, request: Request, identity: ?[32]u8) !void {
    const row = (try findRecord(state, request)) orelse return;
    if (row.binding) |binding| {
        try validatePublicationIdentity(binding.publication_identity, identity);
    }
    if (row.restart) |restart| {
        try validatePublicationIdentity(restart.publication_identity, identity);
    }
}

fn validatePublicationIdentity(actual: ?[32]u8, expected: ?[32]u8) !void {
    if (expected != null) try requirePublicationIdentity(actual, expected);
}

fn requirePublicationIdentity(actual: ?[32]u8, expected: ?[32]u8) !void {
    if (!std.meta.eql(actual, expected)) return error.ReservationIdentityMismatch;
}

fn validateBinding(binding: Binding) !void {
    if (!codec.isGeneratedTransactionId(binding.transaction_id) or
        binding.transaction_dir.len == 0 or
        binding.transaction_dir.len > std.fs.max_path_bytes or
        !std.mem.eql(u8, std.fs.path.basename(binding.transaction_dir), binding.transaction_id))
    {
        return error.ReservationCorrupt;
    }
}

fn classifyWrites(
    allocator: std.mem.Allocator,
    options: CommitOptions,
    writes: []const transactions.TransactionTargetUsage,
) ![]ClassifiedWrite {
    if (options.target_classes.len > writes.len) return error.ReservationIdentityMismatch;
    for (options.target_classes, 0..) |selected, index| {
        for (options.target_classes[0..index]) |prior| {
            if (std.mem.eql(u8, selected.path, prior.path)) {
                return error.ReservationIdentityMismatch;
            }
        }
        var found = false;
        for (writes) |write| {
            if (std.mem.eql(u8, selected.path, write.path)) found = true;
        }
        if (!found) return error.ReservationIdentityMismatch;
    }
    var count: usize = 0;
    for (writes) |write| count += @intFromBool(write.write);
    const result = try allocator.alloc(ClassifiedWrite, count);
    errdefer allocator.free(result);
    var index: usize = 0;
    for (writes) |write| {
        if (!write.write) continue;
        result[index] = .{
            .path = write.path,
            .before_bytes = write.before_bytes,
            .after_bytes = write.after_bytes,
            .class = targetClass(options, write.path),
        };
        index += 1;
    }
    return result;
}

fn targetClass(options: CommitOptions, path: []const u8) TargetClass {
    for (options.target_classes) |selected| {
        if (std.mem.eql(u8, selected.path, path)) return selected.class;
    }
    return options.target_class;
}

fn finalStateDigest(
    options: CommitOptions,
    targets: []const transactions.TransactionTargetUsage,
) ![32]u8 {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256).init(&buffer);
    try output.writer.print("{d}:", .{targets.len});
    for (targets) |target| {
        try std.json.Stringify.value(.{
            .path = target.path,
            .digest = target.digest_after,
            .length = target.after_bytes,
            .class = targetClass(options, target.path),
        }, .{}, &output.writer);
    }
    try output.writer.flush();
    var digest: [32]u8 = undefined;
    output.hasher.final(&digest);
    return digest;
}

const ClassifiedTotals = struct {
    before: u64 = 0,
    after: u64 = 0,
    before_metadata: u64 = 0,
    after_metadata: u64 = 0,
};

fn classifiedTotals(writes: []const ClassifiedWrite) !ClassifiedTotals {
    if (writes.len > codec.transaction_recovery_max_rows) return error.ReservationLimit;
    var result: ClassifiedTotals = .{};
    for (writes, 0..) |write, index| {
        if (write.path.len == 0 or write.path.len > std.fs.max_path_bytes) {
            return error.ReservationCorrupt;
        }
        if (index > 0 and std.mem.order(u8, writes[index - 1].path, write.path) != .lt) {
            return error.ReservationCorrupt;
        }
        result.before = try sum(result.before, write.before_bytes);
        result.after = try sum(result.after, write.after_bytes);
        if (write.class == .metadata) {
            result.before_metadata = try sum(result.before_metadata, write.before_bytes);
            result.after_metadata = try sum(result.after_metadata, write.after_bytes);
        }
    }
    return result;
}

fn validateClassifiedWrites(binding: Binding, writes: []const ClassifiedWrite) !void {
    const totals = try classifiedTotals(writes);
    if (!std.meta.eql(binding.target_usage_digest, try hashValue(writes)) or
        binding.before_bytes != totals.before or binding.after_bytes != totals.after or
        binding.before_metadata_bytes != totals.before_metadata or
        binding.after_metadata_bytes != totals.after_metadata) return error.ReservationCorrupt;
}

fn validateView(binding: Binding, view: transactions.TransactionPublicationView) !void {
    if (!std.mem.eql(u8, binding.transaction_id, view.transaction_id) or
        !std.mem.eql(u8, binding.transaction_dir, view.transaction_dir) or
        !std.meta.eql(binding.intent_digest, view.intent_digest) or
        !std.meta.eql(binding.root_identity, view.root_identity)) return error.ReservationChanged;
    if (view.before_bytes) |bytes| {
        if (bytes != binding.before_bytes) return error.ReservationChanged;
    }
    if (view.after_bytes) |bytes| {
        if (bytes != binding.after_bytes) return error.ReservationChanged;
    }
}

fn admitTransactionCharge(charge: Charge, binding: Binding) !void {
    const required = try Budget.transactionCharge(
        binding.after_bytes,
        binding.after_metadata_bytes,
    );
    if (!required.within(charge)) return error.ReservationExtensionRequired;
}

fn hashValue(value: anytype) ![32]u8 {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256).init(&buffer);
    try std.json.Stringify.value(value, .{}, &output.writer);
    try output.writer.flush();
    var digest: [32]u8 = undefined;
    output.hasher.final(&digest);
    return digest;
}

fn requestDigest(mutations: []const codec.TransactionMutation, options: CommitOptions) ![32]u8 {
    if (options.publication_identity) |identity| {
        return hashValue(.{
            .target_class = options.target_class,
            .target_classes = options.target_classes,
            .mutations = mutations,
            .publication_identity = identity,
        });
    }
    return hashValue(.{
        .target_class = options.target_class,
        .target_classes = options.target_classes,
        .mutations = mutations,
    });
}

fn renderPin(allocator: std.mem.Allocator, request: Request, binding: Binding) ![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, ReservationPin{
        .schema = "durable-reservation-pin/v1",
        .budget_id = request.budget_id,
        .store_id = request.store_id,
        .operation_id = request.operation_id,
        .binding_digest = try hashValue(binding),
    }, .{});
    errdefer allocator.free(bytes);
    if (bytes.len > transactions.reservation_pin_max_bytes) return error.ReservationLimit;
    return bytes;
}

fn terminalName(request: Request) [69]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{ request.budget_id, request.operation_id }) |value| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, value.len, .little);
        hash.update(&length);
        hash.update(value);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var name: [69]u8 = undefined;
    name[0..64].* = std.fmt.bytesToHex(digest, .lower);
    name[64..].* = ".json".*;
    return name;
}

fn accountingOwner(request: Request) codec.Owner {
    return .{
        .process_id = 1,
        .session_id = request.operation_id,
        .executor = "budget-accounting",
    };
}

fn subtractCharge(value: Charge, removed: Charge) !Charge {
    if (!removed.within(value)) return error.ReservationAccountingMismatch;
    return .{
        .logical_total = value.logical_total - removed.logical_total,
        .staging = value.staging - removed.staging,
        .metadata = value.metadata - removed.metadata,
    };
}

fn terminalEvidence(
    allocator: std.mem.Allocator,
    request: Request,
    binding: Binding,
    terminal: transactions.TransactionTerminal,
    generation: u64,
    restart: ?Restart,
) !TerminalRecord {
    var result: TerminalRecord = .{
        .schema = "durable-reservation-terminal/v1",
        .budget_id = request.budget_id,
        .store_id = request.store_id,
        .operation_id = request.operation_id,
        .charge = request.charge,
        .binding = binding,
        .outcome = terminal.state,
        .generation = generation,
        .added = Charge.zero,
        .removed = Charge.zero,
        .native_metadata_bytes = terminal.metadata_bytes,
        .terminal_bytes = 0,
    };
    const after = if (terminal.state == .committed) binding.after_bytes else 0;
    const before = if (terminal.state == .committed) binding.before_bytes else 0;
    result.removed.logical_total = before;
    if (terminal.state == .committed) result.removed.metadata = binding.before_metadata_bytes;
    if (restart) |prior| {
        result.removed.logical_total = try sum(result.removed.logical_total, prior.terminal_bytes);
        result.removed.metadata = try sum(result.removed.metadata, prior.terminal_bytes);
    }
    for (0..8) |_| {
        const metadata = try sum(terminal.metadata_bytes, result.terminal_bytes);
        result.added.logical_total = try sum(after, metadata);
        result.added.metadata = try sum(
            metadata,
            if (terminal.state == .committed) binding.after_metadata_bytes else 0,
        );
        const bytes = try std.json.Stringify.valueAlloc(allocator, result, .{});
        defer allocator.free(bytes);
        if (bytes.len > Budget.max_terminal_bytes) return error.ReservationLimit;
        if (bytes.len == result.terminal_bytes) {
            if (!result.added.within(request.charge)) return error.ReservationAccountingMismatch;
            return result;
        }
        result.terminal_bytes = bytes.len;
    }
    return error.ReservationAccountingMismatch;
}

fn pendingResult(
    allocator: std.mem.Allocator,
    binding: Binding,
) !transactions.ControlledTransactionReceipt {
    const id = try allocator.dupe(u8, binding.transaction_id);
    errdefer allocator.free(id);
    const dir = try allocator.dupe(u8, binding.transaction_dir);
    errdefer allocator.free(dir);
    const record = try std.fs.path.join(allocator, &.{ dir, "transaction.json" });
    errdefer allocator.free(record);
    const marker = try std.fs.path.join(allocator, &.{ dir, "commit.json" });
    return .{
        .transaction = .{
            .transaction_id = id,
            .transaction_dir = dir,
            .record_path = record,
            .commit_marker_path = marker,
            .state = .recovery_required,
        },
        .semantic = .recovery_required,
    };
}

fn terminalResult(
    allocator: std.mem.Allocator,
    terminal: TerminalRecord,
) !transactions.ControlledTransactionReceipt {
    var result = try pendingResult(allocator, terminal.binding);
    result.semantic = if (terminal.outcome == .committed) .committed else .aborted;
    result.transaction.state = if (terminal.outcome == .committed) .committed else .aborted;
    result.reused = true;
    return result;
}

fn terminalReceipt(state: State, terminal: TerminalRecord) !Receipt {
    if (terminal.generation > state.generation) return error.ReservationRecoveryRequired;
    for (state.reservations) |row| {
        if (std.mem.eql(u8, row.operation_id, terminal.operation_id)) {
            return error.ReservationRecoveryRequired;
        }
    }
    return .{
        .generation = terminal.generation,
        .policy_generation = state.policy_generation,
        .charge = terminal.charge,
        .reused = true,
        .status = if (terminal.outcome == .committed) .committed else .aborted,
    };
}

fn receipt(state: State, row: Record, reused: bool) Receipt {
    return .{
        .generation = row.generation,
        .policy_generation = state.policy_generation,
        .charge = row.charge,
        .reused = reused,
    };
}

fn sum(left: u64, right: u64) !u64 {
    return std.math.add(u64, left, right) catch return error.ReservationOverflow;
}

fn validateIdentity(identity: []const u8) !void {
    if (identity.len == 0 or identity.len > Budget.max_identity_bytes or
        std.mem.indexOfScalar(u8, identity, 0) != null) return error.InvalidReservationIdentity;
}

fn validateState(state: State) !void {
    if (!std.mem.eql(u8, state.schema, "durable-reservation-budget/v1") or
        state.generation == 0 or state.policy_generation == 0 or
        state.policy_generation > state.generation) return error.ReservationCorrupt;
    try validateIdentity(state.budget_id);
    try validateIdentity(state.policy.free_space_scope_id);
    if (state.policy.max_observation_age_ms == 0) return error.InvalidReservationPolicy;
    if (state.policy.recovery_reserve_bytes > state.policy.limits.logical_total) {
        return error.InvalidReservationPolicy;
    }
    _ = try sum(state.policy.minimum_free_bytes, state.policy.recovery_reserve_bytes);
    if (state.stores.len == 0 or state.stores.len > Budget.max_stores or
        state.reservations.len > Budget.max_reservations) return error.ReservationLimit;
    for (state.stores, 0..) |store, index| {
        try validateIdentity(store.store_id);
        try store.used.validate();
        for (state.stores[0..index]) |prior| {
            if (std.mem.eql(u8, prior.store_id, store.store_id)) return error.ReservationCorrupt;
        }
    }
    for (state.reservations, 0..) |row, index| {
        try validateIdentity(row.operation_id);
        try row.charge.validate();
        if (row.binding) |binding| {
            try validateBinding(binding);
            try validateClassifiedWrites(binding, row.target_usage);
            if (row.restart) |prior| {
                if (!std.meta.eql(binding.final_state_digest, prior.final_state_digest) or
                    !std.meta.eql(binding.root_identity, prior.root_identity) or
                    !std.meta.eql(binding.publication_identity, prior.publication_identity))
                {
                    return error.ReservationCorrupt;
                }
            }
            const preparing = row.preparing_record orelse return error.ReservationCorrupt;
            if (preparing.len == 0 or preparing.len > codec.transaction_record_max_bytes) {
                return error.ReservationCorrupt;
            }
        } else if (row.preparing_record != null or row.target_usage.len != 0) {
            return error.ReservationCorrupt;
        }
        if (row.restart) |prior| {
            if (prior.terminal_generation == 0 or prior.terminal_generation >= row.generation or
                prior.terminal_bytes == 0 or prior.terminal_bytes > Budget.max_terminal_bytes)
            {
                return error.ReservationCorrupt;
            }
        }
        if (row.generation == 0 or row.generation > state.generation) {
            return error.ReservationCorrupt;
        }
        _ = try findStore(state, row.store_id);
        for (state.reservations[0..index]) |prior| {
            if (std.mem.eql(u8, prior.operation_id, row.operation_id)) {
                return error.ReservationCorrupt;
            }
        }
    }
    _ = try Charge.add(try usedTotal(state), try reservedTotal(state, null));
}

fn findStore(state: State, store_id: []const u8) !Store {
    for (state.stores) |store| {
        if (std.mem.eql(u8, store.store_id, store_id)) return store;
    }
    return error.ReservationStoreUnknown;
}

fn findRecord(state: State, request: Request) !?Record {
    try validateIdentity(request.operation_id);
    try request.charge.validate();
    if (!std.mem.eql(u8, state.budget_id, request.budget_id)) {
        return error.ReservationIdentityMismatch;
    }
    _ = try findStore(state, request.store_id);
    for (state.reservations) |row| {
        if (!std.mem.eql(u8, row.operation_id, request.operation_id)) continue;
        if (!std.mem.eql(u8, row.store_id, request.store_id)) {
            return error.ReservationIdentityMismatch;
        }
        return row;
    }
    return null;
}

fn usedTotal(state: State) !Charge {
    var used = Charge.zero;
    for (state.stores) |store| used = try used.add(store.used);
    return used;
}

fn reservedTotal(state: State, store_id: ?[]const u8) !Charge {
    var reserved = Charge.zero;
    for (state.reservations) |row| {
        if (store_id) |selected| {
            if (!std.mem.eql(u8, selected, row.store_id)) continue;
        }
        reserved = try reserved.add(row.charge);
    }
    return reserved;
}

fn admitGrowth(fs: Fs, state: State, free: FreeSpaceObservation) !void {
    const reserved = try reservedTotal(state, null);
    var total = try Charge.add(
        try Charge.add(try usedTotal(state), reserved),
        Budget.control_charge,
    );
    total.logical_total = try sum(total.logical_total, state.policy.recovery_reserve_bytes);
    if (!total.within(state.policy.limits)) return error.ReservationCapacityExceeded;
    for (state.stores) |store| {
        var store_total = try store.used.add(try reservedTotal(state, store.store_id));
        if (store.association != null) store_total = try store_total.add(Budget.association_charge);
        if (!store_total.within(store.limits)) return error.ReservationStoreCapacityExceeded;
    }
    try validateFreeSpace(fs, state, free);
}

fn validateFreeSpace(fs: Fs, state: State, free: FreeSpaceObservation) !void {
    if (!std.mem.eql(u8, free.scope_id, state.policy.free_space_scope_id)) {
        return error.ReservationFreeSpaceScopeMismatch;
    }
    const now = filesystem.clockMillis(fs, .real);
    if (free.observed_at_ms > now or
        now - free.observed_at_ms > state.policy.max_observation_age_ms)
    {
        return error.ReservationFreeSpaceStale;
    }
    const floor = try sum(state.policy.minimum_free_bytes, state.policy.recovery_reserve_bytes);
    const reserved = try reservedTotal(state, null);
    const peak = try sum(try reserved.physicalPeak(), try Budget.control_charge.physicalPeak());
    if (try sum(floor, peak) > free.available_bytes) return error.ReservationFreeSpaceInsufficient;
}

fn requireEmptyStaging(io: std.Io, directory: std.Io.Dir) !void {
    var iterable = try directory.openDir(io, ".", .{ .iterate = true });
    defer iterable.close(io);
    var iter = iterable.iterate();
    if (try iter.next(io) != null) return error.ReservationRecoveryRequired;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    budget: Budget,

    fn init(used: Charge) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var root = try PrivateDirectory.open(.init(std.testing.io, tmp.dir), "budget", .create);
        root.deinit();
        const stores = [_]Store{
            .{ .store_id = "a", .used = used, .limits = test_store_limits },
            .{ .store_id = "b", .used = Charge.zero, .limits = test_store_limits },
        };
        const budget = try Budget.initialize(
            .init(std.testing.io, tmp.dir),
            std.testing.allocator,
            "budget",
            "test-budget",
            test_policy,
            &stores,
            observation(),
        );
        return .{ .tmp = tmp, .budget = budget };
    }

    fn deinit(self: *Fixture) void {
        self.budget.deinit();
        self.tmp.cleanup();
    }

    fn reopen(self: *Fixture, io: std.Io) !Budget {
        return Budget.open(.init(io, self.tmp.dir), "budget");
    }
};

const test_store_limits: Charge = .{ .logical_total = 100, .staging = 100, .metadata = 100 };
const test_policy: Policy = .{
    .limits = .{
        .logical_total = Budget.control_charge.logical_total + 100 + 20,
        .staging = Budget.control_charge.staging + 100,
        .metadata = Budget.control_charge.metadata + 100,
    },
    .free_space_scope_id = "test-filesystem",
    .minimum_free_bytes = 10,
    .recovery_reserve_bytes = 20,
    .max_observation_age_ms = 60_000,
};

fn observation() FreeSpaceObservation {
    return .{
        .scope_id = "test-filesystem",
        .available_bytes = 16 * 1024 * 1024,
        .observed_at_ms = filesystem.clockMillis(.init(std.testing.io, std.Io.Dir.cwd()), .real),
    };
}

fn requestFor(operation: []const u8, logical_total: u64) Request {
    return .{
        .budget_id = "test-budget",
        .store_id = "a",
        .operation_id = operation,
        .charge = .{ .logical_total = logical_total, .staging = 0, .metadata = 0 },
    };
}

test "reservations persist exact caps and retries without double charging" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(.{ .logical_total = 10, .staging = 0, .metadata = 0 });
    defer fixture.deinit();
    const request = requestFor("operation", 90);
    const first = try fixture.budget.reserve(allocator, request, observation());
    try std.testing.expect(!first.reused);
    var reopened = try fixture.reopen(std.testing.io);
    defer reopened.deinit();
    const retry = try reopened.reserve(allocator, request, observation());
    try std.testing.expect(retry.reused);
    try std.testing.expectEqual(first.generation, retry.generation);
    var snapshot = try reopened.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 10), snapshot.used.logical_total);
    try std.testing.expectEqual(@as(u64, 90), snapshot.reserved.logical_total);
    try std.testing.expectEqual(@as(usize, 1), snapshot.parsed.value.reservations.len);
    try std.testing.expectError(
        error.ReservationCapacityExceeded,
        reopened.reserve(allocator, requestFor("too-much", 1), observation()),
    );
    try std.testing.expectError(
        error.ReservationExtensionRequired,
        reopened.reserve(allocator, requestFor("operation", 91), observation()),
    );
    try std.testing.expectError(
        error.ReservationCapacityExceeded,
        reopened.extend(allocator, requestFor("operation", 91), observation()),
    );
    _ = try validateReservation(snapshot.parsed.value, request, first);
}

test "reservations extend explicitly and preserve grandfathered charges after quota reduction" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(Charge.zero);
    defer fixture.deinit();
    const first = try fixture.budget.reserve(allocator, requestFor("operation", 30), observation());
    const grown = requestFor("operation", 60);
    const extended = try fixture.budget.extend(allocator, grown, observation());
    try std.testing.expect(extended.generation > first.generation);
    try std.testing.expectError(
        error.ReservationReductionUnsupported,
        fixture.budget.extend(allocator, requestFor("operation", 59), observation()),
    );
    var policy = test_policy;
    policy.limits.logical_total = Budget.control_charge.logical_total + 20 + 20;
    try fixture.budget.updatePolicy(
        allocator,
        "test-budget",
        extended.generation,
        policy,
        &.{ test_store_limits, test_store_limits },
    );
    var changed = try fixture.budget.inspect(allocator);
    defer changed.deinit();
    try std.testing.expectError(error.ReservationChanged, validateReservation(
        changed.parsed.value,
        grown,
        extended,
    ));
    const retained = try fixture.budget.reserve(allocator, grown, observation());
    try std.testing.expect(retained.reused);
    try std.testing.expectEqual(extended.generation, retained.generation);
    _ = try validateReservation(changed.parsed.value, grown, retained);
    try std.testing.expectError(
        error.ReservationCapacityExceeded,
        fixture.budget.extend(allocator, requestFor("operation", 61), observation()),
    );
    var snapshot = try fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 60), snapshot.reserved.logical_total);
}

test "reservations reject overflow stale observations identity conflicts and stale policy updates" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(.{ .logical_total = 1, .staging = 0, .metadata = 0 });
    defer fixture.deinit();
    try std.testing.expectError(
        error.ReservationOverflow,
        fixture.budget.reserve(
            allocator,
            requestFor("overflow", std.math.maxInt(u64)),
            observation(),
        ),
    );
    var free = observation();
    free.observed_at_ms = 0;
    try std.testing.expectError(
        error.ReservationFreeSpaceStale,
        fixture.budget.reserve(allocator, requestFor("stale", 1), free),
    );
    free = observation();
    free.scope_id = "another-filesystem";
    try std.testing.expectError(
        error.ReservationFreeSpaceScopeMismatch,
        fixture.budget.reserve(allocator, requestFor("wrong-scope", 1), free),
    );
    _ = try fixture.budget.reserve(allocator, requestFor("identity", 1), observation());
    var conflicting = requestFor("identity", 1);
    conflicting.store_id = "b";
    try std.testing.expectError(
        error.ReservationIdentityMismatch,
        fixture.budget.reserve(allocator, conflicting, observation()),
    );
    try std.testing.expectError(error.ReservationChanged, fixture.budget.updatePolicy(
        allocator,
        "test-budget",
        1,
        test_policy,
        &.{ test_store_limits, test_store_limits },
    ));
}

test "reservations enforce physical free reserve independently of logical quota" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(Charge.zero);
    defer fixture.deinit();
    const request = requestFor("physical", 1);
    var free = observation();
    free.available_bytes = try sum(
        try sum(try Budget.control_charge.physicalPeak(), try request.charge.physicalPeak()),
        30,
    );
    free.available_bytes -= 1;
    try std.testing.expectError(
        error.ReservationFreeSpaceInsufficient,
        fixture.budget.reserve(allocator, request, free),
    );
    free.available_bytes += 1;
    _ = try fixture.budget.reserve(allocator, request, free);
}

const ConcurrentReserve = struct {
    fixture: *Fixture,
    operation: []const u8,
    store: []const u8,
    start: *std.atomic.Value(bool),
    outcome: ?anyerror = null,

    fn run(self: *ConcurrentReserve) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        self.attempt() catch |err| {
            self.outcome = err;
        };
    }

    fn attempt(self: *ConcurrentReserve) !void {
        var budget = try self.fixture.reopen(std.testing.io);
        defer budget.deinit();
        var request = requestFor(self.operation, 60);
        request.store_id = self.store;
        for (0..1000) |_| {
            _ = budget.reserve(std.heap.page_allocator, request, observation()) catch |err| {
                if (err != error.LockBusy) return err;
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                continue;
            };
            return;
        }
        return error.TestReservationTimeout;
    }
};

test "native concurrent reservations serialize a shared budget across stores" {
    var fixture = try Fixture.init(Charge.zero);
    defer fixture.deinit();
    var start = std.atomic.Value(bool).init(false);
    var first: ConcurrentReserve = .{
        .fixture = &fixture,
        .operation = "first",
        .store = "a",
        .start = &start,
    };
    var second: ConcurrentReserve = .{
        .fixture = &fixture,
        .operation = "second",
        .store = "b",
        .start = &start,
    };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentReserve.run, .{&first});
    const second_thread = std.Thread.spawn(.{}, ConcurrentReserve.run, .{&second}) catch |err| {
        start.store(true, .release);
        first_thread.join();
        return err;
    };
    start.store(true, .release);
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.outcome == null or second.outcome == null);
    if (first.outcome) |denied| {
        try std.testing.expectEqual(error.ReservationCapacityExceeded, denied);
    } else if (second.outcome) |denied| {
        try std.testing.expectEqual(error.ReservationCapacityExceeded, denied);
    } else return error.TestExpectedDenial;
    var snapshot = try fixture.budget.inspect(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 60), snapshot.reserved.logical_total);
    try std.testing.expectEqual(@as(usize, 1), snapshot.parsed.value.reservations.len);
}

test "reservation rename reply loss persists admission and retry does not double charge" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(Charge.zero);
    defer fixture.deinit();
    var vtable = std.testing.io.vtable.*;
    vtable.dirRename = struct {
        fn rename(
            userdata: ?*anyopaque,
            old_dir: std.Io.Dir,
            old_name: []const u8,
            new_dir: std.Io.Dir,
            new_name: []const u8,
        ) std.Io.Dir.RenameError!void {
            try std.testing.io.vtable.dirRename(userdata, old_dir, old_name, new_dir, new_name);
            return error.HardwareFailure;
        }
    }.rename;
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var failing = try fixture.reopen(injected);
    defer failing.deinit();
    const request = requestFor("lost-reply", 30);
    try std.testing.expectError(
        error.ReservationPublicationUnknown,
        failing.reserve(allocator, request, observation()),
    );
    var reopened = try fixture.reopen(std.testing.io);
    defer reopened.deinit();
    const retry = try reopened.reserve(allocator, request, observation());
    try std.testing.expect(retry.reused);
    var snapshot = try reopened.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 30), snapshot.reserved.logical_total);
    try std.testing.expectEqual(@as(usize, 1), snapshot.parsed.value.reservations.len);
}

test "reservation prepublication sync failure leaves no admitted charge" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(Charge.zero);
    defer fixture.deinit();
    var vtable = std.testing.io.vtable.*;
    vtable.fileSync = struct {
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
    }.sync;
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var failing = try fixture.reopen(injected);
    defer failing.deinit();
    const request = requestFor("before-rename", 30);
    try std.testing.expectError(
        error.InputOutput,
        failing.reserve(allocator, request, observation()),
    );
    var snapshot = try fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 0), snapshot.reserved.logical_total);
    const retry = try fixture.budget.reserve(allocator, request, observation());
    try std.testing.expect(!retry.reused);
}

test "reservation class charges are subsets of total and have independent store limits" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(Charge.zero);
    defer fixture.deinit();
    var request = requestFor("classes", 10);
    request.charge.staging = 6;
    request.charge.metadata = 5;
    try std.testing.expectError(
        error.InvalidReservationCharge,
        fixture.budget.reserve(allocator, request, observation()),
    );
    request.charge.metadata = 4;
    var limits = test_store_limits;
    limits.staging = 5;
    try fixture.budget.updatePolicy(
        allocator,
        "test-budget",
        1,
        test_policy,
        &.{ limits, test_store_limits },
    );
    try std.testing.expectError(
        error.ReservationStoreCapacityExceeded,
        fixture.budget.reserve(allocator, request, observation()),
    );
    request.charge.staging = 5;
    request.charge.metadata = 5;
    _ = try fixture.budget.reserve(allocator, request, observation());
    var snapshot = try fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 10), snapshot.reserved.logical_total);
    try std.testing.expectEqual(@as(u64, 5), snapshot.reserved.staging);
    try std.testing.expectEqual(@as(u64, 5), snapshot.reserved.metadata);
}

test "reservation inspection does not create missing coordination state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var private = try PrivateDirectory.open(.init(std.testing.io, tmp.dir), "budget", .create);
    private.deinit();
    var budget = try Budget.open(.init(std.testing.io, tmp.dir), "budget");
    defer budget.deinit();
    try std.testing.expectError(
        error.ReservationCoordinationUnavailable,
        budget.inspect(std.testing.allocator),
    );
    var dir = try tmp.dir.openDir(std.testing.io, "budget", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iter = dir.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try iter.next(std.testing.io));
}

test "reservation retry retains unknown staging even with a valid native filename" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(Charge.zero);
    defer fixture.deinit();
    var staging = try fixture.budget.root.openChild(Budget.staging_leaf, .read_only);
    defer staging.deinit();
    const name = "00000000000000000000000000000000";
    const orphan = try staging.directory.createFile(std.testing.io, name, .{
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    try orphan.writeStreamingAll(std.testing.io, "interrupted control state");
    orphan.close(std.testing.io);
    for (0..2) |_| {
        try std.testing.expectError(
            error.ReservationRecoveryRequired,
            fixture.budget.reserve(allocator, requestFor("foreign-stage", 1), observation()),
        );
    }
    var snapshot = try fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 0), snapshot.reserved.logical_total);
    const retained = try staging.readAlloc(allocator, name, 100);
    defer allocator.free(retained);
    try std.testing.expectEqualStrings("interrupted control state", retained);
    var dir = try staging.directory.openDir(std.testing.io, ".", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iter = dir.iterate();
    try std.testing.expect(try iter.next(std.testing.io) != null);
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try iter.next(std.testing.io));
}

test "reservation directory sync failure retains its published charge" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(Charge.zero);
    defer fixture.deinit();
    const Hook = struct {
        var calls: usize = 0;

        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            calls += 1;
            if (calls == 2) return error.InputOutput;
            return std.testing.io.vtable.fileSync(userdata, file);
        }
    };
    Hook.calls = 0;
    var vtable = std.testing.io.vtable.*;
    vtable.fileSync = Hook.sync;
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var failing = try fixture.reopen(injected);
    defer failing.deinit();
    const request = requestFor("directory-sync", 30);
    try std.testing.expectError(
        error.ReservationDurabilityUncertain,
        failing.reserve(allocator, request, observation()),
    );
    var snapshot = try fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 30), snapshot.reserved.logical_total);
    const retry = try fixture.budget.reserve(allocator, request, observation());
    try std.testing.expect(retry.reused);
}

const CommitFixture = struct {
    fixture: Fixture,
    target: []u8,
    transactions_dir: []u8,
    request: Request,
    reservation: Receipt,
    publication_identity: ?[32]u8 = null,

    const text = "reserved native payload\n";

    fn init() !CommitFixture {
        const allocator = std.testing.allocator;
        var fixture = try Fixture.init(Charge.zero);
        errdefer fixture.deinit();
        var policy = test_policy;
        policy.limits = .{
            .logical_total = 32 * 1024 * 1024,
            .staging = 16 * 1024 * 1024,
            .metadata = 16 * 1024 * 1024,
        };
        const limits = policy.limits;
        try fixture.budget.updatePolicy(
            allocator,
            "test-budget",
            1,
            policy,
            &.{ limits, limits },
        );
        try fixture.tmp.dir.createDir(std.testing.io, "store", .default_dir);
        const root = try fixture.tmp.dir.realPathFileAlloc(std.testing.io, "store", allocator);
        defer allocator.free(root);
        const target = try std.fs.path.join(allocator, &.{ root, "target" });
        errdefer allocator.free(target);
        const journals = try std.fs.path.join(allocator, &.{ root, "transactions" });
        errdefer allocator.free(journals);
        const metadata = transactions.reserved_transaction_metadata_max_bytes +
            Budget.max_terminal_bytes;
        var request = requestFor("native-operation", metadata + 2 * text.len);
        request.charge.staging = text.len;
        request.charge.metadata = metadata;
        const reservation = try fixture.budget.reserve(allocator, request, observation());
        return .{
            .fixture = fixture,
            .target = target,
            .transactions_dir = journals,
            .request = request,
            .reservation = reservation,
        };
    }

    fn deinit(self: *CommitFixture) void {
        std.testing.allocator.free(self.target);
        std.testing.allocator.free(self.transactions_dir);
        self.fixture.deinit();
    }

    fn associate(self: *CommitFixture, io: std.Io) !void {
        try self.fixture.budget.associateSource(
            std.testing.allocator,
            .init(io, std.Io.Dir.cwd()),
            self.transactions_dir,
            .{
                .request = self.request,
                .reservation = self.reservation,
                .free_space = observation(),
                .transaction = .{ .owner = accountingOwner(self.request) },
            },
        );
    }

    fn commit(self: *CommitFixture, io: std.Io) !transactions.ControlledTransactionReceipt {
        const mutation: codec.TransactionMutation = .{
            .path = self.target,
            .text = text,
            .content_mode = .raw,
            .expectation = .{ .expected_exists = false },
            .max_bytes = 1024,
        };
        return self.fixture.budget.commitReserved(
            std.testing.allocator,
            .init(io, std.Io.Dir.cwd()),
            self.transactions_dir,
            &.{mutation},
            .{
                .request = self.request,
                .reservation = self.reservation,
                .free_space = observation(),
                .transaction = .{ .owner = accountingOwner(self.request) },
                .publication_identity = self.publication_identity,
            },
        );
    }
};

test "publication identity rejects another terminal despite identical existing payload" {
    const allocator = std.testing.allocator;
    const mismatch = error.ReservationIdentityMismatch;
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const identity: [32]u8 = @splat(1);
    const other: [32]u8 = @splat(2);
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    fixture.publication_identity = identity;
    const first = try fixture.commit(std.testing.io);
    defer first.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, first.semantic);
    const observed = (try fixture.fixture.budget.observedPublication(
        allocator,
        fs,
        fixture.request,
        identity,
    )).?;
    defer observed.transaction.deinit(allocator);
    try std.testing.expectEqualStrings(
        first.transaction.transaction_id,
        observed.transaction.transaction_id,
    );
    const recovered = try fixture.fixture.budget.reconcilePublication(
        allocator,
        fs,
        fixture.request,
        observation(),
        identity,
    );
    defer recovered.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, recovered.semantic);
    try std.testing.expectError(mismatch, fixture.fixture.budget.observedPublication(
        allocator,
        fs,
        fixture.request,
        other,
    ));
    try std.testing.expectError(mismatch, fixture.fixture.budget.reconcilePublication(
        allocator,
        fs,
        fixture.request,
        observation(),
        other,
    ));
    try std.testing.expectError(mismatch, fixture.fixture.budget.restartAbortedPublication(
        allocator,
        fs,
        fixture.request,
        observation(),
        other,
    ));
    fixture.publication_identity = other;
    try std.testing.expectError(mismatch, fixture.commit(std.testing.io));
    fixture.publication_identity = null;
    try std.testing.expectError(mismatch, fixture.commit(std.testing.io));
    fixture.publication_identity = identity;
    const retry = try fixture.commit(std.testing.io);
    defer retry.transaction.deinit(allocator);
    try std.testing.expectEqualStrings(
        first.transaction.transaction_id,
        retry.transaction.transaction_id,
    );
}

test "publication identity checks pending binding before native recovery" {
    const allocator = std.testing.allocator;
    const mismatch = error.ReservationIdentityMismatch;
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const identity: [32]u8 = @splat(1);
    const other: [32]u8 = @splat(2);
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    fixture.publication_identity = identity;
    StoreIoProbe.mode = .fail_publication;
    var table = StoreIoProbe.vtable();
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    const failed = try fixture.commit(injected);
    defer failed.transaction.deinit(allocator);
    try std.testing.expectEqual(.recovery_required, failed.semantic);
    try std.testing.expectEqual(null, try fixture.fixture.budget.observedPublication(
        allocator,
        fs,
        fixture.request,
        identity,
    ));
    try std.testing.expectError(mismatch, fixture.fixture.budget.observedPublication(
        allocator,
        fs,
        fixture.request,
        other,
    ));
    try std.testing.expectError(mismatch, fixture.fixture.budget.reconcilePublication(
        allocator,
        fs,
        fixture.request,
        observation(),
        other,
    ));
    fixture.publication_identity = other;
    try std.testing.expectError(mismatch, fixture.commit(std.testing.io));
    var pending = try fixture.fixture.budget.inspect(allocator);
    defer pending.deinit();
    try std.testing.expectEqual(@as(usize, 1), pending.parsed.value.reservations.len);
    try std.testing.expect(!filesystem.fileExists(fs, fixture.target));
    const recovered = try fixture.fixture.budget.reconcilePublication(
        allocator,
        fs,
        fixture.request,
        observation(),
        identity,
    );
    defer recovered.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, recovered.semantic);
}

test "publication identity survives aborted restart and rejects retargeting" {
    const allocator = std.testing.allocator;
    const mismatch = error.ReservationIdentityMismatch;
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const identity: [32]u8 = @splat(1);
    const other: [32]u8 = @splat(2);
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    fixture.publication_identity = identity;
    try abortCommitFixture(&fixture);
    try std.testing.expectError(mismatch, fixture.fixture.budget.restartAbortedPublication(
        allocator,
        fs,
        fixture.request,
        observation(),
        other,
    ));
    const aborted = (try fixture.fixture.budget.observedPublication(
        allocator,
        fs,
        fixture.request,
        identity,
    )).?;
    defer aborted.transaction.deinit(allocator);
    try std.testing.expectEqual(.aborted, aborted.semantic);
    fixture.reservation = try fixture.fixture.budget.restartAbortedPublication(
        allocator,
        fs,
        fixture.request,
        observation(),
        identity,
    );
    try std.testing.expectEqual(null, try fixture.fixture.budget.observedPublication(
        allocator,
        fs,
        fixture.request,
        identity,
    ));
    try std.testing.expectError(mismatch, fixture.fixture.budget.observedPublication(
        allocator,
        fs,
        fixture.request,
        other,
    ));
    try std.testing.expectError(mismatch, fixture.fixture.budget.reconcilePublication(
        allocator,
        fs,
        fixture.request,
        observation(),
        other,
    ));
    fixture.publication_identity = other;
    try std.testing.expectError(mismatch, fixture.commit(std.testing.io));
    fixture.publication_identity = null;
    try std.testing.expectError(mismatch, fixture.commit(std.testing.io));
    fixture.publication_identity = identity;
    const committed = try fixture.commit(std.testing.io);
    defer committed.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, committed.semantic);
}

test "publication identity preserves legacy null binding encoding and retry digest" {
    const allocator = std.testing.allocator;
    const mismatch = error.ReservationIdentityMismatch;
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const first = try fixture.commit(std.testing.io);
    defer first.transaction.deinit(allocator);
    const terminal = (try fixture.fixture.budget.readTerminal(allocator, fixture.request)).?;
    defer terminal.deinit();
    const bytes = try std.json.Stringify.valueAlloc(allocator, terminal.value.binding, .{});
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "publication_identity") == null);
    const parsed = try std.json.parseFromSlice(Binding, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(null, parsed.value.publication_identity);
    try std.testing.expectEqual(try hashValue(terminal.value.binding), try hashValue(parsed.value));
    const options: CommitOptions = .{
        .request = fixture.request,
        .reservation = fixture.reservation,
        .free_space = observation(),
        .transaction = .{ .owner = accountingOwner(fixture.request) },
    };
    const mutations: []const codec.TransactionMutation = &.{};
    try std.testing.expectEqual(try hashValue(.{
        .target_class = options.target_class,
        .target_classes = options.target_classes,
        .mutations = mutations,
    }), try requestDigest(mutations, options));
    try std.testing.expectError(mismatch, fixture.fixture.budget.observedPublication(
        allocator,
        fs,
        fixture.request,
        @splat(1),
    ));
    try std.testing.expectError(mismatch, fixture.fixture.budget.reconcilePublication(
        allocator,
        fs,
        fixture.request,
        observation(),
        @splat(1),
    ));
    const retry = try fixture.commit(std.testing.io);
    defer retry.transaction.deinit(allocator);
    try std.testing.expectEqualStrings(
        first.transaction.transaction_id,
        retry.transaction.transaction_id,
    );
}

test "reserved native commit settles measured usage and retries from exact terminal evidence" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const first = try fixture.commit(std.testing.io);
    defer first.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, first.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), first.accounting_error);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), snapshot.parsed.value.reservations.len);
    try std.testing.expectEqual(@as(u64, 0), snapshot.reserved.logical_total);
    try std.testing.expectEqual(
        snapshot.used.logical_total,
        snapshot.used.metadata + CommitFixture.text.len,
    );
    try std.testing.expect(snapshot.used.logical_total < fixture.request.charge.logical_total);
    const retry = try fixture.commit(std.testing.io);
    defer retry.transaction.deinit(allocator);
    try std.testing.expect(retry.reused);
    try std.testing.expectEqualStrings(
        first.transaction.transaction_id,
        retry.transaction.transaction_id,
    );
    const reserved_again = try fixture.fixture.budget.reserve(
        allocator,
        fixture.request,
        observation(),
    );
    try std.testing.expectEqual(.committed, reserved_again.status);
    try std.testing.expectError(error.ReservationTerminal, fixture.fixture.budget.extend(
        allocator,
        fixture.request,
        observation(),
    ));
}

const StoreIoProbe = struct {
    var stage_handle: ?@FieldType(std.Io.File, "handle") = null;
    var mode: enum { fail_stage, fail_publication, probe_locks, change_policy } = .fail_stage;
    var budget: ?*Budget = null;
    var stage_admitted: bool = false;
    var publication_busy: bool = false;
    var policy_changed: bool = false;

    fn create(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        name: []const u8,
        options: std.Io.Dir.CreateFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        const file = try std.testing.io.vtable.dirCreateFile(userdata, dir, name, options);
        if (std.mem.startsWith(u8, name, codec.transaction_stage_prefix)) {
            stage_handle = file.handle;
        }
        return file;
    }

    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        if (stage_handle != null and file.handle == stage_handle.?) {
            stage_handle = null;
            if (mode == .fail_stage) return error.InputOutput;
            if (mode == .probe_locks) {
                var request = requestFor("during-staging", 1);
                request.store_id = "b";
                if (budget.?.reserve(std.heap.page_allocator, request, observation())) |_| {
                    stage_admitted = true;
                } else |_| {}
            }
            if (mode == .change_policy) {
                if (changePolicy()) |_| {
                    policy_changed = true;
                } else |_| {}
            }
        }
        return std.testing.io.vtable.fileSync(userdata, file);
    }

    fn rename(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_name: []const u8,
        new_dir: std.Io.Dir,
        new_name: []const u8,
    ) std.Io.Dir.RenameError!void {
        if (std.mem.startsWith(u8, old_name, codec.transaction_stage_prefix) and
            std.mem.eql(u8, new_name, "target"))
        {
            if (mode == .fail_publication) return error.HardwareFailure;
            if (mode == .probe_locks) {
                var request = requestFor("during-publication", 1);
                request.store_id = "b";
                _ = budget.?.reserve(std.heap.page_allocator, request, observation()) catch |err| {
                    publication_busy = err == error.LockBusy;
                    return std.testing.io.vtable.dirRename(
                        userdata,
                        old_dir,
                        old_name,
                        new_dir,
                        new_name,
                    );
                };
            }
        }
        return std.testing.io.vtable.dirRename(userdata, old_dir, old_name, new_dir, new_name);
    }

    fn vtable() std.Io.VTable {
        stage_handle = null;
        stage_admitted = false;
        publication_busy = false;
        policy_changed = false;
        var table = std.testing.io.vtable.*;
        table.dirCreateFile = create;
        table.fileSync = sync;
        table.dirRename = rename;
        return table;
    }

    fn changePolicy() !void {
        const allocator = std.heap.page_allocator;
        var snapshot = try budget.?.inspect(allocator);
        defer snapshot.deinit();
        const state = snapshot.parsed.value;
        var policy = state.policy;
        policy.minimum_free_bytes += 1;
        try budget.?.updatePolicy(
            allocator,
            state.budget_id,
            state.generation,
            policy,
            &.{ state.stores[0].limits, state.stores[1].limits },
        );
    }
};

test "reserved staging failure refunds only after native durable abort" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    StoreIoProbe.mode = .fail_stage;
    var table = StoreIoProbe.vtable();
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    const failed = try fixture.commit(injected);
    defer failed.transaction.deinit(allocator);
    try std.testing.expectEqual(.recovery_required, failed.semantic);
    try std.testing.expectEqual(error.InputOutput, failed.failure.?);
    var before = try fixture.fixture.budget.inspect(allocator);
    defer before.deinit();
    try std.testing.expectEqual(
        fixture.request.charge.logical_total,
        before.reserved.logical_total,
    );
    try std.testing.expectError(
        error.TransactionReservationRequired,
        transactions.recoverTransaction(
            .init(std.testing.io, std.Io.Dir.cwd()),
            allocator,
            failed.transaction.transaction_dir,
        ),
    );
    const reconciled = try fixture.fixture.budget.reconcile(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.request,
        observation(),
    );
    defer reconciled.transaction.deinit(allocator);
    try std.testing.expectEqual(.aborted, reconciled.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), reconciled.accounting_error);
    var after = try fixture.fixture.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expectEqual(@as(u64, 0), after.reserved.logical_total);
    try std.testing.expectEqual(after.used.metadata, after.used.logical_total);
    try std.testing.expect(after.used.logical_total < fixture.request.charge.logical_total);
    const retry = try fixture.commit(std.testing.io);
    defer retry.transaction.deinit(allocator);
    try std.testing.expectEqual(.aborted, retry.semantic);
    try std.testing.expect(retry.reused);
}

test "reserved prepared publication failure recovers under the same budget authority" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    StoreIoProbe.mode = .fail_publication;
    var table = StoreIoProbe.vtable();
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    const failed = try fixture.commit(injected);
    defer failed.transaction.deinit(allocator);
    try std.testing.expectEqual(.recovery_required, failed.semantic);
    const reconciled = try fixture.fixture.budget.reconcile(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.request,
        observation(),
    );
    defer reconciled.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, reconciled.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), reconciled.accounting_error);
    const actual = try filesystem.readRegularFileNoSymlink(
        .init(std.testing.io, std.Io.Dir.cwd()),
        allocator,
        fixture.target,
        1024,
    );
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(CommitFixture.text, actual);
}

test "reserved publication holds budget authority but payload staging does not" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    StoreIoProbe.mode = .probe_locks;
    StoreIoProbe.budget = &fixture.fixture.budget;
    var table = StoreIoProbe.vtable();
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    const result = try fixture.commit(injected);
    defer result.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, result.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), result.accounting_error);
    try std.testing.expect(StoreIoProbe.stage_admitted);
    try std.testing.expect(StoreIoProbe.publication_busy);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 1), snapshot.reserved.logical_total);
}

test "committed semantic output remains committed across interrupted native accounting" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    var table = std.testing.io.vtable.*;
    table.dirRename = struct {
        fn rename(
            userdata: ?*anyopaque,
            old_dir: std.Io.Dir,
            old_name: []const u8,
            new_dir: std.Io.Dir,
            new_name: []const u8,
        ) std.Io.Dir.RenameError!void {
            try std.testing.io.vtable.dirRename(userdata, old_dir, old_name, new_dir, new_name);
            if (std.mem.startsWith(u8, old_name, codec.transaction_stage_prefix) and
                std.mem.eql(u8, new_name, Budget.state_leaf)) return error.HardwareFailure;
        }
    }.rename;
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    fixture.fixture.budget.root.io = injected;
    const result = fixture.commit(std.testing.io) catch |err| {
        fixture.fixture.budget.root.io = std.testing.io;
        return err;
    };
    fixture.fixture.budget.root.io = std.testing.io;
    defer result.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, result.semantic);
    try std.testing.expectEqual(error.HardwareFailure, result.accounting_error.?);
    try std.testing.expectError(
        error.ReservationRecoveryRequired,
        fixture.fixture.budget.inspect(allocator),
    );
    const reconciled = try fixture.fixture.budget.reconcile(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.request,
        observation(),
    );
    defer reconciled.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, reconciled.semantic);
    try std.testing.expect(reconciled.reused);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 0), snapshot.reserved.logical_total);
    try std.testing.expectEqual(
        snapshot.used.metadata + CommitFixture.text.len,
        snapshot.used.logical_total,
    );
}

test "reserved publication rejects an intervening policy generation before target rename" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    StoreIoProbe.mode = .change_policy;
    StoreIoProbe.budget = &fixture.fixture.budget;
    var table = StoreIoProbe.vtable();
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    const result = try fixture.commit(injected);
    defer result.transaction.deinit(allocator);
    try std.testing.expect(StoreIoProbe.policy_changed);
    try std.testing.expectEqual(.recovery_required, result.semantic);
    try std.testing.expectEqual(error.ReservationChanged, result.failure.?);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(
        std.testing.io,
        fixture.target,
        .{ .follow_symlinks = false },
    ));
    const recovered = try fixture.fixture.budget.reconcile(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.request,
        observation(),
    );
    defer recovered.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, recovered.semantic);
}

test "terminal evidence frees bounded active capacity without forgetting operation identity" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const rows = try allocator.alloc(Record, Budget.max_reservations);
    defer allocator.free(rows);
    var initialized: usize = 1;
    defer for (rows[1..initialized]) |row| allocator.free(row.operation_id);
    {
        var lock = try fixture.fixture.budget.exclusive(allocator);
        defer lock.close(std.testing.io);
        var snapshot = try fixture.fixture.budget.load(allocator);
        defer snapshot.deinit();
        var state = snapshot.parsed.value;
        rows[0] = state.reservations[0];
        for (rows[1..], 1..) |*row, index| {
            row.* = .{
                .store_id = "b",
                .operation_id = try allocator.print("waiting-{d}", .{index}),
                .charge = Charge.zero,
                .generation = state.generation,
            };
            initialized += 1;
        }
        state.reservations = rows;
        state.generation = try sum(state.generation, 1);
        try validateState(state);
        try fixture.fixture.budget.publish(allocator, state);
    }
    var extra = requestFor("next-operation", 0);
    extra.store_id = "b";
    try std.testing.expectError(
        error.ReservationLimit,
        fixture.fixture.budget.reserve(allocator, extra, observation()),
    );
    const completed = try fixture.commit(std.testing.io);
    defer completed.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, completed.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), completed.accounting_error);
    _ = try fixture.fixture.budget.reserve(allocator, extra, observation());
    const retry = try fixture.commit(std.testing.io);
    defer retry.transaction.deinit(allocator);
    try std.testing.expect(retry.reused);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(
        @as(usize, Budget.max_reservations),
        snapshot.parsed.value.reservations.len,
    );
}

fn interruptBeforeJournal(fixture: *CommitFixture) !transactions.ControlledTransactionReceipt {
    var table = std.testing.io.vtable.*;
    table.dirCreateFile = struct {
        fn create(
            userdata: ?*anyopaque,
            dir: std.Io.Dir,
            name: []const u8,
            options: std.Io.Dir.CreateFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            if (std.mem.eql(u8, name, transactions.reservation_pin_leaf)) {
                return error.AccessDenied;
            }
            return std.testing.io.vtable.dirCreateFile(userdata, dir, name, options);
        }
    }.create;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    return fixture.commit(io);
}

fn inspectFixtureDependencies(
    fixture: *CommitFixture,
    selected: []const []const u8,
    limits: transactions.TransactionDependencyLimits,
) !DependencySnapshot {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var mutated = false;
    try transactions.ensureTransactionDependencyCoordination(
        fs,
        std.testing.allocator,
        fixture.transactions_dir,
        &mutated,
    );
    return fixture.fixture.budget.snapshotDependencies(
        std.testing.allocator,
        fs,
        fixture.transactions_dir,
        selected,
        null,
        .{
            .budget_id = fixture.request.budget_id,
            .store_id = fixture.request.store_id,
            .limits = limits,
        },
    );
}

test "reservation dependencies retain exact settled evidence and release budget custody" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const committed = try fixture.commit(std.testing.io);
    defer committed.transaction.deinit(allocator);
    var snapshot = try inspectFixtureDependencies(&fixture, &.{fixture.target}, .{});
    defer snapshot.deinit(allocator);
    try std.testing.expect(!snapshot.pending);
    try std.testing.expectEqual(@as(usize, 1), snapshot.settled_transactions);
    try std.testing.expectEqual(@as(usize, 2), snapshot.evidence.len);
    try std.testing.expectEqual(.supplied_budget_store, snapshot.coverage);
    try std.testing.expectEqualStrings(fixture.request.budget_id, snapshot.budget_id);
    try std.testing.expectEqualStrings(fixture.request.store_id, snapshot.store_id);
    try std.testing.expect(snapshot.metadata_bytes_read > snapshot.budget_bytes_read);
    var terminal = try parseTerminalBytes(allocator, snapshot.evidence[0].bytes);
    defer terminal.deinit();
    try std.testing.expectEqualStrings(
        committed.transaction.transaction_id,
        terminal.value.binding.transaction_id,
    );
    var request = requestFor("snapshot-unrelated-reservation", 0);
    request.store_id = "b";
    _ = try fixture.fixture.budget.reserve(allocator, request, observation());
    try std.testing.expectError(
        error.LockBusy,
        filesystem.acquireCasAdvisoryLock(
            .init(
                std.testing.io,
                std.Io.Dir.cwd(),
            ),
            allocator,
            fixture.target,
        ),
    );
}

test "reservation dependencies classify absent and pin-only pending intents" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |pin_prefix| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        const interrupted = try interruptBeforeJournal(&fixture);
        defer interrupted.transaction.deinit(allocator);
        try std.testing.expectEqual(.recovery_required, interrupted.semantic);
        if (pin_prefix) try installFixtureReservationPin(&fixture);
        var snapshot = try inspectFixtureDependencies(&fixture, &.{fixture.target}, .{});
        defer snapshot.deinit(allocator);
        try std.testing.expect(snapshot.pending);
        try std.testing.expectEqual(@as(usize, 1), snapshot.pending_intents);
        try std.testing.expectEqual(@as(usize, 1), snapshot.evidence.len);
        try std.testing.expectEqual(@as(usize, 1), snapshot.transactions.transactions.len);
        const pending = snapshot.transactions.transactions[0];
        try std.testing.expectEqual(.supplied_preparation, pending.record_source);
        try std.testing.expectEqual(.preparing, pending.state);
        var pin_seen = false;
        for (pending.entries) |dependency| {
            if (dependency.kind == .journal) try std.testing.expect(!dependency.present);
            if (dependency.kind == .reservation_pin) pin_seen = dependency.present;
        }
        try std.testing.expectEqual(pin_prefix, pin_seen);
    }
}

test "reservation dependencies accept unbound and disjoint pin-only intents" {
    const allocator = std.testing.allocator;
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const selected = try std.fs.path.join(allocator, &.{
        std.fs.path.dirname(fixture.target).?, "unrelated",
    });
    defer allocator.free(selected);
    const lock = try filesystem.acquireCasAdvisoryLock(fs, allocator, selected);
    lock.close(fs.io);
    {
        var snapshot = try inspectFixtureDependencies(&fixture, &.{selected}, .{});
        defer snapshot.deinit(allocator);
        try std.testing.expect(!snapshot.pending);
        try std.testing.expectEqual(@as(usize, 1), snapshot.unbound_reservations);
        try std.testing.expectEqual(@as(usize, 0), snapshot.transactions.transactions.len);
    }
    const interrupted = try interruptBeforeJournal(&fixture);
    defer interrupted.transaction.deinit(allocator);
    try installFixtureReservationPin(&fixture);
    var target = try fs.directory().createFile(fs.io, fixture.target, .{ .exclusive = true });
    defer target.close(fs.io);
    try target.setLength(fs.io, 4 * 1024 * 1024 * 1024);
    try target.setPermissions(fs.io, .fromMode(0o000));
    defer target.setPermissions(fs.io, .fromMode(0o600)) catch |err| {
        std.debug.panic("fixture permissions: {t}", .{err});
    };
    var snapshot = try inspectFixtureDependencies(&fixture, &.{selected}, .{});
    defer snapshot.deinit(allocator);
    try std.testing.expect(!snapshot.pending);
    try std.testing.expectEqual(@as(usize, 1), snapshot.disjoint_intents);
    try std.testing.expectEqual(@as(usize, 0), snapshot.transactions.transactions.len);
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), (try target.stat(fs.io)).size);
}

test "reservation dependencies enforce one aggregate metadata byte ceiling" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const committed = try fixture.commit(std.testing.io);
    defer committed.transaction.deinit(allocator);
    var required: usize = 0;
    {
        var snapshot = try inspectFixtureDependencies(&fixture, &.{fixture.target}, .{});
        defer snapshot.deinit(allocator);
        required = snapshot.metadata_bytes_read;
        try std.testing.expect(required > snapshot.transactions.journal_bytes_read);
        try std.testing.expect(required > snapshot.budget_bytes_read);
    }
    try std.testing.expectError(error.ReservationLimit, inspectFixtureDependencies(
        &fixture,
        &.{fixture.target},
        .{ .journal_bytes = required - 1 },
    ));
    var exact = try inspectFixtureDependencies(
        &fixture,
        &.{fixture.target},
        .{ .journal_bytes = required },
    );
    defer exact.deinit(allocator);
    try std.testing.expectEqual(required, exact.metadata_bytes_read);
}

test "reservation dependencies reject corrupt bound intent and root identity" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |corrupt_root| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        const interrupted = try interruptBeforeJournal(&fixture);
        defer interrupted.transaction.deinit(allocator);
        {
            var snapshot = try fixture.fixture.budget.inspect(allocator);
            defer snapshot.deinit();
            var state = snapshot.parsed.value;
            var row = state.reservations[0];
            if (corrupt_root) {
                row.binding.?.root_identity.inode +%= 1;
            } else row.binding.?.intent_digest[0] ^= 1;
            state.reservations = &.{row};
            try fixture.fixture.budget.publish(allocator, state);
        }
        try std.testing.expectError(
            error.TransactionReservationMismatch,
            inspectFixtureDependencies(
                &fixture,
                &.{fixture.target},
                .{},
            ),
        );
    }
}

test "reservation dependencies reject missing settled terminal and foreign context" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const committed = try fixture.commit(std.testing.io);
    defer committed.transaction.deinit(allocator);
    {
        var snapshot = try inspectFixtureDependencies(&fixture, &.{fixture.target}, .{});
        snapshot.deinit(allocator);
    }
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectError(
        error.ReservationIdentityMismatch,
        fixture.fixture.budget.snapshotDependencies(
            allocator,
            fs,
            fixture.transactions_dir,
            &.{fixture.target},
            null,
            .{
                .budget_id = "foreign",
                .store_id = fixture.request.store_id,
            },
        ),
    );
    var terminals = try fixture.fixture.budget.root.openChild(Budget.terminal_leaf, .read_only);
    defer terminals.deinit();
    const name = terminalName(fixture.request);
    try terminals.directory.deleteFile(std.testing.io, &name);
    try std.testing.expectError(
        error.ReservationRecoveryRequired,
        inspectFixtureDependencies(
            &fixture,
            &.{fixture.target},
            .{},
        ),
    );
}

test "reservation dependencies preserve absolute evidence through a pinned moved root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |settled| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        const outcome = if (settled)
            try fixture.commit(io)
        else
            try interruptBeforeJournal(&fixture);
        defer outcome.transaction.deinit(allocator);
        if (!settled) try installFixtureReservationPin(&fixture);
        var original = try inspectFixtureDependencies(&fixture, &.{fixture.target}, .{});
        original.deinit(allocator);
        var source = try fixture.fixture.tmp.dir.openDir(io, "store", .{});
        defer source.close(io);
        const origin = try source.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(origin);
        try fixture.fixture.tmp.dir.rename("store", fixture.fixture.tmp.dir, "moved", io);
        try fixture.fixture.tmp.dir.createDir(io, "store", .default_dir);
        try fixture.fixture.tmp.dir.writeFile(io, .{
            .sub_path = "store/target",
            .data = "replacement must never be consulted",
        });
        var snapshot = try fixture.fixture.budget.snapshotDependencies(
            allocator,
            Fs.anchored(io, source),
            "./transactions",
            &.{"./target"},
            .{ .recorded_control_root = origin },
            .{
                .budget_id = fixture.request.budget_id,
                .store_id = fixture.request.store_id,
            },
        );
        defer snapshot.deinit(allocator);
        try std.testing.expectEqual(!settled, snapshot.pending);
        try std.testing.expectEqual(@as(usize, 1), snapshot.transactions.transactions.len);
        if (settled) {
            try std.testing.expectEqual(@as(usize, 2), snapshot.evidence.len);
            try std.testing.expect(std.mem.indexOf(u8, snapshot.evidence[0].bytes, origin) != null);
        } else try std.testing.expectEqual(@as(usize, 1), snapshot.pending_intents);
        for (snapshot.transactions.transactions[0].entries) |entry| {
            try std.testing.expect(!std.fs.path.isAbsolute(entry.path));
        }
    }
}

fn installFixtureReservationPin(fixture: *CommitFixture) !void {
    const allocator = std.testing.allocator;
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var state = try fixture.fixture.budget.inspect(allocator);
    defer state.deinit();
    const binding = state.parsed.value.reservations[0].binding.?;
    try filesystem.ensureDirectoryPathNoSymlinks(fs, binding.transaction_dir);
    const pin = try renderPin(allocator, fixture.request, binding);
    defer allocator.free(pin);
    const path = try std.fs.path.join(
        allocator,
        &.{
            binding.transaction_dir,
            transactions.reservation_pin_leaf,
        },
    );
    defer allocator.free(path);
    try filesystem.writeTextCreateNew(fs, allocator, path, pin, .{});
}

test "reserved prejournal interruption reconstructs native abort with original identity" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |pin_prefix| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        const failed = try interruptBeforeJournal(&fixture);
        defer failed.transaction.deinit(allocator);
        try std.testing.expectEqual(.recovery_required, failed.semantic);
        try std.testing.expectEqual(error.AccessDenied, failed.failure.?);
        var snapshot = try fixture.fixture.budget.inspect(allocator);
        defer snapshot.deinit();
        const row = snapshot.parsed.value.reservations[0];
        try std.testing.expect(row.preparing_record != null);
        try std.testing.expectEqual(
            fixture.request.charge.logical_total,
            snapshot.reserved.logical_total,
        );
        if (pin_prefix) {
            const fs: Fs = .init(std.testing.io, std.Io.Dir.cwd());
            try filesystem.ensureDirectoryPathNoSymlinks(fs, row.binding.?.transaction_dir);
            const pin = try renderPin(allocator, fixture.request, row.binding.?);
            defer allocator.free(pin);
            const path = try std.fs.path.join(allocator, &.{
                row.binding.?.transaction_dir, transactions.reservation_pin_leaf,
            });
            defer allocator.free(path);
            try filesystem.writeTextCreateNew(fs, allocator, path, pin, .{});
        }
        const retry = try fixture.commit(std.testing.io);
        defer retry.transaction.deinit(allocator);
        try std.testing.expectEqual(.aborted, retry.semantic);
        try std.testing.expectEqual(@as(?anyerror, null), retry.accounting_error);
        try std.testing.expectEqualStrings(
            failed.transaction.transaction_id,
            retry.transaction.transaction_id,
        );
        const again = try fixture.commit(std.testing.io);
        defer again.transaction.deinit(allocator);
        try std.testing.expect(again.reused);
        try std.testing.expectEqual(.aborted, again.semantic);
        var final = try fixture.fixture.budget.inspect(allocator);
        defer final.deinit();
        try std.testing.expectEqual(@as(u64, 0), final.reserved.logical_total);
        try std.testing.expect(final.used.metadata > 0);
        try std.testing.expectEqual(final.used.metadata, final.used.logical_total);
    }
}

test "reserved bind publication lost reply reconciles persisted identity" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    try fixture.associate(std.testing.io);
    var table = std.testing.io.vtable.*;
    table.dirRename = struct {
        fn rename(
            userdata: ?*anyopaque,
            old_dir: std.Io.Dir,
            old_name: []const u8,
            new_dir: std.Io.Dir,
            new_name: []const u8,
        ) std.Io.Dir.RenameError!void {
            try std.testing.io.vtable.dirRename(userdata, old_dir, old_name, new_dir, new_name);
            if (std.mem.eql(u8, new_name, Budget.state_leaf)) return error.HardwareFailure;
        }
    }.rename;
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    fixture.fixture.budget.root.io = injected;
    const failed = fixture.commit(std.testing.io);
    fixture.fixture.budget.root.io = std.testing.io;
    try std.testing.expectError(error.ReservationPublicationUnknown, failed);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    const binding = snapshot.parsed.value.reservations[0].binding.?;
    const retry = try fixture.commit(std.testing.io);
    defer retry.transaction.deinit(allocator);
    try std.testing.expectEqual(.aborted, retry.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), retry.accounting_error);
    try std.testing.expectEqualStrings(binding.transaction_id, retry.transaction.transaction_id);
    var final = try fixture.fixture.budget.inspect(allocator);
    defer final.deinit();
    try std.testing.expectEqual(
        snapshot.parsed.value.generation + 1,
        final.parsed.value.generation,
    );
}

test "reserved prejournal reconciliation retains charge for changed targets and unknown prefixes" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "foreign", transactions.reservation_pin_leaf, "changed-target" }) |case| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        const failed = try interruptBeforeJournal(&fixture);
        defer failed.transaction.deinit(allocator);
        const fs: Fs = .init(std.testing.io, std.Io.Dir.cwd());
        const path = if (std.mem.eql(u8, case, "changed-target"))
            try allocator.dupe(u8, fixture.target)
        else path: {
            try filesystem.ensureDirectoryPathNoSymlinks(fs, failed.transaction.transaction_dir);
            break :path try std.fs.path.join(
                allocator,
                &.{ failed.transaction.transaction_dir, case },
            );
        };
        defer allocator.free(path);
        try filesystem.writeTextCreateNew(fs, allocator, path, "unrelated", .{});
        const retry = try fixture.commit(std.testing.io);
        defer retry.transaction.deinit(allocator);
        try std.testing.expectEqual(.recovery_required, retry.semantic);
        try std.testing.expect(retry.failure != null);
        var snapshot = try fixture.fixture.budget.inspect(allocator);
        defer snapshot.deinit();
        try std.testing.expectEqual(
            fixture.request.charge.logical_total,
            snapshot.reserved.logical_total,
        );
        const preserved = try filesystem.readRegularFileNoSymlink(fs, allocator, path, 1024);
        defer allocator.free(preserved);
        try std.testing.expectEqualStrings("unrelated", preserved);
    }
}

test "reserved prejournal reconciliation rejects replacement store root identity" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const failed = try interruptBeforeJournal(&fixture);
    defer failed.transaction.deinit(allocator);
    try fixture.fixture.tmp.dir.rename("store", fixture.fixture.tmp.dir, "retired", std.testing.io);
    try fixture.fixture.tmp.dir.createDir(std.testing.io, "store", .default_dir);
    try fixture.fixture.tmp.dir.createDir(std.testing.io, "store/transactions", .default_dir);
    try std.testing.expectError(
        error.TransactionReservationMismatch,
        fixture.commit(std.testing.io),
    );
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(
        fixture.request.charge.logical_total,
        snapshot.reserved.logical_total,
    );
    try std.testing.expectEqualStrings(
        failed.transaction.transaction_id,
        snapshot.parsed.value.reservations[0].binding.?.transaction_id,
    );
}

const MixedCommitFixture = struct {
    base: CommitFixture,
    manifest: []u8,

    const old_payload = "old payload bytes";
    const old_manifest = "old metadata";
    const new_manifest = "{\"version\":1}\n";

    fn init() !MixedCommitFixture {
        const allocator = std.testing.allocator;
        var base = try CommitFixture.init();
        errdefer base.deinit();
        const parent = std.fs.path.dirname(base.target).?;
        const manifest = try std.fs.path.join(allocator, &.{ parent, "manifest" });
        errdefer allocator.free(manifest);
        const fs: Fs = .init(std.testing.io, std.Io.Dir.cwd());
        try filesystem.writeTextCreateNew(fs, allocator, base.target, old_payload, .{});
        try filesystem.writeTextCreateNew(fs, allocator, manifest, old_manifest, .{});
        var snapshot = try base.fixture.budget.inspect(allocator);
        defer snapshot.deinit();
        var state = snapshot.parsed.value;
        var stores = [_]Store{ state.stores[0], state.stores[1] };
        stores[0].used = .{
            .logical_total = old_payload.len + old_manifest.len,
            .staging = 0,
            .metadata = old_manifest.len,
        };
        state.stores = &stores;
        try base.fixture.budget.publish(allocator, state);
        const metadata = transactions.reserved_transaction_metadata_max_bytes +
            Budget.max_terminal_bytes;
        const after = CommitFixture.text.len + new_manifest.len;
        base.request.charge = .{
            .logical_total = metadata + 2 * after,
            .staging = after,
            .metadata = metadata + new_manifest.len,
        };
        base.reservation = try base.fixture.budget.extend(allocator, base.request, observation());
        return .{ .base = base, .manifest = manifest };
    }

    fn deinit(self: *MixedCommitFixture) void {
        std.testing.allocator.free(self.manifest);
        self.base.deinit();
    }

    fn commit(
        self: *MixedCommitFixture,
        io: std.Io,
        default: TargetClass,
    ) !transactions.ControlledTransactionReceipt {
        const overrides: []const TargetClassification = if (default == .payload)
            &.{.{ .path = self.manifest, .class = .metadata }}
        else
            &.{.{ .path = self.base.target, .class = .payload }};
        return self.commitClasses(io, default, overrides);
    }

    fn commitClasses(
        self: *MixedCommitFixture,
        io: std.Io,
        default: TargetClass,
        overrides: []const TargetClassification,
    ) !transactions.ControlledTransactionReceipt {
        return self.base.fixture.budget.commitReserved(
            std.testing.allocator,
            .init(io, std.Io.Dir.cwd()),
            self.base.transactions_dir,
            &.{
                .{
                    .path = self.base.target,
                    .text = CommitFixture.text,
                    .content_mode = .raw,
                    .expectation = .{ .expected_exists = true },
                    .max_bytes = 1024,
                },
                .{
                    .path = self.manifest,
                    .text = new_manifest,
                    .content_mode = .raw,
                    .expectation = .{ .expected_exists = true },
                    .max_bytes = 1024,
                },
            },
            .{
                .request = self.base.request,
                .reservation = self.base.reservation,
                .free_space = observation(),
                .target_class = default,
                .target_classes = overrides,
                .transaction = .{ .owner = accountingOwner(self.base.request) },
            },
        );
    }

    fn expectSettled(self: *MixedCommitFixture, committed: bool) !void {
        const allocator = std.testing.allocator;
        var snapshot = try self.base.fixture.budget.inspect(allocator);
        defer snapshot.deinit();
        try std.testing.expectEqual(@as(u64, 0), snapshot.reserved.logical_total);
        const payload_bytes = if (committed) CommitFixture.text.len else old_payload.len;
        try std.testing.expectEqual(
            payload_bytes,
            snapshot.used.logical_total - snapshot.used.metadata,
        );
        const terminal = (try self.base.fixture.budget.readTerminal(
            allocator,
            self.base.request,
        )).?;
        defer terminal.deinit();
        const binding = terminal.value.binding;
        try std.testing.expectEqual(old_manifest.len, binding.before_metadata_bytes);
        try std.testing.expectEqual(new_manifest.len, binding.after_metadata_bytes);
        try std.testing.expectEqual(
            if (committed) old_manifest.len else 0,
            terminal.value.removed.metadata,
        );
    }
};

test "reserved mixed publication accounts manifest and payload replacements in one transaction" {
    const allocator = std.testing.allocator;
    for ([_]TargetClass{ .payload, .metadata }) |default| {
        var fixture = try MixedCommitFixture.init();
        defer fixture.deinit();
        const result = try fixture.commit(std.testing.io, default);
        defer result.transaction.deinit(allocator);
        try std.testing.expectEqual(.committed, result.semantic);
        try std.testing.expectEqual(@as(?anyerror, null), result.accounting_error);
        try fixture.expectSettled(true);
        const retry = try fixture.commit(std.testing.io, default);
        defer retry.transaction.deinit(allocator);
        try std.testing.expect(retry.reused);
        try std.testing.expectEqualStrings(
            result.transaction.transaction_id,
            retry.transaction.transaction_id,
        );
        try std.testing.expectError(
            error.ReservationIdentityMismatch,
            fixture.commit(std.testing.io, if (default == .payload) .metadata else .payload),
        );
    }
}

test "reserved mixed recovery retains per-target classes through a partially published prefix" {
    const allocator = std.testing.allocator;
    var fixture = try MixedCommitFixture.init();
    defer fixture.deinit();
    StoreIoProbe.mode = .fail_publication;
    var table = StoreIoProbe.vtable();
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    const failed = try fixture.commit(injected, .payload);
    defer failed.transaction.deinit(allocator);
    try std.testing.expectEqual(.recovery_required, failed.semantic);
    var snapshot = try fixture.base.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    const row = snapshot.parsed.value.reservations[0];
    try std.testing.expectEqual(@as(usize, 2), row.target_usage.len);
    try std.testing.expectEqual(TargetClass.metadata, row.target_usage[0].class);
    try std.testing.expectEqual(TargetClass.payload, row.target_usage[1].class);
    const recovered = try fixture.base.fixture.budget.reconcile(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.base.request,
        observation(),
    );
    defer recovered.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, recovered.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), recovered.accounting_error);
    try fixture.expectSettled(true);
}

fn commitPinned(fixture: *CommitFixture, fs: Fs) !transactions.ControlledTransactionReceipt {
    return fixture.fixture.budget.commitReserved(
        std.testing.allocator,
        fs,
        "./transactions",
        &.{.{
            .path = "./target",
            .text = CommitFixture.text,
            .content_mode = .raw,
            .expectation = .{ .expected_exists = false },
            .max_bytes = 1024,
        }},
        .{
            .request = fixture.request,
            .reservation = fixture.reservation,
            .free_space = observation(),
            .transaction = .{ .owner = accountingOwner(fixture.request) },
        },
    );
}

test "reserved relative publication requires pinned authority and rejects another pinned root" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    var store = try fixture.fixture.tmp.dir.openDir(std.testing.io, "store", .{});
    defer store.close(std.testing.io);
    try std.testing.expectError(
        error.NotAbsolute,
        commitPinned(&fixture, .init(std.testing.io, store)),
    );
    const first = try commitPinned(&fixture, .anchored(std.testing.io, store));
    defer first.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, first.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), first.accounting_error);
    const retry = try commitPinned(&fixture, .anchored(std.testing.io, store));
    defer retry.transaction.deinit(allocator);
    try std.testing.expect(retry.reused);
    try fixture.fixture.tmp.dir.createDir(std.testing.io, "other", .default_dir);
    var other = try fixture.fixture.tmp.dir.openDir(std.testing.io, "other", .{});
    defer other.close(std.testing.io);
    try std.testing.expectError(
        error.TransactionReservationMismatch,
        commitPinned(&fixture, .anchored(std.testing.io, other)),
    );
    try std.testing.expectError(
        error.TransactionReservationMismatch,
        fixture.fixture.budget.reconcile(
            allocator,
            .anchored(std.testing.io, other),
            fixture.request,
            observation(),
        ),
    );
}

test "reserved relative recovery uses its original pinned authority" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    var store = try fixture.fixture.tmp.dir.openDir(std.testing.io, "store", .{});
    defer store.close(std.testing.io);
    StoreIoProbe.mode = .fail_publication;
    var table = StoreIoProbe.vtable();
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    const first = try commitPinned(&fixture, .anchored(injected, store));
    defer first.transaction.deinit(allocator);
    try std.testing.expectEqual(.recovery_required, first.semantic);
    try fixture.fixture.tmp.dir.createDir(std.testing.io, "other", .default_dir);
    try fixture.fixture.tmp.dir.createDir(std.testing.io, "other/transactions", .default_dir);
    var other = try fixture.fixture.tmp.dir.openDir(std.testing.io, "other", .{});
    defer other.close(std.testing.io);
    const wrong = try fixture.fixture.budget.reconcile(
        allocator,
        .anchored(std.testing.io, other),
        fixture.request,
        observation(),
    );
    defer wrong.transaction.deinit(allocator);
    try std.testing.expectEqual(.recovery_required, wrong.semantic);
    try std.testing.expectEqual(error.TransactionReservationMismatch, wrong.failure.?);
    const recovered = try commitPinned(&fixture, .anchored(std.testing.io, store));
    defer recovered.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, recovered.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), recovered.accounting_error);
}

test "reserved mixed staging abort preserves classified baseline and releases only staging" {
    const allocator = std.testing.allocator;
    var fixture = try MixedCommitFixture.init();
    defer fixture.deinit();
    StoreIoProbe.mode = .fail_stage;
    var table = StoreIoProbe.vtable();
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    const failed = try fixture.commit(injected, .payload);
    defer failed.transaction.deinit(allocator);
    try std.testing.expectEqual(.recovery_required, failed.semantic);
    const recovered = try fixture.base.fixture.budget.reconcile(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.base.request,
        observation(),
    );
    defer recovered.transaction.deinit(allocator);
    try std.testing.expectEqual(.aborted, recovered.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), recovered.accounting_error);
    try fixture.expectSettled(false);
}

test "reserved mixed metadata admission and class identity reject before publication" {
    const allocator = std.testing.allocator;
    var fixture = try MixedCommitFixture.init();
    defer fixture.deinit();
    try std.testing.expectError(
        error.ReservationExtensionRequired,
        fixture.commitClasses(std.testing.io, .metadata, &.{}),
    );
    const unknown = [_]TargetClassification{.{ .path = "/unselected", .class = .metadata }};
    try std.testing.expectError(
        error.ReservationIdentityMismatch,
        fixture.commitClasses(std.testing.io, .payload, &unknown),
    );
    const duplicate = [_]TargetClassification{
        .{ .path = fixture.manifest, .class = .metadata },
        .{ .path = fixture.manifest, .class = .payload },
    };
    try std.testing.expectError(
        error.ReservationIdentityMismatch,
        fixture.commitClasses(std.testing.io, .payload, &duplicate),
    );
    var snapshot = try fixture.base.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.parsed.value.reservations[0].binding == null);
    const before = try filesystem.readRegularFileNoSymlink(
        .init(std.testing.io, std.Io.Dir.cwd()),
        allocator,
        fixture.manifest,
        1024,
    );
    defer allocator.free(before);
    try std.testing.expectEqualStrings(MixedCommitFixture.old_manifest, before);
}

test "reserved transaction charge bounds reject overflow and impossible class totals" {
    try std.testing.expectError(
        error.ReservationOverflow,
        Budget.transactionCharge(std.math.maxInt(u64), 0),
    );
    try std.testing.expectError(error.InvalidReservationCharge, Budget.transactionCharge(1, 2));
    const mixed = try Budget.transactionCharge(100, 30);
    const payload = try Budget.transactionCharge(100, 0);
    try std.testing.expectEqual(payload.logical_total, mixed.logical_total);
    try std.testing.expectEqual(payload.staging, mixed.staging);
    try std.testing.expectEqual(payload.metadata + 30, mixed.metadata);
    try mixed.validate();
}

test "reserved metadata default accounts every written target without overrides" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    fixture.request.charge = try Budget.transactionCharge(
        CommitFixture.text.len,
        CommitFixture.text.len,
    );
    fixture.reservation = try fixture.fixture.budget.extend(
        allocator,
        fixture.request,
        observation(),
    );
    const result = try fixture.fixture.budget.commitReserved(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.transactions_dir,
        &.{.{
            .path = fixture.target,
            .text = CommitFixture.text,
            .content_mode = .raw,
            .expectation = .{ .expected_exists = false },
            .max_bytes = 1024,
        }},
        .{
            .request = fixture.request,
            .reservation = fixture.reservation,
            .free_space = observation(),
            .target_class = .metadata,
            .transaction = .{ .owner = accountingOwner(fixture.request) },
        },
    );
    defer result.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, result.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), result.accounting_error);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.used.logical_total > CommitFixture.text.len);
    try std.testing.expectEqual(snapshot.used.logical_total, snapshot.used.metadata);
}

fn abortCommitFixture(fixture: *CommitFixture) !void {
    const allocator = std.testing.allocator;
    StoreIoProbe.mode = .fail_stage;
    var table = StoreIoProbe.vtable();
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    const failed = try fixture.commit(injected);
    defer failed.transaction.deinit(allocator);
    try std.testing.expectEqual(.recovery_required, failed.semantic);
    const recovered = try fixture.fixture.budget.reconcile(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.request,
        observation(),
    );
    defer recovered.transaction.deinit(allocator);
    try std.testing.expectEqual(.aborted, recovered.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), recovered.accounting_error);
}

fn restartFixture(fixture: *CommitFixture, fs: Fs) !void {
    fixture.reservation = try fixture.fixture.budget.restartAborted(
        std.testing.allocator,
        fs,
        fixture.request,
        observation(),
    );
    try std.testing.expectEqual(.reserved, fixture.reservation.status);
}

fn expectOneTerminal(fixture: *CommitFixture) !u64 {
    const allocator = std.testing.allocator;
    const terminal = (try fixture.fixture.budget.readTerminal(allocator, fixture.request)).?;
    defer terminal.deinit();
    var dir = try fixture.fixture.budget.root.openChild(Budget.terminal_leaf, .read_only);
    defer dir.deinit();
    var iterable = try dir.directory.openDir(std.testing.io, ".", .{ .iterate = true });
    defer iterable.close(std.testing.io);
    var iterator = iterable.iterate();
    const name = terminalName(fixture.request);
    const advisory = try filesystem.casAdvisoryPathAlloc(allocator, &name);
    defer allocator.free(advisory);
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        count += 1;
        try std.testing.expect(std.mem.eql(u8, entry.name, &name) or
            std.mem.eql(u8, entry.name, advisory));
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    return terminal.value.native_metadata_bytes + terminal.value.terminal_bytes;
}

fn expectNativeJournalCount(fixture: *CommitFixture, count: usize) !void {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, fixture.transactions_dir, .{
        .iterate = true,
    });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var actual: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind != .directory) continue;
        actual += 1;
        var child = try dir.openDir(std.testing.io, entry.name, .{ .iterate = true });
        defer child.close(std.testing.io);
        var files = child.iterate();
        while (try files.next(std.testing.io)) |file| {
            try std.testing.expect(!std.mem.startsWith(
                u8,
                file.name,
                codec.transaction_stage_prefix,
            ));
        }
    }
    try std.testing.expectEqual(count, actual);
}

test "aborted reservation restarts one hundred times with bounded journals and then commits" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    for (0..100) |_| {
        try abortCommitFixture(&fixture);
        try expectNativeJournalCount(&fixture, 1);
        const retained = try expectOneTerminal(&fixture);
        var snapshot = try fixture.fixture.budget.inspect(allocator);
        defer snapshot.deinit();
        try std.testing.expectEqual(retained, snapshot.used.metadata);
        try std.testing.expectEqual(retained, snapshot.used.logical_total);
        try std.testing.expectEqual(@as(u64, 0), snapshot.reserved.logical_total);
        try restartFixture(&fixture, .init(std.testing.io, std.Io.Dir.cwd()));
        try expectNativeJournalCount(&fixture, 0);
    }
    const committed = try fixture.commit(std.testing.io);
    defer committed.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, committed.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), committed.accounting_error);
    const retained = try expectOneTerminal(&fixture);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(retained + CommitFixture.text.len, snapshot.used.logical_total);
    try std.testing.expectEqual(retained, snapshot.used.metadata);
    try expectNativeJournalCount(&fixture, 1);
    const terminal = try fixture.fixture.budget.restartAborted(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.request,
        observation(),
    );
    try std.testing.expectEqual(.committed, terminal.status);
    const again = try fixture.commit(std.testing.io);
    defer again.transaction.deinit(allocator);
    try std.testing.expect(again.reused);
    try std.testing.expectEqualStrings(
        committed.transaction.transaction_id,
        again.transaction.transaction_id,
    );
}

fn publishOtherObject(fixture: *CommitFixture) !void {
    const allocator = std.testing.allocator;
    var request = fixture.request;
    request.operation_id = "other-object-publisher";
    const reserved = try fixture.fixture.budget.reserve(allocator, request, observation());
    const result = try fixture.fixture.budget.commitReserved(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.transactions_dir,
        &.{.{
            .path = fixture.target,
            .text = CommitFixture.text,
            .content_mode = .raw,
            .expectation = .{ .expected_exists = false },
            .max_bytes = 1024,
        }},
        .{
            .request = request,
            .reservation = reserved,
            .free_space = observation(),
            .transaction = .{ .owner = accountingOwner(request) },
        },
    );
    defer result.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, result.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), result.accounting_error);
}

test "aborted reservation can reuse identical object published by another operation" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    try abortCommitFixture(&fixture);
    try publishOtherObject(&fixture);
    try restartFixture(&fixture, .init(std.testing.io, std.Io.Dir.cwd()));
    const digest = try codec.digestBytesAlloc(allocator, CommitFixture.text);
    defer allocator.free(digest);
    const mutations = [_]codec.TransactionMutation{.{
        .path = fixture.target,
        .text = "",
        .content_mode = .raw,
        .expectation = .{ .expected_exists = true, .expected_digest = digest },
        .max_bytes = CommitFixture.text.len,
        .expected_digest_after = digest,
        .action = .check_only,
    }};
    const result = try fixture.fixture.budget.commitReserved(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.transactions_dir,
        &mutations,
        .{
            .request = fixture.request,
            .reservation = fixture.reservation,
            .free_space = observation(),
            .transaction = .{ .owner = accountingOwner(fixture.request) },
        },
    );
    defer result.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, result.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), result.accounting_error);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(
        CommitFixture.text.len,
        snapshot.used.logical_total - snapshot.used.metadata,
    );
    try std.testing.expectEqual(@as(u64, 0), snapshot.reserved.logical_total);
    const bytes = try filesystem.readRegularFileNoSymlink(
        .init(std.testing.io, std.Io.Dir.cwd()),
        allocator,
        fixture.target,
        1024,
    );
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(CommitFixture.text, bytes);
}

test "aborted restart rejects changed final content and classes but preserves valid retry" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    try abortCommitFixture(&fixture);
    const stale = fixture.reservation;
    try restartFixture(&fixture, .init(std.testing.io, std.Io.Dir.cwd()));
    const current = fixture.reservation;
    fixture.reservation = stale;
    try std.testing.expectError(error.ReservationChanged, fixture.commit(std.testing.io));
    fixture.reservation = current;
    for ([_]bool{ false, true }) |change_class| {
        try std.testing.expectError(
            error.ReservationIdentityMismatch,
            fixture.fixture.budget.commitReserved(
                allocator,
                .init(std.testing.io, std.Io.Dir.cwd()),
                fixture.transactions_dir,
                &.{.{
                    .path = fixture.target,
                    .text = if (change_class) CommitFixture.text else "different content",
                    .content_mode = .raw,
                    .expectation = .{ .expected_exists = false },
                    .max_bytes = 1024,
                }},
                .{
                    .request = fixture.request,
                    .reservation = fixture.reservation,
                    .target_class = if (change_class) .metadata else .payload,
                    .free_space = observation(),
                    .transaction = .{ .owner = accountingOwner(fixture.request) },
                },
            ),
        );
    }
    const result = try fixture.commit(std.testing.io);
    defer result.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, result.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), result.accounting_error);
}

const RestartIoProbe = struct {
    var cut: enum { record, pin, directory, sync } = .record;
    var removed_record = false;

    fn deleteFile(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        name: []const u8,
    ) std.Io.Dir.DeleteFileError!void {
        try std.testing.io.vtable.dirDeleteFile(userdata, dir, name);
        if (std.mem.eql(u8, name, "transaction.json")) {
            removed_record = true;
            if (cut == .record) return error.AccessDenied;
        }
        if (std.mem.eql(u8, name, transactions.reservation_pin_leaf) and cut == .pin) {
            return error.AccessDenied;
        }
    }

    fn deleteDir(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        name: []const u8,
    ) std.Io.Dir.DeleteDirError!void {
        try std.testing.io.vtable.dirDeleteDir(userdata, dir, name);
        if (cut == .directory) return error.AccessDenied;
    }

    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        if (cut == .sync and removed_record) return error.InputOutput;
        return std.testing.io.vtable.fileSync(userdata, file);
    }

    fn vtable() std.Io.VTable {
        removed_record = false;
        var table = std.testing.io.vtable.*;
        table.dirDeleteFile = deleteFile;
        table.dirDeleteDir = deleteDir;
        table.fileSync = sync;
        return table;
    }
};

test "aborted restart resumes every native retirement prefix without double credit" {
    const allocator = std.testing.allocator;
    for ([_]@TypeOf(RestartIoProbe.cut){ .record, .pin, .directory, .sync }) |cut| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        try abortCommitFixture(&fixture);
        var before = try fixture.fixture.budget.inspect(allocator);
        defer before.deinit();
        RestartIoProbe.cut = cut;
        var table = RestartIoProbe.vtable();
        const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
        const result = fixture.fixture.budget.restartAborted(
            allocator,
            .init(injected, std.Io.Dir.cwd()),
            fixture.request,
            observation(),
        );
        if (cut == .sync) {
            try std.testing.expectError(error.InputOutput, result);
        } else try std.testing.expectError(error.AccessDenied, result);
        var interrupted = try fixture.fixture.budget.inspect(allocator);
        defer interrupted.deinit();
        try std.testing.expectEqual(before.used.logical_total, interrupted.used.logical_total);
        try restartFixture(&fixture, .init(std.testing.io, std.Io.Dir.cwd()));
        const result_after = try fixture.commit(std.testing.io);
        defer result_after.transaction.deinit(allocator);
        try std.testing.expectEqual(.committed, result_after.semantic);
        try std.testing.expectEqual(@as(?anyerror, null), result_after.accounting_error);
    }
}

test "aborted restart preserves journal and accounting when current quota rejects readmission" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    try abortCommitFixture(&fixture);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    var policy = snapshot.parsed.value.policy;
    policy.limits.logical_total = Budget.control_charge.logical_total + snapshot.used.logical_total;
    try fixture.fixture.budget.updatePolicy(
        allocator,
        "test-budget",
        snapshot.parsed.value.generation,
        policy,
        &.{ snapshot.parsed.value.stores[0].limits, snapshot.parsed.value.stores[1].limits },
    );
    try std.testing.expectError(
        error.ReservationCapacityExceeded,
        fixture.fixture.budget.restartAborted(
            allocator,
            .init(std.testing.io, std.Io.Dir.cwd()),
            fixture.request,
            observation(),
        ),
    );
    try expectNativeJournalCount(&fixture, 1);
    var after = try fixture.fixture.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expectEqual(snapshot.used.logical_total, after.used.logical_total);
    try std.testing.expectEqual(@as(usize, 0), after.parsed.value.reservations.len);
}

const ConcurrentRestart = struct {
    fixture: *CommitFixture,
    start: *std.atomic.Value(bool),
    outcome: ?Receipt = null,
    failure: ?anyerror = null,

    fn run(self: *ConcurrentRestart) void {
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        self.outcome = self.fixture.fixture.budget.restartAborted(
            std.heap.page_allocator,
            .init(std.testing.io, std.Io.Dir.cwd()),
            self.fixture.request,
            observation(),
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "aborted restart concurrent contenders install one reservation and credit one journal" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    try abortCommitFixture(&fixture);
    var start = std.atomic.Value(bool).init(false);
    var first: ConcurrentRestart = .{ .fixture = &fixture, .start = &start };
    var second: ConcurrentRestart = .{ .fixture = &fixture, .start = &start };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentRestart.run, .{&first});
    const second_thread = std.Thread.spawn(.{}, ConcurrentRestart.run, .{&second}) catch |err| {
        start.store(true, .release);
        first_thread.join();
        return err;
    };
    start.store(true, .release);
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.outcome != null or second.outcome != null);
    if (first.failure) |err| try std.testing.expectEqual(error.LockBusy, err);
    if (second.failure) |err| try std.testing.expectEqual(error.LockBusy, err);
    if (first.outcome != null and second.outcome != null) {
        try std.testing.expectEqual(first.outcome.?.generation, second.outcome.?.generation);
    }
    fixture.reservation = first.outcome orelse second.outcome.?;
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), snapshot.parsed.value.reservations.len);
    try std.testing.expectEqual(
        fixture.request.charge.logical_total,
        snapshot.reserved.logical_total,
    );
    try expectNativeJournalCount(&fixture, 0);
    const result = try fixture.commit(std.testing.io);
    defer result.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, result.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), result.accounting_error);
}

test "aborted restart retains unknown journal entries and rejects wrong roots and pins" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "foreign", "wrong-pin", "wrong-root" }) |case| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        try abortCommitFixture(&fixture);
        const terminal = (try fixture.fixture.budget.readTerminal(allocator, fixture.request)).?;
        defer terminal.deinit();
        const fs: Fs = .init(std.testing.io, std.Io.Dir.cwd());
        if (std.mem.eql(u8, case, "wrong-root")) {
            try fixture.fixture.tmp.dir.rename(
                "store",
                fixture.fixture.tmp.dir,
                "prior",
                std.testing.io,
            );
            try fixture.fixture.tmp.dir.createDir(std.testing.io, "store", .default_dir);
        } else {
            const leaf = if (std.mem.eql(u8, case, "wrong-pin"))
                transactions.reservation_pin_leaf
            else
                case;
            const path = try std.fs.path.join(
                allocator,
                &.{ terminal.value.binding.transaction_dir, leaf },
            );
            defer allocator.free(path);
            try filesystem.writeTextAtomic(fs, allocator, path, "unknown");
        }
        if (fixture.fixture.budget.restartAborted(
            allocator,
            fs,
            fixture.request,
            observation(),
        )) |_| return error.TestExpectedError else |_| {}
        var snapshot = try fixture.fixture.budget.inspect(allocator);
        defer snapshot.deinit();
        try std.testing.expectEqual(@as(usize, 0), snapshot.parsed.value.reservations.len);
        try std.testing.expectEqual(
            terminal.value.added.logical_total,
            snapshot.used.logical_total,
        );
    }
}

test "aborted restart state publication lost reply reuses generation and terminal replacement" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    try abortCommitFixture(&fixture);
    var table = std.testing.io.vtable.*;
    table.dirRename = struct {
        fn rename(
            userdata: ?*anyopaque,
            old_dir: std.Io.Dir,
            old_name: []const u8,
            new_dir: std.Io.Dir,
            new_name: []const u8,
        ) std.Io.Dir.RenameError!void {
            try std.testing.io.vtable.dirRename(userdata, old_dir, old_name, new_dir, new_name);
            if (std.mem.eql(u8, new_name, Budget.state_leaf)) return error.HardwareFailure;
        }
    }.rename;
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    fixture.fixture.budget.root.io = injected;
    const interrupted = fixture.fixture.budget.restartAborted(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.request,
        observation(),
    );
    fixture.fixture.budget.root.io = std.testing.io;
    try std.testing.expectError(error.ReservationPublicationUnknown, interrupted);
    var after = try fixture.fixture.budget.inspect(allocator);
    defer after.deinit();
    const generation = after.parsed.value.generation;
    try restartFixture(&fixture, .init(std.testing.io, std.Io.Dir.cwd()));
    try std.testing.expectEqual(generation, fixture.reservation.generation);
    const reused = try fixture.fixture.budget.reserve(allocator, fixture.request, observation());
    try std.testing.expectEqual(generation, reused.generation);
    const result = try fixture.commit(std.testing.io);
    defer result.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, result.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), result.accounting_error);
    _ = try expectOneTerminal(&fixture);
}

test "aborted restart terminal replacement lost reply remains committed and settles once" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    try abortCommitFixture(&fixture);
    try restartFixture(&fixture, .init(std.testing.io, std.Io.Dir.cwd()));
    var table = std.testing.io.vtable.*;
    table.dirRename = struct {
        fn rename(
            userdata: ?*anyopaque,
            old_dir: std.Io.Dir,
            old_name: []const u8,
            new_dir: std.Io.Dir,
            new_name: []const u8,
        ) std.Io.Dir.RenameError!void {
            try std.testing.io.vtable.dirRename(userdata, old_dir, old_name, new_dir, new_name);
            if (std.mem.startsWith(u8, old_name, codec.transaction_stage_prefix) and
                std.mem.endsWith(u8, new_name, ".json") and
                !std.mem.eql(u8, new_name, Budget.state_leaf)) return error.HardwareFailure;
        }
    }.rename;
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    fixture.fixture.budget.root.io = injected;
    const result = fixture.commit(std.testing.io) catch |err| {
        fixture.fixture.budget.root.io = std.testing.io;
        return err;
    };
    fixture.fixture.budget.root.io = std.testing.io;
    defer result.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, result.semantic);
    try std.testing.expect(result.accounting_error != null);
    const retry = try fixture.commit(std.testing.io);
    defer retry.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, retry.semantic);
    try std.testing.expect(retry.reused);
    const retained = try expectOneTerminal(&fixture);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(retained + CommitFixture.text.len, snapshot.used.logical_total);
}

fn ordinarySuccessor(fixture: *CommitFixture, text: []const u8) !void {
    const allocator = std.testing.allocator;
    const fs: Fs = .init(std.testing.io, std.Io.Dir.cwd());
    try transactions.recoverAndCompactTransactions(fs, allocator, fixture.transactions_dir);
    const result = try transactions.commitTextTransaction(
        fs,
        allocator,
        fixture.transactions_dir,
        &.{.{
            .path = fixture.target,
            .text = text,
            .content_mode = .raw,
            .expectation = .{ .expected_exists = true },
            .max_bytes = 1024,
        }},
        .{ .owner = accountingOwner(fixture.request) },
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(.committed, result.state);
}

test "committed reserved journals admit ordinary successors and retain exact budget evidence" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const fs: Fs = .init(std.testing.io, std.Io.Dir.cwd());
    const committed = try fixture.commit(std.testing.io);
    defer committed.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, committed.semantic);
    const record_before = try filesystem.readRegularFileNoSymlink(
        fs,
        allocator,
        committed.transaction.record_path,
        codec.transaction_record_max_bytes,
    );
    defer allocator.free(record_before);
    const marker_before = try filesystem.readRegularFileNoSymlink(
        fs,
        allocator,
        committed.transaction.commit_marker_path,
        2048,
    );
    defer allocator.free(marker_before);
    try ordinarySuccessor(&fixture, "first ordinary successor");
    try ordinarySuccessor(&fixture, "second ordinary successor");
    try transactions.recoverAndCompactTransactions(fs, allocator, fixture.transactions_dir);
    const observed = try transactions.recoverTransaction(
        fs,
        allocator,
        committed.transaction.transaction_dir,
    );
    defer observed.deinit(allocator);
    try std.testing.expectEqual(codec.RecoveryDecision.already_committed, observed.decision);
    try expectNativeJournalCount(&fixture, 1);
    const record_after = try filesystem.readRegularFileNoSymlink(
        fs,
        allocator,
        committed.transaction.record_path,
        codec.transaction_record_max_bytes,
    );
    defer allocator.free(record_after);
    const marker_after = try filesystem.readRegularFileNoSymlink(
        fs,
        allocator,
        committed.transaction.commit_marker_path,
        2048,
    );
    defer allocator.free(marker_after);
    try std.testing.expectEqualStrings(record_before, record_after);
    try std.testing.expectEqualStrings(marker_before, marker_after);
    const terminal = (try fixture.fixture.budget.readTerminal(allocator, fixture.request)).?;
    defer terminal.deinit();
    const expected_pin = try renderPin(allocator, fixture.request, terminal.value.binding);
    defer allocator.free(expected_pin);
    const pin_path = try std.fs.path.join(allocator, &.{
        committed.transaction.transaction_dir, transactions.reservation_pin_leaf,
    });
    defer allocator.free(pin_path);
    const pin = try filesystem.readRegularFileNoSymlink(fs, allocator, pin_path, 4096);
    defer allocator.free(pin);
    try std.testing.expectEqualStrings(expected_pin, pin);
}

test "ordinary recovery rejects damaged reserved commit evidence without compaction" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        transactions.reservation_pin_leaf,
        "commit.json",
        "transaction.json",
        "missing-pin",
        "missing-marker",
    };
    for (cases) |case| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        const fs: Fs = .init(std.testing.io, std.Io.Dir.cwd());
        const committed = try fixture.commit(std.testing.io);
        defer committed.transaction.deinit(allocator);
        const leaf = if (std.mem.eql(u8, case, "missing-pin"))
            transactions.reservation_pin_leaf
        else if (std.mem.eql(u8, case, "missing-marker")) "commit.json" else case;
        const path = try std.fs.path.join(
            allocator,
            &.{ committed.transaction.transaction_dir, leaf },
        );
        defer allocator.free(path);
        if (std.mem.startsWith(u8, case, "missing-")) {
            try std.Io.Dir.deleteFileAbsolute(std.testing.io, path);
        } else try filesystem.writeTextAtomic(fs, allocator, path, "{}");
        if (transactions.recoverAndCompactTransactions(
            fs,
            allocator,
            fixture.transactions_dir,
        )) |_| {
            return error.TestExpectedError;
        } else |_| {}
        var retained = try std.Io.Dir.openDirAbsolute(
            std.testing.io,
            committed.transaction.transaction_dir,
            .{},
        );
        retained.close(std.testing.io);
        var snapshot = try fixture.fixture.budget.inspect(allocator);
        defer snapshot.deinit();
        try std.testing.expect(snapshot.used.logical_total > CommitFixture.text.len);
    }
}

test "ordinary recovery leaves prepared reserved publication fenced by budget authority" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    StoreIoProbe.mode = .fail_publication;
    var table = StoreIoProbe.vtable();
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    const pending = try fixture.commit(injected);
    defer pending.transaction.deinit(allocator);
    try std.testing.expectEqual(.recovery_required, pending.semantic);
    try std.testing.expectError(
        error.TransactionReservationRequired,
        transactions.recoverAndCompactTransactions(
            .init(std.testing.io, std.Io.Dir.cwd()),
            allocator,
            fixture.transactions_dir,
        ),
    );
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(
        fixture.request.charge.logical_total,
        snapshot.reserved.logical_total,
    );
}

test "sealed committed reservation accounts original publication after ordinary target evolution" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    var table = std.testing.io.vtable.*;
    table.dirCreateFile = struct {
        fn create(
            userdata: ?*anyopaque,
            dir: std.Io.Dir,
            name: []const u8,
            options: std.Io.Dir.CreateFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            if (std.mem.eql(u8, name, "transaction.json")) return error.AccessDenied;
            return std.testing.io.vtable.dirCreateFile(userdata, dir, name, options);
        }
    }.create;
    const injected: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    fixture.fixture.budget.root.io = injected;
    const committed = fixture.commit(std.testing.io) catch |err| {
        fixture.fixture.budget.root.io = std.testing.io;
        return err;
    };
    fixture.fixture.budget.root.io = std.testing.io;
    defer committed.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, committed.semantic);
    try std.testing.expectEqual(error.AccessDenied, committed.accounting_error.?);
    var unsettled = try fixture.fixture.budget.inspect(allocator);
    defer unsettled.deinit();
    try std.testing.expectEqual(@as(usize, 1), unsettled.parsed.value.reservations.len);
    try std.testing.expectEqual(@as(u64, 0), unsettled.used.logical_total);
    const successor = "later ordinary publication has a different byte length";
    try ordinarySuccessor(&fixture, successor);
    const recovered = try fixture.fixture.budget.reconcile(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.request,
        observation(),
    );
    defer recovered.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, recovered.semantic);
    try std.testing.expectEqual(@as(?anyerror, null), recovered.accounting_error);
    const retained = try expectOneTerminal(&fixture);
    var settled = try fixture.fixture.budget.inspect(allocator);
    defer settled.deinit();
    try std.testing.expectEqual(retained + CommitFixture.text.len, settled.used.logical_total);
    try std.testing.expectEqual(@as(u64, 0), settled.reserved.logical_total);
    const actual = try filesystem.readRegularFileNoSymlink(
        .init(std.testing.io, std.Io.Dir.cwd()),
        allocator,
        fixture.target,
        1024,
    );
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(successor, actual);
    const retry = try fixture.fixture.budget.reconcile(
        allocator,
        .init(std.testing.io, std.Io.Dir.cwd()),
        fixture.request,
        observation(),
    );
    defer retry.transaction.deinit(allocator);
    try std.testing.expect(retry.reused);
}

test "ordinary recovery rejects reserved commit seal copied to a replacement root" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const fs: Fs = .init(std.testing.io, std.Io.Dir.cwd());
    const committed = try fixture.commit(std.testing.io);
    defer committed.transaction.deinit(allocator);
    const leaves = [_][]const u8{
        "transaction.json", "commit.json", transactions.reservation_pin_leaf,
    };
    var contents: [3][]u8 = undefined;
    var count: usize = 0;
    defer for (contents[0..count]) |bytes| allocator.free(bytes);
    for (leaves, 0..) |leaf, index| {
        const path = try std.fs.path.join(
            allocator,
            &.{ committed.transaction.transaction_dir, leaf },
        );
        defer allocator.free(path);
        contents[index] = try filesystem.readRegularFileNoSymlink(
            fs,
            allocator,
            path,
            codec.transaction_record_max_bytes,
        );
        count += 1;
    }
    try fixture.fixture.tmp.dir.rename(
        "store",
        fixture.fixture.tmp.dir,
        "original",
        std.testing.io,
    );
    try filesystem.ensureDirectoryPathNoSymlinks(fs, committed.transaction.transaction_dir);
    for (leaves, contents) |leaf, bytes| {
        const path = try std.fs.path.join(
            allocator,
            &.{ committed.transaction.transaction_dir, leaf },
        );
        defer allocator.free(path);
        try filesystem.writeTextCreateNew(fs, allocator, path, bytes, .{});
    }
    try std.testing.expectError(
        error.TransactionReservationMismatch,
        transactions.recoverAndCompactTransactions(fs, allocator, fixture.transactions_dir),
    );
    try expectNativeJournalCount(&fixture, 1);
}

test "ordinary legacy marker spelling remains eligible for ordinary recovery and compaction" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const fs: Fs = .init(std.testing.io, std.Io.Dir.cwd());
    const ordinary = try transactions.commitTextTransaction(
        fs,
        allocator,
        fixture.transactions_dir,
        &.{.{
            .path = fixture.target,
            .text = "ordinary data",
            .content_mode = .raw,
            .expectation = .{ .expected_exists = false },
            .max_bytes = 1024,
        }},
        .{ .owner = accountingOwner(fixture.request) },
    );
    defer ordinary.deinit(allocator);
    try filesystem.writeTextAtomic(
        fs,
        allocator,
        ordinary.commit_marker_path,
        "{ \"state\": \"committed\", \"commit_marker\": \"DTX-v1\" }\n",
    );
    try transactions.recoverAndCompactTransactions(fs, allocator, fixture.transactions_dir);
    try expectNativeJournalCount(&fixture, 0);
}

test "budget association rejects invalid reservation before source coordination" {
    const allocator = std.testing.allocator;
    for (0..3) |case| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        var before = try fixture.fixture.budget.inspect(allocator);
        defer before.deinit();
        switch (case) {
            0 => fixture.request.budget_id = "foreign-budget",
            1 => fixture.request.operation_id = "missing-operation",
            2 => fixture.reservation.generation += 1,
            else => unreachable,
        }
        const expected = [_]anyerror{
            error.ReservationIdentityMismatch, error.ReservationNotFound, error.ReservationChanged,
        };
        try std.testing.expectError(expected[case], fixture.commit(std.testing.io));
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        try std.testing.expect(!filesystem.fileExists(fs, fixture.transactions_dir));
        var after = try fixture.fixture.budget.inspect(allocator);
        defer after.deinit();
        try std.testing.expectEqual(before.parsed.value.generation, after.parsed.value.generation);
        try std.testing.expect(after.parsed.value.stores[0].association == null);
        try std.testing.expect(after.parsed.value.reservations[0].binding == null);
    }
}

test "root reader prevents first association and remains independent of budget lock" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var mutated = false;
    try transactions.ensureTransactionDependencyCoordination(
        fs,
        allocator,
        fixture.transactions_dir,
        &mutated,
    );
    {
        var reader = try transactions.snapshotTransactionDependencies(
            fs,
            allocator,
            fixture.transactions_dir,
            &.{},
            .{},
        );
        defer reader.deinit(allocator);
        try std.testing.expectError(error.LockBusy, fixture.commit(std.testing.io));
        var budget = try fixture.fixture.budget.inspect(allocator);
        defer budget.deinit();
        try std.testing.expect(budget.parsed.value.stores[0].association == null);
        try std.testing.expect(budget.parsed.value.reservations[0].binding == null);
        var request = requestFor("while-root-read-held", 0);
        request.store_id = "b";
        _ = try fixture.fixture.budget.reserve(allocator, request, observation());
    }
    const committed = try fixture.commit(std.testing.io);
    defer committed.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, committed.semantic);
    try std.testing.expectError(
        error.TransactionDependencyBudgetContextRequired,
        transactions.snapshotTransactionDependencies(
            fs,
            allocator,
            fixture.transactions_dir,
            &.{},
            .{},
        ),
    );
}

test "budget association preserves foreign stage and association before ownership" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        transactions.transaction_budget_association_leaf, ".reservation-budget.stage",
    }) |leaf| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        try filesystem.ensureDirectoryPathNoSymlinks(fs, fixture.transactions_dir);
        const path = try std.fs.path.join(allocator, &.{ fixture.transactions_dir, leaf });
        defer allocator.free(path);
        try filesystem.writeTextCreateNew(fs, allocator, path, "foreign bytes", .{});
        try std.testing.expectError(
            error.TransactionDependencyBudgetMismatch,
            fixture.commit(std.testing.io),
        );
        const bytes = try filesystem.readRegularFileNoSymlink(fs, allocator, path, 64);
        defer allocator.free(bytes);
        try std.testing.expectEqualStrings("foreign bytes", bytes);
        var budget = try fixture.fixture.budget.inspect(allocator);
        defer budget.deinit();
        try std.testing.expect(budget.parsed.value.stores[0].association == null);
        try std.testing.expect(budget.parsed.value.reservations[0].binding == null);
    }
}

const AssociationIoProbe = struct {
    var stage: ?std.Io.File = null;
    var mode: enum { partial_stage, lost_rename, unsynced_directory } = .partial_stage;
    var renamed = false;

    fn create(
        context: ?*anyopaque,
        directory: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.CreateFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        const file = try std.testing.io.vtable.dirCreateFile(context, directory, path, options);
        if (std.mem.eql(u8, path, ".reservation-budget.stage")) stage = file;
        return file;
    }

    fn sync(context: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        if (stage != null and file.handle == stage.?.handle) {
            stage = null;
            if (mode == .partial_stage) {
                file.setLength(std.testing.io, 7) catch return error.InputOutput;
                return error.InputOutput;
            }
        }
        if (renamed and mode == .unsynced_directory) return error.InputOutput;
        return std.testing.io.vtable.fileSync(context, file);
    }

    fn rename(
        context: ?*anyopaque,
        old_dir: std.Io.Dir,
        old: []const u8,
        new_dir: std.Io.Dir,
        new: []const u8,
    ) std.Io.Dir.RenamePreserveError!void {
        try std.testing.io.vtable.dirRenamePreserve(context, old_dir, old, new_dir, new);
        if (std.mem.eql(u8, new, transactions.transaction_budget_association_leaf)) {
            renamed = true;
            if (mode == .lost_rename) return error.HardwareFailure;
        }
    }
};

test "association interruptions retain unbound charge and reuse one deterministic stage" {
    const allocator = std.testing.allocator;
    for (std.enums.values(@TypeOf(AssociationIoProbe.mode))) |mode| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        AssociationIoProbe.mode = mode;
        AssociationIoProbe.renamed = false;
        AssociationIoProbe.stage = null;
        var table = std.testing.io.vtable.*;
        table.dirCreateFile = AssociationIoProbe.create;
        table.fileSync = AssociationIoProbe.sync;
        table.dirRenamePreserve = AssociationIoProbe.rename;
        const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
        const expected = if (mode == .lost_rename) error.HardwareFailure else error.InputOutput;
        try std.testing.expectError(expected, fixture.commit(io));
        var budget = try fixture.fixture.budget.inspect(allocator);
        defer budget.deinit();
        try std.testing.expect(budget.parsed.value.stores[0].association != null);
        try std.testing.expect(budget.parsed.value.reservations[0].binding == null);
        try std.testing.expectEqual(@as(u64, 0), budget.used.logical_total);
        try std.testing.expectEqual(
            fixture.request.charge.logical_total,
            budget.reserved.logical_total,
        );
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        try std.testing.expect(!filesystem.fileExists(fs, fixture.target));
        try std.testing.expectError(
            error.TransactionDependencyBudgetContextRequired,
            transactions.snapshotTransactionDependencies(
                fs,
                allocator,
                fixture.transactions_dir,
                &.{},
                .{},
            ),
        );
        const committed = try fixture.commit(std.testing.io);
        defer committed.transaction.deinit(allocator);
        try std.testing.expectEqual(.committed, committed.semantic);
        const stage_path = try std.fs.path.join(
            allocator,
            &.{ fixture.transactions_dir, ".reservation-budget.stage" },
        );
        defer allocator.free(stage_path);
        try std.testing.expect(!filesystem.fileExists(fs, stage_path));
        var snapshot = try inspectFixtureDependencies(&fixture, &.{fixture.target}, .{});
        defer snapshot.deinit(allocator);
        try std.testing.expectEqual(.budget_association, snapshot.evidence[1].kind);
    }
}

test "one store association rejects extra transaction roots without creating them" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    try fixture.associate(std.testing.io);
    const original = fixture.transactions_dir;
    const alternate = try allocator.print("{s}-other", .{original});
    defer allocator.free(alternate);
    fixture.transactions_dir = alternate;
    defer fixture.transactions_dir = original;
    try std.testing.expectError(
        error.TransactionReservationMismatch,
        fixture.commit(std.testing.io),
    );
    try std.testing.expect(!filesystem.fileExists(
        .init(std.testing.io, std.Io.Dir.cwd()),
        alternate,
    ));
}

test "association capacity is reserved within the store quota before source publication" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    var limit = try fixture.request.charge.add(Budget.association_charge);
    limit.logical_total -= 1;
    try fixture.fixture.budget.updatePolicy(
        allocator,
        fixture.request.budget_id,
        snapshot.parsed.value.generation,
        snapshot.parsed.value.policy,
        &.{ limit, snapshot.parsed.value.stores[1].limits },
    );
    fixture.reservation = try fixture.fixture.budget.reserve(
        allocator,
        fixture.request,
        observation(),
    );
    try std.testing.expectError(
        error.ReservationStoreCapacityExceeded,
        fixture.commit(std.testing.io),
    );
    var after = try fixture.fixture.budget.inspect(allocator);
    defer after.deinit();
    try std.testing.expect(after.parsed.value.stores[0].association == null);
    try std.testing.expectEqual(@as(u64, 0), after.used.logical_total);
}

test "known committed replay preserves outcome when association integrity is unavailable" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |remove| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        const committed = try fixture.commit(std.testing.io);
        defer committed.transaction.deinit(allocator);
        var before = try fixture.fixture.budget.inspect(allocator);
        defer before.deinit();
        const path = try std.fs.path.join(
            allocator,
            &.{ fixture.transactions_dir, transactions.transaction_budget_association_leaf },
        );
        defer allocator.free(path);
        try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        if (!remove) try filesystem.writeTextCreateNew(fs, allocator, path, "damaged", .{});
        const retry = try fixture.commit(std.testing.io);
        defer retry.transaction.deinit(allocator);
        try std.testing.expectEqual(.committed, retry.semantic);
        try std.testing.expect(retry.reused);
        try std.testing.expectEqual(error.TransactionDependencyBudgetMismatch, retry.failure.?);
        try std.testing.expectEqualStrings(
            committed.transaction.transaction_id,
            retry.transaction.transaction_id,
        );
        var after = try fixture.fixture.budget.inspect(allocator);
        defer after.deinit();
        try std.testing.expectEqual(before.parsed.value.generation, after.parsed.value.generation);
        if (remove) {
            try std.testing.expect(!filesystem.fileExists(fs, path));
        } else {
            const bytes = try filesystem.readRegularFileNoSymlink(fs, allocator, path, 64);
            defer allocator.free(bytes);
            try std.testing.expectEqualStrings("damaged", bytes);
        }
    }
}

test "source association claim lost reply remains metadata only and is resumed by its owner" {
    const allocator = std.testing.allocator;
    var fixture = try CommitFixture.init();
    defer fixture.deinit();
    var table = std.testing.io.vtable.*;
    table.dirRename = struct {
        fn rename(
            context: ?*anyopaque,
            old_dir: std.Io.Dir,
            old: []const u8,
            new_dir: std.Io.Dir,
            new: []const u8,
        ) std.Io.Dir.RenameError!void {
            try std.testing.io.vtable.dirRename(context, old_dir, old, new_dir, new);
            if (std.mem.eql(u8, new, Budget.state_leaf)) return error.HardwareFailure;
        }
    }.rename;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
    fixture.fixture.budget.root.io = io;
    const failed = fixture.commit(std.testing.io);
    fixture.fixture.budget.root.io = std.testing.io;
    try std.testing.expectError(error.ReservationPublicationUnknown, failed);
    var snapshot = try fixture.fixture.budget.inspect(allocator);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.parsed.value.stores[0].association != null);
    try std.testing.expect(snapshot.parsed.value.reservations[0].binding == null);
    try std.testing.expectEqual(@as(u64, 0), snapshot.used.logical_total);
    try std.testing.expectError(
        error.TransactionDependencyBudgetMismatch,
        inspectFixtureDependencies(&fixture, &.{}, .{}),
    );
    const retry = try fixture.commit(std.testing.io);
    defer retry.transaction.deinit(allocator);
    try std.testing.expectEqual(.committed, retry.semantic);
}

const AssociationRootSwap = struct {
    var parent: std.Io.Dir = undefined;
    var transaction_only = false;
    var swapped = false;

    fn create(
        context: ?*anyopaque,
        directory: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.CreateFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        const file = try std.testing.io.vtable.dirCreateFile(context, directory, path, options);
        errdefer file.close(std.testing.io);
        if (swapped or !std.mem.endsWith(u8, path, "/target.cas.lock.advisory")) return file;
        swap() catch return error.AccessDenied;
        swapped = true;
        return file;
    }

    fn swap() !void {
        const io = std.testing.io;
        if (transaction_only) {
            try parent.rename("store/transactions", parent, "retired-transactions", io);
        } else {
            try parent.rename("store", parent, "retired-store", io);
            try parent.createDir(io, "store", .default_dir);
        }
        try parent.createDir(io, "store/transactions", .default_dir);
    }
};

test "reserved bind rejects source replacement after association before native intent" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |transaction_only| {
        var fixture = try CommitFixture.init();
        defer fixture.deinit();
        AssociationRootSwap.parent = fixture.fixture.tmp.dir;
        AssociationRootSwap.transaction_only = transaction_only;
        AssociationRootSwap.swapped = false;
        var table = std.testing.io.vtable.*;
        table.dirCreateFile = AssociationRootSwap.create;
        const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &table };
        try std.testing.expectError(error.TransactionReservationMismatch, fixture.commit(io));
        try std.testing.expect(AssociationRootSwap.swapped);
        var budget = try fixture.fixture.budget.inspect(allocator);
        defer budget.deinit();
        try std.testing.expect(budget.parsed.value.stores[0].association != null);
        try std.testing.expect(budget.parsed.value.reservations[0].binding == null);
        try std.testing.expectEqual(@as(u64, 0), budget.used.logical_total);
        try std.testing.expectEqual(
            fixture.request.charge.logical_total,
            budget.reserved.logical_total,
        );
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        try std.testing.expect(!filesystem.fileExists(fs, fixture.target));
    }
}
