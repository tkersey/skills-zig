const app_meta = @import("app_meta");
const automation_files = @import("automation/files.zig");
const automation_output = @import("automation/output.zig");
const automation_rrule = @import("automation/rrule.zig");
const automation_runner = @import("automation/runner.zig");
const automation_scheduler = @import("automation/scheduler.zig");
const automation_store = @import("automation/store.zig");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);

const SourceFile = "cas_automation.zig";
const DefaultCodexBin = "codex";
const DefaultLaunchdLabel = "com.openai.codex.automation-runner";
const DefaultIntervalSeconds: i64 = 60;

fn envString(key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(value);
}

pub const Command = enum {
    doctor,
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
    .{
        .name = "doctor",
        .command = .doctor,
        .summary = "Inspect store, files, Codex, and scheduler safety",
    },
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
    .{
        .name = "install",
        .command = .install,
        .summary = "Install/start launchd scheduler (macOS)",
    },
    .{
        .name = "uninstall",
        .command = .uninstall,
        .summary = "Stop/remove launchd scheduler (macOS)",
    },
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
    const automation_root = try std.fs.path.join(
        allocator,
        &.{ temp_root, ".codex", "automations" },
    );
    defer allocator.free(automation_root);
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, automation_root);
    automation_files.setAutomationRootOverride(automation_root);
    defer automation_files.setAutomationRootOverride(null);
    try seedPerfDb(allocator, db_path);

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    switch (case) {
        .show => try run(
            allocator,
            io,
            &.{ "--db", db_path, "show", "--id", "cron-001" },
        ),
        .create => try run(
            allocator,
            io,
            &.{
                "--db",
                db_path,
                "create",
                "--name",
                "Created Perf",
                "--prompt",
                "noop prompt",
                "--rrule",
                "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=15",
            },
        ),
        .update => try run(
            allocator,
            io,
            &.{ "--db", db_path, "update", "--id", "cron-001", "--new-name", "Updated Perf" },
        ),
        .enable => try run(
            allocator,
            io,
            &.{ "--db", db_path, "enable", "--id", "cron-001" },
        ),
        .disable => try run(
            allocator,
            io,
            &.{ "--db", db_path, "disable", "--id", "cron-001" },
        ),
        .run_now => try run(
            allocator,
            io,
            &.{ "--db", db_path, "run-now", "--id", "cron-001" },
        ),
        .delete => try run(
            allocator,
            io,
            &.{ "--db", db_path, "delete", "--id", "cron-001" },
        ),
        .run_due => try run(
            allocator,
            io,
            &.{ "--db", db_path, "run-due", "--id", "cron-001", "--dry-run" },
        ),
    }
}

const StdoutGuard = struct {
    saved_fd: std.posix.fd_t,
    devnull: std.Io.File,
};

fn silenceStdout() !StdoutGuard {
    const saved_fd = std.c.dup(std.posix.STDOUT_FILENO);
    if (saved_fd < 0) return error.SystemResources;
    const devnull = try std.Io.Dir.openFileAbsolute(
        std.Io.Threaded.global_single_threaded.io(),
        "/dev/null",
        .{ .mode = .write_only },
    );
    if (std.c.dup2(devnull.handle, std.posix.STDOUT_FILENO) < 0) return error.SystemResources;
    return .{ .saved_fd = saved_fd, .devnull = devnull };
}

fn restoreStdout(guard: StdoutGuard) void {
    _ = std.c.dup2(guard.saved_fd, std.posix.STDOUT_FILENO);
    _ = std.c.close(guard.saved_fd);
    guard.devnull.close(std.Io.Threaded.global_single_threaded.io());
}

fn ignoreError(result: anyerror!void) void {
    result catch return;
}

pub const AutomationStatus = automation_store.AutomationStatus;
const AutomationRow = automation_store.AutomationRow;
const Day = automation_rrule.Day;
const Freq = automation_rrule.Freq;
const RRule = automation_rrule.RRule;

pub const ResolveArgs = automation_store.ResolveArgs;
pub const CwdsMode = automation_store.CwdsMode;
pub const CwdsInput = automation_store.CwdsInput;
pub const CreateArgs = automation_store.CreateArgs;
pub const UpdateArgs = automation_store.UpdateArgs;
pub const ListArgs = automation_store.ListArgs;
pub const ShowArgs = automation_store.ShowArgs;

pub const RunDueArgs = struct {
    automation_id: ?[]const u8,
    limit: usize,
    dry_run: bool,
    codex_bin: []const u8,
    lock_label: []const u8,
};

const SchedulerInstallArgs = automation_scheduler.SchedulerInstallArgs;
const SchedulerLabelArgs = automation_scheduler.SchedulerLabelArgs;

const DoctorArgs = automation_store.DoctorArgs;

const RunResult = automation_runner.RunResult;

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
        ignoreError(stderr.print("error: {s}: {s}\n", .{ @errorName(err), SourceFile }));
        std.process.exit(1);
    };
}

fn run(allocator: std.mem.Allocator, io: std.Io, raw_args: []const []const u8) !void {
    const global = try parseGlobalArgs(allocator, raw_args);
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

    return dispatchCommand(allocator, io, global.db_path, global.args, command);
}

fn dispatchCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    args: []const []const u8,
    command: Command,
) !void {
    switch (command) {
        .doctor => {
            const parsed = try parseDoctorArgs(args[1..]);
            try cmdDoctor(allocator, io, db_path, parsed);
            return;
        },
        .list => {
            const parsed = try parseListArgs(args[1..]);
            try cmdList(allocator, db_path, parsed);
            return;
        },
        .show => {
            const parsed = try parseShowArgs(args[1..]);
            try cmdShow(allocator, db_path, parsed);
            return;
        },
        .create => {
            var parsed = try parseCreateArgs(allocator, args[1..]);
            defer parsed.cwds.deinit(allocator);
            try cmdCreate(allocator, db_path, parsed);
            return;
        },
        .update => {
            var parsed = try parseUpdateArgs(allocator, args[1..]);
            defer parsed.cwds.deinit(allocator);
            try cmdUpdate(allocator, db_path, parsed);
            return;
        },
        .enable => {
            const resolve = try parseResolveOnly(args[1..]);
            try cmdEnableDisable(allocator, db_path, resolve, .ACTIVE);
            return;
        },
        .disable => {
            const resolve = try parseResolveOnly(args[1..]);
            try cmdEnableDisable(allocator, db_path, resolve, .PAUSED);
            return;
        },
        .run_now => {
            const resolve = try parseResolveOnly(args[1..]);
            try cmdRunNow(allocator, db_path, resolve);
            return;
        },
        .delete => {
            const resolve = try parseResolveOnly(args[1..]);
            try cmdDelete(allocator, db_path, resolve);
            return;
        },
        .run_due => {
            const parsed = try parseRunDueArgs(args[1..]);
            try cmdRunDue(allocator, io, db_path, parsed);
            return;
        },
        .scheduler => {
            try cmdScheduler(allocator, io, args[1..]);
            return;
        },
        .unknown => {},
    }

    return userErrorFmt("unknown command: {s}", .{args[0]});
}

fn parseDoctorArgs(args: []const []const u8) !DoctorArgs {
    var out: DoctorArgs = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
        } else {
            return userErrorFmt("unknown doctor arg: {s}", .{arg});
        }
    }
    return out;
}

fn printUsage() !void {
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\cas automation
        \\
        \\Manage Codex automations with native Zig runtime (no Python/shell delegation).
        \\
        \\Usage:
        \\  cas automation [--db <path>] <command> [options]
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
        if (try parseCwdsArg(allocator, args, &i, &cwds, .inherit_default)) continue;
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

fn parseCwdsArg(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    index: *usize,
    cwds: *CwdsInput,
    initial_mode: CwdsMode,
) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--cwd")) {
        if (index.* + 1 >= args.len) return userErrorFmt("--cwd requires a value", .{});
        if (cwds.mode != initial_mode and cwds.mode != .list) {
            return userErrorFmt(
                "--cwd cannot be combined with --cwds-json/--clear-cwds",
                .{},
            );
        }
        cwds.mode = .list;
        try cwds.list.append(allocator, args[index.* + 1]);
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--cwds-json")) {
        if (index.* + 1 >= args.len) {
            return userErrorFmt("--cwds-json requires a value", .{});
        }
        if (cwds.mode != initial_mode) {
            return userErrorFmt(
                "--cwds-json cannot be combined with --cwd/--clear-cwds",
                .{},
            );
        }
        cwds.mode = .json;
        cwds.json_text = args[index.* + 1];
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--clear-cwds")) {
        if (cwds.mode != initial_mode) {
            return userErrorFmt(
                "--clear-cwds cannot be combined with --cwd/--cwds-json",
                .{},
            );
        }
        cwds.mode = .clear;
        return true;
    }
    return false;
}

fn parseResolveArg(
    args: []const []const u8,
    index: *usize,
    resolve: *ResolveArgs,
) !bool {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--id")) {
        if (index.* + 1 >= args.len) return userErrorFmt("--id requires a value", .{});
        resolve.automation_id = args[index.* + 1];
        index.* += 1;
        return true;
    }
    if (std.mem.eql(u8, arg, "--name")) {
        if (index.* + 1 >= args.len) return userErrorFmt("--name requires a value", .{});
        resolve.name = args[index.* + 1];
        index.* += 1;
        return true;
    }
    return false;
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
        if (try parseResolveArg(args, &i, &resolve)) continue;
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
        if (try parseCwdsArg(allocator, args, &i, &cwds, .unchanged)) continue;
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
    var lock_label: []const u8 =
        envString("CAS_AUTOMATION_LAUNCHD_LABEL") orelse DefaultLaunchdLabel;

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
    if (args.len == 0) {
        return userErrorFmt(
            "scheduler requires one of: install, uninstall, status",
            .{},
        );
    }
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
    var label: []const u8 = envString("CAS_AUTOMATION_LAUNCHD_LABEL") orelse DefaultLaunchdLabel;
    var interval_seconds: i64 = blk: {
        if (envString("CAS_AUTOMATION_LAUNCHD_INTERVAL_SECONDS")) |value| {
            break :blk try parsePositiveI64(value, "CAS_AUTOMATION_LAUNCHD_INTERVAL_SECONDS");
        }
        break :blk DefaultIntervalSeconds;
    };
    var path_value: []const u8 = envString("CAS_AUTOMATION_LAUNCHD_PATH") orelse
        envString("PATH") orelse
        "/usr/bin:/bin:/usr/sbin:/sbin";
    var codex_bin: []const u8 = envString("CODEX_BIN") orelse DefaultCodexBin;
    var replace = false;

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
        if (std.mem.eql(u8, arg, "--replace")) {
            replace = true;
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
        .replace = replace,
    };
}

fn parseSchedulerLabelArgs(args: []const []const u8) !SchedulerLabelArgs {
    var label: []const u8 = envString("CAS_AUTOMATION_LAUNCHD_LABEL") orelse DefaultLaunchdLabel;
    var json = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--label")) {
            if (i + 1 >= args.len) return userErrorFmt("--label requires a value", .{});
            label = args[i + 1];
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            continue;
        }
        return userErrorFmt("unknown scheduler arg: {s}", .{arg});
    }

    return .{ .label = try validateSchedulerLabel(label), .json = json };
}

fn validateResolveArgs(resolve: ResolveArgs) !void {
    if (resolve.automation_id == null and resolve.name == null) {
        return userErrorFmt("provide --id or --name", .{});
    }
    if (resolve.automation_id != null and resolve.name != null) {
        return userErrorFmt("use either --id or --name", .{});
    }
}

const validateSchedulerLabel = automation_scheduler.validateSchedulerLabel;

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

const c = automation_store.c;
const SqlParam = automation_store.SqlParam;
const Db = automation_store.Db;
const Stmt = automation_store.Stmt;
const StepResult = automation_store.StepResult;
const DoctorDiagnostics = automation_store.DoctorDiagnostics;
const nowMs = automation_store.nowMs;
const alignMsToMinute = automation_rrule.alignMsToMinute;
const civilFromDays = automation_rrule.civilFromDays;
const weekdayMon = automation_rrule.weekdayMon;
const parseHmsFromMs = automation_rrule.parseHmsFromMs;
const timestampStringUtc = automation_rrule.timestampStringUtc;
const dateStringUtc = automation_rrule.dateStringUtc;
const parseAndCanonicalizeRrule = automation_rrule.parseAndCanonicalizeRrule;
const parseRrule = automation_rrule.parseRrule;
const renderCanonicalRrule = automation_rrule.renderCanonicalRrule;
const containsDay = automation_rrule.containsDay;
const validateAutomationId = automation_store.validateAutomationId;
const defaultDbPath = automation_store.defaultDbPath;
const seedPerfDb = automation_store.seedPerfDb;
const automationDirPath = automation_files.automationDirPath;
const readPrompt = automation_files.readPrompt;
const parseCwdsJson = automation_files.parseCwdsJson;
const freeOwnedStrings = automation_files.freeOwnedStrings;
const currentPathOwned = automation_store.currentPathOwned;
const encodeStringArrayJson = automation_store.encodeStringArrayJson;
const resolveCwdsForCreate = automation_store.resolveCwdsForCreate;
const resolveCwdsForUpdate = automation_store.resolveCwdsForUpdate;
const getAutomationByResolve = automation_store.getAutomationByResolve;
const getAutomationById = automation_store.getAutomationById;
const getAutomationByName = automation_store.getAutomationByName;
const readAutomationRow = automation_store.readAutomationRow;
const syncAutomationFilesAfterCommit = automation_store.syncAutomationFilesAfterCommit;
const renderAutomationTomlAlloc = automation_files.renderAutomationTomlAlloc;
const cmdDoctor = automation_store.cmdDoctor;
const cmdList = automation_store.cmdList;
const cmdShow = automation_store.cmdShow;
const cmdShowByIdPlain = automation_store.cmdShowByIdPlain;
const cmdCreate = automation_store.cmdCreate;
const cmdUpdate = automation_store.cmdUpdate;
const cmdEnableDisable = automation_store.cmdEnableDisable;
const cmdRunNow = automation_store.cmdRunNow;
const cmdDelete = automation_store.cmdDelete;
const cmdRunDue = automation_runner.cmdRunDue;
const selectDueAutomations = automation_runner.selectDueAutomations;
const validateDueBatch = automation_runner.validateDueBatch;
const runDueAutomation = automation_runner.runDueAutomation;
const computeNextRunAt = automation_rrule.computeNextRunAt;
const nextHourly = automation_rrule.nextHourly;
const nextDaily = automation_rrule.nextDaily;
const nextWeekly = automation_rrule.nextWeekly;
const weekdayAllowed = automation_rrule.weekdayAllowed;
const closeStaleRunningRows = automation_runner.closeStaleRunningRows;
const firstLine = automation_runner.firstLine;
const firstMeaningfulLine = automation_runner.firstMeaningfulLine;
const summarizeOutput = automation_runner.summarizeOutput;
const collapseWhitespace = automation_runner.collapseWhitespace;
const insertRunRow = automation_runner.insertRunRow;
const updateRunRow = automation_runner.updateRunRow;
const updateAutomationTimes = automation_runner.updateAutomationTimes;
const CodexRunResult = automation_runner.CodexRunResult;
const runCodexExec = automation_runner.runCodexExec;
const tmpAutomationRunnerDir = automation_runner.tmpAutomationRunnerDir;
const acquireRunLock = automation_runner.acquireRunLock;
const acquireExclusiveLockWithStaleRetry = automation_runner.acquireExclusiveLockWithStaleRetry;
const releaseRunLock = automation_runner.releaseRunLock;
const resolveExecutable = automation_store.resolveExecutable;
const cmdSchedulerInstall = automation_scheduler.cmdSchedulerInstall;
const cmdSchedulerUninstall = automation_scheduler.cmdSchedulerUninstall;
const cmdSchedulerStatus = automation_scheduler.cmdSchedulerStatus;
const readSchedulerStatus = automation_scheduler.readSchedulerStatus;
const renderLaunchdProgramArguments = automation_scheduler.renderLaunchdProgramArguments;
const parsePlistProgramArguments = automation_scheduler.parsePlistProgramArguments;
const parseLaunchctlProgramArguments = automation_scheduler.parseLaunchctlProgramArguments;
const projectLoadedProgramArguments = automation_scheduler.projectLoadedProgramArguments;
const schedulerArgumentsMatchCas = automation_scheduler.schedulerArgumentsMatchCas;
const classifySchedulerSurface = automation_scheduler.classifySchedulerSurface;
const buildAutomationRowsJsonAlloc = automation_output.buildAutomationRowsJsonAlloc;
const buildAutomationRowJsonAlloc = automation_output.buildAutomationRowJsonAlloc;
const printRunResultsJson = automation_output.printRunResultsJson;
const buildRunResultsJsonAlloc = automation_output.buildRunResultsJsonAlloc;
const jsonWriteString = automation_output.jsonWriteString;
const xmlEscapeAlloc = automation_output.xmlEscapeAlloc;
const writeFileAtomic = automation_output.writeFileAtomic;
const tomlQuoteAlloc = automation_output.tomlQuoteAlloc;
const renderTomlStringArray = automation_output.renderTomlStringArray;
const generateUuidV4 = automation_store.generateUuidV4;
const userErrorFmt = automation_output.userErrorFmt;
const createTestSchema = automation_store.createTestSchema;
const inspectStoreSchema = automation_store.inspectStoreSchema;
const inspectMutationWritability = automation_store.inspectMutationWritability;

const insert_automation_sql =
    "insert into automations " ++
    "(id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at) " ++
    "values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

test "parseAndCanonicalizeRrule canonicalizes prefix and key order" {
    const alloc = std.testing.allocator;
    const rule = try parseAndCanonicalizeRrule(
        alloc,
        "freq=weekly;byday=mo,we,fr;byhour=9;byminute=0",
    );
    defer alloc.free(rule);
    try std.testing.expectEqualStrings(
        "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=0",
        rule,
    );
}

test "parseRrule rejects unsupported status tokens" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.UserInput,
        parseAndCanonicalizeRrule(alloc, "RRULE:FREQ=MONTHLY;BYHOUR=9;BYMINUTE=0"),
    );
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
    try std.testing.expectError(
        error.UserInput,
        parseSchedulerLabelArgs(&.{ "--label", "../bad" }),
    );
    try std.testing.expectError(
        error.UserInput,
        parseSchedulerLabelArgs(&.{ "--label", "bad label" }),
    );
}

test "parseRunDueArgs rejects invalid lock label" {
    try std.testing.expectError(error.UserInput, parseRunDueArgs(&.{ "--lock-label", "../bad" }));
    try std.testing.expectError(
        error.UserInput,
        parseRunDueArgs(&.{ "--lock-label", "bad label" }),
    );
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
    try std.testing.expect(
        std.mem.indexOf(u8, json_text, "\"prompt\": \"line one\\nline two\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, json_text, "\"prompt\": \"line one\nline two\"") == null,
    );
}

test "cmdUpdate preserves prompt text until sqlite step" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "codex-dev.db", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "prompt.md", .data = "file prompt\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
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
        insert_automation_sql,
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

    var inline_args = try parseUpdateArgs(
        alloc,
        &.{ "--id", "prompt-update-id", "--prompt", "inline prompt" },
    );
    defer inline_args.cwds.deinit(alloc);
    {
        const stdout_guard = try silenceStdout();
        defer restoreStdout(stdout_guard);
        try cmdUpdate(alloc, db_path, inline_args);
    }

    var inline_row = try getAutomationById(alloc, &db, "prompt-update-id");
    defer inline_row.deinit(alloc);
    try std.testing.expectEqualStrings("inline prompt", inline_row.prompt);

    var file_args = try parseUpdateArgs(
        alloc,
        &.{ "--id", "prompt-update-id", "--prompt-file", prompt_path },
    );
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
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "codex-dev.db", .data = "" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root_abs);
    const db_path = try std.fs.path.join(alloc, &.{ root_abs, "codex-dev.db" });
    defer alloc.free(db_path);
    const automation_root = try std.fs.path.join(alloc, &.{ root_abs, ".codex", "automations" });
    defer alloc.free(automation_root);
    try std.Io.Dir.cwd().createDirPath(io, automation_root);

    automation_files.setAutomationRootOverride(automation_root);
    defer automation_files.setAutomationRootOverride(null);

    var db = try Db.open(alloc, db_path);
    defer db.close();
    try createTestSchema(alloc, &db);

    const created_at: i64 = 1_772_469_600_000;
    try db.exec(
        alloc,
        insert_automation_sql,
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

test "launchd ProgramArguments invoke cas automation run-due" {
    const rendered = try renderLaunchdProgramArguments(std.testing.allocator, "/opt/cas/bin/cas");
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "  <key>ProgramArguments</key>\n" ++
            "  <array>\n" ++
            "    <string>/opt/cas/bin/cas</string>\n" ++
            "    <string>automation</string>\n" ++
            "    <string>run-due</string>\n" ++
            "  </array>\n",
        rendered,
    );
}

test "scheduler surface distinguishes CAS adoption from standalone Cron" {
    var cas_args = [_][]u8{
        @constCast("/opt/cas/bin/cas"),
        @constCast("automation"),
        @constCast("run-due"),
    };
    try std.testing.expectEqualStrings("cas-automation", classifySchedulerSurface(&cas_args));
    var cron_args = [_][]u8{
        @constCast("/opt/homebrew/bin/cron"),
        @constCast("run-due"),
    };
    try std.testing.expectEqualStrings("standalone-cron", classifySchedulerSurface(&cron_args));
    var unknown_args = [_][]u8{@constCast("/bin/false")};
    try std.testing.expectEqualStrings("unknown", classifySchedulerSurface(&unknown_args));
}

test "plist ProgramArguments parser is bounded to the selected array" {
    const plist =
        "<dict><key>ProgramArguments</key><array>" ++
        "<string>/opt/cas/bin/cas</string><string>automation</string><string>run-due</string>" ++
        "</array><key>Other</key><array><string>ignored</string></array></dict>";
    var args: std.ArrayList([]u8) = .empty;
    defer {
        for (args.items) |arg| std.testing.allocator.free(arg);
        args.deinit(std.testing.allocator);
    }
    try parsePlistProgramArguments(std.testing.allocator, plist, &args);
    try std.testing.expectEqual(@as(usize, 3), args.items.len);
    try std.testing.expectEqualStrings("cas-automation", classifySchedulerSurface(args.items));
}

test "launchctl ProgramArguments parser verifies the loaded same-label arguments" {
    const loaded_state =
        \\gui/501/com.openai.codex.automation-runner = {
        \\    path = /Users/test/Library/LaunchAgents/com.openai.codex.automation-runner.plist
        \\    program = /opt/cas/bin/cas
        \\    arguments = {
        \\        /opt/cas/bin/cas
        \\        automation
        \\        run-due
        \\    }
        \\}
    ;
    var loaded_args: std.ArrayList([]u8) = .empty;
    defer freeOwnedStrings(std.testing.allocator, loaded_args);
    try parseLaunchctlProgramArguments(std.testing.allocator, loaded_state, &loaded_args);
    try std.testing.expect(schedulerArgumentsMatchCas(loaded_args.items, "/opt/cas/bin/cas"));
    try std.testing.expect(!schedulerArgumentsMatchCas(loaded_args.items, "/different/cas"));
}

test "scheduler adoption does not trust a CAS plist when launchd loaded Cron" {
    var status_args: std.ArrayList([]u8) = .empty;
    defer freeOwnedStrings(std.testing.allocator, status_args);
    try status_args.append(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, "/opt/cas/bin/cas"),
    );
    try status_args.append(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, "automation"),
    );
    try status_args.append(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, "run-due"),
    );
    try std.testing.expectEqualStrings(
        "cas-automation",
        classifySchedulerSurface(status_args.items),
    );

    const loaded_state =
        \\gui/501/com.openai.codex.automation-runner = {
        \\    program = /opt/homebrew/bin/cron
        \\    arguments = {
        \\        /opt/homebrew/bin/cron
        \\        run-due
        \\    }
        \\}
    ;
    try std.testing.expect(try projectLoadedProgramArguments(
        std.testing.allocator,
        loaded_state,
        &status_args,
    ));
    try std.testing.expectEqual(@as(usize, 2), status_args.items.len);
    try std.testing.expectEqualStrings("/opt/homebrew/bin/cron", status_args.items[0]);
    try std.testing.expectEqualStrings("run-due", status_args.items[1]);
    const surface = classifySchedulerSurface(status_args.items);
    try std.testing.expectEqualStrings("standalone-cron", surface);
    const migration_required = std.mem.eql(u8, surface, "standalone-cron");
    try std.testing.expect(migration_required);
    try std.testing.expect(!schedulerArgumentsMatchCas(status_args.items, "/opt/cas/bin/cas"));
}

test "loaded scheduler projection fails closed instead of retaining plist arguments" {
    var status_args: std.ArrayList([]u8) = .empty;
    defer freeOwnedStrings(std.testing.allocator, status_args);
    try status_args.append(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, "/opt/cas/bin/cas"),
    );
    try status_args.append(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, "automation"),
    );
    try status_args.append(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, "run-due"),
    );

    const malformed_loaded_state =
        \\arguments = {
        \\    /opt/homebrew/bin/cron
        \\    run-due
    ;
    try std.testing.expect(!try projectLoadedProgramArguments(
        std.testing.allocator,
        malformed_loaded_state,
        &status_args,
    ));
    try std.testing.expectEqual(@as(usize, 0), status_args.items.len);
    try std.testing.expectEqualStrings("unknown", classifySchedulerSurface(status_args.items));
}

test "launchctl ProgramArguments parser rejects an unbounded argument list" {
    var fixture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer fixture.deinit();
    try fixture.writer.writeAll("arguments = {\n");
    for (0..33) |index| try fixture.writer.print("  arg-{d}\n", .{index});
    try fixture.writer.writeAll("}\n");
    const loaded_state = try fixture.toOwnedSlice();
    defer std.testing.allocator.free(loaded_state);

    var loaded_args: std.ArrayList([]u8) = .empty;
    defer freeOwnedStrings(std.testing.allocator, loaded_args);
    try std.testing.expectError(
        error.TooManyProgramArguments,
        parseLaunchctlProgramArguments(
            std.testing.allocator,
            loaded_state,
            &loaded_args,
        ),
    );
}

test "store schema gate accepts additive columns and rejects missing required tables" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "codex-dev.db", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const db_path = try std.fs.path.join(alloc, &.{ root, "codex-dev.db" });
    defer alloc.free(db_path);
    var db = try Db.open(alloc, db_path);
    defer db.close();
    try createTestSchema(alloc, &db);
    try db.exec(alloc, "alter table automations add column future_metadata text", &.{});
    var compatible: DoctorDiagnostics = .{};
    defer compatible.deinit(alloc);
    try inspectStoreSchema(alloc, &db, &compatible);
    try std.testing.expect(!compatible.hasError());
    var saw_additive = false;
    for (compatible.rows.items) |row| {
        if (std.mem.eql(u8, row.code, "additive-column")) saw_additive = true;
    }
    try std.testing.expect(saw_additive);

    try db.exec(alloc, "drop table inbox_items", &.{});
    var incompatible: DoctorDiagnostics = .{};
    defer incompatible.deinit(alloc);
    try inspectStoreSchema(alloc, &db, &incompatible);
    try std.testing.expect(incompatible.hasError());
}

fn expectWritabilityDiagnostic(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    automation_root: []const u8,
    expected_code: []const u8,
) !void {
    var blocked: DoctorDiagnostics = .{};
    defer blocked.deinit(allocator);
    try inspectMutationWritability(allocator, db_path, automation_root, &blocked);
    for (blocked.rows.items) |row| {
        if (std.mem.eql(u8, row.code, expected_code)) return;
    }
    return error.TestUnexpectedResult;
}

fn databaseFilePermissionBlocks(
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    automation_root: []const u8,
) !bool {
    var db_file = try std.Io.Dir.cwd().openFile(io, db_path, .{ .mode = .read_write });
    defer db_file.close(io);
    try db_file.setPermissions(io, std.Io.File.Permissions.fromMode(0o400));
    defer ignoreError(db_file.setPermissions(io, std.Io.File.Permissions.fromMode(0o600)));
    std.Io.Dir.cwd().access(io, db_path, .{ .write = true }) catch {
        try expectWritabilityDiagnostic(
            allocator,
            db_path,
            automation_root,
            "database-not-writable",
        );
        return true;
    };
    return false;
}

fn directoryPermissionBlocks(
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    automation_root: []const u8,
    directory_path: []const u8,
    expected_code: []const u8,
) !bool {
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);
    try directory.setPermissions(io, std.Io.File.Permissions.fromMode(0o500));
    defer ignoreError(directory.setPermissions(io, std.Io.File.Permissions.fromMode(0o700)));
    std.Io.Dir.cwd().access(
        io,
        directory_path,
        .{ .write = true, .execute = true },
    ) catch {
        try expectWritabilityDiagnostic(allocator, db_path, automation_root, expected_code);
        return true;
    };
    return false;
}

test "mutation writability checks database owner and automation root without writes" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "store");
    try tmp.dir.createDirPath(io, "automations");
    try tmp.dir.writeFile(io, .{ .sub_path = "store/codex-dev.db", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const db_path = try std.fs.path.join(alloc, &.{ root, "store", "codex-dev.db" });
    defer alloc.free(db_path);
    const store_owner = try std.fs.path.join(alloc, &.{ root, "store" });
    defer alloc.free(store_owner);
    const automation_root = try std.fs.path.join(alloc, &.{ root, "automations" });
    defer alloc.free(automation_root);

    var writable: DoctorDiagnostics = .{};
    defer writable.deinit(alloc);
    try inspectMutationWritability(alloc, db_path, automation_root, &writable);
    try std.testing.expect(!writable.hasError());

    var permission_checks_exercised: usize = 0;
    if (try databaseFilePermissionBlocks(alloc, io, db_path, automation_root)) {
        permission_checks_exercised += 1;
    }
    if (try directoryPermissionBlocks(
        alloc,
        io,
        db_path,
        automation_root,
        store_owner,
        "database-owner-not-writable",
    )) {
        permission_checks_exercised += 1;
    }
    if (try directoryPermissionBlocks(
        alloc,
        io,
        db_path,
        automation_root,
        automation_root,
        "automation-root-not-writable",
    )) {
        permission_checks_exercised += 1;
    }

    // Privileged test identities can retain write access despite mode bits.
    if (permission_checks_exercised == 0) return error.SkipZigTest;
}

test "mutation writability inspection diagnoses missing owners without creating them" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const db_path = try std.fs.path.join(alloc, &.{ root, "missing-store", "codex-dev.db" });
    defer alloc.free(db_path);
    const automation_root = try std.fs.path.join(alloc, &.{ root, "missing-automations" });
    defer alloc.free(automation_root);

    var diagnostics: DoctorDiagnostics = .{};
    defer diagnostics.deinit(alloc);
    try inspectMutationWritability(alloc, db_path, automation_root, &diagnostics);
    try std.testing.expect(diagnostics.hasError());
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, automation_root, .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(io, std.fs.path.dirname(db_path).?, .{}),
    );
}

fn seedMalformedAutomation(allocator: std.mem.Allocator, db_path: []const u8) !void {
    var db = try Db.open(allocator, db_path);
    defer db.close();
    try createTestSchema(allocator, &db);
    try db.exec(
        allocator,
        "insert into automations " ++
            "(id,name,prompt,status,next_run_at,last_run_at,cwds,rrule," ++
            "created_at,updated_at) values " ++
            "('malformed','n','p','ACTIVE',null,null,'not-json'," ++
            "'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',1,1)",
        &.{},
    );
}

test "doctor emits complete JSON when an automation row has malformed cwds" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "codex-dev.db", .data = "" });
    try tmp.dir.createDirPath(io, "automations/malformed");
    try tmp.dir.writeFile(io, .{
        .sub_path = "automations/malformed/automation.toml",
        .data = "stale = true\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "automations/malformed/memory.md", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const db_path = try std.fs.path.join(alloc, &.{ root, "codex-dev.db" });
    defer alloc.free(db_path);
    const automation_root = try std.fs.path.join(alloc, &.{ root, "automations" });
    defer alloc.free(automation_root);
    const report_path = try std.fs.path.join(alloc, &.{ root, "doctor.json" });
    defer alloc.free(report_path);

    try seedMalformedAutomation(alloc, db_path);

    automation_files.setAutomationRootOverride(automation_root);
    defer automation_files.setAutomationRootOverride(null);
    {
        const saved_fd = std.c.dup(std.posix.STDOUT_FILENO);
        if (saved_fd < 0) return error.SystemResources;
        var report_file = try std.Io.Dir.cwd().createFile(io, report_path, .{});
        defer {
            _ = std.c.dup2(saved_fd, std.posix.STDOUT_FILENO);
            _ = std.c.close(saved_fd);
            report_file.close(io);
        }
        if (std.c.dup2(report_file.handle, std.posix.STDOUT_FILENO) < 0) {
            return error.SystemResources;
        }
        try cmdDoctor(alloc, io, db_path, .{ .json = true });
    }

    const report = try std.Io.Dir.cwd().readFileAlloc(
        io,
        report_path,
        alloc,
        .limited(2 * 1024 * 1024),
    );
    defer alloc.free(report);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, report, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "cas-automation-doctor/v1",
        parsed.value.object.get("schema").?.string,
    );
    try std.testing.expect(!parsed.value.object.get("safeToMutate").?.bool);
    var saw_malformed = false;
    var saw_skipped = false;
    for (parsed.value.object.get("diagnostics").?.array.items) |diagnostic| {
        const code = diagnostic.object.get("code").?.string;
        if (std.mem.eql(u8, code, "malformed-cwds")) saw_malformed = true;
        if (std.mem.eql(u8, code, "automation-file-comparison-skipped")) saw_skipped = true;
    }
    try std.testing.expect(saw_malformed);
    try std.testing.expect(saw_skipped);
}

test "transaction rollback preserves the pre-mutation row" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "codex-dev.db", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const db_path = try std.fs.path.join(alloc, &.{ root, "codex-dev.db" });
    defer alloc.free(db_path);
    var db = try Db.open(alloc, db_path);
    defer db.close();
    try createTestSchema(alloc, &db);
    try db.begin(alloc);
    try db.exec(
        alloc,
        "insert into automations " ++
            "(id,name,prompt,status,next_run_at,last_run_at,cwds,rrule," ++
            "created_at,updated_at) values " ++
            "('rollback','n','p','ACTIVE',null,null,'[]'," ++
            "'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',1,1)",
        &.{},
    );
    db.rollback(alloc);
    var stmt = try db.prepare(alloc, "select count(*) from automations where id = 'rollback'");
    defer stmt.deinit();
    try std.testing.expectEqual(StepResult.row, try stmt.step());
    try std.testing.expectEqual(@as(i64, 0), stmt.intColumn(0));
}

fn createDryRunTestSchema(allocator: std.mem.Allocator, db: *Db) !void {
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
}

test "runDueAutomation dry-run is read-only" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "codex-dev.db", .data = "" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root_abs);
    const db_path = try std.fs.path.join(alloc, &.{ root_abs, "codex-dev.db" });
    defer alloc.free(db_path);

    var db = try Db.open(alloc, db_path);
    defer db.close();

    try createDryRunTestSchema(alloc, &db);

    const created_at: i64 = 1_772_469_600_000;
    try db.exec(
        alloc,
        insert_automation_sql,
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

    const result = try runDueAutomation(alloc, io, &db, &row, "codex", true);
    defer alloc.free(result.thread_id);
    defer alloc.free(result.cwd);
    if (result.err) |err_text| alloc.free(err_text);

    try std.testing.expectEqualStrings("dry_run", result.status);
    try std.testing.expect(result.thread_id.len > 0);
    try std.testing.expectEqualStrings("/tmp", result.cwd);

    var runs_stmt = try db.prepare(
        alloc,
        "select count(*) from automation_runs where automation_id = ?",
    );
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
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "codex-dev.db", .data = "" });
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root_abs);
    const db_path = try std.fs.path.join(alloc, &.{ root_abs, "codex-dev.db" });
    defer alloc.free(db_path);

    var db = try Db.open(alloc, db_path);
    defer db.close();
    try createTestSchema(alloc, &db);

    const created_at: i64 = 1_772_469_600_000;
    try db.exec(
        alloc,
        insert_automation_sql,
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

    var runs_stmt = try db.prepare(
        alloc,
        "select status from automation_runs where automation_id = ?",
    );
    defer runs_stmt.deinit();
    try runs_stmt.bindAll(&.{.{ .text = "run-due-id" }});
    switch (try runs_stmt.step()) {
        .row => try std.testing.expectEqualStrings("PENDING_REVIEW", runs_stmt.textColumn(0)),
        .done => unreachable,
    }
}

test "runPerfCase covers residual automation command families" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
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
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root_abs);
    const lock_dir = try std.fs.path.join(alloc, &.{ root_abs, "locks" });
    defer alloc.free(lock_dir);
    try std.Io.Dir.cwd().createDirPath(io, lock_dir);
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

test "doctor CLI keeps scheduler identity environment-only" {
    const json = try parseDoctorArgs(&.{"--json"});
    try std.testing.expect(json.json);
    try std.testing.expectError(
        error.UserInput,
        parseDoctorArgs(&.{ "--label", "com.example.scheduler" }),
    );
}
