const std = @import("std");
const json = @import("json.zig");

pub const Reference = struct {
    id: []u8,
    path: []u8,

    fn deinit(self: *Reference, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Manifest = struct {
    skill: []u8,
    seq: []Reference,
    ledger: []Reference,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.skill);
        for (self.seq) |*reference| reference.deinit(allocator);
        allocator.free(self.seq);
        for (self.ledger) |*reference| reference.deinit(allocator);
        allocator.free(self.ledger);
        self.* = undefined;
    }
};

pub fn parseAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !Manifest {
    const root = try json.object(value);
    try json.requireExactKeys(root, &.{ "schema", "skill", "seq", "ledger" });
    try json.requireFields(root, &.{ "schema", "skill" });
    if (!std.mem.eql(
        u8,
        try json.requiredString(root, "schema"),
        "skill-definition-set/v1",
    )) return error.InvalidManifestSchema;
    const skill = try json.requiredString(root, "skill");
    try json.safeIdentifier(skill, 128);

    const seq = try parseReferences(allocator, root.get("seq"), "seq");
    errdefer deinitReferences(allocator, seq);
    const ledger = try parseReferences(allocator, root.get("ledger"), "ledger");
    errdefer deinitReferences(allocator, ledger);
    try rejectDuplicateIds(seq, ledger);

    return .{
        .skill = try allocator.dupe(u8, skill),
        .seq = seq,
        .ledger = ledger,
    };
}

fn parseReferences(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    required_prefix: []const u8,
) ![]Reference {
    const items = if (value) |present|
        try json.array(present)
    else
        return allocator.alloc(Reference, 0);
    var out: std.ArrayList(Reference) = .empty;
    errdefer {
        for (out.items) |*reference| reference.deinit(allocator);
        out.deinit(allocator);
    }
    for (items.items) |item| {
        const object = try json.object(item);
        try json.requireExactKeys(object, &.{ "id", "path" });
        try json.requireFields(object, &.{ "id", "path" });
        const id = try json.requiredString(object, "id");
        try json.safeIdentifier(id, 256);
        const path = try json.requiredString(object, "path");
        try json.repositoryRelativePath(path, false);
        if (!std.mem.startsWith(u8, path, required_prefix) or
            path.len <= required_prefix.len or path[required_prefix.len] != '/' or
            !std.mem.endsWith(u8, path, ".json"))
        {
            return error.InvalidManifestReferencePath;
        }
        for (out.items) |prior| {
            if (std.mem.eql(u8, prior.id, id) or std.mem.eql(u8, prior.path, path)) {
                return error.DuplicateManifestReference;
            }
        }
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .path = try allocator.dupe(u8, path),
        });
    }
    std.sort.heap(Reference, out.items, {}, lessThanReference);
    return out.toOwnedSlice(allocator);
}

fn rejectDuplicateIds(left: []const Reference, right: []const Reference) !void {
    for (left) |a| for (right) |b| {
        if (std.mem.eql(u8, a.id, b.id)) return error.DuplicateManifestReference;
    };
}

fn deinitReferences(allocator: std.mem.Allocator, references: []Reference) void {
    for (references) |*reference| reference.deinit(allocator);
    allocator.free(references);
}

fn lessThanReference(_: void, left: Reference, right: Reference) bool {
    return std.mem.lessThan(u8, left.id, right.id);
}

test "manifest contains only explicit passive definition references" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{
        \\  "schema": "skill-definition-set/v1",
        \\  "skill": "example",
        \\  "seq": [
        \\    {"id": "example/observation", "path": "seq/observation.json"}
        \\  ],
        \\  "ledger": [
        \\    {"id": "example/artifact", "path": "ledger/artifact.json"}
        \\  ]
        \\}
    ,
        .{},
    );
    defer parsed.deinit();
    var manifest = try parseAlloc(std.testing.allocator, parsed.value);
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("example", manifest.skill);
    try std.testing.expectEqual(@as(usize, 1), manifest.seq.len);

    var executable = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"schema":"skill-definition-set/v1","skill":"example","seq":[],"ledger":[],"hook":"run"}
    ,
        .{},
    );
    defer executable.deinit();
    try std.testing.expectError(
        error.UnknownField,
        parseAlloc(std.testing.allocator, executable.value),
    );
}

fn fuzzManifestTarget(_: void, smith: *std.testing.Smith) !void {
    var storage: [4096]u8 = undefined;
    for (&storage) |*byte| byte.* = smith.value(u8);
    const bytes = storage[0 .. smith.value(usize) % (storage.len + 1)];

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        bytes,
        .{},
    ) catch return;
    defer parsed.deinit();

    var value = parseAlloc(std.testing.allocator, parsed.value) catch return;
    defer value.deinit(std.testing.allocator);
}

test "fuzz passive manifest parsing" {
    try std.testing.fuzz({}, fuzzManifestTarget, .{});
}
