const std = @import("std");

/// Narrow source overlay for the pinned upstream revision. The fetched package
/// remains immutable; WriteFile owns a separately hashed generated source tree.
/// Remove this module when upstream includes these Zig 0.17 compatibility fixes.
pub fn apply(b: *std.Build, step: *std.Build.Step) void {
    const run = step.cast(std.Build.Step.Run).?;
    const exe = run.argv.items[0].artifact.artifact;
    const lib = exe.root_module.import_table.get("zlinter").?;
    const upstream = lib.root_source_file.?.src_path.owner;
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(upstream.path("src"), "src", .{
        .exclude_extensions = &.{
            "lib/files.zig", "lib/zon.zig", "exe/common/CliLintConfigStore.zig",
        },
    });
    for (patched_files) |name| {
        var source = readSource(b, upstream, name);
        for (patches) |patch| {
            if (!std.mem.eql(u8, patch.path, name)) continue;
            if (std.mem.count(u8, source, patch.before) != 1) {
                std.debug.panic("zlinter compatibility patch no longer matches {s}", .{name});
            }
            source = std.mem.replaceOwned(u8, b.allocator, source, patch.before, patch.after) catch
                @panic("OOM");
        }
        _ = files.add(name, source);
    }
    const directory = files.getDirectory();
    lib.root_source_file = directory.path(b, "src/lib/zlinter.zig");
    exe.root_module.root_source_file = directory.path(b, "src/exe/cli.zig");
}

fn readSource(b: *std.Build, upstream: *std.Build, name: []const u8) []const u8 {
    b.dependOnFileContents(upstream.path(name));
    const path = upstream.root.join(b.allocator, name) catch @panic("OOM");
    return path.root_dir.handle.readFileAlloc(
        b.graph.io,
        path.sub_path,
        b.allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| std.debug.panic("cannot read zlinter source {s}: {t}", .{ name, err });
}

const Patch = struct { path: []const u8, before: []const u8, after: []const u8 };
const patched_files = [_][]const u8{
    "src/lib/files.zig", "src/lib/zon.zig", "src/exe/common/CliLintConfigStore.zig",
};
const patches = [_]Patch{
    .{
        .path = patched_files[0],
        .before = "                .zig_lib,",
        .after = "                .zig_lib,\n                .libc_runtimes,",
    },
    .{
        .path = patched_files[1],
        .before =
        \\    return try std.zon.parse.fromSliceAlloc(
        \\        T,
        \\        gpa,
        \\        null_terminated,
        \\        diagnostics,
        \\        .{
        \\            .ignore_unknown_fields = false,
        \\            .free_on_error = true,
        \\        },
        \\    );
        ,
        .after =
        \\    var discarded_diagnostics: Diagnostics = undefined;
        \\    return try std.zon.parse.fromSlice(T, .{
        \\        .gpa = gpa,
        \\        .arena = gpa,
        \\        .source = null_terminated,
        \\        .diagnostics = diagnostics orelse &discarded_diagnostics,
        \\        .ignore_unknown_fields = false,
        \\    });
        ,
    },
    .{
        .path = patched_files[1],
        .before = "    var diagnostics = Diagnostics{};",
        .after = "    var diagnostics: Diagnostics = undefined;",
    },
    .{
        .path = patched_files[1],
        .before =
        \\    var it = diagnostics.iterateErrors();
        \\    try std.testing.expect(it.next() != null);
        \\    try std.testing.expect(it.next() == null);
        ,
        .after = "    try std.testing.expectEqual(@as(usize, 1), diagnostics.errors.len);",
    },
    .{
        .path = patched_files[2],
        .before = "        var diagnostics: std.zon.parse.Diagnostics = .{};",
        .after = "        var diagnostics: std.zon.parse.Diagnostics = undefined;",
    },
    .{
        .path = patched_files[2],
        .before =
        \\        zon.* = std.zon.parse.fromSliceAlloc(
        \\            Zon,
        \\            arena,
        \\            source,
        \\            &diagnostics,
        \\            .{},
        \\        ) catch |e| {
        ,
        .after =
        \\        zon.* = std.zon.parse.fromSlice(Zon, .{
        \\            .gpa = arena,
        \\            .arena = arena,
        \\            .source = source,
        \\            .diagnostics = &diagnostics,
        \\        }) catch |e| {
        ,
    },
    .{
        .path = patched_files[2],
        .before = "                    .{ lint_config_abs_path, e, diagnostics },",
        .after = "                    .{ lint_config_abs_path, e, " ++
            "diagnostics.fmt(lint_config_abs_path) },",
    },
};
