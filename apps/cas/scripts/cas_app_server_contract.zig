const std = @import("std");
const definition_core = @import("definition_core");
const proxy_client = @import("cas_proxy_client");

pub const baseline_json = @import("cas_app_server_contract_data").json;

const max_methods = 256;
const max_shapes = 64;
const max_documents = 64;
const max_document_bytes = 8 * 1024 * 1024;

const cache_schema = "cas-app-server-schema-cache/v1";
pub const app_server_contract_id = "codex-app-server-capabilities-v1";
const max_cache_documents: usize = 768;
const max_cache_file_bytes: u64 = 8 * 1024 * 1024;
const max_cache_total_bytes: u64 = 64 * 1024 * 1024;
const max_cache_relative_path: usize = 4096;
const max_binary_bytes: u64 = 512 * 1024 * 1024;
const max_manifest_bytes: usize = 64 * 1024;

pub const CodexVersion = struct {
    major: u64,
    minor: u64,
    patch: u64,
    text: []u8,
    banner: []u8,
    pre: ?[]const u8,
    build: ?[]const u8,

    pub fn deinit(self: *CodexVersion, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.banner);
        self.* = undefined;
    }

    pub fn prerelease(self: CodexVersion) bool {
        return self.pre != null;
    }
};

pub const ExecutableIdentity = struct {
    resolved_path: [:0]u8,
    path_fingerprint: []u8,
    binary_digest: []u8,
    inode: u64,
    size: u64,
    mtime_ns: i128,
    ctime_ns: i128,

    pub fn deinit(self: *ExecutableIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved_path);
        allocator.free(self.path_fingerprint);
        allocator.free(self.binary_digest);
        self.* = undefined;
    }
};

pub const CachedSchemas = struct {
    cache_path: []u8,
    stable_path: []u8,
    experimental_path: []u8,
    stable_digest: []u8,
    experimental_digest: []u8,
    stable_file_count: usize,
    stable_byte_count: u64,
    experimental_file_count: usize,
    experimental_byte_count: u64,
    version: CodexVersion,
    executable: ExecutableIdentity,
    hit: bool,
    _lock_io: std.Io,
    _lock_file: std.Io.File,
    _lock_held: bool = true,

    pub fn releaseLock(self: *CachedSchemas) void {
        if (!self._lock_held) return;
        self._lock_file.unlock(self._lock_io);
        self._lock_file.close(self._lock_io);
        self._lock_held = false;
    }

    pub fn deinit(self: *CachedSchemas, allocator: std.mem.Allocator) void {
        allocator.free(self.cache_path);
        allocator.free(self.stable_path);
        allocator.free(self.experimental_path);
        allocator.free(self.stable_digest);
        allocator.free(self.experimental_digest);
        self.version.deinit(allocator);
        self.executable.deinit(allocator);
        self.releaseLock();
        self.* = undefined;
    }
};

pub const CacheOptions = struct {
    cache_root: []const u8,
    codex_path: ?[]const u8 = null,
    contract_id: []const u8 = app_server_contract_id,
    refresh: bool = false,
};

const CacheLimits = struct {
    version_timeout_ms: u64 = 5_000,
    version_stdout_bytes: usize = 4 * 1024,
    version_stderr_bytes: usize = 16 * 1024,
    generator_timeout_ms: u64 = 30_000,
    generator_stdout_bytes: usize = 64 * 1024,
    generator_stderr_bytes: usize = 64 * 1024,
    // Cover both bounded generators plus identity hashing, bundle validation,
    // synced manifest publication, and a conservative filesystem margin.
    lock_timeout_ms: u64 = 180_000,
    lock_retry_ms: u64 = 25,
    binary_bytes: u64 = max_binary_bytes,
    bundle_documents: usize = max_cache_documents,
    bundle_file_bytes: u64 = max_cache_file_bytes,
    bundle_total_bytes: u64 = max_cache_total_bytes,
    bundle_path_bytes: usize = max_cache_relative_path,
};

const BundleDigest = struct {
    digest: []u8,
    file_count: usize,
    byte_count: u64,

    fn deinit(self: *BundleDigest, allocator: std.mem.Allocator) void {
        allocator.free(self.digest);
    }
};

const ManifestView = struct {
    stable_digest: []u8,
    stable_file_count: usize,
    stable_byte_count: u64,
    experimental_digest: []u8,
    experimental_file_count: usize,
    experimental_byte_count: u64,
};

const CachePaths = struct {
    cache: []u8,
    stable: []u8,
    experimental: []u8,

    fn init(
        allocator: std.mem.Allocator,
        executable_root: []const u8,
        version: []const u8,
    ) !CachePaths {
        const cache = try std.fs.path.join(allocator, &.{ executable_root, version });
        errdefer allocator.free(cache);
        const stable = try std.fs.path.join(allocator, &.{ cache, "stable" });
        errdefer allocator.free(stable);
        const experimental = try std.fs.path.join(allocator, &.{ cache, "experimental" });
        return .{ .cache = cache, .stable = stable, .experimental = experimental };
    }

    fn deinit(self: CachePaths, allocator: std.mem.Allocator) void {
        allocator.free(self.cache);
        allocator.free(self.stable);
        allocator.free(self.experimental);
    }
};

const StagingPaths = struct {
    root: []u8,
    stable: []u8,
    experimental: []u8,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        cache_path: []const u8,
        nonce: i128,
    ) !StagingPaths {
        const root = try std.fmt.allocPrint(allocator, "{s}.staging.{d}", .{ cache_path, nonce });
        errdefer allocator.free(root);
        try std.Io.Dir.cwd().deleteTree(io, root);
        errdefer std.Io.Dir.cwd().deleteTree(io, root) catch |err| ignoreError(err);
        const stable = try std.fs.path.join(allocator, &.{ root, "stable" });
        errdefer allocator.free(stable);
        const experimental = try std.fs.path.join(allocator, &.{ root, "experimental" });
        errdefer allocator.free(experimental);
        try std.Io.Dir.cwd().createDirPath(io, stable);
        try std.Io.Dir.cwd().createDirPath(io, experimental);
        return .{ .root = root, .stable = stable, .experimental = experimental };
    }

    fn deinit(self: StagingPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.stable);
        allocator.free(self.experimental);
    }
};

const GeneratedBundles = struct {
    stable: BundleDigest,
    experimental: BundleDigest,

    fn deinit(self: *GeneratedBundles, allocator: std.mem.Allocator) void {
        self.stable.deinit(allocator);
        self.experimental.deinit(allocator);
    }
};

pub fn ensureSchemaCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CacheOptions,
) !CachedSchemas {
    return ensureSchemaCacheWithLimits(allocator, io, options, .{});
}

fn ensureSchemaCacheWithLimits(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CacheOptions,
    limits: CacheLimits,
) !CachedSchemas {
    if (options.cache_root.len == 0 or options.contract_id.len == 0) {
        return error.InvalidCacheOptions;
    }
    const cache_root = try absoluteCacheRootAlloc(allocator, io, options.cache_root);
    defer allocator.free(cache_root);

    var identity = try resolveExecutableIdentity(
        allocator,
        io,
        options.codex_path,
        limits.binary_bytes,
    );
    errdefer identity.deinit(allocator);
    var version = try readCodexVersion(allocator, io, identity.resolved_path, limits);
    errdefer version.deinit(allocator);
    try requireIdentityUnchanged(allocator, io, &identity, limits.binary_bytes);

    const path_hex = identity.path_fingerprint["sha256:".len..];
    const executable_root = try std.fs.path.join(allocator, &.{ cache_root, path_hex });
    defer allocator.free(executable_root);
    try std.Io.Dir.cwd().createDirPath(io, executable_root);
    const lock_path = try std.fs.path.join(allocator, &.{ executable_root, ".lock" });
    defer allocator.free(lock_path);
    var lock = try acquireCacheLock(io, lock_path, limits);
    errdefer {
        lock.unlock(io);
        lock.close(io);
    }

    return ensureSchemaCacheLocked(
        allocator,
        io,
        options,
        limits,
        executable_root,
        &identity,
        version,
        lock,
    );
}

fn ensureSchemaCacheLocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CacheOptions,
    limits: CacheLimits,
    executable_root: []const u8,
    identity: *ExecutableIdentity,
    version: CodexVersion,
    lock: std.Io.File,
) !CachedSchemas {
    // Bind the generation to the identity and banner observed after lock acquisition.
    try requireIdentityUnchanged(allocator, io, identity, limits.binary_bytes);
    const paths = try CachePaths.init(allocator, executable_root, version.text);
    errdefer paths.deinit(allocator);

    if (!options.refresh) {
        if (try validateCacheHit(
            allocator,
            io,
            paths.cache,
            identity,
            version,
            options.contract_id,
            limits,
        )) |manifest| {
            return cachedSchemasFromManifest(paths, identity.*, version, io, lock, manifest);
        }
    }

    return generateSchemaCache(
        allocator,
        io,
        paths,
        identity,
        version,
        lock,
        options.contract_id,
        limits,
    );
}

fn cachedSchemasFromManifest(
    paths: CachePaths,
    identity: ExecutableIdentity,
    version: CodexVersion,
    io: std.Io,
    lock: std.Io.File,
    manifest: ManifestView,
) CachedSchemas {
    return .{
        .cache_path = paths.cache,
        .stable_path = paths.stable,
        .experimental_path = paths.experimental,
        .stable_digest = manifest.stable_digest,
        .experimental_digest = manifest.experimental_digest,
        .stable_file_count = manifest.stable_file_count,
        .stable_byte_count = manifest.stable_byte_count,
        .experimental_file_count = manifest.experimental_file_count,
        .experimental_byte_count = manifest.experimental_byte_count,
        .version = version,
        .executable = identity,
        .hit = true,
        ._lock_io = io,
        ._lock_file = lock,
    };
}

fn generateSchemaCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: CachePaths,
    identity: *ExecutableIdentity,
    version: CodexVersion,
    lock: std.Io.File,
    contract_id: []const u8,
    limits: CacheLimits,
) !CachedSchemas {
    const nonce = std.Io.Clock.awake.now(io).nanoseconds;
    const staging = try StagingPaths.init(allocator, io, paths.cache, nonce);
    defer staging.deinit(allocator);
    errdefer std.Io.Dir.cwd().deleteTree(io, staging.root) catch |err| ignoreError(err);
    var generated = try stageSchemaCache(
        allocator,
        io,
        staging,
        identity,
        version,
        contract_id,
        limits,
    );
    defer generated.deinit(allocator);
    try promoteCacheDirectory(allocator, io, staging.root, paths.cache, nonce);

    const owned_stable_digest = try allocator.dupe(u8, generated.stable.digest);
    errdefer allocator.free(owned_stable_digest);
    const owned_experimental_digest = try allocator.dupe(u8, generated.experimental.digest);
    return .{
        .cache_path = paths.cache,
        .stable_path = paths.stable,
        .experimental_path = paths.experimental,
        .stable_digest = owned_stable_digest,
        .experimental_digest = owned_experimental_digest,
        .stable_file_count = generated.stable.file_count,
        .stable_byte_count = generated.stable.byte_count,
        .experimental_file_count = generated.experimental.file_count,
        .experimental_byte_count = generated.experimental.byte_count,
        .version = version,
        .executable = identity.*,
        .hit = false,
        ._lock_io = io,
        ._lock_file = lock,
    };
}

fn stageSchemaCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    staging: StagingPaths,
    identity: *ExecutableIdentity,
    version: CodexVersion,
    contract_id: []const u8,
    limits: CacheLimits,
) !GeneratedBundles {
    try generateBundle(allocator, io, identity.resolved_path, staging.stable, false, limits);
    try requireIdentityUnchanged(allocator, io, identity, limits.binary_bytes);
    try generateBundle(allocator, io, identity.resolved_path, staging.experimental, true, limits);
    try requireIdentityUnchanged(allocator, io, identity, limits.binary_bytes);
    var final_version = try readCodexVersion(allocator, io, identity.resolved_path, limits);
    defer final_version.deinit(allocator);
    if (!versionsEqual(version, final_version)) return error.ExecutableChanged;
    try requireIdentityUnchanged(allocator, io, identity, limits.binary_bytes);

    var stable = try digestBundle(allocator, io, staging.stable, limits);
    errdefer stable.deinit(allocator);
    var experimental = try digestBundle(allocator, io, staging.experimental, limits);
    errdefer experimental.deinit(allocator);
    const manifest = try manifestAlloc(
        allocator,
        identity,
        version,
        contract_id,
        stable,
        experimental,
    );
    defer allocator.free(manifest);
    if (manifest.len > max_manifest_bytes) return error.ManifestTooLarge;
    const manifest_path = try std.fs.path.join(allocator, &.{ staging.root, "preflight.json" });
    defer allocator.free(manifest_path);
    try writeSyncedFile(io, manifest_path, manifest);
    try syncDirectory(io, staging.stable);
    try syncDirectory(io, staging.experimental);
    try syncDirectory(io, staging.root);
    return .{ .stable = stable, .experimental = experimental };
}

pub fn defaultCacheRootAlloc(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) ![]u8 {
    if (environment.get("XDG_CACHE_HOME")) |xdg| {
        if (xdg.len != 0 and std.fs.path.isAbsolute(xdg))
            return std.fs.path.join(allocator, &.{ xdg, "cas", "app-server-schema" });
    }
    const home = environment.get("HOME") orelse return error.HomeNotSet;
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.InvalidHome;
    return std.fs.path.join(allocator, &.{ home, ".cache", "cas", "app-server-schema" });
}

fn absoluteCacheRootAlloc(allocator: std.mem.Allocator, io: std.Io, raw: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(raw)) return std.fs.path.resolve(allocator, &.{raw});
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, raw });
}

fn parseCodexVersion(allocator: std.mem.Allocator, raw: []const u8) !CodexVersion {
    if (raw.len == 0 or raw[raw.len - 1] != '\n' or std.mem.countScalar(u8, raw, '\n') != 1 or
        std.mem.indexOfScalar(u8, raw, '\r') != null)
        return error.InvalidCodexVersion;
    const banner = raw[0 .. raw.len - 1];
    const prefix = "codex-cli ";
    if (!std.mem.startsWith(u8, banner, prefix)) return error.InvalidCodexVersion;
    const semver = banner[prefix.len..];
    if (semver.len == 0 or std.mem.indexOfScalar(u8, semver, ' ') != null or
        std.mem.indexOfScalar(u8, semver, '\t') != null)
        return error.InvalidCodexVersion;

    const plus = std.mem.indexOfScalar(u8, semver, '+');
    const without_build = if (plus) |index| semver[0..index] else semver;
    const dash = std.mem.indexOfScalar(u8, without_build, '-');
    const core = if (dash) |index| without_build[0..index] else without_build;
    const pre_slice = if (dash) |index| without_build[index + 1 ..] else null;
    const build_slice = if (plus) |index| semver[index + 1 ..] else null;
    if ((pre_slice != null and !validSemverIdentifiers(pre_slice.?)) or
        (build_slice != null and !validSemverIdentifiers(build_slice.?)))
        return error.InvalidCodexVersion;
    var parts = std.mem.splitScalar(u8, core, '.');
    const major_text = parts.next() orelse return error.InvalidCodexVersion;
    const minor_text = parts.next() orelse return error.InvalidCodexVersion;
    const patch_text = parts.next() orelse return error.InvalidCodexVersion;
    if (parts.next() != null or
        !validCoreNumber(major_text) or
        !validCoreNumber(minor_text) or
        !validCoreNumber(patch_text))
        return error.InvalidCodexVersion;

    const owned_text = try allocator.dupe(u8, semver);
    errdefer allocator.free(owned_text);
    const pre = if (dash) |index| owned_text[index + 1 .. (plus orelse semver.len)] else null;
    const build = if (plus) |index| owned_text[index + 1 ..] else null;
    return .{
        .major = std.fmt.parseUnsigned(u64, major_text, 10) catch return error.InvalidCodexVersion,
        .minor = std.fmt.parseUnsigned(u64, minor_text, 10) catch return error.InvalidCodexVersion,
        .patch = std.fmt.parseUnsigned(u64, patch_text, 10) catch return error.InvalidCodexVersion,
        .text = owned_text,
        .banner = try allocator.dupe(u8, banner),
        .pre = pre,
        .build = build,
    };
}

fn validCoreNumber(text: []const u8) bool {
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return false;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validSemverIdentifiers(text: []const u8) bool {
    if (text.len == 0) return false;
    var parts = std.mem.splitScalar(u8, text, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    }
    return true;
}

fn readCodexVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    limits: CacheLimits,
) !CodexVersion {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ executable, "--version" },
        .stdout_limit = .limited(limits.version_stdout_bytes),
        .stderr_limit = .limited(limits.version_stderr_bytes),
        .timeout = .{ .deadline = awakeDeadline(io, limits.version_timeout_ms) },
    }) catch |err| return mapProcessError(err);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!termSucceeded(result.term)) return error.CodexVersionFailed;
    return parseCodexVersion(allocator, result.stdout);
}

fn generateBundle(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    output: []const u8,
    experimental: bool,
    limits: CacheLimits,
) !void {
    const argv: []const []const u8 = if (experimental)
        &.{ executable, "app-server", "generate-json-schema", "--experimental", "--out", output }
    else
        &.{ executable, "app-server", "generate-json-schema", "--out", output };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(limits.generator_stdout_bytes),
        .stderr_limit = .limited(limits.generator_stderr_bytes),
        .timeout = .{ .deadline = awakeDeadline(io, limits.generator_timeout_ms) },
    }) catch |err| return mapProcessError(err);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!termSucceeded(result.term)) return error.SchemaGenerationFailed;
}

fn mapProcessError(err: anyerror) anyerror {
    return switch (err) {
        error.Timeout => error.ProcessTimedOut,
        error.StreamTooLong => error.ProcessOutputTooLarge,
        else => err,
    };
}

fn awakeDeadline(io: std.Io, milliseconds: u64) std.Io.Clock.Timestamp {
    return .fromNow(io, .{
        .raw = .fromMilliseconds(@intCast(milliseconds)),
        .clock = .awake,
    });
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn versionsEqual(left: CodexVersion, right: CodexVersion) bool {
    return std.mem.eql(u8, left.text, right.text) and std.mem.eql(u8, left.banner, right.banner);
}

fn resolveExecutableIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    explicit_path: ?[]const u8,
    binary_limit: u64,
) !ExecutableIdentity {
    const candidate = if (explicit_path) |path|
        try allocator.dupe(u8, path)
    else
        try findOnPath(allocator, io, "codex");
    defer allocator.free(candidate);
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, candidate, allocator);
    errdefer allocator.free(resolved);
    var file = try std.Io.Dir.openFileAbsolute(io, resolved, .{
        .follow_symlinks = false,
        .allow_directory = false,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidCodexExecutable;
    if (!hasExecutablePermission(stat.permissions)) return error.InvalidCodexExecutable;
    if (stat.size > binary_limit) return error.CodexBinaryTooLarge;
    const binary_digest = try fileDigestAlloc(allocator, io, file, binary_limit);
    errdefer allocator.free(binary_digest);
    return .{
        .resolved_path = resolved,
        .path_fingerprint = try digestAlloc(allocator, resolved),
        .binary_digest = binary_digest,
        .inode = @intCast(stat.inode),
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
        .ctime_ns = stat.ctime.nanoseconds,
    };
}

fn findOnPath(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    const path_value = std.Io.Threaded.global_single_threaded.environString("PATH") orelse
        return error.CodexNotFound;
    var components = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (components.next()) |component| {
        const directory = if (component.len == 0) "." else component;
        const candidate = try std.fs.path.join(allocator, &.{ directory, name });
        var file = std.Io.Dir.cwd().openFile(io, candidate, .{ .allow_directory = false }) catch {
            allocator.free(candidate);
            continue;
        };
        defer file.close(io);
        const stat = file.stat(io) catch {
            allocator.free(candidate);
            continue;
        };
        if (stat.kind != .file or !hasExecutablePermission(stat.permissions)) {
            allocator.free(candidate);
            continue;
        }
        return candidate;
    }
    return error.CodexNotFound;
}

fn hasExecutablePermission(permissions: std.Io.File.Permissions) bool {
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        return permissions.toMode() & 0o111 != 0;
    }
    return true;
}

fn requireIdentityUnchanged(
    allocator: std.mem.Allocator,
    io: std.Io,
    expected: *const ExecutableIdentity,
    binary_limit: u64,
) !void {
    var actual = try resolveExecutableIdentity(allocator, io, expected.resolved_path, binary_limit);
    defer actual.deinit(allocator);
    if (!identitiesEqual(expected.*, actual)) return error.ExecutableChanged;
}

pub fn verifyExecutableIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    expected: *const ExecutableIdentity,
) !void {
    return requireIdentityUnchanged(allocator, io, expected, max_binary_bytes);
}

fn identitiesEqual(left: ExecutableIdentity, right: ExecutableIdentity) bool {
    return std.mem.eql(u8, left.resolved_path, right.resolved_path) and
        std.mem.eql(u8, left.path_fingerprint, right.path_fingerprint) and
        std.mem.eql(u8, left.binary_digest, right.binary_digest) and
        left.inode == right.inode and left.size == right.size and
        left.mtime_ns == right.mtime_ns and left.ctime_ns == right.ctime_ns;
}

fn fileDigestAlloc(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, limit: u64) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    var total: u64 = 0;
    while (true) { // tiger: event-loop
        const slice = reader.interface.peek(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        total = std.math.add(u64, total, slice.len) catch return error.CodexBinaryTooLarge;
        if (total > limit) return error.CodexBinaryTooLarge;
        hasher.update(slice);
        reader.interface.toss(slice.len);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digestBytesAlloc(allocator, &digest);
}

fn digestAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digestBytesAlloc(allocator, &digest);
}

fn digestBytesAlloc(allocator: std.mem.Allocator, digest: *const [32]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "sha256:{x}", .{digest.*});
}

fn acquireCacheLock(io: std.Io, path: []const u8, limits: CacheLimits) !std.Io.File {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    errdefer file.close(io);
    const deadline = awakeDeadline(io, limits.lock_timeout_ms);
    while (!(try file.tryLock(io, .exclusive))) {
        if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.CacheLockTimedOut;
        std.Io.sleep(
            io,
            .fromMilliseconds(@intCast(limits.lock_retry_ms)),
            .awake,
        ) catch |err| ignoreError(err);
    }
    return file;
}

const BundleFile = struct {
    path: []u8,
    digest: [32]u8,
};

fn digestBundle(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    limits: CacheLimits,
) !BundleDigest {
    var root = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walk(allocator);
    defer walker.deinit();
    var files: std.ArrayList(BundleFile) = .empty;
    defer {
        for (files.items) |file| allocator.free(file.path);
        files.deinit(allocator);
    }
    var total_bytes: u64 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.path.len > limits.bundle_path_bytes) return error.BundlePathTooLong;
        switch (entry.kind) {
            .directory => {},
            .file => try appendBundleFile(allocator, io, entry, limits, &files, &total_bytes),
            else => return error.InvalidBundleEntry,
        }
    }
    if (files.items.len == 0) return error.EmptyBundle;
    std.mem.sort(BundleFile, files.items, {}, struct {
        fn lessThan(_: void, left: BundleFile, right: BundleFile) bool {
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.lessThan);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("cas-app-server-schema-bundle/v1\x00");
    for (files.items) |file| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, file.path.len, .big);
        hasher.update(&length);
        hasher.update(file.path);
        std.mem.writeInt(u64, &length, file.digest.len, .big);
        hasher.update(&length);
        hasher.update(&file.digest);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{
        .digest = try digestBytesAlloc(allocator, &digest),
        .file_count = files.items.len,
        .byte_count = total_bytes,
    };
}

fn appendBundleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    entry: std.Io.Dir.Walker.Entry,
    limits: CacheLimits,
    files: *std.ArrayList(BundleFile),
    total_bytes: *u64,
) !void {
    if (!std.mem.endsWith(u8, entry.path, ".json")) return error.InvalidBundleEntry;
    if (files.items.len == limits.bundle_documents) return error.BundleTooManyFiles;
    var file = try entry.dir.openFile(io, entry.basename, .{
        .follow_symlinks = false,
        .allow_directory = false,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidBundleEntry;
    if (stat.size > limits.bundle_file_bytes) return error.BundleFileTooLarge;
    total_bytes.* = std.math.add(u64, total_bytes.*, stat.size) catch
        return error.BundleTooLarge;
    if (total_bytes.* > limits.bundle_total_bytes) return error.BundleTooLarge;
    const raw = try readFileBounded(allocator, io, file, @intCast(limits.bundle_file_bytes));
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return error.InvalidBundleJson;
    defer parsed.deinit();
    const canonical = try definition_core.canonical_json.canonicalJsonAlloc(
        allocator,
        parsed.value,
    );
    defer allocator.free(canonical);
    var canonical_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &canonical_digest, .{});
    const owned_path = try allocator.dupe(u8, entry.path);
    errdefer allocator.free(owned_path);
    try files.append(allocator, .{ .path = owned_path, .digest = canonical_digest });
}

fn readFileBounded(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    limit: usize,
) ![]u8 {
    const stat = try file.stat(io);
    if (stat.size > limit) return error.FileTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(bytes);
    const read = try file.readPositionalAll(io, bytes, 0);
    if (read != bytes.len) return error.UnexpectedEndOfFile;
    return bytes;
}

fn validateCacheHit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    identity: *const ExecutableIdentity,
    version: CodexVersion,
    contract_id: []const u8,
    limits: CacheLimits,
) !?ManifestView {
    const manifest_path = try std.fs.path.join(allocator, &.{ cache_path, "preflight.json" });
    defer allocator.free(manifest_path);
    var file = std.Io.Dir.openFileAbsolute(io, manifest_path, .{
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch return null;
    defer file.close(io);
    const raw = readFileBounded(allocator, io, file, max_manifest_bytes) catch return null;
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    if (!manifestIdentityMatches(parsed.value, identity, version, contract_id)) return null;
    const stable_path = try std.fs.path.join(allocator, &.{ cache_path, "stable" });
    defer allocator.free(stable_path);
    const experimental_path = try std.fs.path.join(allocator, &.{ cache_path, "experimental" });
    defer allocator.free(experimental_path);
    var stable = digestBundle(allocator, io, stable_path, limits) catch return null;
    defer stable.deinit(allocator);
    var experimental = digestBundle(allocator, io, experimental_path, limits) catch return null;
    defer experimental.deinit(allocator);
    const stable_object = objectField(parsed.value, "stable") catch return null;
    const experimental_object = objectField(parsed.value, "experimental") catch return null;
    const manifest_stable_digest = stringField(stable_object, "digest") catch return null;
    const manifest_experimental_digest = stringField(
        experimental_object,
        "digest",
    ) catch return null;
    const stable_files = decimalUsizeField(stable_object, "fileCount") catch return null;
    const stable_bytes = decimalU64Field(stable_object, "byteCount") catch return null;
    const experimental_files = decimalUsizeField(
        experimental_object,
        "fileCount",
    ) catch return null;
    const experimental_bytes = decimalU64Field(experimental_object, "byteCount") catch return null;
    if (!std.mem.eql(u8, manifest_stable_digest, stable.digest) or
        !std.mem.eql(u8, manifest_experimental_digest, experimental.digest) or
        stable_files != stable.file_count or stable_bytes != stable.byte_count or
        experimental_files != experimental.file_count or
        experimental_bytes != experimental.byte_count)
        return null;
    const owned_stable_digest = try allocator.dupe(u8, stable.digest);
    errdefer allocator.free(owned_stable_digest);
    const owned_experimental_digest = try allocator.dupe(u8, experimental.digest);
    return .{
        .stable_digest = owned_stable_digest,
        .stable_file_count = stable.file_count,
        .stable_byte_count = stable.byte_count,
        .experimental_digest = owned_experimental_digest,
        .experimental_file_count = experimental.file_count,
        .experimental_byte_count = experimental.byte_count,
    };
}

fn manifestIdentityMatches(
    root: std.json.Value,
    identity: *const ExecutableIdentity,
    version: CodexVersion,
    contract_id: []const u8,
) bool {
    return std.mem.eql(u8, stringField(root, "schema") catch return false, cache_schema) and
        std.mem.eql(u8, stringField(root, "contractId") catch return false, contract_id) and
        std.mem.eql(
            u8,
            stringField(root, "resolvedPath") catch return false,
            identity.resolved_path,
        ) and
        std.mem.eql(
            u8,
            stringField(root, "pathFingerprint") catch return false,
            identity.path_fingerprint,
        ) and
        std.mem.eql(u8, stringField(root, "version") catch return false, version.text) and
        std.mem.eql(u8, stringField(root, "banner") catch return false, version.banner) and
        (boolField(root, "prerelease") catch return false) == version.prerelease() and
        std.mem.eql(
            u8,
            stringField(root, "binaryDigest") catch return false,
            identity.binary_digest,
        ) and
        (decimalU64Field(root, "inode") catch return false) == identity.inode and
        (decimalU64Field(root, "size") catch return false) == identity.size and
        (decimalI128Field(root, "mtimeNs") catch return false) == identity.mtime_ns and
        (decimalI128Field(root, "ctimeNs") catch return false) == identity.ctime_ns;
}

fn decimalU64Field(value: std.json.Value, name: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, try stringField(value, name), 10);
}
fn decimalUsizeField(value: std.json.Value, name: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, try stringField(value, name), 10);
}
fn decimalI128Field(value: std.json.Value, name: []const u8) !i128 {
    return std.fmt.parseInt(i128, try stringField(value, name), 10);
}

fn manifestAlloc(
    allocator: std.mem.Allocator,
    identity: *const ExecutableIdentity,
    version: CodexVersion,
    contract_id: []const u8,
    stable: BundleDigest,
    experimental: BundleDigest,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeByte('{');
    try manifestStringField(writer, "schema", cache_schema, false);
    try manifestStringField(writer, "contractId", contract_id, true);
    try manifestStringField(writer, "resolvedPath", identity.resolved_path, true);
    try manifestStringField(writer, "pathFingerprint", identity.path_fingerprint, true);
    try manifestStringField(writer, "version", version.text, true);
    try manifestStringField(writer, "banner", version.banner, true);
    try writer.print(",\"prerelease\":{}", .{version.prerelease()});
    try manifestStringField(writer, "binaryDigest", identity.binary_digest, true);
    try manifestDecimalField(writer, "inode", identity.inode);
    try manifestDecimalField(writer, "size", identity.size);
    try manifestDecimalField(writer, "mtimeNs", identity.mtime_ns);
    try manifestDecimalField(writer, "ctimeNs", identity.ctime_ns);
    try writer.writeAll(",\"stable\":{");
    try manifestStringField(writer, "digest", stable.digest, false);
    try manifestDecimalField(writer, "fileCount", stable.file_count);
    try manifestDecimalField(writer, "byteCount", stable.byte_count);
    try writer.writeAll("},\"experimental\":{");
    try manifestStringField(writer, "digest", experimental.digest, false);
    try manifestDecimalField(writer, "fileCount", experimental.file_count);
    try manifestDecimalField(writer, "byteCount", experimental.byte_count);
    try writer.writeAll("}}\n");
    return output.toOwnedSlice();
}

fn manifestStringField(
    writer: *std.Io.Writer,
    name: []const u8,
    value: []const u8,
    comma: bool,
) !void {
    if (comma) try writer.writeByte(',');
    try definition_core.canonical_json.writeCanonicalString(writer, name);
    try writer.writeByte(':');
    try definition_core.canonical_json.writeCanonicalString(writer, value);
}

fn manifestDecimalField(writer: *std.Io.Writer, name: []const u8, value: anytype) !void {
    try writer.writeByte(',');
    try definition_core.canonical_json.writeCanonicalString(writer, name);
    try writer.writeAll(":\"");
    try writer.print("{d}", .{value});
    try writer.writeByte('"');
}

fn writeSyncedFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

fn syncDirectory(io: std.Io, path: []const u8) !void {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = true });
    defer file.close(io);
    try file.sync(io);
}

fn promoteCacheDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    staging: []const u8,
    target: []const u8,
    nonce: i128,
) !void {
    const backup = try std.fmt.allocPrint(allocator, "{s}.rollback.{d}", .{ target, nonce });
    defer allocator.free(backup);
    try std.Io.Dir.cwd().deleteTree(io, backup);
    var had_target = true;
    std.Io.Dir.renameAbsolute(target, backup, io) catch |err| switch (err) {
        error.FileNotFound => had_target = false,
        else => return err,
    };
    std.Io.Dir.renameAbsolute(staging, target, io) catch |err| {
        if (had_target) {
            std.Io.Dir.renameAbsolute(backup, target, io) catch |restore_err|
                ignoreError(restore_err);
        }
        return err;
    };
    const parent = std.fs.path.dirname(target) orelse return error.InvalidCachePath;
    syncDirectory(io, parent) catch |err| {
        std.Io.Dir.cwd().deleteTree(io, target) catch |delete_err| ignoreError(delete_err);
        if (had_target) {
            std.Io.Dir.renameAbsolute(backup, target, io) catch |restore_err|
                ignoreError(restore_err);
        }
        return err;
    };
    if (had_target) {
        std.Io.Dir.cwd().deleteTree(io, backup) catch |err| ignoreError(err);
    }
}

fn ignoreError(err: anyerror) void {
    _ = @errorName(err);
}

pub const Profile = enum { core, review, session_inquiry, full };
pub const Status = enum { compatible, incompatible };

pub const ProbeTransport = enum {
    stdio,
    managed_websocket,
    explicit_websocket,
    unix_websocket,
};

pub const ProbeSelection = struct {
    transport: ProbeTransport = .stdio,
    code_mode_host: bool = false,
};

pub const ProbeRequirement = enum { required, not_applicable };

pub const BehavioralProbeDescriptor = struct {
    id: []const u8,
    common: bool = false,
    core: bool = false,
    review: bool = false,
    session_inquiry: bool = false,
    full: bool = false,
    transport: ?ProbeTransport = null,
    code_mode_host: bool = false,
};

pub const behavioral_probe_descriptors = [_]BehavioralProbeDescriptor{
    .{ .id = "initialize-lifecycle", .common = true },
    .{ .id = "stdio-transport", .transport = .stdio },
    .{ .id = "managed-websocket-transport", .transport = .managed_websocket },
    .{ .id = "explicit-websocket-transport", .transport = .explicit_websocket },
    .{ .id = "unix-websocket-transport", .transport = .unix_websocket },
    .{ .id = "remote-code-mode-host", .code_mode_host = true },
    .{ .id = "server-request-coverage", .common = true },
    .{ .id = "thread-pinning-round-trip", .full = true },
    .{ .id = "paginated-fork", .session_inquiry = true, .full = true },
    .{ .id = "ephemeral-fork", .session_inquiry = true, .full = true },
    .{ .id = "executor-skill-resources", .full = true },
    .{ .id = "external-import-history", .full = true },
    .{ .id = "bounded-overload-retry", .common = true },
    .{ .id = "structured-review", .review = true, .full = true },
    .{ .id = "paginated-session-inquiry", .session_inquiry = true, .full = true },
};

pub fn behavioralProbeDescriptor(id: []const u8) ?BehavioralProbeDescriptor {
    for (behavioral_probe_descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.id, id)) return descriptor;
    }
    return null;
}

pub fn probeRequirement(
    profile: Profile,
    selection: ProbeSelection,
    id: []const u8,
) ?ProbeRequirement {
    const descriptor = behavioralProbeDescriptor(id) orelse return null;
    if (descriptor.transport) |transport| {
        return if (transport == selection.transport) .required else .not_applicable;
    }
    if (descriptor.code_mode_host) {
        return if (selection.code_mode_host) .required else .not_applicable;
    }
    if (descriptor.common) return .required;
    const applies = switch (profile) {
        .core => descriptor.core,
        .review => descriptor.review,
        .session_inquiry => descriptor.session_inquiry,
        .full => descriptor.full,
    };
    return if (applies) .required else .not_applicable;
}

pub const Document = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const SchemaBundle = struct {
    documents: []const Document,
};

/// A protocol PathUri is an opaque canonical `file:` URI. Parsing validates
/// only the wire boundary; filesystem identity and native-path conversion are
/// deliberately owned by later host-I/O boundaries.
pub const PathUri = struct {
    raw: []const u8,

    pub fn parse(raw: []const u8) !PathUri {
        if (!std.mem.startsWith(u8, raw, "file:") or raw.len == "file:".len)
            return error.InvalidPathUri;
        for (raw) |byte| if (byte <= 0x20 or byte == 0x7f) return error.InvalidPathUri;
        return .{ .raw = raw };
    }
};

pub const required_schema_documents = [_][]const u8{
    "ClientRequest.json",
    "ServerRequest.json",
    "ServerNotification.json",
    "codex_app_server_protocol.v2.schemas.json",
};

pub const OwnedSchemaBundle = struct {
    documents: [required_schema_documents.len]Document,
    contents: [required_schema_documents.len][]u8,

    pub fn view(self: *const OwnedSchemaBundle) SchemaBundle {
        return .{ .documents = &self.documents };
    }

    pub fn deinit(self: *OwnedSchemaBundle, allocator: std.mem.Allocator) void {
        for (self.contents) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

pub fn loadRequiredSchemaBundle(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
) !OwnedSchemaBundle {
    if (!std.fs.path.isAbsolute(root_path)) return error.SchemaRootNotAbsolute;
    var root = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = false });
    defer root.close(io);
    var contents: [required_schema_documents.len][]u8 = undefined;
    var loaded: usize = 0;
    errdefer for (contents[0..loaded]) |bytes| allocator.free(bytes);
    for (required_schema_documents, 0..) |name, index| {
        var file = try root.openFile(io, name, .{
            .follow_symlinks = false,
            .allow_directory = false,
        });
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.InvalidSchemaDocument;
        if (stat.size > max_document_bytes) return error.SchemaTooLarge;
        contents[index] = try readFileBounded(allocator, io, file, max_document_bytes);
        loaded += 1;
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            contents[index],
            .{},
        ) catch return error.InvalidBundleJson;
        parsed.deinit();
    }
    var documents: [required_schema_documents.len]Document = undefined;
    for (required_schema_documents, 0..) |name, index| {
        documents[index] = .{ .name = name, .bytes = contents[index] };
    }
    return .{ .documents = documents, .contents = contents };
}

pub const InspectionReport = struct {
    status: Status = .compatible,
    missing_required: std.ArrayList([]u8) = .empty,
    additive_client_methods: std.ArrayList([]u8) = .empty,
    additive_server_requests: std.ArrayList([]u8) = .empty,
    unclassified_server_requests: std.ArrayList([]u8) = .empty,
    additive_notifications: std.ArrayList([]u8) = .empty,
    shape_failures: std.ArrayList([]u8) = .empty,
    handler_failures: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *InspectionReport, allocator: std.mem.Allocator) void {
        deinitStrings(&self.missing_required, allocator);
        deinitStrings(&self.additive_client_methods, allocator);
        deinitStrings(&self.additive_server_requests, allocator);
        deinitStrings(&self.unclassified_server_requests, allocator);
        deinitStrings(&self.additive_notifications, allocator);
        deinitStrings(&self.shape_failures, allocator);
        deinitStrings(&self.handler_failures, allocator);
    }
};

pub fn parseBaseline(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, baseline_json, .{});
    errdefer parsed.deinit();
    try validateBaseline(parsed.value);
    return parsed;
}

pub fn inspect(
    allocator: std.mem.Allocator,
    baseline: *const std.json.Value,
    stable: SchemaBundle,
    experimental: SchemaBundle,
    profile: Profile,
) !InspectionReport {
    var report: InspectionReport = .{};
    errdefer report.deinit(allocator);

    const stable_contract = try objectField(baseline.*, "stable");
    const experimental_contract = try objectField(baseline.*, "experimental");
    var methods = try InspectionMethods.init(allocator, stable, experimental);
    defer methods.deinit(allocator);
    const required = try RequiredMethods.init(stable_contract, experimental_contract);
    try inspectRequiredMethods(allocator, required, &methods, profile, &report);
    try inspectAdditiveMethods(allocator, required, &methods, &report);
    const policies = try objectField(baseline.*, "serverRequestPolicies");
    try inspectServerPolicies(allocator, required, &methods, policies, &report);
    try inspectShapesForProfile(
        allocator,
        stable_contract,
        experimental_contract,
        stable,
        experimental,
        profile,
        &report,
    );
    if (inspectionFailed(report, profile)) report.status = .incompatible;
    return report;
}

fn validateBaseline(root: std.json.Value) !void {
    try validateBaselineHeader(root);
    const stable = try objectField(root, "stable");
    const experimental = try objectField(root, "experimental");
    try validateBaselineMethodSets(stable, experimental);
    const policies = try objectField(root, "serverRequestPolicies");
    try validateBaselinePolicies(stable, policies);
    try validateHandlerParity(policies);
    const probes = try arrayField(root, "behavioralProbes");
    try validateStringArray(probes);
    try validateProbeParity(probes);
}

fn validateBaselineHeader(root: std.json.Value) !void {
    const object = switch (root) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    const keys = [_][]const u8{
        "schema",
        "contractId",
        "stable",
        "experimental",
        "serverRequestPolicies",
        "behavioralProbes",
    };
    if (object.count() != keys.len) return error.InvalidContract;
    for (keys) |key| if (!object.contains(key)) return error.InvalidContract;
    if (!std.mem.eql(
        u8,
        try stringField(root, "schema"),
        "cas-app-server-contract/v1",
    )) return error.InvalidContract;
    if (!std.mem.eql(
        u8,
        try stringField(root, "contractId"),
        app_server_contract_id,
    )) return error.InvalidContract;
}

fn validateBaselineMethodSets(
    stable: std.json.Value,
    experimental: std.json.Value,
) !void {
    if ((try arrayField(stable, "requiredClientMethods")).items.len != 90) {
        return error.InvalidContract;
    }
    if ((try arrayField(stable, "requiredServerRequests")).items.len != 10) {
        return error.InvalidContract;
    }
    if ((try arrayField(stable, "requiredNotifications")).items.len != 70) {
        return error.InvalidContract;
    }
    if ((try arrayField(experimental, "requiredClientMethods")).items.len != 127) {
        return error.InvalidContract;
    }
    if ((try arrayField(stable, "requiredShapes")).items.len > max_shapes) {
        return error.ContractTooLarge;
    }
    if ((try arrayField(experimental, "requiredShapes")).items.len > max_shapes) {
        return error.ContractTooLarge;
    }
    try validateStringArray(try arrayField(stable, "requiredClientMethods"));
    try validateStringArray(try arrayField(stable, "requiredServerRequests"));
    try validateStringArray(try arrayField(stable, "requiredNotifications"));
    try validateStringArray(try arrayField(experimental, "requiredClientMethods"));
    try validateShapeProfiles(try arrayField(stable, "requiredShapes"));
    try validateShapeProfiles(try arrayField(experimental, "requiredShapes"));
}

fn validateShapeProfiles(shapes: std.json.Array) !void {
    for (shapes.items) |shape| {
        const object = switch (shape) {
            .object => |value| value,
            else => return error.InvalidContract,
        };
        const profiles_value = object.get("profiles") orelse continue;
        const profiles = switch (profiles_value) {
            .array => |value| value,
            else => return error.InvalidContract,
        };
        if (profiles.items.len == 0) return error.InvalidContract;
        for (profiles.items) |profile_value| {
            const name = switch (profile_value) {
                .string => |value| value,
                else => return error.InvalidContract,
            };
            if (profileFromName(name) == null) return error.InvalidContract;
        }
    }
}

fn validateBaselinePolicies(stable: std.json.Value, policies: std.json.Value) !void {
    for ((try arrayField(stable, "requiredServerRequests")).items) |item| {
        const method = switch (item) {
            .string => |value| value,
            else => return error.InvalidContract,
        };
        if (switch (policies) {
            .object => |value| !value.contains(method),
            else => true,
        }) return error.InvalidContract;
    }
    const policy_object = switch (policies) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    if (policy_object.count() != proxy_client.server_request_handler_descriptors.len) {
        return error.InvalidContract;
    }
    var policy_iterator = policy_object.iterator();
    while (policy_iterator.next()) |entry| {
        const policy = switch (entry.value_ptr.*) {
            .string => |value| value,
            else => return error.InvalidContract,
        };
        if (std.mem.trim(u8, policy, " \t\r\n").len == 0) return error.InvalidContract;
    }
}

const MethodSet = struct {
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *MethodSet, allocator: std.mem.Allocator) void {
        deinitStrings(&self.items, allocator);
    }
};

const RequiredMethods = struct {
    stable_clients: std.json.Array,
    stable_servers: std.json.Array,
    notifications: std.json.Array,
    experimental_clients: std.json.Array,

    fn init(
        stable_contract: std.json.Value,
        experimental_contract: std.json.Value,
    ) !RequiredMethods {
        return .{
            .stable_clients = try arrayField(stable_contract, "requiredClientMethods"),
            .stable_servers = try arrayField(stable_contract, "requiredServerRequests"),
            .notifications = try arrayField(stable_contract, "requiredNotifications"),
            .experimental_clients = try arrayField(
                experimental_contract,
                "requiredClientMethods",
            ),
        };
    }
};

const InspectionMethods = struct {
    stable_clients: MethodSet,
    stable_servers: MethodSet,
    stable_notifications: MethodSet,
    experimental_clients: MethodSet,
    experimental_servers: MethodSet,
    experimental_notifications: MethodSet,

    fn init(
        allocator: std.mem.Allocator,
        stable: SchemaBundle,
        experimental: SchemaBundle,
    ) !InspectionMethods {
        var stable_clients = try collectMethods(
            allocator,
            try documentBytes(stable, "ClientRequest.json"),
        );
        errdefer stable_clients.deinit(allocator);
        var stable_servers = try collectMethods(
            allocator,
            try documentBytes(stable, "ServerRequest.json"),
        );
        errdefer stable_servers.deinit(allocator);
        var stable_notifications = try collectMethods(
            allocator,
            try documentBytes(stable, "ServerNotification.json"),
        );
        errdefer stable_notifications.deinit(allocator);
        var experimental_clients = try collectMethods(
            allocator,
            try documentBytes(experimental, "ClientRequest.json"),
        );
        errdefer experimental_clients.deinit(allocator);
        var experimental_servers = try collectMethods(
            allocator,
            try documentBytes(experimental, "ServerRequest.json"),
        );
        errdefer experimental_servers.deinit(allocator);
        var experimental_notifications = try collectMethods(
            allocator,
            try documentBytes(experimental, "ServerNotification.json"),
        );
        errdefer experimental_notifications.deinit(allocator);
        return .{
            .stable_clients = stable_clients,
            .stable_servers = stable_servers,
            .stable_notifications = stable_notifications,
            .experimental_clients = experimental_clients,
            .experimental_servers = experimental_servers,
            .experimental_notifications = experimental_notifications,
        };
    }

    fn deinit(self: *InspectionMethods, allocator: std.mem.Allocator) void {
        self.experimental_notifications.deinit(allocator);
        self.experimental_servers.deinit(allocator);
        self.experimental_clients.deinit(allocator);
        self.stable_notifications.deinit(allocator);
        self.stable_servers.deinit(allocator);
        self.stable_clients.deinit(allocator);
    }
};

fn inspectRequiredMethods(
    allocator: std.mem.Allocator,
    required: RequiredMethods,
    methods: *const InspectionMethods,
    profile: Profile,
    report: *InspectionReport,
) !void {
    const Comparison = struct { required: std.json.Array, actual: []const []u8 };
    const comparisons = [_]Comparison{
        .{ .required = required.stable_clients, .actual = methods.stable_clients.items.items },
        .{
            .required = required.stable_clients,
            .actual = methods.experimental_clients.items.items,
        },
        .{ .required = required.stable_servers, .actual = methods.stable_servers.items.items },
        .{
            .required = required.stable_servers,
            .actual = methods.experimental_servers.items.items,
        },
        .{ .required = required.notifications, .actual = methods.stable_notifications.items.items },
        .{
            .required = required.notifications,
            .actual = methods.experimental_notifications.items.items,
        },
    };
    for (comparisons) |comparison| {
        try compareRequired(
            allocator,
            comparison.required,
            comparison.actual,
            &report.missing_required,
        );
    }
    switch (profile) {
        .core, .review => {},
        .session_inquiry => {
            try requireMethod(
                allocator,
                required.experimental_clients,
                methods.experimental_clients.items.items,
                "thread/turns/list",
                &report.missing_required,
            );
            try requireMethod(
                allocator,
                required.experimental_clients,
                methods.experimental_clients.items.items,
                "thread/items/list",
                &report.missing_required,
            );
        },
        .full => try compareRequired(
            allocator,
            required.experimental_clients,
            methods.experimental_clients.items.items,
            &report.missing_required,
        ),
    }
}

fn inspectAdditiveMethods(
    allocator: std.mem.Allocator,
    required: RequiredMethods,
    methods: *const InspectionMethods,
    report: *InspectionReport,
) !void {
    try collectAdditive(
        allocator,
        methods.stable_clients.items.items,
        required.stable_clients,
        &report.additive_client_methods,
    );
    try collectAdditive(
        allocator,
        methods.experimental_clients.items.items,
        required.experimental_clients,
        &report.additive_client_methods,
    );
    try collectAdditive(
        allocator,
        methods.stable_notifications.items.items,
        required.notifications,
        &report.additive_notifications,
    );
    try collectAdditive(
        allocator,
        methods.experimental_notifications.items.items,
        required.notifications,
        &report.additive_notifications,
    );
}

fn inspectServerPolicies(
    allocator: std.mem.Allocator,
    required: RequiredMethods,
    methods: *const InspectionMethods,
    policies: std.json.Value,
    report: *InspectionReport,
) !void {
    try inspectHandlerParity(allocator, policies, &report.handler_failures);
    try comparePolicyRequired(
        allocator,
        policies,
        methods.experimental_servers.items.items,
        &report.missing_required,
    );
    try classifyServerAdditions(
        allocator,
        methods.stable_servers.items.items,
        required.stable_servers,
        policies,
        report,
    );
    try classifyExperimentalServerAdditions(
        allocator,
        methods.experimental_servers.items.items,
        policies,
        report,
    );
}

fn inspectShapesForProfile(
    allocator: std.mem.Allocator,
    stable_contract: std.json.Value,
    experimental_contract: std.json.Value,
    stable: SchemaBundle,
    experimental: SchemaBundle,
    profile: Profile,
    report: *InspectionReport,
) !void {
    try inspectShapes(
        allocator,
        stable,
        try arrayField(stable_contract, "requiredShapes"),
        profile,
        &report.shape_failures,
    );
    switch (profile) {
        .core, .review => {},
        .session_inquiry, .full => try inspectShapes(
            allocator,
            experimental,
            try arrayField(experimental_contract, "requiredShapes"),
            profile,
            &report.shape_failures,
        ),
    }
}

fn inspectionFailed(report: InspectionReport, profile: Profile) bool {
    return report.missing_required.items.len != 0 or
        report.shape_failures.items.len != 0 or
        report.handler_failures.items.len != 0 or
        (profile == .full and report.unclassified_server_requests.items.len != 0);
}

fn collectMethods(allocator: std.mem.Allocator, raw: []const u8) !MethodSet {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const variants = try arrayField(parsed.value, "oneOf");
    if (variants.items.len > max_methods) return error.SchemaTooLarge;
    var methods: MethodSet = .{};
    errdefer methods.deinit(allocator);
    for (variants.items) |variant| {
        const properties = try objectField(variant, "properties");
        const method_schema = try objectField(properties, "method");
        const values = try arrayField(method_schema, "enum");
        if (values.items.len != 1) return error.InvalidMethodDiscriminator;
        const method = switch (values.items[0]) {
            .string => |value| value,
            else => return error.InvalidMethodDiscriminator,
        };
        if (contains(methods.items.items, method)) return error.DuplicateMethod;
        try methods.items.append(allocator, try allocator.dupe(u8, method));
    }
    return methods;
}

fn compareRequired(
    allocator: std.mem.Allocator,
    required: std.json.Array,
    actual: []const []u8,
    failures: *std.ArrayList([]u8),
) !void {
    for (required.items) |item| {
        const method = switch (item) {
            .string => |value| value,
            else => return error.InvalidContract,
        };
        if (!contains(actual, method)) try appendUnique(allocator, failures, method);
    }
}

fn requireMethod(
    allocator: std.mem.Allocator,
    baseline: std.json.Array,
    actual: []const []u8,
    method: []const u8,
    failures: *std.ArrayList([]u8),
) !void {
    if (!jsonArrayContains(baseline, method)) return error.InvalidContract;
    if (!contains(actual, method)) try appendUnique(allocator, failures, method);
}

fn collectAdditive(
    allocator: std.mem.Allocator,
    actual: []const []u8,
    required: std.json.Array,
    output: *std.ArrayList([]u8),
) !void {
    for (actual) |method| {
        if (!jsonArrayContains(required, method)) {
            try appendUnique(allocator, output, method);
        }
    }
}

fn classifyServerAdditions(
    allocator: std.mem.Allocator,
    actual: []const []u8,
    required: std.json.Array,
    policies: std.json.Value,
    report: *InspectionReport,
) !void {
    const policy_object = switch (policies) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    for (actual) |method| {
        if (jsonArrayContains(required, method)) continue;
        try appendUnique(allocator, &report.additive_server_requests, method);
        if (!policy_object.contains(method)) {
            try appendUnique(allocator, &report.unclassified_server_requests, method);
        }
    }
}

fn classifyExperimentalServerAdditions(
    allocator: std.mem.Allocator,
    actual: []const []u8,
    policies: std.json.Value,
    report: *InspectionReport,
) !void {
    const policy_object = switch (policies) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    for (actual) |method| {
        if (policy_object.contains(method)) continue;
        try appendUnique(allocator, &report.additive_server_requests, method);
        try appendUnique(allocator, &report.unclassified_server_requests, method);
    }
}

fn comparePolicyRequired(
    allocator: std.mem.Allocator,
    policies: std.json.Value,
    actual: []const []u8,
    failures: *std.ArrayList([]u8),
) !void {
    const policy_object = switch (policies) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    var iterator = policy_object.iterator();
    while (iterator.next()) |entry| {
        if (!contains(actual, entry.key_ptr.*)) {
            try appendUnique(allocator, failures, entry.key_ptr.*);
        }
    }
}

fn validateHandlerParity(policies: std.json.Value) !void {
    const policy_object = switch (policies) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    if (policy_object.count() != proxy_client.server_request_handler_descriptors.len) {
        return error.InvalidContract;
    }
    for (proxy_client.server_request_handler_descriptors, 0..) |descriptor, index| {
        if (descriptor.kind == .unknown) return error.InvalidContract;
        for (proxy_client.server_request_handler_descriptors[0..index]) |prior| {
            if (std.mem.eql(u8, descriptor.method, prior.method) or
                descriptor.kind == prior.kind)
            {
                return error.InvalidContract;
            }
        }
        const value = policy_object.get(descriptor.method) orelse return error.InvalidContract;
        const policy = switch (value) {
            .string => |text| text,
            else => return error.InvalidContract,
        };
        if (!std.mem.eql(u8, policy, descriptor.policy)) return error.InvalidContract;
    }
    var iterator = policy_object.iterator();
    while (iterator.next()) |entry| {
        const descriptor = proxy_client.serverRequestHandler(entry.key_ptr.*) orelse
            return error.InvalidContract;
        const policy = switch (entry.value_ptr.*) {
            .string => |text| text,
            else => return error.InvalidContract,
        };
        if (!std.mem.eql(u8, policy, descriptor.policy)) return error.InvalidContract;
    }
}

fn inspectHandlerParity(
    allocator: std.mem.Allocator,
    policies: std.json.Value,
    failures: *std.ArrayList([]u8),
) !void {
    const policy_object = switch (policies) {
        .object => |value| value,
        else => {
            try appendUnique(allocator, failures, "serverRequestPolicies");
            return;
        },
    };
    for (proxy_client.server_request_handler_descriptors, 0..) |descriptor, index| {
        if (descriptor.kind == .unknown) try appendUnique(allocator, failures, descriptor.method);
        for (proxy_client.server_request_handler_descriptors[0..index]) |prior| {
            if (std.mem.eql(u8, descriptor.method, prior.method) or descriptor.kind == prior.kind) {
                try appendUnique(allocator, failures, descriptor.method);
            }
        }
        const policy_value = policy_object.get(descriptor.method) orelse {
            try appendUnique(allocator, failures, descriptor.method);
            continue;
        };
        const policy = switch (policy_value) {
            .string => |text| text,
            else => {
                try appendUnique(allocator, failures, descriptor.method);
                continue;
            },
        };
        if (!std.mem.eql(u8, policy, descriptor.policy)) {
            try appendUnique(allocator, failures, descriptor.method);
        }
    }
    var iterator = policy_object.iterator();
    while (iterator.next()) |entry| {
        const descriptor = proxy_client.serverRequestHandler(entry.key_ptr.*) orelse {
            try appendUnique(allocator, failures, entry.key_ptr.*);
            continue;
        };
        const policy = switch (entry.value_ptr.*) {
            .string => |text| text,
            else => {
                try appendUnique(allocator, failures, entry.key_ptr.*);
                continue;
            },
        };
        if (!std.mem.eql(u8, policy, descriptor.policy)) {
            try appendUnique(allocator, failures, entry.key_ptr.*);
        }
    }
}

fn validateProbeParity(probes: std.json.Array) !void {
    if (probes.items.len != behavioral_probe_descriptors.len) return error.InvalidContract;
    for (behavioral_probe_descriptors, 0..) |descriptor, index| {
        for (behavioral_probe_descriptors[0..index]) |prior| {
            if (std.mem.eql(u8, descriptor.id, prior.id)) return error.InvalidContract;
        }
        if (!jsonArrayContains(probes, descriptor.id)) return error.InvalidContract;
    }
    for (probes.items) |item| {
        const id = switch (item) {
            .string => |value| value,
            else => return error.InvalidContract,
        };
        if (behavioralProbeDescriptor(id) == null) return error.InvalidContract;
    }
}

fn inspectShapes(
    allocator: std.mem.Allocator,
    bundle: SchemaBundle,
    shapes: std.json.Array,
    profile: Profile,
    failures: *std.ArrayList([]u8),
) !void {
    if (bundle.documents.len > max_documents or shapes.items.len > max_shapes) {
        return error.SchemaTooLarge;
    }
    for (shapes.items) |shape| {
        if (!shapeAppliesToProfile(shape, profile)) continue;
        const id = try stringField(shape, "id");
        const document = try stringField(shape, "document");
        const pointer = try stringField(shape, "pointer");
        const expected_kind = try stringField(shape, "kind");
        const expected_nullable = try boolField(shape, "nullable");
        const raw = documentBytes(bundle, document) catch {
            try appendUnique(allocator, failures, id);
            continue;
        };
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
            try appendUnique(allocator, failures, id);
            continue;
        };
        defer parsed.deinit();
        const node = resolveShapeNode(&parsed.value, shape, pointer) catch {
            try appendUnique(allocator, failures, id);
            continue;
        };
        if (!schemaKindIsCompatible(node.*, expected_kind, expected_nullable) or
            !requiredNamesPresent(shape, node.*) or !enumValuesPresent(shape, node.*))
        {
            try appendUnique(allocator, failures, id);
        }
    }
}

fn shapeAppliesToProfile(shape: std.json.Value, profile: Profile) bool {
    const object = switch (shape) {
        .object => |value| value,
        else => return false,
    };
    const profiles_value = object.get("profiles") orelse return true;
    const profiles = switch (profiles_value) {
        .array => |value| value,
        else => return false,
    };
    for (profiles.items) |profile_value| {
        const name = switch (profile_value) {
            .string => |value| value,
            else => continue,
        };
        if (profileFromName(name) == profile) return true;
    }
    return false;
}

fn profileFromName(name: []const u8) ?Profile {
    if (std.mem.eql(u8, name, "core")) return .core;
    if (std.mem.eql(u8, name, "review")) return .review;
    if (std.mem.eql(u8, name, "session-inquiry")) return .session_inquiry;
    if (std.mem.eql(u8, name, "full")) return .full;
    return null;
}

fn resolveShapeNode(
    root: *const std.json.Value,
    selector: std.json.Value,
    pointer: []const u8,
) !*const std.json.Value {
    const selector_object = switch (selector) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    const variant_pointer_value = selector_object.get("variantPointer") orelse
        return resolvePointer(root, pointer);
    const variant_pointer = switch (variant_pointer_value) {
        .string => |value| value,
        else => return error.InvalidContract,
    };
    const discriminator = try stringField(selector, "discriminator");
    const discriminator_value = try stringField(selector, "discriminatorValue");
    const variants_node = try resolvePointer(root, variant_pointer);
    const variants = switch (variants_node.*) {
        .array => |value| value,
        else => return error.InvalidContract,
    };
    for (variants.items) |*variant| {
        const variant_object = switch (variant.*) {
            .object => |value| value,
            else => continue,
        };
        const properties_value = variant_object.get("properties") orelse continue;
        const properties = switch (properties_value) {
            .object => |value| value,
            else => continue,
        };
        const discriminator_schema_value = properties.get(discriminator) orelse continue;
        const discriminator_schema = switch (discriminator_schema_value) {
            .object => |value| value,
            else => continue,
        };
        const enum_value = discriminator_schema.get("enum") orelse continue;
        const enum_values = switch (enum_value) {
            .array => |value| value,
            else => continue,
        };
        if (jsonArrayContains(enum_values, discriminator_value)) {
            return resolvePointer(variant, pointer);
        }
    }
    return error.MissingDiscriminatorVariant;
}

fn resolvePointer(root: *const std.json.Value, pointer: []const u8) !*const std.json.Value {
    if (pointer.len == 0) return root;
    if (pointer[0] != '/') return error.InvalidPointer;
    var current = root;
    var segments = std.mem.splitScalar(u8, pointer[1..], '/');
    while (segments.next()) |segment| {
        if (std.mem.indexOfScalar(u8, segment, '~') != null) return error.InvalidPointer;
        current = switch (current.*) {
            .object => |object| object.getPtr(segment) orelse return error.MissingShape,
            .array => |array| blk: {
                const index = try std.fmt.parseUnsigned(usize, segment, 10);
                if (index >= array.items.len) return error.MissingShape;
                break :blk &array.items[index];
            },
            else => return error.MissingShape,
        };
    }
    return current;
}

fn schemaHasKind(value: std.json.Value, expected: []const u8) bool {
    const object = switch (value) {
        .object => |item| item,
        else => return false,
    };
    if (std.mem.eql(u8, expected, "ref")) {
        if (object.get("$ref") != null) return true;
        return unionHasRef(object.get("anyOf")) or
            unionHasRef(object.get("oneOf")) or
            unionHasRef(object.get("allOf"));
    }
    if (object.get("type")) |type_value| switch (type_value) {
        .string => |kind| if (std.mem.eql(u8, kind, expected)) return true,
        .array => |kinds| for (kinds.items) |kind_value| switch (kind_value) {
            .string => |kind| if (std.mem.eql(u8, kind, expected)) return true,
            else => {},
        },
        else => {},
    };
    return unionHasKind(object.get("anyOf"), expected) or
        unionHasKind(object.get("oneOf"), expected);
}

fn schemaKindIsCompatible(
    value: std.json.Value,
    expected: []const u8,
    nullable: bool,
) bool {
    if (!schemaHasKind(value, expected) or schemaIsNullable(value) != nullable) return false;
    if (!isScalarKind(expected)) return true;

    const object = switch (value) {
        .object => |item| item,
        else => return false,
    };
    if (object.get("type")) |type_value| {
        return typeHasOnlyExpectedScalarKind(type_value, expected, nullable);
    }

    var saw_union = false;
    for ([_][]const u8{ "anyOf", "oneOf" }) |union_name| {
        const union_value = object.get(union_name) orelse continue;
        saw_union = true;
        if (!unionHasOnlyExpectedScalarKind(union_value, expected, nullable)) return false;
    }
    return saw_union;
}

fn isScalarKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "boolean") or
        std.mem.eql(u8, kind, "integer") or
        std.mem.eql(u8, kind, "number") or
        std.mem.eql(u8, kind, "string");
}

fn typeHasOnlyExpectedScalarKind(
    type_value: std.json.Value,
    expected: []const u8,
    nullable: bool,
) bool {
    return switch (type_value) {
        .string => |kind| std.mem.eql(u8, kind, expected) and !nullable,
        .array => |kinds| blk: {
            var saw_expected = false;
            var saw_null = false;
            for (kinds.items) |kind_value| {
                const kind = switch (kind_value) {
                    .string => |text| text,
                    else => break :blk false,
                };
                if (std.mem.eql(u8, kind, expected)) {
                    saw_expected = true;
                } else if (std.mem.eql(u8, kind, "null")) {
                    saw_null = true;
                } else {
                    break :blk false;
                }
            }
            break :blk saw_expected and saw_null == nullable;
        },
        else => false,
    };
}

fn unionHasOnlyExpectedScalarKind(
    value: std.json.Value,
    expected: []const u8,
    nullable: bool,
) bool {
    const variants = switch (value) {
        .array => |items| items,
        else => return false,
    };
    var saw_expected = false;
    var saw_null = false;
    for (variants.items) |variant| {
        const object = switch (variant) {
            .object => |item| item,
            else => return false,
        };
        const type_value = object.get("type") orelse return false;
        const kind = switch (type_value) {
            .string => |text| text,
            else => return false,
        };
        if (std.mem.eql(u8, kind, expected)) {
            saw_expected = true;
        } else if (std.mem.eql(u8, kind, "null")) {
            saw_null = true;
        } else {
            return false;
        }
    }
    return saw_expected and saw_null == nullable;
}

fn unionHasRef(value: ?std.json.Value) bool {
    const variants = switch (value orelse return false) {
        .array => |items| items,
        else => return false,
    };
    for (variants.items) |variant| {
        const object = switch (variant) {
            .object => |item| item,
            else => continue,
        };
        if (object.get("$ref") != null) return true;
    }
    return false;
}

fn schemaIsNullable(value: std.json.Value) bool {
    return schemaHasKind(value, "null");
}

fn unionHasKind(value: ?std.json.Value, expected: []const u8) bool {
    const variants = switch (value orelse return false) {
        .array => |items| items,
        else => return false,
    };
    for (variants.items) |variant| {
        const object = switch (variant) {
            .object => |item| item,
            else => continue,
        };
        const type_value = object.get("type") orelse continue;
        if (switch (type_value) {
            .string => |kind| std.mem.eql(u8, kind, expected),
            else => false,
        }) return true;
    }
    return false;
}

fn requiredNamesPresent(selector: std.json.Value, schema: std.json.Value) bool {
    const selector_object = switch (selector) {
        .object => |value| value,
        else => return false,
    };
    const expected = selector_object.get("required") orelse return true;
    const expected_array = switch (expected) {
        .array => |value| value,
        else => return false,
    };
    const schema_object = switch (schema) {
        .object => |value| value,
        else => return false,
    };
    for (expected_array.items) |item| {
        const name = switch (item) {
            .string => |value| value,
            else => return false,
        };
        const actual = schema_object.get("required") orelse return false;
        const actual_array = switch (actual) {
            .array => |value| value,
            else => return false,
        };
        if (!jsonArrayContains(actual_array, name)) return false;
    }
    return true;
}

fn enumValuesPresent(selector: std.json.Value, schema: std.json.Value) bool {
    const selector_object = switch (selector) {
        .object => |value| value,
        else => return false,
    };
    const expected = selector_object.get("enumContains") orelse return true;
    const expected_array = switch (expected) {
        .array => |value| value,
        else => return false,
    };
    const schema_object = switch (schema) {
        .object => |value| value,
        else => return false,
    };
    for (expected_array.items) |item| {
        const name = switch (item) {
            .string => |value| value,
            else => return false,
        };
        const actual = schema_object.get("enum") orelse return false;
        const actual_array = switch (actual) {
            .array => |value| value,
            else => return false,
        };
        if (!jsonArrayContains(actual_array, name)) return false;
    }
    return true;
}

fn documentBytes(bundle: SchemaBundle, name: []const u8) ![]const u8 {
    if (bundle.documents.len > max_documents) return error.SchemaTooLarge;
    for (bundle.documents) |document| if (std.mem.eql(u8, document.name, name)) {
        if (document.bytes.len > max_document_bytes) return error.SchemaTooLarge;
        return document.bytes;
    };
    return error.MissingSchemaDocument;
}

fn objectField(value: std.json.Value, name: []const u8) !std.json.Value {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidJsonShape,
    };
    return object.get(name) orelse error.InvalidJsonShape;
}

fn arrayField(value: std.json.Value, name: []const u8) !std.json.Array {
    return switch (try objectField(value, name)) {
        .array => |item| item,
        else => error.InvalidJsonShape,
    };
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    return switch (try objectField(value, name)) {
        .string => |item| item,
        else => error.InvalidJsonShape,
    };
}

fn boolField(value: std.json.Value, name: []const u8) !bool {
    return switch (try objectField(value, name)) {
        .bool => |item| item,
        else => error.InvalidJsonShape,
    };
}

fn validateStringArray(array: std.json.Array) !void {
    if (array.items.len > max_methods) return error.ContractTooLarge;
    for (array.items, 0..) |item, index| {
        const text = switch (item) {
            .string => |value| value,
            else => return error.InvalidContract,
        };
        for (array.items[0..index]) |prior| if (switch (prior) {
            .string => |value| std.mem.eql(u8, text, value),
            else => false,
        }) return error.InvalidContract;
    }
}

fn jsonArrayContains(array: std.json.Array, needle: []const u8) bool {
    for (array.items) |item| if (switch (item) {
        .string => |value| std.mem.eql(u8, value, needle),
        else => false,
    }) return true;
    return false;
}

fn contains(items: []const []u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    if (!contains(list.items, value)) try list.append(allocator, try allocator.dupe(u8, value));
}

fn deinitStrings(list: *std.ArrayList([]u8), allocator: std.mem.Allocator) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

const stable_shapes =
    \\{"definitions":{"InitializeCapabilities":{"properties":{"experimentalApi":{"type":"boolean"},"optOutNotificationMethods":{"type":["array","null"]},"mcpServerOpenaiFormElicitation":{"type":"boolean"},"requestAttestation":{"type":"boolean"}}},"Thread":{"properties":{"isPinned":{"type":"boolean","future":true},"path":{"type":["string","null"]}}},"ThreadMetadataUpdateParams":{"properties":{"isPinned":{"type":["boolean","null"]}}},"ThreadListParams":{"properties":{"isPinned":{"type":["boolean","null"]}}},"ThreadForkParams":{"properties":{"lastTurnId":{"type":["string","null"]},"ephemeral":{"type":"boolean"}}},"ReviewStartParams":{"type":"object","required":["target","threadId"],"properties":{"target":{"allOf":[{"$ref":"#/definitions/ReviewTarget"}]}}},"ReviewTarget":{"oneOf":[{"type":"object","required":["type"],"properties":{"type":{"type":"string","enum":["uncommittedChanges"]}}},{"type":"object","required":["type","branch"],"properties":{"branch":{"type":"string"},"type":{"type":"string","enum":["baseBranch"]}}},{"type":"object","required":["type","sha"],"properties":{"sha":{"type":"string"},"type":{"type":"string","enum":["commit"]}}}]},"ThreadItem":{"oneOf":[{"properties":{"type":{"enum":["commandExecution"]},"pluginId":{"type":["string","null"]},"scriptPath":{"type":["string","null"]}}}]},"PathUri":{"type":"string"},"SkillInterface":{"properties":{"iconSmallUrl":{"type":["string","null"]},"iconLargeUrl":{"type":["string","null"]}}},"PluginListParams":{"properties":{"forceRefetch":{"type":"boolean"}}},"PluginShareContext":{"properties":{"canPublishToWorkspace":{"type":["boolean","null"]}}},"PluginShareSaveResponse":{"properties":{"canPublishToWorkspace":{"type":["boolean","null"]}}},"AppToolSummary":{"properties":{"isEnabled":{"type":"boolean"},"disabledReason":{"type":["string","null"]},"isReadOnly":{"type":"boolean"}}},"ConfigRequirements":{"properties":{"browserUse":{"anyOf":[{"$ref":"#/definitions/BrowserUseRequirements"},{"type":"null"}]},"sqliteHome":{"type":["string","null"]},"logDir":{"type":["string","null"]},"modelCatalogJson":{"type":["string","null"]},"checkForUpdateOnStartup":{"type":["boolean","null"]},"allowLoginShell":{"type":["boolean","null"]},"feedback":{"anyOf":[{"$ref":"#/definitions/FeedbackRequirements"},{"type":"null"}]},"windowsSandboxPrivateDesktop":{"type":["boolean","null"]}}},"ExternalAgentConfigDetectParams":{"properties":{"maxSessionAgeDays":{"type":["integer","null"]},"maxSessions":{"type":["integer","null"]}}},"ExternalAgentConfigImportParams":{"properties":{"providerId":{"type":["string","null"]}}},"PlanType":{"type":"string","enum":["ent26"]},"AppMetadata":{"type":"object","properties":{"name":{"type":"string"},"firstPartyType":{"type":"string"}}}}}
;

const experimental_shapes =
    \\{"definitions":{"ThreadForkParams":{"type":"object","required":["threadId"],"properties":{"beforeTurnId":{"type":["string","null"]},"ephemeral":{"type":"boolean"},"excludeTurns":{"type":"boolean"},"deferGoalContinuation":{"type":"boolean"}}},"ThreadTurnsListParams":{"type":"object","required":["threadId"]},"ThreadItemsListParams":{"type":"object","required":["threadId"]}}}
;

const TestBundles = struct {
    stable_client: []u8,
    stable_server: []u8,
    stable_notification: []u8,
    experimental_client: []u8,
    experimental_server: []u8,
    experimental_notification: []u8,

    fn deinit(self: *TestBundles, allocator: std.mem.Allocator) void {
        allocator.free(self.stable_client);
        allocator.free(self.stable_server);
        allocator.free(self.stable_notification);
        allocator.free(self.experimental_client);
        allocator.free(self.experimental_server);
        allocator.free(self.experimental_notification);
    }
};

fn methodSchema(allocator: std.mem.Allocator, methods: std.json.Array) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"oneOf\":[");
    for (methods.items, 0..) |method, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.writeAll("{\"properties\":{\"method\":{\"enum\":[");
        try std.json.Stringify.value(switch (method) {
            .string => |value| value,
            else => return error.InvalidContract,
        }, .{}, &output.writer);
        try output.writer.writeAll("]}}}");
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn makeTestBundles(allocator: std.mem.Allocator, baseline: std.json.Value) !TestBundles {
    const stable = try objectField(baseline, "stable");
    const experimental = try objectField(baseline, "experimental");
    const experimental_server_base = try methodSchema(
        allocator,
        try arrayField(stable, "requiredServerRequests"),
    );
    defer allocator.free(experimental_server_base);
    const current_time_addition =
        ",{\"properties\":{\"method\":{\"enum\":[\"currentTime/read\"]}}}]}";
    return .{
        .stable_client = try methodSchema(
            allocator,
            try arrayField(stable, "requiredClientMethods"),
        ),
        .stable_server = try methodSchema(
            allocator,
            try arrayField(stable, "requiredServerRequests"),
        ),
        .stable_notification = try methodSchema(
            allocator,
            try arrayField(stable, "requiredNotifications"),
        ),
        .experimental_client = try methodSchema(
            allocator,
            try arrayField(experimental, "requiredClientMethods"),
        ),
        .experimental_server = try std.mem.concat(allocator, u8, &.{
            experimental_server_base[0 .. experimental_server_base.len - 2],
            current_time_addition,
        }),
        .experimental_notification = try methodSchema(
            allocator,
            try arrayField(stable, "requiredNotifications"),
        ),
    };
}

fn inspectTestBundles(
    allocator: std.mem.Allocator,
    baseline: *const std.json.Value,
    bundles: *const TestBundles,
    stable_shape_doc: []const u8,
    experimental_shape_doc: []const u8,
) !InspectionReport {
    return inspectTestBundlesForProfile(
        allocator,
        baseline,
        bundles,
        stable_shape_doc,
        experimental_shape_doc,
        .full,
    );
}

fn inspectTestBundlesForProfile(
    allocator: std.mem.Allocator,
    baseline: *const std.json.Value,
    bundles: *const TestBundles,
    stable_shape_doc: []const u8,
    experimental_shape_doc: []const u8,
    profile: Profile,
) !InspectionReport {
    const stable_docs = [_]Document{
        .{ .name = "ClientRequest.json", .bytes = bundles.stable_client },
        .{ .name = "ServerRequest.json", .bytes = bundles.stable_server },
        .{ .name = "ServerNotification.json", .bytes = bundles.stable_notification },
        .{ .name = "codex_app_server_protocol.v2.schemas.json", .bytes = stable_shape_doc },
    };
    const experimental_docs = [_]Document{
        .{ .name = "ClientRequest.json", .bytes = bundles.experimental_client },
        .{ .name = "ServerRequest.json", .bytes = bundles.experimental_server },
        .{ .name = "ServerNotification.json", .bytes = bundles.experimental_notification },
    };
    const experimental_docs_with_shapes = [_]Document{
        experimental_docs[0], experimental_docs[1], experimental_docs[2],
    };
    var adjusted = experimental_docs_with_shapes;
    adjusted[0].bytes = try mergeDefinitionsIntoMethodSchema(
        allocator,
        bundles.experimental_client,
        experimental_shape_doc,
    );
    defer allocator.free(adjusted[0].bytes);
    return inspect(
        allocator,
        baseline,
        .{ .documents = &stable_docs },
        .{ .documents = &adjusted },
        profile,
    );
}

fn mergeDefinitionsIntoMethodSchema(
    allocator: std.mem.Allocator,
    methods: []const u8,
    definitions: []const u8,
) ![]u8 {
    if (methods.len < 2 or definitions.len < 2) return error.InvalidJsonShape;
    return std.fmt.allocPrint(
        allocator,
        "{{\"definitions\":{s},\"oneOf\":{s}",
        .{ definitions[15 .. definitions.len - 1], methods[9..] },
    );
}

test "baseline method-set cardinalities and exact compatible bundles" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    var report = try inspectTestBundles(
        std.testing.allocator,
        &baseline.value,
        &bundles,
        stable_shapes,
        experimental_shapes,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.compatible, report.status);
    try std.testing.expectEqual(@as(usize, 0), report.additive_server_requests.items.len);
}

test "PathUri round trips opaquely without native path normalization" {
    const fixtures = [_][]const u8{
        "file:///tmp/a%2Fb%20c",
        "file://server/share/Case%2FAlias",
        "file:///C:/Users/Test/%E2%98%83",
    };
    for (fixtures) |raw| {
        const uri = try PathUri.parse(raw);
        try std.testing.expectEqualStrings(raw, uri.raw);
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try std.json.Stringify.value(uri.raw, .{}, &output.writer);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            output.written(),
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectEqualStrings(raw, parsed.value.string);
    }
    try std.testing.expectError(error.InvalidPathUri, PathUri.parse("/tmp/not-a-uri"));
    try std.testing.expectError(error.InvalidPathUri, PathUri.parse("FILE:///tmp/not-canonical"));
    try std.testing.expectError(error.InvalidPathUri, PathUri.parse("file:///tmp/raw space"));
}

test "profiles select only their experimental client and shape obligations" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    try expectExperimentalMethodProfiles(&baseline.value, "thread/search", &.{.full});
    try expectExperimentalMethodProfiles(
        &baseline.value,
        "thread/turns/list",
        &.{ .session_inquiry, .full },
    );
    try expectExperimentalShapeProfiles(&baseline.value);
}

fn expectExperimentalMethodProfiles(
    baseline: *const std.json.Value,
    method: []const u8,
    required_profiles: []const Profile,
) !void {
    var bundles = try makeTestBundles(std.testing.allocator, baseline.*);
    defer bundles.deinit(std.testing.allocator);
    const offset = std.mem.indexOf(u8, bundles.experimental_client, method) orelse
        return error.TestExpectedEqual;
    bundles.experimental_client[offset + method.len - 1] = 'x';
    for ([_]Profile{ .core, .review, .session_inquiry, .full }) |profile| {
        var report = try inspectTestBundlesForProfile(
            std.testing.allocator,
            baseline,
            &bundles,
            stable_shapes,
            experimental_shapes,
            profile,
        );
        defer report.deinit(std.testing.allocator);
        const expected: Status = if (containsProfile(required_profiles, profile))
            .incompatible
        else
            .compatible;
        try std.testing.expectEqual(expected, report.status);
    }
}

fn expectExperimentalShapeProfiles(baseline: *const std.json.Value) !void {
    var bundles = try makeTestBundles(std.testing.allocator, baseline.*);
    defer bundles.deinit(std.testing.allocator);
    const drifted = try std.testing.allocator.dupe(u8, experimental_shapes);
    defer std.testing.allocator.free(drifted);
    const method = "beforeTurnId";
    const offset = std.mem.indexOf(u8, drifted, method) orelse
        return error.TestExpectedEqual;
    drifted[offset + method.len - 1] = 'x';
    for ([_]Profile{ .core, .review, .session_inquiry, .full }) |profile| {
        var report = try inspectTestBundlesForProfile(
            std.testing.allocator,
            baseline,
            &bundles,
            stable_shapes,
            drifted,
            profile,
        );
        defer report.deinit(std.testing.allocator);
        const expected: Status = if (profile == .session_inquiry or profile == .full)
            .incompatible
        else
            .compatible;
        try std.testing.expectEqual(expected, report.status);
    }
}

fn containsProfile(profiles: []const Profile, expected: Profile) bool {
    for (profiles) |profile| if (profile == expected) return true;
    return false;
}

test "stable obligations remain fail closed within their selected profiles" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    try expectMethodDriftAllProfiles(
        &baseline.value,
        .stable_client,
        "externalAgentConfig/import/recordHistory",
    );
    try expectMethodDriftAllProfiles(&baseline.value, .experimental_server, "currentTime/read");
    try expectMethodDriftAllProfiles(&baseline.value, .stable_notification, "error");
    try expectStableShapeProfiles(
        &baseline.value,
        "experimentalApi",
        &.{ .core, .review, .session_inquiry, .full },
    );
    try expectStableShapeProfiles(&baseline.value, "isPinned", &.{.full});
    try expectStableShapeProfiles(&baseline.value, "ReviewStartParams", &.{ .review, .full });
    try expectPolicyDriftAllProfiles(&baseline.value);
}

const TestMethodSurface = enum { stable_client, experimental_server, stable_notification };

fn expectMethodDriftAllProfiles(
    baseline: *const std.json.Value,
    surface: TestMethodSurface,
    method: []const u8,
) !void {
    for ([_]Profile{ .core, .review, .session_inquiry, .full }) |profile| {
        var bundles = try makeTestBundles(std.testing.allocator, baseline.*);
        defer bundles.deinit(std.testing.allocator);
        const bytes = switch (surface) {
            .stable_client => bundles.stable_client,
            .experimental_server => bundles.experimental_server,
            .stable_notification => bundles.stable_notification,
        };
        const offset = std.mem.indexOf(u8, bytes, method) orelse
            return error.TestExpectedEqual;
        bytes[offset + method.len - 1] = 'x';
        var report = try inspectTestBundlesForProfile(
            std.testing.allocator,
            baseline,
            &bundles,
            stable_shapes,
            experimental_shapes,
            profile,
        );
        defer report.deinit(std.testing.allocator);
        try std.testing.expectEqual(Status.incompatible, report.status);
    }
}

fn expectStableShapeProfiles(
    baseline: *const std.json.Value,
    needle: []const u8,
    required_profiles: []const Profile,
) !void {
    for ([_]Profile{ .core, .review, .session_inquiry, .full }) |profile| {
        var bundles = try makeTestBundles(std.testing.allocator, baseline.*);
        defer bundles.deinit(std.testing.allocator);
        const drifted = try std.testing.allocator.dupe(u8, stable_shapes);
        defer std.testing.allocator.free(drifted);
        const offset = std.mem.indexOf(u8, drifted, needle) orelse
            return error.TestExpectedEqual;
        drifted[offset + needle.len - 1] = 'x';
        var report = try inspectTestBundlesForProfile(
            std.testing.allocator,
            baseline,
            &bundles,
            drifted,
            experimental_shapes,
            profile,
        );
        defer report.deinit(std.testing.allocator);
        const expected: Status = if (containsProfile(required_profiles, profile))
            .incompatible
        else
            .compatible;
        try std.testing.expectEqual(expected, report.status);
    }
}

fn expectPolicyDriftAllProfiles(baseline: *std.json.Value) !void {
    const policy_value = baseline.object.getPtr("serverRequestPolicies") orelse
        return error.TestExpectedEqual;
    const policy = policy_value.object.getPtr("currentTime/read") orelse
        return error.TestExpectedEqual;
    policy.* = .{ .string = "wrong-policy" };
    for ([_]Profile{ .core, .review, .session_inquiry, .full }) |profile| {
        var bundles = try makeTestBundles(std.testing.allocator, baseline.*);
        defer bundles.deinit(std.testing.allocator);
        var report = try inspectTestBundlesForProfile(
            std.testing.allocator,
            baseline,
            &bundles,
            stable_shapes,
            experimental_shapes,
            profile,
        );
        defer report.deinit(std.testing.allocator);
        try std.testing.expectEqual(Status.incompatible, report.status);
        try std.testing.expect(contains(report.handler_failures.items, "currentTime/read"));
    }
}

fn expectProbeRequirement(
    expected: ProbeRequirement,
    profile: Profile,
    selection: ProbeSelection,
    probe_id: []const u8,
) !void {
    try std.testing.expectEqual(
        expected,
        probeRequirement(profile, selection, probe_id).?,
    );
}

test "behavioral probe descriptors exactly cover contract and select required probes" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    const probes = try arrayField(baseline.value, "behavioralProbes");
    try std.testing.expectEqual(probes.items.len, behavioral_probe_descriptors.len);
    for (behavioral_probe_descriptors) |descriptor| {
        try std.testing.expect(jsonArrayContains(probes, descriptor.id));
    }

    const stdio = ProbeSelection{ .transport = .stdio };
    try expectProbeRequirement(.required, .core, stdio, "initialize-lifecycle");
    try expectProbeRequirement(.required, .core, stdio, "stdio-transport");
    try expectProbeRequirement(.not_applicable, .core, stdio, "managed-websocket-transport");
    try expectProbeRequirement(.not_applicable, .core, stdio, "remote-code-mode-host");
    try expectProbeRequirement(.required, .review, stdio, "structured-review");
    try expectProbeRequirement(.required, .session_inquiry, stdio, "paginated-fork");
    try expectProbeRequirement(.not_applicable, .review, stdio, "paginated-fork");
    try expectProbeRequirement(.required, .full, stdio, "thread-pinning-round-trip");
    try expectProbeRequirement(
        .required,
        .core,
        .{ .transport = .stdio, .code_mode_host = true },
        "remote-code-mode-host",
    );
    try std.testing.expect(probeRequirement(.core, stdio, "future-probe") == null);
}

test "additive client notification and object fields remain compatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const client_addition = ",{\"properties\":{\"method\":{\"enum\":[\"future/client\"]}}}]}";
    const notification_addition =
        ",{\"properties\":{\"method\":{\"enum\":[\"future/notification\"]}}}]}";
    const experimental_notification_addition =
        ",{\"properties\":{\"method\":{\"enum\":[\"future/experimental-notification\"]}}}]}";
    const old_client = bundles.stable_client;
    const old_notification = bundles.stable_notification;
    const old_experimental_notification = bundles.experimental_notification;
    bundles.stable_client = try std.mem.concat(std.testing.allocator, u8, &.{
        old_client[0 .. old_client.len - 2],
        client_addition,
    });
    bundles.stable_notification = try std.mem.concat(std.testing.allocator, u8, &.{
        old_notification[0 .. old_notification.len - 2],
        notification_addition,
    });
    bundles.experimental_notification = try std.mem.concat(
        std.testing.allocator,
        u8,
        &.{
            old_experimental_notification[0 .. old_experimental_notification.len - 2],
            experimental_notification_addition,
        },
    );
    std.testing.allocator.free(old_client);
    std.testing.allocator.free(old_notification);
    std.testing.allocator.free(old_experimental_notification);
    var report = try inspectTestBundles(
        std.testing.allocator,
        &baseline.value,
        &bundles,
        stable_shapes,
        experimental_shapes,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.compatible, report.status);
    try std.testing.expectEqual(@as(usize, 1), report.additive_client_methods.items.len);
    try std.testing.expectEqual(@as(usize, 2), report.additive_notifications.items.len);
}

test "missing required method and discriminator drift are incompatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const needle = "externalAgentConfig/import/recordHistory";
    const offset = std.mem.indexOf(u8, bundles.stable_client, needle) orelse
        return error.TestExpectedEqual;
    @memcpy(
        bundles.stable_client[offset .. offset + needle.len],
        "externalAgentConfig/import/recordHistorx",
    );
    var report = try inspectTestBundles(
        std.testing.allocator,
        &baseline.value,
        &bundles,
        stable_shapes,
        experimental_shapes,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expect(report.missing_required.items.len != 0);
}

test "required shape kind and nullability drift are incompatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const drifted = try std.testing.allocator.dupe(u8, stable_shapes);
    defer std.testing.allocator.free(drifted);
    const kind_needle = "\"isPinned\":{\"type\":\"boolean\"";
    const kind_offset = std.mem.indexOf(u8, drifted, kind_needle) orelse
        return error.TestExpectedEqual;
    @memcpy(
        drifted[kind_offset + kind_needle.len - 8 .. kind_offset + kind_needle.len - 1],
        "integer",
    );
    const nullability_needle = "\"path\":{\"type\":[\"string\",\"null\"]}";
    const nullability_offset = std.mem.indexOf(u8, drifted, nullability_needle) orelse
        return error.TestExpectedEqual;
    const null_offset = nullability_offset + nullability_needle.len - 7;
    @memcpy(drifted[null_offset .. null_offset + 4], "bool");
    var report = try inspectTestBundles(
        std.testing.allocator,
        &baseline.value,
        &bundles,
        drifted,
        experimental_shapes,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expectEqual(@as(usize, 2), report.shape_failures.items.len);
}

test "required scalar shape rejects an additive union kind" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const widened = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        stable_shapes,
        "\"isPinned\":{\"type\":\"boolean\",\"future\":true}",
        "\"isPinned\":{\"type\":[\"boolean\",\"string\"],\"future\":true}",
    );
    defer std.testing.allocator.free(widened);
    var report = try inspectTestBundles(
        std.testing.allocator,
        &baseline.value,
        &bundles,
        widened,
        experimental_shapes,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expectEqual(@as(usize, 1), report.shape_failures.items.len);
    try std.testing.expectEqualStrings("thread-is-pinned", report.shape_failures.items[0]);
}

test "review target branch and commit identity remain strings" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const drifted = try std.testing.allocator.dupe(u8, stable_shapes);
    defer std.testing.allocator.free(drifted);
    for ([_][]const u8{
        "\"branch\":{\"type\":\"string\"}",
        "\"sha\":{\"type\":\"string\"}",
    }) |needle| {
        const offset = std.mem.indexOf(u8, drifted, needle) orelse
            return error.TestExpectedEqual;
        const kind_offset = offset + needle.len - "string\"}".len;
        @memcpy(drifted[kind_offset .. kind_offset + "string".len], "number");
    }
    var report = try inspectTestBundles(
        std.testing.allocator,
        &baseline.value,
        &bundles,
        drifted,
        experimental_shapes,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expectEqual(@as(usize, 2), report.shape_failures.items.len);
}

test "discriminated variant and required enum drift are incompatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const drifted = try std.testing.allocator.dupe(u8, stable_shapes);
    defer std.testing.allocator.free(drifted);
    const discriminator = "commandExecution";
    const discriminator_offset = std.mem.indexOf(u8, drifted, discriminator) orelse
        return error.TestExpectedEqual;
    drifted[discriminator_offset + discriminator.len - 1] = 'x';
    const plan = "ent26";
    const plan_offset = std.mem.indexOf(u8, drifted, plan) orelse return error.TestExpectedEqual;
    drifted[plan_offset + plan.len - 1] = '7';
    var report = try inspectTestBundles(
        std.testing.allocator,
        &baseline.value,
        &bundles,
        drifted,
        experimental_shapes,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expectEqual(@as(usize, 3), report.shape_failures.items.len);
}

test "unclassified additive server request fails full profile" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const addition = ",{\"properties\":{\"method\":{\"enum\":[\"future/server\"]}}}]}";
    const old = bundles.experimental_server;
    bundles.experimental_server = try std.mem.concat(std.testing.allocator, u8, &.{
        old[0 .. old.len - 2],
        addition,
    });
    std.testing.allocator.free(old);
    var report = try inspectTestBundles(
        std.testing.allocator,
        &baseline.value,
        &bundles,
        stable_shapes,
        experimental_shapes,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expectEqual(@as(usize, 1), report.unclassified_server_requests.items.len);
}

test "missing experimental current time request is incompatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const method = "currentTime/read";
    const offset = std.mem.indexOf(u8, bundles.experimental_server, method) orelse
        return error.TestExpectedEqual;
    bundles.experimental_server[offset + method.len - 1] = 'x';
    var report = try inspectTestBundles(
        std.testing.allocator,
        &baseline.value,
        &bundles,
        stable_shapes,
        experimental_shapes,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expect(contains(report.missing_required.items, method));
}

test "missing experimental notification is incompatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const method = "error";
    const offset = std.mem.indexOf(u8, bundles.experimental_notification, method) orelse
        return error.TestExpectedEqual;
    bundles.experimental_notification[offset + method.len - 1] = 'x';
    var report = try inspectTestBundles(
        std.testing.allocator,
        &baseline.value,
        &bundles,
        stable_shapes,
        experimental_shapes,
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expect(contains(report.missing_required.items, method));
}

test "exact codex version parsing distinguishes prerelease from build metadata" {
    const cases = [_]struct { raw: []const u8, prerelease: bool }{
        .{ .raw = "codex-cli 0.146.0\n", .prerelease = false },
        .{ .raw = "codex-cli 0.146.0-alpha.1\n", .prerelease = true },
        .{ .raw = "codex-cli 0.146.0+darwin.arm64\n", .prerelease = false },
        .{ .raw = "codex-cli 0.146.0-rc.1+build.7\n", .prerelease = true },
    };
    for (cases) |case| {
        var version = try parseCodexVersion(std.testing.allocator, case.raw);
        defer version.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.prerelease, version.prerelease());
    }
    const malformed = [_][]const u8{
        "codex 0.146.0\n",
        "codex-cli 0.146\n",
        "codex-cli 00.146.0\n",
        "codex-cli 0.146.0\ntrailing\n",
        "codex-cli 0.146.0 trailing\n",
        "codex-cli 0.146.0",
        "codex-cli 0.146.0\r\n",
        "codex-cli 0.146.0-\n",
    };
    for (malformed) |raw| {
        try std.testing.expectError(
            error.InvalidCodexVersion,
            parseCodexVersion(std.testing.allocator, raw),
        );
    }
}

test "codex version accepts bounded stderr diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    defer allocator.free(executable);
    try writeAbsoluteTestFile(
        io,
        executable,
        "#!/bin/sh\nprintf 'temporary-path warning\\n' >&2\n" ++
            "printf 'codex-cli 0.146.0\\n'\n",
    );
    try makeTestExecutable(io, executable);

    var version = try readCodexVersion(allocator, io, executable, .{});
    defer version.deinit(allocator);
    try std.testing.expectEqualStrings("0.146.0", version.text);
}

test "schema cache admission is independent of Codex version and release channel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    for ([_][]const u8{ "0.1.0", "0.148.0-alpha.5" }, 0..) |version_text, index| {
        const executable = try std.fmt.allocPrint(allocator, "{s}/fake-codex-{d}", .{ root, index });
        defer allocator.free(executable);
        const log_path = try std.fmt.allocPrint(allocator, "{s}/log-{d}", .{ root, index });
        defer allocator.free(log_path);
        const cache_root = try std.fmt.allocPrint(allocator, "{s}/cache-{d}", .{ root, index });
        defer allocator.free(cache_root);
        const script = try fakeCodexScriptVersionAlloc(
            allocator,
            log_path,
            false,
            false,
            version_text,
        );
        defer allocator.free(script);
        try writeAbsoluteTestFile(io, executable, script);
        try makeTestExecutable(io, executable);

        var schemas = try ensureSchemaCache(allocator, io, .{
            .cache_root = cache_root,
            .codex_path = executable,
        });
        defer schemas.deinit(allocator);
        try std.testing.expectEqualStrings(version_text, schemas.version.text);
    }
}

test "canonical bundle digest ignores object and creation order but binds path and content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const left = try std.fs.path.join(std.testing.allocator, &.{ root, "left" });
    defer std.testing.allocator.free(left);
    const right = try std.fs.path.join(std.testing.allocator, &.{ root, "right" });
    defer std.testing.allocator.free(right);
    try std.Io.Dir.cwd().createDirPath(io, left);
    try std.Io.Dir.cwd().createDirPath(io, right);
    try writeTestFile(io, left, "a.json", "{\"z\":1,\"a\":[2,3]}\n");
    try writeTestFile(io, left, "b.json", "{\"k\":true}\n");
    try writeTestFile(io, right, "b.json", "{\"k\":true}\n");
    try writeTestFile(io, right, "a.json", "{\"a\":[2,3],\"z\":1}\n");
    var left_digest = try digestBundle(std.testing.allocator, io, left, .{});
    defer left_digest.deinit(std.testing.allocator);
    var right_digest = try digestBundle(std.testing.allocator, io, right, .{});
    defer right_digest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(left_digest.digest, right_digest.digest);

    try writeTestFile(io, right, "a.json", "{\"a\":[3,2],\"z\":1}\n");
    var content_drift = try digestBundle(std.testing.allocator, io, right, .{});
    defer content_drift.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, left_digest.digest, content_drift.digest));
    const old_path = try std.fs.path.join(std.testing.allocator, &.{ right, "a.json" });
    defer std.testing.allocator.free(old_path);
    try std.Io.Dir.cwd().deleteFile(io, old_path);
    try writeTestFile(io, right, "renamed.json", "{\"z\":1,\"a\":[2,3]}\n");
    var path_drift = try digestBundle(std.testing.allocator, io, right, .{});
    defer path_drift.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, left_digest.digest, path_drift.digest));
}

test "bundle bounds reject symlink count and byte excess" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try writeTestFile(io, root, "a.json", "{}\n");
    const link = try std.fs.path.join(std.testing.allocator, &.{ root, "link.json" });
    defer std.testing.allocator.free(link);
    const target = try std.fs.path.join(std.testing.allocator, &.{ root, "a.json" });
    defer std.testing.allocator.free(target);
    try std.Io.Dir.symLinkAbsolute(io, target, link, .{});
    try std.testing.expectError(
        error.InvalidBundleEntry,
        digestBundle(std.testing.allocator, io, root, .{}),
    );
    try std.Io.Dir.cwd().deleteFile(io, link);

    try writeTestFile(io, root, "b.json", "{}\n");
    try std.testing.expectError(
        error.BundleTooManyFiles,
        digestBundle(std.testing.allocator, io, root, .{ .bundle_documents = 1 }),
    );
    try std.testing.expectError(
        error.BundleFileTooLarge,
        digestBundle(std.testing.allocator, io, root, .{ .bundle_file_bytes = 1 }),
    );
    try std.testing.expectError(
        error.BundleTooLarge,
        digestBundle(std.testing.allocator, io, root, .{ .bundle_total_bytes = 4 }),
    );
}

test "executable identity verification rejects an in-place replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    defer allocator.free(executable);
    try writeAbsoluteTestFile(io, executable, "#!/bin/sh\nexit 0\n");
    try makeTestExecutable(io, executable);
    var identity = try resolveExecutableIdentity(allocator, io, executable, max_binary_bytes);
    defer identity.deinit(allocator);

    try writeAbsoluteTestFile(io, executable, "#!/bin/sh\nexit 1\n");
    try makeTestExecutable(io, executable);
    try std.testing.expectError(
        error.ExecutableChanged,
        verifyExecutableIdentity(allocator, io, &identity),
    );
}

test "schema cache hits only after exact identity manifest and canonical bundles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    defer allocator.free(executable);
    const log_path = try std.fs.path.join(allocator, &.{ root, "invocations.log" });
    defer allocator.free(log_path);
    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    const script = try fakeCodexScriptAlloc(allocator, log_path, false, false);
    defer allocator.free(script);
    try writeAbsoluteTestFile(io, executable, script);
    try makeTestExecutable(io, executable);

    const saved = try primeSchemaCache(allocator, io, cache_root, executable, log_path);
    defer allocator.free(saved.stable);
    defer allocator.free(saved.cache);
    try expectSchemaCacheHit(allocator, io, cache_root, executable, log_path);
    try expectSchemaCacheRegeneration(
        allocator,
        io,
        cache_root,
        executable,
        script,
        saved,
    );
}

const SavedCachePaths = struct { stable: []u8, cache: []u8 };

fn primeSchemaCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_root: []const u8,
    executable: []const u8,
    log_path: []const u8,
) !SavedCachePaths {
    var first = try ensureSchemaCache(allocator, io, .{
        .cache_root = cache_root,
        .codex_path = executable,
    });
    defer first.deinit(allocator);
    try std.testing.expect(!first.hit);
    const first_log = try readAbsoluteTestFile(allocator, io, log_path, 16 * 1024);
    defer allocator.free(first_log);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, first_log, "app-server generate-json-schema"),
    );
    try std.testing.expectError(
        error.CacheLockTimedOut,
        ensureSchemaCacheWithLimits(
            allocator,
            io,
            .{ .cache_root = cache_root, .codex_path = executable },
            .{ .lock_timeout_ms = 30, .lock_retry_ms = 5 },
        ),
    );
    first.releaseLock();
    first.releaseLock();
    var concurrent_reader = try ensureSchemaCacheWithLimits(
        allocator,
        io,
        .{ .cache_root = cache_root, .codex_path = executable },
        .{ .lock_timeout_ms = 30, .lock_retry_ms = 5 },
    );
    defer concurrent_reader.deinit(allocator);
    try std.testing.expect(concurrent_reader.hit);
    return .{
        .stable = try allocator.dupe(u8, first.stable_path),
        .cache = try allocator.dupe(u8, first.cache_path),
    };
}

fn expectSchemaCacheHit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_root: []const u8,
    executable: []const u8,
    log_path: []const u8,
) !void {
    const first_log = try readAbsoluteTestFile(allocator, io, log_path, 16 * 1024);
    defer allocator.free(first_log);
    var second = try ensureSchemaCache(allocator, io, .{
        .cache_root = cache_root,
        .codex_path = executable,
    });
    defer second.deinit(allocator);
    try std.testing.expect(second.hit);
    const second_log = try readAbsoluteTestFile(allocator, io, log_path, 16 * 1024);
    defer allocator.free(second_log);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, second_log, "app-server generate-json-schema"),
    );
    try std.testing.expectEqual(
        std.mem.count(u8, first_log, "--version") + 1,
        std.mem.count(u8, second_log, "--version"),
    );
}

fn expectSchemaCacheRegeneration(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_root: []const u8,
    executable: []const u8,
    script: []const u8,
    saved: SavedCachePaths,
) !void {
    try writeTestFile(io, saved.stable, "root.json", "{\"drift\":true}\n");
    {
        var bundle_regenerated = try ensureSchemaCache(allocator, io, .{
            .cache_root = cache_root,
            .codex_path = executable,
        });
        defer bundle_regenerated.deinit(allocator);
        try std.testing.expect(!bundle_regenerated.hit);
    }

    const manifest_path = try std.fs.path.join(allocator, &.{ saved.cache, "preflight.json" });
    defer allocator.free(manifest_path);
    try writeAbsoluteTestFile(io, manifest_path, "{}\n");
    {
        var manifest_regenerated = try ensureSchemaCache(allocator, io, .{
            .cache_root = cache_root,
            .codex_path = executable,
        });
        defer manifest_regenerated.deinit(allocator);
        try std.testing.expect(!manifest_regenerated.hit);
    }

    const changed_script = try std.mem.concat(allocator, u8, &.{ script, "# identity drift\n" });
    defer allocator.free(changed_script);
    try writeAbsoluteTestFile(io, executable, changed_script);
    try makeTestExecutable(io, executable);
    var identity_regenerated = try ensureSchemaCache(allocator, io, .{
        .cache_root = cache_root,
        .codex_path = executable,
    });
    defer identity_regenerated.deinit(allocator);
    try std.testing.expect(!identity_regenerated.hit);
}

test "relative cache root is normalized to an absolute isolated path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    defer allocator.free(executable);
    const log_path = try std.fs.path.join(allocator, &.{ root, "relative.log" });
    defer allocator.free(log_path);
    const absolute_cache = try std.fs.path.join(
        allocator,
        &.{ root, "relative-cache", "missing-child" },
    );
    defer allocator.free(absolute_cache);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const relative_cache = try std.fs.path.relative(allocator, cwd, null, cwd, absolute_cache);
    defer allocator.free(relative_cache);
    const script = try fakeCodexScriptAlloc(allocator, log_path, false, false);
    defer allocator.free(script);
    try writeAbsoluteTestFile(io, executable, script);
    try makeTestExecutable(io, executable);

    var schemas = try ensureSchemaCache(allocator, io, .{
        .cache_root = relative_cache,
        .codex_path = executable,
    });
    defer schemas.deinit(allocator);
    try std.testing.expect(std.fs.path.isAbsolute(schemas.cache_path));
    try std.testing.expect(std.mem.startsWith(u8, schemas.cache_path, absolute_cache));
}

test "tiny process deadline and output limits fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const cache_root = try std.fs.path.join(allocator, &.{ root, "cache" });
    defer allocator.free(cache_root);
    const executable = try std.fs.path.join(allocator, &.{ root, "fake-codex" });
    defer allocator.free(executable);
    const log_path = try std.fs.path.join(allocator, &.{ root, "log" });
    defer allocator.free(log_path);

    const slow = try fakeCodexScriptAlloc(allocator, log_path, true, false);
    defer allocator.free(slow);
    try writeAbsoluteTestFile(io, executable, slow);
    try makeTestExecutable(io, executable);
    try std.testing.expectError(
        error.ProcessTimedOut,
        ensureSchemaCacheWithLimits(
            allocator,
            io,
            .{ .cache_root = cache_root, .codex_path = executable },
            .{ .version_timeout_ms = 10 },
        ),
    );

    const noisy = try fakeCodexScriptAlloc(allocator, log_path, false, true);
    defer allocator.free(noisy);
    try writeAbsoluteTestFile(io, executable, noisy);
    try makeTestExecutable(io, executable);
    try std.testing.expectError(
        error.ProcessOutputTooLarge,
        ensureSchemaCacheWithLimits(
            allocator,
            io,
            .{ .cache_root = cache_root, .codex_path = executable },
            .{ .version_stdout_bytes = 16 },
        ),
    );
}

fn writeTestFile(io: std.Io, root: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, name });
    defer std.testing.allocator.free(path);
    try writeAbsoluteTestFile(io, path, bytes);
}

fn writeAbsoluteTestFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn readAbsoluteTestFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false });
    defer file.close(io);
    return readFileBounded(allocator, io, file, limit);
}

fn fakeCodexScriptAlloc(
    allocator: std.mem.Allocator,
    log_path: []const u8,
    slow: bool,
    noisy: bool,
) ![]u8 {
    return fakeCodexScriptVersionAlloc(allocator, log_path, slow, noisy, "0.146.0");
}

fn fakeCodexScriptVersionAlloc(
    allocator: std.mem.Allocator,
    log_path: []const u8,
    slow: bool,
    noisy: bool,
    version: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> '{s}'\n" ++
            "if [ \"$1\" = \"--version\" ]; then\n  {s}\n  {s}\n" ++
            "  printf 'codex-cli {s}\\n'\n  exit 0\nfi\n" ++
            "out=''\nprofile='stable'\nwhile [ \"$#\" -gt 0 ]; do\n" ++
            "  case \"$1\" in\n    --experimental) profile='experimental' ;;\n" ++
            "    --out) shift; out=\"$1\" ;;\n  esac\n  shift\ndone\n" ++
            "mkdir -p \"$out\"\nprintf '{{\"profile\":\"%s\"," ++
            "\"object\":{{\"z\":1,\"a\":2}}}}\\n' \"$profile\" > \"$out/root.json\"\n",
        .{
            log_path,
            if (slow) "sleep 1" else ":",
            if (noisy)
                "printf '0123456789012345678901234567890123456789'"
            else
                ":",
            version,
        },
    );
}

fn makeTestExecutable(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        path,
        std.Io.File.Permissions.fromMode(0o755),
        .{},
    );
}
