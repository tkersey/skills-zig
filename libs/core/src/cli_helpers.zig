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

pub fn containsHelpArg(args: []const []const u8) bool {
    for (args) |arg| {
        if (isHelpArg(arg)) return true;
    }
    return false;
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

pub fn printHelpWithVersion(
    writer: anytype,
    usage_text: []const u8,
    version_text: []const u8,
) !void {
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
    writer: *std.Io.Writer,
    argv: []const []const u8,
    usage_text: []const u8,
    version_text: []const u8,
) !bool {
    return handleDefaultHelpAndVersionSurface(writer, argv, .{
        .executable_name = "",
        .help_text = usage_text,
    }, version_text);
}

pub fn handleDefaultHelpAndVersionSurface(
    writer: *std.Io.Writer,
    argv: []const []const u8,
    surface: HelpSurface,
    version_text: []const u8,
) !bool {
    if (argv.len <= 1) {
        try printHelpSurface(writer, surface, version_text);
        return true;
    }

    const first = argv[1];
    if (isHelpArg(first)) {
        try printHelpSurface(writer, surface, version_text);
        return true;
    }
    if (isVersionArg(first) or isVersionSubcommand(first)) {
        try printVersion(writer, version_text);
        return true;
    }
    return false;
}

test "normalizeVersion trims whitespace and newline" {
    try std.testing.expectEqualStrings("1.2.3", normalizeVersion(" 1.2.3 \n"));
}

test "version flags and subcommand detection" {
    try std.testing.expect(isHelpArg("--help"));
    try std.testing.expect(isHelpArg("-h"));
    try std.testing.expect(!isHelpArg("-help"));
    try std.testing.expect(isVersionArg("--version"));
    try std.testing.expect(isVersionArg("-V"));
    try std.testing.expect(isVersionSubcommand("version"));
    try std.testing.expect(!isVersionArg("-h"));
}

test "containsHelpArg recognizes help anywhere in an argument tail" {
    try std.testing.expect(containsHelpArg(&.{ "--limit", "5", "--help" }));
    try std.testing.expect(containsHelpArg(&.{"-h"}));
    try std.testing.expect(!containsHelpArg(&.{ "--limit", "5" }));
}

test "printUsageFailureWithHelp renders token detail and versioned help" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try printUsageFailureWithHelp(
        &output.writer,
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
        output.written(),
    );
}

test "usage diagnostic reports writer failure" {
    var writer = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, printUsageFailureWithHelp(
        &writer,
        .{ .executable_name = "demo", .help_text = "demo --help" },
        "1.2.3",
        "MissingValue",
        "--input",
    ));
}

test "default help and version preserve dispatch and exact output" {
    const cases = .{
        .{ &[_][]const u8{}, true, "usage\n\nVersion: 1.2.3\n" },
        .{ &[_][]const u8{"demo"}, true, "usage\n\nVersion: 1.2.3\n" },
        .{ &[_][]const u8{ "demo", "--help" }, true, "usage\n\nVersion: 1.2.3\n" },
        .{ &[_][]const u8{ "demo", "-h" }, true, "usage\n\nVersion: 1.2.3\n" },
        .{ &[_][]const u8{ "demo", "--version" }, true, "1.2.3\n" },
        .{ &[_][]const u8{ "demo", "-V" }, true, "1.2.3\n" },
        .{ &[_][]const u8{ "demo", "version" }, true, "1.2.3\n" },
        .{ &[_][]const u8{ "demo", "--unknown" }, false, "" },
        .{ &[_][]const u8{ "demo", "--option", "--help" }, false, "" },
        .{ &[_][]const u8{ "demo", "positional", "--version" }, false, "" },
    };
    inline for (cases) |case| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        try std.testing.expectEqual(case[1], try handleDefaultHelpAndVersion(
            &output.writer,
            case[0],
            "usage",
            " 1.2.3\n",
        ));
        try std.testing.expectEqualStrings(case[2], output.written());
    }
}

test "default help writer failure is observable by its caller" {
    var writer = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, handleDefaultHelpAndVersion(
        &writer,
        &.{ "demo", "--help" },
        "usage",
        "1.2.3",
    ));
}
