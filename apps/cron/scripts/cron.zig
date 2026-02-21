const std = @import("std");

const SourceFile = "cron.zig";
const SkillName = "cron";
const ScriptName = "cron.py";

const UsageText =
    \\cron.zig
    \\
    \\Marker: cron.zig
    \\Delegates non-help invocations to:
    \\  uv run python <resolved cron.py>
    \\
    \\Resolution order:
    \\  1. ${CODEX_HOME:-$HOME/.codex}/skills/cron/scripts/cron.py
    \\  2. ${CLAUDE_HOME:-$HOME/.claude}/skills/cron/scripts/cron.py
    \\  3. /Users/tk/.dotfiles/codex/skills/cron/scripts/cron.py
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (isHelpRequested(argv)) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("{s}\n", .{UsageText});
        return;
    }

    const script_path = resolveScriptPath(allocator, SkillName, ScriptName) catch {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}: unable to locate delegated script {s}\n", .{ SourceFile, ScriptName });
        std.process.exit(1);
    };
    defer allocator.free(script_path);

    const exit_code = runUvPython(allocator, script_path, argv[1..]) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}: delegate execution failed: {s}\n", .{ SourceFile, @errorName(err) });
        std.process.exit(1);
    };

    if (exit_code != 0) std.process.exit(exit_code);
}

fn isHelpRequested(argv: []const []const u8) bool {
    if (argv.len <= 1) return false;
    const arg = argv[1];
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn runUvPython(
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

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
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

fn resolveScriptPath(
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
