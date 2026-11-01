const std = @import("std");
const durable_store = @import("durable_store");
const storage_root = @import("storage_root");

pub const filename = "catalog.json";
pub const schema = "ledger-personal-catalog/v1";
pub const registration_name = "ledger-store.json";
pub const registration_schema = "ledger-repository-registration/v1";
pub const max_catalog_bytes = 1048576;

pub const Document = struct {
    schema: []const u8,
    stores: std.json.ArrayHashMap([]const u8),
    aliases: std.json.ArrayHashMap([]const u8),
    workspace_identities: std.json.ArrayHashMap(?[]const u8) = .{},
};

pub fn empty() Document {
    return .{ .schema = schema, .stores = .{}, .aliases = .{} };
}

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    value: Document,

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn associate(self: *Catalog, aliases: []const []const u8, store_id: []const u8) !bool {
        var changed = false;
        for (aliases) |alias| {
            if (self.value.aliases.map.get(alias)) |existing| {
                if (!std.mem.eql(u8, existing, store_id))
                    return error.ConflictingWorkspaceAssociations;
            }
        }
        const allocator = self.arena.allocator();
        const common = commonAlias(aliases);
        for (aliases) |alias| {
            if (!self.value.aliases.map.contains(alias)) {
                try self.value.aliases.map.put(
                    allocator,
                    try allocator.dupe(u8, alias),
                    try allocator.dupe(u8, store_id),
                );
                changed = true;
            }
            if (std.mem.startsWith(u8, alias, "workspace:")) {
                const existing = self.value.workspace_identities.map.getEntry(alias);
                if (existing == null or !optionalEqual(existing.?.value_ptr.*, common)) {
                    try self.value.workspace_identities.map.put(
                        allocator,
                        try allocator.dupe(u8, alias),
                        if (common) |path| try allocator.dupe(u8, path) else null,
                    );
                    changed = true;
                }
            }
        }
        return changed;
    }

    pub fn register(self: *Catalog, store_id: []const u8, root: []const u8) !bool {
        try validStoreId(store_id);
        if (!std.fs.path.isAbsolute(root)) return error.StorageRootNotAbsolute;
        if (self.value.stores.map.get(store_id)) |existing| {
            if (!std.mem.eql(u8, existing, root)) return error.StoreAlreadyCatalogedAtAnotherRoot;
            return false;
        }
        const allocator = self.arena.allocator();
        try self.value.stores.map.put(
            allocator,
            try allocator.dupe(u8, store_id),
            try allocator.dupe(u8, root),
        );
        return true;
    }

    pub fn select(
        self: *const Catalog,
        aliases: []const []const u8,
        store_id: ?[]const u8,
        attach: bool,
    ) !?[]const u8 {
        if (store_id) |id| {
            try validStoreId(id);
            if (!self.value.stores.map.contains(id)) return error.SelectedStoreNotCataloged;
        }
        var associated: ?[]const u8 = null;
        var workspace_id: ?[]const u8 = null;
        for (aliases) |alias| {
            if (self.value.aliases.map.get(alias)) |id| {
                if (associated) |previous| {
                    if (!std.mem.eql(u8, previous, id))
                        return error.ConflictingWorkspaceAssociations;
                }
                if (store_id) |explicit| {
                    if (!std.mem.eql(u8, explicit, id))
                        return error.ConflictingWorkspaceAssociations;
                }
                associated = id;
                if (std.mem.startsWith(u8, alias, "workspace:")) workspace_id = id;
            }
        }
        if (!attach) {
            if (workspace_id) |id| {
                for (aliases) |alias| {
                    if (std.mem.startsWith(u8, alias, "git-common-dir:") and
                        !optionalEqual(
                            self.value.aliases.map.get(alias),
                            id,
                        )) return error.UnregisteredGitCommonDirectory;
                }
            }
        }
        const live_common = commonAlias(aliases);
        for (aliases) |alias| {
            if (!std.mem.startsWith(u8, alias, "workspace:")) continue;
            const id = self.value.aliases.map.get(alias) orelse continue;
            if (self.value.workspace_identities.map.getEntry(alias)) |identity| {
                if (identity.value_ptr.*) |expected| {
                    if (!optionalEqual(live_common, expected) and
                        (live_common == null or
                            !attach))
                    {
                        return error.GitCommonDirectoryIdentityChanged;
                    }
                }
            } else if (live_common == null) {
                for (
                    self.value.aliases.map.keys(),
                    self.value.aliases.map.values(),
                ) |key, selected| {
                    if (std.mem.startsWith(u8, key, "git-common-dir:") and
                        std.mem.eql(u8, selected, id))
                    {
                        return error.LegacyGitCommonDirectoryUnverifiable;
                    }
                }
            }
        }
        return store_id orelse associated;
    }
};

pub fn validStoreId(id: []const u8) !void {
    if (id.len != 32) return error.InvalidStoreIdentity;
    for (id) |byte| {
        if (!std.ascii.isDigit(byte) and
            !(byte >= 'a' and
                byte <= 'f'))
            return error.InvalidStoreIdentity;
    }
}

pub fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn commonAlias(aliases: []const []const u8) ?[]const u8 {
    for (aliases) |alias| {
        if (std.mem.startsWith(u8, alias, "git-common-dir:")) return alias["git-common-dir:".len..];
    }
    return null;
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !Catalog {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const dir = openDirectory(io, home, false) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .value = empty() },
        else => return err,
    };
    defer dir.close(io);
    const value = try readAt(arena.allocator(), io, dir);
    return .{ .arena = arena, .value = value };
}

pub fn readAt(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Document {
    const bytes = readBytes(
        allocator,
        io,
        dir,
        filename,
        max_catalog_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return empty(),
        else => return err,
    };
    defer allocator.free(bytes);
    const value = std.json.parseFromSliceLeaky(Document, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidPersonalCatalog;
    try validate(value);
    return value;
}

pub fn validate(value: Document) !void {
    if (!std.mem.eql(u8, value.schema, schema)) return error.InvalidPersonalCatalog;
    for (value.stores.map.keys(), value.stores.map.values()) |id, root| {
        try validStoreId(id);
        if (!std.fs.path.isAbsolute(root)) return error.InvalidCatalogRoot;
    }
    for (value.aliases.map.keys(), value.aliases.map.values()) |alias, id| {
        const split = std.mem.findScalar(u8, alias, ':') orelse
            return error.InvalidWorkspaceAssociation;
        if ((!std.mem.eql(u8, alias[0..split], "workspace") and
            !std.mem.eql(u8, alias[0..split], "git-common-dir")) or
            !std.fs.path.isAbsolute(alias[split + 1 ..]) or !value.stores.map.contains(id))
        {
            return error.InvalidWorkspaceAssociation;
        }
    }
    for (
        value.workspace_identities.map.keys(),
        value.workspace_identities.map.values(),
    ) |alias, common| {
        const id = value.aliases.map.get(alias) orelse return error.InvalidWorkspaceIdentity;
        if (!std.mem.startsWith(u8, alias, "workspace:")) return error.InvalidWorkspaceIdentity;
        if (common) |path| {
            if (!std.fs.path.isAbsolute(path)) return error.InvalidWorkspaceIdentity;
            var found = false;
            for (value.aliases.map.keys(), value.aliases.map.values()) |candidate, selected| {
                if (std.mem.startsWith(u8, candidate, "git-common-dir:") and
                    std.mem.eql(
                        u8,
                        candidate["git-common-dir:".len..],
                        path,
                    ) and std.mem.eql(u8, selected, id)) found = true;
            }
            if (!found) return error.InvalidWorkspaceIdentity;
        }
    }
}

pub const Lock = struct {
    dir: std.Io.Dir,
    file: std.Io.File,
    io: std.Io,

    pub fn acquire(io: std.Io, home: []const u8) !Lock {
        const dir = try openDirectory(io, home, true);
        errdefer dir.close(io);
        const file = try openLock(io, dir, "catalog.lock");
        errdefer file.close(io);
        if ((try file.stat(io)).kind != .file) return error.InvalidCatalogLock;
        lockExclusive(io, file) catch |err| switch (err) {
            error.LockBusy => return error.CatalogLockBusy,
            else => return err,
        };
        return .{ .dir = dir, .file = file, .io = io };
    }

    pub fn deinit(self: *Lock) void {
        self.file.close(self.io);
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn read(self: *const Lock, allocator: std.mem.Allocator) !Catalog {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const value = try readAt(arena.allocator(), self.io, self.dir);
        return .{ .arena = arena, .value = value };
    }

    pub fn publish(self: *const Lock, allocator: std.mem.Allocator, value: Document) !void {
        try validate(value);
        try writeJson(allocator, self.io, self.dir, filename, value, max_catalog_bytes);
    }
};

pub fn openLock(io: std.Io, dir: std.Io.Dir, name: []const u8) !std.Io.File {
    for (0..4) |_| {
        return dir.createFile(io, name, .{
            .exclusive = true,
            .read = true,
            .truncate = false,
            .permissions = .fromMode(0o600),
        }) catch |create_error| switch (create_error) {
            error.PathAlreadyExists => blk: {
                const fd = std.posix.openat(dir.handle, name, .{
                    .ACCMODE = .RDWR,
                    .NOFOLLOW = true,
                    .NONBLOCK = true,
                    .CLOEXEC = true,
                }, 0) catch |open_error| switch (open_error) {
                    error.FileNotFound => continue,
                    else => return open_error,
                };
                break :blk .{ .handle = fd, .flags = .{ .nonblocking = true } };
            },
            else => return create_error,
        };
    }
    return error.LockFileDisappeared;
}

pub fn lockExclusive(io: std.Io, file: std.Io.File) !void {
    for (0..301) |attempt| {
        if (try file.tryLock(io, .exclusive)) return;
        if (attempt == 300) return error.LockBusy;
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    }
    unreachable;
}

pub fn openDirectory(io: std.Io, path: []const u8, create: bool) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return error.StorageRootNotAbsolute;
    var current = try std.Io.Dir.openDirAbsolute(
        io,
        "/",
        .{ .follow_symlinks = false, .iterate = true },
    );
    errdefer current.close(io);
    var components = std.fs.path.componentIterator(path);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
            return error.InvalidStorageRootPath;
        }
        const next = current.openDir(
            io,
            component.name,
            .{ .follow_symlinks = false, .iterate = true },
        ) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (!create) return err;
                current.createDir(
                    io,
                    component.name,
                    .fromMode(0o700),
                ) catch |create_error| switch (create_error) {
                    error.PathAlreadyExists => {},
                    else => return create_error,
                };
                try sync(io, current);
                break :blk try current.openDir(
                    io,
                    component.name,
                    .{ .follow_symlinks = false, .iterate = true },
                );
            },
            else => return err,
        };
        current.close(io);
        current = next;
    }
    return current;
}

pub fn readBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    limit: usize,
) ![]u8 {
    var budget: durable_store.ReadBudget = .{ .max_bytes = limit + 1, .max_files = 1 };
    var fs = durable_store.Fs.anchored(io, dir);
    fs.read_budget = &budget;
    return durable_store.readRegularFileNoSymlink(fs, allocator, path, limit);
}

pub fn readJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
) !std.json.Parsed(T) {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const dir = try openDirectory(io, parent, false);
    defer dir.close(io);
    const bytes = try readBytes(allocator, io, dir, std.fs.path.basename(path), limit);
    defer allocator.free(bytes);
    return std.json.parseFromSlice(
        T,
        allocator,
        bytes,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
}

pub fn writeJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    value: anytype,
    limit: usize,
) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    if (bytes.len >= limit) return error.CatalogSizeBoundExceeded;
    if (try existsAt(io, dir, name)) {
        if ((try dir.statFile(io, name, .{ .follow_symlinks = false })).kind != .file)
            return error.InvalidMetadataFile;
    }
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const temporary = try std.fmt.allocPrint(allocator, ".{s}.{s}", .{ name, hex });
    defer allocator.free(temporary);
    const file = try dir.createFile(
        io,
        temporary,
        .{ .exclusive = true, .permissions = .fromMode(0o600) },
    );
    defer file.close(io);
    defer dir.deleteFile(io, temporary) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("catalog temporary cleanup failed: {s}", .{@errorName(err)}),
    };
    try file.writeStreamingAll(io, bytes);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
    try dir.rename(temporary, dir, name, io);
    try sync(io, dir);
}

pub fn existsAt(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    _ = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn exists(io: std.Io, path: []const u8) !bool {
    try noSymlinks(io, path);
    return existsAt(io, std.Io.Dir.cwd(), path);
}

pub fn noSymlinks(io: std.Io, path: []const u8) !void {
    try durable_store.rejectSymlinkComponents(durable_store.Fs.init(io, std.Io.Dir.cwd()), path);
}

pub fn sync(io: std.Io, dir: std.Io.Dir) !void {
    const file = try dir.openFile(io, ".", .{
        .allow_directory = true,
        .follow_symlinks = false,
        .path_only = false,
    });
    defer file.close(io);
    try file.sync(io);
}

pub fn checkedRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    id: []const u8,
) !std.Io.Dir {
    try validStoreId(id);
    return storage_root.checkedRoot(allocator, io, path, id);
}

test "catalog distinguishes missing Git provenance from plain workspace identity" {
    var catalog = Catalog{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .value = empty(),
    };
    defer catalog.deinit();
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    _ = try catalog.register(id, "/custody");
    _ = try catalog.associate(&.{ "workspace:/plain", "git-common-dir:/repo/.git" }, id);
    _ = try catalog.associate(&.{"workspace:/plain"}, id);
    try std.testing.expectEqualStrings(
        id,
        (try catalog.select(&.{"workspace:/plain"}, null, false)).?,
    );
    _ = catalog.value.workspace_identities.map.swapRemove("workspace:/plain");
    try std.testing.expectError(
        error.LegacyGitCommonDirectoryUnverifiable,
        catalog.select(&.{"workspace:/plain"}, null, false),
    );
}

test "catalog association rejects replacement and requires explicit Git attachment" {
    var catalog = Catalog{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .value = empty(),
    };
    defer catalog.deinit();
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    _ = try catalog.register(id, "/custody");
    _ = try catalog.associate(&.{ "workspace:/repo", "git-common-dir:/old" }, id);
    try std.testing.expectError(
        error.UnregisteredGitCommonDirectory,
        catalog.select(&.{ "workspace:/repo", "git-common-dir:/new" }, null, false),
    );
    try std.testing.expectEqualStrings(
        id,
        (try catalog.select(&.{ "workspace:/repo", "git-common-dir:/new" }, id, true)).?,
    );
    try std.testing.expectError(
        error.GitCommonDirectoryIdentityChanged,
        catalog.select(&.{"workspace:/repo"}, id, true),
    );
    try std.testing.expectError(
        error.StoreAlreadyCatalogedAtAnotherRoot,
        catalog.register(id, "/replacement"),
    );
}

test "catalog metadata rejects missing fields duplicate keys and dangling associations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    for ([_][]const u8{
        "{}",
        "{\"schema\":\"ledger-personal-catalog/v1\",\"stores\":{}}",
        "{\"schema\":\"bad\",\"schema\":\"ledger-personal-catalog/v1\"," ++
            "\"stores\":{},\"aliases\":{}}",
        "{\"schema\":\"ledger-personal-catalog/v1\",\"stores\":{}," ++
            "\"aliases\":{\"workspace:/x\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}",
        "{\"schema\":\"ledger-personal-catalog/v1\",\"stores\":{}," ++
            "\"aliases\":{},\"unknown\":{}}",
    }) |bytes| {
        try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = bytes });
        if (read(allocator, io, root)) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.TestExpectedError;
        } else |_| {}
    }
    try tmp.dir.writeFile(io, .{
        .sub_path = filename,
        .data = "{\"schema\":\"ledger-personal-catalog/v1\",\"stores\":{},\"aliases\":{}}",
    });
    var legacy = try read(allocator, io, root);
    defer legacy.deinit();
    try std.testing.expectEqual(@as(usize, 0), legacy.value.workspace_identities.map.count());
}

test "catalog oversized publication leaves prior readable metadata intact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var lock = try Lock.acquire(io, root);
    defer lock.deinit();
    try lock.publish(allocator, empty());
    const before = try readBytes(allocator, io, tmp.dir, filename, max_catalog_bytes);
    defer allocator.free(before);
    var selected = try lock.read(allocator);
    defer selected.deinit();
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    _ = try selected.register(id, "/custody");
    const alias = try allocator.alloc(u8, max_catalog_bytes);
    defer allocator.free(alias);
    @memset(alias, 'x');
    @memcpy(alias[0..11], "workspace:/");
    _ = try selected.associate(&.{alias}, id);
    try std.testing.expectError(
        error.CatalogSizeBoundExceeded,
        lock.publish(allocator, selected.value),
    );
    const after = try readBytes(allocator, io, tmp.dir, filename, max_catalog_bytes);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

const ContendedLockWait = struct {
    var slept_ns: i96 = 0;

    fn sleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        std.debug.assert(timeout == .duration);
        std.debug.assert(timeout.duration.clock == .awake);
        slept_ns += timeout.duration.raw.nanoseconds;
    }

    fn blockingLock(
        _: ?*anyopaque,
        _: std.Io.File,
        _: std.Io.File.Lock,
    ) std.Io.File.LockError!void {
        return error.Unexpected;
    }
};

test "catalog contention has a bounded wait and preserves the active lock" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    var vtable = io.vtable.*;
    vtable.sleep = ContendedLockWait.sleep;
    vtable.fileLock = ContendedLockWait.blockingLock;
    var bounded = io;
    bounded.vtable = &vtable;
    ContendedLockWait.slept_ns = 0;
    var inode: std.Io.File.INode = undefined;
    {
        var active = try Lock.acquire(io, home);
        defer active.deinit();
        inode = (try active.file.stat(io)).inode;
        try std.testing.expectError(error.CatalogLockBusy, Lock.acquire(bounded, home));
        try std.testing.expectEqual(@as(i96, 30 * std.time.ns_per_s), ContendedLockWait.slept_ns);
        try std.testing.expectEqual(inode, (try active.file.stat(io)).inode);
        try std.testing.expect(!try existsAt(io, tmp.dir, filename));
    }
    var acquired = try Lock.acquire(bounded, home);
    defer acquired.deinit();
    try std.testing.expectEqual(inode, (try acquired.file.stat(io)).inode);
    try std.testing.expectEqual(@as(i96, 30 * std.time.ns_per_s), ContendedLockWait.slept_ns);
}
