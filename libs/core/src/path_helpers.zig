const std = @import("std");

pub fn expandHomePath(allocator: std.mem.Allocator, home_opt: ?[]const u8, path: []const u8) ![]u8 {
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

pub fn toAbsolutePath(
    allocator: std.mem.Allocator,
    home: ?[]const u8,
    cwd_path: []const u8,
    path: []const u8,
) ![]u8 {
    const expanded = try expandHomePath(allocator, home, path);
    defer allocator.free(expanded);

    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);

    return std.fs.path.join(allocator, &.{ cwd_path, expanded });
}

test "path expansion uses only the supplied home and cwd" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ @as(?[]const u8, "/one"), "/two", "~/file", "/one/file" },
        .{ @as(?[]const u8, "/other"), "/two", "~", "/other" },
        .{ @as(?[]const u8, null), "/two", "child", "/two/child" },
        .{ @as(?[]const u8, null), "/two", "/absolute", "/absolute" },
        .{ @as(?[]const u8, null), "/two", "~name", "/two/~name" },
    };
    inline for (cases) |case| {
        const actual = try toAbsolutePath(allocator, case[0], case[1], case[2]);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(case[3], actual);
    }
    try std.testing.expectError(
        error.EnvironmentVariableNotFound,
        expandHomePath(allocator, null, "~/file"),
    );
}

fn expandWithAllocationFailure(allocator: std.mem.Allocator) !void {
    const path = try toAbsolutePath(allocator, "/home", "/cwd", "~/file");
    defer allocator.free(path);
}

test "path expansion releases intermediate paths on allocation failure" {
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        expandWithAllocationFailure,
        .{},
    );
}
