const std = @import("std");

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

pub fn handleDefaultHelpAndVersion(
    argv: []const []const u8,
    usage_text: []const u8,
    version_text: []const u8,
) !bool {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    if (argv.len <= 1) {
        try printHelpWithVersion(stdout, usage_text, version_text);
        return true;
    }

    const first = argv[1];
    if (isHelpArg(first)) {
        try printHelpWithVersion(stdout, usage_text, version_text);
        return true;
    }
    if (isVersionArg(first) or isVersionSubcommand(first)) {
        try printVersion(stdout, version_text);
        return true;
    }
    return false;
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
