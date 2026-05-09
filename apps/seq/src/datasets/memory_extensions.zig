const std = @import("std");
const core_path = @import("core_path");

pub const Options = struct {
    extensions_root: ?[]const u8 = null,
};

pub const Row = struct {
    extension_name: []u8,
    instructions_path: ?[]u8 = null,
    has_instructions: bool,
    modified_at: ?[]u8 = null,
    size_bytes: ?u64 = null,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.extension_name);
        if (self.instructions_path) |value| allocator.free(value);
        if (self.modified_at) |value| allocator.free(value);
    }
};

pub const RowList = std.ArrayList(Row);

pub fn deinitRows(allocator: std.mem.Allocator, rows: *RowList) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

pub fn collect(allocator: std.mem.Allocator, options: Options) !RowList {
    var rows: RowList = .empty;
    errdefer deinitRows(allocator, &rows);

    const root_abs = try resolveExtensionsRoot(allocator, options.extensions_root);
    defer allocator.free(root_abs);

    var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), root_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return rows,
        else => return err,
    };
    defer dir.close(std.Io.Threaded.global_single_threaded.io());

    var iter = dir.iterate();
    while (try iter.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .directory) continue;

        const instructions_abs = try std.fs.path.join(allocator, &.{ root_abs, entry.name, "instructions.md" });
        defer allocator.free(instructions_abs);

        const instructions_file = std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), instructions_abs, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => return err,
        };

        var row = Row{
            .extension_name = try allocator.dupe(u8, entry.name),
            .has_instructions = instructions_file != null,
        };
        errdefer row.deinit(allocator);

        if (instructions_file) |file| {
            defer file.close(std.Io.Threaded.global_single_threaded.io());
            const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
            row.instructions_path = try allocator.dupe(u8, instructions_abs);
            row.modified_at = try std.fmt.allocPrint(allocator, "{d}", .{stat.mtime});
            row.size_bytes = stat.size;
        }

        try rows.append(allocator, row);
    }

    std.mem.sort(Row, rows.items, {}, lessThanExtensionName);
    return rows;
}

fn resolveExtensionsRoot(allocator: std.mem.Allocator, override_root: ?[]const u8) ![]u8 {
    if (override_root) |path| return toAbsolutePath(allocator, path);

    const home = std.Io.Threaded.global_single_threaded.environString("HOME") orelse return error.EnvironmentVariableNotFound;
    return std.fs.path.join(allocator, &.{ home, ".codex", "memories", "extensions" });
}

fn toAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const expanded = try core_path.expandHomePath(allocator, path);
    defer allocator.free(expanded);

    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);

    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, expanded });
}

fn lessThanExtensionName(_: void, a: Row, b: Row) bool {
    return std.mem.order(u8, a.extension_name, b.extension_name) == .lt;
}

test "collect returns extension rows including missing instructions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "harness");
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "empty");
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "harness/instructions.md",
        .data = "# Harness\n",
    });

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);

    var rows = try collect(std.testing.allocator, .{ .extensions_root = root_abs });
    defer deinitRows(std.testing.allocator, &rows);

    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("empty", rows.items[0].extension_name);
    try std.testing.expect(!rows.items[0].has_instructions);
    try std.testing.expect(rows.items[0].instructions_path == null);
    try std.testing.expectEqualStrings("harness", rows.items[1].extension_name);
    try std.testing.expect(rows.items[1].has_instructions);
    try std.testing.expect(rows.items[1].instructions_path != null);
}

test "default root points at Codex memories extensions" {
    const root = try resolveExtensionsRoot(std.testing.allocator, null);
    defer std.testing.allocator.free(root);

    try std.testing.expect(std.mem.endsWith(u8, root, "/.codex/memories/extensions"));
}
