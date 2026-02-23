const std = @import("std");
const core_delegate = @import("core_delegate");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const SourceFile = "cron.zig";
const SkillName = "cron";
const ScriptName = "cron.py";
const Version = core_cli.normalizeVersion(app_meta.version);

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
        .uv_python,
    );
}
