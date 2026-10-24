const std = @import("std");

const max_stat_bytes = 4096;
const max_mount_bytes = 64 * 1024;
const max_process_entries = 65_536;

const ProcessState = struct {
    pid: u64,
    group: u64,
    terminal: bool,
};

pub fn processIsTerminal(io: std.Io, process_id: u64) bool {
    var proc = std.Io.Dir.openDirAbsolute(io, "/proc", .{}) catch return false;
    defer proc.close(io);
    if (!samePidNamespace(io, proc)) return false;
    const state = readProcessState(io, proc, process_id) catch return false;
    return if (state) |value| value.terminal else false;
}

pub fn groupIsTerminal(io: std.Io, group_id: u64) bool {
    var proc = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch
        return false;
    defer proc.close(io);
    if (!samePidNamespace(io, proc)) return false;
    var mounts: [max_mount_bytes]u8 = undefined;
    const data = proc.readFile(io, "mounts", &mounts) catch return false;
    if (data.len == mounts.len or !unrestrictedProcMount(data)) return false;
    return groupIsTerminalIn(io, proc, group_id) catch false;
}

fn samePidNamespace(io: std.Io, proc: std.Io.Dir) bool {
    var buffer: [max_stat_bytes]u8 = undefined;
    const data = proc.readFile(io, "self/stat", &buffer) catch return false;
    if (data.len == buffer.len) return false;
    const state = parseProcessState(data) catch return false;
    return state.pid == @as(u64, @intCast(std.os.linux.getpid()));
}

fn groupIsTerminalIn(io: std.Io, proc: std.Io.Dir, group_id: u64) !bool {
    var iterator = proc.iterate();
    var count: usize = 0;
    var found = false;
    while (try iterator.next(io)) |entry| {
        count += 1;
        if (count > max_process_entries) return error.ProcessInventoryTooLarge;
        const pid = std.fmt.parseInt(u64, entry.name, 10) catch continue;
        const state = (try readProcessState(io, proc, pid)) orelse continue;
        if (state.group != group_id) continue;
        if (!state.terminal) return false;
        found = true;
    }
    return found;
}

fn readProcessState(io: std.Io, proc: std.Io.Dir, process_id: u64) !?ProcessState {
    var path_buffer: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{d}/stat", .{process_id});
    var buffer: [max_stat_bytes]u8 = undefined;
    const data = proc.readFile(io, path, &buffer) catch |err| switch (err) {
        error.FileNotFound => {
            if (processMissing(process_id)) return null;
            return err;
        },
        else => return err,
    };
    if (data.len == buffer.len) return error.ProcessStateTooLarge;
    const state = try parseProcessState(data);
    if (state.pid != process_id) return error.ProcessIdentityMismatch;
    return state;
}

fn processMissing(process_id: u64) bool {
    const pid = std.math.cast(std.posix.pid_t, process_id) orelse return false;
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| {
        return err == error.ProcessNotFound;
    };
    return false;
}

fn parseProcessState(data: []const u8) !ProcessState {
    const open = std.mem.indexOf(u8, data, " (") orelse return error.InvalidProcessState;
    const close = std.mem.lastIndexOf(u8, data, ") ") orelse return error.InvalidProcessState;
    if (close < open + 2) return error.InvalidProcessState;
    const pid = try std.fmt.parseInt(u64, data[0..open], 10);
    var fields = std.mem.tokenizeScalar(u8, data[close + 2 ..], ' ');
    const state = fields.next() orelse return error.InvalidProcessState;
    if (state.len != 1 or std.mem.indexOfScalar(u8, "RSDZTtXxKWPI", state[0]) == null) {
        return error.InvalidProcessState;
    }
    _ = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidProcessState, 10);
    const group = try std.fmt.parseInt(
        u64,
        fields.next() orelse return error.InvalidProcessState,
        10,
    );
    for (0..14) |_| _ = fields.next() orelse return error.InvalidProcessState;
    const threads = try std.fmt.parseInt(
        u64,
        fields.next() orelse return error.InvalidProcessState,
        10,
    );
    return .{
        .pid = pid,
        .group = group,
        .terminal = (state[0] == 'Z' or state[0] == 'X') and threads == 1,
    };
}

fn unrestrictedProcMount(data: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var found = false;
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse return false;
        const mount = fields.next() orelse return false;
        if (!std.mem.eql(u8, mount, "/proc")) continue;
        if (found) return false;
        if (!std.mem.eql(u8, fields.next() orelse return false, "proc")) return false;
        var options = std.mem.tokenizeScalar(u8, fields.next() orelse return false, ',');
        while (options.next()) |option| {
            if (!std.mem.startsWith(u8, option, "hidepid=")) continue;
            const value = option["hidepid=".len..];
            if (!std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "off")) return false;
        }
        found = true;
    }
    return found;
}

test "process state distinguishes zombies from stopped and live tasks" {
    const suffix = " 1 40 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ";
    const zombie = try parseProcessState("42 (name with ) and ( parentheses)) Z" ++ suffix ++ "1");
    try std.testing.expectEqual(@as(u64, 42), zombie.pid);
    try std.testing.expectEqual(@as(u64, 40), zombie.group);
    try std.testing.expect(zombie.terminal);
    try std.testing.expect(!(try parseProcessState("42 (leader) Z" ++ suffix ++ "2")).terminal);
    try std.testing.expect(!(try parseProcessState("42 (task) Z" ++ suffix ++ "0")).terminal);
    for ("RSDTtKWPI") |state| {
        var buffer: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "42 (task) {c}" ++ suffix ++ "1", .{state});
        try std.testing.expect(!(try parseProcessState(text)).terminal);
    }
    try std.testing.expectError(error.InvalidProcessState, parseProcessState("42 task Z 1 40"));
    try std.testing.expectError(error.InvalidProcessState, parseProcessState("42 (task) ? 1 40"));
    try std.testing.expectError(error.InvalidProcessState, parseProcessState("42 (task) Z 1"));
}

test "terminal group requires visible members and rejects live nonleaders" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "41", .default_dir);
    try tmp.dir.createDir(io, "42", .default_dir);
    const suffix = " 1 41 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ";
    try tmp.dir.writeFile(io, .{ .sub_path = "41/stat", .data = "41 (leader) Z" ++ suffix ++ "1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "42/stat", .data = "42 (child) S" ++ suffix ++ "1" });
    try std.testing.expect(!try groupIsTerminalIn(io, tmp.dir, 41));
    try tmp.dir.deleteFile(io, "41/stat");
    try tmp.dir.deleteDir(io, "41");
    try std.testing.expect(!try groupIsTerminalIn(io, tmp.dir, 41));
    try tmp.dir.writeFile(io, .{ .sub_path = "42/stat", .data = "42 (child) Z" ++ suffix ++ "2" });
    try std.testing.expect(!try groupIsTerminalIn(io, tmp.dir, 41));
    try tmp.dir.writeFile(io, .{ .sub_path = "42/stat", .data = "42 (child) Z" ++ suffix ++ "1" });
    try std.testing.expect(try groupIsTerminalIn(io, tmp.dir, 41));
    try std.testing.expect(!try groupIsTerminalIn(io, tmp.dir, 50));
    try tmp.dir.writeFile(io, .{ .sub_path = "42/stat", .data = "not a process state" });
    try std.testing.expectError(error.InvalidProcessState, groupIsTerminalIn(io, tmp.dir, 41));
}

test "restrictive or unknown proc visibility cannot establish group termination" {
    try std.testing.expect(unrestrictedProcMount("proc /proc proc rw,nosuid,nodev,noexec 0 0\n"));
    try std.testing.expect(unrestrictedProcMount("proc /proc proc rw,hidepid=0 0 0\n"));
    for ([_][]const u8{ "1", "2", "4", "invisible", "ptraceable", "unknown" }) |value| {
        var buffer: [128]u8 = undefined;
        const mounts = try std.fmt.bufPrint(
            &buffer,
            "proc /proc proc rw,hidepid={s} 0 0\n",
            .{value},
        );
        try std.testing.expect(!unrestrictedProcMount(mounts));
    }
    try std.testing.expect(!unrestrictedProcMount(""));
    try std.testing.expect(!unrestrictedProcMount("none /proc tmpfs rw 0 0\n"));
    const duplicate = "proc /proc proc rw 0 0\nproc /proc proc rw 0 0\n";
    try std.testing.expect(!unrestrictedProcMount(duplicate));
}
