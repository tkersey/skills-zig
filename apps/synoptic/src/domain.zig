const std = @import("std");

pub const ViewedState = enum { viewed, unviewed, dismissed };
pub const SessionStatus = enum { current, stale_origin, completed, closed };

pub const File = struct {
    path: []const u8,
    additions: u32 = 0,
    deletions: u32 = 0,
    viewed: ViewedState,
    revision_key: []const u8,
};

pub const PrGeneration = struct {
    allocator: std.mem.Allocator,
    head_oid: []u8,
    files: std.ArrayList(File) = .empty,

    pub fn init(allocator: std.mem.Allocator, head_oid: []const u8) !PrGeneration {
        return .{ .allocator = allocator, .head_oid = try allocator.dupe(u8, head_oid) };
    }

    pub fn deinit(self: *PrGeneration) void {
        for (self.files.items) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.revision_key);
        }
        self.files.deinit(self.allocator);
        self.allocator.free(self.head_oid);
    }

    pub fn addFile(self: *PrGeneration, file: File) !void {
        try self.files.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, file.path),
            .additions = file.additions,
            .deletions = file.deletions,
            .viewed = file.viewed,
            .revision_key = try self.allocator.dupe(u8, file.revision_key),
        });
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
};

pub fn revisionKey(allocator: std.mem.Allocator, path: []const u8, blob: []const u8, diff: []const u8) ![]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(path); hash.update(&.{0}); hash.update(blob); hash.update(&.{0}); hash.update(diff);
    var digest: [32]u8 = undefined; hash.final(&digest);
    return std.fmt.allocPrint(allocator, "sha256:{x}", .{digest});
}

test "viewed state is the queue" {
    var gen = try PrGeneration.init(std.testing.allocator, "head"); defer gen.deinit();
    try gen.addFile(.{ .path = "a.zig", .viewed = .dismissed, .revision_key = "r" });
    try std.testing.expect(gen.queued("a.zig"));
    try gen.markViewed("a.zig");
    try std.testing.expect(!gen.queued("a.zig"));
}
