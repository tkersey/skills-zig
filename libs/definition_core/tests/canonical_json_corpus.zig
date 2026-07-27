const std = @import("std");
const canonical_json = @import("canonical_json");

fn expectCanonicalParseClosure(canonical: []const u8) !void {
    var reparsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        canonical,
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer reparsed.deinit();
    const repeated = try canonical_json.canonicalJsonAlloc(std.testing.allocator, reparsed.value);
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(canonical, repeated);
}

test "broad deterministic f64 corpus is round-trip stable and byte locked" {
    const sample_count = 16_384;
    var state: u64 = 0x6a09e667f3bcc909;
    var finite_count: usize = 0;
    var nonfinite_count: usize = 0;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..sample_count) |_| {
        state +%= 0x9e3779b97f4a7c15;
        var bits = state;
        bits = (bits ^ (bits >> 30)) *% 0xbf58476d1ce4e5b9;
        bits = (bits ^ (bits >> 27)) *% 0x94d049bb133111eb;
        bits ^= bits >> 31;
        const number: f64 = @bitCast(bits);
        var bits_be: [8]u8 = undefined;
        std.mem.writeInt(u64, &bits_be, bits, .big);
        hasher.update(&bits_be);
        hasher.update(&.{0});
        if (!std.math.isFinite(number)) {
            nonfinite_count += 1;
            try std.testing.expectError(
                error.NonFiniteNumber,
                canonical_json.canonicalJsonAlloc(std.testing.allocator, .{ .float = number }),
            );
            hasher.update("nonfinite");
            hasher.update(&.{0xff});
            continue;
        }

        finite_count += 1;
        const encoded = try canonical_json.canonicalJsonAlloc(std.testing.allocator, .{ .float = number });
        defer std.testing.allocator.free(encoded);
        const reparsed = try std.fmt.parseFloat(f64, encoded);
        const expected_bits: u64 = if (number == 0) 0 else bits;
        try std.testing.expectEqual(expected_bits, @as(u64, @bitCast(reparsed)));
        const repeated = try canonical_json.canonicalJsonAlloc(std.testing.allocator, .{ .float = number });
        defer std.testing.allocator.free(repeated);
        try std.testing.expectEqualStrings(encoded, repeated);
        try expectCanonicalParseClosure(encoded);
        hasher.update(encoded);
        hasher.update(&.{0xff});
    }
    try std.testing.expectEqual(sample_count, finite_count + nonfinite_count);
    try std.testing.expect(nonfinite_count != 0);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "a6ee6f414fa52e60a8ca93eda2fad1bbed7f470ea29f716ad7a9a3ace69fa16a",
        &hex,
    );
}
