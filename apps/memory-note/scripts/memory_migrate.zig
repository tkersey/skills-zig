const std = @import("std");
const durable_store = @import("durable_store");
const layout = @import("memory_layout.zig");
const memory_storage = @import("memory_storage.zig");

const note_bytes_max = 1024 * 1024;
const note_count_max = 10_000;
const identity_bytes_max = 128;

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
        const id = try storedIdentity(parsed.value, extension);
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

fn storedIdentity(value: std.json.Value, extension: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidStoredNote;
    const schema = try string(value, "schema");
    if (!std.mem.eql(u8, schema, "memory-source-note/v1")) return error.InvalidStoredNote;
    const owner = try string(value, "extension");
    if (!std.mem.eql(u8, owner, extension)) return error.InvalidStoredNote;
    const id = try string(value, "id");
    if (!std.mem.startsWith(u8, id, "MSN-") or id.len <= 4 or id.len > identity_bytes_max)
        return error.InvalidStoredNote;
    // Migration transports stored evidence; it does not recapture or reinterpret it.
    for ([_][]const u8{ "captured_at", "kind", "operation", "summary", "fingerprint" }) |key|
        _ = try string(value, key);
    return id;
}

fn string(parent: std.json.Value, key: []const u8) ![]const u8 {
    const value = parent.object.get(key) orelse return error.InvalidStoredNote;
    if (value != .string) return error.InvalidStoredNote;
    return value.string;
}

const fixture =
    \\{"schema":"memory-source-note/v1","id":"MSN-one","extension":"learnings","captured_at":"2026-10-11T12:00:00Z","kind":"learning-admission","operation":"assert","summary":"fixture","fingerprint":"same-transport-fingerprint","related_ids":[],"supersedes_id":null,"payload":{}}
;

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
