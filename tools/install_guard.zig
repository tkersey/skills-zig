const std = @import("std");

/// Install paths are make-time inputs in Zig 0.17. Check them on every install,
/// before any artifact is copied, including when configuration is cached.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.InvalidInstallGuardArguments;
    validate(
        init.arena.allocator(),
        args[1],
        args[2],
        args[3],
        init.environ_map.get("DESTDIR"),
    ) catch |err| {
        var writer = std.Io.File.stderr().writerStreaming(init.io, &.{});
        try writer.interface.print(
            "skills-zig forbids external installs; use the Homebrew tap release flow: {t}\n",
            .{err},
        );
        try writer.interface.flush();
        std.process.exit(1);
    };
}

fn validate(
    allocator: std.mem.Allocator,
    expected: []const u8,
    prefix: []const u8,
    bin: []const u8,
    destdir: ?[]const u8,
) !void {
    if (destdir != null) return error.ExternalInstallForbidden;
    const expected_prefix = try std.fs.path.resolve(allocator, &.{expected});
    defer allocator.free(expected_prefix);
    const actual_prefix = try std.fs.path.resolve(allocator, &.{prefix});
    defer allocator.free(actual_prefix);
    const expected_bin = try std.fs.path.resolve(allocator, &.{ expected, "bin" });
    defer allocator.free(expected_bin);
    const actual_bin = try std.fs.path.resolve(allocator, &.{bin});
    defer allocator.free(actual_bin);
    if (!std.mem.eql(u8, expected_prefix, actual_prefix) or
        !std.mem.eql(u8, expected_bin, actual_bin)) return error.ExternalInstallForbidden;
}

test "install admission accepts only the local prefix and executable directory" {
    const allocator = std.testing.allocator;
    try validate(allocator, "/repo/zig-out", "/repo/zig-out", "/repo/zig-out/bin", null);
    try std.testing.expectError(
        error.ExternalInstallForbidden,
        validate(allocator, "/repo/zig-out", "/usr/local", "/usr/local/bin", null),
    );
    try std.testing.expectError(
        error.ExternalInstallForbidden,
        validate(allocator, "/repo/zig-out", "/repo/zig-out", "/usr/local/bin", null),
    );
    try std.testing.expectError(
        error.ExternalInstallForbidden,
        validate(allocator, "/repo/zig-out", "/repo/zig-out", "/repo/zig-out/bin", ""),
    );
}
