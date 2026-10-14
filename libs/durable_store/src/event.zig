const std = @import("std");
const jsonl_core = @import("jsonl_core");

pub const EventRecord = struct {
    payload: []u8,
    ordinal: u64,
    diagnostic_position: ?usize = null,

    pub fn deinit(self: *EventRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = .{ .payload = &.{}, .ordinal = 0 };
    }
};

pub const EventSnapshot = struct {
    logical_ref: []u8,
    exists: bool,
    revision: []u8,
    content_digest: []u8,
    records: []EventRecord,
    blank_entries: usize = 0,
    extent_bytes: usize = 0,
    append_separator_bytes: usize = 0,

    pub fn deinit(self: *EventSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.logical_ref);
        allocator.free(self.revision);
        allocator.free(self.content_digest);
        for (self.records) |*record| record.deinit(allocator);
        allocator.free(self.records);
        self.* = .{
            .logical_ref = &.{},
            .exists = false,
            .revision = &.{},
            .content_digest = &.{},
            .records = &.{},
        };
    }
};

pub const EventRecordView = struct {
    /// Borrowed only for the active EventRecordVisitor.visit call.
    /// Visitors must copy payload bytes that need to outlive that call.
    payload: []const u8,
    ordinal: u64,
    diagnostic_position: ?usize = null,
    extent_start: usize,
    extent_end: usize,
};

pub const EventRecordVisitor = struct {
    /// Scans stream records before the complete source is known valid. A later
    /// read, size, allocation, or visitor error does not roll back completed
    /// calls. Callers that retry a failed scan must make visitFn side-effect
    /// free or idempotent for records already observed by that attempt.
    context: *anyopaque,
    visitFn: *const fn (context: *anyopaque, record: EventRecordView) anyerror!void,
    rawFn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!void = null,

    pub fn visit(self: EventRecordVisitor, record: EventRecordView) !void {
        try self.visitFn(self.context, record);
    }

    pub fn observeRaw(self: EventRecordVisitor, bytes: []const u8) !void {
        if (self.rawFn) |observe| try observe(self.context, bytes);
    }
};

pub const EventScanSummary = struct {
    logical_ref: []u8,
    exists: bool,
    revision: []u8,
    content_digest: []u8,
    record_count: usize,
    blank_entries: usize = 0,
    extent_bytes: usize = 0,
    append_separator_bytes: usize = 0,
    append_context: EventAppendContext = .{},

    pub fn deinit(self: *EventScanSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.logical_ref);
        allocator.free(self.revision);
        allocator.free(self.content_digest);
        self.* = .{
            .logical_ref = &.{},
            .exists = false,
            .revision = &.{},
            .content_digest = &.{},
            .record_count = 0,
        };
    }
};

pub const EventAppendContext = struct {
    raw_hash: EventHash = EventHash.init(.{}),
    extent_bytes: usize = 0,
    separator_bytes: usize = 0,

    pub fn fromBytes(bytes: []const u8) EventAppendContext {
        var raw_hash = EventHash.init(.{});
        raw_hash.update(bytes);
        return .{
            .raw_hash = raw_hash,
            .extent_bytes = bytes.len,
            .separator_bytes = if (bytes.len != 0 and
                bytes[bytes.len - 1] != '\n') 1 else 0,
        };
    }

    pub fn revisionWithSuffixAlloc(
        self: EventAppendContext,
        allocator: std.mem.Allocator,
        suffix: []const u8,
    ) ![]u8 {
        var hash = self.raw_hash;
        hash.update(suffix);
        return finishEventHashAlloc(allocator, &hash);
    }
};

pub const EventAppendExpectation = struct {
    revision: ?[]const u8 = null,
    exists: ?bool = null,
};

pub const EventAppendReceipt = struct {
    logical_ref: []u8,
    revision_before: []u8,
    revision_after: []u8,
    content_digest_after: []u8,
    record_count_before: usize,
    record_count_after: usize,

    pub fn deinit(self: *EventAppendReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.logical_ref);
        allocator.free(self.revision_before);
        allocator.free(self.revision_after);
        allocator.free(self.content_digest_after);
        self.* = .{
            .logical_ref = &.{},
            .revision_before = &.{},
            .revision_after = &.{},
            .content_digest_after = &.{},
            .record_count_before = 0,
            .record_count_after = 0,
        };
    }
};

pub const EventStoreExclusive = struct {
    context: *anyopaque,
    vtable: *const VTable,
    active: bool = true,
    scan_active: bool = false,
    release_pending: bool = false,

    pub const VTable = struct {
        scan: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            max_bytes: usize,
            visitor: EventRecordVisitor,
        ) anyerror!EventScanSummary,
        snapshot: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            max_bytes: usize,
        ) anyerror!EventSnapshot,
        append: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            payload: []const u8,
            expectation: EventAppendExpectation,
            max_bytes: usize,
        ) anyerror!EventAppendReceipt,
        replace: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            records: []const []const u8,
            expectation: EventAppendExpectation,
            max_bytes: usize,
        ) anyerror!EventAppendReceipt,
        release: *const fn (context: *anyopaque) void,
    };

    pub fn scan(
        self: *EventStoreExclusive,
        allocator: std.mem.Allocator,
        max_bytes: usize,
        visitor: EventRecordVisitor,
    ) !EventScanSummary {
        if (!self.active) return error.EventStoreSessionReleased;
        if (self.scan_active) return error.EventStoreBusy;
        self.scan_active = true;
        defer {
            self.scan_active = false;
            if (self.release_pending) {
                self.release_pending = false;
                self.vtable.release(self.context);
            }
        }
        return self.vtable.scan(self.context, allocator, max_bytes, visitor);
    }

    pub fn snapshot(
        self: *const EventStoreExclusive,
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) !EventSnapshot {
        if (!self.active) return error.EventStoreSessionReleased;
        return self.vtable.snapshot(self.context, allocator, max_bytes);
    }

    pub fn append(
        self: *const EventStoreExclusive,
        allocator: std.mem.Allocator,
        payload: []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        if (!self.active) return error.EventStoreSessionReleased;
        return self.vtable.append(self.context, allocator, payload, expectation, max_bytes);
    }

    pub fn replace(
        self: *const EventStoreExclusive,
        allocator: std.mem.Allocator,
        records: []const []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        if (!self.active) return error.EventStoreSessionReleased;
        return self.vtable.replace(self.context, allocator, records, expectation, max_bytes);
    }

    pub fn release(self: *EventStoreExclusive) void {
        if (!self.active) return;
        self.active = false;
        if (self.scan_active) {
            self.release_pending = true;
            return;
        }
        self.vtable.release(self.context);
    }
};

pub const EventStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        logicalRef: *const fn (context: *anyopaque) []const u8,
        scan: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            max_bytes: usize,
            visitor: EventRecordVisitor,
        ) anyerror!EventScanSummary,
        snapshot: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            max_bytes: usize,
        ) anyerror!EventSnapshot,
        append: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            payload: []const u8,
            expectation: EventAppendExpectation,
            max_bytes: usize,
        ) anyerror!EventAppendReceipt,
        replace: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            records: []const []const u8,
            expectation: EventAppendExpectation,
            max_bytes: usize,
        ) anyerror!EventAppendReceipt,
        acquireExclusive: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror!EventStoreExclusive,
    };

    pub fn logicalRef(self: EventStore) []const u8 {
        return self.vtable.logicalRef(self.context);
    }

    pub fn scan(
        self: EventStore,
        allocator: std.mem.Allocator,
        max_bytes: usize,
        visitor: EventRecordVisitor,
    ) !EventScanSummary {
        return self.vtable.scan(self.context, allocator, max_bytes, visitor);
    }

    pub fn snapshot(
        self: EventStore,
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) !EventSnapshot {
        return self.vtable.snapshot(self.context, allocator, max_bytes);
    }

    pub fn append(
        self: EventStore,
        allocator: std.mem.Allocator,
        payload: []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        return self.vtable.append(self.context, allocator, payload, expectation, max_bytes);
    }

    pub fn replace(
        self: EventStore,
        allocator: std.mem.Allocator,
        records: []const []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        return self.vtable.replace(self.context, allocator, records, expectation, max_bytes);
    }

    pub fn acquireExclusive(self: EventStore, allocator: std.mem.Allocator) !EventStoreExclusive {
        return self.vtable.acquireExclusive(self.context, allocator);
    }
};

pub fn validateEventPayload(allocator: std.mem.Allocator, payload: []const u8) !void {
    if (payload.len == 0 or std.mem.indexOfScalar(u8, payload, '\n') != null or
        std.mem.indexOfScalar(u8, payload, '\r') != null)
    {
        return error.InvalidEventPayload;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidEventPayload,
        };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEventPayload;
}

pub const SnapshotCollector = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(EventRecord) = .empty,

    pub fn init(allocator: std.mem.Allocator) SnapshotCollector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SnapshotCollector) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    pub fn visitor(self: *SnapshotCollector) EventRecordVisitor {
        return .{ .context = self, .visitFn = visit };
    }

    fn visit(context: *anyopaque, record: EventRecordView) !void {
        const self: *SnapshotCollector = @ptrCast(@alignCast(context));
        const payload = try self.allocator.dupe(u8, record.payload);
        errdefer self.allocator.free(payload);
        try self.records.append(self.allocator, .{
            .payload = payload,
            .ordinal = record.ordinal,
            .diagnostic_position = record.diagnostic_position,
        });
    }

    pub fn finish(self: *SnapshotCollector, summary: *EventScanSummary) !EventSnapshot {
        const records = try self.records.toOwnedSlice(self.allocator);
        self.records = .empty;
        const snapshot = EventSnapshot{
            .logical_ref = summary.logical_ref,
            .exists = summary.exists,
            .revision = summary.revision,
            .content_digest = summary.content_digest,
            .records = records,
            .blank_entries = summary.blank_entries,
            .extent_bytes = summary.extent_bytes,
            .append_separator_bytes = summary.append_separator_bytes,
        };
        summary.logical_ref = &.{};
        summary.revision = &.{};
        summary.content_digest = &.{};
        return snapshot;
    }
};

pub const EventHash = std.crypto.hash.sha2.Sha256;

pub const max_event_record_bytes: usize = 16 * 1024 * 1024;

const RawHashObserver = struct {
    hash: *EventHash,
    visitor: EventRecordVisitor,
    max_bytes: usize,
    bytes_observed: usize = 0,
    last_byte: ?u8 = null,

    fn observe(context: *anyopaque, bytes: []const u8) !void {
        const self: *RawHashObserver = @ptrCast(@alignCast(context));
        const bytes_observed = std.math.add(
            usize,
            self.bytes_observed,
            bytes.len,
        ) catch return error.StreamTooLong;
        if (bytes_observed > self.max_bytes) return error.StreamTooLong;
        self.bytes_observed = bytes_observed;
        self.hash.update(bytes);
        try self.visitor.observeRaw(bytes);
        if (bytes.len != 0) self.last_byte = bytes[bytes.len - 1];
    }
};

pub fn scanEventReader(
    allocator: std.mem.Allocator,
    logical_ref: []const u8,
    max_bytes: usize,
    visitor: EventRecordVisitor,
    reader: *std.Io.Reader,
) !EventScanSummary {
    var raw_hash = EventHash.init(.{});
    var canonical_hash = EventHash.init(.{});
    var raw_observer = RawHashObserver{
        .hash = &raw_hash,
        .visitor = visitor,
        .max_bytes = max_bytes,
    };
    var stream = try jsonl_core.Stream.init(allocator, reader, .{
        .max_line_bytes = @max(
            @min(max_bytes, max_event_record_bytes),
            1,
        ),
        .chunk_observer = .{
            .context = &raw_observer,
            .observeFn = RawHashObserver.observe,
        },
    });
    defer stream.deinit();

    const counts = try visitEventLines(&stream, &canonical_hash, visitor);
    return finishEventScanSummary(
        allocator,
        logical_ref,
        true,
        &raw_hash,
        &canonical_hash,
        counts.records,
        counts.blank_entries,
        stream.bytes_read,
        if (stream.bytes_read != 0 and raw_observer.last_byte.? != '\n') 1 else 0,
    );
}

const EventLineCounts = struct {
    records: usize,
    blank_entries: usize,
};

fn visitEventLines(
    stream: *jsonl_core.Stream,
    canonical_hash: *EventHash,
    visitor: EventRecordVisitor,
) !EventLineCounts {
    var record_count: usize = 0;
    var blank_entries: usize = 0;
    while (try stream.next()) |line| {
        const payload = std.mem.trim(u8, line.bytes, " \t\r\n");
        if (payload.len == 0) {
            blank_entries += 1;
            continue;
        }
        record_count += 1;
        canonical_hash.update(payload);
        canonical_hash.update("\n");
        const leading = std.mem.trimStart(u8, line.bytes, " \t\r\n");
        const payload_start = line.start_offset +
            (line.bytes.len - leading.len);
        try visitor.visit(.{
            .payload = payload,
            .ordinal = @intCast(record_count),
            .diagnostic_position = line.number,
            .extent_start = payload_start,
            .extent_end = payload_start + payload.len,
        });
    }
    return .{ .records = record_count, .blank_entries = blank_entries };
}

pub fn emptyEventScanSummary(
    allocator: std.mem.Allocator,
    logical_ref: []const u8,
    exists: bool,
) !EventScanSummary {
    var raw_hash = EventHash.init(.{});
    var canonical_hash = EventHash.init(.{});
    return finishEventScanSummary(
        allocator,
        logical_ref,
        exists,
        &raw_hash,
        &canonical_hash,
        0,
        0,
        0,
        0,
    );
}

pub fn finishEventScanSummary(
    allocator: std.mem.Allocator,
    logical_ref: []const u8,
    exists: bool,
    raw_hash: *EventHash,
    canonical_hash: *EventHash,
    record_count: usize,
    blank_entries: usize,
    extent_bytes: usize,
    append_separator_bytes: usize,
) !EventScanSummary {
    const append_context: EventAppendContext = .{
        .raw_hash = raw_hash.*,
        .extent_bytes = extent_bytes,
        .separator_bytes = append_separator_bytes,
    };
    const owned_logical_ref = try allocator.dupe(u8, logical_ref);
    errdefer allocator.free(owned_logical_ref);
    const revision = try finishEventHashAlloc(allocator, raw_hash);
    errdefer allocator.free(revision);
    const content_digest = try finishEventHashAlloc(allocator, canonical_hash);
    errdefer allocator.free(content_digest);
    return .{
        .logical_ref = owned_logical_ref,
        .exists = exists,
        .revision = revision,
        .content_digest = content_digest,
        .record_count = record_count,
        .blank_entries = blank_entries,
        .extent_bytes = extent_bytes,
        .append_separator_bytes = append_separator_bytes,
        .append_context = append_context,
    };
}

fn finishEventHashAlloc(allocator: std.mem.Allocator, hash: *EventHash) ![]u8 {
    var digest: [EventHash.digest_length]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.print("sha256:{s}", .{&hex});
}

pub fn ignoreEventRecord(_: *anyopaque, _: EventRecordView) !void {}

pub fn validateEventExpectation(
    snapshot: EventScanSummary,
    expectation: EventAppendExpectation,
) !void {
    if (expectation.exists) |expected| {
        if (expected != snapshot.exists) return error.ExpectationMismatch;
    }
    if (expectation.revision) |expected| {
        if (!std.mem.eql(u8, expected, snapshot.revision)) return error.ExpectationMismatch;
    }
}

pub fn validateEventAppendFits(
    snapshot: EventScanSummary,
    payload_len: usize,
    max_bytes: usize,
) !void {
    if (snapshot.extent_bytes > max_bytes or payload_len >= max_bytes) return error.StreamTooLong;
    const additional = payload_len + 1 + snapshot.append_separator_bytes;
    if (additional > max_bytes - snapshot.extent_bytes) return error.StreamTooLong;
}

pub fn eventAppendReceipt(
    allocator: std.mem.Allocator,
    before: EventScanSummary,
    after: EventScanSummary,
) !EventAppendReceipt {
    const logical_ref = try allocator.dupe(u8, after.logical_ref);
    errdefer allocator.free(logical_ref);
    const revision_before = try allocator.dupe(u8, before.revision);
    errdefer allocator.free(revision_before);
    const revision_after = try allocator.dupe(u8, after.revision);
    errdefer allocator.free(revision_after);
    const content_digest_after = try allocator.dupe(u8, after.content_digest);
    errdefer allocator.free(content_digest_after);
    return .{
        .logical_ref = logical_ref,
        .revision_before = revision_before,
        .revision_after = revision_after,
        .content_digest_after = content_digest_after,
        .record_count_before = before.record_count,
        .record_count_after = after.record_count,
    };
}

pub fn renderEventRecordsAlloc(allocator: std.mem.Allocator, records: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (records) |payload| {
        out.writer.writeAll(payload) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}
