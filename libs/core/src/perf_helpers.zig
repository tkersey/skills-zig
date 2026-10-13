const std = @import("std");

/// Counts allocation attempts and requested bytes, including failed calls.
/// These totals do not describe successful allocations or live memory.
pub const AllocStats = struct {
    alloc_calls: u64 = 0,
    resize_calls: u64 = 0,
    remap_calls: u64 = 0,
    free_calls: u64 = 0,
    requested_alloc_bytes: u64 = 0,
    requested_resize_bytes: u64 = 0,
    requested_remap_bytes: u64 = 0,

    pub fn totalCalls(self: AllocStats) u64 {
        return self.alloc_calls + self.resize_calls + self.remap_calls;
    }

    pub fn totalRequestedBytes(self: AllocStats) u64 {
        return self.requested_alloc_bytes +
            self.requested_resize_bytes + self.requested_remap_bytes;
    }
};

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    stats: AllocStats = .{},

    pub fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.stats.alloc_calls += 1;
        self.stats.requested_alloc_bytes += @intCast(len);
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.stats.resize_calls += 1;
        self.stats.requested_resize_bytes += @intCast(new_len);
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.stats.remap_calls += 1;
        self.stats.requested_remap_bytes += @intCast(new_len);
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.stats.free_calls += 1;
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

pub fn intFieldToUsize(value: std.json.Value) !usize {
    return switch (value) {
        .integer => |i| blk: {
            if (i <= 0) return error.InvalidConfig;
            break :blk std.math.cast(usize, i) orelse return error.InvalidConfig;
        },
        else => error.InvalidConfig,
    };
}

pub fn intFieldToU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |i| blk: {
            if (i <= 0) return error.InvalidConfig;
            break :blk @intCast(i);
        },
        else => error.InvalidConfig,
    };
}

pub fn floatFieldToF64(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.InvalidConfig,
    };
}

pub fn valueToU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |v| blk: {
            if (v < 0) break :blk null;
            break :blk @intCast(v);
        },
        .float => |v| blk: {
            if (!std.math.isFinite(v) or v < 0 or v >= 0x1p64) break :blk null;
            break :blk @intFromFloat(v);
        },
        else => null,
    };
}

pub fn valueToF64(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => null,
    };
}

/// Copies and sorts once for all requested floor-index percentiles. The input
/// remains in capture order, including when allocating the working copy fails.
pub fn percentilesU64(
    allocator: std.mem.Allocator,
    samples: []const u64,
    comptime percentages: []const usize,
) ![percentages.len]u64 {
    const sorted = try sortedSamplesAlloc(allocator, samples);
    defer allocator.free(sorted);
    var result: [percentages.len]u64 = undefined;
    for (percentages, 0..) |p, index| result[index] = percentileSortedU64(sorted, p);
    return result;
}

pub fn percentileU64(allocator: std.mem.Allocator, samples: []const u64, p: usize) !u64 {
    const sorted = try sortedSamplesAlloc(allocator, samples);
    defer allocator.free(sorted);
    return percentileSortedU64(sorted, p);
}

fn sortedSamplesAlloc(allocator: std.mem.Allocator, samples: []const u64) ![]u64 {
    if (samples.len == 0) return error.EmptySamples;
    const copy = try allocator.dupe(u64, samples);
    std.mem.sort(u64, copy, {}, lessThanU64);
    return copy;
}

fn percentileSortedU64(sorted: []const u64, p: usize) u64 {
    if (p >= 100) return sorted[sorted.len - 1];
    const last = sorted.len - 1;
    const idx = (last / 100) * p + ((last % 100) * p) / 100;
    return sorted[idx];
}

pub fn allowedUpperBoundWithTolerance(base: u64, tolerance_pct: f64) u64 {
    if (base == 0) return 1;
    const tolerance = if (std.math.isNan(tolerance_pct)) 0.0 else @max(tolerance_pct, 0.0);
    const factor = 1.0 + tolerance / 100.0;
    const allowed = std.math.ceil(@as(f64, @floatFromInt(base)) * factor);
    if (allowed >= 0x1p64) return std.math.maxInt(u64);
    return @intFromFloat(allowed);
}

fn lessThanU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

test "allowedUpperBoundWithTolerance handles positive and zero base" {
    try std.testing.expectEqual(@as(u64, 120), allowedUpperBoundWithTolerance(100, 20.0));
    try std.testing.expectEqual(@as(u64, 1), allowedUpperBoundWithTolerance(0, 20.0));
}

test "int field helpers validate positive integers" {
    try std.testing.expectEqual(
        @as(usize, 5),
        try intFieldToUsize(.{ .integer = 5 }),
    );
    try std.testing.expectEqual(
        @as(u64, 42),
        try intFieldToU64(.{ .integer = 42 }),
    );
    try std.testing.expectError(error.InvalidConfig, intFieldToU64(.{ .integer = 0 }));
}

test "float and numeric value helpers parse numbers" {
    try std.testing.expectApproxEqAbs(
        @as(f64, 2.5),
        try floatFieldToF64(.{ .float = 2.5 }),
        0.000_001,
    );
    try std.testing.expectEqual(@as(?u64, 5), valueToU64(.{ .integer = 5 }));
    try std.testing.expectEqual(@as(?u64, 7), valueToU64(.{ .float = 7.0 }));
    try std.testing.expectEqual(@as(?f64, 9.0), valueToF64(.{ .integer = 9 }));
}

test "numeric helpers reject unrepresentable unsigned floats" {
    const invalid = [_]f64{ -1.0, 0x1p64, std.math.inf(f64), std.math.nan(f64) };
    for (invalid) |value| {
        try std.testing.expectEqual(@as(?u64, null), valueToU64(.{ .float = value }));
    }
    try std.testing.expectEqual(@as(?u64, 7), valueToU64(.{ .float = 7.9 }));
}

test "tolerance upper bounds saturate instead of trapping" {
    const maximum = std.math.maxInt(u64);
    try std.testing.expectEqual(maximum, allowedUpperBoundWithTolerance(maximum, 20));
    try std.testing.expectEqual(maximum, allowedUpperBoundWithTolerance(1, std.math.inf(f64)));
    try std.testing.expectEqual(@as(u64, 100), allowedUpperBoundWithTolerance(100, -20));
    try std.testing.expectEqual(
        @as(u64, 100),
        allowedUpperBoundWithTolerance(100, std.math.nan(f64)),
    );
}

test "percentile summaries preserve floor ranks, duplicates, extremes, and capture order" {
    const samples = [_]u64{ 9, 0, 3, std.math.maxInt(u64), 3, 7, 1, 8, 2, 6 };
    const before = samples;
    const actual = try percentilesU64(std.testing.allocator, &samples, &.{ 0, 50, 95, 100, 101 });
    try std.testing.expectEqualSlices(u64, &.{ 0, 3, 9, std.math.maxInt(u64), std.math.maxInt(u64) }, &actual);
    try std.testing.expectEqualSlices(u64, &before, &samples);
    const singleton = try percentilesU64(std.testing.allocator, &.{42}, &.{ 0, 50, 95, 100 });
    try std.testing.expectEqualSlices(u64, &.{ 42, 42, 42, 42 }, &singleton);
}

test "percentile summaries agree with legacy independent sorts at established and large sample counts" {
    var storage: [4097]u64 = undefined;
    for (&storage, 0..) |*sample, index| sample.* = @intCast((index * 37) % 113);
    const percentages = [_]usize{ 0, 1, 50, 95, 99, 100, 101, std.math.maxInt(usize) };
    for ([_]usize{ 8, 9, 30, 240, storage.len }) |count| {
        var counting = CountingAllocator.init(std.testing.allocator);
        const actual = try percentilesU64(counting.allocator(), storage[0..count], &percentages);
        try std.testing.expectEqual(@as(u64, 1), counting.stats.alloc_calls);
        try std.testing.expectEqual(@as(u64, 1), counting.stats.free_calls);
        try std.testing.expectEqual(@as(u64, count * @sizeOf(u64)), counting.stats.requested_alloc_bytes);
        for (percentages, actual) |percent, result| {
            var legacy = storage;
            const sorted = legacy[0..count];
            std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
            const index = if (percent >= 100) count - 1 else ((count - 1) * percent) / 100;
            try std.testing.expectEqual(sorted[index], result);
            try std.testing.expectEqual(result, try percentileU64(std.testing.allocator, storage[0..count], percent));
        }
    }
}

test "percentile summaries preserve empty-input and allocation failure behavior" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    try std.testing.expectError(error.EmptySamples, percentilesU64(allocator, &.{}, &.{ 50, 95 }));
    try std.testing.expectError(error.EmptySamples, percentileU64(allocator, &.{}, 50));
    var samples = [_]u64{ 9, 1, 3 };
    try std.testing.expectError(error.OutOfMemory, percentilesU64(allocator, &samples, &.{ 50, 95 }));
    try std.testing.expectEqualSlices(u64, &.{ 9, 1, 3 }, &samples);
}

test "allocation counters retain attempted calls and requested bytes on success and failure" {
    var storage: [16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var counting = CountingAllocator.init(fixed.allocator());
    const allocator = counting.allocator();
    const alignment = std.mem.Alignment.of(u8);
    const memory = allocator.rawAlloc(8, alignment, @returnAddress()).?;
    try std.testing.expect(allocator.rawAlloc(32, alignment, @returnAddress()) == null);
    try std.testing.expect(allocator.rawResize(memory[0..8], alignment, 12, @returnAddress()));
    try std.testing.expect(!allocator.rawResize(memory[0..12], alignment, 32, @returnAddress()));
    const remapped = allocator.rawRemap(memory[0..12], alignment, 4, @returnAddress()).?;
    try std.testing.expect(allocator.rawRemap(remapped[0..4], alignment, 32, @returnAddress()) == null);
    allocator.rawFree(remapped[0..4], alignment, @returnAddress());
    try std.testing.expectEqual(AllocStats{
        .alloc_calls = 2,
        .resize_calls = 2,
        .remap_calls = 2,
        .free_calls = 1,
        .requested_alloc_bytes = 40,
        .requested_resize_bytes = 44,
        .requested_remap_bytes = 36,
    }, counting.stats);
    try std.testing.expectEqual(@as(u64, 6), counting.stats.totalCalls());
    try std.testing.expectEqual(@as(u64, 120), counting.stats.totalRequestedBytes());
}
