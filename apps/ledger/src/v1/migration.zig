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
const transaction = @import("transaction.zig");

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
    transaction.resetMutationState();
    if (!std.fs.path.isAbsolute(repo_root)) {
        return error.RepositoryRootNotAbsolute;
    }
    if (!std.mem.eql(
        u8,
        definition_plan.closure_digest[0..],
        definition_closure.digestSlice(),
    )) {
        return error.DefinitionClosureDigestMismatch;
    }
    if (try transaction.recoverRepositoryTransactions(
        allocator,
        repo_root,
    )) transaction.markStorageMutated();
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
    if (target.head_exists) return validateExistingTarget(
        allocator,
        definition_plan,
        repo_root,
        slot,
        parameters,
        slot.relative_path,
        &target,
    );
    return migrateLegacySlot(
        allocator,
        definition_plan,
        definition_closure,
        definition_entry_path,
        event_plan,
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
    event_plan: *const protocol.Plan,
    repo_root: []const u8,
    slot: storage.ResolvedSlot,
    parameters: *const definition_core.parameters.Bindings,
    target: *const segmented_event_log.Snapshot,
) !Result {
    var legacy_slot = slot;
    legacy_slot.layout = .monolithic;
    legacy_slot.max_bytes = segmented_event_log.legacy_event_max_bytes;
    var legacy = try custody.readSlot(
        allocator,
        repo_root,
        definition_plan.id,
        legacy_slot,
    );
    defer legacy.deinit(allocator);
    var stats = try replay.validateSlot(
        allocator,
        repo_root,
        definition_plan.id,
        legacy_slot,
        &legacy,
        parameters,
        definition_plan.bounds.max_records,
        true,
    );
    defer stats.deinit(allocator);
    if (stats.protocol_state == null) return error.SegmentedMigrationCheckpointMissing;
    const state = &stats.protocol_state.?;
    try protocol.activateCheckpoint(allocator, event_plan, state);
    const checkpoint_bytes = try protocol.encodeCheckpointAlloc(
        allocator,
        state,
        definition_plan.closure_digest[0..],
    );
    defer allocator.free(checkpoint_bytes);
    var segments = try MigrationSegments.init(
        allocator,
        legacy.content,
        legacy.binding.bytes,
    );
    defer segments.deinit(allocator);
    var head = try prepareHead(
        allocator,
        slot.relative_path,
        segments.events,
        segments.bindings,
        checkpoint_bytes,
    );
    defer head.deinit(allocator);
    if (head.total_event_records != stats.records_validated or
        head.total_binding_rows != legacy.binding.rows.len)
    {
        return error.SegmentedMigrationRecordMismatch;
    }
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
        &segments,
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

const MigrationSegments = struct {
    events: [][]const u8,
    bindings: [][]const u8,

    fn init(
        allocator: std.mem.Allocator,
        events: []const u8,
        bindings: []const u8,
    ) !MigrationSegments {
        const event_segments = try splitSegmentsAlloc(
            allocator,
            events,
            segmented_event_log.event_segment_bytes,
        );
        errdefer allocator.free(event_segments);
        const binding_segments = try splitSegmentsAlloc(
            allocator,
            bindings,
            segmented_event_log.binding_segment_bytes,
        );
        return .{
            .events = event_segments,
            .bindings = binding_segments,
        };
    }

    fn deinit(self: *MigrationSegments, allocator: std.mem.Allocator) void {
        allocator.free(self.events);
        allocator.free(self.bindings);
        self.* = undefined;
    }
};

fn splitSegmentsAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    maximum: usize,
) ![][]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') {
        return error.InvalidLegacySegmentSource;
    }
    var segments: std.ArrayList([]const u8) = .empty;
    errdefer segments.deinit(allocator);
    var segment_start: usize = 0;
    var record_start: usize = 0;
    while (record_start < bytes.len) {
        const newline_offset = std.mem.indexOfScalar(
            u8,
            bytes[record_start..],
            '\n',
        ) orelse return error.InvalidLegacySegmentSource;
        const record_end = record_start + newline_offset + 1;
        if (record_end - record_start > maximum) {
            return error.LegacyRecordExceedsSegment;
        }
        if (record_end - segment_start > maximum) {
            try segments.append(allocator, bytes[segment_start..record_start]);
            segment_start = record_start;
        }
        record_start = record_end;
    }
    try segments.append(allocator, bytes[segment_start..]);
    return segments.toOwnedSlice(allocator);
}

fn prepareHead(
    allocator: std.mem.Allocator,
    logical_path: []const u8,
    event_segments: []const []const u8,
    binding_segments: []const []const u8,
    checkpoint_bytes: []const u8,
) !segmented_event_log.Head {
    var head = try segmented_event_log.Head.init(allocator, logical_path);
    errdefer head.deinit(allocator);
    try head.importLegacySegments(event_segments, binding_segments);
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

fn validateExistingTarget(
    allocator: std.mem.Allocator,
    definition_plan: *const definition.Plan,
    repo_root: []const u8,
    slot: storage.ResolvedSlot,
    parameters: *const definition_core.parameters.Bindings,
    logical_ref: []const u8,
    target: *const segmented_event_log.Snapshot,
) !Result {
    try segmented_event_log.auditHistory(allocator, target);
    const logical_revision = try target.head.revisionAlloc(allocator);
    defer allocator.free(logical_revision);
    var binding = try custody.parseBindingSegment(
        allocator,
        target.binding_bytes,
        definition_plan.id,
        slot.name,
        slot.relative_path,
        target.head.checkpointRevision() orelse logical_revision,
        logical_revision,
        null,
    );
    defer binding.deinit(allocator);
    var stats = try replay.validateSegmentedSnapshot(
        allocator,
        repo_root,
        definition_plan.id,
        slot,
        target,
        &binding,
        parameters,
        definition_plan.bounds.max_records,
        true,
    );
    defer stats.deinit(allocator);
    if (stats.protocol_state == null) {
        return error.SegmentedMigrationCheckpointMissing;
    }
    const transaction_id = try reconcileExistingTombstones(
        allocator,
        repo_root,
        target,
    );
    errdefer if (transaction_id) |id| allocator.free(id);
    const owned_ref = try allocator.dupe(u8, logical_ref);
    errdefer allocator.free(owned_ref);
    const revision = try target.head.revisionAlloc(allocator);
    errdefer allocator.free(revision);
    return .{
        .logical_ref = owned_ref,
        .revision = revision,
        .records = stats.records_validated,
        .transaction_id = transaction_id,
        .already_migrated = transaction_id == null,
    };
}

const TombstoneState = enum { absent, exact, invalid };

fn reconcileExistingTombstones(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    target: *const segmented_event_log.Snapshot,
) !?[]u8 {
    const paths = &target.paths;
    const event_state = try tombstoneState(
        allocator,
        paths.legacy_event,
        segmented_event_log.legacy_event_tombstone,
    );
    const binding_state = try tombstoneState(
        allocator,
        paths.legacy_binding,
        segmented_event_log.legacy_binding_tombstone,
    );
    if (event_state == .exact and binding_state == .exact) return null;
    if (event_state == .absent and binding_state == .absent) {
        return installTombstones(
            allocator,
            repo_root,
            paths,
            null,
            null,
        );
    }
    if (event_state != .invalid or binding_state != .invalid) {
        return error.SegmentedLegacyCustodyMismatch;
    }
    const legacy_events = try durable_store.readRegularFileNoSymlink(
        allocator,
        paths.legacy_event,
        segmented_event_log.legacy_event_max_bytes,
    );
    defer allocator.free(legacy_events);
    const legacy_bindings = try durable_store.readRegularFileNoSymlink(
        allocator,
        paths.legacy_binding,
        custody.binding_max_bytes,
    );
    defer allocator.free(legacy_bindings);
    if (!try eventHistoryEquals(allocator, target, legacy_events) or
        !try bindingHistoryEquals(allocator, target, legacy_bindings))
    {
        return error.SegmentedLegacyCustodyMismatch;
    }
    const event_digest = try digestAlloc(allocator, legacy_events);
    defer allocator.free(event_digest);
    const binding_digest = try digestAlloc(allocator, legacy_bindings);
    defer allocator.free(binding_digest);
    return installTombstones(
        allocator,
        repo_root,
        paths,
        event_digest,
        binding_digest,
    );
}

fn installTombstones(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    paths: *const segmented_event_log.Paths,
    event_digest: ?[]const u8,
    binding_digest: ?[]const u8,
) !?[]u8 {
    transaction.markStorageMutationUnknown();
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
    const mutations = [_]durable_store.TransactionMutation{
        tombstoneMutation(
            paths.legacy_event,
            segmented_event_log.legacy_event_tombstone,
            legacyEventMutationMaximum(event_digest),
            event_digest,
        ),
        tombstoneMutation(
            paths.legacy_binding,
            segmented_event_log.legacy_binding_tombstone,
            segmented_event_log.binding_segment_bytes,
            binding_digest,
        ),
    };
    var commit = try durable_store.commitTextTransaction(
        allocator,
        transactions,
        &mutations,
        .{
            .owner = .{
                .process_id = 0,
                .session_id = "ledger-segmented-custody-upgrade-v1",
                .executor = "ledger",
            },
            .fencing_counter_path = counter,
            .reject_symlinks = true,
        },
    );
    defer commit.deinit(allocator);
    transaction.markStorageMutated();
    return @as(?[]u8, try allocator.dupe(u8, commit.transaction_id));
}

fn legacyEventMutationMaximum(expected_digest: ?[]const u8) usize {
    return if (expected_digest == null)
        segmented_event_log.event_segment_bytes
    else
        segmented_event_log.legacy_event_max_bytes;
}

fn eventHistoryEquals(
    allocator: std.mem.Allocator,
    snapshot: *const segmented_event_log.Snapshot,
    legacy: []const u8,
) !bool {
    var iterator = segmented_event_log.EventHistoryIterator{
        .allocator = allocator,
        .snapshot = snapshot,
    };
    var offset: usize = 0;
    while (try iterator.next()) |bytes| {
        defer allocator.free(bytes);
        const end = std.math.add(usize, offset, bytes.len) catch return false;
        if (end > legacy.len or !std.mem.eql(u8, legacy[offset..end], bytes)) {
            return false;
        }
        offset = end;
        if (offset == legacy.len) return true;
    }
    try iterator.finish();
    return false;
}

fn bindingHistoryEquals(
    allocator: std.mem.Allocator,
    snapshot: *const segmented_event_log.Snapshot,
    legacy: []const u8,
) !bool {
    var iterator = segmented_event_log.BindingHistoryIterator{
        .allocator = allocator,
        .snapshot = snapshot,
    };
    var offset: usize = 0;
    while (try iterator.next()) |bytes| {
        defer allocator.free(bytes);
        const end = std.math.add(usize, offset, bytes.len) catch return false;
        if (end > legacy.len or !std.mem.eql(u8, legacy[offset..end], bytes)) {
            return false;
        }
        offset = end;
        if (offset == legacy.len) return true;
    }
    try iterator.finish();
    return false;
}

fn tombstoneState(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: []const u8,
) !TombstoneState {
    const bytes = durable_store.readRegularFileNoSymlink(
        allocator,
        path,
        expected.len,
    ) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        error.FileTooBig => return .invalid,
        else => return err,
    };
    defer allocator.free(bytes);
    return if (std.mem.eql(u8, bytes, expected)) .exact else .invalid;
}

fn tombstoneMutation(
    path: []const u8,
    text: []const u8,
    maximum: usize,
    expected_digest: ?[]const u8,
) durable_store.TransactionMutation {
    return .{
        .path = path,
        .text = text,
        .expectation = .{
            .expected_digest = expected_digest,
            .expected_exists = expected_digest != null,
        },
        .content_mode = .raw,
        .max_bytes = maximum,
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
    segments: *const MigrationSegments,
    checkpoint_bytes: []const u8,
) ![]u8 {
    transaction.markStorageMutationUnknown();
    try ensureMigrationDirectories(allocator, target, repo_root);
    transaction.markStorageMutated();
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
        segments,
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
    transaction.markStorageMutated();
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
    event_paths: [][]u8,
    binding_paths: [][]u8,
    checkpoint_path: []u8,
    legacy_binding_path: []u8,
    head_after: []u8,
    head_digest: []u8,
    checkpoint_digest: []u8,
    legacy_event_tombstone_digest: []u8,
    legacy_binding_tombstone_digest: []u8,

    fn init(
        allocator: std.mem.Allocator,
        target: *const segmented_event_log.Snapshot,
        repo_root: []const u8,
        legacy: *const custody.SlotSnapshot,
        head: *const segmented_event_log.Head,
        segments: *const MigrationSegments,
        checkpoint_bytes: []const u8,
        archive: *const definition_archive.Candidate,
    ) !MigrationMutations {
        var result = try initMigrationMutationStorage(
            allocator,
            target,
            repo_root,
            head,
            segments,
            checkpoint_bytes,
            archive.exists,
        );
        errdefer result.deinit(allocator);
        result.fill(
            target,
            legacy,
            segments,
            checkpoint_bytes,
            archive,
        );
        return result;
    }

    fn deinit(self: *MigrationMutations, allocator: std.mem.Allocator) void {
        allocator.free(self.mutations);
        for (self.event_paths) |path| allocator.free(path);
        allocator.free(self.event_paths);
        for (self.binding_paths) |path| allocator.free(path);
        allocator.free(self.binding_paths);
        allocator.free(self.checkpoint_path);
        allocator.free(self.legacy_binding_path);
        allocator.free(self.head_after);
        allocator.free(self.head_digest);
        allocator.free(self.checkpoint_digest);
        allocator.free(self.legacy_event_tombstone_digest);
        allocator.free(self.legacy_binding_tombstone_digest);
        self.* = undefined;
    }

    fn fill(
        self: *MigrationMutations,
        target: *const segmented_event_log.Snapshot,
        legacy: *const custody.SlotSnapshot,
        segments: *const MigrationSegments,
        checkpoint_bytes: []const u8,
        archive: *const definition_archive.Candidate,
    ) void {
        self.mutations[0] = sourceEventMutation(self, legacy);
        self.mutations[1] = sourceBindingMutation(self, legacy);
        var index: usize = 2;
        for (segments.events, 0..) |bytes, segment_index| {
            self.mutations[index] = sealedSegmentMutation(
                self.event_paths[segment_index],
                bytes,
                segmented_event_log.event_segment_bytes,
            );
            index += 1;
        }
        for (segments.bindings, 0..) |bytes, segment_index| {
            self.mutations[index] = sealedSegmentMutation(
                self.binding_paths[segment_index],
                bytes,
                segmented_event_log.binding_segment_bytes,
            );
            index += 1;
        }
        self.mutations[index] = checkpointMutation(self, checkpoint_bytes);
        index += 1;
        self.mutations[index] = headMutation(self, target);
        index += 1;
        if (!archive.exists) self.mutations[index] = .{
            .path = archive.path,
            .text = archive.content,
            .expectation = .{ .expected_exists = false },
            .content_mode = .raw,
            .max_bytes = definition_archive.max_bytes,
        };
        std.debug.assert(index + @intFromBool(!archive.exists) ==
            self.mutations.len);
    }
};

fn initMigrationMutationStorage(
    allocator: std.mem.Allocator,
    target: *const segmented_event_log.Snapshot,
    repo_root: []const u8,
    head: *const segmented_event_log.Head,
    segments: *const MigrationSegments,
    checkpoint_bytes: []const u8,
    archive_exists: bool,
) !MigrationMutations {
    const mutations = try allocator.alloc(
        durable_store.TransactionMutation,
        4 + segments.events.len + segments.bindings.len +
            @as(usize, if (archive_exists) 0 else 1),
    );
    errdefer allocator.free(mutations);
    const event_paths = try segmentPathsAlloc(
        allocator,
        &target.paths,
        segments.events.len,
        .events,
    );
    errdefer freePaths(allocator, event_paths);
    const binding_paths = try segmentPathsAlloc(
        allocator,
        &target.paths,
        segments.bindings.len,
        .bindings,
    );
    errdefer freePaths(allocator, binding_paths);
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
    const checkpoint_digest = try digestAlloc(allocator, checkpoint_bytes);
    errdefer allocator.free(checkpoint_digest);
    const legacy_event_tombstone_digest = try digestAlloc(
        allocator,
        segmented_event_log.legacy_event_tombstone,
    );
    errdefer allocator.free(legacy_event_tombstone_digest);
    const legacy_binding_tombstone_digest = try digestAlloc(
        allocator,
        segmented_event_log.legacy_binding_tombstone,
    );
    errdefer allocator.free(legacy_binding_tombstone_digest);
    return .{
        .mutations = mutations,
        .event_paths = event_paths,
        .binding_paths = binding_paths,
        .checkpoint_path = checkpoint_path,
        .legacy_binding_path = legacy_binding_path,
        .head_after = head_after,
        .head_digest = head_digest,
        .checkpoint_digest = checkpoint_digest,
        .legacy_event_tombstone_digest = legacy_event_tombstone_digest,
        .legacy_binding_tombstone_digest = legacy_binding_tombstone_digest,
    };
}

fn sourceEventMutation(
    owned: *const MigrationMutations,
    legacy: *const custody.SlotSnapshot,
) durable_store.TransactionMutation {
    return .{
        .path = legacy.path,
        .text = segmented_event_log.legacy_event_tombstone,
        .expectation = .{
            .expected_digest = legacy.revision,
            .expected_exists = true,
        },
        .content_mode = .raw,
        .max_bytes = segmented_event_log.legacy_event_max_bytes,
        .expected_digest_after = owned.legacy_event_tombstone_digest,
    };
}

fn sourceBindingMutation(
    owned: *const MigrationMutations,
    legacy: *const custody.SlotSnapshot,
) durable_store.TransactionMutation {
    return .{
        .path = owned.legacy_binding_path,
        .text = segmented_event_log.legacy_binding_tombstone,
        .expectation = .{
            .expected_digest = legacy.binding.digest,
            .expected_exists = true,
        },
        .content_mode = .raw,
        .max_bytes = segmented_event_log.binding_segment_bytes,
        .expected_digest_after = owned.legacy_binding_tombstone_digest,
    };
}

fn sealedSegmentMutation(
    path: []const u8,
    bytes: []const u8,
    maximum: usize,
) durable_store.TransactionMutation {
    return .{
        .path = path,
        .text = bytes,
        .expectation = .{ .expected_exists = false },
        .content_mode = .raw,
        .max_bytes = maximum,
    };
}

const MigrationSegmentKind = enum { events, bindings };

fn segmentPathsAlloc(
    allocator: std.mem.Allocator,
    paths: *const segmented_event_log.Paths,
    count: usize,
    kind: MigrationSegmentKind,
) ![][]u8 {
    const result = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |path| allocator.free(path);
        allocator.free(result);
    }
    while (initialized < count) : (initialized += 1) {
        result[initialized] = switch (kind) {
            .events => try paths.eventSegmentAlloc(
                allocator,
                @intCast(initialized),
            ),
            .bindings => try paths.bindingSegmentAlloc(
                allocator,
                @intCast(initialized),
            ),
        };
    }
    return result;
}

fn freePaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
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

test "legacy custody tombstones are fail-closed for monolithic readers" {
    const event_result = durable_store.validateJsonlBytes(
        std.testing.allocator,
        segmented_event_log.legacy_event_tombstone,
    );
    const binding_result = durable_store.validateJsonlBytes(
        std.testing.allocator,
        segmented_event_log.legacy_binding_tombstone,
    );
    try std.testing.expect(!event_result.ok());
    try std.testing.expect(!binding_result.ok());
}

test "legacy migration partitions a monolithic log above one segment" {
    const length = segmented_event_log.event_segment_bytes + 2;
    const events = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(events);
    var index: usize = 0;
    while (index < events.len) : (index += 3) {
        @memcpy(events[index .. index + 3], "{}\n");
    }
    var segments = try MigrationSegments.init(
        std.testing.allocator,
        events,
        "{}\n",
    );
    defer segments.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), segments.events.len);
    try std.testing.expect(segments.events[0].len <=
        segmented_event_log.event_segment_bytes);
    try std.testing.expectEqual(length, segments.events[0].len + segments.events[1].len);
    var head = try prepareHead(
        std.testing.allocator,
        "example/events.jsonl",
        segments.events,
        segments.bindings,
        "checkpoint",
    );
    defer head.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, @intCast(length)), head.total_event_bytes);
    try std.testing.expectEqual(@as(u64, 2), head.event_index);
    try std.testing.expectEqual(@as(usize, 0), head.event_bytes);
}

test "explicit migration reserves absent legacy paths for segmented stores" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".ledger/example");
    try tmp.dir.createDirPath(std.testing.io, ".ledger/.bindings/example");
    try tmp.dir.createDirPath(std.testing.io, ".ledger/.transactions");
    const repo_root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(repo_root);
    var paths = try segmented_event_log.Paths.init(
        std.testing.allocator,
        repo_root,
        "example/events.jsonl",
    );
    defer paths.deinit(std.testing.allocator);
    const transaction_id = (try installTombstones(
        std.testing.allocator,
        repo_root,
        &paths,
        null,
        null,
    )).?;
    defer std.testing.allocator.free(transaction_id);
    try std.testing.expectEqual(
        TombstoneState.exact,
        try tombstoneState(
            std.testing.allocator,
            paths.legacy_event,
            segmented_event_log.legacy_event_tombstone,
        ),
    );
}

test "legacy reconciliation retains the migration source bound" {
    try std.testing.expectEqual(
        segmented_event_log.event_segment_bytes,
        legacyEventMutationMaximum(null),
    );
    try std.testing.expectEqual(
        segmented_event_log.legacy_event_max_bytes,
        legacyEventMutationMaximum("sha256:source"),
    );
}

fn digestAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]u8 {
    return definition_core.canonical_json.digestBytesAlloc(allocator, bytes);
}
