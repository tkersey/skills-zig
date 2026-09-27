const std = @import("std");
const cli = @import("cli.zig");
const ledger = @import("ledger_v1_core");
const storage_root = @import("storage_root.zig");

pub const panic = cli.panic;
pub const std_options = cli.std_options;

const storage_help =
    \\Managed custody roots:
    \\  Durable commands also accept --store-root <absolute-directory> --store-id <id>
    \\  instead of --repo. The caller selects and initializes the root; Ledger verifies
    \\  its identity marker and keeps all logical slots beneath its .ledger directory.
    \\  No Git discovery, default location, registration, migration, or fallback occurs.
    \\
;

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    // Preserve the established native entry point for all legacy invocations.
    if (!storage_root.hasSelector(argv)) {
        if (isHelp(argv)) try write(init.io, storage_help);
        return cli.main(init);
    }
    ledger.transaction.installRuntimeIo(init.io);
    const code = runManaged(init.gpa, init.io, init.environ_map, argv) catch |err| {
        try emitRootError(init.io, err);
        std.process.exit(rootFailureCode(argv));
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
    return cli.runWithArgv(allocator, environment, selection.argv);
}

fn rootFailureCode(argv: []const []const u8) u8 {
    // An unavailable managed root must never look like a clear route gate.
    return if (argv.len > 1 and std.mem.eql(u8, argv[1], "project")) 3 else 2;
}

fn isHelp(argv: []const []const u8) bool {
    if (argv.len < 2) return false;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

fn write(io: std.Io, bytes: []const u8) !void {
    var writer = std.Io.File.stdout().writer(io, &.{});
    try writer.interface.writeAll(bytes);
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
