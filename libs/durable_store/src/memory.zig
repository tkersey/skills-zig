const std = @import("std");
const event = @import("event.zig");
const EventAppendExpectation = event.EventAppendExpectation;
const EventAppendReceipt = event.EventAppendReceipt;
const EventHash = event.EventHash;
const EventRecordVisitor = event.EventRecordVisitor;
const EventScanSummary = event.EventScanSummary;
const EventSnapshot = event.EventSnapshot;
const EventStore = event.EventStore;
const EventStoreExclusive = event.EventStoreExclusive;
const SnapshotCollector = event.SnapshotCollector;
const eventAppendReceipt = event.eventAppendReceipt;
const finishEventScanSummary = event.finishEventScanSummary;
const ignoreEventRecord = event.ignoreEventRecord;
const renderEventRecordsAlloc = event.renderEventRecordsAlloc;
const validateEventAppendFits = event.validateEventAppendFits;
const validateEventExpectation = event.validateEventExpectation;
const validateEventPayload = event.validateEventPayload;

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

    fn exclusiveSnapshot(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) !EventSnapshot {
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
        const existed = self.exists;
        const record_count = self.records.items.len;
        const owned = try self.allocator.dupe(u8, payload);
        self.records.append(self.allocator, owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
        errdefer {
            std.debug.assert(self.records.items.len == record_count + 1);
            self.allocator.free(self.records.pop().?);
            self.exists = existed;
        }
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
        for (records) |payload| {
            const owned = try self.allocator.dupe(u8, payload);
            errdefer self.allocator.free(owned);
            try replacement.append(self.allocator, owned);
        }
        var proposed = self.*;
        proposed.records = replacement;
        proposed.exists = true;
        var after = try scanWithOwnedState(&proposed, allocator, max_bytes, visitor);
        defer after.deinit(allocator);
        const receipt = try eventAppendReceipt(allocator, before, after);
        for (self.records.items) |record| self.allocator.free(record);
        self.records.deinit(self.allocator);
        self.records = replacement;
        replacement = .empty;
        self.exists = true;
        return receipt;
    }

    fn releaseExclusive(context: *anyopaque) void {
        const exclusive = exclusiveCast(context);
        exclusive.store.exclusive_active = false;
        const allocator = exclusive.allocator;
        allocator.destroy(exclusive);
    }
};

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
