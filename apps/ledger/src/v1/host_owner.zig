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
const durable = @import("durable_store");

const history_limits: preparation.Limits = .{
    .max_bytes = 256 * 1024 * 1024,
    .max_files = 512,
    .max_read_bytes = 2 * 1024 * 1024 * 1024,
};
const writer_attempts_max = 301;
const writer_retry_delay_ms = 100;

pub const Options = struct {
    context: host.Options,
    definition: []const u8,
    manifest: []const u8,
    ensure: bool = false,
    reconcile: bool = false,
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

    fn observeMutation(self: *Result, mutated: ?bool) !void {
        const previous = self.value.object.get("storage_mutated");
        if (previous) |value| if (value == .bool and value.bool) return;
        try self.put("storage_mutated", mutated);
    }

    fn block(self: *Result, code: []const u8) !void {
        self.exit_code = 3;
        try self.put("schema", "ledger-workspace-context-error/v1");
        try self.put("status", "blocked");
        try self.put("error_code", code);
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
        try result.block(@errorName(err));
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
    if (options.reconcile and !options.ensure) return error.ReconciliationRequiresPreparation;
    if (options.reconcile and options.context.workspace == null)
        return error.ReconciliationRequiresWorkspace;
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
    var selected = try resolveOwnerContext(allocator, io, environment, options, &associations);
    defer if (selected) |*value| value.deinit();
    if (options.repair_archive and selected == null) {
        return error.ArchiveRepairRequiresExistingCustody;
    }
    try runSelectedPlan(
        result,
        io,
        environment,
        options,
        plan,
        bindings,
        &associations,
        if (selected) |value| value.value else null,
        retired,
    );
}

fn runSelectedPlan(
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    associations: *const host.workspace.Associations,
    selected: ?host.ContextValue,
    retired: []const []const u8,
) !void {
    var discover_archives = true;
    if (selected) |current| {
        if (!options.ensure) {
            return admitRead(result, io, options, plan, bindings, associations, current);
        }
        if (!options.reconcile and !options.repair_archive) {
            switch (try admitPresentOwner(
                result,
                io,
                options,
                plan,
                bindings,
                associations,
                current,
            )) {
                .present => {
                    try registerContext(result, io, environment, options, current);
                    return;
                },
                .blocked => return,
                .preparation => try requireWorkspaceForMissingOwner(result, io, options, current),
            }
        }
        const coverage = try existingCoverage(
            result,
            io,
            environment,
            options,
            plan,
            bindings,
            associations,
            current,
            retired,
        );
        discover_archives = coverage.discover_archives;
        if (coverage.covered) {
            try registerContext(result, io, environment, options, current);
            try result.put(
                "source_coverage",
                if (options.context.workspace != null) "checked" else "not_checked",
            );
            return;
        }
    }
    if (!options.ensure) return error.OwnerPreparationRequired;
    _ = try preparation.selectedSlot(&plan.storage_plan.?);
    try prepare(
        result,
        io,
        environment,
        options,
        plan,
        bindings,
        selected,
        retired,
        discover_archives,
    );
}

fn resolveOwnerContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    associations: *const host.workspace.Associations,
) !?host.Context {
    return resolveExisting(allocator, io, environment, options.context, associations) catch |err| {
        if (err != error.SelectedStoreNotCataloged or options.ensure or
            options.context.workspace != null)
            return err;
        return try pending.readById(
            allocator,
            io,
            options.context.catalog_root,
            options.context.store_id.?,
        );
    };
}

fn admitRead(
    result: *Result,
    io: std.Io,
    options: Options,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    associations: *const host.workspace.Associations,
    selected: host.ContextValue,
) !void {
    const allocator = result.arena.allocator();
    try result.setContext(selected);
    try result.put("source_coverage", "not_checked");
    try pending.checkPendingContext(
        allocator,
        io,
        associations,
        options.context.catalog_root,
        selected,
    );
    var health = try inspect(allocator, io, plan, bindings, selected);
    defer health.deinit(allocator);
    try result.put("owner_health", health);
    if (health.preparation_error) |failure| return result.block(failure);
    if (health.pending_transactions != 0) return error.TransactionRecoveryRequired;
    if (health.preparation_pending) return error.OwnerPreparationRequired;
    if (health.slots[0].error_code) |failure| return result.block(failure);
    if (health.slots[0].state == .missing) return error.OwnerPreparationRequired;
    if (!health.healthy) return error.OwnerHistoryUnhealthy;
}

const OwnerReadiness = enum { present, preparation, blocked };

fn admitPresentOwner(
    result: *Result,
    io: std.Io,
    options: Options,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    associations: *const host.workspace.Associations,
    selected: host.ContextValue,
) !OwnerReadiness {
    const allocator = result.arena.allocator();
    try result.setContext(selected);
    try result.put("source_coverage", "not_checked");
    try pending.checkPendingContext(
        allocator,
        io,
        associations,
        options.context.catalog_root,
        selected,
    );
    var waited = false;
    for (0..writer_attempts_max) |attempt| {
        var health = try inspect(allocator, io, plan, bindings, selected);
        defer health.deinit(allocator);
        if (busyHealth(health)) |failure| {
            if (attempt == writer_attempts_max - 1) return blockedReadiness(result, failure);
            try waitForWriter(io, if (waited) 1 else 0);
            waited = true;
            continue;
        }
        if (health.preparation_error) |failure| {
            if (!std.mem.eql(u8, failure, "TransactionRecoveryRequired"))
                return blockedReadiness(result, failure);
        }
        if (health.pending_transactions != 0 or health.preparation_pending) {
            if (attempt == writer_attempts_max - 1) return error.TransactionRecoveryRequired;
            recoverSelectedOwner(result, io, selected) catch |err| {
                if (err != error.LockBusy and err != error.EventStoreBusy) return err;
                try waitForWriter(io, if (waited) 1 else 0);
                waited = true;
            };
            continue;
        }
        if (health.slots[0].state == .missing and health.slots[0].error_code == null)
            return .preparation;
        if (health.slots[0].error_code) |failure| {
            if (std.mem.eql(u8, failure, "StoreBindingWithoutSlot")) return .preparation;
            try result.put("owner_health", health);
            return blockedReadiness(result, failure);
        }
        try result.put("owner_health", health);
        if (!health.healthy) return error.OwnerHistoryUnhealthy;
        return .present;
    }
    unreachable;
}

fn busyHealth(health: doctor.Result) ?[]const u8 {
    const failures = [_]?[]const u8{ health.preparation_error, health.slots[0].error_code };
    for (failures) |failure| if (failure) |code| {
        if (std.mem.eql(u8, code, "LockBusy") or std.mem.eql(u8, code, "EventStoreBusy"))
            return code;
    };
    return null;
}

fn recoverSelectedOwner(result: *Result, io: std.Io, selected: host.ContextValue) !void {
    const allocator = result.arena.allocator();
    const control = try storage_root.checkedRoot(
        allocator,
        io,
        selected.store_root,
        selected.store_id,
    );
    defer control.close(io);
    var scope = storage_root.Scope.init(.anchored(io, control));
    const transaction = @import("ledger_v1_core").transaction;
    var budget: storage_root.ReadBudget = .{
        .max_bytes = history_limits.max_read_bytes,
        .max_files = history_limits.max_files * 16,
    };
    scope.fs.read_budget = &budget;
    var created = false;
    const guard = try durable.acquireCasAdvisoryLockObserved(
        scope.fs,
        allocator,
        ".preparation",
        &created,
    );
    defer guard.close(io);
    if (created) {
        transaction.markStorageMutated(&scope);
        try result.observeMutation(true);
    }
    const recovered = transaction.recoverRepositoryTransactions(
        &scope,
        allocator,
        ".",
    ) catch |err| {
        try result.observeMutation(scope.mutation_state);
        return err;
    };
    if (recovered) transaction.markStorageMutated(&scope);
    try result.observeMutation(scope.mutation_state);
    try recheckTarget(allocator, io, selected, control);
}

fn requireWorkspaceForMissingOwner(
    result: *Result,
    io: std.Io,
    options: Options,
    selected: host.ContextValue,
) !void {
    if (options.context.workspace != null) return;
    var catalog = try host.catalog.read(result.arena.allocator(), io, options.context.catalog_root);
    defer catalog.deinit();
    for (catalog.value.aliases.map.keys(), catalog.value.aliases.map.values()) |alias, id| {
        if (std.mem.eql(u8, id, selected.store_id) and
            (std.mem.startsWith(u8, alias, "workspace:") or
                std.mem.startsWith(u8, alias, "git-common-dir:")))
            return error.OwnerPreparationRequiresWorkspace;
    }
}

fn blockedReadiness(result: *Result, failure: []const u8) !OwnerReadiness {
    try result.block(failure);
    return .blocked;
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
            result,
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
            result,
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

fn discoverSources(
    result: *Result,
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    workspace: ?[]const u8,
    selected: ?host.ContextValue,
    slot: []const u8,
    retired: []const []const u8,
    archives: bool,
) !discovery.Sources {
    var diagnostic: discovery.Diagnostic = .{};
    defer diagnostic.deinit(allocator);
    return discovery.discoverObserved(
        allocator,
        io,
        environment,
        workspace,
        selected,
        slot,
        retired,
        archives,
        &diagnostic,
    ) catch |err| {
        if (diagnostic.source_root != null) try result.put("source_failure", diagnostic);
        return err;
    };
}

fn missingCovered(
    result: *Result,
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    selected: host.ContextValue,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    retired: []const []const u8,
) !bool {
    var sources = try discoverSources(
        result,
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
    if (plan.storage_plan.?.slots[0].layout == .segmented) {
        try requireSegmentedSourcesAbsent(
            allocator,
            io,
            environment,
            selected,
            plan,
            &sources,
            options.confirm_no_writers,
            true,
        );
        return true;
    }
    return coverSources(
        result,
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

fn registerContext(
    result: *Result,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    selected: host.ContextValue,
) !void {
    try result.beginMutation();
    var cataloged = selected.cataloged;
    defer result.value.object.getPtr("cataloged").?.* = .{ .bool = cataloged };
    var registered = try host.registerRootObserved(
        result.arena.allocator(),
        io,
        environment,
        options.context,
        selected.store_root,
        selected.store_id,
        &cataloged,
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
    var registered = try host.catalog.read(allocator, io, options.catalog_root);
    defer registered.deinit();
    return try host.checkedRoot(
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
    result: *Result,
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    selected: host.ContextValue,
    plan: *const compiled.PlanSet,
    bindings: *const parameters.Bindings,
    confirm_no_writers: bool,
) !bool {
    const root = selected.workspace_root orelse return true;
    var sources = try discoverSources(
        result,
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
        try requireSegmentedSourcesAbsent(
            allocator,
            io,
            environment,
            selected,
            plan,
            &sources,
            confirm_no_writers,
            false,
        );
        return true;
    }
    return coverSources(
        result,
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
    result: *Result,
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
    var coordination = try SourceCoordination.acquire(
        result,
        io,
        plan,
        sources.sources,
        target_dir,
        confirm_no_writers,
    );
    defer coordination.deinit();
    return coverCoordinatedSources(
        allocator,
        io,
        environment,
        selected,
        plan,
        bindings,
        sources,
        confirm_no_writers,
        target_present,
        discover_archives,
        target_dir,
        &coordination,
    );
}

fn coverCoordinatedSources(
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
    target_dir: std.Io.Dir,
    coordination: *const SourceCoordination,
) !bool {
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
    try coordination.revalidate();
    try recheckTarget(allocator, io, selected, target_dir);
    return covered;
}

const SourceCoordination = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    held: std.ArrayList(Held) = .empty,

    const Held = struct {
        source: preparation.Source,
        root: std.Io.Dir,
        control: std.Io.Dir,
        locks: durable.CasReadLockPair,
    };

    fn deinit(self: *SourceCoordination) void {
        for (self.held.items) |*held| {
            held.locks.deinit();
            held.control.close(self.io);
            held.root.close(self.io);
        }
        self.held.deinit(self.allocator);
    }

    fn acquire(
        result: *Result,
        io: std.Io,
        plan: *const compiled.PlanSet,
        sources: []const preparation.Source,
        target: ?std.Io.Dir,
        confirmed: bool,
    ) !SourceCoordination {
        for (0..writer_attempts_max) |attempt| {
            if (acquireOnce(result, io, plan, sources, target, confirmed)) |guards| {
                _ = result.value.object.swapRemove("source_failure");
                return guards;
            } else |err| {
                if ((err != error.LockBusy and err != error.EventStoreBusy) or
                    attempt == writer_attempts_max - 1) return err;
                try waitForWriter(io, attempt);
            }
        }
        unreachable;
    }

    fn acquireOnce(
        result: *Result,
        io: std.Io,
        plan: *const compiled.PlanSet,
        sources: []const preparation.Source,
        target: ?std.Io.Dir,
        confirmed: bool,
    ) !SourceCoordination {
        var guards: SourceCoordination = .{ .allocator = result.arena.allocator(), .io = io };
        errdefer guards.deinit();
        if (confirmed or plan.storage_plan.?.slots[0].layout == .segmented) return guards;
        for (sources) |source| {
            if (source.archive) continue;
            if (target) |target_control| {
                if (try openCoverageSource(guards.allocator, io, source)) |source_control| {
                    defer source_control.close(io);
                    if (try durable.sameDirectoryObject(io, source_control, target_control))
                        continue;
                }
            }
            try guards.held.ensureUnusedCapacity(guards.allocator, 1);
            var mutated = false;
            const held = guards.acquireSource(source, plan, &mutated) catch |err| {
                try observeSourceMutation(result, mutated);
                try result.put("source_failure", .{
                    .source_root = source.root,
                    .owner = plan.definition_plan.id,
                    .error_code = @errorName(err),
                });
                return err;
            };
            guards.held.appendAssumeCapacity(held);
            try observeSourceMutation(result, mutated);
        }
        return guards;
    }

    fn observeSourceMutation(result: *Result, mutated: bool) !void {
        if (!mutated) return;
        try result.observeMutation(true);
        try result.put("source_coordination_mutated", true);
        try result.put("source_coordination_scope", "selected-owner-advisory-locks");
    }

    fn acquireSource(
        self: *SourceCoordination,
        source: preparation.Source,
        plan: *const compiled.PlanSet,
        mutated: *bool,
    ) !Held {
        const io = self.io;
        const allocator = self.allocator;
        const root = try host.catalog.openDirectory(io, source.root, false);
        errdefer root.close(io);
        var control = try openCoverageSource(allocator, io, source);
        if (control == null) {
            const fs = durable.Fs.anchored(io, root);
            try durable.ensureDirectoryPathNoSymlinksObserved(fs, ".ledger", mutated);
            control = try root.openDir(io, ".ledger", .{ .follow_symlinks = false });
        }
        const directory = control.?;
        errdefer directory.close(io);
        var scope = storage_root.Scope.init(.anchored(io, directory));
        const slot = plan.storage_plan.?.slots[0].relative_path;
        var paths = try @import("ledger_v1_core").segmented_event_log.Paths.init(
            &scope,
            allocator,
            ".",
            slot,
        );
        defer paths.deinit(allocator);
        try durable.ensureNoPendingTransactions(scope.fs, allocator, ".transactions");
        var initial = try durable.acquireCasReadLockPair(
            scope.fs,
            allocator,
            slot,
            paths.legacy_binding,
        );
        defer initial.deinit();
        const incomplete = initial.count != 2;
        if (incomplete)
            try self.establishAbsentLocks(scope.fs, directory, slot, &paths, mutated);
        var locks = try durable.acquireCasReadLockPair(
            scope.fs,
            allocator,
            slot,
            paths.legacy_binding,
        );
        errdefer locks.deinit();
        if (locks.count != 2) return error.PreparationRequiresQuiescence;
        try durable.ensureNoPendingTransactions(scope.fs, allocator, ".transactions");
        if (incomplete and !try selectedAbsent(io, scope.fs, directory, &paths))
            return error.SourceChangedDuringPreparation;
        const held: Held = .{
            .source = source,
            .root = root,
            .control = directory,
            .locks = locks,
        };
        try self.revalidateOne(held);
        return held;
    }

    fn establishAbsentLocks(
        self: *const SourceCoordination,
        fs: durable.Fs,
        directory: std.Io.Dir,
        slot: []const u8,
        paths: *const @import("ledger_v1_core").segmented_event_log.Paths,
        mutated: *bool,
    ) !void {
        const io = self.io;
        const allocator = self.allocator;
        if (!try selectedAbsent(io, fs, directory, paths)) {
            const event_exists = try host.catalog.existsAt(io, directory, slot);
            const binding_exists = try host.catalog.existsAt(io, directory, paths.legacy_binding);
            if (binding_exists and !event_exists) return error.StoreBindingWithoutSlot;
            if (event_exists and !binding_exists) return error.StoreSlotWithoutBinding;
            if (try host.catalog.existsAt(io, directory, paths.manifest))
                return error.SegmentedLocalCoverageRequiresMigration;
            return error.PreparationRequiresQuiescence;
        }
        for ([_][]const u8{ slot, paths.legacy_binding }) |path| {
            if (try durable.casAdvisoryLockExists(fs, allocator, path)) continue;
            try durable.ensureDirectoryPathNoSymlinksObserved(
                fs,
                std.fs.path.dirname(path) orelse ".",
                mutated,
            );
            const lock = try durable.acquireCasAdvisoryLockObserved(fs, allocator, path, mutated);
            lock.close(io);
        }
    }

    fn selectedAbsent(
        io: std.Io,
        fs: durable.Fs,
        directory: std.Io.Dir,
        paths: *const @import("ledger_v1_core").segmented_event_log.Paths,
    ) !bool {
        for ([_][]const u8{ paths.legacy_event, paths.legacy_binding, paths.manifest }) |path| {
            try durable.rejectSymlinkComponents(fs, path);
            if (try host.catalog.existsAt(io, directory, path)) return false;
        }
        return true;
    }

    fn revalidate(self: *const SourceCoordination) !void {
        for (self.held.items) |held| try self.revalidateOne(held);
    }

    fn revalidateOne(self: *const SourceCoordination, held: Held) !void {
        const root = try host.catalog.openDirectory(self.io, held.source.root, false);
        defer root.close(self.io);
        if (!try durable.sameDirectoryObject(self.io, held.root, root))
            return error.SourceChangedDuringPreparation;
        const control = (try openCoverageSource(self.allocator, self.io, held.source)) orelse
            return error.SourceChangedDuringPreparation;
        defer control.close(self.io);
        if (!try durable.sameDirectoryObject(self.io, held.control, control))
            return error.SourceChangedDuringPreparation;
    }
};

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

fn requireSegmentedSourcesAbsent(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    selected: host.ContextValue,
    plan: *const compiled.PlanSet,
    sources: *const discovery.Sources,
    confirm_no_writers: bool,
    discover_archives: bool,
) !void {
    const controls = try allocator.alloc(?std.Io.Dir, sources.sources.len);
    defer allocator.free(controls);
    @memset(controls, null);
    defer for (controls) |control| if (control) |dir| dir.close(io);
    const guards = try allocator.alloc([2]?durable.CasReadLockPair, sources.sources.len);
    defer allocator.free(guards);
    @memset(guards, .{ null, null });
    defer for (guards) |*pair| for (pair) |*guard| if (guard.*) |*held| held.deinit();
    for (sources.sources, controls, guards) |source, *control, *pair| {
        if (source.archive) return error.SegmentedLocalCoverageRequiresMigration;
        control.* = try openCoverageSource(allocator, io, source);
        const directory = control.* orelse {
            if (!confirm_no_writers) return error.PreparationRequiresQuiescence;
            continue;
        };
        var scope = storage_root.Scope.init(.anchored(io, directory));
        var paths = try @import("ledger_v1_core").segmented_event_log.Paths.init(
            &scope,
            allocator,
            ".",
            plan.storage_plan.?.slots[0].relative_path,
        );
        defer paths.deinit(allocator);
        try durable.ensureNoPendingTransactions(scope.fs, allocator, ".transactions");
        pair[0] = try durable.acquireCasReadLockPair(
            scope.fs,
            allocator,
            paths.legacy_event,
            paths.legacy_binding,
        );
        pair[1] = try durable.acquireCasReadLockPair(
            scope.fs,
            allocator,
            paths.manifest,
            paths.manifest,
        );
        try durable.ensureNoPendingTransactions(scope.fs, allocator, ".transactions");
        for ([_][]const u8{ paths.legacy_event, paths.legacy_binding, paths.manifest }) |path| {
            try durable.rejectSymlinkComponents(scope.fs, path);
            if (try host.catalog.existsAt(io, directory, path))
                return error.SegmentedLocalCoverageRequiresMigration;
        }
        if (!confirm_no_writers and (pair[0].?.count != 2 or pair[1].?.count != 1))
            return error.PreparationRequiresQuiescence;
    }
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
        var sources = try discoverSources(
            result,
            allocator,
            io,
            environment,
            options.context.workspace,
            null,
            plan.storage_plan.?.slots[0].relative_path,
            retired,
            false,
        );
        defer sources.deinit();
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
    var sources = try discoverSources(
        result,
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
    if (options.repair_archive) try requireArchiveEvidence(sources.sources);
    const control = try storage_root.checkedRoot(
        allocator,
        io,
        selected.store_root,
        selected.store_id,
    );
    defer control.close(io);
    var coordination = try SourceCoordination.acquire(
        result,
        io,
        plan,
        sources.sources,
        control,
        options.confirm_no_writers,
    );
    defer coordination.deinit();
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
    try coordination.revalidate();
    try registerContext(result, io, environment, options, selected);
    try result.put(
        "source_coverage",
        if (options.context.workspace != null) "checked" else "not_checked",
    );
}

fn requireArchiveEvidence(sources: []const preparation.Source) !void {
    for (sources) |source| if (source.archive) return;
    return error.ArchiveRepairRequiresArchiveEvidence;
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
        if (!selected.storage_mutated) try result.observeMutation(scope.mutation_state);
        return err;
    };
    defer prepared.deinit(allocator);
    prepared.store_id = selected.store_id;
    prepared.store_root = selected.store_root;
    try result.put("preparation", prepared);
    if (!selected.storage_mutated) try result.observeMutation(prepared.storage_mutated);
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
    for (0..writer_attempts_max) |attempt| {
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
        ) or result.storage_mutated != false or attempt == writer_attempts_max - 1) return result;
        result.deinit(allocator);
        try waitForWriter(scope.fs.io, attempt);
    }
    unreachable;
}

fn waitForWriter(io: std.Io, attempt: usize) !void {
    if (attempt == 0) {
        var writer = std.Io.File.stderr().writer(io, &.{});
        try writer.interface.writeAll("Waiting for active Ledger writer\n");
        try writer.interface.flush();
    }
    try std.Io.sleep(io, .fromMilliseconds(writer_retry_delay_ms), .awake);
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

test "empty owner establishes native source custody and keeps canonical progress independent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = try host.workspace.testPlainDirectory();
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(io, ".", owned);
    try testOwnerInputs(temporary.dir);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var options = try testOwnerOptions(owned, root);
    options.ensure = true;
    var initialized = try execute(allocator, io, &environment, options);
    defer initialized.deinit();
    try std.testing.expectEqual(@as(u8, 0), initialized.exit_code);
    try std.testing.expect(initialized.value.object.get("storage_mutated").?.bool);
    try std.testing.expect(initialized.value.object.get("source_coordination_mutated").?.bool);
    try std.testing.expectEqualStrings(
        "checked",
        initialized.value.object.get("source_coverage").?.string,
    );
    const id = initialized.value.object.get("store_id").?.string;
    const target = initialized.value.object.get("store_root").?.string;
    try std.testing.expect(!try host.catalog.existsAt(
        io,
        temporary.dir,
        "workspace/.ledger/example/events.jsonl",
    ));
    var empty = try execute(allocator, io, &environment, options);
    defer empty.deinit();
    try std.testing.expectEqual(@as(u8, 0), empty.exit_code);
    try std.testing.expectEqualStrings(id, empty.value.object.get("store_id").?.string);
    try std.testing.expect(!empty.value.object.get("storage_mutated").?.bool);
    try testAppendOwner(&environment, options.definition, target);
    try temporary.dir.deleteTree(io, "workspace/.ledger");
    for ([_]bool{ false, true }) |by_id| {
        var current = options;
        if (by_id) {
            current.context.workspace = null;
            current.context.store_id = id;
        }
        var selected = try execute(allocator, io, &environment, current);
        defer selected.deinit();
        try std.testing.expectEqual(@as(u8, 0), selected.exit_code);
        try std.testing.expectEqualStrings(id, selected.value.object.get("store_id").?.string);
        try std.testing.expectEqualStrings(
            "not_checked",
            selected.value.object.get("source_coverage").?.string,
        );
        try std.testing.expect(!selected.value.object.get("storage_mutated").?.bool);
        try std.testing.expect(!try host.catalog.existsAt(io, temporary.dir, "workspace/.ledger"));
    }
    options.reconcile = true;
    var reconciled = try execute(allocator, io, &environment, options);
    defer reconciled.deinit();
    try std.testing.expectEqual(@as(u8, 0), reconciled.exit_code);
    try std.testing.expectEqualStrings(id, reconciled.value.object.get("store_id").?.string);
    try std.testing.expectEqualStrings(
        "checked",
        reconciled.value.object.get("source_coverage").?.string,
    );
    try std.testing.expect(reconciled.value.object.get("storage_mutated").?.bool);
}

test "segmented owner absence needs quiescence or all existing publication guards" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = try host.workspace.testPlainDirectory();
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(io, ".", owned);
    try testOwnerInputs(temporary.dir);
    try testSegmentedDefinition(owned, temporary.dir);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var options: Options = .{
        .context = .{
            .catalog_root = try std.fs.path.join(owned, &.{ root, "home" }),
            .workspace = try std.fs.path.join(owned, &.{ root, "workspace" }),
        },
        .definition = try std.fs.path.join(owned, &.{ root, "definition.json" }),
        .manifest = try std.fs.path.join(owned, &.{ root, "migration.json" }),
        .ensure = true,
    };
    var initialized = try host.initialize(allocator, io, &environment, options.context);
    defer initialized.deinit();
    try expectOwnerError(io, &environment, options, "PreparationRequiresQuiescence");
    options.confirm_no_writers = true;
    var quiescent = try execute(allocator, io, &environment, options);
    defer quiescent.deinit();
    try std.testing.expectEqual(@as(u8, 0), quiescent.exit_code);
    try temporary.dir.createDirPath(io, "workspace/.ledger/.transactions/dtx-first");
    try expectOwnerError(io, &environment, options, "TransactionRecoveryRequired");
    try temporary.dir.deleteDir(io, "workspace/.ledger/.transactions/dtx-first");
    options.confirm_no_writers = false;
    const control = try temporary.dir.openDir(io, "workspace/.ledger", .{});
    defer control.close(io);
    var scope = storage_root.Scope.init(.anchored(io, control));
    var paths = try @import("ledger_v1_core").segmented_event_log.Paths.init(
        &scope,
        allocator,
        ".",
        "example/chained-events.jsonl",
    );
    defer paths.deinit(allocator);
    for ([_][]const u8{ paths.legacy_event, paths.legacy_binding, paths.manifest }) |path| {
        try expectOwnerError(io, &environment, options, "PreparationRequiresQuiescence");
        try control.createDirPath(io, std.fs.path.dirname(path).?);
        const guard = try @import("durable_store").acquireCasAdvisoryLock(
            scope.fs,
            allocator,
            path,
        );
        guard.close(io);
    }
    var protected = try execute(allocator, io, &environment, options);
    defer protected.deinit();
    try std.testing.expectEqual(@as(u8, 0), protected.exit_code);
    try std.testing.expect(!protected.value.object.get("storage_mutated").?.bool);
    try control.writeFile(io, .{ .sub_path = paths.manifest, .data = "present" });
    try expectOwnerError(io, &environment, options, "SegmentedLocalCoverageRequiresMigration");
}

test "empty source coordination excludes participating writers through held custody" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = try host.workspace.testPlainDirectory();
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(io, ".", owned);
    try testOwnerInputs(temporary.dir);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const options = try testOwnerOptions(owned, root);
    var scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
    var plan = try cli.loadDefinitionWithCache(
        &scope,
        allocator,
        &environment,
        options.definition,
        .{ .kind = .doctor },
        false,
    );
    defer plan.deinit(allocator);
    var result: Result = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .value = .{ .object = .{} },
    };
    defer result.deinit();
    try result.put("storage_mutated", false);
    {
        var guards = try SourceCoordination.acquire(
            &result,
            io,
            &plan,
            &.{.{ .root = options.context.workspace.? }},
            null,
            false,
        );
        defer guards.deinit();
        try std.testing.expect(result.value.object.get("storage_mutated").?.bool);
        try std.testing.expect(result.value.object.get("source_coordination_mutated").?.bool);
        const control = guards.held.items[0].control;
        var source_scope = storage_root.Scope.init(.anchored(io, control));
        const slot = plan.storage_plan.?.slots[0].relative_path;
        const binding = try @import("ledger_v1_core").custody.bindingPathAlloc(
            &source_scope,
            allocator,
            ".",
            slot,
        );
        defer allocator.free(binding);
        for ([_][]const u8{ slot, binding }) |path| {
            try std.testing.expect(!try host.catalog.existsAt(io, control, path));
            try std.testing.expectError(
                error.LockBusy,
                durable.acquireCasAdvisoryLock(source_scope.fs, allocator, path),
            );
        }
        try guards.revalidate();
    }
    const control = try temporary.dir.openDir(io, "workspace/.ledger", .{});
    defer control.close(io);
    const lock = try durable.acquireCasAdvisoryLock(
        .anchored(io, control),
        allocator,
        plan.storage_plan.?.slots[0].relative_path,
    );
    lock.close(io);
}

test "owner preparation keeps incomplete historic coordination and source failures explicit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = try host.workspace.testPlainDirectory();
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(io, ".", owned);
    try testOwnerInputs(temporary.dir);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var options = try testOwnerOptions(owned, root);
    options.ensure = true;
    var selected = try host.initialize(allocator, io, &environment, options.context);
    defer selected.deinit();
    try testAppendOwner(&environment, options.definition, options.context.workspace.?);
    const source = try temporary.dir.openDir(io, "workspace/.ledger", .{});
    defer source.close(io);
    const advisory = "example/events.jsonl.cas.lock.advisory";
    try source.deleteFile(io, advisory);
    try expectOwnerError(io, &environment, options, "PreparationRequiresQuiescence");
    try std.testing.expect(!try host.catalog.existsAt(io, source, advisory));
    try source.createDirPath(io, ".transactions/dtx-first");
    try expectOwnerError(io, &environment, options, "TransactionRecoveryRequired");
    try source.deleteDir(io, ".transactions/dtx-first");
    try source.deleteFile(io, "example/events.jsonl");
    var failed = try execute(allocator, io, &environment, options);
    defer failed.deinit();
    try std.testing.expectEqual(@as(u8, 3), failed.exit_code);
    try std.testing.expectEqualStrings(
        "StoreBindingWithoutSlot",
        failed.value.object.get("error_code").?.string,
    );
    try expectSourceFailure(&failed, options.context.workspace.?);
    try std.testing.expect(!failed.value.object.get("storage_mutated").?.bool);
    try temporary.dir.createDir(io, "empty", .default_dir);
    const empty_root = try std.fs.path.join(owned, &.{ root, "empty" });
    var scope = storage_root.Scope.init(.init(io, std.Io.Dir.cwd()));
    var plan = try cli.loadDefinitionWithCache(
        &scope,
        allocator,
        &environment,
        options.definition,
        .{ .kind = .doctor },
        false,
    );
    defer plan.deinit(allocator);
    var observed: Result = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .value = .{ .object = .{} },
    };
    defer observed.deinit();
    try observed.put("storage_mutated", false);
    try std.testing.expectError(error.StoreBindingWithoutSlot, SourceCoordination.acquire(
        &observed,
        io,
        &plan,
        &.{
            .{ .root = empty_root },
            .{ .root = options.context.workspace.? },
        },
        null,
        false,
    ));
    try std.testing.expect(observed.value.object.get("storage_mutated").?.bool);
    try std.testing.expect(observed.value.object.get("source_coordination_mutated").?.bool);
    try expectSourceFailure(&observed, options.context.workspace.?);
}

fn expectSourceFailure(result: *const Result, root: []const u8) !void {
    try std.testing.expectEqualStrings(
        root,
        result.value.object.get("source_failure").?.object.get("source_root").?.string,
    );
}

fn testSegmentedDefinition(allocator: std.mem.Allocator, directory: std.Io.Dir) !void {
    const segmented = try std.mem.replaceOwned(
        u8,
        allocator,
        @embedFile("fixtures/chained-event-definition.json"),
        "\"codec\":\"jsonl\",\"max_bytes\":65536",
        "\"codec\":\"jsonl\",\"layout\":\"segmented\",\"max_bytes\":67108864",
    );
    defer allocator.free(segmented);
    const definition = try std.mem.replaceOwned(
        u8,
        allocator,
        segmented,
        ",\"idempotency_param\":\"request\"",
        "",
    );
    defer allocator.free(definition);
    try directory.writeFile(std.testing.io, .{ .sub_path = "definition.json", .data = definition });
}

test "canonical read preserves missing-binding diagnosis and selected identity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = try host.workspace.testPlainDirectory();
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(io, ".", owned);
    try testOwnerInputs(temporary.dir);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var options = try testOwnerOptions(owned, root);
    var selected = try host.initialize(allocator, io, &environment, options.context);
    defer selected.deinit();
    try expectOwnerError(io, &environment, options, "OwnerPreparationRequired");
    try testAppendOwner(&environment, options.definition, selected.value.store_root);
    const target = try host.catalog.openDirectory(io, selected.value.store_root, false);
    defer target.close(io);
    try target.deleteFile(io, ".ledger/example/events.jsonl");
    for ([_]bool{ false, true }) |by_id| {
        if (by_id) {
            options.context.workspace = null;
            options.context.store_id = selected.value.store_id;
        }
        var result = try execute(allocator, io, &environment, options);
        defer result.deinit();
        try std.testing.expectEqual(@as(u8, 3), result.exit_code);
        try std.testing.expectEqualStrings(
            "StoreBindingWithoutSlot",
            result.value.object.get("error_code").?.string,
        );
        try std.testing.expectEqualStrings(
            selected.value.store_id,
            result.value.object.get("store_id").?.string,
        );
        try std.testing.expectEqualStrings(
            "not_checked",
            result.value.object.get("source_coverage").?.string,
        );
        try std.testing.expect(!result.value.object.get("storage_mutated").?.bool);
        try std.testing.expect(!try host.catalog.existsAt(
            io,
            target,
            ".ledger/example/events.jsonl",
        ));
    }
}

test "retained pending owner remains readable by identity after workspace removal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = try host.workspace.testPlainDirectory();
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const owned = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(io, ".", owned);
    try testOwnerInputs(temporary.dir);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var options = try testOwnerOptions(owned, root);
    const selected = blk: {
        var target = try pending.prepareTarget(allocator, io, &environment, options.context, true);
        defer target.deinit();
        break :blk try host.context(
            owned,
            target.context.value.store_root,
            target.context.value.store_id,
            null,
            null,
            false,
            target.context.value.cataloged,
        );
    };
    try testAppendOwner(&environment, options.definition, selected.value.store_root);
    try temporary.dir.deleteDir(io, "workspace");
    options.context.workspace = null;
    options.context.store_id = selected.value.store_id;
    var before = try host.list(allocator, io, options.context.catalog_root);
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 0), before.value.stores.len);
    try std.testing.expectEqual(@as(usize, 1), before.value.pending.len);
    try std.testing.expectEqualStrings(
        selected.value.store_id,
        before.value.pending[0].registration.store_id,
    );
    try std.testing.expectEqual(.materialized, before.value.pending[0].state);
    var read = try execute(allocator, io, &environment, options);
    defer read.deinit();
    try std.testing.expectEqual(@as(u8, 0), read.exit_code);
    try std.testing.expect(!read.value.object.get("cataloged").?.bool);
    try std.testing.expect(!read.value.object.get("storage_mutated").?.bool);
    try testFailedPendingAllocation(owned, &environment, options, root, &read);
    options.ensure = true;
    try expectOwnerError(io, &environment, options, "SelectedStoreNotCataloged");
    try testRegisterPendingRead(&environment, options, selected.value, &read);
}

fn testFailedPendingAllocation(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    options: Options,
    root: []const u8,
    original: *const Result,
) !void {
    const io = std.testing.io;
    const path = try std.fs.path.join(allocator, &.{
        options.context.catalog_root, "preparations",
    });
    const controls = try host.catalog.openDirectory(io, path, false);
    defer controls.close(io);
    for (0..127) |index| {
        const name = try std.fmt.allocPrint(allocator, "{x:0>64}", .{index});
        try controls.createDir(io, name, .fromMode(0o700));
    }
    var before = try host.list(std.testing.allocator, io, options.context.catalog_root);
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 1), before.value.pending.len);
    var healthy = try execute(std.testing.allocator, io, environment, options);
    defer healthy.deinit();
    try std.testing.expectEqual(@as(u8, 0), healthy.exit_code);
    const workspace = try std.fs.path.join(allocator, &.{ root, "another" });
    const directory = try host.catalog.openDirectory(io, workspace, true);
    defer directory.close(io);
    try std.testing.expectError(error.PendingCustodyDiscoveryBoundExceeded, pending.prepareTarget(
        std.testing.allocator,
        io,
        environment,
        .{ .catalog_root = options.context.catalog_root, .workspace = workspace },
        true,
    ));
    var retried = try execute(std.testing.allocator, io, environment, options);
    defer retried.deinit();
    try std.testing.expectEqual(@as(u8, 0), retried.exit_code);
    const original_health = try std.json.Stringify.valueAlloc(
        allocator,
        original.value.object.get("owner_health").?,
        .{},
    );
    const retried_health = try std.json.Stringify.valueAlloc(
        allocator,
        retried.value.object.get("owner_health").?,
        .{},
    );
    try std.testing.expectEqualStrings(original_health, retried_health);
    var after = try host.list(std.testing.allocator, io, options.context.catalog_root);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.value.pending.len);
    const rejected = try pending.controlsPath(
        allocator,
        workspace,
        null,
        options.context.catalog_root,
    );
    try std.testing.expect(!try host.catalog.exists(io, rejected));
}

fn testOwnerOptions(allocator: std.mem.Allocator, root: []const u8) !Options {
    return .{
        .context = .{
            .catalog_root = try std.fs.path.join(allocator, &.{ root, "home" }),
            .workspace = try std.fs.path.join(allocator, &.{ root, "workspace" }),
        },
        .definition = try std.fs.path.join(allocator, &.{ root, "definition.json" }),
        .manifest = try std.fs.path.join(allocator, &.{ root, "migration.json" }),
    };
}

fn testRegisterPendingRead(
    environment: *const std.process.Environ.Map,
    options: Options,
    selected: host.ContextValue,
    original: *const Result,
) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(
        error.SelectedStoreNotCataloged,
        host.resolve(allocator, io, environment, options.context),
    );
    var registered = try host.registerRoot(
        allocator,
        io,
        environment,
        options.context,
        selected.store_root,
        selected.store_id,
    );
    defer registered.deinit();
    // Publication can occur between the catalog miss and retained-ID fallback.
    var fallback = try pending.readById(
        allocator,
        io,
        options.context.catalog_root,
        selected.store_id,
    );
    defer fallback.deinit();
    try std.testing.expect(fallback.value.cataloged);
    try std.testing.expect(!fallback.value.storage_mutated);
    try std.testing.expectEqualStrings(selected.store_id, fallback.value.store_id);
    try std.testing.expectEqualStrings(selected.store_root, fallback.value.store_root);
    var after = try host.list(allocator, io, options.context.catalog_root);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.value.stores.len);
    try std.testing.expectEqual(@as(usize, 0), after.value.pending.len);
    try std.testing.expectEqualStrings(selected.store_id, after.value.stores[0].store_id);
    var read_options = options;
    read_options.ensure = false;
    var retry = try execute(allocator, io, environment, read_options);
    defer retry.deinit();
    try std.testing.expectEqual(@as(u8, 0), retry.exit_code);
    try std.testing.expect(retry.value.object.get("cataloged").?.bool);
    const original_health = original.value.object.get("owner_health").?.object;
    const original_slot = original_health.get("slots").?.array.items[0].object;
    const retried_health = retry.value.object.get("owner_health").?.object;
    const retried_slot = retried_health.get("slots").?.array.items[0].object;
    try std.testing.expectEqualStrings(
        original_slot.get("revision").?.string,
        retried_slot.get("revision").?.string,
    );
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
        .confirm_no_writers = true,
    });
    defer result.deinit();
    try interleaving.verify(result);
    const target = try host.catalog.openDirectory(io, selected.value.store_root, false);
    defer target.close(io);
    try expectOwnerBytes(target, original);
    try expectOwnerBytes(workspace_dir, original);
}

fn expectOwnerError(
    io: std.Io,
    environment: *const std.process.Environ.Map,
    options: Options,
    expected: []const u8,
) !void {
    var result = try execute(std.testing.allocator, io, environment, options);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 3), result.exit_code);
    try std.testing.expectEqualStrings(expected, result.value.object.get("error_code").?.string);
    try std.testing.expect(!result.value.object.get("storage_mutated").?.bool);
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

test "owner registration retains observed membership across publication failures" {
    const fault = host.catalog.TestPublicationFault;
    for ([_]bool{ false, true }) |published| {
        for (std.enums.values(fault.Kind)) |kind| {
            const allocator = std.testing.allocator;
            const io = std.testing.io;
            var temporary = try host.workspace.testPlainDirectory();
            defer temporary.cleanup();
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const owned = arena.allocator();
            const root = try temporary.dir.realPathFileAlloc(io, ".", owned);
            try testOwnerInputs(temporary.dir);
            const options = try testOwnerOptions(owned, root);
            var environment = std.process.Environ.Map.init(allocator);
            defer environment.deinit();
            var seed = try host.initialize(allocator, io, &environment, .{
                .catalog_root = try std.fs.path.join(owned, &.{ root, "catalog-seed" }),
            });
            defer seed.deinit();
            if (published) {
                var registered = try host.registerRoot(allocator, io, &environment, .{
                    .catalog_root = options.context.catalog_root,
                }, seed.value.store_root, seed.value.store_id);
                registered.deinit();
            }
            var result: Result = .{
                .arena = std.heap.ArenaAllocator.init(allocator),
                .value = .{ .object = .{} },
            };
            defer result.deinit();
            var selected = seed.value;
            // The retained snapshot predates registration in the selected catalog.
            selected.cataloged = false;
            try result.setContext(selected);
            var vtable = io.vtable.*;
            fault.install(&vtable, kind);
            var injected = io;
            injected.vtable = &vtable;
            try std.testing.expectError(
                if (kind == .before_rename) error.HardwareFailure else error.InputOutput,
                registerContext(
                    &result,
                    injected,
                    &environment,
                    options,
                    selected,
                ),
            );
            try std.testing.expect(fault.reached);
            var actual = try host.catalog.read(allocator, io, options.context.catalog_root);
            defer actual.deinit();
            const visible = actual.value.stores.map.get(selected.store_id) != null;
            try std.testing.expectEqual(published or kind == .after_rename, visible);
            try std.testing.expectEqual(visible, result.value.object.get("cataloged").?.bool);
            try std.testing.expectEqualStrings(
                selected.store_id,
                result.value.object.get("store_id").?.string,
            );
            try std.testing.expectEqualStrings(
                selected.store_root,
                result.value.object.get("store_root").?.string,
            );
        }
    }
}
