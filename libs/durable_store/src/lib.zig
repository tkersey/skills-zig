const std = @import("std");

const Io = std.Io.Threaded.global_single_threaded;

pub const JsonlIssue = struct {
    line: usize,
    message: []const u8,
};

pub const JsonlValidation = struct {
    lines: usize = 0,
    blank_lines: usize = 0,
    first_issue: ?JsonlIssue = null,

    pub fn ok(self: JsonlValidation) bool {
        return self.first_issue == null;
    }
};

pub const CreateNewOptions = struct {
    reject_symlinks: bool = true,
    file_mode: ?u32 = 0o600,
    sync: bool = true,
};

pub fn lockPathAlloc(allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.lock", .{store_path});
}

pub fn fileExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(Io.io(), path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(Io.io(), path, .{}) catch return false;
    return true;
}

pub fn fileSize(path: []const u8) !u64 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(Io.io(), path, .{})
    else
        try std.Io.Dir.cwd().openFile(Io.io(), path, .{});
    defer file.close(Io.io());

    const stat = try file.stat(Io.io());
    return stat.size;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(Io.io(), path, .{})
    else
        try std.Io.Dir.cwd().openFile(Io.io(), path, .{});
    defer file.close(Io.io());

    var reader = file.reader(Io.io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

pub fn ensureParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;

    if (std.fs.path.isAbsolute(parent)) {
        const rel = std.mem.trim(u8, parent, "/");
        if (rel.len == 0) return;
        var root = try std.Io.Dir.openDirAbsolute(Io.io(), "/", .{});
        defer root.close(Io.io());
        try root.createDirPath(Io.io(), rel);
        return;
    }

    try std.Io.Dir.cwd().createDirPath(Io.io(), parent);
}

pub fn rejectSymlinkComponents(path: []const u8) !void {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        const stat = std.Io.Dir.cwd().statFile(Io.io(), component.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
    }
}

pub fn ensureDirectoryPathNoSymlinks(path: []const u8) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return;

    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        const stat = std.Io.Dir.cwd().statFile(Io.io(), component.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.Dir.cwd().createDirPath(Io.io(), component.path);
                const created_stat = try std.Io.Dir.cwd().statFile(Io.io(), component.path, .{ .follow_symlinks = false });
                if (created_stat.kind == .sym_link) return error.SymlinkComponent;
                if (created_stat.kind != .directory) return error.NotDir;
                continue;
            },
            else => return err,
        };
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .directory) return error.NotDir;
    }
}

pub fn readRegularFileNoSymlink(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const stat = try std.Io.Dir.cwd().statFile(Io.io(), path, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) return error.SymlinkComponent;
    if (stat.kind != .file) return error.NotFile;
    if (stat.size > max_bytes) return error.FileTooBig;

    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(Io.io(), path, .{ .allow_directory = false, .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openFile(Io.io(), path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(Io.io());

    var reader = file.reader(Io.io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes + 1));
}

pub fn freeStringList(allocator: std.mem.Allocator, list: []const []u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

pub fn listSortedRegularFilesNoSymlink(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    max_files: usize,
    max_file_bytes: usize,
) ![][]u8 {
    const dir_stat = try std.Io.Dir.cwd().statFile(Io.io(), dir_path, .{ .follow_symlinks = false });
    if (dir_stat.kind == .sym_link) return error.SymlinkComponent;
    if (dir_stat.kind != .directory) return error.NotDir;

    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.Io.Dir.openDirAbsolute(Io.io(), dir_path, .{ .iterate = true, .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), dir_path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(Io.io());

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(Io.io())) |entry| {
        if (entry.kind == .sym_link) return error.SymlinkComponent;
        if (entry.kind != .file) continue;
        if (names.items.len >= max_files) return error.TooManyFiles;

        const entry_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(entry_path);
        const stat = try std.Io.Dir.cwd().statFile(Io.io(), entry_path, .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.SymlinkComponent;
        if (stat.kind != .file) continue;
        if (stat.size > max_file_bytes) return error.FileTooBig;

        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.toOwnedSlice(allocator);
}

fn filePermissionsFromMode(mode: ?u32) std.Io.File.Permissions {
    const Permissions = std.Io.File.Permissions;
    const requested = mode orelse return .default_file;
    if (@hasDecl(Permissions, "fromMode")) {
        return Permissions.fromMode(@as(std.posix.mode_t, @intCast(requested)));
    }
    return .default_file;
}

pub fn writeTextCreateNew(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    options: CreateNewOptions,
) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (parent.len == 0 or base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return error.InvalidPath;
    }
    if (options.reject_symlinks) {
        try ensureDirectoryPathNoSymlinks(parent);
        const existing_stat = std.Io.Dir.cwd().statFile(Io.io(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing_stat) |stat| {
            if (stat.kind == .sym_link) return error.SymlinkComponent;
        }
    } else {
        try ensureParentPath(path);
    }

    var dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(Io.io(), parent, .{ .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(Io.io(), parent, .{ .follow_symlinks = false });
    defer dir.close(Io.io());

    var file = try dir.createFile(Io.io(), base, .{
        .exclusive = true,
        .read = true,
        .truncate = false,
        .permissions = filePermissionsFromMode(options.file_mode),
    });
    var close_file = true;
    errdefer {
        if (close_file) file.close(Io.io());
        dir.deleteFile(Io.io(), base) catch {};
    }
    try file.writeStreamingAll(Io.io(), text);
    if (options.sync) try file.sync(Io.io());
    file.close(Io.io());
    close_file = false;
    _ = allocator;
}

pub fn writeTextAtomic(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    try ensureParentPath(path);

    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse ".";
    const tmp_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.{d}.tmp",
        .{ base, std.Io.Clock.awake.now(Io.io()).nanoseconds },
    );
    defer allocator.free(tmp_name);

    if (std.fs.path.isAbsolute(path)) {
        var dir = try std.Io.Dir.openDirAbsolute(Io.io(), parent, .{});
        defer dir.close(Io.io());
        try writeTempAndRename(&dir, tmp_name, base, text);
        return;
    }

    var dir = try std.Io.Dir.cwd().openDir(Io.io(), parent, .{});
    defer dir.close(Io.io());
    try writeTempAndRename(&dir, tmp_name, base, text);
}

fn writeTempAndRename(dir: *std.Io.Dir, tmp_name: []const u8, base: []const u8, text: []const u8) !void {
    var file = try dir.createFile(Io.io(), tmp_name, .{ .truncate = true, .read = true });
    var close_file = true;
    errdefer if (close_file) file.close(Io.io());
    try file.writeStreamingAll(Io.io(), text);
    try file.sync(Io.io());
    file.close(Io.io());
    close_file = false;
    errdefer dir.deleteFile(Io.io(), tmp_name) catch {};
    try dir.rename(tmp_name, dir.*, base, Io.io());
}

pub fn appendLineAtomic(
    allocator: std.mem.Allocator,
    path: []const u8,
    line: []const u8,
    max_existing_bytes: usize,
) !void {
    const existing = readFileAlloc(allocator, path, max_existing_bytes) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const owns_existing = existing.len > 0 or fileExists(path);
    defer if (owns_existing) allocator.free(existing);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.writer.writeByte('\n');
    try out.writer.writeAll(line);
    try out.writer.writeByte('\n');
    const payload = try out.toOwnedSlice();
    defer allocator.free(payload);
    try writeTextAtomic(allocator, path, payload);
}

pub fn validateJsonl(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) !JsonlValidation {
    const data = readFileAlloc(allocator, path, max_bytes) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(data);
    return validateJsonlBytes(allocator, data);
}

pub fn validateJsonlBytes(allocator: std.mem.Allocator, data: []const u8) JsonlValidation {
    var result = JsonlValidation{};
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) {
            result.blank_lines += 1;
            continue;
        }
        result.lines += 1;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            if (result.first_issue == null) result.first_issue = .{ .line = line_no, .message = "invalid json" };
            continue;
        };
        parsed.deinit();
    }
    return result;
}

pub fn nextMonotonicIdAlloc(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    existing_ids: []const []const u8,
) ![]u8 {
    var max_seen: usize = 0;
    for (existing_ids) |id| {
        const n = parseMonotonicSuffix(prefix, id) orelse continue;
        if (n > max_seen) max_seen = n;
    }
    return std.fmt.allocPrint(allocator, "{s}{d:0>6}", .{ prefix, max_seen + 1 });
}

pub fn parseMonotonicSuffix(prefix: []const u8, id: []const u8) ?usize {
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    if (id.len == prefix.len) return null;
    return std.fmt.parseInt(usize, id[prefix.len..], 10) catch null;
}

pub const LockFile = struct {
    path: []u8,

    pub fn release(self: *LockFile, allocator: std.mem.Allocator) void {
        if (std.fs.path.isAbsolute(self.path)) {
            std.Io.Dir.deleteFileAbsolute(Io.io(), self.path) catch {};
        } else {
            std.Io.Dir.cwd().deleteFile(Io.io(), self.path) catch {};
        }
        allocator.free(self.path);
        self.* = .{ .path = &.{} };
    }
};

pub fn acquireLock(allocator: std.mem.Allocator, store_path: []const u8) !LockFile {
    const path = try lockPathAlloc(allocator, store_path);
    errdefer allocator.free(path);
    try ensureParentPath(path);
    var file = try std.Io.Dir.cwd().createFile(Io.io(), path, .{ .exclusive = true, .read = true, .truncate = false });
    file.close(Io.io());
    return .{ .path = path };
}

pub fn acquireAbsoluteExclusiveLock(allocator: std.mem.Allocator, absolute_path: []const u8) !LockFile {
    if (!std.fs.path.isAbsolute(absolute_path)) return error.NotAbsolute;
    const path = try allocator.dupe(u8, absolute_path);
    errdefer allocator.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try ensureDirectoryPathNoSymlinks(parent);
    const existing_stat = std.Io.Dir.cwd().statFile(Io.io(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing_stat) |stat| {
        if (stat.kind == .sym_link) return error.SymlinkComponent;
    }
    var file = try std.Io.Dir.createFileAbsolute(Io.io(), path, .{ .exclusive = true, .read = true, .truncate = false });
    file.close(Io.io());
    return .{ .path = path };
}

pub fn findGitRootAlloc(allocator: std.mem.Allocator, start: []const u8) ![]u8 {
    var argv = [_][]const u8{ "git", "-C", start, "rev-parse", "--show-toplevel" };
    const result = try std.process.run(allocator, Io.io(), .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.GitCommandFailed;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.GitCommandFailed;
    return allocator.dupe(u8, trimmed);
}

pub fn ensureLockSidecarGitignored(allocator: std.mem.Allocator, store_path: []const u8) !void {
    const parent = std.fs.path.dirname(store_path) orelse ".";
    const git_root = findGitRootAlloc(allocator, parent) catch return;
    defer allocator.free(git_root);

    const lock_path = try lockPathAlloc(allocator, store_path);
    defer allocator.free(lock_path);
    const lock_rel = if (std.fs.path.isAbsolute(lock_path))
        try std.fs.path.relative(allocator, git_root, null, git_root, lock_path)
    else
        try allocator.dupe(u8, lock_path);
    defer allocator.free(lock_rel);

    var argv = [_][]const u8{ "git", "-C", git_root, "check-ignore", "-q", "--", lock_rel };
    const result = try std.process.run(allocator, Io.io(), .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) return;
    if (result.term == .exited and result.term.exited == 1) return error.LockSidecarNotGitignored;
    return error.GitCommandFailed;
}

test "writeTextAtomic creates parent directories and replaces content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "store.jsonl" });
    defer std.testing.allocator.free(path);

    try writeTextAtomic(std.testing.allocator, path, "{\"ok\":true}\n");
    const first = try tryReadForTest(path);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", first);
    try writeTextAtomic(std.testing.allocator, path, "{\"ok\":false}\n");
    const second = try tryReadForTest(path);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"ok\":false}\n", second);
}

test "writeTextCreateNew creates once without overwriting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "note.md" });
    defer std.testing.allocator.free(path);

    try writeTextCreateNew(std.testing.allocator, path, "first", .{});
    try std.testing.expectError(error.PathAlreadyExists, writeTextCreateNew(std.testing.allocator, path, "second", .{}));
    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("first", data);
}

test "writeTextCreateNew rejects symlink parent component" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    try tmp.dir.createDir(Io.io(), "real", .default_dir);
    try tmp.dir.symLink(Io.io(), "real", "link", .{ .is_directory = true });
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "link", "note.md" });
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.SymlinkComponent, writeTextCreateNew(std.testing.allocator, path, "payload", .{}));
}

test "readRegularFileNoSymlink rejects symlink and oversized file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "file.txt" });
    defer std.testing.allocator.free(path);
    const link = try std.fs.path.join(std.testing.allocator, &.{ root, "link.txt" });
    defer std.testing.allocator.free(link);

    try writeTextAtomic(std.testing.allocator, path, "abcd");
    try tmp.dir.symLink(Io.io(), "file.txt", "link.txt", .{});
    const data = try readRegularFileNoSymlink(std.testing.allocator, path, 4);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("abcd", data);
    try std.testing.expectError(error.FileTooBig, readRegularFileNoSymlink(std.testing.allocator, path, 3));
    try std.testing.expectError(error.SymlinkComponent, readRegularFileNoSymlink(std.testing.allocator, link, 4));
}

test "listSortedRegularFilesNoSymlink sorts and rejects symlink entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ root, "notes" });
    defer std.testing.allocator.free(dir_path);
    try ensureDirectoryPathNoSymlinks(dir_path);

    const b = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "b.md" });
    defer std.testing.allocator.free(b);
    const a = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "a.md" });
    defer std.testing.allocator.free(a);
    try writeTextCreateNew(std.testing.allocator, b, "b", .{});
    try writeTextCreateNew(std.testing.allocator, a, "a", .{});

    const names = try listSortedRegularFilesNoSymlink(std.testing.allocator, dir_path, 10, 10);
    defer freeStringList(std.testing.allocator, names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("a.md", names[0]);
    try std.testing.expectEqualStrings("b.md", names[1]);

    var dir = try std.Io.Dir.openDirAbsolute(Io.io(), dir_path, .{});
    defer dir.close(Io.io());
    try dir.symLink(Io.io(), "a.md", "link.md", .{});
    try std.testing.expectError(error.SymlinkComponent, listSortedRegularFilesNoSymlink(std.testing.allocator, dir_path, 10, 10));
}

test "appendLineAtomic appends newline-delimited records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "store.jsonl" });
    defer std.testing.allocator.free(path);

    try appendLineAtomic(std.testing.allocator, path, "{\"n\":1}", 1024);
    try appendLineAtomic(std.testing.allocator, path, "{\"n\":2}", 1024);
    const data = try tryReadForTest(path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"n\":1}\n{\"n\":2}\n", data);
}

test "validateJsonlBytes reports first invalid row" {
    const valid = validateJsonlBytes(std.testing.allocator, "{\"a\":1}\n\n{\"b\":2}\n");
    try std.testing.expect(valid.ok());
    try std.testing.expectEqual(@as(usize, 2), valid.lines);

    const invalid = validateJsonlBytes(std.testing.allocator, "{\"a\":1}\nnot-json\n");
    try std.testing.expect(!invalid.ok());
    try std.testing.expectEqual(@as(usize, 2), invalid.first_issue.?.line);
}

test "nextMonotonicIdAlloc scans matching numeric suffixes" {
    const ids = [_][]const u8{ "NEG-000001", "other", "NEG-000010", "NEG-bad" };
    const next = try nextMonotonicIdAlloc(std.testing.allocator, "NEG-", &ids);
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("NEG-000011", next);
}

test "acquireLock is exclusive until released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "store.jsonl" });
    defer std.testing.allocator.free(path);

    var lock = try acquireLock(std.testing.allocator, path);
    try std.testing.expectError(error.PathAlreadyExists, acquireLock(std.testing.allocator, path));
    lock.release(std.testing.allocator);
    var second = try acquireLock(std.testing.allocator, path);
    second.release(std.testing.allocator);
}

test "acquireAbsoluteExclusiveLock is exclusive until released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "locks", "store.lock" });
    defer std.testing.allocator.free(path);

    var lock = try acquireAbsoluteExclusiveLock(std.testing.allocator, path);
    try std.testing.expectError(error.PathAlreadyExists, acquireAbsoluteExclusiveLock(std.testing.allocator, path));
    lock.release(std.testing.allocator);
    var second = try acquireAbsoluteExclusiveLock(std.testing.allocator, path);
    second.release(std.testing.allocator);
}

fn tryReadForTest(path: []const u8) ![]u8 {
    return try readFileAlloc(std.testing.allocator, path, 4096);
}
