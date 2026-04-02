const app_meta = @import("app_meta");
const core_cli = @import("core_cli");
const core_delegate = @import("core_delegate");
const std = @import("std");

const SourceFile = "puff.zig";
const SkillName = "puff";
const ScriptName = "puff.sh";
const Version = core_cli.normalizeVersion(app_meta.version);

const UsageText =
    \\puff
    \\
    \\Delegates non-help invocations to:
    \\  bash <resolved puff.sh>
    \\
    \\Resolution order:
    \\  1. ${CODEX_HOME:-$HOME/.codex}/skills/puff/scripts/puff.sh
    \\  2. ${CLAUDE_HOME:-$HOME/.claude}/skills/puff/scripts/puff.sh
    \\  3. $HOME/.dotfiles/codex/skills/puff/scripts/puff.sh
    \\
    \\Options:
    \\  -h, --help                        Show help.
    \\  -V, --version | version           Show version.
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
        Version,
        SourceFile,
        SkillName,
        ScriptName,
        .bash,
    );
}
