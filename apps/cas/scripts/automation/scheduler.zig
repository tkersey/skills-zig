const output = @import("output.zig");
const builtin = @import("builtin");
const std = @import("std");

pub const MaxCommandOutputBytes = 10 * 1024 * 1024;

pub const SchedulerInstallArgs = struct {
    label: []const u8,
    interval_seconds: i64,
    path_value: []const u8,
    codex_bin: []const u8,
    replace: bool,
};

pub const SchedulerLabelArgs = struct {
    label: []const u8,
    json: bool = false,
};

pub const SchedulerStatus = struct {
    installed: bool,
    loaded: bool,
    label: []u8,
    plist_path: []u8,
    program_arguments: std.ArrayList([]u8) = .empty,
    surface: []const u8,
    migration_required: bool,

    pub fn deinit(self: *SchedulerStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.plist_path);
        freeOwnedStrings(allocator, self.program_arguments);
    }
};

pub fn validateSchedulerLabel(raw: []const u8) ![]const u8 {
    const label = std.mem.trim(u8, raw, " \t\r\n");
    if (label.len == 0) return userErrorFmt("label must not be empty", .{});

    for (label) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_') continue;
        return userErrorFmt("invalid label: {s} (allowed: [A-Za-z0-9._-])", .{label});
    }
    return label;
}

pub fn renderLaunchdProgramArguments(allocator: std.mem.Allocator, cas_path_xml: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "  <key>ProgramArguments</key>\n" ++
            "  <array>\n" ++
            "    <string>{s}</string>\n" ++
            "    <string>automation</string>\n" ++
            "    <string>run-due</string>\n" ++
            "  </array>\n",
        .{cas_path_xml},
    );
}

pub fn parsePlistProgramArguments(
    allocator: std.mem.Allocator,
    plist: []const u8,
    result: *std.ArrayList([]u8),
) !void {
    const key = "<key>ProgramArguments</key>";
    const key_index = std.mem.indexOf(u8, plist, key) orelse return;
    const array_start_rel = std.mem.indexOf(
        u8,
        plist[key_index + key.len ..],
        "<array>",
    ) orelse return;
    const array_start = key_index + key.len + array_start_rel + "<array>".len;
    const array_end_rel = std.mem.indexOf(u8, plist[array_start..], "</array>") orelse return;
    const body = plist[array_start .. array_start + array_end_rel];
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, "<string>")) |start_tag| {
        const start = start_tag + "<string>".len;
        const end_rel = std.mem.indexOf(u8, body[start..], "</string>") orelse break;
        if (result.items.len >= 32) return error.TooManyProgramArguments;
        try result.append(allocator, try allocator.dupe(u8, body[start .. start + end_rel]));
        cursor = start + end_rel + "</string>".len;
    }
}

pub fn parseLaunchctlProgramArguments(
    allocator: std.mem.Allocator,
    loaded_state: []const u8,
    result: *std.ArrayList([]u8),
) !void {
    if (loaded_state.len > MaxCommandOutputBytes) return error.LaunchctlOutputTooLarge;
    var lines = std.mem.splitScalar(u8, loaded_state, '\n');
    var in_arguments = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!in_arguments) {
            if (std.mem.eql(u8, trimmed, "arguments = {")) in_arguments = true;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "}")) return;
        if (trimmed.len == 0) continue;
        if (trimmed.len > 4096) return error.ProgramArgumentTooLong;
        if (result.items.len >= 32) return error.TooManyProgramArguments;
        const quoted = trimmed.len >= 2 and
            trimmed[0] == '"' and
            trimmed[trimmed.len - 1] == '"';
        const value = if (quoted) trimmed[1 .. trimmed.len - 1] else trimmed;
        try result.append(allocator, try allocator.dupe(u8, value));
    }
    if (in_arguments) return error.UnterminatedProgramArguments;
}

pub fn projectLoadedProgramArguments(
    allocator: std.mem.Allocator,
    loaded_state: []const u8,
    result: *std.ArrayList([]u8),
) !bool {
    var loaded_arguments: std.ArrayList([]u8) = .empty;
    parseLaunchctlProgramArguments(allocator, loaded_state, &loaded_arguments) catch |err| {
        if (err == error.OutOfMemory) {
            freeOwnedStrings(allocator, loaded_arguments);
            return err;
        }
        freeOwnedStrings(allocator, loaded_arguments);
        freeOwnedStrings(allocator, result.*);
        result.* = .empty;
        return false;
    };
    freeOwnedStrings(allocator, result.*);
    result.* = loaded_arguments;
    return true;
}

pub fn schedulerArgumentsMatchCas(arguments: []const []u8, cas_path: []const u8) bool {
    return arguments.len == 3 and std.mem.eql(u8, arguments[0], cas_path) and
        std.mem.eql(u8, arguments[1], "automation") and std.mem.eql(u8, arguments[2], "run-due");
}

pub fn classifySchedulerSurface(arguments: []const []u8) []const u8 {
    if (arguments.len >= 3 and
        std.mem.eql(u8, std.fs.path.basename(arguments[0]), "cas") and
        std.mem.eql(u8, arguments[1], "automation") and
        std.mem.eql(u8, arguments[2], "run-due"))
    {
        return "cas-automation";
    }
    if (arguments.len >= 2 and std.mem.eql(u8, std.fs.path.basename(arguments[0]), "cron") and
        std.mem.eql(u8, arguments[1], "run-due")) return "standalone-cron";
    return "unknown";
}

pub fn writeSchedulerStatusJson(writer: anytype, status: SchedulerStatus) !void {
    try writer.writeAll("{\"schema\":\"cas-automation-scheduler-status/v1\",\"installed\":");
    try writer.writeAll(if (status.installed) "true" else "false");
    try writer.writeAll(",\"loaded\":");
    try writer.writeAll(if (status.loaded) "true" else "false");
    try writer.writeAll(",\"label\":");
    try output.jsonWriteString(writer, status.label);
    try writer.writeAll(",\"plistPath\":");
    try output.jsonWriteString(writer, status.plist_path);
    try writer.writeAll(",\"programArguments\":[");
    for (status.program_arguments.items, 0..) |arg, index| {
        if (index != 0) try writer.writeByte(',');
        try output.jsonWriteString(writer, arg);
    }
    try writer.writeAll("],\"surface\":");
    try output.jsonWriteString(writer, status.surface);
    try writer.writeAll(",\"migrationRequired\":");
    try writer.writeAll(if (status.migration_required) "true" else "false");
    try writer.writeByte('}');
}

fn freeOwnedStrings(allocator: std.mem.Allocator, list: std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    var owned = list;
    owned.deinit(allocator);
}

fn userErrorFmt(comptime fmt: []const u8, args: anytype) error{UserInput} {
    return output.userErrorFmt(fmt, args);
}

pub fn cmdSchedulerInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: SchedulerInstallArgs,
) !void {
    if (builtin.os.tag != .macos) {
        return userErrorFmt("scheduler commands are supported on macOS only", .{});
    }

    const home = envString("HOME") orelse return userErrorFmt("HOME is not set", .{});

    const launch_agents = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents", .{home});
    defer allocator.free(launch_agents);
    const log_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/Library/Logs/codex-automation-runner",
        .{home},
    );
    defer allocator.free(log_dir);
    try std.Io.Dir.cwd().createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
        launch_agents,
    );
    try std.Io.Dir.cwd().createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
        log_dir,
    );

    const plist_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.plist",
        .{ launch_agents, args.label },
    );
    defer allocator.free(plist_path);

    const self_path = try std.process.executablePathAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        allocator,
    );
    defer allocator.free(self_path);
    const executable_dir = std.fs.path.dirname(self_path) orelse
        return userErrorFmt("failed to resolve cas executable directory", .{});
    const cas_path = try std.fs.path.join(allocator, &.{ executable_dir, "cas" });
    defer allocator.free(cas_path);

    const plist = try buildSchedulerPlist(allocator, args, home, log_dir, cas_path);
    defer allocator.free(plist);

    if (try schedulerPlistChanged(allocator, plist_path, plist, args.replace)) {
        try output.writeFileAtomic(allocator, plist_path, plist);
    }

    try activateScheduler(allocator, io, args.label, plist_path, cas_path);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("installed and started: {s}\n", .{args.label});
    try stdout.print("plist: {s}\n", .{plist_path});
    try stdout.print("logs: {s}\n", .{log_dir});
}

const SchedulerPlistTemplate =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " ++
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
    "<plist version=\"1.0\">\n" ++
    "<dict>\n" ++
    "  <key>Label</key>\n" ++
    "  <string>{s}</string>\n" ++
    "{s}" ++
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
    "    <key>CAS_AUTOMATION_LAUNCHD_LABEL</key>\n" ++
    "    <string>{s}</string>\n" ++
    "    <key>CODEX_BIN</key>\n" ++
    "    <string>{s}</string>\n" ++
    "  </dict>\n" ++
    "</dict>\n" ++
    "</plist>\n";

fn buildSchedulerPlist(
    allocator: std.mem.Allocator,
    args: SchedulerInstallArgs,
    home: []const u8,
    log_dir: []const u8,
    cas_path: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const label_xml = try output.xmlEscapeAlloc(scratch, args.label);
    const cas_path_xml = try output.xmlEscapeAlloc(scratch, cas_path);
    const home_xml = try output.xmlEscapeAlloc(scratch, home);
    const log_dir_xml = try output.xmlEscapeAlloc(scratch, log_dir);
    const path_xml = try output.xmlEscapeAlloc(scratch, args.path_value);
    const codex_bin_xml = try output.xmlEscapeAlloc(scratch, args.codex_bin);
    const program_arguments_xml = try renderLaunchdProgramArguments(scratch, cas_path_xml);
    return std.fmt.allocPrint(
        allocator,
        SchedulerPlistTemplate,
        .{
            label_xml,
            program_arguments_xml,
            home_xml,
            args.interval_seconds,
            log_dir_xml,
            log_dir_xml,
            path_xml,
            label_xml,
            codex_bin_xml,
        },
    );
}

fn schedulerPlistChanged(
    allocator: std.mem.Allocator,
    plist_path: []const u8,
    plist: []const u8,
    replace: bool,
) !bool {
    const existing = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        plist_path,
        allocator,
        .limited(MaxCommandOutputBytes),
    ) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return userErrorFmt(
            "failed to read existing plist ({s}): {s}",
            .{ plist_path, @errorName(err) },
        ),
    };
    defer allocator.free(existing);
    if (std.mem.eql(u8, existing, plist)) return false;
    if (existing.len == 0) return true;

    var existing_args: std.ArrayList([]u8) = .empty;
    defer freeOwnedStrings(allocator, existing_args);
    try parsePlistProgramArguments(allocator, existing, &existing_args);
    const existing_surface = classifySchedulerSurface(existing_args.items);
    if (!std.mem.eql(u8, existing_surface, "cas-automation") and !replace) {
        return userErrorFmt(
            "refusing to replace {s} scheduler at the same label without --replace",
            .{existing_surface},
        );
    }
    return true;
}

fn activateScheduler(
    allocator: std.mem.Allocator,
    io: std.Io,
    label: []const u8,
    plist_path: []const u8,
    cas_path: []const u8,
) !void {
    _ = try runCommandCapture(allocator, io, &.{ "plutil", "-lint", plist_path }, true);
    const uid = std.c.getuid();
    const target = try std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, label });
    defer allocator.free(target);
    const domain = try std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
    defer allocator.free(domain);

    _ = runCommandCapture(
        allocator,
        io,
        &.{ "launchctl", "bootout", target },
        false,
    ) catch null;
    _ = try runCommandCapture(
        allocator,
        io,
        &.{ "launchctl", "bootstrap", domain, plist_path },
        true,
    );
    _ = runCommandCapture(
        allocator,
        io,
        &.{ "launchctl", "enable", target },
        false,
    ) catch null;
    _ = try runCommandCapture(
        allocator,
        io,
        &.{ "launchctl", "kickstart", "-k", target },
        true,
    );
    const loaded_state = try runCommandCapture(
        allocator,
        io,
        &.{ "launchctl", "print", target },
        true,
    );
    defer allocator.free(loaded_state.stdout);
    defer allocator.free(loaded_state.stderr);
    var loaded_arguments: std.ArrayList([]u8) = .empty;
    defer freeOwnedStrings(allocator, loaded_arguments);
    try parseLaunchctlProgramArguments(allocator, loaded_state.stdout, &loaded_arguments);
    if (!schedulerArgumentsMatchCas(loaded_arguments.items, cas_path)) {
        return userErrorFmt(
            "scheduler replacement did not load cas automation program arguments",
            .{},
        );
    }
}

pub fn cmdSchedulerUninstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: SchedulerLabelArgs,
) !void {
    if (builtin.os.tag != .macos) {
        return userErrorFmt("scheduler commands are supported on macOS only", .{});
    }

    const home = envString("HOME") orelse return userErrorFmt("HOME is not set", .{});
    const plist = try std.fmt.allocPrint(
        allocator,
        "{s}/Library/LaunchAgents/{s}.plist",
        .{ home, args.label },
    );
    defer allocator.free(plist);

    const uid = std.c.getuid();
    const target = try std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, args.label });
    defer allocator.free(target);

    _ = runCommandCapture(allocator, io, &.{ "launchctl", "disable", target }, false) catch null;
    _ = runCommandCapture(allocator, io, &.{ "launchctl", "bootout", target }, false) catch null;

    var existed = true;
    std.Io.Dir.cwd().deleteFile(
        std.Io.Threaded.global_single_threaded.io(),
        plist,
    ) catch |err| switch (err) {
        error.FileNotFound => existed = false,
        else => return userErrorFmt(
            "failed to remove plist ({s}): {s}",
            .{ plist, @errorName(err) },
        ),
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

pub fn cmdSchedulerStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: SchedulerLabelArgs,
) !void {
    if (builtin.os.tag != .macos) {
        return userErrorFmt("scheduler commands are supported on macOS only", .{});
    }

    var status = try readSchedulerStatus(allocator, io, args.label);
    defer status.deinit(allocator);

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.json) {
        try writeSchedulerStatusJson(stdout, status);
        try stdout.writeByte('\n');
    } else {
        try stdout.print(
            "installed: {}\nloaded: {}\nlabel: {s}\nplist: {s}\n" ++
                "surface: {s}\nmigration required: {}\n",
            .{
                status.installed,
                status.loaded,
                status.label,
                status.plist_path,
                status.surface,
                status.migration_required,
            },
        );
    }
}

pub fn readSchedulerStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    label: []const u8,
) !SchedulerStatus {
    const plist_path = try schedulerPlistPath(allocator, envString("HOME"), label);
    errdefer allocator.free(plist_path);
    var arguments: std.ArrayList([]u8) = .empty;
    errdefer {
        for (arguments.items) |arg| allocator.free(arg);
        arguments.deinit(allocator);
    }
    const plist = try readSchedulerPlist(allocator, plist_path);
    defer if (plist) |bytes| allocator.free(bytes);
    if (plist) |bytes| try parsePlistProgramArguments(allocator, bytes, &arguments);

    var loaded = false;
    if (builtin.os.tag == .macos) {
        const uid = std.c.getuid();
        const target = try std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, label });
        defer allocator.free(target);
        const out = runCommandCapture(
            allocator,
            io,
            &.{ "launchctl", "print", target },
            false,
        ) catch null;
        if (out) |result| {
            loaded = result.exit_code == 0;
            if (loaded) _ = try projectLoadedProgramArguments(allocator, result.stdout, &arguments);
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
    }

    const surface = classifySchedulerSurface(arguments.items);
    return .{
        .installed = plist != null,
        .loaded = loaded,
        .label = try allocator.dupe(u8, label),
        .plist_path = plist_path,
        .program_arguments = arguments,
        .surface = surface,
        .migration_required = std.mem.eql(u8, surface, "standalone-cron"),
    };
}

fn schedulerPlistPath(
    allocator: std.mem.Allocator,
    home: ?[]const u8,
    label: []const u8,
) ![]u8 {
    const value = home orelse return userErrorFmt("HOME is not set", .{});
    return std.fmt.allocPrint(
        allocator,
        "{s}/Library/LaunchAgents/{s}.plist",
        .{ value, label },
    );
}

fn readSchedulerPlist(allocator: std.mem.Allocator, plist_path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        plist_path,
        allocator,
        .limited(2 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub const CommandCapture = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
};

pub fn runCommandCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    fail_on_nonzero: bool,
) !CommandCapture {
    const child = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(MaxCommandOutputBytes),
        .stderr_limit = .limited(MaxCommandOutputBytes),
    });

    const exit_code: u8 = switch (child.term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(
            @as(u32, 128) + @intFromEnum(signal),
            @as(u32, 255),
        )),
        .stopped, .unknown => 1,
    };

    if (fail_on_nonzero and exit_code != 0) {
        defer allocator.free(child.stdout);
        defer allocator.free(child.stderr);
        return userErrorFmt(
            "command failed ({s}): {s}",
            .{ argv[0], std.mem.trim(u8, child.stderr, " \t\r\n") },
        );
    }

    return .{ .exit_code = exit_code, .stdout = child.stdout, .stderr = child.stderr };
}

fn envString(key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(value);
}

fn expectSchedulerPlistReadFailure(
    allocator: std.mem.Allocator,
    plist_path: []const u8,
) !void {
    const unexpected = readSchedulerPlist(allocator, plist_path) catch |err| {
        try std.testing.expect(err != error.FileNotFound);
        return;
    };
    if (unexpected) |bytes| allocator.free(bytes);
    return error.TestExpectedError;
}

test "scheduler plist inspection distinguishes absence from read failures" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try std.testing.expectError(
        error.UserInput,
        schedulerPlistPath(allocator, null, "com.example.scheduler"),
    );

    const missing_path = try std.fs.path.join(allocator, &.{ root, "missing.plist" });
    defer allocator.free(missing_path);
    const missing = try readSchedulerPlist(allocator, missing_path);
    try std.testing.expect(missing == null);

    try expectSchedulerPlistReadFailure(allocator, root);

    const oversized_path = try std.fs.path.join(allocator, &.{ root, "oversized.plist" });
    defer allocator.free(oversized_path);
    const oversized = try allocator.alloc(u8, 2 * 1024 * 1024 + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "oversized.plist", .data = oversized });
    try expectSchedulerPlistReadFailure(allocator, oversized_path);
}
