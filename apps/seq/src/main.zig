const std = @import("std");
const lib = @import("lib.zig");
const commands = @import("commands/mod.zig");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");

const Version = core_cli.normalizeVersion(app_meta.version);

fn shouldIgnoreWriteError(err: anyerror) bool {
    return err == error.WriteFailed or err == error.BrokenPipe;
}

fn shouldSuppressCliError(err: anyerror) bool {
    return switch (err) {
        error.InvalidCommand,
        error.UnknownArgument,
        error.UnsupportedOption,
        error.InvalidFormatForCommand,
        error.InvalidLimit,
        error.MissingArgValue,
        error.MissingDatasetArg,
        error.MissingSpecArg,
        error.MissingSkillArg,
        error.MissingPromptArg,
        error.MissingSectionsArg,
        error.MissingCueSpecArg,
        error.SessionNotFound,
        error.InvalidSessionTarget,
        error.AmbiguousSessionTarget,
        error.CurrentSessionUnavailable,
        error.InvalidRoleArg,
        error.InvalidModeArg,
        error.QueryHangDetected,
        => true,
        else => false,
    };
}

fn printCommandList(stdout: anytype) !void {
    try stdout.print("seq\n", .{});
    try stdout.print("Version: {s}\n", .{Version});
    try stdout.print("Commands:\n", .{});
    for (lib.commandNames()) |def| {
        try stdout.print("- {s}\n", .{def.name});
    }
    try stdout.writeAll("\nUse: seq <command> [options]\n");
}

fn writeIntegerSequence(stdout: anytype, start: i64, step: i64, last: i64) !void {
    if (step == 0) return error.InvalidCommand;

    var current = start;
    while (true) {
        const in_range = if (step > 0) current <= last else current >= last;
        if (!in_range) break;

        try stdout.print("{d}\n", .{current});
        const next, const overflow = @addWithOverflow(current, step);
        if (overflow != 0) break;
        current = next;
    }
}

fn runLegacyNumericSeqCompat(stdout: anytype, argv: []const []const u8) !bool {
    if (argv.len == 0 or argv.len > 3) return false;

    var values: [3]i64 = undefined;
    for (argv, 0..) |token, idx| {
        values[idx] = std.fmt.parseInt(i64, token, 10) catch return false;
    }

    switch (argv.len) {
        1 => try writeIntegerSequence(stdout, 1, 1, values[0]),
        2 => try writeIntegerSequence(stdout, values[0], 1, values[1]),
        3 => try writeIntegerSequence(stdout, values[0], values[1], values[2]),
        else => unreachable,
    }
    return true;
}

pub fn main() !void {
    runMain() catch |err| {
        if (shouldIgnoreWriteError(err)) return;
        if (shouldSuppressCliError(err)) std.process.exit(2);
        return err;
    };
}

fn runMain() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var args = std.process.args();
    _ = args.next();

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    const arg = args.next() orelse {
        try printCommandList(stdout);
        return;
    };

    if (lib.isHelpArg(arg)) {
        try printCommandList(stdout);
        return;
    }
    if (core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) {
        try core_cli.printVersion(stdout, Version);
        return;
    }

    const cmd = lib.parseCommand(arg);
    switch (cmd) {
        .unknown => {
            var unknown_args: std.ArrayList([]const u8) = .empty;
            defer unknown_args.deinit(allocator);
            try unknown_args.append(allocator, arg);
            while (args.next()) |next_arg| {
                try unknown_args.append(allocator, next_arg);
            }

            if (try runLegacyNumericSeqCompat(stdout, unknown_args.items)) {
                return;
            }

            var stderr_writer = std.fs.File.stderr().writer(&.{});
            try stderr_writer.interface.print("unknown command: {s}\n", .{arg});
            return error.InvalidCommand;
        },
        else => {
            var extra_args: std.ArrayList([]const u8) = .empty;
            defer extra_args.deinit(allocator);

            while (args.next()) |next_arg| {
                try extra_args.append(allocator, next_arg);
            }

            try commands.run(allocator, cmd, extra_args.items);
        },
    }
}

test "shouldIgnoreWriteError recognizes broken pipe write failures" {
    try std.testing.expect(shouldIgnoreWriteError(error.WriteFailed));
    try std.testing.expect(shouldIgnoreWriteError(error.BrokenPipe));
    try std.testing.expect(!shouldIgnoreWriteError(error.InvalidCommand));
}

test "legacy numeric compatibility handles one to three positional args" {
    var out: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);

    try std.testing.expect(try runLegacyNumericSeqCompat(fbs.writer(), &[_][]const u8{"9"}));
    try std.testing.expectEqualStrings("1\n2\n3\n4\n5\n6\n7\n8\n9\n", fbs.getWritten());
}

test "legacy numeric compatibility handles explicit start/end and start/step/end" {
    var out_two: [256]u8 = undefined;
    var fbs_two = std.io.fixedBufferStream(&out_two);
    try std.testing.expect(try runLegacyNumericSeqCompat(fbs_two.writer(), &[_][]const u8{ "1", "9" }));
    try std.testing.expectEqualStrings("1\n2\n3\n4\n5\n6\n7\n8\n9\n", fbs_two.getWritten());

    var out_three: [256]u8 = undefined;
    var fbs_three = std.io.fixedBufferStream(&out_three);
    try std.testing.expect(try runLegacyNumericSeqCompat(fbs_three.writer(), &[_][]const u8{ "1", "2", "9" }));
    try std.testing.expectEqualStrings("1\n3\n5\n7\n9\n", fbs_three.getWritten());
}

test "legacy numeric compatibility ignores non-numeric invocations" {
    var out: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);

    try std.testing.expect(!(try runLegacyNumericSeqCompat(fbs.writer(), &[_][]const u8{"datasets"})));
    try std.testing.expectEqualStrings("", fbs.getWritten());
}
