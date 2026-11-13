const std = @import("std");

pub const SessionInput = struct {
    source: *std.Io.Reader,
    compressed: ?*Compressed = null,

    pub fn isCompressed(path: []const u8) bool {
        return std.mem.endsWith(u8, path, ".jsonl.zst");
    }

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        source: *std.Io.Reader,
        max_input_bytes: usize,
    ) !SessionInput {
        if (!isCompressed(path)) return .{ .source = source };
        const compressed = try allocator.create(Compressed);
        errdefer allocator.destroy(compressed);
        const window = try allocator.alloc(u8, window_bytes);
        errdefer allocator.free(window);
        const buffer = try allocator.alloc(u8, input_buffer_bytes);
        errdefer allocator.free(buffer);
        compressed.* = .{
            .source = source,
            .encoded_limit = max_input_bytes *| 2 +| 1024 * 1024,
            .input = .{
                .vtable = &.{ .stream = Compressed.forward },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .decoder = undefined,
            .interface = .{
                .vtable = &.{ .stream = Compressed.stream },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
        compressed.decoder = .init(&compressed.input, window, .{
            .verify_checksum = false,
            .window_len = std.compress.zstd.default_window_len,
        });
        return .{ .source = source, .compressed = compressed };
    }

    pub fn reader(self: *SessionInput) *std.Io.Reader {
        return if (self.compressed) |compressed| &compressed.interface else self.source;
    }

    pub fn sourceError(self: *const SessionInput, err: anyerror) anyerror {
        const compressed = self.compressed orelse return err;
        if (err != error.ReadFailed) return err;
        const cause: anyerror = if (compressed.err) |value|
            value
        else if (compressed.decoder.err) |value|
            value
        else
            return err;
        return switch (cause) {
            error.OutputBufferUndersize,
            error.WindowOversize,
            error.WindowSizeUnknown,
            => error.CompressedSessionWindowExceeded,
            error.DictionaryIdFlagUnsupported => error.CompressedSessionDictionaryUnsupported,
            error.CompressedSessionInputByteBoundExceeded => cause,
            error.ReadFailed => err,
            else => error.InvalidCompressedSession,
        };
    }

    pub fn deinit(self: *SessionInput, allocator: std.mem.Allocator) void {
        if (self.compressed) |compressed| {
            allocator.free(compressed.decoder.reader.buffer);
            allocator.free(compressed.input.buffer);
            allocator.destroy(compressed);
        }
        self.* = undefined;
    }
};

const window_bytes = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;
const input_buffer_bytes = std.compress.zstd.block_size_max + 16;

const Compressed = struct {
    source: *std.Io.Reader,
    encoded_limit: usize,
    encoded_bytes: usize = 0,
    input: std.Io.Reader,
    decoder: std.compress.zstd.Decompress,
    interface: std.Io.Reader,
    hasher: std.hash.XxHash64 = .init(0),
    has_checksum: bool = false,
    saw_frame: bool = false,
    err: ?anyerror = null,

    fn forward(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *Compressed = @fieldParentPtr("input", reader);
        const remaining = self.encoded_limit -| self.encoded_bytes;
        const count = try self.source.stream(writer, limit.min(.limited(remaining +| 1)));
        self.encoded_bytes +|= count;
        if (self.encoded_bytes > self.encoded_limit) {
            self.err = error.CompressedSessionInputByteBoundExceeded;
            return error.ReadFailed;
        }
        return count;
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *Compressed = @fieldParentPtr("interface", reader);
        const decoded = &self.decoder.reader;
        if (decoded.bufferedLen() == 0) try self.decodeBlock();
        const bytes = limit.sliceConst(decoded.buffer[decoded.seek..decoded.end]);
        const count = try writer.write(bytes);
        decoded.seek += count;
        return count;
    }

    fn decodeBlock(self: *Compressed) std.Io.Reader.Error!void {
        if (self.decoder.state == .new_frame) try self.startFrame();
        var unused: std.Io.Writer.Discarding = .init(&.{});
        _ = self.decoder.reader.vtable.stream(
            &self.decoder.reader,
            &unused.writer,
            .unlimited,
        ) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            else => |failure| return failure,
        };
        const decoded = &self.decoder.reader;
        self.hasher.update(decoded.buffer[decoded.seek..decoded.end]);
        if (self.decoder.state == .new_frame and self.has_checksum) {
            std.debug.assert(self.input.seek >= @sizeOf(u32));
            const checksum_bytes = self.input.buffer[self.input.seek - @sizeOf(u32) ..][0..4];
            const expected = std.mem.readInt(u32, checksum_bytes, .little);
            const actual: u32 = @truncate(self.hasher.final());
            if (actual != expected) {
                self.err = error.ChecksumFailure;
                return error.ReadFailed;
            }
        }
    }

    fn startFrame(self: *Compressed) std.Io.Reader.Error!void {
        std.debug.assert(self.decoder.reader.bufferedLen() == 0);
        self.decoder.reader.seek = 0;
        self.decoder.reader.end = 0;
        const magic_bytes = self.input.peek(4) catch |err| {
            if (err == error.EndOfStream and self.input.bufferedLen() == 0 and self.saw_frame) {
                return error.EndOfStream;
            }
            self.err = self.err orelse if (err == error.EndOfStream) error.BadMagic else err;
            return error.ReadFailed;
        };
        const magic = std.mem.readInt(u32, magic_bytes[0..4], .little);
        self.has_checksum = false;
        self.hasher = .init(0);
        if (magic == 0xfd2fb528) {
            const header = self.input.peek(5) catch |err| {
                self.err = self.err orelse err;
                return error.ReadFailed;
            };
            self.has_checksum = header[4] & 4 != 0;
        }
        self.saw_frame = true;
    }
};

fn readInput(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var raw: std.Io.Reader = .fixed(compressed);
    var input = try SessionInput.init(allocator, "session.jsonl.zst", &raw, 1024 * 1024);
    defer input.deinit(allocator);
    return input.reader().allocRemaining(allocator, .limited(1024 * 1024)) catch |err|
        return input.sourceError(err);
}

test "compressed input streams a raw block and validates its checksum" {
    const source = "source\n";
    const prefix = "\x28\xb5\x2f\xfd\x24\x07\x39\x00\x00" ++ source;
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, @truncate(std.hash.XxHash64.hash(0, source)), .little);
    var frame: [prefix.len + 4]u8 = undefined;
    @memcpy(frame[0..prefix.len], prefix);
    @memcpy(frame[prefix.len..], &checksum);
    const result = try readInput(std.testing.allocator, &frame);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(source, result);
    var joined: [frame.len * 2]u8 = undefined;
    @memcpy(joined[0..frame.len], &frame);
    @memcpy(joined[frame.len..], &frame);
    const joined_result = try readInput(std.testing.allocator, &joined);
    defer std.testing.allocator.free(joined_result);
    try std.testing.expectEqualStrings(source ++ source, joined_result);
    frame[frame.len - 1] ^= 1;
    try std.testing.expectError(
        error.InvalidCompressedSession,
        readInput(std.testing.allocator, &frame),
    );
}

test "compressed input rejects truncated and non-frame sources" {
    for ([_][]const u8{
        "", "plain text", "\x28\xb5\x2f", "\x28\xb5\x2f\xfd\x20\x05\x29\x00\x00hi",
    }) |source| {
        try std.testing.expectError(
            error.InvalidCompressedSession,
            readInput(std.testing.allocator, source),
        );
    }
}

test "compressed input accepts concatenated and skippable frames" {
    const frame = "\x28\xb5\x2f\xfd\x20\x03\x19\x00\x00one";
    const skip = "\x50\x2a\x4d\x18\x02\x00\x00\x00xx";
    const result = try readInput(std.testing.allocator, frame ++ skip ++ frame);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("oneone", result);
}

test "compressed frames cannot borrow previous frame history" {
    const first = "\x28\xb5\x2f\xfd\x20\x07\x39\x00\x00abcdef\n";
    const invalid = "\x28\xb5\x2f\xfd\x20\x07\x3d\x00\x00" ++
        "\x00\x01\x54\x00\x02\x04\x05";
    for ([_][]const u8{ invalid, first ++ invalid }) |source| {
        try std.testing.expectError(
            error.InvalidCompressedSession,
            readInput(std.testing.allocator, source),
        );
    }
}

test "skippable frame input is bounded even when it produces no decoded bytes" {
    const encoded_limit = 1024 * 1024 + 2;
    const frame = try std.testing.allocator.alloc(u8, encoded_limit + 32);
    defer std.testing.allocator.free(frame);
    @memset(frame, 0);
    @memcpy(frame[0..4], "\x50\x2a\x4d\x18");
    std.mem.writeInt(u32, frame[4..8], @intCast(frame.len - 8), .little);
    var raw: std.Io.Reader = .fixed(frame);
    var input = try SessionInput.init(std.testing.allocator, "session.jsonl.zst", &raw, 1);
    defer input.deinit(std.testing.allocator);
    var buffer: [1]u8 = undefined;
    const result = input.reader().readSliceShort(&buffer) catch |err| {
        try std.testing.expectEqual(
            error.CompressedSessionInputByteBoundExceeded,
            input.sourceError(err),
        );
        try std.testing.expectEqual(encoded_limit + 1, input.compressed.?.encoded_bytes);
        return;
    };
    _ = result;
    return error.ExpectedCompressedInputBound;
}

test "small skippable frames keep the encoded input bound error" {
    const frame_count = 2 * 1024 * 1024 / 8;
    const source = try std.testing.allocator.alloc(u8, frame_count * 8);
    defer std.testing.allocator.free(source);
    for (0..frame_count) |index| {
        @memcpy(source[index * 8 ..][0..4], "\x50\x2a\x4d\x18");
        std.mem.writeInt(u32, source[index * 8 + 4 ..][0..4], 0, .little);
    }
    var raw: std.Io.Reader = .fixed(source);
    var input = try SessionInput.init(std.testing.allocator, "session.jsonl.zst", &raw, 1);
    defer input.deinit(std.testing.allocator);
    var buffer: [1]u8 = undefined;
    _ = input.reader().readSliceShort(&buffer) catch |err| {
        try std.testing.expectEqual(
            error.CompressedSessionInputByteBoundExceeded,
            input.sourceError(err),
        );
        return;
    };
    return error.ExpectedCompressedInputBound;
}

test "compressed input keeps the decompressed bound independent of frame size" {
    const frame = "\x28\xb5\x2f\xfd\x20\x64\x23\x03\x00x";
    var raw: std.Io.Reader = .fixed(frame);
    var input = try SessionInput.init(std.testing.allocator, "session.jsonl.zst", &raw, 32);
    defer input.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.StreamTooLong,
        input.reader().allocRemaining(std.testing.allocator, .limited(32)),
    );
}

fn consumeMultiblock(compressed: []const u8) !usize {
    const source = "{\"type\":\"event_msg\",\"payload\":" ++
        "{\"type\":\"agent_message\",\"message\":\"safe\"}}\n";
    var raw: std.Io.Reader = .fixed(compressed);
    var input = try SessionInput.init(
        std.testing.allocator,
        "multiblock.jsonl.zst",
        &raw,
        source.len * 150000,
    );
    defer input.deinit(std.testing.allocator);
    var chunk: [65536]u8 = undefined;
    var size: usize = 0;
    while (size <= source.len * 150000) {
        const count = input.reader().readSliceShort(&chunk) catch |err|
            return input.sourceError(err);
        if (count == 0) return size;
        for (chunk[0..count], size..) |byte, index| {
            try std.testing.expectEqual(source[index % source.len], byte);
        }
        size += count;
    }
    return error.UnexpectedOutputSize;
}

test "compressed blocks validate checksums after sliding-window rebases" {
    const allocator = std.testing.allocator;
    const fixture = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "libs/trace_core/testdata/compressed_multiblock.jsonl.zst",
        allocator,
        .limited(4096),
    );
    defer allocator.free(fixture);
    try std.testing.expectEqual(@as(usize, 10950000), try consumeMultiblock(fixture));
    fixture[fixture.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidCompressedSession, consumeMultiblock(fixture));
}

test "compressed input rejects windows and dictionaries outside its support" {
    try std.testing.expectError(
        error.CompressedSessionWindowExceeded,
        readInput(std.testing.allocator, "\x28\xb5\x2f\xfd\x00\x88\x01\x00\x00"),
    );
    try std.testing.expectError(
        error.CompressedSessionDictionaryUnsupported,
        readInput(std.testing.allocator, "\x28\xb5\x2f\xfd\x21\x01\x00\x01\x00\x00"),
    );
}

test "compressed input allocation failures clean up" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const decoded = try readInput(allocator, "\x28\xb5\x2f\xfd\x20\x03\x19\x00\x00one");
            defer allocator.free(decoded);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
