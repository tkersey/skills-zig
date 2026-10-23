const std = @import("std");
const durable_store = @import("durable_store");
const cache = @import("cache.zig");
const closure = @import("closure.zig");
const source_cache = @import("source_cache.zig");

pub const Namespace = enum { plans, locators };

pub const Entry = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    payload: []const u8,

    pub fn deinit(self: *Entry) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Directory = struct {
    entries: durable_store.PrivateDirectory,

    pub fn open(
        fs: durable_store.Fs,
        path: []const u8,
        mode: durable_store.PrivateDirectory.Mode,
    ) !Directory {
        return .{ .entries = try durable_store.PrivateDirectory.open(fs, path, mode) };
    }

    pub fn deinit(self: *Directory) void {
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn read(
        self: *const Directory,
        allocator: std.mem.Allocator,
        namespace: Namespace,
        key: [32]u8,
        limits: cache.Limits,
    ) !Entry {
        var entries = try self.entries.openChild(@tagName(namespace), .read_only);
        defer entries.deinit();
        const filename = leaf(key);
        const bytes = try entries.readAlloc(allocator, &filename, limits.max_entry_bytes);
        errdefer allocator.free(bytes);
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .payload = try cache.decode(key, bytes, limits),
        };
    }

    pub fn publishPlan(
        self: *const Directory,
        key: [32]u8,
        payload: []const u8,
        limits: cache.Limits,
    ) !PlanPublication {
        try self.publish(.plans, key, payload, limits);
        return .{ .directory = self, .key = key };
    }

    pub fn readVerifiedLocator(
        self: *const Directory,
        allocator: std.mem.Allocator,
        key: [32]u8,
        admitted_root: []const u8,
        limits: cache.Limits,
        closure_limits: closure.Limits,
        comptime decode: anytype,
    ) !?source_cache.VerifiedLocator {
        var entry = self.read(allocator, .locators, key, limits) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer entry.deinit();
        return try source_cache.verifyLocator(
            self.entries.io,
            allocator,
            admitted_root,
            try decode(allocator, entry.payload),
            closure_limits,
        );
    }

    fn publish(
        self: *const Directory,
        namespace: Namespace,
        key: [32]u8,
        payload: []const u8,
        limits: cache.Limits,
    ) !void {
        const header = try cache.encodeHeader(key, payload, limits);
        var entries = try self.entries.openChild(@tagName(namespace), .create);
        defer entries.deinit();
        const filename = leaf(key);
        try entries.replace(&filename, &.{ &header, payload });
    }
};

pub const PlanPublication = struct {
    directory: *const Directory,
    key: [32]u8,

    pub fn publishLocator(
        self: PlanPublication,
        key: [32]u8,
        payload: []const u8,
        limits: cache.Limits,
    ) !void {
        try self.directory.publish(.locators, key, payload, limits);
    }
};

pub fn leaf(key: [32]u8) [68]u8 {
    const hex = cache.keyHex(key);
    var filename: [68]u8 = undefined;
    @memcpy(filename[0..64], &hex);
    @memcpy(filename[64..], ".bin");
    return filename;
}

test "cache transport preserves envelope bytes and independent entry ownership" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try Directory.open(.init(io, tmp.dir), "cache", .create);
    defer directory.deinit();
    const plan_key = cache.key(&.{"plan"});
    const locator_key = cache.key(&.{"locator"});
    const published = try directory.publishPlan(plan_key, "compiled", .{});
    try published.publishLocator(locator_key, &plan_key, .{});
    var plan = try directory.read(allocator, .plans, plan_key, .{});
    defer plan.deinit();
    var locator = try directory.read(allocator, .locators, locator_key, .{});
    defer locator.deinit();
    const expected_plan = try cache.encodeAlloc(allocator, plan_key, "compiled", .{});
    defer allocator.free(expected_plan);
    try std.testing.expectEqualSlices(u8, expected_plan, plan.bytes);
    try std.testing.expectEqualStrings("compiled", plan.payload);
    try std.testing.expectEqualSlices(u8, &plan_key, locator.payload);
    const replacement = try directory.publishPlan(plan_key, "replacement", .{});
    try std.testing.expectEqualSlices(u8, &plan_key, &replacement.key);
    try std.testing.expectEqualStrings("compiled", plan.payload);
}

test "cache transport rejects corrupt bounded entries and missing namespaces" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try Directory.open(.init(io, tmp.dir), "cache", .create);
    defer directory.deinit();
    const key = cache.key(&.{"entry"});
    try std.testing.expectError(error.FileNotFound, directory.read(allocator, .locators, key, .{}));
    const published = try directory.publishPlan(key, "payload", .{});
    try std.testing.expectEqualSlices(u8, &key, &published.key);
    try std.testing.expectError(error.FileTooBig, directory.read(allocator, .plans, key, .{
        .max_entry_bytes = cache.header_bytes + "payload".len - 1,
    }));
    try std.testing.expectError(
        error.CachePayloadTooLarge,
        directory.read(allocator, .plans, key, .{ .max_payload_bytes = "payload".len - 1 }),
    );
    var entries = try directory.entries.openChild("plans", .read_only);
    defer entries.deinit();
    const filename = leaf(key);
    const wrong_key = cache.key(&.{"different"});
    const wrong_header = try cache.encodeHeader(wrong_key, "payload", .{});
    try entries.replace(&filename, &.{ &wrong_header, "payload" });
    try std.testing.expectError(
        error.CacheKeyMismatch,
        directory.read(allocator, .plans, key, .{}),
    );
    const header = try cache.encodeHeader(key, "payload", .{});
    try entries.replace(&filename, &.{ &header, "changed" });
    try std.testing.expectError(
        error.CachePayloadChecksumMismatch,
        directory.read(allocator, .plans, key, .{}),
    );
}

test "cache transport retains the plan when locator publication is rejected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try Directory.open(.init(io, tmp.dir), "cache", .create);
    defer directory.deinit();
    const plan_key = cache.key(&.{"plan"});
    const locator_key = cache.key(&.{"locator"});
    const publication = try directory.publishPlan(plan_key, "compiled", .{});
    try std.testing.expectError(
        error.CachePayloadTooLarge,
        publication.publishLocator(locator_key, "locator", .{ .max_payload_bytes = 1 }),
    );
    var plan = try directory.read(allocator, .plans, plan_key, .{});
    defer plan.deinit();
    try std.testing.expectEqualStrings("compiled", plan.payload);
    try std.testing.expectError(
        error.FileNotFound,
        directory.read(allocator, .locators, locator_key, .{}),
    );
}

test "cache transport releases every failed read allocation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try Directory.open(.init(io, tmp.dir), "cache", .create);
    defer directory.deinit();
    const key = cache.key(&.{"plan"});
    _ = try directory.publishPlan(key, "compiled", .{});
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        readForAllocationFailure,
        .{ &directory, key },
    );
}

fn readForAllocationFailure(
    allocator: std.mem.Allocator,
    directory: *const Directory,
    key: [32]u8,
) !void {
    var entry = try directory.read(allocator, .plans, key, .{});
    defer entry.deinit();
    try std.testing.expectEqualStrings("compiled", entry.payload);
}
