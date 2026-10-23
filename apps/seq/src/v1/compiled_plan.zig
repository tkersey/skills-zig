const std = @import("std");
const definition_core = @import("definition_core");
const source_cache = definition_core.source_cache;
const cache_store = definition_core.cache_store;
const durable_store = @import("durable_store");
const definition = @import("definition.zig");
const plan = @import("plan.zig");

const payload_version: u16 = 2;
const locator_version: u16 = 1;
const cache_limits: definition_core.cache.Limits = .{};
const locator_max_payload_bytes: usize = 2 * 1024 * 1024;
const locator_limits: definition_core.cache.Limits = .{
    .max_payload_bytes = locator_max_payload_bytes,
    .max_entry_bytes = locator_max_payload_bytes +
        definition_core.cache.header_bytes,
};

pub const Request = struct {
    projection_names: []const []const u8 = &.{},

    pub fn validate(self: Request) !void {
        if (self.projection_names.len > 64) {
            return error.InvalidProjectionCount;
        }
        for (self.projection_names, 0..) |name, index| {
            try definition_core.json.safeIdentifier(name, 128);
            if (index != 0 and
                std.mem.order(
                    u8,
                    self.projection_names[index - 1],
                    name,
                ) != .lt)
            {
                return error.ProjectionSetNotSorted;
            }
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
    native_plan: plan.Plan,
    stats: definition_core.result.CompileStats,
    cache_arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *PlanSet, allocator: std.mem.Allocator) void {
        if (self.cache_arena) |arena_value| {
            var arena = arena_value;
            const cache_allocator = arena.allocator();
            self.native_plan.deinit(cache_allocator);
            self.definition_plan.deinit(cache_allocator);
            cache_allocator.free(self.entry_path);
            self.closure.deinit(cache_allocator);
            arena.deinit();
        } else {
            self.native_plan.deinit(allocator);
            self.definition_plan.deinit(allocator);
            allocator.free(self.entry_path);
            self.closure.deinit(allocator);
        }
        self.* = undefined;
    }
};

const Locator = source_cache.Locator;
const VerifiedLocator = source_cache.VerifiedLocator;

pub fn load(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    entry_path: []const u8,
    request: Request,
    runtime_version: []const u8,
    source_adapter_version: []const u8,
    options: Options,
) !PlanSet {
    try request.validate();
    if (!std.fs.path.isAbsolute(admitted_root)) {
        return error.DefinitionRootNotAbsolute;
    }
    const start_ns = monotonicNanoseconds(fs.io);
    if (options.cache_dir) |cache_dir| {
        if (!std.fs.path.isAbsolute(cache_dir)) {
            return error.CacheRootNotAbsolute;
        }
        const cached = tryLoadCache(
            fs,
            allocator,
            admitted_root,
            entry_path,
            request,
            runtime_version,
            source_adapter_version,
            cache_dir,
            options.closure_limits,
        ) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => null,
        };
        if (cached) |value| {
            var result = value;
            result.stats.compile_ns = elapsedNanoseconds(fs.io, start_ns);
            return result;
        }
    }

    var compiled = try compileFromSource(
        fs,
        allocator,
        admitted_root,
        entry_path,
        request,
        options.closure_limits,
    );
    errdefer compiled.deinit(allocator);
    compiled.stats.compile_ns = elapsedNanoseconds(fs.io, start_ns);
    if (options.cache_dir) |cache_dir| {
        writeCache(
            fs,
            allocator,
            cache_dir,
            admitted_root,
            request,
            runtime_version,
            source_adapter_version,
            &compiled,
        ) catch |err| {
            // Cancellation ends the operation, even when the cache is optional.
            if (err == error.Canceled) return err;
            compiled.stats.cache_write_failed = true;
        };
    }
    return compiled;
}

fn compileFromSource(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    entry_path: []const u8,
    request: Request,
    closure_limits: definition_core.closure.Limits,
) !PlanSet {
    var closure = try definition_core.closure.load(
        fs.io,
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
    try validateRequest(&definition_plan, request);
    var native_plan = try plan.compile(allocator, &definition_plan);
    errdefer native_plan.deinit(allocator);
    try plan.validateCachePlan(&native_plan, &definition_plan);
    return .{
        .closure = closure,
        .entry_path = owned_entry_path,
        .definition_plan = definition_plan,
        .native_plan = native_plan,
        .stats = .{
            .cache_hit = false,
            .closure_files = closure.files.len,
            .closure_bytes = closure.total_definition_bytes,
        },
    };
}

fn tryLoadCache(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    entry_path: []const u8,
    request: Request,
    runtime_version: []const u8,
    source_adapter_version: []const u8,
    cache_dir: []const u8,
    closure_limits: definition_core.closure.Limits,
) !?PlanSet {
    var cache_root = try cache_store.Directory.open(fs, cache_dir, .read_only);
    defer cache_root.deinit();
    const locator_key = locatorKey(
        admitted_root,
        entry_path,
        request,
        runtime_version,
        source_adapter_version,
    );
    const cached_locator = try cache_root.readVerifiedLocator(
        allocator,
        locator_key,
        admitted_root,
        locator_limits,
        closure_limits,
        decodeLocator,
    );
    var locator = cached_locator orelse return null;
    defer locator.deinit(allocator);
    return @as(?PlanSet, try loadCachedPlan(
        allocator,
        &cache_root,
        entry_path,
        request,
        runtime_version,
        source_adapter_version,
        &locator,
        closure_limits,
    ));
}

fn loadCachedPlan(
    allocator: std.mem.Allocator,
    cache_root: *const cache_store.Directory,
    entry_path: []const u8,
    request: Request,
    runtime_version: []const u8,
    source_adapter_version: []const u8,
    locator: *const VerifiedLocator,
    closure_limits: definition_core.closure.Limits,
) !PlanSet {
    var entry = try cache_root.read(
        allocator,
        .plans,
        locator.value.plan_key,
        cache_limits,
    );
    defer entry.deinit();
    var result = try decodePlanSet(
        allocator,
        entry.payload,
        entry_path,
        request,
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
        return error.CacheClosureManifestMismatch;
    const expected_plan_key = planKey(
        runtime_version,
        source_adapter_version,
        request,
        &result.definition_plan,
    );
    if (!std.mem.eql(u8, &expected_plan_key, &locator.value.plan_key)) {
        return error.CachePlanKeyMismatch;
    }
    result.stats.cache_hit = true;
    return result;
}

fn writeCache(
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    admitted_root: []const u8,
    request: Request,
    runtime_version: []const u8,
    source_adapter_version: []const u8,
    plan_set: *const PlanSet,
) !void {
    var cache_root = try cache_store.Directory.open(fs, cache_dir, .create);
    defer cache_root.deinit();
    const publication = try writePlanEntry(
        allocator,
        &cache_root,
        runtime_version,
        source_adapter_version,
        request,
        plan_set,
    );
    try writeLocatorEntry(
        allocator,
        publication,
        admitted_root,
        runtime_version,
        source_adapter_version,
        request,
        plan_set,
    );
}

fn writePlanEntry(
    allocator: std.mem.Allocator,
    cache_root: *const cache_store.Directory,
    runtime_version: []const u8,
    source_adapter_version: []const u8,
    request: Request,
    plan_set: *const PlanSet,
) !cache_store.PlanPublication {
    const plan_key = planKey(
        runtime_version,
        source_adapter_version,
        request,
        &plan_set.definition_plan,
    );
    var plan_encoder = definition_core.cache.Encoder.init(
        allocator,
        cache_limits.max_payload_bytes,
    );
    defer plan_encoder.deinit();
    try encodePlanSet(plan_set, &plan_encoder);
    return cache_root.publishPlan(plan_key, plan_encoder.written(), cache_limits);
}

fn writeLocatorEntry(
    allocator: std.mem.Allocator,
    publication: cache_store.PlanPublication,
    admitted_root: []const u8,
    runtime_version: []const u8,
    source_adapter_version: []const u8,
    request: Request,
    plan_set: *const PlanSet,
) !void {
    const locator_key = locatorKey(
        admitted_root,
        plan_set.entry_path,
        request,
        runtime_version,
        source_adapter_version,
    );
    var locator_encoder = definition_core.cache.Encoder.init(
        allocator,
        locator_limits.max_payload_bytes,
    );
    defer locator_encoder.deinit();
    try encodeLocator(plan_set, publication.key, &locator_encoder);
    try publication.publishLocator(
        locator_key,
        locator_encoder.written(),
        locator_limits,
    );
}

fn encodePlanSet(
    plan_set: *const PlanSet,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(payload_version);
    try encoder.writeBytes(plan_set.entry_path);
    try encodeClosure(&plan_set.closure, encoder);
    try definition.encodeCache(&plan_set.definition_plan, encoder);
    try plan.encodeCache(&plan_set.native_plan, encoder);
}

fn decodePlanSet(
    allocator: std.mem.Allocator,
    payload: []const u8,
    expected_entry_path: []const u8,
    request: Request,
    closure_limits: definition_core.closure.Limits,
) !PlanSet {
    var cache_arena = std.heap.ArenaAllocator.init(allocator);
    var cache_arena_owned = true;
    errdefer if (cache_arena_owned) cache_arena.deinit();
    const cache_allocator = cache_arena.allocator();
    var decoder = definition_core.cache.Decoder.init(payload);
    if (try decoder.readU16() != payload_version) {
        return error.SeqCompiledPlanCacheVersionMismatch;
    }
    var result: PlanSet = result: {
        const entry_path = try decoder.readBytesAlloc(
            cache_allocator,
            4 * 1024 * 1024,
        );
        errdefer cache_allocator.free(entry_path);
        if (!std.mem.eql(u8, entry_path, expected_entry_path)) {
            return error.CacheEntryPathMismatch;
        }
        var closure = try decodeClosure(
            cache_allocator,
            &decoder,
            entry_path,
            closure_limits,
        );
        errdefer closure.deinit(cache_allocator);
        var definition_plan = try definition.decodeCache(
            cache_allocator,
            &decoder,
        );
        errdefer definition_plan.deinit(cache_allocator);
        if (!std.mem.eql(
            u8,
            &definition_plan.closure_digest,
            &closure.digest,
        )) return error.CacheClosureDigestMismatch;
        try validateRequest(&definition_plan, request);
        var native_plan = try plan.decodeCache(
            cache_allocator,
            &decoder,
            &definition_plan,
        );
        errdefer native_plan.deinit(cache_allocator);
        break :result .{
            .closure = closure,
            .entry_path = entry_path,
            .definition_plan = definition_plan,
            .native_plan = native_plan,
            .stats = .{
                .cache_hit = true,
                .closure_files = closure.files.len,
                .closure_bytes = closure.total_definition_bytes,
            },
        };
    };
    errdefer result.deinit(cache_allocator);
    try decoder.finish();
    try validatePlanSet(&result, request);
    result.cache_arena = cache_arena;
    cache_arena_owned = false;
    return result;
}

const encodeClosure = source_cache.encodeClosure;
const decodeClosure = source_cache.decodeClosure;

fn encodeLocator(
    plan_set: *const PlanSet,
    plan_key: [32]u8,
    encoder: *definition_core.cache.Encoder,
) !void {
    try encoder.writeU16(locator_version);
    try source_cache.encodeLocatorBody(&plan_set.closure, plan_key, encoder);
}

fn decodeLocator(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !Locator {
    var decoder = definition_core.cache.Decoder.init(payload);
    if (try decoder.readU16() != locator_version) {
        return error.SeqCacheLocatorVersionMismatch;
    }
    return source_cache.decodeLocatorBody(allocator, &decoder, .{ .min_files = 1 });
}

fn validatePlanSet(
    plan_set: *const PlanSet,
    request: Request,
) !void {
    if (!std.mem.eql(
        u8,
        &plan_set.definition_plan.closure_digest,
        &plan_set.closure.digest,
    )) return error.CacheClosureDigestMismatch;
    try validateRequest(&plan_set.definition_plan, request);
    try plan.validateCachePlan(
        &plan_set.native_plan,
        &plan_set.definition_plan,
    );
}

fn validateRequest(
    definition_plan: *const definition.Plan,
    request: Request,
) !void {
    try request.validate();
    for (request.projection_names) |name| {
        var found = false;
        for (definition_plan.projections) |projection| {
            if (std.mem.eql(u8, projection.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnknownObservationProjection;
    }
}

fn planKey(
    runtime_version: []const u8,
    source_adapter_version: []const u8,
    request: Request,
    definition_plan: *const definition.Plan,
) [32]u8 {
    const selection_digest = projectionSetDigest(request);
    return definition_core.cache.key(&.{
        "seq-compiled-plan/v1",
        definition.abi,
        runtime_version,
        source_adapter_version,
        definition_plan.closure_digest[0..],
        definition_plan.parameter_declarations.shape_digest[0..],
        selection_digest[0..],
    });
}

fn locatorKey(
    admitted_root: []const u8,
    entry_path: []const u8,
    request: Request,
    runtime_version: []const u8,
    source_adapter_version: []const u8,
) [32]u8 {
    const selection_digest = projectionSetDigest(request);
    return definition_core.cache.key(&.{
        "seq-cache-locator/v1",
        definition.abi,
        runtime_version,
        source_adapter_version,
        admitted_root,
        entry_path,
        selection_digest[0..],
    });
}

fn projectionSetDigest(request: Request) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("seq-projection-set/v1\x00");
    var length: [8]u8 = undefined;
    for (request.projection_names) |name| {
        std.mem.writeInt(u64, &length, @intCast(name.len), .big);
        hasher.update(&length);
        hasher.update(name);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

const cacheLeaf = cache_store.leaf;

fn cachePathAlloc(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    namespace: []const u8,
    cache_key: [32]u8,
) ![]u8 {
    const hex = definition_core.cache.keyHex(cache_key);
    const filename = try allocator.print(
        "{s}.bin",
        .{&hex},
    );
    defer allocator.free(filename);
    return std.fs.path.join(
        allocator,
        &.{ cache_dir, namespace, filename },
    );
}

fn monotonicNanoseconds(io: std.Io) u64 {
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    if (now <= 0) return 0;
    return std.math.cast(u64, now) orelse std.math.maxInt(u64);
}

fn elapsedNanoseconds(io: std.Io, start: u64) u64 {
    const now = monotonicNanoseconds(io);
    return if (now > start) now - start else 0;
}

fn decodePlanSetForAllocationFailure(
    allocator: std.mem.Allocator,
    payload: []const u8,
    request: Request,
) !void {
    var plan_set = try decodePlanSet(
        allocator,
        payload,
        "observation.json",
        request,
        .{},
    );
    defer plan_set.deinit(allocator);
}

const cached_observation_definition =
    \\{
    \\  "schema": "seq-observation-definition/v1",
    \\  "id": "example/cache",
    \\  "requires": {
    \\    "abi": "seq-observation-abi/v1",
    \\    "operators": ["scan", "filter", "project"]
    \\  },
    \\  "parameters": {"needle": {"type": "string", "required": true}},
    \\  "selectors": ["path"],
    \\  "relations": [{"name": "messages", "fields": ["session_id", "text"]}],
    \\  "inputs": [],
    \\  "pipeline": [
    \\    {"op": "scan", "relation": "messages", "as": "source"},
    \\    {"op": "filter", "input": "source", "as": "matched",
    \\     "where": [{"field": "text", "op": "contains", "param": "needle"}]},
    \\    {"op": "project", "input": "matched", "as": "rows",
    \\     "fields": ["session_id", "text"]}
    \\  ],
    \\  "projections": {
    \\    "rows": {"relation": "rows", "schema": "example-rows/v1",
    \\             "fields": ["session_id", "text"], "renderers": ["json"]}
    \\  },
    \\  "bounds": {
    \\    "max_rows": 100,
    \\    "max_output_bytes": 4096,
    \\    "max_fold_states": 8
    \\  }
    \\}
;

fn cacheHitKey(
    source_root: []const u8,
    cache_root: []const u8,
    request: Request,
) ![32]u8 {
    var cold = try load(
        durable_store.Fs.init(std.testing.io, .cwd()),
        std.testing.allocator,
        source_root,
        "observation.json",
        request,
        "1.0.0",
        "trace-source/v1",
        .{ .cache_dir = cache_root },
    );
    defer cold.deinit(std.testing.allocator);
    try std.testing.expect(!cold.stats.cache_hit);
    var encoder = definition_core.cache.Encoder.init(
        std.testing.allocator,
        cache_limits.max_payload_bytes,
    );
    defer encoder.deinit();
    try encodePlanSet(&cold, &encoder);
    const payload = try encoder.toOwnedSlice();
    defer std.testing.allocator.free(payload);
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        decodePlanSetForAllocationFailure,
        .{ payload, request },
    );

    var warm = try load(
        durable_store.Fs.init(std.testing.io, .cwd()),
        std.testing.allocator,
        source_root,
        "observation.json",
        request,
        "1.0.0",
        "trace-source/v1",
        .{ .cache_dir = cache_root },
    );
    defer warm.deinit(std.testing.allocator);
    try std.testing.expect(warm.stats.cache_hit);
    try std.testing.expectEqualStrings(
        cold.definition_plan.id,
        warm.definition_plan.id,
    );
    return planKey(
        "1.0.0",
        "trace-source/v1",
        request,
        &warm.definition_plan,
    );
}

fn repairCache(
    source_root: []const u8,
    cache_root: []const u8,
    request: Request,
    key: [32]u8,
) !void {
    const corrupt_path = try cachePathAlloc(
        std.testing.allocator,
        cache_root,
        "plans",
        key,
    );
    defer std.testing.allocator.free(corrupt_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = corrupt_path,
        .data = "corrupt",
    });
    var rebuilt = try load(
        durable_store.Fs.init(std.testing.io, .cwd()),
        std.testing.allocator,
        source_root,
        "observation.json",
        request,
        "1.0.0",
        "trace-source/v1",
        .{ .cache_dir = cache_root },
    );
    defer rebuilt.deinit(std.testing.allocator);
    try std.testing.expect(!rebuilt.stats.cache_hit);
    var repaired_hit = try load(
        durable_store.Fs.init(std.testing.io, .cwd()),
        std.testing.allocator,
        source_root,
        "observation.json",
        request,
        "1.0.0",
        "trace-source/v1",
        .{ .cache_dir = cache_root },
    );
    defer repaired_hit.deinit(std.testing.allocator);
    try std.testing.expect(repaired_hit.stats.cache_hit);
}

fn invalidateCache(
    source_dir: *std.Io.Dir,
    source_root: []const u8,
    cache_dir: *std.Io.Dir,
    cache_root: []const u8,
    request: Request,
) !void {
    try source_dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data = "\n" ++ cached_observation_definition,
    });
    var source_miss = try load(
        durable_store.Fs.init(std.testing.io, .cwd()),
        std.testing.allocator,
        source_root,
        "observation.json",
        request,
        "1.0.0",
        "trace-source/v1",
        .{ .cache_dir = cache_root },
    );
    defer source_miss.deinit(std.testing.allocator);
    try std.testing.expect(!source_miss.stats.cache_hit);

    var adapter_miss = try load(
        durable_store.Fs.init(std.testing.io, .cwd()),
        std.testing.allocator,
        source_root,
        "observation.json",
        request,
        "1.0.0",
        "trace-source/v2",
        .{ .cache_dir = cache_root },
    );
    defer adapter_miss.deinit(std.testing.allocator);
    try std.testing.expect(!adapter_miss.stats.cache_hit);

    try cache_dir.writeFile(std.testing.io, .{
        .sub_path = "not-a-directory",
        .data = "cache writes must remain optional",
    });
    const blocked_cache = try cache_dir.realPathFileAlloc(
        std.testing.io,
        "not-a-directory",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(blocked_cache);
    var write_failure = try load(
        durable_store.Fs.init(std.testing.io, .cwd()),
        std.testing.allocator,
        source_root,
        "observation.json",
        request,
        "1.0.1",
        "trace-source/v1",
        .{ .cache_dir = blocked_cache },
    );
    defer write_failure.deinit(std.testing.allocator);
    try std.testing.expect(write_failure.stats.cache_write_failed);
}

test "compiled plan cache restores typed plans and rebuilds corrupt entries" {
    var source_tmp = std.testing.tmpDir(.{});
    defer source_tmp.cleanup();
    try source_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data = cached_observation_definition,
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
    const request: Request = .{ .projection_names = &.{"rows"} };
    const key = try cacheHitKey(source_root, cache_root, request);
    try repairCache(source_root, cache_root, request, key);
    try invalidateCache(
        &source_tmp.dir,
        source_root,
        &cache_tmp.dir,
        cache_root,
        request,
    );
}

test "projection cache selection is canonical and explicit" {
    try std.testing.expectError(
        error.ProjectionSetNotSorted,
        (Request{ .projection_names = &.{ "summary", "rows" } }).validate(),
    );
    try (Request{
        .projection_names = &.{ "rows", "summary" },
    }).validate();
    try std.testing.expect(!std.mem.eql(
        u8,
        &projectionSetDigest(.{ .projection_names = &.{"rows"} }),
        &projectionSetDigest(.{ .projection_names = &.{"summary"} }),
    ));
}

test "failed locator publication leaves a complete unadvertised plan and a usable source result" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const fs = durable_store.Fs.init(io, .cwd());
    var source = std.testing.tmpDir(.{});
    defer source.cleanup();
    try source.dir.writeFile(
        io,
        .{ .sub_path = "observation.json", .data = cached_observation_definition },
    );
    const source_root = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_root);
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    try cache.dir.writeFile(io, .{ .sub_path = "locators", .data = "obstruction" });
    const cache_root = try cache.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cache_root);
    const request: Request = .{ .projection_names = &.{"rows"} };
    var result = try load(
        fs,
        allocator,
        source_root,
        "observation.json",
        request,
        "1",
        "trace/v1",
        .{ .cache_dir = cache_root },
    );
    defer result.deinit(allocator);
    try std.testing.expect(result.stats.cache_write_failed);
    try std.testing.expect(!result.stats.cache_hit);
    var root = try durable_store.PrivateDirectory.open(fs, cache_root, .read_only);
    defer root.deinit();
    var plans = try root.openChild("plans", .read_only);
    defer plans.deinit();
    const key = planKey("1", "trace/v1", request, &result.definition_plan);
    const leaf = cacheLeaf(key);
    const entry = try plans.readAlloc(allocator, &leaf, cache_limits.max_entry_bytes);
    defer allocator.free(entry);
    _ = try definition_core.cache.decode(key, entry, cache_limits);
    try cache.dir.deleteFile(io, "locators");
    var repaired = try load(
        fs,
        allocator,
        source_root,
        "observation.json",
        request,
        "1",
        "trace/v1",
        .{ .cache_dir = cache_root },
    );
    defer repaired.deinit(allocator);
    try std.testing.expect(!repaired.stats.cache_hit);
    try std.testing.expect(!repaired.stats.cache_write_failed);
    var warm = try load(
        fs,
        allocator,
        source_root,
        "observation.json",
        request,
        "1",
        "trace/v1",
        .{ .cache_dir = cache_root },
    );
    defer warm.deinit(allocator);
    try std.testing.expect(warm.stats.cache_hit);
}

const CacheCancellationProbe = struct {
    var cancel_read = false;
    var cancel_rename: usize = 0;
    var rename_count: usize = 0;
    var cancellations: usize = 0;
    var cancel_read_file: usize = 0;
    var read_count: usize = 0;

    fn checkCancel(userdata: ?*anyopaque) std.Io.Cancelable!void {
        if (cancel_read) {
            cancel_read = false;
            cancellations += 1;
            return error.Canceled;
        }
        return std.testing.io.vtable.checkCancel(userdata);
    }

    fn read(
        userdata: ?*anyopaque,
        file: std.Io.File,
        buffers: []const []u8,
        offset: u64,
    ) std.Io.File.ReadPositionalError!usize {
        if (offset == 0) {
            read_count += 1;
            if (read_count == cancel_read_file) {
                cancellations += 1;
                return error.Canceled;
            }
        }
        return std.testing.io.vtable.fileReadPositional(userdata, file, buffers, offset);
    }

    fn rename(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_name: []const u8,
        new_dir: std.Io.Dir,
        new_name: []const u8,
    ) std.Io.Dir.RenameError!void {
        rename_count += 1;
        if (rename_count == cancel_rename) {
            cancellations += 1;
            return error.Canceled;
        }
        return std.testing.io.vtable.dirRename(userdata, old_dir, old_name, new_dir, new_name);
    }
};

test "optional cache cancellation stops reads and both publication phases without leaking plans" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var source = std.testing.tmpDir(.{});
    defer source.cleanup();
    try source.dir.writeFile(io, .{
        .sub_path = "definition.json",
        .data = cached_observation_definition,
    });
    const source_root = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_root);
    // Zero cancels cache admission; one and two cancel plan and locator publication.
    for (0..3) |phase| {
        var cache = std.testing.tmpDir(.{});
        defer cache.cleanup();
        const cache_root = try cache.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(cache_root);
        CacheCancellationProbe.cancel_read = phase == 0;
        CacheCancellationProbe.cancel_rename = phase;
        CacheCancellationProbe.rename_count = 0;
        CacheCancellationProbe.cancellations = 0;
        var vtable = io.vtable.*;
        vtable.checkCancel = CacheCancellationProbe.checkCancel;
        vtable.dirRename = CacheCancellationProbe.rename;
        const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        const fs = durable_store.Fs.init(injected, .cwd());
        try std.testing.expectError(error.Canceled, load(
            fs,
            allocator,
            source_root,
            "definition.json",
            .{ .projection_names = &.{"rows"} },
            "1",
            "trace/v1",
            .{ .cache_dir = cache_root },
        ));
        try std.testing.expectEqual(@as(usize, 1), CacheCancellationProbe.cancellations);
        try std.testing.expectEqual(phase, CacheCancellationProbe.rename_count);
        // The one-shot signal is consumed: later independent work remains valid.
        CacheCancellationProbe.cancel_rename = 0;
        var recovered = try load(
            fs,
            allocator,
            source_root,
            "definition.json",
            .{ .projection_names = &.{"rows"} },
            "1",
            "trace/v1",
            .{ .cache_dir = cache_root },
        );
        defer recovered.deinit(allocator);
        try std.testing.expect(!recovered.stats.cache_hit);
        try std.testing.expect(!recovered.stats.cache_write_failed);
        var warm = try load(
            fs,
            allocator,
            source_root,
            "definition.json",
            .{ .projection_names = &.{"rows"} },
            "1",
            "trace/v1",
            .{ .cache_dir = cache_root },
        );
        defer warm.deinit(allocator);
        try std.testing.expect(warm.stats.cache_hit);
    }
}

test "warm cache cancellation survives the locator source and plan reader adapters" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const fs = durable_store.Fs.init(io, .cwd());
    var source = std.testing.tmpDir(.{});
    defer source.cleanup();
    try source.dir.writeFile(io, .{
        .sub_path = "definition.json",
        .data = cached_observation_definition,
    });
    const source_root = try source.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(source_root);
    var cache = std.testing.tmpDir(.{});
    defer cache.cleanup();
    const cache_root = try cache.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cache_root);
    var cold = try load(
        fs,
        allocator,
        source_root,
        "definition.json",
        .{ .projection_names = &.{"rows"} },
        "1",
        "trace/v1",
        .{ .cache_dir = cache_root },
    );
    defer cold.deinit(allocator);
    try std.testing.expect(!cold.stats.cache_write_failed);
    // Warm lookup reads the locator, its source manifest, and then the plan.
    for (1..4) |file_number| {
        CacheCancellationProbe.read_count = 0;
        CacheCancellationProbe.cancellations = 0;
        CacheCancellationProbe.cancel_read_file = file_number;
        defer CacheCancellationProbe.cancel_read_file = 0;
        CacheCancellationProbe.rename_count = 0;
        CacheCancellationProbe.cancel_rename = 0;
        var vtable = io.vtable.*;
        vtable.fileReadPositional = CacheCancellationProbe.read;
        vtable.dirRename = CacheCancellationProbe.rename;
        const injected: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        const injected_fs = durable_store.Fs.init(injected, .cwd());
        try std.testing.expectError(error.Canceled, load(
            injected_fs,
            allocator,
            source_root,
            "definition.json",
            .{ .projection_names = &.{"rows"} },
            "1",
            "trace/v1",
            .{ .cache_dir = cache_root },
        ));
        try std.testing.expectEqual(file_number, CacheCancellationProbe.read_count);
        try std.testing.expectEqual(@as(usize, 1), CacheCancellationProbe.cancellations);
        try std.testing.expectEqual(@as(usize, 0), CacheCancellationProbe.rename_count);
    }
}
