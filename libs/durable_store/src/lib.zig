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
        std.Io.Dir.cwd().deleteFile(Io.io(), self.path) catch {};
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

fn tryReadForTest(path: []const u8) ![]u8 {
    return try readFileAlloc(std.testing.allocator, path, 4096);
}
