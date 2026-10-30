const std = @import("std");
const jsonl_core = @import("jsonl_core");
const record_codec = @import("record_codec.zig");
const AcquireOptions = record_codec.AcquireOptions;
const CasExpectation = record_codec.CasExpectation;
const CasWriteReceipt = record_codec.CasWriteReceipt;
const CommitTransactionReceipt = record_codec.CommitTransactionReceipt;
const JsonlSnapshotCommitReceipt = record_codec.JsonlSnapshotCommitReceipt;
const JsonlTransactionOptions = record_codec.JsonlTransactionOptions;
const JsonlTransactionReceipt = record_codec.JsonlTransactionReceipt;
const LeaseLock = record_codec.LeaseLock;
const LegacyFencingAuthority = record_codec.LegacyFencingAuthority;
const LegacyLeaseReclaimRequest = record_codec.LegacyLeaseReclaimRequest;
const LegacyLeaseRecoveryCandidate = record_codec.LegacyLeaseRecoveryCandidate;
const Owner = record_codec.Owner;
const ParsedTransactionRecord = record_codec.ParsedTransactionRecord;
const ReclaimReceipt = record_codec.ReclaimReceipt;
const RecoveryDecision = record_codec.RecoveryDecision;
const RecoveryReceipt = record_codec.RecoveryReceipt;
const RecoveryStatus = record_codec.RecoveryStatus;
const Snapshot = record_codec.Snapshot;
const TransactionExpected = record_codec.TransactionExpected;
const TransactionMutation = record_codec.TransactionMutation;
const TransactionRecordFormat = record_codec.TransactionRecordFormat;
const TransactionRecoveryOptions = record_codec.TransactionRecoveryOptions;
const TransactionRecoverySummary = record_codec.TransactionRecoverySummary;
const TransactionState = record_codec.TransactionState;
const TransactionWrite = record_codec.TransactionWrite;
const default_snapshot_max_bytes = record_codec.default_snapshot_max_bytes;
const digestBytesAlloc = record_codec.digestBytesAlloc;
const freeTransactionExpectedRows = record_codec.freeTransactionExpectedRows;
const freeTransactionWriteRows = record_codec.freeTransactionWriteRows;
const isGeneratedTransactionId = record_codec.isGeneratedTransactionId;
const isLegacyTransactionId = record_codec.isLegacyTransactionId;
const jsonObjectSequence = record_codec.jsonObjectSequence;
const jsonlSequenceOrNull = record_codec.jsonlSequenceOrNull;
const jsonlSequenceRequired = record_codec.jsonlSequenceRequired;
const lastJsonlSequence = record_codec.lastJsonlSequence;
const leaseLineagesEqual = record_codec.leaseLineagesEqual;
const leaseWitnessesEqual = record_codec.leaseWitnessesEqual;
const legacyTransactionStageName = record_codec.legacyTransactionStageName;
const lockPathAlloc = record_codec.lockPathAlloc;
const makeLeaseLockOwned = record_codec.makeLeaseLockOwned;
const ownTransactionRecordFields = record_codec.ownTransactionRecordFields;
const ownersEqual = record_codec.ownersEqual;
const parseLeaseLockValue = record_codec.parseLeaseLockValue;
const parseU64Text = record_codec.parseU64Text;
const renderLeaseLockAlloc = record_codec.renderLeaseLockAlloc;
const renderParsedTransactionRecordAlloc = record_codec.renderParsedTransactionRecordAlloc;
const renderTransactionRecord = record_codec.renderTransactionRecord;
const renderTransactionRecordAlloc = record_codec.renderTransactionRecordAlloc;
const transactionRecordFields = record_codec.transactionRecordFields;
const transactionRecordFormat = record_codec.transactionRecordFormat;
const transactionStageName = record_codec.transactionStageName;
const transactionStageNameAlloc = record_codec.transactionStageNameAlloc;
const transaction_record_max_bytes = record_codec.transaction_record_max_bytes;
const transaction_recovery_max_rows = record_codec.transaction_recovery_max_rows;
const transaction_stage_prefix = record_codec.transaction_stage_prefix;
const validateAutomaticRecoveryRowBounds = record_codec.validateAutomaticRecoveryRowBounds;
const validateJsonlBytes = record_codec.validateJsonlBytes;
const fs_authority = @import("fs_authority.zig");
const Fs = fs_authority.Fs;
const filesystem = @import("filesystem.zig");
const CanonicalPathIndex = filesystem.CanonicalPathIndex;
const HostPathIdentityContext = filesystem.HostPathIdentityContext;
const LockFile = filesystem.LockFile;
const acquireCasAdvisoryLock = filesystem.acquireCasAdvisoryLock;
const acquireCasAdvisoryLockObserved = filesystem.acquireCasAdvisoryLockObserved;
const acquireExclusiveLockPath = filesystem.acquireExclusiveLockPath;
const acquireExclusiveLockPathRetry = filesystem.acquireExclusiveLockPathRetry;
const acquireLeaseAdvisoryLock = filesystem.acquireLeaseAdvisoryLock;
const acquireLeaseAdvisoryLockObserved = filesystem.acquireLeaseAdvisoryLockObserved;
const acquireTransactionJournalLock = filesystem.acquireTransactionJournalLock;
const acquireTransactionRecoveryLock = filesystem.acquireTransactionRecoveryLock;
const casAdvisoryPathAlloc = filesystem.casAdvisoryPathAlloc;
const casLockPathAlloc = filesystem.casLockPathAlloc;
const clockMillis = filesystem.clockMillis;
const deleteFileAfterFailure = filesystem.deleteFileAfterFailure;
const directoryNameIsCaseInsensitive = filesystem.directoryNameIsCaseInsensitive;
const elapsedMillis = filesystem.elapsedMillis;
const ensureDirectoryPathNoSymlinks = filesystem.ensureDirectoryPathNoSymlinks;
const fileExists = filesystem.fileExists;
const pathIsAtOrBelow = filesystem.pathIsAtOrBelow;
const pathIsWithinDirectory = filesystem.pathIsWithinDirectory;
const pathsAliasOrOverlap = filesystem.pathsAliasOrOverlap;
const pathsAliasOrOverlapCaseSensitive = filesystem.pathsAliasOrOverlapCaseSensitive;
const readFileAlloc = filesystem.readFileAlloc;
const readRegularFileNoSymlink = filesystem.readRegularFileNoSymlink;
const rejectCasControlTargetPath = filesystem.rejectCasControlTargetPath;
const rejectSymlinkComponents = filesystem.rejectSymlinkComponents;
const statRegularFileNoSymlink = filesystem.statRegularFileNoSymlink;
const syncDirectoryHandle = filesystem.syncDirectoryHandle;
const syncDirectoryPath = filesystem.syncDirectoryPath;
const tryReadForTest = filesystem.tryReadForTest;
const writeTextAtomic = filesystem.writeTextAtomic;
const writeTextCreateNew = filesystem.writeTextCreateNew;

pub fn acquireLeaseLock(
    fs: Fs,
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    options: AcquireOptions,
) !LeaseLock {
    return acquireLeaseLockObserved(
        fs,
        allocator,
        resource_path,
        options,
        null,
    );
}

fn tryAcquireLeaseLockObserved(
    fs: Fs,
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    lock_path: []const u8,
    counter_path: []const u8,
    options: AcquireOptions,
    storage_mutated: ?*bool,
) !?LeaseLock {
    var advisory = acquireLeaseAdvisoryLockObserved(
        fs,
        allocator,
        lock_path,
        storage_mutated,
    ) catch |err| switch (err) {
        error.LockBusy => return null,
        else => return err,
    };
    defer advisory.close(fs.io);
    if (try statRegularFileNoSymlink(fs, lock_path) != null) return null;
    const token = try allocateFencingToken(
        fs,
        allocator,
        counter_path,
        storage_mutated,
    );
    const now_ms = clockMillis(fs, .real);
    const expires_ms = std.math.add(
        u64,
        now_ms,
        options.lease_ms,
    ) catch return error.TransactionRecoveryRequired;
    const lock = try makeLeaseLockOwned(
        allocator,
        lock_path,
        resource_path,
        options.owner,
        now_ms,
        expires_ms,
        token,
        options.transaction_id,
    );
    const payload = renderLeaseLockAlloc(allocator, lock) catch |err| {
        var cleanup = lock;
        cleanup.deinit(allocator);
        return err;
    };
    defer allocator.free(payload);
    writeTextCreateNew(
        fs,
        allocator,
        lock_path,
        payload,
        .{ .reject_symlinks = options.reject_symlinks },
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {
            var cleanup = lock;
            cleanup.deinit(allocator);
            return null;
        },
        else => {
            var cleanup = lock;
            cleanup.deinit(allocator);
            return err;
        },
    };
    return lock;
}

fn sleepLeaseRetry(fs: Fs, options: AcquireOptions) !void {
    const sleep_ms = @min(
        @max(options.retry_interval_ms, 1),
        @as(u64, @intCast(std.math.maxInt(i64))),
    );
    try std.Io.sleep(
        fs.io,
        .fromMilliseconds(@intCast(sleep_ms)),
        .awake,
    );
}

fn acquireLeaseLockObserved(
    fs: Fs,
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    options: AcquireOptions,
    storage_mutated: ?*bool,
) !LeaseLock {
    if (options.reject_symlinks) try rejectSymlinkComponents(fs, resource_path);

    const lock_path = try lockPathAlloc(allocator, resource_path);
    defer allocator.free(lock_path);
    const counter_path = try fencingCounterPathAlloc(
        allocator,
        lock_path,
        options.fencing_counter_path,
    );
    defer allocator.free(counter_path);

    const started_ms = clockMillis(fs, .awake);
    var attempted = false;
    while (!attempted or elapsedMillis(fs, started_ms) < options.timeout_ms) {
        attempted = true;
        const lock = try tryAcquireLeaseLockObserved(
            fs,
            allocator,
            resource_path,
            lock_path,
            counter_path,
            options,
            storage_mutated,
        );
        if (lock) |acquired| return acquired;
        if (options.timeout_ms == 0 or
            elapsedMillis(fs, started_ms) >= options.timeout_ms)
        {
            return error.LockBusy;
        }
        try sleepLeaseRetry(fs, options);
    }
    return error.LockBusy;
}

pub fn refreshLease(
    fs: Fs,
    allocator: std.mem.Allocator,
    lock: *LeaseLock,
    expected_fencing_token: u64,
    lease_ms: u64,
) !void {
    var advisory = try acquireLeaseAdvisoryLock(
        fs,
        allocator,
        lock.path,
    );
    defer advisory.close(fs.io);
    const current = try readLeaseLock(fs, allocator, lock.path);
    var current_owned = current;
    defer current_owned.deinit(allocator);
    if (current.fencing_token != expected_fencing_token) return error.FencingTokenStale;
    if (!ownersEqual(current.owner, lock.owner)) return error.LockOwnerMismatch;

    const now_ms = clockMillis(fs, .real);
    const expires_ms = std.math.add(u64, now_ms, lease_ms) catch
        return error.TransactionRecoveryRequired;
    const refreshed = try makeLeaseLockOwned(
        allocator,
        lock.path,
        current.resource,
        current.owner,
        parseU64Text(current.acquired_at) catch now_ms,
        expires_ms,
        current.fencing_token,
        current.transaction_id,
    );
    var refreshed_owned = refreshed;
    errdefer refreshed_owned.deinit(allocator);

    const payload = try renderLeaseLockAlloc(allocator, refreshed);
    defer allocator.free(payload);
    try writeTextAtomic(fs, allocator, lock.path, payload);
    lock.deinit(allocator);
    lock.* = refreshed_owned;
}

pub fn releaseLease(
    fs: Fs,
    allocator: std.mem.Allocator,
    lock: *LeaseLock,
    expected_fencing_token: u64,
) !void {
    var advisory = try acquireLeaseAdvisoryLock(
        fs,
        allocator,
        lock.path,
    );
    defer advisory.close(fs.io);
    const current = try readLeaseLock(fs, allocator, lock.path);
    var current_owned = current;
    defer current_owned.deinit(allocator);
    if (current.fencing_token != expected_fencing_token) return error.FencingTokenStale;
    if (!ownersEqual(current.owner, lock.owner)) return error.LockOwnerMismatch;

    if (std.fs.path.isAbsolute(lock.path)) {
        try std.Io.Dir.deleteFileAbsolute(fs.io, lock.path);
    } else {
        try fs.directory().deleteFile(fs.io, lock.path);
    }
    lock.deinit(allocator);
}

pub fn reclaimExpiredLease(
    fs: Fs,
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    options: AcquireOptions,
) !ReclaimReceipt {
    if (options.reject_symlinks) try rejectSymlinkComponents(fs, resource_path);
    const lock_path = try lockPathAlloc(allocator, resource_path);
    defer allocator.free(lock_path);
    const counter_path = try fencingCounterPathAlloc(
        allocator,
        lock_path,
        options.fencing_counter_path,
    );
    defer allocator.free(counter_path);

    var advisory = try acquireLeaseAdvisoryLock(
        fs,
        allocator,
        lock_path,
    );
    defer advisory.close(fs.io);
    var current = try readLeaseLock(fs, allocator, lock_path);
    defer current.deinit(allocator);
    if (current.transaction_id != null) {
        return error.TransactionRecoveryRequired;
    }
    return reclaimLeaseMatchingWitnessLocked(
        fs,
        allocator,
        current,
        counter_path,
        null,
        true,
    );
}

fn reclaimLeaseMatchingWitnessLocked(
    fs: Fs,
    allocator: std.mem.Allocator,
    expected: LeaseLock,
    counter_path: []const u8,
    storage_mutated: ?*bool,
    require_expired: bool,
) !ReclaimReceipt {
    if (require_expired) {
        const expires_ms = try parseU64Text(expected.expires_at);
        if (clockMillis(fs, .real) < expires_ms) return error.LockBusy;
    }
    var current = try readLeaseLock(fs, allocator, expected.path);
    defer current.deinit(allocator);
    if (!leaseWitnessesEqual(current, expected)) {
        return error.FencingTokenStale;
    }
    const new_counter = try allocateFencingToken(
        fs,
        allocator,
        counter_path,
        storage_mutated,
    );
    if (expected.fencing_token >= new_counter) {
        return error.FencingTokenStale;
    }
    const evidence_path = try reclaimEvidencePathAlloc(
        allocator,
        expected,
    );
    defer allocator.free(evidence_path);
    const payload = try renderLeaseLockAlloc(allocator, expected);
    defer allocator.free(payload);
    writeTextCreateNew(
        fs,
        allocator,
        evidence_path,
        payload,
        .{},
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const existing = try readRegularFileNoSymlink(
                fs,
                allocator,
                evidence_path,
                4096,
            );
            defer allocator.free(existing);
            if (!std.mem.eql(u8, existing, payload)) return err;
        },
        else => return err,
    };
    if (storage_mutated) |mutated| mutated.* = true;
    const parent = std.fs.path.dirname(expected.path) orelse
        return error.InvalidPath;
    try syncDirectoryPath(fs, parent);
    if (std.fs.path.isAbsolute(expected.path)) {
        try std.Io.Dir.deleteFileAbsolute(fs.io, expected.path);
    } else {
        try fs.directory().deleteFile(fs.io, expected.path);
    }
    if (storage_mutated) |mutated| mutated.* = true;
    try syncDirectoryPath(fs, parent);
    return makeReclaimReceipt(
        allocator,
        expected,
        new_counter,
    );
}

fn reclaimEvidencePathAlloc(
    allocator: std.mem.Allocator,
    lock: LeaseLock,
) ![]u8 {
    return allocator.print(
        "{s}.reclaimed-{d}",
        .{ lock.path, lock.fencing_token },
    );
}

fn makeReclaimReceipt(
    allocator: std.mem.Allocator,
    expected: LeaseLock,
    authority_counter: u64,
) !ReclaimReceipt {
    const lock_id = try allocator.dupe(u8, expected.lock_id);
    errdefer allocator.free(lock_id);
    const resource = try allocator.dupe(u8, expected.resource);
    errdefer allocator.free(resource);
    const result = try allocator.dupe(u8, "reclaimed");
    return .{
        .lock_id = lock_id,
        .resource = resource,
        .previous_fencing_token = expected.fencing_token,
        .authority_counter = authority_counter,
        .result = result,
    };
}

fn fencingCounterPathAlloc(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    explicit_counter_path: ?[]const u8,
) ![]u8 {
    if (explicit_counter_path) |path| return allocator.dupe(u8, path);
    return allocator.print("{s}.counter", .{lock_path});
}

fn allocateFencingToken(
    fs: Fs,
    allocator: std.mem.Allocator,
    counter_path: []const u8,
    storage_mutated: ?*bool,
) !u64 {
    const counter_lock_path = try allocator.print("{s}.lock", .{counter_path});
    defer allocator.free(counter_lock_path);
    var counter_lock = try acquireExclusiveLockPath(fs, allocator, counter_lock_path);
    var counter_lock_pending = true;
    defer if (counter_lock_pending) counter_lock.release(allocator);
    if (storage_mutated) |mutated| mutated.* = true;
    const next = writeNextFencingCounter(
        fs,
        allocator,
        counter_path,
        storage_mutated,
    ) catch |err| {
        try counter_lock.releaseChecked(allocator);
        counter_lock_pending = false;
        try syncDirectoryPath(
            fs,
            std.fs.path.dirname(counter_path) orelse
                return error.InvalidPath,
        );
        return err;
    };
    try counter_lock.releaseChecked(allocator);
    counter_lock_pending = false;
    try syncDirectoryPath(
        fs,
        std.fs.path.dirname(counter_path) orelse
            return error.InvalidPath,
    );
    return next;
}

fn writeNextFencingCounter(
    fs: Fs,
    allocator: std.mem.Allocator,
    counter_path: []const u8,
    storage_mutated: ?*bool,
) !u64 {
    const current = try readFencingCounter(fs, allocator, counter_path);
    if (current == std.math.maxInt(u64)) {
        return error.TransactionRecoveryRequired;
    }
    const next = current + 1;
    const payload = try allocator.print("{d}\n", .{next});
    defer allocator.free(payload);
    try writeTextAtomic(fs, allocator, counter_path, payload);
    if (storage_mutated) |mutated| mutated.* = true;
    return next;
}

fn readFencingCounter(fs: Fs, allocator: std.mem.Allocator, counter_path: []const u8) !u64 {
    const bytes = readRegularFileNoSymlink(
        fs,
        allocator,
        counter_path,
        64,
    ) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer allocator.free(bytes);
    return parseU64Text(bytes) catch error.TransactionRecoveryRequired;
}

fn readLeaseLock(fs: Fs, allocator: std.mem.Allocator, path: []const u8) !LeaseLock {
    const bytes = try readRegularFileNoSymlink(fs, allocator, path, 4096);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    return parseLeaseLockValue(allocator, parsed.value, path);
}

const transaction_recovery_max_bytes: usize = if (@sizeOf(usize) >= 8)
    4 * 1024 * 1024 * 1024
else
    std.math.maxInt(usize);

const transaction_recovery_hash_max_bytes: usize = if (@sizeOf(usize) >= 8)
    16 * 1024 * 1024 * 1024
else
    std.math.maxInt(usize);

pub fn writeTextAtomicCas(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    expectation: CasExpectation,
) !CasWriteReceipt {
    return writeTextAtomicCasBounded(
        fs,
        allocator,
        path,
        text,
        expectation,
        default_snapshot_max_bytes,
    );
}

pub fn writeTextAtomicCasBounded(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    expectation: CasExpectation,
    max_bytes: usize,
) !CasWriteReceipt {
    if (max_bytes == 0 or text.len > max_bytes) return error.FileTooBig;
    var advisory_lock = try acquireCasAdvisoryLock(fs, allocator, path);
    defer advisory_lock.close(fs.io);
    const cas_lock_path = try casLockPathAlloc(allocator, path);
    defer allocator.free(cas_lock_path);
    var cas_lock = try acquireExclusiveLockPathRetry(fs, allocator, cas_lock_path, 5000, 2);
    defer cas_lock.release(allocator);
    return writeTextAtomicCasBoundedLocked(
        fs,
        allocator,
        path,
        text,
        expectation,
        max_bytes,
    );
}

fn writeTextAtomicCasBoundedLocked(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    expectation: CasExpectation,
    max_bytes: usize,
) !CasWriteReceipt {
    if (max_bytes == 0 or text.len > max_bytes) return error.FileTooBig;
    const current = readRegularFileNoSymlink(
        fs,
        allocator,
        path,
        max_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (current) |bytes| allocator.free(bytes);
    const exists = current != null;
    if (expectation.expected_exists) |expected_exists| {
        if (expected_exists != exists) return error.ExpectationMismatch;
    }

    const digest_before = if (current) |bytes| try digestBytesAlloc(allocator, bytes) else null;
    errdefer if (digest_before) |digest| allocator.free(digest);
    if (expectation.expected_digest) |expected_digest| {
        const actual = digest_before orelse return error.DigestMismatch;
        if (!std.mem.eql(u8, expected_digest, actual)) return error.DigestMismatch;
    }

    const sequence_before = if (current) |bytes|
        try jsonlSequenceOrNull(allocator, bytes)
    else
        null;
    if (expectation.expected_sequence) |expected_sequence| {
        const actual = sequence_before orelse return error.SequenceMismatch;
        if (expected_sequence != actual) return error.SequenceMismatch;
    }

    const digest_after = try digestBytesAlloc(allocator, text);
    errdefer allocator.free(digest_after);
    const sequence_after = try jsonlSequenceOrNull(allocator, text);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const result = try allocator.dupe(u8, "written");
    errdefer allocator.free(result);
    try writeTextAtomic(fs, allocator, path, text);
    return .{
        .path = owned_path,
        .digest_before = digest_before,
        .digest_after = digest_after,
        .sequence_before = sequence_before,
        .sequence_after = sequence_after,
        .result = result,
    };
}

pub fn readJsonlSnapshot(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_sequence: ?u64,
) !Snapshot {
    const data = try readRegularFileNoSymlink(fs, allocator, path, default_snapshot_max_bytes);
    errdefer allocator.free(data);
    const validation = try validateJsonlBytes(allocator, data);
    if (!validation.ok()) return error.InvalidJsonl;
    const digest = try digestBytesAlloc(allocator, data);
    errdefer allocator.free(digest);
    const sequence = try jsonlSequenceRequired(allocator, data);
    if (expected_sequence) |expected| {
        if (sequence == null or sequence.? != expected) return error.SequenceMismatch;
    }
    return .{
        .path = try allocator.dupe(u8, path),
        .data = data,
        .digest = digest,
        .sequence = sequence,
    };
}

const TransactionSnapshot = struct {
    digest: []u8,
    sequence: ?u64,
    byte_len: usize,

    fn deinit(self: TransactionSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.digest);
    }
};

fn readTransactionSnapshotAt(
    fs: Fs,
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    base: []const u8,
    mutation: TransactionMutation,
) !TransactionSnapshot {
    if (mutation.content_mode == .raw) {
        if (mutation.expectation.expected_sequence) |sequence| {
            if (sequence != 0) return error.SequenceMismatch;
        }
        const observed = try digestRegularFileNoSymlinkAtAlloc(
            fs,
            allocator,
            dir,
            base,
            mutation.max_bytes,
        );
        return .{
            .digest = observed.digest,
            .sequence = null,
            .byte_len = observed.byte_len,
        };
    }
    const data = try readRegularFileNoSymlinkAt(
        fs,
        allocator,
        dir,
        base,
        mutation.max_bytes,
    );
    defer allocator.free(data);
    const digest = try digestBytesAlloc(allocator, data);
    errdefer allocator.free(digest);
    const validation = try validateJsonlBytes(allocator, data);
    if (!validation.ok()) return error.InvalidJsonl;
    const sequence = try jsonlSequenceRequired(allocator, data);
    if (mutation.expectation.expected_sequence) |expected| {
        if (sequence == null or sequence.? != expected) {
            return error.SequenceMismatch;
        }
    }
    return .{
        .digest = digest,
        .sequence = sequence,
        .byte_len = data.len,
    };
}

const RegularFileDigest = struct {
    digest: []u8,
    byte_len: usize,
};

fn digestRegularFileNoSymlinkAtAlloc(
    fs: Fs,
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    base: []const u8,
    max_bytes: usize,
) !RegularFileDigest {
    const stat = try dir.statFile(
        fs.io,
        base,
        .{ .follow_symlinks = false },
    );
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.nlink > 1) return error.HardlinkTarget;
    if (stat.size > max_bytes) return error.FileTooBig;
    var file = try dir.openFile(
        fs.io,
        base,
        .{ .allow_directory = false, .follow_symlinks = false },
    );
    defer file.close(fs.io);
    var reader = file.reader(fs.io, &.{});
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var observed: usize = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (observed <= max_bytes) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        observed = std.math.add(usize, observed, count) catch
            return error.FileTooBig;
        if (observed > max_bytes) return error.FileTooBig;
        hasher.update(buffer[0..count]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return .{
        .digest = try allocator.print(
            "sha256:{s}",
            .{&hex},
        ),
        .byte_len = observed,
    };
}

fn rejectHardlinkedTargetAt(fs: Fs, dir: *std.Io.Dir, base: []const u8) !void {
    const stat = dir.statFile(
        fs.io,
        base,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (stat) |value| {
        if (value.kind == .sym_link) return error.SymlinkComponent;
        if (value.kind != .file) return error.NotFile;
        if (value.nlink > 1) return error.HardlinkTarget;
    }
}

fn readRegularFileNoSymlinkAt(
    fs: Fs,
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    base: []const u8,
    max_bytes: usize,
) ![]u8 {
    const stat = try dir.statFile(
        fs.io,
        base,
        .{ .follow_symlinks = false },
    );
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > max_bytes) return error.FileTooBig;
    var file = try dir.openFile(
        fs.io,
        base,
        .{ .allow_directory = false, .follow_symlinks = false },
    );
    defer file.close(fs.io);
    const opened = try file.stat(fs.io);
    if (opened.kind != .file or opened.nlink > 1) return error.HardlinkTarget;
    var reader = file.reader(fs.io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes + 1));
}

pub fn commitJsonlSnapshotCas(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    expectation: CasExpectation,
    transaction_id: ?[]const u8,
) !JsonlSnapshotCommitReceipt {
    const validation = try validateJsonlBytes(allocator, text);
    if (!validation.ok()) return error.InvalidJsonl;
    const owned_transaction_id = if (transaction_id) |id| try allocator.dupe(u8, id) else null;
    errdefer if (owned_transaction_id) |id| allocator.free(id);
    const receipt = try writeTextAtomicCas(fs, allocator, path, text, expectation);
    // Transfer the already prepared receipt: publication has succeeded, so
    // constructing this projection must not introduce another allocation.
    return .{
        .path = receipt.path,
        .sequence_before = receipt.sequence_before,
        .sequence_after = receipt.sequence_after,
        .digest_before = receipt.digest_before,
        .digest_after = receipt.digest_after,
        .transaction_id = owned_transaction_id,
        .result = receipt.result,
    };
}

const TransactionTarget = struct {
    fs: Fs,
    dir: std.Io.Dir,
    base: []const u8,
    inode: std.Io.File.INode,

    fn init(fs: Fs, control_root: []const u8, path: []const u8) !TransactionTarget {
        const relative = try pathRelativeToControlRoot(control_root, path);
        const parent = std.fs.path.dirname(relative) orelse "";
        var dir = if (std.fs.path.isAbsolute(control_root))
            try std.Io.Dir.openDirAbsolute(
                fs.io,
                control_root,
                .{ .follow_symlinks = false },
            )
        else
            try fs.directory().openDir(
                fs.io,
                control_root,
                .{ .follow_symlinks = false },
            );
        errdefer dir.close(fs.io);
        if (parent.len != 0) {
            var components = std.fs.path.componentIterator(parent);
            while (components.next()) |component| {
                if (component.name.len == 0 or
                    std.mem.eql(u8, component.name, ".") or
                    std.mem.eql(u8, component.name, ".."))
                {
                    return error.InvalidPath;
                }
                const next = dir.openDir(
                    fs.io,
                    component.name,
                    .{ .follow_symlinks = false },
                ) catch |err| switch (err) {
                    error.SymLinkLoop => return error.SymlinkComponent,
                    else => return err,
                };
                dir.close(fs.io);
                dir = next;
            }
        }
        const stat = try dir.statFile(
            fs.io,
            ".",
            .{ .follow_symlinks = false },
        );
        if (stat.kind != .directory) return error.NotDir;
        return .{
            .fs = fs,
            .dir = dir,
            .base = std.fs.path.basename(path),
            .inode = stat.inode,
        };
    }

    fn deinit(self: *TransactionTarget) void {
        const fs = self.fs;
        self.dir.close(fs.io);
        self.* = undefined;
    }

    fn verifyPathIdentity(self: *TransactionTarget) !void {
        const fs = self.fs;
        const stat = try self.dir.statFile(
            fs.io,
            ".",
            .{ .follow_symlinks = false },
        );
        if (stat.kind != .directory or stat.inode != self.inode) {
            return error.TransactionTargetChanged;
        }
    }
};

fn pathRelativeToControlRoot(
    control_root: []const u8,
    path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(control_root) != std.fs.path.isAbsolute(path) or
        path.len <= control_root.len or
        !std.mem.eql(u8, path[0..control_root.len], control_root) or
        !std.fs.path.isSep(path[control_root.len]))
    {
        return error.TransactionPathOutsideControlRoot;
    }
    const relative = path[control_root.len + 1 ..];
    if (relative.len == 0 or std.fs.path.isSep(relative[0])) {
        return error.InvalidPath;
    }
    var components = std.fs.path.componentIterator(relative);
    var observed: usize = 0;
    while (components.next()) |component| {
        observed += component.name.len;
        if (std.mem.eql(u8, component.name, ".") or
            std.mem.eql(u8, component.name, ".."))
        {
            return error.TransactionPathOutsideControlRoot;
        }
    }
    if (observed == 0) return error.InvalidPath;
    for (relative[1..], 1..) |byte, index| {
        if (std.fs.path.isSep(byte) and
            std.fs.path.isSep(relative[index - 1]))
        {
            return error.InvalidPath;
        }
    }
    return relative;
}

test "transaction paths reject lexical escapes before recovery reads" {
    try std.testing.expectEqualStrings(
        "nested/record.json",
        try pathRelativeToControlRoot(
            "/tmp/control",
            "/tmp/control/nested/record.json",
        ),
    );
    for ([_][]const u8{
        "/tmp/control/nested/../outside.json",
        "/tmp/control/./record.json",
        "/tmp/control-other/record.json",
    }) |path| {
        try std.testing.expectError(
            error.TransactionPathOutsideControlRoot,
            pathRelativeToControlRoot("/tmp/control", path),
        );
    }
    try std.testing.expectError(
        error.InvalidPath,
        pathRelativeToControlRoot(
            "/tmp/control",
            "/tmp/control//record.json",
        ),
    );
    if (@import("builtin").os.tag != .windows) {
        try std.testing.expectError(
            error.TransactionPathOutsideControlRoot,
            pathRelativeToControlRoot(
                "/tmp/control",
                "/tmp/control\\outside.json",
            ),
        );
    }
}

test "all transaction paths reserve the reclaim evidence namespace" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    try std.testing.expect(pathContainsReclaimEvidenceComponent(
        "/repo/events.jsonl.lock.reclaimed-42",
    ));
    try std.testing.expect(pathContainsReclaimEvidenceComponent(
        "/repo/EVENTS.LOCK.RECLAIMED-42/child",
    ));
    try std.testing.expect(pathContainsReclaimEvidenceComponent(
        "/repo/events.jsonl.lock.reclaimed-not-a-token",
    ));
    try std.testing.expect(pathContainsReclaimEvidenceComponent(
        "/repo/events.jsonl.lock.reclaimed-1700000000000-42",
    ));
    try std.testing.expectError(
        error.ReservedStorePath,
        rejectTransactionPath(
            fs,
            "/repo/events.jsonl.lock.reclaimed-1700000000000-42",
            false,
        ),
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, ".transactions", "dtx-68" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const evidence_target = try std.fs.path.join(
        allocator,
        &.{ root, "events.jsonl.lock.reclaimed-1700000000000-7" },
    );
    defer allocator.free(evidence_target);
    var expected = [_]TransactionExpected{.{
        .path = evidence_target,
        .digest = "",
        .sequence = 0,
    }};
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope(
            fs,
            allocator,
            root,
            transaction_dir,
            .{
                .transaction_id = "dtx-68",
                .owner = .{
                    .process_id = 968,
                    .session_id = "reclaim-evidence-namespace",
                    .executor = "test",
                },
                .state = .prepared,
                .expected = &expected,
                .writes = &.{},
                .created_at = "1",
                .updated_at = "2",
            },
            .legacy,
        ),
    );
}

fn addTransactionRecoveryHashAdmission(
    admitted: *usize,
    bytes: usize,
    max_bytes: usize,
) !void {
    const total = std.math.add(usize, admitted.*, bytes) catch
        return error.TransactionRecoveryWorkExceeded;
    if (total > max_bytes) {
        return error.TransactionRecoveryWorkExceeded;
    }
    admitted.* = total;
}

fn admitTransactionRecoveryHashWork(
    admitted: *usize,
    before_bytes: usize,
    after_bytes: usize,
    max_bytes: usize,
) !void {
    const before_recovery = std.math.mul(
        usize,
        before_bytes,
        4,
    ) catch return error.TransactionRecoveryWorkExceeded;
    const staged_recovery = std.math.mul(
        usize,
        after_bytes,
        2,
    ) catch return error.TransactionRecoveryWorkExceeded;
    const unpublished_recovery = std.math.add(
        usize,
        before_recovery,
        staged_recovery,
    ) catch return error.TransactionRecoveryWorkExceeded;
    const published_recovery = std.math.mul(
        usize,
        after_bytes,
        4,
    ) catch return error.TransactionRecoveryWorkExceeded;
    try addTransactionRecoveryHashAdmission(
        admitted,
        @max(unpublished_recovery, published_recovery),
        max_bytes,
    );
}

test "transaction admission covers repeated recovery hashes" {
    var admitted: usize = 0;
    try admitTransactionRecoveryHashWork(
        &admitted,
        2,
        2,
        16,
    );
    try std.testing.expectEqual(@as(usize, 12), admitted);
    try std.testing.expectError(
        error.TransactionRecoveryWorkExceeded,
        admitTransactionRecoveryHashWork(
            &admitted,
            2,
            2,
            16,
        ),
    );
}

fn ensureTransactionRecordAdmission(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    owner: Owner,
    expected: []const TransactionExpected,
    writes: []const TransactionWrite,
) !void {
    const bytes = try renderTransactionRecordAlloc(
        allocator,
        transaction_id,
        owner,
        .preparing,
        expected,
        writes,
        &.{},
        std.math.maxInt(u64),
        std.math.maxInt(u64),
        .current,
    );
    defer allocator.free(bytes);
    const digest_after_max_bytes: usize = 7 + 64;
    var digest_growth: usize = 0;
    for (writes) |write| {
        if (write.digest_after.len > digest_after_max_bytes) {
            return error.TransactionCorrupt;
        }
        digest_growth = std.math.add(
            usize,
            digest_growth,
            digest_after_max_bytes - write.digest_after.len,
        ) catch return error.FileTooBig;
    }
    const max_record_bytes = std.math.add(
        usize,
        bytes.len,
        digest_growth,
    ) catch return error.FileTooBig;
    if (max_record_bytes > transaction_record_max_bytes) {
        return error.FileTooBig;
    }
}

test "transaction admission rejects records above the parser bound" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions" },
    );
    defer allocator.free(transactions_dir);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "target.json" },
    );
    defer allocator.free(target_path);
    const session_id = try allocator.alloc(
        u8,
        transaction_record_max_bytes,
    );
    defer allocator.free(session_id);
    @memset(session_id, 's');
    const mutations = [_]TransactionMutation{.{
        .path = target_path,
        .text = "bounded\n",
        .expectation = .{ .expected_exists = false },
        .content_mode = .raw,
        .max_bytes = 4096,
    }};
    try std.testing.expectError(
        error.FileTooBig,
        commitTextTransaction(
            fs,
            allocator,
            transactions_dir,
            &mutations,
            .{
                .owner = .{
                    .process_id = 1,
                    .session_id = session_id,
                    .executor = "test",
                },
            },
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countPendingTransactions(
            fs,
            allocator,
            transactions_dir,
        ),
    );
    try std.testing.expect(!fileExists(fs, target_path));
}

pub fn commitTextTransaction(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    mutations: []const TransactionMutation,
    options: AcquireOptions,
) !CommitTransactionReceipt {
    const result = try commitTextTransactionControlled(
        fs,
        allocator,
        transactions_dir,
        mutations,
        options,
        .{},
    );
    return result.transaction;
}

pub const TransactionTargetUsage = struct {
    path: []const u8,
    before_bytes: u64,
    after_bytes: u64,
    digest_after: []const u8,
    write: bool,
};

pub const TransactionPublicationView = struct {
    transaction_id: []const u8,
    transaction_dir: []const u8,
    intent_digest: [32]u8,
    root_identity: filesystem.OpenDirectoryIdentity,
    transaction_root_identity: ?filesystem.OpenDirectoryIdentity = null,
    before_bytes: ?u64 = null,
    after_bytes: ?u64 = null,
    preparing_record: ?[]const u8 = null,
    targets: []const TransactionTargetUsage = &.{},
};

pub const TransactionTerminal = struct {
    view: TransactionPublicationView,
    state: enum { committed, aborted },
    usage: union(enum) { observed: u64, committed_intent },
    metadata_bytes: u64,
};

pub const TransactionPreparation = struct {
    record: []const u8,
    root_identity: filesystem.OpenDirectoryIdentity,
    intent_digest: [32]u8,
};

pub const TransactionPublicationHooks = struct {
    context: *anyopaque,
    bind: *const fn (*anyopaque, TransactionPublicationView) anyerror![]const u8,
    acquire: *const fn (*anyopaque, TransactionPublicationView) anyerror!void,
    settled: *const fn (*anyopaque, TransactionTerminal) anyerror!void,
    release: *const fn (*anyopaque) void,
    expected_pin: ?[]const u8 = null,
    preparation: ?TransactionPreparation = null,
};

pub const TransactionCommitControls = struct {
    publication: ?TransactionPublicationHooks = null,
    custody: ?*const TransactionPublicationCustody = null,
    wait_for_compatibility_locks: bool = true,
    private_outputs: bool = false,
};

pub const ControlledTransactionReceipt = struct {
    transaction: CommitTransactionReceipt,
    semantic: enum { committed, aborted, recovery_required },
    failure: ?anyerror = null,
    accounting_error: ?anyerror = null,
    reused: bool = false,
};

pub const reservation_pin_leaf = "reservation-pin.json";
pub const reservation_pin_max_bytes: usize = 4096;
const transaction_commit_marker_max_bytes = 2048;
const ordinary_commit_marker = "{\"commit_marker\":\"DTX-v1\",\"state\":\"committed\"}\n";
const reserved_committed_result = "reserved_committed";
pub const reserved_transaction_metadata_max_bytes: usize =
    transaction_record_max_bytes + reservation_pin_max_bytes + transaction_commit_marker_max_bytes;

pub fn commitTextTransactionControlled(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    mutations: []const TransactionMutation,
    options: AcquireOptions,
    controls: TransactionCommitControls,
) !ControlledTransactionReceipt {
    if (controls.custody) |custody| try custody.validate(fs, transactions_dir);
    try admitTransactionTargets(fs, allocator, transactions_dir, mutations);
    var commit: TransactionCommit = .{
        .fs = fs,
        .allocator = allocator,
        .transactions_dir = transactions_dir,
        .options = options,
        .controls = controls,
    };
    defer commit.deinit();
    try commit.prepare(mutations);
    try commit.prepareRows();
    if (controls.publication) |hooks| {
        try commit.sealIntendedWrites();
        try commit.preparePublicationUsage();
        commit.preparing_record = try commit.renderPreparingRecord();
        commit.publication_pin = try hooks.bind(hooks.context, try commit.publicationView());
        if (commit.publication_pin.?.len > reservation_pin_max_bytes) return error.FileTooBig;
    }
    const accounting_error = commit.realize() catch |err| {
        if (controls.publication == null) return err;
        var receipt = commit.takeReceipt();
        receipt.state = .recovery_required;
        return .{ .transaction = receipt, .semantic = .recovery_required, .failure = err };
    };
    return .{
        .transaction = commit.takeReceipt(),
        .semantic = .committed,
        .accounting_error = accounting_error,
    };
}

fn admitTransactionTargets(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    mutations: []const TransactionMutation,
) !void {
    if (mutations.len == 0) return error.InvalidPath;
    if (mutations.len > transaction_recovery_max_rows) return error.TooManyFiles;
    for (mutations) |mutation| try rejectCasControlTargetPath(mutation.path);
    try ensureDirectoryPathNoSymlinks(fs, transactions_dir);
    for (mutations) |mutation| {
        if (try pathIsWithinDirectory(fs, allocator, transactions_dir, mutation.path)) {
            return error.InvalidPath;
        }
    }
}

/// Owns temporary resources for one commit. Persistent journal custody begins
/// only after persistPreparingRecord succeeds; subsequent failures leave that
/// journal and its staged files available to the existing recovery protocol.
const TransactionCommit = struct {
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    options: AcquireOptions,
    controls: TransactionCommitControls = .{},
    publication_pin: ?[]const u8 = null,
    sealed_intent: ?[32]u8 = null,
    preparing_record: ?[]u8 = null,
    publication_usage: []TransactionTargetUsage = &.{},
    ordered: []TransactionMutation = &.{},
    transaction_id: []const u8 = &.{},
    transaction_dir: []const u8 = &.{},
    record_path: []const u8 = &.{},
    commit_marker_path: []const u8 = &.{},
    targets: []TransactionTarget = &.{},
    target_count: usize = 0,
    advisory_locks: []std.Io.File = &.{},
    advisory_lock_count: usize = 0,
    now_ms: u64 = 0,
    expected: []TransactionExpected = &.{},
    expected_count: usize = 0,
    writes: []TransactionWrite = &.{},
    write_count: usize = 0,
    before_exists: []bool = &.{},
    before_sizes: []usize = &.{},
    recovery_hash_admission: usize = 0,
    recovery_hash_check_only: usize = 0,
    record_persisted: bool = false,
    stage_dir: ?std.Io.Dir = null,
    cas_locks: []LockFile = &.{},
    cas_lock_count: usize = 0,
    staged_files: []StagedTransactionFile = &.{},
    staged_file_count: usize = 0,

    fn realize(self: *TransactionCommit) !?anyerror {
        try self.persistPreparingRecord();
        try self.acquireCompatibilityLocks();
        try self.stageWrites();
        if (self.sealed_intent) |sealed| {
            const actual = try self.publicationView();
            if (!std.mem.eql(u8, &sealed, &actual.intent_digest)) return error.TransactionCorrupt;
        }
        try self.writeRecord(.prepared);
        if (self.controls.publication) |hooks| {
            try self.validatePublication();
            try hooks.acquire(hooks.context, try self.publicationView());
        }
        defer if (self.controls.publication) |hooks| hooks.release(hooks.context);
        try self.publishWrites();
        try self.writeRecord(.committed);
        try writeTransactionCommitMarker(
            self.fs,
            self.allocator,
            self.transaction_dir,
            self.commit_marker_path,
            self.publication_pin,
        );
        try syncDirectoryPath(self.fs, self.transaction_dir);
        if (self.controls.publication) |hooks| {
            const terminal = measureTransactionTerminal(
                self.fs,
                self.allocator,
                self.transaction_dir,
                self.publication_pin.?,
                .committed,
            ) catch |err| return @as(?anyerror, err);
            hooks.settled(hooks.context, terminal) catch |err| return @as(?anyerror, err);
        }
        return null;
    }

    fn preparePublicationUsage(self: *TransactionCommit) !void {
        self.publication_usage = try self.allocator.alloc(TransactionTargetUsage, self.ordered.len);
        var write_index: usize = 0;
        for (self.ordered, self.before_sizes, 0..) |mutation, before, index| {
            const write = mutation.action != .check_only;
            self.publication_usage[index] = .{
                .path = self.expected[index].path,
                .before_bytes = before,
                .after_bytes = if (write) try transactionAfterSize(mutation, before) else before,
                .digest_after = if (write)
                    self.writes[write_index].digest_after
                else
                    self.expected[index].digest,
                .write = write,
            };
            write_index += @intFromBool(write);
        }
        if (write_index != self.write_count) return error.TransactionCorrupt;
    }

    fn sealIntendedWrites(self: *TransactionCommit) !void {
        var index: usize = 0;
        for (self.ordered) |mutation| {
            if (mutation.action == .check_only) continue;
            const digest = if (mutation.action == .append)
                try self.allocator.dupe(u8, mutation.expected_digest_after orelse
                    return error.TransactionCorrupt)
            else
                try digestBytesAlloc(self.allocator, mutation.text);
            self.allocator.free(self.writes[index].digest_after);
            self.writes[index].digest_after = digest;
            index += 1;
        }
        self.sealed_intent = (try self.publicationView()).intent_digest;
    }

    fn publicationView(self: *TransactionCommit) !TransactionPublicationView {
        const expected = self.expected[0..self.expected_count];
        const writes = self.writes[0..self.write_count];
        var before_bytes: u64 = 0;
        var after_bytes: u64 = 0;
        for (self.ordered, self.before_sizes) |mutation, before| {
            if (mutation.action == .check_only) continue;
            before_bytes = try std.math.add(u64, before_bytes, before);
            after_bytes = try std.math.add(
                u64,
                after_bytes,
                try transactionAfterSize(mutation, before),
            );
        }
        return .{
            .transaction_id = self.transaction_id,
            .transaction_dir = self.transaction_dir,
            .intent_digest = try transactionIntentDigest(
                self.allocator,
                self.transaction_id,
                self.options.owner,
                expected,
                writes,
            ),
            .root_identity = try transactionRootIdentity(self.fs, self.transaction_dir),
            .transaction_root_identity = try transactionDirectoryIdentity(
                self.fs,
                self.transactions_dir,
            ),
            .before_bytes = before_bytes,
            .after_bytes = after_bytes,
            .preparing_record = self.preparing_record,
            .targets = self.publication_usage,
        };
    }

    fn validatePublication(self: *TransactionCommit) !void {
        var index: usize = 0;
        for (self.ordered, self.targets, 0..) |mutation, *target, target_index| {
            try validateTransactionExpectationAt(
                self.fs,
                self.allocator,
                mutation,
                transactionMutationExpectation(mutation),
                target,
            );
            if (mutation.action == .check_only) continue;
            const staged_stat = try verifyStagedTransactionIdentity(
                self.fs,
                self.writes[index],
                mutation.max_bytes,
                &self.stage_dir.?,
                &self.staged_files[index],
                target_index,
            );
            if (staged_stat.size != self.publication_usage[target_index].after_bytes) {
                return error.TransactionCorrupt;
            }
            index += 1;
        }
    }

    fn deinit(self: *TransactionCommit) void {
        const fs = self.fs;
        if (self.stage_dir) |*stage_dir| {
            for (self.staged_files[0..self.staged_file_count]) |*staged| {
                staged.deinit(stage_dir, self.record_persisted);
            }
        }
        self.allocator.free(self.publication_usage);
        if (self.preparing_record) |bytes| self.allocator.free(bytes);
        self.allocator.free(self.staged_files);
        for (self.cas_locks[0..self.cas_lock_count]) |*lock| lock.release(self.allocator);
        self.allocator.free(self.cas_locks);
        if (self.stage_dir) |dir| dir.close(fs.io);
        self.allocator.free(self.before_sizes);
        self.allocator.free(self.before_exists);
        freeTransactionWriteRows(self.allocator, self.writes[0..self.write_count]);
        self.allocator.free(self.writes);
        freeTransactionExpectedRows(self.allocator, self.expected[0..self.expected_count]);
        self.allocator.free(self.expected);
        for (self.advisory_locks[0..self.advisory_lock_count]) |file| file.close(fs.io);
        self.allocator.free(self.advisory_locks);
        for (self.targets[0..self.target_count]) |*target| target.deinit();
        self.allocator.free(self.targets);
        self.allocator.free(self.commit_marker_path);
        self.allocator.free(self.record_path);
        self.allocator.free(self.transaction_dir);
        self.allocator.free(self.transaction_id);
        self.allocator.free(self.ordered);
        self.* = undefined;
    }

    fn prepare(self: *TransactionCommit, mutations: []const TransactionMutation) !void {
        const fs = self.fs;
        const allocator = self.allocator;
        const control_root = std.fs.path.dirname(self.transactions_dir) orelse
            return error.InvalidPath;
        self.ordered = try normalizeTransactionMutations(
            fs,
            allocator,
            mutations,
            self.options.reject_symlinks,
        );
        self.transaction_id = try transactionIdAlloc(fs, allocator);
        self.transaction_dir = try std.fs.path.join(
            allocator,
            &.{ self.transactions_dir, self.transaction_id },
        );
        self.record_path = try std.fs.path.join(
            allocator,
            &.{ self.transaction_dir, "transaction.json" },
        );
        self.commit_marker_path = try std.fs.path.join(
            allocator,
            &.{ self.transaction_dir, "commit.json" },
        );
        try self.prepareTargetCustody(control_root);
        self.now_ms = clockMillis(fs, .real);
        self.expected = try allocator.alloc(TransactionExpected, self.ordered.len);
        self.writes = try allocator.alloc(TransactionWrite, self.ordered.len);
        self.before_exists = try allocator.alloc(bool, self.ordered.len);
        self.before_sizes = try allocator.alloc(usize, self.ordered.len);
    }

    fn prepareTargetCustody(self: *TransactionCommit, control_root: []const u8) !void {
        const fs = self.fs;
        self.targets = try self.allocator.alloc(TransactionTarget, self.ordered.len);
        for (self.ordered) |mutation| {
            const parent = std.fs.path.dirname(mutation.path) orelse return error.InvalidPath;
            try ensureDirectoryPathNoSymlinks(fs, parent);
            self.targets[self.target_count] = try TransactionTarget.init(
                fs,
                control_root,
                mutation.path,
            );
            self.target_count += 1;
        }
        self.advisory_locks = try self.allocator.alloc(std.Io.File, self.ordered.len);
        for (self.ordered) |mutation| {
            self.advisory_locks[self.advisory_lock_count] = try acquireCasAdvisoryLock(
                fs,
                self.allocator,
                mutation.path,
            );
            self.advisory_lock_count += 1;
        }
    }

    fn prepareRows(self: *TransactionCommit) !void {
        for (self.ordered, self.targets, 0..) |mutation, *target, index| {
            try self.prepareMutation(mutation, target, index);
        }
        if (self.write_count != 0) {
            try addTransactionRecoveryHashAdmission(
                &self.recovery_hash_admission,
                self.recovery_hash_check_only,
                transaction_recovery_hash_max_bytes,
            );
        }
        try ensureTransactionRecordAdmission(
            self.allocator,
            self.transaction_id,
            self.options.owner,
            self.expected[0..self.expected_count],
            self.writes[0..self.write_count],
        );
    }

    fn prepareMutation(
        self: *TransactionCommit,
        mutation: TransactionMutation,
        target: *TransactionTarget,
        index: usize,
    ) !void {
        const fs = self.fs;
        try target.verifyPathIdentity();
        try rejectHardlinkedTargetAt(fs, &target.dir, target.base);
        const append_fast_path = mutation.action == .append and mutation.content_mode == .raw;
        const before = if (append_fast_path) null else readTransactionSnapshotAt(
            fs,
            self.allocator,
            &target.dir,
            target.base,
            mutation,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (before) |snapshot| snapshot.deinit(self.allocator);
        const size = if (append_fast_path) try transactionTargetSizeAt(
            fs,
            &target.dir,
            target.base,
            mutation.max_bytes,
        ) else if (before) |snapshot| snapshot.byte_len else null;
        self.before_exists[index] = size != null;
        self.before_sizes[index] = size orelse 0;
        self.expected[self.expected_count] = try transactionExpectedRowAlloc(
            self.allocator,
            mutation,
            before,
            self.before_exists[index],
            append_fast_path,
        );
        self.expected_count += 1;
        if (mutation.action == .check_only) {
            self.recovery_hash_check_only = std.math.add(
                usize,
                self.recovery_hash_check_only,
                self.before_sizes[index],
            ) catch return error.TransactionRecoveryWorkExceeded;
            return;
        }
        self.writes[self.write_count] = try transactionWriteRowAlloc(
            self.allocator,
            self.transaction_id,
            self.write_count,
            mutation,
            target.base,
        );
        self.write_count += 1;
        try admitTransactionRecoveryHashWork(
            &self.recovery_hash_admission,
            self.before_sizes[index],
            try transactionAfterSize(mutation, self.before_sizes[index]),
            transaction_recovery_hash_max_bytes,
        );
    }

    fn renderPreparingRecord(self: *TransactionCommit) ![]u8 {
        const bytes = try renderTransactionRecordAlloc(
            self.allocator,
            self.transaction_id,
            self.options.owner,
            .preparing,
            self.expected[0..self.expected_count],
            self.writes[0..self.write_count],
            &.{},
            self.now_ms,
            self.now_ms,
            .current,
        );
        errdefer self.allocator.free(bytes);
        if (bytes.len > transaction_record_max_bytes) return error.FileTooBig;
        return bytes;
    }

    fn persistPreparingRecord(self: *TransactionCommit) !void {
        const fs = self.fs;
        if (self.controls.custody) |custody| try custody.validate(fs, self.transactions_dir);
        const journal_lock = if (self.controls.custody == null) try acquireTransactionJournalLock(
            fs,
            self.allocator,
            self.transactions_dir,
            null,
        ) else null;
        defer if (journal_lock) |lock| lock.close(fs.io);
        errdefer if (!self.record_persisted) {
            fs.directory().deleteTree(fs.io, self.transaction_dir) catch |err| {
                fs_authority.warn(fs.io, "journal rollback failed for {s}: {s}; run recovery", .{
                    self.transaction_dir, @errorName(err),
                });
            };
            syncDirectoryPath(fs, self.transactions_dir) catch |err| {
                fs_authority.warn(
                    fs.io,
                    "journal rollback sync failed for {s}: {s}; run recovery",
                    .{
                        self.transactions_dir, @errorName(err),
                    },
                );
            };
        };
        try ensureDirectoryPathNoSymlinks(fs, self.transaction_dir);
        if (self.publication_pin) |pin| {
            const pin_path = try std.fs.path.join(
                self.allocator,
                &.{ self.transaction_dir, reservation_pin_leaf },
            );
            defer self.allocator.free(pin_path);
            try writeTextCreateNew(fs, self.allocator, pin_path, pin, .{});
        }
        if (self.preparing_record) |bytes| {
            try writeTextCreateNew(fs, self.allocator, self.record_path, bytes, .{});
        } else try writeCurrentTransactionRecord(
            fs,
            self.allocator,
            self.record_path,
            self.transaction_id,
            self.options.owner,
            .preparing,
            self.expected[0..self.expected_count],
            self.writes[0..self.write_count],
            &.{},
            self.now_ms,
            clockMillis(fs, .real),
            true,
        );
        try syncDirectoryPath(fs, self.transaction_dir);
        try syncDirectoryPath(fs, self.transactions_dir);
        self.record_persisted = true;
    }

    fn acquireCompatibilityLocks(self: *TransactionCommit) !void {
        const fs = self.fs;
        self.stage_dir = if (std.fs.path.isAbsolute(self.transaction_dir))
            try std.Io.Dir.openDirAbsolute(fs.io, self.transaction_dir, .{
                .follow_symlinks = false,
            })
        else
            try fs.directory().openDir(fs.io, self.transaction_dir, .{
                .follow_symlinks = false,
            });
        self.cas_locks = try self.allocator.alloc(LockFile, self.ordered.len);
        for (self.ordered) |mutation| {
            const path = try casLockPathAlloc(self.allocator, mutation.path);
            defer self.allocator.free(path);
            self.cas_locks[self.cas_lock_count] = if (self.controls.wait_for_compatibility_locks)
                try acquireExclusiveLockPathRetry(fs, self.allocator, path, 5000, 2)
            else
                try acquireExclusiveLockPath(fs, self.allocator, path);
            self.cas_lock_count += 1;
        }
        for (self.ordered, self.targets) |mutation, *target| {
            try validateTransactionExpectationAt(
                fs,
                self.allocator,
                mutation,
                transactionMutationExpectation(mutation),
                target,
            );
        }
    }

    fn stageWrites(self: *TransactionCommit) !void {
        self.staged_files = try self.allocator.alloc(StagedTransactionFile, self.ordered.len);
        var write_index: usize = 0;
        for (self.ordered, self.targets, 0..) |mutation, *target, index| {
            if (mutation.action == .check_only) continue;
            try self.stageWrite(mutation, target, index, write_index);
            write_index += 1;
        }
        std.debug.assert(write_index == self.write_count);
    }

    fn stageWrite(
        self: *TransactionCommit,
        mutation: TransactionMutation,
        target: *TransactionTarget,
        index: usize,
        write_index: usize,
    ) !void {
        const fs = self.fs;
        const write = &self.writes[write_index];
        self.staged_files[self.staged_file_count] = try createStagedTransactionFile(
            fs,
            &self.stage_dir.?,
            write.staged_ref,
            index,
        );
        const staged = &self.staged_files[self.staged_file_count];
        self.staged_file_count += 1;
        if (self.controls.private_outputs) try staged.file.setPermissions(fs.io, .fromMode(0o600));
        const digest = try stageTransactionMutation(
            fs,
            self.allocator,
            staged,
            mutation,
            target,
            self.before_exists[index],
        );
        errdefer self.allocator.free(digest);
        try syncDirectoryHandle(fs, &self.stage_dir.?);
        if (mutation.expected_digest_after) |expected| {
            if (!std.mem.eql(u8, digest, expected)) return error.DigestMismatch;
        }
        self.allocator.free(write.digest_after);
        write.digest_after = digest;
    }

    fn writeRecord(self: *TransactionCommit, state: TransactionState) !void {
        const fs = self.fs;
        try writeCurrentTransactionRecord(
            fs,
            self.allocator,
            self.record_path,
            self.transaction_id,
            self.options.owner,
            state,
            self.expected[0..self.expected_count],
            self.writes[0..self.write_count],
            &.{},
            self.now_ms,
            clockMillis(fs, .real),
            false,
        );
        try syncDirectoryPath(fs, self.transaction_dir);
    }

    fn publishWrites(self: *TransactionCommit) !void {
        const fs = self.fs;
        var index: usize = 0;
        for (self.ordered, self.targets, 0..) |mutation, *target, target_index| {
            if (mutation.action == .check_only) continue;
            try publishStagedTransactionWrite(
                fs,
                self.allocator,
                self.writes[index],
                mutation,
                transactionMutationExpectation(mutation),
                target,
                &self.stage_dir.?,
                &self.staged_files[index],
                target_index,
                self.controls.publication != null,
            );
            index += 1;
        }
        std.debug.assert(index == self.write_count);
        try syncDirectoryHandle(fs, &self.stage_dir.?);
    }

    fn takeReceipt(self: *TransactionCommit) CommitTransactionReceipt {
        const receipt: CommitTransactionReceipt = .{
            .transaction_id = self.transaction_id,
            .transaction_dir = self.transaction_dir,
            .record_path = self.record_path,
            .commit_marker_path = self.commit_marker_path,
            .state = .committed,
        };
        self.transaction_id = &.{};
        self.transaction_dir = &.{};
        self.record_path = &.{};
        self.commit_marker_path = &.{};
        return receipt;
    }
};

fn transactionMutationExpectation(mutation: TransactionMutation) CasExpectation {
    var expectation = mutation.expectation;
    if (mutation.content_mode == .raw and expectation.expected_sequence == 0) {
        expectation.expected_sequence = null;
    }
    return expectation;
}

fn transactionExpectedRowAlloc(
    allocator: std.mem.Allocator,
    mutation: TransactionMutation,
    before: ?TransactionSnapshot,
    before_exists: bool,
    append_fast_path: bool,
) !TransactionExpected {
    var digest: []const u8 = "";
    var sequence: u64 = 0;
    if (append_fast_path) {
        if (mutation.expectation.expected_exists) |expected| {
            if (expected != before_exists) return error.ExpectationMismatch;
        }
        if (before_exists != (mutation.expectation.expected_digest != null)) {
            return error.DigestMismatch;
        }
        digest = mutation.expectation.expected_digest orelse "";
    } else if (before) |snapshot| {
        if (mutation.expectation.expected_digest) |expected| {
            if (!std.mem.eql(u8, expected, snapshot.digest)) return error.DigestMismatch;
        }
        if (mutation.expectation.expected_exists) |expected| {
            if (!expected) return error.ExpectationMismatch;
        }
        digest = snapshot.digest;
        sequence = switch (mutation.content_mode) {
            .jsonl_sequence_required => snapshot.sequence orelse return error.SequenceMismatch,
            .raw => 0,
        };
    } else {
        if (mutation.expectation.expected_exists) |expected| {
            if (expected) return error.ExpectationMismatch;
        }
        if (mutation.expectation.expected_digest != null) return error.DigestMismatch;
        if (mutation.expectation.expected_sequence) |expected| {
            if (expected != 0) return error.SequenceMismatch;
        }
    }
    const path = try allocator.dupe(u8, mutation.path);
    errdefer allocator.free(path);
    const digest_owned = try allocator.dupe(u8, digest);
    return .{ .path = path, .digest = digest_owned, .sequence = sequence };
}

fn transactionWriteRowAlloc(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    write_index: usize,
    mutation: TransactionMutation,
    target_base: []const u8,
) !TransactionWrite {
    if (mutation.text.len > mutation.max_bytes) return error.FileTooBig;
    if (mutation.content_mode == .jsonl_sequence_required) {
        const validation = try validateJsonlBytes(allocator, mutation.text);
        if (!validation.ok()) return error.InvalidJsonl;
    }
    const staged_ref = try transactionStageNameAlloc(allocator, transaction_id, write_index);
    errdefer allocator.free(staged_ref);
    if (std.mem.eql(u8, target_base, staged_ref)) return error.TransactionCorrupt;
    const sequence = switch (mutation.content_mode) {
        .jsonl_sequence_required => (try jsonlSequenceRequired(
            allocator,
            mutation.text,
        )) orelse return error.SequenceMismatch,
        .raw => 0,
    };
    const path = try allocator.dupe(u8, mutation.path);
    errdefer allocator.free(path);
    const digest = try allocator.dupe(u8, "");
    return .{
        .path = path,
        .staged_ref = staged_ref,
        .digest_after = digest,
        .sequence_after = sequence,
    };
}

fn transactionAfterSize(mutation: TransactionMutation, before_size: usize) !usize {
    return switch (mutation.action) {
        .write => mutation.text.len,
        .append => size: {
            const size = std.math.add(usize, before_size, mutation.text.len) catch
                return error.FileTooBig;
            if (size > mutation.max_bytes) return error.FileTooBig;
            break :size size;
        },
        .check_only => unreachable,
    };
}

fn stageTransactionMutation(
    fs: Fs,
    allocator: std.mem.Allocator,
    staged: *StagedTransactionFile,
    mutation: TransactionMutation,
    target: *TransactionTarget,
    before_exists: bool,
) ![]u8 {
    switch (mutation.action) {
        .write => {
            try staged.file.writeStreamingAll(fs.io, mutation.text);
            try staged.file.sync(fs.io);
            return digestBytesAlloc(allocator, mutation.text);
        },
        .append => {
            if (mutation.content_mode != .raw or mutation.expected_digest_after == null) {
                return error.TransactionCorrupt;
            }
            return stageAppendedTransactionWrite(
                fs,
                allocator,
                &staged.file,
                target,
                before_exists,
                mutation.expectation.expected_digest,
                mutation.text,
                mutation.max_bytes,
            );
        },
        .check_only => unreachable,
    }
}

fn stageAppendedTransactionWrite(
    fs: Fs,
    allocator: std.mem.Allocator,
    staged: *std.Io.File,
    target: *TransactionTarget,
    before_exists: bool,
    expected_before_digest: ?[]const u8,
    suffix: []const u8,
    max_bytes: usize,
) ![]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var copied: usize = 0;
    if (before_exists) {
        var source = try target.dir.openFile(fs.io, target.base, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
        defer source.close(fs.io);
        var reader = source.reader(fs.io, &.{});
        var buffer: [jsonl_core.chunk_size]u8 = undefined;
        while (copied <= max_bytes) {
            const count = try reader.interface.readSliceShort(&buffer);
            if (count == 0) break;
            copied = std.math.add(usize, copied, count) catch
                return error.FileTooBig;
            if (copied > max_bytes) return error.FileTooBig;
            try staged.writeStreamingAll(fs.io, buffer[0..count]);
            hash.update(buffer[0..count]);
        }
        var prefix_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
            undefined;
        var prefix_hash = hash;
        prefix_hash.final(&prefix_digest);
        const prefix_hex = std.fmt.bytesToHex(prefix_digest, .lower);
        var formatted: [71]u8 = undefined;
        @memcpy(formatted[0..7], "sha256:");
        @memcpy(formatted[7..], &prefix_hex);
        if (!std.mem.eql(
            u8,
            &formatted,
            expected_before_digest orelse return error.DigestMismatch,
        )) return error.DigestMismatch;
    } else if (expected_before_digest != null) {
        return error.DigestMismatch;
    }
    const total = std.math.add(usize, copied, suffix.len) catch
        return error.FileTooBig;
    if (total > max_bytes) return error.FileTooBig;
    try staged.writeStreamingAll(fs.io, suffix);
    hash.update(suffix);
    try staged.sync(fs.io);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.print("sha256:{s}", .{&hex});
}

fn transactionTargetSizeAt(
    fs: Fs,
    dir: *std.Io.Dir,
    base: []const u8,
    max_bytes: usize,
) !?usize {
    const stat = dir.statFile(
        fs.io,
        base,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.nlink > 1) return error.HardlinkTarget;
    if (stat.size > max_bytes) return error.FileTooBig;
    return std.math.cast(usize, stat.size) orelse error.FileTooBig;
}

const StagedTransactionFile = struct {
    fs: Fs,
    file: std.Io.File,
    staged_ref: []const u8,
    target_index: usize,
    file_open: bool = true,
    file_exists: bool = true,

    fn deinit(
        self: *StagedTransactionFile,
        stage_dir: *std.Io.Dir,
        journal_owns_file: bool,
    ) void {
        const fs = self.fs;
        if (self.file_open) {
            self.file.close(fs.io);
            self.file_open = false;
        }
        if (self.file_exists and !journal_owns_file) {
            deleteFileAfterFailure(fs, stage_dir.*, self.staged_ref);
        }
        self.file_exists = false;
    }
};

fn createStagedTransactionFile(
    fs: Fs,
    stage_dir: *std.Io.Dir,
    staged_ref: []const u8,
    target_index: usize,
) !StagedTransactionFile {
    return .{
        .fs = fs,
        .file = try stage_dir.createFile(fs.io, staged_ref, .{
            .exclusive = true,
            .read = true,
            .truncate = false,
        }),
        .staged_ref = staged_ref,
        .target_index = target_index,
    };
}

fn publishVerifiedStagedFile(
    fs: Fs,
    staged_dir: *std.Io.Dir,
    staged_ref: []const u8,
    expected_digest: []const u8,
    max_bytes: usize,
    target: *TransactionTarget,
) !usize {
    const entry = try staged_dir.statFile(
        fs.io,
        staged_ref,
        .{ .follow_symlinks = false },
    );
    if (entry.kind == .sym_link) return error.SymlinkComponent;
    if (entry.kind != .file) return error.NotFile;
    if (entry.nlink != 1) return error.HardlinkTarget;
    if (entry.size > max_bytes) return error.FileTooBig;

    var source = try staged_dir.openFile(fs.io, staged_ref, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer source.close(fs.io);
    const opened = try source.stat(fs.io);
    if (opened.kind != .file or opened.nlink != 1) {
        return error.HardlinkTarget;
    }
    if (opened.inode != entry.inode) return error.TransactionCorrupt;

    var destination = try target.dir.createFileAtomic(
        fs.io,
        target.base,
        .{ .replace = true },
    );
    defer destination.deinit(fs.io);
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) {
        try destination.file.setPermissions(fs.io, .fromMode(opened.permissions.toMode() & 0o777));
    }
    var copied = try copyStagedFileAndHash(fs, source, destination.file, max_bytes);
    const observed = copied.bytes;
    const final_source = try source.stat(fs.io);
    if (final_source.kind != .file or final_source.nlink != 1) {
        return error.HardlinkTarget;
    }
    if (final_source.inode != opened.inode or
        final_source.size != observed)
    {
        return error.TransactionCorrupt;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    copied.hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    var formatted: [71]u8 = undefined;
    @memcpy(formatted[0..7], "sha256:");
    @memcpy(formatted[7..], &hex);
    if (!std.mem.eql(u8, &formatted, expected_digest)) {
        return error.TransactionCorrupt;
    }
    try destination.file.sync(fs.io);
    try destination.replace(fs.io);
    return observed;
}

const StagedFileCopy = struct {
    bytes: usize,
    hash: std.crypto.hash.sha2.Sha256,
};

fn copyStagedFileAndHash(
    fs: Fs,
    source: std.Io.File,
    destination: std.Io.File,
    max_bytes: usize,
) !StagedFileCopy {
    var reader = source.reader(fs.io, &.{});
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var observed: usize = 0;
    var buffer: [jsonl_core.chunk_size]u8 = undefined;
    while (observed <= max_bytes) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        observed = std.math.add(usize, observed, count) catch
            return error.FileTooBig;
        if (observed > max_bytes) return error.FileTooBig;
        try destination.writeStreamingAll(
            fs.io,
            buffer[0..count],
        );
        hasher.update(buffer[0..count]);
    }
    return .{ .bytes = observed, .hash = hasher };
}

fn publishVerifiedRecoveryStagedFile(
    fs: Fs,
    staged_dir: *std.Io.Dir,
    staged_ref: []const u8,
    expected_digest: []const u8,
    target: *TransactionTarget,
    hash_bytes_remaining: *usize,
) !void {
    const stat = try staged_dir.statFile(
        fs.io,
        staged_ref,
        .{ .follow_symlinks = false },
    );
    const size = std.math.cast(usize, stat.size) orelse
        return error.TransactionRecoveryWorkExceeded;
    if (size > transaction_recovery_max_bytes or
        size > hash_bytes_remaining.*)
    {
        return error.TransactionRecoveryWorkExceeded;
    }
    const observed = publishVerifiedStagedFile(
        fs,
        staged_dir,
        staged_ref,
        expected_digest,
        @min(transaction_recovery_max_bytes, hash_bytes_remaining.*),
        target,
    ) catch |err| switch (err) {
        error.FileTooBig => return error.TransactionRecoveryWorkExceeded,
        else => return err,
    };
    hash_bytes_remaining.* -= observed;
}

fn publishStagedTransactionWrite(
    fs: Fs,
    allocator: std.mem.Allocator,
    write: TransactionWrite,
    mutation: TransactionMutation,
    expectation: CasExpectation,
    target: *TransactionTarget,
    stage_dir: *std.Io.Dir,
    staged: *StagedTransactionFile,
    target_index: usize,
    already_validated: bool,
) !void {
    if (!already_validated) {
        const sequence_after = switch (mutation.content_mode) {
            .jsonl_sequence_required => (try jsonlSequenceRequired(
                allocator,
                mutation.text,
            )) orelse return error.SequenceMismatch,
            .raw => 0,
        };
        if (sequence_after != write.sequence_after) return error.TransactionCorrupt;
    }
    try target.verifyPathIdentity();
    if (!already_validated) try validateTransactionExpectationAt(
        fs,
        allocator,
        mutation,
        expectation,
        target,
    );
    const opened = try verifyStagedTransactionIdentity(
        fs,
        write,
        mutation.max_bytes,
        stage_dir,
        staged,
        target_index,
    );
    staged.file.close(fs.io);
    staged.file_open = false;
    try stage_dir.rename(
        write.staged_ref,
        target.dir,
        target.base,
        fs.io,
    );
    staged.file_exists = false;
    try syncDirectoryHandle(fs, &target.dir);
    try target.verifyPathIdentity();
    const published = try target.dir.statFile(
        fs.io,
        target.base,
        .{ .follow_symlinks = false },
    );
    if (published.kind != .file or published.nlink != 1 or
        published.inode != opened.inode or published.size != opened.size)
    {
        return error.TransactionCorrupt;
    }
}

fn verifyStagedTransactionIdentity(
    fs: Fs,
    write: TransactionWrite,
    max_bytes: usize,
    stage_dir: *std.Io.Dir,
    staged: *StagedTransactionFile,
    target_index: usize,
) !std.Io.File.Stat {
    if (!staged.file_open or !staged.file_exists or
        staged.target_index != target_index or
        !std.mem.eql(u8, staged.staged_ref, write.staged_ref))
    {
        return error.TransactionCorrupt;
    }
    const opened = try staged.file.stat(fs.io);
    if (opened.kind != .file or opened.nlink != 1 or
        opened.size > max_bytes)
    {
        return error.TransactionCorrupt;
    }
    const entry = try stage_dir.statFile(
        fs.io,
        write.staged_ref,
        .{ .follow_symlinks = false },
    );
    if (entry.kind != .file or entry.nlink != 1 or
        entry.inode != opened.inode or entry.size != opened.size)
    {
        return error.TransactionCorrupt;
    }
    return opened;
}

fn validateTransactionExpectationAt(
    fs: Fs,
    allocator: std.mem.Allocator,
    mutation: TransactionMutation,
    expectation: CasExpectation,
    target: *TransactionTarget,
) !void {
    const current = readTransactionSnapshotAt(
        fs,
        allocator,
        &target.dir,
        target.base,
        mutation,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (current) |snapshot| snapshot.deinit(allocator);
    if (expectation.expected_exists) |expected_exists| {
        if (expected_exists != (current != null)) {
            return error.ExpectationMismatch;
        }
    }
    if (expectation.expected_digest) |expected_digest| {
        const actual = if (current) |snapshot| snapshot.digest else return error.DigestMismatch;
        if (!std.mem.eql(u8, expected_digest, actual)) {
            return error.DigestMismatch;
        }
    }
    if (expectation.expected_sequence) |expected_sequence| {
        const actual = if (current) |snapshot| snapshot.sequence else return error.SequenceMismatch;
        if (actual == null or actual.? != expected_sequence) {
            return error.SequenceMismatch;
        }
    }
}

fn transactionIdAlloc(fs: Fs, allocator: std.mem.Allocator) ![]u8 {
    var entropy: [16]u8 = undefined;
    try std.Io.randomSecure(fs.io, &entropy);
    const encoded = std.fmt.bytesToHex(entropy, .lower);
    return allocator.print(
        "dtx-{d}-{s}",
        .{ clockMillis(fs, .real), &encoded },
    );
}

fn transactionCommitMarkerPathAlloc(
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) ![]u8 {
    return std.fs.path.join(
        allocator,
        &.{ transaction_dir, "commit.json" },
    );
}

fn writeTransactionCommitMarker(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    path: []const u8,
    pin: ?[]const u8,
) !void {
    if (pin) |bytes| {
        const marker = try renderReservedCommitMarker(fs, allocator, transaction_dir, bytes);
        defer allocator.free(marker);
        return writeTextCreateNew(fs, allocator, path, marker, .{});
    }
    return writeCommittedTransactionMarker(fs, allocator, path);
}

fn renderReservedCommitMarker(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    pin: []const u8,
) ![]u8 {
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const bytes = try readRegularFileNoSymlink(
        fs,
        allocator,
        record_path,
        transaction_record_max_bytes,
    );
    defer allocator.free(bytes);
    const parsed = try parseTransactionRecordBytes(allocator, bytes);
    defer parsed.deinit(allocator);
    return renderReservedCommitMarkerRecord(
        allocator,
        bytes,
        parsed,
        try transactionRootIdentity(
            fs,
            transaction_dir,
        ),
        pin,
    );
}

fn renderReservedCommitMarkerRecord(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    parsed: ParsedTransactionRecord,
    root_identity: filesystem.OpenDirectoryIdentity,
    pin: []const u8,
) ![]u8 {
    if (parsed.state != .committed or try transactionRecordFormat(allocator, parsed) != .current) {
        return error.TransactionReservationMismatch;
    }
    var record_digest: [32]u8 = undefined;
    var pin_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &record_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(pin, &pin_digest, .{});
    const result = try std.json.Stringify.valueAlloc(allocator, .{
        .commit_marker = "DTX-v1",
        .state = "committed",
        .reservation = .{
            .schema = "durable-reserved-commit/v1",
            .record_digest = record_digest,
            .pin_digest = pin_digest,
            .intent_digest = try transactionIntentDigest(
                allocator,
                parsed.transaction_id,
                parsed.owner,
                parsed.expected,
                parsed.writes,
            ),
            .root_identity = root_identity,
        },
    }, .{});
    errdefer allocator.free(result);
    if (result.len > transaction_commit_marker_max_bytes) return error.FileTooBig;
    return result;
}

fn validateReservedCommitMarker(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) !void {
    const pin_path = try std.fs.path.join(allocator, &.{ transaction_dir, reservation_pin_leaf });
    defer allocator.free(pin_path);
    const pin = try readRegularFileNoSymlink(fs, allocator, pin_path, reservation_pin_max_bytes);
    defer allocator.free(pin);
    const expected = try renderReservedCommitMarker(fs, allocator, transaction_dir, pin);
    defer allocator.free(expected);
    const path = try transactionCommitMarkerPathAlloc(allocator, transaction_dir);
    defer allocator.free(path);
    const actual = try readRegularFileNoSymlink(
        fs,
        allocator,
        path,
        transaction_commit_marker_max_bytes,
    );
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, expected)) return error.TransactionReservationMismatch;
}

fn transactionHasReservationEvidence(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) !bool {
    if (try transactionHasReservationPin(fs, allocator, transaction_dir)) return true;
    const path = try transactionCommitMarkerPathAlloc(allocator, transaction_dir);
    defer allocator.free(path);
    const marker = readRegularFileNoSymlink(
        fs,
        allocator,
        path,
        transaction_commit_marker_max_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound, error.FileTooBig => return false,
        else => return err,
    };
    defer allocator.free(marker);
    if (std.mem.eql(u8, marker, ordinary_commit_marker)) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, marker, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
    defer parsed.deinit();
    return parsed.value == .object and parsed.value.object.get("reservation") != null;
}

fn writeCommittedTransactionMarker(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    try writeTextCreateNew(
        fs,
        allocator,
        path,
        "{\"commit_marker\":\"DTX-v1\",\"state\":\"committed\"}\n",
        .{},
    );
}

fn transactionIntentDigest(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    owner: Owner,
    expected: []const TransactionExpected,
    writes: []const TransactionWrite,
) ![32]u8 {
    const bytes = try renderTransactionRecordAlloc(
        allocator,
        transaction_id,
        owner,
        .prepared,
        expected,
        writes,
        &.{},
        0,
        0,
        null,
    );
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

pub const AbortedTransactionWitness = struct {
    root_identity: filesystem.OpenDirectoryIdentity,
    intent_digest: [32]u8,
    pin: []const u8,
    metadata_bytes: u64,
};

const RetirementFile = struct {
    file: std.Io.File,
    stat: std.Io.File.Stat,
};

pub const AbortedTransactionRetirement = struct {
    fs: Fs,
    transaction_dir: []const u8,
    root_identity: filesystem.OpenDirectoryIdentity,
    recovery_lock: std.Io.File,
    journal_lock: std.Io.File,
    parent: std.Io.Dir,
    directory: ?std.Io.Dir = null,
    record: ?RetirementFile = null,
    pin: ?RetirementFile = null,

    pub fn deinit(self: *AbortedTransactionRetirement) void {
        if (self.record) |file| file.file.close(self.fs.io);
        if (self.pin) |file| file.file.close(self.fs.io);
        if (self.directory) |dir| dir.close(self.fs.io);
        self.parent.close(self.fs.io);
        self.journal_lock.close(self.fs.io);
        self.recovery_lock.close(self.fs.io);
        self.* = undefined;
    }

    pub fn finish(self: *AbortedTransactionRetirement) !void {
        try validatePublicationRoot(self.fs, self.transaction_dir, self.root_identity);
        const leaf = std.fs.path.basename(self.transaction_dir);
        if (self.directory) |dir| {
            var current = try self.parent.openDir(self.fs.io, leaf, .{ .follow_symlinks = false });
            defer current.close(self.fs.io);
            if (!std.meta.eql(
                try filesystem.openDirectoryIdentity(self.fs.io, dir),
                try filesystem.openDirectoryIdentity(self.fs.io, current),
            )) return error.TransactionRecoveryRequired;
            try validateRetirementEntries(self.fs.io, dir);
            try self.removeFile(dir, "transaction.json", self.record);
            try self.removeFile(dir, reservation_pin_leaf, self.pin);
            try self.parent.deleteDir(self.fs.io, leaf);
        } else if (try statRegularFileNoSymlink(
            .anchored(self.fs.io, self.parent),
            leaf,
        ) != null) return error.TransactionRecoveryRequired;
        try syncDirectoryHandle(self.fs, &self.parent);
    }

    fn removeFile(
        self: *AbortedTransactionRetirement,
        dir: std.Io.Dir,
        name: []const u8,
        selected: ?RetirementFile,
    ) !void {
        const current = try statRegularFileNoSymlink(.anchored(self.fs.io, dir), name);
        if (selected) |original| {
            const stat = current orelse return error.TransactionRecoveryRequired;
            if (stat.inode != original.stat.inode or stat.size != original.stat.size or
                stat.nlink != 1 or !std.meta.eql(stat.mtime, original.stat.mtime) or
                !std.meta.eql(stat.ctime, original.stat.ctime))
            {
                return error.TransactionRecoveryRequired;
            }
            try dir.deleteFile(self.fs.io, name);
            try syncDirectoryHandle(self.fs, &dir);
        } else if (current != null) return error.TransactionRecoveryRequired;
    }
};

pub fn prepareAbortedTransactionRetirement(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    witness: AbortedTransactionWitness,
) !AbortedTransactionRetirement {
    try validatePublicationRoot(fs, transaction_dir, witness.root_identity);
    const parent_path = std.fs.path.dirname(transaction_dir) orelse return error.InvalidPath;
    const recovery = try acquireTransactionRecoveryLock(fs, allocator, parent_path, null);
    errdefer recovery.close(fs.io);
    const journal = try acquireTransactionJournalLock(fs, allocator, parent_path, null);
    errdefer journal.close(fs.io);
    const parent = try fs.directory().openDir(fs.io, parent_path, .{ .follow_symlinks = false });
    var result: AbortedTransactionRetirement = .{
        .fs = fs,
        .transaction_dir = transaction_dir,
        .root_identity = witness.root_identity,
        .recovery_lock = recovery,
        .journal_lock = journal,
        .parent = parent,
    };
    errdefer {
        if (result.record) |file| file.file.close(fs.io);
        if (result.pin) |file| file.file.close(fs.io);
        if (result.directory) |dir| dir.close(fs.io);
        parent.close(fs.io);
    }
    result.directory = parent.openDir(fs.io, std.fs.path.basename(transaction_dir), .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    const dir = result.directory.?;
    try validateRetirementEntries(fs.io, dir);
    result.record = try openRetirementFile(fs.io, dir, "transaction.json");
    result.pin = try openRetirementFile(fs.io, dir, reservation_pin_leaf);
    if (result.record != null and result.pin == null) return error.TransactionRecoveryRequired;
    if (result.pin) |pin| {
        const bytes = try retirementFileBytes(
            fs.io,
            allocator,
            pin.file,
            reservation_pin_max_bytes,
        );
        defer allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, witness.pin)) return error.TransactionReservationMismatch;
    }
    if (result.record) |record| {
        try validateAbortedRetirementRecord(fs, allocator, transaction_dir, record.file, witness);
        const bytes = try std.math.add(u64, record.stat.size, result.pin.?.stat.size);
        if (bytes != witness.metadata_bytes) return error.TransactionReservationMismatch;
    }
    return result;
}

fn validateRetirementEntries(io: std.Io, directory: std.Io.Dir) !void {
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        count += 1;
        if (count > 2 or entry.kind != .file or
            (!std.mem.eql(u8, entry.name, "transaction.json") and
                !std.mem.eql(u8, entry.name, reservation_pin_leaf)))
        {
            return error.TransactionRecoveryRequired;
        }
    }
}

fn openRetirementFile(io: std.Io, dir: std.Io.Dir, name: []const u8) !?RetirementFile {
    const file = filesystem.openRegularFileNoSymlink(.anchored(io, dir), name) catch |err|
        switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.nlink != 1) return error.TransactionCorrupt;
    return .{ .file = file, .stat = stat };
}

fn retirementFileBytes(
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    max_bytes: usize,
) ![]u8 {
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

fn validateAbortedRetirementRecord(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    file: std.Io.File,
    witness: AbortedTransactionWitness,
) !void {
    const bytes = try retirementFileBytes(fs.io, allocator, file, transaction_record_max_bytes);
    defer allocator.free(bytes);
    const parsed = try parseTransactionRecordBytes(allocator, bytes);
    defer parsed.deinit(allocator);
    if (parsed.state != .aborted or try transactionRecordFormat(allocator, parsed) != .current) {
        return error.TransactionReservationMismatch;
    }
    try validateAutomaticRecoveryRowBounds(parsed);
    try validateTransactionRecordScopeWithMode(
        fs,
        allocator,
        try transactionControlRoot(transaction_dir),
        transaction_dir,
        parsed,
        .current,
        .metadata_only,
    );
    const digest = try transactionIntentDigest(
        allocator,
        parsed.transaction_id,
        parsed.owner,
        parsed.expected,
        parsed.writes,
    );
    if (!std.meta.eql(digest, witness.intent_digest)) return error.TransactionReservationMismatch;
}

pub fn validatePublicationRoot(
    fs: Fs,
    transaction_dir: []const u8,
    expected: filesystem.OpenDirectoryIdentity,
) !void {
    if (!std.fs.path.isAbsolute(transaction_dir) and !fs.isPinned()) return error.NotAbsolute;
    if (!std.meta.eql(expected, try transactionRootIdentity(fs, transaction_dir))) {
        return error.TransactionReservationMismatch;
    }
}

fn transactionRootIdentity(fs: Fs, transaction_dir: []const u8) !filesystem.OpenDirectoryIdentity {
    const root = try transactionControlRoot(transaction_dir);
    return transactionDirectoryIdentity(fs, root);
}

fn transactionDirectoryIdentity(fs: Fs, path: []const u8) !filesystem.OpenDirectoryIdentity {
    var dir = try fs.directory().openDir(fs.io, path, .{ .follow_symlinks = false });
    defer dir.close(fs.io);
    return filesystem.openDirectoryIdentity(fs.io, dir);
}

fn validateReservationPin(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    expected_pin: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ transaction_dir, reservation_pin_leaf });
    defer allocator.free(path);
    const bytes = try readRegularFileNoSymlink(fs, allocator, path, reservation_pin_max_bytes);
    defer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes, expected_pin)) return error.TransactionReservationMismatch;
}

fn transactionHasReservationPin(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) !bool {
    const path = try std.fs.path.join(allocator, &.{ transaction_dir, reservation_pin_leaf });
    defer allocator.free(path);
    return (try statRegularFileNoSymlink(fs, path)) != null;
}

fn measureTransactionTerminal(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    expected_pin: []const u8,
    state: @FieldType(TransactionTerminal, "state"),
) !TransactionTerminal {
    try validateReservationPin(fs, allocator, transaction_dir, expected_pin);
    const path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(path);
    const parsed = try parseTransactionRecord(fs, allocator, path);
    defer parsed.deinit(allocator);
    const required: TransactionState = if (state == .committed) .committed else .aborted;
    if (parsed.state != required) return error.TransactionRecoveryRequired;
    var target_bytes: u64 = 0;
    if (state == .aborted) for (parsed.writes) |write| {
        if (try statRegularFileNoSymlink(fs, write.path)) |stat| {
            target_bytes = try std.math.add(u64, target_bytes, stat.size);
        }
    };
    return .{
        .view = .{
            .transaction_id = std.fs.path.basename(transaction_dir),
            .transaction_dir = transaction_dir,
            .intent_digest = try transactionIntentDigest(
                allocator,
                parsed.transaction_id,
                parsed.owner,
                parsed.expected,
                parsed.writes,
            ),
            .root_identity = try transactionRootIdentity(fs, transaction_dir),
        },
        .state = state,
        .usage = if (state == .committed) .committed_intent else .{ .observed = target_bytes },
        .metadata_bytes = try transactionTerminalMetadataBytes(
            fs,
            allocator,
            transaction_dir,
            state,
        ),
    };
}

fn transactionTerminalMetadataBytes(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    state: @FieldType(TransactionTerminal, "state"),
) !u64 {
    var dir = try fs.directory().openDir(fs.io, transaction_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(fs.io);
    var iter = dir.iterate();
    var total: u64 = 0;
    var count: usize = 0;
    while (try iter.next(fs.io)) |entry| {
        count += 1;
        if (count > 3 or entry.kind != .file) return error.TransactionRecoveryRequired;
        if (!std.mem.eql(u8, entry.name, "transaction.json") and
            !std.mem.eql(u8, entry.name, "commit.json") and
            !std.mem.eql(u8, entry.name, reservation_pin_leaf))
        {
            return error.TransactionRecoveryRequired;
        }
        const stat = try dir.statFile(fs.io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .file or stat.nlink != 1) return error.TransactionCorrupt;
        total = try std.math.add(u64, total, stat.size);
    }
    if (state == .committed) {
        try validateReservedCommitMarker(fs, allocator, transaction_dir);
    } else if (count != 2) return error.TransactionRecoveryRequired;
    return total;
}

pub fn inspectTransaction(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) !RecoveryStatus {
    var hash_bytes_remaining = transaction_recovery_hash_max_bytes;
    return inspectTransactionWithBudget(
        fs,
        allocator,
        transaction_dir,
        &hash_bytes_remaining,
    );
}

pub fn inspectLegacyLeaseRecoveryCandidates(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    authority: LegacyFencingAuthority,
) ![]LegacyLeaseRecoveryCandidate {
    const parsed = try parseValidatedLegacyRecoveryRecord(
        fs,
        allocator,
        transaction_dir,
        authority,
    );
    defer parsed.deinit(allocator);
    var candidates = try allocator.alloc(
        LegacyLeaseRecoveryCandidate,
        parsed.expected.len,
    );
    var count: usize = 0;
    errdefer {
        for (candidates[0..count]) |*candidate| {
            candidate.deinit(allocator);
        }
        allocator.free(candidates);
    }
    const now_ms = clockMillis(fs, .real);
    for (parsed.expected) |expected| {
        const lock_path = try lockPathAlloc(
            allocator,
            expected.path,
        );
        defer allocator.free(lock_path);
        var current = readLeaseLock(
            fs,
            allocator,
            lock_path,
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer current.deinit(allocator);
        if (!std.mem.eql(u8, current.resource, expected.path)) continue;
        const ownership = legacyLeaseRecoveryOwnership(
            parsed,
            current,
        ) orelse continue;
        const kind: LegacyLeaseRecoveryCandidate.Kind = switch (ownership) {
            .embedded_legacy => legacy: {
                const expires_ms = try parseU64Text(current.expires_at);
                if (now_ms < expires_ms) continue;
                break :legacy .expired_legacy;
            },
            .interrupted_recovery => .interrupted_recovery,
        };
        candidates[count] = try makeLegacyLeaseRecoveryCandidate(
            allocator,
            parsed.transaction_id,
            current,
            kind,
        );
        count += 1;
    }
    if (count == candidates.len) return candidates;
    return allocator.realloc(candidates, count);
}

const LegacyLeaseRecoveryOwnership = union(enum) {
    embedded_legacy: LeaseLock,
    interrupted_recovery: LeaseLock,
};

fn legacyLeaseRecoveryOwnership(
    parsed: ParsedTransactionRecord,
    current: LeaseLock,
) ?LegacyLeaseRecoveryOwnership {
    for (parsed.embedded_locks) |embedded| {
        if (leaseLineagesEqual(current, embedded)) {
            return .{ .embedded_legacy = current };
        }
    }
    if (current.transaction_id != null and
        std.mem.eql(
            u8,
            current.transaction_id.?,
            parsed.transaction_id,
        ) and
        ownersEqual(current.owner, parsed.owner))
    {
        return .{ .interrupted_recovery = current };
    }
    return null;
}

fn parseValidatedLegacyRecoveryRecord(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    authority: LegacyFencingAuthority,
) !ParsedTransactionRecord {
    const control_root = try transactionControlRoot(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const parsed = try parseTransactionRecord(fs, allocator, record_path);
    errdefer parsed.deinit(allocator);
    if (try transactionRecordFormat(allocator, parsed) != .legacy) {
        return error.TransactionRecoveryRequired;
    }
    try validateTransactionRecordScope(
        fs,
        allocator,
        control_root,
        transaction_dir,
        parsed,
        .legacy,
    );
    try validateLegacyFencingAuthorityScope(
        fs,
        allocator,
        transaction_dir,
        parsed,
        authority,
    );
    return parsed;
}

fn makeLegacyLeaseRecoveryCandidate(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    lock: LeaseLock,
    kind: LegacyLeaseRecoveryCandidate.Kind,
) !LegacyLeaseRecoveryCandidate {
    const transaction_id_owned = try allocator.dupe(u8, transaction_id);
    errdefer allocator.free(transaction_id_owned);
    const lock_id_owned = try allocator.dupe(u8, lock.lock_id);
    errdefer allocator.free(lock_id_owned);
    const resource_owned = try allocator.dupe(u8, lock.resource);
    errdefer allocator.free(resource_owned);
    const expires_at_owned = try allocator.dupe(u8, lock.expires_at);
    return .{
        .transaction_id = transaction_id_owned,
        .lock_id = lock_id_owned,
        .resource = resource_owned,
        .fencing_token = lock.fencing_token,
        .expires_at = expires_at_owned,
        .kind = kind,
    };
}

pub fn deinitLegacyLeaseRecoveryCandidates(
    allocator: std.mem.Allocator,
    candidates: []LegacyLeaseRecoveryCandidate,
) void {
    for (candidates) |*candidate| candidate.deinit(allocator);
    allocator.free(candidates);
}

pub fn reclaimLegacyLease(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    authority: LegacyFencingAuthority,
    request: LegacyLeaseReclaimRequest,
    summary: *TransactionRecoverySummary,
) !ReclaimReceipt {
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse
        return error.InvalidPath;
    var recovery_lock = try acquireTransactionRecoveryLock(
        fs,
        allocator,
        transactions_dir,
        &summary.storage_mutated,
    );
    defer recovery_lock.close(fs.io);
    const parsed = try parseValidatedLegacyRecoveryRecord(
        fs,
        allocator,
        transaction_dir,
        authority,
    );
    defer parsed.deinit(allocator);
    try validateLegacyLeaseSelection(parsed, request);

    const control_root = try transactionControlRoot(transaction_dir);
    var resource_target = try TransactionTarget.init(
        fs,
        control_root,
        request.resource,
    );
    defer resource_target.deinit();
    try rejectSymlinkComponents(fs, request.resource);
    try resource_target.verifyPathIdentity();
    const lock_path = try lockPathAlloc(
        allocator,
        request.resource,
    );
    defer allocator.free(lock_path);
    try rejectSymlinkComponents(fs, lock_path);
    var advisory = try acquireLeaseAdvisoryLockObserved(
        fs,
        allocator,
        lock_path,
        &summary.storage_mutated,
    );
    defer advisory.close(fs.io);
    try rejectSymlinkComponents(fs, request.resource);
    try rejectSymlinkComponents(fs, lock_path);
    try resource_target.verifyPathIdentity();
    var current = try readLeaseLock(fs, allocator, lock_path);
    defer current.deinit(allocator);
    if (!std.mem.eql(u8, current.resource, request.resource) or
        !std.mem.eql(u8, current.lock_id, request.lock_id) or
        current.fencing_token != request.fencing_token)
    {
        return error.TransactionRecoveryRequired;
    }

    return reclaimCurrentLegacyLease(
        fs,
        allocator,
        parsed,
        current,
        authority,
        request,
        &summary.storage_mutated,
    );
}

fn validateLegacyLeaseSelection(
    parsed: ParsedTransactionRecord,
    request: LegacyLeaseReclaimRequest,
) !void {
    if (!std.mem.eql(
        u8,
        parsed.transaction_id,
        request.transaction_id,
    )) return error.TransactionCorrupt;

    var resource_selected = false;
    for (parsed.expected) |expected| {
        if (!std.mem.eql(u8, expected.path, request.resource)) continue;
        if (resource_selected) return error.TransactionCorrupt;
        resource_selected = true;
    }
    if (!resource_selected) return error.TransactionRecoveryRequired;
}

fn reclaimCurrentLegacyLease(
    fs: Fs,
    allocator: std.mem.Allocator,
    parsed: ParsedTransactionRecord,
    current: LeaseLock,
    authority: LegacyFencingAuthority,
    request: LegacyLeaseReclaimRequest,
    storage_mutated: *bool,
) !ReclaimReceipt {
    const ownership = legacyLeaseRecoveryOwnership(
        parsed,
        current,
    ) orelse return error.TransactionRecoveryRequired;
    const expected, const require_expiry = switch (ownership) {
        .embedded_legacy => |embedded| legacy: {
            if (!request.confirm_no_legacy_writers) {
                return error.LegacyWriterConfirmationRequired;
            }
            break :legacy .{ embedded, true };
        },
        .interrupted_recovery => |recovery| .{ recovery, false },
    };
    const counter_path = switch (authority) {
        .shared => |path| try allocator.dupe(u8, path),
        .per_resource => per_resource: {
            const derived_lock_path = try lockPathAlloc(
                allocator,
                expected.resource,
            );
            defer allocator.free(derived_lock_path);
            break :per_resource try fencingCounterPathAlloc(
                allocator,
                derived_lock_path,
                null,
            );
        },
    };
    defer allocator.free(counter_path);
    return reclaimLeaseMatchingWitnessLocked(
        fs,
        allocator,
        expected,
        counter_path,
        storage_mutated,
        require_expiry,
    );
}

pub const TransactionDependency = struct {
    kind: enum { journal, commit_marker, target, staged, reservation_pin },
    path: []const u8,
    present: bool,
};

pub const TransactionDependencies = struct {
    transaction_id: []const u8,
    format: TransactionRecordFormat,
    state: TransactionState,
    record_source: enum { journal, supplied_preparation } = .journal,
    intersects: bool,
    coverage: enum { supplied_transaction_only } = .supplied_transaction_only,
    coordination: enum { uncoordinated, retained_read_custody } = .uncoordinated,
    stage_location: enum { transaction_directory } = .transaction_directory,
    entries: []TransactionDependency,

    pub fn deinit(self: TransactionDependencies, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(entry.path);
        allocator.free(self.entries);
        allocator.free(self.transaction_id);
    }
};

pub const transaction_dependency_max_selected_paths = transaction_recovery_max_rows;
pub const transaction_dependency_max_journal_bytes = transaction_record_max_bytes;

pub const TransactionDependencyLimits = struct {
    root_entries: usize = 8196,
    journals: usize = 4096,
    journal_bytes: usize = 16 * 1024 * 1024,
    dependencies: usize = 65536,
    locks: usize = 65536,
    identity_checks: usize = 1024 * 1024,
    preparations: usize = 1024,
};

pub const transaction_budget_association_max_bytes = 4096;
pub const transaction_budget_association_leaf = ".reservation-budget.json";
const transaction_budget_association_stage = ".reservation-budget.stage";

pub const TransactionBudgetSource = struct {
    control_root: filesystem.OpenDirectoryIdentity,
    transaction_root: filesystem.OpenDirectoryIdentity,
};

pub const TransactionBudgetContext = struct {
    budget_id: []const u8,
    store_id: []const u8,
    budget_root: filesystem.OpenDirectoryIdentity,
};

const TransactionBudgetAssociation = struct {
    schema: []const u8 = "durable-transaction-budget/v1",
    context: TransactionBudgetContext,
    source: TransactionBudgetSource,
};

pub const TransactionBudgetCustody = struct {
    fs: Fs,
    directory: std.Io.Dir,
    recovery: std.Io.File,
    source: TransactionBudgetSource,

    pub fn acquire(
        fs: Fs,
        allocator: std.mem.Allocator,
        path: []const u8,
        expected: ?TransactionBudgetSource,
    ) !@This() {
        if (expected == null) try ensureDirectoryPathNoSymlinks(fs, path);
        const directory = fs.directory().openDir(fs.io, path, .{
            .follow_symlinks = false,
        }) catch |err| {
            if (expected != null) return error.TransactionReservationMismatch;
            return err;
        };
        errdefer directory.close(fs.io);
        const source = try transactionBudgetSource(fs, directory);
        if (expected) |identity| {
            if (!std.meta.eql(identity, source)) return error.TransactionReservationMismatch;
        }
        const recovery = try acquireTransactionRecoveryLock(
            Fs.anchored(fs.io, directory),
            allocator,
            ".",
            null,
        );
        errdefer recovery.close(fs.io);
        return .{
            .fs = fs,
            .directory = directory,
            .recovery = recovery,
            .source = source,
        };
    }

    pub fn acquireRead(fs: Fs, allocator: std.mem.Allocator, path: []const u8) !@This() {
        const directory = try fs.directory().openDir(fs.io, path, .{ .follow_symlinks = false });
        errdefer directory.close(fs.io);
        var locks: std.ArrayList(std.Io.File) = .empty;
        defer locks.deinit(allocator);
        errdefer for (locks.items) |lock| lock.close(fs.io);
        try retainDependencyLock(
            Fs.anchored(fs.io, directory),
            allocator,
            &locks,
            ".recovery.advisory",
            1,
        );
        return .{
            .fs = fs,
            .directory = directory,
            .source = try transactionBudgetSource(fs, directory),
            .recovery = locks.pop().?,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.directory.close(self.fs.io);
        self.recovery.close(self.fs.io);
        self.* = undefined;
    }

    pub fn requireUnassociated(self: *const @This()) !void {
        const fs = Fs.init(self.fs.io, self.directory);
        for ([_][]const u8{
            transaction_budget_association_leaf, transaction_budget_association_stage,
        }) |leaf| {
            if (try statRegularFileNoSymlink(fs, leaf) != null) {
                return error.TransactionDependencyBudgetMismatch;
            }
        }
    }

    pub fn validate(
        self: *const @This(),
        allocator: std.mem.Allocator,
        context: TransactionBudgetContext,
    ) !void {
        const bytes = (try readTransactionBudgetAssociation(
            Fs.init(self.fs.io, self.directory),
            allocator,
            transaction_budget_association_max_bytes,
        )) orelse return error.TransactionDependencyBudgetMismatch;
        defer allocator.free(bytes);
        try validateTransactionBudgetAssociation(allocator, bytes, context, self.source);
    }

    pub fn publish(
        self: *@This(),
        allocator: std.mem.Allocator,
        context: TransactionBudgetContext,
    ) !void {
        const fs = Fs.init(self.fs.io, self.directory);
        if (try readTransactionBudgetAssociation(
            fs,
            allocator,
            transaction_budget_association_max_bytes,
        )) |existing| {
            defer allocator.free(existing);
            try validateTransactionBudgetAssociation(allocator, existing, context, self.source);
            const file = try self.directory.openFile(fs.io, transaction_budget_association_leaf, .{
                .follow_symlinks = false,
            });
            defer file.close(fs.io);
            try file.sync(fs.io);
        } else {
            const bytes = try std.json.Stringify.valueAlloc(allocator, TransactionBudgetAssociation{
                .context = context,
                .source = self.source,
            }, .{});
            defer allocator.free(bytes);
            if (bytes.len > transaction_budget_association_max_bytes) return error.FileTooBig;
            const file = try openTransactionBudgetStage(fs);
            {
                defer file.close(fs.io);
                try file.writeStreamingAll(fs.io, bytes);
                try file.sync(fs.io);
            }
            try self.directory.renamePreserve(
                transaction_budget_association_stage,
                self.directory,
                transaction_budget_association_leaf,
                fs.io,
            );
        }
        try filesystem.syncDirectoryHandle(fs, &self.directory);
    }
};

pub fn validateTransactionBudgetAt(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: TransactionBudgetSource,
    context: TransactionBudgetContext,
) !void {
    const directory = fs.directory().openDir(fs.io, path, .{
        .follow_symlinks = false,
    }) catch return error.TransactionReservationMismatch;
    defer directory.close(fs.io);
    const source = try transactionBudgetSource(fs, directory);
    if (!std.meta.eql(source, expected)) return error.TransactionReservationMismatch;
    var custody = try TransactionBudgetCustody.acquireRead(fs, allocator, path);
    defer custody.deinit();
    if (!std.meta.eql(custody.source, expected)) return error.TransactionReservationMismatch;
    try custody.validate(allocator, context);
}

fn transactionBudgetSource(
    fs: Fs,
    directory: std.Io.Dir,
) !TransactionBudgetSource {
    const control = try directory.openDir(fs.io, "..", .{ .follow_symlinks = false });
    defer control.close(fs.io);
    return .{
        .control_root = try filesystem.openDirectoryIdentity(fs.io, control),
        .transaction_root = try filesystem.openDirectoryIdentity(fs.io, directory),
    };
}

fn openTransactionBudgetStage(fs: Fs) !std.Io.File {
    const file = fs.directory().createFile(fs.io, transaction_budget_association_stage, .{
        .exclusive = true,
        .permissions = .fromMode(0o600),
    }) catch |err| switch (err) {
        error.PathAlreadyExists => try fs.directory().openFile(
            fs.io,
            transaction_budget_association_stage,
            .{
                .mode = .read_write,
                .follow_symlinks = false,
                .allow_directory = false,
            },
        ),
        else => return err,
    };
    errdefer file.close(fs.io);
    const stat = try file.stat(fs.io);
    if (stat.kind != .file) return error.NotFile;
    if (stat.nlink != 1) return error.HardlinkTarget;
    try file.setLength(fs.io, 0);
    return file;
}

fn readTransactionBudgetAssociation(
    fs: Fs,
    allocator: std.mem.Allocator,
    maximum: usize,
) !?[]u8 {
    const file = filesystem.openRegularFileNoSymlink(
        fs,
        transaction_budget_association_leaf,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(fs.io);
    const stat = try file.stat(fs.io);
    if (stat.nlink != 1) return error.HardlinkTarget;
    if (stat.size > maximum) return error.TransactionDependencyLimitExceeded;
    var reader = file.reader(fs.io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(maximum)) catch |err|
        switch (err) {
            error.StreamTooLong => error.TransactionDependencyLimitExceeded,
            error.ReadFailed => reader.err orelse error.ReadFailed,
            else => err,
        };
}

fn validateTransactionBudgetAssociation(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    context: TransactionBudgetContext,
    source: TransactionBudgetSource,
) !void {
    const parsed = std.json.parseFromSlice(TransactionBudgetAssociation, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch return error.TransactionDependencyBudgetMismatch;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schema, "durable-transaction-budget/v1") or
        !std.mem.eql(u8, parsed.value.context.budget_id, context.budget_id) or
        !std.mem.eql(u8, parsed.value.context.store_id, context.store_id) or
        !std.meta.eql(parsed.value.context.budget_root, context.budget_root) or
        !std.meta.eql(parsed.value.source, source))
    {
        return error.TransactionDependencyBudgetMismatch;
    }
}

pub const TransactionDependencyLocation = struct {
    recorded_control_root: []const u8,
};

pub const TransactionDependencyPreparation = struct {
    transaction_dir: []const u8,
    preparation: TransactionPreparation,
    pin: []const u8,
};

pub const TransactionDependencyPublication = struct {
    transaction_id: []const u8,
    transaction_dir: []const u8,
    state: TransactionState,
    intent_digest: [32]u8,
    root_identity: filesystem.OpenDirectoryIdentity,
    pin: []const u8,

    pub fn deinit(self: *TransactionDependencyPublication, allocator: std.mem.Allocator) void {
        allocator.free(self.transaction_dir);
        allocator.free(self.pin);
    }
};

pub fn ensureTransactionDependencyCoordination(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    storage_mutated: *bool,
) !void {
    try filesystem.ensureDirectoryPathNoSymlinksObserved(fs, transactions_dir, storage_mutated);
    for ([_][]const u8{ ".recovery.advisory", ".journal.advisory" }, 0..) |leaf, index| {
        const path = try std.fs.path.join(allocator, &.{ transactions_dir, leaf });
        defer allocator.free(path);
        if (try statRegularFileNoSymlink(fs, path) != null) continue;
        const lock = (if (index == 0)
            acquireTransactionRecoveryLock(fs, allocator, transactions_dir, storage_mutated)
        else
            acquireTransactionJournalLock(
                fs,
                allocator,
                transactions_dir,
                storage_mutated,
            )) catch |err| {
            if (err == error.LockBusy and try statRegularFileNoSymlink(fs, path) != null) continue;
            return err;
        };
        lock.close(fs.io);
    }
}

pub const TransactionPublicationCustody = struct {
    fs: Fs,
    directory: std.Io.Dir,
    source: TransactionBudgetSource,
    journal: std.Io.File,
    recovery: []RecoveryGuard,

    const snapshots_max = 1024;
    const locks_max = 65536;
    const RecoveryGuard = struct { io: std.Io, file: std.Io.File };

    pub fn acquire(
        allocator: std.mem.Allocator,
        snapshots: []const *TransactionDependencySnapshot,
    ) !TransactionPublicationCustody {
        if (snapshots.len == 0) return error.TransactionDependencyCoordinationUnavailable;
        if (snapshots.len > snapshots_max) return error.TransactionDependencyLimitExceeded;
        const first = snapshots[0];
        const directory = try first.fs.directory().openDir(
            first.fs.io,
            first.transactions_dir,
            .{ .follow_symlinks = false },
        );
        errdefer directory.close(first.fs.io);
        const source = try transactionBudgetSource(first.fs, directory);
        try validateSnapshots(snapshots, source);
        const recovery = try allocator.alloc(RecoveryGuard, snapshots.len);
        errdefer allocator.free(recovery);
        const journal_inode = (try first.locks[first.locks.len - 1].stat(first.fs.io)).inode;
        for (snapshots) |snapshot| {
            snapshot.coordination = .released;
            for (snapshot.transactions) |*transaction| transaction.coordination = .uncoordinated;
            snapshot.owned_lock_count -= 1;
            snapshot.locks[snapshot.owned_lock_count].close(snapshot.fs.io);
        }
        const journal = directory.openFile(first.fs.io, ".journal.advisory", .{
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.LockBusy,
            error.FileNotFound => return error.TransactionDependencyCoordinationUnavailable,
            else => return err,
        };
        errdefer journal.close(first.fs.io);
        const stat = try journal.stat(first.fs.io);
        if (stat.kind != .file or stat.inode != journal_inode) {
            return error.TransactionDependencyChanged;
        }
        var result: TransactionPublicationCustody = .{
            .fs = first.fs,
            .directory = directory,
            .source = source,
            .journal = journal,
            .recovery = recovery,
        };
        for (snapshots) |snapshot| try result.validate(snapshot.fs, snapshot.transactions_dir);
        for (snapshots, recovery) |snapshot, *guard| {
            guard.* = .{ .io = snapshot.fs.io, .file = snapshot.locks[0] };
            for (snapshot.locks[1..snapshot.owned_lock_count]) |lock| lock.close(snapshot.fs.io);
            snapshot.owned_lock_count = 0;
        }
        return result;
    }

    fn validateSnapshots(
        snapshots: []const *TransactionDependencySnapshot,
        source: TransactionBudgetSource,
    ) !void {
        var total: usize = 0;
        for (snapshots, 0..) |snapshot, index| {
            if (snapshot.coordination != .retained_read_custody or
                snapshot.owned_lock_count != snapshot.locks.len or snapshot.locks.len < 2)
            {
                return error.TransactionDependencyCoordinationUnavailable;
            }
            if (snapshot.locks.len > locks_max - total) {
                return error.TransactionDependencyLimitExceeded;
            }
            total += snapshot.locks.len;
            for (snapshots[0..index]) |prior| {
                if (prior == snapshot) return error.TransactionDependencyCoordinationUnavailable;
            }
            if (!std.meta.eql(snapshot.source, source)) return error.TransactionReservationMismatch;
            try validateSource(snapshot.fs, snapshot.transactions_dir, source);
        }
    }

    pub fn validate(self: *const @This(), fs: Fs, transactions_dir: []const u8) !void {
        try validateSource(fs, transactions_dir, self.source);
        if (!std.meta.eql(self.source, try transactionBudgetSource(self.fs, self.directory))) {
            return error.TransactionReservationMismatch;
        }
    }

    fn validateSource(fs: Fs, transactions_dir: []const u8, source: TransactionBudgetSource) !void {
        try rejectSymlinkComponents(fs, transactions_dir);
        const directory = fs.directory().openDir(fs.io, transactions_dir, .{
            .follow_symlinks = false,
        }) catch return error.TransactionReservationMismatch;
        defer directory.close(fs.io);
        if (!std.meta.eql(source, try transactionBudgetSource(fs, directory))) {
            return error.TransactionReservationMismatch;
        }
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.journal.close(self.fs.io);
        for (self.recovery) |guard| guard.file.close(guard.io);
        allocator.free(self.recovery);
        self.directory.close(self.fs.io);
        self.* = undefined;
    }
};

pub const TransactionDependencySnapshot = struct {
    fs: Fs,
    source: TransactionBudgetSource,
    transactions: []TransactionDependencies,
    locks: []std.Io.File,
    owned_lock_count: usize,
    protected_paths: [][]const u8,
    transactions_dir: []const u8,
    root_entries_seen: usize,
    journal_bytes_read: usize,
    identity_checks_used: usize,
    recorded_control_root: ?[]const u8 = null,
    budget_association: ?[]const u8 = null,
    coverage: enum {
        transaction_root_only,
        transaction_root_and_supplied_preparations,
    } = .transaction_root_only,
    reserved_intent_coverage: enum {
        not_inspected,
        supplied_preparations_only,
    } = .not_inspected,
    coordination: enum { retained_read_custody, released } = .retained_read_custody,
    lock_order: enum {
        recovery_then_sorted_targets_then_journal,
    } = .recovery_then_sorted_targets_then_journal,

    pub fn deinit(self: *TransactionDependencySnapshot, allocator: std.mem.Allocator) void {
        for (self.transactions) |transaction| transaction.deinit(allocator);
        allocator.free(self.transactions);
        for (self.locks[0..self.owned_lock_count]) |lock| lock.close(self.fs.io);
        allocator.free(self.locks);
        for (self.protected_paths) |path| allocator.free(path);
        allocator.free(self.protected_paths);
        allocator.free(self.transactions_dir);
        if (self.recorded_control_root) |root| allocator.free(root);
        if (self.budget_association) |bytes| allocator.free(bytes);
        self.* = undefined;
    }

    pub fn visit(self: *const TransactionDependencySnapshot, visitor: anytype) !void {
        for (self.transactions) |transaction| {
            for (transaction.entries) |dependency| {
                try visitor.visit(transaction.transaction_id, dependency);
            }
        }
    }

    pub fn preparationIntersects(
        self: *const TransactionDependencySnapshot,
        allocator: std.mem.Allocator,
        preparation: TransactionDependencyPreparation,
        checks_remaining: *usize,
    ) !bool {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const location: ?TransactionDependencyLocation = if (self.recorded_control_root) |root|
            .{ .recorded_control_root = root }
        else
            null;
        const path = try dependencyPreparationPath(
            arena.allocator(),
            self.transactions_dir,
            location,
            preparation.transaction_dir,
        );
        try validatePublicationRoot(self.fs, path, preparation.preparation.root_identity);
        const parsed = try parseReservedPreparation(allocator, preparation.preparation);
        defer parsed.deinit(allocator);
        try validateTransactionRecordIdentity(path, parsed, .current);
        const control = try transactionControlRoot(path);
        var view = try DependencyRecordView.init(allocator, parsed, control, location);
        defer view.deinit();
        try validateTransactionRecordScopeWithMode(
            self.fs,
            allocator,
            control,
            path,
            view.record,
            .current,
            .metadata_only,
        );
        return transactionIntersectsSelectionBounded(
            self.fs,
            allocator,
            view.record,
            self.protected_paths,
            checks_remaining,
        );
    }

    pub fn validatePublicationBinding(
        self: *const TransactionDependencySnapshot,
        allocator: std.mem.Allocator,
        publication_view: TransactionDependencyPublication,
        recorded_dir: []const u8,
        intent: [32]u8,
        root_identity: filesystem.OpenDirectoryIdentity,
    ) !void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const location: ?TransactionDependencyLocation = if (self.recorded_control_root) |root|
            .{ .recorded_control_root = root }
        else
            null;
        const mapped = try dependencyPreparationPath(
            arena.allocator(),
            self.transactions_dir,
            location,
            recorded_dir,
        );
        if (!std.mem.eql(u8, mapped, publication_view.transaction_dir) or
            !std.meta.eql(intent, publication_view.intent_digest) or
            !std.meta.eql(root_identity, publication_view.root_identity))
        {
            return error.TransactionReservationMismatch;
        }
    }

    pub fn readPublication(
        self: *const TransactionDependencySnapshot,
        allocator: std.mem.Allocator,
        transaction: TransactionDependencies,
        remaining: *usize,
    ) !?TransactionDependencyPublication {
        if (transaction.record_source == .supplied_preparation) return null;
        const path = try std.fs.path.join(
            allocator,
            &.{
                self.transactions_dir,
                transaction.transaction_id,
            },
        );
        errdefer allocator.free(path);
        const marker_path = try transactionCommitMarkerPathAlloc(allocator, path);
        defer allocator.free(marker_path);
        const marker = readDependencyBytes(
            self.fs,
            allocator,
            marker_path,
            transaction_commit_marker_max_bytes,
            remaining,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (marker) |bytes| allocator.free(bytes);
        const pin_path = try std.fs.path.join(allocator, &.{ path, reservation_pin_leaf });
        defer allocator.free(pin_path);
        const pin = readDependencyBytes(
            self.fs,
            allocator,
            pin_path,
            reservation_pin_max_bytes,
            remaining,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        errdefer if (pin) |bytes| allocator.free(bytes);
        if (pin == null) {
            if (marker) |bytes| {
                if (!std.mem.eql(u8, bytes, ordinary_commit_marker)) {
                    return error.TransactionReservationMismatch;
                }
            }
            allocator.free(path);
            return null;
        }
        return try dependencyPublicationFromRecord(
            self,
            allocator,
            transaction,
            path,
            pin.?,
            marker,
            remaining,
        );
    }
};

fn dependencyPublicationFromRecord(
    snapshot: *const TransactionDependencySnapshot,
    allocator: std.mem.Allocator,
    transaction: TransactionDependencies,
    path: []const u8,
    pin: []const u8,
    marker: ?[]const u8,
    remaining: *usize,
) !TransactionDependencyPublication {
    const record_path = try std.fs.path.join(allocator, &.{ path, "transaction.json" });
    defer allocator.free(record_path);
    const bytes = try readDependencyBytes(
        snapshot.fs,
        allocator,
        record_path,
        transaction_record_max_bytes,
        remaining,
    );
    defer allocator.free(bytes);
    const parsed = try parseTransactionRecordBytes(allocator, bytes);
    defer parsed.deinit(allocator);
    const root_identity = try transactionRootIdentity(snapshot.fs, path);
    if (transaction.state != parsed.state) return error.TransactionDependencyChanged;
    if (parsed.state == .committed) {
        const expected = try renderReservedCommitMarkerRecord(
            allocator,
            bytes,
            parsed,
            root_identity,
            pin,
        );
        defer allocator.free(expected);
        if (marker == null or !std.mem.eql(u8, expected, marker.?)) {
            return error.TransactionReservationMismatch;
        }
    } else if (marker != null) return error.TransactionReservationMismatch;
    return .{
        .transaction_id = transaction.transaction_id,
        .transaction_dir = path,
        .state = parsed.state,
        .intent_digest = try transactionIntentDigest(
            allocator,
            parsed.transaction_id,
            parsed.owner,
            parsed.expected,
            parsed.writes,
        ),
        .root_identity = root_identity,
        .pin = pin,
    };
}

pub fn snapshotTransactionDependencies(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    selected_paths: []const []const u8,
    limits: TransactionDependencyLimits,
) !TransactionDependencySnapshot {
    return snapshotTransactionDependenciesAt(
        fs,
        allocator,
        transactions_dir,
        selected_paths,
        null,
        limits,
    );
}

pub fn snapshotTransactionDependenciesAt(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    selected_paths: []const []const u8,
    location: ?TransactionDependencyLocation,
    limits: TransactionDependencyLimits,
) !TransactionDependencySnapshot {
    return snapshotTransactionDependenciesWithPreparationsAt(
        fs,
        allocator,
        transactions_dir,
        selected_paths,
        location,
        &.{},
        limits,
    );
}

pub fn snapshotTransactionDependenciesWithPreparationsAt(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    selected_paths: []const []const u8,
    location: ?TransactionDependencyLocation,
    preparations: []const TransactionDependencyPreparation,
    limits: TransactionDependencyLimits,
) !TransactionDependencySnapshot {
    return snapshotTransactionDependenciesWithBudgetAt(
        fs,
        allocator,
        transactions_dir,
        selected_paths,
        location,
        preparations,
        null,
        limits,
    );
}

pub fn snapshotTransactionDependenciesWithBudgetAt(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    selected_paths: []const []const u8,
    location: ?TransactionDependencyLocation,
    preparations: []const TransactionDependencyPreparation,
    budget_context: ?TransactionBudgetContext,
    limits: TransactionDependencyLimits,
) !TransactionDependencySnapshot {
    try validateDependencySnapshotLocation(fs, transactions_dir, location, limits);
    if (preparations.len > limits.preparations) return error.TransactionDependencyLimitExceeded;
    var capture: DependencySnapshotCapture = .{
        .fs = fs,
        .allocator = allocator,
        .transactions_dir = transactions_dir,
        .location = location,
        .limits = limits,
        .preparations = preparations,
        .budget_context = budget_context,
        .entries_remaining = limits.root_entries,
        .bytes_remaining = limits.journal_bytes,
        .checks_remaining = limits.identity_checks,
    };
    defer capture.deinit();
    return capture.run(selected_paths);
}

fn validateDependencySnapshotLocation(
    fs: Fs,
    transactions_dir: []const u8,
    location: ?TransactionDependencyLocation,
    limits: TransactionDependencyLimits,
) !void {
    const ceilings: TransactionDependencyLimits = .{};
    inline for (.{
        "root_entries", "journals", "journal_bytes", "dependencies", "locks", "identity_checks",
        "preparations",
    }) |field| {
        if (@field(limits, field) > @field(ceilings, field)) {
            return error.TransactionDependencyLimitExceeded;
        }
    }
    if (fs.isPinned() and std.fs.path.isAbsolute(transactions_dir)) {
        return error.InvalidTransactionDependencyLocation;
    }
    if (location) |origin| {
        if (!fs.isPinned() or std.fs.path.isAbsolute(transactions_dir) or
            !std.fs.path.isAbsolute(origin.recorded_control_root))
        {
            return error.InvalidTransactionDependencyLocation;
        }
        var components = std.fs.path.componentIterator(origin.recorded_control_root);
        while (components.next()) |component| {
            if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
                return error.InvalidTransactionDependencyLocation;
            }
        }
    }
}

const DependencySnapshotCapture = struct {
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    location: ?TransactionDependencyLocation,
    limits: TransactionDependencyLimits,
    preparations: []const TransactionDependencyPreparation,
    budget_context: ?TransactionBudgetContext,
    budget_association: ?[]const u8 = null,
    source_directory: ?std.Io.Dir = null,
    source_identity: ?TransactionBudgetSource = null,
    entries_remaining: usize,
    bytes_remaining: usize,
    checks_remaining: usize,
    locks: std.ArrayList(std.Io.File) = .empty,
    selected: std.ArrayList([]const u8) = .empty,
    census: std.ArrayList(DependencyCensusEntry) = .empty,
    current: std.ArrayList(DependencyCensusEntry) = .empty,

    fn deinit(self: *DependencySnapshotCapture) void {
        if (self.source_directory) |directory| directory.close(self.fs.io);
        if (self.budget_association) |bytes| self.allocator.free(bytes);
        for (self.locks.items) |lock| lock.close(self.fs.io);
        self.locks.deinit(self.allocator);
        self.selected.deinit(self.allocator);
        for (self.census.items) |*entry| entry.deinit(self.allocator);
        self.census.deinit(self.allocator);
        for (self.current.items) |*entry| entry.deinit(self.allocator);
        self.current.deinit(self.allocator);
    }

    fn run(
        self: *DependencySnapshotCapture,
        selected_paths: []const []const u8,
    ) !TransactionDependencySnapshot {
        const root = std.fs.path.dirname(self.transactions_dir) orelse return error.InvalidPath;
        if (self.fs.isPinned()) {
            for (selected_paths) |selected| {
                if (std.fs.path.isAbsolute(selected)) {
                    return error.TransactionPathOutsideControlRoot;
                }
            }
        }
        try rejectSymlinkComponents(self.fs, self.transactions_dir);
        try validateDependencySelection(self.fs, self.allocator, root, selected_paths);
        try self.sourceCustody();
        try self.budgetAssociation();
        try self.selected.appendSlice(self.allocator, selected_paths);
        try self.targetLocks();
        self.census = try self.readCensus();
        try self.expand();
        for (self.locks.items[1..]) |lock| lock.close(self.fs.io);
        self.locks.shrinkRetainingCapacity(1);
        try self.targetLocks();
        try self.controlLock(".journal.advisory");
        self.current = try self.readCensus();
        return self.finish();
    }

    fn sourceCustody(self: *DependencySnapshotCapture) !void {
        if (self.limits.locks == 0) return error.TransactionDependencyLimitExceeded;
        var custody = try TransactionBudgetCustody.acquireRead(
            self.fs,
            self.allocator,
            self.transactions_dir,
        );
        errdefer custody.deinit();
        try self.locks.append(self.allocator, custody.recovery);
        self.source_directory = custody.directory;
        self.source_identity = custody.source;
    }

    fn validateSourceCustody(self: *const DependencySnapshotCapture) !void {
        const current = try self.fs.directory().openDir(self.fs.io, self.transactions_dir, .{
            .follow_symlinks = false,
        });
        defer current.close(self.fs.io);
        if (!std.meta.eql(self.source_identity.?, try transactionBudgetSource(self.fs, current))) {
            return error.TransactionDependencyChanged;
        }
    }

    fn budgetAssociation(self: *DependencySnapshotCapture) !void {
        const directory = self.source_directory.?;
        const fs = Fs.init(self.fs.io, directory);
        self.budget_association = try readTransactionBudgetAssociation(
            fs,
            self.allocator,
            @min(self.bytes_remaining, transaction_budget_association_max_bytes),
        );
        if (self.budget_association) |bytes| {
            if (bytes.len > self.bytes_remaining) return error.TransactionDependencyLimitExceeded;
            self.bytes_remaining -= bytes.len;
            const context = self.budget_context orelse
                return error.TransactionDependencyBudgetContextRequired;
            try validateTransactionBudgetAssociation(
                self.allocator,
                bytes,
                context,
                try transactionBudgetSource(self.fs, directory),
            );
        } else if (try statRegularFileNoSymlink(fs, transaction_budget_association_stage) != null) {
            return error.TransactionDependencyBudgetContextRequired;
        }
    }

    fn controlLock(self: *DependencySnapshotCapture, leaf: []const u8) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.transactions_dir, leaf });
        defer self.allocator.free(path);
        try retainDependencyLock(self.fs, self.allocator, &self.locks, path, self.limits.locks);
    }

    fn targetLocks(self: *DependencySnapshotCapture) !void {
        try retainDependencyTargetLocks(
            self.fs,
            self.allocator,
            &self.locks,
            self.selected.items,
            self.limits.locks,
        );
    }

    fn readCensus(self: *DependencySnapshotCapture) !std.ArrayList(DependencyCensusEntry) {
        return readDependencyCensus(
            self.fs,
            self.allocator,
            self.transactions_dir,
            self.location,
            self.preparations,
            self.limits,
            &self.entries_remaining,
            &self.bytes_remaining,
        );
    }

    fn expand(self: *DependencySnapshotCapture) !void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.census.items) |*entry| {
                if (entry.selected or !try transactionIntersectsSelectionBounded(
                    self.fs,
                    self.allocator,
                    entry.view.record,
                    self.selected.items,
                    &self.checks_remaining,
                )) continue;
                if (try transactionRecordFormat(self.allocator, entry.record) == .legacy) {
                    return error.TransactionDependencyLegacyAuthorityRequired;
                }
                if (entry.view.record.expected.len >
                    self.limits.dependencies -| self.selected.items.len)
                {
                    return error.TransactionDependencyLimitExceeded;
                }
                for (entry.view.record.expected) |expected| {
                    try self.selected.append(self.allocator, expected.path);
                }
                entry.selected = true;
                changed = true;
            }
        }
    }

    fn finish(self: *DependencySnapshotCapture) !TransactionDependencySnapshot {
        try self.validateSourceCustody();
        const allocator = self.allocator;
        if (self.current.items.len != self.census.items.len) {
            return error.TransactionDependencyChanged;
        }
        var indexes: std.StringHashMap(usize) = .init(allocator);
        defer indexes.deinit();
        for (self.census.items, 0..) |entry, index| try indexes.put(entry.path, index);
        var result: std.ArrayList(TransactionDependencies) = .empty;
        errdefer {
            for (result.items) |transaction| transaction.deinit(allocator);
            result.deinit(allocator);
        }
        var dependencies: usize = 0;
        for (self.current.items) |entry| {
            const index = indexes.get(entry.path) orelse return error.TransactionDependencyChanged;
            const prior = self.census.items[index];
            if (!recoveryRecordCustodyEqual(prior.record, entry.record)) {
                return error.TransactionDependencyChanged;
            }
            if (!prior.selected) continue;
            var transaction = try transactionDependenciesFromRecord(
                self.fs,
                allocator,
                entry.path,
                self.selected.items,
                entry.view.record,
                true,
            );
            errdefer transaction.deinit(allocator);
            if (transaction.entries.len > self.limits.dependencies - dependencies) {
                return error.TransactionDependencyLimitExceeded;
            }
            dependencies += transaction.entries.len;
            transaction.coordination = .retained_read_custody;
            transaction.record_source = if (entry.from_preparation)
                .supplied_preparation
            else
                .journal;
            try result.append(allocator, transaction);
        }
        const owned = try result.toOwnedSlice(allocator);
        errdefer {
            for (owned) |transaction| transaction.deinit(allocator);
            allocator.free(owned);
        }
        return self.ownSnapshot(owned);
    }

    fn ownSnapshot(
        self: *DependencySnapshotCapture,
        owned: []TransactionDependencies,
    ) !TransactionDependencySnapshot {
        const allocator = self.allocator;
        const recorded_root = if (self.location) |origin|
            try allocator.dupe(u8, origin.recorded_control_root)
        else
            null;
        errdefer if (recorded_root) |root| allocator.free(root);
        const protected = try duplicateDependencyPaths(allocator, self.selected.items);
        errdefer {
            for (protected) |path| allocator.free(path);
            allocator.free(protected);
        }
        const transactions_dir = try allocator.dupe(u8, self.transactions_dir);
        errdefer allocator.free(transactions_dir);
        const result: TransactionDependencySnapshot = .{
            .fs = self.fs,
            .source = self.source_identity.?,
            .transactions = owned,
            .owned_lock_count = self.locks.items.len,
            .locks = try self.locks.toOwnedSlice(allocator),
            .protected_paths = protected,
            .transactions_dir = transactions_dir,
            .root_entries_seen = self.limits.root_entries - self.entries_remaining,
            .journal_bytes_read = self.limits.journal_bytes - self.bytes_remaining,
            .identity_checks_used = self.limits.identity_checks - self.checks_remaining,
            .recorded_control_root = recorded_root,
            .budget_association = self.budget_association,
            .coverage = if (self.preparations.len == 0)
                .transaction_root_only
            else
                .transaction_root_and_supplied_preparations,
            .reserved_intent_coverage = if (self.preparations.len == 0)
                .not_inspected
            else
                .supplied_preparations_only,
        };
        self.budget_association = null;
        return result;
    }
};

fn retainDependencyTargetLocks(
    fs: Fs,
    allocator: std.mem.Allocator,
    locks: *std.ArrayList(std.Io.File),
    paths: [][]const u8,
    maximum: usize,
) !void {
    std.sort.heap([]const u8, paths, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    for (paths, 0..) |path, index| {
        if (index != 0 and std.mem.eql(u8, paths[index - 1], path)) continue;
        try retainDependencyTargetLock(fs, allocator, locks, path, maximum);
    }
}

const DependencyCensusEntry = struct {
    path: []u8,
    record: ParsedTransactionRecord,
    view: DependencyRecordView,
    selected: bool = false,
    from_preparation: bool = false,

    fn deinit(self: *DependencyCensusEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.view.deinit();
        self.record.deinit(allocator);
    }
};

const DependencyRecordView = struct {
    arena: std.heap.ArenaAllocator,
    record: ParsedTransactionRecord,

    fn init(
        allocator: std.mem.Allocator,
        record: ParsedTransactionRecord,
        control_root: []const u8,
        location: ?TransactionDependencyLocation,
    ) !DependencyRecordView {
        var result: DependencyRecordView = .{ .arena = .init(allocator), .record = record };
        errdefer result.deinit();
        const origin = location orelse return result;
        const arena = result.arena.allocator();
        var expected_paths: std.StringHashMap(void) = .init(arena);
        for (record.expected) |expected| try expected_paths.put(expected.path, {});
        for (record.writes) |write| {
            if (!expected_paths.contains(write.path)) return error.TransactionCorrupt;
        }
        result.record.expected = try arena.dupe(TransactionExpected, record.expected);
        for (result.record.expected) |*expected| {
            expected.path = try mapDependencyPath(arena, control_root, origin, expected.path);
        }
        result.record.writes = try arena.dupe(TransactionWrite, record.writes);
        for (result.record.writes) |*write| {
            write.path = try mapDependencyPath(arena, control_root, origin, write.path);
        }
        result.record.embedded_locks = try arena.dupe(LeaseLock, record.embedded_locks);
        for (result.record.embedded_locks) |*lock| {
            lock.resource = try mapDependencyPath(arena, control_root, origin, lock.resource);
            lock.path = try mapDependencyPath(arena, control_root, origin, lock.path);
        }
        return result;
    }

    fn deinit(self: *DependencyRecordView) void {
        self.arena.deinit();
    }
};

fn mapDependencyPath(
    allocator: std.mem.Allocator,
    control_root: []const u8,
    location: TransactionDependencyLocation,
    path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        const relative = try pathRelativeToControlRoot(location.recorded_control_root, path);
        return std.fs.path.join(allocator, &.{ control_root, relative });
    }
    var components = std.fs.path.componentIterator(path);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return error.TransactionPathOutsideControlRoot;
    }
    const normalized_root = try std.fs.path.resolve(allocator, &.{control_root});
    const normalized_path = try std.fs.path.resolve(allocator, &.{path});
    const relative = if (std.mem.eql(u8, normalized_root, "."))
        normalized_path
    else
        try pathRelativeToControlRoot(normalized_root, normalized_path);
    if (std.mem.eql(u8, relative, ".") or std.fs.path.isAbsolute(relative)) {
        return error.TransactionPathOutsideControlRoot;
    }
    return std.fs.path.join(allocator, &.{ control_root, relative });
}

fn readDependencyCensus(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    location: ?TransactionDependencyLocation,
    preparations: []const TransactionDependencyPreparation,
    limits: TransactionDependencyLimits,
    entries_remaining: *usize,
    bytes_remaining: *usize,
) !std.ArrayList(DependencyCensusEntry) {
    var directory = try fs.directory().openDir(fs.io, transactions_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer directory.close(fs.io);
    var result: std.ArrayList(DependencyCensusEntry) = .empty;
    errdefer {
        for (result.items) |*entry| entry.deinit(allocator);
        result.deinit(allocator);
    }
    var supplied = try DependencyPreparationIndex.init(
        fs,
        allocator,
        transactions_dir,
        location,
        preparations,
    );
    defer supplied.deinit(allocator);
    var iterator = directory.iterate();
    while (try iterator.next(fs.io)) |entry| {
        if (entries_remaining.* == 0) return error.TransactionDependencyLimitExceeded;
        entries_remaining.* -= 1;
        if (entry.kind == .sym_link) return error.SymlinkComponent;
        if (entry.kind != .directory) {
            if (!std.mem.eql(u8, entry.name, ".recovery.advisory") and
                !std.mem.eql(u8, entry.name, ".journal.advisory") and
                !std.mem.eql(u8, entry.name, transaction_budget_association_leaf) and
                !std.mem.eql(u8, entry.name, transaction_budget_association_stage))
            {
                return error.TransactionDependencyIncomplete;
            }
            continue;
        }
        if (result.items.len == limits.journals) return error.TransactionDependencyLimitExceeded;
        const path = try std.fs.path.join(allocator, &.{ transactions_dir, entry.name });
        defer allocator.free(path);
        try appendDependencyCensusEntry(
            fs,
            allocator,
            &result,
            path,
            location,
            supplied.take(path),
            entries_remaining,
            bytes_remaining,
        );
    }
    try supplied.appendUnseen(
        fs,
        allocator,
        &result,
        location,
        limits.journals,
        entries_remaining,
        bytes_remaining,
    );
    return result;
}

const DependencyPreparationIndex = struct {
    const Entry = struct {
        path: []const u8,
        preparation: TransactionDependencyPreparation,
        seen: bool = false,
    };
    entries: std.ArrayList(Entry) = .empty,
    indexes: std.StringHashMap(usize),
    arena: std.heap.ArenaAllocator,

    fn init(
        fs: Fs,
        allocator: std.mem.Allocator,
        transactions_dir: []const u8,
        location: ?TransactionDependencyLocation,
        preparations: []const TransactionDependencyPreparation,
    ) !DependencyPreparationIndex {
        var result: DependencyPreparationIndex = .{
            .indexes = .init(allocator),
            .arena = .init(allocator),
        };
        errdefer result.deinit(allocator);
        for (preparations) |preparation| {
            const path = try dependencyPreparationPath(
                result.arena.allocator(),
                transactions_dir,
                location,
                preparation.transaction_dir,
            );
            try validatePublicationRoot(fs, path, preparation.preparation.root_identity);
            const entry = try result.indexes.getOrPut(path);
            if (entry.found_existing) return error.TransactionReservationMismatch;
            entry.value_ptr.* = result.entries.items.len;
            try result.entries.append(allocator, .{ .path = path, .preparation = preparation });
        }
        return result;
    }

    fn appendUnseen(
        self: *DependencyPreparationIndex,
        fs: Fs,
        allocator: std.mem.Allocator,
        result: *std.ArrayList(DependencyCensusEntry),
        location: ?TransactionDependencyLocation,
        maximum: usize,
        entries_remaining: *usize,
        bytes_remaining: *usize,
    ) !void {
        for (self.entries.items) |entry| {
            if (entry.seen) continue;
            if (result.items.len == maximum) return error.TransactionDependencyLimitExceeded;
            try appendDependencyCensusEntry(
                fs,
                allocator,
                result,
                entry.path,
                location,
                entry.preparation,
                entries_remaining,
                bytes_remaining,
            );
        }
    }

    fn take(self: *DependencyPreparationIndex, path: []const u8) ?TransactionDependencyPreparation {
        const index = self.indexes.get(path) orelse return null;
        self.entries.items[index].seen = true;
        return self.entries.items[index].preparation;
    }

    fn deinit(self: *DependencyPreparationIndex, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.indexes.deinit();
        self.arena.deinit();
    }
};

fn dependencyPreparationPath(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    location: ?TransactionDependencyLocation,
    recorded: []const u8,
) ![]const u8 {
    const control = std.fs.path.dirname(transactions_dir) orelse return error.InvalidPath;
    const mapped = if (location) |origin|
        try mapDependencyPath(allocator, control, origin, recorded)
    else
        try allocator.dupe(u8, recorded);
    const parent = std.fs.path.dirname(mapped) orelse return error.InvalidPath;
    const normalized_parent = try std.fs.path.resolve(allocator, &.{parent});
    const normalized_root = try std.fs.path.resolve(allocator, &.{transactions_dir});
    if (!std.mem.eql(u8, normalized_parent, normalized_root)) {
        return error.TransactionPathOutsideControlRoot;
    }
    return std.fs.path.join(allocator, &.{ transactions_dir, std.fs.path.basename(mapped) });
}

fn appendDependencyCensusEntry(
    fs: Fs,
    allocator: std.mem.Allocator,
    result: *std.ArrayList(DependencyCensusEntry),
    path: []const u8,
    location: ?TransactionDependencyLocation,
    supplied: ?TransactionDependencyPreparation,
    entries_remaining: *usize,
    bytes_remaining: *usize,
) !void {
    var from_preparation = false;
    const record = readDependencyRecord(fs, allocator, path, bytes_remaining) catch |err| value: {
        if (err != error.TransactionDependencyIncomplete) return err;
        const preparation = supplied orelse return err;
        if (preparation.preparation.record.len > bytes_remaining.*) {
            return error.TransactionDependencyLimitExceeded;
        }
        bytes_remaining.* -= preparation.preparation.record.len;
        try validateDependencyPreparationPrefix(
            fs,
            allocator,
            path,
            preparation.pin,
            entries_remaining,
            bytes_remaining,
        );
        from_preparation = true;
        break :value try parseReservedPreparation(allocator, preparation.preparation);
    };
    errdefer record.deinit(allocator);
    if (supplied) |preparation| {
        const actual = try transactionIntentDigest(
            allocator,
            record.transaction_id,
            record.owner,
            record.expected,
            record.writes,
        );
        if (!std.meta.eql(actual, preparation.preparation.intent_digest)) {
            return error.TransactionReservationMismatch;
        }
    }
    try validateAutomaticRecoveryRowBounds(record);
    const format = try transactionRecordFormat(allocator, record);
    try validateTransactionRecordIdentity(path, record, format);
    const control = try transactionControlRoot(path);
    var view = try DependencyRecordView.init(allocator, record, control, location);
    errdefer view.deinit();
    try validateTransactionRecordScopeWithMode(
        fs,
        allocator,
        control,
        path,
        view.record,
        format,
        .metadata_only,
    );
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try result.append(
        allocator,
        .{
            .path = owned,
            .record = record,
            .view = view,
            .from_preparation = from_preparation,
        },
    );
}

fn validateDependencyPreparationPrefix(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    pin: []const u8,
    entries_remaining: *usize,
    bytes_remaining: *usize,
) !void {
    var dir = fs.directory().openDir(
        fs.io,
        path,
        .{
            .iterate = true,
            .follow_symlinks = false,
        },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(fs.io);
    var iterator = dir.iterate();
    while (try iterator.next(fs.io)) |entry| {
        if (entries_remaining.* == 0) return error.TransactionDependencyLimitExceeded;
        entries_remaining.* -= 1;
        if (entry.kind != .file or !std.mem.eql(u8, entry.name, reservation_pin_leaf)) {
            return error.TransactionDependencyIncomplete;
        }
        const pin_path = try std.fs.path.join(allocator, &.{ path, reservation_pin_leaf });
        defer allocator.free(pin_path);
        const bytes = try readDependencyBytes(
            fs,
            allocator,
            pin_path,
            reservation_pin_max_bytes,
            bytes_remaining,
        );
        defer allocator.free(bytes);
        if (!std.mem.eql(u8, pin, bytes)) return error.TransactionReservationMismatch;
    }
}

fn duplicateDependencyPaths(allocator: std.mem.Allocator, paths: []const []const u8) ![][]const u8 {
    var result = try allocator.alloc([]const u8, paths.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |path| allocator.free(path);
        allocator.free(result);
    }
    for (paths, result) |path, *owned| {
        owned.* = try allocator.dupe(u8, path);
        initialized += 1;
    }
    return result;
}

fn retainDependencyTargetLock(
    fs: Fs,
    allocator: std.mem.Allocator,
    locks: *std.ArrayList(std.Io.File),
    path: []const u8,
    maximum: usize,
) !void {
    const advisory = try casAdvisoryPathAlloc(allocator, path);
    defer allocator.free(advisory);
    try retainDependencyLock(fs, allocator, locks, advisory, maximum);
}

fn retainDependencyLock(
    fs: Fs,
    allocator: std.mem.Allocator,
    locks: *std.ArrayList(std.Io.File),
    path: []const u8,
    maximum: usize,
) !void {
    if (locks.items.len == maximum) return error.TransactionDependencyLimitExceeded;
    try rejectSymlinkComponents(fs, path);
    const file = fs.directory().openFile(fs.io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .lock = .shared,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.TransactionDependencyCoordinationUnavailable,
        error.WouldBlock => return error.LockBusy,
        error.SymLinkLoop => return error.SymlinkComponent,
        else => return err,
    };
    errdefer file.close(fs.io);
    if ((try file.stat(fs.io)).kind != .file) return error.NotFile;
    try locks.append(allocator, file);
}

fn readDependencyRecord(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    remaining: *usize,
) !ParsedTransactionRecord {
    const path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(path);
    const bytes = readDependencyBytes(
        fs,
        allocator,
        path,
        transaction_record_max_bytes,
        remaining,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.TransactionDependencyIncomplete,
        else => return err,
    };
    defer allocator.free(bytes);
    return parseTransactionRecordBytes(allocator, bytes);
}

fn readDependencyBytes(
    fs: Fs,
    allocator: std.mem.Allocator,
    path: []const u8,
    maximum: usize,
    remaining: *usize,
) ![]u8 {
    const bytes = readRegularFileNoSymlink(
        fs,
        allocator,
        path,
        @min(remaining.*, maximum),
    ) catch |err| switch (err) {
        error.FileTooBig => return error.TransactionDependencyLimitExceeded,
        else => return err,
    };
    remaining.* -= bytes.len;
    return bytes;
}

pub fn enumerateTransactionDependencies(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    selected_paths: []const []const u8,
) !TransactionDependencies {
    return loadTransactionDependencies(fs, allocator, transaction_dir, selected_paths, null);
}

pub fn inspectTransactionDependencies(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) !TransactionDependencies {
    return loadTransactionDependencies(fs, allocator, transaction_dir, &.{}, true);
}

fn loadTransactionDependencies(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    selected_paths: []const []const u8,
    known_intersection: ?bool,
) !TransactionDependencies {
    const control_root = try transactionControlRoot(transaction_dir);
    _ = try pathRelativeToControlRoot(control_root, transaction_dir);
    try rejectSymlinkComponents(fs, transaction_dir);
    try validateDependencySelection(fs, allocator, control_root, selected_paths);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const parsed = try parseTransactionRecord(fs, allocator, record_path);
    defer parsed.deinit(allocator);
    return transactionDependenciesFromRecord(
        fs,
        allocator,
        transaction_dir,
        selected_paths,
        parsed,
        known_intersection,
    );
}

fn transactionDependenciesFromRecord(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    selected_paths: []const []const u8,
    parsed: ParsedTransactionRecord,
    known_intersection: ?bool,
) !TransactionDependencies {
    const control_root = try transactionControlRoot(transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    try validateAutomaticRecoveryRowBounds(parsed);
    const format = try transactionRecordFormat(allocator, parsed);
    try validateTransactionRecordScopeWithMode(
        fs,
        allocator,
        control_root,
        transaction_dir,
        parsed,
        format,
        .metadata_only,
    );
    const intersects = known_intersection orelse try transactionIntersectsSelection(
        fs,
        allocator,
        parsed,
        selected_paths,
    );
    const transaction_id = try allocator.dupe(u8, parsed.transaction_id);
    errdefer allocator.free(transaction_id);
    var entries: std.ArrayList(TransactionDependency) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }
    if (intersects) {
        try appendTransactionDependency(fs, allocator, &entries, .journal, record_path);
        const marker_path = try transactionCommitMarkerPathAlloc(allocator, transaction_dir);
        defer allocator.free(marker_path);
        try appendTransactionDependency(fs, allocator, &entries, .commit_marker, marker_path);
        if (try transactionHasReservationPin(fs, allocator, transaction_dir)) {
            const pin = try std.fs.path.join(
                allocator,
                &.{ transaction_dir, reservation_pin_leaf },
            );
            defer allocator.free(pin);
            try appendTransactionDependency(fs, allocator, &entries, .reservation_pin, pin);
        }
        for (parsed.expected) |expected| {
            try appendTransactionDependency(fs, allocator, &entries, .target, expected.path);
        }
        for (parsed.writes) |write| {
            const staged_path = try std.fs.path.join(
                allocator,
                &.{ transaction_dir, write.staged_ref },
            );
            defer allocator.free(staged_path);
            try appendTransactionDependency(fs, allocator, &entries, .staged, staged_path);
        }
    }
    return .{
        .transaction_id = transaction_id,
        .format = format,
        .state = parsed.state,
        .intersects = intersects,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn validateDependencySelection(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    selected_paths: []const []const u8,
) !void {
    if (selected_paths.len > transaction_dependency_max_selected_paths) {
        return error.TransactionRecoveryRequired;
    }
    var path_bytes_remaining = transaction_dependency_max_journal_bytes;
    for (selected_paths) |path| {
        if (path.len > path_bytes_remaining) return error.FileTooBig;
        path_bytes_remaining -= path.len;
        try rejectTransactionPath(fs, path, true);
        if (!try pathIsWithinDirectory(fs, allocator, control_root, path)) {
            return error.TransactionPathOutsideControlRoot;
        }
    }
    try validateTransactionPathsDisjoint(fs, allocator, .legacy, selected_paths);
}

fn transactionIntersectsSelection(
    fs: Fs,
    allocator: std.mem.Allocator,
    parsed: ParsedTransactionRecord,
    selected_paths: []const []const u8,
) !bool {
    var remaining: usize = 1024 * 1024;
    return transactionIntersectsSelectionBounded(fs, allocator, parsed, selected_paths, &remaining);
}

fn transactionIntersectsSelectionBounded(
    fs: Fs,
    allocator: std.mem.Allocator,
    parsed: ParsedTransactionRecord,
    selected_paths: []const []const u8,
    remaining: *usize,
) !bool {
    var identities = HostPathIdentityContext.init(fs, allocator);
    defer identities.deinit();
    for (selected_paths) |selected| {
        const canonical = try dependencyCanonicalPath(&identities, selected);
        defer allocator.free(canonical);
        const selected_stat = try statRegularFileNoSymlink(fs, selected);
        for (parsed.expected) |expected| {
            if (remaining.* == 0) return error.TransactionDependencyLimitExceeded;
            remaining.* -= 1;
            const candidate = try dependencyCanonicalPath(&identities, expected.path);
            defer allocator.free(candidate);
            if (std.mem.eql(u8, canonical, candidate)) return true;
            if (selected_stat) |selected_file| {
                if (try statRegularFileNoSymlink(fs, expected.path)) |expected_file| {
                    if (selected_file.inode == expected_file.inode and
                        try dependencyPathsShareDevice(fs, selected, expected.path)) return true;
                }
            }
            if (try transactionPathsAliasOrOverlap(fs, allocator, .legacy, canonical, candidate)) {
                return true;
            }
        }
    }
    return false;
}

fn dependencyPathsShareDevice(fs: Fs, left: []const u8, right: []const u8) !bool {
    const left_parent = std.fs.path.dirname(left) orelse ".";
    const right_parent = std.fs.path.dirname(right) orelse ".";
    if (std.mem.eql(u8, left_parent, right_parent)) return true;
    const a = try fs.directory().openDir(fs.io, left_parent, .{ .follow_symlinks = false });
    defer a.close(fs.io);
    const b = try fs.directory().openDir(fs.io, right_parent, .{ .follow_symlinks = false });
    defer b.close(fs.io);
    const a_identity = try filesystem.openDirectoryIdentity(fs.io, a);
    const b_identity = try filesystem.openDirectoryIdentity(fs.io, b);
    return a_identity.device == b_identity.device;
}

fn dependencyCanonicalPath(identities: *HostPathIdentityContext, path: []const u8) ![]u8 {
    const normalized = try std.fs.path.resolve(identities.allocator, &.{path});
    defer identities.allocator.free(normalized);
    if (identities.fs.isPinned() and !std.fs.path.isAbsolute(normalized)) {
        return identities.allocator.dupe(u8, normalized);
    }
    const parent_path = std.fs.path.dirname(normalized) orelse ".";
    const parent = if (std.mem.eql(u8, parent_path, "."))
        try identities.allocator.dupe(u8, ".")
    else
        try identities.canonicalAlloc(parent_path);
    defer identities.allocator.free(parent);
    return std.fs.path.join(identities.allocator, &.{ parent, std.fs.path.basename(normalized) });
}

fn appendTransactionDependency(
    fs: Fs,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(TransactionDependency),
    kind: @FieldType(TransactionDependency, "kind"),
    path: []const u8,
) !void {
    try rejectSymlinkComponents(fs, path);
    const present = (try statRegularFileNoSymlink(fs, path)) != null;
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try entries.append(allocator, .{ .kind = kind, .path = owned, .present = present });
}

fn inspectTransactionWithBudget(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    hash_bytes_remaining: *usize,
) !RecoveryStatus {
    const control_root = try transactionControlRoot(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const commit_marker_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "commit.json" },
    );
    defer allocator.free(commit_marker_path);
    const parsed = try parseTransactionRecord(fs, allocator, record_path);
    defer parsed.deinit(allocator);
    const format = try transactionRecordFormat(allocator, parsed);
    try validateTransactionRecordScope(
        fs,
        allocator,
        control_root,
        transaction_dir,
        parsed,
        format,
    );
    const preflight = try inspectValidatedTransactionWithBudget(
        fs,
        allocator,
        control_root,
        commit_marker_path,
        parsed,
        format,
        hash_bytes_remaining,
    );
    if (preflight.write_states) |states| allocator.free(states);
    return preflight.status;
}

const RecoveryWriteState = enum {
    published,
    expected,
    missing,
};

const RecoveryWritePreflight = struct {
    states: []RecoveryWriteState,
    published_count: usize,

    fn deinit(
        self: RecoveryWritePreflight,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.states);
    }
};

const RecoveryPreflight = struct {
    status: RecoveryStatus,
    write_states: ?[]RecoveryWriteState = null,
    published_count: usize = 0,

    fn deinit(
        self: RecoveryPreflight,
        allocator: std.mem.Allocator,
    ) void {
        self.status.deinit(allocator);
        if (self.write_states) |states| allocator.free(states);
    }
};

const RecoverySelection = struct {
    decision: RecoveryDecision,
    reason: []const u8,
};

fn selectRecovery(
    parsed: ParsedTransactionRecord,
    format: TransactionRecordFormat,
    published_count: usize,
) RecoverySelection {
    if (parsed.state == .committed) {
        return if (published_count == parsed.writes.len)
            .{
                .decision = .finish_commit,
                .reason = "committed-marker-required",
            }
        else
            .{
                .decision = .manual_recovery_required,
                .reason = "committed-digest-disagreement",
            };
    }
    if (published_count == parsed.writes.len) {
        return .{
            .decision = .finish_commit,
            .reason = "all-digests-published",
        };
    }
    if (format == .legacy) {
        return if (published_count == 0)
            .{
                .decision = .roll_back_unpublished,
                .reason = "legacy-no-digests-published",
            }
        else
            .{
                .decision = .manual_recovery_required,
                .reason = "legacy-mixed-published-digests",
            };
    }
    return .{
        .decision = .finish_commit,
        .reason = "roll-forward-required",
    };
}

fn classifyRecoveryWrites(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    writes: []const TransactionWrite,
    expected: []const TransactionExpected,
    hash_bytes_remaining: *usize,
) !?RecoveryWritePreflight {
    var expected_digests = try transactionExpectedDigestIndex(
        allocator,
        expected,
    );
    defer expected_digests.deinit();
    const states = try allocator.alloc(RecoveryWriteState, writes.len);
    errdefer allocator.free(states);
    var published_count: usize = 0;
    for (writes, 0..) |write, index| {
        _ = try pathRelativeToControlRoot(control_root, write.path);
        var target = try TransactionTarget.init(fs, control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        const digest = digestRecoveryFileAtAlloc(
            fs,
            allocator,
            &target.dir,
            target.base,
            hash_bytes_remaining,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const expected_digest = expected_digests.get(
                    write.path,
                ) orelse return error.TransactionCorrupt;
                if (expected_digest.len != 0) {
                    allocator.free(states);
                    return null;
                }
                states[index] = .missing;
                continue;
            },
            else => return err,
        };
        defer allocator.free(digest);
        if (std.mem.eql(u8, digest, write.digest_after)) {
            states[index] = .published;
            published_count += 1;
            continue;
        }
        const expected_digest = expected_digests.get(write.path) orelse
            return error.TransactionCorrupt;
        if (!std.mem.eql(u8, digest, expected_digest)) {
            allocator.free(states);
            return null;
        }
        states[index] = .expected;
    }
    return .{
        .states = states,
        .published_count = published_count,
    };
}

fn inspectValidatedTransactionWithBudget(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    commit_marker_path: []const u8,
    parsed: ParsedTransactionRecord,
    format: TransactionRecordFormat,
    hash_bytes_remaining: *usize,
) !RecoveryPreflight {
    if (parsed.state == .preparing) {
        return .{ .status = try makeRecoveryStatus(
            allocator,
            parsed.transaction_id,
            .roll_back_unpublished,
            "preparing-stage-cleanup-required",
        ) };
    }
    if (parsed.state == .committed and fileExists(fs, commit_marker_path)) {
        return .{ .status = try makeRecoveryStatus(
            allocator,
            parsed.transaction_id,
            .already_committed,
            "commit-marker-present",
        ) };
    }
    if (parsed.state == .aborted) {
        return .{ .status = try makeRecoveryStatus(
            allocator,
            parsed.transaction_id,
            .roll_back_unpublished,
            "already-aborted",
        ) };
    }
    const classified = (try classifyRecoveryWrites(
        fs,
        allocator,
        control_root,
        parsed.writes,
        parsed.expected,
        hash_bytes_remaining,
    )) orelse return .{ .status = try makeRecoveryStatus(
        allocator,
        parsed.transaction_id,
        .manual_recovery_required,
        "published-digest-disagreement",
    ) };
    errdefer classified.deinit(allocator);
    const selection = selectRecovery(
        parsed,
        format,
        classified.published_count,
    );
    return .{
        .status = try makeRecoveryStatus(
            allocator,
            parsed.transaction_id,
            selection.decision,
            selection.reason,
        ),
        .write_states = classified.states,
        .published_count = classified.published_count,
    };
}

fn transactionExpectedRowsEqual(
    left: []const TransactionExpected,
    right: []const TransactionExpected,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path) or
            !std.mem.eql(u8, a.digest, b.digest) or
            a.sequence != b.sequence)
        {
            return false;
        }
    }
    return true;
}

fn transactionWriteRowsEqual(
    left: []const TransactionWrite,
    right: []const TransactionWrite,
    preliminary_state: TransactionState,
    custodied_state: TransactionState,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path) or
            !std.mem.eql(u8, a.staged_ref, b.staged_ref) or
            a.sequence_after != b.sequence_after)
        {
            return false;
        }
        if (std.mem.eql(u8, a.digest_after, b.digest_after)) continue;
        if (preliminary_state != .preparing or
            custodied_state == .preparing or
            a.digest_after.len != 0 or
            b.digest_after.len == 0)
        {
            return false;
        }
    }
    return true;
}

fn transactionLockRowsEqual(
    left: []const LeaseLock,
    right: []const LeaseLock,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!leaseWitnessesEqual(a, b)) return false;
    }
    return true;
}

fn recoveryRecordCustodyEqual(
    preliminary: ParsedTransactionRecord,
    custodied: ParsedTransactionRecord,
) bool {
    return std.mem.eql(
        u8,
        preliminary.transaction_id,
        custodied.transaction_id,
    ) and
        ownersEqual(preliminary.owner, custodied.owner) and
        preliminary.format_hint == custodied.format_hint and
        preliminary.bounded_rows == custodied.bounded_rows and
        std.mem.eql(u8, preliminary.created_at, custodied.created_at) and
        recoveryStateTransitionAllowed(
            preliminary.state,
            custodied.state,
        ) and
        transactionExpectedRowsEqual(
            preliminary.expected,
            custodied.expected,
        ) and
        transactionWriteRowsEqual(
            preliminary.writes,
            custodied.writes,
            preliminary.state,
            custodied.state,
        ) and
        transactionLockRowsEqual(
            preliminary.embedded_locks,
            custodied.embedded_locks,
        );
}

fn recoveryStateTransitionAllowed(
    preliminary: TransactionState,
    custodied: TransactionState,
) bool {
    if (preliminary == custodied) return true;
    return switch (preliminary) {
        .preparing => switch (custodied) {
            .prepared, .committing, .committed => true,
            else => false,
        },
        .prepared => switch (custodied) {
            .committing, .committed => true,
            else => false,
        },
        .committing => custodied == .committed,
        .committed, .aborted, .recovery_required => false,
    };
}

fn parseCustodiedRecoveryRecord(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    transaction_dir: []const u8,
    record_path: []const u8,
    preliminary: ParsedTransactionRecord,
    expected_format: TransactionRecordFormat,
) !ParsedTransactionRecord {
    const custodied = try parseTransactionRecord(fs, allocator, record_path);
    errdefer custodied.deinit(allocator);
    try validateAutomaticRecoveryRowBounds(custodied);
    const format = try transactionRecordFormat(allocator, custodied);
    if (format != expected_format or
        !recoveryRecordCustodyEqual(preliminary, custodied))
    {
        return error.TransactionCorrupt;
    }
    try validateTransactionRecordScope(
        fs,
        allocator,
        control_root,
        transaction_dir,
        custodied,
        format,
    );
    return custodied;
}

pub fn recoverTransaction(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) !RecoveryReceipt {
    return recoverTransactionWithOptions(
        fs,
        allocator,
        transaction_dir,
        .{},
    );
}

pub fn recoverTransactionWithOptions(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    options: TransactionRecoveryOptions,
) !RecoveryReceipt {
    var summary: TransactionRecoverySummary = .{};
    return recoverTransactionWithOptionsAccumulating(
        fs,
        allocator,
        transaction_dir,
        options,
        &summary,
    );
}

pub fn recoverTransactionWithOptionsAccumulating(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    options: TransactionRecoveryOptions,
    summary: *TransactionRecoverySummary,
) !RecoveryReceipt {
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse
        return error.InvalidPath;
    var storage_mutated = summary.storage_mutated;
    var recovery_lock = try acquireTransactionRecoveryLock(
        fs,
        allocator,
        transactions_dir,
        &storage_mutated,
    );
    defer recovery_lock.close(fs.io);
    var hash_bytes_remaining = transaction_recovery_hash_max_bytes;
    var receipt = recoverTransactionWithOptionsAccumulatingLocked(
        fs,
        allocator,
        transaction_dir,
        options,
        &storage_mutated,
        &hash_bytes_remaining,
    ) catch |err| {
        summary.storage_mutated = storage_mutated;
        return err;
    };
    receipt.storage_mutated = storage_mutated;
    summary.storage_mutated = storage_mutated;
    summary.transaction_count += 1;
    return receipt;
}

fn recoverTransactionWithOptionsAccumulatingLocked(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    options: TransactionRecoveryOptions,
    storage_mutated: *bool,
    hash_bytes_remaining: *usize,
) !RecoveryReceipt {
    return recoverTransactionControlledLocked(
        fs,
        allocator,
        transaction_dir,
        options,
        storage_mutated,
        hash_bytes_remaining,
        null,
    );
}

pub fn recoverTransactionWithPublication(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    hooks: TransactionPublicationHooks,
) !RecoveryReceipt {
    if (hooks.preparation) |preparation| {
        try validatePublicationRoot(fs, transaction_dir, preparation.root_identity);
    }
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse return error.InvalidPath;
    var storage_mutated = false;
    var lock = try acquireTransactionRecoveryLock(
        fs,
        allocator,
        transactions_dir,
        &storage_mutated,
    );
    defer lock.close(fs.io);
    var hash_budget = transaction_recovery_hash_max_bytes;
    if (hooks.preparation) |preparation| try restoreReservedPreparingRecord(
        fs,
        allocator,
        transaction_dir,
        hooks.expected_pin orelse return error.TransactionReservationMismatch,
        preparation,
        &storage_mutated,
        &hash_budget,
    );
    return recoverTransactionControlledLocked(
        fs,
        allocator,
        transaction_dir,
        .{},
        &storage_mutated,
        &hash_budget,
        hooks,
    );
}

fn restoreReservedPreparingRecord(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    pin: []const u8,
    preparation: TransactionPreparation,
    storage_mutated: *bool,
    hash_budget: *usize,
) !void {
    try validatePublicationRoot(fs, transaction_dir, preparation.root_identity);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    if (try statRegularFileNoSymlink(fs, record_path) != null) return;
    const parsed = try parseReservedPreparation(allocator, preparation);
    defer parsed.deinit(allocator);
    const root = try transactionControlRoot(transaction_dir);
    try validateTransactionRecordScope(fs, allocator, root, transaction_dir, parsed, .current);
    var locks = try acquireTransactionRecoveryLocks(
        fs,
        allocator,
        parsed.expected,
        storage_mutated,
    );
    defer locks.deinit(allocator);
    var no_writes = std.StringHashMap(void).init(allocator);
    defer no_writes.deinit();
    try validateReadOnlyRecoveryTargets(
        fs,
        allocator,
        root,
        parsed.expected,
        no_writes,
        hash_budget,
    );
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse return error.InvalidPath;
    var journal = try acquireTransactionJournalLock(
        fs,
        allocator,
        transactions_dir,
        storage_mutated,
    );
    defer journal.close(fs.io);
    try validatePublicationRoot(fs, transaction_dir, preparation.root_identity);
    if (try statRegularFileNoSymlink(fs, record_path) != null) {
        return error.TransactionRecoveryRequired;
    }
    try ensureReservedPreparingPrefix(fs, allocator, transaction_dir, pin);
    try writeTextCreateNew(fs, allocator, record_path, preparation.record, .{});
    storage_mutated.* = true;
    try syncDirectoryPath(fs, transaction_dir);
    try syncDirectoryPath(fs, transactions_dir);
}

fn parseReservedPreparation(
    allocator: std.mem.Allocator,
    preparation: TransactionPreparation,
) !ParsedTransactionRecord {
    const parsed = try parseTransactionRecordBytes(allocator, preparation.record);
    errdefer parsed.deinit(allocator);
    try validateAutomaticRecoveryRowBounds(parsed);
    if (parsed.state != .preparing or try transactionRecordFormat(allocator, parsed) != .current) {
        return error.TransactionReservationMismatch;
    }
    const intent = try transactionIntentDigest(
        allocator,
        parsed.transaction_id,
        parsed.owner,
        parsed.expected,
        parsed.writes,
    );
    if (!std.meta.eql(intent, preparation.intent_digest)) {
        return error.TransactionReservationMismatch;
    }
    return parsed;
}

fn ensureReservedPreparingPrefix(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    pin: []const u8,
) !void {
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    var dir = try fs.directory().openDir(fs.io, transaction_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(fs.io);
    var iterator = dir.iterate();
    var has_pin = false;
    while (try iterator.next(fs.io)) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.name, reservation_pin_leaf)) {
            return error.TransactionRecoveryRequired;
        }
        has_pin = true;
    }
    if (has_pin) return validateReservationPin(fs, allocator, transaction_dir, pin);
    const path = try std.fs.path.join(allocator, &.{ transaction_dir, reservation_pin_leaf });
    defer allocator.free(path);
    try writeTextCreateNew(fs, allocator, path, pin, .{});
}

fn recoverTransactionControlledLocked(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    options: TransactionRecoveryOptions,
    storage_mutated: *bool,
    hash_bytes_remaining: *usize,
    hooks: ?TransactionPublicationHooks,
) !RecoveryReceipt {
    const control_root = try transactionControlRoot(transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const commit_marker_path = try transactionCommitMarkerPathAlloc(allocator, transaction_dir);
    defer allocator.free(commit_marker_path);
    var parsed = try parseTransactionRecord(fs, allocator, record_path);
    defer parsed.deinit(allocator);
    try validateAutomaticRecoveryRowBounds(parsed);
    const format = try transactionRecordFormat(allocator, parsed);
    const recovery: TransactionRecovery = .{
        .fs = fs,
        .allocator = allocator,
        .transaction_dir = transaction_dir,
        .control_root = control_root,
        .record_path = record_path,
        .commit_marker_path = commit_marker_path,
        .parsed = &parsed,
        .format = format,
        .storage_mutated = storage_mutated,
        .hash_bytes_remaining = hash_bytes_remaining,
        .publication = hooks,
    };
    return recovery.run(options);
}

// All paths and parsed fields borrow the entry function's owners. Custody refresh
// replaces that function's parsed record; no borrowed field escapes recovery.

const TransactionRecovery = struct {
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    control_root: []const u8,
    record_path: []const u8,
    commit_marker_path: []const u8,
    parsed: *ParsedTransactionRecord,
    format: TransactionRecordFormat,
    storage_mutated: *bool,
    hash_bytes_remaining: *usize,
    publication: ?TransactionPublicationHooks = null,

    fn run(self: TransactionRecovery, options: TransactionRecoveryOptions) !RecoveryReceipt {
        const fs = self.fs;
        if (self.publication) |hooks| {
            if (self.format != .current) return error.TransactionReservationMismatch;
            try validateReservationPin(
                fs,
                self.allocator,
                self.transaction_dir,
                hooks.expected_pin orelse return error.TransactionReservationMismatch,
            );
            if (self.parsed.state == .committed and fileExists(fs, self.commit_marker_path)) {
                return self.recognizeReservedCommit();
            }
        } else if (try transactionHasReservationEvidence(
            fs,
            self.allocator,
            self.transaction_dir,
        )) {
            return self.recognizeReservedCommit();
        }
        try validateTransactionRecordScope(
            fs,
            self.allocator,
            self.control_root,
            self.transaction_dir,
            self.parsed.*,
            self.format,
        );
        const authority = if (self.format == .legacy)
            options.legacy_fencing_authority orelse return error.TransactionRecoveryRequired
        else
            null;
        if (authority) |selected| {
            try validateLegacyFencingAuthorityScope(
                fs,
                self.allocator,
                self.transaction_dir,
                self.parsed.*,
                selected,
            );
        }
        const counter_path = if (authority) |selected|
            legacyFencingCounterPath(selected)
        else
            null;
        if (self.format == .legacy and self.parsed.state == .committed and
            fileExists(fs, self.commit_marker_path))
        {
            return self.recoverTerminal(counter_path);
        }
        return self.recoverNonTerminal(counter_path);
    }

    fn recognizeReservedCommit(self: TransactionRecovery) !RecoveryReceipt {
        if (self.format != .current or self.parsed.state != .committed) {
            return error.TransactionReservationRequired;
        }
        const parent = std.fs.path.dirname(self.transaction_dir) orelse return error.InvalidPath;
        var lock = try acquireTransactionJournalLock(
            self.fs,
            self.allocator,
            parent,
            self.storage_mutated,
        );
        defer lock.close(self.fs.io);
        const current = try parseTransactionRecord(self.fs, self.allocator, self.record_path);
        defer current.deinit(self.allocator);
        if (!recoveryRecordCustodyEqual(self.parsed.*, current)) return error.TransactionCorrupt;
        try validateTransactionRecordScopeWithMode(
            self.fs,
            self.allocator,
            self.control_root,
            self.transaction_dir,
            current,
            .current,
            .metadata_only,
        );
        _ = try transactionTerminalMetadataBytes(
            self.fs,
            self.allocator,
            self.transaction_dir,
            .committed,
        );
        if (self.publication) |hooks| {
            const terminal = try measureTransactionTerminal(
                self.fs,
                self.allocator,
                self.transaction_dir,
                hooks.expected_pin.?,
                .committed,
            );
            try hooks.acquire(hooks.context, terminal.view);
            defer hooks.release(hooks.context);
            try hooks.settled(hooks.context, terminal);
        }
        return makeRecoveryReceipt(
            self.allocator,
            current.transaction_id,
            .already_committed,
            reserved_committed_result,
        );
    }

    fn acquireLegacyLeases(self: TransactionRecovery, counter_path: ?[]const u8) ![]LeaseLock {
        const fs = self.fs;
        return acquireLegacyTransactionRecoveryLeases(
            fs,
            self.allocator,
            self.parsed.expected,
            self.parsed.owner,
            self.parsed.transaction_id,
            counter_path,
            self.storage_mutated,
        );
    }

    fn cleanupLegacyLeases(self: TransactionRecovery, leases: *[]LeaseLock) void {
        const fs = self.fs;
        releaseLegacyTransactionRecoveryLeases(
            fs,
            self.allocator,
            leases,
            self.storage_mutated,
        ) catch |release_error| {
            fs_authority.warn(
                fs.io,
                "recovery lease cleanup failed for {s}: {s}; inspect recovery locks",
                .{
                    self.transaction_dir,
                    @errorName(release_error),
                },
            );
        };
    }

    fn refreshCustodiedRecord(self: TransactionRecovery) !void {
        const fs = self.fs;
        const custodied = try parseCustodiedRecoveryRecord(
            fs,
            self.allocator,
            self.control_root,
            self.transaction_dir,
            self.record_path,
            self.parsed.*,
            self.format,
        );
        self.parsed.deinit(self.allocator);
        self.parsed.* = custodied;
    }

    fn recoverTerminal(self: TransactionRecovery, counter_path: ?[]const u8) !RecoveryReceipt {
        const fs = self.fs;
        try ensureLegacyTerminalLeasesQuiescent(fs, self.allocator, self.parsed.expected);
        var leases = try self.acquireLegacyLeases(counter_path);
        var leases_pending = true;
        defer if (leases_pending) self.cleanupLegacyLeases(&leases);
        var locks = try acquireTransactionRecoveryLocks(
            fs,
            self.allocator,
            self.parsed.expected,
            self.storage_mutated,
        );
        var locks_pending = true;
        defer if (locks_pending) locks.deinit(self.allocator);
        try self.refreshCustodiedRecord();
        try self.validateTerminalPublication();
        try syncLegacyTerminalEffects(
            fs,
            self.control_root,
            self.transaction_dir,
            self.parsed.expected,
        );
        locks_pending = false;
        try locks.releaseDurable(self.allocator, self.storage_mutated);
        leases_pending = false;
        try releaseLegacyTransactionRecoveryLeases(
            fs,
            self.allocator,
            &leases,
            self.storage_mutated,
        );
        return makeRecoveryReceipt(
            self.allocator,
            self.parsed.transaction_id,
            .already_committed,
            "already_committed",
        );
    }

    fn validateTerminalPublication(self: TransactionRecovery) !void {
        const fs = self.fs;
        if (self.parsed.state != .committed or !fileExists(fs, self.commit_marker_path)) {
            return error.TransactionRecoveryRequired;
        }
        const published = (try transactionPublishedCount(
            fs,
            self.allocator,
            self.control_root,
            self.parsed.writes,
            self.parsed.expected,
            self.hash_bytes_remaining,
        )) orelse return error.TransactionRecoveryRequired;
        if (published != self.parsed.writes.len) return error.TransactionRecoveryRequired;
    }

    fn recoverNonTerminal(self: TransactionRecovery, counter_path: ?[]const u8) !RecoveryReceipt {
        const fs = self.fs;
        var leases = if (self.format == .legacy)
            try self.acquireLegacyLeases(counter_path)
        else
            null;
        var leases_pending = leases != null;
        defer if (leases_pending) {
            if (leases) |*pending| self.cleanupLegacyLeases(pending);
        };
        var locks = try acquireTransactionRecoveryLocks(
            fs,
            self.allocator,
            self.parsed.expected,
            self.storage_mutated,
        );
        var locks_pending = true;
        defer if (locks_pending) locks.deinit(self.allocator);
        try self.refreshCustodiedRecord();
        const preflight = try inspectValidatedTransactionWithBudget(
            fs,
            self.allocator,
            self.control_root,
            self.commit_marker_path,
            self.parsed.*,
            self.format,
            self.hash_bytes_remaining,
        );
        defer preflight.deinit(self.allocator);
        try self.acquirePublication(preflight);
        defer if (self.publication) |hooks| hooks.release(hooks.context);
        const result = try self.realizeDecision(preflight);
        try self.settlePublication(preflight.status.decision);
        if (leases) |*pending| {
            leases_pending = false;
            try releaseLegacyTransactionRecoveryLeases(
                fs,
                self.allocator,
                pending,
                self.storage_mutated,
            );
        }
        locks_pending = false;
        try locks.releaseDurable(self.allocator, self.storage_mutated);
        return makeRecoveryReceipt(
            self.allocator,
            self.parsed.transaction_id,
            preflight.status.decision,
            result,
        );
    }

    fn acquirePublication(self: TransactionRecovery, preflight: RecoveryPreflight) !void {
        if (self.publication) |hooks| {
            try self.validateGuardedRecovery(preflight);
            try hooks.acquire(hooks.context, .{
                .transaction_id = self.parsed.transaction_id,
                .transaction_dir = self.transaction_dir,
                .intent_digest = try transactionIntentDigest(
                    self.allocator,
                    self.parsed.transaction_id,
                    self.parsed.owner,
                    self.parsed.expected,
                    self.parsed.writes,
                ),
                .root_identity = try transactionRootIdentity(self.fs, self.transaction_dir),
            });
        }
    }

    fn settlePublication(self: TransactionRecovery, decision: RecoveryDecision) !void {
        if (self.publication) |hooks| {
            try hooks.settled(hooks.context, try measureTransactionTerminal(
                self.fs,
                self.allocator,
                self.transaction_dir,
                hooks.expected_pin.?,
                if (decision == .roll_back_unpublished) .aborted else .committed,
            ));
        }
    }

    fn realizeDecision(self: TransactionRecovery, preflight: RecoveryPreflight) ![]const u8 {
        const fs = self.fs;
        switch (preflight.status.decision) {
            .already_committed => return "already_committed",
            .finish_commit => {
                try self.finishCommit(preflight);
                return "committed";
            },
            .roll_back_unpublished => {
                try deleteReservedTransactionStages(
                    fs,
                    self.transaction_dir,
                    self.parsed.writes,
                    self.storage_mutated,
                );
                try self.persistState(.aborted);
                return "aborted";
            },
            .manual_recovery_required => return error.TransactionRecoveryRequired,
        }
    }

    fn persistState(self: TransactionRecovery, state: TransactionState) !void {
        const fs = self.fs;
        const record = try renderParsedTransactionRecordAlloc(self.allocator, self.parsed.*, state);
        defer self.allocator.free(record);
        try writeTextAtomic(fs, self.allocator, self.record_path, record);
        self.storage_mutated.* = true;
        try syncDirectoryPath(fs, self.transaction_dir);
    }

    fn finishCommit(self: TransactionRecovery, preflight: RecoveryPreflight) !void {
        const fs = self.fs;
        const write_states = preflight.write_states orelse return error.TransactionCorrupt;
        if (self.publication == null) try validateRollForwardTransaction(
            fs,
            self.allocator,
            self.control_root,
            self.transaction_dir,
            self.parsed.*,
            write_states,
            preflight.published_count,
            self.hash_bytes_remaining,
        );
        if (self.publication != null) {
            try rollForwardValidatedTransaction(
                fs,
                self.control_root,
                self.transaction_dir,
                self.parsed.*,
                write_states,
                self.storage_mutated,
            );
        } else try rollForwardTransaction(
            fs,
            self.control_root,
            self.transaction_dir,
            self.parsed.*,
            write_states,
            self.storage_mutated,
            self.hash_bytes_remaining,
        );
        try self.persistState(.committed);
        var marker_created = true;
        writeTransactionCommitMarker(
            fs,
            self.allocator,
            self.transaction_dir,
            self.commit_marker_path,
            if (self.publication) |hooks| hooks.expected_pin else null,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => marker_created = false,
            else => return err,
        };
        if (marker_created) self.storage_mutated.* = true;
        try syncDirectoryPath(fs, self.transaction_dir);
    }

    fn validateGuardedRecovery(self: TransactionRecovery, preflight: RecoveryPreflight) !void {
        switch (preflight.status.decision) {
            .finish_commit => try validateRollForwardTransaction(
                self.fs,
                self.allocator,
                self.control_root,
                self.transaction_dir,
                self.parsed.*,
                preflight.write_states orelse return error.TransactionCorrupt,
                preflight.published_count,
                self.hash_bytes_remaining,
            ),
            .already_committed => try validateReservedCommitMarker(
                self.fs,
                self.allocator,
                self.transaction_dir,
            ),
            .roll_back_unpublished => {
                var no_writes = std.StringHashMap(void).init(self.allocator);
                defer no_writes.deinit();
                try validateReadOnlyRecoveryTargets(
                    self.fs,
                    self.allocator,
                    self.control_root,
                    self.parsed.expected,
                    no_writes,
                    self.hash_bytes_remaining,
                );
            },
            .manual_recovery_required => return error.TransactionRecoveryRequired,
        }
    }
};

pub fn recoverAndCompactTransactions(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
) !void {
    _ = try recoverAndCompactTransactionsWithOptions(
        fs,
        allocator,
        transactions_dir,
        .{},
    );
}

pub fn recoverAndCompactTransactionsWithOptions(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    options: TransactionRecoveryOptions,
) !TransactionRecoverySummary {
    var summary: TransactionRecoverySummary = .{};
    try recoverAndCompactTransactionsAccumulating(
        fs,
        allocator,
        transactions_dir,
        options,
        &summary,
    );
    return summary;
}

pub fn recoverAndCompactTransactionsAccumulating(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    options: TransactionRecoveryOptions,
    summary: *TransactionRecoverySummary,
) !void {
    var hash_bytes_remaining = transaction_recovery_hash_max_bytes;
    return recoverAndCompactTransactionsAccumulatingWithHashBudget(
        fs,
        allocator,
        transactions_dir,
        options,
        summary,
        &hash_bytes_remaining,
    );
}

fn recoverAndCompactTransactionsAccumulatingWithHashBudget(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    options: TransactionRecoveryOptions,
    summary: *TransactionRecoverySummary,
    hash_bytes_remaining: *usize,
) !void {
    const max_entries: usize = 4096;
    const max_record_bytes: usize = 16 * 1024 * 1024;
    var dir = try fs.directory().openDir(fs.io, transactions_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(fs.io);
    var recovery_lock = try acquireTransactionRecoveryLock(
        fs,
        allocator,
        transactions_dir,
        &summary.storage_mutated,
    );
    defer recovery_lock.close(fs.io);
    var entries: usize = 0;
    var record_bytes: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(fs.io)) |entry| {
        if (entry.kind == .sym_link) return error.SymlinkComponent;
        if (entry.kind != .directory) continue;
        entries = std.math.add(usize, entries, 1) catch return error.TooManyFiles;
        if (entries > max_entries) return error.TooManyFiles;
        const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, entry.name });
        defer allocator.free(transaction_dir);
        const stat = try statOrReclaimRecoveryJournal(
            fs,
            allocator,
            transactions_dir,
            transaction_dir,
            &dir,
            entry.name,
            summary,
        ) orelse continue;
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) return error.TransactionCorrupt;
        record_bytes = std.math.add(
            usize,
            record_bytes,
            std.math.cast(usize, stat.size) orelse return error.FileTooBig,
        ) catch return error.FileTooBig;
        if (record_bytes > max_record_bytes) return error.FileTooBig;
        try recoverAndMaybeCompactTransaction(
            fs,
            allocator,
            transactions_dir,
            transaction_dir,
            &dir,
            options,
            summary,
            hash_bytes_remaining,
        );
        summary.transaction_count += 1;
    }
}

fn recoverAndMaybeCompactTransaction(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    transaction_dir: []const u8,
    directory: *const std.Io.Dir,
    options: TransactionRecoveryOptions,
    summary: *TransactionRecoverySummary,
    hash_budget: *usize,
) !void {
    const receipt = try recoverTransactionWithOptionsAccumulatingLocked(
        fs,
        allocator,
        transaction_dir,
        options,
        &summary.storage_mutated,
        hash_budget,
    );
    defer receipt.deinit(allocator);
    if (std.mem.eql(u8, receipt.result, reserved_committed_result)) return;
    try compactRecoveredTransaction(
        fs,
        allocator,
        transactions_dir,
        transaction_dir,
        directory,
        &summary.storage_mutated,
    );
}

fn statOrReclaimRecoveryJournal(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    transaction_dir: []const u8,
    dir: *std.Io.Dir,
    entry_name: []const u8,
    summary: *TransactionRecoverySummary,
) !?std.Io.File.Stat {
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    var journal_lock = try acquireTransactionJournalLock(
        fs,
        allocator,
        transactions_dir,
        &summary.storage_mutated,
    );
    defer journal_lock.close(fs.io);
    return fs.directory().statFile(
        fs.io,
        record_path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => {
            try reclaimRecordlessTransaction(fs, dir, entry_name, summary);
            return null;
        },
        else => return err,
    };
}

fn reclaimRecordlessTransaction(
    fs: Fs,
    dir: *std.Io.Dir,
    entry_name: []const u8,
    summary: *TransactionRecoverySummary,
) !void {
    const current_id = isGeneratedTransactionId(entry_name);
    const legacy_id = isLegacyTransactionId(entry_name);
    if (!current_id and !legacy_id) return error.TransactionCorrupt;
    if (!current_id) return error.TransactionRecoveryRequired;
    var removed = true;
    dir.deleteDir(fs.io, entry_name) catch |delete_err| switch (delete_err) {
        error.FileNotFound => removed = false,
        error.DirNotEmpty => return error.TransactionRecoveryRequired,
        else => return delete_err,
    };
    if (removed) {
        summary.storage_mutated = true;
        try syncDirectoryHandle(fs, dir);
    }
    summary.transaction_count += 1;
}

fn compactRecoveredTransaction(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    transaction_dir: []const u8,
    transactions: *const std.Io.Dir,
    storage_mutated: *bool,
) !void {
    var journal_lock = try acquireTransactionJournalLock(
        fs,
        allocator,
        transactions_dir,
        storage_mutated,
    );
    defer journal_lock.close(fs.io);
    if (try transactionHasReservationEvidence(fs, allocator, transaction_dir)) {
        return error.TransactionReservationRequired;
    }
    const stat = fs.directory().statFile(
        fs.io,
        transaction_dir,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .directory) return error.TransactionCorrupt;
    // Recursive removal can mutate a strict prefix before reporting failure.
    storage_mutated.* = true;
    try fs.directory().deleteTree(
        fs.io,
        transaction_dir,
    );
    try syncDirectoryHandle(fs, transactions);
}

fn legacyFencingCounterPath(
    authority: LegacyFencingAuthority,
) ?[]const u8 {
    return switch (authority) {
        .per_resource => null,
        .shared => |path| path,
    };
}

fn validateLegacyFencingAuthorityScope(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    parsed: ParsedTransactionRecord,
    authority: LegacyFencingAuthority,
) !void {
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse
        return error.InvalidPath;
    try validateLegacyAuthorityOutsideTransactions(
        fs,
        allocator,
        transactions_dir,
        parsed.expected,
        authority,
    );
    var identities = HostPathIdentityContext.init(fs, allocator);
    defer identities.deinit();
    const canonical_transactions_dir = try identities.canonicalAlloc(
        transactions_dir,
    );
    defer allocator.free(canonical_transactions_dir);
    var transaction_paths = try canonicalTransactionPathIndexAlloc(
        allocator,
        &identities,
        parsed,
    );
    defer transaction_paths.deinit(allocator);
    var authority_paths = try canonicalLegacyAuthorityPathIndexAlloc(
        allocator,
        &identities,
        parsed.expected,
        authority,
    );
    defer authority_paths.deinit(allocator);
    if (transaction_paths.objectsIntersect(authority_paths)) {
        return error.TransactionCorrupt;
    }

    for (authority_paths.items()) |authority_path| {
        if (pathIsAtOrBelow(
            canonical_transactions_dir,
            authority_path,
        )) return error.TransactionCorrupt;
        if (transaction_paths.aliasesCanonical(authority_path)) {
            return error.TransactionCorrupt;
        }
    }
    try validateLegacyRecoveryControlDisjointness(
        allocator,
        &identities,
        parsed,
        transaction_paths,
        authority_paths,
    );
    try validateLegacyFencingTokenFloor(fs, allocator, parsed, authority);
}

fn validateLegacyAuthorityOutsideTransactions(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    expected: []const TransactionExpected,
    authority: LegacyFencingAuthority,
) !void {
    switch (authority) {
        .shared => |counter_path| try validateAuthorityPathOutsideTransactions(
            fs,
            allocator,
            transactions_dir,
            counter_path,
        ),
        .per_resource => for (expected) |row| {
            const lease_path = try lockPathAlloc(allocator, row.path);
            defer allocator.free(lease_path);
            const counter_path = try fencingCounterPathAlloc(
                allocator,
                lease_path,
                null,
            );
            defer allocator.free(counter_path);
            try validateAuthorityPathOutsideTransactions(
                fs,
                allocator,
                transactions_dir,
                counter_path,
            );
        },
    }
}

fn validateAuthorityPathOutsideTransactions(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    counter_path: []const u8,
) !void {
    if (try pathIsWithinDirectory(
        fs,
        allocator,
        transactions_dir,
        counter_path,
    )) return error.TransactionCorrupt;
    const counter_lock_path = try allocator.print(
        "{s}.lock",
        .{counter_path},
    );
    defer allocator.free(counter_lock_path);
    if (try pathIsWithinDirectory(
        fs,
        allocator,
        transactions_dir,
        counter_lock_path,
    )) return error.TransactionCorrupt;
}

fn canonicalTransactionPathIndexAlloc(
    allocator: std.mem.Allocator,
    identities: *HostPathIdentityContext,
    parsed: ParsedTransactionRecord,
) !CanonicalPathIndex {
    var index: CanonicalPathIndex = .{
        .paths = try allocator.alloc([]u8, parsed.expected.len),
        .object_keys = undefined,
    };
    index.object_keys = allocator.alloc(
        []u8,
        parsed.expected.len,
    ) catch |err| {
        allocator.free(index.paths);
        return err;
    };
    errdefer index.deinit(allocator);
    for (parsed.expected) |row| try index.append(identities, row.path);
    try index.finalize();
    return index;
}

fn appendCanonicalFencingAuthority(
    allocator: std.mem.Allocator,
    identities: *HostPathIdentityContext,
    index: *CanonicalPathIndex,
    counter_path: []const u8,
) !void {
    try index.append(identities, counter_path);
    const counter_lock_path = try allocator.print(
        "{s}.lock",
        .{counter_path},
    );
    defer allocator.free(counter_lock_path);
    try index.append(identities, counter_lock_path);
}

fn canonicalLegacyAuthorityPathIndexAlloc(
    allocator: std.mem.Allocator,
    identities: *HostPathIdentityContext,
    expected: []const TransactionExpected,
    authority: LegacyFencingAuthority,
) !CanonicalPathIndex {
    const count = switch (authority) {
        .shared => 2,
        .per_resource => std.math.mul(usize, expected.len, 2) catch
            return error.TransactionCorrupt,
    };
    var index: CanonicalPathIndex = .{
        .paths = try allocator.alloc([]u8, count),
        .object_keys = undefined,
    };
    index.object_keys = allocator.alloc([]u8, count) catch |err| {
        allocator.free(index.paths);
        return err;
    };
    errdefer index.deinit(allocator);
    switch (authority) {
        .shared => |counter_path| try appendCanonicalFencingAuthority(
            allocator,
            identities,
            &index,
            counter_path,
        ),
        .per_resource => for (expected) |row| {
            try index.appendDerived(
                identities,
                row.path,
                ".lock.counter",
            );
            try index.appendDerived(
                identities,
                row.path,
                ".lock.counter.lock",
            );
        },
    }
    try index.finalize();
    return index;
}

fn validateLegacyRecoveryControlDisjointness(
    allocator: std.mem.Allocator,
    identities: *HostPathIdentityContext,
    parsed: ParsedTransactionRecord,
    transaction_paths: CanonicalPathIndex,
    authority_paths: CanonicalPathIndex,
) !void {
    const control_count = std.math.mul(
        usize,
        parsed.expected.len,
        4,
    ) catch return error.TransactionCorrupt;
    var control_paths: CanonicalPathIndex = .{
        .paths = try allocator.alloc([]u8, control_count),
        .object_keys = undefined,
    };
    control_paths.object_keys = allocator.alloc(
        []u8,
        control_count,
    ) catch |err| {
        allocator.free(control_paths.paths);
        return err;
    };
    defer control_paths.deinit(allocator);
    for (parsed.expected) |expected| {
        const validated_cas_path = casLockPathAlloc(
            allocator,
            expected.path,
        ) catch |err| switch (err) {
            error.ReservedCasControlPath => return error.TransactionCorrupt,
            else => return err,
        };
        defer allocator.free(validated_cas_path);
        try control_paths.appendDerived(
            identities,
            expected.path,
            ".lock",
        );
        try control_paths.appendDerived(
            identities,
            expected.path,
            ".lock.advisory",
        );
        try control_paths.appendDerived(
            identities,
            expected.path,
            ".cas.lock",
        );
        try control_paths.appendDerived(
            identities,
            expected.path,
            ".cas.lock.advisory",
        );
    }
    try control_paths.finalize();
    if (transaction_paths.objectsIntersect(control_paths) or
        authority_paths.objectsIntersect(control_paths))
    {
        return error.TransactionCorrupt;
    }
    for (control_paths.items()) |control_path| {
        if (transaction_paths.aliasesCanonical(control_path)) {
            return error.TransactionCorrupt;
        }
        if (authority_paths.aliasesCanonical(control_path)) {
            return error.TransactionCorrupt;
        }
    }
}

fn validateLegacyFencingTokenFloor(
    fs: Fs,
    allocator: std.mem.Allocator,
    parsed: ParsedTransactionRecord,
    authority: LegacyFencingAuthority,
) !void {
    if (parsed.embedded_locks.len == 0) return;
    switch (authority) {
        .shared => |counter_path| {
            const counter = try readFencingCounter(fs, allocator, counter_path);
            for (parsed.embedded_locks) |lock| {
                if (counter < lock.fencing_token) {
                    return error.TransactionRecoveryRequired;
                }
            }
        },
        .per_resource => for (parsed.embedded_locks) |lock| {
            const lock_path = try lockPathAlloc(allocator, lock.resource);
            defer allocator.free(lock_path);
            const counter_path = try fencingCounterPathAlloc(
                allocator,
                lock_path,
                null,
            );
            defer allocator.free(counter_path);
            const counter = try readFencingCounter(fs, allocator, counter_path);
            if (counter < lock.fencing_token) {
                return error.TransactionRecoveryRequired;
            }
        },
    }
}

fn acquireLegacyTransactionRecoveryLeases(
    fs: Fs,
    allocator: std.mem.Allocator,
    expected: []const TransactionExpected,
    owner: Owner,
    transaction_id: []const u8,
    fencing_counter_path: ?[]const u8,
    storage_mutated: *bool,
) ![]LeaseLock {
    // Current recovery never reclaims an extant legacy lease. Its own
    // compatibility lease therefore uses the fail-closed protocol horizon:
    // a legacy writer cannot reclaim it mid-recovery, and an abnormal exit
    // still requires the same explicit operator repair as any stale lease.
    const recovery_lease_ms = std.math.maxInt(u64) / 2;
    const leases = try allocator.alloc(LeaseLock, expected.len);
    var acquired: usize = 0;
    errdefer {
        var index: usize = acquired;
        while (index > 0) {
            index -= 1;
            releaseLease(
                fs,
                allocator,
                &leases[index],
                leases[index].fencing_token,
            ) catch |err| {
                fs_authority.warn(
                    fs.io,
                    "lease rollback failed for {s}: {s}; run lease recovery",
                    .{
                        leases[index].path, @errorName(err),
                    },
                );
                leases[index].deinit(allocator);
            };
        }
        allocator.free(leases);
    }
    for (expected) |row| {
        const parent = std.fs.path.dirname(row.path) orelse
            return error.InvalidPath;
        const stat = try fs.directory().statFile(
            fs.io,
            parent,
            .{ .follow_symlinks = false },
        );
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .directory) return error.InvalidPath;
    }
    const options: AcquireOptions = .{
        .owner = owner,
        .lease_ms = recovery_lease_ms,
        .fencing_counter_path = fencing_counter_path,
        .transaction_id = transaction_id,
    };
    for (expected) |row| {
        leases[acquired] = try acquireLegacyRecoveryLease(
            fs,
            allocator,
            row.path,
            options,
            storage_mutated,
        );
        acquired += 1;
    }
    return leases;
}

fn acquireLegacyRecoveryLease(
    fs: Fs,
    allocator: std.mem.Allocator,
    resource: []const u8,
    options: AcquireOptions,
    storage_mutated: *bool,
) !LeaseLock {
    return acquireLeaseLockObserved(fs, allocator, resource, options, storage_mutated) catch |err|
        switch (err) {
            error.LockBusy => retry: {
                const path = try lockPathAlloc(allocator, resource);
                defer allocator.free(path);
                var current = readLeaseLock(
                    fs,
                    allocator,
                    path,
                ) catch |read_err| switch (read_err) {
                    error.FileNotFound => break :retry try acquireLeaseLockObserved(
                        fs,
                        allocator,
                        resource,
                        options,
                        storage_mutated,
                    ),
                    else => return read_err,
                };
                defer current.deinit(allocator);
                if (!std.mem.eql(u8, current.resource, resource)) return error.TransactionCorrupt;
                const expires_ms = try parseU64Text(current.expires_at);
                if (clockMillis(fs, .real) < expires_ms) return error.LockBusy;
                return error.TransactionRecoveryRequired;
            },
            else => return err,
        };
}

fn ensureLegacyTerminalLeasesQuiescent(
    fs: Fs,
    allocator: std.mem.Allocator,
    expected: []const TransactionExpected,
) !void {
    for (expected) |row| {
        const lock_path = try lockPathAlloc(allocator, row.path);
        defer allocator.free(lock_path);
        var current = readLeaseLock(
            fs,
            allocator,
            lock_path,
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer current.deinit(allocator);
        if (!std.mem.eql(u8, current.resource, row.path)) {
            return error.TransactionCorrupt;
        }
        const expires_ms = try parseU64Text(current.expires_at);
        if (clockMillis(fs, .real) < expires_ms) return error.LockBusy;
        return error.TransactionRecoveryRequired;
    }
}

fn syncLegacyTerminalEffects(
    fs: Fs,
    control_root: []const u8,
    transaction_dir: []const u8,
    expected: []const TransactionExpected,
) !void {
    for (expected) |row| {
        var target = try TransactionTarget.init(fs, control_root, row.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        try syncDirectoryHandle(fs, &target.dir);
        try target.verifyPathIdentity();
    }
    try syncDirectoryPath(fs, transaction_dir);
}

fn releaseLegacyTransactionRecoveryLeases(
    fs: Fs,
    allocator: std.mem.Allocator,
    leases: *[]LeaseLock,
    storage_mutated: *bool,
) !void {
    var first_error: ?anyerror = null;
    var index: usize = leases.len;
    while (index > 0) {
        index -= 1;
        const parent = std.fs.path.dirname(
            leases.*[index].path,
        ) orelse {
            leases.*[index].deinit(allocator);
            if (first_error == null) first_error = error.InvalidPath;
            continue;
        };
        var parent_dir = (if (std.fs.path.isAbsolute(parent))
            std.Io.Dir.openDirAbsolute(
                fs.io,
                parent,
                .{ .follow_symlinks = false },
            )
        else
            fs.directory().openDir(
                fs.io,
                parent,
                .{ .follow_symlinks = false },
            )) catch |err| {
            leases.*[index].deinit(allocator);
            if (first_error == null) first_error = err;
            continue;
        };
        {
            defer parent_dir.close(fs.io);
            releaseLease(
                fs,
                allocator,
                &leases.*[index],
                leases.*[index].fencing_token,
            ) catch |err| {
                leases.*[index].deinit(allocator);
                if (first_error == null) first_error = err;
                continue;
            };
            storage_mutated.* = true;
            syncDirectoryHandle(fs, &parent_dir) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
    }
    allocator.free(leases.*);
    leases.* = &.{};
    if (first_error) |err| return err;
}

fn transactionControlRoot(transaction_dir: []const u8) ![]const u8 {
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse
        return error.InvalidPath;
    return std.fs.path.dirname(transactions_dir) orelse
        return error.InvalidPath;
}

fn validateTransactionRecordScope(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    transaction_dir: []const u8,
    parsed: ParsedTransactionRecord,
    format: TransactionRecordFormat,
) !void {
    return validateTransactionRecordScopeWithMode(
        fs,
        allocator,
        control_root,
        transaction_dir,
        parsed,
        format,
        .target_identity,
    );
}

const TransactionScopeMode = enum { target_identity, metadata_only };

fn validateTransactionRecordScopeWithMode(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    transaction_dir: []const u8,
    parsed: ParsedTransactionRecord,
    format: TransactionRecordFormat,
    mode: TransactionScopeMode,
) !void {
    try validateTransactionRecordIdentity(transaction_dir, parsed, format);
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse
        return error.InvalidPath;
    var expected_indexes = std.StringHashMap(usize).init(allocator);
    defer expected_indexes.deinit();
    var expected_paths = try allocator.alloc([]const u8, parsed.expected.len);
    defer allocator.free(expected_paths);
    for (parsed.expected, 0..) |row, row_index| {
        if (pathContainsReclaimEvidenceComponent(row.path)) {
            return error.TransactionCorrupt;
        }
        _ = try pathRelativeToControlRoot(control_root, row.path);
        if (try transactionTargetWithinDirectory(
            fs,
            allocator,
            transactions_dir,
            row.path,
            mode,
        )) return error.TransactionCorrupt;
        const result = try expected_indexes.getOrPut(row.path);
        if (result.found_existing) return error.TransactionCorrupt;
        result.value_ptr.* = row_index;
        expected_paths[row_index] = row.path;
    }
    try validateTransactionPathsDisjoint(fs, allocator, format, expected_paths);
    try validateTransactionWriteScope(
        fs,
        allocator,
        control_root,
        transactions_dir,
        parsed,
        format,
        expected_indexes,
        mode,
    );
}

fn transactionTargetWithinDirectory(
    fs: Fs,
    allocator: std.mem.Allocator,
    directory: []const u8,
    path: []const u8,
    mode: TransactionScopeMode,
) !bool {
    if (mode == .target_identity) return pathIsWithinDirectory(fs, allocator, directory, path);
    if (pathIsAtOrBelow(directory, path)) return true;
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    return pathIsWithinDirectory(fs, allocator, directory, parent);
}

fn validateTransactionRecordIdentity(
    transaction_dir: []const u8,
    parsed: ParsedTransactionRecord,
    format: TransactionRecordFormat,
) !void {
    const format_matches_id = switch (format) {
        .current => isGeneratedTransactionId(parsed.transaction_id),
        .legacy => isLegacyTransactionId(parsed.transaction_id) or
            isGeneratedTransactionId(parsed.transaction_id),
    };
    if (!format_matches_id or
        !std.mem.eql(
            u8,
            std.fs.path.basename(transaction_dir),
            parsed.transaction_id,
        ))
    {
        return error.TransactionCorrupt;
    }
    switch (format) {
        .current => if (parsed.embedded_locks.len != 0) {
            return error.TransactionCorrupt;
        },
        .legacy => if (parsed.state == .preparing) {
            return error.TransactionCorrupt;
        } else if (parsed.embedded_locks.len != 0) {
            if (parsed.embedded_locks.len != parsed.expected.len) {
                return error.TransactionCorrupt;
            }
            for (parsed.embedded_locks, parsed.expected) |lock, expected| {
                if (!std.mem.eql(u8, lock.resource, expected.path) or
                    !ownersEqual(lock.owner, parsed.owner))
                {
                    return error.TransactionCorrupt;
                }
                if (lock.transaction_id) |transaction_id| {
                    if (!std.mem.eql(
                        u8,
                        transaction_id,
                        parsed.transaction_id,
                    )) return error.TransactionCorrupt;
                }
            }
        },
    }
}

fn validateTransactionWriteScope(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    transactions_dir: []const u8,
    parsed: ParsedTransactionRecord,
    format: TransactionRecordFormat,
    expected_indexes: std.StringHashMap(usize),
    mode: TransactionScopeMode,
) !void {
    var write_paths = try allocator.alloc([]const u8, parsed.writes.len);
    defer allocator.free(write_paths);
    var target_basenames = std.StringHashMap(void).init(allocator);
    defer target_basenames.deinit();
    for (parsed.expected) |expected| {
        try target_basenames.put(std.fs.path.basename(expected.path), {});
    }
    for (parsed.writes) |write| {
        try target_basenames.put(std.fs.path.basename(write.path), {});
    }
    for (parsed.writes, 0..) |row, write_index| {
        _ = try pathRelativeToControlRoot(control_root, row.path);
        if (try transactionTargetWithinDirectory(
            fs,
            allocator,
            transactions_dir,
            row.path,
            mode,
        )) return error.TransactionCorrupt;
        const expected_index = expected_indexes.get(row.path) orelse
            return error.TransactionCorrupt;
        write_paths[write_index] = row.path;
        var expected_name_buffer: [96]u8 = undefined;
        const expected_name = switch (format) {
            .current => try transactionStageName(
                &expected_name_buffer,
                parsed.transaction_id,
                write_index,
            ),
            .legacy => try legacyTransactionStageName(
                &expected_name_buffer,
                expected_index,
            ),
        };
        if (!std.mem.eql(u8, row.staged_ref, expected_name)) {
            return error.TransactionCorrupt;
        }
        if (format == .legacy) continue;
        if (target_basenames.contains(row.staged_ref)) {
            return error.TransactionCorrupt;
        }
    }
    try validateTransactionPathsDisjoint(fs, allocator, format, write_paths);
}

fn pathContainsReclaimEvidenceComponent(path: []const u8) bool {
    var components = std.fs.path.componentIterator(path);
    while (components.next()) |component| {
        if (isReclaimEvidenceComponent(component.name)) return true;
    }
    return false;
}

fn isReclaimEvidenceComponent(component: []const u8) bool {
    const marker = ".lock.reclaimed-";
    if (component.len <= marker.len) return false;
    var offset: usize = 0;
    while (offset + marker.len < component.len) : (offset += 1) {
        if (!std.ascii.eqlIgnoreCase(
            component[offset .. offset + marker.len],
            marker,
        )) continue;
        if (component.len > offset + marker.len) return true;
    }
    return false;
}

fn validateTransactionPathsDisjoint(
    fs: Fs,
    allocator: std.mem.Allocator,
    format: TransactionRecordFormat,
    paths: []const []const u8,
) !void {
    if (paths.len < 2) return;
    var case_sensitive = try allocator.alloc([]const u8, paths.len);
    defer allocator.free(case_sensitive);
    @memcpy(case_sensitive, paths);
    std.sort.heap([]const u8, case_sensitive, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    for (case_sensitive[1..], 1..) |path, index| {
        if (pathsAliasOrOverlapCaseSensitive(
            case_sensitive[index - 1],
            path,
        )) return error.TransactionCorrupt;
    }

    const FoldedPath = struct {
        original: []const u8,
        folded: []u8,
    };
    var folded = try allocator.alloc(FoldedPath, paths.len);
    var folded_count: usize = 0;
    defer {
        for (folded[0..folded_count]) |path| allocator.free(path.folded);
        allocator.free(folded);
    }
    for (paths, 0..) |path, index| {
        folded[index] = .{
            .original = path,
            .folded = try allocator.dupe(u8, path),
        };
        folded_count += 1;
        for (folded[index].folded) |*byte| {
            byte.* = std.ascii.toLower(byte.*);
        }
    }
    std.sort.heap(FoldedPath, folded, {}, struct {
        fn lessThan(_: void, left: FoldedPath, right: FoldedPath) bool {
            return std.mem.lessThan(u8, left.folded, right.folded);
        }
    }.lessThan);
    for (folded[1..], 1..) |path, index| {
        const prior = folded[index - 1];
        if (!pathsAliasOrOverlapCaseSensitive(
            prior.folded,
            path.folded,
        )) continue;
        if (try transactionPathsAliasOrOverlap(
            fs,
            allocator,
            format,
            prior.original,
            path.original,
        )) {
            return error.TransactionCorrupt;
        }
    }
}

fn deleteReservedTransactionStages(
    fs: Fs,
    transaction_dir: []const u8,
    writes: []const TransactionWrite,
    storage_mutated: *bool,
) !void {
    var stage_dir = if (std.fs.path.isAbsolute(transaction_dir))
        try std.Io.Dir.openDirAbsolute(fs.io, transaction_dir, .{
            .follow_symlinks = false,
        })
    else
        try fs.directory().openDir(fs.io, transaction_dir, .{
            .follow_symlinks = false,
        });
    defer stage_dir.close(fs.io);
    for (writes) |write| {
        const stat = stage_dir.statFile(
            fs.io,
            write.staged_ref,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file or stat.nlink != 1) {
            return error.TransactionCorrupt;
        }
        try stage_dir.deleteFile(fs.io, write.staged_ref);
        storage_mutated.* = true;
        try syncDirectoryHandle(fs, &stage_dir);
    }
}

const TransactionRecoveryLocks = struct {
    fs: Fs,
    advisory: []std.Io.File,
    compatibility: []LockFile,
    advisory_count: usize,
    compatibility_count: usize,

    fn deinit(
        self: *TransactionRecoveryLocks,
        allocator: std.mem.Allocator,
    ) void {
        const fs = self.fs;
        for (self.compatibility[0..self.compatibility_count]) |*lock| {
            lock.release(allocator);
        }
        for (self.advisory[0..self.advisory_count]) |file| {
            file.close(fs.io);
        }
        allocator.free(self.compatibility);
        allocator.free(self.advisory);
        self.* = undefined;
    }

    fn releaseDurable(
        self: *TransactionRecoveryLocks,
        allocator: std.mem.Allocator,
        storage_mutated: *bool,
    ) !void {
        const fs = self.fs;
        var first_error: ?anyerror = null;
        releaseCompatibilityLocksDurable(
            fs,
            allocator,
            self.compatibility[0..self.compatibility_count],
            storage_mutated,
        ) catch |err| {
            first_error = err;
        };
        for (self.advisory[0..self.advisory_count]) |file| {
            file.close(fs.io);
        }
        allocator.free(self.compatibility);
        allocator.free(self.advisory);
        self.* = undefined;
        if (first_error) |err| return err;
    }
};

const CompatibilityReleaseEntry = struct {
    lock: *LockFile,
    parent: []const u8,
};

fn deleteCompatibilityLockObserved(
    fs: Fs,
    parent_dir: *std.Io.Dir,
    basename: []const u8,
    storage_mutated: *bool,
) !bool {
    var removed = true;
    parent_dir.deleteFile(fs.io, basename) catch |err| switch (err) {
        error.FileNotFound => removed = false,
        else => return err,
    };
    if (removed) storage_mutated.* = true;
    return removed;
}

fn openCompatibilityLockParent(fs: Fs, parent: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(parent))
        std.Io.Dir.openDirAbsolute(
            fs.io,
            parent,
            .{ .follow_symlinks = false },
        )
    else
        fs.directory().openDir(
            fs.io,
            parent,
            .{ .follow_symlinks = false },
        );
}

fn releaseCompatibilityLockGroup(
    fs: Fs,
    entries: []CompatibilityReleaseEntry,
    storage_mutated: *bool,
) !void {
    std.debug.assert(entries.len != 0);
    var parent_dir = try openCompatibilityLockParent(fs, entries[0].parent);
    defer parent_dir.close(fs.io);
    var first_error: ?anyerror = null;
    var removed = false;
    for (entries) |entry| {
        const deleted = deleteCompatibilityLockObserved(
            fs,
            &parent_dir,
            std.fs.path.basename(entry.lock.path),
            storage_mutated,
        ) catch |err| failed: {
            if (first_error == null) first_error = err;
            break :failed false;
        };
        removed = removed or deleted;
    }
    if (removed) {
        syncDirectoryHandle(fs, &parent_dir) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    if (first_error) |err| return err;
}

fn releaseCompatibilityLocksDurable(
    fs: Fs,
    allocator: std.mem.Allocator,
    locks: []LockFile,
    storage_mutated: *bool,
) !void {
    if (locks.len > transaction_recovery_max_rows) {
        return error.TransactionRecoveryRequired;
    }
    var entries_buffer: [transaction_recovery_max_rows]CompatibilityReleaseEntry = undefined;
    const entries = entries_buffer[0..locks.len];
    for (locks, entries) |*lock, *entry| {
        entry.* = .{
            .lock = lock,
            .parent = std.fs.path.dirname(lock.path) orelse ".",
        };
    }
    std.sort.heap(
        CompatibilityReleaseEntry,
        entries,
        {},
        struct {
            fn lessThan(
                _: void,
                left: CompatibilityReleaseEntry,
                right: CompatibilityReleaseEntry,
            ) bool {
                return std.mem.lessThan(
                    u8,
                    left.parent,
                    right.parent,
                );
            }
        }.lessThan,
    );
    var first_error: ?anyerror = null;
    var index: usize = 0;
    while (index < entries.len) {
        const parent = entries[index].parent;
        const start = index;
        while (index < entries.len and
            std.mem.eql(u8, entries[index].parent, parent))
        {
            index += 1;
        }
        releaseCompatibilityLockGroup(
            fs,
            entries[start..index],
            storage_mutated,
        ) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    for (locks) |*lock| {
        allocator.free(lock.path);
        lock.* = .{ .path = &.{}, .fs = lock.fs };
    }
    if (first_error) |err| return err;
}

fn acquireTransactionRecoveryLocks(
    fs: Fs,
    allocator: std.mem.Allocator,
    expected: []const TransactionExpected,
    storage_mutated: *bool,
) !TransactionRecoveryLocks {
    const advisory = try allocator.alloc(std.Io.File, expected.len);
    const compatibility = allocator.alloc(
        LockFile,
        expected.len,
    ) catch |err| {
        allocator.free(advisory);
        return err;
    };
    var result: TransactionRecoveryLocks = .{
        .fs = fs,
        .advisory = advisory,
        .compatibility = compatibility,
        .advisory_count = 0,
        .compatibility_count = 0,
    };
    errdefer result.deinit(allocator);
    for (expected) |row| {
        result.advisory[result.advisory_count] =
            try acquireCasAdvisoryLockObserved(
                fs,
                allocator,
                row.path,
                storage_mutated,
            );
        result.advisory_count += 1;
        const cas_path = try casLockPathAlloc(allocator, row.path);
        defer allocator.free(cas_path);
        const stat = fs.directory().statFile(
            fs.io,
            cas_path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (stat) |value| {
            if (value.kind == .sym_link) return error.SymlinkComponent;
            if (value.kind != .file) return error.TransactionCorrupt;
            if (value.size != 0) {
                return error.TransactionRecoveryRequired;
            }
            if (std.fs.path.isAbsolute(cas_path)) {
                try std.Io.Dir.deleteFileAbsolute(fs.io, cas_path);
            } else {
                try fs.directory().deleteFile(fs.io, cas_path);
            }
            storage_mutated.* = true;
        }
        result.compatibility[result.compatibility_count] =
            try acquireExclusiveLockPath(fs, allocator, cas_path);
        result.compatibility_count += 1;
        storage_mutated.* = true;
    }
    return result;
}

fn rollForwardValidatedTransaction(
    fs: Fs,
    control_root: []const u8,
    transaction_dir: []const u8,
    parsed: ParsedTransactionRecord,
    write_states: []const RecoveryWriteState,
    storage_mutated: *bool,
) !void {
    var stages = try fs.directory().openDir(fs.io, transaction_dir, .{
        .follow_symlinks = false,
    });
    defer stages.close(fs.io);
    for (parsed.writes, write_states) |write, state| {
        var target = try TransactionTarget.init(fs, control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        if (state == .published) {
            stages.deleteFile(fs.io, write.staged_ref) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
        } else {
            const staged = try stages.statFile(fs.io, write.staged_ref, .{
                .follow_symlinks = false,
            });
            if (staged.kind != .file or staged.nlink != 1) return error.TransactionCorrupt;
            try stages.rename(write.staged_ref, target.dir, target.base, fs.io);
            try syncDirectoryHandle(fs, &target.dir);
            try target.verifyPathIdentity();
            const actual = try target.dir.statFile(fs.io, target.base, .{
                .follow_symlinks = false,
            });
            if (actual.kind != .file or actual.inode != staged.inode or
                actual.size != staged.size or actual.nlink != 1) return error.TransactionCorrupt;
        }
        storage_mutated.* = true;
        try syncDirectoryHandle(fs, &stages);
    }
}

fn rollForwardTransaction(
    fs: Fs,
    control_root: []const u8,
    transaction_dir: []const u8,
    parsed: ParsedTransactionRecord,
    write_states: []const RecoveryWriteState,
    storage_mutated: *bool,
    hash_bytes_remaining: *usize,
) !void {
    if (write_states.len != parsed.writes.len) {
        return error.TransactionCorrupt;
    }
    var stage_dir = if (std.fs.path.isAbsolute(transaction_dir))
        try std.Io.Dir.openDirAbsolute(fs.io, transaction_dir, .{
            .follow_symlinks = false,
        })
    else
        try fs.directory().openDir(fs.io, transaction_dir, .{
            .follow_symlinks = false,
        });
    defer stage_dir.close(fs.io);
    for (parsed.writes, write_states) |write, state| {
        var target = try TransactionTarget.init(fs, control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        switch (state) {
            .published => {
                try syncDirectoryHandle(fs, &target.dir);
                try target.verifyPathIdentity();
                var stage_deleted = true;
                stage_dir.deleteFile(
                    fs.io,
                    write.staged_ref,
                ) catch |err| switch (err) {
                    error.FileNotFound => stage_deleted = false,
                    else => return err,
                };
                if (stage_deleted) storage_mutated.* = true;
                try syncDirectoryHandle(fs, &stage_dir);
                continue;
            },
            .expected, .missing => {},
        }
        try rejectHardlinkedTargetAt(fs, &target.dir, target.base);
        try publishVerifiedRecoveryStagedFile(
            fs,
            &stage_dir,
            write.staged_ref,
            write.digest_after,
            &target,
            hash_bytes_remaining,
        );
        storage_mutated.* = true;
        try syncDirectoryHandle(fs, &target.dir);
        try stage_dir.deleteFile(fs.io, write.staged_ref);
        storage_mutated.* = true;
        try syncDirectoryHandle(fs, &stage_dir);
        try target.verifyPathIdentity();
    }
}

fn validateRollForwardTransaction(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    transaction_dir: []const u8,
    parsed: ParsedTransactionRecord,
    write_states: []const RecoveryWriteState,
    published_count: usize,
    hash_bytes_remaining: *usize,
) !void {
    if (write_states.len != parsed.writes.len or
        published_count > write_states.len)
    {
        return error.TransactionCorrupt;
    }
    var expected_digests = try transactionExpectedDigestIndex(
        allocator,
        parsed.expected,
    );
    defer expected_digests.deinit();
    var write_paths = std.StringHashMap(void).init(allocator);
    defer write_paths.deinit();
    for (parsed.writes) |write| {
        const result = try write_paths.getOrPut(write.path);
        if (result.found_existing) return error.TransactionCorrupt;
    }
    var stage_dir = if (std.fs.path.isAbsolute(transaction_dir))
        try std.Io.Dir.openDirAbsolute(fs.io, transaction_dir, .{
            .follow_symlinks = false,
        })
    else
        try fs.directory().openDir(fs.io, transaction_dir, .{
            .follow_symlinks = false,
        });
    defer stage_dir.close(fs.io);
    if (parsed.state != .committed and
        published_count != parsed.writes.len)
    {
        try validateReadOnlyRecoveryTargets(
            fs,
            allocator,
            control_root,
            parsed.expected,
            write_paths,
            hash_bytes_remaining,
        );
    }
    for (parsed.writes, write_states) |write, state| {
        try validateRecoveryStagedWrite(
            fs,
            allocator,
            control_root,
            &stage_dir,
            write,
            state,
            expected_digests,
            hash_bytes_remaining,
        );
    }
}

fn validateReadOnlyRecoveryTargets(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    expected_rows: []const TransactionExpected,
    write_paths: std.StringHashMap(void),
    hash_bytes_remaining: *usize,
) !void {
    for (expected_rows) |expected| {
        if (write_paths.contains(expected.path)) continue;
        var target = try TransactionTarget.init(
            fs,
            control_root,
            expected.path,
        );
        defer target.deinit();
        try target.verifyPathIdentity();
        const current = digestRecoveryFileAtAlloc(
            fs,
            allocator,
            &target.dir,
            target.base,
            hash_bytes_remaining,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (current) |digest| allocator.free(digest);
        if (current) |digest| {
            if (!std.mem.eql(u8, digest, expected.digest)) {
                return error.TransactionRecoveryRequired;
            }
        } else if (expected.digest.len != 0) {
            return error.TransactionRecoveryRequired;
        }
    }
}

fn validateRecoveryStagedWrite(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    stage_dir: *std.Io.Dir,
    write: TransactionWrite,
    state: RecoveryWriteState,
    expected_digests: std.StringHashMap([]const u8),
    hash_bytes_remaining: *usize,
) !void {
    var target = try TransactionTarget.init(fs, control_root, write.path);
    defer target.deinit();
    try target.verifyPathIdentity();
    switch (state) {
        .published => return,
        .expected => {},
        .missing => {
            const expected_digest = expected_digests.get(write.path) orelse
                return error.TransactionCorrupt;
            if (expected_digest.len != 0) {
                return error.TransactionRecoveryRequired;
            }
        },
    }
    const staged_digest = digestRecoveryFileAtAlloc(
        fs,
        allocator,
        stage_dir,
        write.staged_ref,
        hash_bytes_remaining,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.TransactionRecoveryRequired,
        else => return err,
    };
    defer allocator.free(staged_digest);
    if (!std.mem.eql(u8, staged_digest, write.digest_after)) {
        return error.TransactionCorrupt;
    }
}

fn makeRecoveryStatus(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    decision: RecoveryDecision,
    reason: []const u8,
) !RecoveryStatus {
    const owned_id = try allocator.dupe(u8, transaction_id);
    errdefer allocator.free(owned_id);
    return .{
        .transaction_id = owned_id,
        .decision = decision,
        .reason = try allocator.dupe(u8, reason),
    };
}

fn makeRecoveryReceipt(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    decision: RecoveryDecision,
    result: []const u8,
) !RecoveryReceipt {
    const owned_id = try allocator.dupe(u8, transaction_id);
    errdefer allocator.free(owned_id);
    return .{
        .transaction_id = owned_id,
        .decision = decision,
        .result = try allocator.dupe(u8, result),
    };
}

fn normalizeTransactionMutations(
    fs: Fs,
    allocator: std.mem.Allocator,
    mutations: []const TransactionMutation,
    reject_symlinks: bool,
) ![]TransactionMutation {
    var ordered = try allocator.alloc(TransactionMutation, mutations.len);
    errdefer allocator.free(ordered);
    for (mutations, 0..) |mutation, index| {
        try rejectTransactionPath(fs, mutation.path, reject_symlinks);
        ordered[index] = mutation;
    }
    std.sort.heap(TransactionMutation, ordered, {}, struct {
        fn lessThan(_: void, a: TransactionMutation, b: TransactionMutation) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    for (ordered[1..], 1..) |mutation, index| {
        const prior = ordered[index - 1].path;
        if (pathsAliasOrOverlap(prior, mutation.path)) {
            return error.InvalidPath;
        }
    }
    return ordered;
}

fn transactionPathsAliasOrOverlap(
    fs: Fs,
    allocator: std.mem.Allocator,
    format: TransactionRecordFormat,
    left: []const u8,
    right: []const u8,
) !bool {
    if (!pathsAliasOrOverlap(left, right)) return false;
    if (format == .current or pathsAliasOrOverlapCaseSensitive(left, right)) {
        return true;
    }
    const shorter = if (left.len < right.len) left else right;
    const parent = std.fs.path.dirname(shorter) orelse
        return error.InvalidPath;
    return directoryNameIsCaseInsensitive(
        fs,
        allocator,
        parent,
        std.fs.path.basename(shorter),
    );
}

fn rejectTransactionPath(fs: Fs, path: []const u8, reject_symlinks: bool) !void {
    const base = std.fs.path.basename(path);
    if (path.len == 0 or
        base.len == 0 or
        std.mem.eql(u8, base, ".") or
        std.mem.eql(u8, base, "..") or
        std.mem.startsWith(u8, base, transaction_stage_prefix))
    {
        return error.InvalidPath;
    }
    if (pathContainsReclaimEvidenceComponent(path)) {
        return error.ReservedStorePath;
    }
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return error.InvalidPath;
    }
    if (reject_symlinks) try rejectSymlinkComponents(fs, path);
}

fn writeCurrentTransactionRecord(
    fs: Fs,
    allocator: std.mem.Allocator,
    record_path: []const u8,
    transaction_id: []const u8,
    owner: Owner,
    state: TransactionState,
    expected: []const TransactionExpected,
    writes: []const TransactionWrite,
    locks: []const LeaseLock,
    created_ms: u64,
    updated_ms: u64,
    create_new: bool,
) !void {
    const bytes = try renderTransactionRecordAlloc(
        allocator,
        transaction_id,
        owner,
        state,
        expected,
        writes,
        locks,
        created_ms,
        updated_ms,
        .current,
    );
    defer allocator.free(bytes);
    if (bytes.len > transaction_record_max_bytes) {
        return error.FileTooBig;
    }
    if (create_new) {
        try writeTextCreateNew(fs, allocator, record_path, bytes, .{});
    } else {
        try writeTextAtomic(fs, allocator, record_path, bytes);
    }
}

fn writeTransactionRecord(
    fs: Fs,
    allocator: std.mem.Allocator,
    record_path: []const u8,
    transaction_id: []const u8,
    owner: Owner,
    state: TransactionState,
    expected: []const TransactionExpected,
    writes: []const TransactionWrite,
    locks: []const LeaseLock,
    created_ms: u64,
    updated_ms: u64,
    create_new: bool,
) !void {
    const bytes = try renderTransactionRecordAlloc(
        allocator,
        transaction_id,
        owner,
        state,
        expected,
        writes,
        locks,
        created_ms,
        updated_ms,
        null,
    );
    defer allocator.free(bytes);
    if (bytes.len > transaction_record_max_bytes) {
        return error.FileTooBig;
    }
    if (create_new) {
        try writeTextCreateNew(fs, allocator, record_path, bytes, .{});
    } else {
        try writeTextAtomic(fs, allocator, record_path, bytes);
    }
}

fn parseTransactionRecord(
    fs: Fs,
    allocator: std.mem.Allocator,
    record_path: []const u8,
) !ParsedTransactionRecord {
    const bytes = try readRegularFileNoSymlink(
        fs,
        allocator,
        record_path,
        transaction_record_max_bytes,
    );
    defer allocator.free(bytes);
    return parseTransactionRecordBytes(allocator, bytes);
}

fn parseTransactionRecordBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !ParsedTransactionRecord {
    if (bytes.len > transaction_record_max_bytes) return error.FileTooBig;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return err,
            else => return error.TransactionCorrupt,
        };
    defer parsed.deinit();
    if (parsed.value != .object) return error.TransactionCorrupt;
    const fields = try transactionRecordFields(parsed.value.object);
    return ownTransactionRecordFields(allocator, fields);
}

fn transactionPublishedCount(
    fs: Fs,
    allocator: std.mem.Allocator,
    control_root: []const u8,
    writes: []const TransactionWrite,
    expected: []const TransactionExpected,
    hash_bytes_remaining: *usize,
) !?usize {
    var expected_digests = try transactionExpectedDigestIndex(
        allocator,
        expected,
    );
    defer expected_digests.deinit();
    var published: usize = 0;
    for (writes) |write| {
        _ = try pathRelativeToControlRoot(control_root, write.path);
        var target = try TransactionTarget.init(fs, control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        const digest = digestRecoveryFileAtAlloc(
            fs,
            allocator,
            &target.dir,
            target.base,
            hash_bytes_remaining,
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(digest);
        if (std.mem.eql(u8, digest, write.digest_after)) {
            published += 1;
        } else {
            const expected_digest = expected_digests.get(write.path) orelse
                return error.TransactionCorrupt;
            if (!std.mem.eql(u8, digest, expected_digest)) return null;
        }
    }
    return published;
}

fn transactionExpectedDigestIndex(
    allocator: std.mem.Allocator,
    expected: []const TransactionExpected,
) !std.StringHashMap([]const u8) {
    var index = std.StringHashMap([]const u8).init(allocator);
    errdefer index.deinit();
    for (expected) |row| {
        const result = try index.getOrPut(row.path);
        if (result.found_existing) return error.TransactionCorrupt;
        result.value_ptr.* = row.digest;
    }
    return index;
}

fn digestRecoveryFileAtAlloc(
    fs: Fs,
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    base: []const u8,
    hash_bytes_remaining: *usize,
) ![]u8 {
    const stat = try dir.statFile(
        fs.io,
        base,
        .{ .follow_symlinks = false },
    );
    const size = std.math.cast(usize, stat.size) orelse
        return error.TransactionRecoveryWorkExceeded;
    if (size > transaction_recovery_max_bytes or
        size > hash_bytes_remaining.*)
    {
        return error.TransactionRecoveryWorkExceeded;
    }
    const observed = digestRegularFileNoSymlinkAtAlloc(
        fs,
        allocator,
        dir,
        base,
        @min(transaction_recovery_max_bytes, hash_bytes_remaining.*),
    ) catch |err| switch (err) {
        error.FileTooBig => return error.TransactionRecoveryWorkExceeded,
        else => return err,
    };
    hash_bytes_remaining.* -= observed.byte_len;
    return observed.digest;
}

pub fn ensureNoPendingTransactions(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
) !void {
    if (try countPendingTransactions(fs, allocator, transactions_dir) != 0) {
        return error.TransactionRecoveryRequired;
    }
}

pub fn countPendingTransactions(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
) !usize {
    return countPendingTransactionsBounded(
        fs,
        allocator,
        transactions_dir,
        4096,
        8192,
    );
}

fn countPendingTransactionsBounded(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    max_pending: usize,
    max_entries: usize,
) !usize {
    return countPendingTransactionsBudgeted(
        fs,
        allocator,
        transactions_dir,
        max_pending,
        max_entries,
        null,
    );
}

pub fn countPendingTransactionsWithReadBudget(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    remaining: *usize,
) !usize {
    return countPendingTransactionsBudgeted(fs, allocator, transactions_dir, 4096, 8192, remaining);
}

fn countPendingTransactionsBudgeted(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    max_pending: usize,
    max_entries: usize,
    remaining: ?*usize,
) !usize {
    const dir_stat = fs.directory().statFile(
        fs.io,
        transactions_dir,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    if (dir_stat.kind == .sym_link) return error.SymlinkComponent;
    if (dir_stat.kind != .directory) return error.NotDir;

    var dir = if (std.fs.path.isAbsolute(transactions_dir))
        try std.Io.Dir.openDirAbsolute(
            fs.io,
            transactions_dir,
            .{ .iterate = true, .follow_symlinks = false },
        )
    else
        try fs.directory().openDir(
            fs.io,
            transactions_dir,
            .{ .iterate = true, .follow_symlinks = false },
        );
    defer dir.close(fs.io);

    var pending: usize = 0;
    var entries: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(fs.io)) |entry| {
        entries = std.math.add(usize, entries, 1) catch
            return error.TooManyFiles;
        if (entries > max_entries) return error.TooManyFiles;
        if (try transactionEntryPending(fs, allocator, transactions_dir, entry, remaining)) {
            try incrementPending(&pending, max_pending);
        }
    }
    return pending;
}

fn transactionEntryPending(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    entry: std.Io.Dir.Entry,
    remaining: ?*usize,
) !bool {
    if (entry.kind == .sym_link) return error.SymlinkComponent;
    if (entry.kind != .file and entry.kind != .directory) return false;

    const entry_path = try std.fs.path.join(allocator, &.{ transactions_dir, entry.name });
    defer allocator.free(entry_path);
    const stat = try fs.directory().statFile(
        fs.io,
        entry_path,
        .{ .follow_symlinks = false },
    );
    if (stat.kind == .sym_link) return error.SymlinkComponent;

    if (stat.kind == .file) {
        if (stat.size > 1024 * 1024) return error.FileTooBig;
        const prepared_suffix = ".prepared.json";
        if (!std.mem.endsWith(u8, entry.name, prepared_suffix)) return false;
        const prefix = entry.name[0 .. entry.name.len - prepared_suffix.len];
        const commit_name = try allocator.print("{s}.commit.json", .{prefix});
        defer allocator.free(commit_name);
        const commit_path = try std.fs.path.join(
            allocator,
            &.{ transactions_dir, commit_name },
        );
        defer allocator.free(commit_path);
        return !fileExists(fs, commit_path);
    }

    if (stat.kind == .directory) {
        return transactionDirectoryPending(fs, allocator, entry_path, remaining);
    }
    return false;
}

fn incrementPending(pending: *usize, max_pending: usize) !void {
    if (pending.* >= max_pending) return error.TooManyFiles;
    pending.* += 1;
}

fn transactionDirectoryPending(
    fs: Fs,
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    remaining: ?*usize,
) !bool {
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const commit_marker_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "commit.json" },
    );
    defer allocator.free(commit_marker_path);
    const parsed = (if (remaining) |budget|
        readDependencyRecord(fs, allocator, transaction_dir, budget)
    else
        parseTransactionRecord(fs, allocator, record_path)) catch |err| switch (err) {
        error.FileNotFound, error.TransactionDependencyIncomplete => return true,
        else => return err,
    };
    defer parsed.deinit(allocator);
    return switch (parsed.state) {
        .committed => !fileExists(fs, commit_marker_path),
        .aborted => false,
        .preparing, .prepared, .committing, .recovery_required => true,
    };
}

pub fn appendJsonlCheckpointTransaction(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
    locks_dir: []const u8,
    transactions_dir: []const u8,
    checkpoint_line: []const u8,
    options: JsonlTransactionOptions,
) !JsonlTransactionReceipt {
    try ensureDirectoryPathNoSymlinks(fs, locks_dir);
    try ensureDirectoryPathNoSymlinks(fs, transactions_dir);

    const lock_name = try transactionLockNameAlloc(allocator, store_path);
    defer allocator.free(lock_name);
    const lock_path = try std.fs.path.join(allocator, &.{ locks_dir, lock_name });
    defer allocator.free(lock_path);
    var lock = try acquireExclusiveLockPath(fs, allocator, lock_path);
    defer lock.release(allocator);

    try ensureNoPendingTransactions(fs, allocator, transactions_dir);

    const existing = readRegularFileNoSymlink(
        fs,
        allocator,
        store_path,
        options.max_existing_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    const receipt = try checkpointReceiptAlloc(
        fs,
        allocator,
        transactions_dir,
        existing,
        checkpoint_line,
        options,
    );
    errdefer {
        allocator.free(receipt.transaction_id);
        allocator.free(receipt.prepared_path);
        allocator.free(receipt.commit_path);
    }
    try publishJsonlCheckpoint(
        fs,
        allocator,
        store_path,
        existing,
        checkpoint_line,
        options,
        receipt,
    );
    return receipt;
}

fn checkpointReceiptAlloc(
    fs: Fs,
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    existing: []const u8,
    checkpoint_line: []const u8,
    options: JsonlTransactionOptions,
) !JsonlTransactionReceipt {
    const sequence_before = try lastJsonlSequence(allocator, existing, options.sequence_field);
    if (options.expected_sequence) |expected| {
        if (expected != sequence_before) return error.SequenceStale;
    }
    const trimmed_checkpoint = std.mem.trim(u8, checkpoint_line, " \t\r\n");
    if (trimmed_checkpoint.len == 0) return error.InvalidCheckpoint;
    const sequence_after = try jsonObjectSequence(
        allocator,
        trimmed_checkpoint,
        options.sequence_field,
    );
    const requires_increment = options.mode == .append or !options.allow_sequence_reset;
    if (requires_increment) {
        const next = std.math.add(i64, sequence_before, 1) catch
            return error.TransactionSequenceMismatch;
        if (sequence_after != next) return error.TransactionSequenceMismatch;
    }
    const transaction_id = try allocator.print(
        "txn-{d:0>12}-{d}",
        .{ sequence_after, std.Io.Clock.awake.now(fs.io).nanoseconds },
    );
    errdefer allocator.free(transaction_id);
    const prepared_name = try allocator.print("{s}.prepared.json", .{transaction_id});
    defer allocator.free(prepared_name);
    const prepared_path = try std.fs.path.join(allocator, &.{ transactions_dir, prepared_name });
    errdefer allocator.free(prepared_path);
    const commit_name = try allocator.print("{s}.commit.json", .{transaction_id});
    defer allocator.free(commit_name);
    const commit_path = try std.fs.path.join(allocator, &.{ transactions_dir, commit_name });
    return .{
        .transaction_id = transaction_id,
        .prepared_path = prepared_path,
        .commit_path = commit_path,
        .sequence_before = sequence_before,
        .sequence_after = sequence_after,
    };
}

fn publishJsonlCheckpoint(
    fs: Fs,
    allocator: std.mem.Allocator,
    store_path: []const u8,
    existing: []const u8,
    checkpoint_line: []const u8,
    options: JsonlTransactionOptions,
    receipt: JsonlTransactionReceipt,
) !void {
    const prepared = try renderTransactionRecord(
        allocator,
        "prepared",
        receipt.transaction_id,
        store_path,
        options.operation,
        receipt.sequence_before,
        receipt.sequence_after,
    );
    defer allocator.free(prepared);
    const trimmed_checkpoint = std.mem.trim(u8, checkpoint_line, " \t\r\n");
    const combined = switch (options.mode) {
        .append => try combineJsonlAppend(allocator, existing, trimmed_checkpoint),
        .replace => try combineJsonlAppend(allocator, "", trimmed_checkpoint),
    };
    defer allocator.free(combined);
    const committed = try renderTransactionRecord(
        allocator,
        "committed",
        receipt.transaction_id,
        store_path,
        options.operation,
        receipt.sequence_before,
        receipt.sequence_after,
    );
    defer allocator.free(committed);
    try writeTextCreateNew(fs, allocator, receipt.prepared_path, prepared, .{});
    try writeTextAtomic(fs, allocator, store_path, combined);
    try writeTextCreateNew(fs, allocator, receipt.commit_path, committed, .{});
}

fn transactionLockNameAlloc(allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(store_path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return error.InvalidPath;
    }
    return allocator.print("{s}.lock", .{base});
}

fn combineJsonlAppend(allocator: std.mem.Allocator, existing: []const u8, line: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.writer.writeByte('\n');
    try out.writer.writeAll(line);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

test "lease locks enforce fencing tokens and reclaim expired metadata" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const resource = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(resource);
    const counter = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.counter" });
    defer std.testing.allocator.free(counter);
    const owner: Owner = .{
        .process_id = 100,
        .session_id = "session-a",
        .executor = "test",
    };
    const options: AcquireOptions = .{
        .owner = owner,
        .timeout_ms = 0,
        .retry_interval_ms = 1,
        .lease_ms = 1000,
        .fencing_counter_path = counter,
    };

    var lock = try acquireLeaseLock(fs, std.testing.allocator, resource, options);
    const counter_lock = try std.testing.allocator.print("{s}.lock", .{counter});
    defer std.testing.allocator.free(counter_lock);
    try std.testing.expect(lock.fencing_token > 0);
    try std.testing.expect(fileExists(fs, lock.path));
    try std.testing.expect(!fileExists(fs, counter_lock));
    try std.testing.expectError(
        error.LockBusy,
        acquireLeaseLock(
            fs,
            std.testing.allocator,
            resource,
            .{
                .owner = owner,
                .timeout_ms = 2,
                .retry_interval_ms = 1,
                .lease_ms = 1000,
                .fencing_counter_path = counter,
            },
        ),
    );

    try std.testing.expectError(error.FencingTokenStale, refreshLease(
        fs,
        std.testing.allocator,
        &lock,
        lock.fencing_token + 1,
        1000,
    ));
    try refreshLease(fs, std.testing.allocator, &lock, lock.fencing_token, 1000);

    const saved_executor = lock.owner.executor;
    lock.owner.executor = "other";
    try std.testing.expectError(
        error.LockOwnerMismatch,
        releaseLease(fs, std.testing.allocator, &lock, lock.fencing_token),
    );
    lock.owner.executor = saved_executor;
    try releaseLease(fs, std.testing.allocator, &lock, lock.fencing_token);

    try assertExpiredLeaseReclaimed(resource, owner, counter, options);
    try assertCorruptFencingCounterRejected(root, owner);
}

fn assertCorruptFencingCounterRejected(
    root: []const u8,
    owner: Owner,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const corrupt_resource = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "corrupt.jsonl" },
    );
    defer std.testing.allocator.free(corrupt_resource);
    const corrupt_counter = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "corrupt.counter" },
    );
    defer std.testing.allocator.free(corrupt_counter);
    try writeTextAtomic(fs, std.testing.allocator, corrupt_counter, "not-a-number\n");
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        acquireLeaseLock(fs, std.testing.allocator, corrupt_resource, .{
            .owner = owner,
            .fencing_counter_path = corrupt_counter,
        }),
    );
    const corrupt_counter_lock = try std.testing.allocator.print(
        "{s}.lock",
        .{corrupt_counter},
    );
    defer std.testing.allocator.free(corrupt_counter_lock);
    try std.testing.expect(!fileExists(fs, corrupt_counter_lock));
}

fn assertExpiredLeaseReclaimed(
    resource: []const u8,
    owner: Owner,
    counter: []const u8,
    options: AcquireOptions,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var expired = try acquireLeaseLock(fs, std.testing.allocator, resource, .{
        .owner = owner,
        .timeout_ms = 0,
        .retry_interval_ms = 1,
        .lease_ms = 1,
        .fencing_counter_path = counter,
    });
    const expired_token = expired.fencing_token;
    defer expired.deinit(std.testing.allocator);
    try std.Io.sleep(fs.io, .fromMilliseconds(3), .awake);
    const receipt = try reclaimExpiredLease(fs, std.testing.allocator, resource, options);
    defer {
        std.testing.allocator.free(receipt.lock_id);
        std.testing.allocator.free(receipt.resource);
        std.testing.allocator.free(receipt.result);
    }
    try std.testing.expectEqual(expired_token, receipt.previous_fencing_token);
    try std.testing.expect(receipt.authority_counter > expired_token);

    var after_reclaim = try acquireLeaseLock(fs, std.testing.allocator, resource, options);
    defer releaseLease(
        fs,
        std.testing.allocator,
        &after_reclaim,
        after_reclaim.fencing_token,
    ) catch |release_error| {
        std.debug.panic("failed to release reclaimed lease: {s}", .{@errorName(release_error)});
    };
    try std.testing.expect(after_reclaim.fencing_token > receipt.previous_fencing_token);
}

test "lease retry releases advisory custody before waiting" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const resource = try std.fs.path.join(
        allocator,
        &.{ root, "retry.jsonl" },
    );
    defer allocator.free(resource);
    const counter = try std.fs.path.join(
        allocator,
        &.{ root, "retry.counter" },
    );
    defer allocator.free(counter);
    const options: AcquireOptions = .{
        .owner = .{
            .process_id = 101,
            .session_id = "retry-custody",
            .executor = "test",
        },
        .fencing_counter_path = counter,
    };
    var lock = try acquireLeaseLock(fs, allocator, resource, options);
    const contender = try tryAcquireLeaseLockObserved(
        fs,
        allocator,
        resource,
        lock.path,
        counter,
        options,
        null,
    );
    try std.testing.expect(contender == null);
    try refreshLease(
        fs,
        allocator,
        &lock,
        lock.fencing_token,
        1000,
    );
    try releaseLease(fs, allocator, &lock, lock.fencing_token);
}

test "cas writes and jsonl snapshots reject stale expectations" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "state.jsonl" });
    defer std.testing.allocator.free(path);

    var first = try writeTextAtomicCas(
        fs,
        std.testing.allocator,
        path,
        "{\"seq\":1,\"ok\":true}\n",
        .{ .expected_exists = false },
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.digest_before == null);
    try std.testing.expectEqual(@as(?u64, null), first.sequence_before);
    try std.testing.expectEqual(@as(?u64, 1), first.sequence_after);

    var second = try writeTextAtomicCas(
        fs,
        std.testing.allocator,
        path,
        "{\"seq\":2,\"ok\":true}\n",
        .{
            .expected_digest = first.digest_after,
            .expected_sequence = 1,
            .expected_exists = true,
        },
    );
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 1), second.sequence_before);
    try std.testing.expectEqual(@as(?u64, 2), second.sequence_after);

    try std.testing.expectError(
        error.DigestMismatch,
        writeTextAtomicCas(
            fs,
            std.testing.allocator,
            path,
            "{\"seq\":3}\n",
            .{ .expected_digest = first.digest_after },
        ),
    );
    try std.testing.expectError(
        error.SequenceMismatch,
        writeTextAtomicCas(
            fs,
            std.testing.allocator,
            path,
            "{\"seq\":3}\n",
            .{ .expected_sequence = 1 },
        ),
    );
    try std.testing.expectError(
        error.ExpectationMismatch,
        writeTextAtomicCas(
            fs,
            std.testing.allocator,
            path,
            "{\"seq\":3}\n",
            .{ .expected_exists = false },
        ),
    );

    try assertJsonlSnapshotCasContract(path, second);
}

fn assertJsonlSnapshotCasContract(
    path: []const u8,
    second: CasWriteReceipt,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var snapshot = try readJsonlSnapshot(fs, std.testing.allocator, path, 2);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 2), snapshot.sequence);
    try std.testing.expectEqualStrings(second.digest_after, snapshot.digest);
    try std.testing.expectError(
        error.SequenceMismatch,
        readJsonlSnapshot(fs, std.testing.allocator, path, 1),
    );

    var committed = try commitJsonlSnapshotCas(
        fs,
        std.testing.allocator,
        path,
        "{\"seq\":3,\"ok\":true}\n",
        .{
            .expected_sequence = 2,
            .expected_digest = second.digest_after,
            .expected_exists = true,
        },
        "txn-cas-1",
    );
    defer committed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 2), committed.sequence_before);
    try std.testing.expectEqual(@as(?u64, 3), committed.sequence_after);
    try std.testing.expectEqualStrings("txn-cas-1", committed.transaction_id.?);

    try std.testing.expectError(
        error.InvalidJsonl,
        commitJsonlSnapshotCas(
            fs,
            std.testing.allocator,
            path,
            "not-json\n",
            .{ .expected_sequence = 3 },
            null,
        ),
    );
}

test "CAS targets cannot inhabit generated control paths" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        fs.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    for ([_][]const u8{
        "state.jsonl.cas.lock",
        "state.jsonl.cas.lock.advisory",
        "state.jsonl.CAS.LOCK",
        "state.jsonl.CAS.LOCK.ADVISORY",
        "state.jsonl.cas.lock/child.jsonl",
    }) |basename| {
        const path = try std.fs.path.join(
            std.testing.allocator,
            &.{ root, basename },
        );
        defer std.testing.allocator.free(path);
        try std.testing.expectError(
            error.ReservedCasControlPath,
            writeTextAtomicCas(
                fs,
                std.testing.allocator,
                path,
                "{\"seq\":1}\n",
                .{ .expected_exists = false },
            ),
        );
        try std.testing.expectError(
            error.FileNotFound,
            fs.directory().access(fs.io, path, .{}),
        );
    }
}

test "transactions reject CAS control aliases before creating directories" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        fs.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);
    const target_parent = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "state.jsonl.CAS.LOCK" },
    );
    defer std.testing.allocator.free(target_parent);
    const target = try std.fs.path.join(
        std.testing.allocator,
        &.{ target_parent, "child.jsonl" },
    );
    defer std.testing.allocator.free(target);
    const mutations = [_]TransactionMutation{.{
        .path = target,
        .text = "{\"seq\":1}\n",
        .expectation = .{ .expected_exists = false },
        .content_mode = .raw,
        .max_bytes = 4096,
    }};
    try std.testing.expectError(
        error.ReservedCasControlPath,
        commitTextTransaction(
            fs,
            std.testing.allocator,
            transactions_dir,
            &mutations,
            .{
                .owner = .{
                    .process_id = 1,
                    .session_id = "reserved-control-path",
                    .executor = "test",
                },
            },
        ),
    );
    for ([_][]const u8{ transactions_dir, target_parent }) |path| {
        try std.testing.expectError(
            error.FileNotFound,
            fs.directory().access(fs.io, path, .{}),
        );
    }
}

test "transactions reject missing descendants of case-aliased journal roots" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    if (!try directoryNameIsCaseInsensitive(
        fs,
        allocator,
        root,
        "Probe",
    )) {
        return error.SkipZigTest;
    }
    const transactions_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions" },
    );
    defer allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(fs, transactions_dir);
    const aliased_parent = try std.fs.path.join(
        allocator,
        &.{ root, "TRANSACTIONS", "missing" },
    );
    defer allocator.free(aliased_parent);
    const target = try std.fs.path.join(
        allocator,
        &.{ aliased_parent, "events.jsonl" },
    );
    defer allocator.free(target);
    const mutations = [_]TransactionMutation{.{
        .path = target,
        .text = "{\"seq\":1}\n",
        .expectation = .{ .expected_exists = false },
        .content_mode = .raw,
        .max_bytes = 4096,
    }};
    try std.testing.expectError(
        error.InvalidPath,
        commitTextTransaction(
            fs,
            allocator,
            transactions_dir,
            &mutations,
            .{
                .owner = .{
                    .process_id = 2,
                    .session_id = "case-aliased-journal-root",
                    .executor = "test",
                },
            },
        ),
    );
    try std.testing.expect(!fileExists(fs, aliased_parent));
}

test "transactions reject targets inside their journal namespace" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions" },
    );
    defer allocator.free(transactions_dir);
    const target = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "payload.json" },
    );
    defer allocator.free(target);
    const mutations = [_]TransactionMutation{.{
        .path = target,
        .text = "{}\n",
        .expectation = .{ .expected_exists = false },
        .content_mode = .raw,
    }};
    try std.testing.expectError(
        error.InvalidPath,
        commitTextTransaction(
            fs,
            allocator,
            transactions_dir,
            &mutations,
            .{
                .owner = .{
                    .process_id = 1,
                    .session_id = "journal-namespace",
                    .executor = "test",
                },
            },
        ),
    );
    try std.testing.expect(!fileExists(fs, target));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countPendingTransactions(fs, allocator, transactions_dir),
    );
}

test "transactions reject journals larger than recovery can represent" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions" },
    );
    defer allocator.free(transactions_dir);
    const target = try std.fs.path.join(
        allocator,
        &.{ root, "payload.json" },
    );
    defer allocator.free(target);
    const mutations = try allocator.alloc(
        TransactionMutation,
        transaction_recovery_max_rows + 1,
    );
    defer allocator.free(mutations);
    for (mutations) |*mutation| {
        mutation.* = .{
            .path = target,
            .text = "{}\n",
            .content_mode = .raw,
        };
    }
    try std.testing.expectError(
        error.TooManyFiles,
        commitTextTransaction(
            fs,
            allocator,
            transactions_dir,
            mutations,
            .{
                .owner = .{
                    .process_id = 1,
                    .session_id = "recovery-row-bound",
                    .executor = "test",
                },
            },
        ),
    );
    try std.testing.expect(!fileExists(fs, transactions_dir));
}

const CasWorkerContext = struct {
    path: []const u8,
    result: ?anyerror = null,
};

fn runCasWorker(context: *CasWorkerContext) void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var receipt = writeTextAtomicCas(
        fs,
        std.heap.smp_allocator,
        context.path,
        "{\"seq\":2,\"worker\":true}\n",
        .{
            .expected_sequence = 1,
            .expected_exists = true,
        },
    ) catch |err| {
        context.result = err;
        return;
    };
    receipt.deinit(std.heap.smp_allocator);
    context.result = null;
}

test "cas sidecar serializes comparison before write" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "state.jsonl" });
    defer std.testing.allocator.free(path);
    try writeTextAtomic(fs, std.testing.allocator, path, "{\"seq\":1,\"main\":true}\n");

    const lock_path = try casLockPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(lock_path);
    var held_lock = try acquireExclusiveLockPath(fs, std.testing.allocator, lock_path);

    var context: CasWorkerContext = .{ .path = path };
    const thread = try std.Thread.spawn(.{}, runCasWorker, .{&context});
    try std.Io.sleep(fs.io, .fromMilliseconds(10), .awake);
    try writeTextAtomic(fs, std.testing.allocator, path, "{\"seq\":2,\"main\":true}\n");
    held_lock.release(std.testing.allocator);
    thread.join();

    try std.testing.expect(context.result != null);
    try std.testing.expectEqual(error.SequenceMismatch, context.result.?);
    const final = try tryReadForTest(path);
    defer std.testing.allocator.free(final);
    try std.testing.expectEqualStrings("{\"seq\":2,\"main\":true}\n", final);
}

test "durable transactions atomically publish bounded raw documents" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);
    const counter = try std.fs.path.join(std.testing.allocator, &.{ root, "fencing.counter" });
    defer std.testing.allocator.free(counter);
    const document_path = try std.fs.path.join(std.testing.allocator, &.{ root, "document.json" });
    defer std.testing.allocator.free(document_path);
    const binding_path = try std.fs.path.join(std.testing.allocator, &.{ root, "binding.json" });
    defer std.testing.allocator.free(binding_path);
    const mutations = [_]TransactionMutation{
        .{
            .path = document_path,
            .text = "{\"value\":1}\n",
            .expectation = .{
                .expected_exists = false,
                .expected_sequence = 0,
            },
            .content_mode = .raw,
            .max_bytes = 4096,
        },
        .{
            .path = binding_path,
            .text = "{\"definition_digest\":\"sha256:test\"}\n",
            .expectation = .{ .expected_exists = false },
            .content_mode = .raw,
            .max_bytes = 4096,
        },
    };
    var receipt = try commitTextTransaction(
        fs,
        std.testing.allocator,
        transactions_dir,
        &mutations,
        .{
            .owner = .{
                .process_id = 300,
                .session_id = "raw-transaction",
                .executor = "test",
            },
            .fencing_counter_path = counter,
        },
    );
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(.committed, receipt.state);
    const document = try tryReadForTest(document_path);
    defer std.testing.allocator.free(document);
    try std.testing.expectEqualStrings("{\"value\":1}\n", document);
    const binding = try tryReadForTest(binding_path);
    defer std.testing.allocator.free(binding);
    try std.testing.expectEqualStrings("{\"definition_digest\":\"sha256:test\"}\n", binding);

    try assertRawTransactionRejectsStaleDigest(document_path, transactions_dir, counter);
    try assertRawTransactionRejectsHardlink(root, document_path, transactions_dir, counter);
}

fn assertRawTransactionRejectsHardlink(
    root: []const u8,
    document_path: []const u8,
    transactions_dir: []const u8,
    counter: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var root_dir = try std.Io.Dir.openDirAbsolute(fs.io, root, .{});
    defer root_dir.close(fs.io);
    try root_dir.hardLink("document.json", root_dir, "document-alias.json", fs.io, .{});
    const hardlinked = [_]TransactionMutation{.{
        .path = document_path,
        .text = "{\"value\":3}\n",
        .expectation = .{ .expected_exists = true },
        .content_mode = .raw,
        .max_bytes = 4096,
    }};
    try std.testing.expectError(
        error.HardlinkTarget,
        commitTextTransaction(
            fs,
            std.testing.allocator,
            transactions_dir,
            &hardlinked,
            .{
                .owner = .{
                    .process_id = 302,
                    .session_id = "raw-hardlink",
                    .executor = "test",
                },
                .fencing_counter_path = counter,
            },
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countPendingTransactions(fs, std.testing.allocator, transactions_dir),
    );
}

fn assertRawTransactionRejectsStaleDigest(
    document_path: []const u8,
    transactions_dir: []const u8,
    counter: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const stale = [_]TransactionMutation{.{
        .path = document_path,
        .text = "{\"value\":2}\n",
        .expectation = .{
            .expected_digest = "sha256:" ++
                "0000000000000000000000000000000000000000000000000000000000000000",
            .expected_exists = true,
        },
        .content_mode = .raw,
        .max_bytes = 4096,
    }};
    try std.testing.expectError(
        error.DigestMismatch,
        commitTextTransaction(
            fs,
            std.testing.allocator,
            transactions_dir,
            &stale,
            .{
                .owner = .{
                    .process_id = 301,
                    .session_id = "raw-stale",
                    .executor = "test",
                },
                .fencing_counter_path = counter,
            },
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countPendingTransactions(fs, std.testing.allocator, transactions_dir),
    );
}

test "transaction publication binds staged bytes before target replacement" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions", "txn-race" },
    );
    defer std.testing.allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root, "store.jsonl" });
    defer std.testing.allocator.free(target_path);
    try writeTextCreateNew(fs, std.testing.allocator, target_path, "{\"seq\":1}\n", .{});
    const staged_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ transaction_dir, "write-0.staged" },
    );
    defer std.testing.allocator.free(staged_path);
    try writeTextCreateNew(fs, std.testing.allocator, staged_path, "{\"seq\":999}\n", .{});
    const expected_digest = try digestBytesAlloc(std.testing.allocator, "{\"seq\":2}\n");
    defer std.testing.allocator.free(expected_digest);
    var target = try TransactionTarget.init(fs, root, target_path);
    defer target.deinit();
    var staged_dir = try std.Io.Dir.openDirAbsolute(
        fs.io,
        transaction_dir,
        .{ .follow_symlinks = false },
    );
    defer staged_dir.close(fs.io);

    try std.testing.expectError(
        error.TransactionCorrupt,
        publishVerifiedStagedFile(
            fs,
            &staged_dir,
            "write-0.staged",
            expected_digest,
            4096,
            &target,
        ),
    );
    const current = try readFileAlloc(fs, std.testing.allocator, target_path, 4096);
    defer std.testing.allocator.free(current);
    try std.testing.expectEqualStrings("{\"seq\":1}\n", current);

    try staged_dir.deleteFile(fs.io, "write-0.staged");
    try staged_dir.symLink(fs.io, target_path, "write-0.staged", .{});
    try std.testing.expectError(
        error.SymlinkComponent,
        publishVerifiedStagedFile(
            fs,
            &staged_dir,
            "write-0.staged",
            expected_digest,
            4096,
            &target,
        ),
    );
    const after = try readFileAlloc(fs, std.testing.allocator, target_path, 4096);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("{\"seq\":1}\n", after);
}

test "pending transaction bounds exclude committed flat journals" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);
    const root = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "transactions" });
    defer std.testing.allocator.free(root);
    try ensureDirectoryPathNoSymlinks(fs, root);
    for (0..5) |index| {
        const prepared = try std.testing.allocator.print(
            "transactions/txn-{d}.prepared.json",
            .{index},
        );
        defer std.testing.allocator.free(prepared);
        const committed = try std.testing.allocator.print(
            "transactions/txn-{d}.commit.json",
            .{index},
        );
        defer std.testing.allocator.free(committed);
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = prepared,
            .data = "{}\n",
        });
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = committed,
            .data = "{}\n",
        });
    }
    try std.testing.expectEqual(
        @as(usize, 0),
        try countPendingTransactionsBounded(fs, std.testing.allocator, root, 0, 16),
    );
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "transactions/pending.prepared.json",
        .data = "{}\n",
    });
    try std.testing.expectError(
        error.TooManyFiles,
        countPendingTransactionsBounded(fs, std.testing.allocator, root, 0, 16),
    );
}

test "transaction recovery hashes admitted stores above the snapshot allocation bound" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const target = try std.fs.path.join(std.testing.allocator, &.{ root, "large-document.bin" });
    defer std.testing.allocator.free(target);
    const bytes = try std.testing.allocator.alloc(u8, default_snapshot_max_bytes + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try writeTextAtomic(fs, std.testing.allocator, target, bytes);
    const digest = try digestBytesAlloc(std.testing.allocator, bytes);
    defer std.testing.allocator.free(digest);
    const writes = [_]TransactionWrite{.{
        .path = target,
        .staged_ref = "write-0.staged",
        .digest_after = digest,
        .sequence_after = 0,
    }};
    var hash_bytes_remaining = transaction_recovery_hash_max_bytes;
    const published = try transactionPublishedCount(
        fs,
        std.testing.allocator,
        root,
        &writes,
        &.{},
        &hash_bytes_remaining,
    );
    try std.testing.expectEqual(@as(?usize, 1), published);
}

test "transaction recovery hashing consumes one aggregate budget" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(fs.io, .{
        .sub_path = "first",
        .data = "1234",
    });
    try tmp.dir.writeFile(fs.io, .{
        .sub_path = "second",
        .data = "5678",
    });
    var dir = try std.Io.Dir.openDirAbsolute(fs.io, root, .{ .follow_symlinks = false });
    defer dir.close(fs.io);
    var hash_bytes_remaining: usize = 7;
    const first = try digestRecoveryFileAtAlloc(
        fs,
        allocator,
        &dir,
        "first",
        &hash_bytes_remaining,
    );
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 3), hash_bytes_remaining);
    try std.testing.expectError(
        error.TransactionRecoveryWorkExceeded,
        digestRecoveryFileAtAlloc(fs, allocator, &dir, "second", &hash_bytes_remaining),
    );
}

test "recovery scan shares one hash budget across transaction journals" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(fs, transactions_dir);
    const content = "{\"seq\":1}\n";
    for (0..2) |index| {
        const transaction_id = try allocator.print(
            "dtx-1-0000000000000000000000000000000{d}",
            .{index + 1},
        );
        defer allocator.free(transaction_id);
        const target_path = try allocator.print(
            "{s}/events-{d}.jsonl",
            .{ root, index },
        );
        defer allocator.free(target_path);
        try writeTextAtomic(fs, allocator, target_path, content);
        try writeCommittedRecoveryJournalForTest(
            allocator,
            transactions_dir,
            transaction_id,
            target_path,
            content,
        );
    }
    var summary: TransactionRecoverySummary = .{};
    var hash_bytes_remaining = content.len * 2 - 1;
    try std.testing.expectError(
        error.TransactionRecoveryWorkExceeded,
        recoverAndCompactTransactionsAccumulatingWithHashBudget(
            fs,
            allocator,
            transactions_dir,
            .{},
            &summary,
            &hash_bytes_remaining,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), summary.transaction_count);
    try std.testing.expectEqual(content.len - 1, hash_bytes_remaining);
}

test "durable transactions compare check-only participants without rewriting them" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);
    const counter = try std.fs.path.join(std.testing.allocator, &.{ root, "fencing.counter" });
    defer std.testing.allocator.free(counter);
    const guarded_path = try std.fs.path.join(std.testing.allocator, &.{ root, "guarded.jsonl" });
    defer std.testing.allocator.free(guarded_path);
    const metadata_path = try std.fs.path.join(std.testing.allocator, &.{ root, "binding.jsonl" });
    defer std.testing.allocator.free(metadata_path);
    const guarded = "{\"seq\":1}\n";
    try writeTextAtomic(fs, std.testing.allocator, guarded_path, guarded);
    const guarded_digest = try digestBytesAlloc(std.testing.allocator, guarded);
    defer std.testing.allocator.free(guarded_digest);
    const mutations = [_]TransactionMutation{
        .{
            .path = guarded_path,
            .text = "",
            .expectation = .{
                .expected_digest = guarded_digest,
                .expected_exists = true,
            },
            .content_mode = .raw,
            .max_bytes = 4096,
            .action = .check_only,
        },
        .{
            .path = metadata_path,
            .text = "{\"bound\":true}\n",
            .expectation = .{ .expected_exists = false },
            .content_mode = .raw,
            .max_bytes = 4096,
        },
    };
    var receipt = try commitTextTransaction(
        fs,
        std.testing.allocator,
        transactions_dir,
        &mutations,
        .{
            .owner = .{
                .process_id = 400,
                .session_id = "check-only",
                .executor = "test",
            },
            .fencing_counter_path = counter,
        },
    );
    defer receipt.deinit(std.testing.allocator);
    const guarded_after = try readRegularFileNoSymlink(
        fs,
        std.testing.allocator,
        guarded_path,
        4096,
    );
    defer std.testing.allocator.free(guarded_after);
    try std.testing.expectEqualStrings(guarded, guarded_after);
    const metadata = try readRegularFileNoSymlink(fs, std.testing.allocator, metadata_path, 4096);
    defer std.testing.allocator.free(metadata);
    try std.testing.expectEqualStrings("{\"bound\":true}\n", metadata);

    try assertCheckOnlyRejectsStaleDigest(guarded_path, transactions_dir, counter);
}

fn assertCheckOnlyRejectsStaleDigest(
    guarded_path: []const u8,
    transactions_dir: []const u8,
    counter: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const stale = [_]TransactionMutation{.{
        .path = guarded_path,
        .text = "",
        .expectation = .{
            .expected_digest = "sha256:" ++
                "0000000000000000000000000000000000000000000000000000000000000000",
            .expected_exists = true,
        },
        .content_mode = .raw,
        .max_bytes = 4096,
        .action = .check_only,
    }};
    try std.testing.expectError(
        error.DigestMismatch,
        commitTextTransaction(
            fs,
            std.testing.allocator,
            transactions_dir,
            &stale,
            .{
                .owner = .{
                    .process_id = 401,
                    .session_id = "check-only-stale",
                    .executor = "test",
                },
                .fencing_counter_path = counter,
            },
        ),
    );
}

const GuardedTransactionContext = struct {
    fs: Fs,
    transactions_dir: []const u8,
    counter_path: []const u8,
    guarded_path: []const u8,
    guarded_digest: []const u8,
    metadata_path: []const u8,
    result: ?anyerror = null,
};

fn runGuardedTransaction(context: *GuardedTransactionContext) void {
    const fs = context.fs;
    const mutations = [_]TransactionMutation{
        .{
            .path = context.guarded_path,
            .text = "",
            .expectation = .{
                .expected_digest = context.guarded_digest,
                .expected_exists = true,
            },
            .content_mode = .raw,
            .max_bytes = 4096,
            .action = .check_only,
        },
        .{
            .path = context.metadata_path,
            .text = "{\"bound\":true}\n",
            .expectation = .{ .expected_exists = false },
            .content_mode = .raw,
            .max_bytes = 4096,
        },
    };
    var receipt = commitTextTransaction(
        fs,
        std.heap.smp_allocator,
        context.transactions_dir,
        &mutations,
        .{
            .owner = .{
                .process_id = 402,
                .session_id = "check-only-race",
                .executor = "test",
            },
            .fencing_counter_path = context.counter_path,
        },
    ) catch |err| {
        context.result = err;
        return;
    };
    receipt.deinit(std.heap.smp_allocator);
    context.result = null;
}

test "durable transactions hold check-only CAS guards through publication" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);
    const counter = try std.fs.path.join(std.testing.allocator, &.{ root, "fencing.counter" });
    defer std.testing.allocator.free(counter);
    const guarded_path = try std.fs.path.join(std.testing.allocator, &.{ root, "guarded.jsonl" });
    defer std.testing.allocator.free(guarded_path);
    const metadata_path = try std.fs.path.join(std.testing.allocator, &.{ root, "binding.jsonl" });
    defer std.testing.allocator.free(metadata_path);
    const before = "{\"seq\":1}\n";
    try writeTextAtomic(fs, std.testing.allocator, guarded_path, before);
    const before_digest = try digestBytesAlloc(std.testing.allocator, before);
    defer std.testing.allocator.free(before_digest);
    const lock_path = try casLockPathAlloc(std.testing.allocator, guarded_path);
    defer std.testing.allocator.free(lock_path);
    var held_lock = try acquireExclusiveLockPath(fs, std.testing.allocator, lock_path);
    var context = GuardedTransactionContext{
        .fs = fs,
        .transactions_dir = transactions_dir,
        .counter_path = counter,
        .guarded_path = guarded_path,
        .guarded_digest = before_digest,
        .metadata_path = metadata_path,
    };
    const thread = try std.Thread.spawn(.{}, runGuardedTransaction, .{&context});
    try std.Io.sleep(fs.io, .fromMilliseconds(10), .awake);
    try writeTextAtomic(fs, std.testing.allocator, guarded_path, "{\"seq\":2}\n");
    held_lock.release(std.testing.allocator);
    thread.join();
    try std.testing.expectEqual(error.DigestMismatch, context.result.?);
    try std.testing.expect(!fileExists(fs, metadata_path));
}

test "durable transactions commit and recover from prepared records" {
    const allocator = std.testing.allocator;
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir =
        try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(fs, transactions_dir);
    const counter = try std.fs.path.join(allocator, &.{ root, "workspace.counter" });
    defer allocator.free(counter);
    const owner: Owner = .{
        .process_id = 200,
        .session_id = "txn-session",
        .executor = "test",
    };

    const workspace_path =
        try std.fs.path.join(allocator, &.{ root, "workspace.jsonl" });
    defer allocator.free(workspace_path);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "plan.jsonl" });
    defer allocator.free(plan_path);
    try writeTextAtomic(fs, allocator, workspace_path, "{\"seq\":1,\"workspace\":true}\n");
    try writeTextAtomic(fs, allocator, plan_path, "{\"seq\":1,\"plan\":true}\n");
    const mutations = [_]TransactionMutation{
        .{
            .path = plan_path,
            .text = "{\"seq\":2,\"plan\":true}\n",
            .expectation = .{
                .expected_sequence = 1,
                .expected_exists = true,
            },
        },
        .{
            .path = workspace_path,
            .text = "{\"seq\":2,\"workspace\":true}\n",
            .expectation = .{
                .expected_sequence = 1,
                .expected_exists = true,
            },
        },
    };
    var receipt = try commitTextTransaction(
        fs,
        allocator,
        transactions_dir,
        &mutations,
        .{
            .owner = owner,
            .fencing_counter_path = counter,
        },
    );
    defer receipt.deinit(allocator);
    try std.testing.expectEqual(TransactionState.committed, receipt.state);
    try std.testing.expect(fileExists(fs, receipt.commit_marker_path));
    const workspace_data = try tryReadForTest(workspace_path);
    defer allocator.free(workspace_data);
    try std.testing.expectEqualStrings("{\"seq\":2,\"workspace\":true}\n", workspace_data);
    var committed_status =
        try inspectTransaction(fs, allocator, receipt.transaction_dir);
    defer committed_status.deinit(allocator);
    try std.testing.expectEqual(RecoveryDecision.already_committed, committed_status.decision);

    try assertPreparedUnpublishedRecovery(root, transactions_dir, owner);
    try assertPreparedPublishedRecovery(root, transactions_dir, owner);
    try assertPreparedMixedRecovery(root, transactions_dir, owner);
}

fn assertPreparedMixedRecovery(
    root: []const u8,
    transactions_dir: []const u8,
    owner: Owner,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const mixed_id = "dtx-1-00000000000000000000000000000005";
    const mixed_dir = try std.fs.path.join(std.testing.allocator, &.{ transactions_dir, mixed_id });
    defer std.testing.allocator.free(mixed_dir);
    try ensureDirectoryPathNoSymlinks(fs, mixed_dir);
    const mixed_record = try std.fs.path.join(
        std.testing.allocator,
        &.{ mixed_dir, "transaction.json" },
    );
    defer std.testing.allocator.free(mixed_record);
    const mixed_a = try std.fs.path.join(std.testing.allocator, &.{ root, "mixed-a.jsonl" });
    defer std.testing.allocator.free(mixed_a);
    const mixed_b = try std.fs.path.join(std.testing.allocator, &.{ root, "mixed-b.jsonl" });
    defer std.testing.allocator.free(mixed_b);
    try writeTextAtomic(fs, std.testing.allocator, mixed_a, "{\"seq\":2}\n");
    try writeTextAtomic(fs, std.testing.allocator, mixed_b, "{\"seq\":1}\n");
    try writePreparedTwoWriteRecordForTest(
        std.testing.allocator,
        mixed_record,
        mixed_id,
        owner,
        mixed_a,
        mixed_b,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countPendingTransactions(fs, std.testing.allocator, transactions_dir),
    );
    var mixed_status = try inspectTransaction(fs, std.testing.allocator, mixed_dir);
    defer mixed_status.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, mixed_status.decision);
    var mixed_receipt = try recoverTransaction(fs, std.testing.allocator, mixed_dir);
    defer mixed_receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, mixed_receipt.decision);
    const mixed_b_after = try tryReadForTest(mixed_b);
    defer std.testing.allocator.free(mixed_b_after);
    try std.testing.expectEqualStrings("{\"seq\":2}\n", mixed_b_after);
}

fn assertPreparedPublishedRecovery(
    root: []const u8,
    transactions_dir: []const u8,
    owner: Owner,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const finish_id = "dtx-1-00000000000000000000000000000004";
    const finish_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ transactions_dir, finish_id },
    );
    defer std.testing.allocator.free(finish_dir);
    try ensureDirectoryPathNoSymlinks(fs, finish_dir);
    const finish_record = try std.fs.path.join(
        std.testing.allocator,
        &.{ finish_dir, "transaction.json" },
    );
    defer std.testing.allocator.free(finish_record);
    const finish_path = try std.fs.path.join(std.testing.allocator, &.{ root, "finish.jsonl" });
    defer std.testing.allocator.free(finish_path);
    try writeTextAtomic(fs, std.testing.allocator, finish_path, "{\"seq\":2}\n");
    try writePreparedRecordForTest(
        std.testing.allocator,
        finish_record,
        finish_id,
        owner,
        finish_path,
        "{\"seq\":1}\n",
        "{\"seq\":2}\n",
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countPendingTransactions(fs, std.testing.allocator, transactions_dir),
    );
    var finish_status = try inspectTransaction(fs, std.testing.allocator, finish_dir);
    defer finish_status.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, finish_status.decision);
    var finish_receipt = try recoverTransaction(fs, std.testing.allocator, finish_dir);
    defer finish_receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, finish_receipt.decision);
    const finish_marker = try std.fs.path.join(
        std.testing.allocator,
        &.{ finish_dir, "commit.json" },
    );
    defer std.testing.allocator.free(finish_marker);
    try std.testing.expect(fileExists(fs, finish_marker));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countPendingTransactions(fs, std.testing.allocator, transactions_dir),
    );
}

fn assertPreparedUnpublishedRecovery(
    root: []const u8,
    transactions_dir: []const u8,
    owner: Owner,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const rollback_id = "dtx-1-00000000000000000000000000000003";
    const rollback_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ transactions_dir, rollback_id },
    );
    defer std.testing.allocator.free(rollback_dir);
    try ensureDirectoryPathNoSymlinks(fs, rollback_dir);
    const rollback_record = try std.fs.path.join(
        std.testing.allocator,
        &.{ rollback_dir, "transaction.json" },
    );
    defer std.testing.allocator.free(rollback_record);
    const rollback_path = try std.fs.path.join(std.testing.allocator, &.{ root, "rollback.jsonl" });
    defer std.testing.allocator.free(rollback_path);
    try writeTextAtomic(fs, std.testing.allocator, rollback_path, "{\"seq\":1}\n");
    try writePreparedRecordForTest(
        std.testing.allocator,
        rollback_record,
        rollback_id,
        owner,
        rollback_path,
        "{\"seq\":1}\n",
        "{\"seq\":2}\n",
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countPendingTransactions(fs, std.testing.allocator, transactions_dir),
    );
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        ensureNoPendingTransactions(fs, std.testing.allocator, transactions_dir),
    );
    var rollback_status = try inspectTransaction(fs, std.testing.allocator, rollback_dir);
    defer rollback_status.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, rollback_status.decision);
    var rollback_receipt = try recoverTransaction(fs, std.testing.allocator, rollback_dir);
    defer rollback_receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, rollback_receipt.decision);
    const rollback_after = try tryReadForTest(rollback_path);
    defer std.testing.allocator.free(rollback_after);
    try std.testing.expectEqualStrings("{\"seq\":2}\n", rollback_after);
    try std.testing.expectEqual(
        @as(usize, 0),
        try countPendingTransactions(fs, std.testing.allocator, transactions_dir),
    );
}

test "preparing transaction recovery removes only journal-owned stages" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-1-00000000000000000000000000000001";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const before = "{\"seq\":1}\n";
    try writeTextAtomic(fs, allocator, target_path, before);
    const before_digest = try digestBytesAlloc(allocator, before);
    defer allocator.free(before_digest);
    const staged_ref = try transactionStageNameAlloc(allocator, transaction_id, 0);
    defer allocator.free(staged_ref);
    const staged_path = try std.fs.path.join(allocator, &.{ transaction_dir, staged_ref });
    defer allocator.free(staged_path);
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = before_digest,
        .sequence = 1,
    }};
    const writes = [_]TransactionWrite{.{
        .path = target_path,
        .staged_ref = staged_ref,
        .digest_after = "",
        .sequence_after = 2,
    }};
    const owner: Owner = .{
        .process_id = 902,
        .session_id = "preparing-recovery",
        .executor = "test",
    };
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        owner,
        .preparing,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
    try writeTextCreateNew(fs, allocator, staged_path, "{\"seq\":2}\n", .{});

    var status = try inspectTransaction(fs, allocator, transaction_dir);
    defer status.deinit(allocator);
    try std.testing.expectEqual(RecoveryDecision.roll_back_unpublished, status.decision);
    var receipt = try recoverTransaction(fs, allocator, transaction_dir);
    defer receipt.deinit(allocator);
    try std.testing.expectEqual(RecoveryDecision.roll_back_unpublished, receipt.decision);
    try std.testing.expect(receipt.storage_mutated);
    try std.testing.expect(!fileExists(fs, staged_path));
    const after = try tryReadForTest(target_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "transaction recovery reclaims only empty current recordless journals" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const incomplete_dir = try std.fs.path.join(
        allocator,
        &.{
            transactions_dir,
            "dtx-1-00000000000000000000000000000006",
        },
    );
    defer allocator.free(incomplete_dir);
    try ensureDirectoryPathNoSymlinks(fs, incomplete_dir);

    try std.testing.expectEqual(
        @as(usize, 1),
        try countPendingTransactions(fs, allocator, transactions_dir),
    );
    try recoverAndCompactTransactions(fs, allocator, transactions_dir);
    try std.testing.expect(!fileExists(fs, incomplete_dir));

    const nonempty_current_dir = try std.fs.path.join(
        allocator,
        &.{
            transactions_dir,
            "dtx-1-00000000000000000000000000000008",
        },
    );
    defer allocator.free(nonempty_current_dir);
    try ensureDirectoryPathNoSymlinks(fs, nonempty_current_dir);
    const current_unowned_path = try std.fs.path.join(
        allocator,
        &.{ nonempty_current_dir, "unknown" },
    );
    defer allocator.free(current_unowned_path);
    try writeTextAtomic(fs, allocator, current_unowned_path, "retain");
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactions(fs, allocator, transactions_dir),
    );
    try std.testing.expect(fileExists(fs, current_unowned_path));
    try fs.directory().deleteTree(fs.io, nonempty_current_dir);

    try assertLegacyRecordlessJournalsRetained(root, transactions_dir);
}

fn assertLegacyRecordlessJournalsRetained(
    root: []const u8,
    transactions_dir: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    const legacy_incomplete_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-1" });
    defer allocator.free(legacy_incomplete_dir);
    try ensureDirectoryPathNoSymlinks(fs, legacy_incomplete_dir);
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactions(fs, allocator, transactions_dir),
    );
    try std.testing.expect(fileExists(fs, legacy_incomplete_dir));
    const counter_path = try std.fs.path.join(allocator, &.{ root, "fencing.counter" });
    defer allocator.free(counter_path);
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{ .shared = counter_path },
            },
        ),
    );
    try std.testing.expect(fileExists(fs, legacy_incomplete_dir));

    try fs.directory().deleteDir(fs.io, legacy_incomplete_dir);
    const nonempty_legacy_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-2" });
    defer allocator.free(nonempty_legacy_dir);
    try ensureDirectoryPathNoSymlinks(fs, nonempty_legacy_dir);
    const unowned_path = try std.fs.path.join(allocator, &.{ nonempty_legacy_dir, "unknown" });
    defer allocator.free(unowned_path);
    try writeTextAtomic(fs, allocator, unowned_path, "retain");
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{ .shared = counter_path },
            },
        ),
    );
    try std.testing.expect(fileExists(fs, unowned_path));
}

test "transaction recovery reports recovery lock creation as mutation" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(fs, transactions_dir);

    const first = try recoverAndCompactTransactionsWithOptions(
        fs,
        allocator,
        transactions_dir,
        .{},
    );
    try std.testing.expect(first.storage_mutated);
    const second = try recoverAndCompactTransactionsWithOptions(
        fs,
        allocator,
        transactions_dir,
        .{},
    );
    try std.testing.expect(!second.storage_mutated);

    const invalid_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "invalid" });
    defer allocator.free(invalid_dir);
    try ensureDirectoryPathNoSymlinks(fs, invalid_dir);
    var failed: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverAndCompactTransactionsAccumulating(fs, allocator, transactions_dir, .{}, &failed),
    );
    try std.testing.expect(failed.storage_mutated);
}

test "committed legacy journals require syncable target parents before compaction" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-1";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const commit_marker_path = try transactionCommitMarkerPathAlloc(allocator, transaction_dir);
    defer allocator.free(commit_marker_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const removed_target_parent = try std.fs.path.join(allocator, &.{ root, "removed" });
    defer allocator.free(removed_target_parent);
    const removed_target_path = try std.fs.path.join(
        allocator,
        &.{ removed_target_parent, "events.jsonl" },
    );
    defer allocator.free(removed_target_path);
    const content = "{\"seq\":1}\n";
    try writeTextAtomic(fs, allocator, target_path, content);
    try writeTextAtomic(fs, allocator, removed_target_path, content);
    const content_digest = try digestBytesAlloc(allocator, content);
    defer allocator.free(content_digest);
    try writeCommittedLegacyParentRecord(
        record_path,
        transaction_id,
        target_path,
        removed_target_path,
        content_digest,
    );
    try writeCommittedTransactionMarker(fs, allocator, commit_marker_path);
    const counter_path = try std.fs.path.join(allocator, &.{ root, ".fencing.counter" });
    defer allocator.free(counter_path);
    try writeTextAtomic(fs, allocator, counter_path, "10\n");
    try writeTextAtomic(fs, allocator, target_path, "{\"seq\":2}\n");
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{ .legacy_fencing_authority = .{ .shared = counter_path } },
        ),
    );
    try std.testing.expect(fileExists(fs, transaction_dir));
    try writeTextAtomic(fs, allocator, target_path, content);
    try fs.directory().deleteTree(fs.io, removed_target_parent);
    try assertLegacyRecoveryRequiresSyncableParents(
        target_path,
        counter_path,
        transactions_dir,
        transaction_dir,
        removed_target_parent,
        content,
    );
}

fn assertLegacyRecoveryRequiresSyncableParents(
    target_path: []const u8,
    counter_path: []const u8,
    transactions_dir: []const u8,
    transaction_dir: []const u8,
    removed_target_parent: []const u8,
    content: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var expired_lease = try acquireLeaseLock(
        fs,
        allocator,
        target_path,
        .{
            .owner = .{
                .process_id = 906,
                .session_id = "legacy-committed-compatibility",
                .executor = "test",
            },
            .lease_ms = 1,
            .fencing_counter_path = counter_path,
        },
    );
    try std.Io.sleep(fs.io, .fromMilliseconds(3), .awake);

    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{ .legacy_fencing_authority = .{ .shared = counter_path } },
        ),
    );
    try std.testing.expect(fileExists(fs, transaction_dir));
    try std.testing.expect(fileExists(fs, expired_lease.path));
    try releaseLease(fs, allocator, &expired_lease, expired_lease.fencing_token);
    try std.testing.expectError(
        error.FileNotFound,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{ .legacy_fencing_authority = .{ .shared = counter_path } },
        ),
    );
    try std.testing.expect(fileExists(fs, transaction_dir));
    try std.testing.expect(!fileExists(fs, expired_lease.path));
    try std.testing.expect(!fileExists(fs, removed_target_parent));
    const after = try tryReadForTest(target_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(content, after);
}

fn writeCommittedLegacyParentRecord(
    record_path: []const u8,
    transaction_id: []const u8,
    target_path: []const u8,
    removed_target_path: []const u8,
    content_digest: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    const expected = [_]TransactionExpected{
        .{
            .path = target_path,
            .digest = content_digest,
            .sequence = 1,
        },
        .{
            .path = removed_target_path,
            .digest = content_digest,
            .sequence = 1,
        },
    };
    const writes = [_]TransactionWrite{
        .{
            .path = target_path,
            .staged_ref = "write-0.staged",
            .digest_after = content_digest,
            .sequence_after = 1,
        },
        .{
            .path = removed_target_path,
            .staged_ref = "write-1.staged",
            .digest_after = content_digest,
            .sequence_after = 1,
        },
    };
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 906,
            .session_id = "legacy-committed-compatibility",
            .executor = "test",
        },
        .committed,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
}

test "committed legacy journals retain fail-closed lease custody until marker" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-20" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "guard.json" });
    defer allocator.free(target_path);
    const content = "{\"guard\":true}\n";
    try writeTextAtomic(fs, allocator, target_path, content);
    const digest = try digestBytesAlloc(allocator, content);
    defer allocator.free(digest);
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = digest,
        .sequence = 0,
    }};
    const owner: Owner = .{
        .process_id = 920,
        .session_id = "legacy-committed-custody",
        .executor = "test",
    };
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        "dtx-20",
        owner,
        .committed,
        &expected,
        &.{},
        &.{},
        1,
        2,
        true,
    );
    const counter_path = try std.fs.path.join(allocator, &.{ root, "fencing.counter" });
    defer allocator.free(counter_path);
    try assertLegacyRecoveryWaitsForWriter(transactions_dir, target_path, owner, counter_path);
    try assertLegacyRecoveryLeaseLifetime(&expected, owner, counter_path);
    try assertLegacyTerminalRecoveryReclaimsLease(
        transaction_dir,
        transactions_dir,
        target_path,
        owner,
        counter_path,
    );
}

fn assertLegacyTerminalRecoveryReclaimsLease(
    transaction_dir: []const u8,
    transactions_dir: []const u8,
    target_path: []const u8,
    owner: Owner,
    counter_path: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    const commit_marker_path = try transactionCommitMarkerPathAlloc(allocator, transaction_dir);
    defer allocator.free(commit_marker_path);
    try writeCommittedTransactionMarker(fs, allocator, commit_marker_path);
    var expired_terminal_lease = try acquireLeaseLock(
        fs,
        allocator,
        target_path,
        .{
            .owner = owner,
            .lease_ms = 1,
            .fencing_counter_path = counter_path,
        },
    );
    try std.Io.sleep(fs.io, .fromMilliseconds(3), .awake);
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{ .legacy_fencing_authority = .{ .shared = counter_path } },
        ),
    );
    try std.testing.expect(fileExists(fs, transaction_dir));
    try std.testing.expect(fileExists(fs, expired_terminal_lease.path));
    try releaseLease(fs, allocator, &expired_terminal_lease, expired_terminal_lease.fencing_token);
    const counter_before_terminal = try readFencingCounter(fs, allocator, counter_path);
    const summary = try recoverAndCompactTransactionsWithOptions(
        fs,
        allocator,
        transactions_dir,
        .{
            .legacy_fencing_authority = .{
                .shared = counter_path,
            },
        },
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expect(!fileExists(fs, transaction_dir));
    try std.testing.expect(
        try readFencingCounter(fs, allocator, counter_path) >
            counter_before_terminal,
    );
}

fn assertLegacyRecoveryLeaseLifetime(
    expected: []const TransactionExpected,
    owner: Owner,
    counter_path: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var recovery_storage_mutated = false;
    var recovery_leases = try acquireLegacyTransactionRecoveryLeases(
        fs,
        allocator,
        expected,
        owner,
        "dtx-20",
        counter_path,
        &recovery_storage_mutated,
    );
    const expires_ms = try parseU64Text(recovery_leases[0].expires_at);
    try std.testing.expect(expires_ms - clockMillis(fs, .real) > 365 * 24 * 60 * 60 * 1000);
    try releaseLegacyTransactionRecoveryLeases(
        fs,
        allocator,
        &recovery_leases,
        &recovery_storage_mutated,
    );

    var failed_release_leases = try acquireLegacyTransactionRecoveryLeases(
        fs,
        allocator,
        expected,
        owner,
        "dtx-20",
        counter_path,
        &recovery_storage_mutated,
    );
    try std.Io.Dir.deleteFileAbsolute(fs.io, failed_release_leases[0].path);
    try std.testing.expectError(
        error.FileNotFound,
        releaseLegacyTransactionRecoveryLeases(
            fs,
            allocator,
            &failed_release_leases,
            &recovery_storage_mutated,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), failed_release_leases.len);
}

fn assertLegacyRecoveryWaitsForWriter(
    transactions_dir: []const u8,
    target_path: []const u8,
    owner: Owner,
    counter_path: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var writer_lease = try acquireLeaseLock(
        fs,
        allocator,
        target_path,
        .{
            .owner = owner,
            .lease_ms = 60_000,
            .fencing_counter_path = counter_path,
        },
    );
    var busy_summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.LockBusy,
        recoverAndCompactTransactionsAccumulating(
            fs,
            allocator,
            transactions_dir,
            .{ .legacy_fencing_authority = .{ .shared = counter_path } },
            &busy_summary,
        ),
    );
    try std.testing.expect(busy_summary.storage_mutated);
    try releaseLease(fs, allocator, &writer_lease, writer_lease.fencing_token);
}

const ExpiredLeaseRepairFixture = struct {
    transaction_dir: []u8,
    counter_path: []u8,
    expired: LeaseLock,

    fn init(
        allocator: std.mem.Allocator,
        root: []const u8,
    ) !ExpiredLeaseRepairFixture {
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        const transaction_id = "dtx-62";
        const transaction_dir = try std.fs.path.join(
            allocator,
            &.{ root, "transactions", transaction_id },
        );
        errdefer allocator.free(transaction_dir);
        try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
        const record_path = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "transaction.json" },
        );
        defer allocator.free(record_path);
        const target_path = try std.fs.path.join(allocator, &.{ root, "repair.jsonl" });
        defer allocator.free(target_path);
        try writeTextAtomic(fs, allocator, target_path, "{\"sequence\":1}\n");
        const counter_path = try std.fs.path.join(allocator, &.{ root, "fencing.counter" });
        errdefer allocator.free(counter_path);
        const owner: Owner = .{
            .process_id = 962,
            .session_id = "witnessed-lease-repair",
            .executor = "test",
        };
        var expired = try acquireLeaseLock(fs, allocator, target_path, .{
            .owner = owner,
            .lease_ms = 1,
            .fencing_counter_path = counter_path,
            .transaction_id = transaction_id,
        });
        errdefer expired.deinit(allocator);
        const expected = [_]TransactionExpected{.{
            .path = target_path,
            .digest = "",
            .sequence = 0,
        }};
        try writeTransactionRecord(
            fs,
            allocator,
            record_path,
            transaction_id,
            owner,
            .prepared,
            &expected,
            &.{},
            &.{expired},
            1,
            2,
            true,
        );
        try std.Io.sleep(fs.io, .fromMilliseconds(3), .awake);
        return .{
            .transaction_dir = transaction_dir,
            .counter_path = counter_path,
            .expired = expired,
        };
    }

    fn deinit(
        self: *ExpiredLeaseRepairFixture,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.transaction_dir);
        allocator.free(self.counter_path);
        self.expired.deinit(allocator);
        self.* = undefined;
    }
};

test "refreshed embedded lease retains legacy ownership" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    var fixture = try ExpiredLeaseRepairFixture.init(allocator, root);
    defer fixture.deinit(allocator);
    try refreshLease(fs, allocator, &fixture.expired, fixture.expired.fencing_token, 60_000);

    const candidates = try inspectLegacyLeaseRecoveryCandidates(
        fs,
        allocator,
        fixture.transaction_dir,
        .{ .shared = fixture.counter_path },
    );
    defer deinitLegacyLeaseRecoveryCandidates(allocator, candidates);
    try std.testing.expectEqual(@as(usize, 0), candidates.len);

    var summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.LegacyWriterConfirmationRequired,
        reclaimLegacyLease(
            fs,
            allocator,
            fixture.transaction_dir,
            .{ .shared = fixture.counter_path },
            .{
                .transaction_id = "dtx-62",
                .resource = fixture.expired.resource,
                .lock_id = fixture.expired.lock_id,
                .fencing_token = fixture.expired.fencing_token,
            },
            &summary,
        ),
    );
    try std.testing.expect(fileExists(fs, fixture.expired.path));
}

test "legacy lease repair requires and revalidates an exact journal witness" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    var fixture = try ExpiredLeaseRepairFixture.init(allocator, root);
    defer fixture.deinit(allocator);
    const candidates = try inspectLegacyLeaseRecoveryCandidates(
        fs,
        allocator,
        fixture.transaction_dir,
        .{ .shared = fixture.counter_path },
    );
    defer deinitLegacyLeaseRecoveryCandidates(allocator, candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings(fixture.expired.lock_id, candidates[0].lock_id);
    try std.testing.expectEqual(fixture.expired.fencing_token, candidates[0].fencing_token);
    try std.testing.expectEqual(
        LegacyLeaseRecoveryCandidate.Kind.expired_legacy,
        candidates[0].kind,
    );

    try assertLegacyLeaseRepairRejectsUnprovedWitness(&fixture);
    var summary: TransactionRecoverySummary = .{};
    const receipt = try reclaimLegacyLease(
        fs,
        allocator,
        fixture.transaction_dir,
        .{ .shared = fixture.counter_path },
        .{
            .transaction_id = "dtx-62",
            .resource = fixture.expired.resource,
            .lock_id = fixture.expired.lock_id,
            .fencing_token = fixture.expired.fencing_token,
            .confirm_no_legacy_writers = true,
        },
        &summary,
    );
    defer {
        allocator.free(receipt.lock_id);
        allocator.free(receipt.resource);
        allocator.free(receipt.result);
    }
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expectEqual(fixture.expired.fencing_token, receipt.previous_fencing_token);
    try std.testing.expect(!fileExists(fs, fixture.expired.path));
}

fn assertLegacyLeaseRepairRejectsUnprovedWitness(
    fixture: *const ExpiredLeaseRepairFixture,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    const counter_before_mismatch = try readFencingCounter(fs, allocator, fixture.counter_path);
    var mismatch_summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        reclaimLegacyLease(
            fs,
            allocator,
            fixture.transaction_dir,
            .{ .shared = fixture.counter_path },
            .{
                .transaction_id = "dtx-62",
                .resource = fixture.expired.resource,
                .lock_id = fixture.expired.lock_id,
                .fencing_token = fixture.expired.fencing_token + 1,
                .confirm_no_legacy_writers = true,
            },
            &mismatch_summary,
        ),
    );
    try std.testing.expect(fileExists(fs, fixture.expired.path));
    try std.testing.expectEqual(
        counter_before_mismatch,
        try readFencingCounter(fs, allocator, fixture.counter_path),
    );

    var unconfirmed_summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.LegacyWriterConfirmationRequired,
        reclaimLegacyLease(
            fs,
            allocator,
            fixture.transaction_dir,
            .{ .shared = fixture.counter_path },
            .{
                .transaction_id = "dtx-62",
                .resource = fixture.expired.resource,
                .lock_id = fixture.expired.lock_id,
                .fencing_token = fixture.expired.fencing_token,
            },
            &unconfirmed_summary,
        ),
    );
    try std.testing.expect(fileExists(fs, fixture.expired.path));
}

test "legacy reclaim preserves existing recovery evidence without replacement" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    var fixture = try ExpiredLeaseRepairFixture.init(allocator, root);
    defer fixture.deinit(allocator);
    const evidence_path = try allocator.print(
        "{s}.reclaimed-{d}",
        .{ fixture.expired.path, fixture.expired.fencing_token },
    );
    defer allocator.free(evidence_path);
    try writeTextCreateNew(fs, allocator, evidence_path, "preexisting evidence\n", .{});

    var summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.PathAlreadyExists,
        reclaimLegacyLease(
            fs,
            allocator,
            fixture.transaction_dir,
            .{ .shared = fixture.counter_path },
            .{
                .transaction_id = "dtx-62",
                .resource = fixture.expired.resource,
                .lock_id = fixture.expired.lock_id,
                .fencing_token = fixture.expired.fencing_token,
                .confirm_no_legacy_writers = true,
            },
            &summary,
        ),
    );
    const preserved = try readFileAlloc(fs, allocator, evidence_path, 4096);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("preexisting evidence\n", preserved);
    try std.testing.expect(fileExists(fs, fixture.expired.path));
}

test "interrupted recovery leases are transaction-bound and repairable" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    var fixture = try ExpiredLeaseRepairFixture.init(allocator, root);
    defer fixture.deinit(allocator);
    const resource = try allocator.dupe(u8, fixture.expired.resource);
    defer allocator.free(resource);
    try releaseLease(fs, allocator, &fixture.expired, fixture.expired.fencing_token);
    const owner: Owner = .{
        .process_id = 962,
        .session_id = "witnessed-lease-repair",
        .executor = "test",
    };
    var interrupted = try acquireLeaseLock(
        fs,
        allocator,
        resource,
        .{
            .owner = owner,
            .lease_ms = std.math.maxInt(u64) / 2,
            .fencing_counter_path = fixture.counter_path,
            .transaction_id = "dtx-62",
        },
    );
    const lock_id = try allocator.dupe(u8, interrupted.lock_id);
    defer allocator.free(lock_id);
    const fencing_token = interrupted.fencing_token;
    interrupted.deinit(allocator);

    const candidates = try inspectLegacyLeaseRecoveryCandidates(
        fs,
        allocator,
        fixture.transaction_dir,
        .{ .shared = fixture.counter_path },
    );
    defer deinitLegacyLeaseRecoveryCandidates(allocator, candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqual(
        LegacyLeaseRecoveryCandidate.Kind.interrupted_recovery,
        candidates[0].kind,
    );

    try assertInterruptedLeaseRequiresBoundRepair(
        &fixture,
        resource,
        owner,
        lock_id,
        fencing_token,
    );
}

fn assertInterruptedLeaseRequiresBoundRepair(
    fixture: *const ExpiredLeaseRepairFixture,
    resource: []const u8,
    owner: Owner,
    lock_id: []const u8,
    fencing_token: u64,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        reclaimExpiredLease(
            fs,
            allocator,
            resource,
            .{
                .owner = owner,
                .fencing_counter_path = fixture.counter_path,
            },
        ),
    );

    var summary: TransactionRecoverySummary = .{};
    const receipt = try reclaimLegacyLease(
        fs,
        allocator,
        fixture.transaction_dir,
        .{ .shared = fixture.counter_path },
        .{
            .transaction_id = "dtx-62",
            .resource = resource,
            .lock_id = lock_id,
            .fencing_token = fencing_token,
        },
        &summary,
    );
    defer {
        allocator.free(receipt.lock_id);
        allocator.free(receipt.resource);
        allocator.free(receipt.result);
    }
    try std.testing.expect(summary.storage_mutated);
    const lock_path = try lockPathAlloc(allocator, resource);
    defer allocator.free(lock_path);
    try std.testing.expect(!fileExists(fs, lock_path));
}

test "legacy reclaim rejects symlinked resource parents" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    if (@import("builtin").os.tag == .windows) {
        return error.SkipZigTest;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.createDir(fs.io, "outside", .default_dir);
    try tmp.dir.symLink(fs.io, "outside", "linked", .{ .is_directory = true });
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-69" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const resource = try std.fs.path.join(allocator, &.{ root, "linked", "repair.jsonl" });
    defer allocator.free(resource);
    const lock_path = try lockPathAlloc(allocator, resource);
    defer allocator.free(lock_path);
    const counter_path = try std.fs.path.join(allocator, &.{ root, "fencing.counter" });
    defer allocator.free(counter_path);
    const owner: Owner = .{
        .process_id = 969,
        .session_id = "symlinked-reclaim-resource",
        .executor = "test",
    };
    var lock = try makeLeaseLockOwned(allocator, lock_path, resource, owner, 1, 2, 1, null);
    defer lock.deinit(allocator);
    const payload = try renderLeaseLockAlloc(allocator, lock);
    defer allocator.free(payload);
    try tmp.dir.writeFile(fs.io, .{
        .sub_path = "outside/repair.jsonl.lock",
        .data = payload,
    });
    var expected = [_]TransactionExpected{.{
        .path = resource,
        .digest = "",
        .sequence = 0,
    }};
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        "dtx-69",
        owner,
        .prepared,
        &expected,
        &.{},
        &.{lock},
        1,
        2,
        true,
    );
    try writeTextAtomic(fs, allocator, counter_path, "1\n");

    try assertSymlinkedLeaseResourceRejected(
        transaction_dir,
        counter_path,
        resource,
        lock,
        lock_path,
    );
}

fn assertSymlinkedLeaseResourceRejected(
    transaction_dir: []const u8,
    counter_path: []const u8,
    resource: []const u8,
    lock: LeaseLock,
    lock_path: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.SymLinkLoop,
        reclaimLegacyLease(
            fs,
            allocator,
            transaction_dir,
            .{ .shared = counter_path },
            .{
                .transaction_id = "dtx-69",
                .resource = resource,
                .lock_id = lock.lock_id,
                .fencing_token = lock.fencing_token,
                .confirm_no_legacy_writers = true,
            },
            &summary,
        ),
    );
    try std.testing.expect(fileExists(fs, lock_path));
}

test "recovery accumulation preserves a successful prefix across later errors" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const recoverable_dir = try std.fs.path.join(
        allocator,
        &.{
            transactions_dir,
            "dtx-1-00000000000000000000000000000014",
        },
    );
    defer allocator.free(recoverable_dir);
    try ensureDirectoryPathNoSymlinks(fs, recoverable_dir);
    const record_path = try std.fs.path.join(allocator, &.{ recoverable_dir, "transaction.json" });
    defer allocator.free(record_path);
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        "dtx-1-00000000000000000000000000000014",
        .{
            .process_id = 921,
            .session_id = "recovery-prefix",
            .executor = "test",
        },
        .preparing,
        &.{},
        &.{},
        &.{},
        1,
        2,
        true,
    );
    var summary: TransactionRecoverySummary = .{};
    try recoverAndCompactTransactionsAccumulating(fs, allocator, transactions_dir, .{}, &summary);
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expectEqual(@as(usize, 1), summary.transaction_count);

    const corrupt_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-invalid" });
    defer allocator.free(corrupt_dir);
    try ensureDirectoryPathNoSymlinks(fs, corrupt_dir);
    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverAndCompactTransactionsAccumulating(fs, allocator, transactions_dir, .{}, &summary),
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expectEqual(@as(usize, 1), summary.transaction_count);
}

test "recovery reports target publication before a later stage cleanup error" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-1-00000000000000000000000000000015";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const before = "{\"seq\":1}\n";
    const after = "{\"seq\":2}\n";
    try writeTextAtomic(fs, allocator, target_path, before);
    try writePreparedRecordForTest(
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 922,
            .session_id = "partial-roll-forward",
            .executor = "test",
        },
        target_path,
        before,
        after,
    );

    var stage_dir = try std.Io.Dir.openDirAbsolute(fs.io, transaction_dir, .{ .iterate = true });
    defer stage_dir.close(fs.io);
    const writable = std.Io.File.Permissions.fromMode(0o755);
    const read_only = std.Io.File.Permissions.fromMode(0o555);
    try stage_dir.setPermissions(fs.io, read_only);
    defer stage_dir.setPermissions(fs.io, writable) catch |err| {
        std.debug.panic("restore transaction directory permissions: {s}", .{
            @errorName(err),
        });
    };

    var summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.AccessDenied,
        recoverTransactionWithOptionsAccumulating(fs, allocator, transaction_dir, .{}, &summary),
    );
    try std.testing.expect(summary.storage_mutated);
    const published = try tryReadForTest(target_path);
    defer allocator.free(published);
    try std.testing.expectEqualStrings(after, published);
}

test "recovery preserves nonempty compatibility-shaped files" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-1-00000000000000000000000000000016";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const before = "{\"seq\":1}\n";
    const after = "{\"seq\":2}\n";
    try writeTextAtomic(fs, allocator, target_path, before);
    try writePreparedRecordForTest(
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 923,
            .session_id = "stale-compatibility-lock",
            .executor = "test",
        },
        target_path,
        before,
        after,
    );
    try writeTextAtomic(fs, allocator, target_path, "{\"seq\":3}\n");
    const cas_path = try casLockPathAlloc(allocator, target_path);
    defer allocator.free(cas_path);
    try writeTextCreateNew(fs, allocator, cas_path, "stale\n", .{});

    var summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsAccumulating(fs, allocator, transactions_dir, .{}, &summary),
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expect(fileExists(fs, cas_path));
    try std.testing.expect(fileExists(fs, transaction_dir));
}

test "recovery does not remove a live lease at a compatibility path" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const lease_resource = try allocator.print("{s}.cas", .{target_path});
    defer allocator.free(lease_resource);
    const counter_path = try std.fs.path.join(allocator, &.{ root, "fencing.counter" });
    defer allocator.free(counter_path);
    var lease = try acquireLeaseLock(
        fs,
        allocator,
        lease_resource,
        .{
            .owner = .{
                .process_id = 937,
                .session_id = "live-compatibility-lease",
                .executor = "test",
            },
            .lease_ms = 60_000,
            .fencing_counter_path = counter_path,
        },
    );
    defer releaseLease(
        fs,
        allocator,
        &lease,
        lease.fencing_token,
    ) catch |release_error| {
        std.debug.panic("failed to release live lease: {s}", .{
            @errorName(release_error),
        });
    };
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = "",
        .sequence = 0,
    }};
    var storage_mutated = false;
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        acquireTransactionRecoveryLocks(fs, allocator, &expected, &storage_mutated),
    );
    try std.testing.expect(fileExists(fs, lease.path));
}

test "recovery replaces empty stale compatibility locks" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const cas_path = try casLockPathAlloc(allocator, target_path);
    defer allocator.free(cas_path);
    try writeTextCreateNew(fs, allocator, cas_path, "", .{});
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = "",
        .sequence = 0,
    }};
    var storage_mutated = false;
    var locks = try acquireTransactionRecoveryLocks(fs, allocator, &expected, &storage_mutated);
    defer locks.deinit(allocator);
    try std.testing.expect(storage_mutated);
}

test "compatibility lock release batches parent durability" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const first_path = try std.fs.path.join(allocator, &.{ root, "first.lock" });
    defer allocator.free(first_path);
    const second_path = try std.fs.path.join(allocator, &.{ root, "second.lock" });
    defer allocator.free(second_path);
    var locks = [_]LockFile{
        try acquireExclusiveLockPath(fs, allocator, first_path),
        try acquireExclusiveLockPath(fs, allocator, second_path),
    };
    var storage_mutated = false;
    try releaseCompatibilityLocksDurable(fs, allocator, &locks, &storage_mutated);
    try std.testing.expect(storage_mutated);
    try std.testing.expect(!fileExists(fs, first_path));
    try std.testing.expect(!fileExists(fs, second_path));
}

test "direct recovery reports target advisory creation as mutation" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-1-00000000000000000000000000000042";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const marker_path = try transactionCommitMarkerPathAlloc(allocator, transaction_dir);
    defer allocator.free(marker_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const content = "{\"seq\":1}\n";
    try writeTextAtomic(fs, allocator, target_path, content);
    const digest = try digestBytesAlloc(allocator, content);
    defer allocator.free(digest);
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = digest,
        .sequence = 1,
    }};
    var stage_buffer: [96]u8 = undefined;
    const staged_ref = try transactionStageName(&stage_buffer, transaction_id, 0);
    const writes = [_]TransactionWrite{.{
        .path = target_path,
        .staged_ref = staged_ref,
        .digest_after = digest,
        .sequence_after = 1,
    }};
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 942,
            .session_id = "target-advisory-mutation",
            .executor = "test",
        },
        .committed,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
    try writeCommittedTransactionMarker(fs, allocator, marker_path);
    const recovery_advisory = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, ".recovery.advisory" },
    );
    defer allocator.free(recovery_advisory);
    try writeTextCreateNew(fs, allocator, recovery_advisory, "", .{});
    const target_advisory = try casAdvisoryPathAlloc(allocator, target_path);
    defer allocator.free(target_advisory);
    try std.testing.expect(!fileExists(fs, target_advisory));

    try assertRecoveryCreatesOnlyTargetAdvisory(transaction_dir, target_advisory, target_path);
}

fn assertRecoveryCreatesOnlyTargetAdvisory(
    transaction_dir: []const u8,
    target_advisory: []const u8,
    target_path: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var receipt = try recoverTransaction(fs, allocator, transaction_dir);
    defer receipt.deinit(allocator);
    try std.testing.expectEqual(RecoveryDecision.already_committed, receipt.decision);
    try std.testing.expect(receipt.storage_mutated);
    try std.testing.expect(fileExists(fs, target_advisory));
    const compatibility_path = try casLockPathAlloc(allocator, target_path);
    defer allocator.free(compatibility_path);
    try std.testing.expect(!fileExists(fs, compatibility_path));
}

test "prepared legacy journals preserve rollback-on-zero-published law" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-2";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const before = "{\"seq\":1}\n";
    const after = "{\"seq\":2}\n";
    try writeTextAtomic(fs, allocator, target_path, before);
    try writePreparedRecordForTest(
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 908,
            .session_id = "legacy-pre-marker",
            .executor = "test",
        },
        target_path,
        before,
        after,
    );
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactions(fs, allocator, transactions_dir),
    );

    try assertLegacyWriterBlocksRollback(target_path, transactions_dir, transaction_dir, before);
    const summary = try recoverAndCompactTransactionsWithOptions(
        fs,
        allocator,
        transactions_dir,
        .{
            .legacy_fencing_authority = .per_resource,
        },
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expect(!fileExists(fs, transaction_dir));
    const recovered = try tryReadForTest(target_path);
    defer allocator.free(recovered);
    try std.testing.expectEqualStrings(before, recovered);
}

fn assertLegacyWriterBlocksRollback(
    target_path: []const u8,
    transactions_dir: []const u8,
    transaction_dir: []const u8,
    before: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    {
        var legacy_lease = try acquireLeaseLock(
            fs,
            allocator,
            target_path,
            .{
                .owner = .{
                    .process_id = 908,
                    .session_id = "legacy-pre-marker",
                    .executor = "test",
                },
                .lease_ms = 60_000,
            },
        );
        defer releaseLease(
            fs,
            allocator,
            &legacy_lease,
            legacy_lease.fencing_token,
        ) catch |release_error| {
            std.debug.panic("failed to release legacy lease: {s}", .{@errorName(release_error)});
        };
        try std.testing.expectError(
            error.LockBusy,
            recoverAndCompactTransactionsWithOptions(
                fs,
                allocator,
                transactions_dir,
                .{
                    .legacy_fencing_authority = .per_resource,
                },
            ),
        );
        try std.testing.expect(fileExists(fs, transaction_dir));
        const unchanged = try tryReadForTest(target_path);
        defer allocator.free(unchanged);
        try std.testing.expectEqualStrings(before, unchanged);
    }
}

test "hashed transaction ids retain legacy stage and decision compatibility" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-2-00000000000000000000000000000002";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const before = "{\"seq\":1}\n";
    const after = "{\"seq\":2}\n";
    try writeTextAtomic(fs, allocator, target_path, before);
    try writePreparedLegacyStageRecordForTest(
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 911,
            .session_id = "hashed-legacy-stage",
            .executor = "test",
        },
        target_path,
        before,
        after,
    );

    const summary = try recoverAndCompactTransactionsWithOptions(
        fs,
        allocator,
        transactions_dir,
        .{
            .legacy_fencing_authority = .per_resource,
        },
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expect(!fileExists(fs, transaction_dir));
    const recovered = try tryReadForTest(target_path);
    defer allocator.free(recovered);
    try std.testing.expectEqualStrings(before, recovered);
}

test "legacy prepared journals quarantine mixed published prefixes" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-41" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const first_path = try std.fs.path.join(allocator, &.{ root, "first.jsonl" });
    defer allocator.free(first_path);
    const second_path = try std.fs.path.join(allocator, &.{ root, "second.jsonl" });
    defer allocator.free(second_path);
    try writeTextAtomic(fs, allocator, first_path, "{\"seq\":2}\n");
    try writeTextAtomic(fs, allocator, second_path, "{\"seq\":1}\n");
    try writePreparedTwoWriteRecordForTest(
        allocator,
        record_path,
        "dtx-41",
        .{
            .process_id = 941,
            .session_id = "legacy-mixed-prefix",
            .executor = "test",
        },
        first_path,
        second_path,
    );

    var status = try inspectTransaction(fs, allocator, transaction_dir);
    defer status.deinit(allocator);
    try std.testing.expectEqual(RecoveryDecision.manual_recovery_required, status.decision);
    try std.testing.expectEqualStrings("legacy-mixed-published-digests", status.reason);
}

test "legacy rollback does not reacquire expected-only guards" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-5" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const source_path = try std.fs.path.join(allocator, &.{ root, "a-source.json" });
    defer allocator.free(source_path);
    const binding_path = try std.fs.path.join(allocator, &.{ root, "z-binding.json" });
    defer allocator.free(binding_path);
    const source_before = "{\"source\":1}\n";
    const source_after = "{\"source\":2}\n";
    const binding_before = "{\"binding\":1}\n";
    const binding_after = "{\"binding\":2}\n";
    try writeTextAtomic(fs, allocator, source_path, source_before);
    try writeTextAtomic(fs, allocator, binding_path, binding_before);
    const source_digest = try digestBytesAlloc(allocator, source_before);
    defer allocator.free(source_digest);
    const binding_before_digest = try digestBytesAlloc(allocator, binding_before);
    defer allocator.free(binding_before_digest);
    const binding_after_digest = try digestBytesAlloc(allocator, binding_after);
    defer allocator.free(binding_after_digest);
    const expected = [_]TransactionExpected{
        .{ .path = source_path, .digest = source_digest, .sequence = 0 },
        .{
            .path = binding_path,
            .digest = binding_before_digest,
            .sequence = 0,
        },
    };
    const writes = [_]TransactionWrite{.{
        .path = binding_path,
        .staged_ref = "write-1.staged",
        .digest_after = binding_after_digest,
        .sequence_after = 0,
    }};
    try writePreparedCheckOnlyRecord(
        transaction_dir,
        record_path,
        binding_after,
        &expected,
        &writes,
    );
    try writeTextAtomic(fs, allocator, source_path, source_after);

    try assertLegacyRollbackPreservesBinding(
        transactions_dir,
        transaction_dir,
        binding_path,
        binding_before,
    );
}

fn writePreparedCheckOnlyRecord(
    transaction_dir: []const u8,
    record_path: []const u8,
    binding_after: []const u8,
    expected: []const TransactionExpected,
    writes: []const TransactionWrite,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    const staged_path = try std.fs.path.join(allocator, &.{ transaction_dir, "write-1.staged" });
    defer allocator.free(staged_path);
    try writeTextCreateNew(fs, allocator, staged_path, binding_after, .{});
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        "dtx-5",
        .{
            .process_id = 912,
            .session_id = "expected-only-preflight",
            .executor = "test",
        },
        .prepared,
        expected,
        writes,
        &.{},
        1,
        2,
        true,
    );
}

fn assertLegacyRollbackPreservesBinding(
    transactions_dir: []const u8,
    transaction_dir: []const u8,
    binding_path: []const u8,
    binding_before: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    const summary = try recoverAndCompactTransactionsWithOptions(
        fs,
        allocator,
        transactions_dir,
        .{
            .legacy_fencing_authority = .per_resource,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), summary.transaction_count);
    try std.testing.expect(!fileExists(fs, transaction_dir));
    const unchanged = try tryReadForTest(binding_path);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(binding_before, unchanged);
}

test "committed recovery does not revalidate released expected-only guards" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-6-00000000000000000000000000000001";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const source_path = try std.fs.path.join(allocator, &.{ root, "source.json" });
    defer allocator.free(source_path);
    const binding_path = try std.fs.path.join(allocator, &.{ root, "binding.json" });
    defer allocator.free(binding_path);
    const source_before = "{\"source\":1}\n";
    const source_after = "{\"source\":2}\n";
    const binding_before = "{\"binding\":1}\n";
    const binding_after = "{\"binding\":2}\n";
    try writeTextAtomic(fs, allocator, source_path, source_before);
    try writeTextAtomic(fs, allocator, binding_path, binding_before);
    const source_digest = try digestBytesAlloc(allocator, source_before);
    defer allocator.free(source_digest);
    const binding_before_digest = try digestBytesAlloc(allocator, binding_before);
    defer allocator.free(binding_before_digest);
    const binding_after_digest = try digestBytesAlloc(allocator, binding_after);
    defer allocator.free(binding_after_digest);
    const expected = [_]TransactionExpected{
        .{ .path = binding_path, .digest = binding_before_digest, .sequence = 0 },
        .{ .path = source_path, .digest = source_digest, .sequence = 0 },
    };
    try writeCommittedReleasedGuardJournal(
        record_path,
        transaction_id,
        binding_path,
        binding_after_digest,
        &expected,
    );
    var incomplete = try inspectTransaction(fs, allocator, transaction_dir);
    defer incomplete.deinit(allocator);
    try std.testing.expectEqual(RecoveryDecision.manual_recovery_required, incomplete.decision);
    try writeTextAtomic(fs, allocator, binding_path, binding_after);
    try writeTextAtomic(fs, allocator, source_path, source_after);

    try recoverAndCompactTransactions(fs, allocator, transactions_dir);
    try std.testing.expect(!fileExists(fs, transaction_dir));
    const binding = try tryReadForTest(binding_path);
    defer allocator.free(binding);
    try std.testing.expectEqualStrings(binding_after, binding);

    try assertPreparedRecoveryIgnoresReleasedGuards(
        transactions_dir,
        binding_path,
        binding_after_digest,
        &expected,
    );
}

fn writeCommittedReleasedGuardJournal(
    record_path: []const u8,
    transaction_id: []const u8,
    binding_path: []const u8,
    binding_after_digest: []const u8,
    expected: []const TransactionExpected,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    const staged_ref = try transactionStageNameAlloc(allocator, transaction_id, 0);
    defer allocator.free(staged_ref);
    const writes = [_]TransactionWrite{.{
        .path = binding_path,
        .staged_ref = staged_ref,
        .digest_after = binding_after_digest,
        .sequence_after = 0,
    }};
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 916,
            .session_id = "committed-guard-release",
            .executor = "test",
        },
        .committed,
        expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
}

fn assertPreparedRecoveryIgnoresReleasedGuards(
    transactions_dir: []const u8,
    binding_path: []const u8,
    binding_after_digest: []const u8,
    expected: []const TransactionExpected,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    const prepared_id = "dtx-6-00000000000000000000000000000002";
    const prepared_dir = try std.fs.path.join(allocator, &.{ transactions_dir, prepared_id });
    defer allocator.free(prepared_dir);
    try ensureDirectoryPathNoSymlinks(fs, prepared_dir);
    const prepared_record = try std.fs.path.join(allocator, &.{ prepared_dir, "transaction.json" });
    defer allocator.free(prepared_record);
    const prepared_staged_ref = try transactionStageNameAlloc(allocator, prepared_id, 0);
    defer allocator.free(prepared_staged_ref);
    const prepared_writes = [_]TransactionWrite{.{
        .path = binding_path,
        .staged_ref = prepared_staged_ref,
        .digest_after = binding_after_digest,
        .sequence_after = 0,
    }};
    try writeTransactionRecord(
        fs,
        allocator,
        prepared_record,
        prepared_id,
        .{
            .process_id = 917,
            .session_id = "prepared-guard-release",
            .executor = "test",
        },
        .prepared,
        expected,
        &prepared_writes,
        &.{},
        1,
        2,
        true,
    );
    var prepared = try inspectTransaction(fs, allocator, prepared_dir);
    defer prepared.deinit(allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, prepared.decision);

    try recoverAndCompactTransactions(fs, allocator, transactions_dir);
    try std.testing.expect(!fileExists(fs, prepared_dir));
}

test "legacy recovery cannot target its shared fencing authority" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-7" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const counter_path = try std.fs.path.join(allocator, &.{ root, "fencing.counter" });
    defer allocator.free(counter_path);
    const counter_before = "10\n";
    const counter_after = "0\n";
    try writeTextAtomic(fs, allocator, counter_path, counter_before);
    const before_digest = try digestBytesAlloc(allocator, counter_before);
    defer allocator.free(before_digest);
    const after_digest = try digestBytesAlloc(allocator, counter_after);
    defer allocator.free(after_digest);
    const expected = [_]TransactionExpected{.{
        .path = counter_path,
        .digest = before_digest,
        .sequence = 0,
    }};
    const writes = [_]TransactionWrite{.{
        .path = counter_path,
        .staged_ref = "write-0.staged",
        .digest_after = after_digest,
        .sequence_after = 0,
    }};
    const staged_path = try std.fs.path.join(allocator, &.{ transaction_dir, "write-0.staged" });
    defer allocator.free(staged_path);
    try writeTextCreateNew(fs, allocator, staged_path, counter_after, .{});
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        "dtx-7",
        .{
            .process_id = 917,
            .session_id = "fencing-authority-target",
            .executor = "test",
        },
        .prepared,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );

    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{ .legacy_fencing_authority = .{ .shared = counter_path } },
        ),
    );
    const counter = try tryReadForTest(counter_path);
    defer allocator.free(counter);
    try std.testing.expectEqualStrings(counter_before, counter);
}

test "legacy recovery rejects duplicate write targets before publishing" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-6" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const before = "{\"seq\":1}\n";
    try writeDuplicateTargetJournal(target_path, before, transaction_dir, record_path);
    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .per_resource,
            },
        ),
    );
    const unchanged = try tryReadForTest(target_path);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(before, unchanged);
}

fn writeDuplicateTargetJournal(
    target_path: []const u8,
    before: []const u8,
    transaction_dir: []const u8,
    record_path: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    const after_a = "{\"seq\":2}\n";
    const after_b = "{\"seq\":3}\n";
    try writeTextAtomic(fs, allocator, target_path, before);
    const before_digest = try digestBytesAlloc(allocator, before);
    defer allocator.free(before_digest);
    const after_a_digest = try digestBytesAlloc(allocator, after_a);
    defer allocator.free(after_a_digest);
    const after_b_digest = try digestBytesAlloc(allocator, after_b);
    defer allocator.free(after_b_digest);
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = before_digest,
        .sequence = 1,
    }};
    const writes = [_]TransactionWrite{
        .{
            .path = target_path,
            .staged_ref = "write-0.staged",
            .digest_after = after_a_digest,
            .sequence_after = 2,
        },
        .{
            .path = target_path,
            .staged_ref = "write-1.staged",
            .digest_after = after_b_digest,
            .sequence_after = 3,
        },
    };
    const staged_a = try std.fs.path.join(allocator, &.{ transaction_dir, "write-0.staged" });
    defer allocator.free(staged_a);
    const staged_b = try std.fs.path.join(allocator, &.{ transaction_dir, "write-1.staged" });
    defer allocator.free(staged_b);
    try writeTextCreateNew(fs, allocator, staged_a, after_a, .{});
    try writeTextCreateNew(fs, allocator, staged_b, after_b, .{});
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        "dtx-6",
        .{
            .process_id = 913,
            .session_id = "duplicate-recovery-target",
            .executor = "test",
        },
        .prepared,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
}

test "legacy recovery rejects the transaction-control namespace" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-7" });
    defer allocator.free(transaction_dir);
    const sibling_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-8" });
    defer allocator.free(sibling_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, sibling_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const sibling_record = try std.fs.path.join(allocator, &.{ sibling_dir, "transaction.json" });
    defer allocator.free(sibling_record);
    const before = "sibling-journal\n";
    const after = "corrupted-journal\n";
    try writeTextAtomic(fs, allocator, sibling_record, before);
    try writePreparedLegacyStageRecordForTest(
        allocator,
        record_path,
        "dtx-7",
        .{
            .process_id = 914,
            .session_id = "transaction-namespace-target",
            .executor = "test",
        },
        sibling_record,
        before,
        after,
    );

    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .per_resource,
            },
        ),
    );
    const unchanged = try tryReadForTest(sibling_record);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(before, unchanged);
}

test "legacy rollback refuses a missing nonempty before-state" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-4" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const target_a = try std.fs.path.join(allocator, &.{ root, "a.jsonl" });
    defer allocator.free(target_a);
    const target_b = try std.fs.path.join(allocator, &.{ root, "b.jsonl" });
    defer allocator.free(target_b);
    const before = "{\"seq\":1}\n";
    try writeTextAtomic(fs, allocator, target_a, before);
    try writeTextAtomic(fs, allocator, target_b, before);
    try writePreparedTwoWriteRecordForTest(
        allocator,
        record_path,
        "dtx-4",
        .{
            .process_id = 910,
            .session_id = "legacy-preflight",
            .executor = "test",
        },
        target_a,
        target_b,
    );
    try std.Io.Dir.deleteFileAbsolute(fs.io, target_b);

    var status = try inspectTransaction(fs, allocator, transaction_dir);
    defer status.deinit(allocator);
    try std.testing.expectEqual(RecoveryDecision.manual_recovery_required, status.decision);
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .per_resource,
            },
        ),
    );
    try std.testing.expect(fileExists(fs, transaction_dir));
    const unchanged = try tryReadForTest(target_a);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(before, unchanged);
}

test "legacy journals reject filesystem aliases into their directory" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-3";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const transaction_alias = try std.fs.path.join(allocator, &.{ root, "transaction-alias" });
    defer allocator.free(transaction_alias);
    try fs.directory().symLink(
        fs.io,
        transaction_dir,
        transaction_alias,
        .{ .is_directory = true },
    );
    const target_path = try std.fs.path.join(allocator, &.{ transaction_alias, "victim.jsonl" });
    defer allocator.free(target_path);
    const actual_target_path =
        try std.fs.path.join(allocator, &.{ transaction_dir, "victim.jsonl" });
    defer allocator.free(actual_target_path);
    const staged_path = try std.fs.path.join(allocator, &.{ transaction_dir, "write-0.staged" });
    defer allocator.free(staged_path);
    const before = "{\"seq\":1}\n";
    const after = "{\"seq\":2}\n";
    try writeTextAtomic(fs, allocator, actual_target_path, before);
    try writeTextAtomic(fs, allocator, staged_path, after);
    const digest_before = try digestBytesAlloc(allocator, before);
    defer allocator.free(digest_before);
    const digest_after = try digestBytesAlloc(allocator, after);
    defer allocator.free(digest_after);
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = digest_before,
        .sequence = 1,
    }};
    const writes = [_]TransactionWrite{.{
        .path = target_path,
        .staged_ref = "write-0.staged",
        .digest_after = digest_after,
        .sequence_after = 2,
    }};
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 909,
            .session_id = "legacy-stage-alias",
            .executor = "test",
        },
        .prepared,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );

    try assertLegacyJournalAliasRejected(transactions_dir, transaction_dir, target_path, before);
}

fn assertLegacyJournalAliasRejected(
    transactions_dir: []const u8,
    transaction_dir: []const u8,
    target_path: []const u8,
    before: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .per_resource,
            },
        ),
    );
    try std.testing.expect(fileExists(fs, transaction_dir));
    const unchanged = try tryReadForTest(target_path);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(before, unchanged);
}

test "committed current journals retain strict scope and writer locks" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-3-00000000000000000000000000000003";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const commit_marker_path = try transactionCommitMarkerPathAlloc(allocator, transaction_dir);
    defer allocator.free(commit_marker_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const content = "{\"seq\":1}\n";
    try writeTextAtomic(fs, allocator, target_path, content);
    const content_digest = try digestBytesAlloc(allocator, content);
    defer allocator.free(content_digest);
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = content_digest,
        .sequence = 1,
    }};
    var writes = [_]TransactionWrite{.{
        .path = target_path,
        .staged_ref = "events.jsonl",
        .digest_after = content_digest,
        .sequence_after = 1,
    }};
    const owner: Owner = .{
        .process_id = 909,
        .session_id = "current-terminal-synchronization",
        .executor = "test",
    };
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        owner,
        .committed,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
    try writeCommittedTransactionMarker(fs, allocator, commit_marker_path);
    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverTransaction(fs, allocator, transaction_dir),
    );

    try assertCommittedRecoveryRetainsWriterLock(
        transaction_id,
        record_path,
        owner,
        &expected,
        writes[0],
        target_path,
        transaction_dir,
        transactions_dir,
    );
}

fn assertCommittedRecoveryRetainsWriterLock(
    transaction_id: []const u8,
    record_path: []const u8,
    owner: Owner,
    expected: []const TransactionExpected,
    initial_write: TransactionWrite,
    target_path: []const u8,
    transaction_dir: []const u8,
    transactions_dir: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var writes = [_]TransactionWrite{initial_write};
    var stage_name_buffer: [96]u8 = undefined;
    writes[0].staged_ref = try transactionStageName(&stage_name_buffer, transaction_id, 0);
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        owner,
        .committed,
        expected,
        &writes,
        &.{},
        1,
        3,
        false,
    );
    var live_writer = try acquireCasAdvisoryLock(fs, allocator, target_path);
    try std.testing.expectError(error.LockBusy, recoverTransaction(fs, allocator, transaction_dir));
    live_writer.close(fs.io);

    try recoverAndCompactTransactions(fs, allocator, transactions_dir);
    try std.testing.expect(!fileExists(fs, transaction_dir));
}

test "journal lock excludes live current recordless reclamation" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(fs, transactions_dir);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{
            transactions_dir,
            "dtx-1-00000000000000000000000000000007",
        },
    );
    defer allocator.free(transaction_dir);
    var live_journal = try acquireTransactionJournalLock(fs, allocator, transactions_dir, null);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    try std.testing.expectError(
        error.LockBusy,
        recoverAndCompactTransactions(fs, allocator, transactions_dir),
    );
    try std.testing.expect(fileExists(fs, transaction_dir));
    live_journal.close(fs.io);

    try recoverAndCompactTransactions(fs, allocator, transactions_dir);
    try std.testing.expect(!fileExists(fs, transaction_dir));
}

test "recovered transaction compaction is idempotent after disappearance" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-35" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    var held_recovery = try acquireTransactionRecoveryLock(fs, allocator, transactions_dir, null);
    try std.testing.expectError(
        error.LockBusy,
        recoverAndCompactTransactionsWithOptions(
            fs,
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{
                    .shared = "/unused/fencing.counter",
                },
            },
        ),
    );
    held_recovery.close(fs.io);
    var transactions = try std.Io.Dir.openDirAbsolute(
        fs.io,
        transactions_dir,
        .{ .follow_symlinks = false },
    );
    defer transactions.close(fs.io);

    var first_mutated = false;
    try compactRecoveredTransaction(
        fs,
        allocator,
        transactions_dir,
        transaction_dir,
        &transactions,
        &first_mutated,
    );
    try std.testing.expect(first_mutated);
    try std.testing.expect(!fileExists(fs, transaction_dir));

    var second_mutated = false;
    try compactRecoveredTransaction(
        fs,
        allocator,
        transactions_dir,
        transaction_dir,
        &transactions,
        &second_mutated,
    );
    try std.testing.expect(!second_mutated);
}

test "transaction records reject non-reserved and target-aliased stages" {
    const transaction_id = "dtx-1-00000000000000000000000000000002";
    var expected = [_]TransactionExpected{.{
        .path = "/repo/.ledger/events.jsonl",
        .digest = "",
        .sequence = 0,
    }};
    const owner: Owner = .{
        .process_id = 903,
        .session_id = "stage-authority",
        .executor = "test",
    };
    var invalid = [_]TransactionWrite{.{
        .path = "/repo/.ledger/events.jsonl",
        .staged_ref = "events.jsonl",
        .digest_after = "",
        .sequence_after = 0,
    }};
    try assertCurrentTransactionStageRejected(
        transaction_id,
        "/repo/.ledger/transactions/dtx-1-00000000000000000000000000000002",
        owner,
        &expected,
        &invalid,
    );
    invalid[0].staged_ref = "write-0.staged";
    try assertCurrentTransactionStageRejected(
        transaction_id,
        "/repo/.ledger/transactions/dtx-1-00000000000000000000000000000002",
        owner,
        &expected,
        &invalid,
    );
    var legacy_stage_buffer: [96]u8 = undefined;
    invalid[0].staged_ref = try transactionStageName(&legacy_stage_buffer, "dtx-1", 0);
    try assertCurrentTransactionStageRejected(
        "dtx-1",
        "/repo/.ledger/transactions/dtx-1",
        owner,
        &expected,
        &invalid,
    );
}

fn assertCurrentTransactionStageRejected(
    transaction_id: []const u8,
    transaction_dir: []const u8,
    owner: Owner,
    expected: []TransactionExpected,
    writes: []TransactionWrite,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope(
            fs,
            std.testing.allocator,
            "/repo/.ledger",
            transaction_dir,
            .{
                .transaction_id = transaction_id,
                .owner = owner,
                .state = .preparing,
                .expected = expected,
                .writes = writes,
                .created_at = "1",
                .updated_at = "2",
            },
            .current,
        ),
    );
}

test "legacy transaction records reject impossible preparing state" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope(
            fs,
            std.testing.allocator,
            "/repo",
            "/repo/transactions/dtx-37",
            .{
                .transaction_id = "dtx-37",
                .owner = .{
                    .process_id = 937,
                    .session_id = "impossible-legacy-preparing",
                    .executor = "test",
                },
                .state = .preparing,
                .expected = &.{},
                .writes = &.{},
                .created_at = "1",
                .updated_at = "2",
            },
            .legacy,
        ),
    );
}

test "recovery custody accepts digest completion and rejects state regression" {
    var preliminary_writes = [_]TransactionWrite{.{
        .path = "/tmp/target",
        .staged_ref = ".txn-dtx-1-00.stage",
        .digest_after = "",
        .sequence_after = 1,
    }};
    var custodied_writes = [_]TransactionWrite{.{
        .path = "/tmp/target",
        .staged_ref = ".txn-dtx-1-00.stage",
        .digest_after = "sha256:after",
        .sequence_after = 1,
    }};
    const preliminary: ParsedTransactionRecord = .{
        .transaction_id = "dtx-1",
        .owner = .{
            .process_id = 1,
            .session_id = "custody",
            .executor = "test",
        },
        .state = .preparing,
        .expected = &.{},
        .writes = &preliminary_writes,
        .created_at = "1",
        .updated_at = "2",
    };
    var custodied = preliminary;
    custodied.state = .prepared;
    custodied.writes = &custodied_writes;
    try std.testing.expect(recoveryRecordCustodyEqual(preliminary, custodied));
    var regressed = custodied;
    regressed.state = .preparing;
    try std.testing.expect(!recoveryRecordCustodyEqual(custodied, regressed));
    regressed.state = .aborted;
    try std.testing.expect(!recoveryRecordCustodyEqual(custodied, regressed));
}

test "custodied recovery snapshot re-reads mutable journal state" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_id = "dtx-1-00000000000000000000000000000070";
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", transaction_id },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const owner: Owner = .{
        .process_id = 970,
        .session_id = "custodied-state",
        .executor = "test",
    };
    try writeCurrentTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        owner,
        .preparing,
        &.{},
        &.{},
        &.{},
        1,
        2,
        true,
    );
    const preliminary = try parseTransactionRecord(fs, allocator, record_path);
    defer preliminary.deinit(allocator);
    const format = try transactionRecordFormat(allocator, preliminary);
    try writeCurrentTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        owner,
        .prepared,
        &.{},
        &.{},
        &.{},
        1,
        3,
        false,
    );
    const custodied = try parseCustodiedRecoveryRecord(
        fs,
        allocator,
        root,
        transaction_dir,
        record_path,
        preliminary,
        format,
    );
    defer custodied.deinit(allocator);
    try std.testing.expectEqual(TransactionState.prepared, custodied.state);
}

fn makePrelimitExpectedRows(
    allocator: std.mem.Allocator,
    root: []const u8,
) ![]TransactionExpected {
    const row_count = transaction_recovery_max_rows + 1;
    const expected = try allocator.alloc(TransactionExpected, row_count);
    var count: usize = 0;
    errdefer {
        for (expected[0..count]) |row| allocator.free(row.path);
        allocator.free(expected);
    }
    for (expected) |*row| {
        row.* = .{
            .path = try allocator.print("{s}/target-{d}.jsonl", .{ root, count }),
            .digest = "",
            .sequence = 0,
        };
        count += 1;
    }
    return expected;
}

fn deinitPrelimitExpectedRows(
    allocator: std.mem.Allocator,
    expected: []TransactionExpected,
) void {
    for (expected) |row| allocator.free(row.path);
    allocator.free(expected);
}

test "pre-limit journals above the current row cap remain inspectable" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-1-00000000000000000000000000000064";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const expected = try makePrelimitExpectedRows(allocator, root);
    defer deinitPrelimitExpectedRows(allocator, expected);
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 964,
            .session_id = "pre-limit-row-compatibility",
            .executor = "test",
        },
        .preparing,
        expected,
        &.{},
        &.{},
        1,
        2,
        true,
    );
    const parsed = try parseTransactionRecord(fs, allocator, record_path);
    defer parsed.deinit(allocator);
    try std.testing.expect(!parsed.bounded_rows);
    const rewritten = try renderParsedTransactionRecordAlloc(allocator, parsed, .committed);
    defer allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"recovery_profile\"") == null);
    var status = try inspectTransaction(fs, allocator, transaction_dir);
    defer status.deinit(allocator);
    try std.testing.expectEqual(RecoveryDecision.roll_back_unpublished, status.decision);
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverTransaction(fs, allocator, transaction_dir),
    );
}

test "legacy format and lock witnesses survive recovery record rewrites" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const record_path = try std.fs.path.join(allocator, &.{ root, "transaction.json" });
    defer allocator.free(record_path);
    var locks = [_]LeaseLock{.{
        .lock_id = "dlk-1-1",
        .resource = "/repo/events.jsonl",
        .owner = .{
            .process_id = 918,
            .session_id = "legacy-format-rewrite",
            .executor = "test",
        },
        .acquired_at = "1",
        .expires_at = "2",
        .fencing_token = 1,
        .path = "/repo/events.jsonl.lock",
    }};
    const original: ParsedTransactionRecord = .{
        .transaction_id = "dtx-1-00000000000000000000000000000012",
        .owner = .{
            .process_id = 918,
            .session_id = "legacy-format-rewrite",
            .executor = "test",
        },
        .state = .prepared,
        .expected = &.{},
        .writes = &.{},
        .embedded_locks = &locks,
        .created_at = "1",
        .updated_at = "2",
    };
    const rewritten = try renderParsedTransactionRecordAlloc(allocator, original, .committed);
    defer allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rewritten,
        "\"journal_format\":\"legacy\"",
    ) != null);
    try writeTextAtomic(fs, allocator, record_path, rewritten);
    const reparsed = try parseTransactionRecord(fs, allocator, record_path);
    defer reparsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), reparsed.embedded_locks.len);
    try std.testing.expectEqualStrings("/repo/events.jsonl", reparsed.embedded_locks[0].resource);
    try std.testing.expectEqual(
        TransactionRecordFormat.legacy,
        try transactionRecordFormat(std.testing.allocator, reparsed),
    );
}

test "legacy journals bind embedded lock witnesses to expected targets" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const owner: Owner = .{
        .process_id = 919,
        .session_id = "legacy-lock-binding",
        .executor = "test",
    };
    var expected = [_]TransactionExpected{.{
        .path = "/repo/target-b.jsonl",
        .digest = "",
        .sequence = 0,
    }};
    var locks = [_]LeaseLock{.{
        .lock_id = "dlk-1-1",
        .resource = "/repo/target-a.jsonl",
        .owner = owner,
        .acquired_at = "1",
        .expires_at = "2",
        .fencing_token = 1,
        .path = "/repo/target-a.jsonl.lock",
    }};
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope(
            fs,
            std.testing.allocator,
            "/repo",
            "/repo/transactions/dtx-1",
            .{
                .transaction_id = "dtx-1",
                .owner = owner,
                .state = .prepared,
                .expected = &expected,
                .writes = &.{},
                .embedded_locks = &locks,
                .created_at = "1",
                .updated_at = "2",
            },
            .legacy,
        ),
    );
}

test "legacy journal path identity follows the host filesystem" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    if (try directoryNameIsCaseInsensitive(
        fs,
        allocator,
        root,
        "Probe",
    )) {
        return error.SkipZigTest;
    }
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-30" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const upper_path = try std.fs.path.join(allocator, &.{ root, "A.jsonl" });
    defer allocator.free(upper_path);
    const lower_path = try std.fs.path.join(allocator, &.{ root, "a.jsonl" });
    defer allocator.free(lower_path);
    var expected = [_]TransactionExpected{
        .{ .path = upper_path, .digest = "", .sequence = 0 },
        .{ .path = lower_path, .digest = "", .sequence = 0 },
    };
    try validateTransactionRecordScope(
        fs,
        allocator,
        root,
        transaction_dir,
        .{
            .transaction_id = "dtx-30",
            .owner = .{
                .process_id = 930,
                .session_id = "host-path-identity",
                .executor = "test",
            },
            .state = .prepared,
            .expected = &expected,
            .writes = &.{},
            .created_at = "1",
            .updated_at = "2",
        },
        .legacy,
    );
}

test "legacy fencing authority rejects canonical target aliases" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-31" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const nested = try std.fs.path.join(allocator, &.{ root, "nested" });
    defer allocator.free(nested);
    try ensureDirectoryPathNoSymlinks(fs, nested);
    const target_path = try std.fs.path.join(allocator, &.{ root, "target.jsonl" });
    defer allocator.free(target_path);
    const counter_alias = try std.fs.path.join(allocator, &.{ nested, "..", "target.jsonl" });
    defer allocator.free(counter_alias);
    var expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = "",
        .sequence = 0,
    }};
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateLegacyFencingAuthorityScope(
            fs,
            allocator,
            transaction_dir,
            .{
                .transaction_id = "dtx-31",
                .owner = .{
                    .process_id = 931,
                    .session_id = "canonical-fencing-alias",
                    .executor = "test",
                },
                .state = .prepared,
                .expected = &expected,
                .writes = &.{},
                .created_at = "1",
                .updated_at = "2",
            },
            .{ .shared = counter_alias },
        ),
    );
    try std.testing.expect(!fileExists(fs, target_path));
}

test "legacy fencing authority rejects non-adjacent target ancestors" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-38" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const target_ancestor = try std.fs.path.join(allocator, &.{ root, "a" });
    defer allocator.free(target_ancestor);
    const sort_interloper = try std.fs.path.join(allocator, &.{ root, "a-guard" });
    defer allocator.free(sort_interloper);
    const counter_path = try std.fs.path.join(allocator, &.{ target_ancestor, "counter" });
    defer allocator.free(counter_path);
    var expected = [_]TransactionExpected{
        .{ .path = target_ancestor, .digest = "", .sequence = 0 },
        .{ .path = sort_interloper, .digest = "", .sequence = 0 },
    };
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateLegacyFencingAuthorityScope(
            fs,
            allocator,
            transaction_dir,
            .{
                .transaction_id = "dtx-38",
                .owner = .{
                    .process_id = 938,
                    .session_id = "non-adjacent-ancestor",
                    .executor = "test",
                },
                .state = .prepared,
                .expected = &expected,
                .writes = &.{},
                .created_at = "1",
                .updated_at = "2",
            },
            .{ .shared = counter_path },
        ),
    );
}

test "legacy path identity recognizes Unicode filesystem aliases" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-39" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const composed_path = try std.fs.path.join(allocator, &.{ root, "\xc3\xa9.jsonl" });
    defer allocator.free(composed_path);
    const decomposed_alias = try std.fs.path.join(allocator, &.{ root, "e\xcc\x81.jsonl" });
    defer allocator.free(decomposed_alias);
    try writeTextAtomic(fs, allocator, composed_path, "7\n");
    if (!fileExists(fs, decomposed_alias)) return error.SkipZigTest;
    const authority_lock = try allocator.print("{s}.lock", .{decomposed_alias});
    defer allocator.free(authority_lock);
    try writeTextAtomic(fs, allocator, authority_lock, "lock\n");
    var expected = [_]TransactionExpected{.{
        .path = composed_path,
        .digest = "",
        .sequence = 0,
    }};
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateLegacyFencingAuthorityScope(
            fs,
            allocator,
            transaction_dir,
            .{
                .transaction_id = "dtx-39",
                .owner = .{
                    .process_id = 939,
                    .session_id = "unicode-host-alias",
                    .executor = "test",
                },
                .state = .prepared,
                .expected = &expected,
                .writes = &.{},
                .created_at = "1",
                .updated_at = "2",
            },
            .{ .shared = decomposed_alias },
        ),
    );
}

test "legacy recovery targets reject derived control path aliases" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-33" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const target_path = try std.fs.path.join(allocator, &.{ root, "target.jsonl" });
    defer allocator.free(target_path);
    const counter_path = try std.fs.path.join(allocator, &.{ root, "fencing.counter" });
    defer allocator.free(counter_path);
    const lease_path = try lockPathAlloc(allocator, target_path);
    defer allocator.free(lease_path);
    const cas_path = try casLockPathAlloc(allocator, target_path);
    defer allocator.free(cas_path);
    const advisory_path = try casAdvisoryPathAlloc(allocator, target_path);
    defer allocator.free(advisory_path);
    const control_paths = [_][]const u8{
        lease_path,
        cas_path,
        advisory_path,
    };
    for (control_paths) |control_path| {
        var expected = [_]TransactionExpected{
            .{ .path = target_path, .digest = "", .sequence = 0 },
            .{ .path = control_path, .digest = "", .sequence = 0 },
        };
        try std.testing.expectError(
            error.TransactionCorrupt,
            validateLegacyFencingAuthorityScope(
                fs,
                allocator,
                transaction_dir,
                .{
                    .transaction_id = "dtx-33",
                    .owner = .{
                        .process_id = 933,
                        .session_id = "recovery-control-target-alias",
                        .executor = "test",
                    },
                    .state = .prepared,
                    .expected = &expected,
                    .writes = &.{},
                    .created_at = "1",
                    .updated_at = "2",
                },
                .{ .shared = counter_path },
            ),
        );
    }
}

test "legacy recovery derives controls from an existing unicode target identity" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    if (!try directoryNameIsCaseInsensitive(
        fs,
        allocator,
        root,
        "Probe",
    )) {
        return error.SkipZigTest;
    }
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, "dtx-61" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const target = try std.fs.path.join(allocator, &.{ root, "caf\xc3\xa9.jsonl" });
    defer allocator.free(target);
    try writeTextAtomic(fs, allocator, target, "{\"sequence\":1}\n");
    var expected = [_]TransactionExpected{.{
        .path = target,
        .digest = "",
        .sequence = 0,
    }};
    try validateLegacyFencingAuthorityScope(
        fs,
        allocator,
        transaction_dir,
        .{
            .transaction_id = "dtx-61",
            .owner = .{
                .process_id = 961,
                .session_id = "unicode-control-identity",
                .executor = "test",
            },
            .state = .prepared,
            .expected = &expected,
            .writes = &.{},
            .created_at = "1",
            .updated_at = "2",
        },
        .per_resource,
    );
}

test "legacy recovery rejects collisions between generated controls" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-40" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const first_target = try std.fs.path.join(allocator, &.{ root, "item" });
    defer allocator.free(first_target);
    const second_target = try allocator.print("{s}.cas", .{first_target});
    defer allocator.free(second_target);
    const counter_path = try std.fs.path.join(allocator, &.{ root, "fencing.counter" });
    defer allocator.free(counter_path);
    var expected = [_]TransactionExpected{
        .{ .path = first_target, .digest = "", .sequence = 0 },
        .{ .path = second_target, .digest = "", .sequence = 0 },
    };
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateLegacyFencingAuthorityScope(
            fs,
            allocator,
            transaction_dir,
            .{
                .transaction_id = "dtx-40",
                .owner = .{
                    .process_id = 940,
                    .session_id = "generated-control-collision",
                    .executor = "test",
                },
                .state = .prepared,
                .expected = &expected,
                .writes = &.{},
                .created_at = "1",
                .updated_at = "2",
            },
            .{ .shared = counter_path },
        ),
    );
}

test "legacy fencing authority rejects derived recovery controls" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-34" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const target_path = try std.fs.path.join(allocator, &.{ root, "target.jsonl" });
    defer allocator.free(target_path);
    const lease_path = try lockPathAlloc(allocator, target_path);
    defer allocator.free(lease_path);
    const cas_path = try casLockPathAlloc(allocator, target_path);
    defer allocator.free(cas_path);
    const advisory_path = try casAdvisoryPathAlloc(allocator, target_path);
    defer allocator.free(advisory_path);
    var expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = "",
        .sequence = 0,
    }};
    const parsed: ParsedTransactionRecord = .{
        .transaction_id = "dtx-34",
        .owner = .{
            .process_id = 934,
            .session_id = "recovery-control-authority-alias",
            .executor = "test",
        },
        .state = .prepared,
        .expected = &expected,
        .writes = &.{},
        .created_at = "1",
        .updated_at = "2",
    };
    const control_paths = [_][]const u8{
        lease_path,
        cas_path,
        advisory_path,
    };
    for (control_paths) |control_path| {
        try writeTextAtomic(fs, allocator, control_path, "7\n");
        try std.testing.expectError(
            error.TransactionCorrupt,
            validateLegacyFencingAuthorityScope(
                fs,
                allocator,
                transaction_dir,
                parsed,
                .{ .shared = control_path },
            ),
        );
        const retained = try tryReadForTest(control_path);
        defer allocator.free(retained);
        try std.testing.expectEqualStrings("7\n", retained);
    }
}

test "legacy recovery control validation is bounded at the row cap" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-36" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const counter_path = try std.fs.path.join(allocator, &.{ root, "fencing.counter" });
    defer allocator.free(counter_path);
    const expected = try allocator.alloc(TransactionExpected, transaction_recovery_max_rows);
    var expected_count: usize = 0;
    defer {
        for (expected[0..expected_count]) |row| allocator.free(row.path);
        allocator.free(expected);
    }
    for (expected, 0..) |*row, index| {
        row.* = .{
            .path = try allocator.print("{s}/target-{d}.jsonl", .{ root, index }),
            .digest = "",
            .sequence = 0,
        };
        expected_count += 1;
    }
    const started_ms = clockMillis(fs, .awake);
    try validateLegacyFencingAuthorityScope(
        fs,
        allocator,
        transaction_dir,
        .{
            .transaction_id = "dtx-36",
            .owner = .{
                .process_id = 936,
                .session_id = "bounded-control-validation",
                .executor = "test",
            },
            .state = .prepared,
            .expected = expected,
            .writes = &.{},
            .created_at = "1",
            .updated_at = "2",
        },
        .{ .shared = counter_path },
    );
    try std.testing.expect(elapsedMillis(fs, started_ms) < 30_000);
}

test "legacy fencing authority cannot regress embedded witness tokens" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(allocator, &.{ root, "transactions", "dtx-32" });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const target_path = try std.fs.path.join(allocator, &.{ root, "target.jsonl" });
    defer allocator.free(target_path);
    const counter_path = try std.fs.path.join(allocator, &.{ root, "fencing.counter" });
    defer allocator.free(counter_path);
    try writeTextAtomic(fs, allocator, counter_path, "9\n");
    const owner: Owner = .{
        .process_id = 932,
        .session_id = "fencing-token-floor",
        .executor = "test",
    };
    var expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = "",
        .sequence = 0,
    }};
    var locks = [_]LeaseLock{.{
        .lock_id = "dlk-10-1",
        .resource = target_path,
        .owner = owner,
        .acquired_at = "1",
        .expires_at = "2",
        .fencing_token = 10,
        .path = "unused",
    }};
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        validateLegacyFencingAuthorityScope(
            fs,
            allocator,
            transaction_dir,
            .{
                .transaction_id = "dtx-32",
                .owner = owner,
                .state = .prepared,
                .expected = &expected,
                .writes = &.{},
                .embedded_locks = &locks,
                .created_at = "1",
                .updated_at = "2",
            },
            .{ .shared = counter_path },
        ),
    );
    const counter = try tryReadForTest(counter_path);
    defer allocator.free(counter);
    try std.testing.expectEqualStrings("9\n", counter);
}

test "transaction writes require exact expected path identity" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const transaction_id = "dtx-1-00000000000000000000000000000013";
    var expected = [_]TransactionExpected{.{
        .path = "/repo/foo",
        .digest = "",
        .sequence = 0,
    }};
    var stage_buffer: [96]u8 = undefined;
    const staged_ref = try transactionStageName(&stage_buffer, transaction_id, 0);
    var writes = [_]TransactionWrite{.{
        .path = "/repo/FOO",
        .staged_ref = staged_ref,
        .digest_after = "",
        .sequence_after = 0,
    }};
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope(
            fs,
            std.testing.allocator,
            "/repo",
            "/repo/transactions/dtx-1-00000000000000000000000000000013",
            .{
                .transaction_id = transaction_id,
                .owner = .{
                    .process_id = 919,
                    .session_id = "exact-path-identity",
                    .executor = "test",
                },
                .state = .prepared,
                .expected = &expected,
                .writes = &writes,
                .created_at = "1",
                .updated_at = "2",
            },
            .current,
        ),
    );
}

test "transaction recovery binds journal identity to its directory" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
    defer allocator.free(transactions_dir);
    const directory_id = "dtx-1-00000000000000000000000000000008";
    const claimed_id = "dtx-1-00000000000000000000000000000009";
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, directory_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const target_path = try std.fs.path.join(allocator, &.{ root, "events.jsonl" });
    defer allocator.free(target_path);
    const staged_ref = try transactionStageNameAlloc(allocator, claimed_id, 0);
    defer allocator.free(staged_ref);
    const staged_path = try std.fs.path.join(allocator, &.{ transaction_dir, staged_ref });
    defer allocator.free(staged_path);
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = "",
        .sequence = 0,
    }};
    const writes = [_]TransactionWrite{.{
        .path = target_path,
        .staged_ref = staged_ref,
        .digest_after = "",
        .sequence_after = 1,
    }};
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        claimed_id,
        .{
            .process_id = 905,
            .session_id = "identity-mismatch",
            .executor = "test",
        },
        .preparing,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
    try writeTextCreateNew(fs, allocator, staged_path, "{\"seq\":1}\n", .{});

    try std.testing.expectError(
        error.TransactionCorrupt,
        inspectTransaction(fs, allocator, transaction_dir),
    );
    try std.testing.expect(fileExists(fs, staged_path));
}

test "transactions publish in canonical path order and reject duplicates" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(fs, transactions_dir);
    const counter = try std.fs.path.join(std.testing.allocator, &.{ root, "counter" });
    defer std.testing.allocator.free(counter);
    const a_path = try std.fs.path.join(std.testing.allocator, &.{ root, "a-plan.jsonl" });
    defer std.testing.allocator.free(a_path);
    const z_path = try std.fs.path.join(std.testing.allocator, &.{ root, "z-workspace.jsonl" });
    defer std.testing.allocator.free(z_path);
    try writeTextAtomic(fs, std.testing.allocator, a_path, "{\"seq\":1,\"name\":\"a\"}\n");
    try writeTextAtomic(fs, std.testing.allocator, z_path, "{\"seq\":1,\"name\":\"z\"}\n");

    const owner: Owner = .{ .process_id = 201, .session_id = "ordered", .executor = "test" };
    const reverse = [_]TransactionMutation{
        .{
            .path = z_path,
            .text = "{\"seq\":2,\"name\":\"z\"}\n",
            .expectation = .{ .expected_sequence = 1, .expected_exists = true },
        },
        .{
            .path = a_path,
            .text = "{\"seq\":2,\"name\":\"a\"}\n",
            .expectation = .{ .expected_sequence = 1, .expected_exists = true },
        },
    };
    var receipt = try commitTextTransaction(
        fs,
        std.testing.allocator,
        transactions_dir,
        &reverse,
        .{
            .owner = owner,
            .fencing_counter_path = counter,
        },
    );
    defer receipt.deinit(std.testing.allocator);

    const record = try readRegularFileNoSymlink(
        fs,
        std.testing.allocator,
        receipt.record_path,
        default_snapshot_max_bytes,
    );
    defer std.testing.allocator.free(record);
    const a_index = std.mem.indexOf(
        u8,
        record,
        a_path,
    ) orelse return error.TestExpectedCanonicalPath;
    const z_index = std.mem.indexOf(
        u8,
        record,
        z_path,
    ) orelse return error.TestExpectedCanonicalPath;
    try std.testing.expect(a_index < z_index);

    try assertDuplicateTransactionTargetsRejected(a_path, transactions_dir, owner, counter);
}

fn assertDuplicateTransactionTargetsRejected(
    a_path: []const u8,
    transactions_dir: []const u8,
    owner: Owner,
    counter: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const duplicate = [_]TransactionMutation{
        .{
            .path = a_path,
            .text = "{\"seq\":3,\"name\":\"a\"}\n",
            .expectation = .{ .expected_sequence = 2, .expected_exists = true },
        },
        .{
            .path = a_path,
            .text = "{\"seq\":4,\"name\":\"a\"}\n",
            .expectation = .{ .expected_sequence = 2, .expected_exists = true },
        },
    };
    try std.testing.expectError(
        error.InvalidPath,
        commitTextTransaction(fs, std.testing.allocator, transactions_dir, &duplicate, .{
            .owner = owner,
            .fencing_counter_path = counter,
        }),
    );
}

test "appendJsonlCheckpointTransaction publishes checkpoint and receipts" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(store_path);
    const locks_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "locks" });
    defer std.testing.allocator.free(locks_dir);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);

    var first = try appendJsonlCheckpointTransaction(
        fs,
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":1,\"ok\":true}",
        .{
            .expected_sequence = 0,
            .sequence_field = "workspace_sequence",
            .operation = "test-init",
        },
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), first.sequence_before);
    try std.testing.expectEqual(@as(i64, 1), first.sequence_after);
    try std.testing.expect(fileExists(fs, first.prepared_path));
    try std.testing.expect(fileExists(fs, first.commit_path));

    var second = try appendJsonlCheckpointTransaction(
        fs,
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":2,\"ok\":false}",
        .{
            .expected_sequence = 1,
            .sequence_field = "workspace_sequence",
            .operation = "test-append",
        },
    );
    defer second.deinit(std.testing.allocator);
    const data = try tryReadForTest(store_path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings(
        "{\"workspace_sequence\":1,\"ok\":true}\n{\"workspace_sequence\":2,\"ok\":false}\n",
        data,
    );
}

test "appendJsonlCheckpointTransaction rejects stale sequence without publishing" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(store_path);
    const locks_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "locks" });
    defer std.testing.allocator.free(locks_dir);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);

    var first = try appendJsonlCheckpointTransaction(
        fs,
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":1,\"ok\":true}",
        .{ .expected_sequence = 0, .sequence_field = "workspace_sequence" },
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expectError(error.SequenceStale, appendJsonlCheckpointTransaction(
        fs,
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":2,\"ok\":false}",
        .{ .expected_sequence = 0, .sequence_field = "workspace_sequence" },
    ));
    const data = try tryReadForTest(store_path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"workspace_sequence\":1,\"ok\":true}\n", data);
}

test "appendJsonlCheckpointTransaction reports pending prepared recovery" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(store_path);
    const locks_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "locks" });
    defer std.testing.allocator.free(locks_dir);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(fs, transactions_dir);
    const prepared_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ transactions_dir, "txn-orphan.prepared.json" },
    );
    defer std.testing.allocator.free(prepared_path);
    try writeTextCreateNew(
        fs,
        std.testing.allocator,
        prepared_path,
        "{\"state\":\"prepared\"}\n",
        .{},
    );

    try std.testing.expectError(error.TransactionRecoveryRequired, appendJsonlCheckpointTransaction(
        fs,
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":1,\"ok\":true}",
        .{ .expected_sequence = 0, .sequence_field = "workspace_sequence" },
    ));
}

fn writePreparedRecordForTest(
    allocator: std.mem.Allocator,
    record_path: []const u8,
    transaction_id: []const u8,
    owner: Owner,
    path: []const u8,
    before: []const u8,
    after: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const digest_before = try digestBytesAlloc(allocator, before);
    defer allocator.free(digest_before);
    const digest_after = try digestBytesAlloc(allocator, after);
    defer allocator.free(digest_after);
    const expected = [_]TransactionExpected{.{
        .path = path,
        .digest = digest_before,
        .sequence = (try jsonlSequenceRequired(allocator, before)).?,
    }};
    const staged_ref = try transactionRecordStageNameAlloc(allocator, transaction_id, 0);
    defer allocator.free(staged_ref);
    const writes = [_]TransactionWrite{.{
        .path = path,
        .staged_ref = staged_ref,
        .digest_after = digest_after,
        .sequence_after = (try jsonlSequenceRequired(allocator, after)).?,
    }};
    const transaction_dir = std.fs.path.dirname(record_path) orelse
        return error.InvalidPath;
    const staged_path = try std.fs.path.join(allocator, &.{ transaction_dir, staged_ref });
    defer allocator.free(staged_path);
    try writeTextCreateNew(fs, allocator, staged_path, after, .{});
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        owner,
        .prepared,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
}

fn writeCommittedRecoveryJournalForTest(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    transaction_id: []const u8,
    target_path: []const u8,
    content: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const digest = try digestBytesAlloc(allocator, content);
    defer allocator.free(digest);
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = digest,
        .sequence = 1,
    }};
    const staged_ref = try transactionRecordStageNameAlloc(allocator, transaction_id, 0);
    defer allocator.free(staged_ref);
    const writes = [_]TransactionWrite{.{
        .path = target_path,
        .staged_ref = staged_ref,
        .digest_after = digest,
        .sequence_after = 1,
    }};
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 964,
            .session_id = "aggregate-recovery-budget",
            .executor = "test",
        },
        .committed,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
}

fn writePreparedLegacyStageRecordForTest(
    allocator: std.mem.Allocator,
    record_path: []const u8,
    transaction_id: []const u8,
    owner: Owner,
    path: []const u8,
    before: []const u8,
    after: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const digest_before = try digestBytesAlloc(allocator, before);
    defer allocator.free(digest_before);
    const digest_after = try digestBytesAlloc(allocator, after);
    defer allocator.free(digest_after);
    const expected = [_]TransactionExpected{.{
        .path = path,
        .digest = digest_before,
        .sequence = 0,
    }};
    var stage_buffer: [96]u8 = undefined;
    const staged_ref = try legacyTransactionStageName(&stage_buffer, 0);
    const writes = [_]TransactionWrite{.{
        .path = path,
        .staged_ref = staged_ref,
        .digest_after = digest_after,
        .sequence_after = 0,
    }};
    const transaction_dir = std.fs.path.dirname(record_path) orelse
        return error.InvalidPath;
    const staged_path = try std.fs.path.join(allocator, &.{ transaction_dir, staged_ref });
    defer allocator.free(staged_path);
    try writeTextCreateNew(fs, allocator, staged_path, after, .{});
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        owner,
        .prepared,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
}

fn writePreparedTwoWriteRecordForTest(
    allocator: std.mem.Allocator,
    record_path: []const u8,
    transaction_id: []const u8,
    owner: Owner,
    path_a: []const u8,
    path_b: []const u8,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const before = "{\"seq\":1}\n";
    const after = "{\"seq\":2}\n";
    const digest_before = try digestBytesAlloc(allocator, before);
    defer allocator.free(digest_before);
    const digest_after = try digestBytesAlloc(allocator, after);
    defer allocator.free(digest_after);
    const expected = [_]TransactionExpected{
        .{
            .path = path_a,
            .digest = digest_before,
            .sequence = 1,
        },
        .{
            .path = path_b,
            .digest = digest_before,
            .sequence = 1,
        },
    };
    const staged_ref_a = try transactionRecordStageNameAlloc(allocator, transaction_id, 0);
    defer allocator.free(staged_ref_a);
    const staged_ref_b = try transactionRecordStageNameAlloc(allocator, transaction_id, 1);
    defer allocator.free(staged_ref_b);
    const writes = [_]TransactionWrite{
        .{
            .path = path_a,
            .staged_ref = staged_ref_a,
            .digest_after = digest_after,
            .sequence_after = 2,
        },
        .{
            .path = path_b,
            .staged_ref = staged_ref_b,
            .digest_after = digest_after,
            .sequence_after = 2,
        },
    };
    const transaction_dir = std.fs.path.dirname(record_path) orelse
        return error.InvalidPath;
    const staged_a = try std.fs.path.join(allocator, &.{ transaction_dir, staged_ref_a });
    defer allocator.free(staged_a);
    const staged_b = try std.fs.path.join(allocator, &.{ transaction_dir, staged_ref_b });
    defer allocator.free(staged_b);
    try writeTextCreateNew(fs, allocator, staged_a, after, .{});
    try writeTextCreateNew(fs, allocator, staged_b, after, .{});
    try writeTransactionRecord(
        fs,
        allocator,
        record_path,
        transaction_id,
        owner,
        .prepared,
        &expected,
        &writes,
        &.{},
        1,
        2,
        true,
    );
}

fn transactionRecordStageNameAlloc(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    write_index: usize,
) ![]u8 {
    if (isGeneratedTransactionId(transaction_id)) {
        return transactionStageNameAlloc(allocator, transaction_id, write_index);
    }
    if (!isLegacyTransactionId(transaction_id)) {
        return error.TransactionCorrupt;
    }
    var buffer: [96]u8 = undefined;
    return allocator.dupe(u8, try legacyTransactionStageName(&buffer, write_index));
}

pub const TransactionAllocationFixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    transactions_dir: []u8,
    target_path: []u8,

    const before = "{\"seq\":1}\n";
    const after = "{\"seq\":2}\n";

    pub fn init() !TransactionAllocationFixture {
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(fs.io, ".", allocator);
        errdefer allocator.free(root);
        const transactions_dir = try std.fs.path.join(allocator, &.{ root, "transactions" });
        errdefer allocator.free(transactions_dir);
        const target_path = try std.fs.path.join(allocator, &.{ root, "target.jsonl" });
        errdefer allocator.free(target_path);
        try ensureDirectoryPathNoSymlinks(fs, transactions_dir);
        try writeTextAtomic(fs, allocator, target_path, before);
        return .{
            .tmp = tmp,
            .root = root,
            .transactions_dir = transactions_dir,
            .target_path = target_path,
        };
    }

    pub fn deinit(self: *TransactionAllocationFixture) void {
        std.testing.allocator.free(self.target_path);
        std.testing.allocator.free(self.transactions_dir);
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    pub fn expectContent(self: TransactionAllocationFixture, expected: []const u8) !void {
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        const actual = try readRegularFileNoSymlink(
            fs,
            std.testing.allocator,
            self.target_path,
            4096,
        );
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }

    fn expectUnpublished(self: TransactionAllocationFixture) !void {
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        try self.expectContent(before);
        try std.testing.expectEqual(
            @as(usize, 0),
            try countPendingTransactions(fs, std.testing.allocator, self.transactions_dir),
        );
        var dir = try std.Io.Dir.openDirAbsolute(
            fs.io,
            self.transactions_dir,
            .{ .iterate = true },
        );
        defer dir.close(fs.io);
        var iter = dir.iterate();
        while (try iter.next(fs.io)) |entry| {
            // Preflight may create supported advisory sidecars, but no journal or receipt.
            try std.testing.expect(entry.kind != .directory);
            try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".json"));
        }
    }
};

test "transaction preparation allocation failures preserve targets without journals" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkTransactionPreparationAllocation,
        .{},
    );
}

fn checkTransactionPreparationAllocation(allocator: std.mem.Allocator) !void {
    var fixture = try TransactionAllocationFixture.init();
    defer fixture.deinit();
    const result = prepareTransactionAllocationCase(allocator, fixture);
    try fixture.expectUnpublished();
    try result;
}

fn prepareTransactionAllocationCase(
    allocator: std.mem.Allocator,
    fixture: TransactionAllocationFixture,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const mutations = [_]TransactionMutation{.{
        .path = fixture.target_path,
        .text = TransactionAllocationFixture.after,
        .expectation = .{ .expected_exists = true },
        .content_mode = .raw,
        .max_bytes = 4096,
    }};
    var commit: TransactionCommit = .{
        .fs = fs,
        .allocator = allocator,
        .transactions_dir = fixture.transactions_dir,
        .options = .{ .owner = .{
            .process_id = 1100,
            .session_id = "allocation-preparation",
            .executor = "test",
        } },
    };
    defer commit.deinit();
    try commit.prepare(&mutations);
    try commit.prepareRows();
    try std.testing.expect(!commit.record_persisted);
    try std.testing.expect(!fileExists(fs, commit.transaction_dir));
    try std.testing.expect(!fileExists(fs, commit.commit_marker_path));
}

test "transaction row constructors free every partial allocation" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkExpectedTransactionRowAllocation,
        .{},
    );
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkWriteTransactionRowAllocation,
        .{},
    );
}

fn checkExpectedTransactionRowAllocation(allocator: std.mem.Allocator) !void {
    var digest = "sha256:before".*;
    const before: TransactionSnapshot = .{ .digest = &digest, .sequence = 1, .byte_len = 10 };
    const mutation: TransactionMutation = .{
        .path = "/repo/target.jsonl",
        .text = TransactionAllocationFixture.after,
        .expectation = .{ .expected_exists = true, .expected_digest = &digest },
    };
    var rows = [_]TransactionExpected{
        try transactionExpectedRowAlloc(allocator, mutation, before, true, false),
    };
    defer freeTransactionExpectedRows(allocator, &rows);
    try std.testing.expectEqualStrings(mutation.path, rows[0].path);
    try std.testing.expectEqualStrings(&digest, rows[0].digest);
    try std.testing.expectEqual(@as(u64, 1), rows[0].sequence);
    try std.testing.expect(rows[0].path.ptr != mutation.path.ptr);
    try std.testing.expect(rows[0].digest.ptr != before.digest.ptr);
}

fn checkWriteTransactionRowAllocation(allocator: std.mem.Allocator) !void {
    const mutation: TransactionMutation = .{
        .path = "/repo/target.jsonl",
        .text = TransactionAllocationFixture.after,
    };
    var rows = [_]TransactionWrite{
        try transactionWriteRowAlloc(allocator, "dtx-1", 0, mutation, "target.jsonl"),
    };
    defer freeTransactionWriteRows(allocator, &rows);
    try std.testing.expectEqualStrings(mutation.path, rows[0].path);
    try std.testing.expectEqual(@as(u64, 2), rows[0].sequence_after);
    try std.testing.expect(rows[0].path.ptr != mutation.path.ptr);
    var stage_buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        try transactionStageName(&stage_buffer, "dtx-1", 0),
        rows[0].staged_ref,
    );
}

test "oversized raw append preserves the target and owns its staged row exactly once" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var fixture = try TransactionAllocationFixture.init();
    defer fixture.deinit();
    const allocator = std.testing.allocator;
    const suffix = "extra";
    const before_digest = try digestBytesAlloc(allocator, TransactionAllocationFixture.before);
    defer allocator.free(before_digest);
    const after_digest = try digestBytesAlloc(
        allocator,
        TransactionAllocationFixture.before ++ suffix,
    );
    defer allocator.free(after_digest);
    const mutations = [_]TransactionMutation{.{
        .path = fixture.target_path,
        .text = suffix,
        .expectation = .{ .expected_exists = true, .expected_digest = before_digest },
        .content_mode = .raw,
        .action = .append,
        .max_bytes = TransactionAllocationFixture.before.len + suffix.len - 1,
        .expected_digest_after = after_digest,
    }};
    try std.testing.expectError(
        error.FileTooBig,
        commitTextTransaction(fs, allocator, fixture.transactions_dir, &mutations, .{ .owner = .{
            .process_id = 1101,
            .session_id = "bounded-append",
            .executor = "test",
        } }),
    );
    try fixture.expectUnpublished();
}

const CasAllocationOperation = enum { write, snapshot };

const DependencyFixture = struct {
    storage: TransactionAllocationFixture,
    transaction_dir: []u8,
    record_path: []u8,
    other_path: []u8,

    fn init(format: TransactionRecordFormat) !DependencyFixture {
        const allocator = std.testing.allocator;
        var storage = try TransactionAllocationFixture.init();
        errdefer storage.deinit();
        const id = switch (format) {
            .current => "dtx-1-00000000000000000000000000000042",
            .legacy => "dtx-1",
        };
        const transaction_dir = try std.fs.path.join(allocator, &.{ storage.transactions_dir, id });
        errdefer allocator.free(transaction_dir);
        const record_path = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "transaction.json" },
        );
        errdefer allocator.free(record_path);
        const other_path = try std.fs.path.join(allocator, &.{ storage.root, "other.jsonl" });
        errdefer allocator.free(other_path);
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        try ensureDirectoryPathNoSymlinks(fs, transaction_dir);
        try writePreparedTwoWriteRecordForTest(
            allocator,
            record_path,
            id,
            .{ .process_id = 1200, .session_id = "dependencies", .executor = "test" },
            storage.target_path,
            other_path,
        );
        return .{
            .storage = storage,
            .transaction_dir = transaction_dir,
            .record_path = record_path,
            .other_path = other_path,
        };
    }

    fn deinit(self: *DependencyFixture) void {
        const allocator = std.testing.allocator;
        allocator.free(self.transaction_dir);
        allocator.free(self.record_path);
        allocator.free(self.other_path);
        self.storage.deinit();
    }

    fn enumerate(self: DependencyFixture, selected: []const []const u8) !TransactionDependencies {
        return enumerateTransactionDependencies(
            Fs.init(std.testing.io, std.Io.Dir.cwd()),
            std.testing.allocator,
            self.transaction_dir,
            selected,
        );
    }

    fn coordinate(self: DependencyFixture, selected: []const []const u8) !void {
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        const allocator = std.testing.allocator;
        const recovery = try acquireTransactionRecoveryLock(
            fs,
            allocator,
            self.storage.transactions_dir,
            null,
        );
        recovery.close(fs.io);
        const journal = try acquireTransactionJournalLock(
            fs,
            allocator,
            self.storage.transactions_dir,
            null,
        );
        journal.close(fs.io);
        for (selected) |path| {
            const lock = try acquireCasAdvisoryLock(fs, allocator, path);
            lock.close(fs.io);
        }
    }

    fn snapshot(
        self: DependencyFixture,
        selected: []const []const u8,
        limits: TransactionDependencyLimits,
    ) !TransactionDependencySnapshot {
        return snapshotTransactionDependencies(
            Fs.init(std.testing.io, std.Io.Dir.cwd()),
            std.testing.allocator,
            self.storage.transactions_dir,
            selected,
            limits,
        );
    }

    fn replaceRecord(self: DependencyFixture, parsed: ParsedTransactionRecord) !void {
        try writeTransactionRecord(
            Fs.init(std.testing.io, std.Io.Dir.cwd()),
            std.testing.allocator,
            self.record_path,
            parsed.transaction_id,
            parsed.owner,
            parsed.state,
            parsed.expected,
            parsed.writes,
            &.{},
            1,
            2,
            false,
        );
    }
};

test "publication custody transfers alias snapshots and permits guarded transaction" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    var custody = custody: {
        var first = try fixture.snapshot(&.{fixture.storage.target_path}, .{});
        defer first.deinit(allocator);
        var second = try snapshotTransactionDependenciesAt(
            Fs.anchored(fs.io, fixture.storage.tmp.dir),
            allocator,
            "./transactions",
            &.{"./other.jsonl"},
            .{ .recorded_control_root = fixture.storage.root },
            .{},
        );
        defer second.deinit(allocator);
        var result = try TransactionPublicationCustody.acquire(allocator, &.{ &first, &second });
        errdefer result.deinit(allocator);
        try std.testing.expectEqual(.released, first.coordination);
        try std.testing.expectEqual(.released, second.coordination);
        try std.testing.expectEqual(@as(usize, 0), first.owned_lock_count);
        try std.testing.expectEqual(@as(usize, 0), second.owned_lock_count);
        try std.testing.expectEqual(.uncoordinated, first.transactions[0].coordination);
        break :custody result;
    };
    {
        defer custody.deinit(allocator);
        try std.testing.expectError(
            error.LockBusy,
            acquireTransactionRecoveryLock(fs, allocator, fixture.storage.transactions_dir, null),
        );
        const receipt = try commitTextTransactionControlled(
            fs,
            allocator,
            fixture.storage.transactions_dir,
            &.{.{
                .path = fixture.storage.target_path,
                .text = TransactionAllocationFixture.after,
                .expectation = .{ .expected_exists = true, .expected_sequence = 1 },
            }},
            .{ .owner = .{ .process_id = 1201, .session_id = "handoff", .executor = "test" } },
            .{ .custody = &custody },
        );
        defer receipt.transaction.deinit(allocator);
        try std.testing.expectEqual(.committed, receipt.semantic);
        try fixture.storage.expectContent(TransactionAllocationFixture.after);
        try std.testing.expectError(
            error.LockBusy,
            acquireTransactionRecoveryLock(fs, allocator, fixture.storage.transactions_dir, null),
        );
        try std.testing.expectError(
            error.LockBusy,
            acquireTransactionJournalLock(fs, allocator, fixture.storage.transactions_dir, null),
        );
    }
    const recovery = try acquireTransactionRecoveryLock(
        fs,
        allocator,
        fixture.storage.transactions_dir,
        null,
    );
    recovery.close(fs.io);
}

test "publication custody rejects different roots and duplicate snapshots before releasing guards" {
    const allocator = std.testing.allocator;
    var first_fixture = try DependencyFixture.init(.current);
    defer first_fixture.deinit();
    var second_fixture = try DependencyFixture.init(.current);
    defer second_fixture.deinit();
    try first_fixture.coordinate(&.{ first_fixture.storage.target_path, first_fixture.other_path });
    try second_fixture.coordinate(&.{
        second_fixture.storage.target_path, second_fixture.other_path,
    });
    var first = try first_fixture.snapshot(&.{first_fixture.storage.target_path}, .{});
    defer first.deinit(allocator);
    var second = try second_fixture.snapshot(&.{second_fixture.storage.target_path}, .{});
    defer second.deinit(allocator);
    try std.testing.expectError(
        error.TransactionDependencyCoordinationUnavailable,
        TransactionPublicationCustody.acquire(allocator, &.{}),
    );
    try std.testing.expectError(
        error.TransactionReservationMismatch,
        TransactionPublicationCustody.acquire(allocator, &.{ &first, &second }),
    );
    try std.testing.expectError(
        error.TransactionDependencyCoordinationUnavailable,
        TransactionPublicationCustody.acquire(allocator, &.{ &first, &first }),
    );
    try std.testing.expectEqual(.retained_read_custody, first.coordination);
    try std.testing.expectEqual(.retained_read_custody, second.coordination);
    var custody = try TransactionPublicationCustody.acquire(allocator, &.{&first});
    defer custody.deinit(allocator);
    try std.testing.expectError(
        error.TransactionReservationMismatch,
        commitTextTransactionControlled(
            first.fs,
            allocator,
            second_fixture.storage.transactions_dir,
            &.{.{
                .path = second_fixture.storage.target_path,
                .text = TransactionAllocationFixture.after,
            }},
            .{ .owner = .{ .process_id = 1201, .session_id = "wrong-root", .executor = "test" } },
            .{ .custody = &custody },
        ),
    );
    try second_fixture.storage.expectContent(TransactionAllocationFixture.before);
}

test "publication custody conflicting handoff preserves recovery and releases owned guards safely" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    {
        var first = try fixture.snapshot(&.{fixture.storage.target_path}, .{});
        defer first.deinit(allocator);
        var omitted = try fixture.snapshot(&.{fixture.other_path}, .{});
        defer omitted.deinit(allocator);
        try std.testing.expectError(
            error.LockBusy,
            TransactionPublicationCustody.acquire(allocator, &.{&first}),
        );
        try std.testing.expectEqual(.released, first.coordination);
        try std.testing.expectEqual(.retained_read_custody, omitted.coordination);
        try std.testing.expectEqual(first.locks.len - 1, first.owned_lock_count);
        try std.testing.expectError(
            error.TransactionDependencyCoordinationUnavailable,
            TransactionPublicationCustody.acquire(allocator, &.{ &first, &omitted }),
        );
        try std.testing.expectError(
            error.LockBusy,
            acquireTransactionRecoveryLock(fs, allocator, fixture.storage.transactions_dir, null),
        );
        try std.testing.expectError(
            error.LockBusy,
            acquireCasAdvisoryLock(fs, allocator, fixture.storage.target_path),
        );
    }
    const recovery = try acquireTransactionRecoveryLock(
        fs,
        allocator,
        fixture.storage.transactions_dir,
        null,
    );
    recovery.close(fs.io);
    const journal = try acquireTransactionJournalLock(
        fs,
        allocator,
        fixture.storage.transactions_dir,
        null,
    );
    journal.close(fs.io);
    const target = try acquireCasAdvisoryLock(fs, allocator, fixture.storage.target_path);
    target.close(fs.io);
}

test "publication custody allocation failure retains full read custody" {
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    var snapshot = try fixture.snapshot(&.{fixture.storage.target_path}, .{});
    defer snapshot.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        TransactionPublicationCustody.acquire(failing.allocator(), &.{&snapshot}),
    );
    try std.testing.expectEqual(.retained_read_custody, snapshot.coordination);
    try std.testing.expectEqual(snapshot.locks.len, snapshot.owned_lock_count);
    var custody = try TransactionPublicationCustody.acquire(allocator, &.{&snapshot});
    defer custody.deinit(allocator);
}

test "publication custody missing journal cannot recreate coordination" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    var snapshot = try fixture.snapshot(&.{fixture.storage.target_path}, .{});
    defer snapshot.deinit(allocator);
    const journal_path = try std.fs.path.join(
        allocator,
        &.{ fixture.storage.transactions_dir, ".journal.advisory" },
    );
    defer allocator.free(journal_path);
    try fs.directory().deleteFile(fs.io, journal_path);
    try std.testing.expectError(
        error.TransactionDependencyCoordinationUnavailable,
        TransactionPublicationCustody.acquire(allocator, &.{&snapshot}),
    );
    try std.testing.expectEqual(.released, snapshot.coordination);
    try std.testing.expect(try statRegularFileNoSymlink(fs, journal_path) == null);
    try std.testing.expectError(
        error.LockBusy,
        acquireTransactionRecoveryLock(fs, allocator, fixture.storage.transactions_dir, null),
    );
}

test "publication custody does not wait for a competing target writer" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    var snapshot = try fixture.snapshot(&.{fixture.storage.target_path}, .{});
    defer snapshot.deinit(allocator);
    var custody = try TransactionPublicationCustody.acquire(allocator, &.{&snapshot});
    defer custody.deinit(allocator);
    const target = try acquireCasAdvisoryLock(fs, allocator, fixture.storage.target_path);
    defer target.close(fs.io);
    try std.testing.expectError(
        error.LockBusy,
        commitTextTransactionControlled(
            fs,
            allocator,
            fixture.storage.transactions_dir,
            &.{.{
                .path = fixture.storage.target_path,
                .text = TransactionAllocationFixture.after,
            }},
            .{ .owner = .{ .process_id = 1201, .session_id = "busy-target", .executor = "test" } },
            .{ .custody = &custody },
        ),
    );
    try fixture.storage.expectContent(TransactionAllocationFixture.before);
}

test "transaction dependency snapshot excludes a live writer and retains crashed pending custody" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    {
        var writer: TransactionCommit = .{
            .fs = fs,
            .allocator = allocator,
            .transactions_dir = fixture.storage.transactions_dir,
            .options = .{ .owner = .{
                .process_id = 1201,
                .session_id = "snapshot-writer",
                .executor = "test",
            } },
        };
        defer writer.deinit();
        try writer.prepare(
            &.{.{ .path = fixture.storage.target_path, .text = "after", .content_mode = .raw }},
        );
        try std.testing.expectError(
            error.LockBusy,
            fixture.snapshot(&.{fixture.storage.target_path}, .{}),
        );
    }
    var snapshot = try fixture.snapshot(&.{fixture.storage.target_path}, .{});
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.transactions.len);
    try std.testing.expectEqual(.prepared, snapshot.transactions[0].state);
    try std.testing.expectEqual(.transaction_root_only, snapshot.coverage);
    try std.testing.expectEqual(.not_inspected, snapshot.reserved_intent_coverage);
    try std.testing.expectEqual(.retained_read_custody, snapshot.coordination);
    try std.testing.expectError(
        error.LockBusy,
        acquireTransactionRecoveryLock(fs, allocator, fixture.storage.transactions_dir, null),
    );
    try std.testing.expectError(
        error.LockBusy,
        acquireTransactionJournalLock(fs, allocator, fixture.storage.transactions_dir, null),
    );
    try std.testing.expectError(
        error.LockBusy,
        acquireCasAdvisoryLock(fs, allocator, fixture.other_path),
    );
}

test "dependency snapshot retains whole atomic and reserved committed evidence" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    for ([_]TransactionState{ .prepared, .committed }) |state| {
        var fixture = try DependencyFixture.init(.current);
        defer fixture.deinit();
        try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
        var parsed = try parseTransactionRecord(fs, allocator, fixture.record_path);
        defer parsed.deinit(allocator);
        parsed.state = state;
        try fixture.replaceRecord(parsed);
        const pin = try std.fs.path.join(
            allocator,
            &.{ fixture.transaction_dir, reservation_pin_leaf },
        );
        defer allocator.free(pin);
        try writeTextCreateNew(fs, allocator, pin, "retained reservation witness", .{});
        if (state == .committed) {
            const marker = try transactionCommitMarkerPathAlloc(allocator, fixture.transaction_dir);
            defer allocator.free(marker);
            try writeTextCreateNew(fs, allocator, marker, "retained commit witness", .{});
        }
        var snapshot = try fixture.snapshot(&.{fixture.storage.target_path}, .{});
        defer snapshot.deinit(allocator);
        const Probe = struct {
            other: []const u8,
            count: usize = 0,
            targets: usize = 0,
            stages: usize = 0,
            other_seen: bool = false,
            pin_seen: bool = false,
            marker_present: bool = false,

            pub fn visit(self: *@This(), id: []const u8, dependency: TransactionDependency) !void {
                try std.testing.expect(id.len > 0);
                self.count += 1;
                switch (dependency.kind) {
                    .target => self.targets += 1,
                    .staged => self.stages += 1,
                    .reservation_pin => self.pin_seen = dependency.present,
                    .commit_marker => self.marker_present = dependency.present,
                    .journal => try std.testing.expect(dependency.present),
                }
                if (std.mem.eql(u8, self.other, dependency.path)) self.other_seen = true;
            }
        };
        var probe: Probe = .{ .other = fixture.other_path };
        try snapshot.visit(&probe);
        try std.testing.expectEqual(@as(usize, 7), probe.count);
        try std.testing.expectEqual(@as(usize, 2), probe.targets);
        try std.testing.expectEqual(@as(usize, 2), probe.stages);
        try std.testing.expect(probe.other_seen and probe.pin_seen);
        try std.testing.expectEqual(state == .committed, probe.marker_present);
    }
}

test "transaction dependency snapshot resolves alias spellings without reading disjoint payload" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    const alias = try allocator.print("{s}/./{s}", .{
        std.fs.path.dirname(fixture.storage.target_path).?,
        std.fs.path.basename(fixture.storage.target_path),
    });
    defer allocator.free(alias);
    {
        var snapshot = try fixture.snapshot(&.{alias}, .{});
        defer snapshot.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), snapshot.transactions.len);
    }
    var target = try fs.directory().openFile(
        fs.io,
        fixture.storage.target_path,
        .{ .mode = .read_write },
    );
    defer target.close(fs.io);
    try target.setLength(fs.io, 4 * 1024 * 1024 * 1024);
    try target.setPermissions(fs.io, .fromMode(0o000));
    defer target.setPermissions(fs.io, .fromMode(0o600)) catch |err| {
        std.debug.panic("fixture permissions: {t}", .{err});
    };
    const parsed = try parseTransactionRecord(fs, allocator, fixture.record_path);
    defer parsed.deinit(allocator);
    const stage = try std.fs.path.join(
        allocator,
        &.{ fixture.transaction_dir, parsed.writes[0].staged_ref },
    );
    defer allocator.free(stage);
    try fs.directory().deleteFile(fs.io, stage);
    try fs.directory().symLink(fs.io, fixture.storage.target_path, stage, .{});
    const selected = try std.fs.path.join(allocator, &.{ fixture.storage.root, "unrelated.jsonl" });
    defer allocator.free(selected);
    try fixture.coordinate(&.{selected});
    var snapshot = try fixture.snapshot(&.{selected}, .{});
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), snapshot.transactions.len);
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), (try target.stat(fs.io)).size);
}

test "transaction dependency snapshot bounds inventory reads dependencies and custody" {
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    const limits = [_]TransactionDependencyLimits{
        .{ .root_entries = 0 },
        .{ .journals = 0 },
        .{ .journal_bytes = 0 },
        .{ .dependencies = 5 },
        .{ .locks = 2 },
        .{ .identity_checks = 0 },
        .{ .root_entries = std.math.maxInt(usize) },
    };
    for (limits) |limit| {
        try std.testing.expectError(
            error.TransactionDependencyLimitExceeded,
            fixture.snapshot(&.{fixture.storage.target_path}, limit),
        );
    }
    var snapshot = try fixture.snapshot(&.{fixture.storage.target_path}, .{});
    defer snapshot.deinit(allocator);
    try std.testing.expect(snapshot.journal_bytes_read > 0);
    try std.testing.expect(snapshot.identity_checks_used > 0);
}

test "transaction dependency snapshot expands transitive journal components" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    const third = try std.fs.path.join(allocator, &.{ fixture.storage.root, "third.jsonl" });
    defer allocator.free(third);
    const id = "dtx-1-00000000000000000000000000000041";
    const directory = try std.fs.path.join(allocator, &.{ fixture.storage.transactions_dir, id });
    defer allocator.free(directory);
    try ensureDirectoryPathNoSymlinks(fs, directory);
    const record = try std.fs.path.join(allocator, &.{ directory, "transaction.json" });
    defer allocator.free(record);
    try writePreparedTwoWriteRecordForTest(
        allocator,
        record,
        id,
        .{ .process_id = 1202, .session_id = "transitive", .executor = "test" },
        fixture.other_path,
        third,
    );
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path, third });
    var snapshot = try fixture.snapshot(&.{fixture.storage.target_path}, .{});
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.transactions.len);
    var third_seen = false;
    for (snapshot.transactions) |transaction| {
        try std.testing.expectEqual(.retained_read_custody, transaction.coordination);
        for (transaction.entries) |dependency| {
            if (std.mem.eql(u8, third, dependency.path)) third_seen = true;
        }
    }
    try std.testing.expect(third_seen);
    try std.testing.expectError(error.LockBusy, acquireCasAdvisoryLock(fs, allocator, third));
}

test "transaction dependency snapshot accepts native committed and compacted stores" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try TransactionAllocationFixture.init();
    defer fixture.deinit();
    var receipt = try commitTextTransaction(
        fs,
        allocator,
        fixture.transactions_dir,
        &.{.{
            .path = fixture.target_path,
            .text = TransactionAllocationFixture.after,
            .content_mode = .raw,
        }},
        .{ .owner = .{
            .process_id = 1203,
            .session_id = "retired-dependencies",
            .executor = "test",
        } },
    );
    defer receipt.deinit(allocator);
    const recovery = try acquireTransactionRecoveryLock(
        fs,
        allocator,
        fixture.transactions_dir,
        null,
    );
    recovery.close(fs.io);
    {
        var snapshot = try snapshotTransactionDependencies(
            fs,
            allocator,
            fixture.transactions_dir,
            &.{fixture.target_path},
            .{},
        );
        defer snapshot.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), snapshot.transactions.len);
        try std.testing.expectEqual(.committed, snapshot.transactions[0].state);
    }
    try recoverAndCompactTransactions(fs, allocator, fixture.transactions_dir);
    var snapshot = try snapshotTransactionDependencies(
        fs,
        allocator,
        fixture.transactions_dir,
        &.{fixture.target_path},
        .{},
    );
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), snapshot.transactions.len);
    try fixture.expectContent(TransactionAllocationFixture.after);
}

const DependencyPinnedProbe = struct {
    var absolute_paths: usize = 0;

    fn rejectAbsolute(path: []const u8) !void {
        if (std.fs.path.isAbsolute(path)) {
            absolute_paths += 1;
            return error.AccessDenied;
        }
    }

    fn openFile(
        context: ?*anyopaque,
        dir: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.OpenFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        try rejectAbsolute(path);
        return std.testing.io.vtable.dirOpenFile(context, dir, path, options);
    }

    fn openDir(
        context: ?*anyopaque,
        dir: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.OpenOptions,
    ) std.Io.Dir.OpenError!std.Io.Dir {
        try rejectAbsolute(path);
        return std.testing.io.vtable.dirOpenDir(context, dir, path, options);
    }

    fn statFile(
        context: ?*anyopaque,
        dir: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.StatFileOptions,
    ) std.Io.Dir.StatFileError!std.Io.File.Stat {
        try rejectAbsolute(path);
        return std.testing.io.vtable.dirStatFile(context, dir, path, options);
    }

    fn realPathFile(
        context: ?*anyopaque,
        dir: std.Io.Dir,
        path: []const u8,
        buffer: []u8,
    ) std.Io.Dir.RealPathFileError!usize {
        try rejectAbsolute(path);
        return std.testing.io.vtable.dirRealPathFile(context, dir, path, buffer);
    }
};

test "pinned dependency view preserves mixed journals across locator replacement" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "source", .default_dir);
    var source = try tmp.dir.openDir(io, "source", .{});
    defer source.close(io);
    const origin = try source.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(origin);
    const transactions = try std.fs.path.join(allocator, &.{ origin, "transactions" });
    defer allocator.free(transactions);
    const target = try std.fs.path.join(allocator, &.{ origin, "target" });
    defer allocator.free(target);
    const fs = Fs.init(io, std.Io.Dir.cwd());
    var absolute = try commitTextTransaction(fs, allocator, transactions, &.{.{
        .path = target,
        .text = "original absolute bytes",
        .content_mode = .raw,
    }}, .{ .owner = .{ .process_id = 1204, .session_id = "absolute-source", .executor = "test" } });
    defer absolute.deinit(allocator);
    const pinned = Fs.anchored(io, source);
    var relative = try commitTextTransaction(pinned, allocator, "././transactions", &.{.{
        .path = "././.bindings/other",
        .text = "original relative bytes",
        .content_mode = .raw,
    }}, .{ .owner = .{ .process_id = 1205, .session_id = "relative-source", .executor = "test" } });
    defer relative.deinit(allocator);
    const recovery = try acquireTransactionRecoveryLock(
        pinned,
        allocator,
        "././transactions",
        null,
    );
    recovery.close(io);
    const absolute_record = try std.fs.path.join(
        allocator,
        &.{ "transactions", absolute.transaction_id, "transaction.json" },
    );
    defer allocator.free(absolute_record);
    const original_bytes = try readRegularFileNoSymlink(
        pinned,
        allocator,
        absolute_record,
        transaction_record_max_bytes,
    );
    defer allocator.free(original_bytes);
    try tmp.dir.rename("source", tmp.dir, "original", io);
    try tmp.dir.createDir(io, "source", .default_dir);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "source/target", .data = "replacement must never be read" },
    );
    try expectPinnedDependencyView(
        pinned,
        origin,
        absolute.transaction_id,
        absolute_record,
        original_bytes,
    );
}

fn expectPinnedDependencyView(
    pinned: Fs,
    origin: []const u8,
    absolute_id: []const u8,
    absolute_record: []const u8,
    original_bytes: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const io = pinned.io;
    var vtable = io.vtable.*;
    vtable.dirOpenFile = DependencyPinnedProbe.openFile;
    vtable.dirOpenDir = DependencyPinnedProbe.openDir;
    vtable.dirStatFile = DependencyPinnedProbe.statFile;
    vtable.dirRealPathFile = DependencyPinnedProbe.realPathFile;
    const observed_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    DependencyPinnedProbe.absolute_paths = 0;
    const observed = Fs.anchored(observed_io, pinned.directory());
    var snapshot = try snapshotTransactionDependenciesAt(
        observed,
        allocator,
        "././transactions",
        &.{ "././target", "././.bindings/other" },
        .{ .recorded_control_root = origin },
        .{},
    );
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.transactions.len);
    try std.testing.expectEqualStrings(origin, snapshot.recorded_control_root.?);
    for (snapshot.transactions) |transaction| {
        for (transaction.entries) |dependency| {
            try std.testing.expect(!std.fs.path.isAbsolute(dependency.path));
            if (!dependency.present) continue;
            const bytes = try readRegularFileNoSymlink(
                observed,
                allocator,
                dependency.path,
                transaction_record_max_bytes,
            );
            defer allocator.free(bytes);
            if (dependency.kind == .journal and
                std.mem.eql(u8, transaction.transaction_id, absolute_id))
            {
                try std.testing.expectEqualStrings(original_bytes, bytes);
                try std.testing.expect(std.mem.indexOf(u8, bytes, origin) != null);
            }
            if (std.mem.eql(u8, dependency.path, "././target")) {
                try std.testing.expectEqualStrings("original absolute bytes", bytes);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), DependencyPinnedProbe.absolute_paths);
    const after = try readRegularFileNoSymlink(
        pinned,
        allocator,
        absolute_record,
        transaction_record_max_bytes,
    );
    defer allocator.free(after);
    try std.testing.expectEqualStrings(original_bytes, after);
}

test "pinned dependency view rejects foreign roots and lexical escapes before access" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    var source = try fs.directory().openDir(fs.io, fixture.storage.root, .{});
    defer source.close(fs.io);
    const pinned = Fs.anchored(fs.io, source);
    try std.testing.expectError(
        error.TransactionPathOutsideControlRoot,
        snapshotTransactionDependenciesAt(
            pinned,
            allocator,
            "././transactions",
            &.{fixture.storage.target_path},
            .{ .recorded_control_root = fixture.storage.root },
            .{},
        ),
    );
    try std.testing.expectError(
        error.TransactionPathOutsideControlRoot,
        snapshotTransactionDependenciesAt(
            pinned,
            allocator,
            "././transactions",
            &.{"././target.jsonl"},
            .{ .recorded_control_root = "/different-origin" },
            .{},
        ),
    );
    var parsed = try parseTransactionRecord(fs, allocator, fixture.record_path);
    defer parsed.deinit(allocator);
    const original_expected = parsed.expected[0].path;
    const original_write = parsed.writes[0].path;
    const escaped = try allocator.print("{s}/../escaped", .{fixture.storage.root});
    defer allocator.free(escaped);
    parsed.expected[0].path = escaped;
    parsed.writes[0].path = escaped;
    defer parsed.expected[0].path = original_expected;
    defer parsed.writes[0].path = original_write;
    try fixture.replaceRecord(parsed);
    try std.testing.expectError(
        error.TransactionPathOutsideControlRoot,
        snapshotTransactionDependenciesAt(
            pinned,
            allocator,
            "././transactions",
            &.{"././target.jsonl"},
            .{ .recorded_control_root = fixture.storage.root },
            .{},
        ),
    );
}

test "dependency snapshot preserves missing coordination and recordless journals" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    try std.testing.expectError(
        error.TransactionDependencyCoordinationUnavailable,
        fixture.snapshot(&.{fixture.storage.target_path}, .{}),
    );
    const recovery = try std.fs.path.join(
        allocator,
        &.{ fixture.storage.transactions_dir, ".recovery.advisory" },
    );
    defer allocator.free(recovery);
    try std.testing.expectEqual(
        @as(?std.Io.File.Stat, null),
        try statRegularFileNoSymlink(fs, recovery),
    );
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    try fs.directory().deleteFile(fs.io, fixture.record_path);
    try std.testing.expectError(
        error.TransactionDependencyIncomplete,
        fixture.snapshot(&.{fixture.storage.target_path}, .{}),
    );
    try std.testing.expectEqual(
        @as(?std.Io.File.Stat, null),
        try statRegularFileNoSymlink(fs, fixture.record_path),
    );
}

test "transaction dependency snapshot requires explicit legacy recovery authority" {
    var fixture = try DependencyFixture.init(.legacy);
    defer fixture.deinit();
    try fixture.coordinate(&.{ fixture.storage.target_path, fixture.other_path });
    try std.testing.expectError(
        error.TransactionDependencyLegacyAuthorityRequired,
        fixture.snapshot(&.{fixture.storage.target_path}, .{}),
    );
}

test "native dependency coordination initializes fresh roots and observes idempotence" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try TransactionAllocationFixture.init();
    defer fixture.deinit();
    var mutated = false;
    try ensureTransactionDependencyCoordination(fs, allocator, fixture.transactions_dir, &mutated);
    try std.testing.expect(mutated);
    mutated = false;
    try ensureTransactionDependencyCoordination(fs, allocator, fixture.transactions_dir, &mutated);
    try std.testing.expect(!mutated);
    var snapshot = try snapshotTransactionDependencies(
        fs,
        allocator,
        fixture.transactions_dir,
        &.{},
        .{},
    );
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), snapshot.transactions.len);
    try ensureTransactionDependencyCoordination(fs, allocator, fixture.transactions_dir, &mutated);
    try std.testing.expect(!mutated);
    var concurrent = try snapshotTransactionDependencies(
        fs,
        allocator,
        fixture.transactions_dir,
        &.{},
        .{},
    );
    defer concurrent.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), concurrent.transactions.len);
}

test "exact transaction dependency inspection includes targets without a selection seed" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try TransactionAllocationFixture.init();
    defer fixture.deinit();
    const receipt = try commitTextTransaction(
        fs,
        allocator,
        fixture.transactions_dir,
        &.{.{
            .path = fixture.target_path,
            .text = TransactionAllocationFixture.after,
            .content_mode = .raw,
        }},
        .{ .owner = .{
            .process_id = 1204,
            .session_id = "exact-dependency-inspection",
            .executor = "test",
        } },
    );
    defer receipt.deinit(allocator);
    const unrelated = try std.fs.path.join(allocator, &.{ fixture.root, "unrelated.jsonl" });
    defer allocator.free(unrelated);
    const selected = try enumerateTransactionDependencies(
        fs,
        allocator,
        receipt.transaction_dir,
        &.{unrelated},
    );
    defer selected.deinit(allocator);
    try std.testing.expect(!selected.intersects);
    try std.testing.expectEqual(@as(usize, 0), selected.entries.len);
    const inspected = try inspectTransactionDependencies(fs, allocator, receipt.transaction_dir);
    defer inspected.deinit(allocator);
    try std.testing.expectEqualStrings(receipt.transaction_id, inspected.transaction_id);
    try std.testing.expectEqual(.committed, inspected.state);
    try std.testing.expectEqual(.uncoordinated, inspected.coordination);
    try std.testing.expectEqual(.supplied_transaction_only, inspected.coverage);
    try std.testing.expect(inspected.intersects);
    var target_count: usize = 0;
    for (inspected.entries) |entry| {
        if (entry.kind != .target) continue;
        target_count += 1;
        try std.testing.expectEqualStrings(fixture.target_path, entry.path);
        try std.testing.expect(entry.present);
    }
    try std.testing.expectEqual(@as(usize, 1), target_count);
    try fixture.expectContent(TransactionAllocationFixture.after);
}

test "transaction dependencies preserve whole intersecting transaction in both native formats" {
    const allocator = std.testing.allocator;
    inline for (.{ TransactionRecordFormat.current, TransactionRecordFormat.legacy }) |format| {
        var fixture = try DependencyFixture.init(format);
        defer fixture.deinit();
        const result = try fixture.enumerate(&.{fixture.storage.target_path});
        defer result.deinit(allocator);
        try std.testing.expect(result.intersects);
        try std.testing.expectEqual(format, result.format);
        try std.testing.expectEqual(.uncoordinated, result.coordination);
        try std.testing.expectEqual(.supplied_transaction_only, result.coverage);
        try std.testing.expectEqual(.transaction_directory, result.stage_location);
        try std.testing.expectEqual(@as(usize, 6), result.entries.len);
        try std.testing.expectEqual(.journal, result.entries[0].kind);
        try std.testing.expect(result.entries[0].present);
        try std.testing.expectEqual(.commit_marker, result.entries[1].kind);
        try std.testing.expect(!result.entries[1].present);
        try std.testing.expectEqualStrings(fixture.other_path, result.entries[3].path);
        try std.testing.expect(!result.entries[3].present);
        for (result.entries[4..]) |entry| {
            try std.testing.expectEqual(.staged, entry.kind);
            try std.testing.expect(entry.present);
            try std.testing.expectEqualStrings(
                fixture.transaction_dir,
                std.fs.path.dirname(entry.path).?,
            );
        }
        var dir = try std.Io.Dir.openDirAbsolute(
            std.testing.io,
            fixture.transaction_dir,
            .{ .iterate = true },
        );
        defer dir.close(std.testing.io);
        var iter = dir.iterate();
        var count: usize = 0;
        while (try iter.next(std.testing.io)) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 3), count);
        try fixture.storage.expectContent(TransactionAllocationFixture.before);
    }
}

test "disjoint transaction dependencies do not open huge unreadable targets or unsafe stages" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    var target = try fs.directory().openFile(
        fs.io,
        fixture.storage.target_path,
        .{ .mode = .read_write },
    );
    defer target.close(fs.io);
    try target.setLength(fs.io, 4 * 1024 * 1024 * 1024);
    try target.setPermissions(fs.io, .fromMode(0o000));
    defer target.setPermissions(fs.io, .fromMode(0o600)) catch |err| {
        std.debug.panic("fixture permissions: {t}", .{err});
    };
    const parsed = try parseTransactionRecord(fs, allocator, fixture.record_path);
    defer parsed.deinit(allocator);
    const stage = try std.fs.path.join(
        allocator,
        &.{ fixture.transaction_dir, parsed.writes[0].staged_ref },
    );
    defer allocator.free(stage);
    try fs.directory().deleteFile(fs.io, stage);
    try fs.directory().symLink(fs.io, fixture.storage.target_path, stage, .{});
    const selected = try std.fs.path.join(allocator, &.{ fixture.storage.root, "selected.jsonl" });
    defer allocator.free(selected);
    const result = try fixture.enumerate(&.{selected});
    defer result.deinit(allocator);
    try std.testing.expect(!result.intersects);
    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), (try target.stat(fs.io)).size);
}

test "transaction dependencies reject unsafe intersecting stages and journal ancestors" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.legacy);
    defer fixture.deinit();
    const stage = try std.fs.path.join(allocator, &.{ fixture.transaction_dir, "write-0.staged" });
    defer allocator.free(stage);
    try fs.directory().deleteFile(fs.io, stage);
    try fs.directory().symLink(fs.io, fixture.storage.target_path, stage, .{});
    try std.testing.expectError(
        error.SymlinkComponent,
        fixture.enumerate(&.{fixture.storage.target_path}),
    );
    const alias = try std.fs.path.join(
        allocator,
        &.{ fixture.storage.root, "linked-transactions" },
    );
    defer allocator.free(alias);
    try fs.directory().symLink(
        fs.io,
        fixture.storage.transactions_dir,
        alias,
        .{ .is_directory = true },
    );
    const aliased_transaction = try std.fs.path.join(allocator, &.{ alias, "dtx-1" });
    defer allocator.free(aliased_transaction);
    try std.testing.expectError(error.SymlinkComponent, enumerateTransactionDependencies(
        fs,
        allocator,
        aliased_transaction,
        &.{fixture.storage.target_path},
    ));
}

test "transaction dependencies reject duplicate rows and malformed disjoint native scope" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const allocator = std.testing.allocator;
    var fixture = try DependencyFixture.init(.current);
    defer fixture.deinit();
    var parsed = try parseTransactionRecord(fs, allocator, fixture.record_path);
    defer parsed.deinit(allocator);
    const original = parsed.expected[1].path;
    {
        parsed.expected[1].path = parsed.expected[0].path;
        defer parsed.expected[1].path = original;
        try fixture.replaceRecord(parsed);
    }
    try std.testing.expectError(error.TransactionCorrupt, fixture.enumerate(&.{}));
    const original_stage = parsed.writes[0].staged_ref;
    {
        parsed.writes[0].staged_ref = "../escape";
        defer parsed.writes[0].staged_ref = original_stage;
        try fixture.replaceRecord(parsed);
    }
    try std.testing.expectError(error.TransactionCorrupt, fixture.enumerate(&.{}));
    const original_path = parsed.expected[0].path;
    {
        const original_write = parsed.writes[0].path;
        parsed.expected[0].path = "/outside-control-root.jsonl";
        parsed.writes[0].path = "/outside-control-root.jsonl";
        defer parsed.expected[0].path = original_path;
        defer parsed.writes[0].path = original_write;
        try fixture.replaceRecord(parsed);
    }
    try std.testing.expectError(error.TransactionPathOutsideControlRoot, fixture.enumerate(&.{}));
}

test "CAS receipts allocate before publication across every allocation failure" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkCasPublicationAllocation,
        .{CasAllocationOperation.write},
    );
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkCasPublicationAllocation,
        .{CasAllocationOperation.snapshot},
    );
}

fn checkCasPublicationAllocation(
    allocator: std.mem.Allocator,
    operation: CasAllocationOperation,
) !void {
    var fixture = try TransactionAllocationFixture.init();
    defer fixture.deinit();
    publishCasAllocationCase(allocator, fixture.target_path, operation) catch |err| {
        try fixture.expectUnpublished();
        return err;
    };
    try fixture.expectContent(TransactionAllocationFixture.after);
}

fn publishCasAllocationCase(
    allocator: std.mem.Allocator,
    path: []const u8,
    operation: CasAllocationOperation,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const text = TransactionAllocationFixture.after;
    const expectation: CasExpectation = .{ .expected_sequence = 1, .expected_exists = true };
    switch (operation) {
        .write => {
            var receipt = try writeTextAtomicCas(fs, allocator, path, text, expectation);
            defer receipt.deinit(allocator);
            try assertCasAllocationReceipt(receipt, path);
        },
        .snapshot => {
            var receipt = try commitJsonlSnapshotCas(
                fs,
                allocator,
                path,
                text,
                expectation,
                "alloc-cas",
            );
            defer receipt.deinit(allocator);
            try assertCasAllocationReceipt(receipt, path);
            try std.testing.expectEqualStrings("alloc-cas", receipt.transaction_id.?);
        },
    }
}

fn assertCasAllocationReceipt(receipt: anytype, path: []const u8) !void {
    try std.testing.expectEqualStrings(path, receipt.path);
    try std.testing.expect(receipt.path.ptr != path.ptr);
    try std.testing.expectEqualStrings("written", receipt.result);
    try std.testing.expectEqual(@as(?u64, 1), receipt.sequence_before);
    try std.testing.expectEqual(@as(?u64, 2), receipt.sequence_after);
    const before = try digestBytesAlloc(std.testing.allocator, TransactionAllocationFixture.before);
    defer std.testing.allocator.free(before);
    const after = try digestBytesAlloc(std.testing.allocator, TransactionAllocationFixture.after);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, receipt.digest_before.?);
    try std.testing.expectEqualStrings(after, receipt.digest_after);
}

test "lease and recovery result constructors free partial allocations" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkLeaseResultAllocation,
        .{},
    );
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkRecoveryResultAllocation,
        .{},
    );
}

fn checkLeaseResultAllocation(allocator: std.mem.Allocator) !void {
    var lock = try makeLeaseLockOwned(
        allocator,
        "/repo/a.lock",
        "/repo/a",
        .{ .process_id = 12, .session_id = "lease-session", .executor = "test" },
        10,
        20,
        7,
        "dtx-1",
    );
    defer lock.deinit(allocator);
    try std.testing.expectEqualStrings("dlk-7-10", lock.lock_id);
    try std.testing.expectEqualStrings("/repo/a", lock.resource);
    try std.testing.expectEqualStrings("lease-session", lock.owner.session_id);
    try std.testing.expectEqualStrings("test", lock.owner.executor);
    try std.testing.expectEqualStrings("10", lock.acquired_at);
    try std.testing.expectEqualStrings("20", lock.expires_at);
    try std.testing.expectEqualStrings("dtx-1", lock.transaction_id.?);
    try std.testing.expectEqualStrings("/repo/a.lock", lock.path);
}

fn checkRecoveryResultAllocation(allocator: std.mem.Allocator) !void {
    const status = try makeRecoveryStatus(allocator, "dtx-1", .finish_commit, "staged");
    defer status.deinit(allocator);
    try std.testing.expectEqualStrings("dtx-1", status.transaction_id);
    try std.testing.expectEqualStrings("staged", status.reason);
    try std.testing.expectEqual(.finish_commit, status.decision);
    const receipt = try makeRecoveryReceipt(allocator, "dtx-1", .finish_commit, "committed");
    defer receipt.deinit(allocator);
    try std.testing.expectEqualStrings("dtx-1", receipt.transaction_id);
    try std.testing.expectEqualStrings("committed", receipt.result);
    try std.testing.expectEqual(.finish_commit, receipt.decision);
}

test "checkpoint sequences reject overflow before journal allocation" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    const exhausted = "{\"seq\":9223372036854775807}";
    try std.testing.expectError(
        error.TransactionSequenceMismatch,
        checkpointReceiptAlloc(
            fs,
            std.testing.allocator,
            "transactions",
            exhausted,
            exhausted,
            .{},
        ),
    );
}
