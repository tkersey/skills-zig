const std = @import("std");

pub const HelpSurface = struct {
    executable_name: []const u8,
    help_text: []const u8,
};

pub fn normalizeVersion(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n");
}

pub fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn isVersionArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V");
}

pub fn isVersionSubcommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "version");
}

pub fn printVersion(writer: anytype, version_text: []const u8) !void {
    try writer.print("{s}\n", .{normalizeVersion(version_text)});
}

pub fn printHelpWithVersion(writer: anytype, usage_text: []const u8, version_text: []const u8) !void {
    try writer.print("{s}\n\nVersion: {s}\n", .{ usage_text, normalizeVersion(version_text) });
}

pub fn printHelpSurface(writer: anytype, surface: HelpSurface, version_text: []const u8) !void {
    _ = surface.executable_name;
    try printHelpWithVersion(writer, surface.help_text, version_text);
}

pub fn printUsageFailureWithHelp(
    writer: anytype,
    surface: HelpSurface,
    version_text: []const u8,
    err_token: []const u8,
    detail: ?[]const u8,
) !void {
    if (detail) |value| {
        if (value.len > 0) {
            try writer.print("{s}: {s}\n", .{ err_token, value });
        } else {
            try writer.print("{s}\n", .{err_token});
        }
    } else {
        try writer.print("{s}\n", .{err_token});
    }
    try printHelpSurface(writer, surface, version_text);
}

pub fn handleDefaultHelpAndVersion(
    argv: []const []const u8,
    usage_text: []const u8,
    version_text: []const u8,
) !bool {
    return handleDefaultHelpAndVersionSurface(argv, .{
        .executable_name = "",
        .help_text = usage_text,
    }, version_text);
}

pub fn handleDefaultHelpAndVersionSurface(
    argv: []const []const u8,
    surface: HelpSurface,
    version_text: []const u8,
) !bool {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    if (argv.len <= 1) {
        try printHelpSurface(stdout, surface, version_text);
        return true;
    }

    const first = argv[1];
    if (isHelpArg(first)) {
        try printHelpSurface(stdout, surface, version_text);
        return true;
    }
    if (isVersionArg(first) or isVersionSubcommand(first)) {
        try printVersion(stdout, version_text);
        return true;
    }
    return false;
}

pub fn exitUsageFailure(
    surface: HelpSurface,
    version_text: []const u8,
    err_token: []const u8,
    detail: ?[]const u8,
) noreturn {
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stderr = &stderr_writer.interface;
    printUsageFailureWithHelp(stderr, surface, version_text, err_token, detail) catch {};
    std.process.exit(2);
}

test "normalizeVersion trims whitespace and newline" {
    try std.testing.expectEqualStrings("1.2.3", normalizeVersion(" 1.2.3 \n"));
}

test "version flags and subcommand detection" {
    try std.testing.expect(isVersionArg("--version"));
    try std.testing.expect(isVersionArg("-V"));
    try std.testing.expect(isVersionSubcommand("version"));
    try std.testing.expect(!isVersionArg("-h"));
}

test "printUsageFailureWithHelp renders token detail and versioned help" {
    var out: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);
    try printUsageFailureWithHelp(
        fbs.writer(),
        .{
            .executable_name = "demo",
            .help_text = "demo\n\nUsage:\n  demo --help",
        },
        " 1.2.3 \n",
        "MissingValue",
        "--input",
    );
    try std.testing.expectEqualStrings(
        "MissingValue: --input\ndemo\n\nUsage:\n  demo --help\n\nVersion: 1.2.3\n",
        fbs.getWritten(),
    );
}
