const core_json = @import("core_json");
const std = @import("std");
const app_server_launch = @import("transport.zig");

pub const HookPolicy = enum {
    inherit,
    off,
    require_observed,

    pub fn parse(raw: []const u8) ?HookPolicy {
        if (std.mem.eql(u8, raw, "inherit")) return .inherit;
        if (std.mem.eql(u8, raw, "off")) return .off;
        if (std.mem.eql(u8, raw, "require-observed") or
            std.mem.eql(u8, raw, "require_observed")) return .require_observed;
        return null;
    }

    pub fn asString(self: HookPolicy) []const u8 {
        return switch (self) {
            .inherit => "inherit",
            .off => "off",
            .require_observed => "require-observed",
        };
    }

    pub fn shouldCaptureNotifications(self: HookPolicy) bool {
        return self != .inherit;
    }
};

pub const FailureCode = enum {
    hooks_unsupported,
    hook_blocked,
    hook_failed,
    hook_stopped,
    hook_not_observed,

    pub fn asString(self: FailureCode) []const u8 {
        return switch (self) {
            .hooks_unsupported => "hooks_unsupported",
            .hook_blocked => "hook_blocked",
            .hook_failed => "hook_failed",
            .hook_stopped => "hook_stopped",
            .hook_not_observed => "hook_not_observed",
        };
    }
};

pub const HookSummary = struct {
    policy: []const u8,
    observed: bool,
    started: usize,
    completed: usize,
    blocked: usize,
    failed: usize,
    stopped: usize,
    failureCode: ?[]const u8 = null,
    hookLogPath: ?[]const u8 = null,
};

pub fn unsupportedSummary(policy: HookPolicy, hook_log_path: ?[]const u8) HookSummary {
    return .{
        .policy = policy.asString(),
        .observed = false,
        .started = 0,
        .completed = 0,
        .blocked = 0,
        .failed = 0,
        .stopped = 0,
        .failureCode = FailureCode.hooks_unsupported.asString(),
        .hookLogPath = hook_log_path,
    };
}

pub const HookAccumulator = struct {
    pub const Log = struct {
        io: std.Io,
        path: []const u8,
    };

    policy: HookPolicy,
    started: usize = 0,
    completed: usize = 0,
    blocked: usize = 0,
    failed: usize = 0,
    stopped: usize = 0,
    hook_log: ?Log = null,

    pub fn init(policy: HookPolicy, hook_log: ?Log) HookAccumulator {
        return .{
            .policy = policy,
            .hook_log = hook_log,
        };
    }

    pub fn absorbLine(
        self: *HookAccumulator,
        allocator: std.mem.Allocator,
        line: []const u8,
    ) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            return;
        };
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return,
        };
        const method = core_json.stringField(root, "method") orelse return;
        if (!isHookNotificationMethod(method)) return;

        var successor = self.*;
        if (std.mem.eql(u8, method, "hook/started")) {
            successor.started = try std.math.add(usize, self.started, 1);
        } else if (std.mem.eql(u8, method, "hook/completed")) {
            successor.completed = try std.math.add(usize, self.completed, 1);
        }
        if (core_json.objectField(root, "params")) |params| {
            if (core_json.objectField(params, "run")) |run| {
                if (core_json.stringField(run, "status")) |status| {
                    try successor.absorbStatus(status);
                }
            }
        }
        if (self.hook_log) |log| try appendRawHookLine(log, line);
        self.* = successor;
    }

    pub fn absorbLines(
        self: *HookAccumulator,
        allocator: std.mem.Allocator,
        lines: []const []u8,
    ) !void {
        for (lines) |line| try self.absorbLine(allocator, line);
    }

    pub fn summary(self: HookAccumulator) HookSummary {
        const failure = self.failureCode();
        return .{
            .policy = self.policy.asString(),
            .observed = self.observed(),
            .started = self.started,
            .completed = self.completed,
            .blocked = self.blocked,
            .failed = self.failed,
            .stopped = self.stopped,
            .failureCode = if (failure) |code| code.asString() else null,
            .hookLogPath = if (self.hook_log) |log| log.path else null,
        };
    }

    pub fn failureCode(self: HookAccumulator) ?FailureCode {
        if (self.blocked > 0) return .hook_blocked;
        if (self.failed > 0) return .hook_failed;
        if (self.stopped > 0) return .hook_stopped;
        if (self.policy == .require_observed and !self.observed()) return .hook_not_observed;
        return null;
    }

    pub fn ok(self: HookAccumulator) bool {
        return self.failureCode() == null;
    }

    fn observed(self: HookAccumulator) bool {
        return self.started > 0 or self.completed > 0;
    }

    fn absorbStatus(self: *HookAccumulator, status: []const u8) !void {
        if (std.mem.eql(u8, status, "blocked")) {
            self.blocked = try std.math.add(usize, self.blocked, 1);
        } else if (std.mem.eql(u8, status, "failed")) {
            self.failed = try std.math.add(usize, self.failed, 1);
        } else if (std.mem.eql(u8, status, "stopped")) {
            self.stopped = try std.math.add(usize, self.stopped, 1);
        }
    }
};

pub fn isHookNotificationLine(allocator: std.mem.Allocator, line: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return false,
    };
    const method = core_json.stringField(root, "method") orelse return false;
    return isHookNotificationMethod(method);
}

pub fn appendAppServerArgs(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    policy: HookPolicy,
    listen_url: ?[]const u8,
    code_mode_host: ?*const app_server_launch.CodeModeHost,
) !void {
    try app_server_launch.appendAppServerArgs(
        allocator,
        argv,
        policy == .off,
        listen_url,
        code_mode_host,
    );
}

pub fn ensureLaunchSupportsPolicy(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_path: []const u8,
    cwd: []const u8,
    policy: HookPolicy,
) !void {
    const deadline_ms = @as(i64, @intCast(@divFloor(
        std.Io.Clock.awake.now(io).nanoseconds,
        1_000_000,
    ))) + app_server_launch.default_startup_timeout_ms;
    return ensureLaunchSupportsPolicyUntil(allocator, io, codex_path, cwd, policy, deadline_ms);
}

pub fn ensureLaunchSupportsPolicyUntil(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_path: []const u8,
    cwd: []const u8,
    policy: HookPolicy,
    deadline_ms: i64,
) !void {
    if (policy == .inherit) return;
    const deadline: std.Io.Clock.Timestamp = .{
        .raw = .fromNanoseconds(@as(i96, deadline_ms) * 1_000_000),
        .clock = .awake,
    };
    const help = try helpOutputUntil(allocator, io, codex_path, cwd, deadline);
    defer allocator.free(help);
    if (std.mem.indexOf(u8, help, "--disable") == null) return error.HooksUnsupported;
    if (policy == .require_observed and
        std.mem.indexOf(u8, help, "generate-json-schema") == null)
        return error.HooksUnsupported;
}

const HelpProbeEvent = union(enum) {
    completed: anyerror!void,
    timeout: std.Io.Cancelable!void,
};

fn helpOutputUntil(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_path: []const u8,
    cwd: []const u8,
    deadline: std.Io.Clock.Timestamp,
) ![]u8 {
    if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.ConnectionTimedOut;
    const builtin = @import("builtin");
    var child = try std.process.spawn(io, .{
        .argv = &.{ codex_path, "app-server", "--help" },
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    });
    const process_group_id: ?u64 = switch (builtin.os.tag) {
        .windows, .wasi => null,
        else => @intCast(child.id.?),
    };
    defer @import("websocket.zig").retireProcessChild(io, &child, process_group_id);
    var output: ?[]u8 = null;
    defer if (output) |bytes| allocator.free(bytes);
    var events: [2]HelpProbeEvent = undefined;
    var select = std.Io.Select(HelpProbeEvent).init(io, &events);
    // Both jobs return only status; output stays owned here until both have joined.
    defer select.cancelDiscard();
    try select.concurrent(.timeout, std.Io.Clock.Timestamp.wait, .{ deadline, io });
    try select.concurrent(.completed, collectHelpOutput, .{ allocator, io, &child, &output });
    switch (try select.await()) {
        .completed => |result| try result,
        .timeout => |result| {
            try result;
            return error.ConnectionTimedOut;
        },
    }
    const bytes = output.?;
    output = null;
    return bytes;
}

fn collectHelpOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    output: *?[]u8,
) !void {
    var buffers: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(allocator, io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const stdout = reader.reader(0);
    const stderr = reader.reader(1);
    // Each fill grows buffered bytes or reaches EOF; the owner cancels at its deadline.
    while (reader.fill(64, .none)) |_| {
        if (stdout.buffered().len > 256 * 1024 or stderr.buffered().len > 64 * 1024) {
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.HooksUnsupported;
    output.* = try reader.toOwnedSlice(0);
}

pub fn defaultHookLogPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    prefix: []const u8,
) ![]u8 {
    const now_ns = std.Io.Clock.real.now(io).nanoseconds;
    return std.fmt.allocPrint(allocator, "/tmp/{s}-hooks-{d}.ndjson", .{ prefix, now_ns });
}

fn isHookNotificationMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "hook/started") or std.mem.eql(u8, method, "hook/completed");
}

fn appendRawHookLine(log: HookAccumulator.Log, line: []const u8) !void {
    var file = std.Io.Dir.openFileAbsolute(log.io, log.path, .{
        .mode = .write_only,
    }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.createFileAbsolute(log.io, log.path, .{
            .truncate = false,
        }),
        else => return err,
    };
    defer file.close(log.io);
    const end_pos = (try file.stat(log.io)).size;
    var writer = file.writer(log.io, &.{});
    try writer.seekTo(end_pos);
    try writer.interface.writeAll(line);
    try writer.interface.writeAll("\n");
}

test "HookPolicy parses accepted values" {
    try std.testing.expectEqual(HookPolicy.inherit, HookPolicy.parse("inherit").?);
    try std.testing.expectEqual(HookPolicy.off, HookPolicy.parse("off").?);
    try std.testing.expectEqual(
        HookPolicy.require_observed,
        HookPolicy.parse("require-observed").?,
    );
    try std.testing.expect(HookPolicy.parse("required") == null);
}

test "help policy probe times out and retires its process group" {
    try exerciseHangingHelp(false);
}

test "help policy deadline includes waiting after both output pipes close" {
    try exerciseHangingHelp(true);
}

fn exerciseHangingHelp(close_output: bool) !void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "codex" });
    defer allocator.free(executable);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nsleep 600 &\nprintf '%s %s\\n' \"$$\" \"$!\" > '{s}/pid'\n{s}wait\n",
        .{ root, if (close_output) "exec 1>&- 2>&-\n" else "" },
    );
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = script });
    try tmp.dir.setFilePermissions(io, "codex", .fromMode(0o755), .{});
    const started_ms: i64 = @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000));
    try std.testing.expectError(error.ConnectionTimedOut, ensureLaunchSupportsPolicyUntil(
        allocator,
        io,
        executable,
        root,
        .off,
        started_ms + 100,
    ));
    const finished_ms = @divFloor(std.Io.Clock.awake.now(io).nanoseconds, 1_000_000);
    try std.testing.expect(finished_ms - started_ms < 2_000);
    const pids = try tmp.dir.readFileAlloc(io, "pid", allocator, .limited(64));
    defer allocator.free(pids);
    var fields = std.mem.tokenizeAny(u8, pids, " \t\r\n");
    var count: usize = 0;
    while (fields.next()) |field| {
        const pid = try std.fmt.parseInt(u64, field, 10);
        try std.testing.expect(!@import("websocket.zig").processAlive(pid));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "help policy probe preserves supported and unsupported launch admission" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const executable = try std.fs.path.join(allocator, &.{ root, "codex" });
    defer allocator.free(executable);
    try tmp.dir.writeFile(io, .{
        .sub_path = "codex",
        .data = "#!/bin/sh\nprintf '%s\\n' '--disable generate-json-schema'\n",
    });
    try tmp.dir.setFilePermissions(io, "codex", .fromMode(0o755), .{});
    try ensureLaunchSupportsPolicy(allocator, io, executable, root, .off);
    try ensureLaunchSupportsPolicy(allocator, io, executable, root, .require_observed);
    try tmp.dir.writeFile(io, .{ .sub_path = "codex", .data = "#!/bin/sh\nexit 0\n" });
    try std.testing.expectError(error.HooksUnsupported, ensureLaunchSupportsPolicy(
        allocator,
        io,
        executable,
        root,
        .off,
    ));
}

test "appendAppServerArgs disables hooks only for off policy" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    var code_mode_host = try app_server_launch.CodeModeHost.init(
        std.testing.allocator,
        "https://example.com:443/",
    );
    defer code_mode_host.deinit();
    try appendAppServerArgs(
        std.testing.allocator,
        &argv,
        .off,
        "ws://127.0.0.1:1",
        &code_mode_host,
    );
    try std.testing.expectEqual(@as(usize, 7), argv.items.len);
    try std.testing.expectEqualStrings("app-server", argv.items[0]);
    try std.testing.expectEqualStrings("--disable", argv.items[1]);
    try std.testing.expectEqualStrings("codex_hooks", argv.items[2]);
    try std.testing.expectEqualStrings("--listen", argv.items[3]);
    try std.testing.expectEqualStrings("--code-mode-host", argv.items[5]);
    try std.testing.expectEqualStrings(code_mode_host.raw, argv.items[6]);

    for ([_][]const u8{
        "https://example.com:invalid/",
        "https://example.com:/",
        "https://::1/",
    }) |invalid| {
        try std.testing.expectError(
            error.InvalidCodeModeHost,
            app_server_launch.CodeModeHost.init(std.testing.allocator, invalid),
        );
    }
}

test "HookAccumulator summarizes failure precedence" {
    var acc = HookAccumulator.init(.require_observed, null);
    try acc.absorbLine(
        std.testing.allocator,
        "{\"method\":\"hook/completed\",\"params\":{\"run\":{\"status\":\"failed\"}}}",
    );
    try acc.absorbLine(
        std.testing.allocator,
        "{\"method\":\"hook/completed\",\"params\":{\"run\":{\"status\":\"blocked\"}}}",
    );
    const summary_value = acc.summary();
    try std.testing.expect(summary_value.observed);
    try std.testing.expectEqual(@as(usize, 2), summary_value.completed);
    try std.testing.expectEqualStrings("hook_blocked", summary_value.failureCode.?);
}

test "HookAccumulator require-observed fails closed when no hook notifications arrive" {
    const acc = HookAccumulator.init(.require_observed, null);
    const summary_value = acc.summary();
    try std.testing.expect(!summary_value.observed);
    try std.testing.expectEqualStrings("hook_not_observed", summary_value.failureCode.?);
}

test "hook parsing propagates allocation failure without changing counters" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseHookAllocations,
        .{},
    );
}

fn exerciseHookAllocations(allocator: std.mem.Allocator) !void {
    const notification =
        "{\"method\":\"hook/completed\",\"params\":{\"run\":{\"status\":\"failed\"}}}";
    var accumulator = HookAccumulator.init(.require_observed, null);
    accumulator.absorbLine(allocator, notification) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), accumulator.completed);
        try std.testing.expectEqual(@as(usize, 0), accumulator.failed);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), accumulator.completed);
    try std.testing.expectEqual(@as(usize, 1), accumulator.failed);
    try std.testing.expect(try isHookNotificationLine(allocator, notification));
    try std.testing.expect(!try isHookNotificationLine(allocator, "not-json"));
}

test "hook overflow is rejected before logging or counter mutation" {
    const allocator = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const root_path = try directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);
    const log_path = try std.fs.path.join(allocator, &.{ root_path, "hooks.jsonl" });
    defer allocator.free(log_path);
    var accumulator = HookAccumulator.init(.require_observed, .{
        .io = std.testing.io,
        .path = log_path,
    });
    accumulator.failed = std.math.maxInt(usize);
    try std.testing.expectError(error.Overflow, accumulator.absorbLine(
        allocator,
        "{\"method\":\"hook/completed\",\"params\":{\"run\":{\"status\":\"failed\"}}}",
    ));
    try std.testing.expectEqual(@as(usize, 0), accumulator.completed);
    try std.testing.expectEqual(std.math.maxInt(usize), accumulator.failed);
    try std.testing.expectError(
        error.FileNotFound,
        directory.dir.statFile(std.testing.io, "hooks.jsonl", .{}),
    );
}

test "hook log uses the supplied I/O and preserves raw line order" {
    const allocator = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const root_path = try directory.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);
    const log_path = try std.fs.path.join(allocator, &.{ root_path, "hooks.jsonl" });
    defer allocator.free(log_path);
    var accumulator = HookAccumulator.init(.require_observed, .{
        .io = std.testing.io,
        .path = log_path,
    });
    const first = "{\"method\":\"hook/started\"}";
    const second = "{\"method\":\"hook/completed\"}";
    try accumulator.absorbLine(allocator, first);
    try accumulator.absorbLine(allocator, second);
    const bytes = try directory.dir.readFileAlloc(
        std.testing.io,
        "hooks.jsonl",
        allocator,
        .limited(4096),
    );
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(first ++ "\n" ++ second ++ "\n", bytes);
    try std.testing.expectEqual(@as(usize, 1), accumulator.started);
    try std.testing.expectEqual(@as(usize, 1), accumulator.completed);
}
