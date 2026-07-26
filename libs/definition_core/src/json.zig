const std = @import("std");
const canonical_json = @import("canonical_json.zig");

pub fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ExpectedObject,
    };
}

pub fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |items| items,
        else => error.ExpectedArray,
    };
}

pub fn field(map: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return map.get(name) orelse error.MissingField;
}

pub fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

pub fn requiredString(map: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const text = try string(try field(map, name));
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidString;
    }
    return text;
}

pub fn optionalString(map: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = map.get(name) orelse return null;
    if (value == .null) return null;
    const text = try string(value);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidString;
    return text;
}

pub fn boolean(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |flag| flag,
        else => error.ExpectedBoolean,
    };
}

pub fn integer(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |number| number,
        else => error.ExpectedInteger,
    };
}

pub fn unsigned(value: std.json.Value) !usize {
    const number = try integer(value);
    if (number < 0) return error.ExpectedUnsigned;
    return std.math.cast(usize, number) orelse error.ExpectedUnsigned;
}

pub fn requireExactKeys(map: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |candidate| {
            if (std.mem.eql(u8, candidate, entry.key_ptr.*)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnknownField;
    }
}

pub fn requireFields(map: std.json.ObjectMap, names: []const []const u8) !void {
    for (names) |name| if (!map.contains(name)) return error.MissingField;
}

pub fn safeIdentifier(text: []const u8, max_bytes: usize) !void {
    if (text.len == 0 or text.len > max_bytes) return error.InvalidIdentifier;
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and
            byte != '.' and byte != '/')
        {
            return error.InvalidIdentifier;
        }
    }
    if (text[0] == '/' or text[text.len - 1] == '/' or
        std.mem.indexOf(u8, text, "//") != null)
    {
        return error.InvalidIdentifier;
    }
    var components = std.mem.splitScalar(u8, text, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidIdentifier;
        }
    }
}

pub fn digest(text: []const u8) !void {
    if (!canonical_json.isFingerprint(text)) return error.InvalidDigest;
}

pub fn repositoryRelativePath(text: []const u8, allow_root: bool) !void {
    if (text.len == 0 or std.fs.path.isAbsolute(text) or
        std.mem.indexOfScalar(u8, text, 0) != null or
        std.mem.indexOfScalar(u8, text, '\\') != null)
    {
        return error.InvalidRelativePath;
    }
    if (std.mem.eql(u8, text, ".")) {
        if (allow_root) return;
        return error.InvalidRelativePath;
    }
    if (text[text.len - 1] == '/') return error.InvalidRelativePath;
    var iterator = std.mem.splitScalar(u8, text, '/');
    while (iterator.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return error.InvalidRelativePath;
        }
        for (component) |byte| if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidRelativePath;
        };
    }
}

test "exact keys and common scalar boundaries fail closed" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"known\":true,\"extra\":false}",
        .{},
    );
    defer parsed.deinit();
    const map = try object(parsed.value);
    try std.testing.expectError(error.UnknownField, requireExactKeys(map, &.{"known"}));
    try safeIdentifier("owner/artifact-v1", 128);
    try std.testing.expectError(error.InvalidIdentifier, safeIdentifier("../escape", 128));
    try repositoryRelativePath("definitions/ledger/a.json", false);
    try std.testing.expectError(
        error.InvalidRelativePath,
        repositoryRelativePath("definitions/../a.json", false),
    );
}
