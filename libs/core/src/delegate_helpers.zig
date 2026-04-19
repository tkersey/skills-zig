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
    argv: []const []const u8,
    usage_text: []const u8,
    version_text: []const u8,
    source_file: []const u8,
    skill_name: []const u8,
    script_name: []const u8,
    runtime: DelegateRuntime,
) !void {
    if (argv.len <= 1 or isHelpRequested(argv)) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpWithVersion(stdout, usage_text, version_text);
        return;
    }

    if (isVersionRequested(argv)) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, version_text);
        return;
    }

    const script_path = resolveScriptPath(allocator, skill_name, script_name) catch {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}: unable to locate delegated script {s}\n", .{ source_file, script_name });
        std.process.exit(1);
    };
    defer allocator.free(script_path);

    const exit_code = runDelegateRuntime(allocator, runtime, script_path, argv[1..]) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}: delegate execution failed: {s}\n", .{ source_file, @errorName(err) });
        std.process.exit(1);
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

pub fn runUvPython(
    allocator: std.mem.Allocator,
    script_path: []const u8,
    passthrough_args: []const []const u8,
) !u8 {
    return runDelegateRuntime(allocator, .uv_python, script_path, passthrough_args);
}

pub fn runBash(
    allocator: std.mem.Allocator,
    script_path: []const u8,
    passthrough_args: []const []const u8,
) !u8 {
    return runDelegateRuntime(allocator, .bash, script_path, passthrough_args);
}

fn runDelegateRuntime(
    allocator: std.mem.Allocator,
    runtime: DelegateRuntime,
    script_path: []const u8,
    passthrough_args: []const []const u8,
) !u8 {
    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);

    try appendDelegateArgs(allocator, &child_argv, runtime, script_path, passthrough_args);
    return runCommand(allocator, child_argv.items);
}

fn appendDelegateArgs(
    allocator: std.mem.Allocator,
    child_argv: *std.ArrayList([]const u8),
    runtime: DelegateRuntime,
    script_path: []const u8,
    passthrough_args: []const []const u8,
) !void {
    switch (runtime) {
        .uv_python => try child_argv.appendSlice(allocator, &.{ "uv", "run", "python", script_path }),
        .bash => try child_argv.appendSlice(allocator, &.{ "bash", script_path }),
    }
    try child_argv.appendSlice(allocator, passthrough_args);
}

pub fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = args,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| @intCast(@min(@as(u32, 128) + @intFromEnum(signal), @as(u32, 255))),
        .stopped, .unknown => 1,
    };
}

pub fn resolveScriptPath(
    allocator: std.mem.Allocator,
    skill_name: []const u8,
    script_name: []const u8,
) ![]u8 {
    const codex_home = try resolveHomePath(allocator, "CODEX_HOME", ".codex");
    defer allocator.free(codex_home);
    if (try buildCandidateIfExists(allocator, codex_home, skill_name, script_name)) |path| return path;

    const claude_home = try resolveHomePath(allocator, "CLAUDE_HOME", ".claude");
    defer allocator.free(claude_home);
    if (try buildCandidateIfExists(allocator, claude_home, skill_name, script_name)) |path| return path;

    const home = std.Io.Threaded.global_single_threaded.environString("HOME") orelse return error.MissingHome;
    const absolute_fallback = try std.fmt.allocPrint(
        allocator,
        "{s}/.dotfiles/codex/skills/{s}/scripts/{s}",
        .{ home, skill_name, script_name },
    );
    if (pathExists(absolute_fallback)) return absolute_fallback;
    allocator.free(absolute_fallback);

    return error.ScriptNotFound;
}

fn resolveHomePath(
    allocator: std.mem.Allocator,
    comptime env_key: []const u8,
    default_dir: []const u8,
) ![]u8 {
    _ = env_key;
    const home = std.Io.Threaded.global_single_threaded.environString("HOME") orelse return error.MissingHome;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, default_dir });
}

fn buildCandidateIfExists(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    skill_name: []const u8,
    script_name: []const u8,
) !?[]u8 {
    const candidate = try std.fmt.allocPrint(
        allocator,
        "{s}/skills/{s}/scripts/{s}",
        .{ home_dir, skill_name, script_name },
    );
    if (pathExists(candidate)) return candidate;
    allocator.free(candidate);
    return null;
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
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
    try std.testing.expectError(
        error.ScriptNotFound,
        resolveScriptPath(std.testing.allocator, "__no_such_skill__", "__no_such_script__.py"),
    );
}

fn resolveMissingWithAlloc(
    alloc: std.mem.Allocator,
    skill_name: []const u8,
    script_name: []const u8,
) !void {
    _ = resolveScriptPath(alloc, skill_name, script_name) catch |err| switch (err) {
        error.ScriptNotFound => return,
        else => return err,
    };
}

test "allocation failures resolving missing script path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveMissingWithAlloc,
        .{ "__alloc_missing_skill__", "__alloc_missing_script__.py" },
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

fn fuzzHelpRequestedTarget(_: void, input: []const u8) !void {
    const argv = [_][]const u8{ "delegate", input };
    _ = isHelpRequested(&argv);
}

test "fuzz help flag detection" {
    try std.testing.fuzz({}, fuzzHelpRequestedTarget, .{});
}
