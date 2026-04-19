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
        error.MissingContainsArg,
        error.MissingThreadIdArg,
        error.MissingRolloutSummaryArg,
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

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    runMain(init.gpa, argv) catch |err| {
        if (shouldIgnoreWriteError(err)) return;
        if (shouldSuppressCliError(err)) std.process.exit(2);
        return err;
    };
}

fn runMain(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var arg_index: usize = 1;

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    const arg = if (arg_index < argv.len) argv[arg_index] else {
        try printCommandList(stdout);
        return;
    };
    arg_index += 1;

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
            while (arg_index < argv.len) : (arg_index += 1) {
                try unknown_args.append(allocator, argv[arg_index]);
            }

            if (try runLegacyNumericSeqCompat(stdout, unknown_args.items)) {
                return;
            }

            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            try stderr_writer.interface.print("unknown command: {s}\n", .{arg});
            return error.InvalidCommand;
        },
        else => {
            var extra_args: std.ArrayList([]const u8) = .empty;
            defer extra_args.deinit(allocator);

            while (arg_index < argv.len) : (arg_index += 1) {
                try extra_args.append(allocator, argv[arg_index]);
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
    var writer = std.Io.Writer.fixed(&out);

    try std.testing.expect(try runLegacyNumericSeqCompat(&writer, &[_][]const u8{"9"}));
    try std.testing.expectEqualStrings("1\n2\n3\n4\n5\n6\n7\n8\n9\n", writer.buffer[0..writer.end]);
}

test "legacy numeric compatibility handles explicit start/end and start/step/end" {
    var out_two: [256]u8 = undefined;
    var writer_two = std.Io.Writer.fixed(&out_two);
    try std.testing.expect(try runLegacyNumericSeqCompat(&writer_two, &[_][]const u8{ "1", "9" }));
    try std.testing.expectEqualStrings("1\n2\n3\n4\n5\n6\n7\n8\n9\n", writer_two.buffer[0..writer_two.end]);

    var out_three: [256]u8 = undefined;
    var writer_three = std.Io.Writer.fixed(&out_three);
    try std.testing.expect(try runLegacyNumericSeqCompat(&writer_three, &[_][]const u8{ "1", "2", "9" }));
    try std.testing.expectEqualStrings("1\n3\n5\n7\n9\n", writer_three.buffer[0..writer_three.end]);
}

test "legacy numeric compatibility ignores non-numeric invocations" {
    var out: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);

    try std.testing.expect(!(try runLegacyNumericSeqCompat(&writer, &[_][]const u8{"datasets"})));
    try std.testing.expectEqualStrings("", writer.buffer[0..writer.end]);
}
