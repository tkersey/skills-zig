const std = @import("std");
const canonical_json = @import("definition_core").canonical_json;
const catalog = @import("host_catalog.zig");

pub const Limits = struct {
    max_files: usize = 100000,
    max_bytes: u64 = 2 * 1024 * 1024 * 1024,
};

pub const Entry = struct {
    kind: []const u8,
    size: ?u64 = null,
    sha256: ?[]const u8 = null,
    target: ?[]const u8 = null,
    mode: ?u32 = null,
};

pub const Source = struct {
    workspace: []const u8,
    entries: std.json.ArrayHashMap(Entry) = .{},
};

pub const Sources = std.json.ArrayHashMap(Source);

pub const Inventory = struct {
    arena: std.heap.ArenaAllocator,
    sources: Sources,
    file_count: usize,
    total_bytes: u64,

    pub fn deinit(self: *Inventory) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn json(self: *const Inventory, allocator: std.mem.Allocator) ![]u8 {
        return canonicalAlloc(allocator, self.sources);
    }
};

pub const Witness = struct {
    bytes: u64,
    sha256: [64]u8,
};

const archives = [_][]const u8{ ".bindings", ".definitions", ".revisions" };

pub fn canonicalAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const serialized = try std.json.Stringify.valueAlloc(
        allocator,
        value,
        .{ .emit_null_optional_fields = false },
    );
    defer allocator.free(serialized);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, serialized, .{});
    defer parsed.deinit();
    return canonical_json.canonicalJsonAlloc(allocator, parsed.value);
}

pub fn inventory(
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
    slots: []const []const u8,
    retired: []const []const u8,
    limits: Limits,
) !Inventory {
    if (roots.len == 0 or
        roots.len > 128 or
        limits.max_files == 0 or
        limits.max_files > 100000 or
        limits.max_bytes > 2 * 1024 * 1024 * 1024)
        return error.MigrationInventoryBoundExceeded;
    for (slots) |slot| try relative(slot);
    for (retired) |name| try relative(name);
    var result: Inventory = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .sources = .{},
        .file_count = 0,
        .total_bytes = 0,
    };
    errdefer result.deinit();
    const owned = result.arena.allocator();
    for (roots, 0..) |root, index| {
        const root_dir = try catalog.openDirectory(io, root, false);
        root_dir.close(io);
        var source: Source = .{ .workspace = try owned.dupe(u8, root) };
        var pending: std.ArrayList([]const u8) = .empty;
        try pending.append(owned, ".ledger");
        try pending.appendSlice(owned, retired);
        while (pending.pop()) |name| {
            if (source.entries.map.contains(name)) continue;
            const parent = openParent(owned, io, root, name, false) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer parent.close(io);
            const base = std.fs.path.basename(name);
            const info = parent.statFile(
                io,
                base,
                .{ .follow_symlinks = false },
            ) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (result.file_count == limits.max_files) return error.MigrationInventoryBoundExceeded;
            result.file_count += 1;
            const entry = try inventoryEntry(
                &result,
                io,
                parent,
                name,
                info,
                &pending,
                slots,
                retired,
                limits,
            );
            try source.entries.map.put(owned, try owned.dupe(u8, name), entry);
        }
        try result.sources.map.put(owned, try std.fmt.allocPrint(owned, "{d}", .{index}), source);
    }
    return result;
}

fn inventoryEntry(
    result: *Inventory,
    io: std.Io,
    parent: std.Io.Dir,
    name: []const u8,
    info: std.Io.File.Stat,
    pending: *std.ArrayList([]const u8),
    slots: []const []const u8,
    retired: []const []const u8,
    limits: Limits,
) !Entry {
    const owned = result.arena.allocator();
    const base = std.fs.path.basename(name);
    return switch (info.kind) {
        .directory => blk: {
            const dir = try parent.openDir(
                io,
                base,
                .{ .iterate = true, .follow_symlinks = false },
            );
            defer dir.close(io);
            var iterator = dir.iterate();
            while (try iterator.next(io)) |child| {
                if (pending.items.len >= limits.max_files)
                    return error.MigrationInventoryBoundExceeded;
                try pending.append(
                    owned,
                    try std.fs.path.join(owned, &.{ name, child.name }),
                );
            }
            break :blk .{ .kind = "directory" };
        },
        .file => blk: {
            if (info.size > limits.max_bytes - result.total_bytes)
                return error.MigrationInventoryBoundExceeded;
            const witness = try hashFile(io, parent, base, info.size);
            if (witness.bytes != info.size) return error.SourceChanged;
            result.total_bytes += info.size;
            break :blk .{
                .kind = "file",
                .size = info.size,
                .sha256 = try owned.dupe(u8, &witness.sha256),
            };
        },
        .sym_link => blk: {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = try parent.readLink(io, base, &buffer);
            break :blk .{
                .kind = "symlink",
                .target = try owned.dupe(u8, buffer[0..length]),
            };
        },
        .named_pipe => blk: {
            if (protected(name, slots, retired)) return error.UnsupportedSpecialSourceEntry;
            break :blk .{
                .kind = "fifo",
                .mode = @intCast(info.permissions.toMode() & 0o7777),
            };
        },
        else => return error.UnsupportedSpecialSourceEntry,
    };
}

pub fn relative(path: []const u8) !void {
    if (path.len == 0 or
        std.fs.path.isAbsolute(path) or
        std.mem.indexOfScalar(u8, path, '\\') != null)
        return error.InvalidLegacyRelativePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or
            std.mem.eql(u8, part, ".") or
            std.mem.eql(u8, part, "..") or
            std.mem.indexOfScalar(u8, part, 0) != null)
            return error.InvalidLegacyRelativePath;
    }
}

fn below(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or
        (std.mem.startsWith(u8, path, prefix) and
            path.len > prefix.len and
            path[prefix.len] == '/');
}

fn archivedControl(name: []const u8) bool {
    for (archives) |control| if (below(name, control)) return true;
    return false;
}

fn protected(name: []const u8, slots: []const []const u8, retired: []const []const u8) bool {
    for (retired) |path| if (std.mem.eql(u8, name, path)) return true;
    if (std.mem.eql(u8, name, ".ledger")) return true;
    if (!std.mem.startsWith(u8, name, ".ledger/")) return false;
    const local = name[8..];
    if (archivedControl(local)) return true;
    for (slots) |slot| if (below(slot, local)) return true;
    return false;
}

fn openParent(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    path: []const u8,
    create: bool,
) !std.Io.Dir {
    try relative(path);
    const full = try std.fs.path.join(allocator, &.{ root, std.fs.path.dirname(path) orelse "" });
    defer allocator.free(full);
    return catalog.openDirectory(io, full, create);
}

fn openRegular(io: std.Io, dir: std.Io.Dir, name: []const u8) !std.Io.File {
    try relative(name);
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidLegacyRelativePath;
    const fd = try std.posix.openat(
        dir.handle,
        name,
        .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true },
        0,
    );
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.UnsupportedSelectedSlot;
    return file;
}

pub fn hashFile(io: std.Io, dir: std.Io.Dir, name: []const u8, max_bytes: u64) !Witness {
    const file = try openRegular(io, dir, name);
    defer file.close(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var size: u64 = 0;
    while (size <= max_bytes) {
        const count = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        if (count > max_bytes - size) return error.SourceChanged;
        size += count;
        hash.update(buffer[0..count]);
    }
    return .{ .bytes = size, .sha256 = std.fmt.bytesToHex(hash.finalResult(), .lower) };
}

fn verifyFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    name: []const u8,
    entry: Entry,
) !void {
    const dir = try openParent(allocator, io, root, name, false);
    defer dir.close(io);
    const witness = try hashFile(io, dir, std.fs.path.basename(name), entry.size orelse
        return error.InvalidLegacyManifest);
    if (witness.bytes != entry.size.? or
        !std.mem.eql(u8, &witness.sha256, entry.sha256 orelse
            return error.InvalidLegacyManifest))
        return error.SourceChanged;
}

fn copyFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    source_name: []const u8,
    destination: []const u8,
    destination_name: []const u8,
    entry: Entry,
) !void {
    const from = try openParent(allocator, io, source, source_name, false);
    defer from.close(io);
    const input = try openRegular(io, from, std.fs.path.basename(source_name));
    defer input.close(io);
    const to = try openParent(allocator, io, destination, destination_name, true);
    defer to.close(io);
    const output = try to.createFile(
        io,
        std.fs.path.basename(destination_name),
        .{ .exclusive = true, .permissions = .fromMode(0o600) },
    );
    defer output.close(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var size: u64 = 0;
    const expected = entry.size orelse return error.InvalidLegacyManifest;
    while (size <= expected) {
        const count = input.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        if (count > expected - size) return error.SourceChanged;
        size += count;
        hash.update(buffer[0..count]);
        try output.writeStreamingAll(io, buffer[0..count]);
    }
    const digest = std.fmt.bytesToHex(hash.finalResult(), .lower);
    if (size != expected or
        !std.mem.eql(u8, &digest, entry.sha256 orelse
            return error.InvalidLegacyManifest))
        return error.SourceChanged;
    try output.sync(io);
    try catalog.sync(io, to);
}

pub fn archive(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: *const Inventory,
    destination: []const u8,
) !void {
    if (try catalog.exists(io, destination))
        return verifyArchive(allocator, io, snapshot, destination);
    const parent_path = std.fs.path.dirname(destination) orelse return error.InvalidPath;
    const parent = try catalog.openDirectory(io, parent_path, true);
    defer parent.close(io);
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const temporary = try std.fmt.allocPrint(
        allocator,
        ".archiving-{s}",
        .{std.fmt.bytesToHex(random, .lower)},
    );
    defer allocator.free(temporary);
    try parent.createDir(io, temporary, .fromMode(0o700));
    const stage = try std.fs.path.join(allocator, &.{ parent_path, temporary });
    defer allocator.free(stage);
    for (snapshot.sources.map.keys(), snapshot.sources.map.values()) |index, source| {
        for (source.entries.map.keys(), source.entries.map.values()) |name, entry| {
            const target = try std.fmt.allocPrint(allocator, "worktree-{s}/{s}", .{ index, name });
            defer allocator.free(target);
            if (std.mem.eql(u8, entry.kind, "directory")) {
                const path = try std.fs.path.join(allocator, &.{ stage, target });
                defer allocator.free(path);
                const dir = try catalog.openDirectory(io, path, true);
                defer dir.close(io);
                try catalog.sync(io, dir);
            } else if (std.mem.eql(u8, entry.kind, "file")) {
                try copyFile(allocator, io, source.workspace, name, stage, target, entry);
            }
        }
    }
    const dir = try catalog.openDirectory(io, stage, false);
    defer dir.close(io);
    const manifest = try canonicalAlloc(
        allocator,
        .{ .schema = "ledger-legacy-archive/v1", .sources = snapshot.sources },
    );
    defer allocator.free(manifest);
    const file = try dir.createFile(
        io,
        "manifest.json",
        .{ .exclusive = true, .permissions = .fromMode(0o600) },
    );
    defer file.close(io);
    try file.writeStreamingAll(io, manifest);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
    try catalog.sync(io, dir);
    if (try catalog.exists(io, destination)) return error.ArchiveAlreadyExists;
    try parent.rename(temporary, parent, std.fs.path.basename(destination), io);
    try catalog.sync(io, parent);
    try verifyArchive(allocator, io, snapshot, destination);
}

pub fn verifyArchive(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: *const Inventory,
    root: []const u8,
) !void {
    const dir = try catalog.openDirectory(io, root, false);
    defer dir.close(io);
    const expected = try canonicalAlloc(
        allocator,
        .{ .schema = "ledger-legacy-archive/v1", .sources = snapshot.sources },
    );
    defer allocator.free(expected);
    const bytes = try catalog.readBytes(
        allocator,
        io,
        dir,
        "manifest.json",
        expected.len + 1048576,
    );
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer parsed.deinit();
    const actual = try canonical_json.canonicalJsonAlloc(allocator, parsed.value);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, expected, actual)) return error.ArchiveManifestMismatch;
    for (snapshot.sources.map.keys(), snapshot.sources.map.values()) |index, source| {
        for (source.entries.map.keys(), source.entries.map.values()) |name, entry| {
            const target = try std.fmt.allocPrint(allocator, "worktree-{s}/{s}", .{ index, name });
            defer allocator.free(target);
            if (std.mem.eql(u8, entry.kind, "file")) {
                try verifyFile(allocator, io, root, target, entry);
            } else if (std.mem.eql(u8, entry.kind, "directory")) {
                const path = try std.fs.path.join(allocator, &.{ root, target });
                defer allocator.free(path);
                const directory = try catalog.openDirectory(io, path, false);
                directory.close(io);
            } else {
                const parent = openParent(
                    allocator,
                    io,
                    root,
                    target,
                    false,
                ) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                defer parent.close(io);
                if (try catalog.existsAt(io, parent, std.fs.path.basename(target)))
                    return error.ArchiveTopologyMismatch;
            }
        }
    }
}

pub fn selectSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: *const Inventory,
    slots: []const []const u8,
) !?usize {
    var selected: ?usize = null;
    var any = false;
    for (snapshot.sources.map.values(), 0..) |candidate, index| {
        var present = false;
        for (slots) |slot| {
            const name = try std.fs.path.join(allocator, &.{ ".ledger", slot });
            defer allocator.free(name);
            try validateSelectedPath(allocator, io, candidate.workspace, name);
            if (candidate.entries.map.get(name)) |entry| {
                if (!std.mem.eql(u8, entry.kind, "file")) return error.UnsupportedSelectedSlot;
                present = true;
            }
        }
        if (!present) continue;
        any = true;
        var covering = true;
        for (snapshot.sources.map.values()) |other| {
            for (slots) |slot| {
                const name = try std.fs.path.join(allocator, &.{ ".ledger", slot });
                defer allocator.free(name);
                const left = other.entries.map.get(name) orelse continue;
                const right = candidate.entries.map.get(name) orelse {
                    covering = false;
                    continue;
                };
                if (!try completePrefix(
                    allocator,
                    io,
                    other.workspace,
                    candidate.workspace,
                    name,
                    left,
                    right,
                )) covering = false;
            }
        }
        if (covering and
            (selected == null or
                std.mem.lessThan(
                    u8,
                    candidate.workspace,
                    snapshot.sources.map.values()[selected.?].workspace,
                ))) selected = index;
    }
    if (any and selected == null) return error.DivergentSelectedHistories;
    return selected;
}

fn validateSelectedPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    name: []const u8,
) !void {
    const parent = openParent(allocator, io, root, name, false) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer parent.close(io);
    const info = parent.statFile(
        io,
        std.fs.path.basename(name),
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (info.kind != .file) return error.UnsupportedSelectedSlot;
}

pub fn completePrefix(
    allocator: std.mem.Allocator,
    io: std.Io,
    left_root: []const u8,
    right_root: []const u8,
    name: []const u8,
    left: Entry,
    right: Entry,
) !bool {
    if (!std.mem.eql(u8, left.kind, "file") or
        !std.mem.eql(u8, right.kind, "file"))
        return error.UnsupportedSelectedSlot;
    try verifyFile(allocator, io, left_root, name, left);
    try verifyFile(allocator, io, right_root, name, right);
    if (left.size.? > right.size.?) return false;
    if (left.size.? == right.size.?) return std.mem.eql(u8, left.sha256.?, right.sha256.?);
    const left_dir = try openParent(allocator, io, left_root, name, false);
    defer left_dir.close(io);
    const right_dir = try openParent(allocator, io, right_root, name, false);
    defer right_dir.close(io);
    const a = try openRegular(io, left_dir, std.fs.path.basename(name));
    defer a.close(io);
    const b = try openRegular(io, right_dir, std.fs.path.basename(name));
    defer b.close(io);
    var a_buffer: [65536]u8 = undefined;
    var b_buffer: [65536]u8 = undefined;
    var remaining = left.size.?;
    var last: ?u8 = null;
    while (remaining > 0) {
        const amount: usize = @intCast(@min(remaining, a_buffer.len));
        const count = a.readStreaming(io, &.{a_buffer[0..amount]}) catch |err| switch (err) {
            error.EndOfStream => return error.SourceChanged,
            else => return err,
        };
        if (count == 0) return error.SourceChanged;
        var offset: usize = 0;
        while (offset < count) {
            const got = b.readStreaming(io, &.{b_buffer[offset..count]}) catch |err| switch (err) {
                error.EndOfStream => return false,
                else => return err,
            };
            if (got == 0) return false;
            offset += got;
        }
        if (!std.mem.eql(u8, a_buffer[0..count], b_buffer[0..count])) return false;
        last = a_buffer[count - 1];
        remaining -= count;
    }
    return last == null or last.? == '\n';
}

pub fn copySelected(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: *const Inventory,
    index: usize,
    slots: []const []const u8,
    archive_root: []const u8,
    destination: []const u8,
) !void {
    if (index >= snapshot.sources.map.count()) return error.InvalidSourceIndex;
    const source = snapshot.sources.map.values()[index];
    for (source.entries.map.keys(), source.entries.map.values()) |name, entry| {
        if (!std.mem.startsWith(u8, name, ".ledger/")) continue;
        const local = name[8..];
        var selected = archivedControl(local);
        for (slots) |slot| selected = selected or std.mem.eql(u8, local, slot);
        if (!selected) continue;
        if (std.mem.eql(u8, entry.kind, "symlink")) return error.SymlinkInSelectedCustody;
        if (!std.mem.eql(u8, entry.kind, "file") or
            std.mem.endsWith(u8, name, ".cas.lock.advisory"))
            continue;
        const archived = try std.fmt.allocPrint(
            allocator,
            "worktree-{s}/{s}",
            .{ snapshot.sources.map.keys()[index], name },
        );
        defer allocator.free(archived);
        try copyFile(allocator, io, archive_root, archived, destination, name, entry);
    }
}

pub fn coldInventory(
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
    slots: []const []const u8,
    limits: Limits,
) !Inventory {
    if (slots.len == 0) return error.MissingOwnerDefinitions;
    var result = try inventory(allocator, io, roots, slots, &.{}, limits);
    errdefer result.deinit();
    for (result.sources.map.values()) |*source| {
        var i: usize = 0;
        while (i < source.entries.map.count()) {
            const name = source.entries.map.keys()[i];
            const entry = source.entries.map.values()[i];
            if (std.mem.eql(u8, entry.kind, "directory")) {
                _ = source.entries.map.orderedRemove(name);
                continue;
            }
            if (!std.mem.eql(u8, entry.kind, "file")) return error.UnsupportedColdAdoptionEntry;
            const local = name[8..];
            var selected = false;
            for (slots) |slot| selected = selected or std.mem.eql(u8, local, slot);
            const advisory = ".cas.lock.advisory";
            var skip = below(local, ".transactions") or below(local, ".fencing.counter");
            if (std.mem.endsWith(u8, local, advisory)) {
                const original = local[0 .. local.len - advisory.len];
                var selected_advisory = archivedControl(local);
                for (slots) |slot| selected_advisory = selected_advisory or
                    std.mem.eql(u8, original, slot);
                skip = skip or selected_advisory;
            }
            if (skip) {
                _ = source.entries.map.orderedRemove(name);
                continue;
            }
            if (std.mem.endsWith(u8, name, ".cas.lock")) return error.LegacyLeaseRequiresRecovery;
            if (!selected and !archivedControl(local)) return error.UncoveredLegacyFile;
            i += 1;
        }
    }
    return result;
}

pub fn copyCold(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: *const Inventory,
    index: usize,
    destination: []const u8,
) !void {
    if (index >= snapshot.sources.map.count()) return error.InvalidSourceIndex;
    const source = snapshot.sources.map.values()[index];
    for (source.entries.map.keys(), source.entries.map.values()) |name, entry| {
        if (!std.mem.eql(u8, entry.kind, "file")) return error.UnsupportedColdAdoptionEntry;
        try copyFile(allocator, io, source.workspace, name, destination, name, entry);
    }
}

fn testWrite(root: []const u8, name: []const u8, bytes: []const u8) !void {
    const dir = try openParent(std.testing.allocator, std.testing.io, root, name, true);
    defer dir.close(std.testing.io);
    const file = try dir.createFile(std.testing.io, std.fs.path.basename(name), .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}

test "legacy transport archives unselected bytes and inert links and FIFO metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try testWrite(root, ".ledger/owner/events.jsonl", "a\n");
    try testWrite(root, ".ledger/unselected/raw", "unselected bytes");
    try tmp.dir.symLink(io, "/absent/external", ".ledger/unselected/link", .{});
    const fifo = try std.fs.path.join(allocator, &.{ root, ".ledger/unselected/pipe" });
    defer allocator.free(fifo);
    const created = try std.process.run(allocator, io, .{ .argv = &.{ "mkfifo", fifo } });
    defer allocator.free(created.stdout);
    defer allocator.free(created.stderr);
    try std.testing.expect(created.term == .exited and created.term.exited == 0);
    var snapshot = try inventory(allocator, io, &.{root}, &.{"owner/events.jsonl"}, &.{}, .{});
    defer snapshot.deinit();
    const entries = snapshot.sources.map.values()[0].entries;
    try std.testing.expectEqualStrings(
        "/absent/external",
        entries.map.get(".ledger/unselected/link").?.target.?,
    );
    try std.testing.expectEqualStrings("fifo", entries.map.get(".ledger/unselected/pipe").?.kind);
    try std.testing.expectError(
        error.UnsupportedSpecialSourceEntry,
        inventory(allocator, io, &.{root}, &.{"unselected/pipe"}, &.{}, .{}),
    );
    const target = try std.fs.path.join(allocator, &.{ root, "archive" });
    defer allocator.free(target);
    try archive(allocator, io, &snapshot, target);
    try verifyArchive(allocator, io, &snapshot, target);
    try archive(allocator, io, &snapshot, target);
    try std.testing.expect(!try catalog.existsAt(
        io,
        tmp.dir,
        "archive/worktree-0/.ledger/unselected/link",
    ));
    try std.testing.expect(!try catalog.existsAt(
        io,
        tmp.dir,
        "archive/worktree-0/.ledger/unselected/pipe",
    ));
    const destination = try std.fs.path.join(allocator, &.{ root, "custody" });
    defer allocator.free(destination);
    try copySelected(allocator, io, &snapshot, 0, &.{"owner/events.jsonl"}, target, destination);
    try std.testing.expect(try catalog.existsAt(io, tmp.dir, "custody/.ledger/owner/events.jsonl"));
    try std.testing.expect(!try catalog.existsAt(io, tmp.dir, "custody/.ledger/unselected"));
    try tmp.dir.symLink(io, "/absent/external", "archive/worktree-0/.ledger/unselected/link", .{});
    try std.testing.expectError(
        error.ArchiveTopologyMismatch,
        verifyArchive(allocator, io, &snapshot, target),
    );
    try tmp.dir.deleteFile(io, "archive/worktree-0/.ledger/unselected/link");
    try testWrite(target, "worktree-0/.ledger/unselected/raw", "tampered bytes");
    try std.testing.expectError(
        error.SourceChanged,
        verifyArchive(allocator, io, &snapshot, target),
    );
    const serialized = try snapshot.json(allocator);
    defer allocator.free(serialized);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"target\":null") == null);
}

test "legacy transport selects complete prefixes and rejects divergent and partial rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const a = try std.fs.path.join(allocator, &.{ root, "a" });
    defer allocator.free(a);
    const b = try std.fs.path.join(allocator, &.{ root, "b" });
    defer allocator.free(b);
    const slot = "owner/events.jsonl";
    try testWrite(a, ".ledger/owner/events.jsonl", "a\n");
    try testWrite(b, ".ledger/owner/events.jsonl", "a\nb\n");
    var snapshot = try inventory(allocator, io, &.{ a, b }, &.{slot}, &.{}, .{});
    defer snapshot.deinit();
    try std.testing.expectEqual(
        @as(?usize, 1),
        try selectSource(allocator, io, &snapshot, &.{slot}),
    );
    try testWrite(a, ".ledger/owner/events.jsonl", "a");
    var partial = try inventory(allocator, io, &.{ a, b }, &.{slot}, &.{}, .{});
    defer partial.deinit();
    try std.testing.expectError(
        error.DivergentSelectedHistories,
        selectSource(allocator, io, &partial, &.{slot}),
    );
    try testWrite(b, ".ledger/owner/events.jsonl", "a");
    var equal = try inventory(allocator, io, &.{ a, b }, &.{slot}, &.{}, .{});
    defer equal.deinit();
    try std.testing.expectEqual(@as(?usize, 0), try selectSource(allocator, io, &equal, &.{slot}));
    try testWrite(a, ".ledger/owner/events.jsonl", "different\n");
    var divergent = try inventory(allocator, io, &.{ a, b }, &.{slot}, &.{}, .{});
    defer divergent.deinit();
    try std.testing.expectError(
        error.DivergentSelectedHistories,
        selectSource(allocator, io, &divergent, &.{slot}),
    );
}

test "legacy transport bounds inventory and rejects selected links and missing roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const missing = try std.fs.path.join(allocator, &.{ root, "missing" });
    defer allocator.free(missing);
    try std.testing.expectError(
        error.FileNotFound,
        inventory(allocator, io, &.{missing}, &.{}, &.{}, .{}),
    );
    try testWrite(root, ".ledger/owner/events.jsonl", "large");
    try std.testing.expectError(
        error.MigrationInventoryBoundExceeded,
        inventory(allocator, io, &.{root}, &.{}, &.{}, .{ .max_bytes = 2 }),
    );
    try std.testing.expectError(
        error.MigrationInventoryBoundExceeded,
        inventory(allocator, io, &.{root}, &.{}, &.{}, .{ .max_files = 1 }),
    );
    try tmp.dir.deleteFile(io, ".ledger/owner/events.jsonl");
    try tmp.dir.symLink(io, "/absent/external", ".ledger/owner/events.jsonl", .{});
    var linked = try inventory(allocator, io, &.{root}, &.{"owner/events.jsonl"}, &.{}, .{});
    defer linked.deinit();
    try std.testing.expectError(
        error.UnsupportedSelectedSlot,
        selectSource(allocator, io, &linked, &.{"owner/events.jsonl"}),
    );
}

test "legacy cold adoption retains covered bytes and excludes transient advisory files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try testWrite(root, ".ledger/owner/events.jsonl", "a\n");
    try testWrite(root, ".ledger/owner/events.jsonl.cas.lock.advisory", "");
    try testWrite(root, ".ledger/.transactions/stale", "transport must omit");
    var snapshot = try coldInventory(allocator, io, &.{root}, &.{"owner/events.jsonl"}, .{});
    defer snapshot.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        snapshot.sources.map.values()[0].entries.map.count(),
    );
    const destination = try std.fs.path.join(allocator, &.{ root, "cold" });
    defer allocator.free(destination);
    try copyCold(allocator, io, &snapshot, 0, destination);
    try testWrite(root, ".ledger/unselected", "retain but require explicit broad archive");
    try std.testing.expectError(
        error.UncoveredLegacyFile,
        coldInventory(allocator, io, &.{root}, &.{"owner/events.jsonl"}, .{}),
    );
    try tmp.dir.deleteFile(io, ".ledger/unselected");
    try testWrite(root, ".ledger/owner/events.jsonl.cas.lock", "lease");
    try std.testing.expectError(
        error.LegacyLeaseRequiresRecovery,
        coldInventory(allocator, io, &.{root}, &.{"owner/events.jsonl"}, .{}),
    );
}
