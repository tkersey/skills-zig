const std = @import("std");

pub const form_bytes_max = 131072;
pub const parameters_max = 32;
pub const Pair = struct { name: []const u8, value: []const u8 };

pub const Fields = struct {
    allocator: std.mem.Allocator,
    pairs: []Pair,

    pub fn deinit(self: *Fields) void {
        for (self.pairs) |pair| {
            self.allocator.free(pair.name);
            self.allocator.free(pair.value);
        }
        self.allocator.free(self.pairs);
        self.* = undefined;
    }

    pub fn get(self: Fields, name: []const u8) ?[]const u8 {
        for (self.pairs) |pair| {
            if (std.mem.eql(u8, pair.name, name)) return pair.value;
        }
        return null;
    }
};

pub fn encodeForm(allocator: std.mem.Allocator, pairs: []const Pair) ![]u8 {
    if (pairs.len > parameters_max) return error.TooManyParameters;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (pairs, 0..) |pair, index| {
        if (index != 0) try appendByte(allocator, &output, '&');
        try appendEncoded(allocator, &output, pair.name);
        try appendByte(allocator, &output, '=');
        try appendEncoded(allocator, &output, pair.value);
    }
    return output.toOwnedSlice(allocator);
}

fn appendByte(allocator: std.mem.Allocator, output: *std.ArrayList(u8), byte: u8) !void {
    if (output.items.len == form_bytes_max) return error.FormTooLarge;
    try output.append(allocator, byte);
}

fn appendEncoded(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        const plain = std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, "-._~", byte) != null;
        const needed: usize = if (plain) 1 else 3;
        if (output.items.len > form_bytes_max - needed) return error.FormTooLarge;
        if (plain) {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 15] });
        }
    }
}

pub fn parseForm(allocator: std.mem.Allocator, bytes: []const u8) !Fields {
    if (bytes.len == 0 or bytes.len > form_bytes_max) return error.InvalidForm;
    var pairs: std.ArrayList(Pair) = .empty;
    errdefer {
        for (pairs.items) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        pairs.deinit(allocator);
    }
    var parts = std.mem.splitScalar(u8, bytes, '&');
    while (parts.next()) |part| {
        if (pairs.items.len == parameters_max) return error.TooManyParameters;
        const separator = std.mem.indexOfScalar(u8, part, '=') orelse
            return error.InvalidForm;
        const name = try decode(allocator, part[0..separator]);
        errdefer allocator.free(name);
        if (name.len == 0) return error.InvalidForm;
        for (pairs.items) |existing| {
            if (std.mem.eql(u8, name, existing.name)) return error.DuplicateParameter;
        }
        const value = try decode(allocator, part[separator + 1 ..]);
        errdefer allocator.free(value);
        try pairs.append(allocator, .{ .name = name, .value = value });
    }
    return .{ .allocator = allocator, .pairs = try pairs.toOwnedSlice(allocator) };
}

fn decode(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, source.len);
    errdefer allocator.free(result);
    var offset: usize = 0;
    var length: usize = 0;
    while (offset < source.len) {
        const byte = switch (source[offset]) {
            '%' => value: {
                if (source.len - offset < 3) return error.InvalidEncoding;
                const high = std.fmt.charToDigit(source[offset + 1], 16) catch
                    return error.InvalidEncoding;
                const low = std.fmt.charToDigit(source[offset + 2], 16) catch
                    return error.InvalidEncoding;
                offset += 2;
                break :value high * 16 + low;
            },
            '+' => ' ',
            else => source[offset],
        };
        if (byte < 0x20 or byte == 0x7f) return error.InvalidEncoding;
        result[length] = byte;
        length += 1;
        offset += 1;
    }
    if (!std.unicode.utf8ValidateSlice(result[0..length])) return error.InvalidEncoding;
    return allocator.realloc(result, length);
}

pub fn decodeBase64(allocator: std.mem.Allocator, value: []const u8, limit: usize) ![]u8 {
    const codec = std.base64.url_safe_no_pad;
    const length = codec.Decoder.calcSizeForSlice(value) catch return error.InvalidBase64;
    if (length == 0 or length > limit) return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, length);
    errdefer allocator.free(decoded);
    codec.Decoder.decode(decoded, value) catch return error.InvalidBase64;
    const canonical = try allocator.alloc(u8, codec.Encoder.calcSize(length));
    defer allocator.free(canonical);
    _ = codec.Encoder.encode(canonical, decoded);
    if (!std.mem.eql(u8, canonical, value)) return error.InvalidBase64;
    return decoded;
}

pub fn secretEqual(left: []const u8, right: []const u8) bool {
    var left_hash: [32]u8 = undefined;
    var right_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(left, &left_hash, .{});
    std.crypto.hash.sha2.Sha256.hash(right, &right_hash, .{});
    return std.crypto.timing_safe.eql([32]u8, left_hash, right_hash);
}

test "form encoding preserves opaque punctuation and rejects ambiguous inputs" {
    const allocator = std.testing.allocator;
    const encoded = try encodeForm(allocator, &.{.{ .name = "value", .value = "a +&=/%" }});
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("value=a%20%2B%26%3D%2F%25", encoded);
    var fields = try parseForm(allocator, encoded);
    defer fields.deinit();
    try std.testing.expectEqualStrings("a +&=/%", fields.get("value").?);
    const bad = [_][]const u8{ "", "a", "=b", "a=%", "a=%zz", "a=%00", "a=%FF" };
    for (bad) |input| {
        if (parseForm(allocator, input)) |result| {
            var unexpected = result;
            unexpected.deinit();
            return error.ExpectedRejection;
        } else |_| {}
    }
    try std.testing.expectError(error.DuplicateParameter, parseForm(allocator, "a=1&%61=2"));
}

test "base64 accepts only canonical unpadded URL encoding" {
    const allocator = std.testing.allocator;
    const bytes = try decodeBase64(allocator, "YQ", 1);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("a", bytes);
    for ([_][]const u8{ "", "YQ==", "YR", "YQ+", "YWI" }) |input| {
        try std.testing.expectError(error.InvalidBase64, decodeBase64(allocator, input, 1));
    }
    try std.testing.expect(secretEqual("opaque", "opaque"));
    try std.testing.expect(!secretEqual("opaque", "different"));
}

test "form output and parameter counts enforce their exact limits" {
    const allocator = std.testing.allocator;
    const value = try allocator.alloc(u8, form_bytes_max);
    defer allocator.free(value);
    @memset(value, 'a');
    const valid = try encodeForm(allocator, &.{.{
        .name = "k",
        .value = value[0 .. value.len - 2],
    }});
    defer allocator.free(valid);
    try std.testing.expectEqual(form_bytes_max, valid.len);
    try std.testing.expectError(error.FormTooLarge, encodeForm(
        allocator,
        &.{.{ .name = "k", .value = value[0 .. value.len - 1] }},
    ));
    try std.testing.expectError(error.FormTooLarge, encodeForm(
        allocator,
        &.{.{ .name = value, .value = "" }},
    ));
    const pairs: [parameters_max + 1]Pair = @splat(.{ .name = "a", .value = "b" });
    try std.testing.expectError(error.TooManyParameters, encodeForm(allocator, &pairs));
}
