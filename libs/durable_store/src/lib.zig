const std = @import("std");
const jsonl_core = @import("jsonl_core");

const Io = std.Io.Threaded.global_single_threaded;
const GitCheckOutputLimit = 4 * 1024;
threadlocal var runtime_io: ?std.Io = null;

/// Installs the process-owned I/O implementation used by default persistent
/// store constructors reached through composed CLI subcommands.
pub fn installRuntimeIo(io: std.Io) void {
    runtime_io = io;
}

fn mutationAdmissionIo() !std.Io {
    return runtime_io orelse
        if (@import("builtin").is_test) std.testing.io else error.EventStoreIoUnavailable;
}

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
        snapshot: *const fn (context: *anyopaque, allocator: std.mem.Allocator, max_bytes: usize) anyerror!EventSnapshot,
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

    pub fn snapshot(self: *const EventStoreExclusive, allocator: std.mem.Allocator, max_bytes: usize) !EventSnapshot {
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
        snapshot: *const fn (context: *anyopaque, allocator: std.mem.Allocator, max_bytes: usize) anyerror!EventSnapshot,
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
        acquireExclusive: *const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!EventStoreExclusive,
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

    pub fn snapshot(self: EventStore, allocator: std.mem.Allocator, max_bytes: usize) !EventSnapshot {
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

/// Stable construction surface for repo-local persistent event stores.
/// The locator is a logical store identity; the current compatibility adapter
/// interprets it as a JSONL path. Source callers depend only on EventStore.
pub const PersistentEventStore = struct {
    adapter: JsonlEventStore,

    pub fn init(locator: []const u8) PersistentEventStore {
        return .{ .adapter = JsonlEventStore.init(locator) };
    }

    pub fn initWithIo(locator: []const u8, io: std.Io) PersistentEventStore {
        return .{ .adapter = JsonlEventStore.initWithIo(locator, io) };
    }

    pub fn eventStore(self: *PersistentEventStore) EventStore {
        return self.adapter.eventStore();
    }
};

pub const JsonlEventStore = struct {
    path: []const u8,
    io: ?std.Io = null,
    scan_active: bool = false,
    mutation_admission_checked: bool = false,

    pub fn init(path: []const u8) JsonlEventStore {
        return .{ .path = path };
    }

    pub fn initWithIo(path: []const u8, io: std.Io) JsonlEventStore {
        return .{ .path = path, .io = io };
    }

    pub fn eventStore(self: *JsonlEventStore) EventStore {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = EventStore.VTable{
        .logicalRef = logicalRef,
        .scan = scan,
        .snapshot = snapshot,
        .append = append,
        .replace = replace,
        .acquireExclusive = acquireExclusive,
    };

    const ExclusiveContext = struct {
        allocator: std.mem.Allocator,
        store: *JsonlEventStore,
        lock: EventStoreExclusiveLock,
    };

    const ScanOwnership = enum {
        acquire_shared,
        exclusive_held,
    };

    const exclusive_vtable = EventStoreExclusive.VTable{
        .scan = exclusiveScan,
        .snapshot = exclusiveSnapshot,
        .append = exclusiveAppend,
        .replace = exclusiveReplace,
        .release = releaseExclusive,
    };

    fn cast(context: *anyopaque) *JsonlEventStore {
        return @ptrCast(@alignCast(context));
    }

    fn logicalRef(context: *anyopaque) []const u8 {
        return cast(context).path;
    }

    fn scan(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        max_bytes: usize,
        visitor: EventRecordVisitor,
    ) !EventScanSummary {
        return scanWithOwnership(
            cast(context),
            allocator,
            max_bytes,
            visitor,
            .acquire_shared,
        );
    }

    fn scanWithOwnership(
        self: *JsonlEventStore,
        allocator: std.mem.Allocator,
        max_bytes: usize,
        visitor: EventRecordVisitor,
        ownership: ScanOwnership,
    ) !EventScanSummary {
        if (self.scan_active) return error.EventStoreBusy;
        self.scan_active = true;
        defer self.scan_active = false;
        return scanJsonlEventStore(
            allocator,
            self.path,
            max_bytes,
            visitor,
            ownership == .acquire_shared,
        );
    }

    fn snapshot(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) !EventSnapshot {
        var collector = SnapshotCollector.init(allocator);
        defer collector.deinit();
        var summary = try scan(context, allocator, max_bytes, collector.visitor());
        defer summary.deinit(allocator);
        return collector.finish(&summary);
    }

    fn append(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        payload: []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        if (cast(context).scan_active) return error.EventStoreBusy;
        var exclusive = acquireExclusive(context, allocator) catch |err| switch (err) {
            error.EventStoreBusy => return error.PathAlreadyExists,
            else => return err,
        };
        defer exclusive.release();
        return exclusive.append(allocator, payload, expectation, max_bytes);
    }

    fn replace(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        records: []const []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        if (cast(context).scan_active) return error.EventStoreBusy;
        var exclusive = acquireExclusive(context, allocator) catch |err| switch (err) {
            error.EventStoreBusy => return error.PathAlreadyExists,
            else => return err,
        };
        defer exclusive.release();
        return exclusive.replace(allocator, records, expectation, max_bytes);
    }

    fn acquireExclusive(context: *anyopaque, allocator: std.mem.Allocator) !EventStoreExclusive {
        const self = cast(context);
        if (self.scan_active) return error.EventStoreBusy;
        if (!self.mutation_admission_checked) {
            const io = self.io orelse try mutationAdmissionIo();
            try ensureLockSidecarGitignored(allocator, io, self.path);
            self.mutation_admission_checked = true;
        }
        const exclusive = try allocator.create(ExclusiveContext);
        errdefer allocator.destroy(exclusive);
        const lock = acquireEventStoreExclusiveLock(allocator, self.path) catch |err| switch (err) {
            error.WouldBlock => return error.EventStoreBusy,
            else => return err,
        };
        exclusive.* = .{ .allocator = allocator, .store = self, .lock = lock };
        return .{ .context = exclusive, .vtable = &exclusive_vtable };
    }

    fn exclusiveCast(context: *anyopaque) *ExclusiveContext {
        return @ptrCast(@alignCast(context));
    }

    fn exclusiveScan(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        max_bytes: usize,
        visitor: EventRecordVisitor,
    ) !EventScanSummary {
        return scanWithOwnership(
            exclusiveCast(context).store,
            allocator,
            max_bytes,
            visitor,
            .exclusive_held,
        );
    }

    fn exclusiveSnapshot(context: *anyopaque, allocator: std.mem.Allocator, max_bytes: usize) !EventSnapshot {
        const exclusive = exclusiveCast(context);
        var collector = SnapshotCollector.init(allocator);
        defer collector.deinit();
        var summary = try scanWithOwnership(
            exclusive.store,
            allocator,
            max_bytes,
            collector.visitor(),
            .exclusive_held,
        );
        defer summary.deinit(allocator);
        return collector.finish(&summary);
    }

    fn exclusiveAppend(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        payload: []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        const exclusive = exclusiveCast(context);
        if (exclusive.store.scan_active) return error.EventStoreBusy;
        try validateEventPayload(allocator, payload);
        var ignored: u8 = 0;
        const visitor = EventRecordVisitor{ .context = &ignored, .visitFn = ignoreEventRecord };
        var before = try scanWithOwnership(
            exclusive.store,
            allocator,
            max_bytes,
            visitor,
            .exclusive_held,
        );
        defer before.deinit(allocator);
        try validateEventExpectation(before, expectation);
        try validateEventAppendFits(before, payload.len, max_bytes);
        try appendLineAtomic(allocator, exclusive.store.path, payload, max_bytes);
        var after = try scanWithOwnership(
            exclusive.store,
            allocator,
            max_bytes,
            visitor,
            .exclusive_held,
        );
        defer after.deinit(allocator);
        return eventAppendReceipt(allocator, before, after);
    }

    fn exclusiveReplace(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        records: []const []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        const exclusive = exclusiveCast(context);
        if (exclusive.store.scan_active) return error.EventStoreBusy;
        for (records) |payload| try validateEventPayload(allocator, payload);
        var ignored: u8 = 0;
        const visitor = EventRecordVisitor{ .context = &ignored, .visitFn = ignoreEventRecord };
        var before = try scanWithOwnership(
            exclusive.store,
            allocator,
            max_bytes,
            visitor,
            .exclusive_held,
        );
        defer before.deinit(allocator);
        try validateEventExpectation(before, expectation);
        const text = try renderEventRecordsAlloc(allocator, records);
        defer allocator.free(text);
        if (text.len > max_bytes) return error.StreamTooLong;
        try writeTextAtomic(allocator, exclusive.store.path, text);
        var after = try scanWithOwnership(
            exclusive.store,
            allocator,
            max_bytes,
            visitor,
            .exclusive_held,
        );
        defer after.deinit(allocator);
        return eventAppendReceipt(allocator, before, after);
    }

    fn releaseExclusive(context: *anyopaque) void {
        const exclusive = exclusiveCast(context);
        exclusive.lock.release();
        const allocator = exclusive.allocator;
        allocator.destroy(exclusive);
    }
};

pub const MemoryEventStore = struct {
    allocator: std.mem.Allocator,
    logical_ref: []const u8,
    exists: bool = false,
    exclusive_active: bool = false,
    scan_active: bool = false,
    records: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, logical_ref: []const u8) MemoryEventStore {
        return .{ .allocator = allocator, .logical_ref = logical_ref };
    }

    pub fn deinit(self: *MemoryEventStore) void {
        for (self.records.items) |record| self.allocator.free(record);
        self.records.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator, .logical_ref = self.logical_ref };
    }

    pub fn eventStore(self: *MemoryEventStore) EventStore {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = EventStore.VTable{
        .logicalRef = logicalRef,
        .scan = scan,
        .snapshot = snapshot,
        .append = append,
        .replace = replace,
        .acquireExclusive = acquireExclusive,
    };

    const ExclusiveContext = struct {
        allocator: std.mem.Allocator,
        store: *MemoryEventStore,
    };

    const exclusive_vtable = EventStoreExclusive.VTable{
        .scan = exclusiveScan,
        .snapshot = exclusiveSnapshot,
        .append = exclusiveAppend,
        .replace = exclusiveReplace,
        .release = releaseExclusive,
    };

    fn cast(context: *anyopaque) *MemoryEventStore {
        return @ptrCast(@alignCast(context));
    }

    fn logicalRef(context: *anyopaque) []const u8 {
        return cast(context).logical_ref;
    }

    fn scan(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        max_bytes: usize,
        visitor: EventRecordVisitor,
    ) !EventScanSummary {
        const self = cast(context);
        if (self.exclusive_active) return error.EventStoreBusy;
        return scanWithOwnedState(self, allocator, max_bytes, visitor);
    }

    fn scanWithOwnedState(
        self: *MemoryEventStore,
        allocator: std.mem.Allocator,
        max_bytes: usize,
        visitor: EventRecordVisitor,
    ) !EventScanSummary {
        if (self.scan_active) return error.EventStoreBusy;
        self.scan_active = true;
        defer self.scan_active = false;
        return scanMemoryEventStore(allocator, self, max_bytes, visitor);
    }

    fn snapshot(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) !EventSnapshot {
        var collector = SnapshotCollector.init(allocator);
        defer collector.deinit();
        var summary = try scan(context, allocator, max_bytes, collector.visitor());
        defer summary.deinit(allocator);
        return collector.finish(&summary);
    }

    fn append(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        payload: []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        var exclusive = try acquireExclusive(context, allocator);
        defer exclusive.release();
        return exclusive.append(allocator, payload, expectation, max_bytes);
    }

    fn replace(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        records: []const []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        var exclusive = try acquireExclusive(context, allocator);
        defer exclusive.release();
        return exclusive.replace(allocator, records, expectation, max_bytes);
    }

    fn acquireExclusive(context: *anyopaque, allocator: std.mem.Allocator) !EventStoreExclusive {
        const self = cast(context);
        if (self.exclusive_active or self.scan_active) return error.EventStoreBusy;
        const exclusive = try allocator.create(ExclusiveContext);
        exclusive.* = .{ .allocator = allocator, .store = self };
        self.exclusive_active = true;
        return .{ .context = exclusive, .vtable = &exclusive_vtable };
    }

    fn exclusiveCast(context: *anyopaque) *ExclusiveContext {
        return @ptrCast(@alignCast(context));
    }

    fn exclusiveScan(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        max_bytes: usize,
        visitor: EventRecordVisitor,
    ) !EventScanSummary {
        return scanWithOwnedState(
            exclusiveCast(context).store,
            allocator,
            max_bytes,
            visitor,
        );
    }

    fn exclusiveSnapshot(context: *anyopaque, allocator: std.mem.Allocator, max_bytes: usize) !EventSnapshot {
        const self = exclusiveCast(context).store;
        var collector = SnapshotCollector.init(allocator);
        defer collector.deinit();
        var summary = try scanWithOwnedState(
            self,
            allocator,
            max_bytes,
            collector.visitor(),
        );
        defer summary.deinit(allocator);
        return collector.finish(&summary);
    }

    fn exclusiveAppend(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        payload: []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        const self = exclusiveCast(context).store;
        if (self.scan_active) return error.EventStoreBusy;
        try validateEventPayload(allocator, payload);
        var ignored: u8 = 0;
        const visitor = EventRecordVisitor{ .context = &ignored, .visitFn = ignoreEventRecord };
        var before = try scanWithOwnedState(self, allocator, max_bytes, visitor);
        defer before.deinit(allocator);
        try validateEventExpectation(before, expectation);
        try validateEventAppendFits(before, payload.len, max_bytes);
        try self.records.append(self.allocator, try self.allocator.dupe(u8, payload));
        self.exists = true;
        var after = try scanWithOwnedState(self, allocator, max_bytes, visitor);
        defer after.deinit(allocator);
        return eventAppendReceipt(allocator, before, after);
    }

    fn exclusiveReplace(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        records: []const []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        const self = exclusiveCast(context).store;
        if (self.scan_active) return error.EventStoreBusy;
        for (records) |payload| try validateEventPayload(allocator, payload);
        var ignored: u8 = 0;
        const visitor = EventRecordVisitor{ .context = &ignored, .visitFn = ignoreEventRecord };
        var before = try scanWithOwnedState(self, allocator, max_bytes, visitor);
        defer before.deinit(allocator);
        try validateEventExpectation(before, expectation);
        const replacement_text = try renderEventRecordsAlloc(allocator, records);
        defer allocator.free(replacement_text);
        if (replacement_text.len > max_bytes) return error.StreamTooLong;

        var replacement: std.ArrayList([]u8) = .empty;
        errdefer {
            for (replacement.items) |record| self.allocator.free(record);
            replacement.deinit(self.allocator);
        }
        for (records) |payload| try replacement.append(self.allocator, try self.allocator.dupe(u8, payload));
        for (self.records.items) |record| self.allocator.free(record);
        self.records.deinit(self.allocator);
        self.records = replacement;
        replacement = .empty;
        self.exists = true;
        var after = try scanWithOwnedState(self, allocator, max_bytes, visitor);
        defer after.deinit(allocator);
        return eventAppendReceipt(allocator, before, after);
    }

    fn releaseExclusive(context: *anyopaque) void {
        const exclusive = exclusiveCast(context);
        exclusive.store.exclusive_active = false;
        const allocator = exclusive.allocator;
        allocator.destroy(exclusive);
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

pub const AppendLineOptions = struct {
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
    while (true) { // tiger: event-loop -- bounded by lock timeout.
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
const transaction_recovery_max_bytes: usize = if (@sizeOf(usize) >= 8)
    4 * 1024 * 1024 * 1024
else
    std.math.maxInt(usize);

pub fn writeTextAtomicCas(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    expectation: CasExpectation,
) !CasWriteReceipt {
    return writeTextAtomicCasBounded(
        allocator,
        path,
        text,
        expectation,
        default_snapshot_max_bytes,
    );
}

pub fn writeTextAtomicCasBounded(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    expectation: CasExpectation,
    max_bytes: usize,
) !CasWriteReceipt {
    if (max_bytes == 0 or text.len > max_bytes) return error.FileTooBig;
    var advisory_lock = try acquireCasAdvisoryLock(allocator, path);
    defer advisory_lock.close(Io.io());
    const cas_lock_path = try casLockPathAlloc(allocator, path);
    defer allocator.free(cas_lock_path);
    var cas_lock = try acquireExclusiveLockPathRetry(allocator, cas_lock_path, 5000, 2);
    defer cas_lock.release(allocator);
    return writeTextAtomicCasBoundedLocked(
        allocator,
        path,
        text,
        expectation,
        max_bytes,
    );
}

fn writeTextAtomicCasBoundedLocked(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    expectation: CasExpectation,
    max_bytes: usize,
) !CasWriteReceipt {
    if (max_bytes == 0 or text.len > max_bytes) return error.FileTooBig;
    const current = readRegularFileNoSymlink(allocator, path, max_bytes) catch |err| switch (err) {
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

const TransactionSnapshot = struct {
    digest: []u8,
    sequence: ?u64,

    fn deinit(self: TransactionSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.digest);
    }
};

fn readTransactionSnapshotAt(
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    base: []const u8,
    mutation: TransactionMutation,
) !TransactionSnapshot {
    if (mutation.content_mode == .raw) {
        if (mutation.expectation.expected_sequence) |sequence| {
            if (sequence != 0) return error.SequenceMismatch;
        }
        return .{
            .digest = try digestRegularFileNoSymlinkAtAlloc(
                allocator,
                dir,
                base,
                mutation.max_bytes,
            ),
            .sequence = null,
        };
    }
    const data = try readRegularFileNoSymlinkAt(
        allocator,
        dir,
        base,
        mutation.max_bytes,
    );
    errdefer allocator.free(data);
    const digest = try digestBytesAlloc(allocator, data);
    errdefer allocator.free(digest);
    defer allocator.free(data);
    const validation = validateJsonlBytes(allocator, data);
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
    };
}

fn digestRegularFileNoSymlinkAtAlloc(
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    base: []const u8,
    max_bytes: usize,
) ![]u8 {
    const stat = try dir.statFile(
        Io.io(),
        base,
        .{ .follow_symlinks = false },
    );
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.nlink > 1) return error.HardlinkTarget;
    if (stat.size > max_bytes) return error.FileTooBig;
    var file = try dir.openFile(
        Io.io(),
        base,
        .{ .allow_directory = false, .follow_symlinks = false },
    );
    defer file.close(Io.io());
    var reader = file.reader(Io.io(), &.{});
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var observed: usize = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) { // tiger: event-loop
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
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
}

fn rejectHardlinkedTargetAt(dir: *std.Io.Dir, base: []const u8) !void {
    const stat = dir.statFile(
        Io.io(),
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
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    base: []const u8,
    max_bytes: usize,
) ![]u8 {
    const stat = try dir.statFile(
        Io.io(),
        base,
        .{ .follow_symlinks = false },
    );
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > max_bytes) return error.FileTooBig;
    var file = try dir.openFile(
        Io.io(),
        base,
        .{ .allow_directory = false, .follow_symlinks = false },
    );
    defer file.close(Io.io());
    const opened = try file.stat(Io.io());
    if (opened.kind != .file or opened.nlink > 1) return error.HardlinkTarget;
    var reader = file.reader(Io.io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes + 1));
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

const TransactionTarget = struct {
    dir: std.Io.Dir,
    base: []const u8,
    inode: std.Io.File.INode,

    fn init(control_root: []const u8, path: []const u8) !TransactionTarget {
        const relative = try pathRelativeToControlRoot(control_root, path);
        const parent = std.fs.path.dirname(relative) orelse "";
        var dir = try std.Io.Dir.openDirAbsolute(
            Io.io(),
            control_root,
            .{ .follow_symlinks = false },
        );
        errdefer dir.close(Io.io());
        if (parent.len != 0) {
            var components = std.mem.splitAny(u8, parent, "/\\");
            while (components.next()) |component| {
                if (component.len == 0 or
                    std.mem.eql(u8, component, ".") or
                    std.mem.eql(u8, component, ".."))
                {
                    return error.InvalidPath;
                }
                const next = try dir.openDir(
                    Io.io(),
                    component,
                    .{ .follow_symlinks = false },
                );
                dir.close(Io.io());
                dir = next;
            }
        }
        const stat = try dir.statFile(
            Io.io(),
            ".",
            .{ .follow_symlinks = false },
        );
        if (stat.kind != .directory) return error.NotDir;
        return .{
            .dir = dir,
            .base = std.fs.path.basename(path),
            .inode = stat.inode,
        };
    }

    fn deinit(self: *TransactionTarget) void {
        self.dir.close(Io.io());
        self.* = undefined;
    }

    fn verifyPathIdentity(self: *TransactionTarget) !void {
        const stat = try self.dir.statFile(
            Io.io(),
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
    if (!std.fs.path.isAbsolute(control_root) or
        !std.fs.path.isAbsolute(path) or
        path.len <= control_root.len or
        !std.mem.eql(u8, path[0..control_root.len], control_root) or
        (path[control_root.len] != '/' and path[control_root.len] != '\\'))
    {
        return error.TransactionPathOutsideControlRoot;
    }
    const relative = path[control_root.len + 1 ..];
    if (relative.len == 0 or relative[0] == '/' or relative[0] == '\\') {
        return error.InvalidPath;
    }
    var components = std.mem.tokenizeAny(u8, relative, "/\\");
    var observed: usize = 0;
    while (components.next()) |component| {
        observed += component.len;
        if (std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return error.TransactionPathOutsideControlRoot;
        }
    }
    if (observed == 0 or
        std.mem.indexOf(u8, relative, "//") != null or
        std.mem.indexOf(u8, relative, "\\\\") != null)
    {
        return error.InvalidPath;
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
}

pub fn commitTextTransaction(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    mutations: []const TransactionMutation,
    options: AcquireOptions,
) !CommitTransactionReceipt {
    if (mutations.len == 0) return error.InvalidPath;
    try ensureDirectoryPathNoSymlinks(transactions_dir);
    const control_root = std.fs.path.dirname(transactions_dir) orelse
        return error.InvalidPath;

    const ordered = try normalizeTransactionMutations(allocator, mutations, options.reject_symlinks);
    defer allocator.free(ordered);

    const transaction_id = try transactionIdAlloc(allocator);
    errdefer allocator.free(transaction_id);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    errdefer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    try syncDirectoryPath(transactions_dir);
    var record_persisted = false;
    errdefer if (!record_persisted) {
        std.Io.Dir.cwd().deleteTree(
            Io.io(),
            transaction_dir,
        ) catch |cleanup_error| switch (cleanup_error) {
            else => {},
        };
        syncDirectoryPath(transactions_dir) catch |cleanup_error| switch (cleanup_error) {
            else => {},
        };
    };
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    errdefer allocator.free(record_path);
    const commit_marker_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "commit.json" },
    );
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

    var cas_locks = try allocator.alloc(LockFile, ordered.len);
    var cas_lock_count: usize = 0;
    defer {
        var index: usize = 0;
        while (index < cas_lock_count) : (index += 1) {
            cas_locks[index].release(allocator);
        }
        allocator.free(cas_locks);
    }
    var advisory_locks = try allocator.alloc(std.Io.File, ordered.len);
    var advisory_lock_count: usize = 0;
    defer {
        for (advisory_locks[0..advisory_lock_count]) |file| {
            file.close(Io.io());
        }
        allocator.free(advisory_locks);
    }
    for (ordered) |mutation| {
        advisory_locks[advisory_lock_count] = try acquireCasAdvisoryLock(
            allocator,
            mutation.path,
        );
        advisory_lock_count += 1;
        const cas_lock_path = try casLockPathAlloc(allocator, mutation.path);
        cas_locks[cas_lock_count] = acquireExclusiveLockPathRetry(
            allocator,
            cas_lock_path,
            5000,
            2,
        ) catch |err| {
            allocator.free(cas_lock_path);
            return err;
        };
        allocator.free(cas_lock_path);
        cas_lock_count += 1;
    }

    var targets = try allocator.alloc(TransactionTarget, ordered.len);
    var target_count: usize = 0;
    defer {
        for (targets[0..target_count]) |*target| target.deinit();
        allocator.free(targets);
    }
    for (ordered) |mutation| {
        targets[target_count] = try TransactionTarget.init(
            control_root,
            mutation.path,
        );
        target_count += 1;
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
    const before_exists = try allocator.alloc(bool, ordered.len);
    defer allocator.free(before_exists);
    var staged_files = try allocator.alloc(StagedTransactionFile, ordered.len);
    var staged_file_count: usize = 0;
    defer {
        for (staged_files[0..staged_file_count]) |*staged| {
            staged.deinit(
                &targets[staged.target_index].dir,
                record_persisted,
            );
        }
        allocator.free(staged_files);
    }

    for (ordered, targets, 0..) |mutation, *target, mutation_index| {
        try target.verifyPathIdentity();
        try rejectHardlinkedTargetAt(&target.dir, target.base);
        const append_fast_path = mutation.action == .append and
            mutation.content_mode == .raw;
        const maybe_before: ?TransactionSnapshot = if (append_fast_path)
            null
        else
            readTransactionSnapshotAt(
                allocator,
                &target.dir,
                target.base,
                mutation,
            ) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
        defer if (maybe_before) |before| before.deinit(allocator);
        before_exists[mutation_index] = if (append_fast_path)
            try transactionTargetExistsAt(
                &target.dir,
                target.base,
                mutation.max_bytes,
            )
        else
            maybe_before != null;
        if (append_fast_path) {
            if (mutation.expectation.expected_exists) |expected_exists| {
                if (expected_exists != before_exists[mutation_index]) {
                    return error.ExpectationMismatch;
                }
            }
            if (before_exists[mutation_index] and
                mutation.expectation.expected_digest == null)
            {
                return error.DigestMismatch;
            }
            if (!before_exists[mutation_index] and
                mutation.expectation.expected_digest != null)
            {
                return error.DigestMismatch;
            }
            expected[expected_count] = .{
                .path = try allocator.dupe(u8, mutation.path),
                .digest = try allocator.dupe(
                    u8,
                    mutation.expectation.expected_digest orelse "",
                ),
                .sequence = 0,
            };
        } else if (maybe_before) |before| {
            if (mutation.expectation.expected_digest) |digest| {
                if (!std.mem.eql(u8, digest, before.digest)) return error.DigestMismatch;
            }
            if (mutation.expectation.expected_exists) |expected_exists| {
                if (!expected_exists) return error.ExpectationMismatch;
            }
            expected[expected_count] = .{
                .path = try allocator.dupe(u8, mutation.path),
                .digest = try allocator.dupe(u8, before.digest),
                .sequence = switch (mutation.content_mode) {
                    .jsonl_sequence_required => before.sequence orelse
                        return error.SequenceMismatch,
                    .raw => 0,
                },
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

        if (mutation.action == .check_only) continue;
        if (mutation.text.len > mutation.max_bytes) return error.FileTooBig;
        if (mutation.content_mode == .jsonl_sequence_required) {
            const validation = validateJsonlBytes(allocator, mutation.text);
            if (!validation.ok()) return error.InvalidJsonl;
        }
        const staged_ref = try transactionStageNameAlloc(
            allocator,
            transaction_id,
            write_count,
        );
        errdefer allocator.free(staged_ref);
        if (std.mem.eql(u8, target.base, staged_ref)) {
            return error.TransactionCorrupt;
        }
        const sequence_after = switch (mutation.content_mode) {
            .jsonl_sequence_required => (try jsonlSequenceRequired(
                allocator,
                mutation.text,
            )) orelse return error.SequenceMismatch,
            .raw => 0,
        };
        writes[write_count] = .{
            .path = try allocator.dupe(u8, mutation.path),
            .staged_ref = staged_ref,
            .digest_after = try allocator.dupe(u8, ""),
            .sequence_after = sequence_after,
        };
        write_count += 1;
    }

    try writeTransactionRecord(
        allocator,
        record_path,
        transaction_id,
        options.owner,
        .preparing,
        expected[0..expected_count],
        writes[0..write_count],
        locks[0..lock_count],
        now_ms,
        clockMillis(.real),
        true,
    );
    try syncDirectoryPath(transaction_dir);
    record_persisted = true;

    var write_index: usize = 0;
    for (ordered, targets, 0..) |mutation, *target, mutation_index| {
        if (mutation.action == .check_only) continue;
        const write = &writes[write_index];
        staged_files[staged_file_count] = try createStagedTransactionFile(
            &target.dir,
            write.staged_ref,
            mutation_index,
        );
        const staged = &staged_files[staged_file_count];
        staged_file_count += 1;
        const digest_after = switch (mutation.action) {
            .write => digest: {
                try staged.file.writeStreamingAll(
                    Io.io(),
                    mutation.text,
                );
                try staged.file.sync(Io.io());
                break :digest try digestBytesAlloc(
                    allocator,
                    mutation.text,
                );
            },
            .append => digest: {
                if (mutation.content_mode != .raw or
                    mutation.expected_digest_after == null)
                {
                    return error.TransactionCorrupt;
                }
                break :digest try stageAppendedTransactionWrite(
                    allocator,
                    &staged.file,
                    target,
                    before_exists[mutation_index],
                    mutation.expectation.expected_digest,
                    mutation.text,
                    mutation.max_bytes,
                );
            },
            .check_only => unreachable,
        };
        try syncDirectoryHandle(&target.dir);
        errdefer allocator.free(digest_after);
        if (mutation.expected_digest_after) |expected_after| {
            if (!std.mem.eql(u8, digest_after, expected_after)) {
                return error.DigestMismatch;
            }
        }
        allocator.free(write.digest_after);
        write.digest_after = digest_after;
        write_index += 1;
    }

    try writeTransactionRecord(
        allocator,
        record_path,
        transaction_id,
        options.owner,
        .prepared,
        expected[0..expected_count],
        writes[0..write_count],
        locks[0..lock_count],
        now_ms,
        clockMillis(.real),
        false,
    );
    try syncDirectoryPath(transaction_dir);

    var publish_index: usize = 0;
    for (ordered, targets, 0..) |mutation, *target, target_index| {
        if (mutation.action == .check_only) continue;
        var expectation = mutation.expectation;
        if (mutation.content_mode == .raw and
            expectation.expected_sequence == 0)
        {
            expectation.expected_sequence = null;
        }
        try publishStagedTransactionWrite(
            allocator,
            writes[publish_index],
            mutation,
            expectation,
            target,
            &staged_files[publish_index],
            target_index,
        );
        publish_index += 1;
    }

    try writeTransactionRecord(allocator, record_path, transaction_id, options.owner, .committed, expected[0..expected_count], writes[0..write_count], locks[0..lock_count], now_ms, clockMillis(.real), false);
    try syncDirectoryPath(transaction_dir);
    try writeTextCreateNew(allocator, commit_marker_path, "{\"commit_marker\":\"DTX-v1\",\"state\":\"committed\"}\n", .{});
    try syncDirectoryPath(transaction_dir);

    return .{
        .transaction_id = transaction_id,
        .transaction_dir = transaction_dir,
        .record_path = record_path,
        .commit_marker_path = commit_marker_path,
        .state = .committed,
    };
}

fn stageAppendedTransactionWrite(
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
        var source = try target.dir.openFile(Io.io(), target.base, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
        defer source.close(Io.io());
        var reader = source.reader(Io.io(), &.{});
        var buffer: [jsonl_core.chunk_size]u8 = undefined;
        while (true) { // tiger: event-loop -- bounded by source EOF.
            const count = try reader.interface.readSliceShort(&buffer);
            if (count == 0) break;
            copied = std.math.add(usize, copied, count) catch
                return error.FileTooBig;
            if (copied > max_bytes) return error.FileTooBig;
            try staged.writeStreamingAll(Io.io(), buffer[0..count]);
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
    try staged.writeStreamingAll(Io.io(), suffix);
    hash.update(suffix);
    try staged.sync(Io.io());
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
}

fn transactionTargetExistsAt(
    dir: *std.Io.Dir,
    base: []const u8,
    max_bytes: usize,
) !bool {
    const stat = dir.statFile(
        Io.io(),
        base,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.nlink > 1) return error.HardlinkTarget;
    if (stat.size > max_bytes) return error.FileTooBig;
    return true;
}

const transaction_stage_prefix = ".ledger-dtx-stage-";

const StagedTransactionFile = struct {
    file: std.Io.File,
    staged_ref: []const u8,
    target_index: usize,
    file_open: bool = true,
    file_exists: bool = true,

    fn deinit(
        self: *StagedTransactionFile,
        target_dir: *std.Io.Dir,
        journal_owns_file: bool,
    ) void {
        if (self.file_open) {
            self.file.close(Io.io());
            self.file_open = false;
        }
        if (self.file_exists and !journal_owns_file) {
            target_dir.deleteFile(
                Io.io(),
                self.staged_ref,
            ) catch |cleanup_error| switch (cleanup_error) {
                else => {},
            };
        }
        self.file_exists = false;
    }
};

fn createStagedTransactionFile(
    target_dir: *std.Io.Dir,
    staged_ref: []const u8,
    target_index: usize,
) !StagedTransactionFile {
    return .{
        .file = try target_dir.createFile(Io.io(), staged_ref, .{
            .exclusive = true,
            .read = true,
            .truncate = false,
        }),
        .staged_ref = staged_ref,
        .target_index = target_index,
    };
}

fn transactionStageNameAlloc(
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

fn transactionStageName(
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

fn publishVerifiedStagedFile(
    staged_dir: *std.Io.Dir,
    staged_ref: []const u8,
    expected_digest: []const u8,
    max_bytes: usize,
    target: *TransactionTarget,
) !void {
    const entry = try staged_dir.statFile(
        Io.io(),
        staged_ref,
        .{ .follow_symlinks = false },
    );
    if (entry.kind == .sym_link) return error.SymlinkComponent;
    if (entry.kind != .file) return error.NotFile;
    if (entry.nlink != 1) return error.HardlinkTarget;
    if (entry.size > max_bytes) return error.FileTooBig;

    var source = try staged_dir.openFile(Io.io(), staged_ref, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer source.close(Io.io());
    const opened = try source.stat(Io.io());
    if (opened.kind != .file or opened.nlink != 1) {
        return error.HardlinkTarget;
    }
    if (opened.inode != entry.inode) return error.TransactionCorrupt;

    var destination = try target.dir.createFileAtomic(
        Io.io(),
        target.base,
        .{ .replace = true },
    );
    defer destination.deinit(Io.io());
    var reader = source.reader(Io.io(), &.{});
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var observed: usize = 0;
    var buffer: [jsonl_core.chunk_size]u8 = undefined;
    while (true) { // tiger: event-loop -- bounded by the staged file.
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        observed = std.math.add(usize, observed, count) catch
            return error.FileTooBig;
        if (observed > max_bytes) return error.FileTooBig;
        try destination.file.writeStreamingAll(
            Io.io(),
            buffer[0..count],
        );
        hasher.update(buffer[0..count]);
    }
    const final_source = try source.stat(Io.io());
    if (final_source.kind != .file or final_source.nlink != 1) {
        return error.HardlinkTarget;
    }
    if (final_source.inode != opened.inode or
        final_source.size != observed)
    {
        return error.TransactionCorrupt;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    var formatted: [71]u8 = undefined;
    @memcpy(formatted[0..7], "sha256:");
    @memcpy(formatted[7..], &hex);
    if (!std.mem.eql(u8, &formatted, expected_digest)) {
        return error.TransactionCorrupt;
    }
    try destination.file.sync(Io.io());
    try destination.replace(Io.io());
}

fn publishStagedTransactionWrite(
    allocator: std.mem.Allocator,
    write: TransactionWrite,
    mutation: TransactionMutation,
    expectation: CasExpectation,
    target: *TransactionTarget,
    staged: *StagedTransactionFile,
    target_index: usize,
) !void {
    const sequence_after = switch (mutation.content_mode) {
        .jsonl_sequence_required => (try jsonlSequenceRequired(
            allocator,
            mutation.text,
        )) orelse return error.SequenceMismatch,
        .raw => 0,
    };
    if (sequence_after != write.sequence_after) {
        return error.TransactionCorrupt;
    }
    try target.verifyPathIdentity();
    try validateTransactionExpectationAt(
        allocator,
        mutation,
        expectation,
        target,
    );
    if (!staged.file_open or !staged.file_exists or
        staged.target_index != target_index or
        !std.mem.eql(u8, staged.staged_ref, write.staged_ref))
    {
        return error.TransactionCorrupt;
    }
    const opened = try staged.file.stat(Io.io());
    if (opened.kind != .file or opened.nlink != 1 or
        opened.size > mutation.max_bytes)
    {
        return error.TransactionCorrupt;
    }
    const entry = try target.dir.statFile(
        Io.io(),
        write.staged_ref,
        .{ .follow_symlinks = false },
    );
    if (entry.kind != .file or entry.nlink != 1 or
        entry.inode != opened.inode or entry.size != opened.size)
    {
        return error.TransactionCorrupt;
    }
    staged.file.close(Io.io());
    staged.file_open = false;
    try target.dir.rename(
        write.staged_ref,
        target.dir,
        target.base,
        Io.io(),
    );
    staged.file_exists = false;
    try syncDirectoryHandle(&target.dir);
    try target.verifyPathIdentity();
    const published = try target.dir.statFile(
        Io.io(),
        target.base,
        .{ .follow_symlinks = false },
    );
    if (published.kind != .file or published.nlink != 1 or
        published.inode != opened.inode or published.size != opened.size)
    {
        return error.TransactionCorrupt;
    }
}

fn validateTransactionExpectationAt(
    allocator: std.mem.Allocator,
    mutation: TransactionMutation,
    expectation: CasExpectation,
    target: *TransactionTarget,
) !void {
    const current = readTransactionSnapshotAt(
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

fn transactionIdAlloc(allocator: std.mem.Allocator) ![]u8 {
    var entropy: [16]u8 = undefined;
    try std.Io.randomSecure(Io.io(), &entropy);
    const encoded = std.fmt.bytesToHex(entropy, .lower);
    return std.fmt.allocPrint(
        allocator,
        "dtx-{d}-{s}",
        .{ clockMillis(.real), &encoded },
    );
}

pub fn inspectTransaction(
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
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
    const parsed = try parseTransactionRecord(allocator, record_path);
    defer parsed.deinit(allocator);
    try validateTransactionRecordScope(control_root, parsed);
    if (parsed.state == .preparing) {
        return makeRecoveryStatus(
            allocator,
            parsed.transaction_id,
            .roll_back_unpublished,
            "preparing-stage-cleanup-required",
        );
    }
    if (parsed.state == .committed and fileExists(commit_marker_path)) {
        return makeRecoveryStatus(
            allocator,
            parsed.transaction_id,
            .already_committed,
            "commit-marker-present",
        );
    }
    if (parsed.state == .aborted) {
        return makeRecoveryStatus(
            allocator,
            parsed.transaction_id,
            .roll_back_unpublished,
            "already-aborted",
        );
    }
    const published = (try transactionPublishedCount(
        allocator,
        control_root,
        parsed.writes,
        parsed.expected,
    )) orelse
        return makeRecoveryStatus(
            allocator,
            parsed.transaction_id,
            .manual_recovery_required,
            "published-digest-disagreement",
        );
    if (published == parsed.writes.len) {
        return makeRecoveryStatus(
            allocator,
            parsed.transaction_id,
            .finish_commit,
            "all-digests-published",
        );
    }
    return makeRecoveryStatus(
        allocator,
        parsed.transaction_id,
        .finish_commit,
        "roll-forward-required",
    );
}

pub fn recoverTransaction(
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) !RecoveryReceipt {
    const control_root = try transactionControlRoot(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const commit_marker_path = try std.fs.path.join(allocator, &.{ transaction_dir, "commit.json" });
    defer allocator.free(commit_marker_path);
    var parsed = try parseTransactionRecord(allocator, record_path);
    defer parsed.deinit(allocator);
    try validateTransactionRecordScope(control_root, parsed);
    var recovery_locks = try acquireTransactionRecoveryLocks(
        allocator,
        parsed.expected,
    );
    defer recovery_locks.deinit(allocator);
    const status = try inspectTransaction(allocator, transaction_dir);
    defer status.deinit(allocator);
    switch (status.decision) {
        .already_committed => return makeRecoveryReceipt(allocator, parsed.transaction_id, .already_committed, "already_committed"),
        .finish_commit => {
            try rollForwardTransaction(
                allocator,
                control_root,
                parsed,
            );
            const record = try renderParsedTransactionRecordAlloc(allocator, parsed, .committed);
            defer allocator.free(record);
            try writeTextAtomic(allocator, record_path, record);
            try syncDirectoryPath(transaction_dir);
            writeTextCreateNew(allocator, commit_marker_path, "{\"commit_marker\":\"DTX-v1\",\"state\":\"committed\"}\n", .{}) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            try syncDirectoryPath(transaction_dir);
            return makeRecoveryReceipt(allocator, parsed.transaction_id, .finish_commit, "committed");
        },
        .roll_back_unpublished => {
            try deleteReservedTransactionStages(
                control_root,
                parsed.writes,
            );
            const record = try renderParsedTransactionRecordAlloc(allocator, parsed, .aborted);
            defer allocator.free(record);
            try writeTextAtomic(allocator, record_path, record);
            try syncDirectoryPath(transaction_dir);
            return makeRecoveryReceipt(allocator, parsed.transaction_id, .roll_back_unpublished, "aborted");
        },
        .manual_recovery_required => return error.TransactionRecoveryRequired,
    }
}

pub fn recoverAndCompactTransactions(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
) !void {
    const max_entries: usize = 4096;
    const max_record_bytes: usize = 16 * 1024 * 1024;
    var dir = if (std.fs.path.isAbsolute(transactions_dir))
        try std.Io.Dir.openDirAbsolute(Io.io(), transactions_dir, .{
            .iterate = true,
            .follow_symlinks = false,
        })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), transactions_dir, .{
            .iterate = true,
            .follow_symlinks = false,
        });
    defer dir.close(Io.io());

    var entries: usize = 0;
    var record_bytes: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(Io.io())) |entry| {
        if (entry.kind == .sym_link) return error.SymlinkComponent;
        if (entry.kind != .directory) continue;
        entries = std.math.add(usize, entries, 1) catch
            return error.TooManyFiles;
        if (entries > max_entries) return error.TooManyFiles;
        const transaction_dir = try std.fs.path.join(
            allocator,
            &.{ transactions_dir, entry.name },
        );
        defer allocator.free(transaction_dir);
        const record_path = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "transaction.json" },
        );
        defer allocator.free(record_path);
        const stat = std.Io.Dir.cwd().statFile(
            Io.io(),
            record_path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.Dir.cwd().deleteTree(Io.io(), transaction_dir);
                try syncDirectoryHandle(&dir);
                continue;
            },
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) return error.TransactionCorrupt;
        record_bytes = std.math.add(
            usize,
            record_bytes,
            std.math.cast(usize, stat.size) orelse return error.FileTooBig,
        ) catch return error.FileTooBig;
        if (record_bytes > max_record_bytes) return error.FileTooBig;

        var receipt = try recoverTransaction(allocator, transaction_dir);
        receipt.deinit(allocator);
        try std.Io.Dir.cwd().deleteTree(Io.io(), transaction_dir);
        try syncDirectoryHandle(&dir);
    }
}

fn transactionControlRoot(transaction_dir: []const u8) ![]const u8 {
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse
        return error.InvalidPath;
    return std.fs.path.dirname(transactions_dir) orelse
        return error.InvalidPath;
}

fn validateTransactionRecordScope(
    control_root: []const u8,
    parsed: ParsedTransactionRecord,
) !void {
    for (parsed.expected) |row| {
        _ = try pathRelativeToControlRoot(control_root, row.path);
    }
    for (parsed.writes, 0..) |row, write_index| {
        _ = try pathRelativeToControlRoot(control_root, row.path);
        var expected_name_buffer: [96]u8 = undefined;
        const expected_name = try transactionStageName(
            &expected_name_buffer,
            parsed.transaction_id,
            write_index,
        );
        if (!std.mem.eql(u8, row.staged_ref, expected_name)) {
            return error.TransactionCorrupt;
        }
        for (parsed.expected) |expected| {
            if (std.mem.eql(
                u8,
                std.fs.path.basename(expected.path),
                row.staged_ref,
            )) return error.TransactionCorrupt;
        }
        for (parsed.writes) |sibling| {
            if (std.mem.eql(
                u8,
                std.fs.path.basename(sibling.path),
                row.staged_ref,
            )) return error.TransactionCorrupt;
        }
    }
}

fn deleteReservedTransactionStages(
    control_root: []const u8,
    writes: []const TransactionWrite,
) !void {
    for (writes) |write| {
        var target = try TransactionTarget.init(control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        const stat = target.dir.statFile(
            Io.io(),
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
        try target.dir.deleteFile(Io.io(), write.staged_ref);
        try syncDirectoryHandle(&target.dir);
    }
}

const TransactionRecoveryLocks = struct {
    advisory: []std.Io.File,
    compatibility: []LockFile,
    advisory_count: usize,
    compatibility_count: usize,

    fn deinit(
        self: *TransactionRecoveryLocks,
        allocator: std.mem.Allocator,
    ) void {
        for (self.compatibility[0..self.compatibility_count]) |*lock| {
            lock.release(allocator);
        }
        for (self.advisory[0..self.advisory_count]) |file| {
            file.close(Io.io());
        }
        allocator.free(self.compatibility);
        allocator.free(self.advisory);
        self.* = undefined;
    }
};

fn acquireTransactionRecoveryLocks(
    allocator: std.mem.Allocator,
    expected: []const TransactionExpected,
) !TransactionRecoveryLocks {
    const advisory = try allocator.alloc(std.Io.File, expected.len);
    errdefer allocator.free(advisory);
    const compatibility = try allocator.alloc(LockFile, expected.len);
    errdefer allocator.free(compatibility);
    var result: TransactionRecoveryLocks = .{
        .advisory = advisory,
        .compatibility = compatibility,
        .advisory_count = 0,
        .compatibility_count = 0,
    };
    errdefer result.deinit(allocator);
    for (expected) |row| {
        result.advisory[result.advisory_count] = try acquireCasAdvisoryLock(
            allocator,
            row.path,
        );
        result.advisory_count += 1;
        const cas_path = try casLockPathAlloc(allocator, row.path);
        defer allocator.free(cas_path);
        const stat = std.Io.Dir.cwd().statFile(
            Io.io(),
            cas_path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (stat) |value| {
            if (value.kind == .sym_link) return error.SymlinkComponent;
            if (value.kind != .file) return error.TransactionCorrupt;
            if (std.fs.path.isAbsolute(cas_path)) {
                try std.Io.Dir.deleteFileAbsolute(Io.io(), cas_path);
            } else {
                try std.Io.Dir.cwd().deleteFile(Io.io(), cas_path);
            }
        }
        result.compatibility[result.compatibility_count] =
            try acquireExclusiveLockPath(allocator, cas_path);
        result.compatibility_count += 1;
    }
    return result;
}

fn rollForwardTransaction(
    allocator: std.mem.Allocator,
    control_root: []const u8,
    parsed: ParsedTransactionRecord,
) !void {
    for (parsed.writes) |write| {
        var target = try TransactionTarget.init(control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        const current = digestRegularFileNoSymlinkAtAlloc(
            allocator,
            &target.dir,
            target.base,
            transaction_recovery_max_bytes,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (current) |digest| allocator.free(digest);
        if (current) |digest| {
            if (std.mem.eql(u8, digest, write.digest_after)) {
                target.dir.deleteFile(
                    Io.io(),
                    write.staged_ref,
                ) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                try syncDirectoryHandle(&target.dir);
                continue;
            }
            if (!digestMatchesExpectedBefore(
                write.path,
                digest,
                parsed.expected,
            )) return error.TransactionRecoveryRequired;
        } else if (!expectedMissingBefore(write.path, parsed.expected)) {
            return error.TransactionRecoveryRequired;
        }
        try rejectHardlinkedTargetAt(&target.dir, target.base);
        try publishVerifiedStagedFile(
            &target.dir,
            write.staged_ref,
            write.digest_after,
            transaction_recovery_max_bytes,
            &target,
        );
        try syncDirectoryHandle(&target.dir);
        try target.dir.deleteFile(Io.io(), write.staged_ref);
        try syncDirectoryHandle(&target.dir);
        try target.verifyPathIdentity();
    }
}

fn syncDirectoryPath(path: []const u8) !void {
    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(
            Io.io(),
            path,
            .{ .follow_symlinks = false },
        )
    else
        try std.Io.Dir.cwd().openDir(
            Io.io(),
            path,
            .{ .follow_symlinks = false },
        );
    defer dir.close(Io.io());
    try syncDirectoryHandle(&dir);
}

fn syncDirectoryHandle(dir: *const std.Io.Dir) !void {
    var file = try dir.openFile(Io.io(), ".", .{
        .allow_directory = true,
        .follow_symlinks = false,
        .path_only = false,
    });
    defer file.close(Io.io());
    try file.sync(Io.io());
}

fn expectedMissingBefore(
    path: []const u8,
    expected: []const TransactionExpected,
) bool {
    for (expected) |row| {
        if (std.mem.eql(u8, row.path, path)) return row.digest.len == 0;
    }
    return false;
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

fn pathsAliasOrOverlap(left: []const u8, right: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(left, right)) return true;
    const shorter = if (left.len < right.len) left else right;
    const longer = if (left.len < right.len) right else left;
    return longer.len > shorter.len and
        std.ascii.startsWithIgnoreCase(longer, shorter) and
        longer[shorter.len] == std.fs.path.sep;
}

fn rejectTransactionPath(path: []const u8, reject_symlinks: bool) !void {
    const base = std.fs.path.basename(path);
    if (path.len == 0 or
        base.len == 0 or
        std.mem.eql(u8, base, ".") or
        std.mem.eql(u8, base, "..") or
        std.mem.startsWith(u8, base, transaction_stage_prefix))
    {
        return error.InvalidPath;
    }
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
    control_root: []const u8,
    writes: []const TransactionWrite,
    expected: []const TransactionExpected,
) !?usize {
    var published: usize = 0;
    for (writes) |write| {
        _ = try pathRelativeToControlRoot(control_root, write.path);
        var target = try TransactionTarget.init(control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        const digest = digestRegularFileNoSymlinkAtAlloc(
            allocator,
            &target.dir,
            target.base,
            transaction_recovery_max_bytes,
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(digest);
        if (std.mem.eql(u8, digest, write.digest_after)) {
            published += 1;
        } else if (!digestMatchesExpectedBefore(write.path, digest, expected)) {
            return null;
        }
    }
    return published;
}

fn digestRegularFileNoSymlinkAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const stat = (try statRegularFileNoSymlink(path)) orelse
        return error.FileNotFound;
    if (stat.size > max_bytes) return error.FileTooBig;
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(
            Io.io(),
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        )
    else
        try std.Io.Dir.cwd().openFile(
            Io.io(),
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        );
    defer file.close(Io.io());
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var reader = file.reader(Io.io(), &.{});
    var buffer: [jsonl_core.chunk_size]u8 = undefined;
    var bytes_observed: usize = 0;
    while (true) { // tiger: event-loop -- bounded by source EOF.
        const read = try reader.interface.readSliceShort(&buffer);
        if (read == 0) break;
        bytes_observed = std.math.add(
            usize,
            bytes_observed,
            read,
        ) catch return error.FileTooBig;
        if (bytes_observed > max_bytes) return error.FileTooBig;
        hash.update(buffer[0..read]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
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

fn validateEventPayload(allocator: std.mem.Allocator, payload: []const u8) !void {
    if (payload.len == 0 or std.mem.indexOfScalar(u8, payload, '\n') != null or std.mem.indexOfScalar(u8, payload, '\r') != null) {
        return error.InvalidEventPayload;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return error.InvalidEventPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEventPayload;
}

const SnapshotCollector = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(EventRecord) = .empty,

    fn init(allocator: std.mem.Allocator) SnapshotCollector {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *SnapshotCollector) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    fn visitor(self: *SnapshotCollector) EventRecordVisitor {
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

    fn finish(self: *SnapshotCollector, summary: *EventScanSummary) !EventSnapshot {
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

const EventHash = std.crypto.hash.sha2.Sha256;
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

fn scanJsonlEventStore(
    allocator: std.mem.Allocator,
    logical_ref: []const u8,
    max_bytes: usize,
    visitor: EventRecordVisitor,
    acquire_shared: bool,
) !EventScanSummary {
    var sidecar: ?std.Io.File = null;
    defer if (sidecar) |file| file.close(Io.io());
    _ = try statRegularFileNoSymlink(logical_ref);
    const open_options: std.Io.Dir.OpenFileOptions = .{
        .allow_directory = true,
        .follow_symlinks = false,
        .lock = if (acquire_shared) .shared else .none,
        .lock_nonblocking = acquire_shared,
    };
    var file = (if (std.fs.path.isAbsolute(logical_ref))
        std.Io.Dir.openFileAbsolute(
            Io.io(),
            logical_ref,
            open_options,
        )
    else
        std.Io.Dir.cwd().openFile(
            Io.io(),
            logical_ref,
            open_options,
        )) catch |err| switch (err) {
        error.FileNotFound => {
            if (acquire_shared) {
                sidecar = try acquireEventStoreScanSidecar(
                    allocator,
                    logical_ref,
                );
            }
            return emptyEventScanSummary(allocator, logical_ref, false);
        },
        error.SymLinkLoop => return error.SymlinkComponent,
        error.WouldBlock => return error.EventStoreBusy,
        else => return err,
    };
    defer file.close(Io.io());
    if (acquire_shared) {
        sidecar = try acquireEventStoreScanSidecar(allocator, logical_ref);
    }

    const stat = try file.stat(Io.io());
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > max_bytes) return error.FileTooBig;

    var raw_hash = EventHash.init(.{});
    var canonical_hash = EventHash.init(.{});
    var raw_observer = RawHashObserver{
        .hash = &raw_hash,
        .visitor = visitor,
        .max_bytes = max_bytes,
    };
    var reader = file.reader(Io.io(), &.{});
    var stream = try jsonl_core.Stream.init(allocator, &reader.interface, .{
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
    return finishEventScanSummary(
        allocator,
        logical_ref,
        true,
        &raw_hash,
        &canonical_hash,
        record_count,
        blank_entries,
        stream.bytes_read,
        if (stream.bytes_read != 0 and raw_observer.last_byte.? != '\n') 1 else 0,
    );
}

fn scanMemoryEventStore(
    allocator: std.mem.Allocator,
    store: *MemoryEventStore,
    max_bytes: usize,
    visitor: EventRecordVisitor,
) !EventScanSummary {
    var extent_bytes: usize = 0;
    for (store.records.items) |payload| {
        extent_bytes = std.math.add(
            usize,
            extent_bytes,
            payload.len + 1,
        ) catch return error.StreamTooLong;
        if (extent_bytes > max_bytes) return error.StreamTooLong;
    }

    var raw_hash = EventHash.init(.{});
    var canonical_hash = EventHash.init(.{});
    var record_count: usize = 0;
    var blank_entries: usize = 0;
    var raw_offset: usize = 0;
    for (store.records.items) |payload| {
        const canonical_payload = std.mem.trim(u8, payload, " \t\r\n");
        raw_hash.update(payload);
        raw_hash.update("\n");
        try visitor.observeRaw(payload);
        try visitor.observeRaw("\n");
        if (canonical_payload.len == 0) {
            blank_entries += 1;
            raw_offset += payload.len + 1;
            continue;
        }
        record_count += 1;
        canonical_hash.update(canonical_payload);
        canonical_hash.update("\n");
        const leading = std.mem.trimStart(u8, payload, " \t\r\n");
        const payload_start = raw_offset + (payload.len - leading.len);
        try visitor.visit(.{
            .payload = canonical_payload,
            .ordinal = @intCast(record_count),
            .diagnostic_position = null,
            .extent_start = payload_start,
            .extent_end = payload_start + canonical_payload.len,
        });
        raw_offset += payload.len + 1;
    }
    return finishEventScanSummary(
        allocator,
        store.logical_ref,
        store.exists,
        &raw_hash,
        &canonical_hash,
        record_count,
        blank_entries,
        extent_bytes,
        0,
    );
}

fn emptyEventScanSummary(
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

fn finishEventScanSummary(
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
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
}

fn ignoreEventRecord(_: *anyopaque, _: EventRecordView) !void {}

fn validateEventExpectation(snapshot: EventScanSummary, expectation: EventAppendExpectation) !void {
    if (expectation.exists) |expected| {
        if (expected != snapshot.exists) return error.ExpectationMismatch;
    }
    if (expectation.revision) |expected| {
        if (!std.mem.eql(u8, expected, snapshot.revision)) return error.ExpectationMismatch;
    }
}

fn validateEventAppendFits(snapshot: EventScanSummary, payload_len: usize, max_bytes: usize) !void {
    if (snapshot.extent_bytes > max_bytes or payload_len >= max_bytes) return error.StreamTooLong;
    const additional = payload_len + 1 + snapshot.append_separator_bytes;
    if (additional > max_bytes - snapshot.extent_bytes) return error.StreamTooLong;
}

fn eventAppendReceipt(
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

fn renderEventRecordsAlloc(allocator: std.mem.Allocator, records: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (records) |payload| {
        try out.writer.writeAll(payload);
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
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

const event_store_lock_dir_name = ".durable-store-locks";

fn rejectEventStoreControlNamespace(path: []const u8) !void {
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
    return std.fmt.allocPrint(allocator, "{s}.lock", .{store_path});
}

fn caseVariantAlloc(
    allocator: std.mem.Allocator,
    name: []const u8,
) !?[]u8 {
    const variant = try allocator.dupe(u8, name);
    errdefer allocator.free(variant);
    for (variant) |*byte| {
        if (std.ascii.isLower(byte.*)) {
            byte.* -= 'a' - 'A';
            return variant;
        }
        if (std.ascii.isUpper(byte.*)) {
            byte.* += 'a' - 'A';
            return variant;
        }
    }
    allocator.free(variant);
    return null;
}

fn nearestExistingPathAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![:0]u8 {
    var candidate = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(candidate);
    while (true) { // tiger: event-loop -- bounded by path ancestors.
        return std.Io.Dir.cwd().realPathFileAlloc(
            Io.io(),
            candidate,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = std.fs.path.dirname(candidate) orelse return err;
                if (std.mem.eql(u8, parent, candidate)) return err;
                const next = try allocator.dupe(u8, parent);
                allocator.free(candidate);
                candidate = next;
                continue;
            },
            else => return err,
        };
    }
}

fn directoryNamesAreCaseInsensitive(
    allocator: std.mem.Allocator,
    directory: []const u8,
) !bool {
    var canonical = try nearestExistingPathAlloc(allocator, directory);
    defer allocator.free(canonical);
    while (true) { // tiger: event-loop -- bounded by path ancestors.
        const parent = std.fs.path.dirname(canonical) orelse return false;
        if (std.mem.eql(u8, parent, canonical)) return false;
        const variant = (try caseVariantAlloc(
            allocator,
            std.fs.path.basename(canonical),
        )) orelse {
            const next = try allocator.dupeZ(u8, parent);
            allocator.free(canonical);
            canonical = next;
            continue;
        };
        defer allocator.free(variant);
        const alias = try std.fs.path.join(allocator, &.{ parent, variant });
        defer allocator.free(alias);
        const alias_stat = std.Io.Dir.cwd().statFile(
            Io.io(),
            alias,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        if (alias_stat.kind != .directory) return false;
        const alias_real = std.Io.Dir.cwd().realPathFileAlloc(
            Io.io(),
            alias,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer allocator.free(alias_real);
        return std.mem.eql(u8, canonical, alias_real);
    }
}

fn eventStoreIdentityBasenameAlloc(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) ![:0]u8 {
    const identity_path = std.Io.Dir.cwd().realPathFileAlloc(
        Io.io(),
        store_path,
        allocator,
    ) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupeZ(u8, store_path),
        else => return err,
    };
    defer allocator.free(identity_path);
    const basename = std.fs.path.basename(identity_path);
    const identity = try allocator.dupeZ(u8, basename);
    errdefer allocator.free(identity);
    const parent = std.fs.path.dirname(identity_path) orelse ".";
    if (try directoryNamesAreCaseInsensitive(allocator, parent)) {
        for (identity[0..basename.len]) |*byte| {
            byte.* = std.ascii.toLower(byte.*);
        }
    }
    return identity;
}

pub fn eventStoreLockPathAlloc(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) ![]u8 {
    try rejectEventStoreControlNamespace(store_path);
    const identity_basename = try eventStoreIdentityBasenameAlloc(
        allocator,
        store_path,
    );
    defer allocator.free(identity_basename);
    var digest: [EventHash.digest_length]u8 = undefined;
    EventHash.hash(std.fs.path.basename(identity_basename), &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    const file_name = try std.fmt.allocPrint(
        allocator,
        "{s}.lock",
        .{&encoded},
    );
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{
        std.fs.path.dirname(store_path) orelse ".",
        event_store_lock_dir_name,
        file_name,
    });
}

fn casLockPathAlloc(allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.cas.lock", .{store_path});
}

fn acquireCasAdvisoryLock(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !std.Io.File {
    const cas_path = try casLockPathAlloc(allocator, store_path);
    defer allocator.free(cas_path);
    const advisory_path = try std.fmt.allocPrint(
        allocator,
        "{s}.advisory",
        .{cas_path},
    );
    defer allocator.free(advisory_path);
    return openEventStoreSidecarExclusive(advisory_path) catch |err| switch (err) {
        error.WouldBlock => return error.LockBusy,
        else => return err,
    };
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
                std.Io.Dir.cwd().createDir(
                    Io.io(),
                    component.path,
                    .default_dir,
                ) catch |create_error| switch (create_error) {
                    error.PathAlreadyExists => {},
                    else => return create_error,
                };
                const created_stat = try std.Io.Dir.cwd().statFile(Io.io(), component.path, .{ .follow_symlinks = false });
                if (created_stat.kind == .sym_link) return error.SymlinkComponent;
                if (created_stat.kind != .directory) return error.NotDir;
                try syncDirectoryPath(component.path);
                try syncDirectoryPath(
                    std.fs.path.dirname(component.path) orelse ".",
                );
                continue;
            },
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .directory) return error.NotDir;
    }
}

pub fn ensurePrivateDirectoryPathNoSymlinks(path: []const u8) !void {
    try ensureDirectoryPathNoSymlinks(path);
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return;
    try std.Io.Dir.cwd().setFilePermissions(
        Io.io(),
        path,
        std.Io.File.Permissions.fromMode(0o700),
        .{ .follow_symlinks = false },
    );
    try validatePrivateDirectoryPathNoSymlinks(path);
}

pub fn validatePrivateDirectoryPathNoSymlinks(path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(
        Io.io(),
        path,
        .{ .follow_symlinks = false },
    );
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .directory) return error.NotDir;
    if (@hasDecl(std.Io.File.Permissions, "toMode") and
        stat.permissions.toMode() & 0o077 != 0)
    {
        return error.InsecurePrivateDirectory;
    }
}

fn statRegularFileNoSymlink(path: []const u8) !?std.Io.File.Stat {
    const stat = std.Io.Dir.cwd().statFile(
        Io.io(),
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    return stat;
}

pub fn readRegularFileNoSymlink(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const stat = (try statRegularFileNoSymlink(path)) orelse
        return error.FileNotFound;
    if (stat.size > max_bytes) return error.FileTooBig;

    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(
            Io.io(),
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        )
    else
        try std.Io.Dir.cwd().openFile(
            Io.io(),
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        );
    defer file.close(Io.io());

    var reader = file.reader(Io.io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes + 1));
}

pub fn readPrivateRegularFileNoSymlink(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(
            Io.io(),
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        )
    else
        try std.Io.Dir.cwd().openFile(
            Io.io(),
            path,
            .{ .allow_directory = false, .follow_symlinks = false },
        );
    defer file.close(Io.io());
    const stat = try file.stat(Io.io());
    if (stat.kind != .file) return error.NotFile;
    if (stat.nlink != 1) return error.HardlinkTarget;
    if (@hasDecl(std.Io.File.Permissions, "toMode") and
        stat.permissions.toMode() & 0o077 != 0)
    {
        return error.InsecurePrivateFile;
    }
    if (stat.size > max_bytes) return error.FileTooBig;
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
    std.sort.heap([]u8, names.items, {}, struct {
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
    if (parent.len == 0 or
        base.len == 0 or
        std.mem.eql(u8, base, ".") or
        std.mem.eql(u8, base, ".."))
    {
        return error.InvalidPath;
    }
    if (options.reject_symlinks) {
        try ensureDirectoryPathNoSymlinks(parent);
        const existing_stat = std.Io.Dir.cwd().statFile(
            Io.io(),
            path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
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

pub fn writeTextCreateNewAtomic(
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

    var atomic_file = try dir.createFileAtomic(Io.io(), base, .{
        .permissions = filePermissionsFromMode(options.file_mode),
        .replace = false,
    });
    defer atomic_file.deinit(Io.io());
    try atomic_file.file.writeStreamingAll(Io.io(), text);
    if (options.sync) try atomic_file.file.sync(Io.io());
    try atomic_file.link(Io.io());
    _ = allocator;
}

pub fn writeTextAtomic(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    return writeTextAtomicMode(allocator, path, text, null);
}

pub fn writeTextAtomicPrivate(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
) !void {
    return writeTextAtomicMode(allocator, path, text, 0o600);
}

fn writeTextAtomicMode(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    file_mode: ?u32,
) !void {
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
        try writeTempAndRename(&dir, tmp_name, base, text, file_mode);
        return;
    }

    var dir = try std.Io.Dir.cwd().openDir(Io.io(), parent, .{});
    defer dir.close(Io.io());
    try writeTempAndRename(&dir, tmp_name, base, text, file_mode);
}

fn writeTempAndRename(
    dir: *std.Io.Dir,
    tmp_name: []const u8,
    base: []const u8,
    text: []const u8,
    file_mode: ?u32,
) !void {
    var file = try dir.createFile(Io.io(), tmp_name, .{
        .truncate = true,
        .read = true,
        .permissions = filePermissionsFromMode(file_mode),
    });
    var close_file = true;
    errdefer if (close_file) file.close(Io.io());
    try file.writeStreamingAll(Io.io(), text);
    try file.sync(Io.io());
    file.close(Io.io());
    close_file = false;
    errdefer dir.deleteFile(Io.io(), tmp_name) catch {};
    try dir.rename(tmp_name, dir.*, base, Io.io());
}

fn addCopiedBytesWithinLimit(
    copied_bytes: usize,
    read_bytes: usize,
    max_existing_bytes: usize,
) !usize {
    const next = std.math.add(
        usize,
        copied_bytes,
        read_bytes,
    ) catch return error.StreamTooLong;
    if (next > max_existing_bytes) return error.StreamTooLong;
    return next;
}

pub fn appendLineAtomic(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    max_existing_bytes: usize,
) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (parent.len == 0 or
        base.len == 0 or
        std.mem.eql(u8, base, ".") or
        std.mem.eql(u8, base, ".."))
    {
        return error.InvalidPath;
    }
    try ensureDirectoryPathNoSymlinks(parent);

    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(
            Io.io(),
            parent,
            .{ .follow_symlinks = false },
        )
    else
        try std.Io.Dir.cwd().openDir(
            Io.io(),
            parent,
            .{ .follow_symlinks = false },
        );
    defer dir.close(Io.io());

    var source: ?std.Io.File = dir.openFile(Io.io(), base, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (source) |*file| file.close(Io.io());
    if (source) |*file| {
        const stat = try file.stat(Io.io());
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) return error.NotFile;
        if (stat.size > max_existing_bytes) return error.StreamTooLong;
    }

    const tmp_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.{d}.tmp",
        .{ base, std.Io.Clock.awake.now(Io.io()).nanoseconds },
    );
    defer allocator.free(tmp_name);
    var destination = try dir.createFile(Io.io(), tmp_name, .{
        .exclusive = true,
        .read = true,
        .truncate = true,
    });
    var destination_open = true;
    errdefer if (destination_open) destination.close(Io.io());
    // Preserve the primary append error; temp-file cleanup is best effort.
    errdefer dir.deleteFile(Io.io(), tmp_name) catch |cleanup_error| switch (cleanup_error) {
        error.FileNotFound => {},
        else => {},
    };

    var last_byte: ?u8 = null;
    var copied_bytes: usize = 0;
    if (source) |*file| {
        var reader = file.reader(Io.io(), &.{});
        var buffer: [jsonl_core.chunk_size]u8 = undefined;
        while (true) { // tiger: event-loop -- bounded by source EOF.
            const read = try reader.interface.readSliceShort(&buffer);
            if (read == 0) break;
            copied_bytes = try addCopiedBytesWithinLimit(
                copied_bytes,
                read,
                max_existing_bytes,
            );
            try destination.writeStreamingAll(Io.io(), buffer[0..read]);
            last_byte = buffer[read - 1];
        }
    }
    if (last_byte != null and last_byte.? != '\n') {
        try destination.writeStreamingAll(Io.io(), "\n");
    }
    try destination.writeStreamingAll(Io.io(), line);
    try destination.writeStreamingAll(Io.io(), "\n");
    try destination.sync(Io.io());
    destination.close(Io.io());
    destination_open = false;
    try dir.rename(tmp_name, dir, base, Io.io());
}

pub fn appendLineStreaming(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    options: AppendLineOptions,
) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (parent.len == 0 or
        base.len == 0 or
        std.mem.eql(u8, base, ".") or
        std.mem.eql(u8, base, ".."))
    {
        return error.InvalidPath;
    }
    if (options.reject_symlinks) {
        try ensureDirectoryPathNoSymlinks(parent);
        const existing_stat = std.Io.Dir.cwd().statFile(
            Io.io(),
            path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing_stat) |stat| {
            if (stat.kind == .sym_link) return error.SymlinkComponent;
            if (stat.kind != .file) return error.NotFile;
        }
    } else {
        try ensureParentPath(path);
    }

    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(Io.io(), parent, .{ .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), parent, .{ .follow_symlinks = false });
    defer dir.close(Io.io());

    var file = dir.openFile(Io.io(), base, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(Io.io(), base, .{
            .exclusive = true,
            .read = true,
            .truncate = false,
            .permissions = filePermissionsFromMode(options.file_mode),
        }) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => try dir.openFile(Io.io(), base, .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
            }),
            else => return create_err,
        },
        else => return err,
    };
    defer file.close(Io.io());

    const stat = try file.stat(Io.io());
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    var offset = stat.size;
    if (stat.size > 0) {
        var last: [1]u8 = undefined;
        const read = try file.readPositionalAll(Io.io(), &last, stat.size - 1);
        if (read == 1 and last[0] != '\n') {
            try file.writePositionalAll(Io.io(), "\n", offset);
            offset += 1;
        }
    }
    try file.writePositionalAll(Io.io(), line, offset);
    try file.writePositionalAll(Io.io(), "\n", offset + line.len);
    if (options.sync) try file.sync(Io.io());
    _ = allocator;
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
    return countPendingTransactionsBounded(
        allocator,
        transactions_dir,
        4096,
        8192,
    );
}

fn countPendingTransactionsBounded(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    max_pending: usize,
    max_entries: usize,
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
        entries = std.math.add(usize, entries, 1) catch
            return error.TooManyFiles;
        if (entries > max_entries) return error.TooManyFiles;
        if (entry.kind == .sym_link) return error.SymlinkComponent;
        if (entry.kind != .file and entry.kind != .directory) continue;

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
            if (!fileExists(commit_path)) try incrementPending(
                &pending,
                max_pending,
            );
            continue;
        }

        if (stat.kind == .directory) {
            if (try transactionDirectoryPending(allocator, entry_path)) {
                try incrementPending(&pending, max_pending);
            }
        }
    }
    return pending;
}

fn incrementPending(pending: *usize, max_pending: usize) !void {
    if (pending.* >= max_pending) return error.TooManyFiles;
    pending.* += 1;
}

fn transactionDirectoryPending(allocator: std.mem.Allocator, transaction_dir: []const u8) !bool {
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    defer allocator.free(record_path);
    const commit_marker_path = try std.fs.path.join(allocator, &.{ transaction_dir, "commit.json" });
    defer allocator.free(commit_marker_path);
    const parsed = parseTransactionRecord(
        allocator,
        record_path,
    ) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
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

const EventStoreExclusiveLock = struct {
    allocator: std.mem.Allocator,
    compatibility: LockFile,
    sidecar: std.Io.File,
    data: ?std.Io.File,

    fn release(self: *EventStoreExclusiveLock) void {
        if (self.data) |file| file.close(Io.io());
        self.sidecar.close(Io.io());
        self.compatibility.release(self.allocator);
        self.* = undefined;
    }
};

fn acquireEventStoreExclusiveLock(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !EventStoreExclusiveLock {
    var compatibility = acquireLock(allocator, store_path) catch |err| switch (err) {
        error.PathAlreadyExists => return error.EventStoreBusy,
        else => return err,
    };
    errdefer compatibility.release(allocator);
    const lock_path = try eventStoreLockPathAlloc(allocator, store_path);
    defer allocator.free(lock_path);
    try ensureParentPath(lock_path);
    var sidecar = try openEventStoreSidecarExclusive(lock_path);
    errdefer sidecar.close(Io.io());
    const data = try openEventStoreDataExclusive(store_path);
    errdefer if (data) |file| file.close(Io.io());
    return .{
        .allocator = allocator,
        .compatibility = compatibility,
        .sidecar = sidecar,
        .data = data,
    };
}

fn openEventStoreSidecarExclusive(path: []const u8) !std.Io.File {
    var attempt: u8 = 0;
    while (attempt < 4) : (attempt += 1) {
        return (if (std.fs.path.isAbsolute(path))
            std.Io.Dir.createFileAbsolute(Io.io(), path, .{
                .exclusive = true,
                .read = true,
                .truncate = false,
                .lock = .exclusive,
                .lock_nonblocking = true,
            })
        else
            std.Io.Dir.cwd().createFile(Io.io(), path, .{
                .exclusive = true,
                .read = true,
                .truncate = false,
                .lock = .exclusive,
                .lock_nonblocking = true,
            })) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => {
                _ = (try statRegularFileNoSymlink(path)) orelse continue;
                return (if (std.fs.path.isAbsolute(path))
                    std.Io.Dir.openFileAbsolute(Io.io(), path, .{
                        .allow_directory = false,
                        .follow_symlinks = false,
                        .lock = .exclusive,
                        .lock_nonblocking = true,
                    })
                else
                    std.Io.Dir.cwd().openFile(Io.io(), path, .{
                        .allow_directory = false,
                        .follow_symlinks = false,
                        .lock = .exclusive,
                        .lock_nonblocking = true,
                    })) catch |open_err| switch (open_err) {
                    error.FileNotFound => continue,
                    error.SymLinkLoop => return error.SymlinkComponent,
                    else => return open_err,
                };
            },
            else => return create_err,
        };
    }
    return error.FileNotFound;
}

fn openEventStoreDataExclusive(store_path: []const u8) !?std.Io.File {
    _ = (try statRegularFileNoSymlink(store_path)) orelse return null;
    // Windows byte-range locks conflict with the exclusive session's own
    // reopened scan and append handles. The stable sidecar remains the
    // canonical same-store exclusion witness on that platform.
    if (@import("builtin").os.tag == .windows) return null;
    var file = (if (std.fs.path.isAbsolute(store_path))
        std.Io.Dir.openFileAbsolute(Io.io(), store_path, .{
            .allow_directory = true,
            .follow_symlinks = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        })
    else
        std.Io.Dir.cwd().openFile(Io.io(), store_path, .{
            .allow_directory = true,
            .follow_symlinks = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        })) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop => return error.SymlinkComponent,
        else => return err,
    };
    errdefer file.close(Io.io());
    const stat = try file.stat(Io.io());
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    return file;
}

fn acquireEventStoreScanSidecar(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !?std.Io.File {
    const path = try eventStoreLockPathAlloc(allocator, store_path);
    defer allocator.free(path);
    _ = (try statRegularFileNoSymlink(path)) orelse return null;
    var file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(Io.io(), path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .shared,
            .lock_nonblocking = true,
        })
    else
        std.Io.Dir.cwd().openFile(Io.io(), path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .shared,
            .lock_nonblocking = true,
        })) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop => return error.SymlinkComponent,
        error.WouldBlock => return error.EventStoreBusy,
        else => return err,
    };
    errdefer file.close(Io.io());
    const stat = try file.stat(Io.io());
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    return file;
}

pub fn acquireLock(allocator: std.mem.Allocator, store_path: []const u8) !LockFile {
    const path = try lockPathAlloc(allocator, store_path);
    errdefer allocator.free(path);
    try ensureParentPath(path);
    var file = try std.Io.Dir.cwd().createFile(Io.io(), path, .{
        .exclusive = true,
        .read = true,
        .truncate = false,
    });
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
    var candidate = try std.fs.path.resolve(allocator, &.{start});
    defer allocator.free(candidate);
    var current: []u8 = while (true) { // tiger: event-loop -- bounded by ancestors.
        const real = std.Io.Dir.cwd().realPathFileAlloc(
            Io.io(),
            candidate,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = std.fs.path.dirname(candidate) orelse return err;
                if (std.mem.eql(u8, parent, candidate)) return err;
                const next = try allocator.dupe(u8, parent);
                allocator.free(candidate);
                candidate = next;
                continue;
            },
            else => return err,
        };
        defer allocator.free(real);
        break try allocator.dupe(u8, real);
    };
    errdefer allocator.free(current);
    while (true) {
        const marker = try std.fmt.allocPrint(allocator, "{s}/.git", .{current});
        defer allocator.free(marker);
        if (fileExists(marker)) return current;

        const parent = std.fs.path.dirname(current) orelse return error.GitCommandFailed;
        if (std.mem.eql(u8, parent, current)) return error.GitCommandFailed;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

pub fn ensureLockSidecarGitignored(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_path: []const u8,
) !void {
    const parent = std.fs.path.dirname(store_path) orelse ".";
    const git_root = findGitRootAlloc(allocator, parent) catch |err| switch (err) {
        error.GitCommandFailed => return,
        else => return err,
    };
    defer allocator.free(git_root);

    const public_path = try lockPathAlloc(allocator, store_path);
    defer allocator.free(public_path);
    try ensurePathGitignored(allocator, io, git_root, public_path);
    const advisory_path = try eventStoreLockPathAlloc(allocator, store_path);
    defer allocator.free(advisory_path);
    try ensurePathGitignored(allocator, io, git_root, advisory_path);
}

fn ensurePathGitignored(
    allocator: std.mem.Allocator,
    io: std.Io,
    git_root: []const u8,
    path: []const u8,
) !void {
    const absolute_path = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(absolute_path);
    const relative_path = try std.fs.path.relative(
        allocator,
        git_root,
        null,
        git_root,
        absolute_path,
    );
    defer allocator.free(relative_path);

    var argv = [_][]const u8{
        "git",
        "-C",
        git_root,
        "check-ignore",
        "-q",
        "--",
        relative_path,
    };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(GitCheckOutputLimit),
        .stderr_limit = .limited(GitCheckOutputLimit),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return;
    if (result.term == .exited and result.term.exited == 1) return error.LockSidecarNotGitignored;
    return error.GitCommandFailed;
}

test "lock ignore admission covers public and advisory paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const git_result = try std.process.run(
        std.testing.allocator,
        std.testing.io,
        .{
            .argv = &.{ "git", "init", "--quiet" },
            .cwd = .{ .path = root },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        },
    );
    defer std.testing.allocator.free(git_result.stdout);
    defer std.testing.allocator.free(git_result.stderr);
    try std.testing.expect(
        git_result.term == .exited and git_result.term.exited == 0,
    );

    const gitignore = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".gitignore" },
    );
    defer std.testing.allocator.free(gitignore);
    try writeTextAtomic(
        std.testing.allocator,
        gitignore,
        "events.jsonl.lock\n",
    );
    const store_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "events.jsonl" },
    );
    defer std.testing.allocator.free(store_path);
    try std.testing.expectError(
        error.LockSidecarNotGitignored,
        ensureLockSidecarGitignored(
            std.testing.allocator,
            std.testing.io,
            store_path,
        ),
    );

    try writeTextAtomic(
        std.testing.allocator,
        gitignore,
        "events.jsonl.lock\n.durable-store-locks/\n",
    );
    try ensureLockSidecarGitignored(
        std.testing.allocator,
        std.testing.io,
        store_path,
    );
}

test "persistent mutation enforces shared lock ignore admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const git_result = try std.process.run(
        std.testing.allocator,
        std.testing.io,
        .{
            .argv = &.{ "git", "init", "--quiet" },
            .cwd = .{ .path = root },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        },
    );
    defer std.testing.allocator.free(git_result.stdout);
    defer std.testing.allocator.free(git_result.stderr);
    try std.testing.expect(
        git_result.term == .exited and git_result.term.exited == 0,
    );

    const gitignore = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".gitignore" },
    );
    defer std.testing.allocator.free(gitignore);
    try writeTextAtomic(
        std.testing.allocator,
        gitignore,
        "events.jsonl.lock\n",
    );
    const store_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "events.jsonl" },
    );
    defer std.testing.allocator.free(store_path);
    try writeTextAtomic(std.testing.allocator, store_path, "{\"sequence\":0}\n");
    var backend = JsonlEventStore.initWithIo(store_path, std.testing.io);
    try std.testing.expectError(
        error.LockSidecarNotGitignored,
        backend.eventStore().acquireExclusive(std.testing.allocator),
    );

    try writeTextAtomic(
        std.testing.allocator,
        gitignore,
        "events.jsonl.lock\n.durable-store-locks/\n",
    );
    var exclusive = try backend.eventStore().acquireExclusive(
        std.testing.allocator,
    );
    exclusive.release();

    try writeTextAtomic(
        std.testing.allocator,
        gitignore,
        "*.jsonl.lock\n.durable-store-locks/\n",
    );
    const prospective_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "missing", "nested", "prospective.jsonl" },
    );
    defer std.testing.allocator.free(prospective_path);
    var prospective = JsonlEventStore.initWithIo(
        prospective_path,
        std.testing.io,
    );
    var prospective_exclusive = try prospective.eventStore().acquireExclusive(
        std.testing.allocator,
    );
    prospective_exclusive.release();
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

    var lock_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lock_json.deinit();
    try lock.writeJson(&lock_json.writer);
    const lock_bytes = try lock_json.toOwnedSlice();
    defer std.testing.allocator.free(lock_bytes);
    try std.testing.expectEqualStrings(
        "{\"lock_version\":\"DLK-v1\",\"lock_id\":\"lock-1\",\"resource\":\"/repo/.ledger/plan.jsonl\",\"owner\":{\"process_id\":1234,\"session_id\":\"session-a\",\"executor\":\"codex\"},\"acquired_at\":\"2026-06-25T14:00:00Z\",\"expires_at\":\"2026-06-25T14:00:05Z\",\"fencing_token\":7,\"transaction_id\":\"txn-1\"}",
        lock_bytes,
    );

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
        "{\"cas_write_receipt\":{\"path\":\"/repo/.ledger/plan.jsonl\",\"digest_before\":null,\"digest_after\":\"sha256:after\",\"sequence_before\":41,\"sequence_after\":42,\"result\":\"written\"}}",
        cas_bytes,
    );

    var transaction_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer transaction_json.deinit();
    try transaction.writeJson(&transaction_json.writer);
    const transaction_bytes = try transaction_json.toOwnedSlice();
    defer std.testing.allocator.free(transaction_bytes);
    try std.testing.expectEqualStrings(
        "{\"transaction_version\":\"DTX-v1\",\"transaction_id\":\"txn-1\",\"owner\":{\"process_id\":1234,\"session_id\":\"session-a\",\"executor\":\"codex\"},\"state\":\"prepared\",\"expected\":[{\"path\":\"/repo/.ledger/plan.jsonl\",\"digest\":\"sha256:before\",\"sequence\":41}],\"writes\":[{\"path\":\"/repo/.ledger/plan.jsonl\",\"staged_ref\":\"transactions/txn-1/plan.jsonl\",\"digest_after\":\"sha256:after\",\"sequence_after\":42}],\"locks\":[{\"lock_version\":\"DLK-v1\",\"lock_id\":\"lock-1\",\"resource\":\"/repo/.ledger/plan.jsonl\",\"owner\":{\"process_id\":1234,\"session_id\":\"session-a\",\"executor\":\"codex\"},\"acquired_at\":\"2026-06-25T14:00:00Z\",\"expires_at\":\"2026-06-25T14:00:05Z\",\"fencing_token\":7,\"transaction_id\":\"txn-1\"}],\"created_at\":\"2026-06-25T14:00:00Z\",\"updated_at\":\"2026-06-25T14:00:01Z\"}",
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

    var first = try writeTextAtomicCas(
        std.testing.allocator,
        path,
        "{\"seq\":1,\"ok\":true}\n",
        .{ .expected_exists = false },
    );
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

    try std.testing.expectError(
        error.DigestMismatch,
        writeTextAtomicCas(
            std.testing.allocator,
            path,
            "{\"seq\":3}\n",
            .{ .expected_digest = first.digest_after },
        ),
    );
    try std.testing.expectError(
        error.SequenceMismatch,
        writeTextAtomicCas(
            std.testing.allocator,
            path,
            "{\"seq\":3}\n",
            .{ .expected_sequence = 1 },
        ),
    );
    try std.testing.expectError(
        error.ExpectationMismatch,
        writeTextAtomicCas(
            std.testing.allocator,
            path,
            "{\"seq\":3}\n",
            .{ .expected_exists = false },
        ),
    );

    var snapshot = try readJsonlSnapshot(std.testing.allocator, path, 2);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 2), snapshot.sequence);
    try std.testing.expectEqualStrings(second.digest_after, snapshot.digest);
    try std.testing.expectError(
        error.SequenceMismatch,
        readJsonlSnapshot(std.testing.allocator, path, 1),
    );

    var committed = try commitJsonlSnapshotCas(
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
            std.testing.allocator,
            path,
            "not-json\n",
            .{ .expected_sequence = 3 },
            null,
        ),
    );
}

const CasWorkerContext = struct {
    path: []const u8,
    result: ?anyerror = null,
};

fn runCasWorker(context: *CasWorkerContext) void {
    var receipt = writeTextAtomicCas(
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
    try std.Io.sleep(Io.io(), .fromMilliseconds(10), .awake);
    try writeTextAtomic(std.testing.allocator, path, "{\"seq\":2,\"main\":true}\n");
    held_lock.release(std.testing.allocator);
    thread.join();

    try std.testing.expect(context.result != null);
    try std.testing.expectEqual(error.SequenceMismatch, context.result.?);
    const final = try tryReadForTest(path);
    defer std.testing.allocator.free(final);
    try std.testing.expectEqualStrings("{\"seq\":2,\"main\":true}\n", final);
}

test "durable transactions atomically publish bounded raw documents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);
    const counter = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "fencing.counter" },
    );
    defer std.testing.allocator.free(counter);
    const document_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "document.json" },
    );
    defer std.testing.allocator.free(document_path);
    const binding_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "binding.json" },
    );
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
    try std.testing.expectEqualStrings(
        "{\"definition_digest\":\"sha256:test\"}\n",
        binding,
    );

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
        try countPendingTransactions(std.testing.allocator, transactions_dir),
    );

    var root_dir = try std.Io.Dir.openDirAbsolute(Io.io(), root, .{});
    defer root_dir.close(Io.io());
    try root_dir.hardLink(
        "document.json",
        root_dir,
        "document-alias.json",
        Io.io(),
        .{},
    );
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
        try countPendingTransactions(std.testing.allocator, transactions_dir),
    );
}

test "transaction publication binds staged bytes before target replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions", "txn-race" },
    );
    defer std.testing.allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const target_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "store.jsonl" },
    );
    defer std.testing.allocator.free(target_path);
    try writeTextCreateNew(
        std.testing.allocator,
        target_path,
        "{\"seq\":1}\n",
        .{},
    );
    const staged_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ transaction_dir, "write-0.staged" },
    );
    defer std.testing.allocator.free(staged_path);
    try writeTextCreateNew(
        std.testing.allocator,
        staged_path,
        "{\"seq\":999}\n",
        .{},
    );
    const expected_digest = try digestBytesAlloc(
        std.testing.allocator,
        "{\"seq\":2}\n",
    );
    defer std.testing.allocator.free(expected_digest);
    var target = try TransactionTarget.init(root, target_path);
    defer target.deinit();
    var staged_dir = try std.Io.Dir.openDirAbsolute(
        Io.io(),
        transaction_dir,
        .{ .follow_symlinks = false },
    );
    defer staged_dir.close(Io.io());

    try std.testing.expectError(
        error.TransactionCorrupt,
        publishVerifiedStagedFile(
            &staged_dir,
            "write-0.staged",
            expected_digest,
            4096,
            &target,
        ),
    );
    const current = try readFileAlloc(
        std.testing.allocator,
        target_path,
        4096,
    );
    defer std.testing.allocator.free(current);
    try std.testing.expectEqualStrings("{\"seq\":1}\n", current);

    try staged_dir.deleteFile(Io.io(), "write-0.staged");
    try staged_dir.symLink(
        Io.io(),
        target_path,
        "write-0.staged",
        .{},
    );
    try std.testing.expectError(
        error.SymlinkComponent,
        publishVerifiedStagedFile(
            &staged_dir,
            "write-0.staged",
            expected_digest,
            4096,
            &target,
        ),
    );
    const after = try readFileAlloc(
        std.testing.allocator,
        target_path,
        4096,
    );
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("{\"seq\":1}\n", after);
}

test "pending transaction bounds exclude committed flat journals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(tmp_root);
    const root = try std.fs.path.join(
        std.testing.allocator,
        &.{ tmp_root, "transactions" },
    );
    defer std.testing.allocator.free(root);
    try ensureDirectoryPathNoSymlinks(root);
    for (0..5) |index| {
        const prepared = try std.fmt.allocPrint(
            std.testing.allocator,
            "transactions/txn-{d}.prepared.json",
            .{index},
        );
        defer std.testing.allocator.free(prepared);
        const committed = try std.fmt.allocPrint(
            std.testing.allocator,
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
        try countPendingTransactionsBounded(
            std.testing.allocator,
            root,
            0,
            16,
        ),
    );
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "transactions/pending.prepared.json",
        .data = "{}\n",
    });
    try std.testing.expectError(
        error.TooManyFiles,
        countPendingTransactionsBounded(
            std.testing.allocator,
            root,
            0,
            16,
        ),
    );
}

test "transaction recovery hashes admitted stores above the snapshot allocation bound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const target = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "large-document.bin" },
    );
    defer std.testing.allocator.free(target);
    const bytes = try std.testing.allocator.alloc(
        u8,
        default_snapshot_max_bytes + 1,
    );
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try writeTextAtomic(std.testing.allocator, target, bytes);
    const digest = try digestBytesAlloc(std.testing.allocator, bytes);
    defer std.testing.allocator.free(digest);
    const writes = [_]TransactionWrite{.{
        .path = target,
        .staged_ref = "write-0.staged",
        .digest_after = digest,
        .sequence_after = 0,
    }};
    const published = try transactionPublishedCount(
        std.testing.allocator,
        root,
        &writes,
        &.{},
    );
    try std.testing.expectEqual(@as(?usize, 1), published);
}

test "durable transactions compare check-only participants without rewriting them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);
    const counter = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "fencing.counter" },
    );
    defer std.testing.allocator.free(counter);
    const guarded_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "guarded.jsonl" },
    );
    defer std.testing.allocator.free(guarded_path);
    const metadata_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "binding.jsonl" },
    );
    defer std.testing.allocator.free(metadata_path);
    const guarded = "{\"seq\":1}\n";
    try writeTextAtomic(std.testing.allocator, guarded_path, guarded);
    const guarded_digest = try digestBytesAlloc(
        std.testing.allocator,
        guarded,
    );
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
        std.testing.allocator,
        guarded_path,
        4096,
    );
    defer std.testing.allocator.free(guarded_after);
    try std.testing.expectEqualStrings(guarded, guarded_after);
    const metadata = try readRegularFileNoSymlink(
        std.testing.allocator,
        metadata_path,
        4096,
    );
    defer std.testing.allocator.free(metadata);
    try std.testing.expectEqualStrings("{\"bound\":true}\n", metadata);

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
    transactions_dir: []const u8,
    counter_path: []const u8,
    guarded_path: []const u8,
    guarded_digest: []const u8,
    metadata_path: []const u8,
    result: ?anyerror = null,
};

fn runGuardedTransaction(context: *GuardedTransactionContext) void {
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "transactions" },
    );
    defer std.testing.allocator.free(transactions_dir);
    const counter = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "fencing.counter" },
    );
    defer std.testing.allocator.free(counter);
    const guarded_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "guarded.jsonl" },
    );
    defer std.testing.allocator.free(guarded_path);
    const metadata_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "binding.jsonl" },
    );
    defer std.testing.allocator.free(metadata_path);
    const before = "{\"seq\":1}\n";
    try writeTextAtomic(std.testing.allocator, guarded_path, before);
    const before_digest = try digestBytesAlloc(std.testing.allocator, before);
    defer std.testing.allocator.free(before_digest);
    const lock_path = try casLockPathAlloc(
        std.testing.allocator,
        guarded_path,
    );
    defer std.testing.allocator.free(lock_path);
    var held_lock = try acquireExclusiveLockPath(
        std.testing.allocator,
        lock_path,
    );
    var context = GuardedTransactionContext{
        .transactions_dir = transactions_dir,
        .counter_path = counter,
        .guarded_path = guarded_path,
        .guarded_digest = before_digest,
        .metadata_path = metadata_path,
    };
    const thread = try std.Thread.spawn(.{}, runGuardedTransaction, .{&context});
    try std.Io.sleep(Io.io(), .fromMilliseconds(10), .awake);
    try writeTextAtomic(
        std.testing.allocator,
        guarded_path,
        "{\"seq\":2}\n",
    );
    held_lock.release(std.testing.allocator);
    thread.join();
    try std.testing.expectEqual(error.DigestMismatch, context.result.?);
    try std.testing.expect(!fileExists(metadata_path));
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
    try std.testing.expectEqual(RecoveryDecision.finish_commit, rollback_status.decision);
    var rollback_receipt = try recoverTransaction(std.testing.allocator, rollback_dir);
    defer rollback_receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, rollback_receipt.decision);
    const rollback_after = try tryReadForTest(rollback_path);
    defer std.testing.allocator.free(rollback_after);
    try std.testing.expectEqualStrings("{\"seq\":2}\n", rollback_after);
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
    try std.testing.expectEqual(RecoveryDecision.finish_commit, mixed_status.decision);
    var mixed_receipt = try recoverTransaction(std.testing.allocator, mixed_dir);
    defer mixed_receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, mixed_receipt.decision);
    const mixed_b_after = try tryReadForTest(mixed_b);
    defer std.testing.allocator.free(mixed_b_after);
    try std.testing.expectEqualStrings("{\"seq\":2}\n", mixed_b_after);
}

test "preparing transaction recovery removes only journal-owned stages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions" },
    );
    defer allocator.free(transactions_dir);
    const transaction_id = "dtx-preparing-recovery";
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, transaction_id },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "events.jsonl" },
    );
    defer allocator.free(target_path);
    const before = "{\"seq\":1}\n";
    try writeTextAtomic(allocator, target_path, before);
    const before_digest = try digestBytesAlloc(allocator, before);
    defer allocator.free(before_digest);
    const staged_ref = try transactionStageNameAlloc(
        allocator,
        transaction_id,
        0,
    );
    defer allocator.free(staged_ref);
    const staged_path = try std.fs.path.join(
        allocator,
        &.{ root, staged_ref },
    );
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
    try writeTextCreateNew(allocator, staged_path, "{\"seq\":2}\n", .{});

    var status = try inspectTransaction(allocator, transaction_dir);
    defer status.deinit(allocator);
    try std.testing.expectEqual(
        RecoveryDecision.roll_back_unpublished,
        status.decision,
    );
    var receipt = try recoverTransaction(allocator, transaction_dir);
    defer receipt.deinit(allocator);
    try std.testing.expectEqual(
        RecoveryDecision.roll_back_unpublished,
        receipt.decision,
    );
    try std.testing.expect(!fileExists(staged_path));
    const after = try tryReadForTest(target_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "transaction recovery removes an empty pre-record journal directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transactions_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions" },
    );
    defer allocator.free(transactions_dir);
    const incomplete_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-incomplete" },
    );
    defer allocator.free(incomplete_dir);
    try ensureDirectoryPathNoSymlinks(incomplete_dir);

    try std.testing.expectEqual(
        @as(usize, 1),
        try countPendingTransactions(allocator, transactions_dir),
    );
    try recoverAndCompactTransactions(allocator, transactions_dir);
    try std.testing.expect(!fileExists(incomplete_dir));
}

test "transaction records reject non-reserved and target-aliased stages" {
    const transaction_id = "dtx-stage-authority";
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
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope("/repo/.ledger", .{
            .transaction_id = transaction_id,
            .owner = owner,
            .state = .preparing,
            .expected = &expected,
            .writes = &invalid,
            .created_at = "1",
            .updated_at = "2",
        }),
    );
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

test "writeTextCreateNewAtomic links only complete new files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "records", "record.json" });
    defer std.testing.allocator.free(path);

    try writeTextCreateNewAtomic(std.testing.allocator, path, "{\"ok\":true}\n", .{});
    try std.testing.expectError(error.PathAlreadyExists, writeTextCreateNewAtomic(std.testing.allocator, path, "{\"ok\":false}\n", .{}));
    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", data);
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

test "private cache paths reject shared permissions" {
    if (!@hasDecl(std.Io.File.Permissions, "fromMode")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        allocator,
    );
    defer allocator.free(root);
    const private_dir = try std.fs.path.join(
        allocator,
        &.{ root, "private" },
    );
    defer allocator.free(private_dir);
    try ensurePrivateDirectoryPathNoSymlinks(private_dir);
    const private_path = try std.fs.path.join(
        allocator,
        &.{ private_dir, "entry.bin" },
    );
    defer allocator.free(private_path);
    try writeTextAtomicPrivate(allocator, private_path, "plan");
    const bytes = try readPrivateRegularFileNoSymlink(
        allocator,
        private_path,
        16,
    );
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("plan", bytes);
    try std.Io.Dir.cwd().setFilePermissions(
        std.testing.io,
        private_path,
        std.Io.File.Permissions.fromMode(0o644),
        .{ .follow_symlinks = false },
    );
    try std.testing.expectError(
        error.InsecurePrivateFile,
        readPrivateRegularFileNoSymlink(allocator, private_path, 16),
    );
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

test "atomic copy byte budget includes the exact cap" {
    try std.testing.expectEqual(
        @as(usize, 8),
        try addCopiedBytesWithinLimit(3, 5, 8),
    );
    try std.testing.expectEqual(
        @as(usize, 7),
        try addCopiedBytesWithinLimit(3, 4, 8),
    );
    try std.testing.expectError(
        error.StreamTooLong,
        addCopiedBytesWithinLimit(3, 6, 8),
    );
    try std.testing.expectError(
        error.StreamTooLong,
        addCopiedBytesWithinLimit(std.math.maxInt(usize), 1, std.math.maxInt(usize)),
    );
}

test "appendLineAtomic accepts an existing source at the exact cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "store.jsonl" });
    defer std.testing.allocator.free(path);

    try writeTextAtomic(std.testing.allocator, path, "12345678");
    try appendLineAtomic(std.testing.allocator, path, "{}", 8);
    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("12345678\n{}\n", data);
}

test "appendLineStreaming appends without reading capped existing log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.ndjson" });
    defer std.testing.allocator.free(path);

    const large = try std.testing.allocator.alloc(u8, 2048);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try writeTextAtomic(std.testing.allocator, path, large);
    try std.testing.expectError(error.StreamTooLong, appendLineAtomic(std.testing.allocator, path, "{\"n\":1}", 1024));
    try appendLineStreaming(std.testing.allocator, path, "{\"n\":1}", .{});

    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, 2048 + "\n{\"n\":1}\n".len), data.len);
    try std.testing.expectEqualStrings("\n{\"n\":1}\n", data[2048..]);
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

const EventScanProbe = struct {
    count: usize = 0,
    last_ordinal: u64 = 0,

    fn visit(context: *anyopaque, record: EventRecordView) !void {
        const self: *EventScanProbe = @ptrCast(@alignCast(context));
        self.count += 1;
        self.last_ordinal = record.ordinal;
    }

    fn visitor(self: *EventScanProbe) EventRecordVisitor {
        return .{ .context = self, .visitFn = visit };
    }
};

const RawEventScanProbe = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn visit(_: *anyopaque, _: EventRecordView) !void {}

    fn observeRaw(context: *anyopaque, bytes: []const u8) !void {
        const self: *RawEventScanProbe = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(std.testing.allocator, bytes);
    }

    fn visitor(self: *RawEventScanProbe) EventRecordVisitor {
        return .{
            .context = self,
            .visitFn = visit,
            .rawFn = observeRaw,
        };
    }

    fn deinit(self: *RawEventScanProbe) void {
        self.bytes.deinit(std.testing.allocator);
        self.* = undefined;
    }
};

fn createFifoForTest(path: []const u8) !void {
    const result = try std.process.run(
        std.testing.allocator,
        std.testing.io,
        .{
            .argv = &.{ "mkfifo", path },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(1024),
        },
    );
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.MkfifoFailed;
    }
}

const GrowingEventScanProbe = struct {
    path: []const u8,
    count: usize = 0,
    expanded: bool = false,

    fn visit(context: *anyopaque, _: EventRecordView) !void {
        const self: *GrowingEventScanProbe = @ptrCast(@alignCast(context));
        self.count += 1;
        if (self.expanded) return;
        self.expanded = true;
        try appendLineStreaming(
            std.testing.allocator,
            self.path,
            "{\"n\":2}",
            .{ .sync = false },
        );
        try appendLineStreaming(
            std.testing.allocator,
            self.path,
            "{\"n\":3}",
            .{ .sync = false },
        );
    }

    fn visitor(self: *GrowingEventScanProbe) EventRecordVisitor {
        return .{ .context = self, .visitFn = visit };
    }
};

const ReentrantEventScanProbe = struct {
    store: EventStore,
    count: usize = 0,
    acquisition_rejected: bool = false,
    mutation_rejected: bool = false,

    fn visit(context: *anyopaque, _: EventRecordView) !void {
        const self: *ReentrantEventScanProbe = @ptrCast(@alignCast(context));
        self.count += 1;
        if (self.count != 1) return;
        if (self.store.acquireExclusive(std.testing.allocator)) |session| {
            var exclusive = session;
            exclusive.release();
            return error.ExpectedEventStoreBusy;
        } else |err| switch (err) {
            error.EventStoreBusy => self.acquisition_rejected = true,
            else => return err,
        }
        const replacement = [_][]const u8{"{\"sequence\":99}"};
        var receipt = self.store.replace(
            std.testing.allocator,
            &replacement,
            .{},
            4096,
        ) catch |err| switch (err) {
            error.EventStoreBusy => {
                self.mutation_rejected = true;
                return;
            },
            else => return err,
        };
        defer receipt.deinit(std.testing.allocator);
        return error.ExpectedEventStoreBusy;
    }

    fn visitor(self: *ReentrantEventScanProbe) EventRecordVisitor {
        return .{ .context = self, .visitFn = visit };
    }
};

const ReentrantExclusiveScanProbe = struct {
    store: *const EventStoreExclusive,
    count: usize = 0,
    mutation_rejected: bool = false,

    fn visit(context: *anyopaque, _: EventRecordView) !void {
        const self: *ReentrantExclusiveScanProbe = @ptrCast(@alignCast(context));
        self.count += 1;
        if (self.count != 1) return;
        const replacement = [_][]const u8{"{\"sequence\":99}"};
        var receipt = self.store.replace(
            std.testing.allocator,
            &replacement,
            .{},
            4096,
        ) catch |err| switch (err) {
            error.EventStoreBusy => {
                self.mutation_rejected = true;
                return;
            },
            else => return err,
        };
        defer receipt.deinit(std.testing.allocator);
        return error.ExpectedEventStoreBusy;
    }

    fn visitor(self: *ReentrantExclusiveScanProbe) EventRecordVisitor {
        return .{ .context = self, .visitFn = visit };
    }
};

const EquivalentHandleEventScanProbe = struct {
    store: EventStore,
    count: usize = 0,
    mutation_rejected: bool = false,

    fn visit(context: *anyopaque, _: EventRecordView) !void {
        const self: *EquivalentHandleEventScanProbe = @ptrCast(@alignCast(context));
        self.count += 1;
        if (self.count != 1) return;
        const replacement = [_][]const u8{"{\"sequence\":99}"};
        var receipt = self.store.replace(
            std.testing.allocator,
            &replacement,
            .{},
            4096,
        ) catch |err| switch (err) {
            error.EventStoreBusy, error.PathAlreadyExists => {
                self.mutation_rejected = true;
                return;
            },
            else => return err,
        };
        defer receipt.deinit(std.testing.allocator);
        return error.ExpectedEventStoreBusy;
    }

    fn visitor(self: *EquivalentHandleEventScanProbe) EventRecordVisitor {
        return .{ .context = self, .visitFn = visit };
    }
};

const ReleaseDuringExclusiveScanProbe = struct {
    session: *EventStoreExclusive,
    contender: EventStore,
    count: usize = 0,
    mutation_rejected: bool = false,

    fn visit(context: *anyopaque, _: EventRecordView) !void {
        const self: *ReleaseDuringExclusiveScanProbe = @ptrCast(
            @alignCast(context),
        );
        self.count += 1;
        if (self.count != 1) return;
        self.session.release();
        if (self.session.active) return error.ExpectedReleasedSession;
        const replacement = [_][]const u8{"{\"sequence\":99}"};
        var receipt = self.contender.replace(
            std.testing.allocator,
            &replacement,
            .{},
            4096,
        ) catch |err| switch (err) {
            error.EventStoreBusy, error.PathAlreadyExists => {
                self.mutation_rejected = true;
                return;
            },
            else => return err,
        };
        defer receipt.deinit(std.testing.allocator);
        return error.ExpectedEventStoreBusy;
    }

    fn visitor(self: *ReleaseDuringExclusiveScanProbe) EventRecordVisitor {
        return .{ .context = self, .visitFn = visit };
    }
};

fn assertEventStoreRejectsReentrantMutation(store: EventStore) !void {
    const records = [_][]const u8{
        "{\"sequence\":1}",
        "{\"sequence\":2}",
    };
    var seeded = try store.replace(
        std.testing.allocator,
        &records,
        .{ .exists = false },
        4096,
    );
    defer seeded.deinit(std.testing.allocator);

    var probe = ReentrantEventScanProbe{ .store = store };
    var summary = try store.scan(std.testing.allocator, 4096, probe.visitor());
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(probe.acquisition_rejected);
    try std.testing.expect(probe.mutation_rejected);
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    try std.testing.expectEqual(@as(usize, 2), summary.record_count);

    var snapshot = try store.snapshot(std.testing.allocator, 4096);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.records.len);
    try std.testing.expectEqualStrings(records[0], snapshot.records[0].payload);
    try std.testing.expectEqualStrings(records[1], snapshot.records[1].payload);

    var exclusive = try store.acquireExclusive(std.testing.allocator);
    defer exclusive.release();
    var exclusive_probe = ReentrantExclusiveScanProbe{ .store = &exclusive };
    var exclusive_summary = try exclusive.scan(
        std.testing.allocator,
        4096,
        exclusive_probe.visitor(),
    );
    defer exclusive_summary.deinit(std.testing.allocator);
    try std.testing.expect(exclusive_probe.mutation_rejected);
    try std.testing.expectEqual(@as(usize, 2), exclusive_probe.count);
    try std.testing.expectEqual(@as(usize, 2), exclusive_summary.record_count);
}

fn assertEventStoreContract(store: EventStore) !void {
    var initial = try store.snapshot(std.testing.allocator, 4096);
    defer initial.deinit(std.testing.allocator);
    try std.testing.expect(!initial.exists);
    try std.testing.expectEqual(@as(usize, 0), initial.records.len);
    try std.testing.expectError(error.InvalidEventPayload, store.append(
        std.testing.allocator,
        "not-json",
        .{ .revision = initial.revision, .exists = false },
        4096,
    ));

    var first = try store.append(
        std.testing.allocator,
        "{\"schema\":\"event/v1\",\"sequence\":1}",
        .{ .revision = initial.revision, .exists = false },
        4096,
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), first.record_count_before);
    try std.testing.expectEqual(@as(usize, 1), first.record_count_after);

    var after_first = try store.snapshot(std.testing.allocator, 4096);
    defer after_first.deinit(std.testing.allocator);
    try std.testing.expect(after_first.exists);
    try std.testing.expectEqual(@as(usize, 1), after_first.records.len);
    try std.testing.expectEqualStrings(
        "{\"schema\":\"event/v1\",\"sequence\":1}",
        after_first.records[0].payload,
    );
    try std.testing.expectEqualStrings(first.revision_after, after_first.revision);
    try std.testing.expectError(error.ExpectationMismatch, store.append(
        std.testing.allocator,
        "{\"schema\":\"event/v1\",\"sequence\":2}",
        .{ .revision = initial.revision, .exists = true },
        4096,
    ));
    try std.testing.expectError(error.StreamTooLong, store.append(
        std.testing.allocator,
        "{\"schema\":\"event/v1\",\"sequence\":2}",
        .{ .revision = after_first.revision, .exists = true },
        after_first.extent_bytes + 1,
    ));
    var after_rejected_append = try store.snapshot(std.testing.allocator, 4096);
    defer after_rejected_append.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(after_first.revision, after_rejected_append.revision);
    const oversized_replacement = [_][]const u8{
        "{\"schema\":\"event/v1\",\"sequence\":2,\"padding\":\"too-large\"}",
    };
    try std.testing.expectError(error.StreamTooLong, store.replace(
        std.testing.allocator,
        &oversized_replacement,
        .{ .revision = after_first.revision, .exists = true },
        after_first.extent_bytes,
    ));
    var after_rejected_replace = try store.snapshot(std.testing.allocator, 4096);
    defer after_rejected_replace.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(after_first.revision, after_rejected_replace.revision);

    const replacement = [_][]const u8{
        "{\"schema\":\"event/v1\",\"sequence\":1}",
        "{\"schema\":\"event/v1\",\"sequence\":2}",
    };
    var replaced = try store.replace(
        std.testing.allocator,
        &replacement,
        .{ .revision = after_first.revision, .exists = true },
        4096,
    );
    defer replaced.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), replaced.record_count_after);
    var final = try store.snapshot(std.testing.allocator, 4096);
    defer final.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), final.records.len);
    try std.testing.expectEqualStrings(replaced.content_digest_after, final.content_digest);
    var probe = EventScanProbe{};
    var summary = try store.scan(std.testing.allocator, 4096, probe.visitor());
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(final.exists, summary.exists);
    try std.testing.expectEqualStrings(final.revision, summary.revision);
    try std.testing.expectEqualStrings(final.content_digest, summary.content_digest);
    try std.testing.expectEqual(final.records.len, summary.record_count);
    try std.testing.expectEqual(final.blank_entries, summary.blank_entries);
    try std.testing.expectEqual(final.extent_bytes, summary.extent_bytes);
    try std.testing.expectEqual(final.append_separator_bytes, summary.append_separator_bytes);
    try std.testing.expectEqual(summary.record_count, probe.count);
    try std.testing.expectEqual(@as(u64, @intCast(summary.record_count)), probe.last_ordinal);
}

fn assertExclusiveEventStoreContract(store: EventStore) !void {
    var exclusive = try store.acquireExclusive(std.testing.allocator);
    defer exclusive.release();
    try std.testing.expectError(error.EventStoreBusy, store.acquireExclusive(std.testing.allocator));
    var ordinary_probe = EventScanProbe{};
    try std.testing.expectError(error.EventStoreBusy, store.scan(
        std.testing.allocator,
        4096,
        ordinary_probe.visitor(),
    ));
    try std.testing.expectError(
        error.EventStoreBusy,
        store.snapshot(std.testing.allocator, 4096),
    );

    var initial = try exclusive.snapshot(std.testing.allocator, 4096);
    defer initial.deinit(std.testing.allocator);
    var receipt = try exclusive.append(
        std.testing.allocator,
        "{\"schema\":\"exclusive-event/v1\",\"sequence\":1}",
        .{ .revision = initial.revision, .exists = false },
        4096,
    );
    defer receipt.deinit(std.testing.allocator);
    exclusive.release();
    try std.testing.expectError(error.EventStoreSessionReleased, exclusive.snapshot(std.testing.allocator, 4096));

    var reacquired = try store.acquireExclusive(std.testing.allocator);
    reacquired.release();
}

test "event store contract is backend independent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(path);

    var persistent_backend = PersistentEventStore.init(path);
    try assertEventStoreContract(persistent_backend.eventStore());

    var memory_backend = MemoryEventStore.init(std.testing.allocator, "memory:test");
    defer memory_backend.deinit();
    try assertEventStoreContract(memory_backend.eventStore());

    var persistent_snapshot = try persistent_backend.eventStore().snapshot(std.testing.allocator, 4096);
    defer persistent_snapshot.deinit(std.testing.allocator);
    var memory_snapshot = try memory_backend.eventStore().snapshot(std.testing.allocator, 4096);
    defer memory_snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(persistent_snapshot.records.len, memory_snapshot.records.len);
    try std.testing.expectEqualStrings(persistent_snapshot.content_digest, memory_snapshot.content_digest);
    for (persistent_snapshot.records, memory_snapshot.records) |persistent_record, memory_record| {
        try std.testing.expectEqualStrings(persistent_record.payload, memory_record.payload);
    }
}

test "event scans expose exact raw bytes in the same physical pass" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "events.jsonl" },
    );
    defer std.testing.allocator.free(path);
    const records = [_][]const u8{
        "{\"sequence\":1}",
        "{\"sequence\":2}",
    };
    const expected = records[0] ++ "\n" ++ records[1] ++ "\n";

    var persistent = PersistentEventStore.init(path);
    var persistent_receipt = try persistent.eventStore().replace(
        std.testing.allocator,
        &records,
        .{ .exists = false },
        4096,
    );
    defer persistent_receipt.deinit(std.testing.allocator);
    var persistent_probe = RawEventScanProbe{};
    defer persistent_probe.deinit();
    var persistent_summary = try persistent.eventStore().scan(
        std.testing.allocator,
        4096,
        persistent_probe.visitor(),
    );
    defer persistent_summary.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, persistent_probe.bytes.items);

    var memory = MemoryEventStore.init(std.testing.allocator, "memory:raw");
    defer memory.deinit();
    var memory_receipt = try memory.eventStore().replace(
        std.testing.allocator,
        &records,
        .{ .exists = false },
        4096,
    );
    defer memory_receipt.deinit(std.testing.allocator);
    var memory_probe = RawEventScanProbe{};
    defer memory_probe.deinit();
    var memory_summary = try memory.eventStore().scan(
        std.testing.allocator,
        4096,
        memory_probe.visitor(),
    );
    defer memory_summary.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, memory_probe.bytes.items);
}

test "event store backends share canonical padded-event observations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "padded.jsonl" });
    defer std.testing.allocator.free(path);
    try writeTextAtomic(std.testing.allocator, path, " \n{\"a\":1}\n\t\n");

    var persistent_backend = PersistentEventStore.init(path);
    var persistent_snapshot = try persistent_backend.eventStore().snapshot(
        std.testing.allocator,
        4096,
    );
    defer persistent_snapshot.deinit(std.testing.allocator);

    var memory_backend = MemoryEventStore.init(std.testing.allocator, "memory:padded");
    defer memory_backend.deinit();
    const padded_records = [_][]const u8{ " ", "  {\"a\":1} \t", "\t" };
    for (padded_records) |payload| {
        try memory_backend.records.append(
            memory_backend.allocator,
            try memory_backend.allocator.dupe(u8, payload),
        );
    }
    memory_backend.exists = true;
    var memory_snapshot = try memory_backend.eventStore().snapshot(
        std.testing.allocator,
        4096,
    );
    defer memory_snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        persistent_snapshot.records[0].payload,
        memory_snapshot.records[0].payload,
    );
    try std.testing.expectEqualStrings(
        persistent_snapshot.content_digest,
        memory_snapshot.content_digest,
    );
    try std.testing.expectEqual(@as(usize, 1), memory_snapshot.records.len);
    try std.testing.expectEqual(@as(u64, 1), memory_snapshot.records[0].ordinal);
    try std.testing.expectEqual(
        persistent_snapshot.blank_entries,
        memory_snapshot.blank_entries,
    );
    try std.testing.expectEqual(@as(usize, 2), memory_snapshot.blank_entries);
    try std.testing.expect(!std.mem.eql(
        u8,
        persistent_snapshot.revision,
        memory_snapshot.revision,
    ));
    try std.testing.expectEqual(
        @as(usize, " \n  {\"a\":1} \t\n\t\n".len),
        memory_snapshot.extent_bytes,
    );
}

test "event store backends reject reentrant mutation during scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "reentrant.jsonl" });
    defer std.testing.allocator.free(path);

    var persistent_backend = PersistentEventStore.init(path);
    try assertEventStoreRejectsReentrantMutation(persistent_backend.eventStore());

    var equivalent_backend = PersistentEventStore.init(path);
    var before_alias_scan = try persistent_backend.eventStore().snapshot(
        std.testing.allocator,
        4096,
    );
    defer before_alias_scan.deinit(std.testing.allocator);
    var equivalent_probe = EquivalentHandleEventScanProbe{
        .store = equivalent_backend.eventStore(),
    };
    var equivalent_summary = try persistent_backend.eventStore().scan(
        std.testing.allocator,
        4096,
        equivalent_probe.visitor(),
    );
    defer equivalent_summary.deinit(std.testing.allocator);
    try std.testing.expect(equivalent_probe.mutation_rejected);
    try std.testing.expectEqual(@as(usize, 2), equivalent_probe.count);
    try std.testing.expectEqual(@as(usize, 2), equivalent_summary.record_count);
    var after_alias_scan = try persistent_backend.eventStore().snapshot(
        std.testing.allocator,
        4096,
    );
    defer after_alias_scan.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        before_alias_scan.revision,
        after_alias_scan.revision,
    );

    var memory_backend = MemoryEventStore.init(std.testing.allocator, "memory:reentrant");
    defer memory_backend.deinit();
    try assertEventStoreRejectsReentrantMutation(memory_backend.eventStore());
}

test "jsonl scan maps open-time missing store to an empty summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "missing.jsonl" });
    defer std.testing.allocator.free(path);
    const lock_path = try lockPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(lock_path);

    var backend = JsonlEventStore.init(path);
    var probe = EventScanProbe{};
    var summary = try backend.eventStore().scan(
        std.testing.allocator,
        4096,
        probe.visitor(),
    );
    defer summary.deinit(std.testing.allocator);

    try std.testing.expect(!summary.exists);
    try std.testing.expectEqual(@as(usize, 0), summary.record_count);
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try std.testing.expect(!fileExists(path));
    try std.testing.expect(!fileExists(lock_path));
}

test "jsonl scans require no parent write and tolerate unlocked sidecars" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const parent = try std.fs.path.join(std.testing.allocator, &.{ root, "read-only" });
    defer std.testing.allocator.free(parent);
    try ensureDirectoryPathNoSymlinks(parent);
    const path = try std.fs.path.join(std.testing.allocator, &.{ parent, "events.jsonl" });
    defer std.testing.allocator.free(path);
    const public_lock_path = try lockPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(public_lock_path);
    const advisory_path = try eventStoreLockPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(advisory_path);
    try writeTextAtomic(std.testing.allocator, path, "{\"n\":1}\n");

    var parent_dir = try std.Io.Dir.openDirAbsolute(Io.io(), parent, .{
        .iterate = true,
    });
    defer parent_dir.close(Io.io());
    const writable = std.Io.File.Permissions.fromMode(0o755);
    const read_only = std.Io.File.Permissions.fromMode(0o555);
    try parent_dir.setPermissions(Io.io(), read_only);
    defer parent_dir.setPermissions(Io.io(), writable) catch |err| {
        std.debug.panic("restore test directory permissions: {s}", .{
            @errorName(err),
        });
    };

    var backend = JsonlEventStore.init(path);
    var first = try backend.eventStore().snapshot(std.testing.allocator, 4096);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.records.len);
    try std.testing.expect(!fileExists(public_lock_path));
    try std.testing.expect(!fileExists(advisory_path));

    try parent_dir.setPermissions(Io.io(), writable);
    try ensureParentPath(advisory_path);
    try writeTextCreateNew(std.testing.allocator, advisory_path, "", .{});
    try parent_dir.setPermissions(Io.io(), read_only);
    var second = try backend.eventStore().snapshot(std.testing.allocator, 4096);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.revision, second.revision);
    try std.testing.expect(!fileExists(public_lock_path));
    try std.testing.expect(fileExists(advisory_path));

    try parent_dir.setPermissions(Io.io(), writable);
    var exclusive = try backend.eventStore().acquireExclusive(std.testing.allocator);
    exclusive.release();
    try std.testing.expect(!fileExists(public_lock_path));
    try std.testing.expect(fileExists(advisory_path));
}

test "jsonl scan classifies a final symlink as SymlinkComponent" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(path);
    const link = try std.fs.path.join(std.testing.allocator, &.{ root, "events-link.jsonl" });
    defer std.testing.allocator.free(link);
    try writeTextAtomic(std.testing.allocator, path, "{\"n\":1}\n");
    try tmp.dir.symLink(Io.io(), "events.jsonl", "events-link.jsonl", .{});

    var backend = JsonlEventStore.init(link);
    try std.testing.expectError(
        error.SymlinkComponent,
        backend.eventStore().snapshot(std.testing.allocator, 4096),
    );
}

test "EventStore rejects special data and advisory files before open" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);

    const special_data = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "special-data.jsonl" },
    );
    defer std.testing.allocator.free(special_data);
    try createFifoForTest(special_data);
    var data_backend = PersistentEventStore.init(special_data);
    try std.testing.expectError(
        error.NotFile,
        data_backend.eventStore().snapshot(std.testing.allocator, 4096),
    );
    try std.testing.expectError(
        error.NotFile,
        data_backend.eventStore().acquireExclusive(std.testing.allocator),
    );

    const regular_data = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "regular-data.jsonl" },
    );
    defer std.testing.allocator.free(regular_data);
    try writeTextAtomic(
        std.testing.allocator,
        regular_data,
        "{\"sequence\":1}\n",
    );
    const special_advisory = try eventStoreLockPathAlloc(
        std.testing.allocator,
        regular_data,
    );
    defer std.testing.allocator.free(special_advisory);
    try ensureParentPath(special_advisory);
    try createFifoForTest(special_advisory);
    var advisory_backend = PersistentEventStore.init(regular_data);
    try std.testing.expectError(
        error.NotFile,
        advisory_backend.eventStore().snapshot(
            std.testing.allocator,
            4096,
        ),
    );
    try std.testing.expectError(
        error.NotFile,
        advisory_backend.eventStore().acquireExclusive(
            std.testing.allocator,
        ),
    );
}

test "jsonl scan preserves completed visitor calls before a terminal error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "growing.jsonl" });
    defer std.testing.allocator.free(path);
    try writeTextAtomic(std.testing.allocator, path, "{\"n\":1}\n");

    var backend = JsonlEventStore.init(path);
    var probe = GrowingEventScanProbe{ .path = path };
    try std.testing.expectError(
        error.StreamTooLong,
        backend.eventStore().scan(std.testing.allocator, 16, probe.visitor()),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.count);
}

test "ordinary scans reject active exclusive sessions across backends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "exclusive-events.jsonl" });
    defer std.testing.allocator.free(path);

    var persistent_backend = PersistentEventStore.init(path);
    try assertExclusiveEventStoreContract(persistent_backend.eventStore());

    var memory_backend = MemoryEventStore.init(std.testing.allocator, "memory:exclusive-test");
    defer memory_backend.deinit();
    try assertExclusiveEventStoreContract(memory_backend.eventStore());
}

test "exclusive release requested by a visitor waits for scan completion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "release-during-scan.jsonl" },
    );
    defer std.testing.allocator.free(path);

    var owner_backend = PersistentEventStore.init(path);
    const records = [_][]const u8{
        "{\"sequence\":1}",
        "{\"sequence\":2}",
    };
    var seeded = try owner_backend.eventStore().replace(
        std.testing.allocator,
        &records,
        .{ .exists = false },
        4096,
    );
    defer seeded.deinit(std.testing.allocator);

    var contender_backend = PersistentEventStore.init(path);
    const contender = contender_backend.eventStore();
    var exclusive = try owner_backend.eventStore().acquireExclusive(
        std.testing.allocator,
    );
    defer exclusive.release();
    var probe = ReleaseDuringExclusiveScanProbe{
        .session = &exclusive,
        .contender = contender,
    };
    var summary = try exclusive.scan(
        std.testing.allocator,
        4096,
        probe.visitor(),
    );
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(probe.mutation_rejected);
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    try std.testing.expectEqual(@as(usize, 2), summary.record_count);
    try std.testing.expect(!exclusive.active);
    try std.testing.expect(!exclusive.release_pending);

    var after_scan = try contender.acquireExclusive(std.testing.allocator);
    after_scan.release();
}

test "EventStore advisory paths use a disjoint reserved namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const first = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "events" },
    );
    defer std.testing.allocator.free(first);
    const formerly_colliding = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "events.event-store" },
    );
    defer std.testing.allocator.free(formerly_colliding);
    const first_advisory = try eventStoreLockPathAlloc(
        std.testing.allocator,
        first,
    );
    defer std.testing.allocator.free(first_advisory);
    const second_public = try lockPathAlloc(
        std.testing.allocator,
        formerly_colliding,
    );
    defer std.testing.allocator.free(second_public);
    try std.testing.expect(!std.mem.eql(
        u8,
        first_advisory,
        second_public,
    ));

    const reserved_resource = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, event_store_lock_dir_name, "resource" },
    );
    defer std.testing.allocator.free(reserved_resource);
    try std.testing.expectError(
        error.ReservedStorePath,
        lockPathAlloc(std.testing.allocator, reserved_resource),
    );
    try std.testing.expectError(
        error.ReservedStorePath,
        eventStoreLockPathAlloc(
            std.testing.allocator,
            reserved_resource,
        ),
    );
    const reserved_case_alias = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".DURABLE-STORE-LOCKS", "resource" },
    );
    defer std.testing.allocator.free(reserved_case_alias);
    try std.testing.expectError(
        error.ReservedStorePath,
        lockPathAlloc(std.testing.allocator, reserved_case_alias),
    );
    try std.testing.expectError(
        error.ReservedStorePath,
        eventStoreLockPathAlloc(
            std.testing.allocator,
            reserved_case_alias,
        ),
    );
}

test "EventStore advisory paths preserve existing filesystem case identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const canonical_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "Events.jsonl" },
    );
    defer std.testing.allocator.free(canonical_path);
    const case_alias = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "events.jsonl" },
    );
    defer std.testing.allocator.free(case_alias);
    try writeTextAtomic(
        std.testing.allocator,
        canonical_path,
        "{\"sequence\":1}\n",
    );

    const alias_real_path = std.Io.Dir.cwd().realPathFileAlloc(
        Io.io(),
        case_alias,
        std.testing.allocator,
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer std.testing.allocator.free(alias_real_path);
    try std.testing.expectEqualStrings(canonical_path, alias_real_path);

    const canonical_advisory = try eventStoreLockPathAlloc(
        std.testing.allocator,
        canonical_path,
    );
    defer std.testing.allocator.free(canonical_advisory);
    const alias_advisory = try eventStoreLockPathAlloc(
        std.testing.allocator,
        case_alias,
    );
    defer std.testing.allocator.free(alias_advisory);
    try std.testing.expectEqualStrings(canonical_advisory, alias_advisory);
}

test "EventStore prospective case identity follows the host filesystem" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const canonical_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "Events.jsonl" },
    );
    defer std.testing.allocator.free(canonical_path);
    const case_alias = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "events.jsonl" },
    );
    defer std.testing.allocator.free(case_alias);
    const case_insensitive = try directoryNamesAreCaseInsensitive(
        std.testing.allocator,
        root,
    );
    const canonical_advisory = try eventStoreLockPathAlloc(
        std.testing.allocator,
        canonical_path,
    );
    defer std.testing.allocator.free(canonical_advisory);
    const alias_advisory = try eventStoreLockPathAlloc(
        std.testing.allocator,
        case_alias,
    );
    defer std.testing.allocator.free(alias_advisory);
    try std.testing.expectEqual(
        case_insensitive,
        std.mem.eql(u8, canonical_advisory, alias_advisory),
    );
    if (!case_insensitive) return;

    var canonical = JsonlEventStore.initWithIo(
        canonical_path,
        std.testing.io,
    );
    var exclusive = try canonical.eventStore().acquireExclusive(
        std.testing.allocator,
    );
    defer exclusive.release();
    var initial = try exclusive.snapshot(std.testing.allocator, 4096);
    defer initial.deinit(std.testing.allocator);
    var receipt = try exclusive.append(
        std.testing.allocator,
        "{\"schema\":\"event/v1\",\"sequence\":1}",
        .{ .revision = initial.revision, .exists = false },
        4096,
    );
    defer receipt.deinit(std.testing.allocator);
    var alias = JsonlEventStore.initWithIo(case_alias, std.testing.io);
    try std.testing.expectError(
        error.EventStoreBusy,
        alias.eventStore().snapshot(std.testing.allocator, 4096),
    );
}

test "EventStore case probe does not treat directory symlinks as folding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    if (try directoryNamesAreCaseInsensitive(
        std.testing.allocator,
        root,
    )) return;

    try tmp.dir.createDir(Io.io(), "Foo", .default_dir);
    try tmp.dir.symLink(Io.io(), "Foo", "foo", .{ .is_directory = true });
    const upper_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "Foo", "A.jsonl" },
    );
    defer std.testing.allocator.free(upper_path);
    const lower_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "Foo", "a.jsonl" },
    );
    defer std.testing.allocator.free(lower_path);
    const upper_advisory = try eventStoreLockPathAlloc(
        std.testing.allocator,
        upper_path,
    );
    defer std.testing.allocator.free(upper_advisory);
    const lower_advisory = try eventStoreLockPathAlloc(
        std.testing.allocator,
        lower_path,
    );
    defer std.testing.allocator.free(lower_advisory);

    try std.testing.expect(
        !std.mem.eql(u8, upper_advisory, lower_advisory),
    );
}

test "EventStore exclusive sessions bridge public lock protocols" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(path);
    const public_lock_path = try lockPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(public_lock_path);
    const advisory_path = try eventStoreLockPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(advisory_path);
    const counter_path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.counter" });
    defer std.testing.allocator.free(counter_path);
    const lease_options: AcquireOptions = .{
        .owner = .{
            .process_id = 200,
            .session_id = "event-store-compatibility-test",
            .executor = "durable-store-test",
        },
        .fencing_counter_path = counter_path,
    };

    var backend = JsonlEventStore.init(path);
    const store = backend.eventStore();

    var presence = try acquireLock(std.testing.allocator, path);
    try std.testing.expectError(
        error.EventStoreBusy,
        store.acquireExclusive(std.testing.allocator),
    );
    presence.release(std.testing.allocator);

    var lease = try acquireLeaseLock(std.testing.allocator, path, lease_options);
    try std.testing.expectError(
        error.EventStoreBusy,
        store.acquireExclusive(std.testing.allocator),
    );
    try releaseLease(std.testing.allocator, &lease, lease.fencing_token);

    var exclusive = try store.acquireExclusive(std.testing.allocator);
    try std.testing.expect(fileExists(public_lock_path));
    try std.testing.expect(fileExists(advisory_path));
    try std.testing.expectError(
        error.PathAlreadyExists,
        acquireLock(std.testing.allocator, path),
    );
    try std.testing.expectError(
        error.LockBusy,
        acquireLeaseLock(std.testing.allocator, path, lease_options),
    );
    exclusive.release();

    try std.testing.expect(!fileExists(public_lock_path));
    try std.testing.expect(fileExists(advisory_path));

    var presence_after = try acquireLock(std.testing.allocator, path);
    presence_after.release(std.testing.allocator);
    var lease_after = try acquireLeaseLock(std.testing.allocator, path, lease_options);
    try releaseLease(
        std.testing.allocator,
        &lease_after,
        lease_after.fencing_token,
    );
}

test "jsonl event store contains physical diagnostics in its adapter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(path);
    try writeTextAtomic(std.testing.allocator, path, "{\"sequence\":1}\n\n{\"sequence\":2}");

    var backend = JsonlEventStore.init(path);
    var snapshot = try backend.eventStore().snapshot(std.testing.allocator, 4096);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.records.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.blank_entries);
    try std.testing.expectEqual(@as(?usize, 1), snapshot.records[0].diagnostic_position);
    try std.testing.expectEqual(@as(?usize, 3), snapshot.records[1].diagnostic_position);
    try std.testing.expectEqual(@as(usize, 1), snapshot.append_separator_bytes);
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

test "findGitRootAlloc walks parents without spawning git" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(Io.io(), ".git");
    try tmp.dir.createDirPath(Io.io(), "a/b/c");

    const nested = try std.fs.path.join(std.testing.allocator, &.{ root, "a", "b", "c" });
    defer std.testing.allocator.free(nested);
    const found = try findGitRootAlloc(std.testing.allocator, nested);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings(root, found);
}

test "findGitRootAlloc starts from the nearest existing ancestor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.createDirPath(Io.io(), ".git");

    const prospective = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "missing", "nested" },
    );
    defer std.testing.allocator.free(prospective);
    const found = try findGitRootAlloc(std.testing.allocator, prospective);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualStrings(root, found);
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
    const staged_ref = try transactionStageNameAlloc(
        allocator,
        transaction_id,
        0,
    );
    defer allocator.free(staged_ref);
    const writes = [_]TransactionWrite{.{
        .path = path,
        .staged_ref = staged_ref,
        .digest_after = digest_after,
        .sequence_after = (try jsonlSequenceRequired(allocator, after)).?,
    }};
    const target_dir = std.fs.path.dirname(path) orelse
        return error.InvalidPath;
    const staged_path = try std.fs.path.join(
        allocator,
        &.{ target_dir, staged_ref },
    );
    defer allocator.free(staged_path);
    try writeTextCreateNew(allocator, staged_path, after, .{});
    try writeTransactionRecord(allocator, record_path, transaction_id, owner, .prepared, &expected, &writes, &.{}, 1, 2, true);
}

fn writePreparedTwoWriteRecordForTest(
    allocator: std.mem.Allocator,
    record_path: []const u8,
    owner: Owner,
    path_a: []const u8,
    path_b: []const u8,
) !void {
    const transaction_id = "txn-mixed";
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
    const staged_ref_a = try transactionStageNameAlloc(
        allocator,
        transaction_id,
        0,
    );
    defer allocator.free(staged_ref_a);
    const staged_ref_b = try transactionStageNameAlloc(
        allocator,
        transaction_id,
        1,
    );
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
    const target_dir_a = std.fs.path.dirname(path_a) orelse
        return error.InvalidPath;
    const target_dir_b = std.fs.path.dirname(path_b) orelse
        return error.InvalidPath;
    const staged_a = try std.fs.path.join(
        allocator,
        &.{ target_dir_a, staged_ref_a },
    );
    defer allocator.free(staged_a);
    const staged_b = try std.fs.path.join(
        allocator,
        &.{ target_dir_b, staged_ref_b },
    );
    defer allocator.free(staged_b);
    try writeTextCreateNew(allocator, staged_a, after, .{});
    try writeTextCreateNew(allocator, staged_b, after, .{});
    try writeTransactionRecord(
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

fn tryReadForTest(path: []const u8) ![]u8 {
    return try readFileAlloc(std.testing.allocator, path, 4096);
}
