const registration = @import("hctp_conformance_registration.zig");
const execution = @import("hctp_conformance_execution.zig");
const grading = @import("hctp_conformance_grading.zig");
const retrace_holdout = @import("hctp_conformance_retrace_holdout.zig");
const hylo = @import("hylo.zig");
const durable_store = @import("durable_store");
const std = @import("std");

const MaxStoreBytes = 1024 * 1024;

test "HCTP-v1 backend aggregate imports every conformance owner" {
    _ = registration;
    _ = execution;
    _ = grading;
    _ = retrace_holdout;
    _ = hylo;
}

test "HCTP EventStore carrier bridge preserves ordered payloads across memory and persistent reload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "events.jsonl" });
    defer std.testing.allocator.free(path);

    var memory = durable_store.MemoryEventStore.init(std.testing.allocator, "memory:hctp-carrier-bridge");
    defer memory.deinit();
    var persistent = durable_store.PersistentEventStore.init(path);
    const memory_store = memory.eventStore();
    const persistent_store = persistent.eventStore();
    inline for (.{
        "{\"kind\":\"registered\",\"ordinal\":1}",
        "{\"kind\":\"started\",\"ordinal\":2}",
        "{\"kind\":\"finished\",\"ordinal\":3}",
    }) |payload| {
        var memory_receipt = try memory_store.append(
            std.testing.allocator,
            payload,
            .{},
            MaxStoreBytes,
        );
        defer memory_receipt.deinit(std.testing.allocator);
        var persistent_receipt = try persistent_store.append(
            std.testing.allocator,
            payload,
            .{},
            MaxStoreBytes,
        );
        defer persistent_receipt.deinit(std.testing.allocator);
    }

    var reloaded = durable_store.PersistentEventStore.init(path);
    var memory_snapshot = try memory_store.snapshot(std.testing.allocator, MaxStoreBytes);
    defer memory_snapshot.deinit(std.testing.allocator);
    var persistent_snapshot = try reloaded.eventStore().snapshot(std.testing.allocator, MaxStoreBytes);
    defer persistent_snapshot.deinit(std.testing.allocator);
    try std.testing.expect(memory_snapshot.exists);
    try std.testing.expect(persistent_snapshot.exists);
    try std.testing.expectEqualStrings(memory_snapshot.content_digest, persistent_snapshot.content_digest);
    try std.testing.expectEqual(memory_snapshot.records.len, persistent_snapshot.records.len);
    for (memory_snapshot.records, persistent_snapshot.records) |memory_record, persistent_record| {
        try std.testing.expectEqual(memory_record.ordinal, persistent_record.ordinal);
        try std.testing.expectEqualStrings(memory_record.payload, persistent_record.payload);
    }
}

test "HCTP EventStore case 11 focused selected-backend owner witness" {
    try hylo.testConformanceCase11EventStoreOwner();
}
