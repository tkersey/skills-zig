const std = @import("std");

pub const chunk_size: usize = 64 * 1024;
// Preserve the former whole-file reader's accepted single-record envelope
// while removing its aggregate source-size ceiling.
pub const default_max_line_bytes: usize = 256 * 1024 * 1024;

pub const Options = struct {
    max_line_bytes: usize = default_max_line_bytes,
};

pub const Line = struct {
    bytes: []const u8,
    number: usize,
};

/// Delivers newline-delimited records in source order without imposing an
/// aggregate source-size ceiling. Returned bytes remain valid until the next
/// call to `next` or `deinit`.
pub const Stream = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_line_bytes: usize,
    line: std.ArrayList(u8) = .empty,
    chunk: [chunk_size]u8 = undefined,
    chunk_pos: usize = 0,
    chunk_len: usize = 0,
    line_number: usize = 0,
    bytes_read: usize = 0,
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
        };
    }

    pub fn deinit(self: *Stream) void {
        self.line.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn next(self: *Stream) !?Line {
        self.line.clearRetainingCapacity();

        while (true) {
            if (self.chunk_pos < self.chunk_len) {
                const remaining = self.chunk[self.chunk_pos..self.chunk_len];
                if (std.mem.indexOfScalar(u8, remaining, '\n')) |newline_rel| {
                    try self.append(remaining[0..newline_rel]);
                    self.chunk_pos += newline_rel + 1;
                    self.line_number += 1;
                    return .{ .bytes = self.line.items, .number = self.line_number };
                }
                try self.append(remaining);
                self.chunk_pos = self.chunk_len;
            }

            if (self.eof) {
                if (self.line.items.len == 0) return null;
                self.line_number += 1;
                return .{ .bytes = self.line.items, .number = self.line_number };
            }

            self.chunk_len = try self.reader.readSliceShort(self.chunk[0..]);
            self.chunk_pos = 0;
            self.bytes_read += self.chunk_len;
            if (self.chunk_len == 0) self.eof = true;
        }
    }

    fn append(self: *Stream, bytes: []const u8) !void {
        if (bytes.len > self.max_line_bytes -| self.line.items.len) {
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
