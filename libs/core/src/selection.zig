const std = @import("std");

pub fn siftUp(
    comptime T: type,
    heap: []T,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), T, T) bool,
) void {
    std.debug.assert(heap.len > 0);
    var child = heap.len - 1;
    while (child > 0) {
        const parent = (child - 1) / 2;
        if (!lessThan(context, heap[parent], heap[child])) return;
        std.mem.swap(T, &heap[parent], &heap[child]);
        child = parent;
    }
}

pub fn siftDown(
    comptime T: type,
    heap: []T,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), T, T) bool,
) void {
    std.debug.assert(heap.len > 0);
    var parent: usize = 0;
    while (parent < heap.len / 2) {
        var child = parent * 2 + 1;
        if (child + 1 < heap.len and lessThan(context, heap[child], heap[child + 1])) {
            child += 1;
        }
        if (!lessThan(context, heap[parent], heap[child])) return;
        std.mem.swap(T, &heap[parent], &heap[child]);
        parent = child;
    }
}

const TestRow = struct {
    key: i64,
    ordinal: usize,

    fn lessThan(descending: bool, left: TestRow, right: TestRow) bool {
        if (left.key == right.key) return left.ordinal < right.ordinal;
        return if (descending) left.key > right.key else left.key < right.key;
    }
};

fn expectSelection(count: usize, limit: usize, descending: bool) !void {
    var source: [257]TestRow = undefined;
    for (&source, 0..) |*row, index| {
        row.* = .{ .key = @as(i64, @intCast((index * 73) % 31)) - 15, .ordinal = index };
    }
    var expected = source;
    std.mem.sort(TestRow, expected[0..count], descending, TestRow.lessThan);
    var selected: [257]TestRow = undefined;
    const capacity = @min(count, limit);
    var retained: usize = 0;
    for (source[0..count]) |row| {
        if (capacity == 0) continue;
        if (retained < capacity) {
            selected[retained] = row;
            retained += 1;
            siftUp(TestRow, selected[0..retained], descending, TestRow.lessThan);
        } else if (TestRow.lessThan(descending, row, selected[0])) {
            selected[0] = row;
            siftDown(TestRow, selected[0..retained], descending, TestRow.lessThan);
        }
        for (selected[0..retained], 0..) |child, index| {
            if (index == 0) continue;
            try std.testing.expect(!TestRow.lessThan(descending, selected[(index - 1) / 2], child));
        }
    }
    std.mem.sort(TestRow, selected[0..retained], descending, TestRow.lessThan);
    try std.testing.expectEqualSlices(TestRow, expected[0..capacity], selected[0..retained]);
}

test "bounded selection preserves total ordering stable ties and all capacity boundaries" {
    for ([_]usize{ 0, 1, 2, 3, 16, 257 }) |count| {
        for ([_]usize{ 0, 1, 2, 3, 10, 100, 256, 257, 258 }) |limit| {
            try expectSelection(count, limit, false);
            try expectSelection(count, limit, true);
        }
    }
}
