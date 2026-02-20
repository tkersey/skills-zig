const std = @import("std");

pub fn expandHomePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "~")) {
        return std.process.getEnvVarOwned(allocator, "HOME");
    }
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    return allocator.dupe(u8, path);
}

pub fn toAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const expanded = try expandHomePath(allocator, path);
    defer allocator.free(expanded);

    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, expanded });
}
