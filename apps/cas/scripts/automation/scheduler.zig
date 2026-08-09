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

pub const LaunchctlObservation = enum {
    not_queried,
    loaded,
    not_found,
    spawn_failed,
    command_failed,
    invalid_output,
};

pub const SchedulerStatus = struct {
    installed: bool,
    loaded: bool,
    label: []u8,
    plist_path: []u8,
    program_arguments: std.ArrayList([]u8) = .empty,
    surface: []const u8 = "unknown",
    migration_required: bool = false,
    persisted_program_arguments: std.ArrayList([]u8) = .empty,
    loaded_program_arguments: std.ArrayList([]u8) = .empty,
    persisted_surface: []const u8 = "unknown",
    loaded_surface: []const u8 = "unknown",
    launchctl_observation: LaunchctlObservation = .not_queried,
    launchctl_exit_code: ?u8 = null,
    launchctl_error: ?[]u8 = null,
    sources_agree: bool = true,

    pub fn deinit(self: *SchedulerStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.plist_path);
        freeOwnedStrings(allocator, self.program_arguments);
        freeOwnedStrings(allocator, self.persisted_program_arguments);
        freeOwnedStrings(allocator, self.loaded_program_arguments);
        if (self.launchctl_error) |detail| allocator.free(detail);
    }
};

pub const CommandCapture = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
};

const CommandRunner = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        std.Io,
        []const []const u8,
        bool,
    ) anyerror!CommandCapture,

    fn run(
        self: CommandRunner,
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        fail_on_nonzero: bool,
    ) !CommandCapture {
        return self.run_fn(self.context, allocator, io, argv, fail_on_nonzero);
    }
};

const system_command_runner: CommandRunner = .{ .run_fn = runSystemCommandCapture };

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

fn parseSchedulerPlistJson(
    allocator: std.mem.Allocator,
    json: []const u8,
    expected_label: []const u8,
    result: *std.ArrayList([]u8),
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return error.InvalidSchedulerPlist;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSchedulerPlist;
    const label = parsed.value.object.get("Label") orelse return error.InvalidSchedulerPlist;
    if (label != .string) return error.InvalidSchedulerPlist;
    if (!std.mem.eql(u8, label.string, expected_label)) return error.SchedulerLabelMismatch;
    const arguments = parsed.value.object.get("ProgramArguments") orelse
        return error.InvalidSchedulerPlist;
    if (arguments != .array or arguments.array.items.len > 32) {
        return error.InvalidSchedulerPlist;
    }
    for (arguments.array.items) |argument| {
        if (argument != .string) return error.InvalidSchedulerPlist;
        const owned = try allocator.dupe(u8, argument.string);
        result.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
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
    if (arguments.len == 3 and
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

pub fn launchctlObservationName(observation: LaunchctlObservation) []const u8 {
    return switch (observation) {
        .not_queried => "not-queried",
        .loaded => "loaded",
        .not_found => "not-found",
        .spawn_failed => "spawn-failed",
        .command_failed => "command-failed",
        .invalid_output => "invalid-output",
    };
}

fn writeProgramArgumentsJson(writer: anytype, arguments: []const []u8) !void {
    try writer.writeByte('[');
    for (arguments, 0..) |arg, index| {
        if (index != 0) try writer.writeByte(',');
        try output.jsonWriteString(writer, arg);
    }
    try writer.writeByte(']');
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
    try writer.writeAll(",\"programArguments\":");
    try writeProgramArgumentsJson(writer, status.program_arguments.items);
    try writer.writeAll(",\"surface\":");
    try output.jsonWriteString(writer, status.surface);
    try writer.writeAll(",\"migrationRequired\":");
    try writer.writeAll(if (status.migration_required) "true" else "false");
    try writer.writeAll(",\"persistedProgramArguments\":");
    if (status.installed) {
        try writeProgramArgumentsJson(writer, status.persisted_program_arguments.items);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"persistedSurface\":");
    if (status.installed) {
        try output.jsonWriteString(writer, status.persisted_surface);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"loadedProgramArguments\":");
    if (status.launchctl_observation == .loaded) {
        try writeProgramArgumentsJson(writer, status.loaded_program_arguments.items);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"loadedSurface\":");
    if (status.launchctl_observation == .loaded) {
        try output.jsonWriteString(writer, status.loaded_surface);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"launchctlStatus\":");
    try output.jsonWriteString(writer, launchctlObservationName(status.launchctl_observation));
    try writer.writeAll(",\"launchctlExitCode\":");
    if (status.launchctl_exit_code) |exit_code| {
        try writer.print("{d}", .{exit_code});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"launchctlError\":");
    if (status.launchctl_error) |detail| {
        try output.jsonWriteString(writer, detail);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"sourcesAgree\":");
    try writer.writeAll(if (status.sources_agree) "true" else "false");
    try writer.writeByte('}');
}

fn freeOwnedStrings(allocator: std.mem.Allocator, list: std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    var owned = list;
    owned.deinit(allocator);
}

fn duplicateProgramArguments(
    allocator: std.mem.Allocator,
    source: []const []u8,
    target: *std.ArrayList([]u8),
) !void {
    for (source) |argument| {
        const owned = try allocator.dupe(u8, argument);
        target.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
}

fn programArgumentsEqual(left: []const []u8, right: []const []u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_argument, right_argument| {
        if (!std.mem.eql(u8, left_argument, right_argument)) return false;
    }
    return true;
}

fn userErrorFmt(comptime fmt: []const u8, args: anytype) error{UserInput} {
    return output.userErrorFmt(fmt, args);
}

const LaunchctlQuery = struct {
    observation: LaunchctlObservation,
    exit_code: ?u8 = null,
    program_arguments: std.ArrayList([]u8) = .empty,
    error_detail: ?[]u8 = null,

    fn deinit(self: *LaunchctlQuery, allocator: std.mem.Allocator) void {
        freeOwnedStrings(allocator, self.program_arguments);
        if (self.error_detail) |detail| allocator.free(detail);
    }
};

fn isExactLaunchctlNotFound(capture: CommandCapture, target: []const u8) bool {
    if (capture.exit_code != 113) return false;
    const marker = "Could not find service \"";
    const marker_start = std.mem.indexOf(u8, capture.stderr, marker) orelse return false;
    const service_start = marker_start + marker.len;
    const service_end_relative = std.mem.indexOf(u8, capture.stderr[service_start..], "\"") orelse
        return false;
    const service = capture.stderr[service_start .. service_start + service_end_relative];
    return std.mem.eql(u8, service, std.fs.path.basename(target)) and
        std.mem.indexOf(u8, capture.stderr, " in domain for user gui:") != null;
}

fn queryLaunchctl(
    allocator: std.mem.Allocator,
    io: std.Io,
    runner: CommandRunner,
    target: []const u8,
) !LaunchctlQuery {
    const capture = runner.run(
        allocator,
        io,
        &.{ "launchctl", "print", target },
        false,
    ) catch |err| {
        return .{
            .observation = .spawn_failed,
            .error_detail = try allocator.dupe(u8, @errorName(err)),
        };
    };
    defer allocator.free(capture.stdout);
    defer allocator.free(capture.stderr);

    if (capture.exit_code != 0) {
        if (isExactLaunchctlNotFound(capture, target)) {
            return .{ .observation = .not_found, .exit_code = capture.exit_code };
        }
        const detail = std.mem.trim(u8, capture.stderr, " \t\r\n");
        return .{
            .observation = .command_failed,
            .exit_code = capture.exit_code,
            .error_detail = try allocator.dupe(
                u8,
                if (detail.len == 0) "launchctl print failed" else detail,
            ),
        };
    }

    var query: LaunchctlQuery = .{ .observation = .loaded, .exit_code = 0 };
    parseLaunchctlProgramArguments(
        allocator,
        capture.stdout,
        &query.program_arguments,
    ) catch |err| {
        freeOwnedStrings(allocator, query.program_arguments);
        query.program_arguments = .empty;
        if (err == error.OutOfMemory) return err;
        query.observation = .invalid_output;
        query.error_detail = try allocator.dupe(u8, @errorName(err));
    };
    return query;
}

fn projectSchedulerStatus(allocator: std.mem.Allocator, status: *SchedulerStatus) !void {
    status.persisted_surface = if (status.installed)
        classifySchedulerSurface(status.persisted_program_arguments.items)
    else
        "unknown";
    status.loaded_surface = if (status.launchctl_observation == .loaded)
        classifySchedulerSurface(status.loaded_program_arguments.items)
    else
        "unknown";
    const both_observed = status.installed and status.launchctl_observation == .loaded;
    status.sources_agree = !both_observed or programArgumentsEqual(
        status.persisted_program_arguments.items,
        status.loaded_program_arguments.items,
    );

    const projected_arguments = if (both_observed and status.sources_agree)
        status.persisted_program_arguments.items
    else if (both_observed)
        &.{}
    else if (status.installed)
        status.persisted_program_arguments.items
    else if (status.launchctl_observation == .loaded)
        status.loaded_program_arguments.items
    else
        &.{};
    try duplicateProgramArguments(allocator, projected_arguments, &status.program_arguments);
    status.surface = classifySchedulerSurface(status.program_arguments.items);

    const persisted_requires_migration = status.installed and
        !std.mem.eql(u8, status.persisted_surface, "cas-automation");
    const loaded_requires_migration = status.launchctl_observation == .loaded and
        !std.mem.eql(u8, status.loaded_surface, "cas-automation");
    const query_untrusted = switch (status.launchctl_observation) {
        .loaded, .not_found, .not_queried => false,
        .spawn_failed, .command_failed, .invalid_output => true,
    };
    status.migration_required = persisted_requires_migration or
        loaded_requires_migration or !status.sources_agree or query_untrusted;
}

fn initSchedulerStatus(
    allocator: std.mem.Allocator,
    label: []const u8,
    plist_path: []const u8,
) !SchedulerStatus {
    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    return .{
        .installed = false,
        .loaded = false,
        .label = owned_label,
        .plist_path = try allocator.dupe(u8, plist_path),
    };
}

fn readSchedulerStatusAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    label: []const u8,
    plist_path: []const u8,
    target: ?[]const u8,
    runner: CommandRunner,
) !SchedulerStatus {
    var status = try initSchedulerStatus(allocator, label, plist_path);
    errdefer status.deinit(allocator);

    const plist = try readSchedulerPlist(allocator, plist_path);
    defer if (plist) |bytes| allocator.free(bytes);
    status.installed = plist != null;
    if (plist != null) {
        const converted = try runner.run(
            allocator,
            io,
            &.{ "plutil", "-convert", "json", "-o", "-", plist_path },
            true,
        );
        defer allocator.free(converted.stdout);
        defer allocator.free(converted.stderr);
        try parseSchedulerPlistJson(
            allocator,
            converted.stdout,
            label,
            &status.persisted_program_arguments,
        );
    }

    if (target) |launchctl_target| {
        var query = try queryLaunchctl(allocator, io, runner, launchctl_target);
        defer query.deinit(allocator);
        switch (query.observation) {
            .loaded, .not_found => {},
            .not_queried, .spawn_failed, .command_failed, .invalid_output => {
                return userErrorFmt(
                    "launchd scheduler state is unavailable: {s}",
                    .{launchctlObservationName(query.observation)},
                );
            },
        }
        status.launchctl_observation = query.observation;
        status.launchctl_exit_code = query.exit_code;
        status.launchctl_error = query.error_detail;
        query.error_detail = null;
        status.loaded_program_arguments = query.program_arguments;
        query.program_arguments = .empty;
        status.loaded = status.launchctl_observation == .loaded;
    }

    try projectSchedulerStatus(allocator, &status);
    return status;
}

fn requireTrustedInstallState(
    status: SchedulerStatus,
    cas_path: []const u8,
    replace: bool,
) !void {
    switch (status.launchctl_observation) {
        .loaded, .not_found => {},
        .not_queried, .spawn_failed, .command_failed, .invalid_output => {
            return userErrorFmt(
                "refusing scheduler install because launchd state is {s}",
                .{launchctlObservationName(status.launchctl_observation)},
            );
        },
    }
    if (replace) return;
    if (!status.sources_agree) {
        return userErrorFmt(
            "refusing to replace disagreeing persisted and loaded schedulers without --replace",
            .{},
        );
    }
    if (status.installed and
        !schedulerArgumentsMatchCas(status.persisted_program_arguments.items, cas_path))
    {
        return userErrorFmt(
            "refusing to replace non-matching persisted scheduler without --replace",
            .{},
        );
    }
    if (status.launchctl_observation == .loaded and
        !schedulerArgumentsMatchCas(status.loaded_program_arguments.items, cas_path))
    {
        return userErrorFmt(
            "refusing to replace non-matching loaded scheduler without --replace",
            .{},
        );
    }
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

    const uid = std.c.getuid();
    const target = try std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, args.label });
    defer allocator.free(target);
    const domain = try std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
    defer allocator.free(domain);

    try installSchedulerAtPaths(
        allocator,
        io,
        args,
        launch_agents,
        log_dir,
        plist_path,
        domain,
        target,
        cas_path,
        plist,
        system_command_runner,
    );

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("installed and started: {s}\n", .{args.label});
    try stdout.print("plist: {s}\n", .{plist_path});
    try stdout.print("logs: {s}\n", .{log_dir});
}

fn installSchedulerAtPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: SchedulerInstallArgs,
    launch_agents: []const u8,
    log_dir: []const u8,
    plist_path: []const u8,
    domain: []const u8,
    target: []const u8,
    cas_path: []const u8,
    plist: []const u8,
    runner: CommandRunner,
) !void {
    var status = try readSchedulerStatusAtPath(
        allocator,
        io,
        args.label,
        plist_path,
        target,
        runner,
    );
    defer status.deinit(allocator);
    try requireTrustedInstallState(status, cas_path, args.replace);
    try ensureSchedulerAbsent(
        allocator,
        io,
        target,
        status.launchctl_observation,
        runner,
    );
    try std.Io.Dir.cwd().createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
        launch_agents,
    );
    try std.Io.Dir.cwd().createDirPath(
        std.Io.Threaded.global_single_threaded.io(),
        log_dir,
    );
    if (try schedulerPlistChanged(allocator, plist_path, plist)) {
        try output.writeFileAtomic(allocator, plist_path, plist);
    }
    try activateScheduler(
        allocator,
        io,
        domain,
        target,
        plist_path,
        cas_path,
        runner,
    );
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
    return true;
}

fn ensureSchedulerAbsent(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    observed: LaunchctlObservation,
    runner: CommandRunner,
) !void {
    if (observed == .loaded) {
        try runCommandChecked(allocator, io, runner, &.{ "launchctl", "bootout", target });
    }
    var verified = try queryLaunchctl(allocator, io, runner, target);
    defer verified.deinit(allocator);
    if (verified.observation != .not_found) {
        return userErrorFmt(
            "scheduler absence was not verified after bootout: {s}",
            .{launchctlObservationName(verified.observation)},
        );
    }
}

fn runCommandChecked(
    allocator: std.mem.Allocator,
    io: std.Io,
    runner: CommandRunner,
    argv: []const []const u8,
) !void {
    const capture = try runner.run(allocator, io, argv, true);
    allocator.free(capture.stdout);
    allocator.free(capture.stderr);
}

fn activateScheduler(
    allocator: std.mem.Allocator,
    io: std.Io,
    domain: []const u8,
    target: []const u8,
    plist_path: []const u8,
    cas_path: []const u8,
    runner: CommandRunner,
) !void {
    try runCommandChecked(allocator, io, runner, &.{ "plutil", "-lint", plist_path });
    try runCommandChecked(allocator, io, runner, &.{ "launchctl", "enable", target });
    try runCommandChecked(
        allocator,
        io,
        runner,
        &.{ "launchctl", "bootstrap", domain, plist_path },
    );
    try runCommandChecked(
        allocator,
        io,
        runner,
        &.{ "launchctl", "kickstart", "-k", target },
    );
    var loaded = try queryLaunchctl(allocator, io, runner, target);
    defer loaded.deinit(allocator);
    if (loaded.observation != .loaded or
        !schedulerArgumentsMatchCas(loaded.program_arguments.items, cas_path))
    {
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

    const existed = try uninstallSchedulerAtPath(
        allocator,
        io,
        args.label,
        plist,
        target,
        system_command_runner,
    );

    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.json) {
        try writeSchedulerUninstallJson(stdout, args.label, existed);
        try stdout.writeByte('\n');
    } else if (existed) {
        try stdout.print("stopped and removed: {s}\n", .{args.label});
    } else {
        try stdout.print("already absent: {s}\n", .{args.label});
    }
}

fn writeSchedulerUninstallJson(writer: anytype, label: []const u8, removed: bool) !void {
    try writer.writeAll("{\"schema\":\"cas-automation-scheduler-uninstall/v1\",\"label\":");
    try output.jsonWriteString(writer, label);
    try writer.writeAll(",\"removed\":");
    try writer.writeAll(if (removed) "true" else "false");
    try writer.writeByte('}');
}

fn uninstallSchedulerAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    label: []const u8,
    plist_path: []const u8,
    target: []const u8,
    runner: CommandRunner,
) !bool {
    var status = try readSchedulerStatusAtPath(
        allocator,
        io,
        label,
        plist_path,
        target,
        runner,
    );
    defer status.deinit(allocator);
    switch (status.launchctl_observation) {
        .loaded => {
            try runCommandChecked(
                allocator,
                io,
                runner,
                &.{ "launchctl", "bootout", target },
            );
        },
        .not_found => {},
        .not_queried, .spawn_failed, .command_failed, .invalid_output => {
            return userErrorFmt(
                "refusing scheduler uninstall because launchd state is {s}",
                .{launchctlObservationName(status.launchctl_observation)},
            );
        },
    }

    var verified = try queryLaunchctl(allocator, io, runner, target);
    defer verified.deinit(allocator);
    if (verified.observation != .not_found) {
        return userErrorFmt(
            "scheduler absence was not verified before plist removal: {s}",
            .{launchctlObservationName(verified.observation)},
        );
    }
    try runCommandChecked(
        allocator,
        io,
        runner,
        &.{ "launchctl", "disable", target },
    );

    const removed = status.installed or status.loaded;
    std.Io.Dir.cwd().deleteFile(
        std.Io.Threaded.global_single_threaded.io(),
        plist_path,
    ) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return userErrorFmt(
            "failed to remove plist ({s}): {s}",
            .{ plist_path, @errorName(err) },
        ),
    };
    return removed;
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
    defer allocator.free(plist_path);
    var target: ?[]u8 = null;
    defer if (target) |value| allocator.free(value);
    if (builtin.os.tag == .macos) {
        const uid = std.c.getuid();
        target = try std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, label });
    }
    return readSchedulerStatusAtPath(
        allocator,
        io,
        label,
        plist_path,
        target,
        system_command_runner,
    );
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

pub fn runCommandCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    fail_on_nonzero: bool,
) !CommandCapture {
    return runSystemCommandCapture(null, allocator, io, argv, fail_on_nonzero);
}

fn runSystemCommandCapture(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    fail_on_nonzero: bool,
) !CommandCapture {
    _ = context;
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

const ScriptStep = struct {
    verb: []const u8,
    argv: ?[]const []const u8 = null,
    exit_code: u8 = 0,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    spawn_error: ?anyerror = null,
};

const ScriptedRunner = struct {
    steps: []const ScriptStep,
    next_step: usize = 0,

    fn commandRunner(self: *ScriptedRunner) CommandRunner {
        return .{ .context = self, .run_fn = run };
    }

    fn run(
        runner_context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        fail_on_nonzero: bool,
    ) !CommandCapture {
        _ = io;
        const self: *ScriptedRunner = @ptrCast(@alignCast(runner_context orelse
            return error.MissingScriptContext));
        if (self.next_step >= self.steps.len or argv.len < 2) {
            return error.UnexpectedScriptCommand;
        }
        const step = self.steps[self.next_step];
        self.next_step += 1;
        if (!std.mem.eql(u8, argv[1], step.verb)) return error.UnexpectedScriptCommand;
        if (step.argv) |expected| {
            if (argv.len != expected.len) return error.UnexpectedScriptCommand;
            for (argv, expected) |actual_arg, expected_arg| {
                if (!std.mem.eql(u8, actual_arg, expected_arg)) {
                    return error.UnexpectedScriptCommand;
                }
            }
        }
        if (step.spawn_error) |err| return err;
        if (fail_on_nonzero and step.exit_code != 0) return error.ScriptedNonZero;
        const stdout = try allocator.dupe(u8, step.stdout);
        errdefer allocator.free(stdout);
        return .{
            .exit_code = step.exit_code,
            .stdout = stdout,
            .stderr = try allocator.dupe(u8, step.stderr),
        };
    }

    fn expectComplete(self: ScriptedRunner) !void {
        try std.testing.expectEqual(self.steps.len, self.next_step);
    }
};

const TestCasLoadedState =
    \\gui/501/com.example.scheduler = {
    \\    arguments = {
    \\        /opt/cas/bin/cas
    \\        automation
    \\        run-due
    \\    }
    \\}
;

const TestCronLoadedState =
    \\gui/501/com.example.scheduler = {
    \\    arguments = {
    \\        /opt/homebrew/bin/cron
    \\        run-due
    \\    }
    \\}
;

const TestCasExtraLoadedState =
    \\gui/501/com.example.scheduler = {
    \\    arguments = {
    \\        /opt/cas/bin/cas
    \\        automation
    \\        run-due
    \\        --extra
    \\    }
    \\}
;

const TestSchedulerNotFound =
    "Could not find service \"com.example.scheduler\" " ++
    "in domain for user gui: 501\n";

const TestCronPlist =
    "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>" ++
    "<key>Label</key><string>com.example.scheduler</string>" ++
    "<key>ProgramArguments</key><array>" ++
    "<string>/opt/homebrew/bin/cron</string><string>run-due</string>" ++
    "</array></dict></plist>";

const TestCasPlist =
    "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>" ++
    "<key>Label</key><string>com.example.scheduler</string>" ++
    "<key>ProgramArguments</key><array>" ++
    "<string>/opt/cas/bin/cas</string><string>automation</string>" ++
    "<string>run-due</string></array></dict></plist>";

const TestCasExtraArgumentPlist =
    "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>" ++
    "<key>Label</key><string>com.example.scheduler</string>" ++
    "<key>ProgramArguments</key><array>" ++
    "<string>/opt/cas/bin/cas</string><string>automation</string>" ++
    "<string>run-due</string><string>--extra</string>" ++
    "</array></dict></plist>";

const TestCronPlistJson =
    "{\"Label\":\"com.example.scheduler\",\"ProgramArguments\":" ++
    "[\"/opt/homebrew/bin/cron\",\"run-due\"]}";

const TestCasPlistJson =
    "{\"Label\":\"com.example.scheduler\",\"ProgramArguments\":" ++
    "[\"/opt/cas/bin/cas\",\"automation\",\"run-due\"]}";

const TestCasExtraArgumentJson =
    "{\"Label\":\"com.example.scheduler\",\"ProgramArguments\":" ++
    "[\"/opt/cas/bin/cas\",\"automation\",\"run-due\",\"--extra\"]}";

const TestInstallSteps = [_]ScriptStep{
    .{ .verb = "print", .exit_code = 113, .stderr = TestSchedulerNotFound },
    .{ .verb = "print", .exit_code = 113, .stderr = TestSchedulerNotFound },
    .{ .verb = "-lint" },
    .{ .verb = "enable" },
    .{ .verb = "bootstrap" },
    .{ .verb = "kickstart" },
    .{ .verb = "print", .stdout = TestCasLoadedState },
};

fn testPlistPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
) ![]u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "scheduler.plist", .data = TestCronPlist });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "scheduler.plist" });
}

fn expectPlistPreserved(io: std.Io, tmp: *std.testing.TmpDir) !void {
    const contents = try tmp.dir.readFileAlloc(
        io,
        "scheduler.plist",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(TestCronPlist, contents);
}

fn expectPlistPreservedAtPath(
    io: std.Io,
    plist_path: []const u8,
    expected: []const u8,
) !void {
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        io,
        plist_path,
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(expected, contents);
}

fn runTestSchedulerInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    log_dir: []const u8,
    plist_path: []const u8,
    script: *ScriptedRunner,
) !void {
    const args: SchedulerInstallArgs = .{
        .label = "com.example.scheduler",
        .interval_seconds = 300,
        .path_value = "/usr/bin",
        .codex_bin = "codex",
        .replace = false,
    };
    try installSchedulerAtPaths(
        allocator,
        io,
        args,
        root,
        log_dir,
        plist_path,
        "gui/501",
        "gui/501/com.example.scheduler",
        "/opt/cas/bin/cas",
        TestCasPlist,
        script.commandRunner(),
    );
    try script.expectComplete();
}

test "scheduler surface requires the exact CAS argument tuple" {
    var exact = [_][]u8{
        @constCast("/opt/cas/bin/cas"),
        @constCast("automation"),
        @constCast("run-due"),
    };
    var extra = [_][]u8{
        @constCast("/opt/cas/bin/cas"),
        @constCast("automation"),
        @constCast("run-due"),
        @constCast("--extra"),
    };
    try std.testing.expectEqualStrings("cas-automation", classifySchedulerSurface(&exact));
    try std.testing.expectEqualStrings("unknown", classifySchedulerSurface(&extra));
}

test "scheduler status preserves disagreeing persisted Cron and loaded CAS" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plist_path = try testPlistPath(allocator, io, &tmp);
    defer allocator.free(plist_path);

    var script = ScriptedRunner{ .steps = &.{
        .{ .verb = "-convert", .stdout = TestCronPlistJson },
        .{ .verb = "print", .stdout = TestCasLoadedState },
    } };
    var status = try readSchedulerStatusAtPath(
        allocator,
        io,
        "com.example.scheduler",
        plist_path,
        "gui/501/com.example.scheduler",
        script.commandRunner(),
    );
    defer status.deinit(allocator);
    try script.expectComplete();

    try std.testing.expectEqualStrings("standalone-cron", status.persisted_surface);
    try std.testing.expectEqualStrings("cas-automation", status.loaded_surface);
    try std.testing.expect(!status.sources_agree);
    try std.testing.expectEqual(@as(usize, 0), status.program_arguments.items.len);
    try std.testing.expectEqualStrings("unknown", status.surface);
    try std.testing.expect(status.migration_required);
}

test "scheduler status JSON preserves absent sources as null" {
    const allocator = std.testing.allocator;
    var status: SchedulerStatus = .{
        .installed = false,
        .loaded = false,
        .label = try allocator.dupe(u8, "com.example.scheduler"),
        .plist_path = try allocator.dupe(u8, "/tmp/scheduler.plist"),
        .launchctl_observation = .not_found,
    };
    defer status.deinit(allocator);
    var encoded = std.Io.Writer.Allocating.init(allocator);
    defer encoded.deinit();
    try writeSchedulerStatusJson(&encoded.writer, status);
    const json = try encoded.toOwnedSlice();
    defer allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(object.get("persistedProgramArguments").? == .null);
    try std.testing.expect(object.get("loadedProgramArguments").? == .null);
    try std.testing.expect(object.get("persistedSurface").? == .null);
    try std.testing.expect(object.get("loadedSurface").? == .null);
}

test "scheduler uninstall JSON reports its exact result contract" {
    const allocator = std.testing.allocator;
    var encoded = std.Io.Writer.Allocating.init(allocator);
    defer encoded.deinit();
    try writeSchedulerUninstallJson(
        &encoded.writer,
        "com.example.scheduler",
        true,
    );
    try std.testing.expectEqualStrings(
        "{\"schema\":\"cas-automation-scheduler-uninstall/v1\"," ++
            "\"label\":\"com.example.scheduler\",\"removed\":true}",
        encoded.written(),
    );
}

test "persisted scheduler plist requires well formed XML and exact label" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const plist_path = try std.fs.path.join(allocator, &.{ root, "scheduler.plist" });
    defer allocator.free(plist_path);

    try tmp.dir.writeFile(io, .{
        .sub_path = "scheduler.plist",
        .data = "<plist><dict><key>Label</key><string>com.example.scheduler</dict></plist>",
    });
    var script = ScriptedRunner{ .steps = &.{
        .{ .verb = "-convert", .exit_code = 1, .stderr = "invalid plist" },
        .{
            .verb = "-convert",
            .stdout = "{\"Label\":\"other.label\",\"ProgramArguments\":[\"/bin/false\"]}",
        },
    } };
    try std.testing.expectError(
        error.ScriptedNonZero,
        readSchedulerStatusAtPath(
            allocator,
            io,
            "com.example.scheduler",
            plist_path,
            null,
            script.commandRunner(),
        ),
    );
    const wrong_label =
        "<plist><dict><key>Label</key><string>other.label</string>" ++
        "<key>ProgramArguments</key><array><string>/bin/false</string>" ++
        "</array></dict></plist>";
    try tmp.dir.writeFile(io, .{ .sub_path = "scheduler.plist", .data = wrong_label });
    try std.testing.expectError(
        error.SchedulerLabelMismatch,
        readSchedulerStatusAtPath(
            allocator,
            io,
            "com.example.scheduler",
            plist_path,
            null,
            script.commandRunner(),
        ),
    );
    try script.expectComplete();
}

test "install rejects extra persisted arguments before effects" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "scheduler.plist",
        .data = TestCasExtraArgumentPlist,
    });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const plist_path = try std.fs.path.join(allocator, &.{ root, "scheduler.plist" });
    defer allocator.free(plist_path);
    const launch_agents = try std.fs.path.join(allocator, &.{ root, "LaunchAgents" });
    defer allocator.free(launch_agents);
    const log_dir = try std.fs.path.join(allocator, &.{ root, "Logs" });
    defer allocator.free(log_dir);
    var script = ScriptedRunner{ .steps = &.{
        .{ .verb = "-convert", .stdout = TestCasExtraArgumentJson },
        .{ .verb = "print", .exit_code = 113, .stderr = TestSchedulerNotFound },
    } };
    const args: SchedulerInstallArgs = .{
        .label = "com.example.scheduler",
        .interval_seconds = 300,
        .path_value = "/usr/bin",
        .codex_bin = "codex",
        .replace = false,
    };
    try std.testing.expectError(error.UserInput, installSchedulerAtPaths(
        allocator,
        io,
        args,
        launch_agents,
        log_dir,
        plist_path,
        "gui/501",
        "gui/501/com.example.scheduler",
        "/opt/cas/bin/cas",
        TestCasPlist,
        script.commandRunner(),
    ));
    try script.expectComplete();
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "LaunchAgents", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "Logs", .{}));
    try expectPlistPreservedAtPath(io, plist_path, TestCasExtraArgumentPlist);
}

test "launchctl query distinguishes exact absence from query failures" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const target = "gui/501/com.example.scheduler";
    const not_found =
        "Could not find service \"com.example.scheduler\" " ++
        "in domain for user gui: 501\n";
    var script = ScriptedRunner{ .steps = &.{
        .{ .verb = "print", .spawn_error = error.FileNotFound },
        .{ .verb = "print", .exit_code = 64, .stderr = "Not privileged\n" },
        .{
            .verb = "print",
            .exit_code = 113,
            .stderr = "Could not find service \"different.label\" in domain for user gui: 501\n",
        },
        .{ .verb = "print", .exit_code = 113, .stderr = not_found },
    } };

    var spawn_failed = try queryLaunchctl(allocator, io, script.commandRunner(), target);
    defer spawn_failed.deinit(allocator);
    try std.testing.expectEqual(LaunchctlObservation.spawn_failed, spawn_failed.observation);
    var command_failed = try queryLaunchctl(allocator, io, script.commandRunner(), target);
    defer command_failed.deinit(allocator);
    try std.testing.expectEqual(LaunchctlObservation.command_failed, command_failed.observation);
    var wrong_label = try queryLaunchctl(allocator, io, script.commandRunner(), target);
    defer wrong_label.deinit(allocator);
    try std.testing.expectEqual(LaunchctlObservation.command_failed, wrong_label.observation);
    var absent = try queryLaunchctl(allocator, io, script.commandRunner(), target);
    defer absent.deinit(allocator);
    try std.testing.expectEqual(LaunchctlObservation.not_found, absent.observation);
    try script.expectComplete();
}

test "scheduler status propagates launchctl query failure" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const plist_path = try std.fs.path.join(allocator, &.{ root, "missing.plist" });
    defer allocator.free(plist_path);
    var script = ScriptedRunner{ .steps = &.{.{
        .verb = "print",
        .spawn_error = error.FileNotFound,
    }} };
    try std.testing.expectError(
        error.UserInput,
        readSchedulerStatusAtPath(
            allocator,
            io,
            "com.example.scheduler",
            plist_path,
            "gui/501/com.example.scheduler",
            script.commandRunner(),
        ),
    );
    try script.expectComplete();
}

test "loaded CAS with extra arguments requires explicit replacement" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const launch_agents = try std.fs.path.join(allocator, &.{ root, "LaunchAgents" });
    defer allocator.free(launch_agents);
    const log_dir = try std.fs.path.join(allocator, &.{ root, "Logs" });
    defer allocator.free(log_dir);
    const plist_path = try std.fs.path.join(allocator, &.{ launch_agents, "scheduler.plist" });
    defer allocator.free(plist_path);
    var script = ScriptedRunner{ .steps = &.{.{
        .verb = "print",
        .stdout = TestCasExtraLoadedState,
    }} };
    const args: SchedulerInstallArgs = .{
        .label = "com.example.scheduler",
        .interval_seconds = 300,
        .path_value = "/usr/bin",
        .codex_bin = "codex",
        .replace = false,
    };
    try std.testing.expectError(
        error.UserInput,
        installSchedulerAtPaths(
            allocator,
            io,
            args,
            launch_agents,
            log_dir,
            plist_path,
            "gui/501",
            "gui/501/com.example.scheduler",
            "/opt/cas/bin/cas",
            "<plist/>",
            script.commandRunner(),
        ),
    );
    try script.expectComplete();
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "LaunchAgents", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "Logs", .{}));
}

test "replace adopts the exact same-label standalone Cron scheduler" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const plist_path = try std.fs.path.join(allocator, &.{ root, "scheduler.plist" });
    defer allocator.free(plist_path);
    const log_dir = try std.fs.path.join(allocator, &.{ root, "Logs" });
    defer allocator.free(log_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "scheduler.plist", .data = TestCronPlist });

    const target = "gui/501/com.example.scheduler";
    const domain = "gui/501";
    const convert_argv = [_][]const u8{
        "plutil",
        "-convert",
        "json",
        "-o",
        "-",
        plist_path,
    };
    const initial_print_argv = [_][]const u8{ "launchctl", "print", target };
    const bootout_argv = [_][]const u8{ "launchctl", "bootout", target };
    const verify_absent_argv = [_][]const u8{ "launchctl", "print", target };
    const lint_argv = [_][]const u8{ "plutil", "-lint", plist_path };
    const enable_argv = [_][]const u8{ "launchctl", "enable", target };
    const bootstrap_argv = [_][]const u8{ "launchctl", "bootstrap", domain, plist_path };
    const kickstart_argv = [_][]const u8{ "launchctl", "kickstart", "-k", target };
    const final_print_argv = [_][]const u8{ "launchctl", "print", target };
    var script = ScriptedRunner{ .steps = &.{
        .{ .verb = "-convert", .argv = &convert_argv, .stdout = TestCronPlistJson },
        .{ .verb = "print", .argv = &initial_print_argv, .stdout = TestCronLoadedState },
        .{ .verb = "bootout", .argv = &bootout_argv },
        .{
            .verb = "print",
            .argv = &verify_absent_argv,
            .exit_code = 113,
            .stderr = TestSchedulerNotFound,
        },
        .{ .verb = "-lint", .argv = &lint_argv },
        .{ .verb = "enable", .argv = &enable_argv },
        .{ .verb = "bootstrap", .argv = &bootstrap_argv },
        .{ .verb = "kickstart", .argv = &kickstart_argv },
        .{ .verb = "print", .argv = &final_print_argv, .stdout = TestCasLoadedState },
    } };
    const args: SchedulerInstallArgs = .{
        .label = "com.example.scheduler",
        .interval_seconds = 300,
        .path_value = "/usr/bin",
        .codex_bin = "codex",
        .replace = true,
    };
    try installSchedulerAtPaths(
        allocator,
        io,
        args,
        root,
        log_dir,
        plist_path,
        domain,
        target,
        "/opt/cas/bin/cas",
        TestCasPlist,
        script.commandRunner(),
    );
    try script.expectComplete();
    try expectPlistPreservedAtPath(io, plist_path, TestCasPlist);
}

test "failed or unverified bootout preserves the scheduler plist" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plist_path = try testPlistPath(allocator, io, &tmp);
    defer allocator.free(plist_path);
    const target = "gui/501/com.example.scheduler";

    var failed_bootout = ScriptedRunner{ .steps = &.{.{
        .verb = "bootout",
        .exit_code = 1,
    }} };
    try std.testing.expectError(
        error.ScriptedNonZero,
        ensureSchedulerAbsent(
            allocator,
            io,
            target,
            .loaded,
            failed_bootout.commandRunner(),
        ),
    );
    try failed_bootout.expectComplete();
    try expectPlistPreserved(io, &tmp);

    var unverified_bootout = ScriptedRunner{ .steps = &.{
        .{ .verb = "bootout" },
        .{ .verb = "print", .exit_code = 64, .stderr = "Not privileged\n" },
    } };
    try std.testing.expectError(
        error.UserInput,
        ensureSchedulerAbsent(
            allocator,
            io,
            target,
            .loaded,
            unverified_bootout.commandRunner(),
        ),
    );
    try unverified_bootout.expectComplete();
    try expectPlistPreserved(io, &tmp);
}

test "uninstall removes the plist only after verified launchd absence" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plist_path = try testPlistPath(allocator, io, &tmp);
    defer allocator.free(plist_path);
    const not_found =
        "Could not find service \"com.example.scheduler\" " ++
        "in domain for user gui: 501\n";
    var script = ScriptedRunner{ .steps = &.{
        .{ .verb = "-convert", .stdout = TestCronPlistJson },
        .{ .verb = "print", .stdout = TestCronLoadedState },
        .{ .verb = "bootout" },
        .{ .verb = "print", .exit_code = 113, .stderr = not_found },
        .{ .verb = "disable" },
    } };
    try std.testing.expect(try uninstallSchedulerAtPath(
        allocator,
        io,
        "com.example.scheduler",
        plist_path,
        "gui/501/com.example.scheduler",
        script.commandRunner(),
    ));
    try script.expectComplete();
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io, "scheduler.plist", .{}),
    );
}

test "uninstall reports a loaded-only scheduler as removed" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const plist_path = try std.fs.path.join(allocator, &.{ root, "missing.plist" });
    defer allocator.free(plist_path);
    var script = ScriptedRunner{ .steps = &.{
        .{ .verb = "print", .stdout = TestCasLoadedState },
        .{ .verb = "bootout" },
        .{ .verb = "print", .exit_code = 113, .stderr = TestSchedulerNotFound },
        .{ .verb = "disable" },
    } };
    try std.testing.expect(try uninstallSchedulerAtPath(
        allocator,
        io,
        "com.example.scheduler",
        plist_path,
        "gui/501/com.example.scheduler",
        script.commandRunner(),
    ));
    try script.expectComplete();
}

test "uninstall rejects a persisted plist with the wrong label before effects" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plist_path = try testPlistPath(allocator, io, &tmp);
    defer allocator.free(plist_path);
    var script = ScriptedRunner{ .steps = &.{.{
        .verb = "-convert",
        .stdout = "{\"Label\":\"other.label\",\"ProgramArguments\":[\"/bin/false\"]}",
    }} };
    try std.testing.expectError(
        error.SchedulerLabelMismatch,
        uninstallSchedulerAtPath(
            allocator,
            io,
            "com.example.scheduler",
            plist_path,
            "gui/501/com.example.scheduler",
            script.commandRunner(),
        ),
    );
    try script.expectComplete();
    try expectPlistPreserved(io, &tmp);
}

test "scheduler install succeeds after uninstall disabled the same label" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const plist_path = try std.fs.path.join(allocator, &.{ root, "scheduler.plist" });
    defer allocator.free(plist_path);
    const log_dir = try std.fs.path.join(allocator, &.{ root, "Logs" });
    defer allocator.free(log_dir);
    const target = "gui/501/com.example.scheduler";

    var first_install = ScriptedRunner{ .steps = &TestInstallSteps };
    try runTestSchedulerInstall(allocator, io, root, log_dir, plist_path, &first_install);

    var uninstall_script = ScriptedRunner{ .steps = &.{
        .{ .verb = "-convert", .stdout = TestCasPlistJson },
        .{ .verb = "print", .stdout = TestCasLoadedState },
        .{ .verb = "bootout" },
        .{ .verb = "print", .exit_code = 113, .stderr = TestSchedulerNotFound },
        .{ .verb = "disable" },
    } };
    try std.testing.expect(try uninstallSchedulerAtPath(
        allocator,
        io,
        "com.example.scheduler",
        plist_path,
        target,
        uninstall_script.commandRunner(),
    ));
    try uninstall_script.expectComplete();

    var second_install = ScriptedRunner{ .steps = &TestInstallSteps };
    try runTestSchedulerInstall(allocator, io, root, log_dir, plist_path, &second_install);
    try expectPlistPreservedAtPath(io, plist_path, TestCasPlist);
}

test "uninstall verification failure preserves the scheduler plist" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plist_path = try testPlistPath(allocator, io, &tmp);
    defer allocator.free(plist_path);
    var script = ScriptedRunner{ .steps = &.{
        .{ .verb = "-convert", .stdout = TestCronPlistJson },
        .{ .verb = "print", .stdout = TestCronLoadedState },
        .{ .verb = "bootout" },
        .{ .verb = "print", .exit_code = 64, .stderr = "Not privileged\n" },
    } };
    try std.testing.expectError(
        error.UserInput,
        uninstallSchedulerAtPath(
            allocator,
            io,
            "com.example.scheduler",
            plist_path,
            "gui/501/com.example.scheduler",
            script.commandRunner(),
        ),
    );
    try script.expectComplete();
    try expectPlistPreserved(io, &tmp);
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
