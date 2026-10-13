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
