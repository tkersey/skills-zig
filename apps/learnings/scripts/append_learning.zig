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

    try core_delegate.runDelegatedCli(
        allocator,
        argv,
        UsageText,
        SourceFile,
        SkillName,
        ScriptName,
        .uv_python,
    );
}
