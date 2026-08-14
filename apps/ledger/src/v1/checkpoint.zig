const std = @import("std");

pub const max_checkpoint_bytes: usize = 128 * 1024 * 1024;
pub const max_collection_items: usize = 10_000_000;

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Encoder) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn toOwnedSlice(self: *Encoder) ![]u8 {
        return self.bytes.toOwnedSlice(self.allocator);
    }

    pub fn writeBool(self: *Encoder, value: bool) !void {
        try self.writeByte(@intFromBool(value));
    }

    pub fn writeU64(self: *Encoder, value: u64) !void {
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, value, .big);
        try self.append(&encoded);
    }

    pub fn writeBytes(self: *Encoder, value: []const u8) !void {
        try self.writeU64(@intCast(value.len));
        try self.append(value);
    }

    pub fn writeOptionalBytes(
        self: *Encoder,
        value: ?[]const u8,
    ) !void {
        try self.writeBool(value != null);
        if (value) |bytes| try self.writeBytes(bytes);
    }

    fn writeByte(self: *Encoder, value: u8) !void {
        if (self.bytes.items.len == max_checkpoint_bytes) {
            return error.CheckpointBoundsExceeded;
        }
        try self.bytes.append(self.allocator, value);
    }

    fn append(self: *Encoder, value: []const u8) !void {
        const next = std.math.add(
            usize,
            self.bytes.items.len,
            value.len,
        ) catch return error.CheckpointBoundsExceeded;
        if (next > max_checkpoint_bytes) {
            return error.CheckpointBoundsExceeded;
        }
        try self.bytes.appendSlice(self.allocator, value);
    }
};

pub const Decoder = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) !Decoder {
        if (bytes.len > max_checkpoint_bytes) {
            return error.CheckpointBoundsExceeded;
        }
        return .{ .bytes = bytes };
    }

    pub fn finish(self: *const Decoder) !void {
        if (self.offset != self.bytes.len) {
            return error.CheckpointTrailingBytes;
        }
    }

    pub fn readBool(self: *Decoder) !bool {
        return switch (try self.readByte()) {
            0 => false,
            1 => true,
            else => error.CheckpointInvalidBoolean,
        };
    }

    pub fn readU64(self: *Decoder) !u64 {
        const encoded = try self.readExact(8);
        return std.mem.readInt(u64, encoded[0..8], .big);
    }

    pub fn readCount(self: *Decoder, maximum: usize) !usize {
        const value = try self.readUsize();
        if (value > maximum or value > max_collection_items) {
            return error.CheckpointBoundsExceeded;
        }
        return value;
    }

    pub fn readCountBoundedByRemaining(
        self: *Decoder,
        maximum: usize,
        minimum_item_bytes: usize,
    ) !usize {
        std.debug.assert(minimum_item_bytes > 0);
        const value = try self.readCount(maximum);
        if (value > self.remainingBytes() / minimum_item_bytes) {
            return error.CheckpointBoundsExceeded;
        }
        return value;
    }

    pub fn remainingBytes(self: *const Decoder) usize {
        return self.bytes.len - self.offset;
    }

    pub fn readBoundedUsize(
        self: *Decoder,
        maximum: usize,
    ) !usize {
        const value = try self.readUsize();
        if (value > maximum) return error.CheckpointBoundsExceeded;
        return value;
    }

    pub fn readUsize(self: *Decoder) !usize {
        return std.math.cast(usize, try self.readU64()) orelse
            error.CheckpointBoundsExceeded;
    }

    pub fn readBytes(self: *Decoder, maximum: usize) ![]const u8 {
        const length = try self.readBoundedUsize(maximum);
        return self.readExact(length);
    }

    pub fn readOptionalBytes(
        self: *Decoder,
        maximum: usize,
    ) !?[]const u8 {
        return if (try self.readBool())
            try self.readBytes(maximum)
        else
            null;
    }

    fn readByte(self: *Decoder) !u8 {
        const result = try self.readExact(1);
        return result[0];
    }

    fn readExact(self: *Decoder, length: usize) ![]const u8 {
        const end = std.math.add(usize, self.offset, length) catch
            return error.CheckpointTruncated;
        if (end > self.bytes.len) return error.CheckpointTruncated;
        const result = self.bytes[self.offset..end];
        self.offset = end;
        return result;
    }
};

test "checkpoint codec rejects truncation and trailing bytes" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.writeBytes("state");
    const encoded = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(encoded);

    var complete = try Decoder.init(encoded);
    try std.testing.expectEqualStrings("state", try complete.readBytes(5));
    try complete.finish();

    var truncated = try Decoder.init(encoded[0 .. encoded.len - 1]);
    try std.testing.expectError(
        error.CheckpointTruncated,
        truncated.readBytes(5),
    );

    var trailing = try Decoder.init("\x00\x00\x00\x00\x00\x00\x00\x00x");
    _ = try trailing.readBytes(0);
    try std.testing.expectError(
        error.CheckpointTrailingBytes,
        trailing.finish(),
    );
}

test "segmented checkpoint count is bounded before allocation" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.writeU64(1_000_000);
    const encoded = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(encoded);
    var decoder = try Decoder.init(encoded);
    try std.testing.expectError(
        error.CheckpointBoundsExceeded,
        decoder.readCountBoundedByRemaining(max_collection_items, 8),
    );
}
