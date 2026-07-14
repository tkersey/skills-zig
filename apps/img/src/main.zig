const std = @import("std");
const lib = @import("lib.zig");
const app_meta = @import("app_meta");

const version = app_meta.version;

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    runMain(init.gpa, init.io, init.environ_map, argv) catch |err| {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        stderr.print("img: {s} ({s})\n", .{ lib.errorMessage(err), @errorName(err) }) catch {};
        if (lib.cli.isUsageError(err)) {
            stderr.writeAll("Try 'img --help' for usage.\n") catch {};
            std.process.exit(2);
        }
        std.process.exit(1);
    };
}

fn runMain(
    allocator: std.mem.Allocator,
    process_io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !void {
    const args = if (argv.len > 1) argv[1..] else &.{};
    var parsed = try lib.cli.parse(allocator, args);
    switch (parsed) {
        .help => {
            try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), lib.cli.help_text);
        },
        .version => {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            try stdout_writer.interface.print("{s}\n", .{version});
        },
        .options => |*options| {
            defer options.deinit(allocator);
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            try lib.executeWithEnvironment(allocator, process_io, parent_environment, options.*, &stdout_writer.interface, &stderr_writer.interface);
        },
    }
}
