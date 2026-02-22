const std = @import("std");

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
        return self.requested_alloc_bytes + self.requested_resize_bytes + self.requested_remap_bytes;
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

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.stats.resize_calls += 1;
        self.stats.requested_resize_bytes += @intCast(new_len);
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
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
            break :blk @intCast(i);
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
            if (v < 0) break :blk null;
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

pub fn percentileU64(allocator: std.mem.Allocator, samples: []const u64, p: usize) !u64 {
    if (samples.len == 0) return error.EmptySamples;
    const copy = try allocator.dupe(u64, samples);
    defer allocator.free(copy);
    std.mem.sort(u64, copy, {}, lessThanU64);

    if (p >= 100) return copy[copy.len - 1];
    const idx = ((copy.len - 1) * p) / 100;
    return copy[idx];
}

pub fn allowedUpperBoundWithTolerance(base: u64, tolerance_pct: f64) u64 {
    if (base == 0) return 1;
    const factor = 1.0 + @max(tolerance_pct, 0.0) / 100.0;
    const allowed = @as(f64, @floatFromInt(base)) * factor;
    return @as(u64, @intFromFloat(std.math.ceil(allowed)));
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
