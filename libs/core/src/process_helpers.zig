const std = @import("std");
const builtin = @import("builtin");

pub const ExecutableResolution = enum { direct, search_path };

const PosixCommand = struct {
    arena: std.heap.ArenaAllocator,
    executable: [:0]const u8,
    argv: [:null]?[*:0]const u8,
    environ: [:null]const ?[*:0]const u8,

    fn init(
        allocator: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        executable: []const u8,
        args: []const []const u8,
    ) !PosixCommand {
        if (args.len == 0) return error.FileNotFound;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const argv = try owned.allocSentinel(?[*:0]const u8, args.len, null);
        for (args, 0..) |arg, index| argv[index] = (try owned.dupeSentinel(u8, arg, 0)).ptr;
        const environment = try environ.createPosixBlock(owned, .{});
        const executable_z = if (std.mem.eql(u8, executable, args[0]))
            std.mem.span(argv[0].?)
        else
            try owned.dupeSentinel(u8, executable, 0);
        return .{
            .arena = arena,
            .executable = executable_z,
            .argv = argv,
            .environ = environment.slice,
        };
    }

    fn deinit(self: *PosixCommand) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn spawnDarwin(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    executable: []const u8,
    args: []const []const u8,
    actions: ?*const std.c.posix_spawn_file_actions_t,
    attributes: ?*const std.c.posix_spawnattr_t,
    resolution: ExecutableResolution,
) !std.c.pid_t {
    if (builtin.os.tag != .macos) @compileError("Darwin spawn requires macOS");
    var command = try PosixCommand.init(allocator, environ, executable, args);
    defer command.deinit();
    var pid: std.c.pid_t = undefined;
    const result = switch (resolution) {
        .direct => std.c.posix_spawn(
            &pid,
            command.executable,
            actions,
            attributes,
            command.argv.ptr,
            command.environ.ptr,
        ),
        .search_path => std.c.posix_spawnp(
            &pid,
            command.executable,
            actions,
            attributes,
            command.argv.ptr,
            command.environ.ptr,
        ),
    };
    if (result != 0) return posixSpawnError(result);
    return pid;
}

pub fn waitPosix(pid: std.c.pid_t) !u8 {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) { // tiger: event-loop -- the owned child determines termination.
        switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
            .SUCCESS => return statusToExitCode(@bitCast(status)),
            .INTR => continue,
            .CHILD => return error.NoChildProcess,
            else => return error.WaitFailed,
        }
    }
}

pub fn termToExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |signal| signalToExitCode(@backingInt(signal)),
        .stopped, .unknown => 1,
    };
}

pub fn statusToExitCode(status: u32) u8 {
    if (std.posix.W.IFEXITED(status)) return std.posix.W.EXITSTATUS(status);
    if (std.posix.W.IFSIGNALED(status)) {
        return signalToExitCode(@backingInt(std.posix.W.TERMSIG(status)));
    }
    return 1;
}

fn signalToExitCode(signal: u32) u8 {
    return @intCast(@min(@as(u32, 128) + signal, @as(u32, 255)));
}

fn posixSpawnError(rc: c_int) anyerror {
    const err: std.c.E = @fromBackingInt(@intCast(@as(u16, @intCast(rc))));
    return switch (err) {
        .NOMEM, .@"2BIG" => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOEXEC => error.InvalidExe,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        else => error.SpawnFailed,
    };
}

test "POSIX command owns argument and environment storage through all allocation failures" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("CORE_PROCESS_TEST", "owned");
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        inspectPosixCommand,
        .{&environ},
    );
    try @import("test_support").checkAllAllocationFailures(
        std.testing.allocator,
        inspectPosixCommandGrowth,
        .{&environ},
    );
}

fn inspectPosixCommand(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !void {
    var command = try PosixCommand.init(allocator, environ, "/bin/sh", &.{ "sh", "", "a b" });
    defer command.deinit();
    try std.testing.expectEqualStrings("/bin/sh", command.executable);
    try std.testing.expectEqual(@as(usize, 3), command.argv.len);
    try std.testing.expectEqualStrings("sh", std.mem.span(command.argv[0].?));
    try std.testing.expectEqualStrings("", std.mem.span(command.argv[1].?));
    try std.testing.expectEqualStrings("a b", std.mem.span(command.argv[2].?));
    try std.testing.expect(command.argv[command.argv.len] == null);
    try std.testing.expectEqual(@as(usize, 1), command.environ.len);
    try std.testing.expectEqualStrings(
        "CORE_PROCESS_TEST=owned",
        std.mem.span(command.environ[0].?),
    );
    try std.testing.expect(command.environ[command.environ.len] == null);
}

fn inspectPosixCommandGrowth(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !void {
    const argument: [512]u8 = @splat('a');
    const args: [32][]const u8 = @splat(&argument);
    const executable: [9216]u8 = @splat('x');
    var command = try PosixCommand.init(allocator, environ, &executable, &args);
    defer command.deinit();
    try std.testing.expectEqualStrings(&executable, command.executable);
    for (command.argv) |arg| try std.testing.expectEqualStrings(&argument, std.mem.span(arg.?));
}

test "POSIX spawn preserves arguments environment exit and signal status" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("CORE_PROCESS_TEST", "owned");
    const pid = try spawnDarwin(std.testing.allocator, &environ, "/bin/sh", &.{
        "sh",     "-c",
        "test \"$CORE_PROCESS_TEST\" = owned && " ++
            "test \"$1\" = 'argument with spaces' && exit 7; exit 23",
        "marker", "argument with spaces",
    }, null, null, .direct);
    try std.testing.expectEqual(@as(u8, 7), try waitPosix(pid));
    const signaled = try spawnDarwin(std.testing.allocator, &environ, "/bin/sh", &.{
        "sh", "-c", "kill -TERM $$",
    }, null, null, .direct);
    try std.testing.expectEqual(@as(u8, 143), try waitPosix(signaled));
}

test "POSIX spawn keeps direct and PATH lookup distinct and reports missing executables" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    const pid = try spawnDarwin(std.testing.allocator, &environ, "sh", &.{
        "sh", "-c", "exit 9",
    }, null, null, .search_path);
    try std.testing.expectEqual(@as(u8, 9), try waitPosix(pid));
    try std.testing.expectError(error.FileNotFound, spawnDarwin(
        std.testing.allocator,
        &environ,
        "/__skills_zig_missing_executable__",
        &.{"missing"},
        null,
        null,
        .direct,
    ));
    try std.testing.expectError(error.FileNotFound, spawnDarwin(
        std.testing.allocator,
        &environ,
        "/bin/sh",
        &.{},
        null,
        null,
        .direct,
    ));
}

test "child termination and spawn errors keep their public categories" {
    try std.testing.expectEqual(@as(u8, 23), termToExitCode(.{ .exited = 23 }));
    try std.testing.expectEqual(@as(u8, 143), termToExitCode(.{ .signal = .TERM }));
    try std.testing.expectEqual(@as(u8, 1), termToExitCode(.{ .unknown = 0 }));
    try std.testing.expectEqual(@as(u8, 255), signalToExitCode(127));
    try std.testing.expectEqual(error.AccessDenied, posixSpawnError(@backingInt(std.c.E.ACCES)));
    try std.testing.expectEqual(error.InvalidExe, posixSpawnError(@backingInt(std.c.E.NOEXEC)));
    try std.testing.expectEqual(error.SystemResources, posixSpawnError(@backingInt(std.c.E.NOMEM)));
}
