const std = @import("std");

pub fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn readStdinAlloc(allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var reader = std.Io.File.stdin().reader(defaultIo(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.StreamTooLong,
        else => err,
    };
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(max_bytes));
}

pub fn realPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), path, allocator);
}

pub fn isClosedPipeError(err: anyerror) bool {
    return err == error.WriteFailed or err == error.BrokenPipe;
}

pub fn writeToStreamAllowBrokenPipe(file: std.Io.File, bytes: []const u8) !void {
    file.writeStreamingAll(defaultIo(), bytes) catch |err| switch (err) {
        error.BrokenPipe => return,
        else => return err,
    };
}

pub fn writeAllAllowBrokenPipe(file: std.Io.File, bytes: []const u8) !void {
    return writeToStreamAllowBrokenPipe(file, bytes);
}
