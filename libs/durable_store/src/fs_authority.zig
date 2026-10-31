const std = @import("std");

/// Borrowed I/O and directory authority. The caller keeps the directory and
/// I/O implementation alive through every operation, scan and lock release.
/// Construction does not admit a path or replace per-operation identity checks.
pub const Fs = struct {
    io: std.Io,
    read_budget: ?*ReadBudget = null,
    root: union(enum) { cwd: std.Io.Dir, pinned: std.Io.Dir },

    pub fn init(io: std.Io, dir: std.Io.Dir) Fs {
        return .{ .io = io, .root = .{ .cwd = dir } };
    }

    pub fn anchored(io: std.Io, dir: std.Io.Dir) Fs {
        return .{ .io = io, .root = .{ .pinned = dir } };
    }

    pub fn reanchor(self: Fs, dir: std.Io.Dir) Fs {
        return .{ .io = self.io, .root = .{ .pinned = dir }, .read_budget = self.read_budget };
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

pub const ReadBudget = struct {
    max_bytes: usize,
    max_files: usize,
    bytes: usize = 0,
    files: usize = 0,

    pub fn begin(self: *ReadBudget) !void {
        std.debug.assert(self.files <= self.max_files);
        if (self.files == self.max_files) return error.ReadFileBudgetExceeded;
        self.files += 1;
    }
};

pub const FileRead = struct {
    fs: Fs,
    file: std.Io.File,
    max_bytes: usize,
    offset: usize = 0,
    failure: ?anyerror = null,
    interface: std.Io.Reader = .{
        .vtable = &.{ .stream = stream },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    },

    pub fn init(fs: Fs, file: std.Io.File, max_bytes: usize) !FileRead {
        if (fs.read_budget) |budget| try budget.begin();
        return initCounted(fs, file, max_bytes);
    }

    pub fn initCounted(fs: Fs, file: std.Io.File, max_bytes: usize) !FileRead {
        if (fs.read_budget) |budget| {
            const stat = try file.stat(fs.io);
            if (stat.kind != .file) return error.NotFile;
            if (stat.size > max_bytes) return error.FileTooBig;
            std.debug.assert(budget.bytes <= budget.max_bytes);
            if (stat.size > budget.max_bytes - budget.bytes) return error.ReadBudgetExceeded;
        }
        return .{ .fs = fs, .file = file, .max_bytes = max_bytes };
    }

    pub fn read(self: *FileRead, buffer: []u8) !usize {
        std.debug.assert(buffer.len > 0);
        var request = buffer.len;
        if (self.fs.read_budget) |budget| {
            if (self.offset > self.max_bytes) return error.FileTooBig;
            const remaining = budget.max_bytes - budget.bytes;
            if (remaining == 0) {
                const stat = try self.file.stat(self.fs.io);
                if (stat.kind == .file and stat.size <= self.offset) return 0;
                return error.ReadBudgetExceeded;
            }
            request = @min(request, @min(remaining, self.max_bytes - self.offset +| 1));
        }
        const count = try self.file.readPositional(self.fs.io, &.{buffer[0..request]}, self.offset);
        if (self.fs.read_budget) |budget| budget.bytes += count;
        self.offset = std.math.add(usize, self.offset, count) catch return error.FileTooBig;
        return count;
    }

    pub fn alloc(self: *FileRead, allocator: std.mem.Allocator) ![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        var buffer: [16 * 1024]u8 = undefined;
        while (bytes.items.len <= self.max_bytes) {
            const count = try self.read(&buffer);
            if (count == 0) return bytes.toOwnedSlice(allocator);
            if (count > self.max_bytes - bytes.items.len) return error.FileTooBig;
            try bytes.appendSlice(allocator, buffer[0..count]);
        }
        unreachable;
    }

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *FileRead = @fieldParentPtr("interface", reader);
        const buffer = limit.slice(try writer.writableSliceGreedy(1));
        if (buffer.len == 0) return 0;
        const count = self.read(buffer) catch |err| {
            self.failure = err;
            return error.ReadFailed;
        };
        if (count == 0) return error.EndOfStream;
        writer.advance(count);
        return count;
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
