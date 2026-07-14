const std = @import("std");
const font = @import("font.zig");

pub const newline_marker = "↵";
pub const newline_marker_codepoint: u21 = 0x21b5;
pub const tab_marker = "→";
const tab_width: usize = 4;

fn trimTrailingHorizontalWhitespace(out: *std.ArrayList(u8)) void {
    while (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (last != ' ' and last != '\t') break;
        out.items.len -= 1;
    }
}

/// Strip trailing spaces/tabs on every line and collapse runs of four or more
/// newlines to three. Mid-line and leading whitespace remain untouched.
pub fn minifyForRender(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    for (text) |byte| {
        if (byte != '\n') {
            try out.append(allocator, byte);
            continue;
        }

        trimTrailingHorizontalWhitespace(&out);
        var newline_count: usize = 0;
        var index = out.items.len;
        while (index > 0 and out.items[index - 1] == '\n') : (index -= 1) {
            newline_count += 1;
        }
        if (newline_count < 3) try out.append(allocator, '\n');
    }
    trimTrailingHorizontalWhitespace(&out);
    return out.toOwnedSlice(allocator);
}

fn appendExpandedLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
) !void {
    var view = std.unicode.Utf8View.initUnchecked(line);
    var iterator = view.iterator();
    var column: usize = 0;
    var byte_index: usize = 0;
    while (iterator.nextCodepointSlice()) |slice| {
        const codepoint = std.unicode.utf8Decode(slice) catch unreachable;
        byte_index += slice.len;
        if (codepoint != '\t') {
            try out.appendSlice(allocator, slice);
            column += font.cellsFor(codepoint);
            continue;
        }

        const span = tab_width - (column % tab_width);
        try out.appendSlice(allocator, tab_marker);
        if (span > 1) try out.appendNTimes(allocator, ' ', span - 1);
        column += span;
    }
    std.debug.assert(byte_index == line.len);
}

/// Apply pxpipe's optional reflow transform. A source that already contains ↵
/// is copied byte-for-byte: upstream returns `null` before minification or tab
/// expansion and its caller falls back to the original source.
pub fn prepare(
    allocator: std.mem.Allocator,
    text: []const u8,
    enable_reflow: bool,
) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (!enable_reflow or std.mem.indexOf(u8, text, newline_marker) != null) {
        return allocator.dupe(u8, text);
    }

    const minified = try minifyForRender(allocator, text);
    defer allocator.free(minified);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, minified.len);

    var start: usize = 0;
    while (true) {
        const relative_end = std.mem.indexOfScalar(u8, minified[start..], '\n');
        const end = if (relative_end) |relative| start + relative else minified.len;
        try appendExpandedLine(allocator, &out, minified[start..end]);
        if (end == minified.len) break;
        try out.appendSlice(allocator, newline_marker);
        start = end + 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Apply the normalization performed by pxpipe's `wrapLines`: minification,
/// followed by visible tab expansion, while retaining actual line boundaries.
pub fn prepareForWrap(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const minified = try minifyForRender(allocator, text);
    defer allocator.free(minified);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, minified.len);
    var start: usize = 0;
    while (true) {
        const relative_end = std.mem.indexOfScalar(u8, minified[start..], '\n');
        const end = if (relative_end) |relative| start + relative else minified.len;
        try appendExpandedLine(allocator, &out, minified[start..end]);
        if (end == minified.len) break;
        try out.append(allocator, '\n');
        start = end + 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn dereflow(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var start: usize = 0;
    while (std.mem.indexOf(u8, text[start..], newline_marker)) |relative| {
        const at = start + relative;
        try out.appendSlice(allocator, text[start..at]);
        try out.append(allocator, '\n');
        start = at + newline_marker.len;
    }
    try out.appendSlice(allocator, text[start..]);
    return out.toOwnedSlice(allocator);
}

test "minify preserves indentation and caps blank lines" {
    const result = try minifyForRender(std.testing.allocator, "  a  \n\n\n\n\n\tb\t  ");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("  a\n\n\n\tb", result);
}

test "reflow exposes tabs and hard newlines" {
    const reflowed = try prepare(std.testing.allocator, "a\tb\n東\tx", true);
    defer std.testing.allocator.free(reflowed);
    try std.testing.expectEqualStrings("a→  b↵東→ x", reflowed);

    const unpacked = try dereflow(std.testing.allocator, reflowed);
    defer std.testing.allocator.free(unpacked);
    try std.testing.expectEqualStrings("a→  b\n東→ x", unpacked);
}

test "CRLF preserves carriage return as a renderable blank cell" {
    const result = try prepare(std.testing.allocator, "a\r\nb", true);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a\r↵b", result);
}

test "existing newline marker disables joining" {
    const source = "a↵b\t \n\n\n\nc  ";
    const result = try prepare(std.testing.allocator, source, true);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(source, result);
    try std.testing.expect(font.glyph('\t') == null);

    const wrapped = try prepareForWrap(std.testing.allocator, result);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualStrings("a↵b\n\n\nc", wrapped);
}
