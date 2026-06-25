const std = @import("std");
const atom = @import("atom.zig");

pub const Condition = struct {
    all: []const []const u8 = &.{},
    any: []const []const u8 = &.{},
    none: []const []const u8 = &.{},
};

pub const OwnedCondition = struct {
    all: [][]u8 = &.{},
    any: [][]u8 = &.{},
    none: [][]u8 = &.{},

    pub fn asCondition(self: OwnedCondition) Condition {
        return .{
            .all = self.all,
            .any = self.any,
            .none = self.none,
        };
    }

    pub fn deinit(self: *OwnedCondition, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.all);
        freeStringList(allocator, self.any);
        freeStringList(allocator, self.none);
        self.* = undefined;
    }
};

pub fn parseOwned(allocator: std.mem.Allocator, value: std.json.Value) !OwnedCondition {
    if (value != .object) return error.SchemaInvalid;
    const object = value.object;
    var result: OwnedCondition = .{};
    errdefer result.deinit(allocator);

    result.all = try parseAtomArray(allocator, object.get("all") orelse null);
    result.any = try parseAtomArray(allocator, object.get("any") orelse null);
    result.none = try parseAtomArray(allocator, object.get("none") orelse null);
    return result;
}

pub fn parseOptionalOwned(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) !OwnedCondition {
    return parseOwned(allocator, maybe_value orelse std.json.Value{ .object = .{} });
}

pub fn validateDeclaredAtoms(condition: Condition, declarations: atom.DeclarationSet) !void {
    for (condition.all) |item| _ = try atom.validateDeclared(item, declarations);
    for (condition.any) |item| _ = try atom.validateDeclared(item, declarations);
    for (condition.none) |item| _ = try atom.validateDeclared(item, declarations);
}

pub fn evaluate(condition: Condition, satisfied: []const []const u8) bool {
    for (condition.all) |required_atom| {
        if (!contains(satisfied, required_atom)) return false;
    }
    if (condition.any.len > 0) {
        var matched_any = false;
        for (condition.any) |candidate_atom| {
            if (contains(satisfied, candidate_atom)) {
                matched_any = true;
                break;
            }
        }
        if (!matched_any) return false;
    }
    for (condition.none) |forbidden_atom| {
        if (contains(satisfied, forbidden_atom)) return false;
    }
    return true;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn parseAtomArray(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) ![][]u8 {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.SchemaInvalid;

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .string) return error.SchemaInvalid;
        _ = try atom.parse(item.string);
        try out.append(allocator, try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    if (items.len > 0) allocator.free(items);
}

test "empty condition is true" {
    try std.testing.expect(evaluate(.{}, &.{}));
}

test "condition all any none semantics" {
    const c: Condition = .{
        .all = &.{"fact:a"},
        .any = &.{ "fact:b", "fact:c" },
        .none = &.{"fact:d"},
    };
    try std.testing.expect(evaluate(c, &.{ "fact:a", "fact:c" }));
    try std.testing.expect(!evaluate(c, &.{"fact:c"}));
    try std.testing.expect(!evaluate(c, &.{ "fact:a", "fact:b", "fact:d" }));
}

test "parse owned condition duplicates atom strings" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"all\":[\"fact:a\"],\"none\":[\"action:x=failure\"]}", .{});
    defer parsed.deinit();

    var owned = try parseOwned(std.testing.allocator, parsed.value);
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("fact:a", owned.all[0]);
    try std.testing.expectEqualStrings("action:x=failure", owned.none[0]);
    try std.testing.expect(evaluate(owned.asCondition(), &.{"fact:a"}));
}

test "condition declared atom validation" {
    const c: Condition = .{
        .all = &.{"fact:a"},
        .none = &.{"custom:safety"},
    };
    try validateDeclaredAtoms(c, .{
        .declared_atoms = &.{ "fact:a", "custom:safety" },
        .custom_authority_atoms = &.{"custom:safety"},
    });
    try std.testing.expectError(error.CustomAtomUndeclared, validateDeclaredAtoms(c, .{
        .declared_atoms = &.{ "fact:a", "custom:safety" },
    }));
}
