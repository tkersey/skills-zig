const std = @import("std");

pub const Digest = struct {
    text: []u8,

    pub fn deinit(self: *Digest, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn digestRawJson(allocator: std.mem.Allocator, bytes: []const u8) !Digest {
    const canonical = try canonicalizeAlloc(allocator, bytes);
    defer allocator.free(canonical);
    return digestCanonicalBytes(allocator, canonical);
}

pub fn canonicalizeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeCanonicalValue(allocator, &out.writer, parsed.value);
    return out.toOwnedSlice();
}

pub fn digestCanonicalBytes(allocator: std.mem.Allocator, bytes: []const u8) !Digest {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return .{ .text = try std.fmt.allocPrint(allocator, "sha256:{s}", .{hex}) };
}

fn writeCanonicalValue(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |f| {
            if (!std.math.isFinite(f)) return error.NonFiniteNumber;
            try writer.print("{d}", .{f});
        },
        .number_string => |s| try writer.writeAll(s),
        .string => |s| try std.json.Stringify.value(s, .{}, writer),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writeCanonicalValue(allocator, writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            var fields: std.ArrayList(ObjectField) = .empty;
            defer fields.deinit(allocator);

            var it = object.iterator();
            while (it.next()) |entry| {
                try fields.append(allocator, .{
                    .key = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                });
            }
            std.mem.sort(ObjectField, fields.items, {}, ObjectField.lessThan);

            try writer.writeByte('{');
            for (fields.items, 0..) |field, index| {
                if (index > 0) try writer.writeByte(',');
                try std.json.Stringify.value(field.key, .{}, writer);
                try writer.writeByte(':');
                try writeCanonicalValue(allocator, writer, field.value);
            }
            try writer.writeByte('}');
        },
    }
}

const ObjectField = struct {
    key: []const u8,
    value: std.json.Value,

    fn lessThan(_: void, a: ObjectField, b: ObjectField) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

test "digest is sha256 prefixed" {
    var digest = try digestRawJson(std.testing.allocator, "{}");
    defer digest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 71), digest.text.len);
    try std.testing.expect(std.mem.startsWith(u8, digest.text, "sha256:"));
}

test "canonical JSON sorts object keys recursively" {
    const a = try canonicalizeAlloc(std.testing.allocator, "{\"b\":2,\"a\":{\"d\":4,\"c\":3}}");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("{\"a\":{\"c\":3,\"d\":4},\"b\":2}", a);

    var digest_a = try digestRawJson(std.testing.allocator, "{\"b\":2,\"a\":1}");
    defer digest_a.deinit(std.testing.allocator);
    var digest_b = try digestRawJson(std.testing.allocator, "{\"a\":1,\"b\":2}");
    defer digest_b.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(digest_a.text, digest_b.text);
}

test "canonical JSON preserves array order" {
    var digest_a = try digestRawJson(std.testing.allocator, "{\"items\":[1,2]}");
    defer digest_a.deinit(std.testing.allocator);
    var digest_b = try digestRawJson(std.testing.allocator, "{\"items\":[2,1]}");
    defer digest_b.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, digest_a.text, digest_b.text));
}
