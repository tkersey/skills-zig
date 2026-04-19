const std = @import("std");

pub fn expandHomePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const home_opt = std.Io.Threaded.global_single_threaded.environString("HOME");
    if (std.mem.eql(u8, path, "~")) {
        const home = home_opt orelse return error.EnvironmentVariableNotFound;
        return allocator.dupe(u8, home);
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = home_opt orelse return error.EnvironmentVariableNotFound;
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    return allocator.dupe(u8, path);
}

pub fn toAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const expanded = try expandHomePath(allocator, path);
    defer allocator.free(expanded);

    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);

    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, expanded });
}
