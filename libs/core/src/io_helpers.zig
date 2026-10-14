const std = @import("std");

pub fn readStdinAlloc(io: std.Io, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var reader = std.Io.File.stdin().reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

pub fn readFileAlloc(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return dir.readFileAlloc(io, path, allocator, .limited(max_bytes));
}

pub fn realPathAlloc(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    path: []const u8,
) ![:0]u8 {
    return dir.realPathFileAlloc(io, path, allocator);
}

pub fn isClosedPipeError(err: anyerror) bool {
    return err == error.BrokenPipe;
}

/// For terminal output only: callers that have subsequent effects must propagate
/// BrokenPipe themselves so a closed reader stops those effects.
pub fn writeToStreamAllowBrokenPipe(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    file.writeStreamingAll(io, bytes) catch |err| switch (err) {
        error.BrokenPipe => return,
        else => return err,
    };
}

pub fn writeAllAllowBrokenPipe(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    return writeToStreamAllowBrokenPipe(io, file, bytes);
}

test "only a proven broken pipe is a closed reader" {
    try std.testing.expect(isClosedPipeError(error.BrokenPipe));
    try std.testing.expect(!isClosedPipeError(error.WriteFailed));
    try std.testing.expect(!isClosedPipeError(error.AccessDenied));
}

test "filesystem helpers retain the supplied directory authority" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    try first.dir.writeFile(io, .{ .sub_path = "same", .data = "first" });
    try second.dir.writeFile(io, .{ .sub_path = "same", .data = "second" });
    const first_bytes = try readFileAlloc(io, first.dir, allocator, "same", 32);
    defer allocator.free(first_bytes);
    const second_bytes = try readFileAlloc(io, second.dir, allocator, "same", 32);
    defer allocator.free(second_bytes);
    try std.testing.expectEqualStrings("first", first_bytes);
    try std.testing.expectEqualStrings("second", second_bytes);
    const first_path = try realPathAlloc(io, first.dir, allocator, "same");
    defer allocator.free(first_path);
    const second_path = try realPathAlloc(io, second.dir, allocator, "same");
    defer allocator.free(second_path);
    try std.testing.expect(!std.mem.eql(u8, first_path, second_path));
}

test "filesystem helpers propagate supplied I/O cancellation" {
    const Canceled = struct {
        fn open(
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: std.Io.Dir.OpenFileOptions,
        ) std.Io.File.OpenError!std.Io.File {
            return error.Canceled;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.dirOpenFile = Canceled.open;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(
        error.Canceled,
        readFileAlloc(io, std.Io.Dir.cwd(), std.testing.allocator, "unused", 32),
    );
}

test "terminal writes use supplied I/O and swallow only broken pipe" {
    const ClosedReader = struct {
        fn operate(_: ?*anyopaque, op: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            return switch (op) {
                .file_write_streaming => .{ .file_write_streaming = error.BrokenPipe },
                else => unreachable,
            };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.operate = ClosedReader.operate;
    const io: std.Io = .{ .userdata = null, .vtable = &vtable };
    try writeToStreamAllowBrokenPipe(io, std.Io.File.stdout(), "closed");
    try writeAllAllowBrokenPipe(io, std.Io.File.stdout(), "closed");
    try std.testing.expectError(
        error.InputOutput,
        writeToStreamAllowBrokenPipe(std.Io.failing, std.Io.File.stdout(), "failed"),
    );
    try std.testing.expectError(
        error.InputOutput,
        writeAllAllowBrokenPipe(std.Io.failing, std.Io.File.stdout(), "failed"),
    );
}
