const std = @import("std");
const limits = @import("limits.zig");

pub const Code = enum {
    invalid_usage,
    unsupported_schema,
    invalid_json,
    duplicate_key,
    invalid_document,
    duplicate_id,
    unknown_reference,
    conflicting_record,
    identity_mismatch,
    receipt_mismatch,
    missing_input,
    resource_limit,
    io_error,
};

pub const Error = error{ Rejected, OutOfMemory };

const segments_max = 2 * limits.json_depth_max;
pub const location_bytes_max = segments_max * (2 * segment_key_bytes_max + 1);
const segment_key_bytes_max = limits.id_bytes_max;

pub const Loc = struct {
    parent: ?*const Loc,
    segment: Segment,

    pub const Segment = union(enum) {
        root,
        key: []const u8,
        index: usize,
    };

    pub const root: Loc = .{ .parent = null, .segment = .root };

    pub fn key(self: *const Loc, name: []const u8) Loc {
        return .{ .parent = self, .segment = .{ .key = name } };
    }

    pub fn index(self: *const Loc, position: usize) Loc {
        return .{ .parent = self, .segment = .{ .index = position } };
    }

    pub fn write(self: *const Loc, writer: *std.Io.Writer) void {
        var chain: [segments_max]*const Loc = undefined;
        var count: usize = 0;
        var cursor: ?*const Loc = self;
        while (cursor) |node| : (cursor = node.parent) {
            if (node.segment == .root) break;
            std.debug.assert(count < segments_max);
            chain[count] = node;
            count += 1;
        }
        var position = count;
        while (position > 0) {
            position -= 1;
            const mark = writer.end;
            writeSegment(writer, chain[position].segment) catch {
                writer.end = mark;
                return;
            };
        }
    }

    fn writeSegment(writer: *std.Io.Writer, segment: Segment) !void {
        switch (segment) {
            .root => {},
            .index => |value| try writer.print("/{d}", .{value}),
            .key => |name| {
                if (name.len > segment_key_bytes_max) return error.WriteFailed;
                try writer.writeByte('/');
                for (name) |byte| switch (byte) {
                    '~' => try writer.writeAll("~0"),
                    '/' => try writer.writeAll("~1"),
                    else => try writer.writeByte(byte),
                };
            },
        }
    }
};

pub const Diagnostic = struct {
    code: Code = .io_error,
    message_buffer: [limits.error_message_bytes_max]u8 = undefined,
    message_len: usize = 0,
    location_buffer: [location_bytes_max]u8 = undefined,
    location_len: ?usize = null,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.message_buffer[0..self.message_len];
    }

    pub fn location(self: *const Diagnostic) ?[]const u8 {
        const len = self.location_len orelse return null;
        return self.location_buffer[0..len];
    }

    pub fn fail(
        self: *Diagnostic,
        code: Code,
        loc: ?*const Loc,
        comptime format: []const u8,
        arguments: anytype,
    ) error{Rejected} {
        self.set(code, loc, format, arguments);
        return error.Rejected;
    }

    pub fn set(
        self: *Diagnostic,
        code: Code,
        loc: ?*const Loc,
        comptime format: []const u8,
        arguments: anytype,
    ) void {
        self.code = code;
        var writer = std.Io.Writer.fixed(&self.message_buffer);
        writer.print(format, arguments) catch |err| switch (err) {
            error.WriteFailed => {},
        };
        self.message_len = utf8Prefix(writer.buffered());
        self.location_len = null;
        if (loc) |where| {
            var location_writer = std.Io.Writer.fixed(&self.location_buffer);
            where.write(&location_writer);
            self.location_len = location_writer.end;
        }
    }

    pub fn rewrap(
        self: *Diagnostic,
        code: Code,
        loc: ?*const Loc,
        role: []const u8,
        comptime summary: []const u8,
    ) error{Rejected} {
        var inner: [limits.error_message_bytes_max]u8 = undefined;
        const inner_message = inner[0..self.message_len];
        @memcpy(inner_message, self.message());
        var inner_where: [nested_location_bytes_max]u8 = undefined;
        const inner_location = quoteLocation(&inner_where, self.location());
        const inner_code = self.code;
        return self.fail(code, loc, "{s}: " ++ summary ++ " ({s} at {s}: {s})", .{
            role,
            @tagName(inner_code),
            inner_location,
            inner_message,
        });
    }
};

const nested_location_bytes_max = 1024;

fn quoteLocation(buffer: *[nested_location_bytes_max]u8, location: ?[]const u8) []const u8 {
    const full = location orelse return "none";
    var prefix = full;
    var attempts: usize = 0;
    while (attempts <= segments_max) : (attempts += 1) {
        var writer = std.Io.Writer.fixed(buffer);
        const options: std.json.Stringify.Options = .{ .escape_unicode = true };
        const fits = if (std.json.Stringify.encodeJsonString(prefix, options, &writer)) |_|
            writer.unusedCapacityLen() >= " (abbreviated)".len
        else |_|
            false;
        if (fits) {
            if (prefix.len < full.len) {
                writer.writeAll(" (abbreviated)") catch return writer.buffered();
            }
            return writer.buffered();
        }
        const cut = std.mem.lastIndexOfScalar(u8, prefix, '/') orelse break;
        prefix = prefix[0..cut];
    }
    return "\"\" (abbreviated)";
}

fn utf8Prefix(bytes: []const u8) usize {
    var len = bytes.len;
    while (len > 0 and !std.unicode.utf8ValidateSlice(bytes[0..len])) len -= 1;
    return len;
}

test "locations escape pointer tokens and omit oversized keys" {
    var diagnostic: Diagnostic = .{};
    const records = Loc.root.key("records");
    const first = records.index(0);
    const odd = first.key("a/b~c");
    diagnostic.set(.invalid_document, &odd, "bad {s}", .{"field"});
    try std.testing.expectEqualStrings("/records/0/a~1b~0c", diagnostic.location().?);
    try std.testing.expectEqualStrings("bad field", diagnostic.message());
    const long: [200]u8 = @splat('k');
    const oversized = first.key(&long);
    diagnostic.set(.invalid_document, &oversized, "unknown", .{});
    try std.testing.expectEqualStrings("/records/0", diagnostic.location().?);
    const below = oversized.key("a");
    const deeper = below.index(3);
    diagnostic.set(.duplicate_key, &deeper, "nested", .{});
    try std.testing.expectEqualStrings("/records/0", diagnostic.location().?);
    diagnostic.set(.io_error, null, "plain", .{});
    try std.testing.expect(diagnostic.location() == null);
    diagnostic.set(.invalid_document, &Loc.root, "root", .{});
    try std.testing.expectEqualStrings("", diagnostic.location().?);
}

test "nested locations are escaped, bounded at segments, and explicit when absent" {
    var buffer: [nested_location_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("none", quoteLocation(&buffer, null));
    try std.testing.expectEqualStrings(
        "\"/a/\\u001b]0;x\\u0007\\u202e\"",
        quoteLocation(&buffer, "/a/\x1b]0;x\x07\u{202e}"),
    );
    var long: [64 * 33]u8 = undefined;
    for (0..64) |index| {
        long[index * 33] = '/';
        @memset(long[index * 33 + 1 ..][0..32], 'k');
    }
    const quoted = quoteLocation(&buffer, &long);
    try std.testing.expect(quoted.len <= nested_location_bytes_max);
    try std.testing.expect(std.mem.endsWith(u8, quoted, "\" (abbreviated)"));
    try std.testing.expectEqual(@as(usize, 0), (quoted.len - 2 - " (abbreviated)".len) % 33);
}

test "messages are bounded at a UTF-8 boundary" {
    var diagnostic: Diagnostic = .{};
    var text: [6000]u8 = undefined;
    for (0..3000) |index| @memcpy(text[2 * index ..][0..2], "é");
    diagnostic.set(.invalid_document, null, "{s}", .{&text});
    try std.testing.expect(diagnostic.message().len <= limits.error_message_bytes_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(diagnostic.message()));
}
