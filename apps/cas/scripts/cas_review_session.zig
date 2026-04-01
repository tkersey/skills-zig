const app_meta = @import("app_meta");
const cas = @import("cas_proxy_client.zig");
const core_cli = @import("core_cli");
const core_json = @import("core_json");
const core_path = @import("core_path");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);

const UsageText =
    \\cas_review_session.zig
    \\
    \\Control detached Codex review sessions via the app-server.
    \\
    \\Usage:
    \\  zig run apps/cas/scripts/cas_review_session.zig -- <start|status|wait|interrupt> [options]
    \\
    \\Actions:
    \\  start      Start a detached review session and persist its handle.
    \\  status     Read the persisted session and report current review status.
    \\  wait       Poll the persisted session until the review turn reaches a terminal status.
    \\  interrupt  Interrupt the persisted detached review turn.
    \\
    \\Start options:
    \\  --cwd DIR                        Workspace for the app-server.
    \\  --parent-thread-id THREAD_ID     Optional parent thread id to reuse.
    \\  --parent-mode MODE               Parent strategy: auto|fresh|reuse (default: auto).
    \\  --wait                           Keep the start process alive until the review turn reaches a terminal status.
    \\  --uncommitted                    Review staged, unstaged, and untracked changes.
    \\  --base BRANCH                    Review changes against a base branch.
    \\  --commit SHA                     Review a specific commit.
    \\  --title TITLE                    Optional commit title for --commit.
    \\  --custom-instructions VALUE      Custom review instructions, raw text, @file, or - for stdin.
    \\
    \\Approval/runtime options:
    \\  --exec-approval VALUE            auto|accept|acceptForSession|decline|cancel.
    \\  --file-approval VALUE            auto|accept|acceptForSession|decline|cancel.
    \\  --permissions-approval VALUE     deny|grant-turn|grant-session.
    \\  --request-user-input-response-json JSON
    \\                                   Exact result payload for item/tool/requestUserInput.
    \\  --elicitation-action VALUE       decline|cancel|accept.
    \\  --elicitation-content-json JSON  Content payload when elicitation action is accept.
    \\  --dynamic-tool-response-json JSON
    \\                                   Exact result payload for item/tool/call.
    \\  --read-only                      Decline exec + file approvals.
    \\  --fallback MODE                  none|native-review (default: none).
    \\
    \\Status/wait/interrupt options:
    \\  --review-thread-id THREAD_ID     Detached review thread id handle.
    \\
    \\Common options:
    \\  --json                           Emit machine-readable JSON.
    \\  --timeout-ms N                   Wait timeout for `wait` (default: 300000).
    \\  --poll-interval-ms N             Poll interval for `wait` (default: 250).
    \\  --help                           Show help.
    \\  --version                        Show version.
    \\  version                          Show version.
    \\
    \\Examples:
    \\  cas review_session start --cwd /path/to/repo --uncommitted --json
    \\  cas review_session start --cwd /path/to/repo --base main --json
    \\  cas review_session start --wait --cwd /path/to/repo --base main --json
    \\  cas review_session status --review-thread-id thr_123 --json
    \\  cas review_session wait --review-thread-id thr_123 --timeout-ms 300000 --json
    \\  cas review_session interrupt --review-thread-id thr_123 --json
;

const Action = enum {
    start,
    status,
    wait,
    interrupt,

    fn parse(raw: []const u8) ?Action {
        if (std.mem.eql(u8, raw, "start")) return .start;
        if (std.mem.eql(u8, raw, "status")) return .status;
        if (std.mem.eql(u8, raw, "wait")) return .wait;
        if (std.mem.eql(u8, raw, "interrupt")) return .interrupt;
        return null;
    }
};

const ParentMode = enum {
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

const FallbackMode = enum {
    none,
    native_review,

    fn parse(raw: []const u8) ?FallbackMode {
        if (std.mem.eql(u8, raw, "none")) return .none;
        if (std.mem.eql(u8, raw, "native-review")) return .native_review;
        if (std.mem.eql(u8, raw, "native_review")) return .native_review;
        return null;
    }
};

const TargetKind = enum {
    uncommitted,
    base_branch,
    commit,
    custom,

    fn asString(self: TargetKind) []const u8 {
        return switch (self) {
            .uncommitted => "uncommittedChanges",
            .base_branch => "baseBranch",
            .commit => "commit",
            .custom => "custom",
        };
    }
};

const TargetConfig = struct {
    kind: TargetKind,
    branch: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    title: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
};

const ParsedArgs = struct {
    action: ?Action = null,
    cwd: ?[]const u8 = null,
    parent_thread_id: ?[]const u8 = null,
    parent_mode: ParentMode = .auto,
    review_thread_id: ?[]const u8 = null,
    target: ?TargetConfig = null,
    wait_after_start: bool = false,
    json: bool = false,
    timeout_ms: u32 = 300_000,
    poll_interval_ms: u32 = 250,
    exec_approval: ?[]const u8 = null,
    file_approval: ?[]const u8 = null,
    permissions_approval: ?[]const u8 = null,
    request_user_input_response_json: ?[]const u8 = null,
    elicitation_action: ?[]const u8 = null,
    elicitation_content_json: ?[]const u8 = null,
    dynamic_tool_response_json: ?[]const u8 = null,
    read_only: bool = false,
    fallback_mode: FallbackMode = .none,
    show_help: bool = false,
    show_version: bool = false,
};

const TargetRecord = struct {
    type: []const u8,
    branch: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    title: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
};

const SessionRecord = struct {
    schema_version: u32 = 2,
    cwd: []const u8,
    parent_thread_id: []const u8,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    delivery: []const u8,
    target: TargetRecord,
    event_log_path: []const u8,
    created_at_unix_s: i64,
    last_observed_status: []const u8,
    codex_version: []const u8,
    resolved_codex_path: ?[]const u8 = null,
    compatibility_verdict: ?[]const u8 = null,
};

const OutputReceipt = struct {
    resolved_codex_path: ?[]const u8 = null,
    resolved_codex_version: ?[]const u8 = null,
    compatibility_verdict: []const u8 = "not_checked",
};

const FailureInfo = struct {
    code: []const u8,
    hint: []const u8,
};

const parent_materialization_prompt =
    "Internal bootstrap for detached review parent materialization. Reply with OK only.";

const ReviewStatus = struct {
    thread_status: []const u8,
    turn_status: []const u8,
    turn_count: usize,
    materialized: bool,
    thread_preview: []const u8,
    rollout_path: ?[]const u8,
    turn_error_message: ?[]const u8,
    last_turn_has_entered_review_mode: bool,
    last_turn_has_exited_review_mode: bool,
    review_result_available: bool,
    review_result_source: ?[]const u8,
    review_result_json: ?[]const u8,
    raw_response_json: []const u8,

    fn deinit(self: ReviewStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.thread_status);
        allocator.free(self.turn_status);
        allocator.free(self.thread_preview);
        if (self.rollout_path) |path| allocator.free(path);
        if (self.turn_error_message) |message| allocator.free(message);
        if (self.review_result_json) |json| allocator.free(json);
        allocator.free(self.raw_response_json);
    }
};

const NativeFallbackResult = struct {
    exit_code: u8,
    ok: bool,
    stdout_text: ?[]const u8,
    stderr_text: ?[]const u8,

    fn deinit(self: NativeFallbackResult, allocator: std.mem.Allocator) void {
        if (self.stdout_text) |value| allocator.free(value);
        if (self.stderr_text) |value| allocator.free(value);
    }
};

const ReviewLineRangeJson = struct {
    start: u32,
    end: u32,
};

const ReviewCodeLocationJson = struct {
    absoluteFilePath: []const u8,
    lineRange: ReviewLineRangeJson,
};

const ReviewFindingJson = struct {
    title: []const u8,
    body: []const u8,
    confidenceScore: f32,
    priority: i32,
    codeLocation: ReviewCodeLocationJson,
};

const ReviewResultJson = struct {
    findings: []ReviewFindingJson,
    overallCorrectness: []const u8,
    overallExplanation: []const u8,
    overallConfidenceScore: f32,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    if (try core_cli.handleDefaultHelpAndVersion(argv, UsageText, Version)) return;

    const parsed = parseArgs(allocator, argv) catch |err| {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}\n{s}\n", .{ @errorName(err), UsageText });
        std.process.exit(2);
    };

    if (parsed.show_version) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }

    if (parsed.show_help or parsed.action == null) {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpWithVersion(stdout, UsageText, Version);
        return;
    }

    switch (parsed.action.?) {
        .start => try cmdStart(allocator, parsed),
        .status => try cmdStatus(allocator, parsed),
        .wait => try cmdWait(allocator, parsed),
        .interrupt => try cmdInterrupt(allocator, parsed),
    }
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    var out = ParsedArgs{};
    if (argv.len <= 1) return out;

    var i: usize = 1;
    const first = argv[i];
    if (core_cli.isHelpArg(first)) {
        out.show_help = true;
        return out;
    }
    if (core_cli.isVersionArg(first) or core_cli.isVersionSubcommand(first)) {
        out.show_version = true;
        return out;
    }

    out.action = Action.parse(first) orelse return error.UnknownAction;
    i += 1;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (core_cli.isHelpArg(arg)) {
            out.show_help = true;
            continue;
        }
        if (core_cli.isVersionArg(arg) or core_cli.isVersionSubcommand(arg)) {
            out.show_version = true;
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
        if (std.mem.eql(u8, arg, "--wait")) {
            out.wait_after_start = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--uncommitted")) {
            setTarget(&out, .{ .kind = .uncommitted });
            continue;
        }

        i += 1;
        if (i >= argv.len) return error.MissingValue;
        const value = argv[i];

        if (std.mem.eql(u8, arg, "--cwd")) {
            out.cwd = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--parent-thread-id")) {
            out.parent_thread_id = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--parent-mode")) {
            out.parent_mode = ParentMode.parse(value) orelse return error.InvalidParentMode;
            continue;
        }
        if (std.mem.eql(u8, arg, "--review-thread-id")) {
            out.review_thread_id = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--base")) {
            setTarget(&out, .{ .kind = .base_branch, .branch = value });
            continue;
        }
        if (std.mem.eql(u8, arg, "--commit")) {
            setTarget(&out, .{ .kind = .commit, .sha = value });
            continue;
        }
        if (std.mem.eql(u8, arg, "--title")) {
            if (out.target == null or out.target.?.kind != .commit) return error.TitleRequiresCommit;
            out.target.?.title = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--custom-instructions")) {
            const instructions = try loadCustomInstructionsAlloc(allocator, value);
            setTarget(&out, .{ .kind = .custom, .instructions = instructions });
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout-ms")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidTimeout;
            out.timeout_ms = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--poll-interval-ms")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidPollInterval;
            out.poll_interval_ms = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--exec-approval")) {
            out.exec_approval = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--file-approval")) {
            out.file_approval = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--permissions-approval")) {
            out.permissions_approval = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--request-user-input-response-json")) {
            out.request_user_input_response_json = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--elicitation-action")) {
            out.elicitation_action = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--elicitation-content-json")) {
            out.elicitation_content_json = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dynamic-tool-response-json")) {
            out.dynamic_tool_response_json = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--fallback")) {
            out.fallback_mode = FallbackMode.parse(value) orelse return error.InvalidFallbackMode;
            continue;
        }
        return error.UnknownArg;
    }

    switch (out.action.?) {
        .start => {
            if (out.cwd == null) return error.MissingCwd;
            if (out.target == null) return error.MissingTarget;
            if (out.parent_mode == .fresh and out.parent_thread_id != null) return error.FreshParentModeDisallowsParentThreadId;
            if (out.parent_mode == .reuse and out.parent_thread_id == null) return error.ReuseParentModeRequiresParentThreadId;
        },
        .status, .wait, .interrupt => {
            if (out.review_thread_id == null) return error.MissingReviewThreadId;
        },
    }

    return out;
}

fn setTarget(parsed: *ParsedArgs, target: TargetConfig) void {
    parsed.target = target;
}

fn loadCustomInstructionsAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.eql(u8, raw, "-")) {
        return std.fs.File.stdin().readToEndAlloc(allocator, 1024 * 1024);
    }
    if (std.mem.startsWith(u8, raw, "@")) {
        return std.fs.cwd().readFileAlloc(allocator, raw[1..], 1024 * 1024);
    }
    return allocator.dupe(u8, raw);
}

fn cmdStart(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    const cwd = parsed.cwd.?;
    const resolved_codex_path = cas.resolveExecutableAlloc(allocator, "codex") catch {
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            "codex binary could not be resolved for review_session",
            cwd,
            .{},
            .{
                .code = "missing_codex_binary",
                .hint = "install or expose a compatible codex binary on PATH before running cas review_session",
            },
        );
    };
    const codex_version = readCodexVersionAlloc(allocator, cwd, resolved_codex_path) catch {
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            "codex --version could not be read for review_session",
            cwd,
            .{
                .resolved_codex_path = resolved_codex_path,
            },
            .{
                .code = "review_turn_failed",
                .hint = "verify the resolved codex binary is executable and supports app-server mode",
            },
        );
    };
    const output_receipt = OutputReceipt{
        .resolved_codex_path = resolved_codex_path,
        .resolved_codex_version = codex_version,
        .compatibility_verdict = "not_checked",
    };

    var client = cas.Client.start(allocator, .{
        .cwd = cwd,
        .codex_path = resolved_codex_path,
        .client_name = "cas-review-session",
        .client_title = "CAS Review Session",
        .client_version = Version,
        .exec_approval = parsed.exec_approval,
        .file_approval = parsed.file_approval,
        .permissions_approval = parsed.permissions_approval,
        .request_user_input_response_json = parsed.request_user_input_response_json,
        .elicitation_action = parsed.elicitation_action,
        .elicitation_content_json = parsed.elicitation_content_json,
        .dynamic_tool_response_json = parsed.dynamic_tool_response_json,
        .read_only = parsed.read_only,
    }) catch |err| {
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            @errorName(err),
            cwd,
            output_receipt,
            .{
                .code = "review_turn_failed",
                .hint = "codex app-server failed before detached review startup completed",
            },
        );
    };
    defer {
        client.close();
        client.deinit();
    }

    const session_dir = try sessionDirAlloc(allocator);
    const parent_event_log_path = try std.fs.path.join(allocator, &.{ session_dir, "parent-thread.ndjson" });
    const target = parsed.target.?;
    const target_record = targetToRecord(target);
    const created_parent_thread = parsed.parent_thread_id == null;
    const parent_thread_id = if (parsed.parent_thread_id) |existing| blk: {
        try resumeParentThread(allocator, &client, existing, session_dir);
        var parent_status = try fetchReviewStatus(allocator, &client, existing, parent_event_log_path);
        defer parent_status.deinit(allocator);
        if (failureInfoForParentReuse(&parent_status)) |failure| {
            try renderErrorAndExit(
                parsed.json,
                "start",
                "review/start",
                failure.hint,
                cwd,
                output_receipt,
                failure,
            );
        }
        break :blk try allocator.dupe(u8, existing);
    } else try startParentThreadAlloc(allocator, &client, cwd, session_dir);
    const review_params_json = try buildReviewStartParamsJson(allocator, parent_thread_id, target);
    defer allocator.free(review_params_json);
    appendLogRecord(allocator, parent_event_log_path, "thread/start", "response", parent_thread_id) catch {};

    var review_result_json: []u8 = undefined;
    var review_start_retry_used = false;
    review_result_json = client.requestJson("review/start", review_params_json) catch |err| blk: {
        const raw_message = client.lastError() orelse @errorName(err);
        const failure = failureInfoForReviewStart(raw_message, created_parent_thread);
        if (created_parent_thread and failure != null) {
            materializeParentThreadTurn(
                allocator,
                &client,
                parent_thread_id,
                parent_event_log_path,
                parsed.timeout_ms,
                parsed.poll_interval_ms,
            ) catch {
                try renderErrorAndExit(
                    parsed.json,
                    "start",
                    "review/start",
                    "fresh detached review parent could not be materialized before retry",
                    cwd,
                    .{
                        .resolved_codex_path = resolved_codex_path,
                        .resolved_codex_version = codex_version,
                        .compatibility_verdict = "incompatible",
                    },
                    .{
                        .code = "parent_materialization_failed",
                        .hint = "fresh parent-thread retry could not materialize rollout state; upgrade codex or pass a clean materialized --parent-thread-id",
                    },
                );
            };

            review_start_retry_used = true;
            break :blk client.requestJson("review/start", review_params_json) catch |retry_err| {
                const retry_message = client.lastError() orelse @errorName(retry_err);
                const retry_failure = failureInfoForReviewStart(retry_message, created_parent_thread);
                const message = if (retry_failure) |value| value.hint else retry_message;
                try maybeRunNativeFallbackAndExitStart(
                    allocator,
                    parsed,
                    cwd,
                    resolved_codex_path,
                    parent_thread_id,
                    "",
                    "",
                    target_record,
                    "",
                    parent_event_log_path,
                    .{
                        .resolved_codex_path = resolved_codex_path,
                        .resolved_codex_version = codex_version,
                        .compatibility_verdict = if (retry_failure != null) "incompatible" else "not_checked",
                    },
                    null,
                    false,
                    false,
                    retry_failure orelse .{
                        .code = "review_turn_failed",
                        .hint = "detached review startup failed after fresh-parent materialization retry",
                    },
                );
                try renderErrorAndExit(
                    parsed.json,
                    "start",
                    "review/start",
                    message,
                    cwd,
                    .{
                        .resolved_codex_path = resolved_codex_path,
                        .resolved_codex_version = codex_version,
                        .compatibility_verdict = if (retry_failure != null) "incompatible" else "not_checked",
                    },
                    retry_failure orelse .{
                        .code = "review_turn_failed",
                        .hint = "detached review startup failed after fresh-parent materialization retry",
                    },
                );
            };
        }

        const message = if (failure) |value| value.hint else raw_message;
        try maybeRunNativeFallbackAndExitStart(
            allocator,
            parsed,
            cwd,
            resolved_codex_path,
            parent_thread_id,
            "",
            "",
            target_record,
            "",
            parent_event_log_path,
            .{
                .resolved_codex_path = resolved_codex_path,
                .resolved_codex_version = codex_version,
                .compatibility_verdict = if (failure != null) "incompatible" else "not_checked",
            },
            null,
            false,
            false,
            failure orelse .{
                .code = "review_turn_failed",
                .hint = "detached review startup failed after app-server launch",
            },
        );
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            message,
            cwd,
            .{
                .resolved_codex_path = resolved_codex_path,
                .resolved_codex_version = codex_version,
                .compatibility_verdict = if (failure != null) "incompatible" else "not_checked",
            },
            failure orelse .{
                .code = "review_turn_failed",
                .hint = "detached review startup failed after app-server launch",
            },
        );
    };
    defer allocator.free(review_result_json);

    const review_thread_id = try extractReviewThreadIdAlloc(allocator, review_result_json);
    const review_turn_id = try extractReviewTurnIdAlloc(allocator, review_result_json);
    const event_log_path = try std.fmt.allocPrint(allocator, "{s}/{s}.events.ndjson", .{ session_dir, review_thread_id });
    const record_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, review_thread_id });

    try appendLogRecord(allocator, event_log_path, "review/start", "request", review_params_json);
    try appendLogRecord(allocator, event_log_path, "review/start", "response", review_result_json);
    if (review_start_retry_used) {
        appendLogRecord(allocator, event_log_path, "review/start", "note", "{\"retry\":\"fresh-parent-materialization\"}") catch {};
    }

    var record = SessionRecord{
        .cwd = cwd,
        .parent_thread_id = parent_thread_id,
        .review_thread_id = review_thread_id,
        .review_turn_id = review_turn_id,
        .delivery = "detached",
        .target = target_record,
        .event_log_path = event_log_path,
        .created_at_unix_s = std.time.timestamp(),
        .last_observed_status = "inProgress",
        .codex_version = codex_version,
        .resolved_codex_path = resolved_codex_path,
        .compatibility_verdict = "compatible",
    };
    try writeSessionRecord(allocator, record_path, record);

    if (parsed.wait_after_start) {
        const latest = waitForReviewCompletion(
            allocator,
            &client,
            record.review_thread_id,
            record.event_log_path,
            parsed.timeout_ms,
            parsed.poll_interval_ms,
        ) catch |err| switch (err) {
            error.WaitTimedOut => {
                const timeout_status = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path);
                record.last_observed_status = timeoutStatusString(&timeout_status);
                try writeSessionRecord(allocator, record_path, record);
                if (parsed.json) {
                    try printStartJson(
                        allocator,
                        cwd,
                        parent_thread_id,
                        review_thread_id,
                        review_turn_id,
                        target_record,
                        record_path,
                        event_log_path,
                        .{
                            .resolved_codex_path = resolved_codex_path,
                            .resolved_codex_version = codex_version,
                            .compatibility_verdict = "compatible",
                        },
                        timeout_status,
                        true,
                        true,
                        .{
                            .code = "wait_timed_out",
                            .hint = "retry cas review_session wait on the same review thread or increase --timeout-ms",
                        },
                        null,
                    );
                } else {
                    var stdout_writer = std.fs.File.stdout().writer(&.{});
                    const stdout = &stdout_writer.interface;
                    try stdout.print("cas_review_session start timed out after {d}ms\nreview thread: {s}\n", .{
                        parsed.timeout_ms,
                        review_thread_id,
                    });
                }
                std.process.exit(1);
            },
            error.ReviewResultUnavailable => {
                const latest_status = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path);
                record.last_observed_status = timeoutStatusString(&latest_status);
                if (failureInfoForStatus(&latest_status)) |failure| {
                    if (std.mem.eql(u8, failure.code, "incompatible_codex_review_runtime")) {
                        record.compatibility_verdict = "incompatible";
                    }
                }
                try writeSessionRecord(allocator, record_path, record);
                try maybeRunNativeFallbackAndExitStart(
                    allocator,
                    parsed,
                    cwd,
                    resolved_codex_path,
                    parent_thread_id,
                    review_thread_id,
                    review_turn_id,
                    target_record,
                    record_path,
                    event_log_path,
                    .{
                        .resolved_codex_path = resolved_codex_path,
                        .resolved_codex_version = codex_version,
                        .compatibility_verdict = "compatible",
                    },
                    latest_status,
                    false,
                    true,
                    failureInfoForStatus(&latest_status) orelse .{
                        .code = "review_result_unavailable",
                        .hint = "detached review reached terminal status without a materialized reviewResult",
                    },
                );
                if (parsed.json) {
                    try printStartJson(
                        allocator,
                        cwd,
                        parent_thread_id,
                        review_thread_id,
                        review_turn_id,
                        target_record,
                        record_path,
                        event_log_path,
                        .{
                            .resolved_codex_path = resolved_codex_path,
                            .resolved_codex_version = codex_version,
                            .compatibility_verdict = record.compatibility_verdict orelse "compatible",
                        },
                        latest_status,
                        false,
                        true,
                        .{
                            .code = failureInfoForStatus(&latest_status).?.code,
                            .hint = failureInfoForStatus(&latest_status).?.hint,
                        },
                        null,
                    );
                } else {
                    var stdout_writer = std.fs.File.stdout().writer(&.{});
                    const stdout = &stdout_writer.interface;
                    try stdout.print("cas_review_session start reached terminal status without a reviewResult\nreview thread: {s}\n", .{
                        review_thread_id,
                    });
                }
                std.process.exit(1);
            },
            else => return err,
        };
        record.last_observed_status = latest.turn_status;
        try writeSessionRecord(allocator, record_path, record);

        if (parsed.json) {
            try printStartJson(
                allocator,
                cwd,
                parent_thread_id,
                review_thread_id,
                review_turn_id,
                target_record,
                record_path,
                event_log_path,
                .{
                    .resolved_codex_path = resolved_codex_path,
                    .resolved_codex_version = codex_version,
                    .compatibility_verdict = "compatible",
                },
                latest,
                false,
                true,
                null,
                null,
            );
        } else {
            var stdout_writer = std.fs.File.stdout().writer(&.{});
            const stdout = &stdout_writer.interface;
            try stdout.print("cas_review_session start\ncwd: {s}\nparent thread: {s}\nreview thread: {s}\nreview turn: {s}\nfinal turn status: {s}\nrecord: {s}\nevent log: {s}\n", .{
                cwd,
                parent_thread_id,
                review_thread_id,
                review_turn_id,
                latest.turn_status,
                record_path,
                event_log_path,
            });
        }
        return;
    }

    if (parsed.json) {
        try printStartJson(
            allocator,
            cwd,
            parent_thread_id,
            review_thread_id,
            review_turn_id,
            target_record,
            record_path,
            event_log_path,
            .{
                .resolved_codex_path = resolved_codex_path,
                .resolved_codex_version = codex_version,
                .compatibility_verdict = "compatible",
            },
            null,
            false,
            false,
            null,
            null,
        );
    } else {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session start\ncwd: {s}\nparent thread: {s}\nreview thread: {s}\nreview turn: {s}\nrecord: {s}\nevent log: {s}\n", .{
            cwd,
            parent_thread_id,
            review_thread_id,
            review_turn_id,
            record_path,
            event_log_path,
        });
    }
}

fn cmdStatus(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    const loaded = try loadSessionRecord(allocator, parsed.review_thread_id.?);
    const record = loaded.record;

    var client = try cas.Client.start(allocator, .{
        .cwd = record.cwd,
        .codex_path = record.resolved_codex_path orelse "codex",
        .client_name = "cas-review-session",
        .client_title = "CAS Review Session",
        .client_version = Version,
    });
    defer {
        client.close();
        client.deinit();
    }

    const status = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path);

    if (parsed.json) {
        try printStatusJson(
            allocator,
            .status,
            record.cwd,
            record.parent_thread_id,
            record.review_thread_id,
            record.review_turn_id,
            status,
            loaded.record_path,
            record.event_log_path,
            .{
                .resolved_codex_path = record.resolved_codex_path,
                .resolved_codex_version = record.codex_version,
                .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
            },
            null,
            null,
            failureInfoForStatus(&status),
            null,
        );
    } else {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session status\nreview thread: {s}\nreview turn: {s}\nthread status: {s}\nturn status: {s}\nturn count: {d}\nmaterialized: {s}\nrecord: {s}\nevent log: {s}\n", .{
            record.review_thread_id,
            record.review_turn_id,
            status.thread_status,
            status.turn_status,
            status.turn_count,
            if (status.materialized) "yes" else "no",
            loaded.record_path,
            record.event_log_path,
        });
    }
}

fn cmdWait(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    const loaded = try loadSessionRecord(allocator, parsed.review_thread_id.?);
    var record = loaded.record;

    var client = try cas.Client.start(allocator, .{
        .cwd = record.cwd,
        .codex_path = record.resolved_codex_path orelse "codex",
        .client_name = "cas-review-session",
        .client_title = "CAS Review Session",
        .client_version = Version,
    });
    defer {
        client.close();
        client.deinit();
    }

    const latest = waitForReviewCompletion(
        allocator,
        &client,
        record.review_thread_id,
        record.event_log_path,
        parsed.timeout_ms,
        parsed.poll_interval_ms,
    ) catch |err| switch (err) {
        error.WaitTimedOut => {
            const timeout_status = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path);
            record.last_observed_status = timeoutStatusString(&timeout_status);
            try writeSessionRecord(allocator, loaded.record_path, record);
            if (parsed.json) {
                try printStatusJson(
                    allocator,
                    .wait,
                    null,
                    null,
                    record.review_thread_id,
                    record.review_turn_id,
                    timeout_status,
                    loaded.record_path,
                    record.event_log_path,
                    .{
                        .resolved_codex_path = record.resolved_codex_path,
                        .resolved_codex_version = record.codex_version,
                        .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                    },
                    parsed.timeout_ms,
                    true,
                    .{
                        .code = "wait_timed_out",
                        .hint = "retry cas review_session wait on the same review thread or increase --timeout-ms",
                    },
                    null,
                );
            } else {
                var stdout_writer = std.fs.File.stdout().writer(&.{});
                const stdout = &stdout_writer.interface;
                try stdout.print("cas_review_session wait timed out after {d}ms\nreview thread: {s}\n", .{
                    parsed.timeout_ms,
                    record.review_thread_id,
                });
            }
            std.process.exit(1);
        },
        error.ReviewResultUnavailable => {
            const terminal_status = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path);
            record.last_observed_status = timeoutStatusString(&terminal_status);
            if (failureInfoForStatus(&terminal_status)) |failure| {
                if (std.mem.eql(u8, failure.code, "incompatible_codex_review_runtime")) {
                    record.compatibility_verdict = "incompatible";
                }
            }
            try writeSessionRecord(allocator, loaded.record_path, record);
            try maybeRunNativeFallbackAndExitWait(
                allocator,
                parsed,
                record,
                loaded.record_path,
                terminal_status,
                failureInfoForStatus(&terminal_status) orelse .{
                    .code = "review_result_unavailable",
                    .hint = "detached review reached terminal status without a materialized reviewResult",
                },
            );
            if (parsed.json) {
                try printStatusJson(
                    allocator,
                    .wait,
                    null,
                    null,
                    record.review_thread_id,
                    record.review_turn_id,
                    terminal_status,
                    loaded.record_path,
                    record.event_log_path,
                    .{
                        .resolved_codex_path = record.resolved_codex_path,
                        .resolved_codex_version = record.codex_version,
                        .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                    },
                    null,
                    false,
                    .{
                        .code = failureInfoForStatus(&terminal_status).?.code,
                        .hint = failureInfoForStatus(&terminal_status).?.hint,
                    },
                    null,
                );
            } else {
                var stdout_writer = std.fs.File.stdout().writer(&.{});
                const stdout = &stdout_writer.interface;
                try stdout.print("cas_review_session wait reached terminal status without a reviewResult\nreview thread: {s}\n", .{
                    record.review_thread_id,
                });
            }
            std.process.exit(1);
        },
        else => return err,
    };

    record.last_observed_status = latest.turn_status;
    try writeSessionRecord(allocator, loaded.record_path, record);

    if (parsed.json) {
        try printStatusJson(
            allocator,
            .wait,
            null,
            null,
            record.review_thread_id,
            record.review_turn_id,
            latest,
            loaded.record_path,
            record.event_log_path,
            .{
                .resolved_codex_path = record.resolved_codex_path,
                .resolved_codex_version = record.codex_version,
                .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
            },
            null,
            false,
            null,
            null,
        );
    } else {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session wait\nreview thread: {s}\nreview turn: {s}\nfinal turn status: {s}\nrecord: {s}\n", .{
            record.review_thread_id,
            record.review_turn_id,
            latest.turn_status,
            loaded.record_path,
        });
    }
}

fn cmdInterrupt(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    const loaded = try loadSessionRecord(allocator, parsed.review_thread_id.?);
    var record = loaded.record;

    var client = try cas.Client.start(allocator, .{
        .cwd = record.cwd,
        .codex_path = record.resolved_codex_path orelse "codex",
        .client_name = "cas-review-session",
        .client_title = "CAS Review Session",
        .client_version = Version,
    });
    defer {
        client.close();
        client.deinit();
    }

    const latest = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path);
    if (isTerminalTurnStatus(latest.turn_status)) {
        record.last_observed_status = latest.turn_status;
        try writeSessionRecord(allocator, loaded.record_path, record);
        if (parsed.json) {
            const payload = .{
                .demo = "cas-review-session",
                .action = "interrupt",
                .reviewThreadId = record.review_thread_id,
                .reviewTurnId = record.review_turn_id,
                .skipped = true,
                .reason = "already-terminal",
                .turnStatus = latest.turn_status,
                .recordPath = loaded.record_path,
                .eventLogPath = record.event_log_path,
            };
            try printJson(payload);
        } else {
            var stdout_writer = std.fs.File.stdout().writer(&.{});
            const stdout = &stdout_writer.interface;
            try stdout.print("cas_review_session interrupt\nreview thread: {s}\nreview turn: {s}\nresult: already terminal ({s})\nrecord: {s}\n", .{
                record.review_thread_id,
                record.review_turn_id,
                latest.turn_status,
                loaded.record_path,
            });
        }
        return;
    }

    if (latest.rollout_path) |path| {
        const resume_params_json = try stringifyAnyAlloc(allocator, .{
            .threadId = record.review_thread_id,
            .path = path,
        });
        defer allocator.free(resume_params_json);
        const resume_result_json = client.requestJson("thread/resume", resume_params_json) catch |err| {
            const message = client.lastError() orelse @errorName(err);
            try renderErrorAndExit(
                parsed.json,
                "interrupt",
                "thread/resume",
                message,
                record.cwd,
                .{
                    .resolved_codex_path = record.resolved_codex_path,
                    .resolved_codex_version = record.codex_version,
                    .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                },
                .{
                    .code = "review_turn_failed",
                    .hint = "detached review thread could not be resumed before interrupt",
                },
            );
        };
        defer allocator.free(resume_result_json);
        try appendLogRecord(allocator, record.event_log_path, "thread/resume", "request", resume_params_json);
        try appendLogRecord(allocator, record.event_log_path, "thread/resume", "response", resume_result_json);
    }

    const params_json = try stringifyAnyAlloc(allocator, .{
        .threadId = record.review_thread_id,
        .turnId = record.review_turn_id,
    });
    defer allocator.free(params_json);

    const interrupt_result_json = client.requestJson("turn/interrupt", params_json) catch |err| {
        const message = client.lastError() orelse @errorName(err);
        try renderErrorAndExit(
            parsed.json,
            "interrupt",
            "turn/interrupt",
            message,
            record.cwd,
            .{
                .resolved_codex_path = record.resolved_codex_path,
                .resolved_codex_version = record.codex_version,
                .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
            },
            .{
                .code = "review_turn_failed",
                .hint = "detached review thread could not be interrupted cleanly",
            },
        );
    };
    defer allocator.free(interrupt_result_json);

    try appendLogRecord(allocator, record.event_log_path, "turn/interrupt", "request", params_json);
    try appendLogRecord(allocator, record.event_log_path, "turn/interrupt", "response", interrupt_result_json);

    record.last_observed_status = "interruptRequested";
    try writeSessionRecord(allocator, loaded.record_path, record);

    if (parsed.json) {
        const payload = .{
            .demo = "cas-review-session",
            .action = "interrupt",
            .reviewThreadId = record.review_thread_id,
            .reviewTurnId = record.review_turn_id,
            .result = interrupt_result_json,
            .recordPath = loaded.record_path,
            .eventLogPath = record.event_log_path,
        };
        try printJson(payload);
    } else {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session interrupt\nreview thread: {s}\nreview turn: {s}\nrecord: {s}\n", .{
            record.review_thread_id,
            record.review_turn_id,
            loaded.record_path,
        });
    }
}

fn fetchReviewStatus(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    review_thread_id: []const u8,
    event_log_path: []const u8,
) !ReviewStatus {
    const params_json = try stringifyAnyAlloc(allocator, .{
        .threadId = review_thread_id,
        .includeTurns = true,
    });
    defer allocator.free(params_json);

    const response_json = client.requestJson("thread/read", params_json) catch |err| {
        const detail = client.lastError() orelse @errorName(err);
        if (std.mem.indexOf(u8, detail, "includeTurns is unavailable") != null or
            std.mem.indexOf(u8, detail, "not materialized yet") != null)
        {
            const fallback_params = try stringifyAnyAlloc(allocator, .{
                .threadId = review_thread_id,
                .includeTurns = false,
            });
            defer allocator.free(fallback_params);
            const fallback_json = try client.requestJson("thread/read", fallback_params);
            try appendLogRecord(allocator, event_log_path, "thread/read", "response", fallback_json);
            var status = try parseReviewStatusAlloc(allocator, fallback_json, false);
            try populateReviewResult(allocator, &status);
            if (try maybeResumeMaterializedThread(allocator, client, review_thread_id, event_log_path, &status)) {
                allocator.free(fallback_json);
                const resumed_json = try client.requestJson("thread/read", fallback_params);
                try appendLogRecord(allocator, event_log_path, "thread/read", "response", resumed_json);
                var resumed_status = try parseReviewStatusAlloc(allocator, resumed_json, false);
                try populateReviewResult(allocator, &resumed_status);
                return resumed_status;
            }
            return status;
        }
        return err;
    };
    try appendLogRecord(allocator, event_log_path, "thread/read", "response", response_json);
    var status = try parseReviewStatusAlloc(allocator, response_json, true);
    try populateReviewResult(allocator, &status);
    if (try maybeResumeMaterializedThread(allocator, client, review_thread_id, event_log_path, &status)) {
        allocator.free(response_json);
        const params_after_resume = try stringifyAnyAlloc(allocator, .{
            .threadId = review_thread_id,
            .includeTurns = true,
        });
        defer allocator.free(params_after_resume);
        const resumed_json = try client.requestJson("thread/read", params_after_resume);
        try appendLogRecord(allocator, event_log_path, "thread/read", "response", resumed_json);
        var resumed_status = try parseReviewStatusAlloc(allocator, resumed_json, true);
        try populateReviewResult(allocator, &resumed_status);
        return resumed_status;
    }
    return status;
}

fn parseReviewStatusAlloc(allocator: std.mem.Allocator, raw_json: []const u8, materialized: bool) !ReviewStatus {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    const thread_obj = core_json.objectField(root_obj, "thread") orelse return error.MissingThread;
    const thread_preview = if (core_json.stringField(thread_obj, "preview")) |preview|
        try allocator.dupe(u8, preview)
    else
        try allocator.dupe(u8, "");
    const thread_status = blk: {
        if (core_json.stringField(thread_obj, "status")) |status| break :blk status;
        if (core_json.objectField(thread_obj, "status")) |status_obj| {
            if (core_json.stringField(status_obj, "type")) |status| break :blk status;
        }
        break :blk "unknown";
    };
    var turn_status: []const u8 = if (materialized) "pending" else "materializing";
    var turn_count: usize = 0;
    var turn_error_message: ?[]const u8 = null;
    var last_turn_has_entered_review_mode = false;
    var last_turn_has_exited_review_mode = false;
    const rollout_path = if (core_json.stringField(thread_obj, "path")) |path|
        try allocator.dupe(u8, path)
    else
        null;
    if (thread_obj.get("turns")) |turns_val| switch (turns_val) {
        .array => |arr| {
            turn_count = arr.items.len;
            if (arr.items.len > 0) {
                const last = arr.items[arr.items.len - 1];
                if (last == .object) {
                    if (core_json.stringField(last.object, "status")) |status| turn_status = status;
                    if (last.object.get("error")) |error_val| {
                        turn_error_message = try extractErrorMessageAlloc(allocator, error_val);
                    }
                    if (last.object.get("items")) |items_val| switch (items_val) {
                        .array => |items| {
                            for (items.items) |item| {
                                if (item != .object) continue;
                                const item_type = core_json.stringField(item.object, "type") orelse continue;
                                if (std.mem.eql(u8, item_type, "enteredReviewMode")) last_turn_has_entered_review_mode = true;
                                if (std.mem.eql(u8, item_type, "exitedReviewMode")) last_turn_has_exited_review_mode = true;
                            }
                        },
                        else => {},
                    };
                }
            }
        },
        else => {},
    };
    return .{
        .thread_status = try allocator.dupe(u8, thread_status),
        .turn_status = try allocator.dupe(u8, turn_status),
        .turn_count = turn_count,
        .materialized = materialized,
        .thread_preview = thread_preview,
        .rollout_path = rollout_path,
        .turn_error_message = turn_error_message,
        .last_turn_has_entered_review_mode = last_turn_has_entered_review_mode,
        .last_turn_has_exited_review_mode = last_turn_has_exited_review_mode,
        .review_result_available = false,
        .review_result_source = null,
        .review_result_json = null,
        .raw_response_json = try allocator.dupe(u8, raw_json),
    };
}

fn extractErrorMessageAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .null => null,
        .string => |text| try allocator.dupe(u8, text),
        .object => |obj| blk: {
            if (core_json.stringField(obj, "message")) |text| {
                break :blk try allocator.dupe(u8, text);
            }
            break :blk null;
        },
        else => null,
    };
}

fn populateReviewResult(allocator: std.mem.Allocator, status: *ReviewStatus) !void {
    if (!status.materialized) return;
    if (!isTerminalTurnStatus(status.turn_status)) return;
    const rollout_path = status.rollout_path orelse return;
    if (try readReviewResultJsonFromRolloutAlloc(allocator, rollout_path)) |json| {
        status.review_result_available = true;
        status.review_result_source = "rollout_exited_review_mode";
        status.review_result_json = json;
    }
}

fn maybeResumeMaterializedThread(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    review_thread_id: []const u8,
    event_log_path: []const u8,
    status: *const ReviewStatus,
) !bool {
    if (!status.materialized) return false;
    if (!std.mem.eql(u8, status.thread_status, "notLoaded")) return false;
    const rollout_path = status.rollout_path orelse return false;

    const params_json = try stringifyAnyAlloc(allocator, .{
        .threadId = review_thread_id,
        .path = rollout_path,
    });
    defer allocator.free(params_json);

    const resume_result_json = client.requestJson("thread/resume", params_json) catch return false;
    defer allocator.free(resume_result_json);
    try appendLogRecord(allocator, event_log_path, "thread/resume", "request", params_json);
    try appendLogRecord(allocator, event_log_path, "thread/resume", "response", resume_result_json);
    return true;
}

fn failureInfoForParentReuse(status: *const ReviewStatus) ?FailureInfo {
    if (!status.materialized or status.rollout_path == null or status.turn_count == 0) {
        return .{
            .code = "parent_thread_not_materialized",
            .hint = "supplied parent thread is not safely materialized for detached review reuse; pass a materialized thread or use --parent-mode fresh",
        };
    }
    if (std.mem.eql(u8, status.turn_status, "inProgress")) {
        return .{
            .code = "unsafe_parent_thread_state",
            .hint = "supplied parent thread still has an active turn; wait for it to finish or choose another parent thread",
        };
    }
    if (std.mem.eql(u8, status.turn_status, "interrupted") or
        std.mem.eql(u8, status.turn_status, "failed") or
        std.mem.eql(u8, status.turn_status, "errored"))
    {
        return .{
            .code = "unsafe_parent_thread_state",
            .hint = "supplied parent thread ended in an interrupted or failed state; reuse a clean materialized parent thread instead",
        };
    }
    if (status.last_turn_has_entered_review_mode and !status.last_turn_has_exited_review_mode) {
        return .{
            .code = "unsafe_parent_thread_state",
            .hint = "supplied parent thread still carries unfinished review-mode state; reuse a clean materialized parent thread instead",
        };
    }
    return null;
}

fn buildTurnStartParamsJson(allocator: std.mem.Allocator, thread_id: []const u8, text: []const u8) ![]u8 {
    return stringifyAnyAlloc(allocator, .{
        .threadId = thread_id,
        .input = .{
            .{ .type = "text", .text = text },
        },
    });
}

fn waitForThreadTerminalState(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    thread_id: []const u8,
    event_log_path: []const u8,
    timeout_ms: u32,
    poll_interval_ms: u32,
) !ReviewStatus {
    const started_ms = std.time.milliTimestamp();
    while (true) {
        const latest = try fetchReviewStatus(allocator, client, thread_id, event_log_path);
        if (isTerminalTurnStatus(latest.turn_status)) return latest;
        latest.deinit(allocator);
        if (std.time.milliTimestamp() - started_ms >= timeout_ms) return error.WaitTimedOut;
        std.Thread.sleep(@as(u64, poll_interval_ms) * std.time.ns_per_ms);
    }
}

fn materializeParentThreadTurn(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    parent_thread_id: []const u8,
    event_log_path: []const u8,
    timeout_ms: u32,
    poll_interval_ms: u32,
) !void {
    const params_json = try buildTurnStartParamsJson(
        allocator,
        parent_thread_id,
        parent_materialization_prompt,
    );
    defer allocator.free(params_json);
    const result_json = try client.requestJson("turn/start", params_json);
    defer allocator.free(result_json);
    try appendLogRecord(allocator, event_log_path, "turn/start", "request", params_json);
    try appendLogRecord(allocator, event_log_path, "turn/start", "response", result_json);

    var terminal_status = try waitForThreadTerminalState(
        allocator,
        client,
        parent_thread_id,
        event_log_path,
        timeout_ms,
        poll_interval_ms,
    );
    defer terminal_status.deinit(allocator);
    if (std.mem.eql(u8, terminal_status.turn_status, "failed") or
        std.mem.eql(u8, terminal_status.turn_status, "errored"))
    {
        return error.ParentMaterializationFailed;
    }
}

fn appendNativeReviewArgs(allocator: std.mem.Allocator, args: *std.ArrayList([]const u8), target: TargetRecord) !void {
    if (std.mem.eql(u8, target.type, "uncommittedChanges")) {
        try args.append(allocator, "--uncommitted");
        return;
    }
    if (std.mem.eql(u8, target.type, "baseBranch")) {
        try args.append(allocator, "--base");
        try args.append(allocator, target.branch.?);
        return;
    }
    if (std.mem.eql(u8, target.type, "commit")) {
        try args.append(allocator, "--commit");
        try args.append(allocator, target.sha.?);
        if (target.title) |title| {
            try args.append(allocator, "--title");
            try args.append(allocator, title);
        }
        return;
    }
    if (std.mem.eql(u8, target.type, "custom")) {
        try args.append(allocator, target.instructions.?);
        return;
    }
}

fn runNativeReviewFallbackAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    codex_path: []const u8,
    target: TargetRecord,
) !NativeFallbackResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, codex_path);
    try argv.append(allocator, "review");
    try appendNativeReviewArgs(allocator, &argv, target);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout_bytes = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr_bytes = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(@min(code, 255)),
        else => 1,
    };
    return .{
        .exit_code = exit_code,
        .ok = exit_code == 0,
        .stdout_text = if (stdout_bytes.len > 0) stdout_bytes else blk: {
            allocator.free(stdout_bytes);
            break :blk null;
        },
        .stderr_text = if (stderr_bytes.len > 0) stderr_bytes else blk: {
            allocator.free(stderr_bytes);
            break :blk null;
        },
    };
}

fn isTerminalTurnStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "completed") or
        std.mem.eql(u8, status, "interrupted") or
        std.mem.eql(u8, status, "failed") or
        std.mem.eql(u8, status, "errored");
}

fn waitForReviewCompletion(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    review_thread_id: []const u8,
    event_log_path: []const u8,
    timeout_ms: u32,
    poll_interval_ms: u32,
) !ReviewStatus {
    const started_ms = std.time.milliTimestamp();
    while (true) {
        const latest = try fetchReviewStatus(allocator, client, review_thread_id, event_log_path);
        if (isTerminalTurnStatus(latest.turn_status) and latest.review_result_available) return latest;
        if (isTerminalTurnStatus(latest.turn_status) and !latest.review_result_available) {
            latest.deinit(allocator);
            return error.ReviewResultUnavailable;
        }
        if (std.time.milliTimestamp() - started_ms >= timeout_ms) return error.WaitTimedOut;
        std.Thread.sleep(@as(u64, poll_interval_ms) * std.time.ns_per_ms);
    }
}

fn startParentThreadAlloc(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    cwd: []const u8,
    session_dir: []const u8,
) ![]const u8 {
    const params_json = try stringifyAnyAlloc(allocator, .{
        .cwd = cwd,
        .experimentalRawEvents = false,
    });
    defer allocator.free(params_json);
    const result_json = try client.requestJson("thread/start", params_json);
    defer allocator.free(result_json);
    const parent_thread_id = try extractStartedThreadIdAlloc(allocator, result_json);
    const parent_event_log_path = try std.fs.path.join(allocator, &.{ session_dir, "parent-thread.ndjson" });
    try appendLogRecord(allocator, parent_event_log_path, "thread/start", "request", params_json);
    try appendLogRecord(allocator, parent_event_log_path, "thread/start", "response", result_json);
    return parent_thread_id;
}

fn resumeParentThread(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    parent_thread_id: []const u8,
    session_dir: []const u8,
) !void {
    const params_json = try stringifyAnyAlloc(allocator, .{
        .threadId = parent_thread_id,
    });
    defer allocator.free(params_json);
    const result_json = try client.requestJson("thread/resume", params_json);
    defer allocator.free(result_json);
    const parent_event_log_path = try std.fs.path.join(allocator, &.{ session_dir, "parent-thread.ndjson" });
    try appendLogRecord(allocator, parent_event_log_path, "thread/resume", "request", params_json);
    try appendLogRecord(allocator, parent_event_log_path, "thread/resume", "response", result_json);
}

fn extractStartedThreadIdAlloc(allocator: std.mem.Allocator, raw_json: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    const thread_obj = core_json.objectField(root_obj, "thread") orelse return error.MissingThread;
    const id = core_json.stringField(thread_obj, "id") orelse return error.MissingThreadId;
    return allocator.dupe(u8, id);
}

fn extractReviewThreadIdAlloc(allocator: std.mem.Allocator, raw_json: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    const review_thread_id = core_json.stringField(root_obj, "reviewThreadId") orelse return error.MissingReviewThreadId;
    return allocator.dupe(u8, review_thread_id);
}

fn extractReviewTurnIdAlloc(allocator: std.mem.Allocator, raw_json: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    const turn_obj = core_json.objectField(root_obj, "turn") orelse return error.MissingTurn;
    const turn_id = core_json.stringField(turn_obj, "id") orelse return error.MissingTurnId;
    return allocator.dupe(u8, turn_id);
}

fn buildReviewStartParamsJson(
    allocator: std.mem.Allocator,
    parent_thread_id: []const u8,
    target: TargetConfig,
) ![]u8 {
    const target_json = try buildTargetJson(allocator, target);
    defer allocator.free(target_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"threadId\":{s},\"delivery\":\"detached\",\"target\":{s}}}",
        .{ try quoteJsonStringAlloc(allocator, parent_thread_id), target_json },
    );
}

fn buildTargetJson(allocator: std.mem.Allocator, target: TargetConfig) ![]u8 {
    return switch (target.kind) {
        .uncommitted => stringifyAnyAlloc(allocator, .{ .type = "uncommittedChanges" }),
        .base_branch => stringifyAnyAlloc(allocator, .{ .type = "baseBranch", .branch = target.branch.? }),
        .commit => stringifyAnyAlloc(allocator, .{ .type = "commit", .sha = target.sha.?, .title = target.title }),
        .custom => stringifyAnyAlloc(allocator, .{ .type = "custom", .instructions = target.instructions.? }),
    };
}

fn targetToRecord(target: TargetConfig) TargetRecord {
    return .{
        .type = target.kind.asString(),
        .branch = target.branch,
        .sha = target.sha,
        .title = target.title,
        .instructions = target.instructions,
    };
}

fn sessionDirAlloc(allocator: std.mem.Allocator) ![]const u8 {
    const base = try core_path.expandHomePath(allocator, "~/.codex/cas/review_sessions");
    try ensureParentPath(base);
    try std.fs.cwd().makePath(base);
    return base;
}

const LoadedSessionRecord = struct {
    record_path: []const u8,
    record: SessionRecord,
};

fn loadSessionRecord(allocator: std.mem.Allocator, review_thread_id: []const u8) !LoadedSessionRecord {
    const session_dir = try sessionDirAlloc(allocator);
    const record_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, review_thread_id });
    const file = try std.fs.openFileAbsolute(record_path, .{});
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
    const parsed = try std.json.parseFromSlice(SessionRecord, allocator, raw, .{});
    return .{
        .record_path = record_path,
        .record = parsed.value,
    };
}

fn writeSessionRecord(allocator: std.mem.Allocator, path: []const u8, record: SessionRecord) !void {
    try ensureParentPath(path);
    const json = try stringifyAnyAlloc(allocator, record);
    defer allocator.free(json);
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(json);
    try file.writeAll("\n");
}

fn appendLogRecord(
    allocator: std.mem.Allocator,
    path: []const u8,
    method: []const u8,
    direction: []const u8,
    payload_json: []const u8,
) !void {
    const json_line = try std.fmt.allocPrint(
        allocator,
        "{{\"recordedAtUnixS\":{d},\"method\":{s},\"direction\":{s},\"payload\":{s}}}",
        .{
            std.time.timestamp(),
            try quoteJsonStringAlloc(allocator, method),
            try quoteJsonStringAlloc(allocator, direction),
            try quoteJsonStringAlloc(allocator, payload_json),
        },
    );
    defer allocator.free(json_line);
    try ensureParentPath(path);
    var file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.createFileAbsolute(path, .{ .truncate = false }),
        else => return err,
    };
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(json_line);
    try file.writeAll("\n");
}

fn ensureParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;

    if (std.fs.path.isAbsolute(parent)) {
        const rel = std.mem.trimLeft(u8, parent, "/");
        if (rel.len == 0) return;
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        try root.makePath(rel);
        return;
    }

    try std.fs.cwd().makePath(parent);
}

fn renderErrorAndExit(
    json_mode: bool,
    action: []const u8,
    method: []const u8,
    message: []const u8,
    cwd: ?[]const u8,
    receipt: OutputReceipt,
    failure: FailureInfo,
) !noreturn {
    if (json_mode) {
        const payload = .{
            .demo = "cas-review-session",
            .action = action,
            .method = method,
            .cwd = cwd,
            .resolvedCodexPath = receipt.resolved_codex_path,
            .resolvedCodexVersion = receipt.resolved_codex_version,
            .compatibilityVerdict = receipt.compatibility_verdict,
            .failureCode = failure.code,
            .failureHint = failure.hint,
            .@"error" = message,
        };
        try printJson(payload);
    } else {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}: {s} ({s})\n", .{ method, message, failure.code });
    }
    std.process.exit(1);
}

fn maybeRunNativeFallbackAndExitStart(
    allocator: std.mem.Allocator,
    parsed: ParsedArgs,
    cwd: []const u8,
    codex_path: []const u8,
    parent_thread_id: []const u8,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    target_record: TargetRecord,
    record_path: []const u8,
    event_log_path: []const u8,
    receipt: OutputReceipt,
    status: ?ReviewStatus,
    timed_out: bool,
    waited: bool,
    failure: FailureInfo,
) !void {
    if (parsed.fallback_mode != .native_review) return;

    var fallback = try runNativeReviewFallbackAlloc(allocator, cwd, codex_path, target_record);
    defer fallback.deinit(allocator);

    if (parsed.json) {
        try printStartJson(
            allocator,
            cwd,
            parent_thread_id,
            review_thread_id,
            review_turn_id,
            target_record,
            record_path,
            event_log_path,
            receipt,
            status,
            timed_out,
            waited,
            failure,
            fallback,
        );
    } else if (fallback.stdout_text) |text| {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(text);
        if (!std.mem.endsWith(u8, text, "\n")) try stdout.writeAll("\n");
    }

    if (fallback.stderr_text) |text| {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.writeAll(text);
        if (!std.mem.endsWith(u8, text, "\n")) try stderr.writeAll("\n");
    }
    std.process.exit(if (fallback.ok) 0 else 1);
}

fn maybeRunNativeFallbackAndExitWait(
    allocator: std.mem.Allocator,
    parsed: ParsedArgs,
    record: SessionRecord,
    record_path: []const u8,
    status: ReviewStatus,
    failure: FailureInfo,
) !void {
    if (parsed.fallback_mode != .native_review) return;

    const codex_path = record.resolved_codex_path orelse "codex";
    var fallback = try runNativeReviewFallbackAlloc(allocator, record.cwd, codex_path, record.target);
    defer fallback.deinit(allocator);

    if (parsed.json) {
        try printStatusJson(
            allocator,
            .wait,
            record.cwd,
            record.parent_thread_id,
            record.review_thread_id,
            record.review_turn_id,
            status,
            record_path,
            record.event_log_path,
            .{
                .resolved_codex_path = record.resolved_codex_path,
                .resolved_codex_version = record.codex_version,
                .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
            },
            null,
            false,
            failure,
            fallback,
        );
    } else if (fallback.stdout_text) |text| {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(text);
        if (!std.mem.endsWith(u8, text, "\n")) try stdout.writeAll("\n");
    }

    if (fallback.stderr_text) |text| {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        try stderr.writeAll(text);
        if (!std.mem.endsWith(u8, text, "\n")) try stderr.writeAll("\n");
    }
    std.process.exit(if (fallback.ok) 0 else 1);
}

fn readCodexVersionAlloc(allocator: std.mem.Allocator, cwd: []const u8, codex_path: []const u8) ![]const u8 {
    var child = std.process.Child.init(&.{ codex_path, "--version" }, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 4096);
    _ = try child.wait();
    return allocator.dupe(u8, std.mem.trim(u8, stdout, " \t\r\n"));
}

fn quoteJsonStringAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(text, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn stringifyAnyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn printJson(value: anytype) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeAll("\n");
}

const StatusAction = enum {
    status,
    wait,
};

fn printStatusJson(
    allocator: std.mem.Allocator,
    action: StatusAction,
    cwd: ?[]const u8,
    parent_thread_id: ?[]const u8,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    status: ReviewStatus,
    record_path: ?[]const u8,
    event_log_path: []const u8,
    receipt: OutputReceipt,
    timeout_ms: ?u32,
    timed_out: ?bool,
    failure: ?FailureInfo,
    fallback: ?NativeFallbackResult,
) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    const cwd_json = if (cwd) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const parent_thread_json = if (parent_thread_id) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const rollout_path_json = if (status.rollout_path) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const record_path_json = if (record_path) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const review_result_source_json = if (status.review_result_source) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const review_result_json = status.review_result_json orelse "null";
    const resolved_codex_path_json = if (receipt.resolved_codex_path) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const resolved_codex_version_json = if (receipt.resolved_codex_version) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const failure_code_json = if (failure) |value| try quoteJsonStringAlloc(allocator, value.code) else "null";
    const failure_hint_json = if (failure) |value| try quoteJsonStringAlloc(allocator, value.hint) else "null";
    const fallback_transport_json = if (fallback != null) "\"native-review\"" else "null";
    const fallback_exit_code_json = if (fallback) |value|
        try std.fmt.allocPrint(allocator, "{d}", .{value.exit_code})
    else
        "null";
    const fallback_stdout_json = if (fallback) |value|
        if (value.stdout_text) |text| try quoteJsonStringAlloc(allocator, text) else "null"
    else
        "null";
    const fallback_stderr_json = if (fallback) |value|
        if (value.stderr_text) |text| try quoteJsonStringAlloc(allocator, text) else "null"
    else
        "null";
    const timeout_json = if (timeout_ms) |value|
        try std.fmt.allocPrint(allocator, "{d}", .{value})
    else
        "null";
    const timed_out_json = if (timed_out) |value|
        if (value) "true" else "false"
    else
        "null";

    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":\"{s}\",\"cwd\":{s},\"parentThreadId\":{s},\"reviewThreadId\":{s},\"reviewTurnId\":{s},\"threadStatus\":{s},\"turnStatus\":{s},\"turnCount\":{d},\"materialized\":{s},\"rolloutPath\":{s},\"recordPath\":{s},\"eventLogPath\":{s},\"resolvedCodexPath\":{s},\"resolvedCodexVersion\":{s},\"compatibilityVerdict\":{s},\"timeoutMs\":{s},\"timedOut\":{s},\"failureCode\":{s},\"failureHint\":{s},\"fallbackUsed\":{s},\"fallbackTransport\":{s},\"fallbackExitCode\":{s},\"fallbackOutputText\":{s},\"fallbackErrorText\":{s},\"reviewResultAvailable\":{s},\"reviewResultSource\":{s},\"reviewResult\":{s}}}\n",
        .{
            @tagName(action),
            cwd_json,
            parent_thread_json,
            try quoteJsonStringAlloc(allocator, review_thread_id),
            try quoteJsonStringAlloc(allocator, review_turn_id),
            try quoteJsonStringAlloc(allocator, status.thread_status),
            try quoteJsonStringAlloc(allocator, status.turn_status),
            status.turn_count,
            if (status.materialized) "true" else "false",
            rollout_path_json,
            record_path_json,
            try quoteJsonStringAlloc(allocator, event_log_path),
            resolved_codex_path_json,
            resolved_codex_version_json,
            try quoteJsonStringAlloc(allocator, receipt.compatibility_verdict),
            timeout_json,
            timed_out_json,
            failure_code_json,
            failure_hint_json,
            if (fallback != null) "true" else "false",
            fallback_transport_json,
            fallback_exit_code_json,
            fallback_stdout_json,
            fallback_stderr_json,
            if (status.review_result_available) "true" else "false",
            review_result_source_json,
            review_result_json,
        },
    );
}

fn printStartJson(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    parent_thread_id: []const u8,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    target_record: TargetRecord,
    record_path: []const u8,
    event_log_path: []const u8,
    receipt: OutputReceipt,
    status: ?ReviewStatus,
    timed_out: bool,
    waited: bool,
    failure: ?FailureInfo,
    fallback: ?NativeFallbackResult,
) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    const target_json = try stringifyAnyAlloc(allocator, target_record);
    const timed_out_json = if (timed_out) "true" else "false";
    const waited_json = if (waited) "true" else "false";
    const thread_status_json = if (status) |value| try quoteJsonStringAlloc(allocator, value.thread_status) else "null";
    const turn_status_json = if (status) |value| try quoteJsonStringAlloc(allocator, value.turn_status) else "null";
    const turn_count = if (status) |value| value.turn_count else 0;
    const materialized_json = if (status) |value|
        if (value.materialized) "true" else "false"
    else
        "null";
    const rollout_path_json = if (status) |value|
        if (value.rollout_path) |path| try quoteJsonStringAlloc(allocator, path) else "null"
    else
        "null";
    const review_result_available_json = if (status) |value|
        if (value.review_result_available) "true" else "false"
    else
        "null";
    const review_result_source_json = if (status) |value|
        if (value.review_result_source) |source| try quoteJsonStringAlloc(allocator, source) else "null"
    else
        "null";
    const review_result_json = if (status) |value| value.review_result_json orelse "null" else "null";
    const resolved_codex_path_json = if (receipt.resolved_codex_path) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const resolved_codex_version_json = if (receipt.resolved_codex_version) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const failure_code_json = if (failure) |value| try quoteJsonStringAlloc(allocator, value.code) else "null";
    const failure_hint_json = if (failure) |value| try quoteJsonStringAlloc(allocator, value.hint) else "null";
    const fallback_transport_json = if (fallback != null) "\"native-review\"" else "null";
    const fallback_exit_code_json = if (fallback) |value|
        try std.fmt.allocPrint(allocator, "{d}", .{value.exit_code})
    else
        "null";
    const fallback_stdout_json = if (fallback) |value|
        if (value.stdout_text) |text| try quoteJsonStringAlloc(allocator, text) else "null"
    else
        "null";
    const fallback_stderr_json = if (fallback) |value|
        if (value.stderr_text) |text| try quoteJsonStringAlloc(allocator, text) else "null"
    else
        "null";

    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":\"start\",\"cwd\":{s},\"parentThreadId\":{s},\"reviewThreadId\":{s},\"reviewTurnId\":{s},\"delivery\":\"detached\",\"target\":{s},\"recordPath\":{s},\"eventLogPath\":{s},\"codexVersion\":{s},\"resolvedCodexPath\":{s},\"resolvedCodexVersion\":{s},\"compatibilityVerdict\":{s},\"waited\":{s},\"timedOut\":{s},\"threadStatus\":{s},\"turnStatus\":{s},\"turnCount\":{d},\"materialized\":{s},\"rolloutPath\":{s},\"failureCode\":{s},\"failureHint\":{s},\"fallbackUsed\":{s},\"fallbackTransport\":{s},\"fallbackExitCode\":{s},\"fallbackOutputText\":{s},\"fallbackErrorText\":{s},\"reviewResultAvailable\":{s},\"reviewResultSource\":{s},\"reviewResult\":{s}}}\n",
        .{
            try quoteJsonStringAlloc(allocator, cwd),
            try quoteJsonStringAlloc(allocator, parent_thread_id),
            try quoteJsonStringAlloc(allocator, review_thread_id),
            try quoteJsonStringAlloc(allocator, review_turn_id),
            target_json,
            try quoteJsonStringAlloc(allocator, record_path),
            try quoteJsonStringAlloc(allocator, event_log_path),
            try quoteJsonStringAlloc(allocator, receipt.resolved_codex_version orelse ""),
            resolved_codex_path_json,
            resolved_codex_version_json,
            try quoteJsonStringAlloc(allocator, receipt.compatibility_verdict),
            waited_json,
            timed_out_json,
            thread_status_json,
            turn_status_json,
            turn_count,
            materialized_json,
            rollout_path_json,
            failure_code_json,
            failure_hint_json,
            if (fallback != null) "true" else "false",
            fallback_transport_json,
            fallback_exit_code_json,
            fallback_stdout_json,
            fallback_stderr_json,
            review_result_available_json,
            review_result_source_json,
            review_result_json,
        },
    );
}

fn failureInfoForReviewStart(raw_message: []const u8, created_parent_thread: bool) ?FailureInfo {
    if (created_parent_thread and std.mem.indexOf(u8, raw_message, "no rollout found for thread id") != null) {
        return .{
            .code = "incompatible_codex_review_runtime",
            .hint = "detached review on a freshly created parent thread requires a newer codex build; upgrade codex or supply --parent-thread-id for a materialized parent thread",
        };
    }
    if (created_parent_thread and
        std.mem.indexOf(u8, raw_message, "error creating detached review thread") != null and
        std.mem.indexOf(u8, raw_message, "(os error 2)") != null)
    {
        return .{
            .code = "incompatible_codex_review_runtime",
            .hint = "detached review on this codex build is incompatible with fresh parent-thread startup; upgrade codex or supply --parent-thread-id for a materialized parent thread",
        };
    }
    return null;
}

fn failureInfoForStatus(status: *const ReviewStatus) ?FailureInfo {
    if (isTerminalTurnStatus(status.turn_status) and !status.review_result_available) {
        if (std.mem.eql(u8, status.thread_preview, parent_materialization_prompt) and
            !status.last_turn_has_entered_review_mode)
        {
            return .{
                .code = "incompatible_codex_review_runtime",
                .hint = "detached review resolved to the fresh-parent bootstrap thread instead of a review-mode thread; installed codex runtime is not producing a usable detached review thread on this path",
            };
        }
        if (std.mem.eql(u8, status.turn_status, "interrupted")) {
            return .{
                .code = "review_interrupted",
                .hint = "detached review was interrupted before a materialized reviewResult was written",
            };
        }
        if (status.turn_error_message) |message| {
            if (std.mem.indexOf(u8, message, "approval") != null or
                std.mem.indexOf(u8, message, "permission") != null or
                std.mem.indexOf(u8, message, "denied") != null)
            {
                return .{
                    .code = "approval_denied",
                    .hint = "detached review stopped on an approval or permissions denial before emitting a structured reviewResult",
                };
            }
        }
        if (std.mem.eql(u8, status.turn_status, "failed") or std.mem.eql(u8, status.turn_status, "errored")) {
            return .{
                .code = "review_failed",
                .hint = "detached review ended in a failed or errored state before emitting a structured reviewResult",
            };
        }
        return .{
            .code = "review_output_missing",
            .hint = "detached review reached terminal status without a materialized reviewResult",
        };
    }
    return null;
}

fn timeoutStatusString(status: *const ReviewStatus) []const u8 {
    return status.turn_status;
}

fn readReviewResultJsonFromRolloutAlloc(allocator: std.mem.Allocator, rollout_path: []const u8) !?[]u8 {
    const file = try std.fs.openFileAbsolute(rollout_path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);

    var latest_json: ?[]u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();

        const root_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        const line_type = core_json.stringField(root_obj, "type") orelse continue;
        if (!std.mem.eql(u8, line_type, "event_msg")) continue;

        const payload_obj = core_json.objectField(root_obj, "payload") orelse continue;
        const payload_type = core_json.stringField(payload_obj, "type") orelse continue;
        if (!std.mem.eql(u8, payload_type, "exited_review_mode")) continue;

        const review_output = payload_obj.get("review_output") orelse continue;
        const review_output_obj = switch (review_output) {
            .object => |obj| obj,
            else => continue,
        };
        latest_json = try buildReviewResultJsonAlloc(allocator, review_output_obj);
    }

    return latest_json;
}

fn buildReviewResultJsonAlloc(allocator: std.mem.Allocator, review_output_obj: std.json.ObjectMap) ![]u8 {
    var findings = std.ArrayList(ReviewFindingJson).empty;
    defer findings.deinit(allocator);

    if (review_output_obj.get("findings")) |findings_value| switch (findings_value) {
        .array => |arr| {
            for (arr.items) |item| {
                const finding_obj = switch (item) {
                    .object => |obj| obj,
                    else => continue,
                };
                const code_location_obj = core_json.objectField(finding_obj, "code_location") orelse continue;
                const line_range_obj = core_json.objectField(code_location_obj, "line_range") orelse continue;
                try findings.append(allocator, .{
                    .title = core_json.stringField(finding_obj, "title") orelse "",
                    .body = core_json.stringField(finding_obj, "body") orelse "",
                    .confidenceScore = floatField(finding_obj, "confidence_score") orelse 0.0,
                    .priority = @intCast(core_json.intField(finding_obj, "priority") orelse 0),
                    .codeLocation = .{
                        .absoluteFilePath = core_json.stringField(code_location_obj, "absolute_file_path") orelse "",
                        .lineRange = .{
                            .start = @intCast(core_json.intField(line_range_obj, "start") orelse 0),
                            .end = @intCast(core_json.intField(line_range_obj, "end") orelse 0),
                        },
                    },
                });
            }
        },
        else => {},
    };

    const payload = ReviewResultJson{
        .findings = try findings.toOwnedSlice(allocator),
        .overallCorrectness = core_json.stringField(review_output_obj, "overall_correctness") orelse "",
        .overallExplanation = core_json.stringField(review_output_obj, "overall_explanation") orelse "",
        .overallConfidenceScore = floatField(review_output_obj, "overall_confidence_score") orelse 0.0,
    };
    defer allocator.free(payload.findings);
    return stringifyAnyAlloc(allocator, payload);
}

fn floatField(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .float => |f| @floatCast(f),
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

test "parseArgs accepts detached start target" {
    const argv = [_][]const u8{
        "cas_review_session",
        "start",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Action.start, parsed.action.?);
    try std.testing.expectEqualStrings("/tmp/repo", parsed.cwd.?);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(TargetKind.base_branch, parsed.target.?.kind);
    try std.testing.expectEqualStrings("main", parsed.target.?.branch.?);
}

test "parseArgs captures start --wait" {
    const argv = [_][]const u8{
        "cas_review_session",
        "start",
        "--wait",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expect(parsed.wait_after_start);
    try std.testing.expectEqual(Action.start, parsed.action.?);
    try std.testing.expectEqual(TargetKind.base_branch, parsed.target.?.kind);
}

test "parseArgs captures parent mode approvals and fallback" {
    const argv = [_][]const u8{
        "cas_review_session",
        "start",
        "--cwd",
        "/tmp/repo",
        "--parent-thread-id",
        "thr_parent",
        "--parent-mode",
        "reuse",
        "--uncommitted",
        "--exec-approval",
        "decline",
        "--file-approval",
        "acceptForSession",
        "--permissions-approval",
        "grant-session",
        "--request-user-input-response-json",
        "{\"answers\":{}}",
        "--elicitation-action",
        "accept",
        "--elicitation-content-json",
        "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"ok\"}]}",
        "--dynamic-tool-response-json",
        "{\"success\":true,\"contentItems\":[]}",
        "--fallback",
        "native-review",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(ParentMode.reuse, parsed.parent_mode);
    try std.testing.expectEqual(FallbackMode.native_review, parsed.fallback_mode);
    try std.testing.expectEqualStrings("thr_parent", parsed.parent_thread_id.?);
    try std.testing.expectEqualStrings("decline", parsed.exec_approval.?);
    try std.testing.expectEqualStrings("acceptForSession", parsed.file_approval.?);
    try std.testing.expectEqualStrings("grant-session", parsed.permissions_approval.?);
}

test "parseReviewStatusAlloc handles materialized and pending states" {
    const materialized = try parseReviewStatusAlloc(
        std.testing.allocator,
        "{\"thread\":{\"status\":\"running\",\"turns\":[{\"status\":\"inProgress\"}]}}",
        true,
    );
    defer materialized.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("running", materialized.thread_status);
    try std.testing.expectEqualStrings("inProgress", materialized.turn_status);
    try std.testing.expectEqual(@as(usize, 1), materialized.turn_count);
    try std.testing.expect(materialized.materialized);

    const pending = try parseReviewStatusAlloc(
        std.testing.allocator,
        "{\"thread\":{\"status\":\"running\"}}",
        false,
    );
    defer pending.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("running", pending.thread_status);
    try std.testing.expectEqualStrings("materializing", pending.turn_status);
    try std.testing.expectEqual(@as(usize, 0), pending.turn_count);
    try std.testing.expect(!pending.materialized);
}

test "readReviewResultJsonFromRolloutAlloc extracts exited review output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        \\{"type":"session_meta","payload":{"id":"thr_1"}}
        \\{"type":"event_msg","payload":{"type":"entered_review_mode","user_facing_hint":"current changes"}}
        \\{"type":"event_msg","payload":{"type":"exited_review_mode","review_output":{"findings":[{"title":"Prefer helper","body":"Use the helper.","confidence_score":0.75,"priority":1,"code_location":{"absolute_file_path":"/tmp/file.zig","line_range":{"start":7,"end":9}}}],"overall_correctness":"patch is correct","overall_explanation":"Looks good.","overall_confidence_score":0.9}}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "rollout.jsonl", .data = rollout });

    const rollout_path = try tmp.dir.realpathAlloc(std.testing.allocator, "rollout.jsonl");
    defer std.testing.allocator.free(rollout_path);

    const json = (try readReviewResultJsonFromRolloutAlloc(std.testing.allocator, rollout_path)).?;
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    const findings = root_obj.get("findings").?.array;
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqualStrings("patch is correct", core_json.stringField(root_obj, "overallCorrectness").?);
    try std.testing.expectEqualStrings("Looks good.", core_json.stringField(root_obj, "overallExplanation").?);
    try std.testing.expectEqual(@as(f32, 0.9), floatField(root_obj, "overallConfidenceScore").?);

    const first = findings.items[0].object;
    try std.testing.expectEqualStrings("Prefer helper", core_json.stringField(first, "title").?);
    try std.testing.expectEqualStrings("Use the helper.", core_json.stringField(first, "body").?);
    try std.testing.expectEqual(@as(f32, 0.75), floatField(first, "confidenceScore").?);
    const code_location = core_json.objectField(first, "codeLocation").?;
    try std.testing.expectEqualStrings("/tmp/file.zig", core_json.stringField(code_location, "absoluteFilePath").?);
}

test "readReviewResultJsonFromRolloutAlloc returns null when review output is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        \\{"type":"event_msg","payload":{"type":"entered_review_mode","user_facing_hint":"current changes"}}
        \\{"type":"event_msg","payload":{"type":"exited_review_mode","review_output":null}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "rollout.jsonl", .data = rollout });

    const rollout_path = try tmp.dir.realpathAlloc(std.testing.allocator, "rollout.jsonl");
    defer std.testing.allocator.free(rollout_path);

    try std.testing.expect((try readReviewResultJsonFromRolloutAlloc(std.testing.allocator, rollout_path)) == null);
}

test "failureInfoForReviewStart maps detached parent rollout error" {
    const failure = failureInfoForReviewStart("no rollout found for thread id thr_123", true).?;
    try std.testing.expectEqualStrings("incompatible_codex_review_runtime", failure.code);
}

test "failureInfoForStatus flags missing terminal review result" {
    var status = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "loaded"),
        .turn_status = try std.testing.allocator.dupe(u8, "completed"),
        .turn_count = 1,
        .materialized = true,
        .thread_preview = try std.testing.allocator.dupe(u8, ""),
        .rollout_path = null,
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = false,
        .last_turn_has_exited_review_mode = false,
        .review_result_available = false,
        .review_result_source = null,
        .review_result_json = null,
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);

    const failure = failureInfoForStatus(&status).?;
    try std.testing.expectEqualStrings("review_output_missing", failure.code);
}

test "failureInfoForStatus maps interrupted and approval failures" {
    var interrupted = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "idle"),
        .turn_status = try std.testing.allocator.dupe(u8, "interrupted"),
        .turn_count = 1,
        .materialized = true,
        .thread_preview = try std.testing.allocator.dupe(u8, ""),
        .rollout_path = null,
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = true,
        .last_turn_has_exited_review_mode = false,
        .review_result_available = false,
        .review_result_source = null,
        .review_result_json = null,
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer interrupted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("review_interrupted", failureInfoForStatus(&interrupted).?.code);

    var denied = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "idle"),
        .turn_status = try std.testing.allocator.dupe(u8, "failed"),
        .turn_count = 1,
        .materialized = true,
        .thread_preview = try std.testing.allocator.dupe(u8, ""),
        .rollout_path = null,
        .turn_error_message = try std.testing.allocator.dupe(u8, "permission denied by approval policy"),
        .last_turn_has_entered_review_mode = false,
        .last_turn_has_exited_review_mode = false,
        .review_result_available = false,
        .review_result_source = null,
        .review_result_json = null,
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer denied.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("approval_denied", failureInfoForStatus(&denied).?.code);
}

test "failureInfoForParentReuse rejects unsafe parents" {
    var parent = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "idle"),
        .turn_status = try std.testing.allocator.dupe(u8, "interrupted"),
        .turn_count = 1,
        .materialized = true,
        .thread_preview = try std.testing.allocator.dupe(u8, ""),
        .rollout_path = try std.testing.allocator.dupe(u8, "/tmp/rollout.jsonl"),
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = true,
        .last_turn_has_exited_review_mode = false,
        .review_result_available = false,
        .review_result_source = null,
        .review_result_json = null,
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer parent.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("unsafe_parent_thread_state", failureInfoForParentReuse(&parent).?.code);
}

test "failureInfoForStatus flags bootstrap-thread substitution as incompatible runtime" {
    var status = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "idle"),
        .turn_status = try std.testing.allocator.dupe(u8, "completed"),
        .turn_count = 1,
        .materialized = true,
        .thread_preview = try std.testing.allocator.dupe(u8, parent_materialization_prompt),
        .rollout_path = try std.testing.allocator.dupe(u8, "/tmp/bootstrap-rollout.jsonl"),
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = false,
        .last_turn_has_exited_review_mode = false,
        .review_result_available = false,
        .review_result_source = null,
        .review_result_json = null,
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);

    const failure = failureInfoForStatus(&status).?;
    try std.testing.expectEqualStrings("incompatible_codex_review_runtime", failure.code);
}
