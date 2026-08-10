const std = @import("std");

pub const ViewedState = enum { viewed, unviewed, dismissed };
pub const SessionStatus = enum { current, stale_origin, completed, closed };

pub const ReviewThread = struct { id: []const u8, path: []const u8, line: ?u32 = null, outdated: bool = false };
pub const Tab = struct { id: []const u8, path: []const u8, revision: []const u8, status: SessionStatus = .current };

pub const File = struct {
    path: []const u8,
    additions: u32 = 0,
    deletions: u32 = 0,
    change_type: []const u8 = "MODIFIED",
    viewed: ViewedState,
    revision_key: []const u8,
};

pub const PrGeneration = struct {
    allocator: std.mem.Allocator,
    head_oid: []u8,
    base_oid: []u8,
    files: std.ArrayList(File) = .empty,
    threads: std.ArrayList(ReviewThread) = .empty,

    pub fn init(allocator: std.mem.Allocator, head_oid: []const u8) !PrGeneration {
        return initFull(allocator, "unknown-base", head_oid);
    }
    pub fn initFull(allocator: std.mem.Allocator, base_oid: []const u8, head_oid: []const u8) !PrGeneration {
        return .{ .allocator = allocator, .head_oid = try allocator.dupe(u8, head_oid), .base_oid = try allocator.dupe(u8, base_oid) };
    }

    pub fn deinit(self: *PrGeneration) void {
        for (self.files.items) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.revision_key);
            self.allocator.free(file.change_type);
        }
        self.files.deinit(self.allocator);
        for (self.threads.items) |thread| {
            self.allocator.free(thread.id);
            self.allocator.free(thread.path);
        }
        self.threads.deinit(self.allocator);
        self.allocator.free(self.head_oid);
        self.allocator.free(self.base_oid);
    }

    pub fn addFile(self: *PrGeneration, file: File) !void {
        try self.files.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, file.path),
            .additions = file.additions,
            .deletions = file.deletions,
            .change_type = try self.allocator.dupe(u8, file.change_type),
            .viewed = file.viewed,
            .revision_key = try self.allocator.dupe(u8, file.revision_key),
        });
    }

    pub fn addThread(self: *PrGeneration, thread: ReviewThread) !void {
        try self.threads.append(self.allocator, .{ .id = try self.allocator.dupe(u8, thread.id), .path = try self.allocator.dupe(u8, thread.path), .line = thread.line, .outdated = thread.outdated });
    }

    pub fn queued(self: *const PrGeneration, path: []const u8) bool {
        for (self.files.items) |file| if (std.mem.eql(u8, file.path, path))
            return file.viewed == .unviewed or file.viewed == .dismissed;
        return false;
    }

    pub fn markViewed(self: *PrGeneration, path: []const u8) !void {
        for (self.files.items) |*file| if (std.mem.eql(u8, file.path, path)) {
            file.viewed = .viewed;
            return;
        };
        return error.UnknownFile;
    }

    pub fn setRevision(self: *PrGeneration, path: []const u8, revision: []const u8) !void {
        for (self.files.items) |*file| if (std.mem.eql(u8, file.path, path)) {
            self.allocator.free(file.revision_key);
            file.revision_key = try self.allocator.dupe(u8, revision);
            return;
        };
        return error.UnknownFile;
    }
};

pub fn revisionKey(allocator: std.mem.Allocator, path: []const u8, change_type: []const u8, blob: []const u8, diff: []const u8) ![]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(path);
    hash.update(&.{0});
    hash.update(change_type);
    hash.update(&.{0});
    hash.update(blob);
    hash.update(&.{0});
    hash.update(diff);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.allocPrint(allocator, "sha256:{x}", .{digest});
}

pub fn sameRevision(a: File, b: File) bool {
    return std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.revision_key, b.revision_key);
}
pub fn revisionFor(generation: *const PrGeneration, path: []const u8) ?[]const u8 {
    for (generation.files.items) |file| if (std.mem.eql(u8, file.path, path)) return file.revision_key;
    return null;
}

test "viewed state is the queue" {
    var gen = try PrGeneration.init(std.testing.allocator, "head");
    defer gen.deinit();
    try gen.addFile(.{ .path = "a.zig", .viewed = .dismissed, .revision_key = "r" });
    try std.testing.expect(gen.queued("a.zig"));
    try gen.markViewed("a.zig");
    try std.testing.expect(!gen.queued("a.zig"));
}

test "revision identity includes change type" {
    const a = try revisionKey(std.testing.allocator, "a", "MODIFIED", "blob", "diff");
    defer std.testing.allocator.free(a);
    const b = try revisionKey(std.testing.allocator, "a", "RENAMED", "blob", "diff");
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
