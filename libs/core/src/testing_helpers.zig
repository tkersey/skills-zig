const std = @import("std");

/// SafeAllocator can grow the last allocation in a bucket, depending on the
/// preceding trials' heap history. Force relocation so the fault index enumerates
/// the same allocation sequence in every trial. The standard checker still
/// verifies every injected failure, propagation, and balanced allocation bytes.
pub fn checkAllAllocationFailures(
    backing: std.mem.Allocator,
    comptime probe: anytype,
    args: anytype,
) !void {
    var relocating = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(relocating.allocator(), probe, args);
}

fn growthProbe(allocator: std.mem.Allocator) !void {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    for (0..1024) |index| try bytes.append(allocator, @truncate(index));
    try std.testing.expectEqual(@as(u8, 255), bytes.items[1023]);
}

fn swallowingProbe(allocator: std.mem.Allocator) !void {
    const bytes = allocator.alloc(u8, 8) catch return;
    defer allocator.free(bytes);
}

test "relocation fault trials preserve growth and reject swallowed allocation failures" {
    try checkAllAllocationFailures(std.testing.allocator, growthProbe, .{});
    try std.testing.expectError(
        error.SwallowedOutOfMemoryError,
        checkAllAllocationFailures(std.testing.allocator, swallowingProbe, .{}),
    );
}
