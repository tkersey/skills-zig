const std = @import("std");
const delegate = @import("core_delegate");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas",
    .help_text = UsageText,
};

const UsageText =
    \\cas
    \\
    \\CAS dispatcher for subcommand-style usage.
    \\
    \\Usage:
    \\  cas <subcommand> [args...]
    \\
    \\Subcommands:
    \\  conformance     | conformance-suite  Run cas_conformance_suite.
    \\  instance_runner | instance-runner   Run cas_instance_runner.
    \\  review_session  | review-session    Run cas_review_session.
    \\  smoke_check     | smoke-check       Run cas_smoke_check.
    \\
    \\Examples:
    \\  cas conformance --cwd /path/to/repo --json
    \\  cas instance_runner --cwd /path/to/repo --instances 4
    \\  cas review_session start --cwd /path/to/repo --uncommitted --json
    \\  cas smoke_check --cwd /path/to/repo --json
    \\
    \\Options:
    \\  --help                              Show this help.
    \\  --version | version                 Show version.
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    if (argv.len <= 1 or delegate.isHelpRequested(argv) or std.mem.eql(u8, argv[1], "help")) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    if (delegate.isVersionRequested(argv)) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }

    const target_name = resolveTarget(argv[1]) orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "UnknownSubcommand", argv[1]);
    };

    const target_exec = blk: {
        const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch null;
        if (exe_dir) |dir| break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, target_name });
        break :blk try allocator.dupe(u8, target_name);
    };

    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(allocator);
    try child_argv.append(allocator, target_exec);
    try child_argv.appendSlice(allocator, argv[2..]);

    const exit_code = delegate.runCommand(allocator, child_argv.items) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print(
            "failed to launch {s}: {s}\ninstall or expose the full CAS binary set beside `cas` ({s}, cas_smoke_check, cas_instance_runner, cas_conformance_suite)\n",
            .{ target_name, @errorName(err), target_name },
        );
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

fn resolveTarget(subcommand: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, subcommand, "conformance") or std.mem.eql(u8, subcommand, "conformance-suite") or std.mem.eql(u8, subcommand, "conformance_suite")) {
        return "cas_conformance_suite";
    }
    if (std.mem.eql(u8, subcommand, "instance_runner") or std.mem.eql(u8, subcommand, "instance-runner")) {
        return "cas_instance_runner";
    }
    if (std.mem.eql(u8, subcommand, "review_session") or std.mem.eql(u8, subcommand, "review-session")) {
        return "cas_review_session";
    }
    if (std.mem.eql(u8, subcommand, "smoke_check") or std.mem.eql(u8, subcommand, "smoke-check")) {
        return "cas_smoke_check";
    }
    return null;
}

test "resolveTarget supports supported subcommands" {
    try std.testing.expectEqualStrings("cas_conformance_suite", resolveTarget("conformance").?);
    try std.testing.expectEqualStrings("cas_conformance_suite", resolveTarget("conformance-suite").?);
    try std.testing.expectEqualStrings("cas_instance_runner", resolveTarget("instance_runner").?);
    try std.testing.expectEqualStrings("cas_instance_runner", resolveTarget("instance-runner").?);
    try std.testing.expectEqualStrings("cas_review_session", resolveTarget("review_session").?);
    try std.testing.expectEqualStrings("cas_review_session", resolveTarget("review-session").?);
    try std.testing.expectEqualStrings("cas_smoke_check", resolveTarget("smoke_check").?);
    try std.testing.expectEqualStrings("cas_smoke_check", resolveTarget("smoke-check").?);
    try std.testing.expect(resolveTarget("unknown") == null);
}
