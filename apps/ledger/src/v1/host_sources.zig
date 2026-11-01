const std = @import("std");
const host = @import("host_context.zig");
const catalog = @import("host_catalog.zig");
const workspace = @import("host_workspace.zig");
const preparation = @import("ledger_v1_core").preparation;
const legacy = @import("host_legacy.zig");

pub const Trees = struct {
    arena: std.heap.ArenaAllocator,
    roots: []const []const u8,
    workspace_root: []const u8,
    git_common_dir: ?[]const u8,

    pub fn deinit(self: *Trees) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Sources = struct {
    arena: std.heap.ArenaAllocator,
    trees: []const []const u8,
    sources: []preparation.Source,

    pub fn deinit(self: *Sources) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Marker = struct { schema: []const u8, store_id: []const u8 };
const max_sources = 128;

pub fn trees(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    selected: []const u8,
) !Trees {
    return treesForTarget(allocator, io, environment, selected, null);
}

pub fn treesForTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    selected: []const u8,
    target: ?host.ContextValue,
) !Trees {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const selected_dir = try catalog.openDirectory(io, selected, false);
    defer selected_dir.close(io);
    const canonical = try selected_dir.realPathFileAlloc(io, ".", owned);
    try admitSelectedRoot(allocator, io, selected_dir, canonical, target);
    const paths = try workspace.gitOrPlain(
        owned,
        io,
        environment,
        canonical,
    );
    var result: Trees = .{
        .arena = arena,
        .roots = undefined,
        .workspace_root = canonical,
        .git_common_dir = null,
    };
    var found: std.ArrayList([]const u8) = .empty;
    if (paths) |git| {
        result.workspace_root = git.root;
        result.git_common_dir = git.common;
        const root_dir = try catalog.openDirectory(io, git.root, false);
        defer root_dir.close(io);
        try admitSelectedRoot(allocator, io, root_dir, git.root, target);
        try appendGitTrees(owned, io, environment, git, &found);
    } else {
        try found.append(owned, canonical);
    }
    for (found.items) |root| {
        const control = try std.fs.path.join(owned, &.{ root, ".ledger" });
        _ = try noSymlinks(io, control);
    }
    std.mem.sort([]const u8, found.items, {}, lessString);
    result.roots = try found.toOwnedSlice(owned);
    result.arena = arena;
    return result;
}

fn admitSelectedRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
    target: ?host.ContextValue,
) !void {
    if (!try catalog.existsAt(io, directory, ".ledger-root.json")) return;
    const current = target orelse return error.ManagedRootRequiresRegistration;
    if (!std.mem.eql(u8, path, current.store_root)) return error.ManagedRootRequiresRegistration;
    const control = try catalog.checkedRoot(allocator, io, path, current.store_id);
    control.close(io);
}

fn appendGitTrees(
    owned: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    git: workspace.GitPaths,
    found: *std.ArrayList([]const u8),
) !void {
    const output = try workspace.git(
        owned,
        io,
        environment,
        git.root,
        &.{ "worktree", "list", "--porcelain", "-z" },
    );
    var fields = std.mem.splitScalar(u8, output, 0);
    while (fields.next()) |field| {
        if (!std.mem.startsWith(u8, field, "worktree ")) continue;
        if (found.items.len == max_sources) return error.WorkspaceDiscoveryBoundExceeded;
        const path = field["worktree ".len..];
        const dir = catalog.openDirectory(io, path, false) catch |err| switch (err) {
            error.FileNotFound => return error.UnavailableWorktree,
            else => return err,
        };
        defer dir.close(io);
        const canonical = try dir.realPathFileAlloc(io, ".", owned);
        const verified = try workspace.verifiedGit(owned, io, environment, canonical);
        if (!std.mem.eql(u8, verified.root, canonical) or
            !std.mem.eql(u8, verified.common, git.common))
            return error.WorktreeGitIdentityChanged;
        try found.append(owned, canonical);
    }
    if (found.items.len == 0) return error.IncompleteWorkspaceDiscovery;
}

pub fn discover(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    selected: ?[]const u8,
    target: ?host.ContextValue,
    slot: []const u8,
    retired: []const []const u8,
    discover_archives: bool,
) !Sources {
    try legacy.relative(slot);
    for (retired) |path| try legacy.relative(path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var roots: []const []const u8 = &.{};
    if (selected) |path| {
        var discovered = try treesForTarget(allocator, io, environment, path, target);
        defer discovered.deinit();
        const copied = try owned.alloc([]const u8, discovered.roots.len);
        for (discovered.roots, copied) |root, *copy| copy.* = try owned.dupe(u8, root);
        roots = copied;
    }
    var result: std.ArrayList(preparation.Source) = .empty;
    for (roots) |root| {
        for (retired) |path| {
            const full = try std.fs.path.join(owned, &.{ root, path });
            if (try existsWithoutFollowing(io, full))
                return error.RetiredSourceRequiresOwnerImporter;
        }
        if (target) |current| if (std.mem.eql(u8, current.store_root, root)) continue;
        const marker_path = try std.fs.path.join(owned, &.{ root, ".ledger-root.json" });
        var source: preparation.Source = .{ .root = root };
        if (try existsWithoutFollowing(io, marker_path)) {
            const marker = try catalog.readJson(Marker, allocator, io, marker_path, 4096);
            defer marker.deinit();
            if (!std.mem.eql(u8, marker.value.schema, "ledger-storage-root/v1"))
                return error.InvalidSourceRootIdentity;
            const checked = try catalog.checkedRoot(allocator, io, root, marker.value.store_id);
            checked.close(io);
            source.store_id = try owned.dupe(u8, marker.value.store_id);
        }
        try result.append(owned, source);
    }
    if (target) |current| {
        if (discover_archives) try appendArchives(
            owned,
            allocator,
            io,
            current.store_root,
            slot,
            roots.len,
            &result,
        );
    }
    const source_slice = try result.toOwnedSlice(owned);
    return .{ .arena = arena, .trees = roots, .sources = source_slice };
}

fn appendArchives(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    slot: []const u8,
    tree_count: usize,
    sources: *std.ArrayList(preparation.Source),
) !void {
    const path = try std.fs.path.join(allocator, &.{ root, "legacy-archive" });
    const archive_dir = catalog.openDirectory(io, path, false) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer archive_dir.close(io);
    const generations = try archiveGenerations(allocator, io, archive_dir);
    const selected_slot = try std.fmt.allocPrint(allocator, ".ledger/{s}", .{slot});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(slot, &hash, .{});
    const binding = try std.fmt.allocPrint(
        allocator,
        ".ledger/.bindings/{s}.jsonl",
        .{std.fmt.bytesToHex(hash, .lower)},
    );
    var selected: std.StringHashMapUnmanaged(void) = .empty;
    var total: u64 = 0;
    for (generations) |name| {
        const generation = try archive_dir.openDir(io, name, .{ .follow_symlinks = false });
        defer generation.close(io);
        const bytes = try catalog.readBytes(
            scratch,
            io,
            generation,
            "manifest.json",
            32 * 1024 * 1024,
        );
        defer scratch.free(bytes);
        total += bytes.len;
        if (total > 2 * 1024 * 1024 * 1024) return error.ArchiveManifestByteBoundExceeded;
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            scratch,
            bytes,
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        try selectArchiveTrees(
            allocator,
            io,
            parsed.value,
            selected_slot,
            binding,
            path,
            name,
            tree_count,
            &selected,
        );
    }
    const ordered = try allocator.alloc([]const u8, selected.count());
    var keys = selected.keyIterator();
    var index: usize = 0;
    while (keys.next()) |key| : (index += 1) ordered[index] = key.*;
    std.mem.sort([]const u8, ordered, {}, lessString);
    for (ordered) |original| try sources.append(allocator, .{ .root = original, .archive = true });
}

fn noSymlinks(io: std.Io, path: []const u8) !bool {
    if (!std.fs.path.isAbsolute(path)) return error.StorageRootNotAbsolute;
    var dir = try std.Io.Dir.openDirAbsolute(io, "/", .{ .follow_symlinks = false });
    defer dir.close(io);
    var parts = std.fs.path.componentIterator(path);
    while (parts.next()) |component| {
        if (std.mem.eql(u8, component.name, ".") or
            std.mem.eql(u8, component.name, ".."))
            return error.InvalidStorageRootPath;
        const info = dir.statFile(
            io,
            component.name,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        if (info.kind == .sym_link) return error.SymlinkInSourcePath;
        if (parts.peekNext() == null) return true;
        const next = try dir.openDir(io, component.name, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return true;
}

fn existsWithoutFollowing(io: std.Io, path: []const u8) !bool {
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const parent = catalog.openDirectory(io, parent_path, false) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer parent.close(io);
    return catalog.existsAt(io, parent, std.fs.path.basename(path));
}

fn selectArchiveTrees(
    allocator: std.mem.Allocator,
    io: std.Io,
    value: std.json.Value,
    selected_slot: []const u8,
    binding: []const u8,
    path: []const u8,
    name: []const u8,
    tree_count: usize,
    selected: *std.StringHashMapUnmanaged(void),
) !void {
    if (value != .object) return error.InvalidArchiveManifest;
    const schema = value.object.get("schema") orelse return error.InvalidArchiveManifest;
    const all = value.object.get("sources") orelse return error.InvalidArchiveManifest;
    if (schema != .string or
        !std.mem.eql(u8, schema.string, "ledger-legacy-archive/v1") or
        all != .object or
        all.object.count() > max_sources)
        return error.InvalidArchiveManifest;
    for (all.object.keys(), all.object.values()) |index, tree| {
        if (index.len == 0) return error.InvalidArchiveWorktreeIndex;
        for (index) |byte| if (!std.ascii.isDigit(byte))
            return error.InvalidArchiveWorktreeIndex;
        if (tree != .object) return error.InvalidArchiveSourceInventory;
        const entries = tree.object.get("entries") orelse
            return error.InvalidArchiveSourceInventory;
        if (entries != .object or
            entries.object.count() > 100000)
            return error.InvalidArchiveSourceInventory;
        const entry = entries.object.get(selected_slot);
        if (entry == null or entry.? == .null) {
            if (!entries.object.contains(binding)) continue;
        } else if (entry.? != .object) return error.InvalidArchivedSlotEntry;
        const original = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/worktree-{s}",
            .{ path, name, index },
        );
        _ = try noSymlinks(io, original);
        try selected.put(allocator, original, {});
        if (selected.count() + tree_count > max_sources)
            return error.PreparationSourceBoundExceeded;
    }
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn testWrite(root: []const u8, name: []const u8, bytes: []const u8) !void {
    const allocator = std.testing.allocator;
    const parent = try std.fs.path.join(allocator, &.{ root, std.fs.path.dirname(name) orelse "" });
    defer allocator.free(parent);
    const dir = try catalog.openDirectory(std.testing.io, parent, true);
    defer dir.close(std.testing.io);
    const file = try dir.createFile(std.testing.io, std.fs.path.basename(name), .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}

fn testGit(
    environment: *const std.process.Environ.Map,
    root: []const u8,
    arguments: []const []const u8,
) !void {
    const bytes = try workspace.git(
        std.testing.allocator,
        std.testing.io,
        environment,
        root,
        arguments,
    );
    defer std.testing.allocator.free(bytes);
}

test "host sources discovery is read only and retired evidence blocks native preparation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const parent = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer parent.close(io);
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const temporary = std.fmt.bytesToHex(random, .lower);
    try parent.createDir(io, &temporary, .fromMode(0o700));
    defer parent.deleteTree(io, &temporary) catch |err| @panic(@errorName(err));
    const dir = try parent.openDir(io, &temporary, .{});
    defer dir.close(io);
    const root = try dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var plain = try discover(
        allocator,
        io,
        &environment,
        root,
        null,
        "owner/events.jsonl",
        &.{".retired.jsonl"},
        true,
    );
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 1), plain.trees.len);
    try std.testing.expectEqual(@as(usize, 1), plain.sources.len);
    try std.testing.expect(plain.sources[0].store_id == null and !plain.sources[0].archive);
    try std.testing.expect(!try catalog.existsAt(io, dir, ".ledger"));
    try testWrite(root, ".retired.jsonl", "old owner material");
    try std.testing.expectError(
        error.RetiredSourceRequiresOwnerImporter,
        discover(
            allocator,
            io,
            &environment,
            root,
            null,
            "owner/events.jsonl",
            &.{".retired.jsonl"},
            true,
        ),
    );
    try dir.deleteFile(io, ".retired.jsonl");
    try dir.symLink(io, "/missing", ".ledger", .{});
    try std.testing.expectError(
        error.SymlinkInSourcePath,
        trees(allocator, io, &environment, root),
    );
}

test "host sources reject broken Git and preserve sibling identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try testInitializeGitFamily(root, tmp.dir, &environment);
    const linked = try std.fs.path.join(allocator, &.{ root, "linked" });
    defer allocator.free(linked);
    try testGit(&environment, root, &.{ "worktree", "add", "--detach", linked });
    try testWrite(
        linked,
        ".ledger-root.json",
        "{\"schema\":\"ledger-storage-root/v1\",\"store_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
    );
    try testWrite(linked, ".ledger/owner/events.jsonl", "");
    var found = try discover(
        allocator,
        io,
        &environment,
        root,
        null,
        "owner/events.jsonl",
        &.{},
        false,
    );
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 2), found.sources.len);
    try std.testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        found.sources[1].store_id.?,
    );
    try std.testing.expectError(
        error.ManagedRootRequiresRegistration,
        trees(allocator, io, &environment, linked),
    );
    try testWrite(
        linked,
        ".ledger-root.json",
        "{\"schema\":\"wrong\",\"store_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
    );
    try std.testing.expectError(
        error.InvalidSourceRootIdentity,
        discover(allocator, io, &environment, root, null, "owner/events.jsonl", &.{}, false),
    );
    try tmp.dir.deleteTree(io, "linked");
    try std.testing.expectError(
        error.UnavailableWorktree,
        trees(allocator, io, &environment, root),
    );
}

test "host sources select archived events and bindings without unrelated reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var target = try host.context(
        allocator,
        root,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        null,
        null,
        false,
    );
    defer target.deinit();
    const slot = "owner/events.jsonl";
    try testArchiveManifest(root, slot);
    var found = try discover(allocator, io, &environment, null, target.value, slot, &.{}, true);
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 0), found.trees.len);
    try std.testing.expectEqual(@as(usize, 2), found.sources.len);
    try std.testing.expect(found.sources[0].archive and found.sources[1].archive);
    try std.testing.expect(std.mem.endsWith(u8, found.sources[0].root, "worktree-0"));
    var skipped = try discover(allocator, io, &environment, null, target.value, slot, &.{}, false);
    defer skipped.deinit();
    try std.testing.expectEqual(@as(usize, 0), skipped.sources.len);
    try testWrite(
        root,
        "legacy-archive/a/manifest.json",
        "{\"schema\":\"ledger-legacy-archive/v1\",\"sources\":{\"../escape\":{\"entries\":{}}}}",
    );
    try std.testing.expectError(
        error.InvalidArchiveWorktreeIndex,
        discover(allocator, io, &environment, null, target.value, slot, &.{}, true),
    );
    try testWrite(
        root,
        "legacy-archive/a/manifest.json",
        "{\"schema\":\"ledger-legacy-archive/v1\"," ++
            "\"sources\":{\"0\":{\"entries\":{\".ledger/owner/events.jsonl\":42}}}}",
    );
    try std.testing.expectError(
        error.InvalidArchivedSlotEntry,
        discover(allocator, io, &environment, null, target.value, slot, &.{}, true),
    );
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    var oversized: std.json.ArrayHashMap(struct { entries: std.json.ArrayHashMap(u8) = .{} }) = .{};
    for (0..129) |index| try oversized.map.put(
        owned,
        try std.fmt.allocPrint(owned, "{d}", .{index}),
        .{},
    );
    const too_many = try legacy.canonicalAlloc(
        allocator,
        .{ .schema = "ledger-legacy-archive/v1", .sources = oversized },
    );
    defer allocator.free(too_many);
    try testWrite(root, "legacy-archive/a/manifest.json", too_many);
    try std.testing.expectError(
        error.InvalidArchiveManifest,
        discover(allocator, io, &environment, null, target.value, slot, &.{}, true),
    );
}

fn testInitializeGitFamily(
    root: []const u8,
    dir: std.Io.Dir,
    environment: *const std.process.Environ.Map,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try testWrite(root, ".git", "gitdir: /missing/repository\n");
    try std.testing.expectError(
        error.UnverifiableGitFamily,
        trees(allocator, io, environment, root),
    );
    try dir.deleteFile(io, ".git");
    try testGit(environment, root, &.{ "init", "-q" });
    try testGit(
        environment,
        root,
        &.{
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "--allow-empty",
            "-qm",
            "fixture",
        },
    );
}

fn testArchiveManifest(root: []const u8, slot: []const u8) !void {
    const allocator = std.testing.allocator;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(slot, &hash, .{});
    const manifest = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"ledger-legacy-archive/v1\",\"sources\":{{" ++
            "\"0\":{{\"entries\":{{\".ledger/owner/events.jsonl\":{{\"kind\":\"file\"}}," ++
            "\".ledger/other\":{{\"kind\":\"file\"}}}}}}," ++
            "\"1\":{{\"entries\":{{\".ledger/.bindings/{s}.jsonl\":{{\"kind\":\"file\"}}}}}}," ++
            "\"2\":{{\"entries\":{{\".ledger/unrelated\":{{\"kind\":\"file\"}}}}}}}}}}",
        .{std.fmt.bytesToHex(hash, .lower)},
    );
    defer allocator.free(manifest);
    try testWrite(root, "legacy-archive/a/manifest.json", manifest);
}

fn archiveGenerations(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_dir: std.Io.Dir,
) ![]const []const u8 {
    var generations: std.ArrayList([]const u8) = .empty;
    var iterator = archive_dir.iterate();
    var observed: usize = 0;
    while (try iterator.next(io)) |entry| {
        observed += 1;
        if (observed > 100000) return error.ArchiveManifestBoundExceeded;
        if (unpublishedArchive(entry.name)) continue;
        if (generations.items.len == max_sources) return error.ArchiveManifestBoundExceeded;
        const generation = try archive_dir.openDir(io, entry.name, .{ .follow_symlinks = false });
        generation.close(io);
        try generations.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, generations.items, {}, lessString);
    return generations.toOwnedSlice(allocator);
}

fn unpublishedArchive(name: []const u8) bool {
    const prefix = ".archiving-";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    if (name.len == prefix.len + 8) {
        for (name[prefix.len..]) |byte| {
            if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'z') and byte != '_')
                return false;
        }
        return true;
    }
    if (name.len != prefix.len + 32) return false;
    for (name[prefix.len..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

test "host archive discovery retains old stages beside valid generations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var target = try host.context(
        allocator,
        root,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        null,
        null,
        false,
    );
    defer target.deinit();
    const slot = "owner/events.jsonl";
    try testArchiveManifest(root, slot);
    const native = "legacy-archive/.archiving-0123456789abcdef0123456789abcdef/partial";
    const python_stage = "legacy-archive/.archiving-a1b2c3d_/partial";
    try testWrite(root, native, "retain native stage");
    try testWrite(root, python_stage, "retain Python stage");
    var found = try discover(allocator, io, &environment, null, target.value, slot, &.{}, true);
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 2), found.sources.len);
    try std.testing.expect(found.sources[0].archive and found.sources[1].archive);
    for (&[_][]const u8{ native, python_stage }) |path| {
        const bytes = try catalog.readBytes(allocator, io, tmp.dir, path, 128);
        defer allocator.free(bytes);
        try std.testing.expect(std.mem.startsWith(u8, bytes, "retain "));
    }
    try testWrite(root, "legacy-archive/.archiving-unknown/partial", "unclassified");
    try std.testing.expectError(
        error.FileNotFound,
        discover(allocator, io, &environment, null, target.value, slot, &.{}, true),
    );
}
