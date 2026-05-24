const app_meta = @import("app_meta");
const cas = @import("cas_proxy_client.zig");
const cas_websocket = @import("cas_websocket_transport.zig");
const core_cli = @import("core_cli");
const core_json = @import("core_json");
const core_path = @import("core_path");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas_review_session",
    .help_text = UsageText,
};

const UsageText =
    \\cas_review_session
    \\
    \\Control detached Codex review sessions via the app-server.
    \\
    \\Usage:
    \\  cas_review_session <start|status|wait|interrupt|lane|receipt> [options]
    \\
    \\Actions:
    \\  start      Start a detached review session and persist its handle.
    \\  status     Read the persisted session and report current review status.
    \\  wait       Poll the persisted session until the review turn reaches a terminal status.
    \\  interrupt  Interrupt the persisted detached review turn.
    \\  lane       Reuse one managed app-server for multiple fresh-parent reviews.
    \\  receipt    Summarize saved CAS review receipts without touching review state.
    \\
    \\Lane actions:
    \\  lane start   Start a reusable review lane.
    \\  lane review  Run one fresh-parent review through the lane and archive review threads.
    \\  lane status  Report whether the lane app-server process is still alive.
    \\  lane stop    Stop the lane app-server process.
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
    \\  --hooks MODE                     Hook policy: inherit|off|require-observed (default: inherit).
    \\  --fallback MODE                  none|native-review (default: none).
    \\
    \\Status/wait/interrupt options:
    \\  --review-thread-id THREAD_ID     Detached review thread id handle.
    \\
    \\Lane options:
    \\  --lane-id LANE_ID                Lane handle for lane review/status/stop.
    \\  --no-archive                     Do not best-effort archive lane review threads.
    \\
    \\Common options:
    \\  --json                           Emit machine-readable JSON.
    \\  --verdict-only                   Emit only the compact reviewVerdict JSON for lane review.
    \\  --path FILE                      Receipt file to summarize; repeatable for receipt.
    \\  --glob PATTERN                   Simple receipt glob; repeatable for receipt.
    \\  --format FORMAT                  Receipt output: table|json|jsonl (default: table).
    \\  --summary                        Include aggregate receipt counts.
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
    \\  cas review_session lane start --cwd /path/to/repo --json
    \\  cas review_session lane review --lane-id lane_123 --base main --json
    \\  cas review_session receipt --path review-1.json --format table --summary
    \\  cas review_session lane stop --lane-id lane_123 --json
;

const Action = enum {
    start,
    status,
    wait,
    interrupt,
    lane,
    receipt,

    fn parse(raw: []const u8) ?Action {
        if (std.mem.eql(u8, raw, "start")) return .start;
        if (std.mem.eql(u8, raw, "status")) return .status;
        if (std.mem.eql(u8, raw, "wait")) return .wait;
        if (std.mem.eql(u8, raw, "interrupt")) return .interrupt;
        if (std.mem.eql(u8, raw, "lane")) return .lane;
        if (std.mem.eql(u8, raw, "receipt")) return .receipt;
        return null;
    }
};

const LaneAction = enum {
    start,
    review,
    status,
    stop,

    fn parse(raw: []const u8) ?LaneAction {
        if (std.mem.eql(u8, raw, "start")) return .start;
        if (std.mem.eql(u8, raw, "review")) return .review;
        if (std.mem.eql(u8, raw, "status")) return .status;
        if (std.mem.eql(u8, raw, "stop")) return .stop;
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

const ReceiptFormat = enum {
    table,
    json,
    jsonl,

    fn parse(raw: []const u8) ?ReceiptFormat {
        if (std.mem.eql(u8, raw, "table")) return .table;
        if (std.mem.eql(u8, raw, "json")) return .json;
        if (std.mem.eql(u8, raw, "jsonl")) return .jsonl;
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
    lane_action: ?LaneAction = null,
    cwd: ?[]const u8 = null,
    lane_id: ?[]const u8 = null,
    parent_thread_id: ?[]const u8 = null,
    parent_mode: ParentMode = .auto,
    review_thread_id: ?[]const u8 = null,
    target: ?TargetConfig = null,
    wait_after_start: bool = false,
    archive_lane_threads: bool = true,
    json: bool = false,
    verdict_only: bool = false,
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
    hook_policy: cas.hooks.HookPolicy = .inherit,
    fallback_mode: FallbackMode = .none,
    receipt_paths: []const []const u8 = &.{},
    receipt_globs: []const []const u8 = &.{},
    receipt_format: ReceiptFormat = .table,
    receipt_summary: bool = false,
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
    schema_version: u32 = 3,
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
    transport_kind: ?[]const u8 = null,
    transport_selection_reason: ?[]const u8 = null,
    managed_server_pid: ?u64 = null,
    managed_server_listen_url: ?[]const u8 = null,
    managed_server_stderr_log_path: ?[]const u8 = null,
    orphan_ttl_seconds: ?u32 = null,
    terminal_review_result_source: ?[]const u8 = null,
    terminal_review_result_json: ?[]const u8 = null,
    terminal_fallback_transport: ?[]const u8 = null,
    terminal_fallback_exit_code: ?u8 = null,
    terminal_fallback_output_text: ?[]const u8 = null,
    terminal_fallback_error_text: ?[]const u8 = null,
    hook_policy: ?[]const u8 = null,
    hook_log_path: ?[]const u8 = null,
};

const LaneRecord = struct {
    schema_version: u32 = 1,
    lane_id: []const u8,
    cwd: []const u8,
    created_at_unix_s: i64,
    last_used_at_unix_s: i64,
    status: []const u8,
    review_count: u32 = 0,
    codex_version: []const u8,
    resolved_codex_path: []const u8,
    transport_kind: []const u8 = "websocket",
    transport_selection_reason: []const u8 = "persistent_review_lane",
    managed_server_pid: u64,
    managed_server_listen_url: []const u8,
    orphan_ttl_seconds: u32 = managed_server_orphan_ttl_seconds,
    hook_policy: []const u8,
    last_review_thread_id: ?[]const u8 = null,
    last_review_turn_id: ?[]const u8 = null,
    last_record_path: ?[]const u8 = null,
    last_event_log_path: ?[]const u8 = null,
    last_target_fingerprint: ?[]const u8 = null,
    last_head_sha: ?[]const u8 = null,
    last_base_sha: ?[]const u8 = null,
    last_dual_parse_verdict: ?[]const u8 = null,
    last_archive_status: ?[]const u8 = null,
};

const OutputReceipt = struct {
    resolved_codex_path: ?[]const u8 = null,
    resolved_codex_version: ?[]const u8 = null,
    compatibility_verdict: []const u8 = "not_checked",
    selected_transport: []const u8 = "stdio",
    selection_reason: []const u8 = "default_stdio",
    degraded_fallback: bool = false,
    managed_server_pid: ?u64 = null,
    managed_server_listen_url: ?[]const u8 = null,
    managed_server_stderr_log_path: ?[]const u8 = null,
    orphan_ttl_seconds: ?u32 = null,
    hook_policy: cas.hooks.HookPolicy = .inherit,
    hook_log_path: ?[]const u8 = null,
};

const FailureInfo = struct {
    code: []const u8,
    hint: []const u8,
};

const SemverTriplet = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

const parent_materialization_prompt =
    "Internal bootstrap for detached review parent materialization. Reply with OK only.";
const review_fallback_text = "Reviewer failed to output a response.";
const managed_server_orphan_ttl_seconds: u32 = 15 * 60;

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
    review_text: ?[]const u8 = null,
    raw_response_json: []const u8,

    fn deinit(self: ReviewStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.thread_status);
        allocator.free(self.turn_status);
        allocator.free(self.thread_preview);
        if (self.rollout_path) |path| allocator.free(path);
        if (self.turn_error_message) |message| allocator.free(message);
        if (self.review_result_json) |json| allocator.free(json);
        if (self.review_text) |text| allocator.free(text);
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

const TargetIdentity = struct {
    head_sha: ?[]const u8,
    base_sha: ?[]const u8,
    fingerprint: []const u8,

    fn deinit(self: TargetIdentity, allocator: std.mem.Allocator) void {
        if (self.head_sha) |value| allocator.free(value);
        if (self.base_sha) |value| allocator.free(value);
        allocator.free(self.fingerprint);
    }
};

const DualParseVerdict = struct {
    verdict: []const u8,
    structured_findings: usize,
    raw_findings: ?usize,
    raw_review_text_available: bool,

    fn deinit(self: DualParseVerdict, allocator: std.mem.Allocator) void {
        allocator.free(self.verdict);
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

const LiveReviewNotificationState = struct {
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    review_text: ?[]u8 = null,
    observed_terminal_status: ?[]const u8 = null,
    observed_turn_error_message: ?[]u8 = null,
    saw_entered_review_mode: bool = false,
    saw_exited_review_mode: bool = false,

    fn deinit(self: *LiveReviewNotificationState, allocator: std.mem.Allocator) void {
        if (self.review_text) |text| allocator.free(text);
        if (self.observed_turn_error_message) |text| allocator.free(text);
        self.review_text = null;
        self.observed_turn_error_message = null;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;

    const parsed = parseArgs(allocator, argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };

    if (parsed.show_version) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }

    if (parsed.show_help or parsed.action == null) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    switch (parsed.action.?) {
        .start => try cmdStart(allocator, init.io, parsed),
        .status => try cmdStatus(allocator, init.io, parsed),
        .wait => try cmdWait(allocator, init.io, parsed),
        .interrupt => try cmdInterrupt(allocator, init.io, parsed),
        .lane => try cmdLane(allocator, init.io, parsed),
        .receipt => try cmdReceipt(allocator, parsed),
    }
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    var out = ParsedArgs{};
    var receipt_paths: std.ArrayList([]const u8) = .empty;
    var receipt_globs: std.ArrayList([]const u8) = .empty;
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
    if (out.action.? == .lane) {
        if (i >= argv.len) return error.MissingLaneAction;
        out.lane_action = LaneAction.parse(argv[i]) orelse return error.UnknownLaneAction;
        i += 1;
    }

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
        if (std.mem.eql(u8, arg, "--verdict-only")) {
            out.verdict_only = true;
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
        if (std.mem.eql(u8, arg, "--no-archive")) {
            out.archive_lane_threads = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--summary")) {
            out.receipt_summary = true;
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
        if (std.mem.eql(u8, arg, "--lane-id")) {
            out.lane_id = value;
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
        if (std.mem.eql(u8, arg, "--hooks")) {
            out.hook_policy = cas.hooks.HookPolicy.parse(value) orelse return error.InvalidHooksPolicy;
            continue;
        }
        if (std.mem.eql(u8, arg, "--fallback")) {
            out.fallback_mode = FallbackMode.parse(value) orelse return error.InvalidFallbackMode;
            continue;
        }
        if (std.mem.eql(u8, arg, "--path")) {
            try receipt_paths.append(allocator, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--glob")) {
            try receipt_globs.append(allocator, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            out.receipt_format = ReceiptFormat.parse(value) orelse return error.InvalidReceiptFormat;
            continue;
        }
        return error.UnknownArg;
    }

    out.receipt_paths = try receipt_paths.toOwnedSlice(allocator);
    out.receipt_globs = try receipt_globs.toOwnedSlice(allocator);

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
        .lane => switch (out.lane_action orelse return error.MissingLaneAction) {
            .start => {
                if (out.cwd == null) return error.MissingCwd;
            },
            .review => {
                if (out.lane_id == null) return error.MissingLaneId;
                if (out.target == null) return error.MissingTarget;
            },
            .status, .stop => {
                if (out.lane_id == null) return error.MissingLaneId;
            },
        },
        .receipt => {
            if (out.receipt_paths.len == 0 and out.receipt_globs.len == 0) return error.MissingReceiptInput;
        },
    }

    return out;
}

fn setTarget(parsed: *ParsedArgs, target: TargetConfig) void {
    parsed.target = target;
}

fn loadCustomInstructionsAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.eql(u8, raw, "-")) {
        var reader = std.Io.File.stdin().reader(std.Io.Threaded.global_single_threaded.io(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    }
    if (std.mem.startsWith(u8, raw, "@")) {
        return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), raw[1..], allocator, .limited(1024 * 1024));
    }
    return allocator.dupe(u8, raw);
}

fn cmdStart(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
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
    const codex_version = readCodexVersionAlloc(allocator, io, cwd, resolved_codex_path) catch {
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
                .code = "review_failed",
                .hint = "verify the resolved codex binary is executable and supports app-server mode",
            },
        );
    };
    const output_receipt = OutputReceipt{
        .resolved_codex_path = resolved_codex_path,
        .resolved_codex_version = codex_version,
        .compatibility_verdict = "compatible",
        .selected_transport = "websocket",
        .selection_reason = "detached_review_requires_cross_process_truth",
        .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
        .hook_policy = parsed.hook_policy,
    };

    var managed_server = startManagedWebsocketServer(allocator, cwd, resolved_codex_path, parsed.hook_policy, io) catch |err| {
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            @errorName(err),
            cwd,
            output_receipt,
            .{
                .code = "websocket_bootstrap_failed",
                .hint = "CAS could not start the managed websocket app-server for detached review",
            },
        );
    };
    const managed_server_pid = managed_server.processId();
    const managed_server_listen_url = managed_server.listen_url;

    var client = connectReviewClient(
        allocator,
        cwd,
        resolved_codex_path,
        codex_version,
        "websocket",
        managed_server_listen_url,
        io,
        parsed,
    ) catch |err| {
        managed_server.kill();
        managed_server.deinit(allocator);
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            @errorName(err),
            cwd,
            .{
                .resolved_codex_path = resolved_codex_path,
                .resolved_codex_version = codex_version,
                .compatibility_verdict = "compatible",
                .selected_transport = "websocket",
                .selection_reason = "detached_review_requires_cross_process_truth",
                .managed_server_pid = managed_server_pid,
                .managed_server_listen_url = managed_server_listen_url,
                .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
            },
            .{
                .code = "websocket_bootstrap_failed",
                .hint = "CAS started the managed websocket app-server but could not complete the websocket client handshake",
            },
        );
    };
    defer {
        client.close();
        client.deinit();
    }

    const session_dir = try sessionDirAlloc(allocator);
    const target = parsed.target.?;
    const target_record = targetToRecord(target);
    const created_parent_thread = parsed.parent_thread_id == null;
    const parent_thread_id = if (parsed.parent_thread_id) |existing| blk: {
        const existing_parent_event_log_path = try parentEventLogPathAlloc(allocator, session_dir, existing);
        defer allocator.free(existing_parent_event_log_path);
        try resumeParentThread(allocator, &client, existing, existing_parent_event_log_path);
        var parent_status = try fetchReviewStatus(allocator, &client, existing, existing_parent_event_log_path, null);
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
    const parent_event_log_path = try parentEventLogPathAlloc(allocator, session_dir, parent_thread_id);
    defer allocator.free(parent_event_log_path);
    const review_params_json = try buildReviewStartParamsJson(allocator, parent_thread_id, target);
    defer allocator.free(review_params_json);
    appendLogRecord(allocator, parent_event_log_path, "thread/start", "response", parent_thread_id) catch {};

    var review_result_json: []u8 = undefined;
    var review_start_retry_used = false;
    const pre_materialize_parent = created_parent_thread and shouldPreMaterializeDetachedReviewParent(parsed.parent_mode, codex_version);
    if (pre_materialize_parent) {
        // Codex 0.118.x requires a persisted parent rollout before detached review/start.
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
                "fresh detached review parent could not be materialized before detached review launch",
                cwd,
                output_receipt,
                .{
                    .code = "parent_materialization_failed",
                    .hint = "auto parent-mode could not bootstrap a materialized parent thread for this codex runtime; pass a clean materialized --parent-thread-id or use native codex review",
                },
            );
        };
        appendLogRecord(allocator, parent_event_log_path, "review/start", "note", "{\"compatibility\":\"pre-materialized-fresh-parent\"}") catch {};
    }
    review_result_json = client.requestJson("review/start", review_params_json) catch |err| blk: {
        const raw_message = client.lastError() orelse @errorName(err);
        const failure = failureInfoForReviewStart(raw_message, created_parent_thread);
        if (created_parent_thread and failure != null and !pre_materialize_parent) {
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
                        .code = "review_failed",
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
                        .code = "review_failed",
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
                .code = "review_failed",
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
                .code = "review_failed",
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
        .created_at_unix_s = @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000))),
        .last_observed_status = "inProgress",
        .codex_version = codex_version,
        .resolved_codex_path = resolved_codex_path,
        .compatibility_verdict = "compatible",
        .transport_kind = "websocket",
        .transport_selection_reason = "detached_review_requires_cross_process_truth",
        .managed_server_pid = managed_server_pid,
        .managed_server_listen_url = managed_server_listen_url,
        .managed_server_stderr_log_path = null,
        .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
        .hook_policy = parsed.hook_policy.asString(),
        .hook_log_path = event_log_path,
    };
    try writeSessionRecord(allocator, record_path, record);

    if (parsed.wait_after_start) {
        const latest = waitForReviewCompletion(
            allocator,
            &client,
            record.review_thread_id,
            record.review_turn_id,
            record.event_log_path,
            parsed.timeout_ms,
            parsed.poll_interval_ms,
        ) catch |err| switch (err) {
            error.WaitTimedOut => {
                const timeout_status = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path, null);
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
                            .selected_transport = "websocket",
                            .selection_reason = "detached_review_requires_cross_process_truth",
                            .managed_server_pid = managed_server_pid,
                            .managed_server_listen_url = managed_server_listen_url,
                            .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
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
                    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                    const stdout = &stdout_writer.interface;
                    try stdout.print("cas_review_session start timed out after {d}ms\nreview thread: {s}\n", .{
                        parsed.timeout_ms,
                        review_thread_id,
                    });
                }
                std.process.exit(1);
            },
            else => return err,
        };
        record.last_observed_status = latest.turn_status;
        if (!latest.review_result_available) {
            if (failureInfoForStatus(&latest)) |failure| {
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
                    .compatibility_verdict = record.compatibility_verdict orelse "compatible",
                },
                latest,
                false,
                true,
                failureInfoForStatus(&latest) orelse .{
                    .code = "review_output_missing",
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
                        .selected_transport = "websocket",
                        .selection_reason = "detached_review_requires_cross_process_truth",
                        .managed_server_pid = managed_server_pid,
                        .managed_server_listen_url = managed_server_listen_url,
                        .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
                    },
                    latest,
                    false,
                    true,
                    failureInfoForStatus(&latest) orelse .{
                        .code = "review_output_missing",
                        .hint = "detached review reached terminal status without a materialized reviewResult",
                    },
                    null,
                );
            } else {
                var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                const stdout = &stdout_writer.interface;
                try stdout.print("cas_review_session start reached terminal status without a reviewResult\nreview thread: {s}\n", .{
                    review_thread_id,
                });
            }
            std.process.exit(1);
        }
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
                    .selected_transport = "websocket",
                    .selection_reason = "detached_review_requires_cross_process_truth",
                    .managed_server_pid = managed_server_pid,
                    .managed_server_listen_url = managed_server_listen_url,
                    .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
                },
                latest,
                false,
                true,
                null,
                null,
            );
        } else {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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
                .selected_transport = "websocket",
                .selection_reason = "detached_review_requires_cross_process_truth",
                .managed_server_pid = managed_server_pid,
                .managed_server_listen_url = managed_server_listen_url,
                .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
            },
            null,
            false,
            false,
            null,
            null,
        );
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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

fn cmdStatus(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    const loaded = try loadSessionRecord(allocator, parsed.review_thread_id.?);
    const record = loaded.record;
    const identity_opt: ?TargetIdentity = computeTargetIdentityAlloc(allocator, io, record.cwd, record.target) catch null;
    defer if (identity_opt) |identity| identity.deinit(allocator);

    if (record.terminal_fallback_transport != null and record.terminal_review_result_json != null) {
        const status = try makeStoredFallbackStatus(allocator, record);
        defer status.deinit(allocator);
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
                record.target,
                identity_opt,
                .{
                    .resolved_codex_path = record.resolved_codex_path,
                    .resolved_codex_version = record.codex_version,
                    .compatibility_verdict = record.compatibility_verdict orelse "compatible",
                    .selected_transport = record.terminal_fallback_transport.?,
                    .selection_reason = "stored_terminal_fallback",
                    .degraded_fallback = true,
                    .managed_server_pid = record.managed_server_pid,
                    .managed_server_listen_url = record.managed_server_listen_url,
                    .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                    .orphan_ttl_seconds = record.orphan_ttl_seconds,
                },
                null,
                null,
                null,
                .{
                    .exit_code = record.terminal_fallback_exit_code orelse 0,
                    .ok = (record.terminal_fallback_exit_code orelse 1) == 0,
                    .stdout_text = record.terminal_fallback_output_text,
                    .stderr_text = record.terminal_fallback_error_text,
                },
            );
        } else {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            try stdout.print("cas_review_session status\nreview thread: {s}\nreview turn: {s}\nturn status: {s}\ntransport: native-review (stored fallback)\nrecord: {s}\n", .{
                record.review_thread_id,
                record.review_turn_id,
                status.turn_status,
                loaded.record_path,
            });
        }
        return;
    }

    var client = try connectReviewClient(
        allocator,
        record.cwd,
        record.resolved_codex_path orelse "codex",
        record.codex_version,
        record.transport_kind,
        record.managed_server_listen_url,
        io,
        parsed,
    );
    defer {
        client.close();
        client.deinit();
    }

    var status = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path, null);
    try applyRecordedStatusOverlay(allocator, record, &status);

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
            record.target,
            identity_opt,
            .{
                .resolved_codex_path = record.resolved_codex_path,
                .resolved_codex_version = record.codex_version,
                .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                .selected_transport = record.transport_kind orelse "stdio",
                .selection_reason = record.transport_selection_reason orelse "legacy_record",
                .managed_server_pid = record.managed_server_pid,
                .managed_server_listen_url = record.managed_server_listen_url,
                .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                .orphan_ttl_seconds = record.orphan_ttl_seconds,
            },
            null,
            null,
            failureInfoForStatus(&status),
            null,
        );
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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

fn cmdWait(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    const loaded = try loadSessionRecord(allocator, parsed.review_thread_id.?);
    var record = loaded.record;
    const identity_opt: ?TargetIdentity = computeTargetIdentityAlloc(allocator, io, record.cwd, record.target) catch null;
    defer if (identity_opt) |identity| identity.deinit(allocator);
    if (record.terminal_fallback_transport != null and record.terminal_review_result_json != null) {
        const status = try makeStoredFallbackStatus(allocator, record);
        defer status.deinit(allocator);
        if (parsed.json) {
            try printStatusJson(
                allocator,
                .wait,
                record.cwd,
                record.parent_thread_id,
                record.review_thread_id,
                record.review_turn_id,
                status,
                loaded.record_path,
                record.event_log_path,
                record.target,
                identity_opt,
                .{
                    .resolved_codex_path = record.resolved_codex_path,
                    .resolved_codex_version = record.codex_version,
                    .compatibility_verdict = record.compatibility_verdict orelse "compatible",
                    .selected_transport = record.terminal_fallback_transport.?,
                    .selection_reason = "stored_terminal_fallback",
                    .degraded_fallback = true,
                    .managed_server_pid = record.managed_server_pid,
                    .managed_server_listen_url = record.managed_server_listen_url,
                    .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                    .orphan_ttl_seconds = record.orphan_ttl_seconds,
                },
                null,
                false,
                null,
                .{
                    .exit_code = record.terminal_fallback_exit_code orelse 0,
                    .ok = (record.terminal_fallback_exit_code orelse 1) == 0,
                    .stdout_text = record.terminal_fallback_output_text,
                    .stderr_text = record.terminal_fallback_error_text,
                },
            );
        }
        return;
    }

    var client = connectReviewClient(
        allocator,
        record.cwd,
        record.resolved_codex_path orelse "codex",
        record.codex_version,
        record.transport_kind,
        record.managed_server_listen_url,
        io,
        parsed,
    ) catch |err| {
        if (parsed.fallback_mode == .native_review) {
            try maybeRunNativeFallbackAndExitWait(
                allocator,
                parsed,
                &record,
                loaded.record_path,
                null,
                .{
                    .code = "review_transport_lost",
                    .hint = "managed websocket review transport could not be reconnected; returning explicit native-review fallback",
                },
            );
        }
        return err;
    };
    defer {
        client.close();
        client.deinit();
    }

    const latest = waitForReviewCompletion(
        allocator,
        &client,
        record.review_thread_id,
        record.review_turn_id,
        record.event_log_path,
        parsed.timeout_ms,
        parsed.poll_interval_ms,
    ) catch |err| switch (err) {
        error.WaitTimedOut => {
            var timeout_status = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path, null);
            try applyRecordedStatusOverlay(allocator, record, &timeout_status);
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
                    record.target,
                    identity_opt,
                    .{
                        .resolved_codex_path = record.resolved_codex_path,
                        .resolved_codex_version = record.codex_version,
                        .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                        .selected_transport = record.transport_kind orelse "stdio",
                        .selection_reason = record.transport_selection_reason orelse "legacy_record",
                        .managed_server_pid = record.managed_server_pid,
                        .managed_server_listen_url = record.managed_server_listen_url,
                        .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                        .orphan_ttl_seconds = record.orphan_ttl_seconds,
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
                var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                const stdout = &stdout_writer.interface;
                try stdout.print("cas_review_session wait timed out after {d}ms\nreview thread: {s}\n", .{
                    parsed.timeout_ms,
                    record.review_thread_id,
                });
            }
            std.process.exit(1);
        },
        else => {
            if (parsed.fallback_mode == .native_review and isTransportLossError(err)) {
                try maybeRunNativeFallbackAndExitWait(
                    allocator,
                    parsed,
                    &record,
                    loaded.record_path,
                    null,
                    .{
                        .code = "review_transport_lost",
                        .hint = "managed websocket review transport was lost while waiting; returning explicit native-review fallback",
                    },
                );
            }
            return err;
        },
    };

    record.last_observed_status = latest.turn_status;
    if (!latest.review_result_available) {
        if (failureInfoForStatus(&latest)) |failure| {
            if (std.mem.eql(u8, failure.code, "incompatible_codex_review_runtime")) {
                record.compatibility_verdict = "incompatible";
            }
        }
        try writeSessionRecord(allocator, loaded.record_path, record);
        try maybeRunNativeFallbackAndExitWait(
            allocator,
            parsed,
            &record,
            loaded.record_path,
            latest,
            failureInfoForStatus(&latest) orelse .{
                .code = "review_output_missing",
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
                latest,
                loaded.record_path,
                record.event_log_path,
                record.target,
                identity_opt,
                .{
                    .resolved_codex_path = record.resolved_codex_path,
                    .resolved_codex_version = record.codex_version,
                    .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                    .selected_transport = record.transport_kind orelse "stdio",
                    .selection_reason = record.transport_selection_reason orelse "legacy_record",
                    .managed_server_pid = record.managed_server_pid,
                    .managed_server_listen_url = record.managed_server_listen_url,
                    .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                    .orphan_ttl_seconds = record.orphan_ttl_seconds,
                },
                null,
                false,
                failureInfoForStatus(&latest) orelse .{
                    .code = "review_output_missing",
                    .hint = "detached review reached terminal status without a materialized reviewResult",
                },
                null,
            );
        } else {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            try stdout.print("cas_review_session wait reached terminal status without a reviewResult\nreview thread: {s}\n", .{
                record.review_thread_id,
            });
        }
        std.process.exit(1);
    }
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
            record.target,
            identity_opt,
            .{
                .resolved_codex_path = record.resolved_codex_path,
                .resolved_codex_version = record.codex_version,
                .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                .selected_transport = record.transport_kind orelse "stdio",
                .selection_reason = record.transport_selection_reason orelse "legacy_record",
                .managed_server_pid = record.managed_server_pid,
                .managed_server_listen_url = record.managed_server_listen_url,
                .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                .orphan_ttl_seconds = record.orphan_ttl_seconds,
            },
            null,
            false,
            null,
            null,
        );
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session wait\nreview thread: {s}\nreview turn: {s}\nfinal turn status: {s}\nrecord: {s}\n", .{
            record.review_thread_id,
            record.review_turn_id,
            latest.turn_status,
            loaded.record_path,
        });
    }
}

fn cmdInterrupt(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    const loaded = try loadSessionRecord(allocator, parsed.review_thread_id.?);
    var record = loaded.record;

    if (record.terminal_fallback_transport != null) {
        if (parsed.json) {
            const payload = .{
                .demo = "cas-review-session",
                .action = "interrupt",
                .reviewThreadId = record.review_thread_id,
                .reviewTurnId = record.review_turn_id,
                .skipped = true,
                .reason = "stored-terminal-fallback",
                .turnStatus = record.last_observed_status,
                .recordPath = loaded.record_path,
                .eventLogPath = record.event_log_path,
            };
            try printJson(payload);
        }
        return;
    }

    var client = try connectReviewClient(
        allocator,
        record.cwd,
        record.resolved_codex_path orelse "codex",
        record.codex_version,
        record.transport_kind,
        record.managed_server_listen_url,
        io,
        parsed,
    );
    defer {
        client.close();
        client.deinit();
    }

    const latest = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path, null);
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
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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
                    .code = "review_failed",
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
                .code = "review_failed",
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
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session interrupt\nreview thread: {s}\nreview turn: {s}\nrecord: {s}\n", .{
            record.review_thread_id,
            record.review_turn_id,
            loaded.record_path,
        });
    }
}

const NormalizedReceipt = struct {
    source_path: []const u8,
    status: []const u8,
    backend_class: []const u8,
    clean: bool,
    finding_count: usize,
    base_sha: ?[]const u8,
    head_sha: ?[]const u8,
    target_fingerprint: ?[]const u8,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: ?[]const u8,
    event_log_path: ?[]const u8,
    failure_code: ?[]const u8,
    failure_hint: ?[]const u8,
    findings_json: []const u8,

    fn deinit(self: NormalizedReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.status);
        allocator.free(self.backend_class);
        if (self.base_sha) |value| allocator.free(value);
        if (self.head_sha) |value| allocator.free(value);
        if (self.target_fingerprint) |value| allocator.free(value);
        if (self.review_thread_id) |value| allocator.free(value);
        if (self.review_turn_id) |value| allocator.free(value);
        if (self.record_path) |value| allocator.free(value);
        if (self.event_log_path) |value| allocator.free(value);
        if (self.failure_code) |value| allocator.free(value);
        if (self.failure_hint) |value| allocator.free(value);
        allocator.free(self.findings_json);
    }
};

const ReceiptError = struct {
    source_path: []const u8,
    message: []const u8,

    fn deinit(self: ReceiptError, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.message);
    }
};

const ReceiptSummary = struct {
    total: usize = 0,
    clean: usize = 0,
    findings: usize = 0,
    timeout: usize = 0,
    parse_mismatch: usize = 0,
    transport_failure: usize = 0,
    incomplete: usize = 0,
    other_status: usize = 0,
    cas_lane: usize = 0,
    cas_native_fallback: usize = 0,
    other_backend: usize = 0,
};

fn cmdReceipt(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    for (parsed.receipt_paths) |path| {
        try paths.append(allocator, try allocator.dupe(u8, path));
    }
    for (parsed.receipt_globs) |pattern| {
        try expandReceiptGlob(allocator, pattern, &paths);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanString);

    var receipts: std.ArrayList(NormalizedReceipt) = .empty;
    defer {
        for (receipts.items) |receipt| receipt.deinit(allocator);
        receipts.deinit(allocator);
    }
    var errors: std.ArrayList(ReceiptError) = .empty;
    defer {
        for (errors.items) |err| err.deinit(allocator);
        errors.deinit(allocator);
    }

    if (paths.items.len == 0) {
        try errors.append(allocator, .{
            .source_path = try allocator.dupe(u8, "<input>"),
            .message = try allocator.dupe(u8, "no receipt files matched"),
        });
    }

    for (paths.items) |path| {
        const receipt = normalizeReceiptFromPathAlloc(allocator, path) catch |err| {
            try errors.append(allocator, .{
                .source_path = try allocator.dupe(u8, path),
                .message = try allocator.dupe(u8, @errorName(err)),
            });
            continue;
        };
        try receipts.append(allocator, receipt);
    }

    const summary = summarizeReceipts(receipts.items);
    switch (parsed.receipt_format) {
        .table => try printReceiptTable(receipts.items, errors.items, if (parsed.receipt_summary) summary else null),
        .json => try printReceiptJson(receipts.items, errors.items, if (parsed.receipt_summary) summary else null),
        .jsonl => try printReceiptJsonl(receipts.items, errors.items, if (parsed.receipt_summary) summary else null),
    }
    if (errors.items.len > 0) std.process.exit(1);
}

fn cmdLane(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    switch (parsed.lane_action.?) {
        .start => try cmdLaneStart(allocator, io, parsed),
        .review => try cmdLaneReview(allocator, io, parsed),
        .status => try cmdLaneStatus(allocator, parsed),
        .stop => try cmdLaneStop(allocator, parsed),
    }
}

fn cmdLaneStart(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    const cwd = parsed.cwd.?;
    const resolved_codex_path = cas.resolveExecutableAlloc(allocator, "codex") catch {
        try renderErrorAndExit(
            parsed.json,
            "lane-start",
            "app-server/start",
            "codex binary could not be resolved for review_session lane",
            cwd,
            .{},
            .{
                .code = "missing_codex_binary",
                .hint = "install or expose a compatible codex binary on PATH before starting a CAS review lane",
            },
        );
    };
    const codex_version = try readCodexVersionAlloc(allocator, io, cwd, resolved_codex_path);
    var managed_server = startManagedWebsocketServer(allocator, cwd, resolved_codex_path, parsed.hook_policy, io) catch |err| {
        try renderErrorAndExit(
            parsed.json,
            "lane-start",
            "app-server/start",
            @errorName(err),
            cwd,
            .{
                .resolved_codex_path = resolved_codex_path,
                .resolved_codex_version = codex_version,
                .compatibility_verdict = "compatible",
                .selected_transport = "websocket",
                .selection_reason = "persistent_review_lane",
                .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
            },
            .{
                .code = "websocket_bootstrap_failed",
                .hint = "CAS could not start the managed websocket app-server for the persistent review lane",
            },
        );
    };
    const lane_id = try laneIdAlloc(allocator, managed_server.processId());

    var client = connectReviewClient(
        allocator,
        cwd,
        resolved_codex_path,
        codex_version,
        "websocket",
        managed_server.listen_url,
        io,
        parsed,
    ) catch |err| {
        managed_server.kill();
        managed_server.deinit(allocator);
        try renderErrorAndExit(
            parsed.json,
            "lane-start",
            "app-server/connect",
            @errorName(err),
            cwd,
            .{
                .resolved_codex_path = resolved_codex_path,
                .resolved_codex_version = codex_version,
                .compatibility_verdict = "compatible",
                .selected_transport = "websocket",
                .selection_reason = "persistent_review_lane",
                .managed_server_pid = managed_server.processId(),
                .managed_server_listen_url = managed_server.listen_url,
                .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
            },
            .{
                .code = "websocket_bootstrap_failed",
                .hint = "CAS started the managed websocket app-server but could not complete the lane websocket client handshake",
            },
        );
    };
    defer {
        client.close();
        client.deinit();
    }

    const now_s = unixSeconds();
    const lane = LaneRecord{
        .lane_id = lane_id,
        .cwd = cwd,
        .created_at_unix_s = now_s,
        .last_used_at_unix_s = now_s,
        .status = "running",
        .codex_version = codex_version,
        .resolved_codex_path = resolved_codex_path,
        .managed_server_pid = managed_server.processId(),
        .managed_server_listen_url = managed_server.listen_url,
        .hook_policy = parsed.hook_policy.asString(),
    };
    const path = try laneRecordPathAlloc(allocator, lane_id);
    try writeLaneRecord(allocator, path, lane);

    if (parsed.json) {
        try printJson(.{
            .demo = "cas-review-session",
            .action = "lane-start",
            .laneId = lane.lane_id,
            .cwd = lane.cwd,
            .recordPath = path,
            .resolvedCodexPath = lane.resolved_codex_path,
            .resolvedCodexVersion = lane.codex_version,
            .selectedTransport = lane.transport_kind,
            .selectionReason = lane.transport_selection_reason,
            .managedServerPid = lane.managed_server_pid,
            .managedServerListenUrl = lane.managed_server_listen_url,
            .orphanTtlSeconds = lane.orphan_ttl_seconds,
            .hookPolicy = lane.hook_policy,
        });
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session lane start\nlane: {s}\ncwd: {s}\nmanaged server pid: {d}\nrecord: {s}\n", .{
            lane.lane_id,
            lane.cwd,
            lane.managed_server_pid,
            path,
        });
    }
}

fn cmdLaneReview(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var loaded = try loadLaneRecord(allocator, parsed.lane_id.?);
    defer loaded.deinit(allocator);
    var lane = loaded.record;
    const target = parsed.target.?;
    const target_record = targetToRecord(target);
    var identity = try computeTargetIdentityAlloc(allocator, io, lane.cwd, target_record);
    defer identity.deinit(allocator);

    if (!cas_websocket.processAlive(lane.managed_server_pid)) {
        if (parsed.fallback_mode == .native_review) {
            var fallback = try runNativeReviewFallbackAlloc(allocator, lane.cwd, lane.resolved_codex_path, target_record);
            defer fallback.deinit(allocator);
            try printLaneFallbackJson(allocator, lane, loaded.record_path, target_record, identity, fallback, .{
                .code = "lane_transport_lost",
                .hint = "persistent CAS lane app-server is not alive; returned explicit native-review fallback",
            }, parsed.verdict_only);
            std.process.exit(if (fallback.ok) 0 else 1);
        }
        try renderErrorAndExit(
            parsed.json,
            "lane-review",
            "review/start",
            "persistent CAS lane app-server is not alive",
            lane.cwd,
            .{
                .resolved_codex_path = lane.resolved_codex_path,
                .resolved_codex_version = lane.codex_version,
                .compatibility_verdict = "compatible",
                .selected_transport = "websocket",
                .selection_reason = "persistent_review_lane",
                .managed_server_pid = lane.managed_server_pid,
                .managed_server_listen_url = lane.managed_server_listen_url,
                .orphan_ttl_seconds = lane.orphan_ttl_seconds,
            },
            .{
                .code = "lane_transport_lost",
                .hint = "restart the CAS review lane or pass --fallback native-review for explicit degraded transport",
            },
        );
    }

    var client = connectReviewClient(
        allocator,
        lane.cwd,
        lane.resolved_codex_path,
        lane.codex_version,
        lane.transport_kind,
        lane.managed_server_listen_url,
        io,
        parsed,
    ) catch |err| {
        if (parsed.fallback_mode == .native_review) {
            var fallback = try runNativeReviewFallbackAlloc(allocator, lane.cwd, lane.resolved_codex_path, target_record);
            defer fallback.deinit(allocator);
            try printLaneFallbackJson(allocator, lane, loaded.record_path, target_record, identity, fallback, .{
                .code = "lane_transport_lost",
                .hint = "persistent CAS lane websocket could not be reconnected; returned explicit native-review fallback",
            }, parsed.verdict_only);
            std.process.exit(if (fallback.ok) 0 else 1);
        }
        try renderErrorAndExit(
            parsed.json,
            "lane-review",
            "review/start",
            @errorName(err),
            lane.cwd,
            .{
                .resolved_codex_path = lane.resolved_codex_path,
                .resolved_codex_version = lane.codex_version,
                .compatibility_verdict = "compatible",
                .selected_transport = "websocket",
                .selection_reason = "persistent_review_lane",
                .managed_server_pid = lane.managed_server_pid,
                .managed_server_listen_url = lane.managed_server_listen_url,
                .orphan_ttl_seconds = lane.orphan_ttl_seconds,
            },
            .{
                .code = "lane_transport_lost",
                .hint = "persistent CAS lane websocket could not be reconnected; restart the lane or pass --fallback native-review",
            },
        );
    };
    defer {
        client.close();
        client.deinit();
    }

    const session_dir = try sessionDirAlloc(allocator);
    const parent_thread_id = startParentThreadAlloc(allocator, &client, lane.cwd, session_dir) catch |err| {
        if (parsed.fallback_mode == .native_review and isTransportLossError(err)) {
            var fallback = try runNativeReviewFallbackAlloc(allocator, lane.cwd, lane.resolved_codex_path, target_record);
            defer fallback.deinit(allocator);
            try printLaneFallbackJson(allocator, lane, loaded.record_path, target_record, identity, fallback, .{
                .code = "lane_transport_lost",
                .hint = "persistent CAS lane websocket was lost while starting a fresh parent; returned explicit native-review fallback",
            }, parsed.verdict_only);
            std.process.exit(if (fallback.ok) 0 else 1);
        }
        if (isTransportLossError(err)) {
            try renderErrorAndExit(
                parsed.json,
                "lane-review",
                "thread/start",
                @errorName(err),
                lane.cwd,
                .{
                    .resolved_codex_path = lane.resolved_codex_path,
                    .resolved_codex_version = lane.codex_version,
                    .compatibility_verdict = "compatible",
                    .selected_transport = "websocket",
                    .selection_reason = "persistent_review_lane",
                    .managed_server_pid = lane.managed_server_pid,
                    .managed_server_listen_url = lane.managed_server_listen_url,
                    .orphan_ttl_seconds = lane.orphan_ttl_seconds,
                },
                .{
                    .code = "lane_transport_lost",
                    .hint = "persistent CAS lane websocket was lost while starting a fresh parent; retry, restart the lane, or pass --fallback native-review",
                },
            );
        }
        return err;
    };
    const parent_event_log_path = try parentEventLogPathAlloc(allocator, session_dir, parent_thread_id);
    defer allocator.free(parent_event_log_path);
    if (shouldPreMaterializeDetachedReviewParent(.auto, lane.codex_version)) {
        materializeParentThreadTurn(
            allocator,
            &client,
            parent_thread_id,
            parent_event_log_path,
            parsed.timeout_ms,
            parsed.poll_interval_ms,
        ) catch |err| {
            if (parsed.fallback_mode == .native_review and isTransportLossError(err)) {
                var fallback = try runNativeReviewFallbackAlloc(allocator, lane.cwd, lane.resolved_codex_path, target_record);
                defer fallback.deinit(allocator);
                try printLaneFallbackJson(allocator, lane, loaded.record_path, target_record, identity, fallback, .{
                    .code = "lane_transport_lost",
                    .hint = "persistent CAS lane websocket was lost while materializing a fresh parent; returned explicit native-review fallback",
                }, parsed.verdict_only);
                std.process.exit(if (fallback.ok) 0 else 1);
            }
            if (isTransportLossError(err)) {
                try renderErrorAndExit(
                    parsed.json,
                    "lane-review",
                    "turn/start",
                    @errorName(err),
                    lane.cwd,
                    .{
                        .resolved_codex_path = lane.resolved_codex_path,
                        .resolved_codex_version = lane.codex_version,
                        .compatibility_verdict = "compatible",
                        .selected_transport = "websocket",
                        .selection_reason = "persistent_review_lane",
                        .managed_server_pid = lane.managed_server_pid,
                        .managed_server_listen_url = lane.managed_server_listen_url,
                        .orphan_ttl_seconds = lane.orphan_ttl_seconds,
                    },
                    .{
                        .code = "lane_transport_lost",
                        .hint = "persistent CAS lane websocket was lost while materializing a fresh parent; retry, restart the lane, or pass --fallback native-review",
                    },
                );
            }
            return err;
        };
    }

    const review_params_json = try buildReviewStartParamsJson(allocator, parent_thread_id, target);
    defer allocator.free(review_params_json);
    const review_result_json = client.requestJson("review/start", review_params_json) catch |err| {
        if (parsed.fallback_mode == .native_review) {
            var fallback = try runNativeReviewFallbackAlloc(allocator, lane.cwd, lane.resolved_codex_path, target_record);
            defer fallback.deinit(allocator);
            try printLaneFallbackJson(allocator, lane, loaded.record_path, target_record, identity, fallback, .{
                .code = "review_failed",
                .hint = "lane review startup failed; returned explicit native-review fallback",
            }, parsed.verdict_only);
            std.process.exit(if (fallback.ok) 0 else 1);
        }
        return err;
    };
    defer allocator.free(review_result_json);

    const review_thread_id = try extractReviewThreadIdAlloc(allocator, review_result_json);
    const review_turn_id = try extractReviewTurnIdAlloc(allocator, review_result_json);
    const event_log_path = try std.fmt.allocPrint(allocator, "{s}/{s}.events.ndjson", .{ session_dir, review_thread_id });
    const record_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, review_thread_id });
    try appendLogRecord(allocator, event_log_path, "review/start", "request", review_params_json);
    try appendLogRecord(allocator, event_log_path, "review/start", "response", review_result_json);

    var record = SessionRecord{
        .cwd = lane.cwd,
        .parent_thread_id = parent_thread_id,
        .review_thread_id = review_thread_id,
        .review_turn_id = review_turn_id,
        .delivery = "detached",
        .target = target_record,
        .event_log_path = event_log_path,
        .created_at_unix_s = unixSeconds(),
        .last_observed_status = "inProgress",
        .codex_version = lane.codex_version,
        .resolved_codex_path = lane.resolved_codex_path,
        .compatibility_verdict = "compatible",
        .transport_kind = lane.transport_kind,
        .transport_selection_reason = "persistent_review_lane",
        .managed_server_pid = lane.managed_server_pid,
        .managed_server_listen_url = lane.managed_server_listen_url,
        .managed_server_stderr_log_path = null,
        .orphan_ttl_seconds = lane.orphan_ttl_seconds,
        .hook_policy = lane.hook_policy,
        .hook_log_path = event_log_path,
    };
    try writeSessionRecord(allocator, record_path, record);

    const latest = waitForReviewCompletion(
        allocator,
        &client,
        review_thread_id,
        review_turn_id,
        event_log_path,
        parsed.timeout_ms,
        parsed.poll_interval_ms,
    ) catch |err| switch (err) {
        error.WaitTimedOut => {
            record.last_observed_status = "timeout";
            try writeSessionRecord(allocator, record_path, record);
            lane.last_used_at_unix_s = unixSeconds();
            lane.last_review_thread_id = review_thread_id;
            lane.last_review_turn_id = review_turn_id;
            lane.last_record_path = record_path;
            lane.last_event_log_path = event_log_path;
            lane.last_target_fingerprint = identity.fingerprint;
            lane.last_head_sha = identity.head_sha;
            lane.last_base_sha = identity.base_sha;
            lane.last_dual_parse_verdict = "timeout";
            lane.last_archive_status = "skipped_timeout";
            try writeLaneRecord(allocator, loaded.record_path, lane);
            try printLaneReviewTimeoutJson(
                allocator,
                lane,
                loaded.record_path,
                target_record,
                identity,
                review_thread_id,
                review_turn_id,
                record_path,
                event_log_path,
                parsed.timeout_ms,
                parsed.verdict_only,
            );
            std.process.exit(1);
        },
        else => {
            if (parsed.fallback_mode == .native_review and isTransportLossError(err)) {
                var fallback = try runNativeReviewFallbackAlloc(allocator, lane.cwd, lane.resolved_codex_path, target_record);
                defer fallback.deinit(allocator);
                try printLaneFallbackJson(allocator, lane, loaded.record_path, target_record, identity, fallback, .{
                    .code = "lane_transport_lost",
                    .hint = "persistent CAS lane websocket was lost while waiting; returned explicit native-review fallback",
                }, parsed.verdict_only);
                std.process.exit(if (fallback.ok) 0 else 1);
            }
            if (isTransportLossError(err)) {
                try renderErrorAndExit(
                    parsed.json,
                    "lane-review",
                    "review/wait",
                    @errorName(err),
                    lane.cwd,
                    .{
                        .resolved_codex_path = lane.resolved_codex_path,
                        .resolved_codex_version = lane.codex_version,
                        .compatibility_verdict = "compatible",
                        .selected_transport = "websocket",
                        .selection_reason = "persistent_review_lane",
                        .managed_server_pid = lane.managed_server_pid,
                        .managed_server_listen_url = lane.managed_server_listen_url,
                        .orphan_ttl_seconds = lane.orphan_ttl_seconds,
                    },
                    .{
                        .code = "lane_transport_lost",
                        .hint = "persistent CAS lane websocket was lost while waiting; retry, restart the lane, or pass --fallback native-review",
                    },
                );
            }
            return err;
        },
    };
    defer latest.deinit(allocator);

    record.last_observed_status = latest.turn_status;
    try writeSessionRecord(allocator, record_path, record);

    const dual_parse = try dualParseVerdictAlloc(allocator, latest);
    defer dual_parse.deinit(allocator);
    const archive_status = if (parsed.archive_lane_threads)
        try archiveLaneThreadsBestEffort(allocator, &client, parent_thread_id, review_thread_id, event_log_path)
    else
        try allocator.dupe(u8, "skipped");
    defer allocator.free(archive_status);

    lane.review_count += 1;
    lane.last_used_at_unix_s = unixSeconds();
    lane.last_review_thread_id = review_thread_id;
    lane.last_review_turn_id = review_turn_id;
    lane.last_record_path = record_path;
    lane.last_event_log_path = event_log_path;
    lane.last_target_fingerprint = identity.fingerprint;
    lane.last_head_sha = identity.head_sha;
    lane.last_base_sha = identity.base_sha;
    lane.last_dual_parse_verdict = dual_parse.verdict;
    lane.last_archive_status = archive_status;
    try writeLaneRecord(allocator, loaded.record_path, lane);

    const trusted_structured_result = latest.review_result_available and
        latest.review_result_source != null and
        std.mem.eql(u8, latest.review_result_source.?, "rollout_exited_review_mode");
    const lane_failure: ?FailureInfo = if (!latest.review_result_available)
        .{
            .code = "review_output_missing",
            .hint = "lane review reached terminal status without a materialized reviewResult",
        }
    else if (!trusted_structured_result)
        .{
            .code = "review_untrusted_source",
            .hint = "lane review only has notification-rendered review text; a clean receipt requires rollout-backed structured review output",
        }
    else if (std.mem.eql(u8, dual_parse.verdict, "mismatch"))
        .{
            .code = "review_parse_mismatch",
            .hint = "lane review structured findings disagree with the raw rendered review parse",
        }
    else
        null;

    if (lane_failure != null) {
        if (parsed.fallback_mode == .native_review) {
            var fallback = try runNativeReviewFallbackAlloc(allocator, lane.cwd, lane.resolved_codex_path, target_record);
            defer fallback.deinit(allocator);
            try printLaneFallbackJson(allocator, lane, loaded.record_path, target_record, identity, fallback, lane_failure.?, parsed.verdict_only);
            std.process.exit(if (fallback.ok) 0 else 1);
        }
    }

    const finding_count = try reviewFindingCount(allocator, latest.review_result_json);
    const clean = lane_failure == null and finding_count == 0;
    try printLaneReviewJson(
        allocator,
        lane,
        loaded.record_path,
        target_record,
        identity,
        review_thread_id,
        review_turn_id,
        record_path,
        event_log_path,
        latest,
        dual_parse,
        archive_status,
        clean,
        lane_failure,
        parsed.verdict_only,
    );
    if (!clean) std.process.exit(1);
}

fn cmdLaneStatus(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    var loaded = try loadLaneRecord(allocator, parsed.lane_id.?);
    defer loaded.deinit(allocator);
    const lane = loaded.record;
    const alive = cas_websocket.processAlive(lane.managed_server_pid);
    if (parsed.json) {
        try printJson(.{
            .demo = "cas-review-session",
            .action = "lane-status",
            .laneId = lane.lane_id,
            .cwd = lane.cwd,
            .recordPath = loaded.record_path,
            .status = lane.status,
            .alive = alive,
            .managedServerPid = lane.managed_server_pid,
            .managedServerListenUrl = lane.managed_server_listen_url,
            .reviewCount = lane.review_count,
            .lastReviewThreadId = lane.last_review_thread_id,
            .lastTargetFingerprint = lane.last_target_fingerprint,
        });
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session lane status\nlane: {s}\nalive: {s}\nreview count: {d}\nrecord: {s}\n", .{
            lane.lane_id,
            if (alive) "yes" else "no",
            lane.review_count,
            loaded.record_path,
        });
    }
}

fn cmdLaneStop(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    var loaded = try loadLaneRecord(allocator, parsed.lane_id.?);
    defer loaded.deinit(allocator);
    var lane = loaded.record;
    const was_alive = cas_websocket.processAlive(lane.managed_server_pid);
    if (was_alive) cas_websocket.terminateProcess(lane.managed_server_pid);
    lane.status = "stopped";
    lane.last_used_at_unix_s = unixSeconds();
    try writeLaneRecord(allocator, loaded.record_path, lane);
    if (parsed.json) {
        try printJson(.{
            .demo = "cas-review-session",
            .action = "lane-stop",
            .laneId = lane.lane_id,
            .recordPath = loaded.record_path,
            .managedServerPid = lane.managed_server_pid,
            .wasAlive = was_alive,
            .status = lane.status,
        });
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session lane stop\nlane: {s}\nwas alive: {s}\nrecord: {s}\n", .{
            lane.lane_id,
            if (was_alive) "yes" else "no",
            loaded.record_path,
        });
    }
}

fn fetchReviewStatus(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    review_thread_id: []const u8,
    event_log_path: []const u8,
    live_notifications: ?*LiveReviewNotificationState,
) !ReviewStatus {
    const params_json = try stringifyAnyAlloc(allocator, .{
        .threadId = review_thread_id,
        .includeTurns = true,
    });
    defer allocator.free(params_json);

    var captured_notifications: std.ArrayList([]u8) = .empty;
    defer {
        for (captured_notifications.items) |line| allocator.free(line);
        captured_notifications.deinit(allocator);
    }

    const response_json = (if (live_notifications != null)
        client.requestJsonCaptureNotifications("thread/read", params_json, &captured_notifications)
    else
        client.requestJson("thread/read", params_json)) catch |err| {
        const detail = client.lastError() orelse @errorName(err);
        if (std.mem.indexOf(u8, detail, "includeTurns is unavailable") != null or
            std.mem.indexOf(u8, detail, "not materialized yet") != null)
        {
            const fallback_params = try stringifyAnyAlloc(allocator, .{
                .threadId = review_thread_id,
                .includeTurns = false,
            });
            defer allocator.free(fallback_params);
            const fallback_json = if (live_notifications != null)
                try client.requestJsonCaptureNotifications("thread/read", fallback_params, &captured_notifications)
            else
                try client.requestJson("thread/read", fallback_params);
            if (live_notifications) |state| {
                try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
            }
            try appendLogRecord(allocator, event_log_path, "thread/read", "response", fallback_json);
            var status = try parseReviewStatusAlloc(allocator, fallback_json, false);
            try populateReviewResult(allocator, &status);
            try populateReviewResultFromLiveNotifications(allocator, &status, live_notifications);
            if (try maybeResumeMaterializedThread(allocator, client, review_thread_id, event_log_path, &status)) {
                allocator.free(fallback_json);
                captured_notifications.clearRetainingCapacity();
                const resumed_json = if (live_notifications != null)
                    try client.requestJsonCaptureNotifications("thread/read", fallback_params, &captured_notifications)
                else
                    try client.requestJson("thread/read", fallback_params);
                if (live_notifications) |state| {
                    try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
                }
                try appendLogRecord(allocator, event_log_path, "thread/read", "response", resumed_json);
                var resumed_status = try parseReviewStatusAlloc(allocator, resumed_json, false);
                try populateReviewResult(allocator, &resumed_status);
                try populateReviewResultFromLiveNotifications(allocator, &resumed_status, live_notifications);
                return resumed_status;
            }
            return status;
        }
        return err;
    };
    if (live_notifications) |state| {
        try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
    }
    try appendLogRecord(allocator, event_log_path, "thread/read", "response", response_json);
    var status = try parseReviewStatusAlloc(allocator, response_json, true);
    try populateReviewResult(allocator, &status);
    try populateReviewResultFromLiveNotifications(allocator, &status, live_notifications);
    if (try maybeResumeMaterializedThread(allocator, client, review_thread_id, event_log_path, &status)) {
        allocator.free(response_json);
        const params_after_resume = try stringifyAnyAlloc(allocator, .{
            .threadId = review_thread_id,
            .includeTurns = true,
        });
        defer allocator.free(params_after_resume);
        captured_notifications.clearRetainingCapacity();
        const resumed_json = if (live_notifications != null)
            try client.requestJsonCaptureNotifications("thread/read", params_after_resume, &captured_notifications)
        else
            try client.requestJson("thread/read", params_after_resume);
        if (live_notifications) |state| {
            try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
        }
        try appendLogRecord(allocator, event_log_path, "thread/read", "response", resumed_json);
        var resumed_status = try parseReviewStatusAlloc(allocator, resumed_json, true);
        try populateReviewResult(allocator, &resumed_status);
        try populateReviewResultFromLiveNotifications(allocator, &resumed_status, live_notifications);
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
        .review_text = null,
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

fn absorbLiveReviewNotifications(
    allocator: std.mem.Allocator,
    captured_notifications: *const std.ArrayList([]u8),
    event_log_path: []const u8,
    live_notifications: *LiveReviewNotificationState,
) !void {
    for (captured_notifications.items) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const root_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        const method = core_json.stringField(root_obj, "method") orelse continue;
        try appendLogRecord(allocator, event_log_path, method, "notification", line);
        if (std.mem.eql(u8, method, "turn/aborted")) {
            const params_obj = core_json.objectField(root_obj, "params") orelse continue;
            const thread_id = core_json.stringField(params_obj, "threadId") orelse continue;
            const turn_id = core_json.stringField(params_obj, "turnId") orelse continue;
            if (std.mem.eql(u8, thread_id, live_notifications.review_thread_id) and
                std.mem.eql(u8, turn_id, live_notifications.review_turn_id))
            {
                live_notifications.observed_terminal_status = "interrupted";
            }
            continue;
        }
        if (std.mem.eql(u8, method, "turn/completed")) {
            const params_obj = core_json.objectField(root_obj, "params") orelse continue;
            const thread_id = core_json.stringField(params_obj, "threadId") orelse continue;
            if (!std.mem.eql(u8, thread_id, live_notifications.review_thread_id)) continue;
            const turn_obj = core_json.objectField(params_obj, "turn") orelse continue;
            const turn_id = core_json.stringField(turn_obj, "id") orelse continue;
            if (!std.mem.eql(u8, turn_id, live_notifications.review_turn_id)) continue;
            const turn_status = core_json.stringField(turn_obj, "status") orelse continue;
            live_notifications.observed_terminal_status =
                if (std.mem.eql(u8, turn_status, "completed")) "completed" else if (std.mem.eql(u8, turn_status, "failed")) "failed" else if (std.mem.eql(u8, turn_status, "errored")) "errored" else if (std.mem.eql(u8, turn_status, "interrupted")) "interrupted" else turn_status;
            if (turn_obj.get("error")) |error_val| {
                if (live_notifications.observed_turn_error_message) |existing| allocator.free(existing);
                live_notifications.observed_turn_error_message = try extractErrorMessageAlloc(allocator, error_val);
            }
            continue;
        }
        if (!std.mem.eql(u8, method, "item/started") and !std.mem.eql(u8, method, "item/completed")) continue;
        const params_obj = core_json.objectField(root_obj, "params") orelse continue;
        const thread_id = core_json.stringField(params_obj, "threadId") orelse continue;
        const turn_id = core_json.stringField(params_obj, "turnId") orelse continue;
        if (!std.mem.eql(u8, thread_id, live_notifications.review_thread_id)) continue;
        if (!std.mem.eql(u8, turn_id, live_notifications.review_turn_id)) continue;
        const item_obj = core_json.objectField(params_obj, "item") orelse continue;
        const item_type = core_json.stringField(item_obj, "type") orelse continue;
        if (std.mem.eql(u8, item_type, "enteredReviewMode")) {
            live_notifications.saw_entered_review_mode = true;
            continue;
        }
        if (!std.mem.eql(u8, item_type, "exitedReviewMode")) continue;
        live_notifications.saw_exited_review_mode = true;
        const review_text = core_json.stringField(item_obj, "review") orelse continue;
        if (live_notifications.review_text) |existing| allocator.free(existing);
        live_notifications.review_text = try allocator.dupe(u8, review_text);
    }
}

fn populateReviewResultFromLiveNotifications(
    allocator: std.mem.Allocator,
    status: *ReviewStatus,
    live_notifications: ?*LiveReviewNotificationState,
) !void {
    const state = live_notifications orelse return;
    status.last_turn_has_entered_review_mode = status.last_turn_has_entered_review_mode or state.saw_entered_review_mode;
    status.last_turn_has_exited_review_mode = status.last_turn_has_exited_review_mode or state.saw_exited_review_mode;
    if (state.observed_terminal_status) |observed_status| {
        allocator.free(status.turn_status);
        status.turn_status = try allocator.dupe(u8, observed_status);
    }
    if (status.turn_error_message == null) {
        if (state.observed_turn_error_message) |message| {
            status.turn_error_message = try allocator.dupe(u8, message);
        }
    }
    const review_text = state.review_text orelse return;
    if (status.review_text == null) {
        status.review_text = try allocator.dupe(u8, review_text);
    }
    if (!isTerminalTurnStatus(status.turn_status)) return;
    if (status.review_result_available) return;
    if (!std.mem.eql(u8, status.turn_status, "completed")) return;
    if (std.mem.eql(u8, review_text, review_fallback_text)) return;
    status.review_result_available = true;
    status.review_result_source = "notification_exited_review_mode";
    status.review_result_json = try buildReviewResultJsonFromRenderedTextAlloc(allocator, review_text);
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
    const started_ms = @divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000);
    while (true) {
        const latest = try fetchReviewStatus(allocator, client, thread_id, event_log_path, null);
        if (isTerminalTurnStatus(latest.turn_status)) return latest;
        latest.deinit(allocator);
        if (@divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000) - started_ms >= timeout_ms) return error.WaitTimedOut;
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(poll_interval_ms), .awake) catch {};
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

fn gitOutputAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv_tail: []const []const u8,
) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (argv_tail) |arg| try argv.append(allocator, arg);
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.GitCommandFailed;
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn computeTargetIdentityAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    target: TargetRecord,
) !TargetIdentity {
    const head_sha = gitOutputAlloc(allocator, io, cwd, &.{ "rev-parse", "HEAD" }) catch null;
    const base_sha = if (std.mem.eql(u8, target.type, "baseBranch") and target.branch != null)
        gitOutputAlloc(allocator, io, cwd, &.{ "merge-base", "HEAD", target.branch.? }) catch null
    else if (std.mem.eql(u8, target.type, "commit") and target.sha != null)
        try allocator.dupe(u8, target.sha.?)
    else
        null;
    const target_json = try stringifyAnyAlloc(allocator, target);
    defer allocator.free(target_json);
    const fingerprint = try std.fmt.allocPrint(allocator, "target={s};head={s};base={s}", .{
        target_json,
        head_sha orelse "unknown",
        base_sha orelse "unknown",
    });
    return .{
        .head_sha = head_sha,
        .base_sha = base_sha,
        .fingerprint = fingerprint,
    };
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

    const result = try std.process.run(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    const exit_code: u8 = switch (result.term) {
        .exited => |code| @intCast(@min(code, 255)),
        else => 1,
    };
    return .{
        .exit_code = exit_code,
        .ok = exit_code == 0,
        .stdout_text = if (result.stdout.len > 0) result.stdout else blk: {
            allocator.free(result.stdout);
            break :blk null;
        },
        .stderr_text = if (result.stderr.len > 0) result.stderr else blk: {
            allocator.free(result.stderr);
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

fn isTransportLossError(err: anyerror) bool {
    return err == error.AppServerClosed or err == error.ConnectionResetByPeer or err == error.BrokenPipe or err == error.EndOfStream;
}

fn waitForReviewCompletion(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    event_log_path: []const u8,
    timeout_ms: u32,
    poll_interval_ms: u32,
) !ReviewStatus {
    const started_ms = @divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000);
    var live_notifications = LiveReviewNotificationState{
        .review_thread_id = review_thread_id,
        .review_turn_id = review_turn_id,
    };
    defer live_notifications.deinit(allocator);
    while (true) {
        var captured_notifications: std.ArrayList([]u8) = .empty;
        defer {
            for (captured_notifications.items) |line| allocator.free(line);
            captured_notifications.deinit(allocator);
        }

        const poll_result_json = try client.requestJsonCaptureNotifications(
            "experimentalFeature/list",
            "{\"cursor\":null,\"limit\":1}",
            &captured_notifications,
        );
        allocator.free(poll_result_json);
        try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, &live_notifications);

        if (live_notifications.observed_terminal_status != null) {
            return try fetchReviewStatus(allocator, client, review_thread_id, event_log_path, &live_notifications);
        }
        if (@divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000) - started_ms >= timeout_ms) return error.WaitTimedOut;
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(poll_interval_ms), .awake) catch {};
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
    const parent_event_log_path = try parentEventLogPathAlloc(allocator, session_dir, parent_thread_id);
    defer allocator.free(parent_event_log_path);
    try appendLogRecord(allocator, parent_event_log_path, "thread/start", "request", params_json);
    try appendLogRecord(allocator, parent_event_log_path, "thread/start", "response", result_json);
    return parent_thread_id;
}

fn codexDetachedReviewNeedsLiveConnection(codex_version: []const u8) bool {
    const semver = parseSemverTriplet(codex_version) orelse return false;
    return semver.major == 0 and semver.minor == 118;
}

fn resumeParentThread(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    parent_thread_id: []const u8,
    parent_event_log_path: []const u8,
) !void {
    const params_json = try stringifyAnyAlloc(allocator, .{
        .threadId = parent_thread_id,
    });
    defer allocator.free(params_json);
    const result_json = try client.requestJson("thread/resume", params_json);
    defer allocator.free(result_json);
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
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), base);
    return base;
}

fn laneIdAlloc(allocator: std.mem.Allocator, process_id: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "lane_{d}_{d}", .{
        process_id,
        std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds,
    });
}

fn laneRecordPathAlloc(allocator: std.mem.Allocator, lane_id: []const u8) ![]const u8 {
    const session_dir = try sessionDirAlloc(allocator);
    defer allocator.free(session_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.lane.json", .{ session_dir, lane_id });
}

const LoadedLaneRecord = struct {
    record_path: []const u8,
    raw: []u8,
    parsed: std.json.Parsed(LaneRecord),
    record: LaneRecord,

    fn deinit(self: *LoadedLaneRecord, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw);
        allocator.free(self.record_path);
    }
};

fn loadLaneRecord(allocator: std.mem.Allocator, lane_id: []const u8) !LoadedLaneRecord {
    const record_path = try laneRecordPathAlloc(allocator, lane_id);
    const file = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), record_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    const raw = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    const parsed = try std.json.parseFromSlice(LaneRecord, allocator, raw, .{});
    return .{
        .record_path = record_path,
        .raw = raw,
        .parsed = parsed,
        .record = parsed.value,
    };
}

fn writeLaneRecord(allocator: std.mem.Allocator, path: []const u8, record: LaneRecord) !void {
    try ensureParentPath(path);
    const json = try stringifyAnyAlloc(allocator, record);
    defer allocator.free(json);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ path, std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds });
    defer allocator.free(temp_path);
    var file = try std.Io.Dir.createFileAbsolute(std.Io.Threaded.global_single_threaded.io(), temp_path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), json);
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n");
    try std.Io.Dir.renameAbsolute(temp_path, path, std.Io.Threaded.global_single_threaded.io());
}

fn unixSeconds() i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000));
}

fn parentEventLogPathAlloc(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    parent_thread_id: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.parent.events.ndjson", .{ session_dir, parent_thread_id });
}

fn startManagedWebsocketServer(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    codex_path: []const u8,
    hook_policy: cas.hooks.HookPolicy,
    io: std.Io,
) !cas_websocket.ManagedServer {
    return cas_websocket.startManagedLoopbackServer(allocator, cwd, codex_path, hook_policy, io);
}

fn connectReviewClient(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    codex_path: []const u8,
    codex_version: []const u8,
    transport_kind: ?[]const u8,
    websocket_url: ?[]const u8,
    io: std.Io,
    parsed: ParsedArgs,
) !cas.Client {
    _ = codex_version;
    return cas.Client.start(allocator, .{
        .cwd = cwd,
        .io = io,
        .codex_path = codex_path,
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
        .hook_policy = parsed.hook_policy,
        .websocket_url = if (transport_kind != null and std.mem.eql(u8, transport_kind.?, "websocket")) websocket_url else null,
    });
}

fn makeStoredFallbackStatus(allocator: std.mem.Allocator, record: SessionRecord) !ReviewStatus {
    return .{
        .thread_status = try allocator.dupe(u8, "terminal"),
        .turn_status = try allocator.dupe(u8, record.last_observed_status),
        .turn_count = 1,
        .materialized = true,
        .thread_preview = try allocator.dupe(u8, ""),
        .rollout_path = null,
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = true,
        .last_turn_has_exited_review_mode = true,
        .review_result_available = record.terminal_review_result_json != null,
        .review_result_source = if (record.terminal_review_result_source) |value| try allocator.dupe(u8, value) else null,
        .review_result_json = if (record.terminal_review_result_json) |value| try allocator.dupe(u8, value) else null,
        .review_text = null,
        .raw_response_json = try allocator.dupe(u8, "{}"),
    };
}

fn applyRecordedStatusOverlay(allocator: std.mem.Allocator, record: SessionRecord, status: *ReviewStatus) !void {
    if (std.mem.eql(u8, record.last_observed_status, "interruptRequested") and
        std.mem.eql(u8, status.turn_status, "inProgress"))
    {
        allocator.free(status.turn_status);
        status.turn_status = try allocator.dupe(u8, "interruptRequested");
    }
}

const LoadedSessionRecord = struct {
    record_path: []const u8,
    record: SessionRecord,
};

fn loadSessionRecord(allocator: std.mem.Allocator, review_thread_id: []const u8) !LoadedSessionRecord {
    const session_dir = try sessionDirAlloc(allocator);
    const record_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, review_thread_id });
    const file = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), record_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    const raw = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
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
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ path, std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds });
    defer allocator.free(temp_path);
    var file = try std.Io.Dir.createFileAbsolute(std.Io.Threaded.global_single_threaded.io(), temp_path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), json);
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n");
    try std.Io.Dir.renameAbsolute(temp_path, path, std.Io.Threaded.global_single_threaded.io());
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
            @divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000),
            try quoteJsonStringAlloc(allocator, method),
            try quoteJsonStringAlloc(allocator, direction),
            try quoteJsonStringAlloc(allocator, payload_json),
        },
    );
    defer allocator.free(json_line);
    try ensureParentPath(path);
    var file = std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.createFileAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{ .truncate = false }),
        else => return err,
    };
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    const end_pos = (try file.stat(std.Io.Threaded.global_single_threaded.io())).size;
    var writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try writer.seekTo(end_pos);
    try writer.interface.writeAll(json_line);
    try writer.interface.writeAll("\n");
}

fn ensureParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;

    if (std.fs.path.isAbsolute(parent)) {
        const rel = std.mem.trim(u8, parent, "/");
        if (rel.len == 0) return;
        var root = try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), "/", .{});
        defer root.close(std.Io.Threaded.global_single_threaded.io());
        try root.createDirPath(std.Io.Threaded.global_single_threaded.io(), rel);
        return;
    }

    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), parent);
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
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(text);
        if (!std.mem.endsWith(u8, text, "\n")) try stdout.writeAll("\n");
    }

    if (fallback.stderr_text) |text| {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.writeAll(text);
        if (!std.mem.endsWith(u8, text, "\n")) try stderr.writeAll("\n");
    }
    std.process.exit(if (fallback.ok) 0 else 1);
}

fn maybeRunNativeFallbackAndExitWait(
    allocator: std.mem.Allocator,
    parsed: ParsedArgs,
    record: *SessionRecord,
    record_path: []const u8,
    status: ?ReviewStatus,
    failure: FailureInfo,
) !void {
    if (parsed.fallback_mode != .native_review) return;

    const codex_path = record.resolved_codex_path orelse "codex";
    var fallback = try runNativeReviewFallbackAlloc(allocator, record.cwd, codex_path, record.target);
    defer fallback.deinit(allocator);

    record.last_observed_status = if (fallback.ok) "completed" else "failed";
    record.compatibility_verdict = "compatible";
    record.terminal_fallback_transport = "native-review";
    record.terminal_fallback_exit_code = fallback.exit_code;
    record.terminal_fallback_output_text = fallback.stdout_text;
    record.terminal_fallback_error_text = fallback.stderr_text;
    record.terminal_review_result_source = "native_fallback";
    record.terminal_review_result_json = try buildReviewResultJsonFromRenderedTextAlloc(
        allocator,
        fallback.stdout_text orelse fallback.stderr_text orelse review_fallback_text,
    );
    try writeSessionRecord(allocator, record_path, record.*);

    if (parsed.json) {
        try printStatusJson(
            allocator,
            .wait,
            record.cwd,
            record.parent_thread_id,
            record.review_thread_id,
            record.review_turn_id,
            if (status) |value| value else try makeStoredFallbackStatus(allocator, record.*),
            record_path,
            record.event_log_path,
            record.target,
            null,
            .{
                .resolved_codex_path = record.resolved_codex_path,
                .resolved_codex_version = record.codex_version,
                .compatibility_verdict = record.compatibility_verdict orelse "compatible",
                .selected_transport = "native-review",
                .selection_reason = "websocket_transport_lost",
                .degraded_fallback = true,
                .managed_server_pid = record.managed_server_pid,
                .managed_server_listen_url = record.managed_server_listen_url,
                .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                .orphan_ttl_seconds = record.orphan_ttl_seconds,
            },
            null,
            false,
            failure,
            fallback,
        );
    } else if (fallback.stdout_text) |text| {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(text);
        if (!std.mem.endsWith(u8, text, "\n")) try stdout.writeAll("\n");
    }

    if (fallback.stderr_text) |text| {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.writeAll(text);
        if (!std.mem.endsWith(u8, text, "\n")) try stderr.writeAll("\n");
    }
    std.process.exit(if (fallback.ok) 0 else 1);
}

fn readCodexVersionAlloc(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, codex_path: []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ codex_path, "--version" },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn shouldPreMaterializeDetachedReviewParent(parent_mode: ParentMode, codex_version: []const u8) bool {
    if (parent_mode != .auto) return false;
    return codexDetachedReviewNeedsLiveConnection(codex_version);
}

fn parseSemverTriplet(raw: []const u8) ?SemverTriplet {
    var cursor: usize = 0;
    while (cursor < raw.len and !std.ascii.isDigit(raw[cursor])) : (cursor += 1) {}
    if (cursor == raw.len) return null;

    const major = parseVersionComponent(raw[cursor..]) orelse return null;
    cursor += major.next_offset;
    if (cursor >= raw.len or raw[cursor] != '.') return null;
    cursor += 1;

    const minor = parseVersionComponent(raw[cursor..]) orelse return null;
    cursor += minor.next_offset;
    if (cursor >= raw.len or raw[cursor] != '.') return null;
    cursor += 1;

    const patch = parseVersionComponent(raw[cursor..]) orelse return null;
    return .{
        .major = major.value,
        .minor = minor.value,
        .patch = patch.value,
    };
}

fn parseVersionComponent(raw: []const u8) ?struct { value: u32, next_offset: usize } {
    var len: usize = 0;
    while (len < raw.len and std.ascii.isDigit(raw[len])) : (len += 1) {}
    if (len == 0) return null;
    return .{
        .value = std.fmt.parseInt(u32, raw[0..len], 10) catch return null,
        .next_offset = len,
    };
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
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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
    target: ?TargetRecord,
    identity: ?TargetIdentity,
    receipt: OutputReceipt,
    timeout_ms: ?u32,
    timed_out: ?bool,
    failure: ?FailureInfo,
    fallback: ?NativeFallbackResult,
) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    const cwd_json = if (cwd) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const parent_thread_json = if (parent_thread_id) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const rollout_path_json = if (status.rollout_path) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const record_path_json = if (record_path) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const target_json = if (target) |value| try stringifyAnyAlloc(allocator, value) else "null";
    const target_fingerprint_json = if (identity) |value| try quoteJsonStringAlloc(allocator, value.fingerprint) else "null";
    const head_sha_json = if (identity) |value|
        if (value.head_sha) |sha| try quoteJsonStringAlloc(allocator, sha) else "null"
    else
        "null";
    const base_sha_json = if (identity) |value|
        if (value.base_sha) |sha| try quoteJsonStringAlloc(allocator, sha) else "null"
    else
        "null";
    const review_result_source_json = if (status.review_result_source) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const review_result_json = status.review_result_json orelse "null";
    const review_text_json = if (status.review_text) |text| try quoteJsonStringAlloc(allocator, text) else "null";
    const resolved_codex_path_json = if (receipt.resolved_codex_path) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const resolved_codex_version_json = if (receipt.resolved_codex_version) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const selected_transport_json = try quoteJsonStringAlloc(allocator, receipt.selected_transport);
    const selection_reason_json = try quoteJsonStringAlloc(allocator, receipt.selection_reason);
    const managed_server_pid_json = if (receipt.managed_server_pid) |value|
        try std.fmt.allocPrint(allocator, "{d}", .{value})
    else
        "null";
    const managed_server_listen_url_json = if (receipt.managed_server_listen_url) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const managed_server_stderr_log_path_json = if (receipt.managed_server_stderr_log_path) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const orphan_ttl_seconds_json = if (receipt.orphan_ttl_seconds) |value|
        try std.fmt.allocPrint(allocator, "{d}", .{value})
    else
        "null";
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
    const hook_summary = try hookSummaryFromEventLog(allocator, receipt.hook_policy, receipt.hook_log_path orelse event_log_path);
    const hook_summary_json = try stringifyAnyAlloc(allocator, hook_summary);
    const dual_parse_opt: ?DualParseVerdict = dualParseVerdictAlloc(allocator, status) catch null;
    defer if (dual_parse_opt) |dual_parse| dual_parse.deinit(allocator);
    const dual_parse_verdict_json = if (dual_parse_opt) |dual_parse| try quoteJsonStringAlloc(allocator, dual_parse.verdict) else "null";
    const structured_finding_count_json = if (dual_parse_opt) |dual_parse|
        try std.fmt.allocPrint(allocator, "{d}", .{dual_parse.structured_findings})
    else
        "null";
    const raw_finding_count_json = if (dual_parse_opt) |dual_parse|
        if (dual_parse.raw_findings) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else "null"
    else
        "null";
    const clean_json = if (dual_parse_opt) |dual_parse|
        if (failure == null and status.review_result_available and dual_parse.structured_findings == 0 and !std.mem.eql(u8, dual_parse.verdict, "mismatch")) "true" else "false"
    else
        "null";

    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":\"{s}\",\"cwd\":{s},\"parentThreadId\":{s},\"reviewThreadId\":{s},\"reviewTurnId\":{s},\"threadStatus\":{s},\"turnStatus\":{s},\"turnCount\":{d},\"materialized\":{s},\"rolloutPath\":{s},\"recordPath\":{s},\"eventLogPath\":{s},\"target\":{s},\"targetFingerprint\":{s},\"headSha\":{s},\"baseSha\":{s},\"resolvedCodexPath\":{s},\"resolvedCodexVersion\":{s},\"compatibilityVerdict\":{s},\"selectedTransport\":{s},\"selectionReason\":{s},\"degradedFallback\":{s},\"managedServerPid\":{s},\"managedServerListenUrl\":{s},\"managedServerStderrLogPath\":{s},\"orphanTtlSeconds\":{s}",
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
            target_json,
            target_fingerprint_json,
            head_sha_json,
            base_sha_json,
            resolved_codex_path_json,
            resolved_codex_version_json,
            try quoteJsonStringAlloc(allocator, receipt.compatibility_verdict),
            selected_transport_json,
            selection_reason_json,
            if (receipt.degraded_fallback) "true" else "false",
            managed_server_pid_json,
            managed_server_listen_url_json,
            managed_server_stderr_log_path_json,
            orphan_ttl_seconds_json,
        },
    );
    try stdout.print(
        ",\"timeoutMs\":{s},\"timedOut\":{s},\"failureCode\":{s},\"failureHint\":{s},\"fallbackUsed\":{s},\"fallbackTransport\":{s},\"fallbackExitCode\":{s},\"fallbackOutputText\":{s},\"fallbackErrorText\":{s},\"hookSummary\":{s},\"reviewResultAvailable\":{s},\"reviewResultSource\":{s},\"reviewResult\":{s},\"rawReviewText\":{s},\"dualParseVerdict\":{s},\"structuredFindingCount\":{s},\"rawFindingCount\":{s},\"clean\":{s}}}\n",
        .{
            timeout_json,
            timed_out_json,
            failure_code_json,
            failure_hint_json,
            if (fallback != null) "true" else "false",
            fallback_transport_json,
            fallback_exit_code_json,
            fallback_stdout_json,
            fallback_stderr_json,
            hook_summary_json,
            if (status.review_result_available) "true" else "false",
            review_result_source_json,
            review_result_json,
            review_text_json,
            dual_parse_verdict_json,
            structured_finding_count_json,
            raw_finding_count_json,
            clean_json,
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
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
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
    const selected_transport_json = try quoteJsonStringAlloc(allocator, receipt.selected_transport);
    const selection_reason_json = try quoteJsonStringAlloc(allocator, receipt.selection_reason);
    const managed_server_pid_json = if (receipt.managed_server_pid) |value|
        try std.fmt.allocPrint(allocator, "{d}", .{value})
    else
        "null";
    const managed_server_listen_url_json = if (receipt.managed_server_listen_url) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const managed_server_stderr_log_path_json = if (receipt.managed_server_stderr_log_path) |value| try quoteJsonStringAlloc(allocator, value) else "null";
    const orphan_ttl_seconds_json = if (receipt.orphan_ttl_seconds) |value|
        try std.fmt.allocPrint(allocator, "{d}", .{value})
    else
        "null";
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
    const hook_summary = try hookSummaryFromEventLog(allocator, receipt.hook_policy, receipt.hook_log_path orelse event_log_path);
    const hook_summary_json = try stringifyAnyAlloc(allocator, hook_summary);

    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":\"start\",\"cwd\":{s},\"parentThreadId\":{s},\"reviewThreadId\":{s},\"reviewTurnId\":{s},\"delivery\":\"detached\",\"target\":{s},\"recordPath\":{s},\"eventLogPath\":{s},\"codexVersion\":{s},\"resolvedCodexPath\":{s},\"resolvedCodexVersion\":{s},\"compatibilityVerdict\":{s},\"selectedTransport\":{s},\"selectionReason\":{s},\"degradedFallback\":{s},\"managedServerPid\":{s},\"managedServerListenUrl\":{s},\"managedServerStderrLogPath\":{s},\"orphanTtlSeconds\":{s},\"waited\":{s},\"timedOut\":{s},\"threadStatus\":{s},\"turnStatus\":{s}",
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
            selected_transport_json,
            selection_reason_json,
            if (receipt.degraded_fallback) "true" else "false",
            managed_server_pid_json,
            managed_server_listen_url_json,
            managed_server_stderr_log_path_json,
            orphan_ttl_seconds_json,
            waited_json,
            timed_out_json,
            thread_status_json,
            turn_status_json,
        },
    );
    try stdout.print(
        ",\"turnCount\":{d},\"materialized\":{s},\"rolloutPath\":{s},\"failureCode\":{s},\"failureHint\":{s},\"fallbackUsed\":{s},\"fallbackTransport\":{s},\"fallbackExitCode\":{s},\"fallbackOutputText\":{s},\"fallbackErrorText\":{s},\"hookSummary\":{s},\"reviewResultAvailable\":{s},\"reviewResultSource\":{s},\"reviewResult\":{s}}}\n",
        .{
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
            hook_summary_json,
            review_result_available_json,
            review_result_source_json,
            review_result_json,
        },
    );
}

fn hookSummaryFromEventLog(
    allocator: std.mem.Allocator,
    policy: cas.hooks.HookPolicy,
    event_log_path: []const u8,
) !cas.hooks.HookSummary {
    var accumulator = cas.hooks.HookAccumulator.init(policy, null);
    const file = std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), event_log_path, .{}) catch {
        var summary = accumulator.summary();
        summary.hookLogPath = event_log_path;
        return summary;
    };
    defer file.close(std.Io.Threaded.global_single_threaded.io());

    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(8 * 1024 * 1024)) catch {
        var summary = accumulator.summary();
        summary.hookLogPath = event_log_path;
        return summary;
    };
    defer allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        const payload = core_json.stringField(root, "payload") orelse continue;
        try accumulator.absorbLine(allocator, payload);
    }

    var summary = accumulator.summary();
    summary.hookLogPath = event_log_path;
    return summary;
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
        if (std.mem.eql(u8, status.thread_preview, parent_materialization_prompt) and
            !status.last_turn_has_entered_review_mode)
        {
            return .{
                .code = "incompatible_codex_review_runtime",
                .hint = "detached review resolved to the fresh-parent bootstrap thread instead of a review-mode thread; installed codex runtime is not producing a usable detached review thread on this path",
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
    const file = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), rollout_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    const bytes = try reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
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

fn buildReviewResultJsonFromRenderedTextAlloc(allocator: std.mem.Allocator, review_text: []const u8) ![]u8 {
    var findings = std.ArrayList(ReviewFindingJson).empty;
    defer findings.deinit(allocator);
    const trimmed = std.mem.trim(u8, review_text, " \t\r\n");
    var overall_explanation = if (trimmed.len > 0) trimmed else "Reviewer failed to output a response.";
    var first_finding_offset: ?usize = null;
    var current_finding_index: ?usize = null;
    var current_body = std.ArrayList(u8).empty;
    defer current_body.deinit(allocator);

    var offset: usize = 0;
    while (offset < trimmed.len) {
        const line_end = std.mem.indexOfScalarPos(u8, trimmed, offset, '\n') orelse trimmed.len;
        const line = trimmed[offset..line_end];
        const line_trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (parseRenderedFindingHeader(line_trimmed)) |header| {
            if (current_finding_index) |index| {
                findings.items[index].body = try allocator.dupe(u8, std.mem.trim(u8, current_body.items, " \t\r\n"));
                current_body.clearRetainingCapacity();
            }
            if (first_finding_offset == null) {
                first_finding_offset = offset;
                const prefix = std.mem.trim(u8, trimmed[0..offset], " \t\r\n");
                if (prefix.len > 0) overall_explanation = prefix;
            }
            try findings.append(allocator, .{
                .title = header.title,
                .body = "",
                .confidenceScore = 0.0,
                .priority = header.priority,
                .codeLocation = .{
                    .absoluteFilePath = header.path,
                    .lineRange = .{
                        .start = header.start,
                        .end = header.end,
                    },
                },
            });
            current_finding_index = findings.items.len - 1;
        } else if (current_finding_index != null and line_trimmed.len > 0) {
            if (current_body.items.len > 0) try current_body.append(allocator, '\n');
            try current_body.appendSlice(allocator, line_trimmed);
        }
        offset = if (line_end == trimmed.len) trimmed.len else line_end + 1;
    }
    if (current_finding_index) |index| {
        findings.items[index].body = try allocator.dupe(u8, std.mem.trim(u8, current_body.items, " \t\r\n"));
    }
    const payload = ReviewResultJson{
        .findings = try findings.toOwnedSlice(allocator),
        .overallCorrectness = "",
        .overallExplanation = overall_explanation,
        .overallConfidenceScore = 0.0,
    };
    defer {
        for (payload.findings) |finding| if (finding.body.len > 0) allocator.free(finding.body);
        allocator.free(payload.findings);
    }
    return stringifyAnyAlloc(allocator, payload);
}

const RenderedFindingHeader = struct {
    priority: i32,
    title: []const u8,
    path: []const u8,
    start: u32,
    end: u32,
};

fn parseRenderedFindingHeader(line: []const u8) ?RenderedFindingHeader {
    if (!std.mem.startsWith(u8, line, "- [P")) return null;
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return null;
    const priority = std.fmt.parseInt(i32, line[4..close], 10) catch return null;

    const tail_start = close + 1;
    const location = parseTrailingLocation(line[tail_start..]) orelse return null;
    var title_part = std.mem.trim(u8, line[tail_start .. tail_start + location.location_start], " \t-");
    while (std.mem.startsWith(u8, title_part, "\xe2\x80\x94")) {
        title_part = std.mem.trim(u8, title_part[3..], " \t-");
    }
    while (std.mem.endsWith(u8, title_part, "\xe2\x80\x94")) {
        title_part = std.mem.trim(u8, title_part[0 .. title_part.len - 3], " \t-");
    }
    if (title_part.len == 0) return null;
    return .{
        .priority = priority,
        .title = title_part,
        .path = location.path,
        .start = location.start,
        .end = location.end,
    };
}

fn parseTrailingLocation(text: []const u8) ?struct {
    location_start: usize,
    path: []const u8,
    start: u32,
    end: u32,
} {
    var colon_index: ?usize = null;
    var cursor = text.len;
    while (cursor > 0) {
        cursor -= 1;
        if (text[cursor] == ':') {
            colon_index = cursor;
            break;
        }
    }
    const colon = colon_index orelse return null;
    if (colon + 1 >= text.len or !std.ascii.isDigit(text[colon + 1])) return null;

    var number_end = colon + 1;
    while (number_end < text.len and std.ascii.isDigit(text[number_end])) : (number_end += 1) {}
    const start = std.fmt.parseInt(u32, text[colon + 1 .. number_end], 10) catch return null;
    var end = start;
    if (number_end < text.len and text[number_end] == '-') {
        const range_start = number_end + 1;
        var range_end = range_start;
        while (range_end < text.len and std.ascii.isDigit(text[range_end])) : (range_end += 1) {}
        if (range_end == range_start) return null;
        end = std.fmt.parseInt(u32, text[range_start..range_end], 10) catch return null;
    }

    const before_path = text[0..colon];
    const slash = std.mem.lastIndexOfScalar(u8, before_path, '/') orelse return null;
    var path_start = slash;
    while (path_start > 0 and !std.ascii.isWhitespace(before_path[path_start - 1])) : (path_start -= 1) {}
    const path = before_path[path_start..];
    if (path.len == 0) return null;
    return .{
        .location_start = path_start,
        .path = path,
        .start = start,
        .end = end,
    };
}

fn reviewFindingCount(allocator: std.mem.Allocator, review_result_json: ?[]const u8) !usize {
    const raw = review_result_json orelse return 0;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return 0,
    };
    const findings_val = root_obj.get("findings") orelse return 0;
    return switch (findings_val) {
        .array => |arr| arr.items.len,
        else => 0,
    };
}

fn dualParseVerdictAlloc(allocator: std.mem.Allocator, status: ReviewStatus) !DualParseVerdict {
    const structured_findings = try reviewFindingCount(allocator, status.review_result_json);
    const review_text = status.review_text orelse {
        return .{
            .verdict = try allocator.dupe(u8, "raw_unavailable"),
            .structured_findings = structured_findings,
            .raw_findings = null,
            .raw_review_text_available = false,
        };
    };
    const raw_json = try buildReviewResultJsonFromRenderedTextAlloc(allocator, review_text);
    defer allocator.free(raw_json);
    const raw_findings = try reviewFindingCount(allocator, raw_json);
    return .{
        .verdict = try allocator.dupe(u8, if (structured_findings == raw_findings) "match" else "mismatch"),
        .structured_findings = structured_findings,
        .raw_findings = raw_findings,
        .raw_review_text_available = true,
    };
}

fn archiveThreadBestEffort(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    thread_id: []const u8,
    event_log_path: []const u8,
    label: []const u8,
) !bool {
    const params_json = try stringifyAnyAlloc(allocator, .{ .threadId = thread_id });
    defer allocator.free(params_json);
    const result_json = client.requestJson("thread/archive", params_json) catch |err| {
        const note = try std.fmt.allocPrint(allocator, "{{\"label\":{s},\"threadId\":{s},\"error\":{s}}}", .{
            try quoteJsonStringAlloc(allocator, label),
            try quoteJsonStringAlloc(allocator, thread_id),
            try quoteJsonStringAlloc(allocator, client.lastError() orelse @errorName(err)),
        });
        defer allocator.free(note);
        appendLogRecord(allocator, event_log_path, "thread/archive", "warning", note) catch {};
        return false;
    };
    defer allocator.free(result_json);
    try appendLogRecord(allocator, event_log_path, "thread/archive", "request", params_json);
    try appendLogRecord(allocator, event_log_path, "thread/archive", "response", result_json);
    return true;
}

fn archiveLaneThreadsBestEffort(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    parent_thread_id: []const u8,
    review_thread_id: []const u8,
    event_log_path: []const u8,
) ![]const u8 {
    const parent_ok = try archiveThreadBestEffort(allocator, client, parent_thread_id, event_log_path, "parent");
    const review_ok = try archiveThreadBestEffort(allocator, client, review_thread_id, event_log_path, "review");
    if (parent_ok and review_ok) return allocator.dupe(u8, "ok");
    if (parent_ok or review_ok) return allocator.dupe(u8, "partial");
    return allocator.dupe(u8, "failed");
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

fn writeNullableJsonString(writer: *std.Io.Writer, text: ?[]const u8) !void {
    if (text) |value| try writeJsonString(writer, value) else try writer.writeAll("null");
}

fn writeNullableJsonBool(writer: *std.Io.Writer, value: ?bool) !void {
    if (value) |flag| try writer.writeAll(if (flag) "true" else "false") else try writer.writeAll("null");
}

fn writeNullableJsonUsize(writer: *std.Io.Writer, value: ?usize) !void {
    if (value) |number| try writer.print("{d}", .{number}) else try writer.writeAll("null");
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{});
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(max_bytes));
    }
    var file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn expandReceiptGlob(allocator: std.mem.Allocator, pattern: []const u8, out: *std.ArrayList([]const u8)) !void {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        try out.append(allocator, try allocator.dupe(u8, pattern));
        return;
    }
    const slash_idx = std.mem.lastIndexOfScalar(u8, pattern, '/');
    const dir_path = if (slash_idx) |idx|
        if (idx == 0) "/" else pattern[0..idx]
    else
        ".";
    const file_pat = if (slash_idx) |idx| pattern[idx + 1 ..] else pattern;
    const star_idx = std.mem.indexOfScalar(u8, file_pat, '*') orelse return;
    const prefix = file_pat[0..star_idx];
    const suffix = file_pat[star_idx + 1 ..];

    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), dir_path, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), dir_path, .{ .iterate = true });
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var it = dir.iterate();
    while (try it.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const full = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else if (std.mem.eql(u8, dir_path, "/"))
            try std.fmt.allocPrint(allocator, "/{s}", .{entry.name})
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        try out.append(allocator, full);
    }
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonI64Field(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        else => null,
    };
}

fn jsonBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn jsonUsizeField(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn dupOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn optionalStringFromVerdictOrRoot(verdict: std.json.ObjectMap, root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return jsonStringField(verdict, key) orelse jsonStringField(root, key);
}

fn stringifyJsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn normalizeReceiptFromPathAlloc(allocator: std.mem.Allocator, path: []const u8) !NormalizedReceipt {
    const raw = try readFileAlloc(allocator, path, 8 * 1024 * 1024);
    defer allocator.free(raw);
    return normalizeReceiptFromJsonAlloc(allocator, path, raw);
}

fn normalizeReceiptFromJsonAlloc(allocator: std.mem.Allocator, source_path: []const u8, raw: []const u8) !NormalizedReceipt {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidReceiptJson,
    };
    const verdict = if (root.get("reviewVerdict")) |value| switch (value) {
        .object => |obj| obj,
        else => return error.InvalidReviewVerdict,
    } else root;

    const receipt_status = jsonStringField(verdict, "status") orelse return error.MissingReceiptStatus;
    const backend_class = jsonStringField(verdict, "backendClass") orelse return error.MissingBackendClass;
    const clean = jsonBoolField(verdict, "clean") orelse return error.MissingCleanFlag;
    const finding_count = jsonUsizeField(verdict, "findingCount") orelse return error.MissingFindingCount;
    const findings_json = if (verdict.get("findings")) |value|
        try stringifyJsonValueAlloc(allocator, value)
    else
        try allocator.dupe(u8, "[]");

    return .{
        .source_path = try allocator.dupe(u8, source_path),
        .status = try allocator.dupe(u8, receipt_status),
        .backend_class = try allocator.dupe(u8, backend_class),
        .clean = clean,
        .finding_count = finding_count,
        .base_sha = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "baseSha")),
        .head_sha = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "headSha")),
        .target_fingerprint = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "targetFingerprint")),
        .review_thread_id = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "reviewThreadId")),
        .review_turn_id = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "reviewTurnId")),
        .record_path = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "recordPath")),
        .event_log_path = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "eventLogPath")),
        .failure_code = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "failureCode")),
        .failure_hint = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "failureHint")),
        .findings_json = findings_json,
    };
}

fn summarizeReceipts(receipts: []const NormalizedReceipt) ReceiptSummary {
    var summary = ReceiptSummary{ .total = receipts.len };
    for (receipts) |receipt| {
        if (std.mem.eql(u8, receipt.status, "clean")) summary.clean += 1 else if (std.mem.eql(u8, receipt.status, "findings")) summary.findings += 1 else if (std.mem.eql(u8, receipt.status, "timeout")) summary.timeout += 1 else if (std.mem.eql(u8, receipt.status, "parse_mismatch")) summary.parse_mismatch += 1 else if (std.mem.eql(u8, receipt.status, "transport_failure")) summary.transport_failure += 1 else if (std.mem.eql(u8, receipt.status, "incomplete")) summary.incomplete += 1 else summary.other_status += 1;
        if (std.mem.eql(u8, receipt.backend_class, "cas-lane")) summary.cas_lane += 1 else if (std.mem.eql(u8, receipt.backend_class, "cas-native-fallback")) summary.cas_native_fallback += 1 else summary.other_backend += 1;
    }
    return summary;
}

fn writeReceiptObject(writer: *std.Io.Writer, receipt: NormalizedReceipt) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "sourcePath");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.source_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "status");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.status);
    try writer.writeByte(',');
    try writeJsonString(writer, "backendClass");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.backend_class);
    try writer.writeByte(',');
    try writeJsonString(writer, "clean");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.clean) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "findingCount");
    try writer.writeByte(':');
    try writer.print("{d}", .{receipt.finding_count});
    try writer.writeByte(',');
    try writeJsonString(writer, "baseSha");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.base_sha);
    try writer.writeByte(',');
    try writeJsonString(writer, "headSha");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.head_sha);
    try writer.writeByte(',');
    try writeJsonString(writer, "targetFingerprint");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.target_fingerprint);
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewThreadId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.review_thread_id);
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewTurnId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.review_turn_id);
    try writer.writeByte(',');
    try writeJsonString(writer, "recordPath");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.record_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "eventLogPath");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.event_log_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "failureCode");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.failure_code);
    try writer.writeByte(',');
    try writeJsonString(writer, "failureHint");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.failure_hint);
    try writer.writeByte(',');
    try writeJsonString(writer, "findings");
    try writer.writeByte(':');
    try writer.writeAll(receipt.findings_json);
    try writer.writeByte('}');
}

fn writeReceiptErrorObject(writer: *std.Io.Writer, err: ReceiptError) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "sourcePath");
    try writer.writeByte(':');
    try writeJsonString(writer, err.source_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "error");
    try writer.writeByte(':');
    try writeJsonString(writer, err.message);
    try writer.writeByte('}');
}

fn writeReceiptSummaryObject(writer: *std.Io.Writer, summary: ReceiptSummary) !void {
    try writer.print(
        "{{\"total\":{d},\"status\":{{\"clean\":{d},\"findings\":{d},\"timeout\":{d},\"parse_mismatch\":{d},\"transport_failure\":{d},\"incomplete\":{d},\"other\":{d}}},\"backendClass\":{{\"cas-lane\":{d},\"cas-native-fallback\":{d},\"other\":{d}}}}}",
        .{
            summary.total,
            summary.clean,
            summary.findings,
            summary.timeout,
            summary.parse_mismatch,
            summary.transport_failure,
            summary.incomplete,
            summary.other_status,
            summary.cas_lane,
            summary.cas_native_fallback,
            summary.other_backend,
        },
    );
}

fn printReceiptJson(receipts: []const NormalizedReceipt, errors: []const ReceiptError, summary: ?ReceiptSummary) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"receipts\":[");
    for (receipts, 0..) |receipt, i| {
        if (i > 0) try stdout.writeByte(',');
        try writeReceiptObject(stdout, receipt);
    }
    try stdout.writeAll("],\"summary\":");
    if (summary) |value| try writeReceiptSummaryObject(stdout, value) else try stdout.writeAll("null");
    try stdout.writeAll(",\"errors\":[");
    for (errors, 0..) |err, i| {
        if (i > 0) try stdout.writeByte(',');
        try writeReceiptErrorObject(stdout, err);
    }
    try stdout.writeAll("]}\n");
}

fn printReceiptJsonl(receipts: []const NormalizedReceipt, errors: []const ReceiptError, summary: ?ReceiptSummary) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    for (receipts) |receipt| {
        try writeReceiptObject(stdout, receipt);
        try stdout.writeByte('\n');
    }
    for (errors) |err| {
        try stdout.writeAll("{\"recordType\":\"error\",");
        try writeJsonString(stdout, "sourcePath");
        try stdout.writeByte(':');
        try writeJsonString(stdout, err.source_path);
        try stdout.writeByte(',');
        try writeJsonString(stdout, "error");
        try stdout.writeByte(':');
        try writeJsonString(stdout, err.message);
        try stdout.writeAll("}\n");
    }
    if (summary) |value| {
        try stdout.writeAll("{\"recordType\":\"summary\",");
        try stdout.writeAll("\"summary\":");
        try writeReceiptSummaryObject(stdout, value);
        try stdout.writeAll("}\n");
    }
}

fn printReceiptTable(receipts: []const NormalizedReceipt, errors: []const ReceiptError, summary: ?ReceiptSummary) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("sourcePath\tstatus\tbackendClass\tclean\tfindingCount\tbaseSha\theadSha\ttargetFingerprint\tfailureCode\n");
    for (receipts) |receipt| {
        try stdout.print("{s}\t{s}\t{s}\t{s}\t{d}\t{s}\t{s}\t{s}\t{s}\n", .{
            receipt.source_path,
            receipt.status,
            receipt.backend_class,
            if (receipt.clean) "true" else "false",
            receipt.finding_count,
            receipt.base_sha orelse "",
            receipt.head_sha orelse "",
            receipt.target_fingerprint orelse "",
            receipt.failure_code orelse "",
        });
    }
    for (errors) |err| {
        try stdout.print("{s}\terror\t\tfalse\t0\t\t\t\t{s}\n", .{ err.source_path, err.message });
    }
    if (summary) |value| {
        try stdout.print("# summary total={d} clean={d} findings={d} timeout={d} parse_mismatch={d} transport_failure={d} incomplete={d} other={d} cas-lane={d} cas-native-fallback={d} other-backend={d}\n", .{
            value.total,
            value.clean,
            value.findings,
            value.timeout,
            value.parse_mismatch,
            value.transport_failure,
            value.incomplete,
            value.other_status,
            value.cas_lane,
            value.cas_native_fallback,
            value.other_backend,
        });
    }
}

fn compactFindingsJsonAlloc(allocator: std.mem.Allocator, review_result_json: ?[]const u8) ![]u8 {
    const raw = review_result_json orelse return allocator.dupe(u8, "[]");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('[');
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            try writer.writeByte(']');
            return out.toOwnedSlice();
        },
    };
    const findings_val = root_obj.get("findings") orelse {
        try writer.writeByte(']');
        return out.toOwnedSlice();
    };
    const findings = switch (findings_val) {
        .array => |arr| arr,
        else => {
            try writer.writeByte(']');
            return out.toOwnedSlice();
        },
    };

    var emitted: usize = 0;
    for (findings.items) |finding_val| {
        const finding = switch (finding_val) {
            .object => |obj| obj,
            else => continue,
        };
        if (emitted > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writeJsonString(writer, "title");
        try writer.writeByte(':');
        try writeNullableJsonString(writer, jsonStringField(finding, "title"));
        try writer.writeByte(',');
        try writeJsonString(writer, "file");
        try writer.writeByte(':');
        var file_path: ?[]const u8 = null;
        var start_line: ?i64 = null;
        if (finding.get("codeLocation")) |location_val| switch (location_val) {
            .object => |location| {
                file_path = jsonStringField(location, "absoluteFilePath");
                if (location.get("lineRange")) |range_val| switch (range_val) {
                    .object => |range| start_line = jsonI64Field(range, "start"),
                    else => {},
                };
            },
            else => {},
        };
        try writeNullableJsonString(writer, file_path);
        try writer.writeByte(',');
        try writeJsonString(writer, "line");
        try writer.writeByte(':');
        if (start_line) |line| try writer.print("{d}", .{line}) else try writer.writeAll("null");
        try writer.writeByte(',');
        try writeJsonString(writer, "priority");
        try writer.writeByte(':');
        if (jsonI64Field(finding, "priority")) |priority| try writer.print("{d}", .{priority}) else try writer.writeAll("null");
        try writer.writeByte('}');
        emitted += 1;
    }
    try writer.writeByte(']');
    return out.toOwnedSlice();
}

fn reviewVerdictStatus(clean: ?bool, finding_count: ?usize, failure: ?FailureInfo) []const u8 {
    if (failure) |info| {
        if (std.mem.eql(u8, info.code, "wait_timed_out")) return "timeout";
        if (std.mem.eql(u8, info.code, "review_parse_mismatch")) return "parse_mismatch";
        if (std.mem.indexOf(u8, info.code, "transport") != null) return "transport_failure";
        return "incomplete";
    }
    if (clean orelse false) return "clean";
    if ((finding_count orelse 0) > 0) return "findings";
    return "incomplete";
}

fn buildReviewVerdictJsonAlloc(
    allocator: std.mem.Allocator,
    backend_class: []const u8,
    clean: ?bool,
    finding_count: ?usize,
    failure: ?FailureInfo,
    identity: TargetIdentity,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: ?[]const u8,
    event_log_path: ?[]const u8,
    review_result_json: ?[]const u8,
) ![]u8 {
    const findings_json = compactFindingsJsonAlloc(allocator, review_result_json) catch try allocator.dupe(u8, "[]");
    defer allocator.free(findings_json);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('{');
    try writeJsonString(writer, "status");
    try writer.writeByte(':');
    try writeJsonString(writer, reviewVerdictStatus(clean, finding_count, failure));
    try writer.writeByte(',');
    try writeJsonString(writer, "backendClass");
    try writer.writeByte(':');
    try writeJsonString(writer, backend_class);
    try writer.writeByte(',');
    try writeJsonString(writer, "clean");
    try writer.writeByte(':');
    try writeNullableJsonBool(writer, clean);
    try writer.writeByte(',');
    try writeJsonString(writer, "findingCount");
    try writer.writeByte(':');
    try writeNullableJsonUsize(writer, finding_count);
    try writer.writeByte(',');
    try writeJsonString(writer, "failureCode");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, if (failure) |value| value.code else null);
    try writer.writeByte(',');
    try writeJsonString(writer, "failureHint");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, if (failure) |value| value.hint else null);
    try writer.writeByte(',');
    try writeJsonString(writer, "baseSha");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, identity.base_sha);
    try writer.writeByte(',');
    try writeJsonString(writer, "headSha");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, identity.head_sha);
    try writer.writeByte(',');
    try writeJsonString(writer, "targetFingerprint");
    try writer.writeByte(':');
    try writeJsonString(writer, identity.fingerprint);
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewThreadId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, review_thread_id);
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewTurnId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, review_turn_id);
    try writer.writeByte(',');
    try writeJsonString(writer, "recordPath");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, record_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "eventLogPath");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, event_log_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "findings");
    try writer.writeByte(':');
    try writer.writeAll(findings_json);
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn printLaneFallbackJson(
    allocator: std.mem.Allocator,
    lane: LaneRecord,
    lane_record_path: []const u8,
    target: TargetRecord,
    identity: TargetIdentity,
    fallback: NativeFallbackResult,
    failure: FailureInfo,
    verdict_only: bool,
) !void {
    const target_json = try stringifyAnyAlloc(allocator, target);
    const fallback_stdout_json = if (fallback.stdout_text) |text| try quoteJsonStringAlloc(allocator, text) else "null";
    const fallback_stderr_json = if (fallback.stderr_text) |text| try quoteJsonStringAlloc(allocator, text) else "null";
    const review_verdict_json = try buildReviewVerdictJsonAlloc(
        allocator,
        "cas-native-fallback",
        null,
        null,
        failure,
        identity,
        null,
        null,
        null,
        null,
        null,
    );
    defer allocator.free(review_verdict_json);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (verdict_only) {
        try stdout.print("{s}\n", .{review_verdict_json});
        return;
    }
    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":\"lane-review\",\"laneId\":{s},\"cwd\":{s},\"laneRecordPath\":{s},\"target\":{s},\"targetFingerprint\":{s},\"headSha\":{s},\"baseSha\":{s},\"selectedTransport\":\"native-review\",\"fallbackUsed\":true,\"fallbackTransport\":\"native-review\",\"fallbackExitCode\":{d},\"fallbackOutputText\":{s},\"fallbackErrorText\":{s},\"failureCode\":{s},\"failureHint\":{s},\"reviewVerdict\":{s}}}\n",
        .{
            try quoteJsonStringAlloc(allocator, lane.lane_id),
            try quoteJsonStringAlloc(allocator, lane.cwd),
            try quoteJsonStringAlloc(allocator, lane_record_path),
            target_json,
            try quoteJsonStringAlloc(allocator, identity.fingerprint),
            if (identity.head_sha) |value| try quoteJsonStringAlloc(allocator, value) else "null",
            if (identity.base_sha) |value| try quoteJsonStringAlloc(allocator, value) else "null",
            fallback.exit_code,
            fallback_stdout_json,
            fallback_stderr_json,
            try quoteJsonStringAlloc(allocator, failure.code),
            try quoteJsonStringAlloc(allocator, failure.hint),
            review_verdict_json,
        },
    );
}

fn printLaneReviewJson(
    allocator: std.mem.Allocator,
    lane: LaneRecord,
    lane_record_path: []const u8,
    target: TargetRecord,
    identity: TargetIdentity,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    record_path: []const u8,
    event_log_path: []const u8,
    status: ReviewStatus,
    dual_parse: DualParseVerdict,
    archive_status: []const u8,
    clean: bool,
    failure: ?FailureInfo,
    verdict_only: bool,
) !void {
    const target_json = try stringifyAnyAlloc(allocator, target);
    const review_result_json = status.review_result_json orelse "null";
    const review_text_json = if (status.review_text) |text| try quoteJsonStringAlloc(allocator, text) else "null";
    const raw_findings_json = if (dual_parse.raw_findings) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else "null";
    const failure_code_json = if (failure) |value| try quoteJsonStringAlloc(allocator, value.code) else "null";
    const failure_hint_json = if (failure) |value| try quoteJsonStringAlloc(allocator, value.hint) else "null";
    const review_verdict_json = try buildReviewVerdictJsonAlloc(
        allocator,
        "cas-lane",
        clean,
        dual_parse.structured_findings,
        failure,
        identity,
        review_thread_id,
        review_turn_id,
        record_path,
        event_log_path,
        status.review_result_json,
    );
    defer allocator.free(review_verdict_json);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (verdict_only) {
        try stdout.print("{s}\n", .{review_verdict_json});
        return;
    }
    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":\"lane-review\",\"laneId\":{s},\"cwd\":{s},\"laneRecordPath\":{s},\"reviewCount\":{d},\"reviewThreadId\":{s},\"reviewTurnId\":{s},\"recordPath\":{s},\"eventLogPath\":{s},\"target\":{s},\"targetFingerprint\":{s},\"headSha\":{s},\"baseSha\":{s},\"selectedTransport\":\"websocket\",\"fallbackUsed\":false,\"managedServerPid\":{d},\"managedServerListenUrl\":{s},\"turnStatus\":{s},\"reviewResultAvailable\":{s},\"reviewResultSource\":{s},\"reviewResult\":{s},\"rawReviewText\":{s},\"dualParseVerdict\":{s},\"structuredFindingCount\":{d},\"rawFindingCount\":{s},\"archiveStatus\":{s},\"failureCode\":{s},\"failureHint\":{s},\"clean\":{s},\"reviewVerdict\":{s}}}\n",
        .{
            try quoteJsonStringAlloc(allocator, lane.lane_id),
            try quoteJsonStringAlloc(allocator, lane.cwd),
            try quoteJsonStringAlloc(allocator, lane_record_path),
            lane.review_count,
            try quoteJsonStringAlloc(allocator, review_thread_id),
            try quoteJsonStringAlloc(allocator, review_turn_id),
            try quoteJsonStringAlloc(allocator, record_path),
            try quoteJsonStringAlloc(allocator, event_log_path),
            target_json,
            try quoteJsonStringAlloc(allocator, identity.fingerprint),
            if (identity.head_sha) |value| try quoteJsonStringAlloc(allocator, value) else "null",
            if (identity.base_sha) |value| try quoteJsonStringAlloc(allocator, value) else "null",
            lane.managed_server_pid,
            try quoteJsonStringAlloc(allocator, lane.managed_server_listen_url),
            try quoteJsonStringAlloc(allocator, status.turn_status),
            if (status.review_result_available) "true" else "false",
            if (status.review_result_source) |value| try quoteJsonStringAlloc(allocator, value) else "null",
            review_result_json,
            review_text_json,
            try quoteJsonStringAlloc(allocator, dual_parse.verdict),
            dual_parse.structured_findings,
            raw_findings_json,
            try quoteJsonStringAlloc(allocator, archive_status),
            failure_code_json,
            failure_hint_json,
            if (clean) "true" else "false",
            review_verdict_json,
        },
    );
}

fn printLaneReviewTimeoutJson(
    allocator: std.mem.Allocator,
    lane: LaneRecord,
    lane_record_path: []const u8,
    target: TargetRecord,
    identity: TargetIdentity,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    record_path: []const u8,
    event_log_path: []const u8,
    timeout_ms: u32,
    verdict_only: bool,
) !void {
    const target_json = try stringifyAnyAlloc(allocator, target);
    const failure = FailureInfo{
        .code = "wait_timed_out",
        .hint = "retry cas review_session wait on the same reviewThreadId or increase --timeout-ms",
    };
    const review_verdict_json = try buildReviewVerdictJsonAlloc(
        allocator,
        "cas-lane",
        false,
        0,
        failure,
        identity,
        review_thread_id,
        review_turn_id,
        record_path,
        event_log_path,
        null,
    );
    defer allocator.free(review_verdict_json);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (verdict_only) {
        try stdout.print("{s}\n", .{review_verdict_json});
        return;
    }
    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":\"lane-review\",\"method\":\"review/wait\",\"laneId\":{s},\"cwd\":{s},\"laneRecordPath\":{s},\"reviewCount\":{d},\"reviewThreadId\":{s},\"reviewTurnId\":{s},\"recordPath\":{s},\"eventLogPath\":{s},\"target\":{s},\"targetFingerprint\":{s},\"headSha\":{s},\"baseSha\":{s},\"selectedTransport\":\"websocket\",\"fallbackUsed\":false,\"managedServerPid\":{d},\"managedServerListenUrl\":{s},\"timeoutMs\":{d},\"timedOut\":true,\"reviewResultAvailable\":false,\"reviewResultSource\":null,\"reviewResult\":null,\"rawReviewText\":null,\"dualParseVerdict\":\"timeout\",\"structuredFindingCount\":0,\"rawFindingCount\":null,\"archiveStatus\":\"skipped_timeout\",\"failureCode\":\"wait_timed_out\",\"failureHint\":\"retry cas review_session wait --review-thread-id {s} --timeout-ms {d} --json\",\"clean\":false,\"reviewVerdict\":{s}}}\n",
        .{
            try quoteJsonStringAlloc(allocator, lane.lane_id),
            try quoteJsonStringAlloc(allocator, lane.cwd),
            try quoteJsonStringAlloc(allocator, lane_record_path),
            lane.review_count,
            try quoteJsonStringAlloc(allocator, review_thread_id),
            try quoteJsonStringAlloc(allocator, review_turn_id),
            try quoteJsonStringAlloc(allocator, record_path),
            try quoteJsonStringAlloc(allocator, event_log_path),
            target_json,
            try quoteJsonStringAlloc(allocator, identity.fingerprint),
            if (identity.head_sha) |value| try quoteJsonStringAlloc(allocator, value) else "null",
            if (identity.base_sha) |value| try quoteJsonStringAlloc(allocator, value) else "null",
            lane.managed_server_pid,
            try quoteJsonStringAlloc(allocator, lane.managed_server_listen_url),
            timeout_ms,
            try quoteJsonStringAlloc(allocator, review_thread_id),
            timeout_ms,
            review_verdict_json,
        },
    );
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
        "--hooks",
        "require-observed",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(ParentMode.reuse, parsed.parent_mode);
    try std.testing.expectEqual(FallbackMode.native_review, parsed.fallback_mode);
    try std.testing.expectEqualStrings("thr_parent", parsed.parent_thread_id.?);
    try std.testing.expectEqualStrings("decline", parsed.exec_approval.?);
    try std.testing.expectEqualStrings("acceptForSession", parsed.file_approval.?);
    try std.testing.expectEqualStrings("grant-session", parsed.permissions_approval.?);
    try std.testing.expectEqual(cas.hooks.HookPolicy.require_observed, parsed.hook_policy);
}

test "parseArgs accepts review lane start" {
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "start",
        "--cwd",
        "/tmp/repo",
        "--hooks",
        "off",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Action.lane, parsed.action.?);
    try std.testing.expectEqual(LaneAction.start, parsed.lane_action.?);
    try std.testing.expectEqualStrings("/tmp/repo", parsed.cwd.?);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(cas.hooks.HookPolicy.off, parsed.hook_policy);
}

test "parseArgs accepts review lane review target" {
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "review",
        "--lane-id",
        "lane_123",
        "--base",
        "main",
        "--fallback",
        "native-review",
        "--no-archive",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Action.lane, parsed.action.?);
    try std.testing.expectEqual(LaneAction.review, parsed.lane_action.?);
    try std.testing.expectEqualStrings("lane_123", parsed.lane_id.?);
    try std.testing.expectEqual(TargetKind.base_branch, parsed.target.?.kind);
    try std.testing.expectEqualStrings("main", parsed.target.?.branch.?);
    try std.testing.expectEqual(FallbackMode.native_review, parsed.fallback_mode);
    try std.testing.expect(!parsed.archive_lane_threads);
}

test "parseArgs accepts lane review verdict-only output" {
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "review",
        "--lane-id",
        "lane_123",
        "--base",
        "main",
        "--verdict-only",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Action.lane, parsed.action.?);
    try std.testing.expectEqual(LaneAction.review, parsed.lane_action.?);
    try std.testing.expect(parsed.verdict_only);
    try std.testing.expect(parsed.json);
}

test "parseArgs accepts receipt inputs and format" {
    const argv = [_][]const u8{
        "cas_review_session",
        "receipt",
        "--path",
        "review-1.json",
        "--glob",
        "reviews/*.json",
        "--format",
        "jsonl",
        "--summary",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(parsed.receipt_paths);
    defer std.testing.allocator.free(parsed.receipt_globs);
    try std.testing.expectEqual(Action.receipt, parsed.action.?);
    try std.testing.expectEqualStrings("review-1.json", parsed.receipt_paths[0]);
    try std.testing.expectEqualStrings("reviews/*.json", parsed.receipt_globs[0]);
    try std.testing.expectEqual(ReceiptFormat.jsonl, parsed.receipt_format);
    try std.testing.expect(parsed.receipt_summary);
}

test "expandReceiptGlob matches current-directory patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "review-a.json", .data = "{}" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "review-b.json", .data = "{}" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "other.txt", .data = "" });

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);
    const old_cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(old_cwd);
    try std.Io.Threaded.chdir(tmp_path);
    defer std.Io.Threaded.chdir(old_cwd) catch {};

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| std.testing.allocator.free(path);
        paths.deinit(std.testing.allocator);
    }
    try expandReceiptGlob(std.testing.allocator, "review-*.json", &paths);
    std.mem.sort([]const u8, paths.items, {}, lessThanString);
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expectEqualStrings("review-a.json", paths.items[0]);
    try std.testing.expectEqualStrings("review-b.json", paths.items[1]);
}

test "receipt normalizer accepts full CAS receipt" {
    const raw =
        \\{"demo":"cas-review-session","action":"lane-review","reviewThreadId":"thr_1","reviewTurnId":"turn_1","recordPath":"/tmp/record.json","eventLogPath":"/tmp/event.jsonl","targetFingerprint":"fp_1","headSha":"head_1","baseSha":"base_1","reviewVerdict":{"status":"clean","backendClass":"cas-lane","clean":true,"findingCount":0,"failureCode":null,"failureHint":null,"baseSha":"base_1","headSha":"head_1","targetFingerprint":"fp_1","reviewThreadId":"thr_1","reviewTurnId":"turn_1","recordPath":"/tmp/record.json","eventLogPath":"/tmp/event.jsonl","findings":[]}}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "review.json", raw);
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("review.json", receipt.source_path);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expectEqualStrings("cas-lane", receipt.backend_class);
    try std.testing.expect(receipt.clean);
    try std.testing.expectEqual(@as(usize, 0), receipt.finding_count);
    try std.testing.expectEqualStrings("base_1", receipt.base_sha.?);
    try std.testing.expectEqualStrings("head_1", receipt.head_sha.?);
    try std.testing.expectEqualStrings("fp_1", receipt.target_fingerprint.?);
    try std.testing.expectEqualStrings("thr_1", receipt.review_thread_id.?);
}

test "receipt normalizer accepts compact verdict-only artifact" {
    const raw =
        \\{"status":"findings","backendClass":"cas-lane","clean":false,"findingCount":1,"failureCode":null,"failureHint":null,"baseSha":"base_2","headSha":"head_2","targetFingerprint":"fp_2","reviewThreadId":"thr_2","reviewTurnId":"turn_2","recordPath":"/tmp/record.json","eventLogPath":"/tmp/event.jsonl","findings":[{"title":"Issue","file":"/tmp/a.zig","line":12,"priority":1}]}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "verdict.json", raw);
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("findings", receipt.status);
    try std.testing.expect(!receipt.clean);
    try std.testing.expectEqual(@as(usize, 1), receipt.finding_count);
    try std.testing.expect(std.mem.indexOf(u8, receipt.findings_json, "Issue") != null);
}

test "receipt normalizer fails closed on missing verdict fields" {
    try std.testing.expectError(
        error.MissingBackendClass,
        normalizeReceiptFromJsonAlloc(std.testing.allocator, "bad.json", "{\"status\":\"clean\",\"clean\":true,\"findingCount\":0}"),
    );
    try std.testing.expectError(
        error.MissingCleanFlag,
        normalizeReceiptFromJsonAlloc(std.testing.allocator, "bad.json", "{\"status\":\"clean\",\"backendClass\":\"cas-lane\",\"findingCount\":0}"),
    );
}

test "review verdict compacts lane findings for consumers" {
    const review_result =
        \\{"findings":[{"title":"Count matching offers","body":"Body omitted in compact verdict.","confidenceScore":0.86,"priority":2,"codeLocation":{"absoluteFilePath":"/tmp/src/program/evidence.zig","lineRange":{"start":3571,"end":3571}}}],"overallCorrectness":"patch is incorrect","overallExplanation":"One issue.","overallConfidenceScore":0.86}
    ;
    const identity = TargetIdentity{
        .head_sha = "head123",
        .base_sha = "base123",
        .fingerprint = "target-fingerprint",
    };
    const verdict = try buildReviewVerdictJsonAlloc(
        std.testing.allocator,
        "cas-lane",
        false,
        1,
        null,
        identity,
        "review-thread",
        "review-turn",
        "/tmp/record.json",
        "/tmp/events.ndjson",
        review_result,
    );
    defer std.testing.allocator.free(verdict);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, verdict, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("findings", root.get("status").?.string);
    try std.testing.expectEqualStrings("cas-lane", root.get("backendClass").?.string);
    try std.testing.expect(!root.get("clean").?.bool);
    try std.testing.expectEqual(@as(i64, 1), root.get("findingCount").?.integer);
    const finding = root.get("findings").?.array.items[0].object;
    try std.testing.expectEqualStrings("Count matching offers", finding.get("title").?.string);
    try std.testing.expectEqualStrings("/tmp/src/program/evidence.zig", finding.get("file").?.string);
    try std.testing.expectEqual(@as(i64, 3571), finding.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 2), finding.get("priority").?.integer);
}

test "dualParseVerdict fails closed on structured/raw mismatch" {
    const structured =
        \\{"findings":[{"title":"Issue","body":"Fix it.","confidenceScore":0.8,"priority":1,"codeLocation":{"absoluteFilePath":"/tmp/a.zig","lineRange":{"start":1,"end":1}}}],"overallCorrectness":"patch is incorrect","overallExplanation":"Issue found.","overallConfidenceScore":0.8}
    ;
    const status = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "loaded"),
        .turn_status = try std.testing.allocator.dupe(u8, "completed"),
        .turn_count = 1,
        .materialized = true,
        .thread_preview = try std.testing.allocator.dupe(u8, ""),
        .rollout_path = null,
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = true,
        .last_turn_has_exited_review_mode = true,
        .review_result_available = true,
        .review_result_source = "test",
        .review_result_json = try std.testing.allocator.dupe(u8, structured),
        .review_text = try std.testing.allocator.dupe(u8, "Review text with one finding rendered separately."),
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);

    const verdict = try dualParseVerdictAlloc(std.testing.allocator, status);
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("mismatch", verdict.verdict);
    try std.testing.expectEqual(@as(usize, 1), verdict.structured_findings);
    try std.testing.expectEqual(@as(usize, 0), verdict.raw_findings.?);
}

test "notification-only review results are not trusted clean receipts" {
    const source = "notification_exited_review_mode";
    const trusted = std.mem.eql(u8, source, "rollout_exited_review_mode");
    try std.testing.expect(!trusted);
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
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "rollout.jsonl", .data = rollout });

    const rollout_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "rollout.jsonl", std.testing.allocator);
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
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "rollout.jsonl", .data = rollout });

    const rollout_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "rollout.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(rollout_path);

    try std.testing.expect((try readReviewResultJsonFromRolloutAlloc(std.testing.allocator, rollout_path)) == null);
}

test "failureInfoForReviewStart maps detached parent rollout error" {
    const failure = failureInfoForReviewStart("no rollout found for thread id thr_123", true).?;
    try std.testing.expectEqualStrings("incompatible_codex_review_runtime", failure.code);
}

test "buildReviewResultJsonFromRenderedTextAlloc preserves review text" {
    const json = try buildReviewResultJsonFromRenderedTextAlloc(std.testing.allocator, "Looks solid overall.");
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    try std.testing.expectEqualStrings("Looks solid overall.", core_json.stringField(root_obj, "overallExplanation").?);
    try std.testing.expectEqual(@as(usize, 0), root_obj.get("findings").?.array.items.len);
}

test "buildReviewResultJsonFromRenderedTextAlloc parses rendered review findings" {
    const review_text =
        "The boundary-closure analysis found one issue.\n\n" ++
        "Review comment:\n" ++
        "- [P2] Defer registering unproven provider programs \xe2\x80\x94 /Users/tk/workspace/tk/boundary/src/program/evidence.zig:3977-3981\n" ++
        "  When this path registers the provider before closure proof, downstream evidence can observe an unproven program.";
    const json = try buildReviewResultJsonFromRenderedTextAlloc(std.testing.allocator, review_text);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    try std.testing.expectEqualStrings("The boundary-closure analysis found one issue.\n\nReview comment:", core_json.stringField(root_obj, "overallExplanation").?);
    const findings = root_obj.get("findings").?.array;
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    const first = findings.items[0].object;
    try std.testing.expectEqualStrings("Defer registering unproven provider programs", core_json.stringField(first, "title").?);
    try std.testing.expectEqual(@as(f32, 0.0), floatField(first, "confidenceScore").?);
    try std.testing.expectEqual(@as(i64, 2), first.get("priority").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, core_json.stringField(first, "body").?, "downstream evidence") != null);
    const code_location = core_json.objectField(first, "codeLocation").?;
    try std.testing.expectEqualStrings("/Users/tk/workspace/tk/boundary/src/program/evidence.zig", core_json.stringField(code_location, "absoluteFilePath").?);
    const line_range = core_json.objectField(code_location, "lineRange").?;
    try std.testing.expectEqual(@as(i64, 3977), line_range.get("start").?.integer);
    try std.testing.expectEqual(@as(i64, 3981), line_range.get("end").?.integer);
}

test "dualParseVerdict matches rendered review finding count" {
    const structured =
        \\{"findings":[{"title":"Defer registering unproven provider programs","body":"When this path registers the provider before closure proof, downstream evidence can observe an unproven program.","confidenceScore":0.0,"priority":2,"codeLocation":{"absoluteFilePath":"/Users/tk/workspace/tk/boundary/src/program/evidence.zig","lineRange":{"start":3977,"end":3981}}}],"overallCorrectness":"","overallExplanation":"The boundary-closure analysis found one issue.","overallConfidenceScore":0.0}
    ;
    const status = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "loaded"),
        .turn_status = try std.testing.allocator.dupe(u8, "completed"),
        .turn_count = 1,
        .materialized = true,
        .thread_preview = try std.testing.allocator.dupe(u8, ""),
        .rollout_path = null,
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = true,
        .last_turn_has_exited_review_mode = true,
        .review_result_available = true,
        .review_result_source = "rollout_exited_review_mode",
        .review_result_json = try std.testing.allocator.dupe(u8, structured),
        .review_text = try std.testing.allocator.dupe(u8, "- [P2] Defer registering unproven provider programs - /Users/tk/workspace/tk/boundary/src/program/evidence.zig:3977-3981\n  When this path registers the provider before closure proof, downstream evidence can observe an unproven program."),
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);

    const verdict = try dualParseVerdictAlloc(std.testing.allocator, status);
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("match", verdict.verdict);
    try std.testing.expectEqual(@as(usize, 1), verdict.structured_findings);
    try std.testing.expectEqual(@as(usize, 1), verdict.raw_findings.?);
}

test "shouldPreMaterializeDetachedReviewParent gates auto mode for codex 0.118" {
    try std.testing.expect(shouldPreMaterializeDetachedReviewParent(.auto, "codex-cli 0.118.0"));
    try std.testing.expect(shouldPreMaterializeDetachedReviewParent(.auto, "0.118.3-dev"));
    try std.testing.expect(!shouldPreMaterializeDetachedReviewParent(.auto, "codex-cli 0.119.0"));
    try std.testing.expect(!shouldPreMaterializeDetachedReviewParent(.fresh, "codex-cli 0.118.0"));
    try std.testing.expect(!shouldPreMaterializeDetachedReviewParent(.reuse, "codex-cli 0.118.0"));
}

test "codexDetachedReviewNeedsLiveConnection matches 0.118 only" {
    try std.testing.expect(codexDetachedReviewNeedsLiveConnection("codex-cli 0.118.0"));
    try std.testing.expect(!codexDetachedReviewNeedsLiveConnection("codex-cli 0.119.0"));
}

test "parseSemverTriplet extracts version from codex banner text" {
    const parsed = parseSemverTriplet("codex-cli 0.118.0").?;
    try std.testing.expectEqual(@as(u32, 0), parsed.major);
    try std.testing.expectEqual(@as(u32, 118), parsed.minor);
    try std.testing.expectEqual(@as(u32, 0), parsed.patch);
    try std.testing.expect(parseSemverTriplet("codex-cli dev-build") == null);
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

test "failureInfoForStatus prefers interrupted over bootstrap-thread heuristic" {
    var status = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "idle"),
        .turn_status = try std.testing.allocator.dupe(u8, "interrupted"),
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
    try std.testing.expectEqualStrings("review_interrupted", failure.code);
}
