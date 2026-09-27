const std = @import("std");
const cli = @import("cli.zig");
const ledger = @import("ledger_v1_core");
const storage_root = @import("storage_root");

pub const panic = cli.panic;
pub const std_options = cli.std_options;
pub const std_options_cwd = storage_root.currentCwd;

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    // Preserve the established native entry point for all legacy invocations.
    if (!storage_root.hasSelector(argv)) {
        return cli.main(init);
    }
    ledger.transaction.installRuntimeIo(init.io);
    var selection = storage_root.prepare(init.gpa, init.io, argv) catch |err| {
        emitRootError(init.io, err) catch |write_err| {
            if (cli.isClosedPipe(write_err)) return;
            return write_err;
        };
        std.process.exit(rootFailureCode(argv));
    };
    defer selection.deinit(init.gpa);
    storage_root.install(&selection);
    defer storage_root.uninstall();
    const code = cli.runWithArgv(init.gpa, init.environ_map, selection.argv) catch |err| blk: {
        cli.emitCommandError(err) catch |write_err| {
            if (cli.isClosedPipe(write_err)) return;
            return write_err;
        };
        break :blk @as(u8, 2);
    };
    if (code != 0) std.process.exit(code);
}

pub fn runWithArgv(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    return runManaged(
        allocator,
        std.Io.Threaded.global_single_threaded.io(),
        environment,
        argv,
    );
}

fn runManaged(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var selection = try storage_root.prepare(allocator, io, argv);
    defer selection.deinit(allocator);
    storage_root.install(&selection);
    defer storage_root.uninstall();
    return cli.runWithArgv(allocator, environment, selection.argv);
}

fn rootFailureCode(argv: []const []const u8) u8 {
    // An unavailable managed root must never look like a clear route gate.
    return if (argv.len > 1 and std.mem.eql(u8, argv[1], "project")) 3 else 2;
}

fn emitRootError(io: std.Io, err: anyerror) !void {
    var writer = std.Io.File.stdout().writer(io, &.{});
    try writer.interface.print(
        "{{\"schema\":\"ledger-storage-root-error/v1\",\"error\":\"{s}\"," ++
            "\"storage_mutated\":false,\"authority_granted\":false}}\n",
        .{@errorName(err)},
    );
}

test {
    _ = cli;
    _ = storage_root;
}

test "managed projection failure is not a clear route gate" {
    try std.testing.expectEqual(@as(u8, 3), rootFailureCode(&.{ "ledger", "project" }));
    try std.testing.expectEqual(@as(u8, 2), rootFailureCode(&.{ "ledger", "transact" }));
}
