const std = @import("std");

pub const Pointer = struct {
    raw: []u8,
    segments: [][]u8,

    pub fn deinit(self: *Pointer, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
        for (self.segments) |segment| allocator.free(segment);
        allocator.free(self.segments);
        self.* = undefined;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !Pointer {
    if (raw.len != 0 and raw[0] != '/') return error.InvalidJsonPointer;
    var segments: std.ArrayList([]u8) = .empty;
    errdefer {
        for (segments.items) |segment| allocator.free(segment);
        segments.deinit(allocator);
    }
    if (raw.len != 0) {
        var iterator = std.mem.splitScalar(u8, raw[1..], '/');
        while (iterator.next()) |encoded| {
            var decoded: std.Io.Writer.Allocating = .init(allocator);
            errdefer decoded.deinit();
            var index: usize = 0;
            while (index < encoded.len) : (index += 1) {
                if (encoded[index] != '~') {
                    try decoded.writer.writeByte(encoded[index]);
                    continue;
                }
                if (index + 1 >= encoded.len) {
                    return error.InvalidJsonPointer;
                }
                index += 1;
                try decoded.writer.writeByte(switch (encoded[index]) {
                    '0' => '~',
                    '1' => '/',
                    else => return error.InvalidJsonPointer,
                });
            }
            const segment = try decoded.toOwnedSlice();
            errdefer allocator.free(segment);
            try segments.append(allocator, segment);
        }
    }
    const owned_raw = try allocator.dupe(u8, raw);
    errdefer allocator.free(owned_raw);
    return .{
        .raw = owned_raw,
        .segments = try segments.toOwnedSlice(allocator),
    };
}

pub fn lookup(root: std.json.Value, pointer: Pointer) ?std.json.Value {
    var current = root;
    for (pointer.segments) |segment| {
        current = switch (current) {
            .object => |object| object.get(segment) orelse return null,
            .array => |array| blk: {
                if (segment.len == 0 or
                    (segment.len > 1 and segment[0] == '0'))
                {
                    return null;
                }
                const index = std.fmt.parseInt(
                    usize,
                    segment,
                    10,
                ) catch return null;
                if (index >= array.items.len) return null;
                break :blk array.items[index];
            },
            else => return null,
        };
    }
    return current;
}

pub fn lookupPtr(
    root: *std.json.Value,
    pointer: Pointer,
) ?*std.json.Value {
    var current = root;
    for (pointer.segments) |segment| {
        current = switch (current.*) {
            .object => |*object| object.getPtr(segment) orelse return null,
            .array => |*array| blk: {
                if (segment.len == 0 or
                    (segment.len > 1 and segment[0] == '0'))
                {
                    return null;
                }
                const index = std.fmt.parseInt(
                    usize,
                    segment,
                    10,
                ) catch return null;
                if (index >= array.items.len) return null;
                break :blk &array.items[index];
            },
            else => return null,
        };
    }
    return current;
}

test "compiled JSON pointers look up escaped object and array segments" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"a/b\":[{\"~key\":\"value\"}]}",
        .{},
    );
    defer parsed.deinit();
    var pointer = try compile(
        std.testing.allocator,
        "/a~1b/0/~0key",
    );
    defer pointer.deinit(std.testing.allocator);
    const value = lookup(parsed.value, pointer) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("value", value.string);
    const mutable = lookupPtr(&parsed.value, pointer) orelse
        return error.TestExpectedEqual;
    mutable.* = .{ .string = "changed" };
    try std.testing.expectEqualStrings(
        "changed",
        lookup(parsed.value, pointer).?.string,
    );
    try std.testing.expectError(
        error.InvalidJsonPointer,
        compile(std.testing.allocator, "/bad~2escape"),
    );
}
