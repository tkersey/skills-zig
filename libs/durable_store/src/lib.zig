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

const TransactionRecordFormat = enum {
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
    return acquireLeaseLockObserved(
        allocator,
        resource_path,
        options,
        null,
    );
}

fn tryAcquireLeaseLockObserved(
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    lock_path: []const u8,
    counter_path: []const u8,
    options: AcquireOptions,
    storage_mutated: ?*bool,
) !?LeaseLock {
    var advisory = acquireLeaseAdvisoryLockObserved(
        allocator,
        lock_path,
        storage_mutated,
    ) catch |err| switch (err) {
        error.LockBusy => return null,
        else => return err,
    };
    defer advisory.close(Io.io());
    if (try statRegularFileNoSymlink(lock_path) != null) return null;
    const token = try allocateFencingToken(
        allocator,
        counter_path,
        storage_mutated,
    );
    const now_ms = clockMillis(.real);
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

fn sleepLeaseRetry(options: AcquireOptions) !void {
    const sleep_ms = @min(
        @max(options.retry_interval_ms, 1),
        @as(u64, @intCast(std.math.maxInt(i64))),
    );
    try std.Io.sleep(
        Io.io(),
        .fromMilliseconds(@intCast(sleep_ms)),
        .awake,
    );
}

fn acquireLeaseLockObserved(
    allocator: std.mem.Allocator,
    resource_path: []const u8,
    options: AcquireOptions,
    storage_mutated: ?*bool,
) !LeaseLock {
    if (options.reject_symlinks) try rejectSymlinkComponents(resource_path);

    const lock_path = try lockPathAlloc(allocator, resource_path);
    defer allocator.free(lock_path);
    const counter_path = try fencingCounterPathAlloc(allocator, lock_path, options.fencing_counter_path);
    defer allocator.free(counter_path);

    const started_ms = clockMillis(.awake);
    while (true) { // tiger: event-loop -- bounded by lock timeout.
        const lock = try tryAcquireLeaseLockObserved(
            allocator,
            resource_path,
            lock_path,
            counter_path,
            options,
            storage_mutated,
        );
        if (lock) |acquired| return acquired;
        if (options.timeout_ms == 0 or
            elapsedMillis(started_ms) >= options.timeout_ms)
        {
            return error.LockBusy;
        }
        try sleepLeaseRetry(options);
    }
}

pub fn refreshLease(
    allocator: std.mem.Allocator,
    lock: *LeaseLock,
    expected_fencing_token: u64,
    lease_ms: u64,
) !void {
    var advisory = try acquireLeaseAdvisoryLock(
        allocator,
        lock.path,
    );
    defer advisory.close(Io.io());
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
    var advisory = try acquireLeaseAdvisoryLock(
        allocator,
        lock.path,
    );
    defer advisory.close(Io.io());
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

    var advisory = try acquireLeaseAdvisoryLock(
        allocator,
        lock_path,
    );
    defer advisory.close(Io.io());
    var current = try readLeaseLock(allocator, lock_path);
    defer current.deinit(allocator);
    if (current.transaction_id != null) {
        return error.TransactionRecoveryRequired;
    }
    return reclaimLeaseMatchingWitnessLocked(
        allocator,
        current,
        counter_path,
        null,
        true,
    );
}

fn reclaimLeaseMatchingWitnessLocked(
    allocator: std.mem.Allocator,
    expected: LeaseLock,
    counter_path: []const u8,
    storage_mutated: ?*bool,
    require_expired: bool,
) !ReclaimReceipt {
    if (require_expired) {
        const expires_ms = try parseU64Text(expected.expires_at);
        if (clockMillis(.real) < expires_ms) return error.LockBusy;
    }
    var current = try readLeaseLock(allocator, expected.path);
    defer current.deinit(allocator);
    if (!leaseWitnessesEqual(current, expected)) {
        return error.FencingTokenStale;
    }
    const new_counter = try allocateFencingToken(
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
        allocator,
        evidence_path,
        payload,
        .{},
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const existing = try readRegularFileNoSymlink(
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
    try syncDirectoryPath(parent);
    if (std.fs.path.isAbsolute(expected.path)) {
        try std.Io.Dir.deleteFileAbsolute(Io.io(), expected.path);
    } else {
        try std.Io.Dir.cwd().deleteFile(Io.io(), expected.path);
    }
    if (storage_mutated) |mutated| mutated.* = true;
    try syncDirectoryPath(parent);
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
    return std.fmt.allocPrint(
        allocator,
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

fn leaseWitnessesEqual(left: LeaseLock, right: LeaseLock) bool {
    return leaseLineagesEqual(left, right) and
        std.mem.eql(u8, left.expires_at, right.expires_at);
}

fn leaseLineagesEqual(left: LeaseLock, right: LeaseLock) bool {
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

fn leaseAdvisoryPathAlloc(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}.advisory",
        .{lock_path},
    );
}

fn acquireLeaseAdvisoryLock(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
) !std.Io.File {
    return acquireLeaseAdvisoryLockObserved(
        allocator,
        lock_path,
        null,
    );
}

fn acquireLeaseAdvisoryLockObserved(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    storage_mutated: ?*bool,
) !std.Io.File {
    const advisory_path = try leaseAdvisoryPathAlloc(
        allocator,
        lock_path,
    );
    defer allocator.free(advisory_path);
    var created = false;
    const lock = openEventStoreSidecarExclusiveObserved(
        advisory_path,
        &created,
    ) catch |err| switch (err) {
        error.WouldBlock => return error.LockBusy,
        else => return err,
    };
    if (created) {
        if (storage_mutated) |mutated| mutated.* = true;
    }
    return lock;
}

fn allocateFencingToken(
    allocator: std.mem.Allocator,
    counter_path: []const u8,
    storage_mutated: ?*bool,
) !u64 {
    const counter_lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{counter_path});
    defer allocator.free(counter_lock_path);
    var counter_lock = try acquireExclusiveLockPath(allocator, counter_lock_path);
    var counter_lock_pending = true;
    defer if (counter_lock_pending) counter_lock.release(allocator);
    if (storage_mutated) |mutated| mutated.* = true;
    const next = writeNextFencingCounter(
        allocator,
        counter_path,
        storage_mutated,
    ) catch |err| {
        try counter_lock.releaseChecked(allocator);
        counter_lock_pending = false;
        try syncDirectoryPath(
            std.fs.path.dirname(counter_path) orelse
                return error.InvalidPath,
        );
        return err;
    };
    try counter_lock.releaseChecked(allocator);
    counter_lock_pending = false;
    try syncDirectoryPath(
        std.fs.path.dirname(counter_path) orelse
            return error.InvalidPath,
    );
    return next;
}

fn writeNextFencingCounter(
    allocator: std.mem.Allocator,
    counter_path: []const u8,
    storage_mutated: ?*bool,
) !u64 {
    const current = try readFencingCounter(allocator, counter_path);
    if (current == std.math.maxInt(u64)) {
        return error.TransactionRecoveryRequired;
    }
    const next = current + 1;
    const payload = try std.fmt.allocPrint(allocator, "{d}\n", .{next});
    defer allocator.free(payload);
    try writeTextAtomic(allocator, counter_path, payload);
    if (storage_mutated) |mutated| mutated.* = true;
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
    return parseLeaseLockValue(allocator, parsed.value, path);
}

fn parseLeaseLockValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    persisted_path: ?[]const u8,
) !LeaseLock {
    if (value != .object) return error.TransactionCorrupt;
    const object = value.object;
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
    const fencing_token = jsonUnsigned(
        object.get("fencing_token") orelse
            return error.TransactionCorrupt,
    ) orelse return error.TransactionCorrupt;
    const transaction_id = switch (object.get("transaction_id") orelse return error.TransactionCorrupt) {
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

fn ownersEqual(a: Owner, b: Owner) bool {
    return a.process_id == b.process_id and
        std.mem.eql(u8, a.session_id, b.session_id) and
        std.mem.eql(u8, a.executor, b.executor);
}

const default_snapshot_max_bytes: usize = 1024 * 1024;
const transaction_record_max_bytes: usize = default_snapshot_max_bytes;
const transaction_recovery_max_bytes: usize = if (@sizeOf(usize) >= 8)
    4 * 1024 * 1024 * 1024
else
    std.math.maxInt(usize);
const transaction_recovery_hash_max_bytes: usize = if (@sizeOf(usize) >= 8)
    16 * 1024 * 1024 * 1024
else
    std.math.maxInt(usize);
const transaction_recovery_max_rows: usize = 1024;

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
    byte_len: usize,

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
        const observed = try digestRegularFileNoSymlinkAtAlloc(
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
        .byte_len = data.len,
    };
}

const RegularFileDigest = struct {
    digest: []u8,
    byte_len: usize,
};

fn digestRegularFileNoSymlinkAtAlloc(
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    base: []const u8,
    max_bytes: usize,
) !RegularFileDigest {
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
    return .{
        .digest = try std.fmt.allocPrint(
            allocator,
            "sha256:{s}",
            .{&hex},
        ),
        .byte_len = observed,
    };
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
            var components = std.fs.path.componentIterator(parent);
            while (components.next()) |component| {
                if (component.name.len == 0 or
                    std.mem.eql(u8, component.name, ".") or
                    std.mem.eql(u8, component.name, ".."))
                {
                    return error.InvalidPath;
                }
                const next = dir.openDir(
                    Io.io(),
                    component.name,
                    .{ .follow_symlinks = false },
                ) catch |err| switch (err) {
                    error.SymLinkLoop => return error.SymlinkComponent,
                    else => return err,
                };
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
            "/repo/events.jsonl.lock.reclaimed-1700000000000-42",
            false,
        ),
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, ".transactions", "dtx-68" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
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
            allocator,
            transactions_dir,
        ),
    );
    try std.testing.expect(!fileExists(target_path));
}

pub fn commitTextTransaction(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    mutations: []const TransactionMutation,
    options: AcquireOptions,
) !CommitTransactionReceipt {
    if (mutations.len == 0) return error.InvalidPath;
    if (mutations.len > transaction_recovery_max_rows) {
        return error.TooManyFiles;
    }
    for (mutations) |mutation| {
        try rejectCasControlTargetPath(mutation.path);
    }
    try ensureDirectoryPathNoSymlinks(transactions_dir);
    for (mutations) |mutation| {
        if (try pathIsWithinDirectory(
            allocator,
            transactions_dir,
            mutation.path,
        )) return error.InvalidPath;
    }
    const control_root = std.fs.path.dirname(transactions_dir) orelse
        return error.InvalidPath;

    const ordered = try normalizeTransactionMutations(allocator, mutations, options.reject_symlinks);
    defer allocator.free(ordered);

    const transaction_id = try transactionIdAlloc(allocator);
    errdefer allocator.free(transaction_id);
    const transaction_dir = try std.fs.path.join(allocator, &.{ transactions_dir, transaction_id });
    errdefer allocator.free(transaction_dir);
    const record_path = try std.fs.path.join(allocator, &.{ transaction_dir, "transaction.json" });
    errdefer allocator.free(record_path);
    const commit_marker_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "commit.json" },
    );
    errdefer allocator.free(commit_marker_path);

    var targets = try allocator.alloc(TransactionTarget, ordered.len);
    var target_count: usize = 0;
    defer {
        for (targets[0..target_count]) |*target| target.deinit();
        allocator.free(targets);
    }
    for (ordered) |mutation| {
        const parent = std.fs.path.dirname(mutation.path) orelse
            return error.InvalidPath;
        try ensureDirectoryPathNoSymlinks(parent);
        targets[target_count] = try TransactionTarget.init(
            control_root,
            mutation.path,
        );
        target_count += 1;
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
    const before_sizes = try allocator.alloc(usize, ordered.len);
    defer allocator.free(before_sizes);
    var recovery_hash_admission: usize = 0;
    var recovery_hash_check_only: usize = 0;

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
        if (append_fast_path) {
            const maybe_size = try transactionTargetSizeAt(
                &target.dir,
                target.base,
                mutation.max_bytes,
            );
            before_exists[mutation_index] = maybe_size != null;
            before_sizes[mutation_index] = maybe_size orelse 0;
        } else {
            before_exists[mutation_index] = maybe_before != null;
            before_sizes[mutation_index] = if (maybe_before) |before|
                before.byte_len
            else
                0;
        }
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

        if (mutation.action == .check_only) {
            recovery_hash_check_only = std.math.add(
                usize,
                recovery_hash_check_only,
                before_sizes[mutation_index],
            ) catch return error.TransactionRecoveryWorkExceeded;
            continue;
        }
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
        const after_size = switch (mutation.action) {
            .write => mutation.text.len,
            .append => size: {
                const size = std.math.add(
                    usize,
                    before_sizes[mutation_index],
                    mutation.text.len,
                ) catch return error.FileTooBig;
                if (size > mutation.max_bytes) return error.FileTooBig;
                break :size size;
            },
            .check_only => unreachable,
        };
        try admitTransactionRecoveryHashWork(
            &recovery_hash_admission,
            before_sizes[mutation_index],
            after_size,
            transaction_recovery_hash_max_bytes,
        );
    }
    if (write_count != 0) {
        try addTransactionRecoveryHashAdmission(
            &recovery_hash_admission,
            recovery_hash_check_only,
            transaction_recovery_hash_max_bytes,
        );
    }
    try ensureTransactionRecordAdmission(
        allocator,
        transaction_id,
        options.owner,
        expected[0..expected_count],
        writes[0..write_count],
    );

    // Target custody is process-owned and crash-released. The journal namespace
    // lock makes the empty-directory-to-preparing-record transition indivisible
    // to recovery, before any persistent compatibility lock or stage exists.
    var record_persisted = false;
    {
        var journal_lock = try acquireTransactionJournalLock(
            allocator,
            transactions_dir,
            null,
        );
        defer journal_lock.close(Io.io());
        errdefer if (!record_persisted) {
            std.Io.Dir.cwd().deleteTree(
                Io.io(),
                transaction_dir,
            ) catch |cleanup_error| switch (cleanup_error) {
                else => {},
            };
            syncDirectoryPath(transactions_dir) catch |sync_error| switch (sync_error) {
                else => {},
            };
        };
        try ensureDirectoryPathNoSymlinks(transaction_dir);
        try writeCurrentTransactionRecord(
            allocator,
            record_path,
            transaction_id,
            options.owner,
            .preparing,
            expected[0..expected_count],
            writes[0..write_count],
            &.{},
            now_ms,
            clockMillis(.real),
            true,
        );
        try syncDirectoryPath(transaction_dir);
        try syncDirectoryPath(transactions_dir);
        record_persisted = true;
    }

    var transaction_stage_dir = if (std.fs.path.isAbsolute(transaction_dir))
        try std.Io.Dir.openDirAbsolute(Io.io(), transaction_dir, .{
            .follow_symlinks = false,
        })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), transaction_dir, .{
            .follow_symlinks = false,
        });
    defer transaction_stage_dir.close(Io.io());

    var cas_locks = try allocator.alloc(LockFile, ordered.len);
    var cas_lock_count: usize = 0;
    defer {
        var index: usize = 0;
        while (index < cas_lock_count) : (index += 1) {
            cas_locks[index].release(allocator);
        }
        allocator.free(cas_locks);
    }
    for (ordered) |mutation| {
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
    for (ordered, targets) |mutation, *target| {
        var expectation = mutation.expectation;
        if (mutation.content_mode == .raw and
            expectation.expected_sequence == 0)
        {
            expectation.expected_sequence = null;
        }
        try validateTransactionExpectationAt(
            allocator,
            mutation,
            expectation,
            target,
        );
    }

    var staged_files = try allocator.alloc(StagedTransactionFile, ordered.len);
    var staged_file_count: usize = 0;
    defer {
        for (staged_files[0..staged_file_count]) |*staged| {
            staged.deinit(
                &transaction_stage_dir,
                record_persisted,
            );
        }
        allocator.free(staged_files);
    }

    var write_index: usize = 0;
    for (ordered, targets, 0..) |mutation, *target, mutation_index| {
        if (mutation.action == .check_only) continue;
        const write = &writes[write_index];
        staged_files[staged_file_count] = try createStagedTransactionFile(
            &transaction_stage_dir,
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
        try syncDirectoryHandle(&transaction_stage_dir);
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

    try writeCurrentTransactionRecord(
        allocator,
        record_path,
        transaction_id,
        options.owner,
        .prepared,
        expected[0..expected_count],
        writes[0..write_count],
        &.{},
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
            &transaction_stage_dir,
            &staged_files[publish_index],
            target_index,
        );
        publish_index += 1;
    }
    try syncDirectoryHandle(&transaction_stage_dir);

    try writeCurrentTransactionRecord(
        allocator,
        record_path,
        transaction_id,
        options.owner,
        .committed,
        expected[0..expected_count],
        writes[0..write_count],
        &.{},
        now_ms,
        clockMillis(.real),
        false,
    );
    try syncDirectoryPath(transaction_dir);
    try writeCommittedTransactionMarker(allocator, commit_marker_path);
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

fn transactionTargetSizeAt(
    dir: *std.Io.Dir,
    base: []const u8,
    max_bytes: usize,
) !?usize {
    const stat = dir.statFile(
        Io.io(),
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

const transaction_stage_prefix = ".ledger-dtx-stage-";

const StagedTransactionFile = struct {
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
        if (self.file_open) {
            self.file.close(Io.io());
            self.file_open = false;
        }
        if (self.file_exists and !journal_owns_file) {
            stage_dir.deleteFile(
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
    stage_dir: *std.Io.Dir,
    staged_ref: []const u8,
    target_index: usize,
) !StagedTransactionFile {
    return .{
        .file = try stage_dir.createFile(Io.io(), staged_ref, .{
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

fn legacyTransactionStageName(
    buffer: []u8,
    write_index: usize,
) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "write-{d}.staged",
        .{write_index},
    );
}

fn publishVerifiedStagedFile(
    staged_dir: *std.Io.Dir,
    staged_ref: []const u8,
    expected_digest: []const u8,
    max_bytes: usize,
    target: *TransactionTarget,
) !usize {
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
    return observed;
}

fn publishVerifiedRecoveryStagedFile(
    staged_dir: *std.Io.Dir,
    staged_ref: []const u8,
    expected_digest: []const u8,
    target: *TransactionTarget,
    hash_bytes_remaining: *usize,
) !void {
    const stat = try staged_dir.statFile(
        Io.io(),
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
    allocator: std.mem.Allocator,
    write: TransactionWrite,
    mutation: TransactionMutation,
    expectation: CasExpectation,
    target: *TransactionTarget,
    stage_dir: *std.Io.Dir,
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
    const entry = try stage_dir.statFile(
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
    try stage_dir.rename(
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

fn transactionCommitMarkerPathAlloc(
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) ![]u8 {
    return std.fs.path.join(
        allocator,
        &.{ transaction_dir, "commit.json" },
    );
}

fn writeCommittedTransactionMarker(
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    try writeTextCreateNew(
        allocator,
        path,
        "{\"commit_marker\":\"DTX-v1\",\"state\":\"committed\"}\n",
        .{},
    );
}

pub fn inspectTransaction(
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) !RecoveryStatus {
    var hash_bytes_remaining = transaction_recovery_hash_max_bytes;
    return inspectTransactionWithBudget(
        allocator,
        transaction_dir,
        &hash_bytes_remaining,
    );
}

pub fn inspectLegacyLeaseRecoveryCandidates(
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    authority: LegacyFencingAuthority,
) ![]LegacyLeaseRecoveryCandidate {
    const parsed = try parseValidatedLegacyRecoveryRecord(
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
    const now_ms = clockMillis(.real);
    for (parsed.expected) |expected| {
        const lock_path = try lockPathAlloc(
            allocator,
            expected.path,
        );
        defer allocator.free(lock_path);
        var current = readLeaseLock(
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
    const parsed = try parseTransactionRecord(allocator, record_path);
    errdefer parsed.deinit(allocator);
    if (try transactionRecordFormat(allocator, parsed) != .legacy) {
        return error.TransactionRecoveryRequired;
    }
    try validateTransactionRecordScope(
        allocator,
        control_root,
        transaction_dir,
        parsed,
        .legacy,
    );
    try validateLegacyFencingAuthorityScope(
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
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    authority: LegacyFencingAuthority,
    request: LegacyLeaseReclaimRequest,
    summary: *TransactionRecoverySummary,
) !ReclaimReceipt {
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse
        return error.InvalidPath;
    var recovery_lock = try acquireTransactionRecoveryLock(
        allocator,
        transactions_dir,
        &summary.storage_mutated,
    );
    defer recovery_lock.close(Io.io());
    const parsed = try parseValidatedLegacyRecoveryRecord(
        allocator,
        transaction_dir,
        authority,
    );
    defer parsed.deinit(allocator);
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

    const control_root = try transactionControlRoot(transaction_dir);
    var resource_target = try TransactionTarget.init(
        control_root,
        request.resource,
    );
    defer resource_target.deinit();
    try rejectSymlinkComponents(request.resource);
    try resource_target.verifyPathIdentity();
    const lock_path = try lockPathAlloc(
        allocator,
        request.resource,
    );
    defer allocator.free(lock_path);
    try rejectSymlinkComponents(lock_path);
    var advisory = try acquireLeaseAdvisoryLockObserved(
        allocator,
        lock_path,
        &summary.storage_mutated,
    );
    defer advisory.close(Io.io());
    try rejectSymlinkComponents(request.resource);
    try rejectSymlinkComponents(lock_path);
    try resource_target.verifyPathIdentity();
    var current = try readLeaseLock(allocator, lock_path);
    defer current.deinit(allocator);
    if (!std.mem.eql(u8, current.resource, request.resource) or
        !std.mem.eql(u8, current.lock_id, request.lock_id) or
        current.fencing_token != request.fencing_token)
    {
        return error.TransactionRecoveryRequired;
    }

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
        allocator,
        expected,
        counter_path,
        &summary.storage_mutated,
        require_expiry,
    );
}

fn inspectTransactionWithBudget(
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
    const parsed = try parseTransactionRecord(allocator, record_path);
    defer parsed.deinit(allocator);
    const format = try transactionRecordFormat(allocator, parsed);
    try validateTransactionRecordScope(
        allocator,
        control_root,
        transaction_dir,
        parsed,
        format,
    );
    const preflight = try inspectValidatedTransactionWithBudget(
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
        var target = try TransactionTarget.init(control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        const digest = digestRecoveryFileAtAlloc(
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
    if (parsed.state == .committed and fileExists(commit_marker_path)) {
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
    allocator: std.mem.Allocator,
    control_root: []const u8,
    transaction_dir: []const u8,
    record_path: []const u8,
    preliminary: ParsedTransactionRecord,
    expected_format: TransactionRecordFormat,
) !ParsedTransactionRecord {
    const custodied = try parseTransactionRecord(allocator, record_path);
    errdefer custodied.deinit(allocator);
    try validateAutomaticRecoveryRowBounds(custodied);
    const format = try transactionRecordFormat(allocator, custodied);
    if (format != expected_format or
        !recoveryRecordCustodyEqual(preliminary, custodied))
    {
        return error.TransactionCorrupt;
    }
    try validateTransactionRecordScope(
        allocator,
        control_root,
        transaction_dir,
        custodied,
        format,
    );
    return custodied;
}

pub fn recoverTransaction(
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
) !RecoveryReceipt {
    return recoverTransactionWithOptions(
        allocator,
        transaction_dir,
        .{},
    );
}

pub fn recoverTransactionWithOptions(
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    options: TransactionRecoveryOptions,
) !RecoveryReceipt {
    var summary: TransactionRecoverySummary = .{};
    return recoverTransactionWithOptionsAccumulating(
        allocator,
        transaction_dir,
        options,
        &summary,
    );
}

pub fn recoverTransactionWithOptionsAccumulating(
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    options: TransactionRecoveryOptions,
    summary: *TransactionRecoverySummary,
) !RecoveryReceipt {
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse
        return error.InvalidPath;
    var storage_mutated = summary.storage_mutated;
    var recovery_lock = try acquireTransactionRecoveryLock(
        allocator,
        transactions_dir,
        &storage_mutated,
    );
    defer recovery_lock.close(Io.io());
    var hash_bytes_remaining = transaction_recovery_hash_max_bytes;
    var receipt = recoverTransactionWithOptionsAccumulatingLocked(
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
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    options: TransactionRecoveryOptions,
    storage_mutated: *bool,
    hash_bytes_remaining: *usize,
) !RecoveryReceipt {
    const control_root = try transactionControlRoot(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const commit_marker_path = try transactionCommitMarkerPathAlloc(
        allocator,
        transaction_dir,
    );
    defer allocator.free(commit_marker_path);
    var parsed = try parseTransactionRecord(allocator, record_path);
    defer parsed.deinit(allocator);
    try validateAutomaticRecoveryRowBounds(parsed);
    const format = try transactionRecordFormat(allocator, parsed);
    try validateTransactionRecordScope(
        allocator,
        control_root,
        transaction_dir,
        parsed,
        format,
    );
    const legacy_fencing_authority = if (format == .legacy)
        options.legacy_fencing_authority orelse
            return error.TransactionRecoveryRequired
    else
        null;
    if (legacy_fencing_authority) |authority| {
        try validateLegacyFencingAuthorityScope(
            allocator,
            transaction_dir,
            parsed,
            authority,
        );
    }
    const legacy_fencing_counter_path = if (legacy_fencing_authority) |authority|
        legacyFencingCounterPath(authority)
    else
        null;
    const legacy_terminal =
        format == .legacy and
        parsed.state == .committed and
        fileExists(commit_marker_path);
    if (legacy_terminal) {
        try ensureLegacyTerminalLeasesQuiescent(
            allocator,
            parsed.expected,
        );
        var terminal_leases = try acquireLegacyTransactionRecoveryLeases(
            allocator,
            parsed.expected,
            parsed.owner,
            parsed.transaction_id,
            legacy_fencing_counter_path,
            storage_mutated,
        );
        var terminal_leases_pending = true;
        defer if (terminal_leases_pending) {
            releaseLegacyTransactionRecoveryLeases(
                allocator,
                &terminal_leases,
                storage_mutated,
            ) catch |release_error| switch (release_error) {
                else => {},
            };
        };
        var terminal_locks = try acquireTransactionRecoveryLocks(
            allocator,
            parsed.expected,
            storage_mutated,
        );
        var terminal_locks_pending = true;
        defer if (terminal_locks_pending) {
            terminal_locks.deinit(allocator);
        };
        const terminal_custodied = try parseCustodiedRecoveryRecord(
            allocator,
            control_root,
            transaction_dir,
            record_path,
            parsed,
            format,
        );
        parsed.deinit(allocator);
        parsed = terminal_custodied;
        if (parsed.state != .committed or
            !fileExists(commit_marker_path))
        {
            return error.TransactionRecoveryRequired;
        }
        const published = (try transactionPublishedCount(
            allocator,
            control_root,
            parsed.writes,
            parsed.expected,
            hash_bytes_remaining,
        )) orelse return error.TransactionRecoveryRequired;
        if (published != parsed.writes.len) {
            return error.TransactionRecoveryRequired;
        }
        try syncLegacyTerminalEffects(
            control_root,
            transaction_dir,
            parsed.expected,
        );
        terminal_locks_pending = false;
        try terminal_locks.releaseDurable(
            allocator,
            storage_mutated,
        );
        terminal_leases_pending = false;
        try releaseLegacyTransactionRecoveryLeases(
            allocator,
            &terminal_leases,
            storage_mutated,
        );
        return makeRecoveryReceipt(
            allocator,
            parsed.transaction_id,
            .already_committed,
            "already_committed",
        );
    }
    var legacy_leases = if (format == .legacy)
        try acquireLegacyTransactionRecoveryLeases(
            allocator,
            parsed.expected,
            parsed.owner,
            parsed.transaction_id,
            legacy_fencing_counter_path,
            storage_mutated,
        )
    else
        null;
    var legacy_release_pending = legacy_leases != null;
    defer if (legacy_release_pending) {
        if (legacy_leases) |*leases| {
            releaseLegacyTransactionRecoveryLeases(
                allocator,
                leases,
                storage_mutated,
            ) catch |release_error| switch (release_error) {
                else => {},
            };
        }
    };
    var recovery_locks = try acquireTransactionRecoveryLocks(
        allocator,
        parsed.expected,
        storage_mutated,
    );
    var recovery_locks_pending = true;
    defer if (recovery_locks_pending) {
        recovery_locks.deinit(allocator);
    };
    const custodied = try parseCustodiedRecoveryRecord(
        allocator,
        control_root,
        transaction_dir,
        record_path,
        parsed,
        format,
    );
    parsed.deinit(allocator);
    parsed = custodied;
    const preflight = try inspectValidatedTransactionWithBudget(
        allocator,
        control_root,
        commit_marker_path,
        parsed,
        format,
        hash_bytes_remaining,
    );
    defer preflight.deinit(allocator);
    switch (preflight.status.decision) {
        .already_committed => {
            if (legacy_leases) |*leases| {
                legacy_release_pending = false;
                try releaseLegacyTransactionRecoveryLeases(
                    allocator,
                    leases,
                    storage_mutated,
                );
            }
            recovery_locks_pending = false;
            try recovery_locks.releaseDurable(
                allocator,
                storage_mutated,
            );
            return makeRecoveryReceipt(
                allocator,
                parsed.transaction_id,
                .already_committed,
                "already_committed",
            );
        },
        .finish_commit => {
            const write_states = preflight.write_states orelse
                return error.TransactionCorrupt;
            try validateRollForwardTransaction(
                allocator,
                control_root,
                transaction_dir,
                parsed,
                write_states,
                preflight.published_count,
                hash_bytes_remaining,
            );
            try rollForwardTransaction(
                control_root,
                transaction_dir,
                parsed,
                write_states,
                storage_mutated,
                hash_bytes_remaining,
            );
            const record = try renderParsedTransactionRecordAlloc(allocator, parsed, .committed);
            defer allocator.free(record);
            try writeTextAtomic(allocator, record_path, record);
            storage_mutated.* = true;
            try syncDirectoryPath(transaction_dir);
            var marker_created = true;
            writeTextCreateNew(allocator, commit_marker_path, "{\"commit_marker\":\"DTX-v1\",\"state\":\"committed\"}\n", .{}) catch |err| switch (err) {
                error.PathAlreadyExists => marker_created = false,
                else => return err,
            };
            if (marker_created) storage_mutated.* = true;
            try syncDirectoryPath(transaction_dir);
            if (legacy_leases) |*leases| {
                legacy_release_pending = false;
                try releaseLegacyTransactionRecoveryLeases(
                    allocator,
                    leases,
                    storage_mutated,
                );
            }
            recovery_locks_pending = false;
            try recovery_locks.releaseDurable(
                allocator,
                storage_mutated,
            );
            return makeRecoveryReceipt(allocator, parsed.transaction_id, .finish_commit, "committed");
        },
        .roll_back_unpublished => {
            try deleteReservedTransactionStages(
                transaction_dir,
                parsed.writes,
                storage_mutated,
            );
            const record = try renderParsedTransactionRecordAlloc(allocator, parsed, .aborted);
            defer allocator.free(record);
            try writeTextAtomic(allocator, record_path, record);
            storage_mutated.* = true;
            try syncDirectoryPath(transaction_dir);
            if (legacy_leases) |*leases| {
                legacy_release_pending = false;
                try releaseLegacyTransactionRecoveryLeases(
                    allocator,
                    leases,
                    storage_mutated,
                );
            }
            recovery_locks_pending = false;
            try recovery_locks.releaseDurable(
                allocator,
                storage_mutated,
            );
            return makeRecoveryReceipt(allocator, parsed.transaction_id, .roll_back_unpublished, "aborted");
        },
        .manual_recovery_required => return error.TransactionRecoveryRequired,
    }
}

pub fn recoverAndCompactTransactions(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
) !void {
    _ = try recoverAndCompactTransactionsWithOptions(
        allocator,
        transactions_dir,
        .{},
    );
}

pub fn recoverAndCompactTransactionsWithOptions(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    options: TransactionRecoveryOptions,
) !TransactionRecoverySummary {
    var summary: TransactionRecoverySummary = .{};
    try recoverAndCompactTransactionsAccumulating(
        allocator,
        transactions_dir,
        options,
        &summary,
    );
    return summary;
}

pub fn recoverAndCompactTransactionsAccumulating(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    options: TransactionRecoveryOptions,
    summary: *TransactionRecoverySummary,
) !void {
    var hash_bytes_remaining = transaction_recovery_hash_max_bytes;
    return recoverAndCompactTransactionsAccumulatingWithHashBudget(
        allocator,
        transactions_dir,
        options,
        summary,
        &hash_bytes_remaining,
    );
}

fn recoverAndCompactTransactionsAccumulatingWithHashBudget(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    options: TransactionRecoveryOptions,
    summary: *TransactionRecoverySummary,
    hash_bytes_remaining: *usize,
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
    var recovery_lock = try acquireTransactionRecoveryLock(
        allocator,
        transactions_dir,
        &summary.storage_mutated,
    );
    defer recovery_lock.close(Io.io());

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
        const stat = locked: {
            var journal_lock = try acquireTransactionJournalLock(
                allocator,
                transactions_dir,
                &summary.storage_mutated,
            );
            defer journal_lock.close(Io.io());
            break :locked std.Io.Dir.cwd().statFile(
                Io.io(),
                record_path,
                .{ .follow_symlinks = false },
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    const current_id = isGeneratedTransactionId(entry.name);
                    const legacy_id = isLegacyTransactionId(entry.name);
                    if (!current_id and !legacy_id) {
                        return error.TransactionCorrupt;
                    }
                    if (!current_id) {
                        return error.TransactionRecoveryRequired;
                    }
                    var removed = true;
                    dir.deleteDir(Io.io(), entry.name) catch |delete_err| switch (delete_err) {
                        error.FileNotFound => removed = false,
                        error.DirNotEmpty => return error.TransactionRecoveryRequired,
                        else => return delete_err,
                    };
                    if (removed) {
                        summary.storage_mutated = true;
                        try syncDirectoryHandle(&dir);
                    }
                    summary.transaction_count += 1;
                    continue;
                },
                else => return err,
            };
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) return error.TransactionCorrupt;
        record_bytes = std.math.add(
            usize,
            record_bytes,
            std.math.cast(usize, stat.size) orelse return error.FileTooBig,
        ) catch return error.FileTooBig;
        if (record_bytes > max_record_bytes) return error.FileTooBig;

        var receipt = try recoverTransactionWithOptionsAccumulatingLocked(
            allocator,
            transaction_dir,
            options,
            &summary.storage_mutated,
            hash_bytes_remaining,
        );
        receipt.deinit(allocator);
        try compactRecoveredTransaction(
            allocator,
            transactions_dir,
            transaction_dir,
            &dir,
            &summary.storage_mutated,
        );
        summary.transaction_count += 1;
    }
}

fn compactRecoveredTransaction(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    transaction_dir: []const u8,
    transactions: *const std.Io.Dir,
    storage_mutated: *bool,
) !void {
    var journal_lock = try acquireTransactionJournalLock(
        allocator,
        transactions_dir,
        storage_mutated,
    );
    defer journal_lock.close(Io.io());
    const stat = std.Io.Dir.cwd().statFile(
        Io.io(),
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
    try std.Io.Dir.cwd().deleteTree(
        Io.io(),
        transaction_dir,
    );
    try syncDirectoryHandle(transactions);
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
    allocator: std.mem.Allocator,
    transaction_dir: []const u8,
    parsed: ParsedTransactionRecord,
    authority: LegacyFencingAuthority,
) !void {
    const transactions_dir = std.fs.path.dirname(transaction_dir) orelse
        return error.InvalidPath;
    try validateLegacyAuthorityOutsideTransactions(
        allocator,
        transactions_dir,
        parsed.expected,
        authority,
    );
    var identities = HostPathIdentityContext.init(allocator);
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
    try validateLegacyFencingTokenFloor(allocator, parsed, authority);
}

fn validateLegacyAuthorityOutsideTransactions(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    expected: []const TransactionExpected,
    authority: LegacyFencingAuthority,
) !void {
    switch (authority) {
        .shared => |counter_path| try validateAuthorityPathOutsideTransactions(
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
                allocator,
                transactions_dir,
                counter_path,
            );
        },
    }
}

fn validateAuthorityPathOutsideTransactions(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    counter_path: []const u8,
) !void {
    if (try pathIsWithinDirectory(
        allocator,
        transactions_dir,
        counter_path,
    )) return error.TransactionCorrupt;
    const counter_lock_path = try std.fmt.allocPrint(
        allocator,
        "{s}.lock",
        .{counter_path},
    );
    defer allocator.free(counter_lock_path);
    if (try pathIsWithinDirectory(
        allocator,
        transactions_dir,
        counter_lock_path,
    )) return error.TransactionCorrupt;
}

const HostPathIdentityContext = struct {
    const DirectoryIdentity = struct {
        canonical: []u8,
        case_insensitive: bool,
    };

    allocator: std.mem.Allocator,
    directories: std.StringHashMap(DirectoryIdentity),

    fn init(allocator: std.mem.Allocator) HostPathIdentityContext {
        return .{
            .allocator = allocator,
            .directories = std.StringHashMap(DirectoryIdentity).init(
                allocator,
            ),
        };
    }

    fn deinit(self: *HostPathIdentityContext) void {
        var entries = self.directories.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.canonical);
        }
        self.directories.deinit();
        self.* = undefined;
    }

    fn directoryIdentity(
        self: *HostPathIdentityContext,
        directory: []const u8,
        witness_name: []const u8,
    ) !DirectoryIdentity {
        const resolved = try std.fs.path.resolve(
            self.allocator,
            &.{directory},
        );
        defer self.allocator.free(resolved);
        if (self.directories.get(resolved)) |identity| return identity;
        const key = try self.allocator.dupe(u8, resolved);
        errdefer self.allocator.free(key);
        const canonical = try canonicalProspectivePathAlloc(
            self.allocator,
            resolved,
        );
        errdefer self.allocator.free(canonical);
        const case_insensitive = try directoryNameIsCaseInsensitive(
            self.allocator,
            canonical,
            witness_name,
        );
        if (case_insensitive) {
            for (canonical) |*byte| byte.* = std.ascii.toLower(byte.*);
        }
        const identity: DirectoryIdentity = .{
            .canonical = canonical,
            .case_insensitive = case_insensitive,
        };
        try self.directories.put(key, identity);
        return identity;
    }

    fn canonicalAlloc(
        self: *HostPathIdentityContext,
        path: []const u8,
    ) ![]u8 {
        const resolved = try std.fs.path.resolve(
            self.allocator,
            &.{path},
        );
        defer self.allocator.free(resolved);
        const parent = std.fs.path.dirname(resolved) orelse
            return error.InvalidPath;
        const directory = try self.directoryIdentity(
            parent,
            std.fs.path.basename(resolved),
        );
        if (containsNonAscii(std.fs.path.basename(resolved))) {
            const host_canonical = std.Io.Dir.cwd().realPathFileAlloc(
                Io.io(),
                resolved,
                self.allocator,
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    if (directory.case_insensitive) {
                        return error.TransactionRecoveryRequired;
                    }
                    return std.fs.path.join(
                        self.allocator,
                        &.{
                            directory.canonical,
                            std.fs.path.basename(resolved),
                        },
                    );
                },
                else => return err,
            };
            defer self.allocator.free(host_canonical);
            const canonical = try self.allocator.dupe(u8, host_canonical);
            if (directory.case_insensitive) {
                for (canonical) |*byte| {
                    byte.* = std.ascii.toLower(byte.*);
                }
            }
            return canonical;
        }
        const canonical = try std.fs.path.join(
            self.allocator,
            &.{ directory.canonical, std.fs.path.basename(resolved) },
        );
        if (directory.case_insensitive) {
            for (canonical) |*byte| byte.* = std.ascii.toLower(byte.*);
        }
        return canonical;
    }

    fn objectKeyAlloc(
        self: *HostPathIdentityContext,
        path: []const u8,
    ) ![]u8 {
        if (@import("builtin").os.tag == .windows) {
            const canonical = try self.canonicalAlloc(path);
            defer self.allocator.free(canonical);
            return std.fmt.allocPrint(
                self.allocator,
                "path:{s}",
                .{canonical},
            );
        }
        const resolved = try std.fs.path.resolve(
            self.allocator,
            &.{path},
        );
        defer self.allocator.free(resolved);
        var candidate = try self.allocator.dupe(u8, resolved);
        defer self.allocator.free(candidate);
        while (true) { // tiger: event-loop -- bounded by path ancestors.
            if (try hostObjectIdentity(candidate)) |identity| {
                if (std.mem.eql(u8, candidate, resolved)) {
                    return std.fmt.allocPrint(
                        self.allocator,
                        "object:{d}:{d}",
                        .{ identity.device, identity.inode },
                    );
                }
                if (identity.kind != .directory) {
                    return error.InvalidPath;
                }
                const suffix = try std.fs.path.relative(
                    self.allocator,
                    candidate,
                    null,
                    candidate,
                    resolved,
                );
                defer self.allocator.free(suffix);
                const normalized = try self.allocator.dupe(u8, suffix);
                defer self.allocator.free(normalized);
                const separator = std.mem.indexOfScalar(
                    u8,
                    suffix,
                    std.fs.path.sep,
                ) orelse suffix.len;
                if (try directoryNameIsCaseInsensitive(
                    self.allocator,
                    candidate,
                    suffix[0..separator],
                )) {
                    if (containsNonAscii(normalized)) {
                        return error.TransactionRecoveryRequired;
                    }
                    for (normalized) |*byte| {
                        byte.* = std.ascii.toLower(byte.*);
                    }
                }
                return std.fmt.allocPrint(
                    self.allocator,
                    "prospective:{d}:{d}:{s}",
                    .{
                        identity.device,
                        identity.inode,
                        normalized,
                    },
                );
            }
            const parent = std.fs.path.dirname(candidate) orelse
                return error.InvalidPath;
            if (std.mem.eql(u8, parent, candidate)) {
                return error.InvalidPath;
            }
            const next = try self.allocator.dupe(u8, parent);
            self.allocator.free(candidate);
            candidate = next;
        }
    }
};

const HostObjectIdentity = struct {
    device: u64,
    inode: std.Io.File.INode,
    kind: std.Io.File.Kind,
    mtime_ns: i96,
    ctime_ns: i96,
};

fn hostObjectIdentitiesEqual(
    left: HostObjectIdentity,
    right: HostObjectIdentity,
) bool {
    return left.device == right.device and
        left.inode == right.inode and
        left.kind == right.kind and
        left.mtime_ns == right.mtime_ns and
        left.ctime_ns == right.ctime_ns;
}

fn hostObjectIdentity(path: []const u8) !?HostObjectIdentity {
    if (@import("builtin").os.tag == .windows) return null;
    var file = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(Io.io(), path, .{
            .allow_directory = true,
            .follow_symlinks = false,
            .path_only = false,
        })
    else
        std.Io.Dir.cwd().openFile(Io.io(), path, .{
            .allow_directory = true,
            .follow_symlinks = false,
            .path_only = false,
        })) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(Io.io());
    const portable_stat = try file.stat(Io.io());
    return .{
        .device = try hostFileDevice(file),
        .inode = portable_stat.inode,
        .kind = portable_stat.kind,
        .mtime_ns = portable_stat.mtime.nanoseconds,
        .ctime_ns = portable_stat.ctime.nanoseconds,
    };
}

fn hostFileDevice(file: std.Io.File) !u64 {
    return switch (@import("builtin").os.tag) {
        .linux => linuxFileDevice(file),
        .windows => unreachable,
        else => posixFileDevice(file),
    };
}

fn linuxFileDevice(file: std.Io.File) !u64 {
    const linux = std.os.linux;
    while (true) { // tiger: event-loop -- bounded by syscall completion.
        var statx = std.mem.zeroes(linux.Statx);
        const result = linux.statx(
            file.handle,
            "",
            linux.AT.EMPTY_PATH,
            .{ .INO = true },
            &statx,
        );
        switch (linux.errno(result)) {
            .SUCCESS => return (@as(u64, statx.dev_major) << 32) |
                @as(u64, statx.dev_minor),
            .INTR => continue,
            else => return error.TransactionRecoveryRequired,
        }
    }
}

fn posixFileDevice(file: std.Io.File) !u64 {
    var host_stat: std.posix.Stat = undefined;
    if (std.posix.system.fstat(file.handle, &host_stat) != 0) {
        return error.TransactionRecoveryRequired;
    }
    return @intCast(host_stat.dev);
}

test "host object identity collapses hardlinked path aliases" {
    if (@import("builtin").os.tag == .windows) {
        return error.SkipZigTest;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const source_path = try std.fs.path.join(
        allocator,
        &.{ root, "source" },
    );
    defer allocator.free(source_path);
    const alias_path = try std.fs.path.join(
        allocator,
        &.{ root, "alias" },
    );
    defer allocator.free(alias_path);
    try writeTextAtomic(allocator, source_path, "identity\n");
    var root_dir = try std.Io.Dir.openDirAbsolute(Io.io(), root, .{});
    defer root_dir.close(Io.io());
    try root_dir.hardLink(
        "source",
        root_dir,
        "alias",
        Io.io(),
        .{},
    );
    var identities = HostPathIdentityContext.init(allocator);
    defer identities.deinit();
    const source_key = try identities.objectKeyAlloc(source_path);
    defer allocator.free(source_key);
    const alias_key = try identities.objectKeyAlloc(alias_path);
    defer allocator.free(alias_key);
    try std.testing.expectEqualStrings(source_key, alias_key);
}

fn containsNonAscii(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isAscii(byte)) return true;
    }
    return false;
}

const CanonicalPathIndex = struct {
    paths: [][]u8,
    object_keys: [][]u8,
    count: usize = 0,

    fn deinit(self: *CanonicalPathIndex, allocator: std.mem.Allocator) void {
        for (self.paths[0..self.count]) |path| allocator.free(path);
        for (self.object_keys[0..self.count]) |key| allocator.free(key);
        allocator.free(self.paths);
        allocator.free(self.object_keys);
        self.* = undefined;
    }

    fn items(self: CanonicalPathIndex) []const []u8 {
        return self.paths[0..self.count];
    }

    fn append(
        self: *CanonicalPathIndex,
        identities: *HostPathIdentityContext,
        path: []const u8,
    ) !void {
        std.debug.assert(self.count < self.paths.len);
        self.paths[self.count] = try identities.canonicalAlloc(path);
        errdefer identities.allocator.free(self.paths[self.count]);
        self.object_keys[self.count] = try identities.objectKeyAlloc(path);
        self.count += 1;
    }

    fn appendDerived(
        self: *CanonicalPathIndex,
        identities: *HostPathIdentityContext,
        resource_path: []const u8,
        suffix: []const u8,
    ) !void {
        std.debug.assert(self.count < self.paths.len);
        const resource_canonical = try identities.canonicalAlloc(
            resource_path,
        );
        defer identities.allocator.free(resource_canonical);
        self.paths[self.count] = try std.fmt.allocPrint(
            identities.allocator,
            "{s}{s}",
            .{ resource_canonical, suffix },
        );
        errdefer identities.allocator.free(self.paths[self.count]);
        const actual_path = try std.fmt.allocPrint(
            identities.allocator,
            "{s}{s}",
            .{ resource_path, suffix },
        );
        defer identities.allocator.free(actual_path);
        self.object_keys[self.count] = if (try hostObjectIdentity(actual_path)) |identity|
            try std.fmt.allocPrint(
                identities.allocator,
                "object:{d}:{d}",
                .{ identity.device, identity.inode },
            )
        else
            try std.fmt.allocPrint(
                identities.allocator,
                "derived:{s}",
                .{self.paths[self.count]},
            );
        self.count += 1;
    }

    fn finalize(self: *CanonicalPathIndex) !void {
        std.sort.heap([]u8, self.paths[0..self.count], {}, struct {
            fn lessThan(_: void, left: []u8, right: []u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);
        std.sort.heap([]u8, self.object_keys[0..self.count], {}, struct {
            fn lessThan(_: void, left: []u8, right: []u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);
        if (self.count >= 2) {
            for (self.paths[1..self.count], 1..) |path, index| {
                if (pathsAliasOrOverlapCaseSensitive(
                    self.paths[index - 1],
                    path,
                )) return error.TransactionCorrupt;
            }
            for (self.object_keys[1..self.count], 1..) |key, index| {
                if (std.mem.eql(
                    u8,
                    self.object_keys[index - 1],
                    key,
                )) return error.TransactionCorrupt;
            }
        }
    }

    fn objectsIntersect(
        self: CanonicalPathIndex,
        other: CanonicalPathIndex,
    ) bool {
        var left: usize = 0;
        var right: usize = 0;
        while (left < self.count and right < other.count) {
            if (std.mem.eql(
                u8,
                self.object_keys[left],
                other.object_keys[right],
            )) return true;
            if (std.mem.lessThan(
                u8,
                self.object_keys[left],
                other.object_keys[right],
            )) {
                left += 1;
            } else {
                right += 1;
            }
        }
        return false;
    }

    fn aliasesCanonical(
        self: CanonicalPathIndex,
        candidate: []const u8,
    ) bool {
        const lower = self.lowerBound(candidate);
        if (lower < self.count and pathIsAtOrBelow(
            candidate,
            self.paths[lower],
        )) return true;
        var ancestor = candidate;
        while (true) { // tiger: event-loop -- bounded by path ancestors.
            const parent = std.fs.path.dirname(ancestor) orelse break;
            if (std.mem.eql(u8, parent, ancestor)) break;
            if (self.containsExact(parent)) return true;
            ancestor = parent;
        }
        return false;
    }

    fn containsExact(
        self: CanonicalPathIndex,
        candidate: []const u8,
    ) bool {
        const lower = self.lowerBound(candidate);
        return lower < self.count and
            std.mem.eql(u8, self.paths[lower], candidate);
    }

    fn lowerBound(
        self: CanonicalPathIndex,
        candidate: []const u8,
    ) usize {
        var lower: usize = 0;
        var upper = self.count;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            if (std.mem.lessThan(
                u8,
                self.paths[middle],
                candidate,
            )) {
                lower = middle + 1;
            } else {
                upper = middle;
            }
        }
        return lower;
    }
};

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
    const counter_lock_path = try std.fmt.allocPrint(
        allocator,
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
    allocator: std.mem.Allocator,
    parsed: ParsedTransactionRecord,
    authority: LegacyFencingAuthority,
) !void {
    if (parsed.embedded_locks.len == 0) return;
    switch (authority) {
        .shared => |counter_path| {
            const counter = try readFencingCounter(allocator, counter_path);
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
            const counter = try readFencingCounter(allocator, counter_path);
            if (counter < lock.fencing_token) {
                return error.TransactionRecoveryRequired;
            }
        },
    }
}

fn acquireLegacyTransactionRecoveryLeases(
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
                allocator,
                &leases[index],
                leases[index].fencing_token,
            ) catch leases[index].deinit(allocator);
        }
        allocator.free(leases);
    }
    for (expected) |row| {
        const parent = std.fs.path.dirname(row.path) orelse
            return error.InvalidPath;
        const stat = try std.Io.Dir.cwd().statFile(
            Io.io(),
            parent,
            .{ .follow_symlinks = false },
        );
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .directory) return error.InvalidPath;
    }
    for (expected) |row| {
        leases[acquired] = acquireLeaseLockObserved(
            allocator,
            row.path,
            .{
                .owner = owner,
                .lease_ms = recovery_lease_ms,
                .fencing_counter_path = fencing_counter_path,
                .transaction_id = transaction_id,
            },
            storage_mutated,
        ) catch |err| switch (err) {
            error.LockBusy => retry: {
                const lock_path = try lockPathAlloc(allocator, row.path);
                defer allocator.free(lock_path);
                var current = readLeaseLock(
                    allocator,
                    lock_path,
                ) catch |read_err| switch (read_err) {
                    error.FileNotFound => break :retry try acquireLeaseLockObserved(
                        allocator,
                        row.path,
                        .{
                            .owner = owner,
                            .lease_ms = recovery_lease_ms,
                            .fencing_counter_path = fencing_counter_path,
                            .transaction_id = transaction_id,
                        },
                        storage_mutated,
                    ),
                    else => return read_err,
                };
                defer current.deinit(allocator);
                if (!std.mem.eql(u8, current.resource, row.path)) {
                    return error.TransactionCorrupt;
                }
                const expires_ms = try parseU64Text(current.expires_at);
                if (clockMillis(.real) < expires_ms) return error.LockBusy;
                return error.TransactionRecoveryRequired;
            },
            else => return err,
        };
        acquired += 1;
    }
    return leases;
}

fn ensureLegacyTerminalLeasesQuiescent(
    allocator: std.mem.Allocator,
    expected: []const TransactionExpected,
) !void {
    for (expected) |row| {
        const lock_path = try lockPathAlloc(allocator, row.path);
        defer allocator.free(lock_path);
        var current = readLeaseLock(
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
        if (clockMillis(.real) < expires_ms) return error.LockBusy;
        return error.TransactionRecoveryRequired;
    }
}

fn syncLegacyTerminalEffects(
    control_root: []const u8,
    transaction_dir: []const u8,
    expected: []const TransactionExpected,
) !void {
    for (expected) |row| {
        var target = try TransactionTarget.init(control_root, row.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        try syncDirectoryHandle(&target.dir);
        try target.verifyPathIdentity();
    }
    try syncDirectoryPath(transaction_dir);
}

fn releaseLegacyTransactionRecoveryLeases(
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
                Io.io(),
                parent,
                .{ .follow_symlinks = false },
            )
        else
            std.Io.Dir.cwd().openDir(
                Io.io(),
                parent,
                .{ .follow_symlinks = false },
            )) catch |err| {
            leases.*[index].deinit(allocator);
            if (first_error == null) first_error = err;
            continue;
        };
        {
            defer parent_dir.close(Io.io());
            releaseLease(
                allocator,
                &leases.*[index],
                leases.*[index].fencing_token,
            ) catch |err| {
                leases.*[index].deinit(allocator);
                if (first_error == null) first_error = err;
                continue;
            };
            storage_mutated.* = true;
            syncDirectoryHandle(&parent_dir) catch |err| {
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

fn transactionRecordFormat(
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

fn validateTransactionRecordScope(
    allocator: std.mem.Allocator,
    control_root: []const u8,
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
        if (try pathIsWithinDirectory(
            allocator,
            transactions_dir,
            row.path,
        )) return error.TransactionCorrupt;
        const result = try expected_indexes.getOrPut(row.path);
        if (result.found_existing) return error.TransactionCorrupt;
        result.value_ptr.* = row_index;
        expected_paths[row_index] = row.path;
    }
    try validateTransactionPathsDisjoint(allocator, format, expected_paths);
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
        if (try pathIsWithinDirectory(
            allocator,
            transactions_dir,
            row.path,
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
    try validateTransactionPathsDisjoint(allocator, format, write_paths);
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
            allocator,
            format,
            prior.original,
            path.original,
        )) {
            return error.TransactionCorrupt;
        }
    }
}

fn pathIsWithinDirectory(
    allocator: std.mem.Allocator,
    directory: []const u8,
    path: []const u8,
) !bool {
    if (pathIsAtOrBelow(directory, path)) return true;
    const canonical_directory = try canonicalProspectivePathAlloc(
        allocator,
        directory,
    );
    defer allocator.free(canonical_directory);
    const canonical_path = try canonicalProspectivePathAlloc(
        allocator,
        path,
    );
    defer allocator.free(canonical_path);
    if (pathIsAtOrBelow(canonical_directory, canonical_path)) {
        return true;
    }
    return hostPathIsAtOrBelow(allocator, directory, path);
}

fn hostPathIsAtOrBelow(
    allocator: std.mem.Allocator,
    directory: []const u8,
    path: []const u8,
) !bool {
    if (@import("builtin").os.tag == .windows) return false;
    const directory_identity = (try hostObjectIdentity(directory)) orelse
        return false;
    if (directory_identity.kind != .directory) return error.InvalidPath;
    const resolved = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(resolved);
    var candidate = try allocator.dupe(u8, resolved);
    defer allocator.free(candidate);
    while (true) { // tiger: event-loop -- bounded by path ancestors.
        if (try hostObjectIdentity(candidate)) |identity| {
            if (identity.device == directory_identity.device and
                identity.inode == directory_identity.inode)
            {
                return true;
            }
        }
        const parent = std.fs.path.dirname(candidate) orelse return false;
        if (std.mem.eql(u8, parent, candidate)) return false;
        const next = try allocator.dupe(u8, parent);
        allocator.free(candidate);
        candidate = next;
    }
}

fn pathIsAtOrBelow(parent: []const u8, candidate: []const u8) bool {
    return std.mem.eql(u8, parent, candidate) or
        (candidate.len > parent.len and
            std.mem.startsWith(u8, candidate, parent) and
            (candidate[parent.len] == '/' or
                candidate[parent.len] == '\\'));
}

fn isGeneratedTransactionId(transaction_id: []const u8) bool {
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

fn isLegacyTransactionId(transaction_id: []const u8) bool {
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

fn deleteReservedTransactionStages(
    transaction_dir: []const u8,
    writes: []const TransactionWrite,
    storage_mutated: *bool,
) !void {
    var stage_dir = if (std.fs.path.isAbsolute(transaction_dir))
        try std.Io.Dir.openDirAbsolute(Io.io(), transaction_dir, .{
            .follow_symlinks = false,
        })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), transaction_dir, .{
            .follow_symlinks = false,
        });
    defer stage_dir.close(Io.io());
    for (writes) |write| {
        const stat = stage_dir.statFile(
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
        try stage_dir.deleteFile(Io.io(), write.staged_ref);
        storage_mutated.* = true;
        try syncDirectoryHandle(&stage_dir);
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

    fn releaseDurable(
        self: *TransactionRecoveryLocks,
        allocator: std.mem.Allocator,
        storage_mutated: *bool,
    ) !void {
        var first_error: ?anyerror = null;
        releaseCompatibilityLocksDurable(
            allocator,
            self.compatibility[0..self.compatibility_count],
            storage_mutated,
        ) catch |err| {
            first_error = err;
        };
        for (self.advisory[0..self.advisory_count]) |file| {
            file.close(Io.io());
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
    parent_dir: *std.Io.Dir,
    basename: []const u8,
    storage_mutated: *bool,
) !bool {
    var removed = true;
    parent_dir.deleteFile(Io.io(), basename) catch |err| switch (err) {
        error.FileNotFound => removed = false,
        else => return err,
    };
    if (removed) storage_mutated.* = true;
    return removed;
}

fn openCompatibilityLockParent(parent: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(parent))
        std.Io.Dir.openDirAbsolute(
            Io.io(),
            parent,
            .{ .follow_symlinks = false },
        )
    else
        std.Io.Dir.cwd().openDir(
            Io.io(),
            parent,
            .{ .follow_symlinks = false },
        );
}

fn releaseCompatibilityLockGroup(
    entries: []CompatibilityReleaseEntry,
    storage_mutated: *bool,
) !void {
    std.debug.assert(entries.len != 0);
    var parent_dir = try openCompatibilityLockParent(entries[0].parent);
    defer parent_dir.close(Io.io());
    var first_error: ?anyerror = null;
    var removed = false;
    for (entries) |entry| {
        const deleted = deleteCompatibilityLockObserved(
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
        syncDirectoryHandle(&parent_dir) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    if (first_error) |err| return err;
}

fn releaseCompatibilityLocksDurable(
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
            entries[start..index],
            storage_mutated,
        ) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    for (locks) |*lock| {
        allocator.free(lock.path);
        lock.* = .{ .path = &.{} };
    }
    if (first_error) |err| return err;
}

fn acquireTransactionRecoveryLocks(
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
        .advisory = advisory,
        .compatibility = compatibility,
        .advisory_count = 0,
        .compatibility_count = 0,
    };
    errdefer result.deinit(allocator);
    for (expected) |row| {
        result.advisory[result.advisory_count] =
            try acquireCasAdvisoryLockObserved(
                allocator,
                row.path,
                storage_mutated,
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
            if (value.size != 0) {
                return error.TransactionRecoveryRequired;
            }
            if (std.fs.path.isAbsolute(cas_path)) {
                try std.Io.Dir.deleteFileAbsolute(Io.io(), cas_path);
            } else {
                try std.Io.Dir.cwd().deleteFile(Io.io(), cas_path);
            }
            storage_mutated.* = true;
        }
        result.compatibility[result.compatibility_count] =
            try acquireExclusiveLockPath(allocator, cas_path);
        result.compatibility_count += 1;
        storage_mutated.* = true;
    }
    return result;
}

fn rollForwardTransaction(
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
        try std.Io.Dir.openDirAbsolute(Io.io(), transaction_dir, .{
            .follow_symlinks = false,
        })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), transaction_dir, .{
            .follow_symlinks = false,
        });
    defer stage_dir.close(Io.io());
    for (parsed.writes, write_states) |write, state| {
        var target = try TransactionTarget.init(control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        switch (state) {
            .published => {
                try syncDirectoryHandle(&target.dir);
                try target.verifyPathIdentity();
                var stage_deleted = true;
                stage_dir.deleteFile(
                    Io.io(),
                    write.staged_ref,
                ) catch |err| switch (err) {
                    error.FileNotFound => stage_deleted = false,
                    else => return err,
                };
                if (stage_deleted) storage_mutated.* = true;
                try syncDirectoryHandle(&stage_dir);
                continue;
            },
            .expected, .missing => {},
        }
        try rejectHardlinkedTargetAt(&target.dir, target.base);
        try publishVerifiedRecoveryStagedFile(
            &stage_dir,
            write.staged_ref,
            write.digest_after,
            &target,
            hash_bytes_remaining,
        );
        storage_mutated.* = true;
        try syncDirectoryHandle(&target.dir);
        try stage_dir.deleteFile(Io.io(), write.staged_ref);
        storage_mutated.* = true;
        try syncDirectoryHandle(&stage_dir);
        try target.verifyPathIdentity();
    }
}

fn validateRollForwardTransaction(
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
        try std.Io.Dir.openDirAbsolute(Io.io(), transaction_dir, .{
            .follow_symlinks = false,
        })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), transaction_dir, .{
            .follow_symlinks = false,
        });
    defer stage_dir.close(Io.io());
    if (parsed.state != .committed and
        published_count != parsed.writes.len)
    {
        for (parsed.expected) |expected| {
            if (write_paths.contains(expected.path)) continue;
            var target = try TransactionTarget.init(
                control_root,
                expected.path,
            );
            defer target.deinit();
            try target.verifyPathIdentity();
            const current = digestRecoveryFileAtAlloc(
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
    for (parsed.writes, write_states) |write, state| {
        var target = try TransactionTarget.init(control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        switch (state) {
            .published => continue,
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
            allocator,
            &stage_dir,
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

fn transactionPathsAliasOrOverlap(
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
        allocator,
        parent,
        std.fs.path.basename(shorter),
    );
}

fn pathsAliasOrOverlapCaseSensitive(
    left: []const u8,
    right: []const u8,
) bool {
    if (std.mem.eql(u8, left, right)) return true;
    const shorter = if (left.len < right.len) left else right;
    const longer = if (left.len < right.len) right else left;
    return longer.len > shorter.len and
        std.mem.startsWith(u8, longer, shorter) and
        longer[shorter.len] == std.fs.path.sep;
}

fn canonicalProspectivePathAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const resolved = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(resolved);
    var candidate = try allocator.dupe(u8, resolved);
    defer allocator.free(candidate);
    while (true) { // tiger: event-loop -- bounded by path ancestors.
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(
            Io.io(),
            candidate,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = std.fs.path.dirname(candidate) orelse
                    return error.InvalidPath;
                if (std.mem.eql(u8, parent, candidate)) return err;
                const next = try allocator.dupe(u8, parent);
                allocator.free(candidate);
                candidate = next;
                continue;
            },
            else => return err,
        };
        defer allocator.free(canonical);
        if (std.mem.eql(u8, candidate, resolved)) {
            return allocator.dupe(u8, canonical);
        }
        const suffix = try std.fs.path.relative(
            allocator,
            candidate,
            null,
            candidate,
            resolved,
        );
        defer allocator.free(suffix);
        return std.fs.path.join(allocator, &.{ canonical, suffix });
    }
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
    if (pathContainsReclaimEvidenceComponent(path)) {
        return error.ReservedStorePath;
    }
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return error.InvalidPath;
    }
    if (reject_symlinks) try rejectSymlinkComponents(path);
}

fn writeCurrentTransactionRecord(
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
        try writeTextCreateNew(allocator, record_path, bytes, .{});
    } else {
        try writeTextAtomic(allocator, record_path, bytes);
    }
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
        try writeTextCreateNew(allocator, record_path, bytes, .{});
    } else {
        try writeTextAtomic(allocator, record_path, bytes);
    }
}

fn renderTransactionRecordAlloc(
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
    errdefer out.deinit();
    try transaction.writeJsonWithFormatAndProfile(
        &out.writer,
        format,
        format == .current,
    );
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
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

fn freeTransactionLockRows(allocator: std.mem.Allocator, locks: []LeaseLock) void {
    for (locks) |*lock| lock.deinit(allocator);
}

const ParsedTransactionRecord = struct {
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

    fn deinit(self: ParsedTransactionRecord, allocator: std.mem.Allocator) void {
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

fn parseTransactionRecord(allocator: std.mem.Allocator, record_path: []const u8) !ParsedTransactionRecord {
    const bytes = try readRegularFileNoSymlink(
        allocator,
        record_path,
        transaction_record_max_bytes,
    );
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
    const locks_value = object.get("locks") orelse return error.TransactionCorrupt;
    if (expected_value != .array or
        writes_value != .array or
        locks_value != .array)
    {
        return error.TransactionCorrupt;
    }

    const process_id = jsonInteger(
        owner_object.get("process_id") orelse
            return error.TransactionCorrupt,
    ) orelse return error.TransactionCorrupt;
    const session_id = jsonString(
        owner_object.get("session_id") orelse
            return error.TransactionCorrupt,
    ) orelse return error.TransactionCorrupt;
    const executor = jsonString(
        owner_object.get("executor") orelse
            return error.TransactionCorrupt,
    ) orelse return error.TransactionCorrupt;
    const created_at = jsonString(
        object.get("created_at") orelse return error.TransactionCorrupt,
    ) orelse return error.TransactionCorrupt;
    const updated_at = jsonString(
        object.get("updated_at") orelse return error.TransactionCorrupt,
    ) orelse return error.TransactionCorrupt;
    const format_hint = if (object.get("journal_format")) |format_value|
        parseTransactionRecordFormat(
            jsonString(format_value) orelse
                return error.TransactionCorrupt,
        ) orelse return error.TransactionCorrupt
    else
        null;
    const bounded_rows = if (object.get("recovery_profile")) |profile_value|
        std.mem.eql(
            u8,
            jsonString(profile_value) orelse
                return error.TransactionCorrupt,
            "bounded-rows-v1",
        ) or return error.TransactionCorrupt
    else
        false;
    try validateTransactionRowBounds(
        bounded_rows,
        expected_value.array.items.len,
        writes_value.array.items.len,
        locks_value.array.items.len,
    );

    const transaction_id_owned = try allocator.dupe(u8, transaction_id);
    errdefer allocator.free(transaction_id_owned);
    const session_id_owned = try allocator.dupe(u8, session_id);
    errdefer allocator.free(session_id_owned);
    const executor_owned = try allocator.dupe(u8, executor);
    errdefer allocator.free(executor_owned);
    const expected = try parseTransactionExpectedArray(
        allocator,
        expected_value.array.items,
    );
    errdefer {
        freeTransactionExpectedRows(allocator, expected);
        allocator.free(expected);
    }
    const writes = try parseTransactionWriteArray(
        allocator,
        writes_value.array.items,
    );
    errdefer {
        freeTransactionWriteRows(allocator, writes);
        allocator.free(writes);
    }
    const embedded_locks = try parseTransactionLockArray(
        allocator,
        locks_value.array.items,
    );
    errdefer {
        freeTransactionLockRows(allocator, embedded_locks);
        allocator.free(embedded_locks);
    }
    const created_at_owned = try allocator.dupe(u8, created_at);
    errdefer allocator.free(created_at_owned);
    const updated_at_owned = try allocator.dupe(u8, updated_at);
    errdefer allocator.free(updated_at_owned);

    return .{
        .transaction_id = transaction_id_owned,
        .owner = .{
            .process_id = process_id,
            .session_id = session_id_owned,
            .executor = executor_owned,
        },
        .state = parseTransactionState(state_text) orelse return error.TransactionCorrupt,
        .expected = expected,
        .writes = writes,
        .embedded_locks = embedded_locks,
        .format_hint = format_hint,
        .bounded_rows = bounded_rows,
        .created_at = created_at_owned,
        .updated_at = updated_at_owned,
    };
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

fn validateAutomaticRecoveryRowBounds(
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
        const sequence = jsonUnsigned(
            object.get("sequence") orelse return error.TransactionCorrupt,
        ) orelse return error.TransactionCorrupt;
        rows[count] = .{
            .path = try allocator.dupe(u8, jsonString(object.get("path") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
            .digest = try allocator.dupe(u8, jsonString(object.get("digest") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
            .sequence = sequence,
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
        const sequence = jsonUnsigned(
            object.get("sequence_after") orelse
                return error.TransactionCorrupt,
        ) orelse return error.TransactionCorrupt;
        rows[count] = .{
            .path = try allocator.dupe(u8, jsonString(object.get("path") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
            .staged_ref = try allocator.dupe(u8, jsonString(object.get("staged_ref") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
            .digest_after = try allocator.dupe(u8, jsonString(object.get("digest_after") orelse return error.TransactionCorrupt) orelse return error.TransactionCorrupt),
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

fn transactionPublishedCount(
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
        var target = try TransactionTarget.init(control_root, write.path);
        defer target.deinit();
        try target.verifyPathIdentity();
        const digest = digestRecoveryFileAtAlloc(
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
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    base: []const u8,
    hash_bytes_remaining: *usize,
) ![]u8 {
    const stat = try dir.statFile(
        Io.io(),
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

fn renderParsedTransactionRecordAlloc(
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

const directory_case_direct_entries_max: usize = 64;
const directory_case_inconclusive_entries_max: usize = 16;
const directory_case_probe_attempts_max: usize = 3;

const DirectoryCaseCache = struct {
    const Value = union(enum) {
        direct: bool,
        scan_inconclusive,
    };

    const Entry = struct {
        device: u64,
        inode: std.Io.File.INode,
        mtime_ns: i96,
        ctime_ns: i96,
        value: Value,
    };

    direct_entries: [directory_case_direct_entries_max]Entry = undefined,
    direct_count: usize = 0,
    direct_replace_index: usize = 0,
    inconclusive_entries: [directory_case_inconclusive_entries_max]Entry = undefined,
    inconclusive_count: usize = 0,
    inconclusive_replace_index: usize = 0,

    fn get(self: DirectoryCaseCache, identity: HostObjectIdentity) ?Value {
        for (self.direct_entries[0..self.direct_count]) |entry| {
            if (entryMatchesIdentity(entry, identity)) return entry.value;
        }
        for (
            self.inconclusive_entries[0..self.inconclusive_count],
        ) |entry| {
            if (entryMatchesIdentity(entry, identity)) return entry.value;
        }
        return null;
    }

    fn entryMatchesIdentity(
        entry: Entry,
        identity: HostObjectIdentity,
    ) bool {
        return entry.device == identity.device and
            entry.inode == identity.inode and
            entry.mtime_ns == identity.mtime_ns and
            entry.ctime_ns == identity.ctime_ns;
    }

    fn ownerIndex(
        entries: []const Entry,
        identity: HostObjectIdentity,
    ) ?usize {
        for (entries, 0..) |entry, index| {
            if (entry.device == identity.device and
                entry.inode == identity.inode) return index;
        }
        return null;
    }

    fn put(
        self: *DirectoryCaseCache,
        identity: HostObjectIdentity,
        value: Value,
    ) void {
        switch (value) {
            .direct => self.putDirect(identity, value),
            .scan_inconclusive => self.putInconclusive(identity, value),
        }
    }

    fn putDirect(
        self: *DirectoryCaseCache,
        identity: HostObjectIdentity,
        value: Value,
    ) void {
        const entries = self.direct_entries[0..self.direct_count];
        const index = ownerIndex(entries, identity) orelse add: {
            if (self.direct_count < self.direct_entries.len) {
                defer self.direct_count += 1;
                break :add self.direct_count;
            }
            break :add self.direct_replace_index;
        };
        self.direct_entries[index] = makeEntry(identity, value);
        self.direct_replace_index =
            (index + 1) % self.direct_entries.len;
    }

    fn putInconclusive(
        self: *DirectoryCaseCache,
        identity: HostObjectIdentity,
        value: Value,
    ) void {
        for (self.direct_entries[0..self.direct_count]) |entry| {
            if (entryMatchesIdentity(entry, identity)) return;
        }
        const entries =
            self.inconclusive_entries[0..self.inconclusive_count];
        const index = ownerIndex(entries, identity) orelse add: {
            if (self.inconclusive_count <
                self.inconclusive_entries.len)
            {
                defer self.inconclusive_count += 1;
                break :add self.inconclusive_count;
            }
            break :add self.inconclusive_replace_index;
        };
        self.inconclusive_entries[index] = makeEntry(identity, value);
        self.inconclusive_replace_index =
            (index + 1) % self.inconclusive_entries.len;
    }

    fn makeEntry(
        identity: HostObjectIdentity,
        value: Value,
    ) Entry {
        return .{
            .device = identity.device,
            .inode = identity.inode,
            .mtime_ns = identity.mtime_ns,
            .ctime_ns = identity.ctime_ns,
            .value = value,
        };
    }
};

threadlocal var directory_case_cache: DirectoryCaseCache = .{};

test "directory case cache is bounded and identity keyed" {
    var cache: DirectoryCaseCache = .{};
    const first: HostObjectIdentity = .{
        .device = 1,
        .inode = 2,
        .kind = .directory,
        .mtime_ns = 3,
        .ctime_ns = 4,
    };
    try std.testing.expect(cache.get(first) == null);
    cache.put(first, .{ .direct = true });
    try std.testing.expect(cache.get(first).?.direct);
    try std.testing.expect(cache.get(.{
        .device = 2,
        .inode = 2,
        .kind = .directory,
        .mtime_ns = 3,
        .ctime_ns = 4,
    }) == null);
    var changed = first;
    changed.ctime_ns += 1;
    try std.testing.expect(cache.get(changed) == null);
    cache.put(changed, .scan_inconclusive);
    try std.testing.expectEqual(@as(usize, 1), cache.direct_count);
    try std.testing.expectEqual(@as(usize, 1), cache.inconclusive_count);
    try std.testing.expectEqual(
        DirectoryCaseCache.Value.scan_inconclusive,
        cache.get(changed).?,
    );
    for (0..directory_case_direct_entries_max + 1) |index| {
        cache.put(.{
            .device = 3,
            .inode = @intCast(index),
            .kind = .directory,
            .mtime_ns = 5,
            .ctime_ns = 6,
        }, .{ .direct = false });
    }
    try std.testing.expectEqual(
        directory_case_direct_entries_max,
        cache.direct_count,
    );
}

test "inconclusive case scans enter a saturated cache" {
    var cache: DirectoryCaseCache = .{};
    for (0..directory_case_direct_entries_max) |index| {
        cache.put(.{
            .device = 1,
            .inode = @intCast(index),
            .kind = .directory,
            .mtime_ns = 1,
            .ctime_ns = 1,
        }, .{ .direct = false });
    }
    const inconclusive: HostObjectIdentity = .{
        .device = 2,
        .inode = 1,
        .kind = .directory,
        .mtime_ns = 2,
        .ctime_ns = 2,
    };
    cache.put(inconclusive, .scan_inconclusive);
    try std.testing.expectEqual(
        DirectoryCaseCache.Value.scan_inconclusive,
        cache.get(inconclusive).?,
    );
    try std.testing.expectEqual(
        directory_case_direct_entries_max,
        cache.direct_count,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        cache.inconclusive_count,
    );
}

fn directoryNameIsCaseInsensitive(
    allocator: std.mem.Allocator,
    directory: []const u8,
    witness_name: []const u8,
) !bool {
    for (0..directory_case_probe_attempts_max) |_| {
        return directoryCaseSensitivityAttempt(
            allocator,
            directory,
            witness_name,
        ) catch |err| switch (err) {
            error.DirectoryIdentityChanged => continue,
            else => return err,
        };
    }
    return error.TransactionRecoveryRequired;
}

fn directoryCaseSensitivityAttempt(
    allocator: std.mem.Allocator,
    directory: []const u8,
    witness_name: []const u8,
) !bool {
    const canonical = try nearestExistingPathAlloc(allocator, directory);
    defer allocator.free(canonical);
    const identity = try hostObjectIdentity(canonical);
    const cached = if (identity) |value| cache: {
        if (value.kind != .directory) return error.NotDir;
        break :cache directory_case_cache.get(value);
    } else cache: {
        if (@import("builtin").os.tag != .windows) {
            return error.TransactionRecoveryRequired;
        }
        break :cache null;
    };
    if (cached) |value| {
        if (value == .direct) return value.direct;
    }

    var direct = try targetNameCaseSensitivity(
        allocator,
        canonical,
        witness_name,
    );
    if (direct == null) {
        direct = try hostDirectoryCaseSensitivity(canonical);
        if (direct == null) {
            if (cached == null or cached.? != .scan_inconclusive) {
                direct = try childNameCaseSensitivity(
                    allocator,
                    canonical,
                );
            }
        }
    }
    if (direct == null) {
        const before = identity orelse
            return error.TransactionRecoveryRequired;
        if (try directoryCrossesDeviceBoundary(canonical, before)) {
            return error.TransactionRecoveryRequired;
        }
    }
    const case_insensitive = direct orelse
        try detectAncestorCaseInsensitivity(
            allocator,
            canonical,
        );
    try cacheDirectoryCaseResult(canonical, identity, direct);
    return case_insensitive;
}

fn cacheDirectoryCaseResult(
    directory: []const u8,
    identity: ?HostObjectIdentity,
    direct: ?bool,
) !void {
    const before = identity orelse return;
    const refreshed = (try hostObjectIdentity(directory)) orelse
        return error.TransactionRecoveryRequired;
    if (!hostObjectIdentitiesEqual(before, refreshed)) {
        return error.DirectoryIdentityChanged;
    }
    directory_case_cache.put(
        refreshed,
        if (direct) |observed|
            .{ .direct = observed }
        else
            .scan_inconclusive,
    );
}

fn directoryCrossesDeviceBoundary(
    directory: []const u8,
    identity: HostObjectIdentity,
) !bool {
    const parent = std.fs.path.dirname(directory) orelse return false;
    if (std.mem.eql(u8, parent, directory)) return false;
    const parent_identity = (try hostObjectIdentity(parent)) orelse
        return error.TransactionRecoveryRequired;
    if (parent_identity.kind != .directory) return error.NotDir;
    return parent_identity.device != identity.device;
}

fn hostDirectoryCaseSensitivity(
    directory: []const u8,
) !?bool {
    return switch (@import("builtin").os.tag) {
        .linux => linuxDirectoryCaseSensitivity(directory),
        .windows => windowsDirectoryCaseSensitivity(directory),
        else => null,
    };
}

fn linuxDirectoryCaseSensitivity(
    directory: []const u8,
) !?bool {
    const linux = std.os.linux;
    const fs_ioc_getflags: u32 = 0x8008_6601;
    const fs_casefold_fl: usize = 0x4000_0000;
    var dir = if (std.fs.path.isAbsolute(directory))
        try std.Io.Dir.openDirAbsolute(Io.io(), directory, .{
            .follow_symlinks = false,
        })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), directory, .{
            .follow_symlinks = false,
        });
    defer dir.close(Io.io());
    while (true) { // tiger: event-loop -- bounded by syscall completion.
        var flags: usize = 0;
        const result = linux.ioctl(
            dir.handle,
            fs_ioc_getflags,
            @intFromPtr(&flags),
        );
        switch (linux.errno(result)) {
            .SUCCESS => return (flags & fs_casefold_fl) != 0,
            .INTR => continue,
            .INVAL, .NOTTY, .OPNOTSUPP, .NOSYS => return null,
            else => return error.TransactionRecoveryRequired,
        }
    }
}

const WindowsFileCaseSensitiveInformation = extern struct {
    flags: u32,
};

fn windowsDirectoryCaseSensitivity(
    directory: []const u8,
) !?bool {
    const windows = std.os.windows;
    const file_cs_flag_case_sensitive_dir: u32 = 0x1;
    var dir = if (std.fs.path.isAbsolute(directory))
        try std.Io.Dir.openDirAbsolute(Io.io(), directory, .{
            .follow_symlinks = false,
        })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), directory, .{
            .follow_symlinks = false,
        });
    defer dir.close(Io.io());
    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    var information: WindowsFileCaseSensitiveInformation = undefined;
    return switch (windows.ntdll.NtQueryInformationFile(
        dir.handle,
        &io_status_block,
        &information,
        @sizeOf(WindowsFileCaseSensitiveInformation),
        .CaseSensitive,
    )) {
        .SUCCESS => (information.flags &
            file_cs_flag_case_sensitive_dir) == 0,
        .INVALID_INFO_CLASS, .INVALID_PARAMETER, .NOT_SUPPORTED => null,
        else => error.TransactionRecoveryRequired,
    };
}

fn detectAncestorCaseInsensitivity(
    allocator: std.mem.Allocator,
    directory: []const u8,
) !bool {
    var canonical = try allocator.dupeZ(u8, directory);
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

fn targetNameCaseSensitivity(
    allocator: std.mem.Allocator,
    directory: []const u8,
    witness_name: []const u8,
) !?bool {
    const attempts_max: usize = 2;
    var dir = if (std.fs.path.isAbsolute(directory))
        try std.Io.Dir.openDirAbsolute(Io.io(), directory, .{
            .follow_symlinks = false,
        })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), directory, .{
            .follow_symlinks = false,
        });
    defer dir.close(Io.io());
    const variant = (try caseVariantAlloc(
        allocator,
        witness_name,
    )) orelse return null;
    defer allocator.free(variant);
    for (0..attempts_max) |_| {
        const first = try targetNameStats(
            dir,
            witness_name,
            variant,
        );
        const second = try targetNameStats(
            dir,
            witness_name,
            variant,
        );
        if (!first.eql(second)) continue;
        return classifyTargetNameStats(
            allocator,
            dir,
            witness_name,
            variant,
            second,
        );
    }
    return error.TransactionRecoveryRequired;
}

const TargetNameStats = struct {
    original: ?std.Io.File.Stat,
    alias: ?std.Io.File.Stat,

    fn eql(left: TargetNameStats, right: TargetNameStats) bool {
        return targetNameStatEqual(left.original, right.original) and
            targetNameStatEqual(left.alias, right.alias);
    }
};

fn targetNameStats(
    dir: std.Io.Dir,
    original_name: []const u8,
    alias_name: []const u8,
) !TargetNameStats {
    return .{
        .original = try targetNameStat(dir, original_name),
        .alias = try targetNameStat(dir, alias_name),
    };
}

fn targetNameStatEqual(
    left: ?std.Io.File.Stat,
    right: ?std.Io.File.Stat,
) bool {
    const left_value = left orelse return right == null;
    const right_value = right orelse return false;
    return left_value.inode == right_value.inode and
        left_value.kind == right_value.kind and
        left_value.mtime.nanoseconds == right_value.mtime.nanoseconds and
        left_value.ctime.nanoseconds == right_value.ctime.nanoseconds;
}

fn classifyTargetNameStats(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    witness_name: []const u8,
    variant: []const u8,
    stats: TargetNameStats,
) !?bool {
    if (stats.original) |original| {
        if (original.kind == .sym_link) return null;
    } else {
        const alias = stats.alias orelse return null;
        if (alias.kind == .sym_link) return null;
        return false;
    }
    if (stats.alias) |alias| {
        if (alias.kind == .sym_link) return false;
    } else {
        return false;
    }
    return @as(?bool, try targetNamesResolveToSamePath(
        allocator,
        dir,
        witness_name,
        variant,
    ));
}

fn targetNameStat(
    dir: std.Io.Dir,
    name: []const u8,
) !?std.Io.File.Stat {
    return dir.statFile(
        Io.io(),
        name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn targetNamesResolveToSamePath(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    original_name: []const u8,
    alias_name: []const u8,
) !bool {
    const original = dir.realPathFileAlloc(
        Io.io(),
        original_name,
        allocator,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.TransactionRecoveryRequired,
        else => return err,
    };
    defer allocator.free(original);
    const alias = dir.realPathFileAlloc(
        Io.io(),
        alias_name,
        allocator,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.TransactionRecoveryRequired,
        else => return err,
    };
    defer allocator.free(alias);
    return std.mem.eql(u8, original, alias);
}

fn childNameCaseSensitivity(
    allocator: std.mem.Allocator,
    directory: []const u8,
) !?bool {
    const entries_max: usize = 1024;
    var dir = if (std.fs.path.isAbsolute(directory))
        try std.Io.Dir.openDirAbsolute(Io.io(), directory, .{
            .iterate = true,
            .follow_symlinks = false,
        })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), directory, .{
            .iterate = true,
            .follow_symlinks = false,
        });
    defer dir.close(Io.io());
    var entries: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(Io.io())) |entry| {
        entries += 1;
        if (entries > entries_max) return null;
        const original_stat = dir.statFile(
            Io.io(),
            entry.name,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (original_stat.kind == .sym_link) continue;
        const variant = (try caseVariantAlloc(
            allocator,
            entry.name,
        )) orelse continue;
        defer allocator.free(variant);
        const alias_stat = dir.statFile(
            Io.io(),
            variant,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const witness_stat = dir.statFile(
                    Io.io(),
                    entry.name,
                    .{ .follow_symlinks = false },
                ) catch |witness_error| switch (witness_error) {
                    error.FileNotFound => continue,
                    else => return witness_error,
                };
                if (witness_stat.kind == .sym_link) continue;
                return false;
            },
            else => return err,
        };
        if (alias_stat.kind == .sym_link) continue;
        const original = dir.realPathFileAlloc(
            Io.io(),
            entry.name,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(original);
        const alias = dir.realPathFileAlloc(
            Io.io(),
            variant,
            allocator,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                const witness_stat = dir.statFile(
                    Io.io(),
                    entry.name,
                    .{ .follow_symlinks = false },
                ) catch |witness_error| switch (witness_error) {
                    error.FileNotFound => continue,
                    else => return witness_error,
                };
                if (witness_stat.kind == .sym_link) continue;
                return false;
            },
            else => return err,
        };
        defer allocator.free(alias);
        return std.mem.eql(u8, original, alias);
    }
    return null;
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
    if (try directoryNameIsCaseInsensitive(
        allocator,
        parent,
        basename,
    )) {
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
    try rejectCasControlTargetPath(store_path);
    return std.fmt.allocPrint(allocator, "{s}.cas.lock", .{store_path});
}

pub fn rejectCasControlTargetPath(store_path: []const u8) !void {
    var components = std.mem.tokenizeAny(u8, store_path, "/\\");
    while (components.next()) |component| {
        if (endsWithAsciiIgnoreCase(component, ".cas.lock") or
            endsWithAsciiIgnoreCase(component, ".cas.lock.advisory"))
        {
            return error.ReservedCasControlPath;
        }
    }
}

fn endsWithAsciiIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn casAdvisoryPathAlloc(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) ![]u8 {
    const cas_path = try casLockPathAlloc(allocator, store_path);
    defer allocator.free(cas_path);
    return std.fmt.allocPrint(
        allocator,
        "{s}.advisory",
        .{cas_path},
    );
}

fn acquireCasAdvisoryLock(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !std.Io.File {
    return acquireCasAdvisoryLockObserved(
        allocator,
        store_path,
        null,
    );
}

fn acquireCasAdvisoryLockObserved(
    allocator: std.mem.Allocator,
    store_path: []const u8,
    storage_mutated: ?*bool,
) !std.Io.File {
    const advisory_path = try casAdvisoryPathAlloc(
        allocator,
        store_path,
    );
    defer allocator.free(advisory_path);
    var created = false;
    const lock = openEventStoreSidecarExclusiveObserved(
        advisory_path,
        &created,
    ) catch |err| switch (err) {
        error.WouldBlock => return error.LockBusy,
        else => return err,
    };
    if (created) {
        if (storage_mutated) |mutated| mutated.* = true;
    }
    return lock;
}

pub const CasReadLockPair = struct {
    files: [2]std.Io.File = undefined,
    count: u2 = 0,

    pub fn deinit(self: *CasReadLockPair) void {
        for (self.files[0..self.count]) |file| file.close(Io.io());
        self.* = undefined;
    }
};

pub fn acquireCasReadLockPair(
    allocator: std.mem.Allocator,
    left_path: []const u8,
    right_path: []const u8,
) !CasReadLockPair {
    const left_first = std.mem.lessThan(u8, left_path, right_path);
    const paths = if (left_first)
        [2][]const u8{ left_path, right_path }
    else
        [2][]const u8{ right_path, left_path };
    var result = CasReadLockPair{};
    errdefer result.deinit();
    for (paths, 0..) |path, index| {
        if (index == 1 and std.mem.eql(u8, paths[0], path)) break;
        result.files[result.count] =
            (try openCasAdvisorySharedIfExists(allocator, path)) orelse
            continue;
        result.count += 1;
    }
    return result;
}

pub fn casAdvisoryLockExists(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !bool {
    const advisory_path = try casAdvisoryPathAlloc(allocator, store_path);
    defer allocator.free(advisory_path);
    return (try statRegularFileNoSymlink(advisory_path)) != null;
}

fn openCasAdvisorySharedIfExists(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) !?std.Io.File {
    const advisory_path = try casAdvisoryPathAlloc(allocator, store_path);
    defer allocator.free(advisory_path);
    _ = (try statRegularFileNoSymlink(advisory_path)) orelse return null;
    return try openEventStoreSidecarSharedExisting(advisory_path);
}

fn acquireTransactionJournalLock(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    storage_mutated: ?*bool,
) !std.Io.File {
    const path = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, ".journal.advisory" },
    );
    defer allocator.free(path);
    var created = false;
    const lock = openEventStoreSidecarExclusiveObserved(
        path,
        &created,
    ) catch |err| switch (err) {
        error.WouldBlock => return error.LockBusy,
        else => return err,
    };
    if (created) {
        if (storage_mutated) |mutated| mutated.* = true;
    }
    return lock;
}

fn acquireTransactionRecoveryLock(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    storage_mutated: ?*bool,
) !std.Io.File {
    const path = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, ".recovery.advisory" },
    );
    defer allocator.free(path);
    var created = false;
    const lock = openEventStoreSidecarExclusiveObserved(
        path,
        &created,
    ) catch |err| switch (err) {
        error.WouldBlock => return error.LockBusy,
        else => return err,
    };
    if (created) {
        if (storage_mutated) |mutated| mutated.* = true;
    }
    return lock;
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
    var storage_mutated = false;
    return ensureDirectoryPathNoSymlinksObserved(
        path,
        &storage_mutated,
    );
}

pub fn ensureDirectoryPathNoSymlinksObserved(
    path: []const u8,
    storage_mutated: *bool,
) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return;

    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        const stat = std.Io.Dir.cwd().statFile(Io.io(), component.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                var created = true;
                std.Io.Dir.cwd().createDir(
                    Io.io(),
                    component.path,
                    .default_dir,
                ) catch |create_error| switch (create_error) {
                    error.PathAlreadyExists => created = false,
                    else => return create_error,
                };
                if (created) storage_mutated.* = true;
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
    const dir_stat = try std.Io.Dir.cwd().statFile(
        Io.io(),
        dir_path,
        .{ .follow_symlinks = false },
    );
    if (dir_stat.kind == .sym_link) return error.SymlinkComponent;
    if (dir_stat.kind != .directory) return error.NotDir;

    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.Io.Dir.openDirAbsolute(
            Io.io(),
            dir_path,
            .{ .iterate = true, .follow_symlinks = false },
        )
    else
        try std.Io.Dir.cwd().openDir(
            Io.io(),
            dir_path,
            .{ .iterate = true, .follow_symlinks = false },
        );
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

    pub fn releaseChecked(
        self: *LockFile,
        allocator: std.mem.Allocator,
    ) !void {
        if (std.fs.path.isAbsolute(self.path)) {
            try std.Io.Dir.deleteFileAbsolute(Io.io(), self.path);
        } else {
            try std.Io.Dir.cwd().deleteFile(Io.io(), self.path);
        }
        allocator.free(self.path);
        self.* = .{ .path = &.{} };
    }

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
    var created = false;
    return openEventStoreSidecarExclusiveObserved(path, &created);
}

fn openEventStoreSidecarExclusiveObserved(
    path: []const u8,
    created: *bool,
) !std.Io.File {
    var attempt: u8 = 0;
    while (attempt < 4) : (attempt += 1) {
        const file = (if (std.fs.path.isAbsolute(path))
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
        created.* = true;
        return file;
    }
    return error.FileNotFound;
}

fn openEventStoreSidecarSharedExisting(path: []const u8) !std.Io.File {
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
        error.FileNotFound => return error.MissingCasAdvisoryLock,
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
    const counter_lock = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}.lock",
        .{counter},
    );
    defer std.testing.allocator.free(counter_lock);
    try std.testing.expect(lock.fencing_token > 0);
    try std.testing.expect(fileExists(lock.path));
    try std.testing.expect(!fileExists(counter_lock));
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
    const corrupt_counter_lock = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}.lock",
        .{corrupt_counter},
    );
    defer std.testing.allocator.free(corrupt_counter_lock);
    try std.testing.expect(!fileExists(corrupt_counter_lock));
}

test "lease retry releases advisory custody before waiting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
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
    var lock = try acquireLeaseLock(allocator, resource, options);
    const contender = try tryAcquireLeaseLockObserved(
        allocator,
        resource,
        lock.path,
        counter,
        options,
        null,
    );
    try std.testing.expect(contender == null);
    try refreshLease(
        allocator,
        &lock,
        lock.fencing_token,
        1000,
    );
    try releaseLease(allocator, &lock, lock.fencing_token);
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

test "CAS targets cannot inhabit generated control paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
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
                std.testing.allocator,
                path,
                "{\"seq\":1}\n",
                .{ .expected_exists = false },
            ),
        );
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.cwd().access(Io.io(), path, .{}),
        );
    }
}

test "transactions reject CAS control aliases before creating directories" {
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
            std.Io.Dir.cwd().access(Io.io(), path, .{}),
        );
    }
}

test "transactions reject missing descendants of case-aliased journal roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    if (!try directoryNameIsCaseInsensitive(
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
    try ensureDirectoryPathNoSymlinks(transactions_dir);
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
    try std.testing.expect(!fileExists(aliased_parent));
}

test "transactions reject targets inside their journal namespace" {
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
    try std.testing.expect(!fileExists(target));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countPendingTransactions(allocator, transactions_dir),
    );
}

test "transactions reject journals larger than recovery can represent" {
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
    try std.testing.expect(!fileExists(transactions_dir));
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
    var hash_bytes_remaining = transaction_recovery_hash_max_bytes;
    const published = try transactionPublishedCount(
        std.testing.allocator,
        root,
        &writes,
        &.{},
        &hash_bytes_remaining,
    );
    try std.testing.expectEqual(@as(?usize, 1), published);
}

test "transaction recovery hashing consumes one aggregate budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    try tmp.dir.writeFile(Io.io(), .{
        .sub_path = "first",
        .data = "1234",
    });
    try tmp.dir.writeFile(Io.io(), .{
        .sub_path = "second",
        .data = "5678",
    });
    var dir = try std.Io.Dir.openDirAbsolute(
        Io.io(),
        root,
        .{ .follow_symlinks = false },
    );
    defer dir.close(Io.io());
    var hash_bytes_remaining: usize = 7;
    const first = try digestRecoveryFileAtAlloc(
        allocator,
        &dir,
        "first",
        &hash_bytes_remaining,
    );
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 3), hash_bytes_remaining);
    try std.testing.expectError(
        error.TransactionRecoveryWorkExceeded,
        digestRecoveryFileAtAlloc(
            allocator,
            &dir,
            "second",
            &hash_bytes_remaining,
        ),
    );
}

test "recovery scan shares one hash budget across transaction journals" {
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
    try ensureDirectoryPathNoSymlinks(transactions_dir);
    const content = "{\"seq\":1}\n";
    for (0..2) |index| {
        const transaction_id = try std.fmt.allocPrint(
            allocator,
            "dtx-1-0000000000000000000000000000000{d}",
            .{index + 1},
        );
        defer allocator.free(transaction_id);
        const target_path = try std.fmt.allocPrint(
            allocator,
            "{s}/events-{d}.jsonl",
            .{ root, index },
        );
        defer allocator.free(target_path);
        try writeTextAtomic(allocator, target_path, content);
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
    try ensureDirectoryPathNoSymlinks(transactions_dir);
    const counter = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "workspace.counter" },
    );
    defer std.testing.allocator.free(counter);
    const owner: Owner = .{
        .process_id = 200,
        .session_id = "txn-session",
        .executor = "test",
    };

    const workspace_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "workspace.jsonl" },
    );
    defer std.testing.allocator.free(workspace_path);
    const plan_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "plan.jsonl" },
    );
    defer std.testing.allocator.free(plan_path);
    try writeTextAtomic(
        std.testing.allocator,
        workspace_path,
        "{\"seq\":1,\"workspace\":true}\n",
    );
    try writeTextAtomic(
        std.testing.allocator,
        plan_path,
        "{\"seq\":1,\"plan\":true}\n",
    );
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

    const rollback_id = "dtx-1-00000000000000000000000000000003";
    const rollback_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ transactions_dir, rollback_id },
    );
    defer std.testing.allocator.free(rollback_dir);
    try ensureDirectoryPathNoSymlinks(rollback_dir);
    const rollback_record = try std.fs.path.join(
        std.testing.allocator,
        &.{ rollback_dir, "transaction.json" },
    );
    defer std.testing.allocator.free(rollback_record);
    const rollback_path = try std.fs.path.join(std.testing.allocator, &.{ root, "rollback.jsonl" });
    defer std.testing.allocator.free(rollback_path);
    try writeTextAtomic(std.testing.allocator, rollback_path, "{\"seq\":1}\n");
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
        try countPendingTransactions(std.testing.allocator, transactions_dir),
    );
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        ensureNoPendingTransactions(std.testing.allocator, transactions_dir),
    );
    var rollback_status = try inspectTransaction(std.testing.allocator, rollback_dir);
    defer rollback_status.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, rollback_status.decision);
    var rollback_receipt = try recoverTransaction(std.testing.allocator, rollback_dir);
    defer rollback_receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, rollback_receipt.decision);
    const rollback_after = try tryReadForTest(rollback_path);
    defer std.testing.allocator.free(rollback_after);
    try std.testing.expectEqualStrings("{\"seq\":2}\n", rollback_after);
    try std.testing.expectEqual(
        @as(usize, 0),
        try countPendingTransactions(std.testing.allocator, transactions_dir),
    );

    const finish_id = "dtx-1-00000000000000000000000000000004";
    const finish_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ transactions_dir, finish_id },
    );
    defer std.testing.allocator.free(finish_dir);
    try ensureDirectoryPathNoSymlinks(finish_dir);
    const finish_record = try std.fs.path.join(
        std.testing.allocator,
        &.{ finish_dir, "transaction.json" },
    );
    defer std.testing.allocator.free(finish_record);
    const finish_path = try std.fs.path.join(std.testing.allocator, &.{ root, "finish.jsonl" });
    defer std.testing.allocator.free(finish_path);
    try writeTextAtomic(std.testing.allocator, finish_path, "{\"seq\":2}\n");
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
        try countPendingTransactions(std.testing.allocator, transactions_dir),
    );
    var finish_status = try inspectTransaction(std.testing.allocator, finish_dir);
    defer finish_status.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, finish_status.decision);
    var finish_receipt = try recoverTransaction(std.testing.allocator, finish_dir);
    defer finish_receipt.deinit(std.testing.allocator);
    try std.testing.expectEqual(RecoveryDecision.finish_commit, finish_receipt.decision);
    const finish_marker = try std.fs.path.join(
        std.testing.allocator,
        &.{ finish_dir, "commit.json" },
    );
    defer std.testing.allocator.free(finish_marker);
    try std.testing.expect(fileExists(finish_marker));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countPendingTransactions(std.testing.allocator, transactions_dir),
    );

    const mixed_id = "dtx-1-00000000000000000000000000000005";
    const mixed_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ transactions_dir, mixed_id },
    );
    defer std.testing.allocator.free(mixed_dir);
    try ensureDirectoryPathNoSymlinks(mixed_dir);
    const mixed_record = try std.fs.path.join(
        std.testing.allocator,
        &.{ mixed_dir, "transaction.json" },
    );
    defer std.testing.allocator.free(mixed_record);
    const mixed_a = try std.fs.path.join(std.testing.allocator, &.{ root, "mixed-a.jsonl" });
    defer std.testing.allocator.free(mixed_a);
    const mixed_b = try std.fs.path.join(std.testing.allocator, &.{ root, "mixed-b.jsonl" });
    defer std.testing.allocator.free(mixed_b);
    try writeTextAtomic(std.testing.allocator, mixed_a, "{\"seq\":2}\n");
    try writeTextAtomic(std.testing.allocator, mixed_b, "{\"seq\":1}\n");
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
        try countPendingTransactions(std.testing.allocator, transactions_dir),
    );
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
    const transaction_id = "dtx-1-00000000000000000000000000000001";
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
        &.{ transaction_dir, staged_ref },
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
    try std.testing.expect(receipt.storage_mutated);
    try std.testing.expect(!fileExists(staged_path));
    const after = try tryReadForTest(target_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "transaction recovery reclaims only empty current recordless journals" {
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
        &.{
            transactions_dir,
            "dtx-1-00000000000000000000000000000006",
        },
    );
    defer allocator.free(incomplete_dir);
    try ensureDirectoryPathNoSymlinks(incomplete_dir);

    try std.testing.expectEqual(
        @as(usize, 1),
        try countPendingTransactions(allocator, transactions_dir),
    );
    try recoverAndCompactTransactions(allocator, transactions_dir);
    try std.testing.expect(!fileExists(incomplete_dir));

    const nonempty_current_dir = try std.fs.path.join(
        allocator,
        &.{
            transactions_dir,
            "dtx-1-00000000000000000000000000000008",
        },
    );
    defer allocator.free(nonempty_current_dir);
    try ensureDirectoryPathNoSymlinks(nonempty_current_dir);
    const current_unowned_path = try std.fs.path.join(
        allocator,
        &.{ nonempty_current_dir, "unknown" },
    );
    defer allocator.free(current_unowned_path);
    try writeTextAtomic(allocator, current_unowned_path, "retain");
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactions(allocator, transactions_dir),
    );
    try std.testing.expect(fileExists(current_unowned_path));
    try std.Io.Dir.cwd().deleteTree(Io.io(), nonempty_current_dir);

    const legacy_incomplete_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-1" },
    );
    defer allocator.free(legacy_incomplete_dir);
    try ensureDirectoryPathNoSymlinks(legacy_incomplete_dir);
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactions(allocator, transactions_dir),
    );
    try std.testing.expect(fileExists(legacy_incomplete_dir));
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ root, "fencing.counter" },
    );
    defer allocator.free(counter_path);
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{ .shared = counter_path },
            },
        ),
    );
    try std.testing.expect(fileExists(legacy_incomplete_dir));

    try std.Io.Dir.cwd().deleteDir(Io.io(), legacy_incomplete_dir);
    const nonempty_legacy_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-2" },
    );
    defer allocator.free(nonempty_legacy_dir);
    try ensureDirectoryPathNoSymlinks(nonempty_legacy_dir);
    const unowned_path = try std.fs.path.join(
        allocator,
        &.{ nonempty_legacy_dir, "unknown" },
    );
    defer allocator.free(unowned_path);
    try writeTextAtomic(allocator, unowned_path, "retain");
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{ .shared = counter_path },
            },
        ),
    );
    try std.testing.expect(fileExists(unowned_path));
}

test "transaction recovery reports recovery lock creation as mutation" {
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
    try ensureDirectoryPathNoSymlinks(transactions_dir);

    const first = try recoverAndCompactTransactionsWithOptions(
        allocator,
        transactions_dir,
        .{},
    );
    try std.testing.expect(first.storage_mutated);
    const second = try recoverAndCompactTransactionsWithOptions(
        allocator,
        transactions_dir,
        .{},
    );
    try std.testing.expect(!second.storage_mutated);

    const invalid_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "invalid" },
    );
    defer allocator.free(invalid_dir);
    try ensureDirectoryPathNoSymlinks(invalid_dir);
    var failed: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverAndCompactTransactionsAccumulating(
            allocator,
            transactions_dir,
            .{},
            &failed,
        ),
    );
    try std.testing.expect(failed.storage_mutated);
}

test "committed legacy journals require syncable target parents before compaction" {
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
    const transaction_id = "dtx-1";
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
    const commit_marker_path = try transactionCommitMarkerPathAlloc(
        allocator,
        transaction_dir,
    );
    defer allocator.free(commit_marker_path);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "events.jsonl" },
    );
    defer allocator.free(target_path);
    const removed_target_parent = try std.fs.path.join(
        allocator,
        &.{ root, "removed" },
    );
    defer allocator.free(removed_target_parent);
    const removed_target_path = try std.fs.path.join(
        allocator,
        &.{ removed_target_parent, "events.jsonl" },
    );
    defer allocator.free(removed_target_path);
    const content = "{\"seq\":1}\n";
    try writeTextAtomic(allocator, target_path, content);
    try writeTextAtomic(allocator, removed_target_path, content);
    const content_digest = try digestBytesAlloc(allocator, content);
    defer allocator.free(content_digest);
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
    try writeCommittedTransactionMarker(allocator, commit_marker_path);
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ root, ".fencing.counter" },
    );
    defer allocator.free(counter_path);
    try writeTextAtomic(allocator, counter_path, "10\n");
    try writeTextAtomic(allocator, target_path, "{\"seq\":2}\n");
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{
                    .shared = counter_path,
                },
            },
        ),
    );
    try std.testing.expect(fileExists(transaction_dir));
    try writeTextAtomic(allocator, target_path, content);
    try std.Io.Dir.cwd().deleteTree(Io.io(), removed_target_parent);
    var expired_lease = try acquireLeaseLock(
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
    try std.Io.sleep(Io.io(), .fromMilliseconds(3), .awake);

    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{
                    .shared = counter_path,
                },
            },
        ),
    );
    try std.testing.expect(fileExists(transaction_dir));
    try std.testing.expect(fileExists(expired_lease.path));
    try releaseLease(
        allocator,
        &expired_lease,
        expired_lease.fencing_token,
    );
    try std.testing.expectError(
        error.FileNotFound,
        recoverAndCompactTransactionsWithOptions(
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{
                    .shared = counter_path,
                },
            },
        ),
    );
    try std.testing.expect(fileExists(transaction_dir));
    try std.testing.expect(!fileExists(expired_lease.path));
    try std.testing.expect(!fileExists(removed_target_parent));
    const after = try tryReadForTest(target_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(content, after);
}

test "committed legacy journals retain fail-closed lease custody until marker" {
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
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-20" },
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
        &.{ root, "guard.json" },
    );
    defer allocator.free(target_path);
    const content = "{\"guard\":true}\n";
    try writeTextAtomic(allocator, target_path, content);
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
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ root, "fencing.counter" },
    );
    defer allocator.free(counter_path);
    var writer_lease = try acquireLeaseLock(
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
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{
                    .shared = counter_path,
                },
            },
            &busy_summary,
        ),
    );
    try std.testing.expect(busy_summary.storage_mutated);
    try releaseLease(
        allocator,
        &writer_lease,
        writer_lease.fencing_token,
    );

    var recovery_storage_mutated = false;
    var recovery_leases = try acquireLegacyTransactionRecoveryLeases(
        allocator,
        &expected,
        owner,
        "dtx-20",
        counter_path,
        &recovery_storage_mutated,
    );
    const expires_ms = try parseU64Text(recovery_leases[0].expires_at);
    try std.testing.expect(
        expires_ms - clockMillis(.real) > 365 * 24 * 60 * 60 * 1000,
    );
    try releaseLegacyTransactionRecoveryLeases(
        allocator,
        &recovery_leases,
        &recovery_storage_mutated,
    );

    var failed_release_leases = try acquireLegacyTransactionRecoveryLeases(
        allocator,
        &expected,
        owner,
        "dtx-20",
        counter_path,
        &recovery_storage_mutated,
    );
    try std.Io.Dir.deleteFileAbsolute(
        Io.io(),
        failed_release_leases[0].path,
    );
    try std.testing.expectError(
        error.FileNotFound,
        releaseLegacyTransactionRecoveryLeases(
            allocator,
            &failed_release_leases,
            &recovery_storage_mutated,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), failed_release_leases.len);

    const commit_marker_path = try transactionCommitMarkerPathAlloc(
        allocator,
        transaction_dir,
    );
    defer allocator.free(commit_marker_path);
    try writeCommittedTransactionMarker(
        allocator,
        commit_marker_path,
    );
    var expired_terminal_lease = try acquireLeaseLock(
        allocator,
        target_path,
        .{
            .owner = owner,
            .lease_ms = 1,
            .fencing_counter_path = counter_path,
        },
    );
    try std.Io.sleep(Io.io(), .fromMilliseconds(3), .awake);
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{
                    .shared = counter_path,
                },
            },
        ),
    );
    try std.testing.expect(fileExists(transaction_dir));
    try std.testing.expect(fileExists(expired_terminal_lease.path));
    try releaseLease(
        allocator,
        &expired_terminal_lease,
        expired_terminal_lease.fencing_token,
    );
    const counter_before_terminal = try readFencingCounter(
        allocator,
        counter_path,
    );
    const summary = try recoverAndCompactTransactionsWithOptions(
        allocator,
        transactions_dir,
        .{
            .legacy_fencing_authority = .{
                .shared = counter_path,
            },
        },
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expect(!fileExists(transaction_dir));
    try std.testing.expect(
        try readFencingCounter(allocator, counter_path) >
            counter_before_terminal,
    );
}

const ExpiredLeaseRepairFixture = struct {
    transaction_dir: []u8,
    counter_path: []u8,
    expired: LeaseLock,

    fn init(
        allocator: std.mem.Allocator,
        root: []const u8,
    ) !ExpiredLeaseRepairFixture {
        const transaction_id = "dtx-62";
        const transaction_dir = try std.fs.path.join(
            allocator,
            &.{ root, "transactions", transaction_id },
        );
        errdefer allocator.free(transaction_dir);
        try ensureDirectoryPathNoSymlinks(transaction_dir);
        const record_path = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "transaction.json" },
        );
        defer allocator.free(record_path);
        const target_path = try std.fs.path.join(
            allocator,
            &.{ root, "repair.jsonl" },
        );
        defer allocator.free(target_path);
        try writeTextAtomic(allocator, target_path, "{\"sequence\":1}\n");
        const counter_path = try std.fs.path.join(
            allocator,
            &.{ root, "fencing.counter" },
        );
        errdefer allocator.free(counter_path);
        const owner: Owner = .{
            .process_id = 962,
            .session_id = "witnessed-lease-repair",
            .executor = "test",
        };
        var expired = try acquireLeaseLock(allocator, target_path, .{
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
        try std.Io.sleep(Io.io(), .fromMilliseconds(3), .awake);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    var fixture = try ExpiredLeaseRepairFixture.init(allocator, root);
    defer fixture.deinit(allocator);
    try refreshLease(
        allocator,
        &fixture.expired,
        fixture.expired.fencing_token,
        60_000,
    );

    const candidates = try inspectLegacyLeaseRecoveryCandidates(
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
    try std.testing.expect(fileExists(fixture.expired.path));
}

test "legacy lease repair requires and revalidates an exact journal witness" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    var fixture = try ExpiredLeaseRepairFixture.init(allocator, root);
    defer fixture.deinit(allocator);
    const candidates = try inspectLegacyLeaseRecoveryCandidates(
        allocator,
        fixture.transaction_dir,
        .{ .shared = fixture.counter_path },
    );
    defer deinitLegacyLeaseRecoveryCandidates(allocator, candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings(
        fixture.expired.lock_id,
        candidates[0].lock_id,
    );
    try std.testing.expectEqual(
        fixture.expired.fencing_token,
        candidates[0].fencing_token,
    );
    try std.testing.expectEqual(
        LegacyLeaseRecoveryCandidate.Kind.expired_legacy,
        candidates[0].kind,
    );

    const counter_before_mismatch = try readFencingCounter(
        allocator,
        fixture.counter_path,
    );
    var mismatch_summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        reclaimLegacyLease(
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
    try std.testing.expect(fileExists(fixture.expired.path));
    try std.testing.expectEqual(
        counter_before_mismatch,
        try readFencingCounter(allocator, fixture.counter_path),
    );

    var unconfirmed_summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.LegacyWriterConfirmationRequired,
        reclaimLegacyLease(
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
    try std.testing.expect(fileExists(fixture.expired.path));

    var summary: TransactionRecoverySummary = .{};
    const receipt = try reclaimLegacyLease(
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
    try std.testing.expectEqual(
        fixture.expired.fencing_token,
        receipt.previous_fencing_token,
    );
    try std.testing.expect(!fileExists(fixture.expired.path));
}

test "legacy reclaim preserves existing recovery evidence without replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    var fixture = try ExpiredLeaseRepairFixture.init(allocator, root);
    defer fixture.deinit(allocator);
    const evidence_path = try std.fmt.allocPrint(
        allocator,
        "{s}.reclaimed-{d}",
        .{ fixture.expired.path, fixture.expired.fencing_token },
    );
    defer allocator.free(evidence_path);
    try writeTextCreateNew(
        allocator,
        evidence_path,
        "preexisting evidence\n",
        .{},
    );

    var summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.PathAlreadyExists,
        reclaimLegacyLease(
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
    const preserved = try readFileAlloc(
        allocator,
        evidence_path,
        4096,
    );
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings(
        "preexisting evidence\n",
        preserved,
    );
    try std.testing.expect(fileExists(fixture.expired.path));
}

test "interrupted recovery leases are transaction-bound and repairable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    var fixture = try ExpiredLeaseRepairFixture.init(allocator, root);
    defer fixture.deinit(allocator);
    const resource = try allocator.dupe(u8, fixture.expired.resource);
    defer allocator.free(resource);
    try releaseLease(
        allocator,
        &fixture.expired,
        fixture.expired.fencing_token,
    );
    const owner: Owner = .{
        .process_id = 962,
        .session_id = "witnessed-lease-repair",
        .executor = "test",
    };
    var interrupted = try acquireLeaseLock(
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

    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        reclaimExpiredLease(
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
    try std.testing.expect(!fileExists(lock_path));
}

test "legacy reclaim rejects symlinked resource parents" {
    if (@import("builtin").os.tag == .windows) {
        return error.SkipZigTest;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    try tmp.dir.createDir(Io.io(), "outside", .default_dir);
    try tmp.dir.symLink(
        Io.io(),
        "outside",
        "linked",
        .{ .is_directory = true },
    );
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-69" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const resource = try std.fs.path.join(
        allocator,
        &.{ root, "linked", "repair.jsonl" },
    );
    defer allocator.free(resource);
    const lock_path = try lockPathAlloc(allocator, resource);
    defer allocator.free(lock_path);
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ root, "fencing.counter" },
    );
    defer allocator.free(counter_path);
    const owner: Owner = .{
        .process_id = 969,
        .session_id = "symlinked-reclaim-resource",
        .executor = "test",
    };
    var lock = try makeLeaseLockOwned(
        allocator,
        lock_path,
        resource,
        owner,
        1,
        2,
        1,
        null,
    );
    defer lock.deinit(allocator);
    const payload = try renderLeaseLockAlloc(allocator, lock);
    defer allocator.free(payload);
    try tmp.dir.writeFile(Io.io(), .{
        .sub_path = "outside/repair.jsonl.lock",
        .data = payload,
    });
    var expected = [_]TransactionExpected{.{
        .path = resource,
        .digest = "",
        .sequence = 0,
    }};
    try writeTransactionRecord(
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
    try writeTextAtomic(allocator, counter_path, "1\n");

    var summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.SymLinkLoop,
        reclaimLegacyLease(
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
    try std.testing.expect(fileExists(lock_path));
}

test "recovery accumulation preserves a successful prefix across later errors" {
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
    const recoverable_dir = try std.fs.path.join(
        allocator,
        &.{
            transactions_dir,
            "dtx-1-00000000000000000000000000000014",
        },
    );
    defer allocator.free(recoverable_dir);
    try ensureDirectoryPathNoSymlinks(recoverable_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ recoverable_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    try writeTransactionRecord(
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
    try recoverAndCompactTransactionsAccumulating(
        allocator,
        transactions_dir,
        .{},
        &summary,
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expectEqual(@as(usize, 1), summary.transaction_count);

    const corrupt_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-invalid" },
    );
    defer allocator.free(corrupt_dir);
    try ensureDirectoryPathNoSymlinks(corrupt_dir);
    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverAndCompactTransactionsAccumulating(
            allocator,
            transactions_dir,
            .{},
            &summary,
        ),
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expectEqual(@as(usize, 1), summary.transaction_count);
}

test "recovery reports target publication before a later stage cleanup error" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
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
    const transaction_id = "dtx-1-00000000000000000000000000000015";
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
    const after = "{\"seq\":2}\n";
    try writeTextAtomic(allocator, target_path, before);
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

    var stage_dir = try std.Io.Dir.openDirAbsolute(
        Io.io(),
        transaction_dir,
        .{ .iterate = true },
    );
    defer stage_dir.close(Io.io());
    const writable = std.Io.File.Permissions.fromMode(0o755);
    const read_only = std.Io.File.Permissions.fromMode(0o555);
    try stage_dir.setPermissions(Io.io(), read_only);
    defer stage_dir.setPermissions(Io.io(), writable) catch |err| {
        std.debug.panic("restore transaction directory permissions: {s}", .{
            @errorName(err),
        });
    };

    var summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.AccessDenied,
        recoverTransactionWithOptionsAccumulating(
            allocator,
            transaction_dir,
            .{},
            &summary,
        ),
    );
    try std.testing.expect(summary.storage_mutated);
    const published = try tryReadForTest(target_path);
    defer allocator.free(published);
    try std.testing.expectEqualStrings(after, published);
}

test "recovery preserves nonempty compatibility-shaped files" {
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
    const transaction_id = "dtx-1-00000000000000000000000000000016";
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
    const after = "{\"seq\":2}\n";
    try writeTextAtomic(allocator, target_path, before);
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
    try writeTextAtomic(allocator, target_path, "{\"seq\":3}\n");
    const cas_path = try casLockPathAlloc(allocator, target_path);
    defer allocator.free(cas_path);
    try writeTextCreateNew(allocator, cas_path, "stale\n", .{});

    var summary: TransactionRecoverySummary = .{};
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsAccumulating(
            allocator,
            transactions_dir,
            .{},
            &summary,
        ),
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expect(fileExists(cas_path));
    try std.testing.expect(fileExists(transaction_dir));
}

test "recovery does not remove a live lease at a compatibility path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "events.jsonl" },
    );
    defer allocator.free(target_path);
    const lease_resource = try std.fmt.allocPrint(
        allocator,
        "{s}.cas",
        .{target_path},
    );
    defer allocator.free(lease_resource);
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ root, "fencing.counter" },
    );
    defer allocator.free(counter_path);
    var lease = try acquireLeaseLock(
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
        acquireTransactionRecoveryLocks(
            allocator,
            &expected,
            &storage_mutated,
        ),
    );
    try std.testing.expect(fileExists(lease.path));
}

test "recovery replaces empty stale compatibility locks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "events.jsonl" },
    );
    defer allocator.free(target_path);
    const cas_path = try casLockPathAlloc(allocator, target_path);
    defer allocator.free(cas_path);
    try writeTextCreateNew(allocator, cas_path, "", .{});
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = "",
        .sequence = 0,
    }};
    var storage_mutated = false;
    var locks = try acquireTransactionRecoveryLocks(
        allocator,
        &expected,
        &storage_mutated,
    );
    defer locks.deinit(allocator);
    try std.testing.expect(storage_mutated);
}

test "compatibility lock release batches parent durability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const first_path = try std.fs.path.join(
        allocator,
        &.{ root, "first.lock" },
    );
    defer allocator.free(first_path);
    const second_path = try std.fs.path.join(
        allocator,
        &.{ root, "second.lock" },
    );
    defer allocator.free(second_path);
    var locks = [_]LockFile{
        try acquireExclusiveLockPath(allocator, first_path),
        try acquireExclusiveLockPath(allocator, second_path),
    };
    var storage_mutated = false;
    try releaseCompatibilityLocksDurable(
        allocator,
        &locks,
        &storage_mutated,
    );
    try std.testing.expect(storage_mutated);
    try std.testing.expect(!fileExists(first_path));
    try std.testing.expect(!fileExists(second_path));
}

test "direct recovery reports target advisory creation as mutation" {
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
    const transaction_id = "dtx-1-00000000000000000000000000000042";
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
    const marker_path = try transactionCommitMarkerPathAlloc(
        allocator,
        transaction_dir,
    );
    defer allocator.free(marker_path);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "events.jsonl" },
    );
    defer allocator.free(target_path);
    const content = "{\"seq\":1}\n";
    try writeTextAtomic(allocator, target_path, content);
    const digest = try digestBytesAlloc(allocator, content);
    defer allocator.free(digest);
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = digest,
        .sequence = 1,
    }};
    var stage_buffer: [96]u8 = undefined;
    const staged_ref = try transactionStageName(
        &stage_buffer,
        transaction_id,
        0,
    );
    const writes = [_]TransactionWrite{.{
        .path = target_path,
        .staged_ref = staged_ref,
        .digest_after = digest,
        .sequence_after = 1,
    }};
    try writeTransactionRecord(
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
    try writeCommittedTransactionMarker(allocator, marker_path);
    const recovery_advisory = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, ".recovery.advisory" },
    );
    defer allocator.free(recovery_advisory);
    try writeTextCreateNew(allocator, recovery_advisory, "", .{});
    const target_advisory = try casAdvisoryPathAlloc(
        allocator,
        target_path,
    );
    defer allocator.free(target_advisory);
    try std.testing.expect(!fileExists(target_advisory));

    var receipt = try recoverTransaction(allocator, transaction_dir);
    defer receipt.deinit(allocator);
    try std.testing.expectEqual(
        RecoveryDecision.already_committed,
        receipt.decision,
    );
    try std.testing.expect(receipt.storage_mutated);
    try std.testing.expect(fileExists(target_advisory));
    const compatibility_path = try casLockPathAlloc(
        allocator,
        target_path,
    );
    defer allocator.free(compatibility_path);
    try std.testing.expect(!fileExists(compatibility_path));
}

test "prepared legacy journals preserve rollback-on-zero-published law" {
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
    const transaction_id = "dtx-2";
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
    const after = "{\"seq\":2}\n";
    try writeTextAtomic(allocator, target_path, before);
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
        recoverAndCompactTransactions(allocator, transactions_dir),
    );

    {
        var legacy_lease = try acquireLeaseLock(
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
            allocator,
            &legacy_lease,
            legacy_lease.fencing_token,
        ) catch |release_error| {
            std.debug.panic(
                "failed to release legacy lease: {s}",
                .{@errorName(release_error)},
            );
        };
        try std.testing.expectError(
            error.LockBusy,
            recoverAndCompactTransactionsWithOptions(
                allocator,
                transactions_dir,
                .{
                    .legacy_fencing_authority = .per_resource,
                },
            ),
        );
        try std.testing.expect(fileExists(transaction_dir));
        const unchanged = try tryReadForTest(target_path);
        defer allocator.free(unchanged);
        try std.testing.expectEqualStrings(before, unchanged);
    }

    const summary = try recoverAndCompactTransactionsWithOptions(
        allocator,
        transactions_dir,
        .{
            .legacy_fencing_authority = .per_resource,
        },
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expect(!fileExists(transaction_dir));
    const recovered = try tryReadForTest(target_path);
    defer allocator.free(recovered);
    try std.testing.expectEqualStrings(before, recovered);
}

test "hashed transaction ids retain legacy stage and decision compatibility" {
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
    const transaction_id = "dtx-2-00000000000000000000000000000002";
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
    const after = "{\"seq\":2}\n";
    try writeTextAtomic(allocator, target_path, before);
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
        allocator,
        transactions_dir,
        .{
            .legacy_fencing_authority = .per_resource,
        },
    );
    try std.testing.expect(summary.storage_mutated);
    try std.testing.expect(!fileExists(transaction_dir));
    const recovered = try tryReadForTest(target_path);
    defer allocator.free(recovered);
    try std.testing.expectEqualStrings(before, recovered);
}

test "legacy prepared journals quarantine mixed published prefixes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-41" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const first_path = try std.fs.path.join(
        allocator,
        &.{ root, "first.jsonl" },
    );
    defer allocator.free(first_path);
    const second_path = try std.fs.path.join(
        allocator,
        &.{ root, "second.jsonl" },
    );
    defer allocator.free(second_path);
    try writeTextAtomic(allocator, first_path, "{\"seq\":2}\n");
    try writeTextAtomic(allocator, second_path, "{\"seq\":1}\n");
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

    var status = try inspectTransaction(allocator, transaction_dir);
    defer status.deinit(allocator);
    try std.testing.expectEqual(
        RecoveryDecision.manual_recovery_required,
        status.decision,
    );
    try std.testing.expectEqualStrings(
        "legacy-mixed-published-digests",
        status.reason,
    );
}

test "legacy rollback does not reacquire expected-only guards" {
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
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-5" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const source_path = try std.fs.path.join(
        allocator,
        &.{ root, "a-source.json" },
    );
    defer allocator.free(source_path);
    const binding_path = try std.fs.path.join(
        allocator,
        &.{ root, "z-binding.json" },
    );
    defer allocator.free(binding_path);
    const source_before = "{\"source\":1}\n";
    const source_after = "{\"source\":2}\n";
    const binding_before = "{\"binding\":1}\n";
    const binding_after = "{\"binding\":2}\n";
    try writeTextAtomic(allocator, source_path, source_before);
    try writeTextAtomic(allocator, binding_path, binding_before);
    const source_digest = try digestBytesAlloc(allocator, source_before);
    defer allocator.free(source_digest);
    const binding_before_digest = try digestBytesAlloc(
        allocator,
        binding_before,
    );
    defer allocator.free(binding_before_digest);
    const binding_after_digest = try digestBytesAlloc(
        allocator,
        binding_after,
    );
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
    const staged_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "write-1.staged" },
    );
    defer allocator.free(staged_path);
    try writeTextCreateNew(allocator, staged_path, binding_after, .{});
    try writeTransactionRecord(
        allocator,
        record_path,
        "dtx-5",
        .{
            .process_id = 912,
            .session_id = "expected-only-preflight",
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
    try writeTextAtomic(allocator, source_path, source_after);

    const summary = try recoverAndCompactTransactionsWithOptions(
        allocator,
        transactions_dir,
        .{
            .legacy_fencing_authority = .per_resource,
        },
    );
    try std.testing.expectEqual(@as(usize, 1), summary.transaction_count);
    try std.testing.expect(!fileExists(transaction_dir));
    const unchanged = try tryReadForTest(binding_path);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(binding_before, unchanged);
}

test "committed recovery does not revalidate released expected-only guards" {
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
    const transaction_id = "dtx-6-00000000000000000000000000000001";
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
    const source_path = try std.fs.path.join(
        allocator,
        &.{ root, "source.json" },
    );
    defer allocator.free(source_path);
    const binding_path = try std.fs.path.join(
        allocator,
        &.{ root, "binding.json" },
    );
    defer allocator.free(binding_path);
    const source_before = "{\"source\":1}\n";
    const source_after = "{\"source\":2}\n";
    const binding_before = "{\"binding\":1}\n";
    const binding_after = "{\"binding\":2}\n";
    try writeTextAtomic(allocator, source_path, source_before);
    try writeTextAtomic(allocator, binding_path, binding_before);
    const source_digest = try digestBytesAlloc(allocator, source_before);
    defer allocator.free(source_digest);
    const binding_before_digest = try digestBytesAlloc(
        allocator,
        binding_before,
    );
    defer allocator.free(binding_before_digest);
    const binding_after_digest = try digestBytesAlloc(
        allocator,
        binding_after,
    );
    defer allocator.free(binding_after_digest);
    const expected = [_]TransactionExpected{
        .{ .path = binding_path, .digest = binding_before_digest, .sequence = 0 },
        .{ .path = source_path, .digest = source_digest, .sequence = 0 },
    };
    const staged_ref = try transactionStageNameAlloc(
        allocator,
        transaction_id,
        0,
    );
    defer allocator.free(staged_ref);
    const writes = [_]TransactionWrite{.{
        .path = binding_path,
        .staged_ref = staged_ref,
        .digest_after = binding_after_digest,
        .sequence_after = 0,
    }};
    try writeTransactionRecord(
        allocator,
        record_path,
        transaction_id,
        .{
            .process_id = 916,
            .session_id = "committed-guard-release",
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
    var incomplete = try inspectTransaction(allocator, transaction_dir);
    defer incomplete.deinit(allocator);
    try std.testing.expectEqual(
        RecoveryDecision.manual_recovery_required,
        incomplete.decision,
    );
    try writeTextAtomic(allocator, binding_path, binding_after);
    try writeTextAtomic(allocator, source_path, source_after);

    try recoverAndCompactTransactions(
        allocator,
        transactions_dir,
    );
    try std.testing.expect(!fileExists(transaction_dir));
    const binding = try tryReadForTest(binding_path);
    defer allocator.free(binding);
    try std.testing.expectEqualStrings(binding_after, binding);

    const prepared_id = "dtx-6-00000000000000000000000000000002";
    const prepared_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, prepared_id },
    );
    defer allocator.free(prepared_dir);
    try ensureDirectoryPathNoSymlinks(prepared_dir);
    const prepared_record = try std.fs.path.join(
        allocator,
        &.{ prepared_dir, "transaction.json" },
    );
    defer allocator.free(prepared_record);
    const prepared_staged_ref = try transactionStageNameAlloc(
        allocator,
        prepared_id,
        0,
    );
    defer allocator.free(prepared_staged_ref);
    const prepared_writes = [_]TransactionWrite{.{
        .path = binding_path,
        .staged_ref = prepared_staged_ref,
        .digest_after = binding_after_digest,
        .sequence_after = 0,
    }};
    try writeTransactionRecord(
        allocator,
        prepared_record,
        prepared_id,
        .{
            .process_id = 917,
            .session_id = "prepared-guard-release",
            .executor = "test",
        },
        .prepared,
        &expected,
        &prepared_writes,
        &.{},
        1,
        2,
        true,
    );
    var prepared = try inspectTransaction(allocator, prepared_dir);
    defer prepared.deinit(allocator);
    try std.testing.expectEqual(
        RecoveryDecision.finish_commit,
        prepared.decision,
    );

    try recoverAndCompactTransactions(
        allocator,
        transactions_dir,
    );
    try std.testing.expect(!fileExists(prepared_dir));
}

test "legacy recovery cannot target its shared fencing authority" {
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
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-7" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ root, "fencing.counter" },
    );
    defer allocator.free(counter_path);
    const counter_before = "10\n";
    const counter_after = "0\n";
    try writeTextAtomic(allocator, counter_path, counter_before);
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
    const staged_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "write-0.staged" },
    );
    defer allocator.free(staged_path);
    try writeTextCreateNew(allocator, staged_path, counter_after, .{});
    try writeTransactionRecord(
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
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{
                    .shared = counter_path,
                },
            },
        ),
    );
    const counter = try tryReadForTest(counter_path);
    defer allocator.free(counter);
    try std.testing.expectEqualStrings(counter_before, counter);
}

test "legacy recovery rejects duplicate write targets before publishing" {
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
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-6" },
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
    const after_a = "{\"seq\":2}\n";
    const after_b = "{\"seq\":3}\n";
    try writeTextAtomic(allocator, target_path, before);
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
    const staged_a = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "write-0.staged" },
    );
    defer allocator.free(staged_a);
    const staged_b = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "write-1.staged" },
    );
    defer allocator.free(staged_b);
    try writeTextCreateNew(allocator, staged_a, after_a, .{});
    try writeTextCreateNew(allocator, staged_b, after_b, .{});
    try writeTransactionRecord(
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

    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverAndCompactTransactionsWithOptions(
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

test "legacy recovery rejects the transaction-control namespace" {
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
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-7" },
    );
    defer allocator.free(transaction_dir);
    const sibling_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-8" },
    );
    defer allocator.free(sibling_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    try ensureDirectoryPathNoSymlinks(sibling_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const sibling_record = try std.fs.path.join(
        allocator,
        &.{ sibling_dir, "transaction.json" },
    );
    defer allocator.free(sibling_record);
    const before = "sibling-journal\n";
    const after = "corrupted-journal\n";
    try writeTextAtomic(allocator, sibling_record, before);
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
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-4" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const target_a = try std.fs.path.join(
        allocator,
        &.{ root, "a.jsonl" },
    );
    defer allocator.free(target_a);
    const target_b = try std.fs.path.join(
        allocator,
        &.{ root, "b.jsonl" },
    );
    defer allocator.free(target_b);
    const before = "{\"seq\":1}\n";
    try writeTextAtomic(allocator, target_a, before);
    try writeTextAtomic(allocator, target_b, before);
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
    try std.Io.Dir.deleteFileAbsolute(Io.io(), target_b);

    var status = try inspectTransaction(allocator, transaction_dir);
    defer status.deinit(allocator);
    try std.testing.expectEqual(
        RecoveryDecision.manual_recovery_required,
        status.decision,
    );
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverAndCompactTransactionsWithOptions(
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .per_resource,
            },
        ),
    );
    try std.testing.expect(fileExists(transaction_dir));
    const unchanged = try tryReadForTest(target_a);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(before, unchanged);
}

test "legacy journals reject filesystem aliases into their directory" {
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
    const transaction_id = "dtx-3";
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
    const transaction_alias = try std.fs.path.join(
        allocator,
        &.{ root, "transaction-alias" },
    );
    defer allocator.free(transaction_alias);
    try std.Io.Dir.cwd().symLink(
        Io.io(),
        transaction_dir,
        transaction_alias,
        .{ .is_directory = true },
    );
    const target_path = try std.fs.path.join(
        allocator,
        &.{ transaction_alias, "victim.jsonl" },
    );
    defer allocator.free(target_path);
    const actual_target_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "victim.jsonl" },
    );
    defer allocator.free(actual_target_path);
    const staged_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "write-0.staged" },
    );
    defer allocator.free(staged_path);
    const before = "{\"seq\":1}\n";
    const after = "{\"seq\":2}\n";
    try writeTextAtomic(allocator, actual_target_path, before);
    try writeTextAtomic(allocator, staged_path, after);
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

    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverAndCompactTransactionsWithOptions(
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .per_resource,
            },
        ),
    );
    try std.testing.expect(fileExists(transaction_dir));
    const unchanged = try tryReadForTest(target_path);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(before, unchanged);
}

test "committed current journals retain strict scope and writer locks" {
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
    const transaction_id = "dtx-3-00000000000000000000000000000003";
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
    const commit_marker_path = try transactionCommitMarkerPathAlloc(
        allocator,
        transaction_dir,
    );
    defer allocator.free(commit_marker_path);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "events.jsonl" },
    );
    defer allocator.free(target_path);
    const content = "{\"seq\":1}\n";
    try writeTextAtomic(allocator, target_path, content);
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
    try writeCommittedTransactionMarker(allocator, commit_marker_path);
    try std.testing.expectError(
        error.TransactionCorrupt,
        recoverTransaction(allocator, transaction_dir),
    );

    var stage_name_buffer: [96]u8 = undefined;
    writes[0].staged_ref = try transactionStageName(
        &stage_name_buffer,
        transaction_id,
        0,
    );
    try writeTransactionRecord(
        allocator,
        record_path,
        transaction_id,
        owner,
        .committed,
        &expected,
        &writes,
        &.{},
        1,
        3,
        false,
    );
    var live_writer = try acquireCasAdvisoryLock(allocator, target_path);
    try std.testing.expectError(
        error.LockBusy,
        recoverTransaction(allocator, transaction_dir),
    );
    live_writer.close(Io.io());

    try recoverAndCompactTransactions(allocator, transactions_dir);
    try std.testing.expect(!fileExists(transaction_dir));
}

test "journal lock excludes live current recordless reclamation" {
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
    try ensureDirectoryPathNoSymlinks(transactions_dir);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{
            transactions_dir,
            "dtx-1-00000000000000000000000000000007",
        },
    );
    defer allocator.free(transaction_dir);
    var live_journal = try acquireTransactionJournalLock(
        allocator,
        transactions_dir,
        null,
    );
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    try std.testing.expectError(
        error.LockBusy,
        recoverAndCompactTransactions(allocator, transactions_dir),
    );
    try std.testing.expect(fileExists(transaction_dir));
    live_journal.close(Io.io());

    try recoverAndCompactTransactions(allocator, transactions_dir);
    try std.testing.expect(!fileExists(transaction_dir));
}

test "recovered transaction compaction is idempotent after disappearance" {
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
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-35" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    var held_recovery = try acquireTransactionRecoveryLock(
        allocator,
        transactions_dir,
        null,
    );
    try std.testing.expectError(
        error.LockBusy,
        recoverAndCompactTransactionsWithOptions(
            allocator,
            transactions_dir,
            .{
                .legacy_fencing_authority = .{
                    .shared = "/unused/fencing.counter",
                },
            },
        ),
    );
    held_recovery.close(Io.io());
    var transactions = try std.Io.Dir.openDirAbsolute(
        Io.io(),
        transactions_dir,
        .{ .follow_symlinks = false },
    );
    defer transactions.close(Io.io());

    var first_mutated = false;
    try compactRecoveredTransaction(
        allocator,
        transactions_dir,
        transaction_dir,
        &transactions,
        &first_mutated,
    );
    try std.testing.expect(first_mutated);
    try std.testing.expect(!fileExists(transaction_dir));

    var second_mutated = false;
    try compactRecoveredTransaction(
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
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope(
            std.testing.allocator,
            "/repo/.ledger",
            "/repo/.ledger/transactions/dtx-1-00000000000000000000000000000002",
            .{
                .transaction_id = transaction_id,
                .owner = owner,
                .state = .preparing,
                .expected = &expected,
                .writes = &invalid,
                .created_at = "1",
                .updated_at = "2",
            },
            .current,
        ),
    );
    invalid[0].staged_ref = "write-0.staged";
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope(
            std.testing.allocator,
            "/repo/.ledger",
            "/repo/.ledger/transactions/dtx-1-00000000000000000000000000000002",
            .{
                .transaction_id = transaction_id,
                .owner = owner,
                .state = .preparing,
                .expected = &expected,
                .writes = &invalid,
                .created_at = "1",
                .updated_at = "2",
            },
            .current,
        ),
    );
    var legacy_stage_buffer: [96]u8 = undefined;
    invalid[0].staged_ref = try transactionStageName(
        &legacy_stage_buffer,
        "dtx-1",
        0,
    );
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope(
            std.testing.allocator,
            "/repo/.ledger",
            "/repo/.ledger/transactions/dtx-1",
            .{
                .transaction_id = "dtx-1",
                .owner = owner,
                .state = .preparing,
                .expected = &expected,
                .writes = &invalid,
                .created_at = "1",
                .updated_at = "2",
            },
            .current,
        ),
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

test "legacy transaction records reject impossible preparing state" {
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope(
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

test "current journals enforce the new row bound without rejecting legacy input" {
    try validateTransactionRowBounds(
        true,
        transaction_recovery_max_rows,
        transaction_recovery_max_rows,
        transaction_recovery_max_rows,
    );
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRowBounds(
            true,
            transaction_recovery_max_rows + 1,
            0,
            0,
        ),
    );
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRowBounds(
            true,
            0,
            transaction_recovery_max_rows + 1,
            0,
        ),
    );
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRowBounds(
            true,
            0,
            0,
            transaction_recovery_max_rows + 1,
        ),
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
    try std.testing.expect(
        recoveryRecordCustodyEqual(preliminary, custodied),
    );
    var regressed = custodied;
    regressed.state = .preparing;
    try std.testing.expect(
        !recoveryRecordCustodyEqual(custodied, regressed),
    );
    regressed.state = .aborted;
    try std.testing.expect(
        !recoveryRecordCustodyEqual(custodied, regressed),
    );
}

test "custodied recovery snapshot re-reads mutable journal state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_id = "dtx-1-00000000000000000000000000000070";
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", transaction_id },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "transaction.json" },
    );
    defer allocator.free(record_path);
    const owner: Owner = .{
        .process_id = 970,
        .session_id = "custodied-state",
        .executor = "test",
    };
    try writeCurrentTransactionRecord(
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
    const preliminary = try parseTransactionRecord(allocator, record_path);
    defer preliminary.deinit(allocator);
    const format = try transactionRecordFormat(allocator, preliminary);
    try writeCurrentTransactionRecord(
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
        allocator,
        root,
        transaction_dir,
        record_path,
        preliminary,
        format,
    );
    defer custodied.deinit(allocator);
    try std.testing.expectEqual(
        TransactionState.prepared,
        custodied.state,
    );
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
            .path = try std.fmt.allocPrint(
                allocator,
                "{s}/target-{d}.jsonl",
                .{ root, count },
            ),
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
    const transaction_id = "dtx-1-00000000000000000000000000000064";
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
    const expected = try makePrelimitExpectedRows(allocator, root);
    defer deinitPrelimitExpectedRows(allocator, expected);
    try writeTransactionRecord(
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
    const parsed = try parseTransactionRecord(allocator, record_path);
    defer parsed.deinit(allocator);
    try std.testing.expect(!parsed.bounded_rows);
    const rewritten = try renderParsedTransactionRecordAlloc(
        allocator,
        parsed,
        .committed,
    );
    defer allocator.free(rewritten);
    try std.testing.expect(
        std.mem.indexOf(u8, rewritten, "\"recovery_profile\"") == null,
    );
    var status = try inspectTransaction(allocator, transaction_dir);
    defer status.deinit(allocator);
    try std.testing.expectEqual(
        RecoveryDecision.roll_back_unpublished,
        status.decision,
    );
    try std.testing.expectError(
        error.TransactionRecoveryRequired,
        recoverTransaction(allocator, transaction_dir),
    );
}

test "legacy format and lock witnesses survive recovery record rewrites" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const record_path = try std.fs.path.join(
        allocator,
        &.{ root, "transaction.json" },
    );
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
    const rewritten = try renderParsedTransactionRecordAlloc(
        allocator,
        original,
        .committed,
    );
    defer allocator.free(rewritten);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            rewritten,
            "\"journal_format\":\"legacy\"",
        ) != null,
    );
    try writeTextAtomic(allocator, record_path, rewritten);
    const reparsed = try parseTransactionRecord(allocator, record_path);
    defer reparsed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), reparsed.embedded_locks.len);
    try std.testing.expectEqualStrings(
        "/repo/events.jsonl",
        reparsed.embedded_locks[0].resource,
    );
    try std.testing.expectEqual(
        TransactionRecordFormat.legacy,
        try transactionRecordFormat(std.testing.allocator, reparsed),
    );
}

test "recovery record rewrites reject output above the parser byte limit" {
    const allocator = std.testing.allocator;
    const oversized = try allocator.alloc(
        u8,
        transaction_record_max_bytes,
    );
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

test "legacy journals bind embedded lock witnesses to expected targets" {
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    if (try directoryNameIsCaseInsensitive(
        allocator,
        root,
        "Probe",
    )) {
        return error.SkipZigTest;
    }
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-30" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const upper_path = try std.fs.path.join(
        allocator,
        &.{ root, "A.jsonl" },
    );
    defer allocator.free(upper_path);
    const lower_path = try std.fs.path.join(
        allocator,
        &.{ root, "a.jsonl" },
    );
    defer allocator.free(lower_path);
    var expected = [_]TransactionExpected{
        .{ .path = upper_path, .digest = "", .sequence = 0 },
        .{ .path = lower_path, .digest = "", .sequence = 0 },
    };
    try validateTransactionRecordScope(
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-31" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const nested = try std.fs.path.join(allocator, &.{ root, "nested" });
    defer allocator.free(nested);
    try ensureDirectoryPathNoSymlinks(nested);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "target.jsonl" },
    );
    defer allocator.free(target_path);
    const counter_alias = try std.fs.path.join(
        allocator,
        &.{ nested, "..", "target.jsonl" },
    );
    defer allocator.free(counter_alias);
    var expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = "",
        .sequence = 0,
    }};
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateLegacyFencingAuthorityScope(
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
    try std.testing.expect(!fileExists(target_path));
}

test "legacy fencing authority rejects non-adjacent target ancestors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-38" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const target_ancestor = try std.fs.path.join(
        allocator,
        &.{ root, "a" },
    );
    defer allocator.free(target_ancestor);
    const sort_interloper = try std.fs.path.join(
        allocator,
        &.{ root, "a-guard" },
    );
    defer allocator.free(sort_interloper);
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ target_ancestor, "counter" },
    );
    defer allocator.free(counter_path);
    var expected = [_]TransactionExpected{
        .{ .path = target_ancestor, .digest = "", .sequence = 0 },
        .{ .path = sort_interloper, .digest = "", .sequence = 0 },
    };
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateLegacyFencingAuthorityScope(
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-39" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const composed_path = try std.fs.path.join(
        allocator,
        &.{ root, "\xc3\xa9.jsonl" },
    );
    defer allocator.free(composed_path);
    const decomposed_alias = try std.fs.path.join(
        allocator,
        &.{ root, "e\xcc\x81.jsonl" },
    );
    defer allocator.free(decomposed_alias);
    try writeTextAtomic(allocator, composed_path, "7\n");
    if (!fileExists(decomposed_alias)) return error.SkipZigTest;
    const authority_lock = try std.fmt.allocPrint(
        allocator,
        "{s}.lock",
        .{decomposed_alias},
    );
    defer allocator.free(authority_lock);
    try writeTextAtomic(allocator, authority_lock, "lock\n");
    var expected = [_]TransactionExpected{.{
        .path = composed_path,
        .digest = "",
        .sequence = 0,
    }};
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateLegacyFencingAuthorityScope(
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-33" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "target.jsonl" },
    );
    defer allocator.free(target_path);
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ root, "fencing.counter" },
    );
    defer allocator.free(counter_path);
    const lease_path = try lockPathAlloc(allocator, target_path);
    defer allocator.free(lease_path);
    const cas_path = try casLockPathAlloc(allocator, target_path);
    defer allocator.free(cas_path);
    const advisory_path = try casAdvisoryPathAlloc(
        allocator,
        target_path,
    );
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    if (!try directoryNameIsCaseInsensitive(
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
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, "dtx-61" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const target = try std.fs.path.join(
        allocator,
        &.{ root, "caf\xc3\xa9.jsonl" },
    );
    defer allocator.free(target);
    try writeTextAtomic(allocator, target, "{\"sequence\":1}\n");
    var expected = [_]TransactionExpected{.{
        .path = target,
        .digest = "",
        .sequence = 0,
    }};
    try validateLegacyFencingAuthorityScope(
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-40" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const first_target = try std.fs.path.join(
        allocator,
        &.{ root, "item" },
    );
    defer allocator.free(first_target);
    const second_target = try std.fmt.allocPrint(
        allocator,
        "{s}.cas",
        .{first_target},
    );
    defer allocator.free(second_target);
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ root, "fencing.counter" },
    );
    defer allocator.free(counter_path);
    var expected = [_]TransactionExpected{
        .{ .path = first_target, .digest = "", .sequence = 0 },
        .{ .path = second_target, .digest = "", .sequence = 0 },
    };
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateLegacyFencingAuthorityScope(
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-34" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "target.jsonl" },
    );
    defer allocator.free(target_path);
    const lease_path = try lockPathAlloc(allocator, target_path);
    defer allocator.free(lease_path);
    const cas_path = try casLockPathAlloc(allocator, target_path);
    defer allocator.free(cas_path);
    const advisory_path = try casAdvisoryPathAlloc(
        allocator,
        target_path,
    );
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
        try writeTextAtomic(allocator, control_path, "7\n");
        try std.testing.expectError(
            error.TransactionCorrupt,
            validateLegacyFencingAuthorityScope(
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-36" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ root, "fencing.counter" },
    );
    defer allocator.free(counter_path);
    const expected = try allocator.alloc(
        TransactionExpected,
        transaction_recovery_max_rows,
    );
    var expected_count: usize = 0;
    defer {
        for (expected[0..expected_count]) |row| allocator.free(row.path);
        allocator.free(expected);
    }
    for (expected, 0..) |*row, index| {
        row.* = .{
            .path = try std.fmt.allocPrint(
                allocator,
                "{s}/target-{d}.jsonl",
                .{ root, index },
            ),
            .digest = "",
            .sequence = 0,
        };
        expected_count += 1;
    }
    const started_ms = clockMillis(.awake);
    try validateLegacyFencingAuthorityScope(
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
    try std.testing.expect(elapsedMillis(started_ms) < 30_000);
}

test "legacy fencing authority cannot regress embedded witness tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ root, "transactions", "dtx-32" },
    );
    defer allocator.free(transaction_dir);
    try ensureDirectoryPathNoSymlinks(transaction_dir);
    const target_path = try std.fs.path.join(
        allocator,
        &.{ root, "target.jsonl" },
    );
    defer allocator.free(target_path);
    const counter_path = try std.fs.path.join(
        allocator,
        &.{ root, "fencing.counter" },
    );
    defer allocator.free(counter_path);
    try writeTextAtomic(allocator, counter_path, "9\n");
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
    const transaction_id = "dtx-1-00000000000000000000000000000013";
    var expected = [_]TransactionExpected{.{
        .path = "/repo/foo",
        .digest = "",
        .sequence = 0,
    }};
    var stage_buffer: [96]u8 = undefined;
    const staged_ref = try transactionStageName(
        &stage_buffer,
        transaction_id,
        0,
    );
    var writes = [_]TransactionWrite{.{
        .path = "/repo/FOO",
        .staged_ref = staged_ref,
        .digest_after = "",
        .sequence_after = 0,
    }};
    try std.testing.expectError(
        error.TransactionCorrupt,
        validateTransactionRecordScope(
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
    const directory_id = "dtx-1-00000000000000000000000000000008";
    const claimed_id = "dtx-1-00000000000000000000000000000009";
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ transactions_dir, directory_id },
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
    const staged_ref = try transactionStageNameAlloc(
        allocator,
        claimed_id,
        0,
    );
    defer allocator.free(staged_ref);
    const staged_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, staged_ref },
    );
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
    try writeTextCreateNew(allocator, staged_path, "{\"seq\":1}\n", .{});

    try std.testing.expectError(
        error.TransactionCorrupt,
        inspectTransaction(allocator, transaction_dir),
    );
    try std.testing.expect(fileExists(staged_path));
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

test "CAS read custody excludes writers across a canonical path pair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const binding_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".ledger", ".bindings", "slot.jsonl" },
    );
    defer std.testing.allocator.free(binding_path);
    const slot_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".ledger", "example", "events.jsonl" },
    );
    defer std.testing.allocator.free(slot_path);
    try ensureParentPath(binding_path);
    try ensureParentPath(slot_path);

    var binding_writer = try acquireCasAdvisoryLock(
        std.testing.allocator,
        binding_path,
    );
    binding_writer.close(Io.io());
    var slot_writer = try acquireCasAdvisoryLock(
        std.testing.allocator,
        slot_path,
    );
    slot_writer.close(Io.io());

    var read_custody = try acquireCasReadLockPair(
        std.testing.allocator,
        slot_path,
        binding_path,
    );
    defer read_custody.deinit();
    try std.testing.expectError(
        error.LockBusy,
        acquireCasAdvisoryLock(std.testing.allocator, binding_path),
    );
    try std.testing.expectError(
        error.LockBusy,
        acquireCasAdvisoryLock(std.testing.allocator, slot_path),
    );
}

test "CAS read custody holds the existing member of a partial advisory pair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const binding_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".ledger", ".bindings", "slot.jsonl" },
    );
    defer std.testing.allocator.free(binding_path);
    const slot_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".ledger", "example", "events.jsonl" },
    );
    defer std.testing.allocator.free(slot_path);
    try ensureParentPath(binding_path);
    try ensureParentPath(slot_path);
    var binding_writer = try acquireCasAdvisoryLock(
        std.testing.allocator,
        binding_path,
    );
    binding_writer.close(Io.io());

    var read_custody = try acquireCasReadLockPair(
        std.testing.allocator,
        slot_path,
        binding_path,
    );
    defer read_custody.deinit();
    try std.testing.expectEqual(@as(u2, 1), read_custody.count);
    try std.testing.expectError(
        error.LockBusy,
        acquireCasAdvisoryLock(std.testing.allocator, binding_path),
    );
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
    const case_insensitive = try directoryNameIsCaseInsensitive(
        std.testing.allocator,
        root,
        "Events.jsonl",
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
    if (try directoryNameIsCaseInsensitive(
        std.testing.allocator,
        root,
        "Probe",
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

test "EventStore case probe excludes child symlink destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    if (try directoryNameIsCaseInsensitive(
        std.testing.allocator,
        root,
        "Probe",
    )) return;

    const witness_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "Witness" },
    );
    defer std.testing.allocator.free(witness_path);
    try writeTextAtomic(
        std.testing.allocator,
        witness_path,
        "case-sensitive\n",
    );
    try tmp.dir.symLink(Io.io(), "Witness", "witness", .{});
    try std.testing.expect(
        !try directoryNameIsCaseInsensitive(
            std.testing.allocator,
            root,
            "Witness",
        ),
    );
}

test "EventStore case probe targets the requested witness" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        Io.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);

    var name_buffer: [32]u8 = undefined;
    for (0..1025) |index| {
        const name = try std.fmt.bufPrint(
            &name_buffer,
            "{d}",
            .{index},
        );
        var file = try tmp.dir.createFile(
            Io.io(),
            name,
            .{ .exclusive = true },
        );
        file.close(Io.io());
    }
    try std.testing.expectEqual(
        @as(?bool, null),
        try targetNameCaseSensitivity(
            std.testing.allocator,
            root,
            "Events.jsonl",
        ),
    );
}

test "EventStore inconclusive case cache rechecks the target witness" {
    directory_case_cache = .{};
    defer directory_case_cache = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", allocator);
    defer allocator.free(root);
    var witness = try tmp.dir.createFile(
        Io.io(),
        "Events.jsonl",
        .{ .exclusive = true },
    );
    witness.close(Io.io());
    const refreshed = (try hostObjectIdentity(root)) orelse
        return error.SkipZigTest;
    directory_case_cache.put(refreshed, .scan_inconclusive);
    _ = try directoryNameIsCaseInsensitive(
        allocator,
        root,
        "Events.jsonl",
    );
    try std.testing.expect(
        directory_case_cache.get(refreshed).? == .direct,
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
    const staged_ref = try transactionRecordStageNameAlloc(
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
    const transaction_dir = std.fs.path.dirname(record_path) orelse
        return error.InvalidPath;
    const staged_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, staged_ref },
    );
    defer allocator.free(staged_path);
    try writeTextCreateNew(allocator, staged_path, after, .{});
    try writeTransactionRecord(allocator, record_path, transaction_id, owner, .prepared, &expected, &writes, &.{}, 1, 2, true);
}

fn writeCommittedRecoveryJournalForTest(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
    transaction_id: []const u8,
    target_path: []const u8,
    content: []const u8,
) !void {
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
    const digest = try digestBytesAlloc(allocator, content);
    defer allocator.free(digest);
    const expected = [_]TransactionExpected{.{
        .path = target_path,
        .digest = digest,
        .sequence = 1,
    }};
    const staged_ref = try transactionRecordStageNameAlloc(
        allocator,
        transaction_id,
        0,
    );
    defer allocator.free(staged_ref);
    const writes = [_]TransactionWrite{.{
        .path = target_path,
        .staged_ref = staged_ref,
        .digest_after = digest,
        .sequence_after = 1,
    }};
    try writeTransactionRecord(
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
    const staged_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, staged_ref },
    );
    defer allocator.free(staged_path);
    try writeTextCreateNew(allocator, staged_path, after, .{});
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

fn writePreparedTwoWriteRecordForTest(
    allocator: std.mem.Allocator,
    record_path: []const u8,
    transaction_id: []const u8,
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
    const staged_ref_a = try transactionRecordStageNameAlloc(
        allocator,
        transaction_id,
        0,
    );
    defer allocator.free(staged_ref_a);
    const staged_ref_b = try transactionRecordStageNameAlloc(
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
    const transaction_dir = std.fs.path.dirname(record_path) orelse
        return error.InvalidPath;
    const staged_a = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, staged_ref_a },
    );
    defer allocator.free(staged_a);
    const staged_b = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, staged_ref_b },
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

fn transactionRecordStageNameAlloc(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    write_index: usize,
) ![]u8 {
    if (isGeneratedTransactionId(transaction_id)) {
        return transactionStageNameAlloc(
            allocator,
            transaction_id,
            write_index,
        );
    }
    if (!isLegacyTransactionId(transaction_id)) {
        return error.TransactionCorrupt;
    }
    var buffer: [96]u8 = undefined;
    return allocator.dupe(
        u8,
        try legacyTransactionStageName(&buffer, write_index),
    );
}

fn tryReadForTest(path: []const u8) ![]u8 {
    return try readFileAlloc(std.testing.allocator, path, 4096);
}
