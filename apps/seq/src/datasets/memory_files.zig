const std = @import("std");
const core_path = @import("core_path");

pub const Options = struct {
    include_preview: bool = false,
    memory_root: ?[]const u8 = null,
};

pub const Row = struct {
    path: []u8,
    relative_path: []u8,
    name: []u8,
    category: []u8,
    extension: []u8,
    size_bytes: u64,
    modified_at: []u8,
    preview: ?[]u8 = null,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.relative_path);
        allocator.free(self.name);
        allocator.free(self.category);
        allocator.free(self.extension);
        allocator.free(self.modified_at);
        if (self.preview) |v| allocator.free(v);
    }
};

pub const RowList = std.ArrayList(Row);

pub const Iterator = struct {
    rows: []const Row,
    index: usize = 0,

    pub fn next(self: *Iterator) ?Row {
        if (self.index >= self.rows.len) return null;
        defer self.index += 1;
        return self.rows[self.index];
    }
};

pub fn iter(rows: []const Row) Iterator {
    return .{ .rows = rows };
}

pub fn deinitRows(allocator: std.mem.Allocator, rows: *RowList) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

pub fn collect(allocator: std.mem.Allocator, options: Options) !RowList {
    var rows = RowList.empty;
    errdefer deinitRows(allocator, &rows);

    const root_abs = try resolveMemoryRoot(allocator, options.memory_root);
    defer allocator.free(root_abs);

    var rel_paths = try collectFilePaths(allocator, root_abs);
    defer {
        for (rel_paths.items) |path| allocator.free(path);
        rel_paths.deinit(allocator);
    }

    for (rel_paths.items) |relative_path| {
        const absolute_path = try std.fs.path.join(allocator, &.{ root_abs, relative_path });
        defer allocator.free(absolute_path);

        const file = std.fs.openFileAbsolute(absolute_path, .{}) catch continue;
        defer file.close();

        const stat = file.stat() catch continue;

        const base_name = std.fs.path.basename(relative_path);
        const category = if (std.mem.indexOfScalar(u8, relative_path, '/')) |sep| relative_path[0..sep] else "root";

        var row = Row{
            .path = try allocator.dupe(u8, absolute_path),
            .relative_path = try allocator.dupe(u8, relative_path),
            .name = try allocator.dupe(u8, base_name),
            .category = try allocator.dupe(u8, category),
            .extension = try allocator.dupe(u8, fileExtension(base_name)),
            .size_bytes = stat.size,
            .modified_at = try std.fmt.allocPrint(allocator, "{d}", .{stat.mtime}),
        };
        errdefer row.deinit(allocator);

        if (options.include_preview) {
            row.preview = try readPreview(allocator, absolute_path);
        }

        try rows.append(allocator, row);
    }

    return rows;
}

fn resolveMemoryRoot(allocator: std.mem.Allocator, override_root: ?[]const u8) ![]u8 {
    if (override_root) |path| {
        return toAbsolutePath(allocator, path);
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".codex", "memories" });
}

fn toAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const expanded = try expandHomePath(allocator, path);
    defer allocator.free(expanded);

    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, expanded });
}

fn expandHomePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return core_path.expandHomePath(allocator, path);
}

fn collectFilePaths(allocator: std.mem.Allocator, root_abs: []const u8) !std.ArrayList([]u8) {
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    var root_dir = std.fs.openDirAbsolute(root_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out,
        else => return err,
    };
    defer root_dir.close();

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.path));
    }

    std.mem.sort([]u8, out.items, {}, lessThanString);
    return out;
}

fn lessThanString(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn fileExtension(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    return name[dot..];
}

fn readPreview(allocator: std.mem.Allocator, absolute_path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(absolute_path, .{}) catch return allocator.dupe(u8, "");
    defer file.close();

    const content = file.readToEndAlloc(allocator, 8 * 1024) catch return allocator.dupe(u8, "");
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        return allocator.dupe(u8, trimmed[0..@min(trimmed.len, 200)]);
    }

    return allocator.dupe(u8, "");
}
