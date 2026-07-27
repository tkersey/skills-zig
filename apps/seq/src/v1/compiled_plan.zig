const std = @import("std");
const definition_core = @import("definition_core");
const durable_store = @import("durable_store");
const definition = @import("definition.zig");
const plan = @import("plan.zig");

const payload_version: u16 = 1;
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
    request: Request,
    runtime_version: []const u8,
    source_adapter_version: []const u8,
    options: Options,
) !PlanSet {
    try request.validate();
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
            request,
            runtime_version,
            source_adapter_version,
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
        request,
        options.closure_limits,
    );
    compiled.stats.compile_ns = elapsedNanoseconds(start_ns);
    if (options.cache_dir) |cache_dir| {
        writeCache(
            allocator,
            cache_dir,
            admitted_root,
            request,
            runtime_version,
            source_adapter_version,
            &compiled,
        ) catch {
            compiled.stats.cache_write_failed = true;
        };
    }
    return compiled;
}

fn compileFromSource(
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    entry_path: []const u8,
    request: Request,
    closure_limits: definition_core.closure.Limits,
) !PlanSet {
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
    allocator: std.mem.Allocator,
    admitted_root: []const u8,
    entry_path: []const u8,
    request: Request,
    runtime_version: []const u8,
    source_adapter_version: []const u8,
    cache_dir: []const u8,
    closure_limits: definition_core.closure.Limits,
) !?PlanSet {
    const locator_key = locatorKey(
        admitted_root,
        entry_path,
        request,
        runtime_version,
        source_adapter_version,
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
    const locator_payload = try definition_core.cache.decode(
        locator_key,
        locator_entry,
        locator_limits,
    );
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
    const plan_payload = try definition_core.cache.decode(
        locator.plan_key,
        plan_entry,
        cache_limits,
    );
    var result = try decodePlanSet(
        allocator,
        plan_payload,
        entry_path,
        request,
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
        source_adapter_version,
        request,
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
    request: Request,
    runtime_version: []const u8,
    source_adapter_version: []const u8,
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
        request,
        runtime_version,
        source_adapter_version,
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
        const files = try allocator.alloc(
            definition_core.ClosureFile,
            count,
        );
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
            file.* = .{
                .path = path,
                .canonical_json = canonical_json,
                .source_digest = source_digest,
                .source_bytes = try decoder.readUsize(),
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
        return error.SeqCacheLocatorVersionMismatch;
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
    if (count == 0) return error.TooManyDefinitionFiles;
    const files = try allocator.alloc(SourceManifestFile, count);
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |*file| file.deinit(allocator);
        allocator.free(files);
    }
    for (files) |*file| {
        const path = try decoder.readBytesAlloc(
            allocator,
            4 * 1024 * 1024,
        );
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

fn cachePathAlloc(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    namespace: []const u8,
    cache_key: [32]u8,
) ![]u8 {
    const hex = definition_core.cache.keyHex(cache_key);
    const filename = try std.fmt.allocPrint(
        allocator,
        "{s}.bin",
        .{&hex},
    );
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

fn decodePlanSetForAllocationFailure(
    allocator: std.mem.Allocator,
    payload: []const u8,
    request: Request,
) !void {
    var plan_set = decodePlanSet(
        allocator,
        payload,
        "observation.json",
        request,
        .{},
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer plan_set.deinit(allocator);
}

test "compiled plan cache restores typed plans and rebuilds corrupt entries" {
    var source_tmp = std.testing.tmpDir(.{});
    defer source_tmp.cleanup();
    const observation_source =
        \\{"schema":"seq-observation-definition/v1","id":"example/cache","requires":{"abi":"seq-observation-abi/v1","operators":["scan","filter","project"]},"parameters":{"needle":{"type":"string","required":true}},"selectors":["path"],"relations":[{"name":"messages","fields":["session_id","text"]}],"inputs":[],"pipeline":[{"op":"scan","relation":"messages","as":"source"},{"op":"filter","input":"source","as":"matched","where":[{"field":"text","op":"contains","param":"needle"}]},{"op":"project","input":"matched","as":"rows","fields":["session_id","text"]}],"projections":{"rows":{"relation":"rows","schema":"example-rows/v1","fields":["session_id","text"],"renderers":["json"]}},"bounds":{"max_rows":100,"max_output_bytes":4096,"max_fold_states":8}}
    ;
    try source_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data = observation_source,
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

    var cold = try load(
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
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodePlanSetForAllocationFailure,
        .{ payload, request },
    );

    var warm = try load(
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

    const key = planKey(
        "1.0.0",
        "trace-source/v1",
        request,
        &warm.definition_plan,
    );
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

    try source_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "observation.json",
        .data = "\n" ++ observation_source,
    });
    var source_miss = try load(
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
        "observation.json",
        request,
        "1.0.1",
        "trace-source/v1",
        .{ .cache_dir = blocked_cache },
    );
    defer write_failure.deinit(std.testing.allocator);
    try std.testing.expect(write_failure.stats.cache_write_failed);
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
