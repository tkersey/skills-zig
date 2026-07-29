const std = @import("std");
const json = @import("json.zig");

pub const Kind = enum {
    string,
    integer,
    boolean,
    digest,
    timestamp,
    safe_identifier,
    relative_path,

    pub fn parse(text: []const u8) !Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidScalarKind;
    }
};

pub const Value = union(Kind) {
    string: []u8,
    integer: i64,
    boolean: bool,
    digest: []u8,
    timestamp: []u8,
    safe_identifier: []u8,
    relative_path: []u8,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string, .digest, .timestamp, .safe_identifier, .relative_path => |text| {
                allocator.free(text);
            },
            .integer, .boolean => {},
        }
        self.* = undefined;
    }

    pub fn kind(self: Value) Kind {
        return std.meta.activeTag(self);
    }

    pub fn writeCanonical(self: Value, writer: *std.Io.Writer) !void {
        switch (self) {
            .string,
            .digest,
            .timestamp,
            .safe_identifier,
            .relative_path,
            => |text| try @import("canonical_json.zig").writeCanonicalString(writer, text),
            .integer => |number| try writer.print("{d}", .{number}),
            .boolean => |flag| try writer.writeAll(if (flag) "true" else "false"),
        }
    }
};

pub fn parseAlloc(
    allocator: std.mem.Allocator,
    kind: Kind,
    raw: []const u8,
) !Value {
    return switch (kind) {
        .string => .{ .string = try duplicateUtf8(allocator, raw) },
        .integer => .{ .integer = std.fmt.parseInt(i64, raw, 10) catch
            return error.InvalidInteger },
        .boolean => .{ .boolean = if (std.mem.eql(u8, raw, "true"))
            true
        else if (std.mem.eql(u8, raw, "false"))
            false
        else
            return error.InvalidBoolean },
        .digest => blk: {
            try json.digest(raw);
            break :blk .{ .digest = try allocator.dupe(u8, raw) };
        },
        .timestamp => blk: {
            try validateTimestamp(raw);
            break :blk .{ .timestamp = try allocator.dupe(u8, raw) };
        },
        .safe_identifier => blk: {
            try json.safeIdentifier(raw, 128);
            break :blk .{ .safe_identifier = try allocator.dupe(u8, raw) };
        },
        .relative_path => blk: {
            try json.repositoryRelativePath(raw, true);
            break :blk .{ .relative_path = try allocator.dupe(u8, raw) };
        },
    };
}

pub fn validateString(kind: Kind, raw: []const u8) !void {
    switch (kind) {
        .string => if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8,
        .integer => _ = std.fmt.parseInt(i64, raw, 10) catch
            return error.InvalidInteger,
        .boolean => if (!std.mem.eql(u8, raw, "true") and
            !std.mem.eql(u8, raw, "false"))
        {
            return error.InvalidBoolean;
        },
        .digest => try json.digest(raw),
        .timestamp => try validateTimestamp(raw),
        .safe_identifier => try json.safeIdentifier(raw, 128),
        .relative_path => try json.repositoryRelativePath(raw, true),
    }
}

pub fn fromJsonAlloc(
    allocator: std.mem.Allocator,
    kind: Kind,
    value: std.json.Value,
) !Value {
    return switch (kind) {
        .integer => .{ .integer = try json.integer(value) },
        .boolean => .{ .boolean = try json.boolean(value) },
        else => try parseAlloc(allocator, kind, try json.string(value)),
    };
}

fn duplicateUtf8(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return allocator.dupe(u8, text);
}

fn validateTimestamp(text: []const u8) !void {
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or
        text[10] != 'T' or text[13] != ':' or text[16] != ':')
    {
        return error.InvalidTimestamp;
    }
    const year = try decimalComponent(text[0..4]);
    const month = try decimalComponent(text[5..7]);
    const day = try decimalComponent(text[8..10]);
    const hour = try decimalComponent(text[11..13]);
    const minute = try decimalComponent(text[14..16]);
    const second = try decimalComponent(text[17..19]);
    if (month == 0 or month > 12 or day == 0 or
        day > daysInMonth(year, month) or hour > 23 or minute > 59 or
        second > 60)
    {
        return error.InvalidTimestamp;
    }

    var offset_index: usize = 19;
    if (text[offset_index] == '.') {
        offset_index += 1;
        const fraction_start = offset_index;
        while (offset_index < text.len and
            std.ascii.isDigit(text[offset_index])) : (offset_index += 1)
        {}
        if (offset_index == fraction_start) return error.InvalidTimestamp;
    }
    if (offset_index == text.len - 1 and text[offset_index] == 'Z') return;
    if (offset_index + 6 != text.len or
        (text[offset_index] != '+' and text[offset_index] != '-') or
        text[offset_index + 3] != ':')
    {
        return error.InvalidTimestamp;
    }
    const offset_hour = try decimalComponent(text[offset_index + 1 .. offset_index + 3]);
    const offset_minute = try decimalComponent(text[offset_index + 4 ..]);
    if (offset_hour > 23 or offset_minute > 59) return error.InvalidTimestamp;
}

fn decimalComponent(text: []const u8) !u16 {
    if (text.len == 0) return error.InvalidTimestamp;
    var value: u16 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
        value = value * 10 + byte - '0';
    }
    return value;
}

fn daysInMonth(year: u16, month: u16) u16 {
    return switch (month) {
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

test "typed scalar parsing rejects ambiguous values" {
    var digest_value = try parseAlloc(
        std.testing.allocator,
        .digest,
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    );
    defer digest_value.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidBoolean,
        parseAlloc(std.testing.allocator, .boolean, "yes"),
    );
    try std.testing.expectError(
        error.InvalidRelativePath,
        parseAlloc(std.testing.allocator, .relative_path, "../escape"),
    );
    for ([_][]const u8{
        "2026-99-99T99:99:99Z",
        "2026-01-01T00:00:00garbage",
        "2025-02-29T00:00:00Z",
        "2026-01-01T00:00:00+24:00",
        "2026-01-01T00:00:00.",
    }) |invalid| {
        try std.testing.expectError(
            error.InvalidTimestamp,
            parseAlloc(std.testing.allocator, .timestamp, invalid),
        );
    }
    var timestamp = try parseAlloc(
        std.testing.allocator,
        .timestamp,
        "2024-02-29T23:59:60.125-07:30",
    );
    defer timestamp.deinit(std.testing.allocator);
}
