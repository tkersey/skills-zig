const std = @import("std");

pub fn isClosedPipeError(err: anyerror) bool {
    return err == error.WriteFailed or err == error.BrokenPipe;
}

pub fn writeToStreamAllowBrokenPipe(file: std.fs.File, bytes: []const u8) !void {
    file.writeAll(bytes) catch |err| switch (err) {
        error.BrokenPipe => return,
        else => return err,
    };
}

pub fn writeAllAllowBrokenPipe(file: std.fs.File, bytes: []const u8) !void {
    return writeToStreamAllowBrokenPipe(file, bytes);
}
