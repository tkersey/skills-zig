const std = @import("std");

pub const AtomKind = enum {
    fact,
    observation,
    action,
    unknown,
    obligation,
    terminal,
    custom,
};

pub const ParsedAtom = struct {
    kind: AtomKind,
    text: []const u8,
    id: []const u8,
    outcome: ?[]const u8 = null,
};

pub const DeclarationSet = struct {
    declared_atoms: []const []const u8 = &.{},
    custom_authority_atoms: []const []const u8 = &.{},
};

pub fn parse(atom: []const u8) !ParsedAtom {
    if (atom.len == 0 or atom.len > 256) return error.InvalidAtom;
    for (atom) |byte| {
        if (byte > 0x7f or std.ascii.isWhitespace(byte)) return error.InvalidAtom;
    }

    if (std.mem.startsWith(u8, atom, "fact:")) {
        const id = atom["fact:".len..];
        try validateStableId(id);
        return .{ .kind = .fact, .text = atom, .id = id };
    }
    if (std.mem.startsWith(u8, atom, "obs:")) {
        const rest = atom["obs:".len..];
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.InvalidAtom;
        const id = rest[0..eq];
        const outcome = rest[eq + 1 ..];
        try validateStableId(id);
        try validateStableId(outcome);
        return .{ .kind = .observation, .text = atom, .id = id, .outcome = outcome };
    }
    if (std.mem.startsWith(u8, atom, "action:")) {
        const rest = atom["action:".len..];
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.InvalidAtom;
        const id = rest[0..eq];
        const outcome = rest[eq + 1 ..];
        try validateStableId(id);
        if (!std.mem.eql(u8, outcome, "success") and !std.mem.eql(u8, outcome, "failure")) return error.InvalidAtom;
        return .{ .kind = .action, .text = atom, .id = id, .outcome = outcome };
    }
    if (std.mem.startsWith(u8, atom, "unknown:")) {
        const rest = atom["unknown:".len..];
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.InvalidAtom;
        const id = rest[0..eq];
        const outcome = rest[eq + 1 ..];
        try validateStableId(id);
        if (!std.mem.eql(u8, outcome, "resolved") and !std.mem.eql(u8, outcome, "blocked")) return error.InvalidAtom;
        return .{ .kind = .unknown, .text = atom, .id = id, .outcome = outcome };
    }
    if (std.mem.startsWith(u8, atom, "obligation:")) {
        const rest = atom["obligation:".len..];
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.InvalidAtom;
        const id = rest[0..eq];
        const outcome = rest[eq + 1 ..];
        try validateStableId(id);
        if (!std.mem.eql(u8, outcome, "closed")) return error.InvalidAtom;
        return .{ .kind = .obligation, .text = atom, .id = id, .outcome = outcome };
    }
    if (std.mem.startsWith(u8, atom, "terminal:")) {
        const id = atom["terminal:".len..];
        try validateStableId(id);
        return .{ .kind = .terminal, .text = atom, .id = id };
    }
    if (std.mem.startsWith(u8, atom, "custom:")) {
        const id = atom["custom:".len..];
        try validateStableId(id);
        return .{ .kind = .custom, .text = atom, .id = id };
    }
    return error.InvalidAtom;
}

pub fn validateDeclared(atom_text: []const u8, declarations: DeclarationSet) !ParsedAtom {
    const parsed = try parse(atom_text);
    if (!contains(declarations.declared_atoms, atom_text)) return error.UnknownAtom;
    if (parsed.kind == .custom and !contains(declarations.custom_authority_atoms, atom_text)) return error.CustomAtomUndeclared;
    return parsed;
}

pub fn validateStableId(id: []const u8) !void {
    if (id.len == 0) return error.InvalidAtom;
    for (id) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
            else => return error.InvalidAtom,
        }
    }
}

fn contains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

test "parse atom prefix" {
    const parsed = try parse("fact:source-current");
    try std.testing.expectEqual(AtomKind.fact, parsed.kind);
    try std.testing.expectEqualStrings("source-current", parsed.id);
}

test "parse atom grammar outcomes" {
    try std.testing.expectEqual(AtomKind.observation, (try parse("obs:probe=pass")).kind);
    try std.testing.expectEqualStrings("success", (try parse("action:patch=success")).outcome.?);
    try std.testing.expectError(error.InvalidAtom, parse("action:patch=maybe"));
    try std.testing.expectError(error.InvalidAtom, parse("unknown:risk=maybe"));
    try std.testing.expectError(error.InvalidAtom, parse("obligation:proof=open"));
    try std.testing.expectError(error.InvalidAtom, parse("fact:has space"));
    try std.testing.expectError(error.InvalidAtom, parse("custom:"));
}

test "declared atom and custom authority checks" {
    const declarations: DeclarationSet = .{
        .declared_atoms = &.{ "fact:ready", "custom:safety-boundary" },
        .custom_authority_atoms = &.{"custom:safety-boundary"},
    };
    _ = try validateDeclared("fact:ready", declarations);
    _ = try validateDeclared("custom:safety-boundary", declarations);

    try std.testing.expectError(error.UnknownAtom, validateDeclared("fact:missing", declarations));
    try std.testing.expectError(error.CustomAtomUndeclared, validateDeclared("custom:safety-boundary", .{
        .declared_atoms = &.{"custom:safety-boundary"},
    }));
}
