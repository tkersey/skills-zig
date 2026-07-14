const std = @import("std");
const atlas = @import("img_atlas");

/// Production pxpipe v0.9.0 atlas geometry. The generated atlas combines
/// Spleen 5x8 for ASCII/code with an 8px GNU Unifont fallback.
pub const cell_width: usize = 5;
pub const cell_height: usize = 8;
pub const ascent: usize = 7;

const codepoints = atlas.codepoints;
const offsets = atlas.offsets;
const wide_flags = atlas.wide_flags;
const pixels = atlas.pixels;

pub const glyph_count = codepoints.len / @sizeOf(u32);

comptime {
    std.debug.assert(codepoints.len % @sizeOf(u32) == 0);
    std.debug.assert(offsets.len == codepoints.len);
    std.debug.assert(wide_flags.len == glyph_count);
}

pub const Glyph = struct {
    coverage: []const u8,
    width: usize,
    cells: u2,
};

fn readU32Le(bytes: []const u8, index: usize) u32 {
    const start = index * @sizeOf(u32);
    return std.mem.readInt(u32, bytes[start..][0..4], .little);
}

fn rank(codepoint: u21) ?usize {
    var low: usize = 0;
    var high: usize = glyph_count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = readU32Le(codepoints, middle);
        if (candidate < codepoint) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low < glyph_count and readU32Le(codepoints, low) == codepoint) return low;
    return null;
}

pub fn glyph(codepoint: u21) ?Glyph {
    const glyph_rank = rank(codepoint) orelse return null;
    const cells: u2 = if (wide_flags[glyph_rank] == 1) 2 else 1;
    const width = @as(usize, cells) * cell_width;
    const start: usize = @intCast(readU32Le(offsets, glyph_rank));
    const length = width * cell_height;
    if (start > pixels.len or length > pixels.len - start) return null;
    const end = start + length;
    return .{
        .coverage = pixels[start..end],
        .width = width,
        .cells = cells,
    };
}

/// Missing glyphs deliberately occupy one cell so wrapping and drop accounting
/// remain stable.
pub fn cellsFor(codepoint: u21) u2 {
    return if (glyph(codepoint)) |found| found.cells else 1;
}

test "embedded atlas has the pinned pxpipe shape" {
    try std.testing.expectEqual(@as(usize, 35_501), glyph_count);
    try std.testing.expectEqual(@as(u2, 1), glyph('A').?.cells);
    try std.testing.expectEqual(@as(u2, 2), glyph('東').?.cells);
    try std.testing.expect(glyph(0x1f642) == null);
    try std.testing.expect(glyph(0x21b5) != null);
    try std.testing.expect(glyph(0x2192) != null);
}
