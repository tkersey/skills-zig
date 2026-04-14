const std = @import("std");
const core_path = @import("core_path");

pub const StepResult = enum { row, done };

const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};

    pub const SQLITE_OK: c_int = 0;
    pub const SQLITE_ROW: c_int = 100;
    pub const SQLITE_DONE: c_int = 101;
    pub const SQLITE_NULL: c_int = 5;

    extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
    extern fn sqlite3_close(db: *sqlite3) c_int;
    extern fn sqlite3_prepare_v2(db: *sqlite3, zSql: [*]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*:0]const u8) c_int;
    extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
    extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_clear_bindings(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, idx: c_int, value: [*]const u8, n: c_int, dtor: ?*const anyopaque) c_int;
    extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, idx: c_int, value: i64) c_int;
    extern fn sqlite3_bind_null(stmt: *sqlite3_stmt, idx: c_int) c_int;
    extern fn sqlite3_column_type(stmt: *sqlite3_stmt, iCol: c_int) c_int;
    extern fn sqlite3_column_text(stmt: *sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
    extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, iCol: c_int) i64;
};

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(allocator: std.mem.Allocator, db_path: []const u8) !Db {
        const probe = std.fs.openFileAbsolute(db_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.MissingCodexStateDb,
            else => return err,
        };
        probe.close();

        const path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(path_z);

        var raw: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path_z, &raw) != c.SQLITE_OK or raw == null) {
            return error.CodexStateDbOpenFailed;
        }
        return .{ .handle = raw.? };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn prepare(self: *Db, allocator: std.mem.Allocator, sql: []const u8) !Stmt {
        _ = allocator;
        var stmt_ptr: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt_ptr, null);
        if (rc != c.SQLITE_OK or stmt_ptr == null) return error.CodexStateDbPrepareFailed;
        return .{ .handle = stmt_ptr.? };
    }

    pub fn exec(self: *Db, allocator: std.mem.Allocator, sql: []const u8) !void {
        const sql_z = try allocator.dupeZ(u8, sql);
        defer allocator.free(sql_z);
        if (c.sqlite3_exec(self.handle, sql_z, null, null, null) != c.SQLITE_OK) {
            return error.CodexStateDbStepFailed;
        }
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn reset(self: *Stmt) !void {
        const rc_reset = c.sqlite3_reset(self.handle);
        if (rc_reset != c.SQLITE_OK) return error.CodexStateDbStepFailed;
        const rc_clear = c.sqlite3_clear_bindings(self.handle);
        if (rc_clear != c.SQLITE_OK) return error.CodexStateDbBindFailed;
    }

    pub fn bindText(self: *Stmt, idx: c_int, value: []const u8) !void {
        const rc = c.sqlite3_bind_text(self.handle, idx, value.ptr, @intCast(value.len), null);
        if (rc != c.SQLITE_OK) return error.CodexStateDbBindFailed;
    }

    pub fn bindInt64(self: *Stmt, idx: c_int, value: i64) !void {
        const rc = c.sqlite3_bind_int64(self.handle, idx, value);
        if (rc != c.SQLITE_OK) return error.CodexStateDbBindFailed;
    }

    pub fn bindNull(self: *Stmt, idx: c_int) !void {
        const rc = c.sqlite3_bind_null(self.handle, idx);
        if (rc != c.SQLITE_OK) return error.CodexStateDbBindFailed;
    }

    pub fn step(self: *Stmt) !StepResult {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => error.CodexStateDbStepFailed,
        };
    }

    pub fn intColumn(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    pub fn nullableIntColumn(self: *Stmt, col: c_int) ?i64 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) return null;
        return c.sqlite3_column_int64(self.handle, col);
    }

    pub fn textColumnAlloc(self: *Stmt, allocator: std.mem.Allocator, col: c_int) ![]u8 {
        const raw = c.sqlite3_column_text(self.handle, col) orelse return allocator.dupe(u8, "");
        return allocator.dupe(u8, std.mem.sliceTo(raw, 0));
    }

    pub fn nullableTextColumnAlloc(self: *Stmt, allocator: std.mem.Allocator, col: c_int) !?[]u8 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) return null;
        const raw = c.sqlite3_column_text(self.handle, col) orelse return null;
        return try allocator.dupe(u8, std.mem.sliceTo(raw, 0));
    }
};

pub fn toAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const expanded = try core_path.expandHomePath(allocator, path);
    defer allocator.free(expanded);

    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, expanded });
}

pub fn resolveDefaultDbPath(allocator: std.mem.Allocator, override_path: ?[]const u8) ![]u8 {
    if (override_path) |path| return toAbsolutePath(allocator, path);

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const codex_home = try std.fs.path.join(allocator, &.{ home, ".codex" });
    defer allocator.free(codex_home);

    return discoverLatestStateDbPath(allocator, codex_home);
}

pub fn discoverLatestStateDbPath(allocator: std.mem.Allocator, codex_home: []const u8) ![]u8 {
    var dir = std.fs.openDirAbsolute(codex_home, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.MissingCodexStateDb,
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    var best_version: ?u32 = null;
    var best_name: ?[]u8 = null;
    defer if (best_name) |value| allocator.free(value);

    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const version = parseStateDbVersion(entry.name) orelse continue;
        if (best_version == null or version > best_version.?) {
            if (best_name) |existing| allocator.free(existing);
            best_version = version;
            best_name = try allocator.dupe(u8, entry.name);
        }
    }

    const file_name = best_name orelse return error.MissingCodexStateDb;
    return std.fs.path.join(allocator, &.{ codex_home, file_name });
}

fn parseStateDbVersion(file_name: []const u8) ?u32 {
    const prefix = "state_";
    const suffix = ".sqlite";
    if (!std.mem.startsWith(u8, file_name, prefix)) return null;
    if (!std.mem.endsWith(u8, file_name, suffix)) return null;
    const version_text = file_name[prefix.len .. file_name.len - suffix.len];
    if (version_text.len == 0) return null;
    return std.fmt.parseInt(u32, version_text, 10) catch null;
}

pub fn epochSecondsToIso8601Alloc(allocator: std.mem.Allocator, value: ?i64) !?[]u8 {
    const epoch_seconds = value orelse return null;
    if (epoch_seconds < 0) return null;

    const secs = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_seconds) };
    const epoch_day = secs.getEpochDay();
    const day_seconds = secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

test "parseStateDbVersion accepts versioned state db names only" {
    try std.testing.expectEqual(@as(?u32, 5), parseStateDbVersion("state_5.sqlite"));
    try std.testing.expectEqual(@as(?u32, 12), parseStateDbVersion("state_12.sqlite"));
    try std.testing.expectEqual(@as(?u32, null), parseStateDbVersion("state.sqlite"));
    try std.testing.expectEqual(@as(?u32, null), parseStateDbVersion("state_5.sqlite-wal"));
    try std.testing.expectEqual(@as(?u32, null), parseStateDbVersion("logs_2.sqlite"));
}

test "discoverLatestStateDbPath picks the highest numeric version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "state_3.sqlite", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "state_5.sqlite", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "state_4.sqlite", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "state.sqlite", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "state_5.sqlite-wal", .data = "" });

    const root_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_abs);

    const db_path = try discoverLatestStateDbPath(std.testing.allocator, root_abs);
    defer std.testing.allocator.free(db_path);

    try std.testing.expect(std.mem.endsWith(u8, db_path, "state_5.sqlite"));
}

test "epochSecondsToIso8601Alloc formats UTC timestamps" {
    const text = (try epochSecondsToIso8601Alloc(std.testing.allocator, 1772550556)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("2026-03-03T15:09:16Z", text);
}
