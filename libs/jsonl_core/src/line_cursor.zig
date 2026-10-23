const std = @import("std");

pub const Frame = struct {
    bytes: []const u8,
    terminated: bool,
};

pub const LineCursor = struct {
    start: usize = 0,
    scanned: usize = 0,
    frame_end: ?usize = null,
    frame_next: usize = 0,

    pub fn peek(self: *LineCursor, bytes: []const u8, eof: bool) ?Frame {
        std.debug.assert(self.start <= self.scanned);
        std.debug.assert(self.scanned <= bytes.len);
        if (self.frame_end) |end| {
            std.debug.assert(end <= bytes.len);
            return .{
                .bytes = bytes[self.start..end],
                .terminated = self.frame_next != end,
            };
        }
        if (std.mem.indexOfScalarPos(u8, bytes, self.scanned, '\n')) |end| {
            self.frame_end = end;
            self.frame_next = end + 1;
            return .{ .bytes = bytes[self.start..end], .terminated = true };
        }
        self.scanned = bytes.len;
        if (!eof or self.start == bytes.len) return null;
        self.frame_end = bytes.len;
        self.frame_next = bytes.len;
        return .{ .bytes = bytes[self.start..], .terminated = false };
    }

    pub fn consume(self: *LineCursor) void {
        std.debug.assert(self.frame_end != null);
        self.start = self.frame_next;
        self.scanned = self.start;
        self.frame_end = null;
    }

    pub fn compact(self: *LineCursor, bytes: []u8) usize {
        std.debug.assert(self.frame_end == null);
        std.debug.assert(self.start <= self.scanned);
        std.debug.assert(self.scanned <= bytes.len);
        const retained = bytes.len - self.start;
        if (self.start != 0) std.mem.copyForwards(u8, bytes[0..retained], bytes[self.start..]);
        self.scanned -= self.start;
        self.start = 0;
        self.frame_next = 0;
        return retained;
    }
};

test "line cursor retains unconsumed frames and exact delimiter semantics" {
    var cursor: LineCursor = .{};
    const input = "\nfirst\r\nlast";
    const empty = cursor.peek(input, false).?;
    try std.testing.expectEqualStrings("", empty.bytes);
    try std.testing.expect(empty.terminated);
    try std.testing.expectEqualDeep(empty, cursor.peek(input, false).?);
    cursor.consume();
    const first = cursor.peek(input, false).?;
    try std.testing.expectEqualStrings("first\r", first.bytes);
    try std.testing.expect(first.terminated);
    cursor.consume();
    try std.testing.expect(cursor.peek(input, false) == null);
    const last = cursor.peek(input, true).?;
    try std.testing.expectEqualStrings("last", last.bytes);
    try std.testing.expect(!last.terminated);
    cursor.consume();
    try std.testing.expect(cursor.peek(input, true) == null);
}

test "line cursor compact preserves incomplete suffix and scan position" {
    var input = "first\nsecond".*;
    var cursor: LineCursor = .{};
    try std.testing.expectEqualStrings("first", cursor.peek(&input, false).?.bytes);
    cursor.consume();
    try std.testing.expect(cursor.peek(&input, false) == null);
    const retained = cursor.compact(&input);
    try std.testing.expectEqualStrings("second", input[0..retained]);
    try std.testing.expectEqual(retained, cursor.scanned);
    input[retained] = '\n';
    try std.testing.expectEqualStrings(
        "second",
        cursor.peek(input[0 .. retained + 1], false).?.bytes,
    );
    cursor.consume();
    try std.testing.expect(cursor.peek(input[0 .. retained + 1], true) == null);
    try std.testing.expectEqual(@as(usize, 0), cursor.compact(input[0 .. retained + 1]));
}

test "line cursor agrees with delimiter splitting across every chunk boundary" {
    const input = "\nalpha\nbeta\r\n\nlast";
    for (1..input.len + 1) |chunk_size| {
        var cursor: LineCursor = .{};
        var offset: usize = 0;
        var expected: usize = 0;
        var next: usize = 0;
        while (next < input.len) {
            next = @min(input.len, next + chunk_size);
            while (cursor.peek(input[0..next], next == input.len)) |frame| {
                const end = std.mem.indexOfScalarPos(u8, input, offset, '\n') orelse input.len;
                try std.testing.expectEqualStrings(input[offset..end], frame.bytes);
                try std.testing.expectEqual(end != input.len, frame.terminated);
                offset = end + @intFromBool(frame.terminated);
                expected += 1;
                cursor.consume();
            }
        }
        try std.testing.expectEqual(@as(usize, 5), expected);
        try std.testing.expectEqual(input.len, offset);
    }
}
