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

pub const JsonlTransactionMode = enum {
    append,
    replace,
};

pub const JsonlTransactionOptions = struct {
    expected_sequence: ?i64 = null,
    sequence_field: []const u8 = "seq",
    operation: []const u8 = "append-checkpoint",
    max_existing_bytes: usize = 1024 * 1024,
    mode: JsonlTransactionMode = .append,
    allow_sequence_reset: bool = false,
};

pub const JsonlTransactionReceipt = struct {
    transaction_id: []u8,
    prepared_path: []u8,
    commit_path: []u8,
    sequence_before: i64,
    sequence_after: i64,

    pub fn deinit(self: JsonlTransactionReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.transaction_id);
        allocator.free(self.prepared_path);
        allocator.free(self.commit_path);
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
    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse ".";
    try ensureDirectoryPathNoSymlinks(parent);
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

pub fn ensureNoPendingTransactions(
    allocator: std.mem.Allocator,
    transactions_dir: []const u8,
) !void {
    const dir_exists = fileExists(transactions_dir);
    if (!dir_exists) return;

    const names = try listSortedRegularFilesNoSymlink(allocator, transactions_dir, 4096, 1024 * 1024);
    defer freeStringList(allocator, names);

    const prepared_suffix = ".prepared.json";
    for (names) |name| {
        if (!std.mem.endsWith(u8, name, prepared_suffix)) continue;
        const prefix = name[0 .. name.len - prepared_suffix.len];
        const commit_name = try std.fmt.allocPrint(allocator, "{s}.commit.json", .{prefix});
        defer allocator.free(commit_name);
        const commit_path = try std.fs.path.join(allocator, &.{ transactions_dir, commit_name });
        defer allocator.free(commit_path);
        if (!fileExists(commit_path)) return error.TransactionRecoveryRequired;
    }
}

pub fn appendJsonlCheckpointTransaction(
    allocator: std.mem.Allocator,
    store_path: []const u8,
    locks_dir: []const u8,
    transactions_dir: []const u8,
    checkpoint_line: []const u8,
    options: JsonlTransactionOptions,
) !JsonlTransactionReceipt {
    try ensureDirectoryPathNoSymlinks(locks_dir);
    try ensureDirectoryPathNoSymlinks(transactions_dir);

    const lock_name = try transactionLockNameAlloc(allocator, store_path);
    defer allocator.free(lock_name);
    const lock_path = try std.fs.path.join(allocator, &.{ locks_dir, lock_name });
    defer allocator.free(lock_path);
    var lock = try acquireExclusiveLockPath(allocator, lock_path);
    defer lock.release(allocator);

    try ensureNoPendingTransactions(allocator, transactions_dir);

    const existing = readRegularFileNoSymlink(allocator, store_path, options.max_existing_bytes) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    const sequence_before = try lastJsonlSequence(allocator, existing, options.sequence_field);
    if (options.expected_sequence) |expected| {
        if (expected != sequence_before) return error.SequenceStale;
    }

    const trimmed_checkpoint = std.mem.trim(u8, checkpoint_line, " \t\r\n");
    if (trimmed_checkpoint.len == 0) return error.InvalidCheckpoint;
    const sequence_after = try jsonObjectSequence(allocator, trimmed_checkpoint, options.sequence_field);
    switch (options.mode) {
        .append => {
            if (sequence_after != sequence_before + 1) return error.TransactionSequenceMismatch;
        },
        .replace => {
            if (!options.allow_sequence_reset and sequence_after != sequence_before + 1) {
                return error.TransactionSequenceMismatch;
            }
        },
    }

    const transaction_id = try std.fmt.allocPrint(
        allocator,
        "txn-{d:0>12}-{d}",
        .{ sequence_after, std.Io.Clock.awake.now(Io.io()).nanoseconds },
    );
    errdefer allocator.free(transaction_id);
    const prepared_name = try std.fmt.allocPrint(allocator, "{s}.prepared.json", .{transaction_id});
    defer allocator.free(prepared_name);
    const prepared_path = try std.fs.path.join(allocator, &.{ transactions_dir, prepared_name });
    errdefer allocator.free(prepared_path);
    const commit_name = try std.fmt.allocPrint(allocator, "{s}.commit.json", .{transaction_id});
    defer allocator.free(commit_name);
    const commit_path = try std.fs.path.join(allocator, &.{ transactions_dir, commit_name });
    errdefer allocator.free(commit_path);

    const prepared = try renderTransactionRecord(
        allocator,
        "prepared",
        transaction_id,
        store_path,
        options.operation,
        sequence_before,
        sequence_after,
    );
    defer allocator.free(prepared);
    try writeTextCreateNew(allocator, prepared_path, prepared, .{});

    const combined = switch (options.mode) {
        .append => try combineJsonlAppend(allocator, existing, trimmed_checkpoint),
        .replace => try combineJsonlAppend(allocator, "", trimmed_checkpoint),
    };
    defer allocator.free(combined);
    try writeTextAtomic(allocator, store_path, combined);

    const committed = try renderTransactionRecord(
        allocator,
        "committed",
        transaction_id,
        store_path,
        options.operation,
        sequence_before,
        sequence_after,
    );
    defer allocator.free(committed);
    try writeTextCreateNew(allocator, commit_path, committed, .{});

    return .{
        .transaction_id = transaction_id,
        .prepared_path = prepared_path,
        .commit_path = commit_path,
        .sequence_before = sequence_before,
        .sequence_after = sequence_after,
    };
}

fn transactionLockNameAlloc(allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(store_path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.InvalidPath;
    return std.fmt.allocPrint(allocator, "{s}.lock", .{base});
}

fn combineJsonlAppend(allocator: std.mem.Allocator, existing: []const u8, line: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.writer.writeByte('\n');
    try out.writer.writeAll(line);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn lastJsonlSequence(allocator: std.mem.Allocator, data: []const u8, sequence_field: []const u8) !i64 {
    var last: []const u8 = "";
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len != 0) last = line;
    }
    if (last.len == 0) return 0;
    return jsonObjectSequence(allocator, last, sequence_field);
}

fn jsonObjectSequence(allocator: std.mem.Allocator, line: []const u8, sequence_field: []const u8) !i64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCheckpoint;
    const value = parsed.value.object.get(sequence_field) orelse return error.InvalidCheckpoint;
    if (value != .integer) return error.InvalidCheckpoint;
    return value.integer;
}

fn renderTransactionRecord(
    allocator: std.mem.Allocator,
    state: []const u8,
    transaction_id: []const u8,
    store_path: []const u8,
    operation: []const u8,
    sequence_before: i64,
    sequence_after: i64,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"transaction_schema\":\"DSTXN-v1\",\"state\":");
    try std.json.Stringify.value(state, .{}, writer);
    try writer.writeAll(",\"transaction_id\":");
    try std.json.Stringify.value(transaction_id, .{}, writer);
    try writer.writeAll(",\"operation\":");
    try std.json.Stringify.value(operation, .{}, writer);
    try writer.writeAll(",\"store_path\":");
    try std.json.Stringify.value(store_path, .{}, writer);
    try writer.writeAll(",\"sequence_before\":");
    try writer.print("{d}", .{sequence_before});
    try writer.writeAll(",\"sequence_after\":");
    try writer.print("{d}", .{sequence_after});
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
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

pub fn acquireExclusiveLockPath(allocator: std.mem.Allocator, path_raw: []const u8) !LockFile {
    if (std.fs.path.isAbsolute(path_raw)) return acquireAbsoluteExclusiveLock(allocator, path_raw);
    const path = try allocator.dupe(u8, path_raw);
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

test "appendJsonlCheckpointTransaction publishes checkpoint and receipts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(store_path);
    const locks_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "locks" });
    defer std.testing.allocator.free(locks_dir);
    const transactions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "transactions" });
    defer std.testing.allocator.free(transactions_dir);

    var first = try appendJsonlCheckpointTransaction(
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":1,\"ok\":true}",
        .{ .expected_sequence = 0, .sequence_field = "workspace_sequence", .operation = "test-init" },
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), first.sequence_before);
    try std.testing.expectEqual(@as(i64, 1), first.sequence_after);
    try std.testing.expect(fileExists(first.prepared_path));
    try std.testing.expect(fileExists(first.commit_path));

    var second = try appendJsonlCheckpointTransaction(
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":2,\"ok\":false}",
        .{ .expected_sequence = 1, .sequence_field = "workspace_sequence", .operation = "test-append" },
    );
    defer second.deinit(std.testing.allocator);
    const data = try tryReadForTest(store_path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"workspace_sequence\":1,\"ok\":true}\n{\"workspace_sequence\":2,\"ok\":false}\n", data);
}

test "appendJsonlCheckpointTransaction rejects stale sequence without publishing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(store_path);
    const locks_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "locks" });
    defer std.testing.allocator.free(locks_dir);
    const transactions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "transactions" });
    defer std.testing.allocator.free(transactions_dir);

    var first = try appendJsonlCheckpointTransaction(
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":1,\"ok\":true}",
        .{ .expected_sequence = 0, .sequence_field = "workspace_sequence" },
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expectError(error.SequenceStale, appendJsonlCheckpointTransaction(
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":2,\"ok\":false}",
        .{ .expected_sequence = 0, .sequence_field = "workspace_sequence" },
    ));
    const data = try tryReadForTest(store_path);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("{\"workspace_sequence\":1,\"ok\":true}\n", data);
}

test "appendJsonlCheckpointTransaction reports pending prepared recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(Io.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.jsonl" });
    defer std.testing.allocator.free(store_path);
    const locks_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "locks" });
    defer std.testing.allocator.free(locks_dir);
    const transactions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "transactions" });
    defer std.testing.allocator.free(transactions_dir);
    try ensureDirectoryPathNoSymlinks(transactions_dir);
    const prepared_path = try std.fs.path.join(std.testing.allocator, &.{ transactions_dir, "txn-orphan.prepared.json" });
    defer std.testing.allocator.free(prepared_path);
    try writeTextCreateNew(std.testing.allocator, prepared_path, "{\"state\":\"prepared\"}\n", .{});

    try std.testing.expectError(error.TransactionRecoveryRequired, appendJsonlCheckpointTransaction(
        std.testing.allocator,
        store_path,
        locks_dir,
        transactions_dir,
        "{\"workspace_sequence\":1,\"ok\":true}",
        .{ .expected_sequence = 0, .sequence_field = "workspace_sequence" },
    ));
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
