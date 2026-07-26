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
    return allocator.dupe(u8, payload);
}

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
