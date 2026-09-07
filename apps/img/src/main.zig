const std = @import("std");
const lib = @import("lib.zig");
const app_meta = @import("app_meta");

const version = app_meta.version;

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    runMain(init.gpa, init.io, init.environ_map, argv) catch |err| {
        const code: u8 = if (lib.cli.isUsageError(err)) 2 else 1;
        reportError(init.io, err) catch std.process.exit(code);
        std.process.exit(code);
    };
}

fn reportError(io: std.Io, err: anyerror) !void {
    var writer = std.Io.File.stderr().writer(io, &.{});
    try writer.interface.print("img: {s} ({s})\n", .{ lib.errorMessage(err), @errorName(err) });
    if (lib.cli.isUsageError(err)) {
        try writer.interface.writeAll("Try 'img --help' for usage.\n");
    }
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
            try std.Io.File.stdout().writeStreamingAll(
                std.Io.Threaded.global_single_threaded.io(),
                lib.cli.help_text,
            );
        },
        .version => {
            var stdout_writer = std.Io.File.stdout().writer(
                std.Io.Threaded.global_single_threaded.io(),
                &.{},
            );
            try stdout_writer.interface.print("{s}\n", .{version});
        },
        .options => |*options| {
            defer options.deinit(allocator);
            var stdout_writer = std.Io.File.stdout().writer(
                std.Io.Threaded.global_single_threaded.io(),
                &.{},
            );
            var stderr_writer = std.Io.File.stderr().writer(
                std.Io.Threaded.global_single_threaded.io(),
                &.{},
            );
            try lib.executeWithEnvironment(
                allocator,
                process_io,
                parent_environment,
                options.*,
                &stdout_writer.interface,
                &stderr_writer.interface,
            );
        },
    }
}
