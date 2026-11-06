const std = @import("std");
const host = @import("host_context.zig");
const catalog = host.catalog;
const workspace = host.workspace;
const migration_copy = @import("host_migration_copy.zig");
const migration_archive = @import("host_migration_archive.zig");

const max_sources = 128;
const marker_name = ".ledger-root.json";
const candidate_name = ".root-marker.json";
const Marker = struct { schema: []const u8, store_id: []const u8 };
const migration_copy_name = "migration-copy.json";
const migration_copy_schema = "ledger-migration-copy/v1";
const MigrationCopy = struct {
    schema: []const u8,
    store_id: []const u8,
    store_root: []const u8,
    source_sha256: ?[]const u8 = null,
};

pub const Registration = struct {
    schema: []const u8,
    store_id: []const u8,
    store_root: []const u8,
    workspace_root: []const u8,
    git_common_dir: ?[]const u8,
};

pub const Retained = struct {
    registration: Registration,
    // Allocation can survive before the marker is materialized. Neither state
    // establishes owner health, source coverage, or publication in the catalog.
    state: enum { allocated, materialized },
};

pub fn retained(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    registered: *const catalog.Catalog,
) ![]Retained {
    return scanRetained(allocator, io, home, registered, null);
}

fn scanRetained(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    registered: *const catalog.Catalog,
    selected_id: ?[]const u8,
) ![]Retained {
    const path = try std.fs.path.join(allocator, &.{ home, "preparations" });
    const controls = catalog.openDirectory(io, path, false) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Retained, 0),
        else => return err,
    };
    defer controls.close(io);
    var values: std.ArrayList(Retained) = .empty;
    var entries = controls.iterate();
    var count: usize = 0;
    while (try entries.next(io)) |entry| {
        if (count == max_sources) return error.PendingCustodyDiscoveryBoundExceeded;
        count += 1;
        const child = try controls.openDir(io, entry.name, .{ .follow_symlinks = false });
        defer child.close(io);
        const value = try readRetainedRegistration(
            allocator,
            io,
            home,
            child,
            entry.name,
        ) orelse continue;
        if (selected_id) |id| if (!std.mem.eql(u8, id, value.store_id)) continue;
        if (registered.value.stores.map.get(value.store_id)) |root| {
            if (!std.mem.eql(u8, root, value.store_root))
                return error.PendingCustodyConflictsWithCatalog;
            continue;
        }
        for (values.items) |previous| {
            if (std.mem.eql(u8, previous.registration.store_id, value.store_id))
                return error.ConflictingPendingIdentity;
        }
        const marker = try std.fs.path.join(allocator, &.{ value.store_root, marker_name });
        const materialized = try catalog.exists(io, marker);
        if (materialized) {
            const control = try catalog.checkedRoot(
                allocator,
                io,
                value.store_root,
                value.store_id,
            );
            control.close(io);
        } else try checkSkeleton(io, value.store_root);
        try values.append(allocator, .{
            .registration = value,
            .state = if (materialized) .materialized else .allocated,
        });
    }
    std.mem.sort(Retained, values.items, {}, struct {
        fn less(_: void, left: Retained, right: Retained) bool {
            return std.mem.lessThan(u8, left.registration.store_id, right.registration.store_id);
        }
    }.less);
    return values.toOwnedSlice(allocator);
}

fn readRetainedRegistration(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    directory: std.Io.Dir,
    name: []const u8,
) !?Registration {
    if (!try catalog.existsAt(io, directory, "registration.json")) return null;
    const bytes = try catalog.readBytes(allocator, io, directory, "registration.json", 4096);
    const value = try std.json.parseFromSliceLeaky(Registration, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    try validRegistration(allocator, value, home);
    const expected = try controlsPath(allocator, value.workspace_root, value.git_common_dir, home);
    if (!std.mem.eql(u8, name, std.fs.path.basename(expected)))
        return error.ConflictingPendingIdentity;
    return value;
}

pub fn readById(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    id: []const u8,
) !host.Context {
    try catalog.validStoreId(id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var registered = try catalog.read(allocator, io, home);
    defer registered.deinit();
    // Publication can complete after the caller's first catalog lookup.
    if (registered.value.stores.map.get(id)) |root| {
        return host.checkedRoot(allocator, io, root, id, null, null, false, true);
    }
    const values = try scanRetained(arena.allocator(), io, home, &registered, id);
    for (values) |value| {
        if (!std.mem.eql(u8, value.registration.store_id, id)) continue;
        if (value.state == .allocated) return error.PendingInitializationRequiresPreparation;
        return host.checkedRoot(
            allocator,
            io,
            value.registration.store_root,
            id,
            null,
            null,
            false,
            false,
        );
    }
    return error.SelectedStoreNotCataloged;
}

test "pending inventory rejects transplanted locators and conflicting root markers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", owned);
    const home = try std.fs.path.join(owned, &.{ root, "home" });
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var target = try prepareTarget(
        allocator,
        io,
        &environment,
        .{ .catalog_root = home, .workspace = root },
        true,
    );
    defer target.deinit();
    const id = target.context.value.store_id;
    const controls_path = try controlsPath(owned, root, null, home);
    const controls = try catalog.openDirectory(io, std.fs.path.dirname(controls_path).?, false);
    defer controls.close(io);
    const basename = std.fs.path.basename(controls_path);
    try controls.renamePreserve(basename, controls, "displaced", io);
    try std.testing.expectError(error.ConflictingPendingIdentity, host.list(allocator, io, home));
    try controls.renamePreserve("displaced", controls, basename, io);
    const custody = try catalog.openDirectory(io, target.context.value.store_root, false);
    defer custody.close(io);
    const original = try catalog.readBytes(owned, io, custody, marker_name, 4096);
    try custody.deleteFile(io, marker_name);
    var allocated = try host.list(allocator, io, home);
    defer allocated.deinit();
    try std.testing.expectEqual(.allocated, allocated.value.pending[0].state);
    try std.testing.expectError(
        error.PendingInitializationRequiresPreparation,
        readById(allocator, io, home, id),
    );
    try std.testing.expect(!try catalog.existsAt(io, custody, marker_name));
    try catalog.writeJson(allocator, io, custody, marker_name, Marker{
        .schema = "ledger-storage-root/v1",
        .store_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }, 4096);
    try std.testing.expectError(
        error.StorageRootIdentityMismatch,
        readById(allocator, io, home, id),
    );
    try custody.writeFile(io, .{ .sub_path = marker_name, .data = original });
    var verified = try host.list(allocator, io, home);
    defer verified.deinit();
    try std.testing.expectEqual(@as(usize, 1), verified.value.pending.len);
    try std.testing.expectEqualStrings(id, verified.value.pending[0].registration.store_id);
    try std.testing.expect(!verified.value.storage_mutated);
    try testUnrelatedPendingRoot(&environment, tmp.dir, root, home, id);
}

fn testUnrelatedPendingRoot(
    environment: *const std.process.Environ.Map,
    directory: std.Io.Dir,
    root: []const u8,
    home: []const u8,
    id: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try directory.createDir(io, "other", .default_dir);
    const other_workspace = try std.fs.path.join(allocator, &.{ root, "other" });
    defer allocator.free(other_workspace);
    var other = try prepareTarget(
        allocator,
        io,
        environment,
        .{ .catalog_root = home, .workspace = other_workspace },
        true,
    );
    defer other.deinit();
    const other_custody = try catalog.openDirectory(io, other.context.value.store_root, false);
    defer other_custody.close(io);
    try other_custody.deleteDir(io, ".ledger");
    var readable = try readById(allocator, io, home, id);
    defer readable.deinit();
    try std.testing.expectEqualStrings(id, readable.value.store_id);
    try std.testing.expect(!readable.value.cataloged);
    try std.testing.expectError(error.StorageRootMissing, host.list(allocator, io, home));
}

pub fn migrationScratch(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    selected: host.ContextValue,
    guard: *const Guard,
    source_sha256: ?[]const u8,
) !migration_copy.Scratch {
    _ = guard;
    const controls_path = try controlsPath(
        allocator,
        associations.workspace_root.?,
        associations.git_common_dir,
        home,
    );
    defer allocator.free(controls_path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const locator = try std.fs.path.join(
        arena.allocator(),
        &.{ controls_path, "registration.json" },
    );
    const value = try readPendingRegistration(arena.allocator(), io, associations, home, locator);
    if (!std.mem.eql(u8, value.store_id, selected.store_id) or
        !std.mem.eql(u8, value.store_root, selected.store_root))
        return error.PendingCustodyConflictsWithCatalog;
    var checked = try host.checkedRoot(
        allocator,
        io,
        value.store_root,
        value.store_id,
        associations.workspace_root,
        associations.git_common_dir,
        false,
        selected.cataloged,
    );
    defer checked.deinit();
    const root = try catalog.openDirectory(io, checked.value.store_root, false);
    defer root.close(io);
    const controls = try catalog.openDirectory(io, controls_path, false);
    defer controls.close(io);
    try declareMigrationCopy(allocator, io, controls, root, value, source_sha256);
    return migration_copy.Scratch.open(io, root);
}

pub fn migrationCopyMatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    selected: host.ContextValue,
    source_sha256: []const u8,
) !bool {
    const controls = try controlsPath(
        allocator,
        associations.workspace_root.?,
        associations.git_common_dir,
        home,
    );
    defer allocator.free(controls);
    const path = try std.fs.path.join(allocator, &.{ controls, migration_copy_name });
    defer allocator.free(path);
    if (!try catalog.exists(io, path)) return false;
    var parsed = try catalog.readJson(MigrationCopy, allocator, io, path, 4096);
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.schema, migration_copy_schema) or
        !std.mem.eql(u8, value.store_id, selected.store_id) or
        !std.mem.eql(u8, value.store_root, selected.store_root))
        return error.InvalidMigrationCopy;
    const admitted = value.source_sha256 orelse return false;
    return std.mem.eql(u8, admitted, source_sha256);
}

pub fn retireMigrationCopy(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    selected: host.ContextValue,
    guard: *const Guard,
) !bool {
    _ = guard;
    const controls_path = try controlsPath(
        allocator,
        associations.workspace_root.?,
        associations.git_common_dir,
        home,
    );
    defer allocator.free(controls_path);
    const controls = catalog.openDirectory(io, controls_path, false) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer controls.close(io);
    if (!try catalog.existsAt(io, controls, migration_copy_name)) {
        try catalog.sync(io, controls);
        return false;
    }
    const bytes = try catalog.readBytes(allocator, io, controls, migration_copy_name, 4096);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(MigrationCopy, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.schema, migration_copy_schema) or
        !std.mem.eql(u8, value.store_id, selected.store_id) or
        !std.mem.eql(u8, value.store_root, selected.store_root))
        return error.InvalidMigrationCopy;
    const control = try catalog.checkedRoot(allocator, io, selected.store_root, selected.store_id);
    defer control.close(io);
    const root = try catalog.openDirectory(io, selected.store_root, false);
    defer root.close(io);
    const anchored = try root.openDir(io, ".ledger", .{ .follow_symlinks = false });
    defer anchored.close(io);
    if (!try @import("durable_store").sameDirectoryObject(io, control, anchored))
        return error.StorageRootChanged;
    if (try catalog.existsAt(io, root, migration_copy.directory_name)) {
        const dir = try root.openDir(io, migration_copy.directory_name, .{
            .follow_symlinks = false,
            .iterate = true,
        });
        defer dir.close(io);
        const scratch: migration_copy.Scratch = .{ .dir = dir };
        try scratch.clear(io);
        try catalog.sync(io, dir);
        try root.deleteDir(io, migration_copy.directory_name);
    }
    try catalog.sync(io, root);
    try controls.deleteFile(io, migration_copy_name);
    try catalog.sync(io, controls);
    return true;
}

pub fn archiveScratch(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    selected: host.ContextValue,
    guard: *const Guard,
) !migration_archive.Scratch {
    _ = guard;
    try checkPendingContext(allocator, io, associations, home, selected);
    try archiveIdentity(allocator, io, associations, home, selected);
    const control = try catalog.checkedRoot(allocator, io, selected.store_root, selected.store_id);
    defer control.close(io);
    const root = try catalog.openDirectory(io, selected.store_root, false);
    defer root.close(io);
    const path = try controlsPath(
        allocator,
        associations.workspace_root.?,
        associations.git_common_dir,
        home,
    );
    defer allocator.free(path);
    const controls = try catalog.openDirectory(io, path, true);
    defer controls.close(io);
    return migration_archive.Scratch.open(
        allocator,
        io,
        controls,
        root,
        selected.store_id,
        selected.store_root,
    );
}

fn archiveIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    selected: host.ContextValue,
) !void {
    var registered = try catalog.read(allocator, io, home);
    defer registered.deinit();
    if (registered.value.stores.map.get(selected.store_id)) |path| {
        if (!std.mem.eql(u8, path, selected.store_root))
            return error.PendingCustodyConflictsWithCatalog;
        _ = try registered.select(associations.aliases, selected.store_id, false);
        return;
    }
    if (associations.git_common_dir) |common| {
        const path = try std.fs.path.join(allocator, &.{ common, catalog.registration_name });
        defer allocator.free(path);
        if (try catalog.exists(io, path)) {
            var registration = try host.readRegistration(allocator, io, path);
            defer registration.deinit();
            if (!std.mem.eql(u8, registration.value.store_root, selected.store_root) or
                !std.mem.eql(u8, registration.value.store_id, selected.store_id))
                return error.ConflictingLegacyRegistration;
            return;
        }
    }
    const path = try controlsPath(
        allocator,
        associations.workspace_root.?,
        associations.git_common_dir,
        home,
    );
    defer allocator.free(path);
    var pending = try pendingTarget(allocator, io, associations, home, path, false);
    defer pending.deinit();
    if (!std.mem.eql(u8, pending.value.store_root, selected.store_root) or
        !std.mem.eql(u8, pending.value.store_id, selected.store_id))
        return error.PendingCustodyConflictsWithCatalog;
}

fn declareMigrationCopy(
    allocator: std.mem.Allocator,
    io: std.Io,
    controls: std.Io.Dir,
    root: std.Io.Dir,
    registration: Registration,
    source_sha256: ?[]const u8,
) !void {
    const expected: MigrationCopy = .{
        .schema = migration_copy_schema,
        .store_id = registration.store_id,
        .store_root = registration.store_root,
        .source_sha256 = source_sha256,
    };
    if (try catalog.existsAt(io, controls, migration_copy_name)) {
        const bytes = try catalog.readBytes(allocator, io, controls, migration_copy_name, 4096);
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(MigrationCopy, allocator, bytes, .{
            .duplicate_field_behavior = .@"error",
        });
        defer parsed.deinit();
        const value = parsed.value;
        if (!std.mem.eql(u8, value.schema, expected.schema) or
            !std.mem.eql(u8, value.store_id, expected.store_id) or
            !std.mem.eql(u8, value.store_root, expected.store_root) or
            !catalog.optionalEqual(value.source_sha256, expected.source_sha256))
            return error.InvalidMigrationCopy;
    } else {
        if (try catalog.existsAt(io, root, migration_copy.directory_name))
            return error.UndeclaredMigrationScratch;
        try catalog.writeJson(allocator, io, controls, migration_copy_name, expected, 4096);
    }
    const declaration = try controls.openFile(io, migration_copy_name, .{
        .follow_symlinks = false,
    });
    defer declaration.close(io);
    try declaration.sync(io);
    try catalog.sync(io, controls);
}

pub const Guard = struct {
    dir: std.Io.Dir,
    file: std.Io.File,
    io: std.Io,

    pub fn acquire(io: std.Io, path: []const u8) !Guard {
        const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
        const dir = try catalog.openDirectory(io, parent, true);
        errdefer dir.close(io);
        const basename = std.fs.path.basename(path);
        const file = try catalog.openLock(io, dir, basename);
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.nlink != 1) return error.InvalidRegistrationLock;
        catalog.lockExclusive(io, file) catch |err| switch (err) {
            error.LockBusy => return error.RegistrationLockBusy,
            else => return err,
        };
        return .{ .dir = dir, .file = file, .io = io };
    }

    pub fn deinit(self: *Guard) void {
        self.file.close(self.io);
        self.dir.close(self.io);
        self.* = undefined;
    }
};

pub const Target = struct {
    context: host.Context,
    guard: ?Guard,

    pub fn deinit(self: *Target) void {
        self.context.deinit();
        if (self.guard) |*guard| guard.deinit();
        self.* = undefined;
    }
};

pub fn controlsPath(
    allocator: std.mem.Allocator,
    root: []const u8,
    common: ?[]const u8,
    home: []const u8,
) ![]u8 {
    const identity = if (common) |path|
        try std.json.Stringify.valueAlloc(allocator, .{ .git_common_dir = path }, .{})
    else
        try std.json.Stringify.valueAlloc(allocator, .{ .workspace_root = root }, .{});
    defer allocator.free(identity);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(identity, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fs.path.join(allocator, &.{ home, "preparations", &hex });
}

pub fn prepareTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: host.Options,
    apply: bool,
) !Target {
    var associations = try workspace.resolve(allocator, io, environment, options.workspace);
    defer associations.deinit();
    const root = associations.workspace_root orelse return error.PreparationRequiresWorkspace;
    if (!try workspace.isDirectory(io, root)) return error.NewWorkspaceRequiresExistingDirectory;
    if (host.resolve(allocator, io, environment, options)) |selected| {
        var current = selected;
        errdefer current.deinit();
        try checkPendingContext(allocator, io, &associations, options.catalog_root, current.value);
        return .{ .context = current, .guard = null };
    } else |err| switch (err) {
        error.UnregisteredContext => {},
        else => return err,
    }
    if (associations.git_common_dir) |common| {
        const registration = try std.fs.path.join(
            allocator,
            &.{ common, catalog.registration_name },
        );
        defer allocator.free(registration);
        if (try catalog.exists(io, registration)) return error.ExistingRegistrationRequiresImport;
    }
    const controls = try controlsPath(
        allocator,
        root,
        associations.git_common_dir,
        options.catalog_root,
    );
    defer allocator.free(controls);
    if (!apply) return .{
        .context = try pendingTarget(
            allocator,
            io,
            &associations,
            options.catalog_root,
            controls,
            false,
        ),
        .guard = null,
    };
    const control_dir = try catalog.openDirectory(io, controls, true);
    control_dir.close(io);
    const lock_path = try std.fs.path.join(
        allocator,
        &.{ associations.git_common_dir orelse controls, "ledger-store.lock" },
    );
    defer allocator.free(lock_path);
    var guard = try Guard.acquire(io, lock_path);
    errdefer guard.deinit();
    var resolved = host.resolve(allocator, io, environment, options) catch |err| switch (err) {
        error.UnregisteredContext => try pendingTarget(
            allocator,
            io,
            &associations,
            options.catalog_root,
            controls,
            true,
        ),
        else => return err,
    };
    errdefer resolved.deinit();
    try checkPendingContext(allocator, io, &associations, options.catalog_root, resolved.value);
    return .{ .context = resolved, .guard = guard };
}

pub fn checkPendingContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    selected: host.ContextValue,
) !void {
    return admitPendingContext(allocator, io, associations, home, selected, null);
}

pub fn syncPendingContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    selected: host.ContextValue,
    lock: *const catalog.Lock,
) !void {
    return admitPendingContext(allocator, io, associations, home, selected, lock);
}

fn admitPendingContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    selected: host.ContextValue,
    lock: ?*const catalog.Lock,
) !void {
    const root = associations.workspace_root orelse return;
    const controls = try controlsPath(allocator, root, associations.git_common_dir, home);
    defer allocator.free(controls);
    const locator = try std.fs.path.join(allocator, &.{ controls, "registration.json" });
    defer allocator.free(locator);
    if (!try catalog.exists(io, locator)) return;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try readPendingRegistration(arena.allocator(), io, associations, home, locator);
    if (!std.mem.eql(u8, value.store_id, selected.store_id) or
        !std.mem.eql(u8, value.store_root, selected.store_root))
    {
        return error.PendingCustodyConflictsWithCatalog;
    }
    if (lock != null) try syncRegistration(io, controls);
    var pending = try materializePending(
        allocator,
        io,
        associations,
        value,
        controls,
        lock,
        selected.cataloged,
    );
    defer pending.deinit();
}

fn validRegistration(allocator: std.mem.Allocator, value: Registration, home: []const u8) !void {
    if (!std.mem.eql(
        u8,
        value.schema,
        catalog.registration_schema,
    )) return error.InvalidPendingIdentity;
    try catalog.validStoreId(value.store_id);
    if (!std.fs.path.isAbsolute(value.workspace_root)) return error.InvalidPendingIdentity;
    if (value.git_common_dir) |common| {
        if (!std.fs.path.isAbsolute(common)) return error.InvalidPendingIdentity;
    }
    const expected = try std.fs.path.join(allocator, &.{ home, "repos", value.store_id });
    defer allocator.free(expected);
    if (!std.mem.eql(u8, value.store_root, expected)) return error.InvalidPendingTarget;
}

pub fn rejectUnregisteredCustody(
    allocator: std.mem.Allocator,
    lock: *const catalog.Lock,
    root: ?[]const u8,
    common: ?[]const u8,
    home: []const u8,
) !void {
    const io = lock.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    var selected = try lock.read(owned);
    defer selected.deinit();
    var known: std.StringHashMap(void) = .init(owned);
    for (selected.value.stores.map.values()) |path| try known.put(path, {});
    if (try catalog.existsAt(io, lock.dir, "preparations")) {
        const controls = try lock.dir.openDir(
            io,
            "preparations",
            .{ .follow_symlinks = false, .iterate = true },
        );
        defer controls.close(io);
        var entries = controls.iterate();
        var count: usize = 0;
        while (try entries.next(io)) |entry| {
            if (count == max_sources) return error.PendingCustodyDiscoveryBoundExceeded;
            count += 1;
            const child = try controls.openDir(io, entry.name, .{ .follow_symlinks = false });
            defer child.close(io);
            if (!try catalog.existsAt(io, child, "registration.json")) continue;
            const bytes = try catalog.readBytes(owned, io, child, "registration.json", 4096);
            const value = try std.json.parseFromSliceLeaky(
                Registration,
                owned,
                bytes,
                .{ .duplicate_field_behavior = .@"error" },
            );
            try validRegistration(owned, value, home);
            if (root != null and std.mem.eql(u8, value.workspace_root, root.?) and
                !catalog.optionalEqual(value.git_common_dir, common))
            {
                return error.PendingWorkspaceGitIdentityChanged;
            }
            try known.put(value.store_root, {});
        }
    }
    const repos_path = try std.fs.path.join(owned, &.{ home, "repos" });
    if (try catalog.existsAt(io, lock.dir, "repos")) {
        const repos = try lock.dir.openDir(
            io,
            "repos",
            .{ .follow_symlinks = false, .iterate = true },
        );
        defer repos.close(io);
        var entries = repos.iterate();
        var count: usize = 0;
        while (try entries.next(io)) |entry| {
            if (count == max_sources) return error.CustodyDiscoveryBoundExceeded;
            count += 1;
            if (entry.kind == .sym_link) return error.SymlinkComponent;
            const path = try std.fs.path.join(owned, &.{ repos_path, entry.name });
            if (!known.contains(path)) return error.UnregisteredCustodyExists;
        }
    }
}

pub fn pendingTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    controls_path: []const u8,
    apply: bool,
) !host.Context {
    if (!apply) return pendingTargetObserved(
        allocator,
        io,
        associations,
        home,
        controls_path,
        null,
    );
    var lock = try catalog.Lock.acquire(io, home);
    defer lock.deinit();
    return pendingTargetLocked(allocator, io, associations, home, controls_path, &lock);
}

pub fn pendingTargetLocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    controls_path: []const u8,
    lock: *const catalog.Lock,
) !host.Context {
    return pendingTargetObserved(allocator, io, associations, home, controls_path, lock);
}

fn pendingTargetObserved(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    controls_path: []const u8,
    publication_lock: ?*const catalog.Lock,
) !host.Context {
    const root = associations.workspace_root orelse return error.PreparationRequiresWorkspace;
    var selected = if (publication_lock) |lock|
        try lock.read(allocator)
    else
        try catalog.read(allocator, io, home);
    defer selected.deinit();
    if (publication_lock != null) {
        if (try selected.select(associations.aliases, null, false)) |id| {
            return host.checkedRoot(
                allocator,
                io,
                selected.value.stores.map.get(id).?,
                id,
                root,
                associations.git_common_dir,
                false,
                true,
            );
        }
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const value = try pendingRegistration(
        owned,
        io,
        associations,
        home,
        controls_path,
        publication_lock,
    );
    return materializePending(
        allocator,
        io,
        associations,
        value,
        controls_path,
        publication_lock,
        try selected.containsStoreRoot(allocator, io, value.store_id, value.store_root),
    );
}

fn pendingRegistration(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    controls_path: []const u8,
    publication_lock: ?*const catalog.Lock,
) !Registration {
    const root = associations.workspace_root orelse return error.PreparationRequiresWorkspace;
    const locator_path = try std.fs.path.join(allocator, &.{ controls_path, "registration.json" });
    if (try catalog.exists(io, locator_path)) {
        const value = try readPendingRegistration(allocator, io, associations, home, locator_path);
        if (publication_lock != null) try syncRegistration(io, controls_path);
        return value;
    }
    const lock = publication_lock orelse return error.PendingInitializationRequiresPreparation;
    try rejectUnregisteredCustody(allocator, lock, root, associations.git_common_dir, home);
    const id = try allocator.dupe(u8, &(try host.newStoreId(io)));
    const value: Registration = .{
        .schema = catalog.registration_schema,
        .store_id = id,
        .store_root = try std.fs.path.join(allocator, &.{ home, "repos", id }),
        .workspace_root = root,
        .git_common_dir = associations.git_common_dir,
    };
    if (try catalog.exists(io, value.store_root)) return error.PendingTargetAlreadyExists;
    const controls = try catalog.openDirectory(io, controls_path, true);
    defer controls.close(io);
    try catalog.writeJson(allocator, io, controls, "registration.json", value, 4096);
    return value;
}

fn syncRegistration(io: std.Io, controls_path: []const u8) !void {
    const controls = try catalog.openDirectory(io, controls_path, true);
    defer controls.close(io);
    const locator = try controls.openFile(io, "registration.json", .{ .follow_symlinks = false });
    defer locator.close(io);
    const stat = try locator.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.InvalidPendingRegistration;
    try locator.sync(io);
    try catalog.sync(io, controls);
}

fn readPendingRegistration(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    path: []const u8,
) !Registration {
    var parsed = try catalog.readJson(Registration, allocator, io, path, 4096);
    defer parsed.deinit();
    try validRegistration(allocator, parsed.value, home);
    if (!catalog.optionalEqual(parsed.value.git_common_dir, associations.git_common_dir) or
        (associations.git_common_dir == null and
            !std.mem.eql(u8, parsed.value.workspace_root, associations.workspace_root.?)))
    {
        return error.ConflictingPendingIdentity;
    }
    return .{
        .schema = catalog.registration_schema,
        .store_id = try allocator.dupe(u8, parsed.value.store_id),
        .store_root = try allocator.dupe(u8, parsed.value.store_root),
        .workspace_root = try allocator.dupe(u8, parsed.value.workspace_root),
        .git_common_dir = if (parsed.value.git_common_dir) |common|
            try allocator.dupe(u8, common)
        else
            null,
    };
}

fn materializePending(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    value: Registration,
    controls_path: []const u8,
    publication_lock: ?*const catalog.Lock,
    cataloged: bool,
) !host.Context {
    const marker_path = try std.fs.path.join(allocator, &.{ value.store_root, marker_name });
    defer allocator.free(marker_path);
    if (try catalog.exists(io, marker_path)) {
        var checked = try host.checkedRoot(
            allocator,
            io,
            value.store_root,
            value.store_id,
            associations.workspace_root,
            associations.git_common_dir,
            false,
            cataloged,
        );
        errdefer checked.deinit();
        if (publication_lock != null) try syncPending(io, value.store_root, controls_path);
        return checked;
    }
    if (publication_lock == null) return error.PendingInitializationRequiresPreparation;
    try checkSkeleton(io, value.store_root);
    const custody = try catalog.openDirectory(io, value.store_root, true);
    defer custody.close(io);
    custody.createDir(io, ".ledger", .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try checkSkeleton(io, value.store_root);
    const controls = try catalog.openDirectory(io, controls_path, false);
    defer controls.close(io);
    try prepareMarker(allocator, io, controls, value.store_id);
    try controls.renamePreserve(candidate_name, custody, marker_name, io);
    try syncPending(io, value.store_root, controls_path);
    return host.checkedRoot(
        allocator,
        io,
        value.store_root,
        value.store_id,
        associations.workspace_root,
        associations.git_common_dir,
        true,
        cataloged,
    );
}

fn syncPending(io: std.Io, root: []const u8, controls_path: []const u8) !void {
    const controls = try catalog.openDirectory(io, controls_path, false);
    defer controls.close(io);
    try catalog.sync(io, controls);
    const custody = try catalog.openDirectory(io, root, false);
    defer custody.close(io);
    const marker = try custody.openFile(io, marker_name, .{ .follow_symlinks = false });
    defer marker.close(io);
    const stat = try marker.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.InvalidPendingMarker;
    try marker.sync(io);
    const control = try custody.openDir(io, ".ledger", .{ .follow_symlinks = false });
    defer control.close(io);
    try catalog.sync(io, control);
    try catalog.sync(io, custody);
    const repos_path = std.fs.path.dirname(root).?;
    const repos = try catalog.openDirectory(io, repos_path, false);
    defer repos.close(io);
    try catalog.sync(io, repos);
    const home = try catalog.openDirectory(io, std.fs.path.dirname(repos_path).?, false);
    defer home.close(io);
    try catalog.sync(io, home);
}

fn checkSkeleton(io: std.Io, root: []const u8) !void {
    const custody = catalog.openDirectory(io, root, false) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer custody.close(io);
    var entries = custody.iterate();
    while (try entries.next(io)) |entry| {
        if (!std.mem.eql(u8, entry.name, ".ledger")) return error.UnverifiedPendingFiles;
        const control = try custody.openDir(
            io,
            ".ledger",
            .{ .follow_symlinks = false, .iterate = true },
        );
        defer control.close(io);
        var files = control.iterate();
        if (try files.next(io) != null) return error.UnverifiedPendingControlData;
    }
}

fn prepareMarker(
    allocator: std.mem.Allocator,
    io: std.Io,
    controls: std.Io.Dir,
    id: []const u8,
) !void {
    const marker: Marker = .{ .schema = "ledger-storage-root/v1", .store_id = id };
    const file = controls.createFile(
        io,
        candidate_name,
        .{ .exclusive = true, .permissions = .fromMode(0o600) },
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const bytes = try catalog.readBytes(allocator, io, controls, candidate_name, 4096);
            defer allocator.free(bytes);
            var parsed = try std.json.parseFromSlice(
                Marker,
                allocator,
                bytes,
                .{ .duplicate_field_behavior = .@"error" },
            );
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.schema, marker.schema) or
                !std.mem.eql(u8, parsed.value.store_id, id))
            {
                return error.ConflictingPendingMarker;
            }
            const existing = try controls.openFile(
                io,
                candidate_name,
                .{ .follow_symlinks = false },
            );
            defer existing.close(io);
            try existing.sync(io);
            return;
        },
        else => return err,
    };
    defer file.close(io);
    const created = try file.stat(io);
    errdefer discardMarkerCandidate(io, controls, created.inode);
    const bytes = try std.json.Stringify.valueAlloc(allocator, marker, .{});
    defer allocator.free(bytes);
    try file.writeStreamingAll(io, bytes);
    try file.writeStreamingAll(io, "\n");
    try file.sync(io);
}

fn discardMarkerCandidate(io: std.Io, controls: std.Io.Dir, inode: std.Io.File.INode) void {
    const current = controls.statFile(io, candidate_name, .{ .follow_symlinks = false }) catch |err|
        switch (err) {
            error.FileNotFound => return,
            else => {
                std.log.warn("pending marker cleanup inspection failed: {s}", .{@errorName(err)});
                return;
            },
        };
    if (current.inode != inode or current.kind != .file) return;
    controls.deleteFile(io, candidate_name) catch |err| {
        std.log.warn("pending marker cleanup failed: {s}", .{@errorName(err)});
        return;
    };
    catalog.sync(io, controls) catch |err| {
        std.log.warn("pending marker cleanup sync failed: {s}", .{@errorName(err)});
    };
}

const MigrationScratchTest = struct {
    associations: *const workspace.Associations,
    home: []const u8,
    context: host.ContextValue,
    guard: *const Guard,

    fn acquire(self: MigrationScratchTest, io: std.Io) !migration_copy.Scratch {
        return migrationScratch(
            std.testing.allocator,
            io,
            self.associations,
            self.home,
            self.context,
            self.guard,
            null,
        );
    }
};

test "pending migration scratch owns only its declared fixed layout across retries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", owned);
    const home = try std.fs.path.join(owned, &.{ root, "home" });
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const options: host.Options = .{ .catalog_root = home, .workspace = root };
    var target = try prepareTarget(allocator, io, &environment, options, true);
    defer target.deinit();
    var associations = try workspace.resolve(allocator, io, &environment, root);
    defer associations.deinit();
    const context = target.context.value;
    const fixture: MigrationScratchTest = .{
        .associations = &associations,
        .home = home,
        .context = context,
        .guard = &target.guard.?,
    };
    const custody = try catalog.openDirectory(io, context.store_root, false);
    defer custody.close(io);
    try custody.createDir(io, migration_copy.directory_name, .fromMode(0o700));
    try std.testing.expectError(error.UndeclaredMigrationScratch, fixture.acquire(io));
    try custody.deleteDir(io, migration_copy.directory_name);
    const scratch = try fixture.acquire(io);
    defer scratch.deinit(io);
    const controls = try controlsPath(owned, root, null, home);
    const locator = try std.fs.path.join(owned, &.{ controls, "registration.json" });
    const value = try readPendingRegistration(owned, io, &associations, home, locator);
    try std.testing.expectEqualStrings(context.store_id, value.store_id);
    try scratch.dir.writeFile(io, .{ .sub_path = "payload", .data = "partial" });
    const retry = try fixture.acquire(io);
    defer retry.deinit(io);
    try std.testing.expect(!try catalog.existsAt(io, retry.dir, "payload"));
    try scratch.dir.writeFile(io, .{ .sub_path = "foreign", .data = "retain" });
    try std.testing.expectError(error.UnknownMigrationScratch, fixture.acquire(io));
    try std.testing.expect(try catalog.existsAt(io, scratch.dir, "foreign"));
}

test "pending migration scratch declaration rejects other versions and identities" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    const registration: Registration = .{
        .schema = catalog.registration_schema,
        .store_id = "id",
        .store_root = "/root",
        .workspace_root = "/workspace",
        .git_common_dir = null,
    };
    for (0..3) |field| {
        try catalog.writeJson(allocator, io, tmp.dir, migration_copy_name, MigrationCopy{
            .schema = if (field == 0) "ledger-migration-copy/v2" else migration_copy_schema,
            .store_id = if (field == 1) "foreign" else registration.store_id,
            .store_root = if (field == 2) "/foreign" else registration.store_root,
        }, 4096);
        try std.testing.expectError(
            error.InvalidMigrationCopy,
            declareMigrationCopy(allocator, io, tmp.dir, tmp.dir, registration, null),
        );
        try std.testing.expect(!try catalog.existsAt(io, tmp.dir, migration_copy.directory_name));
    }
}

test "pending migration declaration failure creates no scratch and retry reuses identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", owned);
    const home = try std.fs.path.join(owned, &.{ root, "home" });
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var target = try prepareTarget(
        allocator,
        io,
        &environment,
        .{ .catalog_root = home, .workspace = root },
        true,
    );
    defer target.deinit();
    var associations = try workspace.resolve(allocator, io, &environment, root);
    defer associations.deinit();
    const fixture: MigrationScratchTest = .{
        .associations = &associations,
        .home = home,
        .context = target.context.value,
        .guard = &target.guard.?,
    };
    const custody = try catalog.openDirectory(io, target.context.value.store_root, false);
    defer custody.close(io);
    var vtable = io.vtable.*;
    vtable.dirRename = struct {
        fn rename(
            userdata: ?*anyopaque,
            from: std.Io.Dir,
            name: []const u8,
            to: std.Io.Dir,
            leaf: []const u8,
        ) std.Io.Dir.RenameError!void {
            try std.testing.io.vtable.dirRename(userdata, from, name, to, leaf);
            if (std.mem.eql(u8, leaf, migration_copy_name)) return error.HardwareFailure;
        }
    }.rename;
    var injected = io;
    injected.vtable = &vtable;
    try std.testing.expectError(error.HardwareFailure, fixture.acquire(injected));
    try std.testing.expect(!try catalog.existsAt(io, custody, migration_copy.directory_name));
    const scratch = try fixture.acquire(io);
    defer scratch.deinit(io);
    const controls = try controlsPath(owned, root, null, home);
    const locator = try std.fs.path.join(owned, &.{ controls, "registration.json" });
    const registration = try readPendingRegistration(owned, io, &associations, home, locator);
    try std.testing.expectEqualStrings(target.context.value.store_id, registration.store_id);
}

test "pending target persists identity across preparation retries and does not publish catalog" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const options: host.Options = .{ .catalog_root = home, .workspace = root };
    var first = try prepareTarget(allocator, io, &environment, options, true);
    const id = try allocator.dupe(u8, first.context.value.store_id);
    defer allocator.free(id);
    first.deinit();
    var second = try prepareTarget(allocator, io, &environment, options, false);
    defer second.deinit();
    try std.testing.expectEqualStrings(id, second.context.value.store_id);
    try std.testing.expect(!second.context.value.storage_mutated);
    try std.testing.expectError(
        error.UnregisteredContext,
        host.resolve(allocator, io, &environment, options),
    );
    var published = try host.registerRoot(
        allocator,
        io,
        &environment,
        options,
        second.context.value.store_root,
        id,
    );
    defer published.deinit();
    try std.testing.expect(published.value.storage_mutated);
}

test "pending target observes catalog membership without workspace aliases" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const options: host.Options = .{ .catalog_root = home, .workspace = root };
    var first = try prepareTarget(allocator, io, &environment, options, true);
    const id = try allocator.dupe(u8, first.context.value.store_id);
    defer allocator.free(id);
    const custody = try allocator.dupe(u8, first.context.value.store_root);
    defer allocator.free(custody);
    try std.testing.expect(!first.context.value.cataloged);
    first.deinit();
    var published = try host.registerRoot(
        allocator,
        io,
        &environment,
        .{ .catalog_root = home, .store_id = id },
        custody,
        id,
    );
    defer published.deinit();
    try std.testing.expect(published.value.cataloged);
    try std.testing.expectError(error.UnregisteredContext, host.resolve(
        allocator,
        io,
        &environment,
        options,
    ));
    for ([_]bool{ false, true }) |apply| {
        var retry = try prepareTarget(allocator, io, &environment, options, apply);
        defer retry.deinit();
        try std.testing.expectEqualStrings(id, retry.context.value.store_id);
        try std.testing.expectEqualStrings(custody, retry.context.value.store_root);
        try std.testing.expect(retry.context.value.cataloged);
        try std.testing.expect(!retry.context.value.storage_mutated);
    }
}

test "pending target refuses foreign skeleton data and retains locator identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const options: host.Options = .{ .catalog_root = home, .workspace = root };
    var first = try prepareTarget(allocator, io, &environment, options, true);
    const custody = try allocator.dupe(u8, first.context.value.store_root);
    defer allocator.free(custody);
    first.deinit();
    const dir = try catalog.openDirectory(io, custody, false);
    defer dir.close(io);
    try dir.deleteFile(io, marker_name);
    try dir.writeFile(io, .{ .sub_path = ".ledger/foreign", .data = "preserve" });
    try std.testing.expectError(
        error.UnverifiedPendingControlData,
        prepareTarget(allocator, io, &environment, options, true),
    );
    try std.testing.expect(try catalog.existsAt(io, dir, ".ledger/foreign"));
}

test "pending bootstrap resumes durable locator root and control boundaries with one identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for (0..3) |boundary| {
        var tmp = try workspace.testPlainDirectory();
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        const home = try std.fs.path.join(allocator, &.{ root, "home" });
        defer allocator.free(home);
        const controls_path = try controlsPath(allocator, root, null, home);
        defer allocator.free(controls_path);
        const controls = try catalog.openDirectory(io, controls_path, true);
        defer controls.close(io);
        const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        const target_path = try std.fs.path.join(allocator, &.{ home, "repos", id });
        defer allocator.free(target_path);
        try catalog.writeJson(allocator, io, controls, "registration.json", Registration{
            .schema = catalog.registration_schema,
            .store_id = id,
            .store_root = target_path,
            .workspace_root = root,
            .git_common_dir = null,
        }, 4096);
        if (boundary > 0) {
            const target = try catalog.openDirectory(io, target_path, true);
            defer target.close(io);
            if (boundary > 1) try target.createDir(io, ".ledger", .fromMode(0o700));
        }
        var environment = std.process.Environ.Map.init(allocator);
        defer environment.deinit();
        const options: host.Options = .{ .catalog_root = home, .workspace = root };
        const before = try catalog.readBytes(allocator, io, controls, "registration.json", 4096);
        defer allocator.free(before);
        try std.testing.expectError(error.PendingInitializationRequiresPreparation, prepareTarget(
            allocator,
            io,
            &environment,
            options,
            false,
        ));
        var resumed = try prepareTarget(allocator, io, &environment, options, true);
        defer resumed.deinit();
        try std.testing.expectEqualStrings(id, resumed.context.value.store_id);
        const after = try catalog.readBytes(allocator, io, controls, "registration.json", 4096);
        defer allocator.free(after);
        try std.testing.expectEqualStrings(before, after);
    }
}

test "pending matching marker candidate keeps its inode and malformed candidate survives failure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try tmp.dir.writeFile(io, .{ .sub_path = candidate_name, .data = "{partial" });
    if (prepareMarker(allocator, io, tmp.dir, id)) |_| return error.TestExpectedError else |_| {}
    const retained_bytes = try catalog.readBytes(allocator, io, tmp.dir, candidate_name, 4096);
    defer allocator.free(retained_bytes);
    try std.testing.expectEqualStrings("{partial", retained_bytes);
    try tmp.dir.deleteFile(io, candidate_name);
    try catalog.writeJson(allocator, io, tmp.dir, candidate_name, Marker{
        .schema = "ledger-storage-root/v1",
        .store_id = id,
    }, 4096);
    const before = try tmp.dir.statFile(io, candidate_name, .{ .follow_symlinks = false });
    try prepareMarker(allocator, io, tmp.dir, id);
    try tmp.dir.renamePreserve(candidate_name, tmp.dir, marker_name, io);
    const after = try tmp.dir.statFile(io, marker_name, .{ .follow_symlinks = false });
    try std.testing.expectEqual(before.inode, after.inode);
}

test "pending identity prevents replacement initialization without holding catalog custody" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    const other = try std.fs.path.join(allocator, &.{ root, "other" });
    defer allocator.free(other);
    try tmp.dir.createDir(io, "other", .fromMode(0o700));
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const options: host.Options = .{ .catalog_root = home, .workspace = root };
    var pending = try prepareTarget(allocator, io, &environment, options, true);
    defer pending.deinit();
    try std.testing.expectError(error.PendingInitializationRequiresPreparation, host.initialize(
        allocator,
        io,
        &environment,
        options,
    ));
    var unrelated = try host.initialize(
        allocator,
        io,
        &environment,
        .{ .catalog_root = home, .workspace = other },
    );
    defer unrelated.deinit();
    try std.testing.expect(!std.mem.eql(
        u8,
        pending.context.value.store_id,
        unrelated.value.store_id,
    ));
    var resumed = try prepareTarget(allocator, io, &environment, options, false);
    defer resumed.deinit();
    try std.testing.expectEqualStrings(
        pending.context.value.store_id,
        resumed.context.value.store_id,
    );
    var selected = try catalog.read(allocator, io, home);
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.value.stores.map.count());
    try std.testing.expect(!selected.value.stores.map.contains(pending.context.value.store_id));
}

const CatalogPublicationInterleaving = struct {
    var active: ?*CatalogPublicationInterleaving = null;

    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: host.Options,
    ready: std.Io.Event = .unset,
    worker: ?std.Thread = null,
    failure: ?anyerror = null,
    store_id: [32]u8 = undefined,
    waited_for_catalog: bool = false,

    fn prepare(self: *CatalogPublicationInterleaving) void {
        defer self.ready.set(self.io);
        var vtable = self.io.vtable.*;
        vtable.fileTryLock = waitForCatalog;
        var injected = self.io;
        injected.vtable = &vtable;
        var target = prepareTarget(
            std.heap.page_allocator,
            injected,
            self.environment,
            self.options,
            true,
        ) catch |err| {
            self.failure = err;
            return;
        };
        defer target.deinit();
        @memcpy(&self.store_id, target.context.value.store_id);
    }

    fn waitForCatalog(
        userdata: ?*anyopaque,
        file: std.Io.File,
        mode: std.Io.File.Lock,
    ) std.Io.File.LockError!bool {
        const self = active.?;
        const acquired = try self.io.vtable.fileTryLock(userdata, file, mode);
        if (!acquired) {
            self.waited_for_catalog = true;
            self.ready.set(self.io);
        }
        return acquired;
    }

    fn rename(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_name: []const u8,
        new_dir: std.Io.Dir,
        new_name: []const u8,
    ) std.Io.Dir.RenameError!void {
        const self = active.?;
        try self.io.vtable.dirRename(userdata, old_dir, old_name, new_dir, new_name);
        if (self.worker == null and std.mem.eql(u8, new_name, marker_name)) {
            self.worker = std.Thread.spawn(.{}, prepare, .{self}) catch |err| {
                std.debug.panic("catalog interleaving worker failed: {s}", .{@errorName(err)});
            };
            self.ready.waitUncancelable(self.io);
        }
    }
};

test "pending target waits for catalog publication and reuses its initialized identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const options: host.Options = .{ .catalog_root = home, .workspace = root };
    var interleaving: CatalogPublicationInterleaving = .{
        .io = io,
        .environment = &environment,
        .options = options,
    };
    CatalogPublicationInterleaving.active = &interleaving;
    defer CatalogPublicationInterleaving.active = null;
    defer if (interleaving.worker) |worker| worker.join();
    var vtable = io.vtable.*;
    vtable.dirRename = CatalogPublicationInterleaving.rename;
    var injected = io;
    injected.vtable = &vtable;
    var initialized = try host.initialize(allocator, injected, &environment, options);
    defer initialized.deinit();
    const worker = interleaving.worker orelse return error.TestExpectedWorker;
    worker.join();
    interleaving.worker = null;
    if (interleaving.failure) |err| return err;
    try std.testing.expect(interleaving.waited_for_catalog);
    try std.testing.expectEqualStrings(initialized.value.store_id, &interleaving.store_id);
    var selected = try catalog.read(allocator, io, home);
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.value.stores.map.count());
}

const PendingSyncFault = struct {
    const Kind = enum { registration, marker };
    var kind: Kind = .registration;
    var renamed = false;
    var fail = true;
    var reached = false;
    var calls: usize = 0;
    var mask: u8 = 0;
    var last_file: ?std.Io.File = null;
    var last_bit: u8 = 0;
    var root: []const u8 = "";
    var controls: []const u8 = "";
    var fail_bit: u8 = 0;

    fn install(vtable: *std.Io.VTable, selected: Kind, failing: bool) void {
        kind = selected;
        renamed = false;
        fail = failing;
        reached = false;
        calls = 0;
        mask = 0;
        fail_bit = 0;
        last_file = null;
        last_bit = 0;
        vtable.dirRename = rename;
        vtable.dirRenamePreserve = renamePreserve;
        vtable.dirOpenFile = open;
        vtable.fileSync = sync;
    }

    fn rename(
        userdata: ?*anyopaque,
        from: std.Io.Dir,
        name: []const u8,
        to: std.Io.Dir,
        leaf: []const u8,
    ) std.Io.Dir.RenameError!void {
        try std.testing.io.vtable.dirRename(userdata, from, name, to, leaf);
        if (kind == .registration and std.mem.eql(u8, leaf, "registration.json")) renamed = true;
    }

    fn renamePreserve(
        userdata: ?*anyopaque,
        from: std.Io.Dir,
        name: []const u8,
        to: std.Io.Dir,
        leaf: []const u8,
    ) std.Io.Dir.RenamePreserveError!void {
        try std.testing.io.vtable.dirRenamePreserve(userdata, from, name, to, leaf);
        if (kind == .marker and std.mem.eql(u8, leaf, marker_name)) renamed = true;
    }

    fn open(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        name: []const u8,
        options: std.Io.Dir.OpenFileOptions,
    ) std.Io.File.OpenError!std.Io.File {
        const file = try std.testing.io.vtable.dirOpenFile(userdata, dir, name, options);
        last_file = file;
        last_bit = 0;
        if (std.mem.eql(u8, name, "registration.json")) last_bit = 1;
        if (std.mem.eql(u8, name, marker_name)) last_bit = 2;
        if (root.len == 0 or !std.mem.eql(u8, name, ".")) return file;
        const path = dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator) catch |err| {
            std.debug.panic("pending sync probe directory: {s}", .{@errorName(err)});
        };
        defer std.testing.allocator.free(path);
        if (std.mem.eql(u8, std.fs.path.basename(path), ".ledger")) last_bit = 4;
        if (std.mem.eql(u8, path, root)) last_bit = 8;
        if (std.mem.eql(u8, path, std.fs.path.dirname(root).?)) last_bit = 16;
        if (std.mem.eql(u8, path, controls)) last_bit = 32;
        const home = std.fs.path.dirname(std.fs.path.dirname(root).?).?;
        if (std.mem.eql(u8, path, home)) last_bit = 64;
        return file;
    }

    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        calls += 1;
        if (fail and renamed and (fail_bit == 0 or last_bit == fail_bit)) {
            reached = true;
            return error.InputOutput;
        }
        if (last_file != null and last_file.?.handle == file.handle) mask |= last_bit;
        return std.testing.io.vtable.fileSync(userdata, file);
    }
};

test "pending apply retries durability after locator and marker rename while inspect never syncs" {
    for (std.enums.values(PendingSyncFault.Kind)) |kind| try testPendingSyncRetry(kind);
}

fn testPendingSyncRetry(kind: PendingSyncFault.Kind) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", owned);
    const home = try std.fs.path.join(owned, &.{ root, "home" });
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const options: host.Options = .{ .catalog_root = home, .workspace = root };
    var vtable = io.vtable.*;
    PendingSyncFault.root = "";
    PendingSyncFault.install(&vtable, kind, true);
    var injected = io;
    injected.vtable = &vtable;
    try std.testing.expectError(error.InputOutput, prepareTarget(
        allocator,
        injected,
        &environment,
        options,
        true,
    ));
    try std.testing.expect(PendingSyncFault.reached);
    var associations = try workspace.resolve(allocator, io, &environment, root);
    defer associations.deinit();
    const controls = try controlsPath(owned, root, null, home);
    const path = try std.fs.path.join(owned, &.{ controls, "registration.json" });
    const registration = try readPendingRegistration(owned, io, &associations, home, path);
    const before = try catalog.readJson(std.json.Value, owned, io, path, 4096);
    try std.testing.expectEqual(@as(usize, 5), before.value.object.count());
    PendingSyncFault.install(&vtable, kind, false);
    if (prepareTarget(allocator, injected, &environment, options, false)) |value| {
        var observed = value;
        observed.deinit();
        try std.testing.expectEqual(PendingSyncFault.Kind.marker, kind);
    } else |err| {
        try std.testing.expectEqual(error.PendingInitializationRequiresPreparation, err);
        try std.testing.expectEqual(PendingSyncFault.Kind.registration, kind);
    }
    try std.testing.expectEqual(@as(usize, 0), PendingSyncFault.calls);
    PendingSyncFault.root = registration.store_root;
    PendingSyncFault.controls = controls;
    PendingSyncFault.install(&vtable, kind, false);
    var retry = try prepareTarget(allocator, injected, &environment, options, true);
    defer retry.deinit();
    try std.testing.expectEqualStrings(registration.store_id, retry.context.value.store_id);
    try std.testing.expectEqualStrings(registration.store_root, retry.context.value.store_root);
    try std.testing.expectEqual(@as(u8, 127), PendingSyncFault.mask);
    var selected = try catalog.read(allocator, io, home);
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 0), selected.value.stores.map.count());
    PendingSyncFault.root = "";
}

test "registration preserves pending identity and completes marker durability before association" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try workspace.testPlainDirectory();
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", owned);
    const home = try std.fs.path.join(owned, &.{ root, "home" });
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const options: host.Options = .{ .catalog_root = home, .workspace = root };
    var target = try prepareTarget(allocator, io, &environment, options, true);
    defer target.deinit();
    const selected = target.context.value;
    var other = try host.initialize(allocator, io, &environment, .{ .catalog_root = home });
    defer other.deinit();
    try std.testing.expectError(error.PendingCustodyConflictsWithCatalog, host.registerRoot(
        allocator,
        io,
        &environment,
        options,
        other.value.store_root,
        other.value.store_id,
    ));
    const before = try catalog.readBytes(owned, io, tmp.dir, "home/catalog.json", 65536);
    var vtable = io.vtable.*;
    PendingSyncFault.root = selected.store_root;
    PendingSyncFault.controls = try controlsPath(owned, root, null, home);
    defer PendingSyncFault.root = "";
    PendingSyncFault.install(&vtable, .marker, true);
    PendingSyncFault.renamed = true;
    PendingSyncFault.fail_bit = 2;
    var injected = io;
    injected.vtable = &vtable;
    try std.testing.expectError(error.InputOutput, host.registerRoot(
        allocator,
        injected,
        &environment,
        options,
        selected.store_root,
        selected.store_id,
    ));
    try std.testing.expect(PendingSyncFault.reached);
    const after = try catalog.readBytes(owned, io, tmp.dir, "home/catalog.json", 65536);
    try std.testing.expectEqualStrings(before, after);
    PendingSyncFault.install(&vtable, .marker, false);
    var registered = try host.registerRoot(
        allocator,
        injected,
        &environment,
        options,
        selected.store_root,
        selected.store_id,
    );
    defer registered.deinit();
    try std.testing.expectEqual(@as(u8, 127), PendingSyncFault.mask);
    try std.testing.expectEqualStrings(selected.store_id, registered.value.store_id);
    var resolved = try host.resolve(allocator, io, &environment, options);
    defer resolved.deinit();
    try std.testing.expectEqualStrings(selected.store_id, resolved.value.store_id);
}
