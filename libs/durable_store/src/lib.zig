const std = @import("std");

const Io = std.Io.Threaded.global_single_threaded;

pub const JsonlIssue = struct {
    line: usize,
    message: []const u8,
};

pub const JsonlValidation = struct {
    lines: usize = 0,
    blank_lines: usize = 0,
    first_issue: ?JsonlIssue = null,

    pub fn ok(self: JsonlValidation) bool {
        return self.first_issue == null;
    }
};

pub const DurableStoreError = error{
    LockBusy,
    LockExpired,
    LockOwnerMismatch,
    FencingTokenStale,
    ExpectationMismatch,
    SequenceMismatch,
    DigestMismatch,
    TransactionConflict,
    TransactionRecoveryRequired,
    TransactionCorrupt,
    SymlinkComponent,
    InvalidPath,
    FileTooBig,
    TooManyFiles,
};

pub const Owner = struct {
    process_id: i64,
    session_id: []const u8,
    executor: []const u8,

    pub fn writeJson(self: Owner, writer: anytype) !void {
        try writer.writeAll("{\"process_id\":");
        try writer.print("{d}", .{self.process_id});
        try writer.writeAll(",\"session_id\":");
        try std.json.Stringify.value(self.session_id, .{}, writer);
        try writer.writeAll(",\"executor\":");
        try std.json.Stringify.value(self.executor, .{}, writer);
        try writer.writeAll("}");
    }

    pub fn deinit(self: Owner, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.executor);
    }
};

pub const AcquireOptions = struct {
    owner: Owner,
    timeout_ms: u64 = 0,
    retry_interval_ms: u64 = 25,
    lease_ms: u64 = 5000,
    fencing_counter_path: ?[]const u8 = null,
    reject_symlinks: bool = true,
};

pub const LeaseLock = struct {
    lock_id: []const u8,
    resource: []const u8,
    owner: Owner,
    acquired_at: []const u8,
    expires_at: []const u8,
    fencing_token: u64,
    transaction_id: ?[]const u8 = null,
    path: []const u8,

    pub fn writeJson(self: LeaseLock, writer: anytype) !void {
        try writer.writeAll("{\"lock_version\":\"DLK-v1\",\"lock_id\":");
        try std.json.Stringify.value(self.lock_id, .{}, writer);
        try writer.writeAll(",\"resource\":");
        try std.json.Stringify.value(self.resource, .{}, writer);
        try writer.writeAll(",\"owner\":");
        try self.owner.writeJson(writer);
        try writer.writeAll(",\"acquired_at\":");
        try std.json.Stringify.value(self.acquired_at, .{}, writer);
        try writer.writeAll(",\"expires_at\":");
        try std.json.Stringify.value(self.expires_at, .{}, writer);
        try writer.writeAll(",\"fencing_token\":");
        try writer.print("{d}", .{self.fencing_token});
        try writer.writeAll(",\"transaction_id\":");
        try writeOptionalStringJson(writer, self.transaction_id);
        try writer.writeAll("}");
    }

    pub fn deinit(self: *LeaseLock, allocator: std.mem.Allocator) void {
        allocator.free(self.lock_id);
        allocator.free(self.resource);
        self.owner.deinit(allocator);
        allocator.free(self.acquired_at);
        allocator.free(self.expires_at);
        if (self.transaction_id) |transaction_id| allocator.free(transaction_id);
        allocator.free(self.path);
        self.* = .{
            .lock_id = &.{},
            .resource = &.{},
            .owner = .{ .process_id = 0, .session_id = &.{}, .executor = &.{} },
            .acquired_at = &.{},
            .expires_at = &.{},
            .fencing_token = 0,
            .transaction_id = null,
            .path = &.{},
        };
    }
};

pub const ReclaimReceipt = struct {
    lock_id: []const u8,
    resource: []const u8,
    previous_fencing_token: u64,
    authority_counter: u64,
    result: []const u8,

    pub fn writeJson(self: ReclaimReceipt, writer: anytype) !void {
        try writer.writeAll("{\"reclaim_receipt\":{\"receipt_version\":\"DRC-v1\",\"lock_id\":");
        try std.json.Stringify.value(self.lock_id, .{}, writer);
        try writer.writeAll(",\"resource\":");
        try std.json.Stringify.value(self.resource, .{}, writer);
        try writer.writeAll(",\"previous_fencing_token\":");
        try writer.print("{d}", .{self.previous_fencing_token});
        try writer.writeAll(",\"authority_counter\":");
        try writer.print("{d}", .{self.authority_counter});
        try writer.writeAll(",\"result\":");
        try std.json.Stringify.value(self.result, .{}, writer);
        try writer.writeAll("}}");
    }
};

pub const CasExpectation = struct {
    expected_digest: ?[]const u8 = null,
    expected_sequence: ?u64 = null,
    expected_exists: ?bool = null,
};

pub const CasWriteReceipt = struct {
    path: []const u8,
    digest_before: ?[]const u8,
    digest_after: []const u8,
    sequence_before: ?u64,
    sequence_after: ?u64,
    result: []const u8,

    pub fn writeJson(self: CasWriteReceipt, writer: anytype) !void {
        try writer.writeAll("{\"cas_write_receipt\":{\"path\":");
        try std.json.Stringify.value(self.path, .{}, writer);
        try writer.writeAll(",\"digest_before\":");
        try writeOptionalStringJson(writer, self.digest_before);
        try writer.writeAll(",\"digest_after\":");
        try std.json.Stringify.value(self.digest_after, .{}, writer);
        try writer.writeAll(",\"sequence_before\":");
        try writeOptionalU64Json(writer, self.sequence_before);
        try writer.writeAll(",\"sequence_after\":");
        try writeOptionalU64Json(writer, self.sequence_after);
        try writer.writeAll(",\"result\":");
        try std.json.Stringify.value(self.result, .{}, writer);
        try writer.writeAll("}}");
    }

    pub fn deinit(self: CasWriteReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.digest_before) |digest| allocator.free(digest);
        allocator.free(self.digest_after);
        allocator.free(self.result);
    }
};

pub const TransactionState = enum {
    preparing,
    prepared,
    committing,
    committed,
    aborted,
    recovery_required,

    pub fn asString(self: TransactionState) []const u8 {
        return switch (self) {
            .preparing => "preparing",
            .prepared => "prepared",
            .committing => "committing",
            .committed => "committed",
            .aborted => "aborted",
            .recovery_required => "recovery_required",
        };
    }
};

pub const TransactionExpected = struct {
    path: []const u8,
    digest: []const u8,
    sequence: u64,
};

pub const TransactionWrite = struct {
    path: []const u8,
    staged_ref: []const u8,
    digest_after: []const u8,
    sequence_after: u64,
};

pub const DurableTransaction = struct {
    transaction_id: []const u8,
    owner: Owner,
    state: TransactionState,
    expected: []const TransactionExpected,
    writes: []const TransactionWrite,
    locks: []const LeaseLock,
    created_at: []const u8,
    updated_at: []const u8,

    pub fn writeJson(self: DurableTransaction, writer: anytype) !void {
        try writer.writeAll("{\"transaction_version\":\"DTX-v1\",\"transaction_id\":");
        try std.json.Stringify.value(self.transaction_id, .{}, writer);
        try writer.writeAll(",\"owner\":");
        try self.owner.writeJson(writer);
        try writer.writeAll(",\"state\":");
        try std.json.Stringify.value(self.state.asString(), .{}, writer);
        try writer.writeAll(",\"expected\":[");
        for (self.expected, 0..) |row, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"path\":");
            try std.json.Stringify.value(row.path, .{}, writer);
            try writer.writeAll(",\"digest\":");
            try std.json.Stringify.value(row.digest, .{}, writer);
            try writer.writeAll(",\"sequence\":");
            try writer.print("{d}", .{row.sequence});
            try writer.writeAll("}");
        }
        try writer.writeAll("],\"writes\":[");
        for (self.writes, 0..) |row, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"path\":");
            try std.json.Stringify.value(row.path, .{}, writer);
            try writer.writeAll(",\"staged_ref\":");
            try std.json.Stringify.value(row.staged_ref, .{}, writer);
            try writer.writeAll(",\"digest_after\":");
            try std.json.Stringify.value(row.digest_after, .{}, writer);
            try writer.writeAll(",\"sequence_after\":");
            try writer.print("{d}", .{row.sequence_after});
            try writer.writeAll("}");
        }
        try writer.writeAll("],\"locks\":[");
        for (self.locks, 0..) |lock, index| {
            if (index != 0) try writer.writeByte(',');
            try lock.writeJson(writer);
        }
        try writer.writeAll("],\"created_at\":");
        try std.json.Stringify.value(self.created_at, .{}, writer);
        try writer.writeAll(",\"updated_at\":");
        try std.json.Stringify.value(self.updated_at, .{}, writer);
        try writer.writeAll("}");
    }
};

pub const TransactionMutation = struct {
    path: []const u8,
    text: []const u8,
    expectation: CasExpectation = .{},
};

pub const CommitTransactionReceipt = struct {
    transaction_id: []const u8,
    transaction_dir: []const u8,
    record_path: []const u8,
    commit_marker_path: []const u8,
    state: TransactionState,

    pub fn deinit(self: CommitTransactionReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.transaction_id);
        allocator.free(self.transaction_dir);
        allocator.free(self.record_path);
        allocator.free(self.commit_marker_path);
    }
};

pub const RecoveryDecision = enum {
    finish_commit,
    roll_back_unpublished,
    already_committed,
    manual_recovery_required,
};

pub const RecoveryStatus = struct {
    transaction_id: []const u8,
    decision: RecoveryDecision,
    reason: []const u8,

    pub fn deinit(self: RecoveryStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.transaction_id);
        allocator.free(self.reason);
    }
};

pub const RecoveryReceipt = struct {
    transaction_id: []const u8,
    decision: RecoveryDecision,
    result: []const u8,

    pub fn deinit(self: RecoveryReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.transaction_id);
        allocator.free(self.result);
    }
};

pub const Snapshot = struct {
    path: []const u8,
    data: []const u8,
    digest: []const u8,
    sequence: ?u64,

    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.data);
        allocator.free(self.digest);
    }
};

pub const JsonlSnapshotCommitReceipt = struct {
    path: []const u8,
    sequence_before: ?u64,
    sequence_after: ?u64,
    digest_before: ?[]const u8,
    digest_after: []const u8,
    transaction_id: ?[]const u8,
    result: []const u8,

    pub fn deinit(self: JsonlSnapshotCommitReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.digest_before) |digest| allocator.free(digest);
        allocator.free(self.digest_after);
        if (self.transaction_id) |transaction_id| allocator.free(transaction_id);
        allocator.free(self.result);
    }
};

pub const CreateNewOptions = struct {
    reject_symlinks: bool = true,
    file_mode: ?u32 = 0o600,
    sync: bool = true,
};

pub const JsonlTransactionMode = enum {
    append,
    replace,
};

pub const JsonlTransactionOptions = struct {
    expected_sequence: ?i64 = null,
    sequence_field: []const u8 = "seq",
    operation: []const u8 = "append-checkpoint",
    max_existing_bytes: usize = 1024 * 1024,
    mode: JsonlTransactionMode = .append,
    allow_sequence_reset: bool = false,
};

pub const JsonlTransactionReceipt = struct {
    transaction_id: []u8,
    prepared_path: []u8,
    commit_path: []u8,
    sequence_before: i64,
    sequence_after: i64,

    pub fn deinit(self: JsonlTransactionReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.transaction_id);
        allocator.free(self.prepared_path);
        allocator.free(self.commit_path);
    }
};

fn writeOptionalStringJson(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalU64Json(writer: anytype, value: ?u64) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

pub fn acquireLeaseLock(
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    options: AcquireOptions,
) !LeaseLock {
    if (options.reject_symlinks) try rejectSymlinkComponents(resource_path);

    const lock_path = try lockPathAlloc(allocator, resource_path);
    defer allocator.free(lock_path);
    const counter_path = try fencingCounterPathAlloc(allocator, lock_path, options.fencing_counter_path);
    defer allocator.free(counter_path);

    const started_ms = clockMillis(.awake);
    while (true) {
        const token = try allocateFencingToken(allocator, counter_path);
        const now_ms = clockMillis(.real);
        const expires_ms = std.math.add(u64, now_ms, options.lease_ms) catch return error.TransactionRecoveryRequired;
        const lock = try makeLeaseLockOwned(
            allocator,
            lock_path,
            resource_path,
            options.owner,
            now_ms,
            expires_ms,
            token,
            null,
        );

        const payload = renderLeaseLockAlloc(allocator, lock) catch |err| {
            var cleanup = lock;
            cleanup.deinit(allocator);
            return err;
        };
        defer allocator.free(payload);
        writeTextCreateNew(allocator, lock_path, payload, .{ .reject_symlinks = options.reject_symlinks }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                var cleanup = lock;
                cleanup.deinit(allocator);
                if (options.timeout_ms == 0 or elapsedMillis(started_ms) >= options.timeout_ms) return error.LockBusy;
                const sleep_ms = @min(@max(options.retry_interval_ms, 1), @as(u64, @intCast(std.math.maxInt(i64))));
                std.Io.sleep(Io.io(), .fromMilliseconds(@intCast(sleep_ms)), .awake) catch {};
                continue;
            },
            else => {
                var cleanup = lock;
                cleanup.deinit(allocator);
                return err;
            },
        };
        return lock;
    }
}

pub fn refreshLease(
    allocator: std.mem.Allocator,
    lock: *LeaseLock,
    expected_fencing_token: u64,
    lease_ms: u64,
) !void {
    const current = try readLeaseLock(allocator, lock.path);
    var current_owned = current;
    defer current_owned.deinit(allocator);
    if (current.fencing_token != expected_fencing_token) return error.FencingTokenStale;
    if (!ownersEqual(current.owner, lock.owner)) return error.LockOwnerMismatch;

    const now_ms = clockMillis(.real);
    const expires_ms = std.math.add(u64, now_ms, lease_ms) catch return error.TransactionRecoveryRequired;
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
    try writeTextAtomic(allocator, lock.path, payload);
    lock.deinit(allocator);
    lock.* = refreshed_owned;
}

pub fn releaseLease(
    allocator: std.mem.Allocator,
    lock: *LeaseLock,
    expected_fencing_token: u64,
) !void {
    const current = try readLeaseLock(allocator, lock.path);
    var current_owned = current;
    defer current_owned.deinit(allocator);
    if (current.fencing_token != expected_fencing_token) return error.FencingTokenStale;
    if (!ownersEqual(current.owner, lock.owner)) return error.LockOwnerMismatch;

    if (std.fs.path.isAbsolute(lock.path)) {
        try std.Io.Dir.deleteFileAbsolute(Io.io(), lock.path);
    } else {
        try std.Io.Dir.cwd().deleteFile(Io.io(), lock.path);
    }
    lock.deinit(allocator);
}

pub fn reclaimExpiredLease(
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    options: AcquireOptions,
) !ReclaimReceipt {
    if (options.reject_symlinks) try rejectSymlinkComponents(resource_path);
    const lock_path = try lockPathAlloc(allocator, resource_path);
    defer allocator.free(lock_path);
    const counter_path = try fencingCounterPathAlloc(allocator, lock_path, options.fencing_counter_path);
    defer allocator.free(counter_path);

    const current = try readLeaseLock(allocator, lock_path);
    var current_owned = current;
    defer current_owned.deinit(allocator);
    const expires_ms = try parseU64Text(current.expires_at);
    if (clockMillis(.real) < expires_ms) return error.LockBusy;

    const new_counter = try allocateFencingToken(allocator, counter_path);
    if (current.fencing_token >= new_counter) return error.FencingTokenStale;

    const evidence_path = try std.fmt.allocPrint(
        allocator,
        "{s}.reclaimed-{d}-{d}",
        .{ lock_path, clockMillis(.real), current.fencing_token },
    );
    defer allocator.free(evidence_path);
    if (std.fs.path.isAbsolute(lock_path)) {
        try std.Io.Dir.renameAbsolute(lock_path, evidence_path, Io.io());
    } else {
        try std.Io.Dir.cwd().rename(lock_path, std.Io.Dir.cwd(), evidence_path, Io.io());
    }

    return .{
        .lock_id = try allocator.dupe(u8, current.lock_id),
        .resource = try allocator.dupe(u8, current.resource),
        .previous_fencing_token = current.fencing_token,
        .authority_counter = new_counter,
        .result = try allocator.dupe(u8, "reclaimed"),
    };
}

const ClockKind = enum { awake, real };

fn clockMillis(kind: ClockKind) u64 {
    const now = switch (kind) {
        .awake => std.Io.Clock.awake.now(Io.io()),
        .real => std.Io.Clock.real.now(Io.io()),
    };
    return @as(u64, @intCast(@divFloor(now.nanoseconds, 1_000_000)));
}

fn elapsedMillis(start_ms: u64) u64 {
    const now = clockMillis(.awake);
    if (now <= start_ms) return 0;
    return now - start_ms;
}

fn fencingCounterPathAlloc(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    explicit_counter_path: ?[]const u8,
) ![]u8 {
    if (explicit_counter_path) |path| return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "{s}.counter", .{lock_path});
}

fn allocateFencingToken(allocator: std.mem.Allocator, counter_path: []const u8) !u64 {
    const counter_lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{counter_path});
    defer allocator.free(counter_lock_path);
    var counter_lock = try acquireExclusiveLockPath(allocator, counter_lock_path);
    defer counter_lock.release(allocator);

    const current = try readFencingCounter(allocator, counter_path);
    if (current == std.math.maxInt(u64)) return error.TransactionRecoveryRequired;
    const next = current + 1;
    const payload = try std.fmt.allocPrint(allocator, "{d}\n", .{next});
    defer allocator.free(payload);
    try writeTextAtomic(allocator, counter_path, payload);
    return next;
}

fn readFencingCounter(allocator: std.mem.Allocator, counter_path: []const u8) !u64 {
    const bytes = readRegularFileNoSymlink(allocator, counter_path, 64) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer allocator.free(bytes);
    return parseU64Text(bytes) catch error.TransactionRecoveryRequired;
}

fn parseU64Text(bytes: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return error.TransactionRecoveryRequired;
    return std.fmt.parseUnsigned(u64, trimmed, 10) catch error.TransactionRecoveryRequired;
}

fn makeLeaseLockOwned(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    resource_path: []const u8,
    owner: Owner,
    acquired_ms: u64,
    expires_ms: u64,
    fencing_token: u64,
    transaction_id: ?[]const u8,
) !LeaseLock {
    errdefer {}
    return .{
        .lock_id = try std.fmt.allocPrint(allocator, "dlk-{d}-{d}", .{ fencing_token, acquired_ms }),
        .resource = try allocator.dupe(u8, resource_path),
        .owner = .{
            .process_id = owner.process_id,
            .session_id = try allocator.dupe(u8, owner.session_id),
            .executor = try allocator.dupe(u8, owner.executor),
        },
        .acquired_at = try std.fmt.allocPrint(allocator, "{d}", .{acquired_ms}),
        .expires_at = try std.fmt.allocPrint(allocator, "{d}", .{expires_ms}),
        .fencing_token = fencing_token,
        .transaction_id = if (transaction_id) |value| try allocator.dupe(u8, value) else null,
        .path = try allocator.dupe(u8, lock_path),
    };
}

fn renderLeaseLockAlloc(allocator: std.mem.Allocator, lock: LeaseLock) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try lock.writeJson(&out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn readLeaseLock(allocator: std.mem.Allocator, path: []const u8) !LeaseLock {
    const bytes = try readRegularFileNoSymlink(allocator, path, 4096);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TransactionCorrupt;
    const object = parsed.value.object;
    const version = jsonString(object.get("lock_version") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    if (!std.mem.eql(u8, version, "DLK-v1")) return error.TransactionCorrupt;
    const owner_value = object.get("owner") orelse return error.TransactionCorrupt;
    if (owner_value != .object) return error.TransactionCorrupt;
    const owner_object = owner_value.object;
    const process_id = jsonInteger(owner_object.get("process_id") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    const lock_id = jsonString(object.get("lock_id") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    const resource = jsonString(object.get("resource") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    const session_id = jsonString(owner_object.get("session_id") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    const executor = jsonString(owner_object.get("executor") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    const acquired_at = jsonString(object.get("acquired_at") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    const expires_at = jsonString(object.get("expires_at") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    const fencing_token_raw = jsonInteger(object.get("fencing_token") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    if (fencing_token_raw < 0) return error.TransactionCorrupt;
    const transaction_id = switch (object.get("transaction_id") orelse return error.TransactionCorrupt) {
        .null => null,
        .string => |value| value,
        else => return error.TransactionCorrupt,
    };

    return .{
        .lock_id = try allocator.dupe(u8, lock_id),
        .resource = try allocator.dupe(u8, resource),
        .owner = .{
            .process_id = process_id,
            .session_id = try allocator.dupe(u8, session_id),
            .executor = try allocator.dupe(u8, executor),
        },
        .acquired_at = try allocator.dupe(u8, acquired_at),
        .expires_at = try allocator.dupe(u8, expires_at),
        .fencing_token = @intCast(fencing_token_raw),
        .transaction_id = if (transaction_id) |value| try allocator.dupe(u8, value) else null,
        .path = try allocator.dupe(u8, path),
    };
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonInteger(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn ownersEqual(a: Owner, b: Owner) bool {
    return a.process_id == b.process_id and
        std.mem.eql(u8, a.session_id, b.session_id) and
        std.mem.eql(u8, a.executor, b.executor);
}

const default_snapshot_max_bytes: usize = 1024 * 1024;

pub fn writeTextAtomicCas(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    expectation: CasExpectation,
) !CasWriteReceipt {
    const cas_lock_path = try casLockPathAlloc(allocator, path);
    defer allocator.free(cas_lock_path);
    var cas_lock = try acquireExclusiveLockPathRetry(allocator, cas_lock_path, 5000, 2);
    defer cas_lock.release(allocator);

    const current = readRegularFileNoSymlink(allocator, path, default_snapshot_max_bytes) catch |err| switch (err) {
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

    const sequence_before = if (current) |bytes| try jsonlSequenceOrNull(allocator, bytes) else null;
    if (expectation.expected_sequence) |expected_sequence| {
        const actual = sequence_before orelse return error.SequenceMismatch;
        if (expected_sequence != actual) return error.SequenceMismatch;
    }

    const digest_after = try digestBytesAlloc(allocator, text);
    errdefer allocator.free(digest_after);
    const sequence_after = try jsonlSequenceOrNull(allocator, text);
    try writeTextAtomic(allocator, path, text);
    return .{
        .path = try allocator.dupe(u8, path),
        .digest_before = digest_before,
        .digest_after = digest_after,
        .sequence_before = sequence_before,
        .sequence_after = sequence_after,
        .result = try allocator.dupe(u8, "written"),
    };
}

pub fn readJsonlSnapshot(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_sequence: ?u64,
) !Snapshot {
    const data = try readRegularFileNoSymlink(allocator, path, default_snapshot_max_bytes);
    errdefer allocator.free(data);
    const validation = validateJsonlBytes(allocator, data);
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

pub fn commitJsonlSnapshotCas(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    expectation: CasExpectation,
    transaction_id: ?[]const u8,
) !JsonlSnapshotCommitReceipt {
    const validation = validateJsonlBytes(allocator, text);
    if (!validation.ok()) return error.InvalidJsonl;
    var receipt = try writeTextAtomicCas(allocator, path, text, expectation);
    defer receipt.deinit(allocator);
    return .{
        .path = try allocator.dupe(u8, receipt.path),
        .sequence_before = receipt.sequence_before,
        .sequence_after = receipt.sequence_after,
        .digest_before = if (receipt.digest_before) |digest| try allocator.dupe(u8, digest) else null,
        .digest_after = try allocator.dupe(u8, receipt.digest_after),
        .transaction_id = if (transaction_id) |id| try allocator.dupe(u8, id) else null,
        .result = try allocator.dupe(u8, receipt.result),
    };
}

pub fn commitTextTransaction(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    mutations: []const TransactionMutation,
    options: AcquireOptions,
) !CommitTransactionReceipt {
    if (mutations.len == 0) return error.InvalidPath;
    try ensureDirectoryPathNoSymlinks(transactions_dir);

    const ordered = try normalizeTransactionMutations(allocator, mutations, options.reject_symlinks);
    defer allocator.free(ordered);

    const transaction_id = try std.fmt.allocPrint(allocator, "dtx-{d}", .{clockMillis(.real)});
    errdefer allocator.free(transaction_id);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    errdefer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    errdefer allocator.free(record_path);
    const commit_marker_path = try std.fs.path.join(allocator, &.{ transaction_dir, "commit.json" });
    errdefer allocator.free(commit_marker_path);

    var locks = try allocator.alloc(LeaseLock, ordered.len);
    var lock_count: usize = 0;
    defer {
        var index: usize = 0;
        while (index < lock_count) : (index += 1) {
            releaseLease(allocator, &locks[index], locks[index].fencing_token) catch locks[index].deinit(allocator);
        }
        allocator.free(locks);
    }
    for (ordered) |mutation| {
        locks[lock_count] = try acquireLeaseLock(allocator, mutation.path, .{
            .owner = options.owner,
            .lease_ms = options.lease_ms,
            .fencing_counter_path = options.fencing_counter_path,
            .reject_symlinks = options.reject_symlinks,
        });
        lock_count += 1;
    }

    const now_ms = clockMillis(.real);
    var expected = try allocator.alloc(TransactionExpected, ordered.len);
    var expected_count: usize = 0;
    defer {
        freeTransactionExpectedRows(allocator, expected[0..expected_count]);
        allocator.free(expected);
    }
    var writes = try allocator.alloc(TransactionWrite, ordered.len);
    var write_count: usize = 0;
    defer {
        freeTransactionWriteRows(allocator, writes[0..write_count]);
        allocator.free(writes);
    }

    for (ordered, 0..) |mutation, index| {
        const maybe_before = readJsonlSnapshot(allocator, mutation.path, mutation.expectation.expected_sequence) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (maybe_before) |*before| before.deinit(allocator);
        if (maybe_before) |before| {
            if (mutation.expectation.expected_digest) |digest| {
                if (!std.mem.eql(u8, digest, before.digest)) return error.DigestMismatch;
            }
            if (mutation.expectation.expected_exists) |expected_exists| {
                if (!expected_exists) return error.ExpectationMismatch;
            }
            expected[expected_count] = .{
                .path = try allocator.dupe(u8, mutation.path),
                .digest = try allocator.dupe(u8, before.digest),
                .sequence = before.sequence orelse return error.SequenceMismatch,
            };
        } else {
            if (mutation.expectation.expected_exists) |expected_exists| {
                if (expected_exists) return error.ExpectationMismatch;
            }
            if (mutation.expectation.expected_digest != null) return error.DigestMismatch;
            if (mutation.expectation.expected_sequence) |sequence| {
                if (sequence != 0) return error.SequenceMismatch;
            }
            expected[expected_count] = .{
                .path = try allocator.dupe(u8, mutation.path),
                .digest = try allocator.dupe(u8, ""),
                .sequence = 0,
            };
        }
        expected_count += 1;

        const validation = validateJsonlBytes(allocator, mutation.text);
        if (!validation.ok()) return error.InvalidJsonl;
        const staged_name = try std.fmt.allocPrint(allocator, "write-{d}.staged", .{index});
        defer allocator.free(staged_name);
        const staged_path = try std.fs.path.join(allocator, &.{ transaction_dir, staged_name });
        defer allocator.free(staged_path);
        try writeTextCreateNew(allocator, staged_path, mutation.text, .{});
        const digest_after = try digestBytesAlloc(allocator, mutation.text);
        errdefer allocator.free(digest_after);
        const sequence_after = (try jsonlSequenceRequired(allocator, mutation.text)) orelse return error.SequenceMismatch;
        writes[write_count] = .{
            .path = try allocator.dupe(u8, mutation.path),
            .staged_ref = try allocator.dupe(u8, staged_name),
            .digest_after = digest_after,
            .sequence_after = sequence_after,
        };
        write_count += 1;
    }

    try writeTransactionRecord(allocator, record_path, transaction_id, options.owner, .prepared, expected[0..expected_count], writes[0..write_count], locks[0..lock_count], now_ms, clockMillis(.real), true);

    for (ordered) |mutation| {
        var receipt = try writeTextAtomicCas(allocator, mutation.path, mutation.text, mutation.expectation);
        receipt.deinit(allocator);
    }

    try writeTransactionRecord(allocator, record_path, transaction_id, options.owner, .committed, expected[0..expected_count], writes[0..write_count], locks[0..lock_count], now_ms, clockMillis(.real), false);
    try writeTextCreateNew(allocator, commit_marker_path, "{\"commit_marker\":\"DTX-v1\",\"state\":\"committed\"}\n", .{});

    return .{
        .transaction_id = transaction_id,
        .transaction_dir = transaction_dir,
        .record_path = record_path,
        .commit_marker_path = commit_marker_path,
        .state = .committed,
    };
}

pub fn inspectTransaction(allocator: std.mem.Allocator, transaction_dir: []const u8) !RecoveryStatus {
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const commit_marker_path = try std.fs.path.join(allocator, &.{ transaction_dir, "commit.json" });
    defer allocator.free(commit_marker_path);
    const parsed = try parseTransactionRecord(allocator, record_path);
    defer parsed.deinit(allocator);
    if (parsed.state == .committed and fileExists(commit_marker_path)) {
        return makeRecoveryStatus(allocator, parsed.transaction_id, .already_committed, "commit-marker-present");
    }
    if (parsed.state == .aborted) {
        return makeRecoveryStatus(allocator, parsed.transaction_id, .roll_back_unpublished, "already-aborted");
    }
    const published = (try transactionPublishedCount(allocator, parsed.writes, parsed.expected)) orelse
        return makeRecoveryStatus(allocator, parsed.transaction_id, .manual_recovery_required, "published-digest-disagreement");
    if (published == parsed.writes.len) {
        return makeRecoveryStatus(allocator, parsed.transaction_id, .finish_commit, "all-digests-published");
    }
    if (published == 0) {
        return makeRecoveryStatus(allocator, parsed.transaction_id, .roll_back_unpublished, "no-digests-published");
    }
    return makeRecoveryStatus(allocator, parsed.transaction_id, .manual_recovery_required, "mixed-published-digests");
}

pub fn recoverTransaction(allocator: std.mem.Allocator, transaction_dir: []const u8) !RecoveryReceipt {
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const commit_marker_path = try std.fs.path.join(allocator, &.{ transaction_dir, "commit.json" });
    defer allocator.free(commit_marker_path);
    var parsed = try parseTransactionRecord(allocator, record_path);
    defer parsed.deinit(allocator);
    const status = try inspectTransaction(allocator, transaction_dir);
    defer status.deinit(allocator);
    switch (status.decision) {
        .already_committed => return makeRecoveryReceipt(allocator, parsed.transaction_id, .already_committed, "already_committed"),
        .finish_commit => {
            const record = try renderParsedTransactionRecordAlloc(allocator, parsed, .committed);
            defer allocator.free(record);
            try writeTextAtomic(allocator, record_path, record);
            writeTextCreateNew(allocator, commit_marker_path, "{\"commit_marker\":\"DTX-v1\",\"state\":\"committed\"}\n", .{}) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            return makeRecoveryReceipt(allocator, parsed.transaction_id, .finish_commit, "committed");
        },
        .roll_back_unpublished => {
            const record = try renderParsedTransactionRecordAlloc(allocator, parsed, .aborted);
            defer allocator.free(record);
            try writeTextAtomic(allocator, record_path, record);
            return makeRecoveryReceipt(allocator, parsed.transaction_id, .roll_back_unpublished, "aborted");
        },
        .manual_recovery_required => return error.TransactionRecoveryRequired,
    }
}

fn makeRecoveryStatus(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    decision: RecoveryDecision,
    reason: []const u8,
) !RecoveryStatus {
    return .{
        .transaction_id = try allocator.dupe(u8, transaction_id),
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
    return .{
        .transaction_id = try allocator.dupe(u8, transaction_id),
        .decision = decision,
        .result = try allocator.dupe(u8, result),
    };
}

fn normalizeTransactionMutations(
    allocator: std.mem.Allocator,
    mutations: []const TransactionMutation,
    reject_symlinks: bool,
) ![]TransactionMutation {
    var ordered = try allocator.alloc(TransactionMutation, mutations.len);
    errdefer allocator.free(ordered);
    for (mutations, 0..) |mutation, index| {
        try rejectTransactionPath(mutation.path, reject_symlinks);
        ordered[index] = mutation;
    }
    std.mem.sort(TransactionMutation, ordered, {}, struct {
        fn lessThan(_: void, a: TransactionMutation, b: TransactionMutation) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    for (ordered[1..], 1..) |mutation, index| {
        if (std.mem.eql(u8, ordered[index - 1].path, mutation.path)) return error.InvalidPath;
    }
    return ordered;
}

fn rejectTransactionPath(path: []const u8, reject_symlinks: bool) !void {
    const base = std.fs.path.basename(path);
    if (path.len == 0 or base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.InvalidPath;
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return error.InvalidPath;
    }
    if (reject_symlinks) try rejectSymlinkComponents(path);
}

fn writeTransactionRecord(
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
    const created_at = try std.fmt.allocPrint(allocator, "{d}", .{created_ms});
    defer allocator.free(created_at);
    const updated_at = try std.fmt.allocPrint(allocator, "{d}", .{updated_ms});
    defer allocator.free(updated_at);
    const transaction: DurableTransaction = .{
        .transaction_id = transaction_id,
        .owner = owner,
        .state = state,
        .expected = expected,
        .writes = writes,
        .locks = locks,
        .created_at = created_at,
        .updated_at = updated_at,
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try transaction.writeJson(&out.writer);
    try out.writer.writeByte('\n');
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    if (create_new) {
        try writeTextCreateNew(allocator, record_path, bytes, .{});
    } else {
        try writeTextAtomic(allocator, record_path, bytes);
    }
}

fn freeTransactionExpectedRows(allocator: std.mem.Allocator, expected: []TransactionExpected) void {
    for (expected) |row| {
        allocator.free(row.path);
        allocator.free(row.digest);
    }
}

fn freeTransactionWriteRows(allocator: std.mem.Allocator, writes: []TransactionWrite) void {
    for (writes) |row| {
        allocator.free(row.path);
        allocator.free(row.staged_ref);
        allocator.free(row.digest_after);
    }
}

const ParsedTransactionRecord = struct {
    transaction_id: []const u8,
    owner: Owner,
    state: TransactionState,
    expected: []TransactionExpected,
    writes: []TransactionWrite,
    created_at: []const u8,
    updated_at: []const u8,

    fn deinit(self: ParsedTransactionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.transaction_id);
        self.owner.deinit(allocator);
        freeTransactionExpectedRows(allocator, self.expected);
        allocator.free(self.expected);
        freeTransactionWriteRows(allocator, self.writes);
        allocator.free(self.writes);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};

fn parseTransactionRecord(allocator: std.mem.Allocator, record_path: []const u8) !ParsedTransactionRecord {
    const bytes = try readRegularFileNoSymlink(allocator, record_path, default_snapshot_max_bytes);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TransactionCorrupt;
    const object = parsed.value.object;
    const version = jsonString(object.get("transaction_version") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    if (!std.mem.eql(u8, version, "DTX-v1")) return error.TransactionCorrupt;
    const transaction_id = jsonString(object.get("transaction_id") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    const state_text = jsonString(object.get("state") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
    const owner_value = object.get("owner") orelse return error.TransactionCorrupt;
    if (owner_value != .object) return error.TransactionCorrupt;
    const owner_object = owner_value.object;
    const expected_value = object.get("expected") orelse return error.TransactionCorrupt;
    const writes_value = object.get("writes") orelse return error.TransactionCorrupt;
    if (expected_value != .array or writes_value != .array) return error.TransactionCorrupt;

    return .{
        .transaction_id = try allocator.dupe(u8, transaction_id),
        .owner = .{
            .process_id = jsonInteger(owner_object.get("process_id") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt,
            .session_id = try allocator.dupe(u8, jsonString(owner_object.get("session_id") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
            .executor = try allocator.dupe(u8, jsonString(owner_object.get("executor") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
        },
        .state = parseTransactionState(state_text) orelse return error.TransactionCorrupt,
        .expected = try parseTransactionExpectedArray(allocator, expected_value.array.items),
        .writes = try parseTransactionWriteArray(allocator, writes_value.array.items),
        .created_at = try allocator.dupe(u8, jsonString(object.get("created_at") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
        .updated_at = try allocator.dupe(u8, jsonString(object.get("updated_at") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
    };
}

fn parseTransactionState(text: []const u8) ?TransactionState {
    inline for (.{ .preparing, .prepared, .committing, .committed, .aborted, .recovery_required }) |state| {
        const typed_state: TransactionState = state;
        if (std.mem.eql(u8, text, typed_state.asString())) return typed_state;
    }
    return null;
}

fn parseTransactionExpectedArray(allocator: std.mem.Allocator, values: []std.json.Value) ![]TransactionExpected {
    var rows = try allocator.alloc(TransactionExpected, values.len);
    var count: usize = 0;
    errdefer {
        freeTransactionExpectedRows(allocator, rows[0..count]);
        allocator.free(rows);
    }
    for (values) |value| {
        if (value != .object) return error.TransactionCorrupt;
        const object = value.object;
        const sequence = jsonInteger(object.get("sequence") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
        if (sequence < 0) return error.TransactionCorrupt;
        rows[count] = .{
            .path = try allocator.dupe(u8, jsonString(object.get("path") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
            .digest = try allocator.dupe(u8, jsonString(object.get("digest") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
            .sequence = @intCast(sequence),
        };
        count += 1;
    }
    return rows;
}

fn parseTransactionWriteArray(allocator: std.mem.Allocator, values: []std.json.Value) ![]TransactionWrite {
    var rows = try allocator.alloc(TransactionWrite, values.len);
    var count: usize = 0;
    errdefer {
        freeTransactionWriteRows(allocator, rows[0..count]);
        allocator.free(rows);
    }
    for (values) |value| {
        if (value != .object) return error.TransactionCorrupt;
        const object = value.object;
        const sequence = jsonInteger(object.get("sequence_after") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt;
        if (sequence < 0) return error.TransactionCorrupt;
        rows[count] = .{
            .path = try allocator.dupe(u8, jsonString(object.get("path") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
            .staged_ref = try allocator.dupe(u8, jsonString(object.get("staged_ref") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
            .digest_after = try allocator.dupe(u8, jsonString(object.get("digest_after") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
            .sequence_after = @intCast(sequence),
        };
        count += 1;
    }
    return rows;
}

fn transactionPublishedCount(
    allocator: std.mem.Allocator,
    writes: []const TransactionWrite,
    expected: []const TransactionExpected,
) !?usize {
    var published: usize = 0;
    for (writes) |write| {
        const bytes = readRegularFileNoSymlink(allocator, write.path, default_snapshot_max_bytes) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(bytes);
        const digest = try digestBytesAlloc(allocator, bytes);
        defer allocator.free(digest);
        if (std.mem.eql(u8, digest, write.digest_after)) {
            published += 1;
        } else if (!digestMatchesExpectedBefore(write.path, digest, expected)) {
            return null;
        }
    }
    return published;
}

fn digestMatchesExpectedBefore(path: []const u8, digest: []const u8, expected: []const TransactionExpected) bool {
    for (expected) |row| {
        if (std.mem.eql(u8, row.path, path) and std.mem.eql(u8, row.digest, digest)) return true;
    }
    return false;
}

fn renderParsedTransactionRecordAlloc(
    allocator: std.mem.Allocator,
    parsed: ParsedTransactionRecord,
    state: TransactionState,
) ![]u8 {
    const transaction: DurableTransaction = .{
        .transaction_id = parsed.transaction_id,
        .owner = parsed.owner,
        .state = state,
        .expected = parsed.expected,
        .writes = parsed.writes,
        .locks = &.{},
        .created_at = parsed.created_at,
        .updated_at = parsed.updated_at,
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try transaction.writeJson(&out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
}

fn jsonlSequenceOrNull(allocator: std.mem.Allocator, bytes: []const u8) !?u64 {
    const validation = validateJsonlBytes(allocator, bytes);
    if (!validation.ok()) return null;
    return jsonlSequenceRequired(allocator, bytes);
}

fn jsonlSequenceRequired(allocator: std.mem.Allocator, bytes: []const u8) !?u64 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    const fields = [_][]const u8{ "seq", "workspace_sequence", "plan_sequence" };
    for (fields) |field| {
        const sequence = lastJsonlSequence(allocator, bytes, field) catch |err| switch (err) {
            error.InvalidCheckpoint => continue,
            else => return err,
        };
        if (sequence < 0) return error.SequenceMismatch;
        return @intCast(sequence);
    }
    return null;
}

pub fn lockPathAlloc(allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.lock", .{store_path});
}

fn casLockPathAlloc(allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.cas.lock", .{store_path});
}

pub fn fileExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(Io.io(), path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(Io.io(), path, .{}) catch return false;
    return true;
}

pub fn fileSize(path: []const u8) !u64 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(Io.io(), path, .{})
    else
        try std.Io.Dir.cwd().openFile(Io.io(), path, .{});
    defer file.close(Io.io());

    const stat = try file.stat(Io.io());
    return stat.size;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(Io.io(), path, .{})
    else
        try std.Io.Dir.cwd().openFile(Io.io(), path, .{});
    defer file.close(Io.io());

    var reader = file.reader(Io.io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

pub fn ensureParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;

    if (std.fs.path.isAbsolute(parent)) {
        const rel = std.mem.trim(u8, parent, "/");
        if (rel.len == 0) return;
        var root = try std.Io.Dir.openDirAbsolute(Io.io(), "/", .{});
        defer root.close(Io.io());
        try root.createDirPath(Io.io(), rel);
        return;
    }

    try std.Io.Dir.cwd().createDirPath(Io.io(), parent);
}

pub fn rejectSymlinkComponents(path: []const u8) !void {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        const stat = std.Io.Dir.cwd().statFile(Io.io(), component.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
    }
}

pub fn ensureDirectoryPathNoSymlinks(path: []const u8) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return;

    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        const stat = std.Io.Dir.cwd().statFile(Io.io(), component.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.Dir.cwd().createDirPath(Io.io(), component.path);
                const created_stat = try std.Io.Dir.cwd().statFile(Io.io(), component.path, .{ .follow_symlinks = false });
                if (created_stat.kind == .sym_link) return error.SymlinkComponent;
                if (created_stat.kind != .directory) return error.NotDir;
                continue;
            },
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .directory) return error.NotDir;
    }
}

pub fn readRegularFileNoSymlink(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const stat = try std.Io.Dir.cwd().statFile(Io.io(), path, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > max_bytes) return error.FileTooBig;

    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(Io.io(), path, .{ .allow_directory = false, .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openFile(Io.io(), path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(Io.io());

    var reader = file.reader(Io.io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes + 1));
}

pub fn freeStringList(allocator: std.mem.Allocator, list: []const []u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

pub fn listSortedRegularFilesNoSymlink(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    max_files: usize,
    max_file_bytes: usize,
) ![][]u8 {
    const dir_stat = try std.Io.Dir.cwd().statFile(Io.io(), dir_path, .{ .follow_symlinks = false });
    if (dir_stat.kind == .sym_link) return error.SymlinkComponent;
    if (dir_stat.kind != .directory) return error.NotDir;

    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.Io.Dir.openDirAbsolute(Io.io(), dir_path, .{ .iterate = true, .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), dir_path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(Io.io());

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(Io.io())) |entry| {
        if (entry.kind == .sym_link) return error.SymlinkComponent;
        if (entry.kind != .file) continue;
        if (names.items.len >= max_files) return error.TooManyFiles;

        const entry_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(entry_path);
        const stat = try std.Io.Dir.cwd().statFile(Io.io(), entry_path, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) continue;
        if (stat.size > max_file_bytes) return error.FileTooBig;

        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.toOwnedSlice(allocator);
}

fn filePermissionsFromMode(mode: ?u32) std.Io.File.Permissions {
    const Permissions = std.Io.File.Permissions;
    const requested = mode orelse return .default_file;
    if (@hasDecl(Permissions, "fromMode")) {
        return Permissions.fromMode(@as(std.posix.mode_t, @intCast(requested)));
    }
    return .default_file;
}

pub fn writeTextCreateNew(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    options: CreateNewOptions,
) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (parent.len == 0 or base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return error.InvalidPath;
    }
    if (options.reject_symlinks) {
        try ensureDirectoryPathNoSymlinks(parent);
        const existing_stat = std.Io.Dir.cwd().statFile(Io.io(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing_stat) |stat| {
            if (stat.kind == .sym_link) return error.SymlinkComponent;
        }
    } else {
        try ensureParentPath(path);
    }

    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(Io.io(), parent, .{ .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), parent, .{ .follow_symlinks = false });
    defer dir.close(Io.io());

    var file = try dir.createFile(Io.io(), base, .{
        .exclusive = true,
        .read = true,
        .truncate = false,
        .permissions = filePermissionsFromMode(options.file_mode),
    });
    var close_file = true;
    errdefer {
        if (close_file) file.close(Io.io());
        dir.deleteFile(Io.io(), base) catch {};
    }
    try file.writeStreamingAll(Io.io(), text);
    if (options.sync) try file.sync(Io.io());
    file.close(Io.io());
    close_file = false;
    _ = allocator;
}

pub fn writeTextAtomic(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse ".";
    try ensureDirectoryPathNoSymlinks(parent);
    const tmp_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.{d}.tmp",
        .{ base, std.Io.Clock.awake.now(Io.io()).nanoseconds },
    );
    defer allocator.free(tmp_name);

    if (std.fs.path.isAbsolute(path)) {
        var dir = try std.Io.Dir.openDirAbsolute(Io.io(), parent, .{});
        defer dir.close(Io.io());
        try writeTempAndRename(&dir, tmp_name, base, text);
        return;
    }

    var dir = try std.Io.Dir.cwd().openDir(Io.io(), parent, .{});
    defer dir.close(Io.io());
    try writeTempAndRename(&dir, tmp_name, base, text);
}

fn writeTempAndRename(dir: *std.Io.Dir, tmp_name: []const u8, base: []const u8, text: []const u8) !void {
    var file = try dir.createFile(Io.io(), tmp_name, .{ .truncate = true, .read = true });
    var close_file = true;
    errdefer if (close_file) file.close(Io.io());
    try file.writeStreamingAll(Io.io(), text);
    try file.sync(Io.io());
    file.close(Io.io());
    close_file = false;
    errdefer dir.deleteFile(Io.io(), tmp_name) catch {};
    try dir.rename(tmp_name, dir.*, base, Io.io());
}

pub fn appendLineAtomic(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    max_existing_bytes: usize,
) !void {
    const existing = readFileAlloc(allocator, path, max_existing_bytes) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const owns_existing = existing.len > 0 or fileExists(path);
    defer if (owns_existing) allocator.free(existing);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.writer.writeByte('\n');
    try out.writer.writeAll(line);
    try out.writer.writeByte('\n');
    const payload = try out.toOwnedSlice();
    defer allocator.free(payload);
    try writeTextAtomic(allocator, path, payload);
}

pub fn ensureNoPendingTransactions(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
) !void {
    if (try countPendingTransactions(allocator, transactions_dir) != 0) return error.TransactionRecoveryRequired;
}

pub fn countPendingTransactions(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
) !usize {
    const dir_stat = std.Io.Dir.cwd().statFile(Io.io(), transactions_dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    if (dir_stat.kind == .sym_link) return error.SymlinkComponent;
    if (dir_stat.kind != .directory) return error.NotDir;

    var dir = if (std.fs.path.isAbsolute(transactions_dir))
        try std.Io.Dir.openDirAbsolute(Io.io(), transactions_dir, .{ .iterate = true, .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), transactions_dir, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(Io.io());

    var pending: usize = 0;
    var entries: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(Io.io())) |entry| {
        if (entry.kind == .sym_link) return error.SymlinkComponent;
        if (entry.kind != .file and entry.kind != .directory) continue;
        if (entries >= 4096) return error.TooManyFiles;
        entries += 1;

        const entry_path = try std.fs.path.join(allocator, &.{ transactions_dir, entry.name });
        defer allocator.free(entry_path);
        const stat = try std.Io.Dir.cwd().statFile(Io.io(), entry_path, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.SymlinkComponent;

        if (stat.kind == .file) {
            if (stat.size > 1024 * 1024) return error.FileTooBig;
            const prepared_suffix = ".prepared.json";
            if (!std.mem.endsWith(u8, entry.name, prepared_suffix)) continue;
            const prefix = entry.name[0 .. entry.name.len - prepared_suffix.len];
            const commit_name = try std.fmt.allocPrint(allocator, "{s}.commit.json", .{prefix});
            defer allocator.free(commit_name);
            const commit_path = try std.fs.path.join(allocator, &.{ transactions_dir, commit_name });
            defer allocator.free(commit_path);
            if (!fileExists(commit_path)) pending += 1;
            continue;
        }

        if (stat.kind == .directory) {
            if (try transactionDirectoryPending(allocator, entry_path)) pending += 1;
        }
    }
    return pending;
}

fn transactionDirectoryPending(allocator: std.mem.Allocator, transaction_dir: []const u8) !bool {
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const commit_marker_path = try std.fs.path.join(allocator, &.{ transaction_dir, "commit.json" });
    defer allocator.free(commit_marker_path);
    const parsed = try parseTransactionRecord(allocator, record_path);
    defer parsed.deinit(allocator);
    return switch (parsed.state) {
        .committed => !fileExists(commit_marker_path),
        .aborted => false,
        .preparing, .prepared, .committing, .recovery_required => true,
    };
}

pub fn appendJsonlCheckpointTransaction(
    allocator: std.mem.Allocator,
    store_path: []const u8,
    locks_dir: []const u8,
    transactions_dir: []const u8,
    checkpoint_line: []const u8,
    options: JsonlTransactionOptions,
) !JsonlTransactionReceipt {
    try ensureDirectoryPathNoSymlinks(locks_dir);
    try ensureDirectoryPathNoSymlinks(transactions_dir);

    const lock_name = try transactionLockNameAlloc(allocator, store_path);
    defer allocator.free(lock_name);
    const lock_path = try std.fs.path.join(allocator, &.{ locks_dir, lock_name });
    defer allocator.free(lock_path);
    var lock = try acquireExclusiveLockPath(allocator, lock_path);
    defer lock.release(allocator);

    try ensureNoPendingTransactions(allocator, transactions_dir);

    const existing = readRegularFileNoSymlink(allocator, store_path, options.max_existing_bytes) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    const sequence_before = try lastJsonlSequence(allocator, existing, options.sequence_field);
    if (options.expected_sequence) |expected| {
        if (expected != sequence_before) return error.SequenceStale;
    }

    const trimmed_checkpoint = std.mem.trim(u8, checkpoint_line, " \t\r\n");
    if (trimmed_checkpoint.len == 0) return error.InvalidCheckpoint;
    const sequence_after = try jsonObjectSequence(allocator, trimmed_checkpoint, options.sequence_field);
    switch (options.mode) {
        .append => {
            if (sequence_after != sequence_before + 1) return error.TransactionSequenceMismatch;
        },
        .replace => {
            if (!options.allow_sequence_reset and sequence_after != sequence_before + 1) {
                return error.TransactionSequenceMismatch;
            }
        },
    }

    const transaction_id = try std.fmt.allocPrint(
        allocator,
        "txn-{d:0>12}-{d}",
        .{ sequence_after, std.Io.Clock.awake.now(Io.io()).nanoseconds },
    );
    errdefer allocator.free(transaction_id);
    const prepared_name = try std.fmt.allocPrint(allocator, "{s}.prepared.json", .{transaction_id});
    defer allocator.free(prepared_name);
    const prepared_path = try std.fs.path.join(allocator, &.{ transactions_dir, prepared_name });
    errdefer allocator.free(prepared_path);
    const commit_name = try std.fmt.allocPrint(allocator, "{s}.commit.json", .{transaction_id});
    defer allocator.free(commit_name);
    const commit_path = try std.fs.path.join(allocator, &.{ transactions_dir, commit_name });
    errdefer allocator.free(commit_path);

    const prepared = try renderTransactionRecord(
        allocator,
        "prepared",
        transaction_id,
        store_path,
        options.operation,
        sequence_before,
        sequence_after,
    );
    defer allocator.free(prepared);
    try writeTextCreateNew(allocator, prepared_path, prepared, .{});

    const combined = switch (options.mode) {
        .append => try combineJsonlAppend(allocator, existing, trimmed_checkpoint),
        .replace => try combineJsonlAppend(allocator, "", trimmed_checkpoint),
    };
    defer allocator.free(combined);
    try writeTextAtomic(allocator, store_path, combined);

    const committed = try renderTransactionRecord(
        allocator,
        "committed",
        transaction_id,
        store_path,
        options.operation,
        sequence_before,
        sequence_after,
    );
    defer allocator.free(committed);
    try writeTextCreateNew(allocator, commit_path, committed, .{});

    return .{
        .transaction_id = transaction_id,
        .prepared_path = prepared_path,
        .commit_path = commit_path,
        .sequence_before = sequence_before,
        .sequence_after = sequence_after,
    };
}

fn transactionLockNameAlloc(allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(store_path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.InvalidPath;
    return std.fmt.allocPrint(allocator, "{s}.lock", .{base});
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

fn lastJsonlSequence(allocator: std.mem.Allocator, data: []const u8, sequence_field: []const u8) !i64 {
    var last: []const u8 = "";
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len != 0) last = line;
    }
    if (last.len == 0) return 0;
    return jsonObjectSequence(allocator, last, sequence_field);
}

fn jsonObjectSequence(allocator: std.mem.Allocator, line: []const u8, sequence_field: []const u8) !i64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCheckpoint;
    const value = parsed.value.object.get(sequence_field) orelse return error.InvalidCheckpoint;
    if (value != .integer) return error.InvalidCheckpoint;
    return value.integer;
}

fn renderTransactionRecord(
    allocator: std.mem.Allocator,
    state: []const u8,
    transaction_id: []const u8,
    store_path: []const u8,
    operation: []const u8,
    sequence_before: i64,
    sequence_after: i64,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"transaction_schema\":\"DSTXN-v1\",\"state\":");
    try std.json.Stringify.value(state, .{}, writer);
    try writer.writeAll(",\"transaction_id\":");
    try std.json.Stringify.value(transaction_id, .{}, writer);
    try writer.writeAll(",\"operation\":");
    try std.json.Stringify.value(operation, .{}, writer);
    try writer.writeAll(",\"store_path\":");
    try std.json.Stringify.value(store_path, .{}, writer);
    try writer.writeAll(",\"sequence_before\":");
    try writer.print("{d}", .{sequence_before});
    try writer.writeAll(",\"sequence_after\":");
    try writer.print("{d}", .{sequence_after});
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

pub fn validateJsonl(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) !JsonlValidation {
    const data = readFileAlloc(allocator, path, max_bytes) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(data);
    return validateJsonlBytes(allocator, data);
}

pub fn validateJsonlBytes(allocator: std.mem.Allocator, data: []const u8) JsonlValidation {
    var result = JsonlValidation{};
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) {
            result.blank_lines += 1;
            continue;
        }
        result.lines += 1;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            if (result.first_issue == null) result.first_issue = .{ .line = line_no, .message = "invalid json" };
            continue;
        };
        parsed.deinit();
    }
    return result;
}

pub fn nextMonotonicIdAlloc(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    existing_ids: []const []const u8,
) ![]u8 {
    var max_seen: usize = 0;
    for (existing_ids) |id| {
        const n = parseMonotonicSuffix(prefix, id) orelse continue;
        if (n > max_seen) max_seen = n;
    }
    return std.fmt.allocPrint(allocator, "{s}{d:0>6}", .{ prefix, max_seen + 1 });
}

pub fn parseMonotonicSuffix(prefix: []const u8, id: []const u8) ?usize {
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    if (id.len == prefix.len) return null;
    return std.fmt.parseInt(usize, id[prefix.len..], 10) catch null;
}

pub const LockFile = struct {
    path: []u8,

    pub fn release(self: *LockFile, allocator: std.mem.Allocator) void {
        if (std.fs.path.isAbsolute(self.path)) {
            std.Io.Dir.deleteFileAbsolute(Io.io(), self.path) catch {};
        } else {
            std.Io.Dir.cwd().deleteFile(Io.io(), self.path) catch {};
        }
        allocator.free(self.path);
        self.* = .{ .path = &.{} };
    }
};

pub fn acquireLock(allocator: std.mem.Allocator, store_path: []const u8) !LockFile {
    const path = try lockPathAlloc(allocator, store_path);
    errdefer allocator.free(path);
    try ensureParentPath(path);
    var file = try std.Io.Dir.cwd().createFile(Io.io(), path, .{ .exclusive = true, .read = true, .truncate = false });
    file.close(Io.io());
    return .{ .path = path };
}

pub fn acquireAbsoluteExclusiveLock(allocator: std.mem.Allocator, absolute_path: []const u8) !LockFile {
    if (!std.fs.path.isAbsolute(absolute_path)) return error.NotAbsolute;
    const path = try allocator.dupe(u8, absolute_path);
    errdefer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try ensureDirectoryPathNoSymlinks(parent);
    const existing_stat = std.Io.Dir.cwd().statFile(Io.io(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing_stat) |stat| {
        if (stat.kind == .sym_link) return error.SymlinkComponent;
    }
    var file = try std.Io.Dir.createFileAbsolute(Io.io(), path, .{ .exclusive = true, .read = true, .truncate = false });
    file.close(Io.io());
    return .{ .path = path };
}

pub fn acquireExclusiveLockPath(allocator: std.mem.Allocator, path_raw: []const u8) !LockFile {
    if (std.fs.path.isAbsolute(path_raw)) return acquireAbsoluteExclusiveLock(allocator, path_raw);
    const path = try allocator.dupe(u8, path_raw);
    errdefer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try ensureDirectoryPathNoSymlinks(parent);
    const existing_stat = std.Io.Dir.cwd().statFile(Io.io(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing_stat) |stat| {
        if (stat.kind == .sym_link) return error.SymlinkComponent;
    }
    var file = try std.Io.Dir.cwd().createFile(Io.io(), path, .{ .exclusive = true, .read = true, .truncate = false });
    file.close(Io.io());
    return .{ .path = path };
}

fn acquireExclusiveLockPathRetry(
    allocator: std.mem.Allocator,
    path_raw: []const u8,
    timeout_ms: u64,
    retry_interval_ms: u64,
) !LockFile {
    const started_ms = clockMillis(.awake);
    while (true) {
        return acquireExclusiveLockPath(allocator, path_raw) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (timeout_ms == 0 or elapsedMillis(started_ms) >= timeout_ms) return error.LockBusy;
                const sleep_ms = @min(@max(retry_interval_ms, 1), @as(u64, @intCast(std.math.maxInt(i64))));
                std.Io.sleep(Io.io(), .fromMilliseconds(@intCast(sleep_ms)), .awake) catch {};
                continue;
            },
            else => return err,
        };
    }
}

pub fn findGitRootAlloc(allocator: std.mem.Allocator, start: []const u8) ![]u8 {
    var argv = [_][]const u8{ "git", "-C", start, "rev-parse", "--show-toplevel" };
    const result = try std.process.run(allocator, Io.io(), .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.GitCommandFailed;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.GitCommandFailed;
    return allocator.dupe(u8, trimmed);
}

pub fn ensureLockSidecarGitignored(allocator: std.mem.Allocator, store_path: []const u8) !void {
    const parent = std.fs.path.dirname(store_path) orelse ".";
    const git_root = findGitRootAlloc(allocator, parent) catch return;
    defer allocator.free(git_root);

    const lock_path = try lockPathAlloc(allocator, store_path);
    defer allocator.free(lock_path);
    const lock_rel = if (std.fs.path.isAbsolute(lock_path))
        try std.fs.path.relative(allocator, git_root, null, git_root, lock_path)
    else
        try allocator.dupe(u8, lock_path);
    defer allocator.free(lock_rel);

    var argv = [_][]const u8{ "git", "-C", git_root, "check-ignore", "-q", "--", lock_rel };
    const result = try std.process.run(allocator, Io.io(), .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return;
    if (result.term == .exited and result.term.exited == 1) return error.LockSidecarNotGitignored;
    return error.GitCommandFailed;
}

test "durable concurrency records render canonical json" {
    const owner: Owner = .{
        .process_id = 1234,
        .session_id = "session-a",
        .executor = "codex",
    };
    const lock: LeaseLock = .{
        .lock_id = "lock-1",
        .resource = "/repo/.step/st-plan.jsonl",
        .owner = owner,
        .acquired_at = "2026-06-25T14:00:00Z",
        .expires_at = "2026-06-25T14:00:05Z",
        .fencing_token = 7,
        .transaction_id = "txn-1",
        .path = "/repo/.step/st-plan.jsonl.lock",
    };
    const expected = [_]TransactionExpected{.{
        .path = "/repo/.step/st-plan.jsonl",
        .digest = "sha256:before",
        .sequence = 41,
    }};
    const writes = [_]TransactionWrite{.{
        .path = "/repo/.step/st-plan.jsonl",
        .staged_ref = "transactions/txn-1/st-plan.jsonl",
        .digest_after = "sha256:after",
        .sequence_after = 42,
    }};
    const locks = [_]LeaseLock{lock};
    const transaction: DurableTransaction = .{
        .transaction_id = "txn-1",
        .owner = owner,
        .state = .prepared,
        .expected = &expected,
        .writes = &writes,
        .locks = &locks,
        .created_at = "2026-06-25T14:00:00Z",
        .updated_at = "2026-06-25T14:00:01Z",
    };

    var lock_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lock_json.deinit();
    try lock.writeJson(&lock_json.writer);
    const lock_bytes = try lock_json.toOwnedSlice();
    defer std.testing.allocator.free(lock_bytes);
    try std.testing.expectEqualStrings(
        "{\"lock_version\":\"DLK-v1\",\"lock_id\":\"lock-1\",\"resource\":\"/repo/.step/st-plan.jsonl\",\"owner\":{\"process_id\":1234,\"session_id\":\"session-a\",\"executor\":\"codex\"},\"acquired_at\":\"2026-06-25T14:00:00Z\",\"expires_at\":\"2026-06-25T14:00:05Z\",\"fencing_token\":7,\"transaction_id\":\"txn-1\"}",
        lock_bytes,
    );

    var cas_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer cas_json.deinit();
    try (CasWriteReceipt{
        .path = "/repo/.step/st-plan.jsonl",
        .digest_before = null,
        .digest_after = "sha256:after",
        .sequence_before = 41,
        .sequence_after = 42,
        .result = "written",
    }).writeJson(&cas_json.writer);
    const cas_bytes = try cas_json.toOwnedSlice();
    defer std.testing.allocator.free(cas_bytes);
    try std.testing.expectEqualStrings(
        "{\"cas_write_receipt\":{\"path\":\"/repo/.step/st-plan.jsonl\",\"digest_before\":null,\"digest_after\":\"sha256:after\",\"sequence_before\":41,\"sequence_after\":42,\"result\":\"written\"}}",
        cas_bytes,
    );

    var transaction_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer transaction_json.deinit();
    try transaction.writeJson(&transaction_json.writer);
    const transaction_bytes = try transaction_json.toOwnedSlice();
    defer std.testing.allocator.free(transaction_bytes);
    try std.testing.expectEqualStrings(
        "{\"transaction_version\":\"DTX-v1\",\"transaction_id\":\"txn-1\",\"owner\":{\"process_id\":1234,\"session_id\":\"session-a\",\"executor\":\"codex\"},\"state\":\"prepared\",\"expected\":[{\"path\":\"/repo/.step/st-plan.jsonl\",\"digest\":\"sha256:before\",\"sequence\":41}],\"writes\":[{\"path\":\"/repo/.step/st-plan.jsonl\",\"staged_ref\":\"transactions/txn-1/st-plan.jsonl\",\"digest_after\":\"sha256:after\",\"sequence_after\":42}],\"locks\":[{\"lock_version\":\"DLK-v1\",\"lock_id\":\"lock-1\",\"resource\":\"/repo/.step/st-plan.jsonl\",\"owner\":{\"process_id\":1234,\"session_id\":\"session-a\",\"executor\":\"codex\"},\"acquired_at\":\"2026-06-25T14:00:00Z\",\"expires_at\":\"2026-06-25T14:00:05Z\",\"fencing_token\":7,\"transaction_id\":\"txn-1\"}],\"created_at\":\"2026-06-25T14:00:00Z\",\"updated_at\":\"2026-06-25T14:00:01Z\"}",
        transaction_bytes,
    );
}

test "lease locks enforce fencing tokens and reclaim expired metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
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

    var lock = try acquireLeaseLock(std.testing.allocator, resource, options);
    try std.testing.expect(lock.fencing_token > 0);
    try std.testing.expect(fileExists(lock.path));
    try std.testing.expectError(error.LockBusy, acquireLeaseLock(std.testing.allocator, resource, .{
        .owner = owner,
        .timeout_ms = 2,
        .retry_interval_ms = 1,
        .lease_ms = 1000,
        .fencing_counter_path = counter,
    }));

    try std.testing.expectError(error.FencingTokenStale, refreshLease(
        std.testing.allocator,
        &lock,
        lock.fencing_token + 1,
        1000,
    ));
    try refreshLease(std.testing.allocator, &lock, lock.fencing_token, 1000);

    const saved_executor = lock.owner.executor;
    lock.owner.executor = "other";
    try std.testing.expectError(error.LockOwnerMismatch, releaseLease(std.testing.allocator, &lock, lock.fencing_token));
    lock.owner.executor = saved_executor;
    try releaseLease(std.testing.allocator, &lock, lock.fencing_token);

    var expired = try acquireLeaseLock(std.testing.allocator, resource, .{
        .owner = owner,
        .timeout_ms = 0,
        .retry_interval_ms = 1,
        .lease_ms = 1,
        .fencing_counter_path = counter,
    });
    const expired_token = expired.fencing_token;
    defer expired.deinit(std.testing.allocator);
    std.Io.sleep(Io.io(), .fromMilliseconds(3), .awake) catch {};
    const receipt = try reclaimExpiredLease(std.testing.allocator, resource, options);
    defer {
        std.testing.allocator.free(receipt.lock_id);
        std.testing.allocator.free(receipt.resource);
        std.testing.allocator.free(receipt.result);
    }
    try std.testing.expectEqual(expired_token, receipt.previous_fencing_token);
    try std.testing.expect(receipt.authority_counter > expired_token);

    var after_reclaim = try acquireLeaseLock(std.testing.allocator, resource, options);
    defer releaseLease(std.testing.allocator, &after_reclaim, after_reclaim.fencing_token) catch {};
    try std.testing.expect(after_reclaim.fencing_token > receipt.previous_fencing_token);

    const corrupt_resource = try std.fs.path.join(std.testing.allocator, &.{ root, "corrupt.jsonl" });
    defer std.testing.allocator.free(corrupt_resource);
    const corrupt_counter = try std.fs.path.join(std.testing.allocator, &.{ root, "corrupt.counter" });
    defer std.testing.allocator.free(corrupt_counter);
    try writeTextAtomic(std.testing.allocator, corrupt_counter, "not-a-number\n");
    try std.testing.expectError(error.TransactionRecoveryRequired, acquireLeaseLock(std.testing.allocator, corrupt_resource, .{
        .owner = owner,
        .fencing_counter_path = corrupt_counter,
    }));
}

test "cas writes and jsonl snapshots reject stale expectations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "state.jsonl" });
    defer std.testing.allocator.free(path);

    var first = try writeTextAtomicCas(std.testing.allocator, path, "{\"seq\":1,\"ok\":true}\n", .{ .expected_exists = false });
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.digest_before == null);
    try std.testing.expectEqual(@as(?u64, null), first.sequence_before);
    try std.testing.expectEqual(@as(?u64, 1), first.sequence_after);

    var second = try writeTextAtomicCas(std.testing.allocator, path, "{\"seq\":2,\"ok\":true}\n", .{
        .expected_digest = first.digest_after,
        .expected_sequence = 1,
        .expected_exists = true,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 1), second.sequence_before);
    try std.testing.expectEqual(@as(?u64, 2), second.sequence_after);

    try std.testing.expectError(error.DigestMismatch, writeTextAtomicCas(std.testing.allocator, path, "{\"seq\":3}\n", .{
        .expected_digest = first.digest_after,
    }));
    try std.testing.expectError(error.SequenceMismatch, writeTextAtomicCas(std.testing.allocator, path, "{\"seq\":3}\n", .{
        .expected_sequence = 1,
    }));
    try std.testing.expectError(error.ExpectationMismatch, writeTextAtomicCas(std.testing.allocator, path, "{\"seq\":3}\n", .{
        .expected_exists = false,
    }));

    var snapshot = try readJsonlSnapshot(std.testing.allocator, path, 2);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 2), snapshot.sequence);
    try std.testing.expectEqualStrings(second.digest_after, snapshot.digest);
    try std.testing.expectError(error.SequenceMismatch, readJsonlSnapshot(std.testing.allocator, path, 1));

    var committed = try commitJsonlSnapshotCas(std.testing.allocator, path, "{\"seq\":3,\"ok\":true}\n", .{
        .expected_sequence = 2,
        .expected_digest = second.digest_after,
        .expected_exists = true,
    }, "txn-cas-1");
    defer committed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 2), committed.sequence_before);
    try std.testing.expectEqual(@as(?u64, 3), committed.sequence_after);
    try std.testing.expectEqualStrings("txn-cas-1", committed.transaction_id.?);

    try std.testing.expectError(error.InvalidJsonl, commitJsonlSnapshotCas(std.testing.allocator, path, "not-json\n", .{
        .expected_sequence = 3,
    }, null));
}

const CasWorkerContext = struct {
    path: []const u8,
    result: ?anyerror = null,
};

fn runCasWorker(context: *CasWorkerContext) void {
    var receipt = writeTextAtomicCas(std.heap.smp_allocator, context.path, "{\"seq\":2,\"worker\":true}\n", .{
        .expected_sequence = 1,
        .expected_exists = true,
    }) catch |err| {
        context.result = err;
        return;
    };
    receipt.deinit(std.heap.smp_allocator);
    context.result = null;
}

test "cas sidecar serializes comparison before write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "state.jsonl" });
    defer std.testing.allocator.free(path);
    try writeTextAtomic(std.testing.allocator, path, "{\"seq\":1,\"main\":true}\n");

    const lock_path = try casLockPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(lock_path);
    var held_lock = try acquireExclusiveLockPath(std.testing.allocator, lock_path);

    var context: CasWorkerContext = .{ .path = path };
    const thread = try std.Thread.spawn(.{}, runCasWorker, .{&context});
    std.Io.sleep(Io.io(), .fromMilliseconds(10), .awake) catch {};
    try writeTextAtomic(std.testing.allocator, path, "{\"seq\":2,\"main\":true}\n");
    held_lock.release(std.testing.allocator);
    thread.join();

    try std.testing.expect(context.result != null);
    try std.testing.expectEqual(error.SequenceMismatch, context.result.?);
    const final = try tryReadForTest(path);
    defer std.testing.allocator.free(final);
    try std.testing.expectEqualStrings("{\"seq\":2,\"main\":true}\n", final);
}

test "durable transactions commit and recover from prepared records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const transactions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "transactions" });
    defer std.testing.allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(transactions_dir);
    const counter = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.counter" });
    defer std.testing.allocator.free(counter);
    const owner: Owner = .{ .process_id = 200, .session_id = "txn-session", .executor = "test" };

    const workspace_path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(workspace_path);
    const plan_path = try std.fs.path.join(std.testing.allocator, &.{ root, "plan.jsonl" });
    defer std.testing.allocator.free(plan_path);
    try writeTextAtomic(std.testing.allocator, workspace_path, "{\"seq\":1,\"workspace\":true}\n");
    try writeTextAtomic(std.testing.allocator, plan_path, "{\"seq\":1,\"plan\":true}\n");
    const mutations = [_]TransactionMutation{
        .{ .path = plan_path, .text = "{\"seq\":2,\"plan\":true}\n", .expectation = .{ .expected_sequence = 1, .expected_exists = true } },
        .{ .path = workspace_path, .text = "{\"seq\":2,\"workspace\":true}\n", .expectation = .{ .expected_sequence = 1, .expected_exists = true } },
    };
    var receipt = try commitTextTransaction(std.testing.allocator, transactions_dir, &mutations, .{
        .owner = owner,
        .fencing_counter_path = counter,
    });
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(TransactionState.committed, receipt.state);
    try std.testing.expect(fileExists(receipt.commit_marker_path));
    const workspace_data = try tryReadForTest(workspace_path);
    defer std.testing.allocator.free(workspace_data);
    try std.testing.expectEqualStrings("{\"seq\":2,\"workspace\":true}\n", workspace_data);
    var committed_status = try inspectTransaction(std.testing.allocator, receipt.transaction_dir);
    defer committed_status.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.already_committed, committed_status.decision);

    const rollback_dir = try std.fs.path.join(std.testing.allocator, &.{ transactions_dir, "manual-rollback" });
    defer std.testing.allocator.free(rollback_dir);
    try ensureDirectoryPathNoSymlinks(rollback_dir);
    const rollback_record = try std.fs.path.join(std.testing.allocator, &.{ rollback_dir, "transaction.json" });
    defer std.testing.allocator.free(rollback_record);
    const rollback_path = try std.fs.path.join(std.testing.allocator, &.{ root, "rollback.jsonl" });
    defer std.testing.allocator.free(rollback_path);
    try writeTextAtomic(std.testing.allocator, rollback_path, "{\"seq\":1}\n");
    try writePreparedRecordForTest(std.testing.allocator, rollback_record, "txn-rollback", owner, rollback_path, "{\"seq\":1}\n", "{\"seq\":2}\n");
    try std.testing.expectEqual(@as(usize, 1), try countPendingTransactions(std.testing.allocator, transactions_dir));
    try std.testing.expectError(error.TransactionRecoveryRequired, ensureNoPendingTransactions(std.testing.allocator, transactions_dir));
    var rollback_status = try inspectTransaction(std.testing.allocator, rollback_dir);
    defer rollback_status.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.roll_back_unpublished, rollback_status.decision);
    var rollback_receipt = try recoverTransaction(std.testing.allocator, rollback_dir);
    defer rollback_receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.roll_back_unpublished, rollback_receipt.decision);
    try std.testing.expectEqual(@as(usize, 0), try countPendingTransactions(std.testing.allocator, transactions_dir));

    const finish_dir = try std.fs.path.join(std.testing.allocator, &.{ transactions_dir, "manual-finish" });
    defer std.testing.allocator.free(finish_dir);
    try ensureDirectoryPathNoSymlinks(finish_dir);
    const finish_record = try std.fs.path.join(std.testing.allocator, &.{ finish_dir, "transaction.json" });
    defer std.testing.allocator.free(finish_record);
    const finish_path = try std.fs.path.join(std.testing.allocator, &.{ root, "finish.jsonl" });
    defer std.testing.allocator.free(finish_path);
    try writeTextAtomic(std.testing.allocator, finish_path, "{\"seq\":2}\n");
    try writePreparedRecordForTest(std.testing.allocator, finish_record, "txn-finish", owner, finish_path, "{\"seq\":1}\n", "{\"seq\":2}\n");
    try std.testing.expectEqual(@as(usize, 1), try countPendingTransactions(std.testing.allocator, transactions_dir));
    var finish_status = try inspectTransaction(std.testing.allocator, finish_dir);
    defer finish_status.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, finish_status.decision);
    var finish_receipt = try recoverTransaction(std.testing.allocator, finish_dir);
    defer finish_receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, finish_receipt.decision);
    const finish_marker = try std.fs.path.join(std.testing.allocator, &.{ finish_dir, "commit.json" });
    defer std.testing.allocator.free(finish_marker);
    try std.testing.expect(fileExists(finish_marker));
    try std.testing.expectEqual(@as(usize, 0), try countPendingTransactions(std.testing.allocator, transactions_dir));

    const mixed_dir = try std.fs.path.join(std.testing.allocator, &.{ transactions_dir, "manual-mixed" });
    defer std.testing.allocator.free(mixed_dir);
    try ensureDirectoryPathNoSymlinks(mixed_dir);
    const mixed_record = try std.fs.path.join(std.testing.allocator, &.{ mixed_dir, "transaction.json" });
    defer std.testing.allocator.free(mixed_record);
    const mixed_a = try std.fs.path.join(std.testing.allocator, &.{ root, "mixed-a.jsonl" });
    defer std.testing.allocator.free(mixed_a);
    const mixed_b = try std.fs.path.join(std.testing.allocator, &.{ root, "mixed-b.jsonl" });
    defer std.testing.allocator.free(mixed_b);
    try writeTextAtomic(std.testing.allocator, mixed_a, "{\"seq\":2}\n");
    try writeTextAtomic(std.testing.allocator, mixed_b, "{\"seq\":1}\n");
    try writePreparedTwoWriteRecordForTest(std.testing.allocator, mixed_record, owner, mixed_a, mixed_b);
    try std.testing.expectEqual(@as(usize, 1), try countPendingTransactions(std.testing.allocator, transactions_dir));
    var mixed_status = try inspectTransaction(std.testing.allocator, mixed_dir);
    defer mixed_status.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.manual_recovery_required, mixed_status.decision);
    try std.testing.expectError(error.TransactionRecoveryRequired, recoverTransaction(std.testing.allocator, mixed_dir));
}

test "transactions publish in canonical path order and reject duplicates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const transactions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "transactions" });
    defer std.testing.allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(transactions_dir);
    const counter = try std.fs.path.join(std.testing.allocator, &.{ root, "counter" });
    defer std.testing.allocator.free(counter);
    const a_path = try std.fs.path.join(std.testing.allocator, &.{ root, "a-plan.jsonl" });
    defer std.testing.allocator.free(a_path);
    const z_path = try std.fs.path.join(std.testing.allocator, &.{ root, "z-workspace.jsonl" });
    defer std.testing.allocator.free(z_path);
    try writeTextAtomic(std.testing.allocator, a_path, "{\"seq\":1,\"name\":\"a\"}\n");
    try writeTextAtomic(std.testing.allocator, z_path, "{\"seq\":1,\"name\":\"z\"}\n");

    const owner: Owner = .{ .process_id = 201, .session_id = "ordered", .executor = "test" };
    const reverse = [_]TransactionMutation{
        .{ .path = z_path, .text = "{\"seq\":2,\"name\":\"z\"}\n", .expectation = .{ .expected_sequence = 1, .expected_exists = true } },
        .{ .path = a_path, .text = "{\"seq\":2,\"name\":\"a\"}\n", .expectation = .{ .expected_sequence = 1, .expected_exists = true } },
    };
    var receipt = try commitTextTransaction(std.testing.allocator, transactions_dir, &reverse, .{
        .owner = owner,
        .fencing_counter_path = counter,
    });
    defer receipt.deinit(std.testing.allocator);

    const record = try readRegularFileNoSymlink(std.testing.allocator, receipt.record_path, default_snapshot_max_bytes);
    defer std.testing.allocator.free(record);
    const a_index = std.mem.indexOf(u8, record, a_path) orelse return error.TestExpectedCanonicalPath;
    const z_index = std.mem.indexOf(u8, record, z_path) orelse return error.TestExpectedCanonicalPath;
    try std.testing.expect(a_index < z_index);

    const duplicate = [_]TransactionMutation{
        .{ .path = a_path, .text = "{\"seq\":3,\"name\":\"a\"}\n", .expectation = .{ .expected_sequence = 2, .expected_exists = true } },
        .{ .path = a_path, .text = "{\"seq\":4,\"name\":\"a\"}\n", .expectation = .{ .expected_sequence = 2, .expected_exists = true } },
    };
    try std.testing.expectError(error.InvalidPath, commitTextTransaction(std.testing.allocator, transactions_dir, &duplicate, .{
        .owner = owner,
        .fencing_counter_path = counter,
    }));
}

test "writeTextAtomic creates parent directories and replaces content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "store.jsonl" });
    defer std.testing.allocator.free(path);

    try writeTextAtomic(std.testing.allocator, path, "{\"ok\":true}\n");
    const first = try tryReadForTest(path);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", first);
    try writeTextAtomic(std.testing.allocator, path, "{\"ok\":false}\n");
    const second = try tryReadForTest(path);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"ok\":false}\n", second);
}

test "writeTextCreateNew creates once without overwriting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "note.md" });
    defer std.testing.allocator.free(path);

    try writeTextCreateNew(std.testing.allocator, path, "first", .{});
    try std.testing.expectError(error.PathAlreadyExists, writeTextCreateNew(std.testing.allocator, path, "second", .{}));
    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("first", data);
}

test "writeTextCreateNew rejects symlink parent component" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    try tmp.dir.createDir(Io.io(), "real", .default_dir);
    try tmp.dir.symLink(Io.io(), "real", "link", .{ .is_directory = true });
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "link", "note.md" });
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.SymlinkComponent, writeTextCreateNew(std.testing.allocator, path, "payload", .{}));
}

test "readRegularFileNoSymlink rejects symlink and oversized file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "file.txt" });
    defer std.testing.allocator.free(path);
    const link = try std.fs.path.join(std.testing.allocator, &.{ root, "link.txt" });
    defer std.testing.allocator.free(link);

    try writeTextAtomic(std.testing.allocator, path, "abcd");
    try tmp.dir.symLink(Io.io(), "file.txt", "link.txt", .{});
    const data = try readRegularFileNoSymlink(std.testing.allocator, path, 4);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("abcd", data);
    try std.testing.expectError(error.FileTooBig, readRegularFileNoSymlink(std.testing.allocator, path, 3));
    try std.testing.expectError(error.SymlinkComponent, readRegularFileNoSymlink(std.testing.allocator, link, 4));
}

test "listSortedRegularFilesNoSymlink sorts and rejects symlink entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ root, "notes" });
    defer std.testing.allocator.free(dir_path);
    try ensureDirectoryPathNoSymlinks(dir_path);

    const b = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "b.md" });
    defer std.testing.allocator.free(b);
    const a = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "a.md" });
    defer std.testing.allocator.free(a);
    try writeTextCreateNew(std.testing.allocator, b, "b", .{});
    try writeTextCreateNew(std.testing.allocator, a, "a", .{});

    const names = try listSortedRegularFilesNoSymlink(std.testing.allocator, dir_path, 10, 10);
    defer freeStringList(std.testing.allocator, names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("a.md", names[0]);
    try std.testing.expectEqualStrings("b.md", names[1]);

    var dir = try std.Io.Dir.openDirAbsolute(Io.io(), dir_path, .{});
    defer dir.close(Io.io());
    try dir.symLink(Io.io(), "a.md", "link.md", .{});
    try std.testing.expectError(error.SymlinkComponent, listSortedRegularFilesNoSymlink(std.testing.allocator, dir_path, 10, 10));
}

test "appendLineAtomic appends newline-delimited records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "store.jsonl" });
    defer std.testing.allocator.free(path);

    try appendLineAtomic(std.testing.allocator, path, "{\"n\":1}", 1024);
    try appendLineAtomic(std.testing.allocator, path, "{\"n\":2}", 1024);
    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"n\":1}\n{\"n\":2}\n", data);
}

test "appendJsonlCheckpointTransaction publishes checkpoint and receipts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(store_path);
    const locks_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "locks" });
    defer std.testing.allocator.free(locks_dir);
    const transactions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "transactions" });
    defer std.testing.allocator.free(transactions_dir);

    var first = try appendJsonlCheckpointTransaction(
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":1,\"ok\":true}",
        .{ .expected_sequence = 0, .sequence_field = "workspace_sequence", .operation = "test-init" },
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), first.sequence_before);
    try std.testing.expectEqual(@as(i64, 1), first.sequence_after);
    try std.testing.expect(fileExists(first.prepared_path));
    try std.testing.expect(fileExists(first.commit_path));

    var second = try appendJsonlCheckpointTransaction(
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":2,\"ok\":false}",
        .{ .expected_sequence = 1, .sequence_field = "workspace_sequence", .operation = "test-append" },
    );
    defer second.deinit(std.testing.allocator);
    const data = try tryReadForTest(store_path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"workspace_sequence\":1,\"ok\":true}\n{\"workspace_sequence\":2,\"ok\":false}\n", data);
}

test "appendJsonlCheckpointTransaction rejects stale sequence without publishing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(store_path);
    const locks_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "locks" });
    defer std.testing.allocator.free(locks_dir);
    const transactions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "transactions" });
    defer std.testing.allocator.free(transactions_dir);

    var first = try appendJsonlCheckpointTransaction(
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":1,\"ok\":true}",
        .{ .expected_sequence = 0, .sequence_field = "workspace_sequence" },
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expectError(error.SequenceStale, appendJsonlCheckpointTransaction(
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(store_path);
    const locks_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "locks" });
    defer std.testing.allocator.free(locks_dir);
    const transactions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "transactions" });
    defer std.testing.allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(transactions_dir);
    const prepared_path = try std.fs.path.join(std.testing.allocator, &.{ transactions_dir, "txn-orphan.prepared.json" });
    defer std.testing.allocator.free(prepared_path);
    try writeTextCreateNew(std.testing.allocator, prepared_path, "{\"state\":\"prepared\"}\n", .{});

    try std.testing.expectError(error.TransactionRecoveryRequired, appendJsonlCheckpointTransaction(
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":1,\"ok\":true}",
        .{ .expected_sequence = 0, .sequence_field = "workspace_sequence" },
    ));
}

test "validateJsonlBytes reports first invalid row" {
    const valid = validateJsonlBytes(std.testing.allocator, "{\"a\":1}\n\n{\"b\":2}\n");
    try std.testing.expect(valid.ok());
    try std.testing.expectEqual(@as(usize, 2), valid.lines);

    const invalid = validateJsonlBytes(std.testing.allocator, "{\"a\":1}\nnot-json\n");
    try std.testing.expect(!invalid.ok());
    try std.testing.expectEqual(@as(usize, 2), invalid.first_issue.?.line);
}

test "nextMonotonicIdAlloc scans matching numeric suffixes" {
    const ids = [_][]const u8{ "NEG-000001", "other", "NEG-000010", "NEG-bad" };
    const next = try nextMonotonicIdAlloc(std.testing.allocator, "NEG-", &ids);
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("NEG-000011", next);
}

test "acquireLock is exclusive until released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "store.jsonl" });
    defer std.testing.allocator.free(path);

    var lock = try acquireLock(std.testing.allocator, path);
    try std.testing.expectError(error.PathAlreadyExists, acquireLock(std.testing.allocator, path));
    lock.release(std.testing.allocator);
    var second = try acquireLock(std.testing.allocator, path);
    second.release(std.testing.allocator);
}

test "acquireAbsoluteExclusiveLock is exclusive until released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "locks", "store.lock" });
    defer std.testing.allocator.free(path);

    var lock = try acquireAbsoluteExclusiveLock(std.testing.allocator, path);
    try std.testing.expectError(error.PathAlreadyExists, acquireAbsoluteExclusiveLock(std.testing.allocator, path));
    lock.release(std.testing.allocator);
    var second = try acquireAbsoluteExclusiveLock(std.testing.allocator, path);
    second.release(std.testing.allocator);
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
    const digest_before = try digestBytesAlloc(allocator, before);
    defer allocator.free(digest_before);
    const digest_after = try digestBytesAlloc(allocator, after);
    defer allocator.free(digest_after);
    const expected = [_]TransactionExpected{.{
        .path = path,
        .digest = digest_before,
        .sequence = (try jsonlSequenceRequired(allocator, before)).?,
    }};
    const writes = [_]TransactionWrite{.{
        .path = path,
        .staged_ref = "write-0.staged",
        .digest_after = digest_after,
        .sequence_after = (try jsonlSequenceRequired(allocator, after)).?,
    }};
    try writeTransactionRecord(allocator, record_path, transaction_id, owner, .prepared, &expected, &writes, &.{}, 1, 2, true);
}

fn writePreparedTwoWriteRecordForTest(
    allocator: std.mem.Allocator,
    record_path: []const u8,
    owner: Owner,
    path_a: []const u8,
    path_b: []const u8,
) !void {
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
    const writes = [_]TransactionWrite{
        .{
            .path = path_a,
            .staged_ref = "write-0.staged",
            .digest_after = digest_after,
            .sequence_after = 2,
        },
        .{
            .path = path_b,
            .staged_ref = "write-1.staged",
            .digest_after = digest_after,
            .sequence_after = 2,
        },
    };
    try writeTransactionRecord(allocator, record_path, "txn-mixed", owner, .prepared, &expected, &writes, &.{}, 1, 2, true);
}

fn tryReadForTest(path: []const u8) ![]u8 {
    return try readFileAlloc(std.testing.allocator, path, 4096);
}
