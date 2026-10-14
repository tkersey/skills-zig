const std = @import("std");

/// Borrowed I/O and directory authority. The caller keeps the directory and
/// I/O implementation alive through every operation, scan and lock release.
/// Construction does not admit a path or replace per-operation identity checks.
pub const Fs = struct {
    io: std.Io,
    root: union(enum) { cwd: std.Io.Dir, pinned: std.Io.Dir },

    pub fn init(io: std.Io, dir: std.Io.Dir) Fs {
        return .{ .io = io, .root = .{ .cwd = dir } };
    }

    pub fn anchored(io: std.Io, dir: std.Io.Dir) Fs {
        return .{ .io = io, .root = .{ .pinned = dir } };
    }

    pub fn directory(self: Fs) std.Io.Dir {
        return switch (self.root) {
            .cwd, .pinned => |dir| dir,
        };
    }

    pub fn isPinned(self: Fs) bool {
        return self.root == .pinned;
    }
};

/// Cleanup diagnostics use the same I/O implementation as the failed operation.
/// A failed diagnostic cannot replace the operation's original result.
pub fn warn(io: std.Io, comptime format: []const u8, args: anytype) void {
    if (comptime !std.log.logEnabled(.warn, .default)) return;
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    var buffer: [256]u8 = undefined;
    const stderr = (io.lockStderr(&buffer, null) catch return).terminal();
    defer io.unlockStderr();
    std.log.defaultLogFileTerminal(.warn, .default, format, args, stderr) catch return;
}

const DiagnosticCapture = struct {
    bytes: [1024]u8 = undefined,
    len: usize = 0,
    writer: std.Io.File.Writer = undefined,
    protection: std.Io.CancelProtection = .unblocked,
    locks: usize = 0,
    unlocks: usize = 0,
    fn append(self: *@This(), bytes: []const u8) void {
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    fn writeStreaming(
        context: ?*anyopaque,
        _: std.Io.File,
        header: []const u8,
        data: []const []const u8,
        splat: usize,
    ) usize {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const before = self.len;
        self.append(header);
        if (data.len != 0) {
            for (data[0 .. data.len - 1]) |bytes| self.append(bytes);
            for (0..splat) |_| self.append(data[data.len - 1]);
        }
        return self.len - before;
    }
    fn writePositional(
        context: ?*anyopaque,
        file: std.Io.File,
        header: []const u8,
        data: []const []const u8,
        splat: usize,
        offset: u64,
    ) std.Io.File.WritePositionalError!usize {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const end = self.len;
        self.len = @intCast(offset);
        const written = writeStreaming(context, file, header, data, splat);
        self.len = @max(self.len, end);
        return written;
    }
    fn operate(
        context: ?*anyopaque,
        operation: std.Io.Operation,
    ) std.Io.Cancelable!std.Io.Operation.Result {
        const write = operation.file_write_streaming;
        return .{ .file_write_streaming = writeStreaming(
            context,
            write.file,
            write.header,
            write.data,
            write.splat,
        ) };
    }
    fn lock(
        context: ?*anyopaque,
        _: ?std.Io.Terminal.Mode,
    ) std.Io.Cancelable!std.Io.LockedStderr {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.protection == .blocked);
        self.locks += 1;
        return .{ .file_writer = &self.writer, .terminal_mode = .no_color };
    }
    fn unlock(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.writer.interface.flush() catch |err| {
            std.debug.panic("diagnostic fixture flush: {s}", .{@errorName(err)});
        };
        self.writer.interface.buffer = &.{};
        self.unlocks += 1;
    }
    fn protect(
        context: ?*anyopaque,
        protection: std.Io.CancelProtection,
    ) std.Io.CancelProtection {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const previous = self.protection;
        self.protection = protection;
        return previous;
    }
};

test "cleanup diagnostics preserve preceding output through supplied locked stderr" {
    var capture = DiagnosticCapture{};
    var vtable = std.testing.io.vtable.*;
    vtable.fileWritePositional = DiagnosticCapture.writePositional;
    vtable.operate = DiagnosticCapture.operate;
    vtable.lockStderr = DiagnosticCapture.lock;
    vtable.unlockStderr = DiagnosticCapture.unlock;
    vtable.swapCancelProtection = DiagnosticCapture.protect;
    const io: std.Io = .{ .userdata = &capture, .vtable = &vtable };
    capture.writer = std.Io.File.stderr().writerStreaming(io, &.{});
    capture.append("earlier diagnostic\n");
    warn(
        io,
        "lock release failed for {s}: {s}; inspect and remove stale lock",
        .{ "events.lock", "AccessDenied" },
    );
    warn(io, "second warning", .{});
    try std.testing.expectEqualStrings(
        "earlier diagnostic\nwarning: lock release failed for events.lock: Acce" ++
            "ssDenied; inspect and remove stale lock\nwarning: second warning\n",
        capture.bytes[0..capture.len],
    );
    try std.testing.expectEqual(@as(usize, 2), capture.locks);
    try std.testing.expectEqual(capture.locks, capture.unlocks);
    try std.testing.expectEqual(std.Io.CancelProtection.unblocked, capture.protection);
}
