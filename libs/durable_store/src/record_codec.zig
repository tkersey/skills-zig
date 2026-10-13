const std = @import("std");

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
    transaction_id: ?[]const u8 = null,
    reject_symlinks: bool = true,
};

pub const LegacyFencingAuthority = union(enum) {
    per_resource,
    shared: []const u8,
};

pub const TransactionRecoveryOptions = struct {
    /// Recovery must name the counter authority used by legacy writers.
    legacy_fencing_authority: ?LegacyFencingAuthority = null,
};

pub const TransactionRecoverySummary = struct {
    transaction_count: usize = 0,
    storage_mutated: bool = false,
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

pub const LegacyLeaseRecoveryCandidate = struct {
    transaction_id: []u8,
    lock_id: []u8,
    resource: []u8,
    fencing_token: u64,
    expires_at: []u8,
    kind: Kind,

    pub const Kind = enum {
        expired_legacy,
        interrupted_recovery,

        fn writeJson(self: Kind, writer: anytype) !void {
            try std.json.Stringify.value(@tagName(self), .{}, writer);
        }
    };

    pub fn deinit(
        self: *LegacyLeaseRecoveryCandidate,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.transaction_id);
        allocator.free(self.lock_id);
        allocator.free(self.resource);
        allocator.free(self.expires_at);
        self.* = undefined;
    }

    pub fn writeJson(
        self: LegacyLeaseRecoveryCandidate,
        writer: anytype,
    ) !void {
        try writer.writeAll("{\"transaction_id\":");
        try std.json.Stringify.value(self.transaction_id, .{}, writer);
        try writer.writeAll(",\"lock_id\":");
        try std.json.Stringify.value(self.lock_id, .{}, writer);
        try writer.writeAll(",\"resource\":");
        try std.json.Stringify.value(self.resource, .{}, writer);
        try writer.writeAll(",\"fencing_token\":");
        try writer.print("{d}", .{self.fencing_token});
        try writer.writeAll(",\"expires_at\":");
        try std.json.Stringify.value(self.expires_at, .{}, writer);
        try writer.writeAll(",\"kind\":");
        try self.kind.writeJson(writer);
        try writer.writeByte('}');
    }
};

pub const LegacyLeaseReclaimRequest = struct {
    transaction_id: []const u8,
    resource: []const u8,
    lock_id: []const u8,
    fencing_token: u64,
    confirm_no_legacy_writers: bool = false,
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

pub const TransactionRecordFormat = enum {
    current,
    legacy,
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
        try self.writeJsonWithFormat(writer, null);
    }

    fn writeJsonWithFormat(
        self: DurableTransaction,
        writer: anytype,
        format: ?TransactionRecordFormat,
    ) !void {
        try self.writeJsonWithFormatAndProfile(
            writer,
            format,
            false,
        );
    }

    fn writeJsonWithFormatAndProfile(
        self: DurableTransaction,
        writer: anytype,
        format: ?TransactionRecordFormat,
        bounded_rows: bool,
    ) !void {
        try writer.writeAll("{\"transaction_version\":\"DTX-v1\",\"transaction_id\":");
        try std.json.Stringify.value(self.transaction_id, .{}, writer);
        try writer.writeAll(",\"owner\":");
        try self.owner.writeJson(writer);
        try writer.writeAll(",\"state\":");
        try std.json.Stringify.value(self.state.asString(), .{}, writer);
        if (format) |journal_format| {
            try writer.writeAll(",\"journal_format\":");
            try std.json.Stringify.value(@tagName(journal_format), .{}, writer);
        }
        if (bounded_rows) {
            try writer.writeAll(
                ",\"recovery_profile\":\"bounded-rows-v1\"",
            );
        }
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
    content_mode: TransactionContentMode = .jsonl_sequence_required,
    max_bytes: usize = default_snapshot_max_bytes,
    action: TransactionMutationAction = .write,
    expected_digest_after: ?[]const u8 = null,
};

pub const TransactionContentMode = enum {
    jsonl_sequence_required,
    raw,
};

pub const TransactionMutationAction = enum {
    write,
    append,
    check_only,
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
    storage_mutated: bool = false,

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

pub fn leaseWitnessesEqual(left: LeaseLock, right: LeaseLock) bool {
    return leaseLineagesEqual(left, right) and
        std.mem.eql(u8, left.expires_at, right.expires_at);
}

pub fn leaseLineagesEqual(left: LeaseLock, right: LeaseLock) bool {
    return std.mem.eql(u8, left.lock_id, right.lock_id) and
        std.mem.eql(u8, left.resource, right.resource) and
        ownersEqual(left.owner, right.owner) and
        std.mem.eql(u8, left.acquired_at, right.acquired_at) and
        left.fencing_token == right.fencing_token and
        optionalStringsEqual(left.transaction_id, right.transaction_id) and
        std.mem.eql(u8, left.path, right.path);
}

fn optionalStringsEqual(
    left: ?[]const u8,
    right: ?[]const u8,
) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

pub fn parseU64Text(bytes: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return error.TransactionRecoveryRequired;
    return std.fmt.parseUnsigned(u64, trimmed, 10) catch error.TransactionRecoveryRequired;
}

pub fn makeLeaseLockOwned(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    resource_path: []const u8,
    owner: Owner,
    acquired_ms: u64,
    expires_ms: u64,
    fencing_token: u64,
    transaction_id: ?[]const u8,
) !LeaseLock {
    var lock: LeaseLock = .{
        .lock_id = &.{},
        .resource = &.{},
        .owner = .{ .process_id = owner.process_id, .session_id = &.{}, .executor = &.{} },
        .acquired_at = &.{},
        .expires_at = &.{},
        .fencing_token = fencing_token,
        .transaction_id = null,
        .path = &.{},
    };
    errdefer lock.deinit(allocator);
    lock.lock_id = try allocator.print(
        "dlk-{d}-{d}",
        .{ fencing_token, acquired_ms },
    );
    lock.resource = try allocator.dupe(u8, resource_path);
    lock.owner.session_id = try allocator.dupe(u8, owner.session_id);
    lock.owner.executor = try allocator.dupe(u8, owner.executor);
    lock.acquired_at = try allocator.print("{d}", .{acquired_ms});
    lock.expires_at = try allocator.print("{d}", .{expires_ms});
    lock.transaction_id = if (transaction_id) |value| try allocator.dupe(u8, value) else null;
    lock.path = try allocator.dupe(u8, lock_path);
    return lock;
}

pub fn renderLeaseLockAlloc(allocator: std.mem.Allocator, lock: LeaseLock) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try lock.writeJson(&out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn parseLeaseLockValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    persisted_path: ?[]const u8,
) !LeaseLock {
    if (value != .object) return error.TransactionCorrupt;
    const object = value.object;
    const version = try transactionStringField(object, "lock_version");
    if (!std.mem.eql(u8, version, "DLK-v1")) return error.TransactionCorrupt;
    const owner_value = object.get("owner") orelse return error.TransactionCorrupt;
    if (owner_value != .object) return error.TransactionCorrupt;
    const owner_object = owner_value.object;
    const process_id = jsonInteger(
        owner_object.get("process_id") orelse return error.TransactionCorrupt,
    ) orelse return error.TransactionCorrupt;
    const lock_id = try transactionStringField(object, "lock_id");
    const resource = try transactionStringField(object, "resource");
    const session_id = try transactionStringField(owner_object, "session_id");
    const executor = try transactionStringField(owner_object, "executor");
    const acquired_at = try transactionStringField(object, "acquired_at");
    const expires_at = try transactionStringField(object, "expires_at");
    const fencing_token = jsonUnsigned(
        object.get("fencing_token") orelse
            return error.TransactionCorrupt,
    ) orelse return error.TransactionCorrupt;
    const transaction_value = object.get("transaction_id") orelse return error.TransactionCorrupt;
    const transaction_id = switch (transaction_value) {
        .null => null,
        .string => |text| text,
        else => return error.TransactionCorrupt,
    };

    const lock_id_owned = try allocator.dupe(u8, lock_id);
    errdefer allocator.free(lock_id_owned);
    const resource_owned = try allocator.dupe(u8, resource);
    errdefer allocator.free(resource_owned);
    const session_id_owned = try allocator.dupe(u8, session_id);
    errdefer allocator.free(session_id_owned);
    const executor_owned = try allocator.dupe(u8, executor);
    errdefer allocator.free(executor_owned);
    const acquired_at_owned = try allocator.dupe(u8, acquired_at);
    errdefer allocator.free(acquired_at_owned);
    const expires_at_owned = try allocator.dupe(u8, expires_at);
    errdefer allocator.free(expires_at_owned);
    const transaction_id_owned = if (transaction_id) |text|
        try allocator.dupe(u8, text)
    else
        null;
    errdefer if (transaction_id_owned) |text| allocator.free(text);
    const path_owned = if (persisted_path) |path|
        try allocator.dupe(u8, path)
    else
        try lockPathAlloc(allocator, resource);
    errdefer allocator.free(path_owned);

    return .{
        .lock_id = lock_id_owned,
        .resource = resource_owned,
        .owner = .{
            .process_id = process_id,
            .session_id = session_id_owned,
            .executor = executor_owned,
        },
        .acquired_at = acquired_at_owned,
        .expires_at = expires_at_owned,
        .fencing_token = fencing_token,
        .transaction_id = transaction_id_owned,
        .path = path_owned,
    };
}

fn transactionStringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.TransactionCorrupt;
    return jsonString(value) orelse error.TransactionCorrupt;
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

fn jsonUnsigned(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| if (number < 0) null else @intCast(number),
        .number_string => |number| std.fmt.parseUnsigned(
            u64,
            number,
            10,
        ) catch null,
        else => null,
    };
}

test "embedded lease witnesses preserve the full unsigned fencing range" {
    const bytes =
        "{\"lock_version\":\"DLK-v1\",\"lock_id\":\"dlk-max\"," ++
        "\"resource\":\"/repo/events.jsonl\",\"owner\":{" ++
        "\"process_id\":1,\"session_id\":\"max-token\"," ++
        "\"executor\":\"test\"},\"acquired_at\":\"1\"," ++
        "\"expires_at\":\"2\",\"fencing_token\":" ++
        "18446744073709551615,\"transaction_id\":\"dtx-1\"}";
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        bytes,
        .{},
    );
    defer parsed.deinit();
    var lock = try parseLeaseLockValue(
        std.testing.allocator,
        parsed.value,
        null,
    );
    defer lock.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        lock.fencing_token,
    );
}

pub fn ownersEqual(a: Owner, b: Owner) bool {
    return a.process_id == b.process_id and
        std.mem.eql(u8, a.session_id, b.session_id) and
        std.mem.eql(u8, a.executor, b.executor);
}

pub const default_snapshot_max_bytes: usize = 1024 * 1024;

pub const transaction_record_max_bytes: usize = default_snapshot_max_bytes;

pub const transaction_recovery_max_rows: usize = 1024;

pub const transaction_stage_prefix = ".ledger-dtx-stage-";

pub fn transactionStageNameAlloc(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    write_index: usize,
) ![]u8 {
    var buffer: [96]u8 = undefined;
    return allocator.dupe(
        u8,
        try transactionStageName(
            &buffer,
            transaction_id,
            write_index,
        ),
    );
}

pub fn transactionStageName(
    buffer: []u8,
    transaction_id: []const u8,
    write_index: usize,
) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(transaction_id, &digest, .{});
    const identity = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return std.fmt.bufPrint(
        buffer,
        "{s}{s}-{d}",
        .{ transaction_stage_prefix, &identity, write_index },
    );
}

pub fn legacyTransactionStageName(
    buffer: []u8,
    write_index: usize,
) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "write-{d}.staged",
        .{write_index},
    );
}

pub fn transactionRecordFormat(
    allocator: std.mem.Allocator,
    parsed: ParsedTransactionRecord,
) !TransactionRecordFormat {
    const current_id = isGeneratedTransactionId(parsed.transaction_id);
    const legacy_id = isLegacyTransactionId(parsed.transaction_id);
    if (!current_id and !legacy_id) return error.TransactionCorrupt;
    if (parsed.writes.len == 0) {
        const inferred: TransactionRecordFormat = if (legacy_id or
            parsed.embedded_locks.len != 0)
            .legacy
        else
            .current;
        if (parsed.format_hint) |hint| {
            if (hint == .legacy and current_id) return .legacy;
            if (hint != inferred) return error.TransactionCorrupt;
        }
        return inferred;
    }
    var selected: ?TransactionRecordFormat = null;
    var expected_indexes = std.StringHashMap(usize).init(allocator);
    defer expected_indexes.deinit();
    for (parsed.expected, 0..) |expected, index| {
        const result = try expected_indexes.getOrPut(expected.path);
        if (result.found_existing) return error.TransactionCorrupt;
        result.value_ptr.* = index;
    }
    for (parsed.writes, 0..) |write, write_index| {
        var name_buffer: [96]u8 = undefined;
        const expected_index = expected_indexes.get(write.path) orelse
            return error.TransactionCorrupt;
        const legacy_name = try legacyTransactionStageName(
            &name_buffer,
            expected_index,
        );
        const row_format: TransactionRecordFormat = if (std.mem.eql(
            u8,
            write.staged_ref,
            legacy_name,
        ))
            .legacy
        else current: {
            if (!current_id) return error.TransactionCorrupt;
            const current_name = try transactionStageName(
                &name_buffer,
                parsed.transaction_id,
                write_index,
            );
            if (!std.mem.eql(u8, write.staged_ref, current_name)) {
                return error.TransactionCorrupt;
            }
            break :current .current;
        };
        if (selected) |format| {
            if (format != row_format) return error.TransactionCorrupt;
        } else {
            selected = row_format;
        }
    }
    const inferred = selected.?;
    if (parsed.format_hint) |hint| {
        if (hint != inferred) return error.TransactionCorrupt;
    }
    return inferred;
}

pub fn isGeneratedTransactionId(transaction_id: []const u8) bool {
    const prefix = "dtx-";
    if (!std.mem.startsWith(u8, transaction_id, prefix)) return false;
    const suffix_separator = std.mem.lastIndexOfScalar(
        u8,
        transaction_id,
        '-',
    ) orelse return false;
    if (suffix_separator <= prefix.len or
        transaction_id.len - suffix_separator - 1 != 32)
    {
        return false;
    }
    for (transaction_id[prefix.len..suffix_separator]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    for (transaction_id[suffix_separator + 1 ..]) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

pub fn isLegacyTransactionId(transaction_id: []const u8) bool {
    const prefix = "dtx-";
    if (!std.mem.startsWith(u8, transaction_id, prefix) or
        transaction_id.len == prefix.len)
    {
        return false;
    }
    for (transaction_id[prefix.len..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

pub fn renderTransactionRecordAlloc(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    owner: Owner,
    state: TransactionState,
    expected: []const TransactionExpected,
    writes: []const TransactionWrite,
    locks: []const LeaseLock,
    created_ms: u64,
    updated_ms: u64,
    format: ?TransactionRecordFormat,
) ![]u8 {
    const created_at = try allocator.print("{d}", .{created_ms});
    defer allocator.free(created_at);
    const updated_at = try allocator.print("{d}", .{updated_ms});
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
    errdefer out.deinit();
    transaction.writeJsonWithFormatAndProfile(
        &out.writer,
        format,
        format == .current,
    ) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

pub fn freeTransactionExpectedRows(allocator: std.mem.Allocator, expected: []TransactionExpected) void {
    for (expected) |row| {
        allocator.free(row.path);
        allocator.free(row.digest);
    }
}

pub fn freeTransactionWriteRows(allocator: std.mem.Allocator, writes: []TransactionWrite) void {
    for (writes) |row| {
        allocator.free(row.path);
        allocator.free(row.staged_ref);
        allocator.free(row.digest_after);
    }
}

fn freeTransactionLockRows(allocator: std.mem.Allocator, locks: []LeaseLock) void {
    for (locks) |*lock| lock.deinit(allocator);
}

pub const ParsedTransactionRecord = struct {
    transaction_id: []const u8,
    owner: Owner,
    state: TransactionState,
    expected: []TransactionExpected,
    writes: []TransactionWrite,
    embedded_locks: []LeaseLock = &.{},
    format_hint: ?TransactionRecordFormat = null,
    bounded_rows: bool = false,
    created_at: []const u8,
    updated_at: []const u8,

    pub fn deinit(self: ParsedTransactionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.transaction_id);
        self.owner.deinit(allocator);
        freeTransactionExpectedRows(allocator, self.expected);
        allocator.free(self.expected);
        freeTransactionWriteRows(allocator, self.writes);
        allocator.free(self.writes);
        freeTransactionLockRows(allocator, self.embedded_locks);
        allocator.free(self.embedded_locks);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};

/// Borrows the active JSON parser; only ownTransactionRecordFields may turn
/// these fields into the escaping, independently owned recovery record.
const TransactionRecordFields = struct {
    transaction_id: []const u8,
    state: []const u8,
    owner: Owner,
    expected: []std.json.Value,
    writes: []std.json.Value,
    locks: []std.json.Value,
    created_at: []const u8,
    updated_at: []const u8,
    format_hint: ?TransactionRecordFormat,
    bounded_rows: bool,
};

pub fn transactionRecordFields(object: std.json.ObjectMap) !TransactionRecordFields {
    const version = try transactionStringField(object, "transaction_version");
    if (!std.mem.eql(u8, version, "DTX-v1")) return error.TransactionCorrupt;
    const transaction_id = try transactionStringField(object, "transaction_id");
    const state = try transactionStringField(object, "state");
    const owner_value = object.get("owner") orelse return error.TransactionCorrupt;
    if (owner_value != .object) return error.TransactionCorrupt;
    const expected = object.get("expected") orelse return error.TransactionCorrupt;
    const writes = object.get("writes") orelse return error.TransactionCorrupt;
    const locks = object.get("locks") orelse return error.TransactionCorrupt;
    if (expected != .array or writes != .array or locks != .array) {
        return error.TransactionCorrupt;
    }
    const process_id = jsonInteger(
        owner_value.object.get("process_id") orelse return error.TransactionCorrupt,
    ) orelse return error.TransactionCorrupt;
    const session_id = try transactionStringField(owner_value.object, "session_id");
    const executor = try transactionStringField(owner_value.object, "executor");
    const created_at = try transactionStringField(object, "created_at");
    const updated_at = try transactionStringField(object, "updated_at");
    const format_hint = if (object.get("journal_format")) |value| hint: {
        const name = jsonString(value) orelse return error.TransactionCorrupt;
        break :hint parseTransactionRecordFormat(name) orelse return error.TransactionCorrupt;
    } else null;
    const bounded_rows = if (object.get("recovery_profile")) |value| profile: {
        const name = jsonString(value) orelse return error.TransactionCorrupt;
        if (!std.mem.eql(u8, name, "bounded-rows-v1")) return error.TransactionCorrupt;
        break :profile true;
    } else false;
    try validateTransactionRowBounds(
        bounded_rows,
        expected.array.items.len,
        writes.array.items.len,
        locks.array.items.len,
    );
    return .{
        .transaction_id = transaction_id,
        .state = state,
        .owner = .{ .process_id = process_id, .session_id = session_id, .executor = executor },
        .expected = expected.array.items,
        .writes = writes.array.items,
        .locks = locks.array.items,
        .created_at = created_at,
        .updated_at = updated_at,
        .format_hint = format_hint,
        .bounded_rows = bounded_rows,
    };
}

pub fn ownTransactionRecordFields(
    allocator: std.mem.Allocator,
    fields: TransactionRecordFields,
) !ParsedTransactionRecord {
    var result: ParsedTransactionRecord = .{
        .transaction_id = &.{},
        .owner = .{ .process_id = fields.owner.process_id, .session_id = &.{}, .executor = &.{} },
        .state = .preparing,
        .expected = &.{},
        .writes = &.{},
        .embedded_locks = &.{},
        .format_hint = fields.format_hint,
        .bounded_rows = fields.bounded_rows,
        .created_at = &.{},
        .updated_at = &.{},
    };
    errdefer result.deinit(allocator);
    result.transaction_id = try allocator.dupe(u8, fields.transaction_id);
    result.owner.session_id = try allocator.dupe(u8, fields.owner.session_id);
    result.owner.executor = try allocator.dupe(u8, fields.owner.executor);
    result.expected = try parseTransactionExpectedArray(allocator, fields.expected);
    result.writes = try parseTransactionWriteArray(allocator, fields.writes);
    result.embedded_locks = try parseTransactionLockArray(allocator, fields.locks);
    result.created_at = try allocator.dupe(u8, fields.created_at);
    result.updated_at = try allocator.dupe(u8, fields.updated_at);
    result.state = parseTransactionState(fields.state) orelse return error.TransactionCorrupt;
    return result;
}

fn validateTransactionRowBounds(
    bounded_rows: bool,
    expected_count: usize,
    write_count: usize,
    lock_count: usize,
) !void {
    if (bounded_rows and
        (expected_count > transaction_recovery_max_rows or
            write_count > transaction_recovery_max_rows or
            lock_count > transaction_recovery_max_rows))
    {
        return error.TransactionCorrupt;
    }
}

pub fn validateAutomaticRecoveryRowBounds(
    parsed: ParsedTransactionRecord,
) !void {
    if (parsed.expected.len > transaction_recovery_max_rows or
        parsed.writes.len > transaction_recovery_max_rows or
        parsed.embedded_locks.len > transaction_recovery_max_rows)
    {
        return error.TransactionRecoveryRequired;
    }
}

fn parseTransactionRecordFormat(text: []const u8) ?TransactionRecordFormat {
    inline for (.{ .current, .legacy }) |format| {
        const typed_format: TransactionRecordFormat = format;
        if (std.mem.eql(u8, text, @tagName(typed_format))) return typed_format;
    }
    return null;
}

fn parseTransactionState(text: []const u8) ?TransactionState {
    inline for (.{
        .preparing, .prepared, .committing, .committed, .aborted, .recovery_required,
    }) |state| {
        const typed_state: TransactionState = state;
        if (std.mem.eql(u8, text, typed_state.asString())) return typed_state;
    }
    return null;
}

fn parseTransactionExpectedArray(
    allocator: std.mem.Allocator,
    values: []std.json.Value,
) ![]TransactionExpected {
    var rows = try allocator.alloc(TransactionExpected, values.len);
    var count: usize = 0;
    errdefer {
        freeTransactionExpectedRows(allocator, rows[0..count]);
        allocator.free(rows);
    }
    for (values) |value| {
        if (value != .object) return error.TransactionCorrupt;
        const object = value.object;
        const sequence = jsonUnsigned(
            object.get("sequence") orelse return error.TransactionCorrupt,
        ) orelse return error.TransactionCorrupt;
        const path = try allocator.dupe(u8, try transactionStringField(object, "path"));
        errdefer allocator.free(path);
        const digest = try allocator.dupe(u8, try transactionStringField(object, "digest"));
        rows[count] = .{
            .path = path,
            .digest = digest,
            .sequence = sequence,
        };
        count += 1;
    }
    return rows;
}

fn parseTransactionWriteArray(
    allocator: std.mem.Allocator,
    values: []std.json.Value,
) ![]TransactionWrite {
    var rows = try allocator.alloc(TransactionWrite, values.len);
    var count: usize = 0;
    errdefer {
        freeTransactionWriteRows(allocator, rows[0..count]);
        allocator.free(rows);
    }
    for (values) |value| {
        if (value != .object) return error.TransactionCorrupt;
        const object = value.object;
        const sequence = jsonUnsigned(
            object.get("sequence_after") orelse
                return error.TransactionCorrupt,
        ) orelse return error.TransactionCorrupt;
        const path = try allocator.dupe(u8, try transactionStringField(object, "path"));
        errdefer allocator.free(path);
        const staged_ref = try allocator.dupe(u8, try transactionStringField(object, "staged_ref"));
        errdefer allocator.free(staged_ref);
        const digest = try allocator.dupe(u8, try transactionStringField(object, "digest_after"));
        rows[count] = .{
            .path = path,
            .staged_ref = staged_ref,
            .digest_after = digest,
            .sequence_after = sequence,
        };
        count += 1;
    }
    return rows;
}

fn parseTransactionLockArray(
    allocator: std.mem.Allocator,
    values: []std.json.Value,
) ![]LeaseLock {
    const rows = try allocator.alloc(LeaseLock, values.len);
    var count: usize = 0;
    errdefer {
        freeTransactionLockRows(allocator, rows[0..count]);
        allocator.free(rows);
    }
    for (values) |value| {
        rows[count] = try parseLeaseLockValue(allocator, value, null);
        count += 1;
    }
    return rows;
}

pub fn renderParsedTransactionRecordAlloc(
    allocator: std.mem.Allocator,
    parsed: ParsedTransactionRecord,
    state: TransactionState,
) ![]u8 {
    const format = try transactionRecordFormat(allocator, parsed);
    const transaction: DurableTransaction = .{
        .transaction_id = parsed.transaction_id,
        .owner = parsed.owner,
        .state = state,
        .expected = parsed.expected,
        .writes = parsed.writes,
        .locks = parsed.embedded_locks,
        .created_at = parsed.created_at,
        .updated_at = parsed.updated_at,
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try transaction.writeJsonWithFormatAndProfile(
        &out.writer,
        format,
        parsed.bounded_rows,
    );
    try out.writer.writeByte('\n');
    const bytes = try out.toOwnedSlice();
    errdefer allocator.free(bytes);
    if (bytes.len > transaction_record_max_bytes) {
        return error.FileTooBig;
    }
    return bytes;
}

pub fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.print("sha256:{s}", .{&hex});
}

pub fn jsonlSequenceOrNull(allocator: std.mem.Allocator, bytes: []const u8) !?u64 {
    const validation = try validateJsonlBytes(allocator, bytes);
    if (!validation.ok()) return null;
    return jsonlSequenceRequired(allocator, bytes);
}

pub fn jsonlSequenceRequired(allocator: std.mem.Allocator, bytes: []const u8) !?u64 {
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

pub const event_store_lock_dir_name = ".durable-store-locks";

pub fn rejectEventStoreControlNamespace(path: []const u8) !void {
    var components = std.fs.path.componentIterator(path);
    while (components.next()) |component| {
        if (std.ascii.eqlIgnoreCase(
            component.name,
            event_store_lock_dir_name,
        )) return error.ReservedStorePath;
    }
}

pub fn lockPathAlloc(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) ![]u8 {
    try rejectEventStoreControlNamespace(store_path);
    return allocator.print("{s}.lock", .{store_path});
}

pub fn lastJsonlSequence(
    allocator: std.mem.Allocator,
    data: []const u8,
    sequence_field: []const u8,
) !i64 {
    var last: []const u8 = "";
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len != 0) last = line;
    }
    if (last.len == 0) return 0;
    return jsonObjectSequence(allocator, last, sequence_field);
}

pub fn jsonObjectSequence(
    allocator: std.mem.Allocator,
    line: []const u8,
    sequence_field: []const u8,
) !i64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCheckpoint;
    const value = parsed.value.object.get(sequence_field) orelse return error.InvalidCheckpoint;
    if (value != .integer) return error.InvalidCheckpoint;
    return value.integer;
}

pub fn renderTransactionRecord(
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

pub fn validateJsonlBytes(allocator: std.mem.Allocator, data: []const u8) !JsonlValidation {
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
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (result.first_issue == null) {
                result.first_issue = .{ .line = line_no, .message = "invalid json" };
            }
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
    const next = try std.math.add(usize, max_seen, 1);
    return allocator.print("{s}{d:0>6}", .{ prefix, next });
}

pub fn parseMonotonicSuffix(prefix: []const u8, id: []const u8) ?usize {
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    if (id.len == prefix.len) return null;
    return std.fmt.parseInt(usize, id[prefix.len..], 10) catch null;
}

test "durable concurrency records render canonical json" {
    const owner: Owner = .{
        .process_id = 1234,
        .session_id = "session-a",
        .executor = "codex",
    };
    const lock: LeaseLock = .{
        .lock_id = "lock-1",
        .resource = "/repo/.ledger/plan.jsonl",
        .owner = owner,
        .acquired_at = "2026-06-25T14:00:00Z",
        .expires_at = "2026-06-25T14:00:05Z",
        .fencing_token = 7,
        .transaction_id = "txn-1",
        .path = "/repo/.ledger/plan.jsonl.lock",
    };
    var expected = [_]TransactionExpected{.{
        .path = "/repo/.ledger/plan.jsonl",
        .digest = "sha256:before",
        .sequence = 41,
    }};
    const writes = [_]TransactionWrite{.{
        .path = "/repo/.ledger/plan.jsonl",
        .staged_ref = "transactions/txn-1/plan.jsonl",
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

    try assertCanonicalLeaseJson(lock);
    try assertCanonicalCasReceiptJson();
    try assertCanonicalTransactionJson(transaction);
}

fn assertCanonicalTransactionJson(
    transaction: DurableTransaction,
) !void {
    var transaction_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer transaction_json.deinit();
    try transaction.writeJson(&transaction_json.writer);
    const transaction_bytes = try transaction_json.toOwnedSlice();
    defer std.testing.allocator.free(transaction_bytes);
    try std.testing.expectEqualStrings(
        "{\"transaction_version\":\"DTX-v1\",\"transaction_id\":\"txn-1\",\"owner\":{\"pr" ++
            "ocess_id\":1234,\"session_id\":\"session-a\",\"executor\":\"codex\"},\"state\":" ++
            "\"prepared\",\"expected\":[{\"path\":\"/repo/.ledger/plan.jsonl\",\"digest\":\"s" ++
            "ha256:before\",\"sequence\":41}],\"writes\":[{\"path\":\"/repo/.ledger/plan.json" ++
            "l\",\"staged_ref\":\"transactions/txn-1/plan.jsonl\",\"digest_after\":\"sha256:a" ++
            "fter\",\"sequence_after\":42}],\"locks\":[{\"lock_version\":\"DLK-v1\",\"lock_id" ++
            "\":\"lock-1\",\"resource\":\"/repo/.ledger/plan.jsonl\",\"owner\":{\"process_id" ++
            "\":1234,\"session_id\":\"session-a\",\"executor\":\"codex\"},\"acquired_at\":\"2" ++
            "026-06-25T14:00:00Z\",\"expires_at\":\"2026-06-25T14:00:05Z\",\"fencing_token\":" ++
            "7,\"transaction_id\":\"txn-1\"}],\"created_at\":\"2026-06-25T14:00:00Z\",\"updat" ++
            "ed_at\":\"2026-06-25T14:00:01Z\"}",
        transaction_bytes,
    );
}

fn assertCanonicalCasReceiptJson() !void {
    var cas_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer cas_json.deinit();
    try (CasWriteReceipt{
        .path = "/repo/.ledger/plan.jsonl",
        .digest_before = null,
        .digest_after = "sha256:after",
        .sequence_before = 41,
        .sequence_after = 42,
        .result = "written",
    }).writeJson(&cas_json.writer);
    const cas_bytes = try cas_json.toOwnedSlice();
    defer std.testing.allocator.free(cas_bytes);
    try std.testing.expectEqualStrings(
        "{\"cas_write_receipt\":{\"path\":\"/repo/.ledger/plan.jsonl\",\"digest_before\":" ++
            "null,\"digest_after\":\"sha256:after\",\"sequence_before\":41,\"sequence_after\"" ++
            ":42,\"result\":\"written\"}}",
        cas_bytes,
    );
}

fn assertCanonicalLeaseJson(
    lock: LeaseLock,
) !void {
    var lock_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lock_json.deinit();
    try lock.writeJson(&lock_json.writer);
    const lock_bytes = try lock_json.toOwnedSlice();
    defer std.testing.allocator.free(lock_bytes);
    try std.testing.expectEqualStrings(
        "{\"lock_version\":\"DLK-v1\",\"lock_id\":\"lock-1\",\"resource\":\"/repo/.ledger" ++
            "/plan.jsonl\",\"owner\":{\"process_id\":1234,\"session_id\":\"session-a\",\"exec" ++
            "utor\":\"codex\"},\"acquired_at\":\"2026-06-25T14:00:00Z\",\"expires_at\":\"2026" ++
            "-06-25T14:00:05Z\",\"fencing_token\":7,\"transaction_id\":\"txn-1\"}",
        lock_bytes,
    );
}

test "embedded locks identify write-free legacy transaction records" {
    var locks = [_]LeaseLock{.{
        .lock_id = "dlk-1-1",
        .resource = "/repo/events.jsonl",
        .owner = .{
            .process_id = 915,
            .session_id = "write-free-legacy-schema",
            .executor = "test",
        },
        .acquired_at = "1",
        .expires_at = "2",
        .fencing_token = 1,
        .path = "/repo/events.jsonl.lock",
    }};
    try std.testing.expectEqual(
        TransactionRecordFormat.legacy,
        try transactionRecordFormat(std.testing.allocator, .{
            .transaction_id = "dtx-1-00000000000000000000000000000011",
            .owner = .{
                .process_id = 915,
                .session_id = "write-free-legacy-schema",
                .executor = "test",
            },
            .state = .prepared,
            .expected = &.{},
            .writes = &.{},
            .embedded_locks = &locks,
            .created_at = "1",
            .updated_at = "2",
        }),
    );
}

test "current journals enforce the new row bound without rejecting legacy input" {
    try validateTransactionRowBounds(
        true,
        transaction_recovery_max_rows,
        transaction_recovery_max_rows,
        transaction_recovery_max_rows,
    );
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRowBounds(true, transaction_recovery_max_rows + 1, 0, 0),
    );
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRowBounds(true, 0, transaction_recovery_max_rows + 1, 0),
    );
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRowBounds(true, 0, 0, transaction_recovery_max_rows + 1),
    );
    try validateTransactionRowBounds(
        false,
        transaction_recovery_max_rows + 1,
        transaction_recovery_max_rows + 1,
        transaction_recovery_max_rows + 1,
    );
    try validateTransactionRowBounds(
        false,
        transaction_recovery_max_rows + 1,
        transaction_recovery_max_rows + 1,
        transaction_recovery_max_rows + 1,
    );
}

test "recovery record rewrites reject output above the parser byte limit" {
    const allocator = std.testing.allocator;
    const oversized = try allocator.alloc(u8, transaction_record_max_bytes);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.FileTooBig,
        renderParsedTransactionRecordAlloc(
            allocator,
            .{
                .transaction_id = "dtx-1-00000000000000000000000000000063",
                .owner = .{
                    .process_id = 963,
                    .session_id = oversized,
                    .executor = "test",
                },
                .state = .prepared,
                .expected = &.{},
                .writes = &.{},
                .created_at = "1",
                .updated_at = "2",
            },
            .committed,
        ),
    );
}

test "validateJsonlBytes reports first invalid row" {
    const valid = try validateJsonlBytes(std.testing.allocator, "{\"a\":1}\n\n{\"b\":2}\n");
    try std.testing.expect(valid.ok());
    try std.testing.expectEqual(@as(usize, 2), valid.lines);

    const invalid = try validateJsonlBytes(std.testing.allocator, "{\"a\":1}\nnot-json\n");
    try std.testing.expect(!invalid.ok());
    try std.testing.expectEqual(@as(usize, 2), invalid.first_issue.?.line);
}

test "nextMonotonicIdAlloc scans matching numeric suffixes" {
    const ids = [_][]const u8{ "NEG-000001", "other", "NEG-000010", "NEG-bad" };
    const next = try nextMonotonicIdAlloc(std.testing.allocator, "NEG-", &ids);
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("NEG-000011", next);
}

const transaction_allocation_json =
    \\{"transaction_version":"DTX-v1","transaction_id":"dtx-1","state":"prepared",
    \\"owner":{"process_id":42,"session_id":"copy-owner","executor":"test"},
    \\"expected":[{"path":"/repo/a","digest":"sha256:before-a","sequence":1},
    \\{"path":"/repo/b","digest":"sha256:before-b","sequence":2}],
    \\"writes":[{"path":"/repo/a","staged_ref":"write-0.staged",
    \\"digest_after":"sha256:after-a","sequence_after":3},
    \\{"path":"/repo/b","staged_ref":"write-1.staged",
    \\"digest_after":"sha256:after-b","sequence_after":4}],
    \\"locks":[{"lock_version":"DLK-v1","lock_id":"lock-copy","resource":"/repo/a",
    \\"owner":{"process_id":43,"session_id":"lease-owner","executor":"lease-test"},
    \\"acquired_at":"10","expires_at":"20","fencing_token":7,"transaction_id":"dtx-1"}],
    \\"created_at":"1","updated_at":"2"}
;

test "owned transaction fields survive parser disposal at every allocation boundary" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        checkOwnedTransactionFieldsAllocation,
        .{},
    );
}

fn checkOwnedTransactionFieldsAllocation(allocator: std.mem.Allocator) !void {
    const record = ownedTransactionAllocationCase(allocator);
    const owned = try record;
    defer owned.deinit(allocator);
    // The JSON parser and all of its allocated strings are already gone here.
    try std.testing.expectEqualStrings("dtx-1", owned.transaction_id);
    try std.testing.expectEqualStrings("copy-owner", owned.owner.session_id);
    try std.testing.expectEqualStrings("test", owned.owner.executor);
    try std.testing.expectEqual(@as(i64, 42), owned.owner.process_id);
    try std.testing.expectEqual(.prepared, owned.state);
    try std.testing.expectEqual(@as(?TransactionRecordFormat, null), owned.format_hint);
    try std.testing.expect(!owned.bounded_rows);
    try std.testing.expectEqualStrings("1", owned.created_at);
    try std.testing.expectEqualStrings("2", owned.updated_at);
    try std.testing.expectEqual(@as(usize, 2), owned.expected.len);
    try std.testing.expectEqual(@as(usize, 2), owned.writes.len);
    try std.testing.expectEqual(@as(usize, 1), owned.embedded_locks.len);
    try assertOwnedTransactionRows(owned);
    try assertOwnedTransactionLock(owned.embedded_locks[0]);
}

fn ownedTransactionAllocationCase(allocator: std.mem.Allocator) !ParsedTransactionRecord {
    var json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        transaction_allocation_json,
        .{ .allocate = .alloc_always },
    );
    defer json.deinit();
    const fields = try transactionRecordFields(json.value.object);
    return ownTransactionRecordFields(allocator, fields);
}

fn assertOwnedTransactionRows(record: ParsedTransactionRecord) !void {
    const paths = [_][]const u8{ "/repo/a", "/repo/b" };
    const before = [_][]const u8{ "sha256:before-a", "sha256:before-b" };
    const after = [_][]const u8{ "sha256:after-a", "sha256:after-b" };
    const stages = [_][]const u8{ "write-0.staged", "write-1.staged" };
    for (paths, before, after, stages, 0..) |path, digest_before, digest_after, stage, index| {
        try std.testing.expectEqualStrings(path, record.expected[index].path);
        try std.testing.expectEqualStrings(digest_before, record.expected[index].digest);
        try std.testing.expectEqual(@as(u64, index + 1), record.expected[index].sequence);
        try std.testing.expectEqualStrings(path, record.writes[index].path);
        try std.testing.expectEqualStrings(digest_after, record.writes[index].digest_after);
        try std.testing.expectEqualStrings(stage, record.writes[index].staged_ref);
        try std.testing.expectEqual(@as(u64, index + 3), record.writes[index].sequence_after);
    }
}

fn assertOwnedTransactionLock(lock: LeaseLock) !void {
    try std.testing.expectEqualStrings("lock-copy", lock.lock_id);
    try std.testing.expectEqualStrings("/repo/a", lock.resource);
    try std.testing.expectEqualStrings("lease-owner", lock.owner.session_id);
    try std.testing.expectEqualStrings("lease-test", lock.owner.executor);
    try std.testing.expectEqual(@as(i64, 43), lock.owner.process_id);
    try std.testing.expectEqualStrings("10", lock.acquired_at);
    try std.testing.expectEqualStrings("20", lock.expires_at);
    try std.testing.expectEqual(@as(u64, 7), lock.fencing_token);
    try std.testing.expectEqualStrings("dtx-1", lock.transaction_id.?);
    try std.testing.expectEqualStrings("/repo/a.lock", lock.path);
}

test "monotonic ids reject exhausted numeric space" {
    const exhausted = std.fmt.comptimePrint("id-{d}", .{std.math.maxInt(usize)});
    try std.testing.expectError(
        error.Overflow,
        nextMonotonicIdAlloc(std.testing.allocator, "id-", &.{exhausted}),
    );
}
