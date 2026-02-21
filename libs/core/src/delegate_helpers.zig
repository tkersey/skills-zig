const std = @import("std");

pub fn isHelpRequested(argv: []const []const u8) bool {
    if (argv.len <= 1) return false;
    const arg = argv[1];
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn runUvPython(
    allocator: std.mem.Allocator,
    script_path: []const u8,
    passthrough_args: []const []const u8,
) !u8 {
    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);

    try child_argv.appendSlice(allocator, &.{ "uv", "run", "python", script_path });
    try child_argv.appendSlice(allocator, passthrough_args);
    return runCommand(allocator, child_argv.items);
}

pub fn runBash(
    allocator: std.mem.Allocator,
    script_path: []const u8,
    passthrough_args: []const []const u8,
) !u8 {
    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);

    try child_argv.appendSlice(allocator, &.{ "bash", script_path });
    try child_argv.appendSlice(allocator, passthrough_args);
    return runCommand(allocator, child_argv.items);
}

pub fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var child = std.process.Child.init(args, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |code| code,
        .Signal => |signal| @intCast(@min(@as(u32, 128) + signal, @as(u32, 255))),
        .Stopped, .Unknown => 1,
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

    const absolute_fallback = try std.fmt.allocPrint(
        allocator,
        "/Users/tk/.dotfiles/codex/skills/{s}/scripts/{s}",
        .{ skill_name, script_name },
    );
    if (pathExists(absolute_fallback)) return absolute_fallback;
    allocator.free(absolute_fallback);

    return error.ScriptNotFound;
}

fn resolveHomePath(
    allocator: std.mem.Allocator,
    env_key: []const u8,
    default_dir: []const u8,
) ![]u8 {
    if (std.posix.getenv(env_key)) |value| {
        return allocator.dupe(u8, value);
    }
    const home = std.posix.getenv("HOME") orelse "/Users/tk";
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
    std.fs.cwd().access(path, .{}) catch return false;
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

fn fuzzHelpRequestedTarget(_: void, input: []const u8) !void {
    const argv = [_][]const u8{ "delegate", input };
    _ = isHelpRequested(&argv);
}

test "fuzz help flag detection" {
    try std.testing.fuzz({}, fuzzHelpRequestedTarget, .{});
}
