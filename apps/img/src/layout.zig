const std = @import("std");
const font = @import("font.zig");

pub const Line = struct {
    start: usize,
    end: usize,
    scalar_count: usize,
    utf16_units: usize,

    pub fn bytes(self: Line, text: []const u8) []const u8 {
        return text[self.start..self.end];
    }
};

fn utf16Units(codepoint: u21) usize {
    return if (codepoint > 0xffff) 2 else 1;
}

pub fn measureContentCols(text: []const u8, max_cols: usize) usize {
    std.debug.assert(max_cols > 0);
    var widest: usize = 1;
    var current: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(text);
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') {
            widest = @max(widest, current);
            if (widest >= max_cols) return max_cols;
            current = 0;
            continue;
        }
        if (codepoint == '\t') {
            current += 4 - (current % 4);
            if (current >= max_cols) return max_cols;
            continue;
        }
        current += font.cellsFor(codepoint);
        if (current >= max_cols) return max_cols;
    }
    widest = @max(widest, current);
    return @min(max_cols, widest);
}

fn appendWrappedRange(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    range_start: usize,
    range_end: usize,
    cols: usize,
) !void {
    if (range_start == range_end) {
        try lines.append(allocator, .{
            .start = range_start,
            .end = range_end,
            .scalar_count = 0,
            .utf16_units = 0,
        });
        return;
    }

    var line_start = range_start;
    var byte_index = range_start;
    var columns: usize = 0;
    var scalars: usize = 0;
    var units: usize = 0;

    while (byte_index < range_end) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[byte_index]) catch unreachable;
        const next = byte_index + sequence_len;
        const codepoint = std.unicode.utf8Decode(text[byte_index..next]) catch unreachable;
        const width = font.cellsFor(codepoint);
        if (columns + width > cols) {
            try lines.append(allocator, .{
                .start = line_start,
                .end = byte_index,
                .scalar_count = scalars,
                .utf16_units = units,
            });
            line_start = byte_index;
            columns = 0;
            scalars = 0;
            units = 0;
        }
        columns += width;
        scalars += 1;
        units += utf16Units(codepoint);
        byte_index = next;
    }

    try lines.append(allocator, .{
        .start = line_start,
        .end = range_end,
        .scalar_count = scalars,
        .utf16_units = units,
    });
}

/// Wrap prepared text by display cells. The resulting spans borrow `text`.
pub fn wrap(
    allocator: std.mem.Allocator,
    text: []const u8,
    cols: usize,
) ![]Line {
    if (cols == 0) return error.InvalidColumns;
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    var start: usize = 0;
    while (true) {
        const relative_end = std.mem.indexOfScalar(u8, text[start..], '\n');
        const end = if (relative_end) |relative| start + relative else text.len;
        try appendWrappedRange(allocator, &lines, text, start, end, cols);
        if (end == text.len) break;
        start = end + 1;
    }
    return lines.toOwnedSlice(allocator);
}

test "measurement and wrapping count wide glyphs by cells" {
    try std.testing.expectEqual(@as(usize, 4), measureContentCols("a東b", 312));
    const lines = try wrap(std.testing.allocator, "a東b", 3);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("a東", lines[0].bytes("a東b"));
    try std.testing.expectEqualStrings("b", lines[1].bytes("a東b"));
}

test "astral scalars retain JavaScript UTF-16 budget accounting" {
    const text = "x🙂y";
    const lines = try wrap(std.testing.allocator, text, 10);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines[0].scalar_count);
    try std.testing.expectEqual(@as(usize, 4), lines[0].utf16_units);
}
