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

pub fn requestedFormat(arguments: []const []const u8) Format {
    var index: usize = 0;
    while (index + 1 < arguments.len) : (index += 1) {
        if (std.mem.eql(u8, arguments[index], "--format") and
            std.mem.eql(u8, arguments[index + 1], "text")) return .text;
    }
    return .json;
}

pub fn parse(arguments: []const []const u8, d: *diag.Diagnostic) error{Rejected}!Options {
    std.debug.assert(arguments.len >= 1);
    const command = std.meta.stringToEnum(Command, arguments[0]) orelse {
        return d.fail(.invalid_usage, null, "unknown command; run assay --help", .{});
    };
    var options: Options = .{ .command = command };
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (core_cli.isHelpArg(argument)) {
            options.help = true;
            continue;
        }
        if (!std.mem.startsWith(u8, argument, "--")) {
            return d.fail(.invalid_usage, null, "unexpected positional argument", .{});
        }
        const flag = std.meta.stringToEnum(Flag, argument[2..]) orelse {
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
        if (index + 1 == arguments.len) {
            return d.fail(.invalid_usage, null, "--{s} requires a value", .{@tagName(flag)});
        }
        index += 1;
        options.values.set(flag, arguments[index]);
    }
    if (options.help) return options;
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
    try testing.expectEqual(Format.text, requestedFormat(&.{ "x", "--format", "text" }));
    try testing.expectEqual(Format.json, requestedFormat(&.{ "x", "--format" }));
}
