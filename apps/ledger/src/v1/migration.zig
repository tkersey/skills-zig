const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const checkpoint = @import("checkpoint.zig");
const custody = @import("custody.zig");
const definition = @import("definition.zig");
const definition_archive = @import("definition_archive.zig");
const protocol = @import("protocol.zig");
const replay = @import("replay.zig");
const segmented_event_log = @import("segmented_event_log.zig");
const storage = @import("storage.zig");

pub const Result = struct {
    logical_ref: []u8,
    revision: []u8,
    records: usize,
    transaction_id: ?[]u8,
    already_migrated: bool,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.logical_ref);
        allocator.free(self.revision);
        if (self.transaction_id) |transaction_id| allocator.free(transaction_id);
        self.* = undefined;
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    definition_closure: *const definition_core.Closure,
    definition_entry_path: []const u8,
    storage_plan: *const storage.Plan,
    event_protocol: ?*const protocol.Plan,
    repo_root: []const u8,
    parameters: *const definition_core.parameters.Bindings,
) !Result {
    if (!std.fs.path.isAbsolute(repo_root)) {
        return error.RepositoryRootNotAbsolute;
    }
    var resolved = try storage.resolve(allocator, storage_plan, parameters);
    defer resolved.deinit(allocator);
    const event_plan = event_protocol orelse
        return error.SegmentedMigrationRequiresProtocol;
    const slot = resolved.slot(event_plan.target_slot_index);
    if (!slot.isSegmented() or slot.kind != .event_log) {
        return error.SegmentedMigrationRequiresSegmentedEventLog;
    }
    var target = try segmented_event_log.Snapshot.load(
        allocator,
        repo_root,
        slot.relative_path,
    );
    defer target.deinit(allocator);
    if (target.head_exists) return existingResult(
        allocator,
        slot.relative_path,
        &target,
    );
    return migrateLegacySlot(
        allocator,
        definition_plan,
        definition_closure,
        definition_entry_path,
        repo_root,
        slot,
        parameters,
        &target,
    );
}

fn migrateLegacySlot(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    definition_closure: *const definition_core.Closure,
    definition_entry_path: []const u8,
    repo_root: []const u8,
    slot: storage.ResolvedSlot,
    parameters: *const definition_core.parameters.Bindings,
    target: *const segmented_event_log.Snapshot,
) !Result {
    var legacy = try custody.readSlot(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
    );
    defer legacy.deinit(allocator);
    var stats = try replay.validateSlot(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
        &legacy,
        parameters,
        definition_plan.bounds.max_records,
        true,
    );
    defer stats.deinit(allocator);
    if (stats.protocol_state == null) return error.SegmentedMigrationCheckpointMissing;
    const state = &stats.protocol_state.?;
    const checkpoint_bytes = try protocol.encodeCheckpointAlloc(
        allocator,
        state,
        definition_plan.closure_digest[0..],
    );
    defer allocator.free(checkpoint_bytes);
    var head = try prepareHead(
        allocator,
        slot.relative_path,
        legacy.content,
        stats.records_validated,
        legacy.binding.bytes,
        legacy.binding.rows.len,
        checkpoint_bytes,
    );
    defer head.deinit(allocator);
    const revision = try head.revisionAlloc(allocator);
    errdefer allocator.free(revision);
    try requireRevision(revision, legacy.revision);
    releaseReadCustody(&legacy);
    const transaction_id = try commitMigration(
        allocator,
        definition_plan,
        definition_closure,
        definition_entry_path,
        repo_root,
        target,
        &legacy,
        &head,
        checkpoint_bytes,
    );
    errdefer allocator.free(transaction_id);
    return migratedResult(
        allocator,
        slot.relative_path,
        stats.records_validated,
        revision,
        transaction_id,
    );
}

fn migratedResult(
    allocator: std.mem.Allocator,
    logical_ref: []const u8,
    records: usize,
    revision: []u8,
    transaction_id: []u8,
) !Result {
    return .{
        .logical_ref = try allocator.dupe(u8, logical_ref),
        .revision = revision,
        .records = records,
        .transaction_id = transaction_id,
        .already_migrated = false,
    };
}

fn prepareHead(
    allocator: std.mem.Allocator,
    logical_path: []const u8,
    event_bytes: []const u8,
    event_records: usize,
    binding_bytes: []const u8,
    binding_rows: usize,
    checkpoint_bytes: []const u8,
) !segmented_event_log.Head {
    var head = try segmented_event_log.Head.init(allocator, logical_path);
    errdefer head.deinit(allocator);
    try head.importLegacy(
        event_bytes,
        event_records,
        binding_bytes,
        binding_rows,
    );
    try head.installCheckpoint(checkpoint_bytes);
    return head;
}

fn releaseReadCustody(legacy: *custody.SlotSnapshot) void {
    if (legacy.read_custody) |*read_custody| read_custody.deinit();
    legacy.read_custody = null;
}

fn requireRevision(actual: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) {
        return error.SegmentedMigrationRevisionMismatch;
    }
}

fn existingResult(
    allocator: std.mem.Allocator,
    logical_ref: []const u8,
    target: *const segmented_event_log.Snapshot,
) !Result {
    const owned_ref = try allocator.dupe(u8, logical_ref);
    errdefer allocator.free(owned_ref);
    const revision = try target.head.revisionAlloc(allocator);
    errdefer allocator.free(revision);
    return .{
        .logical_ref = owned_ref,
        .revision = revision,
        .records = std.math.cast(
            usize,
            target.head.total_event_records,
        ) orelse return error.CurrentStoreRecordBoundsExceeded,
        .transaction_id = null,
        .already_migrated = true,
    };
}

fn commitMigration(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    definition_closure: *const definition_core.Closure,
    definition_entry_path: []const u8,
    repo_root: []const u8,
    target: *const segmented_event_log.Snapshot,
    legacy: *const custody.SlotSnapshot,
    head: *const segmented_event_log.Head,
    checkpoint_bytes: []const u8,
) ![]u8 {
    try ensureMigrationDirectories(allocator, target, repo_root);
    var archive = try definition_archive.prepare(
        allocator,
        repo_root,
        definition_plan.id,
        definition_entry_path,
        definition_closure,
    );
    defer archive.deinit(allocator);
    var owned = try MigrationMutations.init(
        allocator,
        target,
        repo_root,
        legacy,
        head,
        checkpoint_bytes,
        &archive,
    );
    defer owned.deinit(allocator);
    const transactions = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", ".transactions" },
    );
    defer allocator.free(transactions);
    const counter = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", ".fencing.counter" },
    );
    defer allocator.free(counter);
    var commit = try durable_store.commitTextTransaction(
        allocator,
        transactions,
        owned.mutations,
        .{
            .owner = .{
                .process_id = 0,
                .session_id = "ledger-segmented-migration-v1",
                .executor = "ledger",
            },
            .fencing_counter_path = counter,
            .reject_symlinks = true,
        },
    );
    defer commit.deinit(allocator);
    return allocator.dupe(u8, commit.transaction_id);
}

fn ensureMigrationDirectories(
    allocator: std.mem.Allocator,
    target: *const segmented_event_log.Snapshot,
    repo_root: []const u8,
) !void {
    try durable_store.ensureDirectoryPathNoSymlinks(target.paths.events);
    try durable_store.ensureDirectoryPathNoSymlinks(target.paths.bindings);
    try durable_store.ensureDirectoryPathNoSymlinks(target.paths.checkpoints);
    const transactions = try std.fs.path.join(
        allocator,
        &.{ repo_root, ".ledger", ".transactions" },
    );
    defer allocator.free(transactions);
    try durable_store.ensureDirectoryPathNoSymlinks(transactions);
}

const MigrationMutations = struct {
    mutations: []durable_store.TransactionMutation,
    event_path: []u8,
    binding_path: []u8,
    checkpoint_path: []u8,
    legacy_binding_path: []u8,
    head_after: []u8,
    head_digest: []u8,
    checkpoint_digest: []u8,

    fn init(
        allocator: std.mem.Allocator,
        target: *const segmented_event_log.Snapshot,
        repo_root: []const u8,
        legacy: *const custody.SlotSnapshot,
        head: *const segmented_event_log.Head,
        checkpoint_bytes: []const u8,
        archive: *const definition_archive.Candidate,
    ) !MigrationMutations {
        var result = try initMigrationMutationStorage(
            allocator,
            target,
            repo_root,
            head,
            checkpoint_bytes,
            archive.exists,
        );
        errdefer result.deinit(allocator);
        result.fill(target, legacy, checkpoint_bytes, archive);
        return result;
    }

    fn deinit(self: *MigrationMutations, allocator: std.mem.Allocator) void {
        allocator.free(self.mutations);
        allocator.free(self.event_path);
        allocator.free(self.binding_path);
        allocator.free(self.checkpoint_path);
        allocator.free(self.legacy_binding_path);
        allocator.free(self.head_after);
        allocator.free(self.head_digest);
        allocator.free(self.checkpoint_digest);
        self.* = undefined;
    }

    fn fill(
        self: *MigrationMutations,
        target: *const segmented_event_log.Snapshot,
        legacy: *const custody.SlotSnapshot,
        checkpoint_bytes: []const u8,
        archive: *const definition_archive.Candidate,
    ) void {
        self.mutations[0] = sourceEventMutation(legacy);
        self.mutations[1] = sourceBindingMutation(self, legacy);
        self.mutations[2] = sealedEventMutation(self, legacy);
        self.mutations[3] = sealedBindingMutation(self, legacy);
        self.mutations[4] = checkpointMutation(self, checkpoint_bytes);
        self.mutations[5] = headMutation(self, target);
        if (!archive.exists) self.mutations[6] = .{
            .path = archive.path,
            .text = archive.content,
            .expectation = .{ .expected_exists = false },
            .content_mode = .raw,
            .max_bytes = definition_archive.max_bytes,
        };
    }
};

fn initMigrationMutationStorage(
    allocator: std.mem.Allocator,
    target: *const segmented_event_log.Snapshot,
    repo_root: []const u8,
    head: *const segmented_event_log.Head,
    checkpoint_bytes: []const u8,
    archive_exists: bool,
) !MigrationMutations {
    const mutations = try allocator.alloc(
        durable_store.TransactionMutation,
        if (archive_exists) 6 else 7,
    );
    errdefer allocator.free(mutations);
    const event_path = try target.paths.eventSegmentAlloc(allocator, 0);
    errdefer allocator.free(event_path);
    const binding_path = try target.paths.bindingSegmentAlloc(allocator, 0);
    errdefer allocator.free(binding_path);
    const checkpoint_path = try target.paths.checkpointAlloc(allocator, 0);
    errdefer allocator.free(checkpoint_path);
    const legacy_binding_path = try custody.bindingPathAlloc(
        allocator,
        repo_root,
        head.logical_path,
    );
    errdefer allocator.free(legacy_binding_path);
    const head_after = try head.encodeAlloc(allocator);
    errdefer allocator.free(head_after);
    const head_digest = try digestAlloc(allocator, head_after);
    errdefer allocator.free(head_digest);
    return .{
        .mutations = mutations,
        .event_path = event_path,
        .binding_path = binding_path,
        .checkpoint_path = checkpoint_path,
        .legacy_binding_path = legacy_binding_path,
        .head_after = head_after,
        .head_digest = head_digest,
        .checkpoint_digest = try digestAlloc(allocator, checkpoint_bytes),
    };
}

fn sourceEventMutation(
    legacy: *const custody.SlotSnapshot,
) durable_store.TransactionMutation {
    return .{
        .path = legacy.path,
        .text = legacy.content,
        .expectation = .{
            .expected_digest = legacy.revision,
            .expected_exists = true,
        },
        .content_mode = .raw,
        .max_bytes = segmented_event_log.event_segment_bytes,
        .expected_digest_after = legacy.revision,
    };
}

fn sourceBindingMutation(
    owned: *const MigrationMutations,
    legacy: *const custody.SlotSnapshot,
) durable_store.TransactionMutation {
    return .{
        .path = owned.legacy_binding_path,
        .text = legacy.binding.bytes,
        .expectation = .{
            .expected_digest = legacy.binding.digest,
            .expected_exists = true,
        },
        .content_mode = .raw,
        .max_bytes = segmented_event_log.binding_segment_bytes,
        .expected_digest_after = legacy.binding.digest,
    };
}

fn sealedEventMutation(
    owned: *const MigrationMutations,
    legacy: *const custody.SlotSnapshot,
) durable_store.TransactionMutation {
    return .{
        .path = owned.event_path,
        .text = legacy.content,
        .expectation = .{ .expected_exists = false },
        .content_mode = .raw,
        .max_bytes = segmented_event_log.event_segment_bytes,
        .expected_digest_after = legacy.revision,
    };
}

fn sealedBindingMutation(
    owned: *const MigrationMutations,
    legacy: *const custody.SlotSnapshot,
) durable_store.TransactionMutation {
    return .{
        .path = owned.binding_path,
        .text = legacy.binding.bytes,
        .expectation = .{ .expected_exists = false },
        .content_mode = .raw,
        .max_bytes = segmented_event_log.binding_segment_bytes,
        .expected_digest_after = legacy.binding.digest,
    };
}

fn checkpointMutation(
    owned: *const MigrationMutations,
    checkpoint_bytes: []const u8,
) durable_store.TransactionMutation {
    return .{
        .path = owned.checkpoint_path,
        .text = checkpoint_bytes,
        .expectation = .{ .expected_exists = false },
        .content_mode = .raw,
        .max_bytes = checkpoint.max_checkpoint_bytes,
        .expected_digest_after = owned.checkpoint_digest,
    };
}

fn headMutation(
    owned: *const MigrationMutations,
    target: *const segmented_event_log.Snapshot,
) durable_store.TransactionMutation {
    return .{
        .path = target.paths.manifest,
        .text = owned.head_after,
        .expectation = .{ .expected_exists = false },
        .content_mode = .raw,
        .max_bytes = 64 * 1024,
        .expected_digest_after = owned.head_digest,
    };
}

fn digestAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]u8 {
    return definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
}
