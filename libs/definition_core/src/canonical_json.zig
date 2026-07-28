const std = @import("std");
const exact_number = @import("exact_number.zig");

/// Canonical JSON support for bounded passive definitions and artifacts. This is not a claim
/// of full RFC 8785 compatibility: exact JSON number lexemes are preserved
/// without binary-float rounding, object keys are ordered by their raw UTF-8
/// bytes rather than by UTF-16 code units, and integer-shaped f64 values outside
/// the parser's i64 domain use scientific notation so they remain parse-closed.
const Omission = struct {
    key: ?[]const u8 = null,
    recursive: bool = false,
};

pub fn canonicalJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return canonicalJsonAllocWithOmission(allocator, value, .{});
}

/// Omits `key` from every object in the value.
pub fn canonicalJsonOmittingKeyAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) ![]u8 {
    return canonicalJsonAllocWithOmission(allocator, value, .{ .key = key, .recursive = true });
}

/// Omits `key` only from the root object.
pub fn canonicalObjectOmittingKeyAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) ![]u8 {
    if (value != .object) return error.ExpectedObject;
    return canonicalJsonAllocWithOmission(allocator, value, .{ .key = key });
}

fn canonicalJsonAllocWithOmission(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    omission: Omission,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try writeCanonicalJsonWithOmission(allocator, &out.writer, value, omission, 0);
    return out.toOwnedSlice();
}

pub fn writeCanonicalJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
) !void {
    try writeCanonicalJsonWithOmission(allocator, writer, value, .{}, 0);
}

fn writeCanonicalJsonWithOmission(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
    omission: Omission,
    depth: usize,
) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .integer => |number| try writer.print("{d}", .{number}),
        .float => |number| try writeCanonicalFloat(writer, number),
        .number_string => |text| try exact_number.writeCanonical(writer, text),
        .string => |text| try writeCanonicalString(writer, text),
        .array => |items| {
            try writer.writeByte('[');
            for (items.items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeCanonicalJsonWithOmission(allocator, writer, item, omission, depth + 1);
            }
            try writer.writeByte(']');
        },
        .object => |map| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(allocator);
            var iterator = map.iterator();
            while (iterator.next()) |entry| {
                const omit_here = omission.key != null and
                    std.mem.eql(u8, entry.key_ptr.*, omission.key.?) and
                    (omission.recursive or depth == 0);
                if (!omit_here) try keys.append(allocator, entry.key_ptr.*);
            }
            sortKeys(keys.items);
            try writer.writeByte('{');
            for (keys.items, 0..) |key, index| {
                if (index != 0) try writer.writeByte(',');
                try writeCanonicalString(writer, key);
                try writer.writeByte(':');
                try writeCanonicalJsonWithOmission(
                    allocator,
                    writer,
                    map.get(key).?,
                    omission,
                    depth + 1,
                );
            }
            try writer.writeByte('}');
        },
    }
}

const FloatLayout = struct {
    negative: bool,
    digits_buffer: [24]u8,
    digit_count: usize,
    exponent: i32,

    fn digits(self: *const FloatLayout) []const u8 {
        return self.digits_buffer[0..self.digit_count];
    }

    fn decimalPosition(self: FloatLayout) i32 {
        return self.exponent + 1;
    }
};

fn floatLayout(number: f64) !FloatLayout {
    var rendered_buffer: [std.fmt.float.min_buffer_size]u8 = undefined;
    const rendered = try std.fmt.float.render(&rendered_buffer, number, .{ .mode = .scientific });
    const exponent_marker = std.mem.indexOfScalar(u8, rendered, 'e') orelse
        return error.InvalidFloatRendering;
    const negative = rendered[0] == '-';
    const mantissa_start: usize = @intFromBool(negative);
    if (mantissa_start >= exponent_marker) return error.InvalidFloatRendering;

    var layout: FloatLayout = .{
        .negative = negative,
        .digits_buffer = undefined,
        .digit_count = 0,
        .exponent = 0,
    };
    for (rendered[mantissa_start..exponent_marker]) |byte| switch (byte) {
        '0'...'9' => {
            if (layout.digit_count == layout.digits_buffer.len) return error.InvalidFloatRendering;
            layout.digits_buffer[layout.digit_count] = byte;
            layout.digit_count += 1;
        },
        '.' => {},
        else => return error.InvalidFloatRendering,
    };
    if (layout.digit_count == 0) return error.InvalidFloatRendering;
    layout.exponent = std.fmt.parseInt(i32, rendered[exponent_marker + 1 ..], 10) catch
        return error.InvalidFloatRendering;
    return layout;
}

fn fixedIntegerFitsI64(layout: *const FloatLayout, position: usize) bool {
    std.debug.assert(layout.digit_count <= position);
    if (position < 19) return true;
    if (position > 19) return false;

    const limit = if (layout.negative) "9223372036854775808" else "9223372036854775807";
    for (0..position) |index| {
        const digit = if (index < layout.digit_count) layout.digits_buffer[index] else '0';
        if (digit < limit[index]) return true;
        if (digit > limit[index]) return false;
    }
    return true;
}

fn writeFixedFloat(writer: *std.Io.Writer, layout: *const FloatLayout, decimal_position: i32) !void {
    const digits = layout.digits();
    if (decimal_position > 0) {
        const position: usize = @intCast(decimal_position);
        if (layout.digit_count <= position) {
            try writer.writeAll(digits);
            try writer.splatByteAll('0', position - layout.digit_count);
        } else {
            try writer.writeAll(digits[0..position]);
            try writer.writeByte('.');
            try writer.writeAll(digits[position..]);
        }
        return;
    }

    try writer.writeAll("0.");
    try writer.splatByteAll('0', @intCast(-decimal_position));
    try writer.writeAll(digits);
}

fn writeScientificFloat(writer: *std.Io.Writer, layout: *const FloatLayout) !void {
    const digits = layout.digits();
    try writer.writeByte(digits[0]);
    if (layout.digit_count > 1) {
        try writer.writeByte('.');
        try writer.writeAll(digits[1..]);
    }
    try writer.writeByte('e');
    if (layout.exponent >= 0) try writer.writeByte('+');
    try writer.print("{d}", .{layout.exponent});
}

/// Serialize one finite f64 with a shortest-round-trip spelling. Ryu supplies
/// the digits; this versioned profile owns the fixed/scientific layout,
/// exponent sign, negative-zero rule, and parse-closure override.
pub fn writeCanonicalFloat(writer: *std.Io.Writer, number: f64) !void {
    if (!std.math.isFinite(number)) return error.NonFiniteNumber;
    if (number == 0) {
        try writer.writeByte('0');
        return;
    }

    const layout = try floatLayout(number);
    const decimal_position = layout.decimalPosition();

    if (layout.negative) try writer.writeByte('-');
    if (decimal_position > 0 and decimal_position <= 21) {
        const position: usize = @intCast(decimal_position);
        const integer_shaped = layout.digit_count <= position;
        if (!integer_shaped or fixedIntegerFitsI64(&layout, position)) {
            try writeFixedFloat(writer, &layout, decimal_position);
            return;
        }
    }
    if (decimal_position <= 0 and decimal_position > -6) {
        try writeFixedFloat(writer, &layout, decimal_position);
        return;
    }
    try writeScientificFloat(writer, &layout);
}

pub fn writeCanonicalString(writer: *std.Io.Writer, text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    try writer.writeByte('"');
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x09 => "\\t",
            0x0a => "\\n",
            0x0c => "\\f",
            0x0d => "\\r",
            0x00...0x07, 0x0b, 0x0e...0x1f => null,
            else => continue,
        };
        try writer.writeAll(text[start..index]);
        if (escape) |escaped| {
            try writer.writeAll(escaped);
        } else {
            try writer.writeAll("\\u00");
            const hex = "0123456789abcdef";
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
        start = index + 1;
    }
    try writer.writeAll(text[start..]);
    try writer.writeByte('"');
}

fn sortKeys(keys: [][]const u8) void {
    std.sort.heap([]const u8, keys, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
}

pub fn digestBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

pub fn digestValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const canonical = try canonicalJsonAlloc(allocator, value);
    defer allocator.free(canonical);
    return digestBytesAlloc(allocator, canonical);
}

pub fn fingerprintObjectOmittingAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    omitted: []const u8,
) ![]u8 {
    const canonical = try canonicalObjectOmittingKeyAlloc(allocator, value, omitted);
    defer allocator.free(canonical);
    return digestBytesAlloc(allocator, canonical);
}

pub fn finalizeFingerprintAlloc(
    allocator: std.mem.Allocator,
    json: []const u8,
    field: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |*map| map,
        else => return error.ExpectedObject,
    };
    const slot = object.getPtr(field) orelse return error.FingerprintFieldMissing;
    const fingerprint = try fingerprintObjectOmittingAlloc(allocator, parsed.value, field);
    defer allocator.free(fingerprint);
    slot.* = .{ .string = fingerprint };
    return canonicalJsonAlloc(allocator, parsed.value);
}

pub fn verifyFingerprintAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    field: []const u8,
) !bool {
    const object = switch (value) {
        .object => |map| map,
        else => return false,
    };
    const claimed = switch (object.get(field) orelse return false) {
        .string => |text| text,
        else => return false,
    };
    if (!isFingerprint(claimed)) return false;
    const computed = try fingerprintObjectOmittingAlloc(allocator, value, field);
    defer allocator.free(computed);
    return std.mem.eql(u8, claimed, computed);
}

pub fn isFingerprint(value: []const u8) bool {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) return false;
    for (value[7..]) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn expectCanonicalParseClosure(canonical: []const u8) !void {
    var reparsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        canonical,
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer reparsed.deinit();
    const repeated = try canonicalJsonAlloc(std.testing.allocator, reparsed.value);
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(canonical, repeated);
}

test "canonical JSON remains parse closed and rejects unsupported values" {
    const cases = [_]std.json.Value{
        .{ .float = 1.5 },
        .{ .float = 1.0e-7 },
        .{ .float = 9.223372036854776e18 },
    };
    for (cases) |value| {
        const encoded = try canonicalJsonAlloc(std.testing.allocator, value);
        defer std.testing.allocator.free(encoded);
        try expectCanonicalParseClosure(encoded);
    }
    const exact_integer = try canonicalJsonAlloc(
        std.testing.allocator,
        .{ .number_string = "9223372036854775808" },
    );
    defer std.testing.allocator.free(exact_integer);
    try std.testing.expectEqualStrings("9223372036854775808", exact_integer);
    try expectCanonicalParseClosure(exact_integer);
    try std.testing.expectError(
        error.InvalidNumber,
        canonicalJsonAlloc(std.testing.allocator, .{ .number_string = "01" }),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        canonicalJsonAlloc(std.testing.allocator, .{ .string = "\xff" }),
    );
}

test "canonical JSON preserves distinct exact fractional numbers" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "[9007199254740992.1,9007199254740992.2,1.2300e+2,-0.0000001]",
        .{ .parse_numbers = false },
    );
    defer parsed.deinit();
    const canonical = try canonicalJsonAlloc(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(
        "[9007199254740992.1,9007199254740992.2,123,-1e-7]",
        canonical,
    );
    var reparsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        canonical,
        .{ .parse_numbers = false },
    );
    defer reparsed.deinit();
    const repeated = try canonicalJsonAlloc(std.testing.allocator, reparsed.value);
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(canonical, repeated);
}

test "canonical omission modes preserve their declared depth" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"packet_id\":\"root\",\"nested\":{\"packet_id\":\"nested\",\"value\":1}}",
        .{},
    );
    defer parsed.deinit();
    const root_only = try canonicalObjectOmittingKeyAlloc(std.testing.allocator, parsed.value, "packet_id");
    defer std.testing.allocator.free(root_only);
    try std.testing.expectEqualStrings("{\"nested\":{\"packet_id\":\"nested\",\"value\":1}}", root_only);
    const recursive = try canonicalJsonOmittingKeyAlloc(std.testing.allocator, parsed.value, "packet_id");
    defer std.testing.allocator.free(recursive);
    try std.testing.expectEqualStrings("{\"nested\":{\"value\":1}}", recursive);
}

test "self fingerprint is canonical and tamper evident" {
    const finalized = try finalizeFingerprintAlloc(
        std.testing.allocator,
        "{\"schema\":\"example/v1\",\"value\":1,\"fingerprint\":\"\"}",
        "fingerprint",
    );
    defer std.testing.allocator.free(finalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, finalized, .{});
    defer parsed.deinit();
    try std.testing.expect(try verifyFingerprintAlloc(std.testing.allocator, parsed.value, "fingerprint"));
}
