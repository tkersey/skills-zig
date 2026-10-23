const std = @import("std");
const durable_store = @import("durable_store");

pub const note_bytes_max = 1024 * 1024;
pub const note_count_max = 10_000;
const scratch_retained_bytes_max = 8 * note_bytes_max;

pub const MissingDirectory = enum { empty, fail };

pub const Record = struct {
    path: []const u8,
    raw: []const u8,
};

pub const Reader = struct {
    fs: durable_store.Fs,
    allocator: std.mem.Allocator,
    directory: []const u8,
    names: []const []u8,
    scratch: std.heap.ArenaAllocator,

    pub fn open(
        fs: durable_store.Fs,
        allocator: std.mem.Allocator,
        directory: []const u8,
        missing: MissingDirectory,
    ) !Reader {
        const names = durable_store.listSortedRegularFilesNoSymlink(
            fs,
            allocator,
            directory,
            note_count_max,
            note_bytes_max,
        ) catch |err| switch (err) {
            error.FileNotFound => if (missing == .empty) &.{} else return err,
            else => return err,
        };
        return .{
            .fs = fs,
            .allocator = allocator,
            .directory = directory,
            .names = names,
            .scratch = .init(allocator),
        };
    }

    pub fn deinit(self: *Reader) void {
        self.scratch.deinit();
        durable_store.freeStringList(self.allocator, self.names);
        self.* = undefined;
    }

    pub fn readBorrowed(self: *Reader, index: usize) !Record {
        std.debug.assert(index < self.names.len);
        if (!self.scratch.reset(.{ .retain_with_limit = scratch_retained_bytes_max }))
            return error.OutOfMemory;
        const allocator = self.scratch.allocator();
        const path = try std.fs.path.join(allocator, &.{ self.directory, self.names[index] });
        const raw = try durable_store.readRegularFileNoSymlink(
            self.fs,
            allocator,
            path,
            note_bytes_max,
        );
        return .{ .path = path, .raw = raw };
    }

    pub fn parseBorrowed(self: *Reader, record: Record) !std.json.Value {
        return std.json.parseFromSliceLeaky(
            std.json.Value,
            self.scratch.allocator(),
            record.raw,
            .{},
        );
    }
};

test "inventory preserves ordering and rereads authoritative bytes between visits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "z.md", .data = "{\"id\":\"last\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "{\"id\":\"first\"}" });
    var reader = try Reader.open(durable_store.Fs.init(io, tmp.dir), allocator, ".", .fail);
    defer reader.deinit();
    try std.testing.expectEqual(@as(usize, 2), reader.names.len);
    try std.testing.expectEqualStrings("a.md", reader.names[0]);
    const first = try reader.readBorrowed(0);
    const value = try reader.parseBorrowed(first);
    const retained = try allocator.dupe(u8, value.object.get("id").?.string);
    defer allocator.free(retained);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "{\"id\":\"fresh\"}" });
    const refreshed = try reader.parseBorrowed(try reader.readBorrowed(0));
    try std.testing.expectEqualStrings("fresh", refreshed.object.get("id").?.string);
    try std.testing.expectEqualStrings("first", retained);
    const last = try reader.parseBorrowed(try reader.readBorrowed(1));
    try std.testing.expectEqualStrings("last", last.object.get("id").?.string);
}

test "inventory reuses bounded scratch across equal-sized parsed notes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "note.md",
        .data = "{\"id\":\"same\",\"payload\":{\"entries\":[1,2,3,4]}}",
    });
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var reader = try Reader.open(
        durable_store.Fs.init(io, tmp.dir),
        counted.allocator(),
        ".",
        .fail,
    );
    defer reader.deinit();
    for (0..3) |_| _ = try reader.parseBorrowed(try reader.readBorrowed(0));
    const allocations = counted.alloc_index;
    const bytes = counted.allocated_bytes;
    for (0..32) |_| {
        const value = try reader.parseBorrowed(try reader.readBorrowed(0));
        try std.testing.expectEqualStrings("same", value.object.get("id").?.string);
    }
    try std.testing.expectEqual(allocations, counted.alloc_index);
    try std.testing.expectEqual(bytes, counted.allocated_bytes);
    try std.testing.expect(reader.scratch.queryCapacity() <= scratch_retained_bytes_max);
}

test "inventory preserves invalid JSON errors and later valid reads" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.md", .data = "{broken}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "valid.md", .data = "{}" });
    var reader = try Reader.open(durable_store.Fs.init(io, tmp.dir), allocator, ".", .fail);
    defer reader.deinit();
    try std.testing.expectError(
        error.SyntaxError,
        reader.parseBorrowed(try reader.readBorrowed(0)),
    );
    const valid = try reader.parseBorrowed(try reader.readBorrowed(1));
    try std.testing.expect(valid == .object);
}

test "inventory retains caller missing-directory and symlink policies" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fs = durable_store.Fs.init(io, tmp.dir);
    var empty = try Reader.open(fs, allocator, "missing", .empty);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.names.len);
    try std.testing.expectError(error.FileNotFound, Reader.open(fs, allocator, "missing", .fail));
    try tmp.dir.writeFile(io, .{ .sub_path = "note.md", .data = "{}" });
    var reader = try Reader.open(fs, allocator, ".", .fail);
    defer reader.deinit();
    try tmp.dir.deleteFile(io, "note.md");
    try tmp.dir.symLink(io, "missing", "note.md", .{});
    try std.testing.expectError(error.SymlinkComponent, reader.readBorrowed(0));
}

fn readInventoryWithAllocator(allocator: std.mem.Allocator, fs: durable_store.Fs) !void {
    var reader = try Reader.open(fs, allocator, ".", .fail);
    defer reader.deinit();
    for (0..3) |_| {
        for (0..reader.names.len) |index| {
            const value = try reader.parseBorrowed(try reader.readBorrowed(index));
            try std.testing.expect(value == .object);
        }
    }
}

test "inventory reset and parsing propagate every allocation failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "{\"id\":\"first\"}" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "b.md",
        .data = "{\"id\":\"second\",\"payload\":{\"items\":[1,2,3,4]}}",
    });
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        readInventoryWithAllocator,
        .{durable_store.Fs.init(io, tmp.dir)},
    );
}
