const std = @import("std");
const query = @import("../query/engine.zig");
const spec = @import("../types/spec.zig");

pub const Format = enum {
    table,
    json,
    csv,
    jsonl,

    pub fn parse(text: []const u8) !Format {
        if (std.ascii.eqlIgnoreCase(text, "table")) return .table;
        if (std.ascii.eqlIgnoreCase(text, "json")) return .json;
        if (std.ascii.eqlIgnoreCase(text, "csv")) return .csv;
        if (std.ascii.eqlIgnoreCase(text, "jsonl")) return .jsonl;
        return error.InvalidFormat;
    }
};

pub fn inferColumns(allocator: std.mem.Allocator, rows: []const query.Row) ![]const []const u8 {
    if (rows.len == 0) return &.{};

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);

    var it = rows[0].fields.iterator();
    while (it.next()) |entry| {
        try out.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
    }
    std.mem.sort([]const u8, out.items, {}, lessThanString);
    return out.toOwnedSlice(allocator);
}

pub fn freeColumns(allocator: std.mem.Allocator, cols: []const []const u8) void {
    for (cols) |col| allocator.free(col);
    allocator.free(cols);
}

pub fn render(
    allocator: std.mem.Allocator,
    fmt: Format,
    rows: []const query.Row,
    columns_opt: ?[]const []const u8,
) ![]u8 {
    var infer_owned = false;
    const columns = blk: {
        if (columns_opt) |provided| break :blk provided;
        infer_owned = true;
        break :blk try inferColumns(allocator, rows);
    };
    defer if (infer_owned) freeColumns(allocator, columns);

    return switch (fmt) {
        .table => formatTable(allocator, rows, columns),
        .json => formatJson(allocator, rows, columns, true),
        .csv => formatCsv(allocator, rows, columns),
        .jsonl => formatJsonl(allocator, rows, columns),
    };
}

pub fn writeOutput(
    allocator: std.mem.Allocator,
    fmt: Format,
    rows: []const query.Row,
    columns_opt: ?[]const []const u8,
    out_path: ?[]const u8,
) !void {
    const rendered = try render(allocator, fmt, rows, columns_opt);
    defer allocator.free(rendered);

    if (out_path) |path| {
        try std.fs.cwd().writeFile(.{
            .sub_path = path,
            .data = rendered,
        });
        return;
    }

    var stdout = std.fs.File.stdout().writer(&.{});
    try stdout.interface.writeAll(rendered);
}

pub fn formatTable(
    allocator: std.mem.Allocator,
    rows: []const query.Row,
    columns: []const []const u8,
) ![]u8 {
    if (rows.len == 0) return allocator.dupe(u8, "(no results)\n");
    if (columns.len == 0) return allocator.dupe(u8, "(no columns)\n");

    const widths = try allocator.alloc(usize, columns.len);
    defer allocator.free(widths);

    for (columns, 0..) |col, i| widths[i] = col.len;

    var cell_buf: [256]u8 = undefined;
    for (rows) |row| {
        for (columns, 0..) |col, i| {
            const text = scalarToText(row.valueOrNull(col), cell_buf[0..]);
            if (text.len > widths[i]) widths[i] = text.len;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var writer = out.writer(allocator);

    for (columns, 0..) |col, i| {
        if (i > 0) try writer.writeAll("  ");
        try writePadded(&writer, col, widths[i]);
    }
    try writer.writeByte('\n');

    for (widths, 0..) |w, i| {
        if (i > 0) try writer.writeAll("  ");
        var j: usize = 0;
        while (j < w) : (j += 1) try writer.writeByte('-');
    }
    try writer.writeByte('\n');

    for (rows) |row| {
        for (columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll("  ");
            const text = scalarToText(row.valueOrNull(col), cell_buf[0..]);
            try writePadded(&writer, text, widths[i]);
        }
        try writer.writeByte('\n');
    }

    return out.toOwnedSlice(allocator);
}

pub fn formatCsv(
    allocator: std.mem.Allocator,
    rows: []const query.Row,
    columns: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var writer = out.writer(allocator);

    for (columns, 0..) |col, i| {
        if (i > 0) try writer.writeByte(',');
        try writeCsvCell(&writer, col);
    }
    try writer.writeByte('\n');

    var cell_buf: [256]u8 = undefined;
    for (rows) |row| {
        for (columns, 0..) |col, i| {
            if (i > 0) try writer.writeByte(',');
            const text = scalarToText(row.valueOrNull(col), cell_buf[0..]);
            try writeCsvCell(&writer, text);
        }
        try writer.writeByte('\n');
    }

    return out.toOwnedSlice(allocator);
}

pub fn formatJson(
    allocator: std.mem.Allocator,
    rows: []const query.Row,
    columns: []const []const u8,
    pretty: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var writer = out.writer(allocator);

    if (pretty) {
        try writer.writeAll("[\n");
    } else {
        try writer.writeByte('[');
    }

    for (rows, 0..) |row, row_idx| {
        if (row_idx > 0) {
            try writer.writeByte(',');
            if (pretty) try writer.writeByte('\n');
        }
        if (pretty) try writer.writeAll("  ");
        try writeJsonObject(&writer, row, columns, pretty, if (pretty) "    " else "");
    }

    if (pretty) {
        if (rows.len > 0) try writer.writeByte('\n');
        try writer.writeAll("]\n");
    } else {
        try writer.writeByte(']');
    }

    return out.toOwnedSlice(allocator);
}

pub fn formatJsonl(
    allocator: std.mem.Allocator,
    rows: []const query.Row,
    columns: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var writer = out.writer(allocator);

    for (rows) |row| {
        try writeJsonObject(&writer, row, columns, false, "");
        try writer.writeByte('\n');
    }

    return out.toOwnedSlice(allocator);
}

fn writeJsonObject(
    writer: anytype,
    row: query.Row,
    columns: []const []const u8,
    pretty: bool,
    indent: []const u8,
) !void {
    try writer.writeByte('{');
    for (columns, 0..) |col, i| {
        if (i > 0) try writer.writeByte(',');
        if (pretty) {
            try writer.writeByte('\n');
            try writer.writeAll(indent);
        }
        try writeJsonString(writer, col);
        try writer.writeByte(':');
        if (pretty) try writer.writeByte(' ');
        try writeScalarJson(writer, row.valueOrNull(col));
    }
    if (pretty and columns.len > 0) {
        try writer.writeByte('\n');
        try writer.writeAll("  ");
    }
    try writer.writeByte('}');
}

fn writeScalarJson(writer: anytype, value: spec.Scalar) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |v| try writer.writeAll(if (v) "true" else "false"),
        .int => |v| try writer.print("{d}", .{v}),
        .float => |v| try writer.print("{d}", .{v}),
        .string => |v| try writeJsonString(writer, v),
    }
}

fn writePadded(writer: anytype, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len >= width) return;
    var i: usize = text.len;
    while (i < width) : (i += 1) try writer.writeByte(' ');
}

fn writeCsvCell(writer: anytype, text: []const u8) !void {
    const needs_quotes = std.mem.indexOfAny(u8, text, ",\"\n\r") != null;
    if (!needs_quotes) {
        try writer.writeAll(text);
        return;
    }

    try writer.writeByte('"');
    for (text) |c| {
        if (c == '"') try writer.writeByte('"');
        try writer.writeByte(c);
    }
    try writer.writeByte('"');
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = .{ '\\', 'u', '0', '0', '0', '0' };
                    const hi = c >> 4;
                    const lo = c & 0x0f;
                    buf[4] = hexNibble(hi);
                    buf[5] = hexNibble(lo);
                    try writer.writeAll(&buf);
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn hexNibble(v: u8) u8 {
    return if (v < 10) ('0' + v) else ('a' + (v - 10));
}

fn scalarToText(value: spec.Scalar, buffer: []u8) []const u8 {
    return switch (value) {
        .null => "",
        .bool => |v| if (v) "true" else "false",
        .int => |v| std.fmt.bufPrint(buffer, "{d}", .{v}) catch "",
        .float => |v| std.fmt.bufPrint(buffer, "{d}", .{v}) catch "",
        .string => |v| v,
    };
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn deinitRows(allocator: std.mem.Allocator, rows: *std.ArrayList(query.Row)) void {
    for (rows.items) |*row| row.deinit();
    rows.deinit(allocator);
}

fn rowFromEntries(allocator: std.mem.Allocator, entries: []const struct { key: []const u8, value: spec.Scalar }) !query.Row {
    var row = query.Row.init(allocator);
    errdefer row.deinit();
    for (entries) |entry| {
        try row.putOwnedKey(entry.key, entry.value);
    }
    return row;
}

test "table/csv/json/jsonl output is deterministic" {
    var rows: std.ArrayList(query.Row) = .empty;
    defer deinitRows(std.testing.allocator, &rows);

    try rows.append(std.testing.allocator, try rowFromEntries(std.testing.allocator, &.{
        .{ .key = "skill", .value = .{ .string = "tk" } },
        .{ .key = "count", .value = .{ .int = 3 } },
    }));
    try rows.append(std.testing.allocator, try rowFromEntries(std.testing.allocator, &.{
        .{ .key = "skill", .value = .{ .string = "fix" } },
        .{ .key = "count", .value = .{ .int = 2 } },
    }));

    const columns = [_][]const u8{ "skill", "count" };

    const table = try formatTable(std.testing.allocator, rows.items, columns[0..]);
    defer std.testing.allocator.free(table);
    try std.testing.expect(std.mem.indexOf(u8, table, "skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "tk") != null);

    const csv = try formatCsv(std.testing.allocator, rows.items, columns[0..]);
    defer std.testing.allocator.free(csv);
    try std.testing.expect(std.mem.eql(u8, csv, "skill,count\ntk,3\nfix,2\n"));

    const json = try formatJson(std.testing.allocator, rows.items, columns[0..], false);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.eql(u8, json, "[{\"skill\":\"tk\",\"count\":3},{\"skill\":\"fix\",\"count\":2}]"));

    const jsonl = try formatJsonl(std.testing.allocator, rows.items, columns[0..]);
    defer std.testing.allocator.free(jsonl);
    try std.testing.expect(std.mem.eql(u8, jsonl, "{\"skill\":\"tk\",\"count\":3}\n{\"skill\":\"fix\",\"count\":2}\n"));
}
