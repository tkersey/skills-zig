const std = @import("std");
pub const catalog = @import("host_catalog.zig");
pub const workspace = @import("host_workspace.zig");

pub const Options = struct {
    catalog_root: []const u8,
    workspace: ?[]const u8 = null,
    store_id: ?[]const u8 = null,
    legacy_paths: []const []const u8 = &.{},
};

pub const ContextValue = struct {
    schema: []const u8 = "ledger-workspace-context/v1",
    workspace_root: ?[]const u8,
    git_common_dir: ?[]const u8,
    repository_id: []const u8,
    store_id: []const u8,
    store_root: []const u8,
    native_args: []const []const u8,
    storage_mutated: bool,
    cataloged: bool,
    authority_granted: bool = false,
};

pub const Context = struct {
    arena: std.heap.ArenaAllocator,
    value: ContextValue,

    pub fn deinit(self: *Context) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Store = struct {
    store_id: []const u8,
    repository_id: []const u8,
    store_root: []const u8,
    aliases: []const []const u8,
};

pub const StoreList = struct {
    arena: std.heap.ArenaAllocator,
    value: struct {
        schema: []const u8 = "ledger-personal-store-list/v1",
        stores: []const Store,
        pending: []const @import("host_pending.zig").Retained,
        storage_mutated: bool = false,
        authority_granted: bool = false,
    },

    pub fn deinit(self: *StoreList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Registration = struct {
    schema: []const u8,
    store_id: []const u8,
    store_root: []const u8,
};

pub fn context(
    allocator: std.mem.Allocator,
    root: []const u8,
    id: []const u8,
    workspace_root: ?[]const u8,
    common: ?[]const u8,
    mutated: bool,
    cataloged: bool,
) !Context {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const owned_root = try owned.dupe(u8, root);
    const owned_id = try owned.dupe(u8, id);
    const args = try owned.alloc([]const u8, 4);
    @memcpy(args, &[_][]const u8{ "--store-root", owned_root, "--store-id", owned_id });
    const value: ContextValue = .{
        .workspace_root = if (workspace_root) |path| try owned.dupe(u8, path) else null,
        .git_common_dir = if (common) |path| try owned.dupe(u8, path) else null,
        .repository_id = try std.fmt.allocPrint(owned, "ledger-repository:{s}", .{owned_id}),
        .store_id = owned_id,
        .store_root = owned_root,
        .native_args = args,
        .storage_mutated = mutated,
        .cataloged = cataloged,
    };
    return .{ .arena = arena, .value = value };
}

pub fn checkedRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    id: []const u8,
    workspace_root: ?[]const u8,
    common: ?[]const u8,
    mutated: bool,
    cataloged: bool,
) !Context {
    const control = try catalog.checkedRoot(allocator, io, root, id);
    defer control.close(io);
    return context(allocator, root, id, workspace_root, common, mutated, cataloged);
}

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
) !Context {
    var associations = try workspace.resolve(allocator, io, environment, options.workspace);
    defer associations.deinit();
    var selected = try catalog.read(allocator, io, options.catalog_root);
    defer selected.deinit();
    const id = (try selected.select(associations.aliases, options.store_id, false)) orelse
        return error.UnregisteredContext;
    return checkedRoot(
        allocator,
        io,
        selected.value.stores.map.get(id).?,
        id,
        associations.workspace_root,
        associations.git_common_dir,
        false,
        true,
    );
}

pub fn ensure(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
) !Context {
    return resolve(allocator, io, environment, options) catch |err| switch (err) {
        error.UnregisteredContext => blk: {
            if (options.workspace == null or options.store_id != null) return err;
            var associations = try workspace.resolve(allocator, io, environment, options.workspace);
            defer associations.deinit();
            const common = associations.git_common_dir orelse return err;
            const registration = try std.fs.path.join(
                allocator,
                &.{ common, catalog.registration_name },
            );
            defer allocator.free(registration);
            if (!try catalog.exists(io, registration)) return err;
            break :blk try importRegistration(allocator, io, environment, options, registration);
        },
        else => return err,
    };
}

pub fn registerRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    root: []const u8,
    id: []const u8,
) !Context {
    var cataloged = false;
    return registerRootObserved(allocator, io, environment, options, root, id, &cataloged);
}

pub fn registerRootObserved(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    root: []const u8,
    id: []const u8,
    cataloged: *bool,
) !Context {
    if (options.store_id) |selected| {
        if (!std.mem.eql(u8, selected, id)) return error.ConflictingStoreIdentity;
    }
    var associations = try workspace.resolve(allocator, io, environment, options.workspace);
    defer associations.deinit();
    const control = try catalog.checkedRoot(allocator, io, root, id);
    defer control.close(io);
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
    defer allocator.free(canonical);
    var lock = try catalog.Lock.acquire(io, options.catalog_root);
    defer lock.deinit();
    const changed = try associateRootLocked(
        allocator,
        io,
        &lock,
        &associations,
        options.catalog_root,
        canonical,
        id,
        control,
        cataloged,
    );
    return context(
        allocator,
        canonical,
        id,
        associations.workspace_root,
        associations.git_common_dir,
        changed,
        true,
    );
}

pub fn associateRootLocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    lock: *const catalog.Lock,
    associations: *const workspace.Associations,
    home: []const u8,
    root: []const u8,
    id: []const u8,
    control: std.Io.Dir,
    cataloged: *bool,
) !bool {
    try checkLegacyRegistration(allocator, io, associations.git_common_dir, root, id);
    var selected = try lock.read(allocator);
    defer selected.deinit();
    cataloged.* = try selected.containsStoreRoot(allocator, io, id, root);
    var candidate = try context(
        allocator,
        root,
        id,
        associations.workspace_root,
        associations.git_common_dir,
        false,
        cataloged.*,
    );
    defer candidate.deinit();
    try @import("host_pending.zig").syncPendingContext(
        allocator,
        io,
        associations,
        home,
        candidate.value,
        lock,
    );
    _ = try selected.select(associations.aliases, null, true);
    var changed = try selected.register(id, root);
    changed = (try selected.associate(associations.aliases, id)) or changed;
    const current = try catalog.checkedRoot(allocator, io, root, id);
    defer current.close(io);
    if (!try @import("durable_store").sameDirectoryObject(
        io,
        control,
        current,
    )) return error.StorageRootChanged;
    if (changed) try lock.publishObserved(allocator, selected.value, cataloged);
    return changed;
}

pub fn attach(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
) !Context {
    if (options.workspace == null or options.store_id == null) {
        return error.AttachmentRequiresWorkspaceAndStoreId;
    }
    var associations = try workspace.resolve(allocator, io, environment, options.workspace);
    defer associations.deinit();
    var selected = try catalog.read(allocator, io, options.catalog_root);
    defer selected.deinit();
    const id = (try selected.select(associations.aliases, options.store_id, true)).?;
    return registerRoot(
        allocator,
        io,
        environment,
        options,
        selected.value.stores.map.get(id).?,
        id,
    );
}

pub fn readRegistration(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !std.json.Parsed(
    Registration,
) {
    var registration = try catalog.readJson(Registration, allocator, io, path, 4096);
    errdefer registration.deinit();
    if (!std.mem.eql(u8, registration.value.schema, catalog.registration_schema)) {
        return error.InvalidRegistrationSchema;
    }
    try catalog.validStoreId(registration.value.store_id);
    if (!std.fs.path.isAbsolute(registration.value.store_root)) return error.StorageRootNotAbsolute;
    return registration;
}

pub fn importRegistration(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    path: []const u8,
) !Context {
    if (options.store_id != null) return error.ImportRegistrationProvidesStoreIdentity;
    var registration = try readRegistration(allocator, io, path);
    defer registration.deinit();
    return registerRoot(
        allocator,
        io,
        environment,
        options,
        registration.value.store_root,
        registration.value.store_id,
    );
}

fn checkLegacyRegistration(
    allocator: std.mem.Allocator,
    io: std.Io,
    common: ?[]const u8,
    root: []const u8,
    id: []const u8,
) !void {
    const directory = common orelse return;
    const path = try std.fs.path.join(allocator, &.{ directory, catalog.registration_name });
    defer allocator.free(path);
    if (!try catalog.exists(io, path)) return;
    var registration = try readRegistration(allocator, io, path);
    defer registration.deinit();
    const control = try catalog.checkedRoot(
        allocator,
        io,
        registration.value.store_root,
        registration.value.store_id,
    );
    defer control.close(io);
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(
        io,
        registration.value.store_root,
        allocator,
    );
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, registration.value.store_id, id) or !std.mem.eql(u8, canonical, root)) {
        return error.DifferentLegacyRegistration;
    }
}

pub fn list(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !StoreList {
    var selected = try catalog.read(allocator, io, home);
    defer selected.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const stores = try owned.alloc(Store, selected.value.stores.map.count());
    for (
        selected.value.stores.map.keys(),
        selected.value.stores.map.values(),
        0..,
    ) |id, root, index| {
        var aliases: std.ArrayList([]const u8) = .empty;
        for (
            selected.value.aliases.map.keys(),
            selected.value.aliases.map.values(),
        ) |alias, association| {
            if (std.mem.eql(u8, id, association)) try aliases.append(
                owned,
                try owned.dupe(u8, alias),
            );
        }
        std.mem.sort([]const u8, aliases.items, {}, lessString);
        stores[index] = .{
            .store_id = try owned.dupe(u8, id),
            .repository_id = try std.fmt.allocPrint(owned, "ledger-repository:{s}", .{id}),
            .store_root = try owned.dupe(u8, root),
            .aliases = try aliases.toOwnedSlice(owned),
        };
    }
    std.mem.sort(Store, stores, {}, struct {
        fn less(_: void, left: Store, right: Store) bool {
            return std.mem.lessThan(u8, left.store_id, right.store_id);
        }
    }.less);
    const retained = try @import("host_pending.zig").retained(owned, io, home, &selected);
    return .{ .arena = arena, .value = .{ .stores = stores, .pending = retained } };
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

pub fn newStoreId(io: std.Io) ![32]u8 {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn initialize(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
) !Context {
    var associations = try workspace.resolve(allocator, io, environment, options.workspace);
    defer associations.deinit();
    {
        var initial = try catalog.read(allocator, io, options.catalog_root);
        defer initial.deinit();
        if (try initial.select(associations.aliases, options.store_id, false)) |id| {
            return checkedRoot(
                allocator,
                io,
                initial.value.stores.map.get(id).?,
                id,
                associations.workspace_root,
                associations.git_common_dir,
                false,
                true,
            );
        }
    }
    try rejectKnownHistory(allocator, io, environment, &associations, options.legacy_paths);
    var lock = try catalog.Lock.acquire(io, options.catalog_root);
    defer lock.deinit();
    var selected = try lock.read(allocator);
    defer selected.deinit();
    if (try selected.select(associations.aliases, options.store_id, false)) |id| {
        return checkedRoot(
            allocator,
            io,
            selected.value.stores.map.get(id).?,
            id,
            associations.workspace_root,
            associations.git_common_dir,
            false,
            true,
        );
    }
    try admitInitialization(allocator, io, environment, options, &associations, &lock);
    return publishInitialization(
        allocator,
        io,
        environment,
        options,
        &associations,
        &lock,
        &selected,
    );
}

fn admitInitialization(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    associations: *const workspace.Associations,
    lock: *const catalog.Lock,
) !void {
    try rejectKnownHistory(allocator, io, environment, associations, options.legacy_paths);
    try admitAllocation(allocator, io, options, associations, lock);
}

pub fn admitAllocation(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    associations: *const workspace.Associations,
    lock: *const catalog.Lock,
) !void {
    const pending = @import("host_pending.zig");
    if (associations.workspace_root) |root| {
        const controls = try pending.controlsPath(
            allocator,
            root,
            associations.git_common_dir,
            options.catalog_root,
        );
        defer allocator.free(controls);
        const locator = try std.fs.path.join(allocator, &.{ controls, "registration.json" });
        defer allocator.free(locator);
        if (try catalog.exists(io, locator)) return error.PendingInitializationRequiresPreparation;
    }
    pending.rejectUnregisteredCustody(
        allocator,
        lock,
        associations.workspace_root,
        associations.git_common_dir,
        options.catalog_root,
    ) catch |err| {
        if (err == error.UnregisteredCustodyExists and !try catalog.existsAt(
            io,
            lock.dir,
            catalog.filename,
        )) {
            return error.ExistingCustodyWithoutCatalog;
        }
        return err;
    };
}

fn publishInitialization(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    associations: *const workspace.Associations,
    lock: *const catalog.Lock,
    selected: *catalog.Catalog,
) !Context {
    lock.dir.createDir(io, "repos", .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const repos = try lock.dir.openDir(io, "repos", .{ .follow_symlinks = false, .iterate = true });
    defer repos.close(io);
    const id = try newStoreId(io);
    const stage_name = try std.fmt.allocPrint(allocator, ".initializing-{s}", .{id});
    defer allocator.free(stage_name);
    try repos.createDir(io, stage_name, .fromMode(0o700));
    defer discardInitializationStage(io, repos, stage_name);
    const stage = try repos.openDir(io, stage_name, .{ .follow_symlinks = false });
    defer stage.close(io);
    const control = try prepareInitializationStage(allocator, io, stage, &id);
    defer control.close(io);
    try rejectKnownHistory(allocator, io, environment, associations, options.legacy_paths);
    try repos.renamePreserve(stage_name, repos, &id, io);
    try catalog.sync(io, repos);
    try rejectKnownHistory(allocator, io, environment, associations, options.legacy_paths);
    const home = try lock.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const root = try std.fs.path.join(allocator, &.{ home, "repos", &id });
    defer allocator.free(root);
    const final_control = try catalog.checkedRoot(allocator, io, root, &id);
    defer final_control.close(io);
    _ = try selected.register(&id, root);
    _ = try selected.associate(associations.aliases, &id);
    try lock.publish(allocator, selected.value);
    return context(
        allocator,
        root,
        &id,
        associations.workspace_root,
        associations.git_common_dir,
        true,
        true,
    );
}

fn prepareInitializationStage(
    allocator: std.mem.Allocator,
    io: std.Io,
    stage: std.Io.Dir,
    id: []const u8,
) !std.Io.Dir {
    try stage.createDir(io, ".ledger", .fromMode(0o700));
    try catalog.writeJson(
        allocator,
        io,
        stage,
        ".ledger-root.json",
        .{ .schema = "ledger-storage-root/v1", .store_id = id },
        4096,
    );
    const control = try stage.openDir(io, ".ledger", .{ .follow_symlinks = false });
    errdefer control.close(io);
    try catalog.sync(io, control);
    try catalog.sync(io, stage);
    return control;
}

fn discardInitializationStage(io: std.Io, repos: std.Io.Dir, name: []const u8) void {
    repos.deleteTree(io, name) catch |err| {
        std.log.warn("initialization staging cleanup failed: {s}", .{@errorName(err)});
    };
}

fn rejectKnownHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    associations: *const workspace.Associations,
    legacy_paths: []const []const u8,
) !void {
    const root = associations.workspace_root orelse return;
    if (!try workspace.isDirectory(io, root)) return error.NewWorkspaceRequiresExistingDirectory;
    const legacy_parent = associations.git_common_dir orelse try std.fs.path.join(
        allocator,
        &.{ root, ".git" },
    );
    defer if (associations.git_common_dir == null) allocator.free(legacy_parent);
    const registration = try std.fs.path.join(
        allocator,
        &.{ legacy_parent, catalog.registration_name },
    );
    defer allocator.free(registration);
    if (try catalog.exists(io, registration)) return error.ExistingRegistrationRequiresImport;
    if (try workspace.hasLegacyHistory(
        allocator,
        io,
        root,
        legacy_paths,
    )) return error.LegacyHistoryRequiresMigration;
    if (associations.git_common_dir != null) {
        const trees = try workspace.worktrees(allocator, io, environment, root);
        defer workspace.freeWorktrees(allocator, trees);
        for (trees) |tree| {
            if (try workspace.hasLegacyHistory(allocator, io, tree, legacy_paths)) {
                return error.LinkedWorktreeHistoryRequiresMigration;
            }
        }
    }
}

test "context read-only lookup never initializes an unknown or missing store" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const home = try std.fs.path.join(allocator, &.{ root, "catalog" });
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try std.testing.expectError(
        error.UnregisteredContext,
        resolve(allocator, io, &environment, .{ .catalog_root = home }),
    );
    try std.testing.expect(!try catalog.exists(io, home));
    try std.testing.expectError(
        error.SelectedStoreNotCataloged,
        initialize(allocator, io, &environment, .{
            .catalog_root = home,
            .store_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        }),
    );
    try std.testing.expect(!try catalog.exists(io, home));
    var first = try initialize(allocator, io, &environment, .{ .catalog_root = home });
    defer first.deinit();
    var direct = try resolve(
        allocator,
        io,
        &environment,
        .{ .catalog_root = home, .store_id = first.value.store_id },
    );
    defer direct.deinit();
    try std.testing.expectEqualStrings(first.value.store_root, direct.value.store_root);
    try std.testing.expect(!direct.value.storage_mutated);
    const control = try std.fs.path.join(allocator, &.{ first.value.store_root, ".ledger" });
    defer allocator.free(control);
    try std.Io.Dir.cwd().deleteDir(io, control);
    try std.testing.expectError(
        error.StorageRootMissing,
        initialize(
            allocator,
            io,
            &environment,
            .{ .catalog_root = home, .store_id = first.value.store_id },
        ),
    );
    try std.testing.expect(!try catalog.exists(io, control));
}

test "context registration preserves identity and refuses root relocation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const home = try std.fs.path.join(allocator, &.{ root, "catalog" });
    defer allocator.free(home);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var first = try initialize(allocator, io, &environment, .{ .catalog_root = home });
    defer first.deinit();
    var unchanged = try registerRoot(
        allocator,
        io,
        &environment,
        .{ .catalog_root = home },
        first.value.store_root,
        first.value.store_id,
    );
    defer unchanged.deinit();
    try std.testing.expect(!unchanged.value.storage_mutated);
    var stores = try list(allocator, io, home);
    defer stores.deinit();
    try std.testing.expectEqual(@as(usize, 1), stores.value.stores.len);
    try std.testing.expectEqualStrings(first.value.store_id, stores.value.stores[0].store_id);
}

const GitFixture = struct {
    temporary: std.testing.TmpDir,
    root: []const u8,
    home: []const u8,
    repo: []const u8,
    other: []const u8,
    environment: std.process.Environ.Map,

    fn init() !GitFixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const canonical_root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(canonical_root);
        const root = try allocator.dupe(u8, canonical_root);
        errdefer allocator.free(root);
        const home = try std.fs.path.join(allocator, &.{ root, "catalog" });
        errdefer allocator.free(home);
        const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
        errdefer allocator.free(repo);
        const other = try std.fs.path.join(allocator, &.{ root, "other" });
        errdefer allocator.free(other);
        var environment = std.process.Environ.Map.init(allocator);
        errdefer environment.deinit();
        try environment.put("PATH", "/usr/bin:/bin");
        try environment.put("GIT_DIR", "/nonexistent-injected-git-dir");
        try environment.put("GIT_WORK_TREE", "/nonexistent-injected-worktree");
        try environment.put("GIT_COMMON_DIR", "/nonexistent-injected-common-dir");
        try environment.put("GIT_INDEX_FILE", "/nonexistent-injected-index");
        var result: GitFixture = .{
            .temporary = temporary,
            .root = root,
            .home = home,
            .repo = repo,
            .other = other,
            .environment = environment,
        };
        try result.run(root, &.{ "init", "-q", repo });
        try result.run(
            repo,
            &.{
                "-c",     "user.name=Fixture", "-c",  "user.email=fixture@example.invalid",
                "commit", "--allow-empty",     "-qm", "fixture",
            },
        );
        try result.run(repo, &.{ "worktree", "add", "-q", "--detach", other });
        return result;
    }

    fn deinit(self: *GitFixture) void {
        self.environment.deinit();
        for ([_][]const u8{
            self.root,
            self.home,
            self.repo,
            self.other,
        }) |path| std.testing.allocator.free(path);
        self.temporary.cleanup();
        self.* = undefined;
    }

    fn run(self: *GitFixture, root: []const u8, args: []const []const u8) !void {
        const bytes = try workspace.git(
            std.testing.allocator,
            std.testing.io,
            &self.environment,
            root,
            args,
        );
        std.testing.allocator.free(bytes);
    }
};

test "context Git family selection survives sibling loss but rejects reused workspace paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try GitFixture.init();
    defer fixture.deinit();
    var first = try initialize(allocator, io, &fixture.environment, .{
        .catalog_root = fixture.home,
        .workspace = fixture.other,
    });
    defer first.deinit();
    var sibling = try resolve(allocator, io, &fixture.environment, .{
        .catalog_root = fixture.home,
        .workspace = fixture.repo,
    });
    defer sibling.deinit();
    try std.testing.expectEqualStrings(first.value.store_id, sibling.value.store_id);
    try fixture.run(fixture.repo, &.{ "worktree", "remove", fixture.other });
    try std.testing.expectError(
        error.GitCommonDirectoryIdentityChanged,
        resolve(allocator, io, &fixture.environment, .{
            .catalog_root = fixture.home,
            .workspace = fixture.other,
        }),
    );
    try fixture.run(fixture.root, &.{ "init", "-q", fixture.other });
    try std.testing.expectError(
        error.UnregisteredGitCommonDirectory,
        initialize(allocator, io, &fixture.environment, .{
            .catalog_root = fixture.home,
            .workspace = fixture.other,
        }),
    );
    var attached = try attach(allocator, io, &fixture.environment, .{
        .catalog_root = fixture.home,
        .workspace = fixture.other,
        .store_id = first.value.store_id,
    });
    defer attached.deinit();
    try std.testing.expectEqualStrings(first.value.store_id, attached.value.store_id);
    try std.testing.expect(attached.value.storage_mutated);
}

test "context existing registration adoption is explicit and needs no sibling inventory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try GitFixture.init();
    defer fixture.deinit();
    var first = try initialize(
        allocator,
        io,
        &fixture.environment,
        .{ .catalog_root = fixture.home },
    );
    defer first.deinit();
    var associations = try workspace.resolve(allocator, io, &fixture.environment, fixture.repo);
    defer associations.deinit();
    const common = try catalog.openDirectory(io, associations.git_common_dir.?, false);
    defer common.close(io);
    try catalog.writeJson(allocator, io, common, catalog.registration_name, Registration{
        .schema = catalog.registration_schema,
        .store_id = first.value.store_id,
        .store_root = first.value.store_root,
    }, 4096);
    try std.Io.Dir.cwd().deleteTree(io, fixture.other);
    const options: Options = .{ .catalog_root = fixture.home, .workspace = fixture.repo };
    try std.testing.expectError(
        error.UnregisteredContext,
        resolve(allocator, io, &fixture.environment, options),
    );
    try std.testing.expectError(
        error.ExistingRegistrationRequiresImport,
        initialize(allocator, io, &fixture.environment, options),
    );
    var adopted = try ensure(allocator, io, &fixture.environment, options);
    defer adopted.deinit();
    try std.testing.expectEqualStrings(first.value.store_id, adopted.value.store_id);
    var current = try ensure(allocator, io, &fixture.environment, options);
    defer current.deinit();
    try std.testing.expect(!current.value.storage_mutated);
}

test "context initialization preserves caller-declared legacy history in sibling worktrees" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try GitFixture.init();
    defer fixture.deinit();
    const sibling = try catalog.openDirectory(io, fixture.other, false);
    defer sibling.close(io);
    try sibling.writeFile(io, .{ .sub_path = "retired-owner-history.jsonl", .data = "prior\n" });
    try std.testing.expectError(
        error.RetiredSourceRequiresRecovery,
        initialize(allocator, io, &fixture.environment, .{
            .catalog_root = fixture.home,
            .workspace = fixture.repo,
            .legacy_paths = &.{"retired-owner-history.jsonl"},
        }),
    );
    try std.testing.expect(!try catalog.exists(io, fixture.home));
}

const InitializationInterleaving = struct {
    var active: ?*InitializationInterleaving = null;
    io: std.Io,
    workspace_dir: std.Io.Dir,
    after_final_rename: bool,
    fired: bool = false,

    fn append(self: *InitializationInterleaving) void {
        self.workspace_dir.createDir(self.io, ".ledger", .fromMode(0o700)) catch |err| {
            std.debug.panic("late-history directory creation failed: {s}", .{@errorName(err)});
        };
        self.workspace_dir.writeFile(self.io, .{
            .sub_path = ".ledger/prior-history.jsonl",
            .data = "late append\n",
        }) catch |err| {
            std.debug.panic("late-history append failed: {s}", .{@errorName(err)});
        };
        self.fired = true;
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
        if (!self.after_final_rename and std.mem.eql(
            u8,
            new_name,
            ".ledger-root.json",
        )) self.append();
    }

    fn renamePreserve(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_name: []const u8,
        new_dir: std.Io.Dir,
        new_name: []const u8,
    ) std.Io.Dir.RenamePreserveError!void {
        const self = active.?;
        try self.io.vtable.dirRenamePreserve(userdata, old_dir, old_name, new_dir, new_name);
        if (self.after_final_rename and std.mem.startsWith(
            u8,
            old_name,
            ".initializing-",
        )) self.append();
    }
};

test "context initialization checks late history before publishing the family association" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |after_final_rename| {
        var tmp = try workspace.testPlainDirectory();
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        const home = try std.fs.path.join(allocator, &.{ root, "home" });
        defer allocator.free(home);
        var environment = std.process.Environ.Map.init(allocator);
        defer environment.deinit();
        var interleaving: InitializationInterleaving = .{
            .io = io,
            .workspace_dir = tmp.dir,
            .after_final_rename = after_final_rename,
        };
        InitializationInterleaving.active = &interleaving;
        defer InitializationInterleaving.active = null;
        var vtable = io.vtable.*;
        vtable.dirRename = InitializationInterleaving.rename;
        vtable.dirRenamePreserve = InitializationInterleaving.renamePreserve;
        var injected = io;
        injected.vtable = &vtable;
        try std.testing.expectError(error.LegacyHistoryRequiresMigration, initialize(
            allocator,
            injected,
            &environment,
            .{ .catalog_root = home, .workspace = root },
        ));
        try std.testing.expect(interleaving.fired);
        var selected = try catalog.read(allocator, io, home);
        defer selected.deinit();
        try std.testing.expectEqual(@as(usize, 0), selected.value.stores.map.count());
        try std.testing.expect(try catalog.existsAt(io, tmp.dir, ".ledger/prior-history.jsonl"));
    }
}

test "catalog membership preserves admitted root equivalence without reading unrelated roots" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", owned);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var seed = try initialize(allocator, io, &environment, .{
        .catalog_root = try std.fs.path.join(owned, &.{ root, "home" }),
    });
    defer seed.deinit();
    var selected = try catalog.read(allocator, io, try std.fs.path.join(owned, &.{ root, "home" }));
    defer selected.deinit();
    _ = try selected.register("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "/missing-unrelated-custody");
    const spellings = [_][]const u8{
        seed.value.store_root,
        try std.fmt.allocPrint(owned, "{s}/", .{seed.value.store_root}),
        try std.fmt.allocPrint(owned, "{s}//home//repos//{s}", .{ root, seed.value.store_id }),
    };
    for (spellings) |stored| {
        selected.value.stores.map.getPtr(seed.value.store_id).?.* = stored;
        for (spellings) |candidate| try std.testing.expect(try selected.containsStoreRoot(
            allocator,
            io,
            seed.value.store_id,
            candidate,
        ));
    }
    try std.testing.expect(!try selected.containsStoreRoot(
        allocator,
        io,
        "cccccccccccccccccccccccccccccccc",
        seed.value.store_root,
    ));
    try testCatalogRootRefusals(owned, tmp.dir, root, &selected, seed.value.store_id);
}

fn testCatalogRootRefusals(
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    root: []const u8,
    selected: *catalog.Catalog,
    id: []const u8,
) !void {
    const io = std.testing.io;
    try directory.createDir(io, "other", .default_dir);
    const other = try directory.openDir(io, "other", .{});
    defer other.close(io);
    try other.createDir(io, ".ledger", .default_dir);
    try catalog.writeJson(allocator, io, other, ".ledger-root.json", .{
        .schema = "ledger-storage-root/v1",
        .store_id = id,
    }, 4096);
    try std.testing.expect(!try selected.containsStoreRoot(
        allocator,
        io,
        id,
        try std.fs.path.join(allocator, &.{ root, "other" }),
    ));
    try directory.symLink(io, selected.value.stores.map.get(id).?, "linked", .{});
    const linked = try std.fs.path.join(allocator, &.{ root, "linked" });
    if (selected.containsStoreRoot(allocator, io, id, linked)) |_| {
        return error.TestExpectedError;
    } else |err| try std.testing.expect(
        err == error.SymlinkComponent or err == error.StorageRootNotDirectory,
    );
    const dot = try std.fmt.allocPrint(allocator, "{s}/.", .{selected.value.stores.map.get(id).?});
    try std.testing.expectError(error.InvalidStorageRootPath, selected.containsStoreRoot(
        allocator,
        io,
        id,
        dot,
    ));
    const missing = try std.fs.path.join(allocator, &.{ root, "missing" });
    try std.testing.expectError(error.StorageRootMissing, selected.containsStoreRoot(
        allocator,
        io,
        id,
        missing,
    ));
}
