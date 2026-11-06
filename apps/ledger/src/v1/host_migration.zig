const std = @import("std");
const host = @import("host_context.zig");
const pending = @import("host_pending.zig");
const discovery = @import("host_sources.zig");
const legacy = @import("host_legacy.zig");
const migration_history = @import("host_migration_history.zig");
const owner_host = @import("host_owner.zig");
const cli = @import("cli.zig");
const engine = @import("ledger_v1_core");
const storage_root = @import("storage_root");
const definition_core = @import("definition_core");
const schema = "ledger-custody-migration/v2";

pub const Options = struct {
    context: host.Options,
    manifests: []const []const u8,
    apply: bool = false,
    confirm_no_writers: bool = false,
    framing_controls: ?[]const u8 = null,
    import_receipts: []const []const u8 = &.{},
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,
    exit_code: u8 = 0,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn put(self: *Result, key: []const u8, value: anytype) !void {
        const allocator = self.arena.allocator();
        try self.value.object.put(allocator, key, try jsonValue(allocator, value));
    }
};

const Descriptor = struct {
    name: []const u8,
    definition: []const u8,
    slots: []const []const u8,
    retired_sources: []const []const u8,
    importer: ?[]const u8,
    manifest_sha256: []const u8,
};

const Owner = struct {
    descriptor: Descriptor,
    manifest: []const u8,
    definition_sha256: []const u8,
    importer_sha256: ?[]const u8,
    plan: engine.compiled_plan.PlanSet,
    bindings: definition_core.parameters.Bindings,
    description: std.json.Value,

    fn history(self: *const Owner) migration_history.Owner {
        return .{
            .plan = &self.plan,
            .parameters = &self.bindings,
            .definition = self.descriptor.definition,
        };
    }
};

const Owners = struct {
    entries: []Owner,
    slots: []const []const u8,
    retired: []const []const u8,

    fn histories(
        self: Owners,
        buffer: *[128]migration_history.Owner,
    ) []const migration_history.Owner {
        std.debug.assert(self.entries.len <= buffer.len);
        for (self.entries, 0..) |*owner, index| buffer[index] = owner.history();
        return buffer[0..self.entries.len];
    }

    fn deinit(self: *Owners, allocator: std.mem.Allocator) void {
        for (self.entries) |*owner| {
            owner.bindings.deinit(allocator);
            owner.plan.deinit(allocator);
        }
    }
};

pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
) !Result {
    var result: Result = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .value = .{ .object = .{} },
    };
    errdefer result.deinit();
    try result.put("schema", schema);
    try result.put("storage_mutated", false);
    try result.put("authority_granted", false);
    run(allocator, &result, io, environment, options) catch |err| {
        result.exit_code = 3;
        try result.put("status", "blocked");
        try result.put("error_code", @errorName(err));
    };
    return result;
}

fn jsonValue(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    return std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        bytes,
        .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" },
    );
}

fn readValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
) !std.json.Value {
    const parsed = try host.catalog.readJson(std.json.Value, allocator, io, path, limit);
    return parsed.value;
}

fn string(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidMigrationDocument;
    const field = value.object.get(key) orelse return error.InvalidMigrationDocument;
    if (field != .string) return error.InvalidMigrationDocument;
    return field.string;
}

fn equalField(value: std.json.Value, key: []const u8, expected: []const u8) bool {
    const actual = string(value, key) catch return false;
    return std.mem.eql(u8, actual, expected);
}

fn digestPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const dir = try host.catalog.openDirectory(
        io,
        std.fs.path.dirname(path) orelse return error.InvalidPath,
        false,
    );
    defer dir.close(io);
    const witness = try legacy.hashFile(
        io,
        dir,
        std.fs.path.basename(path),
        2 * 1024 * 1024 * 1024,
    );
    return allocator.dupe(u8, &witness.sha256);
}

fn digestBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return allocator.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

fn canonical(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return definition_core.canonical_json.canonicalJsonAlloc(allocator, value);
}

fn loadOwners(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    paths: []const []const u8,
) !Owners {
    if (paths.len == 0 or paths.len > 128) return error.OwnerDiscoveryBoundExceeded;
    const ordered = try allocator.dupe([]const u8, paths);
    std.mem.sort([]const u8, ordered, {}, lessString);
    var loaded: std.ArrayList(Owner) = .empty;
    errdefer for (loaded.items) |*owner| {
        owner.bindings.deinit(scratch);
        owner.plan.deinit(scratch);
    };
    var slots: std.ArrayList([]const u8) = .empty;
    var retired: std.StringHashMapUnmanaged(void) = .empty;
    var claimed: std.StringHashMapUnmanaged(void) = .empty;
    for (ordered) |path| {
        var owner = try loadOwner(allocator, scratch, io, environment, path);
        errdefer owner.bindings.deinit(scratch);
        errdefer owner.plan.deinit(scratch);
        for (owner.descriptor.slots) |slot| {
            if (claimed.contains(slot)) return error.MultipleOwnersForSlot;
            try claimed.put(allocator, slot, {});
            try slots.append(allocator, slot);
        }
        for (owner.descriptor.retired_sources) |name| try retired.put(allocator, name, {});
        try loaded.append(allocator, owner);
    }
    const retired_paths = try allocator.alloc([]const u8, retired.count());
    var keys = retired.keyIterator();
    var index: usize = 0;
    while (keys.next()) |key| : (index += 1) retired_paths[index] = key.*;
    std.mem.sort([]const u8, retired_paths, {}, lessString);
    return .{
        .entries = try loaded.toOwnedSlice(allocator),
        .slots = try slots.toOwnedSlice(allocator),
        .retired = retired_paths,
    };
}

fn ownerPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    manifest: []const u8,
    relative_path: []const u8,
) ![]const u8 {
    try legacy.relative(relative_path);
    const path = try std.fs.path.join(
        allocator,
        &.{ std.fs.path.dirname(manifest).?, relative_path },
    );
    try host.catalog.noSymlinks(io, path);
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

fn ownerSlots(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value != .object) return error.UnsupportedOwnerLayout;
    const storage = value.object.get("storage") orelse return error.UnsupportedOwnerLayout;
    if (storage != .object) return error.UnsupportedOwnerLayout;
    const slots = storage.object.get("slots") orelse return error.UnsupportedOwnerLayout;
    if (slots != .object or slots.object.count() == 0) return error.UnsupportedOwnerLayout;
    var paths: std.ArrayList([]const u8) = .empty;
    for (slots.object.values()) |slot| {
        const path = try string(slot, "path");
        try legacy.relative(path);
        if (!equalField(slot, "kind", "event-log") or !equalField(slot, "codec", "jsonl") or
            std.mem.indexOfScalar(u8, path, '{') != null) return error.UnsupportedOwnerLayout;
        if (slot.object.get("layout")) |layout| {
            if (layout != .string or !std.mem.eql(u8, layout.string, "monolithic")) {
                return error.UnsupportedOwnerLayout;
            }
        }
        try paths.append(allocator, path);
    }
    return paths.toOwnedSlice(allocator);
}

fn describeOwner(
    allocator: std.mem.Allocator,
    plan: *const engine.compiled_plan.PlanSet,
) !std.json.Value {
    var output = std.Io.Writer.Allocating.init(allocator);
    try engine.envelope.writeDefinitionDescriptionJson(
        &output.writer,
        &plan.definition_plan,
        plan.stats,
    );
    return std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        output.written(),
        .{ .allocate = .alloc_always },
    );
}

fn loadOwner(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    manifest_path: []const u8,
) !Owner {
    if (!std.fs.path.isAbsolute(manifest_path)) return error.OwnerInputsMustBeAbsolute;
    const manifest_digest = try digestPath(allocator, io, manifest_path);
    const raw = try host.catalog.readJson(owner_host.Manifest, allocator, io, manifest_path, 16384);
    const definition = try ownerPath(allocator, io, manifest_path, raw.value.definition);
    const manifest = try owner_host.loadManifest(allocator, io, manifest_path, definition);
    const definition_digest = try digestPath(allocator, io, definition);
    const value = try readValue(allocator, io, definition, 32 * 1024 * 1024);
    const slots = try ownerSlots(allocator, value);
    const importer = if (manifest.value.importer) |path|
        try ownerPath(allocator, io, manifest_path, path)
    else
        null;
    var scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
    var plan = try cli.loadDefinitionWithCache(
        &scope,
        scratch,
        environment,
        definition,
        .{ .kind = .doctor },
        false,
    );
    errdefer plan.deinit(scratch);
    var bindings = try cli.bindParameters(
        scratch,
        &plan.definition_plan.parameter_declarations,
        &.{},
    );
    errdefer bindings.deinit(scratch);
    if (plan.storage_plan == null or plan.storage_plan.?.slots.len != slots.len) {
        return error.UnsupportedOwnerLayout;
    }
    const description = try describeOwner(allocator, &plan);
    if (!std.mem.eql(u8, manifest_digest, try digestPath(allocator, io, manifest_path)) or
        !std.mem.eql(u8, definition_digest, try digestPath(allocator, io, definition)))
    {
        return error.OwnerDefinitionChanged;
    }
    return .{
        .descriptor = .{
            .name = try allocator.dupe(u8, plan.definition_plan.owner),
            .definition = definition,
            .slots = slots,
            .retired_sources = manifest.value.retired_sources,
            .importer = importer,
            .manifest_sha256 = manifest_digest,
        },
        .manifest = manifest_path,
        .definition_sha256 = definition_digest,
        .importer_sha256 = if (importer) |path| try digestPath(allocator, io, path) else null,
        .plan = plan,
        .bindings = bindings,
        .description = description,
    };
}

fn sourceValue(allocator: std.mem.Allocator, snapshot: *const legacy.Inventory) !std.json.Value {
    return std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        try snapshot.json(allocator),
        .{ .allocate = .alloc_always },
    );
}

fn fingerprint(
    allocator: std.mem.Allocator,
    snapshot: *const legacy.Inventory,
    owners: Owners,
    framing: std.json.Value,
) ![]const u8 {
    var definitions: std.json.ObjectMap = .{};
    var importers: std.json.ObjectMap = .{};
    var descriptions: std.ArrayList(std.json.Value) = .empty;
    var descriptors: std.ArrayList(Descriptor) = .empty;
    for (owners.entries) |owner| {
        try descriptors.append(allocator, owner.descriptor);
        try definitions.put(
            allocator,
            owner.descriptor.definition,
            .{ .string = owner.definition_sha256 },
        );
        if (owner.descriptor.importer) |path| try importers.put(
            allocator,
            path,
            .{ .string = owner.importer_sha256.? },
        );
        try descriptions.append(allocator, owner.description.object.get("definition").?);
    }
    const first = try jsonValue(allocator, .{
        .sources = try sourceValue(allocator, snapshot),
        .owners = descriptors.items,
        .definitions = std.json.Value{ .object = definitions },
        .importers = std.json.Value{ .object = importers },
        .framing = framing,
    });
    const prefix = try digestBytes(allocator, try canonical(allocator, first));
    const suffix = try canonical(allocator, try jsonValue(allocator, descriptions.items));
    return digestBytes(allocator, try std.mem.concat(allocator, u8, &.{ prefix, suffix }));
}

fn inspectOwner(
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: *const Owner,
    root: []const u8,
    id: ?[]const u8,
) !engine.doctor.Result {
    if (id) |identity| {
        const control = try storage_root.checkedRoot(allocator, io, root, identity);
        defer control.close(io);
        var scope = storage_root.Scope.init(.anchored(io, control));
        return engine.doctor.execute(
            &scope,
            allocator,
            &owner.plan.definition_plan,
            &owner.plan.storage_plan.?,
            if (owner.plan.protocol_plan) |*protocol| protocol else null,
            ".",
            &owner.bindings,
        );
    }
    var scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
    return engine.doctor.execute(
        &scope,
        allocator,
        &owner.plan.definition_plan,
        &owner.plan.storage_plan.?,
        if (owner.plan.protocol_plan) |*protocol| protocol else null,
        root,
        &owner.bindings,
    );
}

fn inspectSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: *const legacy.Inventory,
    owners: Owners,
) !void {
    for (snapshot.sources.map.values()) |source| {
        for (owners.retired) |name| {
            const path = try std.fs.path.join(allocator, &.{ source.workspace, name });
            defer allocator.free(path);
            try host.catalog.noSymlinks(io, path);
            if (source.entries.map.get(name)) |entry| {
                if (!std.mem.eql(u8, entry.kind, "file")) return error.UnsupportedRetiredSource;
            }
        }
        for (source.entries.map.keys(), source.entries.map.values()) |name, entry| {
            if (std.mem.endsWith(u8, name, ".cas.lock")) return error.LegacyLeaseRequiresRecovery;
            if (!std.mem.startsWith(
                u8,
                name,
                ".ledger/",
            ) or !std.mem.eql(u8, entry.kind, "symlink")) continue;
            const local = name[8..];
            const first = if (std.mem.indexOfScalar(u8, local, '/')) |end| local[0..end] else local;
            if (std.mem.eql(u8, first, ".bindings") or std.mem.eql(u8, first, ".definitions") or
                std.mem.eql(u8, first, ".revisions")) return error.SymlinkInSelectedCustody;
        }
        for (owners.entries) |*owner| {
            var health = try inspectOwner(allocator, io, owner, source.workspace, null);
            defer health.deinit(allocator);
            if (health.pending_transactions != 0 or health.preparation_pending or
                health.storage_mutated)
            {
                return error.UnresolvedLegacyTransactionCoverage;
            }
        }
    }
}

fn reinspect(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    workspace_path: []const u8,
    coverage: *const discovery.Trees,
    snapshot: *const legacy.Inventory,
    owners: Owners,
) !void {
    var current = try discovery.trees(allocator, io, environment, workspace_path);
    defer current.deinit();
    if (!std.mem.eql(u8, current.workspace_root, coverage.workspace_root) or
        !host.catalog.optionalEqual(
            current.git_common_dir,
            coverage.git_common_dir,
        )) return error.MigrationSourceChanged;
    var fresh = try legacy.inventory(
        allocator,
        io,
        current.roots,
        owners.slots,
        owners.retired,
        .{},
    );
    defer fresh.deinit();
    const before = try snapshot.json(allocator);
    defer allocator.free(before);
    const after = try fresh.json(allocator);
    defer allocator.free(after);
    if (!std.mem.eql(u8, before, after)) return error.MigrationSourceChanged;
}

fn currentContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: host.Options,
    associations: *const host.workspace.Associations,
) !?host.Context {
    var selected: ?host.Context = host.resolve(
        allocator,
        io,
        environment,
        options,
    ) catch |err| switch (err) {
        error.UnregisteredContext => null,
        else => return err,
    };
    errdefer if (selected) |*value| value.deinit();
    if (associations.git_common_dir) |common| {
        const path = try std.fs.path.join(allocator, &.{ common, host.catalog.registration_name });
        defer allocator.free(path);
        if (try host.catalog.exists(io, path)) {
            var registration = try host.readRegistration(allocator, io, path);
            defer registration.deinit();
            var registered = try host.catalog.read(allocator, io, options.catalog_root);
            defer registered.deinit();
            var old = try host.checkedRoot(
                allocator,
                io,
                registration.value.store_root,
                registration.value.store_id,
                associations.workspace_root,
                common,
                false,
                try registered.containsStoreRoot(
                    allocator,
                    io,
                    registration.value.store_id,
                    registration.value.store_root,
                ),
            );
            if (selected) |current| {
                defer old.deinit();
                if (!sameContext(
                    current.value,
                    old.value,
                )) return error.ConflictingLegacyRegistration;
            } else selected = old;
        }
    }
    return selected;
}

fn sameContext(left: host.ContextValue, right: host.ContextValue) bool {
    return std.mem.eql(
        u8,
        left.store_id,
        right.store_id,
    ) and std.mem.eql(u8, left.store_root, right.store_root);
}

fn run(
    scratch: std.mem.Allocator,
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
) !void {
    if (options.apply and !options.confirm_no_writers) {
        return error.MigrationRequiresWriterQuiescence;
    }
    if (!options.apply and (options.confirm_no_writers or options.import_receipts.len != 0)) {
        return error.MigrationEffectsRequireApply;
    }
    const workspace_path = options.context.workspace orelse return error.MigrationRequiresWorkspace;
    const allocator = result.arena.allocator();
    var owners = try loadOwners(allocator, scratch, io, environment, options.manifests);
    defer owners.deinit(scratch);
    var trees = try discovery.trees(scratch, io, environment, workspace_path);
    defer trees.deinit();
    var snapshot = try legacy.inventory(
        scratch,
        io,
        trees.roots,
        owners.slots,
        owners.retired,
        .{},
    );
    defer snapshot.deinit();
    try inspectSources(scratch, io, &snapshot, owners);
    var owner_histories: [128]migration_history.Owner = undefined;
    const source = try migration_history.selectSource(
        scratch,
        io,
        environment,
        &snapshot,
        owners.histories(&owner_histories),
    );
    var associations = try host.workspace.resolve(scratch, io, environment, workspace_path);
    defer associations.deinit();
    var initial = try currentContext(scratch, io, environment, options.context, &associations);
    defer if (initial) |*value| value.deinit();
    const framing = if (options.framing_controls) |path|
        try readValue(allocator, io, path, 32 * 1024 * 1024)
    else
        std.json.Value{ .object = .{} };
    if (framing != .object) return error.InvalidFramingControls;
    const migration: Migration = .{
        .allocator = allocator,
        .scratch = scratch,
        .result = result,
        .io = io,
        .environment = environment,
        .options = options,
        .owners = owners,
        .trees = &trees,
        .snapshot = &snapshot,
        .associations = &associations,
        .initial = if (initial) |value| value.value else null,
        .source = source,
        .digest = try fingerprint(allocator, &snapshot, owners, framing),
    };
    try migration.describe();
    if (!options.apply) return migration.inspectReceipt();
    try migration.apply();
}

const Migration = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    owners: Owners,
    trees: *const discovery.Trees,
    snapshot: *const legacy.Inventory,
    associations: *const host.workspace.Associations,
    initial: ?host.ContextValue,
    source: ?usize,
    digest: []const u8,

    fn describe(self: Migration) !void {
        const result = self.result;
        try result.put("status", "planned");
        try result.put("registered", self.initial != null);
        try result.put("context", self.initial);
        try result.put("fingerprint", self.digest);
        try result.value.object.put(
            self.allocator,
            "sources",
            try sourceValue(self.allocator, self.snapshot),
        );
        try result.put("selected_source", if (self.source) |index|
            @as(?[]const u8, self.snapshot.sources.map.values()[index].workspace)
        else
            null);
        var descriptors: std.ArrayList(Descriptor) = .empty;
        var descriptions: std.ArrayList(std.json.Value) = .empty;
        for (self.owners.entries) |owner| {
            try descriptors.append(self.allocator, owner.descriptor);
            try descriptions.append(self.allocator, owner.description);
        }
        try result.put("owners", descriptors.items);
        try result.put("definitions", descriptions.items);
        try result.put("requires", [_][]const u8{ "--apply", "--confirm-no-writers" });
    }

    fn savedReceipt(self: Migration, selected: host.ContextValue) !?std.json.Value {
        return reusableReceipt(
            self.allocator,
            self.scratch,
            self.io,
            self.environment,
            selected,
            self.digest,
            self.owners,
            self.snapshot,
            self.source,
        );
    }

    fn inspectReceipt(self: Migration) !void {
        if (self.initial) |selected| if (try self.savedReceipt(selected)) |saved| {
            self.result.value = saved;
            try self.result.put("context", selected);
            try self.result.put("storage_mutated", false);
        };
    }

    fn inspectAgain(self: Migration) !void {
        try reinspect(
            self.scratch,
            self.io,
            self.environment,
            self.options.context.workspace.?,
            self.trees,
            self.snapshot,
            self.owners,
        );
    }

    fn checkOwners(self: Migration) !void {
        try checkOwnerInputs(self.allocator, self.scratch, self.io, self.environment, self.owners);
    }

    fn apply(self: Migration) !void {
        try self.result.put("storage_mutated", @as(?bool, null));
        const controls = try pending.controlsPath(
            self.allocator,
            self.associations.workspace_root.?,
            self.associations.git_common_dir,
            self.options.context.catalog_root,
        );
        const controls_dir = try host.catalog.openDirectory(self.io, controls, true);
        controls_dir.close(self.io);
        const guard_path = try std.fs.path.join(self.allocator, &.{
            self.associations.git_common_dir orelse controls, "ledger-store.lock",
        });
        var guard = try pending.Guard.acquire(self.io, guard_path);
        defer guard.deinit();
        var lock = try host.catalog.Lock.acquire(self.io, self.options.context.catalog_root);
        defer lock.deinit();
        var current = try currentContext(
            self.scratch,
            self.io,
            self.environment,
            self.options.context,
            self.associations,
        );
        defer if (current) |*value| value.deinit();
        if ((current == null) != (self.initial == null)) return error.MigrationIdentityChanged;
        if (current) |value| if (!sameContext(value.value, self.initial.?)) {
            return error.MigrationIdentityChanged;
        };
        try self.inspectAgain();
        var target: ?host.Context = null;
        defer if (target) |*value| value.deinit();
        const selected = if (current) |value| value.value else blk: {
            target = try pending.pendingTargetLocked(
                self.scratch,
                self.io,
                self.associations,
                self.options.context.catalog_root,
                controls,
                &lock,
            );
            break :blk target.?.value;
        };
        try pending.checkPendingContext(
            self.scratch,
            self.io,
            self.associations,
            self.options.context.catalog_root,
            selected,
        );
        try self.result.put("context", selected);
        if (try self.savedReceipt(selected)) |saved| {
            return self.reuseCompleted(selected, saved, &lock, &guard);
        }
        const archive_path = try self.archive(selected, current != null, &guard);
        if (!try self.importOwners(selected, archive_path)) return;
        try self.finish(selected, &lock);
        _ = try self.retireCopy(selected, &guard);
    }

    fn reuseCompleted(
        self: Migration,
        selected: host.ContextValue,
        saved: std.json.Value,
        lock: *const host.catalog.Lock,
        guard: *const pending.Guard,
    ) !void {
        try self.inspectAgain();
        try self.checkOwners();
        const changed = try publish(
            self.scratch,
            self.io,
            lock,
            self.associations,
            self.options.context.catalog_root,
            selected,
            self.result,
        );
        self.result.value = saved;
        var published = selected;
        published.cataloged = true;
        try self.result.put("context", published);
        const retired = try self.retireCopy(selected, guard);
        try self.result.put("storage_mutated", changed or retired);
    }

    fn retireCopy(self: Migration, selected: host.ContextValue, guard: *const pending.Guard) !bool {
        return pending.retireMigrationCopy(
            self.scratch,
            self.io,
            self.associations,
            self.options.context.catalog_root,
            selected,
            guard,
        );
    }

    fn archive(
        self: Migration,
        selected: host.ContextValue,
        registered: bool,
        guard: *const pending.Guard,
    ) ![]const u8 {
        const source_sha256 = if (self.source) |index|
            try copyInputDigest(self.allocator, self.snapshot, index, self.owners.slots)
        else
            null;
        const copy_owned = if (!registered) true else if (source_sha256) |digest|
            try pending.migrationCopyMatches(
                self.scratch,
                self.io,
                self.associations,
                self.options.context.catalog_root,
                selected,
                digest,
            )
        else
            false;
        try self.requireCoverage(selected, copy_owned, true);
        var copy_scratch: ?@import("host_migration_copy.zig").Scratch = null;
        defer if (copy_scratch) |scratch| scratch.deinit(self.io);
        if (copy_owned and source_sha256 != null) copy_scratch = try pending.migrationScratch(
            self.scratch,
            self.io,
            self.associations,
            self.options.context.catalog_root,
            selected,
            guard,
            source_sha256.?,
        );
        const path = try std.fs.path.join(
            self.allocator,
            &.{ selected.store_root, "legacy-archive", self.digest },
        );
        const archive_scratch = try pending.archiveScratch(
            self.scratch,
            self.io,
            self.associations,
            self.options.context.catalog_root,
            selected,
            guard,
        );
        defer archive_scratch.deinit(self.io);
        try legacy.archive(self.scratch, self.io, self.snapshot, path, archive_scratch);
        if (copy_scratch) |scratch| {
            try copyMissing(
                self.scratch,
                self.io,
                self.snapshot,
                self.source.?,
                self.owners.slots,
                path,
                selected.store_root,
                scratch,
            );
        }
        try self.result.put("storage_mutated", true);
        for (self.owners.entries) |*owner| {
            try healthy(self.scratch, self.io, self.environment, owner, selected, true);
        }
        try self.requireCoverage(selected, false, false);
        return path;
    }

    fn requireCoverage(
        self: Migration,
        selected: host.ContextValue,
        partial: bool,
        repair: bool,
    ) !void {
        var owner_histories: [128]migration_history.Owner = undefined;
        try migration_history.requireCovered(
            self.scratch,
            self.io,
            self.environment,
            self.owners.histories(&owner_histories),
            if (self.source) |index| self.snapshot.sources.map.values()[index].workspace else null,
            selected.store_root,
            selected.store_id,
            partial,
            repair,
        );
    }

    fn importOwners(self: Migration, selected: host.ContextValue, archive_path: []const u8) !bool {
        var imports: std.ArrayList(std.json.Value) = .empty;
        var required: std.ArrayList(std.json.Value) = .empty;
        const consumed = try self.allocator.alloc(bool, self.options.import_receipts.len);
        @memset(consumed, false);
        for (self.owners.entries) |*owner| {
            const sources = try retiredSources(
                self.allocator,
                self.snapshot,
                archive_path,
                owner.descriptor.retired_sources,
            );
            if (sources.len == 0) continue;
            const supplied = try self.importReceipt(selected, owner, sources, consumed);
            if (supplied) |receipt| {
                try imports.append(self.allocator, receipt);
            } else try required.append(self.allocator, try jsonValue(self.allocator, .{
                .manifest = owner.manifest,
                .definition = owner.descriptor.definition,
                .importer = owner.descriptor.importer,
                .sources = sources,
                .store_root = selected.store_root,
                .store_id = selected.store_id,
            }));
        }
        for (consumed) |used| if (!used) return error.UnmatchedOwnerImportReceipt;
        try self.inspectAgain();
        try self.checkOwners();
        try self.result.put("imports", imports.items);
        if (required.items.len == 0) return true;
        self.result.exit_code = 3;
        try self.result.put("status", "owner-import-required");
        try self.result.put("owner_imports", required.items);
        return false;
    }

    fn importReceipt(
        self: Migration,
        selected: host.ContextValue,
        owner: *const Owner,
        sources: []const ImportSource,
        consumed: []bool,
    ) !?std.json.Value {
        var supplied: ?std.json.Value = null;
        for (self.options.import_receipts, 0..) |path, index| {
            const receipt = try readValue(self.allocator, self.io, path, 32 * 1024 * 1024);
            if (!equalField(receipt, "definition_path", owner.descriptor.definition)) continue;
            if (supplied != null) return error.DuplicateOwnerImportReceipt;
            try validateImportReceipt(self.scratch, self.io, receipt, owner, selected, sources);
            supplied = receipt;
            consumed[index] = true;
        }
        return supplied;
    }

    fn finish(self: Migration, selected: host.ContextValue, lock: *const host.catalog.Lock) !void {
        for (self.owners.entries) |*owner| {
            try healthy(self.scratch, self.io, self.environment, owner, selected, false);
        }
        try self.requireCoverage(selected, false, false);
        const result = self.result;
        try result.put("status", "verified");
        try result.put("store_id", selected.store_id);
        try result.value.object.put(
            self.allocator,
            "destination_prefixes",
            try destinationPrefixes(
                self.allocator,
                self.io,
                self.owners.slots,
                selected.store_root,
            ),
        );
        try result.put(
            "unselected_disposition",
            "preserved in source and archive; not semantically imported",
        );
        _ = result.value.object.swapRemove("requires");
        _ = result.value.object.swapRemove("registered");
        _ = result.value.object.swapRemove("selected_source");
        var saved = try jsonValue(self.allocator, result.value);
        _ = saved.object.swapRemove("context");
        const root = try host.catalog.openDirectory(self.io, selected.store_root, false);
        defer root.close(self.io);
        try host.catalog.writeJson(
            self.scratch,
            self.io,
            root,
            "migration-receipt.json",
            saved,
            64 * 1024 * 1024,
        );
        try self.inspectAgain();
        _ = try publish(
            self.scratch,
            self.io,
            lock,
            self.associations,
            self.options.context.catalog_root,
            selected,
            self.result,
        );
        var published = selected;
        published.cataloged = true;
        try result.put("context", published);
    }
};

fn healthy(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    owner: *const Owner,
    selected: host.ContextValue,
    repair: bool,
) !void {
    for (0..2) |attempt| {
        var health = try inspectOwner(allocator, io, owner, selected.store_root, selected.store_id);
        defer health.deinit(allocator);
        if (health.pending_transactions != 0 or health.preparation_pending or
            health.storage_mutated)
        {
            return error.UnresolvedCustodyTransaction;
        }
        if (health.healthy) return;
        if (!repair or attempt != 0 or health.slots.len != 1 or owner.descriptor.slots.len != 1) {
            return error.OwnerCustodyRequiresMaintenance;
        }
        const failure = health.slots[0].error_code orelse return error.UnknownBindingFailure;
        const operation = try migration_history.maintenanceName(failure);
        try repairBinding(allocator, io, environment, owner, selected, operation);
    }
    unreachable;
}

fn repairBinding(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    owner: *const Owner,
    selected: host.ContextValue,
    operation: []const u8,
) !void {
    const event_path = try std.fs.path.join(
        allocator,
        &.{ selected.store_root, ".ledger", owner.descriptor.slots[0] },
    );
    defer allocator.free(event_path);
    const before = try digestPath(allocator, io, event_path);
    defer allocator.free(before);
    var input_scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
    var plan = try cli.loadDefinitionWithCache(
        &input_scope,
        allocator,
        environment,
        owner.descriptor.definition,
        .{ .kind = .transact, .name = operation },
        false,
    );
    defer plan.deinit(allocator);
    try migration_history.checkMaintenanceOperation(&plan, owner.history(), operation);
    const control = try storage_root.checkedRoot(
        allocator,
        io,
        selected.store_root,
        selected.store_id,
    );
    defer control.close(io);
    try transactMaintenance(allocator, io, &plan, control, operation);
    const after = try digestPath(allocator, io, event_path);
    defer allocator.free(after);
    if (!std.mem.eql(u8, before, after)) return error.BindingMaintenanceChangedEvents;
    const current = try storage_root.checkedRoot(
        allocator,
        io,
        selected.store_root,
        selected.store_id,
    );
    defer current.close(io);
    if (!try @import("durable_store").sameDirectoryObject(io, control, current)) {
        return error.StorageRootChanged;
    }
}

fn transactMaintenance(
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: *const engine.compiled_plan.PlanSet,
    control: std.Io.Dir,
    operation: []const u8,
) !void {
    var bindings = try cli.bindParameters(
        allocator,
        &plan.definition_plan.parameter_declarations,
        &.{},
    );
    defer bindings.deinit(allocator);
    var scope = storage_root.Scope.init(.anchored(io, control));
    var repaired = try engine.transaction.transact(
        &scope,
        allocator,
        &plan.definition_plan,
        &plan.closure,
        plan.entry_path,
        &(plan.validation_plan orelse return error.UnsupportedBindingMaintenance),
        &(plan.storage_plan orelse return error.UnsupportedBindingMaintenance),
        if (plan.protocol_plan) |*protocol| protocol else null,
        operation,
        ".",
        &.{},
        &bindings,
    );
    defer repaired.deinit(allocator);
    if (!repaired.validation_result.valid or repaired.effects.len != 1) {
        return error.UnverifiedBindingMaintenance;
    }
}

fn targetEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    slot: []const u8,
) !?legacy.Entry {
    const path = try std.fs.path.join(allocator, &.{ root, ".ledger", slot });
    defer allocator.free(path);
    try host.catalog.noSymlinks(io, path);
    const dir = host.catalog.openDirectory(
        io,
        std.fs.path.dirname(path).?,
        false,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    const witness = legacy.hashFile(
        io,
        dir,
        std.fs.path.basename(path),
        2 * 1024 * 1024 * 1024,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return .{
        .kind = "file",
        .size = witness.bytes,
        .sha256 = try allocator.dupe(u8, &witness.sha256),
    };
}

fn copyMissing(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: *const legacy.Inventory,
    index: usize,
    slots: []const []const u8,
    archive: []const u8,
    root: []const u8,
    scratch: @import("host_migration_copy.zig").Scratch,
) !void {
    var missing: legacy.Inventory = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .sources = .{},
        .file_count = 0,
        .total_bytes = 0,
    };
    defer missing.deinit();
    const owned = missing.arena.allocator();
    const selected = snapshot.sources.map.values()[index];
    var source: legacy.Source = .{ .workspace = selected.workspace };
    for (selected.entries.map.keys(), selected.entries.map.values()) |name, entry| {
        const selected_slot = (try selectedCopyEntry(name, entry, slots)) orelse continue;
        const path = try std.fs.path.join(owned, &.{ root, name });
        try host.catalog.noSymlinks(io, path);
        if (try host.catalog.exists(io, path)) {
            try verifyExistingCopy(owned, io, selected.workspace, root, name, entry, selected_slot);
            continue;
        }
        try source.entries.map.put(owned, name, entry);
    }
    try missing.sources.map.put(owned, snapshot.sources.map.keys()[index], source);
    try legacy.copySelected(allocator, io, &missing, 0, slots, archive, root, scratch);
}

fn selectedCopyEntry(name: []const u8, entry: legacy.Entry, slots: []const []const u8) !?bool {
    if (!std.mem.startsWith(u8, name, ".ledger/")) return null;
    const local = name[8..];
    var selected_slot = false;
    for (slots) |slot| selected_slot = selected_slot or std.mem.eql(u8, local, slot);
    const first = if (std.mem.indexOfScalar(u8, local, '/')) |end| local[0..end] else local;
    const control = std.mem.eql(u8, first, ".bindings") or
        std.mem.eql(u8, first, ".definitions") or std.mem.eql(u8, first, ".revisions");
    if (!selected_slot and !control) return null;
    if (std.mem.eql(u8, entry.kind, "symlink")) return error.SymlinkInSelectedCustody;
    if (!std.mem.eql(u8, entry.kind, "file") or
        std.mem.endsWith(u8, name, ".cas.lock.advisory")) return null;
    return selected_slot;
}

fn copyInputDigest(
    allocator: std.mem.Allocator,
    snapshot: *const legacy.Inventory,
    index: usize,
    slots: []const []const u8,
) ![]const u8 {
    const Entry = struct { size: u64, sha256: []const u8 };
    var selected: std.json.ArrayHashMap(Entry) = .{};
    defer selected.deinit(allocator);
    const source = snapshot.sources.map.values()[index];
    for (source.entries.map.keys(), source.entries.map.values()) |name, entry| {
        if (try selectedCopyEntry(name, entry, slots) == null) continue;
        try selected.map.put(allocator, name, .{
            .size = entry.size orelse return error.InvalidLegacyManifest,
            .sha256 = entry.sha256 orelse return error.InvalidLegacyManifest,
        });
    }
    const bytes = try legacy.canonicalAlloc(allocator, selected);
    defer allocator.free(bytes);
    return @import("definition_core").canonical_json.digestBytesAlloc(allocator, bytes);
}

fn verifyExistingCopy(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    root: []const u8,
    name: []const u8,
    entry: legacy.Entry,
    selected_slot: bool,
) !void {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(path);
    if ((try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false })).kind != .file) {
        return error.UnsupportedSelectedSlot;
    }
    const parent = try host.catalog.openDirectory(io, std.fs.path.dirname(path).?, false);
    defer parent.close(io);
    if (selected_slot) {
        const active = (try targetEntry(allocator, io, root, name[8..])).?;
        defer allocator.free(active.sha256.?);
        if (!try legacy.completePrefix(allocator, io, source, root, name, entry, active)) {
            return error.AdditionalOrDivergentHistory;
        }
    } else if (!std.mem.startsWith(u8, name, ".ledger/.bindings/")) {
        const active = try legacy.hashFile(io, parent, std.fs.path.basename(path), entry.size.?);
        if (active.bytes != entry.size.? or !std.mem.eql(u8, &active.sha256, entry.sha256.?)) {
            return error.AdditionalOrDivergentHistory;
        }
    }
    try host.catalog.sync(io, parent);
}

const ImportSource = struct { source: []const u8, source_sha256: []const u8 };

fn retiredSources(
    allocator: std.mem.Allocator,
    snapshot: *const legacy.Inventory,
    archive: []const u8,
    paths: []const []const u8,
) ![]const ImportSource {
    var sources: std.ArrayList(ImportSource) = .empty;
    for (snapshot.sources.map.keys(), snapshot.sources.map.values()) |index, tree| {
        for (paths) |path| {
            const entry = tree.entries.map.get(path) orelse continue;
            std.debug.assert(std.mem.eql(u8, entry.kind, "file"));
            try sources.append(allocator, .{
                .source = try std.fmt.allocPrint(
                    allocator,
                    "{s}/worktree-{s}/{s}",
                    .{ archive, index, path },
                ),
                .source_sha256 = entry.sha256.?,
            });
        }
    }
    return sources.toOwnedSlice(allocator);
}

fn validateImportReceipt(
    allocator: std.mem.Allocator,
    io: std.Io,
    receipt: std.json.Value,
    owner: *const Owner,
    selected: host.ContextValue,
    expected_sources: []const ImportSource,
) !void {
    if (!equalField(receipt, "status", "verified") or (try string(receipt, "schema")).len == 0 or
        !equalField(
            receipt,
            "store_root",
            selected.store_root,
        ) or !equalField(receipt, "store_id", selected.store_id) or
        !equalField(
            receipt,
            "definition_path",
            owner.descriptor.definition,
        )) return error.OwnerImportReceiptScopeMismatch;
    const authority = receipt.object.get("authority_granted") orelse
        return error.OwnerImportReceiptScopeMismatch;
    if (authority != .bool or authority.bool) return error.OwnerImportReceiptScopeMismatch;
    const parity = receipt.object.get("full_record_parity_verified") orelse
        return error.OwnerImportParityUnverified;
    if (parity != .bool or !parity.bool) return error.OwnerImportParityUnverified;
    const definition = receipt.object.get("definition") orelse
        return error.OwnerImportReceiptScopeMismatch;
    if (!equalField(definition, "id", owner.plan.definition_plan.id) or
        !equalField(
            definition,
            "digest",
            &owner.plan.definition_plan.closure_digest,
        )) return error.OwnerImportReceiptScopeMismatch;
    const sources = receipt.object.get("sources") orelse return error.OwnerImportSourcesMismatch;
    if (sources != .array or sources.array.items.len != expected_sources.len) {
        return error.OwnerImportSourcesMismatch;
    }
    for (expected_sources) |expected| {
        var matches: usize = 0;
        for (sources.array.items) |actual| {
            if (equalField(
                actual,
                "source",
                expected.source,
            ) and equalField(actual, "source_sha256", expected.source_sha256)) matches += 1;
        }
        if (matches != 1) return error.OwnerImportSourcesMismatch;
    }
    var health = try inspectOwner(allocator, io, owner, selected.store_root, selected.store_id);
    defer health.deinit(allocator);
    if (!health.healthy or health.pending_transactions != 0 or health.preparation_pending or
        health.slots.len != owner.plan.storage_plan.?.slots.len)
    {
        return error.OwnerImportRevisionMismatch;
    }
    if (health.slots.len == 1) {
        return validateImportRevision(
            health.slots[0].revision,
            receipt.object.get("revision") orelse return error.OwnerImportRevisionMismatch,
        );
    }
    const revisions = receipt.object.get("revisions") orelse
        return error.OwnerImportRevisionMismatch;
    if (revisions != .object or revisions.object.count() != health.slots.len)
        return error.OwnerImportRevisionMismatch;
    for (health.slots) |slot| try validateImportRevision(
        slot.revision,
        revisions.object.get(slot.logical_ref) orelse return error.OwnerImportRevisionMismatch,
    );
}

fn validateImportRevision(current_revision: ?[]const u8, revision: std.json.Value) !void {
    if (current_revision) |current| {
        if (revision != .string or !std.mem.eql(
            u8,
            revision.string,
            current,
        )) return error.OwnerImportRevisionMismatch;
    } else if (revision != .null) return error.OwnerImportRevisionMismatch;
}

fn destinationPrefixes(
    allocator: std.mem.Allocator,
    io: std.Io,
    slots: []const []const u8,
    root: []const u8,
) !std.json.Value {
    var prefixes: std.json.ObjectMap = .{};
    for (slots) |slot| {
        const entry = try targetEntry(allocator, io, root, slot);
        try prefixes.put(
            allocator,
            slot,
            if (entry) |value| try jsonValue(
                allocator,
                .{ .bytes = value.size.?, .sha256 = value.sha256.? },
            ) else .null,
        );
    }
    return .{ .object = prefixes };
}

fn prefixDigest(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: u64) ![64]u8 {
    const parent = try host.catalog.openDirectory(io, std.fs.path.dirname(path).?, false);
    defer parent.close(io);
    const fd = try std.posix.openat(
        parent.handle,
        std.fs.path.basename(path),
        .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true },
        0,
    );
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size < bytes) return error.DestinationPrefixChanged;
    _ = allocator;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var remaining = bytes;
    while (remaining != 0) {
        const size: usize = @intCast(@min(remaining, buffer.len));
        const count = file.readStreaming(io, &.{buffer[0..size]}) catch |err| switch (err) {
            error.EndOfStream => return error.DestinationPrefixChanged,
            else => return err,
        };
        if (count == 0) return error.DestinationPrefixChanged;
        hash.update(buffer[0..count]);
        remaining -= count;
    }
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

fn preservedPrefixes(
    allocator: std.mem.Allocator,
    io: std.Io,
    selected: host.ContextValue,
    slots: []const []const u8,
    witnesses: std.json.Value,
) !bool {
    if (witnesses != .object or witnesses.object.count() != slots.len) return false;
    for (slots) |slot| {
        const witness = witnesses.object.get(slot) orelse return false;
        if (witness == .null) continue;
        if (witness != .object or witness.object.count() != 2) return false;
        const bytes = witness.object.get("bytes") orelse return false;
        const digest = witness.object.get("sha256") orelse return false;
        if (bytes != .integer or bytes.integer < 0 or digest != .string) return false;
        const path = try std.fs.path.join(allocator, &.{ selected.store_root, ".ledger", slot });
        defer allocator.free(path);
        const current = prefixDigest(
            allocator,
            io,
            path,
            @intCast(bytes.integer),
        ) catch |err| switch (err) {
            error.FileNotFound, error.DestinationPrefixChanged => return false,
            else => return err,
        };
        if (!std.mem.eql(u8, &current, digest.string)) return false;
    }
    return true;
}

fn reusableReceipt(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    selected: host.ContextValue,
    digest: []const u8,
    owners: Owners,
    snapshot: *const legacy.Inventory,
    source: ?usize,
) !?std.json.Value {
    const path = try std.fs.path.join(
        allocator,
        &.{ selected.store_root, "migration-receipt.json" },
    );
    if (!try host.catalog.exists(io, path)) return null;
    const saved = try readValue(allocator, io, path, 64 * 1024 * 1024);
    if (!equalField(saved, "schema", schema) or !equalField(saved, "status", "verified") or
        !equalField(
            saved,
            "store_id",
            selected.store_id,
        ) or !equalField(saved, "fingerprint", digest)) return null;
    const prefixes = saved.object.get("destination_prefixes") orelse return null;
    if (!try preservedPrefixes(scratch, io, selected, owners.slots, prefixes)) return null;
    for (owners.entries) |*owner| {
        var health = try inspectOwner(scratch, io, owner, selected.store_root, selected.store_id);
        defer health.deinit(scratch);
        if (!health.healthy or health.pending_transactions != 0 or
            health.preparation_pending or health.storage_mutated)
        {
            return error.OwnerCustodyRequiresMaintenance;
        }
    }
    var owner_histories: [128]migration_history.Owner = undefined;
    try migration_history.requireCovered(
        scratch,
        io,
        environment,
        owners.histories(&owner_histories),
        if (source) |index| snapshot.sources.map.values()[index].workspace else null,
        selected.store_root,
        selected.store_id,
        false,
        false,
    );
    const archive = try std.fs.path.join(
        scratch,
        &.{ selected.store_root, "legacy-archive", digest },
    );
    defer scratch.free(archive);
    try legacy.verifyArchive(scratch, io, snapshot, archive);
    return saved;
}

fn checkOwnerInputs(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    owners: Owners,
) !void {
    for (owners.entries) |owner| {
        if (!std.mem.eql(
            u8,
            try digestPath(allocator, io, owner.manifest),
            owner.descriptor.manifest_sha256,
        ) or
            !std.mem.eql(
                u8,
                try digestPath(allocator, io, owner.descriptor.definition),
                owner.definition_sha256,
            )) return error.OwnerDefinitionChanged;
        if (owner.descriptor.importer) |path| if (!std.mem.eql(
            u8,
            try digestPath(allocator, io, path),
            owner.importer_sha256.?,
        )) return error.OwnerImporterChanged;
        var scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
        var current = try cli.loadDefinitionWithCache(
            &scope,
            scratch,
            environment,
            owner.descriptor.definition,
            .{ .kind = .doctor },
            false,
        );
        defer current.deinit(scratch);
        if (!std.mem.eql(
            u8,
            &current.definition_plan.closure_digest,
            &owner.plan.definition_plan.closure_digest,
        )) return error.OwnerDefinitionChanged;
    }
}

fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    lock: *const host.catalog.Lock,
    associations: *const host.workspace.Associations,
    home: []const u8,
    selected: host.ContextValue,
    result: *Result,
) !bool {
    var cataloged = selected.cataloged;
    defer {
        const retained_context = result.value.object.getPtr("context").?;
        retained_context.object.getPtr("cataloged").?.* = .{ .bool = cataloged };
    }
    const control = try host.catalog.checkedRoot(
        allocator,
        io,
        selected.store_root,
        selected.store_id,
    );
    defer control.close(io);
    return host.associateRootLocked(
        allocator,
        io,
        lock,
        associations,
        home,
        selected.store_root,
        selected.store_id,
        control,
        &cataloged,
    );
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    parent: std.Io.Dir,
    name: [32]u8,
    root: []const u8,
    source: []const u8,
    home: []const u8,
    manifest: []const u8,
    environment: std.process.Environ.Map,

    fn init(retired: bool) !Fixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const parent = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
        errdefer parent.close(io);
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const name = std.fmt.bytesToHex(random, .lower);
        try parent.createDir(io, &name, .fromMode(0o700));
        errdefer parent.deleteTree(
            io,
            &name,
        ) catch |err| std.debug.panic("fixture cleanup failed: {s}", .{@errorName(err)});
        const dir = try parent.openDir(io, &name, .{});
        defer dir.close(io);
        const root = try dir.realPathFileAlloc(io, ".", owned);
        const source = try std.fs.path.join(owned, &.{ root, "source" });
        const home = try std.fs.path.join(owned, &.{ root, "home" });
        const manifest = try std.fs.path.join(owned, &.{ root, "owner/migration.json" });
        try fixtureWrite(
            root,
            "owner/definition.json",
            @embedFile("fixtures/plain-event-definition.json"),
        );
        try fixtureWrite(root, "owner/migration.json", if (retired)
            "{\"schema\":\"ledger-owner-migration/v1\"" ++
                ",\"definition\":\"definition.json\",\"retired_sources\":[\".retired.jsonl\"]" ++
                ",\"importer\":\"importer.py\"}"
        else
            "{\"schema\":\"ledger-owner-migration/v1\"" ++
                ",\"definition\":\"definition.json\",\"retired_sources\":[],\"importer\":null}");
        if (retired) {
            try fixtureWrite(root, "owner/importer.py", "owner-controlled opaque importer\n");
            try fixtureWrite(source, ".retired.jsonl", "{\"id\":\"historical\"}\n");
        }
        try fixtureWrite(
            source,
            ".ledger/example/plain.jsonl",
            "{\"kind\":\"created\",\"value\":{\"id\":\"one\",\"revision\":\"r1\"}}\n",
        );
        try fixtureWrite(source, ".ledger/unselected/payload", "retained original bytes\n");
        const source_dir = try host.catalog.openDirectory(io, source, false);
        defer source_dir.close(io);
        try source_dir.symLink(io, "/missing/external", ".ledger/unselected/link", .{});
        return .{
            .arena = arena,
            .parent = parent,
            .name = name,
            .root = root,
            .source = source,
            .home = home,
            .manifest = manifest,
            .environment = std.process.Environ.Map.init(allocator),
        };
    }

    fn deinit(self: *Fixture) void {
        self.environment.deinit();
        self.parent.deleteTree(
            std.testing.io,
            &self.name,
        ) catch |err| std.debug.panic("fixture cleanup failed: {s}", .{@errorName(err)});
        self.parent.close(std.testing.io);
        self.arena.deinit();
    }

    fn options(self: *const Fixture, apply: bool) Options {
        return .{
            .context = .{ .catalog_root = self.home, .workspace = self.source },
            .manifests = (&self.manifest)[0..1],
            .apply = apply,
            .confirm_no_writers = apply,
        };
    }
};

fn fixtureWrite(root: []const u8, name: []const u8, bytes: []const u8) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = try std.fs.path.join(allocator, &.{ root, std.fs.path.dirname(name) orelse "" });
    defer allocator.free(path);
    const dir = try host.catalog.openDirectory(io, path, true);
    defer dir.close(io);
    const file = try dir.createFile(io, std.fs.path.basename(name), .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn expectStatus(result: Result, expected: []const u8) !void {
    if (!equalField(result.value, "status", expected)) {
        const rendered = try canonical(std.testing.allocator, result.value);
        defer std.testing.allocator.free(rendered);
        std.debug.print("unexpected migration result: {s}\n", .{rendered});
    }
    try std.testing.expectEqualStrings(expected, try string(result.value, "status"));
}

test "host migration retries interrupted copy in the same pending identity" {
    const copy = @import("host_migration_copy.zig");
    for ([_]bool{ false, true }) |registered| {
        for (std.enums.values(copy.TestFault.Kind)) |fault|
            try testCopyInterruption(fault, registered);
    }
}

fn testCopyInterruption(
    fault: @import("host_migration_copy.zig").TestFault.Kind,
    registered: bool,
) !void {
    const copy = @import("host_migration_copy.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var vtable = io.vtable.*;
    copy.TestFault.install(&vtable, fault);
    var injected = io;
    injected.vtable = &vtable;
    var failed = try execute(allocator, injected, &fixture.environment, fixture.options(true));
    defer failed.deinit();
    try expectStatus(failed, "blocked");
    try std.testing.expect(copy.TestFault.reached);
    const selected = failed.value.object.get("context").?;
    const root = try string(selected, "store_root");
    const dir = try host.catalog.openDirectory(io, root, false);
    defer dir.close(io);
    const published = fault == .after_rename or fault == .directory_sync;
    try std.testing.expectEqual(
        published,
        try host.catalog.existsAt(io, dir, ".ledger/example/plain.jsonl"),
    );
    const source = try host.catalog.openDirectory(io, fixture.source, false);
    defer source.close(io);
    const before = try testHash(source, ".ledger/example/plain.jsonl");
    if (registered) {
        var associated = try host.registerRoot(
            allocator,
            io,
            &fixture.environment,
            fixture.options(true).context,
            root,
            try string(selected, "store_id"),
        );
        defer associated.deinit();
    }
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "verified");
    const resumed = retry.value.object.get("context").?;
    try std.testing.expectEqualStrings(
        try string(selected, "store_id"),
        try string(resumed, "store_id"),
    );
    try std.testing.expectEqualStrings(root, try string(resumed, "store_root"));
    const after = try testHash(dir, ".ledger/example/plain.jsonl");
    try std.testing.expectEqualDeep(before, after);
    const unchanged = try testHash(source, ".ledger/example/plain.jsonl");
    try std.testing.expectEqualDeep(before, unchanged);
    const archive_name = try std.fmt.allocPrint(
        allocator,
        "legacy-archive/{s}/worktree-0/.ledger/example/plain.jsonl",
        .{try string(retry.value, "fingerprint")},
    );
    defer allocator.free(archive_name);
    try std.testing.expectEqualDeep(before, try testHash(dir, archive_name));
    try std.testing.expect(!try host.catalog.existsAt(io, dir, ".migration-copy/payload"));
    try std.testing.expect(!try host.catalog.existsAt(io, dir, ".migration-copy"));
}

fn testHash(root: std.Io.Dir, path: []const u8) !legacy.Witness {
    const dir = try root.openDir(std.testing.io, std.fs.path.dirname(path).?, .{});
    defer dir.close(std.testing.io);
    return legacy.hashFile(std.testing.io, dir, std.fs.path.basename(path), 4096);
}

test "host migration publishes a saved receipt without retaining pending catalog state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var vtable = io.vtable.*;
    vtable.dirRename = struct {
        fn rename(
            userdata: ?*anyopaque,
            from: std.Io.Dir,
            name: []const u8,
            to: std.Io.Dir,
            leaf: []const u8,
        ) std.Io.Dir.RenameError!void {
            if (std.mem.eql(u8, leaf, "catalog.json")) return error.HardwareFailure;
            return std.testing.io.vtable.dirRename(userdata, from, name, to, leaf);
        }
    }.rename;
    var injected = io;
    injected.vtable = &vtable;
    var failed = try execute(allocator, injected, &fixture.environment, fixture.options(true));
    defer failed.deinit();
    try expectStatus(failed, "blocked");
    try std.testing.expectEqualStrings("HardwareFailure", try string(failed.value, "error_code"));
    const selected = failed.value.object.get("context").?;
    try std.testing.expect(!selected.object.get("cataloged").?.bool);
    const root = try host.catalog.openDirectory(io, try string(selected, "store_root"), false);
    defer root.close(io);
    try std.testing.expect(try host.catalog.existsAt(io, root, "migration-receipt.json"));
    var before = try host.list(allocator, io, fixture.home);
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 0), before.value.stores.len);
    vtable = io.vtable.*;
    vtable.dirDeleteDir = struct {
        fn remove(
            userdata: ?*anyopaque,
            directory: std.Io.Dir,
            name: []const u8,
        ) std.Io.Dir.DeleteDirError!void {
            if (std.mem.eql(u8, name, ".migration-copy")) return error.AccessDenied;
            return std.testing.io.vtable.dirDeleteDir(userdata, directory, name);
        }
    }.remove;
    var cleanup = try execute(allocator, injected, &fixture.environment, fixture.options(true));
    defer cleanup.deinit();
    try expectStatus(cleanup, "blocked");
    try std.testing.expectEqualStrings("AccessDenied", try string(cleanup.value, "error_code"));
    try std.testing.expect(cleanup.value.object.get("context").?.object.get("cataloged").?.bool);
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "verified");
    const resumed = retry.value.object.get("context").?;
    try std.testing.expect(resumed.object.get("cataloged").?.bool);
    try std.testing.expectEqualStrings(
        try string(selected, "store_id"),
        try string(resumed, "store_id"),
    );
    try std.testing.expectEqualStrings(
        try string(selected, "store_root"),
        try string(resumed, "store_root"),
    );
    var after = try host.list(allocator, io, fixture.home);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.value.stores.len);
    try std.testing.expectEqualStrings(
        try string(resumed, "store_id"),
        after.value.stores[0].store_id,
    );
}

test "host migration current history archives broad material repairs bindings and reuses receipt" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var inspection = try execute(allocator, io, &fixture.environment, fixture.options(false));
    defer inspection.deinit();
    try expectStatus(inspection, "planned");
    try std.testing.expect(!try host.catalog.exists(io, fixture.home));
    const owners = inspection.value.object.get("owners").?;
    try std.testing.expect(owners.array.items[0].object.get("importer").? == .null);
    const original = try digestPath(
        allocator,
        io,
        try fixture.arena.allocator().print("{s}/.ledger/example/plain.jsonl", .{fixture.source}),
    );
    defer allocator.free(original);
    var applied = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer applied.deinit();
    try expectStatus(applied, "verified");
    const selected = applied.value.object.get("context").?;
    try std.testing.expect(selected.object.get("cataloged").?.bool);
    const custody = try string(selected, "store_root");
    const fingerprint_value = try string(applied.value, "fingerprint");
    const archive = try std.fmt.allocPrint(
        allocator,
        "{s}/legacy-archive/{s}",
        .{ custody, fingerprint_value },
    );
    defer allocator.free(archive);
    const dir = try host.catalog.openDirectory(io, archive, false);
    defer dir.close(io);
    try std.testing.expect(try host.catalog.existsAt(
        io,
        dir,
        "worktree-0/.ledger/unselected/payload",
    ));
    try std.testing.expect(!try host.catalog.existsAt(
        io,
        dir,
        "worktree-0/.ledger/unselected/link",
    ));
    const active = try host.catalog.openDirectory(io, custody, false);
    defer active.close(io);
    try std.testing.expect(!try host.catalog.existsAt(io, active, ".ledger/unselected"));
    const unchanged = try digestPath(
        allocator,
        io,
        try fixture.arena.allocator().print("{s}/.ledger/example/plain.jsonl", .{fixture.source}),
    );
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);
    var repeated = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer repeated.deinit();
    try expectStatus(repeated, "verified");
    try std.testing.expect(repeated.value.object.get("context").?.object.get("cataloged").?.bool);
    try std.testing.expect(!repeated.value.object.get("storage_mutated").?.bool);
    try std.testing.expectEqualStrings(
        fingerprint_value,
        try string(repeated.value, "fingerprint"),
    );
    try std.testing.expectEqualStrings(
        try string(selected, "store_id"),
        try string(repeated.value.object.get("context").?, "store_id"),
    );
}

test "host migration observes published pending membership before owner import completes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var staged = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer staged.deinit();
    try expectStatus(staged, "owner-import-required");
    const selected = staged.value.object.get("context").?;
    try std.testing.expect(!selected.object.get("cataloged").?.bool);
    const id = try string(selected, "store_id");
    const root = try string(selected, "store_root");
    var published = try host.registerRoot(
        allocator,
        io,
        &fixture.environment,
        .{ .catalog_root = fixture.home, .store_id = id },
        root,
        id,
    );
    defer published.deinit();
    var listed = try host.list(allocator, io, fixture.home);
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 1), listed.value.stores.len);
    try std.testing.expectEqual(@as(usize, 0), listed.value.stores[0].aliases.len);
    try std.testing.expectEqual(@as(usize, 0), listed.value.pending.len);
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "owner-import-required");
    const repeated = retry.value.object.get("context").?;
    try std.testing.expectEqualStrings(id, try string(repeated, "store_id"));
    try std.testing.expectEqualStrings(root, try string(repeated, "store_root"));
    try std.testing.expect(repeated.object.get("cataloged").?.bool);
    try std.testing.expect(!repeated.object.get("authority_granted").?.bool);
}

test "host migration retired conversion stages stable custody and rejects unscoped finalization" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var staged = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer staged.deinit();
    try expectStatus(staged, "owner-import-required");
    try std.testing.expect(!staged.value.object.get("context").?.object.get("cataloged").?.bool);
    const selected = staged.value.object.get("context").?;
    const home = try host.catalog.openDirectory(io, fixture.home, false);
    defer home.close(io);
    try std.testing.expect(!try host.catalog.existsAt(io, home, "catalog.json"));
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "owner-import-required");
    try std.testing.expectEqualStrings(
        try string(selected, "store_id"),
        try string(retry.value.object.get("context").?, "store_id"),
    );
    try std.testing.expectEqualStrings(
        try string(staged.value, "fingerprint"),
        try string(retry.value, "fingerprint"),
    );
    const definition = try std.fs.path.join(allocator, &.{ fixture.root, "owner/definition.json" });
    defer allocator.free(definition);
    const invalid = try std.json.Stringify.valueAlloc(
        allocator,
        .{ .schema = "fixture-import/v1", .status = "verified", .definition_path = definition },
        .{},
    );
    defer allocator.free(invalid);
    try fixtureWrite(fixture.root, "invalid-receipt.json", invalid);
    const receipt_path = try std.fs.path.join(
        allocator,
        &.{ fixture.root, "invalid-receipt.json" },
    );
    defer allocator.free(receipt_path);
    var options = fixture.options(true);
    options.import_receipts = &.{receipt_path};
    var rejected = try execute(allocator, io, &fixture.environment, options);
    defer rejected.deinit();
    try expectStatus(rejected, "blocked");
    try std.testing.expectEqualStrings(
        "OwnerImportReceiptScopeMismatch",
        try string(rejected.value, "error_code"),
    );
    try std.testing.expect(!try host.catalog.existsAt(io, home, "catalog.json"));
    const scoped = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = "fixture-import/v1",
        .status = "verified",
        .definition_path = definition,
        .store_root = try string(selected, "store_root"),
        .store_id = try string(selected, "store_id"),
        .authority_granted = false,
        .full_record_parity_verified = false,
    }, .{});
    defer allocator.free(scoped);
    try fixtureWrite(fixture.root, "invalid-receipt.json", scoped);
    var unverified = try execute(allocator, io, &fixture.environment, options);
    defer unverified.deinit();
    try expectStatus(unverified, "blocked");
    try std.testing.expectEqualStrings(
        "OwnerImportParityUnverified",
        try string(unverified.value, "error_code"),
    );
    try std.testing.expect(!try host.catalog.existsAt(io, home, "catalog.json"));
}

test "host migration reinspection rejects changed source bytes" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var owners = try loadOwners(
        arena.allocator(),
        allocator,
        io,
        &fixture.environment,
        &.{fixture.manifest},
    );
    defer owners.deinit(allocator);
    var coverage = try discovery.trees(allocator, io, &fixture.environment, fixture.source);
    defer coverage.deinit();
    var snapshot = try legacy.inventory(
        allocator,
        io,
        coverage.roots,
        owners.slots,
        owners.retired,
        .{},
    );
    defer snapshot.deinit();
    try fixtureWrite(
        fixture.source,
        ".ledger/unselected/payload",
        "source changed after archival inspection\n",
    );
    try std.testing.expectError(
        error.MigrationSourceChanged,
        reinspect(
            allocator,
            io,
            &fixture.environment,
            fixture.source,
            &coverage,
            &snapshot,
            owners,
        ),
    );
    try std.testing.expect(!try host.catalog.exists(io, fixture.home));
}

test "host migration fingerprint matches historical Python v2 canonical vector" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    var snapshot: legacy.Inventory = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .sources = .{},
        .file_count = 2,
        .total_bytes = 2,
    };
    defer snapshot.deinit();
    const a: [64]u8 = @splat('a');
    const b: [64]u8 = @splat('b');
    const c: [64]u8 = @splat('c');
    const d: [64]u8 = @splat('d');
    var source: legacy.Source = .{ .workspace = "/source" };
    try source.entries.map.put(snapshot.arena.allocator(), ".ledger", .{ .kind = "directory" });
    try source.entries.map.put(
        snapshot.arena.allocator(),
        ".ledger/a.jsonl",
        .{ .kind = "file", .size = 2, .sha256 = &a },
    );
    try snapshot.sources.map.put(snapshot.arena.allocator(), "0", source);
    var entries = [_]Owner{.{
        .descriptor = .{
            .name = "fixture",
            .definition = "/owner/definition.json",
            .slots = &.{"a.jsonl"},
            .retired_sources = &.{},
            .importer = null,
            .manifest_sha256 = &b,
        },
        .manifest = "/owner/migration.json",
        .definition_sha256 = &d,
        .importer_sha256 = null,
        .plan = undefined,
        .bindings = undefined,
        .description = try jsonValue(
            owned,
            .{ .definition = .{
                .id = "fixture/events",
                .owner = "fixture",
                .digest = try std.fmt.allocPrint(owned, "sha256:{s}", .{c}),
                .abi = "ledger-artifact-abi/v1",
            } },
        ),
    }};
    const digest = try fingerprint(
        owned,
        &snapshot,
        .{ .entries = &entries, .slots = &.{"a.jsonl"}, .retired = &.{} },
        .{ .object = .{} },
    );
    try std.testing.expectEqualStrings(
        "3af7e978a3a1ad85990ae0a55a774ba482bb4c66bbfe9e9a61a2d14619894eaa",
        digest,
    );
}

test "host migration rejects retired-source symlinks before destination effects" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = try host.catalog.openDirectory(io, fixture.source, false);
    defer dir.close(io);
    try dir.deleteFile(io, ".retired.jsonl");
    try dir.symLink(io, "/missing/external", ".retired.jsonl", .{});
    var result = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer result.deinit();
    try expectStatus(result, "blocked");
    try std.testing.expect(!try host.catalog.exists(io, fixture.home));
}

test "host migration archive retries retain one stage and identity across publication faults" {
    const archive = @import("host_migration_archive.zig");
    for (std.enums.values(archive.TestFault.Kind)) |fault| try testArchiveInterruption(fault);
}

fn testArchiveInterruption(fault: @import("host_migration_archive.zig").TestFault.Kind) !void {
    const archive = @import("host_migration_archive.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var identity: ?[]const u8 = null;
    var root: []const u8 = undefined;
    var retained_bytes: ?u64 = null;
    const attempts: usize = if (fault == .write) 100 else 1;
    for (0..attempts) |_| {
        var vtable = io.vtable.*;
        archive.TestFault.install(&vtable, fault);
        var injected = io;
        injected.vtable = &vtable;
        var failed = try execute(allocator, injected, &fixture.environment, fixture.options(true));
        defer failed.deinit();
        try expectStatus(failed, "blocked");
        try std.testing.expect(archive.TestFault.reached);
        const selected = failed.value.object.get("context").?;
        const id = try string(selected, "store_id");
        if (identity) |previous| {
            try std.testing.expectEqualStrings(previous, id);
            try std.testing.expectEqualStrings(root, try string(selected, "store_root"));
        } else {
            identity = try fixture.arena.allocator().dupe(u8, id);
            root = try fixture.arena.allocator().dupe(u8, try string(selected, "store_root"));
        }
        const dir = try host.catalog.openDirectory(io, root, false);
        defer dir.close(io);
        const final = try std.fmt.allocPrint(allocator, "legacy-archive/{s}", .{
            try string(failed.value, "fingerprint"),
        });
        defer allocator.free(final);
        const published = fault == .after_rename or fault == .directory_sync;
        try testArchiveCount(dir, @intFromBool(published));
        try std.testing.expectEqual(published, try host.catalog.existsAt(io, dir, final));
        try std.testing.expectEqual(
            !published,
            try host.catalog.existsAt(io, dir, archive.directory_name),
        );
        try std.testing.expect(!try host.catalog.existsAt(io, dir, ".ledger/example/plain.jsonl"));
        if (fault == .write) {
            const stage = try dir.openDir(io, archive.directory_name, .{ .iterate = true });
            defer stage.close(io);
            const bytes = try testTreeBytes(stage);
            if (retained_bytes) |previous| try std.testing.expectEqual(previous, bytes);
            retained_bytes = bytes;
        }
    }
    var associated = try host.registerRoot(
        allocator,
        io,
        &fixture.environment,
        fixture.options(true).context,
        root,
        identity.?,
    );
    defer associated.deinit();
    try testArchiveRetry(&fixture, identity.?, root);
}

test "completed migration cannot revive consumed copy authority after receipt and custody loss" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var completed = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer completed.deinit();
    try expectStatus(completed, "verified");
    const selected = completed.value.object.get("context").?;
    const root = try string(selected, "store_root");
    const dir = try host.catalog.openDirectory(io, root, false);
    defer dir.close(io);
    try dir.deleteFile(io, "migration-receipt.json");
    try dir.deleteTree(io, ".ledger");
    try dir.createDir(io, ".ledger", .fromMode(0o700));
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "blocked");
    try std.testing.expectEqualStrings(
        "AdditionalOrDivergentHistory",
        try string(retry.value, "error_code"),
    );
    try std.testing.expect(!try host.catalog.existsAt(io, dir, ".ledger/example/plain.jsonl"));
    var context = try host.resolve(
        allocator,
        io,
        &fixture.environment,
        fixture.options(true).context,
    );
    defer context.deinit();
    try std.testing.expectEqualStrings(try string(selected, "store_id"), context.value.store_id);
}

test "registered interrupted migration cannot exchange its admitted copy input" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const copy = @import("host_migration_copy.zig");
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var vtable = io.vtable.*;
    copy.TestFault.install(&vtable, .before_rename);
    var injected = io;
    injected.vtable = &vtable;
    var interrupted = try execute(allocator, injected, &fixture.environment, fixture.options(true));
    defer interrupted.deinit();
    try expectStatus(interrupted, "blocked");
    try std.testing.expect(copy.TestFault.reached);
    const selected = interrupted.value.object.get("context").?;
    const root = try string(selected, "store_root");
    var associated = try host.registerRoot(
        allocator,
        io,
        &fixture.environment,
        fixture.options(true).context,
        root,
        try string(selected, "store_id"),
    );
    defer associated.deinit();
    try fixtureWrite(
        fixture.source,
        ".ledger/example/plain.jsonl",
        "{\"kind\":\"created\",\"value\":{\"id\":\"other\",\"revision\":\"r2\"}}\n",
    );
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "blocked");
    try std.testing.expectEqualStrings(
        "AdditionalOrDivergentHistory",
        try string(retry.value, "error_code"),
    );
    const dir = try host.catalog.openDirectory(io, root, false);
    defer dir.close(io);
    try std.testing.expect(!try host.catalog.existsAt(io, dir, ".ledger/example/plain.jsonl"));
}

const CopyRetirementFault = struct {
    var after_declaration = false;
    var armed = false;
    var reached = false;

    fn deleteDir(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        name: []const u8,
    ) std.Io.Dir.DeleteDirError!void {
        try std.testing.io.vtable.dirDeleteDir(userdata, dir, name);
        if (!after_declaration and std.mem.eql(u8, name, ".migration-copy")) armed = true;
    }

    fn deleteFile(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        name: []const u8,
    ) std.Io.Dir.DeleteFileError!void {
        try std.testing.io.vtable.dirDeleteFile(userdata, dir, name);
        if (after_declaration and std.mem.eql(u8, name, "migration-copy.json")) armed = true;
    }

    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        if (armed) {
            reached = true;
            return error.InputOutput;
        }
        return std.testing.io.vtable.fileSync(userdata, file);
    }
};

test "completed migration retries copy retirement without repeating publication" {
    for ([_]bool{ false, true }) |after_declaration| try testCopyRetirement(after_declaration);
}

fn testCopyRetirement(after_declaration: bool) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    CopyRetirementFault.after_declaration = after_declaration;
    CopyRetirementFault.armed = false;
    CopyRetirementFault.reached = false;
    var vtable = io.vtable.*;
    vtable.dirDeleteDir = CopyRetirementFault.deleteDir;
    vtable.dirDeleteFile = CopyRetirementFault.deleteFile;
    vtable.fileSync = CopyRetirementFault.sync;
    var injected = io;
    injected.vtable = &vtable;
    var interrupted = try execute(allocator, injected, &fixture.environment, fixture.options(true));
    defer interrupted.deinit();
    try expectStatus(interrupted, "blocked");
    try std.testing.expect(CopyRetirementFault.reached);
    const selected = interrupted.value.object.get("context").?;
    const root = try string(selected, "store_root");
    const dir = try host.catalog.openDirectory(io, root, false);
    defer dir.close(io);
    const before = try testTreeBytes(dir);
    const history = try testHash(dir, ".ledger/example/plain.jsonl");
    const receipt = try legacy.hashFile(io, dir, "migration-receipt.json", 64 * 1024 * 1024);
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "verified");
    try std.testing.expectEqualStrings(
        try string(selected, "store_id"),
        try string(retry.value.object.get("context").?, "store_id"),
    );
    try std.testing.expectEqualDeep(history, try testHash(dir, ".ledger/example/plain.jsonl"));
    try std.testing.expectEqualDeep(
        receipt,
        try legacy.hashFile(io, dir, "migration-receipt.json", 64 * 1024 * 1024),
    );
    try std.testing.expectEqual(before, try testTreeBytes(dir));
    try std.testing.expect(!try host.catalog.existsAt(io, dir, ".migration-copy"));
}

fn testArchiveRetry(fixture: *Fixture, identity: []const u8, root: []const u8) !void {
    const archive = @import("host_migration_archive.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "verified");
    const selected = retry.value.object.get("context").?;
    try std.testing.expectEqualStrings(identity, try string(selected, "store_id"));
    const dir = try host.catalog.openDirectory(io, root, false);
    defer dir.close(io);
    try std.testing.expect(!try host.catalog.existsAt(io, dir, archive.directory_name));
    try testArchiveCount(dir, 1);
    const source = try host.catalog.openDirectory(io, fixture.source, false);
    defer source.close(io);
    try std.testing.expectEqualDeep(
        try testHash(source, ".ledger/example/plain.jsonl"),
        try testHash(dir, ".ledger/example/plain.jsonl"),
    );
}

fn testArchiveCount(root: std.Io.Dir, expected: usize) !void {
    const io = std.testing.io;
    const archives = try root.openDir(io, "legacy-archive", .{ .iterate = true });
    defer archives.close(io);
    var iterator = archives.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".archiving-"));
        count += 1;
    }
    try std.testing.expectEqual(expected, count);
}

fn testTreeBytes(root: std.Io.Dir) !u64 {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(allocator, ".");
    var bytes: u64 = 0;
    var cursor: usize = 0;
    var members: usize = 0;
    while (cursor < paths.items.len) : (cursor += 1) {
        const path = paths.items[cursor];
        const dir = try root.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            members += 1;
            try std.testing.expect(members <= 100129);
            const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
            if (stat.kind == .directory) {
                const child = try std.fs.path.join(allocator, &.{ path, entry.name });
                try paths.append(allocator, child);
            } else {
                try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
                bytes += stat.size;
            }
        }
    }
    return bytes;
}

test "host migration archive restarts from prior manifest after source membership changes" {
    const archive = @import("host_migration_archive.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var vtable = io.vtable.*;
    archive.TestFault.install(&vtable, .before_rename);
    var injected = io;
    injected.vtable = &vtable;
    var failed = try execute(allocator, injected, &fixture.environment, fixture.options(true));
    defer failed.deinit();
    try expectStatus(failed, "blocked");
    try std.testing.expect(archive.TestFault.reached);
    const source = try host.catalog.openDirectory(io, fixture.source, false);
    defer source.close(io);
    try source.deleteFile(io, ".ledger/unselected/payload");
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "verified");
    const previous = failed.value.object.get("context").?;
    const selected = retry.value.object.get("context").?;
    try std.testing.expectEqualStrings(
        try string(previous, "store_id"),
        try string(selected, "store_id"),
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        try string(failed.value, "fingerprint"),
        try string(retry.value, "fingerprint"),
    ));
    const root = try string(selected, "store_root");
    const dir = try host.catalog.openDirectory(io, root, false);
    defer dir.close(io);
    try std.testing.expect(!try host.catalog.existsAt(io, dir, archive.directory_name));
}

test "host migration archives cataloged roots without pending registration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var first = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer first.deinit();
    try expectStatus(first, "verified");
    var associations = try host.workspace.resolve(
        allocator,
        io,
        &fixture.environment,
        fixture.source,
    );
    defer associations.deinit();
    const path = try pending.controlsPath(
        allocator,
        associations.workspace_root.?,
        associations.git_common_dir,
        fixture.home,
    );
    defer allocator.free(path);
    const controls = try host.catalog.openDirectory(io, path, false);
    defer controls.close(io);
    try controls.deleteFile(io, "registration.json");
    try fixtureWrite(fixture.source, ".ledger/unselected/another", "preserved later evidence");
    var next = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer next.deinit();
    try expectStatus(next, "verified");
    try std.testing.expectEqualStrings(
        try string(first.value.object.get("context").?, "store_id"),
        try string(next.value.object.get("context").?, "store_id"),
    );
    try std.testing.expect(!try host.catalog.existsAt(io, controls, "registration.json"));
    const id = try string(first.value.object.get("context").?, "store_id");
    try testUnassociatedMigration(&fixture, id);
}

fn testUnassociatedMigration(fixture: *Fixture, id: []const u8) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    {
        var lock = try host.catalog.Lock.acquire(io, fixture.home);
        defer lock.deinit();
        var catalog = try lock.read(allocator);
        defer catalog.deinit();
        catalog.value.aliases.map.clearRetainingCapacity();
        catalog.value.workspace_identities.map.clearRetainingCapacity();
        try lock.publish(allocator, catalog.value);
    }
    try fixtureWrite(
        fixture.source,
        ".ledger/unselected/explicit",
        "explicit-ID migration evidence",
    );
    var options = fixture.options(true);
    options.context.store_id = id;
    var selected = try execute(allocator, io, &fixture.environment, options);
    defer selected.deinit();
    try expectStatus(selected, "verified");
    try std.testing.expectEqualStrings(
        id,
        try string(selected.value.object.get("context").?, "store_id"),
    );
}

test "host migration archive retains foreign and linked or special staged entries" {
    const Kind = enum { foreign, symlink, hardlink, fifo };
    for (std.enums.values(Kind)) |kind| {
        const archive = @import("host_migration_archive.zig");
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        var fixture = try Fixture.init(false);
        defer fixture.deinit();
        var vtable = io.vtable.*;
        archive.TestFault.install(&vtable, .before_rename);
        var injected = io;
        injected.vtable = &vtable;
        var failed = try execute(allocator, injected, &fixture.environment, fixture.options(true));
        defer failed.deinit();
        try expectStatus(failed, "blocked");
        try std.testing.expect(archive.TestFault.reached);
        const root = try string(failed.value.object.get("context").?, "store_root");
        const path = try std.fs.path.join(allocator, &.{ root, archive.directory_name });
        defer allocator.free(path);
        const stage = try host.catalog.openDirectory(io, path, false);
        defer stage.close(io);
        const target = "worktree-0/.ledger/unselected/payload";
        if (kind != .foreign) try stage.deleteFile(io, target);
        switch (kind) {
            .foreign => try stage.writeFile(io, .{ .sub_path = "foreign", .data = "retain" }),
            .symlink => try stage.symLink(io, "/absent/external", target, .{}),
            .hardlink => {
                try stage.writeFile(io, .{ .sub_path = "foreign", .data = "retain" });
                try stage.hardLink("foreign", stage, target, io, .{});
            },
            .fifo => {
                const fifo = try std.fs.path.join(allocator, &.{ path, target });
                defer allocator.free(fifo);
                const made = try std.process.run(allocator, io, .{ .argv = &.{ "mkfifo", fifo } });
                defer allocator.free(made.stdout);
                defer allocator.free(made.stderr);
                try std.testing.expect(made.term == .exited and made.term.exited == 0);
            },
        }
        var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
        defer retry.deinit();
        try expectStatus(retry, "blocked");
        try std.testing.expectEqualStrings(
            "UnknownMigrationArchive",
            try string(retry.value, "error_code"),
        );
        try std.testing.expect(try host.catalog.existsAt(io, stage, "manifest.json"));
        try std.testing.expect(try host.catalog.existsAt(io, stage, target));
        if (kind == .foreign or kind == .hardlink)
            try std.testing.expect(try host.catalog.existsAt(io, stage, "foreign"));
    }
}

test "host migration archives a legacy registered root without catalog or pending locator" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    const git = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", fixture.source, "init", "--quiet" },
    });
    defer allocator.free(git.stdout);
    defer allocator.free(git.stderr);
    try std.testing.expect(git.term == .exited and git.term.exited == 0);
    var first = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer first.deinit();
    try expectStatus(first, "verified");
    const selected = first.value.object.get("context").?;
    const id = try string(selected, "store_id");
    var associations = try host.workspace.resolve(
        allocator,
        io,
        &fixture.environment,
        fixture.source,
    );
    defer associations.deinit();
    const path = try pending.controlsPath(
        allocator,
        associations.workspace_root.?,
        associations.git_common_dir,
        fixture.home,
    );
    defer allocator.free(path);
    const controls = try host.catalog.openDirectory(io, path, false);
    defer controls.close(io);
    try controls.deleteFile(io, "registration.json");
    const home = try host.catalog.openDirectory(io, fixture.home, false);
    defer home.close(io);
    try home.deleteFile(io, host.catalog.filename);
    const common = try host.catalog.openDirectory(io, associations.git_common_dir.?, false);
    defer common.close(io);
    const registration: host.Registration = .{
        .schema = host.catalog.registration_schema,
        .store_id = id,
        .store_root = try string(selected, "store_root"),
    };
    try host.catalog.writeJson(
        allocator,
        io,
        common,
        host.catalog.registration_name,
        registration,
        4096,
    );
    try fixtureWrite(fixture.source, ".ledger/unselected/legacy", "legacy registered evidence");
    var preview = try execute(allocator, io, &fixture.environment, fixture.options(false));
    defer preview.deinit();
    try expectStatus(preview, "planned");
    try std.testing.expect(!preview.value.object.get("context").?.object.get("cataloged").?.bool);
    try std.testing.expect(!preview.value.object.get("storage_mutated").?.bool);
    try std.testing.expect(!try host.catalog.existsAt(io, home, host.catalog.filename));
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "verified");
    try std.testing.expect(retry.value.object.get("context").?.object.get("cataloged").?.bool);
    try std.testing.expectEqualStrings(
        id,
        try string(retry.value.object.get("context").?, "store_id"),
    );
    try std.testing.expect(!try host.catalog.existsAt(io, controls, "registration.json"));
    try testLegacyMembership(&fixture, registration, common);
}

fn testLegacyMembership(
    fixture: *Fixture,
    registration: host.Registration,
    common: std.Io.Dir,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    {
        var lock = try host.catalog.Lock.acquire(io, fixture.home);
        defer lock.deinit();
        var registered = try lock.read(allocator);
        defer registered.deinit();
        registered.value.aliases.map.clearRetainingCapacity();
        registered.value.workspace_identities.map.clearRetainingCapacity();
        try lock.publish(allocator, registered.value);
    }
    var equivalent = registration;
    equivalent.store_root = try std.fmt.allocPrint(allocator, "{s}/", .{registration.store_root});
    defer allocator.free(equivalent.store_root);
    try host.catalog.writeJson(
        allocator,
        io,
        common,
        host.catalog.registration_name,
        equivalent,
        4096,
    );
    var observed = try execute(allocator, io, &fixture.environment, fixture.options(false));
    defer observed.deinit();
    try std.testing.expectEqual(@as(u8, 0), observed.exit_code);
    const observed_context = observed.value.object.get("context").?;
    try std.testing.expect(observed_context.object.get("cataloged").?.bool);
    try std.testing.expectEqualStrings(
        equivalent.store_root,
        try string(observed_context, "store_root"),
    );
}

const ArchiveCleanupSync = struct {
    var inode: std.Io.File.INode = undefined;
    var reached = false;

    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        const stat = file.stat(std.testing.io) catch return error.InputOutput;
        if (stat.kind == .directory and stat.inode == inode) {
            reached = true;
            return error.InputOutput;
        }
        return std.testing.io.vtable.fileSync(userdata, file);
    }
};

test "archive cleanup retains its manifest until payload removal is durable" {
    const archive = @import("host_migration_archive.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var vtable = io.vtable.*;
    archive.TestFault.install(&vtable, .before_rename);
    var injected = io;
    injected.vtable = &vtable;
    var failed = try execute(allocator, injected, &fixture.environment, fixture.options(true));
    defer failed.deinit();
    try expectStatus(failed, "blocked");
    try std.testing.expect(archive.TestFault.reached);
    const selected = failed.value.object.get("context").?;
    const root = try string(selected, "store_root");
    const stage_path = try std.fs.path.join(allocator, &.{ root, archive.directory_name });
    defer allocator.free(stage_path);
    const stage = try host.catalog.openDirectory(io, stage_path, false);
    defer stage.close(io);
    ArchiveCleanupSync.inode = (try stage.stat(io)).inode;
    ArchiveCleanupSync.reached = false;
    vtable = io.vtable.*;
    vtable.fileSync = ArchiveCleanupSync.sync;
    for (0..2) |_| {
        ArchiveCleanupSync.reached = false;
        var interrupted = try execute(
            allocator,
            injected,
            &fixture.environment,
            fixture.options(true),
        );
        defer interrupted.deinit();
        try expectStatus(interrupted, "blocked");
        try std.testing.expect(ArchiveCleanupSync.reached);
        try std.testing.expect(try host.catalog.existsAt(io, stage, "manifest.json"));
    }
    var entries = stage.iterate();
    const retained = (try entries.next(io)).?;
    try std.testing.expectEqualStrings("manifest.json", retained.name);
    try std.testing.expect(try entries.next(io) == null);
    var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
    defer retry.deinit();
    try expectStatus(retry, "verified");
    try std.testing.expectEqualStrings(
        try string(selected, "store_id"),
        try string(retry.value.object.get("context").?, "store_id"),
    );
}

test "host migration reports visible publication through fresh and receipt retry failures" {
    const fault = host.catalog.TestPublicationFault;
    for ([_]bool{ false, true }) |reuse| {
        for (std.enums.values(fault.Kind)) |kind| {
            const allocator = std.testing.allocator;
            const io = std.testing.io;
            var fixture = try Fixture.init(false);
            defer fixture.deinit();
            var vtable = io.vtable.*;
            var injected = io;
            injected.vtable = &vtable;
            if (reuse) {
                fault.install(&vtable, .before_rename);
                var first = try execute(
                    allocator,
                    injected,
                    &fixture.environment,
                    fixture.options(true),
                );
                defer first.deinit();
                try expectStatus(first, "blocked");
                try std.testing.expect(fault.reached);
                const root = try string(first.value.object.get("context").?, "store_root");
                const receipt = try std.fs.path.join(
                    allocator,
                    &.{ root, "migration-receipt.json" },
                );
                defer allocator.free(receipt);
                try std.testing.expect(try host.catalog.exists(io, receipt));
            }
            fault.install(&vtable, kind);
            var failed = try execute(
                allocator,
                injected,
                &fixture.environment,
                fixture.options(true),
            );
            defer failed.deinit();
            try expectStatus(failed, "blocked");
            try std.testing.expect(fault.reached);
            try std.testing.expectEqualStrings(
                if (kind == .before_rename) "HardwareFailure" else "InputOutput",
                try string(failed.value, "error_code"),
            );
            const selected = failed.value.object.get("context").?;
            const id = try string(selected, "store_id");
            const root = try string(selected, "store_root");
            var actual = try host.catalog.read(allocator, io, fixture.home);
            defer actual.deinit();
            const visible = actual.value.stores.map.get(id) != null;
            try std.testing.expectEqual(kind == .after_rename, visible);
            try std.testing.expectEqual(visible, selected.object.get("cataloged").?.bool);
            if (visible) try std.testing.expectEqualStrings(
                root,
                actual.value.stores.map.get(id).?,
            );
            var retry = try execute(allocator, io, &fixture.environment, fixture.options(true));
            defer retry.deinit();
            try expectStatus(retry, "verified");
            const resumed = retry.value.object.get("context").?;
            try std.testing.expect(resumed.object.get("cataloged").?.bool);
            try std.testing.expectEqualStrings(id, try string(resumed, "store_id"));
            try std.testing.expectEqualStrings(root, try string(resumed, "store_root"));
        }
    }
}
