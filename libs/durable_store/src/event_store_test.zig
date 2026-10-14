const std = @import("std");
const event = @import("event.zig");
const EventAppendExpectation = event.EventAppendExpectation;
const EventAppendReceipt = event.EventAppendReceipt;
const EventRecordView = event.EventRecordView;
const EventRecordVisitor = event.EventRecordVisitor;
const EventSnapshot = event.EventSnapshot;
const EventStore = event.EventStore;
const EventStoreExclusive = event.EventStoreExclusive;
const fs_authority = @import("fs_authority.zig");
const Fs = fs_authority.Fs;
const filesystem = @import("filesystem.zig");
const acquireLock = filesystem.acquireLock;
const appendLineStreaming = filesystem.appendLineStreaming;
const directoryNameIsCaseInsensitive = filesystem.directoryNameIsCaseInsensitive;
const ensureDirectoryPathNoSymlinks = filesystem.ensureDirectoryPathNoSymlinks;
const ensureParentPath = filesystem.ensureParentPath;
const eventStoreLockPathAlloc = filesystem.eventStoreLockPathAlloc;
const fileExists = filesystem.fileExists;
const readFileAlloc = filesystem.readFileAlloc;
const targetNameStat = filesystem.targetNameStat;
const writeTextAtomic = filesystem.writeTextAtomic;
const writeTextCreateNew = filesystem.writeTextCreateNew;
const memory_impl = @import("memory.zig");
const MemoryEventStore = memory_impl.MemoryEventStore;
const jsonl = @import("jsonl.zig");
const JsonlEventStore = jsonl.JsonlEventStore;
const PersistentEventStore = jsonl.PersistentEventStore;
const transactions = @import("transactions.zig");
const TransactionAllocationFixture = transactions.TransactionAllocationFixture;
const acquireLeaseLock = transactions.acquireLeaseLock;
const releaseLease = transactions.releaseLease;
const record_codec = @import("record_codec.zig");
const AcquireOptions = record_codec.AcquireOptions;
const lockPathAlloc = record_codec.lockPathAlloc;

test "persistent mutation enforces shared lock ignore admission" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
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
    try std.testing.expect(git_result.term == .exited and git_result.term.exited == 0);

    const gitignore = try std.fs.path.join(std.testing.allocator, &.{ root, ".gitignore" });
    defer std.testing.allocator.free(gitignore);
    try writeTextAtomic(fs, std.testing.allocator, gitignore, "events.jsonl.lock\n");
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(store_path);
    try writeTextAtomic(fs, std.testing.allocator, store_path, "{\"sequence\":0}\n");
    var backend = JsonlEventStore.init(fs, store_path);
    try std.testing.expectError(
        error.LockSidecarNotGitignored,
        backend.eventStore().acquireExclusive(std.testing.allocator),
    );

    try writeTextAtomic(
        fs,
        std.testing.allocator,
        gitignore,
        "events.jsonl.lock\n.durable-store-locks/\n",
    );
    var exclusive = try backend.eventStore().acquireExclusive(std.testing.allocator);
    exclusive.release();

    try writeTextAtomic(
        fs,
        std.testing.allocator,
        gitignore,
        "*.jsonl.lock\n.durable-store-locks/\n",
    );
    const prospective_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "missing", "nested", "prospective.jsonl" },
    );
    defer std.testing.allocator.free(prospective_path);
    var prospective = JsonlEventStore.init(fs, prospective_path);
    var prospective_exclusive = try prospective.eventStore().acquireExclusive(
        std.testing.allocator,
    );
    prospective_exclusive.release();
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
        const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
        const self: *GrowingEventScanProbe = @ptrCast(@alignCast(context));
        self.count += 1;
        if (self.expanded) return;
        self.expanded = true;
        try appendLineStreaming(
            fs,
            std.testing.allocator,
            self.path,
            "{\"n\":2}",
            .{ .sync = false },
        );
        try appendLineStreaming(
            fs,
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
        const self: *ReleaseDuringExclusiveScanProbe = @ptrCast(@alignCast(context));
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
    var seeded = try store.replace(std.testing.allocator, &records, .{ .exists = false }, 4096);
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

    try assertEventStoreReplacementAndScan(store, &after_first);
}

fn assertEventStoreReplacementAndScan(
    store: EventStore,
    after_first: *const EventSnapshot,
) !void {
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
    try std.testing.expectError(
        error.EventStoreBusy,
        store.acquireExclusive(std.testing.allocator),
    );
    var ordinary_probe = EventScanProbe{};
    try std.testing.expectError(error.EventStoreBusy, store.scan(
        std.testing.allocator,
        4096,
        ordinary_probe.visitor(),
    ));
    try std.testing.expectError(error.EventStoreBusy, store.snapshot(std.testing.allocator, 4096));

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
    try std.testing.expectError(
        error.EventStoreSessionReleased,
        exclusive.snapshot(std.testing.allocator, 4096),
    );

    var reacquired = try store.acquireExclusive(std.testing.allocator);
    reacquired.release();
}

test "event store contract is backend independent" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(path);

    var persistent_backend = PersistentEventStore.init(fs, path);
    try assertEventStoreContract(persistent_backend.eventStore());

    var memory_backend = MemoryEventStore.init(std.testing.allocator, "memory:test");
    defer memory_backend.deinit();
    try assertEventStoreContract(memory_backend.eventStore());

    var persistent_snapshot = try persistent_backend.eventStore().snapshot(
        std.testing.allocator,
        4096,
    );
    defer persistent_snapshot.deinit(std.testing.allocator);
    var memory_snapshot = try memory_backend.eventStore().snapshot(std.testing.allocator, 4096);
    defer memory_snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(persistent_snapshot.records.len, memory_snapshot.records.len);
    try std.testing.expectEqualStrings(
        persistent_snapshot.content_digest,
        memory_snapshot.content_digest,
    );
    for (persistent_snapshot.records, memory_snapshot.records) |persistent_record, memory_record| {
        try std.testing.expectEqualStrings(persistent_record.payload, memory_record.payload);
    }
}

test "event scans expose exact raw bytes in the same physical pass" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(path);
    const records = [_][]const u8{
        "{\"sequence\":1}",
        "{\"sequence\":2}",
    };
    const expected = records[0] ++ "\n" ++ records[1] ++ "\n";

    var persistent = PersistentEventStore.init(fs, path);
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
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "padded.jsonl" });
    defer std.testing.allocator.free(path);
    try writeTextAtomic(fs, std.testing.allocator, path, " \n{\"a\":1}\n\t\n");

    var persistent_backend = PersistentEventStore.init(fs, path);
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
    var memory_snapshot = try memory_backend.eventStore().snapshot(std.testing.allocator, 4096);
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
    try std.testing.expectEqual(persistent_snapshot.blank_entries, memory_snapshot.blank_entries);
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
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "reentrant.jsonl" });
    defer std.testing.allocator.free(path);

    var persistent_backend = PersistentEventStore.init(fs, path);
    try assertEventStoreRejectsReentrantMutation(persistent_backend.eventStore());

    var equivalent_backend = PersistentEventStore.init(fs, path);
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
    try std.testing.expectEqualStrings(before_alias_scan.revision, after_alias_scan.revision);

    var memory_backend = MemoryEventStore.init(std.testing.allocator, "memory:reentrant");
    defer memory_backend.deinit();
    try assertEventStoreRejectsReentrantMutation(memory_backend.eventStore());
}

test "jsonl scan maps open-time missing store to an empty summary" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "missing.jsonl" });
    defer std.testing.allocator.free(path);
    const lock_path = try lockPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(lock_path);

    var backend = JsonlEventStore.init(fs, path);
    var probe = EventScanProbe{};
    var summary = try backend.eventStore().scan(std.testing.allocator, 4096, probe.visitor());
    defer summary.deinit(std.testing.allocator);

    try std.testing.expect(!summary.exists);
    try std.testing.expectEqual(@as(usize, 0), summary.record_count);
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try std.testing.expect(!fileExists(fs, path));
    try std.testing.expect(!fileExists(fs, lock_path));
}

test "jsonl scans require no parent write and tolerate unlocked sidecars" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const parent = try std.fs.path.join(std.testing.allocator, &.{ root, "read-only" });
    defer std.testing.allocator.free(parent);
    try ensureDirectoryPathNoSymlinks(fs, parent);
    const path = try std.fs.path.join(std.testing.allocator, &.{ parent, "events.jsonl" });
    defer std.testing.allocator.free(path);
    const public_lock_path = try lockPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(public_lock_path);
    const advisory_path = try eventStoreLockPathAlloc(fs, std.testing.allocator, path);
    defer std.testing.allocator.free(advisory_path);
    try writeTextAtomic(fs, std.testing.allocator, path, "{\"n\":1}\n");

    var parent_dir = try std.Io.Dir.openDirAbsolute(fs.io, parent, .{
        .iterate = true,
    });
    defer parent_dir.close(fs.io);
    const writable = std.Io.File.Permissions.fromMode(0o755);
    const read_only = std.Io.File.Permissions.fromMode(0o555);
    try parent_dir.setPermissions(fs.io, read_only);
    defer parent_dir.setPermissions(fs.io, writable) catch |err| {
        std.debug.panic("restore test directory permissions: {s}", .{
            @errorName(err),
        });
    };

    var backend = JsonlEventStore.init(fs, path);
    var first = try backend.eventStore().snapshot(std.testing.allocator, 4096);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.records.len);
    try std.testing.expect(!fileExists(fs, public_lock_path));
    try std.testing.expect(!fileExists(fs, advisory_path));

    try parent_dir.setPermissions(fs.io, writable);
    try ensureParentPath(fs, advisory_path);
    try writeTextCreateNew(fs, std.testing.allocator, advisory_path, "", .{});
    try parent_dir.setPermissions(fs.io, read_only);
    var second = try backend.eventStore().snapshot(std.testing.allocator, 4096);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first.revision, second.revision);
    try std.testing.expect(!fileExists(fs, public_lock_path));
    try std.testing.expect(fileExists(fs, advisory_path));

    try parent_dir.setPermissions(fs.io, writable);
    var exclusive = try backend.eventStore().acquireExclusive(std.testing.allocator);
    exclusive.release();
    try std.testing.expect(!fileExists(fs, public_lock_path));
    try std.testing.expect(fileExists(fs, advisory_path));
}

test "jsonl scan classifies a final symlink as SymlinkComponent" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(path);
    const link = try std.fs.path.join(std.testing.allocator, &.{ root, "events-link.jsonl" });
    defer std.testing.allocator.free(link);
    try writeTextAtomic(fs, std.testing.allocator, path, "{\"n\":1}\n");
    try tmp.dir.symLink(fs.io, "events.jsonl", "events-link.jsonl", .{});

    var backend = JsonlEventStore.init(fs, link);
    try std.testing.expectError(
        error.SymlinkComponent,
        backend.eventStore().snapshot(std.testing.allocator, 4096),
    );
}

test "EventStore rejects special data and advisory files before open" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const special_data = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "special-data.jsonl" },
    );
    defer std.testing.allocator.free(special_data);
    try createFifoForTest(special_data);
    var data_backend = PersistentEventStore.init(fs, special_data);
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
    try writeTextAtomic(fs, std.testing.allocator, regular_data, "{\"sequence\":1}\n");
    const special_advisory = try eventStoreLockPathAlloc(fs, std.testing.allocator, regular_data);
    defer std.testing.allocator.free(special_advisory);
    try ensureParentPath(fs, special_advisory);
    try createFifoForTest(special_advisory);
    var advisory_backend = PersistentEventStore.init(fs, regular_data);
    try std.testing.expectError(
        error.NotFile,
        advisory_backend.eventStore().snapshot(std.testing.allocator, 4096),
    );
    try std.testing.expectError(
        error.NotFile,
        advisory_backend.eventStore().acquireExclusive(std.testing.allocator),
    );
}

test "jsonl scan preserves completed visitor calls before a terminal error" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "growing.jsonl" });
    defer std.testing.allocator.free(path);
    try writeTextAtomic(fs, std.testing.allocator, path, "{\"n\":1}\n");

    var backend = JsonlEventStore.init(fs, path);
    var probe = GrowingEventScanProbe{ .path = path };
    try std.testing.expectError(
        error.StreamTooLong,
        backend.eventStore().scan(std.testing.allocator, 16, probe.visitor()),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.count);
}

test "ordinary scans reject active exclusive sessions across backends" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "exclusive-events.jsonl" });
    defer std.testing.allocator.free(path);

    var persistent_backend = PersistentEventStore.init(fs, path);
    try assertExclusiveEventStoreContract(persistent_backend.eventStore());

    var memory_backend = MemoryEventStore.init(std.testing.allocator, "memory:exclusive-test");
    defer memory_backend.deinit();
    try assertExclusiveEventStoreContract(memory_backend.eventStore());
}

test "exclusive release requested by a visitor waits for scan completion" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "release-during-scan.jsonl" },
    );
    defer std.testing.allocator.free(path);

    var owner_backend = PersistentEventStore.init(fs, path);
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

    var contender_backend = PersistentEventStore.init(fs, path);
    const contender = contender_backend.eventStore();
    var exclusive = try owner_backend.eventStore().acquireExclusive(std.testing.allocator);
    defer exclusive.release();
    var probe = ReleaseDuringExclusiveScanProbe{
        .session = &exclusive,
        .contender = contender,
    };
    var summary = try exclusive.scan(std.testing.allocator, 4096, probe.visitor());
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(probe.mutation_rejected);
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    try std.testing.expectEqual(@as(usize, 2), summary.record_count);
    try std.testing.expect(!exclusive.active);
    try std.testing.expect(!exclusive.release_pending);

    var after_scan = try contender.acquireExclusive(std.testing.allocator);
    after_scan.release();
}

test "EventStore missing case aliases retain one custody owner" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    filesystem.directory_case_cache = .{};
    defer filesystem.directory_case_cache = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(fs.io, "CaseParent", .default_dir);
    const original = try tmp.dir.statFile(fs.io, "CaseParent", .{});
    const alias_stat = (try targetNameStat(fs, tmp.dir, "caseParent")) orelse return;
    try std.testing.expectEqual(original.inode, alias_stat.inode);
    const root = try tmp.dir.realPathFileAlloc(fs.io, "CaseParent", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const first = try std.fs.path.join(std.testing.allocator, &.{ root, "Events.jsonl" });
    defer std.testing.allocator.free(first);
    const alias = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(alias);
    var owner = JsonlEventStore.init(fs, first);
    var session = try owner.eventStore().acquireExclusive(std.testing.allocator);
    defer session.release();
    var contender = JsonlEventStore.init(fs, alias);
    if (contender.eventStore().snapshot(std.testing.allocator, 4096)) |snapshot| {
        var unexpected = snapshot;
        defer unexpected.deinit(std.testing.allocator);
        std.debug.print("case-alias snapshot succeeded: exists={any}, records={d}\n", .{
            unexpected.exists,
            unexpected.records.len,
        });
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.EventStoreBusy, err);
    }
}

test "EventStore prospective case identity follows the host filesystem" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const canonical_path = try std.fs.path.join(std.testing.allocator, &.{ root, "Events.jsonl" });
    defer std.testing.allocator.free(canonical_path);
    const case_alias = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(case_alias);
    const case_insensitive = try directoryNameIsCaseInsensitive(
        fs,
        std.testing.allocator,
        root,
        "Events.jsonl",
    );
    const canonical_advisory = try eventStoreLockPathAlloc(
        fs,
        std.testing.allocator,
        canonical_path,
    );
    defer std.testing.allocator.free(canonical_advisory);
    const alias_advisory = try eventStoreLockPathAlloc(fs, std.testing.allocator, case_alias);
    defer std.testing.allocator.free(alias_advisory);
    try std.testing.expectEqual(
        case_insensitive,
        std.mem.eql(u8, canonical_advisory, alias_advisory),
    );
    if (!case_insensitive) return;

    var canonical = JsonlEventStore.init(fs, canonical_path);
    var exclusive = try canonical.eventStore().acquireExclusive(std.testing.allocator);
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
    var alias = JsonlEventStore.init(fs, case_alias);
    try std.testing.expectError(
        error.EventStoreBusy,
        alias.eventStore().snapshot(std.testing.allocator, 4096),
    );
}

test "EventStore exclusive sessions bridge public lock protocols" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(path);
    const public_lock_path = try lockPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(public_lock_path);
    const advisory_path = try eventStoreLockPathAlloc(fs, std.testing.allocator, path);
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

    var backend = JsonlEventStore.init(fs, path);
    const store = backend.eventStore();

    var presence = try acquireLock(fs, std.testing.allocator, path);
    try std.testing.expectError(
        error.EventStoreBusy,
        store.acquireExclusive(std.testing.allocator),
    );
    presence.release(std.testing.allocator);

    var lease = try acquireLeaseLock(fs, std.testing.allocator, path, lease_options);
    try std.testing.expectError(
        error.EventStoreBusy,
        store.acquireExclusive(std.testing.allocator),
    );
    try releaseLease(fs, std.testing.allocator, &lease, lease.fencing_token);

    var exclusive = try store.acquireExclusive(std.testing.allocator);
    try std.testing.expect(fileExists(fs, public_lock_path));
    try std.testing.expect(fileExists(fs, advisory_path));
    try std.testing.expectError(
        error.PathAlreadyExists,
        acquireLock(fs, std.testing.allocator, path),
    );
    try std.testing.expectError(
        error.LockBusy,
        acquireLeaseLock(fs, std.testing.allocator, path, lease_options),
    );
    exclusive.release();

    try std.testing.expect(!fileExists(fs, public_lock_path));
    try std.testing.expect(fileExists(fs, advisory_path));

    var presence_after = try acquireLock(fs, std.testing.allocator, path);
    presence_after.release(std.testing.allocator);
    var lease_after = try acquireLeaseLock(fs, std.testing.allocator, path, lease_options);
    try releaseLease(fs, std.testing.allocator, &lease_after, lease_after.fencing_token);
}

test "jsonl event store contains physical diagnostics in its adapter" {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(fs.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(path);
    try writeTextAtomic(fs, std.testing.allocator, path, "{\"sequence\":1}\n\n{\"sequence\":2}");

    var backend = JsonlEventStore.init(fs, path);
    var snapshot = try backend.eventStore().snapshot(std.testing.allocator, 4096);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.records.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.blank_entries);
    try std.testing.expectEqual(@as(?usize, 1), snapshot.records[0].diagnostic_position);
    try std.testing.expectEqual(@as(?usize, 3), snapshot.records[1].diagnostic_position);
    try std.testing.expectEqual(@as(usize, 1), snapshot.append_separator_bytes);
}

const MemoryAllocationOperation = enum { append, replace };

test "memory event mutations preserve complete snapshots on allocation failure" {
    for ([_]MemoryAllocationOperation{ .append, .replace }) |operation| {
        for ([_]bool{ false, true }) |exists| {
            try @import("test_support").checkAllAllocationFailures(
                std.testing.allocator,
                checkMemoryMutationAllocation,
                .{ operation, exists },
            );
        }
    }
}

fn checkMemoryMutationAllocation(
    allocator: std.mem.Allocator,
    operation: MemoryAllocationOperation,
    initially_exists: bool,
) !void {
    var backend = MemoryEventStore.init(allocator, "memory:allocation-test");
    defer backend.deinit();
    if (initially_exists) try seedMemoryAllocationStore(&backend);
    const store = backend.eventStore();
    var before = try store.snapshot(std.testing.allocator, 4096);
    defer before.deinit(std.testing.allocator);
    const expectation: EventAppendExpectation = .{
        .revision = before.revision,
        .exists = before.exists,
    };
    var receipt = (switch (operation) {
        .append => store.append(allocator, "{\"n\":3}", expectation, 4096),
        .replace => store.replace(allocator, &.{ "{\"n\":4}", "{\"n\":5}" }, expectation, 4096),
    }) catch |err| {
        var after = try store.snapshot(std.testing.allocator, 4096);
        defer after.deinit(std.testing.allocator);
        try std.testing.expectEqualDeep(before, after);
        try std.testing.expect(!backend.exclusive_active);
        try std.testing.expect(!backend.scan_active);
        return err;
    };
    defer receipt.deinit(allocator);
    try assertEventAllocationSuccess(store, receipt, operation, initially_exists);
}

fn seedMemoryAllocationStore(backend: *MemoryEventStore) !void {
    for ([_][]const u8{ "{\"n\":1}", "{\"n\":2}" }) |payload| {
        const owned = try backend.allocator.dupe(u8, payload);
        errdefer backend.allocator.free(owned);
        try backend.records.append(backend.allocator, owned);
    }
    backend.exists = true;
}

fn assertEventAllocationSuccess(
    store: EventStore,
    receipt: EventAppendReceipt,
    operation: MemoryAllocationOperation,
    initially_exists: bool,
) !void {
    var after = try store.snapshot(std.testing.allocator, 4096);
    defer after.deinit(std.testing.allocator);
    const before_count: usize = if (initially_exists) 2 else 0;
    const after_count = if (operation == .append) before_count + 1 else 2;
    try std.testing.expect(after.exists);
    try std.testing.expectEqual(before_count, receipt.record_count_before);
    try std.testing.expectEqual(after_count, receipt.record_count_after);
    try std.testing.expectEqual(after_count, after.records.len);
    try std.testing.expectEqualStrings(receipt.revision_after, after.revision);
    try std.testing.expectEqualStrings(receipt.content_digest_after, after.content_digest);
    if (operation == .append) {
        try std.testing.expectEqualStrings("{\"n\":3}", after.records[after_count - 1].payload);
    } else {
        try std.testing.expectEqualStrings("{\"n\":4}", after.records[0].payload);
        try std.testing.expectEqualStrings("{\"n\":5}", after.records[1].payload);
    }
}

test "persistent event mutations preserve bytes and snapshots on allocation failure" {
    for ([_]MemoryAllocationOperation{ .append, .replace }) |operation| {
        try @import("test_support").checkAllAllocationFailures(
            std.testing.allocator,
            checkPersistentMutationAllocation,
            .{operation},
        );
    }
}

fn checkPersistentMutationAllocation(
    allocator: std.mem.Allocator,
    operation: MemoryAllocationOperation,
) !void {
    const fs = Fs.init(std.testing.io, std.Io.Dir.cwd());
    var fixture = try TransactionAllocationFixture.init();
    defer fixture.deinit();
    const original = "{\"n\":1}\n{\"n\":2}\n";
    try writeTextAtomic(fs, std.testing.allocator, fixture.target_path, original);
    var backend = JsonlEventStore.init(fs, fixture.target_path);
    const store = backend.eventStore();
    var before = try store.snapshot(std.testing.allocator, 4096);
    defer before.deinit(std.testing.allocator);
    const expectation: EventAppendExpectation = .{
        .revision = before.revision,
        .exists = before.exists,
    };
    var receipt = (switch (operation) {
        .append => store.append(allocator, "{\"n\":3}", expectation, 4096),
        .replace => store.replace(allocator, &.{ "{\"n\":4}", "{\"n\":5}" }, expectation, 4096),
    }) catch |err| {
        try fixture.expectContent(original);
        var after = try store.snapshot(std.testing.allocator, 4096);
        defer after.deinit(std.testing.allocator);
        try std.testing.expectEqualDeep(before, after);
        return err;
    };
    defer receipt.deinit(allocator);
    try assertEventAllocationSuccess(store, receipt, operation, true);
}

test "independent filesystem authorities retain roots during nested event operations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var left = std.testing.tmpDir(.{});
    defer left.cleanup();
    var right = std.testing.tmpDir(.{});
    defer right.cleanup();
    const left_fs = Fs.anchored(io, left.dir);
    const right_fs = Fs.init(io, right.dir);
    try writeTextAtomic(left_fs, allocator, "events.jsonl", "{\"root\":\"left\"}\n");
    try writeTextAtomic(right_fs, allocator, "events.jsonl", "{\"root\":\"right\"}\n");
    var left_backend = JsonlEventStore.init(left_fs, "events.jsonl");
    var right_backend = JsonlEventStore.init(right_fs, "events.jsonl");
    var held = try left_backend.eventStore().acquireExclusive(allocator);
    defer held.release();
    const Probe = struct {
        other: EventStore,
        visited: usize = 0,
        fn visit(context: *anyopaque, record: EventRecordView) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("{\"root\":\"left\"}", record.payload);
            var receipt = try self.other.append(
                std.testing.allocator,
                "{\"nested\":true}",
                .{},
                4096,
            );
            defer receipt.deinit(std.testing.allocator);
            self.visited += 1;
        }
    };
    var probe = Probe{ .other = right_backend.eventStore() };
    var scan = try held.scan(allocator, 4096, .{ .context = &probe, .visitFn = Probe.visit });
    defer scan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), probe.visited);
    held.release();
    var left_snapshot = try left_backend.eventStore().snapshot(allocator, 4096);
    defer left_snapshot.deinit(allocator);
    var right_snapshot = try right_backend.eventStore().snapshot(allocator, 4096);
    defer right_snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), left_snapshot.records.len);
    try std.testing.expectEqual(@as(usize, 2), right_snapshot.records.len);
    try std.testing.expectEqualStrings("{\"root\":\"right\"}", right_snapshot.records[0].payload);
}

test "pinned authority keeps data and lock cleanup on a renamed root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "selected", .default_dir);
    var retained = try tmp.dir.openDir(io, "selected", .{});
    defer retained.close(io);
    const fs = Fs.anchored(io, retained);
    try writeTextAtomic(fs, allocator, "events.jsonl", "{\"retained\":true}\n");
    const before_lock = try eventStoreLockPathAlloc(fs, allocator, "events.jsonl");
    defer allocator.free(before_lock);
    var backend = JsonlEventStore.init(fs, "events.jsonl");
    var held = try backend.eventStore().acquireExclusive(allocator);
    defer held.release();
    try tmp.dir.rename("selected", tmp.dir, "retained", io);
    try tmp.dir.createDir(io, "selected", .default_dir);
    var replacement = try tmp.dir.openDir(io, "selected", .{});
    defer replacement.close(io);
    try writeTextAtomic(
        Fs.init(io, replacement),
        allocator,
        "events.jsonl",
        "{\"replacement\":true}\n",
    );
    const after_lock = try eventStoreLockPathAlloc(fs, allocator, "events.jsonl");
    defer allocator.free(after_lock);
    try std.testing.expectEqualStrings(before_lock, after_lock);
    var receipt = try held.append(allocator, "{\"after_swap\":true}", .{}, 4096);
    defer receipt.deinit(allocator);
    held.release();
    try std.testing.expect(!fileExists(fs, "events.jsonl.lock"));
    var snapshot = try backend.eventStore().snapshot(allocator, 4096);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.records.len);
    const replacement_bytes = try readFileAlloc(
        Fs.init(io, replacement),
        allocator,
        "events.jsonl",
        4096,
    );
    defer allocator.free(replacement_bytes);
    try std.testing.expectEqualStrings("{\"replacement\":true}\n", replacement_bytes);
}

test "canceled filesystem authority releases partially acquired event custody" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fs = Fs.anchored(io, tmp.dir);
    try writeTextAtomic(fs, allocator, "events.jsonl", "{\"before\":true}\n");
    var vtable = io.vtable.*;
    vtable.dirOpenFile = struct {
        fn open(
            userdata: ?*anyopaque,
            dir: std.Io.Dir,
            path: []const u8,
            options: std.Io.Dir.OpenFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            if (std.mem.eql(u8, path, "events.jsonl")) return error.Canceled;
            return std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
        }
    }.open;
    const failing = Fs.anchored(.{ .userdata = io.userdata, .vtable = &vtable }, tmp.dir);
    var backend = JsonlEventStore.init(failing, "events.jsonl");
    try std.testing.expectError(error.Canceled, backend.eventStore().acquireExclusive(allocator));
    try std.testing.expect(!fileExists(fs, "events.jsonl.lock"));
    try std.testing.expectError(error.Canceled, backend.eventStore().snapshot(allocator, 4096));
    var healthy = JsonlEventStore.init(fs, "events.jsonl");
    var held = try healthy.eventStore().acquireExclusive(allocator);
    held.release();
    var snapshot = try healthy.eventStore().snapshot(allocator, 4096);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.records.len);
}
