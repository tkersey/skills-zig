const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Budget = struct {
    child: Allocator,
    remaining: usize,

    pub fn init(child: Allocator, bytes_max: usize) Budget {
        return .{ .child = child, .remaining = bytes_max };
    }

    pub fn allocator(self: *Budget) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(context));
        if (len > self.remaining) return null;
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.remaining -= len;
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Budget = @ptrCast(@alignCast(context));
        if (new_len > memory.len and new_len - memory.len > self.remaining) return false;
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.account(memory.len, new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(context));
        if (new_len > memory.len and new_len - memory.len > self.remaining) return null;
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.account(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *Budget = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
        self.remaining += memory.len;
    }

    fn account(self: *Budget, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.remaining -= new_len - old_len;
        } else {
            self.remaining += old_len - new_len;
        }
    }
};

test "budget refuses growth beyond its limit and restores freed bytes" {
    var budget = Budget.init(std.testing.allocator, 64);
    const allocator = budget.allocator();
    const first = try allocator.alloc(u8, 48);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 17));
    try std.testing.expect(!allocator.resize(first, 65));
    allocator.free(first);
    try std.testing.expectEqual(@as(usize, 64), budget.remaining);
    const second = try allocator.alloc(u8, 64);
    allocator.free(second);
}
