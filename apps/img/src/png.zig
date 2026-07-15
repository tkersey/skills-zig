const std = @import("std");

pub const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

fn writeChunk(writer: *std.Io.Writer, chunk_type: *const [4]u8, data: []const u8) !void {
    if (data.len > std.math.maxInt(u32)) return error.ChunkTooLarge;
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(chunk_type);
    try writer.writeAll(data);

    var crc: std.hash.Crc32 = .init();
    crc.update(chunk_type);
    crc.update(data);
    try writer.writeInt(u32, crc.final(), .big);
}

fn compressScanlines(
    allocator: std.mem.Allocator,
    grayscale: []const u8,
    width: usize,
    height: usize,
) ![]u8 {
    var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer compressed.deinit();

    const history = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(history);

    var deflater = try std.compress.flate.Compress.init(
        &compressed.writer,
        history,
        .zlib,
        .default,
    );
    for (0..height) |row| {
        try deflater.writer.writeByte(0); // PNG filter: None
        try deflater.writer.writeAll(grayscale[row * width ..][0..width]);
    }
    try deflater.finish();
    return compressed.toOwnedSlice();
}

/// Encode an 8-bit, non-interlaced grayscale PNG. It deliberately emits one
/// IDAT chunk and filter type 0 for every row, matching pxpipe's observable PNG
/// structure while leaving compressed bytes implementation-specific.
pub fn encodeGrayscale(
    allocator: std.mem.Allocator,
    grayscale: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    const pixel_count = std.math.mul(usize, width, height) catch return error.ImageTooLarge;
    if (grayscale.len != pixel_count) return error.InvalidPixelCount;
    if (width == 0 or height == 0) return error.InvalidDimensions;

    const idat = try compressScanlines(allocator, grayscale, width, height);
    defer allocator.free(idat);

    var ihdr: [13]u8 = @splat(0);
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 0; // grayscale

    const initial_capacity = std.math.add(usize, idat.len, 57) catch return error.ImageTooLarge;
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, initial_capacity);
    defer output.deinit();
    try output.writer.writeAll(&signature);
    try writeChunk(&output.writer, "IHDR", &ihdr);
    try writeChunk(&output.writer, "IDAT", idat);
    try writeChunk(&output.writer, "IEND", &.{});
    return output.toOwnedSlice();
}

test "grayscale PNG has one valid IDAT with filter zero" {
    const pixels = [_]u8{ 0, 127, 255, 64 };
    const encoded = try encodeGrayscale(std.testing.allocator, &pixels, 2, 2);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &signature, encoded[0..signature.len]);
    var chunk_offset: usize = signature.len;
    while (chunk_offset < encoded.len) {
        const chunk_length: usize = @intCast(std.mem.readInt(u32, encoded[chunk_offset..][0..4], .big));
        const crc_start = chunk_offset + 4;
        const crc_end = crc_start + 4 + chunk_length;
        try std.testing.expectEqual(
            std.hash.Crc32.hash(encoded[crc_start..crc_end]),
            std.mem.readInt(u32, encoded[crc_end..][0..4], .big),
        );
        chunk_offset = crc_end + 4;
    }
    try std.testing.expectEqual(encoded.len, chunk_offset);
    try std.testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, encoded[8..12], .big));
    try std.testing.expectEqualStrings("IHDR", encoded[12..16]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[16..20], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[20..24], .big));
    try std.testing.expectEqual(@as(u8, 8), encoded[24]);
    try std.testing.expectEqual(@as(u8, 0), encoded[25]);

    const idat_length: usize = @intCast(std.mem.readInt(u32, encoded[33..37], .big));
    try std.testing.expectEqualStrings("IDAT", encoded[37..41]);
    const idat = encoded[41 .. 41 + idat_length];
    var input: std.Io.Reader = .fixed(idat);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var inflater: std.compress.flate.Decompress = .init(&input, .zlib, &history);
    var scanlines: [6]u8 = undefined;
    try inflater.reader.readSliceAll(&scanlines);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 127, 0, 255, 64 }, &scanlines);

    const iend_type = 41 + idat_length + 8;
    try std.testing.expectEqualStrings("IEND", encoded[iend_type .. iend_type + 4]);
}

test "pixel count is checked" {
    try std.testing.expectError(
        error.InvalidPixelCount,
        encodeGrayscale(std.testing.allocator, &.{0}, 2, 2),
    );
}
