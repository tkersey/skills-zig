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

    try core_delegate.runDelegatedCli(
        allocator,
        argv,
        UsageText,
        SourceFile,
        SkillName,
        ScriptName,
        .bash,
    );
}
