const std = @import("std");
const event = @import("event.zig");
const EventAppendExpectation = event.EventAppendExpectation;
const EventAppendReceipt = event.EventAppendReceipt;
const EventRecordVisitor = event.EventRecordVisitor;
const EventScanSummary = event.EventScanSummary;
const EventSnapshot = event.EventSnapshot;
const EventStore = event.EventStore;
const EventStoreExclusive = event.EventStoreExclusive;
const SnapshotCollector = event.SnapshotCollector;
const eventAppendReceipt = event.eventAppendReceipt;
const ignoreEventRecord = event.ignoreEventRecord;
const renderEventRecordsAlloc = event.renderEventRecordsAlloc;
const scanEventReader = event.scanEventReader;
const validateEventAppendFits = event.validateEventAppendFits;
const validateEventExpectation = event.validateEventExpectation;
const validateEventPayload = event.validateEventPayload;
const fs_authority = @import("fs_authority.zig");
const Fs = fs_authority.Fs;
const filesystem = @import("filesystem.zig");
const EventStoreExclusiveLock = filesystem.EventStoreExclusiveLock;
const acquireEventStoreExclusiveLock = filesystem.acquireEventStoreExclusiveLock;
const appendLineAtomicPrepared = filesystem.appendLineAtomicPrepared;
const ensureLockSidecarGitignored = filesystem.ensureLockSidecarGitignored;
const scanJsonlEventStore = filesystem.scanJsonlEventStore;
const writeTextAtomic = filesystem.writeTextAtomic;

/// Stable construction surface for repo-local persistent event stores.
/// The locator is a logical store identity; the current compatibility adapter
/// interprets it as a JSONL path. Source callers depend only on EventStore.
pub const PersistentEventStore = struct {
    adapter: JsonlEventStore,

    pub fn init(fs: Fs, locator: []const u8) PersistentEventStore {
        return .{ .adapter = JsonlEventStore.init(fs, locator) };
    }

    pub fn eventStore(self: *PersistentEventStore) EventStore {
        return self.adapter.eventStore();
    }
};

pub const JsonlEventStore = struct {
    path: []const u8,
    fs: Fs,
    scan_active: bool = false,
    mutation_admission_checked: bool = false,

    pub fn init(fs: Fs, path: []const u8) JsonlEventStore {
        return .{ .path = path, .fs = fs };
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
        const fs = self.fs;
        if (self.scan_active) return error.EventStoreBusy;
        self.scan_active = true;
        defer self.scan_active = false;
        return scanJsonlEventStore(
            fs,
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
        const fs = cast(context).fs;
        const self = cast(context);
        if (self.scan_active) return error.EventStoreBusy;
        if (!self.mutation_admission_checked) {
            try ensureLockSidecarGitignored(fs, allocator, self.path);
            self.mutation_admission_checked = true;
        }
        const exclusive = try allocator.create(ExclusiveContext);
        errdefer allocator.destroy(exclusive);
        const lock = acquireEventStoreExclusiveLock(
            fs,
            allocator,
            self.path,
        ) catch |err| switch (err) {
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

    fn exclusiveSnapshot(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) !EventSnapshot {
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
        const fs = exclusiveCast(context).store.fs;
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
        return (try appendLineAtomicPrepared(
            fs,
            allocator,
            exclusive.store.path,
            payload,
            max_bytes,
            before,
        )).?;
    }

    fn exclusiveReplace(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        records: []const []const u8,
        expectation: EventAppendExpectation,
        max_bytes: usize,
    ) !EventAppendReceipt {
        const fs = exclusiveCast(context).store.fs;
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
        var reader: std.Io.Reader = .fixed(text);
        var after = try scanEventReader(
            allocator,
            exclusive.store.path,
            max_bytes,
            visitor,
            &reader,
        );
        defer after.deinit(allocator);
        var receipt = try eventAppendReceipt(allocator, before, after);
        errdefer receipt.deinit(allocator);
        try writeTextAtomic(fs, allocator, exclusive.store.path, text);
        return receipt;
    }

    fn releaseExclusive(context: *anyopaque) void {
        const exclusive = exclusiveCast(context);
        exclusive.lock.release();
        const allocator = exclusive.allocator;
        allocator.destroy(exclusive);
    }
};
