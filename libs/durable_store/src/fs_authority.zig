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
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    stderr.interface.print("warning: " ++ format ++ "\n", args) catch return;
    stderr.interface.flush() catch {};
}

test "cleanup diagnostics write through the supplied I/O implementation" {
    const Capture = struct {
        bytes: [1024]u8 = undefined,
        len: usize = 0,
        fn append(self: *@This(), bytes: []const u8) void {
            @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }
        fn write(context: ?*anyopaque, _: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, _: u64) std.Io.File.WritePositionalError!usize {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const before = self.len;
            self.append(header);
            if (data.len != 0) {
                for (data[0 .. data.len - 1]) |bytes| self.append(bytes);
                for (0..splat) |_| self.append(data[data.len - 1]);
            }
            return self.len - before;
        }
        fn protect(_: ?*anyopaque, _: std.Io.CancelProtection) std.Io.CancelProtection {
            return .unblocked;
        }
    };
    var capture = Capture{};
    var vtable = std.testing.io.vtable.*;
    vtable.fileWritePositional = Capture.write;
    vtable.swapCancelProtection = Capture.protect;
    warn(.{ .userdata = &capture, .vtable = &vtable }, "lock release failed for {s}: {s}; inspect and remove stale lock", .{ "events.lock", "AccessDenied" });
    try std.testing.expectEqualStrings("warning: lock release failed for events.lock: AccessDenied; inspect and remove stale lock\n", capture.bytes[0..capture.len]);
}
