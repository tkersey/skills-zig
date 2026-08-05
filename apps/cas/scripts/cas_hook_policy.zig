const core_json = @import("core_json");
const std = @import("std");
const app_server_launch = @import("cas_app_server_launch.zig");

pub const HookPolicy = enum {
    inherit,
    off,
    require_observed,

    pub fn parse(raw: []const u8) ?HookPolicy {
        if (std.mem.eql(u8, raw, "inherit")) return .inherit;
        if (std.mem.eql(u8, raw, "off")) return .off;
        if (std.mem.eql(u8, raw, "require-observed") or std.mem.eql(u8, raw, "require_observed")) return .require_observed;
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
    policy: HookPolicy,
    started: usize = 0,
    completed: usize = 0,
    blocked: usize = 0,
    failed: usize = 0,
    stopped: usize = 0,
    hook_log_path: ?[]const u8 = null,

    pub fn init(policy: HookPolicy, hook_log_path: ?[]const u8) HookAccumulator {
        return .{
            .policy = policy,
            .hook_log_path = hook_log_path,
        };
    }

    pub fn absorbLine(self: *HookAccumulator, allocator: std.mem.Allocator, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return,
        };
        const method = core_json.stringField(root, "method") orelse return;
        if (!isHookNotificationMethod(method)) return;

        if (self.hook_log_path) |path| {
            try appendRawHookLine(path, line);
        }

        if (std.mem.eql(u8, method, "hook/started")) {
            self.started += 1;
        } else if (std.mem.eql(u8, method, "hook/completed")) {
            self.completed += 1;
        }

        const params = core_json.objectField(root, "params") orelse return;
        const run = core_json.objectField(params, "run") orelse return;
        const status = core_json.stringField(run, "status") orelse return;
        self.absorbStatus(status);
    }

    pub fn absorbLines(self: *HookAccumulator, allocator: std.mem.Allocator, lines: []const []u8) !void {
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
            .hookLogPath = self.hook_log_path,
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

    fn absorbStatus(self: *HookAccumulator, status: []const u8) void {
        if (std.mem.eql(u8, status, "blocked")) {
            self.blocked += 1;
        } else if (std.mem.eql(u8, status, "failed")) {
            self.failed += 1;
        } else if (std.mem.eql(u8, status, "stopped")) {
            self.stopped += 1;
        }
    }
};

pub fn isHookNotificationLine(allocator: std.mem.Allocator, line: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
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
) !void {
    try app_server_launch.appendAppServerArgs(allocator, argv, policy == .off, listen_url, null);
}

pub fn ensureLaunchSupportsPolicy(
    allocator: std.mem.Allocator,
    io: std.Io,
    codex_path: []const u8,
    cwd: []const u8,
    policy: HookPolicy,
) !void {
    _ = allocator;
    if (policy == .inherit) return;
    const argv = [_][]const u8{ codex_path, "app-server", "--help" };
    const scratch = std.heap.page_allocator;
    const result = try std.process.run(scratch, io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer scratch.free(result.stdout);
    defer scratch.free(result.stderr);

    const exited_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) return error.HooksUnsupported;
    if (std.mem.indexOf(u8, result.stdout, "--disable") == null) return error.HooksUnsupported;
    if (policy == .require_observed and std.mem.indexOf(u8, result.stdout, "generate-json-schema") == null) return error.HooksUnsupported;
}

pub fn defaultHookLogPathAlloc(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const now_ns = std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
    return std.fmt.allocPrint(allocator, "/tmp/{s}-hooks-{d}.ndjson", .{ prefix, now_ns });
}

fn isHookNotificationMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "hook/started") or std.mem.eql(u8, method, "hook/completed");
}

fn appendRawHookLine(path: []const u8, line: []const u8) !void {
    var file = std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.createFileAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{ .truncate = false }),
        else => return err,
    };
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    const end_pos = (try file.stat(std.Io.Threaded.global_single_threaded.io())).size;
    var writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try writer.seekTo(end_pos);
    try writer.interface.writeAll(line);
    try writer.interface.writeAll("\n");
}

test "HookPolicy parses accepted values" {
    try std.testing.expectEqual(HookPolicy.inherit, HookPolicy.parse("inherit").?);
    try std.testing.expectEqual(HookPolicy.off, HookPolicy.parse("off").?);
    try std.testing.expectEqual(HookPolicy.require_observed, HookPolicy.parse("require-observed").?);
    try std.testing.expect(HookPolicy.parse("required") == null);
}

test "appendAppServerArgs disables hooks only for off policy" {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try appendAppServerArgs(std.testing.allocator, &argv, .off, "ws://127.0.0.1:1");
    try std.testing.expectEqual(@as(usize, 5), argv.items.len);
    try std.testing.expectEqualStrings("app-server", argv.items[0]);
    try std.testing.expectEqualStrings("--disable", argv.items[1]);
    try std.testing.expectEqualStrings("codex_hooks", argv.items[2]);
    try std.testing.expectEqualStrings("--listen", argv.items[3]);
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
