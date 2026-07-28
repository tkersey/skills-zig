const std = @import("std");
const cache = @import("cache.zig");
const canonical_json = @import("canonical_json.zig");
const json = @import("json.zig");
const scalar = @import("scalar.zig");

pub const Declaration = struct {
    name: []u8,
    kind: scalar.Kind,
    required: bool,
    default_value: ?scalar.Value = null,

    fn deinit(self: *Declaration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.default_value) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

pub const Declarations = struct {
    items: []Declaration,
    shape_digest: [71]u8,

    pub fn deinit(self: *Declarations, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }

    pub fn find(self: *const Declarations, name: []const u8) ?*const Declaration {
        var low: usize = 0;
        var high = self.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.items[mid].name, name)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return &self.items[mid],
            }
        }
        return null;
    }
};

pub const Input = struct {
    name: []const u8,
    raw_value: []const u8,
};

pub const Binding = struct {
    name: []u8,
    value: scalar.Value,

    fn deinit(self: *Binding, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const Bindings = struct {
    items: []Binding,
    values_digest: [71]u8,

    pub fn find(self: *const Bindings, name: []const u8) ?*const Binding {
        var low: usize = 0;
        var high = self.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.items[mid].name, name)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return &self.items[mid],
            }
        }
        return null;
    }

    pub fn deinit(self: *Bindings, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) !Declarations {
    var items: std.ArrayList(Declaration) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    const present = value orelse return .{
        .items = try items.toOwnedSlice(allocator),
        .shape_digest = digestDeclarations(items.items),
    };
    const map = try json.object(present);
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        try json.safeIdentifier(entry.key_ptr.*, 128);
        const declaration = try json.object(entry.value_ptr.*);
        try json.requireExactKeys(declaration, &.{ "type", "required", "default" });
        const kind = try scalar.Kind.parse(try json.requiredString(declaration, "type"));
        const required = if (declaration.get("required")) |raw|
            try json.boolean(raw)
        else
            declaration.get("default") == null;
        var default_value: ?scalar.Value = null;
        errdefer if (default_value) |*item| item.deinit(allocator);
        if (declaration.get("default")) |raw| {
            default_value = try scalar.fromJsonAlloc(allocator, kind, raw);
        }
        if (required and default_value != null) return error.RequiredParameterHasDefault;
        const owned_name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(owned_name);
        try items.append(allocator, .{
            .name = owned_name,
            .kind = kind,
            .required = required,
            .default_value = default_value,
        });
        default_value = null;
    }
    std.sort.heap(Declaration, items.items, {}, lessThanDeclaration);
    const shape_digest = digestDeclarations(items.items);
    return .{
        .items = try items.toOwnedSlice(allocator),
        .shape_digest = shape_digest,
    };
}

pub fn bind(
    allocator: std.mem.Allocator,
    declarations: *const Declarations,
    inputs: []const Input,
) !Bindings {
    return bindMode(allocator, declarations, inputs, true);
}

pub fn bindProvided(
    allocator: std.mem.Allocator,
    declarations: *const Declarations,
    inputs: []const Input,
) !Bindings {
    return bindMode(allocator, declarations, inputs, false);
}

fn bindMode(
    allocator: std.mem.Allocator,
    declarations: *const Declarations,
    inputs: []const Input,
    require_all: bool,
) !Bindings {
    var items: std.ArrayList(Binding) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    for (inputs) |input| {
        const declaration = declarations.find(input.name) orelse
            return error.UnknownParameter;
        for (items.items) |prior| {
            if (std.mem.eql(u8, prior.name, input.name)) return error.DuplicateParameter;
        }
        var value = try scalar.parseAlloc(allocator, declaration.kind, input.raw_value);
        errdefer value.deinit(allocator);
        const owned_name = try allocator.dupe(u8, input.name);
        errdefer allocator.free(owned_name);
        try items.append(allocator, .{
            .name = owned_name,
            .value = value,
        });
    }
    for (declarations.items) |declaration| {
        var found = false;
        for (items.items) |item| if (std.mem.eql(u8, item.name, declaration.name)) {
            found = true;
            break;
        };
        if (found) continue;
        if (declaration.default_value) |default_value| {
            var value = try cloneValue(allocator, default_value);
            errdefer value.deinit(allocator);
            const owned_name = try allocator.dupe(u8, declaration.name);
            errdefer allocator.free(owned_name);
            try items.append(allocator, .{
                .name = owned_name,
                .value = value,
            });
        } else if (require_all and declaration.required) {
            return error.MissingParameter;
        }
    }
    std.sort.heap(Binding, items.items, {}, lessThanBinding);
    const values_digest = try digestBindings(items.items);
    return .{
        .items = try items.toOwnedSlice(allocator),
        .values_digest = values_digest,
    };
}

pub fn encodeCache(
    declarations: *const Declarations,
    encoder: *cache.Encoder,
) !void {
    try encoder.writeCount(declarations.items.len);
    for (declarations.items) |declaration| {
        try encoder.writeBytes(declaration.name);
        try encoder.writeEnum(declaration.kind);
        try encoder.writeBool(declaration.required);
        try encoder.writeBool(declaration.default_value != null);
        if (declaration.default_value) |value| {
            if (value.kind() != declaration.kind) {
                return error.CacheParameterKindMismatch;
            }
            try encodeScalar(value, encoder);
        }
    }
}

pub fn decodeCache(
    allocator: std.mem.Allocator,
    decoder: *cache.Decoder,
) !Declarations {
    const count = try decoder.readCount(65_535);
    const items = try allocator.alloc(Declaration, count);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    for (items, 0..) |*item, index| {
        const name = try decoder.readBytesAlloc(allocator, 128);
        errdefer allocator.free(name);
        try json.safeIdentifier(name, 128);
        if (index != 0 and
            std.mem.order(u8, items[index - 1].name, name) != .lt)
        {
            return error.CacheParametersNotSorted;
        }
        const kind = try decoder.readEnum(scalar.Kind);
        const required = try decoder.readBool();
        const has_default = try decoder.readBool();
        if (required and has_default) return error.RequiredParameterHasDefault;
        const default_value = if (has_default)
            try decodeScalar(allocator, decoder, kind)
        else
            null;
        errdefer if (default_value) |*value| value.deinit(allocator);
        item.* = .{
            .name = name,
            .kind = kind,
            .required = required,
            .default_value = default_value,
        };
        initialized += 1;
    }
    return .{
        .items = items,
        .shape_digest = digestDeclarations(items),
    };
}

fn encodeScalar(value: scalar.Value, encoder: *cache.Encoder) !void {
    switch (value) {
        .string,
        .digest,
        .timestamp,
        .safe_identifier,
        .relative_path,
        => |text| try encoder.writeBytes(text),
        .integer => |number| try encoder.writeI64(number),
        .boolean => |flag| try encoder.writeBool(flag),
    }
}

fn decodeScalar(
    allocator: std.mem.Allocator,
    decoder: *cache.Decoder,
    kind: scalar.Kind,
) !scalar.Value {
    return switch (kind) {
        .integer => .{ .integer = try decoder.readI64() },
        .boolean => .{ .boolean = try decoder.readBool() },
        else => blk: {
            const text = try decoder.readBytesAlloc(
                allocator,
                4 * 1024 * 1024,
            );
            defer allocator.free(text);
            break :blk try scalar.parseAlloc(allocator, kind, text);
        },
    };
}

fn cloneValue(allocator: std.mem.Allocator, value: scalar.Value) !scalar.Value {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .boolean = flag },
        .digest => |text| .{ .digest = try allocator.dupe(u8, text) },
        .timestamp => |text| .{ .timestamp = try allocator.dupe(u8, text) },
        .safe_identifier => |text| .{ .safe_identifier = try allocator.dupe(u8, text) },
        .relative_path => |text| .{ .relative_path = try allocator.dupe(u8, text) },
    };
}

fn digestDeclarations(items: []const Declaration) [71]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("definition-parameter-shape/v1\x00");
    for (items) |item| {
        updateLengthPrefixed(&hasher, item.name);
        updateLengthPrefixed(&hasher, @tagName(item.kind));
        hasher.update(if (item.required) "\x01" else "\x00");
        hasher.update(if (item.default_value != null) "\x01" else "\x00");
    }
    return finishDigest(&hasher);
}

fn digestBindings(items: []const Binding) ![71]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("definition-parameter-values/v1\x00");
    for (items) |item| {
        updateLengthPrefixed(&hasher, item.name);
        updateLengthPrefixed(&hasher, @tagName(item.value.kind()));
        var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer out.deinit();
        try item.value.writeCanonical(&out.writer);
        updateLengthPrefixed(&hasher, out.written());
    }
    return finishDigest(&hasher);
}

fn updateLengthPrefixed(hasher: anytype, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
    hasher.update(&length);
    hasher.update(bytes);
}

fn finishDigest(hasher: *std.crypto.hash.sha2.Sha256) [71]u8 {
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    var digest: [71]u8 = undefined;
    @memcpy(digest[0..7], "sha256:");
    @memcpy(digest[7..], &hex);
    return digest;
}

fn lessThanDeclaration(_: void, left: Declaration, right: Declaration) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn lessThanBinding(_: void, left: Binding, right: Binding) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

test "parameter declarations and values compile to stable typed digests" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{
        \\  "limit": {"type": "integer", "required": false, "default": 10},
        \\  "name": {"type": "safe_identifier", "required": true}
        \\}
    ,
        .{},
    );
    defer parsed.deinit();
    var declarations = try compile(std.testing.allocator, parsed.value);
    defer declarations.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), declarations.items.len);
    try std.testing.expect(canonical_json.isFingerprint(&declarations.shape_digest));

    var bindings = try bind(std.testing.allocator, &declarations, &.{
        .{ .name = "name", .raw_value = "example" },
    });
    defer bindings.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), bindings.items.len);
    try std.testing.expect(canonical_json.isFingerprint(&bindings.values_digest));
    try std.testing.expectError(
        error.UnknownParameter,
        bind(std.testing.allocator, &declarations, &.{
            .{ .name = "unknown", .raw_value = "x" },
        }),
    );
}

test "partial parameter binding validates inputs without requiring store keys" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{
        \\  "store": {"type": "safe_identifier", "required": true},
        \\  "limit": {"type": "integer", "required": false, "default": 10}
        \\}
    ,
        .{},
    );
    defer parsed.deinit();
    var declarations = try compile(std.testing.allocator, parsed.value);
    defer declarations.deinit(std.testing.allocator);
    var bindings = try bindProvided(
        std.testing.allocator,
        &declarations,
        &.{},
    );
    defer bindings.deinit(std.testing.allocator);
    try std.testing.expect(bindings.find("store") == null);
    try std.testing.expectEqual(
        @as(i64, 10),
        bindings.find("limit").?.value.integer,
    );
}

test "parameter declarations round trip through bounded cache plans" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{
        \\  "limit": {"type": "integer", "required": false, "default": 10},
        \\  "name": {"type": "safe_identifier", "required": true}
        \\}
    ,
        .{},
    );
    defer parsed.deinit();
    var declarations = try compile(std.testing.allocator, parsed.value);
    defer declarations.deinit(std.testing.allocator);
    var encoder = cache.Encoder.init(std.testing.allocator, 4096);
    defer encoder.deinit();
    try encodeCache(&declarations, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    var decoder = cache.Decoder.init(payload);
    var decoded = try decodeCache(std.testing.allocator, &decoder);
    defer decoded.deinit(std.testing.allocator);
    try decoder.finish();
    try std.testing.expectEqual(declarations.items.len, decoded.items.len);
    try std.testing.expectEqualSlices(
        u8,
        &declarations.shape_digest,
        &decoded.shape_digest,
    );
    try std.testing.expectEqualStrings(
        declarations.items[1].name,
        decoded.items[1].name,
    );
}
