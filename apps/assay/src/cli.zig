const std = @import("std");
const core_cli = @import("core_cli");
const diag = @import("diag.zig");

pub const Command = enum { capabilities, assess, compare, explain };
pub const Format = enum { json, text };

pub const Flag = enum {
    contract,
    subject,
    evidence,
    @"subject-root",
    baseline,
    candidate,
    assessment,
    format,
};

pub const Options = struct {
    command: Command,
    help: bool = false,
    format: Format = .json,
    values: std.enums.EnumArray(Flag, ?[]const u8) = .initFill(null),

    pub fn get(self: Options, flag: Flag) ?[]const u8 {
        return self.values.get(flag);
    }

    pub fn required(self: Options, flag: Flag) []const u8 {
        return self.values.get(flag).?;
    }
};

fn allowed(command: Command, flag: Flag) bool {
    return switch (command) {
        .capabilities => false,
        .assess => switch (flag) {
            .contract, .subject, .evidence, .@"subject-root", .format => true,
            else => false,
        },
        .compare => flag == .baseline or flag == .candidate or flag == .format,
        .explain => flag == .assessment or flag == .format,
    };
}

fn mandatory(command: Command) []const Flag {
    return switch (command) {
        .capabilities => &.{},
        .assess => &.{ .contract, .subject, .evidence },
        .compare => &.{ .baseline, .candidate },
        .explain => &.{.assessment},
    };
}

const Token = union(enum) {
    help,
    positional: []const u8,
    flag: struct { name: []const u8, value: ?[]const u8 },
};

fn isValue(argument: []const u8) bool {
    return !std.mem.startsWith(u8, argument, "--") and !core_cli.isHelpArg(argument);
}

const Tokens = struct {
    arguments: []const []const u8,
    index: usize = 1,

    fn next(self: *Tokens) ?Token {
        if (self.index >= self.arguments.len) return null;
        const argument = self.arguments[self.index];
        self.index += 1;
        if (core_cli.isHelpArg(argument)) return .help;
        if (!std.mem.startsWith(u8, argument, "--")) return .{ .positional = argument };
        var value: ?[]const u8 = null;
        if (self.index < self.arguments.len and isValue(self.arguments[self.index])) {
            value = self.arguments[self.index];
            self.index += 1;
        }
        return .{ .flag = .{ .name = argument[2..], .value = value } };
    }
};

pub fn requestedFormat(arguments: []const []const u8) Format {
    var tokens: Tokens = .{ .arguments = arguments };
    var format: Format = .json;
    while (tokens.next()) |token| switch (token) {
        .flag => |flag| if (std.mem.eql(u8, flag.name, "format")) {
            const value = flag.value orelse continue;
            format = std.meta.stringToEnum(Format, value) orelse format;
        },
        else => {},
    };
    return format;
}

pub fn parse(arguments: []const []const u8, d: *diag.Diagnostic) error{Rejected}!Options {
    std.debug.assert(arguments.len >= 1);
    const command = std.meta.stringToEnum(Command, arguments[0]) orelse {
        return d.fail(.invalid_usage, null, "unknown command; run assay --help", .{});
    };
    var options: Options = .{ .command = command };
    for (arguments[1..]) |argument| {
        if (core_cli.isHelpArg(argument)) {
            options.help = true;
            return options;
        }
    }
    var tokens: Tokens = .{ .arguments = arguments };
    while (tokens.next()) |token| switch (token) {
        .help => unreachable,
        .positional => return d.fail(.invalid_usage, null, "unexpected positional argument", .{}),
        .flag => |entry| try admitFlag(&options, entry.name, entry.value, d),
    };
    if (options.get(.format)) |format| {
        options.format = std.meta.stringToEnum(Format, format) orelse {
            return d.fail(.invalid_usage, null, "--format must be json or text", .{});
        };
    }
    for (mandatory(command)) |flag| {
        if (options.get(flag) == null) {
            return d.fail(.invalid_usage, null, "--{s} is required", .{@tagName(flag)});
        }
    }
    return options;
}

fn admitFlag(
    options: *Options,
    name: []const u8,
    value: ?[]const u8,
    d: *diag.Diagnostic,
) error{Rejected}!void {
    const command = options.command;
    const flag = std.meta.stringToEnum(Flag, name) orelse {
        return d.fail(.invalid_usage, null, "unknown flag for {s}", .{@tagName(command)});
    };
    if (!allowed(command, flag)) {
        return d.fail(.invalid_usage, null, "--{s} is not accepted by {s}", .{
            @tagName(flag), @tagName(command),
        });
    }
    if (options.values.get(flag) != null) {
        return d.fail(.invalid_usage, null, "--{s} was repeated", .{@tagName(flag)});
    }
    const present = value orelse {
        return d.fail(.invalid_usage, null, "--{s} requires a value", .{@tagName(flag)});
    };
    options.values.set(flag, present);
}

const testing = std.testing;

test "command admission accepts exact flags and rejects ambiguity" {
    var d: diag.Diagnostic = .{};
    const ok = try parse(&.{
        "assess", "--contract", "c", "--subject", "s", "--evidence", "e", "--format", "text",
    }, &d);
    try testing.expectEqual(Command.assess, ok.command);
    try testing.expectEqual(Format.text, ok.format);
    try testing.expect(ok.get(.@"subject-root") == null);
    const rejected = [_][]const []const u8{
        &.{"unknown"},
        &.{"assess"},
        &.{ "assess", "--contract", "c", "--subject", "s" },
        &.{ "assess", "--contract", "c", "--contract", "c", "--subject", "s", "--evidence", "e" },
        &.{ "assess", "--contract", "c", "--subject", "s", "--evidence", "e", "extra" },
        &.{ "assess", "--contract", "c", "--subject", "s", "--evidence", "e", "--baseline", "b" },
        &.{ "assess", "--contract", "c", "--subject", "s", "--evidence", "e", "--format", "yaml" },
        &.{ "assess", "--contract", "c", "--subject", "s", "--evidence" },
        &.{ "compare", "--baseline", "b" },
        &.{ "explain", "--assessment", "a", "--format", "json", "--format", "text" },
        &.{ "capabilities", "--format", "json" },
        &.{ "explain", "--assessment=a" },
    };
    for (rejected) |arguments| {
        try testing.expectError(error.Rejected, parse(arguments, &d));
        try testing.expectEqual(diag.Code.invalid_usage, d.code);
    }
    try testing.expect((try parse(&.{ "compare", "--help" }, &d)).help);
    try testing.expect((try parse(&.{ "assess", "--contract", "--help" }, &d)).help);
    try testing.expectError(error.Rejected, parse(&.{
        "assess", "--contract", "--subject", "s", "--evidence", "e",
    }, &d));
    try testing.expectEqualStrings("--contract requires a value", d.message());
    try testing.expectEqual(Format.text, requestedFormat(&.{ "x", "--format", "text" }));
    try testing.expectEqual(Format.json, requestedFormat(&.{ "x", "--format" }));
    const dangling = [_][]const u8{ "explain", "--assessment", "--format" };
    try testing.expectEqual(Format.json, requestedFormat(&dangling));
    const shifted = [_][]const u8{ "x", "--a", "--format", "--b", "text" };
    try testing.expectEqual(Format.json, requestedFormat(&shifted));
}
