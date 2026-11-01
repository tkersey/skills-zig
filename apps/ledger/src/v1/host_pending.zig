const std = @import("std");
const host = @import("host_context.zig");
const catalog = host.catalog;
const workspace = host.workspace;
const migration_copy = @import("host_migration_copy.zig");

const max_sources = 128;
const marker_name = ".ledger-root.json";
const candidate_name = ".root-marker.json";
const Marker = struct { schema: []const u8, store_id: []const u8 };
const migration_copy_name = "migration-copy.json";
const migration_copy_schema = "ledger-migration-copy/v1";
const MigrationCopy = struct { schema: []const u8, store_id: []const u8, store_root: []const u8 };

pub const Registration = struct {
    schema: []const u8,
    store_id: []const u8,
    store_root: []const u8,
    workspace_root: []const u8,
    git_common_dir: ?[]const u8,
};

/// The declaration owns only a fixed scratch layout, never publication state.
/// The caller retains this guard until copying and scratch cleanup finish.
pub fn migrationScratch(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const workspace.Associations,
    home: []const u8,
    selected: host.ContextValue,
    guard: *const Guard,
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
    );
    defer checked.deinit();
    const root = try catalog.openDirectory(io, checked.value.store_root, false);
    defer root.close(io);
    const controls = try catalog.openDirectory(io, controls_path, false);
    defer controls.close(io);
    try declareMigrationCopy(allocator, io, controls, root, value);
    return migration_copy.Scratch.open(io, root);
}

fn declareMigrationCopy(
    allocator: std.mem.Allocator,
    io: std.Io,
    controls: std.Io.Dir,
    root: std.Io.Dir,
    registration: Registration,
) !void {
    const expected: MigrationCopy = .{
        .schema = migration_copy_schema,
        .store_id = registration.store_id,
        .store_root = registration.store_root,
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
            !std.mem.eql(u8, value.store_root, expected.store_root))
            return error.InvalidMigrationCopy;
    } else {
        if (try catalog.existsAt(io, root, migration_copy.directory_name))
            return error.UndeclaredMigrationScratch;
        try catalog.writeJson(allocator, io, controls, migration_copy_name, expected, 4096);
    }
    // A previous declaration rename may have succeeded before directory sync
    // failed. Make the observed ownership durable before creating any payload.
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
    const root = associations.workspace_root orelse return;
    const controls = try controlsPath(allocator, root, associations.git_common_dir, home);
    defer allocator.free(controls);
    const locator = try std.fs.path.join(allocator, &.{ controls, "registration.json" });
    defer allocator.free(locator);
    if (!try catalog.exists(io, locator)) return;
    var pending = try pendingTarget(allocator, io, associations, home, controls, false);
    defer pending.deinit();
    if (!std.mem.eql(u8, pending.value.store_id, selected.store_id) or
        !std.mem.eql(u8, pending.value.store_root, selected.store_root))
    {
        return error.PendingCustodyConflictsWithCatalog;
    }
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
    if (publication_lock) |lock| {
        var selected = try lock.read(allocator);
        defer selected.deinit();
        if (try selected.select(associations.aliases, null, false)) |id| {
            return host.checkedRoot(
                allocator,
                io,
                selected.value.stores.map.get(id).?,
                id,
                root,
                associations.git_common_dir,
                false,
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
    return materializePending(allocator, io, associations, value, controls_path, publication_lock);
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
        return readPendingRegistration(allocator, io, associations, home, locator_path);
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
    const controls = try catalog.openDirectory(io, controls_path, false);
    defer controls.close(io);
    try catalog.writeJson(allocator, io, controls, "registration.json", value, 4096);
    return value;
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
) !host.Context {
    const marker_path = try std.fs.path.join(allocator, &.{ value.store_root, marker_name });
    defer allocator.free(marker_path);
    if (try catalog.exists(io, marker_path)) return host.checkedRoot(
        allocator,
        io,
        value.store_root,
        value.store_id,
        associations.workspace_root,
        associations.git_common_dir,
        false,
    );
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
    try catalog.sync(io, controls);
    const control = try custody.openDir(io, ".ledger", .{ .follow_symlinks = false });
    defer control.close(io);
    try catalog.sync(io, control);
    try catalog.sync(io, custody);
    const repos = try catalog.openDirectory(io, std.fs.path.dirname(value.store_root).?, false);
    defer repos.close(io);
    try catalog.sync(io, repos);
    return host.checkedRoot(
        allocator,
        io,
        value.store_root,
        value.store_id,
        associations.workspace_root,
        associations.git_common_dir,
        true,
    );
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
        );
    }
};

test "pending migration scratch owns only its declared fixed layout across retries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", owned);
    const home = try std.fs.path.join(owned, &.{ root, "home" });
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root).?);
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
    var tmp = std.testing.tmpDir(.{});
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
            declareMigrationCopy(allocator, io, tmp.dir, tmp.dir, registration),
        );
        try std.testing.expect(!try catalog.existsAt(io, tmp.dir, migration_copy.directory_name));
    }
}

test "pending migration declaration failure creates no scratch and retry reuses identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", owned);
    const home = try std.fs.path.join(owned, &.{ root, "home" });
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root).?);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root).?);
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

test "pending target refuses foreign skeleton data and retains locator identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root).?);
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
        var tmp = std.testing.tmpDir(.{});
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
        try environment.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root).?);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try tmp.dir.writeFile(io, .{ .sub_path = candidate_name, .data = "{partial" });
    if (prepareMarker(allocator, io, tmp.dir, id)) |_| return error.TestExpectedError else |_| {}
    const retained = try catalog.readBytes(allocator, io, tmp.dir, candidate_name, 4096);
    defer allocator.free(retained);
    try std.testing.expectEqualStrings("{partial", retained);
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
    var tmp = std.testing.tmpDir(.{});
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
    try environment.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root).?);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const home = try std.fs.path.join(allocator, &.{ root, "home" });
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try environment.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root).?);
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
