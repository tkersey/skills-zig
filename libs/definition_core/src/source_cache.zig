const std = @import("std");
const cache = @import("cache.zig");
const closure = @import("closure.zig");
const json = @import("json.zig");

/// Decoded paths belong to the caller's allocator, independently of cache bytes.
pub const SourceManifestFile = struct {
    path: []u8,
    source_digest: [32]u8,
    source_bytes: usize,

    pub fn deinit(self: *SourceManifestFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Locator = struct {
    plan_key: [32]u8,
    closure_digest: [71]u8,
    files: []SourceManifestFile,

    pub fn deinit(self: *Locator, allocator: std.mem.Allocator) void {
        for (self.files) |*file| file.deinit(allocator);
        allocator.free(self.files);
        self.* = undefined;
    }
};

pub const ManifestLimits = struct {
    min_files: usize = 0,
    max_files: usize = 128,
    max_path_bytes: usize = 4 * 1024 * 1024,
};

/// The caller owns version framing, cache admission, and source verification.
pub fn encodeLocatorBody(
    source: *const closure.Closure,
    plan_key: [32]u8,
    encoder: *cache.Encoder,
) !void {
    try encoder.writeFixed(&plan_key);
    try encoder.writeFixed(&source.digest);
    try encoder.writeCount(source.files.len);
    for (source.files) |file| {
        try encoder.writeBytes(file.path);
        try encoder.writeFixed(&file.source_digest);
        try encoder.writeUsize(file.source_bytes);
    }
}

pub fn decodeLocatorBody(
    allocator: std.mem.Allocator,
    decoder: *cache.Decoder,
    limits: ManifestLimits,
) !Locator {
    var plan_key: [32]u8 = undefined;
    @memcpy(&plan_key, try decoder.readFixed(plan_key.len));
    var closure_digest: [71]u8 = undefined;
    @memcpy(&closure_digest, try decoder.readFixed(closure_digest.len));
    try json.digest(&closure_digest);
    const count = try decoder.readCount(limits.max_files);
    if (count < limits.min_files) return error.TooManyDefinitionFiles;
    const files = try allocator.alloc(SourceManifestFile, count);
    var initialized: usize = 0;
    errdefer {
        for (files[0..initialized]) |*file| file.deinit(allocator);
        allocator.free(files);
    }
    for (files) |*file| {
        const path = try decoder.readBytesAlloc(allocator, limits.max_path_bytes);
        errdefer allocator.free(path);
        var source_digest: [32]u8 = undefined;
        @memcpy(&source_digest, try decoder.readFixed(source_digest.len));
        file.* = .{
            .path = path,
            .source_digest = source_digest,
            .source_bytes = try decoder.readUsize(),
        };
        initialized += 1;
    }
    try decoder.finish();
    return .{ .plan_key = plan_key, .closure_digest = closure_digest, .files = files };
}

pub const ClosureHeader = struct {
    digest: [71]u8,
    total_definition_bytes: usize,
    file_count: usize,
};

pub fn encodeClosureHeader(source: *const closure.Closure, encoder: *cache.Encoder) !void {
    try encoder.writeFixed(&source.digest);
    try encoder.writeUsize(source.total_definition_bytes);
    try encoder.writeCount(source.files.len);
}

pub fn decodeClosureHeader(decoder: *cache.Decoder, limits: closure.Limits) !ClosureHeader {
    var digest: [71]u8 = undefined;
    @memcpy(&digest, try decoder.readFixed(digest.len));
    try json.digest(&digest);
    return .{
        .digest = digest,
        .total_definition_bytes = try decoder.readUsize(),
        .file_count = try decoder.readCount(limits.max_files),
    };
}

pub fn encodeClosureFiles(source: *const closure.Closure, encoder: *cache.Encoder) !void {
    for (source.files) |file| {
        try encoder.writeBytes(file.path);
        try encoder.writeBytes(file.canonical_json);
        try encoder.writeFixed(&file.source_digest);
        try encoder.writeUsize(file.source_bytes);
    }
}

pub fn encodeClosure(source: *const closure.Closure, encoder: *cache.Encoder) !void {
    try encodeClosureHeader(source, encoder);
    try encodeClosureFiles(source, encoder);
}

pub fn decodeClosure(
    allocator: std.mem.Allocator,
    decoder: *cache.Decoder,
    entry_path: []const u8,
    limits: closure.Limits,
) !closure.Closure {
    const header = try decodeClosureHeader(decoder, limits);
    return decodeFullClosure(allocator, decoder, header, entry_path, limits);
}

/// All paths and canonical source bytes are copied into the returned owner.
pub fn decodeFullClosure(
    allocator: std.mem.Allocator,
    decoder: *cache.Decoder,
    header: ClosureHeader,
    entry_path: []const u8,
    limits: closure.Limits,
) !closure.Closure {
    if (header.file_count > limits.max_files) return error.CacheCountTooLarge;
    var result: closure.Closure = .{
        .files = try decodeClosureFiles(allocator, decoder, limits, header.file_count),
        .digest = header.digest,
        .total_definition_bytes = header.total_definition_bytes,
    };
    errdefer result.deinit(allocator);
    try closure.validateCached(allocator, &result, entry_path, limits);
    return result;
}

fn decodeClosureFiles(
    allocator: std.mem.Allocator,
    decoder: *cache.Decoder,
    limits: closure.Limits,
    count: usize,
) ![]closure.ClosureFile {
    const files = try allocator.alloc(closure.ClosureFile, count);
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
        const canonical = try decoder.readBytesAlloc(allocator, limits.max_file_bytes);
        errdefer allocator.free(canonical);
        var source_digest: [32]u8 = undefined;
        @memcpy(&source_digest, try decoder.readFixed(source_digest.len));
        file.* = .{
            .path = path,
            .canonical_json = canonical,
            .source_digest = source_digest,
            .source_bytes = try decoder.readUsize(),
        };
        initialized += 1;
    }
    return files;
}

const fixture_digest = "sha256:e2dedb6a6a1b1cb50761e7cb7ab63785b259e1023507573f5c6d3d4ea14cf418";
const fixture_source_digest =
    "\x44\x13\x6f\xa3\x55\xb3\x67\x8a\x11\x46\xad\x16\xf7\xe8\x64\x9e" ++
    "\x94\xfb\x4f\xc2\x1f\xe7\x7e\x83\x10\xc0\x60\xf6\x1c\xaa\xff\x8a";
const fixture_size = "\x00\x00\x00\x00\x00\x00\x00\x02";
const fixture_count = "\x00\x00\x00\x01";
const fixture_path = "\x00\x00\x00\x06a.json";
const closure_wire = fixture_digest ++ fixture_size ++ fixture_count ++ fixture_path ++
    "\x00\x00\x00\x02{}" ++ fixture_source_digest ++ fixture_size;
const locator_wire = "k" ** 32 ++ fixture_digest ++ fixture_count ++ fixture_path ++
    fixture_source_digest ++ fixture_size;

fn fixtureClosure(files: *[1]closure.ClosureFile) closure.Closure {
    files[0] = .{
        .path = @constCast("a.json"),
        .canonical_json = @constCast("{}"),
        .source_digest = fixture_source_digest[0..32].*,
        .source_bytes = 2,
    };
    return .{ .files = files, .digest = fixture_digest.*, .total_definition_bytes = 2 };
}

test "source cache encoders preserve the fixed closure and locator wire formats" {
    var files: [1]closure.ClosureFile = undefined;
    const source = fixtureClosure(&files);
    var encoded = cache.Encoder.init(std.testing.allocator, 1024);
    defer encoded.deinit();
    try encodeClosure(&source, &encoded);
    try std.testing.expectEqualStrings(closure_wire, encoded.written());
    var locator = cache.Encoder.init(std.testing.allocator, 1024);
    defer locator.deinit();
    try encodeLocatorBody(&source, [_]u8{'k'} ** 32, &locator);
    try std.testing.expectEqualStrings(locator_wire, locator.written());
}

test "decoded source cache ownership survives destruction of input bytes" {
    const bytes = try std.testing.allocator.dupe(u8, closure_wire);
    defer std.testing.allocator.free(bytes);
    var decoder = cache.Decoder.init(bytes);
    var decoded = try decodeClosure(std.testing.allocator, &decoder, "a.json", .{});
    defer decoded.deinit(std.testing.allocator);
    try decoder.finish();
    @memset(bytes, 0);
    try std.testing.expectEqualStrings("a.json", decoded.files[0].path);
    try std.testing.expectEqualStrings("{}", decoded.files[0].canonical_json);
    const manifest_bytes = try std.testing.allocator.dupe(u8, locator_wire);
    defer std.testing.allocator.free(manifest_bytes);
    var manifest_decoder = cache.Decoder.init(manifest_bytes);
    var locator = try decodeLocatorBody(std.testing.allocator, &manifest_decoder, .{});
    defer locator.deinit(std.testing.allocator);
    @memset(manifest_bytes, 0);
    try std.testing.expectEqualStrings("a.json", locator.files[0].path);
    try std.testing.expectEqualStrings(fixture_source_digest, &locator.files[0].source_digest);
}

fn decodeClosureFixture(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var decoder = cache.Decoder.init(bytes);
    var decoded = decodeClosure(allocator, &decoder, "a.json", .{}) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer decoded.deinit(allocator);
    try decoder.finish();
}

fn decodeLocatorFixture(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var decoder = cache.Decoder.init(bytes);
    var decoded = try decodeLocatorBody(allocator, &decoder, .{});
    defer decoded.deinit(allocator);
}

test "source cache decoders release every allocation on truncation and allocation failure" {
    for (0..closure_wire.len) |end| {
        try std.testing.expectError(
            error.CachePayloadTruncated,
            decodeClosureFixture(std.testing.allocator, closure_wire[0..end]),
        );
    }
    for (0..locator_wire.len) |end| {
        try std.testing.expectError(
            error.CachePayloadTruncated,
            decodeLocatorFixture(std.testing.allocator, locator_wire[0..end]),
        );
    }
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeClosureFixture,
        .{closure_wire},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeLocatorFixture,
        .{locator_wire},
    );
}

test "full source cache decoding rejects corrupted authoritative fields" {
    var bytes = closure_wire.*;
    bytes[7] = '0';
    try std.testing.expectError(
        error.DefinitionClosureDigestMismatch,
        decodeClosureFixture(std.testing.allocator, &bytes),
    );
    bytes = closure_wire.*;
    bytes[78] = 3;
    try std.testing.expectError(
        error.DefinitionSourceSizeMismatch,
        decodeClosureFixture(std.testing.allocator, &bytes),
    );
    bytes = closure_wire.*;
    bytes[82] = 129;
    try std.testing.expectError(
        error.CacheCountTooLarge,
        decodeClosureFixture(std.testing.allocator, &bytes),
    );
    try std.testing.expectError(
        error.CachePayloadTrailingBytes,
        decodeLocatorFixture(std.testing.allocator, locator_wire ++ "extra"),
    );
}

test "locator minimum file policy remains caller selected before trailing validation" {
    const empty = "k" ** 32 ++ fixture_digest ++ "\x00\x00\x00\x00";
    try decodeLocatorFixture(std.testing.allocator, empty);
    var decoder = cache.Decoder.init(empty ++ "extra");
    try std.testing.expectError(
        error.TooManyDefinitionFiles,
        decodeLocatorBody(std.testing.allocator, &decoder, .{ .min_files = 1 }),
    );
}
