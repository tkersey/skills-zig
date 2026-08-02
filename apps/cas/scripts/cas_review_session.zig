const app_meta = @import("app_meta");
const cas = @import("cas_proxy_client.zig");
const cas_websocket = @import("cas_websocket_transport.zig");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const core_json = @import("core_json");
const core_path = @import("core_path");
const durable_store = @import("durable_store");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas_review_session",
    .help_text = UsageText,
};

const default_control_timeout_ms: u32 = 300_000;
const default_review_timeout_ms: u32 = 2_700_000;

const UsageText =
    \\cas review
    \\
    \\Control detached Codex review sessions via the app-server.
    \\
    \\Usage:
    \\  cas review <run|start|wait> [options]
    \\
    \\Actions:
    \\  run        Broker one tuple-bound review verdict; waits and hides lock recovery.
    \\  start      Start a review session; workflow-bound starts require --wait.
    \\  wait       Poll the persisted session until the review turn reaches a terminal status.
    \\
    \\Run/start options:
    \\  --cwd DIR                        Workspace for the app-server.
    \\  --parent-thread-id THREAD_ID     Optional parent thread id to reuse.
    \\  --parent-mode MODE               Parent strategy: auto|fresh|reuse (default: auto).
    \\  --wait                           Keep the start process alive until the review turn reaches a terminal status;
    \\                                   required when start uses --workflow-binding-json.
    \\  --uncommitted                    Review staged, unstaged, and untracked changes.
    \\  --base BRANCH                    Review changes against a base branch.
    \\  --commit SHA                     Review a specific commit.
    \\  --title TITLE                    Optional commit title for --commit.
    \\  --custom-instructions VALUE      Exact review prompt, raw text, @file, or -; may accompany a target selector.
    \\  --workflow-binding-json VALUE    Optional opaque request binding as JSON or @file.
    \\  --multi-agent-mode MODE          Removed: use Codex reasoning effort and canonical agent config.
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
    \\  --review-lock-override REASON    Explicitly override a stale or exhausted tuple lock.
    \\  --fresh-attempt REASON           Start a new same-tuple review after terminal evidence.
    \\
    \\Wait options:
    \\  --review-thread-id THREAD_ID     Detached review thread id handle.
    \\  --latest                         Use the newest persisted review-session record.
    \\  --path FILE                      Use an explicit persisted session record.
    \\
    \\Common options:
    \\  --json                           Emit machine-readable JSON.
    \\  --codex-thread-id ID             Codex session/thread id for review reuse scoping.
    \\  --store-root DIR                 Explicit CAS artifact root; default is repo .ledger/cas.
    \\  --timeout-ms N                   Wait timeout. Real review waits default to 2700000;
    \\                                   detached starts default to 300000.
    \\  --poll-interval-ms N             Poll interval for `wait` (default: 250).
    \\  --help                           Show help.
    \\  --version                        Show version.
    \\  version                          Show version.
    \\
    \\Examples:
    \\  cas review run --cwd /path/to/repo --base main --custom-instructions @review.txt
    \\      --workflow-binding-json @binding.json --timeout-ms 2700000 --json
    \\  cas review start --cwd /path/to/repo --uncommitted --json
    \\  cas review start --cwd /path/to/repo --base main --json
    \\  cas review start --wait --cwd /path/to/repo --base main --workflow-binding-json @binding.json
    \\      --timeout-ms 2700000 --json
    \\  cas review wait --cwd /path/to/repo --review-thread-id thr_123 --timeout-ms 2700000 --json
    \\  cas review wait --path /path/to/repo/.ledger/cas/review_sessions/thr_123.json --json
    \\  cas review wait --cwd /path/to/repo --latest --json
;

const Action = enum {
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

const TargetKind = enum {
    uncommitted,
    base_branch,
    commit,

    fn asString(self: TargetKind) []const u8 {
        return switch (self) {
            .uncommitted => "uncommittedChanges",
            .base_branch => "baseBranch",
            .commit => "commit",
        };
    }
};

const TargetConfig = struct {
    kind: TargetKind,
    branch: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

const WorkflowBinding = struct {
    requestId: []const u8,
    requestFingerprint: []const u8,
};

const ParsedArgs = struct {
    executable_path: []const u8 = "cas_review_session",
    action: ?Action = null,
    cwd: ?[]const u8 = null,
    parent_thread_id: ?[]const u8 = null,
    parent_mode: ParentMode = .auto,
    multi_agent_mode: ?cas.MultiAgentMode = null,
    review_thread_id: ?[]const u8 = null,
    latest_review_session: bool = false,
    target: ?TargetConfig = null,
    custom_instructions_arg: ?[]const u8 = null,
    custom_instructions: ?[]const u8 = null,
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

    fn deinit(self: ParsedArgs, allocator: std.mem.Allocator) void {
        if (self.custom_instructions) |instructions| allocator.free(instructions);
        allocator.free(self.receipt_paths);
    }
};

const TargetRecord = struct {
    type: []const u8,
    branch: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

const SessionRecord = struct {
    schema_version: u32 = 4,
    cwd: []const u8,
    store_root: ?[]const u8 = null,
    store_scope: ?[]const u8 = null,
    repo_root: ?[]const u8 = null,
    codex_thread_id: ?[]const u8 = null,
    parent_thread_id: []const u8,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    delivery: []const u8,
    target: TargetRecord,
    developer_instructions: ?[]const u8 = null,
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
    terminal_failure_code: ?[]const u8 = null,
    terminal_failure_hint: ?[]const u8 = null,
    terminal_failure_at_unix_s: ?i64 = null,
    hook_policy: ?[]const u8 = null,
    hook_log_path: ?[]const u8 = null,
    requested_multi_agent_mode: ?[]const u8 = null,
    effective_multi_agent_mode: ?[]const u8 = null,
    multi_agent_mode_support: ?[]const u8 = null,
    multi_agent_mode_metric_eligible: bool = false,
    base_sha: ?[]const u8 = null,
    head_sha: ?[]const u8 = null,
    target_fingerprint: ?[]const u8 = null,
    accountFingerprint: ?[]const u8 = null,
    accountFingerprintReducedProtection: bool = true,
    workflowBinding: ?WorkflowBinding = null,
};

const review_tuple_lock_version = "CAS-RTL-v2";
const legacy_review_tuple_lock_version = "CAS-RTL-v1";
const review_owner_lease_version = "CAS-ROL-v1";
const review_tuple_lock_ttl_seconds: i64 = 30 * 60;
const review_tuple_lock_rewrite_lease_wait_ms: u32 = 500;
const unknown_account_fingerprint = "unknown-account";
const principal_strength_strong = "strong";
const principal_strength_reduced = "reduced";
const cas_review_evidence_schema = "CAS-RER-v1";
var configured_store_root_override: ?[]const u8 = null;
var configured_store_cwd: ?[]const u8 = null;
var configured_codex_thread_id: ?[]const u8 = null;

const ReviewTupleIdentity = struct {
    repo_realpath: []const u8,
    base_sha: ?[]const u8,
    head_sha: ?[]const u8,
    target_fingerprint: []const u8,
    resolved_codex_path: []const u8,
    resolved_codex_version: []const u8,
    account_fingerprint: []const u8,
    account_fingerprint_reduced_protection: bool,
    codex_thread_id: []const u8,
    workflow_binding: ?WorkflowBinding = null,
    workflow_binding_digest: ?[]const u8 = null,

    fn deinit(self: ReviewTupleIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_realpath);
        allocator.free(self.account_fingerprint);
        allocator.free(self.codex_thread_id);
        if (self.workflow_binding_digest) |value| allocator.free(value);
    }
};

const AccountPrincipalEvidence = struct {
    fingerprint: []const u8,
    reduced_protection: bool,

    fn deinit(self: AccountPrincipalEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprint);
    }
};

const ReviewTupleLock = struct {
    lockVersion: []const u8 = review_tuple_lock_version,
    tupleHash: []const u8,
    repoRealpath: []const u8,
    baseSha: ?[]const u8,
    headSha: ?[]const u8,
    targetFingerprint: []const u8,
    resolvedCodexPath: []const u8,
    resolvedCodexVersion: []const u8,
    accountFingerprint: []const u8,
    accountFingerprintReducedProtection: bool,
    codexThreadId: ?[]const u8 = null,
    workflowBinding: ?WorkflowBinding = null,
    ownerLeaseVersion: ?[]const u8 = null,
    managedServerPid: ?u64 = null,
    managedServerShutdownReceiptPath: ?[]const u8 = null,
    managedServerShutdownReceiptToken: ?[]const u8 = null,
    reviewStartSendStarted: bool = false,
    state: []const u8,
    reviewThreadId: ?[]const u8 = null,
    reviewTurnId: ?[]const u8 = null,
    recordPath: ?[]const u8 = null,
    eventLogPath: ?[]const u8 = null,
    createdAtUnixS: i64,
    updatedAtUnixS: i64,
    expiresAtUnixS: i64,
    ownerPid: u64,
    lastFailureCode: ?[]const u8 = null,
    overrideReason: ?[]const u8 = null,
    freshAttemptReason: ?[]const u8 = null,
};

const LoadedReviewTupleLock = struct {
    path: []const u8,
    raw: []u8,
    parsed: std.json.Parsed(ReviewTupleLock),
    record: ReviewTupleLock,

    fn deinit(self: *LoadedReviewTupleLock, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw);
        allocator.free(self.path);
    }
};

const ReviewTupleLockAction = enum {
    create,
    return_existing,
    normalize_existing,
    fresh_after_terminal,
    retry_after_pre_review_failure,
    auto_replace_dead_transport,
    recover_dead_owner,
    takeover_with_override,
    block_active,
    block_dead_owner,
    block_stale,
    block_account_resource,
    block_invalid,

    fn asString(self: ReviewTupleLockAction) []const u8 {
        return switch (self) {
            .create => "create",
            .return_existing => "return_existing",
            .normalize_existing => "normalize_existing",
            .fresh_after_terminal => "fresh_after_terminal",
            .retry_after_pre_review_failure => "retry_after_pre_review_failure",
            .auto_replace_dead_transport => "auto_replace_dead_transport",
            .recover_dead_owner => "recover_dead_owner",
            .takeover_with_override => "takeover_with_override",
            .block_active => "block_active",
            .block_dead_owner => "block_dead_owner",
            .block_stale => "block_stale",
            .block_account_resource => "block_account_resource",
            .block_invalid => "block_invalid",
        };
    }
};

const OutputReceipt = struct {
    surface_action: []const u8 = "start",
    resolved_codex_path: ?[]const u8 = null,
    resolved_codex_version: ?[]const u8 = null,
    compatibility_verdict: []const u8 = "not_checked",
    selected_transport: []const u8 = "stdio",
    selection_reason: []const u8 = "default_stdio",
    managed_server_pid: ?u64 = null,
    managed_server_listen_url: ?[]const u8 = null,
    managed_server_stderr_log_path: ?[]const u8 = null,
    orphan_ttl_seconds: ?u32 = null,
    hook_policy: cas.hooks.HookPolicy = .inherit,
    hook_log_path: ?[]const u8 = null,
    requested_multi_agent_mode: ?cas.MultiAgentMode = null,
    effective_multi_agent_mode: ?cas.MultiAgentMode = null,
    multi_agent_mode_support: cas.MultiAgentModeSupport = .not_requested,
    multi_agent_mode_metric_eligible: bool = false,
    review_broker_decision: ?ReviewBrokerDecision = null,
    account_fingerprint: ?[]const u8 = null,
    account_fingerprint_reduced_protection: bool = true,
    codex_thread_id: ?[]const u8 = null,
    fresh_attempt_required: bool = false,
    workflow_binding: ?WorkflowBinding = null,
    developer_instructions: ?[]const u8 = null,
    error_review_attempt_phase: ?[]const u8 = null,
    error_review_attempt_exists: bool = false,
    error_review_thread_id: ?[]const u8 = null,
    error_review_turn_id: ?[]const u8 = null,
};

const ReviewBrokerDecision = struct {
    version: []const u8 = "CAS-RBD-v1",
    action: []const u8,
    reason: []const u8,
    reviewThreadId: ?[]const u8 = null,
    recordPath: ?[]const u8 = null,
    eventLogPath: ?[]const u8 = null,
};

const FailureInfo = struct {
    code: []const u8,
    hint: []const u8,
};

const account_resource_exhausted_hint = "detached review stopped because the account or runtime resource budget was exhausted before emitting a structured reviewResult";

fn withRecordMultiAgentMode(receipt: OutputReceipt, record: SessionRecord) OutputReceipt {
    var out = receipt;
    out.requested_multi_agent_mode = modeFromStoredConfigValue(record.requested_multi_agent_mode);
    out.effective_multi_agent_mode = modeFromStoredConfigValue(record.effective_multi_agent_mode);
    out.multi_agent_mode_support = supportFromStoredValue(record.multi_agent_mode_support);
    out.multi_agent_mode_metric_eligible = record.multi_agent_mode_metric_eligible;
    out.account_fingerprint = record.accountFingerprint;
    out.account_fingerprint_reduced_protection = record.accountFingerprintReducedProtection;
    out.codex_thread_id = record.codex_thread_id;
    out.workflow_binding = record.workflowBinding;
    out.developer_instructions = record.developer_instructions;
    return out;
}

fn waitOutputReceipt(
    record: SessionRecord,
    current_tuple: ?ReviewTupleIdentity,
    resolved_codex_path: ?[]const u8,
    resolved_codex_version: ?[]const u8,
) OutputReceipt {
    var out = withRecordMultiAgentMode(.{
        .resolved_codex_path = resolved_codex_path,
        .resolved_codex_version = resolved_codex_version,
        .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
        .selected_transport = record.transport_kind.?,
        .selection_reason = record.transport_selection_reason.?,
        .managed_server_pid = record.managed_server_pid,
        .managed_server_listen_url = record.managed_server_listen_url,
        .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
        .orphan_ttl_seconds = record.orphan_ttl_seconds,
    }, record);
    applyObservedReviewContext(
        &out,
        current_tuple,
        resolved_codex_path,
        resolved_codex_version,
    );
    return out;
}

fn applyObservedReviewContext(
    receipt: *OutputReceipt,
    current_tuple: ?ReviewTupleIdentity,
    resolved_codex_path: ?[]const u8,
    resolved_codex_version: ?[]const u8,
) void {
    receipt.resolved_codex_path = resolved_codex_path;
    receipt.resolved_codex_version = resolved_codex_version;
    if (current_tuple) |tuple| {
        receipt.account_fingerprint = tuple.account_fingerprint;
        receipt.account_fingerprint_reduced_protection =
            tuple.account_fingerprint_reduced_protection;
        receipt.codex_thread_id = tuple.codex_thread_id;
    } else {
        receipt.account_fingerprint = null;
        receipt.account_fingerprint_reduced_protection = true;
        receipt.codex_thread_id = null;
    }
}

fn modeFromStoredConfigValue(raw: ?[]const u8) ?cas.MultiAgentMode {
    return if (raw) |value| cas.MultiAgentMode.parse(value) else null;
}

fn supportFromStoredValue(raw: ?[]const u8) cas.MultiAgentModeSupport {
    const value = raw orelse return .not_requested;
    if (std.mem.eql(u8, value, "proven")) return .proven;
    if (std.mem.eql(u8, value, "unproven")) return .unproven;
    if (std.mem.eql(u8, value, "unsupported")) return .unsupported;
    return .not_requested;
}

const SemverTriplet = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

const parent_materialization_prompt =
    "Internal bootstrap for detached review parent materialization. Reply with OK only.";
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

const CanonicalTarget = struct {
    value: TargetConfig,
    owned_sha: ?[]const u8 = null,

    fn deinit(self: CanonicalTarget, allocator: std.mem.Allocator) void {
        if (self.owned_sha) |sha| allocator.free(sha);
    }
};

fn identityHasCompleteTuple(identity: TargetIdentity) bool {
    const base_sha = identity.base_sha orelse return false;
    if (base_sha.len == 0) return false;
    const head_sha = identity.head_sha orelse return false;
    if (head_sha.len == 0) return false;
    return identity.fingerprint.len != 0;
}

const ReviewAttemptFields = struct {
    phase: []const u8,
    review_attempt_exists: bool,
    tuple_verdict_exists: bool,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    base_sha: ?[]const u8,
    head_sha: ?[]const u8,
    target_fingerprint: ?[]const u8,
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
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), usageDetailForParseError(err));
    };
    defer parsed.deinit(allocator);
    configured_store_root_override = parsed.store_root orelse init.environ_map.get("CAS_STORE_ROOT");
    configured_store_cwd = parsed.cwd;
    configured_codex_thread_id = parsed.codex_thread_id orelse
        init.environ_map.get("CODEX_THREAD_ID") orelse
        init.environ_map.get("CODEX_SESSION_ID");

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
        .run => try cmdRun(allocator, init.io, parsed),
        .start => try cmdStart(allocator, init.io, parsed),
        .wait => try cmdWait(allocator, init.io, parsed),
    }
}

fn defaultTimeoutMsForAction(parsed: ParsedArgs) u32 {
    const action = parsed.action orelse return default_control_timeout_ms;
    return switch (action) {
        .run, .wait => default_review_timeout_ms,
        .start => if (parsed.wait_after_start) default_review_timeout_ms else default_control_timeout_ms,
    };
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    var out = ParsedArgs{};
    var receipt_paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        receipt_paths.deinit(allocator);
        if (out.custom_instructions) |instructions| allocator.free(instructions);
        if (out.receipt_paths.len != 0) allocator.free(out.receipt_paths);
    }
    if (argv.len > 0) out.executable_path = argv[0];
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
        if (std.mem.eql(u8, arg, "--latest")) {
            out.latest_review_session = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--wait")) {
            out.wait_after_start = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--uncommitted")) {
            try setTarget(&out, .{ .kind = .uncommitted });
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
        if (std.mem.eql(u8, arg, "--multi-agent-mode")) {
            out.multi_agent_mode = cas.MultiAgentMode.parse(value) orelse return error.InvalidMultiAgentMode;
            continue;
        }
        if (std.mem.eql(u8, arg, "--review-thread-id")) {
            try validateReviewThreadIdSelector(value);
            out.review_thread_id = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--base")) {
            try setTarget(&out, .{ .kind = .base_branch, .branch = value });
            continue;
        }
        if (std.mem.eql(u8, arg, "--commit")) {
            try setTarget(&out, .{ .kind = .commit, .sha = value });
            continue;
        }
        if (std.mem.eql(u8, arg, "--title")) {
            if (out.target == null or out.target.?.kind != .commit) return error.TitleRequiresCommit;
            out.target.?.title = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--custom-instructions")) {
            if (out.custom_instructions_arg != null) return error.DuplicateCustomInstructions;
            const instructions = try loadCustomInstructionsAlloc(allocator, value);
            if (!workflowBindingStringValid(instructions)) {
                allocator.free(instructions);
                return error.InvalidCustomInstructions;
            }
            out.custom_instructions_arg = value;
            out.custom_instructions = instructions;
            continue;
        }
        if (std.mem.eql(u8, arg, "--workflow-binding-json")) {
            if (out.workflow_binding_arg != null) return error.DuplicateWorkflowBinding;
            if (value.len == 0 or std.mem.eql(u8, value, "-")) return error.InvalidWorkflowBinding;
            out.workflow_binding_arg = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout-ms")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidTimeout;
            out.timeout_ms = @intCast(parsed);
            out.timeout_ms_explicit = true;
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
            out.hook_policy = cas.hooks.HookPolicy.parse(value) orelse
                return error.InvalidHooksPolicy;
            continue;
        }
        if (std.mem.eql(u8, arg, "--review-lock-override")) {
            if (value.len == 0) return error.InvalidReviewLockOverrideReason;
            out.review_lock_override_reason = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--fresh-attempt")) {
            if (value.len == 0) return error.InvalidFreshAttemptReason;
            out.fresh_attempt_reason = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--store-root")) {
            if (value.len == 0) return error.InvalidStoreRoot;
            out.store_root = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--codex-thread-id")) {
            if (value.len == 0) return error.InvalidCodexThreadId;
            out.codex_thread_id = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--path")) {
            try receipt_paths.append(allocator, value);
            continue;
        }
        return error.UnknownArg;
    }

    out.receipt_paths = try receipt_paths.toOwnedSlice(allocator);

    // Action-local help and version are introspection surfaces, not operations.
    // They must remain reachable without satisfying operation operands.
    if (out.show_help or out.show_version) return out;

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
        .run, .start => {
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
        },
        .wait => {
            if (out.target != null) return error.TargetUnsupportedAction;
            if (out.custom_instructions != null) return error.CustomInstructionsUnsupportedAction;
            if (out.wait_after_start) return error.WaitFlagUnsupportedAction;
            if (out.review_thread_id != null and out.latest_review_session) {
                return error.AmbiguousReviewSessionSelector;
            }
            if (out.receipt_paths.len > 1 or
                (out.receipt_paths.len == 1 and
                    (out.review_thread_id != null or out.latest_review_session)))
            {
                return error.AmbiguousReviewSessionSelector;
            }
            if (out.review_thread_id == null and
                !out.latest_review_session and
                out.receipt_paths.len == 0)
            {
                return error.MissingReviewThreadId;
            }
        },
    }

    if (!out.timeout_ms_explicit) out.timeout_ms = defaultTimeoutMsForAction(out);
    return out;
}

const ReviewThreadIdSelectorHint =
    "pass the bare reviewThreadId; use --path for a session record or " ++
    "--latest for the newest persisted session.";
const MultiAgentModeRemovedHint =
    "Codex 0.145 ignores request-scoped multiAgentMode; configure [agents] in " ++
    "config.toml and use the current Codex reasoning-effort controls instead.";

fn usageDetailForParseError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidReviewThreadId => ReviewThreadIdSelectorHint,
        error.MultiAgentModeRemoved => MultiAgentModeRemovedHint,
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

fn setTarget(parsed: *ParsedArgs, target: TargetConfig) !void {
    if (parsed.target != null) return error.MultipleTargetSelectors;
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

fn workflowBindingStringValid(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}

fn validateWorkflowBinding(binding: WorkflowBinding) !void {
    if (!workflowBindingStringValid(binding.requestId) or
        !workflowBindingStringValid(binding.requestFingerprint))
    {
        return error.InvalidWorkflowBinding;
    }
}

fn loadWorkflowBindingAlloc(allocator: std.mem.Allocator, raw_arg: ?[]const u8) !?std.json.Parsed(WorkflowBinding) {
    const arg = raw_arg orelse return null;
    const raw = if (std.mem.startsWith(u8, arg, "@")) blk: {
        if (arg.len == 1) return error.InvalidWorkflowBinding;
        break :blk try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), arg[1..], allocator, .limited(1024 * 1024));
    } else try allocator.dupe(u8, arg);
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(WorkflowBinding, allocator, raw, .{ .allocate = .alloc_always }) catch return error.InvalidWorkflowBinding;
    errdefer parsed.deinit();
    try validateWorkflowBinding(parsed.value);
    return parsed;
}

fn workflowBoundStartAdmissionFailure(
    parsed: ParsedArgs,
    workflow_binding: ?WorkflowBinding,
) ?FailureInfo {
    if (parsed.action != .start or workflow_binding == null) return null;
    if (!parsed.wait_after_start) {
        return .{
            .code = "workflow_bound_review_requires_owner_lived_wait",
            .hint = "workflow-bound review attempts require one owner-lived `cas review start --wait` process through terminal evidence; rerun with --wait --timeout-ms 2700000",
        };
    }
    if (!parsed.json) return .{
        .code = "workflow_bound_review_requires_structured_output",
        .hint = "workflow-bound review attempts require --json so every terminal verdict or owner failure is machine-readable",
    };
    return null;
}

fn cmdRun(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var broker_parsed = parsed;
    broker_parsed.wait_after_start = true;
    broker_parsed.json = true;
    try cmdStart(allocator, io, broker_parsed);
}

fn cmdStart(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    const action_name = if (parsed.action != null and parsed.action.? == .run) "run" else "start";
    var loaded_workflow_binding = try loadWorkflowBindingAlloc(
        allocator,
        parsed.workflow_binding_arg,
    );
    defer if (loaded_workflow_binding) |*binding| binding.deinit();
    const workflow_binding = if (loaded_workflow_binding) |binding| binding.value else null;
    const cwd = repoRealpathAlloc(allocator, parsed.cwd.?) catch |err| {
        if (workflow_binding != null) {
            try renderErrorAndExit(
                parsed.json,
                "start",
                "review/start",
                @errorName(err),
                parsed.cwd.?,
                .{ .workflow_binding = workflow_binding },
                .{
                    .code = "review_target_resolution_failed",
                    .hint = "CAS could not resolve the workflow-bound repository before review/start; no review attempt was created",
                },
            );
        }
        return err;
    };
    defer allocator.free(cwd);
    if (workflowBoundStartAdmissionFailure(parsed, workflow_binding)) |failure| {
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            failure.hint,
            cwd,
            .{ .workflow_binding = workflow_binding },
            failure,
        );
    }
    const resolved_codex_path = cas.resolveExecutableAlloc(allocator, "codex") catch {
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            "codex binary could not be resolved for CAS review",
            cwd,
            .{},
            .{
                .code = "missing_codex_binary",
                .hint = "install or expose a compatible codex binary on PATH " ++
                    "before running cas review",
            },
        );
    };
    defer allocator.free(resolved_codex_path);
    const codex_version = readCodexVersionAlloc(allocator, io, cwd, resolved_codex_path) catch {
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            "codex --version could not be read for CAS review",
            cwd,
            .{
                .resolved_codex_path = resolved_codex_path,
            },
            .{
                .code = "review_failed",
                .hint = "verify the resolved codex binary is executable and " ++
                    "supports app-server mode",
            },
        );
    };
    defer allocator.free(codex_version);
    var output_receipt = OutputReceipt{
        .surface_action = action_name,
        .resolved_codex_path = resolved_codex_path,
        .resolved_codex_version = codex_version,
        .compatibility_verdict = "compatible",
        .selected_transport = "websocket",
        .selection_reason = "detached_review_requires_cross_process_truth",
        .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
        .hook_policy = parsed.hook_policy,
        .fresh_attempt_required = parsed.fresh_attempt_reason != null,
        .workflow_binding = workflow_binding,
        .developer_instructions = parsed.custom_instructions,
    };
    if (codexReviewRequiresFreshParent(codex_version) and parsed.parent_thread_id != null) {
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            "Codex 0.145 structured review attempts require a fresh CAS-owned thread",
            cwd,
            output_receipt,
            .{
                .code = "inline_review_parent_reuse_unsupported",
                .hint = "omit --parent-thread-id and let CAS create one unique isolated thread for this attempt",
            },
        );
    }

    const workflow_deadline_ms: ?i64 = if (workflow_binding != null)
        monotonicMilliseconds() + @as(i64, parsed.timeout_ms)
    else
        null;

    var managed_server = startManagedWebsocketServer(
        allocator,
        cwd,
        resolved_codex_path,
        parsed.hook_policy,
        workflow_binding != null,
        io,
    ) catch |err| {
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
    defer managed_server.deinit(allocator);
    defer if (workflow_binding != null) managed_server.kill();
    const managed_server_pid = managed_server.processId();
    const managed_server_listen_url = managed_server.listen_url;
    output_receipt.managed_server_pid = managed_server_pid;
    output_receipt.managed_server_listen_url = managed_server_listen_url;

    var client = connectReviewClient(
        allocator,
        cwd,
        resolved_codex_path,
        codex_version,
        "websocket",
        managed_server_listen_url,
        io,
        parsed,
        workflow_deadline_ms,
    ) catch |err| {
        managed_server.kill();
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
    const previous_request_deadline = if (workflow_deadline_ms) |deadline_ms|
        client.swapRequestDeadlineMs(deadline_ms)
    else
        null;
    defer if (workflow_deadline_ms != null) {
        _ = client.swapRequestDeadlineMs(previous_request_deadline);
    };

    const session_dir = try sessionDirAlloc(allocator);
    defer allocator.free(session_dir);
    const canonical_target = canonicalTargetAlloc(allocator, io, cwd, parsed.target.?) catch |err| {
        if (workflow_binding != null) {
            managed_server.kill();
            output_receipt.error_review_attempt_phase = "pre_review_start";
            output_receipt.error_review_attempt_exists = false;
            try renderErrorAndExit(
                parsed.json,
                "start",
                "review/start",
                @errorName(err),
                cwd,
                output_receipt,
                .{
                    .code = "review_target_resolution_failed",
                    .hint = "CAS could not canonicalize the workflow-bound review target; no review attempt was created",
                },
            );
        }
        return err;
    };
    defer canonical_target.deinit(allocator);
    const target = canonical_target.value;
    const target_record = targetToRecord(target);
    var identity = computeTargetIdentityAlloc(
        allocator,
        io,
        cwd,
        target,
        parsed.custom_instructions,
    ) catch |err| {
        if (workflow_binding != null) {
            managed_server.kill();
            output_receipt.error_review_attempt_phase = "pre_review_start";
            output_receipt.error_review_attempt_exists = false;
            try renderErrorAndExit(
                parsed.json,
                "start",
                "review/start",
                @errorName(err),
                cwd,
                output_receipt,
                .{
                    .code = "review_target_resolution_failed",
                    .hint = "CAS could not bind the workflow-bound target identity; no review attempt was created",
                },
            );
        }
        return err;
    };
    defer identity.deinit(allocator);
    var review_tuple = reviewTupleIdentityAlloc(
        allocator,
        cwd,
        identity,
        resolved_codex_path,
        codex_version,
        &client,
        workflow_binding,
    ) catch |err| {
        managed_server.kill();
        output_receipt.error_review_attempt_phase = "pre_review_start";
        output_receipt.error_review_attempt_exists = false;
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            @errorName(err),
            cwd,
            output_receipt,
            .{
                .code = "pre_review_start_failed",
                .hint = "CAS could not bind the owner-lived review tuple before review/start; no review attempt was created",
            },
        );
    };
    defer review_tuple.deinit(allocator);
    output_receipt.account_fingerprint = review_tuple.account_fingerprint;
    output_receipt.account_fingerprint_reduced_protection = review_tuple.account_fingerprint_reduced_protection;
    output_receipt.codex_thread_id = review_tuple.codex_thread_id;
    var tuple_lock_bundle = try acquireReviewTupleStartLockOrExit(
        allocator,
        parsed.json,
        action_name,
        target_record,
        identity,
        review_tuple,
        parsed.review_lock_override_reason,
        parsed.fresh_attempt_reason,
        &managed_server,
    );
    defer tuple_lock_bundle.deinit(allocator);
    const created_parent_thread = parsed.parent_thread_id == null;
    const parent_thread_id = if (parsed.parent_thread_id) |existing| blk: {
        const existing_parent_event_log_path = try parentEventLogPathAlloc(allocator, session_dir, existing);
        defer allocator.free(existing_parent_event_log_path);
        resumeParentThread(allocator, &client, existing, existing_parent_event_log_path, codex_version) catch |err| {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_start_failed", null, null, null, existing_parent_event_log_path);
            if (workflow_binding != null) {
                managed_server.kill();
                output_receipt.error_review_attempt_phase = "pre_review_start";
                output_receipt.error_review_attempt_exists = false;
                try renderErrorAndExit(
                    parsed.json,
                    "start",
                    "review/start",
                    @errorName(err),
                    cwd,
                    output_receipt,
                    .{
                        .code = "pre_review_start_failed",
                        .hint = "the owner-lived review could not resume its selected parent before review/start; no review attempt was created",
                    },
                );
            }
            return err;
        };
        var parent_status = fetchReviewStatus(
            allocator,
            &client,
            existing,
            null,
            existing_parent_event_log_path,
            null,
            codex_version,
        ) catch |err| {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_start_failed", null, null, null, existing_parent_event_log_path);
            if (workflow_binding != null) {
                managed_server.kill();
                output_receipt.error_review_attempt_phase = "pre_review_start";
                output_receipt.error_review_attempt_exists = false;
                try renderErrorAndExit(
                    parsed.json,
                    "start",
                    "review/start",
                    @errorName(err),
                    cwd,
                    output_receipt,
                    .{
                        .code = "pre_review_start_failed",
                        .hint = "the owner-lived review could not validate its selected parent before review/start; no review attempt was created",
                    },
                );
            }
            return err;
        };
        defer parent_status.deinit(allocator);
        if (failureInfoForParentReuse(&parent_status)) |failure| {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", failure.code, null, null, null, existing_parent_event_log_path);
            if (workflow_binding != null) managed_server.kill();
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
    } else startParentThreadAlloc(
        allocator,
        &client,
        cwd,
        session_dir,
        parsed.custom_instructions,
    ) catch |err| {
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_start_failed", null, null, null, null);
        if (workflow_binding != null) {
            managed_server.kill();
            output_receipt.error_review_attempt_phase = "pre_review_start";
            output_receipt.error_review_attempt_exists = false;
            try renderErrorAndExit(
                parsed.json,
                "start",
                "review/start",
                @errorName(err),
                cwd,
                output_receipt,
                .{
                    .code = "pre_review_start_failed",
                    .hint = "the owner-lived review failed before review/start; the exact request may start one fresh attempt",
                },
            );
        }
        return err;
    };
    defer allocator.free(parent_thread_id);
    const parent_event_log_path = try parentEventLogPathAlloc(allocator, session_dir, parent_thread_id);
    defer allocator.free(parent_event_log_path);
    const review_params_json = try buildReviewStartParamsJson(
        allocator,
        parent_thread_id,
        target,
        codex_version,
    );
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
            codex_version,
        ) catch {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_start_failed", null, null, null, parent_event_log_path);
            if (workflow_binding != null) managed_server.kill();
            try renderErrorAndExit(
                parsed.json,
                "start",
                "review/start",
                "fresh detached review parent could not be materialized before detached review launch",
                cwd,
                output_receipt,
                .{
                    .code = "pre_review_start_failed",
                    .hint = "auto parent-mode could not bootstrap a materialized " ++
                        "parent thread for this codex runtime; upgrade codex or " ++
                        "pass a clean materialized --parent-thread-id",
                },
            );
        };
        appendLogRecord(allocator, parent_event_log_path, "review/start", "note", "{\"compatibility\":\"pre-materialized-fresh-parent\"}") catch {};
    }
    var review_start_send_boundary = ReviewStartSendBoundary{
        .allocator = allocator,
        .lock_path = tuple_lock_bundle.path,
        .lock = &tuple_lock_bundle.lock,
    };
    const review_start_send_observer: ?cas.RequestSendObserver = if (workflow_binding != null)
        .{
            .context = &review_start_send_boundary,
            .before_send = persistReviewStartSendBoundary,
        }
    else
        null;
    review_result_json = requestReviewStart(
        &client,
        review_params_json,
        review_start_send_observer,
    ) catch |err| blk: {
        const request_send_started = client.lastRequestSendStarted();
        const raw_message = client.lastError() orelse @errorName(err);
        const failure = failureInfoForReviewStart(raw_message, created_parent_thread);
        if (workflow_binding != null and request_send_started and
            failure != null and
            std.mem.eql(u8, failure.?.code, "account_resource_exhausted"))
        {
            output_receipt.error_review_attempt_phase = "review_terminal";
            output_receipt.error_review_attempt_exists = true;
            terminalizeOwnedReviewAttempt(
                allocator,
                &managed_server,
                tuple_lock_bundle.path,
                tuple_lock_bundle.lock,
                .{ .event_log_path = parent_event_log_path },
                failure.?,
            );
            try renderErrorAndExit(
                parsed.json,
                "start",
                "review/start",
                failure.?.hint,
                cwd,
                output_receipt,
                failure.?,
            );
        }
        if (reviewStartFailureOwnsAttempt(workflow_binding != null, request_send_started, err)) {
            output_receipt.error_review_attempt_phase = if (request_send_started) "review_terminal" else "pre_review_start";
            output_receipt.error_review_attempt_exists = request_send_started;
            const timeout_failure = workflowOwnedPostStartFailure(err);
            terminalizeOwnedReviewAttempt(
                allocator,
                &managed_server,
                tuple_lock_bundle.path,
                tuple_lock_bundle.lock,
                .{ .event_log_path = parent_event_log_path },
                timeout_failure,
            );
            try renderErrorAndExit(
                parsed.json,
                "start",
                "review/start",
                timeout_failure.hint,
                cwd,
                output_receipt,
                timeout_failure,
            );
        }
        if (created_parent_thread and failure != null and !pre_materialize_parent) {
            materializeParentThreadTurn(
                allocator,
                &client,
                parent_thread_id,
                parent_event_log_path,
                parsed.timeout_ms,
                parsed.poll_interval_ms,
                codex_version,
            ) catch {
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_start_failed", null, null, null, parent_event_log_path);
                if (workflow_binding != null) managed_server.kill();
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
                        .code = "pre_review_start_failed",
                        .hint = "fresh parent-thread retry could not materialize rollout state; upgrade codex or pass a clean materialized --parent-thread-id",
                    },
                );
            };

            review_start_retry_used = true;
            break :blk requestReviewStart(
                &client,
                review_params_json,
                review_start_send_observer,
            ) catch |retry_err| {
                const retry_send_started = client.lastRequestSendStarted();
                const retry_message = client.lastError() orelse @errorName(retry_err);
                const retry_failure = failureInfoForReviewStart(retry_message, created_parent_thread);
                if (workflow_binding != null and retry_send_started and
                    retry_failure != null and
                    std.mem.eql(u8, retry_failure.?.code, "account_resource_exhausted"))
                {
                    output_receipt.error_review_attempt_phase = "review_terminal";
                    output_receipt.error_review_attempt_exists = true;
                    terminalizeOwnedReviewAttempt(
                        allocator,
                        &managed_server,
                        tuple_lock_bundle.path,
                        tuple_lock_bundle.lock,
                        .{ .event_log_path = parent_event_log_path },
                        retry_failure.?,
                    );
                    try renderErrorAndExit(
                        parsed.json,
                        "start",
                        "review/start",
                        retry_failure.?.hint,
                        cwd,
                        output_receipt,
                        retry_failure.?,
                    );
                }
                if (reviewStartFailureOwnsAttempt(workflow_binding != null, retry_send_started, retry_err)) {
                    output_receipt.error_review_attempt_phase = if (retry_send_started) "review_terminal" else "pre_review_start";
                    output_receipt.error_review_attempt_exists = retry_send_started;
                    const timeout_failure = workflowOwnedPostStartFailure(retry_err);
                    terminalizeOwnedReviewAttempt(
                        allocator,
                        &managed_server,
                        tuple_lock_bundle.path,
                        tuple_lock_bundle.lock,
                        .{ .event_log_path = parent_event_log_path },
                        timeout_failure,
                    );
                    try renderErrorAndExit(
                        parsed.json,
                        "start",
                        "review/start",
                        timeout_failure.hint,
                        cwd,
                        output_receipt,
                        timeout_failure,
                    );
                }
                const message = if (retry_failure) |value| value.hint else retry_message;
                const failure_for_lock: FailureInfo = retry_failure orelse .{
                    .code = "pre_review_start_failed",
                    .hint = "detached review startup failed after fresh-parent materialization retry",
                };
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, if (std.mem.eql(u8, failure_for_lock.code, "account_resource_exhausted")) "account_resource_exhausted" else "pre_review_start_failed", failure_for_lock.code, null, null, null, parent_event_log_path);
                if (workflow_binding != null) managed_server.kill();
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
                    failure_for_lock,
                );
            };
        }

        const message = if (failure) |value| value.hint else raw_message;
        const failure_for_lock: FailureInfo = failure orelse .{
            .code = "pre_review_start_failed",
            .hint = "detached review startup failed after app-server launch",
        };
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, if (std.mem.eql(u8, failure_for_lock.code, "account_resource_exhausted")) "account_resource_exhausted" else "pre_review_start_failed", failure_for_lock.code, null, null, null, parent_event_log_path);
        if (workflow_binding != null) managed_server.kill();
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
            failure_for_lock,
        );
    };
    defer allocator.free(review_result_json);

    const review_thread_id = extractReviewThreadIdAlloc(allocator, review_result_json) catch |err| {
        output_receipt.error_review_attempt_phase = "review_terminal";
        output_receipt.error_review_attempt_exists = true;
        const failure = workflowOwnedPostStartFailure(err);
        terminalizeOwnedReviewAttempt(
            allocator,
            &managed_server,
            tuple_lock_bundle.path,
            tuple_lock_bundle.lock,
            .{ .event_log_path = parent_event_log_path },
            failure,
        );
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            failure.hint,
            cwd,
            output_receipt,
            failure,
        );
    };
    defer allocator.free(review_thread_id);
    const review_turn_id = extractReviewTurnIdAlloc(allocator, review_result_json) catch |err| {
        output_receipt.error_review_attempt_phase = "review_terminal";
        output_receipt.error_review_attempt_exists = true;
        output_receipt.error_review_thread_id = review_thread_id;
        const failure = workflowOwnedPostStartFailure(err);
        terminalizeOwnedReviewAttempt(
            allocator,
            &managed_server,
            tuple_lock_bundle.path,
            tuple_lock_bundle.lock,
            .{
                .review_thread_id = review_thread_id,
                .event_log_path = parent_event_log_path,
            },
            failure,
        );
        try renderErrorAndExit(
            parsed.json,
            "start",
            "review/start",
            failure.hint,
            cwd,
            output_receipt,
            failure,
        );
    };
    defer allocator.free(review_turn_id);
    const event_log_path = try std.fmt.allocPrint(allocator, "{s}/{s}.events.ndjson", .{ session_dir, review_thread_id });
    defer allocator.free(event_log_path);
    const record_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, review_thread_id });
    defer allocator.free(record_path);

    appendLogRecord(allocator, event_log_path, "review/start", "request", review_params_json) catch {};
    appendLogRecord(allocator, event_log_path, "review/start", "response", review_result_json) catch {};
    if (review_start_retry_used) {
        appendLogRecord(allocator, event_log_path, "review/start", "note", "{\"retry\":\"fresh-parent-materialization\"}") catch {};
    }
    const store_root = try casStoreRootAlloc(allocator);
    defer allocator.free(store_root);
    const repo_root = try repoRootForCwdAlloc(allocator, cwd);
    defer if (repo_root) |root| allocator.free(root);

    var record = SessionRecord{
        .cwd = cwd,
        .store_root = store_root,
        .store_scope = "repo-local",
        .repo_root = repo_root,
        .codex_thread_id = review_tuple.codex_thread_id,
        .parent_thread_id = parent_thread_id,
        .review_thread_id = review_thread_id,
        .review_turn_id = review_turn_id,
        .delivery = "detached",
        .target = target_record,
        .developer_instructions = parsed.custom_instructions,
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
        .requested_multi_agent_mode = if (output_receipt.requested_multi_agent_mode) |mode| mode.configValue() else null,
        .effective_multi_agent_mode = if (output_receipt.effective_multi_agent_mode) |mode| mode.configValue() else null,
        .multi_agent_mode_support = output_receipt.multi_agent_mode_support.asString(),
        .multi_agent_mode_metric_eligible = output_receipt.multi_agent_mode_metric_eligible,
        .base_sha = identity.base_sha,
        .head_sha = identity.head_sha,
        .target_fingerprint = identity.fingerprint,
        .accountFingerprint = review_tuple.account_fingerprint,
        .accountFingerprintReducedProtection = review_tuple.account_fingerprint_reduced_protection,
        .workflowBinding = workflow_binding,
    };
    if (std.mem.eql(u8, action_name, "run")) {
        const auto_replaced = std.mem.eql(u8, tuple_lock_bundle.lock.overrideReason orelse "", "auto-replaced-dead-transport");
        output_receipt.review_broker_decision = .{
            .action = if (auto_replaced) "auto_replaced_dead_transport" else "created_new",
            .reason = if (auto_replaced)
                "existing same-tuple review transport was marked lost and both recorded owner and managed server were dead"
            else
                "no reusable terminal receipt or provably live active attempt satisfied the requested tuple before starting a new review",
            .reviewThreadId = review_thread_id,
            .recordPath = record_path,
            .eventLogPath = event_log_path,
        };
    }
    writeSessionRecord(allocator, record_path, record) catch |err| {
        if (workflow_binding != null) {
            const failure = workflowOwnedPostStartFailure(err);
            terminalizeOwnedReviewAttempt(
                allocator,
                &managed_server,
                tuple_lock_bundle.path,
                tuple_lock_bundle.lock,
                .{
                    .record_path = record_path,
                    .record = &record,
                    .review_thread_id = review_thread_id,
                    .review_turn_id = review_turn_id,
                    .event_log_path = event_log_path,
                },
                failure,
            );
            var disconnected_status = try makeDisconnectedReviewStatus(allocator);
            defer disconnected_status.deinit(allocator);
            try printStartJson(
                allocator,
                cwd,
                parent_thread_id,
                review_thread_id,
                review_turn_id,
                target_record,
                identity,
                record_path,
                event_log_path,
                output_receipt,
                disconnected_status,
                false,
                true,
                failure,
            );
            std.process.exit(1);
        }
        return err;
    };
    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "review_started", null, review_thread_id, review_turn_id, record_path, event_log_path);

    if (parsed.wait_after_start) {
        const wait_deadline_ms = workflow_deadline_ms orelse
            (monotonicMilliseconds() + @as(i64, parsed.timeout_ms));
        const previous_wait_deadline = if (workflow_deadline_ms == null)
            client.swapRequestDeadlineMs(wait_deadline_ms)
        else
            null;
        defer if (workflow_deadline_ms == null) {
            _ = client.swapRequestDeadlineMs(previous_wait_deadline);
        };
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", null, review_thread_id, review_turn_id, record_path, event_log_path);
        var terminal_status_from_grace = false;
        const latest = waitForReviewCompletion(
            allocator,
            &client,
            record.review_thread_id,
            record.review_turn_id,
            record.event_log_path,
            parsed.timeout_ms,
            parsed.poll_interval_ms,
            codex_version,
            wait_deadline_ms,
        ) catch |err| switch (err) {
            error.WaitTimedOut => timeout: {
                var timeout_status = fetch_timeout_status: {
                    var grace_client = connectReviewClient(
                        allocator,
                        cwd,
                        resolved_codex_path,
                        codex_version,
                        "websocket",
                        managed_server_listen_url,
                        io,
                        parsed,
                        monotonicMilliseconds() + @as(i64, finalReviewStatusGraceMs(parsed.poll_interval_ms)),
                    ) catch {
                        break :fetch_timeout_status try makeDisconnectedReviewStatus(allocator);
                    };
                    defer {
                        grace_client.close();
                        grace_client.deinit();
                    }
                    break :fetch_timeout_status fetchReviewStatusAfterWaitTimeout(
                        allocator,
                        &grace_client,
                        record.review_thread_id,
                        record.review_turn_id,
                        record.event_log_path,
                        codex_version,
                        parsed.poll_interval_ms,
                    ) catch {
                        break :fetch_timeout_status try makeDisconnectedReviewStatus(allocator);
                    };
                };
                if (reviewGraceStatusCompletesWait(&timeout_status)) {
                    terminal_status_from_grace = true;
                    break :timeout timeout_status;
                }
                defer timeout_status.deinit(allocator);
                if (workflow_binding != null) {
                    const failure = reviewWaitTimeoutDisposition(true).failure;
                    terminalizeOwnedReviewAttempt(
                        allocator,
                        &managed_server,
                        tuple_lock_bundle.path,
                        tuple_lock_bundle.lock,
                        .{
                            .record_path = record_path,
                            .record = &record,
                            .review_thread_id = review_thread_id,
                            .review_turn_id = review_turn_id,
                            .event_log_path = event_log_path,
                        },
                        failure,
                    );
                    try printStartJson(
                        allocator,
                        cwd,
                        parent_thread_id,
                        review_thread_id,
                        review_turn_id,
                        target_record,
                        identity,
                        record_path,
                        event_log_path,
                        output_receipt,
                        timeout_status,
                        true,
                        true,
                        failure,
                    );
                    std.process.exit(1);
                }
                const timeout_disposition = reviewWaitTimeoutDisposition(workflow_binding != null);
                record.last_observed_status = timeoutStatusString(&timeout_status);
                try writeSessionRecord(allocator, record_path, record);
                updateReviewTupleLockBestEffort(
                    allocator,
                    tuple_lock_bundle.path,
                    tuple_lock_bundle.lock,
                    timeout_disposition.lock_state,
                    timeout_disposition.failure.code,
                    review_thread_id,
                    review_turn_id,
                    record_path,
                    event_log_path,
                );
                if (parsed.json) {
                    try printStartJson(
                        allocator,
                        cwd,
                        parent_thread_id,
                        review_thread_id,
                        review_turn_id,
                        target_record,
                        identity,
                        record_path,
                        event_log_path,
                        output_receipt,
                        timeout_status,
                        true,
                        true,
                        timeout_disposition.failure,
                    );
                } else {
                    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                    const stdout = &stdout_writer.interface;
                    try stdout.print(
                        "cas review start timed out after {d}ms\n" ++
                            "review thread: {s}\n",
                        .{
                            parsed.timeout_ms,
                            review_thread_id,
                        },
                    );
                }
                std.process.exit(1);
            },
            else => {
                if (workflow_binding != null or isTransportLossError(err)) {
                    const failure = workflowOwnedPostStartFailure(err);
                    terminalizeOwnedReviewAttempt(
                        allocator,
                        &managed_server,
                        tuple_lock_bundle.path,
                        tuple_lock_bundle.lock,
                        .{
                            .record_path = record_path,
                            .record = &record,
                            .review_thread_id = review_thread_id,
                            .review_turn_id = review_turn_id,
                            .event_log_path = event_log_path,
                        },
                        failure,
                    );
                    var disconnected_status = try makeDisconnectedReviewStatus(allocator);
                    defer disconnected_status.deinit(allocator);
                    if (parsed.json) {
                        try printStartJson(
                            allocator,
                            cwd,
                            parent_thread_id,
                            review_thread_id,
                            review_turn_id,
                            target_record,
                            identity,
                            record_path,
                            event_log_path,
                            output_receipt,
                            disconnected_status,
                            err == error.ConnectionTimedOut,
                            true,
                            failure,
                        );
                    } else {
                        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                        try stderr_writer.interface.print(
                            "cas review start: {s} ({s})\nrecord: {s}\n",
                            .{ failure.hint, failure.code, record_path },
                        );
                    }
                    std.process.exit(1);
                }
                return err;
            },
        };
        defer latest.deinit(allocator);
        record.last_observed_status = latest.turn_status;
        persistTerminalReviewResult(&record, latest);
        if (!latest.review_result_available) {
            if (failureInfoForStatus(&latest)) |failure| {
                if (std.mem.eql(u8, failure.code, "incompatible_codex_review_runtime")) {
                    record.compatibility_verdict = "incompatible";
                    output_receipt.compatibility_verdict = "incompatible";
                }
            }
            writeSessionRecord(allocator, record_path, record) catch |err| {
                if (workflow_binding != null) {
                    managed_server.kill();
                    const persistence_failure = terminalReviewOwnerFailure("review_owner_failed").?;
                    updateReviewTupleLockBestEffort(
                        allocator,
                        tuple_lock_bundle.path,
                        tuple_lock_bundle.lock,
                        "terminal",
                        persistence_failure.code,
                        review_thread_id,
                        review_turn_id,
                        record_path,
                        event_log_path,
                    );
                    output_receipt.error_review_attempt_phase = "review_terminal";
                    output_receipt.error_review_attempt_exists = true;
                    if (parsed.json) {
                        try printStartJson(
                            allocator,
                            cwd,
                            parent_thread_id,
                            review_thread_id,
                            review_turn_id,
                            target_record,
                            identity,
                            record_path,
                            event_log_path,
                            output_receipt,
                            latest,
                            false,
                            true,
                            persistence_failure,
                        );
                    }
                    std.process.exit(1);
                }
                return err;
            };
            if (failureInfoForStatus(&latest)) |failure| {
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, if (std.mem.eql(u8, failure.code, "account_resource_exhausted")) "account_resource_exhausted" else "terminal", failure.code, review_thread_id, review_turn_id, record_path, event_log_path);
            } else {
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "terminal", "review_output_missing", review_thread_id, review_turn_id, record_path, event_log_path);
            }
            if (workflow_binding != null) managed_server.kill();
            if (parsed.json) {
                try printStartJson(
                    allocator,
                    cwd,
                    parent_thread_id,
                    review_thread_id,
                    review_turn_id,
                    target_record,
                    identity,
                    record_path,
                    event_log_path,
                    output_receipt,
                    latest,
                    false,
                    true,
                    failureInfoForStatus(&latest) orelse .{
                        .code = "review_output_missing",
                        .hint = "detached review reached terminal status without a materialized reviewResult",
                    },
                );
            } else {
                var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                const stdout = &stdout_writer.interface;
                try stdout.print(
                    "cas review start reached terminal status without a reviewResult\n" ++
                        "review thread: {s}\n",
                    .{review_thread_id},
                );
            }
            std.process.exit(1);
        }
        writeSessionRecord(allocator, record_path, record) catch |err| {
            if (workflow_binding != null) {
                managed_server.kill();
                const persistence_failure = terminalReviewOwnerFailure("review_owner_failed").?;
                updateReviewTupleLockBestEffort(
                    allocator,
                    tuple_lock_bundle.path,
                    tuple_lock_bundle.lock,
                    "terminal",
                    persistence_failure.code,
                    review_thread_id,
                    review_turn_id,
                    record_path,
                    event_log_path,
                );
                output_receipt.error_review_attempt_phase = "review_terminal";
                output_receipt.error_review_attempt_exists = true;
                if (parsed.json) {
                    try printStartJson(
                        allocator,
                        cwd,
                        parent_thread_id,
                        review_thread_id,
                        review_turn_id,
                        target_record,
                        identity,
                        record_path,
                        event_log_path,
                        output_receipt,
                        latest,
                        false,
                        true,
                        persistence_failure,
                    );
                }
                std.process.exit(1);
            }
            return err;
        };
        var terminal_context_client: ?cas.Client = if (terminal_status_from_grace)
            connectReviewClient(
                allocator,
                cwd,
                resolved_codex_path,
                codex_version,
                "websocket",
                managed_server_listen_url,
                io,
                parsed,
                monotonicMilliseconds() + 1_000,
            ) catch null
        else
            null;
        defer if (terminal_context_client) |*fresh_client| {
            fresh_client.close();
            fresh_client.deinit();
        };
        const terminal_context_client_ptr = if (terminal_context_client) |*fresh_client|
            fresh_client
        else
            &client;
        const terminal_context = captureTerminalReviewContext(
            allocator,
            io,
            cwd,
            target,
            parsed.custom_instructions,
            terminal_context_client_ptr,
            workflow_binding,
        );
        defer terminal_context.deinit(allocator);
        const terminal_binding_failure = try terminalReviewFailureAlloc(
            allocator,
            latest,
            identity,
            terminal_context.identity,
            review_tuple,
            terminal_context.tuple,
        );
        applyObservedReviewContext(
            &output_receipt,
            terminal_context.tuple,
            terminal_context.codex_path,
            terminal_context.codex_version,
        );
        updateReviewTupleLockBestEffort(
            allocator,
            tuple_lock_bundle.path,
            tuple_lock_bundle.lock,
            if (terminal_binding_failure == null) "normalized" else "terminal",
            if (terminal_binding_failure) |failure| failure.code else null,
            review_thread_id,
            review_turn_id,
            record_path,
            event_log_path,
        );

        // Terminal renderers may exit (for example `run` with findings), so
        // owner cleanup must happen before control crosses the renderer.
        if (workflow_binding != null) managed_server.kill();
        if (parsed.json) {
            try printStartJson(
                allocator,
                cwd,
                parent_thread_id,
                review_thread_id,
                review_turn_id,
                target_record,
                identity,
                record_path,
                event_log_path,
                output_receipt,
                latest,
                false,
                true,
                terminal_binding_failure,
            );
        } else {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            try stdout.print(
                "cas review start\ncwd: {s}\nparent thread: {s}\n" ++
                    "review thread: {s}\nreview turn: {s}\n" ++
                    "final turn status: {s}\nrecord: {s}\nevent log: {s}\n",
                .{
                    cwd,
                    parent_thread_id,
                    review_thread_id,
                    review_turn_id,
                    latest.turn_status,
                    record_path,
                    event_log_path,
                },
            );
        }
        if (terminal_binding_failure != null) {
            std.process.exit(1);
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
            identity,
            record_path,
            event_log_path,
            output_receipt,
            null,
            false,
            false,
            null,
        );
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print(
            "cas review start\ncwd: {s}\nparent thread: {s}\n" ++
                "review thread: {s}\nreview turn: {s}\n" ++
                "record: {s}\nevent log: {s}\n",
            .{
                cwd,
                parent_thread_id,
                review_thread_id,
                review_turn_id,
                record_path,
                event_log_path,
            },
        );
    }
}

fn cmdWait(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var loaded = try loadSelectedSessionRecord(allocator, parsed);
    defer loaded.deinit(allocator);
    var record = loaded.record;
    const selected_target = try targetConfigFromRecord(record.target);
    const stored_identity = try targetIdentityForRecordAlloc(allocator, record);
    defer stored_identity.deinit(allocator);
    const stored_identity_opt: ?TargetIdentity = stored_identity;
    const wait_deadline_ms = monotonicMilliseconds() + @as(i64, parsed.timeout_ms);

    if (try recordHasTerminalFailureReplayCandidate(
        allocator,
        record,
        loaded.record_path,
    )) {
        try replayTerminalRecordAndExit(
            allocator,
            parsed.json,
            record,
            loaded.record_path,
            stored_identity,
        );
    }

    const current_codex_path = try cas.resolveExecutableAlloc(allocator, "codex");
    defer allocator.free(current_codex_path);
    const current_codex_version = try readCodexVersionAlloc(
        allocator,
        io,
        record.cwd,
        current_codex_path,
    );
    defer allocator.free(current_codex_version);
    var current_identity = try computeTargetIdentityAlloc(
        allocator,
        io,
        record.cwd,
        selected_target,
        record.developer_instructions,
    );
    defer current_identity.deinit(allocator);
    const current_identity_opt: ?TargetIdentity = current_identity;

    if (try recordIsNormalizedVerdictReplayCandidate(
        allocator,
        record,
        loaded.record_path,
    )) {
        const replay_currentness_failure: ?FailureInfo = validation: {
            var validation_server = try startManagedWebsocketServer(
                allocator,
                record.cwd,
                current_codex_path,
                parsed.hook_policy,
                true,
                io,
            );
            defer validation_server.deinit(allocator);
            defer validation_server.kill();
            var validation_client = try connectReviewClient(
                allocator,
                record.cwd,
                current_codex_path,
                current_codex_version,
                "websocket",
                validation_server.listen_url,
                io,
                parsed,
                wait_deadline_ms,
            );
            defer {
                validation_client.close();
                validation_client.deinit();
            }
            var stored_tuple_for_replay = try storedReviewTupleIdentityAlloc(
                allocator,
                record,
            );
            defer stored_tuple_for_replay.deinit(allocator);
            var current_tuple_for_replay = try reviewTupleIdentityAlloc(
                allocator,
                record.cwd,
                current_identity,
                current_codex_path,
                current_codex_version,
                &validation_client,
                record.workflowBinding,
            );
            defer current_tuple_for_replay.deinit(allocator);
            break :validation try reviewTupleCurrentnessFailureAlloc(
                allocator,
                stored_tuple_for_replay,
                current_tuple_for_replay,
            );
        };
        if (replay_currentness_failure) |failure| {
            if (parsed.json) {
                try printRecordedReviewFailureJson(
                    allocator,
                    .wait,
                    record,
                    loaded.record_path,
                    current_identity,
                    null,
                    failure,
                );
                std.process.exit(1);
            }
            return error.ReviewTupleMismatch;
        }
        try replayTerminalRecordAndExit(
            allocator,
            parsed.json,
            record,
            loaded.record_path,
            current_identity,
        );
    }
    var recovery_owner_lease: ?ReviewOwnerLease = null;
    defer if (recovery_owner_lease) |*lease| lease.deinit(allocator);
    switch (try workflowBoundRecordOwnerState(
        allocator,
        record,
        loaded.record_path,
        &recovery_owner_lease,
    )) {
        .live => {
            const failure = workflowOwnerActiveFailureInfo();
            if (parsed.json) {
                try printRecordedReviewFailureJson(
                    allocator,
                    .wait,
                    record,
                    loaded.record_path,
                    stored_identity,
                    null,
                    failure,
                );
                std.process.exit(1);
            }
            return error.WorkflowBoundReviewOwnerActive;
        },
        .dead => {
            const failure = terminalReviewTransportFailure("review_transport_lost").?;
            try terminalizeDeadWorkflowBoundOwner(
                allocator,
                loaded.record_path,
                &record,
                failure,
            );
            if (parsed.json) {
                try printRecordedReviewFailureJson(
                    allocator,
                    .wait,
                    record,
                    loaded.record_path,
                    stored_identity,
                    null,
                    failure,
                );
                std.process.exit(1);
            }
            return error.ReviewTransportTerminal;
        },
        .not_applicable => {},
    }
    // The owner may have committed a normalized verdict or terminal failure
    // between the first replay probe and the lease-state observation. Replay
    // that newer exact state before any historical reconnect is attempted.
    try replayTerminalRecordAndExit(
        allocator,
        parsed.json,
        record,
        loaded.record_path,
        current_identity,
    );
    var stored_tuple = try storedReviewTupleIdentityAlloc(allocator, record);
    defer stored_tuple.deinit(allocator);
    var client = connectReviewClient(
        allocator,
        record.cwd,
        record.resolved_codex_path orelse "codex",
        record.codex_version,
        record.transport_kind,
        record.managed_server_listen_url,
        io,
        parsed,
        wait_deadline_ms,
    ) catch |err| {
        if (err == error.ConnectionTimedOut) {
            try emitHistoricalWaitTimeoutAndExit(
                allocator,
                parsed,
                loaded.record_path,
                &record,
                stored_identity_opt,
                stored_tuple,
                record.resolved_codex_path orelse "codex",
                record.codex_version,
            );
        }
        // A concurrent owner can terminalize while this observer is inside
        // connect/upgrade. The persisted exact state outranks the observer's
        // socket error and must never be overwritten by it.
        try replayTerminalRecordAndExit(
            allocator,
            parsed.json,
            record,
            loaded.record_path,
            current_identity,
        );
        if (isTransportLossError(err)) {
            var exact_lock = try loadExactReviewTupleLockForRecord(
                allocator,
                record,
                loaded.record_path,
            );
            defer exact_lock.deinit(allocator);
            if (!reviewTupleLockDeadTransportProven(allocator, exact_lock.record)) {
                try emitHistoricalWaitTimeoutAndExit(
                    allocator,
                    parsed,
                    loaded.record_path,
                    &record,
                    stored_identity_opt,
                    stored_tuple,
                    record.resolved_codex_path orelse "codex",
                    record.codex_version,
                );
            }
            if (!try transitionActiveReviewTupleLockForRecord(
                allocator,
                record,
                loaded.record_path,
                "terminal",
                "review_transport_lost",
            )) {
                try replayTerminalRecordAndExit(
                    allocator,
                    parsed.json,
                    record,
                    loaded.record_path,
                    current_identity,
                );
                return error.InvalidReviewTupleLockBinding;
            }
            if (parsed.json) {
                const failure = terminalReviewTransportFailure("review_transport_lost").?;
                try printRecordedReviewFailureJson(
                    allocator,
                    .wait,
                    record,
                    loaded.record_path,
                    stored_identity_opt,
                    null,
                    failure,
                );
                std.process.exit(1);
            }
        }
        return err;
    };
    defer {
        client.close();
        client.deinit();
    }
    const previous_wait_deadline = client.swapRequestDeadlineMs(wait_deadline_ms);
    defer _ = client.swapRequestDeadlineMs(previous_wait_deadline);
    var current_tuple = try reviewTupleIdentityAlloc(
        allocator,
        record.cwd,
        current_identity,
        current_codex_path,
        current_codex_version,
        &client,
        record.workflowBinding,
    );
    defer current_tuple.deinit(allocator);
    const attempt_codex_version = reviewAttemptRuntimeVersion(
        record.codex_version,
        current_codex_version,
    );

    var terminal_status_from_grace = false;
    const latest = waitForReviewCompletion(
        allocator,
        &client,
        record.review_thread_id,
        record.review_turn_id,
        record.event_log_path,
        parsed.timeout_ms,
        parsed.poll_interval_ms,
        attempt_codex_version,
        wait_deadline_ms,
    ) catch |err| switch (err) {
        error.WaitTimedOut => timeout: {
            var timeout_status = grace: {
                var grace_client = connectReviewClient(
                    allocator,
                    record.cwd,
                    record.resolved_codex_path orelse "codex",
                    record.codex_version,
                    record.transport_kind,
                    record.managed_server_listen_url,
                    io,
                    parsed,
                    monotonicMilliseconds() + @as(i64, finalReviewStatusGraceMs(parsed.poll_interval_ms)),
                ) catch break :grace try makeDisconnectedReviewStatus(allocator);
                defer {
                    grace_client.close();
                    grace_client.deinit();
                }
                break :grace fetchReviewStatusAfterWaitTimeout(
                    allocator,
                    &grace_client,
                    record.review_thread_id,
                    record.review_turn_id,
                    record.event_log_path,
                    attempt_codex_version,
                    parsed.poll_interval_ms,
                ) catch try makeDisconnectedReviewStatus(allocator);
            };
            try applyRecordedStatusOverlay(allocator, record, &timeout_status);
            // A semantic result observed inside the bounded final grace window
            // is terminal evidence, not a timeout diagnostic. Feed it through
            // the ordinary persistence and normalization path below.
            if (reviewGraceStatusCompletesWait(&timeout_status)) {
                terminal_status_from_grace = true;
                break :timeout timeout_status;
            }
            record.last_observed_status = timeoutStatusString(&timeout_status);
            try transitionReviewTupleLockForRecordOrReplay(
                allocator,
                parsed.json,
                record,
                loaded.record_path,
                "waiting",
                "wait_timed_out",
                current_identity,
            );
            if (parsed.json) {
                try printStatusJson(
                    allocator,
                    .wait,
                    record.cwd,
                    record.parent_thread_id,
                    record.review_thread_id,
                    record.review_turn_id,
                    timeout_status,
                    loaded.record_path,
                    record.event_log_path,
                    record.target,
                    stored_identity_opt,
                    waitOutputReceipt(
                        record,
                        current_tuple,
                        current_codex_path,
                        current_codex_version,
                    ),
                    parsed.timeout_ms,
                    true,
                    .{
                        .code = "wait_timed_out",
                        .hint = "retry cas review wait on the same review thread " ++
                            "or increase --timeout-ms",
                    },
                );
            } else {
                var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                const stdout = &stdout_writer.interface;
                try stdout.print("cas review wait timed out after {d}ms\nreview thread: {s}\n", .{
                    parsed.timeout_ms,
                    record.review_thread_id,
                });
            }
            std.process.exit(1);
        },
        else => {
            if (isTransportLossError(err)) {
                try transitionReviewTupleLockForRecordOrReplay(
                    allocator,
                    parsed.json,
                    record,
                    loaded.record_path,
                    "terminal",
                    "review_transport_lost",
                    current_identity,
                );
                if (parsed.json) {
                    const failure = terminalReviewTransportFailure("review_transport_lost").?;
                    try printRecordedReviewFailureJson(
                        allocator,
                        .wait,
                        record,
                        loaded.record_path,
                        stored_identity_opt,
                        null,
                        failure,
                    );
                    std.process.exit(1);
                }
            }
            return err;
        },
    };
    defer latest.deinit(allocator);

    record.last_observed_status = latest.turn_status;
    persistTerminalReviewResult(&record, latest);
    if (!latest.review_result_available) {
        const failure_for_lock: FailureInfo = failureInfoForStatus(&latest) orelse .{
            .code = "review_output_missing",
            .hint = "detached review reached terminal status without a materialized reviewResult",
        };
        if (failureInfoForStatus(&latest)) |failure| {
            if (std.mem.eql(u8, failure.code, "incompatible_codex_review_runtime")) {
                record.compatibility_verdict = "incompatible";
            }
        }
        try writeSessionRecord(allocator, loaded.record_path, record);
        try transitionReviewTupleLockForRecordOrReplay(
            allocator,
            parsed.json,
            record,
            loaded.record_path,
            if (std.mem.eql(u8, failure_for_lock.code, "account_resource_exhausted")) "account_resource_exhausted" else "terminal",
            failure_for_lock.code,
            current_identity,
        );
        if (parsed.json) {
            try printStatusJson(
                allocator,
                .wait,
                record.cwd,
                record.parent_thread_id,
                record.review_thread_id,
                record.review_turn_id,
                latest,
                loaded.record_path,
                record.event_log_path,
                record.target,
                current_identity_opt,
                waitOutputReceipt(
                    record,
                    current_tuple,
                    current_codex_path,
                    current_codex_version,
                ),
                null,
                false,
                failure_for_lock,
            );
        } else {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            try stdout.print(
                "cas review wait reached terminal status without a reviewResult\n" ++
                    "review thread: {s}\n",
                .{record.review_thread_id},
            );
        }
        std.process.exit(1);
    }
    try writeSessionRecord(allocator, loaded.record_path, record);
    var terminal_context_client: ?cas.Client = if (terminal_status_from_grace)
        connectReviewClient(
            allocator,
            record.cwd,
            record.resolved_codex_path orelse "codex",
            record.codex_version,
            record.transport_kind,
            record.managed_server_listen_url,
            io,
            parsed,
            monotonicMilliseconds() + 1_000,
        ) catch null
    else
        null;
    defer if (terminal_context_client) |*fresh_client| {
        fresh_client.close();
        fresh_client.deinit();
    };
    const terminal_context_client_ptr = if (terminal_context_client) |*fresh_client|
        fresh_client
    else
        &client;
    const terminal_context = captureTerminalReviewContext(
        allocator,
        io,
        record.cwd,
        selected_target,
        record.developer_instructions,
        terminal_context_client_ptr,
        record.workflowBinding,
    );
    defer terminal_context.deinit(allocator);
    const terminal_lock_failure = try terminalReviewFailureAlloc(
        allocator,
        latest,
        current_identity,
        terminal_context.identity,
        stored_tuple,
        terminal_context.tuple,
    );
    try transitionReviewTupleLockForRecordOrReplay(
        allocator,
        parsed.json,
        record,
        loaded.record_path,
        if (terminal_lock_failure == null) "normalized" else "terminal",
        if (terminal_lock_failure) |failure| failure.code else null,
        current_identity,
    );

    if (parsed.json) {
        try printStatusJson(
            allocator,
            .wait,
            record.cwd,
            record.parent_thread_id,
            record.review_thread_id,
            record.review_turn_id,
            latest,
            loaded.record_path,
            record.event_log_path,
            record.target,
            current_identity_opt,
            waitOutputReceipt(
                record,
                terminal_context.tuple,
                terminal_context.codex_path,
                terminal_context.codex_version,
            ),
            null,
            false,
            terminal_lock_failure,
        );
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print(
            "cas review wait\nreview thread: {s}\nreview turn: {s}\n" ++
                "final turn status: {s}\nrecord: {s}\n",
            .{
                record.review_thread_id,
                record.review_turn_id,
                latest.turn_status,
                loaded.record_path,
            },
        );
    }
    if (terminal_lock_failure != null) std.process.exit(1);
}

const NormalizedReceipt = struct {
    source_path: []const u8,
    status: []const u8,
    backend_class: []const u8,
    clean: bool,
    finding_count: usize,
    review_attempt_phase: []const u8,
    review_attempt_exists: bool,
    tuple_verdict_exists: bool,
    principal_strength: []const u8 = principal_strength_reduced,
    account_fingerprint_reduced_protection: bool = true,
    base_sha: ?[]const u8,
    head_sha: ?[]const u8,
    target_fingerprint: ?[]const u8,
    target_json: ?[]const u8 = null,
    repo_realpath: ?[]const u8 = null,
    resolved_codex_path: ?[]const u8 = null,
    resolved_codex_version: ?[]const u8 = null,
    codex_thread_id: ?[]const u8 = null,
    account_fingerprint: ?[]const u8 = null,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: ?[]const u8,
    event_log_path: ?[]const u8,
    attempt_created_at_unix_s: ?i64 = null,
    failure_code: ?[]const u8,
    failure_hint: ?[]const u8,
    failure_class: ?[]const u8,
    retryable_same_tuple_now: ?bool,
    findings_json: []const u8,
    workflow_binding_json: ?[]const u8 = null,

    fn deinit(self: NormalizedReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.status);
        allocator.free(self.backend_class);
        allocator.free(self.review_attempt_phase);
        if (self.base_sha) |value| allocator.free(value);
        if (self.head_sha) |value| allocator.free(value);
        if (self.target_fingerprint) |value| allocator.free(value);
        if (self.target_json) |value| allocator.free(value);
        if (self.repo_realpath) |value| allocator.free(value);
        if (self.resolved_codex_path) |value| allocator.free(value);
        if (self.resolved_codex_version) |value| allocator.free(value);
        if (self.codex_thread_id) |value| allocator.free(value);
        if (self.account_fingerprint) |value| allocator.free(value);
        if (self.review_thread_id) |value| allocator.free(value);
        if (self.review_turn_id) |value| allocator.free(value);
        if (self.record_path) |value| allocator.free(value);
        if (self.event_log_path) |value| allocator.free(value);
        if (self.failure_code) |value| allocator.free(value);
        if (self.failure_hint) |value| allocator.free(value);
        if (self.failure_class) |value| allocator.free(value);
        allocator.free(self.findings_json);
        if (self.workflow_binding_json) |value| allocator.free(value);
    }
};

const NormalizeContext = struct {
    requested_identity: ?TargetIdentity = null,
    requested_identity_required: bool = false,
};

const GateResult = struct {
    path: []const u8,
    errors: []const []const u8,

    fn ok(self: GateResult) bool {
        return self.errors.len == 0;
    }

    fn deinit(self: GateResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.errors) |err| allocator.free(err);
        allocator.free(self.errors);
    }
};

fn requiredCasRerObjectField(
    allocator: std.mem.Allocator,
    data: std.json.ObjectMap,
    key: []const u8,
    errors: *std.ArrayList([]const u8),
) !?std.json.ObjectMap {
    const child = try objectFieldOrGateError(allocator, data, key, errors);
    if (child == null and data.get(key) == null) {
        try appendGateError(allocator, errors, "missing {s}", .{key});
    } else if (child == null) {
        try appendGateError(allocator, errors, "{s} must be an object", .{key});
    }
    return child;
}

fn casRerStatusAllowed(value: []const u8) bool {
    return std.mem.eql(u8, value, "clean") or
        std.mem.eql(u8, value, "findings") or
        std.mem.eql(u8, value, "incomplete") or
        std.mem.eql(u8, value, "timeout") or
        std.mem.eql(u8, value, "transport_failure") or
        std.mem.eql(u8, value, "account_resource_exhausted") or
        std.mem.eql(u8, value, "review_untrusted_source");
}

fn validateCasRerRecordObjectAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    data: std.json.ObjectMap,
) !GateResult {
    var errors: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (errors.items) |err| allocator.free(err);
        errors.deinit(allocator);
    }

    if (!std.mem.eql(
        u8,
        jsonStringField(data, "schema") orelse "",
        cas_review_evidence_schema,
    )) {
        try appendGateError(
            allocator,
            &errors,
            "schema must be {s}",
            .{cas_review_evidence_schema},
        );
    }
    const record_id = nonEmptyOptional(jsonStringField(data, "recordId"));
    if (record_id == null) {
        try appendGateError(allocator, &errors, "recordId must be non-empty", .{});
    } else {
        if (!std.mem.startsWith(u8, record_id.?, "rer_")) {
            try appendGateError(allocator, &errors, "recordId must start with rer_", .{});
        }
        if (std.mem.indexOfScalar(u8, record_id.?, '/') != null or
            std.mem.indexOfScalar(u8, record_id.?, '\\') != null)
        {
            try appendGateError(
                allocator,
                &errors,
                "recordId must not contain path separators",
                .{},
            );
        }
    }

    const command = try requiredCasRerObjectField(allocator, data, "command", &errors);
    const tuple = try requiredCasRerObjectField(allocator, data, "tuple", &errors);
    const attempt = try requiredCasRerObjectField(allocator, data, "attempt", &errors);
    const verdict = try requiredCasRerObjectField(allocator, data, "verdict", &errors);
    const failure = try requiredCasRerObjectField(allocator, data, "failure", &errors);
    const principal = try requiredCasRerObjectField(allocator, data, "principal", &errors);

    if (command) |command_obj| {
        if (nonEmptyOptional(jsonStringField(command_obj, "surface")) == null) {
            try appendGateError(allocator, &errors, "command.surface must be non-empty", .{});
        }
        if (nonEmptyOptional(jsonStringField(command_obj, "backendSelected")) == null) {
            try appendGateError(
                allocator,
                &errors,
                "command.backendSelected must be non-empty",
                .{},
            );
        }
        if (objectField(command_obj, "brokerDecision")) |broker| {
            if (nonEmptyOptional(jsonStringField(broker, "action")) == null) {
                try appendGateError(
                    allocator,
                    &errors,
                    "command.brokerDecision.action must be non-empty",
                    .{},
                );
            }
            if (nonEmptyOptional(jsonStringField(broker, "reason")) == null) {
                try appendGateError(
                    allocator,
                    &errors,
                    "command.brokerDecision.reason must be non-empty",
                    .{},
                );
            }
            if (jsonBoolField(broker, "freshAttemptRequired") == null) {
                try appendGateError(
                    allocator,
                    &errors,
                    "command.brokerDecision.freshAttemptRequired must be boolean",
                    .{},
                );
            }
        } else {
            try appendGateError(allocator, &errors, "missing command.brokerDecision", .{});
        }
    }

    if (tuple) |tuple_obj| {
        if (tuple_obj.get("target")) |target_value| {
            const canonical_target: ?[]u8 = canonicalTargetRecordJsonFromValueAlloc(
                allocator,
                target_value,
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            if (canonical_target) |target_json| {
                allocator.free(target_json);
            } else {
                try appendGateError(
                    allocator,
                    &errors,
                    "tuple.target must be a complete schema-4 target object",
                    .{},
                );
            }
        } else {
            try appendGateError(allocator, &errors, "missing tuple.target", .{});
        }
    }

    const created_at = jsonStringField(data, "createdAt");
    if (created_at == null or parseCasRerCreatedAtNs(created_at.?) == null) {
        try appendGateError(
            allocator,
            &errors,
            "createdAt must be a parseable CAS-RER timestamp",
            .{},
        );
    }
    const updated_at = jsonStringField(data, "updatedAt");
    if (updated_at == null or parseCasRerCreatedAtNs(updated_at.?) == null) {
        try appendGateError(
            allocator,
            &errors,
            "updatedAt must be a parseable CAS-RER timestamp",
            .{},
        );
    }

    if (data.get("workflowBinding")) |binding_value| {
        switch (binding_value) {
            .object => {
                const canonical = canonicalWorkflowBindingJsonFromValueAlloc(
                    allocator,
                    binding_value,
                ) catch null;
                if (canonical) |value| {
                    allocator.free(value);
                } else {
                    try appendGateError(
                        allocator,
                        &errors,
                        "workflowBinding must be a complete canonical request binding",
                        .{},
                    );
                }
            },
            else => try appendGateError(
                allocator,
                &errors,
                "workflowBinding must be an object when present",
                .{},
            ),
        }
    }

    var attempt_exists_value: ?bool = null;
    if (attempt) |attempt_obj| {
        const attempt_exists = jsonBoolField(attempt_obj, "exists");
        attempt_exists_value = attempt_exists;
        if (attempt_exists == null) {
            try appendGateError(allocator, &errors, "attempt.exists must be boolean", .{});
        }
        const review_thread_id_present = nonEmptyOptional(
            jsonStringField(attempt_obj, "reviewThreadId"),
        ) != null;
        if (attempt_exists) |value| {
            if (value != review_thread_id_present) {
                try appendGateError(
                    allocator,
                    &errors,
                    "attempt.exists must equal attempt.reviewThreadId non-empty",
                    .{},
                );
            }
        }
        if (jsonStringField(attempt_obj, "phase")) |phase| {
            if (!reviewPhaseAllowed(phase)) {
                try appendGateError(
                    allocator,
                    &errors,
                    "invalid attempt.phase: {s}",
                    .{phase},
                );
            }
        } else {
            try appendGateError(allocator, &errors, "missing attempt.phase", .{});
        }
    }

    if (verdict) |verdict_obj| {
        const status = jsonStringField(verdict_obj, "status");
        if (status == null or !casRerStatusAllowed(status.?)) {
            try appendGateError(
                allocator,
                &errors,
                "invalid verdict.status: {s}",
                .{status orelse "null"},
            );
        }
        const clean = jsonBoolField(verdict_obj, "clean");
        if (clean == null) {
            try appendGateError(allocator, &errors, "verdict.clean must be boolean", .{});
        } else if (std.mem.eql(u8, status orelse "", "clean")) {
            if (clean.? != true) {
                try appendGateError(
                    allocator,
                    &errors,
                    "verdict.status=clean requires verdict.clean=true",
                    .{},
                );
            }
        } else if (clean.? != false) {
            try appendGateError(
                allocator,
                &errors,
                "verdict.status!=clean requires verdict.clean=false",
                .{},
            );
        }
        const finding_count = jsonUsizeField(verdict_obj, "findingCount");
        if (finding_count == null) {
            try appendGateError(
                allocator,
                &errors,
                "verdict.findingCount must be a non-negative integer",
                .{},
            );
        }
        const findings_len: ?usize = blk: {
            const findings_value = verdict_obj.get("findings") orelse {
                try appendGateError(allocator, &errors, "verdict.findings must be an array", .{});
                break :blk null;
            };
            switch (findings_value) {
                .array => |array| break :blk array.items.len,
                else => {
                    try appendGateError(
                        allocator,
                        &errors,
                        "verdict.findings must be an array",
                        .{},
                    );
                    break :blk null;
                },
            }
        };
        if (std.mem.eql(u8, status orelse "", "findings") and
            (finding_count orelse 0) == 0)
        {
            try appendGateError(
                allocator,
                &errors,
                "verdict.status=findings requires findingCount > 0",
                .{},
            );
        }
        if (std.mem.eql(u8, status orelse "", "findings") and
            findings_len != null and
            finding_count != null and
            findings_len.? != finding_count.?)
        {
            try appendGateError(
                allocator,
                &errors,
                "findings length must match findingCount",
                .{},
            );
        }
        if (std.mem.eql(u8, status orelse "", "clean")) {
            if ((finding_count orelse 1) != 0) {
                try appendGateError(
                    allocator,
                    &errors,
                    "verdict.status=clean requires findingCount = 0",
                    .{},
                );
            }
            if ((findings_len orelse 1) != 0) {
                try appendGateError(
                    allocator,
                    &errors,
                    "verdict.status=clean requires findings length = 0",
                    .{},
                );
            }
        }
        if (std.mem.eql(u8, status orelse "", "clean") or
            std.mem.eql(u8, status orelse "", "findings"))
        {
            if (failure) |failure_obj| {
                if (fieldPresentNonNull(failure_obj, "failureCode")) {
                    try appendGateError(
                        allocator,
                        &errors,
                        "terminal tuple verdict requires failure.failureCode=null",
                        .{},
                    );
                }
                if (fieldPresentNonNull(failure_obj, "failureClass")) {
                    try appendGateError(
                        allocator,
                        &errors,
                        "terminal tuple verdict requires failure.failureClass=null",
                        .{},
                    );
                }
                if (fieldPresentNonNull(failure_obj, "retryableSameTupleNow")) {
                    try appendGateError(
                        allocator,
                        &errors,
                        "terminal tuple verdict requires failure.retryableSameTupleNow=null",
                        .{},
                    );
                }
            }
        }
        if (jsonBoolField(verdict_obj, "tupleVerdictExists")) |tuple_verdict_exists| {
            if (tuple_verdict_exists) {
                if (!(std.mem.eql(u8, status orelse "", "clean") or
                    std.mem.eql(u8, status orelse "", "findings")))
                {
                    try appendGateError(
                        allocator,
                        &errors,
                        "tupleVerdictExists requires terminal clean or findings",
                        .{},
                    );
                }
                if (tuple) |tuple_obj| {
                    if (nonEmptyOptional(jsonStringField(tuple_obj, "repoRealpath")) == null) {
                        try appendGateError(
                            allocator,
                            &errors,
                            "tupleVerdictExists requires tuple.repoRealpath",
                            .{},
                        );
                    }
                    if (nonEmptyOptional(jsonStringField(tuple_obj, "baseSha")) == null) {
                        try appendGateError(
                            allocator,
                            &errors,
                            "tupleVerdictExists requires tuple.baseSha",
                            .{},
                        );
                    }
                    if (nonEmptyOptional(jsonStringField(tuple_obj, "headSha")) == null) {
                        try appendGateError(
                            allocator,
                            &errors,
                            "tupleVerdictExists requires tuple.headSha",
                            .{},
                        );
                    }
                    if (nonEmptyOptional(jsonStringField(tuple_obj, "targetFingerprint")) == null) {
                        try appendGateError(
                            allocator,
                            &errors,
                            "tupleVerdictExists requires tuple.targetFingerprint",
                            .{},
                        );
                    }
                }
                if (std.mem.eql(u8, status orelse "", "clean") or
                    std.mem.eql(u8, status orelse "", "findings"))
                {
                    if (attempt_exists_value != true) {
                        try appendGateError(
                            allocator,
                            &errors,
                            "terminal tuple verdict requires attempt.exists=true",
                            .{},
                        );
                    }
                    if (attempt) |attempt_obj| {
                        if (nonEmptyOptional(jsonStringField(
                            attempt_obj,
                            "reviewThreadId",
                        )) == null) {
                            try appendGateError(
                                allocator,
                                &errors,
                                "terminal tuple verdict requires attempt.reviewThreadId",
                                .{},
                            );
                        }
                        if (nonEmptyOptional(jsonStringField(
                            attempt_obj,
                            "reviewTurnId",
                        )) == null) {
                            try appendGateError(
                                allocator,
                                &errors,
                                "terminal tuple verdict requires attempt.reviewTurnId",
                                .{},
                            );
                        }
                        const phase = jsonStringField(attempt_obj, "phase") orelse "";
                        if (!(std.mem.eql(u8, phase, "review_terminal") or
                            std.mem.eql(u8, phase, "normalized_verdict")))
                        {
                            try appendGateError(
                                allocator,
                                &errors,
                                "terminal tuple verdict requires terminal attempt.phase",
                                .{},
                            );
                        }
                    }
                }
            }
        } else {
            try appendGateError(
                allocator,
                &errors,
                "verdict.tupleVerdictExists must be boolean",
                .{},
            );
        }
    }

    if (principal) |principal_obj| {
        const kind = jsonStringField(principal_obj, "kind");
        if (kind == null or
            !(std.mem.eql(u8, kind.?, "strong") or
                std.mem.eql(u8, kind.?, "reduced") or
                std.mem.eql(u8, kind.?, "unknown")))
        {
            try appendGateError(
                allocator,
                &errors,
                "principal.kind must be strong, reduced, or unknown",
                .{},
            );
        }
        const proof_usable = jsonBoolField(principal_obj, "proofUsable");
        if (proof_usable == null) {
            try appendGateError(allocator, &errors, "principal.proofUsable must be boolean", .{});
        }
        const reduced = jsonBoolField(principal_obj, "reduced");
        if (reduced == null) {
            try appendGateError(allocator, &errors, "principal.reduced must be boolean", .{});
        }
        const fallback_used = jsonBoolField(principal_obj, "fallbackUsed");
        if (fallback_used == null) {
            try appendGateError(allocator, &errors, "principal.fallbackUsed must be boolean", .{});
        } else if (fallback_used != false) {
            try appendGateError(allocator, &errors, "principal.fallbackUsed must be false", .{});
        }
        if (std.mem.eql(u8, kind orelse "", "reduced")) {
            if (proof_usable != false) {
                try appendGateError(
                    allocator,
                    &errors,
                    "principal.kind=reduced requires proofUsable=false",
                    .{},
                );
            }
            if (reduced != true) {
                try appendGateError(
                    allocator,
                    &errors,
                    "principal.kind=reduced requires reduced=true",
                    .{},
                );
            }
        }
        if (proof_usable == true) {
            if (!std.mem.eql(u8, kind orelse "", "strong")) {
                try appendGateError(
                    allocator,
                    &errors,
                    "proofUsable=true requires principal.kind=strong",
                    .{},
                );
            }
            if (reduced != false) {
                try appendGateError(
                    allocator,
                    &errors,
                    "proofUsable=true requires principal.reduced=false",
                    .{},
                );
            }
            if (!casRerPrincipalFingerprintUsable(
                jsonStringField(principal_obj, "accountFingerprint"),
            )) {
                try appendGateError(
                    allocator,
                    &errors,
                    "proofUsable=true requires principal.accountFingerprint",
                    .{},
                );
            }
        }
    }

    return .{
        .path = try allocator.dupe(u8, path),
        .errors = try errors.toOwnedSlice(allocator),
    };
}

fn gateErrorsContain(gate: GateResult, needle: []const u8) bool {
    for (gate.errors) |err| {
        if (std.mem.indexOf(u8, err, needle) != null) return true;
    }
    return false;
}

fn tupleIdentityUnavailableFailureInfo() FailureInfo {
    return .{
        .code = "target_identity_unavailable",
        .hint = "review result is not proof because baseSha, headSha, and " ++
            "targetFingerprint were not all captured",
    };
}

fn terminalBindingFailureForIdentity(
    allocator: std.mem.Allocator,
    status: ReviewStatus,
    identity: TargetIdentity,
) ?FailureInfo {
    return terminalLockFailureForStatus(allocator, status) orelse
        if (!identityHasCompleteTuple(identity))
            tupleIdentityUnavailableFailureInfo()
        else
            null;
}

fn terminalBindingFailureForOptionalIdentity(
    allocator: std.mem.Allocator,
    status: ReviewStatus,
    identity_opt: ?TargetIdentity,
) ?FailureInfo {
    return terminalLockFailureForStatus(allocator, status) orelse
        if (identity_opt) |identity|
            if (!identityHasCompleteTuple(identity))
                tupleIdentityUnavailableFailureInfo()
            else
                null
        else
            tupleIdentityUnavailableFailureInfo();
}

fn reviewTupleCurrentnessFailureAlloc(
    allocator: std.mem.Allocator,
    stored: ReviewTupleIdentity,
    current: ReviewTupleIdentity,
) !?FailureInfo {
    if (stored.account_fingerprint_reduced_protection or
        current.account_fingerprint_reduced_protection or
        std.mem.eql(u8, stored.account_fingerprint, unknown_account_fingerprint) or
        std.mem.eql(u8, current.account_fingerprint, unknown_account_fingerprint))
    {
        return .{
            .code = "review_principal_unavailable",
            .hint = "the current strong account principal could not be bound to the review attempt",
        };
    }
    if (std.mem.eql(u8, stored.codex_thread_id, "reduced-unspecified") or
        std.mem.eql(u8, current.codex_thread_id, "reduced-unspecified"))
    {
        return .{
            .code = "review_context_unavailable",
            .hint = "the current Codex thread identity could not be bound to the review attempt",
        };
    }
    const stored_hash = try reviewTupleHashAlloc(allocator, stored);
    defer allocator.free(stored_hash);
    const current_hash = try reviewTupleHashAlloc(allocator, current);
    defer allocator.free(current_hash);
    if (!std.mem.eql(u8, stored_hash, current_hash)) {
        return .{
            .code = "review_tuple_mismatch",
            .hint = "the current repository, runtime, principal, or Codex " ++
                "thread differs from the recorded review tuple",
        };
    }
    return null;
}

fn reviewContextRecaptureFailureInfo() FailureInfo {
    return .{
        .code = "review_context_unavailable",
        .hint = "the terminal repository, runtime, principal, and Codex thread " ++
            "tuple could not be recaptured",
    };
}

const TerminalReviewContext = struct {
    identity: ?TargetIdentity = null,
    codex_path: ?[]const u8 = null,
    codex_version: ?[]const u8 = null,
    tuple: ?ReviewTupleIdentity = null,

    fn deinit(self: TerminalReviewContext, allocator: std.mem.Allocator) void {
        if (self.tuple) |tuple| tuple.deinit(allocator);
        if (self.codex_version) |version| allocator.free(version);
        if (self.codex_path) |path| allocator.free(path);
        if (self.identity) |identity| identity.deinit(allocator);
    }
};

fn captureTerminalReviewContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    target: TargetConfig,
    developer_instructions: ?[]const u8,
    client: *cas.Client,
    workflow_binding: ?WorkflowBinding,
) TerminalReviewContext {
    var context = TerminalReviewContext{};
    context.identity = computeTargetIdentityAlloc(
        allocator,
        io,
        cwd,
        target,
        developer_instructions,
    ) catch null;
    context.codex_path = cas.resolveExecutableAlloc(allocator, "codex") catch null;
    if (context.codex_path) |path| {
        context.codex_version = readCodexVersionAlloc(allocator, io, cwd, path) catch null;
    }
    if (context.identity) |identity| {
        if (context.codex_path) |path| {
            if (context.codex_version) |version| {
                context.tuple = reviewTupleIdentityAlloc(
                    allocator,
                    cwd,
                    identity,
                    path,
                    version,
                    client,
                    workflow_binding,
                ) catch null;
            }
        }
    }
    return context;
}

fn terminalReviewFailureAlloc(
    allocator: std.mem.Allocator,
    status: ReviewStatus,
    expected_identity: TargetIdentity,
    captured_identity: ?TargetIdentity,
    stored_tuple: ReviewTupleIdentity,
    captured_tuple: ?ReviewTupleIdentity,
) !?FailureInfo {
    const subject_failure = if (captured_identity) |identity|
        if (targetIdentitiesEqual(expected_identity, identity))
            null
        else
            reviewSubjectChangedFailureInfo()
    else
        reviewSubjectRecaptureFailureInfo();
    const context_failure = if (captured_tuple) |tuple|
        try reviewTupleCurrentnessFailureAlloc(allocator, stored_tuple, tuple)
    else
        reviewContextRecaptureFailureInfo();
    return terminalBindingFailureForIdentity(
        allocator,
        status,
        expected_identity,
    ) orelse subject_failure orelse context_failure;
}

fn fetchReviewStatus(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    review_thread_id: []const u8,
    review_turn_id: ?[]const u8,
    event_log_path: []const u8,
    live_notifications: ?*LiveReviewNotificationState,
    codex_version: []const u8,
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
        appendLogRecord(allocator, event_log_path, "thread/read", "error", detail) catch {};
        if (reviewHistoryIsNotMaterialized(detail)) {
            const without_turns_params = try stringifyAnyAlloc(allocator, .{
                .threadId = review_thread_id,
                .includeTurns = false,
            });
            defer allocator.free(without_turns_params);
            const without_turns_json = (if (live_notifications != null)
                client.requestJsonCaptureNotifications(
                    "thread/read",
                    without_turns_params,
                    &captured_notifications,
                )
            else
                client.requestJson("thread/read", without_turns_params)) catch |fallback_err| {
                const fallback_detail = client.lastError() orelse @errorName(fallback_err);
                appendLogRecord(allocator, event_log_path, "thread/read", "error", fallback_detail) catch {};
                if (!reviewHistoryIsNotMaterialized(fallback_detail)) return fallback_err;
                if (live_notifications) |state| {
                    try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
                }
                var pending = try unmaterializedReviewStatusAlloc(allocator, fallback_detail);
                errdefer pending.deinit(allocator);
                try populateReviewEvidenceFromLiveNotifications(allocator, &pending, live_notifications);
                return pending;
            };
            defer allocator.free(without_turns_json);
            if (live_notifications) |state| {
                try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
            }
            try appendLogRecord(
                allocator,
                event_log_path,
                "thread/read",
                "response",
                without_turns_json,
            );
            var status = try parseReviewStatusAlloc(
                allocator,
                without_turns_json,
                false,
                review_thread_id,
                review_turn_id,
            );
            try populateReviewResult(allocator, &status, review_turn_id);
            try populateReviewEvidenceFromLiveNotifications(allocator, &status, live_notifications);
            if (try maybeResumeMaterializedThread(allocator, client, review_thread_id, event_log_path, &status, codex_version)) {
                status.deinit(allocator);
                for (captured_notifications.items) |line| allocator.free(line);
                captured_notifications.clearRetainingCapacity();
                const resumed_json = if (live_notifications != null)
                    try client.requestJsonCaptureNotifications(
                        "thread/read",
                        without_turns_params,
                        &captured_notifications,
                    )
                else
                    try client.requestJson("thread/read", without_turns_params);
                defer allocator.free(resumed_json);
                if (live_notifications) |state| {
                    try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
                }
                try appendLogRecord(allocator, event_log_path, "thread/read", "response", resumed_json);
                var resumed_status = try parseReviewStatusAlloc(
                    allocator,
                    resumed_json,
                    false,
                    review_thread_id,
                    review_turn_id,
                );
                try populateReviewResult(allocator, &resumed_status, review_turn_id);
                try populateReviewEvidenceFromLiveNotifications(
                    allocator,
                    &resumed_status,
                    live_notifications,
                );
                return resumed_status;
            }
            return status;
        }
        return err;
    };
    defer allocator.free(response_json);
    if (live_notifications) |state| {
        try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
    }
    try appendLogRecord(allocator, event_log_path, "thread/read", "response", response_json);
    var status = try parseReviewStatusAlloc(
        allocator,
        response_json,
        true,
        review_thread_id,
        review_turn_id,
    );
    try populateReviewResult(allocator, &status, review_turn_id);
    try populateReviewEvidenceFromLiveNotifications(allocator, &status, live_notifications);
    if (try maybeResumeMaterializedThread(allocator, client, review_thread_id, event_log_path, &status, codex_version)) {
        status.deinit(allocator);
        const params_after_resume = try stringifyAnyAlloc(allocator, .{
            .threadId = review_thread_id,
            .includeTurns = true,
        });
        defer allocator.free(params_after_resume);
        for (captured_notifications.items) |line| allocator.free(line);
        captured_notifications.clearRetainingCapacity();
        const resumed_json = if (live_notifications != null)
            try client.requestJsonCaptureNotifications("thread/read", params_after_resume, &captured_notifications)
        else
            try client.requestJson("thread/read", params_after_resume);
        defer allocator.free(resumed_json);
        if (live_notifications) |state| {
            try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
        }
        try appendLogRecord(allocator, event_log_path, "thread/read", "response", resumed_json);
        var resumed_status = try parseReviewStatusAlloc(
            allocator,
            resumed_json,
            true,
            review_thread_id,
            review_turn_id,
        );
        try populateReviewResult(allocator, &resumed_status, review_turn_id);
        try populateReviewEvidenceFromLiveNotifications(
            allocator,
            &resumed_status,
            live_notifications,
        );
        return resumed_status;
    }
    return status;
}

fn fetchReviewStatusAfterWaitTimeout(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    review_thread_id: []const u8,
    review_turn_id: ?[]const u8,
    event_log_path: []const u8,
    codex_version: []const u8,
    poll_interval_ms: u32,
) !ReviewStatus {
    // Poll cadence never extends the caller's explicit operation deadline.
    // The final status observation has one small independent grace window.
    const grace_ms = finalReviewStatusGraceMs(poll_interval_ms);
    const previous_deadline = client.swapRequestDeadlineMs(
        monotonicMilliseconds() + @as(i64, grace_ms),
    );
    defer _ = client.swapRequestDeadlineMs(previous_deadline);
    return fetchReviewStatus(
        allocator,
        client,
        review_thread_id,
        review_turn_id,
        event_log_path,
        null,
        codex_version,
    );
}

fn finalReviewStatusGraceMs(poll_interval_ms: u32) u32 {
    _ = poll_interval_ms;
    return 250;
}

fn reviewGraceStatusCompletesWait(status: *const ReviewStatus) bool {
    return status.review_result_available or isTerminalTurnStatus(status.turn_status);
}

fn reviewHistoryIsNotMaterialized(detail: []const u8) bool {
    if (std.mem.indexOf(u8, detail, "includeTurns is unavailable") != null or
        std.mem.indexOf(u8, detail, "not materialized yet") != null)
    {
        return true;
    }
    const thread_read_failed =
        std.mem.indexOf(u8, detail, "failed to load thread history") != null or
        std.mem.indexOf(u8, detail, "failed to read thread") != null;
    return thread_read_failed and
        std.mem.indexOf(u8, detail, "failed to read session metadata") != null and
        std.mem.indexOf(u8, detail, "rollout at ") != null and
        std.mem.indexOf(u8, detail, " is empty") != null;
}

fn unmaterializedReviewStatusAlloc(
    allocator: std.mem.Allocator,
    raw_error: []const u8,
) !ReviewStatus {
    const thread_status = try allocator.dupe(u8, "materializing");
    errdefer allocator.free(thread_status);
    const turn_status = try allocator.dupe(u8, "materializing");
    errdefer allocator.free(turn_status);
    const thread_preview = try allocator.dupe(u8, "");
    errdefer allocator.free(thread_preview);
    const raw_response_json = try allocator.dupe(u8, raw_error);
    errdefer allocator.free(raw_response_json);
    return .{
        .thread_status = thread_status,
        .turn_status = turn_status,
        .turn_count = 0,
        .materialized = false,
        .thread_preview = thread_preview,
        .rollout_path = null,
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = false,
        .last_turn_has_exited_review_mode = false,
        .review_result_available = false,
        .review_result_source = null,
        .review_result_json = null,
        .review_text = null,
        .raw_response_json = raw_response_json,
    };
}

fn parseReviewStatusAlloc(
    allocator: std.mem.Allocator,
    raw_json: []const u8,
    materialized: bool,
    expected_thread_id: ?[]const u8,
    expected_turn_id: ?[]const u8,
) !ReviewStatus {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    const thread_obj = core_json.objectField(root_obj, "thread") orelse return error.MissingThread;
    if (expected_thread_id) |expected| {
        const observed = core_json.stringField(thread_obj, "id") orelse
            return error.MissingThreadId;
        if (!std.mem.eql(u8, observed, expected)) return error.ReviewThreadMismatch;
    }
    const thread_preview = if (core_json.stringField(thread_obj, "preview")) |preview|
        try allocator.dupe(u8, preview)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(thread_preview);
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
    errdefer if (turn_error_message) |message| allocator.free(message);
    var last_turn_has_entered_review_mode = false;
    var last_turn_has_exited_review_mode = false;
    const rollout_path = if (core_json.stringField(thread_obj, "path")) |path|
        try allocator.dupe(u8, path)
    else
        null;
    errdefer if (rollout_path) |path| allocator.free(path);
    var selected_turn: ?std.json.ObjectMap = null;
    if (thread_obj.get("turns")) |turns_val| switch (turns_val) {
        .array => |arr| {
            turn_count = arr.items.len;
            if (expected_turn_id) |expected| {
                for (arr.items) |turn| {
                    if (turn != .object) continue;
                    const observed = core_json.stringField(turn.object, "id") orelse continue;
                    if (!std.mem.eql(u8, observed, expected)) continue;
                    if (selected_turn != null) return error.DuplicateReviewTurn;
                    selected_turn = turn.object;
                }
            } else if (arr.items.len > 0 and arr.items[arr.items.len - 1] == .object) {
                selected_turn = arr.items[arr.items.len - 1].object;
            }
            if (selected_turn) |turn| {
                if (core_json.stringField(turn, "status")) |status| turn_status = status;
                if (turn.get("error")) |error_val| {
                    turn_error_message = try extractErrorMessageAlloc(allocator, error_val);
                }
                if (turn.get("items")) |items_val| switch (items_val) {
                    .array => |items| {
                        for (items.items) |item| {
                            if (item != .object) continue;
                            const item_type = core_json.stringField(
                                item.object,
                                "type",
                            ) orelse continue;
                            if (std.mem.eql(u8, item_type, "enteredReviewMode")) {
                                last_turn_has_entered_review_mode = true;
                            }
                            if (std.mem.eql(u8, item_type, "exitedReviewMode")) {
                                last_turn_has_exited_review_mode = true;
                            }
                        }
                    },
                    else => {},
                };
            }
        },
        else => {},
    };
    // An inline review may own the thread before Codex materializes its rollout.
    // Preserve turn identity once turns are observable, while allowing callers
    // to retain the structured non-terminal state during that interval.
    if (materialized and expected_turn_id != null and selected_turn == null) {
        return error.MissingReviewTurn;
    }
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

fn populateReviewResult(
    allocator: std.mem.Allocator,
    status: *ReviewStatus,
    review_turn_id: ?[]const u8,
) !void {
    if (!status.materialized) return;
    if (!isTerminalTurnStatus(status.turn_status)) return;
    const expected_turn_id = review_turn_id orelse return;
    const rollout_path = status.rollout_path orelse return;
    if (try readReviewResultJsonFromRolloutAlloc(
        allocator,
        rollout_path,
        expected_turn_id,
    )) |json| {
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

fn populateReviewEvidenceFromLiveNotifications(
    allocator: std.mem.Allocator,
    status: *ReviewStatus,
    live_notifications: ?*LiveReviewNotificationState,
) !void {
    const state = live_notifications orelse return;
    status.last_turn_has_entered_review_mode =
        status.last_turn_has_entered_review_mode or state.saw_entered_review_mode;
    status.last_turn_has_exited_review_mode =
        status.last_turn_has_exited_review_mode or state.saw_exited_review_mode;
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
}

fn maybeResumeMaterializedThread(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    review_thread_id: []const u8,
    event_log_path: []const u8,
    status: *const ReviewStatus,
    codex_version: []const u8,
) !bool {
    if (!status.materialized) return false;
    if (!std.mem.eql(u8, status.thread_status, "notLoaded")) return false;
    const rollout_path = status.rollout_path orelse return false;

    const params_json = try buildThreadResumeParamsJson(
        allocator,
        review_thread_id,
        rollout_path,
        codex_version,
    );
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

fn buildTurnStartParamsJson(
    allocator: std.mem.Allocator,
    thread_id: []const u8,
    text: []const u8,
) ![]u8 {
    const thread_id_json = try quoteJsonStringAlloc(allocator, thread_id);
    defer allocator.free(thread_id_json);
    const text_json = try quoteJsonStringAlloc(allocator, text);
    defer allocator.free(text_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"threadId\":{s},\"input\":[{{\"type\":\"text\",\"text\":{s}}}]}}",
        .{ thread_id_json, text_json },
    );
}

fn waitForThreadTerminalState(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    thread_id: []const u8,
    event_log_path: []const u8,
    timeout_ms: u32,
    poll_interval_ms: u32,
    codex_version: []const u8,
) !ReviewStatus {
    const started_ms = @divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000);
    while (true) {
        const latest = try fetchReviewStatus(
            allocator,
            client,
            thread_id,
            null,
            event_log_path,
            null,
            codex_version,
        );
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
    codex_version: []const u8,
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
        codex_version,
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
    return gitOutputAllocLimited(allocator, io, cwd, argv_tail, 16 * 1024);
}

fn gitOutputAllocLimited(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv_tail: []const []const u8,
    max_stdout_bytes: usize,
) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (argv_tail) |arg| try argv.append(allocator, arg);
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(max_stdout_bytes),
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

fn gitOutputRawAllocLimited(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv_tail: []const []const u8,
    max_stdout_bytes: usize,
) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (argv_tail) |arg| try argv.append(allocator, arg);
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(max_stdout_bytes),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.GitCommandFailed;
    return allocator.dupe(u8, result.stdout);
}

fn dirtyStateDigestAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const status = try gitOutputRawAllocLimited(
        allocator,
        io,
        cwd,
        &.{ "status", "--porcelain=v1", "-z", "--untracked-files=all" },
        16 * 1024 * 1024,
    );
    defer allocator.free(status);
    hasher.update("status\x00");
    hasher.update(status);

    const diff = try gitOutputRawAllocLimited(
        allocator,
        io,
        cwd,
        &.{ "diff", "--binary", "HEAD", "--" },
        64 * 1024 * 1024,
    );
    defer allocator.free(diff);
    hasher.update("diff-head\x00");
    hasher.update(diff);

    const staged = try gitOutputRawAllocLimited(
        allocator,
        io,
        cwd,
        &.{ "diff", "--binary", "--cached", "HEAD", "--" },
        64 * 1024 * 1024,
    );
    defer allocator.free(staged);
    hasher.update("diff-cached\x00");
    hasher.update(staged);

    const untracked = try gitOutputRawAllocLimited(
        allocator,
        io,
        cwd,
        &.{ "ls-files", "--others", "--exclude-standard", "-z" },
        16 * 1024 * 1024,
    );
    defer allocator.free(untracked);
    var iter = std.mem.splitScalar(u8, untracked, 0);
    while (iter.next()) |path| {
        if (path.len == 0) continue;
        hasher.update("untracked\x00");
        hasher.update(path);
        hasher.update("\x00");
        const absolute_path = try std.fs.path.join(allocator, &.{ cwd, path });
        defer allocator.free(absolute_path);
        try hashUntrackedEntry(allocator, io, &hasher, absolute_path);
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
}

fn hashUntrackedEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    hasher: *std.crypto.hash.sha2.Sha256,
    absolute_path: []const u8,
) !void {
    const stat = try std.Io.Dir.cwd().statFile(
        io,
        absolute_path,
        .{ .follow_symlinks = false },
    );
    hasher.update("kind\x00");
    hasher.update(@tagName(stat.kind));
    hasher.update("\x00");
    switch (stat.kind) {
        .file => {
            const bytes = try readFileAlloc(
                allocator,
                absolute_path,
                16 * 1024 * 1024,
            );
            defer allocator.free(bytes);
            hasher.update(bytes);
        },
        .sym_link => {
            var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const target_len = try std.Io.Dir.readLinkAbsolute(
                io,
                absolute_path,
                &target_buffer,
            );
            hasher.update("target\x00");
            hasher.update(target_buffer[0..target_len]);
        },
        else => {},
    }
}

fn canonicalTargetAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    target: TargetConfig,
) !CanonicalTarget {
    var canonical = target;
    canonical.branch = if (target.branch) |branch|
        std.mem.trim(u8, branch, " \t\r\n")
    else
        null;
    canonical.title = if (target.title) |title| blk: {
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        break :blk if (trimmed.len == 0) null else trimmed;
    } else null;
    switch (target.kind) {
        .uncommitted => return .{ .value = canonical },
        .base_branch => {
            if (canonical.branch == null or canonical.branch.?.len == 0) {
                return error.InvalidBaseTarget;
            }
            return .{ .value = canonical };
        },
        .commit => {
            const selector = if (target.sha) |sha|
                std.mem.trim(u8, sha, " \t\r\n")
            else
                return error.InvalidCommitTarget;
            if (selector.len == 0) return error.InvalidCommitTarget;
            const commit_ref = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{selector});
            defer allocator.free(commit_ref);
            const canonical_sha = try gitOutputAlloc(
                allocator,
                io,
                cwd,
                &.{ "rev-parse", "--verify", commit_ref },
            );
            canonical.sha = canonical_sha;
            return .{ .value = canonical, .owned_sha = canonical_sha };
        },
    }
}

fn computeTargetIdentityAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    target: TargetConfig,
    developer_instructions: ?[]const u8,
) !TargetIdentity {
    const current_head_sha = try gitOutputAlloc(
        allocator,
        io,
        cwd,
        &.{ "rev-parse", "--verify", "HEAD^{commit}" },
    );
    defer allocator.free(current_head_sha);
    const dirty_digest = if (target.kind == .uncommitted)
        try dirtyStateDigestAlloc(allocator, io, cwd)
    else
        null;
    defer if (dirty_digest) |value| allocator.free(value);
    const head_sha = if (target.kind == .commit)
        try allocator.dupe(u8, target.sha.?)
    else if (target.kind == .uncommitted)
        try std.fmt.allocPrint(allocator, "{s}+dirty:{s}", .{ current_head_sha, dirty_digest.? })
    else
        try allocator.dupe(u8, current_head_sha);
    errdefer allocator.free(head_sha);
    const commit_parent_ref = if (target.kind == .commit)
        try std.fmt.allocPrint(allocator, "{s}^", .{target.sha.?})
    else
        null;
    defer if (commit_parent_ref) |value| allocator.free(value);
    const base_sha = switch (target.kind) {
        .base_branch => try gitOutputAlloc(
            allocator,
            io,
            cwd,
            &.{ "merge-base", "HEAD", target.branch.? },
        ),
        .commit => try gitOutputAlloc(
            allocator,
            io,
            cwd,
            &.{ "rev-parse", "--verify", commit_parent_ref.? },
        ),
        .uncommitted => try allocator.dupe(u8, current_head_sha),
    };
    errdefer allocator.free(base_sha);
    const target_record = targetToRecord(target);
    const target_json = try stringifyAnyAlloc(allocator, .{
        .target = target_record,
        .developerInstructions = developer_instructions,
    });
    defer allocator.free(target_json);
    const fingerprint = if (dirty_digest) |digest|
        try std.fmt.allocPrint(allocator, "target={s};head={s};base={s};dirty={s}", .{
            target_json,
            head_sha,
            base_sha,
            digest,
        })
    else
        try std.fmt.allocPrint(allocator, "target={s};head={s};base={s}", .{
            target_json,
            head_sha,
            base_sha,
        });
    return .{
        .head_sha = head_sha,
        .base_sha = base_sha,
        .fingerprint = fingerprint,
    };
}

fn targetIdentityForRecordAlloc(
    allocator: std.mem.Allocator,
    record: SessionRecord,
) !TargetIdentity {
    const fingerprint = record.target_fingerprint orelse return error.MissingTargetIdentity;
    return .{
        .head_sha = try dupOptional(allocator, record.head_sha),
        .base_sha = try dupOptional(allocator, record.base_sha),
        .fingerprint = try allocator.dupe(u8, fingerprint),
    };
}

fn targetConfigFromRecord(record: TargetRecord) !TargetConfig {
    if (std.mem.eql(u8, record.type, "uncommittedChanges")) {
        if (record.branch != null or record.sha != null or record.title != null) {
            return error.InvalidSessionTarget;
        }
        return .{ .kind = .uncommitted };
    }
    if (std.mem.eql(u8, record.type, "baseBranch")) {
        const branch = record.branch orelse return error.InvalidSessionTarget;
        if (branch.len == 0 or record.sha != null or record.title != null) {
            return error.InvalidSessionTarget;
        }
        return .{ .kind = .base_branch, .branch = branch };
    }
    if (std.mem.eql(u8, record.type, "commit")) {
        const sha = record.sha orelse return error.InvalidSessionTarget;
        if (sha.len == 0 or record.branch != null) return error.InvalidSessionTarget;
        return .{ .kind = .commit, .sha = sha, .title = record.title };
    }
    return error.InvalidSessionTarget;
}

fn targetRecordFieldKnown(key: []const u8) bool {
    return std.mem.eql(u8, key, "type") or
        std.mem.eql(u8, key, "branch") or
        std.mem.eql(u8, key, "sha") or
        std.mem.eql(u8, key, "title");
}

fn nullableTargetRecordString(
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]const u8 {
    const value = object.get(key) orelse return error.InvalidSessionTarget;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidSessionTarget,
    };
}

fn canonicalTargetRecordJsonFromValueAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidSessionTarget,
    };
    var field_count: usize = 0;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!targetRecordFieldKnown(entry.key_ptr.*)) {
            return error.InvalidSessionTarget;
        }
        field_count += 1;
    }
    if (field_count != 4) return error.InvalidSessionTarget;
    const record = TargetRecord{
        .type = jsonStringField(object, "type") orelse
            return error.InvalidSessionTarget,
        .branch = try nullableTargetRecordString(object, "branch"),
        .sha = try nullableTargetRecordString(object, "sha"),
        .title = try nullableTargetRecordString(object, "title"),
    };
    _ = try targetConfigFromRecord(record);
    return stringifyAnyAlloc(allocator, record);
}

fn targetRecordJsonFromRootAlloc(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) !?[]u8 {
    const value = root.get("target") orelse return null;
    return try canonicalTargetRecordJsonFromValueAlloc(allocator, value);
}

fn targetIdentitiesEqual(left: TargetIdentity, right: TargetIdentity) bool {
    return optionalStringsEqual(left.base_sha, right.base_sha) and
        optionalStringsEqual(left.head_sha, right.head_sha) and
        std.mem.eql(u8, left.fingerprint, right.fingerprint);
}

fn reviewSubjectChangedFailureInfo() FailureInfo {
    return .{
        .code = "review_subject_changed",
        .hint = "the repository subject no longer matches the target captured " ++
            "before review; start a fresh review on the current subject",
    };
}

fn reviewSubjectRecaptureFailureInfo() FailureInfo {
    return .{
        .code = "review_subject_recapture_failed",
        .hint = "CAS could not recapture the selected Git subject at terminal " ++
            "proof; the review result is not current-subject evidence",
    };
}

fn isTerminalTurnStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "completed") or
        std.mem.eql(u8, status, "interrupted") or
        std.mem.eql(u8, status, "failed") or
        std.mem.eql(u8, status, "errored");
}

fn reviewAttemptRuntimeVersion(
    recorded_codex_version: []const u8,
    current_codex_version: []const u8,
) []const u8 {
    _ = current_codex_version;
    return recorded_codex_version;
}

fn reviewStatusAwaitsStructuredCompletion(
    codex_version: []const u8,
    status: *const ReviewStatus,
) bool {
    return std.mem.eql(u8, codexReviewDelivery(codex_version), "inline") and
        std.mem.eql(u8, status.turn_status, "completed") and
        status.last_turn_has_entered_review_mode and
        !status.last_turn_has_exited_review_mode and
        !status.review_result_available;
}

fn isTransportLossError(err: anyerror) bool {
    return err == error.AppServerClosed or
        err == error.ConnectionRefused or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut or
        err == error.ConnectionPoisoned or
        err == error.BrokenPipe or
        err == error.EndOfStream;
}

fn reviewStartFailureOwnsAttempt(
    workflow_bound: bool,
    request_send_started: bool,
    err: anyerror,
) bool {
    // For a closure-grade request, the send boundary is the authority: every
    // error after it is ambiguous and therefore terminal. A proven pre-send
    // failure remains retryable without consuming attempt credit. Historical
    // unbound starts preserve their transport-loss terminalization behavior.
    return if (workflow_bound) request_send_started else isTransportLossError(err);
}

fn monotonicMilliseconds() i64 {
    return @intCast(@divFloor(
        std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds,
        1_000_000,
    ));
}

fn waitForReviewCompletion(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
    event_log_path: []const u8,
    timeout_ms: u32,
    poll_interval_ms: u32,
    codex_version: []const u8,
    absolute_deadline_ms: ?i64,
) !ReviewStatus {
    const deadline_ms = absolute_deadline_ms orelse
        (monotonicMilliseconds() + @as(i64, timeout_ms));
    const previous_request_deadline = client.swapRequestDeadlineMs(deadline_ms);
    defer _ = client.swapRequestDeadlineMs(previous_request_deadline);
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

        const poll_result_json = client.requestJsonCaptureNotifications(
            "experimentalFeature/list",
            "{\"cursor\":null,\"limit\":1}",
            &captured_notifications,
        ) catch |err| switch (err) {
            error.ConnectionTimedOut => return error.WaitTimedOut,
            else => return err,
        };
        allocator.free(poll_result_json);
        try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, &live_notifications);

        if (live_notifications.observed_terminal_status != null) {
            const latest = fetchReviewStatus(
                allocator,
                client,
                review_thread_id,
                review_turn_id,
                event_log_path,
                &live_notifications,
                codex_version,
            ) catch |err| switch (err) {
                error.ConnectionTimedOut => return error.WaitTimedOut,
                else => return err,
            };
            if (!reviewStatusAwaitsStructuredCompletion(codex_version, &latest)) {
                return latest;
            }
            latest.deinit(allocator);
        }
        const now_ms = @divFloor(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000);
        if (now_ms >= deadline_ms) return error.WaitTimedOut;
        const remaining_ms: u32 = @intCast(deadline_ms - now_ms);
        std.Io.sleep(
            std.Io.Threaded.global_single_threaded.io(),
            .fromMilliseconds(@min(poll_interval_ms, remaining_ms)),
            .awake,
        ) catch {};
    }
}

const ReviewWaitTimeoutDisposition = struct {
    lock_state: []const u8,
    failure: FailureInfo,
};

fn reviewWaitTimeoutDisposition(workflow_bound: bool) ReviewWaitTimeoutDisposition {
    if (workflow_bound) {
        return .{
            .lock_state = "terminal",
            .failure = .{
                .code = "review_transport_timeout",
                .hint = "owner-lived review reached its finite deadline; " ++
                    "start one fresh same-request recovery attempt",
            },
        };
    }
    return .{
        .lock_state = "waiting",
        .failure = .{
            .code = "wait_timed_out",
            .hint = "retry cas review wait on the same review thread " ++
                "or increase --timeout-ms",
        },
    };
}

fn terminalReviewTransportFailure(code: []const u8) ?FailureInfo {
    if (std.mem.eql(u8, code, "review_transport_timeout")) return .{
        .code = "review_transport_timeout",
        .hint = "owner-lived review reached its finite deadline; start one fresh same-request recovery attempt",
    };
    if (std.mem.eql(u8, code, "review_transport_lost")) return .{
        .code = "review_transport_lost",
        .hint = "managed websocket review transport is terminal; start one fresh same-request recovery attempt",
    };
    return null;
}

fn terminalReviewOwnerFailure(code: []const u8) ?FailureInfo {
    if (terminalReviewTransportFailure(code)) |failure| return failure;
    if (std.mem.eql(u8, code, "review_owner_failed")) return .{
        .code = "review_owner_failed",
        .hint = "the owner-lived review process terminated after launch; inspect its durable receipt, then start one fresh exact-request recovery attempt",
    };
    return null;
}

fn workflowOwnerActiveFailureInfo() FailureInfo {
    return .{
        .code = "workflow_bound_review_owner_active",
        .hint = "the owner-lived review process is still active; consume its terminal receipt instead of starting a duplicate owner",
    };
}

fn workflowDeadOwnerAttemptExists(lock: ReviewTupleLock) bool {
    return lock.reviewStartSendStarted or lock.reviewThreadId != null;
}

fn workflowDeadOwnerFailureInfo(lock: ReviewTupleLock) FailureInfo {
    if (workflowDeadOwnerAttemptExists(lock)) {
        return .{
            .code = "review_transport_lost",
            .hint = "the workflow-bound review owner died; the lease is terminal and the exact request may use one fresh recovery attempt",
        };
    }
    return .{
        .code = "workflow_bound_review_owner_lost_before_start",
        .hint = "the workflow-bound owner died before review/start send began; the exact request may retry without consuming review-attempt credit",
    };
}

fn workflowOwnedPostStartFailure(err: anyerror) FailureInfo {
    if (err == error.ConnectionTimedOut or err == error.WaitTimedOut) {
        return terminalReviewTransportFailure("review_transport_timeout").?;
    }
    if (isTransportLossError(err)) {
        return terminalReviewTransportFailure("review_transport_lost").?;
    }
    return terminalReviewOwnerFailure("review_owner_failed").?;
}

const OwnedReviewTerminalContext = struct {
    record_path: ?[]const u8 = null,
    record: ?*SessionRecord = null,
    review_thread_id: ?[]const u8 = null,
    review_turn_id: ?[]const u8 = null,
    event_log_path: ?[]const u8 = null,
};

fn terminalizeOwnedReviewAttempt(
    allocator: std.mem.Allocator,
    managed_server: *cas_websocket.ManagedServer,
    lock_path: []const u8,
    lock: ReviewTupleLock,
    context: OwnedReviewTerminalContext,
    failure: FailureInfo,
) void {
    managed_server.kill();
    const durable_failure = terminalReviewOwnerFailure(failure.code) orelse failure;
    const terminal_state = if (std.mem.eql(u8, failure.code, "account_resource_exhausted"))
        "account_resource_exhausted"
    else
        "terminal";

    const terminal_lock = withReviewTupleLockState(
        lock,
        terminal_state,
        unixSeconds(),
        failure.code,
        context.review_thread_id,
        context.review_turn_id,
        context.record_path,
        context.event_log_path,
    );
    writeReviewTupleLock(allocator, lock_path, terminal_lock) catch {};

    if (context.record) |record| {
        record.last_observed_status = "disconnected";
        record.terminal_failure_code = durable_failure.code;
        record.terminal_failure_hint = durable_failure.hint;
        record.terminal_failure_at_unix_s = unixSeconds();
        if (context.record_path) |record_path| {
            writeSessionRecord(allocator, record_path, record.*) catch {};
        }
    }
}

fn startParentThreadAlloc(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    cwd: []const u8,
    session_dir: []const u8,
    developer_instructions: ?[]const u8,
) ![]const u8 {
    const params_json = try buildThreadStartParamsJson(
        allocator,
        cwd,
        developer_instructions,
    );
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

fn buildThreadStartParamsJson(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    developer_instructions: ?[]const u8,
) ![]u8 {
    return stringifyAnyAlloc(allocator, .{
        .cwd = cwd,
        .experimentalRawEvents = false,
        .developerInstructions = developer_instructions,
    });
}

fn codexDetachedReviewNeedsLiveConnection(codex_version: []const u8) bool {
    const semver = parseSemverTriplet(codex_version) orelse return false;
    return semver.major == 0 and semver.minor == 118;
}

fn codexResumeSupportsExcludeTurns(codex_version: []const u8) bool {
    const semver = parseSemverTriplet(codex_version) orelse return false;
    return semver.major > 0 or (semver.major == 0 and semver.minor >= 145);
}

fn buildThreadResumeParamsJson(
    allocator: std.mem.Allocator,
    thread_id: []const u8,
    path: ?[]const u8,
    codex_version: []const u8,
) ![]u8 {
    if (codexResumeSupportsExcludeTurns(codex_version)) {
        if (path) |rollout_path| {
            return stringifyAnyAlloc(allocator, .{
                .threadId = thread_id,
                .path = rollout_path,
                .excludeTurns = true,
            });
        }
        return stringifyAnyAlloc(allocator, .{
            .threadId = thread_id,
            .excludeTurns = true,
        });
    }
    if (path) |rollout_path| {
        return stringifyAnyAlloc(allocator, .{
            .threadId = thread_id,
            .path = rollout_path,
        });
    }
    return stringifyAnyAlloc(allocator, .{ .threadId = thread_id });
}

fn resumeParentThread(
    allocator: std.mem.Allocator,
    client: *cas.Client,
    parent_thread_id: []const u8,
    parent_event_log_path: []const u8,
    codex_version: []const u8,
) !void {
    const params_json = try buildThreadResumeParamsJson(
        allocator,
        parent_thread_id,
        null,
        codex_version,
    );
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
    codex_version: []const u8,
) ![]u8 {
    const target_json = try buildTargetJson(allocator, target);
    defer allocator.free(target_json);
    const parent_thread_id_json = try quoteJsonStringAlloc(allocator, parent_thread_id);
    defer allocator.free(parent_thread_id_json);
    const delivery = codexReviewDelivery(codex_version);
    return std.fmt.allocPrint(
        allocator,
        "{{\"threadId\":{s},\"delivery\":\"{s}\",\"target\":{s}}}",
        .{ parent_thread_id_json, delivery, target_json },
    );
}

fn codexReviewDelivery(codex_version: []const u8) []const u8 {
    const semver = parseSemverTriplet(codex_version) orelse return "detached";
    // Codex 0.145 routes detached delivery through an ordinary review-agent
    // turn, which emits prose but no exited_review_mode.review_output. CAS
    // already owns an isolated parent thread, so native inline delivery keeps
    // the attempt isolated while preserving Codex's structured review event.
    if (semver.major > 0 or semver.minor >= 145) return "inline";
    return "detached";
}

fn codexReviewRequiresFreshParent(codex_version: []const u8) bool {
    return std.mem.eql(u8, codexReviewDelivery(codex_version), "inline");
}

fn buildTargetJson(allocator: std.mem.Allocator, target: TargetConfig) ![]u8 {
    return switch (target.kind) {
        .uncommitted => stringifyAnyAlloc(allocator, .{ .type = "uncommittedChanges" }),
        .base_branch => stringifyAnyAlloc(allocator, .{ .type = "baseBranch", .branch = target.branch.? }),
        .commit => stringifyAnyAlloc(allocator, .{ .type = "commit", .sha = target.sha.?, .title = target.title }),
    };
}

fn targetToRecord(target: TargetConfig) TargetRecord {
    return .{
        .type = target.kind.asString(),
        .branch = target.branch,
        .sha = target.sha,
        .title = target.title,
    };
}

fn casStoreRootAlloc(allocator: std.mem.Allocator) ![]const u8 {
    if (configured_store_root_override) |root| {
        return absoluteStoreRootOverrideAlloc(allocator, root);
    }
    const start_input = if (configured_store_cwd) |cwd|
        try allocator.dupe(u8, cwd)
    else
        try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(start_input);
    const start = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), start_input, allocator);
    defer allocator.free(start);
    const repo_root = durable_store.findGitRootAlloc(allocator, start) catch |err| switch (err) {
        error.GitCommandFailed => return std.fmt.allocPrint(allocator, "{s}/.ledger/cas", .{start}),
        else => return err,
    };
    defer allocator.free(repo_root);
    return std.fmt.allocPrint(allocator, "{s}/.ledger/cas", .{repo_root});
}

fn absoluteStoreRootOverrideAlloc(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    const expanded = try core_path.expandHomePath(allocator, root);
    errdefer allocator.free(expanded);
    if (std.fs.path.isAbsolute(expanded)) return expanded;
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    const absolute = try std.fs.path.join(allocator, &.{ cwd, expanded });
    allocator.free(expanded);
    return absolute;
}

fn casStorePathAlloc(allocator: std.mem.Allocator, leaf: []const u8) ![]const u8 {
    const root = try casStoreRootAlloc(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, leaf });
}

fn sessionDirAlloc(allocator: std.mem.Allocator) ![]const u8 {
    const base = try casStorePathAlloc(allocator, "review_sessions");
    try durable_store.ensureDirectoryPathNoSymlinks(base);
    return base;
}

fn reviewLedgerRecordsDirAlloc(allocator: std.mem.Allocator) ![]const u8 {
    const base = try reviewLedgerRecordsDirPathAlloc(allocator);
    try durable_store.ensureDirectoryPathNoSymlinks(base);
    return base;
}

fn reviewLedgerRecordsDirPathAlloc(allocator: std.mem.Allocator) ![]const u8 {
    return casStorePathAlloc(allocator, "review_ledger/records");
}

fn casRerRecordIdFromJsonAlloc(
    allocator: std.mem.Allocator,
    record_json: []const u8,
) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidCasRerRecord,
    };
    const record_id = nonEmptyOptional(jsonStringField(root, "recordId")) orelse
        return error.MissingCasRerRecordId;
    if (!std.mem.startsWith(u8, record_id, "rer_")) return error.InvalidCasRerRecordId;
    if (std.mem.indexOfScalar(u8, record_id, '/') != null or
        std.mem.indexOfScalar(u8, record_id, '\\') != null)
    {
        return error.InvalidCasRerRecordId;
    }
    return allocator.dupe(u8, record_id);
}

fn jsonFileContentMatches(raw: []const u8, json: []const u8) bool {
    var end = raw.len;
    while (end > 0 and (raw[end - 1] == '\n' or raw[end - 1] == '\r')) end -= 1;
    return std.mem.eql(u8, raw[0..end], json);
}

fn casRerVolatileTimestampField(key: []const u8) bool {
    return std.mem.eql(u8, key, "createdAt") or std.mem.eql(u8, key, "updatedAt");
}

fn casRerStableCompareIgnoredField(key: []const u8) bool {
    return casRerVolatileTimestampField(key) or
        std.mem.eql(u8, key, "recordPath") or
        std.mem.eql(u8, key, "sourcePath") or
        std.mem.eql(u8, key, "rawSessionRecord") or
        std.mem.eql(u8, key, "rawReceipt");
}

fn jsonValueStableEqual(
    left: std.json.Value,
    right: std.json.Value,
    ignore_cas_rer_provenance: bool,
) bool {
    return switch (left) {
        .null => right == .null,
        .bool => |left_bool| switch (right) {
            .bool => |right_bool| left_bool == right_bool,
            else => false,
        },
        .integer => |left_integer| switch (right) {
            .integer => |right_integer| left_integer == right_integer,
            else => false,
        },
        .float => |left_float| switch (right) {
            .float => |right_float| left_float == right_float,
            else => false,
        },
        .number_string => |left_number| switch (right) {
            .number_string => |right_number| std.mem.eql(u8, left_number, right_number),
            else => false,
        },
        .string => |left_string| switch (right) {
            .string => |right_string| std.mem.eql(u8, left_string, right_string),
            else => false,
        },
        .array => |left_array| switch (right) {
            .array => |right_array| blk: {
                if (left_array.items.len != right_array.items.len) break :blk false;
                for (left_array.items, right_array.items) |left_item, right_item| {
                    if (!jsonValueStableEqual(
                        left_item,
                        right_item,
                        ignore_cas_rer_provenance,
                    )) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |left_object| switch (right) {
            .object => |right_object| jsonObjectStableEqual(
                left_object,
                right_object,
                ignore_cas_rer_provenance,
            ),
            else => false,
        },
    };
}

fn jsonObjectStableEqual(
    left: std.json.ObjectMap,
    right: std.json.ObjectMap,
    ignore_cas_rer_provenance: bool,
) bool {
    var left_count: usize = 0;
    var left_it = left.iterator();
    while (left_it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (ignore_cas_rer_provenance and casRerStableCompareIgnoredField(key)) continue;
        left_count += 1;
        const right_value = right.get(key) orelse return false;
        if (!jsonValueStableEqual(
            entry.value_ptr.*,
            right_value,
            ignore_cas_rer_provenance,
        )) return false;
    }

    var right_count: usize = 0;
    var right_it = right.iterator();
    while (right_it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (ignore_cas_rer_provenance and casRerStableCompareIgnoredField(key)) continue;
        right_count += 1;
    }

    return left_count == right_count;
}

fn casRerStableContentMatchesAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    json: []const u8,
) !bool {
    var existing_parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        std.mem.trim(u8, raw, " \t\r\n"),
        .{},
    ) catch return false;
    defer existing_parsed.deinit();
    var incoming_parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        std.mem.trim(u8, json, " \t\r\n"),
        .{},
    ) catch return false;
    defer incoming_parsed.deinit();
    const existing = switch (existing_parsed.value) {
        .object => |obj| obj,
        else => return false,
    };
    const incoming = switch (incoming_parsed.value) {
        .object => |obj| obj,
        else => return false,
    };
    if (!std.mem.eql(
        u8,
        jsonStringField(existing, "schema") orelse "",
        cas_review_evidence_schema,
    )) return false;
    if (!std.mem.eql(
        u8,
        jsonStringField(incoming, "schema") orelse "",
        cas_review_evidence_schema,
    )) return false;
    if (!optionalStringsEqual(
        jsonStringField(existing, "recordId"),
        jsonStringField(incoming, "recordId"),
    )) return false;
    return jsonObjectStableEqual(existing, incoming, true);
}

fn writeRawJsonFileExclusiveOrIdenticalAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    json: []const u8,
) !void {
    const payload = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    defer allocator.free(payload);
    durable_store.writeTextCreateNewAtomic(
        allocator,
        path,
        payload,
        .{ .reject_symlinks = true },
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const existing = try durable_store.readRegularFileNoSymlink(
                allocator,
                path,
                8 * 1024 * 1024,
            );
            defer allocator.free(existing);
            if (jsonFileContentMatches(existing, json)) return;
            if (try casRerStableContentMatchesAlloc(allocator, existing, json)) return;
            return error.CasRerRecordIdCollision;
        },
        else => return err,
    };
}

fn writeCasRerRecordJsonToLedgerAlloc(
    allocator: std.mem.Allocator,
    record_json: []const u8,
) ![]const u8 {
    const record_id = try casRerRecordIdFromJsonAlloc(allocator, record_json);
    defer allocator.free(record_id);
    const records_dir = try reviewLedgerRecordsDirAlloc(allocator);
    defer allocator.free(records_dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ records_dir, record_id });
    errdefer allocator.free(path);
    try writeRawJsonFileExclusiveOrIdenticalAlloc(allocator, path, record_json);
    return path;
}

fn parseCasRerCreatedAtNs(text: []const u8) ?i128 {
    if (!std.mem.startsWith(u8, text, "unix-ns:")) return null;
    return std.fmt.parseInt(i128, text["unix-ns:".len..], 10) catch null;
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
    owner_lived: bool,
    io: std.Io,
) !cas_websocket.ManagedServer {
    return if (owner_lived)
        cas_websocket.startOwnerLivedLoopbackServer(
            allocator,
            cwd,
            codex_path,
            hook_policy,
            io,
        )
    else
        cas_websocket.startManagedLoopbackServer(
            allocator,
            cwd,
            codex_path,
            hook_policy,
            io,
        );
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
    request_deadline_ms: ?i64,
) !cas.Client {
    _ = codex_version;
    const websocket_connect_timeout_ms: u32 = if (request_deadline_ms) |deadline_ms| blk: {
        const remaining_ms = deadline_ms - monotonicMilliseconds();
        if (remaining_ms <= 0) return error.ConnectionTimedOut;
        break :blk @intCast(@min(remaining_ms, 10_000));
    } else 10_000;
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
        .websocket_connect_timeout_ms = websocket_connect_timeout_ms,
        .request_deadline_ms = request_deadline_ms,
    });
}

fn makeDisconnectedReviewStatus(allocator: std.mem.Allocator) !ReviewStatus {
    return .{
        .thread_status = try allocator.dupe(u8, "unknown"),
        .turn_status = try allocator.dupe(u8, "inProgress"),
        .turn_count = 0,
        .materialized = false,
        .thread_preview = try allocator.dupe(u8, ""),
        .rollout_path = null,
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = false,
        .last_turn_has_exited_review_mode = false,
        .review_result_available = false,
        .review_result_source = null,
        .review_result_json = null,
        .review_text = null,
        .raw_response_json = try allocator.dupe(u8, "{}"),
    };
}

fn emitHistoricalWaitTimeoutAndExit(
    allocator: std.mem.Allocator,
    parsed: ParsedArgs,
    record_path: []const u8,
    record: *SessionRecord,
    identity_opt: ?TargetIdentity,
    stored_tuple: ReviewTupleIdentity,
    codex_path: []const u8,
    codex_version: []const u8,
) !noreturn {
    var status = try makeDisconnectedReviewStatus(allocator);
    defer status.deinit(allocator);
    const failure = FailureInfo{
        .code = "wait_timed_out",
        .hint = "retry cas review wait on the same review thread or increase --timeout-ms",
    };
    if (!try transitionActiveReviewTupleLockForRecord(
        allocator,
        record.*,
        record_path,
        "waiting",
        failure.code,
    )) {
        try replayTerminalRecordAndExit(
            allocator,
            parsed.json,
            record.*,
            record_path,
            targetIdentityFromReviewTuple(stored_tuple),
        );
        return error.InvalidReviewTupleLockBinding;
    }
    record.last_observed_status = timeoutStatusString(&status);
    // Observer-local timeout diagnostics are not authoritative review state.
    // Persisting this stale copy could overwrite a terminal result committed
    // by another observer after the lock transition, so only the tuple lock
    // carries the nonterminal waiting diagnostic.
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
            record.target,
            identity_opt,
            waitOutputReceipt(record.*, stored_tuple, codex_path, codex_version),
            parsed.timeout_ms,
            true,
            failure,
        );
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        try stdout_writer.interface.print(
            "cas review wait timed out after {d}ms\nreview thread: {s}\n",
            .{ parsed.timeout_ms, record.review_thread_id },
        );
    }
    std.process.exit(1);
}

fn printRecordedReviewFailureJson(
    allocator: std.mem.Allocator,
    action: StatusAction,
    record: SessionRecord,
    record_path: []const u8,
    identity_opt: ?TargetIdentity,
    timeout_ms: ?u32,
    failure: FailureInfo,
) !void {
    var status = try makeDisconnectedReviewStatus(allocator);
    defer status.deinit(allocator);
    var receipt = withRecordMultiAgentMode(.{
        .resolved_codex_path = null,
        .resolved_codex_version = null,
        .compatibility_verdict = "not_checked",
        .selected_transport = record.transport_kind.?,
        .selection_reason = record.transport_selection_reason.?,
        .managed_server_pid = record.managed_server_pid,
        .managed_server_listen_url = record.managed_server_listen_url,
        .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
        .orphan_ttl_seconds = record.orphan_ttl_seconds,
    }, record);
    receipt.account_fingerprint = null;
    receipt.account_fingerprint_reduced_protection = true;
    receipt.codex_thread_id = null;
    try printStatusJson(
        allocator,
        action,
        record.cwd,
        record.parent_thread_id,
        record.review_thread_id,
        record.review_turn_id,
        status,
        record_path,
        record.event_log_path,
        record.target,
        identity_opt,
        receipt,
        timeout_ms,
        false,
        failure,
    );
}

fn persistTerminalReviewResult(record: *SessionRecord, status: ReviewStatus) void {
    if (!status.review_result_available) return;
    record.terminal_review_result_source = status.review_result_source;
    record.terminal_review_result_json = status.review_result_json;
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
    raw: []u8,
    parsed: std.json.Parsed(SessionRecord),
    record: SessionRecord,
    previous_store_root_override: ?[]const u8 = null,
    rebound_store_root_override: ?[]const u8 = null,

    fn deinit(self: *LoadedSessionRecord, allocator: std.mem.Allocator) void {
        configured_store_root_override = self.previous_store_root_override;
        if (self.rebound_store_root_override) |root| allocator.free(root);
        self.parsed.deinit();
        allocator.free(self.raw);
        allocator.free(self.record_path);
    }
};

fn loadSessionRecord(allocator: std.mem.Allocator, review_thread_id: []const u8) !LoadedSessionRecord {
    const session_dir = try sessionDirAlloc(allocator);
    defer allocator.free(session_dir);
    const record_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, review_thread_id });
    return loadOwnedSessionRecordPath(allocator, record_path);
}

fn loadSelectedSessionRecord(allocator: std.mem.Allocator, parsed: ParsedArgs) !LoadedSessionRecord {
    if (parsed.receipt_paths.len == 1) {
        const record_path = try absoluteInputPathAlloc(allocator, parsed.receipt_paths[0]);
        return loadOwnedSessionRecordPath(allocator, record_path) catch |err| {
            return err;
        };
    }
    if (parsed.latest_review_session) {
        const record_path = try latestSessionRecordPathAlloc(allocator);
        return loadOwnedSessionRecordPath(allocator, record_path) catch |err| {
            return err;
        };
    }
    return loadSessionRecord(allocator, parsed.review_thread_id.?);
}

fn absoluteInputPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const expanded = try core_path.expandHomePath(allocator, path);
    errdefer allocator.free(expanded);
    if (std.fs.path.isAbsolute(expanded)) return expanded;
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    const absolute = try std.fs.path.join(allocator, &.{ cwd, expanded });
    allocator.free(expanded);
    return absolute;
}

fn loadOwnedSessionRecordPath(allocator: std.mem.Allocator, record_path: []const u8) !LoadedSessionRecord {
    errdefer allocator.free(record_path);
    const raw = try durable_store.readRegularFileNoSymlink(allocator, record_path, 1024 * 1024);
    errdefer allocator.free(raw);
    const parsed = try std.json.parseFromSlice(SessionRecord, allocator, raw, .{});
    errdefer parsed.deinit();
    if (parsed.value.schema_version != 4) return error.InvalidSessionRecord;
    _ = try targetConfigFromRecord(parsed.value.target);
    if (parsed.value.developer_instructions) |instructions| {
        if (!workflowBindingStringValid(instructions)) return error.InvalidSessionRecord;
    }
    if (parsed.value.workflowBinding) |binding| try validateWorkflowBinding(binding);
    try validateCurrentSessionRecordAlloc(allocator, record_path, parsed.value);
    const previous_store_root_override = configured_store_root_override;
    var rebound_store_root_override: ?[]const u8 = null;
    if (parsed.value.store_root) |store_root| {
        rebound_store_root_override = try allocator.dupe(u8, store_root);
        configured_store_root_override = rebound_store_root_override;
    }
    return .{
        .record_path = record_path,
        .raw = raw,
        .parsed = parsed,
        .record = parsed.value,
        .previous_store_root_override = previous_store_root_override,
        .rebound_store_root_override = rebound_store_root_override,
    };
}

fn validateCurrentSessionRecordAlloc(
    allocator: std.mem.Allocator,
    record_path: []const u8,
    record: SessionRecord,
) !void {
    const store_root = nonEmptyOptional(record.store_root) orelse
        return error.InvalidSessionRecord;
    const repo_root = nonEmptyOptional(record.repo_root) orelse
        return error.InvalidSessionRecord;
    const codex_thread_id = nonEmptyOptional(record.codex_thread_id) orelse
        return error.InvalidSessionRecord;
    const resolved_codex_path = nonEmptyOptional(record.resolved_codex_path) orelse
        return error.InvalidSessionRecord;
    const transport_kind = nonEmptyOptional(record.transport_kind) orelse
        return error.InvalidSessionRecord;
    const transport_reason = nonEmptyOptional(record.transport_selection_reason) orelse
        return error.InvalidSessionRecord;
    const terminal_failure_fields_present = record.terminal_failure_code != null or
        record.terminal_failure_hint != null or record.terminal_failure_at_unix_s != null;
    if (terminal_failure_fields_present) {
        const code = nonEmptyOptional(record.terminal_failure_code) orelse
            return error.InvalidSessionRecord;
        const hint = nonEmptyOptional(record.terminal_failure_hint) orelse
            return error.InvalidSessionRecord;
        const terminalized_at = record.terminal_failure_at_unix_s orelse
            return error.InvalidSessionRecord;
        _ = terminalReviewOwnerFailure(code) orelse
            return error.InvalidSessionRecord;
        // The stable failure code is semantic identity. Hint text is durable
        // diagnostic copy and may differ across compatible releases.
        if (hint.len == 0 or terminalized_at <= 0) {
            return error.InvalidSessionRecord;
        }
    }
    _ = codex_thread_id;
    _ = resolved_codex_path;

    if (record.schema_version != 4 or
        !std.fs.path.isAbsolute(store_root) or
        !std.fs.path.isAbsolute(repo_root) or
        !std.fs.path.isAbsolute(record.cwd) or
        !std.mem.eql(u8, record.store_scope orelse "", "repo-local") or
        !std.mem.eql(u8, record.cwd, repo_root) or
        !std.mem.eql(u8, record.delivery, "detached") or
        !std.mem.eql(u8, transport_kind, "websocket") or
        !std.mem.eql(
            u8,
            transport_reason,
            "detached_review_requires_cross_process_truth",
        ) or
        nonEmptyOptional(record.parent_thread_id) == null or
        nonEmptyOptional(record.review_thread_id) == null or
        nonEmptyOptional(record.review_turn_id) == null or
        nonEmptyOptional(record.event_log_path) == null or
        nonEmptyOptional(record.codex_version) == null or
        nonEmptyOptional(record.compatibility_verdict) == null or
        nonEmptyOptional(record.base_sha) == null or
        nonEmptyOptional(record.head_sha) == null or
        nonEmptyOptional(record.target_fingerprint) == null or
        nonEmptyOptional(record.accountFingerprint) == null or
        nonEmptyOptional(record.managed_server_listen_url) == null or
        record.managed_server_pid == null or
        record.managed_server_pid.? == 0 or
        record.orphan_ttl_seconds == null or
        record.orphan_ttl_seconds.? == 0)
    {
        return error.InvalidSessionRecord;
    }

    const session_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/review_sessions",
        .{store_root},
    );
    defer allocator.free(session_dir);
    const expected_record_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.json",
        .{ session_dir, record.review_thread_id },
    );
    defer allocator.free(expected_record_path);
    const expected_event_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.events.ndjson",
        .{ session_dir, record.review_thread_id },
    );
    defer allocator.free(expected_event_path);
    if (!std.mem.eql(u8, record_path, expected_record_path) or
        !std.mem.eql(u8, record.event_log_path, expected_event_path))
    {
        return error.InvalidSessionRecord;
    }
}

fn latestSessionRecordPathAlloc(allocator: std.mem.Allocator) ![]const u8 {
    const session_dir = try sessionDirAlloc(allocator);
    defer allocator.free(session_dir);
    return latestSessionRecordPathInDirAlloc(allocator, session_dir);
}

fn latestSessionRecordPathInDirAlloc(allocator: std.mem.Allocator, session_dir: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), session_dir, .{ .iterate = true });
    defer dir.close(std.Io.Threaded.global_single_threaded.io());

    var best_name: ?[]u8 = null;
    errdefer if (best_name) |name| allocator.free(name);
    var best_mtime: ?std.Io.Timestamp = null;
    var it = dir.iterate();
    while (try it.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (!isReviewSessionRecordName(entry.name, entry.kind)) continue;
        const stat = dir.statFile(std.Io.Threaded.global_single_threaded.io(), entry.name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file) continue;
        const replace = if (best_mtime) |mtime|
            stat.mtime.nanoseconds > mtime.nanoseconds or
                (stat.mtime.nanoseconds == mtime.nanoseconds and std.mem.order(u8, entry.name, best_name.?) == .gt)
        else
            true;
        if (!replace) continue;
        if (best_name) |name| allocator.free(name);
        best_name = try allocator.dupe(u8, entry.name);
        best_mtime = stat.mtime;
    }

    const name = best_name orelse return error.NoReviewSessionRecords;
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ session_dir, name });
}

fn isReviewSessionRecordName(name: []const u8, kind: std.Io.File.Kind) bool {
    if (kind != .file) return false;
    if (!std.mem.endsWith(u8, name, ".json")) return false;
    return true;
}

fn writeSessionRecord(allocator: std.mem.Allocator, path: []const u8, record: SessionRecord) !void {
    const json = try stringifyAnyAlloc(allocator, record);
    defer allocator.free(json);
    const payload = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    defer allocator.free(payload);
    try durable_store.writeTextAtomic(allocator, path, payload);
}

fn currentProcessId() u64 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .plan9 => @intCast(std.os.plan9.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

fn sha256HexAlloc(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
}

fn sha256HexBareAlloc(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const prefixed = try sha256HexAlloc(allocator, data);
    defer allocator.free(prefixed);
    return allocator.dupe(u8, prefixed["sha256:".len..]);
}

fn repoRealpathAlloc(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const realpath = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        cwd,
        allocator,
    );
    defer allocator.free(realpath);
    return durable_store.findGitRootAlloc(allocator, realpath);
}

fn repoRootForCwdAlloc(allocator: std.mem.Allocator, cwd: []const u8) !?[]const u8 {
    const repo_root = durable_store.findGitRootAlloc(allocator, cwd) catch |err| switch (err) {
        error.GitCommandFailed => return null,
        else => return err,
    };
    return repo_root;
}

fn hashedAccountFingerprintAlloc(allocator: std.mem.Allocator, tag: []const u8, value: []const u8) ![]const u8 {
    const tagged = try std.fmt.allocPrint(allocator, "account.{s}:{s}", .{ tag, value });
    defer allocator.free(tagged);
    const digest = try sha256HexBareAlloc(allocator, tagged);
    defer allocator.free(digest);
    return std.fmt.allocPrint(allocator, "acct:{s}", .{digest});
}

fn accountPrincipalFromJsonAlloc(allocator: std.mem.Allocator, account_json: []const u8) !AccountPrincipalEvidence {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, account_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return .{
            .fingerprint = try allocator.dupe(u8, unknown_account_fingerprint),
            .reduced_protection = true,
        },
    };

    var account_obj_opt: ?std.json.ObjectMap = null;
    if (root.get("account")) |account_value| {
        if (account_value == .object) account_obj_opt = account_value.object;
    }

    const candidates = [_][]const u8{ "id", "accountId", "userId", "email" };
    if (account_obj_opt) |account_obj| {
        for (candidates) |field| {
            if (jsonStringField(account_obj, field)) |value| {
                if (value.len == 0) continue;
                return .{
                    .fingerprint = try hashedAccountFingerprintAlloc(allocator, field, value),
                    .reduced_protection = false,
                };
            }
        }
        if (jsonStringField(account_obj, "type")) |account_type| {
            if (jsonStringField(account_obj, "planType")) |plan_type| {
                const combined = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ account_type, plan_type });
                defer allocator.free(combined);
                return .{
                    .fingerprint = try hashedAccountFingerprintAlloc(allocator, "type-plan", combined),
                    .reduced_protection = true,
                };
            }
        }
    }
    return .{
        .fingerprint = try allocator.dupe(u8, unknown_account_fingerprint),
        .reduced_protection = true,
    };
}

fn accountFingerprintFromJsonAlloc(allocator: std.mem.Allocator, account_json: []const u8) ![]const u8 {
    const principal = try accountPrincipalFromJsonAlloc(allocator, account_json);
    return principal.fingerprint;
}

fn readAccountPrincipalAlloc(allocator: std.mem.Allocator, client: *cas.Client) !AccountPrincipalEvidence {
    const account_json = client.requestJson("account/read", "{\"refreshToken\":false}") catch {
        return .{
            .fingerprint = try allocator.dupe(u8, unknown_account_fingerprint),
            .reduced_protection = true,
        };
    };
    defer allocator.free(account_json);
    return accountPrincipalFromJsonAlloc(allocator, account_json) catch .{
        .fingerprint = try allocator.dupe(u8, unknown_account_fingerprint),
        .reduced_protection = true,
    };
}

fn reviewTupleIdentityAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    target_identity: TargetIdentity,
    resolved_codex_path: []const u8,
    resolved_codex_version: []const u8,
    client: *cas.Client,
    workflow_binding: ?WorkflowBinding,
) !ReviewTupleIdentity {
    const repo_realpath = try repoRealpathAlloc(allocator, cwd);
    errdefer allocator.free(repo_realpath);
    const account_principal = try readAccountPrincipalAlloc(allocator, client);
    errdefer allocator.free(account_principal.fingerprint);
    const codex_thread_id = try currentCodexThreadIdAlloc(allocator);
    errdefer allocator.free(codex_thread_id);
    const workflow_binding_digest = if (workflow_binding) |binding| blk: {
        const canonical = try stringifyAnyAlloc(allocator, binding);
        defer allocator.free(canonical);
        break :blk try sha256HexAlloc(allocator, canonical);
    } else null;
    return .{
        .repo_realpath = repo_realpath,
        .base_sha = target_identity.base_sha,
        .head_sha = target_identity.head_sha,
        .target_fingerprint = target_identity.fingerprint,
        .resolved_codex_path = resolved_codex_path,
        .resolved_codex_version = resolved_codex_version,
        .account_fingerprint = account_principal.fingerprint,
        .account_fingerprint_reduced_protection = account_principal.reduced_protection,
        .codex_thread_id = codex_thread_id,
        .workflow_binding = workflow_binding,
        .workflow_binding_digest = workflow_binding_digest,
    };
}

fn currentCodexThreadIdAlloc(allocator: std.mem.Allocator) ![]const u8 {
    if (configured_codex_thread_id) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, "reduced-unspecified");
}

fn canonicalReviewTuplePayloadAlloc(allocator: std.mem.Allocator, tuple: ReviewTupleIdentity) ![]const u8 {
    const base_payload = try std.fmt.allocPrint(
        allocator,
        "repo_realpath={s}\nbase_sha={s}\nhead_sha={s}\ntarget_fingerprint={s}\n" ++
            "resolved_codex_path={s}\nresolved_codex_version={s}\n" ++
            "account_fingerprint={s}\naccount_fingerprint_reduced_protection={}\n" ++
            "codex_thread_id={s}\n",
        .{
            tuple.repo_realpath,
            tuple.base_sha orelse "",
            tuple.head_sha orelse "",
            tuple.target_fingerprint,
            tuple.resolved_codex_path,
            tuple.resolved_codex_version,
            tuple.account_fingerprint,
            tuple.account_fingerprint_reduced_protection,
            tuple.codex_thread_id,
        },
    );
    const workflow_binding_digest = tuple.workflow_binding_digest orelse return base_payload;
    defer allocator.free(base_payload);
    return std.fmt.allocPrint(
        allocator,
        "{s}workflow_binding_digest={s}\n",
        .{ base_payload, workflow_binding_digest },
    );
}

fn reviewTupleHashAlloc(allocator: std.mem.Allocator, tuple: ReviewTupleIdentity) ![]const u8 {
    const canonical = try canonicalReviewTuplePayloadAlloc(allocator, tuple);
    defer allocator.free(canonical);
    return sha256HexAlloc(allocator, canonical);
}

fn storedReviewTupleIdentityAlloc(
    allocator: std.mem.Allocator,
    record: SessionRecord,
) !ReviewTupleIdentity {
    const repo_root = nonEmptyOptional(record.repo_root) orelse
        return error.InvalidSessionRecord;
    const target_fingerprint = nonEmptyOptional(record.target_fingerprint) orelse
        return error.InvalidSessionRecord;
    const resolved_codex_path = nonEmptyOptional(record.resolved_codex_path) orelse
        return error.InvalidSessionRecord;
    const account_fingerprint = nonEmptyOptional(record.accountFingerprint) orelse
        return error.InvalidSessionRecord;
    const codex_thread_id = nonEmptyOptional(record.codex_thread_id) orelse
        return error.InvalidSessionRecord;
    if (nonEmptyOptional(record.base_sha) == null or
        nonEmptyOptional(record.head_sha) == null or
        nonEmptyOptional(record.codex_version) == null)
    {
        return error.InvalidSessionRecord;
    }

    const repo_realpath = try allocator.dupe(u8, repo_root);
    errdefer allocator.free(repo_realpath);
    const account_copy = try allocator.dupe(u8, account_fingerprint);
    errdefer allocator.free(account_copy);
    const codex_thread_copy = try allocator.dupe(u8, codex_thread_id);
    errdefer allocator.free(codex_thread_copy);
    const workflow_binding_digest = if (record.workflowBinding) |binding| blk: {
        const canonical = try stringifyAnyAlloc(allocator, binding);
        defer allocator.free(canonical);
        break :blk try sha256HexAlloc(allocator, canonical);
    } else null;
    return .{
        .repo_realpath = repo_realpath,
        .base_sha = record.base_sha,
        .head_sha = record.head_sha,
        .target_fingerprint = target_fingerprint,
        .resolved_codex_path = resolved_codex_path,
        .resolved_codex_version = record.codex_version,
        .account_fingerprint = account_copy,
        .account_fingerprint_reduced_protection = record.accountFingerprintReducedProtection,
        .codex_thread_id = codex_thread_copy,
        .workflow_binding = record.workflowBinding,
        .workflow_binding_digest = workflow_binding_digest,
    };
}

fn storedReviewTupleLockPathAlloc(
    allocator: std.mem.Allocator,
    record: SessionRecord,
) ![]const u8 {
    var tuple = try storedReviewTupleIdentityAlloc(allocator, record);
    defer tuple.deinit(allocator);
    const tuple_hash = try reviewTupleHashAlloc(allocator, tuple);
    defer allocator.free(tuple_hash);
    return reviewTupleLockPathAlloc(allocator, tuple_hash);
}

fn reviewTupleLockMatchesRecord(
    lock: ReviewTupleLock,
    record: SessionRecord,
    record_path: []const u8,
) bool {
    return std.mem.eql(u8, lock.reviewThreadId orelse "", record.review_thread_id) and
        std.mem.eql(u8, lock.reviewTurnId orelse "", record.review_turn_id) and
        std.mem.eql(u8, lock.recordPath orelse "", record_path) and
        std.mem.eql(u8, lock.eventLogPath orelse "", record.event_log_path);
}

fn loadExactReviewTupleLockForRecord(
    allocator: std.mem.Allocator,
    record: SessionRecord,
    record_path: []const u8,
) !LoadedReviewTupleLock {
    const lock_path = try storedReviewTupleLockPathAlloc(allocator, record);
    defer allocator.free(lock_path);
    var loaded = (try loadReviewTupleLock(allocator, lock_path)) orelse
        return error.MissingReviewTupleLock;
    errdefer loaded.deinit(allocator);
    if (!reviewTupleLockMatchesRecord(loaded.record, record, record_path)) {
        return error.InvalidReviewTupleLockBinding;
    }
    return loaded;
}

fn recordHasTerminalFailureReplayCandidate(
    allocator: std.mem.Allocator,
    record: SessionRecord,
    record_path: []const u8,
) !bool {
    var loaded = try loadExactReviewTupleLockForRecord(
        allocator,
        record,
        record_path,
    );
    defer loaded.deinit(allocator);
    const terminal = std.mem.eql(u8, loaded.record.state, "terminal") or
        std.mem.eql(u8, loaded.record.state, "account_resource_exhausted");
    if (!terminal) return false;
    const lock_code = loaded.record.lastFailureCode orelse
        return error.InvalidReviewTupleLockBinding;
    if (record.terminal_failure_code) |record_code| {
        if (!std.mem.eql(u8, record_code, lock_code)) {
            return error.InvalidReviewTupleLockBinding;
        }
    }
    return true;
}

fn recordIsNormalizedVerdictReplayCandidate(
    allocator: std.mem.Allocator,
    record: SessionRecord,
    record_path: []const u8,
) !bool {
    var loaded = try loadExactReviewTupleLockForRecord(
        allocator,
        record,
        record_path,
    );
    defer loaded.deinit(allocator);
    return std.mem.eql(u8, loaded.record.state, "normalized");
}

fn recordTerminalOwnerFailure(
    allocator: std.mem.Allocator,
    record: SessionRecord,
    record_path: []const u8,
) !?FailureInfo {
    var loaded = try loadExactReviewTupleLockForRecord(
        allocator,
        record,
        record_path,
    );
    defer loaded.deinit(allocator);
    if (!std.mem.eql(u8, loaded.record.state, "terminal")) return null;
    const lock_code = loaded.record.lastFailureCode orelse return null;
    if (record.terminal_failure_code) |record_code| {
        if (!std.mem.eql(u8, record_code, lock_code)) {
            return error.InvalidReviewTupleLockBinding;
        }
    }
    return terminalReviewOwnerFailure(lock_code);
}

fn replayTerminalRecordAndExit(
    allocator: std.mem.Allocator,
    json_mode: bool,
    record: SessionRecord,
    record_path: []const u8,
    identity: TargetIdentity,
) !void {
    var loaded = try loadExactReviewTupleLockForRecord(
        allocator,
        record,
        record_path,
    );
    defer loaded.deinit(allocator);
    if (std.mem.eql(u8, loaded.record.state, "normalized")) {
        const normalized = try normalizeReceiptFromPathAlloc(
            allocator,
            record_path,
            true,
            .{
                .requested_identity = identity,
                .requested_identity_required = true,
            },
        );
        defer normalized.deinit(allocator);
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        if (json_mode) {
            try writeReceiptObject(stdout, normalized);
            try stdout.writeAll("\n");
        } else {
            try stdout.print(
                "cas review wait\nreview thread: {s}\nstatus: {s}\nfindings: {d}\nrecord: {s}\n",
                .{ record.review_thread_id, normalized.status, normalized.finding_count, record_path },
            );
        }
        // A completed review is a successful wait operation even when its
        // semantic verdict contains findings. Review credit is adjudicated by
        // the caller; replay must preserve the live wait command's exit law.
        std.process.exit(0);
    }

    const terminal = std.mem.eql(u8, loaded.record.state, "terminal") or
        std.mem.eql(u8, loaded.record.state, "account_resource_exhausted");
    if (!terminal) return;
    const code = loaded.record.lastFailureCode orelse
        record.terminal_failure_code orelse "review_failed";
    if (record.terminal_failure_code) |record_code| {
        if (loaded.record.lastFailureCode) |lock_code| {
            if (!std.mem.eql(u8, record_code, lock_code)) {
                return error.InvalidReviewTupleLockBinding;
            }
        }
    }
    const failure = terminalReviewOwnerFailure(code) orelse FailureInfo{
        .code = code,
        .hint = record.terminal_failure_hint orelse
            "the durable review owner recorded a terminal failure; inspect the persisted receipt before starting a replacement",
    };
    if (json_mode) {
        try printRecordedReviewFailureJson(
            allocator,
            .wait,
            record,
            record_path,
            identity,
            null,
            failure,
        );
    } else {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        try stderr_writer.interface.print(
            "cas review wait: {s} ({s})\nrecord: {s}\n",
            .{ failure.hint, failure.code, record_path },
        );
    }
    std.process.exit(1);
}

const WorkflowBoundRecordOwnerState = enum {
    not_applicable,
    live,
    dead,
};

fn workflowBoundRecordOwnerState(
    allocator: std.mem.Allocator,
    record: SessionRecord,
    record_path: []const u8,
    retained_owner_lease: *?ReviewOwnerLease,
) !WorkflowBoundRecordOwnerState {
    if (record.workflowBinding == null) return .not_applicable;
    var loaded = try loadExactReviewTupleLockForRecord(
        allocator,
        record,
        record_path,
    );
    defer loaded.deinit(allocator);
    const active = std.mem.eql(u8, loaded.record.state, "starting_review") or
        std.mem.eql(u8, loaded.record.state, "review_started") or
        std.mem.eql(u8, loaded.record.state, "waiting");
    if (!active) return .not_applicable;
    // Pre-CAS-ROL records retain their historical PID/server wait semantics.
    // Only a versioned file lease is recovery authority for new owner-lived
    // records; a numeric PID can be recycled and is not an identity proof.
    if (!std.mem.eql(u8, loaded.record.lockVersion, review_tuple_lock_version) or
        !std.mem.eql(
            u8,
            loaded.record.ownerLeaseVersion orelse "",
            review_owner_lease_version,
        )) return .not_applicable;
    var lease = (try tryAcquireReviewOwnerLeaseAlloc(allocator, loaded.path)) orelse
        return .live;
    errdefer lease.deinit(allocator);
    var rechecked = try loadExactReviewTupleLockForRecord(
        allocator,
        record,
        record_path,
    );
    defer rechecked.deinit(allocator);
    const rechecked_active = std.mem.eql(u8, rechecked.record.state, "starting_review") or
        std.mem.eql(u8, rechecked.record.state, "review_started") or
        std.mem.eql(u8, rechecked.record.state, "waiting");
    if (!rechecked_active) {
        lease.deinit(allocator);
        return .not_applicable;
    }
    retained_owner_lease.* = lease;
    return .dead;
}

fn workflowBoundRecordHasLiveOwner(
    allocator: std.mem.Allocator,
    record: SessionRecord,
    record_path: []const u8,
) !bool {
    var retained_owner_lease: ?ReviewOwnerLease = null;
    defer if (retained_owner_lease) |*lease| lease.deinit(allocator);
    return try workflowBoundRecordOwnerState(
        allocator,
        record,
        record_path,
        &retained_owner_lease,
    ) == .live;
}

fn terminalizeDeadWorkflowBoundOwner(
    allocator: std.mem.Allocator,
    record_path: []const u8,
    record: *SessionRecord,
    failure: FailureInfo,
) !void {
    // The owner lease is the durable identity. A persisted numeric PID is
    // diagnostic only and may already name an unrelated process. Owner-pipe
    // EOF independently directs the watchdog to retire its exact child.

    var loaded = try loadExactReviewTupleLockForRecord(
        allocator,
        record.*,
        record_path,
    );
    defer loaded.deinit(allocator);

    const durable_failure = terminalReviewOwnerFailure(failure.code) orelse failure;
    record.last_observed_status = "disconnected";
    record.terminal_failure_code = durable_failure.code;
    record.terminal_failure_hint = durable_failure.hint;
    record.terminal_failure_at_unix_s = unixSeconds();
    try writeSessionRecord(allocator, record_path, record.*);

    const terminal_lock = withReviewTupleLockState(
        loaded.record,
        "terminal",
        unixSeconds(),
        failure.code,
        record.review_thread_id,
        record.review_turn_id,
        record_path,
        record.event_log_path,
    );
    try writeReviewTupleLock(allocator, loaded.path, terminal_lock);
}

fn persistDeadOwnerRecoveryEvidence(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    lock: ReviewTupleLock,
    target_identity: TargetIdentity,
) !?[]const u8 {
    const record_path = lock.recordPath orelse {
        const failure = workflowDeadOwnerFailureInfo(lock);
        const terminal_state = if (workflowDeadOwnerAttemptExists(lock))
            "terminal"
        else
            "pre_review_start_failed";
        const terminal = withReviewTupleLockState(
            lock,
            terminal_state,
            unixSeconds(),
            failure.code,
            lock.reviewThreadId,
            lock.reviewTurnId,
            null,
            lock.eventLogPath,
        );
        const terminal_json = try stringifyAnyAlloc(allocator, terminal);
        defer allocator.free(terminal_json);
        const terminal_digest = try sha256HexAlloc(allocator, terminal_json);
        defer allocator.free(terminal_digest);
        const predecessor_path = try std.fmt.allocPrint(
            allocator,
            "{s}.predecessor-{s}",
            .{ lock_path, terminal_digest["sha256:".len..] },
        );
        errdefer allocator.free(predecessor_path);
        writeReviewTupleLockExclusive(
            allocator,
            predecessor_path,
            terminal,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                var existing = (try loadReviewTupleLockArtifact(
                    allocator,
                    predecessor_path,
                    false,
                )) orelse return error.InvalidReviewTupleLockBinding;
                defer existing.deinit(allocator);
                if (!std.mem.eql(u8, existing.record.tupleHash, terminal.tupleHash) or
                    existing.record.ownerPid != terminal.ownerPid or
                    existing.record.createdAtUnixS != terminal.createdAtUnixS or
                    !std.mem.eql(u8, existing.record.state, terminal.state) or
                    !std.mem.eql(
                        u8,
                        existing.record.lastFailureCode orelse "",
                        terminal.lastFailureCode orelse "",
                    )) return error.InvalidReviewTupleLockBinding;
            },
            else => return err,
        };
        try writeReviewTupleLock(allocator, lock_path, terminal);
        return predecessor_path;
    };
    var loaded_record = try loadOwnedSessionRecordPath(
        allocator,
        try allocator.dupe(u8, record_path),
    );
    defer loaded_record.deinit(allocator);
    const failure = terminalReviewTransportFailure("review_transport_lost").?;
    try terminalizeDeadWorkflowBoundOwner(
        allocator,
        record_path,
        &loaded_record.record,
        failure,
    );

    const normalized = try normalizeReceiptFromPathAlloc(
        allocator,
        record_path,
        true,
        .{
            .requested_identity = target_identity,
            .requested_identity_required = true,
        },
    );
    defer normalized.deinit(allocator);
    const timestamp = try casRerTimestampAlloc(allocator);
    defer allocator.free(timestamp);
    return try writeCasRerShadowRecordFromReceipt(allocator, normalized, .{
        .command_surface = "start_wait",
        .backend_selected = "cas-start-wait",
        .broker_action = "recover_dead_owner",
        .broker_reason = "predecessor terminal evidence persisted before fresh recovery",
        .timestamp = timestamp,
    });
}

fn targetIdentityFromReviewTuple(tuple: ReviewTupleIdentity) TargetIdentity {
    return .{
        .head_sha = tuple.head_sha,
        .base_sha = tuple.base_sha,
        .fingerprint = tuple.target_fingerprint,
    };
}

fn normalizeContextFromReviewTuple(tuple: ReviewTupleIdentity) NormalizeContext {
    return .{
        .requested_identity = targetIdentityFromReviewTuple(tuple),
        .requested_identity_required = true,
    };
}

fn reviewTupleLocksDirAlloc(allocator: std.mem.Allocator) ![]const u8 {
    const session_dir = try sessionDirAlloc(allocator);
    defer allocator.free(session_dir);
    const locks_dir = try std.fmt.allocPrint(allocator, "{s}/locks", .{session_dir});
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), locks_dir);
    return locks_dir;
}

fn reviewTupleLockPathAlloc(allocator: std.mem.Allocator, tuple_hash: []const u8) ![]const u8 {
    const locks_dir = try reviewTupleLocksDirAlloc(allocator);
    defer allocator.free(locks_dir);
    const bare_hash = if (std.mem.startsWith(u8, tuple_hash, "sha256:")) tuple_hash["sha256:".len..] else tuple_hash;
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ locks_dir, bare_hash });
}

fn reviewTupleLockRewriteLeasePathAlloc(allocator: std.mem.Allocator, lock_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.rewrite-lease", .{lock_path});
}

fn reviewOwnerLeasePathAlloc(allocator: std.mem.Allocator, lock_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.owner-lease", .{lock_path});
}

const ReviewOwnerLease = struct {
    file: std.Io.File,
    path: []const u8,

    fn deinit(self: *ReviewOwnerLease, allocator: std.mem.Allocator) void {
        self.file.close(std.Io.Threaded.global_single_threaded.io());
        allocator.free(self.path);
    }
};

const ReviewTupleRewriteLease = struct {
    file: std.Io.File,
    path: []const u8,

    fn deinit(self: *ReviewTupleRewriteLease, allocator: std.mem.Allocator) void {
        self.file.close(std.Io.Threaded.global_single_threaded.io());
        allocator.free(self.path);
    }
};

fn tryAcquireReviewOwnerLeaseAlloc(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
) !?ReviewOwnerLease {
    const lease_path = try reviewOwnerLeasePathAlloc(allocator, lock_path);
    errdefer allocator.free(lease_path);
    try ensureParentPath(lease_path);
    const io = std.Io.Threaded.global_single_threaded.io();
    while (true) {
        const file = std.Io.Dir.openFileAbsolute(io, lease_path, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .follow_symlinks = false,
        }) catch |open_err| switch (open_err) {
            error.FileNotFound => std.Io.Dir.createFileAbsolute(io, lease_path, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => continue,
                error.WouldBlock => {
                    allocator.free(lease_path);
                    return null;
                },
                else => return create_err,
            },
            error.WouldBlock => {
                allocator.free(lease_path);
                return null;
            },
            else => return open_err,
        };
        return .{ .file = file, .path = lease_path };
    }
}

fn reviewTupleLockWorkflowBindingValidAlloc(allocator: std.mem.Allocator, lock: ReviewTupleLock) !bool {
    const codex_thread_id = lock.codexThreadId orelse return false;
    const current_lock = std.mem.eql(u8, lock.lockVersion, review_tuple_lock_version);
    const legacy_lock = std.mem.eql(u8, lock.lockVersion, legacy_review_tuple_lock_version);
    if ((!current_lock and !legacy_lock) or
        lock.tupleHash.len == 0 or
        lock.repoRealpath.len == 0 or
        nonEmptyOptional(lock.baseSha) == null or
        nonEmptyOptional(lock.headSha) == null or
        lock.targetFingerprint.len == 0 or
        lock.resolvedCodexPath.len == 0 or
        lock.resolvedCodexVersion.len == 0 or
        lock.accountFingerprint.len == 0 or
        codex_thread_id.len == 0)
    {
        return false;
    }
    if (current_lock) {
        if (lock.workflowBinding != null and
            !std.mem.eql(
                u8,
                lock.ownerLeaseVersion orelse "",
                review_owner_lease_version,
            )) return false;
    } else if (lock.ownerLeaseVersion != null) {
        // CAS-RTL-v1 predates owner-lease authority. A lease-bearing lock must
        // use CAS-RTL-v2 so older readers reject it instead of ignoring the
        // authority-bearing field.
        return false;
    }
    const workflow_binding_digest = if (lock.workflowBinding) |binding| blk: {
        try validateWorkflowBinding(binding);
        const canonical = try stringifyAnyAlloc(allocator, binding);
        defer allocator.free(canonical);
        break :blk try sha256HexAlloc(allocator, canonical);
    } else null;
    defer if (workflow_binding_digest) |digest| allocator.free(digest);
    const expected_tuple_hash = try reviewTupleHashAlloc(allocator, .{
        .repo_realpath = lock.repoRealpath,
        .base_sha = lock.baseSha,
        .head_sha = lock.headSha,
        .target_fingerprint = lock.targetFingerprint,
        .resolved_codex_path = lock.resolvedCodexPath,
        .resolved_codex_version = lock.resolvedCodexVersion,
        .account_fingerprint = lock.accountFingerprint,
        .account_fingerprint_reduced_protection = lock.accountFingerprintReducedProtection,
        .codex_thread_id = codex_thread_id,
        .workflow_binding = lock.workflowBinding,
        .workflow_binding_digest = workflow_binding_digest,
    });
    defer allocator.free(expected_tuple_hash);
    return std.mem.eql(u8, lock.tupleHash, expected_tuple_hash);
}

fn reviewTupleLockPathMatchesHash(path: []const u8, tuple_hash: []const u8) bool {
    const basename = std.fs.path.basename(path);
    const bare_hash = if (std.mem.startsWith(u8, tuple_hash, "sha256:"))
        tuple_hash["sha256:".len..]
    else
        tuple_hash;
    if (!std.mem.endsWith(u8, basename, ".json")) return false;
    return std.mem.eql(u8, basename[0 .. basename.len - ".json".len], bare_hash);
}

fn loadReviewTupleLockArtifact(
    allocator: std.mem.Allocator,
    path: []const u8,
    require_canonical_path: bool,
) !?LoadedReviewTupleLock {
    const raw = durable_store.readRegularFileNoSymlink(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer allocator.free(raw);
    const parsed = try std.json.parseFromSlice(ReviewTupleLock, allocator, raw, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (!try reviewTupleLockWorkflowBindingValidAlloc(allocator, parsed.value) or
        (require_canonical_path and
            !reviewTupleLockPathMatchesHash(path, parsed.value.tupleHash)))
    {
        return error.InvalidReviewTupleLockBinding;
    }
    return .{
        .path = try allocator.dupe(u8, path),
        .raw = raw,
        .parsed = parsed,
        .record = parsed.value,
    };
}

fn loadReviewTupleLock(allocator: std.mem.Allocator, path: []const u8) !?LoadedReviewTupleLock {
    return loadReviewTupleLockArtifact(allocator, path, true);
}

fn makeReviewTupleLock(
    tuple_hash: []const u8,
    tuple: ReviewTupleIdentity,
    state: []const u8,
    now_s: i64,
    override_reason: ?[]const u8,
    fresh_attempt_reason: ?[]const u8,
) ReviewTupleLock {
    return .{
        .tupleHash = tuple_hash,
        .repoRealpath = tuple.repo_realpath,
        .baseSha = tuple.base_sha,
        .headSha = tuple.head_sha,
        .targetFingerprint = tuple.target_fingerprint,
        .resolvedCodexPath = tuple.resolved_codex_path,
        .resolvedCodexVersion = tuple.resolved_codex_version,
        .accountFingerprint = tuple.account_fingerprint,
        .accountFingerprintReducedProtection = tuple.account_fingerprint_reduced_protection,
        .codexThreadId = tuple.codex_thread_id,
        .workflowBinding = tuple.workflow_binding,
        .ownerLeaseVersion = if (tuple.workflow_binding != null)
            review_owner_lease_version
        else
            null,
        .state = state,
        .createdAtUnixS = now_s,
        .updatedAtUnixS = now_s,
        .expiresAtUnixS = now_s + review_tuple_lock_ttl_seconds,
        .ownerPid = currentProcessId(),
        .overrideReason = override_reason,
        .freshAttemptReason = fresh_attempt_reason,
    };
}

fn withReviewTupleLockState(
    current: ReviewTupleLock,
    state: []const u8,
    now_s: i64,
    failure_code: ?[]const u8,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: ?[]const u8,
    event_log_path: ?[]const u8,
) ReviewTupleLock {
    var next = current;
    next.state = state;
    next.updatedAtUnixS = now_s;
    next.expiresAtUnixS = now_s + review_tuple_lock_ttl_seconds;
    next.lastFailureCode = failure_code;
    if (review_thread_id != null) next.reviewThreadId = review_thread_id;
    if (review_turn_id != null) next.reviewTurnId = review_turn_id;
    if (record_path != null) next.recordPath = record_path;
    if (event_log_path != null) next.eventLogPath = event_log_path;
    return next;
}

fn markReviewStartSendStarted(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    lock: *ReviewTupleLock,
) !void {
    if (lock.reviewStartSendStarted) return;
    var rewrite_lease = try acquireReviewTupleLockRewriteLeaseWithin(
        allocator,
        lock_path,
        0,
    );
    defer rewrite_lease.deinit(allocator);
    var loaded = (try loadReviewTupleLock(allocator, lock_path)) orelse
        return error.MissingReviewTupleLock;
    defer loaded.deinit(allocator);
    if (!std.mem.eql(u8, loaded.record.tupleHash, lock.tupleHash) or
        !std.mem.eql(u8, loaded.record.state, "starting_review") or
        loaded.record.ownerPid != lock.ownerPid)
    {
        return error.InvalidReviewTupleLockBinding;
    }
    if (loaded.record.reviewStartSendStarted) {
        lock.reviewStartSendStarted = true;
        return;
    }
    var next = loaded.record;
    next.reviewStartSendStarted = true;
    next.updatedAtUnixS = unixSeconds();
    next.expiresAtUnixS = next.updatedAtUnixS + review_tuple_lock_ttl_seconds;
    try writeReviewTupleLock(allocator, lock_path, next);
    lock.reviewStartSendStarted = true;
    lock.updatedAtUnixS = next.updatedAtUnixS;
    lock.expiresAtUnixS = next.expiresAtUnixS;
}

const ReviewStartSendBoundary = struct {
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    lock: *ReviewTupleLock,
};

fn persistReviewStartSendBoundary(context: *anyopaque) anyerror!void {
    const boundary: *ReviewStartSendBoundary = @ptrCast(@alignCast(context));
    try markReviewStartSendStarted(
        boundary.allocator,
        boundary.lock_path,
        boundary.lock,
    );
}

fn requestReviewStart(
    client: *cas.Client,
    params_json: []const u8,
    send_observer: ?cas.RequestSendObserver,
) ![]u8 {
    if (send_observer) |observer| {
        return client.requestJsonWithSendObserver(
            "review/start",
            params_json,
            observer,
        );
    }
    return client.requestJson("review/start", params_json);
}

fn writeReviewTupleLock(allocator: std.mem.Allocator, path: []const u8, lock: ReviewTupleLock) !void {
    const json = try stringifyAnyAlloc(allocator, lock);
    defer allocator.free(json);
    const payload = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    defer allocator.free(payload);
    try durable_store.writeTextAtomic(allocator, path, payload);
}

fn writeReviewTupleLockExclusive(allocator: std.mem.Allocator, path: []const u8, lock: ReviewTupleLock) !void {
    const json = try stringifyAnyAlloc(allocator, lock);
    defer allocator.free(json);
    const payload = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    defer allocator.free(payload);
    try durable_store.writeTextCreateNew(allocator, path, payload, .{ .reject_symlinks = true });
}

fn acquireReviewTupleLockRewriteLeaseWithin(
    allocator: std.mem.Allocator,
    lock_path: []const u8,
    wait_ms: u32,
) !ReviewTupleRewriteLease {
    const lease_path = try reviewTupleLockRewriteLeasePathAlloc(allocator, lock_path);
    errdefer allocator.free(lease_path);
    try ensureParentPath(lease_path);

    const started_ms = monotonicMilliseconds();
    while (true) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.openFileAbsolute(io, lease_path, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .follow_symlinks = false,
        }) catch |open_err| switch (open_err) {
            error.FileNotFound => std.Io.Dir.createFileAbsolute(io, lease_path, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => continue,
                error.WouldBlock => {
                    const elapsed_ms = monotonicMilliseconds() - started_ms;
                    if (elapsed_ms >= wait_ms) return error.PathAlreadyExists;
                    std.Io.sleep(
                        io,
                        .fromMilliseconds(@min(@as(i64, 10), @as(i64, wait_ms) - elapsed_ms)),
                        .awake,
                    ) catch {};
                    continue;
                },
                else => return create_err,
            },
            error.WouldBlock => {
                const elapsed_ms = monotonicMilliseconds() - started_ms;
                if (elapsed_ms >= wait_ms) return error.PathAlreadyExists;
                std.Io.sleep(
                    io,
                    .fromMilliseconds(@min(@as(i64, 10), @as(i64, wait_ms) - elapsed_ms)),
                    .awake,
                ) catch {};
                continue;
            },
            else => return open_err,
        };
        return .{ .file = file, .path = lease_path };
    }
}

fn reviewTupleLockAction(action_name: []const u8, existing: ?ReviewTupleLock, now_s: i64, override_reason: ?[]const u8, fresh_attempt_reason: ?[]const u8) ReviewTupleLockAction {
    return reviewTupleLockActionWithProbe(action_name, existing, now_s, override_reason, fresh_attempt_reason, false);
}

fn reviewTupleLockActionWithProbe(action_name: []const u8, existing: ?ReviewTupleLock, now_s: i64, override_reason: ?[]const u8, fresh_attempt_reason: ?[]const u8, dead_transport_proven: bool) ReviewTupleLockAction {
    const lock = existing orelse return .create;
    const current_lock = std.mem.eql(u8, lock.lockVersion, review_tuple_lock_version);
    const legacy_lock = std.mem.eql(u8, lock.lockVersion, legacy_review_tuple_lock_version);
    if (!current_lock and !legacy_lock) return .block_invalid;
    if (legacy_lock and
        !(std.mem.eql(u8, lock.state, "terminal") or
            std.mem.eql(u8, lock.state, "normalized") or
            std.mem.eql(u8, lock.state, "account_resource_exhausted")))
    {
        return .block_invalid;
    }
    if (std.mem.eql(u8, lock.state, "account_resource_exhausted")) {
        return if (override_reason != null) .takeover_with_override else .block_account_resource;
    }
    if (std.mem.eql(u8, lock.state, "terminal") or std.mem.eql(u8, lock.state, "normalized")) {
        if ((std.mem.eql(u8, action_name, "run") or
            std.mem.eql(u8, action_name, "start")) and
            fresh_attempt_reason != null)
        {
            return .fresh_after_terminal;
        }
        return .normalize_existing;
    }
    const expired = lock.expiresAtUnixS <= now_s;
    if (expired or std.mem.eql(u8, lock.state, "stale")) {
        return if (override_reason != null) .takeover_with_override else .block_stale;
    }
    if (std.mem.eql(u8, lock.state, "review_started") or std.mem.eql(u8, lock.state, "waiting")) {
        if (std.mem.eql(u8, action_name, "run") and dead_transport_proven and reviewTupleLockReplaceableDeadFailure(lock)) return .auto_replace_dead_transport;
        return if (lock.reviewThreadId != null) .return_existing else .block_active;
    }
    if (std.mem.eql(u8, lock.state, "pre_review_start_failed")) return .retry_after_pre_review_failure;
    if (std.mem.eql(u8, lock.state, "starting_review")) return .block_active;
    return .block_invalid;
}

fn normalizedReceiptReusableTerminal(receipt: NormalizedReceipt) bool {
    if (!receipt.tuple_verdict_exists) return false;
    if (!(std.mem.eql(u8, receipt.status, "clean") or std.mem.eql(u8, receipt.status, "findings"))) return false;
    return casRerPrincipalProofUsable(receipt);
}

fn terminalLockNeedsFreshAttempt(
    allocator: std.mem.Allocator,
    action_name: []const u8,
    lock: ReviewTupleLock,
    target_identity: TargetIdentity,
) bool {
    if (!(std.mem.eql(u8, action_name, "run") or
        std.mem.eql(u8, action_name, "start"))) return false;
    if (!(std.mem.eql(u8, lock.state, "terminal") or std.mem.eql(u8, lock.state, "normalized"))) return false;
    const record_path = lock.recordPath orelse return true;
    const normalized = normalizeReceiptFromPathAlloc(allocator, record_path, true, .{
        .requested_identity = target_identity,
        .requested_identity_required = true,
    }) catch return true;
    defer normalized.deinit(allocator);
    return !normalizedReceiptReusableTerminal(normalized);
}

fn reviewTupleLockReplaceableDeadFailure(lock: ReviewTupleLock) bool {
    const code = lock.lastFailureCode orelse return false;
    return std.mem.eql(u8, code, "review_transport_lost") or
        std.mem.eql(u8, code, "review_transport_timeout") or
        std.mem.eql(u8, code, "review_owner_failed") or
        std.mem.eql(u8, code, "workflow_bound_review_owner_lost_before_start") or
        std.mem.eql(u8, code, "wait_timed_out");
}

fn reviewTupleLockDeadTransportProven(allocator: std.mem.Allocator, lock: ReviewTupleLock) bool {
    if (!reviewTupleLockReplaceableDeadFailure(lock)) return false;
    if (cas_websocket.processAlive(lock.ownerPid)) return false;
    const managed_server_pid = reviewTupleManagedServerPid(allocator, lock) orelse return false;
    return !cas_websocket.processAlive(managed_server_pid);
}

fn reviewTupleManagedServerPid(
    allocator: std.mem.Allocator,
    lock: ReviewTupleLock,
) ?u64 {
    if (lock.managedServerPid) |process_id| return process_id;
    const record_path = lock.recordPath orelse return null;
    const owned_record_path = allocator.dupe(u8, record_path) catch return null;
    var loaded = loadOwnedSessionRecordPath(allocator, owned_record_path) catch return null;
    defer loaded.deinit(allocator);
    return loaded.record.managed_server_pid;
}

fn ensureReviewTuplePredecessorExited(
    allocator: std.mem.Allocator,
    lock: ReviewTupleLock,
) !void {
    return ensureReviewTuplePredecessorExitedWithin(
        allocator,
        lock,
        cas_websocket.owner_watchdog_shutdown_grace_ms + 1_500,
    );
}

fn ensureReviewTuplePredecessorExitedWithin(
    allocator: std.mem.Allocator,
    lock: ReviewTupleLock,
    timeout_ms: u32,
) !void {
    if (lock.managedServerShutdownReceiptPath) |receipt_path| {
        const receipt_token = lock.managedServerShutdownReceiptToken orelse
            return error.InvalidReviewTupleLockBinding;
        const started_ms = monotonicMilliseconds();
        while (true) {
            const raw = durable_store.readRegularFileNoSymlink(
                allocator,
                receipt_path,
                4096,
            ) catch null;
            if (raw) |payload| {
                defer allocator.free(payload);
                var parsed = std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    payload,
                    .{},
                ) catch return error.InvalidReviewTupleLockBinding;
                defer parsed.deinit();
                const object = switch (parsed.value) {
                    .object => |value| value,
                    else => return error.InvalidReviewTupleLockBinding,
                };
                if (!std.mem.eql(
                    u8,
                    jsonStringField(object, "schema") orelse "",
                    "CAS-WDR-v1",
                ) or !std.mem.eql(
                    u8,
                    jsonStringField(object, "token") orelse "",
                    receipt_token,
                )) return error.InvalidReviewTupleLockBinding;
                return;
            }
            if (monotonicMilliseconds() - started_ms >= timeout_ms) {
                return error.ReviewPredecessorStillAlive;
            }
            std.Io.sleep(
                std.Io.Threaded.global_single_threaded.io(),
                .fromMilliseconds(10),
                .awake,
            ) catch {};
        }
    }

    // Existing CAS-RTL-v2 locks predate the stable shutdown receipt. Their
    // acquired owner lease proves the owner is gone, and the released
    // watchdog contract has a bounded child-retirement grace. Numeric PID is
    // diagnostic only and cannot gate authority across PID reuse.
    const compatibility_wait_ms = cas_websocket.owner_watchdog_shutdown_grace_ms + 100;
    if (timeout_ms < compatibility_wait_ms) {
        return error.ReviewPredecessorStillAlive;
    }
    std.Io.sleep(
        std.Io.Threaded.global_single_threaded.io(),
        .fromMilliseconds(compatibility_wait_ms),
        .awake,
    ) catch {};
}

fn reviewTupleLockActionForAcquire(
    allocator: std.mem.Allocator,
    action_name: []const u8,
    existing: ?ReviewTupleLock,
    now_s: i64,
    override_reason: ?[]const u8,
    fresh_attempt_reason: ?[]const u8,
    target_identity: TargetIdentity,
    owner_lease_held_elsewhere: ?bool,
) ReviewTupleLockAction {
    if (existing == null and owner_lease_held_elsewhere == true) {
        return .block_active;
    }
    if (existing) |lock| {
        const active = std.mem.eql(u8, lock.state, "starting_review") or
            std.mem.eql(u8, lock.state, "review_started") or
            std.mem.eql(u8, lock.state, "waiting");
        if (active and lock.workflowBinding != null and
            std.mem.eql(
                u8,
                lock.ownerLeaseVersion orelse "",
                review_owner_lease_version,
            ))
        {
            return if (owner_lease_held_elsewhere == true)
                .block_active
            else if (fresh_attempt_reason != null)
                .recover_dead_owner
            else
                .block_dead_owner;
        }
    }
    const dead_transport_proven = if (existing) |lock| reviewTupleLockDeadTransportProven(allocator, lock) else false;
    var action = reviewTupleLockActionWithProbe(action_name, existing, now_s, override_reason, fresh_attempt_reason, dead_transport_proven);
    if (action == .normalize_existing and fresh_attempt_reason == null) {
        if (existing) |lock| {
            if (terminalLockNeedsFreshAttempt(allocator, action_name, lock, target_identity)) action = .fresh_after_terminal;
        }
    }
    if (owner_lease_held_elsewhere == true and reviewTupleLockActionMutates(action)) {
        return .block_active;
    }
    return action;
}

fn reviewTupleLockActionMutates(action: ReviewTupleLockAction) bool {
    return switch (action) {
        .create,
        .retry_after_pre_review_failure,
        .auto_replace_dead_transport,
        .recover_dead_owner,
        .takeover_with_override,
        .fresh_after_terminal,
        => true,
        else => false,
    };
}

fn printReviewTupleLockExistingAndExit(
    allocator: std.mem.Allocator,
    action_name: []const u8,
    target: TargetRecord,
    target_identity: TargetIdentity,
    tuple: ReviewTupleIdentity,
    lock_path: []const u8,
    lock: ReviewTupleLock,
    decision: ReviewTupleLockAction,
) !noreturn {
    if (decision == .normalize_existing) {
        if (lock.recordPath) |record_path| {
            const normalized_opt: ?NormalizedReceipt = normalizeReceiptFromPathAlloc(
                allocator,
                record_path,
                true,
                .{
                    .requested_identity = target_identity,
                    .requested_identity_required = true,
                },
            ) catch null;
            if (normalized_opt) |normalized| {
                defer normalized.deinit(allocator);
                var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
                const stdout = &stdout_writer.interface;
                if (std.mem.eql(u8, action_name, "run")) {
                    try writeRunNormalizedReceiptObject(allocator, stdout, normalized, lock);
                    try stdout.writeAll("\n");
                } else {
                    try writeReceiptObject(stdout, normalized);
                    try stdout.writeAll("\n");
                }
                std.process.exit(if (normalizedReceiptCommandSucceeded(normalized)) 0 else 1);
            }
        }
    }

    const review_thread_id = lock.reviewThreadId;
    const review_turn_id = lock.reviewTurnId;
    const lock_points_to_terminal = std.mem.eql(u8, lock.state, "terminal") or std.mem.eql(u8, lock.state, "normalized");
    const workflow_owner_active = tuple.workflow_binding != null and !lock_points_to_terminal;
    const active_failure: ?FailureInfo = if (workflow_owner_active)
        workflowOwnerActiveFailureInfo()
    else
        null;
    const active_failure_code: ?[]const u8 = if (active_failure) |failure| failure.code else null;
    const active_failure_hint: []const u8 = if (active_failure) |failure|
        failure.hint
    else if (decision == .normalize_existing)
        "tuple lock points to an existing terminal receipt; normalize that record instead of starting a duplicate review"
    else
        "tuple lock points to an existing active review attempt";
    const broker_decision: ?ReviewBrokerDecision = if (std.mem.eql(u8, action_name, "run")) .{
        .action = "blocked_live_attempt",
        .reason = if (decision == .normalize_existing)
            "tuple lock points to an existing terminal receipt, but the receipt could not be normalized into a terminal verdict"
        else
            "tuple lock points to an existing active review attempt whose liveness was not disproven",
        .reviewThreadId = review_thread_id,
        .recordPath = lock.recordPath,
        .eventLogPath = lock.eventLogPath,
    } else null;
    const payload = .{
        .demo = "cas-review-session",
        .action = action_name,
        .reviewBrokerDecision = broker_decision,
        .cwd = tuple.repo_realpath,
        .reviewAttemptPhase = if (lock_points_to_terminal) "review_terminal" else "review_waiting",
        .reviewAttemptExists = review_thread_id != null,
        .tupleVerdictExists = false,
        .reviewThreadId = review_thread_id,
        .reviewTurnId = review_turn_id,
        .target = target,
        .baseSha = tuple.base_sha,
        .headSha = tuple.head_sha,
        .targetFingerprint = tuple.target_fingerprint,
        .resolvedCodexPath = tuple.resolved_codex_path,
        .resolvedCodexVersion = tuple.resolved_codex_version,
        .reviewTupleLockVersion = review_tuple_lock_version,
        .reviewTupleHash = lock.tupleHash,
        .reviewTupleLockPath = lock_path,
        .reviewTupleLockState = lock.state,
        .reviewTupleLockAction = decision.asString(),
        .accountFingerprint = tuple.account_fingerprint,
        .accountFingerprintReducedProtection = tuple.account_fingerprint_reduced_protection,
        .workflowBinding = tuple.workflow_binding,
        .failureCode = active_failure_code,
        .failureClass = failureClassForCode(active_failure_code),
        .retryableSameTupleNow = retryableSameTupleNowForCode(active_failure_code),
        .failureHint = active_failure_hint,
        .recordPath = lock.recordPath,
        .eventLogPath = lock.eventLogPath,
        .lastFailureCode = lock.lastFailureCode,
        .reviewVerdict = .{
            .status = tupleLockDiagnosticVerdictStatus(lock),
            .reviewAttemptPhase = if (lock_points_to_terminal) "review_terminal" else "review_waiting",
            .reviewAttemptExists = review_thread_id != null,
            .tupleVerdictExists = false,
            .backendClass = "cas-receipt-normalized",
            .clean = false,
            .findingCount = 0,
            .failureCode = active_failure_code,
            .failureHint = active_failure_hint,
            .baseSha = tuple.base_sha,
            .headSha = tuple.head_sha,
            .targetFingerprint = tuple.target_fingerprint,
            .reviewThreadId = review_thread_id,
            .reviewTurnId = review_turn_id,
            .recordPath = lock.recordPath,
            .eventLogPath = lock.eventLogPath,
            .findings = [_]std.json.Value{},
        },
    };
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    const payload_json = try stringifyAnyAlloc(allocator, payload);
    defer allocator.free(payload_json);
    if (std.mem.eql(u8, action_name, "run")) {
        const timestamp = try casRerTimestampAlloc(allocator);
        defer allocator.free(timestamp);
        const shadow_record_path = writeCasRerShadowRecordFromJsonAlloc(
            allocator,
            lock.recordPath orelse lock_path,
            payload_json,
            .{
                .requested_identity = target_identity,
                .requested_identity_required = true,
            },
            .{
                .command_surface = "run",
                .backend_selected = "cas-run",
                .broker_action = "blocked_live",
                .broker_reason = broker_decision.?.reason,
                .timestamp = timestamp,
            },
        ) catch null;
        defer if (shadow_record_path) |path| allocator.free(path);
    }
    try stdout.print("{s}\n", .{payload_json});
    std.process.exit(1);
}

fn writeRunNormalizedReceiptObject(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    receipt: NormalizedReceipt,
    lock: ReviewTupleLock,
) !void {
    const broker = ReviewBrokerDecision{
        .action = "normalized_existing",
        .reason = "tuple lock points to an existing terminal receipt " ++
            "normalized for the requested tuple",
        .reviewThreadId = lock.reviewThreadId,
        .recordPath = lock.recordPath,
        .eventLogPath = lock.eventLogPath,
    };
    try writeCasRunEnvelopeFromReceipt(allocator, writer, receipt, broker, false);
}

fn reviewBrokerActionForBlockedLock(decision: ReviewTupleLockAction) []const u8 {
    return switch (decision) {
        .block_account_resource => "blocked_account_resource",
        .block_stale => "blocked_stale_lock",
        .block_invalid => "blocked_invalid_lock",
        .block_dead_owner => "terminal_dead_owner",
        else => "blocked_live_attempt",
    };
}

fn tupleLockDiagnosticVerdictStatus(lock: ReviewTupleLock) []const u8 {
    if (std.mem.eql(u8, lock.lastFailureCode orelse "", "review_transport_timeout")) return "review_transport_failure";
    if (std.mem.eql(u8, lock.lastFailureCode orelse "", "wait_timed_out")) return "timeout";
    return "incomplete";
}

fn emitReviewTupleLockBlockedAndExit(
    allocator: std.mem.Allocator,
    json_mode: bool,
    action_name: []const u8,
    target: TargetRecord,
    tuple: ReviewTupleIdentity,
    lock_path: []const u8,
    lock: ?ReviewTupleLock,
    decision: ReviewTupleLockAction,
    override_reason: ?[]const u8,
) !noreturn {
    const workflow_owner_active = tuple.workflow_binding != null and decision == .block_active;
    const workflow_owner_dead = tuple.workflow_binding != null and decision == .block_dead_owner;
    const dead_attempt_exists = if (lock) |value|
        workflowDeadOwnerAttemptExists(value)
    else
        false;
    const owner_active_failure: ?FailureInfo = if (workflow_owner_active)
        workflowOwnerActiveFailureInfo()
    else
        null;
    const dead_owner_failure: ?FailureInfo = if (workflow_owner_dead) blk: {
        const value = lock orelse return error.InvalidReviewTupleLockBinding;
        break :blk workflowDeadOwnerFailureInfo(value);
    } else null;
    const failure_code: []const u8 = if (dead_owner_failure) |failure|
        failure.code
    else if (owner_active_failure) |failure|
        failure.code
    else switch (decision) {
        .block_account_resource => "review_tuple_lock_account_resource_exhausted",
        .block_stale => "review_tuple_lock_stale",
        .block_invalid => "review_tuple_lock_invalid",
        else => "review_tuple_lock_active",
    };
    const hint: []const u8 = if (dead_owner_failure) |failure|
        failure.hint
    else if (owner_active_failure) |failure|
        failure.hint
    else switch (decision) {
        .block_account_resource => "same-account review retry is blocked until " ++
            "the limit resets, the account changes, or " ++
            "--review-lock-override is supplied",
        .block_stale => "tuple lock is stale; supply --review-lock-override " ++
            "with a takeover reason before starting a new review",
        .block_invalid => "tuple lock file is invalid for CAS-RTL-v2 or historical CAS-RTL-v1; " ++
            "inspect or remove it before starting a new review",
        else => "an active review attempt already owns this repo/base/head/account tuple",
    };
    if (workflow_owner_dead) {
        const value = lock orelse return error.InvalidReviewTupleLockBinding;
        // Retry authority follows the durable terminal transition. Never emit a
        // retryable recovery receipt for a lease that remained active on disk.
        if (value.recordPath) |record_path| {
            var loaded_record = try loadOwnedSessionRecordPath(
                allocator,
                try allocator.dupe(u8, record_path),
            );
            defer loaded_record.deinit(allocator);
            try terminalizeDeadWorkflowBoundOwner(
                allocator,
                record_path,
                &loaded_record.record,
                .{ .code = failure_code, .hint = hint },
            );
        } else {
            const terminal = withReviewTupleLockState(
                value,
                "terminal",
                unixSeconds(),
                failure_code,
                value.reviewThreadId,
                value.reviewTurnId,
                value.recordPath,
                value.eventLogPath,
            );
            try writeReviewTupleLock(allocator, lock_path, terminal);
        }
    }
    if (json_mode) {
        const blocked_review_thread_id = if (lock) |value| value.reviewThreadId else null;
        const blocked_review_turn_id = if (lock) |value| value.reviewTurnId else null;
        const blocked_attempt_exists = if (workflow_owner_dead)
            dead_attempt_exists
        else
            blocked_review_thread_id != null;
        const blocked_phase: []const u8 = if (workflow_owner_dead and blocked_attempt_exists)
            "review_terminal"
        else if (blocked_attempt_exists)
            "review_waiting"
        else
            "pre_review_start";
        const broker_decision: ?ReviewBrokerDecision = if (std.mem.eql(u8, action_name, "run")) .{
            .action = reviewBrokerActionForBlockedLock(decision),
            .reason = hint,
            .reviewThreadId = if (lock) |value| value.reviewThreadId else null,
            .recordPath = if (lock) |value| value.recordPath else null,
            .eventLogPath = if (lock) |value| value.eventLogPath else null,
        } else null;
        const payload = .{
            .demo = "cas-review-session",
            .action = action_name,
            .reviewBrokerDecision = broker_decision,
            .cwd = tuple.repo_realpath,
            .reviewAttemptPhase = blocked_phase,
            .reviewAttemptExists = blocked_attempt_exists,
            .tupleVerdictExists = false,
            .reviewThreadId = blocked_review_thread_id,
            .reviewTurnId = blocked_review_turn_id,
            .target = target,
            .baseSha = tuple.base_sha,
            .headSha = tuple.head_sha,
            .targetFingerprint = tuple.target_fingerprint,
            .resolvedCodexPath = tuple.resolved_codex_path,
            .resolvedCodexVersion = tuple.resolved_codex_version,
            .failureCode = failure_code,
            .failureClass = if (workflow_owner_dead and blocked_attempt_exists)
                "transport_review_attempt"
            else
                "coordination",
            .retryableSameTupleNow = workflow_owner_dead,
            .failureHint = hint,
            .reviewTupleLockVersion = review_tuple_lock_version,
            .reviewTupleHash = if (lock) |value| value.tupleHash else null,
            .reviewTupleLockPath = lock_path,
            .reviewTupleLockState = if (workflow_owner_dead)
                "terminal"
            else if (lock) |value|
                value.state
            else
                null,
            .reviewTupleLockAction = decision.asString(),
            .accountFingerprint = tuple.account_fingerprint,
            .accountFingerprintReducedProtection = tuple.account_fingerprint_reduced_protection,
            .workflowBinding = tuple.workflow_binding,
            .overrideReason = override_reason,
            .recordPath = if (lock) |value| value.recordPath else null,
            .eventLogPath = if (lock) |value| value.eventLogPath else null,
            .lastFailureCode = if (lock) |value| value.lastFailureCode else null,
            .reviewVerdict = .{
                .status = "incomplete",
                .reviewAttemptPhase = blocked_phase,
                .reviewAttemptExists = blocked_attempt_exists,
                .tupleVerdictExists = false,
                .backendClass = "cas-receipt-normalized",
                .clean = false,
                .findingCount = 0,
                .failureCode = failure_code,
                .failureHint = hint,
                .baseSha = tuple.base_sha,
                .headSha = tuple.head_sha,
                .targetFingerprint = tuple.target_fingerprint,
                .reviewThreadId = blocked_review_thread_id,
                .reviewTurnId = blocked_review_turn_id,
                .recordPath = if (lock) |value| value.recordPath else null,
                .eventLogPath = if (lock) |value| value.eventLogPath else null,
                .findings = [_]std.json.Value{},
            },
        };
        const payload_json = try stringifyAnyAlloc(allocator, payload);
        defer allocator.free(payload_json);
        if (std.mem.eql(u8, action_name, "run")) {
            const timestamp = try casRerTimestampAlloc(allocator);
            defer allocator.free(timestamp);
            const shadow_record_path = writeCasRerShadowRecordFromJsonAlloc(allocator, if (lock) |value| value.recordPath orelse lock_path else lock_path, payload_json, normalizeContextFromReviewTuple(tuple), .{
                .command_surface = "run",
                .backend_selected = "cas-run",
                .broker_action = publicReviewBrokerAction(reviewBrokerActionForBlockedLock(decision)),
                .broker_reason = hint,
                .timestamp = timestamp,
            }) catch null;
            defer if (shadow_record_path) |path| allocator.free(path);
        }
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("{s}\n", .{payload_json});
    } else {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("review tuple lock blocked {s}: {s}\n", .{ decision.asString(), hint });
    }
    std.process.exit(1);
}

const ReviewTupleStartLockBundle = struct {
    path: []const u8,
    lock: ReviewTupleLock,
    owner_lease: ?ReviewOwnerLease = null,

    fn deinit(self: ReviewTupleStartLockBundle, allocator: std.mem.Allocator) void {
        if (self.owner_lease) |value| {
            var lease = value;
            lease.deinit(allocator);
        }
        allocator.free(self.path);
        allocator.free(self.lock.tupleHash);
    }
};

fn acquireReviewTupleStartLockOrExit(
    allocator: std.mem.Allocator,
    json_mode: bool,
    action_name: []const u8,
    target: TargetRecord,
    target_identity: TargetIdentity,
    tuple: ReviewTupleIdentity,
    override_reason: ?[]const u8,
    fresh_attempt_reason: ?[]const u8,
    managed_server_to_kill_on_exit: ?*cas_websocket.ManagedServer,
) !ReviewTupleStartLockBundle {
    const tuple_hash = try reviewTupleHashAlloc(allocator, tuple);
    const lock_path = try reviewTupleLockPathAlloc(allocator, tuple_hash);
    var owner_lease = if (tuple.workflow_binding != null)
        try tryAcquireReviewOwnerLeaseAlloc(allocator, lock_path)
    else
        null;
    errdefer if (owner_lease) |*lease| lease.deinit(allocator);
    const owner_lease_held_elsewhere: ?bool = if (tuple.workflow_binding != null)
        owner_lease == null
    else
        null;
    var loaded_opt = loadReviewTupleLock(allocator, lock_path) catch {
        killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
        try emitReviewTupleLockBlockedAndExit(
            allocator,
            json_mode,
            action_name,
            target,
            tuple,
            lock_path,
            null,
            .block_invalid,
            override_reason,
        );
    };
    defer if (loaded_opt) |*loaded| loaded.deinit(allocator);
    const now_s = unixSeconds();
    const decision = reviewTupleLockActionForAcquire(
        allocator,
        action_name,
        if (loaded_opt) |loaded| loaded.record else null,
        now_s,
        override_reason,
        fresh_attempt_reason,
        target_identity,
        owner_lease_held_elsewhere,
    );
    switch (decision) {
        .create => {
            var lock = makeReviewTupleLock(
                tuple_hash,
                tuple,
                "starting_review",
                now_s,
                override_reason,
                fresh_attempt_reason,
            );
            lock.managedServerPid = if (managed_server_to_kill_on_exit) |server|
                server.processId()
            else
                null;
            lock.managedServerShutdownReceiptPath = if (managed_server_to_kill_on_exit) |server|
                server.shutdownReceiptPath()
            else
                null;
            lock.managedServerShutdownReceiptToken = if (managed_server_to_kill_on_exit) |server|
                server.shutdownReceiptToken()
            else
                null;
            writeReviewTupleLockExclusive(allocator, lock_path, lock) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    var raced = (loadReviewTupleLock(allocator, lock_path) catch {
                        killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                        try emitReviewTupleLockBlockedAndExit(
                            allocator,
                            json_mode,
                            action_name,
                            target,
                            tuple,
                            lock_path,
                            null,
                            .block_invalid,
                            override_reason,
                        );
                    }) orelse return err;
                    defer raced.deinit(allocator);
                    const raced_decision = reviewTupleLockActionForAcquire(
                        allocator,
                        action_name,
                        raced.record,
                        now_s,
                        override_reason,
                        fresh_attempt_reason,
                        target_identity,
                        owner_lease_held_elsewhere,
                    );
                    switch (raced_decision) {
                        .return_existing, .normalize_existing => {
                            killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                            try printReviewTupleLockExistingAndExit(
                                allocator,
                                action_name,
                                target,
                                target_identity,
                                tuple,
                                lock_path,
                                raced.record,
                                raced_decision,
                            );
                        },
                        .block_active, .block_dead_owner, .block_stale, .block_account_resource, .block_invalid => {
                            killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                            try emitReviewTupleLockBlockedAndExit(
                                allocator,
                                json_mode,
                                action_name,
                                target,
                                tuple,
                                lock_path,
                                raced.record,
                                raced_decision,
                                override_reason,
                            );
                        },
                        .create,
                        .retry_after_pre_review_failure,
                        .auto_replace_dead_transport,
                        .recover_dead_owner,
                        .takeover_with_override,
                        .fresh_after_terminal,
                        => return err,
                    }
                },
                else => return err,
            };
            return .{
                .path = lock_path,
                .lock = lock,
                .owner_lease = owner_lease,
            };
        },
        .retry_after_pre_review_failure,
        .auto_replace_dead_transport,
        .recover_dead_owner,
        .takeover_with_override,
        .fresh_after_terminal,
        => {
            var rewrite_lease = acquireReviewTupleLockRewriteLeaseWithin(
                allocator,
                lock_path,
                0,
            ) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                    try emitReviewTupleLockBlockedAndExit(
                        allocator,
                        json_mode,
                        action_name,
                        target,
                        tuple,
                        lock_path,
                        if (loaded_opt) |loaded| loaded.record else null,
                        .block_active,
                        override_reason,
                    );
                },
                else => return err,
            };
            defer rewrite_lease.deinit(allocator);

            var latest = (loadReviewTupleLock(allocator, lock_path) catch {
                killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                try emitReviewTupleLockBlockedAndExit(
                    allocator,
                    json_mode,
                    action_name,
                    target,
                    tuple,
                    lock_path,
                    null,
                    .block_invalid,
                    override_reason,
                );
            }) orelse {
                killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                try emitReviewTupleLockBlockedAndExit(
                    allocator,
                    json_mode,
                    action_name,
                    target,
                    tuple,
                    lock_path,
                    null,
                    .block_invalid,
                    override_reason,
                );
            };
            defer latest.deinit(allocator);
            const latest_decision = reviewTupleLockActionForAcquire(
                allocator,
                action_name,
                latest.record,
                unixSeconds(),
                override_reason,
                fresh_attempt_reason,
                target_identity,
                owner_lease_held_elsewhere,
            );
            switch (latest_decision) {
                .retry_after_pre_review_failure,
                .auto_replace_dead_transport,
                .recover_dead_owner,
                .takeover_with_override,
                .fresh_after_terminal,
                => {},
                .return_existing, .normalize_existing => {
                    killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                    try printReviewTupleLockExistingAndExit(
                        allocator,
                        action_name,
                        target,
                        target_identity,
                        tuple,
                        lock_path,
                        latest.record,
                        latest_decision,
                    );
                },
                .block_active, .block_dead_owner, .block_stale, .block_account_resource, .block_invalid => {
                    killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                    try emitReviewTupleLockBlockedAndExit(
                        allocator,
                        json_mode,
                        action_name,
                        target,
                        tuple,
                        lock_path,
                        latest.record,
                        latest_decision,
                        override_reason,
                    );
                },
                .create => {
                    killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                    try emitReviewTupleLockBlockedAndExit(
                        allocator,
                        json_mode,
                        action_name,
                        target,
                        tuple,
                        lock_path,
                        latest.record,
                        .block_invalid,
                        override_reason,
                    );
                },
            }
            const replacement_override_reason =
                if (latest_decision == .auto_replace_dead_transport)
                    "auto-replaced-dead-transport"
                else if (latest_decision == .recover_dead_owner)
                    "recovered-dead-owner"
                else
                    override_reason;
            if (latest_decision == .recover_dead_owner) {
                try ensureReviewTuplePredecessorExited(allocator, latest.record);
                const predecessor_rer_path = try persistDeadOwnerRecoveryEvidence(
                    allocator,
                    lock_path,
                    latest.record,
                    target_identity,
                );
                if (predecessor_rer_path) |path| allocator.free(path);
            }
            var lock = makeReviewTupleLock(
                tuple_hash,
                tuple,
                "starting_review",
                now_s,
                replacement_override_reason,
                fresh_attempt_reason,
            );
            lock.managedServerPid = if (managed_server_to_kill_on_exit) |server|
                server.processId()
            else
                null;
            lock.managedServerShutdownReceiptPath = if (managed_server_to_kill_on_exit) |server|
                server.shutdownReceiptPath()
            else
                null;
            lock.managedServerShutdownReceiptToken = if (managed_server_to_kill_on_exit) |server|
                server.shutdownReceiptToken()
            else
                null;
            try writeReviewTupleLock(allocator, lock_path, lock);
            return .{
                .path = lock_path,
                .lock = lock,
                .owner_lease = owner_lease,
            };
        },
        .return_existing, .normalize_existing => {
            const lock = loaded_opt.?.record;
            killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
            try printReviewTupleLockExistingAndExit(
                allocator,
                action_name,
                target,
                target_identity,
                tuple,
                lock_path,
                lock,
                decision,
            );
        },
        .block_active, .block_dead_owner, .block_stale, .block_account_resource, .block_invalid => {
            killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
            try emitReviewTupleLockBlockedAndExit(
                allocator,
                json_mode,
                action_name,
                target,
                tuple,
                lock_path,
                if (loaded_opt) |loaded| loaded.record else null,
                decision,
                override_reason,
            );
        },
    }
}

fn killManagedServerBeforeTupleLockExit(managed_server: ?*cas_websocket.ManagedServer) void {
    if (managed_server) |server| server.kill();
}

fn updateReviewTupleLockBestEffort(
    allocator: std.mem.Allocator,
    path: []const u8,
    current: ReviewTupleLock,
    state: []const u8,
    failure_code: ?[]const u8,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: ?[]const u8,
    event_log_path: ?[]const u8,
) void {
    const next = withReviewTupleLockState(
        current,
        state,
        unixSeconds(),
        failure_code,
        review_thread_id,
        review_turn_id,
        record_path,
        event_log_path,
    );
    writeReviewTupleLock(allocator, path, next) catch {};
}

fn transitionReviewTupleLockForRecordOrReplay(
    allocator: std.mem.Allocator,
    json_mode: bool,
    record: SessionRecord,
    record_path: []const u8,
    state: []const u8,
    failure_code: ?[]const u8,
    identity: TargetIdentity,
) !void {
    if (try transitionActiveReviewTupleLockForRecord(
        allocator,
        record,
        record_path,
        state,
        failure_code,
    )) return;
    try replayTerminalRecordAndExit(
        allocator,
        json_mode,
        record,
        record_path,
        identity,
    );
    return error.InvalidReviewTupleLockBinding;
}

fn transitionActiveReviewTupleLockForRecord(
    allocator: std.mem.Allocator,
    record: SessionRecord,
    record_path: []const u8,
    state: []const u8,
    failure_code: ?[]const u8,
) !bool {
    const lock_path = try storedReviewTupleLockPathAlloc(allocator, record);
    defer allocator.free(lock_path);
    var rewrite_lease = try acquireReviewTupleLockRewriteLeaseWithin(
        allocator,
        lock_path,
        review_tuple_lock_rewrite_lease_wait_ms,
    );
    defer rewrite_lease.deinit(allocator);
    var loaded = try loadExactReviewTupleLockForRecord(
        allocator,
        record,
        record_path,
    );
    defer loaded.deinit(allocator);
    const active = std.mem.eql(u8, loaded.record.state, "starting_review") or
        std.mem.eql(u8, loaded.record.state, "review_started") or
        std.mem.eql(u8, loaded.record.state, "waiting");
    if (!active) return false;
    const next = withReviewTupleLockState(
        loaded.record,
        state,
        unixSeconds(),
        failure_code,
        record.review_thread_id,
        record.review_turn_id,
        record_path,
        record.event_log_path,
    );
    try writeReviewTupleLock(allocator, loaded.path, next);
    return true;
}
fn appendLogRecord(
    allocator: std.mem.Allocator,
    path: []const u8,
    method: []const u8,
    direction: []const u8,
    payload_json: []const u8,
) !void {
    const method_json = try quoteJsonStringAlloc(allocator, method);
    defer allocator.free(method_json);
    const direction_json = try quoteJsonStringAlloc(allocator, direction);
    defer allocator.free(direction_json);
    const payload_json_string = try quoteJsonStringAlloc(allocator, payload_json);
    defer allocator.free(payload_json_string);
    const json_line = try std.fmt.allocPrint(
        allocator,
        "{{\"recordedAtUnixS\":{d},\"method\":{s},\"direction\":{s},\"payload\":{s}}}",
        .{
            @divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000),
            method_json,
            direction_json,
            payload_json_string,
        },
    );
    defer allocator.free(json_line);
    try durable_store.appendLineStreaming(allocator, path, json_line, .{ .reject_symlinks = true });
}

fn ensureParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;

    if (std.fs.path.isAbsolute(parent)) {
        const rel = std.mem.trim(u8, parent, "/");
        if (rel.len == 0) return;
        var root = try std.Io.Dir.openDirAbsolute(
            std.Io.Threaded.global_single_threaded.io(),
            "/",
            .{},
        );
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
        const failure_class = failureClassForCode(failure.code);
        const retryable_same_tuple_now = retryableSameTupleNowForCode(failure.code);
        const review_attempt_phase = receipt.error_review_attempt_phase orelse
            errorReviewAttemptPhase(action, method);
        const payload = .{
            .demo = "cas-review-session",
            .action = action,
            .method = method,
            .reviewAttemptPhase = review_attempt_phase,
            .reviewAttemptExists = receipt.error_review_attempt_exists,
            .tupleVerdictExists = false,
            .reviewThreadId = receipt.error_review_thread_id,
            .reviewTurnId = receipt.error_review_turn_id,
            .baseSha = @as(?[]const u8, null),
            .headSha = @as(?[]const u8, null),
            .targetFingerprint = @as(?[]const u8, null),
            .cwd = cwd,
            .resolvedCodexPath = receipt.resolved_codex_path,
            .resolvedCodexVersion = receipt.resolved_codex_version,
            .compatibilityVerdict = receipt.compatibility_verdict,
            .requestedMultiAgentMode = if (receipt.requested_multi_agent_mode) |mode|
                mode.configValue()
            else
                null,
            .effectiveMultiAgentMode = if (receipt.effective_multi_agent_mode) |mode|
                mode.configValue()
            else
                null,
            .multiAgentModeSupport = receipt.multi_agent_mode_support.asString(),
            .multiAgentModeMetricEligible = receipt.multi_agent_mode_metric_eligible,
            .workflowBinding = receipt.workflow_binding,
            .failureCode = failure.code,
            .failureClass = failure_class,
            .retryableSameTupleNow = retryable_same_tuple_now,
            .failureHint = failure.hint,
            .@"error" = message,
            .reviewVerdict = .{
                .status = "incomplete",
                .backendClass = "cas-receipt-normalized",
                .clean = false,
                .findingCount = 0,
                .failureCode = failure.code,
                .failureHint = failure.hint,
                .baseSha = @as(?[]const u8, null),
                .headSha = @as(?[]const u8, null),
                .targetFingerprint = @as(?[]const u8, null),
                .reviewThreadId = receipt.error_review_thread_id,
                .reviewTurnId = receipt.error_review_turn_id,
                .recordPath = @as(?[]const u8, null),
                .eventLogPath = @as(?[]const u8, null),
                .workflowBinding = receipt.workflow_binding,
                .findings = [_]std.json.Value{},
            },
        };
        try printJson(payload);
    } else {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}: {s} ({s})\n", .{ method, message, failure.code });
    }
    std.process.exit(1);
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

fn optionalModeJsonAlloc(allocator: std.mem.Allocator, mode: ?cas.MultiAgentMode) ![]const u8 {
    if (mode) |value| return quoteJsonStringAlloc(allocator, value.configValue());
    return "null";
}

fn modeSupportJsonAlloc(allocator: std.mem.Allocator, support: cas.MultiAgentModeSupport) ![]u8 {
    return quoteJsonStringAlloc(allocator, support.asString());
}

fn printJson(value: anytype) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, stdout);
    try stdout.writeAll("\n");
}

const StatusAction = enum {
    wait,
};

fn printStatusJson(
    backing_allocator: std.mem.Allocator,
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
) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer scratch_arena.deinit();
    const allocator = scratch_arena.allocator();
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    const effective_failure = failure;
    const review_verdict_json_opt = if (identity) |target_identity|
        try startWaitReviewVerdictJsonAlloc(
            allocator,
            target_identity,
            review_thread_id,
            review_turn_id,
            record_path orelse "",
            event_log_path,
            receipt,
            status,
            timed_out orelse false,
            true,
            effective_failure,
        )
    else
        null;
    defer if (review_verdict_json_opt) |value| allocator.free(value);
    const wait_tuple_verdict_exists = if (identity) |target_identity|
        startReceiptTupleVerdictExists(
            allocator,
            review_verdict_json_opt,
            review_thread_id,
            target_identity,
            status,
            timed_out orelse false,
        )
    else
        false;
    const attempt_fields = identityReviewAttemptFields(
        if (wait_tuple_verdict_exists)
            "normalized_verdict"
        else
            startReceiptReviewAttemptPhase(
                status,
                timed_out orelse false,
                effective_failure,
                review_thread_id,
            ),
        wait_tuple_verdict_exists,
        review_thread_id,
        review_turn_id,
        identity,
    );

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
    const requested_multi_agent_mode_json = try optionalModeJsonAlloc(allocator, receipt.requested_multi_agent_mode);
    const effective_multi_agent_mode_json = try optionalModeJsonAlloc(allocator, receipt.effective_multi_agent_mode);
    const multi_agent_mode_support_json = try modeSupportJsonAlloc(allocator, receipt.multi_agent_mode_support);
    const failure_code_json = if (effective_failure) |value|
        try quoteJsonStringAlloc(allocator, value.code)
    else
        "null";
    const failure_hint_json = if (effective_failure) |value|
        try quoteJsonStringAlloc(allocator, value.hint)
    else
        "null";
    const failure_control_suffix = try failureControlJsonSuffixAlloc(allocator, effective_failure);
    defer allocator.free(failure_control_suffix);
    const timeout_json = if (timeout_ms) |value|
        try std.fmt.allocPrint(allocator, "{d}", .{value})
    else
        "null";
    const timed_out_json = if (timed_out) |value|
        if (value) "true" else "false"
    else
        "null";
    const hook_summary = try hookSummaryFromEventLog(
        allocator,
        receipt.hook_policy,
        receipt.hook_log_path orelse event_log_path,
    );
    const hook_summary_json = try stringifyAnyAlloc(allocator, hook_summary);
    const structured_finding_count = if (status.review_result_available and
        reviewStatusHasTrustedResult(status))
        reviewFindingCount(allocator, status.review_result_json) catch null
    else
        null;
    const structured_finding_count_json = if (structured_finding_count) |count|
        try std.fmt.allocPrint(allocator, "{d}", .{count})
    else
        "null";
    const clean_json = if (structured_finding_count) |count|
        if (effective_failure == null and count == 0)
            "true"
        else
            "false"
    else
        "null";

    if (action == .wait) {
        if (identity) |target_identity| {
            const target_record = target orelse return error.MissingSessionTarget;
            if (review_verdict_json_opt) |review_verdict_json| {
                const synthetic_receipt_json = try casRunSyntheticReceiptJsonAlloc(
                    allocator,
                    cwd orelse "",
                    target_identity,
                    target_record,
                    parent_thread_id orelse "",
                    review_thread_id,
                    review_turn_id,
                    record_path orelse "",
                    event_log_path,
                    receipt,
                    review_verdict_json,
                );
                defer allocator.free(synthetic_receipt_json);
                const normalized = try normalizeReceiptFromJsonAlloc(
                    allocator,
                    record_path orelse event_log_path,
                    synthetic_receipt_json,
                    true,
                    .{
                        .requested_identity = target_identity,
                        .requested_identity_required = true,
                    },
                );
                defer normalized.deinit(allocator);
                const timestamp = try casRerTimestampAlloc(allocator);
                defer allocator.free(timestamp);
                const shadow_record_path = writeCasRerShadowRecordFromReceipt(allocator, normalized, .{
                    .command_surface = "start_wait",
                    .backend_selected = "cas-start-wait",
                    .broker_action = "created_new",
                    .broker_reason = "low-level wait output shadowed into CAS-RER-v1",
                    .timestamp = timestamp,
                }) catch null;
                defer if (shadow_record_path) |path| allocator.free(path);
            }
        }
    }
    const review_verdict_suffix = if (review_verdict_json_opt) |value|
        try std.fmt.allocPrint(allocator, ",\"reviewVerdict\":{s}", .{value})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(review_verdict_suffix);

    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":\"{s}\"",
        .{@tagName(action)},
    );
    try writeReviewAttemptStateFields(stdout, attempt_fields);
    try stdout.print(
        ",\"cwd\":{s},\"parentThreadId\":{s},\"reviewThreadId\":{s}," ++
            "\"reviewTurnId\":{s},\"threadStatus\":{s},\"turnStatus\":{s}," ++
            "\"turnCount\":{d},\"materialized\":{s},\"rolloutPath\":{s}," ++
            "\"recordPath\":{s},\"eventLogPath\":{s},\"target\":{s}," ++
            "\"targetFingerprint\":{s},\"headSha\":{s},\"baseSha\":{s}," ++
            "\"resolvedCodexPath\":{s},\"resolvedCodexVersion\":{s}," ++
            "\"compatibilityVerdict\":{s},\"selectedTransport\":{s}," ++
            "\"selectionReason\":{s},\"managedServerPid\":{s}," ++
            "\"managedServerListenUrl\":{s},\"managedServerStderrLogPath\":{s}," ++
            "\"orphanTtlSeconds\":{s},\"requestedMultiAgentMode\":{s}," ++
            "\"effectiveMultiAgentMode\":{s},\"multiAgentModeSupport\":{s}," ++
            "\"multiAgentModeMetricEligible\":{s}",
        .{
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
            managed_server_pid_json,
            managed_server_listen_url_json,
            managed_server_stderr_log_path_json,
            orphan_ttl_seconds_json,
            requested_multi_agent_mode_json,
            effective_multi_agent_mode_json,
            multi_agent_mode_support_json,
            if (receipt.multi_agent_mode_metric_eligible) "true" else "false",
        },
    );
    if (receipt.workflow_binding) |binding| {
        try stdout.writeAll(",\"workflowBinding\":");
        try std.json.Stringify.value(binding, .{}, stdout);
    }
    if (receipt.developer_instructions) |instructions| {
        try stdout.writeAll(",\"developerInstructions\":");
        try writeJsonString(stdout, instructions);
    }
    try stdout.print(
        ",\"timeoutMs\":{s},\"timedOut\":{s},\"failureCode\":{s}," ++
            "\"failureHint\":{s}{s},\"hookSummary\":{s}," ++
            "\"reviewResultAvailable\":{s},\"reviewResultSource\":{s}," ++
            "\"reviewResult\":{s},\"rawReviewText\":{s}," ++
            "\"structuredFindingCount\":{s},\"clean\":{s}{s}}}\n",
        .{
            timeout_json,
            timed_out_json,
            failure_code_json,
            failure_hint_json,
            failure_control_suffix,
            hook_summary_json,
            if (status.review_result_available) "true" else "false",
            review_result_source_json,
            review_result_json,
            review_text_json,
            structured_finding_count_json,
            clean_json,
            review_verdict_suffix,
        },
    );
}

fn startWaitReviewVerdictJsonAlloc(
    allocator: std.mem.Allocator,
    identity: TargetIdentity,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: []const u8,
    event_log_path: []const u8,
    receipt: OutputReceipt,
    status: ?ReviewStatus,
    timed_out: bool,
    waited: bool,
    failure: ?FailureInfo,
) !?[]u8 {
    if (!waited) return null;

    var effective_failure = failure;
    var clean: ?bool = false;
    var finding_count: ?usize = 0;
    var review_result_json: ?[]const u8 = null;

    if (timed_out and effective_failure == null) {
        effective_failure = .{
            .code = "wait_timed_out",
            .hint = "retry cas review wait on the same review thread or increase --timeout-ms",
        };
    }

    if (status) |value| {
        review_result_json = value.review_result_json;
        if (value.review_result_available) {
            if (!reviewStatusHasTrustedResult(value)) {
                if (effective_failure == null) effective_failure = reviewUntrustedSourceFailureInfo();
            } else {
                if (reviewFindingCount(allocator, value.review_result_json)) |count| {
                    finding_count = count;
                    clean = effective_failure == null and count == 0;
                } else |_| {
                    finding_count = null;
                    clean = false;
                    if (effective_failure == null) {
                        effective_failure = .{
                            .code = "review_output_invalid",
                            .hint = "structured reviewResult is malformed or " ++
                                "internally inconsistent",
                        };
                    }
                }
            }
        }
    }

    return try buildReviewVerdictJsonAlloc(
        allocator,
        "cas-start-wait",
        clean,
        finding_count,
        effective_failure,
        identity,
        receipt,
        review_thread_id,
        review_turn_id,
        if (record_path.len == 0) null else record_path,
        if (event_log_path.len == 0) null else event_log_path,
        review_result_json,
    );
}

fn casRunSyntheticReceiptJsonAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    identity: TargetIdentity,
    target: TargetRecord,
    parent_thread_id: []const u8,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: []const u8,
    event_log_path: []const u8,
    receipt: OutputReceipt,
    review_verdict_json: []const u8,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('{');
    try writeJsonString(writer, "demo");
    try writer.writeAll(":\"cas-review-session\",");
    try writeJsonString(writer, "action");
    try writer.writeAll(":\"run\",");
    try writeJsonString(writer, "cwd");
    try writer.writeByte(':');
    try writeJsonString(writer, cwd);
    try writer.writeByte(',');
    try writeJsonString(writer, "target");
    try writer.writeByte(':');
    try std.json.Stringify.value(target, .{}, writer);
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
    try writeJsonString(writer, "parentThreadId");
    try writer.writeByte(':');
    try writeJsonString(writer, parent_thread_id);
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
    try writeJsonString(writer, record_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "eventLogPath");
    try writer.writeByte(':');
    try writeJsonString(writer, event_log_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "resolvedCodexPath");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.resolved_codex_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "resolvedCodexVersion");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.resolved_codex_version);
    try writer.writeByte(',');
    try writeJsonString(writer, "accountFingerprint");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.account_fingerprint);
    try writer.writeByte(',');
    try writeJsonString(writer, "accountFingerprintReducedProtection");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.account_fingerprint_reduced_protection) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "codexThreadId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.codex_thread_id);
    try writer.writeByte(',');
    try writeJsonString(writer, "workflowBinding");
    try writer.writeByte(':');
    if (receipt.workflow_binding) |binding| {
        try std.json.Stringify.value(binding, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte(',');
    try writeJsonString(writer, "developerInstructions");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.developer_instructions);
    try writer.writeByte(',');
    try writeJsonString(writer, "principalStrength");
    try writer.writeByte(':');
    try writeJsonString(writer, if (receipt.account_fingerprint_reduced_protection) principal_strength_reduced else principal_strength_strong);
    try writer.writeByte(',');
    try writeJsonString(writer, "createdAtUnixS");
    try writer.writeByte(':');
    try writer.print("{d}", .{unixSeconds()});
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewVerdict");
    try writer.writeByte(':');
    try writer.writeAll(review_verdict_json);
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn startShadowReceiptPayloadJsonAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    parent_thread_id: []const u8,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: []const u8,
    event_log_path: []const u8,
    identity: TargetIdentity,
    target: TargetRecord,
    receipt: OutputReceipt,
    attempt_phase: []const u8,
) ![]u8 {
    const payload = .{
        .demo = "cas-review-session",
        .action = "start",
        .cwd = cwd,
        .parentThreadId = parent_thread_id,
        .reviewAttemptPhase = attempt_phase,
        .reviewAttemptExists = true,
        .tupleVerdictExists = false,
        .reviewThreadId = review_thread_id,
        .reviewTurnId = review_turn_id,
        .target = target,
        .baseSha = identity.base_sha,
        .headSha = identity.head_sha,
        .targetFingerprint = identity.fingerprint,
        .resolvedCodexPath = receipt.resolved_codex_path,
        .resolvedCodexVersion = receipt.resolved_codex_version,
        .codexThreadId = receipt.codex_thread_id,
        .recordPath = record_path,
        .eventLogPath = event_log_path,
        .accountFingerprint = receipt.account_fingerprint,
        .accountFingerprintReducedProtection = receipt.account_fingerprint_reduced_protection,
        .workflowBinding = receipt.workflow_binding,
        .developerInstructions = receipt.developer_instructions,
    };
    return stringifyAnyAlloc(allocator, payload);
}

fn printStartJson(
    backing_allocator: std.mem.Allocator,
    cwd: []const u8,
    parent_thread_id: []const u8,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    target_record: TargetRecord,
    identity: TargetIdentity,
    record_path: []const u8,
    event_log_path: []const u8,
    receipt: OutputReceipt,
    status: ?ReviewStatus,
    timed_out: bool,
    waited: bool,
    failure: ?FailureInfo,
) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer scratch_arena.deinit();
    const allocator = scratch_arena.allocator();
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    const effective_failure = failure;
    const target_json = try stringifyAnyAlloc(allocator, target_record);
    const attempt_phase = startReceiptReviewAttemptPhase(status, timed_out, effective_failure, review_thread_id);
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
    const requested_multi_agent_mode_json = try optionalModeJsonAlloc(allocator, receipt.requested_multi_agent_mode);
    const effective_multi_agent_mode_json = try optionalModeJsonAlloc(allocator, receipt.effective_multi_agent_mode);
    const multi_agent_mode_support_json = try modeSupportJsonAlloc(allocator, receipt.multi_agent_mode_support);
    const failure_code_json = if (effective_failure) |value| try quoteJsonStringAlloc(allocator, value.code) else "null";
    const failure_hint_json = if (effective_failure) |value| try quoteJsonStringAlloc(allocator, value.hint) else "null";
    const failure_control_suffix = try failureControlJsonSuffixAlloc(allocator, effective_failure);
    defer allocator.free(failure_control_suffix);
    const surface_action_json = try quoteJsonStringAlloc(allocator, receipt.surface_action);
    const broker_decision_json = if (receipt.review_broker_decision) |value| try stringifyAnyAlloc(allocator, value) else try allocator.dupe(u8, "null");
    defer allocator.free(broker_decision_json);
    const hook_summary = try hookSummaryFromEventLog(allocator, receipt.hook_policy, receipt.hook_log_path orelse event_log_path);
    const hook_summary_json = try stringifyAnyAlloc(allocator, hook_summary);
    const review_verdict_json_opt = try startWaitReviewVerdictJsonAlloc(
        allocator,
        identity,
        review_thread_id,
        review_turn_id,
        record_path,
        event_log_path,
        receipt,
        status,
        timed_out,
        waited,
        effective_failure,
    );
    defer if (review_verdict_json_opt) |value| allocator.free(value);
    const start_tuple_verdict_exists = startReceiptTupleVerdictExists(allocator, review_verdict_json_opt, review_thread_id, identity, status, timed_out);
    const attempt_fields = identityReviewAttemptFields(
        if (start_tuple_verdict_exists) "normalized_verdict" else attempt_phase,
        start_tuple_verdict_exists,
        review_thread_id,
        review_turn_id,
        identity,
    );
    const review_verdict_suffix = if (review_verdict_json_opt) |value|
        try std.fmt.allocPrint(allocator, ",\"reviewVerdict\":{s}", .{value})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(review_verdict_suffix);

    if (std.mem.eql(u8, receipt.surface_action, "start") and !waited and review_thread_id != null) {
        const payload_json = try startShadowReceiptPayloadJsonAlloc(
            allocator,
            cwd,
            parent_thread_id,
            review_thread_id,
            review_turn_id,
            record_path,
            event_log_path,
            identity,
            target_record,
            receipt,
            attempt_phase,
        );
        defer allocator.free(payload_json);
        const timestamp = try casRerTimestampAlloc(allocator);
        defer allocator.free(timestamp);
        const shadow_record_path = writeCasRerShadowRecordFromJsonAlloc(allocator, record_path, payload_json, .{
            .requested_identity = identity,
            .requested_identity_required = true,
        }, .{
            .command_surface = "start",
            .backend_selected = "cas-start",
            .broker_action = "created_new",
            .broker_reason = "low-level start output shadowed into CAS-RER-v1",
            .timestamp = timestamp,
        }) catch null;
        defer if (shadow_record_path) |path| allocator.free(path);
    }

    if (std.mem.eql(u8, receipt.surface_action, "run")) {
        if (review_verdict_json_opt) |review_verdict_json| {
            const synthetic_receipt_json = try casRunSyntheticReceiptJsonAlloc(
                allocator,
                cwd,
                identity,
                target_record,
                parent_thread_id,
                review_thread_id,
                review_turn_id,
                record_path,
                event_log_path,
                receipt,
                review_verdict_json,
            );
            defer allocator.free(synthetic_receipt_json);
            const normalized = try normalizeReceiptFromJsonAlloc(
                allocator,
                record_path,
                synthetic_receipt_json,
                true,
                .{
                    .requested_identity = identity,
                    .requested_identity_required = true,
                },
            );
            defer normalized.deinit(allocator);
            const broker = receipt.review_broker_decision orelse ReviewBrokerDecision{
                .action = "created_new",
                .reason = "run completed without an explicit broker decision",
                .reviewThreadId = review_thread_id,
                .recordPath = record_path,
                .eventLogPath = event_log_path,
            };
            try writeCasRunEnvelopeFromReceipt(
                allocator,
                stdout,
                normalized,
                broker,
                receipt.fresh_attempt_required,
            );
            try stdout.writeByte('\n');
            if (!normalizedReceiptCommandSucceeded(normalized)) std.process.exit(1);
            return;
        }
    } else if (std.mem.eql(u8, receipt.surface_action, "start") and waited) {
        if (review_verdict_json_opt) |review_verdict_json| {
            const synthetic_receipt_json = try casRunSyntheticReceiptJsonAlloc(
                allocator,
                cwd,
                identity,
                target_record,
                parent_thread_id,
                review_thread_id,
                review_turn_id,
                record_path,
                event_log_path,
                receipt,
                review_verdict_json,
            );
            defer allocator.free(synthetic_receipt_json);
            const normalized = try normalizeReceiptFromJsonAlloc(
                allocator,
                record_path,
                synthetic_receipt_json,
                true,
                .{
                    .requested_identity = identity,
                    .requested_identity_required = true,
                },
            );
            defer normalized.deinit(allocator);
            const timestamp = try casRerTimestampAlloc(allocator);
            defer allocator.free(timestamp);
            const shadow_record_path = writeCasRerShadowRecordFromReceipt(allocator, normalized, .{
                .command_surface = "start_wait",
                .backend_selected = "cas-start-wait",
                .broker_action = "created_new",
                .broker_reason = "low-level start --wait output shadowed into CAS-RER-v1",
                .timestamp = timestamp,
            }) catch null;
            defer if (shadow_record_path) |path| allocator.free(path);
        }
    }

    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":{s}," ++
            "\"reviewBrokerDecision\":{s},\"cwd\":{s},\"parentThreadId\":{s}",
        .{
            surface_action_json,
            broker_decision_json,
            try quoteJsonStringAlloc(allocator, cwd),
            try quoteJsonStringAlloc(allocator, parent_thread_id),
        },
    );
    try writeReviewAttemptFields(stdout, attempt_fields);
    try stdout.print(
        ",\"delivery\":\"detached\",\"target\":{s},\"recordPath\":{s}," ++
            "\"eventLogPath\":{s},\"codexVersion\":{s},\"resolvedCodexPath\":{s}," ++
            "\"resolvedCodexVersion\":{s},\"compatibilityVerdict\":{s}," ++
            "\"selectedTransport\":{s},\"selectionReason\":{s}," ++
            "\"managedServerPid\":{s},\"managedServerListenUrl\":{s}," ++
            "\"managedServerStderrLogPath\":{s},\"orphanTtlSeconds\":{s}," ++
            "\"requestedMultiAgentMode\":{s},\"effectiveMultiAgentMode\":{s}," ++
            "\"multiAgentModeSupport\":{s},\"multiAgentModeMetricEligible\":{s}," ++
            "\"waited\":{s},\"timedOut\":{s},\"threadStatus\":{s},\"turnStatus\":{s}",
        .{
            target_json,
            try quoteJsonStringAlloc(allocator, record_path),
            try quoteJsonStringAlloc(allocator, event_log_path),
            try quoteJsonStringAlloc(allocator, receipt.resolved_codex_version orelse ""),
            resolved_codex_path_json,
            resolved_codex_version_json,
            try quoteJsonStringAlloc(allocator, receipt.compatibility_verdict),
            selected_transport_json,
            selection_reason_json,
            managed_server_pid_json,
            managed_server_listen_url_json,
            managed_server_stderr_log_path_json,
            orphan_ttl_seconds_json,
            requested_multi_agent_mode_json,
            effective_multi_agent_mode_json,
            multi_agent_mode_support_json,
            if (receipt.multi_agent_mode_metric_eligible) "true" else "false",
            waited_json,
            timed_out_json,
            thread_status_json,
            turn_status_json,
        },
    );
    if (receipt.workflow_binding) |binding| {
        try stdout.writeAll(",\"workflowBinding\":");
        try std.json.Stringify.value(binding, .{}, stdout);
    }
    if (receipt.developer_instructions) |instructions| {
        try stdout.writeAll(",\"developerInstructions\":");
        try writeJsonString(stdout, instructions);
    }
    try stdout.print(
        ",\"turnCount\":{d},\"materialized\":{s},\"rolloutPath\":{s}," ++
            "\"failureCode\":{s},\"failureHint\":{s}{s},\"hookSummary\":{s}," ++
            "\"reviewResultAvailable\":{s},\"reviewResultSource\":{s}," ++
            "\"reviewResult\":{s}{s}}}\n",
        .{
            turn_count,
            materialized_json,
            rollout_path_json,
            failure_code_json,
            failure_hint_json,
            failure_control_suffix,
            hook_summary_json,
            review_result_available_json,
            review_result_source_json,
            review_result_json,
            review_verdict_suffix,
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
    if (detectAccountResourceExhaustion(raw_message)) return accountResourceExhaustedFailureInfo();
    if (created_parent_thread and std.mem.indexOf(u8, raw_message, "no rollout found for thread id") != null) {
        return .{
            .code = "incompatible_codex_review_runtime",
            .hint = "detached review on a freshly created parent thread requires a " ++
                "newer codex build; upgrade codex or supply --parent-thread-id for " ++
                "a materialized parent thread",
        };
    }
    if (created_parent_thread and
        std.mem.indexOf(u8, raw_message, "error creating detached review thread") != null and
        std.mem.indexOf(u8, raw_message, "(os error 2)") != null)
    {
        return .{
            .code = "incompatible_codex_review_runtime",
            .hint = "detached review on this codex build is incompatible with " ++
                "fresh parent-thread startup; upgrade codex or supply " ++
                "--parent-thread-id for a materialized parent thread",
        };
    }
    return null;
}

fn failureInfoForStatus(status: *const ReviewStatus) ?FailureInfo {
    if (isTerminalTurnStatus(status.turn_status) and
        if (status.turn_error_message) |message|
            detectAccountResourceExhaustion(message)
        else
            false)
    {
        return accountResourceExhaustedFailureInfo();
    }
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

fn terminalLockFailureForStatus(
    allocator: std.mem.Allocator,
    status: ReviewStatus,
) ?FailureInfo {
    if (status.review_result_available and !reviewStatusHasTrustedResult(status)) {
        return reviewUntrustedSourceFailureInfo();
    }
    if (status.review_result_available) {
        _ = reviewFindingCount(allocator, status.review_result_json) catch {
            return .{
                .code = "review_output_invalid",
                .hint = "structured reviewResult is malformed or internally inconsistent",
            };
        };
    }
    return null;
}

fn readReviewResultJsonFromRolloutAlloc(
    allocator: std.mem.Allocator,
    rollout_path: []const u8,
    review_turn_id: []const u8,
) !?[]u8 {
    if (std.mem.trim(u8, review_turn_id, " \t\r\n").len == 0) return error.InvalidReviewTurnId;
    const file = try std.Io.Dir.openFileAbsolute(
        std.Io.Threaded.global_single_threaded.io(),
        rollout_path,
        .{},
    );
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    const bytes = try reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);

    var latest_json: ?[]u8 = null;
    errdefer if (latest_json) |json| allocator.free(json);
    var active_turn_matches = false;
    var saw_review_turn = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            trimmed,
            .{},
        ) catch return error.InvalidRolloutRecord;
        defer parsed.deinit();

        const root_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidRolloutRecord,
        };
        const line_type = core_json.stringField(root_obj, "type") orelse continue;
        if (std.mem.eql(u8, line_type, "turn_context")) {
            const payload_obj = core_json.objectField(root_obj, "payload") orelse
                return error.InvalidReviewTurnBoundary;
            const observed_turn_id = core_json.stringField(payload_obj, "turn_id") orelse
                return error.InvalidReviewTurnBoundary;
            if (observed_turn_id.len == 0) return error.InvalidReviewTurnBoundary;
            active_turn_matches = std.mem.eql(u8, observed_turn_id, review_turn_id);
            saw_review_turn = saw_review_turn or active_turn_matches;
            continue;
        }
        if (!std.mem.eql(u8, line_type, "event_msg")) continue;
        const payload_obj = core_json.objectField(root_obj, "payload") orelse continue;
        const event_turn_matches = if (payload_obj.get("turn_id")) |turn_value| blk: {
            const observed_turn_id = switch (turn_value) {
                .string => |value| value,
                else => return error.InvalidReviewTurnBoundary,
            };
            if (observed_turn_id.len == 0) return error.InvalidReviewTurnBoundary;
            const matches = std.mem.eql(u8, observed_turn_id, review_turn_id);
            saw_review_turn = saw_review_turn or matches;
            break :blk matches;
        } else active_turn_matches;
        if (!event_turn_matches) continue;

        const payload_type = core_json.stringField(payload_obj, "type") orelse continue;
        if (!std.mem.eql(u8, payload_type, "exited_review_mode")) continue;

        const review_output = payload_obj.get("review_output") orelse
            return error.InvalidReviewOutput;
        const review_output_obj = switch (review_output) {
            .object => |obj| obj,
            else => return error.InvalidReviewOutput,
        };
        if (latest_json != null) return error.InvalidReviewOutput;
        const next_json = try buildReviewResultJsonAlloc(allocator, review_output_obj);
        latest_json = next_json;
    }

    if (!saw_review_turn) return error.MissingReviewTurnBoundary;
    return latest_json;
}

const ReviewResultFieldNames = struct {
    confidence_score: []const u8,
    code_location: []const u8,
    absolute_file_path: []const u8,
    line_range: []const u8,
    overall_correctness: []const u8,
    overall_explanation: []const u8,
    overall_confidence_score: []const u8,
};

const rollout_review_result_fields = ReviewResultFieldNames{
    .confidence_score = "confidence_score",
    .code_location = "code_location",
    .absolute_file_path = "absolute_file_path",
    .line_range = "line_range",
    .overall_correctness = "overall_correctness",
    .overall_explanation = "overall_explanation",
    .overall_confidence_score = "overall_confidence_score",
};

const canonical_review_result_fields = ReviewResultFieldNames{
    .confidence_score = "confidenceScore",
    .code_location = "codeLocation",
    .absolute_file_path = "absoluteFilePath",
    .line_range = "lineRange",
    .overall_correctness = "overallCorrectness",
    .overall_explanation = "overallExplanation",
    .overall_confidence_score = "overallConfidenceScore",
};

fn requiredNonEmptyReviewString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = core_json.stringField(obj, key) orelse return error.InvalidReviewOutput;
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.InvalidReviewOutput;
    return value;
}

fn requiredReviewConfidence(obj: std.json.ObjectMap, key: []const u8) !f32 {
    const value = floatField(obj, key) orelse return error.InvalidReviewOutput;
    if (!(value >= 0.0 and value <= 1.0)) return error.InvalidReviewOutput;
    return value;
}

fn requiredReviewPriority(obj: std.json.ObjectMap) !i32 {
    const value = core_json.intField(obj, "priority") orelse
        return error.InvalidReviewOutput;
    if (value < 0 or value > 3) return error.InvalidReviewOutput;
    return @intCast(value);
}

fn requiredReviewLine(obj: std.json.ObjectMap, key: []const u8) !u32 {
    const value = core_json.intField(obj, key) orelse return error.InvalidReviewOutput;
    if (value <= 0 or value > @as(i64, std.math.maxInt(u32))) {
        return error.InvalidReviewOutput;
    }
    return @intCast(value);
}

fn validateReviewResultObject(
    review_result_obj: std.json.ObjectMap,
    fields: ReviewResultFieldNames,
) !usize {
    const findings_value = review_result_obj.get("findings") orelse
        return error.InvalidReviewOutput;
    const findings = switch (findings_value) {
        .array => |value| value,
        else => return error.InvalidReviewOutput,
    };

    for (findings.items) |item| {
        const finding = switch (item) {
            .object => |value| value,
            else => return error.InvalidReviewOutput,
        };
        _ = try requiredNonEmptyReviewString(finding, "title");
        _ = try requiredNonEmptyReviewString(finding, "body");
        _ = try requiredReviewConfidence(finding, fields.confidence_score);
        _ = try requiredReviewPriority(finding);

        const code_location = core_json.objectField(finding, fields.code_location) orelse
            return error.InvalidReviewOutput;
        const absolute_file_path = try requiredNonEmptyReviewString(
            code_location,
            fields.absolute_file_path,
        );
        if (!std.fs.path.isAbsolute(absolute_file_path)) return error.InvalidReviewOutput;
        const line_range = core_json.objectField(code_location, fields.line_range) orelse
            return error.InvalidReviewOutput;
        const start = try requiredReviewLine(line_range, "start");
        const end = try requiredReviewLine(line_range, "end");
        if (end < start) return error.InvalidReviewOutput;
    }

    const correctness = try requiredNonEmptyReviewString(
        review_result_obj,
        fields.overall_correctness,
    );
    _ = try requiredNonEmptyReviewString(
        review_result_obj,
        fields.overall_explanation,
    );
    _ = try requiredReviewConfidence(
        review_result_obj,
        fields.overall_confidence_score,
    );
    const is_correct = std.mem.eql(u8, correctness, "patch is correct");
    const is_incorrect = std.mem.eql(u8, correctness, "patch is incorrect");
    if (!is_correct and !is_incorrect) return error.InvalidReviewOutput;
    if ((findings.items.len == 0) != is_correct) return error.InvalidReviewOutput;
    return findings.items.len;
}

fn buildReviewResultJsonAlloc(
    allocator: std.mem.Allocator,
    review_output_obj: std.json.ObjectMap,
) ![]u8 {
    _ = try validateReviewResultObject(review_output_obj, rollout_review_result_fields);
    var findings = std.ArrayList(ReviewFindingJson).empty;
    defer findings.deinit(allocator);

    const findings_array = review_output_obj.get("findings").?.array;
    for (findings_array.items) |item| {
        const finding_obj = item.object;
        const code_location_obj = core_json.objectField(
            finding_obj,
            "code_location",
        ).?;
        const line_range_obj = core_json.objectField(
            code_location_obj,
            "line_range",
        ).?;
        try findings.append(allocator, .{
            .title = core_json.stringField(finding_obj, "title").?,
            .body = core_json.stringField(finding_obj, "body").?,
            .confidenceScore = floatField(finding_obj, "confidence_score").?,
            .priority = @intCast(core_json.intField(finding_obj, "priority").?),
            .codeLocation = .{
                .absoluteFilePath = core_json.stringField(
                    code_location_obj,
                    "absolute_file_path",
                ).?,
                .lineRange = .{
                    .start = @intCast(core_json.intField(line_range_obj, "start").?),
                    .end = @intCast(core_json.intField(line_range_obj, "end").?),
                },
            },
        });
    }

    const payload = ReviewResultJson{
        .findings = try findings.toOwnedSlice(allocator),
        .overallCorrectness = core_json.stringField(
            review_output_obj,
            "overall_correctness",
        ).?,
        .overallExplanation = core_json.stringField(
            review_output_obj,
            "overall_explanation",
        ).?,
        .overallConfidenceScore = floatField(
            review_output_obj,
            "overall_confidence_score",
        ).?,
    };
    defer allocator.free(payload.findings);
    return stringifyAnyAlloc(allocator, payload);
}

fn reviewFindingCount(allocator: std.mem.Allocator, review_result_json: ?[]const u8) !usize {
    const raw = review_result_json orelse return 0;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidReviewOutput,
    };
    return validateReviewResultObject(root_obj, canonical_review_result_fields);
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

fn writeNullableJsonString(writer: *std.Io.Writer, text: ?[]const u8) !void {
    if (text) |value| try writeJsonString(writer, value) else try writer.writeAll("null");
}

fn nonEmptyOptional(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (value.len == 0) null else value;
}

fn reviewAttemptExists(review_thread_id: ?[]const u8) bool {
    return nonEmptyOptional(review_thread_id) != null;
}

fn receiptReviewAttemptExists(
    root: std.json.ObjectMap,
    review_thread_id: ?[]const u8,
) bool {
    if (reviewAttemptExists(review_thread_id)) return true;
    if (jsonBoolField(root, "reviewAttemptExists") orelse false) return true;
    if (root.get("reviewVerdict")) |value| switch (value) {
        .object => |verdict| {
            if (jsonBoolField(verdict, "reviewAttemptExists") orelse false) {
                return true;
            }
        },
        else => {},
    };
    return false;
}

fn identityReviewAttemptFields(
    phase: []const u8,
    tuple_verdict_exists: bool,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    identity: ?TargetIdentity,
) ReviewAttemptFields {
    const thread_id = nonEmptyOptional(review_thread_id);
    return .{
        .phase = phase,
        .review_attempt_exists = reviewAttemptExists(thread_id),
        .tuple_verdict_exists = tuple_verdict_exists,
        .review_thread_id = thread_id,
        .review_turn_id = nonEmptyOptional(review_turn_id),
        .base_sha = if (identity) |value| value.base_sha else null,
        .head_sha = if (identity) |value| value.head_sha else null,
        .target_fingerprint = if (identity) |value| value.fingerprint else null,
    };
}

fn statusReviewAttemptPhase(status: ?ReviewStatus, timed_out: ?bool) []const u8 {
    if (status) |value| {
        if (isTerminalTurnStatus(value.turn_status)) return "review_terminal";
        return "review_waiting";
    }
    if (timed_out orelse false) return "review_waiting";
    return "review_started";
}

fn startReceiptReviewAttemptPhase(status: ?ReviewStatus, timed_out: bool, failure: ?FailureInfo, review_thread_id: ?[]const u8) []const u8 {
    if (failure) |value| {
        if (terminalReviewOwnerFailure(value.code) != null) {
            return if (reviewAttemptExists(review_thread_id)) "review_terminal" else "pre_review_start";
        }
        if (failureCodeIsAccountResourceExhausted(value.code)) {
            return if (reviewAttemptExists(review_thread_id)) "review_terminal" else "pre_review_start";
        }
    }
    return statusReviewAttemptPhase(status, timed_out);
}

fn startReceiptTupleVerdictExists(
    allocator: std.mem.Allocator,
    review_verdict_json_opt: ?[]const u8,
    review_thread_id: ?[]const u8,
    identity: TargetIdentity,
    status: ?ReviewStatus,
    timed_out: bool,
) bool {
    if (timed_out) return false;
    if (status) |value| {
        if (!value.review_result_available) return false;
    }
    const review_verdict_json = review_verdict_json_opt orelse return false;
    if (!reviewVerdictJsonTupleVerdictExists(allocator, review_verdict_json)) return false;
    return reviewAttemptExists(review_thread_id) and identityHasCompleteTuple(identity);
}

fn reviewVerdictJsonTupleVerdictExists(allocator: std.mem.Allocator, review_verdict_json: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, review_verdict_json, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return false,
    };
    return jsonBoolField(root, "tupleVerdictExists") orelse false;
}

fn errorReviewAttemptPhase(action: []const u8, method: []const u8) []const u8 {
    _ = action;
    if (std.mem.eql(u8, method, "review/start")) return "pre_review_start";
    return "pre_review_start";
}

fn writeReviewAttemptFields(writer: *std.Io.Writer, fields: ReviewAttemptFields) !void {
    try writer.writeAll(",\"reviewAttemptPhase\":");
    try writeJsonString(writer, fields.phase);
    try writer.writeAll(",\"reviewAttemptExists\":");
    try writer.writeAll(if (fields.review_attempt_exists) "true" else "false");
    try writer.writeAll(",\"tupleVerdictExists\":");
    try writer.writeAll(if (fields.tuple_verdict_exists) "true" else "false");
    try writer.writeAll(",\"reviewThreadId\":");
    try writeNullableJsonString(writer, fields.review_thread_id);
    try writer.writeAll(",\"reviewTurnId\":");
    try writeNullableJsonString(writer, fields.review_turn_id);
    try writer.writeAll(",\"baseSha\":");
    try writeNullableJsonString(writer, fields.base_sha);
    try writer.writeAll(",\"headSha\":");
    try writeNullableJsonString(writer, fields.head_sha);
    try writer.writeAll(",\"targetFingerprint\":");
    try writeNullableJsonString(writer, fields.target_fingerprint);
}

fn writeReviewAttemptStateFields(writer: *std.Io.Writer, fields: ReviewAttemptFields) !void {
    try writer.writeAll(",\"reviewAttemptPhase\":");
    try writeJsonString(writer, fields.phase);
    try writer.writeAll(",\"reviewAttemptExists\":");
    try writer.writeAll(if (fields.review_attempt_exists) "true" else "false");
    try writer.writeAll(",\"tupleVerdictExists\":");
    try writer.writeAll(if (fields.tuple_verdict_exists) "true" else "false");
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.Io.Dir.openFileAbsolute(
            std.Io.Threaded.global_single_threaded.io(),
            path,
            .{},
        );
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(max_bytes));
    }
    var file = try std.Io.Dir.cwd().openFile(
        std.Io.Threaded.global_single_threaded.io(),
        path,
        .{},
    );
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var reader = file.reader(std.Io.Threaded.global_single_threaded.io(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn objectField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |child| child,
        else => null,
    };
}

fn objectFieldOrGateError(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    errors: *std.ArrayList([]const u8),
) !?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .object => |child| child,
        .null => null,
        else => {
            try appendGateError(allocator, errors, "{s} must be an object", .{key});
            return null;
        },
    };
}

fn fieldPresentNonNull(obj: std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return false;
    return switch (value) {
        .null => false,
        else => true,
    };
}

fn jsonFieldAsJsonAlloc(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| try allocator.dupe(u8, text),
        else => try stringifyJsonValueAlloc(allocator, value),
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

fn receiptCreatedAtUnixS(root: std.json.ObjectMap) ?i64 {
    return jsonI64Field(root, "createdAtUnixS") orelse jsonI64Field(root, "created_at_unix_s");
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

fn optionalBoolFromVerdictOrRoot(verdict: std.json.ObjectMap, root: std.json.ObjectMap, key: []const u8) ?bool {
    return jsonBoolField(verdict, key) orelse jsonBoolField(root, key);
}

fn receiptPrincipalReduced(verdict: std.json.ObjectMap, root: std.json.ObjectMap) bool {
    if (optionalBoolFromVerdictOrRoot(verdict, root, "accountFingerprintReducedProtection")) |value| return value;
    return true;
}

fn receiptPrincipalStrength(verdict: std.json.ObjectMap, root: std.json.ObjectMap) []const u8 {
    if (optionalStringFromVerdictOrRoot(verdict, root, "principalStrength")) |value| {
        if (std.mem.eql(u8, value, principal_strength_strong)) return principal_strength_strong;
        return principal_strength_reduced;
    }
    return if (receiptPrincipalReduced(verdict, root)) principal_strength_reduced else principal_strength_strong;
}

fn optionalStringFromRootKeys(root: std.json.ObjectMap, primary: []const u8, secondary: []const u8) ?[]const u8 {
    return jsonStringField(root, primary) orelse jsonStringField(root, secondary);
}

fn receiptRepoRealpathAlloc(allocator: std.mem.Allocator, root: std.json.ObjectMap) !?[]const u8 {
    if (optionalStringFromRootKeys(root, "repoRealpath", "repo_realpath")) |value| return try allocator.dupe(u8, value);
    if (optionalStringFromRootKeys(root, "cwd", "repo")) |cwd| return repoRealpathAlloc(allocator, cwd) catch try allocator.dupe(u8, cwd);
    return null;
}

fn receiptResolvedCodexPath(root: std.json.ObjectMap) ?[]const u8 {
    return optionalStringFromRootKeys(root, "resolvedCodexPath", "resolved_codex_path");
}

fn receiptResolvedCodexVersion(root: std.json.ObjectMap) ?[]const u8 {
    return jsonStringField(root, "resolvedCodexVersion") orelse
        jsonStringField(root, "resolved_codex_version") orelse
        jsonStringField(root, "codexVersion") orelse
        jsonStringField(root, "codex_version");
}

fn receiptCodexThreadId(root: std.json.ObjectMap) ?[]const u8 {
    return optionalStringFromRootKeys(root, "codexThreadId", "codex_thread_id");
}

fn receiptAccountFingerprint(verdict: std.json.ObjectMap, root: std.json.ObjectMap) ?[]const u8 {
    return optionalStringFromVerdictOrRoot(verdict, root, "accountFingerprint");
}

fn optionalStringFromRootKey(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, "baseSha")) return optionalStringFromRootKeys(root, "baseSha", "base_sha");
    if (std.mem.eql(u8, key, "headSha")) return optionalStringFromRootKeys(root, "headSha", "head_sha");
    if (std.mem.eql(u8, key, "targetFingerprint")) return optionalStringFromRootKeys(root, "targetFingerprint", "target_fingerprint");
    return jsonStringField(root, key);
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn rootFieldMatchesIfPresent(root: std.json.ObjectMap, key: []const u8, verdict_value: ?[]const u8) bool {
    const root_value = optionalStringFromRootKey(root, key) orelse return true;
    return optionalStringsEqual(root_value, verdict_value);
}

fn rootTupleMatchesIdentity(root: std.json.ObjectMap, identity: TargetIdentity) bool {
    return optionalStringsEqual(optionalStringFromRootKey(root, "baseSha"), identity.base_sha) and
        optionalStringsEqual(optionalStringFromRootKey(root, "headSha"), identity.head_sha) and
        optionalStringsEqual(optionalStringFromRootKey(root, "targetFingerprint"), identity.fingerprint);
}

fn rootTupleFieldsMatchIdentityIfPresent(root: std.json.ObjectMap, identity: TargetIdentity) bool {
    return rootFieldMatchesIfPresent(root, "baseSha", identity.base_sha) and
        rootFieldMatchesIfPresent(root, "headSha", identity.head_sha) and
        rootFieldMatchesIfPresent(root, "targetFingerprint", identity.fingerprint);
}

fn rootHasTupleVerdictBinding(root: std.json.ObjectMap) bool {
    const base_sha = optionalStringFromRootKey(root, "baseSha") orelse return false;
    if (base_sha.len == 0) return false;
    const head_sha = optionalStringFromRootKey(root, "headSha") orelse return false;
    if (head_sha.len == 0) return false;
    const target_fingerprint = optionalStringFromRootKey(root, "targetFingerprint") orelse return false;
    return target_fingerprint.len != 0;
}

fn normalizedReceiptCommandSucceeded(receipt: NormalizedReceipt) bool {
    return receipt.tuple_verdict_exists and receipt.clean and casRerPrincipalProofUsable(receipt);
}

fn verdictTupleMatchesIdentity(verdict: std.json.ObjectMap, identity: TargetIdentity) bool {
    return optionalStringsEqual(jsonStringField(verdict, "baseSha"), identity.base_sha) and
        optionalStringsEqual(jsonStringField(verdict, "headSha"), identity.head_sha) and
        optionalStringsEqual(jsonStringField(verdict, "targetFingerprint"), identity.fingerprint);
}

fn verdictHasTupleBinding(verdict: std.json.ObjectMap, root: std.json.ObjectMap, root_has_verdict: bool) bool {
    const base_sha = jsonStringField(verdict, "baseSha") orelse return false;
    if (base_sha.len == 0) return false;
    const head_sha = jsonStringField(verdict, "headSha") orelse return false;
    if (head_sha.len == 0) return false;
    const target_fingerprint = jsonStringField(verdict, "targetFingerprint") orelse return false;
    if (target_fingerprint.len == 0) return false;
    if (!root_has_verdict) return true;
    return rootFieldMatchesIfPresent(root, "targetFingerprint", target_fingerprint) and
        rootFieldMatchesIfPresent(root, "baseSha", base_sha) and
        rootFieldMatchesIfPresent(root, "headSha", head_sha);
}

fn terminalReceiptStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "clean") or
        std.mem.eql(u8, status, "findings") or
        std.mem.eql(u8, status, "timeout") or
        std.mem.eql(u8, status, "pre_review_transport_failure") or
        std.mem.eql(u8, status, "account_resource_exhausted") or
        std.mem.eql(u8, status, "review_transport_failure") or
        std.mem.eql(u8, status, "incomplete");
}

fn normalizedAttemptPhase(root: std.json.ObjectMap, status: []const u8, tuple_verdict_exists: bool, review_thread_id: ?[]const u8) []const u8 {
    if (tuple_verdict_exists) return "normalized_verdict";
    if (jsonStringField(root, "reviewAttemptPhase")) |phase| return phase;
    if (root.get("reviewVerdict")) |value| switch (value) {
        .object => |verdict| {
            if (jsonStringField(verdict, "reviewAttemptPhase")) |phase| return phase;
        },
        else => {},
    };
    if (reviewAttemptExists(review_thread_id)) {
        if (std.mem.eql(u8, status, "timeout")) return "review_waiting";
        if (std.mem.eql(u8, status, "review_transport_failure")) return "review_waiting";
        if (terminalReceiptStatus(status)) return "review_terminal";
        return "review_waiting";
    }
    return "pre_review_start";
}

fn stringifyJsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn canonicalWorkflowBindingJsonFromValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const raw = try stringifyJsonValueAlloc(allocator, value);
    defer allocator.free(raw);
    if (std.json.parseFromSlice(WorkflowBinding, allocator, raw, .{}) catch null) |parsed_value| {
        var parsed = parsed_value;
        defer parsed.deinit();
        try validateWorkflowBinding(parsed.value);
        return stringifyAnyAlloc(allocator, parsed.value);
    }

    return error.InvalidWorkflowBinding;
}

fn workflowBindingJsonFromRootAlloc(allocator: std.mem.Allocator, root: std.json.ObjectMap) !?[]const u8 {
    const nested_value: ?std.json.Value = if (root.get("record")) |record_value| switch (record_value) {
        .object => |record| record.get("workflowBinding"),
        else => null,
    } else null;
    const candidates = [_]?std.json.Value{
        root.get("workflowBinding"),
        nested_value,
    };
    var canonical: ?[]const u8 = null;
    errdefer if (canonical) |value| allocator.free(value);
    var saw_explicit_null = false;
    for (candidates) |candidate| {
        const value = candidate orelse continue;
        switch (value) {
            .null => {
                if (canonical != null) return error.InvalidWorkflowBinding;
                saw_explicit_null = true;
            },
            .object => {
                if (saw_explicit_null) return error.InvalidWorkflowBinding;
                const next = try canonicalWorkflowBindingJsonFromValueAlloc(allocator, value);
                if (canonical) |existing| {
                    defer allocator.free(next);
                    if (!std.mem.eql(u8, existing, next)) return error.InvalidWorkflowBinding;
                } else {
                    canonical = next;
                }
            },
            else => return error.InvalidWorkflowBinding,
        }
    }
    return canonical;
}

fn readRolloutReviewResultFromEventLogAlloc(
    allocator: std.mem.Allocator,
    event_log_path: []const u8,
    review_thread_id: []const u8,
    review_turn_id: []const u8,
) !?[]u8 {
    const raw = try readFileAlloc(allocator, event_log_path, 16 * 1024 * 1024);
    defer allocator.free(raw);

    var latest_review_result: ?[]u8 = null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();
        const root_obj = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        const method = jsonStringField(root_obj, "method") orelse continue;
        if (!std.mem.eql(u8, method, "thread/read")) continue;
        const direction = jsonStringField(root_obj, "direction") orelse continue;
        if (!std.mem.eql(u8, direction, "response")) continue;

        const payload_text = jsonStringField(root_obj, "payload") orelse continue;
        var payload_parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_text, .{}) catch continue;
        defer payload_parsed.deinit();
        const payload_obj = switch (payload_parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        const thread_obj = core_json.objectField(payload_obj, "thread") orelse continue;
        const observed_thread_id = core_json.stringField(thread_obj, "id") orelse continue;
        if (!std.mem.eql(u8, observed_thread_id, review_thread_id)) continue;
        const rollout_path = core_json.stringField(thread_obj, "path") orelse continue;
        const review_result = (try readReviewResultJsonFromRolloutAlloc(
            allocator,
            rollout_path,
            review_turn_id,
        )) orelse continue;
        if (latest_review_result) |existing| allocator.free(existing);
        latest_review_result = review_result;
    }
    return latest_review_result;
}

fn normalizeReceiptFromPathAlloc(allocator: std.mem.Allocator, path: []const u8, recover_event_logs: bool, context: NormalizeContext) !NormalizedReceipt {
    const raw = try readFileAlloc(allocator, path, 8 * 1024 * 1024);
    defer allocator.free(raw);
    return normalizeReceiptFromJsonAlloc(allocator, path, raw, recover_event_logs, context);
}

fn tupleVerdictExistsForContext(verdict: std.json.ObjectMap, root: std.json.ObjectMap, root_has_verdict: bool, context: NormalizeContext) bool {
    if (context.requested_identity_required) {
        const requested = context.requested_identity orelse return false;
        if (!identityHasCompleteTuple(requested)) return false;
        return verdictTupleMatchesIdentity(verdict, requested) and (!root_has_verdict or rootTupleFieldsMatchIdentityIfPresent(root, requested));
    }
    return verdictHasTupleBinding(verdict, root, root_has_verdict);
}

fn tupleBindingFailureCode(verdict: std.json.ObjectMap, root: std.json.ObjectMap, root_has_verdict: bool, context: NormalizeContext) ?[]const u8 {
    if (!context.requested_identity_required) return null;
    const requested = context.requested_identity orelse return "target_identity_unavailable";
    if (!identityHasCompleteTuple(requested)) return "target_identity_unavailable";
    if (!verdictTupleMatchesIdentity(verdict, requested)) return "tuple_mismatch";
    if (root_has_verdict and !rootTupleFieldsMatchIdentityIfPresent(root, requested)) return "tuple_mismatch";
    return null;
}

fn normalizeReceiptFromJsonAlloc(allocator: std.mem.Allocator, source_path: []const u8, raw: []const u8, recover_event_logs: bool, context: NormalizeContext) !NormalizedReceipt {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidReceiptJson,
    };
    const verdict_value = root.get("reviewVerdict");
    const root_has_verdict = if (verdict_value) |value| switch (value) {
        .object => true,
        .null => false,
        else => return error.InvalidReviewVerdict,
    } else false;
    const verdict = if (root_has_verdict) verdict_value.?.object else root;

    if (!root_has_verdict and
        jsonStringField(root, "reviewAttemptPhase") != null and
        !terminalReceiptStatus(jsonStringField(root, "status") orelse "") and
        !std.mem.eql(u8, jsonStringField(root, "action") orelse "", "start"))
    {
        return normalizeAttemptOnlyReceiptAlloc(allocator, source_path, root, context);
    }
    if (jsonStringField(verdict, "status") == null) {
        if (jsonStringField(root, "action")) |action| {
            if (std.mem.eql(u8, action, "start")) {
                return normalizeStartReceiptAlloc(allocator, source_path, root, context);
            }
        }
        if (jsonStringField(root, "reviewAttemptPhase") != null or jsonStringField(root, "failureCode") != null) {
            return normalizeAttemptOnlyReceiptAlloc(allocator, source_path, root, context);
        }
        return normalizeStoredSessionRecordReceiptAlloc(allocator, source_path, root, recover_event_logs, context);
    }

    const receipt_status = jsonStringField(verdict, "status") orelse return error.MissingReceiptStatus;
    const backend_class = jsonStringField(verdict, "backendClass") orelse return error.MissingBackendClass;
    const clean = jsonBoolField(verdict, "clean") orelse return error.MissingCleanFlag;
    const finding_count = jsonUsizeField(verdict, "findingCount") orelse return error.MissingFindingCount;
    const review_thread_id = optionalStringFromVerdictOrRoot(verdict, root, "reviewThreadId");
    const review_attempt_exists = receiptReviewAttemptExists(root, review_thread_id);
    const account_failure = rootHasStructuredAccountResourceExhaustion(root) or
        if (optionalStringFromVerdictOrRoot(verdict, root, "failureCode")) |code| failureCodeIsAccountResourceExhausted(code) else false;
    const raw_failure_code = optionalStringFromVerdictOrRoot(verdict, root, "failureCode");
    const status_without_binding = if (account_failure and !review_attempt_exists)
        "incomplete"
    else if (account_failure)
        "account_resource_exhausted"
    else if (review_attempt_exists and
        if (raw_failure_code) |code|
            std.mem.indexOf(u8, code, "transport") != null
        else
            false)
        "review_transport_failure"
    else
        canonicalReceiptStatus(receipt_status, raw_failure_code, review_thread_id);
    const binding_failure = if (reviewVerdictStatusIsTupleTerminal(status_without_binding))
        tupleBindingFailureCode(verdict, root, root_has_verdict, context)
    else
        null;
    const final_failure_code = binding_failure orelse if (account_failure) "account_resource_exhausted" else raw_failure_code;
    const final_status = if (binding_failure != null) "incomplete" else status_without_binding;
    const tuple_verdict_exists = binding_failure == null and
        reviewVerdictStatusIsTupleTerminal(final_status) and
        tupleVerdictExistsForContext(verdict, root, root_has_verdict, context);
    const final_clean = if (binding_failure != null) false else clean;
    const final_failure_hint = if (binding_failure) |code|
        if (std.mem.eql(u8, code, "target_identity_unavailable"))
            "requested target identity could not be computed for receipt normalization"
        else
            "reviewVerdict tuple did not match the requested target identity"
    else if (account_failure) account_resource_exhausted_hint else optionalStringFromVerdictOrRoot(verdict, root, "failureHint");
    const final_failure_class = optionalStringFromVerdictOrRoot(verdict, root, "failureClass") orelse failureClassForCode(final_failure_code);
    const final_retryable_same_tuple_now = jsonBoolField(root, "retryableSameTupleNow") orelse retryableSameTupleNowForCode(final_failure_code);
    const review_attempt_phase = if (account_failure and review_attempt_exists)
        "review_terminal"
    else
        normalizedAttemptPhase(root, final_status, tuple_verdict_exists, review_thread_id);
    const findings_json = if (verdict.get("findings")) |value|
        try stringifyJsonValueAlloc(allocator, value)
    else
        try allocator.dupe(u8, "[]");
    const account_fingerprint_reduced_protection = receiptPrincipalReduced(verdict, root);
    const principal_strength = receiptPrincipalStrength(verdict, root);
    const target_json = try targetRecordJsonFromRootAlloc(allocator, root);
    errdefer if (target_json) |value| allocator.free(value);

    return .{
        .source_path = try allocator.dupe(u8, source_path),
        .status = try allocator.dupe(u8, final_status),
        .backend_class = try allocator.dupe(u8, backend_class),
        .clean = final_clean,
        .finding_count = finding_count,
        .review_attempt_phase = try allocator.dupe(u8, review_attempt_phase),
        .review_attempt_exists = review_attempt_exists,
        .tuple_verdict_exists = tuple_verdict_exists,
        .principal_strength = principal_strength,
        .account_fingerprint_reduced_protection = account_fingerprint_reduced_protection,
        .base_sha = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "baseSha")),
        .head_sha = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "headSha")),
        .target_fingerprint = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "targetFingerprint")),
        .target_json = target_json,
        .repo_realpath = try receiptRepoRealpathAlloc(allocator, root),
        .resolved_codex_path = try dupOptional(allocator, receiptResolvedCodexPath(root)),
        .resolved_codex_version = try dupOptional(allocator, receiptResolvedCodexVersion(root)),
        .codex_thread_id = try dupOptional(allocator, receiptCodexThreadId(root)),
        .account_fingerprint = try dupOptional(allocator, receiptAccountFingerprint(verdict, root)),
        .review_thread_id = try dupOptional(allocator, review_thread_id),
        .review_turn_id = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "reviewTurnId")),
        .record_path = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "recordPath")),
        .event_log_path = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "eventLogPath")),
        .attempt_created_at_unix_s = receiptCreatedAtUnixS(root),
        .failure_code = try dupOptional(allocator, final_failure_code),
        .failure_hint = try dupOptional(allocator, final_failure_hint),
        .failure_class = try dupOptional(allocator, final_failure_class),
        .retryable_same_tuple_now = final_retryable_same_tuple_now,
        .findings_json = findings_json,
        .workflow_binding_json = try workflowBindingJsonFromRootAlloc(allocator, root),
    };
}

fn normalizeAttemptOnlyReceiptAlloc(allocator: std.mem.Allocator, source_path: []const u8, root: std.json.ObjectMap, context: NormalizeContext) !NormalizedReceipt {
    const review_thread_id = jsonStringField(root, "reviewThreadId");
    const review_attempt_exists = receiptReviewAttemptExists(root, review_thread_id);
    const failure_code = jsonStringField(root, "failureCode");
    const account_failure = if (failure_code) |code|
        failureCodeIsAccountResourceExhausted(code) or
            rootHasStructuredAccountResourceExhaustion(root)
    else
        rootHasStructuredAccountResourceExhaustion(root);
    const status = if (!review_attempt_exists)
        "incomplete"
    else if (account_failure)
        "account_resource_exhausted"
    else if (failure_code) |code|
        if (std.mem.indexOf(u8, code, "transport") != null)
            "review_transport_failure"
        else
            reviewVerdictStatus(false, 0, .{ .code = code, .hint = jsonStringField(root, "failureHint") orelse "" }, review_thread_id)
    else
        "incomplete";
    _ = context;
    const tuple_verdict_exists = false;
    const account_fingerprint_reduced_protection = receiptPrincipalReduced(root, root);
    const principal_strength = receiptPrincipalStrength(root, root);
    const target_json = try targetRecordJsonFromRootAlloc(allocator, root);
    errdefer if (target_json) |value| allocator.free(value);
    return .{
        .source_path = try allocator.dupe(u8, source_path),
        .status = try allocator.dupe(u8, status),
        .backend_class = try allocator.dupe(u8, "cas-receipt-normalized"),
        .clean = false,
        .finding_count = 0,
        .review_attempt_phase = try allocator.dupe(u8, normalizedAttemptPhase(root, status, tuple_verdict_exists, review_thread_id)),
        .review_attempt_exists = review_attempt_exists,
        .tuple_verdict_exists = tuple_verdict_exists,
        .principal_strength = principal_strength,
        .account_fingerprint_reduced_protection = account_fingerprint_reduced_protection,
        .base_sha = try dupOptional(allocator, jsonStringField(root, "baseSha")),
        .head_sha = try dupOptional(allocator, jsonStringField(root, "headSha")),
        .target_fingerprint = try dupOptional(allocator, jsonStringField(root, "targetFingerprint")),
        .target_json = target_json,
        .repo_realpath = try receiptRepoRealpathAlloc(allocator, root),
        .resolved_codex_path = try dupOptional(allocator, receiptResolvedCodexPath(root)),
        .resolved_codex_version = try dupOptional(allocator, receiptResolvedCodexVersion(root)),
        .codex_thread_id = try dupOptional(allocator, receiptCodexThreadId(root)),
        .account_fingerprint = try dupOptional(allocator, receiptAccountFingerprint(root, root)),
        .review_thread_id = try dupOptional(allocator, review_thread_id),
        .review_turn_id = try dupOptional(allocator, jsonStringField(root, "reviewTurnId")),
        .record_path = try dupOptional(allocator, jsonStringField(root, "recordPath")),
        .event_log_path = try dupOptional(allocator, jsonStringField(root, "eventLogPath")),
        .attempt_created_at_unix_s = receiptCreatedAtUnixS(root),
        .failure_code = try dupOptional(allocator, if (account_failure) "account_resource_exhausted" else failure_code),
        .failure_hint = try dupOptional(allocator, if (account_failure) account_resource_exhausted_hint else jsonStringField(root, "failureHint")),
        .failure_class = try dupOptional(allocator, if (account_failure) "account_resource" else failureClassForCode(failure_code)),
        .retryable_same_tuple_now = if (account_failure) false else retryableSameTupleNowForCode(failure_code),
        .findings_json = try allocator.dupe(u8, "[]"),
        .workflow_binding_json = try workflowBindingJsonFromRootAlloc(allocator, root),
    };
}

fn normalizeStartReceiptAlloc(allocator: std.mem.Allocator, source_path: []const u8, root: std.json.ObjectMap, context: NormalizeContext) !NormalizedReceipt {
    const review_thread_id = jsonStringField(root, "reviewThreadId");
    const review_attempt_exists = receiptReviewAttemptExists(root, review_thread_id);
    const failure_code = jsonStringField(root, "failureCode");
    const review_result_json = try jsonFieldAsJsonAlloc(allocator, root, "reviewResult");
    defer if (review_result_json) |value| allocator.free(value);
    const finding_count = try reviewFindingCount(allocator, review_result_json);
    const account_failure = if (failure_code) |code|
        failureCodeIsAccountResourceExhausted(code) or
            rootHasStructuredAccountResourceExhaustion(root)
    else
        rootHasStructuredAccountResourceExhaustion(root);
    const timed_out = jsonBoolField(root, "timedOut") orelse false;
    const status = if (account_failure and !review_attempt_exists)
        "incomplete"
    else if (account_failure)
        "account_resource_exhausted"
    else if (failure_code) |code|
        if (std.mem.indexOf(u8, code, "transport") != null)
            if (review_attempt_exists)
                "review_transport_failure"
            else
                "incomplete"
        else if (timed_out)
            "timeout"
        else if (!review_attempt_exists)
            "incomplete"
        else
            reviewVerdictStatus(false, finding_count, .{ .code = code, .hint = jsonStringField(root, "failureHint") orelse "" }, review_thread_id)
    else if (timed_out)
        "timeout"
    else if (!review_attempt_exists)
        "incomplete"
    else if (finding_count > 0)
        "findings"
    else if (review_result_json != null)
        "clean"
    else
        "incomplete";
    const binding_failure = if (context.requested_identity_required) blk: {
        const requested = context.requested_identity orelse break :blk "target_identity_unavailable";
        if (!identityHasCompleteTuple(requested)) break :blk "target_identity_unavailable";
        break :blk if (rootTupleMatchesIdentity(root, requested)) @as(?[]const u8, null) else "tuple_mismatch";
    } else null;
    const final_status = if (binding_failure != null) "incomplete" else status;
    const final_clean = binding_failure == null and std.mem.eql(u8, final_status, "clean");
    const final_failure_code = binding_failure orelse if (account_failure) "account_resource_exhausted" else failure_code;
    const final_failure_hint = if (binding_failure) |code|
        if (std.mem.eql(u8, code, "target_identity_unavailable"))
            "requested target identity could not be computed for receipt normalization"
        else
            "reviewVerdict tuple did not match the requested target identity"
    else if (account_failure) account_resource_exhausted_hint else jsonStringField(root, "failureHint");
    const final_failure_class = jsonStringField(root, "failureClass") orelse failureClassForCode(final_failure_code);
    const final_retryable_same_tuple_now = jsonBoolField(root, "retryableSameTupleNow") orelse retryableSameTupleNowForCode(final_failure_code);
    const tuple_verdict_exists = binding_failure == null and
        reviewVerdictStatusIsTupleTerminal(final_status) and
        if (context.requested_identity_required)
            rootTupleMatchesIdentity(root, context.requested_identity.?)
        else
            rootHasTupleVerdictBinding(root);
    const findings_json = compactFindingsJsonAlloc(allocator, review_result_json) catch try allocator.dupe(u8, "[]");
    const account_fingerprint_reduced_protection = receiptPrincipalReduced(root, root);
    const principal_strength = receiptPrincipalStrength(root, root);
    const target_json = try targetRecordJsonFromRootAlloc(allocator, root);
    errdefer if (target_json) |value| allocator.free(value);
    return .{
        .source_path = try allocator.dupe(u8, source_path),
        .status = try allocator.dupe(u8, final_status),
        .backend_class = try allocator.dupe(u8, "cas-start-wait"),
        .clean = final_clean,
        .finding_count = finding_count,
        .review_attempt_phase = try allocator.dupe(u8, normalizedAttemptPhase(root, final_status, tuple_verdict_exists, review_thread_id)),
        .review_attempt_exists = review_attempt_exists,
        .tuple_verdict_exists = tuple_verdict_exists,
        .principal_strength = principal_strength,
        .account_fingerprint_reduced_protection = account_fingerprint_reduced_protection,
        .base_sha = try dupOptional(allocator, jsonStringField(root, "baseSha")),
        .head_sha = try dupOptional(allocator, jsonStringField(root, "headSha")),
        .target_fingerprint = try dupOptional(allocator, jsonStringField(root, "targetFingerprint")),
        .target_json = target_json,
        .repo_realpath = try receiptRepoRealpathAlloc(allocator, root),
        .resolved_codex_path = try dupOptional(allocator, receiptResolvedCodexPath(root)),
        .resolved_codex_version = try dupOptional(allocator, receiptResolvedCodexVersion(root)),
        .codex_thread_id = try dupOptional(allocator, receiptCodexThreadId(root)),
        .account_fingerprint = try dupOptional(allocator, receiptAccountFingerprint(root, root)),
        .review_thread_id = try dupOptional(allocator, review_thread_id),
        .review_turn_id = try dupOptional(allocator, jsonStringField(root, "reviewTurnId")),
        .record_path = try dupOptional(allocator, jsonStringField(root, "recordPath")),
        .event_log_path = try dupOptional(allocator, jsonStringField(root, "eventLogPath")),
        .attempt_created_at_unix_s = receiptCreatedAtUnixS(root),
        .failure_code = try dupOptional(allocator, final_failure_code),
        .failure_hint = try dupOptional(allocator, final_failure_hint),
        .failure_class = try dupOptional(allocator, final_failure_class),
        .retryable_same_tuple_now = final_retryable_same_tuple_now,
        .findings_json = findings_json,
        .workflow_binding_json = try workflowBindingJsonFromRootAlloc(allocator, root),
    };
}

fn normalizeStoredSessionRecordReceiptAlloc(allocator: std.mem.Allocator, source_path: []const u8, root: std.json.ObjectMap, recover_event_logs: bool, context: NormalizeContext) !NormalizedReceipt {
    const typed_json = try stringifyAnyAlloc(
        allocator,
        std.json.Value{ .object = root },
    );
    defer allocator.free(typed_json);
    var typed = std.json.parseFromSlice(
        SessionRecord,
        allocator,
        typed_json,
        .{},
    ) catch return error.InvalidSessionRecord;
    defer typed.deinit();
    try validateCurrentSessionRecordAlloc(allocator, source_path, typed.value);
    var exact_lock = try loadExactReviewTupleLockForRecord(
        allocator,
        typed.value,
        source_path,
    );
    defer exact_lock.deinit(allocator);

    const review_thread_id = jsonStringField(root, "review_thread_id") orelse
        return error.NotReviewReceipt;
    const review_turn_id = jsonStringField(root, "review_turn_id");
    const event_log_path = jsonStringField(root, "event_log_path");
    var result_source = jsonStringField(root, "terminal_review_result_source");

    var review_result_json: ?[]u8 = null;
    defer if (review_result_json) |value| allocator.free(value);
    if (jsonStringField(root, "terminal_review_result_json")) |json| {
        if (std.mem.eql(u8, result_source orelse "", "rollout_exited_review_mode")) {
            review_result_json = try allocator.dupe(u8, json);
        }
    } else if (recover_event_logs) {
        if (event_log_path) |path| {
            const recovered_rollout_result = readRolloutReviewResultFromEventLogAlloc(
                allocator,
                path,
                typed.value.review_thread_id,
                typed.value.review_turn_id,
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            if (recovered_rollout_result) |rollout_result| {
                review_result_json = rollout_result;
                result_source = "rollout_exited_review_mode";
            }
        }
    }
    const structured_account_failure =
        std.mem.eql(u8, exact_lock.record.state, "account_resource_exhausted") or
        if (exact_lock.record.lastFailureCode) |code|
            failureCodeIsAccountResourceExhausted(code)
        else
            false;
    const persisted_terminal_failure_code = typed.value.terminal_failure_code;
    const persisted_terminal_failure_hint = typed.value.terminal_failure_hint;
    const structured_terminal_owner_failure = if (persisted_terminal_failure_code) |code| blk: {
        if (!std.mem.eql(u8, exact_lock.record.state, "terminal")) {
            return error.InvalidReviewTupleLockBinding;
        }
        const lock_code = exact_lock.record.lastFailureCode orelse
            return error.InvalidReviewTupleLockBinding;
        if (!std.mem.eql(u8, code, lock_code) or
            terminalReviewOwnerFailure(code) == null)
        {
            return error.InvalidReviewTupleLockBinding;
        }
        break :blk true;
    } else false;

    const finding_count = try reviewFindingCount(allocator, review_result_json);
    const missing_completed_result = review_result_json == null and
        std.mem.eql(u8, jsonStringField(root, "last_observed_status") orelse "", "completed");
    const failure_code: ?[]const u8 = if (structured_account_failure)
        "account_resource_exhausted"
    else if (structured_terminal_owner_failure)
        persisted_terminal_failure_code
    else if (missing_completed_result)
        "review_output_missing"
    else
        null;
    const failure_hint: ?[]const u8 = if (structured_account_failure)
        account_resource_exhausted_hint
    else if (structured_terminal_owner_failure)
        persisted_terminal_failure_hint
    else if (missing_completed_result)
        "stored review session record did not include a materialized rollout reviewResult"
    else
        null;
    const status = if (structured_account_failure)
        "account_resource_exhausted"
    else if (structured_terminal_owner_failure and
        terminalReviewTransportFailure(persisted_terminal_failure_code.?) != null)
        "review_transport_failure"
    else if (structured_terminal_owner_failure)
        "incomplete"
    else if (finding_count > 0)
        "findings"
    else if (missing_completed_result)
        "incomplete"
    else if (std.mem.eql(u8, result_source orelse "", "rollout_exited_review_mode"))
        "clean"
    else
        "incomplete";
    const findings_json = compactFindingsJsonAlloc(
        allocator,
        review_result_json,
    ) catch try allocator.dupe(u8, "[]");
    const binding_failure = if (structured_terminal_owner_failure)
        null
    else if (!std.mem.eql(u8, exact_lock.record.state, "normalized"))
        "review_tuple_lock_not_normalized"
    else if (context.requested_identity_required) blk: {
        const requested = context.requested_identity orelse break :blk "target_identity_unavailable";
        if (!identityHasCompleteTuple(requested)) break :blk "target_identity_unavailable";
        break :blk if (rootTupleMatchesIdentity(root, requested)) @as(?[]const u8, null) else "tuple_mismatch";
    } else null;
    const final_status = if (binding_failure != null) "incomplete" else status;
    const final_clean = binding_failure == null and std.mem.eql(u8, final_status, "clean");
    const final_failure_code = binding_failure orelse failure_code;
    const final_failure_hint = if (binding_failure) |code|
        if (std.mem.eql(u8, code, "target_identity_unavailable"))
            "requested target identity could not be computed for receipt normalization"
        else
            "stored review session tuple did not match the requested target identity"
    else
        failure_hint;
    const final_failure_class = failureClassForCode(final_failure_code);
    const final_retryable_same_tuple_now = retryableSameTupleNowForCode(final_failure_code);
    const tuple_verdict_exists = binding_failure == null and
        reviewVerdictStatusIsTupleTerminal(final_status) and
        if (context.requested_identity_required)
            rootTupleMatchesIdentity(root, context.requested_identity.?)
        else
            rootHasTupleVerdictBinding(root);
    const review_attempt_phase = if (tuple_verdict_exists)
        "normalized_verdict"
    else if (structured_terminal_owner_failure or
        std.mem.eql(u8, final_status, "account_resource_exhausted") or
        isTerminalTurnStatus(jsonStringField(root, "last_observed_status") orelse ""))
        "review_terminal"
    else
        "review_waiting";
    const account_fingerprint_reduced_protection = receiptPrincipalReduced(root, root);
    const principal_strength = receiptPrincipalStrength(root, root);
    const target_json = try stringifyAnyAlloc(allocator, typed.value.target);
    errdefer allocator.free(target_json);

    return .{
        .source_path = try allocator.dupe(u8, source_path),
        .status = try allocator.dupe(u8, final_status),
        .backend_class = try allocator.dupe(u8, "cas-start-wait"),
        .clean = final_clean,
        .finding_count = finding_count,
        .review_attempt_phase = try allocator.dupe(u8, review_attempt_phase),
        .review_attempt_exists = true,
        .tuple_verdict_exists = tuple_verdict_exists,
        .principal_strength = principal_strength,
        .account_fingerprint_reduced_protection = account_fingerprint_reduced_protection,
        .base_sha = try dupOptional(allocator, optionalStringFromRootKeys(root, "baseSha", "base_sha")),
        .head_sha = try dupOptional(allocator, optionalStringFromRootKeys(root, "headSha", "head_sha")),
        .target_fingerprint = try dupOptional(allocator, optionalStringFromRootKeys(root, "targetFingerprint", "target_fingerprint")),
        .target_json = target_json,
        .repo_realpath = try receiptRepoRealpathAlloc(allocator, root),
        .resolved_codex_path = try dupOptional(allocator, receiptResolvedCodexPath(root)),
        .resolved_codex_version = try dupOptional(allocator, receiptResolvedCodexVersion(root)),
        .codex_thread_id = try dupOptional(allocator, receiptCodexThreadId(root)),
        .account_fingerprint = try dupOptional(allocator, receiptAccountFingerprint(root, root)),
        .review_thread_id = try allocator.dupe(u8, review_thread_id),
        .review_turn_id = try dupOptional(allocator, review_turn_id),
        .record_path = try allocator.dupe(u8, source_path),
        .event_log_path = try dupOptional(allocator, event_log_path),
        .attempt_created_at_unix_s = receiptCreatedAtUnixS(root),
        .failure_code = try dupOptional(allocator, final_failure_code),
        .failure_hint = try dupOptional(allocator, final_failure_hint),
        .failure_class = try dupOptional(allocator, final_failure_class),
        .retryable_same_tuple_now = final_retryable_same_tuple_now,
        .findings_json = findings_json,
        .workflow_binding_json = try workflowBindingJsonFromRootAlloc(allocator, root),
    };
}

const CasRerProjectionOptions = struct {
    command_surface: []const u8,
    backend_selected: []const u8,
    broker_action: []const u8,
    broker_reason: []const u8,
    fresh_attempt_required: bool = false,
    timestamp: []const u8,
};

fn casRerTimestampAlloc(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "unix-ns:{d}", .{std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds});
}

fn publicReviewBrokerAction(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "normalized_existing")) return "returned_terminal";
    if (std.mem.eql(u8, raw, "auto_replaced_dead_transport")) return "replaced_dead_transport";
    if (std.mem.eql(u8, raw, "blocked_live_attempt")) return "blocked_live";
    return raw;
}

fn writePublicReviewBrokerDecisionObject(writer: *std.Io.Writer, broker: ReviewBrokerDecision, fresh_attempt_required: bool) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "action");
    try writer.writeByte(':');
    try writeJsonString(writer, publicReviewBrokerAction(broker.action));
    try writer.writeByte(',');
    try writeJsonString(writer, "reason");
    try writer.writeByte(':');
    try writeJsonString(writer, broker.reason);
    try writer.writeByte(',');
    try writeJsonString(writer, "freshAttemptRequired");
    try writer.writeByte(':');
    try writer.writeAll(if (fresh_attempt_required) "true" else "false");
    try writer.writeByte('}');
}

fn writeCasRunEnvelopeFromReceipt(allocator: std.mem.Allocator, writer: *std.Io.Writer, receipt: NormalizedReceipt, broker: ReviewBrokerDecision, fresh_attempt_required: bool) !void {
    const timestamp = try casRerTimestampAlloc(allocator);
    defer allocator.free(timestamp);
    const record_json = try casRerJsonFromReceiptAlloc(allocator, receipt, .{
        .command_surface = "run",
        .backend_selected = "cas-run",
        .broker_action = publicReviewBrokerAction(broker.action),
        .broker_reason = broker.reason,
        .fresh_attempt_required = fresh_attempt_required,
        .timestamp = timestamp,
    });
    defer allocator.free(record_json);
    var parsed_record = try std.json.parseFromSlice(std.json.Value, allocator, record_json, .{});
    defer parsed_record.deinit();
    const validation = try validateCasRerRecordObjectAlloc(allocator, receipt.source_path, parsed_record.value.object);
    defer validation.deinit(allocator);
    if (!validation.ok()) return error.InvalidCasRerRecord;
    const ledger_record_path = try writeCasRerRecordJsonToLedgerAlloc(allocator, record_json);
    defer allocator.free(ledger_record_path);
    try writer.writeAll("{\"schema\":\"CAS-RUN-v1\",\"recordPath\":");
    try writeJsonString(writer, ledger_record_path);
    try writer.writeAll(",\"record\":");
    try writer.writeAll(record_json);
    try writer.writeAll(",\"reviewVerdict\":");
    try writeReceiptReviewVerdictObject(writer, receipt);
    try writer.writeAll(",\"reviewBrokerDecision\":");
    try writePublicReviewBrokerDecisionObject(writer, broker, fresh_attempt_required);
    try writer.writeByte('}');
}

fn writeCasRerShadowRecordFromReceipt(allocator: std.mem.Allocator, receipt: NormalizedReceipt, opts: CasRerProjectionOptions) ![]const u8 {
    const record_json = try casRerJsonFromReceiptAlloc(allocator, receipt, opts);
    defer allocator.free(record_json);
    var parsed_record = try std.json.parseFromSlice(std.json.Value, allocator, record_json, .{});
    defer parsed_record.deinit();
    const validation = try validateCasRerRecordObjectAlloc(allocator, receipt.source_path, parsed_record.value.object);
    defer validation.deinit(allocator);
    if (!validation.ok()) {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("CAS-RER shadow validation failed for {s}\n", .{receipt.source_path});
        for (validation.errors) |err| {
            try stderr.print("- {s}\n", .{err});
        }
        return error.InvalidCasRerRecord;
    }
    return writeCasRerRecordJsonToLedgerAlloc(allocator, record_json);
}

fn writeCasRerShadowRecordFromJsonAlloc(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    payload_json: []const u8,
    context: NormalizeContext,
    opts: CasRerProjectionOptions,
) ![]const u8 {
    const normalized = try normalizeReceiptFromJsonAlloc(allocator, source_path, payload_json, true, context);
    defer normalized.deinit(allocator);
    return writeCasRerShadowRecordFromReceipt(allocator, normalized, opts);
}

fn casRerVerdictStatus(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "pre_review_transport_failure")) return "transport_failure";
    if (std.mem.eql(u8, status, "review_transport_failure")) return "transport_failure";
    return status;
}

fn casRerPrincipalKind(receipt: NormalizedReceipt) []const u8 {
    if (std.mem.eql(u8, receipt.principal_strength, principal_strength_strong)) return "strong";
    if (std.mem.eql(u8, receipt.principal_strength, principal_strength_reduced)) return "reduced";
    return "unknown";
}

fn casRerPrincipalFingerprintUsable(fingerprint: ?[]const u8) bool {
    const value = nonEmptyOptional(fingerprint) orelse return false;
    return !std.mem.eql(u8, value, unknown_account_fingerprint);
}

fn casRerPrincipalProofUsable(receipt: NormalizedReceipt) bool {
    return std.mem.eql(u8, casRerPrincipalKind(receipt), "strong") and
        std.mem.eql(u8, receipt.backend_class, "cas-start-wait") and
        !receipt.account_fingerprint_reduced_protection and
        casRerPrincipalFingerprintUsable(receipt.account_fingerprint);
}

fn casRerAttemptIdAlloc(allocator: std.mem.Allocator, receipt: NormalizedReceipt) !?[]const u8 {
    const review_thread_id = nonEmptyOptional(receipt.review_thread_id) orelse return null;
    const material = try std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{
        review_thread_id,
        receipt.review_turn_id orelse "",
    });
    defer allocator.free(material);
    return try sha256HexAlloc(allocator, material);
}

fn casRerRecordIdAlloc(allocator: std.mem.Allocator, receipt: NormalizedReceipt, opts: CasRerProjectionOptions) ![]const u8 {
    const target_json = receipt.target_json orelse return error.MissingCasRerTarget;
    const base_material = try std.fmt.allocPrint(
        allocator,
        "repo_realpath={s}\n" ++
            "resolved_codex_path={s}\n" ++
            "resolved_codex_version={s}\n" ++
            "account_fingerprint={s}\n" ++
            "codex_thread_id={s}\n" ++
            "backend_class={s}\n" ++
            "principal_strength={s}\n" ++
            "principal_protection={s}\n" ++
            "command_surface={s}\n" ++
            "backend_selected={s}\n" ++
            "broker_action={s}\n" ++
            "broker_reason={s}\n" ++
            "fresh_attempt={s}\n" ++
            "status={s}\n" ++
            "review_thread_id={s}\n" ++
            "review_turn_id={s}\n" ++
            "base_sha={s}\n" ++
            "head_sha={s}\n" ++
            "target_fingerprint={s}\n" ++
            "target={s}\n" ++
            "failure_code={s}\n" ++
            "finding_count={d}\n" ++
            "clean={s}\n" ++
            "findings={s}\n",
        .{
            receipt.repo_realpath orelse "",
            receipt.resolved_codex_path orelse "",
            receipt.resolved_codex_version orelse "",
            receipt.account_fingerprint orelse "",
            receipt.codex_thread_id orelse "",
            receipt.backend_class,
            receipt.principal_strength,
            if (receipt.account_fingerprint_reduced_protection)
                "reduced-protection"
            else
                "full-protection",
            opts.command_surface,
            opts.backend_selected,
            opts.broker_action,
            opts.broker_reason,
            if (opts.fresh_attempt_required) "fresh" else "not-fresh",
            receipt.status,
            receipt.review_thread_id orelse "",
            receipt.review_turn_id orelse "",
            receipt.base_sha orelse "",
            receipt.head_sha orelse "",
            receipt.target_fingerprint orelse "",
            target_json,
            receipt.failure_code orelse "",
            receipt.finding_count,
            if (receipt.clean) "clean" else "not-clean",
            receipt.findings_json,
        },
    );
    defer allocator.free(base_material);
    const material = if (receipt.workflow_binding_json) |workflow_binding_json|
        try std.fmt.allocPrint(
            allocator,
            "{s}\x1fworkflowBinding\x1f{s}",
            .{ base_material, workflow_binding_json },
        )
    else
        try allocator.dupe(u8, base_material);
    defer allocator.free(material);
    const digest = try sha256HexBareAlloc(allocator, material);
    defer allocator.free(digest);
    return std.fmt.allocPrint(allocator, "rer_{s}", .{digest});
}

fn writeCasRerCommandObject(writer: *std.Io.Writer, receipt: NormalizedReceipt, opts: CasRerProjectionOptions) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "surface");
    try writer.writeByte(':');
    try writeJsonString(writer, opts.command_surface);
    try writer.writeByte(',');
    try writeJsonString(writer, "argv");
    try writer.writeAll(":[]");
    try writer.writeByte(',');
    try writeJsonString(writer, "backendSelected");
    try writer.writeByte(':');
    try writeJsonString(writer, opts.backend_selected);
    try writer.writeByte(',');
    try writeJsonString(writer, "sourceBackendClass");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.backend_class);
    try writer.writeByte(',');
    try writeJsonString(writer, "brokerDecision");
    try writer.writeAll(":{");
    try writeJsonString(writer, "action");
    try writer.writeByte(':');
    try writeJsonString(writer, opts.broker_action);
    try writer.writeByte(',');
    try writeJsonString(writer, "reason");
    try writer.writeByte(':');
    try writeJsonString(writer, opts.broker_reason);
    try writer.writeByte(',');
    try writeJsonString(writer, "freshAttemptRequired");
    try writer.writeByte(':');
    try writer.writeAll(if (opts.fresh_attempt_required) "true" else "false");
    try writer.writeAll("}}");
}

fn writeCasRerTupleObject(writer: *std.Io.Writer, receipt: NormalizedReceipt) !void {
    const target_json = receipt.target_json orelse return error.MissingCasRerTarget;
    try writer.writeByte('{');
    try writeJsonString(writer, "repoRealpath");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.repo_realpath);
    try writer.writeByte(',');
    try writeJsonString(writer, "target");
    try writer.writeByte(':');
    try writer.writeAll(target_json);
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
    try writeJsonString(writer, "resolvedCodexPath");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.resolved_codex_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "resolvedCodexVersion");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.resolved_codex_version);
    try writer.writeByte(',');
    try writeJsonString(writer, "codexThreadId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.codex_thread_id);
    try writer.writeByte('}');
}

fn writeCasRerAttemptObject(writer: *std.Io.Writer, receipt: NormalizedReceipt, attempt_id: ?[]const u8) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "exists");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.review_attempt_exists) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "attemptId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, attempt_id);
    try writer.writeByte(',');
    try writeJsonString(writer, "phase");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.review_attempt_phase);
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
    try writer.writeByte('}');
}

fn writeCasRerVerdictObject(writer: *std.Io.Writer, receipt: NormalizedReceipt) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "tupleVerdictExists");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.tuple_verdict_exists) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "status");
    try writer.writeByte(':');
    try writeJsonString(writer, casRerVerdictStatus(receipt.status));
    try writer.writeByte(',');
    try writeJsonString(writer, "clean");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.clean) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "findingCount");
    try writer.writeByte(':');
    try writer.print("{d}", .{receipt.finding_count});
    try writer.writeByte(',');
    try writeJsonString(writer, "findings");
    try writer.writeByte(':');
    try writer.writeAll(receipt.findings_json);
    try writer.writeByte('}');
}

fn writeCasRerFailureObject(writer: *std.Io.Writer, receipt: NormalizedReceipt) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "failureCode");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.failure_code);
    try writer.writeByte(',');
    try writeJsonString(writer, "failureClass");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.failure_class);
    try writer.writeByte(',');
    try writeJsonString(writer, "retryableSameTupleNow");
    try writer.writeByte(':');
    if (receipt.retryable_same_tuple_now) |value|
        try writer.writeAll(if (value) "true" else "false")
    else
        try writer.writeAll("null");
    try writer.writeByte('}');
}

fn casRerPrincipalProofUsableWithFingerprint(receipt: NormalizedReceipt, account_fingerprint: ?[]const u8) bool {
    return std.mem.eql(u8, casRerPrincipalKind(receipt), "strong") and
        std.mem.eql(u8, receipt.backend_class, "cas-start-wait") and
        !receipt.account_fingerprint_reduced_protection and
        casRerPrincipalFingerprintUsable(account_fingerprint);
}

fn writeCasRerPrincipalObject(writer: *std.Io.Writer, receipt: NormalizedReceipt) !void {
    const account_fingerprint = receipt.account_fingerprint;
    try writer.writeByte('{');
    try writeJsonString(writer, "kind");
    try writer.writeByte(':');
    try writeJsonString(writer, casRerPrincipalKind(receipt));
    try writer.writeByte(',');
    try writeJsonString(writer, "accountFingerprint");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, account_fingerprint);
    try writer.writeByte(',');
    try writeJsonString(writer, "proofUsable");
    try writer.writeByte(':');
    try writer.writeAll(if (casRerPrincipalProofUsableWithFingerprint(receipt, account_fingerprint)) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "reduced");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.account_fingerprint_reduced_protection) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "fallbackUsed");
    try writer.writeByte(':');
    try writer.writeAll("false");
    try writer.writeByte(',');
    try writeJsonString(writer, "source");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.backend_class);
    try writer.writeByte('}');
}

fn writeCasRerAttachmentsObject(writer: *std.Io.Writer, receipt: NormalizedReceipt) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "stdout");
    try writer.writeAll(":null,");
    try writeJsonString(writer, "stderr");
    try writer.writeAll(":null,");
    try writeJsonString(writer, "eventLog");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.event_log_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "rawSessionRecord");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.record_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "rawReceipt");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.source_path);
    try writer.writeByte('}');
}

fn writeCasRerRecordObject(
    writer: *std.Io.Writer,
    receipt: NormalizedReceipt,
    record_id: []const u8,
    attempt_id: ?[]const u8,
    opts: CasRerProjectionOptions,
) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "schema");
    try writer.writeByte(':');
    try writeJsonString(writer, cas_review_evidence_schema);
    try writer.writeByte(',');
    try writeJsonString(writer, "recordId");
    try writer.writeByte(':');
    try writeJsonString(writer, record_id);
    try writer.writeByte(',');
    try writeJsonString(writer, "createdAt");
    try writer.writeByte(':');
    try writeJsonString(writer, opts.timestamp);
    try writer.writeByte(',');
    try writeJsonString(writer, "updatedAt");
    try writer.writeByte(':');
    try writeJsonString(writer, opts.timestamp);
    try writer.writeByte(',');
    try writeJsonString(writer, "command");
    try writer.writeByte(':');
    try writeCasRerCommandObject(writer, receipt, opts);
    try writer.writeByte(',');
    try writeJsonString(writer, "tuple");
    try writer.writeByte(':');
    try writeCasRerTupleObject(writer, receipt);
    if (receipt.workflow_binding_json) |workflow_binding_json| {
        try writer.writeByte(',');
        try writeJsonString(writer, "workflowBinding");
        try writer.writeByte(':');
        try writer.writeAll(workflow_binding_json);
    }
    try writer.writeByte(',');
    try writeJsonString(writer, "attempt");
    try writer.writeByte(':');
    try writeCasRerAttemptObject(writer, receipt, attempt_id);
    try writer.writeByte(',');
    try writeJsonString(writer, "verdict");
    try writer.writeByte(':');
    try writeCasRerVerdictObject(writer, receipt);
    try writer.writeByte(',');
    try writeJsonString(writer, "failure");
    try writer.writeByte(':');
    try writeCasRerFailureObject(writer, receipt);
    try writer.writeByte(',');
    try writeJsonString(writer, "principal");
    try writer.writeByte(':');
    try writeCasRerPrincipalObject(writer, receipt);
    try writer.writeByte(',');
    try writeJsonString(writer, "attachments");
    try writer.writeByte(':');
    try writeCasRerAttachmentsObject(writer, receipt);
    try writer.writeByte('}');
}

fn casRerJsonFromReceiptAlloc(allocator: std.mem.Allocator, receipt: NormalizedReceipt, opts: CasRerProjectionOptions) ![]u8 {
    const record_id = try casRerRecordIdAlloc(allocator, receipt, opts);
    defer allocator.free(record_id);
    const attempt_id = try casRerAttemptIdAlloc(allocator, receipt);
    defer if (attempt_id) |value| allocator.free(value);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeCasRerRecordObject(&out.writer, receipt, record_id, attempt_id, opts);
    return out.toOwnedSlice();
}

fn writeReceiptReviewVerdictObject(writer: *std.Io.Writer, receipt: NormalizedReceipt) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "status");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.status);
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewAttemptPhase");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.review_attempt_phase);
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewAttemptExists");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.review_attempt_exists) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "tupleVerdictExists");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.tuple_verdict_exists) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "principalStrength");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.principal_strength);
    try writer.writeByte(',');
    try writeJsonString(writer, "accountFingerprint");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.account_fingerprint);
    try writer.writeByte(',');
    try writeJsonString(writer, "accountFingerprintReducedProtection");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.account_fingerprint_reduced_protection) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "codexThreadId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.codex_thread_id);
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
    try writeJsonString(writer, "failureCode");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.failure_code);
    try writer.writeByte(',');
    try writeJsonString(writer, "failureHint");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.failure_hint);
    try writer.writeByte(',');
    try writeJsonString(writer, "failureClass");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.failure_class);
    try writer.writeByte(',');
    try writeJsonString(writer, "retryableSameTupleNow");
    try writer.writeByte(':');
    if (receipt.retryable_same_tuple_now) |value| {
        try writer.writeAll(if (value) "true" else "false");
    } else {
        try writer.writeAll("null");
    }
    if (receipt.workflow_binding_json) |workflow_binding_json| {
        try writer.writeByte(',');
        try writeJsonString(writer, "workflowBinding");
        try writer.writeByte(':');
        try writer.writeAll(workflow_binding_json);
    }
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
    try writeJsonString(writer, "findings");
    try writer.writeByte(':');
    try writer.writeAll(receipt.findings_json);
    try writer.writeByte('}');
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
    try writeJsonString(writer, "reviewAttemptPhase");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.review_attempt_phase);
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewAttemptExists");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.review_attempt_exists) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "tupleVerdictExists");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.tuple_verdict_exists) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "principalStrength");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.principal_strength);
    try writer.writeByte(',');
    try writeJsonString(writer, "accountFingerprintReducedProtection");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.account_fingerprint_reduced_protection) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "codexThreadId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.codex_thread_id);
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
    try writeJsonString(writer, "failureClass");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.failure_class);
    try writer.writeByte(',');
    try writeJsonString(writer, "retryableSameTupleNow");
    try writer.writeByte(':');
    if (receipt.retryable_same_tuple_now) |value| try writer.writeAll(if (value) "true" else "false") else try writer.writeAll("null");
    try writer.writeByte(',');
    try writeJsonString(writer, "findings");
    try writer.writeByte(':');
    try writer.writeAll(receipt.findings_json);
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewVerdict");
    try writer.writeByte(':');
    try writeReceiptReviewVerdictObject(writer, receipt);
    try writer.writeByte('}');
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
        try writeJsonString(writer, "body");
        try writer.writeByte(':');
        try writeNullableJsonString(writer, jsonStringField(finding, "body"));
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

fn failureCodeIsAccountResourceExhausted(code: []const u8) bool {
    return detectAccountResourceExhaustion(code) or
        std.mem.indexOf(u8, code, "usageLimitExceeded") != null or
        std.mem.indexOf(u8, code, "usage_limit") != null or
        std.mem.indexOf(u8, code, "rate_limit") != null or
        std.mem.indexOf(u8, code, "account_resource") != null or
        std.mem.indexOf(u8, code, "resource_exhausted") != null;
}

fn reviewUntrustedSourceFailureInfo() FailureInfo {
    return .{
        .code = "review_untrusted_source",
        .hint = "reviewResult is not rollout-backed structured output and cannot be proof",
    };
}

fn reviewStatusHasTrustedResult(status: ReviewStatus) bool {
    if (!status.review_result_available) return false;
    const source = status.review_result_source orelse return false;
    return std.mem.eql(u8, source, "rollout_exited_review_mode");
}

fn failureControlJsonSuffixAlloc(allocator: std.mem.Allocator, failure: ?FailureInfo) ![]u8 {
    const value = failure orelse return allocator.dupe(u8, "");
    const failure_class = failureClassForCode(value.code) orelse return allocator.dupe(u8, "");
    const retryable = retryableSameTupleNowForCode(value.code);
    if (retryable) |flag| {
        return std.fmt.allocPrint(
            allocator,
            ",\"failureClass\":\"{s}\",\"retryableSameTupleNow\":{s}",
            .{ failure_class, if (flag) "true" else "false" },
        );
    }
    return std.fmt.allocPrint(allocator, ",\"failureClass\":\"{s}\"", .{failure_class});
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn detectAccountResourceExhaustion(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "usageLimitExceeded") != null or
        containsIgnoreCase(text, "rate limit exceeded") or
        containsIgnoreCase(text, "quota exceeded") or
        containsIgnoreCase(text, "account limit") or
        containsIgnoreCase(text, "usage limit") or
        containsIgnoreCase(text, "resource exhausted");
}

fn appendGateError(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try errors.append(allocator, try std.fmt.allocPrint(allocator, fmt, args));
}

fn reviewPhaseAllowed(value: []const u8) bool {
    return std.mem.eql(u8, value, "pre_review_start") or
        std.mem.eql(u8, value, "review_started") or
        std.mem.eql(u8, value, "review_waiting") or
        std.mem.eql(u8, value, "review_terminal") or
        std.mem.eql(u8, value, "normalized_verdict");
}

fn rootHasStructuredAccountResourceExhaustion(root: std.json.ObjectMap) bool {
    const keys = [_][]const u8{
        "failureCode",
        "error",
    };
    for (keys) |key| {
        if (jsonStringField(root, key)) |value| {
            if (detectAccountResourceExhaustion(value)) return true;
        }
    }
    return false;
}

fn accountResourceExhaustedFailureInfo() FailureInfo {
    return .{
        .code = "account_resource_exhausted",
        .hint = account_resource_exhausted_hint,
    };
}

fn failureClassForCode(code: ?[]const u8) ?[]const u8 {
    const value = code orelse return null;
    if (failureCodeIsAccountResourceExhausted(value)) return "account_resource";
    if (std.mem.eql(u8, value, "review_transport_lost")) return "transport_review_attempt";
    if (std.mem.indexOf(u8, value, "transport") != null) return "transport_review_attempt";
    if (std.mem.eql(u8, value, "review_owner_failed")) return "owner_review_attempt";
    if (std.mem.eql(u8, value, "pre_review_start_failed")) return "caller_error";
    if (std.mem.eql(u8, value, "workflow_bound_review_owner_lost_before_start")) return "coordination";
    if (std.mem.eql(u8, value, "wait_timed_out")) return "timeout";
    if (std.mem.eql(u8, value, "workflow_bound_review_requires_owner_lived_wait") or
        std.mem.eql(u8, value, "workflow_bound_review_requires_structured_output") or
        std.mem.eql(u8, value, "workflow_bound_review_owner_active")) return "caller_error";
    if (std.mem.indexOf(u8, value, "parse") != null) return "parse";
    if (std.mem.eql(u8, value, "review_untrusted_source")) return "review_output";
    if (std.mem.indexOf(u8, value, "output") != null) return "review_output";
    if (std.mem.eql(u8, value, "target_identity_unavailable") or std.mem.eql(u8, value, "tuple_mismatch")) return "caller_error";
    return null;
}

fn retryableSameTupleNowForCode(code: ?[]const u8) ?bool {
    const value = code orelse return null;
    if (failureCodeIsAccountResourceExhausted(value)) return false;
    if (std.mem.eql(u8, value, "review_transport_lost")) return true;
    if (std.mem.eql(u8, value, "review_transport_timeout")) return true;
    if (std.mem.eql(u8, value, "review_owner_failed")) return true;
    if (std.mem.eql(u8, value, "pre_review_start_failed")) return true;
    if (std.mem.eql(u8, value, "workflow_bound_review_owner_lost_before_start")) return true;
    if (std.mem.eql(u8, value, "wait_timed_out")) return true;
    if (std.mem.eql(u8, value, "workflow_bound_review_requires_owner_lived_wait")) return true;
    if (std.mem.eql(u8, value, "workflow_bound_review_requires_structured_output")) return true;
    if (std.mem.eql(u8, value, "workflow_bound_review_owner_active")) return false;
    return null;
}

fn reviewVerdictStatus(clean: ?bool, finding_count: ?usize, failure: ?FailureInfo, review_thread_id: ?[]const u8) []const u8 {
    if (!reviewAttemptExists(review_thread_id)) return "incomplete";
    if (failure) |info| {
        if (std.mem.eql(u8, info.code, "wait_timed_out")) return "timeout";
        if (std.mem.eql(u8, info.code, "review_untrusted_source")) return "review_untrusted_source";
        if (failureCodeIsAccountResourceExhausted(info.code)) return "account_resource_exhausted";
        if (std.mem.indexOf(u8, info.code, "transport") != null) return "review_transport_failure";
        return "incomplete";
    }
    if (clean orelse false) return "clean";
    if ((finding_count orelse 0) > 0) return "findings";
    return "incomplete";
}

fn reviewVerdictStatusIsTupleTerminal(status: []const u8) bool {
    return std.mem.eql(u8, status, "clean") or
        std.mem.eql(u8, status, "findings");
}

fn canonicalReceiptStatus(status: []const u8, failure_code: ?[]const u8, review_thread_id: ?[]const u8) []const u8 {
    _ = failure_code;
    if (std.mem.eql(u8, status, "no_attempt")) return "incomplete";
    if (std.mem.eql(u8, status, "transport_failure")) {
        if (reviewAttemptExists(review_thread_id)) return "review_transport_failure";
        return "pre_review_transport_failure";
    }
    return status;
}

fn buildReviewVerdictJsonAlloc(
    allocator: std.mem.Allocator,
    backend_class: []const u8,
    clean: ?bool,
    finding_count: ?usize,
    failure: ?FailureInfo,
    identity: TargetIdentity,
    receipt: OutputReceipt,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: ?[]const u8,
    event_log_path: ?[]const u8,
    review_result_json: ?[]const u8,
) ![]u8 {
    const findings_json = compactFindingsJsonAlloc(
        allocator,
        review_result_json,
    ) catch try allocator.dupe(u8, "[]");
    defer allocator.free(findings_json);
    const status = reviewVerdictStatus(clean, finding_count, failure, review_thread_id);
    const normalized_clean = std.mem.eql(u8, status, "clean") and (clean orelse false);
    const normalized_finding_count = finding_count orelse 0;
    const tuple_verdict_exists = reviewVerdictStatusIsTupleTerminal(status) and
        reviewAttemptExists(review_thread_id) and
        identityHasCompleteTuple(identity);
    const attempt_fields = identityReviewAttemptFields(
        if (tuple_verdict_exists)
            "normalized_verdict"
        else if (reviewAttemptExists(review_thread_id))
            if (std.mem.eql(u8, status, "timeout") or
                if (failure) |info|
                    std.mem.eql(u8, info.code, "workflow_bound_review_owner_active")
                else
                    false)
                "review_waiting"
            else
                "review_terminal"
        else
            "pre_review_start",
        tuple_verdict_exists,
        review_thread_id,
        review_turn_id,
        identity,
    );

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('{');
    try writeJsonString(writer, "status");
    try writer.writeByte(':');
    try writeJsonString(writer, status);
    try writeReviewAttemptStateFields(writer, attempt_fields);
    try writer.writeByte(',');
    try writeJsonString(writer, "backendClass");
    try writer.writeByte(':');
    try writeJsonString(writer, backend_class);
    try writer.writeByte(',');
    try writeJsonString(writer, "principalStrength");
    try writer.writeByte(':');
    try writeJsonString(
        writer,
        if (receipt.account_fingerprint_reduced_protection)
            principal_strength_reduced
        else
            principal_strength_strong,
    );
    try writer.writeByte(',');
    try writeJsonString(writer, "accountFingerprintReducedProtection");
    try writer.writeByte(':');
    try writer.writeAll(if (receipt.account_fingerprint_reduced_protection) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "workflowBinding");
    try writer.writeByte(':');
    if (receipt.workflow_binding) |binding| {
        try std.json.Stringify.value(binding, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte(',');
    try writeJsonString(writer, "clean");
    try writer.writeByte(':');
    try writer.writeAll(if (normalized_clean) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "findingCount");
    try writer.writeByte(':');
    try writer.print("{d}", .{normalized_finding_count});
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

fn floatField(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .float => |f| @floatCast(f),
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

const test_workflow_binding_json =
    \\{"requestId":"request-test","requestFingerprint":"sha256:request"}
;

const test_uncommitted_target_json =
    "{\"type\":\"uncommittedChanges\",\"branch\":null," ++
    "\"sha\":null,\"title\":null}";
const test_base_target_json =
    "{\"type\":\"baseBranch\",\"branch\":\"main\"," ++
    "\"sha\":null,\"title\":null}";
const test_commit_target_json =
    "{\"type\":\"commit\",\"branch\":null," ++
    "\"sha\":\"0123456789abcdef\",\"title\":\"subject\"}";

fn testWorkflowBinding() WorkflowBinding {
    return .{
        .requestId = "request-test",
        .requestFingerprint = "sha256:request",
    };
}

fn testCasRerProjectionOptions(timestamp: []const u8) CasRerProjectionOptions {
    return .{
        .command_surface = "run",
        .backend_selected = "cas-run",
        .broker_action = "created_new",
        .broker_reason = "test",
        .timestamp = timestamp,
    };
}

test "default timeout policy gives waited reviews 45 minutes and detached starts five minutes" {
    const review_actions = [_]ParsedArgs{
        .{ .action = .run },
        .{ .action = .wait },
        .{ .action = .start, .wait_after_start = true },
    };
    for (review_actions) |parsed| {
        try std.testing.expectEqual(@as(u32, 2_700_000), defaultTimeoutMsForAction(parsed));
    }

    try std.testing.expectEqual(
        @as(u32, 300_000),
        defaultTimeoutMsForAction(.{ .action = .start }),
    );
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
    try std.testing.expectEqual(default_control_timeout_ms, parsed.timeout_ms);
    try std.testing.expect(!parsed.timeout_ms_explicit);
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
    try std.testing.expectEqual(default_review_timeout_ms, parsed.timeout_ms);
    try std.testing.expect(!parsed.timeout_ms_explicit);
}

test "parseArgs accepts brokered run target" {
    const argv = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--json",
        "--fresh-attempt",
        "run 2",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Action.run, parsed.action.?);
    try std.testing.expectEqualStrings("/tmp/repo", parsed.cwd.?);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(TargetKind.base_branch, parsed.target.?.kind);
    try std.testing.expectEqualStrings("main", parsed.target.?.branch.?);
    try std.testing.expectEqualStrings("run 2", parsed.fresh_attempt_reason.?);
    try std.testing.expectEqual(default_review_timeout_ms, parsed.timeout_ms);
    try std.testing.expect(!parsed.timeout_ms_explicit);
}

test "parseArgs rejects ambiguous and action-inapplicable selectors" {
    const conflicting = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--commit",
        "HEAD",
    };
    try std.testing.expectError(
        error.MultipleTargetSelectors,
        parseArgs(std.testing.allocator, &conflicting),
    );

    const wait_target = [_][]const u8{
        "cas_review_session",
        "wait",
        "--review-thread-id",
        "thr_1",
        "--uncommitted",
    };
    try std.testing.expectError(
        error.TargetUnsupportedAction,
        parseArgs(std.testing.allocator, &wait_target),
    );

    const run_session = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--latest",
    };
    try std.testing.expectError(
        error.ReviewSessionSelectorUnsupportedAction,
        parseArgs(std.testing.allocator, &run_session),
    );
}

test "action help and version bypass operation operand validation" {
    const help_argv = [_][]const u8{ "cas_review_session", "run", "--help" };
    const help = try parseArgs(std.testing.allocator, &help_argv);
    defer help.deinit(std.testing.allocator);
    try std.testing.expect(help.show_help);
    try std.testing.expectEqual(Action.run, help.action.?);

    const version_argv = [_][]const u8{ "cas_review_session", "wait", "--version" };
    const version = try parseArgs(std.testing.allocator, &version_argv);
    defer version.deinit(std.testing.allocator);
    try std.testing.expect(version.show_version);
    try std.testing.expectEqual(Action.wait, version.action.?);
}

test "custom instructions require one Git target and a fresh parent" {
    const no_target = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/tmp/repo",
        "--custom-instructions",
        "review carefully",
    };
    try std.testing.expectError(
        error.MissingTarget,
        parseArgs(std.testing.allocator, &no_target),
    );

    const reused_parent = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--parent-thread-id",
        "thr_parent",
        "--custom-instructions",
        "review carefully",
    };
    try std.testing.expectError(
        error.CustomInstructionsRequireFreshParent,
        parseArgs(std.testing.allocator, &reused_parent),
    );
}

test "parseArgs preserves an explicit review timeout" {
    const argv = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--timeout-ms",
        "60000",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(@as(u32, 60_000), parsed.timeout_ms);
    try std.testing.expect(parsed.timeout_ms_explicit);
}

test "workflow binding input is canonical and action scoped" {
    var loaded = (try loadWorkflowBindingAlloc(std.testing.allocator, test_workflow_binding_json)).?;
    defer loaded.deinit();
    const canonical = try stringifyAnyAlloc(std.testing.allocator, loaded.value);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(test_workflow_binding_json, canonical);

    const run_argv = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--workflow-binding-json",
        test_workflow_binding_json,
    };
    const parsed = try parseArgs(std.testing.allocator, &run_argv);
    try std.testing.expectEqualStrings(test_workflow_binding_json, parsed.workflow_binding_arg.?);

    const wait_argv = [_][]const u8{
        "cas_review_session",
        "wait",
        "--review-thread-id",
        "thr_1",
        "--workflow-binding-json",
        test_workflow_binding_json,
    };
    try std.testing.expectError(
        error.WorkflowBindingUnsupportedAction,
        parseArgs(std.testing.allocator, &wait_argv),
    );
}

test "workflow binding input accepts only complete opaque request identity" {
    const invalid = [_][]const u8{
        \\{"requestId":"request-test"}
        ,
        \\{"requestId":" ","requestFingerprint":"sha256:request"}
        ,
        \\{"requestId":"request-test","requestFingerprint":" "}
        ,
        \\{"requestId":"request-test","requestFingerprint":"sha256:request","extra":"forbidden"}
    };
    for (invalid) |raw| {
        try std.testing.expectError(
            error.InvalidWorkflowBinding,
            loadWorkflowBindingAlloc(std.testing.allocator, raw),
        );
    }
}

test "owner-lived admission exhausts action binding and wait states" {
    const actions = [_]Action{ .run, .start, .wait };
    for (actions) |action| {
        for ([_]bool{ false, true }) |has_binding| {
            for ([_]bool{ false, true }) |wait_after_start| {
                for ([_]bool{ false, true }) |json_mode| {
                    const workflow_binding: ?WorkflowBinding = if (has_binding)
                        testWorkflowBinding()
                    else
                        null;
                    const failure = workflowBoundStartAdmissionFailure(
                        .{
                            .action = action,
                            .wait_after_start = wait_after_start,
                            .json = json_mode,
                        },
                        workflow_binding,
                    );
                    const should_reject = action == .start and has_binding and
                        (!wait_after_start or !json_mode);
                    try std.testing.expectEqual(should_reject, failure != null);
                    if (failure) |value| {
                        if (!wait_after_start) {
                            try std.testing.expectEqualStrings(
                                "workflow_bound_review_requires_owner_lived_wait",
                                value.code,
                            );
                        } else {
                            try std.testing.expectEqualStrings(
                                "workflow_bound_review_requires_structured_output",
                                value.code,
                            );
                        }
                    }
                }
            }
        }
    }
}

test "workflow-bound wait timeout is one terminal owner failure" {
    const workflow_bound = reviewWaitTimeoutDisposition(true);
    try std.testing.expectEqualStrings("terminal", workflow_bound.lock_state);
    try std.testing.expectEqualStrings("review_transport_timeout", workflow_bound.failure.code);
    try std.testing.expectEqualStrings("transport_review_attempt", failureClassForCode(workflow_bound.failure.code).?);
    try std.testing.expectEqual(true, retryableSameTupleNowForCode(workflow_bound.failure.code).?);
    try std.testing.expectEqualStrings(
        "review_terminal",
        startReceiptReviewAttemptPhase(null, true, workflow_bound.failure, "thr"),
    );

    const unbound = reviewWaitTimeoutDisposition(false);
    try std.testing.expectEqualStrings("waiting", unbound.lock_state);
    try std.testing.expectEqualStrings("wait_timed_out", unbound.failure.code);
    try std.testing.expectEqualStrings(
        "review_waiting",
        startReceiptReviewAttemptPhase(null, true, unbound.failure, "thr"),
    );
    try std.testing.expectEqual(@as(u32, 250), finalReviewStatusGraceMs(1));
    try std.testing.expectEqual(@as(u32, 250), finalReviewStatusGraceMs(60_000));

    var grace_status = try makeDisconnectedReviewStatus(std.testing.allocator);
    defer grace_status.deinit(std.testing.allocator);
    try std.testing.expect(!reviewGraceStatusCompletesWait(&grace_status));
    std.testing.allocator.free(grace_status.turn_status);
    grace_status.turn_status = try std.testing.allocator.dupe(u8, "failed");
    try std.testing.expect(reviewGraceStatusCompletesWait(&grace_status));
    std.testing.allocator.free(grace_status.turn_status);
    grace_status.turn_status = try std.testing.allocator.dupe(u8, "inProgress");
    try std.testing.expect(!reviewGraceStatusCompletesWait(&grace_status));
    grace_status.review_result_available = true;
    try std.testing.expect(reviewGraceStatusCompletesWait(&grace_status));
}

test "owner-lived admission failure is an immediate caller retry" {
    const code = "workflow_bound_review_requires_owner_lived_wait";
    try std.testing.expectEqualStrings("caller_error", failureClassForCode(code).?);
    try std.testing.expectEqual(true, retryableSameTupleNowForCode(code).?);
}

test "workflow-bound review start authority follows the actual send boundary" {
    try std.testing.expect(!reviewStartFailureOwnsAttempt(
        true,
        false,
        error.ConnectionTimedOut,
    ));
    try std.testing.expect(reviewStartFailureOwnsAttempt(
        true,
        true,
        error.InvalidAppServerResponse,
    ));
    try std.testing.expect(reviewStartFailureOwnsAttempt(
        false,
        false,
        error.ConnectionResetByPeer,
    ));
    try std.testing.expect(!reviewStartFailureOwnsAttempt(
        false,
        true,
        error.InvalidAppServerResponse,
    ));
}

test "proven pre-review-start failure is structurally retryable" {
    try std.testing.expectEqualStrings(
        "caller_error",
        failureClassForCode("pre_review_start_failed").?,
    );
    try std.testing.expectEqual(
        true,
        retryableSameTupleNowForCode("pre_review_start_failed").?,
    );
}

test "workflow owner failures are total and owner-active remains waiting" {
    const timeout = workflowOwnedPostStartFailure(error.ConnectionTimedOut);
    try std.testing.expectEqualStrings("review_transport_timeout", timeout.code);
    const protocol = workflowOwnedPostStartFailure(error.InvalidAppServerResponse);
    try std.testing.expectEqualStrings("review_owner_failed", protocol.code);
    try std.testing.expectEqual(true, retryableSameTupleNowForCode(protocol.code).?);

    const identity = TargetIdentity{
        .head_sha = "head",
        .base_sha = "base",
        .fingerprint = "fingerprint",
    };
    const owner_active = workflowOwnerActiveFailureInfo();
    const verdict = try buildReviewVerdictJsonAlloc(
        std.testing.allocator,
        "cas-start-wait",
        false,
        0,
        owner_active,
        identity,
        .{ .workflow_binding = testWorkflowBinding() },
        "review-thread",
        "review-turn",
        "/tmp/record.json",
        "/tmp/events.ndjson",
        null,
    );
    defer std.testing.allocator.free(verdict);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        verdict,
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("review_waiting", root.get("reviewAttemptPhase").?.string);
    try std.testing.expectEqualStrings(
        "workflow_bound_review_owner_active",
        root.get("failureCode").?.string,
    );
    try std.testing.expectEqual(false, retryableSameTupleNowForCode(owner_active.code).?);

    const tuple = testTupleIdentity("acct:a");
    const tuple_hash = try reviewTupleHashAlloc(std.testing.allocator, tuple);
    defer std.testing.allocator.free(tuple_hash);
    var dead_owner_lock = makeReviewTupleLock(
        tuple_hash,
        tuple,
        "starting_review",
        1,
        null,
        null,
    );
    try std.testing.expect(!workflowDeadOwnerAttemptExists(dead_owner_lock));
    try std.testing.expectEqualStrings(
        "workflow_bound_review_owner_lost_before_start",
        workflowDeadOwnerFailureInfo(dead_owner_lock).code,
    );
    dead_owner_lock.reviewStartSendStarted = true;
    try std.testing.expect(workflowDeadOwnerAttemptExists(dead_owner_lock));
    try std.testing.expectEqualStrings(
        "review_transport_lost",
        workflowDeadOwnerFailureInfo(dead_owner_lock).code,
    );
}

test "parseArgs accepts latest wait selector" {
    const wait_argv = [_][]const u8{
        "cas_review_session",
        "wait",
        "--latest",
    };
    const wait = try parseArgs(std.testing.allocator, &wait_argv);
    try std.testing.expectEqual(Action.wait, wait.action.?);
    try std.testing.expect(wait.latest_review_session);
    try std.testing.expectEqual(default_review_timeout_ms, wait.timeout_ms);
    try std.testing.expect(!wait.timeout_ms_explicit);
}

test "parseArgs accepts bare review thread id selectors" {
    const argv = [_][]const u8{
        "cas_review_session",
        "wait",
        "--review-thread-id",
        "019f198b-722f-7b81-a6a9-f6dbbcec5ed8",
        "--json",
    };

    var parsed = try parseArgs(std.testing.allocator, &argv);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Action.wait, parsed.action.?);
    try std.testing.expectEqualStrings(
        "019f198b-722f-7b81-a6a9-f6dbbcec5ed8",
        parsed.review_thread_id.?,
    );
    try std.testing.expect(parsed.json);
}

test "parseArgs accepts explicit session record path selectors" {
    const argv = [_][]const u8{
        "cas_review_session",
        "wait",
        "--path",
        "/repo/.ledger/cas/review_sessions/thr_1.json",
        "--json",
    };

    var parsed = try parseArgs(std.testing.allocator, &argv);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Action.wait, parsed.action.?);
    try std.testing.expectEqualStrings(
        "/repo/.ledger/cas/review_sessions/thr_1.json",
        parsed.receipt_paths[0],
    );
    try std.testing.expect(parsed.json);
}

test "loadSelectedSessionRecord rebinds store root from loaded record" {
    const old_store_root = configured_store_root_override;
    configured_store_root_override = "before";
    defer configured_store_root_override = old_store_root;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "external-store" });
    defer std.testing.allocator.free(store_root);
    const session_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ store_root, "review_sessions" },
    );
    defer std.testing.allocator.free(session_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(session_dir);
    const record_path = try std.fs.path.join(std.testing.allocator, &.{ session_dir, "thr.json" });
    const event_log_path = try std.fs.path.join(std.testing.allocator, &.{ store_root, "review_sessions", "thr.events.ndjson" });
    defer std.testing.allocator.free(event_log_path);
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":4,\"cwd\":\"{s}\",\"store_root\":\"{s}\"," ++
            "\"store_scope\":\"repo-local\",\"repo_root\":\"{s}\"," ++
            "\"codex_thread_id\":\"thread\"," ++
            "\"parent_thread_id\":\"parent\",\"review_thread_id\":\"thr\"," ++
            "\"review_turn_id\":\"turn\",\"delivery\":\"detached\"," ++
            "\"target\":{{\"type\":\"uncommittedChanges\"}},\"base_sha\":\"base\"," ++
            "\"head_sha\":\"head\",\"target_fingerprint\":\"fp\"," ++
            "\"transport_kind\":\"websocket\",\"transport_selection_reason\":" ++
            "\"detached_review_requires_cross_process_truth\",\"event_log_path\":\"{s}\"," ++
            "\"created_at_unix_s\":1,\"last_observed_status\":\"inProgress\"," ++
            "\"codex_version\":\"codex-cli test\",\"resolved_codex_path\":\"/bin/codex\"," ++
            "\"compatibility_verdict\":\"compatible\",\"managed_server_pid\":1," ++
            "\"managed_server_listen_url\":\"ws://127.0.0.1:1\",\"orphan_ttl_seconds\":1," ++
            "\"accountFingerprint\":\"acct:test\"," ++
            "\"accountFingerprintReducedProtection\":false}}\n",
        .{ root, store_root, root, event_log_path },
    );
    defer std.testing.allocator.free(raw);
    try durable_store.writeTextAtomic(std.testing.allocator, record_path, raw);

    var loaded = try loadOwnedSessionRecordPath(std.testing.allocator, record_path);
    try std.testing.expectEqualStrings(store_root, configured_store_root_override.?);
    loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("before", configured_store_root_override.?);
}

test "session record owns and validates workflow binding across reload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, ".ledger", "cas" });
    defer std.testing.allocator.free(store_root);
    const session_dir = try std.fs.path.join(
        std.testing.allocator,
        &.{ store_root, "review_sessions" },
    );
    defer std.testing.allocator.free(session_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(session_dir);
    const event_log_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ session_dir, "thr.events.ndjson" },
    );
    defer std.testing.allocator.free(event_log_path);
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":4,\"cwd\":\"{s}\",\"store_root\":\"{s}\"," ++
            "\"store_scope\":\"repo-local\",\"repo_root\":\"{s}\"," ++
            "\"codex_thread_id\":\"thread\"," ++
            "\"parent_thread_id\":\"parent\",\"review_thread_id\":\"thr\"," ++
            "\"review_turn_id\":\"turn\",\"delivery\":\"detached\"," ++
            "\"target\":{{\"type\":\"uncommittedChanges\"}},\"base_sha\":\"base\"," ++
            "\"head_sha\":\"head\",\"target_fingerprint\":\"fp\"," ++
            "\"transport_kind\":\"websocket\",\"transport_selection_reason\":" ++
            "\"detached_review_requires_cross_process_truth\",\"event_log_path\":\"{s}\"," ++
            "\"created_at_unix_s\":1,\"last_observed_status\":\"inProgress\"," ++
            "\"codex_version\":\"codex-cli test\",\"resolved_codex_path\":\"/bin/codex\"," ++
            "\"compatibility_verdict\":\"compatible\",\"managed_server_pid\":1," ++
            "\"managed_server_listen_url\":\"ws://127.0.0.1:1\",\"orphan_ttl_seconds\":1," ++
            "\"accountFingerprint\":\"acct:test\",\"accountFingerprintReducedProtection\":false," ++
            "\"workflowBinding\":{s}}}\n",
        .{ root, store_root, root, event_log_path, test_workflow_binding_json },
    );
    defer std.testing.allocator.free(raw);
    const record_path = try std.fs.path.join(std.testing.allocator, &.{ session_dir, "thr.json" });
    try durable_store.writeTextAtomic(std.testing.allocator, record_path, raw);
    var loaded = try loadOwnedSessionRecordPath(std.testing.allocator, record_path);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("request-test", loaded.record.workflowBinding.?.requestId);

    const invalid_raw = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        raw,
        "sha256:request",
        " ",
    );
    defer std.testing.allocator.free(invalid_raw);
    const invalid_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ session_dir, "invalid-record.json" },
    );
    try durable_store.writeTextAtomic(std.testing.allocator, invalid_path, invalid_raw);
    try std.testing.expectError(
        error.InvalidWorkflowBinding,
        loadOwnedSessionRecordPath(std.testing.allocator, invalid_path),
    );
}

test "session record rejects pre-kernel schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":3,\"cwd\":\"{s}\",\"parent_thread_id\":\"parent\"," ++
            "\"review_thread_id\":\"thr\",\"review_turn_id\":\"turn\",\"delivery\":\"review\"," ++
            "\"target\":{{\"type\":\"uncommittedChanges\"}}," ++
            "\"event_log_path\":\"events.ndjson\"," ++
            "\"created_at_unix_s\":1,\"last_observed_status\":\"inProgress\"," ++
            "\"codex_version\":\"codex-cli test\"}}\n",
        .{root},
    );
    defer std.testing.allocator.free(raw);
    const record_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "legacy-record.json" },
    );
    try durable_store.writeTextAtomic(std.testing.allocator, record_path, raw);
    try std.testing.expectError(
        error.InvalidSessionRecord,
        loadOwnedSessionRecordPath(std.testing.allocator, record_path),
    );
}

test "current session record rejects relocation and incomplete custody" {
    const record = SessionRecord{
        .cwd = "/repo",
        .store_root = "/repo/.ledger/cas",
        .store_scope = "repo-local",
        .repo_root = "/repo",
        .codex_thread_id = "thread-current",
        .parent_thread_id = "parent",
        .review_thread_id = "thr",
        .review_turn_id = "turn",
        .delivery = "detached",
        .target = .{ .type = "uncommittedChanges" },
        .event_log_path = "/repo/.ledger/cas/review_sessions/thr.events.ndjson",
        .created_at_unix_s = 1,
        .last_observed_status = "inProgress",
        .codex_version = "codex-cli test",
        .resolved_codex_path = "/bin/codex",
        .compatibility_verdict = "compatible",
        .transport_kind = "websocket",
        .transport_selection_reason = "detached_review_requires_cross_process_truth",
        .managed_server_pid = 1,
        .managed_server_listen_url = "ws://127.0.0.1:1",
        .orphan_ttl_seconds = 1,
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .accountFingerprint = "acct:test",
        .accountFingerprintReducedProtection = false,
    };
    try validateCurrentSessionRecordAlloc(
        std.testing.allocator,
        "/repo/.ledger/cas/review_sessions/thr.json",
        record,
    );
    try std.testing.expectError(
        error.InvalidSessionRecord,
        validateCurrentSessionRecordAlloc(
            std.testing.allocator,
            "/tmp/relocated.json",
            record,
        ),
    );
    var incomplete = record;
    incomplete.accountFingerprint = null;
    try std.testing.expectError(
        error.InvalidSessionRecord,
        validateCurrentSessionRecordAlloc(
            std.testing.allocator,
            "/repo/.ledger/cas/review_sessions/thr.json",
            incomplete,
        ),
    );
}

test "store root falls back to cwd ledger outside git while repo root stays optional" {
    const old_store_root = configured_store_root_override;
    const old_store_cwd = configured_store_cwd;
    configured_store_root_override = null;
    defer configured_store_root_override = old_store_root;
    defer configured_store_cwd = old_store_cwd;

    const root = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/cas-review-session-store-root-test-{d}",
        .{std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds},
    );
    defer std.testing.allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), root);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), root) catch {};
    configured_store_cwd = root;

    const store_root = try casStoreRootAlloc(std.testing.allocator);
    defer std.testing.allocator.free(store_root);
    const real_root = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), root, std.testing.allocator);
    defer std.testing.allocator.free(real_root);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/.ledger/cas", .{real_root});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, store_root);

    const repo_root = try repoRootForCwdAlloc(std.testing.allocator, root);
    try std.testing.expect(repo_root == null);
}

test "parseArgs rejects artifact-like review thread id selectors" {
    const invalid_values = [_][]const u8{
        "",
        "019f198b-722f-7b81-a6a9-f6dbbcec5ed8.json",
        "019f198b-722f-7b81-a6a9-f6dbbcec5ed8.events.ndjson",
        "019f198b-722f-7b81-a6a9-f6dbbcec5ed8.parent.events.ndjson",
        "review_sessions/019f198b-722f-7b81-a6a9-f6dbbcec5ed8",
        "review_sessions\\019f198b-722f-7b81-a6a9-f6dbbcec5ed8",
    };

    for (invalid_values) |value| {
        const argv = [_][]const u8{
            "cas_review_session",
            "wait",
            "--review-thread-id",
            value,
        };
        try std.testing.expectError(error.InvalidReviewThreadId, parseArgs(std.testing.allocator, &argv));
    }
}

test "usage detail explains invalid review thread id selectors" {
    const detail = usageDetailForParseError(error.InvalidReviewThreadId) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, detail, "bare reviewThreadId") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "--latest") != null);
}

test "parseArgs rejects ambiguous and unsafe latest selectors" {
    const ambiguous_argv = [_][]const u8{
        "cas_review_session",
        "wait",
        "--latest",
        "--review-thread-id",
        "thr_1",
    };
    try std.testing.expectError(error.AmbiguousReviewSessionSelector, parseArgs(std.testing.allocator, &ambiguous_argv));

    const path_argv = [_][]const u8{
        "cas_review_session",
        "wait",
        "--latest",
        "--path",
        "/repo/.ledger/cas/review_sessions/thr_1.json",
    };
    try std.testing.expectError(
        error.AmbiguousReviewSessionSelector,
        parseArgs(std.testing.allocator, &path_argv),
    );
}

test "latestSessionRecordPathInDirAlloc selects newest top-level session record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "old.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "new.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "events.ndjson", .data = "" });
    try tmp.dir.setTimestamps(io, "old.json", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 1 } } });
    try tmp.dir.setTimestamps(io, "new.json", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 2 } } });

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);
    const latest = try latestSessionRecordPathInDirAlloc(std.testing.allocator, tmp_path);
    defer std.testing.allocator.free(latest);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/new.json", .{tmp_path});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, latest);
}

test "parseArgs rejects removed multi-agent mode for start" {
    const start_argv = [_][]const u8{
        "cas_review_session",
        "start",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--multi-agent-mode",
        "proactive",
    };
    try std.testing.expectError(
        error.MultiAgentModeRemoved,
        parseArgs(std.testing.allocator, &start_argv),
    );
}

test "parseArgs rejects removed multi-agent mode for wait" {
    const argv = [_][]const u8{
        "cas_review_session",
        "wait",
        "--review-thread-id",
        "thr_1",
        "--multi-agent-mode",
        "proactive",
    };

    try std.testing.expectError(
        error.MultiAgentModeRemoved,
        parseArgs(std.testing.allocator, &argv),
    );
}

test "request builders omit removed multi-agent mode" {
    const thread_params = try buildThreadStartParamsJson(
        std.testing.allocator,
        "/tmp/repo",
        "review only this contract",
    );
    defer std.testing.allocator.free(thread_params);
    var parsed_thread = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        thread_params,
        .{},
    );
    defer parsed_thread.deinit();
    try std.testing.expect(parsed_thread.value.object.get("multiAgentMode") == null);
    try std.testing.expectEqualStrings(
        "review only this contract",
        parsed_thread.value.object.get("developerInstructions").?.string,
    );

    const turn_params = try buildTurnStartParamsJson(
        std.testing.allocator,
        "thr_1",
        "hello",
    );
    defer std.testing.allocator.free(turn_params);
    var parsed_turn = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        turn_params,
        .{},
    );
    defer parsed_turn.deinit();
    try std.testing.expect(parsed_turn.value.object.get("multiAgentMode") == null);
}

test "thread resume excludes turns only for Codex 0.145 and newer" {
    const current = try buildThreadResumeParamsJson(
        std.testing.allocator,
        "thr_1",
        "/tmp/rollout.jsonl",
        "codex-cli 0.145.0",
    );
    defer std.testing.allocator.free(current);
    var current_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, current, .{});
    defer current_json.deinit();
    try std.testing.expect(current_json.value.object.get("excludeTurns").?.bool);
    try std.testing.expectEqualStrings(
        "/tmp/rollout.jsonl",
        current_json.value.object.get("path").?.string,
    );

    const legacy = try buildThreadResumeParamsJson(
        std.testing.allocator,
        "thr_1",
        null,
        "codex-cli 0.144.2",
    );
    defer std.testing.allocator.free(legacy);
    var legacy_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, legacy, .{});
    defer legacy_json.deinit();
    try std.testing.expect(legacy_json.value.object.get("excludeTurns") == null);
    try std.testing.expect(legacy_json.value.object.get("path") == null);
}

test "review start preserves structured output on Codex 0.145 and newer" {
    const target = TargetConfig{
        .kind = .base_branch,
        .branch = "main",
    };
    const current = try buildReviewStartParamsJson(
        std.testing.allocator,
        "thr_isolated",
        target,
        "codex-cli 0.145.0",
    );
    defer std.testing.allocator.free(current);
    var current_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        current,
        .{},
    );
    defer current_json.deinit();
    try std.testing.expectEqualStrings(
        "inline",
        current_json.value.object.get("delivery").?.string,
    );
    try std.testing.expectEqualStrings(
        "thr_isolated",
        current_json.value.object.get("threadId").?.string,
    );

    const legacy = try buildReviewStartParamsJson(
        std.testing.allocator,
        "thr_isolated",
        target,
        "codex-cli 0.144.6",
    );
    defer std.testing.allocator.free(legacy);
    var legacy_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        legacy,
        .{},
    );
    defer legacy_json.deinit();
    try std.testing.expectEqualStrings(
        "detached",
        legacy_json.value.object.get("delivery").?.string,
    );
    try std.testing.expect(codexReviewRequiresFreshParent("codex-cli 0.145.0"));
    try std.testing.expect(!codexReviewRequiresFreshParent("codex-cli 0.144.6"));
}

test "parseArgs captures parent mode and approvals" {
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
        "--hooks",
        "require-observed",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(ParentMode.reuse, parsed.parent_mode);
    try std.testing.expectEqualStrings("thr_parent", parsed.parent_thread_id.?);
    try std.testing.expectEqualStrings("decline", parsed.exec_approval.?);
    try std.testing.expectEqualStrings("acceptForSession", parsed.file_approval.?);
    try std.testing.expectEqualStrings("grant-session", parsed.permissions_approval.?);
    try std.testing.expectEqual(cas.hooks.HookPolicy.require_observed, parsed.hook_policy);
}

test "terminal proof failure requires tuple identity" {
    const review_result =
        "{\"findings\":[],\"overallCorrectness\":\"patch is correct\"," ++
        "\"overallExplanation\":\"clean\",\"overallConfidenceScore\":1}";
    var status = ReviewStatus{
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
        .review_result_json = try std.testing.allocator.dupe(u8, review_result),
        .review_text = try std.testing.allocator.dupe(u8, "No findings."),
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);
    const missing_base = TargetIdentity{
        .base_sha = null,
        .head_sha = "head",
        .fingerprint = "fp",
    };

    const failure = terminalBindingFailureForIdentity(
        std.testing.allocator,
        status,
        missing_base,
    ) orelse return error.ExpectedTerminalProofFailure;
    try std.testing.expectEqualStrings("target_identity_unavailable", failure.code);
    const missing_identity_failure = terminalBindingFailureForOptionalIdentity(
        std.testing.allocator,
        status,
        null,
    ) orelse return error.ExpectedTerminalProofFailure;
    try std.testing.expectEqualStrings(
        "target_identity_unavailable",
        missing_identity_failure.code,
    );
}

test "targetIdentityForRecordAlloc prefers stored tuple fields" {
    const record = SessionRecord{
        .cwd = "/path/that/does/not/need/git",
        .parent_thread_id = "parent",
        .review_thread_id = "thr_1",
        .review_turn_id = "turn_1",
        .delivery = "detached",
        .target = .{ .type = "uncommittedChanges" },
        .event_log_path = "/tmp/events.ndjson",
        .created_at_unix_s = 1,
        .last_observed_status = "completed",
        .codex_version = "codex-test",
        .base_sha = "stored_base",
        .head_sha = "stored_head+dirty:sha256:old",
        .target_fingerprint = "stored_fp",
    };

    const identity = try targetIdentityForRecordAlloc(std.testing.allocator, record);
    defer identity.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("stored_base", identity.base_sha.?);
    try std.testing.expectEqualStrings("stored_head+dirty:sha256:old", identity.head_sha.?);
    try std.testing.expectEqualStrings("stored_fp", identity.fingerprint);
}

test "start receipt tuple verdict detection requires tuple and review thread" {
    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    try std.testing.expect(startReceiptTupleVerdictExists(std.testing.allocator, "{\"tupleVerdictExists\":true}", "thr_1", identity, null, false));
    try std.testing.expect(!startReceiptTupleVerdictExists(std.testing.allocator, "{\"tupleVerdictExists\":false}", "thr_1", identity, null, false));
    try std.testing.expect(!startReceiptTupleVerdictExists(std.testing.allocator, null, "thr_1", identity, null, false));
    try std.testing.expect(!startReceiptTupleVerdictExists(std.testing.allocator, "{\"tupleVerdictExists\":true}", null, identity, null, false));
    try std.testing.expect(!startReceiptTupleVerdictExists(std.testing.allocator, "{\"tupleVerdictExists\":true}", "thr_1", identity, null, true));

    const missing_base = TargetIdentity{
        .base_sha = null,
        .head_sha = "head",
        .fingerprint = "fp",
    };
    try std.testing.expect(!startReceiptTupleVerdictExists(std.testing.allocator, "{\"tupleVerdictExists\":true}", "thr_1", missing_base, null, false));

    const missing_head = TargetIdentity{
        .base_sha = "base",
        .head_sha = null,
        .fingerprint = "fp",
    };
    try std.testing.expect(!startReceiptTupleVerdictExists(
        std.testing.allocator,
        "{\"tupleVerdictExists\":true}",
        "thr_1",
        missing_head,
        null,
        false,
    ));

    const empty_fingerprint = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "",
    };
    try std.testing.expect(!startReceiptTupleVerdictExists(
        std.testing.allocator,
        "{\"tupleVerdictExists\":true}",
        "thr_1",
        empty_fingerprint,
        null,
        false,
    ));
}

test "normalizer treats null start reviewResult as non-proof" {
    const raw =
        "{\"demo\":\"cas-review-session\",\"action\":\"start\"," ++
        "\"reviewAttemptPhase\":\"review_started\",\"reviewAttemptExists\":true," ++
        "\"tupleVerdictExists\":false,\"reviewThreadId\":\"thr_waiting\"," ++
        "\"reviewTurnId\":\"turn_waiting\",\"baseSha\":\"base\",\"headSha\":\"head\"," ++
        "\"targetFingerprint\":\"fp\",\"recordPath\":\"/tmp/record.json\"," ++
        "\"eventLogPath\":\"/tmp/events.ndjson\",\"reviewResult\":null}";
    const receipt = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "start-null.json",
        raw,
        true,
        .{},
    );
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("incomplete", receipt.status);
    try std.testing.expectEqualStrings("review_started", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expect(!receipt.clean);
}

test "target selector and custom instructions remain independently bound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(
        std.Io.Threaded.global_single_threaded.io(),
        .{ .sub_path = "review.txt", .data = "loaded instruction body" },
    );
    const instruction_path = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "review.txt",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(instruction_path);
    const instruction_arg = try std.fmt.allocPrint(
        std.testing.allocator,
        "@{s}",
        .{instruction_path},
    );
    defer std.testing.allocator.free(instruction_arg);
    const argv = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--custom-instructions",
        instruction_arg,
    };
    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(TargetKind.base_branch, parsed.target.?.kind);
    try std.testing.expectEqualStrings("main", parsed.target.?.branch.?);
    try std.testing.expectEqualStrings("loaded instruction body", parsed.custom_instructions.?);

    const target_json = try buildTargetJson(std.testing.allocator, parsed.target.?);
    defer std.testing.allocator.free(target_json);
    var target_value = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        target_json,
        .{},
    );
    defer target_value.deinit();
    try std.testing.expectEqualStrings(
        "baseBranch",
        target_value.value.object.get("type").?.string,
    );
    try std.testing.expectEqualStrings(
        "main",
        target_value.value.object.get("branch").?.string,
    );
    try std.testing.expect(target_value.value.object.get("instructions") == null);

    const target_record = targetToRecord(parsed.target.?);
    try std.testing.expectEqualStrings("baseBranch", target_record.type);
    try std.testing.expectEqualStrings("main", target_record.branch.?);

    const reverse_argv = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/tmp/repo",
        "--custom-instructions",
        instruction_arg,
        "--base",
        "main",
    };
    const reverse = try parseArgs(std.testing.allocator, &reverse_argv);
    defer reverse.deinit(std.testing.allocator);
    try std.testing.expectEqual(TargetKind.base_branch, reverse.target.?.kind);
    try std.testing.expectEqualStrings("main", reverse.target.?.branch.?);
    try std.testing.expectEqualStrings("loaded instruction body", reverse.custom_instructions.?);
}

fn runTestGitCommand(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv_tail: []const []const u8,
) !void {
    const output = try gitOutputAlloc(
        allocator,
        std.testing.io,
        cwd,
        argv_tail,
    );
    defer allocator.free(output);
}

test "commit selectors canonicalize and subject identity recaptures instructions and dirty state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try runTestGitCommand(allocator, root, &.{ "init", "--quiet" });
    try runTestGitCommand(allocator, root, &.{ "config", "user.email", "cas-test@example.com" });
    try runTestGitCommand(allocator, root, &.{ "config", "user.name", "CAS Test" });
    try runTestGitCommand(allocator, root, &.{ "config", "commit.gpgsign", "false" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "first\n" });
    try runTestGitCommand(allocator, root, &.{ "add", "tracked.txt" });
    try runTestGitCommand(allocator, root, &.{ "commit", "--quiet", "-m", "first" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "second\n" });
    try runTestGitCommand(allocator, root, &.{ "add", "tracked.txt" });
    try runTestGitCommand(allocator, root, &.{ "commit", "--quiet", "-m", "second" });

    const expected_oid = try gitOutputAlloc(
        allocator,
        io,
        root,
        &.{ "rev-parse", "--verify", "HEAD^{commit}" },
    );
    defer allocator.free(expected_oid);
    const canonical = try canonicalTargetAlloc(
        allocator,
        io,
        root,
        .{ .kind = .commit, .sha = "HEAD" },
    );
    defer canonical.deinit(allocator);
    try std.testing.expectEqualStrings(expected_oid, canonical.value.sha.?);
    try std.testing.expect(!std.mem.eql(u8, canonical.value.sha.?, "HEAD"));

    var initial = try computeTargetIdentityAlloc(
        allocator,
        io,
        root,
        .{ .kind = .uncommitted },
        "review law A",
    );
    defer initial.deinit(allocator);
    var same = try computeTargetIdentityAlloc(
        allocator,
        io,
        root,
        .{ .kind = .uncommitted },
        "review law A",
    );
    defer same.deinit(allocator);
    try std.testing.expect(targetIdentitiesEqual(initial, same));

    var other_instructions = try computeTargetIdentityAlloc(
        allocator,
        io,
        root,
        .{ .kind = .uncommitted },
        "review law B",
    );
    defer other_instructions.deinit(allocator);
    try std.testing.expect(!targetIdentitiesEqual(initial, other_instructions));

    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "changed after capture\n" });
    var changed = try computeTargetIdentityAlloc(
        allocator,
        io,
        root,
        .{ .kind = .uncommitted },
        "review law A",
    );
    defer changed.deinit(allocator);
    try std.testing.expect(!targetIdentitiesEqual(initial, changed));
}

test "repo realpath canonicalizes subdirectories and dirty capture covers repository" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try runTestGitCommand(allocator, root, &.{ "init", "--quiet" });
    try runTestGitCommand(allocator, root, &.{ "config", "user.email", "cas-test@example.com" });
    try runTestGitCommand(allocator, root, &.{ "config", "user.name", "CAS Test" });
    try runTestGitCommand(allocator, root, &.{ "config", "commit.gpgsign", "false" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "tracked\n" });
    try runTestGitCommand(allocator, root, &.{ "add", "tracked.txt" });
    try runTestGitCommand(allocator, root, &.{ "commit", "--quiet", "-m", "initial" });
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    try tmp.dir.writeFile(io, .{ .sub_path = "b/outside.txt", .data = "first\n" });

    const nested = try tmp.dir.realPathFileAlloc(io, "a", allocator);
    defer allocator.free(nested);
    const canonical = try repoRealpathAlloc(allocator, nested);
    defer allocator.free(canonical);
    try std.testing.expectEqualStrings(root, canonical);

    var initial = try computeTargetIdentityAlloc(
        allocator,
        io,
        canonical,
        .{ .kind = .uncommitted },
        null,
    );
    defer initial.deinit(allocator);
    try tmp.dir.writeFile(io, .{ .sub_path = "b/outside.txt", .data = "second\n" });
    var changed = try computeTargetIdentityAlloc(
        allocator,
        io,
        canonical,
        .{ .kind = .uncommitted },
        null,
    );
    defer changed.deinit(allocator);
    try std.testing.expect(!targetIdentitiesEqual(initial, changed));
}

test "dirty subject capture binds untracked symlinks without following them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try runTestGitCommand(allocator, root, &.{ "init", "--quiet" });
    try runTestGitCommand(allocator, root, &.{ "config", "user.email", "cas-test@example.com" });
    try runTestGitCommand(allocator, root, &.{ "config", "user.name", "CAS Test" });
    try runTestGitCommand(allocator, root, &.{ "config", "commit.gpgsign", "false" });
    try runTestGitCommand(
        allocator,
        root,
        &.{ "commit", "--quiet", "--allow-empty", "-m", "initial" },
    );
    try tmp.dir.createDirPath(io, "target-dir");
    try tmp.dir.symLink(io, "target-dir", "dir-link", .{ .is_directory = true });
    try tmp.dir.symLink(io, "missing-a", "dangling", .{});
    var first = try computeTargetIdentityAlloc(
        allocator,
        io,
        root,
        .{ .kind = .uncommitted },
        null,
    );
    defer first.deinit(allocator);

    try tmp.dir.deleteFile(io, "dangling");
    try tmp.dir.symLink(io, "missing-b", "dangling", .{});
    var second = try computeTargetIdentityAlloc(
        allocator,
        io,
        root,
        .{ .kind = .uncommitted },
        null,
    );
    defer second.deinit(allocator);
    try std.testing.expect(!targetIdentitiesEqual(first, second));
}

test "dirty subject capture propagates Git failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.heap.page_allocator;
    try tmp.dir.writeFile(
        std.testing.io,
        .{ .sub_path = ".git", .data = "gitdir: /definitely/missing/cas-test-gitdir\n" },
    );
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        allocator,
    );
    defer allocator.free(root);
    try std.testing.expectError(
        error.GitCommandFailed,
        dirtyStateDigestAlloc(
            allocator,
            std.testing.io,
            root,
        ),
    );
}

test "receipt normalizer accepts full CAS receipt" {
    const raw =
        "{\"demo\":\"cas-review-session\",\"action\":\"start\",\"reviewThreadId\":\"thr_1\"," ++
        "\"reviewTurnId\":\"turn_1\",\"recordPath\":\"/tmp/record.json\"," ++
        "\"eventLogPath\":\"/tmp/event.jsonl\",\"targetFingerprint\":\"fp_1\"," ++
        "\"headSha\":\"head_1\",\"baseSha\":\"base_1\",\"reviewVerdict\":{" ++
        "\"status\":\"clean\",\"backendClass\":\"cas-start-wait\",\"clean\":true," ++
        "\"findingCount\":0,\"failureCode\":null,\"failureHint\":null," ++
        "\"baseSha\":\"base_1\",\"headSha\":\"head_1\",\"targetFingerprint\":\"fp_1\"," ++
        "\"reviewThreadId\":\"thr_1\",\"reviewTurnId\":\"turn_1\"," ++
        "\"recordPath\":\"/tmp/record.json\",\"eventLogPath\":\"/tmp/event.jsonl\"," ++
        "\"findings\":[]}}";
    const receipt = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "review.json",
        raw,
        true,
        .{},
    );
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("review.json", receipt.source_path);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expectEqualStrings("cas-start-wait", receipt.backend_class);
    try std.testing.expect(receipt.clean);
    try std.testing.expectEqual(@as(usize, 0), receipt.finding_count);
    try std.testing.expectEqualStrings("normalized_verdict", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings(principal_strength_reduced, receipt.principal_strength);
    try std.testing.expect(receipt.account_fingerprint_reduced_protection);
    try std.testing.expect(!normalizedReceiptCommandSucceeded(receipt));
    try std.testing.expectEqualStrings("base_1", receipt.base_sha.?);
    try std.testing.expectEqualStrings("head_1", receipt.head_sha.?);
    try std.testing.expectEqualStrings("fp_1", receipt.target_fingerprint.?);
    try std.testing.expectEqualStrings("thr_1", receipt.review_thread_id.?);
}

test "receipt normalizer accepts strong principal metadata" {
    const raw =
        "{\"demo\":\"cas-review-session\",\"action\":\"start\",\"reviewThreadId\":\"thr_1\"," ++
        "\"reviewTurnId\":\"turn_1\",\"recordPath\":\"/tmp/record.json\"," ++
        "\"eventLogPath\":\"/tmp/event.jsonl\",\"targetFingerprint\":\"fp_1\"," ++
        "\"headSha\":\"head_1\",\"baseSha\":\"base_1\"," ++
        "\"accountFingerprint\":\"acct:abc\",\"accountFingerprintReducedProtection\":false," ++
        "\"reviewVerdict\":{\"status\":\"clean\",\"backendClass\":\"cas-start-wait\"," ++
        "\"clean\":true,\"findingCount\":0,\"failureCode\":null,\"failureHint\":null," ++
        "\"baseSha\":\"base_1\",\"headSha\":\"head_1\",\"targetFingerprint\":\"fp_1\"," ++
        "\"reviewThreadId\":\"thr_1\",\"reviewTurnId\":\"turn_1\"," ++
        "\"recordPath\":\"/tmp/record.json\",\"eventLogPath\":\"/tmp/event.jsonl\"," ++
        "\"findings\":[]}}";
    const receipt = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "review-strong.json",
        raw,
        true,
        .{},
    );
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expect(receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings(principal_strength_strong, receipt.principal_strength);
    try std.testing.expect(!receipt.account_fingerprint_reduced_protection);
    try std.testing.expect(normalizedReceiptCommandSucceeded(receipt));
}

test "CAS-RER writer projects terminal findings receipt" {
    const raw =
        "{\"cwd\":\"/tmp/repo\",\"status\":\"findings\"," ++
        "\"target\":" ++ test_uncommitted_target_json ++ "," ++
        "\"backendClass\":\"cas-start-wait\",\"clean\":false,\"findingCount\":1," ++
        "\"failureCode\":null,\"failureHint\":null," ++
        "\"reviewAttemptPhase\":\"normalized_verdict\",\"baseSha\":\"base_rer\"," ++
        "\"headSha\":\"head_rer\",\"targetFingerprint\":\"fp_rer\"," ++
        "\"reviewThreadId\":\"thr_rer\",\"reviewTurnId\":\"turn_rer\"," ++
        "\"recordPath\":\"/tmp/record.json\",\"eventLogPath\":\"/tmp/event.jsonl\"," ++
        "\"findings\":[{\"title\":\"Ledger issue\",\"file\":\"/tmp/a.zig\"," ++
        "\"line\":12,\"priority\":1}]}";
    const receipt = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "findings-receipt.json",
        raw,
        true,
        .{},
    );
    defer receipt.deinit(std.testing.allocator);

    const rer_json = try casRerJsonFromReceiptAlloc(
        std.testing.allocator,
        receipt,
        testCasRerProjectionOptions("unix-ns:1"),
    );
    defer std.testing.allocator.free(rer_json);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        rer_json,
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(
        cas_review_evidence_schema,
        root.get("schema").?.string,
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        root.get("recordId").?.string,
        "rer_",
    ));
    try std.testing.expectEqualStrings(
        "run",
        root.get("command").?.object.get("surface").?.string,
    );
    try std.testing.expectEqualStrings(
        "base_rer",
        root.get("tuple").?.object.get("baseSha").?.string,
    );
    try std.testing.expectEqualStrings(
        "head_rer",
        root.get("tuple").?.object.get("headSha").?.string,
    );
    try std.testing.expectEqualStrings(
        "fp_rer",
        root.get("tuple").?.object.get("targetFingerprint").?.string,
    );
    const attempt = root.get("attempt").?.object;
    try std.testing.expect(attempt.get("exists").?.bool);
    try std.testing.expect(std.mem.startsWith(
        u8,
        attempt.get("attemptId").?.string,
        "sha256:",
    ));
    try std.testing.expectEqualStrings("thr_rer", attempt.get("reviewThreadId").?.string);
    var copied_receipt = receipt;
    copied_receipt.source_path = "/tmp/copied-findings-receipt.json";
    const copied_attempt_id = (try casRerAttemptIdAlloc(
        std.testing.allocator,
        copied_receipt,
    )).?;
    defer std.testing.allocator.free(copied_attempt_id);
    try std.testing.expectEqualStrings(attempt.get("attemptId").?.string, copied_attempt_id);
    const verdict = root.get("verdict").?.object;
    try std.testing.expect(verdict.get("tupleVerdictExists").?.bool);
    try std.testing.expectEqualStrings("findings", verdict.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 1), verdict.get("findingCount").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, rer_json, "Ledger issue") != null);
    const principal = root.get("principal").?.object;
    try std.testing.expectEqualStrings(
        principal_strength_reduced,
        principal.get("kind").?.string,
    );
    try std.testing.expect(!principal.get("proofUsable").?.bool);
    try std.testing.expect(root.get("workflowBinding") == null);

    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "rer.json", root);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(gate.ok());
}

test "CAS-RER target projection preserves schema-4 target variants and identity" {
    const targets = [_]TargetRecord{
        .{ .type = "uncommittedChanges" },
        .{ .type = "baseBranch", .branch = "main" },
        .{
            .type = "commit",
            .sha = "0123456789abcdef",
            .title = "subject",
        },
    };
    const expected_targets = [_][]const u8{
        test_uncommitted_target_json,
        test_base_target_json,
        test_commit_target_json,
    };
    var record_ids: [targets.len][]u8 = undefined;
    var initialized: usize = 0;
    defer for (record_ids[0..initialized]) |record_id| {
        std.testing.allocator.free(record_id);
    };

    for (targets, 0..) |target, index| {
        const target_json = try stringifyAnyAlloc(std.testing.allocator, target);
        defer std.testing.allocator.free(target_json);
        try std.testing.expectEqualStrings(expected_targets[index], target_json);
        const receipt = NormalizedReceipt{
            .source_path = "source.json",
            .status = "clean",
            .backend_class = "cas-start-wait",
            .clean = true,
            .finding_count = 0,
            .review_attempt_phase = "normalized_verdict",
            .review_attempt_exists = true,
            .tuple_verdict_exists = true,
            .base_sha = "base",
            .head_sha = "head",
            .target_fingerprint = "fingerprint",
            .target_json = target_json,
            .repo_realpath = "/tmp/repo",
            .review_thread_id = "thread",
            .review_turn_id = "turn",
            .record_path = "/tmp/record.json",
            .event_log_path = "/tmp/events.ndjson",
            .failure_code = null,
            .failure_hint = null,
            .failure_class = null,
            .retryable_same_tuple_now = null,
            .findings_json = "[]",
        };
        const rer_json = try casRerJsonFromReceiptAlloc(
            std.testing.allocator,
            receipt,
            testCasRerProjectionOptions("unix-ns:1"),
        );
        defer std.testing.allocator.free(rer_json);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            rer_json,
            .{},
        );
        defer parsed.deinit();
        const root = parsed.value.object;
        const tuple = root.get("tuple").?.object;
        const projected_target = tuple.get("target").?;
        try std.testing.expect(tuple.get("diffScope") == null);
        const projected_json = try canonicalTargetRecordJsonFromValueAlloc(
            std.testing.allocator,
            projected_target,
        );
        defer std.testing.allocator.free(projected_json);
        try std.testing.expectEqualStrings(target_json, projected_json);
        const gate = try validateCasRerRecordObjectAlloc(
            std.testing.allocator,
            "target-rer.json",
            root,
        );
        defer gate.deinit(std.testing.allocator);
        try std.testing.expect(gate.ok());
        record_ids[index] = try std.testing.allocator.dupe(
            u8,
            root.get("recordId").?.string,
        );
        initialized += 1;
    }

    try std.testing.expect(!std.mem.eql(u8, record_ids[0], record_ids[1]));
    try std.testing.expect(!std.mem.eql(u8, record_ids[1], record_ids[2]));
}

test "CAS-RER projection rejects a receipt without an owned target" {
    const raw =
        "{\"cwd\":\"/tmp/repo\",\"status\":\"clean\"," ++
        "\"backendClass\":\"cas-start-wait\",\"clean\":true," ++
        "\"findingCount\":0,\"reviewAttemptPhase\":\"normalized_verdict\"," ++
        "\"baseSha\":\"base\",\"headSha\":\"head\"," ++
        "\"targetFingerprint\":\"fingerprint\",\"reviewThreadId\":\"thread\"," ++
        "\"reviewTurnId\":\"turn\",\"findings\":[]}";
    const receipt = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "targetless.json",
        raw,
        true,
        .{},
    );
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expect(receipt.target_json == null);
    try std.testing.expectError(
        error.MissingCasRerTarget,
        casRerJsonFromReceiptAlloc(
            std.testing.allocator,
            receipt,
            testCasRerProjectionOptions("unix-ns:1"),
        ),
    );
}

test "CAS-RER binding is source carried validated and identity bearing" {
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"cwd\":\"/tmp/repo\",\"status\":\"clean\"," ++
            "\"target\":{s}," ++
            "\"backendClass\":\"cas-start-wait\",\"clean\":true,\"findingCount\":0," ++
            "\"failureCode\":null,\"reviewAttemptPhase\":\"normalized_verdict\"," ++
            "\"baseSha\":\"base\",\"headSha\":\"head\",\"targetFingerprint\":\"fp\"," ++
            "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"," ++
            "\"workflowBinding\":{s},\"findings\":[]}}",
        .{ test_uncommitted_target_json, test_workflow_binding_json },
    );
    defer std.testing.allocator.free(raw);
    const bound = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "bound.json",
        raw,
        true,
        .{},
    );
    defer bound.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(test_workflow_binding_json, bound.workflow_binding_json.?);

    const bound_json = try casRerJsonFromReceiptAlloc(
        std.testing.allocator,
        bound,
        testCasRerProjectionOptions("unix-ns:1"),
    );
    defer std.testing.allocator.free(bound_json);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        bound_json,
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(
        "request-test",
        root.get("workflowBinding").?.object.get("requestId").?.string,
    );
    const gate = try validateCasRerRecordObjectAlloc(
        std.testing.allocator,
        "bound-rer.json",
        root,
    );
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(gate.ok());

    const invalid_json = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        bound_json,
        ",\"requestFingerprint\":\"sha256:request\"",
        "",
    );
    defer std.testing.allocator.free(invalid_json);
    var invalid_parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        invalid_json,
        .{},
    );
    defer invalid_parsed.deinit();
    const invalid_gate = try validateCasRerRecordObjectAlloc(
        std.testing.allocator,
        "partial-bound-rer.json",
        invalid_parsed.value.object,
    );
    defer invalid_gate.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_gate.ok());

    var unbound = bound;
    unbound.workflow_binding_json = null;
    const bound_id = try casRerRecordIdAlloc(
        std.testing.allocator,
        bound,
        testCasRerProjectionOptions("unix-ns:1"),
    );
    defer std.testing.allocator.free(bound_id);
    const unbound_id = try casRerRecordIdAlloc(
        std.testing.allocator,
        unbound,
        testCasRerProjectionOptions("unix-ns:1"),
    );
    defer std.testing.allocator.free(unbound_id);
    try std.testing.expect(!std.mem.eql(u8, bound_id, unbound_id));
}

test "CAS run shell success requires clean proof usable principal" {
    const strong_findings = NormalizedReceipt{
        .source_path = "/tmp/receipt.json",
        .status = "findings",
        .backend_class = "cas-start-wait",
        .clean = false,
        .finding_count = 1,
        .review_attempt_phase = "normalized_verdict",
        .review_attempt_exists = true,
        .tuple_verdict_exists = true,
        .principal_strength = principal_strength_strong,
        .account_fingerprint_reduced_protection = false,
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .repo_realpath = "/tmp/repo",
        .resolved_codex_path = "/bin/codex",
        .resolved_codex_version = "codex 0.1.0",
        .account_fingerprint = "acct:test",
        .review_thread_id = "thr",
        .review_turn_id = "turn",
        .record_path = "/tmp/record.json",
        .event_log_path = "/tmp/events.ndjson",
        .failure_code = null,
        .failure_hint = null,
        .failure_class = null,
        .retryable_same_tuple_now = null,
        .findings_json = "[]",
    };
    try std.testing.expect(casRerPrincipalProofUsable(strong_findings));
    try std.testing.expect(!normalizedReceiptCommandSucceeded(strong_findings));

    var strong_clean = strong_findings;
    strong_clean.status = "clean";
    strong_clean.clean = true;
    strong_clean.finding_count = 0;
    try std.testing.expect(normalizedReceiptCommandSucceeded(strong_clean));

    var reduced = strong_clean;
    reduced.principal_strength = principal_strength_reduced;
    try std.testing.expect(!normalizedReceiptCommandSucceeded(reduced));

    var unknown_account = strong_clean;
    unknown_account.account_fingerprint = unknown_account_fingerprint;
    try std.testing.expect(!normalizedReceiptCommandSucceeded(unknown_account));
}

test "start shadow payload carries Codex identity into CAS-RER tuple" {
    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    const receipt = OutputReceipt{
        .surface_action = "start",
        .resolved_codex_path = "/bin/codex",
        .resolved_codex_version = "codex 0.1.0",
        .account_fingerprint = "acct:test",
        .account_fingerprint_reduced_protection = false,
    };
    const payload_json = try startShadowReceiptPayloadJsonAlloc(
        std.testing.allocator,
        "/tmp/repo",
        "parent",
        "thr",
        "turn",
        "/tmp/record.json",
        "/tmp/events.ndjson",
        identity,
        .{ .type = "uncommittedChanges" },
        receipt,
        "review_started",
    );
    defer std.testing.allocator.free(payload_json);

    try std.testing.expect(std.mem.indexOf(
        u8,
        payload_json,
        "\"resolvedCodexPath\":\"/bin/codex\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        payload_json,
        "\"resolvedCodexVersion\":\"codex 0.1.0\"",
    ) != null);

    const normalized = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "/tmp/record.json",
        payload_json,
        true,
        .{
            .requested_identity = identity,
            .requested_identity_required = true,
        },
    );
    defer normalized.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/bin/codex", normalized.resolved_codex_path.?);
    try std.testing.expectEqualStrings("codex 0.1.0", normalized.resolved_codex_version.?);
    try std.testing.expectEqualStrings(
        test_uncommitted_target_json,
        normalized.target_json.?,
    );

    const rer_json = try casRerJsonFromReceiptAlloc(
        std.testing.allocator,
        normalized,
        testCasRerProjectionOptions("unix-ns:1"),
    );
    defer std.testing.allocator.free(rer_json);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        rer_json,
        .{},
    );
    defer parsed.deinit();
    const tuple = parsed.value.object.get("tuple").?.object;
    try std.testing.expectEqualStrings("/bin/codex", tuple.get("resolvedCodexPath").?.string);
    try std.testing.expectEqualStrings(
        "codex 0.1.0",
        tuple.get("resolvedCodexVersion").?.string,
    );
    try std.testing.expectEqualStrings(
        "uncommittedChanges",
        tuple.get("target").?.object.get("type").?.string,
    );
    try std.testing.expect(tuple.get("tupleCurrentAtRecordTime") == null);
}

const test_cas_rer_tuple =
    "\"tuple\":{\"repoRealpath\":\"/tmp/repo\",\"target\":" ++
    test_uncommitted_target_json ++ ",\"baseSha\":\"base\"," ++
    "\"headSha\":\"head\",\"targetFingerprint\":\"fp\"}";

const test_cas_rer_null_failure =
    "\"failure\":{\"failureCode\":null,\"failureClass\":null," ++
    "\"retryableSameTupleNow\":null}";

const test_cas_rer_strong_principal =
    "\"principal\":{\"kind\":\"strong\",\"accountFingerprint\":\"acct:test\"," ++
    "\"proofUsable\":true,\"reduced\":false,\"fallbackUsed\":false," ++
    "\"source\":\"cas-start-wait\"}";

test "CAS-RER validator rejects findings without finding count" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_bad\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"findings\"," ++
        "\"clean\":false,\"findingCount\":0,\"findings\":[]}," ++
        test_cas_rer_null_failure ++ "," ++ test_cas_rer_strong_principal ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "bad-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(gate, "findingCount > 0"));
}

test "CAS-RER validator rejects findings count without findings entries" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_findings_empty\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"findings\"," ++
        "\"clean\":false,\"findingCount\":1,\"findings\":[]}," ++
        test_cas_rer_null_failure ++ "," ++ test_cas_rer_strong_principal ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "findings-empty-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(gate, "findings length"));
}

test "CAS-RER validator rejects non-terminal tuple verdicts" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_tuple_timeout\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"review_waiting\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"timeout\"," ++
        "\"clean\":false,\"findingCount\":0,\"findings\":[]}," ++
        "\"failure\":{\"failureCode\":\"wait_timed_out\",\"failureClass\":\"timeout\"," ++
        "\"retryableSameTupleNow\":true}," ++ test_cas_rer_strong_principal ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "tuple-timeout-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(gate, "terminal clean or findings"));
}

test "CAS-RER validator rejects terminal tuple verdict with waiting phase" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_waiting_clean\"," ++
        "\"command\":{\"surface\":\"run\",\"backendSelected\":\"cas-run\"," ++
        "\"brokerDecision\":{\"action\":\"created_new\",\"reason\":\"test\"," ++
        "\"freshAttemptRequired\":false}}," ++ test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"review_waiting\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"clean\"," ++
        "\"clean\":true,\"findingCount\":0,\"findings\":[]}," ++
        test_cas_rer_null_failure ++ "," ++ test_cas_rer_strong_principal ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "waiting-clean-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(gate, "terminal attempt.phase"));
}

test "CAS-RER validator rejects unparseable timestamps" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_bad_timestamp\"," ++
        "\"createdAt\":\"zzzz\",\"updatedAt\":\"unix-ns:1\"," ++
        "\"command\":{\"surface\":\"run\",\"backendSelected\":\"cas-run\"," ++
        "\"brokerDecision\":{\"action\":\"created_new\",\"reason\":\"test\"," ++
        "\"freshAttemptRequired\":false}}," ++ test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"clean\"," ++
        "\"clean\":true,\"findingCount\":0,\"findings\":[]}," ++
        test_cas_rer_null_failure ++ "," ++ test_cas_rer_strong_principal ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "bad-timestamp-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gateErrorsContain(gate, "createdAt"));
}

test "CAS-RER validator rejects verdict clean/status disagreement" {
    const clean_false_raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_clean_false\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"clean\"," ++
        "\"clean\":false,\"findingCount\":0,\"findings\":[]}," ++
        test_cas_rer_null_failure ++ "," ++ test_cas_rer_strong_principal ++ "}";
    var clean_false = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, clean_false_raw, .{});
    defer clean_false.deinit();
    const clean_false_gate = try validateCasRerRecordObjectAlloc(
        std.testing.allocator,
        "clean-false-rer.json",
        clean_false.value.object,
    );
    defer clean_false_gate.deinit(std.testing.allocator);
    try std.testing.expect(!clean_false_gate.ok());
    try std.testing.expect(clean_false_gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(clean_false_gate, "verdict.clean=true"));

    const findings_true_raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_findings_true\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"findings\"," ++
        "\"clean\":true,\"findingCount\":1,\"findings\":[{\"title\":\"issue\"}]}," ++
        test_cas_rer_null_failure ++ "," ++ test_cas_rer_strong_principal ++ "}";
    var findings_true = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        findings_true_raw,
        .{},
    );
    defer findings_true.deinit();
    const findings_true_gate = try validateCasRerRecordObjectAlloc(
        std.testing.allocator,
        "findings-true-rer.json",
        findings_true.value.object,
    );
    defer findings_true_gate.deinit(std.testing.allocator);
    try std.testing.expect(!findings_true_gate.ok());
    try std.testing.expect(findings_true_gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(findings_true_gate, "verdict.clean=false"));
}

test "CAS-RER validator rejects terminal verdict failure metadata" {
    const clean_failure_class_raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_clean_failure_class\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"clean\"," ++
        "\"clean\":true,\"findingCount\":0,\"findings\":[]}," ++
        "\"failure\":{\"failureCode\":null,\"failureClass\":\"transport\"," ++
        "\"retryableSameTupleNow\":null}," ++ test_cas_rer_strong_principal ++ "}";
    var clean_failure_class = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        clean_failure_class_raw,
        .{},
    );
    defer clean_failure_class.deinit();
    const clean_gate = try validateCasRerRecordObjectAlloc(
        std.testing.allocator,
        "clean-failure-class-rer.json",
        clean_failure_class.value.object,
    );
    defer clean_gate.deinit(std.testing.allocator);
    try std.testing.expect(!clean_gate.ok());
    try std.testing.expect(clean_gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(clean_gate, "failure.failureClass=null"));

    const findings_failure_raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_findings_failure\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"findings\"," ++
        "\"clean\":false,\"findingCount\":1,\"findings\":[{\"title\":\"issue\"}]}," ++
        "\"failure\":{\"failureCode\":\"review_output_invalid\",\"failureClass\":null," ++
        "\"retryableSameTupleNow\":null}," ++ test_cas_rer_strong_principal ++ "}";
    var findings_failure = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        findings_failure_raw,
        .{},
    );
    defer findings_failure.deinit();
    const findings_gate = try validateCasRerRecordObjectAlloc(
        std.testing.allocator,
        "findings-failure-rer.json",
        findings_failure.value.object,
    );
    defer findings_gate.deinit(std.testing.allocator);
    try std.testing.expect(!findings_gate.ok());
    try std.testing.expect(findings_gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(findings_gate, "failure.failureCode=null"));
}

test "CAS-RER validator rejects terminal verdict without attempt" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_no_attempt\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":false,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":null,\"reviewTurnId\":null}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"clean\"," ++
        "\"clean\":true,\"findingCount\":0,\"findings\":[]}," ++
        test_cas_rer_null_failure ++ "," ++ test_cas_rer_strong_principal ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "no-attempt-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gate.errors.len >= 3);
    try std.testing.expect(gateErrorsContain(gate, "attempt.exists=true"));
}

test "CAS-RER validator rejects terminal tuple verdict without repo binding" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_no_repo\"," ++
        "\"tuple\":{\"repoRealpath\":null,\"target\":" ++
        test_uncommitted_target_json ++ ",\"baseSha\":\"base\",\"headSha\":\"head\"," ++
        "\"targetFingerprint\":\"fp\"}," ++
        "\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"clean\"," ++
        "\"clean\":true,\"findingCount\":0,\"findings\":[]}," ++
        test_cas_rer_null_failure ++ "," ++ test_cas_rer_strong_principal ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "no-repo-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(gate, "repoRealpath"));
}

test "CAS-RER validator rejects attempt exists with empty review thread id" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_empty_thread\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"review_waiting\"," ++
        "\"reviewThreadId\":\"\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":false,\"status\":\"incomplete\"," ++
        "\"clean\":false,\"findingCount\":0,\"findings\":[]}," ++
        "\"failure\":{\"failureCode\":null,\"failureClass\":null," ++
        "\"retryableSameTupleNow\":true}," ++ test_cas_rer_strong_principal ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "empty-thread-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(gate, "reviewThreadId non-empty"));
}

test "CAS-RER validator rejects proof usable principal without account fingerprint" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_unbound_principal\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"clean\"," ++
        "\"clean\":true,\"findingCount\":0,\"findings\":[]}," ++
        test_cas_rer_null_failure ++
        ",\"principal\":{\"kind\":\"strong\",\"proofUsable\":true,\"reduced\":false," ++
        "\"fallbackUsed\":false,\"source\":\"cas-start-wait\"}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "unbound-principal-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(gate, "accountFingerprint"));
}

test "CAS-RER validator rejects missing command section" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_missing_command\"," ++
        test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"clean\"," ++
        "\"clean\":true,\"findingCount\":0,\"findings\":[]}," ++
        test_cas_rer_null_failure ++ "," ++ test_cas_rer_strong_principal ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "missing-command-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gate.errors.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, gate.errors[0], "missing command") != null);
}

test "CAS-RER validator rejects incomplete command metadata" {
    const raw =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_empty_command\"," ++
        "\"command\":{}," ++ test_cas_rer_tuple ++
        ",\"attempt\":{\"exists\":true,\"phase\":\"normalized_verdict\"," ++
        "\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}," ++
        "\"verdict\":{\"tupleVerdictExists\":true,\"status\":\"clean\"," ++
        "\"clean\":true,\"findingCount\":0,\"findings\":[]}," ++
        test_cas_rer_null_failure ++ "," ++ test_cas_rer_strong_principal ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "empty-command-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gateErrorsContain(gate, "command.surface"));
    try std.testing.expect(gateErrorsContain(gate, "command.backendSelected"));
    try std.testing.expect(gateErrorsContain(gate, "command.brokerDecision"));
}

test "CAS-RER validator rejects null required sections" {
    const raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_nulls","tuple":null,"attempt":null,"verdict":null,"failure":null,"principal":null}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "null-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gate.errors.len >= 5);
}

test "CAS-RER ledger write rejects recordId collisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "rer_collision.json" });
    defer std.testing.allocator.free(path);

    try writeRawJsonFileExclusiveOrIdenticalAlloc(std.testing.allocator, path, "{\"recordId\":\"rer_collision\",\"value\":1}");
    try writeRawJsonFileExclusiveOrIdenticalAlloc(std.testing.allocator, path, "{\"recordId\":\"rer_collision\",\"value\":1}");
    try std.testing.expectError(error.CasRerRecordIdCollision, writeRawJsonFileExclusiveOrIdenticalAlloc(std.testing.allocator, path, "{\"recordId\":\"rer_collision\",\"value\":2}"));
}

test "CAS-RER ledger write accepts stable content with regenerated timestamps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "rer_same.json" });
    defer std.testing.allocator.free(path);

    const original_json =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_same\"," ++
        "\"createdAt\":\"unix-ns:1\",\"updatedAt\":\"unix-ns:1\"," ++
        "\"attempt\":{\"recordPath\":\"/tmp/original-session.json\"}," ++
        "\"attachments\":{\"rawSessionRecord\":\"/tmp/original-session.json\"," ++
        "\"rawReceipt\":\"/tmp/original.json\"},\"value\":1}";
    const copied_json =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_same\"," ++
        "\"createdAt\":\"unix-ns:2\",\"updatedAt\":\"unix-ns:2\"," ++
        "\"attempt\":{\"recordPath\":\"/tmp/archive/copy-session.json\"}," ++
        "\"attachments\":{\"rawSessionRecord\":\"/tmp/archive/copy-session.json\"," ++
        "\"rawReceipt\":\"/tmp/copy.json\"},\"value\":1}";
    const collision_json =
        "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_same\"," ++
        "\"createdAt\":\"unix-ns:3\",\"updatedAt\":\"unix-ns:3\",\"value\":2}";
    try writeRawJsonFileExclusiveOrIdenticalAlloc(
        std.testing.allocator,
        path,
        original_json,
    );
    try writeRawJsonFileExclusiveOrIdenticalAlloc(
        std.testing.allocator,
        path,
        copied_json,
    );
    try std.testing.expectError(
        error.CasRerRecordIdCollision,
        writeRawJsonFileExclusiveOrIdenticalAlloc(
            std.testing.allocator,
            path,
            collision_json,
        ),
    );
}

test "CAS-RER record id ignores volatile projection timestamps" {
    const receipt = NormalizedReceipt{
        .source_path = "source.json",
        .status = "clean",
        .backend_class = "cas-start-wait",
        .clean = true,
        .finding_count = 0,
        .review_attempt_phase = "normalized_verdict",
        .review_attempt_exists = true,
        .tuple_verdict_exists = true,
        .principal_strength = principal_strength_strong,
        .account_fingerprint_reduced_protection = false,
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .target_json = test_uncommitted_target_json,
        .repo_realpath = "/tmp/repo",
        .account_fingerprint = "acct:test",
        .review_thread_id = "thr",
        .review_turn_id = "turn",
        .record_path = "/tmp/record.json",
        .event_log_path = "/tmp/events.ndjson",
        .failure_code = null,
        .failure_hint = null,
        .failure_class = null,
        .retryable_same_tuple_now = null,
        .findings_json = "[]",
    };
    const first = try casRerRecordIdAlloc(
        std.testing.allocator,
        receipt,
        testCasRerProjectionOptions("unix-ns:1"),
    );
    defer std.testing.allocator.free(first);
    const second = try casRerRecordIdAlloc(
        std.testing.allocator,
        receipt,
        testCasRerProjectionOptions("unix-ns:2"),
    );
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);

    var copied_receipt = receipt;
    copied_receipt.source_path = "/tmp/copied-source.json";
    const copied = try casRerRecordIdAlloc(
        std.testing.allocator,
        copied_receipt,
        testCasRerProjectionOptions("unix-ns:3"),
    );
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings(first, copied);
}

test "CAS-RER record id includes stable projection identity" {
    const receipt = NormalizedReceipt{
        .source_path = "source.json",
        .status = "clean",
        .backend_class = "cas-start-wait",
        .clean = true,
        .finding_count = 0,
        .review_attempt_phase = "normalized_verdict",
        .review_attempt_exists = true,
        .tuple_verdict_exists = true,
        .principal_strength = principal_strength_strong,
        .account_fingerprint_reduced_protection = false,
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .target_json = test_uncommitted_target_json,
        .repo_realpath = "/tmp/repo",
        .resolved_codex_path = "/bin/codex",
        .resolved_codex_version = "codex 1.0.0",
        .account_fingerprint = "acct:test",
        .review_thread_id = "thr",
        .review_turn_id = "turn",
        .record_path = "/tmp/record.json",
        .event_log_path = "/tmp/events.ndjson",
        .failure_code = null,
        .failure_hint = null,
        .failure_class = null,
        .retryable_same_tuple_now = null,
        .findings_json = "[]",
    };
    const start_wait = try casRerRecordIdAlloc(std.testing.allocator, receipt, .{
        .command_surface = "start_wait",
        .backend_selected = "cas-start-wait",
        .broker_action = "created_new",
        .broker_reason = "test",
        .timestamp = "unix-ns:1",
    });
    defer std.testing.allocator.free(start_wait);
    const run = try casRerRecordIdAlloc(std.testing.allocator, receipt, .{
        .command_surface = "run",
        .backend_selected = "cas-run",
        .broker_action = "returned_terminal",
        .broker_reason = "test",
        .timestamp = "unix-ns:1",
    });
    defer std.testing.allocator.free(run);
    try std.testing.expect(!std.mem.eql(u8, start_wait, run));

    var reduced = receipt;
    reduced.account_fingerprint_reduced_protection = true;
    const reduced_id = try casRerRecordIdAlloc(std.testing.allocator, reduced, .{
        .command_surface = "start_wait",
        .backend_selected = "cas-start-wait",
        .broker_action = "created_new",
        .broker_reason = "test",
        .timestamp = "unix-ns:1",
    });
    defer std.testing.allocator.free(reduced_id);
    try std.testing.expect(!std.mem.eql(u8, start_wait, reduced_id));
}

test "CAS-RUN envelope verdict imports through wrapper without tuple mismatch" {
    const raw =
        "{\"schema\":\"CAS-RUN-v1\",\"record\":{" ++
        "\"schema\":\"CAS-RER-v1\"},\"reviewVerdict\":{" ++
        "\"status\":\"clean\",\"reviewAttemptPhase\":" ++
        "\"normalized_verdict\",\"reviewAttemptExists\":true," ++
        "\"tupleVerdictExists\":true,\"principalStrength\":\"strong\"," ++
        "\"accountFingerprint\":\"acct:test\"," ++
        "\"accountFingerprintReducedProtection\":false," ++
        "\"backendClass\":\"cas-start-wait\",\"clean\":true," ++
        "\"findingCount\":0,\"failureCode\":null,\"failureHint\":null," ++
        "\"baseSha\":\"base\",\"headSha\":\"head\"," ++
        "\"targetFingerprint\":\"fp\",\"reviewThreadId\":\"thr\"," ++
        "\"reviewTurnId\":\"turn\",\"findings\":[]}}";
    const requested = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    const receipt = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "run-envelope.json",
        raw,
        true,
        .{
            .requested_identity = requested,
            .requested_identity_required = true,
        },
    );
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expect(receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("base", receipt.base_sha.?);
    try std.testing.expectEqualStrings("head", receipt.head_sha.?);
    try std.testing.expectEqualStrings("fp", receipt.target_fingerprint.?);
}

test "receipt normalizer rejects target-only start receipt as proof" {
    const raw =
        \\{"demo":"cas-review-session","action":"start","reviewThreadId":"thr_target_only","reviewTurnId":"turn_target_only","targetFingerprint":"fp_only","reviewResult":{"findings":[],"overallCorrectness":"patch is correct","overallExplanation":"clean","overallConfidenceScore":1}}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "start-target-only.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
    try std.testing.expect(!normalizedReceiptCommandSucceeded(receipt));
}

test "receipt normalizer rejects start receipt when requested identity is incomplete" {
    const raw =
        \\{"demo":"cas-review-session","action":"start","reviewThreadId":"thr_1","reviewTurnId":"turn_1","targetFingerprint":"fp_only","reviewResult":{"findings":[],"overallCorrectness":"patch is correct","overallExplanation":"clean","overallConfidenceScore":1}}
    ;
    const requested = TargetIdentity{
        .base_sha = null,
        .head_sha = null,
        .fingerprint = "fp_only",
    };
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "start-missing-requested.json", raw, true, .{
        .requested_identity = requested,
        .requested_identity_required = true,
    });
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("target_identity_unavailable", receipt.failure_code.?);
}

test "receipt normalizer rejects target-only stored session as proof" {
    const raw =
        \\{"schema_version":3,"cwd":"/tmp/repo","parent_thread_id":"parent","review_thread_id":"thr_target_only","review_turn_id":"turn_target_only","delivery":"detached","target":{"type":"baseBranch","branch":"main"},"event_log_path":"/tmp/events.ndjson","created_at_unix_s":1,"last_observed_status":"completed","codex_version":"0.140.0","compatibility_verdict":"compatible","transport_kind":"websocket","terminal_review_result_source":"rollout_exited_review_mode","terminal_review_result_json":"{\"findings\":[],\"overallCorrectness\":\"patch is correct\",\"overallExplanation\":\"clean\",\"overallConfidenceScore\":1}","target_fingerprint":"fp_only"}
    ;
    try std.testing.expectError(
        error.InvalidSessionRecord,
        normalizeReceiptFromJsonAlloc(
            std.testing.allocator,
            "stored-target-only.json",
            raw,
            false,
            .{},
        ),
    );
}

test "receipt normalizer rejects stored session when requested identity is incomplete" {
    const raw =
        \\{"schema_version":3,"cwd":"/tmp/repo","parent_thread_id":"parent","review_thread_id":"thr_1","review_turn_id":"turn_1","delivery":"detached","target":{"type":"baseBranch","branch":"main"},"event_log_path":"/tmp/events.ndjson","created_at_unix_s":1,"last_observed_status":"completed","codex_version":"0.140.0","compatibility_verdict":"compatible","transport_kind":"websocket","terminal_review_result_source":"rollout_exited_review_mode","terminal_review_result_json":"{\"findings\":[],\"overallCorrectness\":\"patch is correct\",\"overallExplanation\":\"clean\",\"overallConfidenceScore\":1}","target_fingerprint":"fp_only"}
    ;
    const requested = TargetIdentity{
        .base_sha = null,
        .head_sha = null,
        .fingerprint = "fp_only",
    };
    try std.testing.expectError(
        error.InvalidSessionRecord,
        normalizeReceiptFromJsonAlloc(
            std.testing.allocator,
            "stored-missing-requested.json",
            raw,
            false,
            .{
                .requested_identity = requested,
                .requested_identity_required = true,
            },
        ),
    );
}

test "receipt normalizer flags mismatched tuple proof" {
    const raw =
        "{\"demo\":\"cas-review-session\",\"action\":\"start\"," ++
        "\"reviewThreadId\":\"thr_1\",\"reviewTurnId\":\"turn_1\"," ++
        "\"targetFingerprint\":\"requested_fp\",\"headSha\":\"requested_head\"," ++
        "\"baseSha\":\"requested_base\",\"reviewVerdict\":{\"status\":\"clean\"," ++
        "\"backendClass\":\"cas-start-wait\",\"clean\":true,\"findingCount\":0," ++
        "\"failureCode\":null,\"failureHint\":null,\"baseSha\":\"other_base\"," ++
        "\"headSha\":\"requested_head\",\"targetFingerprint\":\"requested_fp\"," ++
        "\"reviewThreadId\":\"thr_1\",\"reviewTurnId\":\"turn_1\",\"findings\":[]}}";
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "mismatch.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
}

test "receipt normalizer rejects incomplete requested identity as proof" {
    const raw =
        "{\"demo\":\"cas-review-session\",\"action\":\"start\"," ++
        "\"reviewThreadId\":\"thr_1\",\"reviewTurnId\":\"turn_1\"," ++
        "\"targetFingerprint\":\"requested_fp\",\"headSha\":null,\"baseSha\":null," ++
        "\"reviewVerdict\":{\"status\":\"clean\",\"backendClass\":\"cas-start-wait\"," ++
        "\"clean\":true,\"findingCount\":0,\"failureCode\":null,\"failureHint\":null," ++
        "\"targetFingerprint\":\"requested_fp\",\"reviewThreadId\":\"thr_1\"," ++
        "\"reviewTurnId\":\"turn_1\",\"findings\":[]}}";
    const requested = TargetIdentity{
        .base_sha = null,
        .head_sha = null,
        .fingerprint = "requested_fp",
    };
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "missing-requested-tuple.json", raw, true, .{
        .requested_identity = requested,
        .requested_identity_required = true,
    });
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("target_identity_unavailable", receipt.failure_code.?);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
}

test "receipt normalizer rejects pre-kernel stored findings recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const review_text =
        \\The patch is incorrect.
        \\
        \\Full review comments:
        \\
        \\- [P1] Keep idempotency keys aligned — /tmp/src/world.zig:10-12
        \\  This is the raw finding body that the compact title alone cannot preserve.
    ;
    const notification = try stringifyAnyAlloc(std.testing.allocator, .{
        .method = "item/completed",
        .params = .{
            .threadId = "thr_event",
            .turnId = "turn_event",
            .item = .{
                .type = "exitedReviewMode",
                .review = review_text,
            },
        },
    });
    defer std.testing.allocator.free(notification);
    const notification_json = try quoteJsonStringAlloc(std.testing.allocator, notification);
    defer std.testing.allocator.free(notification_json);
    const line = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"recordedAtUnixS\":1,\"method\":\"item/completed\",\"direction\":\"notification\",\"payload\":{s}}}\n",
        .{notification_json},
    );
    defer std.testing.allocator.free(line);
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "review.events.ndjson", .data = line });
    const event_log_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "review.events.ndjson", std.testing.allocator);
    defer std.testing.allocator.free(event_log_path);
    const event_log_path_json = try quoteJsonStringAlloc(std.testing.allocator, event_log_path);
    defer std.testing.allocator.free(event_log_path_json);

    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":3,\"cwd\":\"/tmp\",\"parent_thread_id\":\"parent\",\"review_thread_id\":\"thr_event\",\"review_turn_id\":\"turn_event\",\"delivery\":\"detached\",\"target\":{{\"type\":\"baseBranch\",\"branch\":\"main\"}},\"event_log_path\":{s},\"created_at_unix_s\":1,\"last_observed_status\":\"completed\",\"codex_version\":\"0.140.0\",\"compatibility_verdict\":\"compatible\",\"transport_kind\":\"websocket\",\"terminal_review_result_source\":null,\"terminal_review_result_json\":null}}",
        .{event_log_path_json},
    );
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(
        error.InvalidSessionRecord,
        normalizeReceiptFromJsonAlloc(
            std.testing.allocator,
            "stored.json",
            raw,
            true,
            .{},
        ),
    );
}

test "receipt normalizer rejects pre-kernel stored clean recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        \\{"type":"session_meta","payload":{"id":"thr_clean"}}
        \\{"type":"event_msg","payload":{"type":"exited_review_mode","review_output":{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"No issues found.","overall_confidence_score":0.88}}}
    ;
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "rollout.jsonl", .data = rollout });
    const rollout_path = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(rollout_path);

    const thread_read_payload = try stringifyAnyAlloc(std.testing.allocator, .{
        .thread = .{
            .id = "thr_clean",
            .path = rollout_path,
        },
    });
    defer std.testing.allocator.free(thread_read_payload);
    const thread_read_payload_json = try quoteJsonStringAlloc(std.testing.allocator, thread_read_payload);
    defer std.testing.allocator.free(thread_read_payload_json);
    const line = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"recordedAtUnixS\":1,\"method\":\"thread/read\",\"direction\":\"response\",\"payload\":{s}}}\n{{\"recordedAtUnixS\":2,\"method\":\"item/completed\",\"direction\":\"notification\",\"payload\":\"reviewer searched for usageLimitExceeded handling\"}}\n",
        .{thread_read_payload_json},
    );
    defer std.testing.allocator.free(line);
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "review.events.ndjson", .data = line });
    const event_log_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "review.events.ndjson", std.testing.allocator);
    defer std.testing.allocator.free(event_log_path);
    const event_log_path_json = try quoteJsonStringAlloc(std.testing.allocator, event_log_path);
    defer std.testing.allocator.free(event_log_path_json);

    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":3,\"cwd\":\"/tmp\",\"parent_thread_id\":\"parent\",\"review_thread_id\":\"thr_clean\",\"review_turn_id\":\"turn_clean\",\"delivery\":\"detached\",\"target\":{{\"type\":\"baseBranch\",\"branch\":\"main\"}},\"event_log_path\":{s},\"created_at_unix_s\":1,\"last_observed_status\":\"completed\",\"codex_version\":\"0.140.0\",\"compatibility_verdict\":\"compatible\",\"transport_kind\":\"websocket\",\"terminal_review_result_source\":null,\"terminal_review_result_json\":null}}",
        .{event_log_path_json},
    );
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(
        error.InvalidSessionRecord,
        normalizeReceiptFromJsonAlloc(
            std.testing.allocator,
            "stored-clean.json",
            raw,
            true,
            .{},
        ),
    );
}

test "receipt normalizer rejects pre-kernel snake-case stored tuple" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        \\{"type":"session_meta","payload":{"id":"thr_snake"}}
        \\{"type":"event_msg","payload":{"type":"exited_review_mode","review_output":{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"No issues found.","overall_confidence_score":0.91}}}
    ;
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "rollout.jsonl", .data = rollout });
    const rollout_path = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(rollout_path);

    const thread_read_payload = try stringifyAnyAlloc(std.testing.allocator, .{
        .thread = .{
            .id = "thr_snake",
            .path = rollout_path,
        },
    });
    defer std.testing.allocator.free(thread_read_payload);
    const thread_read_payload_json = try quoteJsonStringAlloc(std.testing.allocator, thread_read_payload);
    defer std.testing.allocator.free(thread_read_payload_json);
    const line = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"recordedAtUnixS\":1,\"method\":\"thread/read\",\"direction\":\"response\",\"payload\":{s}}}\n",
        .{thread_read_payload_json},
    );
    defer std.testing.allocator.free(line);
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "review.events.ndjson", .data = line });
    const event_log_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "review.events.ndjson", std.testing.allocator);
    defer std.testing.allocator.free(event_log_path);
    const event_log_path_json = try quoteJsonStringAlloc(std.testing.allocator, event_log_path);
    defer std.testing.allocator.free(event_log_path_json);

    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":3,\"cwd\":\"/tmp\",\"parent_thread_id\":\"parent\",\"review_thread_id\":\"thr_snake\",\"review_turn_id\":\"turn_snake\",\"delivery\":\"detached\",\"target\":{{\"type\":\"baseBranch\",\"branch\":\"main\"}},\"event_log_path\":{s},\"created_at_unix_s\":1,\"last_observed_status\":\"completed\",\"codex_version\":\"0.140.0\",\"compatibility_verdict\":\"compatible\",\"transport_kind\":\"websocket\",\"terminal_review_result_source\":null,\"terminal_review_result_json\":null,\"base_sha\":\"base_snake\",\"head_sha\":\"head_snake\",\"target_fingerprint\":\"fp_snake\"}}",
        .{event_log_path_json},
    );
    defer std.testing.allocator.free(raw);
    const requested = TargetIdentity{
        .base_sha = "base_snake",
        .head_sha = "head_snake",
        .fingerprint = "fp_snake",
    };
    try std.testing.expectError(
        error.InvalidSessionRecord,
        normalizeReceiptFromJsonAlloc(
            std.testing.allocator,
            "stored-snake.json",
            raw,
            true,
            .{
                .requested_identity = requested,
                .requested_identity_required = true,
            },
        ),
    );
}

test "receipt normalizer rejects pre-kernel broad stored recovery" {
    const raw =
        \\{"schema_version":3,"cwd":"/tmp","parent_thread_id":"parent","review_thread_id":"thr_broad","review_turn_id":"turn_broad","delivery":"detached","target":{"type":"baseBranch","branch":"main"},"event_log_path":"/tmp/missing.events.ndjson","created_at_unix_s":1,"last_observed_status":"completed","codex_version":"0.140.0","compatibility_verdict":"compatible","transport_kind":"websocket","terminal_review_result_source":null,"terminal_review_result_json":null}
    ;
    try std.testing.expectError(
        error.InvalidSessionRecord,
        normalizeReceiptFromJsonAlloc(
            std.testing.allocator,
            "stored.json",
            raw,
            true,
            .{},
        ),
    );
}

test "receipt normalizer fails closed on missing verdict fields" {
    try std.testing.expectError(
        error.MissingBackendClass,
        normalizeReceiptFromJsonAlloc(std.testing.allocator, "bad.json", "{\"status\":\"clean\",\"clean\":true,\"findingCount\":0}", true, .{}),
    );
    try std.testing.expectError(
        error.MissingCleanFlag,
        normalizeReceiptFromJsonAlloc(
            std.testing.allocator,
            "bad.json",
            "{\"status\":\"clean\",\"backendClass\":\"cas-start-wait\"," ++
                "\"findingCount\":0}",
            true,
            .{},
        ),
    );
}

test "receipt normalizer downgrades requested tuple mismatch" {
    const raw =
        \\{"demo":"cas-review-session","action":"start","reviewThreadId":"thr_1","reviewTurnId":"turn_1","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.jsonl","baseSha":"base_a","headSha":"head_a","targetFingerprint":"fp_a","reviewVerdict":{"status":"clean","backendClass":"cas-start-wait","clean":true,"findingCount":0,"failureCode":null,"failureHint":null,"baseSha":"base_a","headSha":"head_a","targetFingerprint":"fp_a","reviewThreadId":"thr_1","reviewTurnId":"turn_1","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.jsonl","findings":[]}}
    ;
    const requested = TargetIdentity{
        .base_sha = "base_b",
        .head_sha = "head_a",
        .fingerprint = "fp_a",
    };
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "tuple.json", raw, true, .{
        .requested_identity = requested,
        .requested_identity_required = true,
    });
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("incomplete", receipt.status);
    try std.testing.expect(!receipt.clean);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("tuple_mismatch", receipt.failure_code.?);
}

test "receipt normalizer preserves transport failure over requested tuple binding" {
    const raw =
        \\{"demo":"cas-review-session","action":"start","reviewThreadId":"thr_transport","reviewTurnId":"turn_transport","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.jsonl","baseSha":"base_a","headSha":"head_a","targetFingerprint":"fp_a","reviewVerdict":{"status":"review_transport_failure","backendClass":"cas-start-wait","clean":false,"findingCount":0,"failureCode":"review_transport_lost","failureHint":"transport lost","baseSha":"base_a","headSha":"head_a","targetFingerprint":"fp_a","reviewThreadId":"thr_transport","reviewTurnId":"turn_transport","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.jsonl","findings":[]}}
    ;
    const requested = TargetIdentity{
        .base_sha = "base_b",
        .head_sha = "head_a",
        .fingerprint = "fp_a",
    };
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "transport.json", raw, true, .{
        .requested_identity = requested,
        .requested_identity_required = true,
    });
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("review_transport_failure", receipt.status);
    try std.testing.expect(!receipt.clean);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("review_waiting", receipt.review_attempt_phase);
    try std.testing.expectEqualStrings("review_transport_lost", receipt.failure_code.?);
}

test "workflow-bound timeout normalizes as terminal retryable transport failure" {
    const raw =
        \\{"demo":"cas-review-session","action":"start","timedOut":true,"reviewAttemptPhase":"review_terminal","reviewAttemptExists":true,"tupleVerdictExists":false,"reviewThreadId":"thr_timeout","reviewTurnId":"turn_timeout","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.jsonl","baseSha":"base_a","headSha":"head_a","targetFingerprint":"fp_a","failureCode":"review_transport_timeout","failureClass":"transport_review_attempt","retryableSameTupleNow":true,"failureHint":"finite owner deadline","workflowBinding":{"requestId":"request-timeout","requestFingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "transport-timeout.json",
        raw,
        true,
        .{},
    );
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("review_transport_failure", receipt.status);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("review_transport_timeout", receipt.failure_code.?);
    try std.testing.expectEqualStrings("transport_review_attempt", receipt.failure_class.?);
    try std.testing.expectEqual(true, receipt.retryable_same_tuple_now.?);
}

test "normalizer preserves an ambiguous post-send review attempt without ids" {
    const raw =
        \\{"demo":"cas-review-session","action":"start","reviewAttemptPhase":"review_terminal","reviewAttemptExists":true,"reviewThreadId":null,"reviewTurnId":null,"failureCode":"review_transport_timeout","failureClass":"transport_review_attempt","retryableSameTupleNow":true,"failureHint":"response deadline elapsed","reviewVerdict":{"status":"incomplete","backendClass":"cas-receipt-normalized","clean":false,"findingCount":0,"failureCode":"review_transport_timeout","failureHint":"response deadline elapsed","reviewThreadId":null,"reviewTurnId":null,"findings":[]}}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "ambiguous-post-send.json",
        raw,
        true,
        .{},
    );
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("review_transport_failure", receipt.status);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(receipt.review_thread_id == null);
    try std.testing.expectEqualStrings("review_transport_timeout", receipt.failure_code.?);
    try std.testing.expectEqual(true, receipt.retryable_same_tuple_now.?);
}

test "receipt normalizer emits nested reviewVerdict in normalized JSON" {
    const receipt = NormalizedReceipt{
        .source_path = "source.json",
        .status = "clean",
        .backend_class = "cas-start-wait",
        .clean = true,
        .finding_count = 0,
        .review_attempt_phase = "normalized_verdict",
        .review_attempt_exists = true,
        .tuple_verdict_exists = true,
        .principal_strength = principal_strength_strong,
        .account_fingerprint_reduced_protection = false,
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .review_thread_id = "thr",
        .review_turn_id = "turn",
        .record_path = "/tmp/record.json",
        .event_log_path = "/tmp/events.jsonl",
        .failure_code = null,
        .failure_hint = null,
        .failure_class = null,
        .retryable_same_tuple_now = null,
        .findings_json = "[]",
    };
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeReceiptObject(&out.writer, receipt);
    const json = try out.toOwnedSlice();
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const verdict = parsed.value.object.get("reviewVerdict").?.object;
    try std.testing.expectEqualStrings("clean", verdict.get("status").?.string);
    try std.testing.expectEqualStrings("cas-start-wait", verdict.get("backendClass").?.string);
    try std.testing.expect(verdict.get("clean").?.bool);
    try std.testing.expectEqual(@as(i64, 0), verdict.get("findingCount").?.integer);
    try std.testing.expectEqualStrings(principal_strength_strong, verdict.get("principalStrength").?.string);
    try std.testing.expect(!verdict.get("accountFingerprintReducedProtection").?.bool);
    try std.testing.expectEqualStrings("base", verdict.get("baseSha").?.string);

    var compact_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer compact_out.deinit();
    try writeReceiptReviewVerdictObject(&compact_out.writer, receipt);
    const compact_json = try compact_out.toOwnedSlice();
    defer std.testing.allocator.free(compact_json);
    var compact_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, compact_json, .{});
    defer compact_parsed.deinit();
    const compact = compact_parsed.value.object;
    try std.testing.expectEqualStrings("normalized_verdict", compact.get("reviewAttemptPhase").?.string);
    try std.testing.expect(compact.get("reviewAttemptExists").?.bool);
    try std.testing.expect(compact.get("tupleVerdictExists").?.bool);
    try std.testing.expectEqualStrings(principal_strength_strong, compact.get("principalStrength").?.string);
}

test "synthetic run receipt preserves root tuple binding" {
    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    const review_verdict_json =
        \\{"status":"clean","backendClass":"cas-start-wait","clean":true,"findingCount":0,"failureCode":null,"failureHint":null,"baseSha":"base","headSha":"head","targetFingerprint":"fp","reviewThreadId":"thr","reviewTurnId":"turn","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.jsonl","findings":[]}
    ;
    const synthetic = try casRunSyntheticReceiptJsonAlloc(
        std.testing.allocator,
        "/tmp/repo",
        identity,
        .{ .type = "uncommittedChanges" },
        "parent",
        "thr",
        "turn",
        "/tmp/record.json",
        "/tmp/events.jsonl",
        .{
            .surface_action = "run",
            .account_fingerprint_reduced_protection = false,
        },
        review_verdict_json,
    );
    defer std.testing.allocator.free(synthetic);

    const normalized = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "/tmp/record.json", synthetic, true, .{
        .requested_identity = identity,
        .requested_identity_required = true,
    });
    defer normalized.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("clean", normalized.status);
    try std.testing.expect(normalized.tuple_verdict_exists);
    try std.testing.expectEqualStrings("base", normalized.base_sha.?);
    try std.testing.expectEqualStrings("head", normalized.head_sha.?);
    try std.testing.expectEqualStrings("fp", normalized.target_fingerprint.?);
}

test "synthetic run receipt preserves nested terminal attempt phase" {
    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    const review_verdict_json =
        \\{"status":"review_transport_failure","backendClass":"cas-start-wait","reviewAttemptPhase":"review_terminal","reviewAttemptExists":true,"tupleVerdictExists":false,"clean":false,"findingCount":0,"failureCode":"review_transport_timeout","failureClass":"transport_review_attempt","retryableSameTupleNow":true,"failureHint":"owner deadline","baseSha":"base","headSha":"head","targetFingerprint":"fp","reviewThreadId":"thr","reviewTurnId":"turn","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.jsonl","findings":[]}
    ;
    const synthetic = try casRunSyntheticReceiptJsonAlloc(
        std.testing.allocator,
        "/tmp/repo",
        identity,
        .{ .type = "uncommittedChanges" },
        "parent",
        "thr",
        "turn",
        "/tmp/record.json",
        "/tmp/events.jsonl",
        .{
            .surface_action = "run",
            .account_fingerprint_reduced_protection = false,
        },
        review_verdict_json,
    );
    defer std.testing.allocator.free(synthetic);

    const normalized = try normalizeReceiptFromJsonAlloc(
        std.testing.allocator,
        "/tmp/record.json",
        synthetic,
        true,
        .{
            .requested_identity = identity,
            .requested_identity_required = true,
        },
    );
    defer normalized.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("review_terminal", normalized.review_attempt_phase);
    try std.testing.expectEqualStrings("review_transport_timeout", normalized.failure_code.?);
    try std.testing.expectEqual(true, normalized.retryable_same_tuple_now.?);
}

test "structured result alone determines clean despite diagnostic prose" {
    const review_result =
        \\{"findings":[],"overallCorrectness":"patch is correct","overallExplanation":"No issues found.","overallConfidenceScore":0.92}
    ;
    var status = ReviewStatus{
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
        .review_result_json = try std.testing.allocator.dupe(u8, review_result),
        .review_text = try std.testing.allocator.dupe(
            u8,
            "usageLimitExceeded\n- [P1] Diagnostic prose is not a finding.",
        ),
        .raw_response_json = try std.testing.allocator.dupe(
            u8,
            "{\"threadPreview\":\"quota exceeded\"}",
        ),
    };
    defer status.deinit(std.testing.allocator);
    try std.testing.expect(failureInfoForStatus(&status) == null);
    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    const verdict_json = (try startWaitReviewVerdictJsonAlloc(
        std.testing.allocator,
        identity,
        "thr",
        "turn",
        "/tmp/record.json",
        "/tmp/events.jsonl",
        .{
            .account_fingerprint_reduced_protection = false,
            .workflow_binding = testWorkflowBinding(),
        },
        status,
        false,
        true,
        null,
    )).?;
    defer std.testing.allocator.free(verdict_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, verdict_json, .{});
    defer parsed.deinit();
    const verdict = parsed.value.object;
    try std.testing.expectEqualStrings("clean", verdict.get("status").?.string);
    try std.testing.expectEqualStrings("cas-start-wait", verdict.get("backendClass").?.string);
    try std.testing.expectEqualStrings(
        principal_strength_strong,
        verdict.get("principalStrength").?.string,
    );
    try std.testing.expect(!verdict.get("accountFingerprintReducedProtection").?.bool);
    try std.testing.expectEqualStrings(
        "request-test",
        verdict.get("workflowBinding").?.object.get("requestId").?.string,
    );
    try std.testing.expect(verdict.get("clean").?.bool);
    try std.testing.expectEqual(@as(i64, 0), verdict.get("findingCount").?.integer);
    try std.testing.expectEqualStrings("thr", verdict.get("reviewThreadId").?.string);
}

test "start wait verdict builder rejects notification-only proof" {
    const review_result =
        \\{"findings":[],"overallCorrectness":"patch is correct","overallExplanation":"No issues found.","overallConfidenceScore":0.92}
    ;
    var status = ReviewStatus{
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
        .review_result_source = "notification_exited_review_mode",
        .review_result_json = try std.testing.allocator.dupe(u8, review_result),
        .review_text = try std.testing.allocator.dupe(u8, "No issues found."),
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);
    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    const verdict_json = (try startWaitReviewVerdictJsonAlloc(
        std.testing.allocator,
        identity,
        "thr",
        "turn",
        "/tmp/record.json",
        "/tmp/events.jsonl",
        .{},
        status,
        false,
        true,
        null,
    )).?;
    defer std.testing.allocator.free(verdict_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, verdict_json, .{});
    defer parsed.deinit();
    const verdict = parsed.value.object;
    try std.testing.expectEqualStrings("review_untrusted_source", verdict.get("status").?.string);
    try std.testing.expect(!verdict.get("clean").?.bool);
    try std.testing.expect(!verdict.get("tupleVerdictExists").?.bool);
    try std.testing.expectEqualStrings("review_untrusted_source", verdict.get("failureCode").?.string);

    const lock_failure = terminalLockFailureForStatus(std.testing.allocator, status) orelse return error.ExpectedTerminalLockFailure;
    try std.testing.expectEqualStrings("review_untrusted_source", lock_failure.code);
}

test "review verdict status maps phase-three statuses" {
    try std.testing.expectEqualStrings("incomplete", reviewVerdictStatus(false, 0, null, null));
    try std.testing.expectEqualStrings(
        "timeout",
        reviewVerdictStatus(false, 0, .{ .code = "wait_timed_out", .hint = "" }, "thr"),
    );
    try std.testing.expectEqualStrings(
        "incomplete",
        reviewVerdictStatus(
            false,
            1,
            .{ .code = "review_output_invalid", .hint = "" },
            "thr",
        ),
    );
    try std.testing.expectEqualStrings(
        "review_untrusted_source",
        reviewVerdictStatus(
            false,
            0,
            .{ .code = "review_untrusted_source", .hint = "" },
            "thr",
        ),
    );
    try std.testing.expectEqualStrings(
        "account_resource_exhausted",
        reviewVerdictStatus(
            false,
            0,
            .{ .code = "usageLimitExceeded", .hint = "" },
            "thr",
        ),
    );
    try std.testing.expectEqualStrings(
        "review_transport_failure",
        reviewVerdictStatus(
            false,
            0,
            .{ .code = "review_transport_lost", .hint = "" },
            "thr",
        ),
    );
    try std.testing.expectEqualStrings("clean", reviewVerdictStatus(true, 0, null, "thr"));
    try std.testing.expectEqualStrings("findings", reviewVerdictStatus(false, 2, null, "thr"));
}

test "review verdict tuple terminal status is clean or findings only" {
    try std.testing.expect(reviewVerdictStatusIsTupleTerminal("clean"));
    try std.testing.expect(reviewVerdictStatusIsTupleTerminal("findings"));
    try std.testing.expect(!reviewVerdictStatusIsTupleTerminal("account_resource_exhausted"));
    try std.testing.expect(!reviewVerdictStatusIsTupleTerminal("review_output_invalid"));
    try std.testing.expect(!reviewVerdictStatusIsTupleTerminal("timeout"));
    try std.testing.expect(!reviewVerdictStatusIsTupleTerminal("incomplete"));
    try std.testing.expect(!reviewVerdictStatusIsTupleTerminal("review_transport_failure"));
    try std.testing.expect(!reviewVerdictStatusIsTupleTerminal("review_untrusted_source"));
}

test "account resource exhaustion detector accepts required signals" {
    try std.testing.expect(detectAccountResourceExhaustion("usageLimitExceeded"));
    try std.testing.expect(detectAccountResourceExhaustion("Rate Limit Exceeded while starting review"));
    try std.testing.expect(detectAccountResourceExhaustion("quota exceeded for this account"));
    try std.testing.expect(detectAccountResourceExhaustion("temporary ACCOUNT LIMIT reached"));
    try std.testing.expect(!detectAccountResourceExhaustion("review transport lost"));
}

test "account resource exhaustion maps start and terminal status failures" {
    const start_failure = failureInfoForReviewStart("review/start failed: usageLimitExceeded", false).?;
    try std.testing.expectEqualStrings("account_resource_exhausted", start_failure.code);

    var status = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "loaded"),
        .turn_status = try std.testing.allocator.dupe(u8, "failed"),
        .turn_count = 1,
        .materialized = true,
        .thread_preview = try std.testing.allocator.dupe(u8, ""),
        .rollout_path = null,
        .turn_error_message = try std.testing.allocator.dupe(
            u8,
            "quota exceeded before review output",
        ),
        .last_turn_has_entered_review_mode = true,
        .last_turn_has_exited_review_mode = false,
        .review_result_available = false,
        .review_result_source = null,
        .review_result_json = null,
        .review_text = try std.testing.allocator.dupe(u8, "diagnostic reviewer prose"),
        .raw_response_json = try std.testing.allocator.dupe(
            u8,
            "{\"threadPreview\":\"usageLimitExceeded\"}",
        ),
    };
    defer status.deinit(std.testing.allocator);

    const status_failure = failureInfoForStatus(&status).?;
    try std.testing.expectEqualStrings("account_resource_exhausted", status_failure.code);
    try std.testing.expectEqualStrings("account_resource", failureClassForCode(status_failure.code).?);
    try std.testing.expectEqual(false, retryableSameTupleNowForCode(status_failure.code).?);
    try std.testing.expectEqualStrings("pre_review_start", startReceiptReviewAttemptPhase(null, false, status_failure, null));
    try std.testing.expectEqualStrings("review_terminal", startReceiptReviewAttemptPhase(null, false, status_failure, "thr_1"));
}

test "receipt normalizer preserves account resource retry metadata" {
    const raw =
        "{\"demo\":\"cas-review-session\",\"action\":\"start\"," ++
        "\"reviewThreadId\":\"thr_1\",\"reviewTurnId\":\"turn_1\"," ++
        "\"recordPath\":\"/tmp/record.json\"," ++
        "\"eventLogPath\":\"/tmp/events.jsonl\",\"baseSha\":\"base_a\"," ++
        "\"headSha\":\"head_a\",\"targetFingerprint\":\"fp_a\"," ++
        "\"failureCode\":\"review_failed\",\"error\":\"quota exceeded\"," ++
        "\"reviewVerdict\":{\"status\":\"incomplete\"," ++
        "\"backendClass\":\"cas-start-wait\",\"clean\":false," ++
        "\"findingCount\":0,\"failureCode\":\"review_failed\"," ++
        "\"failureHint\":\"failed\",\"baseSha\":\"base_a\"," ++
        "\"headSha\":\"head_a\",\"targetFingerprint\":\"fp_a\"," ++
        "\"reviewThreadId\":\"thr_1\",\"reviewTurnId\":\"turn_1\"," ++
        "\"recordPath\":\"/tmp/record.json\"," ++
        "\"eventLogPath\":\"/tmp/events.jsonl\",\"findings\":[]}}";
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "account.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("account_resource_exhausted", receipt.status);
    try std.testing.expectEqualStrings("account_resource_exhausted", receipt.failure_code.?);
    try std.testing.expectEqualStrings("account_resource", receipt.failure_class.?);
    try std.testing.expectEqual(false, receipt.retryable_same_tuple_now.?);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
}

test "blocked account-resource run payload projects valid CAS-RER" {
    const tuple = ReviewTupleIdentity{
        .repo_realpath = "/repo",
        .base_sha = "base_a",
        .head_sha = "head_a",
        .target_fingerprint = "fp_a",
        .resolved_codex_path = "/bin/codex",
        .resolved_codex_version = "codex 0.1.0",
        .account_fingerprint = "acct:test",
        .account_fingerprint_reduced_protection = false,
        .codex_thread_id = "thread-test",
    };
    const raw = try stringifyAnyAlloc(std.testing.allocator, .{
        .demo = "cas-review-session",
        .action = "run",
        .reviewBrokerDecision = .{
            .action = "blocked_account_resource",
            .reason = "same-account review retry is blocked",
            .freshAttemptRequired = false,
        },
        .cwd = "/repo",
        .reviewAttemptPhase = "review_waiting",
        .reviewAttemptExists = true,
        .tupleVerdictExists = false,
        .reviewThreadId = "thr_account",
        .reviewTurnId = "turn_account",
        .target = TargetRecord{ .type = "uncommittedChanges" },
        .baseSha = tuple.base_sha,
        .headSha = tuple.head_sha,
        .targetFingerprint = tuple.target_fingerprint,
        .resolvedCodexPath = tuple.resolved_codex_path,
        .resolvedCodexVersion = tuple.resolved_codex_version,
        .failureCode = "review_tuple_lock_account_resource_exhausted",
        .failureClass = "coordination",
        .retryableSameTupleNow = false,
        .failureHint = "same-account review retry is blocked",
        .reviewTupleLockVersion = review_tuple_lock_version,
        .reviewTupleHash = "sha256:tuple",
        .reviewTupleLockPath = "/locks/tuple.json",
        .reviewTupleLockState = "account_resource_exhausted",
        .reviewTupleLockAction = "block_account_resource",
        .accountFingerprint = tuple.account_fingerprint,
        .accountFingerprintReducedProtection = tuple.account_fingerprint_reduced_protection,
        .recordPath = "/tmp/record.json",
        .eventLogPath = "/tmp/events.jsonl",
        .lastFailureCode = "account_resource_exhausted",
        .reviewVerdict = .{
            .status = "incomplete",
            .backendClass = "cas-receipt-normalized",
            .clean = false,
            .findingCount = 0,
            .failureCode = "review_tuple_lock_account_resource_exhausted",
            .failureHint = "same-account review retry is blocked",
            .baseSha = tuple.base_sha,
            .headSha = tuple.head_sha,
            .targetFingerprint = tuple.target_fingerprint,
            .reviewThreadId = "thr_account",
            .reviewTurnId = "turn_account",
            .recordPath = "/tmp/record.json",
            .eventLogPath = "/tmp/events.jsonl",
            .findings = [_]std.json.Value{},
        },
    });
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"findings\":[]") != null);
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "/tmp/record.json", raw, true, normalizeContextFromReviewTuple(tuple));
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("account_resource_exhausted", receipt.status);
    try std.testing.expectEqualStrings("account_resource_exhausted", receipt.failure_code.?);
    try std.testing.expectEqual(false, receipt.retryable_same_tuple_now.?);
    try std.testing.expectEqualStrings("/bin/codex", receipt.resolved_codex_path.?);
    try std.testing.expectEqualStrings("codex 0.1.0", receipt.resolved_codex_version.?);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expect(receipt.review_attempt_exists);

    const rer_json = try casRerJsonFromReceiptAlloc(std.testing.allocator, receipt, .{
        .command_surface = "run",
        .backend_selected = "cas-run",
        .broker_action = publicReviewBrokerAction(reviewBrokerActionForBlockedLock(.block_account_resource)),
        .broker_reason = "same-account review retry is blocked",
        .timestamp = "unix-ns:1",
    });
    defer std.testing.allocator.free(rer_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rer_json, .{});
    defer parsed.deinit();

    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "blocked-account-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(gate.ok());
    const verdict = parsed.value.object.get("verdict").?.object;
    try std.testing.expectEqualStrings("account_resource_exhausted", verdict.get("status").?.string);
    try std.testing.expect(!verdict.get("tupleVerdictExists").?.bool);
    const tuple_obj = parsed.value.object.get("tuple").?.object;
    try std.testing.expectEqualStrings("/bin/codex", tuple_obj.get("resolvedCodexPath").?.string);
    try std.testing.expectEqualStrings("codex 0.1.0", tuple_obj.get("resolvedCodexVersion").?.string);
}

test "receipt normalizer keeps pre-attempt account exhaustion attempt-free" {
    const raw =
        \\{"demo":"cas-review-session","action":"start","reviewAttemptPhase":"pre_review_start","reviewAttemptExists":false,"tupleVerdictExists":false,"reviewThreadId":null,"reviewTurnId":null,"failureCode":"account_resource_exhausted","failureClass":"account_resource","retryableSameTupleNow":false,"failureHint":"usageLimitExceeded"}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "pre-account.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("incomplete", receipt.status);
    try std.testing.expectEqualStrings("account_resource_exhausted", receipt.failure_code.?);
    try std.testing.expectEqualStrings("account_resource", receipt.failure_class.?);
    try std.testing.expectEqual(false, receipt.retryable_same_tuple_now.?);
    try std.testing.expectEqualStrings("pre_review_start", receipt.review_attempt_phase);
    try std.testing.expect(!receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
}

test "pre-kernel stored account-limit receipt is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "events.ndjson", .data = "{\"payload\":\"usageLimitExceeded\"}\n" });
    const event_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "events.ndjson", std.testing.allocator);
    defer std.testing.allocator.free(event_path);
    const event_path_json = try quoteJsonStringAlloc(std.testing.allocator, event_path);
    defer std.testing.allocator.free(event_path_json);
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":3,\"cwd\":\"/tmp\",\"parent_thread_id\":\"parent\",\"review_thread_id\":\"thr_account\",\"review_turn_id\":\"turn_account\",\"delivery\":\"detached\",\"target\":{{\"type\":\"baseBranch\",\"branch\":\"main\"}},\"event_log_path\":{s},\"created_at_unix_s\":1,\"last_observed_status\":\"completed\",\"codex_version\":\"0.140.0\",\"compatibility_verdict\":\"compatible\",\"transport_kind\":\"websocket\",\"terminal_review_result_source\":null,\"terminal_review_result_json\":null}}",
        .{event_path_json},
    );
    defer std.testing.allocator.free(raw);

    try std.testing.expectError(
        error.InvalidSessionRecord,
        normalizeReceiptFromJsonAlloc(
            std.testing.allocator,
            "stored-account.json",
            raw,
            true,
            .{},
        ),
    );
}

test "pre-kernel stored account exhaustion with tuple is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "events.ndjson", .data = "{\"payload\":\"quota exceeded\"}\n" });
    const event_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "events.ndjson", std.testing.allocator);
    defer std.testing.allocator.free(event_path);
    const event_path_json = try quoteJsonStringAlloc(std.testing.allocator, event_path);
    defer std.testing.allocator.free(event_path_json);
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":3,\"cwd\":\"/tmp\",\"parent_thread_id\":\"parent\",\"review_thread_id\":\"thr_account\",\"review_turn_id\":\"turn_account\",\"delivery\":\"detached\",\"target\":{{\"type\":\"baseBranch\",\"branch\":\"main\"}},\"event_log_path\":{s},\"created_at_unix_s\":1,\"last_observed_status\":\"inProgress\",\"codex_version\":\"0.140.0\",\"compatibility_verdict\":\"compatible\",\"transport_kind\":\"websocket\",\"terminal_review_result_source\":null,\"terminal_review_result_json\":null,\"base_sha\":\"base_a\",\"head_sha\":\"head_a\",\"target_fingerprint\":\"fp_a\"}}",
        .{event_path_json},
    );
    defer std.testing.allocator.free(raw);

    try std.testing.expectError(
        error.InvalidSessionRecord,
        normalizeReceiptFromJsonAlloc(
            std.testing.allocator,
            "stored-account-proof.json",
            raw,
            true,
            .{},
        ),
    );
}

test "review verdict compacts findings for consumers" {
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
        "cas-start-wait",
        false,
        1,
        null,
        identity,
        .{},
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
    try std.testing.expectEqualStrings("normalized_verdict", root.get("reviewAttemptPhase").?.string);
    try std.testing.expect(root.get("reviewAttemptExists").?.bool);
    try std.testing.expect(root.get("tupleVerdictExists").?.bool);
    try std.testing.expectEqualStrings("cas-start-wait", root.get("backendClass").?.string);
    try std.testing.expect(!root.get("clean").?.bool);
    try std.testing.expectEqual(@as(i64, 1), root.get("findingCount").?.integer);
    const finding = root.get("findings").?.array.items[0].object;
    try std.testing.expectEqualStrings("Count matching offers", finding.get("title").?.string);
    try std.testing.expectEqualStrings("/tmp/src/program/evidence.zig", finding.get("file").?.string);
    try std.testing.expectEqual(@as(i64, 3571), finding.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 2), finding.get("priority").?.integer);
}

test "review verdict requires tuple proof before proof flag" {
    const identity = TargetIdentity{
        .head_sha = "head123",
        .base_sha = null,
        .fingerprint = "target-fingerprint",
    };
    const verdict = try buildReviewVerdictJsonAlloc(
        std.testing.allocator,
        "cas-start-wait",
        true,
        0,
        null,
        identity,
        .{},
        "review-thread",
        "review-turn",
        "/tmp/record.json",
        "/tmp/events.ndjson",
        "{\"findings\":[]}",
    );
    defer std.testing.allocator.free(verdict);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, verdict, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("clean", root.get("status").?.string);
    try std.testing.expectEqualStrings("review_terminal", root.get("reviewAttemptPhase").?.string);
    try std.testing.expect(root.get("reviewAttemptExists").?.bool);
    try std.testing.expect(!root.get("tupleVerdictExists").?.bool);
}

test "review verdict timeout is not proof-bearing" {
    const identity = TargetIdentity{
        .head_sha = "head123",
        .base_sha = "base123",
        .fingerprint = "target-fingerprint",
    };
    const verdict = try buildReviewVerdictJsonAlloc(
        std.testing.allocator,
        "cas-start-wait",
        false,
        0,
        .{ .code = "wait_timed_out", .hint = "retry wait" },
        identity,
        .{},
        "review-thread",
        "review-turn",
        "/tmp/record.json",
        "/tmp/events.ndjson",
        null,
    );
    defer std.testing.allocator.free(verdict);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, verdict, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("timeout", root.get("status").?.string);
    try std.testing.expectEqualStrings("review_waiting", root.get("reviewAttemptPhase").?.string);
    try std.testing.expect(root.get("reviewAttemptExists").?.bool);
    try std.testing.expect(!root.get("tupleVerdictExists").?.bool);
}

test "live exitedReviewMode text remains raw evidence without semantic result" {
    var notifications = LiveReviewNotificationState{
        .review_thread_id = "review-thread",
        .review_turn_id = "review-turn",
        .review_text = try std.testing.allocator.dupe(u8, "No issues found."),
        .observed_terminal_status = "completed",
        .saw_entered_review_mode = true,
        .saw_exited_review_mode = true,
    };
    defer notifications.deinit(std.testing.allocator);
    var status = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "loaded"),
        .turn_status = try std.testing.allocator.dupe(u8, "inProgress"),
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
        .review_text = null,
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);

    try populateReviewEvidenceFromLiveNotifications(
        std.testing.allocator,
        &status,
        &notifications,
    );

    try std.testing.expectEqualStrings("completed", status.turn_status);
    try std.testing.expect(status.last_turn_has_entered_review_mode);
    try std.testing.expect(status.last_turn_has_exited_review_mode);
    try std.testing.expectEqualStrings("No issues found.", status.review_text.?);
    try std.testing.expect(!status.review_result_available);
    try std.testing.expect(status.review_result_source == null);
    try std.testing.expect(status.review_result_json == null);
    const failure = failureInfoForStatus(&status) orelse
        return error.ExpectedMissingReviewOutput;
    try std.testing.expectEqualStrings("review_output_missing", failure.code);
}

test "parseReviewStatusAlloc handles materialized and pending states" {
    const materialized = try parseReviewStatusAlloc(
        std.testing.allocator,
        "{\"thread\":{\"id\":\"thr\",\"status\":\"running\"," ++
            "\"turns\":[{\"id\":\"turn\",\"status\":\"inProgress\"}]}}",
        true,
        "thr",
        "turn",
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
        null,
        null,
    );
    defer pending.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("running", pending.thread_status);
    try std.testing.expectEqualStrings("materializing", pending.turn_status);
    try std.testing.expectEqual(@as(usize, 0), pending.turn_count);
    try std.testing.expect(!pending.materialized);

    const inline_pending = try parseReviewStatusAlloc(
        std.testing.allocator,
        "{\"thread\":{\"id\":\"thr_inline\",\"status\":\"running\"}}",
        false,
        "thr_inline",
        "turn_inline",
    );
    defer inline_pending.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("materializing", inline_pending.turn_status);
    try std.testing.expectEqual(@as(usize, 0), inline_pending.turn_count);
    try std.testing.expect(!inline_pending.materialized);
}

test "review history materialization classifier is narrow" {
    try std.testing.expect(reviewHistoryIsNotMaterialized(
        "includeTurns is unavailable while thread is not materialized yet",
    ));
    try std.testing.expect(reviewHistoryIsNotMaterialized(
        "failed to load thread history for thread thr: thread-store internal error: " ++
            "failed to read session metadata /tmp/rollout.jsonl: rollout at " ++
            "/tmp/rollout.jsonl is empty",
    ));
    try std.testing.expect(reviewHistoryIsNotMaterialized(
        "failed to read thread: thread-store internal error: failed to read " ++
            "session metadata /tmp/rollout.jsonl: rollout at /tmp/rollout.jsonl is empty",
    ));
    try std.testing.expect(!reviewHistoryIsNotMaterialized(
        "failed to load thread history: permission denied",
    ));
    try std.testing.expect(!reviewHistoryIsNotMaterialized(
        "rollout at /tmp/rollout.jsonl is corrupt",
    ));
}

test "unmaterialized review status remains non-terminal and non-proof-bearing" {
    const status = try unmaterializedReviewStatusAlloc(
        std.testing.allocator,
        "rollout is empty",
    );
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("materializing", status.thread_status);
    try std.testing.expectEqualStrings("materializing", status.turn_status);
    try std.testing.expectEqual(@as(usize, 0), status.turn_count);
    try std.testing.expect(!status.materialized);
    try std.testing.expect(!status.review_result_available);
    try std.testing.expect(!isTerminalTurnStatus(status.turn_status));
}

test "inline partial review completion remains pending until structured exit" {
    var status = ReviewStatus{
        .thread_status = try std.testing.allocator.dupe(u8, "loaded"),
        .turn_status = try std.testing.allocator.dupe(u8, "completed"),
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
        .review_text = null,
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);

    try std.testing.expect(reviewStatusAwaitsStructuredCompletion("codex-cli 0.145.0", &status));
    try std.testing.expect(!reviewStatusAwaitsStructuredCompletion("codex-cli 0.144.0", &status));

    status.last_turn_has_exited_review_mode = true;
    try std.testing.expect(!reviewStatusAwaitsStructuredCompletion("codex-cli 0.145.0", &status));
    status.last_turn_has_exited_review_mode = false;
    status.review_result_available = true;
    try std.testing.expect(!reviewStatusAwaitsStructuredCompletion("codex-cli 0.145.0", &status));
    status.review_result_available = false;
    std.testing.allocator.free(status.turn_status);
    status.turn_status = try std.testing.allocator.dupe(u8, "failed");
    try std.testing.expect(!reviewStatusAwaitsStructuredCompletion("codex-cli 0.145.0", &status));
}

test "parseReviewStatusAlloc selects the persisted turn and rejects thread mismatch" {
    const raw =
        "{\"thread\":{\"id\":\"thr_expected\",\"status\":\"running\"," ++
        "\"turns\":[{\"id\":\"turn_expected\",\"status\":\"completed\"," ++
        "\"items\":[{\"type\":\"enteredReviewMode\"},{\"type\":\"exitedReviewMode\"}]}," ++
        "{\"id\":\"turn_later\",\"status\":\"inProgress\"}]}}";
    const status = try parseReviewStatusAlloc(
        std.testing.allocator,
        raw,
        true,
        "thr_expected",
        "turn_expected",
    );
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("completed", status.turn_status);
    try std.testing.expect(status.last_turn_has_entered_review_mode);
    try std.testing.expect(status.last_turn_has_exited_review_mode);

    try std.testing.expectError(
        error.ReviewThreadMismatch,
        parseReviewStatusAlloc(
            std.testing.allocator,
            raw,
            true,
            "thr_other",
            "turn_expected",
        ),
    );
    try std.testing.expectError(
        error.MissingReviewTurn,
        parseReviewStatusAlloc(
            std.testing.allocator,
            raw,
            true,
            "thr_expected",
            "turn_absent",
        ),
    );
}

test "readReviewResultJsonFromRolloutAlloc extracts exited review output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thr_1\"}}\n" ++
        "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn_1\"}}\n" ++
        "{\"type\":\"event_msg\",\"payload\":{" ++
        "\"type\":\"entered_review_mode\"," ++
        "\"user_facing_hint\":\"current changes\"}}\n" ++
        "{\"type\":\"event_msg\",\"payload\":{" ++
        "\"type\":\"exited_review_mode\",\"review_output\":{" ++
        "\"findings\":[{\"title\":\"Prefer helper\"," ++
        "\"body\":\"Use the helper.\",\"confidence_score\":0.75," ++
        "\"priority\":1,\"code_location\":{" ++
        "\"absolute_file_path\":\"/tmp/file.zig\"," ++
        "\"line_range\":{\"start\":7,\"end\":9}}}]," ++
        "\"overall_correctness\":\"patch is incorrect\"," ++
        "\"overall_explanation\":\"One issue found.\"," ++
        "\"overall_confidence_score\":0.9}}}";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "rollout.jsonl",
        .data = rollout,
    });

    const rollout_path = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(rollout_path);

    const json = (try readReviewResultJsonFromRolloutAlloc(
        std.testing.allocator,
        rollout_path,
        "turn_1",
    )).?;
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    const findings = root_obj.get("findings").?.array;
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqualStrings(
        "patch is incorrect",
        core_json.stringField(root_obj, "overallCorrectness").?,
    );
    try std.testing.expectEqualStrings(
        "One issue found.",
        core_json.stringField(root_obj, "overallExplanation").?,
    );
    try std.testing.expectEqual(@as(f32, 0.9), floatField(root_obj, "overallConfidenceScore").?);

    const first = findings.items[0].object;
    try std.testing.expectEqualStrings("Prefer helper", core_json.stringField(first, "title").?);
    try std.testing.expectEqualStrings("Use the helper.", core_json.stringField(first, "body").?);
    try std.testing.expectEqual(@as(f32, 0.75), floatField(first, "confidenceScore").?);
    const code_location = core_json.objectField(first, "codeLocation").?;
    try std.testing.expectEqualStrings(
        "/tmp/file.zig",
        core_json.stringField(code_location, "absoluteFilePath").?,
    );
}

test "readReviewResultJsonFromRolloutAlloc accepts event-local turn identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        "{\"type\":\"event_msg\",\"payload\":{" ++
        "\"turn_id\":\"turn_1\",\"type\":\"exited_review_mode\"," ++
        "\"review_output\":{\"findings\":[]," ++
        "\"overall_correctness\":\"patch is correct\"," ++
        "\"overall_explanation\":\"Clean.\"," ++
        "\"overall_confidence_score\":1}}}";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "rollout.jsonl",
        .data = rollout,
    });
    const rollout_path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(rollout_path);

    const json = (try readReviewResultJsonFromRolloutAlloc(
        std.testing.allocator,
        rollout_path,
        "turn_1",
    )).?;
    defer std.testing.allocator.free(json);
    try std.testing.expectEqual(@as(usize, 0), try reviewFindingCount(
        std.testing.allocator,
        json,
    ));
}

test "readReviewResultJsonFromRolloutAlloc event-local turn overrides legacy context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn_1\"}}\n" ++
        "{\"type\":\"event_msg\",\"payload\":{" ++
        "\"turn_id\":\"turn_other\",\"type\":\"exited_review_mode\"," ++
        "\"review_output\":{\"findings\":[]," ++
        "\"overall_correctness\":\"patch is correct\"," ++
        "\"overall_explanation\":\"Wrong turn.\"," ++
        "\"overall_confidence_score\":1}}}";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "rollout.jsonl",
        .data = rollout,
    });
    const rollout_path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(rollout_path);

    try std.testing.expect((try readReviewResultJsonFromRolloutAlloc(
        std.testing.allocator,
        rollout_path,
        "turn_1",
    )) == null);
}

test "readReviewResultJsonFromRolloutAlloc rejects duplicate verdicts for one turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const review_output =
        "{\"type\":\"event_msg\",\"payload\":{" ++
        "\"type\":\"exited_review_mode\",\"review_output\":{" ++
        "\"findings\":[],\"overall_correctness\":\"patch is correct\"," ++
        "\"overall_explanation\":\"Clean.\"," ++
        "\"overall_confidence_score\":1}}}";
    const rollout =
        "{\"type\":\"turn_context\",\"payload\":{" ++
        "\"turn_id\":\"turn_1\"}}\n" ++
        review_output ++ "\n" ++ review_output;
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "rollout.jsonl",
        .data = rollout,
    });

    const rollout_path = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(rollout_path);

    try std.testing.expectError(
        error.InvalidReviewOutput,
        readReviewResultJsonFromRolloutAlloc(
            std.testing.allocator,
            rollout_path,
            "turn_1",
        ),
    );
}

test "readReviewResultJsonFromRolloutAlloc cannot credit a later turn" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn_expected\"}}\n" ++
        "{\"type\":\"event_msg\",\"payload\":{" ++
        "\"type\":\"exited_review_mode\",\"review_output\":{" ++
        "\"findings\":[{\"title\":\"Expected-turn finding\"," ++
        "\"body\":\"This belongs to the persisted turn.\"," ++
        "\"confidence_score\":0.9,\"priority\":1,\"code_location\":{" ++
        "\"absolute_file_path\":\"/tmp/file.zig\"," ++
        "\"line_range\":{\"start\":1,\"end\":1}}}]," ++
        "\"overall_correctness\":\"patch is incorrect\"," ++
        "\"overall_explanation\":\"One issue found.\"," ++
        "\"overall_confidence_score\":0.9}}}\n" ++
        "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn_later\"}}\n" ++
        "{\"type\":\"event_msg\",\"payload\":{" ++
        "\"type\":\"exited_review_mode\",\"review_output\":{" ++
        "\"findings\":[],\"overall_correctness\":\"patch is correct\"," ++
        "\"overall_explanation\":\"Later turn clean.\"," ++
        "\"overall_confidence_score\":1}}}";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "rollout.jsonl",
        .data = rollout,
    });
    const rollout_path = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(rollout_path);

    const json = (try readReviewResultJsonFromRolloutAlloc(
        std.testing.allocator,
        rollout_path,
        "turn_expected",
    )).?;
    defer std.testing.allocator.free(json);
    try std.testing.expectEqual(@as(usize, 1), try reviewFindingCount(
        std.testing.allocator,
        json,
    ));
    try std.testing.expectError(
        error.MissingReviewTurnBoundary,
        readReviewResultJsonFromRolloutAlloc(
            std.testing.allocator,
            rollout_path,
            "turn_absent",
        ),
    );
}

test "readReviewResultJsonFromRolloutAlloc rejects absent exited review output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn_1\"}}\n" ++
        "{\"type\":\"event_msg\",\"payload\":{" ++
        "\"type\":\"entered_review_mode\"," ++
        "\"user_facing_hint\":\"current changes\"}}\n" ++
        "{\"type\":\"event_msg\",\"payload\":{" ++
        "\"type\":\"exited_review_mode\",\"review_output\":null}}";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "rollout.jsonl",
        .data = rollout,
    });

    const rollout_path = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(rollout_path);

    try std.testing.expectError(
        error.InvalidReviewOutput,
        readReviewResultJsonFromRolloutAlloc(
            std.testing.allocator,
            rollout_path,
            "turn_1",
        ),
    );
}

test "readReviewResultJsonFromRolloutAlloc rejects malformed exited review output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn_1\"}}\n" ++
        "{\"type\":\"event_msg\",\"payload\":{" ++
        "\"type\":\"exited_review_mode\",\"review_output\":{" ++
        "\"findings\":[{\"title\":\"Missing body\"," ++
        "\"confidence_score\":0.8,\"priority\":1,\"code_location\":{" ++
        "\"absolute_file_path\":\"/tmp/file.zig\"," ++
        "\"line_range\":{\"start\":7,\"end\":9}}}]," ++
        "\"overall_correctness\":\"patch is incorrect\"," ++
        "\"overall_explanation\":\"One issue found.\"," ++
        "\"overall_confidence_score\":0.8}}}";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = "rollout.jsonl",
        .data = rollout,
    });

    const rollout_path = try tmp.dir.realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "rollout.jsonl",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(rollout_path);

    try std.testing.expectError(
        error.InvalidReviewOutput,
        readReviewResultJsonFromRolloutAlloc(
            std.testing.allocator,
            rollout_path,
            "turn_1",
        ),
    );
}

const test_invalid_review_results = [_][]const u8{
    "{\"overallCorrectness\":\"patch is correct\"," ++
        "\"overallExplanation\":\"clean\",\"overallConfidenceScore\":1}",
    "{\"findings\":{},\"overallCorrectness\":\"patch is correct\"," ++
        "\"overallExplanation\":\"clean\",\"overallConfidenceScore\":1}",
    "{\"findings\":[null],\"overallCorrectness\":\"patch is incorrect\"," ++
        "\"overallExplanation\":\"issue\",\"overallConfidenceScore\":1}",
    "{\"findings\":[{\"title\":\" \",\"body\":\"body\"," ++
        "\"confidenceScore\":0.8,\"priority\":1,\"codeLocation\":{" ++
        "\"absoluteFilePath\":\"/tmp/a.zig\",\"lineRange\":{" ++
        "\"start\":1,\"end\":1}}}],\"overallCorrectness\":\"patch is incorrect\"," ++
        "\"overallExplanation\":\"issue\",\"overallConfidenceScore\":0.8}",
    "{\"findings\":[{\"title\":\"title\",\"body\":\"body\"," ++
        "\"confidenceScore\":1.1,\"priority\":1,\"codeLocation\":{" ++
        "\"absoluteFilePath\":\"/tmp/a.zig\",\"lineRange\":{" ++
        "\"start\":1,\"end\":1}}}],\"overallCorrectness\":\"patch is incorrect\"," ++
        "\"overallExplanation\":\"issue\",\"overallConfidenceScore\":0.8}",
    "{\"findings\":[{\"title\":\"title\",\"body\":\"body\"," ++
        "\"confidenceScore\":0.8,\"priority\":4,\"codeLocation\":{" ++
        "\"absoluteFilePath\":\"/tmp/a.zig\",\"lineRange\":{" ++
        "\"start\":1,\"end\":1}}}],\"overallCorrectness\":\"patch is incorrect\"," ++
        "\"overallExplanation\":\"issue\",\"overallConfidenceScore\":0.8}",
    "{\"findings\":[{\"title\":\"title\",\"body\":\"body\"," ++
        "\"confidenceScore\":0.8,\"priority\":1,\"codeLocation\":{" ++
        "\"absoluteFilePath\":\"relative/a.zig\",\"lineRange\":{" ++
        "\"start\":1,\"end\":1}}}],\"overallCorrectness\":\"patch is incorrect\"," ++
        "\"overallExplanation\":\"issue\",\"overallConfidenceScore\":0.8}",
    "{\"findings\":[{\"title\":\"title\",\"body\":\"body\"," ++
        "\"confidenceScore\":0.8,\"priority\":1,\"codeLocation\":{" ++
        "\"absoluteFilePath\":\"/tmp/a.zig\",\"lineRange\":{" ++
        "\"start\":2,\"end\":1}}}],\"overallCorrectness\":\"patch is incorrect\"," ++
        "\"overallExplanation\":\"issue\",\"overallConfidenceScore\":0.8}",
    "{\"findings\":[],\"overallCorrectness\":\"patch is incorrect\"," ++
        "\"overallExplanation\":\"issue\",\"overallConfidenceScore\":0.8}",
    "{\"findings\":[{\"title\":\"title\",\"body\":\"body\"," ++
        "\"confidenceScore\":0.8,\"priority\":1,\"codeLocation\":{" ++
        "\"absoluteFilePath\":\"/tmp/a.zig\",\"lineRange\":{" ++
        "\"start\":1,\"end\":1}}}],\"overallCorrectness\":\"patch is correct\"," ++
        "\"overallExplanation\":\"issue\",\"overallConfidenceScore\":0.8}",
};

test "reviewFindingCount rejects malformed and inconsistent structured verdicts" {
    for (test_invalid_review_results) |invalid| {
        try std.testing.expectError(
            error.InvalidReviewOutput,
            reviewFindingCount(std.testing.allocator, invalid),
        );
    }
}

test "terminalLockFailureForStatus maps malformed structured verdict to invalid output" {
    const malformed =
        "{\"findings\":[],\"overallCorrectness\":\"patch is incorrect\"," ++
        "\"overallExplanation\":\"issue\",\"overallConfidenceScore\":0.8}";
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
        .review_result_json = try std.testing.allocator.dupe(u8, malformed),
        .review_text = null,
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);

    const failure = terminalLockFailureForStatus(std.testing.allocator, status) orelse
        return error.ExpectedTerminalLockFailure;
    try std.testing.expectEqualStrings("review_output_invalid", failure.code);
}

test "failureInfoForReviewStart maps detached parent rollout error" {
    const failure = failureInfoForReviewStart("no rollout found for thread id thr_123", true).?;
    try std.testing.expectEqualStrings("incompatible_codex_review_runtime", failure.code);
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

test "review wait completion semantics stay bound to the recorded runtime" {
    try std.testing.expectEqualStrings(
        "codex-cli 0.145.0",
        reviewAttemptRuntimeVersion("codex-cli 0.145.0", "codex-cli 0.144.0"),
    );
    try std.testing.expectEqualStrings(
        "codex-cli 0.144.0",
        reviewAttemptRuntimeVersion("codex-cli 0.144.0", "codex-cli 0.145.0"),
    );
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

test "parseArgs accepts review lock override only for review starters" {
    const start_argv = [_][]const u8{
        "cas_review_session",
        "start",
        "--cwd",
        "/repo",
        "--base",
        "main",
        "--review-lock-override",
        "human takeover",
    };
    var start = try parseArgs(std.testing.allocator, &start_argv);
    defer start.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("human takeover", start.review_lock_override_reason.?);

    const run_argv = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/repo",
        "--base",
        "main",
        "--review-lock-override",
        "human takeover",
    };
    var run = try parseArgs(std.testing.allocator, &run_argv);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("human takeover", run.review_lock_override_reason.?);

    const wait_argv = [_][]const u8{
        "cas_review_session",
        "wait",
        "--review-thread-id",
        "thr_1",
        "--review-lock-override",
        "not allowed",
    };
    try std.testing.expectError(error.ReviewLockOverrideUnsupportedAction, parseArgs(std.testing.allocator, &wait_argv));
}

test "parseArgs accepts fresh attempt only for review starters" {
    const start_argv = [_][]const u8{
        "cas_review_session",
        "start",
        "--cwd",
        "/repo",
        "--base",
        "main",
        "--fresh-attempt",
        "run 2",
    };
    var start = try parseArgs(std.testing.allocator, &start_argv);
    defer start.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("run 2", start.fresh_attempt_reason.?);

    const run_argv = [_][]const u8{
        "cas_review_session",
        "run",
        "--cwd",
        "/repo",
        "--base",
        "main",
        "--fresh-attempt",
        "run 2",
    };
    var run = try parseArgs(std.testing.allocator, &run_argv);
    defer run.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("run 2", run.fresh_attempt_reason.?);

    const wait_argv = [_][]const u8{
        "cas_review_session",
        "wait",
        "--review-thread-id",
        "thr_1",
        "--fresh-attempt",
        "not allowed",
    };
    try std.testing.expectError(
        error.FreshAttemptUnsupportedAction,
        parseArgs(std.testing.allocator, &wait_argv),
    );
}

test "accountFingerprintFromJsonAlloc redacts account identifiers" {
    const fingerprint = try accountFingerprintFromJsonAlloc(
        std.testing.allocator,
        "{\"account\":{\"email\":\"person@example.com\",\"type\":\"chatgpt\"}}",
    );
    defer std.testing.allocator.free(fingerprint);
    try std.testing.expect(std.mem.startsWith(u8, fingerprint, "acct:"));
    try std.testing.expect(std.mem.indexOf(u8, fingerprint, "person@example.com") == null);

    const unknown = try accountFingerprintFromJsonAlloc(std.testing.allocator, "{\"account\":null}");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqualStrings(unknown_account_fingerprint, unknown);
}

test "accountPrincipalFromJsonAlloc treats missing account id as reduced" {
    const stable = try accountPrincipalFromJsonAlloc(
        std.testing.allocator,
        "{\"account\":{\"id\":\"acct_123\",\"type\":\"chatgpt\",\"planType\":\"pro\"}}",
    );
    defer stable.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, stable.fingerprint, "acct:"));
    try std.testing.expect(!stable.reduced_protection);

    const reduced = try accountPrincipalFromJsonAlloc(
        std.testing.allocator,
        "{\"account\":{\"type\":\"chatgpt\",\"planType\":\"pro\"}}",
    );
    defer reduced.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, reduced.fingerprint, "acct:"));
    try std.testing.expect(reduced.reduced_protection);
    try std.testing.expect(!std.mem.eql(u8, stable.fingerprint, reduced.fingerprint));
}

fn testTupleIdentity(account_fingerprint: []const u8) ReviewTupleIdentity {
    return .{
        .repo_realpath = "/repo",
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .resolved_codex_path = "/bin/codex",
        .resolved_codex_version = "codex 0.1.0",
        .account_fingerprint = account_fingerprint,
        .account_fingerprint_reduced_protection = std.mem.eql(u8, account_fingerprint, unknown_account_fingerprint),
        .codex_thread_id = "thread-test",
    };
}

test "review tuple hash is stable and account-bound" {
    const tuple_a = testTupleIdentity("acct:a");
    const tuple_a_again = testTupleIdentity("acct:a");
    const tuple_b = testTupleIdentity("acct:b");

    const hash_a = try reviewTupleHashAlloc(std.testing.allocator, tuple_a);
    defer std.testing.allocator.free(hash_a);
    const hash_a_again = try reviewTupleHashAlloc(std.testing.allocator, tuple_a_again);
    defer std.testing.allocator.free(hash_a_again);
    const hash_b = try reviewTupleHashAlloc(std.testing.allocator, tuple_b);
    defer std.testing.allocator.free(hash_b);

    try std.testing.expectEqualStrings(
        "sha256:4b29e5034fbfe5a15e7abb9898bc9bc317b83c15c0b93106fc53a874710d5fbd",
        hash_a,
    );
    try std.testing.expectEqualStrings(hash_a, hash_a_again);
    try std.testing.expect(!std.mem.eql(u8, hash_a, hash_b));

    const binding_json = try stringifyAnyAlloc(std.testing.allocator, testWorkflowBinding());
    defer std.testing.allocator.free(binding_json);
    const binding_digest = try sha256HexAlloc(std.testing.allocator, binding_json);
    defer std.testing.allocator.free(binding_digest);
    var bound_tuple = tuple_a;
    bound_tuple.workflow_binding = testWorkflowBinding();
    bound_tuple.workflow_binding_digest = binding_digest;
    const bound_hash = try reviewTupleHashAlloc(std.testing.allocator, bound_tuple);
    defer std.testing.allocator.free(bound_hash);
    try std.testing.expect(!std.mem.eql(u8, hash_a, bound_hash));

    var other_binding = testWorkflowBinding();
    other_binding.requestFingerprint = "sha256:other-request";
    const other_json = try stringifyAnyAlloc(std.testing.allocator, other_binding);
    defer std.testing.allocator.free(other_json);
    const other_digest = try sha256HexAlloc(std.testing.allocator, other_json);
    defer std.testing.allocator.free(other_digest);
    bound_tuple.workflow_binding = other_binding;
    bound_tuple.workflow_binding_digest = other_digest;
    const other_hash = try reviewTupleHashAlloc(std.testing.allocator, bound_tuple);
    defer std.testing.allocator.free(other_hash);
    try std.testing.expect(!std.mem.eql(u8, bound_hash, other_hash));

    bound_tuple.workflow_binding = testWorkflowBinding();
    bound_tuple.workflow_binding_digest = binding_digest;
    const bound_lock = makeReviewTupleLock(
        bound_hash,
        bound_tuple,
        "starting_review",
        1,
        null,
        null,
    );
    try std.testing.expect(try reviewTupleLockWorkflowBindingValidAlloc(
        std.testing.allocator,
        bound_lock,
    ));
    var current_without_lease = bound_lock;
    current_without_lease.ownerLeaseVersion = null;
    try std.testing.expect(!try reviewTupleLockWorkflowBindingValidAlloc(
        std.testing.allocator,
        current_without_lease,
    ));
    var historical_lock = bound_lock;
    historical_lock.lockVersion = legacy_review_tuple_lock_version;
    historical_lock.ownerLeaseVersion = null;
    try std.testing.expect(try reviewTupleLockWorkflowBindingValidAlloc(
        std.testing.allocator,
        historical_lock,
    ));
    historical_lock.ownerLeaseVersion = review_owner_lease_version;
    try std.testing.expect(!try reviewTupleLockWorkflowBindingValidAlloc(
        std.testing.allocator,
        historical_lock,
    ));
    var tampered_lock = bound_lock;
    tampered_lock.workflowBinding = other_binding;
    try std.testing.expect(!try reviewTupleLockWorkflowBindingValidAlloc(
        std.testing.allocator,
        tampered_lock,
    ));
}

test "review tuple currentness rejects runtime principal and thread drift" {
    const stored = testTupleIdentity("acct:a");
    try std.testing.expect((try reviewTupleCurrentnessFailureAlloc(
        std.testing.allocator,
        stored,
        stored,
    )) == null);

    var runtime_drift = stored;
    runtime_drift.resolved_codex_version = "codex 0.2.0";
    try std.testing.expectEqualStrings(
        "review_tuple_mismatch",
        (try reviewTupleCurrentnessFailureAlloc(
            std.testing.allocator,
            stored,
            runtime_drift,
        )).?.code,
    );

    var principal_drift = stored;
    principal_drift.account_fingerprint = "acct:b";
    try std.testing.expectEqualStrings(
        "review_tuple_mismatch",
        (try reviewTupleCurrentnessFailureAlloc(
            std.testing.allocator,
            stored,
            principal_drift,
        )).?.code,
    );

    var reduced = stored;
    reduced.account_fingerprint_reduced_protection = true;
    try std.testing.expectEqualStrings(
        "review_principal_unavailable",
        (try reviewTupleCurrentnessFailureAlloc(
            std.testing.allocator,
            stored,
            reduced,
        )).?.code,
    );

    var thread_drift = stored;
    thread_drift.codex_thread_id = "thread-other";
    try std.testing.expectEqualStrings(
        "review_tuple_mismatch",
        (try reviewTupleCurrentnessFailureAlloc(
            std.testing.allocator,
            stored,
            thread_drift,
        )).?.code,
    );
}

test "run and start wait terminal proof rejects tuple drift" {
    const clean_result =
        "{\"findings\":[],\"overallCorrectness\":\"patch is correct\"," ++
        "\"overallExplanation\":\"Clean.\",\"overallConfidenceScore\":1}";
    const status = ReviewStatus{
        .thread_status = "idle",
        .turn_status = "completed",
        .turn_count = 1,
        .materialized = true,
        .thread_preview = "",
        .rollout_path = "/tmp/rollout.jsonl",
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = true,
        .last_turn_has_exited_review_mode = true,
        .review_result_available = true,
        .review_result_source = "rollout_exited_review_mode",
        .review_result_json = clean_result,
        .review_text = null,
        .raw_response_json = "{}",
    };
    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    const stored = testTupleIdentity("acct:a");
    var runtime_drift = stored;
    runtime_drift.resolved_codex_version = "codex 0.2.0";

    const failure = (try terminalReviewFailureAlloc(
        std.testing.allocator,
        status,
        identity,
        identity,
        stored,
        runtime_drift,
    )).?;
    try std.testing.expectEqualStrings("review_tuple_mismatch", failure.code);

    const missing_subject = (try terminalReviewFailureAlloc(
        std.testing.allocator,
        status,
        identity,
        null,
        stored,
        stored,
    )).?;
    try std.testing.expectEqualStrings(
        "review_subject_recapture_failed",
        missing_subject.code,
    );

    const missing_context = (try terminalReviewFailureAlloc(
        std.testing.allocator,
        status,
        identity,
        identity,
        stored,
        null,
    )).?;
    try std.testing.expectEqualStrings(
        "review_context_unavailable",
        missing_context.code,
    );
}

test "review tuple lock action classifies active terminal exhausted and stale states" {
    const now_s: i64 = 1000;
    const active = ReviewTupleLock{
        .tupleHash = "sha256:active",
        .repoRealpath = "/repo",
        .baseSha = "base",
        .headSha = "head",
        .targetFingerprint = "fp",
        .resolvedCodexPath = "/bin/codex",
        .resolvedCodexVersion = "codex 0.1.0",
        .accountFingerprint = "acct:a",
        .accountFingerprintReducedProtection = false,
        .state = "waiting",
        .reviewThreadId = "thr_1",
        .createdAtUnixS = now_s,
        .updatedAtUnixS = now_s,
        .expiresAtUnixS = now_s + 60,
        .ownerPid = 1,
    };
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockAction("run", active, now_s, null, null));
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockActionWithProbe("run", active, now_s, null, null, true));

    var transport_lost = active;
    transport_lost.lastFailureCode = "review_transport_lost";
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockActionWithProbe("run", transport_lost, now_s, null, null, false));
    try std.testing.expectEqual(ReviewTupleLockAction.auto_replace_dead_transport, reviewTupleLockActionWithProbe("run", transport_lost, now_s, null, null, true));

    var timed_out = active;
    timed_out.lastFailureCode = "wait_timed_out";
    try std.testing.expectEqualStrings("timeout", tupleLockDiagnosticVerdictStatus(timed_out));
    try std.testing.expectEqual(
        ReviewTupleLockAction.return_existing,
        reviewTupleLockActionWithProbe("run", timed_out, now_s, null, null, false),
    );
    try std.testing.expectEqual(
        ReviewTupleLockAction.auto_replace_dead_transport,
        reviewTupleLockActionWithProbe("run", timed_out, now_s, null, null, true),
    );
    try std.testing.expectEqualStrings("incomplete", tupleLockDiagnosticVerdictStatus(active));

    var terminal = active;
    terminal.state = "terminal";
    try std.testing.expectEqual(ReviewTupleLockAction.normalize_existing, reviewTupleLockAction("run", terminal, now_s, null, null));
    try std.testing.expectEqual(ReviewTupleLockAction.fresh_after_terminal, reviewTupleLockAction("run", terminal, now_s, null, "run 2"));
    try std.testing.expectEqual(ReviewTupleLockAction.fresh_after_terminal, reviewTupleLockAction("start", terminal, now_s, null, "run 2"));
    terminal.expiresAtUnixS = now_s - 1;
    try std.testing.expectEqual(
        ReviewTupleLockAction.normalize_existing,
        reviewTupleLockAction("run", terminal, now_s, null, null),
    );
    try std.testing.expectEqual(
        ReviewTupleLockAction.fresh_after_terminal,
        reviewTupleLockAction("run", terminal, now_s, null, "run 3"),
    );

    var legacy_terminal = terminal;
    legacy_terminal.lockVersion = legacy_review_tuple_lock_version;
    legacy_terminal.ownerLeaseVersion = null;
    try std.testing.expectEqual(
        ReviewTupleLockAction.normalize_existing,
        reviewTupleLockAction("run", legacy_terminal, now_s, null, null),
    );
    try std.testing.expectEqual(
        ReviewTupleLockAction.fresh_after_terminal,
        reviewTupleLockAction("start", legacy_terminal, now_s, null, "upgrade retry"),
    );
    var legacy_active = active;
    legacy_active.lockVersion = legacy_review_tuple_lock_version;
    legacy_active.ownerLeaseVersion = null;
    try std.testing.expectEqual(
        ReviewTupleLockAction.block_invalid,
        reviewTupleLockAction("run", legacy_active, now_s, "override", null),
    );

    var exhausted = active;
    exhausted.state = "account_resource_exhausted";
    try std.testing.expectEqual(
        ReviewTupleLockAction.block_account_resource,
        reviewTupleLockAction("run", exhausted, now_s, null, "run 2"),
    );
    try std.testing.expectEqual(
        ReviewTupleLockAction.takeover_with_override,
        reviewTupleLockAction("run", exhausted, now_s, "manual reset", null),
    );
    exhausted.expiresAtUnixS = now_s - 1;
    try std.testing.expectEqual(
        ReviewTupleLockAction.block_account_resource,
        reviewTupleLockAction("run", exhausted, now_s, null, "run 2"),
    );

    var stale = active;
    stale.expiresAtUnixS = now_s - 1;
    try std.testing.expectEqual(
        ReviewTupleLockAction.block_stale,
        reviewTupleLockAction("run", stale, now_s, null, null),
    );
    try std.testing.expectEqual(
        ReviewTupleLockAction.takeover_with_override,
        reviewTupleLockAction("run", stale, now_s, "stale owner", null),
    );
    try std.testing.expectEqualStrings("blocked_stale_lock", reviewBrokerActionForBlockedLock(.block_stale));
}

test "review tuple acquire does not reuse non-proof terminal receipts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const reusable_receipt =
        \\{"reviewVerdict":{"status":"findings","backendClass":"cas-start-wait","clean":false,"findingCount":1,"baseSha":"base","headSha":"head","targetFingerprint":"fp","reviewThreadId":"thr","reviewTurnId":"turn","accountFingerprint":"acct:a","accountFingerprintReducedProtection":false,"principalStrength":"strong","findings":[{"title":"issue"}]}}
    ;
    const diagnostic_receipt =
        "{\"reviewVerdict\":{\"status\":\"clean\"," ++
        "\"backendClass\":\"cas-start-wait\",\"clean\":true," ++
        "\"findingCount\":0,\"baseSha\":\"base\",\"headSha\":\"head\"," ++
        "\"targetFingerprint\":\"fp\",\"reviewThreadId\":\"thr\"," ++
        "\"reviewTurnId\":\"turn\",\"accountFingerprint\":\"acct:a\"," ++
        "\"accountFingerprintReducedProtection\":true," ++
        "\"principalStrength\":\"reduced\",\"findings\":[]}}";
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "reusable.json", .data = reusable_receipt });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "diagnostic.json", .data = diagnostic_receipt });
    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const reusable_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "reusable.json" });
    defer std.testing.allocator.free(reusable_path);
    const diagnostic_path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "diagnostic.json" });
    defer std.testing.allocator.free(diagnostic_path);
    const target_identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    const now_s: i64 = 1000;
    var lock = ReviewTupleLock{
        .tupleHash = "sha256:terminal",
        .repoRealpath = "/repo",
        .baseSha = "base",
        .headSha = "head",
        .targetFingerprint = "fp",
        .resolvedCodexPath = "/bin/codex",
        .resolvedCodexVersion = "codex 0.1.0",
        .accountFingerprint = "acct:a",
        .accountFingerprintReducedProtection = false,
        .state = "terminal",
        .reviewThreadId = "thr",
        .reviewTurnId = "turn",
        .recordPath = reusable_path,
        .createdAtUnixS = now_s,
        .updatedAtUnixS = now_s,
        .expiresAtUnixS = now_s + 60,
        .ownerPid = 1,
    };
    try std.testing.expectEqual(ReviewTupleLockAction.normalize_existing, reviewTupleLockActionForAcquire(std.testing.allocator, "run", lock, now_s, null, null, target_identity, null));

    lock.recordPath = diagnostic_path;
    try std.testing.expectEqual(ReviewTupleLockAction.fresh_after_terminal, reviewTupleLockActionForAcquire(std.testing.allocator, "run", lock, now_s, null, null, target_identity, null));
}

test "review tuple lock write and load roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);
    const tuple = testTupleIdentity("acct:a");
    const tuple_hash = try reviewTupleHashAlloc(std.testing.allocator, tuple);
    defer std.testing.allocator.free(tuple_hash);
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}.json",
        .{ tmp_root, tuple_hash["sha256:".len..] },
    );
    defer std.testing.allocator.free(path);

    var lock = makeReviewTupleLock(tuple_hash, tuple, "starting_review", 1, null, null);
    lock.reviewThreadId = "thr_1";
    lock.reviewTurnId = "turn_1";
    lock.recordPath = "/repo/receipt.json";
    lock.eventLogPath = "/repo/events.ndjson";
    lock.managedServerPid = 9;
    lock.updatedAtUnixS = 2;
    lock.expiresAtUnixS = 3;
    lock.ownerPid = 4;
    try writeReviewTupleLock(std.testing.allocator, path, lock);
    var loaded = (try loadReviewTupleLock(std.testing.allocator, path)).?;
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(review_tuple_lock_version, loaded.record.lockVersion);
    try std.testing.expectEqualStrings("starting_review", loaded.record.state);
    try std.testing.expectEqualStrings("thr_1", loaded.record.reviewThreadId.?);
    try std.testing.expectEqualStrings("acct:a", loaded.record.accountFingerprint);
    try std.testing.expectEqual(@as(?u64, 9), loaded.record.managedServerPid);

    try markReviewStartSendStarted(std.testing.allocator, path, &lock);
    try std.testing.expect(lock.reviewStartSendStarted);
    var marked = (try loadReviewTupleLock(std.testing.allocator, path)).?;
    defer marked.deinit(std.testing.allocator);
    try std.testing.expect(marked.record.reviewStartSendStarted);
}

test "recordless dead owner recovery terminalizes the exact lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const tuple = testTupleIdentity("acct:a");
    const tuple_hash = try reviewTupleHashAlloc(std.testing.allocator, tuple);
    defer std.testing.allocator.free(tuple_hash);
    const lock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}.json",
        .{ root, tuple_hash["sha256:".len..] },
    );
    defer std.testing.allocator.free(lock_path);
    var lock = makeReviewTupleLock(
        tuple_hash,
        tuple,
        "starting_review",
        1,
        null,
        "recover exact request",
    );
    try writeReviewTupleLock(std.testing.allocator, lock_path, lock);
    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };

    const pre_send_predecessor_path = (try persistDeadOwnerRecoveryEvidence(
        std.testing.allocator,
        lock_path,
        lock,
        identity,
    )).?;
    defer std.testing.allocator.free(pre_send_predecessor_path);
    var pre_send = (try loadReviewTupleLock(std.testing.allocator, lock_path)).?;
    defer pre_send.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pre_review_start_failed", pre_send.record.state);
    try std.testing.expectEqualStrings(
        "workflow_bound_review_owner_lost_before_start",
        pre_send.record.lastFailureCode.?,
    );
    var pre_send_predecessor = (try loadReviewTupleLockArtifact(
        std.testing.allocator,
        pre_send_predecessor_path,
        false,
    )).?;
    defer pre_send_predecessor.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "pre_review_start_failed",
        pre_send_predecessor.record.state,
    );

    lock.ownerPid = 2;
    lock.createdAtUnixS = 2;
    lock.reviewStartSendStarted = true;
    try writeReviewTupleLock(std.testing.allocator, lock_path, lock);
    const post_send_predecessor_path = (try persistDeadOwnerRecoveryEvidence(
        std.testing.allocator,
        lock_path,
        lock,
        identity,
    )).?;
    defer std.testing.allocator.free(post_send_predecessor_path);
    var post_send = (try loadReviewTupleLock(std.testing.allocator, lock_path)).?;
    defer post_send.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("terminal", post_send.record.state);
    try std.testing.expectEqualStrings(
        "review_transport_lost",
        post_send.record.lastFailureCode.?,
    );
    var post_send_predecessor = (try loadReviewTupleLockArtifact(
        std.testing.allocator,
        post_send_predecessor_path,
        false,
    )).?;
    defer post_send_predecessor.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("terminal", post_send_predecessor.record.state);

    var successor = lock;
    successor.ownerPid = 3;
    successor.createdAtUnixS = 3;
    successor.state = "starting_review";
    successor.lastFailureCode = null;
    try writeReviewTupleLock(std.testing.allocator, lock_path, successor);
    var preserved_predecessor = (try loadReviewTupleLockArtifact(
        std.testing.allocator,
        post_send_predecessor_path,
        false,
    )).?;
    defer preserved_predecessor.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("terminal", preserved_predecessor.record.state);
    try std.testing.expectEqual(@as(u64, 2), preserved_predecessor.record.ownerPid);
}

test "replacement admission requires exact predecessor shutdown receipt" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const receipt_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "shutdown-receipt.json" },
    );
    defer std.testing.allocator.free(receipt_path);
    var child = try cas_websocket.spawnDetachedProcess(
        std.testing.allocator,
        "/tmp",
        &.{ "/bin/sh", "-c", "sleep 10" },
        io,
    );
    defer child.kill(io);
    const process_id: u64 = switch (builtin.os.tag) {
        .windows => @intCast(@intFromPtr(child.id.?)),
        .wasi => 0,
        else => @intCast(child.id.?),
    };
    const lock = ReviewTupleLock{
        .tupleHash = "sha256:predecessor",
        .repoRealpath = "/repo",
        .baseSha = "base",
        .headSha = "head",
        .targetFingerprint = "fp",
        .resolvedCodexPath = "/bin/codex",
        .resolvedCodexVersion = "codex 0.1.0",
        .accountFingerprint = "acct:a",
        .accountFingerprintReducedProtection = false,
        .state = "starting_review",
        .managedServerPid = process_id,
        .managedServerShutdownReceiptPath = receipt_path,
        .managedServerShutdownReceiptToken = "generation-token",
        .createdAtUnixS = 1,
        .updatedAtUnixS = 1,
        .expiresAtUnixS = 61,
        .ownerPid = 1,
    };

    try std.testing.expectError(
        error.ReviewPredecessorStillAlive,
        ensureReviewTuplePredecessorExitedWithin(std.testing.allocator, lock, 1),
    );

    try durable_store.writeTextAtomic(
        std.testing.allocator,
        receipt_path,
        "{\"schema\":\"CAS-WDR-v1\",\"token\":\"wrong-token\"}\n",
    );
    try std.testing.expectError(
        error.InvalidReviewTupleLockBinding,
        ensureReviewTuplePredecessorExitedWithin(std.testing.allocator, lock, 1),
    );
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        receipt_path,
        "{\"schema\":\"CAS-WDR-v1\",\"token\":\"generation-token\"}\n",
    );
    try ensureReviewTuplePredecessorExitedWithin(std.testing.allocator, lock, 1);
    try std.testing.expect(cas_websocket.processAlive(process_id));

    var legacy_lock = lock;
    legacy_lock.managedServerShutdownReceiptPath = null;
    legacy_lock.managedServerShutdownReceiptToken = null;
    try std.testing.expectError(
        error.ReviewPredecessorStillAlive,
        ensureReviewTuplePredecessorExitedWithin(std.testing.allocator, legacy_lock, 1),
    );
    try ensureReviewTuplePredecessorExitedWithin(
        std.testing.allocator,
        legacy_lock,
        cas_websocket.owner_watchdog_shutdown_grace_ms + 100,
    );
    try std.testing.expect(cas_websocket.processAlive(process_id));
}

test "review tuple lock load rejects path and complete-tuple mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const tuple = testTupleIdentity("acct:a");
    const tuple_hash = try reviewTupleHashAlloc(std.testing.allocator, tuple);
    defer std.testing.allocator.free(tuple_hash);
    const lock = makeReviewTupleLock(tuple_hash, tuple, "review_started", 1, null, null);

    const wrong_path = try std.fs.path.join(std.testing.allocator, &.{ root, "wrong.json" });
    defer std.testing.allocator.free(wrong_path);
    try writeReviewTupleLock(std.testing.allocator, wrong_path, lock);
    try std.testing.expectError(
        error.InvalidReviewTupleLockBinding,
        loadReviewTupleLock(std.testing.allocator, wrong_path),
    );

    const correct_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}.json",
        .{ root, tuple_hash["sha256:".len..] },
    );
    defer std.testing.allocator.free(correct_path);
    var incomplete = lock;
    incomplete.codexThreadId = null;
    try writeReviewTupleLock(std.testing.allocator, correct_path, incomplete);
    try std.testing.expectError(
        error.InvalidReviewTupleLockBinding,
        loadReviewTupleLock(std.testing.allocator, correct_path),
    );
    var principal_flag_tamper = lock;
    principal_flag_tamper.accountFingerprintReducedProtection = true;
    try writeReviewTupleLock(
        std.testing.allocator,
        correct_path,
        principal_flag_tamper,
    );
    try std.testing.expectError(
        error.InvalidReviewTupleLockBinding,
        loadReviewTupleLock(std.testing.allocator, correct_path),
    );
}

test "dead transport proof releases missing record path exactly once" {
    const lock = ReviewTupleLock{
        .tupleHash = "sha256:dead",
        .repoRealpath = "/repo",
        .baseSha = "base",
        .headSha = "head",
        .targetFingerprint = "fp",
        .resolvedCodexPath = "/bin/codex",
        .resolvedCodexVersion = "codex 0.1.0",
        .accountFingerprint = "acct:a",
        .accountFingerprintReducedProtection = false,
        .codexThreadId = "thread-test",
        .state = "waiting",
        .recordPath = "/definitely/missing/cas-review-record.json",
        .createdAtUnixS = 1,
        .updatedAtUnixS = 1,
        .expiresAtUnixS = 2,
        .ownerPid = 999_999_999,
        .lastFailureCode = "review_transport_lost",
    };
    try std.testing.expect(!reviewTupleLockDeadTransportProven(std.testing.allocator, lock));
}

test "terminal transport loss requests a fresh same-tuple attempt" {
    const tuple = testTupleIdentity("acct:a");
    const tuple_hash = try reviewTupleHashAlloc(std.testing.allocator, tuple);
    defer std.testing.allocator.free(tuple_hash);
    var lock = makeReviewTupleLock(tuple_hash, tuple, "terminal", 1, null, null);
    lock.lastFailureCode = "review_transport_lost";
    lock.recordPath = "/definitely/missing/cas-review-record.json";
    const target_identity = TargetIdentity{
        .base_sha = tuple.base_sha,
        .head_sha = tuple.head_sha,
        .fingerprint = tuple.target_fingerprint,
    };
    try std.testing.expectEqual(
        ReviewTupleLockAction.fresh_after_terminal,
        reviewTupleLockActionForAcquire(
            std.testing.allocator,
            "run",
            lock,
            1,
            null,
            null,
            target_identity,
            null,
        ),
    );
    try std.testing.expectEqual(
        ReviewTupleLockAction.block_active,
        reviewTupleLockActionForAcquire(
            std.testing.allocator,
            "run",
            lock,
            1,
            null,
            null,
            target_identity,
            true,
        ),
    );
}

test "workflow-bound active lock with dead owner becomes terminal recovery" {
    const tuple = testTupleIdentity("acct:a");
    const target_identity = TargetIdentity{
        .base_sha = tuple.base_sha,
        .head_sha = tuple.head_sha,
        .fingerprint = tuple.target_fingerprint,
    };
    const lock = ReviewTupleLock{
        .tupleHash = "sha256:dead-owner",
        .repoRealpath = tuple.repo_realpath,
        .baseSha = tuple.base_sha,
        .headSha = tuple.head_sha,
        .targetFingerprint = tuple.target_fingerprint,
        .resolvedCodexPath = tuple.resolved_codex_path,
        .resolvedCodexVersion = tuple.resolved_codex_version,
        .accountFingerprint = tuple.account_fingerprint,
        .accountFingerprintReducedProtection = false,
        .codexThreadId = tuple.codex_thread_id,
        .workflowBinding = testWorkflowBinding(),
        .ownerLeaseVersion = review_owner_lease_version,
        .state = "starting_review",
        .createdAtUnixS = 1,
        .updatedAtUnixS = 1,
        .expiresAtUnixS = std.math.maxInt(i64),
        .ownerPid = 999_999_999,
    };
    try std.testing.expectEqual(
        ReviewTupleLockAction.block_dead_owner,
        reviewTupleLockActionForAcquire(
            std.testing.allocator,
            "start",
            lock,
            1,
            null,
            null,
            target_identity,
            false,
        ),
    );
    try std.testing.expectEqualStrings(
        "terminal_dead_owner",
        reviewBrokerActionForBlockedLock(.block_dead_owner),
    );
    try std.testing.expectEqual(
        ReviewTupleLockAction.recover_dead_owner,
        reviewTupleLockActionForAcquire(
            std.testing.allocator,
            "start",
            lock,
            1,
            null,
            "exact request recovery",
            target_identity,
            false,
        ),
    );
}

test "workflow owner lease is exclusive and kernel-released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const lock_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "tuple.json" },
    );
    defer std.testing.allocator.free(lock_path);

    {
        var first = (try tryAcquireReviewOwnerLeaseAlloc(
            std.testing.allocator,
            lock_path,
        )).?;
        defer first.deinit(std.testing.allocator);
        try std.testing.expect((try tryAcquireReviewOwnerLeaseAlloc(
            std.testing.allocator,
            lock_path,
        )) == null);
    }
    var reacquired = (try tryAcquireReviewOwnerLeaseAlloc(
        std.testing.allocator,
        lock_path,
    )).?;
    defer reacquired.deinit(std.testing.allocator);
}

test "terminal timeout session replays only through its exact tuple lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_root = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, ".ledger", "cas" },
    );
    defer std.testing.allocator.free(store_root);
    const old_store_root = configured_store_root_override;
    configured_store_root_override = store_root;
    defer configured_store_root_override = old_store_root;
    const session_dir = try sessionDirAlloc(std.testing.allocator);
    defer std.testing.allocator.free(session_dir);
    const record_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/thr.json",
        .{session_dir},
    );
    defer std.testing.allocator.free(record_path);
    const event_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/thr.events.ndjson",
        .{session_dir},
    );
    defer std.testing.allocator.free(event_path);
    var record = SessionRecord{
        .cwd = root,
        .store_root = store_root,
        .store_scope = "repo-local",
        .repo_root = root,
        .codex_thread_id = "thread-test",
        .parent_thread_id = "parent",
        .review_thread_id = "thr",
        .review_turn_id = "turn",
        .delivery = "detached",
        .target = .{ .type = "uncommittedChanges" },
        .event_log_path = event_path,
        .created_at_unix_s = 1,
        .last_observed_status = "inProgress",
        .codex_version = "codex 0.1.0",
        .resolved_codex_path = "/bin/codex",
        .compatibility_verdict = "compatible",
        .transport_kind = "websocket",
        .transport_selection_reason = "detached_review_requires_cross_process_truth",
        .managed_server_pid = 1,
        .managed_server_listen_url = "ws://127.0.0.1:1",
        .orphan_ttl_seconds = 1,
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .accountFingerprint = "acct:a",
        .accountFingerprintReducedProtection = false,
        .workflowBinding = testWorkflowBinding(),
    };
    var tuple = try storedReviewTupleIdentityAlloc(std.testing.allocator, record);
    defer tuple.deinit(std.testing.allocator);
    const tuple_hash = try reviewTupleHashAlloc(std.testing.allocator, tuple);
    defer std.testing.allocator.free(tuple_hash);
    const lock_path = try reviewTupleLockPathAlloc(
        std.testing.allocator,
        tuple_hash,
    );
    defer std.testing.allocator.free(lock_path);
    var lock = makeReviewTupleLock(tuple_hash, tuple, "terminal", 1, null, null);
    lock.reviewThreadId = record.review_thread_id;
    lock.reviewTurnId = record.review_turn_id;
    lock.recordPath = record_path;
    lock.eventLogPath = event_path;
    const timeout_failure = terminalReviewTransportFailure("review_transport_timeout").?;
    lock.lastFailureCode = timeout_failure.code;
    try writeReviewTupleLock(std.testing.allocator, lock_path, lock);
    record.last_observed_status = "disconnected";
    record.terminal_failure_code = timeout_failure.code;
    record.terminal_failure_hint = timeout_failure.hint;
    record.terminal_failure_at_unix_s = 1;
    try writeSessionRecord(std.testing.allocator, record_path, record);
    var loaded = try loadOwnedSessionRecordPath(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, record_path),
    );
    defer loaded.deinit(std.testing.allocator);
    const failure = (try recordTerminalOwnerFailure(
        std.testing.allocator,
        loaded.record,
        record_path,
    )).?;
    try std.testing.expectEqualStrings("review_transport_timeout", failure.code);
    try std.testing.expect(try recordHasTerminalFailureReplayCandidate(
        std.testing.allocator,
        loaded.record,
        record_path,
    ));
    try std.testing.expect(!try recordIsNormalizedVerdictReplayCandidate(
        std.testing.allocator,
        loaded.record,
        record_path,
    ));
    const requested_identity = TargetIdentity{
        .base_sha = record.base_sha,
        .head_sha = record.head_sha,
        .fingerprint = record.target_fingerprint.?,
    };
    const normalized = try normalizeReceiptFromPathAlloc(
        std.testing.allocator,
        record_path,
        true,
        .{
            .requested_identity = requested_identity,
            .requested_identity_required = true,
        },
    );
    defer normalized.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("review_transport_failure", normalized.status);
    try std.testing.expectEqualStrings("review_terminal", normalized.review_attempt_phase);
    try std.testing.expectEqualStrings(
        "review_transport_timeout",
        normalized.failure_code.?,
    );
    try std.testing.expectEqual(true, normalized.retryable_same_tuple_now.?);
    try std.testing.expect(!normalized.tuple_verdict_exists);

    var mismatched = loaded.record;
    mismatched.review_turn_id = "other-turn";
    try std.testing.expectError(
        error.InvalidReviewTupleLockBinding,
        recordTerminalOwnerFailure(
            std.testing.allocator,
            mismatched,
            record_path,
        ),
    );

    const owner_failure = terminalReviewOwnerFailure("review_owner_failed").?;
    lock.lastFailureCode = owner_failure.code;
    try writeReviewTupleLock(std.testing.allocator, lock_path, lock);
    var owner_failed_record = loaded.record;
    owner_failed_record.terminal_failure_code = owner_failure.code;
    owner_failed_record.terminal_failure_hint = "historical owner-failure copy";
    owner_failed_record.terminal_failure_at_unix_s = 2;
    owner_failed_record.terminal_review_result_source = "rollout_exited_review_mode";
    owner_failed_record.terminal_review_result_json =
        "{\"findings\":[{\"title\":\"uncommitted\",\"body\":\"body\",\"confidenceScore\":0.9,\"priority\":1,\"codeLocation\":{\"absoluteFilePath\":\"/tmp/file\",\"lineRange\":{\"start\":1,\"end\":1}}}],\"overallCorrectness\":\"patch is incorrect\",\"overallExplanation\":\"uncommitted\",\"overallConfidenceScore\":0.9}";
    try writeSessionRecord(
        std.testing.allocator,
        record_path,
        owner_failed_record,
    );
    var historical_copy = try loadOwnedSessionRecordPath(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, record_path),
    );
    historical_copy.deinit(std.testing.allocator);
    const recorded_owner_failure = (try recordTerminalOwnerFailure(
        std.testing.allocator,
        owner_failed_record,
        record_path,
    )).?;
    try std.testing.expectEqualStrings("review_owner_failed", recorded_owner_failure.code);
    const owner_failed_receipt = try normalizeReceiptFromPathAlloc(
        std.testing.allocator,
        record_path,
        true,
        .{
            .requested_identity = requested_identity,
            .requested_identity_required = true,
        },
    );
    defer owner_failed_receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("incomplete", owner_failed_receipt.status);
    try std.testing.expectEqualStrings("review_terminal", owner_failed_receipt.review_attempt_phase);
    try std.testing.expectEqualStrings("review_owner_failed", owner_failed_receipt.failure_code.?);
    try std.testing.expectEqualStrings("owner_review_attempt", owner_failed_receipt.failure_class.?);
    try std.testing.expectEqual(true, owner_failed_receipt.retryable_same_tuple_now.?);

    lock.state = "waiting";
    lock.lastFailureCode = null;
    lock.ownerPid = currentProcessId();
    try writeReviewTupleLock(std.testing.allocator, lock_path, lock);
    try std.testing.expect(!try recordHasTerminalFailureReplayCandidate(
        std.testing.allocator,
        loaded.record,
        record_path,
    ));
    {
        var owner_lease = (try tryAcquireReviewOwnerLeaseAlloc(
            std.testing.allocator,
            lock_path,
        )).?;
        defer owner_lease.deinit(std.testing.allocator);
        try std.testing.expect(try workflowBoundRecordHasLiveOwner(
            std.testing.allocator,
            loaded.record,
            record_path,
        ));
    }
    var retained_owner_lease: ?ReviewOwnerLease = null;
    defer if (retained_owner_lease) |*lease| lease.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        WorkflowBoundRecordOwnerState.dead,
        try workflowBoundRecordOwnerState(
            std.testing.allocator,
            loaded.record,
            record_path,
            &retained_owner_lease,
        ),
    );

    var active_record = loaded.record;
    active_record.managed_server_pid = currentProcessId();
    active_record.last_observed_status = "inProgress";
    active_record.terminal_failure_code = null;
    active_record.terminal_failure_hint = null;
    active_record.terminal_failure_at_unix_s = null;
    try terminalizeDeadWorkflowBoundOwner(
        std.testing.allocator,
        record_path,
        &active_record,
        .{
            .code = timeout_failure.code,
            .hint = "dead-owner-specific display copy",
        },
    );
    try std.testing.expect(cas_websocket.processAlive(currentProcessId()));
    var terminalized = try loadOwnedSessionRecordPath(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, record_path),
    );
    defer terminalized.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "review_transport_timeout",
        terminalized.record.terminal_failure_code.?,
    );
    try std.testing.expectEqualStrings(
        timeout_failure.hint,
        terminalized.record.terminal_failure_hint.?,
    );

    var recovery_record = terminalized.record;
    recovery_record.last_observed_status = "inProgress";
    recovery_record.terminal_failure_code = null;
    recovery_record.terminal_failure_hint = null;
    recovery_record.terminal_failure_at_unix_s = null;
    recovery_record.terminal_review_result_source = null;
    recovery_record.terminal_review_result_json = null;
    try writeSessionRecord(std.testing.allocator, record_path, recovery_record);
    lock.state = "waiting";
    lock.lastFailureCode = null;
    try writeReviewTupleLock(std.testing.allocator, lock_path, lock);
    const predecessor_rer_path = try persistDeadOwnerRecoveryEvidence(
        std.testing.allocator,
        lock_path,
        lock,
        requested_identity,
    );
    defer std.testing.allocator.free(predecessor_rer_path.?);
    try std.Io.Dir.accessAbsolute(io, predecessor_rer_path.?, .{});
    var persisted_terminal = try loadOwnedSessionRecordPath(
        std.testing.allocator,
        try std.testing.allocator.dupe(u8, record_path),
    );
    defer persisted_terminal.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "review_transport_lost",
        persisted_terminal.record.terminal_failure_code.?,
    );

    lock.state = "normalized";
    lock.lastFailureCode = null;
    try writeReviewTupleLock(std.testing.allocator, lock_path, lock);
    try std.testing.expect(!(try transitionActiveReviewTupleLockForRecord(
        std.testing.allocator,
        recovery_record,
        record_path,
        "waiting",
        "wait_timed_out",
    )));
    var preserved_normalized = (try loadReviewTupleLock(
        std.testing.allocator,
        lock_path,
    )).?;
    defer preserved_normalized.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("normalized", preserved_normalized.record.state);
    try std.testing.expect(preserved_normalized.record.lastFailureCode == null);
}

test "terminal owner receipt survives persistence failure" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const child = try cas_websocket.spawnDetachedProcess(
        std.testing.allocator,
        "/tmp",
        &.{ "/bin/sh", "-c", "sleep 10" },
        io,
    );
    var managed_server = cas_websocket.ManagedServer{
        .child = child,
        .listen_url = try std.testing.allocator.dupe(u8, "ws://127.0.0.1:1"),
    };
    defer managed_server.deinit(std.testing.allocator);
    const managed_pid = managed_server.processId();
    var record = SessionRecord{
        .cwd = "/tmp",
        .parent_thread_id = "parent",
        .review_thread_id = "review",
        .review_turn_id = "turn",
        .delivery = "detached",
        .target = .{ .type = "uncommittedChanges" },
        .event_log_path = "/definitely/missing/events.ndjson",
        .created_at_unix_s = 1,
        .last_observed_status = "inProgress",
        .codex_version = "codex 0.1.0",
        .compatibility_verdict = "compatible",
    };
    const tuple = testTupleIdentity("acct:a");
    const lock = makeReviewTupleLock(
        "sha256:persistence-failure",
        tuple,
        "waiting",
        1,
        null,
        null,
    );
    const failure = terminalReviewTransportFailure("review_transport_lost").?;
    terminalizeOwnedReviewAttempt(
        std.testing.allocator,
        &managed_server,
        "/definitely/missing/lock.json",
        lock,
        .{
            .record_path = "/definitely/missing/review.json",
            .record = &record,
            .review_thread_id = record.review_thread_id,
            .review_turn_id = record.review_turn_id,
            .event_log_path = record.event_log_path,
        },
        failure,
    );
    try std.testing.expect(!cas_websocket.processAlive(managed_pid));
    try std.testing.expectEqualStrings("review_transport_lost", record.terminal_failure_code.?);
}

test "review tuple lock load reports malformed lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/lock.json", .{tmp_root});
    defer std.testing.allocator.free(path);

    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "lock.json", .data = "{\"lockVersion\":\"wrong\"" });
    try std.testing.expectError(error.UnexpectedEndOfInput, loadReviewTupleLock(std.testing.allocator, path));
}

test "review tuple lock exclusive write rejects duplicate first claim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/lock.json", .{tmp_root});
    defer std.testing.allocator.free(path);

    const lock = ReviewTupleLock{
        .tupleHash = "sha256:exclusive",
        .repoRealpath = "/repo",
        .baseSha = "base",
        .headSha = "head",
        .targetFingerprint = "fp",
        .resolvedCodexPath = "/bin/codex",
        .resolvedCodexVersion = "codex 0.1.0",
        .accountFingerprint = "acct:a",
        .accountFingerprintReducedProtection = false,
        .state = "starting_review",
        .createdAtUnixS = 1,
        .updatedAtUnixS = 1,
        .expiresAtUnixS = 61,
        .ownerPid = 4,
    };
    try writeReviewTupleLockExclusive(std.testing.allocator, path, lock);
    try std.testing.expectError(error.PathAlreadyExists, writeReviewTupleLockExclusive(std.testing.allocator, path, lock));
}

test "terminal clean receipt preserves transport lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const tmp_root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    const old_store_root = configured_store_root_override;
    const old_store_cwd = configured_store_cwd;
    const old_codex_thread_id = configured_codex_thread_id;
    configured_store_root_override = tmp_root;
    configured_store_cwd = tmp_root;
    configured_codex_thread_id = "thread-clean";
    defer {
        configured_store_root_override = old_store_root;
        configured_store_cwd = old_store_cwd;
        configured_codex_thread_id = old_codex_thread_id;
        allocator.free(tmp_root);
    }

    const record_path = try std.fmt.allocPrint(allocator, "{s}/review_sessions/thr_clean.json", .{tmp_root});
    defer allocator.free(record_path);
    const event_path = try std.fmt.allocPrint(allocator, "{s}/review_sessions/thr_clean.events.ndjson", .{tmp_root});
    defer allocator.free(event_path);
    const clean_result = "{\"findings\":[],\"overallCorrectness\":\"patch is correct\",\"overallExplanation\":\"clean\",\"overallConfidenceScore\":1}";
    const record = SessionRecord{
        .cwd = "/repo",
        .store_root = tmp_root,
        .store_scope = "repo-local",
        .repo_root = "/repo",
        .codex_thread_id = "thread-clean",
        .parent_thread_id = "parent",
        .review_thread_id = "thr_clean",
        .review_turn_id = "turn_clean",
        .delivery = "detached",
        .target = .{ .type = "baseBranch", .branch = "main" },
        .event_log_path = event_path,
        .created_at_unix_s = 1,
        .last_observed_status = "completed",
        .codex_version = "codex 0.1.0",
        .resolved_codex_path = "/bin/codex",
        .compatibility_verdict = "compatible",
        .transport_kind = "websocket",
        .terminal_review_result_source = "rollout_exited_review_mode",
        .terminal_review_result_json = clean_result,
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .accountFingerprint = "acct:test",
        .accountFingerprintReducedProtection = false,
    };
    try writeSessionRecord(allocator, record_path, record);

    const tuple = ReviewTupleIdentity{
        .repo_realpath = "/repo",
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .resolved_codex_path = "/bin/codex",
        .resolved_codex_version = "codex 0.1.0",
        .account_fingerprint = "acct:test",
        .account_fingerprint_reduced_protection = false,
        .codex_thread_id = "thread-clean",
    };
    const tuple_hash = try reviewTupleHashAlloc(allocator, tuple);
    defer allocator.free(tuple_hash);
    const lock_path = try std.fmt.allocPrint(
        allocator,
        "{s}/review_sessions/locks/{s}.json",
        .{ tmp_root, tuple_hash["sha256:".len..] },
    );
    defer allocator.free(lock_path);
    var lock = makeReviewTupleLock(tuple_hash, tuple, "waiting", 1, null, null);
    lock.reviewThreadId = "thr_old";
    lock.reviewTurnId = "turn_old";
    lock.updatedAtUnixS = 1;
    lock.expiresAtUnixS = 999;
    lock.ownerPid = 1;
    try writeReviewTupleLock(allocator, lock_path, lock);
    try std.testing.expect(durable_store.fileExists(lock_path));

    updateReviewTupleLockBestEffort(allocator, lock_path, lock, "terminal", null, "thr_clean", "turn_clean", record_path, event_path);
    try std.testing.expect(durable_store.fileExists(lock_path));
    var updated = (try loadReviewTupleLock(allocator, lock_path)).?;
    defer updated.deinit(allocator);
    try std.testing.expectEqualStrings("terminal", updated.record.state);
    try std.testing.expectEqualStrings(record_path, updated.record.recordPath.?);
}

test "review tuple lock rewrite lease is exclusive and kernel released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/lock.json", .{tmp_root});
    defer std.testing.allocator.free(path);

    var lease = try acquireReviewTupleLockRewriteLeaseWithin(
        std.testing.allocator,
        path,
        0,
    );
    try std.testing.expectError(
        error.PathAlreadyExists,
        acquireReviewTupleLockRewriteLeaseWithin(std.testing.allocator, path, 0),
    );
    lease.deinit(std.testing.allocator);
    var reacquired = try acquireReviewTupleLockRewriteLeaseWithin(
        std.testing.allocator,
        path,
        0,
    );
    defer reacquired.deinit(std.testing.allocator);
}

test "review tuple lock rewrite lease ignores orphaned sidecar content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/lock.json", .{tmp_root});
    defer std.testing.allocator.free(path);
    const lease_path = try reviewTupleLockRewriteLeasePathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(lease_path);

    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = lease_path,
        .data = "{\"ownerPid\":1,\"createdAtUnixS\":1}\n",
    });
    var lease = try acquireReviewTupleLockRewriteLeaseWithin(
        std.testing.allocator,
        path,
        0,
    );
    defer lease.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(lease_path, lease.path);
}
