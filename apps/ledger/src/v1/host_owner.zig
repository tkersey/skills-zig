const std = @import("std");
const host = @import("host_context.zig");
const pending = @import("host_pending.zig");
const discovery = @import("host_sources.zig");
const legacy = @import("host_legacy.zig");
const cli = @import("cli.zig");
const storage_root = @import("storage_root");
const doctor = @import("ledger_v1_core").doctor;
const preparation = @import("ledger_v1_core").preparation;
const compiled = @import("ledger_v1_core").compiled_plan;
const parameters = @import("definition_core").parameters;

const history_limits: preparation.Limits = .{
    .max_bytes = 256 * 1024 * 1024,
    .max_files = 512,
    .max_read_bytes = 2 * 1024 * 1024 * 1024,
};

pub const Options = struct {
    context: host.Options,
    definition: []const u8,
    manifest: []const u8,
    ensure: bool = false,
    repair_archive: bool = false,
    confirm_no_writers: bool = false,
    parameters: []const []const u8 = &.{},
};

pub const Manifest = struct {
    schema: []const u8,
    definition: []const u8,
    retired_sources: []const []const u8,
    importer: ?[]const u8,
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
        const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            bytes,
            .{ .allocate = .alloc_always },
        );
        try self.value.object.put(allocator, key, parsed.value);
    }

    fn beginMutation(self: *Result) !void {
        const previous = self.value.object.get("storage_mutated");
        if (previous) |value| if (value == .bool and value.bool) return;
        try self.put("storage_mutated", @as(?bool, null));
    }

    fn setContext(self: *Result, value: host.ContextValue) !void {
        const allocator = self.arena.allocator();
        const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            bytes,
            .{ .allocate = .alloc_always },
        );
        const previous = self.value.object.get("storage_mutated");
        var fields = parsed.value.object.iterator();
        while (fields.next()) |field| try self.value.object.put(
            allocator,
            field.key_ptr.*,
            field.value_ptr.*,
        );
        if (previous) |old| if (old == .bool and old.bool) try self.put("storage_mutated", true);
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
    try result.put("storage_mutated", false);
    try result.put("authority_granted", false);
    run(&result, io, environment, options) catch |err| {
        result.exit_code = 3;
        try result.put("schema", "ledger-workspace-context-error/v1");
        try result.put("status", "blocked");
        try result.put("error_code", @errorName(err));
    };
    return result;
}

pub fn loadManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    definition: []const u8,
) !std.json.Parsed(Manifest) {
    if (!std.fs.path.isAbsolute(path) or !std.fs.path.isAbsolute(definition)) {
        return error.OwnerInputsMustBeAbsolute;
    }
    var parsed = try host.catalog.readJson(Manifest, allocator, io, path, 16384);
    errdefer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(
        u8,
        value.schema,
        "ledger-owner-migration/v1",
    ) or value.retired_sources.len > 16) return error.InvalidOwnerDeclaration;
    try legacy.relative(value.definition);
    for (value.retired_sources) |name| try legacy.relative(name);
    if ((value.retired_sources.len > 0) != (value.importer != null)) {
        return error.InvalidOwnerImporterDeclaration;
    }
    if (value.importer) |name| try legacy.relative(name);
    const owner_path = try std.fs.path.join(
        allocator,
        &.{ std.fs.path.dirname(path).?, value.definition },
    );
    defer allocator.free(owner_path);
    try host.catalog.noSymlinks(io, owner_path);
    try host.catalog.noSymlinks(io, definition);
    const declared = try std.Io.Dir.cwd().realPathFileAlloc(io, owner_path, allocator);
    defer allocator.free(declared);
    const selected = try std.Io.Dir.cwd().realPathFileAlloc(io, definition, allocator);
    defer allocator.free(selected);
    if (!std.mem.eql(u8, declared, selected)) return error.OwnerDefinitionDoesNotMatchDeclaration;
    return parsed;
}

fn run(
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
) !void {
    if (options.confirm_no_writers and !options.ensure) return error.QuiescenceRequiresPreparation;
    if (options.repair_archive and !options.ensure) return error.ArchiveRepairRequiresPreparation;
    const allocator = result.arena.allocator();
    var manifest = try loadManifest(allocator, io, options.manifest, options.definition);
    defer manifest.deinit();
    var scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
    var plan = try cli.loadDefinitionWithCache(
        &scope,
        allocator,
        environment,
        options.definition,
        .{ .kind = .doctor },
        false,
    );
    defer plan.deinit(allocator);
    const store = &(plan.storage_plan orelse return error.OwnerRequiresStorage);
    if (store.slots.len != 1 or store.slots[0].kind != .event_log or
        store.slots[0].codec != .jsonl or
        std.mem.indexOfScalar(u8, store.slots[0].relative_path, '{') != null)
    {
        return error.UnsupportedOwnerLayout;
    }
    var bindings = try cli.bindParameters(
        allocator,
        &plan.definition_plan.parameter_declarations,
        options.parameters,
    );
    defer bindings.deinit(allocator);
    try runPlan(result, io, environment, options, &plan, &bindings, manifest.value.retired_sources);
}

fn runPlan(
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    retired: []const []const u8,
) !void {
    const allocator = result.arena.allocator();
    var associations = try host.workspace.resolve(
        allocator,
        io,
        environment,
        options.context.workspace,
    );
    defer associations.deinit();
    var selected = try resolveExisting(allocator, io, environment, options.context, &associations);
    defer if (selected) |*value| value.deinit();
    if (options.repair_archive and selected == null) {
        return error.ArchiveRepairRequiresExistingCustody;
    }
    var discover_archives = true;
    if (selected) |*current| {
        const coverage = try existingCoverage(
            result,
            io,
            environment,
            options,
            plan,
            bindings,
            &associations,
            current.value,
            retired,
        );
        discover_archives = coverage.discover_archives;
        if (coverage.covered) {
            if (options.ensure) {
                try registerContext(result, io, environment, options, current.value);
            }
            return;
        }
    }
    if (!options.ensure) return error.OwnerPreparationRequired;
    const slot = try preparation.selectedSlot(&plan.storage_plan.?);
    if (selected == null and try initializeNewOwner(
        result,
        io,
        environment,
        options,
        &associations,
        slot.relative_path,
        retired,
    )) return;
    try prepare(
        result,
        io,
        environment,
        options,
        plan,
        bindings,
        if (selected) |value| value.value else null,
        retired,
        discover_archives,
    );
}

const Coverage = struct {
    covered: bool = false,
    discover_archives: bool = true,
};

fn existingCoverage(
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    associations: *const host.workspace.Associations,
    selected: host.ContextValue,
    retired: []const []const u8,
) !Coverage {
    const allocator = result.arena.allocator();
    try result.setContext(selected);
    try pending.checkPendingContext(
        allocator,
        io,
        associations,
        options.context.catalog_root,
        selected,
    );
    var health = try inspect(allocator, io, plan, bindings, selected);
    defer health.deinit(allocator);
    if (options.repair_archive and health.pending_transactions != 0) {
        return error.ArchiveRepairRequiresResolvedTransactions;
    }
    if (!health.healthy or health.pending_transactions != 0) return .{};
    const slot = plan.storage_plan.?.slots[0];
    const present = health.slots[0].state != .missing;
    const covered = if (present)
        try localCovered(allocator, io, environment, selected, plan, bindings)
    else
        try missingCovered(
            allocator,
            io,
            environment,
            options,
            selected,
            slot.relative_path,
            retired,
        );
    return .{
        .covered = covered and !health.preparation_pending,
        .discover_archives = !present,
    };
}

fn missingCovered(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    selected: host.ContextValue,
    slot: []const u8,
    retired: []const []const u8,
) !bool {
    var sources = try discovery.discover(
        allocator,
        io,
        environment,
        options.context.workspace,
        selected,
        slot,
        retired,
        true,
    );
    defer sources.deinit();
    return !try anyHistory(allocator, io, sources.sources, slot);
}

fn initializeNewOwner(
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    associations: *const host.workspace.Associations,
    slot: []const u8,
    retired: []const []const u8,
) !bool {
    const allocator = result.arena.allocator();
    var sources = try discovery.discover(
        allocator,
        io,
        environment,
        options.context.workspace,
        null,
        slot,
        retired,
        false,
    );
    defer sources.deinit();
    if (!try genuinelyNew(
        allocator,
        io,
        associations,
        options.context.catalog_root,
        sources.trees,
        retired,
    )) return false;
    var initialize_options = options.context;
    initialize_options.legacy_paths = retired;
    try result.put("storage_mutated", @as(?bool, null));
    var initialized = host.initialize(allocator, io, environment, initialize_options) catch |err|
        switch (err) {
            error.PendingInitializationRequiresPreparation => return false,
            else => return err,
        };
    defer initialized.deinit();
    try result.setContext(initialized.value);
    return true;
}

fn registerContext(
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    selected: host.ContextValue,
) !void {
    try result.beginMutation();
    var registered = try host.registerRoot(
        result.arena.allocator(),
        io,
        environment,
        options.context,
        selected.store_root,
        selected.store_id,
    );
    defer registered.deinit();
    try result.setContext(registered.value);
}

fn resolveExisting(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: host.Options,
    associations: *const host.workspace.Associations,
) !?host.Context {
    if (host.resolve(
        allocator,
        io,
        environment,
        options,
    )) |value| return value else |err| switch (err) {
        error.UnregisteredContext => {},
        else => return err,
    }
    if (options.store_id != null) return error.SelectedStoreNotCataloged;
    const common = associations.git_common_dir orelse return null;
    const path = try std.fs.path.join(allocator, &.{ common, host.catalog.registration_name });
    if (!try host.catalog.exists(io, path)) return null;
    var registration = try host.readRegistration(allocator, io, path);
    defer registration.deinit();
    return try host.checkedRoot(
        allocator,
        io,
        registration.value.store_root,
        registration.value.store_id,
        associations.workspace_root,
        common,
        false,
    );
}

fn inspect(
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    selected: host.ContextValue,
) !doctor.Result {
    const control = try storage_root.checkedRoot(
        allocator,
        io,
        selected.store_root,
        selected.store_id,
    );
    defer control.close(io);
    var scope = storage_root.Scope.init(.anchored(io, control));
    return doctor.execute(
        &scope,
        allocator,
        &plan.definition_plan,
        &plan.storage_plan.?,
        if (plan.protocol_plan) |*protocol| protocol else null,
        ".",
        bindings,
    );
}

fn localCovered(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    selected: host.ContextValue,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
) !bool {
    const root = selected.workspace_root orelse return true;
    if (std.mem.eql(u8, root, selected.store_root)) return true;
    var sources = try discovery.discover(
        allocator,
        io,
        environment,
        root,
        selected,
        plan.storage_plan.?.slots[0].relative_path,
        &.{},
        false,
    );
    defer sources.deinit();
    if (plan.storage_plan.?.slots[0].layout == .segmented) {
        if (!try anyHistory(
            allocator,
            io,
            sources.sources,
            plan.storage_plan.?.slots[0].relative_path,
        )) return true;
        return error.SegmentedLocalCoverageRequiresMigration;
    }
    return coverLiveSources(allocator, io, environment, selected, plan, bindings, &sources);
}

fn coverLiveSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    selected: host.ContextValue,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    sources: *const discovery.Sources,
) !bool {
    const target_dir = try storage_root.checkedRoot(
        allocator,
        io,
        selected.store_root,
        selected.store_id,
    );
    defer target_dir.close(io);
    var budget: storage_root.ReadBudget = .{
        .max_bytes = history_limits.max_read_bytes,
        .max_files = history_limits.max_files * 16,
    };
    var target_scope = storage_root.Scope.init(.anchored(io, target_dir));
    target_scope.fs.read_budget = &budget;
    var target_history = try captureCoverageHistory(&target_scope, allocator, plan, bindings);
    defer target_history.deinit(allocator);
    const controls = try allocator.alloc(?std.Io.Dir, sources.sources.len);
    defer allocator.free(controls);
    @memset(controls, null);
    defer for (controls) |control| if (control) |dir| dir.close(io);
    const histories = try allocator.alloc(preparation.History, sources.sources.len);
    defer allocator.free(histories);
    @memset(histories, .{});
    defer for (histories) |*history| history.deinit(allocator);
    var covered = true;
    for (sources.sources, controls, histories) |source, *control, *history| {
        control.* = try openCoverageSource(allocator, io, source);
        const dir = control.* orelse continue;
        var source_scope = storage_root.Scope.init(.anchored(io, dir));
        source_scope.fs.read_budget = &budget;
        history.* = try captureCoverageHistory(&source_scope, allocator, plan, bindings);
        if (!target_history.covers(history)) covered = false;
    }
    try recheckCoverage(allocator, io, environment, selected, plan, sources, controls);
    const current = try storage_root.checkedRoot(
        allocator,
        io,
        selected.store_root,
        selected.store_id,
    );
    defer current.close(io);
    if (!try @import("durable_store").sameDirectoryObject(io, target_dir, current))
        return error.StorageRootChanged;
    return covered;
}

fn openCoverageSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: preparation.Source,
) !?std.Io.Dir {
    if (source.store_id) |id| return try storage_root.checkedRoot(allocator, io, source.root, id);
    const path = try std.fs.path.join(allocator, &.{ source.root, ".ledger" });
    defer allocator.free(path);
    return host.catalog.openDirectory(io, path, false) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn recheckCoverage(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    selected: host.ContextValue,
    plan: *const compiled.PlanSet,
    sources: *const discovery.Sources,
    controls: []const ?std.Io.Dir,
) !void {
    var associations = try host.workspace.resolve(
        allocator,
        io,
        environment,
        selected.workspace_root,
    );
    defer associations.deinit();
    if (!host.catalog.optionalEqual(associations.workspace_root, selected.workspace_root) or
        !host.catalog.optionalEqual(associations.git_common_dir, selected.git_common_dir))
        return error.WorkspaceCoverageChangedAfterPreparation;
    var current = try discovery.discover(
        allocator,
        io,
        environment,
        selected.workspace_root,
        selected,
        plan.storage_plan.?.slots[0].relative_path,
        &.{},
        false,
    );
    defer current.deinit();
    if (current.sources.len != sources.sources.len)
        return error.WorkspaceCoverageChangedAfterPreparation;
    for (current.sources, sources.sources, controls) |now, before, previous| {
        if (!std.mem.eql(u8, now.root, before.root) or
            !host.catalog.optionalEqual(now.store_id, before.store_id))
            return error.WorkspaceCoverageChangedAfterPreparation;
        const control = try openCoverageSource(allocator, io, now);
        defer if (control) |dir| dir.close(io);
        if ((control == null) != (previous == null)) return error.SourceChangedDuringPreparation;
        if (control) |dir| {
            if (!try @import("durable_store").sameDirectoryObject(io, previous.?, dir))
                return error.SourceChangedDuringPreparation;
        }
    }
}

fn captureCoverageHistory(
    scope: *storage_root.Scope,
    allocator: std.mem.Allocator,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
) !preparation.History {
    return preparation.captureHistory(
        scope,
        allocator,
        ".",
        &plan.definition_plan,
        try preparation.selectedSlot(&plan.storage_plan.?),
        bindings,
        plan.protocol_plan != null,
        history_limits,
        false,
    );
}

fn anyHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    sources: []const preparation.Source,
    slot: []const u8,
) !bool {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(slot, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    for (sources) |source| {
        const path = try std.fs.path.join(allocator, &.{ source.root, ".ledger", slot });
        const binding = try std.fmt.allocPrint(
            allocator,
            "{s}/.ledger/.bindings/{s}.jsonl",
            .{ source.root, hex },
        );
        if (try host.catalog.exists(io, path) or try host.catalog.exists(io, binding)) return true;
    }
    return false;
}

fn genuinelyNew(
    allocator: std.mem.Allocator,
    io: std.Io,
    associations: *const host.workspace.Associations,
    home: []const u8,
    trees: []const []const u8,
    retired: []const []const u8,
) !bool {
    const root = associations.workspace_root orelse return false;
    const controls = try pending.controlsPath(allocator, root, associations.git_common_dir, home);
    const registration = try std.fs.path.join(allocator, &.{ controls, "registration.json" });
    if (try host.catalog.exists(io, registration)) return false;
    for (trees) |tree| if (try host.workspace.hasLegacyHistory(
        allocator,
        io,
        tree,
        retired,
    )) return false;
    return true;
}

fn prepare(
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    existing: ?host.ContextValue,
    retired: []const []const u8,
    discover_archives: bool,
) !void {
    const allocator = result.arena.allocator();
    var target: ?pending.Target = null;
    defer if (target) |*value| value.deinit();
    const selected = existing orelse blk: {
        try result.put("storage_mutated", @as(?bool, null));
        target = try pending.prepareTarget(allocator, io, environment, options.context, true);
        break :blk target.?.context.value;
    };
    try prepareSelected(
        result,
        io,
        environment,
        options,
        plan,
        bindings,
        selected,
        if (discover_archives) retired else &.{},
        discover_archives,
    );
}

fn prepareSelected(
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    selected: host.ContextValue,
    retired: []const []const u8,
    discover_archives: bool,
) !void {
    const allocator = result.arena.allocator();
    try result.setContext(selected);
    var sources = try discovery.discover(
        allocator,
        io,
        environment,
        options.context.workspace,
        selected,
        plan.storage_plan.?.slots[0].relative_path,
        retired,
        discover_archives,
    );
    defer sources.deinit();
    const control = try storage_root.checkedRoot(
        allocator,
        io,
        selected.store_root,
        selected.store_id,
    );
    defer control.close(io);
    try prepareNative(
        result,
        io,
        control,
        plan,
        bindings,
        selected,
        sources.sources,
        options.confirm_no_writers,
    );
    if (options.context.workspace) |workspace| {
        try recheckPreparedTrees(allocator, io, environment, workspace, sources.trees);
    }
    try registerContext(result, io, environment, options, selected);
}

fn prepareNative(
    result: *Result,
    io: std.Io,
    control: std.Io.Dir,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    selected: host.ContextValue,
    sources: []const preparation.Source,
    confirm_no_writers: bool,
) !void {
    const allocator = result.arena.allocator();
    const selection: storage_root.Selection = .{
        .argv = &.{},
        .control = control,
        .io = io,
        .supplied_root = selected.store_root,
        .store_id = selected.store_id,
    };
    var scope = storage_root.Scope.init(.anchored(io, control));
    var budget: storage_root.ReadBudget = .{
        .max_bytes = history_limits.max_read_bytes,
        .max_files = history_limits.max_files * 16,
    };
    scope.fs.read_budget = &budget;
    var prepared = prepareWaiting(
        &scope,
        &selection,
        allocator,
        plan,
        bindings,
        sources,
        confirm_no_writers,
    ) catch |err| {
        if (!selected.storage_mutated) try result.put("storage_mutated", scope.mutation_state);
        return err;
    };
    defer prepared.deinit(allocator);
    prepared.store_id = selected.store_id;
    prepared.store_root = selected.store_root;
    try result.put("preparation", prepared);
    if (!selected.storage_mutated) try result.put("storage_mutated", prepared.storage_mutated);
    if (!std.mem.eql(u8, prepared.outcome, "covered") and
        !std.mem.eql(u8, prepared.outcome, "prepared") and
        !std.mem.eql(u8, prepared.outcome, "empty"))
    {
        return error.PreparationRequiresAttention;
    }
}

fn recheckPreparedTrees(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    workspace: []const u8,
    expected: []const []const u8,
) !void {
    var current = try discovery.trees(allocator, io, environment, workspace);
    defer current.deinit();
    if (current.roots.len != expected.len) return error.WorkspaceCoverageChangedAfterPreparation;
    for (current.roots, expected) |left, right| {
        if (!std.mem.eql(u8, left, right)) return error.WorkspaceCoverageChangedAfterPreparation;
    }
}

fn prepareWaiting(
    scope: *storage_root.Scope,
    selection: *const storage_root.Selection,
    allocator: std.mem.Allocator,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    sources: []const preparation.Source,
    confirm_no_writers: bool,
) !preparation.Result {
    for (0..301) |attempt| {
        var result = try preparation.execute(
            scope,
            selection,
            allocator,
            &plan.definition_plan,
            &plan.storage_plan.?,
            bindings,
            plan.protocol_plan != null,
            sources,
            .{
                .apply = true,
                .confirm_no_legacy_writers = confirm_no_writers,
                .limits = history_limits,
            },
        );
        if (!std.mem.eql(
            u8,
            result.outcome,
            "busy",
        ) or result.storage_mutated != false or attempt == 300) return result;
        result.deinit(allocator);
        if (attempt == 0) {
            var writer = std.Io.File.stderr().writer(scope.fs.io, &.{});
            try writer.interface.writeAll("Waiting for active Ledger writer\n");
            try writer.interface.flush();
        }
        try std.Io.sleep(scope.fs.io, .fromMilliseconds(100), .awake);
    }
    unreachable;
}
