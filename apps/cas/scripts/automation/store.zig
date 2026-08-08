const files = @import("files.zig");
const output = @import("output.zig");
const rrule = @import("rrule.zig");
const scheduler = @import("scheduler.zig");
const std = @import("std");

const DefaultCodexBin = "codex";
const DefaultLaunchdLabel = "com.openai.codex.automation-runner";
const AutomationSelectSql =
    "select id, name, prompt, status, next_run_at, last_run_at, " ++
    "cwds, rrule, created_at, updated_at from automations";
const AutomationInsertSql =
    "insert into automations " ++
    "(id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, " ++
    "created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

pub const AutomationStatus = enum {
    ACTIVE,
    PAUSED,

    pub fn parse(raw: []const u8) !AutomationStatus {
        if (std.ascii.eqlIgnoreCase(raw, "ACTIVE")) return .ACTIVE;
        if (std.ascii.eqlIgnoreCase(raw, "PAUSED")) return .PAUSED;
        return userErrorFmt("invalid status: {s} (allowed: ACTIVE, PAUSED)", .{raw});
    }

    pub fn asText(self: AutomationStatus) []const u8 {
        return switch (self) {
            .ACTIVE => "ACTIVE",
            .PAUSED => "PAUSED",
        };
    }
};

pub const AutomationRow = struct {
    id: []u8,
    name: []u8,
    prompt: []u8,
    status: []u8,
    next_run_at: ?i64,
    last_run_at: ?i64,
    cwds_json: []u8,
    rrule: []u8,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *AutomationRow, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.prompt);
        allocator.free(self.status);
        allocator.free(self.cwds_json);
        allocator.free(self.rrule);
    }
};

pub const ResolveArgs = struct {
    automation_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const CwdsMode = enum { clear, inherit_default, json, list, unchanged };

pub const CwdsInput = struct {
    mode: CwdsMode,
    list: std.ArrayList([]const u8),
    json_text: ?[]const u8 = null,

    pub fn init(_: std.mem.Allocator, mode: CwdsMode) CwdsInput {
        return .{ .mode = mode, .list = std.ArrayList([]const u8).empty, .json_text = null };
    }

    pub fn deinit(self: *CwdsInput, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }
};

pub const CreateArgs = struct {
    name: []const u8,
    prompt: []const u8,
    prompt_file: ?[]const u8,
    rrule: []const u8,
    status: ?[]const u8,
    cwds: CwdsInput,
    next_run_at: ?[]const u8,
};

pub const UpdateArgs = struct {
    resolve: ResolveArgs,
    new_name: ?[]const u8,
    prompt: ?[]const u8,
    prompt_file: ?[]const u8,
    rrule: ?[]const u8,
    status: ?[]const u8,
    cwds: CwdsInput,
    next_run_at: ?[]const u8,
    clear_next_run_at: bool,
};

pub const ListArgs = struct { status: ?[]const u8, json: bool };
pub const ShowArgs = struct { resolve: ResolveArgs, json: bool };
pub const DoctorArgs = struct { json: bool = false };

pub const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};

    pub const SQLITE_OK: c_int = 0;
    pub const SQLITE_ERROR: c_int = 1;
    pub const SQLITE_ROW: c_int = 100;
    pub const SQLITE_DONE: c_int = 101;

    pub const SQLITE_INTEGER: c_int = 1;
    pub const SQLITE_FLOAT: c_int = 2;
    pub const SQLITE_TEXT: c_int = 3;
    pub const SQLITE_BLOB: c_int = 4;
    pub const SQLITE_NULL: c_int = 5;
    pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
    pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;

    extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
    extern fn sqlite3_open_v2(
        filename: [*:0]const u8,
        ppDb: *?*sqlite3,
        flags: c_int,
        zVfs: ?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_close(db: *sqlite3) c_int;
    extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
    extern fn sqlite3_prepare_v2(
        db: *sqlite3,
        zSql: [*]const u8,
        nByte: c_int,
        ppStmt: *?*sqlite3_stmt,
        pzTail: ?*?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_changes(db: *sqlite3) c_int;
    extern fn sqlite3_bind_text(
        stmt: *sqlite3_stmt,
        idx: c_int,
        value: [*]const u8,
        n: c_int,
        dtor: ?*const anyopaque,
    ) c_int;
    extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, idx: c_int, value: i64) c_int;
    extern fn sqlite3_bind_null(stmt: *sqlite3_stmt, idx: c_int) c_int;
    extern fn sqlite3_column_type(stmt: *sqlite3_stmt, iCol: c_int) c_int;
    extern fn sqlite3_column_text(stmt: *sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
    extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, iCol: c_int) i64;
};

pub const SqlParam = union(enum) {
    int: i64,
    null,
    text: []const u8,
};

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(allocator: std.mem.Allocator, db_path: []const u8) !Db {
        return openWithFlags(allocator, db_path, c.SQLITE_OPEN_READWRITE);
    }

    pub fn openReadOnly(allocator: std.mem.Allocator, db_path: []const u8) !Db {
        return openWithFlags(allocator, db_path, c.SQLITE_OPEN_READONLY);
    }

    pub fn openWithFlags(allocator: std.mem.Allocator, db_path: []const u8, flags: c_int) !Db {
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), db_path, .{}) catch {
            return userErrorFmt("db not found: {s}", .{db_path});
        };

        const path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(path_z);

        var raw: ?*c.sqlite3 = null;
        const open_result = c.sqlite3_open_v2(path_z, &raw, flags, null);
        if (open_result != c.SQLITE_OK or raw == null) {
            if (raw) |handle| _ = c.sqlite3_close(handle);
            return userErrorFmt("failed to open db: {s}", .{db_path});
        }
        return .{ .handle = raw.? };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn prepare(self: *Db, allocator: std.mem.Allocator, sql: []const u8) !Stmt {
        var stmt_ptr: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt_ptr, null);
        if (rc != c.SQLITE_OK or stmt_ptr == null) {
            const msg = std.mem.sliceTo(c.sqlite3_errmsg(self.handle), 0);
            return userErrorFmt("sqlite prepare failed: {s}", .{msg});
        }
        return .{ .db = self, .handle = stmt_ptr.?, .allocator = allocator };
    }

    pub fn exec(
        self: *Db,
        allocator: std.mem.Allocator,
        sql: []const u8,
        params: []const SqlParam,
    ) !void {
        var stmt = try self.prepare(allocator, sql);
        defer stmt.deinit();
        try stmt.bindAll(params);
        const rc = c.sqlite3_step(stmt.handle);
        if (rc != c.SQLITE_DONE) {
            const msg = std.mem.sliceTo(c.sqlite3_errmsg(self.handle), 0);
            return userErrorFmt("sqlite exec failed: {s}", .{msg});
        }
    }

    pub fn changes(self: *Db) i64 {
        return c.sqlite3_changes(self.handle);
    }

    pub fn begin(self: *Db, allocator: std.mem.Allocator) !void {
        try self.exec(allocator, "begin immediate", &.{});
    }

    pub fn commit(self: *Db, allocator: std.mem.Allocator) !void {
        try self.exec(allocator, "commit", &.{});
    }

    pub fn rollback(self: *Db, allocator: std.mem.Allocator) void {
        self.exec(allocator, "rollback", &.{}) catch |err| switch (err) {
            else => {},
        };
    }
};

pub const Stmt = struct {
    db: *Db,
    handle: *c.sqlite3_stmt,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn bindAll(self: *Stmt, params: []const SqlParam) !void {
        for (params, 0..) |param, idx| {
            const rc = switch (param) {
                .text => |value| c.sqlite3_bind_text(
                    self.handle,
                    @intCast(idx + 1),
                    value.ptr,
                    @intCast(value.len),
                    null,
                ),
                .int => |value| c.sqlite3_bind_int64(self.handle, @intCast(idx + 1), value),
                .null => c.sqlite3_bind_null(self.handle, @intCast(idx + 1)),
            };
            if (rc != c.SQLITE_OK) {
                const msg = std.mem.sliceTo(c.sqlite3_errmsg(self.db.handle), 0);
                return userErrorFmt("sqlite bind failed: {s}", .{msg});
            }
        }
    }

    pub fn step(self: *Stmt) !StepResult {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => {
                const msg = std.mem.sliceTo(c.sqlite3_errmsg(self.db.handle), 0);
                return userErrorFmt("sqlite step failed: {s}", .{msg});
            },
        };
    }

    pub fn textColumnAlloc(self: *Stmt, col: c_int) ![]u8 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) {
            return self.allocator.dupe(u8, "");
        }
        const raw = c.sqlite3_column_text(self.handle, col) orelse
            return self.allocator.dupe(u8, "");
        return self.allocator.dupe(u8, std.mem.sliceTo(raw, 0));
    }

    pub fn textColumn(self: *Stmt, col: c_int) []const u8 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) return "";
        const raw = c.sqlite3_column_text(self.handle, col) orelse return "";
        return std.mem.sliceTo(raw, 0);
    }

    pub fn nullableTextColumnAlloc(self: *Stmt, col: c_int) !?[]u8 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) return null;
        const raw = c.sqlite3_column_text(self.handle, col) orelse return null;
        return self.allocator.dupe(u8, std.mem.sliceTo(raw, 0));
    }

    pub fn intColumn(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    pub fn nullableIntColumn(self: *Stmt, col: c_int) ?i64 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) return null;
        return c.sqlite3_column_int64(self.handle, col);
    }
};

pub const StepResult = enum { done, row };

pub const ColumnAffinity = enum { integer, text };

pub const ColumnRequirement = struct {
    name: []const u8,
    affinity: ColumnAffinity,
};

pub const TableRequirement = struct {
    name: []const u8,
    columns: []const ColumnRequirement,
};

pub const automation_columns = [_]ColumnRequirement{
    .{ .name = "id", .affinity = .text },
    .{ .name = "name", .affinity = .text },
    .{ .name = "prompt", .affinity = .text },
    .{ .name = "status", .affinity = .text },
    .{ .name = "next_run_at", .affinity = .integer },
    .{ .name = "last_run_at", .affinity = .integer },
    .{ .name = "cwds", .affinity = .text },
    .{ .name = "rrule", .affinity = .text },
    .{ .name = "created_at", .affinity = .integer },
    .{ .name = "updated_at", .affinity = .integer },
};

pub const automation_run_columns = [_]ColumnRequirement{
    .{ .name = "thread_id", .affinity = .text },
    .{ .name = "automation_id", .affinity = .text },
    .{ .name = "status", .affinity = .text },
    .{ .name = "read_at", .affinity = .integer },
    .{ .name = "thread_title", .affinity = .text },
    .{ .name = "source_cwd", .affinity = .text },
    .{ .name = "inbox_title", .affinity = .text },
    .{ .name = "inbox_summary", .affinity = .text },
    .{ .name = "created_at", .affinity = .integer },
    .{ .name = "updated_at", .affinity = .integer },
    .{ .name = "archived_user_message", .affinity = .text },
    .{ .name = "archived_assistant_message", .affinity = .text },
    .{ .name = "archived_reason", .affinity = .text },
};

pub const inbox_item_columns = [_]ColumnRequirement{
    .{ .name = "id", .affinity = .text },
    .{ .name = "title", .affinity = .text },
    .{ .name = "description", .affinity = .text },
    .{ .name = "thread_id", .affinity = .text },
    .{ .name = "read_at", .affinity = .integer },
    .{ .name = "created_at", .affinity = .integer },
};

pub const required_tables = [_]TableRequirement{
    .{ .name = "automations", .columns = &automation_columns },
    .{ .name = "automation_runs", .columns = &automation_run_columns },
    .{ .name = "inbox_items", .columns = &inbox_item_columns },
};

pub const DoctorDiagnostic = struct {
    code: []const u8,
    severity: []const u8,
    detail: []u8,
};

pub const DoctorDiagnostics = struct {
    rows: std.ArrayList(DoctorDiagnostic) = .empty,

    pub fn deinit(self: *DoctorDiagnostics, allocator: std.mem.Allocator) void {
        for (self.rows.items) |row| allocator.free(row.detail);
        self.rows.deinit(allocator);
    }

    pub fn append(
        self: *DoctorDiagnostics,
        allocator: std.mem.Allocator,
        code: []const u8,
        severity: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.rows.append(allocator, .{
            .code = code,
            .severity = severity,
            .detail = try std.fmt.allocPrint(allocator, fmt, args),
        });
    }

    pub fn hasError(self: *const DoctorDiagnostics) bool {
        for (self.rows.items) |row| if (std.mem.eql(u8, row.severity, "error")) return true;
        return false;
    }

    fn hasErrorSince(self: *const DoctorDiagnostics, start: usize) bool {
        for (self.rows.items[start..]) |row| {
            if (std.mem.eql(u8, row.severity, "error")) return true;
        }
        return false;
    }
};

pub fn inspectMutationWritability(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    automation_root: []const u8,
    diagnostics: *DoctorDiagnostics,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, db_path, .{ .write = true }) catch |err| {
        try diagnostics.append(
            allocator,
            "database-not-writable",
            "error",
            "database is not writable without changing it: {s} ({s})",
            .{ db_path, @errorName(err) },
        );
    };

    const db_owner = std.fs.path.dirname(db_path) orelse ".";
    std.Io.Dir.cwd().access(io, db_owner, .{ .write = true, .execute = true }) catch |err| {
        try diagnostics.append(
            allocator,
            "database-owner-not-writable",
            "error",
            "database owner directory is not writable without changing it: {s} ({s})",
            .{ db_owner, @errorName(err) },
        );
    };

    std.Io.Dir.cwd().access(
        io,
        automation_root,
        .{ .write = true, .execute = true },
    ) catch |err| {
        try diagnostics.append(
            allocator,
            "automation-root-not-writable",
            "error",
            "automation root is not writable without changing it: {s} ({s})",
            .{ automation_root, @errorName(err) },
        );
    };
}

pub fn declaredAffinity(raw: []const u8) ?ColumnAffinity {
    if (containsIgnoreCase(raw, "INT")) return .integer;
    if (containsIgnoreCase(raw, "CHAR") or
        containsIgnoreCase(raw, "CLOB") or
        containsIgnoreCase(raw, "TEXT")) return .text;
    return null;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

pub fn inspectStoreSchema(
    allocator: std.mem.Allocator,
    db: *Db,
    diagnostics: *DoctorDiagnostics,
) !void {
    for (required_tables) |table| {
        const sql = try std.fmt.allocPrint(allocator, "pragma table_info('{s}')", .{table.name});
        defer allocator.free(sql);
        var stmt = try db.prepare(allocator, sql);
        defer stmt.deinit();
        var seen = try allocator.alloc(bool, table.columns.len);
        defer allocator.free(seen);
        @memset(seen, false);
        var row_count: usize = 0;
        while (try stmt.step() == .row) {
            row_count += 1;
            const name = stmt.textColumn(1);
            const declared = stmt.textColumn(2);
            var required_index: ?usize = null;
            for (table.columns, 0..) |required, index| {
                if (std.mem.eql(u8, name, required.name)) {
                    required_index = index;
                    break;
                }
            }
            if (required_index) |index| {
                seen[index] = true;
                const actual = declaredAffinity(declared);
                if (actual == null or actual.? != table.columns[index].affinity) {
                    try diagnostics.append(
                        allocator,
                        "incompatible-column",
                        "error",
                        "{s}.{s} declares {s}; expected {s} affinity",
                        .{ table.name, name, declared, @tagName(table.columns[index].affinity) },
                    );
                }
            } else {
                try diagnostics.append(
                    allocator,
                    "additive-column",
                    "info",
                    "{s}.{s} is additive and admissible",
                    .{ table.name, name },
                );
            }
        }
        if (row_count == 0) {
            try diagnostics.append(
                allocator,
                "missing-table",
                "error",
                "required table {s} is absent",
                .{table.name},
            );
            continue;
        }
        for (table.columns, 0..) |required, index| if (!seen[index]) {
            try diagnostics.append(
                allocator,
                "missing-column",
                "error",
                "required column {s}.{s} is absent",
                .{ table.name, required.name },
            );
        };
    }
}

pub fn requireStoreSchema(allocator: std.mem.Allocator, db: *Db) !void {
    var diagnostics: DoctorDiagnostics = .{};
    defer diagnostics.deinit(allocator);
    try inspectStoreSchema(allocator, db, &diagnostics);
    if (diagnostics.hasError()) {
        return userErrorFmt(
            "automation store schema is incompatible; run `cas automation doctor --json`",
            .{},
        );
    }
}

pub fn parseUnixTimestampMs(raw: []const u8) !i64 {
    const parsed = std.fmt.parseInt(i64, raw, 10) catch {
        return userErrorFmt("timestamp must be an integer unix value", .{});
    };
    if (parsed < 10_000_000_000) return parsed * 1000;
    return parsed;
}

pub fn nowMs() i64 {
    const now = std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io());
    return @intCast(@divFloor(now.nanoseconds, 1_000_000));
}

pub fn validateAutomationId(raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) {
        return userErrorFmt("automation id must not be empty", .{});
    }
    if (std.mem.indexOfScalar(u8, trimmed, std.fs.path.sep) != null) {
        return userErrorFmt("automation id must not contain path separators", .{});
    }
    if (std.fs.path.sep == '\\' and std.mem.indexOfScalar(u8, trimmed, '/') != null) {
        return userErrorFmt("automation id must not contain path separators", .{});
    }
    return trimmed;
}

pub fn defaultDbPath(allocator: std.mem.Allocator) ![]u8 {
    const home = envString("HOME") orelse {
        return userErrorFmt("HOME is not set", .{});
    };
    return std.fmt.allocPrint(allocator, "{s}/.codex/sqlite/codex-dev.db", .{home});
}

fn recreatePerfDbFile(db_path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(
        std.Io.Threaded.global_single_threaded.io(),
        db_path,
    ) catch |err| switch (err) {
        else => {},
    };
    {
        var file = try std.Io.Dir.cwd().createFile(
            std.Io.Threaded.global_single_threaded.io(),
            db_path,
            .{},
        );
        file.close(std.Io.Threaded.global_single_threaded.io());
    }
}

pub fn seedPerfDb(allocator: std.mem.Allocator, db_path: []const u8) !void {
    try recreatePerfDbFile(db_path);

    var db = try Db.open(allocator, db_path);
    defer db.close();

    try db.exec(allocator,
        \\create table automations (
        \\  id text primary key,
        \\  name text not null,
        \\  prompt text not null,
        \\  status text not null,
        \\  next_run_at integer,
        \\  last_run_at integer,
        \\  cwds text not null,
        \\  rrule text not null,
        \\  created_at integer not null,
        \\  updated_at integer not null
        \\)
    , &.{});
    try db.exec(allocator,
        \\create table automation_runs (
        \\  thread_id text primary key,
        \\  automation_id text not null,
        \\  status text not null,
        \\  read_at integer,
        \\  thread_title text,
        \\  source_cwd text,
        \\  inbox_title text,
        \\  inbox_summary text,
        \\  created_at integer not null,
        \\  updated_at integer not null,
        \\  archived_user_message text,
        \\  archived_assistant_message text,
        \\  archived_reason text
        \\)
    , &.{});
    try db.exec(allocator,
        \\create table inbox_items (
        \\  id text primary key,
        \\  title text,
        \\  description text,
        \\  thread_id text,
        \\  read_at integer,
        \\  created_at integer
        \\)
    , &.{});
    try db.exec(
        allocator,
        AutomationInsertSql,
        &.{
            .{ .text = "cron-001" },
            .{ .text = "Daily Summary" },
            .{ .text = "noop prompt" },
            .{ .text = "ACTIVE" },
            .null,
            .null,
            .{ .text = "[]" },
            .{ .text = "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=15" },
            .{ .int = 1_772_469_600_000 },
            .{ .int = 1_772_469_600_000 },
        },
    );
}

pub fn currentPathOwned(allocator: std.mem.Allocator) ![]u8 {
    const cwd_z = try std.process.currentPathAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        allocator,
    );
    defer allocator.free(cwd_z);
    return allocator.dupe(u8, cwd_z);
}

pub fn encodeStringArrayJson(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try w.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try w.writeByte(',');
        try output.jsonWriteString(w, item);
    }
    try w.writeByte(']');

    return writer_alloc.toOwnedSlice();
}

pub fn resolveCwdsForCreate(allocator: std.mem.Allocator, input: CwdsInput) ![]u8 {
    var owned = std.ArrayList([]u8).empty;
    defer files.freeOwnedStrings(allocator, owned);

    switch (input.mode) {
        .inherit_default => {
            const cwd = try currentPathOwned(allocator);
            try owned.append(allocator, cwd);
        },
        .clear => {},
        .list => {
            for (input.list.items) |cwd| {
                try owned.append(allocator, try allocator.dupe(u8, cwd));
            }
        },
        .json => {
            const parsed = try files.parseCwdsJson(allocator, input.json_text orelse "[]");
            defer files.freeOwnedStrings(allocator, parsed);
            for (parsed.items) |cwd| {
                try owned.append(allocator, try allocator.dupe(u8, cwd));
            }
        },
        .unchanged => unreachable,
    }

    var views = std.ArrayList([]const u8).empty;
    defer views.deinit(allocator);
    for (owned.items) |entry| try views.append(allocator, entry);

    const encoded = try encodeStringArrayJson(allocator, views.items);
    return encoded;
}

pub fn resolveCwdsForUpdate(allocator: std.mem.Allocator, input: CwdsInput) !?[]u8 {
    if (input.mode == .unchanged) return null;

    var owned = std.ArrayList([]u8).empty;
    defer files.freeOwnedStrings(allocator, owned);

    switch (input.mode) {
        .clear => {},
        .list => {
            for (input.list.items) |cwd| {
                try owned.append(allocator, try allocator.dupe(u8, cwd));
            }
        },
        .json => {
            const parsed = try files.parseCwdsJson(allocator, input.json_text orelse "[]");
            defer files.freeOwnedStrings(allocator, parsed);
            for (parsed.items) |cwd| {
                try owned.append(allocator, try allocator.dupe(u8, cwd));
            }
        },
        else => return userErrorFmt("internal cwds mode error", .{}),
    }

    var views = std.ArrayList([]const u8).empty;
    defer views.deinit(allocator);
    for (owned.items) |entry| try views.append(allocator, entry);

    const encoded = try encodeStringArrayJson(allocator, views.items);
    return encoded;
}

pub fn getAutomationByResolve(
    allocator: std.mem.Allocator,
    db: *Db,
    resolve: anytype,
) !AutomationRow {
    if (resolve.automation_id) |automation_id| {
        return getAutomationById(allocator, db, automation_id);
    }
    return getAutomationByName(allocator, db, resolve.name.?);
}

pub fn getAutomationById(
    allocator: std.mem.Allocator,
    db: *Db,
    automation_id: []const u8,
) !AutomationRow {
    var stmt = try db.prepare(allocator, AutomationSelectSql ++ " where id = ?");
    defer stmt.deinit();

    try stmt.bindAll(&.{.{ .text = automation_id }});

    switch (try stmt.step()) {
        .done => return userErrorFmt("no automation with id {s}", .{automation_id}),
        .row => return readAutomationRow(allocator, &stmt),
    }
}

pub fn getAutomationByName(allocator: std.mem.Allocator, db: *Db, name: []const u8) !AutomationRow {
    var stmt = try db.prepare(
        allocator,
        AutomationSelectSql ++ " where name = ? order by created_at desc",
    );
    defer stmt.deinit();

    try stmt.bindAll(&.{.{ .text = name }});

    switch (try stmt.step()) {
        .done => return userErrorFmt("no automation named {s}", .{name}),
        .row => {
            var row = try readAutomationRow(allocator, &stmt);
            switch (try stmt.step()) {
                .row => {
                    row.deinit(allocator);
                    return userErrorFmt("multiple automations named {s}; use --id", .{name});
                },
                .done => return row,
            }
        },
    }
}

pub fn readAutomationRow(_: std.mem.Allocator, stmt: *Stmt) !AutomationRow {
    return .{
        .id = try stmt.textColumnAlloc(0),
        .name = try stmt.textColumnAlloc(1),
        .prompt = try stmt.textColumnAlloc(2),
        .status = try stmt.textColumnAlloc(3),
        .next_run_at = stmt.nullableIntColumn(4),
        .last_run_at = stmt.nullableIntColumn(5),
        .cwds_json = try stmt.textColumnAlloc(6),
        .rrule = try stmt.textColumnAlloc(7),
        .created_at = stmt.intColumn(8),
        .updated_at = stmt.intColumn(9),
    };
}

pub fn syncAutomationFilesAfterCommit(
    allocator: std.mem.Allocator,
    db: *Db,
    automation_id: []const u8,
) !void {
    var row = try getAutomationById(allocator, db, automation_id);
    defer row.deinit(allocator);
    files.writeAutomationFilesForRow(allocator, row) catch |err| {
        return userErrorFmt(
            "database commit succeeded but file synchronization failed for {s} ({s}); " ++
                "run `cas automation doctor --json`",
            .{ automation_id, @errorName(err) },
        );
    };
}

fn inspectDuplicateAutomationNames(
    allocator: std.mem.Allocator,
    db: *Db,
    diagnostics: *DoctorDiagnostics,
) !void {
    const sql =
        "select name, count(*) from automations " ++
        "group by name having count(*) > 1";
    var duplicates = try db.prepare(allocator, sql);
    defer duplicates.deinit();
    while (try duplicates.step() == .row) {
        try diagnostics.append(
            allocator,
            "duplicate-name",
            "error",
            "automation name {s} resolves to {d} rows",
            .{ duplicates.textColumn(0), duplicates.intColumn(1) },
        );
    }
}

fn inspectAutomationCwds(
    allocator: std.mem.Allocator,
    row: *const AutomationRow,
    diagnostics: *DoctorDiagnostics,
) !bool {
    var parsed_cwds = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        row.cwds_json,
        .{},
    ) catch null;
    if (parsed_cwds) |*parsed| {
        defer parsed.deinit();
        var valid = parsed.value == .array;
        if (valid) for (parsed.value.array.items) |item| if (item != .string) {
            valid = false;
            break;
        };
        if (valid) return true;
        try diagnostics.append(
            allocator,
            "malformed-cwds",
            "error",
            "automation {s} cwds is not a JSON string array",
            .{row.id},
        );
    } else {
        try diagnostics.append(
            allocator,
            "malformed-cwds",
            "error",
            "automation {s} cwds is invalid JSON",
            .{row.id},
        );
    }
    return false;
}

fn inspectAutomationRrule(
    allocator: std.mem.Allocator,
    row: *const AutomationRow,
    diagnostics: *DoctorDiagnostics,
) !void {
    const canonical = rrule.parseAndCanonicalizeRrule(allocator, row.rrule) catch null;
    if (canonical) |value| {
        allocator.free(value);
    } else {
        try diagnostics.append(
            allocator,
            "malformed-rrule",
            "error",
            "automation {s} has a malformed RRULE",
            .{row.id},
        );
    }
}

fn inspectAutomationFiles(
    allocator: std.mem.Allocator,
    automation_root: []const u8,
    row: *const AutomationRow,
    cwds_valid: bool,
    diagnostics: *DoctorDiagnostics,
) !void {
    const target_dir = try std.fs.path.join(allocator, &.{ automation_root, row.id });
    defer allocator.free(target_dir);
    const toml_path = try std.fs.path.join(allocator, &.{ target_dir, "automation.toml" });
    defer allocator.free(toml_path);
    const actual = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        toml_path,
        allocator,
        .limited(2 * 1024 * 1024),
    ) catch null;
    if (actual) |bytes| {
        defer allocator.free(bytes);
        if (cwds_valid) {
            const expected = try files.renderAutomationTomlAlloc(allocator, row.*);
            defer allocator.free(expected);
            if (!std.mem.eql(u8, bytes, expected)) {
                try diagnostics.append(
                    allocator,
                    "stale-automation-file",
                    "error",
                    "{s} does not match its database row",
                    .{toml_path},
                );
            }
        } else {
            try diagnostics.append(
                allocator,
                "automation-file-comparison-skipped",
                "info",
                "{s} cannot be compared until automation {s} cwds is repaired",
                .{ toml_path, row.id },
            );
        }
    } else {
        try diagnostics.append(
            allocator,
            "missing-automation-file",
            "error",
            "{s} is absent or unreadable",
            .{toml_path},
        );
    }
    const memory_path = try std.fs.path.join(allocator, &.{ target_dir, "memory.md" });
    defer allocator.free(memory_path);
    std.Io.Dir.cwd().access(
        std.Io.Threaded.global_single_threaded.io(),
        memory_path,
        .{},
    ) catch {
        try diagnostics.append(
            allocator,
            "missing-memory-file",
            "error",
            "{s} is absent",
            .{memory_path},
        );
    };
}

fn inspectAutomationRow(
    allocator: std.mem.Allocator,
    automation_root: []const u8,
    root_accessible: bool,
    row: *const AutomationRow,
    diagnostics: *DoctorDiagnostics,
) !void {
    if (!std.mem.eql(u8, row.status, "ACTIVE") and
        !std.mem.eql(u8, row.status, "PAUSED"))
    {
        try diagnostics.append(
            allocator,
            "malformed-status",
            "error",
            "automation {s} has unsupported status {s}",
            .{ row.id, row.status },
        );
    }
    const cwds_valid = try inspectAutomationCwds(allocator, row, diagnostics);
    try inspectAutomationRrule(allocator, row, diagnostics);
    if (root_accessible) {
        try inspectAutomationFiles(
            allocator,
            automation_root,
            row,
            cwds_valid,
            diagnostics,
        );
    }
}

fn inspectAutomationRows(
    allocator: std.mem.Allocator,
    db: *Db,
    automation_root: []const u8,
    root_accessible: bool,
    diagnostics: *DoctorDiagnostics,
) !void {
    var rows_stmt = try db.prepare(allocator, AutomationSelectSql ++ " order by id");
    defer rows_stmt.deinit();
    while (try rows_stmt.step() == .row) {
        var row = try readAutomationRow(allocator, &rows_stmt);
        defer row.deinit(allocator);
        try inspectAutomationRow(
            allocator,
            automation_root,
            root_accessible,
            &row,
            diagnostics,
        );
    }
}

fn inspectOrphanAutomationFiles(
    allocator: std.mem.Allocator,
    db: *Db,
    automation_root: []const u8,
    diagnostics: *DoctorDiagnostics,
) !void {
    var root = try std.Io.Dir.cwd().openDir(
        std.Io.Threaded.global_single_threaded.io(),
        automation_root,
        .{ .iterate = true },
    );
    defer root.close(std.Io.Threaded.global_single_threaded.io());
    var iterator = root.iterate();
    while (try iterator.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .directory) continue;
        var exists = try db.prepare(
            allocator,
            "select count(*) from automations where id = ?",
        );
        defer exists.deinit();
        try exists.bindAll(&.{.{ .text = entry.name }});
        if (try exists.step() == .row and exists.intColumn(0) == 0) {
            try diagnostics.append(
                allocator,
                "orphan-automation-files",
                "error",
                "automation directory {s} has no database row",
                .{entry.name},
            );
        }
    }
}

fn inspectCompatibleStore(
    allocator: std.mem.Allocator,
    db: *Db,
    automation_root: []const u8,
    root_accessible: bool,
    diagnostics: *DoctorDiagnostics,
) !void {
    try inspectDuplicateAutomationNames(allocator, db, diagnostics);
    try inspectAutomationRows(
        allocator,
        db,
        automation_root,
        root_accessible,
        diagnostics,
    );
    if (root_accessible) {
        try inspectOrphanAutomationFiles(allocator, db, automation_root, diagnostics);
    }
}

fn automationRootAccessible(
    allocator: std.mem.Allocator,
    automation_root: []const u8,
    diagnostics: *DoctorDiagnostics,
) !bool {
    std.Io.Dir.cwd().access(
        std.Io.Threaded.global_single_threaded.io(),
        automation_root,
        .{},
    ) catch {
        try diagnostics.append(
            allocator,
            "automation-root",
            "error",
            "automation root is not accessible: {s}",
            .{automation_root},
        );
        return false;
    };
    return true;
}

fn inspectSchedulerStatus(
    allocator: std.mem.Allocator,
    scheduler_status: anytype,
    diagnostics: *DoctorDiagnostics,
) !void {
    if (scheduler_status.migration_required) {
        try diagnostics.append(
            allocator,
            "scheduler-migration",
            "error",
            "same-label scheduler still invokes standalone cron; " ++
                "run scheduler install --replace",
            .{},
        );
    } else if ((scheduler_status.installed or scheduler_status.loaded) and
        std.mem.eql(u8, scheduler_status.surface, "unknown"))
    {
        try diagnostics.append(
            allocator,
            "scheduler-surface",
            "error",
            "same-label scheduler has unexpected program arguments",
            .{},
        );
    }
}

fn inspectDoctorRuntime(
    allocator: std.mem.Allocator,
    diagnostics: *DoctorDiagnostics,
) !?[]u8 {
    const codex_path = try resolveExecutable(
        allocator,
        envString("CODEX_BIN") orelse DefaultCodexBin,
    );
    if (codex_path == null) {
        try diagnostics.append(
            allocator,
            "codex-executable",
            "error",
            "Codex executable is not resolvable",
            .{},
        );
    }

    return codex_path;
}

fn inspectDoctorScheduler(
    allocator: std.mem.Allocator,
    io: std.Io,
    diagnostics: *DoctorDiagnostics,
) !?scheduler.SchedulerStatus {
    const raw_label = envString("CAS_AUTOMATION_LAUNCHD_LABEL") orelse DefaultLaunchdLabel;
    const label = scheduler.validateSchedulerLabel(raw_label) catch |err| {
        try diagnostics.append(
            allocator,
            "scheduler-status",
            "error",
            "scheduler label is invalid: {s}",
            .{@errorName(err)},
        );
        return null;
    };
    var status = scheduler.readSchedulerStatus(allocator, io, label) catch |err| {
        try diagnostics.append(
            allocator,
            "scheduler-status",
            "error",
            "scheduler state is unavailable: {s}",
            .{@errorName(err)},
        );
        return null;
    };
    errdefer status.deinit(allocator);
    try inspectSchedulerStatus(allocator, status, diagnostics);
    return status;
}

fn appendDoctorInspectionError(
    allocator: std.mem.Allocator,
    diagnostics: *DoctorDiagnostics,
    code: []const u8,
    subject: []const u8,
    err: anyerror,
) !void {
    try diagnostics.append(
        allocator,
        code,
        "error",
        "{s}: {s}",
        .{ subject, @errorName(err) },
    );
}

fn inspectDoctorStoreState(
    allocator: std.mem.Allocator,
    db: *Db,
    db_path: []const u8,
    automation_root: []const u8,
    diagnostics: *DoctorDiagnostics,
) !void {
    const schema_diagnostics_start = diagnostics.rows.items.len;
    try inspectStoreSchema(allocator, db, diagnostics);
    const schema_compatible = !diagnostics.hasErrorSince(schema_diagnostics_start);
    const root_accessible = try automationRootAccessible(allocator, automation_root, diagnostics);
    try inspectMutationWritability(allocator, db_path, automation_root, diagnostics);
    if (schema_compatible) {
        try inspectCompatibleStore(
            allocator,
            db,
            automation_root,
            root_accessible,
            diagnostics,
        );
    }
}

pub fn cmdDoctor(
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    args: DoctorArgs,
) !void {
    var diagnostics: DoctorDiagnostics = .{};
    defer diagnostics.deinit(allocator);

    var scheduler_status = try inspectDoctorScheduler(allocator, io, &diagnostics);
    defer if (scheduler_status) |*status| status.deinit(allocator);

    var db = Db.openReadOnly(allocator, db_path) catch |err| {
        try appendDoctorInspectionError(
            allocator,
            &diagnostics,
            "database-open",
            "database is not safely readable",
            err,
        );
        return renderDoctorSnapshot(
            db_path,
            null,
            null,
            &scheduler_status,
            &diagnostics,
            args.json,
        );
    };
    defer db.close();

    const automation_root = files.defaultAutomationsDir(allocator) catch |err| {
        try appendDoctorInspectionError(
            allocator,
            &diagnostics,
            "automation-root",
            "automation root is unavailable",
            err,
        );
        return renderDoctorSnapshot(
            db_path,
            null,
            null,
            &scheduler_status,
            &diagnostics,
            args.json,
        );
    };
    defer allocator.free(automation_root);

    try inspectDoctorStoreState(allocator, &db, db_path, automation_root, &diagnostics);

    const codex_path = try inspectDoctorRuntime(allocator, &diagnostics);
    defer if (codex_path) |value| allocator.free(value);

    try renderDoctorSnapshot(
        db_path,
        automation_root,
        codex_path,
        &scheduler_status,
        &diagnostics,
        args.json,
    );
}

fn renderDoctorSnapshot(
    db_path: []const u8,
    automation_root: ?[]const u8,
    codex_path: ?[]const u8,
    scheduler_status: *?scheduler.SchedulerStatus,
    diagnostics: *const DoctorDiagnostics,
    as_json: bool,
) !void {
    return renderDoctor(
        db_path,
        automation_root,
        codex_path,
        if (scheduler_status.*) |*status| status else null,
        diagnostics,
        as_json,
    );
}

pub fn renderDoctor(
    db_path: []const u8,
    automation_root: ?[]const u8,
    codex_path: ?[]const u8,
    scheduler_status: ?*const scheduler.SchedulerStatus,
    diagnostics: *const DoctorDiagnostics,
    as_json: bool,
) !void {
    const safe = !diagnostics.hasError();
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (!as_json) {
        try stdout.print("automation doctor: {s}\n", .{if (safe) "safe" else "blocked"});
        for (diagnostics.rows.items) |row| {
            try stdout.print(
                "{s}\t{s}\t{s}\n",
                .{ row.severity, row.code, row.detail },
            );
        }
        return;
    }
    try writeDoctorJson(
        stdout,
        db_path,
        automation_root,
        codex_path,
        scheduler_status,
        diagnostics,
    );
}

fn writeDoctorJson(
    writer: anytype,
    db_path: []const u8,
    automation_root: ?[]const u8,
    codex_path: ?[]const u8,
    scheduler_status: ?*const scheduler.SchedulerStatus,
    diagnostics: *const DoctorDiagnostics,
) !void {
    const safe = !diagnostics.hasError();
    var stdout = writer;
    try stdout.writeAll("{\n  \"schema\": \"cas-automation-doctor/v1\",\n  \"status\": \"");
    try stdout.writeAll(if (safe) "compatible" else "incompatible");
    try stdout.writeAll("\",\n  \"database\": ");
    try output.jsonWriteString(stdout, db_path);
    try stdout.writeAll(",\n  \"automationRoot\": ");
    if (automation_root) |value| {
        try output.jsonWriteString(stdout, value);
    } else {
        try stdout.writeAll("null");
    }
    try stdout.writeAll(",\n  \"codexPath\": ");
    if (codex_path) |value| {
        try output.jsonWriteString(stdout, value);
    } else {
        try stdout.writeAll("null");
    }
    try stdout.writeAll(",\n  \"safeToMutate\": ");
    try stdout.writeAll(if (safe) "true" else "false");
    try stdout.writeAll(",\n  \"scheduler\": ");
    if (scheduler_status) |status| {
        try scheduler.writeSchedulerStatusJson(stdout, status.*);
    } else {
        try stdout.writeAll("null");
    }
    try stdout.writeAll(",\n  \"diagnostics\": [");
    for (diagnostics.rows.items, 0..) |row, index| {
        if (index != 0) try stdout.writeByte(',');
        try stdout.writeAll("\n    {\"code\":");
        try output.jsonWriteString(stdout, row.code);
        try stdout.writeAll(",\"severity\":");
        try output.jsonWriteString(stdout, row.severity);
        try stdout.writeAll(",\"detail\":");
        try output.jsonWriteString(stdout, row.detail);
        try stdout.writeByte('}');
    }
    if (diagnostics.rows.items.len != 0) try stdout.writeByte('\n');
    try stdout.writeAll("  ]\n}\n");
}

pub fn cmdList(allocator: std.mem.Allocator, db_path: []const u8, args: ListArgs) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();

    const sql = if (args.status != null)
        AutomationSelectSql ++ " where status = ? order by created_at desc"
    else
        AutomationSelectSql ++ " order by created_at desc";
    var stmt = try db.prepare(allocator, sql);
    defer stmt.deinit();

    if (args.status) |status_text| {
        try stmt.bindAll(&.{.{ .text = status_text }});
    }

    var rows = std.ArrayList(AutomationRow).empty;
    defer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    while (try stmt.step() == .row) {
        try rows.append(allocator, try readAutomationRow(allocator, &stmt));
    }

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    if (args.json) {
        const json_text = try output.buildAutomationRowsJsonAlloc(allocator, rows.items);
        defer allocator.free(json_text);
        try stdout.writeAll(json_text);
        return;
    }

    if (rows.items.len == 0) {
        try stdout.writeAll("no automations\n");
        return;
    }

    for (rows.items) |row| {
        if (row.next_run_at) |next_ms| {
            try stdout.print(
                "{s}\t{s}\t{s}\t{s}\t{d}\n",
                .{ row.id, row.status, row.name, row.rrule, next_ms },
            );
        } else {
            try stdout.print(
                "{s}\t{s}\t{s}\t{s}\tnull\n",
                .{ row.id, row.status, row.name, row.rrule },
            );
        }
    }
}

pub fn cmdShow(allocator: std.mem.Allocator, db_path: []const u8, args: ShowArgs) !void {
    if (!args.json and args.resolve.automation_id != null and args.resolve.name == null) {
        return cmdShowByIdPlain(allocator, db_path, args.resolve.automation_id.?);
    }

    var db = try Db.open(allocator, db_path);
    defer db.close();

    var row = try getAutomationByResolve(allocator, &db, args.resolve);
    defer row.deinit(allocator);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    if (args.json) {
        const json_text = try output.buildAutomationRowJsonAlloc(allocator, row);
        defer allocator.free(json_text);
        try stdout.writeAll(json_text);
        return;
    }

    try stdout.print("id: {s}\n", .{row.id});
    try stdout.print("name: {s}\n", .{row.name});
    try stdout.print("prompt: {s}\n", .{row.prompt});
    try stdout.print("status: {s}\n", .{row.status});
    if (row.next_run_at) |value| {
        try stdout.print("next_run_at: {d}\n", .{value});
    } else {
        try stdout.writeAll("next_run_at: null\n");
    }
    if (row.last_run_at) |value| {
        try stdout.print("last_run_at: {d}\n", .{value});
    } else {
        try stdout.writeAll("last_run_at: null\n");
    }
    try stdout.print("cwds: {s}\n", .{row.cwds_json});
    try stdout.print("rrule: {s}\n", .{row.rrule});
    try stdout.print("created_at: {d}\n", .{row.created_at});
    try stdout.print("updated_at: {d}\n", .{row.updated_at});
}

pub fn cmdShowByIdPlain(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    automation_id: []const u8,
) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();

    var stmt = try db.prepare(allocator, AutomationSelectSql ++ " where id = ?");
    defer stmt.deinit();

    try stmt.bindAll(&.{.{ .text = automation_id }});

    switch (try stmt.step()) {
        .done => return userErrorFmt("no automation with id {s}", .{automation_id}),
        .row => {},
    }

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    try stdout.print("id: {s}\n", .{stmt.textColumn(0)});
    try stdout.print("name: {s}\n", .{stmt.textColumn(1)});
    try stdout.print("prompt: {s}\n", .{stmt.textColumn(2)});
    try stdout.print("status: {s}\n", .{stmt.textColumn(3)});
    if (stmt.nullableIntColumn(4)) |value| {
        try stdout.print("next_run_at: {d}\n", .{value});
    } else {
        try stdout.writeAll("next_run_at: null\n");
    }
    if (stmt.nullableIntColumn(5)) |value| {
        try stdout.print("last_run_at: {d}\n", .{value});
    } else {
        try stdout.writeAll("last_run_at: null\n");
    }
    try stdout.print("cwds: {s}\n", .{stmt.textColumn(6)});
    try stdout.print("rrule: {s}\n", .{stmt.textColumn(7)});
    try stdout.print("created_at: {d}\n", .{stmt.intColumn(8)});
    try stdout.print("updated_at: {d}\n", .{stmt.intColumn(9)});
}

pub fn cmdCreate(allocator: std.mem.Allocator, db_path: []const u8, args: CreateArgs) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();
    try requireStoreSchema(allocator, &db);

    const prompt = try files.readPrompt(
        allocator,
        if (args.prompt.len == 0) null else args.prompt,
        args.prompt_file,
    );
    defer allocator.free(prompt);

    const canonical_rrule = try rrule.parseAndCanonicalizeRrule(allocator, args.rrule);
    defer allocator.free(canonical_rrule);

    const status_value = if (args.status) |raw|
        (try AutomationStatus.parse(raw)).asText()
    else
        AutomationStatus.ACTIVE.asText();
    const cwds_json = try resolveCwdsForCreate(allocator, args.cwds);
    defer allocator.free(cwds_json);

    const created_at = nowMs();
    const next_run_at: ?i64 = if (args.next_run_at) |raw|
        try parseUnixTimestampMs(raw)
    else
        null;

    const automation_id = try generateUuidV4(allocator);
    defer allocator.free(automation_id);

    try db.begin(allocator);
    var transaction_open = true;
    errdefer if (transaction_open) db.rollback(allocator);
    try db.exec(
        allocator,
        AutomationInsertSql,
        &.{
            .{ .text = automation_id },
            .{ .text = args.name },
            .{ .text = prompt },
            .{ .text = status_value },
            if (next_run_at) |value| .{ .int = value } else .null,
            .null,
            .{ .text = cwds_json },
            .{ .text = canonical_rrule },
            .{ .int = created_at },
            .{ .int = created_at },
        },
    );
    try db.commit(allocator);
    transaction_open = false;

    try syncAutomationFilesAfterCommit(allocator, &db, automation_id);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{automation_id});
}

fn applyAutomationUpdate(
    allocator: std.mem.Allocator,
    db: *Db,
    automation_id: []const u8,
    assignments: *std.ArrayList([]const u8),
    params: *std.ArrayList(SqlParam),
) !void {
    const updated_at = nowMs();
    try assignments.append(allocator, "updated_at = ?");
    try params.append(allocator, .{ .int = updated_at });

    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try w.writeAll("update automations set ");
    for (assignments.items, 0..) |entry, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.writeAll(entry);
    }
    try w.writeAll(" where id = ?");

    try params.append(allocator, .{ .text = automation_id });
    try db.begin(allocator);
    var transaction_open = true;
    errdefer if (transaction_open) db.rollback(allocator);
    try db.exec(allocator, writer_alloc.written(), params.items);
    try db.commit(allocator);
    transaction_open = false;

    try syncAutomationFilesAfterCommit(allocator, db, automation_id);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{automation_id});
}

pub fn cmdUpdate(allocator: std.mem.Allocator, db_path: []const u8, args: UpdateArgs) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();
    try requireStoreSchema(allocator, &db);

    var row = try getAutomationByResolve(allocator, &db, args.resolve);
    defer row.deinit(allocator);

    var assignments = std.ArrayList([]const u8).empty;
    defer assignments.deinit(allocator);
    var params = std.ArrayList(SqlParam).empty;
    defer params.deinit(allocator);

    if (args.new_name) |name| {
        try assignments.append(allocator, "name = ?");
        try params.append(allocator, .{ .text = name });
    }

    var prompt_storage: ?[]u8 = null;
    defer if (prompt_storage) |value| allocator.free(value);
    if (args.prompt != null or args.prompt_file != null) {
        prompt_storage = try files.readPrompt(allocator, args.prompt, args.prompt_file);
        try assignments.append(allocator, "prompt = ?");
        try params.append(allocator, .{ .text = prompt_storage.? });
    }

    var canonical_rrule_storage: ?[]u8 = null;
    defer if (canonical_rrule_storage) |value| allocator.free(value);
    if (args.rrule) |raw| {
        canonical_rrule_storage = try rrule.parseAndCanonicalizeRrule(allocator, raw);
        try assignments.append(allocator, "rrule = ?");
        try params.append(allocator, .{ .text = canonical_rrule_storage.? });
    }

    if (args.status) |raw| {
        const status_value = (try AutomationStatus.parse(raw)).asText();
        try assignments.append(allocator, "status = ?");
        try params.append(allocator, .{ .text = status_value });
    }

    if (args.clear_next_run_at) {
        try assignments.append(allocator, "next_run_at = ?");
        try params.append(allocator, .null);
    } else if (args.next_run_at) |raw| {
        try assignments.append(allocator, "next_run_at = ?");
        try params.append(allocator, .{ .int = try parseUnixTimestampMs(raw) });
    }

    var cwds_storage: ?[]u8 = null;
    defer if (cwds_storage) |value| allocator.free(value);
    if (try resolveCwdsForUpdate(allocator, args.cwds)) |cwds_json| {
        cwds_storage = cwds_json;
        try assignments.append(allocator, "cwds = ?");
        try params.append(allocator, .{ .text = cwds_storage.? });
    }

    if (assignments.items.len == 0) return userErrorFmt("no updates provided", .{});
    try applyAutomationUpdate(allocator, &db, row.id, &assignments, &params);
}

pub fn cmdEnableDisable(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    resolve: ResolveArgs,
    status: AutomationStatus,
) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();
    try requireStoreSchema(allocator, &db);

    var row = try getAutomationByResolve(allocator, &db, resolve);
    defer row.deinit(allocator);

    const ts = nowMs();
    try db.begin(allocator);
    var transaction_open = true;
    errdefer if (transaction_open) db.rollback(allocator);
    try db.exec(
        allocator,
        "update automations set status = ?, updated_at = ? where id = ?",
        &.{ .{ .text = status.asText() }, .{ .int = ts }, .{ .text = row.id } },
    );
    try db.commit(allocator);
    transaction_open = false;

    try syncAutomationFilesAfterCommit(allocator, &db, row.id);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{row.id});
}

pub fn cmdRunNow(allocator: std.mem.Allocator, db_path: []const u8, resolve: ResolveArgs) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();
    try requireStoreSchema(allocator, &db);

    var row = try getAutomationByResolve(allocator, &db, resolve);
    defer row.deinit(allocator);

    const ts = nowMs();
    try db.begin(allocator);
    var transaction_open = true;
    errdefer if (transaction_open) db.rollback(allocator);
    try db.exec(
        allocator,
        "update automations set next_run_at = ?, updated_at = ? where id = ?",
        &.{ .{ .int = ts }, .{ .int = ts }, .{ .text = row.id } },
    );
    try db.commit(allocator);
    transaction_open = false;

    try syncAutomationFilesAfterCommit(allocator, &db, row.id);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{row.id});
}

pub fn cmdDelete(allocator: std.mem.Allocator, db_path: []const u8, resolve: ResolveArgs) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();
    try requireStoreSchema(allocator, &db);

    var row = try getAutomationByResolve(allocator, &db, resolve);
    defer row.deinit(allocator);

    try db.begin(allocator);
    var transaction_open = true;
    errdefer if (transaction_open) db.rollback(allocator);
    try db.exec(allocator, "delete from automations where id = ?", &.{.{ .text = row.id }});
    try db.commit(allocator);
    transaction_open = false;
    files.deleteAutomationFiles(allocator, row.id) catch |err| {
        return userErrorFmt(
            "database delete committed but file cleanup failed for {s} ({s}); " ++
                "run `cas automation doctor --json`",
            .{ row.id, @errorName(err) },
        );
    };

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{row.id});
}

pub fn resolveExecutable(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return null;

    if (std.mem.indexOfScalar(u8, value, '/') != null) {
        std.Io.Dir.cwd().access(
            std.Io.Threaded.global_single_threaded.io(),
            value,
            .{},
        ) catch return null;
        const duped = try allocator.dupe(u8, value);
        return @as(?[]u8, duped);
    }

    const path_env = envString("PATH") orelse return null;
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, value });
        errdefer allocator.free(candidate);
        if (std.Io.Dir.cwd().access(
            std.Io.Threaded.global_single_threaded.io(),
            candidate,
            .{},
        )) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }

    return null;
}

pub fn generateUuidV4(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    const now = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io());
    var prng = std.Random.DefaultPrng.init(@intCast(now.nanoseconds));
    prng.random().bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-{x:0>2}{x:0>2}" ++
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

pub fn userErrorFmt(comptime fmt: []const u8, args: anytype) error{UserInput} {
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stderr = &stderr_writer.interface;
    _ = stderr.print("error: " ++ fmt ++ "\n", args) catch |err| switch (err) {
        else => {},
    };
    return error.UserInput;
}

pub fn createTestSchema(allocator: std.mem.Allocator, db: *Db) !void {
    try db.exec(allocator,
        \\create table automations (
        \\  id text primary key,
        \\  name text not null,
        \\  prompt text not null,
        \\  status text not null,
        \\  next_run_at integer,
        \\  last_run_at integer,
        \\  cwds text not null,
        \\  rrule text not null,
        \\  created_at integer not null,
        \\  updated_at integer not null
        \\)
    , &.{});
    try db.exec(allocator,
        \\create table automation_runs (
        \\  thread_id text primary key,
        \\  automation_id text not null,
        \\  status text not null,
        \\  read_at integer,
        \\  thread_title text,
        \\  source_cwd text,
        \\  inbox_title text,
        \\  inbox_summary text,
        \\  created_at integer not null,
        \\  updated_at integer not null,
        \\  archived_user_message text,
        \\  archived_assistant_message text,
        \\  archived_reason text
        \\)
    , &.{});
    try db.exec(allocator,
        \\create table inbox_items (
        \\  id text primary key,
        \\  title text,
        \\  description text,
        \\  thread_id text,
        \\  read_at integer,
        \\  created_at integer
        \\)
    , &.{});
}

fn envString(key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(value);
}

test "doctor uses one custom-label scheduler snapshot for safety and JSON" {
    const allocator = std.testing.allocator;
    var status: scheduler.SchedulerStatus = .{
        .installed = true,
        .loaded = false,
        .label = try allocator.dupe(u8, "com.example.custom-cron"),
        .plist_path = try allocator.dupe(u8, "/tmp/com.example.custom-cron.plist"),
        .surface = "standalone-cron",
        .migration_required = true,
    };
    defer status.deinit(allocator);
    try status.program_arguments.append(
        allocator,
        try allocator.dupe(u8, "/opt/homebrew/bin/cron"),
    );
    try status.program_arguments.append(allocator, try allocator.dupe(u8, "run-due"));

    var diagnostics: DoctorDiagnostics = .{};
    defer diagnostics.deinit(allocator);
    try inspectSchedulerStatus(allocator, status, &diagnostics);

    var encoded = std.Io.Writer.Allocating.init(allocator);
    defer encoded.deinit();
    try writeDoctorJson(
        &encoded.writer,
        "/tmp/codex-dev.db",
        "/tmp/automations",
        "/opt/homebrew/bin/codex",
        &status,
        &diagnostics,
    );
    const report = try encoded.toOwnedSlice();
    defer allocator.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, report, .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.object.get("safeToMutate").?.bool);
    const scheduler_json = parsed.value.object.get("scheduler").?.object;
    try std.testing.expectEqualStrings(
        "com.example.custom-cron",
        scheduler_json.get("label").?.string,
    );
    try std.testing.expectEqualStrings(
        "standalone-cron",
        scheduler_json.get("surface").?.string,
    );
    const diagnostic = parsed.value.object.get("diagnostics").?.array.items[0].object;
    try std.testing.expectEqualStrings("scheduler-migration", diagnostic.get("code").?.string);
}

test "doctor fails closed when scheduler status is unavailable" {
    const allocator = std.testing.allocator;
    var unavailable: DoctorDiagnostics = .{};
    defer unavailable.deinit(allocator);
    try unavailable.append(
        allocator,
        "scheduler-status",
        "error",
        "scheduler state is unavailable: {s}",
        .{"AccessDenied"},
    );
    var unavailable_encoded = std.Io.Writer.Allocating.init(allocator);
    defer unavailable_encoded.deinit();
    try writeDoctorJson(
        &unavailable_encoded.writer,
        "/tmp/codex-dev.db",
        "/tmp/automations",
        "/opt/homebrew/bin/codex",
        null,
        &unavailable,
    );
    const unavailable_report = try unavailable_encoded.toOwnedSlice();
    defer allocator.free(unavailable_report);
    var unavailable_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        unavailable_report,
        .{},
    );
    defer unavailable_parsed.deinit();
    try std.testing.expect(!unavailable_parsed.value.object.get("safeToMutate").?.bool);
    try std.testing.expect(unavailable_parsed.value.object.get("scheduler").? == .null);
    const diagnostic = unavailable_parsed.value.object.get("diagnostics").?.array.items[0].object;
    try std.testing.expectEqualStrings(
        "scheduler-status",
        diagnostic.get("code").?.string,
    );
}
