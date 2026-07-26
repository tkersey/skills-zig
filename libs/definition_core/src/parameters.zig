const std = @import("std");
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
        try items.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .kind = kind,
            .required = required,
            .default_value = default_value,
        });
        default_value = null;
    }
    std.mem.sort(Declaration, items.items, {}, lessThanDeclaration);
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
        try items.append(allocator, .{
            .name = try allocator.dupe(u8, input.name),
            .value = try scalar.parseAlloc(allocator, declaration.kind, input.raw_value),
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
            try items.append(allocator, .{
                .name = try allocator.dupe(u8, declaration.name),
                .value = try cloneValue(allocator, default_value),
            });
        } else if (declaration.required) {
            return error.MissingParameter;
        }
    }
    std.mem.sort(Binding, items.items, {}, lessThanBinding);
    const values_digest = digestBindings(items.items);
    return .{
        .items = try items.toOwnedSlice(allocator),
        .values_digest = values_digest,
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

fn digestBindings(items: []const Binding) [71]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("definition-parameter-values/v1\x00");
    for (items) |item| {
        updateLengthPrefixed(&hasher, item.name);
        updateLengthPrefixed(&hasher, @tagName(item.value.kind()));
        var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer out.deinit();
        item.value.writeCanonical(&out.writer) catch unreachable;
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
        \\{"limit":{"type":"integer","required":false,"default":10},"name":{"type":"safe_identifier","required":true}}
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
