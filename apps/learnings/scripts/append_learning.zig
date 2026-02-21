const std = @import("std");
const core_delegate = @import("core_delegate");

const SourceFile = "append_learning.zig";
const SkillName = "learnings";
const ScriptName = "append_learning.py";

const UsageText =
    \\append_learning.zig
    \\
    \\Marker: append_learning.zig
    \\Delegates non-help invocations to:
    \\  uv run python <resolved append_learning.py>
    \\
    \\Resolution order:
    \\  1. ${CODEX_HOME:-$HOME/.codex}/skills/learnings/scripts/append_learning.py
    \\  2. ${CLAUDE_HOME:-$HOME/.claude}/skills/learnings/scripts/append_learning.py
    \\  3. /Users/tk/.dotfiles/codex/skills/learnings/scripts/append_learning.py
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (core_delegate.isHelpRequested(argv)) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("{s}\n", .{UsageText});
        return;
    }

    const script_path = core_delegate.resolveScriptPath(allocator, SkillName, ScriptName) catch {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}: unable to locate delegated script {s}\n", .{ SourceFile, ScriptName });
        std.process.exit(1);
    };
    defer allocator.free(script_path);

    const exit_code = core_delegate.runUvPython(allocator, script_path, argv[1..]) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}: delegate execution failed: {s}\n", .{ SourceFile, @errorName(err) });
        std.process.exit(1);
    };

    if (exit_code != 0) std.process.exit(exit_code);
}
