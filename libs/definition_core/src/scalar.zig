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
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or
        text[13] != ':' or text[16] != ':' or
        (text[text.len - 1] != 'Z' and
            std.mem.lastIndexOfAny(u8, text, "+-") == null))
    {
        return error.InvalidTimestamp;
    }
    for (text[0..4]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
    for (text[5..7]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
    for (text[8..10]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
    for (text[11..13]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
    for (text[14..16]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
    for (text[17..19]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
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
}
