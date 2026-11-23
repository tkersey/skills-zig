const std = @import("std");
const limits = @import("limits.zig");
const diag = @import("diag.zig");
const exact_number = @import("exact_number");

const Value = std.json.Value;
const Loc = diag.Loc;
const Diagnostic = diag.Diagnostic;

const Frame = struct {
    value: Value,
    key: ?[]const u8 = null,
};

pub fn parse(
    arena: std.mem.Allocator,
    bytes: []const u8,
    d: *Diagnostic,
    role: []const u8,
) diag.Error!Value {
    if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) {
        return d.fail(.invalid_json, null, "{s}: byte order mark is not permitted", .{role});
    }
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return d.fail(.invalid_json, null, "{s}: input is not valid UTF-8", .{role});
    }
    var scanner = std.json.Scanner.initCompleteInput(arena, bytes);
    var parser: Parser = .{ .arena = arena, .d = d, .role = role };
    var result: ?Value = null;
    var tokens: usize = 0;
    while (tokens <= bytes.len + 1) : (tokens += 1) {
        const next = scanner.nextAllocMax(arena, .alloc_always, bytes.len);
        const token = next catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return parser.fail(.invalid_json, "{s}: malformed JSON", .{role}),
        };
        if (token == .end_of_document) return result.?;
        const value = try parser.step(token) orelse continue;
        if (parser.depth == 0) {
            result = value;
        } else {
            try parser.attach(value);
        }
    }
    return d.fail(.invalid_json, null, "{s}: token count exceeded input length", .{role});
}

const Parser = struct {
    arena: std.mem.Allocator,
    d: *Diagnostic,
    role: []const u8,
    stack: [limits.json_depth_max]Frame = undefined,
    depth: usize = 0,

    fn fail(
        self: *const Parser,
        code: diag.Code,
        comptime format: []const u8,
        arguments: anytype,
    ) error{Rejected} {
        return failAt(self.d, code, self.stack[0..self.depth], format, arguments);
    }

    fn step(self: *Parser, token: std.json.Token) diag.Error!?Value {
        switch (token) {
            .object_begin, .array_begin => {
                try self.open(token == .object_begin);
                return null;
            },
            .object_end, .array_end => {
                self.depth -= 1;
                return self.stack[self.depth].value;
            },
            .allocated_string => |text| return self.string(text),
            .allocated_number => |text| return self.number(text),
            .true => return .{ .bool = true },
            .false => return .{ .bool = false },
            .null => return .null,
            else => unreachable,
        }
    }

    fn open(self: *Parser, is_object: bool) error{Rejected}!void {
        if (self.depth == limits.json_depth_max) {
            return self.fail(.resource_limit, "{s}: nesting exceeds {d}", .{
                self.role, limits.json_depth_max,
            });
        }
        self.stack[self.depth] = .{ .value = if (is_object)
            .{ .object = .empty }
        else
            .{ .array = .init(self.arena) } };
        self.depth += 1;
    }

    fn string(self: *Parser, text: []const u8) error{Rejected}!?Value {
        const top: ?*Frame = if (self.depth > 0) &self.stack[self.depth - 1] else null;
        if (top != null and top.?.value == .object and top.?.key == null) {
            top.?.key = text;
            if (top.?.value.object.contains(text)) {
                return self.fail(.duplicate_key, "{s}: duplicate key", .{self.role});
            }
            return null;
        }
        return .{ .string = text };
    }

    fn number(self: *const Parser, text: []const u8) error{Rejected}!?Value {
        if (text.len > limits.number_bytes_max) {
            return self.fail(.resource_limit, "{s}: number token exceeds {d} bytes", .{
                self.role, limits.number_bytes_max,
            });
        }
        return .{ .number_string = text };
    }

    fn attach(self: *Parser, value: Value) error{OutOfMemory}!void {
        const top = &self.stack[self.depth - 1];
        switch (top.value) {
            .object => |*object| {
                try object.put(self.arena, top.key.?, value);
                top.key = null;
            },
            .array => |*array| try array.append(value),
            else => unreachable,
        }
    }
};

fn failAt(
    d: *Diagnostic,
    code: diag.Code,
    frames: []const Frame,
    comptime format: []const u8,
    arguments: anytype,
) error{Rejected} {
    var storage: [limits.json_depth_max + 1]Loc = undefined;
    storage[0] = Loc.root;
    var count: usize = 1;
    for (frames) |frame| {
        const parent = &storage[count - 1];
        switch (frame.value) {
            .object => {
                const name = frame.key orelse break;
                storage[count] = parent.key(name);
            },
            .array => |array| storage[count] = parent.index(array.items.len),
            else => unreachable,
        }
        count += 1;
    }
    return d.fail(code, &storage[count - 1], format, arguments);
}

pub const Scalar = union(enum) {
    null,
    boolean: bool,
    number: []const u8,
    string: []const u8,

    pub fn eql(left: Scalar, right: Scalar) bool {
        return switch (left) {
            .null => right == .null,
            .boolean => |value| right == .boolean and right.boolean == value,
            .string => |value| right == .string and std.mem.eql(u8, value, right.string),
            .number => |value| right == .number and exact_number.valuesEqual(
                .{ .number_string = value },
                .{ .number_string = right.number },
            ),
        };
    }

    pub fn write(self: Scalar, writer: *std.Io.Writer) !void {
        switch (self) {
            .null => try writer.writeAll("null"),
            .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
            .number => |value| try writer.writeAll(value),
            .string => |value| try std.json.Stringify.encodeJsonString(value, .{}, writer),
        }
    }
};

pub const Fields = struct {
    map: *const std.json.ObjectMap,
    loc: *const Loc,
    d: *Diagnostic,
    role: []const u8,

    pub fn of(d: *Diagnostic, role: []const u8, loc: *const Loc, value: *const Value) !Fields {
        if (value.* != .object) {
            return d.fail(.invalid_document, loc, "{s}: object required", .{role});
        }
        return .{ .map = &value.object, .loc = loc, .d = d, .role = role };
    }

    pub fn document(
        d: *Diagnostic,
        role: []const u8,
        value: *const Value,
        expected_schema: []const u8,
        required: []const []const u8,
    ) error{Rejected}!Fields {
        const fields = try of(d, role, &Loc.root, value);
        try fields.schema(expected_schema);
        try fields.closed(required);
        return fields;
    }

    pub fn closed(self: Fields, required: []const []const u8) error{Rejected}!void {
        for (self.map.keys()) |name| {
            if (!contains(required, name)) {
                const where = self.loc.key(name);
                return self.d.fail(.invalid_document, &where, "{s}: unknown field", .{self.role});
            }
        }
        for (required) |name| _ = try self.field(name);
    }

    pub fn field(self: Fields, name: []const u8) error{Rejected}!*const Value {
        if (self.map.getPtr(name)) |value| return value;
        const where = self.loc.key(name);
        return self.d.fail(.invalid_document, &where, "{s}: missing field", .{self.role});
    }

    pub fn reject(
        self: Fields,
        code: diag.Code,
        name: []const u8,
        comptime format: []const u8,
        arguments: anytype,
    ) error{Rejected} {
        const where = self.loc.key(name);
        return self.d.fail(code, &where, "{s}: " ++ format, .{self.role} ++ arguments);
    }

    pub fn schema(self: Fields, expected: []const u8) error{Rejected}!void {
        const value = try self.field("schema");
        if (value.* == .string and std.mem.eql(u8, value.string, expected)) return;
        return self.reject(.unsupported_schema, "schema", "expected schema {s}", .{expected});
    }

    pub fn text(self: Fields, name: []const u8, bytes_max: u64, nonempty: bool) ![]const u8 {
        const value = try self.field(name);
        if (value.* != .string) return self.reject(.invalid_document, name, "string required", .{});
        if (value.string.len > bytes_max) {
            return self.reject(.resource_limit, name, "text exceeds {d} bytes", .{bytes_max});
        }
        if (nonempty and value.string.len == 0) {
            return self.reject(.invalid_document, name, "nonempty text required", .{});
        }
        return value.string;
    }

    pub fn identifier(self: Fields, name: []const u8) ![]const u8 {
        const value = try self.field(name);
        if (value.* == .string and isIdentifier(value.string)) return value.string;
        return self.reject(.invalid_document, name, "identifier required", .{});
    }

    pub fn digest(self: Fields, name: []const u8) ![]const u8 {
        const value = try self.field(name);
        if (value.* == .string and isDigest(value.string)) return value.string;
        return self.reject(
            .invalid_document,
            name,
            "64 lowercase hexadecimal digits required",
            .{},
        );
    }

    pub fn boolean(self: Fields, name: []const u8) !bool {
        const value = try self.field(name);
        if (value.* == .bool) return value.bool;
        return self.reject(.invalid_document, name, "boolean required", .{});
    }

    pub fn count(self: Fields, name: []const u8, maximum: u64) !u64 {
        const value = try self.field(name);
        const decoded: Unsigned = if (value.* == .number_string)
            decodeUnsigned(value.number_string)
        else
            .invalid;
        switch (decoded) {
            .invalid => {
                return self.reject(.invalid_document, name, "unsigned integer required", .{});
            },
            .too_large => {
                return self.reject(.resource_limit, name, "value exceeds {d}", .{maximum});
            },
            .value => |parsed| {
                if (parsed > maximum) {
                    return self.reject(.resource_limit, name, "value exceeds {d}", .{maximum});
                }
                return parsed;
            },
        }
    }

    pub fn enumeration(self: Fields, comptime E: type, name: []const u8) !E {
        const value = try self.field(name);
        if (value.* == .string) {
            if (std.meta.stringToEnum(E, value.string)) |result| return result;
        }
        return self.reject(.invalid_document, name, "unsupported value", .{});
    }

    pub fn array(self: Fields, name: []const u8, maximum: u32) ![]const Value {
        const value = try self.field(name);
        if (value.* != .array) return self.reject(.invalid_document, name, "array required", .{});
        if (value.array.items.len > maximum) {
            return self.reject(.resource_limit, name, "more than {d} entries", .{maximum});
        }
        return value.array.items;
    }

    pub fn object(self: Fields, name: []const u8, storage: *Loc) !Fields {
        storage.* = self.loc.key(name);
        return of(self.d, self.role, storage, try self.field(name));
    }

    pub fn scalar(self: Fields, name: []const u8) !Scalar {
        const value = try self.field(name);
        return switch (value.*) {
            .null => .null,
            .bool => |flag| .{ .boolean = flag },
            .number_string => |token| if (exact_number.parse(token) != null)
                .{ .number = token }
            else
                self.reject(.invalid_document, name, "number exceeds exact-number limits", .{}),
            .string => |bytes| if (bytes.len <= limits.text_bytes_max)
                .{ .string = bytes }
            else
                self.reject(
                    .resource_limit,
                    name,
                    "text exceeds {d} bytes",
                    .{limits.text_bytes_max},
                ),
            else => self.reject(.invalid_document, name, "JSON scalar required", .{}),
        };
    }
};

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

pub fn isIdentifier(text: []const u8) bool {
    if (text.len == 0 or text.len > limits.id_bytes_max) return false;
    if (!std.ascii.isAlphanumeric(text[0])) return false;
    for (text[1..]) |byte| {
        const allowed = std.ascii.isAlphanumeric(byte) or switch (byte) {
            '.', '_', ':', '/', '-' => true,
            else => false,
        };
        if (!allowed) return false;
    }
    return true;
}

pub fn isDigest(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |byte| {
        const hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!hex) return false;
    }
    return true;
}

pub const Unsigned = union(enum) {
    value: u64,
    invalid,
    too_large,
};

fn classifyUnparsed(token: []const u8) Unsigned {
    const exponent_at = std.mem.indexOfAny(u8, token, "eE") orelse return .invalid;
    const mantissa = token[0..exponent_at];
    const nonzero = std.mem.indexOfNone(u8, mantissa, "-0.") != null;
    if (!nonzero) return .{ .value = 0 };
    if (mantissa[0] == '-') return .invalid;
    const exponent = token[exponent_at + 1 ..];
    if (exponent.len > 0 and exponent[0] == '-') return .invalid;
    return .too_large;
}

pub fn decodeUnsigned(token: []const u8) Unsigned {
    const number = exact_number.parse(token) orelse return classifyUnparsed(token);
    if (number.significant_len == 0) return .{ .value = 0 };
    if (number.negative or number.scale < 0) return .invalid;
    const digits_max = std.math.log10_int(@as(u64, std.math.maxInt(u64))) + 1;
    if (number.scale > digits_max or number.significant_len > digits_max) return .too_large;
    var result: u64 = 0;
    for (0..number.significant_len) |index| {
        result = std.math.mul(u64, result, 10) catch return .too_large;
        result = std.math.add(u64, result, number.digit(index) - '0') catch return .too_large;
    }
    for (0..@intCast(number.scale)) |_| {
        result = std.math.mul(u64, result, 10) catch return .too_large;
    }
    return .{ .value = result };
}

const testing = std.testing;

fn repeat(comptime byte: u8, comptime count: usize) [count]u8 {
    return @splat(byte);
}

fn expectRejected(bytes: []const u8, code: diag.Code, location: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try testing.expectError(error.Rejected, parse(arena.allocator(), bytes, &d, "test"));
    try testing.expectEqual(code, d.code);
    if (location) |expected| {
        try testing.expectEqualStrings(expected, d.location().?);
    }
}

test "strict parsing rejects malformed, encoded, and duplicate input" {
    try expectRejected("\xef\xbb\xbf{}", .invalid_json, null);
    try expectRejected("{\"a\":\"\xff\"}", .invalid_json, null);
    try expectRejected("{\"a\":\"\\ud800\"}", .invalid_json, null);
    try expectRejected("{\"a\":1,}", .invalid_json, null);
    try expectRejected("{} {}", .invalid_json, null);
    try expectRejected("", .invalid_json, null);
    try expectRejected("{\"a\":1,\"\\u0061\":2}", .duplicate_key, "/a");
    try expectRejected("{\"x\":[{\"k\":1},{\"k\":1,\"k\":2}]}", .duplicate_key, "/x/1/k");
    try expectRejected("{\"x\":{\"y\":{\"z\":1,\"z\":1}}}", .duplicate_key, "/x/y/z");
}

test "depth and number bounds apply at and above their limits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const at_limit = try std.mem.concat(allocator, u8, &.{
        &repeat('[', limits.json_depth_max),
        &repeat(']', limits.json_depth_max),
    });
    var d: Diagnostic = .{};
    _ = try parse(allocator, at_limit, &d, "test");
    const above = try std.mem.concat(allocator, u8, &.{ "[", at_limit, "]" });
    try expectRejected(above, .resource_limit, null);
    const digits = repeat('1', limits.number_bytes_max);
    _ = try parse(allocator, "[" ++ digits ++ "]", &d, "test");
    try expectRejected("[" ++ digits ++ "1]", .resource_limit, "/0");
}

test "parsing preserves decoded strings, number tokens, and key order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const value = try parse(arena.allocator(), "{\"b\":1.0e0,\"a\":\"\\u00e9\"}", &d, "t");
    try testing.expectEqualStrings("b", value.object.keys()[0]);
    try testing.expectEqualStrings("1.0e0", value.object.get("b").?.number_string);
    try testing.expectEqualStrings("é", value.object.get("a").?.string);
}

test "scalar equality is typed and exact" {
    const one: Scalar = .{ .number = "1" };
    try testing.expect(one.eql(.{ .number = "1.0" }));
    try testing.expect(one.eql(.{ .number = "1e0" }));
    try testing.expect((Scalar{ .number = "-0" }).eql(.{ .number = "0" }));
    try testing.expect(!one.eql(.{ .string = "1" }));
    try testing.expect(!(Scalar{ .boolean = false }).eql(.{ .number = "0" }));
    try testing.expect(!(Scalar{ .string = "" }).eql(.null));
    try testing.expect((@as(Scalar, .null)).eql(.null));
    try testing.expect(!(Scalar{ .number = "9007199254740993" }).eql(.{
        .number = "9007199254740992",
    }));
    try testing.expect(!(Scalar{ .string = "\u{e9}" }).eql(.{ .string = "e\u{301}" }));
}

test "identifier and digest grammars" {
    try testing.expect(isIdentifier("codec-observer/v1"));
    try testing.expect(isIdentifier(&repeat('a', 128)));
    try testing.expect(!isIdentifier(&repeat('a', 129)));
    try testing.expect(!isIdentifier(""));
    try testing.expect(!isIdentifier("-a"));
    try testing.expect(!isIdentifier("a b"));
    try testing.expect(isDigest(&repeat('0', 64)));
    try testing.expect(!isDigest(&repeat('A', 64)));
    try testing.expect(!isDigest(&repeat('0', 63)));
}

test "unsigned integers accept every exact spelling and reject overflow" {
    const accepted = [_]struct { []const u8, u64 }{
        .{ "0", 0 },
        .{ "-0", 0 },
        .{ "0.0e5", 0 },
        .{ "224", 224 },
        .{ "224.0", 224 },
        .{ "2.24e2", 224 },
        .{ "1e3", 1000 },
        .{ "18446744073709551615", std.math.maxInt(u64) },
        .{ "1.8446744073709551615e19", std.math.maxInt(u64) },
        .{ "0e99999999999999999999", 0 },
        .{ "-0.0e-99999999999999999999", 0 },
    };
    for (accepted) |case| {
        try testing.expectEqual(Unsigned{ .value = case[1] }, decodeUnsigned(case[0]));
    }
    const invalid = [_][]const u8{
        "-1", "1.5", "2.245e2", "1e-1", "1e-99999999999999999999", "-1e99999999999999999999",
    };
    for (invalid) |token| {
        try testing.expectEqual(Unsigned.invalid, decodeUnsigned(token));
    }
    const huge = [_][]const u8{
        "18446744073709551616",   "99999999999999999999",    "1e20", "1e999",
        "1e99999999999999999999", "2E+99999999999999999999",
    };
    for (huge) |token| {
        try testing.expectEqual(Unsigned.too_large, decodeUnsigned(token));
    }
}

test "string tokens beyond the scanner default are retained whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body = try allocator.alloc(u8, 5 * 1024 * 1024);
    @memset(body, 'x');
    const document = try std.mem.concat(allocator, u8, &.{ "{\"s\":\"", body, "\"}" });
    var d: Diagnostic = .{};
    const value = try parse(allocator, document, &d, "test");
    try testing.expectEqual(body.len, value.object.get("s").?.string.len);
}
