//! Private review CLI admission and ownership of expanded command inputs.
const std = @import("std");
const cas = @import("cas_proxy_client");
const core_cli = @import("core_cli");
const review_options = @import("cas_review_options.zig");
const ReviewTarget = @import("cas_review_target.zig").ReviewTarget;

pub const default_control_timeout_ms: u32 = 300_000;
pub const default_review_timeout_ms: u32 = 2_700_000;

pub const Action = enum {
    run,
    start,
    wait,

    fn parse(raw: []const u8) ?Action {
        if (std.mem.eql(u8, raw, "run")) return .run;
        if (std.mem.eql(u8, raw, "start")) return .start;
        if (std.mem.eql(u8, raw, "wait")) return .wait;
        return null;
    }
};

pub const ParentMode = enum {
    auto,
    fresh,
    reuse,

    fn parse(raw: []const u8) ?ParentMode {
        if (std.mem.eql(u8, raw, "auto")) return .auto;
        if (std.mem.eql(u8, raw, "fresh")) return .fresh;
        if (std.mem.eql(u8, raw, "reuse")) return .reuse;
        return null;
    }
};

pub const ParsedArgs = struct {
    executable_path: []const u8 = "cas_review_session",
    action: ?Action = null,
    cwd: ?[]const u8 = null,
    codex_path: ?[]const u8 = null,
    code_mode_host: ?[]const u8 = null,
    parent_thread_id: ?[]const u8 = null,
    parent_mode: ParentMode = .auto,
    multi_agent_mode: ?cas.MultiAgentMode = null,
    review_thread_id: ?[]const u8 = null,
    latest_review_session: bool = false,
    target: ?ReviewTarget = null,
    custom_instructions_arg: ?[]const u8 = null,
    custom_instructions: ?[]const u8 = null,
    thread_start_options: ?review_options.ThreadStartOptions = null,
    workflow_binding_arg: ?[]const u8 = null,
    wait_after_start: bool = false,
    json: bool = false,
    timeout_ms: u32 = default_control_timeout_ms,
    timeout_ms_explicit: bool = false,
    poll_interval_ms: u32 = 250,
    exec_approval: ?[]const u8 = null,
    file_approval: ?[]const u8 = null,
    permissions_approval: ?[]const u8 = null,
    request_user_input_response_json: ?[]const u8 = null,
    elicitation_action: ?[]const u8 = null,
    elicitation_content_json: ?[]const u8 = null,
    dynamic_tool_response_json: ?[]const u8 = null,
    read_only: bool = false,
    hook_policy: cas.hooks.HookPolicy = .inherit,
    review_lock_override_reason: ?[]const u8 = null,
    fresh_attempt_reason: ?[]const u8 = null,
    codex_thread_id: ?[]const u8 = null,
    store_root: ?[]const u8 = null,
    receipt_paths: []const []const u8 = &.{},
    show_help: bool = false,
    show_version: bool = false,

    pub fn deinit(self: ParsedArgs, allocator: std.mem.Allocator) void {
        if (self.custom_instructions) |instructions| allocator.free(instructions);
        if (self.thread_start_options) |options| options.deinit();
        allocator.free(self.receipt_paths);
    }
};

pub fn defaultTimeoutMsForAction(parsed: ParsedArgs) u32 {
    const action = parsed.action orelse return default_control_timeout_ms;
    return switch (action) {
        .run, .wait => default_review_timeout_ms,
        .start => if (parsed.wait_after_start)
            default_review_timeout_ms
        else
            default_control_timeout_ms,
    };
}

pub fn parseArgs(io: std.Io, directory: std.Io.Dir, allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    var out = ParsedArgs{};
    var receipt_paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        receipt_paths.deinit(allocator);
        if (out.custom_instructions) |instructions| allocator.free(instructions);
        if (out.thread_start_options) |options| options.deinit();
        if (out.receipt_paths.len != 0) allocator.free(out.receipt_paths);
    }
    if (argv.len > 0) out.executable_path = argv[0];
    if (argv.len <= 1 or parseReviewIntrospection(&out, argv[1])) return out;
    out.action = Action.parse(argv[1]) orelse return error.UnknownAction;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (try parseReviewFlag(&out, arg)) continue;
        i += 1;
        if (i >= argv.len) return error.MissingValue;
        const value = argv[i];
        if (try parseReviewLocationOption(&out, arg, value)) continue;
        if (try parseReviewTargetOption(&out, arg, value)) continue;
        if (try parseReviewInputOption(io, directory, allocator, &out, arg, value)) continue;
        if (try parseReviewTimingOption(&out, arg, value)) continue;
        if (parseReviewApprovalOption(&out, arg, value)) continue;
        if (try parseReviewStoreOption(&out, arg, value)) continue;
        if (std.mem.eql(u8, arg, "--path")) {
            try receipt_paths.append(allocator, value);
            continue;
        }
        return error.UnknownArg;
    }
    out.receipt_paths = try receipt_paths.toOwnedSlice(allocator);
    // Introspection remains reachable without satisfying operation operands.
    if (out.show_help or out.show_version) return out;
    try validateReviewArgs(out);
    if (!out.timeout_ms_explicit) out.timeout_ms = defaultTimeoutMsForAction(out);
    return out;
}

fn parseReviewIntrospection(out: *ParsedArgs, arg: []const u8) bool {
    if (core_cli.isHelpArg(arg)) {
        out.show_help = true;
        return true;
    }
    if (core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) {
        out.show_version = true;
        return true;
    }
    return false;
}

fn parseReviewFlag(out: *ParsedArgs, arg: []const u8) !bool {
    if (parseReviewIntrospection(out, arg)) return true;
    const flags = .{
        .{ "--json", "json" },
        .{ "--read-only", "read_only" },
        .{ "--latest", "latest_review_session" },
        .{ "--wait", "wait_after_start" },
    };
    inline for (flags) |flag| {
        if (std.mem.eql(u8, arg, flag[0])) {
            @field(out, flag[1]) = true;
            return true;
        }
    }
    if (std.mem.eql(u8, arg, "--uncommitted")) {
        try setTarget(out, .uncommitted);
        return true;
    }
    return false;
}

fn parseReviewLocationOption(out: *ParsedArgs, arg: []const u8, value: []const u8) !bool {
    if (std.mem.eql(u8, arg, "--cwd")) {
        out.cwd = value;
    } else if (std.mem.eql(u8, arg, "--codex-path")) {
        if (value.len == 0) return error.InvalidCodexPath;
        out.codex_path = value;
    } else if (std.mem.eql(u8, arg, "--code-mode-host")) {
        if (value.len == 0) return error.InvalidCodeModeHost;
        out.code_mode_host = value;
    } else if (std.mem.eql(u8, arg, "--parent-thread-id")) {
        out.parent_thread_id = value;
    } else if (std.mem.eql(u8, arg, "--parent-mode")) {
        out.parent_mode = ParentMode.parse(value) orelse return error.InvalidParentMode;
    } else if (std.mem.eql(u8, arg, "--multi-agent-mode")) {
        out.multi_agent_mode = cas.MultiAgentMode.parse(value) orelse
            return error.InvalidMultiAgentMode;
    } else if (std.mem.eql(u8, arg, "--review-thread-id")) {
        try validateReviewThreadIdSelector(value);
        out.review_thread_id = value;
    } else return false;
    return true;
}

fn parseReviewTargetOption(out: *ParsedArgs, arg: []const u8, value: []const u8) !bool {
    if (std.mem.eql(u8, arg, "--base")) {
        try setTarget(out, .{ .base_branch = value });
    } else if (std.mem.eql(u8, arg, "--commit")) {
        try setTarget(out, .{ .commit = .{ .sha = value } });
    } else if (std.mem.eql(u8, arg, "--title")) {
        if (out.target == null or out.target.? != .commit) return error.TitleRequiresCommit;
        out.target.?.commit.title = value;
    } else return false;
    return true;
}

fn parseReviewInputOption(
    io: std.Io,
    directory: std.Io.Dir,
    allocator: std.mem.Allocator,
    out: *ParsedArgs,
    arg: []const u8,
    value: []const u8,
) !bool {
    if (std.mem.eql(u8, arg, "--custom-instructions")) {
        if (out.custom_instructions_arg != null) return error.DuplicateCustomInstructions;
        const instructions = try loadCustomInstructionsAlloc(io, directory, allocator, value);
        if (!workflowBindingStringValid(instructions)) {
            allocator.free(instructions);
            return error.InvalidCustomInstructions;
        }
        out.custom_instructions_arg = value;
        out.custom_instructions = instructions;
    } else if (std.mem.eql(u8, arg, "--thread-start-params-json")) {
        if (out.thread_start_options != null) return error.DuplicateThreadStartParams;
        if (value.len == 0 or std.mem.eql(u8, value, "-") or std.mem.eql(u8, value, "@")) {
            return error.InvalidThreadStartParams;
        }
        const raw = try loadCustomInstructionsAlloc(io, directory, allocator, value);
        defer allocator.free(raw);
        out.thread_start_options = try review_options.ThreadStartOptions.init(allocator, raw);
    } else if (std.mem.eql(u8, arg, "--workflow-binding-json")) {
        if (out.workflow_binding_arg != null) return error.DuplicateWorkflowBinding;
        if (value.len == 0 or std.mem.eql(u8, value, "-")) return error.InvalidWorkflowBinding;
        out.workflow_binding_arg = value;
    } else return false;
    return true;
}

fn parseReviewTimingOption(out: *ParsedArgs, arg: []const u8, value: []const u8) !bool {
    if (std.mem.eql(u8, arg, "--timeout-ms")) {
        const duration = try std.fmt.parseInt(i64, value, 10);
        if (duration <= 0 or duration > std.math.maxInt(u32)) return error.InvalidTimeout;
        out.timeout_ms = @intCast(duration);
        out.timeout_ms_explicit = true;
    } else if (std.mem.eql(u8, arg, "--poll-interval-ms")) {
        const duration = try std.fmt.parseInt(i64, value, 10);
        if (duration <= 0 or duration > std.math.maxInt(u32)) return error.InvalidPollInterval;
        out.poll_interval_ms = @intCast(duration);
    } else return false;
    return true;
}

fn parseReviewApprovalOption(out: *ParsedArgs, arg: []const u8, value: []const u8) bool {
    const options = .{
        .{ "--exec-approval", "exec_approval" },
        .{ "--file-approval", "file_approval" },
        .{ "--permissions-approval", "permissions_approval" },
        .{ "--request-user-input-response-json", "request_user_input_response_json" },
        .{ "--elicitation-action", "elicitation_action" },
        .{ "--elicitation-content-json", "elicitation_content_json" },
        .{ "--dynamic-tool-response-json", "dynamic_tool_response_json" },
    };
    inline for (options) |option| {
        if (std.mem.eql(u8, arg, option[0])) {
            @field(out, option[1]) = value;
            return true;
        }
    }
    return false;
}

test "review duration options reject values outside their stored range" {
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer directory.close(std.testing.io);
    for ([_][]const u8{ "--timeout-ms", "--poll-interval-ms" }) |flag| {
        const expected = if (std.mem.eql(u8, flag, "--timeout-ms"))
            error.InvalidTimeout
        else
            error.InvalidPollInterval;
        for ([_][]const u8{ "-1", "0", "4294967296" }) |invalid| {
            const argv = [_][]const u8{
                "cas_review_session", "run", "--cwd", "/tmp", "--uncommitted", flag, invalid,
            };
            try std.testing.expectError(expected, parseArgs(std.testing.io, directory, std.testing.allocator, &argv));
        }
        for ([_][]const u8{ "1", "4294967295" }) |valid| {
            const argv = [_][]const u8{
                "cas_review_session", "run", "--cwd", "/tmp", "--uncommitted", flag, valid,
            };
            const parsed = try parseArgs(std.testing.io, directory, std.testing.allocator, &argv);
            defer parsed.deinit(std.testing.allocator);
            const observed = if (std.mem.eql(u8, flag, "--timeout-ms"))
                parsed.timeout_ms
            else
                parsed.poll_interval_ms;
            try std.testing.expectEqual(try std.fmt.parseInt(u32, valid, 10), observed);
        }
    }
}

fn parseReviewStoreOption(out: *ParsedArgs, arg: []const u8, value: []const u8) !bool {
    if (std.mem.eql(u8, arg, "--hooks")) {
        out.hook_policy = cas.hooks.HookPolicy.parse(value) orelse return error.InvalidHooksPolicy;
    } else if (std.mem.eql(u8, arg, "--review-lock-override")) {
        if (value.len == 0) return error.InvalidReviewLockOverrideReason;
        out.review_lock_override_reason = value;
    } else if (std.mem.eql(u8, arg, "--fresh-attempt")) {
        if (value.len == 0) return error.InvalidFreshAttemptReason;
        out.fresh_attempt_reason = value;
    } else if (std.mem.eql(u8, arg, "--store-root")) {
        if (value.len == 0) return error.InvalidStoreRoot;
        out.store_root = value;
    } else if (std.mem.eql(u8, arg, "--codex-thread-id")) {
        if (value.len == 0) return error.InvalidCodexThreadId;
        out.codex_thread_id = value;
    } else return false;
    return true;
}

fn validateReviewArgs(out: ParsedArgs) !void {
    if (out.multi_agent_mode != null) return error.MultiAgentModeRemoved;
    if (out.action == .wait and out.review_lock_override_reason != null) {
        return error.ReviewLockOverrideUnsupportedAction;
    }
    if (out.action == .wait and out.fresh_attempt_reason != null) {
        return error.FreshAttemptUnsupportedAction;
    }
    if (out.action == .wait and out.workflow_binding_arg != null) {
        return error.WorkflowBindingUnsupportedAction;
    }
    switch (out.action.?) {
        .run, .start => try validateReviewStartArgs(out),
        .wait => try validateReviewWaitArgs(out),
    }
}

fn validateReviewStartArgs(out: ParsedArgs) !void {
    if (out.cwd == null) return error.MissingCwd;
    if (out.target == null) return error.MissingTarget;
    if (out.review_thread_id != null or out.latest_review_session) {
        return error.ReviewSessionSelectorUnsupportedAction;
    }
    if (out.parent_mode == .fresh and out.parent_thread_id != null) {
        return error.FreshParentModeDisallowsParentThreadId;
    }
    if (out.parent_mode == .reuse and out.parent_thread_id == null) {
        return error.ReuseParentModeRequiresParentThreadId;
    }
    if (out.custom_instructions != null and out.parent_thread_id != null) {
        return error.CustomInstructionsRequireFreshParent;
    }
    if (out.receipt_paths.len != 0) return error.SessionPathUnsupportedAction;
}

fn validateReviewWaitArgs(out: ParsedArgs) !void {
    if (out.thread_start_options != null) return error.ThreadStartParamsUnsupportedAction;
    if (out.codex_path != null) return error.CodexPathUnsupportedAction;
    if (out.code_mode_host != null) return error.CodeModeHostUnsupportedAction;
    if (out.target != null) return error.TargetUnsupportedAction;
    if (out.custom_instructions != null) return error.CustomInstructionsUnsupportedAction;
    if (out.wait_after_start) return error.WaitFlagUnsupportedAction;
    if (out.review_thread_id != null and out.latest_review_session) {
        return error.AmbiguousReviewSessionSelector;
    }
    if (out.receipt_paths.len > 1 or (out.receipt_paths.len == 1 and
        (out.review_thread_id != null or out.latest_review_session)))
    {
        return error.AmbiguousReviewSessionSelector;
    }
    const has_selector = out.review_thread_id != null or out.latest_review_session;
    if (!has_selector and out.receipt_paths.len == 0) {
        return error.MissingReviewThreadId;
    }
}

const ReviewThreadIdSelectorHint =
    "pass the bare reviewThreadId; use --path for a session record or " ++
    "--latest for the newest persisted session.";
const MultiAgentModeRemovedHint =
    "Request-scoped multiAgentMode is retired; configure [agents] in " ++
    "config.toml and use the current Codex reasoning-effort controls instead.";
const ThreadStartInstructionsHint =
    "set the exact review instructions with --custom-instructions";
const EphemeralReviewThreadHint =
    "CAS review requires a durable thread for terminal evidence and later wait";
const ThreadStartActionHint =
    "set launch options on run/start; wait observes the existing configured attempt";
const ThreadStartParamsHint =
    "pass a thread/start JSON object or @file; stdin is reserved for review instructions";

pub fn usageDetailForParseError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidReviewThreadId => ReviewThreadIdSelectorHint,
        error.MultiAgentModeRemoved => MultiAgentModeRemovedHint,
        error.ThreadStartCwdOwnedByCas => "set the reviewed repository with --cwd",
        error.ThreadStartDeveloperInstructionsOwnedByCas => ThreadStartInstructionsHint,
        error.EphemeralReviewThreadUnsupported => EphemeralReviewThreadHint,
        error.ThreadStartParamsUnsupportedAction => ThreadStartActionHint,
        error.ThreadStartOptionsExpectedObject,
        error.InvalidThreadStartParams,
        => ThreadStartParamsHint,
        else => null,
    };
}

fn validateReviewThreadIdSelector(value: []const u8) !void {
    if (value.len == 0) return error.InvalidReviewThreadId;
    if (std.mem.indexOfScalar(u8, value, '/') != null) return error.InvalidReviewThreadId;
    if (std.mem.indexOfScalar(u8, value, '\\') != null) return error.InvalidReviewThreadId;

    const artifact_suffixes = [_][]const u8{
        ".parent.events.ndjson",
        ".events.ndjson",
        ".json",
    };
    for (artifact_suffixes) |suffix| {
        if (std.mem.endsWith(u8, value, suffix)) return error.InvalidReviewThreadId;
    }
}

fn setTarget(parsed: *ParsedArgs, target: ReviewTarget) !void {
    if (parsed.target != null) return error.MultipleTargetSelectors;
    parsed.target = target;
}

fn loadCustomInstructionsAlloc(io: std.Io, directory: std.Io.Dir, allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.eql(u8, raw, "-")) {
        var reader = std.Io.File.stdin().reader(io, &.{});
        return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    }
    if (std.mem.startsWith(u8, raw, "@")) {
        return directory.readFileAlloc(
            io,
            raw[1..],
            allocator,
            .limited(1024 * 1024),
        );
    }
    return allocator.dupe(u8, raw);
}

pub fn workflowBindingStringValid(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}

test "CLI target admission keeps title scoped to the selected commit" {
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer directory.close(std.testing.io);
    const allocator = std.testing.allocator;
    const committed = try parseArgs(std.testing.io, directory, allocator, &.{
        "cas_review_session", "run", "--cwd", ".", "--commit", "HEAD", "--title", "exact title",
    });
    defer committed.deinit(allocator);
    try std.testing.expectEqualStrings("HEAD", committed.target.?.commit.sha);
    try std.testing.expectEqualStrings("exact title", committed.target.?.commit.title.?);
    try std.testing.expectError(error.TitleRequiresCommit, parseArgs(std.testing.io, directory, allocator, &.{
        "cas_review_session", "run", "--cwd", ".", "--base", "main", "--title", "title",
    }));
    try std.testing.expectError(error.TitleRequiresCommit, parseArgs(std.testing.io, directory, allocator, &.{
        "cas_review_session", "run", "--cwd", ".", "--title", "title", "--commit", "HEAD",
    }));
    try std.testing.expectError(error.MultipleTargetSelectors, parseArgs(std.testing.io, directory, allocator, &.{
        "cas_review_session", "run", "--cwd", ".", "--commit", "HEAD", "--uncommitted",
    }));
}
