const std = @import("std");

pub const chunk_size: usize = 64 * 1024;
// Preserve the former whole-file reader's accepted single-record envelope
// while removing its aggregate source-size ceiling.
pub const default_max_line_bytes: usize = 256 * 1024 * 1024;

pub const Options = struct {
    max_line_bytes: usize = default_max_line_bytes,
    chunk_observer: ?ChunkObserver = null,
};

pub const ChunkObserver = struct {
    context: *anyopaque,
    observeFn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn observe(self: ChunkObserver, bytes: []const u8) !void {
        try self.observeFn(self.context, bytes);
    }
};

pub const Line = struct {
    bytes: []const u8,
    number: usize,
    start_offset: usize,
    end_offset: usize,
};

/// Delivers newline-delimited records in source order without imposing an
/// aggregate source-size ceiling. Returned bytes remain valid until the next
/// call to `next` or `deinit`.
pub const Stream = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_line_bytes: usize,
    chunk_observer: ?ChunkObserver,
    line: std.ArrayList(u8) = .empty,
    chunk: [chunk_size]u8 = undefined,
    chunk_pos: usize = 0,
    chunk_len: usize = 0,
    line_number: usize = 0,
    bytes_read: usize = 0,
    line_start_offset: usize = 0,
    eof: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        options: Options,
    ) !Stream {
        if (options.max_line_bytes == 0) return error.InvalidMaxLineBytes;
        return .{
            .allocator = allocator,
            .reader = reader,
            .max_line_bytes = options.max_line_bytes,
            .chunk_observer = options.chunk_observer,
        };
    }

    pub fn deinit(self: *Stream) void {
        self.line.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn next(self: *Stream) !?Line {
        self.line.clearRetainingCapacity();
        // readSliceShort fills a chunk unless EOF is reached. Allow the current
        // partial chunk, every full chunk in one record, and the final EOF check.
        var chunks_left = self.max_line_bytes / chunk_size + 3;
        while (chunks_left > 0) : (chunks_left -= 1) {
            std.debug.assert(self.chunk_pos <= self.chunk_len);
            std.debug.assert(self.chunk_len <= self.chunk.len);
            if (self.chunk_pos < self.chunk_len) {
                const remaining = self.chunk[self.chunk_pos..self.chunk_len];
                if (std.mem.indexOfScalar(u8, remaining, '\n')) |newline_rel| {
                    try self.append(remaining[0..newline_rel]);
                    const record = try self.finishLine(true);
                    self.chunk_pos += newline_rel + 1;
                    return record;
                }
                try self.append(remaining);
                self.chunk_pos = self.chunk_len;
            }
            if (self.eof) {
                if (self.line.items.len == 0) return null;
                return try self.finishLine(false);
            }
            self.chunk_len = try self.reader.readSliceShort(self.chunk[0..]);
            self.chunk_pos = 0;
            self.bytes_read = std.math.add(usize, self.bytes_read, self.chunk_len) catch
                return error.SourceOffsetOverflow;
            if (self.chunk_observer) |observer| {
                try observer.observe(self.chunk[0..self.chunk_len]);
            }
            if (self.chunk_len == 0) self.eof = true;
        }
        return error.LineTooLong;
    }

    fn finishLine(self: *Stream, terminated: bool) !Line {
        std.debug.assert(self.line.items.len <= self.max_line_bytes);
        const number = std.math.add(usize, self.line_number, 1) catch
            return error.SourceLineOverflow;
        const end_offset = std.math.add(usize, self.line_start_offset, self.line.items.len) catch
            return error.SourceOffsetOverflow;
        const next_offset = std.math.add(usize, end_offset, @intFromBool(terminated)) catch
            return error.SourceOffsetOverflow;
        const record = Line{
            .bytes = self.line.items,
            .number = number,
            .start_offset = self.line_start_offset,
            .end_offset = end_offset,
        };
        self.line_number = number;
        self.line_start_offset = next_offset;
        return record;
    }

    fn append(self: *Stream, bytes: []const u8) !void {
        std.debug.assert(self.line.items.len <= self.max_line_bytes);
        if (bytes.len > self.max_line_bytes - self.line.items.len) {
            return error.LineTooLong;
        }
        try self.line.appendSlice(self.allocator, bytes);
    }
};

test "stream preserves chunk-spanning and unterminated records" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendNTimes(std.testing.allocator, 'a', chunk_size + 17);
    try source.append(std.testing.allocator, '\n');
    try source.appendSlice(std.testing.allocator, "last");

    var reader = std.Io.Reader.fixed(source.items);
    var stream = try Stream.init(std.testing.allocator, &reader, .{});
    defer stream.deinit();

    const first = (try stream.next()).?;
    try std.testing.expectEqual(@as(usize, 1), first.number);
    try std.testing.expectEqual(@as(usize, chunk_size + 17), first.bytes.len);
    try std.testing.expect(std.mem.allEqual(u8, first.bytes, 'a'));

    const second = (try stream.next()).?;
    try std.testing.expectEqual(@as(usize, 2), second.number);
    try std.testing.expectEqualStrings("last", second.bytes);
    try std.testing.expect((try stream.next()) == null);
    try std.testing.expectEqual(source.items.len, stream.bytes_read);
}

test "stream preserves empty records and trailing delimiter" {
    var reader = std.Io.Reader.fixed("\nvalue\n");
    var stream = try Stream.init(std.testing.allocator, &reader, .{});
    defer stream.deinit();

    const empty = (try stream.next()).?;
    try std.testing.expectEqual(@as(usize, 1), empty.number);
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);

    const value = (try stream.next()).?;
    try std.testing.expectEqual(@as(usize, 2), value.number);
    try std.testing.expectEqualStrings("value", value.bytes);
    try std.testing.expect((try stream.next()) == null);
}

test "stream rejects only an oversized record" {
    var reader = std.Io.Reader.fixed("12345\n");
    var stream = try Stream.init(std.testing.allocator, &reader, .{ .max_line_bytes = 4 });
    defer stream.deinit();

    try std.testing.expectError(error.LineTooLong, stream.next());
}

test "stream observes each raw byte exactly once" {
    const Observer = struct {
        bytes: std.ArrayList(u8) = .empty,

        fn observe(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.bytes.appendSlice(std.testing.allocator, bytes);
        }
    };
    var observer = Observer{};
    defer observer.bytes.deinit(std.testing.allocator);
    var reader = std.Io.Reader.fixed("first\n\nlast");
    var stream = try Stream.init(std.testing.allocator, &reader, .{
        .chunk_observer = .{ .context = &observer, .observeFn = Observer.observe },
    });
    defer stream.deinit();
    while (try stream.next()) |_| {}
    try std.testing.expectEqualStrings("first\n\nlast", observer.bytes.items);
}

test "stream accepts exact record limits with and without a delimiter" {
    const allocator = std.testing.allocator;
    const lengths = [_]usize{ 1, chunk_size - 1, chunk_size, chunk_size + 1 };
    for (lengths) |length| {
        const input = try allocator.alloc(u8, length + 1);
        defer allocator.free(input);
        @memset(input[0..length], 'a');
        input[length] = '\n';
        for ([_]bool{ false, true }) |terminated| {
            var reader = std.Io.Reader.fixed(input[0 .. length + @intFromBool(terminated)]);
            var stream = try Stream.init(allocator, &reader, .{ .max_line_bytes = length });
            defer stream.deinit();
            const record = (try stream.next()).?;
            try std.testing.expectEqual(length, record.bytes.len);
            try std.testing.expectEqual(@as(usize, 0), record.start_offset);
            try std.testing.expectEqual(length, record.end_offset);
            try std.testing.expect((try stream.next()) == null);
        }
    }
}

test "stream reports counter exhaustion without wrapping provenance" {
    var reader = std.Io.Reader.fixed("x\n");
    var stream = try Stream.init(std.testing.allocator, &reader, .{});
    defer stream.deinit();
    stream.line_number = std.math.maxInt(usize);
    try std.testing.expectError(error.SourceLineOverflow, stream.next());
    try std.testing.expectEqual(std.math.maxInt(usize), stream.line_number);
    stream.line_number = 0;
    stream.line_start_offset = std.math.maxInt(usize);
    try std.testing.expectError(error.SourceOffsetOverflow, stream.next());
    try std.testing.expectEqual(@as(usize, 0), stream.line_number);
}
