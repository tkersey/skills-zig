const app_meta = @import("app_meta");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);

const SourceFile = "cron.zig";
const DefaultCodexBin = "codex";
const DefaultLaunchdLabel = "com.openai.codex.automation-runner";
const DefaultIntervalSeconds: i64 = 60;
const MaxCommandOutputBytes = 10 * 1024 * 1024;
var perf_automation_root_override: ?[]const u8 = null;

fn envString(key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(value);
}

pub const Command = enum {
    list,
    show,
    create,
    update,
    enable,
    disable,
    run_now,
    delete,
    run_due,
    scheduler,
    unknown,
};

pub const SchedulerCommand = enum {
    install,
    uninstall,
    status,
    unknown,
};

pub const CommandDef = struct {
    name: []const u8,
    command: Command,
    summary: []const u8,
};

pub const SchedulerCommandDef = struct {
    name: []const u8,
    command: SchedulerCommand,
    summary: []const u8,
};

const command_defs = [_]CommandDef{
    .{ .name = "list", .command = .list, .summary = "List automations" },
    .{ .name = "show", .command = .show, .summary = "Show one automation" },
    .{ .name = "create", .command = .create, .summary = "Create automation" },
    .{ .name = "update", .command = .update, .summary = "Update automation" },
    .{ .name = "enable", .command = .enable, .summary = "Set status ACTIVE" },
    .{ .name = "disable", .command = .disable, .summary = "Set status PAUSED" },
    .{ .name = "run-now", .command = .run_now, .summary = "Set next_run_at to now" },
    .{ .name = "delete", .command = .delete, .summary = "Delete automation and synced files" },
    .{ .name = "run-due", .command = .run_due, .summary = "Run due automations once (headless)" },
    .{ .name = "scheduler", .command = .scheduler, .summary = "Manage launchd scheduler (macOS)" },
};

const scheduler_command_defs = [_]SchedulerCommandDef{
    .{ .name = "install", .command = .install, .summary = "Install/start launchd scheduler (macOS)" },
    .{ .name = "uninstall", .command = .uninstall, .summary = "Stop/remove launchd scheduler (macOS)" },
    .{ .name = "status", .command = .status, .summary = "Show launchd scheduler status (macOS)" },
};

pub fn commandDefinitions() []const CommandDef {
    return command_defs[0..];
}

pub fn schedulerCommandDefinitions() []const SchedulerCommandDef {
    return scheduler_command_defs[0..];
}

pub fn parseCommand(raw: []const u8) Command {
    for (command_defs) |def| {
        if (std.mem.eql(u8, raw, def.name)) return def.command;
    }
    return .unknown;
}

pub fn parseSchedulerCommand(raw: []const u8) SchedulerCommand {
    for (scheduler_command_defs) |def| {
        if (std.mem.eql(u8, raw, def.name)) return def.command;
    }
    return .unknown;
}

pub const PerfCase = enum {
    show,
    create,
    update,
    enable,
    disable,
    run_now,
    delete,
    run_due,
};

pub fn runPerfCase(allocator: std.mem.Allocator, case: PerfCase, temp_root: []const u8) !void {
    const db_path = try std.fs.path.join(allocator, &.{ temp_root, "codex-dev.db" });
    defer allocator.free(db_path);
    const automation_root = try std.fs.path.join(allocator, &.{ temp_root, ".codex", "automations" });
    defer allocator.free(automation_root);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), automation_root);

    perf_automation_root_override = automation_root;
    defer perf_automation_root_override = null;

    try seedPerfDb(allocator, db_path);

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    switch (case) {
        .show => try run(allocator, std.Io.Threaded.global_single_threaded.io(), &.{ "--db", db_path, "show", "--id", "cron-001" }),
        .create => try run(allocator, std.Io.Threaded.global_single_threaded.io(), &.{ "--db", db_path, "create", "--name", "Created Perf", "--prompt", "noop prompt", "--rrule", "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=15" }),
        .update => try run(allocator, std.Io.Threaded.global_single_threaded.io(), &.{ "--db", db_path, "update", "--id", "cron-001", "--new-name", "Updated Perf" }),
        .enable => try run(allocator, std.Io.Threaded.global_single_threaded.io(), &.{ "--db", db_path, "enable", "--id", "cron-001" }),
        .disable => try run(allocator, std.Io.Threaded.global_single_threaded.io(), &.{ "--db", db_path, "disable", "--id", "cron-001" }),
        .run_now => try run(allocator, std.Io.Threaded.global_single_threaded.io(), &.{ "--db", db_path, "run-now", "--id", "cron-001" }),
        .delete => try run(allocator, std.Io.Threaded.global_single_threaded.io(), &.{ "--db", db_path, "delete", "--id", "cron-001" }),
        .run_due => try run(allocator, std.Io.Threaded.global_single_threaded.io(), &.{ "--db", db_path, "run-due", "--id", "cron-001", "--dry-run" }),
    }
}

const StdoutGuard = struct {
    saved_fd: std.posix.fd_t,
    devnull: std.Io.File,
};

fn silenceStdout() !StdoutGuard {
    const saved_fd = std.c.dup(std.posix.STDOUT_FILENO);
    if (saved_fd < 0) return error.SystemResources;
    const devnull = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), "/dev/null", .{ .mode = .write_only });
    if (std.c.dup2(devnull.handle, std.posix.STDOUT_FILENO) < 0) return error.SystemResources;
    return .{ .saved_fd = saved_fd, .devnull = devnull };
}

fn restoreStdout(guard: StdoutGuard) void {
    _ = std.c.dup2(guard.saved_fd, std.posix.STDOUT_FILENO);
    _ = std.c.close(guard.saved_fd);
    guard.devnull.close(std.Io.Threaded.global_single_threaded.io());
}

const c = struct {
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

    extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
    extern fn sqlite3_close(db: *sqlite3) c_int;
    extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
    extern fn sqlite3_prepare_v2(db: *sqlite3, zSql: [*]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*:0]const u8) c_int;
    extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
    extern fn sqlite3_changes(db: *sqlite3) c_int;
    extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, idx: c_int, value: [*]const u8, n: c_int, dtor: ?*const anyopaque) c_int;
    extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, idx: c_int, value: i64) c_int;
    extern fn sqlite3_bind_null(stmt: *sqlite3_stmt, idx: c_int) c_int;
    extern fn sqlite3_column_type(stmt: *sqlite3_stmt, iCol: c_int) c_int;
    extern fn sqlite3_column_text(stmt: *sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
    extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, iCol: c_int) i64;
};

const SqlParam = union(enum) {
    int: i64,
    null,
    text: []const u8,
};

const Db = struct {
    handle: *c.sqlite3,

    fn open(allocator: std.mem.Allocator, db_path: []const u8) !Db {
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), db_path, .{}) catch {
            return userErrorFmt("db not found: {s}", .{db_path});
        };

        const path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(path_z);

        var raw: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path_z, &raw) != c.SQLITE_OK or raw == null) {
            return userErrorFmt("failed to open db: {s}", .{db_path});
        }
        return .{ .handle = raw.? };
    }

    fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    fn prepare(self: *Db, allocator: std.mem.Allocator, sql: []const u8) !Stmt {
        var stmt_ptr: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt_ptr, null);
        if (rc != c.SQLITE_OK or stmt_ptr == null) {
            const msg = std.mem.sliceTo(c.sqlite3_errmsg(self.handle), 0);
            return userErrorFmt("sqlite prepare failed: {s}", .{msg});
        }
        return .{ .db = self, .handle = stmt_ptr.?, .allocator = allocator };
    }

    fn exec(self: *Db, allocator: std.mem.Allocator, sql: []const u8, params: []const SqlParam) !void {
        var stmt = try self.prepare(allocator, sql);
        defer stmt.deinit();
        try stmt.bindAll(params);
        const rc = c.sqlite3_step(stmt.handle);
        if (rc != c.SQLITE_DONE) {
            const msg = std.mem.sliceTo(c.sqlite3_errmsg(self.handle), 0);
            return userErrorFmt("sqlite exec failed: {s}", .{msg});
        }
    }

    fn changes(self: *Db) i64 {
        return c.sqlite3_changes(self.handle);
    }
};

const Stmt = struct {
    db: *Db,
    handle: *c.sqlite3_stmt,
    allocator: std.mem.Allocator,

    fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    fn bindAll(self: *Stmt, params: []const SqlParam) !void {
        for (params, 0..) |param, idx| {
            const rc = switch (param) {
                .text => |value| c.sqlite3_bind_text(self.handle, @intCast(idx + 1), value.ptr, @intCast(value.len), null),
                .int => |value| c.sqlite3_bind_int64(self.handle, @intCast(idx + 1), value),
                .null => c.sqlite3_bind_null(self.handle, @intCast(idx + 1)),
            };
            if (rc != c.SQLITE_OK) {
                const msg = std.mem.sliceTo(c.sqlite3_errmsg(self.db.handle), 0);
                return userErrorFmt("sqlite bind failed: {s}", .{msg});
            }
        }
    }

    fn step(self: *Stmt) !StepResult {
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

    fn textColumnAlloc(self: *Stmt, col: c_int) ![]u8 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) {
            return self.allocator.dupe(u8, "");
        }
        const raw = c.sqlite3_column_text(self.handle, col) orelse return self.allocator.dupe(u8, "");
        return self.allocator.dupe(u8, std.mem.sliceTo(raw, 0));
    }

    fn textColumn(self: *Stmt, col: c_int) []const u8 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) return "";
        const raw = c.sqlite3_column_text(self.handle, col) orelse return "";
        return std.mem.sliceTo(raw, 0);
    }

    fn nullableTextColumnAlloc(self: *Stmt, col: c_int) !?[]u8 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) return null;
        const raw = c.sqlite3_column_text(self.handle, col) orelse return null;
        return self.allocator.dupe(u8, std.mem.sliceTo(raw, 0));
    }

    fn intColumn(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    fn nullableIntColumn(self: *Stmt, col: c_int) ?i64 {
        if (c.sqlite3_column_type(self.handle, col) == c.SQLITE_NULL) return null;
        return c.sqlite3_column_int64(self.handle, col);
    }
};

const StepResult = enum { done, row };

pub const AutomationStatus = enum {
    ACTIVE,
    PAUSED,

    fn parse(raw: []const u8) !AutomationStatus {
        if (std.ascii.eqlIgnoreCase(raw, "ACTIVE")) return .ACTIVE;
        if (std.ascii.eqlIgnoreCase(raw, "PAUSED")) return .PAUSED;
        return userErrorFmt("invalid status: {s} (allowed: ACTIVE, PAUSED)", .{raw});
    }

    fn asText(self: AutomationStatus) []const u8 {
        return switch (self) {
            .ACTIVE => "ACTIVE",
            .PAUSED => "PAUSED",
        };
    }
};

const Day = enum {
    FR,
    MO,
    SA,
    SU,
    TH,
    TU,
    WE,

    fn parse(raw: []const u8) !Day {
        if (std.ascii.eqlIgnoreCase(raw, "MO")) return .MO;
        if (std.ascii.eqlIgnoreCase(raw, "TU")) return .TU;
        if (std.ascii.eqlIgnoreCase(raw, "WE")) return .WE;
        if (std.ascii.eqlIgnoreCase(raw, "TH")) return .TH;
        if (std.ascii.eqlIgnoreCase(raw, "FR")) return .FR;
        if (std.ascii.eqlIgnoreCase(raw, "SA")) return .SA;
        if (std.ascii.eqlIgnoreCase(raw, "SU")) return .SU;
        return userErrorFmt("invalid BYDAY value: {s}", .{raw});
    }

    fn asText(self: Day) []const u8 {
        return @tagName(self);
    }

    fn weekdayMonIndex(self: Day) u8 {
        return switch (self) {
            .MO => 0,
            .TU => 1,
            .WE => 2,
            .TH => 3,
            .FR => 4,
            .SA => 5,
            .SU => 6,
        };
    }
};

const Freq = enum {
    DAILY,
    HOURLY,
    WEEKLY,

    fn parse(raw: []const u8) !Freq {
        if (std.ascii.eqlIgnoreCase(raw, "HOURLY")) return .HOURLY;
        if (std.ascii.eqlIgnoreCase(raw, "DAILY")) return .DAILY;
        if (std.ascii.eqlIgnoreCase(raw, "WEEKLY")) return .WEEKLY;
        return userErrorFmt("unsupported FREQ: {s} (allowed: HOURLY, DAILY, WEEKLY)", .{raw});
    }

    fn asText(self: Freq) []const u8 {
        return @tagName(self);
    }
};

const RRule = struct {
    freq: Freq,
    interval: u32 = 1,
    byhour: ?u8 = null,
    byminute: ?u8 = null,
    byday: std.ArrayList(Day),

    fn init(_: std.mem.Allocator) RRule {
        return .{ .freq = .DAILY, .interval = 1, .byhour = null, .byminute = null, .byday = std.ArrayList(Day).empty };
    }

    fn deinit(self: *RRule, allocator: std.mem.Allocator) void {
        self.byday.deinit(allocator);
    }
};

const AutomationRow = struct {
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

    fn deinit(self: *AutomationRow, allocator: std.mem.Allocator) void {
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

pub const ListArgs = struct {
    status: ?[]const u8,
    json: bool,
};

pub const ShowArgs = struct {
    resolve: ResolveArgs,
    json: bool,
};

pub const RunDueArgs = struct {
    automation_id: ?[]const u8,
    limit: usize,
    dry_run: bool,
    codex_bin: []const u8,
    lock_label: []const u8,
};

const SchedulerInstallArgs = struct {
    label: []const u8,
    interval_seconds: i64,
    path_value: []const u8,
    codex_bin: []const u8,
};

const SchedulerLabelArgs = struct {
    label: []const u8,
};

const RunResult = struct {
    id: []const u8,
    status: []const u8,
    thread_id: []const u8,
    cwd: []const u8,
    next_run_at: ?i64,
    exit_code: ?u8,
    err: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len <= 1) {
        try printUsage();
        return;
    }
    if (isHelpArg(argv[1])) {
        try printUsage();
        return;
    }
    if (core_cli.isVersionArg(argv[1]) or core_cli.isVersionSubcommand(argv[1])) {
        var stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }

    run(allocator, init.io, argv[1..]) catch |err| {
        if (err == error.UserInput) std.process.exit(1);

        var stderr_file = std.Io.File.stderr();
        var stderr_writer = stderr_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        _ = stderr.print("error: {s}: {s}\n", .{ @errorName(err), SourceFile }) catch {};
        std.process.exit(1);
    };
}

fn run(allocator: std.mem.Allocator, io: std.Io, raw_args: []const []const u8) !void {
    var global = try parseGlobalArgs(allocator, raw_args);
    defer allocator.free(global.db_path);
    defer allocator.free(global.args);

    if (global.args.len == 0) {
        try printUsage();
        return;
    }

    const command = parseCommand(global.args[0]);

    if (global.args.len >= 2 and isHelpArg(global.args[1])) {
        try printUsage();
        return;
    }

    switch (command) {
        .list => {
            const args = try parseListArgs(global.args[1..]);
            try cmdList(allocator, global.db_path, args);
            return;
        },
        .show => {
            const args = try parseShowArgs(global.args[1..]);
            try cmdShow(allocator, global.db_path, args);
            return;
        },
        .create => {
            var args = try parseCreateArgs(allocator, global.args[1..]);
            defer args.cwds.deinit(allocator);
            try cmdCreate(allocator, global.db_path, args);
            return;
        },
        .update => {
            var args = try parseUpdateArgs(allocator, global.args[1..]);
            defer args.cwds.deinit(allocator);
            try cmdUpdate(allocator, global.db_path, args);
            return;
        },
        .enable => {
            const resolve = try parseResolveOnly(global.args[1..]);
            try cmdEnableDisable(allocator, global.db_path, resolve, .ACTIVE);
            return;
        },
        .disable => {
            const resolve = try parseResolveOnly(global.args[1..]);
            try cmdEnableDisable(allocator, global.db_path, resolve, .PAUSED);
            return;
        },
        .run_now => {
            const resolve = try parseResolveOnly(global.args[1..]);
            try cmdRunNow(allocator, global.db_path, resolve);
            return;
        },
        .delete => {
            const resolve = try parseResolveOnly(global.args[1..]);
            try cmdDelete(allocator, global.db_path, resolve);
            return;
        },
        .run_due => {
            const args = try parseRunDueArgs(global.args[1..]);
            try cmdRunDue(allocator, io, global.db_path, args);
            return;
        },
        .scheduler => {
            try cmdScheduler(allocator, io, global.args[1..]);
            return;
        },
        .unknown => {},
    }

    return userErrorFmt("unknown command: {s}", .{global.args[0]});
}

fn printUsage() !void {
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\cron
        \\
        \\Manage Codex automations with native Zig runtime (no Python/shell delegation).
        \\
        \\Usage:
        \\  cron [--db <path>] <command> [options]
        \\
        \\Commands:
        \\
    );
    for (command_defs) |def| {
        if (def.command == .scheduler) {
            for (scheduler_command_defs) |subdef| {
                try stdout.print("  scheduler {s:<9} {s}\n", .{ subdef.name, subdef.summary });
            }
            continue;
        }
        try stdout.print("  {s:<20} {s}\n", .{ def.name, def.summary });
    }
    try stdout.writeAll(
        \\
        \\Global options:
        \\  --db <path>          Path to codex-dev.db
        \\  -h, --help           Show help
        \\  -V, --version        Show version
        \\
    );
    try stdout.print("Version: {s}\n", .{Version});
}

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

const GlobalArgs = struct {
    db_path: []u8,
    args: []const []const u8,
};

fn parseGlobalArgs(allocator: std.mem.Allocator, raw_args: []const []const u8) !GlobalArgs {
    var filtered = std.ArrayList([]const u8).empty;
    defer filtered.deinit(allocator);

    var db_path = try defaultDbPath(allocator);

    var i: usize = 0;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (std.mem.eql(u8, arg, "--db")) {
            if (i + 1 >= raw_args.len) return userErrorFmt("--db requires a value", .{});
            allocator.free(db_path);
            db_path = try allocator.dupe(u8, raw_args[i + 1]);
            i += 1;
            continue;
        }
        try filtered.append(allocator, arg);
    }

    return .{
        .db_path = db_path,
        .args = try filtered.toOwnedSlice(allocator),
    };
}

fn parseListArgs(args: []const []const u8) !ListArgs {
    var out = ListArgs{ .status = null, .json = false };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--status")) {
            if (i + 1 >= args.len) return userErrorFmt("--status requires a value", .{});
            out.status = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
            continue;
        }
        return userErrorFmt("unknown list arg: {s}", .{arg});
    }

    return out;
}

fn parseShowArgs(args: []const []const u8) !ShowArgs {
    var resolve = ResolveArgs{};
    var as_json = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--id")) {
            if (i + 1 >= args.len) return userErrorFmt("--id requires a value", .{});
            resolve.automation_id = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--name")) {
            if (i + 1 >= args.len) return userErrorFmt("--name requires a value", .{});
            resolve.name = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
            continue;
        }
        return userErrorFmt("unknown show arg: {s}", .{arg});
    }

    try validateResolveArgs(resolve);
    return .{ .resolve = resolve, .json = as_json };
}

fn parseResolveOnly(args: []const []const u8) !ResolveArgs {
    var resolve = ResolveArgs{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--id")) {
            if (i + 1 >= args.len) return userErrorFmt("--id requires a value", .{});
            resolve.automation_id = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--name")) {
            if (i + 1 >= args.len) return userErrorFmt("--name requires a value", .{});
            resolve.name = args[i + 1];
            i += 1;
            continue;
        }
        return userErrorFmt("unknown arg: {s}", .{arg});
    }

    try validateResolveArgs(resolve);
    return resolve;
}

fn parseCreateArgs(allocator: std.mem.Allocator, args: []const []const u8) !CreateArgs {
    var name: ?[]const u8 = null;
    var prompt: []const u8 = "";
    var prompt_file: ?[]const u8 = null;
    var rrule: ?[]const u8 = null;
    var status: ?[]const u8 = null;
    var next_run_at: ?[]const u8 = null;
    var cwds = CwdsInput.init(allocator, .inherit_default);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--name")) {
            if (i + 1 >= args.len) return userErrorFmt("--name requires a value", .{});
            name = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt")) {
            if (i + 1 >= args.len) return userErrorFmt("--prompt requires a value", .{});
            prompt = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt-file")) {
            if (i + 1 >= args.len) return userErrorFmt("--prompt-file requires a value", .{});
            prompt_file = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--rrule")) {
            if (i + 1 >= args.len) return userErrorFmt("--rrule requires a value", .{});
            rrule = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--status")) {
            if (i + 1 >= args.len) return userErrorFmt("--status requires a value", .{});
            status = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cwd")) {
            if (i + 1 >= args.len) return userErrorFmt("--cwd requires a value", .{});
            if (cwds.mode == .inherit_default or cwds.mode == .list) {
                cwds.mode = .list;
                try cwds.list.append(allocator, args[i + 1]);
            } else {
                return userErrorFmt("--cwd cannot be combined with --cwds-json/--clear-cwds", .{});
            }
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cwds-json")) {
            if (i + 1 >= args.len) return userErrorFmt("--cwds-json requires a value", .{});
            if (cwds.mode != .inherit_default) return userErrorFmt("--cwds-json cannot be combined with --cwd/--clear-cwds", .{});
            cwds.mode = .json;
            cwds.json_text = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--clear-cwds")) {
            if (cwds.mode != .inherit_default) return userErrorFmt("--clear-cwds cannot be combined with --cwd/--cwds-json", .{});
            cwds.mode = .clear;
            continue;
        }
        if (std.mem.eql(u8, arg, "--next-run-at")) {
            if (i + 1 >= args.len) return userErrorFmt("--next-run-at requires a value", .{});
            next_run_at = args[i + 1];
            i += 1;
            continue;
        }
        return userErrorFmt("unknown create arg: {s}", .{arg});
    }

    if (name == null) return userErrorFmt("--name is required", .{});
    if (rrule == null) return userErrorFmt("--rrule is required", .{});

    return .{
        .name = name.?,
        .prompt = prompt,
        .prompt_file = prompt_file,
        .rrule = rrule.?,
        .status = status,
        .cwds = cwds,
        .next_run_at = next_run_at,
    };
}

fn parseUpdateArgs(allocator: std.mem.Allocator, args: []const []const u8) !UpdateArgs {
    var resolve = ResolveArgs{};
    var new_name: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;
    var prompt_file: ?[]const u8 = null;
    var rrule: ?[]const u8 = null;
    var status: ?[]const u8 = null;
    var next_run_at: ?[]const u8 = null;
    var clear_next_run_at = false;
    var cwds = CwdsInput.init(allocator, .unchanged);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--id")) {
            if (i + 1 >= args.len) return userErrorFmt("--id requires a value", .{});
            resolve.automation_id = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--name")) {
            if (i + 1 >= args.len) return userErrorFmt("--name requires a value", .{});
            resolve.name = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--new-name")) {
            if (i + 1 >= args.len) return userErrorFmt("--new-name requires a value", .{});
            new_name = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt")) {
            if (i + 1 >= args.len) return userErrorFmt("--prompt requires a value", .{});
            prompt = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt-file")) {
            if (i + 1 >= args.len) return userErrorFmt("--prompt-file requires a value", .{});
            prompt_file = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--rrule")) {
            if (i + 1 >= args.len) return userErrorFmt("--rrule requires a value", .{});
            rrule = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--status")) {
            if (i + 1 >= args.len) return userErrorFmt("--status requires a value", .{});
            status = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cwd")) {
            if (i + 1 >= args.len) return userErrorFmt("--cwd requires a value", .{});
            if (cwds.mode == .unchanged or cwds.mode == .list) {
                cwds.mode = .list;
                try cwds.list.append(allocator, args[i + 1]);
            } else {
                return userErrorFmt("--cwd cannot be combined with --cwds-json/--clear-cwds", .{});
            }
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cwds-json")) {
            if (i + 1 >= args.len) return userErrorFmt("--cwds-json requires a value", .{});
            if (cwds.mode != .unchanged) return userErrorFmt("--cwds-json cannot be combined with --cwd/--clear-cwds", .{});
            cwds.mode = .json;
            cwds.json_text = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--clear-cwds")) {
            if (cwds.mode != .unchanged) return userErrorFmt("--clear-cwds cannot be combined with --cwd/--cwds-json", .{});
            cwds.mode = .clear;
            continue;
        }
        if (std.mem.eql(u8, arg, "--next-run-at")) {
            if (i + 1 >= args.len) return userErrorFmt("--next-run-at requires a value", .{});
            next_run_at = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--clear-next-run-at")) {
            clear_next_run_at = true;
            continue;
        }
        return userErrorFmt("unknown update arg: {s}", .{arg});
    }

    try validateResolveArgs(resolve);

    return .{
        .resolve = resolve,
        .new_name = new_name,
        .prompt = prompt,
        .prompt_file = prompt_file,
        .rrule = rrule,
        .status = status,
        .cwds = cwds,
        .next_run_at = next_run_at,
        .clear_next_run_at = clear_next_run_at,
    };
}

fn parseRunDueArgs(args: []const []const u8) !RunDueArgs {
    var id_value: ?[]const u8 = null;
    var limit: usize = 10;
    var dry_run = false;
    var codex_bin: []const u8 = envString("CODEX_BIN") orelse DefaultCodexBin;
    var lock_label: []const u8 = envString("CRON_LAUNCHD_LABEL") orelse DefaultLaunchdLabel;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--id")) {
            if (i + 1 >= args.len) return userErrorFmt("--id requires a value", .{});
            id_value = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            if (i + 1 >= args.len) return userErrorFmt("--limit requires a value", .{});
            limit = try parsePositiveUsize(args[i + 1], "--limit");
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--codex-bin")) {
            if (i + 1 >= args.len) return userErrorFmt("--codex-bin requires a value", .{});
            codex_bin = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--lock-label")) {
            if (i + 1 >= args.len) return userErrorFmt("--lock-label requires a value", .{});
            lock_label = args[i + 1];
            i += 1;
            continue;
        }
        return userErrorFmt("unknown run-due arg: {s}", .{arg});
    }

    const validated_lock_label = try validateSchedulerLabel(lock_label);

    return .{
        .automation_id = id_value,
        .limit = if (limit == 0) 1 else limit,
        .dry_run = dry_run,
        .codex_bin = codex_bin,
        .lock_label = validated_lock_label,
    };
}

fn cmdScheduler(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len == 0) return userErrorFmt("scheduler requires one of: install, uninstall, status", .{});
    if (isHelpArg(args[0])) {
        try printUsage();
        return;
    }
    if (args.len >= 2 and isHelpArg(args[1])) {
        try printUsage();
        return;
    }

    switch (parseSchedulerCommand(args[0])) {
        .install => {
            const parsed = try parseSchedulerInstallArgs(args[1..]);
            try cmdSchedulerInstall(allocator, io, parsed);
            return;
        },
        .uninstall => {
            const parsed = try parseSchedulerLabelArgs(args[1..]);
            try cmdSchedulerUninstall(allocator, io, parsed);
            return;
        },
        .status => {
            const parsed = try parseSchedulerLabelArgs(args[1..]);
            try cmdSchedulerStatus(allocator, io, parsed);
            return;
        },
        .unknown => {},
    }

    return userErrorFmt("unknown scheduler action: {s}", .{args[0]});
}

fn parseSchedulerInstallArgs(args: []const []const u8) !SchedulerInstallArgs {
    var label: []const u8 = envString("CRON_LAUNCHD_LABEL") orelse DefaultLaunchdLabel;
    var interval_seconds: i64 = blk: {
        if (envString("CRON_LAUNCHD_INTERVAL_SECONDS")) |value| {
            break :blk try parsePositiveI64(value, "CRON_LAUNCHD_INTERVAL_SECONDS");
        }
        break :blk DefaultIntervalSeconds;
    };
    var path_value: []const u8 = envString("CRON_LAUNCHD_PATH") orelse envString("PATH") orelse "/usr/bin:/bin:/usr/sbin:/sbin";
    var codex_bin: []const u8 = envString("CODEX_BIN") orelse DefaultCodexBin;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--label")) {
            if (i + 1 >= args.len) return userErrorFmt("--label requires a value", .{});
            label = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-seconds")) {
            if (i + 1 >= args.len) return userErrorFmt("--interval-seconds requires a value", .{});
            interval_seconds = try parsePositiveI64(args[i + 1], "--interval-seconds");
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--path")) {
            if (i + 1 >= args.len) return userErrorFmt("--path requires a value", .{});
            path_value = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--codex-bin")) {
            if (i + 1 >= args.len) return userErrorFmt("--codex-bin requires a value", .{});
            codex_bin = args[i + 1];
            i += 1;
            continue;
        }
        return userErrorFmt("unknown scheduler install arg: {s}", .{arg});
    }

    const validated_label = try validateSchedulerLabel(label);
    return .{
        .label = validated_label,
        .interval_seconds = interval_seconds,
        .path_value = path_value,
        .codex_bin = codex_bin,
    };
}

fn parseSchedulerLabelArgs(args: []const []const u8) !SchedulerLabelArgs {
    var label: []const u8 = envString("CRON_LAUNCHD_LABEL") orelse DefaultLaunchdLabel;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--label")) {
            if (i + 1 >= args.len) return userErrorFmt("--label requires a value", .{});
            label = args[i + 1];
            i += 1;
            continue;
        }
        return userErrorFmt("unknown scheduler arg: {s}", .{arg});
    }

    return .{ .label = try validateSchedulerLabel(label) };
}

fn validateResolveArgs(resolve: ResolveArgs) !void {
    if (resolve.automation_id == null and resolve.name == null) {
        return userErrorFmt("provide --id or --name", .{});
    }
    if (resolve.automation_id != null and resolve.name != null) {
        return userErrorFmt("use either --id or --name", .{});
    }
}

fn validateSchedulerLabel(raw: []const u8) ![]const u8 {
    const label = std.mem.trim(u8, raw, " \t\r\n");
    if (label.len == 0) return userErrorFmt("label must not be empty", .{});

    for (label) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_') continue;
        return userErrorFmt("invalid label: {s} (allowed: [A-Za-z0-9._-])", .{label});
    }
    return label;
}

fn parsePositiveI64(raw: []const u8, field: []const u8) !i64 {
    const parsed = std.fmt.parseInt(i64, raw, 10) catch {
        return userErrorFmt("{s} must be a positive integer", .{field});
    };
    if (parsed < 1) return userErrorFmt("{s} must be >= 1", .{field});
    return parsed;
}

fn parsePositiveUsize(raw: []const u8, field: []const u8) !usize {
    const parsed = std.fmt.parseInt(usize, raw, 10) catch {
        return userErrorFmt("{s} must be a positive integer", .{field});
    };
    if (parsed < 1) return userErrorFmt("{s} must be >= 1", .{field});
    return parsed;
}

fn parseUnixTimestampMs(raw: []const u8) !i64 {
    const parsed = std.fmt.parseInt(i64, raw, 10) catch {
        return userErrorFmt("timestamp must be an integer unix value", .{});
    };
    if (parsed < 10_000_000_000) return parsed * 1000;
    return parsed;
}

fn nowMs() i64 {
    return @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000)));
}

fn alignMsToMinute(ms: i64) i64 {
    const sec = @divFloor(ms, 1000);
    return @as(i64, @intCast(@divFloor(sec, 60) * 60 * 1000));
}

const CivilDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

fn civilFromDays(days_since_unix_epoch: i64) CivilDate {
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    return .{
        .year = y + (if (m <= 2) @as(i64, 1) else @as(i64, 0)),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

fn weekdayMon(days_since_unix_epoch: i64) u8 {
    const idx = @mod(days_since_unix_epoch + 3, 7);
    return @intCast(if (idx < 0) idx + 7 else idx);
}

fn parseHmsFromMs(ms: i64) struct { hour: u8, minute: u8, second: u8, days: i64 } {
    const sec = @divFloor(ms, 1000);
    const days = @divFloor(sec, 86_400);
    const sec_of_day = sec - days * 86_400;
    const hour = @divFloor(sec_of_day, 3600);
    const rem = sec_of_day - hour * 3600;
    const minute = @divFloor(rem, 60);
    const second = rem - minute * 60;
    return .{ .hour = @intCast(hour), .minute = @intCast(minute), .second = @intCast(second), .days = days };
}

fn timestampStringUtc(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    const parts = parseHmsFromMs(ms);
    const d = civilFromDays(parts.days);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} +0000", .{ d.year, d.month, d.day, parts.hour, parts.minute, parts.second });
}

fn dateStringUtc(allocator: std.mem.Allocator, ms: i64) ![]u8 {
    const parts = parseHmsFromMs(ms);
    const d = civilFromDays(parts.days);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
}

fn parseAndCanonicalizeRrule(allocator: std.mem.Allocator, raw_input: []const u8) ![]u8 {
    var input = std.mem.trim(u8, raw_input, " \t\r\n");
    if (input.len == 0) return userErrorFmt("rrule must not be empty", .{});

    if (std.ascii.startsWithIgnoreCase(input, "RRULE:")) {
        input = std.mem.trim(u8, input[6..], " \t\r\n");
    }

    var rule = try parseRrule(allocator, input);
    defer rule.deinit(allocator);
    return renderCanonicalRrule(allocator, rule);
}

fn parseRrule(allocator: std.mem.Allocator, raw_rule: []const u8) !RRule {
    var out = RRule.init(allocator);
    var have_freq = false;
    var have_byminute = false;
    var have_byhour = false;
    var have_byday = false;

    var iter = std.mem.splitScalar(u8, raw_rule, ';');
    while (iter.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;

        var kv = std.mem.splitScalar(u8, part, '=');
        const key_raw = kv.next() orelse return userErrorFmt("rrule token missing key: {s}", .{part});
        const value_raw = kv.next() orelse return userErrorFmt("rrule token missing value: {s}", .{part});
        if (kv.next() != null) return userErrorFmt("rrule token has multiple '=': {s}", .{part});

        const key = std.mem.trim(u8, key_raw, " \t\r\n");
        const value = std.mem.trim(u8, value_raw, " \t\r\n");

        if (std.ascii.eqlIgnoreCase(key, "FREQ")) {
            out.freq = try Freq.parse(value);
            have_freq = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "INTERVAL")) {
            const parsed = try parsePositiveUsize(value, "INTERVAL");
            out.interval = @intCast(parsed);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "BYHOUR")) {
            const parsed = std.fmt.parseInt(i64, value, 10) catch return userErrorFmt("BYHOUR must be an integer 0..23", .{});
            if (parsed < 0 or parsed > 23) return userErrorFmt("BYHOUR must be in 0..23", .{});
            out.byhour = @intCast(parsed);
            have_byhour = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "BYMINUTE")) {
            const parsed = std.fmt.parseInt(i64, value, 10) catch return userErrorFmt("BYMINUTE must be an integer 0..59", .{});
            if (parsed < 0 or parsed > 59) return userErrorFmt("BYMINUTE must be in 0..59", .{});
            out.byminute = @intCast(parsed);
            have_byminute = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "BYDAY")) {
            if (value.len == 0) return userErrorFmt("BYDAY must not be empty", .{});
            var days_iter = std.mem.splitScalar(u8, value, ',');
            while (days_iter.next()) |day_raw| {
                const day = try Day.parse(std.mem.trim(u8, day_raw, " \t\r\n"));
                if (!containsDay(out.byday.items, day)) {
                    try out.byday.append(allocator, day);
                }
            }
            have_byday = out.byday.items.len > 0;
            continue;
        }

        return userErrorFmt("unsupported RRULE token: {s}", .{key});
    }

    if (!have_freq) return userErrorFmt("rrule must include FREQ=...", .{});

    switch (out.freq) {
        .HOURLY => {
            if (!have_byminute) return userErrorFmt("HOURLY rrules must include BYMINUTE", .{});
            if (have_byhour) return userErrorFmt("HOURLY rrules must not include BYHOUR", .{});
            if (have_byday) return userErrorFmt("HOURLY rrules must not include BYDAY", .{});
        },
        .DAILY => {
            if (!have_byhour or !have_byminute) return userErrorFmt("DAILY rrules must include BYHOUR and BYMINUTE", .{});
            if (have_byday) return userErrorFmt("DAILY rrules must not include BYDAY", .{});
        },
        .WEEKLY => {
            if (!have_byday or !have_byhour or !have_byminute) return userErrorFmt("WEEKLY rrules must include BYDAY, BYHOUR, and BYMINUTE", .{});
        },
    }

    return out;
}

fn renderCanonicalRrule(allocator: std.mem.Allocator, rule: RRule) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try w.writeAll("RRULE:FREQ=");
    try w.writeAll(rule.freq.asText());

    if (rule.interval != 1) {
        try w.print(";INTERVAL={d}", .{rule.interval});
    }

    if (rule.byday.items.len > 0) {
        try w.writeAll(";BYDAY=");
        for (rule.byday.items, 0..) |day, idx| {
            if (idx > 0) try w.writeAll(",");
            try w.writeAll(day.asText());
        }
    }

    if (rule.byhour) |hour| {
        try w.print(";BYHOUR={d}", .{hour});
    }
    if (rule.byminute) |minute| {
        try w.print(";BYMINUTE={d}", .{minute});
    }

    return writer_alloc.toOwnedSlice();
}

fn containsDay(items: []const Day, needle: Day) bool {
    for (items) |day| {
        if (day == needle) return true;
    }
    return false;
}

fn validateAutomationId(raw: []const u8) ![]const u8 {
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

fn defaultDbPath(allocator: std.mem.Allocator) ![]u8 {
    const home = envString("HOME") orelse {
        _ = userErrorFmt("HOME is not set", .{}) catch {};
        return error.UserInput;
    };
    return std.fmt.allocPrint(allocator, "{s}/.codex/sqlite/codex-dev.db", .{home});
}

fn defaultAutomationsDir(allocator: std.mem.Allocator) ![]u8 {
    if (perf_automation_root_override) |override| {
        return allocator.dupe(u8, override);
    }
    const home = envString("HOME") orelse {
        _ = userErrorFmt("HOME is not set", .{}) catch {};
        return error.UserInput;
    };
    return std.fmt.allocPrint(allocator, "{s}/.codex/automations", .{home});
}

fn seedPerfDb(allocator: std.mem.Allocator, db_path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), db_path) catch {};
    {
        var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), db_path, .{});
        file.close(std.Io.Threaded.global_single_threaded.io());
    }

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
    try db.exec(
        allocator,
        "insert into automations (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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

fn automationDirPath(allocator: std.mem.Allocator, automation_id: []const u8) ![]u8 {
    const base = try defaultAutomationsDir(allocator);
    defer allocator.free(base);
    const safe_id = try validateAutomationId(automation_id);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, safe_id });
}

fn readPrompt(allocator: std.mem.Allocator, inline_prompt: ?[]const u8, prompt_file: ?[]const u8) ![]u8 {
    if (inline_prompt != null and prompt_file != null) return userErrorFmt("use either --prompt or --prompt-file", .{});
    if (inline_prompt) |text| return allocator.dupe(u8, text);
    if (prompt_file) |path| {
        const raw = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .limited(2 * 1024 * 1024)) catch |err| {
            return userErrorFmt("unable to read prompt file ({s}): {s}", .{ path, @errorName(err) });
        };
        defer allocator.free(raw);
        return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
    }
    return userErrorFmt("prompt is required (--prompt or --prompt-file)", .{});
}

fn parseCwdsJson(allocator: std.mem.Allocator, raw_json: []const u8) !std.ArrayList([]u8) {
    var result = std.ArrayList([]u8).empty;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch {
        return userErrorFmt("cwds_json must be valid JSON", .{});
    };
    defer parsed.deinit();

    if (parsed.value != .array) return userErrorFmt("cwds_json must be a JSON array of strings", .{});
    for (parsed.value.array.items) |item| {
        if (item != .string) return userErrorFmt("cwds_json must be a JSON array of strings", .{});
        try result.append(allocator, try allocator.dupe(u8, item.string));
    }

    return result;
}

fn freeOwnedStrings(allocator: std.mem.Allocator, list: std.ArrayList([]u8)) void {
    var mutable = list;
    for (mutable.items) |item| allocator.free(item);
    mutable.deinit(allocator);
}

fn currentPathOwned(allocator: std.mem.Allocator) ![]u8 {
    const cwd_z = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd_z);
    return allocator.dupe(u8, cwd_z);
}

fn encodeStringArrayJson(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try w.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try w.writeByte(',');
        try jsonWriteString(w, item);
    }
    try w.writeByte(']');

    return writer_alloc.toOwnedSlice();
}

fn resolveCwdsForCreate(allocator: std.mem.Allocator, input: CwdsInput) ![]u8 {
    var owned = std.ArrayList([]u8).empty;
    defer freeOwnedStrings(allocator, owned);

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
            const parsed = try parseCwdsJson(allocator, input.json_text orelse "[]");
            defer freeOwnedStrings(allocator, parsed);
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

fn resolveCwdsForUpdate(allocator: std.mem.Allocator, input: CwdsInput) !?[]u8 {
    if (input.mode == .unchanged) return null;

    var owned = std.ArrayList([]u8).empty;
    defer freeOwnedStrings(allocator, owned);

    switch (input.mode) {
        .clear => {},
        .list => {
            for (input.list.items) |cwd| {
                try owned.append(allocator, try allocator.dupe(u8, cwd));
            }
        },
        .json => {
            const parsed = try parseCwdsJson(allocator, input.json_text orelse "[]");
            defer freeOwnedStrings(allocator, parsed);
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

fn getAutomationByResolve(allocator: std.mem.Allocator, db: *Db, resolve: ResolveArgs) !AutomationRow {
    if (resolve.automation_id) |automation_id| {
        return getAutomationById(allocator, db, automation_id);
    }
    return getAutomationByName(allocator, db, resolve.name.?);
}

fn getAutomationById(allocator: std.mem.Allocator, db: *Db, automation_id: []const u8) !AutomationRow {
    var stmt = try db.prepare(allocator, "select id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at from automations where id = ?");
    defer stmt.deinit();

    try stmt.bindAll(&.{.{ .text = automation_id }});

    switch (try stmt.step()) {
        .done => return userErrorFmt("no automation with id {s}", .{automation_id}),
        .row => return readAutomationRow(allocator, &stmt),
    }
}

fn getAutomationByName(allocator: std.mem.Allocator, db: *Db, name: []const u8) !AutomationRow {
    var stmt = try db.prepare(allocator, "select id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at from automations where name = ? order by created_at desc");
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

fn readAutomationRow(_: std.mem.Allocator, stmt: *Stmt) !AutomationRow {
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

fn writeAutomationFiles(allocator: std.mem.Allocator, db: *Db, automation_id: []const u8) !void {
    var row = try getAutomationById(allocator, db, automation_id);
    defer row.deinit(allocator);

    const target_dir = try automationDirPath(allocator, row.id);
    defer allocator.free(target_dir);

    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), target_dir) catch |err| return userErrorFmt("unable to create automation dir ({s}): {s}", .{ target_dir, @errorName(err) });

    const cwds = try parseCwdsJson(allocator, row.cwds_json);
    defer freeOwnedStrings(allocator, cwds);

    var cwds_view = std.ArrayList([]const u8).empty;
    defer cwds_view.deinit(allocator);
    for (cwds.items) |item| try cwds_view.append(allocator, item);
    const cwds_toml = try renderTomlStringArray(allocator, cwds_view.items);
    defer allocator.free(cwds_toml);

    const id_toml = try tomlQuoteAlloc(allocator, row.id);
    defer allocator.free(id_toml);
    const name_toml = try tomlQuoteAlloc(allocator, row.name);
    defer allocator.free(name_toml);
    const prompt_toml = try tomlQuoteAlloc(allocator, row.prompt);
    defer allocator.free(prompt_toml);
    const status_toml = try tomlQuoteAlloc(allocator, row.status);
    defer allocator.free(status_toml);
    const rrule_toml = try tomlQuoteAlloc(allocator, row.rrule);
    defer allocator.free(rrule_toml);

    const toml_text = try std.fmt.allocPrint(
        allocator,
        "version = 1\n" ++
            "id = {s}\n" ++
            "name = {s}\n" ++
            "prompt = {s}\n" ++
            "status = {s}\n" ++
            "rrule = {s}\n" ++
            "cwds = {s}\n" ++
            "created_at = {d}\n" ++
            "updated_at = {d}\n",
        .{
            id_toml,
            name_toml,
            prompt_toml,
            status_toml,
            rrule_toml,
            cwds_toml,
            row.created_at,
            row.updated_at,
        },
    );
    defer allocator.free(toml_text);

    const automation_toml = try std.fmt.allocPrint(allocator, "{s}/automation.toml", .{target_dir});
    defer allocator.free(automation_toml);
    try writeFileAtomic(allocator, automation_toml, toml_text);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/memory.md", .{target_dir});
    defer allocator.free(memory_path);

    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), memory_path, .{}) catch {
        var file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), memory_path, .{}) catch |err| {
            return userErrorFmt("unable to create memory.md ({s}): {s}", .{ memory_path, @errorName(err) });
        };
        file.close(std.Io.Threaded.global_single_threaded.io());
    };
}

fn deleteAutomationFiles(allocator: std.mem.Allocator, automation_id: []const u8) !void {
    const target_dir = try automationDirPath(allocator, automation_id);
    defer allocator.free(target_dir);

    var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), target_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return userErrorFmt("unable to open automation dir ({s}): {s}", .{ target_dir, @errorName(err) }),
    };
    dir.close(std.Io.Threaded.global_single_threaded.io());
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), target_dir) catch |err| {
        return userErrorFmt("unable to delete automation dir ({s}): {s}", .{ target_dir, @errorName(err) });
    };
}

fn cmdList(allocator: std.mem.Allocator, db_path: []const u8, args: ListArgs) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();

    var stmt = if (args.status) |_| try db.prepare(allocator, "select id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at from automations where status = ? order by created_at desc") else try db.prepare(allocator, "select id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at from automations order by created_at desc");
    defer stmt.deinit();

    if (args.status) |status_text| {
        try stmt.bindAll(&.{.{ .text = status_text }});
    }

    var rows = std.ArrayList(AutomationRow).empty;
    defer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    while (true) {
        switch (try stmt.step()) {
            .done => break,
            .row => try rows.append(allocator, try readAutomationRow(allocator, &stmt)),
        }
    }

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    if (args.json) {
        const json_text = try buildAutomationRowsJsonAlloc(allocator, rows.items);
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
            try stdout.print("{s}\t{s}\t{s}\t{s}\t{d}\n", .{ row.id, row.status, row.name, row.rrule, next_ms });
        } else {
            try stdout.print("{s}\t{s}\t{s}\t{s}\tnull\n", .{ row.id, row.status, row.name, row.rrule });
        }
    }
}

fn cmdShow(allocator: std.mem.Allocator, db_path: []const u8, args: ShowArgs) !void {
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
        const json_text = try buildAutomationRowJsonAlloc(allocator, row);
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

fn cmdShowByIdPlain(allocator: std.mem.Allocator, db_path: []const u8, automation_id: []const u8) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();

    var stmt = try db.prepare(allocator, "select id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at from automations where id = ?");
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

fn cmdCreate(allocator: std.mem.Allocator, db_path: []const u8, args: CreateArgs) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();

    const prompt = try readPrompt(allocator, if (args.prompt.len == 0) null else args.prompt, args.prompt_file);
    defer allocator.free(prompt);

    const canonical_rrule = try parseAndCanonicalizeRrule(allocator, args.rrule);
    defer allocator.free(canonical_rrule);

    const status_value = if (args.status) |raw| (try AutomationStatus.parse(raw)).asText() else AutomationStatus.ACTIVE.asText();
    const cwds_json = try resolveCwdsForCreate(allocator, args.cwds);
    defer allocator.free(cwds_json);

    const created_at = nowMs();
    const next_run_at: ?i64 = if (args.next_run_at) |raw| try parseUnixTimestampMs(raw) else null;

    const automation_id = try generateUuidV4(allocator);
    defer allocator.free(automation_id);

    try db.exec(
        allocator,
        "insert into automations (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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

    try writeAutomationFiles(allocator, &db, automation_id);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{automation_id});
}

fn cmdUpdate(allocator: std.mem.Allocator, db_path: []const u8, args: UpdateArgs) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();

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
        prompt_storage = try readPrompt(allocator, args.prompt, args.prompt_file);
        try assignments.append(allocator, "prompt = ?");
        try params.append(allocator, .{ .text = prompt_storage.? });
    }

    var canonical_rrule_storage: ?[]u8 = null;
    defer if (canonical_rrule_storage) |value| allocator.free(value);
    if (args.rrule) |raw| {
        canonical_rrule_storage = try parseAndCanonicalizeRrule(allocator, raw);
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

    try params.append(allocator, .{ .text = row.id });
    try db.exec(allocator, writer_alloc.written(), params.items);

    try writeAutomationFiles(allocator, &db, row.id);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{row.id});
}

fn cmdEnableDisable(allocator: std.mem.Allocator, db_path: []const u8, resolve: ResolveArgs, status: AutomationStatus) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();

    var row = try getAutomationByResolve(allocator, &db, resolve);
    defer row.deinit(allocator);

    const ts = nowMs();
    try db.exec(
        allocator,
        "update automations set status = ?, updated_at = ? where id = ?",
        &.{ .{ .text = status.asText() }, .{ .int = ts }, .{ .text = row.id } },
    );

    try writeAutomationFiles(allocator, &db, row.id);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{row.id});
}

fn cmdRunNow(allocator: std.mem.Allocator, db_path: []const u8, resolve: ResolveArgs) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();

    var row = try getAutomationByResolve(allocator, &db, resolve);
    defer row.deinit(allocator);

    const ts = nowMs();
    try db.exec(
        allocator,
        "update automations set next_run_at = ?, updated_at = ? where id = ?",
        &.{ .{ .int = ts }, .{ .int = ts }, .{ .text = row.id } },
    );

    try writeAutomationFiles(allocator, &db, row.id);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{row.id});
}

fn cmdDelete(allocator: std.mem.Allocator, db_path: []const u8, resolve: ResolveArgs) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();

    var row = try getAutomationByResolve(allocator, &db, resolve);
    defer row.deinit(allocator);

    try db.exec(allocator, "delete from automations where id = ?", &.{.{ .text = row.id }});
    try deleteAutomationFiles(allocator, row.id);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{row.id});
}

fn cmdRunDue(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, args: RunDueArgs) !void {
    const maybe_lock = try acquireRunLock(allocator, args.lock_label);
    defer releaseRunLock(allocator, maybe_lock);

    if (maybe_lock == null) {
        var stderr_file = std.Io.File.stderr();
        var stderr_writer = stderr_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        const ts = try timestampStringUtc(allocator, nowMs());
        defer allocator.free(ts);
        try stderr.print("{s} skip: lock held\n", .{ts});
        return;
    }

    var db = try Db.open(allocator, db_path);
    defer db.close();

    const now = nowMs();
    var due = try selectDueAutomations(allocator, &db, now, args.limit, args.automation_id);
    defer {
        for (due.items) |*row| row.deinit(allocator);
        due.deinit(allocator);
    }

    if (due.items.len == 0) {
        var stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.writeAll("no due automations\n");
        return;
    }

    const codex_exe = if (args.dry_run) null else try resolveExecutable(allocator, args.codex_bin);
    defer if (codex_exe) |p| allocator.free(p);
    if (!args.dry_run and codex_exe == null) return userErrorFmt("codex executable not found: {s}", .{args.codex_bin});

    var results = std.ArrayList(RunResult).empty;
    defer {
        for (results.items) |item| {
            allocator.free(item.thread_id);
            allocator.free(item.cwd);
            if (item.err) |err_text| allocator.free(err_text);
        }
        results.deinit(allocator);
    }

    for (due.items) |*row| {
        const result = runDueAutomation(allocator, io, &db, row, codex_exe orelse "", args.dry_run) catch |err| {
            const err_text = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
            const empty_thread = try allocator.dupe(u8, "");
            errdefer allocator.free(empty_thread);
            const empty_cwd = try allocator.dupe(u8, "");
            errdefer allocator.free(empty_cwd);
            try results.append(allocator, .{
                .id = row.id,
                .status = "error",
                .thread_id = empty_thread,
                .cwd = empty_cwd,
                .next_run_at = null,
                .exit_code = null,
                .err = err_text,
            });
            continue;
        };
        try results.append(allocator, result);
    }

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    const json_text = try buildRunResultsJsonAlloc(allocator, results.items);
    defer allocator.free(json_text);
    try stdout.writeAll(json_text);
}

fn selectDueAutomations(
    allocator: std.mem.Allocator,
    db: *Db,
    now: i64,
    limit: usize,
    automation_id: ?[]const u8,
) !std.ArrayList(AutomationRow) {
    var rows = std.ArrayList(AutomationRow).empty;

    if (automation_id) |id_value| {
        var stmt = try db.prepare(allocator, "select id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at from automations where id = ? and status = 'ACTIVE' and (next_run_at is null or next_run_at <= ?)");
        defer stmt.deinit();
        try stmt.bindAll(&.{ .{ .text = id_value }, .{ .int = now } });

        while (true) {
            switch (try stmt.step()) {
                .done => break,
                .row => try rows.append(allocator, try readAutomationRow(allocator, &stmt)),
            }
        }

        return rows;
    }

    var stmt = try db.prepare(allocator, "select id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at from automations where status = 'ACTIVE' and (next_run_at is null or next_run_at <= ?) order by coalesce(next_run_at, 0) asc limit ?");
    defer stmt.deinit();

    try stmt.bindAll(&.{ .{ .int = now }, .{ .int = @intCast(limit) } });

    while (true) {
        switch (try stmt.step()) {
            .done => break,
            .row => try rows.append(allocator, try readAutomationRow(allocator, &stmt)),
        }
    }

    return rows;
}

fn runDueAutomation(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Db,
    row: *AutomationRow,
    codex_bin: []const u8,
    dry_run: bool,
) !RunResult {
    const started = nowMs();
    const next_run = try computeNextRunAt(allocator, row, started);

    if (!dry_run) {
        try closeStaleRunningRows(allocator, db, row.id, started);
    }

    var cwds = try parseCwdsJson(allocator, row.cwds_json);
    defer freeOwnedStrings(allocator, cwds);

    if (cwds.items.len == 0) {
        const cwd = try currentPathOwned(allocator);
        try cwds.append(allocator, cwd);
    }

    var failures = std.ArrayList([]u8).empty;
    defer {
        for (failures.items) |msg| allocator.free(msg);
        failures.deinit(allocator);
    }

    var final_thread_id: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(final_thread_id);
    var final_cwd: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(final_cwd);

    for (cwds.items) |cwd| {
        const thread_id = try generateUuidV4(allocator);
        defer allocator.free(thread_id);

        if (dry_run) {
            allocator.free(final_thread_id);
            allocator.free(final_cwd);
            final_thread_id = try allocator.dupe(u8, thread_id);
            final_cwd = try allocator.dupe(u8, cwd);
            continue;
        }

        try insertRunRow(allocator, db, row, thread_id, cwd, started);

        const exec_result = runCodexExec(allocator, io, codex_bin, cwd, row.prompt, thread_id) catch |err| {
            const summary = try std.fmt.allocPrint(allocator, "Command failed before completion: {s}", .{@errorName(err)});
            defer allocator.free(summary);
            try updateRunRow(allocator, db, thread_id, row, "FAILED", summary, summary, nowMs());

            allocator.free(final_thread_id);
            allocator.free(final_cwd);
            final_thread_id = try allocator.dupe(u8, thread_id);
            final_cwd = try allocator.dupe(u8, cwd);

            const msg = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ cwd, @errorName(err) });
            try failures.append(allocator, msg);
            continue;
        };
        defer {
            allocator.free(exec_result.stdout);
            allocator.free(exec_result.stderr);
            allocator.free(exec_result.output_text);
            allocator.free(exec_result.output_path);
        }

        const core_text = if (std.mem.trim(u8, exec_result.output_text, " \t\r\n").len > 0)
            exec_result.output_text
        else if (std.mem.trim(u8, exec_result.stdout, " \t\r\n").len > 0)
            exec_result.stdout
        else
            exec_result.stderr;

        var summary = try summarizeOutput(allocator, core_text, 220);
        defer allocator.free(summary);
        if (exec_result.exit_code != 0) {
            const enriched = try std.fmt.allocPrint(allocator, "Command failed (exit {d}): {s}", .{ exec_result.exit_code, summary });
            allocator.free(summary);
            summary = enriched;
        }

        var details = try allocator.dupe(u8, core_text);
        defer allocator.free(details);
        if (exec_result.stderr.len > 0 and std.mem.indexOf(u8, details, exec_result.stderr) == null) {
            const joined = try std.fmt.allocPrint(allocator, "{s}\n\n--- STDERR ---\n{s}", .{ details, exec_result.stderr });
            allocator.free(details);
            details = joined;
        }
        if (std.mem.trim(u8, details, " \t\r\n").len == 0) {
            allocator.free(details);
            details = try allocator.dupe(u8, summary);
        }

        const status = if (exec_result.exit_code == 0) "PENDING_REVIEW" else "FAILED";
        try updateRunRow(allocator, db, thread_id, row, status, summary, details, nowMs());

        allocator.free(final_thread_id);
        allocator.free(final_cwd);
        final_thread_id = try allocator.dupe(u8, thread_id);
        final_cwd = try allocator.dupe(u8, cwd);

        if (exec_result.exit_code != 0) {
            const msg = try std.fmt.allocPrint(allocator, "{s} (exit {d})", .{ cwd, exec_result.exit_code });
            try failures.append(allocator, msg);
        }
    }

    if (dry_run) {
        return .{
            .id = row.id,
            .status = "dry_run",
            .thread_id = final_thread_id,
            .cwd = final_cwd,
            .next_run_at = next_run,
            .exit_code = null,
            .err = null,
        };
    }

    try updateAutomationTimes(allocator, db, row.id, started, next_run);
    try writeAutomationFiles(allocator, db, row.id);

    const summary_text = if (failures.items.len == 0)
        try std.fmt.allocPrint(allocator, "Completed {d} run(s)", .{cwds.items.len})
    else
        try std.fmt.allocPrint(allocator, "Completed with failures in {d}/{d} cwd(s)", .{ failures.items.len, cwds.items.len });
    defer allocator.free(summary_text);

    try writeMemorySummary(allocator, row.id, summary_text, started);

    if (failures.items.len > 0) {
        const err_text = try std.fmt.allocPrint(allocator, "failed cwds: {d}", .{failures.items.len});
        return .{
            .id = row.id,
            .status = "failed",
            .thread_id = final_thread_id,
            .cwd = final_cwd,
            .next_run_at = next_run,
            .exit_code = 1,
            .err = err_text,
        };
    }

    return .{
        .id = row.id,
        .status = "ok",
        .thread_id = final_thread_id,
        .cwd = final_cwd,
        .next_run_at = next_run,
        .exit_code = 0,
        .err = null,
    };
}

fn computeNextRunAt(allocator: std.mem.Allocator, row: *const AutomationRow, run_started_ms: i64) !i64 {
    const raw = std.mem.trim(u8, row.rrule, " \t\r\n");
    if (raw.len == 0) return userErrorFmt("automation {s} has empty rrule", .{row.id});

    const rule_text = if (std.ascii.startsWithIgnoreCase(raw, "RRULE:"))
        std.mem.trim(u8, raw[6..], " \t\r\n")
    else
        raw;
    if (rule_text.len == 0) return userErrorFmt("automation {s} has malformed rrule", .{row.id});

    var rule = try parseRrule(allocator, rule_text);
    defer rule.deinit(allocator);

    const dtstart_ms: i64 = if (row.next_run_at) |next_ms|
        next_ms
    else if (row.last_run_at) |last_ms|
        last_ms
    else
        row.created_at;

    const dtstart = alignMsToMinute(dtstart_ms);
    const anchor = alignMsToMinute(run_started_ms);

    return switch (rule.freq) {
        .HOURLY => nextHourly(rule, dtstart, anchor),
        .DAILY => nextDaily(rule, dtstart, anchor),
        .WEEKLY => nextWeekly(rule, dtstart, anchor),
    };
}

fn nextHourly(rule: RRule, dtstart_ms: i64, anchor_ms: i64) !i64 {
    const minute = rule.byminute orelse return userErrorFmt("HOURLY rrule missing BYMINUTE", .{});

    const base_sec = @divFloor(dtstart_ms, 1000);
    const anchor_sec = @divFloor(anchor_ms, 1000);

    const base_hour = @divFloor(base_sec, 3600);
    var hour = @max(base_hour, @divFloor(anchor_sec, 3600) - 1);

    while (hour < base_hour + 24 * 365 * 10) : (hour += 1) {
        if (@mod(hour - base_hour, @as(i64, @intCast(rule.interval))) != 0) continue;
        const candidate_sec = hour * 3600 + @as(i64, minute) * 60;
        if (candidate_sec <= anchor_sec or candidate_sec < base_sec) continue;
        return candidate_sec * 1000;
    }

    return userErrorFmt("unable to compute next HOURLY run", .{});
}

fn nextDaily(rule: RRule, dtstart_ms: i64, anchor_ms: i64) !i64 {
    const hour = rule.byhour orelse return userErrorFmt("DAILY rrule missing BYHOUR", .{});
    const minute = rule.byminute orelse return userErrorFmt("DAILY rrule missing BYMINUTE", .{});

    const base_sec = @divFloor(dtstart_ms, 1000);
    const anchor_sec = @divFloor(anchor_ms, 1000);

    const base_day = @divFloor(base_sec, 86_400);
    var day = @max(base_day, @divFloor(anchor_sec, 86_400) - 1);

    while (day < base_day + 366 * 20) : (day += 1) {
        if (@mod(day - base_day, @as(i64, @intCast(rule.interval))) != 0) continue;
        const candidate_sec = day * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
        if (candidate_sec <= anchor_sec or candidate_sec < base_sec) continue;
        return candidate_sec * 1000;
    }

    return userErrorFmt("unable to compute next DAILY run", .{});
}

fn nextWeekly(rule: RRule, dtstart_ms: i64, anchor_ms: i64) !i64 {
    const hour = rule.byhour orelse return userErrorFmt("WEEKLY rrule missing BYHOUR", .{});
    const minute = rule.byminute orelse return userErrorFmt("WEEKLY rrule missing BYMINUTE", .{});
    if (rule.byday.items.len == 0) return userErrorFmt("WEEKLY rrule missing BYDAY", .{});

    const base_sec = @divFloor(dtstart_ms, 1000);
    const anchor_sec = @divFloor(anchor_ms, 1000);

    const base_day = @divFloor(base_sec, 86_400);
    const base_week_start = base_day - @as(i64, weekdayMon(base_day));

    var day = @max(base_day, @divFloor(anchor_sec, 86_400) - 1);
    const max_day = base_day + 366 * 30;

    while (day < max_day) : (day += 1) {
        const wd = weekdayMon(day);
        if (!weekdayAllowed(rule.byday.items, wd)) continue;

        const week_start = day - @as(i64, wd);
        const week_index = @divFloor(week_start - base_week_start, 7);
        if (week_index < 0) continue;
        if (@mod(week_index, @as(i64, @intCast(rule.interval))) != 0) continue;

        const candidate_sec = day * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60;
        if (candidate_sec <= anchor_sec or candidate_sec < base_sec) continue;

        return candidate_sec * 1000;
    }

    return userErrorFmt("unable to compute next WEEKLY run", .{});
}

fn weekdayAllowed(days: []const Day, weekday_index_mon: u8) bool {
    for (days) |day| {
        if (day.weekdayMonIndex() == weekday_index_mon) return true;
    }
    return false;
}

fn closeStaleRunningRows(allocator: std.mem.Allocator, db: *Db, automation_id: []const u8, updated_ms: i64) !void {
    try db.exec(
        allocator,
        "update automation_runs set status = ?, inbox_title = ?, inbox_summary = ?, updated_at = ?, archived_reason = ? where automation_id = ? and status = ?",
        &.{
            .{ .text = "FAILED" },
            .{ .text = "Automation run interrupted" },
            .{ .text = "Marked failed because a previous headless run did not close cleanly." },
            .{ .int = updated_ms },
            .{ .text = "headless_runner_interrupted" },
            .{ .text = automation_id },
            .{ .text = "RUNNING" },
        },
    );
}

fn firstLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const clipped = if (line.len > width) line[0..width] else line;
        return allocator.dupe(u8, clipped);
    }
    return allocator.dupe(u8, "");
}

fn firstMeaningfulLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (std.ascii.startsWithIgnoreCase(line, "Echo:")) continue;
        const clipped = if (line.len > width) line[0..width] else line;
        return allocator.dupe(u8, clipped);
    }
    return allocator.dupe(u8, "");
}

fn summarizeOutput(allocator: std.mem.Allocator, output: []const u8, width: usize) ![]u8 {
    const line = try firstMeaningfulLine(allocator, output, width);
    if (line.len > 0) return line;
    allocator.free(line);

    const compact = try collapseWhitespace(allocator, output);
    defer allocator.free(compact);
    if (compact.len == 0) return allocator.dupe(u8, "No output captured.");
    const clipped = if (compact.len > width) compact[0..width] else compact;
    return allocator.dupe(u8, clipped);
}

fn collapseWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;

    var prev_space = true;
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch)) {
            if (!prev_space) {
                try w.writeByte(' ');
                prev_space = true;
            }
            continue;
        }
        prev_space = false;
        try w.writeByte(ch);
    }

    const trimmed = std.mem.trim(u8, writer_alloc.written(), " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn insertRunRow(
    allocator: std.mem.Allocator,
    db: *Db,
    row: *const AutomationRow,
    thread_id: []const u8,
    source_cwd: []const u8,
    started_ms: i64,
) !void {
    const title = blk: {
        const line = try firstLine(allocator, row.prompt, 120);
        if (line.len > 0) break :blk line;
        allocator.free(line);
        break :blk try allocator.dupe(u8, row.name);
    };
    defer allocator.free(title);
    const running_title = try std.fmt.allocPrint(allocator, "{s} running", .{row.name});
    defer allocator.free(running_title);

    try db.exec(
        allocator,
        "insert into automation_runs (thread_id, automation_id, status, read_at, thread_title, source_cwd, inbox_title, inbox_summary, created_at, updated_at, archived_user_message, archived_assistant_message, archived_reason) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{
            .{ .text = thread_id },
            .{ .text = row.id },
            .{ .text = "RUNNING" },
            .null,
            .{ .text = title },
            .{ .text = source_cwd },
            .{ .text = running_title },
            .{ .text = "Headless runner started this automation." },
            .{ .int = started_ms },
            .{ .int = started_ms },
            .null,
            .null,
            .null,
        },
    );
}

fn updateRunRow(
    allocator: std.mem.Allocator,
    db: *Db,
    thread_id: []const u8,
    row: *const AutomationRow,
    status: []const u8,
    summary: []const u8,
    assistant_message: []const u8,
    finished_ms: i64,
) !void {
    const inbox_title = if (std.mem.eql(u8, status, "PENDING_REVIEW"))
        try std.fmt.allocPrint(allocator, "{s} drafted", .{row.name})
    else
        try std.fmt.allocPrint(allocator, "{s} failed", .{row.name});
    defer allocator.free(inbox_title);

    try db.exec(
        allocator,
        "update automation_runs set status = ?, inbox_title = ?, inbox_summary = ?, updated_at = ?, archived_user_message = ?, archived_assistant_message = ?, archived_reason = ? where thread_id = ?",
        &.{
            .{ .text = status },
            .{ .text = inbox_title },
            .{ .text = summary },
            .{ .int = finished_ms },
            .{ .text = row.prompt },
            .{ .text = assistant_message },
            .{ .text = "headless_runner_auto_archive" },
            .{ .text = thread_id },
        },
    );
}

fn updateAutomationTimes(allocator: std.mem.Allocator, db: *Db, automation_id: []const u8, run_started_ms: i64, next_run_at: i64) !void {
    try db.exec(
        allocator,
        "update automations set last_run_at = ?, next_run_at = ?, updated_at = ? where id = ?",
        &.{ .{ .int = run_started_ms }, .{ .int = next_run_at }, .{ .int = nowMs() }, .{ .text = automation_id } },
    );
}

const CodexRunResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    output_text: []u8,
    output_path: []u8,
};

fn runCodexExec(allocator: std.mem.Allocator, io: std.Io, codex_bin: []const u8, cwd: []const u8, prompt: []const u8, thread_id: []const u8) !CodexRunResult {
    const tmp_dir = try tmpAutomationRunnerDir(allocator);
    defer allocator.free(tmp_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), tmp_dir);

    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}.txt", .{ tmp_dir, thread_id });

    const argv = [_][]const u8{
        codex_bin,
        "exec",
        "--full-auto",
        "--skip-git-repo-check",
        "--cd",
        cwd,
        "--output-last-message",
        output_path,
        prompt,
    };

    const child = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(MaxCommandOutputBytes),
        .stderr_limit = .limited(MaxCommandOutputBytes),
    });

    const output_text = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), output_path, allocator, .limited(MaxCommandOutputBytes)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return userErrorFmt("failed to read codex output file ({s}): {s}", .{ output_path, @errorName(err) }),
    };

    const exit_code: u8 = switch (child.term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(@as(u32, 128) + @intFromEnum(signal), @as(u32, 255))),
        .stopped, .unknown => 1,
    };

    return .{
        .exit_code = exit_code,
        .stdout = child.stdout,
        .stderr = child.stderr,
        .output_text = output_text,
        .output_path = output_path,
    };
}

fn tmpAutomationRunnerDir(allocator: std.mem.Allocator) ![]u8 {
    const home = envString("HOME") orelse {
        _ = userErrorFmt("HOME is not set", .{}) catch {};
        return error.UserInput;
    };
    return std.fmt.allocPrint(allocator, "{s}/.codex/tmp/automation-runner", .{home});
}

fn writeMemorySummary(allocator: std.mem.Allocator, automation_id: []const u8, summary: []const u8, started_ms: i64) !void {
    const folder = try automationDirPath(allocator, automation_id);
    defer allocator.free(folder);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), folder);

    const memory_path = try std.fmt.allocPrint(allocator, "{s}/memory.md", .{folder});
    defer allocator.free(memory_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), memory_path, allocator, .limited(MaxCommandOutputBytes)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return userErrorFmt("failed reading memory file ({s}): {s}", .{ memory_path, @errorName(err) }),
    };
    defer allocator.free(existing);

    const date = try dateStringUtc(allocator, started_ms);
    defer allocator.free(date);
    const ts = try timestampStringUtc(allocator, started_ms);
    defer allocator.free(ts);

    const block = try std.fmt.allocPrint(allocator, "Last run summary ({s}): {s}\nRun time: {s}\n", .{ date, summary, ts });
    defer allocator.free(block);

    const merged = if (existing.len == 0)
        try allocator.dupe(u8, block)
    else
        try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ std.mem.trim(u8, existing, "\n"), block });
    defer allocator.free(merged);

    try writeFileAtomic(allocator, memory_path, merged);
}

const RunLock = struct {
    file: std.Io.File,
    path: []u8,
};

fn acquireRunLock(allocator: std.mem.Allocator, label: []const u8) !?RunLock {
    const home = envString("HOME") orelse {
        _ = userErrorFmt("HOME is not set", .{}) catch {};
        return error.UserInput;
    };
    const validated_label = try validateSchedulerLabel(label);

    const lock_dir = try std.fmt.allocPrint(allocator, "{s}/Library/Caches/{s}", .{ home, validated_label });
    defer allocator.free(lock_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), lock_dir);

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/run.lock", .{lock_dir});

    return acquireExclusiveLockWithStaleRetry(allocator, lock_path);
}

fn acquireExclusiveLockWithStaleRetry(allocator: std.mem.Allocator, lock_path: []const u8) !?RunLock {
    return acquireExclusiveLockWithAttempt(allocator, lock_path, false);
}

fn acquireExclusiveLockWithAttempt(allocator: std.mem.Allocator, lock_path: []const u8, _: bool) !?RunLock {
    var file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), lock_path, .{ .exclusive = true, .read = true, .truncate = false }) catch |err| switch (err) {
        error.PathAlreadyExists => return null,
        else => return userErrorFmt("unable to create lock ({s}): {s}", .{ lock_path, @errorName(err) }),
    };

    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "started_ms={d}\n", .{nowMs()});
    _ = file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), text) catch {};

    return .{ .file = file, .path = try allocator.dupe(u8, lock_path) };
}

fn releaseRunLock(allocator: std.mem.Allocator, lock: ?RunLock) void {
    if (lock) |state| {
        state.file.close(std.Io.Threaded.global_single_threaded.io());
        std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), state.path) catch {};
        allocator.free(state.path);
    }
}

fn resolveExecutable(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return null;

    if (std.mem.indexOfScalar(u8, value, '/') != null) {
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), value, .{}) catch return null;
        const duped = try allocator.dupe(u8, value);
        return @as(?[]u8, duped);
    }

    const path_env = envString("PATH") orelse return null;
    var iter = std.mem.splitScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, value });
        errdefer allocator.free(candidate);
        if (std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }

    return null;
}

fn cmdSchedulerInstall(allocator: std.mem.Allocator, io: std.Io, args: SchedulerInstallArgs) !void {
    if (builtin.os.tag != .macos) return userErrorFmt("scheduler commands are supported on macOS only", .{});

    const home = envString("HOME") orelse return userErrorFmt("HOME is not set", .{});

    const launch_agents = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents", .{home});
    defer allocator.free(launch_agents);
    const log_dir = try std.fmt.allocPrint(allocator, "{s}/Library/Logs/codex-automation-runner", .{home});
    defer allocator.free(log_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), launch_agents);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), log_dir);

    const plist_path = try std.fmt.allocPrint(allocator, "{s}/{s}.plist", .{ launch_agents, args.label });
    defer allocator.free(plist_path);

    const self_path = try std.process.executablePathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(self_path);

    const label_xml = try xmlEscapeAlloc(allocator, args.label);
    defer allocator.free(label_xml);
    const self_path_xml = try xmlEscapeAlloc(allocator, self_path);
    defer allocator.free(self_path_xml);
    const home_xml = try xmlEscapeAlloc(allocator, home);
    defer allocator.free(home_xml);
    const log_dir_xml = try xmlEscapeAlloc(allocator, log_dir);
    defer allocator.free(log_dir_xml);
    const path_xml = try xmlEscapeAlloc(allocator, args.path_value);
    defer allocator.free(path_xml);
    const codex_bin_xml = try xmlEscapeAlloc(allocator, args.codex_bin);
    defer allocator.free(codex_bin_xml);

    const plist = try std.fmt.allocPrint(
        allocator,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
            "<plist version=\"1.0\">\n" ++
            "<dict>\n" ++
            "  <key>Label</key>\n" ++
            "  <string>{s}</string>\n" ++
            "  <key>ProgramArguments</key>\n" ++
            "  <array>\n" ++
            "    <string>{s}</string>\n" ++
            "    <string>run-due</string>\n" ++
            "  </array>\n" ++
            "  <key>WorkingDirectory</key>\n" ++
            "  <string>{s}</string>\n" ++
            "  <key>RunAtLoad</key>\n" ++
            "  <true/>\n" ++
            "  <key>StartInterval</key>\n" ++
            "  <integer>{d}</integer>\n" ++
            "  <key>KeepAlive</key>\n" ++
            "  <dict>\n" ++
            "    <key>Crashed</key>\n" ++
            "    <true/>\n" ++
            "  </dict>\n" ++
            "  <key>ProcessType</key>\n" ++
            "  <string>Background</string>\n" ++
            "  <key>ThrottleInterval</key>\n" ++
            "  <integer>30</integer>\n" ++
            "  <key>StandardOutPath</key>\n" ++
            "  <string>{s}/out.log</string>\n" ++
            "  <key>StandardErrorPath</key>\n" ++
            "  <string>{s}/err.log</string>\n" ++
            "  <key>EnvironmentVariables</key>\n" ++
            "  <dict>\n" ++
            "    <key>PATH</key>\n" ++
            "    <string>{s}</string>\n" ++
            "    <key>CRON_LAUNCHD_LABEL</key>\n" ++
            "    <string>{s}</string>\n" ++
            "    <key>CODEX_BIN</key>\n" ++
            "    <string>{s}</string>\n" ++
            "  </dict>\n" ++
            "</dict>\n" ++
            "</plist>\n",
        .{ label_xml, self_path_xml, home_xml, args.interval_seconds, log_dir_xml, log_dir_xml, path_xml, label_xml, codex_bin_xml },
    );
    defer allocator.free(plist);

    var changed = true;
    const existing = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), plist_path, allocator, .limited(MaxCommandOutputBytes)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return userErrorFmt("failed to read existing plist ({s}): {s}", .{ plist_path, @errorName(err) }),
    };
    defer allocator.free(existing);

    if (std.mem.eql(u8, existing, plist)) changed = false;

    if (changed) {
        try writeFileAtomic(allocator, plist_path, plist);
    }

    _ = try runCommandCapture(allocator, io, &.{ "plutil", "-lint", plist_path }, true);

    const uid = std.c.getuid();
    const target = try std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, args.label });
    defer allocator.free(target);
    const domain = try std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
    defer allocator.free(domain);

    _ = runCommandCapture(allocator, io, &.{ "launchctl", "bootout", target }, false) catch null;
    _ = try runCommandCapture(allocator, io, &.{ "launchctl", "bootstrap", domain, plist_path }, true);
    _ = runCommandCapture(allocator, io, &.{ "launchctl", "enable", target }, false) catch null;
    _ = try runCommandCapture(allocator, io, &.{ "launchctl", "kickstart", "-k", target }, true);
    _ = try runCommandCapture(allocator, io, &.{ "launchctl", "print", target }, true);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("installed and started: {s}\n", .{args.label});
    try stdout.print("plist: {s}\n", .{plist_path});
    try stdout.print("logs: {s}\n", .{log_dir});
}

fn cmdSchedulerUninstall(allocator: std.mem.Allocator, io: std.Io, args: SchedulerLabelArgs) !void {
    if (builtin.os.tag != .macos) return userErrorFmt("scheduler commands are supported on macOS only", .{});

    const home = envString("HOME") orelse return userErrorFmt("HOME is not set", .{});
    const plist = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/{s}.plist", .{ home, args.label });
    defer allocator.free(plist);

    const uid = std.c.getuid();
    const target = try std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, args.label });
    defer allocator.free(target);

    _ = runCommandCapture(allocator, io, &.{ "launchctl", "disable", target }, false) catch null;
    _ = runCommandCapture(allocator, io, &.{ "launchctl", "bootout", target }, false) catch null;

    var existed = true;
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), plist) catch |err| switch (err) {
        error.FileNotFound => existed = false,
        else => return userErrorFmt("failed to remove plist ({s}): {s}", .{ plist, @errorName(err) }),
    };

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (existed) {
        try stdout.print("stopped and removed: {s}\n", .{args.label});
    } else {
        try stdout.print("already absent: {s}\n", .{args.label});
    }
}

fn cmdSchedulerStatus(allocator: std.mem.Allocator, io: std.Io, args: SchedulerLabelArgs) !void {
    if (builtin.os.tag != .macos) return userErrorFmt("scheduler commands are supported on macOS only", .{});

    const uid = std.c.getuid();
    const target = try std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, args.label });
    defer allocator.free(target);

    const out = try runCommandCapture(allocator, io, &.{ "launchctl", "print", target }, false);
    defer {
        allocator.free(out.stdout);
        allocator.free(out.stderr);
    }

    if (out.exit_code != 0) {
        return userErrorFmt("launchctl status unavailable for {s}: {s}", .{ args.label, std.mem.trim(u8, out.stderr, " \t\r\n") });
    }

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(out.stdout);
}

const CommandCapture = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
};

fn runCommandCapture(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, fail_on_nonzero: bool) !CommandCapture {
    const child = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(MaxCommandOutputBytes),
        .stderr_limit = .limited(MaxCommandOutputBytes),
    });

    const exit_code: u8 = switch (child.term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(@as(u32, 128) + @intFromEnum(signal), @as(u32, 255))),
        .stopped, .unknown => 1,
    };

    if (fail_on_nonzero and exit_code != 0) {
        defer allocator.free(child.stdout);
        defer allocator.free(child.stderr);
        return userErrorFmt("command failed ({s}): {s}", .{ argv[0], std.mem.trim(u8, child.stderr, " \t\r\n") });
    }

    return .{ .exit_code = exit_code, .stdout = child.stdout, .stderr = child.stderr };
}

fn printAutomationRowsJson(stdout: anytype, rows: []const AutomationRow) !void {
    try stdout.writeAll("[\n");
    for (rows, 0..) |row, idx| {
        try printAutomationRowJson(stdout, row, 2, false);
        if (idx + 1 != rows.len) {
            try stdout.writeAll(",\n");
        } else {
            try stdout.writeByte('\n');
        }
    }
    try stdout.writeAll("]\n");
}

fn buildAutomationRowsJsonAlloc(allocator: std.mem.Allocator, rows: []const AutomationRow) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try printAutomationRowsJson(w, rows);
    return writer_alloc.toOwnedSlice();
}

fn buildAutomationRowJsonAlloc(allocator: std.mem.Allocator, row: AutomationRow) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try printAutomationRowJson(w, row, 0, false);
    try w.writeByte('\n');
    return writer_alloc.toOwnedSlice();
}

fn printAutomationRowJson(stdout: anytype, row: AutomationRow, indent: usize, trailing_comma: bool) !void {
    const pad = "                                ";
    const prefix = pad[0..@min(indent, pad.len)];
    const field = pad[0..@min(indent + 2, pad.len)];

    try stdout.print("{s}{{\n", .{prefix});
    try stdout.print("{s}\"created_at\": {d},\n", .{ field, row.created_at });
    try stdout.print("{s}\"cwds\": ", .{field});
    try jsonWriteString(stdout, row.cwds_json);
    try stdout.writeAll(",\n");
    try stdout.print("{s}\"id\": ", .{field});
    try jsonWriteString(stdout, row.id);
    try stdout.writeAll(",\n");
    if (row.last_run_at) |value| {
        try stdout.print("{s}\"last_run_at\": {d},\n", .{ field, value });
    } else {
        try stdout.print("{s}\"last_run_at\": null,\n", .{field});
    }
    try stdout.print("{s}\"name\": ", .{field});
    try jsonWriteString(stdout, row.name);
    try stdout.writeAll(",\n");
    if (row.next_run_at) |value| {
        try stdout.print("{s}\"next_run_at\": {d},\n", .{ field, value });
    } else {
        try stdout.print("{s}\"next_run_at\": null,\n", .{field});
    }
    try stdout.print("{s}\"prompt\": ", .{field});
    try jsonWriteString(stdout, row.prompt);
    try stdout.writeAll(",\n");
    try stdout.print("{s}\"rrule\": ", .{field});
    try jsonWriteString(stdout, row.rrule);
    try stdout.writeAll(",\n");
    try stdout.print("{s}\"status\": ", .{field});
    try jsonWriteString(stdout, row.status);
    try stdout.writeAll(",\n");
    try stdout.print("{s}\"updated_at\": {d}\n", .{ field, row.updated_at });
    try stdout.print("{s}}}", .{prefix});
    if (trailing_comma) try stdout.writeByte(',');
}

fn printRunResultsJson(stdout: anytype, results: []const RunResult) !void {
    try stdout.writeAll("[\n");
    for (results, 0..) |item, idx| {
        try stdout.writeAll("  {\n");
        try stdout.writeAll("    \"id\": ");
        try jsonWriteString(stdout, item.id);
        try stdout.writeAll(",\n    \"status\": ");
        try jsonWriteString(stdout, item.status);
        try stdout.writeAll(",\n    \"thread_id\": ");
        try jsonWriteString(stdout, item.thread_id);
        try stdout.writeAll(",\n    \"cwd\": ");
        try jsonWriteString(stdout, item.cwd);
        if (item.next_run_at) |value| {
            try stdout.print(",\n    \"next_run_at\": {d}", .{value});
        } else {
            try stdout.writeAll(",\n    \"next_run_at\": null");
        }
        if (item.exit_code) |code| {
            try stdout.print(",\n    \"exit_code\": {d}", .{code});
        } else {
            try stdout.writeAll(",\n    \"exit_code\": null");
        }
        if (item.err) |err_text| {
            try stdout.writeAll(",\n    \"error\": ");
            try jsonWriteString(stdout, err_text);
        }
        try stdout.writeAll("\n  }");
        if (idx + 1 != results.len) try stdout.writeAll(",\n") else try stdout.writeByte('\n');
    }
    try stdout.writeAll("]\n");
}

fn buildRunResultsJsonAlloc(allocator: std.mem.Allocator, results: []const RunResult) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try printRunResultsJson(w, results);
    return writer_alloc.toOwnedSlice();
}

fn jsonWriteString(writer: anytype, value: []const u8) !void {
    var out = writer;
    try out.writeByte('\"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.writeAll("\\\\"),
            '\"' => try out.writeAll("\\\""),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try out.print("\\u{X:0>4}", .{@as(u16, ch)});
                } else {
                    try out.writeByte(ch);
                }
            },
        }
    }
    try out.writeByte('\"');
}

fn xmlEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;

    for (value) |ch| {
        switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '\"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&apos;"),
            else => try w.writeByte(ch),
        }
    }

    return writer_alloc.toOwnedSlice();
}

fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds });
    defer allocator.free(tmp);

    {
        var file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), tmp, .{}) catch |err| {
            return userErrorFmt("unable to create temp file ({s}): {s}", .{ tmp, @errorName(err) });
        };
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), contents) catch |err| {
            return userErrorFmt("unable to write temp file ({s}): {s}", .{ tmp, @errorName(err) });
        };
    }

    std.Io.Dir.renameAbsolute(tmp, path, std.Io.Threaded.global_single_threaded.io()) catch |err| {
        return userErrorFmt("unable to move temp file to target ({s}): {s}", .{ path, @errorName(err) });
    };
}

fn tomlQuoteAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try w.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(ch),
        }
    }
    try w.writeByte('"');

    return writer_alloc.toOwnedSlice();
}

fn renderTomlStringArray(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var writer_alloc = std.Io.Writer.Allocating.init(allocator);
    defer writer_alloc.deinit();
    const w = &writer_alloc.writer;
    try w.writeByte('[');
    for (values, 0..) |value, idx| {
        if (idx > 0) try w.writeAll(", ");
        const quoted = try tomlQuoteAlloc(allocator, value);
        defer allocator.free(quoted);
        try w.writeAll(quoted);
    }
    try w.writeByte(']');

    return writer_alloc.toOwnedSlice();
}

fn generateUuidV4(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds)));
    prng.random().bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

fn userErrorFmt(comptime fmt: []const u8, args: anytype) error{UserInput} {
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stderr = &stderr_writer.interface;
    _ = stderr.print("error: " ++ fmt ++ "\n", args) catch {};
    return error.UserInput;
}

fn createTestSchema(allocator: std.mem.Allocator, db: *Db) !void {
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

test "parseAndCanonicalizeRrule canonicalizes prefix and key order" {
    const alloc = std.testing.allocator;
    const rule = try parseAndCanonicalizeRrule(alloc, "freq=weekly;byday=mo,we,fr;byhour=9;byminute=0");
    defer alloc.free(rule);
    try std.testing.expectEqualStrings("RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=0", rule);
}

test "parseRrule rejects unsupported status tokens" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UserInput, parseAndCanonicalizeRrule(alloc, "RRULE:FREQ=MONTHLY;BYHOUR=9;BYMINUTE=0"));
}

test "nextWeekly computes next weekday correctly" {
    const alloc = std.testing.allocator;
    var rule = try parseRrule(alloc, "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0");
    defer rule.deinit(alloc);

    const dtstart = 1_772_469_600_000; // 2026-03-03T09:00:00Z (Tuesday)
    const anchor = 1_772_556_000_000; // later on 2026-03-04
    const next = try nextWeekly(rule, dtstart, anchor);
    try std.testing.expect(next > anchor);
}

test "generateUuidV4 emits expected shape" {
    const alloc = std.testing.allocator;
    const value = try generateUuidV4(alloc);
    defer alloc.free(value);

    try std.testing.expectEqual(@as(usize, 36), value.len);
    try std.testing.expectEqual('-', value[8]);
    try std.testing.expectEqual('-', value[13]);
    try std.testing.expectEqual('-', value[18]);
    try std.testing.expectEqual('-', value[23]);
}

test "parseSchedulerLabelArgs rejects invalid labels" {
    try std.testing.expectError(error.UserInput, parseSchedulerLabelArgs(&.{ "--label", "../bad" }));
    try std.testing.expectError(error.UserInput, parseSchedulerLabelArgs(&.{ "--label", "bad label" }));
}

test "parseRunDueArgs rejects invalid lock label" {
    try std.testing.expectError(error.UserInput, parseRunDueArgs(&.{ "--lock-label", "../bad" }));
    try std.testing.expectError(error.UserInput, parseRunDueArgs(&.{ "--lock-label", "bad label" }));
}

test "computeNextRunAt accepts legacy non-prefixed rrule" {
    const alloc = std.testing.allocator;
    var row = AutomationRow{
        .id = try alloc.dupe(u8, "legacy-id"),
        .name = try alloc.dupe(u8, "Legacy"),
        .prompt = try alloc.dupe(u8, "prompt"),
        .status = try alloc.dupe(u8, "ACTIVE"),
        .next_run_at = null,
        .last_run_at = null,
        .cwds_json = try alloc.dupe(u8, "[\"/tmp\"]"),
        .rrule = try alloc.dupe(u8, "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"),
        .created_at = 1_772_469_600_000,
        .updated_at = 1_772_469_600_000,
    };
    defer row.deinit(alloc);

    const anchor: i64 = 1_772_470_000_000;
    const next = try computeNextRunAt(alloc, &row, anchor);
    try std.testing.expect(next > anchor);
}

test "nowMs returns unix epoch milliseconds" {
    const value = nowMs();
    try std.testing.expect(value > 1_600_000_000_000);
    try std.testing.expect(value < 4_102_444_800_000);
}

test "automation rows json uses valid separators for multiple rows" {
    const alloc = std.testing.allocator;
    var rows = [_]AutomationRow{
        .{
            .id = try alloc.dupe(u8, "row-1"),
            .name = try alloc.dupe(u8, "First"),
            .prompt = try alloc.dupe(u8, "line one\nline two"),
            .status = try alloc.dupe(u8, "ACTIVE"),
            .next_run_at = null,
            .last_run_at = null,
            .cwds_json = try alloc.dupe(u8, "[]"),
            .rrule = try alloc.dupe(u8, "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0"),
            .created_at = 1,
            .updated_at = 1,
        },
        .{
            .id = try alloc.dupe(u8, "row-2"),
            .name = try alloc.dupe(u8, "Second"),
            .prompt = try alloc.dupe(u8, "prompt"),
            .status = try alloc.dupe(u8, "ACTIVE"),
            .next_run_at = null,
            .last_run_at = null,
            .cwds_json = try alloc.dupe(u8, "[]"),
            .rrule = try alloc.dupe(u8, "RRULE:FREQ=DAILY;BYHOUR=10;BYMINUTE=0"),
            .created_at = 2,
            .updated_at = 2,
        },
    };
    defer for (&rows) |*row| row.deinit(alloc);

    const json_text = try buildAutomationRowsJsonAlloc(alloc, rows[0..]);
    defer alloc.free(json_text);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "},,") == null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "},\n  {") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"prompt\": \"line one\\nline two\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"prompt\": \"line one\nline two\"") == null);
}

test "cmdUpdate preserves prompt text until sqlite step" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "codex-dev.db", .data = "" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "prompt.md", .data = "file prompt\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", alloc);
    defer alloc.free(root_abs);
    const db_path = try std.fs.path.join(alloc, &.{ root_abs, "codex-dev.db" });
    defer alloc.free(db_path);
    const prompt_path = try std.fs.path.join(alloc, &.{ root_abs, "prompt.md" });
    defer alloc.free(prompt_path);

    var db = try Db.open(alloc, db_path);
    defer db.close();
    try createTestSchema(alloc, &db);
    const created_at: i64 = 1_772_469_600_000;
    try db.exec(
        alloc,
        "insert into automations (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{
            .{ .text = "prompt-update-id" },
            .{ .text = "Prompt Update" },
            .{ .text = "initial prompt" },
            .{ .text = "ACTIVE" },
            .null,
            .null,
            .{ .text = "[]" },
            .{ .text = "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0" },
            .{ .int = created_at },
            .{ .int = created_at },
        },
    );

    var inline_args = try parseUpdateArgs(alloc, &.{ "--id", "prompt-update-id", "--prompt", "inline prompt" });
    defer inline_args.cwds.deinit(alloc);
    {
        const stdout_guard = try silenceStdout();
        defer restoreStdout(stdout_guard);
        try cmdUpdate(alloc, db_path, inline_args);
    }

    var inline_row = try getAutomationById(alloc, &db, "prompt-update-id");
    defer inline_row.deinit(alloc);
    try std.testing.expectEqualStrings("inline prompt", inline_row.prompt);

    var file_args = try parseUpdateArgs(alloc, &.{ "--id", "prompt-update-id", "--prompt-file", prompt_path });
    defer file_args.cwds.deinit(alloc);
    {
        const stdout_guard = try silenceStdout();
        defer restoreStdout(stdout_guard);
        try cmdUpdate(alloc, db_path, file_args);
    }

    var file_row = try getAutomationById(alloc, &db, "prompt-update-id");
    defer file_row.deinit(alloc);
    try std.testing.expectEqualStrings("file prompt", file_row.prompt);
}

test "cmdRunNow writes unix epoch milliseconds" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "codex-dev.db", .data = "" });
    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", alloc);
    defer alloc.free(root_abs);
    const db_path = try std.fs.path.join(alloc, &.{ root_abs, "codex-dev.db" });
    defer alloc.free(db_path);
    const automation_root = try std.fs.path.join(alloc, &.{ root_abs, ".codex", "automations" });
    defer alloc.free(automation_root);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), automation_root);

    perf_automation_root_override = automation_root;
    defer perf_automation_root_override = null;

    var db = try Db.open(alloc, db_path);
    defer db.close();
    try createTestSchema(alloc, &db);

    const created_at: i64 = 1_772_469_600_000;
    try db.exec(
        alloc,
        "insert into automations (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{
            .{ .text = "run-now-id" },
            .{ .text = "Run Now" },
            .{ .text = "noop prompt" },
            .{ .text = "ACTIVE" },
            .null,
            .null,
            .{ .text = "[]" },
            .{ .text = "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0" },
            .{ .int = created_at },
            .{ .int = created_at },
        },
    );

    const before = nowMs();
    {
        const stdout_guard = try silenceStdout();
        defer restoreStdout(stdout_guard);
        try cmdRunNow(alloc, db_path, .{ .automation_id = "run-now-id" });
    }
    const after = nowMs();

    var row = try getAutomationById(alloc, &db, "run-now-id");
    defer row.deinit(alloc);
    const next = row.next_run_at orelse return error.TestUnexpectedResult;
    try std.testing.expect(next >= before);
    try std.testing.expect(next <= after);
    try std.testing.expect(row.updated_at >= before);
    try std.testing.expect(row.updated_at <= after);
}

test "xmlEscapeAlloc escapes plist string metacharacters" {
    const alloc = std.testing.allocator;
    const escaped = try xmlEscapeAlloc(alloc, "a&b<c>d\"e'f");
    defer alloc.free(escaped);
    try std.testing.expectEqualStrings("a&amp;b&lt;c&gt;d&quot;e&apos;f", escaped);
}

test "runDueAutomation dry-run is read-only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "codex-dev.db", .data = "" });
    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", alloc);
    defer alloc.free(root_abs);
    const db_path = try std.fs.path.join(alloc, &.{ root_abs, "codex-dev.db" });
    defer alloc.free(db_path);

    var db = try Db.open(alloc, db_path);
    defer db.close();

    try db.exec(alloc,
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
    try db.exec(alloc,
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

    const created_at: i64 = 1_772_469_600_000;
    try db.exec(
        alloc,
        "insert into automations (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{
            .{ .text = "dry-run-id" },
            .{ .text = "Dry Run" },
            .{ .text = "noop prompt" },
            .{ .text = "ACTIVE" },
            .null,
            .null,
            .{ .text = "[\"/tmp\"]" },
            .{ .text = "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0" },
            .{ .int = created_at },
            .{ .int = created_at },
        },
    );

    var row = try getAutomationById(alloc, &db, "dry-run-id");
    defer row.deinit(alloc);
    const before_last = row.last_run_at;
    const before_next = row.next_run_at;

    const result = try runDueAutomation(alloc, std.Io.Threaded.global_single_threaded.io(), &db, &row, "codex", true);
    defer alloc.free(result.thread_id);
    defer alloc.free(result.cwd);
    if (result.err) |err_text| alloc.free(err_text);

    try std.testing.expectEqualStrings("dry_run", result.status);
    try std.testing.expect(result.thread_id.len > 0);
    try std.testing.expectEqualStrings("/tmp", result.cwd);

    var runs_stmt = try db.prepare(alloc, "select count(*) from automation_runs where automation_id = ?");
    defer runs_stmt.deinit();
    try runs_stmt.bindAll(&.{.{ .text = "dry-run-id" }});
    switch (try runs_stmt.step()) {
        .row => try std.testing.expectEqual(@as(i64, 0), runs_stmt.intColumn(0)),
        .done => unreachable,
    }

    var after = try getAutomationById(alloc, &db, "dry-run-id");
    defer after.deinit(alloc);
    try std.testing.expectEqual(before_last, after.last_run_at);
    try std.testing.expectEqual(before_next, after.next_run_at);
}

test "runDueAutomation non-dry-run finalizes run row with provided io" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "codex-dev.db", .data = "" });
    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", alloc);
    defer alloc.free(root_abs);
    const db_path = try std.fs.path.join(alloc, &.{ root_abs, "codex-dev.db" });
    defer alloc.free(db_path);

    var db = try Db.open(alloc, db_path);
    defer db.close();
    try createTestSchema(alloc, &db);

    const created_at: i64 = 1_772_469_600_000;
    try db.exec(
        alloc,
        "insert into automations (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        &.{
            .{ .text = "run-due-id" },
            .{ .text = "Run Due" },
            .{ .text = "noop prompt" },
            .{ .text = "ACTIVE" },
            .null,
            .null,
            .{ .text = "[]" },
            .{ .text = "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0" },
            .{ .int = created_at },
            .{ .int = created_at },
        },
    );

    var row = try getAutomationById(alloc, &db, "run-due-id");
    defer row.deinit(alloc);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const result = try runDueAutomation(alloc, threaded.io(), &db, &row, "/bin/echo", false);
    defer alloc.free(result.thread_id);
    defer alloc.free(result.cwd);
    if (result.err) |err_text| alloc.free(err_text);

    try std.testing.expectEqualStrings("ok", result.status);

    var runs_stmt = try db.prepare(alloc, "select status from automation_runs where automation_id = ?");
    defer runs_stmt.deinit();
    try runs_stmt.bindAll(&.{.{ .text = "run-due-id" }});
    switch (try runs_stmt.step()) {
        .row => try std.testing.expectEqualStrings("PENDING_REVIEW", runs_stmt.textColumn(0)),
        .done => unreachable,
    }
}

test "runPerfCase covers residual cron command families" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", alloc);
    defer alloc.free(root_abs);
    try runPerfCase(alloc, .show, root_abs);
    try runPerfCase(alloc, .create, root_abs);
    try runPerfCase(alloc, .update, root_abs);
    try runPerfCase(alloc, .enable, root_abs);
    try runPerfCase(alloc, .disable, root_abs);
    try runPerfCase(alloc, .run_now, root_abs);
    try runPerfCase(alloc, .run_due, root_abs);
    try runPerfCase(alloc, .delete, root_abs);

    const db_path = try std.fs.path.join(alloc, &.{ root_abs, "codex-dev.db" });
    defer alloc.free(db_path);
    var db = try Db.open(alloc, db_path);
    defer db.close();
    try std.testing.expectError(error.UserInput, getAutomationById(alloc, &db, "cron-001"));
}

test "lock acquisition is fail-closed while lock exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", alloc);
    defer alloc.free(root_abs);
    const lock_dir = try std.fs.path.join(alloc, &.{ root_abs, "locks" });
    defer alloc.free(lock_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), lock_dir);
    const lock_path = try std.fs.path.join(alloc, &.{ lock_dir, "run.lock" });
    defer alloc.free(lock_path);

    var first = try acquireExclusiveLockWithStaleRetry(alloc, lock_path);
    try std.testing.expect(first != null);

    const second = try acquireExclusiveLockWithStaleRetry(alloc, lock_path);
    try std.testing.expect(second == null);

    releaseRunLock(alloc, first);
    first = null;

    const third = try acquireExclusiveLockWithStaleRetry(alloc, lock_path);
    try std.testing.expect(third != null);
    releaseRunLock(alloc, third);
}

test "parseCommand recognizes the exported command surface" {
    for (command_defs) |def| {
        try std.testing.expectEqual(def.command, parseCommand(def.name));
    }
    try std.testing.expectEqual(Command.unknown, parseCommand("nope"));
}

test "parseSchedulerCommand recognizes exported scheduler actions" {
    for (scheduler_command_defs) |def| {
        try std.testing.expectEqual(def.command, parseSchedulerCommand(def.name));
    }
    try std.testing.expectEqual(SchedulerCommand.unknown, parseSchedulerCommand("bogus"));
}
