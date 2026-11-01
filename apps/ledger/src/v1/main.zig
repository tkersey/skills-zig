const std = @import("std");
const cli = @import("cli.zig");
const storage_root = @import("storage_root");
const host_cli = @import("host_cli.zig");

pub const panic = cli.panic;
pub const std_options = cli.std_options;

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "context")) {
        const code = host_cli.run(init.gpa, init.io, init.environ_map, argv[2..]) catch |err| {
            if (cli.isClosedPipe(err)) return;
            return err;
        };
        if (code != 0) std.process.exit(code);
        return;
    }
    var selection = storage_root.prepare(init.gpa, init.io, argv) catch |err| {
        emitRootError(init.io, err) catch |write_err| {
            if (cli.isClosedPipe(write_err)) return;
            return write_err;
        };
        std.process.exit(rootFailureCode(argv));
    };
    defer selection.deinit(init.gpa);
    var scope = selection.invocationScope(std.Io.Dir.cwd());
    const code = cli.runWithArgv(
        &scope,
        &selection,
        init.gpa,
        init.environ_map,
        selection.argv,
    ) catch |err| blk: {
        cli.emitCommandError(&scope, err) catch |write_err| {
            if (cli.isClosedPipe(write_err)) return;
            return write_err;
        };
        break :blk @as(u8, 2);
    };
    if (code != 0) std.process.exit(code);
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
    _ = host_cli;
}

test "managed projection failure is not a clear route gate" {
    try std.testing.expectEqual(@as(u8, 3), rootFailureCode(&.{ "ledger", "project" }));
    try std.testing.expectEqual(@as(u8, 2), rootFailureCode(&.{ "ledger", "transact" }));
}
