const cas = @import("cas_proxy_client.zig");
const core_json = @import("core_json");
const std = @import("std");

pub const Command = enum {
    resolve,
    get,
    set,
    clear,
    status,
    wait,

    pub fn parse(raw: []const u8) ?Command {
        if (std.mem.eql(u8, raw, "resolve")) return .resolve;
        if (std.mem.eql(u8, raw, "get")) return .get;
        if (std.mem.eql(u8, raw, "set")) return .set;
        if (std.mem.eql(u8, raw, "clear")) return .clear;
        if (std.mem.eql(u8, raw, "status")) return .status;
        if (std.mem.eql(u8, raw, "wait")) return .wait;
        return null;
    }

    pub fn text(self: Command) []const u8 {
        return switch (self) {
            .resolve => "resolve",
            .get => "get",
            .set => "set",
            .clear => "clear",
            .status => "status",
            .wait => "wait",
        };
    }
};

pub const TokenBudget = union(enum) {
    omitted,
    null,
    value: u64,

    pub fn isSet(self: TokenBudget) bool {
        return self != .omitted;
    }
};

pub const ParsedArgs = struct {
    command: Command,
    cwd: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    latest: bool = false,
    objective: ?[]const u8 = null,
    status: ?[]const u8 = null,
    token_budget: TokenBudget = .omitted,
    timeout_ms: u32 = 600_000,
    poll_ms: u32 = 1_000,
    dry_run: bool = false,
    json: bool = false,
    show_help: bool = false,
    show_version: bool = false,
    hook_policy: cas.hooks.HookPolicy = .inherit,
    server_request_timeout_ms: ?u32 = null,
    codex_path: []const u8 = "codex",
    read_only: bool = false,
};

pub const SelectedTarget = struct {
    thread_id: ?[]const u8,
    selected_by: []const u8,
    created_thread: bool = false,
    would_create_thread: bool = false,
    updated_at: ?i64 = null,
};

pub const GoalEnvelope = struct {
    goal_json: []u8,
    status: ?[]u8,
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    if (argv.len < 2) return error.MissingCommand;
    const command = Command.parse(argv[1]) orelse return error.UnknownCommand;
    var out = ParsedArgs{ .command = command };
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help")) {
            out.show_help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "version")) {
            out.show_version = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--latest")) {
            out.latest = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            out.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            out.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--read-only")) {
            out.read_only = true;
            continue;
        }

        const value = argvValue(argv, &i) orelse return error.MissingValue;
        if (std.mem.eql(u8, arg, "--cwd")) {
            out.cwd = value;
        } else if (std.mem.eql(u8, arg, "--thread-id")) {
            out.thread_id = value;
        } else if (std.mem.eql(u8, arg, "--objective")) {
            out.objective = value;
        } else if (std.mem.eql(u8, arg, "--status")) {
            if (!isValidStatus(value)) return error.InvalidStatus;
            out.status = value;
        } else if (std.mem.eql(u8, arg, "--token-budget")) {
            out.token_budget = try parseTokenBudget(value);
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            out.timeout_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--poll-ms")) {
            out.poll_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--hooks")) {
            out.hook_policy = cas.hooks.HookPolicy.parse(value) orelse return error.InvalidHooksPolicy;
        } else if (std.mem.eql(u8, arg, "--server-request-timeout-ms")) {
            out.server_request_timeout_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--codex-path")) {
            out.codex_path = value;
        } else {
            _ = allocator;
            return error.UnknownArg;
        }
    }
    return out;
}

pub fn validateArgs(opts: ParsedArgs) !void {
    if (opts.thread_id != null and opts.latest) return error.DuplicateTargetSelector;
    switch (opts.command) {
        .resolve, .get, .clear, .status, .wait => {
            if (opts.thread_id == null and !opts.latest) return error.MissingTargetSelector;
        },
        .set => {
            if (opts.objective == null and opts.status == null and !opts.token_budget.isSet()) return error.MissingGoalMutation;
            if (opts.objective == null and opts.thread_id == null and !opts.latest) return error.MissingObjectiveForCreate;
        },
    }
    if (opts.command == .status and opts.status == null and !opts.token_budget.isSet()) return error.MissingStatusMutation;
    if (opts.poll_ms == 0) return error.InvalidPollInterval;
}

pub fn parseLatestThreadTarget(allocator: std.mem.Allocator, result_json: []const u8) !SelectedTarget {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidThreadList,
    };
    const data_val = root_obj.get("data") orelse return error.InvalidThreadList;
    const rows = switch (data_val) {
        .array => |arr| arr,
        else => return error.InvalidThreadList,
    };

    var first_id: ?[]const u8 = null;
    var first_updated_at: ?i64 = null;
    var second_same_timestamp = false;

    for (rows.items) |row| {
        const thread_obj = switch (row) {
            .object => |obj| obj,
            else => continue,
        };
        if (boolField(thread_obj, "ephemeral") orelse false) continue;
        const id = core_json.stringField(thread_obj, "id") orelse continue;
        const updated_at = core_json.intField(thread_obj, "updatedAt") orelse core_json.intField(thread_obj, "updated_at");
        if (first_id == null) {
            first_id = id;
            first_updated_at = updated_at;
            continue;
        }
        if ((first_updated_at == null and updated_at == null) or
            (first_updated_at != null and updated_at != null and first_updated_at.? == updated_at.?))
        {
            second_same_timestamp = true;
        }
        break;
    }

    if (first_id == null) return .{
        .thread_id = null,
        .selected_by = "latest",
    };
    if (second_same_timestamp) return error.AmbiguousTarget;
    return .{
        .thread_id = try allocator.dupe(u8, first_id.?),
        .selected_by = "latest",
        .updated_at = first_updated_at,
    };
}

pub fn buildThreadListParamsJson(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const quoted_cwd = try jsonStringAlloc(allocator, cwd);
    defer allocator.free(quoted_cwd);
    return std.fmt.allocPrint(
        allocator,
        "{{\"cursor\":null,\"limit\":20,\"sortKey\":\"updated_at\",\"sortDirection\":\"desc\",\"archived\":false,\"cwd\":{s}}}",
        .{quoted_cwd},
    );
}

pub fn buildThreadIdParamsJson(allocator: std.mem.Allocator, thread_id: []const u8) ![]u8 {
    const quoted_thread_id = try jsonStringAlloc(allocator, thread_id);
    defer allocator.free(quoted_thread_id);
    return std.fmt.allocPrint(allocator, "{{\"threadId\":{s}}}", .{quoted_thread_id});
}

pub fn buildGoalSetParamsJson(allocator: std.mem.Allocator, thread_id: []const u8, opts: ParsedArgs) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    const quoted_thread_id = try jsonStringAlloc(allocator, thread_id);
    defer allocator.free(quoted_thread_id);
    try writer.print("{{\"threadId\":{s}", .{quoted_thread_id});
    if (opts.objective) |objective| {
        const quoted = try jsonStringAlloc(allocator, objective);
        defer allocator.free(quoted);
        try writer.print(",\"objective\":{s}", .{quoted});
    }
    if (opts.status) |status| {
        const quoted = try jsonStringAlloc(allocator, status);
        defer allocator.free(quoted);
        try writer.print(",\"status\":{s}", .{quoted});
    }
    switch (opts.token_budget) {
        .omitted => {},
        .null => try writer.writeAll(",\"tokenBudget\":null"),
        .value => |value| try writer.print(",\"tokenBudget\":{d}", .{value}),
    }
    try writer.writeAll("}");
    return out.toOwnedSlice();
}

pub fn parseGoalEnvelope(allocator: std.mem.Allocator, result_json: []const u8) !GoalEnvelope {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidGoalResponse,
    };
    const goal_val = root_obj.get("goal") orelse return .{
        .goal_json = try allocator.dupe(u8, "null"),
        .status = null,
    };
    const goal_json = try core_json.stringifyAlloc(allocator, goal_val);
    const status = switch (goal_val) {
        .object => |obj| if (core_json.stringField(obj, "status")) |raw| try allocator.dupe(u8, raw) else null,
        else => null,
    };
    return .{
        .goal_json = goal_json,
        .status = status,
    };
}

pub fn extractStartedThreadIdAlloc(allocator: std.mem.Allocator, raw_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.MissingThread,
    };
    const thread_obj = core_json.objectField(root_obj, "thread") orelse return error.MissingThread;
    const id = core_json.stringField(thread_obj, "id") orelse return error.MissingThreadId;
    return allocator.dupe(u8, id);
}

pub fn parseCleared(allocator: std.mem.Allocator, raw: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return false,
    };
    return boolField(root_obj, "cleared") orelse false;
}

pub fn jsonStringAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(text, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn freeTarget(allocator: std.mem.Allocator, target: SelectedTarget) void {
    if (target.thread_id) |thread_id| allocator.free(thread_id);
}

pub fn freeGoalEnvelope(allocator: std.mem.Allocator, goal: GoalEnvelope) void {
    allocator.free(goal.goal_json);
    if (goal.status) |status| allocator.free(status);
}

fn argvValue(argv: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= argv.len) return null;
    i.* += 1;
    return argv[i.*];
}

fn parseTokenBudget(raw: []const u8) !TokenBudget {
    if (std.mem.eql(u8, raw, "null") or std.mem.eql(u8, raw, "none")) return .null;
    return .{ .value = try std.fmt.parseInt(u64, raw, 10) };
}

fn isValidStatus(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "active") or
        std.mem.eql(u8, raw, "paused") or
        std.mem.eql(u8, raw, "blocked") or
        std.mem.eql(u8, raw, "usageLimited") or
        std.mem.eql(u8, raw, "budgetLimited") or
        std.mem.eql(u8, raw, "complete");
}

fn boolField(obj: core_json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

test "parseArgs accepts set with objective and default creation" {
    const argv = [_][]const u8{ "cas_goal", "set", "--cwd", "/repo", "--objective", "finish", "--json" };
    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Command.set, parsed.command);
    try std.testing.expectEqualStrings("/repo", parsed.cwd.?);
    try std.testing.expectEqualStrings("finish", parsed.objective.?);
    try std.testing.expect(parsed.json);
    try validateArgs(parsed);
}

test "parseArgs rejects invalid status" {
    const argv = [_][]const u8{ "cas_goal", "status", "--cwd", "/repo", "--thread-id", "thr_1", "--status", "done" };
    try std.testing.expectError(error.InvalidStatus, parseArgs(std.testing.allocator, &argv));
}

test "validateArgs requires target selectors for mutating non-create commands" {
    const argv = [_][]const u8{ "cas_goal", "clear", "--cwd", "/repo" };
    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectError(error.MissingTargetSelector, validateArgs(parsed));
}

test "buildGoalSetParamsJson includes nullable token budget" {
    const argv = [_][]const u8{ "cas_goal", "set", "--cwd", "/repo", "--thread-id", "thr_1", "--objective", "finish", "--token-budget", "null", "--status", "active" };
    const parsed = try parseArgs(std.testing.allocator, &argv);
    const json = try buildGoalSetParamsJson(std.testing.allocator, "thr_1", parsed);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"threadId\":\"thr_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"objective\":\"finish\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tokenBudget\":null") != null);
}

test "parseLatestThreadTarget skips ephemeral and rejects same-timestamp ambiguity" {
    const ok_json =
        \\{"data":[{"id":"thr_e","ephemeral":true,"updatedAt":10},{"id":"thr_1","ephemeral":false,"updatedAt":9},{"id":"thr_2","ephemeral":false,"updatedAt":8}]}
    ;
    const target = try parseLatestThreadTarget(std.testing.allocator, ok_json);
    defer freeTarget(std.testing.allocator, target);
    try std.testing.expectEqualStrings("thr_1", target.thread_id.?);
    try std.testing.expectEqualStrings("latest", target.selected_by);

    const ambiguous_json =
        \\{"data":[{"id":"thr_1","ephemeral":false,"updatedAt":9},{"id":"thr_2","ephemeral":false,"updatedAt":9}]}
    ;
    try std.testing.expectError(error.AmbiguousTarget, parseLatestThreadTarget(std.testing.allocator, ambiguous_json));

    const missing_timestamp_json =
        \\{"data":[{"id":"thr_1","ephemeral":false},{"id":"thr_2","ephemeral":false}]}
    ;
    try std.testing.expectError(error.AmbiguousTarget, parseLatestThreadTarget(std.testing.allocator, missing_timestamp_json));
}

test "parseGoalEnvelope extracts status and preserves goal json" {
    const raw =
        \\{"goal":{"threadId":"thr_1","objective":"finish","status":"blocked"}}
    ;
    const goal = try parseGoalEnvelope(std.testing.allocator, raw);
    defer freeGoalEnvelope(std.testing.allocator, goal);
    try std.testing.expectEqualStrings("blocked", goal.status.?);
    try std.testing.expect(std.mem.indexOf(u8, goal.goal_json, "\"objective\":\"finish\"") != null);
}
