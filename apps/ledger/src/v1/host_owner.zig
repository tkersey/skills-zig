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
        plan,
        bindings,
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
    if (options.repair_archive and (!health.healthy or health.slots[0].state == .missing)) {
        const failure = health.slots[0].error_code orelse
            return error.ArchiveRepairRequiresBoundMissingSlot;
        if (std.mem.eql(u8, failure, "EventStoreBusy") or
            std.mem.eql(u8, failure, "LockBusy")) return .{};
        if (!std.mem.eql(u8, failure, "StoreBindingWithoutSlot"))
            return error.ArchiveRepairRequiresBoundMissingSlot;
        return .{};
    }
    if (!health.healthy or health.pending_transactions != 0) return .{};
    const present = health.slots[0].state != .missing;
    const covered = if (present)
        try localCovered(
            allocator,
            io,
            environment,
            selected,
            plan,
            bindings,
            options.confirm_no_writers,
        )
    else
        try missingCovered(
            allocator,
            io,
            environment,
            options,
            selected,
            plan,
            bindings,
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
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    retired: []const []const u8,
) !bool {
    var sources = try discovery.discover(
        allocator,
        io,
        environment,
        options.context.workspace,
        selected,
        plan.storage_plan.?.slots[0].relative_path,
        retired,
        true,
    );
    defer sources.deinit();
    if (try emptyFamily(allocator, io, sources.sources)) return true;
    return coverSources(
        allocator,
        io,
        environment,
        selected,
        plan,
        bindings,
        &sources,
        options.confirm_no_writers,
        false,
        true,
    );
}

fn emptyFamily(
    allocator: std.mem.Allocator,
    io: std.Io,
    sources: []const preparation.Source,
) !bool {
    for (sources) |source| {
        if (source.archive or try host.workspace.hasLegacyHistory(allocator, io, source.root, &.{}))
            return false;
    }
    return true;
}

fn initializeNewOwner(
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
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
    const coverage = try existingCoverage(
        result,
        io,
        environment,
        options,
        plan,
        bindings,
        associations,
        initialized.value,
        retired,
    );
    if (!coverage.covered) try prepareSelected(
        result,
        io,
        environment,
        options,
        plan,
        bindings,
        initialized.value,
        if (coverage.discover_archives) retired else &.{},
        coverage.discover_archives,
    );
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
    confirm_no_writers: bool,
) !bool {
    const root = selected.workspace_root orelse return true;
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
    if (try emptyFamily(allocator, io, sources.sources)) return true;
    if (plan.storage_plan.?.slots[0].layout == .segmented) {
        if (!try anyHistory(
            allocator,
            io,
            sources.sources,
            plan.storage_plan.?.slots[0].relative_path,
        )) return true;
        return error.SegmentedLocalCoverageRequiresMigration;
    }
    return coverSources(
        allocator,
        io,
        environment,
        selected,
        plan,
        bindings,
        &sources,
        confirm_no_writers,
        true,
        false,
    );
}

fn coverSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    selected: host.ContextValue,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    sources: *const discovery.Sources,
    confirm_no_writers: bool,
    target_present: bool,
    discover_archives: bool,
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
    var target_history = try captureCoverageHistory(
        &target_scope,
        allocator,
        plan,
        bindings,
        target_present and !confirm_no_writers,
    );
    defer target_history.deinit(allocator);
    const controls = try allocator.alloc(?std.Io.Dir, sources.sources.len);
    defer allocator.free(controls);
    @memset(controls, null);
    defer for (controls) |control| if (control) |dir| dir.close(io);
    const histories = try allocator.alloc(preparation.History, sources.sources.len);
    defer allocator.free(histories);
    @memset(histories, .{});
    defer for (histories) |*history| history.deinit(allocator);
    try captureCoverageSources(
        allocator,
        io,
        plan,
        bindings,
        sources.sources,
        controls,
        histories,
        &budget,
        confirm_no_writers,
    );
    var covered = true;
    for (histories) |*history| if (!target_history.covers(history)) {
        covered = false;
    };
    try recheckCoverage(
        allocator,
        io,
        environment,
        selected,
        plan,
        sources,
        controls,
        discover_archives,
    );
    try recheckTarget(allocator, io, selected, target_dir);
    return covered;
}

fn recheckTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    selected: host.ContextValue,
    previous: std.Io.Dir,
) !void {
    const current = try storage_root.checkedRoot(
        allocator,
        io,
        selected.store_root,
        selected.store_id,
    );
    defer current.close(io);
    if (!try @import("durable_store").sameDirectoryObject(io, previous, current))
        return error.StorageRootChanged;
}

fn captureCoverageSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    sources: []const preparation.Source,
    controls: []?std.Io.Dir,
    histories: []preparation.History,
    budget: *storage_root.ReadBudget,
    confirm_no_writers: bool,
) !void {
    for ([_]bool{ true, false }) |archive| {
        for (sources, controls, histories) |source, *control, *history| {
            if (source.archive != archive) continue;
            control.* = try openCoverageSource(allocator, io, source);
            if (control.*) |dir| {
                var source_scope = storage_root.Scope.init(.anchored(io, dir));
                source_scope.fs.read_budget = budget;
                history.* = if (source.archive)
                    try preparation.captureHistory(
                        &source_scope,
                        allocator,
                        ".",
                        &plan.definition_plan,
                        try preparation.selectedSlot(&plan.storage_plan.?),
                        bindings,
                        plan.protocol_plan != null,
                        history_limits,
                        false,
                    )
                else
                    try captureCoverageHistory(
                        &source_scope,
                        allocator,
                        plan,
                        bindings,
                        !confirm_no_writers,
                    );
            } else if (!source.archive and !confirm_no_writers) {
                return error.PreparationRequiresQuiescence;
            }
            if (source.archive) try preparation.validateArchive(
                io,
                allocator,
                source,
                history,
                budget,
            );
        }
    }
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
    discover_archives: bool,
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
        discover_archives,
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
    require_coordination: bool,
) !preparation.History {
    return preparation.captureSourceHistory(
        scope,
        allocator,
        ".",
        &plan.definition_plan,
        try preparation.selectedSlot(&plan.storage_plan.?),
        bindings,
        plan.protocol_plan != null,
        history_limits,
        require_coordination,
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
        if (source.archive) return true;
        const control = try openCoverageSource(allocator, io, source);
        if (control) |directory| {
            defer directory.close(io);
            try @import("durable_store").ensureNoPendingTransactions(
                .anchored(io, directory),
                allocator,
                ".transactions",
            );
        }
        const path = try std.fs.path.join(allocator, &.{ source.root, ".ledger", slot });
        defer allocator.free(path);
        const binding = try std.fmt.allocPrint(
            allocator,
            "{s}/.ledger/.bindings/{s}.jsonl",
            .{ source.root, hex },
        );
        defer allocator.free(binding);
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
    if (options.repair_archive) {
        const archived = for (sources.sources) |source| {
            if (source.archive) break true;
        } else false;
        if (!archived) return error.ArchiveRepairRequiresArchiveEvidence;
    }
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
        options.repair_archive,
    );
    if (options.context.workspace) |workspace| {
        try recheckPreparedTrees(allocator, io, environment, workspace, selected, sources.trees);
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
    restore_bound_history: bool,
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
        restore_bound_history,
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
    selected: host.ContextValue,
    expected: []const []const u8,
) !void {
    var current = try discovery.treesForTarget(allocator, io, environment, workspace, selected);
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
    restore_bound_history: bool,
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
                .restore_bound_history = restore_bound_history,
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

const OwnerAssociationInterleaving = struct {
    var active: ?*OwnerAssociationInterleaving = null;

    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: host.Options,
    selected: host.ContextValue,
    seed: std.Io.Dir,
    workspace: std.Io.Dir,
    catalog: std.Io.Dir,
    catalog_reads: usize = 0,
    fired: bool = false,

    fn verify(self: *const OwnerAssociationInterleaving, result: Result) !void {
        if (!self.fired or result.exit_code != 0) {
            const diagnostic = try std.json.Stringify.valueAlloc(
                std.testing.allocator,
                result.value,
                .{},
            );
            defer std.testing.allocator.free(diagnostic);
            std.debug.print("catalog reads={d}, fired={}, result={s}\n", .{
                self.catalog_reads, self.fired, diagnostic,
            });
        }
        try std.testing.expect(self.fired);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expectEqualStrings(
            self.selected.store_id,
            result.value.object.get("store_id").?.string,
        );
    }

    fn stat(
        userdata: ?*anyopaque,
        directory: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.StatFileOptions,
    ) std.Io.Dir.StatFileError!std.Io.File.Stat {
        const self = active.?;
        if (std.mem.eql(u8, path, host.catalog.filename) and
            (@import("durable_store").sameDirectoryObject(self.io, directory, self.catalog) catch
                return error.Unexpected))
        {
            self.catalog_reads += 1;
            if (self.catalog_reads == 2) {
                var registered = host.registerRoot(
                    std.testing.allocator,
                    self.io,
                    self.environment,
                    self.options,
                    self.selected.store_root,
                    self.selected.store_id,
                ) catch return error.Unexpected;
                registered.deinit();
                self.seed.renamePreserve(".ledger", self.workspace, ".ledger", self.io) catch
                    return error.Unexpected;
                self.fired = true;
            }
        }
        return self.io.vtable.dirStatFile(userdata, directory, path, options);
    }
};

test "segmented owner source absence rejects unresolved native publication" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = try host.workspace.testPlainDirectory();
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const sources = [_]preparation.Source{.{ .root = root }};
    try std.testing.expect(!try anyHistory(allocator, io, &sources, "example/events.jsonl"));
    try temporary.dir.createDirPath(io, ".ledger/.transactions/dtx-first");
    try std.testing.expectError(error.TransactionRecoveryRequired, anyHistory(
        allocator,
        io,
        &sources,
        "example/events.jsonl",
    ));
    try std.testing.expect(try host.catalog.existsAt(
        io,
        temporary.dir,
        ".ledger/.transactions/dtx-first",
    ));
    try std.testing.expect(!try host.catalog.existsAt(
        io,
        temporary.dir,
        ".ledger/example/events.jsonl",
    ));
}

test "owner initialization admits history after concurrent existing catalog selection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = try host.workspace.testPlainDirectory();
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(io, ".", owned);
    const home = try std.fs.path.join(owned, &.{ root, "home" });
    const workspace = try std.fs.path.join(owned, &.{ root, "workspace" });
    const seed = try std.fs.path.join(owned, &.{ root, "seed" });
    const definition_path = try std.fs.path.join(owned, &.{ root, "definition.json" });
    const manifest_path = try std.fs.path.join(owned, &.{ root, "migration.json" });
    try testOwnerInputs(temporary.dir);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var selected = try host.initialize(allocator, io, &environment, .{ .catalog_root = home });
    defer selected.deinit();
    try testAppendOwner(&environment, definition_path, seed);
    const seed_dir = try temporary.dir.openDir(io, "seed", .{});
    defer seed_dir.close(io);
    const workspace_dir = try temporary.dir.openDir(io, "workspace", .{});
    defer workspace_dir.close(io);
    const catalog_dir = try temporary.dir.openDir(io, "home", .{});
    defer catalog_dir.close(io);
    const original = try host.catalog.readBytes(
        owned,
        io,
        seed_dir,
        ".ledger/example/events.jsonl",
        4096,
    );
    const options: host.Options = .{ .catalog_root = home, .workspace = workspace };
    var interleaving: OwnerAssociationInterleaving = .{
        .io = io,
        .environment = &environment,
        .options = options,
        .selected = selected.value,
        .seed = seed_dir,
        .workspace = workspace_dir,
        .catalog = catalog_dir,
    };
    OwnerAssociationInterleaving.active = &interleaving;
    defer OwnerAssociationInterleaving.active = null;
    var vtable = io.vtable.*;
    vtable.dirStatFile = OwnerAssociationInterleaving.stat;
    var injected = io;
    injected.vtable = &vtable;
    var result = try execute(allocator, injected, &environment, .{
        .context = options,
        .definition = definition_path,
        .manifest = manifest_path,
        .ensure = true,
    });
    defer result.deinit();
    try interleaving.verify(result);
    const target = try host.catalog.openDirectory(io, selected.value.store_root, false);
    defer target.close(io);
    try expectOwnerBytes(target, original);
    try expectOwnerBytes(workspace_dir, original);
}

fn testOwnerInputs(directory: std.Io.Dir) !void {
    const io = std.testing.io;
    try directory.createDir(io, "workspace", .default_dir);
    try directory.createDir(io, "seed", .default_dir);
    try directory.writeFile(io, .{
        .sub_path = "definition.json",
        .data = @embedFile("fixtures/event-definition.json"),
    });
    try host.catalog.writeJson(std.testing.allocator, io, directory, "migration.json", Manifest{
        .schema = "ledger-owner-migration/v1",
        .definition = "definition.json",
        .retired_sources = &.{},
        .importer = null,
    }, 16384);
}

fn expectOwnerBytes(directory: std.Io.Dir, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const actual = try host.catalog.readBytes(
        allocator,
        std.testing.io,
        directory,
        ".ledger/example/events.jsonl",
        4096,
    );
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn testAppendOwner(
    environment: *const std.process.Environ.Map,
    definition_path: []const u8,
    root: []const u8,
) !void {
    const allocator = std.testing.allocator;
    var scope = storage_root.Scope.init(.init(std.testing.io, std.Io.Dir.cwd()));
    var plans = try cli.loadDefinitionWithCache(
        &scope,
        allocator,
        environment,
        definition_path,
        .{ .kind = .transact, .name = "append" },
        false,
    );
    defer plans.deinit(allocator);
    var bindings = try cli.bindParameters(
        allocator,
        &plans.definition_plan.parameter_declarations,
        &.{"request=first"},
    );
    defer bindings.deinit(allocator);
    var result = try @import("ledger_v1_core").transaction.transact(
        &scope,
        allocator,
        &plans.definition_plan,
        &plans.closure,
        plans.entry_path,
        &plans.validation_plan.?,
        &plans.storage_plan.?,
        if (plans.protocol_plan) |*protocol| protocol else null,
        "append",
        root,
        &.{.{ .name = "event", .bytes = "{\"kind\":\"one\",\"value\":1}" }},
        &bindings,
    );
    defer result.deinit(allocator);
    try std.testing.expect(result.validation_result.valid and result.storage_mutated);
}
