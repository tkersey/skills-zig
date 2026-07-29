const std = @import("std");

pub const format_version: u16 = 1;
pub const magic = "DFNCCH1\x00";
pub const header_bytes: usize = 8 + 2 + 8 + 32 + 32 + 32;

pub const Limits = struct {
    max_payload_bytes: usize = 64 * 1024 * 1024,
    max_entry_bytes: usize = 64 * 1024 * 1024 + header_bytes,
};

pub fn key(parts: []const []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("compiled-definition-cache-key/v1\x00");
    var length: [8]u8 = undefined;
    for (parts) |part| {
        std.mem.writeInt(u64, &length, @intCast(part.len), .big);
        hasher.update(&length);
        hasher.update(part);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn keyHex(cache_key: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(cache_key, .lower);
}

pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    cache_key: [32]u8,
    payload: []const u8,
    limits: Limits,
) ![]u8 {
    if (payload.len > limits.max_payload_bytes) return error.CachePayloadTooLarge;
    const entry_len = std.math.add(usize, header_bytes, payload.len) catch
        return error.CacheEntryTooLarge;
    if (entry_len > limits.max_entry_bytes) return error.CacheEntryTooLarge;

    const entry = try allocator.alloc(u8, entry_len);
    errdefer allocator.free(entry);
    @memcpy(entry[0..8], magic);
    std.mem.writeInt(u16, entry[8..10], format_version, .big);
    std.mem.writeInt(u64, entry[10..18], @intCast(payload.len), .big);
    @memcpy(entry[18..50], &cache_key);
    var payload_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &payload_digest, .{});
    @memcpy(entry[50..82], &payload_digest);
    var header_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(entry[0..82], &header_digest, .{});
    @memcpy(entry[82..114], &header_digest);
    @memcpy(entry[header_bytes..], payload);
    return entry;
}

pub fn decodeAlloc(
    allocator: std.mem.Allocator,
    expected_key: [32]u8,
    entry: []const u8,
    limits: Limits,
) ![]u8 {
    return allocator.dupe(
        u8,
        try decode(expected_key, entry, limits),
    );
}

pub fn decode(
    expected_key: [32]u8,
    entry: []const u8,
    limits: Limits,
) ![]const u8 {
    if (entry.len < header_bytes) return error.CacheEntryTruncated;
    if (entry.len > limits.max_entry_bytes) return error.CacheEntryTooLarge;
    if (!std.mem.eql(u8, entry[0..8], magic)) return error.CacheMagicMismatch;
    if (std.mem.readInt(u16, entry[8..10], .big) != format_version) {
        return error.CacheFormatMismatch;
    }
    const payload_len_u64 = std.mem.readInt(u64, entry[10..18], .big);
    const payload_len = std.math.cast(usize, payload_len_u64) orelse
        return error.CachePayloadTooLarge;
    if (payload_len > limits.max_payload_bytes) return error.CachePayloadTooLarge;
    if (entry.len != header_bytes + payload_len) return error.CacheLengthMismatch;
    if (!std.mem.eql(u8, entry[18..50], &expected_key)) return error.CacheKeyMismatch;

    var computed_header_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(entry[0..82], &computed_header_digest, .{});
    if (!std.mem.eql(u8, entry[82..114], &computed_header_digest)) {
        return error.CacheHeaderChecksumMismatch;
    }
    const payload = entry[header_bytes..];
    var computed_payload_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &computed_payload_digest, .{});
    if (!std.mem.eql(u8, entry[50..82], &computed_payload_digest)) {
        return error.CachePayloadChecksumMismatch;
    }
    return payload;
}

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    output: std.Io.Writer.Allocating,
    max_bytes: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) Encoder {
        return .{
            .allocator = allocator,
            .output = .init(allocator),
            .max_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.output.deinit();
        self.* = undefined;
    }

    pub fn written(self: *Encoder) []const u8 {
        return self.output.written();
    }

    pub fn toOwnedSlice(self: *Encoder) ![]u8 {
        return self.output.toOwnedSlice();
    }

    pub fn writeByte(self: *Encoder, value: u8) !void {
        try self.ensureCapacity(1);
        try self.output.writer.writeByte(value);
    }

    pub fn writeBool(self: *Encoder, value: bool) !void {
        try self.writeByte(if (value) 1 else 0);
    }

    pub fn writeU16(self: *Encoder, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .big);
        try self.writeFixed(&bytes);
    }

    pub fn writeU32(self: *Encoder, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .big);
        try self.writeFixed(&bytes);
    }

    pub fn writeU64(self: *Encoder, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .big);
        try self.writeFixed(&bytes);
    }

    pub fn writeU128(self: *Encoder, value: u128) !void {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &bytes, value, .big);
        try self.writeFixed(&bytes);
    }

    pub fn writeI64(self: *Encoder, value: i64) !void {
        try self.writeU64(@bitCast(value));
    }

    pub fn writeF64(self: *Encoder, value: f64) !void {
        try self.writeU64(@bitCast(value));
    }

    pub fn writeUsize(self: *Encoder, value: usize) !void {
        try self.writeU64(@intCast(value));
    }

    pub fn writeCount(self: *Encoder, value: usize) !void {
        try self.writeU32(std.math.cast(u32, value) orelse
            return error.CacheCountTooLarge);
    }

    pub fn writeEnum(self: *Encoder, value: anytype) !void {
        const tag = @intFromEnum(value);
        try self.writeU16(std.math.cast(u16, tag) orelse
            return error.CacheEnumOutOfRange);
    }

    pub fn writeBytes(self: *Encoder, value: []const u8) !void {
        try self.writeCount(value.len);
        try self.writeFixed(value);
    }

    pub fn writeOptionalBytes(
        self: *Encoder,
        value: ?[]const u8,
    ) !void {
        try self.writeBool(value != null);
        if (value) |bytes| try self.writeBytes(bytes);
    }

    pub fn writeFixed(self: *Encoder, value: []const u8) !void {
        try self.ensureCapacity(value.len);
        try self.output.writer.writeAll(value);
    }

    fn ensureCapacity(self: *Encoder, additional: usize) !void {
        const next = std.math.add(
            usize,
            self.output.written().len,
            additional,
        ) catch return error.CachePayloadTooLarge;
        if (next > self.max_bytes) return error.CachePayloadTooLarge;
    }
};

pub const Decoder = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn init(bytes: []const u8) Decoder {
        return .{ .bytes = bytes };
    }

    pub fn finish(self: *const Decoder) !void {
        if (self.cursor != self.bytes.len) return error.CachePayloadTrailingBytes;
    }

    pub fn readByte(self: *Decoder) !u8 {
        return (try self.readFixed(1))[0];
    }

    pub fn readBool(self: *Decoder) !bool {
        return switch (try self.readByte()) {
            0 => false,
            1 => true,
            else => error.CacheBooleanInvalid,
        };
    }

    pub fn readU16(self: *Decoder) !u16 {
        const bytes = try self.readFixed(2);
        const fixed: *const [2]u8 = @ptrCast(bytes.ptr);
        return std.mem.readInt(u16, fixed, .big);
    }

    pub fn readU32(self: *Decoder) !u32 {
        const bytes = try self.readFixed(4);
        const fixed: *const [4]u8 = @ptrCast(bytes.ptr);
        return std.mem.readInt(u32, fixed, .big);
    }

    pub fn readU64(self: *Decoder) !u64 {
        const bytes = try self.readFixed(8);
        const fixed: *const [8]u8 = @ptrCast(bytes.ptr);
        return std.mem.readInt(u64, fixed, .big);
    }

    pub fn readU128(self: *Decoder) !u128 {
        const bytes = try self.readFixed(16);
        const fixed: *const [16]u8 = @ptrCast(bytes.ptr);
        return std.mem.readInt(u128, fixed, .big);
    }

    pub fn readI64(self: *Decoder) !i64 {
        return @bitCast(try self.readU64());
    }

    pub fn readF64(self: *Decoder) !f64 {
        return @bitCast(try self.readU64());
    }

    pub fn readUsize(self: *Decoder) !usize {
        return std.math.cast(usize, try self.readU64()) orelse
            return error.CacheIntegerOutOfRange;
    }

    pub fn readCount(self: *Decoder, maximum: usize) !usize {
        const count: usize = @intCast(try self.readU32());
        if (count > maximum) return error.CacheCountTooLarge;
        return count;
    }

    pub fn readEnum(self: *Decoder, comptime Enum: type) !Enum {
        if (@typeInfo(Enum) != .@"enum") {
            @compileError("cache enum decoder requires an enum type");
        }
        const raw = try self.readU16();
        inline for (@typeInfo(Enum).@"enum".fields) |field| {
            if (field.value == raw) return @enumFromInt(raw);
        }
        return error.CacheEnumInvalid;
    }

    pub fn readBytesAlloc(
        self: *Decoder,
        allocator: std.mem.Allocator,
        maximum: usize,
    ) ![]u8 {
        const length = try self.readCount(maximum);
        return allocator.dupe(u8, try self.readFixed(length));
    }

    pub fn readOptionalBytesAlloc(
        self: *Decoder,
        allocator: std.mem.Allocator,
        maximum: usize,
    ) !?[]u8 {
        if (!try self.readBool()) return null;
        return try self.readBytesAlloc(allocator, maximum);
    }

    pub fn readFixed(self: *Decoder, length: usize) ![]const u8 {
        const end = std.math.add(usize, self.cursor, length) catch
            return error.CachePayloadTruncated;
        if (end > self.bytes.len) return error.CachePayloadTruncated;
        const value = self.bytes[self.cursor..end];
        self.cursor = end;
        return value;
    }
};

test "cache entry is content addressed and rejects stale or corrupt bytes" {
    const first_key = key(&.{
        "runtime-abi/v1",
        "1.0.0",
        "adapter/v1",
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    });
    const second_key = key(&.{
        "runtime-abi/v1",
        "1.0.0",
        "adapter/v2",
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    });
    const encoded = try encodeAlloc(
        std.testing.allocator,
        first_key,
        "compiled-plan",
        .{},
    );
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeAlloc(std.testing.allocator, first_key, encoded, .{});
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("compiled-plan", decoded);
    try std.testing.expectError(
        error.CacheKeyMismatch,
        decodeAlloc(std.testing.allocator, second_key, encoded, .{}),
    );

    const corrupt = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupt);
    corrupt[header_bytes] ^= 0xff;
    try std.testing.expectError(
        error.CachePayloadChecksumMismatch,
        decodeAlloc(std.testing.allocator, first_key, corrupt, .{}),
    );
}

test "bounded cache codec round trips scalars and rejects malformed payloads" {
    var encoder = Encoder.init(std.testing.allocator, 1024);
    defer encoder.deinit();
    try encoder.writeBool(true);
    try encoder.writeU16(513);
    try encoder.writeU32(70_000);
    try encoder.writeU64(9_000_000_000);
    try encoder.writeI64(-42);
    try encoder.writeF64(1.25);
    try encoder.writeBytes("compiled");
    try encoder.writeOptionalBytes(null);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);

    var decoder = Decoder.init(payload);
    try std.testing.expect(try decoder.readBool());
    try std.testing.expectEqual(@as(u16, 513), try decoder.readU16());
    try std.testing.expectEqual(@as(u32, 70_000), try decoder.readU32());
    try std.testing.expectEqual(
        @as(u64, 9_000_000_000),
        try decoder.readU64(),
    );
    try std.testing.expectEqual(@as(i64, -42), try decoder.readI64());
    try std.testing.expectEqual(@as(f64, 1.25), try decoder.readF64());
    const text = try decoder.readBytesAlloc(std.testing.allocator, 16);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("compiled", text);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try decoder.readOptionalBytesAlloc(std.testing.allocator, 16),
    );
    try decoder.finish();

    var truncated = Decoder.init(payload[0 .. payload.len - 1]);
    _ = try truncated.readBool();
    _ = try truncated.readU16();
    _ = try truncated.readU32();
    _ = try truncated.readU64();
    _ = try truncated.readI64();
    _ = try truncated.readF64();
    const truncated_text = try truncated.readBytesAlloc(
        std.testing.allocator,
        16,
    );
    defer std.testing.allocator.free(truncated_text);
    try std.testing.expectError(
        error.CachePayloadTruncated,
        truncated.readOptionalBytesAlloc(std.testing.allocator, 16),
    );

    var invalid_bool = Decoder.init(&.{2});
    try std.testing.expectError(
        error.CacheBooleanInvalid,
        invalid_bool.readBool(),
    );
    var bounded = Encoder.init(std.testing.allocator, 1);
    defer bounded.deinit();
    try std.testing.expectError(
        error.CachePayloadTooLarge,
        bounded.writeU16(1),
    );
}
