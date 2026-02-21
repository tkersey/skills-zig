const std = @import("std");
const core_delegate = @import("core_delegate");

const SourceFile = "puff.zig";
const SkillName = "puff";
const ScriptName = "puff.sh";

const UsageText =
    \\puff.zig
    \\
    \\Marker: puff.zig
    \\Delegates non-help invocations to:
    \\  bash <resolved puff.sh>
    \\
    \\Resolution order:
    \\  1. ${CODEX_HOME:-$HOME/.codex}/skills/puff/scripts/puff.sh
    \\  2. ${CLAUDE_HOME:-$HOME/.claude}/skills/puff/scripts/puff.sh
    \\  3. /Users/tk/.dotfiles/codex/skills/puff/scripts/puff.sh
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

    const exit_code = core_delegate.runBash(allocator, script_path, argv[1..]) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}: delegate execution failed: {s}\n", .{ SourceFile, @errorName(err) });
        std.process.exit(1);
    };

    if (exit_code != 0) std.process.exit(exit_code);
}
