const core_cli = @import("core_cli");
const std = @import("std");

pub fn isHelpRequested(argv: []const []const u8) bool {
    if (argv.len <= 1) return false;
    const arg = argv[1];
    return core_cli.isHelpArg(arg);
}

pub fn isVersionRequested(argv: []const []const u8) bool {
    if (argv.len <= 1) return false;
    const arg = argv[1];
    return core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg);
}

pub const DelegateRuntime = enum {
    bash,
    uv_python,
};

pub fn runDelegatedCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    argv: []const []const u8,
    usage_text: []const u8,
    version_text: []const u8,
    source_file: []const u8,
    skill_name: []const u8,
    script_name: []const u8,
    runtime: DelegateRuntime,
) !void {
    if (argv.len <= 1 or isHelpRequested(argv)) {
        var stdout_writer = std.Io.File.stdout().writer(io, &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpWithVersion(stdout, usage_text, version_text);
        return;
    }

    if (isVersionRequested(argv)) {
        var stdout_writer = std.Io.File.stdout().writer(io, &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, version_text);
        return;
    }

    const script_path = resolveScriptPath(
        allocator,
        io,
        home,
        skill_name,
        script_name,
    ) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        var stderr_writer = std.Io.File.stderr().writer(io, &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print(
            "{s}: unable to locate delegated script {s}\n",
            .{ source_file, script_name },
        );
        std.process.exit(1);
    };
    defer allocator.free(script_path);

    const exit_code = runDelegateRuntime(
        allocator,
        io,
        runtime,
        script_path,
        argv[1..],
    ) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(io, &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print(
            "{s}: delegate execution failed: {s}\n",
            .{ source_file, @errorName(err) },
        );
        std.process.exit(1);
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

pub fn runUvPython(
    allocator: std.mem.Allocator,
    io: std.Io,
    script_path: []const u8,
    passthrough_args: []const []const u8,
) !u8 {
    return runDelegateRuntime(allocator, io, .uv_python, script_path, passthrough_args);
}

pub fn runBash(
    allocator: std.mem.Allocator,
    io: std.Io,
    script_path: []const u8,
    passthrough_args: []const []const u8,
) !u8 {
    return runDelegateRuntime(allocator, io, .bash, script_path, passthrough_args);
}

fn runDelegateRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: DelegateRuntime,
    script_path: []const u8,
    passthrough_args: []const []const u8,
) !u8 {
    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);

    try appendDelegateArgs(allocator, &child_argv, runtime, script_path, passthrough_args);
    return runCommand(io, child_argv.items);
}

fn appendDelegateArgs(
    allocator: std.mem.Allocator,
    child_argv: *std.ArrayList([]const u8),
    runtime: DelegateRuntime,
    script_path: []const u8,
    passthrough_args: []const []const u8,
) !void {
    switch (runtime) {
        .uv_python => try child_argv.appendSlice(
            allocator,
            &.{ "uv", "run", "python", script_path },
        ),
        .bash => try child_argv.appendSlice(allocator, &.{ "bash", script_path }),
    }
    try child_argv.appendSlice(allocator, passthrough_args);
}

/// Waits for the command using caller cancellation; failed waits terminate the child.
pub fn runCommand(io: std.Io, args: []const []const u8) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = args,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    errdefer child.kill(io);
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(@as(u32, 128) + @intFromEnum(signal), @as(u32, 255))),
        .stopped, .unknown => 1,
    };
}

pub fn resolveScriptPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    skill_name: []const u8,
    script_name: []const u8,
) ![]u8 {
    const codex_home = try resolveHomePath(allocator, home, ".codex");
    defer allocator.free(codex_home);
    if (try buildCandidateIfExists(allocator, io, codex_home, skill_name, script_name)) |path| {
        return path;
    }

    const claude_home = try resolveHomePath(allocator, home, ".claude");
    defer allocator.free(claude_home);
    if (try buildCandidateIfExists(allocator, io, claude_home, skill_name, script_name)) |path| {
        return path;
    }

    const absolute_fallback = try std.fmt.allocPrint(
        allocator,
        "{s}/.dotfiles/codex/skills/{s}/scripts/{s}",
        .{ home, skill_name, script_name },
    );
    return try retainAccessibleCandidate(allocator, io, absolute_fallback) orelse
        error.ScriptNotFound;
}

fn resolveHomePath(
    allocator: std.mem.Allocator,
    home: []const u8,
    default_dir: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, default_dir });
}

fn buildCandidateIfExists(
    allocator: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    skill_name: []const u8,
    script_name: []const u8,
) !?[]u8 {
    const candidate = try std.fmt.allocPrint(
        allocator,
        "{s}/skills/{s}/scripts/{s}",
        .{ home_dir, skill_name, script_name },
    );
    return retainAccessibleCandidate(allocator, io, candidate);
}

fn retainAccessibleCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidate: []u8,
) !?[]u8 {
    errdefer allocator.free(candidate);
    if (try pathExists(io, candidate)) return candidate;
    allocator.free(candidate);
    return null;
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    // Inaccessible candidates allow fallback, while caller cancellation stays terminal.
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return err,
        else => return false,
    };
    return true;
}

test "isHelpRequested recognizes flags" {
    const argv_help = [_][]const u8{ "x", "--help" };
    try std.testing.expect(isHelpRequested(&argv_help));

    const argv_short = [_][]const u8{ "x", "-h" };
    try std.testing.expect(isHelpRequested(&argv_short));

    const argv_other = [_][]const u8{ "x", "--version" };
    try std.testing.expect(!isHelpRequested(&argv_other));
}

test "isVersionRequested recognizes flags and subcommand" {
    const argv_long = [_][]const u8{ "x", "--version" };
    try std.testing.expect(isVersionRequested(&argv_long));

    const argv_short = [_][]const u8{ "x", "-V" };
    try std.testing.expect(isVersionRequested(&argv_short));

    const argv_subcommand = [_][]const u8{ "x", "version" };
    try std.testing.expect(isVersionRequested(&argv_subcommand));

    const argv_other = [_][]const u8{ "x", "--help" };
    try std.testing.expect(!isVersionRequested(&argv_other));
}

test "resolveScriptPath returns ScriptNotFound for unknown script" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    try std.testing.expectError(
        error.ScriptNotFound,
        resolveScriptPath(
            std.testing.allocator,
            std.testing.io,
            home,
            "__no_such_skill__",
            "__no_such_script__.py",
        ),
    );
}

fn resolveMissingWithAlloc(
    alloc: std.mem.Allocator,
    home: []const u8,
    skill_name: []const u8,
    script_name: []const u8,
) !void {
    _ = resolveScriptPath(
        alloc,
        std.testing.io,
        home,
        skill_name,
        script_name,
    ) catch |err| switch (err) {
        error.ScriptNotFound => return,
        else => return err,
    };
}

test "allocation failures resolving missing script path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveMissingWithAlloc,
        .{ home, "__alloc_missing_skill__", "__alloc_missing_script__.py" },
    );
}

test "appendDelegateArgs maps runtimes to command prefixes" {
    var uv_args: std.ArrayList([]const u8) = .empty;
    defer uv_args.deinit(std.testing.allocator);
    try appendDelegateArgs(
        std.testing.allocator,
        &uv_args,
        .uv_python,
        "/tmp/x.py",
        &.{"--flag"},
    );
    try std.testing.expectEqualStrings("uv", uv_args.items[0]);
    try std.testing.expectEqualStrings("run", uv_args.items[1]);
    try std.testing.expectEqualStrings("python", uv_args.items[2]);
    try std.testing.expectEqualStrings("/tmp/x.py", uv_args.items[3]);
    try std.testing.expectEqualStrings("--flag", uv_args.items[4]);

    var bash_args: std.ArrayList([]const u8) = .empty;
    defer bash_args.deinit(std.testing.allocator);
    try appendDelegateArgs(
        std.testing.allocator,
        &bash_args,
        .bash,
        "/tmp/x.sh",
        &.{"--flag"},
    );
    try std.testing.expectEqualStrings("bash", bash_args.items[0]);
    try std.testing.expectEqualStrings("/tmp/x.sh", bash_args.items[1]);
    try std.testing.expectEqualStrings("--flag", bash_args.items[2]);
}

fn fuzzHelpRequestedTarget(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    const argv = [_][]const u8{ "delegate", input };
    _ = isHelpRequested(&argv);
}

test "fuzz help flag detection" {
    try std.testing.fuzz({}, fuzzHelpRequestedTarget, .{});
}

test "delegated commands use caller I/O and preserve exit status" {
    const status = try runCommand(std.testing.io, &.{ "/bin/sh", "-c", "exit 7" });
    try std.testing.expectEqual(@as(u8, 7), status);
    const signaled = try runCommand(std.testing.io, &.{ "/bin/sh", "-c", "kill -TERM $$" });
    try std.testing.expectEqual(@as(u8, 143), signaled);
}

test "script lookup preserves home-relative precedence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    const roots = [_][]const u8{ ".codex", ".claude", ".dotfiles/codex" };
    for (roots) |root| {
        const directory = try std.fmt.allocPrint(allocator, "{s}/skills/demo/scripts", .{root});
        defer allocator.free(directory);
        try tmp.dir.createDirPath(io, directory);
        const path = try std.fmt.allocPrint(allocator, "{s}/test.py", .{directory});
        defer allocator.free(path);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "pass\n" });
    }
    for (roots) |root| {
        const found = try resolveScriptPath(allocator, io, home, "demo", "test.py");
        defer allocator.free(found);
        const expected = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/skills/demo/scripts/test.py",
            .{ home, root },
        );
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, found);
        try std.Io.Dir.cwd().deleteFile(io, found);
    }
    try std.testing.expectError(
        error.ScriptNotFound,
        resolveScriptPath(allocator, io, home, "demo", "test.py"),
    );
}
