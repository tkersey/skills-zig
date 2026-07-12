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
const default_review_timeout_ms: u32 = 1_800_000;

const UsageText =
    \\cas_review_session
    \\
    \\Control detached Codex review sessions via the app-server.
    \\
    \\Usage:
    \\  cas_review_session <run|current|list|import|inspect|validate-record|start|status|wait|interrupt|lane|receipt|lock> [options]
    \\
    \\Actions:
    \\  run        Broker one tuple-bound review verdict; waits and hides lock recovery.
    \\  current    Read the latest ledger-backed review record for the current tuple.
    \\  list       List ledger-backed review evidence records for the current tuple.
    \\  import     Import a legacy review artifact into CAS-RER-v1.
    \\  inspect    Diagnostic-only inspection of a CAS-RER-v1 evidence record.
    \\  validate-record
    \\             Validate a CAS-RER-v1 review evidence record.
    \\  start      Start a detached review session and persist its handle.
    \\  status     Read the persisted session and report current review status.
    \\  wait       Poll the persisted session until the review turn reaches a terminal status.
    \\  interrupt  Interrupt the persisted detached review turn.
    \\  lane       Reuse one managed app-server for multiple fresh-parent reviews.
    \\  receipt    Debug/compat receipt normalization and classification surfaces.
    \\  lock       Validate saved CAS review tuple-lock records.
    \\
    \\Lane actions:
    \\  lane start   Start a reusable review lane.
    \\  lane review  Run one fresh-parent review through the lane and archive review threads.
    \\  lane smoke   Start a lane and prove first review creation for a target tuple.
    \\  lane smoke-suite
    \\               Run repeated lane-first-review smoke checks across hooks/delays.
    \\  lane smoke-until-fixed
    \\               Run smoke-suite rounds until persistent lane can be promoted.
    \\  lane status  Report whether the lane app-server process is still alive.
    \\  lane stop    Stop the lane app-server process.
    \\
    \\Receipt actions:
    \\  receipt normalize  Normalize saved receipts into the reviewVerdict surface.
    \\  receipt classify   Classify saved receipt records into transport facts.
    \\  receipt gate       Deprecated compatibility gate; prefer import + validate-record.
    \\
    \\Lock actions:
    \\  lock gate          Validate saved CAS-RTL-v1 tuple-lock records.
    \\
    \\Run/start options:
    \\  --cwd DIR                        Workspace for the app-server.
    \\  --parent-thread-id THREAD_ID     Optional parent thread id to reuse.
    \\  --parent-mode MODE               Parent strategy: auto|fresh|reuse (default: auto).
    \\  --wait                           Keep the start process alive until the review turn reaches a terminal status.
    \\  --uncommitted                    Review staged, unstaged, and untracked changes.
    \\  --base BRANCH                    Review changes against a base branch.
    \\  --commit SHA                     Review a specific commit.
    \\  --title TITLE                    Optional commit title for --commit.
    \\  --custom-instructions VALUE      Exact review prompt, raw text, @file, or -; may accompany a target selector.
    \\  --workflow-binding-json VALUE    Optional opaque request binding as JSON or @file.
    \\  --multi-agent-mode MODE          explicit-request-only|proactive for fresh parent request flow.
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
    \\  --review-lock-override REASON    Explicitly override a stale or exhausted tuple lock.
    \\  --fresh-attempt REASON           Start a new same-tuple review after terminal evidence.
    \\
    \\Status/wait/interrupt options:
    \\  --review-thread-id THREAD_ID     Detached review thread id handle.
    \\  --latest                         Use the newest persisted review-session record for status/wait.
    \\
    \\Lane options:
    \\  --lane-id LANE_ID                Lane handle for lane review/status/stop.
    \\  --no-archive                     Do not best-effort archive lane review threads.
    \\  --no-wait                        For lane smoke, stop after review/start returns a handle.
    \\  --cleanup                        For lane smoke, best-effort archive smoke-created threads.
    \\  --runs N                         Smoke-suite run count (default: 5).
    \\  --runs-per-round N               Smoke-until-fixed runs per round (default: 5).
    \\  --max-rounds N                   Smoke-until-fixed maximum rounds (default: 3).
    \\  --required-consecutive-passes N  Required consecutive smoke passes (default: 3).
    \\  --delay-ms LIST                  Smoke delay schedule, comma-separated ms values.
    \\
    \\Common options:
    \\  --json                           Emit machine-readable JSON.
    \\  --verdict-only                   Emit only the compact reviewVerdict JSON for lane review.
    \\  --path FILE                      Receipt, lock, or session record file to process; repeatable.
    \\  --record FILE                    CAS-RER-v1 record file to validate; repeatable.
    \\  --glob PATTERN                   Simple receipt glob; repeatable.
    \\  --allow-reduced-principal        Include reduced-principal records in diagnostic inspection.
    \\  --allow-native-fallback          Include native-fallback records in diagnostic inspection.
    \\  --show-attachments               Include attachment paths in diagnostic inspect output.
    \\  --format FORMAT                  Helper output: table|json|jsonl (default: table).
    \\  --summary                        Include aggregate receipt counts.
    \\  --codex-thread-id ID             Codex session/thread id for review reuse scoping.
    \\  --store-root DIR                 Explicit CAS artifact root; default is repo .ledger/cas.
    \\  --timeout-ms N                   Wait timeout. Real review waits default to 1800000;
    \\                                   smoke/control waits default to 300000.
    \\  --poll-interval-ms N             Poll interval for `wait` (default: 250).
    \\  --help                           Show help.
    \\  --version                        Show version.
    \\  version                          Show version.
    \\
    \\Examples:
    \\  cas review_session run --cwd /path/to/repo --base main --custom-instructions @review.txt --workflow-binding-json @binding.json --timeout-ms 1800000 --json
    \\  cas review_session current --cwd /path/to/repo --base main --json
    \\  cas review_session list --cwd /path/to/repo --base main --json
    \\  cas review_session import --path review-1.json --cwd /path/to/repo --base main --json
    \\  cas review_session inspect --record rer_123.json --json
    \\  cas review_session validate-record --record rer_123.json --json
    \\  cas review_session start --cwd /path/to/repo --uncommitted --json
    \\  cas review_session start --cwd /path/to/repo --base main --json
    \\  cas review_session start --wait --cwd /path/to/repo --base main --timeout-ms 1800000 --json
    \\  cas review_session status --cwd /path/to/repo --review-thread-id thr_123 --json
    \\  cas review_session status --path /path/to/repo/.ledger/cas/review_sessions/thr_123.json --json
    \\  cas review_session status --cwd /path/to/repo --latest --json
    \\  cas review_session wait --cwd /path/to/repo --review-thread-id thr_123 --timeout-ms 1800000 --json
    \\  cas review_session interrupt --cwd /path/to/repo --review-thread-id thr_123 --json
    \\  cas review_session lane start --cwd /path/to/repo --json
    \\  cas review_session lane smoke --cwd /path/to/repo --base main --json
    \\  cas review_session lane smoke-suite --cwd /path/to/repo --base main --json --cleanup
    \\  cas review_session lane smoke-until-fixed --cwd /path/to/repo --base main --json --cleanup
    \\  cas review_session lane review --lane-id lane_123 --base main --timeout-ms 1800000 --json
    \\  cas review_session receipt normalize --path review-1.json --format json --summary
    \\  cas review_session receipt classify --path receipts.jsonl --format jsonl
    \\  cas review_session receipt gate --path review-1.json --format json
    \\  cas review_session lock gate --path tuple-lock.json --format json
    \\  cas review_session lane stop --lane-id lane_123 --json
;

const Action = enum {
    run,
    current,
    list,
    review_import,
    inspect,
    validate_record,
    start,
    status,
    wait,
    interrupt,
    lane,
    receipt,
    lock,

    fn parse(raw: []const u8) ?Action {
        if (std.mem.eql(u8, raw, "run")) return .run;
        if (std.mem.eql(u8, raw, "current")) return .current;
        if (std.mem.eql(u8, raw, "list")) return .list;
        if (std.mem.eql(u8, raw, "import")) return .review_import;
        if (std.mem.eql(u8, raw, "inspect")) return .inspect;
        if (std.mem.eql(u8, raw, "validate-record")) return .validate_record;
        if (std.mem.eql(u8, raw, "validate_record")) return .validate_record;
        if (std.mem.eql(u8, raw, "start")) return .start;
        if (std.mem.eql(u8, raw, "status")) return .status;
        if (std.mem.eql(u8, raw, "wait")) return .wait;
        if (std.mem.eql(u8, raw, "interrupt")) return .interrupt;
        if (std.mem.eql(u8, raw, "lane")) return .lane;
        if (std.mem.eql(u8, raw, "receipt")) return .receipt;
        if (std.mem.eql(u8, raw, "lock")) return .lock;
        return null;
    }
};

const LaneAction = enum {
    start,
    review,
    smoke,
    smoke_suite,
    smoke_until_fixed,
    status,
    stop,

    fn parse(raw: []const u8) ?LaneAction {
        if (std.mem.eql(u8, raw, "start")) return .start;
        if (std.mem.eql(u8, raw, "review")) return .review;
        if (std.mem.eql(u8, raw, "smoke")) return .smoke;
        if (std.mem.eql(u8, raw, "smoke-suite")) return .smoke_suite;
        if (std.mem.eql(u8, raw, "smoke-until-fixed")) return .smoke_until_fixed;
        if (std.mem.eql(u8, raw, "status")) return .status;
        if (std.mem.eql(u8, raw, "stop")) return .stop;
        return null;
    }
};

const ReceiptAction = enum {
    normalize,
    classify,
    gate,

    fn parse(raw: []const u8) ?ReceiptAction {
        if (std.mem.eql(u8, raw, "normalize")) return .normalize;
        if (std.mem.eql(u8, raw, "classify")) return .classify;
        if (std.mem.eql(u8, raw, "gate")) return .gate;
        return null;
    }
};

const LockAction = enum {
    gate,

    fn parse(raw: []const u8) ?LockAction {
        if (std.mem.eql(u8, raw, "gate")) return .gate;
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

const WorkflowBinding = struct {
    requestId: []const u8,
    requestFingerprint: []const u8,
};

const ParsedArgs = struct {
    executable_path: []const u8 = "cas_review_session",
    action: ?Action = null,
    lane_action: ?LaneAction = null,
    receipt_action: ReceiptAction = .normalize,
    lock_action: ?LockAction = null,
    cwd: ?[]const u8 = null,
    lane_id: ?[]const u8 = null,
    parent_thread_id: ?[]const u8 = null,
    parent_mode: ParentMode = .auto,
    multi_agent_mode: ?cas.MultiAgentMode = null,
    review_thread_id: ?[]const u8 = null,
    latest_review_session: bool = false,
    target: ?TargetConfig = null,
    custom_instructions_arg: ?[]const u8 = null,
    workflow_binding_arg: ?[]const u8 = null,
    wait_after_start: bool = false,
    archive_lane_threads: bool = true,
    lane_smoke_wait: bool = true,
    lane_smoke_cleanup: bool = false,
    smoke_runs: u32 = 5,
    smoke_runs_per_round: u32 = 5,
    smoke_max_rounds: u32 = 3,
    smoke_required_consecutive_passes: u32 = 3,
    smoke_delay_ms: []const u8 = "0,5000,30000,120000",
    smoke_hooks: []const u8 = "inherit,off",
    json: bool = false,
    verdict_only: bool = false,
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
    fallback_mode: FallbackMode = .none,
    review_lock_override_reason: ?[]const u8 = null,
    fresh_attempt_reason: ?[]const u8 = null,
    codex_thread_id: ?[]const u8 = null,
    store_root: ?[]const u8 = null,
    receipt_paths: []const []const u8 = &.{},
    receipt_globs: []const []const u8 = &.{},
    receipt_format: ReceiptFormat = .table,
    receipt_summary: bool = false,
    allow_reduced_principal: bool = false,
    allow_native_fallback: bool = false,
    show_attachments: bool = false,
    show_help: bool = false,
    show_version: bool = false,

    fn deinit(self: ParsedArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.receipt_paths);
        allocator.free(self.receipt_globs);
    }
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
    store_root: ?[]const u8 = null,
    store_scope: ?[]const u8 = null,
    repo_root: ?[]const u8 = null,
    codex_thread_id: ?[]const u8 = null,
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

const review_tuple_lock_version = "CAS-RTL-v1";
const review_tuple_lock_ttl_seconds: i64 = 30 * 60;
const unknown_account_fingerprint = "unknown-account";
const principal_strength_strong = "strong";
const principal_strength_reduced = "reduced";
const cas_review_evidence_schema = "CAS-RER-v1";
var configured_store_root_override: ?[]const u8 = null;
var configured_store_cwd: ?[]const u8 = null;
var configured_codex_thread_id: ?[]const u8 = null;
var configured_home: ?[]const u8 = null;

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
    codexThreadId: ?[]const u8 = null,
    workflowBinding: ?WorkflowBinding = null,
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
    takeover_with_override,
    block_active,
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
            .takeover_with_override => "takeover_with_override",
            .block_active => "block_active",
            .block_stale => "block_stale",
            .block_account_resource => "block_account_resource",
            .block_invalid => "block_invalid",
        };
    }
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
    first_review_thread_id: ?[]const u8 = null,
    first_review_turn_id: ?[]const u8 = null,
    last_smoke_status: ?[]const u8 = null,
    last_smoke_record_path: ?[]const u8 = null,
    last_smoke_cleanup_status: ?[]const u8 = null,
};

const LaneSmokeRecord = struct {
    schema_version: u32 = 1,
    action: []const u8 = "lane-smoke",
    smokeStatus: []const u8,
    laneId: []const u8,
    laneRecordPath: []const u8,
    repoRealpath: []const u8,
    baseSha: ?[]const u8,
    headSha: ?[]const u8,
    targetFingerprint: []const u8,
    resolvedCodexPath: []const u8,
    resolvedCodexVersion: []const u8,
    accountFingerprint: []const u8,
    accountFingerprintReducedProtection: bool,
    tupleHash: []const u8,
    parentThreadId: []const u8,
    reviewThreadId: []const u8,
    reviewTurnId: []const u8,
    recordPath: []const u8,
    eventLogPath: []const u8,
    cleanupStatus: []const u8,
    cleanupWarning: ?[]const u8 = null,
    createdAtUnixS: i64,
};

const LaneSmokeRunSummary = struct {
    run_id: []const u8,
    hook_policy: []const u8,
    delay_ms: u32,
    status: []const u8,
    review_attempt_phase: ?[]const u8,
    failure_code: ?[]const u8,
    review_verdict_status: ?[]const u8,
    finding_count: usize,
    review_attempt_exists: bool,
    tuple_verdict_exists: bool,
    lane_id: ?[]const u8,
    review_thread_id: ?[]const u8,
    base_sha: ?[]const u8,
    head_sha: ?[]const u8,
    target_fingerprint: ?[]const u8,
    receipt_path: ?[]const u8,
    exit_code: u8,

    fn deinit(self: LaneSmokeRunSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.hook_policy);
        allocator.free(self.status);
        if (self.review_attempt_phase) |value| allocator.free(value);
        if (self.failure_code) |value| allocator.free(value);
        if (self.review_verdict_status) |value| allocator.free(value);
        if (self.lane_id) |value| allocator.free(value);
        if (self.review_thread_id) |value| allocator.free(value);
        if (self.base_sha) |value| allocator.free(value);
        if (self.head_sha) |value| allocator.free(value);
        if (self.target_fingerprint) |value| allocator.free(value);
        if (self.receipt_path) |value| allocator.free(value);
    }
};

const OutputReceipt = struct {
    surface_action: []const u8 = "start",
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

fn applyMultiAgentModeReceipt(
    receipt: *OutputReceipt,
    mode: ?cas.MultiAgentMode,
    support: cas.MultiAgentModeSupport,
) void {
    receipt.requested_multi_agent_mode = mode;
    receipt.multi_agent_mode_support = if (mode == null) .not_requested else support;
    receipt.effective_multi_agent_mode = if (receipt.multi_agent_mode_support == .proven) mode else null;
    receipt.multi_agent_mode_metric_eligible = mode == .proactive and receipt.multi_agent_mode_support == .proven;
}

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
    return out;
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
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), usageDetailForParseError(err));
    };
    defer parsed.deinit(allocator);
    configured_store_root_override = parsed.store_root orelse init.environ_map.get("CAS_STORE_ROOT");
    configured_store_cwd = parsed.cwd;
    configured_codex_thread_id = parsed.codex_thread_id orelse
        init.environ_map.get("CODEX_THREAD_ID") orelse
        init.environ_map.get("CODEX_SESSION_ID");
    configured_home = init.environ_map.get("HOME");

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
        .current => try cmdReviewCurrent(allocator, init.io, parsed),
        .list => try cmdReviewList(allocator, init.io, parsed),
        .review_import => try cmdReviewImport(allocator, init.io, parsed),
        .inspect => try cmdReviewInspect(allocator, parsed),
        .validate_record => try cmdValidateRecord(allocator, parsed),
        .start => try cmdStart(allocator, init.io, parsed),
        .status => try cmdStatus(allocator, init.io, parsed),
        .wait => try cmdWait(allocator, init.io, parsed),
        .interrupt => try cmdInterrupt(allocator, init.io, parsed),
        .lane => try cmdLane(allocator, init.io, parsed),
        .receipt => try cmdReceipt(allocator, init.io, parsed),
        .lock => try cmdLock(allocator, parsed),
    }
}

fn defaultTimeoutMsForAction(parsed: ParsedArgs) u32 {
    const action = parsed.action orelse return default_control_timeout_ms;
    return switch (action) {
        .run, .wait => default_review_timeout_ms,
        .start => if (parsed.wait_after_start) default_review_timeout_ms else default_control_timeout_ms,
        .lane => if (parsed.lane_action == .review) default_review_timeout_ms else default_control_timeout_ms,
        .current,
        .list,
        .review_import,
        .inspect,
        .validate_record,
        .status,
        .interrupt,
        .receipt,
        .lock,
        => default_control_timeout_ms,
    };
}

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    var out = ParsedArgs{};
    var receipt_paths: std.ArrayList([]const u8) = .empty;
    var receipt_globs: std.ArrayList([]const u8) = .empty;
    errdefer {
        receipt_paths.deinit(allocator);
        receipt_globs.deinit(allocator);
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
    if (out.action.? == .lane) {
        if (i >= argv.len) return error.MissingLaneAction;
        out.lane_action = LaneAction.parse(argv[i]) orelse return error.UnknownLaneAction;
        i += 1;
    }
    if (out.action.? == .receipt and i < argv.len) {
        if (ReceiptAction.parse(argv[i])) |receipt_action| {
            out.receipt_action = receipt_action;
            i += 1;
        }
    }
    if (out.action.? == .lock) {
        if (i >= argv.len) return error.MissingLockAction;
        out.lock_action = LockAction.parse(argv[i]) orelse return error.UnknownLockAction;
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
        if (std.mem.eql(u8, arg, "--latest")) {
            out.latest_review_session = true;
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
        if (std.mem.eql(u8, arg, "--no-wait")) {
            out.lane_smoke_wait = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cleanup")) {
            out.lane_smoke_cleanup = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--summary")) {
            out.receipt_summary = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-reduced-principal")) {
            out.allow_reduced_principal = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-native-fallback")) {
            out.allow_native_fallback = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--show-attachments")) {
            out.show_attachments = true;
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
            if (out.custom_instructions_arg != null) return error.DuplicateCustomInstructions;
            const instructions = try loadCustomInstructionsAlloc(allocator, value);
            out.custom_instructions_arg = value;
            if (out.target) |*target| {
                target.instructions = instructions;
            } else {
                setTarget(&out, .{ .kind = .custom, .instructions = instructions });
            }
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
        if (std.mem.eql(u8, arg, "--runs")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidSmokeRuns;
            out.smoke_runs = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--runs-per-round")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidSmokeRuns;
            out.smoke_runs_per_round = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-rounds")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidSmokeRounds;
            out.smoke_max_rounds = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--required-consecutive-passes")) {
            const parsed = try std.fmt.parseInt(i64, value, 10);
            if (parsed <= 0) return error.InvalidRequiredConsecutivePasses;
            out.smoke_required_consecutive_passes = @intCast(parsed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--delay-ms")) {
            try validateCommaSeparatedNonNegativeU32(value);
            out.smoke_delay_ms = value;
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
            if (out.action == .lane and
                (out.lane_action == .smoke_suite or out.lane_action == .smoke_until_fixed))
            {
                try validateSmokeHookPolicies(value);
                out.smoke_hooks = value;
            } else {
                out.hook_policy = cas.hooks.HookPolicy.parse(value) orelse return error.InvalidHooksPolicy;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--fallback")) {
            out.fallback_mode = FallbackMode.parse(value) orelse return error.InvalidFallbackMode;
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
        if (std.mem.eql(u8, arg, "--record")) {
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
    errdefer out.deinit(allocator);

    if (out.multi_agent_mode != null) {
        switch (out.action.?) {
            .run => {},
            .current, .list, .review_import, .inspect, .validate_record => return error.MultiAgentModeUnsupportedAction,
            .start => {},
            .lane => switch (out.lane_action orelse return error.MissingLaneAction) {
                .review, .smoke, .smoke_suite, .smoke_until_fixed => {},
                .start, .status, .stop => return error.MultiAgentModeUnsupportedAction,
            },
            .status, .wait, .interrupt, .receipt, .lock => return error.MultiAgentModeUnsupportedAction,
        }
    }
    if (out.review_lock_override_reason != null) {
        switch (out.action.?) {
            .run => {},
            .current, .list, .review_import, .inspect, .validate_record => return error.ReviewLockOverrideUnsupportedAction,
            .start => {},
            .lane => if (out.lane_action != .review and out.lane_action != .smoke) return error.ReviewLockOverrideUnsupportedAction,
            .status, .wait, .interrupt, .receipt, .lock => return error.ReviewLockOverrideUnsupportedAction,
        }
    }
    if (out.fresh_attempt_reason != null) {
        switch (out.action.?) {
            .run => {},
            .current, .list, .review_import, .inspect, .validate_record => return error.FreshAttemptUnsupportedAction,
            .start => {},
            .lane => if (out.lane_action != .review) return error.FreshAttemptUnsupportedAction,
            .status, .wait, .interrupt, .receipt, .lock => return error.FreshAttemptUnsupportedAction,
        }
    }
    if (out.workflow_binding_arg != null) {
        switch (out.action.?) {
            .run, .current, .list, .start => {},
            .lane => if (out.lane_action != .review) return error.WorkflowBindingUnsupportedAction,
            .review_import, .inspect, .validate_record, .status, .wait, .interrupt, .receipt, .lock => return error.WorkflowBindingUnsupportedAction,
        }
    }
    switch (out.action.?) {
        .run, .start => {
            if (out.cwd == null) return error.MissingCwd;
            if (out.target == null) return error.MissingTarget;
            if (out.parent_mode == .fresh and out.parent_thread_id != null) return error.FreshParentModeDisallowsParentThreadId;
            if (out.parent_mode == .reuse and out.parent_thread_id == null) return error.ReuseParentModeRequiresParentThreadId;
        },
        .current, .list => {
            if (out.cwd == null) return error.MissingCwd;
            if (out.target == null) return error.MissingTarget;
        },
        .review_import => {
            if (out.receipt_paths.len == 0 and out.receipt_globs.len == 0) return error.MissingReceiptInput;
            if (out.target != null and out.cwd == null) return error.MissingCwd;
        },
        .inspect, .validate_record => {
            if (out.receipt_paths.len == 0 and out.receipt_globs.len == 0) return error.MissingReceiptInput;
        },
        .status, .wait => {
            if (out.review_thread_id != null and out.latest_review_session) return error.AmbiguousReviewSessionSelector;
            if (out.receipt_paths.len > 1 or (out.receipt_paths.len == 1 and (out.review_thread_id != null or out.latest_review_session))) return error.AmbiguousReviewSessionSelector;
            if (out.review_thread_id == null and !out.latest_review_session and out.receipt_paths.len == 0) return error.MissingReviewThreadId;
        },
        .interrupt => {
            if (out.latest_review_session) return error.LatestReviewSessionUnsupportedAction;
            if (out.receipt_paths.len > 1 or (out.receipt_paths.len == 1 and out.review_thread_id != null)) return error.AmbiguousReviewSessionSelector;
            if (out.review_thread_id == null and out.receipt_paths.len == 0) return error.MissingReviewThreadId;
        },
        .lane => switch (out.lane_action orelse return error.MissingLaneAction) {
            .start => {
                if (out.cwd == null) return error.MissingCwd;
            },
            .review => {
                if (out.lane_id == null) return error.MissingLaneId;
                if (out.target == null) return error.MissingTarget;
            },
            .smoke => {
                if (out.cwd == null) return error.MissingCwd;
                if (out.target == null) return error.MissingTarget;
            },
            .smoke_suite, .smoke_until_fixed => {
                if (out.cwd == null) return error.MissingCwd;
                if (out.target == null) return error.MissingTarget;
                if (!out.lane_smoke_wait) return error.NoWaitUnsupportedForSmokeSuite;
                if (out.smoke_required_consecutive_passes > out.smoke_runs and out.lane_action == .smoke_suite) return error.InvalidRequiredConsecutivePasses;
                if (out.lane_action == .smoke_until_fixed) {
                    const max_possible_runs = std.math.mul(u32, out.smoke_runs_per_round, out.smoke_max_rounds) catch return error.InvalidRequiredConsecutivePasses;
                    if (out.smoke_required_consecutive_passes > max_possible_runs) return error.InvalidRequiredConsecutivePasses;
                }
            },
            .status, .stop => {
                if (out.lane_id == null) return error.MissingLaneId;
            },
        },
        .receipt => {
            if (out.receipt_paths.len == 0 and out.receipt_globs.len == 0) return error.MissingReceiptInput;
        },
        .lock => {
            _ = out.lock_action orelse return error.MissingLockAction;
            if (out.receipt_paths.len == 0 and out.receipt_globs.len == 0) return error.MissingLockInput;
        },
    }

    if (!out.timeout_ms_explicit) out.timeout_ms = defaultTimeoutMsForAction(out);
    return out;
}

const ReviewThreadIdSelectorHint =
    "pass the bare reviewThreadId; do not pass .json, .events.ndjson, .parent.events.ndjson, .lane.json, or paths. Use --latest for the newest persisted status/wait session.";

fn usageDetailForParseError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidReviewThreadId => ReviewThreadIdSelectorHint,
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
        ".lane.json",
        ".json",
    };
    for (artifact_suffixes) |suffix| {
        if (std.mem.endsWith(u8, value, suffix)) return error.InvalidReviewThreadId;
    }
}

fn setTarget(parsed: *ParsedArgs, target: TargetConfig) void {
    var next = target;
    if (parsed.target) |current| next.instructions = current.instructions;
    parsed.target = next;
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

fn validateCommaSeparatedNonNegativeU32(raw: []const u8) !void {
    if (raw.len == 0) return error.InvalidSmokeDelaySchedule;
    var iter = std.mem.splitScalar(u8, raw, ',');
    var count: usize = 0;
    while (iter.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) return error.InvalidSmokeDelaySchedule;
        _ = try std.fmt.parseInt(u32, part, 10);
        count += 1;
    }
    if (count == 0) return error.InvalidSmokeDelaySchedule;
}

fn validateSmokeHookPolicies(raw: []const u8) !void {
    if (raw.len == 0) return error.InvalidHooksPolicy;
    var iter = std.mem.splitScalar(u8, raw, ',');
    var count: usize = 0;
    while (iter.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) return error.InvalidHooksPolicy;
        _ = cas.hooks.HookPolicy.parse(part) orelse return error.InvalidHooksPolicy;
        count += 1;
    }
    if (count == 0) return error.InvalidHooksPolicy;
}

fn cmdRun(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var broker_parsed = parsed;
    broker_parsed.wait_after_start = true;
    broker_parsed.json = true;
    try cmdStart(allocator, io, broker_parsed);
}

fn currentAccountPrincipalAlloc(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs, cwd: []const u8) !AccountPrincipalEvidence {
    const resolved_codex_path = cas.resolveExecutableAlloc(allocator, "codex") catch return .{
        .fingerprint = try allocator.dupe(u8, unknown_account_fingerprint),
        .reduced_protection = true,
    };
    defer allocator.free(resolved_codex_path);
    var client = cas.Client.start(allocator, .{
        .cwd = cwd,
        .io = io,
        .codex_path = resolved_codex_path,
        .client_name = "cas-review-session",
        .client_title = "CAS Review Session",
        .client_version = Version,
        .read_only = true,
        .hook_policy = parsed.hook_policy,
    }) catch return .{
        .fingerprint = try allocator.dupe(u8, unknown_account_fingerprint),
        .reduced_protection = true,
    };
    defer {
        client.close();
        client.deinit();
    }
    return readAccountPrincipalAlloc(allocator, &client) catch .{
        .fingerprint = try allocator.dupe(u8, unknown_account_fingerprint),
        .reduced_protection = true,
    };
}

const ReviewCurrentIdentity = struct {
    cwd: []const u8,
    identity: TargetIdentity,
    resolved_codex_path: []const u8,
    resolved_codex_version: []const u8,
    account_fingerprint: []const u8,
    account_fingerprint_reduced_protection: bool,
    codex_thread_id: []const u8,

    fn deinit(self: ReviewCurrentIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        self.identity.deinit(allocator);
        allocator.free(self.resolved_codex_path);
        allocator.free(self.resolved_codex_version);
        allocator.free(self.account_fingerprint);
        allocator.free(self.codex_thread_id);
    }
};

fn reviewCurrentIdentityAlloc(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !ReviewCurrentIdentity {
    const cwd = try repoRealpathAlloc(allocator, parsed.cwd.?);
    errdefer allocator.free(cwd);
    const identity = try computeTargetIdentityAlloc(allocator, io, cwd, targetToRecord(parsed.target.?));
    errdefer identity.deinit(allocator);
    const resolved_codex_path = try cas.resolveExecutableAlloc(allocator, "codex");
    errdefer allocator.free(resolved_codex_path);
    const resolved_codex_version = readCodexVersionAlloc(allocator, io, cwd, resolved_codex_path) catch try allocator.dupe(u8, "unknown");
    errdefer allocator.free(resolved_codex_version);
    const account_principal = try currentAccountPrincipalAlloc(allocator, io, parsed, cwd);
    errdefer account_principal.deinit(allocator);
    const codex_thread_id = try currentCodexThreadIdAlloc(allocator);
    errdefer allocator.free(codex_thread_id);
    return .{
        .cwd = cwd,
        .identity = identity,
        .resolved_codex_path = resolved_codex_path,
        .resolved_codex_version = resolved_codex_version,
        .account_fingerprint = account_principal.fingerprint,
        .account_fingerprint_reduced_protection = account_principal.reduced_protection,
        .codex_thread_id = codex_thread_id,
    };
}

fn writeCasRerRecordsArray(writer: *std.Io.Writer, records: []const CasRerLedgerRecord) !void {
    try writer.writeByte('[');
    for (records, 0..) |record, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll(record.raw_json);
    }
    try writer.writeByte(']');
}

fn writeCasRerRecordRefsArray(writer: *std.Io.Writer, records: []const CasRerLedgerRecord) !void {
    try writer.writeByte('[');
    for (records, 0..) |record, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"recordId\":");
        try writeJsonString(writer, record.record_id);
        try writer.writeAll(",\"recordPath\":");
        try writeJsonString(writer, record.path);
        try writer.writeAll(",\"contextIdentityMatches\":");
        try writer.writeAll(if (record.context_identity_matches) "true" else "false");
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeCasReviewCurrentEnvelope(writer: *std.Io.Writer, records: []const CasRerLedgerRecord) !void {
    try writer.writeAll("{\"schema\":\"CAS-CURRENT-v2\",\"recordPath\":");
    if (latestCasRerLedgerRecordIndex(records)) |idx| {
        try writeJsonString(writer, records[idx].path);
        try writer.writeAll(",\"record\":");
        try writer.writeAll(records[idx].raw_json);
        try writer.writeAll(",\"tupleCurrent\":true,\"contextIdentityMatches\":");
        try writer.writeAll(if (records[idx].context_identity_matches) "true" else "false");
    } else {
        try writer.writeAll("null,\"record\":null,\"tupleCurrent\":false,\"contextIdentityMatches\":false");
    }
    try writer.writeByte('}');
}

fn writeCasReviewListEnvelope(writer: *std.Io.Writer, records: []const CasRerLedgerRecord) !void {
    try writer.writeAll("{\"schema\":\"CAS-LIST-v2\",\"records\":");
    try writeCasRerRecordsArray(writer, records);
    try writer.writeAll(",\"recordRefs\":");
    try writeCasRerRecordRefsArray(writer, records);
    try writer.writeByte('}');
}

fn cmdReviewCurrent(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var loaded_workflow_binding = try loadWorkflowBindingAlloc(allocator, parsed.workflow_binding_arg);
    defer if (loaded_workflow_binding) |*binding| binding.deinit();
    const workflow_binding_filter = if (loaded_workflow_binding) |binding| binding.value else null;
    var resolved = try reviewCurrentIdentityAlloc(allocator, io, parsed);
    defer resolved.deinit(allocator);

    var records: std.ArrayList(CasRerLedgerRecord) = .empty;
    defer {
        for (records.items) |record| record.deinit(allocator);
        records.deinit(allocator);
    }
    try appendCasRerLedgerRecordsAlloc(allocator, &records, resolved.cwd, resolved.identity, resolved.resolved_codex_path, resolved.resolved_codex_version, resolved.account_fingerprint, resolved.account_fingerprint_reduced_protection, resolved.codex_thread_id, workflow_binding_filter);
    std.mem.sort(CasRerLedgerRecord, records.items, {}, casRerRecordLessThan);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try writeCasReviewCurrentEnvelope(stdout, records.items);
    try stdout.writeByte('\n');
}

fn cmdReviewList(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var loaded_workflow_binding = try loadWorkflowBindingAlloc(allocator, parsed.workflow_binding_arg);
    defer if (loaded_workflow_binding) |*binding| binding.deinit();
    const workflow_binding_filter = if (loaded_workflow_binding) |binding| binding.value else null;
    var resolved = try reviewCurrentIdentityAlloc(allocator, io, parsed);
    defer resolved.deinit(allocator);

    var records: std.ArrayList(CasRerLedgerRecord) = .empty;
    defer {
        for (records.items) |record| record.deinit(allocator);
        records.deinit(allocator);
    }
    try appendCasRerLedgerRecordsAlloc(allocator, &records, resolved.cwd, resolved.identity, resolved.resolved_codex_path, resolved.resolved_codex_version, resolved.account_fingerprint, resolved.account_fingerprint_reduced_protection, resolved.codex_thread_id, workflow_binding_filter);
    std.mem.sort(CasRerLedgerRecord, records.items, {}, casRerRecordLessThan);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try writeCasReviewListEnvelope(stdout, records.items);
    try stdout.writeByte('\n');
}

fn cmdReviewInspect(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    var paths = try collectInputPathsAlloc(allocator, parsed.receipt_paths, parsed.receipt_globs);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"schema\":\"CAS-INSPECT-v1\",\"surface\":\"inspect\",\"diagnosticOnly\":true");
    try stdout.writeAll(",\"allowReducedPrincipal\":");
    try stdout.writeAll(if (parsed.allow_reduced_principal) "true" else "false");
    try stdout.writeAll(",\"allowNativeFallback\":");
    try stdout.writeAll(if (parsed.allow_native_fallback) "true" else "false");
    try stdout.writeAll(",\"records\":[");
    for (paths.items, 0..) |path, i| {
        if (i > 0) try stdout.writeByte(',');
        const validation = try validateCasRerRecordPathAlloc(allocator, path);
        defer validation.deinit(allocator);
        try writeInspectRecordObject(allocator, stdout, path, validation, parsed.show_attachments);
    }
    try stdout.writeAll("]}\n");
}

fn writeInspectRecordObject(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    path: []const u8,
    validation: GateResult,
    show_attachments: bool,
) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "recordPath");
    try writer.writeByte(':');
    try writeJsonString(writer, path);
    try writer.writeByte(',');
    try writeJsonString(writer, "validation");
    try writer.writeByte(':');
    try writeGateResultJson(writer, validation);
    if (show_attachments) {
        const raw = readFileAlloc(allocator, path, 8 * 1024 * 1024) catch null;
        if (raw) |record_json| {
            defer allocator.free(record_json);
            var parsed_record = std.json.parseFromSlice(std.json.Value, allocator, record_json, .{}) catch null;
            if (parsed_record) |*parsed| {
                defer parsed.deinit();
                try writer.writeByte(',');
                try writeJsonString(writer, "record");
                try writer.writeByte(':');
                try writer.writeAll(record_json);
            } else {
                try writer.writeByte(',');
                try writeJsonString(writer, "recordRaw");
                try writer.writeByte(':');
                try writeJsonString(writer, record_json);
            }
        }
    }
    try writer.writeByte('}');
}

fn cmdStart(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    const action_name = if (parsed.action != null and parsed.action.? == .run) "run" else "start";
    var loaded_workflow_binding = try loadWorkflowBindingAlloc(allocator, parsed.workflow_binding_arg);
    defer if (loaded_workflow_binding) |*binding| binding.deinit();
    const workflow_binding = if (loaded_workflow_binding) |binding| binding.value else null;
    const cwd = try repoRealpathAlloc(allocator, parsed.cwd.?);
    defer allocator.free(cwd);
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
    defer allocator.free(resolved_codex_path);
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
    defer managed_server.deinit(allocator);
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

    const session_dir = try sessionDirAlloc(allocator);
    defer allocator.free(session_dir);
    const target = parsed.target.?;
    const target_record = targetToRecord(target);
    var identity = try computeTargetIdentityAlloc(allocator, io, cwd, target_record);
    defer identity.deinit(allocator);
    var review_tuple = try reviewTupleIdentityAlloc(allocator, cwd, identity, resolved_codex_path, codex_version, &client, workflow_binding);
    defer review_tuple.deinit(allocator);
    output_receipt.account_fingerprint = review_tuple.account_fingerprint;
    output_receipt.account_fingerprint_reduced_protection = review_tuple.account_fingerprint_reduced_protection;
    output_receipt.codex_thread_id = review_tuple.codex_thread_id;
    const tuple_lock_bundle = try acquireReviewTupleStartLockOrExit(
        allocator,
        parsed.json,
        action_name,
        identity,
        review_tuple,
        parsed.review_lock_override_reason,
        parsed.fresh_attempt_reason,
        false,
        &managed_server,
    );
    defer tuple_lock_bundle.deinit(allocator);
    const created_parent_thread = parsed.parent_thread_id == null;
    const parent_thread_id = if (parsed.parent_thread_id) |existing| blk: {
        const existing_parent_event_log_path = try parentEventLogPathAlloc(allocator, session_dir, existing);
        defer allocator.free(existing_parent_event_log_path);
        try resumeParentThread(allocator, &client, existing, existing_parent_event_log_path);
        var parent_status = try fetchReviewStatus(allocator, &client, existing, existing_parent_event_log_path, null);
        defer parent_status.deinit(allocator);
        if (failureInfoForParentReuse(&parent_status)) |failure| {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", failure.code, null, null, null, existing_parent_event_log_path);
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
    } else startParentThreadAlloc(allocator, &client, cwd, session_dir, parsed.multi_agent_mode) catch |err| {
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "review_failed", null, null, null, null);
        return err;
    };
    defer allocator.free(parent_thread_id);
    applyMultiAgentModeReceipt(&output_receipt, parsed.multi_agent_mode, if (created_parent_thread) .proven else .unproven);
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
            parsed.multi_agent_mode,
        ) catch {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "parent_materialization_failed", null, null, null, parent_event_log_path);
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
                parsed.multi_agent_mode,
            ) catch {
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "parent_materialization_failed", null, null, null, parent_event_log_path);
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
                const failure_for_lock: FailureInfo = retry_failure orelse .{
                    .code = "review_failed",
                    .hint = "detached review startup failed after fresh-parent materialization retry",
                };
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, if (std.mem.eql(u8, failure_for_lock.code, "account_resource_exhausted")) "account_resource_exhausted" else "pre_review_start_failed", failure_for_lock.code, null, null, null, parent_event_log_path);
                try maybeRunNativeFallbackAndExitStart(
                    allocator,
                    parsed,
                    cwd,
                    resolved_codex_path,
                    parent_thread_id,
                    null,
                    null,
                    target_record,
                    identity,
                    "",
                    parent_event_log_path,
                    .{
                        .surface_action = action_name,
                        .resolved_codex_path = resolved_codex_path,
                        .resolved_codex_version = codex_version,
                        .compatibility_verdict = if (retry_failure != null) "incompatible" else "not_checked",
                    },
                    null,
                    false,
                    false,
                    failure_for_lock,
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
                    failure_for_lock,
                );
            };
        }

        const message = if (failure) |value| value.hint else raw_message;
        const failure_for_lock: FailureInfo = failure orelse .{
            .code = "review_failed",
            .hint = "detached review startup failed after app-server launch",
        };
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, if (std.mem.eql(u8, failure_for_lock.code, "account_resource_exhausted")) "account_resource_exhausted" else "pre_review_start_failed", failure_for_lock.code, null, null, null, parent_event_log_path);
        try maybeRunNativeFallbackAndExitStart(
            allocator,
            parsed,
            cwd,
            resolved_codex_path,
            parent_thread_id,
            null,
            null,
            target_record,
            identity,
            "",
            parent_event_log_path,
            .{
                .surface_action = action_name,
                .resolved_codex_path = resolved_codex_path,
                .resolved_codex_version = codex_version,
                .compatibility_verdict = if (failure != null) "incompatible" else "not_checked",
            },
            null,
            false,
            false,
            failure_for_lock,
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
            failure_for_lock,
        );
    };
    defer allocator.free(review_result_json);

    const review_thread_id = try extractReviewThreadIdAlloc(allocator, review_result_json);
    defer allocator.free(review_thread_id);
    const review_turn_id = try extractReviewTurnIdAlloc(allocator, review_result_json);
    defer allocator.free(review_turn_id);
    const event_log_path = try std.fmt.allocPrint(allocator, "{s}/{s}.events.ndjson", .{ session_dir, review_thread_id });
    defer allocator.free(event_log_path);
    const record_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, review_thread_id });
    defer allocator.free(record_path);

    try appendLogRecord(allocator, event_log_path, "review/start", "request", review_params_json);
    try appendLogRecord(allocator, event_log_path, "review/start", "response", review_result_json);
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
    try writeSessionRecord(allocator, record_path, record);
    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "review_started", null, review_thread_id, review_turn_id, record_path, event_log_path);

    if (parsed.wait_after_start) {
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", null, review_thread_id, review_turn_id, record_path, event_log_path);
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
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", "wait_timed_out", review_thread_id, review_turn_id, record_path, event_log_path);
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
            else => {
                if (isTransportLossError(err) and parsed.json) {
                    var disconnected_status = try makeDisconnectedReviewStatus(allocator);
                    defer disconnected_status.deinit(allocator);
                    record.last_observed_status = "inProgress";
                    try writeSessionRecord(allocator, record_path, record);
                    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", "review_transport_lost", review_thread_id, review_turn_id, record_path, event_log_path);
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
                        .{
                            .code = "review_transport_lost",
                            .hint = "managed websocket review transport was lost while waiting; retry cas review_session wait on the same reviewThreadId",
                        },
                        null,
                    );
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
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, if (std.mem.eql(u8, failure.code, "account_resource_exhausted")) "account_resource_exhausted" else "terminal", failure.code, review_thread_id, review_turn_id, record_path, event_log_path);
            } else {
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "terminal", "review_output_missing", review_thread_id, review_turn_id, record_path, event_log_path);
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
        const terminal_binding_failure = terminalBindingFailureForIdentity(allocator, latest, identity);
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
        if (terminal_binding_failure != null) std.process.exit(1);
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
    var loaded = try loadSelectedSessionRecord(allocator, parsed);
    defer loaded.deinit(allocator);
    const record = loaded.record;
    const identity_opt: ?TargetIdentity = targetIdentityForRecordAlloc(allocator, io, record) catch null;
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
                withRecordMultiAgentMode(.{
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
                }, record),
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
        if (isTransportLossError(err) and parsed.json) {
            try printDisconnectedReviewTransportJson(
                allocator,
                .status,
                record,
                loaded.record_path,
                identity_opt,
                null,
            );
            std.process.exit(1);
        }
        return err;
    };
    defer {
        client.close();
        client.deinit();
    }

    var status = try fetchReviewStatus(allocator, &client, record.review_thread_id, record.event_log_path, null);
    defer status.deinit(allocator);
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
            withRecordMultiAgentMode(.{
                .resolved_codex_path = record.resolved_codex_path,
                .resolved_codex_version = record.codex_version,
                .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                .selected_transport = record.transport_kind orelse "stdio",
                .selection_reason = record.transport_selection_reason orelse "legacy_record",
                .managed_server_pid = record.managed_server_pid,
                .managed_server_listen_url = record.managed_server_listen_url,
                .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                .orphan_ttl_seconds = record.orphan_ttl_seconds,
            }, record),
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
    var loaded = try loadSelectedSessionRecord(allocator, parsed);
    defer loaded.deinit(allocator);
    var record = loaded.record;
    const identity_opt: ?TargetIdentity = targetIdentityForRecordAlloc(allocator, io, record) catch null;
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
                withRecordMultiAgentMode(.{
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
                }, record),
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
        if (isTransportLossError(err) and parsed.json) {
            updateReviewTupleLockByReviewThreadIdBestEffort(
                allocator,
                record,
                loaded.record_path,
                "waiting",
                "review_transport_lost",
            );
            try printDisconnectedReviewTransportJson(
                allocator,
                .wait,
                record,
                loaded.record_path,
                identity_opt,
                null,
            );
            std.process.exit(1);
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
            updateReviewTupleLockForRecordBestEffort(
                allocator,
                record,
                loaded.record_path,
                identity_opt,
                &client,
                "waiting",
                "wait_timed_out",
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
                    identity_opt,
                    withRecordMultiAgentMode(.{
                        .resolved_codex_path = record.resolved_codex_path,
                        .resolved_codex_version = record.codex_version,
                        .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                        .selected_transport = record.transport_kind orelse "stdio",
                        .selection_reason = record.transport_selection_reason orelse "legacy_record",
                        .managed_server_pid = record.managed_server_pid,
                        .managed_server_listen_url = record.managed_server_listen_url,
                        .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                        .orphan_ttl_seconds = record.orphan_ttl_seconds,
                    }, record),
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
            if (isTransportLossError(err) and parsed.json) {
                updateReviewTupleLockForRecordBestEffort(
                    allocator,
                    record,
                    loaded.record_path,
                    identity_opt,
                    &client,
                    "waiting",
                    "review_transport_lost",
                );
                try printDisconnectedReviewTransportJson(
                    allocator,
                    .wait,
                    record,
                    loaded.record_path,
                    identity_opt,
                    null,
                );
                std.process.exit(1);
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
        updateReviewTupleLockForRecordBestEffort(
            allocator,
            record,
            loaded.record_path,
            identity_opt,
            &client,
            if (std.mem.eql(u8, failure_for_lock.code, "account_resource_exhausted")) "account_resource_exhausted" else "terminal",
            failure_for_lock.code,
        );
        try maybeRunNativeFallbackAndExitWait(
            allocator,
            parsed,
            &record,
            loaded.record_path,
            latest,
            failure_for_lock,
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
                identity_opt,
                withRecordMultiAgentMode(.{
                    .resolved_codex_path = record.resolved_codex_path,
                    .resolved_codex_version = record.codex_version,
                    .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                    .selected_transport = record.transport_kind orelse "stdio",
                    .selection_reason = record.transport_selection_reason orelse "legacy_record",
                    .managed_server_pid = record.managed_server_pid,
                    .managed_server_listen_url = record.managed_server_listen_url,
                    .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                    .orphan_ttl_seconds = record.orphan_ttl_seconds,
                }, record),
                null,
                false,
                failure_for_lock,
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
    const terminal_lock_failure = terminalBindingFailureForOptionalIdentity(allocator, latest, identity_opt);
    updateReviewTupleLockForRecordBestEffort(
        allocator,
        record,
        loaded.record_path,
        identity_opt,
        &client,
        if (terminal_lock_failure == null) "normalized" else "terminal",
        if (terminal_lock_failure) |failure| failure.code else null,
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
            identity_opt,
            withRecordMultiAgentMode(.{
                .resolved_codex_path = record.resolved_codex_path,
                .resolved_codex_version = record.codex_version,
                .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
                .selected_transport = record.transport_kind orelse "stdio",
                .selection_reason = record.transport_selection_reason orelse "legacy_record",
                .managed_server_pid = record.managed_server_pid,
                .managed_server_listen_url = record.managed_server_listen_url,
                .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
                .orphan_ttl_seconds = record.orphan_ttl_seconds,
            }, record),
            null,
            false,
            terminal_lock_failure,
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
    if (terminal_lock_failure != null) std.process.exit(1);
}

fn cmdInterrupt(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var loaded = try loadSelectedSessionRecord(allocator, parsed);
    defer loaded.deinit(allocator);
    var record = loaded.record;
    const identity_opt: ?TargetIdentity = targetIdentityForRecordAlloc(allocator, io, record) catch null;
    defer if (identity_opt) |identity| identity.deinit(allocator);

    if (record.terminal_fallback_transport != null) {
        if (parsed.json) {
            const payload = .{
                .demo = "cas-review-session",
                .action = "interrupt",
                .reviewAttemptPhase = "review_terminal",
                .reviewAttemptExists = true,
                .tupleVerdictExists = false,
                .reviewThreadId = record.review_thread_id,
                .reviewTurnId = record.review_turn_id,
                .baseSha = if (identity_opt) |identity| identity.base_sha else null,
                .headSha = if (identity_opt) |identity| identity.head_sha else null,
                .targetFingerprint = if (identity_opt) |identity| identity.fingerprint else null,
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
    defer latest.deinit(allocator);
    if (isTerminalTurnStatus(latest.turn_status)) {
        record.last_observed_status = latest.turn_status;
        try writeSessionRecord(allocator, loaded.record_path, record);
        if (parsed.json) {
            const payload = .{
                .demo = "cas-review-session",
                .action = "interrupt",
                .reviewAttemptPhase = "review_terminal",
                .reviewAttemptExists = true,
                .tupleVerdictExists = false,
                .reviewThreadId = record.review_thread_id,
                .reviewTurnId = record.review_turn_id,
                .baseSha = if (identity_opt) |identity| identity.base_sha else null,
                .headSha = if (identity_opt) |identity| identity.head_sha else null,
                .targetFingerprint = if (identity_opt) |identity| identity.fingerprint else null,
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
            .reviewAttemptPhase = "review_waiting",
            .reviewAttemptExists = true,
            .tupleVerdictExists = false,
            .reviewThreadId = record.review_thread_id,
            .reviewTurnId = record.review_turn_id,
            .baseSha = if (identity_opt) |identity| identity.base_sha else null,
            .headSha = if (identity_opt) |identity| identity.head_sha else null,
            .targetFingerprint = if (identity_opt) |identity| identity.fingerprint else null,
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
    review_attempt_phase: []const u8,
    review_attempt_exists: bool,
    tuple_verdict_exists: bool,
    principal_strength: []const u8 = principal_strength_reduced,
    account_fingerprint_reduced_protection: bool = true,
    base_sha: ?[]const u8,
    head_sha: ?[]const u8,
    target_fingerprint: ?[]const u8,
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
    pre_review_transport_failure: usize = 0,
    account_resource_exhausted: usize = 0,
    parse_mismatch: usize = 0,
    review_transport_failure: usize = 0,
    incomplete: usize = 0,
    other_status: usize = 0,
    cas_lane: usize = 0,
    cas_native_fallback: usize = 0,
    other_backend: usize = 0,
};

const ReceiptEventLogRecoveryMaxInputs = 64;

fn cmdReceipt(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    switch (parsed.receipt_action) {
        .normalize => try cmdReceiptNormalize(allocator, io, parsed),
        .classify => try cmdReceiptClassify(allocator, parsed),
        .gate => try cmdReceiptGate(allocator, parsed),
    }
}

fn collectInputPathsAlloc(allocator: std.mem.Allocator, paths_raw: []const []const u8, globs: []const []const u8) !std.ArrayList([]const u8) {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    for (paths_raw) |path| {
        try paths.append(allocator, try allocator.dupe(u8, path));
    }
    for (globs) |pattern| {
        try expandReceiptGlob(allocator, pattern, &paths);
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanString);
    return paths;
}

const ImportedCasRerRecord = struct {
    source_path: []const u8,
    record_path: []const u8,
    record_json: []const u8,
    validation: GateResult,

    fn deinit(self: ImportedCasRerRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.record_path);
        allocator.free(self.record_json);
        self.validation.deinit(allocator);
    }
};

fn isCasRerObject(obj: std.json.ObjectMap) bool {
    return std.mem.eql(u8, jsonStringField(obj, "schema") orelse "", cas_review_evidence_schema);
}

fn importRecordEnvelopeValidationOk(obj: std.json.ObjectMap) bool {
    const validation = objectField(obj, "validation") orelse return true;
    if (jsonBoolField(validation, "ok")) |ok| return ok;
    if (validation.get("errors")) |errors| switch (errors) {
        .array => |array| return array.items.len == 0,
        else => return false,
    };
    return false;
}

fn nestedCasRerObjectImportable(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !bool {
    if (!isCasRerObject(obj)) return false;
    var validation = try validateCasRerRecordObjectAlloc(allocator, "<nested CAS-RER>", obj);
    defer validation.deinit(allocator);
    return validation.ok();
}

fn collectNestedCasRerRecordsAlloc(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), root: std.json.ObjectMap) !bool {
    if (isCasRerObject(root)) {
        try out.append(allocator, try stringifyJsonValueAlloc(allocator, .{ .object = root }));
        return true;
    }

    var found = false;
    if (objectField(root, "record")) |record| {
        if (try nestedCasRerObjectImportable(allocator, record)) {
            try out.append(allocator, try stringifyJsonValueAlloc(allocator, .{ .object = record }));
            found = true;
        }
    }
    if (root.get("records")) |records_value| switch (records_value) {
        .array => |records| {
            for (records.items) |item| {
                const item_obj = switch (item) {
                    .object => |value| value,
                    else => continue,
                };
                if (!importRecordEnvelopeValidationOk(item_obj)) continue;
                const record = if (try nestedCasRerObjectImportable(allocator, item_obj))
                    item_obj
                else
                    objectField(item_obj, "record") orelse continue;
                if (!(try nestedCasRerObjectImportable(allocator, record))) continue;
                try out.append(allocator, try stringifyJsonValueAlloc(allocator, .{ .object = record }));
                found = true;
            }
        },
        else => {},
    };
    return found;
}

fn collectNestedCasRerRecordsFromJsonLinesAlloc(allocator: std.mem.Allocator, out: *std.ArrayList([]u8), raw: []const u8) !bool {
    var found = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var parsed_line = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed_line.deinit();
        const root = switch (parsed_line.value) {
            .object => |value| value,
            else => continue,
        };
        if (try collectNestedCasRerRecordsAlloc(allocator, out, root)) found = true;
    }
    return found;
}

fn appendImportedCasRerRecordJsonAlloc(
    allocator: std.mem.Allocator,
    imported: *std.ArrayList(ImportedCasRerRecord),
    source_path_raw: []const u8,
    record_json: []u8,
    requested_identity: ?ReviewCurrentIdentity,
) !void {
    errdefer allocator.free(record_json);
    var parsed_record = try std.json.parseFromSlice(std.json.Value, allocator, record_json, .{});
    defer parsed_record.deinit();

    const record_obj = switch (parsed_record.value) {
        .object => |value| value,
        else => return error.InvalidCasRerRecord,
    };

    var validation = try validateCasRerRecordObjectAlloc(allocator, source_path_raw, record_obj);
    errdefer validation.deinit(allocator);
    if (validation.ok()) {
        if (requested_identity) |identity| {
            if (!casRerObjectMatchesIdentity(
                record_obj,
                identity.cwd,
                identity.identity,
                identity.resolved_codex_path,
                identity.resolved_codex_version,
                identity.account_fingerprint,
                identity.account_fingerprint_reduced_protection,
                identity.codex_thread_id,
            )) {
                validation.deinit(allocator);
                validation = try gateResultFromSingleErrorAlloc(
                    allocator,
                    source_path_raw,
                    "CAS-RER record does not match requested import identity",
                );
            }
        }
    }
    const record_path = if (validation.ok())
        try writeCasRerRecordJsonToLedgerAlloc(allocator, record_json)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(record_path);
    const source_path = try allocator.dupe(u8, source_path_raw);
    errdefer allocator.free(source_path);
    try imported.append(allocator, .{
        .source_path = source_path,
        .record_path = record_path,
        .record_json = record_json,
        .validation = validation,
    });
}

fn appendCollectedNestedCasRerRecordsAlloc(
    allocator: std.mem.Allocator,
    imported: *std.ArrayList(ImportedCasRerRecord),
    errors: *std.ArrayList(ReceiptError),
    source_path: []const u8,
    nested_records: *std.ArrayList([]u8),
    requested_identity: ?ReviewCurrentIdentity,
) !void {
    for (nested_records.items) |*record_json_ref| {
        const record_json = record_json_ref.*;
        record_json_ref.* = "";
        appendImportedCasRerRecordJsonAlloc(allocator, imported, source_path, record_json, requested_identity) catch |err| {
            try errors.append(allocator, .{
                .source_path = try allocator.dupe(u8, source_path),
                .message = try allocator.dupe(u8, @errorName(err)),
            });
        };
    }
}

fn reviewImportShouldSkipNormalizeError(from_glob: bool, err: anyerror) bool {
    return from_glob and err == error.NotReviewReceipt;
}

fn cmdReviewImport(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var paths = try collectInputPathsAlloc(allocator, parsed.receipt_paths, parsed.receipt_globs);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    var imported: std.ArrayList(ImportedCasRerRecord) = .empty;
    defer {
        for (imported.items) |record| record.deinit(allocator);
        imported.deinit(allocator);
    }
    var errors: std.ArrayList(ReceiptError) = .empty;
    defer {
        for (errors.items) |err| err.deinit(allocator);
        errors.deinit(allocator);
    }

    var requested_current_opt: ?ReviewCurrentIdentity = null;
    defer if (requested_current_opt) |identity| identity.deinit(allocator);
    const requested_identity_required = parsed.cwd != null and parsed.target != null;
    if (requested_identity_required) {
        requested_current_opt = reviewCurrentIdentityAlloc(allocator, io, parsed) catch |err| {
            try errors.append(allocator, .{
                .source_path = try allocator.dupe(u8, parsed.cwd.?),
                .message = try std.fmt.allocPrint(allocator, "target identity unavailable: {s}", .{@errorName(err)}),
            });
            try printReviewImportResults(imported.items, errors.items, if (parsed.json) .json else parsed.receipt_format);
            std.process.exit(1);
        };
    }
    const normalize_context = NormalizeContext{
        .requested_identity = if (requested_current_opt) |identity| identity.identity else null,
        .requested_identity_required = requested_identity_required,
    };
    const standalone_import_repo_realpath = if (requested_current_opt == null and parsed.cwd != null) try repoRealpathAlloc(allocator, parsed.cwd.?) else null;
    defer if (standalone_import_repo_realpath) |value| allocator.free(value);
    const import_repo_realpath = if (requested_current_opt) |identity| identity.cwd else standalone_import_repo_realpath;

    if (paths.items.len == 0) {
        try errors.append(allocator, .{
            .source_path = try allocator.dupe(u8, "<input>"),
            .message = try allocator.dupe(u8, "no files matched"),
        });
        try printReviewImportResults(imported.items, errors.items, if (parsed.json) .json else parsed.receipt_format);
        std.process.exit(1);
    }

    const recover_event_logs = paths.items.len <= ReceiptEventLogRecoveryMaxInputs;
    const skip_non_receipts = parsed.receipt_globs.len > 0;
    for (paths.items) |path| {
        const raw = readFileAlloc(allocator, path, 8 * 1024 * 1024) catch |err| {
            try errors.append(allocator, .{
                .source_path = try allocator.dupe(u8, path),
                .message = try allocator.dupe(u8, @errorName(err)),
            });
            continue;
        };
        defer allocator.free(raw);

        var maybe_parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch null;
        if (maybe_parsed) |*parsed_value| {
            defer parsed_value.deinit();
            if (parsed_value.value == .object) {
                var nested_records: std.ArrayList([]u8) = .empty;
                defer {
                    for (nested_records.items) |record_json| {
                        if (record_json.len != 0) allocator.free(record_json);
                    }
                    nested_records.deinit(allocator);
                }
                const found_nested = collectNestedCasRerRecordsAlloc(allocator, &nested_records, parsed_value.value.object) catch |err| {
                    try errors.append(allocator, .{
                        .source_path = try allocator.dupe(u8, path),
                        .message = try allocator.dupe(u8, @errorName(err)),
                    });
                    continue;
                };
                if (found_nested) {
                    try appendCollectedNestedCasRerRecordsAlloc(allocator, &imported, &errors, path, &nested_records, requested_current_opt);
                    continue;
                }
            }
        }

        {
            var nested_records: std.ArrayList([]u8) = .empty;
            defer {
                for (nested_records.items) |record_json| {
                    if (record_json.len != 0) allocator.free(record_json);
                }
                nested_records.deinit(allocator);
            }
            const found_nested = collectNestedCasRerRecordsFromJsonLinesAlloc(allocator, &nested_records, raw) catch |err| {
                try errors.append(allocator, .{
                    .source_path = try allocator.dupe(u8, path),
                    .message = try allocator.dupe(u8, @errorName(err)),
                });
                continue;
            };
            if (found_nested) {
                try appendCollectedNestedCasRerRecordsAlloc(allocator, &imported, &errors, path, &nested_records, requested_current_opt);
                continue;
            }
        }

        const receipt = normalizeReceiptFromJsonAlloc(allocator, path, raw, recover_event_logs, normalize_context) catch |err| {
            if (reviewImportShouldSkipNormalizeError(skip_non_receipts, err)) continue;
            try errors.append(allocator, .{
                .source_path = try allocator.dupe(u8, path),
                .message = try allocator.dupe(u8, @errorName(err)),
            });
            continue;
        };
        defer receipt.deinit(allocator);

        const import_timestamp = try casRerTimestampAlloc(allocator);
        defer allocator.free(import_timestamp);
        const record_json = casRerJsonFromReceiptAlloc(allocator, receipt, .{
            .repo_realpath_override = import_repo_realpath,
            .resolved_codex_path_override = if (requested_current_opt) |identity| identity.resolved_codex_path else null,
            .resolved_codex_version_override = if (requested_current_opt) |identity| identity.resolved_codex_version else null,
            .account_fingerprint_override = if (requested_current_opt) |identity| identity.account_fingerprint else null,
            .tuple_current_at_record_time = if (requested_current_opt) |identity| receiptTupleMatchesIdentity(receipt, identity.identity) else false,
            .created_at = import_timestamp,
            .updated_at = import_timestamp,
        }) catch |err| {
            try errors.append(allocator, .{
                .source_path = try allocator.dupe(u8, path),
                .message = try allocator.dupe(u8, @errorName(err)),
            });
            continue;
        };

        appendImportedCasRerRecordJsonAlloc(allocator, &imported, path, record_json, requested_current_opt) catch |err| {
            try errors.append(allocator, .{
                .source_path = try allocator.dupe(u8, path),
                .message = try allocator.dupe(u8, @errorName(err)),
            });
            continue;
        };
    }

    try printReviewImportResults(imported.items, errors.items, if (parsed.json) .json else parsed.receipt_format);

    var failed = errors.items.len > 0;
    for (imported.items) |record| {
        if (!record.validation.ok()) failed = true;
    }
    if (failed) std.process.exit(1);
}

fn cmdValidateRecord(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    var paths = try collectInputPathsAlloc(allocator, parsed.receipt_paths, parsed.receipt_globs);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    try runGateCommand(allocator, paths.items, if (parsed.json) .json else parsed.receipt_format, validateCasRerRecordPathAlloc);
}

fn writeReviewImportRecordJson(writer: *std.Io.Writer, record: ImportedCasRerRecord) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "sourcePath");
    try writer.writeByte(':');
    try writeJsonString(writer, record.source_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "recordPath");
    try writer.writeByte(':');
    try writeJsonString(writer, record.record_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "validation");
    try writer.writeByte(':');
    try writeGateResultJson(writer, record.validation);
    try writer.writeByte(',');
    try writeJsonString(writer, "record");
    try writer.writeByte(':');
    try writer.writeAll(record.record_json);
    try writer.writeByte('}');
}

fn printReviewImportResults(records: []const ImportedCasRerRecord, errors: []const ReceiptError, format: ReceiptFormat) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    switch (format) {
        .json => {
            try stdout.writeAll("{\"schema\":\"CAS-IMPORT-v1\",\"records\":[");
            for (records, 0..) |record, i| {
                if (i > 0) try stdout.writeByte(',');
                try writeReviewImportRecordJson(stdout, record);
            }
            try stdout.writeAll("],\"errors\":[");
            for (errors, 0..) |err, i| {
                if (i > 0) try stdout.writeByte(',');
                try writeReceiptErrorObject(stdout, err);
            }
            try stdout.writeAll("]}\n");
        },
        .jsonl => {
            for (records) |record| {
                try writeReviewImportRecordJson(stdout, record);
                try stdout.writeByte('\n');
            }
            for (errors) |err| {
                try writeReceiptErrorObject(stdout, err);
                try stdout.writeByte('\n');
            }
        },
        .table => {
            try stdout.writeAll("sourcePath\trecordPath\tok\n");
            for (records) |record| {
                try stdout.print("{s}\t{s}\t{s}\n", .{
                    record.source_path,
                    record.record_path,
                    if (record.validation.ok()) "true" else "false",
                });
            }
            for (errors) |err| {
                try stdout.print("{s}\t\terror:{s}\n", .{ err.source_path, err.message });
            }
        },
    }
}

fn cmdReceiptNormalize(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var paths = try collectInputPathsAlloc(allocator, parsed.receipt_paths, parsed.receipt_globs);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

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

    var requested_identity_opt: ?TargetIdentity = null;
    defer if (requested_identity_opt) |identity| identity.deinit(allocator);
    const requested_identity_required = parsed.cwd != null and parsed.target != null;
    if (requested_identity_required) {
        const target_record = targetToRecord(parsed.target.?);
        requested_identity_opt = computeTargetIdentityAlloc(allocator, io, parsed.cwd.?, target_record) catch null;
    }
    const normalize_context = NormalizeContext{
        .requested_identity = requested_identity_opt,
        .requested_identity_required = requested_identity_required,
    };

    const recover_event_logs = paths.items.len <= ReceiptEventLogRecoveryMaxInputs;
    const skip_non_receipts = parsed.receipt_globs.len > 0;
    for (paths.items) |path| {
        const receipt = normalizeReceiptFromPathAlloc(allocator, path, recover_event_logs, normalize_context) catch |err| {
            if (skip_non_receipts and err == error.NotReviewReceipt) continue;
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

const ReceiptClassification = struct {
    classification: []const u8,
    failure_class: []const u8,
    failure_code: ?[]const u8,
    review_attempt_phase: []const u8,
    review_attempt_exists: bool,
    tuple_verdict_exists: bool,
    review_thread_id: ?[]const u8,
    retryable_same_tuple_now: bool,

    fn deinit(self: ReceiptClassification, allocator: std.mem.Allocator) void {
        allocator.free(self.classification);
    }
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

fn cmdReceiptClassify(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    var paths = try collectInputPathsAlloc(allocator, parsed.receipt_paths, parsed.receipt_globs);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    var source_index: usize = 0;
    var emitted: usize = 0;
    if (parsed.receipt_format == .json) try stdout.writeByte('[');
    if (parsed.receipt_format == .table) {
        try stdout.writeAll("sourceIndex\tclassification\tfailureClass\tfailureCode\treviewAttemptPhase\treviewAttemptExists\ttupleVerdictExists\treviewThreadId\tretryableSameTupleNow\n");
    }
    for (paths.items) |path| {
        try classifyReceiptFile(allocator, path, parsed.receipt_format, stdout, &source_index, &emitted);
    }
    if (parsed.receipt_format == .json) try stdout.writeAll("]\n");
}

fn classifyReceiptFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    format: ReceiptFormat,
    writer: *std.Io.Writer,
    source_index: *usize,
    emitted: *usize,
) !void {
    const raw = try readFileAlloc(allocator, path, 8 * 1024 * 1024);
    defer allocator.free(raw);
    const stripped = std.mem.trim(u8, raw, " \t\r\n");
    if (stripped.len == 0) return;

    if (std.mem.startsWith(u8, stripped, "[")) {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stripped, .{});
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |value| value,
            else => return,
        };
        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |value| value,
                else => continue,
            };
            try emitClassificationForObject(allocator, obj, format, writer, source_index, emitted);
        }
        return;
    }

    if (std.mem.startsWith(u8, stripped, "{") and std.mem.indexOfScalar(u8, stripped, '\n') == null) {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stripped, .{});
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => return,
        };
        try emitClassificationForObject(allocator, obj, format, writer, source_index, emitted);
        return;
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |value| value,
            else => continue,
        };
        try emitClassificationForObject(allocator, obj, format, writer, source_index, emitted);
    }
}

fn emitClassificationForObject(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    format: ReceiptFormat,
    writer: *std.Io.Writer,
    source_index: *usize,
    emitted: *usize,
) !void {
    const row = try classifyReceiptRecordAlloc(allocator, obj);
    defer row.deinit(allocator);
    switch (format) {
        .json => {
            if (emitted.* > 0) try writer.writeByte(',');
            try writeReceiptClassificationObject(writer, source_index.*, row);
        },
        .jsonl => {
            try writeReceiptClassificationObject(writer, source_index.*, row);
            try writer.writeByte('\n');
        },
        .table => {
            try writer.print("{d}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
                source_index.*,
                row.classification,
                row.failure_class,
                row.failure_code orelse "",
                row.review_attempt_phase,
                if (row.review_attempt_exists) "true" else "false",
                if (row.tuple_verdict_exists) "true" else "false",
                row.review_thread_id orelse "",
                if (row.retryable_same_tuple_now) "true" else "false",
            });
        },
    }
    source_index.* += 1;
    emitted.* += 1;
}

fn classifyReceiptRecordAlloc(allocator: std.mem.Allocator, receipt: std.json.ObjectMap) !ReceiptClassification {
    const verdict = objectField(receipt, "reviewVerdict");
    const failure_code = stringFieldAny(receipt, &.{ "failureCode", "failure_code" }) orelse
        if (verdict) |value| jsonStringField(value, "failureCode") else null;
    const review_thread_id = stringFieldAny(receipt, &.{ "reviewThreadId", "review_thread_id" }) orelse
        if (verdict) |value| jsonStringField(value, "reviewThreadId") else null;
    const review_count = intFieldAny(receipt, &.{ "reviewCount", "review_count" });
    const last_review_thread = stringFieldAny(receipt, &.{ "lastReviewThreadId", "last_review_thread_id" });
    const last_head = stringFieldAny(receipt, &.{ "lastHeadSha", "last_head_sha" });

    if (try receiptContainsUsageLimit(allocator, receipt) or std.mem.eql(u8, failure_code orelse "", "account_resource_exhausted")) {
        return .{
            .classification = try allocator.dupe(u8, "account_resource_exhausted"),
            .failure_class = "account_resource",
            .failure_code = "account_resource_exhausted",
            .review_attempt_phase = if (reviewAttemptExists(review_thread_id)) "review_terminal" else "pre_review_start",
            .review_attempt_exists = reviewAttemptExists(review_thread_id),
            .tuple_verdict_exists = false,
            .review_thread_id = review_thread_id,
            .retryable_same_tuple_now = false,
        };
    }

    if ((std.mem.eql(u8, failure_code orelse "", "pre_review_lane_transport_lost") or
        std.mem.eql(u8, failure_code orelse "", "lane_transport_lost")) and
        (review_count == null or review_count.? == 0) and
        !reviewAttemptExists(review_thread_id) and
        !reviewAttemptExists(last_review_thread) and
        nonEmptyOptional(last_head) == null)
    {
        return .{
            .classification = try allocator.dupe(u8, "pre_review_lane_transport_lost"),
            .failure_class = "transport_pre_review",
            .failure_code = "pre_review_lane_transport_lost",
            .review_attempt_phase = "pre_review_start",
            .review_attempt_exists = false,
            .tuple_verdict_exists = false,
            .review_thread_id = null,
            .retryable_same_tuple_now = true,
        };
    }

    if (verdict) |value| {
        const status = jsonStringField(value, "status") orelse "";
        return .{
            .classification = try std.fmt.allocPrint(allocator, "review_verdict_{s}", .{status}),
            .failure_class = "review_verdict",
            .failure_code = jsonStringField(value, "failureCode"),
            .review_attempt_phase = "normalized_verdict",
            .review_attempt_exists = reviewAttemptExists(jsonStringField(value, "reviewThreadId") orelse review_thread_id),
            .tuple_verdict_exists = reviewVerdictStatusIsTupleTerminal(status),
            .review_thread_id = jsonStringField(value, "reviewThreadId") orelse review_thread_id,
            .retryable_same_tuple_now = !std.mem.eql(u8, status, "timeout") and !std.mem.eql(u8, status, "account_resource_exhausted"),
        };
    }

    if (reviewAttemptExists(review_thread_id)) {
        return .{
            .classification = try allocator.dupe(u8, "review_attempt_unnormalized"),
            .failure_class = "review_attempt",
            .failure_code = failure_code,
            .review_attempt_phase = "review_started",
            .review_attempt_exists = true,
            .tuple_verdict_exists = false,
            .review_thread_id = review_thread_id,
            .retryable_same_tuple_now = false,
        };
    }

    return .{
        .classification = try allocator.dupe(u8, "unknown_no_attempt"),
        .failure_class = "unknown",
        .failure_code = failure_code,
        .review_attempt_phase = stringFieldAny(receipt, &.{ "reviewAttemptPhase", "phase" }) orelse "pre_lane_start",
        .review_attempt_exists = false,
        .tuple_verdict_exists = false,
        .review_thread_id = null,
        .retryable_same_tuple_now = true,
    };
}

fn writeReceiptClassificationObject(writer: *std.Io.Writer, source_index: usize, row: ReceiptClassification) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "classification");
    try writer.writeByte(':');
    try writeJsonString(writer, row.classification);
    try writer.writeByte(',');
    try writeJsonString(writer, "failureClass");
    try writer.writeByte(':');
    try writeJsonString(writer, row.failure_class);
    try writer.writeByte(',');
    try writeJsonString(writer, "failureCode");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, row.failure_code);
    try writer.writeByte(',');
    try writeJsonString(writer, "retryableSameTupleNow");
    try writer.writeByte(':');
    try writer.writeAll(if (row.retryable_same_tuple_now) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewAttemptExists");
    try writer.writeByte(':');
    try writer.writeAll(if (row.review_attempt_exists) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewAttemptPhase");
    try writer.writeByte(':');
    try writeJsonString(writer, row.review_attempt_phase);
    try writer.writeByte(',');
    try writeJsonString(writer, "reviewThreadId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, row.review_thread_id);
    try writer.writeByte(',');
    try writeJsonString(writer, "sourceIndex");
    try writer.writeByte(':');
    try writer.print("{d}", .{source_index});
    try writer.writeByte(',');
    try writeJsonString(writer, "tupleVerdictExists");
    try writer.writeByte(':');
    try writer.writeAll(if (row.tuple_verdict_exists) "true" else "false");
    try writer.writeByte('}');
}

fn cmdReceiptGate(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stderr_writer.interface.writeAll("warning: receipt gate is deprecated; use cas review import + cas review validate-record\n");
    var paths = try collectInputPathsAlloc(allocator, parsed.receipt_paths, parsed.receipt_globs);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    try runGateCommand(allocator, paths.items, parsed.receipt_format, validateReceiptGatePathAlloc);
}

fn cmdLock(allocator: std.mem.Allocator, parsed: ParsedArgs) !void {
    switch (parsed.lock_action.?) {
        .gate => {},
    }
    var paths = try collectInputPathsAlloc(allocator, parsed.receipt_paths, parsed.receipt_globs);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    try runGateCommand(allocator, paths.items, parsed.receipt_format, validateTupleLockGatePathAlloc);
}

fn runGateCommand(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    format: ReceiptFormat,
    comptime validatePath: fn (std.mem.Allocator, []const u8) anyerror!GateResult,
) !void {
    var results: std.ArrayList(GateResult) = .empty;
    defer {
        for (results.items) |result| result.deinit(allocator);
        results.deinit(allocator);
    }
    if (paths.len == 0) {
        try results.append(allocator, try gateResultFromSingleErrorAlloc(allocator, "<input>", "no files matched"));
    }
    for (paths) |path| {
        try results.append(allocator, try validatePath(allocator, path));
    }

    var any_failed = false;
    for (results.items) |result| {
        if (!result.ok()) any_failed = true;
    }

    switch (format) {
        .json => try printGateResultsJson(results.items),
        .jsonl => try printGateResultsJsonl(results.items),
        .table => try printGateResultsText(results.items),
    }
    if (any_failed) std.process.exit(1);
}

fn validateReceiptGatePathAlloc(allocator: std.mem.Allocator, path: []const u8) !GateResult {
    const raw = readFileAlloc(allocator, path, 8 * 1024 * 1024) catch |err| {
        return gateResultFromSingleErrorAlloc(allocator, path, @errorName(err));
    };
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        return gateResultFromSingleErrorAlloc(allocator, path, @errorName(err));
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return gateResultFromSingleErrorAlloc(allocator, path, "top-level JSON must be an object"),
    };
    return validateReceiptGateObjectAlloc(allocator, path, obj);
}

fn validateReceiptGateObjectAlloc(allocator: std.mem.Allocator, path: []const u8, data: std.json.ObjectMap) !GateResult {
    var errors: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (errors.items) |err| allocator.free(err);
        errors.deinit(allocator);
    }

    const phase = stringFieldAny(data, &.{ "reviewAttemptPhase", "phase" });
    const failure_code = stringFieldAny(data, &.{ "failureCode", "failure_code" });
    const review_thread_id = stringFieldAny(data, &.{ "reviewThreadId", "review_thread_id" });
    const review_thread_id_present = fieldAnyPresentNonNull(data, &.{ "reviewThreadId", "review_thread_id" });
    const review_attempt_exists = boolFieldAny(data, &.{ "reviewAttemptExists", "review_attempt_exists" });
    const tuple_verdict_exists = jsonBoolField(data, "tupleVerdictExists");
    const verdict = try objectFieldOrGateError(allocator, data, "reviewVerdict", &errors);

    if (phase) |value| {
        if (!reviewPhaseAllowed(value)) try appendGateError(allocator, &errors, "invalid reviewAttemptPhase: {s}", .{value});
    } else {
        try appendGateError(allocator, &errors, "missing reviewAttemptPhase", .{});
    }

    const expected_attempt = review_thread_id_present;
    if (review_attempt_exists) |value| {
        if (value != expected_attempt) try appendGateError(allocator, &errors, "reviewAttemptExists must equal reviewThreadId != null", .{});
    }

    if (std.mem.eql(u8, phase orelse "", "pre_review_start")) {
        if (review_thread_id_present) try appendGateError(allocator, &errors, "pre_review_start must not have reviewThreadId", .{});
        if (review_attempt_exists != null and review_attempt_exists.? != false) {
            try appendGateError(allocator, &errors, "pre_review_start must have reviewAttemptExists=false", .{});
        }
    }

    if (std.mem.eql(u8, failure_code orelse "", "pre_review_lane_transport_lost")) {
        if (!std.mem.eql(u8, phase orelse "", "pre_review_start")) {
            try appendGateError(allocator, &errors, "pre_review_lane_transport_lost requires reviewAttemptPhase=pre_review_start", .{});
        }
        if (review_thread_id_present) try appendGateError(allocator, &errors, "pre_review_lane_transport_lost must not have reviewThreadId", .{});
        const failure_class = stringFieldAny(data, &.{ "failureClass", "failure_class" });
        if (failure_class != null and !std.mem.eql(u8, failure_class.?, "transport_pre_review")) {
            try appendGateError(allocator, &errors, "pre_review_lane_transport_lost requires failureClass=transport_pre_review", .{});
        }
        const required = [_][]const u8{ "laneId", "managedServerPid", "reviewCount" };
        for (required) |name| {
            if (data.get(name) == null) try appendGateError(allocator, &errors, "pre_review_lane_transport_lost missing {s}", .{name});
        }
    }

    if (std.mem.eql(u8, failure_code orelse "", "account_resource_exhausted")) {
        if (boolFieldAny(data, &.{ "retryableSameTupleNow", "retryable_same_tuple_now" }) != false) {
            try appendGateError(allocator, &errors, "account_resource_exhausted requires retryableSameTupleNow=false", .{});
        }
    }

    if (verdict) |value| {
        const status = jsonStringField(value, "status");
        const backend = jsonStringField(value, "backendClass");
        if (status == null or !reviewStatusAllowed(status.?)) {
            try appendGateError(allocator, &errors, "invalid reviewVerdict.status: {s}", .{status orelse "null"});
        }
        if (backend == null or !backendClassAllowed(backend.?)) {
            try appendGateError(allocator, &errors, "invalid reviewVerdict.backendClass: {s}", .{backend orelse "null"});
        }
        if (std.mem.eql(u8, status orelse "", "clean") or std.mem.eql(u8, status orelse "", "findings")) {
            const required = [_][]const u8{ "baseSha", "headSha", "targetFingerprint", "reviewThreadId", "reviewTurnId" };
            for (required) |name| {
                if (nonEmptyOptional(jsonStringField(value, name)) == null) {
                    try appendGateError(allocator, &errors, "reviewVerdict.status={s} missing {s}", .{ status.?, name });
                }
            }
            if (std.mem.eql(u8, status.?, "clean") and (jsonUsizeField(value, "findingCount") orelse 0) != 0) {
                try appendGateError(allocator, &errors, "clean reviewVerdict must have findingCount=0", .{});
            }
            if (std.mem.eql(u8, status.?, "clean") and fieldPresentNonNull(value, "failureCode")) {
                try appendGateError(allocator, &errors, "clean reviewVerdict must not have failureCode", .{});
            }
        }
        if (std.mem.eql(u8, status orelse "", "pre_review_transport_failure") and fieldPresentNonNull(value, "reviewThreadId")) {
            try appendGateError(allocator, &errors, "pre_review_transport_failure reviewVerdict must not have reviewThreadId", .{});
        }
        if (std.mem.eql(u8, status orelse "", "review_transport_failure") and
            !reviewAttemptExists(jsonStringField(value, "reviewThreadId") orelse review_thread_id))
        {
            try appendGateError(allocator, &errors, "review_transport_failure reviewVerdict requires reviewThreadId", .{});
        }
        if (tuple_verdict_exists == true and !reviewVerdictStatusIsTupleTerminal(status orelse "")) {
            try appendGateError(allocator, &errors, "tupleVerdictExists=true is inconsistent with reviewVerdict.status", .{});
        }
    }

    return .{
        .path = try allocator.dupe(u8, path),
        .errors = try errors.toOwnedSlice(allocator),
    };
}

fn validateCasRerRecordPathAlloc(allocator: std.mem.Allocator, path: []const u8) !GateResult {
    const raw = readFileAlloc(allocator, path, 8 * 1024 * 1024) catch |err| {
        return gateResultFromSingleErrorAlloc(allocator, path, @errorName(err));
    };
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        return gateResultFromSingleErrorAlloc(allocator, path, @errorName(err));
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return gateResultFromSingleErrorAlloc(allocator, path, "top-level JSON must be a CAS-RER-v1 object"),
    };
    return validateCasRerRecordObjectAlloc(allocator, path, obj);
}

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
        std.mem.eql(u8, value, "parse_mismatch") or
        std.mem.eql(u8, value, "review_untrusted_source");
}

fn validateCasRerRecordObjectAlloc(allocator: std.mem.Allocator, path: []const u8, data: std.json.ObjectMap) !GateResult {
    var errors: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (errors.items) |err| allocator.free(err);
        errors.deinit(allocator);
    }

    if (!std.mem.eql(u8, jsonStringField(data, "schema") orelse "", cas_review_evidence_schema)) {
        try appendGateError(allocator, &errors, "schema must be {s}", .{cas_review_evidence_schema});
    }
    const record_id = nonEmptyOptional(jsonStringField(data, "recordId"));
    if (record_id == null) {
        try appendGateError(allocator, &errors, "recordId must be non-empty", .{});
    } else {
        if (!std.mem.startsWith(u8, record_id.?, "rer_")) {
            try appendGateError(allocator, &errors, "recordId must start with rer_", .{});
        }
        if (std.mem.indexOfScalar(u8, record_id.?, '/') != null or std.mem.indexOfScalar(u8, record_id.?, '\\') != null) {
            try appendGateError(allocator, &errors, "recordId must not contain path separators", .{});
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
            try appendGateError(allocator, &errors, "command.backendSelected must be non-empty", .{});
        }
        if (objectField(command_obj, "brokerDecision")) |broker| {
            if (nonEmptyOptional(jsonStringField(broker, "action")) == null) {
                try appendGateError(allocator, &errors, "command.brokerDecision.action must be non-empty", .{});
            }
            if (nonEmptyOptional(jsonStringField(broker, "reason")) == null) {
                try appendGateError(allocator, &errors, "command.brokerDecision.reason must be non-empty", .{});
            }
            if (jsonBoolField(broker, "freshAttemptRequired") == null) {
                try appendGateError(allocator, &errors, "command.brokerDecision.freshAttemptRequired must be boolean", .{});
            }
        } else {
            try appendGateError(allocator, &errors, "missing command.brokerDecision", .{});
        }
    }

    const created_at = jsonStringField(data, "createdAt");
    if (created_at == null or parseCasRerCreatedAtNs(created_at.?) == null) {
        try appendGateError(allocator, &errors, "createdAt must be a parseable CAS-RER timestamp", .{});
    }
    const updated_at = jsonStringField(data, "updatedAt");
    if (updated_at == null or parseCasRerCreatedAtNs(updated_at.?) == null) {
        try appendGateError(allocator, &errors, "updatedAt must be a parseable CAS-RER timestamp", .{});
    }

    if (data.get("workflowBinding")) |binding_value| {
        switch (binding_value) {
            .object => {
                const canonical = canonicalWorkflowBindingJsonFromValueAlloc(allocator, binding_value) catch null;
                if (canonical) |value| {
                    allocator.free(value);
                } else {
                    try appendGateError(allocator, &errors, "workflowBinding must be a complete canonical opaque request binding", .{});
                }
            },
            else => try appendGateError(allocator, &errors, "workflowBinding must be an object when present", .{}),
        }
    }

    var attempt_exists_value: ?bool = null;
    if (attempt) |attempt_obj| {
        const attempt_exists = jsonBoolField(attempt_obj, "exists");
        attempt_exists_value = attempt_exists;
        if (attempt_exists == null) {
            try appendGateError(allocator, &errors, "attempt.exists must be boolean", .{});
        }
        const review_thread_id_present = nonEmptyOptional(jsonStringField(attempt_obj, "reviewThreadId")) != null;
        if (attempt_exists) |value| {
            if (value != review_thread_id_present) {
                try appendGateError(allocator, &errors, "attempt.exists must equal attempt.reviewThreadId non-empty", .{});
            }
        }
        if (jsonStringField(attempt_obj, "phase")) |phase| {
            if (!reviewPhaseAllowed(phase)) try appendGateError(allocator, &errors, "invalid attempt.phase: {s}", .{phase});
        } else {
            try appendGateError(allocator, &errors, "missing attempt.phase", .{});
        }
    }

    if (verdict) |verdict_obj| {
        const status = jsonStringField(verdict_obj, "status");
        if (status == null or !casRerStatusAllowed(status.?)) {
            try appendGateError(allocator, &errors, "invalid verdict.status: {s}", .{status orelse "null"});
        }
        const clean = jsonBoolField(verdict_obj, "clean");
        if (clean == null) {
            try appendGateError(allocator, &errors, "verdict.clean must be boolean", .{});
        } else if (std.mem.eql(u8, status orelse "", "clean")) {
            if (clean.? != true) {
                try appendGateError(allocator, &errors, "verdict.status=clean requires verdict.clean=true", .{});
            }
        } else if (clean.? != false) {
            try appendGateError(allocator, &errors, "verdict.status!=clean requires verdict.clean=false", .{});
        }
        const finding_count = jsonUsizeField(verdict_obj, "findingCount");
        if (finding_count == null) {
            try appendGateError(allocator, &errors, "verdict.findingCount must be a non-negative integer", .{});
        }
        const findings_len: ?usize = blk: {
            const findings_value = verdict_obj.get("findings") orelse {
                try appendGateError(allocator, &errors, "verdict.findings must be an array", .{});
                break :blk null;
            };
            switch (findings_value) {
                .array => |array| break :blk array.items.len,
                else => {
                    try appendGateError(allocator, &errors, "verdict.findings must be an array", .{});
                    break :blk null;
                },
            }
        };
        if (std.mem.eql(u8, status orelse "", "findings") and (finding_count orelse 0) == 0) {
            try appendGateError(allocator, &errors, "verdict.status=findings requires findingCount > 0", .{});
        }
        if (std.mem.eql(u8, status orelse "", "findings") and findings_len != null and finding_count != null and findings_len.? != finding_count.?) {
            try appendGateError(allocator, &errors, "verdict.status=findings requires findings length to match findingCount", .{});
        }
        if (std.mem.eql(u8, status orelse "", "clean")) {
            if ((finding_count orelse 1) != 0) {
                try appendGateError(allocator, &errors, "verdict.status=clean requires findingCount = 0", .{});
            }
            if ((findings_len orelse 1) != 0) {
                try appendGateError(allocator, &errors, "verdict.status=clean requires findings length = 0", .{});
            }
        }
        if (std.mem.eql(u8, status orelse "", "clean") or std.mem.eql(u8, status orelse "", "findings")) {
            if (failure) |failure_obj| {
                if (fieldPresentNonNull(failure_obj, "failureCode")) {
                    try appendGateError(allocator, &errors, "terminal tuple verdict requires failure.failureCode=null", .{});
                }
                if (fieldPresentNonNull(failure_obj, "failureClass")) {
                    try appendGateError(allocator, &errors, "terminal tuple verdict requires failure.failureClass=null", .{});
                }
                if (fieldPresentNonNull(failure_obj, "retryableSameTupleNow")) {
                    try appendGateError(allocator, &errors, "terminal tuple verdict requires failure.retryableSameTupleNow=null", .{});
                }
            }
        }
        if (jsonBoolField(verdict_obj, "tupleVerdictExists")) |tuple_verdict_exists| {
            if (tuple_verdict_exists) {
                if (!(std.mem.eql(u8, status orelse "", "clean") or std.mem.eql(u8, status orelse "", "findings"))) {
                    try appendGateError(allocator, &errors, "verdict.tupleVerdictExists requires terminal clean or findings status", .{});
                }
                if (tuple) |tuple_obj| {
                    if (nonEmptyOptional(jsonStringField(tuple_obj, "repoRealpath")) == null) {
                        try appendGateError(allocator, &errors, "verdict.tupleVerdictExists requires tuple.repoRealpath", .{});
                    }
                    if (nonEmptyOptional(jsonStringField(tuple_obj, "baseSha")) == null) {
                        try appendGateError(allocator, &errors, "verdict.tupleVerdictExists requires tuple.baseSha", .{});
                    }
                    if (nonEmptyOptional(jsonStringField(tuple_obj, "headSha")) == null) {
                        try appendGateError(allocator, &errors, "verdict.tupleVerdictExists requires tuple.headSha", .{});
                    }
                    if (nonEmptyOptional(jsonStringField(tuple_obj, "targetFingerprint")) == null) {
                        try appendGateError(allocator, &errors, "verdict.tupleVerdictExists requires tuple.targetFingerprint", .{});
                    }
                }
                if (std.mem.eql(u8, status orelse "", "clean") or std.mem.eql(u8, status orelse "", "findings")) {
                    if (attempt_exists_value != true) {
                        try appendGateError(allocator, &errors, "terminal tuple verdict requires attempt.exists=true", .{});
                    }
                    if (attempt) |attempt_obj| {
                        if (nonEmptyOptional(jsonStringField(attempt_obj, "reviewThreadId")) == null) {
                            try appendGateError(allocator, &errors, "terminal tuple verdict requires attempt.reviewThreadId", .{});
                        }
                        if (nonEmptyOptional(jsonStringField(attempt_obj, "reviewTurnId")) == null) {
                            try appendGateError(allocator, &errors, "terminal tuple verdict requires attempt.reviewTurnId", .{});
                        }
                        const phase = jsonStringField(attempt_obj, "phase") orelse "";
                        if (!(std.mem.eql(u8, phase, "review_terminal") or std.mem.eql(u8, phase, "normalized_verdict"))) {
                            try appendGateError(allocator, &errors, "terminal tuple verdict requires terminal attempt.phase", .{});
                        }
                    }
                }
            }
        } else {
            try appendGateError(allocator, &errors, "verdict.tupleVerdictExists must be boolean", .{});
        }
    }

    if (failure) |failure_obj| {
        if (std.mem.eql(u8, jsonStringField(failure_obj, "failureCode") orelse "", "pre_review_lane_transport_lost")) {
            if (attempt_exists_value != false) {
                try appendGateError(allocator, &errors, "pre_review_lane_transport_lost requires attempt.exists=false", .{});
            }
        }
    }

    if (principal) |principal_obj| {
        const kind = jsonStringField(principal_obj, "kind");
        if (kind == null or
            !(std.mem.eql(u8, kind.?, "strong") or std.mem.eql(u8, kind.?, "reduced") or std.mem.eql(u8, kind.?, "unknown")))
        {
            try appendGateError(allocator, &errors, "principal.kind must be strong, reduced, or unknown", .{});
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
        }
        if (std.mem.eql(u8, kind orelse "", "reduced")) {
            if (proof_usable != false) {
                try appendGateError(allocator, &errors, "principal.kind=reduced requires principal.proofUsable=false", .{});
            }
            if (reduced != true) {
                try appendGateError(allocator, &errors, "principal.kind=reduced requires principal.reduced=true", .{});
            }
        }
        if (proof_usable == true) {
            if (!std.mem.eql(u8, kind orelse "", "strong")) {
                try appendGateError(allocator, &errors, "principal.proofUsable=true requires principal.kind=strong", .{});
            }
            if (reduced != false) {
                try appendGateError(allocator, &errors, "principal.proofUsable=true requires principal.reduced=false", .{});
            }
            if (fallback_used != false or std.mem.eql(u8, jsonStringField(principal_obj, "source") orelse "", "cas-native-fallback")) {
                try appendGateError(allocator, &errors, "principal.proofUsable=true requires no fallback", .{});
            }
            if (!casRerPrincipalFingerprintUsable(jsonStringField(principal_obj, "accountFingerprint"))) {
                try appendGateError(allocator, &errors, "principal.proofUsable=true requires principal.accountFingerprint", .{});
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

fn validateTupleLockGatePathAlloc(allocator: std.mem.Allocator, path: []const u8) !GateResult {
    const raw = readFileAlloc(allocator, path, 8 * 1024 * 1024) catch |err| {
        return gateResultFromSingleErrorAlloc(allocator, path, @errorName(err));
    };
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        return gateResultFromSingleErrorAlloc(allocator, path, @errorName(err));
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return gateResultFromSingleErrorAlloc(allocator, path, "top-level lock must be an object"),
    };
    return validateTupleLockGateObjectAlloc(allocator, path, obj);
}

fn validateTupleLockGateObjectAlloc(allocator: std.mem.Allocator, path: []const u8, lock: std.json.ObjectMap) !GateResult {
    var errors: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (errors.items) |err| allocator.free(err);
        errors.deinit(allocator);
    }

    if (!std.mem.eql(u8, jsonStringField(lock, "lockVersion") orelse "", review_tuple_lock_version)) {
        try appendGateError(allocator, &errors, "lockVersion must be {s}", .{review_tuple_lock_version});
    }
    const required = [_][]const u8{
        "tupleHash",
        "repoRealpath",
        "baseSha",
        "headSha",
        "targetFingerprint",
        "resolvedCodexPath",
        "resolvedCodexVersion",
        "accountFingerprint",
        "state",
    };
    for (required) |name| {
        if (!jsonValueTruthy(lock.get(name))) try appendGateError(allocator, &errors, "missing {s}", .{name});
    }
    const state = jsonStringField(lock, "state");
    if (state == null or !reviewTupleLockStateAllowed(state.?)) {
        try appendGateError(allocator, &errors, "invalid state: {s}", .{state orelse "null"});
    }
    if (state != null and reviewTupleLockStateActive(state.?) and nonEmptyOptional(jsonStringField(lock, "reviewThreadId")) == null) {
        try appendGateError(allocator, &errors, "{s} requires reviewThreadId", .{state.?});
    }
    if (std.mem.eql(u8, state orelse "", "pre_review_start_failed") and fieldPresentNonNull(lock, "reviewThreadId")) {
        try appendGateError(allocator, &errors, "pre_review_start_failed must not have reviewThreadId", .{});
    }
    if (std.mem.eql(u8, state orelse "", "account_resource_exhausted") and
        !std.mem.eql(u8, jsonStringField(lock, "lastFailureCode") orelse "", "account_resource_exhausted"))
    {
        try appendGateError(allocator, &errors, "account_resource_exhausted state requires lastFailureCode=account_resource_exhausted", .{});
    }
    const expires_at = jsonI64Field(lock, "expiresAtUnixS") orelse 0;
    const updated_at = jsonI64Field(lock, "updatedAtUnixS") orelse 0;
    if (expires_at != 0 and updated_at != 0 and expires_at < updated_at) {
        try appendGateError(allocator, &errors, "expiresAtUnixS must be >= updatedAtUnixS", .{});
    }
    if (lock.get("workflowBinding")) |binding_value| switch (binding_value) {
        .object => {
            const raw = try stringifyJsonValueAlloc(allocator, .{ .object = lock });
            defer allocator.free(raw);
            var parsed_lock = std.json.parseFromSlice(ReviewTupleLock, allocator, raw, .{ .ignore_unknown_fields = true }) catch null;
            if (parsed_lock) |*parsed| {
                defer parsed.deinit();
                if (!(reviewTupleLockWorkflowBindingValidAlloc(allocator, parsed.value) catch false)) {
                    try appendGateError(allocator, &errors, "workflowBinding must match the tupleHash", .{});
                }
            } else {
                try appendGateError(allocator, &errors, "workflowBinding lock fields are invalid", .{});
            }
        },
        else => try appendGateError(allocator, &errors, "workflowBinding must be an object when present", .{}),
    };
    return .{
        .path = try allocator.dupe(u8, path),
        .errors = try errors.toOwnedSlice(allocator),
    };
}

fn cmdLane(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    switch (parsed.lane_action.?) {
        .start => try cmdLaneStart(allocator, io, parsed),
        .review => try cmdLaneReview(allocator, io, parsed),
        .smoke => try cmdLaneSmoke(allocator, io, parsed),
        .smoke_suite => try cmdLaneSmokeSuite(allocator, io, parsed),
        .smoke_until_fixed => try cmdLaneSmokeUntilFixed(allocator, io, parsed),
        .status => try cmdLaneStatus(allocator, parsed),
        .stop => try cmdLaneStop(allocator, parsed),
    }
}

fn cmdLaneStart(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    const cwd = try repoRealpathAlloc(allocator, parsed.cwd.?);
    defer allocator.free(cwd);
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
    defer allocator.free(resolved_codex_path);
    const codex_version = try readCodexVersionAlloc(allocator, io, cwd, resolved_codex_path);
    defer allocator.free(codex_version);
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
            .reviewAttemptPhase = "lane_started",
            .reviewAttemptExists = false,
            .tupleVerdictExists = false,
            .reviewThreadId = @as(?[]const u8, null),
            .reviewTurnId = @as(?[]const u8, null),
            .baseSha = @as(?[]const u8, null),
            .headSha = @as(?[]const u8, null),
            .targetFingerprint = @as(?[]const u8, null),
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

fn cmdLaneSmoke(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    const cwd = try repoRealpathAlloc(allocator, parsed.cwd.?);
    defer allocator.free(cwd);
    const target = parsed.target.?;
    const target_record = targetToRecord(target);
    var identity = try computeTargetIdentityAlloc(allocator, io, cwd, target_record);
    defer identity.deinit(allocator);

    const resolved_codex_path = cas.resolveExecutableAlloc(allocator, "codex") catch {
        try renderErrorAndExit(
            parsed.json,
            "lane-smoke",
            "app-server/start",
            "codex binary could not be resolved for review_session lane smoke",
            cwd,
            .{},
            .{
                .code = "missing_codex_binary",
                .hint = "install or expose a compatible codex binary on PATH before starting a CAS review lane smoke",
            },
        );
    };
    defer allocator.free(resolved_codex_path);
    const codex_version = try readCodexVersionAlloc(allocator, io, cwd, resolved_codex_path);
    defer allocator.free(codex_version);
    var managed_server = startManagedWebsocketServer(allocator, cwd, resolved_codex_path, parsed.hook_policy, io) catch |err| {
        try renderErrorAndExit(
            parsed.json,
            "lane-smoke",
            "app-server/start",
            @errorName(err),
            cwd,
            .{
                .resolved_codex_path = resolved_codex_path,
                .resolved_codex_version = codex_version,
                .compatibility_verdict = "compatible",
                .selected_transport = "websocket",
                .selection_reason = "persistent_review_lane_smoke",
                .orphan_ttl_seconds = managed_server_orphan_ttl_seconds,
            },
            .{
                .code = "websocket_bootstrap_failed",
                .hint = "CAS could not start the managed websocket app-server for persistent lane smoke",
            },
        );
    };
    const lane_id = try laneIdAlloc(allocator, managed_server.processId());
    defer allocator.free(lane_id);
    const now_s = unixSeconds();
    var lane = LaneRecord{
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
    const lane_record_path = try laneRecordPathAlloc(allocator, lane_id);
    defer allocator.free(lane_record_path);

    var client = connectReviewClient(
        allocator,
        cwd,
        resolved_codex_path,
        codex_version,
        lane.transport_kind,
        managed_server.listen_url,
        io,
        parsed,
    ) catch |err| {
        managed_server.kill();
        try emitPreReviewLaneTransportLostAndExit(
            allocator,
            parsed.json,
            "lane-smoke",
            "review/start",
            @errorName(err),
            "persistent CAS lane smoke could not connect to the managed websocket server",
            lane,
            lane_record_path,
            target_record,
            identity,
            null,
            cas_websocket.processAlive(lane.managed_server_pid),
        );
    };
    defer {
        client.close();
        client.deinit();
    }
    defer managed_server.deinit(allocator);

    var review_tuple = try reviewTupleIdentityAlloc(allocator, cwd, identity, resolved_codex_path, codex_version, &client, null);
    defer review_tuple.deinit(allocator);
    const tuple_lock_bundle = try acquireReviewTupleStartLockOrExit(
        allocator,
        parsed.json,
        "lane-smoke",
        identity,
        review_tuple,
        parsed.review_lock_override_reason,
        null,
        false,
        &managed_server,
    );
    defer tuple_lock_bundle.deinit(allocator);
    try writeLaneRecord(allocator, lane_record_path, lane);

    const session_dir = try sessionDirAlloc(allocator);
    defer allocator.free(session_dir);
    const parent_thread_id = startParentThreadAlloc(allocator, &client, cwd, session_dir, parsed.multi_agent_mode) catch |err| {
        if (isTransportLossError(err)) {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_lane_transport_lost", null, null, null, null);
            try emitPreReviewLaneTransportLostAndExit(
                allocator,
                parsed.json,
                "lane-smoke",
                "thread/start",
                @errorName(err),
                "persistent CAS lane smoke lost websocket transport while starting the parent thread",
                lane,
                lane_record_path,
                target_record,
                identity,
                null,
                cas_websocket.processAlive(lane.managed_server_pid),
            );
        }
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "review_failed", null, null, null, null);
        return err;
    };
    defer allocator.free(parent_thread_id);
    const parent_event_log_path = try parentEventLogPathAlloc(allocator, session_dir, parent_thread_id);
    defer allocator.free(parent_event_log_path);
    if (shouldPreMaterializeDetachedReviewParent(.auto, codex_version)) {
        materializeParentThreadTurn(
            allocator,
            &client,
            parent_thread_id,
            parent_event_log_path,
            parsed.timeout_ms,
            parsed.poll_interval_ms,
            parsed.multi_agent_mode,
        ) catch |err| {
            if (isTransportLossError(err)) {
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_lane_transport_lost", null, null, null, parent_event_log_path);
                try emitPreReviewLaneTransportLostAndExit(
                    allocator,
                    parsed.json,
                    "lane-smoke",
                    "turn/start",
                    @errorName(err),
                    "persistent CAS lane smoke lost websocket transport while materializing the parent thread",
                    lane,
                    lane_record_path,
                    target_record,
                    identity,
                    null,
                    cas_websocket.processAlive(lane.managed_server_pid),
                );
            }
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "review_failed", null, null, null, parent_event_log_path);
            return err;
        };
    }

    const review_params_json = try buildReviewStartParamsJson(allocator, parent_thread_id, target);
    defer allocator.free(review_params_json);
    const review_result_json = client.requestJson("review/start", review_params_json) catch |err| {
        if (isTransportLossError(err)) {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_lane_transport_lost", null, null, null, parent_event_log_path);
            try emitPreReviewLaneTransportLostAndExit(
                allocator,
                parsed.json,
                "lane-smoke",
                "review/start",
                @errorName(err),
                "review/start could not be reached because persistent CAS lane smoke transport was lost",
                lane,
                lane_record_path,
                target_record,
                identity,
                null,
                cas_websocket.processAlive(lane.managed_server_pid),
            );
        }
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "review_failed", null, null, null, parent_event_log_path);
        return err;
    };
    defer allocator.free(review_result_json);

    const review_thread_id = try extractReviewThreadIdAlloc(allocator, review_result_json);
    defer allocator.free(review_thread_id);
    const review_turn_id = try extractReviewTurnIdAlloc(allocator, review_result_json);
    defer allocator.free(review_turn_id);
    const event_log_path = try std.fmt.allocPrint(allocator, "{s}/{s}.events.ndjson", .{ session_dir, review_thread_id });
    defer allocator.free(event_log_path);
    const record_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, review_thread_id });
    defer allocator.free(record_path);
    try appendLogRecord(allocator, event_log_path, "review/start", "request", review_params_json);
    try appendLogRecord(allocator, event_log_path, "review/start", "response", review_result_json);
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
        .event_log_path = event_log_path,
        .created_at_unix_s = unixSeconds(),
        .last_observed_status = "inProgress",
        .codex_version = codex_version,
        .resolved_codex_path = resolved_codex_path,
        .compatibility_verdict = "compatible",
        .transport_kind = lane.transport_kind,
        .transport_selection_reason = "persistent_review_lane_smoke",
        .managed_server_pid = lane.managed_server_pid,
        .managed_server_listen_url = lane.managed_server_listen_url,
        .managed_server_stderr_log_path = null,
        .orphan_ttl_seconds = lane.orphan_ttl_seconds,
        .hook_policy = lane.hook_policy,
        .hook_log_path = event_log_path,
        .base_sha = identity.base_sha,
        .head_sha = identity.head_sha,
        .target_fingerprint = identity.fingerprint,
        .accountFingerprint = review_tuple.account_fingerprint,
        .accountFingerprintReducedProtection = review_tuple.account_fingerprint_reduced_protection,
    };
    try writeSessionRecord(allocator, record_path, record);
    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "review_started", null, review_thread_id, review_turn_id, record_path, event_log_path);
    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", null, review_thread_id, review_turn_id, record_path, event_log_path);

    var observed_status: ?[]u8 = null;
    defer if (observed_status) |status| allocator.free(status);
    var review_attempt_phase: []const u8 = "review_started";
    var tuple_verdict_exists = false;
    var smoke_failure: ?FailureInfo = null;
    var latest_status: ?ReviewStatus = null;
    defer if (latest_status) |*status| status.deinit(allocator);
    if (parsed.lane_smoke_wait) {
        latest_status = waitForReviewCompletion(
            allocator,
            &client,
            review_thread_id,
            review_turn_id,
            event_log_path,
            parsed.timeout_ms,
            parsed.poll_interval_ms,
        ) catch |err| switch (err) {
            error.WaitTimedOut => blk: {
                var timeout_status = try fetchReviewStatus(allocator, &client, review_thread_id, event_log_path, null);
                record.last_observed_status = timeoutStatusString(&timeout_status);
                observed_status = try allocator.dupe(u8, timeout_status.turn_status);
                try writeSessionRecord(allocator, record_path, record);
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", "wait_timed_out", review_thread_id, review_turn_id, record_path, event_log_path);
                review_attempt_phase = statusReviewAttemptPhase(timeout_status, true);
                smoke_failure = .{
                    .code = "wait_timed_out",
                    .hint = "lane smoke review attempt exists but did not reach terminal status before timeout; wait on the same reviewThreadId",
                };
                break :blk timeout_status;
            },
            else => |unhandled| {
                if (isTransportLossError(unhandled)) {
                    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", "review_transport_lost", review_thread_id, review_turn_id, record_path, event_log_path);
                    try printJson(.{
                        .demo = "cas-review-session",
                        .action = "lane-smoke",
                        .smokeKind = "lane-first-review",
                        .status = "fail",
                        .smokeStatus = "failed",
                        .reviewAttemptPhase = "review_started",
                        .reviewAttemptExists = true,
                        .tupleVerdictExists = false,
                        .reviewThreadId = review_thread_id,
                        .reviewTurnId = review_turn_id,
                        .baseSha = identity.base_sha,
                        .headSha = identity.head_sha,
                        .targetFingerprint = identity.fingerprint,
                        .laneId = lane.lane_id,
                        .laneRecordPath = lane_record_path,
                        .recordPath = record_path,
                        .eventLogPath = event_log_path,
                        .failureCode = "review_transport_lost",
                        .failureClass = "transport_review_attempt",
                        .retryableSameTupleNow = true,
                        .failureHint = "persistent CAS lane smoke lost transport after review/start returned a reviewThreadId",
                    });
                    std.process.exit(1);
                }
                return unhandled;
            },
        };
        if (latest_status) |*status| {
            record.last_observed_status = status.turn_status;
            persistTerminalReviewResult(&record, status.*);
            observed_status = try allocator.dupe(u8, status.turn_status);
            if (isTerminalTurnStatus(status.turn_status)) {
                if (reviewStatusHasTrustedResult(status.*, null)) {
                    if (smokeDualParseFailureInfo(allocator, status.*)) |failure| {
                        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "terminal", failure.code, review_thread_id, review_turn_id, record_path, event_log_path);
                        review_attempt_phase = "review_terminal";
                        smoke_failure = failure;
                    } else if (!identityHasCompleteTuple(identity)) {
                        const failure = tupleIdentityUnavailableFailureInfo();
                        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "terminal", failure.code, review_thread_id, review_turn_id, record_path, event_log_path);
                        review_attempt_phase = "review_terminal";
                        smoke_failure = failure;
                    } else {
                        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "normalized", null, review_thread_id, review_turn_id, record_path, event_log_path);
                        review_attempt_phase = "normalized_verdict";
                        tuple_verdict_exists = true;
                    }
                } else if (status.review_result_available) {
                    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "terminal", "review_untrusted_source", review_thread_id, review_turn_id, record_path, event_log_path);
                    review_attempt_phase = "review_terminal";
                    smoke_failure = reviewUntrustedSourceFailureInfo();
                } else if (failureInfoForStatus(status)) |failure| {
                    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, if (std.mem.eql(u8, failure.code, "account_resource_exhausted")) "account_resource_exhausted" else "terminal", failure.code, review_thread_id, review_turn_id, record_path, event_log_path);
                    review_attempt_phase = "review_terminal";
                    smoke_failure = failure;
                } else {
                    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "terminal", "review_output_missing", review_thread_id, review_turn_id, record_path, event_log_path);
                    review_attempt_phase = "review_terminal";
                    smoke_failure = .{
                        .code = "review_output_missing",
                        .hint = "lane smoke review reached terminal status without a materialized reviewResult",
                    };
                }
            } else if (smoke_failure == null) {
                review_attempt_phase = "review_waiting";
            }
            try writeSessionRecord(allocator, record_path, record);
        }
    }

    const cleanup_status = if (parsed.lane_smoke_cleanup)
        archiveLaneThreadsBestEffort(allocator, &client, parent_thread_id, review_thread_id, event_log_path) catch try allocator.dupe(u8, "failed")
    else
        try allocator.dupe(u8, "skipped");
    defer allocator.free(cleanup_status);
    const cleanup_warning: ?[]const u8 = if (std.mem.eql(u8, cleanup_status, "ok") or std.mem.eql(u8, cleanup_status, "skipped"))
        null
    else
        "lane smoke cleanup was incomplete; inspect parent/review threads before reusing artifacts";

    const tuple_hash = try reviewTupleHashAlloc(allocator, review_tuple);
    defer allocator.free(tuple_hash);
    const smoke_record_path = try laneSmokeRecordPathAlloc(allocator, tuple_hash);
    defer allocator.free(smoke_record_path);
    const smoke_failed = laneSmokeFailureMakesSmokeFail(smoke_failure);
    const smoke_command_status: []const u8 = if (smoke_failed) "fail" else "pass";
    const smoke_record_status: []const u8 = if (smoke_failed) "failed" else "passed";
    const smoke_record = LaneSmokeRecord{
        .smokeStatus = smoke_record_status,
        .laneId = lane.lane_id,
        .laneRecordPath = lane_record_path,
        .repoRealpath = review_tuple.repo_realpath,
        .baseSha = identity.base_sha,
        .headSha = identity.head_sha,
        .targetFingerprint = identity.fingerprint,
        .resolvedCodexPath = resolved_codex_path,
        .resolvedCodexVersion = codex_version,
        .accountFingerprint = review_tuple.account_fingerprint,
        .accountFingerprintReducedProtection = review_tuple.account_fingerprint_reduced_protection,
        .tupleHash = tuple_hash,
        .parentThreadId = parent_thread_id,
        .reviewThreadId = review_thread_id,
        .reviewTurnId = review_turn_id,
        .recordPath = record_path,
        .eventLogPath = event_log_path,
        .cleanupStatus = cleanup_status,
        .cleanupWarning = cleanup_warning,
        .createdAtUnixS = unixSeconds(),
    };
    try writeLaneSmokeRecord(allocator, smoke_record_path, smoke_record);

    if (lane.first_review_thread_id == null) lane.first_review_thread_id = review_thread_id;
    if (lane.first_review_turn_id == null) lane.first_review_turn_id = review_turn_id;
    lane.last_used_at_unix_s = unixSeconds();
    lane.last_smoke_status = smoke_record_status;
    lane.last_smoke_record_path = smoke_record_path;
    lane.last_smoke_cleanup_status = cleanup_status;
    try writeLaneRecord(allocator, lane_record_path, lane);

    if (parsed.json) {
        const review_verdict_json = if (latest_status) |status|
            try reviewVerdictJsonForStatusAlloc(
                allocator,
                "cas-lane",
                identity,
                review_thread_id,
                review_turn_id,
                record_path,
                event_log_path,
                status,
                smoke_failure,
            )
        else
            null;
        defer if (review_verdict_json) |json| allocator.free(json);
        if (review_verdict_json) |json| {
            var verdict_parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
            defer verdict_parsed.deinit();
            try printJson(.{
                .demo = "cas-review-session",
                .action = "lane-smoke",
                .smokeKind = "lane-first-review",
                .status = smoke_command_status,
                .smokeStatus = smoke_record_status,
                .reviewAttemptPhase = review_attempt_phase,
                .reviewAttemptExists = true,
                .tupleVerdictExists = tuple_verdict_exists,
                .reviewThreadId = review_thread_id,
                .reviewTurnId = review_turn_id,
                .baseSha = identity.base_sha,
                .headSha = identity.head_sha,
                .targetFingerprint = identity.fingerprint,
                .laneId = lane.lane_id,
                .cwd = lane.cwd,
                .laneRecordPath = lane_record_path,
                .smokeRecordPath = smoke_record_path,
                .recordPath = record_path,
                .eventLogPath = event_log_path,
                .reviewCount = lane.review_count,
                .firstReviewThreadId = lane.first_review_thread_id,
                .firstReviewTurnId = lane.first_review_turn_id,
                .selectedTransport = "websocket",
                .managedServerPid = lane.managed_server_pid,
                .managedServerListenUrl = lane.managed_server_listen_url,
                .tupleHash = tuple_hash,
                .accountFingerprint = review_tuple.account_fingerprint,
                .accountFingerprintReducedProtection = review_tuple.account_fingerprint_reduced_protection,
                .waited = parsed.lane_smoke_wait,
                .observedTurnStatus = observed_status,
                .cleanupStatus = cleanup_status,
                .cleanupWarning = cleanup_warning,
                .failureCode = if (smoke_failure) |failure| failure.code else null,
                .failureClass = if (smoke_failure) |failure| failureClassForCode(failure.code) else "none",
                .failureHint = if (smoke_failure) |failure| failure.hint else null,
                .retryableSameTupleNow = if (smoke_failure) |failure| retryableSameTupleNowForCode(failure.code) else null,
                .reviewVerdict = verdict_parsed.value,
            });
        } else {
            try printJson(.{
                .demo = "cas-review-session",
                .action = "lane-smoke",
                .smokeKind = "lane-first-review",
                .status = smoke_command_status,
                .smokeStatus = smoke_record_status,
                .reviewAttemptPhase = review_attempt_phase,
                .reviewAttemptExists = true,
                .tupleVerdictExists = tuple_verdict_exists,
                .reviewThreadId = review_thread_id,
                .reviewTurnId = review_turn_id,
                .baseSha = identity.base_sha,
                .headSha = identity.head_sha,
                .targetFingerprint = identity.fingerprint,
                .laneId = lane.lane_id,
                .cwd = lane.cwd,
                .laneRecordPath = lane_record_path,
                .smokeRecordPath = smoke_record_path,
                .recordPath = record_path,
                .eventLogPath = event_log_path,
                .reviewCount = lane.review_count,
                .firstReviewThreadId = lane.first_review_thread_id,
                .firstReviewTurnId = lane.first_review_turn_id,
                .selectedTransport = "websocket",
                .managedServerPid = lane.managed_server_pid,
                .managedServerListenUrl = lane.managed_server_listen_url,
                .tupleHash = tuple_hash,
                .accountFingerprint = review_tuple.account_fingerprint,
                .accountFingerprintReducedProtection = review_tuple.account_fingerprint_reduced_protection,
                .waited = parsed.lane_smoke_wait,
                .observedTurnStatus = observed_status,
                .cleanupStatus = cleanup_status,
                .cleanupWarning = cleanup_warning,
                .failureCode = if (smoke_failure) |failure| failure.code else null,
                .failureClass = if (smoke_failure) |failure| failureClassForCode(failure.code) else "none",
                .failureHint = if (smoke_failure) |failure| failure.hint else null,
                .retryableSameTupleNow = if (smoke_failure) |failure| retryableSameTupleNowForCode(failure.code) else null,
                .reviewVerdict = @as(?[]const u8, null),
            });
        }
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session lane smoke\nlane: {s}\nreview thread: {s}\nreview turn: {s}\nreceipt: {s}\nsmoke record: {s}\n", .{
            lane.lane_id,
            review_thread_id,
            review_turn_id,
            record_path,
            smoke_record_path,
        });
    }
    if (smoke_failed) std.process.exit(1);
}

fn laneSmokeFailureMakesSmokeFail(smoke_failure: ?FailureInfo) bool {
    const failure = smoke_failure orelse return false;
    return !std.mem.eql(u8, failure.code, "wait_timed_out");
}

fn smokeDualParseFailureInfo(allocator: std.mem.Allocator, status: ReviewStatus) ?FailureInfo {
    const dual_parse = dualParseVerdictAlloc(allocator, status) catch return null;
    defer dual_parse.deinit(allocator);
    if (!std.mem.eql(u8, dual_parse.verdict, "mismatch")) return null;
    return .{
        .code = "review_parse_mismatch",
        .hint = "lane smoke structured findings disagree with the raw rendered review parse",
    };
}

fn tupleIdentityUnavailableFailureInfo() FailureInfo {
    return .{
        .code = "target_identity_unavailable",
        .hint = "review result is not proof because baseSha, headSha, and targetFingerprint were not all captured",
    };
}

fn terminalBindingFailureForIdentity(allocator: std.mem.Allocator, status: ReviewStatus, identity: TargetIdentity) ?FailureInfo {
    return terminalLockFailureForStatus(allocator, status) orelse if (!identityHasCompleteTuple(identity)) tupleIdentityUnavailableFailureInfo() else null;
}

fn terminalBindingFailureForOptionalIdentity(allocator: std.mem.Allocator, status: ReviewStatus, identity_opt: ?TargetIdentity) ?FailureInfo {
    return terminalLockFailureForStatus(allocator, status) orelse if (identity_opt) |identity|
        if (!identityHasCompleteTuple(identity)) tupleIdentityUnavailableFailureInfo() else null
    else
        tupleIdentityUnavailableFailureInfo();
}

fn cmdLaneSmokeSuite(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var results = std.ArrayList(LaneSmokeRunSummary).empty;
    defer {
        for (results.items) |result| result.deinit(allocator);
        results.deinit(allocator);
    }

    const max_consecutive = try runLaneSmokeSuite(
        allocator,
        io,
        parsed,
        parsed.smoke_runs,
        1,
        &results,
    );
    const status: []const u8 = if (max_consecutive >= parsed.smoke_required_consecutive_passes) "pass" else "fail";
    const persistent_lane_canonical = std.mem.eql(u8, status, "pass");
    if (parsed.json) {
        try printSmokeSuiteJson(
            allocator,
            "CAS-RSS-v1",
            status,
            parsed,
            parsed.smoke_runs,
            max_consecutive,
            persistent_lane_canonical,
            if (persistent_lane_canonical) "cas-lane" else "cas-start-wait-normalized",
            results.items,
        );
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session lane smoke-suite\nstatus: {s}\nmax consecutive passes: {d}\n", .{ status, max_consecutive });
    }
    if (!persistent_lane_canonical) std.process.exit(1);
}

fn cmdLaneSmokeUntilFixed(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var all_results = std.ArrayList(LaneSmokeRunSummary).empty;
    defer {
        for (all_results.items) |result| result.deinit(allocator);
        all_results.deinit(allocator);
    }

    var observed_consecutive: u32 = 0;
    var rounds_run: u32 = 0;
    var last_failure_code: ?[]const u8 = null;
    while (rounds_run < parsed.smoke_max_rounds and observed_consecutive < parsed.smoke_required_consecutive_passes) {
        rounds_run += 1;
        var round_results = std.ArrayList(LaneSmokeRunSummary).empty;
        defer round_results.deinit(allocator);
        _ = try runLaneSmokeSuite(
            allocator,
            io,
            parsed,
            parsed.smoke_runs_per_round,
            smokeSuiteFirstRunNumber(all_results.items.len),
            &round_results,
        );
        for (round_results.items) |result| {
            if (result.failure_code) |code| last_failure_code = code;
            try all_results.append(allocator, result);
        }
        observed_consecutive = maxConsecutiveSmokePasses(all_results.items);
    }

    const promoted = observed_consecutive >= parsed.smoke_required_consecutive_passes;
    if (parsed.json) {
        try printSmokePromotionJson(
            allocator,
            if (promoted) "promoted" else "not_promoted",
            parsed.cwd.?,
            rounds_run,
            parsed.smoke_required_consecutive_passes,
            observed_consecutive,
            last_failure_code,
            promoted,
            all_results.items,
        );
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cas_review_session lane smoke-until-fixed\nstatus: {s}\nrounds: {d}\nobserved consecutive passes: {d}\n", .{
            if (promoted) "promoted" else "not_promoted",
            rounds_run,
            observed_consecutive,
        });
    }
    if (!promoted) std.process.exit(1);
}

fn runLaneSmokeSuite(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: ParsedArgs,
    runs: u32,
    first_run_number: u32,
    results: *std.ArrayList(LaneSmokeRunSummary),
) !u32 {
    const delays = try parseSmokeDelayScheduleAlloc(allocator, parsed.smoke_delay_ms);
    defer allocator.free(delays);
    const hooks = try parseSmokeHookScheduleAlloc(allocator, parsed.smoke_hooks);
    defer {
        for (hooks) |hook| allocator.free(hook);
        allocator.free(hooks);
    }

    var max_consecutive: u32 = 0;
    var current_consecutive: u32 = 0;
    var i: u32 = 0;
    while (i < runs) : (i += 1) {
        const hook = hooks[@as(usize, @intCast(i)) % hooks.len];
        const delay_ms = delays[@as(usize, @intCast(i)) % delays.len];
        const result = try runLaneSmokeChild(allocator, io, parsed, first_run_number + i, hook, delay_ms);
        const passed = laneSmokeRunPassesSuite(result);
        if (passed) {
            current_consecutive += 1;
            max_consecutive = @max(max_consecutive, current_consecutive);
        } else {
            current_consecutive = 0;
        }
        try results.append(allocator, result);
    }
    return max_consecutive;
}

fn runLaneSmokeChild(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: ParsedArgs,
    run_number: u32,
    hook_policy: []const u8,
    delay_ms: u32,
) !LaneSmokeRunSummary {
    if (delay_ms > 0) {
        std.Io.sleep(io, .fromMilliseconds(delay_ms), .awake) catch {};
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ parsed.executable_path, "lane", "smoke", "--cwd", parsed.cwd.?, "--json", "--hooks", hook_policy, "--fallback", "none" });
    try appendSmokeChildRuntimeCliArgs(allocator, &argv, parsed);
    try appendTargetCliArgs(allocator, &argv, parsed);
    if (!parsed.lane_smoke_wait) try argv.append(allocator, "--no-wait");
    if (parsed.lane_smoke_cleanup) try argv.append(allocator, "--cleanup");
    const override_reason = try std.fmt.allocPrint(allocator, "cas-smoke-suite:{d}", .{run_number});
    defer allocator.free(override_reason);
    try argv.appendSlice(allocator, &.{ "--review-lock-override", override_reason });
    const timeout_arg = try std.fmt.allocPrint(allocator, "{d}", .{parsed.timeout_ms});
    defer allocator.free(timeout_arg);
    const poll_arg = try std.fmt.allocPrint(allocator, "{d}", .{parsed.poll_interval_ms});
    defer allocator.free(poll_arg);
    try argv.appendSlice(allocator, &.{ "--timeout-ms", timeout_arg, "--poll-interval-ms", poll_arg });

    const child = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .inherit,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(child.stderr);
    defer allocator.free(child.stdout);
    const exit_code: u8 = switch (child.term) {
        .exited => |code| @intCast(@min(code, 255)),
        .signal => |signal| @intCast(@min(@as(u32, 128) + @intFromEnum(signal), @as(u32, 255))),
        .stopped, .unknown => 1,
    };
    const run_id = try smokeRunIdAlloc(allocator, run_number);
    errdefer allocator.free(run_id);
    var summary = try smokeRunSummaryFromJsonAlloc(allocator, run_id, hook_policy, delay_ms, exit_code, child.stdout, child.stderr);
    errdefer summary.deinit(allocator);
    releaseSmokeChildTupleLockBestEffort(allocator, summary);
    if (summary.lane_id) |lane_id| stopSmokeChildLaneBestEffort(allocator, io, parsed, lane_id);
    return summary;
}

fn releaseSmokeChildTupleLockBestEffort(allocator: std.mem.Allocator, summary: LaneSmokeRunSummary) void {
    const review_thread_id = summary.review_thread_id orelse return;
    const locks_dir = reviewTupleLocksDirAlloc(allocator) catch return;
    defer allocator.free(locks_dir);
    var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), locks_dir, .{ .iterate = true }) catch return;
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var it = dir.iterate();
    while (it.next(std.Io.Threaded.global_single_threaded.io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const lock_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ locks_dir, entry.name }) catch continue;
        defer allocator.free(lock_path);
        var loaded = (loadReviewTupleLock(allocator, lock_path) catch null) orelse continue;
        defer loaded.deinit(allocator);
        if (!smokeChildTupleLockReleasable(loaded.record, review_thread_id)) continue;
        std.Io.Dir.deleteFileAbsolute(std.Io.Threaded.global_single_threaded.io(), lock_path) catch {};
        return;
    }
}

fn smokeChildTupleLockReleasable(lock: ReviewTupleLock, review_thread_id: []const u8) bool {
    if (!std.mem.eql(u8, lock.reviewThreadId orelse "", review_thread_id)) return false;
    if (!isSmokeSuiteOverride(lock.overrideReason)) return false;
    if (std.mem.eql(u8, lock.state, "account_resource_exhausted")) return false;
    if (std.mem.eql(u8, lock.lastFailureCode orelse "", "wait_timed_out")) return false;
    return std.mem.eql(u8, lock.state, "terminal") or std.mem.eql(u8, lock.state, "normalized");
}

fn stopSmokeChildLaneBestEffort(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs, lane_id: []const u8) void {
    const argv = [_][]const u8{ parsed.executable_path, "lane", "stop", "--lane-id", lane_id, "--json" };
    const child = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .inherit,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return;
    allocator.free(child.stdout);
    allocator.free(child.stderr);
}

fn smokeSuiteFirstRunNumber(completed_results_count: usize) u32 {
    return @as(u32, @intCast(completed_results_count)) + 1;
}

fn smokeRunIdAlloc(allocator: std.mem.Allocator, run_number: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "smoke-{d:0>3}", .{run_number});
}

fn appendSmokeChildRuntimeCliArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), parsed: ParsedArgs) !void {
    if (parsed.read_only) try argv.append(allocator, "--read-only");
    if (parsed.exec_approval) |value| try argv.appendSlice(allocator, &.{ "--exec-approval", value });
    if (parsed.file_approval) |value| try argv.appendSlice(allocator, &.{ "--file-approval", value });
    if (parsed.permissions_approval) |value| try argv.appendSlice(allocator, &.{ "--permissions-approval", value });
    if (parsed.request_user_input_response_json) |value| try argv.appendSlice(allocator, &.{ "--request-user-input-response-json", value });
    if (parsed.elicitation_action) |value| try argv.appendSlice(allocator, &.{ "--elicitation-action", value });
    if (parsed.elicitation_content_json) |value| try argv.appendSlice(allocator, &.{ "--elicitation-content-json", value });
    if (parsed.dynamic_tool_response_json) |value| try argv.appendSlice(allocator, &.{ "--dynamic-tool-response-json", value });
    if (parsed.multi_agent_mode) |mode| try argv.appendSlice(allocator, &.{ "--multi-agent-mode", mode.configValue() });
}

fn appendTargetCliArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), parsed: ParsedArgs) !void {
    const target = parsed.target.?;
    switch (target.kind) {
        .uncommitted => try argv.append(allocator, "--uncommitted"),
        .base_branch => try argv.appendSlice(allocator, &.{ "--base", target.branch.? }),
        .commit => {
            try argv.appendSlice(allocator, &.{ "--commit", target.sha.? });
            if (target.title) |title| try argv.appendSlice(allocator, &.{ "--title", title });
        },
        .custom => {},
    }
    if (target.instructions) |instructions| {
        try argv.appendSlice(allocator, &.{ "--custom-instructions", instructions });
    }
}

fn parseSmokeDelayScheduleAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u32 {
    var values = std.ArrayList(u32).empty;
    defer values.deinit(allocator);
    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) return error.InvalidSmokeDelaySchedule;
        try values.append(allocator, try std.fmt.parseInt(u32, part, 10));
    }
    if (values.items.len == 0) return error.InvalidSmokeDelaySchedule;
    return values.toOwnedSlice(allocator);
}

fn parseSmokeHookScheduleAlloc(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var values = std.ArrayList([]const u8).empty;
    defer values.deinit(allocator);
    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) return error.InvalidHooksPolicy;
        _ = cas.hooks.HookPolicy.parse(part) orelse return error.InvalidHooksPolicy;
        try values.append(allocator, try allocator.dupe(u8, part));
    }
    if (values.items.len == 0) return error.InvalidHooksPolicy;
    return values.toOwnedSlice(allocator);
}

fn smokeRunSummaryFromJsonAlloc(
    allocator: std.mem.Allocator,
    run_id: []const u8,
    hook_policy: []const u8,
    delay_ms: u32,
    exit_code: u8,
    stdout_json: []const u8,
    stderr_text: []const u8,
) !LaneSmokeRunSummary {
    const trimmed = std.mem.trim(u8, stdout_json, " \t\r\n");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return .{
            .run_id = run_id,
            .hook_policy = try allocator.dupe(u8, hook_policy),
            .delay_ms = delay_ms,
            .status = try allocator.dupe(u8, "fail"),
            .review_attempt_phase = null,
            .failure_code = try allocator.dupe(u8, if (stderr_text.len > 0) "lane_smoke_failed" else "review_output_missing"),
            .review_verdict_status = null,
            .finding_count = 0,
            .review_attempt_exists = false,
            .tuple_verdict_exists = false,
            .lane_id = null,
            .review_thread_id = null,
            .base_sha = null,
            .head_sha = null,
            .target_fingerprint = null,
            .receipt_path = null,
            .exit_code = exit_code,
        };
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidSmokeOutput,
    };
    const status = core_json.stringField(obj, "status") orelse if (std.mem.eql(u8, core_json.stringField(obj, "smokeStatus") orelse "", "passed")) "pass" else "fail";
    const receipt_path = core_json.stringField(obj, "recordPath") orelse core_json.stringField(obj, "smokeRecordPath");
    const verdict_status = core_json.stringField(obj, "reviewVerdictStatus") orelse if (obj.get("reviewVerdict")) |verdict_value| switch (verdict_value) {
        .object => |verdict| core_json.stringField(verdict, "status"),
        else => null,
    } else null;
    const finding_count = jsonUsizeField(obj, "findingCount") orelse if (obj.get("reviewVerdict")) |verdict_value| switch (verdict_value) {
        .object => |verdict| jsonUsizeField(verdict, "findingCount"),
        else => null,
    } else null;
    return .{
        .run_id = run_id,
        .hook_policy = try allocator.dupe(u8, hook_policy),
        .delay_ms = delay_ms,
        .status = try allocator.dupe(u8, status),
        .review_attempt_phase = try dupOptional(allocator, core_json.stringField(obj, "reviewAttemptPhase")),
        .failure_code = try dupOptional(allocator, core_json.stringField(obj, "failureCode")),
        .review_verdict_status = try dupOptional(allocator, verdict_status),
        .finding_count = finding_count orelse 0,
        .review_attempt_exists = jsonBoolField(obj, "reviewAttemptExists") orelse false,
        .tuple_verdict_exists = jsonBoolField(obj, "tupleVerdictExists") orelse false,
        .lane_id = try dupOptional(allocator, core_json.stringField(obj, "laneId")),
        .review_thread_id = try dupOptional(allocator, core_json.stringField(obj, "reviewThreadId")),
        .base_sha = try dupOptional(allocator, core_json.stringField(obj, "baseSha")),
        .head_sha = try dupOptional(allocator, core_json.stringField(obj, "headSha")),
        .target_fingerprint = try dupOptional(allocator, core_json.stringField(obj, "targetFingerprint")),
        .receipt_path = try dupOptional(allocator, receipt_path),
        .exit_code = exit_code,
    };
}

fn laneSmokeRunPassesSuite(result: LaneSmokeRunSummary) bool {
    if (!std.mem.eql(u8, result.status, "pass")) return false;
    if (!result.review_attempt_exists) return false;
    if (std.mem.eql(u8, result.failure_code orelse "", "pre_review_lane_transport_lost")) return false;
    return result.tuple_verdict_exists;
}

fn maxConsecutiveSmokePasses(results: []const LaneSmokeRunSummary) u32 {
    var max_consecutive: u32 = 0;
    var current_consecutive: u32 = 0;
    for (results) |result| {
        if (laneSmokeRunPassesSuite(result)) {
            current_consecutive += 1;
            max_consecutive = @max(max_consecutive, current_consecutive);
        } else {
            current_consecutive = 0;
        }
    }
    return max_consecutive;
}

fn printSmokeSuiteJson(
    allocator: std.mem.Allocator,
    suite_version: []const u8,
    status: []const u8,
    parsed: ParsedArgs,
    runs_requested: u32,
    max_consecutive_passes: u32,
    persistent_lane_canonical: bool,
    canonical_review_backend: []const u8,
    results: []const LaneSmokeRunSummary,
) !void {
    _ = allocator;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeByte('{');
    try writeJsonString(stdout, "suiteVersion");
    try stdout.writeByte(':');
    try writeJsonString(stdout, suite_version);
    try stdout.writeAll(",\"status\":");
    try writeJsonString(stdout, status);
    try stdout.writeAll(",\"cwd\":");
    try writeJsonString(stdout, parsed.cwd.?);
    try stdout.writeAll(",\"base\":");
    if (parsed.target.?.branch) |branch| try writeJsonString(stdout, branch) else try stdout.writeAll("null");
    try stdout.print(",\"runsRequested\":{d},\"requiredConsecutivePasses\":{d},\"maxConsecutivePasses\":{d},\"persistentLaneCanonical\":{s},\"canonicalReviewBackend\":", .{
        runs_requested,
        parsed.smoke_required_consecutive_passes,
        max_consecutive_passes,
        if (persistent_lane_canonical) "true" else "false",
    });
    try writeJsonString(stdout, canonical_review_backend);
    try stdout.writeAll(",\"results\":[");
    for (results, 0..) |result, idx| {
        if (idx != 0) try stdout.writeByte(',');
        try writeSmokeRunJson(stdout, result);
    }
    try stdout.writeAll("]}\n");
}

fn printSmokePromotionJson(
    allocator: std.mem.Allocator,
    status: []const u8,
    cwd: []const u8,
    rounds_run: u32,
    required_consecutive_passes: u32,
    observed_consecutive_passes: u32,
    last_failure_code: ?[]const u8,
    promoted: bool,
    results: []const LaneSmokeRunSummary,
) !void {
    _ = allocator;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeByte('{');
    try stdout.writeAll("\"promotionVersion\":\"CAS-RSP-v1\",\"status\":");
    try writeJsonString(stdout, status);
    try stdout.writeAll(",\"cwd\":");
    try writeJsonString(stdout, cwd);
    try stdout.print(",\"roundsRun\":{d},\"requiredConsecutivePasses\":{d},\"observedConsecutivePasses\":{d},\"lastFailureCode\":", .{
        rounds_run,
        required_consecutive_passes,
        observed_consecutive_passes,
    });
    try writeNullableJsonString(stdout, last_failure_code);
    try stdout.writeAll(",\"finalBackendPolicy\":{\"persistentLaneCanonical\":");
    try stdout.writeAll(if (promoted) "true" else "false");
    try stdout.writeAll(",\"canonicalReviewBackend\":");
    try writeJsonString(stdout, if (promoted) "cas-lane" else "cas-start-wait-normalized");
    try stdout.writeAll(",\"fallbackReviewBackend\":");
    try writeJsonString(stdout, if (promoted) "cas-start-wait-normalized" else "cas-native-fallback-explicit-only");
    try stdout.writeAll("},\"evidenceRefs\":[");
    var wrote_ref = false;
    for (results) |result| {
        if (result.receipt_path) |path| {
            if (wrote_ref) try stdout.writeByte(',');
            try writeJsonString(stdout, path);
            wrote_ref = true;
        }
    }
    try stdout.writeAll("],\"results\":[");
    for (results, 0..) |result, idx| {
        if (idx != 0) try stdout.writeByte(',');
        try writeSmokeRunJson(stdout, result);
    }
    try stdout.writeAll("]}\n");
}

fn writeSmokeRunJson(writer: *std.Io.Writer, result: LaneSmokeRunSummary) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"runId\":");
    try writeJsonString(writer, result.run_id);
    try writer.writeAll(",\"hookPolicy\":");
    try writeJsonString(writer, result.hook_policy);
    try writer.print(",\"delayMs\":{d},\"status\":", .{result.delay_ms});
    try writeJsonString(writer, result.status);
    try writer.writeAll(",\"failureCode\":");
    try writeNullableJsonString(writer, result.failure_code);
    try writer.writeAll(",\"reviewVerdictStatus\":");
    try writeNullableJsonString(writer, result.review_verdict_status);
    try writer.print(",\"findingCount\":{d}", .{result.finding_count});
    try writer.writeAll(",\"reviewAttemptPhase\":");
    try writeNullableJsonString(writer, result.review_attempt_phase);
    try writer.writeAll(",\"reviewAttemptExists\":");
    try writer.writeAll(if (result.review_attempt_exists) "true" else "false");
    try writer.writeAll(",\"tupleVerdictExists\":");
    try writer.writeAll(if (result.tuple_verdict_exists) "true" else "false");
    try writer.writeAll(",\"laneId\":");
    try writeNullableJsonString(writer, result.lane_id);
    try writer.writeAll(",\"reviewThreadId\":");
    try writeNullableJsonString(writer, result.review_thread_id);
    try writer.writeAll(",\"baseSha\":");
    try writeNullableJsonString(writer, result.base_sha);
    try writer.writeAll(",\"headSha\":");
    try writeNullableJsonString(writer, result.head_sha);
    try writer.writeAll(",\"targetFingerprint\":");
    try writeNullableJsonString(writer, result.target_fingerprint);
    try writer.writeAll(",\"receiptPath\":");
    try writeNullableJsonString(writer, result.receipt_path);
    try writer.print(",\"exitCode\":{d}", .{result.exit_code});
    try writer.writeByte('}');
}

fn writeLaneSessionCasRerShadowAlloc(
    allocator: std.mem.Allocator,
    record_path: []const u8,
    identity: TargetIdentity,
    broker_reason: []const u8,
) ![]const u8 {
    const normalized = try normalizeReceiptFromPathAlloc(allocator, record_path, true, .{
        .requested_identity = identity,
        .requested_identity_required = true,
    });
    defer normalized.deinit(allocator);
    const timestamp = try casRerTimestampAlloc(allocator);
    defer allocator.free(timestamp);
    return writeCasRerShadowRecordFromReceipt(allocator, normalized, .{
        .command_surface = "lane_review",
        .backend_selected = "cas-lane",
        .broker_action = "created_new",
        .broker_reason = broker_reason,
        .imported_from_receipt = false,
        .tuple_current_at_record_time = true,
        .created_at = timestamp,
        .updated_at = timestamp,
    });
}

fn cmdLaneReview(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedArgs) !void {
    var loaded_workflow_binding = try loadWorkflowBindingAlloc(allocator, parsed.workflow_binding_arg);
    defer if (loaded_workflow_binding) |*binding| binding.deinit();
    const workflow_binding = if (loaded_workflow_binding) |binding| binding.value else null;
    var loaded = try loadLaneRecord(allocator, parsed.lane_id.?);
    defer loaded.deinit(allocator);
    var lane = loaded.record;
    const target = parsed.target.?;
    const target_record = targetToRecord(target);
    var identity = try computeTargetIdentityAlloc(allocator, io, lane.cwd, target_record);
    defer identity.deinit(allocator);

    if (!cas_websocket.processAlive(lane.managed_server_pid)) {
        try emitPreReviewLaneTransportLostAndExit(
            allocator,
            parsed.json,
            "lane-review",
            "review/start",
            "persistent CAS lane app-server is not alive",
            "restart the CAS review lane, run lane smoke, or use an explicit fallback command after tuple-lock checks",
            lane,
            loaded.record_path,
            target_record,
            identity,
            workflow_binding,
            false,
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
        try emitPreReviewLaneTransportLostAndExit(
            allocator,
            parsed.json,
            "lane-review",
            "review/start",
            @errorName(err),
            "persistent CAS lane websocket could not be reconnected; restart the lane, run lane smoke, or use explicit fallback after tuple-lock checks",
            lane,
            loaded.record_path,
            target_record,
            identity,
            workflow_binding,
            cas_websocket.processAlive(lane.managed_server_pid),
        );
    };
    defer {
        client.close();
        client.deinit();
    }

    var review_tuple = try reviewTupleIdentityAlloc(allocator, lane.cwd, identity, lane.resolved_codex_path, lane.codex_version, &client, workflow_binding);
    defer review_tuple.deinit(allocator);
    const tuple_lock_bundle = try acquireReviewTupleStartLockOrExit(
        allocator,
        parsed.json,
        "lane-review",
        identity,
        review_tuple,
        parsed.review_lock_override_reason,
        parsed.fresh_attempt_reason,
        parsed.verdict_only,
        null,
    );
    defer tuple_lock_bundle.deinit(allocator);

    const session_dir = try sessionDirAlloc(allocator);
    const parent_thread_id = startParentThreadAlloc(allocator, &client, lane.cwd, session_dir, parsed.multi_agent_mode) catch |err| {
        if (isTransportLossError(err)) {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_lane_transport_lost", null, null, null, null);
            try emitPreReviewLaneTransportLostAndExit(
                allocator,
                parsed.json,
                "lane-review",
                "thread/start",
                @errorName(err),
                "persistent CAS lane websocket was lost while starting a fresh parent; restart the lane, run lane smoke, or use explicit fallback after tuple-lock checks",
                lane,
                loaded.record_path,
                target_record,
                identity,
                workflow_binding,
                cas_websocket.processAlive(lane.managed_server_pid),
            );
        }
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "review_failed", null, null, null, null);
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
            parsed.multi_agent_mode,
        ) catch |err| {
            if (isTransportLossError(err)) {
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_lane_transport_lost", null, null, null, parent_event_log_path);
                try emitPreReviewLaneTransportLostAndExit(
                    allocator,
                    parsed.json,
                    "lane-review",
                    "turn/start",
                    @errorName(err),
                    "persistent CAS lane websocket was lost while materializing a fresh parent; restart the lane, run lane smoke, or use explicit fallback after tuple-lock checks",
                    lane,
                    loaded.record_path,
                    target_record,
                    identity,
                    workflow_binding,
                    cas_websocket.processAlive(lane.managed_server_pid),
                );
            }
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "review_failed", null, null, null, parent_event_log_path);
            return err;
        };
    }

    const review_params_json = try buildReviewStartParamsJson(allocator, parent_thread_id, target);
    defer allocator.free(review_params_json);
    const review_result_json = client.requestJson("review/start", review_params_json) catch |err| {
        if (isTransportLossError(err)) {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "pre_review_lane_transport_lost", null, null, null, parent_event_log_path);
            try emitPreReviewLaneTransportLostAndExit(
                allocator,
                parsed.json,
                "lane-review",
                "review/start",
                @errorName(err),
                "review/start could not be reached because CAS lane transport was lost; restart the lane, run lane smoke, or use explicit fallback after tuple-lock checks",
                lane,
                loaded.record_path,
                target_record,
                identity,
                workflow_binding,
                cas_websocket.processAlive(lane.managed_server_pid),
            );
        }
        if (parsed.fallback_mode == .native_review) {
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "review_failed", null, null, null, parent_event_log_path);
            var fallback = try runNativeReviewFallbackAlloc(allocator, lane.cwd, lane.resolved_codex_path, target_record);
            defer fallback.deinit(allocator);
            try printLaneFallbackJson(allocator, lane, loaded.record_path, target_record, identity, fallback, .{
                .code = "review_failed",
                .hint = "lane review startup failed; returned explicit native-review fallback",
            }, workflow_binding, parsed.multi_agent_mode, parsed.verdict_only);
            std.process.exit(if (fallback.ok) 0 else 1);
        }
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "pre_review_start_failed", "review_failed", null, null, null, parent_event_log_path);
        return err;
    };
    defer allocator.free(review_result_json);

    const review_thread_id = try extractReviewThreadIdAlloc(allocator, review_result_json);
    const review_turn_id = try extractReviewTurnIdAlloc(allocator, review_result_json);
    const event_log_path = try std.fmt.allocPrint(allocator, "{s}/{s}.events.ndjson", .{ session_dir, review_thread_id });
    const record_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, review_thread_id });
    try appendLogRecord(allocator, event_log_path, "review/start", "request", review_params_json);
    try appendLogRecord(allocator, event_log_path, "review/start", "response", review_result_json);
    const store_root = try casStoreRootAlloc(allocator);
    defer allocator.free(store_root);
    const repo_root = try repoRootForCwdAlloc(allocator, lane.cwd);
    defer if (repo_root) |root| allocator.free(root);

    var record = SessionRecord{
        .cwd = lane.cwd,
        .store_root = store_root,
        .store_scope = "repo-local",
        .repo_root = repo_root,
        .codex_thread_id = review_tuple.codex_thread_id,
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
        .base_sha = identity.base_sha,
        .head_sha = identity.head_sha,
        .target_fingerprint = identity.fingerprint,
        .accountFingerprint = review_tuple.account_fingerprint,
        .accountFingerprintReducedProtection = review_tuple.account_fingerprint_reduced_protection,
        .workflowBinding = workflow_binding,
    };
    try writeSessionRecord(allocator, record_path, record);
    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "review_started", null, review_thread_id, review_turn_id, record_path, event_log_path);
    updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", null, review_thread_id, review_turn_id, record_path, event_log_path);

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
            updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", "wait_timed_out", review_thread_id, review_turn_id, record_path, event_log_path);
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
            const shadow_record_path = try writeLaneSessionCasRerShadowAlloc(
                allocator,
                record_path,
                identity,
                "lane review wait timed out",
            );
            defer allocator.free(shadow_record_path);
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
                workflow_binding,
                parsed.multi_agent_mode,
                parsed.verdict_only,
            );
            std.process.exit(1);
        },
        else => {
            if (parsed.fallback_mode == .native_review and isTransportLossError(err)) {
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", "review_transport_lost", review_thread_id, review_turn_id, record_path, event_log_path);
                var fallback = try runNativeReviewFallbackAlloc(allocator, lane.cwd, lane.resolved_codex_path, target_record);
                defer fallback.deinit(allocator);
                try printLaneFallbackJson(allocator, lane, loaded.record_path, target_record, identity, fallback, .{
                    .code = "lane_transport_lost",
                    .hint = "persistent CAS lane websocket was lost while waiting; returned explicit native-review fallback",
                }, workflow_binding, parsed.multi_agent_mode, parsed.verdict_only);
                std.process.exit(if (fallback.ok) 0 else 1);
            }
            if (isTransportLossError(err)) {
                updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "waiting", "review_transport_lost", review_thread_id, review_turn_id, record_path, event_log_path);
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
    persistTerminalReviewResult(&record, latest);
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
        failureInfoForStatus(&latest) orelse .{
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
    else if (!identityHasCompleteTuple(identity))
        tupleIdentityUnavailableFailureInfo()
    else
        null;

    if (lane_failure != null) {
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, if (std.mem.eql(u8, lane_failure.?.code, "account_resource_exhausted")) "account_resource_exhausted" else "terminal", lane_failure.?.code, review_thread_id, review_turn_id, record_path, event_log_path);
        if (parsed.fallback_mode == .native_review) {
            var fallback = try runNativeReviewFallbackAlloc(allocator, lane.cwd, lane.resolved_codex_path, target_record);
            defer fallback.deinit(allocator);
            try printLaneFallbackJson(allocator, lane, loaded.record_path, target_record, identity, fallback, lane_failure.?, workflow_binding, parsed.multi_agent_mode, parsed.verdict_only);
            std.process.exit(if (fallback.ok) 0 else 1);
        }
    }

    const finding_count = try reviewFindingCount(allocator, latest.review_result_json);
    const clean = lane_failure == null and finding_count == 0;
    if (lane_failure == null) {
        updateReviewTupleLockBestEffort(allocator, tuple_lock_bundle.path, tuple_lock_bundle.lock, "normalized", null, review_thread_id, review_turn_id, record_path, event_log_path);
        const shadow_record_path = try writeLaneSessionCasRerShadowAlloc(
            allocator,
            record_path,
            identity,
            "lane review reached a normalized terminal verdict",
        );
        defer allocator.free(shadow_record_path);
    }
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
        workflow_binding,
        parsed.multi_agent_mode,
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
            .reviewAttemptPhase = laneReceiptPhase(alive, lane.last_review_thread_id),
            .reviewAttemptExists = reviewAttemptExists(lane.last_review_thread_id),
            .tupleVerdictExists = false,
            .reviewThreadId = lane.last_review_thread_id,
            .reviewTurnId = lane.last_review_turn_id,
            .baseSha = lane.last_base_sha,
            .headSha = lane.last_head_sha,
            .targetFingerprint = lane.last_target_fingerprint,
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
            .reviewAttemptPhase = laneReceiptPhase(false, lane.last_review_thread_id),
            .reviewAttemptExists = reviewAttemptExists(lane.last_review_thread_id),
            .tupleVerdictExists = false,
            .reviewThreadId = lane.last_review_thread_id,
            .reviewTurnId = lane.last_review_turn_id,
            .baseSha = lane.last_base_sha,
            .headSha = lane.last_head_sha,
            .targetFingerprint = lane.last_target_fingerprint,
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
            defer allocator.free(fallback_json);
            if (live_notifications) |state| {
                try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
            }
            try appendLogRecord(allocator, event_log_path, "thread/read", "response", fallback_json);
            var status = try parseReviewStatusAlloc(allocator, fallback_json, false);
            try populateReviewResult(allocator, &status);
            try populateReviewResultFromLiveNotifications(allocator, &status, live_notifications);
            if (try maybeResumeMaterializedThread(allocator, client, review_thread_id, event_log_path, &status)) {
                status.deinit(allocator);
                for (captured_notifications.items) |line| allocator.free(line);
                captured_notifications.clearRetainingCapacity();
                const resumed_json = if (live_notifications != null)
                    try client.requestJsonCaptureNotifications("thread/read", fallback_params, &captured_notifications)
                else
                    try client.requestJson("thread/read", fallback_params);
                defer allocator.free(resumed_json);
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
    defer allocator.free(response_json);
    if (live_notifications) |state| {
        try absorbLiveReviewNotifications(allocator, &captured_notifications, event_log_path, state);
    }
    try appendLogRecord(allocator, event_log_path, "thread/read", "response", response_json);
    var status = try parseReviewStatusAlloc(allocator, response_json, true);
    try populateReviewResult(allocator, &status);
    try populateReviewResultFromLiveNotifications(allocator, &status, live_notifications);
    if (try maybeResumeMaterializedThread(allocator, client, review_thread_id, event_log_path, &status)) {
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

fn buildTurnStartParamsJson(
    allocator: std.mem.Allocator,
    thread_id: []const u8,
    text: []const u8,
    multi_agent_mode: ?cas.MultiAgentMode,
) ![]u8 {
    const thread_id_json = try quoteJsonStringAlloc(allocator, thread_id);
    defer allocator.free(thread_id_json);
    const text_json = try quoteJsonStringAlloc(allocator, text);
    defer allocator.free(text_json);
    if (multi_agent_mode) |mode| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"threadId\":{s},\"input\":[{{\"type\":\"text\",\"text\":{s}}}],\"multiAgentMode\":\"{s}\"}}",
            .{ thread_id_json, text_json, mode.wireValue() },
        );
    }
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
    multi_agent_mode: ?cas.MultiAgentMode,
) !void {
    const params_json = try buildTurnStartParamsJson(
        allocator,
        parent_thread_id,
        parent_materialization_prompt,
        multi_agent_mode,
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
    const status = gitOutputRawAllocLimited(allocator, io, cwd, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=all" }, 16 * 1024 * 1024) catch try allocator.dupe(u8, "");
    defer allocator.free(status);
    hasher.update("status\x00");
    hasher.update(status);

    const diff = gitOutputRawAllocLimited(allocator, io, cwd, &.{ "diff", "--binary", "HEAD", "--" }, 64 * 1024 * 1024) catch try allocator.dupe(u8, "");
    defer allocator.free(diff);
    hasher.update("diff-head\x00");
    hasher.update(diff);

    const staged = gitOutputRawAllocLimited(allocator, io, cwd, &.{ "diff", "--binary", "--cached", "HEAD", "--" }, 64 * 1024 * 1024) catch try allocator.dupe(u8, "");
    defer allocator.free(staged);
    hasher.update("diff-cached\x00");
    hasher.update(staged);

    const untracked = gitOutputRawAllocLimited(allocator, io, cwd, &.{ "ls-files", "--others", "--exclude-standard", "-z" }, 16 * 1024 * 1024) catch try allocator.dupe(u8, "");
    defer allocator.free(untracked);
    var iter = std.mem.splitScalar(u8, untracked, 0);
    while (iter.next()) |path| {
        if (path.len == 0) continue;
        hasher.update("untracked\x00");
        hasher.update(path);
        hasher.update("\x00");
        const absolute_path = try std.fs.path.join(allocator, &.{ cwd, path });
        defer allocator.free(absolute_path);
        const bytes = readFileAlloc(allocator, absolute_path, 16 * 1024 * 1024) catch |err| {
            hasher.update("untracked-read-error\x00");
            hasher.update(@errorName(err));
            continue;
        };
        defer allocator.free(bytes);
        hasher.update(bytes);
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex});
}

fn computeTargetIdentityAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    target: TargetRecord,
) !TargetIdentity {
    const current_head_sha = gitOutputAlloc(allocator, io, cwd, &.{ "rev-parse", "HEAD" }) catch null;
    defer if (current_head_sha) |value| allocator.free(value);
    const dirty_digest = if (std.mem.eql(u8, target.type, "uncommittedChanges"))
        try dirtyStateDigestAlloc(allocator, io, cwd)
    else
        null;
    defer if (dirty_digest) |value| allocator.free(value);
    const head_sha = if (std.mem.eql(u8, target.type, "commit") and target.sha != null)
        try allocator.dupe(u8, target.sha.?)
    else if (std.mem.eql(u8, target.type, "uncommittedChanges"))
        try std.fmt.allocPrint(allocator, "{s}+dirty:{s}", .{ current_head_sha orelse "unknown", dirty_digest.? })
    else if (current_head_sha) |sha|
        try allocator.dupe(u8, sha)
    else
        null;
    const commit_parent_ref = if (std.mem.eql(u8, target.type, "commit") and target.sha != null)
        try std.fmt.allocPrint(allocator, "{s}^", .{target.sha.?})
    else
        null;
    defer if (commit_parent_ref) |value| allocator.free(value);
    const base_sha = if (std.mem.eql(u8, target.type, "baseBranch") and target.branch != null)
        gitOutputAlloc(allocator, io, cwd, &.{ "merge-base", "HEAD", target.branch.? }) catch null
    else if (std.mem.eql(u8, target.type, "commit") and target.sha != null)
        gitOutputAlloc(allocator, io, cwd, &.{ "rev-parse", commit_parent_ref.? }) catch null
    else if (std.mem.eql(u8, target.type, "uncommittedChanges") and current_head_sha != null)
        try allocator.dupe(u8, current_head_sha.?)
    else
        null;
    const target_json = try stringifyAnyAlloc(allocator, target);
    defer allocator.free(target_json);
    const fingerprint = if (dirty_digest) |digest|
        try std.fmt.allocPrint(allocator, "target={s};head={s};base={s};dirty={s}", .{
            target_json,
            head_sha orelse "unknown",
            base_sha orelse "unknown",
            digest,
        })
    else
        try std.fmt.allocPrint(allocator, "target={s};head={s};base={s}", .{
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

fn targetIdentityForRecordAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    record: SessionRecord,
) !TargetIdentity {
    if (record.target_fingerprint) |fingerprint| {
        return .{
            .head_sha = try dupOptional(allocator, record.head_sha),
            .base_sha = try dupOptional(allocator, record.base_sha),
            .fingerprint = try allocator.dupe(u8, fingerprint),
        };
    }
    return computeTargetIdentityAlloc(allocator, io, record.cwd, record.target);
}

fn appendNativeReviewArgs(allocator: std.mem.Allocator, args: *std.ArrayList([]const u8), target: TargetRecord) !void {
    if (target.instructions) |instructions| {
        try args.append(allocator, instructions);
        return;
    }
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
    return err == error.AppServerClosed or
        err == error.ConnectionRefused or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut or
        err == error.BrokenPipe or
        err == error.EndOfStream;
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
    multi_agent_mode: ?cas.MultiAgentMode,
) ![]const u8 {
    const params_json = try buildThreadStartParamsJson(allocator, cwd, multi_agent_mode);
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
    multi_agent_mode: ?cas.MultiAgentMode,
) ![]u8 {
    const cwd_json = try quoteJsonStringAlloc(allocator, cwd);
    defer allocator.free(cwd_json);
    if (multi_agent_mode) |mode| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"cwd\":{s},\"experimentalRawEvents\":false,\"multiAgentMode\":\"{s}\"}}",
            .{ cwd_json, mode.wireValue() },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"cwd\":{s},\"experimentalRawEvents\":false}}",
        .{cwd_json},
    );
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
    const parent_thread_id_json = try quoteJsonStringAlloc(allocator, parent_thread_id);
    defer allocator.free(parent_thread_id_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"threadId\":{s},\"delivery\":\"detached\",\"target\":{s}}}",
        .{ parent_thread_id_json, target_json },
    );
}

fn buildTargetJson(allocator: std.mem.Allocator, target: TargetConfig) ![]u8 {
    if (target.instructions) |instructions| {
        return stringifyAnyAlloc(allocator, .{ .type = "custom", .instructions = instructions });
    }
    return switch (target.kind) {
        .uncommitted => stringifyAnyAlloc(allocator, .{ .type = "uncommittedChanges" }),
        .base_branch => stringifyAnyAlloc(allocator, .{ .type = "baseBranch", .branch = target.branch.? }),
        .commit => stringifyAnyAlloc(allocator, .{ .type = "commit", .sha = target.sha.?, .title = target.title }),
        .custom => error.MissingCustomInstructions,
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

fn casRerRecordIdFromJsonAlloc(allocator: std.mem.Allocator, record_json: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidCasRerRecord,
    };
    const record_id = nonEmptyOptional(jsonStringField(root, "recordId")) orelse return error.MissingCasRerRecordId;
    if (!std.mem.startsWith(u8, record_id, "rer_")) return error.InvalidCasRerRecordId;
    if (std.mem.indexOfScalar(u8, record_id, '/') != null or std.mem.indexOfScalar(u8, record_id, '\\') != null) return error.InvalidCasRerRecordId;
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

fn jsonValueStableEqual(left: std.json.Value, right: std.json.Value, ignore_cas_rer_provenance: bool) bool {
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
                    if (!jsonValueStableEqual(left_item, right_item, ignore_cas_rer_provenance)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |left_object| switch (right) {
            .object => |right_object| jsonObjectStableEqual(left_object, right_object, ignore_cas_rer_provenance),
            else => false,
        },
    };
}

fn jsonObjectStableEqual(left: std.json.ObjectMap, right: std.json.ObjectMap, ignore_cas_rer_provenance: bool) bool {
    var left_count: usize = 0;
    var left_it = left.iterator();
    while (left_it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (ignore_cas_rer_provenance and casRerStableCompareIgnoredField(key)) continue;
        left_count += 1;
        const right_value = right.get(key) orelse return false;
        if (!jsonValueStableEqual(entry.value_ptr.*, right_value, ignore_cas_rer_provenance)) return false;
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

fn casRerStableContentMatchesAlloc(allocator: std.mem.Allocator, raw: []const u8, json: []const u8) !bool {
    var existing_parsed = std.json.parseFromSlice(std.json.Value, allocator, std.mem.trim(u8, raw, " \t\r\n"), .{}) catch return false;
    defer existing_parsed.deinit();
    var incoming_parsed = std.json.parseFromSlice(std.json.Value, allocator, std.mem.trim(u8, json, " \t\r\n"), .{}) catch return false;
    defer incoming_parsed.deinit();
    const existing = switch (existing_parsed.value) {
        .object => |obj| obj,
        else => return false,
    };
    const incoming = switch (incoming_parsed.value) {
        .object => |obj| obj,
        else => return false,
    };
    if (!std.mem.eql(u8, jsonStringField(existing, "schema") orelse "", cas_review_evidence_schema)) return false;
    if (!std.mem.eql(u8, jsonStringField(incoming, "schema") orelse "", cas_review_evidence_schema)) return false;
    if (!optionalStringsEqual(jsonStringField(existing, "recordId"), jsonStringField(incoming, "recordId"))) return false;
    return jsonObjectStableEqual(existing, incoming, true);
}

fn writeRawJsonFileExclusiveOrIdenticalAlloc(allocator: std.mem.Allocator, path: []const u8, json: []const u8) !void {
    const payload = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    defer allocator.free(payload);
    durable_store.writeTextCreateNewAtomic(allocator, path, payload, .{ .reject_symlinks = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const existing = try durable_store.readRegularFileNoSymlink(allocator, path, 8 * 1024 * 1024);
            defer allocator.free(existing);
            if (jsonFileContentMatches(existing, json)) return;
            if (try casRerStableContentMatchesAlloc(allocator, existing, json)) return;
            return error.CasRerRecordIdCollision;
        },
        else => return err,
    };
}

fn writeCasRerRecordJsonToLedgerAlloc(allocator: std.mem.Allocator, record_json: []const u8) ![]const u8 {
    const record_id = try casRerRecordIdFromJsonAlloc(allocator, record_json);
    defer allocator.free(record_id);
    const records_dir = try reviewLedgerRecordsDirAlloc(allocator);
    defer allocator.free(records_dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ records_dir, record_id });
    errdefer allocator.free(path);
    try writeRawJsonFileExclusiveOrIdenticalAlloc(allocator, path, record_json);
    return path;
}

const CasRerLedgerRecord = struct {
    path: []const u8,
    raw_json: []const u8,
    record_id: []const u8,
    created_at: []const u8,
    status: []const u8,
    phase: []const u8,
    tuple_verdict_exists: bool,
    attempt_exists: bool,
    failure_code: ?[]const u8,
    review_thread_id: ?[]const u8,
    base_sha: ?[]const u8,
    head_sha: ?[]const u8,
    target_fingerprint: ?[]const u8,
    principal_proof_usable: bool,
    context_identity_matches: bool = false,
    fresh_attempt_required: bool,

    fn deinit(self: CasRerLedgerRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.raw_json);
        allocator.free(self.record_id);
        allocator.free(self.created_at);
        allocator.free(self.status);
        allocator.free(self.phase);
        if (self.failure_code) |value| allocator.free(value);
        if (self.review_thread_id) |value| allocator.free(value);
        if (self.base_sha) |value| allocator.free(value);
        if (self.head_sha) |value| allocator.free(value);
        if (self.target_fingerprint) |value| allocator.free(value);
    }
};

fn workflowBindingObjectMatches(root: std.json.ObjectMap, expected: WorkflowBinding) bool {
    const value = root.get("workflowBinding") orelse return false;
    const actual = switch (value) {
        .object => |object| object,
        else => return false,
    };
    if (actual.count() != 2) return false;
    return std.mem.eql(u8, jsonStringField(actual, "requestId") orelse "", expected.requestId) and
        std.mem.eql(u8, jsonStringField(actual, "requestFingerprint") orelse "", expected.requestFingerprint);
}

fn casRerObjectMatchesHistoryScope(
    root: std.json.ObjectMap,
    repo_realpath: []const u8,
    identity: TargetIdentity,
    codex_thread_id: []const u8,
    workflow_binding_filter: ?WorkflowBinding,
) bool {
    const tuple = objectField(root, "tuple") orelse return false;
    const record_repo = jsonStringField(tuple, "repoRealpath") orelse return false;
    if (!std.mem.eql(u8, record_repo, repo_realpath)) return false;
    if (!optionalStringsEqual(jsonStringField(tuple, "baseSha"), identity.base_sha)) return false;
    if (!optionalStringsEqual(jsonStringField(tuple, "headSha"), identity.head_sha)) return false;
    if (!optionalStringsEqual(jsonStringField(tuple, "targetFingerprint"), identity.fingerprint)) return false;
    const record_has_binding = root.get("workflowBinding") != null and root.get("workflowBinding").? != .null;
    const record_codex_thread_id = jsonStringField(tuple, "codexThreadId");
    if (record_codex_thread_id) |value| {
        if (!std.mem.eql(u8, value, codex_thread_id)) return false;
    } else if (record_has_binding) {
        return false;
    }
    if (workflow_binding_filter) |expected| {
        if (record_codex_thread_id == null) return false;
        if (!workflowBindingObjectMatches(root, expected)) return false;
    }
    return true;
}

fn casRerObjectContextIdentityMatches(
    root: std.json.ObjectMap,
    repo_realpath: []const u8,
    identity: TargetIdentity,
    resolved_codex_path: []const u8,
    resolved_codex_version: []const u8,
    account_fingerprint: []const u8,
    account_fingerprint_reduced_protection: bool,
    codex_thread_id: []const u8,
    workflow_binding_filter: ?WorkflowBinding,
) bool {
    if (!casRerObjectMatchesHistoryScope(root, repo_realpath, identity, codex_thread_id, workflow_binding_filter)) return false;
    if (account_fingerprint_reduced_protection) return false;
    const tuple = objectField(root, "tuple") orelse return false;
    if (jsonBoolField(tuple, "tupleCurrentAtRecordTime") != true) return false;
    if (!optionalStringsEqual(jsonStringField(tuple, "resolvedCodexPath"), resolved_codex_path)) return false;
    if (!optionalStringsEqual(jsonStringField(tuple, "resolvedCodexVersion"), resolved_codex_version)) return false;
    if (!casRerPrincipalFingerprintUsable(account_fingerprint)) return false;
    const principal = objectField(root, "principal") orelse return false;
    const record_account_fingerprint = nonEmptyOptional(jsonStringField(principal, "accountFingerprint")) orelse return false;
    return std.mem.eql(u8, record_account_fingerprint, account_fingerprint);
}

fn casRerObjectMatchesIdentity(
    root: std.json.ObjectMap,
    repo_realpath: []const u8,
    identity: TargetIdentity,
    resolved_codex_path: []const u8,
    resolved_codex_version: []const u8,
    account_fingerprint: []const u8,
    account_fingerprint_reduced_protection: bool,
    codex_thread_id: []const u8,
) bool {
    return casRerObjectContextIdentityMatches(root, repo_realpath, identity, resolved_codex_path, resolved_codex_version, account_fingerprint, account_fingerprint_reduced_protection, codex_thread_id, null);
}

fn casRerPrincipalProofUsableObject(principal: ?std.json.ObjectMap) bool {
    const principal_obj = principal orelse return false;
    if (jsonBoolField(principal_obj, "proofUsable") != true) return false;
    if (!std.mem.eql(u8, jsonStringField(principal_obj, "kind") orelse "", "strong")) return false;
    if (jsonBoolField(principal_obj, "reduced") != false) return false;
    if (jsonBoolField(principal_obj, "fallbackUsed") != false) return false;
    if (std.mem.eql(u8, jsonStringField(principal_obj, "source") orelse "", "cas-native-fallback")) return false;
    return casRerPrincipalFingerprintUsable(jsonStringField(principal_obj, "accountFingerprint"));
}

fn casRerLedgerRecordFromJsonAlloc(allocator: std.mem.Allocator, path: []const u8, raw: []const u8) !CasRerLedgerRecord {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidCasRerRecord,
    };
    if (!std.mem.eql(u8, jsonStringField(root, "schema") orelse "", cas_review_evidence_schema)) return error.InvalidCasRerRecord;
    const tuple = objectField(root, "tuple");
    const attempt = objectField(root, "attempt");
    const verdict = objectField(root, "verdict");
    const failure = objectField(root, "failure");
    const principal = objectField(root, "principal");
    const command = objectField(root, "command");
    const broker = if (command) |value| objectField(value, "brokerDecision") else null;
    return .{
        .path = try allocator.dupe(u8, path),
        .raw_json = try allocator.dupe(u8, raw),
        .record_id = try allocator.dupe(u8, jsonStringField(root, "recordId") orelse ""),
        .created_at = try allocator.dupe(u8, jsonStringField(root, "createdAt") orelse ""),
        .status = try allocator.dupe(u8, if (verdict) |value| jsonStringField(value, "status") orelse "incomplete" else "incomplete"),
        .phase = try allocator.dupe(u8, if (attempt) |value| jsonStringField(value, "phase") orelse "" else ""),
        .tuple_verdict_exists = if (verdict) |value| jsonBoolField(value, "tupleVerdictExists") orelse false else false,
        .attempt_exists = if (attempt) |value| jsonBoolField(value, "exists") orelse false else false,
        .failure_code = if (failure) |value| try dupOptional(allocator, jsonStringField(value, "failureCode")) else null,
        .review_thread_id = if (attempt) |value| try dupOptional(allocator, jsonStringField(value, "reviewThreadId")) else null,
        .base_sha = if (tuple) |value| try dupOptional(allocator, jsonStringField(value, "baseSha")) else null,
        .head_sha = if (tuple) |value| try dupOptional(allocator, jsonStringField(value, "headSha")) else null,
        .target_fingerprint = if (tuple) |value| try dupOptional(allocator, jsonStringField(value, "targetFingerprint")) else null,
        .principal_proof_usable = casRerPrincipalProofUsableObject(principal),
        .fresh_attempt_required = if (broker) |value| jsonBoolField(value, "freshAttemptRequired") orelse false else false,
    };
}

fn appendCasRerLedgerRecordsAlloc(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(CasRerLedgerRecord),
    repo_realpath: ?[]const u8,
    identity: ?TargetIdentity,
    resolved_codex_path: ?[]const u8,
    resolved_codex_version: ?[]const u8,
    account_fingerprint: ?[]const u8,
    account_fingerprint_reduced_protection: ?bool,
    codex_thread_id: ?[]const u8,
    workflow_binding_filter: ?WorkflowBinding,
) !void {
    const records_dir = try reviewLedgerRecordsDirPathAlloc(allocator);
    defer allocator.free(records_dir);
    var dir = std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), records_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(std.Io.Threaded.global_single_threaded.io());

    var it = dir.iterate();
    while (try it.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ records_dir, entry.name });
        defer allocator.free(path);
        const raw = readFileAlloc(allocator, path, 8 * 1024 * 1024) catch continue;
        defer allocator.free(raw);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch continue;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        if (!std.mem.eql(u8, jsonStringField(root, "schema") orelse "", cas_review_evidence_schema)) continue;
        var validation = validateCasRerRecordObjectAlloc(allocator, path, root) catch continue;
        defer validation.deinit(allocator);
        if (!validation.ok()) continue;

        var context_identity_matches = false;
        if (repo_realpath != null and identity != null and resolved_codex_path != null and resolved_codex_version != null and account_fingerprint != null and account_fingerprint_reduced_protection != null and codex_thread_id != null) {
            if (!casRerObjectMatchesHistoryScope(root, repo_realpath.?, identity.?, codex_thread_id.?, workflow_binding_filter)) continue;
            context_identity_matches = casRerObjectContextIdentityMatches(root, repo_realpath.?, identity.?, resolved_codex_path.?, resolved_codex_version.?, account_fingerprint.?, account_fingerprint_reduced_protection.?, codex_thread_id.?, workflow_binding_filter);
        }
        var record = casRerLedgerRecordFromJsonAlloc(allocator, path, raw) catch continue;
        record.context_identity_matches = context_identity_matches;
        errdefer record.deinit(allocator);
        try out.append(allocator, record);
    }
}

fn daysFromCivil(year_raw: i64, month_raw: i64, day_raw: i64) i64 {
    var year = year_raw;
    const month = month_raw;
    const day = day_raw;
    const year_adjustment: i64 = if (month <= 2) 1 else 0;
    year -= year_adjustment;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const month_adjustment: i64 = if (month > 2) -3 else 9;
    const mp = month + month_adjustment;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn parseTwoDigits(text: []const u8) ?i64 {
    if (text.len != 2) return null;
    if (!std.ascii.isDigit(text[0]) or !std.ascii.isDigit(text[1])) return null;
    return @as(i64, text[0] - '0') * 10 + @as(i64, text[1] - '0');
}

fn parseIsoTimestampNs(text: []const u8) ?i128 {
    if (text.len < 19) return null;
    if (text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':') return null;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = parseTwoDigits(text[5..7]) orelse return null;
    const day = parseTwoDigits(text[8..10]) orelse return null;
    const hour = parseTwoDigits(text[11..13]) orelse return null;
    const minute = parseTwoDigits(text[14..16]) orelse return null;
    const second = parseTwoDigits(text[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;
    const days = daysFromCivil(year, month, day);
    const seconds = days * 86_400 + hour * 3_600 + minute * 60 + second;

    var idx: usize = 19;
    var fraction_ns: i128 = 0;
    if (idx < text.len and text[idx] == '.') {
        idx += 1;
        var stored_digits: usize = 0;
        var saw_digit = false;
        while (idx < text.len and std.ascii.isDigit(text[idx])) : (idx += 1) {
            saw_digit = true;
            if (stored_digits < 9) {
                fraction_ns = fraction_ns * 10 + @as(i128, text[idx] - '0');
                stored_digits += 1;
            }
        }
        if (!saw_digit) return null;
        while (stored_digits < 9) : (stored_digits += 1) {
            fraction_ns *= 10;
        }
    }

    var offset_seconds: i64 = 0;
    if (idx < text.len) {
        if (text[idx] == 'Z') {
            idx += 1;
            if (idx != text.len) return null;
        } else if (text[idx] == '+' or text[idx] == '-') {
            const sign: i64 = if (text[idx] == '+') 1 else -1;
            idx += 1;
            if (idx + 5 != text.len or text[idx + 2] != ':') return null;
            const offset_hour = parseTwoDigits(text[idx .. idx + 2]) orelse return null;
            const offset_minute = parseTwoDigits(text[idx + 3 .. idx + 5]) orelse return null;
            if (offset_hour > 23 or offset_minute > 59) return null;
            offset_seconds = sign * (offset_hour * 3_600 + offset_minute * 60);
        } else {
            return null;
        }
    }

    return @as(i128, seconds - offset_seconds) * 1_000_000_000 + fraction_ns;
}

fn parseCasRerCreatedAtNs(text: []const u8) ?i128 {
    if (std.mem.startsWith(u8, text, "unix-ns:")) {
        return std.fmt.parseInt(i128, text["unix-ns:".len..], 10) catch null;
    }
    return parseIsoTimestampNs(text);
}

fn casRerRecordLessThan(_: void, left: CasRerLedgerRecord, right: CasRerLedgerRecord) bool {
    const left_ns = parseCasRerCreatedAtNs(left.created_at);
    const right_ns = parseCasRerCreatedAtNs(right.created_at);
    if (left_ns != null and right_ns != null and left_ns.? != right_ns.?) return left_ns.? < right_ns.?;
    const created_order = std.mem.order(u8, left.created_at, right.created_at);
    if (created_order != .eq) return created_order == .lt;
    return std.mem.order(u8, left.record_id, right.record_id) == .lt;
}

fn latestCasRerLedgerRecordIndex(records: []const CasRerLedgerRecord) ?usize {
    if (records.len == 0) return null;
    var best: usize = 0;
    for (records[1..], 1..) |record, idx| {
        if (casRerRecordLessThan({}, records[best], record)) best = idx;
    }
    return best;
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
    const raw = try durable_store.readRegularFileNoSymlink(allocator, record_path, 1024 * 1024);
    const parsed = try std.json.parseFromSlice(LaneRecord, allocator, raw, .{});
    return .{
        .record_path = record_path,
        .raw = raw,
        .parsed = parsed,
        .record = parsed.value,
    };
}

fn writeLaneRecord(allocator: std.mem.Allocator, path: []const u8, record: LaneRecord) !void {
    const json = try stringifyAnyAlloc(allocator, record);
    defer allocator.free(json);
    const payload = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    defer allocator.free(payload);
    try durable_store.writeTextAtomic(allocator, path, payload);
}

fn laneSmokeRecordPathAlloc(allocator: std.mem.Allocator, tuple_hash: []const u8) ![]const u8 {
    const session_dir = try sessionDirAlloc(allocator);
    defer allocator.free(session_dir);
    const smoke_dir = try std.fmt.allocPrint(allocator, "{s}/smoke", .{session_dir});
    defer allocator.free(smoke_dir);
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), smoke_dir);
    const bare_hash = if (std.mem.startsWith(u8, tuple_hash, "sha256:")) tuple_hash["sha256:".len..] else tuple_hash;
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ smoke_dir, bare_hash });
}

fn writeLaneSmokeRecord(allocator: std.mem.Allocator, path: []const u8, record: LaneSmokeRecord) !void {
    const json = try stringifyAnyAlloc(allocator, record);
    defer allocator.free(json);
    const payload = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    defer allocator.free(payload);
    try durable_store.writeTextAtomic(allocator, path, payload);
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

fn printDisconnectedReviewTransportJson(
    allocator: std.mem.Allocator,
    action: StatusAction,
    record: SessionRecord,
    record_path: []const u8,
    identity_opt: ?TargetIdentity,
    timeout_ms: ?u32,
) !void {
    var status = try makeDisconnectedReviewStatus(allocator);
    defer status.deinit(allocator);
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
        withRecordMultiAgentMode(.{
            .resolved_codex_path = record.resolved_codex_path,
            .resolved_codex_version = record.codex_version,
            .compatibility_verdict = record.compatibility_verdict orelse "not_checked",
            .selected_transport = record.transport_kind orelse "stdio",
            .selection_reason = record.transport_selection_reason orelse "legacy_record",
            .managed_server_pid = record.managed_server_pid,
            .managed_server_listen_url = record.managed_server_listen_url,
            .managed_server_stderr_log_path = record.managed_server_stderr_log_path,
            .orphan_ttl_seconds = record.orphan_ttl_seconds,
        }, record),
        timeout_ms,
        false,
        .{
            .code = "review_transport_lost",
            .hint = "managed websocket review transport could not be reconnected; wait/status may be retried on the same reviewThreadId",
        },
        null,
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
    return loadOwnedSessionRecordPath(allocator, record_path) catch |err| {
        if (err == error.FileNotFound) {
            const legacy_path = try legacySessionRecordPathAlloc(allocator, review_thread_id);
            return loadOwnedSessionRecordPath(allocator, legacy_path) catch |legacy_err| {
                return legacy_err;
            };
        }
        return err;
    };
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
    if (parsed.value.workflowBinding) |binding| try validateWorkflowBinding(binding);
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

fn latestSessionRecordPathAlloc(allocator: std.mem.Allocator) ![]const u8 {
    const session_dir = try sessionDirAlloc(allocator);
    defer allocator.free(session_dir);
    return latestSessionRecordPathInDirAlloc(allocator, session_dir) catch |err| switch (err) {
        error.NoReviewSessionRecords, error.FileNotFound => {
            const legacy_dir = try legacySessionDirPathAlloc(allocator);
            defer allocator.free(legacy_dir);
            return latestSessionRecordPathInDirAlloc(allocator, legacy_dir);
        },
        else => return err,
    };
}

fn legacySessionDirPathAlloc(allocator: std.mem.Allocator) ![]const u8 {
    const home = configured_home orelse return error.FileNotFound;
    return std.fmt.allocPrint(allocator, "{s}/.codex/cas/review_sessions", .{home});
}

fn legacySessionRecordPathAlloc(allocator: std.mem.Allocator, review_thread_id: []const u8) ![]const u8 {
    const session_dir = try legacySessionDirPathAlloc(allocator);
    defer allocator.free(session_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ session_dir, review_thread_id });
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
    if (std.mem.endsWith(u8, name, ".lane.json")) return false;
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
    const path_z = try std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), cwd, allocator);
    defer allocator.free(path_z);
    return allocator.dupe(u8, path_z);
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
    const legacy_payload = try std.fmt.allocPrint(
        allocator,
        "repo_realpath={s}\nbase_sha={s}\nhead_sha={s}\ntarget_fingerprint={s}\nresolved_codex_path={s}\nresolved_codex_version={s}\naccount_fingerprint={s}\ncodex_thread_id={s}\n",
        .{
            tuple.repo_realpath,
            tuple.base_sha orelse "",
            tuple.head_sha orelse "",
            tuple.target_fingerprint,
            tuple.resolved_codex_path,
            tuple.resolved_codex_version,
            tuple.account_fingerprint,
            tuple.codex_thread_id,
        },
    );
    const workflow_binding_digest = tuple.workflow_binding_digest orelse return legacy_payload;
    defer allocator.free(legacy_payload);
    return std.fmt.allocPrint(allocator, "{s}workflow_binding_digest={s}\n", .{ legacy_payload, workflow_binding_digest });
}

fn reviewTupleHashAlloc(allocator: std.mem.Allocator, tuple: ReviewTupleIdentity) ![]const u8 {
    const canonical = try canonicalReviewTuplePayloadAlloc(allocator, tuple);
    defer allocator.free(canonical);
    return sha256HexAlloc(allocator, canonical);
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

fn reviewTupleLockRewriteClaimPathAlloc(allocator: std.mem.Allocator, lock_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.rewrite-claim", .{lock_path});
}

fn reviewTupleLockWorkflowBindingValidAlloc(allocator: std.mem.Allocator, lock: ReviewTupleLock) !bool {
    const binding = lock.workflowBinding orelse return true;
    try validateWorkflowBinding(binding);
    const codex_thread_id = lock.codexThreadId orelse return false;
    const canonical = try stringifyAnyAlloc(allocator, binding);
    defer allocator.free(canonical);
    const workflow_binding_digest = try sha256HexAlloc(allocator, canonical);
    defer allocator.free(workflow_binding_digest);
    const expected_tuple_hash = try reviewTupleHashAlloc(allocator, .{
        .repo_realpath = lock.repoRealpath,
        .base_sha = lock.baseSha,
        .head_sha = lock.headSha,
        .target_fingerprint = lock.targetFingerprint,
        .resolved_codex_path = lock.resolvedCodexPath,
        .resolved_codex_version = lock.resolvedCodexVersion,
        .account_fingerprint = lock.accountFingerprint,
        .account_fingerprint_reduced_protection = false,
        .codex_thread_id = codex_thread_id,
        .workflow_binding = binding,
        .workflow_binding_digest = workflow_binding_digest,
    });
    defer allocator.free(expected_tuple_hash);
    return std.mem.eql(u8, lock.tupleHash, expected_tuple_hash);
}

fn loadReviewTupleLock(allocator: std.mem.Allocator, path: []const u8) !?LoadedReviewTupleLock {
    const raw = durable_store.readRegularFileNoSymlink(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer allocator.free(raw);
    const parsed = try std.json.parseFromSlice(ReviewTupleLock, allocator, raw, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (!try reviewTupleLockWorkflowBindingValidAlloc(allocator, parsed.value)) return error.InvalidWorkflowBinding;
    return .{
        .path = try allocator.dupe(u8, path),
        .raw = raw,
        .parsed = parsed,
        .record = parsed.value,
    };
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
        .codexThreadId = tuple.codex_thread_id,
        .workflowBinding = tuple.workflow_binding,
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

fn reviewTupleLockRewriteClaimExpired(allocator: std.mem.Allocator, claim_path: []const u8, now_s: i64) bool {
    const raw = durable_store.readRegularFileNoSymlink(allocator, claim_path, 4096) catch return true;
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return true;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return true,
    };
    const created_at = jsonI64Field(obj, "createdAtUnixS") orelse return true;
    return created_at + review_tuple_lock_ttl_seconds <= now_s;
}

fn claimReviewTupleLockRewriteExclusive(allocator: std.mem.Allocator, lock_path: []const u8) ![]const u8 {
    const claim_path = try reviewTupleLockRewriteClaimPathAlloc(allocator, lock_path);
    errdefer allocator.free(claim_path);
    try ensureParentPath(claim_path);

    var stale_claim_removed = false;
    while (true) {
        const claim = try std.fmt.allocPrint(allocator, "{{\"ownerPid\":{d},\"createdAtUnixS\":{d}}}\n", .{ currentProcessId(), unixSeconds() });
        defer allocator.free(claim);
        durable_store.writeTextCreateNew(allocator, claim_path, claim, .{ .reject_symlinks = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (!stale_claim_removed and reviewTupleLockRewriteClaimExpired(allocator, claim_path, unixSeconds())) {
                    deleteReviewTupleLockRewriteClaimBestEffort(claim_path);
                    stale_claim_removed = true;
                    continue;
                }
                return err;
            },
            else => return err,
        };
        return claim_path;
    }
}

fn deleteReviewTupleLockRewriteClaimBestEffort(claim_path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(std.Io.Threaded.global_single_threaded.io(), claim_path) catch {};
}

fn isSmokeSuiteOverride(override_reason: ?[]const u8) bool {
    return if (override_reason) |reason| std.mem.startsWith(u8, reason, "cas-smoke-suite:") else false;
}

fn reviewTupleLockAction(action_name: []const u8, existing: ?ReviewTupleLock, now_s: i64, override_reason: ?[]const u8, fresh_attempt_reason: ?[]const u8) ReviewTupleLockAction {
    return reviewTupleLockActionWithProbe(action_name, existing, now_s, override_reason, fresh_attempt_reason, false);
}

fn reviewTupleLockActionWithProbe(action_name: []const u8, existing: ?ReviewTupleLock, now_s: i64, override_reason: ?[]const u8, fresh_attempt_reason: ?[]const u8, dead_transport_proven: bool) ReviewTupleLockAction {
    const lock = existing orelse return .create;
    if (!std.mem.eql(u8, lock.lockVersion, review_tuple_lock_version)) return .block_invalid;
    if (std.mem.eql(u8, lock.state, "account_resource_exhausted")) {
        if (isSmokeSuiteOverride(override_reason)) return .block_account_resource;
        return if (override_reason != null) .takeover_with_override else .block_account_resource;
    }
    if (std.mem.eql(u8, lock.state, "terminal") or std.mem.eql(u8, lock.state, "normalized")) {
        if (std.mem.eql(u8, action_name, "lane-smoke") and isSmokeSuiteOverride(override_reason)) return .takeover_with_override;
        if ((std.mem.eql(u8, action_name, "run") or std.mem.eql(u8, action_name, "start") or std.mem.eql(u8, action_name, "lane-review")) and fresh_attempt_reason != null) return .fresh_after_terminal;
        return .normalize_existing;
    }
    const expired = lock.expiresAtUnixS <= now_s;
    if (expired or std.mem.eql(u8, lock.state, "stale")) {
        return if (override_reason != null) .takeover_with_override else .block_stale;
    }
    if (std.mem.eql(u8, lock.state, "review_started") or std.mem.eql(u8, lock.state, "waiting")) {
        if (std.mem.eql(u8, action_name, "run") and dead_transport_proven and reviewTupleLockReplaceableDeadFailure(lock)) return .auto_replace_dead_transport;
        if (std.mem.eql(u8, action_name, "lane-smoke") and
            isSmokeSuiteOverride(override_reason) and
            (isSmokeSuiteOverride(lock.overrideReason) or std.mem.eql(u8, lock.lastFailureCode orelse "", "wait_timed_out")))
        {
            return .takeover_with_override;
        }
        return if (lock.reviewThreadId != null) .return_existing else .block_active;
    }
    if (std.mem.eql(u8, lock.state, "pre_review_start_failed")) return .retry_after_pre_review_failure;
    if (std.mem.eql(u8, lock.state, "starting_lane")) return .block_active;
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
    if (!(std.mem.eql(u8, action_name, "run") or std.mem.eql(u8, action_name, "start") or std.mem.eql(u8, action_name, "lane-review"))) return false;
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
        std.mem.eql(u8, code, "wait_timed_out");
}

fn reviewTupleLockDeadTransportProven(allocator: std.mem.Allocator, lock: ReviewTupleLock) bool {
    if (!reviewTupleLockReplaceableDeadFailure(lock)) return false;
    if (cas_websocket.processAlive(lock.ownerPid)) return false;
    const record_path = lock.recordPath orelse return false;
    const owned_record_path = allocator.dupe(u8, record_path) catch return false;
    var loaded = loadOwnedSessionRecordPath(allocator, owned_record_path) catch {
        allocator.free(owned_record_path);
        return false;
    };
    defer loaded.deinit(allocator);
    const managed_server_pid = loaded.record.managed_server_pid orelse return false;
    return !cas_websocket.processAlive(managed_server_pid);
}

fn reviewTupleLockActionForAcquire(
    allocator: std.mem.Allocator,
    action_name: []const u8,
    existing: ?ReviewTupleLock,
    now_s: i64,
    override_reason: ?[]const u8,
    fresh_attempt_reason: ?[]const u8,
    target_identity: TargetIdentity,
) ReviewTupleLockAction {
    const dead_transport_proven = if (existing) |lock| reviewTupleLockDeadTransportProven(allocator, lock) else false;
    const action = reviewTupleLockActionWithProbe(action_name, existing, now_s, override_reason, fresh_attempt_reason, dead_transport_proven);
    if (action == .normalize_existing and fresh_attempt_reason == null) {
        if (existing) |lock| {
            if (terminalLockNeedsFreshAttempt(allocator, action_name, lock, target_identity)) return .fresh_after_terminal;
        }
    }
    return action;
}

fn printReviewTupleLockExistingAndExit(
    allocator: std.mem.Allocator,
    action_name: []const u8,
    target_identity: TargetIdentity,
    tuple: ReviewTupleIdentity,
    lock_path: []const u8,
    lock: ReviewTupleLock,
    decision: ReviewTupleLockAction,
    verdict_only: bool,
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
                if (verdict_only) {
                    try writeReceiptReviewVerdictObject(stdout, normalized);
                    try stdout.writeAll("\n");
                } else if (std.mem.eql(u8, action_name, "run")) {
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
    const smoke_status = if (std.mem.eql(u8, action_name, "lane-smoke")) @as(?[]const u8, "failed") else null;
    const lock_points_to_terminal = std.mem.eql(u8, lock.state, "terminal") or std.mem.eql(u8, lock.state, "normalized");
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
        .smokeStatus = smoke_status,
        .reviewAttemptPhase = if (lock_points_to_terminal) "review_terminal" else "review_waiting",
        .reviewAttemptExists = review_thread_id != null,
        .tupleVerdictExists = false,
        .reviewThreadId = review_thread_id,
        .reviewTurnId = review_turn_id,
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
        .recordPath = lock.recordPath,
        .eventLogPath = lock.eventLogPath,
        .lastFailureCode = lock.lastFailureCode,
        .reviewVerdict = .{
            .status = tupleLockFallbackVerdictStatus(lock),
            .reviewAttemptPhase = if (lock_points_to_terminal) "review_terminal" else "review_waiting",
            .reviewAttemptExists = review_thread_id != null,
            .tupleVerdictExists = false,
            .backendClass = "cas-receipt-normalized",
            .clean = false,
            .findingCount = 0,
            .failureCode = @as(?[]const u8, null),
            .failureHint = if (decision == .normalize_existing) "tuple lock points to an existing terminal receipt; normalize that record instead of starting a duplicate review" else "tuple lock points to an existing active review attempt",
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
    if (verdict_only) {
        const verdict = try stringifyAnyAlloc(allocator, payload.reviewVerdict);
        defer allocator.free(verdict);
        try stdout.print("{s}\n", .{verdict});
    } else {
        const payload_json = try stringifyAnyAlloc(allocator, payload);
        defer allocator.free(payload_json);
        if (std.mem.eql(u8, action_name, "run")) {
            const timestamp = try casRerTimestampAlloc(allocator);
            defer allocator.free(timestamp);
            const shadow_record_path = writeCasRerShadowRecordFromJsonAlloc(allocator, lock.recordPath orelse lock_path, payload_json, .{
                .requested_identity = target_identity,
                .requested_identity_required = true,
            }, .{
                .command_surface = "run",
                .backend_selected = "cas-run",
                .broker_action = "blocked_live",
                .broker_reason = broker_decision.?.reason,
                .imported_from_receipt = false,
                .tuple_current_at_record_time = true,
                .created_at = timestamp,
                .updated_at = timestamp,
            }) catch null;
            defer if (shadow_record_path) |path| allocator.free(path);
        }
        try stdout.print("{s}\n", .{payload_json});
    }
    std.process.exit(1);
}

fn writeRunNormalizedReceiptObject(allocator: std.mem.Allocator, writer: *std.Io.Writer, receipt: NormalizedReceipt, lock: ReviewTupleLock) !void {
    const broker = ReviewBrokerDecision{
        .action = "normalized_existing",
        .reason = "tuple lock points to an existing terminal receipt normalized for the requested tuple",
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
        else => "blocked_live_attempt",
    };
}

fn tupleLockFallbackVerdictStatus(lock: ReviewTupleLock) []const u8 {
    if (std.mem.eql(u8, lock.lastFailureCode orelse "", "wait_timed_out")) return "timeout";
    return "incomplete";
}

fn emitReviewTupleLockBlockedAndExit(
    allocator: std.mem.Allocator,
    json_mode: bool,
    action_name: []const u8,
    tuple: ReviewTupleIdentity,
    lock_path: []const u8,
    lock: ?ReviewTupleLock,
    decision: ReviewTupleLockAction,
    override_reason: ?[]const u8,
    verdict_only: bool,
) !noreturn {
    const failure_code: []const u8 = switch (decision) {
        .block_account_resource => "review_tuple_lock_account_resource_exhausted",
        .block_stale => "review_tuple_lock_stale",
        .block_invalid => "review_tuple_lock_invalid",
        else => "review_tuple_lock_active",
    };
    const hint: []const u8 = switch (decision) {
        .block_account_resource => "same-account review retry is blocked until the limit resets, the account changes, or --review-lock-override is supplied",
        .block_stale => "tuple lock is stale; supply --review-lock-override with a takeover reason before starting a new review",
        .block_invalid => "tuple lock file is invalid for CAS-RTL-v1; inspect or remove it before starting a new review",
        else => "an active review attempt already owns this repo/base/head/account tuple",
    };
    if (json_mode) {
        const blocked_review_thread_id = if (lock) |value| value.reviewThreadId else null;
        const blocked_review_turn_id = if (lock) |value| value.reviewTurnId else null;
        const blocked_attempt_exists = blocked_review_thread_id != null;
        const blocked_phase: []const u8 = if (blocked_attempt_exists) "review_waiting" else "pre_review_start";
        if (verdict_only) {
            try printJson(.{
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
            });
            std.process.exit(1);
        }
        const smoke_status = if (std.mem.eql(u8, action_name, "lane-smoke")) @as(?[]const u8, "failed") else null;
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
            .smokeStatus = smoke_status,
            .reviewAttemptPhase = blocked_phase,
            .reviewAttemptExists = blocked_attempt_exists,
            .tupleVerdictExists = false,
            .reviewThreadId = blocked_review_thread_id,
            .reviewTurnId = blocked_review_turn_id,
            .baseSha = tuple.base_sha,
            .headSha = tuple.head_sha,
            .targetFingerprint = tuple.target_fingerprint,
            .resolvedCodexPath = tuple.resolved_codex_path,
            .resolvedCodexVersion = tuple.resolved_codex_version,
            .failureCode = failure_code,
            .failureClass = "coordination",
            .retryableSameTupleNow = false,
            .failureHint = hint,
            .reviewTupleLockVersion = review_tuple_lock_version,
            .reviewTupleHash = if (lock) |value| value.tupleHash else null,
            .reviewTupleLockPath = lock_path,
            .reviewTupleLockState = if (lock) |value| value.state else null,
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
                .imported_from_receipt = false,
                .tuple_current_at_record_time = true,
                .created_at = timestamp,
                .updated_at = timestamp,
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

    fn deinit(self: ReviewTupleStartLockBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.lock.tupleHash);
    }
};

fn acquireReviewTupleStartLockOrExit(
    allocator: std.mem.Allocator,
    json_mode: bool,
    action_name: []const u8,
    target_identity: TargetIdentity,
    tuple: ReviewTupleIdentity,
    override_reason: ?[]const u8,
    fresh_attempt_reason: ?[]const u8,
    verdict_only: bool,
    managed_server_to_kill_on_exit: ?*cas_websocket.ManagedServer,
) !ReviewTupleStartLockBundle {
    const tuple_hash = try reviewTupleHashAlloc(allocator, tuple);
    const lock_path = try reviewTupleLockPathAlloc(allocator, tuple_hash);
    var loaded_opt = loadReviewTupleLock(allocator, lock_path) catch {
        killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
        try emitReviewTupleLockBlockedAndExit(
            allocator,
            json_mode,
            action_name,
            tuple,
            lock_path,
            null,
            .block_invalid,
            override_reason,
            verdict_only,
        );
    };
    defer if (loaded_opt) |*loaded| loaded.deinit(allocator);
    const now_s = unixSeconds();
    const decision = reviewTupleLockActionForAcquire(allocator, action_name, if (loaded_opt) |loaded| loaded.record else null, now_s, override_reason, fresh_attempt_reason, target_identity);
    switch (decision) {
        .create => {
            const lock = makeReviewTupleLock(tuple_hash, tuple, "starting_lane", now_s, override_reason, fresh_attempt_reason);
            writeReviewTupleLockExclusive(allocator, lock_path, lock) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    var raced = (loadReviewTupleLock(allocator, lock_path) catch {
                        killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                        try emitReviewTupleLockBlockedAndExit(
                            allocator,
                            json_mode,
                            action_name,
                            tuple,
                            lock_path,
                            null,
                            .block_invalid,
                            override_reason,
                            verdict_only,
                        );
                    }) orelse return err;
                    defer raced.deinit(allocator);
                    const raced_decision = reviewTupleLockActionForAcquire(allocator, action_name, raced.record, now_s, override_reason, fresh_attempt_reason, target_identity);
                    switch (raced_decision) {
                        .return_existing, .normalize_existing => {
                            killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                            try printReviewTupleLockExistingAndExit(allocator, action_name, target_identity, tuple, lock_path, raced.record, raced_decision, verdict_only);
                        },
                        .block_active, .block_stale, .block_account_resource, .block_invalid => {
                            killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                            try emitReviewTupleLockBlockedAndExit(
                                allocator,
                                json_mode,
                                action_name,
                                tuple,
                                lock_path,
                                raced.record,
                                raced_decision,
                                override_reason,
                                verdict_only,
                            );
                        },
                        .create, .retry_after_pre_review_failure, .auto_replace_dead_transport, .takeover_with_override, .fresh_after_terminal => return err,
                    }
                },
                else => return err,
            };
            return .{ .path = lock_path, .lock = lock };
        },
        .retry_after_pre_review_failure, .auto_replace_dead_transport, .takeover_with_override, .fresh_after_terminal => {
            const claim_path = claimReviewTupleLockRewriteExclusive(allocator, lock_path) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                    try emitReviewTupleLockBlockedAndExit(
                        allocator,
                        json_mode,
                        action_name,
                        tuple,
                        lock_path,
                        if (loaded_opt) |loaded| loaded.record else null,
                        .block_active,
                        override_reason,
                        verdict_only,
                    );
                },
                else => return err,
            };
            defer allocator.free(claim_path);
            defer deleteReviewTupleLockRewriteClaimBestEffort(claim_path);

            var latest = (loadReviewTupleLock(allocator, lock_path) catch {
                killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                try emitReviewTupleLockBlockedAndExit(
                    allocator,
                    json_mode,
                    action_name,
                    tuple,
                    lock_path,
                    null,
                    .block_invalid,
                    override_reason,
                    verdict_only,
                );
            }) orelse {
                killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                try emitReviewTupleLockBlockedAndExit(
                    allocator,
                    json_mode,
                    action_name,
                    tuple,
                    lock_path,
                    null,
                    .block_invalid,
                    override_reason,
                    verdict_only,
                );
            };
            defer latest.deinit(allocator);
            const latest_decision = reviewTupleLockActionForAcquire(allocator, action_name, latest.record, unixSeconds(), override_reason, fresh_attempt_reason, target_identity);
            switch (latest_decision) {
                .retry_after_pre_review_failure, .auto_replace_dead_transport, .takeover_with_override, .fresh_after_terminal => {},
                .return_existing, .normalize_existing => {
                    killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                    try printReviewTupleLockExistingAndExit(allocator, action_name, target_identity, tuple, lock_path, latest.record, latest_decision, verdict_only);
                },
                .block_active, .block_stale, .block_account_resource, .block_invalid => {
                    killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                    try emitReviewTupleLockBlockedAndExit(
                        allocator,
                        json_mode,
                        action_name,
                        tuple,
                        lock_path,
                        latest.record,
                        latest_decision,
                        override_reason,
                        verdict_only,
                    );
                },
                .create => {
                    killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
                    try emitReviewTupleLockBlockedAndExit(
                        allocator,
                        json_mode,
                        action_name,
                        tuple,
                        lock_path,
                        latest.record,
                        .block_invalid,
                        override_reason,
                        verdict_only,
                    );
                },
            }
            const replacement_override_reason = if (latest_decision == .auto_replace_dead_transport) "auto-replaced-dead-transport" else override_reason;
            const lock = makeReviewTupleLock(tuple_hash, tuple, "starting_lane", now_s, replacement_override_reason, fresh_attempt_reason);
            try writeReviewTupleLock(allocator, lock_path, lock);
            return .{ .path = lock_path, .lock = lock };
        },
        .return_existing, .normalize_existing => {
            const lock = loaded_opt.?.record;
            killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
            try printReviewTupleLockExistingAndExit(allocator, action_name, target_identity, tuple, lock_path, lock, decision, verdict_only);
        },
        .block_active, .block_stale, .block_account_resource, .block_invalid => {
            killManagedServerBeforeTupleLockExit(managed_server_to_kill_on_exit);
            try emitReviewTupleLockBlockedAndExit(
                allocator,
                json_mode,
                action_name,
                tuple,
                lock_path,
                if (loaded_opt) |loaded| loaded.record else null,
                decision,
                override_reason,
                verdict_only,
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

fn updateReviewTupleLockForRecordBestEffort(
    allocator: std.mem.Allocator,
    record: SessionRecord,
    record_path: []const u8,
    identity_opt: ?TargetIdentity,
    client: *cas.Client,
    state: []const u8,
    failure_code: ?[]const u8,
) void {
    if (identity_opt) |identity| {
        var tuple = reviewTupleIdentityAlloc(
            allocator,
            record.cwd,
            identity,
            record.resolved_codex_path orelse "codex",
            record.codex_version,
            client,
            record.workflowBinding,
        ) catch return updateReviewTupleLockByReviewThreadIdBestEffort(allocator, record, record_path, state, failure_code);
        defer tuple.deinit(allocator);
        const tuple_hash = reviewTupleHashAlloc(allocator, tuple) catch return updateReviewTupleLockByReviewThreadIdBestEffort(allocator, record, record_path, state, failure_code);
        defer allocator.free(tuple_hash);
        const lock_path = reviewTupleLockPathAlloc(allocator, tuple_hash) catch return updateReviewTupleLockByReviewThreadIdBestEffort(allocator, record, record_path, state, failure_code);
        defer allocator.free(lock_path);
        var loaded = (loadReviewTupleLock(allocator, lock_path) catch null) orelse {
            updateReviewTupleLockByReviewThreadIdBestEffort(allocator, record, record_path, state, failure_code);
            return;
        };
        defer loaded.deinit(allocator);
        if (!std.mem.eql(u8, loaded.record.reviewThreadId orelse "", record.review_thread_id)) {
            updateReviewTupleLockByReviewThreadIdBestEffort(allocator, record, record_path, state, failure_code);
            return;
        }
        updateReviewTupleLockBestEffort(
            allocator,
            lock_path,
            loaded.record,
            state,
            failure_code,
            record.review_thread_id,
            record.review_turn_id,
            record_path,
            record.event_log_path,
        );
        return;
    }
    updateReviewTupleLockByReviewThreadIdBestEffort(allocator, record, record_path, state, failure_code);
}

fn updateReviewTupleLockByReviewThreadIdBestEffort(
    allocator: std.mem.Allocator,
    record: SessionRecord,
    record_path: []const u8,
    state: []const u8,
    failure_code: ?[]const u8,
) void {
    const locks_dir = reviewTupleLocksDirAlloc(allocator) catch return;
    defer allocator.free(locks_dir);
    var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), locks_dir, .{ .iterate = true }) catch return;
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var it = dir.iterate();
    while (it.next(std.Io.Threaded.global_single_threaded.io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const lock_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ locks_dir, entry.name }) catch continue;
        defer allocator.free(lock_path);
        var loaded = (loadReviewTupleLock(allocator, lock_path) catch null) orelse continue;
        defer loaded.deinit(allocator);
        if (!std.mem.eql(u8, loaded.record.reviewThreadId orelse "", record.review_thread_id)) continue;
        updateReviewTupleLockBestEffort(
            allocator,
            lock_path,
            loaded.record,
            state,
            failure_code,
            record.review_thread_id,
            record.review_turn_id,
            record_path,
            record.event_log_path,
        );
        return;
    }
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
        const failure_class = failureClassForCode(failure.code);
        const retryable_same_tuple_now = retryableSameTupleNowForCode(failure.code);
        const payload = .{
            .demo = "cas-review-session",
            .action = action,
            .method = method,
            .reviewAttemptPhase = errorReviewAttemptPhase(action, method),
            .reviewAttemptExists = false,
            .tupleVerdictExists = false,
            .reviewThreadId = @as(?[]const u8, null),
            .reviewTurnId = @as(?[]const u8, null),
            .baseSha = @as(?[]const u8, null),
            .headSha = @as(?[]const u8, null),
            .targetFingerprint = @as(?[]const u8, null),
            .cwd = cwd,
            .resolvedCodexPath = receipt.resolved_codex_path,
            .resolvedCodexVersion = receipt.resolved_codex_version,
            .compatibilityVerdict = receipt.compatibility_verdict,
            .requestedMultiAgentMode = if (receipt.requested_multi_agent_mode) |mode| mode.configValue() else null,
            .effectiveMultiAgentMode = if (receipt.effective_multi_agent_mode) |mode| mode.configValue() else null,
            .multiAgentModeSupport = receipt.multi_agent_mode_support.asString(),
            .multiAgentModeMetricEligible = receipt.multi_agent_mode_metric_eligible,
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
                .reviewThreadId = @as(?[]const u8, null),
                .reviewTurnId = @as(?[]const u8, null),
                .recordPath = @as(?[]const u8, null),
                .eventLogPath = @as(?[]const u8, null),
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

fn preReviewLaneServerExitStatus(lane_process_alive: bool) ?[]const u8 {
    return if (lane_process_alive) null else "unknown";
}

fn buildPreReviewLaneTransportLostJsonAlloc(
    allocator: std.mem.Allocator,
    action_name: []const u8,
    method: []const u8,
    message: []const u8,
    failure_hint: []const u8,
    lane: LaneRecord,
    lane_record_path: []const u8,
    target: TargetRecord,
    identity: TargetIdentity,
    workflow_binding: ?WorkflowBinding,
    lane_process_alive: bool,
) ![]u8 {
    const smoke_status = if (std.mem.eql(u8, action_name, "lane-smoke")) @as(?[]const u8, "failed") else null;
    return stringifyAnyAlloc(allocator, .{
        .demo = "cas-review-session",
        .action = action_name,
        .smokeStatus = smoke_status,
        .method = method,
        .reviewAttemptPhase = "pre_review_start",
        .reviewAttemptExists = false,
        .tupleVerdictExists = false,
        .reviewThreadId = @as(?[]const u8, null),
        .reviewTurnId = @as(?[]const u8, null),
        .baseSha = identity.base_sha,
        .headSha = identity.head_sha,
        .targetFingerprint = identity.fingerprint,
        .workflowBinding = workflow_binding,
        .cwd = lane.cwd,
        .laneId = lane.lane_id,
        .laneRecordPath = lane_record_path,
        .target = target,
        .resolvedCodexPath = lane.resolved_codex_path,
        .resolvedCodexVersion = lane.codex_version,
        .compatibilityVerdict = "compatible",
        .selectedTransport = lane.transport_kind,
        .selectionReason = lane.transport_selection_reason,
        .managedServerPid = lane.managed_server_pid,
        .managedServerListenUrl = lane.managed_server_listen_url,
        .serverExitStatus = preReviewLaneServerExitStatus(lane_process_alive),
        .stderrLogPath = @as(?[]const u8, null),
        .orphanTtlSeconds = lane.orphan_ttl_seconds,
        .reviewCount = @as(u32, 0),
        .lastReviewThreadId = @as(?[]const u8, null),
        .failureCode = "pre_review_lane_transport_lost",
        .failureClass = "transport_pre_review",
        .failureHint = failure_hint,
        .reviewVerdict = .{
            .status = "pre_review_transport_failure",
            .backendClass = "cas-lane",
            .clean = false,
            .findingCount = 0,
            .failureCode = "pre_review_lane_transport_lost",
            .failureHint = failure_hint,
            .baseSha = identity.base_sha,
            .headSha = identity.head_sha,
            .targetFingerprint = identity.fingerprint,
            .reviewThreadId = @as(?[]const u8, null),
            .reviewTurnId = @as(?[]const u8, null),
            .recordPath = @as(?[]const u8, null),
            .eventLogPath = @as(?[]const u8, null),
            .findings = [_]std.json.Value{},
        },
        .@"error" = message,
    });
}

fn emitPreReviewLaneTransportLostAndExit(
    allocator: std.mem.Allocator,
    json_mode: bool,
    action_name: []const u8,
    method: []const u8,
    message: []const u8,
    failure_hint: []const u8,
    lane: LaneRecord,
    lane_record_path: []const u8,
    target: TargetRecord,
    identity: TargetIdentity,
    workflow_binding: ?WorkflowBinding,
    lane_process_alive: bool,
) !noreturn {
    if (json_mode) {
        const payload = try buildPreReviewLaneTransportLostJsonAlloc(
            allocator,
            action_name,
            method,
            message,
            failure_hint,
            lane,
            lane_record_path,
            target,
            identity,
            workflow_binding,
            lane_process_alive,
        );
        defer allocator.free(payload);
        const normalized = try normalizeReceiptFromJsonAlloc(allocator, lane_record_path, payload, true, .{
            .requested_identity = identity,
            .requested_identity_required = true,
        });
        defer normalized.deinit(allocator);
        const timestamp = try casRerTimestampAlloc(allocator);
        defer allocator.free(timestamp);
        const shadow_record_path = writeCasRerShadowRecordFromReceipt(allocator, normalized, .{
            .command_surface = "lane_review",
            .backend_selected = "cas-lane",
            .broker_action = "created_new",
            .broker_reason = "pre-review lane transport loss shadowed into CAS-RER-v1",
            .imported_from_receipt = false,
            .tuple_current_at_record_time = true,
            .created_at = timestamp,
            .updated_at = timestamp,
        }) catch null;
        defer if (shadow_record_path) |path| allocator.free(path);
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("{s}\n", .{payload});
    } else {
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stderr = &stderr_writer.interface;
        try stderr.print("{s}: {s} (pre_review_lane_transport_lost)\n", .{ method, message });
    }
    std.process.exit(1);
}

fn maybeRunNativeFallbackAndExitStart(
    allocator: std.mem.Allocator,
    parsed: ParsedArgs,
    cwd: []const u8,
    codex_path: []const u8,
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
            identity,
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
            withRecordMultiAgentMode(.{
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
            }, record.*),
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
    status,
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
    fallback: ?NativeFallbackResult,
) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer scratch_arena.deinit();
    const allocator = scratch_arena.allocator();
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    const attempt_fields = identityReviewAttemptFields(
        statusReviewAttemptPhase(status, timed_out),
        false,
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
    const effective_failure = effectiveFailureWithFallback(failure, fallback);
    const failure_code_json = if (effective_failure) |value| try quoteJsonStringAlloc(allocator, value.code) else "null";
    const failure_hint_json = if (effective_failure) |value| try quoteJsonStringAlloc(allocator, value.hint) else "null";
    const failure_control_suffix = try failureControlJsonSuffixAlloc(allocator, effective_failure);
    defer allocator.free(failure_control_suffix);
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
        if (effective_failure == null and status.review_result_available and dual_parse.structured_findings == 0 and !std.mem.eql(u8, dual_parse.verdict, "mismatch")) "true" else "false"
    else
        "null";

    if (action == .wait) {
        if (identity) |target_identity| {
            const review_verdict_json_opt = try startWaitReviewVerdictJsonAlloc(
                allocator,
                target_identity,
                review_thread_id,
                review_turn_id,
                record_path orelse "",
                event_log_path,
                status,
                timed_out orelse false,
                true,
                effective_failure,
                fallback,
            );
            defer if (review_verdict_json_opt) |value| allocator.free(value);
            if (review_verdict_json_opt) |review_verdict_json| {
                const synthetic_receipt_json = try casRunSyntheticReceiptJsonAlloc(
                    allocator,
                    cwd orelse "",
                    target_identity,
                    parent_thread_id orelse "",
                    review_thread_id,
                    review_turn_id,
                    record_path orelse "",
                    event_log_path,
                    receipt,
                    review_verdict_json,
                );
                defer allocator.free(synthetic_receipt_json);
                const normalized = try normalizeReceiptFromJsonAlloc(allocator, record_path orelse event_log_path, synthetic_receipt_json, true, .{
                    .requested_identity = target_identity,
                    .requested_identity_required = true,
                });
                defer normalized.deinit(allocator);
                const timestamp = try casRerTimestampAlloc(allocator);
                defer allocator.free(timestamp);
                const shadow_record_path = writeCasRerShadowRecordFromReceipt(allocator, normalized, .{
                    .command_surface = "start_wait",
                    .backend_selected = "cas-start-wait",
                    .broker_action = "created_new",
                    .broker_reason = "low-level wait output shadowed into CAS-RER-v1",
                    .imported_from_receipt = false,
                    .tuple_current_at_record_time = true,
                    .created_at = timestamp,
                    .updated_at = timestamp,
                }) catch null;
                defer if (shadow_record_path) |path| allocator.free(path);
            }
        }
    }

    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":\"{s}\"",
        .{@tagName(action)},
    );
    try writeReviewAttemptStateFields(stdout, attempt_fields);
    try stdout.print(
        ",\"cwd\":{s},\"parentThreadId\":{s},\"reviewThreadId\":{s},\"reviewTurnId\":{s},\"threadStatus\":{s},\"turnStatus\":{s},\"turnCount\":{d},\"materialized\":{s},\"rolloutPath\":{s},\"recordPath\":{s},\"eventLogPath\":{s},\"target\":{s},\"targetFingerprint\":{s},\"headSha\":{s},\"baseSha\":{s},\"resolvedCodexPath\":{s},\"resolvedCodexVersion\":{s},\"compatibilityVerdict\":{s},\"selectedTransport\":{s},\"selectionReason\":{s},\"degradedFallback\":{s},\"managedServerPid\":{s},\"managedServerListenUrl\":{s},\"managedServerStderrLogPath\":{s},\"orphanTtlSeconds\":{s},\"requestedMultiAgentMode\":{s},\"effectiveMultiAgentMode\":{s},\"multiAgentModeSupport\":{s},\"multiAgentModeMetricEligible\":{s}",
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
            if (receipt.degraded_fallback) "true" else "false",
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
    try stdout.print(
        ",\"timeoutMs\":{s},\"timedOut\":{s},\"failureCode\":{s},\"failureHint\":{s}{s},\"fallbackUsed\":{s},\"fallbackTransport\":{s},\"fallbackExitCode\":{s},\"fallbackOutputText\":{s},\"fallbackErrorText\":{s},\"hookSummary\":{s},\"reviewResultAvailable\":{s},\"reviewResultSource\":{s},\"reviewResult\":{s},\"rawReviewText\":{s},\"dualParseVerdict\":{s},\"structuredFindingCount\":{s},\"rawFindingCount\":{s},\"clean\":{s}}}\n",
        .{
            timeout_json,
            timed_out_json,
            failure_code_json,
            failure_hint_json,
            failure_control_suffix,
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

fn startWaitReviewVerdictJsonAlloc(
    allocator: std.mem.Allocator,
    identity: TargetIdentity,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: []const u8,
    event_log_path: []const u8,
    status: ?ReviewStatus,
    timed_out: bool,
    waited: bool,
    failure: ?FailureInfo,
    fallback: ?NativeFallbackResult,
) !?[]u8 {
    if (!waited and fallback == null) return null;

    var effective_failure = effectiveFailureWithFallback(failure, fallback);
    var clean: ?bool = false;
    var finding_count: ?usize = 0;
    var review_result_json: ?[]const u8 = null;

    if (timed_out and effective_failure == null) {
        effective_failure = .{
            .code = "wait_timed_out",
            .hint = "retry cas review_session wait on the same review thread or increase --timeout-ms",
        };
    }

    if (status) |value| {
        review_result_json = value.review_result_json;
        if (value.review_result_available) {
            if (!reviewStatusHasTrustedResult(value, fallback)) {
                if (effective_failure == null) effective_failure = reviewUntrustedSourceFailureInfo();
            } else {
                const dual_parse_opt = dualParseVerdictAlloc(allocator, value) catch null;
                if (dual_parse_opt) |dual_parse| {
                    defer dual_parse.deinit(allocator);
                    finding_count = dual_parse.structured_findings;
                    if (std.mem.eql(u8, dual_parse.verdict, "mismatch") and effective_failure == null) {
                        effective_failure = .{
                            .code = "review_parse_mismatch",
                            .hint = "structured reviewResult findings and rendered review text disagree",
                        };
                    }
                    clean = effective_failure == null and dual_parse.structured_findings == 0 and !std.mem.eql(u8, dual_parse.verdict, "mismatch");
                } else {
                    finding_count = reviewFindingCount(allocator, value.review_result_json) catch 0;
                    clean = effective_failure == null and finding_count.? == 0;
                }
            }
        }
    }

    return try buildReviewVerdictJsonAlloc(
        allocator,
        if (fallback != null) "cas-native-fallback" else "cas-start-wait",
        clean,
        finding_count,
        effective_failure,
        identity,
        review_thread_id,
        review_turn_id,
        if (record_path.len == 0) null else record_path,
        if (event_log_path.len == 0) null else event_log_path,
        review_result_json,
    );
}

fn reviewVerdictJsonForStatusAlloc(
    allocator: std.mem.Allocator,
    backend_class: []const u8,
    identity: TargetIdentity,
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: []const u8,
    event_log_path: []const u8,
    status: ReviewStatus,
    failure: ?FailureInfo,
) !?[]u8 {
    if (!status.review_result_available and failure == null) return null;

    var effective_failure = failure;
    var clean: ?bool = false;
    var finding_count: ?usize = 0;
    const review_result_json = status.review_result_json;

    if (status.review_result_available) {
        if (!reviewStatusHasTrustedResult(status, null)) {
            if (effective_failure == null) effective_failure = reviewUntrustedSourceFailureInfo();
        } else {
            const dual_parse_opt = dualParseVerdictAlloc(allocator, status) catch null;
            if (dual_parse_opt) |dual_parse| {
                defer dual_parse.deinit(allocator);
                finding_count = dual_parse.structured_findings;
                if (std.mem.eql(u8, dual_parse.verdict, "mismatch") and effective_failure == null) {
                    effective_failure = .{
                        .code = "review_parse_mismatch",
                        .hint = "structured reviewResult findings and rendered review text disagree",
                    };
                }
                clean = effective_failure == null and dual_parse.structured_findings == 0 and !std.mem.eql(u8, dual_parse.verdict, "mismatch");
            } else {
                finding_count = reviewFindingCount(allocator, status.review_result_json) catch 0;
                clean = effective_failure == null and finding_count.? == 0;
            }
        }
    }

    return try buildReviewVerdictJsonAlloc(
        allocator,
        backend_class,
        clean,
        finding_count,
        effective_failure,
        identity,
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
    fallback: ?NativeFallbackResult,
) !void {
    var scratch_arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer scratch_arena.deinit();
    const allocator = scratch_arena.allocator();
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    const effective_failure = effectiveFailureWithFallback(failure, fallback);
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
        status,
        timed_out,
        waited,
        effective_failure,
        fallback,
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
            .imported_from_receipt = false,
            .tuple_current_at_record_time = true,
            .created_at = timestamp,
            .updated_at = timestamp,
        }) catch null;
        defer if (shadow_record_path) |path| allocator.free(path);
    }

    if (std.mem.eql(u8, receipt.surface_action, "run")) {
        if (review_verdict_json_opt) |review_verdict_json| {
            const synthetic_receipt_json = try casRunSyntheticReceiptJsonAlloc(
                allocator,
                cwd,
                identity,
                parent_thread_id,
                review_thread_id,
                review_turn_id,
                record_path,
                event_log_path,
                receipt,
                review_verdict_json,
            );
            defer allocator.free(synthetic_receipt_json);
            const normalized = try normalizeReceiptFromJsonAlloc(allocator, record_path, synthetic_receipt_json, true, .{
                .requested_identity = identity,
                .requested_identity_required = true,
            });
            defer normalized.deinit(allocator);
            const broker = receipt.review_broker_decision orelse ReviewBrokerDecision{
                .action = "created_new",
                .reason = "run completed without an explicit broker decision",
                .reviewThreadId = review_thread_id,
                .recordPath = record_path,
                .eventLogPath = event_log_path,
            };
            try writeCasRunEnvelopeFromReceipt(allocator, stdout, normalized, broker, receipt.fresh_attempt_required);
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
                parent_thread_id,
                review_thread_id,
                review_turn_id,
                record_path,
                event_log_path,
                receipt,
                review_verdict_json,
            );
            defer allocator.free(synthetic_receipt_json);
            const normalized = try normalizeReceiptFromJsonAlloc(allocator, record_path, synthetic_receipt_json, true, .{
                .requested_identity = identity,
                .requested_identity_required = true,
            });
            defer normalized.deinit(allocator);
            const timestamp = try casRerTimestampAlloc(allocator);
            defer allocator.free(timestamp);
            const shadow_record_path = writeCasRerShadowRecordFromReceipt(allocator, normalized, .{
                .command_surface = "start_wait",
                .backend_selected = "cas-start-wait",
                .broker_action = "created_new",
                .broker_reason = "low-level start --wait output shadowed into CAS-RER-v1",
                .imported_from_receipt = false,
                .tuple_current_at_record_time = true,
                .created_at = timestamp,
                .updated_at = timestamp,
            }) catch null;
            defer if (shadow_record_path) |path| allocator.free(path);
        }
    }

    try stdout.print(
        "{{\"demo\":\"cas-review-session\",\"action\":{s},\"reviewBrokerDecision\":{s},\"cwd\":{s},\"parentThreadId\":{s}",
        .{
            surface_action_json,
            broker_decision_json,
            try quoteJsonStringAlloc(allocator, cwd),
            try quoteJsonStringAlloc(allocator, parent_thread_id),
        },
    );
    try writeReviewAttemptFields(stdout, attempt_fields);
    try stdout.print(
        ",\"delivery\":\"detached\",\"target\":{s},\"recordPath\":{s},\"eventLogPath\":{s},\"codexVersion\":{s},\"resolvedCodexPath\":{s},\"resolvedCodexVersion\":{s},\"compatibilityVerdict\":{s},\"selectedTransport\":{s},\"selectionReason\":{s},\"degradedFallback\":{s},\"managedServerPid\":{s},\"managedServerListenUrl\":{s},\"managedServerStderrLogPath\":{s},\"orphanTtlSeconds\":{s},\"requestedMultiAgentMode\":{s},\"effectiveMultiAgentMode\":{s},\"multiAgentModeSupport\":{s},\"multiAgentModeMetricEligible\":{s},\"waited\":{s},\"timedOut\":{s},\"threadStatus\":{s},\"turnStatus\":{s}",
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
            if (receipt.degraded_fallback) "true" else "false",
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
    try stdout.print(
        ",\"turnCount\":{d},\"materialized\":{s},\"rolloutPath\":{s},\"failureCode\":{s},\"failureHint\":{s}{s},\"fallbackUsed\":{s},\"fallbackTransport\":{s},\"fallbackExitCode\":{s},\"fallbackOutputText\":{s},\"fallbackErrorText\":{s},\"hookSummary\":{s},\"reviewResultAvailable\":{s},\"reviewResultSource\":{s},\"reviewResult\":{s}{s}}}\n",
        .{
            turn_count,
            materialized_json,
            rollout_path_json,
            failure_code_json,
            failure_hint_json,
            failure_control_suffix,
            if (fallback != null) "true" else "false",
            fallback_transport_json,
            fallback_exit_code_json,
            fallback_stdout_json,
            fallback_stderr_json,
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
    if (isTerminalTurnStatus(status.turn_status) and
        (detectAccountResourceExhaustion(status.raw_response_json) or
            if (status.turn_error_message) |message| detectAccountResourceExhaustion(message) else false or
                if (status.review_text) |text| detectAccountResourceExhaustion(text) else false))
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

fn terminalLockFailureForStatus(allocator: std.mem.Allocator, status: ReviewStatus) ?FailureInfo {
    if (status.review_result_available and !reviewStatusHasTrustedResult(status, null)) return reviewUntrustedSourceFailureInfo();
    if (status.review_result_available) {
        const dual_parse = dualParseVerdictAlloc(allocator, status) catch return null;
        defer dual_parse.deinit(allocator);
        if (std.mem.eql(u8, dual_parse.verdict, "mismatch")) {
            return .{
                .code = "review_parse_mismatch",
                .hint = "structured reviewResult findings and rendered review text disagree",
            };
        }
    }
    return null;
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

fn nonEmptyOptional(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (value.len == 0) null else value;
}

fn reviewAttemptExists(review_thread_id: ?[]const u8) bool {
    return nonEmptyOptional(review_thread_id) != null;
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
    if (std.mem.eql(u8, action, "lane-start")) return "pre_lane_start";
    if (std.mem.eql(u8, action, "lane-review")) return "pre_review_start";
    if (std.mem.eql(u8, method, "review/start")) return "pre_review_start";
    return "pre_lane_start";
}

fn laneReceiptPhase(alive: bool, last_review_thread_id: ?[]const u8) []const u8 {
    if (reviewAttemptExists(last_review_thread_id)) return "review_terminal";
    return if (alive) "lane_started" else "pre_lane_start";
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

fn stringFieldAny(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (jsonStringField(obj, key)) |value| return value;
    }
    return null;
}

fn boolFieldAny(obj: std.json.ObjectMap, keys: []const []const u8) ?bool {
    for (keys) |key| {
        if (jsonBoolField(obj, key)) |value| return value;
    }
    return null;
}

fn fieldPresentNonNull(obj: std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return false;
    return switch (value) {
        .null => false,
        else => true,
    };
}

fn fieldAnyPresentNonNull(obj: std.json.ObjectMap, keys: []const []const u8) bool {
    for (keys) |key| {
        if (fieldPresentNonNull(obj, key)) return true;
    }
    return false;
}

fn intFieldAny(obj: std.json.ObjectMap, keys: []const []const u8) ?i64 {
    for (keys) |key| {
        if (jsonI64Field(obj, key)) |value| return value;
    }
    return null;
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

fn jsonValueTruthy(value: ?std.json.Value) bool {
    const actual = value orelse return false;
    return switch (actual) {
        .null => false,
        .bool => |flag| flag,
        .integer => |number| number != 0,
        .float => |number| number != 0,
        .string => |text| text.len != 0,
        .array => |arr| arr.items.len != 0,
        .object => |obj| obj.count() != 0,
        else => true,
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
        std.mem.eql(u8, status, "parse_mismatch") or
        std.mem.eql(u8, status, "review_transport_failure") or
        std.mem.eql(u8, status, "incomplete");
}

fn normalizedAttemptPhase(root: std.json.ObjectMap, status: []const u8, tuple_verdict_exists: bool, review_thread_id: ?[]const u8) []const u8 {
    if (tuple_verdict_exists) return "normalized_verdict";
    if (jsonStringField(root, "reviewAttemptPhase")) |phase| return phase;
    if (reviewAttemptExists(review_thread_id)) {
        if (std.mem.eql(u8, status, "timeout")) return "review_waiting";
        if (std.mem.eql(u8, status, "review_transport_failure")) return "review_waiting";
        if (terminalReceiptStatus(status)) return "review_terminal";
        return "review_waiting";
    }
    return "pre_lane_start";
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

    // Any non-empty retired object remains canonicalized historical evidence.
    // Active commands still accept only the typed two-field shape above.
    if (value != .object or value.object.count() == 0) return error.InvalidWorkflowBinding;
    if (value.object.contains("requestId") or value.object.contains("requestFingerprint")) return error.InvalidWorkflowBinding;
    return allocator.dupe(u8, raw);
}

fn workflowBindingJsonFromRootAlloc(allocator: std.mem.Allocator, root: std.json.ObjectMap) !?[]const u8 {
    const nested_value: ?std.json.Value = if (root.get("record")) |record_value| switch (record_value) {
        .object => |record| record.get("workflowBinding"),
        else => null,
    } else null;
    const candidates = [_]?std.json.Value{
        root.get("workflowBinding"),
        root.get("workflow_binding"),
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

fn readReviewTextFromEventLogAlloc(allocator: std.mem.Allocator, event_log_path: []const u8) !?[]u8 {
    const raw = try readFileAlloc(allocator, event_log_path, 16 * 1024 * 1024);
    defer allocator.free(raw);

    var latest_review_text: ?[]u8 = null;
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
        if (!std.mem.eql(u8, method, "item/completed")) continue;

        const payload_text = jsonStringField(root_obj, "payload") orelse continue;
        var payload_parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_text, .{}) catch continue;
        defer payload_parsed.deinit();
        const payload_obj = switch (payload_parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        const params_obj = core_json.objectField(payload_obj, "params") orelse continue;
        const item_obj = core_json.objectField(params_obj, "item") orelse continue;
        const item_type = core_json.stringField(item_obj, "type") orelse continue;
        if (!std.mem.eql(u8, item_type, "exitedReviewMode")) continue;
        const review_text = core_json.stringField(item_obj, "review") orelse continue;
        if (latest_review_text) |existing| allocator.free(existing);
        latest_review_text = try allocator.dupe(u8, review_text);
    }
    return latest_review_text;
}

fn readRolloutReviewResultFromEventLogAlloc(allocator: std.mem.Allocator, event_log_path: []const u8) !?[]u8 {
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
        const rollout_path = core_json.stringField(thread_obj, "path") orelse continue;
        const review_result = (try readReviewResultJsonFromRolloutAlloc(allocator, rollout_path)) orelse continue;
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
    if (jsonStringField(root, "lane_id") != null and root.get("reviewVerdict") == null) return error.NotReviewReceipt;
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
    const account_failure = rootHasAccountResourceExhaustion(root) or
        if (optionalStringFromVerdictOrRoot(verdict, root, "failureCode")) |code| failureCodeIsAccountResourceExhausted(code) else false;
    const raw_failure_code = optionalStringFromVerdictOrRoot(verdict, root, "failureCode");
    const status_without_binding = if (account_failure and !reviewAttemptExists(review_thread_id))
        "incomplete"
    else if (account_failure)
        "account_resource_exhausted"
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
    const review_attempt_phase = if (account_failure and reviewAttemptExists(review_thread_id))
        "review_terminal"
    else
        normalizedAttemptPhase(root, final_status, tuple_verdict_exists, review_thread_id);
    const findings_json = if (verdict.get("findings")) |value|
        try stringifyJsonValueAlloc(allocator, value)
    else
        try allocator.dupe(u8, "[]");
    const account_fingerprint_reduced_protection = receiptPrincipalReduced(verdict, root);
    const principal_strength = receiptPrincipalStrength(verdict, root);

    return .{
        .source_path = try allocator.dupe(u8, source_path),
        .status = try allocator.dupe(u8, final_status),
        .backend_class = try allocator.dupe(u8, backend_class),
        .clean = final_clean,
        .finding_count = finding_count,
        .review_attempt_phase = try allocator.dupe(u8, review_attempt_phase),
        .review_attempt_exists = reviewAttemptExists(review_thread_id),
        .tuple_verdict_exists = tuple_verdict_exists,
        .principal_strength = principal_strength,
        .account_fingerprint_reduced_protection = account_fingerprint_reduced_protection,
        .base_sha = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "baseSha")),
        .head_sha = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "headSha")),
        .target_fingerprint = try dupOptional(allocator, optionalStringFromVerdictOrRoot(verdict, root, "targetFingerprint")),
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
    const failure_code = jsonStringField(root, "failureCode");
    const account_failure = if (failure_code) |code| failureCodeIsAccountResourceExhausted(code) or rootHasAccountResourceExhaustion(root) else rootHasAccountResourceExhaustion(root);
    const status = if (!reviewAttemptExists(review_thread_id) and std.mem.eql(u8, failure_code orelse "", "pre_review_lane_transport_lost"))
        "pre_review_transport_failure"
    else if (!reviewAttemptExists(review_thread_id))
        "incomplete"
    else if (account_failure)
        "account_resource_exhausted"
    else if (failure_code) |code|
        reviewVerdictStatus(false, 0, .{ .code = code, .hint = jsonStringField(root, "failureHint") orelse "" }, review_thread_id)
    else
        "incomplete";
    _ = context;
    const tuple_verdict_exists = false;
    const account_fingerprint_reduced_protection = receiptPrincipalReduced(root, root);
    const principal_strength = receiptPrincipalStrength(root, root);
    return .{
        .source_path = try allocator.dupe(u8, source_path),
        .status = try allocator.dupe(u8, status),
        .backend_class = try allocator.dupe(u8, if (attemptOnlyReceiptIsLaneBackend(root)) "cas-lane" else "cas-receipt-normalized"),
        .clean = false,
        .finding_count = 0,
        .review_attempt_phase = try allocator.dupe(u8, normalizedAttemptPhase(root, status, tuple_verdict_exists, review_thread_id)),
        .review_attempt_exists = reviewAttemptExists(review_thread_id),
        .tuple_verdict_exists = tuple_verdict_exists,
        .principal_strength = principal_strength,
        .account_fingerprint_reduced_protection = account_fingerprint_reduced_protection,
        .base_sha = try dupOptional(allocator, jsonStringField(root, "baseSha")),
        .head_sha = try dupOptional(allocator, jsonStringField(root, "headSha")),
        .target_fingerprint = try dupOptional(allocator, jsonStringField(root, "targetFingerprint")),
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

fn attemptOnlyReceiptIsLaneBackend(root: std.json.ObjectMap) bool {
    const action = jsonStringField(root, "action") orelse return false;
    return std.mem.eql(u8, action, "lane-review") or std.mem.eql(u8, action, "lane-smoke");
}

fn normalizeStartReceiptAlloc(allocator: std.mem.Allocator, source_path: []const u8, root: std.json.ObjectMap, context: NormalizeContext) !NormalizedReceipt {
    const review_thread_id = jsonStringField(root, "reviewThreadId");
    const failure_code = jsonStringField(root, "failureCode");
    const review_result_json = try jsonFieldAsJsonAlloc(allocator, root, "reviewResult");
    defer if (review_result_json) |value| allocator.free(value);
    const finding_count = try reviewFindingCount(allocator, review_result_json);
    const account_failure = if (failure_code) |code| failureCodeIsAccountResourceExhausted(code) or rootHasAccountResourceExhaustion(root) else rootHasAccountResourceExhaustion(root);
    const status = if (account_failure and !reviewAttemptExists(review_thread_id))
        "incomplete"
    else if (account_failure)
        "account_resource_exhausted"
    else if (jsonBoolField(root, "timedOut") orelse false)
        "timeout"
    else if (!reviewAttemptExists(review_thread_id))
        "incomplete"
    else if (failure_code) |code|
        reviewVerdictStatus(false, finding_count, .{ .code = code, .hint = jsonStringField(root, "failureHint") orelse "" }, review_thread_id)
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
    return .{
        .source_path = try allocator.dupe(u8, source_path),
        .status = try allocator.dupe(u8, final_status),
        .backend_class = try allocator.dupe(u8, if (std.mem.eql(u8, jsonStringField(root, "fallbackTransport") orelse "", "native-review")) "cas-native-fallback" else "cas-start-wait"),
        .clean = final_clean,
        .finding_count = finding_count,
        .review_attempt_phase = try allocator.dupe(u8, normalizedAttemptPhase(root, final_status, tuple_verdict_exists, review_thread_id)),
        .review_attempt_exists = reviewAttemptExists(review_thread_id),
        .tuple_verdict_exists = tuple_verdict_exists,
        .principal_strength = principal_strength,
        .account_fingerprint_reduced_protection = account_fingerprint_reduced_protection,
        .base_sha = try dupOptional(allocator, jsonStringField(root, "baseSha")),
        .head_sha = try dupOptional(allocator, jsonStringField(root, "headSha")),
        .target_fingerprint = try dupOptional(allocator, jsonStringField(root, "targetFingerprint")),
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

fn storedReceiptBackendClass(root: std.json.ObjectMap) []const u8 {
    if (std.mem.eql(u8, jsonStringField(root, "terminal_fallback_transport") orelse "", "native-review")) return "cas-native-fallback";
    if (std.mem.startsWith(u8, jsonStringField(root, "transport_selection_reason") orelse "", "persistent_review_lane")) return "cas-lane";
    return "cas-start-wait";
}

fn normalizeStoredSessionRecordReceiptAlloc(allocator: std.mem.Allocator, source_path: []const u8, root: std.json.ObjectMap, recover_event_logs: bool, context: NormalizeContext) !NormalizedReceipt {
    const review_thread_id = jsonStringField(root, "review_thread_id") orelse return error.NotReviewReceipt;
    const review_turn_id = jsonStringField(root, "review_turn_id");
    const event_log_path = jsonStringField(root, "event_log_path");
    var result_source = jsonStringField(root, "terminal_review_result_source");

    var review_result_json: ?[]u8 = null;
    defer if (review_result_json) |value| allocator.free(value);
    if (jsonStringField(root, "terminal_review_result_json")) |json| {
        review_result_json = try allocator.dupe(u8, json);
    } else if (recover_event_logs) {
        if (event_log_path) |path| {
            const recovered_rollout_result = readRolloutReviewResultFromEventLogAlloc(allocator, path) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            if (recovered_rollout_result) |rollout_result| {
                review_result_json = rollout_result;
                result_source = "rollout_exited_review_mode";
            } else {
                const recovered_review_text = readReviewTextFromEventLogAlloc(allocator, path) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => null,
                };
                if (recovered_review_text) |review_text| {
                    defer allocator.free(review_text);
                    if (!std.mem.eql(u8, review_text, review_fallback_text)) {
                        review_result_json = try buildReviewResultJsonFromRenderedTextAlloc(allocator, review_text);
                        result_source = "notification_exited_review_mode";
                    }
                }
            }
        }
    }
    const trusted_rollout_result = review_result_json != null and std.mem.eql(u8, result_source orelse "", "rollout_exited_review_mode");
    const event_log_account_failure = if (recover_event_logs and !trusted_rollout_result) blk: {
        const path = event_log_path orelse break :blk false;
        break :blk eventLogHasAccountResourceExhaustion(allocator, path) catch false;
    } else false;

    const finding_count = try reviewFindingCount(allocator, review_result_json);
    const missing_completed_result = review_result_json == null and
        std.mem.eql(u8, jsonStringField(root, "last_observed_status") orelse "", "completed");
    const failure_code: ?[]const u8 = if (event_log_account_failure)
        "account_resource_exhausted"
    else if (missing_completed_result)
        "review_output_missing"
    else
        null;
    const failure_hint: ?[]const u8 = if (event_log_account_failure)
        account_resource_exhausted_hint
    else if (missing_completed_result)
        "stored review session record did not include a materialized reviewResult or recoverable exitedReviewMode text"
    else
        null;
    const status = if (finding_count > 0)
        "findings"
    else if (event_log_account_failure)
        "account_resource_exhausted"
    else if (missing_completed_result)
        "incomplete"
    else if (std.mem.eql(u8, result_source orelse "", "rollout_exited_review_mode"))
        "clean"
    else
        "incomplete";
    const findings_json = compactFindingsJsonAlloc(allocator, review_result_json) catch try allocator.dupe(u8, "[]");
    const binding_failure = if (context.requested_identity_required) blk: {
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
    else if (std.mem.eql(u8, final_status, "account_resource_exhausted") or isTerminalTurnStatus(jsonStringField(root, "last_observed_status") orelse ""))
        "review_terminal"
    else
        "review_waiting";
    const account_fingerprint_reduced_protection = receiptPrincipalReduced(root, root);
    const principal_strength = receiptPrincipalStrength(root, root);

    return .{
        .source_path = try allocator.dupe(u8, source_path),
        .status = try allocator.dupe(u8, final_status),
        .backend_class = try allocator.dupe(u8, storedReceiptBackendClass(root)),
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

fn summarizeReceipts(receipts: []const NormalizedReceipt) ReceiptSummary {
    var summary = ReceiptSummary{ .total = receipts.len };
    for (receipts) |receipt| {
        if (std.mem.eql(u8, receipt.status, "clean")) summary.clean += 1 else if (std.mem.eql(u8, receipt.status, "findings")) summary.findings += 1 else if (std.mem.eql(u8, receipt.status, "timeout")) summary.timeout += 1 else if (std.mem.eql(u8, receipt.status, "pre_review_transport_failure")) summary.pre_review_transport_failure += 1 else if (std.mem.eql(u8, receipt.status, "account_resource_exhausted")) summary.account_resource_exhausted += 1 else if (std.mem.eql(u8, receipt.status, "parse_mismatch")) summary.parse_mismatch += 1 else if (std.mem.eql(u8, receipt.status, "review_transport_failure")) summary.review_transport_failure += 1 else if (std.mem.eql(u8, receipt.status, "incomplete")) summary.incomplete += 1 else summary.other_status += 1;
        if (std.mem.eql(u8, receipt.backend_class, "cas-lane")) summary.cas_lane += 1 else if (std.mem.eql(u8, receipt.backend_class, "cas-native-fallback")) summary.cas_native_fallback += 1 else summary.other_backend += 1;
    }
    return summary;
}

fn receiptHasCompleteTuple(receipt: NormalizedReceipt) bool {
    return nonEmptyOptional(receipt.base_sha) != null and
        nonEmptyOptional(receipt.head_sha) != null and
        nonEmptyOptional(receipt.target_fingerprint) != null;
}

fn receiptTupleMatchesIdentity(receipt: NormalizedReceipt, identity: TargetIdentity) bool {
    if (!identityHasCompleteTuple(identity)) return false;
    return optionalStringsEqual(receipt.base_sha, identity.base_sha) and
        optionalStringsEqual(receipt.head_sha, identity.head_sha) and
        optionalStringsEqual(receipt.target_fingerprint, identity.fingerprint);
}

const CasRerProjectionOptions = struct {
    command_surface: []const u8 = "import",
    backend_selected: []const u8 = "imported-legacy",
    broker_action: []const u8 = "imported_legacy",
    broker_reason: []const u8 = "legacy review artifact normalized into CAS-RER-v1",
    repo_realpath_override: ?[]const u8 = null,
    resolved_codex_path_override: ?[]const u8 = null,
    resolved_codex_version_override: ?[]const u8 = null,
    account_fingerprint_override: ?[]const u8 = null,
    fresh_attempt_required: bool = false,
    tuple_current_at_record_time: bool = false,
    imported_from_receipt: bool = true,
    created_at: []const u8 = "1970-01-01T00:00:00Z",
    updated_at: []const u8 = "1970-01-01T00:00:00Z",
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
        .imported_from_receipt = false,
        .tuple_current_at_record_time = true,
        .created_at = timestamp,
        .updated_at = timestamp,
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

fn casRerFallbackUsed(receipt: NormalizedReceipt) bool {
    return std.mem.eql(u8, receipt.backend_class, "cas-native-fallback");
}

fn casRerPrincipalFingerprintUsable(fingerprint: ?[]const u8) bool {
    const value = nonEmptyOptional(fingerprint) orelse return false;
    return !std.mem.eql(u8, value, unknown_account_fingerprint);
}

fn casRerPrincipalProofUsable(receipt: NormalizedReceipt) bool {
    return std.mem.eql(u8, casRerPrincipalKind(receipt), "strong") and
        !receipt.account_fingerprint_reduced_protection and
        !casRerFallbackUsed(receipt) and
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
    const effective_repo_realpath = opts.repo_realpath_override orelse receipt.repo_realpath orelse "";
    const effective_resolved_codex_path = opts.resolved_codex_path_override orelse receipt.resolved_codex_path orelse "";
    const effective_resolved_codex_version = opts.resolved_codex_version_override orelse receipt.resolved_codex_version orelse "";
    const effective_account_fingerprint = opts.account_fingerprint_override orelse receipt.account_fingerprint orelse "";
    const legacy_material = try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}\x1f{d}\x1f{s}\x1f{s}", .{
        effective_repo_realpath,
        effective_resolved_codex_path,
        effective_resolved_codex_version,
        effective_account_fingerprint,
        receipt.codex_thread_id orelse "",
        receipt.backend_class,
        receipt.principal_strength,
        if (receipt.account_fingerprint_reduced_protection) "reduced-protection" else "full-protection",
        opts.command_surface,
        opts.backend_selected,
        opts.broker_action,
        opts.broker_reason,
        if (opts.fresh_attempt_required) "fresh" else "not-fresh",
        if (opts.tuple_current_at_record_time) "current" else "not-current",
        if (opts.imported_from_receipt) "imported" else "native",
        receipt.status,
        receipt.review_thread_id orelse "",
        receipt.review_turn_id orelse "",
        receipt.base_sha orelse "",
        receipt.head_sha orelse "",
        receipt.target_fingerprint orelse "",
        receipt.failure_code orelse "",
        receipt.finding_count,
        if (receipt.clean) "clean" else "not-clean",
        receipt.findings_json,
    });
    defer allocator.free(legacy_material);
    const material = if (receipt.workflow_binding_json) |workflow_binding_json|
        try std.fmt.allocPrint(allocator, "{s}\x1fworkflowBinding\x1f{s}", .{ legacy_material, workflow_binding_json })
    else
        try allocator.dupe(u8, legacy_material);
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

fn writeCasRerTupleObject(writer: *std.Io.Writer, receipt: NormalizedReceipt, opts: CasRerProjectionOptions) !void {
    const repo_realpath = opts.repo_realpath_override orelse receipt.repo_realpath;
    const resolved_codex_path = opts.resolved_codex_path_override orelse receipt.resolved_codex_path;
    const resolved_codex_version = opts.resolved_codex_version_override orelse receipt.resolved_codex_version;
    try writer.writeByte('{');
    try writeJsonString(writer, "repoRealpath");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, repo_realpath);
    try writer.writeByte(',');
    try writeJsonString(writer, "target");
    try writer.writeAll(":null,");
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
    try writeNullableJsonString(writer, resolved_codex_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "resolvedCodexVersion");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, resolved_codex_version);
    try writer.writeByte(',');
    try writeJsonString(writer, "codexThreadId");
    try writer.writeByte(':');
    try writeNullableJsonString(writer, receipt.codex_thread_id);
    try writer.writeByte(',');
    try writeJsonString(writer, "diffScope");
    try writer.writeAll(":\"entire_pr\",");
    try writeJsonString(writer, "tupleCurrentAtRecordTime");
    try writer.writeByte(':');
    try writer.writeAll(if (opts.tuple_current_at_record_time) "true" else "false");
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
    if (receipt.retryable_same_tuple_now) |value| try writer.writeAll(if (value) "true" else "false") else try writer.writeAll("null");
    try writer.writeByte('}');
}

fn casRerPrincipalProofUsableWithFingerprint(receipt: NormalizedReceipt, account_fingerprint: ?[]const u8) bool {
    return std.mem.eql(u8, casRerPrincipalKind(receipt), "strong") and
        !receipt.account_fingerprint_reduced_protection and
        !casRerFallbackUsed(receipt) and
        casRerPrincipalFingerprintUsable(account_fingerprint);
}

fn writeCasRerPrincipalObject(writer: *std.Io.Writer, receipt: NormalizedReceipt, opts: CasRerProjectionOptions) !void {
    const account_fingerprint = opts.account_fingerprint_override orelse receipt.account_fingerprint;
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
    try writer.writeAll(if (casRerFallbackUsed(receipt)) "true" else "false");
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

fn writeCasRerLegacyObject(writer: *std.Io.Writer, receipt: NormalizedReceipt, opts: CasRerProjectionOptions) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "importedFromReceipt");
    try writer.writeByte(':');
    try writer.writeAll(if (opts.imported_from_receipt) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "sourcePath");
    try writer.writeByte(':');
    try writeJsonString(writer, receipt.source_path);
    try writer.writeByte(',');
    try writeJsonString(writer, "normalizationWarnings");
    if (receipt.tuple_verdict_exists or receiptHasCompleteTuple(receipt)) {
        try writer.writeAll(":[]");
    } else {
        try writer.writeAll(":[\"missing tuple verdict binding\"]");
    }
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
    try writeJsonString(writer, opts.created_at);
    try writer.writeByte(',');
    try writeJsonString(writer, "updatedAt");
    try writer.writeByte(':');
    try writeJsonString(writer, opts.updated_at);
    try writer.writeByte(',');
    try writeJsonString(writer, "command");
    try writer.writeByte(':');
    try writeCasRerCommandObject(writer, receipt, opts);
    try writer.writeByte(',');
    try writeJsonString(writer, "tuple");
    try writer.writeByte(':');
    try writeCasRerTupleObject(writer, receipt, opts);
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
    try writeCasRerPrincipalObject(writer, receipt, opts);
    try writer.writeByte(',');
    try writeJsonString(writer, "attachments");
    try writer.writeByte(':');
    try writeCasRerAttachmentsObject(writer, receipt);
    try writer.writeByte(',');
    try writeJsonString(writer, "legacy");
    try writer.writeByte(':');
    try writeCasRerLegacyObject(writer, receipt, opts);
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
    if (receipt.retryable_same_tuple_now) |value| try writer.writeAll(if (value) "true" else "false") else try writer.writeAll("null");
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
        "{{\"total\":{d},\"status\":{{\"clean\":{d},\"findings\":{d},\"timeout\":{d},\"pre_review_transport_failure\":{d},\"account_resource_exhausted\":{d},\"parse_mismatch\":{d},\"review_transport_failure\":{d},\"incomplete\":{d},\"other\":{d}}},\"backendClass\":{{\"cas-lane\":{d},\"cas-native-fallback\":{d},\"other\":{d}}}}}",
        .{
            summary.total,
            summary.clean,
            summary.findings,
            summary.timeout,
            summary.pre_review_transport_failure,
            summary.account_resource_exhausted,
            summary.parse_mismatch,
            summary.review_transport_failure,
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
        try stdout.print("# summary total={d} clean={d} findings={d} timeout={d} pre_review_transport_failure={d} account_resource_exhausted={d} parse_mismatch={d} review_transport_failure={d} incomplete={d} other={d} cas-lane={d} cas-native-fallback={d} other-backend={d}\n", .{
            value.total,
            value.clean,
            value.findings,
            value.timeout,
            value.pre_review_transport_failure,
            value.account_resource_exhausted,
            value.parse_mismatch,
            value.review_transport_failure,
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

fn fallbackHasAccountResourceExhaustion(fallback: ?NativeFallbackResult) bool {
    const value = fallback orelse return false;
    if (value.stderr_text) |text| {
        if (detectAccountResourceExhaustion(text)) return true;
    }
    if (value.stdout_text) |text| {
        if (detectAccountResourceExhaustion(text)) return true;
    }
    return false;
}

fn effectiveFailureWithFallback(failure: ?FailureInfo, fallback: ?NativeFallbackResult) ?FailureInfo {
    if (fallbackHasAccountResourceExhaustion(fallback)) return accountResourceExhaustedFailureInfo();
    return failure;
}

fn reviewUntrustedSourceFailureInfo() FailureInfo {
    return .{
        .code = "review_untrusted_source",
        .hint = "reviewResult was reconstructed from notification-rendered text; wait for rollout-backed structured review output before treating it as proof",
    };
}

fn reviewStatusHasTrustedResult(status: ReviewStatus, fallback: ?NativeFallbackResult) bool {
    if (!status.review_result_available) return false;
    if (fallback != null) return true;
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

fn receiptContainsUsageLimit(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !bool {
    const text = try stringifyJsonValueAlloc(allocator, std.json.Value{ .object = obj });
    defer allocator.free(text);
    return std.mem.indexOf(u8, text, "usageLimitExceeded") != null or
        std.mem.indexOf(u8, text, "quota exceeded") != null or
        std.mem.indexOf(u8, text, "rate limit exceeded") != null;
}

fn appendGateError(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try errors.append(allocator, try std.fmt.allocPrint(allocator, fmt, args));
}

fn gateResultFromSingleErrorAlloc(allocator: std.mem.Allocator, path: []const u8, message: []const u8) !GateResult {
    const errors = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(errors);
    errors[0] = try allocator.dupe(u8, message);
    return .{
        .path = try allocator.dupe(u8, path),
        .errors = errors,
    };
}

fn reviewPhaseAllowed(value: []const u8) bool {
    return std.mem.eql(u8, value, "pre_lane_start") or
        std.mem.eql(u8, value, "lane_started") or
        std.mem.eql(u8, value, "pre_review_start") or
        std.mem.eql(u8, value, "review_started") or
        std.mem.eql(u8, value, "review_waiting") or
        std.mem.eql(u8, value, "review_terminal") or
        std.mem.eql(u8, value, "normalized_verdict");
}

fn reviewStatusAllowed(value: []const u8) bool {
    return std.mem.eql(u8, value, "clean") or
        std.mem.eql(u8, value, "findings") or
        std.mem.eql(u8, value, "timeout") or
        std.mem.eql(u8, value, "pre_review_transport_failure") or
        std.mem.eql(u8, value, "review_transport_failure") or
        std.mem.eql(u8, value, "account_resource_exhausted") or
        std.mem.eql(u8, value, "parse_mismatch") or
        std.mem.eql(u8, value, "review_untrusted_source") or
        std.mem.eql(u8, value, "incomplete");
}

fn backendClassAllowed(value: []const u8) bool {
    return std.mem.eql(u8, value, "cas-lane") or
        std.mem.eql(u8, value, "cas-start-wait") or
        std.mem.eql(u8, value, "cas-native-fallback") or
        std.mem.eql(u8, value, "cas-receipt-normalized");
}

fn reviewTupleLockStateAllowed(value: []const u8) bool {
    return std.mem.eql(u8, value, "starting_lane") or
        std.mem.eql(u8, value, "pre_review_start_failed") or
        std.mem.eql(u8, value, "review_started") or
        std.mem.eql(u8, value, "waiting") or
        std.mem.eql(u8, value, "terminal") or
        std.mem.eql(u8, value, "normalized") or
        std.mem.eql(u8, value, "account_resource_exhausted") or
        std.mem.eql(u8, value, "stale");
}

fn reviewTupleLockStateActive(value: []const u8) bool {
    return std.mem.eql(u8, value, "review_started") or std.mem.eql(u8, value, "waiting");
}

fn writeGateResultJson(writer: *std.Io.Writer, result: GateResult) !void {
    try writer.writeByte('{');
    try writeJsonString(writer, "errors");
    try writer.writeByte(':');
    try writer.writeByte('[');
    for (result.errors, 0..) |err, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, err);
    }
    try writer.writeByte(']');
    try writer.writeByte(',');
    try writeJsonString(writer, "ok");
    try writer.writeByte(':');
    try writer.writeAll(if (result.ok()) "true" else "false");
    try writer.writeByte(',');
    try writeJsonString(writer, "path");
    try writer.writeByte(':');
    try writeJsonString(writer, result.path);
    try writer.writeByte('}');
}

fn printGateResultsJson(results: []const GateResult) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (results.len == 1) {
        try writeGateResultJson(stdout, results[0]);
        try stdout.writeByte('\n');
        return;
    }
    try stdout.writeByte('[');
    for (results, 0..) |result, i| {
        if (i > 0) try stdout.writeByte(',');
        try writeGateResultJson(stdout, result);
    }
    try stdout.writeAll("]\n");
}

fn printGateResultsJsonl(results: []const GateResult) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    for (results) |result| {
        try writeGateResultJson(stdout, result);
        try stdout.writeByte('\n');
    }
}

fn printGateResultsText(results: []const GateResult) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stderr = &stderr_writer.interface;
    for (results) |result| {
        if (result.ok()) {
            try stdout.print("ok: {s}\n", .{result.path});
        } else {
            try stderr.print("failed: {s}\n", .{result.path});
            for (result.errors) |err| {
                try stderr.print("- {s}\n", .{err});
            }
        }
    }
}

fn rootHasAccountResourceExhaustion(root: std.json.ObjectMap) bool {
    const keys = [_][]const u8{
        "failureCode",
        "failureHint",
        "error",
        "fallbackErrorText",
        "fallbackOutputText",
        "rawReviewText",
        "reviewResult",
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
    if (std.mem.eql(u8, value, "pre_review_lane_transport_lost")) return "transport_pre_review";
    if (std.mem.eql(u8, value, "review_transport_lost") or std.mem.eql(u8, value, "lane_transport_lost")) return "transport_review_attempt";
    if (std.mem.indexOf(u8, value, "transport") != null) return "transport_review_attempt";
    if (std.mem.eql(u8, value, "wait_timed_out")) return "timeout";
    if (std.mem.indexOf(u8, value, "parse") != null) return "parse";
    if (std.mem.eql(u8, value, "review_untrusted_source")) return "review_output";
    if (std.mem.indexOf(u8, value, "output") != null) return "review_output";
    if (std.mem.eql(u8, value, "target_identity_unavailable") or std.mem.eql(u8, value, "tuple_mismatch")) return "caller_error";
    return null;
}

fn retryableSameTupleNowForCode(code: ?[]const u8) ?bool {
    const value = code orelse return null;
    if (failureCodeIsAccountResourceExhausted(value)) return false;
    if (std.mem.eql(u8, value, "pre_review_lane_transport_lost")) return true;
    if (std.mem.eql(u8, value, "review_transport_lost") or std.mem.eql(u8, value, "lane_transport_lost")) return true;
    if (std.mem.eql(u8, value, "wait_timed_out")) return true;
    return null;
}

fn eventLogHasAccountResourceExhaustion(allocator: std.mem.Allocator, event_log_path: []const u8) !bool {
    const raw = try readFileAlloc(allocator, event_log_path, 16 * 1024 * 1024);
    defer allocator.free(raw);
    return detectAccountResourceExhaustion(raw);
}

fn reviewVerdictStatus(clean: ?bool, finding_count: ?usize, failure: ?FailureInfo, review_thread_id: ?[]const u8) []const u8 {
    if (!reviewAttemptExists(review_thread_id)) {
        if (failure) |info| {
            if (std.mem.eql(u8, info.code, "pre_review_lane_transport_lost")) return "pre_review_transport_failure";
        }
        return "incomplete";
    }
    if (failure) |info| {
        if (std.mem.eql(u8, info.code, "wait_timed_out")) return "timeout";
        if (std.mem.eql(u8, info.code, "review_parse_mismatch")) return "parse_mismatch";
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
    if (std.mem.eql(u8, status, "no_attempt")) {
        if (failure_code) |code| {
            if (std.mem.eql(u8, code, "pre_review_lane_transport_lost")) return "pre_review_transport_failure";
        }
        return "incomplete";
    }
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
    review_thread_id: ?[]const u8,
    review_turn_id: ?[]const u8,
    record_path: ?[]const u8,
    event_log_path: ?[]const u8,
    review_result_json: ?[]const u8,
) ![]u8 {
    const findings_json = compactFindingsJsonAlloc(allocator, review_result_json) catch try allocator.dupe(u8, "[]");
    defer allocator.free(findings_json);
    const status = reviewVerdictStatus(clean, finding_count, failure, review_thread_id);
    const normalized_clean = std.mem.eql(u8, status, "clean") and (clean orelse false);
    const normalized_finding_count = finding_count orelse 0;
    const tuple_verdict_exists = reviewVerdictStatusIsTupleTerminal(status) and
        reviewAttemptExists(review_thread_id) and
        identityHasCompleteTuple(identity);
    const attempt_fields = identityReviewAttemptFields(
        if (tuple_verdict_exists) "normalized_verdict" else if (reviewAttemptExists(review_thread_id))
            if (std.mem.eql(u8, status, "timeout")) "review_waiting" else "review_terminal"
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

fn printLaneFallbackJson(
    allocator: std.mem.Allocator,
    lane: LaneRecord,
    lane_record_path: []const u8,
    target: TargetRecord,
    identity: TargetIdentity,
    fallback: NativeFallbackResult,
    failure: FailureInfo,
    workflow_binding: ?WorkflowBinding,
    multi_agent_mode: ?cas.MultiAgentMode,
    verdict_only: bool,
) !void {
    const target_json = try stringifyAnyAlloc(allocator, target);
    const fallback_stdout_json = if (fallback.stdout_text) |text| try quoteJsonStringAlloc(allocator, text) else "null";
    const fallback_stderr_json = if (fallback.stderr_text) |text| try quoteJsonStringAlloc(allocator, text) else "null";
    const requested_multi_agent_mode_json = try optionalModeJsonAlloc(allocator, multi_agent_mode);
    const multi_agent_support: cas.MultiAgentModeSupport = if (multi_agent_mode == null) .not_requested else .unsupported;
    const multi_agent_mode_support_json = try modeSupportJsonAlloc(allocator, multi_agent_support);
    const effective_failure = effectiveFailureWithFallback(failure, fallback) orelse failure;
    const failure_control_suffix = try failureControlJsonSuffixAlloc(allocator, effective_failure);
    defer allocator.free(failure_control_suffix);
    const attempt_fields = identityReviewAttemptFields("normalized_verdict", false, null, null, identity);
    const review_verdict_json = try buildReviewVerdictJsonAlloc(
        allocator,
        "cas-native-fallback",
        null,
        null,
        effective_failure,
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
        "{{\"demo\":\"cas-review-session\",\"action\":\"lane-review\",\"laneId\":{s},\"cwd\":{s},\"laneRecordPath\":{s}",
        .{
            try quoteJsonStringAlloc(allocator, lane.lane_id),
            try quoteJsonStringAlloc(allocator, lane.cwd),
            try quoteJsonStringAlloc(allocator, lane_record_path),
        },
    );
    try writeReviewAttemptFields(stdout, attempt_fields);
    if (workflow_binding) |binding| {
        try stdout.writeAll(",\"workflowBinding\":");
        try std.json.Stringify.value(binding, .{}, stdout);
    }
    try stdout.print(
        ",\"target\":{s},\"selectedTransport\":\"native-review\",\"fallbackUsed\":true,\"requestedMultiAgentMode\":{s},\"effectiveMultiAgentMode\":null,\"multiAgentModeSupport\":{s},\"multiAgentModeMetricEligible\":false,\"fallbackTransport\":\"native-review\",\"fallbackExitCode\":{d},\"fallbackOutputText\":{s},\"fallbackErrorText\":{s},\"failureCode\":{s},\"failureHint\":{s}{s},\"reviewVerdict\":{s}}}\n",
        .{
            target_json,
            requested_multi_agent_mode_json,
            multi_agent_mode_support_json,
            fallback.exit_code,
            fallback_stdout_json,
            fallback_stderr_json,
            try quoteJsonStringAlloc(allocator, effective_failure.code),
            try quoteJsonStringAlloc(allocator, effective_failure.hint),
            failure_control_suffix,
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
    workflow_binding: ?WorkflowBinding,
    multi_agent_mode: ?cas.MultiAgentMode,
    verdict_only: bool,
) !void {
    const target_json = try stringifyAnyAlloc(allocator, target);
    const review_result_json = status.review_result_json orelse "null";
    const review_text_json = if (status.review_text) |text| try quoteJsonStringAlloc(allocator, text) else "null";
    const raw_findings_json = if (dual_parse.raw_findings) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else "null";
    const failure_code_json = if (failure) |value| try quoteJsonStringAlloc(allocator, value.code) else "null";
    const failure_hint_json = if (failure) |value| try quoteJsonStringAlloc(allocator, value.hint) else "null";
    const failure_control_suffix = try failureControlJsonSuffixAlloc(allocator, failure);
    defer allocator.free(failure_control_suffix);
    const requested_multi_agent_mode_json = try optionalModeJsonAlloc(allocator, multi_agent_mode);
    const effective_multi_agent_mode_json = try optionalModeJsonAlloc(allocator, multi_agent_mode);
    const multi_agent_mode_support_json = try modeSupportJsonAlloc(allocator, if (multi_agent_mode == null) .not_requested else .proven);
    const lane_verdict_status = reviewVerdictStatus(clean, dual_parse.structured_findings, failure, review_thread_id);
    const lane_tuple_verdict_exists = status.review_result_available and
        reviewVerdictStatusIsTupleTerminal(lane_verdict_status) and
        identityHasCompleteTuple(identity);
    const attempt_fields = identityReviewAttemptFields(
        if (lane_tuple_verdict_exists) "normalized_verdict" else if (isTerminalTurnStatus(status.turn_status)) "review_terminal" else "review_waiting",
        lane_tuple_verdict_exists,
        review_thread_id,
        review_turn_id,
        identity,
    );
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
        "{{\"demo\":\"cas-review-session\",\"action\":\"lane-review\"",
        .{},
    );
    try writeReviewAttemptStateFields(stdout, attempt_fields);
    if (workflow_binding) |binding| {
        try stdout.writeAll(",\"workflowBinding\":");
        try std.json.Stringify.value(binding, .{}, stdout);
    }
    try stdout.print(
        ",\"laneId\":{s},\"cwd\":{s},\"laneRecordPath\":{s},\"reviewCount\":{d},\"reviewThreadId\":{s},\"reviewTurnId\":{s},\"recordPath\":{s},\"eventLogPath\":{s},\"target\":{s},\"targetFingerprint\":{s},\"headSha\":{s},\"baseSha\":{s},\"selectedTransport\":\"websocket\",\"fallbackUsed\":false,\"requestedMultiAgentMode\":{s},\"effectiveMultiAgentMode\":{s},\"multiAgentModeSupport\":{s},\"multiAgentModeMetricEligible\":{s},\"managedServerPid\":{d},\"managedServerListenUrl\":{s},\"turnStatus\":{s},\"reviewResultAvailable\":{s},\"reviewResultSource\":{s},\"reviewResult\":{s},\"rawReviewText\":{s},\"dualParseVerdict\":{s},\"structuredFindingCount\":{d},\"rawFindingCount\":{s},\"archiveStatus\":{s},\"failureCode\":{s},\"failureHint\":{s}{s},\"clean\":{s},\"reviewVerdict\":{s}}}\n",
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
            requested_multi_agent_mode_json,
            effective_multi_agent_mode_json,
            multi_agent_mode_support_json,
            if (multi_agent_mode == .proactive) "true" else "false",
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
            failure_control_suffix,
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
    workflow_binding: ?WorkflowBinding,
    multi_agent_mode: ?cas.MultiAgentMode,
    verdict_only: bool,
) !void {
    const target_json = try stringifyAnyAlloc(allocator, target);
    const requested_multi_agent_mode_json = try optionalModeJsonAlloc(allocator, multi_agent_mode);
    const effective_multi_agent_mode_json = try optionalModeJsonAlloc(allocator, multi_agent_mode);
    const multi_agent_mode_support_json = try modeSupportJsonAlloc(allocator, if (multi_agent_mode == null) .not_requested else .proven);
    const attempt_fields = identityReviewAttemptFields("review_waiting", false, review_thread_id, review_turn_id, identity);
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
        "{{\"demo\":\"cas-review-session\",\"action\":\"lane-review\",\"method\":\"review/wait\"",
        .{},
    );
    try writeReviewAttemptStateFields(stdout, attempt_fields);
    if (workflow_binding) |binding| {
        try stdout.writeAll(",\"workflowBinding\":");
        try std.json.Stringify.value(binding, .{}, stdout);
    }
    try stdout.print(
        ",\"laneId\":{s},\"cwd\":{s},\"laneRecordPath\":{s},\"reviewCount\":{d},\"reviewThreadId\":{s},\"reviewTurnId\":{s},\"recordPath\":{s},\"eventLogPath\":{s},\"target\":{s},\"targetFingerprint\":{s},\"headSha\":{s},\"baseSha\":{s},\"selectedTransport\":\"websocket\",\"fallbackUsed\":false,\"requestedMultiAgentMode\":{s},\"effectiveMultiAgentMode\":{s},\"multiAgentModeSupport\":{s},\"multiAgentModeMetricEligible\":{s},\"managedServerPid\":{d},\"managedServerListenUrl\":{s},\"timeoutMs\":{d},\"timedOut\":true,\"reviewResultAvailable\":false,\"reviewResultSource\":null,\"reviewResult\":null,\"rawReviewText\":null,\"dualParseVerdict\":\"timeout\",\"structuredFindingCount\":0,\"rawFindingCount\":null,\"archiveStatus\":\"skipped_timeout\",\"failureCode\":\"wait_timed_out\",\"failureHint\":\"retry cas review_session wait --review-thread-id {s} --timeout-ms {d} --json\",\"clean\":false,\"reviewVerdict\":{s}}}\n",
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
            requested_multi_agent_mode_json,
            effective_multi_agent_mode_json,
            multi_agent_mode_support_json,
            if (multi_agent_mode == .proactive) "true" else "false",
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

const test_workflow_binding_json =
    \\{"requestId":"request-test","requestFingerprint":"sha256:request"}
;

const test_legacy_workflow_binding_json =
    \\{"retiredField":"retained-value"}
;

fn testWorkflowBinding() WorkflowBinding {
    return .{
        .requestId = "request-test",
        .requestFingerprint = "sha256:request",
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

    const import_argv = [_][]const u8{
        "cas_review_session",
        "import",
        "--path",
        "legacy.json",
        "--workflow-binding-json",
        test_workflow_binding_json,
    };
    try std.testing.expectError(error.WorkflowBindingUnsupportedAction, parseArgs(std.testing.allocator, &import_argv));
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
        ,
        test_legacy_workflow_binding_json,
    };
    for (invalid) |raw| {
        try std.testing.expectError(error.InvalidWorkflowBinding, loadWorkflowBindingAlloc(std.testing.allocator, raw));
    }
}

test "legacy workflow binding is historical evidence but not active input" {
    try std.testing.expectError(error.InvalidWorkflowBinding, loadWorkflowBindingAlloc(std.testing.allocator, test_legacy_workflow_binding_json));
    var value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, test_legacy_workflow_binding_json, .{});
    defer value.deinit();
    const canonical = try canonicalWorkflowBindingJsonFromValueAlloc(std.testing.allocator, value.value);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(test_legacy_workflow_binding_json, canonical);
}

test "parseArgs accepts latest status and wait selectors" {
    const status_argv = [_][]const u8{
        "cas_review_session",
        "status",
        "--latest",
        "--json",
    };
    const status = try parseArgs(std.testing.allocator, &status_argv);
    try std.testing.expectEqual(Action.status, status.action.?);
    try std.testing.expect(status.latest_review_session);
    try std.testing.expect(status.json);

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
        "status",
        "--review-thread-id",
        "019f198b-722f-7b81-a6a9-f6dbbcec5ed8",
        "--json",
    };

    var parsed = try parseArgs(std.testing.allocator, &argv);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Action.status, parsed.action.?);
    try std.testing.expectEqualStrings("019f198b-722f-7b81-a6a9-f6dbbcec5ed8", parsed.review_thread_id.?);
    try std.testing.expect(parsed.json);
}

test "parseArgs accepts explicit session record path selectors" {
    const argv = [_][]const u8{
        "cas_review_session",
        "status",
        "--path",
        "/repo/.ledger/cas/review_sessions/thr_1.json",
        "--json",
    };

    var parsed = try parseArgs(std.testing.allocator, &argv);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Action.status, parsed.action.?);
    try std.testing.expectEqualStrings("/repo/.ledger/cas/review_sessions/thr_1.json", parsed.receipt_paths[0]);
    try std.testing.expect(parsed.json);

    const interrupt_argv = [_][]const u8{
        "cas_review_session",
        "interrupt",
        "--path",
        "/repo/.ledger/cas/review_sessions/thr_1.json",
        "--json",
    };
    var interrupt = try parseArgs(std.testing.allocator, &interrupt_argv);
    defer interrupt.deinit(std.testing.allocator);
    try std.testing.expectEqual(Action.interrupt, interrupt.action.?);
    try std.testing.expectEqualStrings("/repo/.ledger/cas/review_sessions/thr_1.json", interrupt.receipt_paths[0]);
    try std.testing.expect(interrupt.json);
}

test "loadSelectedSessionRecord rebinds store root from loaded record" {
    const old_store_root = configured_store_root_override;
    configured_store_root_override = "before";
    defer configured_store_root_override = old_store_root;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "external-store" });
    defer std.testing.allocator.free(store_root);
    const record_path = try std.fs.path.join(std.testing.allocator, &.{ root, "record.json" });
    errdefer std.testing.allocator.free(record_path);
    const event_log_path = try std.fs.path.join(std.testing.allocator, &.{ store_root, "review_sessions", "thr.events.ndjson" });
    defer std.testing.allocator.free(event_log_path);
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":3,\"cwd\":\"{s}\",\"store_root\":\"{s}\",\"store_scope\":\"repo\",\"repo_root\":\"{s}\",\"codex_thread_id\":\"thread\",\"parent_thread_id\":\"parent\",\"review_thread_id\":\"thr\",\"review_turn_id\":\"turn\",\"delivery\":\"review\",\"target\":{{\"type\":\"uncommittedChanges\"}},\"event_log_path\":\"{s}\",\"created_at_unix_s\":1,\"last_observed_status\":\"inProgress\",\"codex_version\":\"codex-cli test\"}}\n",
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
    const event_log_path = try std.fs.path.join(std.testing.allocator, &.{ root, "thr.events.ndjson" });
    defer std.testing.allocator.free(event_log_path);
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":3,\"cwd\":\"{s}\",\"parent_thread_id\":\"parent\",\"review_thread_id\":\"thr\",\"review_turn_id\":\"turn\",\"delivery\":\"review\",\"target\":{{\"type\":\"uncommittedChanges\"}},\"event_log_path\":\"{s}\",\"created_at_unix_s\":1,\"last_observed_status\":\"inProgress\",\"codex_version\":\"codex-cli test\",\"workflowBinding\":{s}}}\n",
        .{ root, event_log_path, test_workflow_binding_json },
    );
    defer std.testing.allocator.free(raw);
    const record_path = try std.fs.path.join(std.testing.allocator, &.{ root, "record.json" });
    try durable_store.writeTextAtomic(std.testing.allocator, record_path, raw);
    var loaded = try loadOwnedSessionRecordPath(std.testing.allocator, record_path);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("request-test", loaded.record.workflowBinding.?.requestId);

    const normalized = try normalizeReceiptFromJsonAlloc(std.testing.allocator, loaded.record_path, loaded.raw, false, .{});
    defer normalized.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(test_workflow_binding_json, normalized.workflow_binding_json.?);

    const invalid_raw = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        raw,
        "sha256:request",
        " ",
    );
    defer std.testing.allocator.free(invalid_raw);
    const invalid_path = try std.fs.path.join(std.testing.allocator, &.{ root, "invalid-record.json" });
    try durable_store.writeTextAtomic(std.testing.allocator, invalid_path, invalid_raw);
    try std.testing.expectError(error.InvalidWorkflowBinding, loadOwnedSessionRecordPath(std.testing.allocator, invalid_path));
}

test "legacy review session records remain readable by id and latest selectors" {
    const old_store_root = configured_store_root_override;
    const old_home = configured_home;
    configured_store_root_override = null;
    defer configured_store_root_override = old_store_root;
    defer configured_home = old_home;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const repo_store = try std.fs.path.join(std.testing.allocator, &.{ root, "repo-store" });
    defer std.testing.allocator.free(repo_store);
    configured_store_root_override = repo_store;
    configured_home = root;

    const legacy_dir = try std.fs.path.join(std.testing.allocator, &.{ root, ".codex", "cas", "review_sessions" });
    defer std.testing.allocator.free(legacy_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(legacy_dir);
    const legacy_path = try std.fs.path.join(std.testing.allocator, &.{ legacy_dir, "thr_legacy.json" });
    defer std.testing.allocator.free(legacy_path);
    const event_log_path = try std.fs.path.join(std.testing.allocator, &.{ legacy_dir, "thr_legacy.events.ndjson" });
    defer std.testing.allocator.free(event_log_path);
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":3,\"cwd\":\"{s}\",\"parent_thread_id\":\"parent\",\"review_thread_id\":\"thr_legacy\",\"review_turn_id\":\"turn\",\"delivery\":\"review\",\"target\":{{\"type\":\"uncommittedChanges\"}},\"event_log_path\":\"{s}\",\"created_at_unix_s\":1,\"last_observed_status\":\"inProgress\",\"codex_version\":\"codex-cli test\"}}\n",
        .{ root, event_log_path },
    );
    defer std.testing.allocator.free(raw);
    try durable_store.writeTextAtomic(std.testing.allocator, legacy_path, raw);

    var by_id = try loadSessionRecord(std.testing.allocator, "thr_legacy");
    defer by_id.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(legacy_path, by_id.record_path);

    const latest = try latestSessionRecordPathAlloc(std.testing.allocator);
    defer std.testing.allocator.free(latest);
    try std.testing.expectEqualStrings(legacy_path, latest);
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
        "lane_1.lane.json",
        "review_sessions/019f198b-722f-7b81-a6a9-f6dbbcec5ed8",
        "review_sessions\\019f198b-722f-7b81-a6a9-f6dbbcec5ed8",
    };

    for (invalid_values) |value| {
        const argv = [_][]const u8{
            "cas_review_session",
            "status",
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
        "status",
        "--latest",
        "--review-thread-id",
        "thr_1",
    };
    try std.testing.expectError(error.AmbiguousReviewSessionSelector, parseArgs(std.testing.allocator, &ambiguous_argv));

    const interrupt_argv = [_][]const u8{
        "cas_review_session",
        "interrupt",
        "--latest",
    };
    try std.testing.expectError(error.LatestReviewSessionUnsupportedAction, parseArgs(std.testing.allocator, &interrupt_argv));
}

test "latestSessionRecordPathInDirAlloc selects newest top-level session record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "old.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "new.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lane_1.lane.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "events.ndjson", .data = "" });
    try tmp.dir.setTimestamps(io, "old.json", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 1 } } });
    try tmp.dir.setTimestamps(io, "new.json", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 2 } } });
    try tmp.dir.setTimestamps(io, "lane_1.lane.json", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 3 } } });

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);
    const latest = try latestSessionRecordPathInDirAlloc(std.testing.allocator, tmp_path);
    defer std.testing.allocator.free(latest);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/new.json", .{tmp_path});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, latest);
}

test "parseArgs accepts multi-agent mode for start and lane review" {
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
    const start = try parseArgs(std.testing.allocator, &start_argv);
    try std.testing.expectEqual(cas.MultiAgentMode.proactive, start.multi_agent_mode.?);

    const lane_review_argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "review",
        "--lane-id",
        "lane_1",
        "--base",
        "main",
        "--multi-agent-mode",
        "explicit-request-only",
    };
    const lane_review = try parseArgs(std.testing.allocator, &lane_review_argv);
    try std.testing.expectEqual(cas.MultiAgentMode.explicit_request_only, lane_review.multi_agent_mode.?);
}

test "parseArgs rejects multi-agent mode on unsupported review-session actions" {
    const argv = [_][]const u8{
        "cas_review_session",
        "wait",
        "--review-thread-id",
        "thr_1",
        "--multi-agent-mode",
        "proactive",
    };

    try std.testing.expectError(error.MultiAgentModeUnsupportedAction, parseArgs(std.testing.allocator, &argv));
}

test "request builders include multi-agent mode on fresh parent flow" {
    const thread_params = try buildThreadStartParamsJson(std.testing.allocator, "/tmp/repo", .proactive);
    defer std.testing.allocator.free(thread_params);
    var parsed_thread = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, thread_params, .{});
    defer parsed_thread.deinit();
    try std.testing.expectEqualStrings("proactive", parsed_thread.value.object.get("multiAgentMode").?.string);

    const turn_params = try buildTurnStartParamsJson(std.testing.allocator, "thr_1", "hello", .explicit_request_only);
    defer std.testing.allocator.free(turn_params);
    var parsed_turn = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, turn_params, .{});
    defer parsed_turn.deinit();
    try std.testing.expectEqualStrings("explicitRequestOnly", parsed_turn.value.object.get("multiAgentMode").?.string);
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
    try std.testing.expectEqual(default_review_timeout_ms, parsed.timeout_ms);
    try std.testing.expect(!parsed.timeout_ms_explicit);
}

test "parseArgs accepts review lane smoke target and cleanup flags" {
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--no-wait",
        "--cleanup",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Action.lane, parsed.action.?);
    try std.testing.expectEqual(LaneAction.smoke, parsed.lane_action.?);
    try std.testing.expectEqualStrings("/tmp/repo", parsed.cwd.?);
    try std.testing.expectEqual(TargetKind.base_branch, parsed.target.?.kind);
    try std.testing.expectEqualStrings("main", parsed.target.?.branch.?);
    try std.testing.expect(!parsed.lane_smoke_wait);
    try std.testing.expect(parsed.lane_smoke_cleanup);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(default_control_timeout_ms, parsed.timeout_ms);
    try std.testing.expect(!parsed.timeout_ms_explicit);
}

test "parseArgs accepts review lane smoke suite options" {
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke-suite",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--runs",
        "7",
        "--required-consecutive-passes",
        "4",
        "--delay-ms",
        "0,5,30",
        "--hooks",
        "inherit,off",
        "--cleanup",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Action.lane, parsed.action.?);
    try std.testing.expectEqual(LaneAction.smoke_suite, parsed.lane_action.?);
    try std.testing.expectEqualStrings("/tmp/repo", parsed.cwd.?);
    try std.testing.expectEqual(TargetKind.base_branch, parsed.target.?.kind);
    try std.testing.expectEqualStrings("main", parsed.target.?.branch.?);
    try std.testing.expectEqual(@as(u32, 7), parsed.smoke_runs);
    try std.testing.expectEqual(@as(u32, 4), parsed.smoke_required_consecutive_passes);
    try std.testing.expectEqualStrings("0,5,30", parsed.smoke_delay_ms);
    try std.testing.expectEqualStrings("inherit,off", parsed.smoke_hooks);
    try std.testing.expect(parsed.lane_smoke_cleanup);
    try std.testing.expect(parsed.json);
    try std.testing.expectEqual(default_control_timeout_ms, parsed.timeout_ms);
    try std.testing.expect(!parsed.timeout_ms_explicit);
}

test "smoke suite child inherits approval and runtime options" {
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke-suite",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--read-only",
        "--exec-approval",
        "decline",
        "--file-approval",
        "acceptForSession",
        "--permissions-approval",
        "grant-session",
        "--request-user-input-response-json",
        "{\"ok\":true}",
        "--elicitation-action",
        "accept",
        "--elicitation-content-json",
        "{\"answer\":\"yes\"}",
        "--dynamic-tool-response-json",
        "{\"result\":\"ok\"}",
        "--multi-agent-mode",
        "proactive",
    };
    const parsed = try parseArgs(std.testing.allocator, &argv);

    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(std.testing.allocator);
    try appendSmokeChildRuntimeCliArgs(std.testing.allocator, &child_argv, parsed);

    const expected = [_][]const u8{
        "--read-only",
        "--exec-approval",
        "decline",
        "--file-approval",
        "acceptForSession",
        "--permissions-approval",
        "grant-session",
        "--request-user-input-response-json",
        "{\"ok\":true}",
        "--elicitation-action",
        "accept",
        "--elicitation-content-json",
        "{\"answer\":\"yes\"}",
        "--dynamic-tool-response-json",
        "{\"result\":\"ok\"}",
        "--multi-agent-mode",
        "proactive",
    };
    try std.testing.expectEqual(@as(usize, expected.len), child_argv.items.len);
    for (expected, child_argv.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "smoke suite run ids remain unique across promotion rounds" {
    try std.testing.expectEqual(@as(u32, 1), smokeSuiteFirstRunNumber(0));
    try std.testing.expectEqual(@as(u32, 6), smokeSuiteFirstRunNumber(5));

    const first = try smokeRunIdAlloc(std.testing.allocator, smokeSuiteFirstRunNumber(0));
    defer std.testing.allocator.free(first);
    const second_round = try smokeRunIdAlloc(std.testing.allocator, smokeSuiteFirstRunNumber(5));
    defer std.testing.allocator.free(second_round);
    try std.testing.expectEqualStrings("smoke-001", first);
    try std.testing.expectEqualStrings("smoke-006", second_round);
}

test "lane smoke terminal failures fail direct smoke but timeout remains passable" {
    try std.testing.expect(!laneSmokeFailureMakesSmokeFail(null));
    try std.testing.expect(!laneSmokeFailureMakesSmokeFail(.{
        .code = "wait_timed_out",
        .hint = "retry wait",
    }));
    try std.testing.expect(laneSmokeFailureMakesSmokeFail(.{
        .code = "review_output_missing",
        .hint = "missing output",
    }));
    try std.testing.expect(laneSmokeFailureMakesSmokeFail(.{
        .code = "account_resource_exhausted",
        .hint = "account exhausted",
    }));
}

test "lane smoke treats dual parse mismatch as terminal failure" {
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
        .review_result_source = "rollout_exited_review_mode",
        .review_result_json = try std.testing.allocator.dupe(u8, structured),
        .review_text = try std.testing.allocator.dupe(u8, "No findings rendered here."),
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);

    const failure = smokeDualParseFailureInfo(std.testing.allocator, status) orelse return error.ExpectedSmokeFailure;
    try std.testing.expectEqualStrings("review_parse_mismatch", failure.code);
    try std.testing.expect(laneSmokeFailureMakesSmokeFail(failure));

    const lock_failure = terminalLockFailureForStatus(std.testing.allocator, status) orelse return error.ExpectedTerminalLockFailure;
    try std.testing.expectEqualStrings("review_parse_mismatch", lock_failure.code);
}

test "lane smoke treats missing tuple identity as terminal failure" {
    const failure = tupleIdentityUnavailableFailureInfo();
    try std.testing.expectEqualStrings("target_identity_unavailable", failure.code);
    try std.testing.expectEqualStrings("caller_error", failureClassForCode(failure.code).?);
    try std.testing.expect(laneSmokeFailureMakesSmokeFail(failure));
}

test "terminal proof failure requires tuple identity" {
    const review_result =
        \\{"findings":[],"overallCorrectness":"patch is correct","overallExplanation":"clean","overallConfidenceScore":1}
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
        .review_text = try std.testing.allocator.dupe(u8, "No findings."),
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);
    const missing_base = TargetIdentity{
        .base_sha = null,
        .head_sha = "head",
        .fingerprint = "fp",
    };

    const failure = terminalBindingFailureForIdentity(std.testing.allocator, status, missing_base) orelse return error.ExpectedTerminalProofFailure;
    try std.testing.expectEqualStrings("target_identity_unavailable", failure.code);
    const missing_identity_failure = terminalBindingFailureForOptionalIdentity(std.testing.allocator, status, null) orelse return error.ExpectedTerminalProofFailure;
    try std.testing.expectEqualStrings("target_identity_unavailable", missing_identity_failure.code);
}

test "lane smoke suite does not promote no-wait review-started runs" {
    const result = LaneSmokeRunSummary{
        .run_id = "smoke-001",
        .hook_policy = "off",
        .delay_ms = 0,
        .status = "pass",
        .review_attempt_phase = "review_started",
        .failure_code = null,
        .review_verdict_status = null,
        .finding_count = 0,
        .review_attempt_exists = true,
        .tuple_verdict_exists = false,
        .lane_id = "lane_1",
        .review_thread_id = "thr_1",
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .receipt_path = null,
        .exit_code = 0,
    };
    try std.testing.expect(!laneSmokeRunPassesSuite(result));

    var missing_thread = result;
    missing_thread.review_thread_id = null;
    try std.testing.expect(!laneSmokeRunPassesSuite(missing_thread));
}

test "smoke run summary prefers normalizable review record path" {
    const stdout_json =
        \\{"status":"pass","reviewAttemptPhase":"normalized_verdict","reviewAttemptExists":true,"tupleVerdictExists":true,"laneId":"lane_1","reviewThreadId":"thr_1","baseSha":"base","headSha":"head","targetFingerprint":"fp","recordPath":"/tmp/review-record.json","smokeRecordPath":"/tmp/smoke-summary.json","reviewVerdict":{"status":"findings","findingCount":2}}
    ;
    var result = try smokeRunSummaryFromJsonAlloc(std.testing.allocator, try smokeRunIdAlloc(std.testing.allocator, 1), "off", 0, 0, stdout_json, "");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/tmp/review-record.json", result.receipt_path.?);
    try std.testing.expectEqualStrings("lane_1", result.lane_id.?);
    try std.testing.expectEqualStrings("findings", result.review_verdict_status.?);
    try std.testing.expectEqual(@as(usize, 2), result.finding_count);
    try std.testing.expect(laneSmokeRunPassesSuite(result));

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeSmokeRunJson(&out.writer, result);
    const json = try out.toOwnedSlice();
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("findingCount").?.integer);
}

test "smoke until fixed allows pass streaks across rounds" {
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke-until-fixed",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--runs-per-round",
        "3",
        "--max-rounds",
        "3",
        "--required-consecutive-passes",
        "5",
    };
    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(LaneAction.smoke_until_fixed, parsed.lane_action.?);
    try std.testing.expectEqual(@as(u32, 3), parsed.smoke_runs_per_round);
    try std.testing.expectEqual(@as(u32, 3), parsed.smoke_max_rounds);
    try std.testing.expectEqual(@as(u32, 5), parsed.smoke_required_consecutive_passes);
}

test "smoke pass streak is computed across accumulated rounds" {
    const pass = LaneSmokeRunSummary{
        .run_id = "smoke-pass",
        .hook_policy = "off",
        .delay_ms = 0,
        .status = "pass",
        .review_attempt_phase = "normalized_verdict",
        .failure_code = null,
        .review_verdict_status = "clean",
        .finding_count = 0,
        .review_attempt_exists = true,
        .tuple_verdict_exists = true,
        .lane_id = "lane_1",
        .review_thread_id = "thr_1",
        .base_sha = "base",
        .head_sha = "head",
        .target_fingerprint = "fp",
        .receipt_path = null,
        .exit_code = 0,
    };
    var fail = pass;
    fail.run_id = "smoke-fail";
    fail.status = "fail";
    fail.failure_code = "pre_review_lane_transport_lost";
    fail.tuple_verdict_exists = false;
    const results = [_]LaneSmokeRunSummary{ fail, pass, pass, pass };
    try std.testing.expectEqual(@as(u32, 3), maxConsecutiveSmokePasses(&results));
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

    const identity = try targetIdentityForRecordAlloc(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), record);
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
    try std.testing.expect(!startReceiptTupleVerdictExists(std.testing.allocator, "{\"tupleVerdictExists\":true}", "thr_1", missing_head, null, false));

    const empty_fingerprint = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "",
    };
    try std.testing.expect(!startReceiptTupleVerdictExists(std.testing.allocator, "{\"tupleVerdictExists\":true}", "thr_1", empty_fingerprint, null, false));
}

test "normalizer preserves attempt-only receipts as non-proof" {
    const raw =
        \\{"demo":"cas-review-session","action":"lane-smoke","reviewAttemptPhase":"review_started","reviewAttemptExists":true,"tupleVerdictExists":false,"reviewThreadId":"thr_started","reviewTurnId":"turn_started","baseSha":"base","headSha":"head","targetFingerprint":"fp","status":"pass","smokeStatus":"passed"}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "attempt-only.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cas-lane", receipt.backend_class);
    try std.testing.expectEqualStrings("review_started", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
}

test "normalizer treats null reviewVerdict as absent for no-wait smoke" {
    const raw =
        \\{"demo":"cas-review-session","action":"lane-smoke","reviewAttemptPhase":"review_started","reviewAttemptExists":true,"tupleVerdictExists":false,"laneId":"lane_1","reviewThreadId":"thr_started","reviewTurnId":"turn_started","baseSha":"base","headSha":"head","targetFingerprint":"fp","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.ndjson","status":"pass","smokeStatus":"passed","reviewVerdict":null}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "no-wait-smoke.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cas-lane", receipt.backend_class);
    try std.testing.expectEqualStrings("review_started", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("thr_started", receipt.review_thread_id.?);
}

test "normalizer reads object reviewResult in legacy start receipts" {
    const raw =
        \\{"demo":"cas-review-session","action":"start","reviewAttemptPhase":"review_terminal","reviewAttemptExists":true,"tupleVerdictExists":false,"reviewThreadId":"thr_findings","reviewTurnId":"turn_findings","baseSha":"base","headSha":"head","targetFingerprint":"fp","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.ndjson","reviewResult":{"findings":[{"title":"Finding","body":"Body","priority":2,"codeLocation":{"absoluteFilePath":"/tmp/file.zig","lineRange":{"start":12,"end":12}}}],"overallCorrectness":"patch is incorrect","overallExplanation":"one finding","overallConfidenceScore":0.8}}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "start-object.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("findings", receipt.status);
    try std.testing.expectEqual(@as(usize, 1), receipt.finding_count);
    try std.testing.expectEqualStrings("normalized_verdict", receipt.review_attempt_phase);
    try std.testing.expect(receipt.tuple_verdict_exists);
}

test "normalizer treats null start reviewResult as non-proof" {
    const raw =
        \\{"demo":"cas-review-session","action":"start","reviewAttemptPhase":"review_started","reviewAttemptExists":true,"tupleVerdictExists":false,"reviewThreadId":"thr_waiting","reviewTurnId":"turn_waiting","baseSha":"base","headSha":"head","targetFingerprint":"fp","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.ndjson","reviewResult":null}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "start-null.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("incomplete", receipt.status);
    try std.testing.expectEqualStrings("review_started", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expect(!receipt.clean);
}

test "normalizer classifies lane smoke session records as lane backend" {
    const raw =
        \\{"schema_version":3,"cwd":"/tmp/repo","parent_thread_id":"parent","review_thread_id":"thr_smoke","review_turn_id":"turn_smoke","delivery":"detached","target":{"type":"baseBranch","branch":"main"},"event_log_path":"/tmp/events.ndjson","created_at_unix_s":1,"last_observed_status":"completed","codex_version":"0.140.0","resolved_codex_path":"/bin/codex","compatibility_verdict":"compatible","transport_kind":"websocket","transport_selection_reason":"persistent_review_lane_smoke","terminal_review_result_source":"rollout_exited_review_mode","terminal_review_result_json":"{\"findings\":[],\"overallCorrectness\":\"patch is correct\",\"overallExplanation\":\"clean\",\"overallConfidenceScore\":1}","base_sha":"base","head_sha":"head","target_fingerprint":"fp"}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "lane-smoke-record.json", raw, false, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cas-lane", receipt.backend_class);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expect(receipt.tuple_verdict_exists);
}

test "parseArgs accepts review lane smoke-until-fixed options" {
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke-until-fixed",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--max-rounds",
        "2",
        "--runs-per-round",
        "4",
        "--required-consecutive-passes",
        "3",
        "--delay-ms",
        "0",
        "--hooks",
        "off",
        "--json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    try std.testing.expectEqual(Action.lane, parsed.action.?);
    try std.testing.expectEqual(LaneAction.smoke_until_fixed, parsed.lane_action.?);
    try std.testing.expectEqual(@as(u32, 2), parsed.smoke_max_rounds);
    try std.testing.expectEqual(@as(u32, 4), parsed.smoke_runs_per_round);
    try std.testing.expectEqual(@as(u32, 3), parsed.smoke_required_consecutive_passes);
    try std.testing.expectEqualStrings("0", parsed.smoke_delay_ms);
    try std.testing.expectEqualStrings("off", parsed.smoke_hooks);
}

test "parseArgs rejects impossible smoke suite consecutive pass gate" {
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke-suite",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--runs",
        "2",
        "--required-consecutive-passes",
        "3",
    };

    try std.testing.expectError(error.InvalidRequiredConsecutivePasses, parseArgs(std.testing.allocator, &argv));
}

test "parseArgs rejects no-wait smoke suites" {
    const suite_argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke-suite",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--no-wait",
    };
    try std.testing.expectError(error.NoWaitUnsupportedForSmokeSuite, parseArgs(std.testing.allocator, &suite_argv));

    const promotion_argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke-until-fixed",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--no-wait",
    };
    try std.testing.expectError(error.NoWaitUnsupportedForSmokeSuite, parseArgs(std.testing.allocator, &promotion_argv));
}

test "target selector and custom instructions remain independently bound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "review.txt", .data = "loaded instruction body" });
    const instruction_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "review.txt", std.testing.allocator);
    defer std.testing.allocator.free(instruction_path);
    const instruction_arg = try std.fmt.allocPrint(std.testing.allocator, "@{s}", .{instruction_path});
    defer std.testing.allocator.free(instruction_arg);
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke-suite",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--custom-instructions",
        instruction_arg,
    };
    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer if (parsed.target) |target| if (target.instructions) |instructions| std.testing.allocator.free(instructions);
    try std.testing.expectEqual(TargetKind.base_branch, parsed.target.?.kind);
    try std.testing.expectEqualStrings("main", parsed.target.?.branch.?);
    try std.testing.expectEqualStrings("loaded instruction body", parsed.target.?.instructions.?);

    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(std.testing.allocator);
    try appendTargetCliArgs(std.testing.allocator, &child_argv, parsed);
    try std.testing.expectEqual(@as(usize, 4), child_argv.items.len);
    try std.testing.expectEqualStrings("--base", child_argv.items[0]);
    try std.testing.expectEqualStrings("main", child_argv.items[1]);
    try std.testing.expectEqualStrings("--custom-instructions", child_argv.items[2]);
    try std.testing.expectEqualStrings("loaded instruction body", child_argv.items[3]);

    const target_json = try buildTargetJson(std.testing.allocator, parsed.target.?);
    defer std.testing.allocator.free(target_json);
    var target_value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, target_json, .{});
    defer target_value.deinit();
    try std.testing.expectEqualStrings("custom", target_value.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("loaded instruction body", target_value.value.object.get("instructions").?.string);

    const target_record = targetToRecord(parsed.target.?);
    try std.testing.expectEqualStrings("baseBranch", target_record.type);
    try std.testing.expectEqualStrings("main", target_record.branch.?);
    try std.testing.expectEqualStrings("loaded instruction body", target_record.instructions.?);

    var native_argv: std.ArrayList([]const u8) = .empty;
    defer native_argv.deinit(std.testing.allocator);
    try appendNativeReviewArgs(std.testing.allocator, &native_argv, target_record);
    try std.testing.expectEqual(@as(usize, 1), native_argv.items.len);
    try std.testing.expectEqualStrings("loaded instruction body", native_argv.items[0]);

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
    defer if (reverse.target) |target| if (target.instructions) |instructions| std.testing.allocator.free(instructions);
    try std.testing.expectEqual(TargetKind.base_branch, reverse.target.?.kind);
    try std.testing.expectEqualStrings("main", reverse.target.?.branch.?);
    try std.testing.expectEqualStrings("loaded instruction body", reverse.target.?.instructions.?);

    const stdin_parsed = ParsedArgs{
        .target = .{ .kind = .custom, .instructions = "loaded stdin body" },
        .custom_instructions_arg = "-",
    };
    child_argv.clearRetainingCapacity();
    try appendTargetCliArgs(std.testing.allocator, &child_argv, stdin_parsed);
    try std.testing.expectEqualStrings("--custom-instructions", child_argv.items[0]);
    try std.testing.expectEqualStrings("loaded stdin body", child_argv.items[1]);
}

test "parseArgs rejects review lane smoke without target" {
    const argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke",
        "--cwd",
        "/tmp/repo",
    };

    try std.testing.expectError(error.MissingTarget, parseArgs(std.testing.allocator, &argv));
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

test "parseArgs error path does not free borrowed receipt argv values" {
    const argv = [_][]const u8{
        "cas_review_session",
        "receipt",
        "normalize",
        "--path",
        "review-1.json",
        "--format",
        "bad-format",
    };

    try std.testing.expectError(error.InvalidReceiptFormat, parseArgs(std.testing.allocator, &argv));
}

test "parseArgs accepts receipt normalize with requested tuple inputs" {
    const argv = [_][]const u8{
        "cas_review_session",
        "receipt",
        "normalize",
        "--path",
        "start-wait.json",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--format",
        "json",
    };

    const parsed = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(parsed.receipt_paths);
    defer std.testing.allocator.free(parsed.receipt_globs);
    try std.testing.expectEqual(Action.receipt, parsed.action.?);
    try std.testing.expectEqualStrings("start-wait.json", parsed.receipt_paths[0]);
    try std.testing.expectEqualStrings("/tmp/repo", parsed.cwd.?);
    try std.testing.expectEqual(TargetKind.base_branch, parsed.target.?.kind);
    try std.testing.expectEqualStrings("main", parsed.target.?.branch.?);
    try std.testing.expectEqual(ReceiptFormat.json, parsed.receipt_format);
}

test "parseArgs accepts public review import and validate record actions" {
    const import_argv = [_][]const u8{
        "cas_review_session",
        "import",
        "--path",
        "legacy-receipt.json",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--json",
    };
    const import_parsed = try parseArgs(std.testing.allocator, &import_argv);
    defer std.testing.allocator.free(import_parsed.receipt_paths);
    defer std.testing.allocator.free(import_parsed.receipt_globs);
    try std.testing.expectEqual(Action.review_import, import_parsed.action.?);
    try std.testing.expectEqualStrings("legacy-receipt.json", import_parsed.receipt_paths[0]);
    try std.testing.expectEqualStrings("/tmp/repo", import_parsed.cwd.?);
    try std.testing.expectEqual(TargetKind.base_branch, import_parsed.target.?.kind);
    try std.testing.expect(import_parsed.json);

    const target_only_import_argv = [_][]const u8{
        "cas_review_session",
        "import",
        "--path",
        "legacy-receipt.json",
        "--base",
        "main",
        "--json",
    };
    try std.testing.expectError(error.MissingCwd, parseArgs(std.testing.allocator, &target_only_import_argv));

    const validate_argv = [_][]const u8{
        "cas_review_session",
        "validate-record",
        "--record",
        "rer_123.json",
        "--json",
    };
    const validate_parsed = try parseArgs(std.testing.allocator, &validate_argv);
    defer std.testing.allocator.free(validate_parsed.receipt_paths);
    defer std.testing.allocator.free(validate_parsed.receipt_globs);
    try std.testing.expectEqual(Action.validate_record, validate_parsed.action.?);
    try std.testing.expectEqualStrings("rer_123.json", validate_parsed.receipt_paths[0]);
    try std.testing.expect(validate_parsed.json);
}

test "parseArgs accepts public review current list and inspect actions" {
    const current_argv = [_][]const u8{
        "cas_review_session",
        "current",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--json",
    };
    const current_parsed = try parseArgs(std.testing.allocator, &current_argv);
    defer std.testing.allocator.free(current_parsed.receipt_paths);
    defer std.testing.allocator.free(current_parsed.receipt_globs);
    try std.testing.expectEqual(Action.current, current_parsed.action.?);
    try std.testing.expectEqualStrings("/tmp/repo", current_parsed.cwd.?);
    try std.testing.expectEqual(TargetKind.base_branch, current_parsed.target.?.kind);
    try std.testing.expect(current_parsed.json);

    const list_argv = [_][]const u8{
        "cas_review_session",
        "list",
        "--cwd",
        "/tmp/repo",
        "--base",
        "main",
        "--json",
    };
    const list_parsed = try parseArgs(std.testing.allocator, &list_argv);
    defer std.testing.allocator.free(list_parsed.receipt_paths);
    defer std.testing.allocator.free(list_parsed.receipt_globs);
    try std.testing.expectEqual(Action.list, list_parsed.action.?);
    try std.testing.expectEqual(TargetKind.base_branch, list_parsed.target.?.kind);

    const inspect_argv = [_][]const u8{
        "cas_review_session",
        "inspect",
        "--record",
        "rer_123.json",
        "--allow-reduced-principal",
        "--allow-native-fallback",
        "--show-attachments",
        "--json",
    };
    const inspect_parsed = try parseArgs(std.testing.allocator, &inspect_argv);
    defer std.testing.allocator.free(inspect_parsed.receipt_paths);
    defer std.testing.allocator.free(inspect_parsed.receipt_globs);
    try std.testing.expectEqual(Action.inspect, inspect_parsed.action.?);
    try std.testing.expectEqualStrings("rer_123.json", inspect_parsed.receipt_paths[0]);
    try std.testing.expect(inspect_parsed.allow_reduced_principal);
    try std.testing.expect(inspect_parsed.allow_native_fallback);
    try std.testing.expect(inspect_parsed.show_attachments);

    const missing_target_argv = [_][]const u8{
        "cas_review_session",
        "current",
        "--cwd",
        "/tmp/repo",
    };
    try std.testing.expectError(error.MissingTarget, parseArgs(std.testing.allocator, &missing_target_argv));
}

test "parseArgs accepts native receipt classify gate and lock gate actions" {
    const classify_argv = [_][]const u8{
        "cas_review_session",
        "receipt",
        "classify",
        "--path",
        "receipts.jsonl",
        "--format",
        "jsonl",
    };
    const classify = try parseArgs(std.testing.allocator, &classify_argv);
    defer std.testing.allocator.free(classify.receipt_paths);
    defer std.testing.allocator.free(classify.receipt_globs);
    try std.testing.expectEqual(Action.receipt, classify.action.?);
    try std.testing.expectEqual(ReceiptAction.classify, classify.receipt_action);
    try std.testing.expectEqual(ReceiptFormat.jsonl, classify.receipt_format);

    const receipt_gate_argv = [_][]const u8{
        "cas_review_session",
        "receipt",
        "gate",
        "--path",
        "review.json",
        "--format",
        "json",
    };
    const receipt_gate = try parseArgs(std.testing.allocator, &receipt_gate_argv);
    defer std.testing.allocator.free(receipt_gate.receipt_paths);
    defer std.testing.allocator.free(receipt_gate.receipt_globs);
    try std.testing.expectEqual(ReceiptAction.gate, receipt_gate.receipt_action);

    const lock_gate_argv = [_][]const u8{
        "cas_review_session",
        "lock",
        "gate",
        "--path",
        "tuple-lock.json",
        "--format",
        "json",
    };
    const lock_gate = try parseArgs(std.testing.allocator, &lock_gate_argv);
    defer std.testing.allocator.free(lock_gate.receipt_paths);
    defer std.testing.allocator.free(lock_gate.receipt_globs);
    try std.testing.expectEqual(Action.lock, lock_gate.action.?);
    try std.testing.expectEqual(LockAction.gate, lock_gate.lock_action.?);
}

test "native receipt classifier preserves Python helper contract" {
    var pre_review = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"failureCode\":\"lane_transport_lost\",\"lastHeadSha\":null,\"lastReviewThreadId\":null,\"reviewCount\":0,\"reviewThreadId\":null}",
        .{},
    );
    defer pre_review.deinit();
    const pre_review_row = try classifyReceiptRecordAlloc(std.testing.allocator, pre_review.value.object);
    defer pre_review_row.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pre_review_lane_transport_lost", pre_review_row.classification);
    try std.testing.expectEqualStrings("transport_pre_review", pre_review_row.failure_class);
    try std.testing.expectEqualStrings("pre_review_lane_transport_lost", pre_review_row.failure_code.?);
    try std.testing.expect(!pre_review_row.review_attempt_exists);
    try std.testing.expect(!pre_review_row.tuple_verdict_exists);
    try std.testing.expect(pre_review_row.retryable_same_tuple_now);

    var findings = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"reviewVerdict\":{\"backendClass\":\"cas-lane\",\"findingCount\":2,\"reviewThreadId\":\"thr1\",\"status\":\"findings\"}}",
        .{},
    );
    defer findings.deinit();
    const findings_row = try classifyReceiptRecordAlloc(std.testing.allocator, findings.value.object);
    defer findings_row.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("review_verdict_findings", findings_row.classification);
    try std.testing.expectEqualStrings("review_verdict", findings_row.failure_class);
    try std.testing.expect(findings_row.review_attempt_exists);
    try std.testing.expect(findings_row.tuple_verdict_exists);
    try std.testing.expectEqualStrings("thr1", findings_row.review_thread_id.?);

    var exhausted = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"failureCode\":\"review_failed\",\"rawErrorText\":\"usageLimitExceeded: Reviewer failed to output a response.\",\"reviewThreadId\":\"thr2\"}",
        .{},
    );
    defer exhausted.deinit();
    const exhausted_row = try classifyReceiptRecordAlloc(std.testing.allocator, exhausted.value.object);
    defer exhausted_row.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("account_resource_exhausted", exhausted_row.classification);
    try std.testing.expectEqualStrings("account_resource", exhausted_row.failure_class);
    try std.testing.expectEqualStrings("account_resource_exhausted", exhausted_row.failure_code.?);
    try std.testing.expectEqualStrings("review_terminal", exhausted_row.review_attempt_phase);
    try std.testing.expect(!exhausted_row.retryable_same_tuple_now);
}

test "native receipt gate validates pre-review and tuple verdict invariants" {
    var valid = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"action\":\"lane-review\",\"baseSha\":\"base\",\"failureClass\":\"transport_pre_review\",\"failureCode\":\"pre_review_lane_transport_lost\",\"headSha\":\"head\",\"laneId\":\"lane_1\",\"lastReviewThreadId\":null,\"managedServerPid\":123,\"reviewAttemptExists\":false,\"reviewAttemptPhase\":\"pre_review_start\",\"reviewCount\":0,\"reviewThreadId\":null,\"reviewTurnId\":null,\"targetFingerprint\":\"fp\",\"tupleVerdictExists\":false}",
        .{},
    );
    defer valid.deinit();
    const valid_result = try validateReceiptGateObjectAlloc(std.testing.allocator, "valid.json", valid.value.object);
    defer valid_result.deinit(std.testing.allocator);
    try std.testing.expect(valid_result.ok());

    var invalid = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"reviewAttemptPhase\":\"review_waiting\",\"reviewThreadId\":\"thr\",\"reviewAttemptExists\":true,\"tupleVerdictExists\":true,\"reviewVerdict\":{\"status\":\"timeout\",\"backendClass\":\"cas-lane\",\"reviewThreadId\":\"thr\"}}",
        .{},
    );
    defer invalid.deinit();
    const invalid_result = try validateReceiptGateObjectAlloc(std.testing.allocator, "invalid.json", invalid.value.object);
    defer invalid_result.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_result.ok());
    try std.testing.expectEqualStrings("tupleVerdictExists=true is inconsistent with reviewVerdict.status", invalid_result.errors[0]);
}

test "native tuple lock gate validates CAS-RTL-v1 lock records" {
    var valid = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"accountFingerprint\":\"acct:a\",\"baseSha\":\"base\",\"createdAtUnixS\":1,\"expiresAtUnixS\":30,\"headSha\":\"head\",\"lockVersion\":\"CAS-RTL-v1\",\"ownerPid\":4,\"repoRealpath\":\"/repo\",\"resolvedCodexPath\":\"/bin/codex\",\"resolvedCodexVersion\":\"codex 0.1.0\",\"reviewThreadId\":\"thr_1\",\"state\":\"waiting\",\"targetFingerprint\":\"fp\",\"tupleHash\":\"sha256:tuple\",\"updatedAtUnixS\":2}",
        .{},
    );
    defer valid.deinit();
    const valid_result = try validateTupleLockGateObjectAlloc(std.testing.allocator, "lock.json", valid.value.object);
    defer valid_result.deinit(std.testing.allocator);
    try std.testing.expect(valid_result.ok());

    var invalid = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"accountFingerprint\":\"acct:a\",\"baseSha\":\"base\",\"expiresAtUnixS\":1,\"headSha\":\"head\",\"lockVersion\":\"CRTL-v1\",\"repoRealpath\":\"/repo\",\"resolvedCodexPath\":\"/bin/codex\",\"resolvedCodexVersion\":\"codex 0.1.0\",\"state\":\"waiting\",\"targetFingerprint\":\"fp\",\"tupleHash\":\"sha256:tuple\",\"updatedAtUnixS\":2}",
        .{},
    );
    defer invalid.deinit();
    const invalid_result = try validateTupleLockGateObjectAlloc(std.testing.allocator, "bad-lock.json", invalid.value.object);
    defer invalid_result.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_result.ok());
    try std.testing.expect(std.mem.indexOf(u8, invalid_result.errors[0], "lockVersion") != null);

    var null_binding = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"accountFingerprint\":\"acct:a\",\"baseSha\":\"base\",\"createdAtUnixS\":1,\"expiresAtUnixS\":30,\"headSha\":\"head\",\"lockVersion\":\"CAS-RTL-v1\",\"ownerPid\":4,\"repoRealpath\":\"/repo\",\"resolvedCodexPath\":\"/bin/codex\",\"resolvedCodexVersion\":\"codex 0.1.0\",\"reviewThreadId\":\"thr_1\",\"state\":\"waiting\",\"targetFingerprint\":\"fp\",\"tupleHash\":\"sha256:tuple\",\"updatedAtUnixS\":2,\"workflowBinding\":null}",
        .{},
    );
    defer null_binding.deinit();
    const null_binding_result = try validateTupleLockGateObjectAlloc(std.testing.allocator, "null-binding-lock.json", null_binding.value.object);
    defer null_binding_result.deinit(std.testing.allocator);
    try std.testing.expect(!null_binding_result.ok());
    try std.testing.expect(std.mem.indexOf(u8, null_binding_result.errors[0], "workflowBinding") != null);
}

test "parseArgs rejects removed receipt authority and closure surfaces" {
    const proof_argv = [_][]const u8{ "cas_review_session", "receipt", "proof", "--path", "start-wait.json" };
    try std.testing.expectError(error.UnknownArg, parseArgs(std.testing.allocator, &proof_argv));

    const removed_authority_action = "cert" ++ "ify";
    const authority_argv = [_][]const u8{ "cas_review_session", "receipt", removed_authority_action, "--cwd", "/tmp/repo", "--base", "main" };
    try std.testing.expectError(error.UnknownArg, parseArgs(std.testing.allocator, &authority_argv));

    const closure_argv = [_][]const u8{ "cas_review_session", "closure", "--cwd", "/tmp/repo", "--base", "main" };
    try std.testing.expectError(error.UnknownAction, parseArgs(std.testing.allocator, &closure_argv));
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
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "review.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("review.json", receipt.source_path);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expectEqualStrings("cas-lane", receipt.backend_class);
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
        \\{"demo":"cas-review-session","action":"lane-review","reviewThreadId":"thr_1","reviewTurnId":"turn_1","recordPath":"/tmp/record.json","eventLogPath":"/tmp/event.jsonl","targetFingerprint":"fp_1","headSha":"head_1","baseSha":"base_1","accountFingerprint":"acct:abc","accountFingerprintReducedProtection":false,"reviewVerdict":{"status":"clean","backendClass":"cas-lane","clean":true,"findingCount":0,"failureCode":null,"failureHint":null,"baseSha":"base_1","headSha":"head_1","targetFingerprint":"fp_1","reviewThreadId":"thr_1","reviewTurnId":"turn_1","recordPath":"/tmp/record.json","eventLogPath":"/tmp/event.jsonl","findings":[]}}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "review-strong.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expect(receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings(principal_strength_strong, receipt.principal_strength);
    try std.testing.expect(!receipt.account_fingerprint_reduced_protection);
    try std.testing.expect(normalizedReceiptCommandSucceeded(receipt));
}

test "receipt normalizer accepts compact verdict-only artifact" {
    const raw =
        \\{"status":"findings","backendClass":"cas-lane","clean":false,"findingCount":1,"failureCode":null,"failureHint":null,"reviewAttemptPhase":"normalized_verdict","baseSha":"base_2","headSha":"head_2","targetFingerprint":"fp_2","reviewThreadId":"thr_2","reviewTurnId":"turn_2","recordPath":"/tmp/record.json","eventLogPath":"/tmp/event.jsonl","findings":[{"title":"Issue","file":"/tmp/a.zig","line":12,"priority":1}]}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "verdict.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("findings", receipt.status);
    try std.testing.expect(!receipt.clean);
    try std.testing.expectEqual(@as(usize, 1), receipt.finding_count);
    try std.testing.expectEqualStrings("normalized_verdict", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings(principal_strength_reduced, receipt.principal_strength);
    try std.testing.expect(std.mem.indexOf(u8, receipt.findings_json, "Issue") != null);
    try std.testing.expect(!normalizedReceiptCommandSucceeded(receipt));
}

test "CAS-RER writer projects terminal findings receipt" {
    const raw =
        \\{"cwd":"/tmp/repo","status":"findings","backendClass":"cas-lane","clean":false,"findingCount":1,"failureCode":null,"failureHint":null,"reviewAttemptPhase":"normalized_verdict","baseSha":"base_rer","headSha":"head_rer","targetFingerprint":"fp_rer","reviewThreadId":"thr_rer","reviewTurnId":"turn_rer","recordPath":"/tmp/record.json","eventLogPath":"/tmp/event.jsonl","findings":[{"title":"Ledger issue","file":"/tmp/a.zig","line":12,"priority":1}]}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "findings-receipt.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);

    const rer_json = try casRerJsonFromReceiptAlloc(std.testing.allocator, receipt, .{});
    defer std.testing.allocator.free(rer_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rer_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(cas_review_evidence_schema, root.get("schema").?.string);
    try std.testing.expect(std.mem.startsWith(u8, root.get("recordId").?.string, "rer_"));
    try std.testing.expectEqualStrings("import", root.get("command").?.object.get("surface").?.string);
    try std.testing.expectEqualStrings("base_rer", root.get("tuple").?.object.get("baseSha").?.string);
    try std.testing.expectEqualStrings("head_rer", root.get("tuple").?.object.get("headSha").?.string);
    try std.testing.expectEqualStrings("fp_rer", root.get("tuple").?.object.get("targetFingerprint").?.string);
    const attempt = root.get("attempt").?.object;
    try std.testing.expect(attempt.get("exists").?.bool);
    try std.testing.expect(std.mem.startsWith(u8, attempt.get("attemptId").?.string, "sha256:"));
    try std.testing.expectEqualStrings("thr_rer", attempt.get("reviewThreadId").?.string);
    var copied_receipt = receipt;
    copied_receipt.source_path = "/tmp/copied-findings-receipt.json";
    const copied_attempt_id = (try casRerAttemptIdAlloc(std.testing.allocator, copied_receipt)).?;
    defer std.testing.allocator.free(copied_attempt_id);
    try std.testing.expectEqualStrings(attempt.get("attemptId").?.string, copied_attempt_id);
    const verdict = root.get("verdict").?.object;
    try std.testing.expect(verdict.get("tupleVerdictExists").?.bool);
    try std.testing.expectEqualStrings("findings", verdict.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 1), verdict.get("findingCount").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, rer_json, "Ledger issue") != null);
    const principal = root.get("principal").?.object;
    try std.testing.expectEqualStrings(principal_strength_reduced, principal.get("kind").?.string);
    try std.testing.expect(!principal.get("proofUsable").?.bool);
    try std.testing.expect(root.get("legacy").?.object.get("importedFromReceipt").?.bool);
    try std.testing.expect(root.get("workflowBinding") == null);

    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "rer.json", root);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(gate.ok());
}

test "CAS-RER binding is source carried validated and identity bearing" {
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"cwd\":\"/tmp/repo\",\"status\":\"clean\",\"backendClass\":\"cas-lane\",\"clean\":true,\"findingCount\":0,\"failureCode\":null,\"reviewAttemptPhase\":\"normalized_verdict\",\"baseSha\":\"base\",\"headSha\":\"head\",\"targetFingerprint\":\"fp\",\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\",\"workflowBinding\":{s},\"findings\":[]}}",
        .{test_workflow_binding_json},
    );
    defer std.testing.allocator.free(raw);
    const bound = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "bound.json", raw, true, .{});
    defer bound.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(test_workflow_binding_json, bound.workflow_binding_json.?);

    const bound_json = try casRerJsonFromReceiptAlloc(std.testing.allocator, bound, .{});
    defer std.testing.allocator.free(bound_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bound_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("request-test", root.get("workflowBinding").?.object.get("requestId").?.string);
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "bound-rer.json", root);
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
    var invalid_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, invalid_json, .{});
    defer invalid_parsed.deinit();
    const invalid_gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "partial-bound-rer.json", invalid_parsed.value.object);
    defer invalid_gate.deinit(std.testing.allocator);
    try std.testing.expect(!invalid_gate.ok());

    var extra = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"workflowBinding":{"requestId":"request-test","requestFingerprint":"sha256:request","extra":"not-exact"}}
    ,
        .{},
    );
    defer extra.deinit();
    try std.testing.expect(!workflowBindingObjectMatches(extra.value.object, testWorkflowBinding()));

    var unbound = bound;
    unbound.workflow_binding_json = null;
    const bound_id = try casRerRecordIdAlloc(std.testing.allocator, bound, .{});
    defer std.testing.allocator.free(bound_id);
    const unbound_id = try casRerRecordIdAlloc(std.testing.allocator, unbound, .{});
    defer std.testing.allocator.free(unbound_id);
    try std.testing.expect(!std.mem.eql(u8, bound_id, unbound_id));
}

test "CAS-RER ledger record projection matches tuple identity" {
    const raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_match","createdAt":"2026-07-02T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","command":{"surface":"import","backendSelected":"imported-legacy","brokerDecision":{"action":"imported_legacy","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","resolvedCodexPath":"/bin/codex","resolvedCodexVersion":"codex 0.1.0","codexThreadId":"thread-test","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:a","phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":true,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    try std.testing.expect(casRerObjectMatchesHistoryScope(parsed.value.object, "/tmp/repo", identity, "thread-test", null));
    try std.testing.expect(!casRerObjectMatchesHistoryScope(parsed.value.object, "/tmp/repo", identity, "thread-other", null));
    try std.testing.expect(!casRerObjectMatchesHistoryScope(parsed.value.object, "/tmp/repo", identity, "thread-test", testWorkflowBinding()));
    try std.testing.expect(casRerObjectMatchesIdentity(parsed.value.object, "/tmp/repo", identity, "/bin/codex", "codex 0.1.0", "acct:test", false, "thread-test"));
    try std.testing.expect(!casRerObjectMatchesIdentity(parsed.value.object, "/tmp/repo", identity, "/bin/codex", "codex 0.1.0", "acct:test", true, "thread-test"));
    try std.testing.expect(!casRerObjectMatchesIdentity(parsed.value.object, "/tmp/repo", identity, "/usr/local/bin/codex", "codex 0.1.0", "acct:test", false, "thread-test"));
    try std.testing.expect(!casRerObjectMatchesIdentity(parsed.value.object, "/tmp/repo", identity, "/bin/codex", "codex 0.2.0", "acct:test", false, "thread-test"));
    try std.testing.expect(!casRerObjectMatchesIdentity(parsed.value.object, "/tmp/repo", identity, "/bin/codex", "codex 0.1.0", "acct:other", false, "thread-test"));
    try std.testing.expect(!casRerObjectMatchesIdentity(parsed.value.object, "/tmp/repo", identity, "/bin/codex", "codex 0.1.0", "acct:test", false, "thread-other"));
    const non_proof_raw = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        raw,
        "\"proofUsable\":true",
        "\"proofUsable\":false",
    );
    defer std.testing.allocator.free(non_proof_raw);
    var non_proof = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, non_proof_raw, .{});
    defer non_proof.deinit();
    try std.testing.expect(casRerObjectMatchesIdentity(non_proof.value.object, "/tmp/repo", identity, "/bin/codex", "codex 0.1.0", "acct:test", false, "thread-test"));
    const legacy_without_thread_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_match","createdAt":"2026-07-02T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","command":{"surface":"import","backendSelected":"imported-legacy","brokerDecision":{"action":"imported_legacy","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","resolvedCodexPath":"/bin/codex","resolvedCodexVersion":"codex 0.1.0","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:a","phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":true,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    var legacy_without_thread = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, legacy_without_thread_raw, .{});
    defer legacy_without_thread.deinit();
    try std.testing.expect(casRerObjectMatchesIdentity(legacy_without_thread.value.object, "/tmp/repo", identity, "/bin/codex", "codex 0.1.0", "acct:test", false, "thread-test"));
    const wrong_identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "other",
        .fingerprint = "fp",
    };
    try std.testing.expect(!casRerObjectMatchesIdentity(parsed.value.object, "/tmp/repo", wrong_identity, "/bin/codex", "codex 0.1.0", "acct:test", false, "thread-test"));

    var record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_match.json", raw);
    defer record.deinit(std.testing.allocator);
    record.context_identity_matches = true;
    try std.testing.expectEqualStrings("rer_match", record.record_id);
    try std.testing.expectEqualStrings("clean", record.status);
    try std.testing.expect(record.tuple_verdict_exists);

    const reduced_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_reduced","createdAt":"2026-07-02T00:00:01Z","updatedAt":"2026-07-02T00:00:01Z","command":{"surface":"import","backendSelected":"imported-legacy","brokerDecision":{"action":"imported_legacy","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:b","phase":"normalized_verdict","reviewThreadId":"thr_reduced","reviewTurnId":"turn_reduced"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"reduced","proofUsable":false,"reduced":true,"fallbackUsed":false,"source":"cas-lane"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":true,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const reduced_record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_reduced.json", reduced_raw);
    defer reduced_record.deinit(std.testing.allocator);
    try std.testing.expect(reduced_record.tuple_verdict_exists);
    try std.testing.expect(!reduced_record.principal_proof_usable);
    const ranked_records = [_]CasRerLedgerRecord{ reduced_record, record };
    try std.testing.expectEqual(@as(?usize, 0), latestCasRerLedgerRecordIndex(&ranked_records));

    const unix_timestamp_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_unix_ts","createdAt":"unix-ns:500000000","updatedAt":"unix-ns:500000000","command":{"surface":"run","backendSelected":"cas-run","brokerDecision":{"action":"created_new","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:unix","phase":"normalized_verdict","reviewThreadId":"thr_unix","reviewTurnId":"turn_unix"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-run"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":false,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const unix_timestamp_record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_unix_ts.json", unix_timestamp_raw);
    defer unix_timestamp_record.deinit(std.testing.allocator);
    const iso_timestamp_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_iso_ts","createdAt":"1970-01-01T00:00:00.900Z","updatedAt":"1970-01-01T00:00:00.900Z","command":{"surface":"run","backendSelected":"cas-run","brokerDecision":{"action":"created_new","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:iso","phase":"normalized_verdict","reviewThreadId":"thr_iso","reviewTurnId":"turn_iso"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-run"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":false,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const iso_timestamp_record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_iso_ts.json", iso_timestamp_raw);
    defer iso_timestamp_record.deinit(std.testing.allocator);
    const timestamp_records = [_]CasRerLedgerRecord{ unix_timestamp_record, iso_timestamp_record };
    try std.testing.expectEqual(@as(?usize, 1), latestCasRerLedgerRecordIndex(&timestamp_records));
    try std.testing.expectEqual(@as(?i128, 900_000_000), parseCasRerCreatedAtNs("1970-01-01T00:00:00.900Z"));
    try std.testing.expectEqual(@as(?i128, 0), parseCasRerCreatedAtNs("1970-01-01T01:00:00+01:00"));
    try std.testing.expectEqual(@as(?i128, 1_500_000_000), parseCasRerCreatedAtNs("1970-01-01T00:00:01.500+00:00"));

    const fresh_waiting_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_fresh_waiting","createdAt":"2026-07-02T00:00:10Z","updatedAt":"2026-07-02T00:00:10Z","command":{"surface":"run","backendSelected":"cas-run","brokerDecision":{"action":"created_new","reason":"fresh retry","freshAttemptRequired":true}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:fresh","phase":"review_waiting","reviewThreadId":"thr_fresh","reviewTurnId":"turn_fresh"},"verdict":{"tupleVerdictExists":false,"status":"incomplete","clean":false,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":true},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-run"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":false,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const fresh_waiting_record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_fresh_waiting.json", fresh_waiting_raw);
    defer fresh_waiting_record.deinit(std.testing.allocator);
    const fresh_records = [_]CasRerLedgerRecord{ record, fresh_waiting_record };
    try std.testing.expectEqual(@as(?usize, 1), latestCasRerLedgerRecordIndex(&fresh_records));

    const timeout_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_timeout","createdAt":"2026-07-02T00:00:02Z","updatedAt":"2026-07-02T00:00:02Z","command":{"surface":"run","backendSelected":"cas-run","brokerDecision":{"action":"created_new","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:c","phase":"review_waiting","reviewThreadId":"thr_timeout","reviewTurnId":"turn_timeout"},"verdict":{"tupleVerdictExists":false,"status":"timeout","clean":false,"findingCount":0,"findings":[]},"failure":{"failureCode":"wait_timed_out","failureClass":"timeout","retryableSameTupleNow":true},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-start-wait"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":false,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const timeout_record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_timeout.json", timeout_raw);
    defer timeout_record.deinit(std.testing.allocator);
    try std.testing.expect(timeout_record.attempt_exists);
    try std.testing.expect(!timeout_record.tuple_verdict_exists);

    const active_incomplete_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_active","createdAt":"2026-07-02T00:00:03Z","updatedAt":"2026-07-02T00:00:03Z","command":{"surface":"run","backendSelected":"cas-run","brokerDecision":{"action":"blocked_live","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:d","phase":"review_waiting","reviewThreadId":"thr_active","reviewTurnId":"turn_active"},"verdict":{"tupleVerdictExists":false,"status":"incomplete","clean":false,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":true},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-run"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":false,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const active_record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_active.json", active_incomplete_raw);
    defer active_record.deinit(std.testing.allocator);
    try std.testing.expect(active_record.attempt_exists);
    try std.testing.expect(!active_record.tuple_verdict_exists);

    const stale_lock_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_stale_lock","createdAt":"2026-07-02T00:00:03Z","updatedAt":"2026-07-02T00:00:03Z","command":{"surface":"run","backendSelected":"cas-run","brokerDecision":{"action":"blocked_live","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:d","phase":"review_waiting","reviewThreadId":"thr_stale","reviewTurnId":"turn_stale"},"verdict":{"tupleVerdictExists":false,"status":"incomplete","clean":false,"findingCount":0,"findings":[]},"failure":{"failureCode":"review_tuple_lock_stale","failureClass":"coordination","retryableSameTupleNow":false},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-run"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":false,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const stale_lock_record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_stale_lock.json", stale_lock_raw);
    defer stale_lock_record.deinit(std.testing.allocator);

    const active_transport_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_active_transport","createdAt":"2026-07-02T00:00:04Z","updatedAt":"2026-07-02T00:00:04Z","command":{"surface":"run","backendSelected":"cas-run","brokerDecision":{"action":"created_new","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:e","phase":"review_waiting","reviewThreadId":"thr_transport","reviewTurnId":"turn_transport"},"verdict":{"tupleVerdictExists":false,"status":"transport_failure","clean":false,"findingCount":0,"findings":[]},"failure":{"failureCode":"review_transport_lost","failureClass":"transport","retryableSameTupleNow":true},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-start-wait"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":false,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const active_transport_record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_active_transport.json", active_transport_raw);
    defer active_transport_record.deinit(std.testing.allocator);
    try std.testing.expect(active_transport_record.attempt_exists);

    const terminal_incomplete_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_terminal_incomplete","createdAt":"2026-07-02T00:00:05Z","updatedAt":"2026-07-02T00:00:05Z","command":{"surface":"run","backendSelected":"cas-run","brokerDecision":{"action":"created_new","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:f","phase":"review_terminal","reviewThreadId":"thr_terminal","reviewTurnId":"turn_terminal"},"verdict":{"tupleVerdictExists":false,"status":"incomplete","clean":false,"findingCount":1,"findings":[{"title":"tuple mismatch"}]},"failure":{"failureCode":"tuple_mismatch","failureClass":"caller_error","retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-start-wait"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":false,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const terminal_incomplete_record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_terminal_incomplete.json", terminal_incomplete_raw);
    defer terminal_incomplete_record.deinit(std.testing.allocator);
    try std.testing.expect(terminal_incomplete_record.attempt_exists);
    try std.testing.expect(!terminal_incomplete_record.tuple_verdict_exists);
}

test "CAS current and list envelopes include ledger record paths" {
    const raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_path","createdAt":"2026-07-02T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","command":{"surface":"run","backendSelected":"cas-run","brokerDecision":{"action":"created_new","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:a","phase":"review_terminal","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"findings","clean":false,"findingCount":1,"findings":[{"title":"issue"}]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-start-wait"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":false,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const record = try casRerLedgerRecordFromJsonAlloc(std.testing.allocator, "/tmp/rer_path.json", raw);
    defer record.deinit(std.testing.allocator);
    const records = [_]CasRerLedgerRecord{record};

    var current_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer current_out.deinit();
    try writeCasReviewCurrentEnvelope(&current_out.writer, &records);
    const current_json = try current_out.toOwnedSlice();
    defer std.testing.allocator.free(current_json);
    var current_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, current_json, .{});
    defer current_parsed.deinit();
    const current = current_parsed.value.object;
    try std.testing.expectEqualStrings("CAS-CURRENT-v2", current.get("schema").?.string);
    try std.testing.expectEqualStrings("/tmp/rer_path.json", current.get("recordPath").?.string);
    try std.testing.expect(current.get("actionRequired") == null);
    try std.testing.expect(!current.get("contextIdentityMatches").?.bool);
    try std.testing.expectEqualStrings("rer_path", current.get("record").?.object.get("recordId").?.string);

    var list_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list_out.deinit();
    try writeCasReviewListEnvelope(&list_out.writer, &records);
    const list_json = try list_out.toOwnedSlice();
    defer std.testing.allocator.free(list_json);
    var list_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, list_json, .{});
    defer list_parsed.deinit();
    const list = list_parsed.value.object;
    try std.testing.expectEqualStrings("CAS-LIST-v2", list.get("schema").?.string);
    try std.testing.expectEqual(@as(usize, 1), list.get("records").?.array.items.len);
    try std.testing.expectEqualStrings("rer_path", list.get("records").?.array.items[0].object.get("recordId").?.string);
    const ref = list.get("recordRefs").?.array.items[0].object;
    try std.testing.expectEqualStrings("rer_path", ref.get("recordId").?.string);
    try std.testing.expectEqualStrings("/tmp/rer_path.json", ref.get("recordPath").?.string);
    try std.testing.expect(!ref.get("contextIdentityMatches").?.bool);
}

test "CAS list retains drifted findings while reporting context mismatch" {
    const old_store_root = configured_store_root_override;
    defer configured_store_root_override = old_store_root;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    configured_store_root_override = root;

    const records_dir = try reviewLedgerRecordsDirAlloc(std.testing.allocator);
    defer std.testing.allocator.free(records_dir);
    const record_path = try std.fs.path.join(std.testing.allocator, &.{ records_dir, "rer_history.json" });
    defer std.testing.allocator.free(record_path);
    const raw = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_history\",\"createdAt\":\"2026-07-02T00:00:00Z\",\"updatedAt\":\"2026-07-02T00:00:00Z\",\"command\":{{\"surface\":\"run\",\"backendSelected\":\"cas-run\",\"brokerDecision\":{{\"action\":\"created_new\",\"reason\":\"test\",\"freshAttemptRequired\":false}}}},\"tuple\":{{\"repoRealpath\":\"{s}\",\"baseSha\":\"base\",\"headSha\":\"head\",\"targetFingerprint\":\"fp\",\"resolvedCodexPath\":\"/old/codex\",\"resolvedCodexVersion\":\"codex 0.1.0\",\"codexThreadId\":\"thread-test\",\"tupleCurrentAtRecordTime\":true}},\"attempt\":{{\"exists\":true,\"attemptId\":\"sha256:a\",\"phase\":\"normalized_verdict\",\"reviewThreadId\":\"thr\",\"reviewTurnId\":\"turn\"}},\"verdict\":{{\"tupleVerdictExists\":true,\"status\":\"findings\",\"clean\":false,\"findingCount\":1,\"findings\":[{{\"title\":\"drift-visible\"}}]}},\"failure\":{{\"failureCode\":null,\"failureClass\":null,\"retryableSameTupleNow\":null}},\"principal\":{{\"kind\":\"strong\",\"accountFingerprint\":\"acct:old\",\"proofUsable\":true,\"reduced\":false,\"fallbackUsed\":false,\"source\":\"cas-run\"}},\"attachments\":{{\"rawReceipt\":\"/tmp/receipt.json\"}},\"legacy\":{{\"importedFromReceipt\":false,\"sourcePath\":\"/tmp/receipt.json\",\"normalizationWarnings\":[]}}}}",
        .{root},
    );
    defer std.testing.allocator.free(raw);
    try durable_store.writeTextAtomic(std.testing.allocator, record_path, raw);

    const identity = TargetIdentity{ .base_sha = "base", .head_sha = "head", .fingerprint = "fp" };
    var drifted: std.ArrayList(CasRerLedgerRecord) = .empty;
    defer {
        for (drifted.items) |record| record.deinit(std.testing.allocator);
        drifted.deinit(std.testing.allocator);
    }
    try appendCasRerLedgerRecordsAlloc(
        std.testing.allocator,
        &drifted,
        root,
        identity,
        "/new/codex",
        "codex 0.2.0",
        "acct:new",
        false,
        "thread-test",
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), drifted.items.len);
    try std.testing.expectEqualStrings("findings", drifted.items[0].status);
    try std.testing.expect(!drifted.items[0].context_identity_matches);

    var exact: std.ArrayList(CasRerLedgerRecord) = .empty;
    defer {
        for (exact.items) |record| record.deinit(std.testing.allocator);
        exact.deinit(std.testing.allocator);
    }
    try appendCasRerLedgerRecordsAlloc(
        std.testing.allocator,
        &exact,
        root,
        identity,
        "/old/codex",
        "codex 0.1.0",
        "acct:old",
        false,
        "thread-test",
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), exact.items.len);
    try std.testing.expect(exact.items[0].context_identity_matches);

    var foreign_epoch: std.ArrayList(CasRerLedgerRecord) = .empty;
    defer foreign_epoch.deinit(std.testing.allocator);
    try appendCasRerLedgerRecordsAlloc(
        std.testing.allocator,
        &foreign_epoch,
        root,
        identity,
        "/old/codex",
        "codex 0.1.0",
        "acct:old",
        false,
        "thread-test",
        testWorkflowBinding(),
    );
    try std.testing.expectEqual(@as(usize, 0), foreign_epoch.items.len);
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

    var fallback = strong_clean;
    fallback.backend_class = "cas-native-fallback";
    try std.testing.expect(!normalizedReceiptCommandSucceeded(fallback));

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
        receipt,
        "review_started",
    );
    defer std.testing.allocator.free(payload_json);

    try std.testing.expect(std.mem.indexOf(u8, payload_json, "\"resolvedCodexPath\":\"/bin/codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_json, "\"resolvedCodexVersion\":\"codex 0.1.0\"") != null);

    const normalized = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "/tmp/record.json", payload_json, true, .{
        .requested_identity = identity,
        .requested_identity_required = true,
    });
    defer normalized.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/bin/codex", normalized.resolved_codex_path.?);
    try std.testing.expectEqualStrings("codex 0.1.0", normalized.resolved_codex_version.?);

    const rer_json = try casRerJsonFromReceiptAlloc(std.testing.allocator, normalized, .{
        .repo_realpath_override = "/tmp/repo",
    });
    defer std.testing.allocator.free(rer_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rer_json, .{});
    defer parsed.deinit();
    const tuple = parsed.value.object.get("tuple").?.object;
    try std.testing.expectEqualStrings("/bin/codex", tuple.get("resolvedCodexPath").?.string);
    try std.testing.expectEqualStrings("codex 0.1.0", tuple.get("resolvedCodexVersion").?.string);
}

test "CAS-RER writer projects pre-review lane transport as non-attempt" {
    const raw =
        \\{"demo":"cas-review-session","action":"lane-review","reviewAttemptPhase":"pre_review_start","reviewAttemptExists":false,"tupleVerdictExists":false,"reviewThreadId":null,"reviewTurnId":null,"baseSha":"base_1","headSha":"head_1","targetFingerprint":"fp_1","failureCode":"pre_review_lane_transport_lost","failureClass":"transport_pre_review","failureHint":"restart lane"}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "pre-review.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);

    const rer_json = try casRerJsonFromReceiptAlloc(std.testing.allocator, receipt, .{});
    defer std.testing.allocator.free(rer_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rer_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const attempt = root.get("attempt").?.object;
    try std.testing.expect(!attempt.get("exists").?.bool);
    try std.testing.expectEqualStrings("pre_review_start", attempt.get("phase").?.string);
    switch (attempt.get("reviewThreadId").?) {
        .null => {},
        else => return error.ExpectedNull,
    }
    switch (attempt.get("attemptId").?) {
        .null => {},
        else => return error.ExpectedNull,
    }
    const verdict = root.get("verdict").?.object;
    try std.testing.expect(!verdict.get("tupleVerdictExists").?.bool);
    try std.testing.expectEqualStrings("transport_failure", verdict.get("status").?.string);
    const failure = root.get("failure").?.object;
    try std.testing.expectEqualStrings("pre_review_lane_transport_lost", failure.get("failureCode").?.string);
    try std.testing.expectEqualStrings("transport_pre_review", failure.get("failureClass").?.string);

    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "pre-review-rer.json", root);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(gate.ok());
}

test "CAS-RER validator rejects findings without finding count" {
    const raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_bad","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"findings","clean":false,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
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
        \\{"schema":"CAS-RER-v1","recordId":"rer_findings_empty","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"findings","clean":false,"findingCount":1,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
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
        \\{"schema":"CAS-RER-v1","recordId":"rer_tuple_timeout","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"review_waiting","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"timeout","clean":false,"findingCount":0,"findings":[]},"failure":{"failureCode":"wait_timed_out","failureClass":"timeout","retryableSameTupleNow":true},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
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
        \\{"schema":"CAS-RER-v1","recordId":"rer_waiting_clean","command":{"surface":"import","backendSelected":"imported-legacy","brokerDecision":{"action":"imported_legacy","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"review_waiting","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
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
        \\{"schema":"CAS-RER-v1","recordId":"rer_bad_timestamp","createdAt":"zzzz","updatedAt":"2026-07-02T00:00:00Z","command":{"surface":"import","backendSelected":"imported-legacy","brokerDecision":{"action":"imported_legacy","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "bad-timestamp-rer.json", parsed.value.object);
    defer gate.deinit(std.testing.allocator);
    try std.testing.expect(!gate.ok());
    try std.testing.expect(gateErrorsContain(gate, "createdAt"));
}

test "CAS-RER validator rejects verdict clean/status disagreement" {
    const clean_false_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_clean_false","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":false,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
    var clean_false = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, clean_false_raw, .{});
    defer clean_false.deinit();
    const clean_false_gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "clean-false-rer.json", clean_false.value.object);
    defer clean_false_gate.deinit(std.testing.allocator);
    try std.testing.expect(!clean_false_gate.ok());
    try std.testing.expect(clean_false_gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(clean_false_gate, "verdict.clean=true"));

    const findings_true_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_findings_true","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"findings","clean":true,"findingCount":1,"findings":[{"title":"issue"}]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
    var findings_true = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, findings_true_raw, .{});
    defer findings_true.deinit();
    const findings_true_gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "findings-true-rer.json", findings_true.value.object);
    defer findings_true_gate.deinit(std.testing.allocator);
    try std.testing.expect(!findings_true_gate.ok());
    try std.testing.expect(findings_true_gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(findings_true_gate, "verdict.clean=false"));
}

test "CAS-RER validator rejects terminal verdict failure metadata" {
    const clean_failure_class_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_clean_failure_class","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":"transport","retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
    var clean_failure_class = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, clean_failure_class_raw, .{});
    defer clean_failure_class.deinit();
    const clean_gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "clean-failure-class-rer.json", clean_failure_class.value.object);
    defer clean_gate.deinit(std.testing.allocator);
    try std.testing.expect(!clean_gate.ok());
    try std.testing.expect(clean_gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(clean_gate, "failure.failureClass=null"));

    const findings_failure_raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_findings_failure","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"findings","clean":false,"findingCount":1,"findings":[{"title":"issue"}]},"failure":{"failureCode":"review_parse_mismatch","failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
    var findings_failure = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, findings_failure_raw, .{});
    defer findings_failure.deinit();
    const findings_gate = try validateCasRerRecordObjectAlloc(std.testing.allocator, "findings-failure-rer.json", findings_failure.value.object);
    defer findings_gate.deinit(std.testing.allocator);
    try std.testing.expect(!findings_gate.ok());
    try std.testing.expect(findings_gate.errors.len >= 1);
    try std.testing.expect(gateErrorsContain(findings_gate, "failure.failureCode=null"));
}

test "CAS-RER validator rejects terminal verdict without attempt" {
    const raw =
        \\{"schema":"CAS-RER-v1","recordId":"rer_no_attempt","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":false,"phase":"normalized_verdict","reviewThreadId":null,"reviewTurnId":null},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
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
        \\{"schema":"CAS-RER-v1","recordId":"rer_no_repo","tuple":{"repoRealpath":null,"baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
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
        \\{"schema":"CAS-RER-v1","recordId":"rer_empty_thread","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"review_waiting","reviewThreadId":"","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":false,"status":"incomplete","clean":false,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":true},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
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
        \\{"schema":"CAS-RER-v1","recordId":"rer_unbound_principal","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
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
        \\{"schema":"CAS-RER-v1","recordId":"rer_missing_command","tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
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
        \\{"schema":"CAS-RER-v1","recordId":"rer_empty_command","command":{},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-lane"}}
    ;
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

test "CAS-RER projection fills missing repo realpath from import cwd" {
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
        .repo_realpath = null,
        .resolved_codex_path = "/bin/codex",
        .resolved_codex_version = "codex 0.1.0",
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
    const rer_json = try casRerJsonFromReceiptAlloc(std.testing.allocator, receipt, .{
        .repo_realpath_override = "/tmp/repo",
    });
    defer std.testing.allocator.free(rer_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rer_json, .{});
    defer parsed.deinit();
    const tuple = parsed.value.object.get("tuple").?.object;
    try std.testing.expectEqualStrings("/tmp/repo", tuple.get("repoRealpath").?.string);
    try std.testing.expectEqualStrings("/bin/codex", tuple.get("resolvedCodexPath").?.string);
    try std.testing.expectEqualStrings("codex 0.1.0", tuple.get("resolvedCodexVersion").?.string);
    try std.testing.expect(!tuple.get("tupleCurrentAtRecordTime").?.bool);

    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    try std.testing.expect(receiptTupleMatchesIdentity(receipt, identity));
    const matched_json = try casRerJsonFromReceiptAlloc(std.testing.allocator, receipt, .{
        .repo_realpath_override = "/tmp/repo",
        .resolved_codex_path_override = "/opt/codex",
        .resolved_codex_version_override = "codex 9.9.9",
        .account_fingerprint_override = "acct:import",
        .tuple_current_at_record_time = receiptTupleMatchesIdentity(receipt, identity),
    });
    defer std.testing.allocator.free(matched_json);
    var matched = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, matched_json, .{});
    defer matched.deinit();
    const matched_tuple = matched.value.object.get("tuple").?.object;
    try std.testing.expect(matched_tuple.get("tupleCurrentAtRecordTime").?.bool);
    try std.testing.expectEqualStrings("/opt/codex", matched_tuple.get("resolvedCodexPath").?.string);
    try std.testing.expectEqualStrings("codex 9.9.9", matched_tuple.get("resolvedCodexVersion").?.string);
    try std.testing.expectEqualStrings("acct:import", matched.value.object.get("principal").?.object.get("accountFingerprint").?.string);
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

    try writeRawJsonFileExclusiveOrIdenticalAlloc(std.testing.allocator, path, "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_same\",\"createdAt\":\"2026-07-02T00:00:00Z\",\"updatedAt\":\"2026-07-02T00:00:00Z\",\"attempt\":{\"recordPath\":\"/tmp/original-session.json\"},\"attachments\":{\"rawSessionRecord\":\"/tmp/original-session.json\",\"rawReceipt\":\"/tmp/original.json\"},\"legacy\":{\"sourcePath\":\"/tmp/original.json\"},\"value\":1}");
    try writeRawJsonFileExclusiveOrIdenticalAlloc(std.testing.allocator, path, "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_same\",\"createdAt\":\"2026-07-02T00:00:01Z\",\"updatedAt\":\"2026-07-02T00:00:01Z\",\"attempt\":{\"recordPath\":\"/tmp/archive/copy-session.json\"},\"attachments\":{\"rawSessionRecord\":\"/tmp/archive/copy-session.json\",\"rawReceipt\":\"/tmp/copy.json\"},\"legacy\":{\"sourcePath\":\"/tmp/copy.json\"},\"value\":1}");
    try std.testing.expectError(error.CasRerRecordIdCollision, writeRawJsonFileExclusiveOrIdenticalAlloc(std.testing.allocator, path, "{\"schema\":\"CAS-RER-v1\",\"recordId\":\"rer_same\",\"createdAt\":\"2026-07-02T00:00:02Z\",\"updatedAt\":\"2026-07-02T00:00:02Z\",\"value\":2}"));
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
    const first = try casRerRecordIdAlloc(std.testing.allocator, receipt, .{
        .created_at = "2026-07-02T00:00:00Z",
        .updated_at = "2026-07-02T00:00:00Z",
    });
    defer std.testing.allocator.free(first);
    const second = try casRerRecordIdAlloc(std.testing.allocator, receipt, .{
        .created_at = "2026-07-02T00:00:01Z",
        .updated_at = "2026-07-02T00:00:01Z",
    });
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);

    var copied_receipt = receipt;
    copied_receipt.source_path = "/tmp/copied-source.json";
    const copied = try casRerRecordIdAlloc(std.testing.allocator, copied_receipt, .{
        .created_at = "2026-07-02T00:00:02Z",
        .updated_at = "2026-07-02T00:00:02Z",
    });
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
    });
    defer std.testing.allocator.free(start_wait);
    const run = try casRerRecordIdAlloc(std.testing.allocator, receipt, .{
        .command_surface = "run",
        .backend_selected = "cas-run",
        .broker_action = "returned_terminal",
        .broker_reason = "test",
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
    });
    defer std.testing.allocator.free(reduced_id);
    try std.testing.expect(!std.mem.eql(u8, start_wait, reduced_id));

    var fallback = receipt;
    fallback.backend_class = "cas-native-fallback";
    const fallback_id = try casRerRecordIdAlloc(std.testing.allocator, fallback, .{
        .command_surface = "start_wait",
        .backend_selected = "cas-start-wait",
        .broker_action = "created_new",
        .broker_reason = "test",
    });
    defer std.testing.allocator.free(fallback_id);
    try std.testing.expect(!std.mem.eql(u8, start_wait, fallback_id));
}

test "CAS-RER projection lets requested import cwd override receipt repo" {
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
        .repo_realpath = "/tmp/old-repo",
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
    const old_json = try casRerJsonFromReceiptAlloc(std.testing.allocator, receipt, .{});
    defer std.testing.allocator.free(old_json);
    var old_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, old_json, .{});
    defer old_parsed.deinit();

    const override_json = try casRerJsonFromReceiptAlloc(std.testing.allocator, receipt, .{
        .repo_realpath_override = "/tmp/new-repo",
    });
    defer std.testing.allocator.free(override_json);
    var override_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, override_json, .{});
    defer override_parsed.deinit();

    try std.testing.expectEqualStrings("/tmp/new-repo", override_parsed.value.object.get("tuple").?.object.get("repoRealpath").?.string);
    try std.testing.expect(!std.mem.eql(u8, old_parsed.value.object.get("recordId").?.string, override_parsed.value.object.get("recordId").?.string));
}

test "CAS-RUN envelope verdict imports through wrapper without tuple mismatch" {
    const raw =
        \\{"schema":"CAS-RUN-v1","record":{"schema":"CAS-RER-v1"},"reviewVerdict":{"status":"clean","reviewAttemptPhase":"normalized_verdict","reviewAttemptExists":true,"tupleVerdictExists":true,"principalStrength":"strong","accountFingerprint":"acct:test","accountFingerprintReducedProtection":false,"backendClass":"cas-start-wait","clean":true,"findingCount":0,"failureCode":null,"failureHint":null,"baseSha":"base","headSha":"head","targetFingerprint":"fp","reviewThreadId":"thr","reviewTurnId":"turn","findings":[]}}
    ;
    const requested = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "run-envelope.json", raw, true, .{
        .requested_identity = requested,
        .requested_identity_required = true,
    });
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expect(receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("base", receipt.base_sha.?);
    try std.testing.expectEqualStrings("head", receipt.head_sha.?);
    try std.testing.expectEqualStrings("fp", receipt.target_fingerprint.?);
}

test "review import extracts nested CAS-RER records from envelopes" {
    const record_json =
        \\{"schema":"CAS-RER-v1","recordId":"rer_nested","createdAt":"2026-07-02T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","command":{"surface":"run","backendSelected":"cas-run","sourceBackendClass":"cas-start-wait","brokerDecision":{"action":"created_new","reason":"test","freshAttemptRequired":false}},"tuple":{"repoRealpath":"/tmp/repo","baseSha":"base","headSha":"head","targetFingerprint":"fp","resolvedCodexPath":"/bin/codex","resolvedCodexVersion":"codex 0.1.0","codexThreadId":"thread-test","tupleCurrentAtRecordTime":true},"attempt":{"exists":true,"attemptId":"sha256:a","phase":"normalized_verdict","reviewThreadId":"thr","reviewTurnId":"turn"},"verdict":{"tupleVerdictExists":true,"status":"clean","clean":true,"findingCount":0,"findings":[]},"failure":{"failureCode":null,"failureClass":null,"retryableSameTupleNow":null},"principal":{"kind":"strong","accountFingerprint":"acct:test","proofUsable":true,"reduced":false,"fallbackUsed":false,"source":"cas-start-wait"},"attachments":{"rawReceipt":"/tmp/receipt.json"},"legacy":{"importedFromReceipt":false,"sourcePath":"/tmp/receipt.json","normalizationWarnings":[]}}
    ;
    const run_envelope = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"schema":"CAS-RUN-v1","record":{s},"reviewVerdict":{{"status":"clean","backendClass":"cas-start-wait","clean":true,"findingCount":0,"baseSha":"base","headSha":"head","targetFingerprint":"fp","reviewThreadId":"thr","findings":[]}}}}
    , .{record_json});
    defer std.testing.allocator.free(run_envelope);
    var run_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, run_envelope, .{});
    defer run_parsed.deinit();

    var records: std.ArrayList([]u8) = .empty;
    defer {
        for (records.items) |record| std.testing.allocator.free(record);
        records.deinit(std.testing.allocator);
    }
    try std.testing.expect(try collectNestedCasRerRecordsAlloc(std.testing.allocator, &records, run_parsed.value.object));
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    var nested = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, records.items[0], .{});
    defer nested.deinit();
    try std.testing.expectEqualStrings("rer_nested", nested.value.object.get("recordId").?.string);
    try std.testing.expectEqualStrings("/bin/codex", nested.value.object.get("tuple").?.object.get("resolvedCodexPath").?.string);
    try std.testing.expectEqualStrings("acct:test", nested.value.object.get("principal").?.object.get("accountFingerprint").?.string);
    const requested_identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    try std.testing.expect(casRerObjectMatchesIdentity(nested.value.object, "/tmp/repo", requested_identity, "/bin/codex", "codex 0.1.0", "acct:test", false, "thread-test"));
    try std.testing.expect(!casRerObjectMatchesIdentity(nested.value.object, "/tmp/repo", requested_identity, "/bin/codex", "codex 0.1.0", "acct:other", false, "thread-test"));

    const import_envelope = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"schema":"CAS-IMPORT-v1","records":[{{"sourcePath":"/tmp/receipt.json","validation":{{"ok":false,"errors":["bad"],"path":"/tmp/receipt.json"}},"record":{s}}},{{"sourcePath":"/tmp/receipt.json","validation":{{"ok":true,"errors":[],"path":"/tmp/receipt.json"}},"record":{s}}},{s}],"errors":[]}}
    , .{ record_json, record_json, record_json });
    defer std.testing.allocator.free(import_envelope);
    var import_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, import_envelope, .{});
    defer import_parsed.deinit();
    try std.testing.expect(try collectNestedCasRerRecordsAlloc(std.testing.allocator, &records, import_parsed.value.object));
    try std.testing.expectEqual(@as(usize, 3), records.items.len);

    const jsonl_envelope = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"schema":"CAS-IMPORT-v1","records":[{{"sourcePath":"/tmp/receipt.json","validation":{{"ok":false,"errors":["bad"],"path":"/tmp/receipt.json"}},"record":{s}}}],"errors":[]}}
        \\
        \\{s}
    , .{ record_json, record_json });
    defer std.testing.allocator.free(jsonl_envelope);
    var jsonl_records: std.ArrayList([]u8) = .empty;
    defer {
        for (jsonl_records.items) |record| std.testing.allocator.free(record);
        jsonl_records.deinit(std.testing.allocator);
    }
    try std.testing.expect(try collectNestedCasRerRecordsFromJsonLinesAlloc(std.testing.allocator, &jsonl_records, jsonl_envelope));
    try std.testing.expectEqual(@as(usize, 1), jsonl_records.items.len);

    const placeholder_run =
        \\{"schema":"CAS-RUN-v1","record":{"schema":"CAS-RER-v1"},"reviewVerdict":{"status":"clean","backendClass":"cas-start-wait","clean":true,"findingCount":0,"baseSha":"base","headSha":"head","targetFingerprint":"fp","reviewThreadId":"thr","reviewTurnId":"turn","findings":[]}}
    ;
    var placeholder_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, placeholder_run, .{});
    defer placeholder_parsed.deinit();
    var placeholder_records: std.ArrayList([]u8) = .empty;
    defer {
        for (placeholder_records.items) |record| std.testing.allocator.free(record);
        placeholder_records.deinit(std.testing.allocator);
    }
    try std.testing.expect(!try collectNestedCasRerRecordsAlloc(std.testing.allocator, &placeholder_records, placeholder_parsed.value.object));
}

test "review import glob skips non-review receipts" {
    try std.testing.expect(reviewImportShouldSkipNormalizeError(true, error.NotReviewReceipt));
    try std.testing.expect(!reviewImportShouldSkipNormalizeError(false, error.NotReviewReceipt));
    try std.testing.expect(!reviewImportShouldSkipNormalizeError(true, error.InvalidReceiptJson));
}

test "CAS inspect record object keeps malformed JSON output parseable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "bad-rer.json", .data = "{bad" });
    const root_abs = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root_abs);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root_abs, "bad-rer.json" });
    defer std.testing.allocator.free(path);

    const validation = try validateCasRerRecordPathAlloc(std.testing.allocator, path);
    defer validation.deinit(std.testing.allocator);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeInspectRecordObject(std.testing.allocator, &out.writer, path, validation, true);
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("recordRaw") != null);
    try std.testing.expect(root.get("record") == null);
}

test "receipt normalizer rejects target-only verdict as proof" {
    const raw =
        \\{"status":"clean","backendClass":"cas-lane","clean":true,"findingCount":0,"failureCode":null,"failureHint":null,"targetFingerprint":"fp_only","reviewThreadId":"thr_target_only","reviewTurnId":"turn_target_only","findings":[]}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "target-only.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
    try std.testing.expect(!normalizedReceiptCommandSucceeded(receipt));
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
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "stored-target-only.json", raw, false, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
    try std.testing.expect(!normalizedReceiptCommandSucceeded(receipt));
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
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "stored-missing-requested.json", raw, false, .{
        .requested_identity = requested,
        .requested_identity_required = true,
    });
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("target_identity_unavailable", receipt.failure_code.?);
}

test "receipt normalizer flags mismatched tuple proof" {
    const raw =
        \\{"demo":"cas-review-session","action":"lane-review","reviewThreadId":"thr_1","reviewTurnId":"turn_1","targetFingerprint":"requested_fp","headSha":"requested_head","baseSha":"requested_base","reviewVerdict":{"status":"clean","backendClass":"cas-lane","clean":true,"findingCount":0,"failureCode":null,"failureHint":null,"baseSha":"other_base","headSha":"requested_head","targetFingerprint":"requested_fp","reviewThreadId":"thr_1","reviewTurnId":"turn_1","findings":[]}}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "mismatch.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
}

test "receipt normalizer rejects incomplete requested identity as proof" {
    const raw =
        \\{"demo":"cas-review-session","action":"lane-review","reviewThreadId":"thr_1","reviewTurnId":"turn_1","targetFingerprint":"requested_fp","headSha":null,"baseSha":null,"reviewVerdict":{"status":"clean","backendClass":"cas-lane","clean":true,"findingCount":0,"failureCode":null,"failureHint":null,"targetFingerprint":"requested_fp","reviewThreadId":"thr_1","reviewTurnId":"turn_1","findings":[]}}
    ;
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

test "receipt normalizer recovers findings from stored review session event log" {
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
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "stored.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("findings", receipt.status);
    try std.testing.expect(!receipt.clean);
    try std.testing.expectEqual(@as(usize, 1), receipt.finding_count);
    try std.testing.expectEqualStrings("cas-start-wait", receipt.backend_class);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("thr_event", receipt.review_thread_id.?);
    try std.testing.expect(std.mem.indexOf(u8, receipt.findings_json, "Keep idempotency keys aligned") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.findings_json, "raw finding body") != null);
}

test "receipt normalizer recovers clean stored receipt from rollout-backed event log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        \\{"type":"session_meta","payload":{"id":"thr_clean"}}
        \\{"type":"event_msg","payload":{"type":"exited_review_mode","review_output":{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"No issues found.","overall_confidence_score":0.88}}}
    ;
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "rollout.jsonl", .data = rollout });
    const rollout_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "rollout.jsonl", std.testing.allocator);
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
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "stored-clean.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expect(receipt.clean);
    try std.testing.expectEqual(@as(usize, 0), receipt.finding_count);
    try std.testing.expectEqualStrings("cas-start-wait", receipt.backend_class);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("thr_clean", receipt.review_thread_id.?);
}

test "receipt normalizer matches requested identity against snake-case stored tuple" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rollout =
        \\{"type":"session_meta","payload":{"id":"thr_snake"}}
        \\{"type":"event_msg","payload":{"type":"exited_review_mode","review_output":{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"No issues found.","overall_confidence_score":0.91}}}
    ;
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "rollout.jsonl", .data = rollout });
    const rollout_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), "rollout.jsonl", std.testing.allocator);
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
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "stored-snake.json", raw, true, .{
        .requested_identity = requested,
        .requested_identity_required = true,
    });
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clean", receipt.status);
    try std.testing.expect(receipt.clean);
    try std.testing.expect(receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("base_snake", receipt.base_sha.?);
    try std.testing.expectEqualStrings("head_snake", receipt.head_sha.?);
    try std.testing.expectEqualStrings("fp_snake", receipt.target_fingerprint.?);
}

test "receipt normalizer bounds broad stored session recovery" {
    const raw =
        \\{"schema_version":3,"cwd":"/tmp","parent_thread_id":"parent","review_thread_id":"thr_broad","review_turn_id":"turn_broad","delivery":"detached","target":{"type":"baseBranch","branch":"main"},"event_log_path":"/tmp/missing.events.ndjson","created_at_unix_s":1,"last_observed_status":"completed","codex_version":"0.140.0","compatibility_verdict":"compatible","transport_kind":"websocket","terminal_review_result_source":null,"terminal_review_result_json":null}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "stored.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("incomplete", receipt.status);
    try std.testing.expect(!receipt.clean);
    try std.testing.expectEqual(@as(usize, 0), receipt.finding_count);
    try std.testing.expectEqualStrings("review_output_missing", receipt.failure_code.?);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
    try std.testing.expect(receipt.review_attempt_exists);
    try std.testing.expect(!receipt.tuple_verdict_exists);
}

test "receipt normalizer rejects non-receipt lane artifact" {
    try std.testing.expectError(
        error.NotReviewReceipt,
        normalizeReceiptFromJsonAlloc(std.testing.allocator, "lane.json", "{\"lane_id\":\"lane_1\",\"status_path\":\"/tmp/status.json\"}", true, .{}),
    );
}

test "receipt normalizer fails closed on missing verdict fields" {
    try std.testing.expectError(
        error.MissingBackendClass,
        normalizeReceiptFromJsonAlloc(std.testing.allocator, "bad.json", "{\"status\":\"clean\",\"clean\":true,\"findingCount\":0}", true, .{}),
    );
    try std.testing.expectError(
        error.MissingCleanFlag,
        normalizeReceiptFromJsonAlloc(std.testing.allocator, "bad.json", "{\"status\":\"clean\",\"backendClass\":\"cas-lane\",\"findingCount\":0}", true, .{}),
    );
}

test "receipt normalizer emits pre-review transport failure for pre-review lane transport loss" {
    const raw =
        \\{"demo":"cas-review-session","action":"lane-review","reviewAttemptPhase":"pre_review_start","reviewAttemptExists":false,"tupleVerdictExists":false,"reviewThreadId":null,"reviewTurnId":null,"baseSha":"base_1","headSha":"head_1","targetFingerprint":"fp_1","failureCode":"pre_review_lane_transport_lost","failureClass":"transport_pre_review","failureHint":"restart lane"}
    ;
    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "pre-review.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pre_review_transport_failure", receipt.status);
    try std.testing.expectEqualStrings("cas-lane", receipt.backend_class);
    try std.testing.expect(!receipt.clean);
    try std.testing.expect(!receipt.review_attempt_exists);
    try std.testing.expectEqualStrings("pre_review_start", receipt.review_attempt_phase);
    try std.testing.expectEqualStrings("pre_review_lane_transport_lost", receipt.failure_code.?);
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

test "start wait verdict builder emits cas-start-wait clean verdict" {
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
        status,
        false,
        true,
        null,
        null,
    )).?;
    defer std.testing.allocator.free(verdict_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, verdict_json, .{});
    defer parsed.deinit();
    const verdict = parsed.value.object;
    try std.testing.expectEqualStrings("clean", verdict.get("status").?.string);
    try std.testing.expectEqualStrings("cas-start-wait", verdict.get("backendClass").?.string);
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
        status,
        false,
        true,
        null,
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
    try std.testing.expectEqualStrings("timeout", reviewVerdictStatus(false, 0, .{ .code = "wait_timed_out", .hint = "" }, "thr"));
    try std.testing.expectEqualStrings("parse_mismatch", reviewVerdictStatus(false, 1, .{ .code = "review_parse_mismatch", .hint = "" }, "thr"));
    try std.testing.expectEqualStrings("review_untrusted_source", reviewVerdictStatus(false, 0, .{ .code = "review_untrusted_source", .hint = "" }, "thr"));
    try std.testing.expectEqualStrings("account_resource_exhausted", reviewVerdictStatus(false, 0, .{ .code = "usageLimitExceeded", .hint = "" }, "thr"));
    try std.testing.expectEqualStrings("review_transport_failure", reviewVerdictStatus(false, 0, .{ .code = "review_transport_lost", .hint = "" }, "thr"));
    try std.testing.expectEqualStrings("clean", reviewVerdictStatus(true, 0, null, "thr"));
    try std.testing.expectEqualStrings("findings", reviewVerdictStatus(false, 2, null, "thr"));
}

test "review verdict tuple terminal status is clean or findings only" {
    try std.testing.expect(reviewVerdictStatusIsTupleTerminal("clean"));
    try std.testing.expect(reviewVerdictStatusIsTupleTerminal("findings"));
    try std.testing.expect(!reviewVerdictStatusIsTupleTerminal("account_resource_exhausted"));
    try std.testing.expect(!reviewVerdictStatusIsTupleTerminal("parse_mismatch"));
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
        .turn_error_message = null,
        .last_turn_has_entered_review_mode = true,
        .last_turn_has_exited_review_mode = false,
        .review_result_available = false,
        .review_result_source = null,
        .review_result_json = null,
        .review_text = try std.testing.allocator.dupe(u8, "quota exceeded before review output"),
        .raw_response_json = try std.testing.allocator.dupe(u8, "{}"),
    };
    defer status.deinit(std.testing.allocator);

    const status_failure = failureInfoForStatus(&status).?;
    try std.testing.expectEqualStrings("account_resource_exhausted", status_failure.code);
    try std.testing.expectEqualStrings("account_resource", failureClassForCode(status_failure.code).?);
    try std.testing.expectEqual(false, retryableSameTupleNowForCode(status_failure.code).?);
    try std.testing.expectEqualStrings("pre_review_start", startReceiptReviewAttemptPhase(null, false, status_failure, null));
    try std.testing.expectEqualStrings("review_terminal", startReceiptReviewAttemptPhase(null, false, status_failure, "thr_1"));
}

test "fallback stderr account limit drives no-attempt verdict" {
    const identity = TargetIdentity{
        .base_sha = "base",
        .head_sha = "head",
        .fingerprint = "fp",
    };
    const fallback = NativeFallbackResult{
        .exit_code = 1,
        .ok = false,
        .stdout_text = null,
        .stderr_text = "rate limit exceeded",
    };
    const verdict_json = (try startWaitReviewVerdictJsonAlloc(
        std.testing.allocator,
        identity,
        null,
        null,
        "",
        "",
        null,
        false,
        true,
        .{ .code = "review_failed", .hint = "native fallback failed" },
        fallback,
    )).?;
    defer std.testing.allocator.free(verdict_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, verdict_json, .{});
    defer parsed.deinit();
    const verdict = parsed.value.object;
    try std.testing.expectEqualStrings("incomplete", verdict.get("status").?.string);
    try std.testing.expectEqualStrings("account_resource_exhausted", verdict.get("failureCode").?.string);
    try std.testing.expect(!verdict.get("clean").?.bool);
    try std.testing.expect(!verdict.get("reviewAttemptExists").?.bool);
    try std.testing.expect(!verdict.get("tupleVerdictExists").?.bool);
}

test "receipt normalizer preserves account resource retry metadata" {
    const raw =
        \\{"demo":"cas-review-session","action":"start","reviewThreadId":"thr_1","reviewTurnId":"turn_1","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.jsonl","baseSha":"base_a","headSha":"head_a","targetFingerprint":"fp_a","failureCode":"review_failed","fallbackErrorText":"quota exceeded","reviewVerdict":{"status":"incomplete","backendClass":"cas-start-wait","clean":false,"findingCount":0,"failureCode":"review_failed","failureHint":"failed","baseSha":"base_a","headSha":"head_a","targetFingerprint":"fp_a","reviewThreadId":"thr_1","reviewTurnId":"turn_1","recordPath":"/tmp/record.json","eventLogPath":"/tmp/events.jsonl","findings":[]}}
    ;
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
        .imported_from_receipt = false,
        .tuple_current_at_record_time = true,
        .created_at = "unix-ns:1",
        .updated_at = "unix-ns:1",
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

test "stored receipt event log account limit wins over missing output" {
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

    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "stored-account.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("account_resource_exhausted", receipt.status);
    try std.testing.expectEqualStrings("account_resource_exhausted", receipt.failure_code.?);
    try std.testing.expectEqualStrings("account_resource", receipt.failure_class.?);
    try std.testing.expectEqual(false, receipt.retryable_same_tuple_now.?);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
}

test "stored account exhaustion with tuple fields is not a tuple verdict" {
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

    const receipt = try normalizeReceiptFromJsonAlloc(std.testing.allocator, "stored-account-proof.json", raw, true, .{});
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("account_resource_exhausted", receipt.status);
    try std.testing.expectEqualStrings("account_resource_exhausted", receipt.failure_code.?);
    try std.testing.expect(!receipt.tuple_verdict_exists);
    try std.testing.expectEqualStrings("review_terminal", receipt.review_attempt_phase);
}

test "pre-review lane transport receipt is attempt-free and tuple-bound" {
    const lane = LaneRecord{
        .lane_id = "lane_test",
        .cwd = "/tmp/repo",
        .created_at_unix_s = 1,
        .last_used_at_unix_s = 1,
        .status = "running",
        .review_count = 7,
        .codex_version = "codex-test",
        .resolved_codex_path = "/usr/bin/codex",
        .managed_server_pid = 12345,
        .managed_server_listen_url = "ws://127.0.0.1:12345",
        .hook_policy = "inherit",
        .last_review_thread_id = "prior-review-thread",
    };
    const target = TargetRecord{ .type = "baseBranch", .branch = "main" };
    const identity = TargetIdentity{
        .head_sha = "head123",
        .base_sha = "base123",
        .fingerprint = "target-fingerprint",
    };
    const payload = try buildPreReviewLaneTransportLostJsonAlloc(
        std.testing.allocator,
        "lane-review",
        "review/start",
        "ConnectionResetByPeer",
        "restart the lane",
        lane,
        "/tmp/lane.json",
        target,
        identity,
        null,
        false,
    );
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("lane-review", root.get("action").?.string);
    try std.testing.expectEqualStrings("pre_review_lane_transport_lost", root.get("failureCode").?.string);
    try std.testing.expectEqualStrings("transport_pre_review", root.get("failureClass").?.string);
    try std.testing.expectEqualStrings("pre_review_start", root.get("reviewAttemptPhase").?.string);
    try std.testing.expect(!root.get("reviewAttemptExists").?.bool);
    try std.testing.expect(!root.get("tupleVerdictExists").?.bool);
    switch (root.get("reviewThreadId").?) {
        .null => {},
        else => return error.ExpectedNull,
    }
    switch (root.get("reviewTurnId").?) {
        .null => {},
        else => return error.ExpectedNull,
    }
    try std.testing.expectEqualStrings("lane_test", root.get("laneId").?.string);
    try std.testing.expectEqual(@as(i64, 12345), root.get("managedServerPid").?.integer);
    try std.testing.expectEqualStrings("ws://127.0.0.1:12345", root.get("managedServerListenUrl").?.string);
    try std.testing.expectEqualStrings("unknown", root.get("serverExitStatus").?.string);
    switch (root.get("stderrLogPath").?) {
        .null => {},
        else => return error.ExpectedNull,
    }
    try std.testing.expectEqual(@as(i64, 0), root.get("reviewCount").?.integer);
    switch (root.get("lastReviewThreadId").?) {
        .null => {},
        else => return error.ExpectedNull,
    }
    try std.testing.expectEqualStrings("base123", root.get("baseSha").?.string);
    try std.testing.expectEqualStrings("head123", root.get("headSha").?.string);
    try std.testing.expectEqualStrings("target-fingerprint", root.get("targetFingerprint").?.string);
    const verdict = root.get("reviewVerdict").?.object;
    try std.testing.expectEqualStrings("pre_review_transport_failure", verdict.get("status").?.string);
    try std.testing.expectEqualStrings("cas-lane", verdict.get("backendClass").?.string);
    try std.testing.expectEqualStrings("pre_review_lane_transport_lost", verdict.get("failureCode").?.string);
    try std.testing.expect(!verdict.get("clean").?.bool);
    try std.testing.expectEqual(@as(i64, 0), verdict.get("findingCount").?.integer);
    switch (verdict.get("reviewThreadId").?) {
        .null => {},
        else => return error.ExpectedNull,
    }
}

test "pre-review lane transport keeps live server exit status nullable" {
    try std.testing.expectEqual(@as(?[]const u8, null), preReviewLaneServerExitStatus(true));
    try std.testing.expectEqualStrings("unknown", preReviewLaneServerExitStatus(false).?);
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
    try std.testing.expectEqualStrings("normalized_verdict", root.get("reviewAttemptPhase").?.string);
    try std.testing.expect(root.get("reviewAttemptExists").?.bool);
    try std.testing.expect(root.get("tupleVerdictExists").?.bool);
    try std.testing.expectEqualStrings("cas-lane", root.get("backendClass").?.string);
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
        "cas-lane",
        true,
        0,
        null,
        identity,
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
        "cas-lane",
        false,
        0,
        .{ .code = "wait_timed_out", .hint = "retry wait" },
        identity,
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

    const lane_argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "review",
        "--lane-id",
        "lane_1",
        "--base",
        "main",
        "--review-lock-override",
        "stale owner",
    };
    var lane = try parseArgs(std.testing.allocator, &lane_argv);
    defer lane.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("stale owner", lane.review_lock_override_reason.?);

    const smoke_argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke",
        "--cwd",
        "/repo",
        "--base",
        "main",
        "--review-lock-override",
        "cas-smoke-suite:1",
    };
    var smoke = try parseArgs(std.testing.allocator, &smoke_argv);
    defer smoke.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cas-smoke-suite:1", smoke.review_lock_override_reason.?);

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

    const lane_argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "review",
        "--lane-id",
        "lane_1",
        "--base",
        "main",
        "--fresh-attempt",
        "run 3",
    };
    var lane = try parseArgs(std.testing.allocator, &lane_argv);
    defer lane.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("run 3", lane.fresh_attempt_reason.?);

    const smoke_argv = [_][]const u8{
        "cas_review_session",
        "lane",
        "smoke",
        "--cwd",
        "/repo",
        "--base",
        "main",
        "--fresh-attempt",
        "not allowed",
    };
    try std.testing.expectError(error.FreshAttemptUnsupportedAction, parseArgs(std.testing.allocator, &smoke_argv));
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

test "accountPrincipalFromJsonAlloc treats type plan fallback as reduced" {
    const stable = try accountPrincipalFromJsonAlloc(
        std.testing.allocator,
        "{\"account\":{\"id\":\"acct_123\",\"type\":\"chatgpt\",\"planType\":\"pro\"}}",
    );
    defer stable.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, stable.fingerprint, "acct:"));
    try std.testing.expect(!stable.reduced_protection);

    const fallback = try accountPrincipalFromJsonAlloc(
        std.testing.allocator,
        "{\"account\":{\"type\":\"chatgpt\",\"planType\":\"pro\"}}",
    );
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, fallback.fingerprint, "acct:"));
    try std.testing.expect(fallback.reduced_protection);
    try std.testing.expect(!std.mem.eql(u8, stable.fingerprint, fallback.fingerprint));
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

    try std.testing.expectEqualStrings("sha256:b08f2fe9f5de06f5cf9627b670f3e7135082dcab983727ddb01db9aa89061756", hash_a);
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
    const bound_lock = makeReviewTupleLock(bound_hash, bound_tuple, "starting_lane", 1, null, null);
    try std.testing.expect(try reviewTupleLockWorkflowBindingValidAlloc(std.testing.allocator, bound_lock));
    var tampered_lock = bound_lock;
    tampered_lock.workflowBinding = other_binding;
    try std.testing.expect(!try reviewTupleLockWorkflowBindingValidAlloc(std.testing.allocator, tampered_lock));
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
        .state = "waiting",
        .reviewThreadId = "thr_1",
        .createdAtUnixS = now_s,
        .updatedAtUnixS = now_s,
        .expiresAtUnixS = now_s + 60,
        .ownerPid = 1,
    };
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockAction("lane-review", active, now_s, null, null));
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockAction("run", active, now_s, null, null));
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockActionWithProbe("run", active, now_s, null, null, true));

    var transport_lost = active;
    transport_lost.lastFailureCode = "review_transport_lost";
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockActionWithProbe("run", transport_lost, now_s, null, null, false));
    try std.testing.expectEqual(ReviewTupleLockAction.auto_replace_dead_transport, reviewTupleLockActionWithProbe("run", transport_lost, now_s, null, null, true));

    var timed_out_smoke = active;
    timed_out_smoke.lastFailureCode = "wait_timed_out";
    try std.testing.expectEqualStrings("timeout", tupleLockFallbackVerdictStatus(timed_out_smoke));
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockActionWithProbe("run", timed_out_smoke, now_s, null, null, false));
    try std.testing.expectEqual(ReviewTupleLockAction.auto_replace_dead_transport, reviewTupleLockActionWithProbe("run", timed_out_smoke, now_s, null, null, true));
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockAction("lane-review", timed_out_smoke, now_s, "cas-smoke-suite:1", null));
    try std.testing.expectEqual(ReviewTupleLockAction.takeover_with_override, reviewTupleLockAction("lane-smoke", timed_out_smoke, now_s, "cas-smoke-suite:1", null));
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockAction("lane-review", active, now_s, "cas-smoke-suite:2", "run 2"));
    try std.testing.expectEqual(ReviewTupleLockAction.return_existing, reviewTupleLockAction("lane-smoke", active, now_s, "cas-smoke-suite:2", "run 2"));
    try std.testing.expectEqualStrings("incomplete", tupleLockFallbackVerdictStatus(active));

    var active_smoke_owned = active;
    active_smoke_owned.overrideReason = "cas-smoke-suite:1";
    try std.testing.expectEqual(ReviewTupleLockAction.takeover_with_override, reviewTupleLockAction("lane-smoke", active_smoke_owned, now_s, "cas-smoke-suite:2", null));

    var terminal = active;
    terminal.state = "terminal";
    try std.testing.expectEqual(ReviewTupleLockAction.normalize_existing, reviewTupleLockAction("lane-review", terminal, now_s, null, null));
    try std.testing.expectEqual(ReviewTupleLockAction.normalize_existing, reviewTupleLockAction("run", terminal, now_s, null, null));
    try std.testing.expectEqual(ReviewTupleLockAction.fresh_after_terminal, reviewTupleLockAction("lane-review", terminal, now_s, null, "run 2"));
    try std.testing.expectEqual(ReviewTupleLockAction.fresh_after_terminal, reviewTupleLockAction("run", terminal, now_s, null, "run 2"));
    try std.testing.expectEqual(ReviewTupleLockAction.fresh_after_terminal, reviewTupleLockAction("start", terminal, now_s, null, "run 2"));
    try std.testing.expectEqual(ReviewTupleLockAction.normalize_existing, reviewTupleLockAction("lane-review", terminal, now_s, "cas-smoke-suite:1", null));
    try std.testing.expectEqual(ReviewTupleLockAction.takeover_with_override, reviewTupleLockAction("lane-smoke", terminal, now_s, "cas-smoke-suite:1", "run 2"));
    terminal.expiresAtUnixS = now_s - 1;
    try std.testing.expectEqual(ReviewTupleLockAction.normalize_existing, reviewTupleLockAction("lane-review", terminal, now_s, null, null));
    try std.testing.expectEqual(ReviewTupleLockAction.fresh_after_terminal, reviewTupleLockAction("lane-review", terminal, now_s, null, "run 3"));

    var exhausted = active;
    exhausted.state = "account_resource_exhausted";
    try std.testing.expectEqual(ReviewTupleLockAction.block_account_resource, reviewTupleLockAction("lane-review", exhausted, now_s, null, "run 2"));
    try std.testing.expectEqual(ReviewTupleLockAction.takeover_with_override, reviewTupleLockAction("lane-review", exhausted, now_s, "manual reset", null));
    try std.testing.expectEqual(ReviewTupleLockAction.block_account_resource, reviewTupleLockAction("lane-smoke", exhausted, now_s, "cas-smoke-suite:1", null));
    exhausted.expiresAtUnixS = now_s - 1;
    try std.testing.expectEqual(ReviewTupleLockAction.block_account_resource, reviewTupleLockAction("lane-review", exhausted, now_s, null, "run 2"));

    var stale = active;
    stale.expiresAtUnixS = now_s - 1;
    try std.testing.expectEqual(ReviewTupleLockAction.block_stale, reviewTupleLockAction("lane-review", stale, now_s, null, null));
    try std.testing.expectEqual(ReviewTupleLockAction.takeover_with_override, reviewTupleLockAction("lane-review", stale, now_s, "stale owner", null));
    try std.testing.expectEqualStrings("blocked_stale_lock", reviewBrokerActionForBlockedLock(.block_stale));

    var smoke_suite_lock = active;
    smoke_suite_lock.overrideReason = "cas-smoke-suite:1";
    try std.testing.expect(!smokeChildTupleLockReleasable(smoke_suite_lock, "thr_1"));
    smoke_suite_lock.state = "terminal";
    try std.testing.expect(smokeChildTupleLockReleasable(smoke_suite_lock, "thr_1"));
    try std.testing.expect(!smokeChildTupleLockReleasable(smoke_suite_lock, "other_thread"));
    smoke_suite_lock.overrideReason = "manual";
    try std.testing.expect(!smokeChildTupleLockReleasable(smoke_suite_lock, "thr_1"));
    smoke_suite_lock.overrideReason = "cas-smoke-suite:1";
    smoke_suite_lock.lastFailureCode = "wait_timed_out";
    try std.testing.expect(!smokeChildTupleLockReleasable(smoke_suite_lock, "thr_1"));
    smoke_suite_lock.lastFailureCode = null;
    smoke_suite_lock.state = "account_resource_exhausted";
    try std.testing.expect(!smokeChildTupleLockReleasable(smoke_suite_lock, "thr_1"));
}

test "review tuple acquire does not reuse diagnostic terminal receipts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const reusable_receipt =
        \\{"reviewVerdict":{"status":"findings","backendClass":"cas-start-wait","clean":false,"findingCount":1,"baseSha":"base","headSha":"head","targetFingerprint":"fp","reviewThreadId":"thr","reviewTurnId":"turn","accountFingerprint":"acct:a","accountFingerprintReducedProtection":false,"principalStrength":"strong","findings":[{"title":"issue"}]}}
    ;
    const diagnostic_receipt =
        \\{"reviewVerdict":{"status":"clean","backendClass":"cas-native-fallback","clean":true,"findingCount":0,"baseSha":"base","headSha":"head","targetFingerprint":"fp","reviewThreadId":"thr","reviewTurnId":"turn","accountFingerprint":"acct:a","accountFingerprintReducedProtection":true,"principalStrength":"reduced","findings":[]}}
    ;
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
        .state = "terminal",
        .reviewThreadId = "thr",
        .reviewTurnId = "turn",
        .recordPath = reusable_path,
        .createdAtUnixS = now_s,
        .updatedAtUnixS = now_s,
        .expiresAtUnixS = now_s + 60,
        .ownerPid = 1,
    };
    try std.testing.expectEqual(ReviewTupleLockAction.normalize_existing, reviewTupleLockActionForAcquire(std.testing.allocator, "run", lock, now_s, null, null, target_identity));

    lock.recordPath = diagnostic_path;
    try std.testing.expectEqual(ReviewTupleLockAction.fresh_after_terminal, reviewTupleLockActionForAcquire(std.testing.allocator, "run", lock, now_s, null, null, target_identity));
    try std.testing.expectEqual(ReviewTupleLockAction.fresh_after_terminal, reviewTupleLockActionForAcquire(std.testing.allocator, "lane-review", lock, now_s, null, null, target_identity));
    try std.testing.expectEqual(ReviewTupleLockAction.normalize_existing, reviewTupleLockActionForAcquire(std.testing.allocator, "lane-smoke", lock, now_s, null, null, target_identity));
}

test "review tuple lock write and load roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/lock.json", .{tmp_root});
    defer std.testing.allocator.free(path);

    const lock = ReviewTupleLock{
        .tupleHash = "sha256:roundtrip",
        .repoRealpath = "/repo",
        .baseSha = "base",
        .headSha = "head",
        .targetFingerprint = "fp",
        .resolvedCodexPath = "/bin/codex",
        .resolvedCodexVersion = "codex 0.1.0",
        .accountFingerprint = "acct:a",
        .state = "review_started",
        .reviewThreadId = "thr_1",
        .reviewTurnId = "turn_1",
        .recordPath = "/repo/receipt.json",
        .eventLogPath = "/repo/events.ndjson",
        .createdAtUnixS = 1,
        .updatedAtUnixS = 2,
        .expiresAtUnixS = 3,
        .ownerPid = 4,
    };
    try writeReviewTupleLock(std.testing.allocator, path, lock);
    var loaded = (try loadReviewTupleLock(std.testing.allocator, path)).?;
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(review_tuple_lock_version, loaded.record.lockVersion);
    try std.testing.expectEqualStrings("review_started", loaded.record.state);
    try std.testing.expectEqualStrings("thr_1", loaded.record.reviewThreadId.?);
    try std.testing.expectEqualStrings("acct:a", loaded.record.accountFingerprint);
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
        .state = "starting_lane",
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

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/review_sessions/locks/abc.json", .{tmp_root});
    defer allocator.free(lock_path);
    const lock = ReviewTupleLock{
        .tupleHash = "sha256:abc",
        .repoRealpath = "/repo",
        .baseSha = "base",
        .headSha = "head",
        .targetFingerprint = "fp",
        .resolvedCodexPath = "/bin/codex",
        .resolvedCodexVersion = "codex 0.1.0",
        .accountFingerprint = "acct:test",
        .codexThreadId = "thread-clean",
        .state = "waiting",
        .reviewThreadId = "thr_old",
        .reviewTurnId = "turn_old",
        .createdAtUnixS = 1,
        .updatedAtUnixS = 1,
        .expiresAtUnixS = 999,
        .ownerPid = 1,
    };
    try writeReviewTupleLock(allocator, lock_path, lock);
    try std.testing.expect(durable_store.fileExists(lock_path));

    updateReviewTupleLockBestEffort(allocator, lock_path, lock, "terminal", null, "thr_clean", "turn_clean", record_path, event_path);
    try std.testing.expect(durable_store.fileExists(lock_path));
    var updated = (try loadReviewTupleLock(allocator, lock_path)).?;
    defer updated.deinit(allocator);
    try std.testing.expectEqualStrings("terminal", updated.record.state);
    try std.testing.expectEqualStrings(record_path, updated.record.recordPath.?);
}

test "review tuple lock rewrite claim is exclusive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/lock.json", .{tmp_root});
    defer std.testing.allocator.free(path);

    const claim_path = try claimReviewTupleLockRewriteExclusive(std.testing.allocator, path);
    defer std.testing.allocator.free(claim_path);
    defer deleteReviewTupleLockRewriteClaimBestEffort(claim_path);

    try std.testing.expectError(error.PathAlreadyExists, claimReviewTupleLockRewriteExclusive(std.testing.allocator, path));
    deleteReviewTupleLockRewriteClaimBestEffort(claim_path);
    const reclaimed_path = try claimReviewTupleLockRewriteExclusive(std.testing.allocator, path);
    defer std.testing.allocator.free(reclaimed_path);
    defer deleteReviewTupleLockRewriteClaimBestEffort(reclaimed_path);
}

test "review tuple lock rewrite claim expires stale sidecar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/lock.json", .{tmp_root});
    defer std.testing.allocator.free(path);
    const claim_path = try reviewTupleLockRewriteClaimPathAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(claim_path);
    defer deleteReviewTupleLockRewriteClaimBestEffort(claim_path);

    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = claim_path,
        .data = "{\"ownerPid\":1,\"createdAtUnixS\":1}\n",
    });
    const reclaimed_path = try claimReviewTupleLockRewriteExclusive(std.testing.allocator, path);
    defer std.testing.allocator.free(reclaimed_path);
    try std.testing.expectEqualStrings(claim_path, reclaimed_path);
}
