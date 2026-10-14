const std = @import("std");

/// Borrows the process capabilities for one automation operation. The caller
/// keeps the directory, cwd path, and environment alive until it completes.
/// SQLite accepts a path rather than a directory handle, so cwd_path must name
/// cwd when a relative database path is supplied.
pub const Operation = struct {
    io: std.Io,
    cwd: std.Io.Dir,
    cwd_path: []const u8,
    environment: *const std.process.Environ.Map,
    automation_root: ?[]const u8 = null,
};
