const std = @import("std");
const spec = @import("../types/spec.zig");
const query = @import("../query/engine.zig");

test "allocation failure in spec parser is surfaced" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();

    try std.testing.expectError(error.OutOfMemory, spec.parseQuerySpecJson(alloc, "{\"select\":[\"role\"]}"));
}

test "allocation failure in query execute is surfaced" {
    var base_rows: std.ArrayList(query.Row) = .empty;
    defer {
        for (base_rows.items) |*row| row.deinit();
        base_rows.deinit(std.testing.allocator);
    }

    var row = query.Row.init(std.testing.allocator);
    try row.putOwnedKey("role", .{ .string = "assistant" });
    try base_rows.append(std.testing.allocator, row);

    const q = spec.QuerySpec{
        .select = &.{"role"},
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();

    try std.testing.expectError(error.OutOfMemory, query.execute(alloc, base_rows.items, q));
}
