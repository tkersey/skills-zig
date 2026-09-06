const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const definition = @import("definition.zig");
const materialization = @import("materialization.zig");
const protocol = @import("protocol.zig");
const projection = @import("projection.zig");
const storage = @import("storage.zig");
const validation = @import("validation.zig");

const payload_version: u16 = 34;
const locator_version: u16 = 1;
const cache_limits: definition_core.cache.Limits = .{};
const locator_max_payload_bytes: usize = 2 * 1024 * 1024;
const locator_limits: definition_core.cache.Limits = .{
    .max_payload_bytes = locator_max_payload_bytes,
    .max_entry_bytes = locator_max_payload_bytes +
        definition_core.cache.header_bytes,
};

pub const RouteKind = enum {
    definition,
    definition_check,
    validation,
    materialization,
    transact,
    project,
    doctor,
    migration,
};

pub const Route = struct {
    kind: RouteKind,
    name: ?[]const u8 = null,

    pub fn validate(self: Route) !void {
        switch (self.kind) {
            .transact, .project => {
                const name = self.name orelse return error.CacheRouteNameMissing;
                try definition_core.json.safeIdentifier(name, 128);
            },
            else => if (self.name != null) return error.CacheRouteNameUnexpected,
        }
    }
};

pub const Options = struct {
    cache_dir: ?[]const u8 = null,
    closure_limits: definition_core.closure.Limits = .{},
};

pub const PlanSet = struct {
    closure: definition_core.Closure,
    entry_path: []u8,
    definition_plan: definition.Plan,
    validation_plan: ?validation.Plan = null,
    materialization_plan: ?materialization.Plan = null,
    storage_plan: ?storage.Plan = null,
    protocol_plan: ?protocol.Plan = null,
    projection_plan: ?projection.Plan = null,
    stats: definition_core.result.CompileStats,
    cache_arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *PlanSet, allocator: std.mem.Allocator) void {
        if (self.cache_arena) |arena_value| {
            var arena = arena_value;
            self.deinitPlans(arena.allocator());
            arena.deinit();
        } else {
            self.deinitPlans(allocator);
        }
        self.* = undefined;
    }

    fn deinitPlans(self: *PlanSet, allocator: std.mem.Allocator) void {
        if (self.projection_plan) |*plan| plan.deinit(allocator);
        if (self.protocol_plan) |*plan| plan.deinit(allocator);
        if (self.storage_plan) |*plan| plan.deinit(allocator);
        if (self.materialization_plan) |*plan| plan.deinit(allocator);
        if (self.validation_plan) |*plan| plan.deinit(allocator);
        self.definition_plan.deinit(allocator);
        allocator.free(self.entry_path);
        self.closure.deinit(allocator);
    }
};

const SourceManifestFile = struct {
    path: []u8,
    source_digest: [32]u8,
    source_bytes: usize,

    fn deinit(self: *SourceManifestFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const Locator = struct {
    plan_key: [32]u8,
    closure_digest: [71]u8,
    files: []SourceManifestFile,

    fn deinit(self: *Locator, allocator: std.mem.Allocator) void {
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }
};

const VerifiedLocator = struct {
    value: Locator,
    source_bytes: usize,

    fn deinit(self: *VerifiedLocator, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    entry_path: []const u8,
    route: Route,
    runtime_version: []const u8,
    options: Options,
) !PlanSet {
    try route.validate();
    if (!std.fs.path.isAbsolute(admitted_root)) {
        return error.DefinitionRootNotAbsolute;
    }
    const start_ns = monotonicNanoseconds();
    if (options.cache_dir) |cache_dir| {
        if (!std.fs.path.isAbsolute(cache_dir)) {
            return error.CacheRootNotAbsolute;
        }
        const cached = tryLoadCache(
            allocator,
            admitted_root,
            entry_path,
            route,
            runtime_version,
            cache_dir,
            options.closure_limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        if (cached) |value| {
            var result = value;
            result.stats.compile_ns = elapsedNanoseconds(start_ns);
            return result;
        }
    }

    var compiled = try compileFromSource(
        allocator,
        admitted_root,
        entry_path,
        route,
        options.closure_limits,
    );
    compiled.stats.compile_ns = elapsedNanoseconds(start_ns);
    if (options.cache_dir) |cache_dir| {
        writeCache(
            allocator,
            cache_dir,
            admitted_root,
            route,
            runtime_version,
            &compiled,
        ) catch |err| {
            // The cache is optional; a write failure cannot invalidate the plan.
            _ = @errorName(err);
            compiled.stats.cache_write_failed = true;
        };
    }
    return compiled;
}

fn compileFromSource(
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    entry_path: []const u8,
    route: Route,
    closure_limits: definition_core.closure.Limits,
) !PlanSet {
    var result: PlanSet = result: {
        var closure = try definition_core.closure.load(
            allocator,
            admitted_root,
            entry_path,
            closure_limits,
        );
        errdefer closure.deinit(allocator);
        const owned_entry_path = try allocator.dupe(u8, entry_path);
        errdefer allocator.free(owned_entry_path);
        var definition_plan = try definition.compile(
            allocator,
            &closure,
            entry_path,
        );
        errdefer definition_plan.deinit(allocator);
        break :result .{
            .closure = closure,
            .entry_path = owned_entry_path,
            .definition_plan = definition_plan,
            .stats = .{
                .cache_hit = false,
                .closure_files = closure.files.len,
                .closure_bytes = closure.total_definition_bytes,
            },
        };
    };
    errdefer result.deinit(allocator);
    try compileRoutePlans(allocator, &result, route);
    try validatePlanSet(&result, route);
    return result;
}

fn compileRoutePlans(
    allocator: std.mem.Allocator,
    result: *PlanSet,
    route: Route,
) !void {
    switch (route.kind) {
        .definition => {},
        .definition_check => try compileDefinitionCheck(allocator, result),
        .validation => try compileValidation(allocator, result),
        .materialization => try compileMaterialization(allocator, result),
        .transact => try compileTransaction(allocator, result, route.name.?),
        .project => try compileProjection(allocator, result, route.name.?),
        .doctor => try compileDurablePlans(allocator, result),
        .migration => try compileDurablePlans(allocator, result),
    }
}

fn compileDefinitionCheck(
    allocator: std.mem.Allocator,
    result: *PlanSet,
) !void {
    result.validation_plan = try validation.compile(
        allocator,
        &result.definition_plan,
    );
    try compileDurablePlans(allocator, result);
    result.projection_plan = try projection.compile(
        allocator,
        &result.definition_plan,
        &result.storage_plan.?,
        if (result.protocol_plan) |*plan| plan else null,
    );
}

fn compileValidation(
    allocator: std.mem.Allocator,
    result: *PlanSet,
) !void {
    result.validation_plan = try validation.compile(
        allocator,
        &result.definition_plan,
    );
    result.materialization_plan = try materialization.compileForValidation(
        allocator,
        &result.definition_plan,
    );
}

fn compileMaterialization(
    allocator: std.mem.Allocator,
    result: *PlanSet,
) !void {
    result.validation_plan = try validation.compile(
        allocator,
        &result.definition_plan,
    );
    result.materialization_plan = try materialization.compile(
        allocator,
        &result.definition_plan,
    );
}

fn compileTransaction(
    allocator: std.mem.Allocator,
    result: *PlanSet,
    operation: []const u8,
) !void {
    result.validation_plan = try validation.compile(
        allocator,
        &result.definition_plan,
    );
    try compileDurablePlans(allocator, result);
    if (result.storage_plan.?.findOperation(operation) == null) {
        return error.UnknownOperation;
    }
}

fn compileProjection(
    allocator: std.mem.Allocator,
    result: *PlanSet,
    projection_name: []const u8,
) !void {
    try compileDurablePlans(allocator, result);
    result.projection_plan = try projection.compile(
        allocator,
        &result.definition_plan,
        &result.storage_plan.?,
        if (result.protocol_plan) |*plan| plan else null,
    );
    if (result.projection_plan.?.find(projection_name) == null) {
        return error.UnknownProjection;
    }
}

fn compileDurablePlans(
    allocator: std.mem.Allocator,
    result: *PlanSet,
) !void {
    result.storage_plan = try storage.compile(
        allocator,
        &result.definition_plan,
    );
    result.protocol_plan = try protocol.compile(
        allocator,
        &result.definition_plan,
        &result.storage_plan.?,
    );
}

fn tryLoadCache(
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    entry_path: []const u8,
    route: Route,
    runtime_version: []const u8,
    cache_dir: []const u8,
    closure_limits: definition_core.closure.Limits,
) !?PlanSet {
    const locator_key = locatorKey(
        admitted_root,
        entry_path,
        route,
        runtime_version,
    );
    var locator = (try tryLoadLocator(
        allocator,
        admitted_root,
        cache_dir,
        locator_key,
        closure_limits,
    )) orelse return null;
    defer locator.deinit(allocator);
    return try loadCachedPlan(
        allocator,
        entry_path,
        route,
        runtime_version,
        cache_dir,
        &locator,
        closure_limits,
    );
}

fn tryLoadLocator(
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    cache_dir: []const u8,
    locator_key: [32]u8,
    closure_limits: definition_core.closure.Limits,
) !?VerifiedLocator {
    const locator_path = try cachePathAlloc(
        allocator,
        cache_dir,
        "locators",
        locator_key,
    );
    defer allocator.free(locator_path);
    const locator_entry = durable_store.readPrivateRegularFileNoSymlink(
        allocator,
        locator_path,
        locator_limits.max_entry_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(locator_entry);
    const locator_payload = try definition_core.cache.decode(
        locator_key,
        locator_entry,
        locator_limits,
    );
    var locator = try decodeLocator(allocator, locator_payload);
    errdefer locator.deinit(allocator);
    const verified_source_bytes =
        try definition_core.closure.verifySourceManifest(
            allocator,
            admitted_root,
            locator.files,
            closure_limits,
        );
    return .{ .value = locator, .source_bytes = verified_source_bytes };
}

fn loadCachedPlan(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    route: Route,
    runtime_version: []const u8,
    cache_dir: []const u8,
    locator: *const VerifiedLocator,
    closure_limits: definition_core.closure.Limits,
) !PlanSet {
    const plan_path = try cachePathAlloc(
        allocator,
        cache_dir,
        "plans",
        locator.value.plan_key,
    );
    defer allocator.free(plan_path);
    const plan_entry = try durable_store.readPrivateRegularFileNoSymlink(
        allocator,
        plan_path,
        cache_limits.max_entry_bytes,
    );
    defer allocator.free(plan_entry);
    const plan_payload = try definition_core.cache.decode(
        locator.value.plan_key,
        plan_entry,
        cache_limits,
    );
    var result = try decodePlanSet(
        allocator,
        plan_payload,
        route,
        entry_path,
        closure_limits,
    );
    errdefer result.deinit(allocator);
    if (!std.mem.eql(
        u8,
        &result.closure.digest,
        &locator.value.closure_digest,
    )) return error.CacheClosureDigestMismatch;
    if (result.closure.files.len != locator.value.files.len or
        result.closure.total_definition_bytes != locator.source_bytes)
    {
        return error.CacheClosureManifestMismatch;
    }
    const expected_plan_key = planKey(
        runtime_version,
        route,
        &result.definition_plan,
    );
    if (!std.mem.eql(u8, &expected_plan_key, &locator.value.plan_key)) {
        return error.CachePlanKeyMismatch;
    }
    result.stats.cache_hit = true;
    return result;
}

fn writeCache(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    admitted_root: []const u8,
    route: Route,
    runtime_version: []const u8,
    plan_set: *const PlanSet,
) !void {
    try ensureCacheDirectories(allocator, cache_dir);
    const plan_key = planKey(
        runtime_version,
        route,
        &plan_set.definition_plan,
    );
    try writePlanCache(
        allocator,
        cache_dir,
        route,
        plan_set,
        plan_key,
    );
    try writeLocatorCache(
        allocator,
        cache_dir,
        admitted_root,
        route,
        runtime_version,
        plan_set,
        plan_key,
    );
}

fn ensureCacheDirectories(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
) !void {
    const plans_dir = try std.fs.path.join(
        allocator,
        &.{ cache_dir, "plans" },
    );
    defer allocator.free(plans_dir);
    const locators_dir = try std.fs.path.join(
        allocator,
        &.{ cache_dir, "locators" },
    );
    defer allocator.free(locators_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(cache_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(plans_dir);
    try durable_store.ensurePrivateDirectoryPathNoSymlinks(locators_dir);
}

fn writePlanCache(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    route: Route,
    plan_set: *const PlanSet,
    plan_key: [32]u8,
) !void {
    var plan_encoder = definition_core.cache.Encoder.init(
        allocator,
        cache_limits.max_payload_bytes,
    );
    defer plan_encoder.deinit();
    try encodePlanSet(plan_set, route, &plan_encoder);
    const plan_payload = try plan_encoder.toOwnedSlice();
    defer allocator.free(plan_payload);
    const plan_entry = try definition_core.cache.encodeAlloc(
        allocator,
        plan_key,
        plan_payload,
        cache_limits,
    );
    defer allocator.free(plan_entry);
    const plan_path = try cachePathAlloc(
        allocator,
        cache_dir,
        "plans",
        plan_key,
    );
    defer allocator.free(plan_path);
    try durable_store.writeTextAtomicPrivate(allocator, plan_path, plan_entry);
}

fn writeLocatorCache(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    admitted_root: []const u8,
    route: Route,
    runtime_version: []const u8,
    plan_set: *const PlanSet,
    plan_key: [32]u8,
) !void {
    const locator_key = locatorKey(
        admitted_root,
        plan_set.entry_path,
        route,
        runtime_version,
    );
    var locator_encoder = definition_core.cache.Encoder.init(
        allocator,
        locator_limits.max_payload_bytes,
    );
    defer locator_encoder.deinit();
    try encodeLocator(plan_set, plan_key, &locator_encoder);
    const locator_payload = try locator_encoder.toOwnedSlice();
    defer allocator.free(locator_payload);
    const locator_entry = try definition_core.cache.encodeAlloc(
        allocator,
        locator_key,
        locator_payload,
        locator_limits,
    );
    defer allocator.free(locator_entry);
    const locator_path = try cachePathAlloc(
        allocator,
        cache_dir,
        "locators",
        locator_key,
    );
    defer allocator.free(locator_path);
    try durable_store.writeTextAtomicPrivate(
        allocator,
        locator_path,
        locator_entry,
    );
}

fn encodePlanSet(
    plan_set: *const PlanSet,
    route: Route,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(payload_version);
    try encodeRoute(route, encoder);
    try encoder.writeBytes(plan_set.entry_path);
    try encodeClosure(
        &plan_set.closure,
        routeNeedsSources(route),
        encoder,
    );
    try definition.encodeCacheWithDetail(
        &plan_set.definition_plan,
        definitionCacheDetail(route),
        encoder,
    );
    try encoder.writeBool(plan_set.validation_plan != null);
    if (plan_set.validation_plan) |*plan| {
        try validation.encodeCache(plan, encoder);
    }
    try encoder.writeBool(plan_set.materialization_plan != null);
    if (plan_set.materialization_plan) |*plan| {
        try materialization.encodeCache(plan, encoder);
    }
    try encoder.writeBool(plan_set.storage_plan != null);
    if (plan_set.storage_plan) |*plan| {
        try storage.encodeCache(plan, encoder);
    }
    try encoder.writeBool(plan_set.protocol_plan != null);
    if (plan_set.protocol_plan) |*plan| {
        try protocol.encodeCache(plan, encoder);
    }
    try encoder.writeBool(plan_set.projection_plan != null);
    if (plan_set.projection_plan) |*plan| {
        try projection.encodeCache(plan, encoder);
    }
}

fn decodePlanSet(
    allocator: std.mem.Allocator,
    payload: []const u8,
    expected_route: Route,
    expected_entry_path: []const u8,
    closure_limits: definition_core.closure.Limits,
) !PlanSet {
    var cache_arena = std.heap.ArenaAllocator.init(allocator);
    var cache_arena_owned = true;
    errdefer if (cache_arena_owned) cache_arena.deinit();
    const cache_allocator = cache_arena.allocator();
    var decoder = definition_core.cache.Decoder.init(payload);
    if (try decoder.readU16() != payload_version) {
        return error.LedgerCompiledPlanCacheVersionMismatch;
    }
    const route = try decodeRoute(cache_allocator, &decoder);
    defer if (route.name) |name| cache_allocator.free(@constCast(name));
    if (!routesEqual(route, expected_route)) return error.CacheRouteMismatch;
    var result = try decodePlanCore(
        cache_allocator,
        &decoder,
        route,
        expected_entry_path,
        closure_limits,
    );
    errdefer result.deinit(cache_allocator);
    try decodeOptionalPlans(cache_allocator, &decoder, &result);
    try decoder.finish();
    try validatePlanSet(&result, route);
    result.cache_arena = cache_arena;
    cache_arena_owned = false;
    return result;
}

fn decodePlanCore(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    route: Route,
    expected_entry_path: []const u8,
    closure_limits: definition_core.closure.Limits,
) !PlanSet {
    const entry_path = try decoder.readBytesAlloc(
        allocator,
        4 * 1024 * 1024,
    );
    errdefer allocator.free(entry_path);
    if (!std.mem.eql(u8, entry_path, expected_entry_path)) {
        return error.CacheEntryPathMismatch;
    }
    var closure = try decodeClosure(
        allocator,
        decoder,
        entry_path,
        closure_limits,
        routeNeedsSources(route),
    );
    errdefer closure.deinit(allocator);
    var definition_plan = try definition.decodeCacheWithDetail(
        allocator,
        definitionCacheDetail(route),
        decoder,
    );
    errdefer definition_plan.deinit(allocator);
    if (!std.mem.eql(
        u8,
        &definition_plan.closure_digest,
        &closure.digest,
    )) return error.CacheClosureDigestMismatch;
    return .{
        .closure = closure,
        .entry_path = entry_path,
        .definition_plan = definition_plan,
        .stats = .{
            .cache_hit = true,
            .closure_files = closure.files.len,
            .closure_bytes = closure.total_definition_bytes,
        },
    };
}

fn decodeOptionalPlans(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    result: *PlanSet,
) !void {
    if (try decoder.readBool()) {
        result.validation_plan = try validation.decodeCache(
            allocator,
            decoder,
        );
    }
    if (try decoder.readBool()) {
        result.materialization_plan = try materialization.decodeCache(
            allocator,
            decoder,
        );
    }
    if (try decoder.readBool()) {
        result.storage_plan = try storage.decodeCache(
            allocator,
            decoder,
        );
    }
    if (try decoder.readBool()) {
        result.protocol_plan = try protocol.decodeCache(
            allocator,
            decoder,
        );
    }
    if (try decoder.readBool()) {
        result.projection_plan = try projection.decodeCache(
            allocator,
            decoder,
        );
    }
}

fn encodeClosure(
    closure: *const definition_core.Closure,
    include_sources: bool,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeFixed(&closure.digest);
    try encoder.writeUsize(closure.total_definition_bytes);
    try encoder.writeCount(closure.files.len);
    if (!include_sources) return;
    for (closure.files) |file| {
        try encoder.writeBytes(file.path);
        try encoder.writeBytes(file.canonical_json);
        try encoder.writeFixed(&file.source_digest);
        try encoder.writeUsize(file.source_bytes);
    }
}

fn decodeClosure(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    entry_path: []const u8,
    limits: definition_core.closure.Limits,
    include_sources: bool,
) !definition_core.Closure {
    const header = try decodeClosureHeader(decoder, limits);
    if (!include_sources) {
        const files = try emptyClosureFiles(allocator, header.file_count);
        return .{
            .files = files,
            .digest = header.digest,
            .total_definition_bytes = header.total_definition_bytes,
        };
    }
    var closure = definition_core.Closure{
        .files = try decodeClosureFiles(
            allocator,
            decoder,
            limits,
            header.file_count,
        ),
        .digest = header.digest,
        .total_definition_bytes = header.total_definition_bytes,
    };
    errdefer closure.deinit(allocator);
    try definition_core.closure.validateCached(
        allocator,
        &closure,
        entry_path,
        limits,
    );
    return closure;
}

const ClosureHeader = struct {
    digest: [71]u8,
    total_definition_bytes: usize,
    file_count: usize,
};

fn decodeClosureHeader(
    decoder: *definition_core.cache.Decoder,
    limits: definition_core.closure.Limits,
) !ClosureHeader {
    var digest: [71]u8 = undefined;
    @memcpy(&digest, try decoder.readFixed(digest.len));
    try definition_core.json.digest(&digest);
    const total_definition_bytes = try decoder.readUsize();
    const count = try decoder.readCount(limits.max_files);
    if (count == 0 or total_definition_bytes == 0 or
        total_definition_bytes > limits.max_total_bytes)
    {
        return error.CacheClosureManifestInvalid;
    }
    return .{
        .digest = digest,
        .total_definition_bytes = total_definition_bytes,
        .file_count = count,
    };
}

fn emptyClosureFiles(
    allocator: std.mem.Allocator,
    count: usize,
) ![]definition_core.ClosureFile {
    const files = try allocator.alloc(definition_core.ClosureFile, count);
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |file| {
            allocator.free(file.path);
            allocator.free(file.canonical_json);
        }
        allocator.free(files);
    }
    for (files) |*file| {
        const path = try allocator.alloc(u8, 0);
        errdefer allocator.free(path);
        const canonical_json = try allocator.alloc(u8, 0);
        errdefer allocator.free(canonical_json);
        file.* = .{
            .path = path,
            .canonical_json = canonical_json,
            .source_digest = [_]u8{0} ** 32,
            .source_bytes = 0,
        };
        initialized += 1;
    }
    return files;
}

fn decodeClosureFiles(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
    limits: definition_core.closure.Limits,
    count: usize,
) ![]definition_core.ClosureFile {
    const files = try allocator.alloc(definition_core.ClosureFile, count);
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |file| {
            allocator.free(file.path);
            allocator.free(file.canonical_json);
        }
        allocator.free(files);
    }
    for (files) |*file| {
        const path = try decoder.readBytesAlloc(allocator, limits.max_file_bytes);
        errdefer allocator.free(path);
        const canonical_json = try decoder.readBytesAlloc(
            allocator,
            limits.max_file_bytes,
        );
        errdefer allocator.free(canonical_json);
        var source_digest: [32]u8 = undefined;
        @memcpy(&source_digest, try decoder.readFixed(source_digest.len));
        file.* = .{
            .path = path,
            .canonical_json = canonical_json,
            .source_digest = source_digest,
            .source_bytes = try decoder.readUsize(),
        };
        initialized += 1;
    }
    return files;
}

fn encodeLocator(
    plan_set: *const PlanSet,
    plan_key: [32]u8,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(locator_version);
    try encoder.writeFixed(&plan_key);
    try encoder.writeFixed(&plan_set.closure.digest);
    try encoder.writeCount(plan_set.closure.files.len);
    for (plan_set.closure.files) |file| {
        try encoder.writeBytes(file.path);
        try encoder.writeFixed(&file.source_digest);
        try encoder.writeUsize(file.source_bytes);
    }
}

fn decodeLocator(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !Locator {
    var decoder = definition_core.cache.Decoder.init(payload);
    if (try decoder.readU16() != locator_version) {
        return error.LedgerCacheLocatorVersionMismatch;
    }
    var plan_key: [32]u8 = undefined;
    @memcpy(&plan_key, try decoder.readFixed(plan_key.len));
    var closure_digest: [71]u8 = undefined;
    @memcpy(
        &closure_digest,
        try decoder.readFixed(closure_digest.len),
    );
    try definition_core.json.digest(&closure_digest);
    const count = try decoder.readCount(128);
    const files = try allocator.alloc(SourceManifestFile, count);
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |*file| file.deinit(allocator);
        allocator.free(files);
    }
    for (files) |*file| {
        const path = try decoder.readBytesAlloc(allocator, 4 * 1024 * 1024);
        errdefer allocator.free(path);
        var source_digest: [32]u8 = undefined;
        @memcpy(
            &source_digest,
            try decoder.readFixed(source_digest.len),
        );
        file.* = .{
            .path = path,
            .source_digest = source_digest,
            .source_bytes = try decoder.readUsize(),
        };
        initialized += 1;
    }
    try decoder.finish();
    return .{
        .plan_key = plan_key,
        .closure_digest = closure_digest,
        .files = files,
    };
}

fn validatePlanSet(plan_set: *const PlanSet, route: Route) !void {
    try route.validate();
    if (!std.mem.eql(
        u8,
        &plan_set.definition_plan.closure_digest,
        &plan_set.closure.digest,
    )) return error.CacheClosureDigestMismatch;
    if (routeNeedsSources(route)) {
        for (plan_set.closure.files) |file| {
            if (file.path.len == 0 or file.canonical_json.len == 0) {
                return error.CacheDefinitionSourceMissing;
            }
        }
    }
    try validatePlanShape(plan_set, route);
    try validateNestedPlans(plan_set);
    try validateRouteTarget(plan_set, route);
}

fn validatePlanShape(plan_set: *const PlanSet, route: Route) !void {
    const required_validation = route.kind == .definition_check or
        route.kind == .validation or
        route.kind == .materialization or
        route.kind == .transact;
    const required_materialization = route.kind == .validation or
        route.kind == .materialization;
    const required_storage = route.kind == .definition_check or
        route.kind == .transact or
        route.kind == .project or
        route.kind == .doctor or
        route.kind == .migration;
    const required_projection = route.kind == .definition_check or
        route.kind == .project;
    const required_protocol = required_storage and
        protocol.isConfigured(&plan_set.definition_plan);
    if ((plan_set.validation_plan != null) != required_validation or
        (plan_set.materialization_plan != null) !=
            required_materialization or
        (plan_set.storage_plan != null) != required_storage or
        (plan_set.protocol_plan != null) != required_protocol or
        (plan_set.projection_plan != null) != required_projection)
    {
        return error.CachePlanSetShapeMismatch;
    }
}

fn validateNestedPlans(plan_set: *const PlanSet) !void {
    if (plan_set.validation_plan) |*plan| {
        try validation.validateCachePlan(plan, &plan_set.definition_plan);
    }
    if (plan_set.materialization_plan) |*plan| {
        try materialization.validateCachePlan(
            plan,
            &plan_set.definition_plan,
        );
    }
    if (plan_set.storage_plan) |*plan| {
        try storage.validateCachePlan(plan, &plan_set.definition_plan);
    }
    if (plan_set.protocol_plan) |*plan| {
        try protocol.validateCachePlan(
            plan,
            &plan_set.definition_plan,
            &plan_set.storage_plan.?,
        );
    }
    if (plan_set.storage_plan) |*storage_plan| {
        try protocol.validateSegmentedSupport(
            &plan_set.definition_plan,
            storage_plan,
            if (plan_set.protocol_plan) |*plan| plan else null,
        );
    }
    if (plan_set.projection_plan) |*plan| {
        try projection.validateCachePlan(
            plan,
            &plan_set.definition_plan,
            &plan_set.storage_plan.?,
            if (plan_set.protocol_plan) |*protocol_plan|
                protocol_plan
            else
                null,
        );
    }
}

fn validateRouteTarget(plan_set: *const PlanSet, route: Route) !void {
    switch (route.kind) {
        .transact => if (plan_set.storage_plan.?.findOperation(
            route.name.?,
        ) == null) return error.UnknownOperation,
        .project => if (plan_set.projection_plan.?.find(
            route.name.?,
        ) == null) return error.UnknownProjection,
        else => {},
    }
}

fn encodeRoute(
    route: Route,
    encoder: *definition_core.cache.Encoder,
) !void {
    try route.validate();
    try encoder.writeEnum(route.kind);
    try encoder.writeOptionalBytes(route.name);
}

fn decodeRoute(
    allocator: std.mem.Allocator,
    decoder: *definition_core.cache.Decoder,
) !Route {
    const route: Route = .{
        .kind = try decoder.readEnum(RouteKind),
        .name = try decoder.readOptionalBytesAlloc(allocator, 128),
    };
    errdefer if (route.name) |name| allocator.free(@constCast(name));
    try route.validate();
    return route;
}

fn routesEqual(left: Route, right: Route) bool {
    if (left.kind != right.kind or
        (left.name == null) != (right.name == null))
    {
        return false;
    }
    if (left.name) |name| return std.mem.eql(u8, name, right.name.?);
    return true;
}

fn definitionCacheDetail(route: Route) definition.CacheDetail {
    return switch (route.kind) {
        .validation, .materialization => .runtime_metadata,
        else => .full,
    };
}

fn routeNeedsSources(route: Route) bool {
    return route.kind == .transact or route.kind == .migration;
}

fn planKey(
    runtime_version: []const u8,
    route: Route,
    definition_plan: *const definition.Plan,
) [32]u8 {
    return definition_core.cache.key(&.{
        "ledger-compiled-plan/v1",
        definition.abi,
        runtime_version,
        definition_plan.closure_digest[0..],
        @tagName(route.kind),
        route.name orelse "",
        definition_plan.parameter_declarations.shape_digest[0..],
    });
}

fn locatorKey(
    admitted_root: []const u8,
    entry_path: []const u8,
    route: Route,
    runtime_version: []const u8,
) [32]u8 {
    return definition_core.cache.key(&.{
        "ledger-cache-locator/v1",
        definition.abi,
        runtime_version,
        admitted_root,
        entry_path,
        @tagName(route.kind),
        route.name orelse "",
    });
}

fn cachePathAlloc(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    namespace: []const u8,
    cache_key: [32]u8,
) ![]u8 {
    const hex = definition_core.cache.keyHex(cache_key);
    const filename = try std.fmt.allocPrint(allocator, "{s}.bin", .{&hex});
    defer allocator.free(filename);
    return std.fs.path.join(
        allocator,
        &.{ cache_dir, namespace, filename },
    );
}

fn monotonicNanoseconds() u64 {
    const now = std.Io.Clock.awake.now(defaultIo()).nanoseconds;
    if (now <= 0) return 0;
    return std.math.cast(u64, now) orelse std.math.maxInt(u64);
}

fn elapsedNanoseconds(start: u64) u64 {
    const now = monotonicNanoseconds();
    return if (now > start) now - start else 0;
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn expectColdAndWarmCache(
    source_root: []const u8,
    cache_root: []const u8,
    route: Route,
) !void {
    var cold = try load(
        std.testing.allocator,
        source_root,
        "artifact.json",
        route,
        "1.0.0-test",
        .{ .cache_dir = cache_root },
    );
    defer cold.deinit(std.testing.allocator);
    try std.testing.expect(!cold.stats.cache_hit);
    try std.testing.expect(cold.validation_plan != null);
    try std.testing.expect(cold.closure.files[0].canonical_json.len > 0);
    try std.testing.expect(cold.definition_plan.rules.len > 0);
    var warm = try load(
        std.testing.allocator,
        source_root,
        "artifact.json",
        route,
        "1.0.0-test",
        .{ .cache_dir = cache_root },
    );
    defer warm.deinit(std.testing.allocator);
    try std.testing.expect(warm.stats.cache_hit);
    try std.testing.expectEqual(
        @as(usize, 0),
        warm.closure.files[0].canonical_json.len,
    );
    try std.testing.expectEqual(@as(usize, 0), warm.definition_plan.rules.len);
    try std.testing.expectEqualStrings(
        cold.definition_plan.closure_digest[0..],
        warm.definition_plan.closure_digest[0..],
    );
}

fn expectChangedAndCorruptCacheRebuild(
    source_root: []const u8,
    cache_root: []const u8,
    route: Route,
) !void {
    var changed = try load(
        std.testing.allocator,
        source_root,
        "artifact.json",
        route,
        "1.0.0-test",
        .{ .cache_dir = cache_root },
    );
    defer changed.deinit(std.testing.allocator);
    try std.testing.expect(!changed.stats.cache_hit);
    const key = planKey("1.0.0-test", route, &changed.definition_plan);
    const path = try cachePathAlloc(
        std.testing.allocator,
        cache_root,
        "plans",
        key,
    );
    defer std.testing.allocator.free(path);
    try durable_store.writeTextAtomic(std.testing.allocator, path, "corrupt");
    var rebuilt = try load(
        std.testing.allocator,
        source_root,
        "artifact.json",
        route,
        "1.0.0-test",
        .{ .cache_dir = cache_root },
    );
    defer rebuilt.deinit(std.testing.allocator);
    try std.testing.expect(!rebuilt.stats.cache_hit);
}

test "compiled plan cache rebuilds misses and skips definition parsing on hits" {
    var source_tmp = std.testing.tmpDir(.{});
    defer source_tmp.cleanup();
    try source_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = @embedFile("fixtures/record-definition.json"),
    });
    const source_root = try source_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(source_root);
    var cache_tmp = std.testing.tmpDir(.{});
    defer cache_tmp.cleanup();
    const cache_root = try cache_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(cache_root);
    const route: Route = .{ .kind = .validation };
    try expectColdAndWarmCache(source_root, cache_root, route);
    const changed_definition = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{ " ", @embedFile("fixtures/record-definition.json") },
    );
    defer std.testing.allocator.free(changed_definition);
    try source_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = changed_definition,
    });
    try expectChangedAndCorruptCacheRebuild(source_root, cache_root, route);

    try cache_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "not-a-directory",
        .data = "cache writes must remain optional",
    });
    const blocked_cache = try cache_tmp.dir.realPathFileAlloc(
        std.testing.io,
        "not-a-directory",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(blocked_cache);
    var write_failure = try load(
        std.testing.allocator,
        source_root,
        "artifact.json",
        route,
        "1.0.1-test",
        .{ .cache_dir = blocked_cache },
    );
    defer write_failure.deinit(std.testing.allocator);
    try std.testing.expect(write_failure.stats.cache_write_failed);
}

test "transaction cache retains canonical definition archive sources" {
    const source_root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(source_root);
    var cache_tmp = std.testing.tmpDir(.{});
    defer cache_tmp.cleanup();
    const cache_root = try cache_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(cache_root);
    const entry = "apps/ledger/src/v1/fixtures/event-definition.json";
    const route: Route = .{ .kind = .transact, .name = "append" };

    var cold = try load(
        std.testing.allocator,
        source_root,
        entry,
        route,
        "1.0.0-test",
        .{ .cache_dir = cache_root },
    );
    defer cold.deinit(std.testing.allocator);
    var warm = try load(
        std.testing.allocator,
        source_root,
        entry,
        route,
        "1.0.0-test",
        .{ .cache_dir = cache_root },
    );
    defer warm.deinit(std.testing.allocator);

    try std.testing.expect(warm.stats.cache_hit);
    try std.testing.expectEqualStrings(
        cold.closure.files[0].canonical_json,
        warm.closure.files[0].canonical_json,
    );
}

test "migration cache retains canonical definition archive sources" {
    const source_root = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(source_root);
    var cache_tmp = std.testing.tmpDir(.{});
    defer cache_tmp.cleanup();
    const cache_root = try cache_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(cache_root);
    const entry = "apps/ledger/src/v1/fixtures/event-definition.json";
    const route: Route = .{ .kind = .migration };
    var cold = try load(
        std.testing.allocator,
        source_root,
        entry,
        route,
        "1.0.0-test",
        .{ .cache_dir = cache_root },
    );
    defer cold.deinit(std.testing.allocator);
    var warm = try load(
        std.testing.allocator,
        source_root,
        entry,
        route,
        "1.0.0-test",
        .{ .cache_dir = cache_root },
    );
    defer warm.deinit(std.testing.allocator);
    try std.testing.expect(warm.stats.cache_hit);
    try std.testing.expectEqualStrings(
        cold.closure.files[0].canonical_json,
        warm.closure.files[0].canonical_json,
    );
}

fn decodePlanSetForAllocationFailure(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !void {
    var decoded = decodePlanSet(
        allocator,
        payload,
        .{ .kind = .definition_check },
        "artifact.json",
        .{},
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer decoded.deinit(allocator);
}

fn compilePlanSetForAllocationFailure(
    allocator: std.mem.Allocator,
    source_root: []const u8,
) !void {
    var compiled = compileFromSource(
        allocator,
        source_root,
        "artifact.json",
        .{ .kind = .definition_check },
        .{},
    ) catch |err| switch (err) {
        error.WriteFailed,
        error.InvalidDefinitionJson,
        => return error.OutOfMemory,
        else => return err,
    };
    defer compiled.deinit(allocator);
}

test "compiled plan cache releases every allocation on compile and decode failure" {
    var source_tmp = std.testing.tmpDir(.{});
    defer source_tmp.cleanup();
    try source_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data = @embedFile("fixtures/chained-event-definition.json"),
    });
    const source_root = try source_tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(source_root);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        compilePlanSetForAllocationFailure,
        .{source_root},
    );
    var plan_set = try compileFromSource(
        std.testing.allocator,
        source_root,
        "artifact.json",
        .{ .kind = .definition_check },
        .{},
    );
    defer plan_set.deinit(std.testing.allocator);
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        cache_limits.max_payload_bytes,
    );
    defer encoder.deinit();
    try encodePlanSet(
        &plan_set,
        .{ .kind = .definition_check },
        &encoder,
    );
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodePlanSetForAllocationFailure,
        .{payload},
    );
}
