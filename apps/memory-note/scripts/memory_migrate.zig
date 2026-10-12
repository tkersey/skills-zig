const std = @import("std");
const durable_store = @import("durable_store");
const layout = @import("memory_layout.zig");
const memory_storage = @import("memory_storage.zig");
const memory_envelope = @import("memory_envelope.zig");

const note_bytes_max = 1024 * 1024;
const note_count_max = 10_000;

pub const Result = struct {
    source_notes: u32 = 0,
    copied: u32 = 0,
    duplicate_skip: u32 = 0,
    planned: u32 = 0,
    storage_mutated: bool = false,
};

const Entry = struct {
    name: []const u8,
    id: []const u8,
    digest: [32]u8,
};

const Inventory = struct {
    entries: std.ArrayList(Entry) = .empty,
    ids: std.StringHashMapUnmanaged(usize) = .empty,
    names: std.StringHashMapUnmanaged(usize) = .empty,

    fn deinit(self: *Inventory, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.id);
        }
        self.entries.deinit(allocator);
        self.ids.deinit(allocator);
        self.names.deinit(allocator);
    }
};

/// The caller holds the one extension lock across both roots for real copies.
/// Preflight catches conflicts before writing. Interrupted copies can be retried:
/// complete envelopes become visible atomically and existing IDs are preserved.
pub fn copy(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    destination: []const u8,
    extension: []const u8,
    dry_run: bool,
) !Result {
    var prior = try inventory(allocator, io, source, extension);
    defer prior.deinit(allocator);
    var current = try inventory(allocator, io, destination, extension);
    defer current.deinit(allocator);
    var result = try preflight(prior, current);
    if (dry_run) return result;
    for (prior.entries.items) |entry| {
        if (current.ids.contains(entry.id)) continue;
        const source_path = try std.fs.path.join(allocator, &.{ source, entry.name });
        defer allocator.free(source_path);
        const target_path = try std.fs.path.join(allocator, &.{ destination, entry.name });
        defer allocator.free(target_path);
        const raw = try durable_store.readRegularFileNoSymlink(
            allocator,
            source_path,
            note_bytes_max,
        );
        defer allocator.free(raw);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
        if (!std.mem.eql(u8, &digest, &entry.digest)) return error.MigrationSourceChanged;
        try memory_storage.publishNote(allocator, target_path, raw);
        result.copied += 1;
    }
    result.storage_mutated = result.copied > 0;
    return result;
}

fn preflight(source: Inventory, destination: Inventory) !Result {
    var result: Result = .{ .source_notes = @intCast(source.entries.items.len) };
    for (source.entries.items) |entry| {
        if (destination.names.get(entry.name)) |index| {
            if (!std.mem.eql(u8, &entry.digest, &destination.entries.items[index].digest))
                return error.MigrationFilenameConflict;
        }
        if (destination.ids.get(entry.id)) |index| {
            if (!std.mem.eql(u8, &entry.digest, &destination.entries.items[index].digest))
                return error.MigrationIdentityConflict;
            result.duplicate_skip += 1;
        } else result.planned += 1;
    }
    if (destination.entries.items.len + result.planned > note_count_max)
        return error.TooManyFiles;
    return result;
}

fn inventory(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    extension: []const u8,
) !Inventory {
    try layout.validateDirectory(io, directory);
    const names = durable_store.listSortedRegularFilesNoSymlink(
        allocator,
        directory,
        note_count_max,
        note_bytes_max,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer durable_store.freeStringList(allocator, names);
    var result: Inventory = .{};
    errdefer result.deinit(allocator);
    for (names) |name| {
        const path = try std.fs.path.join(allocator, &.{ directory, name });
        defer allocator.free(path);
        const raw = try durable_store.readRegularFileNoSymlink(allocator, path, note_bytes_max);
        defer allocator.free(raw);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const id = try memory_envelope.storedIdentity(parsed.value, extension);
        try insertEntry(allocator, &result, name, id, raw);
    }
    return result;
}

fn insertEntry(
    allocator: std.mem.Allocator,
    result: *Inventory,
    name: []const u8,
    id: []const u8,
    raw: []const u8,
) !void {
    if (result.ids.contains(id)) return error.DuplicateId;
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    try result.entries.ensureUnusedCapacity(allocator, 1);
    try result.ids.ensureUnusedCapacity(allocator, 1);
    try result.names.ensureUnusedCapacity(allocator, 1);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    result.ids.putAssumeCapacity(owned_id, result.entries.items.len);
    result.names.putAssumeCapacity(owned_name, result.entries.items.len);
    result.entries.appendAssumeCapacity(.{ .name = owned_name, .id = owned_id, .digest = digest });
}

const fixture =
    \\{"schema":"memory-source-note/v1","id":"MSN-20261011T120000Z-0123456789abcdef","extension":"learnings","captured_at":"2026-10-11T12:00:00Z","kind":"learning-admission","operation":"assert","authority":"source-admission","summary":"fixture","scope":{"kind":"global","repo":null,"paths":[]},"source_refs":[{"kind":"test","ref":"fixture","summary":"fixture"}],"fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","related_ids":[],"supersedes_id":null,"payload":{"evidence":"retained"}}
;

test "migration rejects incomplete stored envelopes before publishing any note" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "old");
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const source = try std.fs.path.join(allocator, &.{ home, "old" });
    defer allocator.free(source);
    const destination = try std.fs.path.join(allocator, &.{ home, "new" });
    defer allocator.free(destination);
    const required = [_][]const u8{
        "authority", "scope", "source_refs", "related_ids", "supersedes_id", "payload",
    };
    for (required) |field| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixture, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.swapRemove(field));
        const incomplete = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
        defer allocator.free(incomplete);
        try tmp.dir.writeFile(io, .{ .sub_path = "old/incomplete.md", .data = incomplete });
        for ([_]bool{ true, false }) |dry_run| {
            try std.testing.expectError(error.InvalidStoredNote, copy(
                allocator,
                io,
                source,
                destination,
                "learnings",
                dry_run,
            ));
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "new", .{}));
        }
    }
}

test "migration preserves exact bytes and filenames and retry skips the same identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "old");
    try tmp.dir.writeFile(io, .{ .sub_path = "old/original.md", .data = fixture });
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const source = try std.fs.path.join(allocator, &.{ home, "old" });
    defer allocator.free(source);
    const destination = try std.fs.path.join(allocator, &.{ home, "new" });
    defer allocator.free(destination);
    const preview = try copy(allocator, io, source, destination, "learnings", true);
    try std.testing.expectEqual(@as(u32, 1), preview.planned);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "new", .{}));
    const first = try copy(allocator, io, source, destination, "learnings", false);
    try std.testing.expectEqual(@as(u32, 1), first.copied);
    const target = try std.fs.path.join(allocator, &.{ destination, "original.md" });
    defer allocator.free(target);
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, target, note_bytes_max);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(fixture, bytes);
    _ = try tmp.dir.statFile(io, "old/original.md", .{});
    const retry = try copy(allocator, io, source, destination, "learnings", false);
    try std.testing.expectEqual(@as(u32, 0), retry.copied);
    try std.testing.expectEqual(@as(u32, 1), retry.duplicate_skip);
}

test "migration rejects malformed generated metadata before publishing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "old");
    try tmp.dir.writeFile(io, .{ .sub_path = "old/valid.md", .data = fixture });
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const source = try std.fs.path.join(allocator, &.{ home, "old" });
    defer allocator.free(source);
    const destination = try std.fs.path.join(allocator, &.{ home, "new" });
    defer allocator.free(destination);
    const invalid = [_][2][]const u8{
        .{ "id", "MSN-x" },
        .{ "id", "MSN-20260230T120000Z-0123456789abcdef" },
        .{ "id", "MSN-20261011T120000Z-0123456789abcdeF" },
        .{ "captured_at", "not-a-date" },
        .{ "captured_at", "2026-02-29T12:00:00Z" },
        .{ "captured_at", "2026-10-11T24:00:00Z" },
        .{ "fingerprint", "not-a-fingerprint" },
        .{ "fingerprint", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeF" },
    };
    for (invalid) |pair| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixture, .{});
        defer parsed.deinit();
        parsed.value.object.getPtr(pair[0]).?.* = .{ .string = pair[1] };
        const malformed = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
        defer allocator.free(malformed);
        try tmp.dir.writeFile(io, .{ .sub_path = "old/invalid.md", .data = malformed });
        for ([_]bool{ true, false }) |dry_run| {
            try std.testing.expectError(error.InvalidStoredNote, copy(
                allocator,
                io,
                source,
                destination,
                "learnings",
                dry_run,
            ));
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "new", .{}));
        }
    }
}

test "distinct stored identities remain distinct even with equal transport fingerprints" {
    const allocator = std.testing.allocator;
    var source: Inventory = .{};
    defer source.deinit(allocator);
    var destination: Inventory = .{};
    defer destination.deinit(allocator);
    try insertEntry(allocator, &source, "two.md", "MSN-two", "same fingerprint; second id");
    try insertEntry(allocator, &destination, "one.md", "MSN-one", "same fingerprint; first id");
    const result = try preflight(source, destination);
    try std.testing.expectEqual(@as(u32, 1), result.planned);
    try std.testing.expectEqual(@as(u32, 0), result.duplicate_skip);
}

test "migration rejects changed bytes under a stored id and filename collisions" {
    const allocator = std.testing.allocator;
    var source: Inventory = .{};
    defer source.deinit(allocator);
    var destination: Inventory = .{};
    defer destination.deinit(allocator);
    try insertEntry(allocator, &source, "one.md", "MSN-one", "original");
    try insertEntry(allocator, &destination, "other.md", "MSN-one", "changed");
    try std.testing.expectError(error.MigrationIdentityConflict, preflight(source, destination));
    try insertEntry(allocator, &destination, "one.md", "MSN-other", "other record");
    try std.testing.expectError(error.MigrationFilenameConflict, preflight(source, destination));
    try std.testing.expectError(
        error.DuplicateId,
        insertEntry(allocator, &source, "duplicate.md", "MSN-one", "original"),
    );
}

test "migration union stays readable and duplicates at the limit remain valid" {
    const allocator = std.testing.allocator;
    var source: Inventory = .{};
    defer source.deinit(allocator);
    var destination: Inventory = .{};
    defer destination.deinit(allocator);
    for (0..note_count_max) |index| {
        const id = try allocator.print("MSN-{d:0>5}", .{index});
        defer allocator.free(id);
        try insertEntry(allocator, &destination, id, id, id);
    }
    const existing = destination.entries.items[0];
    try insertEntry(allocator, &source, existing.name, existing.id, existing.id);
    const duplicate = try preflight(source, destination);
    try std.testing.expectEqual(@as(u32, 0), duplicate.planned);
    try std.testing.expectEqual(@as(u32, 1), duplicate.duplicate_skip);
    try insertEntry(allocator, &source, "new.md", "MSN-new", "new envelope");
    try std.testing.expectError(error.TooManyFiles, preflight(source, destination));
}
