const std = @import("std");
const host = @import("host_context.zig");
const legacy = @import("host_legacy.zig");
const cli = @import("cli.zig");
const ledger = @import("ledger_v1_core");
const parameters = @import("definition_core").parameters;
const storage_root = @import("storage_root");
const durable_store = @import("durable_store");
const preparation = ledger.preparation;

const Owner = struct {
    plan: ledger.compiled_plan.PlanSet,
    bindings: parameters.Bindings,

    fn deinit(self: *Owner, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
        self.plan.deinit(allocator);
    }
};

const Owners = struct {
    definitions: std.ArrayList(Owner) = .empty,
    slots: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Owners, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        for (self.definitions.items) |*owner| owner.deinit(allocator);
        self.definitions.deinit(allocator);
        self.* = undefined;
    }

    fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
        definitions: []const []const u8,
    ) !Owners {
        if (definitions.len == 0) return error.MissingOwnerDefinitions;
        if (definitions.len > 128) return error.OwnerDefinitionBoundExceeded;
        var result: Owners = .{};
        errdefer result.deinit(allocator);
        var scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
        for (definitions) |path| {
            var plan = try cli.loadDefinitionWithCache(
                &scope,
                allocator,
                environment,
                path,
                .{ .kind = .doctor },
                false,
            );
            errdefer plan.deinit(allocator);
            var bindings = try cli.bindParameters(
                allocator,
                &plan.definition_plan.parameter_declarations,
                &.{},
            );
            errdefer bindings.deinit(allocator);
            const storage = plan.storage_plan orelse
                return error.ColdAdoptionRequiresStaticEventSlots;
            for (storage.slots) |slot| {
                if (slot.kind != .event_log or slot.codec != .jsonl or slot.layout != .monolithic or
                    std.mem.findScalar(u8, slot.relative_path, '{') != null)
                {
                    return error.ColdAdoptionRequiresStaticEventSlots;
                }
                try legacy.relative(slot.relative_path);
                var present = false;
                for (result.slots.items) |existing| {
                    if (std.mem.eql(u8, existing, slot.relative_path)) present = true;
                }
                if (!present) try result.slots.append(allocator, slot.relative_path);
            }
            try result.definitions.append(allocator, .{ .plan = plan, .bindings = bindings });
        }
        if (result.slots.items.len == 0) return error.MissingOwnerDefinitions;
        return result;
    }

    fn inspect(
        self: *const Owners,
        allocator: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        control: ?std.Io.Dir,
    ) !void {
        var scope = storage_root.Scope.init(if (control) |directory|
            .anchored(io, directory)
        else
            .init(io, std.Io.Dir.cwd()));
        for (self.definitions.items) |*owner| {
            var result = try ledger.doctor.execute(
                &scope,
                allocator,
                &owner.plan.definition_plan,
                &owner.plan.storage_plan.?,
                if (owner.plan.protocol_plan) |*protocol| protocol else null,
                if (control != null) "." else root,
                &owner.bindings,
            );
            defer result.deinit(allocator);
            if (!result.healthy or result.pending_transactions != 0 or result.preparation_pending or
                result.storage_mutated or result.authority_granted)
            {
                return error.ColdAdoptionRequiresHealthyCustody;
            }
        }
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: host.Options,
    source: []const u8,
    definitions: []const []const u8,
    confirm_no_writers: bool,
) !host.Context {
    if (!confirm_no_writers) return error.ColdAdoptionRequiresWriterQuiescence;
    const selected_workspace = options.workspace orelse return error.ColdAdoptionRequiresWorkspace;
    if (!std.fs.path.isAbsolute(source)) return error.WorkspaceNotAbsolute;
    var associations = try host.workspace.resolve(allocator, io, environment, selected_workspace);
    defer associations.deinit();
    const root = associations.workspace_root.?;
    const common = associations.git_common_dir orelse return error.ColdAdoptionRequiresGitWorktree;
    var initial = try host.catalog.read(allocator, io, options.catalog_root);
    defer initial.deinit();
    if (try initial.select(associations.aliases, options.store_id, false) != null) {
        return error.ColdAdoptionAlreadyCataloged;
    }
    try rejectRegistration(allocator, io, common);
    const source_git = try host.workspace.verifiedGit(allocator, io, environment, source);
    defer allocator.free(source_git.root);
    defer allocator.free(source_git.common);
    if (!std.mem.eql(u8, source_git.common, common)) return error.AdoptionSourceOutsideGitFamily;
    const trees = try host.workspace.worktrees(allocator, io, environment, root);
    defer host.workspace.freeWorktrees(allocator, trees);
    if (!contains(trees, source_git.root)) return error.AdoptionSourceOutsideGitFamily;
    for (trees) |tree| {
        _ = try host.workspace.hasLegacyHistory(allocator, io, tree, options.legacy_paths);
    }
    if (!try host.workspace.hasLegacyHistory(
        allocator,
        io,
        source_git.root,
        options.legacy_paths,
    )) {
        return error.AdoptionSourceHasNoLegacyCustody;
    }
    var owners = try Owners.load(allocator, io, environment, definitions);
    defer owners.deinit(allocator);
    try owners.inspect(allocator, io, source_git.root, null);
    var before = try legacy.coldInventory(allocator, io, trees, owners.slots.items, .{});
    defer before.deinit();
    const index = try selectedSource(allocator, io, &before, &owners, source_git.root);
    return publishAdoption(
        allocator,
        io,
        environment,
        options,
        &associations,
        trees,
        &owners,
        &before,
        index,
    );
}

fn publishAdoption(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: host.Options,
    associations: *const host.workspace.Associations,
    trees: []const []const u8,
    owners: *const Owners,
    before: *const legacy.Inventory,
    index: usize,
) !host.Context {
    const common = associations.git_common_dir.?;
    var lock = try host.catalog.Lock.acquire(io, options.catalog_root);
    defer lock.deinit();
    var catalog = try lock.read(allocator);
    defer catalog.deinit();
    if (try catalog.select(associations.aliases, options.store_id, false) != null) {
        return error.ConcurrentCatalogRegistration;
    }
    try rejectRegistration(allocator, io, common);
    try host.admitAllocation(allocator, io, options, associations, &lock);
    lock.dir.createDir(io, "repos", .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const repos = try lock.dir.openDir(io, "repos", .{ .follow_symlinks = false, .iterate = true });
    defer repos.close(io);
    const id = try host.newStoreId(io);
    const stage_name = try std.fmt.allocPrint(allocator, ".initializing-{s}", .{id});
    defer allocator.free(stage_name);
    try repos.createDir(io, stage_name, .fromMode(0o700));
    defer repos.deleteTree(io, stage_name) catch |err| {
        std.log.warn("adoption staging cleanup failed: {s}", .{@errorName(err)});
    };
    const stage = try repos.openDir(io, stage_name, .{ .follow_symlinks = false });
    defer stage.close(io);
    const control = try stageAdoption(
        allocator,
        io,
        environment,
        options,
        associations,
        trees,
        owners,
        before,
        index,
        stage,
        &id,
    );
    defer control.close(io);
    try repos.renamePreserve(stage_name, repos, &id, io);
    try host.catalog.sync(io, repos);
    return finishAdoption(
        allocator,
        io,
        environment,
        options,
        associations,
        trees,
        owners,
        before,
        &lock,
        &catalog,
        &id,
        control,
    );
}

fn finishAdoption(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: host.Options,
    associations: *const host.workspace.Associations,
    trees: []const []const u8,
    owners: *const Owners,
    before: *const legacy.Inventory,
    lock: *const host.catalog.Lock,
    catalog: *host.catalog.Catalog,
    id: []const u8,
    control: std.Io.Dir,
) !host.Context {
    const common = associations.git_common_dir.?;
    const home = try lock.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const custody = try std.fs.path.join(allocator, &.{ home, "repos", id });
    defer allocator.free(custody);
    const current = try host.catalog.checkedRoot(allocator, io, custody, id);
    defer current.close(io);
    if (!try durable_store.sameDirectoryObject(io, control, current))
        return error.AdoptionTargetChanged;
    try owners.inspect(allocator, io, custody, current);
    try reinspectFamily(
        allocator,
        io,
        environment,
        options,
        associations,
        trees,
        before,
        owners.slots.items,
    );
    try rejectRegistration(allocator, io, common);
    _ = try catalog.register(id, custody);
    _ = try catalog.associate(associations.aliases, id);
    try lock.publish(allocator, catalog.value);
    return host.context(allocator, custody, id, associations.workspace_root, common, true);
}

fn stageAdoption(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: host.Options,
    associations: *const host.workspace.Associations,
    trees: []const []const u8,
    owners: *const Owners,
    before: *const legacy.Inventory,
    index: usize,
    stage: std.Io.Dir,
    id: []const u8,
) !std.Io.Dir {
    try stage.createDir(io, ".ledger", .fromMode(0o700));
    const stage_path = try stage.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(stage_path);
    try legacy.copyCold(allocator, io, before, index, stage_path);
    try reinspectFamily(
        allocator,
        io,
        environment,
        options,
        associations,
        trees,
        before,
        owners.slots.items,
    );
    try verifyCopy(
        allocator,
        io,
        &before.sources.map.values()[index],
        stage_path,
        owners.slots.items,
    );
    try owners.inspect(allocator, io, stage_path, null);
    try host.catalog.writeJson(allocator, io, stage, ".ledger-root.json", .{
        .schema = "ledger-storage-root/v1",
        .store_id = id,
    }, 4096);
    const control = try stage.openDir(io, ".ledger", .{ .follow_symlinks = false });
    errdefer control.close(io);
    try host.catalog.sync(io, control);
    try host.catalog.sync(io, stage);
    return control;
}

fn contains(paths: []const []const u8, selected: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, selected)) return true;
    }
    return false;
}

fn rejectRegistration(allocator: std.mem.Allocator, io: std.Io, common: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ common, host.catalog.registration_name });
    defer allocator.free(path);
    if (try host.catalog.exists(io, path)) return error.ExistingRegistrationRequiresImport;
}

fn selectedSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: *const legacy.Inventory,
    owners: *const Owners,
    source: []const u8,
) !usize {
    const explicit = for (snapshot.sources.map.values(), 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate.workspace, source)) break index;
    } else return error.AdoptionSourceOutsideGitFamily;
    const limits: legacy.Limits = .{};
    if (snapshot.total_bytes > limits.max_bytes or snapshot.file_count > limits.max_files)
        return error.MigrationInventoryBoundExceeded;
    for (owners.definitions.items) |*owner| {
        for (owner.plan.storage_plan.?.slots) |slot| {
            var selected = try captureSource(allocator, io, owner, source, slot);
            defer selected.deinit(allocator);
            for (snapshot.sources.map.values(), 0..) |candidate, index| {
                if (index == explicit) continue;
                var other = try captureSource(allocator, io, owner, candidate.workspace, slot);
                defer other.deinit(allocator);
                if (!selected.covers(&other)) return error.AdoptionSourceDoesNotCoverHistory;
            }
        }
    }
    return explicit;
}

fn captureSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: *const Owner,
    root: []const u8,
    slot: ledger.storage.Slot,
) !preparation.History {
    const limits: legacy.Limits = .{};
    var scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
    return preparation.captureSourceHistoryBounded(
        &scope,
        allocator,
        root,
        &owner.plan.definition_plan,
        .{
            .name = slot.name,
            .relative_path = slot.relative_path,
            .owned_path = null,
            .kind = slot.kind,
            .codec = slot.codec,
            .max_bytes = slot.max_bytes,
            .layout = slot.layout,
        },
        &owner.bindings,
        owner.plan.protocol_plan != null,
        .{ .max_bytes = @intCast(limits.max_bytes), .max_files = limits.max_files },
        false,
    );
}

fn verifyCopy(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: *const legacy.Source,
    destination: []const u8,
    slots: []const []const u8,
) !void {
    var copied = try legacy.coldInventory(allocator, io, &.{destination}, slots, .{});
    defer copied.deinit();
    const expected = try legacy.canonicalAlloc(allocator, source.entries);
    defer allocator.free(expected);
    const actual = try legacy.canonicalAlloc(allocator, copied.sources.map.values()[0].entries);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, expected, actual)) return error.SourceChangedDuringAdoption;
}

fn reinspectFamily(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: host.Options,
    original: *const host.workspace.Associations,
    trees: []const []const u8,
    before: *const legacy.Inventory,
    slots: []const []const u8,
) !void {
    var current = try host.workspace.resolve(allocator, io, environment, options.workspace);
    defer current.deinit();
    if (!host.catalog.optionalEqual(current.workspace_root, original.workspace_root) or
        !host.catalog.optionalEqual(current.git_common_dir, original.git_common_dir))
    {
        return error.WorkspaceChangedDuringAdoption;
    }
    const now = try host.workspace.worktrees(allocator, io, environment, current.workspace_root.?);
    defer host.workspace.freeWorktrees(allocator, now);
    if (now.len != trees.len) return error.WorktreeCoverageChangedDuringAdoption;
    for (now) |actual| {
        if (!contains(trees, actual)) return error.WorktreeCoverageChangedDuringAdoption;
        _ = try host.workspace.hasLegacyHistory(allocator, io, actual, options.legacy_paths);
    }
    var after = try legacy.coldInventory(allocator, io, trees, slots, .{});
    defer after.deinit();
    const expected = try before.json(allocator);
    defer allocator.free(expected);
    const actual = try after.json(allocator);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, expected, actual)) return error.SourceChangedDuringAdoption;
}

test "cold adoption requires explicit authority before inspecting or creating custody" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try std.testing.expectError(error.ColdAdoptionRequiresWriterQuiescence, execute(
        allocator,
        io,
        &environment,
        .{ .catalog_root = "/unused" },
        "/unused",
        &.{},
        false,
    ));
    try std.testing.expectError(error.ColdAdoptionRequiresWorkspace, execute(
        allocator,
        io,
        &environment,
        .{ .catalog_root = "/unused" },
        "/unused",
        &.{},
        true,
    ));
}

fn testGit(
    environment: *const std.process.Environ.Map,
    root: []const u8,
    args: []const []const u8,
) !void {
    const output = try host.workspace.git(
        std.testing.allocator,
        std.testing.io,
        environment,
        root,
        args,
    );
    std.testing.allocator.free(output);
}

fn testAppend(
    environment: *const std.process.Environ.Map,
    definition: []const u8,
    root: []const u8,
    bytes: []const u8,
) !void {
    const allocator = std.testing.allocator;
    var scope = storage_root.Scope.init(.init(std.testing.io, std.Io.Dir.cwd()));
    var plan = try cli.loadDefinitionWithCache(
        &scope,
        allocator,
        environment,
        definition,
        .{ .kind = .transact, .name = "append" },
        false,
    );
    defer plan.deinit(allocator);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const request = try std.fmt.allocPrint(
        allocator,
        "request={s}",
        .{std.fmt.bytesToHex(digest, .lower)},
    );
    defer allocator.free(request);
    var bindings = try cli.bindParameters(
        allocator,
        &plan.definition_plan.parameter_declarations,
        &.{request},
    );
    defer bindings.deinit(allocator);
    var result = try ledger.transaction.transact(
        &scope,
        allocator,
        &plan.definition_plan,
        &plan.closure,
        plan.entry_path,
        &plan.validation_plan.?,
        &plan.storage_plan.?,
        if (plan.protocol_plan) |*protocol| protocol else null,
        "append",
        root,
        &.{.{ .name = "event", .bytes = bytes }},
        &bindings,
    );
    defer result.deinit(allocator);
    try std.testing.expect(result.validation_result.valid);
    try std.testing.expect(result.storage_mutated);
}

const LateSourceWrite = struct {
    var active: ?*LateSourceWrite = null;
    io: std.Io,
    source: std.Io.Dir,
    replacement: []const u8,
    fired: bool = false,

    fn renamePreserve(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_name: []const u8,
        new_dir: std.Io.Dir,
        new_name: []const u8,
    ) std.Io.Dir.RenamePreserveError!void {
        const self = active.?;
        try self.io.vtable.dirRenamePreserve(userdata, old_dir, old_name, new_dir, new_name);
        if (std.mem.startsWith(u8, old_name, ".initializing-")) {
            self.source.writeFile(self.io, .{
                .sub_path = "example/events.jsonl",
                .data = self.replacement,
            }) catch |err| @panic(@errorName(err));
            self.fired = true;
        }
    }
};

test "cold adoption preserves covering history and detects late source changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
    defer allocator.free(repo);
    const other = try std.fs.path.join(allocator, &.{ root, "other" });
    defer allocator.free(other);
    const home = try std.fs.path.join(allocator, &.{ root, "catalog" });
    defer allocator.free(home);
    const definition = try std.fs.path.join(allocator, &.{ root, "definition.json" });
    defer allocator.free(definition);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "definition.json", .data = @embedFile("fixtures/event-definition.json") },
    );
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try testBuildFamily(tmp.dir, &environment, root, repo, other, definition);
    var before = try legacy.coldInventory(
        allocator,
        io,
        &.{ repo, other },
        &.{"example/events.jsonl"},
        .{},
    );
    defer before.deinit();
    const options: host.Options = .{ .catalog_root = home, .workspace = other };
    try std.testing.expectError(error.AdoptionSourceDoesNotCoverHistory, execute(
        allocator,
        io,
        &environment,
        options,
        other,
        &.{definition},
        true,
    ));
    try std.testing.expect(!try host.catalog.exists(io, home));
    var adopted = try execute(allocator, io, &environment, options, repo, &.{definition}, true);
    defer adopted.deinit();
    try std.testing.expect(adopted.value.storage_mutated);
    try verifyCopy(
        allocator,
        io,
        &before.sources.map.values()[0],
        adopted.value.store_root,
        &.{"example/events.jsonl"},
    );
    try testAdoptionParity(&environment, repo, other, home, &before, adopted.value);
    try std.testing.expectError(error.ColdAdoptionAlreadyCataloged, execute(
        allocator,
        io,
        &environment,
        options,
        repo,
        &.{definition},
        true,
    ));
    try testLateSourceWrite(&environment, root, repo, other, definition);
}

fn testLateSourceWrite(
    environment: *const std.process.Environ.Map,
    root: []const u8,
    repo: []const u8,
    other: []const u8,
    definition: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const control_path = try std.fs.path.join(allocator, &.{ repo, ".ledger" });
    defer allocator.free(control_path);
    const control = try host.catalog.openDirectory(io, control_path, false);
    defer control.close(io);
    const history = try host.catalog.readBytes(
        allocator,
        io,
        control,
        "example/events.jsonl",
        65536,
    );
    defer allocator.free(history);
    const replacement = try std.fmt.allocPrint(allocator, "{s}late append\n", .{history});
    defer allocator.free(replacement);
    const second_home = try std.fs.path.join(allocator, &.{ root, "second-catalog" });
    defer allocator.free(second_home);
    var interleaving: LateSourceWrite = .{
        .io = io,
        .source = control,
        .replacement = replacement,
    };
    LateSourceWrite.active = &interleaving;
    defer LateSourceWrite.active = null;
    var vtable = io.vtable.*;
    vtable.dirRenamePreserve = LateSourceWrite.renamePreserve;
    var injected = io;
    injected.vtable = &vtable;
    try std.testing.expectError(error.SourceChangedDuringAdoption, execute(
        allocator,
        injected,
        environment,
        .{ .catalog_root = second_home, .workspace = other },
        repo,
        &.{definition},
        true,
    ));
    try std.testing.expect(interleaving.fired);
    var unpublished = try host.list(allocator, io, second_home);
    defer unpublished.deinit();
    try std.testing.expectEqual(@as(usize, 0), unpublished.value.stores.len);
}

fn testAdoptionParity(
    environment: *const std.process.Environ.Map,
    repo: []const u8,
    other: []const u8,
    home: []const u8,
    before: *const legacy.Inventory,
    adopted: host.ContextValue,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var after = try legacy.coldInventory(
        allocator,
        io,
        &.{ repo, other },
        &.{"example/events.jsonl"},
        .{},
    );
    defer after.deinit();
    const expected = try before.json(allocator);
    defer allocator.free(expected);
    const actual = try after.json(allocator);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    var selected = try host.resolve(
        allocator,
        io,
        environment,
        .{ .catalog_root = home, .workspace = repo },
    );
    defer selected.deinit();
    try std.testing.expectEqualStrings(adopted.store_id, selected.value.store_id);
}

fn testBuildFamily(
    dir: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    root: []const u8,
    repo: []const u8,
    other: []const u8,
    definition: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try testGit(environment, root, &.{ "init", "-q", repo });
    try dir.writeFile(io, .{ .sub_path = "repo/.gitignore", .data = ".ledger/\n" });
    try testGit(environment, repo, &.{ "add", ".gitignore" });
    try testGit(environment, repo, &.{
        "-c",     "user.name=Fixture", "-c",      "user.email=fixture@example.invalid",
        "commit", "-qm",               "fixture",
    });
    try testGit(environment, repo, &.{ "worktree", "add", "-q", "--detach", other });
    try testAppend(environment, definition, repo, "{\"kind\":\"first\",\"value\":1}");
    var prefix = try legacy.coldInventory(allocator, io, &.{repo}, &.{"example/events.jsonl"}, .{});
    defer prefix.deinit();
    try legacy.copyCold(allocator, io, &prefix, 0, other);
    try testAppend(environment, definition, repo, "{\"kind\":\"second\",\"value\":2}");
}

const AdoptionPublicationFault = struct {
    var active: ?*AdoptionPublicationFault = null;
    io: std.Io,
    catalog_sync: bool,
    published_id: ?[32]u8 = null,
    fired: bool = false,

    fn renamePreserve(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_name: []const u8,
        new_dir: std.Io.Dir,
        new_name: []const u8,
    ) std.Io.Dir.RenamePreserveError!void {
        const self = active.?;
        try self.io.vtable.dirRenamePreserve(userdata, old_dir, old_name, new_dir, new_name);
        if (std.mem.startsWith(u8, old_name, ".initializing-")) {
            std.debug.assert(new_name.len == 32);
            self.published_id = new_name[0..32].*;
        }
    }

    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        const self = active.?;
        if (self.published_id != null) {
            const stat = file.stat(self.io) catch return error.InputOutput;
            if (!self.catalog_sync or stat.kind == .file) {
                self.fired = true;
                return error.InputOutput;
            }
        }
        return self.io.vtable.fileSync(userdata, file);
    }
};

test "cold adoption retains one published identity across sync failures and manual registration" {
    for ([_]bool{ false, true }) |catalog_sync| try testAdoptionPublicationRetry(catalog_sync);
}

fn testAdoptionPublicationRetry(catalog_sync: bool) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try host.workspace.testPlainDirectory();
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", owned);
    const repo = try std.fs.path.join(owned, &.{ root, "repo" });
    const other = try std.fs.path.join(owned, &.{ root, "other" });
    const home = try std.fs.path.join(owned, &.{ root, "catalog" });
    const definition = try std.fs.path.join(owned, &.{ root, "definition.json" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "definition.json",
        .data = @embedFile("fixtures/event-definition.json"),
    });
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    try testBuildFamily(tmp.dir, &environment, root, repo, other, definition);
    if (!catalog_sync) try testSelectedPending(&environment, root, repo, other, definition);
    var unrelated = try host.initialize(allocator, io, &environment, .{ .catalog_root = home });
    defer unrelated.deinit();
    try tmp.dir.createDir(io, "plain", .default_dir);
    const pending = @import("host_pending.zig");
    var unrelated_pending = try pending.prepareTarget(allocator, io, &environment, .{
        .catalog_root = home,
        .workspace = try std.fs.path.join(owned, &.{ root, "plain" }),
    }, true);
    defer unrelated_pending.deinit();
    const options: host.Options = .{ .catalog_root = home, .workspace = other };
    var fault: AdoptionPublicationFault = .{ .io = io, .catalog_sync = catalog_sync };
    AdoptionPublicationFault.active = &fault;
    defer AdoptionPublicationFault.active = null;
    var vtable = io.vtable.*;
    vtable.dirRenamePreserve = AdoptionPublicationFault.renamePreserve;
    vtable.fileSync = AdoptionPublicationFault.sync;
    var injected = io;
    injected.vtable = &vtable;
    try std.testing.expectError(error.InputOutput, execute(
        allocator,
        injected,
        &environment,
        options,
        repo,
        &.{definition},
        true,
    ));
    try std.testing.expect(fault.fired and fault.published_id != null);
    const orphan = try std.fs.path.join(owned, &.{ home, "repos", &fault.published_id.? });
    try testRetainedAdoption(
        &environment,
        options,
        repo,
        definition,
        orphan,
        &fault.published_id.?,
    );
}

fn testRetainedAdoption(
    environment: *const std.process.Environ.Map,
    options: host.Options,
    source: []const u8,
    definition: []const u8,
    orphan: []const u8,
    id: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var before = try legacy.coldInventory(
        allocator,
        io,
        &.{orphan},
        &.{"example/events.jsonl"},
        .{},
    );
    defer before.deinit();
    for (0..100) |_| try std.testing.expectError(error.UnregisteredCustodyExists, execute(
        allocator,
        io,
        environment,
        options,
        source,
        &.{definition},
        true,
    ));
    var after = try legacy.coldInventory(
        allocator,
        io,
        &.{orphan},
        &.{"example/events.jsonl"},
        .{},
    );
    defer after.deinit();
    const expected = try before.json(allocator);
    defer allocator.free(expected);
    const actual = try after.json(allocator);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    {
        var lock = try host.catalog.Lock.acquire(io, options.catalog_root);
        defer lock.deinit();
        const repos = try lock.dir.openDir(io, "repos", .{ .iterate = true });
        defer repos.close(io);
        var entries = repos.iterate();
        var count: usize = 0;
        while (try entries.next(io)) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 3), count);
    }
    try testRegisterRetained(environment, options, orphan, id);
}

fn testRegisterRetained(
    environment: *const std.process.Environ.Map,
    options: host.Options,
    root: []const u8,
    id: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var registered = try host.registerRoot(allocator, io, environment, options, root, id);
    defer registered.deinit();
    var selected = try host.resolve(allocator, io, environment, options);
    defer selected.deinit();
    try std.testing.expectEqualStrings(id, selected.value.store_id);
    try std.testing.expectEqualStrings(root, selected.value.store_root);
}

fn testSelectedPending(
    environment: *const std.process.Environ.Map,
    root: []const u8,
    repo: []const u8,
    other: []const u8,
    definition: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const home = try std.fs.path.join(owned, &.{ root, "pending-catalog" });
    var associations = try host.workspace.resolve(allocator, io, environment, other);
    defer associations.deinit();
    const pending = @import("host_pending.zig");
    const controls_path = try pending.controlsPath(
        owned,
        other,
        associations.git_common_dir,
        home,
    );
    const controls = try host.catalog.openDirectory(io, controls_path, true);
    defer controls.close(io);
    const id = "0123456789abcdef0123456789abcdef";
    const target = try std.fs.path.join(owned, &.{ home, "repos", id });
    try host.catalog.writeJson(allocator, io, controls, "registration.json", pending.Registration{
        .schema = host.catalog.registration_schema,
        .store_id = id,
        .store_root = target,
        .workspace_root = associations.workspace_root.?,
        .git_common_dir = associations.git_common_dir,
    }, 4096);
    const before = try host.catalog.readBytes(owned, io, controls, "registration.json", 4096);
    for (0..3) |_| try std.testing.expectError(
        error.PendingInitializationRequiresPreparation,
        execute(
            allocator,
            io,
            environment,
            .{ .catalog_root = home, .workspace = repo },
            repo,
            &.{definition},
            true,
        ),
    );
    const after = try host.catalog.readBytes(owned, io, controls, "registration.json", 4096);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(!try host.catalog.exists(io, target));
}
