const std = @import("std");
const font = @import("font.zig");
const layout = @import("layout.zig");
const png = @import("png.zig");
const reflow = @import("reflow.zig");

pub const default_cols: u16 = 312;
pub const default_max_height: u16 = 728;
pub const default_max_chars_per_page: u32 = 28_080;
pub const pad_x: usize = 4;
pub const pad_y: usize = 4;

pub const RenderOptions = struct {
    cols: u16 = default_cols,
    max_height: u16 = default_max_height,
    max_chars_per_page: u32 = default_max_chars_per_page,
    reflow: bool = true,
    shrink: bool = true,
};

pub const Page = struct {
    png: []u8,
    width: u32,
    height: u32,
    chars_rendered: usize,
    dropped_chars: usize,

    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        allocator.free(self.png);
        self.* = undefined;
    }
};

const PageSpan = struct {
    first_line: usize,
    line_count: usize,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    lines: []layout.Line,
    pages: []PageSpan,
    cols: usize,
    next_page: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        text: []const u8,
        options: RenderOptions,
    ) !Renderer {
        if (options.cols == 0) return error.InvalidColumns;
        if (options.max_height < 2 * pad_y + font.cell_height) return error.InvalidMaxHeight;
        if (options.max_chars_per_page == 0) return error.InvalidCharacterBudget;

        const source = try reflow.prepare(allocator, text, options.reflow);
        defer allocator.free(source);

        const max_cols: usize = options.cols;
        const cols = if (options.shrink)
            layout.measureContentCols(source, max_cols)
        else
            max_cols;

        const wrapped_text = try reflow.prepareForWrap(allocator, source);
        errdefer allocator.free(wrapped_text);
        const lines = try layout.wrap(allocator, wrapped_text, cols);
        errdefer allocator.free(lines);

        const hard_line_limit = @max(
            @as(usize, 1),
            (@as(usize, options.max_height) - 2 * pad_y) / font.cell_height,
        );
        const budget_line_limit = @max(
            @as(usize, 1),
            @as(usize, options.max_chars_per_page) / cols,
        );
        const line_limit = @min(hard_line_limit, budget_line_limit);

        var pages: std.ArrayList(PageSpan) = .empty;
        errdefer pages.deinit(allocator);
        var first_line: usize = 0;
        var line_count: usize = 0;
        var page_units: usize = 0;
        for (lines, 0..) |line, line_index| {
            const separator_units: usize = if (line_count > 0) 1 else 0;
            const units_with_line = std.math.add(
                usize,
                page_units,
                separator_units + line.utf16_units,
            ) catch return error.InputTooLarge;
            if (line_count > 0 and
                (line_count >= line_limit or units_with_line > options.max_chars_per_page))
            {
                try pages.append(allocator, .{
                    .first_line = first_line,
                    .line_count = line_count,
                });
                first_line = line_index;
                line_count = 0;
                page_units = 0;
            }
            page_units += (if (line_count > 0) @as(usize, 1) else 0) + line.utf16_units;
            line_count += 1;
        }
        std.debug.assert(line_count > 0);
        try pages.append(allocator, .{
            .first_line = first_line,
            .line_count = line_count,
        });

        return .{
            .allocator = allocator,
            .text = wrapped_text,
            .lines = lines,
            .pages = try pages.toOwnedSlice(allocator),
            .cols = cols,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.pages);
        self.allocator.free(self.lines);
        self.allocator.free(self.text);
        self.* = undefined;
    }

    pub fn pageCount(self: *const Renderer) usize {
        return self.pages.len;
    }

    pub fn next(self: *Renderer) !?Page {
        if (self.next_page >= self.pages.len) return null;
        const page = try self.renderPage(self.pages[self.next_page]);
        self.next_page += 1;
        return page;
    }

    fn renderPage(self: *Renderer, span: PageSpan) !Page {
        const width = 2 * pad_x + self.cols * font.cell_width;
        const height = 2 * pad_y + span.line_count * font.cell_height;
        const pixel_count = std.math.mul(usize, width, height) catch return error.ImageTooLarge;
        const pixels = try self.allocator.alloc(u8, pixel_count);
        defer self.allocator.free(pixels);
        @memset(pixels, 255);

        var dropped_chars: usize = 0;
        var chars_rendered: usize = if (span.line_count > 0) span.line_count - 1 else 0;
        const page_lines = self.lines[span.first_line..][0..span.line_count];
        for (page_lines, 0..) |line, row| {
            chars_rendered += line.scalar_count;
            var column: usize = 0;
            var view = std.unicode.Utf8View.initUnchecked(line.bytes(self.text));
            var iterator = view.iterator();
            while (iterator.nextCodepoint()) |codepoint| {
                if (column >= self.cols) break;
                const found = font.glyph(codepoint) orelse {
                    dropped_chars += 1;
                    column += 1;
                    continue;
                };

                const base_x = pad_x + column * font.cell_width;
                const base_y = pad_y + row * font.cell_height;
                for (0..font.cell_height) |glyph_y| {
                    const destination_row = (base_y + glyph_y) * width + base_x;
                    const source_row = glyph_y * found.width;
                    for (0..found.width) |glyph_x| {
                        const destination_x = base_x + glyph_x;
                        if (destination_x >= width) break;
                        const coverage = found.coverage[source_row + glyph_x];
                        if (coverage > 0) {
                            pixels[destination_row + glyph_x] = 255 - coverage;
                        }
                    }
                }
                column += found.cells;
            }
        }

        return .{
            .png = try png.encodeGrayscale(
                self.allocator,
                pixels,
                @intCast(width),
                @intCast(height),
            ),
            .width = @intCast(width),
            .height = @intCast(height),
            .chars_rendered = chars_rendered,
            .dropped_chars = dropped_chars,
        };
    }
};

fn inflatePixels(allocator: std.mem.Allocator, page: Page) ![]u8 {
    var offset: usize = png.signature.len;
    var idat: ?[]const u8 = null;
    while (offset < page.png.len) {
        const length: usize = @intCast(std.mem.readInt(u32, page.png[offset..][0..4], .big));
        const chunk_type = page.png[offset + 4 .. offset + 8];
        if (std.mem.eql(u8, chunk_type, "IDAT")) idat = page.png[offset + 8 ..][0..length];
        offset += 12 + length;
    }
    const compressed = idat orelse return error.MissingIdat;
    var input: std.Io.Reader = .fixed(compressed);
    const history = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(history);
    var inflater: std.compress.flate.Decompress = .init(&input, .zlib, history);
    const row_width = @as(usize, page.width) + 1;
    const scanline_count = std.math.mul(usize, row_width, page.height) catch return error.ImageTooLarge;
    const scanlines = try allocator.alloc(u8, scanline_count);
    defer allocator.free(scanlines);
    try inflater.reader.readSliceAll(scanlines);

    const decoded = try allocator.alloc(u8, @as(usize, page.width) * page.height);
    errdefer allocator.free(decoded);
    for (0..page.height) |row| {
        const source_start = row * row_width;
        if (scanlines[source_start] != 0) return error.UnexpectedFilter;
        @memcpy(
            decoded[row * page.width ..][0..page.width],
            scanlines[source_start + 1 ..][0..page.width],
        );
    }
    return decoded;
}

fn expectPixelHash(page: Page, expected_hex: *const [64]u8) !void {
    const decoded = try inflatePixels(std.testing.allocator, page);
    defer std.testing.allocator.free(decoded);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(decoded, &digest, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "production ASCII raster matches pinned pxpipe decoded pixels" {
    var renderer = try Renderer.init(std.testing.allocator, "Hello, world!", .{});
    defer renderer.deinit();
    try std.testing.expectEqual(@as(usize, 1), renderer.pageCount());
    var page = (try renderer.next()).?;
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 73), page.width);
    try std.testing.expectEqual(@as(u32, 16), page.height);
    try std.testing.expectEqual(@as(usize, 0), page.dropped_chars);
    try expectPixelHash(page, "a8d7399a68994be0c5b54a00e2c169fa88f115dfb5a6ae802acdca6a28a0f807");
    try std.testing.expect((try renderer.next()) == null);
}

test "CRLF retains carriage return as a dropped cell" {
    var renderer = try Renderer.init(std.testing.allocator, "a\r\nb", .{});
    defer renderer.deinit();
    var page = (try renderer.next()).?;
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 28), page.width);
    try std.testing.expectEqual(@as(u32, 16), page.height);
    try std.testing.expectEqual(@as(usize, 1), page.dropped_chars);
    try expectPixelHash(page, "88ee9b86cea0c244532442666c557a01d0c21ef9e752ba8fc6693b66ecf947db");
}

test "visible tab and wide-glyph raster matches pinned pxpipe pixels" {
    var renderer = try Renderer.init(std.testing.allocator, "a\tb\n東\tx", .{});
    defer renderer.deinit();
    var page = (try renderer.next()).?;
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 63), page.width);
    try std.testing.expectEqual(@as(u32, 16), page.height);
    try expectPixelHash(page, "160a157f98ef1704acee53dbb6e8d2153d83816aeb33a954af07bd2e8514aa46");
}

test "literal newline marker keeps raw measurement then wrap normalization" {
    var renderer = try Renderer.init(std.testing.allocator, "a↵b\t \n\n\n\nc  ", .{});
    defer renderer.deinit();
    var page = (try renderer.next()).?;
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 33), page.width);
    try std.testing.expectEqual(@as(u32, 40), page.height);
    try std.testing.expectEqual(@as(usize, 0), page.dropped_chars);
    try expectPixelHash(page, "d0bf417f4ea420419aa82d4c020a6e9c0ac25322101e160235e7566d1c938d7a");
}

test "missing astral glyph occupies one cell and one drop" {
    var renderer = try Renderer.init(std.testing.allocator, "🙂", .{});
    defer renderer.deinit();
    var page = (try renderer.next()).?;
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 13), page.width);
    try std.testing.expectEqual(@as(usize, 1), page.chars_rendered);
    try std.testing.expectEqual(@as(usize, 1), page.dropped_chars);
}

test "missing glyph raster is blank but maintains its cell" {
    var renderer = try Renderer.init(std.testing.allocator, "hi 🙂 world", .{});
    defer renderer.deinit();
    var page = (try renderer.next()).?;
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 58), page.width);
    try std.testing.expectEqual(@as(usize, 1), page.dropped_chars);
    try expectPixelHash(page, "225ca83fae399eee0833c382f40682c1b9cf10166be26b76880b30610c822f5c");
}

test "wide glyph spills intact to the next wrapped row" {
    const text = "a" ** 311 ++ "東";
    var renderer = try Renderer.init(std.testing.allocator, text, .{});
    defer renderer.deinit();
    var page = (try renderer.next()).?;
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1568), page.width);
    try std.testing.expectEqual(@as(u32, 24), page.height);
    try expectPixelHash(page, "4d23999dfd23df6e7cf5fa60db969f653e5904f245a959f1f002c82bb066d2c3");
}

test "empty input still yields one blank one-row page" {
    var renderer = try Renderer.init(std.testing.allocator, "", .{});
    defer renderer.deinit();
    try std.testing.expectEqual(@as(usize, 1), renderer.pageCount());
    var page = (try renderer.next()).?;
    defer page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 13), page.width);
    try std.testing.expectEqual(@as(u32, 16), page.height);
    try expectPixelHash(page, "86ff85227f7cc42cc3293ebdeeb10d8660b51eb429dd1d6c999ddf14cb59db73");
}

test "page budget counts UTF-16 units and synthetic row separators" {
    const text = "🙂" ** 10 ++ "\nx";
    var renderer = try Renderer.init(std.testing.allocator, text, .{
        .cols = 10,
        .max_chars_per_page = 20,
        .reflow = false,
        .shrink = false,
    });
    defer renderer.deinit();
    try std.testing.expectEqual(@as(usize, 2), renderer.pageCount());
    var first = (try renderer.next()).?;
    defer first.deinit(std.testing.allocator);
    var second = (try renderer.next()).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 10), first.dropped_chars);
    try std.testing.expectEqual(@as(usize, 0), second.dropped_chars);
}

test "page budget is inclusive and splits on the next scalar" {
    const exact = try std.testing.allocator.alloc(u8, 27_991);
    defer std.testing.allocator.free(exact);
    @memset(exact, 'x');
    var exact_renderer = try Renderer.init(std.testing.allocator, exact, .{
        .reflow = false,
        .shrink = false,
    });
    defer exact_renderer.deinit();
    try std.testing.expectEqual(@as(usize, 1), exact_renderer.pageCount());
    var exact_page = (try exact_renderer.next()).?;
    defer exact_page.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1568), exact_page.width);
    try std.testing.expectEqual(@as(u32, 728), exact_page.height);
    try expectPixelHash(exact_page, "f66b25f05f71dcf7359b989532dfaf7ac3a0a37d5a4e2bc73699c1c12ede400a");

    const text = try std.testing.allocator.alloc(u8, 27_992);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    var renderer = try Renderer.init(std.testing.allocator, text, .{
        .reflow = false,
        .shrink = false,
    });
    defer renderer.deinit();
    try std.testing.expectEqual(@as(usize, 2), renderer.pageCount());
    var first = (try renderer.next()).?;
    defer first.deinit(std.testing.allocator);
    var second = (try renderer.next()).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1568), first.width);
    try std.testing.expectEqual(@as(u32, 720), first.height);
    try std.testing.expectEqual(@as(u32, 16), second.height);
    try expectPixelHash(first, "4dd2f9bdc884f120634035543943ab5ae541e58032e1d002beabdc11afd6eb8e");
    try expectPixelHash(second, "6ca914bf429d0754a415004195d4940b750909dc4a5b73d9cc5699634d1b2715");
}

test "PNG bytes are deterministic within the Zig implementation" {
    var first_renderer = try Renderer.init(std.testing.allocator, "same input\nwith tabs\tand 東", .{});
    defer first_renderer.deinit();
    var first = (try first_renderer.next()).?;
    defer first.deinit(std.testing.allocator);

    var second_renderer = try Renderer.init(std.testing.allocator, "same input\nwith tabs\tand 東", .{});
    defer second_renderer.deinit();
    var second = (try second_renderer.next()).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, first.png, second.png);
}
