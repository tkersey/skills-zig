const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const definition = @import("definition.zig");
const materialization = @import("materialization.zig");
const protocol = @import("protocol.zig");
const projection = @import("projection.zig");
const storage = @import("storage.zig");
const validation = @import("validation.zig");

const payload_version: u16 = 3;
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

    pub fn deinit(self: *PlanSet, allocator: std.mem.Allocator) void {
        if (self.projection_plan) |*plan| plan.deinit(allocator);
        if (self.protocol_plan) |*plan| plan.deinit(allocator);
        if (self.storage_plan) |*plan| plan.deinit(allocator);
        if (self.materialization_plan) |*plan| plan.deinit(allocator);
        if (self.validation_plan) |*plan| plan.deinit(allocator);
        self.definition_plan.deinit(allocator);
        allocator.free(self.entry_path);
        self.closure.deinit(allocator);
        self.* = undefined;
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
        ) catch {};
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
    switch (route.kind) {
        .definition => {},
        .definition_check => {
            result.validation_plan = try validation.compile(
                allocator,
                &result.definition_plan,
            );
            result.storage_plan = try storage.compile(
                allocator,
                &result.definition_plan,
            );
            result.protocol_plan = try protocol.compile(
                allocator,
                &result.definition_plan,
                &result.storage_plan.?,
            );
            result.projection_plan = try projection.compile(
                allocator,
                &result.definition_plan,
                &result.storage_plan.?,
                if (result.protocol_plan) |*plan| plan else null,
            );
        },
        .validation => {
            result.validation_plan = try validation.compile(
                allocator,
                &result.definition_plan,
            );
        },
        .materialization => {
            result.validation_plan = try validation.compile(
                allocator,
                &result.definition_plan,
            );
            result.materialization_plan = try materialization.compile(
                allocator,
                &result.definition_plan,
            );
        },
        .transact => {
            result.validation_plan = try validation.compile(
                allocator,
                &result.definition_plan,
            );
            result.storage_plan = try storage.compile(
                allocator,
                &result.definition_plan,
            );
            result.protocol_plan = try protocol.compile(
                allocator,
                &result.definition_plan,
                &result.storage_plan.?,
            );
            if (result.storage_plan.?.findOperation(route.name.?) == null) {
                return error.UnknownOperation;
            }
        },
        .project => {
            result.storage_plan = try storage.compile(
                allocator,
                &result.definition_plan,
            );
            result.protocol_plan = try protocol.compile(
                allocator,
                &result.definition_plan,
                &result.storage_plan.?,
            );
            result.projection_plan = try projection.compile(
                allocator,
                &result.definition_plan,
                &result.storage_plan.?,
                if (result.protocol_plan) |*plan| plan else null,
            );
            if (result.projection_plan.?.find(route.name.?) == null) {
                return error.UnknownProjection;
            }
        },
        .doctor => {
            result.storage_plan = try storage.compile(
                allocator,
                &result.definition_plan,
            );
            result.protocol_plan = try protocol.compile(
                allocator,
                &result.definition_plan,
                &result.storage_plan.?,
            );
        },
    }
    try validatePlanSet(&result, route);
    return result;
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
    const locator_path = try cachePathAlloc(
        allocator,
        cache_dir,
        "locators",
        locator_key,
    );
    defer allocator.free(locator_path);
    const locator_entry = durable_store.readRegularFileNoSymlink(
        allocator,
        locator_path,
        locator_limits.max_entry_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(locator_entry);
    const locator_payload = try definition_core.cache.decodeAlloc(
        allocator,
        locator_key,
        locator_entry,
        locator_limits,
    );
    defer allocator.free(locator_payload);
    var locator = try decodeLocator(allocator, locator_payload);
    defer locator.deinit(allocator);
    _ = try definition_core.closure.verifySourceManifest(
        allocator,
        admitted_root,
        locator.files,
        closure_limits,
    );

    const plan_path = try cachePathAlloc(
        allocator,
        cache_dir,
        "plans",
        locator.plan_key,
    );
    defer allocator.free(plan_path);
    const plan_entry = try durable_store.readRegularFileNoSymlink(
        allocator,
        plan_path,
        cache_limits.max_entry_bytes,
    );
    defer allocator.free(plan_entry);
    const plan_payload = try definition_core.cache.decodeAlloc(
        allocator,
        locator.plan_key,
        plan_entry,
        cache_limits,
    );
    defer allocator.free(plan_payload);
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
        &locator.closure_digest,
    )) return error.CacheClosureDigestMismatch;
    const expected_plan_key = planKey(
        runtime_version,
        route,
        &result.definition_plan,
    );
    if (!std.mem.eql(u8, &expected_plan_key, &locator.plan_key)) {
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
    try durable_store.ensureDirectoryPathNoSymlinks(cache_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(plans_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(locators_dir);

    const plan_key = planKey(
        runtime_version,
        route,
        &plan_set.definition_plan,
    );
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
    try durable_store.writeTextAtomic(allocator, plan_path, plan_entry);

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
    try durable_store.writeTextAtomic(
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
    try encodeClosure(&plan_set.closure, encoder);
    try definition.encodeCache(&plan_set.definition_plan, encoder);
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
    var decoder = definition_core.cache.Decoder.init(payload);
    if (try decoder.readU16() != payload_version) {
        return error.LedgerCompiledPlanCacheVersionMismatch;
    }
    const route = try decodeRoute(allocator, &decoder);
    defer if (route.name) |name| allocator.free(@constCast(name));
    if (!routesEqual(route, expected_route)) return error.CacheRouteMismatch;
    var result: PlanSet = result: {
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
            &decoder,
            entry_path,
            closure_limits,
        );
        errdefer closure.deinit(allocator);
        var definition_plan = try definition.decodeCache(
            allocator,
            &decoder,
        );
        errdefer definition_plan.deinit(allocator);
        if (!std.mem.eql(
            u8,
            &definition_plan.closure_digest,
            &closure.digest,
        )) return error.CacheClosureDigestMismatch;
        break :result .{
            .closure = closure,
            .entry_path = entry_path,
            .definition_plan = definition_plan,
            .stats = .{
                .cache_hit = true,
                .closure_files = closure.files.len,
                .closure_bytes = closure.total_definition_bytes,
            },
        };
    };
    errdefer result.deinit(allocator);
    if (try decoder.readBool()) {
        result.validation_plan = try validation.decodeCache(
            allocator,
            &decoder,
        );
    }
    if (try decoder.readBool()) {
        result.materialization_plan = try materialization.decodeCache(
            allocator,
            &decoder,
        );
    }
    if (try decoder.readBool()) {
        result.storage_plan = try storage.decodeCache(allocator, &decoder);
    }
    if (try decoder.readBool()) {
        result.protocol_plan = try protocol.decodeCache(
            allocator,
            &decoder,
        );
    }
    if (try decoder.readBool()) {
        result.projection_plan = try projection.decodeCache(
            allocator,
            &decoder,
        );
    }
    try decoder.finish();
    try validatePlanSet(&result, route);
    return result;
}

fn encodeClosure(
    closure: *const definition_core.Closure,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeFixed(&closure.digest);
    try encoder.writeUsize(closure.total_definition_bytes);
    try encoder.writeCount(closure.files.len);
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
) !definition_core.Closure {
    var digest: [71]u8 = undefined;
    @memcpy(&digest, try decoder.readFixed(digest.len));
    try definition_core.json.digest(&digest);
    const total_definition_bytes = try decoder.readUsize();
    const count = try decoder.readCount(limits.max_files);
    var closure: definition_core.Closure = closure: {
        const files = try allocator.alloc(definition_core.ClosureFile, count);
        var initialized: usize = 0;
        errdefer {
            for (files[0..initialized]) |*file| {
                allocator.free(file.path);
                allocator.free(file.canonical_json);
            }
            allocator.free(files);
        }
        for (files) |*file| {
            const path = try decoder.readBytesAlloc(
                allocator,
                limits.max_file_bytes,
            );
            errdefer allocator.free(path);
            const canonical_json = try decoder.readBytesAlloc(
                allocator,
                limits.max_file_bytes,
            );
            errdefer allocator.free(canonical_json);
            var source_digest: [32]u8 = undefined;
            @memcpy(
                &source_digest,
                try decoder.readFixed(source_digest.len),
            );
            const source_bytes = try decoder.readUsize();
            file.* = .{
                .path = path,
                .canonical_json = canonical_json,
                .source_digest = source_digest,
                .source_bytes = source_bytes,
            };
            initialized += 1;
        }
        break :closure .{
            .files = files,
            .digest = digest,
            .total_definition_bytes = total_definition_bytes,
        };
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
    const required_validation = route.kind == .definition_check or
        route.kind == .validation or
        route.kind == .materialization or
        route.kind == .transact;
    const required_materialization = route.kind == .materialization;
    const required_storage = route.kind == .definition_check or
        route.kind == .transact or
        route.kind == .project or
        route.kind == .doctor;
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

test "compiled plan cache rebuilds misses and skips definition parsing on hits" {
    var source_tmp = std.testing.tmpDir(.{});
    defer source_tmp.cleanup();
    try source_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/cache","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object"]},"parameters":{},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","input":"record","path":"","keys":["value"]}]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":10,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":16}}
        ,
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
    try std.testing.expectEqualStrings(
        cold.definition_plan.closure_digest[0..],
        warm.definition_plan.closure_digest[0..],
    );

    try source_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "artifact.json",
        .data =
        \\{"schema": "ledger-artifact-definition/v1","id":"example/cache","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["exact-object"]},"parameters":{},"inputs":{"record":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","input":"record","path":"","keys":["value"]}]},"constraints":[],"identity":{},"storage":{"kind":"pure"},"operations":{},"projections":{},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":10,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":16}}
        ,
    });
    var changed_source = try load(
        std.testing.allocator,
        source_root,
        "artifact.json",
        route,
        "1.0.0-test",
        .{ .cache_dir = cache_root },
    );
    defer changed_source.deinit(std.testing.allocator);
    try std.testing.expect(!changed_source.stats.cache_hit);

    const key = planKey(
        "1.0.0-test",
        route,
        &changed_source.definition_plan,
    );
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
        .data =
        \\{"schema":"ledger-artifact-definition/v1","id":"example/cache-allocation","owner":"example","requires":{"abi":"ledger-artifact-abi/v1","operators":["body-digest","compare-and-append","event-digest","event-envelope","event-kinds","exact-object","fold","path-format","previous-digest","reducer","replay","sequence","transition-table"]},"parameters":{"limit":{"type":"integer","required":false,"default":10},"stream":{"type":"safe_identifier","required":false,"default":"events"}},"inputs":{"event":{"codec":"json","max_bytes":4096}},"canonicalization":{},"shape":{"rules":[{"op":"exact-object","input":"event","path":"","keys":["body","body_digest","event_digest","kind","previous_digest","sequence"]},{"op":"event-envelope","input":"event","keys":["body","body_digest","event_digest","kind","previous_digest","sequence"],"sequence":"/sequence","kind":"/kind","previous_digest":"/previous_digest","body":"/body","body_digest":"/body_digest","event_digest":"/event_digest"}]},"constraints":[{"op":"sequence","start":1},{"op":"previous-digest","genesis":null},{"op":"body-digest"},{"op":"event-digest"},{"op":"event-kinds","values":["captured"]},{"op":"transition-table","states":["current"],"transitions":[{"from":null,"on":"captured","to":"current"}]},{"op":"reducer","key":"/body/id","on":"/kind"}],"identity":{},"storage":{"kind":"event-log","slots":{"events":{"path":"example/{stream}/events.jsonl","kind":"event-log","codec":"jsonl","max_bytes":4096}}},"operations":{"append":{"effects":[{"op":"compare-and-append","slot":"events","input":"event"}]}},"projections":{"current":{"slot":"events","pipeline":[{"op":"fold","key_field":"id","state_field":"status"}]}},"bounds":{"max_input_bytes":4096,"max_store_bytes":4096,"max_records":10,"max_output_bytes":4096,"max_diagnostics":8,"max_reducer_states":16}}
        ,
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
