const std = @import("std");
const jsonl_stream = @import("jsonl_stream");

const RepeatingReader = struct {
    pattern: []const u8,
    remaining: usize,
    pattern_pos: usize = 0,
    interface: std.Io.Reader,

    fn init(pattern: []const u8, repeat_count: usize) RepeatingReader {
        return .{
            .pattern = pattern,
            .remaining = pattern.len * repeat_count,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *RepeatingReader = @fieldParentPtr("interface", reader);
        if (self.remaining == 0) return error.EndOfStream;

        var allowed = @min(@as(usize, @intFromEnum(limit)), self.remaining);
        var written: usize = 0;
        while (allowed > 0) {
            const available = self.pattern.len - self.pattern_pos;
            const requested = @min(available, allowed);
            const n = try writer.write(self.pattern[self.pattern_pos .. self.pattern_pos + requested]);
            self.pattern_pos = (self.pattern_pos + n) % self.pattern.len;
            self.remaining -= n;
            allowed -= n;
            written += n;
            if (n < requested) break;
        }
        return written;
    }
};

test "stream has no aggregate source-size ceiling" {
    const old_aggregate_limit = 256 * 1024 * 1024;
    var pattern: [jsonl_stream.chunk_size]u8 = @splat(' ');
    pattern[pattern.len - 1] = '\n';
    const repeat_count = (old_aggregate_limit / pattern.len) + 1;

    var source = RepeatingReader.init(&pattern, repeat_count);
    var records = try jsonl_stream.Stream.init(std.testing.allocator, &source.interface, .{});
    defer records.deinit();

    var count: usize = 0;
    while (try records.next()) |record| {
        try std.testing.expectEqual(pattern.len - 1, record.bytes.len);
        count += 1;
    }

    try std.testing.expectEqual(repeat_count, count);
    try std.testing.expect(records.bytes_read > old_aggregate_limit);
}
