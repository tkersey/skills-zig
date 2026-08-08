const std = @import("std");
const core_cli = @import("core_cli");
const core_json = @import("core_json");
const core_path = @import("core_path");
const durable_store = @import("durable_store");
const trace_core = @import("trace_core");
const app_meta = @import("app_meta");
const cas_client = @import("cas_proxy_client.zig");
const cas_websocket = @import("cas_websocket_transport.zig");
const canonical_trace = trace_core;

const Version = core_cli.normalizeVersion(app_meta.version);
const MaxInputBytes = 8 * 1024 * 1024;
const MaxSchemaBytes = 64 * 1024 * 1024;
const MaxInquiryForks: u64 = 4;
const MaxInquiryLanes: usize = 16;
const MaxInquiryTokens: u64 = 1_000_000;
const MaxInquiryTimeoutMs: u64 = 2_700_000;
const MaxThreadHistoryPages: usize = 1024;
const ThreadHistoryPageLimit: u32 = 100;
const AppServerContractId = "codex-app-server-0.146.0";

const HelpSurface = core_cli.HelpSurface{
    .executable_name = "cas_session_inquiry",
    .help_text = UsageText,
};

const UsageText =
    \\cas_session_inquiry
    \\
    \\Safe Codex app-server experiment controller for historical decision replay.
    \\
    \\Usage:
    \\  cas_session_inquiry preflight [--cwd PATH] [--transport auto|managed-ws] [--codex-path PATH] [--code-mode-host URL] [--json]
    \\  cas_session_inquiry run --capsule FILE --capsule-definition FILE --capsule-validation FILE --plan FILE --plan-definition FILE --plan-validation FILE --receipt-dir PATH [--json]
    \\  cas_session_inquiry start --capsule FILE --capsule-definition FILE --capsule-validation FILE --plan FILE --plan-definition FILE --plan-validation FILE --receipt-dir PATH [--json]
    \\  cas_session_inquiry status --inquiry-id ID [--json]
    \\  cas_session_inquiry wait --inquiry-id ID [--timeout-ms N] [--json]
    \\  cas_session_inquiry interrupt --inquiry-id ID [--json]
    \\  cas_session_inquiry receipt --glob GLOB [--format table|json] [--summary] [--json]
    \\  cas_session_inquiry cleanup --inquiry-id ID [--json]
    \\
    \\Common flags:
    \\  --capsule FILE
    \\  --capsule-definition FILE
    \\  --capsule-validation FILE
    \\  --plan FILE
    \\  --plan-definition FILE
    \\  --plan-validation FILE
    \\  --receipt-dir PATH
    \\  --inquiry-id ID
    \\  --cwd PATH
    \\  --model ID
    \\  --model-provider ID
    \\  --service-tier TIER|null
    \\  --permissions PROFILE
    \\  --sandbox read-only
    \\  --hooks inherit|off|require-observed
    \\  --timeout-ms N
    \\  --max-total-tokens N
    \\  --transport auto|managed-ws
    \\  --codex-path PATH
    \\  --code-mode-host ws://LOOPBACK|wss://HOST
    \\  --store-root DIR
    \\  --json
    \\  --verdict-only
    \\
    \\ID lookups are store-scoped. Use --cwd, --store-root, or a recorded
    \\state_ref when checking from outside the original repo/workspace.
    \\
    \\Unsafe modes are intentionally not exposed: workspace-write, full-access,
    \\approval grants, network enablement, and thread/shellCommand.
;

const Command = enum {
    preflight,
    run,
    start,
    status,
    wait,
    interrupt,
    receipt,
    cleanup,
};

const FailureCode = enum {
    capsule_invalid,
    plan_invalid,
    source_not_found,
    source_stale,
    source_turn_digest_mismatch,
    thread_history_mode_unsupported,
    decision_anchor_unavailable,
    fork_unsupported,
    fork_failed,
    lineage_mismatch,
    rollback_unsupported,
    rollback_failed,
    anchor_digest_mismatch,
    permission_profile_unavailable,
    permission_mismatch,
    workspace_mismatch,
    model_unavailable,
    turn_start_failed,
    fork_timeout,
    fork_interrupted,
    approval_requested,
    tool_policy_violation,
    answer_parse_failed,
    hindsight_label_mismatch,
    receipt_invalid,
    budget_exhausted,
    inquiry_transport_lost,
    cleanup_failed,
    codex_incompatible,
    schema_unavailable,

    fn asString(self: FailureCode) []const u8 {
        return @tagName(self);
    }
};

const InquiryState = enum {
    created,
    preflight,
    source_verified,
    forking,
    anchoring,
    turn_running,
    collecting,
    completed,
    partially_completed,
    interrupted,
    failed,
    cleanup_pending,
    closed,
};

const Options = struct {
    command: Command,
    capsule_path: ?[]const u8 = null,
    capsule_definition_path: ?[]const u8 = null,
    capsule_validation_path: ?[]const u8 = null,
    plan_path: ?[]const u8 = null,
    plan_definition_path: ?[]const u8 = null,
    plan_validation_path: ?[]const u8 = null,
    receipt_dir: ?[]const u8 = null,
    inquiry_id: ?[]const u8 = null,
    cwd: []const u8 = ".",
    model: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    permissions: []const u8 = "read-only",
    sandbox: []const u8 = "read-only",
    hooks: []const u8 = "inherit",
    timeout_ms: u64 = 600_000,
    max_total_tokens: ?u64 = null,
    transport: []const u8 = "auto",
    json: bool = false,
    verdict_only: bool = false,
    receipt_glob: ?[]const u8 = null,
    receipt_format: []const u8 = "table",
    receipt_summary: bool = false,
    codex_path: []const u8 = "codex",
    code_mode_host: ?[]const u8 = null,
    store_root: ?[]const u8 = null,
    home: []const u8 = "",
    path_env: []const u8 = "",
    capsule_bytes: ?[]const u8 = null,
    capsule_validation_bytes: ?[]const u8 = null,
    plan_bytes: ?[]const u8 = null,
    plan_validation_bytes: ?[]const u8 = null,
};

const ValidatedInput = struct {
    input: []const u8,
    receipt: []const u8,
    definition_digest: []const u8,

    fn deinit(self: *ValidatedInput, allocator: std.mem.Allocator) void {
        allocator.free(self.input);
        allocator.free(self.receipt);
        allocator.free(self.definition_digest);
        self.* = undefined;
    }
};

const Dcp = struct {
    packet_id: []const u8,
    source_episode_id: ?[]const u8,
    source_thread_id: ?[]const u8,
    source_rollout_path: ?[]const u8,
    source_turn_digest: []const u8,
    source_model: ?[]const u8,
    source_model_provider: ?[]const u8,
    source_codex_version: ?[]const u8,
    reconstructability: []const u8,
    total_turns: u64,
    decision_turn_index: u64,
    first_outcome_turn_index: ?u64,
    anchors: [3]Anchor,
};

const AnchorName = enum {
    pre_decision,
    post_decision_pre_outcome,
    outcome_aware,

    fn asString(self: AnchorName) []const u8 {
        return @tagName(self);
    }
};

const Anchor = struct {
    name: AnchorName,
    available: bool,
    keep_through_turn_index: u64 = 0,
    drop_last_n_turns: u64 = 0,
    anchor_digest: ?[]const u8 = null,
};

const Rip = struct {
    plan_id: []const u8,
    inquiry_id: []const u8,
    objective: []const u8,
    model_policy: []const u8,
    workspace_policy: []const u8,
    permission_read_only: bool,
    permission_network: bool,
    max_forks: u64,
    max_turns_per_fork: u64,
    max_total_tokens: u64,
    timeout_ms: u64,
    lanes: []Lane,
};

const Lane = struct {
    lane_id: []const u8,
    temporal_horizon: []const u8,
    inquiry_mode: []const u8,
    fork_count: u64,
    prompt_template: []const u8,
    evidence_allowed_count: usize,
    evidence_withheld_count: usize,
};

const SchemaCapabilities = struct {
    thread_fork: bool,
    thread_rollback: bool,
    thread_start: bool,
    thread_read: bool,
    thread_turns_list: bool,
    turn_start: bool,
    turn_interrupt: bool,
    thread_archive: bool,
    thread_delete: bool,
    ephemeral_fork_field: bool,
    fork_permissions_field: bool,
    fork_sandbox_field: bool,
    fork_path_field: bool,
    fork_last_turn_id_field: bool,
    fork_before_turn_id_field: bool,
    fork_exclude_turns_field: bool,
    fork_lineage_field: bool,
    rollback_num_turns: bool,
    turns_list_cursor_field: bool,
    turns_list_limit_field: bool,
    turns_list_sort_direction_field: bool,
    turns_list_items_view_field: bool,
    turns_list_data_field: bool,
    turns_list_next_cursor_field: bool,
    shell_command_present: bool,

    fn exactAnchorSupported(self: SchemaCapabilities) bool {
        return self.paginatedAnchorSupported() and
            (self.thread_read or self.thread_turns_list) and
            self.ephemeral_fork_field;
    }

    fn paginatedAnchorSupported(self: SchemaCapabilities) bool {
        return self.thread_fork and self.thread_read and self.thread_turns_list and
            self.fork_last_turn_id_field and self.fork_before_turn_id_field and
            self.fork_exclude_turns_field and self.fork_lineage_field and
            self.turns_list_cursor_field and self.turns_list_limit_field and
            self.turns_list_sort_direction_field and self.turns_list_items_view_field and
            self.turns_list_data_field and self.turns_list_next_cursor_field;
    }

    fn rolloutTranscriptSupported(self: SchemaCapabilities) bool {
        return self.thread_start and self.turn_start and (self.thread_read or self.thread_turns_list);
    }
};

fn zeroCapabilities() SchemaCapabilities {
    return .{
        .thread_fork = false,
        .thread_rollback = false,
        .thread_start = false,
        .thread_read = false,
        .thread_turns_list = false,
        .turn_start = false,
        .turn_interrupt = false,
        .thread_archive = false,
        .thread_delete = false,
        .ephemeral_fork_field = false,
        .fork_permissions_field = false,
        .fork_sandbox_field = false,
        .fork_path_field = false,
        .fork_last_turn_id_field = false,
        .fork_before_turn_id_field = false,
        .fork_exclude_turns_field = false,
        .fork_lineage_field = false,
        .rollback_num_turns = false,
        .turns_list_cursor_field = false,
        .turns_list_limit_field = false,
        .turns_list_sort_direction_field = false,
        .turns_list_items_view_field = false,
        .turns_list_data_field = false,
        .turns_list_next_cursor_field = false,
        .shell_command_present = false,
    };
}

const PreflightResult = struct {
    compatibility_verdict: []const u8,
    codex_path: []const u8,
    codex_version: []const u8,
    schema_fingerprint: []const u8,
    cache_dir: []const u8,
    selected_transport: []const u8,
    capabilities: SchemaCapabilities,
    thread_fork_replay: bool,
    paginated_thread_fork: bool,
    rollout_transcript_replay: bool,
    code_mode_host_redacted: ?[]const u8,
    code_mode_host_digest: ?[]const u8,
    missing: []const []const u8,
    inquiry_allowed: bool,
};

const SharedSessionInquiryPreflight = struct {
    overall_compatible: bool,
    route_neutral_compatible: bool,
    codex_path: []u8,
    codex_version: []u8,
    experimental_path: []u8,
    cache_dir: []u8,
    stable_schema_digest: []u8,
    experimental_schema_digest: []u8,
    selected_transport: []u8,
    paginated_fork_passed: bool,
    ephemeral_fork_passed: bool,
    paginated_inquiry_passed: bool,
    code_mode_host_redacted: ?[]u8,
    code_mode_host_digest: ?[]u8,

    fn deinit(self: *SharedSessionInquiryPreflight, allocator: std.mem.Allocator) void {
        allocator.free(self.codex_path);
        allocator.free(self.codex_version);
        allocator.free(self.experimental_path);
        allocator.free(self.cache_dir);
        allocator.free(self.stable_schema_digest);
        allocator.free(self.experimental_schema_digest);
        allocator.free(self.selected_transport);
        if (self.code_mode_host_redacted) |value| allocator.free(value);
        if (self.code_mode_host_digest) |value| allocator.free(value);
        self.* = undefined;
    }
};

const GateResult = struct {
    valid: bool,
    failure_code: ?FailureCode,
    hint: []const u8,
};

const RunOutput = struct {
    inquiry_id: []const u8,
    state: []const u8,
    receipt_dir: []const u8,
    state_ref: []const u8,
    events_ref: []const u8,
    summary_ref: []const u8,
    failure_code: []const u8,
    failure_hint: []const u8,
};

const TurnDigest = struct {
    count: u64,
    digest: []const u8,
};

const TurnObservation = struct {
    status: []const u8 = "inProgress",
    final_text: []const u8 = "",
    terminal: bool = false,
    blocking_event: bool = false,
};

const FiaAnswer = struct {
    reconstructed_decision: []const u8,
    selected_route: []const u8,
    rejected_routes: []const []const u8,
    evidence_refs: []const []const u8,
    assumptions: []const []const u8,
    alternatives: []const []const u8,
    route_flip_conditions: []const []const u8,
    uncertainty: []const u8,
    hindsight_available: bool,
    unsupported_claims: []const []const u8,
};

const LaneExecutionResult = struct {
    receipt_valid: bool,
    retryable: bool,
};

const ForkPolicyProof = struct {
    ephemeral: bool = false,
    read_only: bool = false,
    approval_never: bool = false,

    fn valid(self: ForkPolicyProof) bool {
        return self.ephemeral and self.read_only and self.approval_never;
    }

    fn safe(self: ForkPolicyProof) bool {
        return self.read_only and self.approval_never;
    }
};

const SourceLineageMode = enum {
    thread_fork,
    rollout_transcript,

    fn asString(self: SourceLineageMode) []const u8 {
        return @tagName(self);
    }
};

fn lineageMode(dcp: Dcp) SourceLineageMode {
    return if (dcp.source_thread_id == null) .rollout_transcript else .thread_fork;
}

const LaneHandle = struct {
    inquiry_id: []const u8,
    lane_id: []const u8,
    inquiry_mode: []const u8,
    temporal_horizon: []const u8,
    question: []const u8,
    ordinal: u64,
    source_thread_id: []const u8,
    fork_thread_id: []const u8,
    forked_from_id: []const u8,
    turn_id: []const u8,
    client_user_message_id: []const u8,
    lane_events: []const u8,
    lane_final: []const u8,
    lane_receipt: []const u8,
    lane_state_ref: []const u8,
    workspace_cwd: []const u8,
    model: []const u8,
    model_provider: []const u8,
    service_tier: []const u8,
    codex_version: []const u8,
    schema_fingerprint: []const u8,
    turns_before: u64,
    turns_dropped: u64,
    turns_after: u64,
    anchor_digest_expected: []const u8,
    anchor_digest_observed: []const u8,
    expected_hindsight: bool,
    policy_request_count_before: u64,
    fork_policy: ForkPolicyProof,
    fork_cleaned: bool = false,
};

const DetachedRecord = struct {
    inquiry_id: []const u8,
    state: []const u8,
    receipt_dir: []const u8,
    state_ref: []const u8,
    events_ref: []const u8,
    summary_ref: []const u8,
    cwd: []const u8,
    codex_path: []const u8,
    listen_url: []const u8,
    managed_server_pid: u64,
    codex_version: []const u8,
    schema_fingerprint: []const u8,
    code_mode_host_redacted: []const u8,
    code_mode_host_digest: []const u8,
    failure_code: []const u8,
    failure_hint: []const u8,
};

const ThreadHistoryMode = enum {
    legacy,
    paginated,
};

const ThreadHistorySnapshot = struct {
    mode: ThreadHistoryMode,
    digest: TurnDigest,
    turn_ids: []const []const u8,
    completed_boundaries: []const bool,

    fn deinit(self: ThreadHistorySnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.digest.digest);
        for (self.turn_ids) |turn_id| allocator.free(turn_id);
        allocator.free(self.turn_ids);
        allocator.free(self.completed_boundaries);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (try core_cli.handleDefaultHelpAndVersionSurface(argv, HelpSurface, Version)) return;
    var options = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    options.home = init.environ_map.get("HOME") orelse "";
    options.path_env = init.environ_map.get("PATH") orelse "";
    configured_store_root_override = options.store_root orelse init.environ_map.get("CAS_STORE_ROOT");
    configured_store_cwd = options.cwd;

    switch (options.command) {
        .preflight => try cmdPreflight(allocator, init.io, options),
        .run => try cmdRun(allocator, init.io, options, false),
        .start => try cmdRun(allocator, init.io, options, true),
        .status => try cmdStatus(allocator, options),
        .wait => try cmdWait(allocator, options),
        .interrupt => try cmdInterrupt(allocator, options),
        .receipt => try cmdReceipt(allocator, options),
        .cleanup => try cmdCleanup(allocator, options),
    }
}

fn parseArgs(argv: []const []const u8) !Options {
    if (argv.len < 2) return error.MissingCommand;
    const command = parseCommand(argv[1]) orelse return error.UnknownCommand;
    var options = Options{ .command = command };
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--verdict-only")) {
            options.verdict_only = true;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            options.receipt_summary = true;
        } else if (std.mem.eql(u8, arg, "--capsule")) {
            options.capsule_path = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--capsule-definition")) {
            options.capsule_definition_path = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--capsule-validation")) {
            options.capsule_validation_path = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--plan")) {
            options.plan_path = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--plan-definition")) {
            options.plan_definition_path = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--plan-validation")) {
            options.plan_validation_path = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--receipt-dir")) {
            options.receipt_dir = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--inquiry-id")) {
            options.inquiry_id = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            options.cwd = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--model")) {
            options.model = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--model-provider")) {
            options.model_provider = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--service-tier")) {
            options.service_tier = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--permissions")) {
            options.permissions = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--sandbox")) {
            const value = try takeValue(argv, &i, arg);
            if (!std.mem.eql(u8, value, "read-only")) return error.UnsafeSandbox;
            options.sandbox = value;
        } else if (std.mem.eql(u8, arg, "--hooks")) {
            const value = try takeValue(argv, &i, arg);
            if (!isOneOf(value, &.{ "inherit", "off", "require-observed" })) return error.InvalidHooks;
            options.hooks = value;
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            options.timeout_ms = try parsePositiveU64(try takeValue(argv, &i, arg));
        } else if (std.mem.eql(u8, arg, "--max-total-tokens")) {
            options.max_total_tokens = try parsePositiveU64(try takeValue(argv, &i, arg));
        } else if (std.mem.eql(u8, arg, "--transport")) {
            const value = try takeValue(argv, &i, arg);
            if (!isOneOf(value, &.{ "auto", "managed-ws" })) return error.InvalidTransport;
            options.transport = value;
        } else if (std.mem.eql(u8, arg, "--glob")) {
            options.receipt_glob = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--format")) {
            const value = try takeValue(argv, &i, arg);
            if (!isOneOf(value, &.{ "table", "json" })) return error.InvalidFormat;
            options.receipt_format = value;
        } else if (std.mem.eql(u8, arg, "--codex-path")) {
            options.codex_path = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--code-mode-host")) {
            options.code_mode_host = try takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--store-root")) {
            const value = try takeValue(argv, &i, arg);
            if (value.len == 0) return error.InvalidStoreRoot;
            options.store_root = value;
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

fn parseCommand(raw: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn takeValue(argv: []const []const u8, index: *usize, flag: []const u8) ![]const u8 {
    _ = flag;
    if (index.* + 1 >= argv.len) return error.MissingValue;
    index.* += 1;
    return argv[index.*];
}

fn parsePositiveU64(raw: []const u8) !u64 {
    const value = try std.fmt.parseUnsigned(u64, raw, 10);
    if (value == 0) return error.InvalidNumber;
    return value;
}

fn isOneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

fn isSafePathComponent(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.') continue;
        return false;
    }
    return true;
}

fn cmdPreflight(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const result = runPreflight(allocator, io, options) catch |err| {
        try printPreflightFailure(allocator, options, err);
        std.process.exit(1);
    };
    defer deinitPreflightResult(allocator, result);
    try printJsonValue(allocator, .{ .session_inquiry_preflight = result });
    if (!result.inquiry_allowed) std.process.exit(2);
}

fn cmdRun(allocator: std.mem.Allocator, io: std.Io, options: Options, detached: bool) !void {
    const capsule_path = options.capsule_path orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingFlag", "--capsule");
    };
    const capsule_validation_path = options.capsule_validation_path orelse {
        core_cli.exitUsageFailure(
            HelpSurface,
            Version,
            "MissingFlag",
            "--capsule-validation",
        );
    };
    const capsule_definition_path = options.capsule_definition_path orelse {
        core_cli.exitUsageFailure(
            HelpSurface,
            Version,
            "MissingFlag",
            "--capsule-definition",
        );
    };
    const plan_path = options.plan_path orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingFlag", "--plan");
    };
    const plan_validation_path = options.plan_validation_path orelse {
        core_cli.exitUsageFailure(
            HelpSurface,
            Version,
            "MissingFlag",
            "--plan-validation",
        );
    };
    const plan_definition_path = options.plan_definition_path orelse {
        core_cli.exitUsageFailure(
            HelpSurface,
            Version,
            "MissingFlag",
            "--plan-definition",
        );
    };
    const receipt_dir = options.receipt_dir orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingFlag", "--receipt-dir");
    };

    const capsule_definition_absolute = absoluteLexicalPathAlloc(
        allocator,
        capsule_definition_path,
    ) catch |err| {
        try printFailureJson(allocator, FailureCode.capsule_invalid, @errorName(err));
        std.process.exit(2);
    };
    defer allocator.free(capsule_definition_absolute);
    var capsule_input = validateLedgerInput(
        allocator,
        capsule_path,
        capsule_validation_path,
        "retrace/decision-context-packet",
        "packet",
    ) catch |err| {
        try printFailureJson(
            allocator,
            FailureCode.capsule_invalid,
            @errorName(err),
        );
        std.process.exit(2);
    };
    defer capsule_input.deinit(allocator);
    const dcp = loadDcpBytes(allocator, capsule_input.input) catch |err| {
        try printFailureJson(allocator, FailureCode.capsule_invalid, @errorName(err));
        std.process.exit(2);
    };
    defer deinitDcp(allocator, dcp);
    const plan_definition_absolute = absoluteLexicalPathAlloc(
        allocator,
        plan_definition_path,
    ) catch |err| {
        try printFailureJson(allocator, FailureCode.plan_invalid, @errorName(err));
        std.process.exit(2);
    };
    defer allocator.free(plan_definition_absolute);
    var plan_input = validateLedgerInput(
        allocator,
        plan_path,
        plan_validation_path,
        "retrace/retrace-inquiry-plan",
        "plan",
    ) catch |err| {
        try printFailureJson(
            allocator,
            FailureCode.plan_invalid,
            @errorName(err),
        );
        std.process.exit(2);
    };
    defer plan_input.deinit(allocator);
    const rip = loadRipBytes(allocator, plan_input.input) catch |err| {
        try printFailureJson(allocator, FailureCode.plan_invalid, @errorName(err));
        std.process.exit(2);
    };
    defer deinitRip(allocator, rip);
    var bound_options = options;
    bound_options.capsule_definition_path = capsule_definition_absolute;
    bound_options.capsule_bytes = capsule_input.input;
    bound_options.capsule_validation_bytes = capsule_input.receipt;
    bound_options.plan_definition_path = plan_definition_absolute;
    bound_options.plan_bytes = plan_input.input;
    bound_options.plan_validation_bytes = plan_input.receipt;
    if (!std.mem.eql(u8, rip.plan_id, dcp.packet_id)) {
        try printFailureJson(allocator, FailureCode.plan_invalid, "RIP source_capsule does not match DCP packet_id");
        std.process.exit(2);
    }
    const gate = validateInquiryInputs(allocator, dcp, rip, options);
    if (!gate.valid) {
        try persistInvalidRunArtifacts(
            allocator,
            bound_options,
            dcp,
            rip,
            receipt_dir,
            gate,
            detached,
        );
        try printFailureJson(
            allocator,
            gate.failure_code orelse FailureCode.receipt_invalid,
            gate.hint,
        );
        std.process.exit(2);
    }

    const preflight_allocator = std.heap.page_allocator;
    const preflight = runPreflight(preflight_allocator, io, bound_options) catch |err| {
        const failed = GateResult{
            .valid = false,
            .failure_code = .codex_incompatible,
            .hint = @errorName(err),
        };
        try persistInvalidRunArtifacts(
            allocator,
            bound_options,
            dcp,
            rip,
            receipt_dir,
            failed,
            detached,
        );
        try printFailureJson(allocator, FailureCode.codex_incompatible, @errorName(err));
        std.process.exit(1);
    };
    defer deinitPreflightResult(preflight_allocator, preflight);
    const selected_lineage_supported = if (dcp.source_thread_id != null)
        preflight.thread_fork_replay
    else
        preflight.rollout_transcript_replay;
    if (!preflight.inquiry_allowed or !selected_lineage_supported) {
        const failed = GateResult{
            .valid = false,
            .failure_code = .codex_incompatible,
            .hint = if (dcp.source_thread_id != null)
                "exact Codex app-server preflight did not prove the required paginated thread-fork inquiry behavior"
            else
                "exact Codex app-server preflight did not prove the required rollout-transcript inquiry behavior",
        };
        try persistInvalidRunArtifacts(
            allocator,
            bound_options,
            dcp,
            rip,
            receipt_dir,
            failed,
            detached,
        );
        try printFailureJson(allocator, FailureCode.codex_incompatible, failed.hint);
        std.process.exit(2);
    }

    const run_allocator = std.heap.page_allocator;
    if (detached) {
        const result = startDetachedInquiry(
            run_allocator,
            bound_options,
            dcp,
            rip,
            receipt_dir,
            preflight,
        ) catch |err| blk: {
            const failed = GateResult{
                .valid = false,
                .failure_code = failureCodeForError(err),
                .hint = @errorName(err),
            };
            try persistInvalidRunArtifacts(
                allocator,
                bound_options,
                dcp,
                rip,
                receipt_dir,
                failed,
                detached,
            );
            break :blk RunOutput{
                .inquiry_id = rip.inquiry_id,
                .state = @tagName(InquiryState.failed),
                .receipt_dir = receipt_dir,
                .state_ref = try stateRecordPath(run_allocator, options.home, rip.inquiry_id),
                .events_ref = try std.fmt.allocPrint(run_allocator, "{s}/events.jsonl", .{receipt_dir}),
                .summary_ref = try std.fmt.allocPrint(run_allocator, "{s}/summary.json", .{receipt_dir}),
                .failure_code = (failed.failure_code orelse FailureCode.receipt_invalid).asString(),
                .failure_hint = failed.hint,
            };
        };
        defer deinitRunOutput(run_allocator, result);
        try printJsonValue(allocator, .{ .session_inquiry = result });
        if (!std.mem.eql(u8, result.failure_code, "")) std.process.exit(2);
        return;
    }

    const result = executeLiveInquiry(
        run_allocator,
        bound_options,
        dcp,
        rip,
        receipt_dir,
        preflight,
        false,
    ) catch |err| blk: {
        const failed = GateResult{
            .valid = false,
            .failure_code = failureCodeForError(err),
            .hint = @errorName(err),
        };
        try persistInvalidRunArtifacts(
            allocator,
            bound_options,
            dcp,
            rip,
            receipt_dir,
            failed,
            detached,
        );
        break :blk RunOutput{
            .inquiry_id = rip.inquiry_id,
            .state = @tagName(InquiryState.failed),
            .receipt_dir = receipt_dir,
            .state_ref = try stateRecordPath(run_allocator, options.home, rip.inquiry_id),
            .events_ref = try std.fmt.allocPrint(run_allocator, "{s}/events.jsonl", .{receipt_dir}),
            .summary_ref = try std.fmt.allocPrint(run_allocator, "{s}/summary.json", .{receipt_dir}),
            .failure_code = (failed.failure_code orelse FailureCode.receipt_invalid).asString(),
            .failure_hint = failed.hint,
        };
    };
    defer deinitRunOutput(run_allocator, result);
    try printJsonValue(allocator, .{ .session_inquiry = result });
    if (!std.mem.eql(u8, result.failure_code, "")) std.process.exit(2);
}

fn cmdStatus(allocator: std.mem.Allocator, options: Options) !void {
    const inquiry_id = options.inquiry_id orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingFlag", "--inquiry-id");
    };
    const path = try stateRecordPath(allocator, options.home, inquiry_id);
    const raw = readFileAlloc(allocator, path, MaxInputBytes) catch |err| {
        try printFailureJson(allocator, FailureCode.receipt_invalid, @errorName(err));
        std.process.exit(1);
    };
    defer allocator.free(raw);
    try printRawJson(raw);
}

fn cmdWait(allocator: std.mem.Allocator, options: Options) !void {
    const inquiry_id = options.inquiry_id orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingFlag", "--inquiry-id");
    };
    const result = waitDetachedInquiry(allocator, options, inquiry_id) catch |err| {
        try printFailureJson(allocator, failureCodeForError(err), @errorName(err));
        std.process.exit(1);
    };
    defer deinitRunOutput(allocator, result);
    try printJsonValue(allocator, .{ .session_inquiry = result });
    if (!std.mem.eql(u8, result.failure_code, "")) std.process.exit(2);
}

fn cmdInterrupt(allocator: std.mem.Allocator, options: Options) !void {
    const inquiry_id = options.inquiry_id orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingFlag", "--inquiry-id");
    };
    const result = interruptDetachedInquiry(allocator, options, inquiry_id) catch |err| {
        try printJsonValue(allocator, .{
            .session_inquiry_interrupt = .{
                .inquiry_id = inquiry_id,
                .interrupted = false,
                .failure_code = failureCodeForError(err).asString(),
                .failure_hint = @errorName(err),
            },
        });
        std.process.exit(2);
    };
    try printJsonValue(allocator, result);
    if (!result.session_inquiry_interrupt.interrupted) std.process.exit(2);
}

fn cmdCleanup(allocator: std.mem.Allocator, options: Options) !void {
    const inquiry_id = options.inquiry_id orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingFlag", "--inquiry-id");
    };
    const maybe_record = loadDetachedRecordAlloc(allocator, options.home, inquiry_id) catch null;
    defer if (maybe_record) |loaded| freeDetachedRecord(allocator, loaded);
    const was_alive = if (maybe_record) |loaded| cas_websocket.processAlive(loaded.managed_server_pid) else false;
    var cleanup_result: CleanupForksResult = .{};
    if (maybe_record) |loaded| {
        cleanup_result = cleanupPersistedForks(allocator, options, inquiry_id, loaded, was_alive) catch |err| .{
            .failed = 1,
            .failure_hint = @errorName(err),
        };
        if (was_alive) {
            cas_websocket.terminateProcess(loaded.managed_server_pid);
        }
    }
    const cleanup_path = try inquiryPathJoin(allocator, options.home, inquiry_id, "cleanup.json");
    try ensureParentDir(cleanup_path);
    const cleanup_status = if (cleanup_result.failed > 0)
        "cleanup_failed"
    else if (cleanup_result.persisted_forks > 0)
        "persisted_fallback_cleaned"
    else
        "ephemeral_runtime_closed";
    const warnings = if (cleanup_result.failed > 0)
        &[_][]const u8{cleanup_result.failure_hint}
    else
        &[_][]const u8{};
    const payload = .{
        .cleanup = .{
            .inquiry_id = inquiry_id,
            .status = cleanup_status,
            .managed_runtime_was_alive = was_alive,
            .persisted_fallback_forks = cleanup_result.persisted_forks,
            .deleted_forks = cleanup_result.deleted,
            .archived_forks = cleanup_result.archived,
            .failed_forks = cleanup_result.failed,
            .source_deleted = false,
            .warnings = warnings,
        },
    };
    try writeJsonFile(allocator, cleanup_path, payload);
    try printJsonValue(allocator, .{ .session_inquiry_cleanup = payload.cleanup });
}

const CleanupForksResult = struct {
    persisted_forks: u64 = 0,
    deleted: u64 = 0,
    archived: u64 = 0,
    failed: u64 = 0,
    failure_hint: []const u8 = "",
};

fn cleanupPersistedForks(
    allocator: std.mem.Allocator,
    options: Options,
    inquiry_id: []const u8,
    record: DetachedRecord,
    managed_runtime_alive: bool,
) !CleanupForksResult {
    const hook_policy = cas_client.hooks.HookPolicy.parse(options.hooks) orelse .inherit;
    var recovery_server: ?cas_websocket.ManagedServer = null;
    defer if (recovery_server) |*server| {
        server.kill();
        server.deinit(allocator);
    };
    const websocket_url = if (managed_runtime_alive) record.listen_url else blk: {
        recovery_server = try cas_websocket.startManagedLoopbackServer(
            allocator,
            record.cwd,
            record.codex_path,
            hook_policy,
            std.Io.Threaded.global_single_threaded.io(),
        );
        break :blk recovery_server.?.listen_url;
    };
    var client = try cas_client.Client.start(allocator, .{
        .cwd = record.cwd,
        .codex_path = record.codex_path,
        .client_name = "cas-session-inquiry-cleanup",
        .client_title = "CAS Session Inquiry Cleanup",
        .client_version = Version,
        .exec_approval = "decline",
        .file_approval = "decline",
        .permissions_approval = "deny",
        .elicitation_action = "decline",
        .dynamic_tool_response_json = "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"Dynamic tools are disabled for CAS session inquiry cleanup\"}],\"success\":false}",
        .read_only = true,
        .hook_policy = hook_policy,
        .websocket_url = websocket_url,
    });
    defer {
        client.close();
        client.deinit();
    }

    const lane_glob = try inquiryPathJoin(allocator, options.home, inquiry_id, "lanes/*.json");
    defer allocator.free(lane_glob);
    const lane_files = try expandSimpleGlobAlloc(allocator, lane_glob);
    defer freeStringList(allocator, lane_files);

    var result: CleanupForksResult = .{};
    for (lane_files) |lane_path| {
        const handle = loadLaneHandleAlloc(allocator, lane_path) catch |err| {
            result.failed += 1;
            result.failure_hint = @errorName(err);
            continue;
        };
        defer freeLaneHandle(allocator, handle);
        if (handle.fork_policy.ephemeral or handle.fork_cleaned) continue;
        result.persisted_forks += 1;
        if (cleanupForkWithMethod(allocator, &client, handle, "thread/delete")) {
            result.deleted += 1;
        } else if (cleanupForkWithMethod(allocator, &client, handle, "thread/archive")) {
            result.archived += 1;
        } else {
            result.failed += 1;
            result.failure_hint = "persisted fallback fork cleanup failed";
        }
    }
    return result;
}

fn cleanupForkWithMethod(
    allocator: std.mem.Allocator,
    client: *cas_client.Client,
    handle: LaneHandle,
    method: []const u8,
) bool {
    return cleanupForkThreadIdWithMethod(allocator, client, handle.lane_events, handle.fork_thread_id, method);
}

fn cleanupForkThreadIdWithMethod(
    allocator: std.mem.Allocator,
    client: *cas_client.Client,
    lane_events: []const u8,
    fork_thread_id: []const u8,
    method: []const u8,
) bool {
    const params = stringifyAnyAlloc(allocator, .{ .threadId = fork_thread_id }) catch return false;
    defer allocator.free(params);
    const request_event = stringifyAnyAlloc(allocator, .{ .event = method, .thread_id = fork_thread_id }) catch return false;
    defer allocator.free(request_event);
    appendLine(lane_events, request_event) catch return false;
    const response = client.requestJson(method, params) catch |err| {
        const error_event = stringifyAnyAlloc(allocator, .{
            .event = method,
            .thread_id = fork_thread_id,
            .failure = client.lastError() orelse @errorName(err),
        }) catch return false;
        defer allocator.free(error_event);
        appendLine(lane_events, error_event) catch {};
        return false;
    };
    defer allocator.free(response);
    appendLine(lane_events, response) catch return false;
    return true;
}

fn cmdReceipt(allocator: std.mem.Allocator, options: Options) !void {
    const glob = options.receipt_glob orelse {
        core_cli.exitUsageFailure(HelpSurface, Version, "MissingFlag", "--glob");
    };
    const files = try expandSimpleGlobAlloc(allocator, glob);
    var valid: usize = 0;
    var invalid: usize = 0;
    for (files) |path| {
        const receipt_valid = readFirReceiptValid(allocator, path) catch false;
        if (receipt_valid) valid += 1 else invalid += 1;
    }
    if (std.mem.eql(u8, options.receipt_format, "json") or options.json) {
        try printJsonValue(allocator, .{
            .session_inquiry_receipt = .{
                .glob = glob,
                .format = "json",
                .summary = options.receipt_summary,
                .offline = true,
                .files = files.len,
                .valid = valid,
                .invalid = invalid,
            },
        });
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("files valid invalid\n{d} {d} {d}\n", .{ files.len, valid, invalid });
    }
    if (invalid > 0) std.process.exit(2);
}

fn runPreflight(allocator: std.mem.Allocator, io: std.Io, options: Options) !PreflightResult {
    var shared = try runSharedSessionInquiryPreflight(allocator, io, options);
    defer shared.deinit(allocator);
    const fingerprint_source = try std.fmt.allocPrint(
        allocator,
        "cas-session-inquiry-schema-fingerprint/v1\x00{s}\x00{s}",
        .{ shared.stable_schema_digest, shared.experimental_schema_digest },
    );
    defer allocator.free(fingerprint_source);
    const fingerprint = sha256HexAlloc(allocator, fingerprint_source) catch return error.SchemaFingerprintFailed;
    errdefer allocator.free(fingerprint);
    const caps = try deriveCapabilitiesFromCache(allocator, shared.experimental_path);
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(allocator);
    if (!shared.route_neutral_compatible) try missing.append(allocator, "codex-app-server/session-inquiry-profile");
    if (!caps.thread_fork) try missing.append(allocator, "thread/fork");
    if (!caps.thread_rollback) try missing.append(allocator, "thread/rollback");
    if (!caps.thread_start) try missing.append(allocator, "thread/start");
    if (!caps.thread_read and !caps.thread_turns_list) try missing.append(allocator, "thread/read-or-thread/turns/list");
    if (!caps.turn_start) try missing.append(allocator, "turn/start");
    if (!caps.turn_interrupt) try missing.append(allocator, "turn/interrupt");
    if (!caps.thread_archive and !caps.thread_delete) try missing.append(allocator, "thread/archive-or-thread/delete");
    if (!caps.ephemeral_fork_field) try missing.append(allocator, "thread/fork.ephemeral");
    if (!caps.fork_permissions_field and !caps.fork_sandbox_field) try missing.append(allocator, "thread/fork.read-only-permissions");
    if (!caps.fork_last_turn_id_field) try missing.append(allocator, "thread/fork.lastTurnId");
    if (!caps.fork_before_turn_id_field) try missing.append(allocator, "thread/fork.beforeTurnId");
    if (!caps.fork_exclude_turns_field) try missing.append(allocator, "thread/fork.excludeTurns");
    if (!caps.fork_lineage_field) try missing.append(allocator, "thread/fork.response.thread.forkedFromId");
    if (!caps.turns_list_cursor_field or !caps.turns_list_limit_field or !caps.turns_list_sort_direction_field or
        !caps.turns_list_items_view_field or !caps.turns_list_data_field or !caps.turns_list_next_cursor_field)
    {
        try missing.append(allocator, "thread/turns/list.pagination-shape");
    }
    if (!shared.paginated_fork_passed) try missing.append(allocator, "thread/fork.paginated-behavior");
    if (!shared.ephemeral_fork_passed) try missing.append(allocator, "thread/fork.ephemeral-behavior");
    if (!shared.paginated_inquiry_passed) try missing.append(allocator, "session-inquiry.paginated-behavior");

    const missing_owned = try allocator.dupe([]const u8, missing.items);
    errdefer allocator.free(missing_owned);
    const thread_fork_replay = shared.route_neutral_compatible and shared.paginated_fork_passed and
        shared.ephemeral_fork_passed and shared.paginated_inquiry_passed and
        caps.exactAnchorSupported() and caps.turn_start and caps.turn_interrupt and
        (caps.thread_archive or caps.thread_delete) and (caps.fork_permissions_field or caps.fork_sandbox_field);
    const rollout_transcript_replay = shared.route_neutral_compatible and caps.rolloutTranscriptSupported();
    const allowed = thread_fork_replay or rollout_transcript_replay;
    const codex_path = try allocator.dupe(u8, shared.codex_path);
    errdefer allocator.free(codex_path);
    const codex_version = try allocator.dupe(u8, shared.codex_version);
    errdefer allocator.free(codex_version);
    const cache_dir = try allocator.dupe(u8, shared.cache_dir);
    errdefer allocator.free(cache_dir);
    const code_mode_host_redacted = try dupeOptionalString(allocator, shared.code_mode_host_redacted);
    errdefer if (code_mode_host_redacted) |value| allocator.free(value);
    const code_mode_host_digest = try dupeOptionalString(allocator, shared.code_mode_host_digest);
    errdefer if (code_mode_host_digest) |value| allocator.free(value);
    return .{
        .compatibility_verdict = if (allowed) "compatible" else "incompatible",
        .codex_path = codex_path,
        .codex_version = codex_version,
        .schema_fingerprint = fingerprint,
        .cache_dir = cache_dir,
        .selected_transport = "managed-ws",
        .capabilities = caps,
        .thread_fork_replay = thread_fork_replay,
        .paginated_thread_fork = thread_fork_replay and caps.paginatedAnchorSupported(),
        .rollout_transcript_replay = rollout_transcript_replay,
        .code_mode_host_redacted = code_mode_host_redacted,
        .code_mode_host_digest = code_mode_host_digest,
        .missing = missing_owned,
        .inquiry_allowed = allowed,
    };
}

fn runSharedSessionInquiryPreflight(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
) !SharedSessionInquiryPreflight {
    const self_path = std.process.executablePathAlloc(io, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.PreflightExecutablePathOutOfMemory,
        else => return err,
    };
    defer allocator.free(self_path);
    const executable_dir = std.fs.path.dirname(self_path) orelse return error.InvalidExecutablePath;
    const preflight_path = std.fs.path.join(allocator, &.{ executable_dir, "cas_app_server_preflight" }) catch
        return error.PreflightPathOutOfMemory;
    defer allocator.free(preflight_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.appendSlice(allocator, &.{
        preflight_path,
        "preflight",
        "--cwd",
        options.cwd,
        "--codex-path",
        options.codex_path,
        "--profile",
        "session-inquiry",
        "--app-server-transport",
        "managed-ws",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.PreflightArgumentsOutOfMemory,
    };
    if (options.code_mode_host) |host| argv.appendSlice(allocator, &.{ "--code-mode-host", host }) catch
        return error.PreflightArgumentsOutOfMemory;
    argv.append(allocator, "--json") catch return error.PreflightArgumentsOutOfMemory;

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = if (std.mem.eql(u8, options.cwd, ".")) .inherit else .{ .path = options.cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.PreflightProcessOutOfMemory,
        else => return err,
    };
    defer child.kill(io);
    const stdout_file = child.stdout orelse return error.PreflightMissingStdout;
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_reader = stdout_file.reader(io, &stdout_buffer);
    const stdout = stdout_reader.interface.allocRemaining(allocator, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => return error.PreflightOutputTooLarge,
        error.OutOfMemory => return error.PreflightOutputOutOfMemory,
        else => return err,
    };
    defer allocator.free(stdout);
    const term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        else => return error.AppServerPreflightFailed,
    };
    if (exit_code > 1) return error.AppServerPreflightFailed;
    var receipt = parseSharedSessionInquiryPreflightAlloc(allocator, stdout) catch |err| switch (err) {
        error.OutOfMemory => return error.PreflightReceiptOutOfMemory,
        else => return err,
    };
    errdefer receipt.deinit(allocator);
    if ((exit_code == 0) != receipt.overall_compatible) return error.AppServerPreflightStatusMismatch;
    const host_identity_present = receipt.code_mode_host_redacted != null and receipt.code_mode_host_digest != null;
    if ((options.code_mode_host != null) != host_identity_present) return error.AppServerPreflightHostIdentityMismatch;
    return receipt;
}

fn parseSharedSessionInquiryPreflightAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !SharedSessionInquiryPreflight {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidAppServerPreflightReceipt,
    };
    if (!std.mem.eql(u8, try requiredString(root, "schema"), "cas-app-server-preflight/v1") or
        !std.mem.eql(u8, try requiredString(root, "action"), "preflight") or
        !std.mem.eql(u8, try requiredString(root, "profile"), "session-inquiry") or
        !std.mem.eql(u8, try requiredString(root, "contractId"), AppServerContractId))
    {
        return error.InvalidAppServerPreflightReceipt;
    }
    const status = try requiredString(root, "status");
    if (!std.mem.eql(u8, status, "compatible") and !std.mem.eql(u8, status, "incompatible"))
        return error.InvalidAppServerPreflightReceipt;
    const codex = rootObject(root, "codex") orelse return error.InvalidAppServerPreflightReceipt;
    const schemas = rootObject(root, "schemas") orelse return error.InvalidAppServerPreflightReceipt;
    const methods = rootObject(root, "methods") orelse return error.InvalidAppServerPreflightReceipt;
    const handler_coverage = rootObject(root, "handlerCoverage") orelse return error.InvalidAppServerPreflightReceipt;
    const shape_checks = rootObject(root, "shapeChecks") orelse return error.InvalidAppServerPreflightReceipt;
    const transport = rootObject(root, "transport") orelse return error.InvalidAppServerPreflightReceipt;
    const probes_value = root.get("behavioralProbes") orelse return error.InvalidAppServerPreflightReceipt;
    const experimental_path = try requiredString(schemas, "experimentalPath");
    const cache_dir_slice = std.fs.path.dirname(experimental_path) orelse return error.InvalidAppServerPreflightReceipt;
    const stable_schema_digest_raw = try requiredString(schemas, "stableDigest");
    const experimental_schema_digest_raw = try requiredString(schemas, "experimentalDigest");
    if (!isSha256Digest(stable_schema_digest_raw) or !isSha256Digest(experimental_schema_digest_raw))
        return error.InvalidAppServerPreflightReceipt;
    const selected_transport = try requiredString(transport, "selected");
    if (!std.mem.eql(u8, selected_transport, "managed-ws")) return error.InvalidAppServerPreflightReceipt;
    const structural_compatible = try requiredListLen(methods, "missingRequired") == 0 and
        std.mem.eql(u8, try requiredString(handler_coverage, "status"), "passed") and
        try requiredListLen(handler_coverage, "failures") == 0 and
        std.mem.eql(u8, try requiredString(shape_checks, "status"), "passed") and
        try requiredListLen(shape_checks, "failures") == 0;
    const route_neutral_probes_passed = routeNeutralBehavioralProbesPassed(probes_value);
    const route_neutral_compatible = structural_compatible and route_neutral_probes_passed;
    const full_profile_probes_passed = route_neutral_probes_passed and
        requiredBehavioralProbePassed(probes_value, "paginated-fork") and
        requiredBehavioralProbePassed(probes_value, "ephemeral-fork") and
        requiredBehavioralProbePassed(probes_value, "paginated-session-inquiry");
    const overall_compatible = std.mem.eql(u8, status, "compatible") and
        structural_compatible and full_profile_probes_passed;

    var code_mode_host_redacted: ?[]u8 = null;
    errdefer if (code_mode_host_redacted) |value| allocator.free(value);
    var code_mode_host_digest: ?[]u8 = null;
    errdefer if (code_mode_host_digest) |value| allocator.free(value);
    if (transport.get("codeModeHost")) |identity_value| switch (identity_value) {
        .null => {},
        .object => |identity| {
            code_mode_host_redacted = try allocator.dupe(u8, try requiredString(identity, "origin"));
            const digest = try requiredString(identity, "sha256");
            if (!isLowerSha256Hex(digest)) return error.InvalidAppServerPreflightReceipt;
            code_mode_host_digest = try std.fmt.allocPrint(allocator, "sha256:{s}", .{digest});
        },
        else => return error.InvalidAppServerPreflightReceipt,
    };

    const version = try requiredString(codex, "version");
    const version_banner = if (std.mem.startsWith(u8, version, "codex-cli "))
        try allocator.dupe(u8, version)
    else
        try std.fmt.allocPrint(allocator, "codex-cli {s}", .{version});
    errdefer allocator.free(version_banner);
    const codex_path = try allocator.dupe(u8, try requiredString(codex, "path"));
    errdefer allocator.free(codex_path);
    const experimental_path_owned = try allocator.dupe(u8, experimental_path);
    errdefer allocator.free(experimental_path_owned);
    const cache_dir = try allocator.dupe(u8, cache_dir_slice);
    errdefer allocator.free(cache_dir);
    const stable_schema_digest = try allocator.dupe(u8, stable_schema_digest_raw);
    errdefer allocator.free(stable_schema_digest);
    const experimental_schema_digest = try allocator.dupe(u8, experimental_schema_digest_raw);
    errdefer allocator.free(experimental_schema_digest);
    const selected_transport_owned = try allocator.dupe(u8, selected_transport);
    errdefer allocator.free(selected_transport_owned);
    return .{
        .overall_compatible = overall_compatible,
        .route_neutral_compatible = route_neutral_compatible,
        .codex_path = codex_path,
        .codex_version = version_banner,
        .experimental_path = experimental_path_owned,
        .cache_dir = cache_dir,
        .stable_schema_digest = stable_schema_digest,
        .experimental_schema_digest = experimental_schema_digest,
        .selected_transport = selected_transport_owned,
        .paginated_fork_passed = requiredBehavioralProbePassed(probes_value, "paginated-fork"),
        .ephemeral_fork_passed = requiredBehavioralProbePassed(probes_value, "ephemeral-fork"),
        .paginated_inquiry_passed = requiredBehavioralProbePassed(probes_value, "paginated-session-inquiry"),
        .code_mode_host_redacted = code_mode_host_redacted,
        .code_mode_host_digest = code_mode_host_digest,
    };
}

fn requiredBehavioralProbePassed(value: std.json.Value, id: []const u8) bool {
    const rows = switch (value) {
        .array => |array| array.items,
        else => return false,
    };
    var found = false;
    for (rows) |row_value| {
        const row = switch (row_value) {
            .object => |object| object,
            else => return false,
        };
        const row_id = optionalString(row, "id") orelse return false;
        if (!std.mem.eql(u8, row_id, id)) continue;
        if (found) return false;
        found = true;
        if (!std.mem.eql(u8, optionalString(row, "requirement") orelse "", "required") or
            !std.mem.eql(u8, optionalString(row, "status") orelse "", "passed")) return false;
    }
    return found;
}

fn routeNeutralBehavioralProbesPassed(value: std.json.Value) bool {
    if (!requiredBehavioralProbePassed(value, "initialize-lifecycle") or
        !requiredBehavioralProbePassed(value, "managed-websocket-transport") or
        !requiredBehavioralProbePassed(value, "server-request-coverage") or
        !requiredBehavioralProbePassed(value, "bounded-overload-retry")) return false;

    const rows = switch (value) {
        .array => |array| array.items,
        else => return false,
    };
    for (rows) |row_value| {
        const row = switch (row_value) {
            .object => |object| object,
            else => return false,
        };
        const requirement = optionalString(row, "requirement") orelse return false;
        if (!std.mem.eql(u8, requirement, "required")) continue;
        const id = optionalString(row, "id") orelse return false;
        if (std.mem.eql(u8, id, "paginated-fork") or
            std.mem.eql(u8, id, "ephemeral-fork") or
            std.mem.eql(u8, id, "paginated-session-inquiry")) continue;
        if (!std.mem.eql(u8, optionalString(row, "status") orelse "", "passed")) return false;
    }
    return true;
}

fn isSha256Digest(value: []const u8) bool {
    return value.len == "sha256:".len + 64 and
        std.mem.startsWith(u8, value, "sha256:") and
        isLowerSha256Hex(value["sha256:".len..]);
}

fn isLowerSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn deinitPreflightResult(allocator: std.mem.Allocator, result: PreflightResult) void {
    allocator.free(result.codex_path);
    allocator.free(result.codex_version);
    allocator.free(result.schema_fingerprint);
    allocator.free(result.cache_dir);
    allocator.free(result.missing);
    if (result.code_mode_host_redacted) |value| allocator.free(value);
    if (result.code_mode_host_digest) |value| allocator.free(value);
}

fn deinitRunOutput(allocator: std.mem.Allocator, result: RunOutput) void {
    allocator.free(result.state_ref);
    allocator.free(result.events_ref);
    allocator.free(result.summary_ref);
}

fn validateLedgerInput(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    receipt_path: []const u8,
    definition_id: []const u8,
    input_name: []const u8,
) !ValidatedInput {
    const input = try readFileAlloc(allocator, input_path, MaxInputBytes);
    errdefer allocator.free(input);
    const receipt = try readFileAlloc(allocator, receipt_path, MaxInputBytes);
    errdefer allocator.free(receipt);
    const definition_digest = try validateLedgerReceiptBytes(
        allocator,
        input,
        receipt,
        definition_id,
        null,
        input_name,
    );
    return .{
        .input = input,
        .receipt = receipt,
        .definition_digest = definition_digest,
    };
}

fn deriveCapabilitiesFromCache(allocator: std.mem.Allocator, cache_dir: []const u8) !SchemaCapabilities {
    const client_request_path = try std.fs.path.join(allocator, &.{ cache_dir, "ClientRequest.json" });
    defer allocator.free(client_request_path);
    const fork_params_path = try std.fs.path.join(allocator, &.{ cache_dir, "v2", "ThreadForkParams.json" });
    defer allocator.free(fork_params_path);
    const fork_response_path = try std.fs.path.join(allocator, &.{ cache_dir, "v2", "ThreadForkResponse.json" });
    defer allocator.free(fork_response_path);
    const rollback_params_path = try std.fs.path.join(allocator, &.{ cache_dir, "v2", "ThreadRollbackParams.json" });
    defer allocator.free(rollback_params_path);
    const turns_list_params_path = try std.fs.path.join(allocator, &.{ cache_dir, "v2", "ThreadTurnsListParams.json" });
    defer allocator.free(turns_list_params_path);
    const turns_list_response_path = try std.fs.path.join(allocator, &.{ cache_dir, "v2", "ThreadTurnsListResponse.json" });
    defer allocator.free(turns_list_response_path);

    const client_request_raw = try readFileAlloc(allocator, client_request_path, MaxSchemaBytes);
    defer allocator.free(client_request_raw);
    const fork_params_raw = try readFileAlloc(allocator, fork_params_path, MaxSchemaBytes);
    defer allocator.free(fork_params_raw);
    const fork_response_raw = try readFileAlloc(allocator, fork_response_path, MaxSchemaBytes);
    defer allocator.free(fork_response_raw);
    const rollback_params_raw = try readFileAlloc(allocator, rollback_params_path, MaxSchemaBytes);
    defer allocator.free(rollback_params_raw);
    const turns_list_params_raw = try readFileAlloc(allocator, turns_list_params_path, MaxSchemaBytes);
    defer allocator.free(turns_list_params_raw);
    const turns_list_response_raw = try readFileAlloc(allocator, turns_list_response_path, MaxSchemaBytes);
    defer allocator.free(turns_list_response_raw);

    var client_request = try std.json.parseFromSlice(std.json.Value, allocator, client_request_raw, .{});
    defer client_request.deinit();
    var fork_params = try std.json.parseFromSlice(std.json.Value, allocator, fork_params_raw, .{});
    defer fork_params.deinit();
    var fork_response = try std.json.parseFromSlice(std.json.Value, allocator, fork_response_raw, .{});
    defer fork_response.deinit();
    var rollback_params = try std.json.parseFromSlice(std.json.Value, allocator, rollback_params_raw, .{});
    defer rollback_params.deinit();
    var turns_list_params = try std.json.parseFromSlice(std.json.Value, allocator, turns_list_params_raw, .{});
    defer turns_list_params.deinit();
    var turns_list_response = try std.json.parseFromSlice(std.json.Value, allocator, turns_list_response_raw, .{});
    defer turns_list_response.deinit();

    return deriveCapabilitiesFromSchemas(
        client_request.value,
        fork_params.value,
        fork_response.value,
        rollback_params.value,
        turns_list_params.value,
        turns_list_response.value,
    );
}

fn deriveCapabilitiesFromSchemas(
    client_request: std.json.Value,
    fork_params: std.json.Value,
    fork_response: std.json.Value,
    rollback_params: std.json.Value,
    turns_list_params: std.json.Value,
    turns_list_response: std.json.Value,
) SchemaCapabilities {
    return .{
        .thread_fork = clientRequestMethodPresent(client_request, "thread/fork"),
        .thread_rollback = clientRequestMethodPresent(client_request, "thread/rollback"),
        .thread_start = clientRequestMethodPresent(client_request, "thread/start"),
        .thread_read = clientRequestMethodPresent(client_request, "thread/read"),
        .thread_turns_list = clientRequestMethodPresent(client_request, "thread/turns/list"),
        .turn_start = clientRequestMethodPresent(client_request, "turn/start"),
        .turn_interrupt = clientRequestMethodPresent(client_request, "turn/interrupt"),
        .thread_archive = clientRequestMethodPresent(client_request, "thread/archive"),
        .thread_delete = clientRequestMethodPresent(client_request, "thread/delete"),
        .ephemeral_fork_field = schemaTopPropertyPresent(fork_params, "ephemeral"),
        .fork_permissions_field = schemaTopPropertyPresent(fork_params, "permissions"),
        .fork_sandbox_field = schemaTopPropertyPresent(fork_params, "sandbox"),
        .fork_path_field = schemaTopPropertyPresent(fork_params, "path"),
        .fork_last_turn_id_field = schemaTopPropertyPresent(fork_params, "lastTurnId"),
        .fork_before_turn_id_field = schemaTopPropertyPresent(fork_params, "beforeTurnId"),
        .fork_exclude_turns_field = schemaTopPropertyPresent(fork_params, "excludeTurns"),
        .fork_lineage_field = schemaDefinitionPropertyPresent(fork_response, "Thread", "forkedFromId"),
        .rollback_num_turns = schemaTopPropertyPresent(rollback_params, "numTurns"),
        .turns_list_cursor_field = schemaTopPropertyPresent(turns_list_params, "cursor"),
        .turns_list_limit_field = schemaTopPropertyPresent(turns_list_params, "limit"),
        .turns_list_sort_direction_field = schemaTopPropertyPresent(turns_list_params, "sortDirection"),
        .turns_list_items_view_field = schemaTopPropertyPresent(turns_list_params, "itemsView"),
        .turns_list_data_field = schemaTopPropertyPresent(turns_list_response, "data"),
        .turns_list_next_cursor_field = schemaTopPropertyPresent(turns_list_response, "nextCursor"),
        .shell_command_present = clientRequestMethodPresent(client_request, "thread/shellCommand"),
    };
}

fn clientRequestMethodPresent(schema: std.json.Value, expected: []const u8) bool {
    const root = switch (schema) {
        .object => |object| object,
        else => return false,
    };
    const variants = switch (root.get("oneOf") orelse return false) {
        .array => |array| array,
        else => return false,
    };
    for (variants.items) |variant_value| {
        const variant = switch (variant_value) {
            .object => |object| object,
            else => continue,
        };
        const properties = core_json.objectField(variant, "properties") orelse continue;
        const method = core_json.objectField(properties, "method") orelse continue;
        if (core_json.stringField(method, "const")) |value| {
            if (std.mem.eql(u8, value, expected)) return true;
        }
        const enum_values = switch (method.get("enum") orelse continue) {
            .array => |array| array,
            else => continue,
        };
        for (enum_values.items) |value| switch (value) {
            .string => |text| if (std.mem.eql(u8, text, expected)) return true,
            else => {},
        };
    }
    return false;
}

fn schemaTopPropertyPresent(schema: std.json.Value, property: []const u8) bool {
    const root = switch (schema) {
        .object => |object| object,
        else => return false,
    };
    const properties = core_json.objectField(root, "properties") orelse return false;
    return properties.get(property) != null;
}

fn schemaDefinitionPropertyPresent(schema: std.json.Value, definition: []const u8, property: []const u8) bool {
    const root = switch (schema) {
        .object => |object| object,
        else => return false,
    };
    const definitions = core_json.objectField(root, "definitions") orelse return false;
    const target = core_json.objectField(definitions, definition) orelse return false;
    const properties = core_json.objectField(target, "properties") orelse return false;
    return properties.get(property) != null;
}

fn loadDcp(allocator: std.mem.Allocator, path: []const u8) !Dcp {
    const raw = try readFileAlloc(allocator, path, MaxInputBytes);
    defer allocator.free(raw);
    return loadDcpBytes(allocator, raw);
}

fn loadDcpBytes(allocator: std.mem.Allocator, raw: []const u8) !Dcp {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    try verifyDcpContentIdentity(allocator, parsed.value);
    return dcpFromValue(allocator, parsed.value);
}

fn validateLedgerInputReceipt(
    allocator: std.mem.Allocator,
    receipt_path: []const u8,
    input_path: []const u8,
    definition_id: []const u8,
    expected_definition_digest: []const u8,
    input_name: []const u8,
) !ValidatedInput {
    const input = try readFileAlloc(allocator, input_path, MaxInputBytes);
    errdefer allocator.free(input);
    const receipt = try readFileAlloc(allocator, receipt_path, MaxInputBytes);
    errdefer allocator.free(receipt);
    const definition_digest = try validateLedgerReceiptBytes(
        allocator,
        input,
        receipt,
        definition_id,
        expected_definition_digest,
        input_name,
    );
    errdefer allocator.free(definition_digest);
    return .{
        .input = input,
        .receipt = receipt,
        .definition_digest = definition_digest,
    };
}

fn validateLedgerReceiptBytes(
    allocator: std.mem.Allocator,
    input: []const u8,
    receipt: []const u8,
    definition_id: []const u8,
    expected_definition_digest: ?[]const u8,
    input_name: []const u8,
) ![]u8 {
    const expected_input_digest = try sha256HexAlloc(allocator, input);
    defer allocator.free(expected_input_digest);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        receipt,
        .{ .duplicate_field_behavior = .@"error" },
    );
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.LedgerValidationReceiptNotObject,
    };
    if (!std.mem.eql(
        u8,
        try requiredString(root, "schema"),
        "ledger-validation-result/v1",
    )) return error.LedgerValidationReceiptSchemaMismatch;
    const definition_receipt = rootObject(root, "definition") orelse
        return error.LedgerValidationDefinitionMissing;
    if (!std.mem.eql(
        u8,
        try requiredString(definition_receipt, "id"),
        definition_id,
    )) return error.LedgerValidationDefinitionMismatch;
    if (!std.mem.eql(
        u8,
        try requiredString(definition_receipt, "abi"),
        "ledger-artifact-abi/v1",
    )) return error.LedgerValidationAbiMismatch;
    const definition_digest = try requiredString(
        definition_receipt,
        "digest",
    );
    if (definition_digest.len != 71 or
        !std.mem.startsWith(u8, definition_digest, "sha256:"))
    {
        return error.LedgerValidationDefinitionDigestInvalid;
    }
    if (expected_definition_digest) |expected| {
        if (!std.mem.eql(
            u8,
            definition_digest,
            expected,
        )) return error.LedgerValidationDefinitionDigestMismatch;
    }
    if (!try requiredBool(root, "valid")) {
        return error.LedgerValidationFailed;
    }
    if (try requiredBool(root, "authority_granted") or
        try requiredBool(root, "storage_mutated"))
    {
        return error.LedgerValidationReceiptAuthorityInvalid;
    }
    const errors = switch (root.get("errors") orelse
        return error.LedgerValidationErrorsMissing) {
        .array => |items| items,
        else => return error.LedgerValidationErrorsInvalid,
    };
    if (errors.items.len != 0) return error.LedgerValidationErrorsPresent;
    const input_digests = rootObject(root, "input_digests") orelse
        return error.LedgerValidationInputDigestsMissing;
    if (!std.mem.eql(
        u8,
        try requiredString(input_digests, input_name),
        expected_input_digest,
    )) return error.LedgerValidationInputDigestMismatch;
    return allocator.dupe(u8, definition_digest);
}

fn verifyDcpContentIdentity(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    const root = switch (value) {
        .object => |object| object,
        else => return error.NotObject,
    };
    const packet = rootObject(root, "decision_context_packet") orelse root;
    const claimed = try requiredString(packet, "packet_id");
    const canonical = try canonicalDcpV2JsonAlloc(allocator, value, true);
    defer allocator.free(canonical);
    const digest = try sha256HexAlloc(allocator, canonical);
    defer allocator.free(digest);
    const expected = try std.fmt.allocPrint(
        allocator,
        "DCP-{s}",
        .{digest["sha256:".len..]},
    );
    defer allocator.free(expected);
    if (!std.mem.eql(u8, claimed, expected)) {
        return error.DcpContentIdentityMismatch;
    }
}

// DCP-v2 identity is a released wire contract. Keep this private writer
// byte-compatible with the original DCP implementation instead of changing
// historical identities when the generic canonical-JSON profile evolves.
fn canonicalDcpV2JsonAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    omit_packet_id: bool,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try writeCanonicalDcpV2Json(
        allocator,
        &output.writer,
        value,
        omit_packet_id,
    );
    return output.toOwnedSlice();
}

fn writeCanonicalDcpV2Json(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
    omit_packet_id: bool,
) !void {
    switch (value) {
        .object => |object| {
            const keys = try allocator.alloc([]const u8, object.count());
            defer allocator.free(keys);
            var key_count: usize = 0;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                if (omit_packet_id and
                    std.mem.eql(u8, key, "packet_id"))
                {
                    continue;
                }
                keys[key_count] = key;
                key_count += 1;
            }
            std.mem.sort(
                []const u8,
                keys[0..key_count],
                {},
                struct {
                    fn lessThan(
                        _: void,
                        left: []const u8,
                        right: []const u8,
                    ) bool {
                        return std.mem.lessThan(u8, left, right);
                    }
                }.lessThan,
            );
            try writer.writeByte('{');
            for (keys[0..key_count], 0..) |key, index| {
                if (index != 0) try writer.writeByte(',');
                try std.json.Stringify.value(
                    std.json.Value{ .string = key },
                    .{},
                    writer,
                );
                try writer.writeByte(':');
                try writeCanonicalDcpV2Json(
                    allocator,
                    writer,
                    object.get(key).?,
                    omit_packet_id,
                );
            }
            try writer.writeByte('}');
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeCanonicalDcpV2Json(
                    allocator,
                    writer,
                    item,
                    omit_packet_id,
                );
            }
            try writer.writeByte(']');
        },
        else => try std.json.Stringify.value(value, .{}, writer),
    }
}

fn dcpFromValue(allocator: std.mem.Allocator, value: std.json.Value) !Dcp {
    // Ledger validates the DCP before this boundary. CAS independently binds
    // every consumed carrier to the materialized content identity and live
    // source so a substituted packet cannot inherit a validated identity.
    const root = switch (value) {
        .object => |obj| obj,
        else => return error.NotObject,
    };
    const packet = rootObject(root, "decision_context_packet") orelse root;
    if (!std.mem.eql(
        u8,
        try requiredString(packet, "packet_version"),
        "DCP-v2",
    )) return error.BadVersion;
    const packet_id = try requiredString(packet, "packet_id");
    const source = rootObject(packet, "source") orelse return error.MissingSource;
    const artifact = rootObject(packet, "artifact_state") orelse return error.MissingArtifactState;
    const turns = rootObject(packet, "turns") orelse return error.MissingTurns;
    const source_episode_id = try sourceEpisodeIdFromDcpAlloc(
        allocator,
        source,
        turns,
    );
    errdefer if (source_episode_id) |owned| allocator.free(owned);
    const anchors_obj = rootObject(packet, "anchors") orelse return error.MissingAnchors;
    const total = try requiredU64(turns, "total_turns");
    const decision = try requiredU64(turns, "decision_turn_index");
    const reconstructability = try requiredString(
        artifact,
        "reconstructability",
    );
    if (!isOneOf(reconstructability, &.{
        "exact",
        "head_only",
        "transcript_only",
        "unavailable",
    })) return error.BadReconstructability;
    var anchors = [_]Anchor{
        try parseAnchor(allocator, anchors_obj, .pre_decision, total),
        try parseAnchor(allocator, anchors_obj, .post_decision_pre_outcome, total),
        try parseAnchor(allocator, anchors_obj, .outcome_aware, total),
    };
    validateDcpAnchors(total, decision, optionalU64(turns, "first_outcome_turn_index"), &anchors) catch |err| return err;
    return .{
        .packet_id = try allocator.dupe(u8, packet_id),
        .source_episode_id = source_episode_id,
        .source_thread_id = try dupeOptionalString(allocator, optionalString(source, "thread_id")),
        .source_rollout_path = try dupeOptionalString(allocator, optionalString(source, "rollout_path")),
        .source_turn_digest = try allocator.dupe(u8, try requiredString(turns, "source_turn_digest")),
        .source_model = try dupeOptionalString(allocator, optionalString(source, "source_model")),
        .source_model_provider = try dupeOptionalString(allocator, optionalString(source, "source_model_provider")),
        .source_codex_version = try dupeOptionalString(allocator, optionalString(source, "source_codex_version")),
        .reconstructability = try allocator.dupe(
            u8,
            reconstructability,
        ),
        .total_turns = total,
        .decision_turn_index = decision,
        .first_outcome_turn_index = optionalU64(turns, "first_outcome_turn_index"),
        .anchors = anchors,
    };
}

fn sourceEpisodeIdFromDcpAlloc(
    allocator: std.mem.Allocator,
    source: std.json.ObjectMap,
    turns: std.json.ObjectMap,
) !?[]u8 {
    if (source.get("source_episode_id")) |value| {
        return switch (value) {
            .string => |text| if (text.len == 0)
                error.SourceEpisodeIdentityMismatch
            else
                try allocator.dupe(u8, text),
            else => error.SourceEpisodeIdentityMismatch,
        };
    }
    const session_id = optionalString(source, "session_id") orelse return null;
    const turn_id = optionalString(turns, "decision_turn_id") orelse return null;
    if (session_id.len == 0 or turn_id.len == 0) return null;
    return @as(?[]u8, try std.fmt.allocPrint(
        allocator,
        "session:{s}#turn:{s}",
        .{ session_id, turn_id },
    ));
}

fn parseAnchor(allocator: std.mem.Allocator, anchors_obj: std.json.ObjectMap, name: AnchorName, total_turns: u64) !Anchor {
    const obj = rootObject(anchors_obj, name.asString()) orelse return error.MissingAnchor;
    const available = try requiredBool(obj, "available");
    if (!available) return .{ .name = name, .available = false };
    const keep = try requiredU64(obj, "keep_through_turn_index");
    const drop = try requiredU64(obj, "drop_last_n_turns");
    if (keep > total_turns or keep + drop != total_turns) return error.BadAnchorMath;
    const digest = try requiredString(obj, "anchor_digest");
    return .{
        .name = name,
        .available = true,
        .keep_through_turn_index = keep,
        .drop_last_n_turns = drop,
        .anchor_digest = try allocator.dupe(u8, digest),
    };
}

fn validateDcpAnchors(total: u64, decision: u64, outcome: ?u64, anchors: *[3]Anchor) !void {
    if (total < 1) return error.BadTotalTurns;
    if (decision < 1 or decision > total) return error.BadDecisionTurn;
    if (outcome) |value| if (value <= decision or value > total) return error.BadOutcomeTurn;
    const pre = anchors[0];
    if (pre.available and pre.keep_through_turn_index >= decision) return error.BadPreDecisionAnchor;
    const post = anchors[1];
    if (post.available) {
        if (post.keep_through_turn_index < decision) return error.BadPostDecisionAnchor;
        if (outcome) |value| if (post.keep_through_turn_index >= value) return error.BadPostDecisionAnchor;
    }
}

fn deinitDcp(allocator: std.mem.Allocator, dcp: Dcp) void {
    allocator.free(dcp.packet_id);
    if (dcp.source_episode_id) |value| allocator.free(value);
    if (dcp.source_thread_id) |value| allocator.free(value);
    if (dcp.source_rollout_path) |value| allocator.free(value);
    allocator.free(dcp.source_turn_digest);
    if (dcp.source_model) |value| allocator.free(value);
    if (dcp.source_model_provider) |value| allocator.free(value);
    if (dcp.source_codex_version) |value| allocator.free(value);
    allocator.free(dcp.reconstructability);
    for (dcp.anchors) |anchor| {
        if (anchor.anchor_digest) |value| allocator.free(value);
    }
}

fn loadRip(allocator: std.mem.Allocator, path: []const u8) !Rip {
    const raw = try readFileAlloc(allocator, path, MaxInputBytes);
    defer allocator.free(raw);
    return loadRipBytes(allocator, raw);
}

fn loadRipBytes(allocator: std.mem.Allocator, raw: []const u8) !Rip {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.NotObject,
    };
    const plan = rootObject(root, "retrace_inquiry_plan") orelse root;
    if (!std.mem.eql(u8, try requiredString(plan, "plan_version"), "RIP-v1")) return error.BadVersion;
    const lanes_val = plan.get("lanes") orelse return error.MissingLanes;
    const lanes_arr = switch (lanes_val) {
        .array => |arr| arr,
        else => return error.MissingLanes,
    };
    if (lanes_arr.items.len == 0) return error.MissingLanes;
    if (lanes_arr.items.len > MaxInquiryLanes) return error.TooManyLanes;
    var lanes = try allocator.alloc(Lane, lanes_arr.items.len);
    var total_forks: u64 = 0;
    for (lanes_arr.items, 0..) |value, index| {
        const obj = switch (value) {
            .object => |inner| inner,
            else => return error.BadLane,
        };
        const fork_count = try requiredU64(obj, "fork_count");
        if (fork_count > MaxInquiryForks) return error.MaxForksExceeded;
        total_forks = std.math.add(
            u64,
            total_forks,
            fork_count,
        ) catch return error.MaxForksExceeded;
        lanes[index] = .{
            .lane_id = try allocator.dupe(u8, try requiredString(obj, "lane_id")),
            .temporal_horizon = try allocator.dupe(u8, try requiredString(obj, "temporal_horizon")),
            .inquiry_mode = try allocator.dupe(u8, try requiredString(obj, "inquiry_mode")),
            .fork_count = fork_count,
            .prompt_template = try allocator.dupe(u8, try requiredString(obj, "prompt_template")),
            .evidence_allowed_count = try requiredListLen(obj, "evidence_allowed"),
            .evidence_withheld_count = try requiredListLen(obj, "evidence_withheld"),
        };
        validateLane(lanes[index]) catch |err| return err;
    }
    const permissions = rootObject(plan, "permission_policy") orelse return error.MissingPermissionPolicy;
    const budgets = rootObject(plan, "budgets") orelse return error.MissingBudgets;
    const max_forks = try requiredU64(budgets, "max_forks");
    if (max_forks > MaxInquiryForks) return error.MaxForksExceeded;
    if (total_forks > max_forks) return error.MaxForksExceeded;
    const max_turns = try requiredU64(budgets, "max_turns_per_fork");
    if (max_turns < 1) return error.BadBudget;
    const max_total_tokens = try requiredU64(
        budgets,
        "max_total_tokens",
    );
    if (max_total_tokens > MaxInquiryTokens) {
        return error.MaxTotalTokensExceeded;
    }
    const timeout_ms = try requiredU64(budgets, "timeout_ms");
    if (timeout_ms > MaxInquiryTimeoutMs) {
        return error.InquiryTimeoutExceeded;
    }
    return .{
        .plan_id = try allocator.dupe(u8, try requiredString(plan, "source_capsule")),
        .inquiry_id = try allocator.dupe(u8, try requiredString(plan, "inquiry_id")),
        .objective = try allocator.dupe(u8, try requiredString(plan, "objective")),
        .model_policy = try allocator.dupe(u8, try requiredString(plan, "model_policy")),
        .workspace_policy = try allocator.dupe(u8, try requiredString(plan, "workspace_policy")),
        .permission_read_only = try requiredBool(permissions, "read_only"),
        .permission_network = try requiredBool(permissions, "network"),
        .max_forks = max_forks,
        .max_turns_per_fork = max_turns,
        .max_total_tokens = max_total_tokens,
        .timeout_ms = timeout_ms,
        .lanes = lanes,
    };
}

fn deinitRip(allocator: std.mem.Allocator, rip: Rip) void {
    allocator.free(rip.plan_id);
    allocator.free(rip.inquiry_id);
    allocator.free(rip.objective);
    allocator.free(rip.model_policy);
    allocator.free(rip.workspace_policy);
    for (rip.lanes) |lane| {
        allocator.free(lane.lane_id);
        allocator.free(lane.temporal_horizon);
        allocator.free(lane.inquiry_mode);
        allocator.free(lane.prompt_template);
    }
    allocator.free(rip.lanes);
}

fn validateLane(lane: Lane) !void {
    if (!isSafePathComponent(lane.lane_id)) return error.BadLaneId;
    if (!isOneOf(lane.temporal_horizon, &.{ "pre_decision", "post_decision_pre_outcome", "outcome_aware" })) return error.BadHorizon;
    if (!isOneOf(lane.inquiry_mode, &.{ "rationale", "counterfactual", "alternative_challenge", "assumption_probe", "evidence_ablation", "retrospective", "replay" })) return error.BadMode;
    if (lane.fork_count < 1) return error.BadForkCount;
    if (std.mem.eql(u8, lane.inquiry_mode, "counterfactual") and !std.mem.eql(u8, lane.temporal_horizon, "pre_decision")) return error.BadLaneHorizon;
    if (std.mem.eql(u8, lane.inquiry_mode, "alternative_challenge") and !std.mem.eql(u8, lane.temporal_horizon, "pre_decision")) return error.BadLaneHorizon;
    if (std.mem.eql(u8, lane.inquiry_mode, "replay") and !std.mem.eql(u8, lane.temporal_horizon, "pre_decision")) return error.BadLaneHorizon;
    if (std.mem.eql(u8, lane.inquiry_mode, "replay") and lane.fork_count != 1) return error.BadForkCount;
    if (std.mem.eql(u8, lane.inquiry_mode, "retrospective") and !std.mem.eql(u8, lane.temporal_horizon, "outcome_aware")) return error.BadLaneHorizon;
}

test "replay mode is one-fork pre-decision only" {
    const replay = Lane{
        .lane_id = "lane-replay",
        .temporal_horizon = "pre_decision",
        .inquiry_mode = "replay",
        .fork_count = 1,
        .prompt_template = "execute the registered opaque lane",
        .evidence_allowed_count = 0,
        .evidence_withheld_count = 0,
    };
    try validateLane(replay);
    var outcome_aware = replay;
    outcome_aware.temporal_horizon = "outcome_aware";
    try std.testing.expectError(error.BadLaneHorizon, validateLane(outcome_aware));
    var hidden_portfolio = replay;
    hidden_portfolio.fork_count = 2;
    try std.testing.expectError(error.BadForkCount, validateLane(hidden_portfolio));
}

fn laneById(rip: Rip, lane_id: []const u8) ?Lane {
    for (rip.lanes) |lane| {
        if (std.mem.eql(u8, lane.lane_id, lane_id)) return lane;
    }
    return null;
}

fn validateInquiryInputs(allocator: std.mem.Allocator, dcp: Dcp, rip: Rip, options: Options) GateResult {
    const lineage = resolveSourceLineage(allocator, dcp, rip) catch |err| return gateFailureForLineageError(err);
    _ = lineage;
    if (!rip.permission_read_only or rip.permission_network) {
        return .{ .valid = false, .failure_code = .permission_mismatch, .hint = "RIP must require read_only=true and network=false" };
    }
    if (!std.mem.eql(u8, options.sandbox, "read-only")) {
        return .{ .valid = false, .failure_code = .permission_mismatch, .hint = "only read-only sandbox is allowed" };
    }
    if (!isOneOf(rip.workspace_policy, &.{ "transcript_only", "exact", "head_only", "unavailable" })) {
        return .{ .valid = false, .failure_code = .workspace_mismatch, .hint = "unsupported workspace_policy" };
    }
    if (std.mem.eql(u8, rip.workspace_policy, "unavailable")) {
        return .{ .valid = false, .failure_code = .workspace_mismatch, .hint = "workspace_policy unavailable cannot run inquiry turns" };
    }
    if (rip.max_turns_per_fork != 1) {
        return .{ .valid = false, .failure_code = .budget_exhausted, .hint = "CAS session inquiry supports one turn per fork in v1" };
    }
    if (options.max_total_tokens) |limit| {
        if (rip.max_total_tokens > limit) {
            return .{ .valid = false, .failure_code = .budget_exhausted, .hint = "RIP max_total_tokens exceeds command limit" };
        }
    }
    for (rip.lanes) |lane| {
        const anchor = anchorForHorizon(dcp, lane.temporal_horizon) orelse {
            return .{ .valid = false, .failure_code = .decision_anchor_unavailable, .hint = "lane temporal horizon is unavailable in DCP" };
        };
        if ((std.mem.eql(u8, lane.temporal_horizon, "pre_decision") or std.mem.eql(u8, lane.temporal_horizon, "post_decision_pre_outcome")) and !anchor.available) {
            return .{ .valid = false, .failure_code = .decision_anchor_unavailable, .hint = "outcome-blind lanes require exact anchor availability" };
        }
    }
    return .{ .valid = true, .failure_code = null, .hint = "ok" };
}

fn resolveSourceLineage(allocator: std.mem.Allocator, dcp: Dcp, rip: Rip) !SourceLineageMode {
    if (dcp.source_thread_id != null) return .thread_fork;
    const rollout_path = dcp.source_rollout_path orelse return error.SourceNotFound;
    if (!std.mem.eql(u8, rip.workspace_policy, "transcript_only")) return error.WorkspaceMismatch;

    var trace = canonical_trace.parseSessionTrace(allocator, rollout_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SourceNotFound,
        else => return error.SourceStale,
    };
    defer trace.deinit(allocator);

    if (trace.turns.items.len != dcp.total_turns) return error.SourceStale;
    const source_digest = try trace_core.completeTraceDigest(allocator, trace);
    defer allocator.free(source_digest);
    if (!std.mem.eql(u8, source_digest, dcp.source_turn_digest)) return error.SourceDigestMismatch;

    for (rip.lanes) |lane| {
        const anchor = anchorForHorizon(dcp, lane.temporal_horizon) orelse return error.AnchorDigestMismatch;
        if (!anchor.available) return error.AnchorDigestMismatch;
        const observed = try trace_core.retainedTraceDigest(
            allocator,
            trace,
            @intCast(anchor.keep_through_turn_index),
        );
        defer allocator.free(observed);
        if (!std.mem.eql(u8, observed, anchor.anchor_digest orelse "")) return error.AnchorDigestMismatch;
    }
    return .rollout_transcript;
}

fn gateFailureForLineageError(err: anyerror) GateResult {
    return switch (err) {
        error.SourceNotFound => .{ .valid = false, .failure_code = .source_not_found, .hint = "DCP source must provide either thread_id or a readable rollout_path" },
        error.WorkspaceMismatch => .{ .valid = false, .failure_code = .workspace_mismatch, .hint = "rollout-backed DCP replay requires transcript_only RIP workspace policy" },
        error.SourceStale => .{ .valid = false, .failure_code = .source_stale, .hint = "rollout_path no longer reconstructs the DCP source turns" },
        error.SourceDigestMismatch => .{ .valid = false, .failure_code = .source_turn_digest_mismatch, .hint = "rollout_path source_turn_digest does not match DCP" },
        error.AnchorDigestMismatch => .{ .valid = false, .failure_code = .anchor_digest_mismatch, .hint = "rollout_path retained-turn digest does not match a lane anchor" },
        else => .{ .valid = false, .failure_code = .source_stale, .hint = @errorName(err) },
    };
}

fn failureCodeForError(err: anyerror) FailureCode {
    return switch (err) {
        error.SourceNotFound => .source_not_found,
        error.SourceStale => .source_stale,
        error.SourceDigestMismatch => .source_turn_digest_mismatch,
        error.ThreadHistoryModeUnsupported => .thread_history_mode_unsupported,
        error.ForkUnsupported => .fork_unsupported,
        error.ForkFailed => .fork_failed,
        error.LineageMismatch => .lineage_mismatch,
        error.RollbackFailed => .rollback_failed,
        error.AnchorDigestMismatch => .anchor_digest_mismatch,
        error.PermissionMismatch => .permission_mismatch,
        error.TurnStartFailed => .turn_start_failed,
        error.AnswerParseFailed => .answer_parse_failed,
        error.InquiryTransportLost => .inquiry_transport_lost,
        else => .receipt_invalid,
    };
}

fn anchorForHorizon(dcp: Dcp, horizon: []const u8) ?Anchor {
    for (dcp.anchors) |anchor| {
        if (std.mem.eql(u8, anchor.name.asString(), horizon)) return anchor;
    }
    return null;
}

fn executeLiveInquiry(
    allocator: std.mem.Allocator,
    options: Options,
    dcp: Dcp,
    rip: Rip,
    receipt_dir: []const u8,
    preflight: PreflightResult,
    detached: bool,
) !RunOutput {
    if (detached) return error.InquiryTransportLost;
    try ensureDir(receipt_dir);
    const lanes_dir = try std.fmt.allocPrint(allocator, "{s}/lanes", .{receipt_dir});
    defer allocator.free(lanes_dir);
    try ensureDir(lanes_dir);
    try persistInputCopies(allocator, options, rip.inquiry_id);
    const inquiry_cwd = try inquiryWorkspaceCwdAlloc(allocator, options, rip);
    defer allocator.free(inquiry_cwd);
    const events_path = try std.fmt.allocPrint(allocator, "{s}/events.jsonl", .{receipt_dir});
    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{receipt_dir});
    const state_path = try stateRecordPath(allocator, options.home, rip.inquiry_id);
    try appendSimpleEvent(allocator, events_path, "run_initialized");

    const hook_policy = cas_client.hooks.HookPolicy.parse(options.hooks) orelse .inherit;
    var managed_server = try startInquiryManagedServer(
        allocator,
        inquiry_cwd,
        null,
        preflight.codex_path,
        hook_policy,
        options.code_mode_host,
        std.Io.Threaded.global_single_threaded.io(),
    );
    defer managed_server.kill();
    defer managed_server.deinit(allocator);
    try appendSimpleEvent(allocator, events_path, "client_start");
    var client = try cas_client.Client.start(allocator, .{
        .cwd = inquiry_cwd,
        .codex_path = preflight.codex_path,
        .exec_approval = "decline",
        .file_approval = "decline",
        .permissions_approval = "deny",
        .elicitation_action = "decline",
        .dynamic_tool_response_json = "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"Dynamic tools are disabled for CAS session inquiry\"}],\"success\":false}",
        .read_only = true,
        .hook_policy = hook_policy,
        .websocket_url = managed_server.listen_url,
    });
    try appendSimpleEvent(allocator, events_path, "client_started");
    defer {
        client.close();
        client.deinit();
    }

    if (dcp.source_thread_id) |source_thread_id| {
        try appendSimpleEvent(allocator, events_path, "source_thread_verify_start");
        try verifySourceThread(allocator, &client, source_thread_id, dcp, events_path);
    } else {
        try appendSimpleEvent(allocator, events_path, "rollout_source_verify_start");
        _ = try resolveSourceLineage(allocator, dcp, rip);
        const verified_event = try stringifyAnyAlloc(allocator, .{ .event = "rollout/source_verified", .rollout_path = dcp.source_rollout_path orelse "" });
        defer allocator.free(verified_event);
        try appendLine(events_path, verified_event);
    }

    var valid_count: u64 = 0;
    var invalid_count: u64 = 0;
    var launched: u64 = 0;
    for (rip.lanes) |lane| {
        var ordinal: u64 = 0;
        while (ordinal < lane.fork_count) : (ordinal += 1) {
            const receipt_valid = try executeLaneForkWithRetries(allocator, &client, options, inquiry_cwd, dcp, rip, lane, ordinal, receipt_dir, events_path, preflight, &launched, null);
            if (receipt_valid) valid_count += 1 else invalid_count += 1;
        }
    }

    const terminal_state = if (invalid_count == 0) @tagName(InquiryState.completed) else if (valid_count > 0) @tagName(InquiryState.partially_completed) else @tagName(InquiryState.failed);
    const failure_code = if (invalid_count == 0) "" else FailureCode.receipt_invalid.asString();
    const failure_hint = if (invalid_count == 0) "" else "one or more lane FIR gates failed";
    const summary = .{
        .session_inquiry_summary = .{
            .summary_version = "SIS-v1",
            .inquiry_id = rip.inquiry_id,
            .state = terminal_state,
            .valid_firs = valid_count,
            .invalid_firs = invalid_count,
            .schema_fingerprint = preflight.schema_fingerprint,
            .failure_code = failure_code,
            .failure_hint = failure_hint,
        },
    };
    try writeJsonFile(allocator, summary_path, summary);
    const state = .{
        .session_inquiry_record = .{
            .record_version = "SIR-v1",
            .inquiry_id = rip.inquiry_id,
            .state = terminal_state,
            .capsule_id = dcp.packet_id,
            .plan_id = rip.inquiry_id,
            .source_thread_id = dcp.source_thread_id orelse "",
            .source_thread_id_present = dcp.source_thread_id != null,
            .source_rollout_path = dcp.source_rollout_path orelse "",
            .source_artifact_reconstructability = dcp.reconstructability,
            .lineage_mode = lineageMode(dcp).asString(),
            .managed_transport = .{
                .selected_transport = "managed-ws",
                .detached = detached,
                .code_mode_host_redacted = preflight.code_mode_host_redacted,
                .code_mode_host_digest = preflight.code_mode_host_digest,
            },
            .lane_states = [_][]const u8{},
            .budgets = .{
                .max_forks = rip.max_forks,
                .max_turns_per_fork = rip.max_turns_per_fork,
                .max_total_tokens = rip.max_total_tokens,
                .timeout_ms = rip.timeout_ms,
            },
            .tokens_used = 0,
            .started_at = nowMillis(),
            .updated_at = nowMillis(),
            .terminal_at = nowMillis(),
            .failure_code = failure_code,
            .failure_hint = failure_hint,
            .summary_ref = summary_path,
        },
    };
    try ensureParentDir(state_path);
    try writeJsonFile(allocator, state_path, state);
    return .{
        .inquiry_id = rip.inquiry_id,
        .state = terminal_state,
        .receipt_dir = receipt_dir,
        .state_ref = state_path,
        .events_ref = events_path,
        .summary_ref = summary_path,
        .failure_code = failure_code,
        .failure_hint = failure_hint,
    };
}

fn startDetachedInquiry(
    allocator: std.mem.Allocator,
    options: Options,
    dcp: Dcp,
    rip: Rip,
    receipt_dir: []const u8,
    preflight: PreflightResult,
) !RunOutput {
    try ensureDir(receipt_dir);
    const receipt_root = try absoluteDirPathAlloc(allocator, receipt_dir);
    const lanes_dir = try std.fmt.allocPrint(allocator, "{s}/lanes", .{receipt_root});
    defer allocator.free(lanes_dir);
    try ensureDir(lanes_dir);
    const state_lanes_dir = try inquiryPathJoin(allocator, options.home, rip.inquiry_id, "lanes");
    defer allocator.free(state_lanes_dir);
    try ensureDir(state_lanes_dir);
    try persistInputCopies(allocator, options, rip.inquiry_id);
    const inquiry_cwd = try inquiryWorkspaceCwdAlloc(allocator, options, rip);
    defer allocator.free(inquiry_cwd);
    const events_path = try std.fmt.allocPrint(allocator, "{s}/events.jsonl", .{receipt_root});
    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{receipt_root});
    const state_path = try stateRecordPath(allocator, options.home, rip.inquiry_id);

    const hook_policy = cas_client.hooks.HookPolicy.parse(options.hooks) orelse .inherit;
    var managed_server = try startInquiryManagedServer(
        allocator,
        inquiry_cwd,
        receipt_root,
        preflight.codex_path,
        hook_policy,
        options.code_mode_host,
        std.Io.Threaded.global_single_threaded.io(),
    );
    var keep_server = false;
    defer if (!keep_server) managed_server.deinit(allocator);

    var client = try cas_client.Client.start(allocator, .{
        .cwd = inquiry_cwd,
        .codex_path = preflight.codex_path,
        .client_name = "cas-session-inquiry",
        .client_title = "CAS Session Inquiry",
        .client_version = Version,
        .exec_approval = "decline",
        .file_approval = "decline",
        .permissions_approval = "deny",
        .elicitation_action = "decline",
        .dynamic_tool_response_json = "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"Dynamic tools are disabled for CAS session inquiry\"}],\"success\":false}",
        .read_only = true,
        .hook_policy = hook_policy,
        .websocket_url = managed_server.listen_url,
    });
    defer {
        client.close();
        client.deinit();
    }

    if (dcp.source_thread_id) |source_thread_id| {
        try verifySourceThread(allocator, &client, source_thread_id, dcp, events_path);
    } else {
        _ = try resolveSourceLineage(allocator, dcp, rip);
        const verified_event = try stringifyAnyAlloc(allocator, .{ .event = "rollout/source_verified", .rollout_path = dcp.source_rollout_path orelse "" });
        defer allocator.free(verified_event);
        try appendLine(events_path, verified_event);
    }

    var launched: u64 = 0;
    for (rip.lanes) |lane| {
        var ordinal: u64 = 0;
        while (ordinal < lane.fork_count) : (ordinal += 1) {
            if (launched >= rip.max_forks) return error.BudgetExhausted;
            launched += 1;
            _ = try startLaneFork(allocator, &client, options, inquiry_cwd, dcp, rip, lane, ordinal, 0, receipt_root, events_path, preflight);
        }
    }

    const transport_path = try inquiryPathJoin(allocator, options.home, rip.inquiry_id, "managed-transport.json");
    defer allocator.free(transport_path);
    try writeJsonFile(allocator, transport_path, .{
        .managed_transport = .{
            .selected_transport = "managed-ws",
            .detached = true,
            .managed_server_pid = managed_server.processId(),
            .listen_url = managed_server.listen_url,
            .codex_path = preflight.codex_path,
            .codex_version = preflight.codex_version,
            .cwd = inquiry_cwd,
            .receipt_dir = receipt_root,
            .schema_fingerprint = preflight.schema_fingerprint,
            .code_mode_host_redacted = preflight.code_mode_host_redacted,
            .code_mode_host_digest = preflight.code_mode_host_digest,
        },
    });

    try writeInquiryState(
        allocator,
        state_path,
        dcp,
        rip,
        dcp.source_thread_id orelse "",
        @tagName(InquiryState.turn_running),
        receipt_root,
        events_path,
        summary_path,
        preflight,
        true,
        managed_server.processId(),
        managed_server.listen_url,
        inquiry_cwd,
        "",
        "",
        null,
    );
    try writeSummary(allocator, summary_path, rip.inquiry_id, @tagName(InquiryState.turn_running), 0, 0, preflight.schema_fingerprint, "", "");
    const store_root = try casStoreRootAlloc(allocator);
    defer allocator.free(store_root);
    try spawnDetachedWaitWorker(allocator, options, rip.inquiry_id, rip.timeout_ms, store_root);
    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(750), .awake) catch {};
    keep_server = true;
    return .{
        .inquiry_id = rip.inquiry_id,
        .state = @tagName(InquiryState.turn_running),
        .receipt_dir = receipt_root,
        .state_ref = state_path,
        .events_ref = events_path,
        .summary_ref = summary_path,
        .failure_code = "",
        .failure_hint = "",
    };
}

fn startInquiryManagedServer(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    owner_receipt_dir: ?[]const u8,
    codex_path: []const u8,
    hook_policy: cas_client.hooks.HookPolicy,
    code_mode_host_raw: ?[]const u8,
    io: std.Io,
) !cas_websocket.ManagedServer {
    var code_mode_host: ?cas_client.app_server_launch.CodeModeHost = if (code_mode_host_raw) |raw|
        try cas_client.app_server_launch.CodeModeHost.init(allocator, raw)
    else
        null;
    defer if (code_mode_host) |*host| host.deinit();
    if (owner_receipt_dir) |receipt_dir| {
        if (code_mode_host) |*host| return cas_websocket.startOwnerLivedLoopbackServerWithCodeModeHost(
            allocator,
            cwd,
            receipt_dir,
            codex_path,
            hook_policy,
            host,
            io,
        );
        return cas_websocket.startOwnerLivedLoopbackServer(
            allocator,
            cwd,
            receipt_dir,
            codex_path,
            hook_policy,
            io,
        );
    }
    if (code_mode_host) |*host| return cas_websocket.startManagedLoopbackServerWithCodeModeHost(
        allocator,
        cwd,
        codex_path,
        hook_policy,
        host,
        io,
    );
    return cas_websocket.startManagedLoopbackServer(allocator, cwd, codex_path, hook_policy, io);
}

fn spawnDetachedWaitWorker(allocator: std.mem.Allocator, options: Options, inquiry_id: []const u8, timeout_ms: u64, store_root: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const self_exe = if (fileExists("zig-out/bin/cas_session_inquiry"))
        try allocator.dupe(u8, "zig-out/bin/cas_session_inquiry")
    else
        try resolveExecutablePathAlloc(allocator, "cas_session_inquiry", options.path_env);
    defer allocator.free(self_exe);
    const timeout_text = try std.fmt.allocPrint(allocator, "{d}", .{timeout_ms});
    defer allocator.free(timeout_text);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        self_exe,
        "wait",
        "--inquiry-id",
        inquiry_id,
        "--timeout-ms",
        timeout_text,
        "--store-root",
        store_root,
    });
    try argv.append(allocator, "--json");
    _ = try cas_websocket.spawnDetachedProcess(
        allocator,
        ".",
        argv.items,
        io,
    );
}

fn waitDetachedInquiry(allocator: std.mem.Allocator, options: Options, inquiry_id: []const u8) !RunOutput {
    const record = try loadDetachedRecordAlloc(allocator, options.home, inquiry_id);
    if (std.mem.eql(u8, record.state, @tagName(InquiryState.completed)) or
        std.mem.eql(u8, record.state, @tagName(InquiryState.partially_completed)) or
        std.mem.eql(u8, record.state, @tagName(InquiryState.failed)) or
        std.mem.eql(u8, record.state, @tagName(InquiryState.interrupted)) or
        std.mem.eql(u8, record.state, @tagName(InquiryState.closed)))
    {
        return .{
            .inquiry_id = record.inquiry_id,
            .state = record.state,
            .receipt_dir = record.receipt_dir,
            .state_ref = record.state_ref,
            .events_ref = record.events_ref,
            .summary_ref = record.summary_ref,
            .failure_code = record.failure_code,
            .failure_hint = record.failure_hint,
        };
    }
    const capsule_path = try inquiryPathJoin(
        allocator,
        options.home,
        inquiry_id,
        "capsule.json",
    );
    defer allocator.free(capsule_path);
    const capsule_receipt_path = try inquiryPathJoin(
        allocator,
        options.home,
        inquiry_id,
        "capsule.validation.json",
    );
    defer allocator.free(capsule_receipt_path);
    var capsule_input = try validateLedgerInput(
        allocator,
        capsule_path,
        capsule_receipt_path,
        "retrace/decision-context-packet",
        "packet",
    );
    defer capsule_input.deinit(allocator);
    const plan_path = try inquiryPathJoin(
        allocator,
        options.home,
        inquiry_id,
        "plan.json",
    );
    defer allocator.free(plan_path);
    const plan_receipt_path = try inquiryPathJoin(
        allocator,
        options.home,
        inquiry_id,
        "plan.validation.json",
    );
    defer allocator.free(plan_receipt_path);
    var plan_input = try validateLedgerInput(
        allocator,
        plan_path,
        plan_receipt_path,
        "retrace/retrace-inquiry-plan",
        "plan",
    );
    defer plan_input.deinit(allocator);
    const dcp = try loadDcpBytes(allocator, capsule_input.input);
    defer deinitDcp(allocator, dcp);
    const rip = try loadRipBytes(allocator, plan_input.input);
    defer deinitRip(allocator, rip);

    const managed_runtime_alive = cas_websocket.processAlive(record.managed_server_pid);
    if (!managed_runtime_alive) return error.InquiryTransportLost;
    const hook_policy = cas_client.hooks.HookPolicy.parse(options.hooks) orelse .inherit;

    var client = try cas_client.Client.start(allocator, .{
        .cwd = record.cwd,
        .codex_path = record.codex_path,
        .client_name = "cas-session-inquiry",
        .client_title = "CAS Session Inquiry",
        .client_version = Version,
        .exec_approval = "decline",
        .file_approval = "decline",
        .permissions_approval = "deny",
        .elicitation_action = "decline",
        .dynamic_tool_response_json = "{\"contentItems\":[{\"type\":\"inputText\",\"text\":\"Dynamic tools are disabled for CAS session inquiry\"}],\"success\":false}",
        .read_only = true,
        .hook_policy = hook_policy,
        .websocket_url = record.listen_url,
    });
    defer {
        client.close();
        client.deinit();
    }

    const lane_glob = try inquiryPathJoin(allocator, options.home, inquiry_id, "lanes/*.json");
    defer allocator.free(lane_glob);
    const lane_files = try expandSimpleGlobAlloc(allocator, lane_glob);
    var valid_count: u64 = 0;
    var invalid_count: u64 = 0;
    for (lane_files) |lane_path| {
        const handle = try loadLaneHandleAlloc(allocator, lane_path);
        const result = try collectLaneFork(allocator, &client, options, dcp, handle);
        if (result.receipt_valid) valid_count += 1 else invalid_count += 1;
    }

    const terminal_state = if (invalid_count == 0) @tagName(InquiryState.completed) else if (valid_count > 0) @tagName(InquiryState.partially_completed) else @tagName(InquiryState.failed);
    const failure_code = if (invalid_count == 0) "" else FailureCode.receipt_invalid.asString();
    const failure_hint = if (invalid_count == 0) "" else "one or more lane FIR gates failed";
    try writeSummary(allocator, record.summary_ref, inquiry_id, terminal_state, valid_count, invalid_count, record.schema_fingerprint, failure_code, failure_hint);
    try writeInquiryState(
        allocator,
        record.state_ref,
        dcp,
        rip,
        dcp.source_thread_id orelse "",
        terminal_state,
        record.receipt_dir,
        record.events_ref,
        record.summary_ref,
        .{
            .compatibility_verdict = "compatible",
            .codex_path = record.codex_path,
            .codex_version = record.codex_version,
            .schema_fingerprint = record.schema_fingerprint,
            .cache_dir = "",
            .selected_transport = "managed-ws",
            .capabilities = zeroCapabilities(),
            .thread_fork_replay = false,
            .paginated_thread_fork = false,
            .rollout_transcript_replay = false,
            .code_mode_host_redacted = if (record.code_mode_host_redacted.len > 0) record.code_mode_host_redacted else null,
            .code_mode_host_digest = if (record.code_mode_host_digest.len > 0) record.code_mode_host_digest else null,
            .missing = &.{},
            .inquiry_allowed = true,
        },
        true,
        record.managed_server_pid,
        record.listen_url,
        record.cwd,
        failure_code,
        failure_hint,
        nowMillis(),
    );
    return .{
        .inquiry_id = inquiry_id,
        .state = terminal_state,
        .receipt_dir = record.receipt_dir,
        .state_ref = record.state_ref,
        .events_ref = record.events_ref,
        .summary_ref = record.summary_ref,
        .failure_code = failure_code,
        .failure_hint = failure_hint,
    };
}

fn interruptDetachedInquiry(allocator: std.mem.Allocator, options: Options, inquiry_id: []const u8) !struct { session_inquiry_interrupt: struct { inquiry_id: []const u8, interrupted: bool, interrupted_turns: u64, failure_code: []const u8, failure_hint: []const u8 } } {
    const record = try loadDetachedRecordAlloc(allocator, options.home, inquiry_id);
    if (!cas_websocket.processAlive(record.managed_server_pid)) return error.InquiryTransportLost;
    var client = try cas_client.Client.start(allocator, .{
        .cwd = record.cwd,
        .codex_path = record.codex_path,
        .client_name = "cas-session-inquiry",
        .client_title = "CAS Session Inquiry",
        .client_version = Version,
        .exec_approval = "decline",
        .file_approval = "decline",
        .permissions_approval = "deny",
        .read_only = true,
        .websocket_url = record.listen_url,
    });
    defer {
        client.close();
        client.deinit();
    }
    const lane_glob = try inquiryPathJoin(allocator, options.home, inquiry_id, "lanes/*.json");
    defer allocator.free(lane_glob);
    const lane_files = try expandSimpleGlobAlloc(allocator, lane_glob);
    var interrupted: u64 = 0;
    for (lane_files) |lane_path| {
        const handle = try loadLaneHandleAlloc(allocator, lane_path);
        const params = try stringifyAnyAlloc(allocator, .{ .threadId = handle.fork_thread_id, .turnId = handle.turn_id });
        defer allocator.free(params);
        const result = client.requestJson("turn/interrupt", params) catch continue;
        defer allocator.free(result);
        try appendLine(handle.lane_events, result);
        try writeLaneHandle(allocator, handle, @tagName(InquiryState.interrupted));
        interrupted += 1;
    }
    if (interrupted > 0) {
        const capsule_path = try inquiryPathJoin(allocator, options.home, inquiry_id, "capsule.json");
        defer allocator.free(capsule_path);
        const plan_path = try inquiryPathJoin(allocator, options.home, inquiry_id, "plan.json");
        defer allocator.free(plan_path);
        const dcp = try loadDcp(allocator, capsule_path);
        defer deinitDcp(allocator, dcp);
        const rip = try loadRip(allocator, plan_path);
        defer deinitRip(allocator, rip);
        try writeSummary(
            allocator,
            record.summary_ref,
            inquiry_id,
            @tagName(InquiryState.interrupted),
            0,
            interrupted,
            record.schema_fingerprint,
            FailureCode.fork_interrupted.asString(),
            "active inquiry turns were interrupted",
        );
        try writeInquiryState(
            allocator,
            record.state_ref,
            dcp,
            rip,
            dcp.source_thread_id orelse "",
            @tagName(InquiryState.interrupted),
            record.receipt_dir,
            record.events_ref,
            record.summary_ref,
            .{
                .compatibility_verdict = "compatible",
                .codex_path = record.codex_path,
                .codex_version = record.codex_version,
                .schema_fingerprint = record.schema_fingerprint,
                .cache_dir = "",
                .selected_transport = "managed-ws",
                .capabilities = zeroCapabilities(),
                .thread_fork_replay = false,
                .paginated_thread_fork = false,
                .rollout_transcript_replay = false,
                .code_mode_host_redacted = if (record.code_mode_host_redacted.len > 0) record.code_mode_host_redacted else null,
                .code_mode_host_digest = if (record.code_mode_host_digest.len > 0) record.code_mode_host_digest else null,
                .missing = &.{},
                .inquiry_allowed = true,
            },
            true,
            record.managed_server_pid,
            record.listen_url,
            record.cwd,
            FailureCode.fork_interrupted.asString(),
            "active inquiry turns were interrupted",
            nowMillis(),
        );
    }
    return .{
        .session_inquiry_interrupt = .{
            .inquiry_id = inquiry_id,
            .interrupted = interrupted > 0,
            .interrupted_turns = interrupted,
            .failure_code = if (interrupted > 0) "" else FailureCode.fork_interrupted.asString(),
            .failure_hint = if (interrupted > 0) "" else "no active inquiry turns were interrupted",
        },
    };
}

fn verifySourceThread(
    allocator: std.mem.Allocator,
    client: *cas_client.Client,
    source_thread_id: []const u8,
    dcp: Dcp,
    events_path: []const u8,
) !void {
    const source = try readThreadHistorySnapshot(
        allocator,
        client,
        source_thread_id,
        dcp.total_turns,
        events_path,
    );
    defer source.deinit(allocator);
    if (source.digest.count != dcp.total_turns) {
        try appendSourceDigestMismatchEvent(allocator, events_path, source.digest, dcp.total_turns, dcp.source_turn_digest, "source_stale");
        return error.SourceStale;
    }
    if (!std.mem.eql(u8, source.digest.digest, dcp.source_turn_digest)) {
        try appendSourceDigestMismatchEvent(allocator, events_path, source.digest, dcp.total_turns, dcp.source_turn_digest, "source_turn_digest_mismatch");
        return error.SourceDigestMismatch;
    }
}

fn threadHistoryModeFromRead(allocator: std.mem.Allocator, raw: []const u8) !ThreadHistoryMode {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.SourceStale,
    };
    const thread = core_json.objectField(root, "thread") orelse return error.SourceStale;
    const history_mode = core_json.stringField(thread, "historyMode") orelse "legacy";
    if (std.mem.eql(u8, history_mode, "legacy")) return .legacy;
    if (std.mem.eql(u8, history_mode, "paginated")) return .paginated;
    return error.ThreadHistoryModeUnsupported;
}

fn writeSummary(
    allocator: std.mem.Allocator,
    summary_path: []const u8,
    inquiry_id: []const u8,
    state: []const u8,
    valid_count: u64,
    invalid_count: u64,
    schema_fingerprint: []const u8,
    failure_code: []const u8,
    failure_hint: []const u8,
) !void {
    try writeJsonFile(allocator, summary_path, .{
        .session_inquiry_summary = .{
            .summary_version = "SIS-v1",
            .inquiry_id = inquiry_id,
            .state = state,
            .valid_firs = valid_count,
            .invalid_firs = invalid_count,
            .schema_fingerprint = schema_fingerprint,
            .failure_code = failure_code,
            .failure_hint = failure_hint,
        },
    });
}

fn writeInquiryState(
    allocator: std.mem.Allocator,
    state_path: []const u8,
    dcp: Dcp,
    rip: Rip,
    source_thread_id: []const u8,
    state_name: []const u8,
    receipt_dir: []const u8,
    events_path: []const u8,
    summary_path: []const u8,
    preflight: PreflightResult,
    detached: bool,
    managed_server_pid: u64,
    listen_url: []const u8,
    cwd: []const u8,
    failure_code: []const u8,
    failure_hint: []const u8,
    terminal_at: ?i128,
) !void {
    try ensureParentDir(state_path);
    try writeJsonFile(allocator, state_path, .{
        .session_inquiry_record = .{
            .record_version = "SIR-v1",
            .inquiry_id = rip.inquiry_id,
            .state = state_name,
            .capsule_id = dcp.packet_id,
            .plan_id = rip.inquiry_id,
            .source_thread_id = source_thread_id,
            .source_thread_id_present = dcp.source_thread_id != null,
            .source_rollout_path = dcp.source_rollout_path orelse "",
            .source_artifact_reconstructability = dcp.reconstructability,
            .lineage_mode = lineageMode(dcp).asString(),
            .receipt_dir = receipt_dir,
            .events_ref = events_path,
            .managed_transport = .{
                .selected_transport = "managed-ws",
                .detached = detached,
                .managed_server_pid = managed_server_pid,
                .listen_url = listen_url,
                .codex_path = preflight.codex_path,
                .codex_version = preflight.codex_version,
                .cwd = cwd,
                .schema_fingerprint = preflight.schema_fingerprint,
                .code_mode_host_redacted = preflight.code_mode_host_redacted,
                .code_mode_host_digest = preflight.code_mode_host_digest,
            },
            .lane_states = [_][]const u8{},
            .budgets = .{
                .max_forks = rip.max_forks,
                .max_turns_per_fork = rip.max_turns_per_fork,
                .max_total_tokens = rip.max_total_tokens,
                .timeout_ms = rip.timeout_ms,
            },
            .tokens_used = 0,
            .started_at = nowMillis(),
            .updated_at = nowMillis(),
            .terminal_at = terminal_at,
            .failure_code = failure_code,
            .failure_hint = failure_hint,
            .summary_ref = summary_path,
        },
    });
}

fn loadDetachedRecordAlloc(allocator: std.mem.Allocator, home: []const u8, inquiry_id: []const u8) !DetachedRecord {
    const path = try stateRecordPath(allocator, home, inquiry_id);
    const raw = try readFileAlloc(allocator, path, MaxInputBytes);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidStateRecord,
    };
    const record = core_json.objectField(root, "session_inquiry_record") orelse root;
    const transport = core_json.objectField(record, "managed_transport") orelse return error.InquiryTransportLost;
    return .{
        .inquiry_id = try allocator.dupe(u8, try requiredString(record, "inquiry_id")),
        .state = try allocator.dupe(u8, try requiredString(record, "state")),
        .receipt_dir = try allocator.dupe(u8, try requiredString(record, "receipt_dir")),
        .state_ref = path,
        .events_ref = try allocator.dupe(u8, try requiredString(record, "events_ref")),
        .summary_ref = try allocator.dupe(u8, try requiredString(record, "summary_ref")),
        .cwd = try allocator.dupe(u8, try requiredString(transport, "cwd")),
        .codex_path = try allocator.dupe(u8, try requiredString(transport, "codex_path")),
        .listen_url = try allocator.dupe(u8, try requiredString(transport, "listen_url")),
        .managed_server_pid = try requiredU64(transport, "managed_server_pid"),
        .codex_version = try allocator.dupe(u8, try requiredString(transport, "codex_version")),
        .schema_fingerprint = try allocator.dupe(u8, try requiredString(transport, "schema_fingerprint")),
        .code_mode_host_redacted = try allocator.dupe(u8, optionalString(transport, "code_mode_host_redacted") orelse ""),
        .code_mode_host_digest = try allocator.dupe(u8, optionalString(transport, "code_mode_host_digest") orelse ""),
        .failure_code = try allocator.dupe(u8, optionalString(record, "failure_code") orelse ""),
        .failure_hint = try allocator.dupe(u8, optionalString(record, "failure_hint") orelse ""),
    };
}

fn executeLaneFork(
    allocator: std.mem.Allocator,
    client: *cas_client.Client,
    options: Options,
    inquiry_cwd: []const u8,
    dcp: Dcp,
    rip: Rip,
    lane: Lane,
    ordinal: u64,
    attempt: u64,
    receipt_dir: []const u8,
    events_path: []const u8,
    preflight: PreflightResult,
) !LaneExecutionResult {
    const handle = try startLaneFork(allocator, client, options, inquiry_cwd, dcp, rip, lane, ordinal, attempt, receipt_dir, events_path, preflight);
    return collectLaneFork(allocator, client, options, dcp, handle);
}

fn executeLaneForkWithRetries(
    allocator: std.mem.Allocator,
    client: *cas_client.Client,
    options: Options,
    inquiry_cwd: []const u8,
    dcp: Dcp,
    rip: Rip,
    lane: Lane,
    ordinal: u64,
    receipt_dir: []const u8,
    events_path: []const u8,
    preflight: PreflightResult,
    launched: *u64,
    initial_handle: ?LaneHandle,
) !bool {
    const max_attempts: u64 = 3;
    var attempt: u64 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const result = if (attempt == 0 and initial_handle != null)
            try collectLaneFork(allocator, client, options, dcp, initial_handle.?)
        else blk: {
            if (launched.* >= rip.max_forks) {
                try appendLaneRetryEvent(allocator, events_path, lane.lane_id, ordinal, attempt, "fork_budget_exhausted");
                return false;
            }
            launched.* += 1;
            const lane_event = try stringifyAnyAlloc(allocator, .{
                .event = "lane_start_attempt",
                .lane_id = lane.lane_id,
                .ordinal = ordinal + 1,
                .attempt = attempt + 1,
                .lineage_mode = lineageMode(dcp).asString(),
                .forks_launched = launched.*,
                .max_forks = rip.max_forks,
            });
            defer allocator.free(lane_event);
            try appendLine(events_path, lane_event);
            break :blk executeLaneFork(allocator, client, options, inquiry_cwd, dcp, rip, lane, ordinal, attempt, receipt_dir, events_path, preflight) catch |err| {
                if (attempt + 1 < max_attempts and isRetryableLaneError(err) and launched.* < rip.max_forks) {
                    try appendLaneRetryEvent(allocator, events_path, lane.lane_id, ordinal, attempt + 1, @errorName(err));
                    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(1500), .awake) catch {};
                    continue;
                }
                return err;
            };
        };
        if (result.receipt_valid) return true;
        if (result.retryable and attempt + 1 < max_attempts and launched.* < rip.max_forks) {
            try appendLaneRetryEvent(allocator, events_path, lane.lane_id, ordinal, attempt + 1, "empty_interrupted_turn");
            std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(1500), .awake) catch {};
            continue;
        }
        return false;
    }
    return false;
}

fn appendLaneRetryEvent(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    lane_id: []const u8,
    ordinal: u64,
    attempt: u64,
    reason: []const u8,
) !void {
    const event = try stringifyAnyAlloc(allocator, .{
        .event = "lane_retry",
        .lane_id = lane_id,
        .ordinal = ordinal + 1,
        .attempt = attempt,
        .next_attempt = attempt + 1,
        .reason = reason,
    });
    defer allocator.free(event);
    try appendLine(events_path, event);
}

fn isRetryableLaneError(err: anyerror) bool {
    return switch (err) {
        error.RequestFailed,
        error.AppServerClosed,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.EndOfStream,
        error.InquiryTransportLost,
        error.ForkFailed,
        => true,
        else => false,
    };
}

fn startLaneFork(
    allocator: std.mem.Allocator,
    client: *cas_client.Client,
    options: Options,
    inquiry_cwd: []const u8,
    dcp: Dcp,
    rip: Rip,
    lane: Lane,
    ordinal: u64,
    attempt: u64,
    receipt_dir: []const u8,
    events_path: []const u8,
    preflight: PreflightResult,
) !LaneHandle {
    if (dcp.source_thread_id == null) {
        return startRolloutTranscriptLane(allocator, client, options, inquiry_cwd, dcp, rip, lane, ordinal, receipt_dir, events_path, preflight);
    }
    const source_thread_id = dcp.source_thread_id orelse return error.SourceNotFound;
    const anchor = anchorForHorizon(dcp, lane.temporal_horizon) orelse return error.AnchorDigestMismatch;
    if (!anchor.available) return error.AnchorDigestMismatch;
    const lane_stem = if (attempt == 0)
        try std.fmt.allocPrint(allocator, "{s}-{d}", .{ lane.lane_id, ordinal + 1 })
    else
        try std.fmt.allocPrint(allocator, "{s}-{d}-attempt-{d}", .{ lane.lane_id, ordinal + 1, attempt + 1 });
    defer allocator.free(lane_stem);
    const lane_events = try std.fmt.allocPrint(allocator, "{s}/lanes/{s}.events.jsonl", .{ receipt_dir, lane_stem });
    const lane_final = try std.fmt.allocPrint(allocator, "{s}/lanes/{s}.final.txt", .{ receipt_dir, lane_stem });
    const lane_receipt = try std.fmt.allocPrint(allocator, "{s}/lanes/{s}.json", .{ receipt_dir, lane_stem });
    const lane_state_leaf = try std.fmt.allocPrint(allocator, "lanes/{s}.json", .{lane_stem});
    defer allocator.free(lane_state_leaf);
    const lane_state_ref = try inquiryPathJoin(allocator, options.home, rip.inquiry_id, lane_state_leaf);
    if (!preflight.capabilities.paginatedAnchorSupported()) return error.ForkUnsupported;
    const source_history = try readThreadHistorySnapshot(
        allocator,
        client,
        source_thread_id,
        dcp.total_turns,
        lane_events,
    );
    defer source_history.deinit(allocator);
    const before_digest = source_history.digest;
    if (before_digest.count != dcp.total_turns or !std.mem.eql(u8, before_digest.digest, dcp.source_turn_digest)) {
        try appendSourceDigestMismatchEvent(allocator, lane_events, before_digest, dcp.total_turns, dcp.source_turn_digest, "source_stale");
        return error.SourceStale;
    }
    const keep_count: usize = @intCast(anchor.keep_through_turn_index);
    if (keep_count > source_history.turn_ids.len) return error.SourceStale;
    const boundary_kind: []const u8 = if (keep_count == 0) "beforeTurnId" else "lastTurnId";
    const boundary_turn_id = if (keep_count == 0)
        source_history.turn_ids[0]
    else blk: {
        if (!source_history.completed_boundaries[keep_count - 1]) return error.DecisionAnchorUnavailable;
        break :blk source_history.turn_ids[keep_count - 1];
    };
    const boundary_event = try stringifyAnyAlloc(allocator, .{
        .event = "thread/fork/boundary_selected",
        .source_thread_id = source_thread_id,
        .history_mode = @tagName(source_history.mode),
        .boundary_kind = boundary_kind,
        .boundary_turn_id = boundary_turn_id,
        .keep_through_turn_index = anchor.keep_through_turn_index,
        .expected_anchor_digest = anchor.anchor_digest orelse "",
    });
    defer allocator.free(boundary_event);
    try appendLine(lane_events, boundary_event);

    const fork_params = if (keep_count == 0)
        try stringifyAnyAlloc(allocator, .{
            .threadId = source_thread_id,
            .beforeTurnId = boundary_turn_id,
            .ephemeral = true,
            .excludeTurns = true,
            .cwd = inquiry_cwd,
            .model = options.model,
            .modelProvider = options.model_provider,
            .serviceTier = options.service_tier,
            .sandbox = options.sandbox,
            .approvalPolicy = "never",
            .baseInstructions = baseInquiryInstructions,
            .developerInstructions = lane.prompt_template,
            .runtimeWorkspaceRoots = [_][]const u8{},
            .threadSource = "retrace",
        })
    else
        try stringifyAnyAlloc(allocator, .{
            .threadId = source_thread_id,
            .lastTurnId = boundary_turn_id,
            .ephemeral = true,
            .excludeTurns = true,
            .cwd = inquiry_cwd,
            .model = options.model,
            .modelProvider = options.model_provider,
            .serviceTier = options.service_tier,
            .sandbox = options.sandbox,
            .approvalPolicy = "never",
            .baseInstructions = baseInquiryInstructions,
            .developerInstructions = lane.prompt_template,
            .runtimeWorkspaceRoots = [_][]const u8{},
            .threadSource = "retrace",
        });
    defer allocator.free(fork_params);
    const fork_json = client.requestJson("thread/fork", fork_params) catch {
        if (client.lastError()) |detail| try appendLine(lane_events, detail);
        return error.ForkFailed;
    };
    defer allocator.free(fork_json);
    const fork_event = try stringifyAnyAlloc(allocator, .{ .event = "thread/fork", .lane_id = lane.lane_id, .ordinal = ordinal + 1 });
    defer allocator.free(fork_event);
    try appendLine(events_path, fork_event);
    try appendLine(lane_events, fork_json);
    const fork_thread_id = try threadIdFromResponse(allocator, fork_json);
    const forked_from = try forkedFromIdFromResponse(allocator, fork_json);
    defer if (forked_from) |value| allocator.free(value);
    const fork_policy = try forkPolicyProofFromResponse(allocator, fork_json, options.permissions);
    if (forked_from == null or !std.mem.eql(u8, forked_from.?, source_thread_id)) {
        try persistLaneHandleSnapshot(allocator, options, inquiry_cwd, dcp, rip, lane, ordinal, lane_events, lane_final, lane_receipt, lane_state_ref, fork_thread_id, forked_from, "", "", before_digest, before_digest, anchor, fork_policy, preflight, client.blockingServerRequestCount(), @tagName(InquiryState.failed));
        return error.LineageMismatch;
    }
    const anchored_history = try readThreadHistorySnapshot(
        allocator,
        client,
        fork_thread_id,
        anchor.keep_through_turn_index,
        lane_events,
    );
    defer anchored_history.deinit(allocator);
    const anchored_digest = anchored_history.digest;
    const anchor_valid = anchored_digest.count == anchor.keep_through_turn_index and
        std.mem.eql(u8, anchored_digest.digest, anchor.anchor_digest orelse "");
    if (!anchor_valid) {
        try persistLaneHandleSnapshot(allocator, options, inquiry_cwd, dcp, rip, lane, ordinal, lane_events, lane_final, lane_receipt, lane_state_ref, fork_thread_id, forked_from, "", "", before_digest, anchored_digest, anchor, fork_policy, preflight, client.blockingServerRequestCount(), @tagName(InquiryState.failed));
        return error.AnchorDigestMismatch;
    }

    const client_msg_id = try std.fmt.allocPrint(allocator, "cas-{s}-{s}-{d}", .{ rip.inquiry_id, lane.lane_id, ordinal + 1 });
    const turn_text = try buildInquiryPromptAlloc(allocator, rip, lane);
    defer allocator.free(turn_text);
    const turn_params = try stringifyAnyAlloc(allocator, .{
        .threadId = fork_thread_id,
        .clientUserMessageId = client_msg_id,
        .input = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = turn_text }},
        .approvalPolicy = "never",
        .sandbox = options.sandbox,
        .model = options.model,
        .serviceTier = options.service_tier,
        .runtimeWorkspaceRoots = [_][]const u8{},
    });
    defer allocator.free(turn_params);
    const policy_request_count_before_turn = client.blockingServerRequestCount();
    var notifications: std.ArrayList([]u8) = .empty;
    defer {
        for (notifications.items) |line| allocator.free(line);
        notifications.deinit(allocator);
    }
    const turn_json = client.requestJsonCaptureNotifications("turn/start", turn_params, &notifications) catch {
        if (client.lastError()) |detail| try appendLine(lane_events, detail);
        _ = cleanupForkThreadIdWithMethod(allocator, client, lane_events, fork_thread_id, "thread/delete") or cleanupForkThreadIdWithMethod(allocator, client, lane_events, fork_thread_id, "thread/archive");
        return error.TurnStartFailed;
    };
    defer allocator.free(turn_json);
    try appendLine(lane_events, turn_json);
    for (notifications.items) |line| try appendLine(lane_events, line);
    const turn_id = try turnIdFromStartResponse(allocator, turn_json);

    const handle = try buildLaneHandleSnapshot(allocator, options, inquiry_cwd, dcp, rip, lane, ordinal, lane_events, lane_final, lane_receipt, lane_state_ref, fork_thread_id, forked_from, turn_id, client_msg_id, before_digest, anchored_digest, anchor, fork_policy, preflight, policy_request_count_before_turn);
    writeLaneHandle(allocator, handle, @tagName(InquiryState.turn_running)) catch |err| {
        std.debug.print("writeLaneHandle failed: {s}\n", .{@errorName(err)});
        return err;
    };
    return handle;
}

fn startRolloutTranscriptLane(
    allocator: std.mem.Allocator,
    client: *cas_client.Client,
    options: Options,
    inquiry_cwd: []const u8,
    dcp: Dcp,
    rip: Rip,
    lane: Lane,
    ordinal: u64,
    receipt_dir: []const u8,
    events_path: []const u8,
    preflight: PreflightResult,
) !LaneHandle {
    const anchor = anchorForHorizon(dcp, lane.temporal_horizon) orelse return error.AnchorDigestMismatch;
    if (!anchor.available) return error.AnchorDigestMismatch;
    const lane_stem = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ lane.lane_id, ordinal + 1 });
    defer allocator.free(lane_stem);
    const lane_events = try std.fmt.allocPrint(allocator, "{s}/lanes/{s}.events.jsonl", .{ receipt_dir, lane_stem });
    const lane_final = try std.fmt.allocPrint(allocator, "{s}/lanes/{s}.final.txt", .{ receipt_dir, lane_stem });
    const lane_receipt = try std.fmt.allocPrint(allocator, "{s}/lanes/{s}.json", .{ receipt_dir, lane_stem });
    const lane_state_leaf = try std.fmt.allocPrint(allocator, "lanes/{s}.json", .{lane_stem});
    defer allocator.free(lane_state_leaf);
    const lane_state_ref = try inquiryPathJoin(allocator, options.home, rip.inquiry_id, lane_state_leaf);

    const start_params = try stringifyAnyAlloc(allocator, .{
        .cwd = inquiry_cwd,
        .experimentalRawEvents = false,
    });
    defer allocator.free(start_params);
    var start_notifications: std.ArrayList([]u8) = .empty;
    defer {
        for (start_notifications.items) |line| allocator.free(line);
        start_notifications.deinit(allocator);
    }
    const start_json = client.requestJsonCaptureNotifications("thread/start", start_params, &start_notifications) catch return error.ForkFailed;
    defer allocator.free(start_json);
    const start_event = try stringifyAnyAlloc(allocator, .{ .event = "thread/start", .lane_id = lane.lane_id, .ordinal = ordinal + 1, .lineage_mode = "rollout_transcript" });
    defer allocator.free(start_event);
    try appendLine(events_path, start_event);
    try appendLine(lane_events, start_json);
    for (start_notifications.items) |line| try appendLine(lane_events, line);
    const thread_id = try threadIdFromResponse(allocator, start_json);

    const client_msg_id = try std.fmt.allocPrint(allocator, "cas-{s}-{s}-{d}", .{ rip.inquiry_id, lane.lane_id, ordinal + 1 });
    const turn_text = try buildRolloutInquiryPromptAlloc(allocator, dcp, rip, lane, anchor);
    defer allocator.free(turn_text);
    const turn_params = try stringifyAnyAlloc(allocator, .{
        .threadId = thread_id,
        .clientUserMessageId = client_msg_id,
        .input = [_]struct { type: []const u8, text: []const u8 }{.{ .type = "text", .text = turn_text }},
        .approvalPolicy = "never",
        .sandbox = options.sandbox,
        .model = options.model,
        .serviceTier = options.service_tier,
        .runtimeWorkspaceRoots = [_][]const u8{},
    });
    defer allocator.free(turn_params);
    const policy_request_count_before_turn = client.blockingServerRequestCount();
    var notifications: std.ArrayList([]u8) = .empty;
    defer {
        for (notifications.items) |line| allocator.free(line);
        notifications.deinit(allocator);
    }
    const turn_json = client.requestJsonCaptureNotifications("turn/start", turn_params, &notifications) catch {
        if (client.lastError()) |detail| try appendLine(lane_events, detail);
        return error.TurnStartFailed;
    };
    defer allocator.free(turn_json);
    try appendLine(lane_events, turn_json);
    for (notifications.items) |line| try appendLine(lane_events, line);
    const turn_id = try turnIdFromStartResponse(allocator, turn_json);

    const before_digest = TurnDigest{ .count = dcp.total_turns, .digest = dcp.source_turn_digest };
    const anchored_digest = TurnDigest{ .count = anchor.keep_through_turn_index, .digest = anchor.anchor_digest orelse "" };
    const fork_policy = ForkPolicyProof{ .ephemeral = true, .read_only = true, .approval_never = true };
    const handle = try buildLaneHandleSnapshot(allocator, options, inquiry_cwd, dcp, rip, lane, ordinal, lane_events, lane_final, lane_receipt, lane_state_ref, thread_id, "", turn_id, client_msg_id, before_digest, anchored_digest, anchor, fork_policy, preflight, policy_request_count_before_turn);
    try writeLaneHandle(allocator, handle, @tagName(InquiryState.turn_running));
    return handle;
}

fn persistLaneHandleSnapshot(
    allocator: std.mem.Allocator,
    options: Options,
    inquiry_cwd: []const u8,
    dcp: Dcp,
    rip: Rip,
    lane: Lane,
    ordinal: u64,
    lane_events: []const u8,
    lane_final: []const u8,
    lane_receipt: []const u8,
    lane_state_ref: []const u8,
    fork_thread_id: []const u8,
    forked_from: ?[]const u8,
    turn_id: []const u8,
    client_msg_id: []const u8,
    before_digest: TurnDigest,
    anchored_digest: TurnDigest,
    anchor: Anchor,
    fork_policy: ForkPolicyProof,
    preflight: PreflightResult,
    policy_request_count_before: u64,
    state: []const u8,
) !void {
    const handle = try buildLaneHandleSnapshot(allocator, options, inquiry_cwd, dcp, rip, lane, ordinal, lane_events, lane_final, lane_receipt, lane_state_ref, fork_thread_id, forked_from, turn_id, client_msg_id, before_digest, anchored_digest, anchor, fork_policy, preflight, policy_request_count_before);
    try writeLaneHandle(allocator, handle, state);
}

fn buildLaneHandleSnapshot(
    allocator: std.mem.Allocator,
    options: Options,
    inquiry_cwd: []const u8,
    dcp: Dcp,
    rip: Rip,
    lane: Lane,
    ordinal: u64,
    lane_events: []const u8,
    lane_final: []const u8,
    lane_receipt: []const u8,
    lane_state_ref: []const u8,
    fork_thread_id: []const u8,
    forked_from: ?[]const u8,
    turn_id: []const u8,
    client_msg_id: []const u8,
    before_digest: TurnDigest,
    anchored_digest: TurnDigest,
    anchor: Anchor,
    fork_policy: ForkPolicyProof,
    preflight: PreflightResult,
    policy_request_count_before: u64,
) !LaneHandle {
    const source_thread_id = dcp.source_thread_id orelse "";
    return .{
        .inquiry_id = try allocator.dupe(u8, rip.inquiry_id),
        .lane_id = try allocator.dupe(u8, lane.lane_id),
        .inquiry_mode = try allocator.dupe(u8, lane.inquiry_mode),
        .temporal_horizon = try allocator.dupe(u8, lane.temporal_horizon),
        .question = try allocator.dupe(u8, lane.prompt_template),
        .ordinal = ordinal + 1,
        .source_thread_id = try allocator.dupe(u8, source_thread_id),
        .fork_thread_id = try allocator.dupe(u8, fork_thread_id),
        .forked_from_id = if (forked_from) |value| try allocator.dupe(u8, value) else try allocator.dupe(u8, source_thread_id),
        .turn_id = try allocator.dupe(u8, turn_id),
        .client_user_message_id = try allocator.dupe(u8, client_msg_id),
        .lane_events = try allocator.dupe(u8, lane_events),
        .lane_final = try allocator.dupe(u8, lane_final),
        .lane_receipt = try allocator.dupe(u8, lane_receipt),
        .lane_state_ref = try allocator.dupe(u8, lane_state_ref),
        .workspace_cwd = try allocator.dupe(u8, inquiry_cwd),
        .model = try allocator.dupe(u8, options.model orelse dcp.source_model orelse ""),
        .model_provider = try allocator.dupe(u8, options.model_provider orelse dcp.source_model_provider orelse ""),
        .service_tier = try allocator.dupe(u8, options.service_tier orelse ""),
        .codex_version = try allocator.dupe(u8, preflight.codex_version),
        .schema_fingerprint = try allocator.dupe(u8, preflight.schema_fingerprint),
        .policy_request_count_before = policy_request_count_before,
        .turns_before = before_digest.count,
        .turns_dropped = anchor.drop_last_n_turns,
        .turns_after = anchored_digest.count,
        .anchor_digest_expected = try allocator.dupe(u8, anchor.anchor_digest orelse ""),
        .anchor_digest_observed = try allocator.dupe(u8, anchored_digest.digest),
        .expected_hindsight = std.mem.eql(u8, lane.temporal_horizon, "outcome_aware"),
        .fork_policy = fork_policy,
    };
}

/// Serializes the packaged FIR-v1 envelope used by live session-inquiry lanes.
/// Keeping one serializer at this boundary prevents callers from accepting a
/// fixture shape that the packaged CAS command cannot emit.
pub fn packagedFirReceiptJsonAlloc(allocator: std.mem.Allocator, fields: anytype) ![]u8 {
    const receipt = .{
        .fork_inquiry_receipt = .{
            .receipt_version = "FIR-v1",
            .receipt_id = fields.receipt_id,
            .inquiry_id = fields.inquiry_id,
            .lane_id = fields.lane_id,
            .source = .{
                .capsule_id = fields.capsule_id,
                .source_episode_id = fields.source_episode_id,
                .source_thread_id = fields.source_thread_id,
                .source_thread_id_present = fields.source_thread_id_present,
                .source_rollout_path = fields.source_rollout_path,
                .source_artifact_reconstructability = fields.source_artifact_reconstructability,
                .source_turn_digest = fields.source_turn_digest,
                .lineage_mode = fields.lineage_mode,
            },
            .fork = .{
                .lineage_mode = fields.lineage_mode,
                .fork_thread_id = fields.fork_thread_id,
                .forked_from_id = fields.forked_from_id,
                .anchor = .{
                    .temporal_horizon = fields.temporal_horizon,
                    .turns_before = fields.turns_before,
                    .turns_dropped = fields.turns_dropped,
                    .turns_after = fields.turns_after,
                    .anchor_digest_expected = fields.anchor_digest_expected,
                    .anchor_digest_observed = fields.anchor_digest_observed,
                    .exact = fields.anchor_exact,
                },
                .model = fields.model,
                .model_provider = fields.model_provider,
                .service_tier = fields.service_tier,
                .codex_version = fields.codex_version,
                .ephemeral = fields.ephemeral,
                .permissions = fields.permissions,
                .sandbox = fields.sandbox,
                .approval_policy = "never",
                .hooks = fields.hooks,
                .multi_agent_mode = "explicit-request-only",
            },
            .workspace_reconstruction = .{
                .mode = fields.workspace_mode,
                .path = fields.workspace_path,
                .head_exact = false,
                .dirty_state_exact = false,
                .dependencies_exact = false,
                .generated_artifacts_exact = false,
                .tools_allowed = false,
                .network_allowed = false,
                .limitations = [_][]const u8{"live workspace equivalence proof is not implemented in this controller slice"},
            },
            .inquiry = .{
                .mode = fields.inquiry_mode,
                .question = fields.question,
                .evidence_allowed = [_][]const u8{},
                .evidence_withheld = [_][]const u8{},
                .client_user_message_id = fields.client_user_message_id,
                .turn_id = fields.turn_id,
                .started_at = fields.started_at,
                .ended_at = fields.ended_at,
                .status = fields.status,
                .token_usage = .{},
            },
            .answer = .{
                .reconstructed_decision = fields.reconstructed_decision,
                .selected_route = fields.selected_route,
                .rejected_routes = fields.rejected_routes,
                .evidence_refs = fields.evidence_refs,
                .assumptions = fields.assumptions,
                .alternatives = fields.alternatives,
                .route_flip_conditions = fields.route_flip_conditions,
                .uncertainty = fields.uncertainty,
                .hindsight_available = fields.hindsight_available,
                .unsupported_claims = fields.unsupported_claims,
                .final_text_ref = fields.final_text_ref,
            },
            .lifecycle = .{
                .event_log_ref = fields.event_log_ref,
                .interrupted = false,
                .archived = fields.archived,
                .deleted = fields.deleted,
                .cleanup_status = fields.cleanup_status,
            },
            .gate = .{
                .lineage_valid = true,
                .anchor_valid = fields.anchor_exact,
                .permissions_valid = fields.permissions_valid,
                .approval_or_tool_request_observed = fields.approval_or_tool_request_observed,
                .hindsight_label_valid = fields.hindsight_label_valid,
                .answer_complete = fields.answer_complete,
                .receipt_valid = fields.receipt_valid,
            },
        },
    };
    return stringifyAnyAlloc(allocator, receipt);
}

fn collectLaneFork(
    allocator: std.mem.Allocator,
    client: *cas_client.Client,
    options: Options,
    dcp: Dcp,
    handle: LaneHandle,
) !LaneExecutionResult {
    const observed = try waitForTurnObservation(allocator, client, handle.fork_thread_id, handle.turn_id, options.timeout_ms, handle.lane_events);
    const final_text = if (observed.final_text.len > 0) observed.final_text else "";
    try durable_store.writeTextAtomic(allocator, handle.lane_final, final_text);
    const parsed_answer = parseFiaAnswerAlloc(allocator, final_text, handle.expected_hindsight) catch null;
    const policy_request_observed = client.blockingServerRequestCount() > handle.policy_request_count_before;
    const blocking_event = observed.blocking_event or policy_request_observed;
    const answer_complete = parsed_answer != null and observed.terminal and std.mem.eql(u8, observed.status, "completed") and !blocking_event;
    const anchor_valid = std.mem.eql(u8, handle.anchor_digest_observed, handle.anchor_digest_expected);
    const fork_deleted = !handle.fork_policy.ephemeral and cleanupForkWithMethod(allocator, client, handle, "thread/delete");
    const fork_archived = !handle.fork_policy.ephemeral and !fork_deleted and cleanupForkWithMethod(allocator, client, handle, "thread/archive");
    const cleanup_valid = handle.fork_policy.ephemeral or handle.fork_cleaned or fork_deleted or fork_archived;
    const receipt_valid = answer_complete and anchor_valid and handle.fork_policy.safe() and cleanup_valid;
    var completed_handle = handle;
    completed_handle.fork_cleaned = cleanup_valid;

    const receipt = .{
        .fork_inquiry_receipt = .{
            .receipt_version = "FIR-v1",
            .receipt_id = try std.fmt.allocPrint(allocator, "FIR-{s}-{d}", .{ handle.lane_id, handle.ordinal }),
            .inquiry_id = handle.inquiry_id,
            .lane_id = handle.lane_id,
            .source = .{
                .capsule_id = dcp.packet_id,
                .source_episode_id = dcp.source_episode_id,
                .source_thread_id = handle.source_thread_id,
                .source_thread_id_present = dcp.source_thread_id != null,
                .source_rollout_path = dcp.source_rollout_path orelse "",
                .source_artifact_reconstructability = dcp.reconstructability,
                .source_turn_digest = dcp.source_turn_digest,
                .lineage_mode = lineageMode(dcp).asString(),
            },
            .fork = .{
                .lineage_mode = lineageMode(dcp).asString(),
                .fork_thread_id = handle.fork_thread_id,
                .forked_from_id = handle.forked_from_id,
                .anchor = .{
                    .temporal_horizon = handle.temporal_horizon,
                    .turns_before = handle.turns_before,
                    .turns_dropped = handle.turns_dropped,
                    .turns_after = handle.turns_after,
                    .anchor_digest_expected = handle.anchor_digest_expected,
                    .anchor_digest_observed = handle.anchor_digest_observed,
                    .exact = anchor_valid,
                },
                .model = handle.model,
                .model_provider = handle.model_provider,
                .service_tier = handle.service_tier,
                .codex_version = handle.codex_version,
                .ephemeral = handle.fork_policy.ephemeral,
                .permissions = options.permissions,
                .sandbox = options.sandbox,
                .approval_policy = "never",
                .hooks = options.hooks,
                .multi_agent_mode = "explicit-request-only",
            },
            .workspace_reconstruction = .{
                .mode = if (lineageMode(dcp) == .rollout_transcript) "transcript_only" else dcp.reconstructability,
                .path = handle.workspace_cwd,
                .head_exact = false,
                .dirty_state_exact = false,
                .dependencies_exact = false,
                .generated_artifacts_exact = false,
                .tools_allowed = false,
                .network_allowed = false,
                .limitations = [_][]const u8{"live workspace equivalence proof is not implemented in this controller slice"},
            },
            .inquiry = .{
                .mode = handle.inquiry_mode,
                .question = handle.question,
                .evidence_allowed = [_][]const u8{},
                .evidence_withheld = [_][]const u8{},
                .client_user_message_id = handle.client_user_message_id,
                .turn_id = handle.turn_id,
                .started_at = nowMillis(),
                .ended_at = nowMillis(),
                .status = if (std.mem.eql(u8, observed.status, "inProgress")) "timeout" else observed.status,
                .token_usage = .{},
            },
            .answer = .{
                .reconstructed_decision = if (parsed_answer) |answer| answer.reconstructed_decision else "",
                .selected_route = if (parsed_answer) |answer| answer.selected_route else "",
                .rejected_routes = if (parsed_answer) |answer| answer.rejected_routes else &[_][]const u8{},
                .evidence_refs = if (parsed_answer) |answer| answer.evidence_refs else &[_][]const u8{},
                .assumptions = if (parsed_answer) |answer| answer.assumptions else &[_][]const u8{},
                .alternatives = if (parsed_answer) |answer| answer.alternatives else &[_][]const u8{},
                .route_flip_conditions = if (parsed_answer) |answer| answer.route_flip_conditions else &[_][]const u8{},
                .uncertainty = if (parsed_answer) |answer| answer.uncertainty else "",
                .hindsight_available = if (parsed_answer) |answer| answer.hindsight_available else handle.expected_hindsight,
                .unsupported_claims = if (parsed_answer) |answer| answer.unsupported_claims else &[_][]const u8{"answer parsing did not complete"},
                .final_text_ref = handle.lane_final,
            },
            .lifecycle = .{
                .event_log_ref = handle.lane_events,
                .interrupted = false,
                .archived = fork_archived,
                .deleted = fork_deleted,
                .cleanup_status = if (handle.fork_policy.ephemeral) "ephemeral_runtime_closed" else if (handle.fork_cleaned) "already_cleaned" else if (cleanup_valid) "persisted_fallback_cleaned" else "cleanup_failed",
            },
            .gate = .{
                .lineage_valid = true,
                .anchor_valid = anchor_valid,
                .permissions_valid = handle.fork_policy.safe(),
                .approval_or_tool_request_observed = blocking_event,
                .hindsight_label_valid = parsed_answer != null,
                .answer_complete = answer_complete,
                .receipt_valid = receipt_valid,
            },
        },
    };
    defer allocator.free(receipt.fork_inquiry_receipt.receipt_id);
    const fir = receipt.fork_inquiry_receipt;
    const receipt_json = try packagedFirReceiptJsonAlloc(allocator, .{
        .receipt_id = fir.receipt_id,
        .inquiry_id = fir.inquiry_id,
        .lane_id = fir.lane_id,
        .capsule_id = fir.source.capsule_id,
        .source_episode_id = fir.source.source_episode_id,
        .source_thread_id = fir.source.source_thread_id,
        .source_thread_id_present = fir.source.source_thread_id_present,
        .source_rollout_path = fir.source.source_rollout_path,
        .source_artifact_reconstructability = fir.source.source_artifact_reconstructability,
        .source_turn_digest = fir.source.source_turn_digest,
        .lineage_mode = fir.source.lineage_mode,
        .fork_thread_id = fir.fork.fork_thread_id,
        .forked_from_id = fir.fork.forked_from_id,
        .temporal_horizon = fir.fork.anchor.temporal_horizon,
        .turns_before = fir.fork.anchor.turns_before,
        .turns_dropped = fir.fork.anchor.turns_dropped,
        .turns_after = fir.fork.anchor.turns_after,
        .anchor_digest_expected = fir.fork.anchor.anchor_digest_expected,
        .anchor_digest_observed = fir.fork.anchor.anchor_digest_observed,
        .anchor_exact = fir.fork.anchor.exact,
        .model = fir.fork.model,
        .model_provider = fir.fork.model_provider,
        .service_tier = fir.fork.service_tier,
        .codex_version = fir.fork.codex_version,
        .ephemeral = fir.fork.ephemeral,
        .permissions = fir.fork.permissions,
        .sandbox = fir.fork.sandbox,
        .hooks = fir.fork.hooks,
        .workspace_mode = fir.workspace_reconstruction.mode,
        .workspace_path = fir.workspace_reconstruction.path,
        .inquiry_mode = fir.inquiry.mode,
        .question = fir.inquiry.question,
        .client_user_message_id = fir.inquiry.client_user_message_id,
        .turn_id = fir.inquiry.turn_id,
        .started_at = fir.inquiry.started_at,
        .ended_at = fir.inquiry.ended_at,
        .status = fir.inquiry.status,
        .reconstructed_decision = fir.answer.reconstructed_decision,
        .selected_route = fir.answer.selected_route,
        .rejected_routes = fir.answer.rejected_routes,
        .evidence_refs = fir.answer.evidence_refs,
        .assumptions = fir.answer.assumptions,
        .alternatives = fir.answer.alternatives,
        .route_flip_conditions = fir.answer.route_flip_conditions,
        .uncertainty = fir.answer.uncertainty,
        .hindsight_available = fir.answer.hindsight_available,
        .unsupported_claims = fir.answer.unsupported_claims,
        .final_text_ref = fir.answer.final_text_ref,
        .event_log_ref = fir.lifecycle.event_log_ref,
        .archived = fir.lifecycle.archived,
        .deleted = fir.lifecycle.deleted,
        .cleanup_status = fir.lifecycle.cleanup_status,
        .permissions_valid = fir.gate.permissions_valid,
        .approval_or_tool_request_observed = fir.gate.approval_or_tool_request_observed,
        .hindsight_label_valid = fir.gate.hindsight_label_valid,
        .answer_complete = fir.gate.answer_complete,
        .receipt_valid = fir.gate.receipt_valid,
    });
    defer allocator.free(receipt_json);
    const receipt_file = try std.fmt.allocPrint(allocator, "{s}\n", .{receipt_json});
    defer allocator.free(receipt_file);
    try durable_store.writeTextAtomic(allocator, handle.lane_receipt, receipt_file);
    try writeLaneHandle(allocator, completed_handle, if (receipt_valid) @tagName(InquiryState.completed) else @tagName(InquiryState.failed));
    return .{
        .receipt_valid = receipt_valid,
        .retryable = !receipt_valid and observed.terminal and std.mem.eql(u8, observed.status, "interrupted") and final_text.len == 0 and !blocking_event,
    };
}

fn writeLaneHandle(allocator: std.mem.Allocator, handle: LaneHandle, state: []const u8) !void {
    const payload = .{
        .session_inquiry_lane = .{
            .record_version = "SIL-v1",
            .state = state,
            .inquiry_id = handle.inquiry_id,
            .lane_id = handle.lane_id,
            .ordinal = handle.ordinal,
            .source_thread_id = handle.source_thread_id,
            .lineage_mode = if (handle.source_thread_id.len == 0) SourceLineageMode.rollout_transcript.asString() else SourceLineageMode.thread_fork.asString(),
            .fork_thread_id = handle.fork_thread_id,
            .forked_from_id = handle.forked_from_id,
            .turn_id = handle.turn_id,
            .client_user_message_id = handle.client_user_message_id,
            .temporal_horizon = handle.temporal_horizon,
            .inquiry_mode = handle.inquiry_mode,
            .question = handle.question,
            .expected_hindsight = handle.expected_hindsight,
            .workspace_cwd = handle.workspace_cwd,
            .model = handle.model,
            .model_provider = handle.model_provider,
            .service_tier = handle.service_tier,
            .codex_version = handle.codex_version,
            .schema_fingerprint = handle.schema_fingerprint,
            .policy_request_count_before = handle.policy_request_count_before,
            .lane_events_ref = handle.lane_events,
            .final_text_ref = handle.lane_final,
            .receipt_ref = handle.lane_receipt,
            .lane_state_ref = handle.lane_state_ref,
            .anchor = .{
                .turns_before = handle.turns_before,
                .turns_dropped = handle.turns_dropped,
                .turns_after = handle.turns_after,
                .anchor_digest_expected = handle.anchor_digest_expected,
                .anchor_digest_observed = handle.anchor_digest_observed,
            },
            .fork_policy = .{
                .ephemeral = handle.fork_policy.ephemeral,
                .read_only = handle.fork_policy.read_only,
                .approval_never = handle.fork_policy.approval_never,
                .cleaned = handle.fork_cleaned,
            },
        },
    };
    try writeJsonFile(allocator, handle.lane_state_ref, payload);
}

fn loadLaneHandleAlloc(allocator: std.mem.Allocator, path: []const u8) !LaneHandle {
    const raw = try readFileAlloc(allocator, path, MaxInputBytes);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidLaneRecord,
    };
    const lane_obj = core_json.objectField(root, "session_inquiry_lane") orelse root;
    const anchor = core_json.objectField(lane_obj, "anchor") orelse return error.InvalidLaneRecord;
    const policy = core_json.objectField(lane_obj, "fork_policy") orelse return error.InvalidLaneRecord;
    return .{
        .inquiry_id = try allocator.dupe(u8, try requiredString(lane_obj, "inquiry_id")),
        .lane_id = try allocator.dupe(u8, try requiredString(lane_obj, "lane_id")),
        .inquiry_mode = try allocator.dupe(u8, try requiredString(lane_obj, "inquiry_mode")),
        .temporal_horizon = try allocator.dupe(u8, try requiredString(lane_obj, "temporal_horizon")),
        .question = try allocator.dupe(u8, try requiredString(lane_obj, "question")),
        .ordinal = try requiredU64(lane_obj, "ordinal"),
        .source_thread_id = try allocator.dupe(u8, try requiredString(lane_obj, "source_thread_id")),
        .fork_thread_id = try allocator.dupe(u8, try requiredString(lane_obj, "fork_thread_id")),
        .forked_from_id = try allocator.dupe(u8, try requiredString(lane_obj, "forked_from_id")),
        .turn_id = try allocator.dupe(u8, try requiredString(lane_obj, "turn_id")),
        .client_user_message_id = try allocator.dupe(u8, try requiredString(lane_obj, "client_user_message_id")),
        .lane_events = try allocator.dupe(u8, try requiredString(lane_obj, "lane_events_ref")),
        .lane_final = try allocator.dupe(u8, try requiredString(lane_obj, "final_text_ref")),
        .lane_receipt = try allocator.dupe(u8, try requiredString(lane_obj, "receipt_ref")),
        .lane_state_ref = try allocator.dupe(u8, try requiredString(lane_obj, "lane_state_ref")),
        .workspace_cwd = try allocator.dupe(u8, try requiredString(lane_obj, "workspace_cwd")),
        .model = try allocator.dupe(u8, optionalString(lane_obj, "model") orelse ""),
        .model_provider = try allocator.dupe(u8, optionalString(lane_obj, "model_provider") orelse ""),
        .service_tier = try allocator.dupe(u8, optionalString(lane_obj, "service_tier") orelse ""),
        .codex_version = try allocator.dupe(u8, try requiredString(lane_obj, "codex_version")),
        .schema_fingerprint = try allocator.dupe(u8, try requiredString(lane_obj, "schema_fingerprint")),
        .policy_request_count_before = optionalU64(lane_obj, "policy_request_count_before") orelse 0,
        .turns_before = try requiredU64(anchor, "turns_before"),
        .turns_dropped = try requiredU64(anchor, "turns_dropped"),
        .turns_after = try requiredU64(anchor, "turns_after"),
        .anchor_digest_expected = try allocator.dupe(u8, try requiredString(anchor, "anchor_digest_expected")),
        .anchor_digest_observed = try allocator.dupe(u8, try requiredString(anchor, "anchor_digest_observed")),
        .expected_hindsight = try requiredBool(lane_obj, "expected_hindsight"),
        .fork_policy = .{
            .ephemeral = try requiredBool(policy, "ephemeral"),
            .read_only = try requiredBool(policy, "read_only"),
            .approval_never = try requiredBool(policy, "approval_never"),
        },
        .fork_cleaned = optionalBool(policy, "cleaned") orelse false,
    };
}

const baseInquiryInstructions =
    \\This is a reconstruction experiment over visible historical context only.
    \\Do not claim hidden historical certainty. Do not mutate files, run external
    \\communication, or request approval escalation. Return only the required
    \\FIA-v1 structured answer and cite evidence references.
;

fn buildInquiryPromptAlloc(allocator: std.mem.Allocator, rip: Rip, lane: Lane) ![]const u8 {
    const hindsight_literal = if (std.mem.eql(u8, lane.temporal_horizon, "outcome_aware")) "true" else "false";
    return std.fmt.allocPrint(allocator,
        \\fork_inquiry_request:
        \\  objective: {s}
        \\  lane_id: {s}
        \\  inquiry_mode: {s}
        \\  temporal_horizon: {s}
        \\caller_objective:
        \\---
        \\{s}
        \\---
        \\
        \\Return only one JSON object. Do not include Echo, markdown fences, prose, or private reasoning.
        \\The JSON must match this shape exactly:
        \\{{
        \\  "fork_inquiry_answer": {{
        \\    "answer_version": "FIA-v1",
        \\    "reconstructed_decision": "<concise answer to the lane question>",
        \\    "selected_route": "<selected route, verdict, or closure decision>",
        \\    "rejected_routes": [],
        \\    "evidence_refs": [],
        \\    "assumptions": [],
        \\    "alternatives": [],
        \\    "route_flip_conditions": [],
        \\    "uncertainty": "low|medium|high",
        \\    "hindsight_available": {s},
        \\    "unsupported_claims": []
        \\  }}
        \\}}
        \\
    , .{ rip.objective, lane.lane_id, lane.inquiry_mode, lane.temporal_horizon, lane.prompt_template, hindsight_literal });
}

fn buildRolloutInquiryPromptAlloc(allocator: std.mem.Allocator, dcp: Dcp, rip: Rip, lane: Lane, anchor: Anchor) ![]const u8 {
    const rollout_path = dcp.source_rollout_path orelse return error.SourceNotFound;
    var trace = try canonical_trace.parseSessionTrace(allocator, rollout_path, .{});
    defer trace.deinit(allocator);
    const hindsight_literal = if (std.mem.eql(u8, lane.temporal_horizon, "outcome_aware")) "true" else "false";

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print(
        \\fork_inquiry_request:
        \\  objective: {s}
        \\  lane_id: {s}
        \\  inquiry_mode: {s}
        \\  temporal_horizon: {s}
        \\  lineage_mode: rollout_transcript
        \\  visible_turns_retained: {d}
        \\caller_objective:
        \\---
        \\{s}
        \\---
        \\
        \\visible_historical_context:
        \\
    , .{ rip.objective, lane.lane_id, lane.inquiry_mode, lane.temporal_horizon, anchor.keep_through_turn_index, lane.prompt_template });
    for (trace.turns.items) |turn| {
        if (turn.turn_index > @as(i64, @intCast(anchor.keep_through_turn_index))) continue;
        try writer.print("- turn_index: {d}\n  turn_id: {s}\n", .{ turn.turn_index, turn.turn_id });
        if (turn.user_message) |text| {
            try writer.writeAll("  user_message: |-\n");
            try writeIndentedExcerpt(writer, text, 4, 2000);
        }
        if (turn.final_answer) |text| {
            try writer.writeAll("  assistant_final: |-\n");
            try writeIndentedExcerpt(writer, text, 4, 2000);
        }
    }
    try writer.writeAll(
        \\
        \\Return only one JSON object. Do not include Echo, markdown fences, prose, or private reasoning.
        \\The JSON must match this shape exactly:
    );
    try writer.print(
        \\{{
        \\  "fork_inquiry_answer": {{
        \\    "answer_version": "FIA-v1",
        \\    "reconstructed_decision": "<concise answer to the lane question>",
        \\    "selected_route": "<selected route, verdict, or closure decision>",
        \\    "rejected_routes": [],
        \\    "evidence_refs": [],
        \\    "assumptions": [],
        \\    "alternatives": [],
        \\    "route_flip_conditions": [],
        \\    "uncertainty": "low|medium|high",
        \\    "hindsight_available": {s},
        \\    "unsupported_claims": []
        \\  }}
        \\}}
        \\
    , .{hindsight_literal});
    return try out.toOwnedSlice();
}

fn writeIndentedExcerpt(writer: anytype, text: []const u8, indent: usize, max_bytes: usize) !void {
    const retained = if (text.len > max_bytes) text[0..max_bytes] else text;
    var remaining = retained;
    while (remaining.len > 0) {
        for (0..indent) |_| try writer.writeByte(' ');
        const newline = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
        try writer.writeAll(remaining[0..newline]);
        if (newline < remaining.len) {
            try writer.writeByte('\n');
            remaining = remaining[newline + 1 ..];
        } else {
            remaining = remaining[newline..];
        }
    }
    if (text.len > max_bytes) try writer.writeAll("\n    [truncated]\n") else try writer.writeByte('\n');
}

fn waitForTurnObservation(
    allocator: std.mem.Allocator,
    client: *cas_client.Client,
    thread_id: []const u8,
    turn_id: []const u8,
    timeout_ms: u64,
    lane_events: []const u8,
) !TurnObservation {
    const start_ms: u64 = @intCast(nowMillis());
    var latest = TurnObservation{};
    while (true) {
        const params = try stringifyAnyAlloc(allocator, .{ .threadId = thread_id, .includeTurns = true });
        defer allocator.free(params);
        var notifications: std.ArrayList([]u8) = .empty;
        defer {
            for (notifications.items) |line| allocator.free(line);
            notifications.deinit(allocator);
        }
        const read_json = try client.requestJsonCaptureNotifications("thread/read", params, &notifications);
        defer allocator.free(read_json);
        try appendLine(lane_events, read_json);
        for (notifications.items) |line| {
            try appendLine(lane_events, line);
            absorbNotification(allocator, line, turn_id, &latest) catch {};
        }
        const from_thread = try observationFromThreadRead(allocator, read_json, turn_id);
        mergeObservation(&latest, from_thread);
        if (latest.terminal) return latest;
        const elapsed: u64 = @intCast(nowMillis() - @as(i128, @intCast(start_ms)));
        if (elapsed >= timeout_ms) return latest;
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(500), .awake) catch {};
    }
}

fn mergeObservation(target: *TurnObservation, source: TurnObservation) void {
    if (source.status.len > 0) target.status = source.status;
    if (source.final_text.len > 0) target.final_text = source.final_text;
    target.terminal = target.terminal or source.terminal;
    target.blocking_event = target.blocking_event or source.blocking_event;
}

fn observationFromThreadRead(allocator: std.mem.Allocator, raw: []const u8, turn_id: []const u8) !TurnObservation {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.SourceStale,
    };
    const thread = core_json.objectField(root, "thread") orelse return error.SourceStale;
    const turns_value = thread.get("turns") orelse return error.SourceStale;
    const turns = switch (turns_value) {
        .array => |arr| arr.items,
        else => return error.SourceStale,
    };
    for (turns) |turn_value| {
        const turn = switch (turn_value) {
            .object => |obj| obj,
            else => continue,
        };
        const id = core_json.stringField(turn, "id") orelse continue;
        if (!std.mem.eql(u8, id, turn_id)) continue;
        var out = TurnObservation{};
        out.status = try allocator.dupe(u8, core_json.stringField(turn, "status") orelse "inProgress");
        out.terminal = isTerminalTurnStatus(out.status);
        if (turn.get("items")) |items_value| {
            out.final_text = try finalTextFromItems(allocator, items_value);
        }
        return out;
    }
    return .{};
}

fn finalTextFromItems(allocator: std.mem.Allocator, items_value: std.json.Value) ![]const u8 {
    const items = switch (items_value) {
        .array => |arr| arr.items,
        else => return "",
    };
    var fallback: []const u8 = "";
    for (items) |item_value| {
        const item = switch (item_value) {
            .object => |obj| obj,
            else => continue,
        };
        const item_type = core_json.stringField(item, "type") orelse continue;
        if (!std.mem.eql(u8, item_type, "agentMessage")) continue;
        const text = core_json.stringField(item, "text") orelse continue;
        const phase = core_json.stringField(item, "phase") orelse "";
        if (std.mem.eql(u8, phase, "final_answer")) return allocator.dupe(u8, text);
        fallback = text;
    }
    if (fallback.len > 0) return allocator.dupe(u8, fallback);
    return "";
}

fn absorbNotification(allocator: std.mem.Allocator, line: []const u8, turn_id: []const u8, out: *TurnObservation) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return,
    };
    const method = core_json.stringField(root, "method") orelse return;
    if (std.mem.indexOf(u8, method, "requestApproval") != null or
        std.mem.eql(u8, method, "item/tool/requestUserInput") or
        std.mem.eql(u8, method, "mcpServer/elicitation/request") or
        std.mem.eql(u8, method, "item/tool/call"))
    {
        out.blocking_event = true;
    }
    const params = core_json.objectField(root, "params") orelse return;
    const notif_turn_id = core_json.stringField(params, "turnId") orelse blk: {
        const turn = core_json.objectField(params, "turn") orelse return;
        break :blk core_json.stringField(turn, "id") orelse return;
    };
    if (!std.mem.eql(u8, notif_turn_id, turn_id)) return;
    if (std.mem.eql(u8, method, "turn/completed")) {
        const turn = core_json.objectField(params, "turn") orelse return;
        out.status = try allocator.dupe(u8, core_json.stringField(turn, "status") orelse "completed");
        out.terminal = true;
    } else if (std.mem.eql(u8, method, "item/completed")) {
        const item = core_json.objectField(params, "item") orelse return;
        const item_type = core_json.stringField(item, "type") orelse return;
        if (!std.mem.eql(u8, item_type, "agentMessage")) return;
        const text = core_json.stringField(item, "text") orelse return;
        const phase = core_json.stringField(item, "phase") orelse "";
        if (std.mem.eql(u8, phase, "final_answer") or out.final_text.len == 0) {
            out.final_text = try allocator.dupe(u8, text);
        }
    } else if (std.mem.eql(u8, method, "item/agentMessage/delta")) {
        const delta = core_json.stringField(params, "delta") orelse return;
        if (delta.len > 0 and out.final_text.len == 0) out.final_text = try allocator.dupe(u8, delta);
    }
}

fn isTerminalTurnStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "completed") or
        std.mem.eql(u8, status, "failed") or
        std.mem.eql(u8, status, "interrupted");
}

fn parseFiaAnswerAlloc(allocator: std.mem.Allocator, final_text: []const u8, expected_hindsight: bool) !FiaAnswer {
    const json_text = try extractJsonAnswerText(allocator, final_text);
    defer allocator.free(json_text);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.AnswerParseFailed,
    };
    const answer = core_json.objectField(root, "fork_inquiry_answer") orelse root;
    const answer_version = optionalString(answer, "answer_version") orelse optionalString(root, "answer_version") orelse return error.AnswerParseFailed;
    if (!std.mem.eql(u8, answer_version, "FIA-v1")) return error.AnswerParseFailed;
    if (answer.get("private_reasoning") != null or answer.get("chain_of_thought") != null) return error.AnswerParseFailed;
    const hindsight = parseHindsight(answer) orelse return error.HindsightMismatch;
    if (hindsight != expected_hindsight) return error.HindsightMismatch;
    const reconstructed_decision = try requiredString(answer, "reconstructed_decision");
    const selected_route = try requiredString(answer, "selected_route");
    const uncertainty = try requiredString(answer, "uncertainty");
    if (isTemplatePlaceholderText(reconstructed_decision) or
        isTemplatePlaceholderText(selected_route) or
        isTemplatePlaceholderText(uncertainty))
    {
        return error.AnswerParseFailed;
    }
    return .{
        .reconstructed_decision = try allocator.dupe(u8, reconstructed_decision),
        .selected_route = try allocator.dupe(u8, selected_route),
        .rejected_routes = try stringListAlloc(allocator, answer, "rejected_routes"),
        .evidence_refs = try stringListAlloc(allocator, answer, "evidence_refs"),
        .assumptions = try stringListAlloc(allocator, answer, "assumptions"),
        .alternatives = try stringListAlloc(allocator, answer, "alternatives"),
        .route_flip_conditions = try stringListAlloc(allocator, answer, "route_flip_conditions"),
        .uncertainty = try allocator.dupe(u8, uncertainty),
        .hindsight_available = hindsight,
        .unsupported_claims = try stringListAlloc(allocator, answer, "unsupported_claims"),
    };
}

fn isTemplatePlaceholderText(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '<') != null or
        std.mem.indexOfScalar(u8, text, '>') != null or
        std.mem.eql(u8, text, "low|medium|high");
}

fn extractJsonAnswerText(allocator: std.mem.Allocator, final_text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, final_text, " \t\r\n");
    if (try extractLastFiaJsonObjectAlloc(allocator, trimmed)) |json| return json;
    if (std.mem.indexOf(u8, trimmed, "```")) |fence| {
        const after_open = trimmed[fence + 3 ..];
        const line_end = std.mem.indexOfScalar(u8, after_open, '\n') orelse return error.AnswerParseFailed;
        const body_start = fence + 3 + line_end + 1;
        const rest = trimmed[body_start..];
        const close_rel = std.mem.indexOf(u8, rest, "```") orelse return error.AnswerParseFailed;
        const fenced = std.mem.trim(u8, rest[0..close_rel], " \t\r\n");
        if (try extractLastFiaJsonObjectAlloc(allocator, fenced)) |json| return json;
    }
    return error.AnswerParseFailed;
}

fn extractLastFiaJsonObjectAlloc(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    var search_from: usize = 0;
    var selected: ?[]u8 = null;
    errdefer if (selected) |json| allocator.free(json);
    while (search_from < text.len) {
        const rel_start = std.mem.indexOfScalar(u8, text[search_from..], '{') orelse break;
        const start = search_from + rel_start;
        const json = try extractBalancedJsonObjectFromAlloc(allocator, text, start) orelse break;
        if (std.mem.indexOf(u8, json, "\"FIA-v1\"") != null or std.mem.indexOf(u8, json, "\"answer_version\"") != null) {
            if (selected) |old| allocator.free(old);
            selected = json;
        } else {
            allocator.free(json);
        }
        search_from = start + 1;
    }
    return selected;
}

fn extractBalancedJsonObjectFromAlloc(allocator: std.mem.Allocator, text: []const u8, start: usize) !?[]u8 {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (text[start..], 0..) |ch, rel_index| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        if (ch == '"') {
            in_string = true;
        } else if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            if (depth == 0) return error.AnswerParseFailed;
            depth -= 1;
            if (depth == 0) {
                return try allocator.dupe(u8, text[start .. start + rel_index + 1]);
            }
        }
    }
    return null;
}

fn parseHindsight(answer: std.json.ObjectMap) ?bool {
    const value = answer.get("hindsight_available") orelse return null;
    return switch (value) {
        .bool => |b| b,
        .string => |text| blk: {
            if (std.mem.eql(u8, text, "yes")) break :blk true;
            if (std.mem.eql(u8, text, "no")) break :blk false;
            if (std.mem.eql(u8, text, "true")) break :blk true;
            if (std.mem.eql(u8, text, "false")) break :blk false;
            break :blk null;
        },
        else => null,
    };
}

fn stringListAlloc(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = obj.get(key) orelse return error.MissingRequiredList;
    const arr = switch (value) {
        .array => |items| items.items,
        else => return error.MissingRequiredList,
    };
    var out = try allocator.alloc([]const u8, arr.len);
    for (arr, 0..) |item, index| {
        out[index] = switch (item) {
            .string => |text| try allocator.dupe(u8, text),
            else => try core_json.stringifyValueAlloc(allocator, item),
        };
    }
    return out;
}

fn threadIdFromResponse(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.ForkFailed,
    };
    const thread = core_json.objectField(root, "thread") orelse return error.ForkFailed;
    return allocator.dupe(u8, core_json.stringField(thread, "id") orelse return error.ForkFailed);
}

fn forkedFromIdFromResponse(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };
    const thread = core_json.objectField(root, "thread") orelse return null;
    const value = core_json.stringField(thread, "forkedFromId") orelse return null;
    const owned = try allocator.dupe(u8, value);
    return owned;
}

fn forkPolicyProofFromResponse(allocator: std.mem.Allocator, raw: []const u8, requested_permissions: []const u8) !ForkPolicyProof {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return .{},
    };
    const thread = core_json.objectField(root, "thread") orelse return .{};
    var proof = ForkPolicyProof{};
    proof.ephemeral = boolField(thread, "ephemeral") orelse false;
    proof.approval_never = approvalPolicyNever(root.get("approvalPolicy"));
    if (core_json.objectField(root, "activePermissionProfile")) |profile| {
        if (core_json.stringField(profile, "id")) |id| {
            if (std.mem.eql(u8, id, requested_permissions) or std.mem.indexOf(u8, id, "read") != null) proof.read_only = true;
        }
    }
    if (!proof.read_only) {
        if (root.get("sandbox")) |sandbox| {
            const sandbox_json = try core_json.stringifyAlloc(allocator, sandbox);
            defer allocator.free(sandbox_json);
            proof.read_only = std.mem.indexOf(u8, sandbox_json, "read-only") != null or std.mem.indexOf(u8, sandbox_json, "readOnly") != null;
        }
    }
    return proof;
}

fn approvalPolicyNever(value: ?std.json.Value) bool {
    const policy = value orelse return false;
    return switch (policy) {
        .string => |text| std.mem.eql(u8, text, "never"),
        else => false,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn turnIdFromStartResponse(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.TurnStartFailed,
    };
    const turn = core_json.objectField(root, "turn") orelse return error.TurnStartFailed;
    return allocator.dupe(u8, core_json.stringField(turn, "id") orelse return error.TurnStartFailed);
}

fn turnDigestFromThreadRead(allocator: std.mem.Allocator, raw: []const u8) !TurnDigest {
    const snapshot = try threadHistorySnapshotFromThreadRead(allocator, raw);
    defer {
        for (snapshot.turn_ids) |turn_id| allocator.free(turn_id);
        allocator.free(snapshot.turn_ids);
        allocator.free(snapshot.completed_boundaries);
    }
    return snapshot.digest;
}

fn threadHistorySnapshotFromThreadRead(allocator: std.mem.Allocator, raw: []const u8) !ThreadHistorySnapshot {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.SourceStale,
    };
    const thread = core_json.objectField(root, "thread") orelse return error.SourceStale;
    const turns_value = thread.get("turns") orelse return error.SourceStale;
    const turns = switch (turns_value) {
        .array => |arr| arr,
        else => return error.SourceStale,
    };
    const mode_text = core_json.stringField(thread, "historyMode") orelse "legacy";
    const mode: ThreadHistoryMode = if (std.mem.eql(u8, mode_text, "legacy"))
        .legacy
    else if (std.mem.eql(u8, mode_text, "paginated"))
        .paginated
    else
        return error.ThreadHistoryModeUnsupported;
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(allocator, core_json.stringField(thread, "path") orelse ""),
    };
    defer trace.deinit(allocator);
    if (core_json.stringField(thread, "id")) |id| trace.session.session_id = try allocator.dupe(u8, id);
    var turn_ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (turn_ids.items) |turn_id| allocator.free(turn_id);
        turn_ids.deinit(allocator);
    }
    var completed_boundaries: std.ArrayList(bool) = .empty;
    errdefer completed_boundaries.deinit(allocator);
    for (turns.items) |turn_value| try appendThreadTurnToSnapshot(
        allocator,
        &trace,
        &turn_ids,
        &completed_boundaries,
        turn_value,
    );
    const digest = try trace_core.retainedTraceDigest(
        allocator,
        trace,
        @intCast(turns.items.len),
    );
    return .{
        .mode = mode,
        .digest = .{ .count = turns.items.len, .digest = digest },
        .turn_ids = try turn_ids.toOwnedSlice(allocator),
        .completed_boundaries = try completed_boundaries.toOwnedSlice(allocator),
    };
}

fn readThreadHistorySnapshot(
    allocator: std.mem.Allocator,
    client: *cas_client.Client,
    thread_id: []const u8,
    expected_turns: u64,
    events_path: []const u8,
) !ThreadHistorySnapshot {
    if (expected_turns > MaxThreadHistoryPages * ThreadHistoryPageLimit) return error.SourceStale;
    const metadata_params = try stringifyAnyAlloc(allocator, .{ .threadId = thread_id, .includeTurns = false });
    defer allocator.free(metadata_params);
    const metadata_json = client.requestJson("thread/read", metadata_params) catch return error.SourceNotFound;
    defer allocator.free(metadata_json);
    const mode = try threadHistoryModeFromRead(allocator, metadata_json);
    try appendHistoryReadEvent(allocator, events_path, thread_id, mode, false, 0, false);
    if (mode == .legacy) {
        const read_params = try stringifyAnyAlloc(allocator, .{ .threadId = thread_id, .includeTurns = true });
        defer allocator.free(read_params);
        const read_json = client.requestJson("thread/read", read_params) catch return error.SourceNotFound;
        defer allocator.free(read_json);
        const snapshot = try threadHistorySnapshotFromThreadRead(allocator, read_json);
        try appendHistoryReadEvent(allocator, events_path, thread_id, mode, true, snapshot.turn_ids.len, false);
        return snapshot;
    }

    var metadata_parsed = try std.json.parseFromSlice(std.json.Value, allocator, metadata_json, .{});
    defer metadata_parsed.deinit();
    const metadata_root = switch (metadata_parsed.value) {
        .object => |object| object,
        else => return error.SourceStale,
    };
    const metadata_thread = core_json.objectField(metadata_root, "thread") orelse return error.SourceStale;
    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(allocator, core_json.stringField(metadata_thread, "path") orelse ""),
    };
    defer trace.deinit(allocator);
    trace.session.session_id = try allocator.dupe(u8, core_json.stringField(metadata_thread, "id") orelse thread_id);
    var turn_ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (turn_ids.items) |turn_id| allocator.free(turn_id);
        turn_ids.deinit(allocator);
    }
    var completed_boundaries: std.ArrayList(bool) = .empty;
    errdefer completed_boundaries.deinit(allocator);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| allocator.free(value);
    var page_index: usize = 0;
    while (page_index < MaxThreadHistoryPages) : (page_index += 1) {
        const params = if (cursor) |value|
            try stringifyAnyAlloc(allocator, .{
                .threadId = thread_id,
                .cursor = value,
                .limit = ThreadHistoryPageLimit,
                .sortDirection = "asc",
                .itemsView = "full",
            })
        else
            try stringifyAnyAlloc(allocator, .{
                .threadId = thread_id,
                .limit = ThreadHistoryPageLimit,
                .sortDirection = "asc",
                .itemsView = "full",
            });
        defer allocator.free(params);
        const page_json = client.requestJson("thread/turns/list", params) catch return error.SourceNotFound;
        defer allocator.free(page_json);
        var page = try std.json.parseFromSlice(std.json.Value, allocator, page_json, .{});
        defer page.deinit();
        const page_root = switch (page.value) {
            .object => |object| object,
            else => return error.SourceStale,
        };
        const data = switch (page_root.get("data") orelse return error.SourceStale) {
            .array => |array| array,
            else => return error.SourceStale,
        };
        if (turn_ids.items.len + data.items.len > expected_turns) return error.SourceStale;
        for (data.items) |turn_value| try appendThreadTurnToSnapshot(
            allocator,
            &trace,
            &turn_ids,
            &completed_boundaries,
            turn_value,
        );
        const next_cursor_text = optionalString(page_root, "nextCursor");
        try appendHistoryReadEvent(allocator, events_path, thread_id, mode, true, data.items.len, next_cursor_text != null);
        if (next_cursor_text == null) {
            const digest = try trace_core.retainedTraceDigest(allocator, trace, @intCast(turn_ids.items.len));
            return .{
                .mode = mode,
                .digest = .{ .count = turn_ids.items.len, .digest = digest },
                .turn_ids = try turn_ids.toOwnedSlice(allocator),
                .completed_boundaries = try completed_boundaries.toOwnedSlice(allocator),
            };
        }
        if (data.items.len == 0) return error.SourceStale;
        const next_cursor = next_cursor_text.?;
        if (cursor) |current| if (std.mem.eql(u8, current, next_cursor)) return error.SourceStale;
        const next_owned = try allocator.dupe(u8, next_cursor);
        if (cursor) |old| allocator.free(old);
        cursor = next_owned;
    }
    return error.SourceStale;
}

fn appendThreadTurnToSnapshot(
    allocator: std.mem.Allocator,
    trace: *canonical_trace.CanonicalSessionTrace,
    turn_ids: *std.ArrayList([]const u8),
    completed_boundaries: *std.ArrayList(bool),
    turn_value: std.json.Value,
) !void {
    const turn = switch (turn_value) {
        .object => |object| object,
        else => return error.SourceStale,
    };
    const turn_id = core_json.stringField(turn, "id") orelse return error.SourceStale;
    if (turn_ids.items.len > 0 and std.mem.eql(u8, turn_ids.items[turn_ids.items.len - 1], turn_id)) return error.SourceStale;
    const turn_index: i64 = @intCast(turn_ids.items.len + 1);
    var record = canonical_trace.TurnRecord{
        .path = try allocator.dupe(u8, trace.session.path),
        .turn_id = try allocator.dupe(u8, turn_id),
        .turn_index = turn_index,
        .status = mapThreadReadTurnStatus(core_json.stringField(turn, "status") orelse ""),
        .user_message = try messageTextFromThreadItems(allocator, turn, "userMessage"),
        .final_answer = try messageTextFromThreadItems(allocator, turn, "agentMessage"),
    };
    errdefer record.deinit(allocator);
    try trace.turns.append(allocator, record);
    try appendToolRecordsFromThreadItems(allocator, trace, turn, turn_index);
    try turn_ids.append(allocator, try allocator.dupe(u8, turn_id));
    try completed_boundaries.append(allocator, std.mem.eql(u8, core_json.stringField(turn, "status") orelse "", "completed"));
}

fn appendHistoryReadEvent(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    thread_id: []const u8,
    mode: ThreadHistoryMode,
    include_turns: bool,
    returned_turns: usize,
    has_next: bool,
) !void {
    const event = try stringifyAnyAlloc(allocator, .{
        .event = if (mode == .paginated and include_turns) "thread/turns/list" else "thread/read",
        .thread_id = thread_id,
        .history_mode = @tagName(mode),
        .include_turns = include_turns,
        .returned_turns = returned_turns,
        .has_next = has_next,
    });
    defer allocator.free(event);
    try appendLine(events_path, event);
}

fn appendToolRecordsFromThreadItems(
    allocator: std.mem.Allocator,
    trace: *canonical_trace.CanonicalSessionTrace,
    turn: std.json.ObjectMap,
    turn_index: i64,
) !void {
    const items_value = turn.get("items") orelse return;
    const items = switch (items_value) {
        .array => |arr| arr,
        else => return error.SourceStale,
    };
    for (items.items) |item_value| {
        const item = switch (item_value) {
            .object => |obj| obj,
            else => return error.SourceStale,
        };
        const item_type = core_json.stringField(item, "type") orelse "";
        if (std.mem.eql(u8, item_type, "function_call") or std.mem.eql(u8, item_type, "custom_tool_call")) {
            try appendLiveToolDeclaration(allocator, trace, turn, item, turn_index);
        } else if (std.mem.eql(u8, item_type, "function_call_output") or std.mem.eql(u8, item_type, "custom_tool_call_output")) {
            try appendLiveToolOutput(allocator, trace, turn, item, turn_index);
        }
    }
}

fn appendLiveToolDeclaration(
    allocator: std.mem.Allocator,
    trace: *canonical_trace.CanonicalSessionTrace,
    turn: std.json.ObjectMap,
    item: std.json.ObjectMap,
    turn_index: i64,
) !void {
    const call_id = core_json.stringField(item, "call_id") orelse core_json.stringField(item, "id") orelse return;
    if (findLiveToolByCallId(trace, call_id)) |_| return;
    const name = core_json.stringField(item, "name") orelse core_json.stringField(item, "tool_name") orelse "unknown";
    var record = canonical_trace.ToolLifecycleRecord{
        .session_id = try dupeOptionalConst(allocator, trace.session.session_id),
        .path = try allocator.dupe(u8, trace.session.path),
        .turn_id = try allocator.dupe(u8, core_json.stringField(turn, "id") orelse ""),
        .turn_index = turn_index,
        .call_id = try allocator.dupe(u8, call_id),
        .tool_name = try allocator.dupe(u8, name),
        .arguments_json = if (core_json.stringField(item, "arguments")) |value| try allocator.dupe(u8, value) else null,
        .input_text = if (core_json.stringField(item, "input")) |value| try allocator.dupe(u8, value) else null,
        .lifecycle_status = .declared,
    };
    errdefer record.deinit(allocator);
    if (record.arguments_json) |args| try parseExecArgsIntoLiveTool(allocator, &record, args);
    try trace.tools.append(allocator, record);
}

fn appendLiveToolOutput(
    allocator: std.mem.Allocator,
    trace: *canonical_trace.CanonicalSessionTrace,
    turn: std.json.ObjectMap,
    item: std.json.ObjectMap,
    turn_index: i64,
) !void {
    const call_id = core_json.stringField(item, "call_id") orelse core_json.stringField(item, "id") orelse return;
    const idx = findLiveToolByCallId(trace, call_id) orelse blk: {
        var record = canonical_trace.ToolLifecycleRecord{
            .session_id = try dupeOptionalConst(allocator, trace.session.session_id),
            .path = try allocator.dupe(u8, trace.session.path),
            .turn_id = try allocator.dupe(u8, core_json.stringField(turn, "id") orelse ""),
            .turn_index = turn_index,
            .call_id = try allocator.dupe(u8, call_id),
            .lifecycle_status = .inferred,
        };
        errdefer record.deinit(allocator);
        try trace.tools.append(allocator, record);
        break :blk trace.tools.items.len - 1;
    };
    const output = core_json.stringField(item, "output") orelse core_json.stringField(item, "aggregated_output") orelse core_json.stringField(item, "stdout") orelse "";
    if (output.len > 0) try replaceLiveOpt(allocator, &trace.tools.items[idx].output_text, output);
    if (core_json.stringField(item, "command")) |value| try replaceLiveOpt(allocator, &trace.tools.items[idx].command_text, value);
    if (core_json.stringField(item, "cwd")) |value| try replaceLiveOpt(allocator, &trace.tools.items[idx].cwd, value);
    if (core_json.intField(item, "exit_code")) |value| trace.tools.items[idx].exit_code = value;
    trace.tools.items[idx].lifecycle_status = if (trace.tools.items[idx].exit_code) |code| if (code == 0) .completed else .failed else .completed;
}

fn findLiveToolByCallId(trace: *canonical_trace.CanonicalSessionTrace, call_id: []const u8) ?usize {
    var idx = trace.tools.items.len;
    while (idx > 0) {
        idx -= 1;
        const existing = trace.tools.items[idx].call_id orelse continue;
        if (std.mem.eql(u8, existing, call_id)) return idx;
    }
    return null;
}

fn parseExecArgsIntoLiveTool(allocator: std.mem.Allocator, record: *canonical_trace.ToolLifecycleRecord, args: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return,
    };
    if (core_json.stringField(obj, "cmd")) |value| try replaceLiveOpt(allocator, &record.command_text, value);
    if (core_json.stringField(obj, "command")) |value| try replaceLiveOpt(allocator, &record.command_text, value);
    if (core_json.stringField(obj, "cwd")) |value| try replaceLiveOpt(allocator, &record.cwd, value);
}

fn dupeOptionalConst(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    if (value) |text| return try allocator.dupe(u8, text);
    return null;
}

fn replaceLiveOpt(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = try allocator.dupe(u8, value);
}

fn mapThreadReadTurnStatus(status: []const u8) canonical_trace.TurnStatus {
    if (std.mem.eql(u8, status, "completed")) return .complete;
    if (std.mem.eql(u8, status, "failed")) return .@"error";
    if (std.mem.eql(u8, status, "interrupted")) return .aborted;
    if (std.mem.eql(u8, status, "aborted")) return .aborted;
    return .ongoing;
}

fn messageTextFromThreadItems(allocator: std.mem.Allocator, turn: std.json.ObjectMap, item_type: []const u8) !?[]u8 {
    const items_value = turn.get("items") orelse return null;
    const items = switch (items_value) {
        .array => |arr| arr,
        else => return error.SourceStale,
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var any = false;
    for (items.items) |item_value| {
        const item = switch (item_value) {
            .object => |obj| obj,
            else => return error.SourceStale,
        };
        if (!std.mem.eql(u8, core_json.stringField(item, "type") orelse "", item_type)) continue;
        if (std.mem.eql(u8, item_type, "agentMessage")) {
            if (core_json.stringField(item, "text")) |text| {
                if (any) try out.append(allocator, '\n');
                try out.appendSlice(allocator, text);
                any = true;
            }
            continue;
        }
        const content_value = item.get("content") orelse continue;
        const content_items = switch (content_value) {
            .array => |arr| arr,
            else => return error.SourceStale,
        };
        for (content_items.items) |content_item_value| {
            const content_item = switch (content_item_value) {
                .object => |obj| obj,
                else => return error.SourceStale,
            };
            if (!std.mem.eql(u8, core_json.stringField(content_item, "type") orelse "", "text")) continue;
            if (core_json.stringField(content_item, "text")) |text| {
                if (any) try out.append(allocator, '\n');
                try out.appendSlice(allocator, text);
                any = true;
            }
        }
    }
    if (!any) {
        out.deinit(allocator);
        return null;
    }
    const text = try out.toOwnedSlice(allocator);
    return text;
}

fn appendSourceDigestMismatchEvent(
    allocator: std.mem.Allocator,
    events_path: []const u8,
    observed: TurnDigest,
    expected_count: u64,
    expected_digest: []const u8,
    failure_code: []const u8,
) !void {
    const event = try stringifyAnyAlloc(allocator, .{
        .event = "source_verification_failed",
        .failure_code = failure_code,
        .expected_turns = expected_count,
        .observed_turns = observed.count,
        .expected_digest = expected_digest,
        .observed_digest = observed.digest,
    });
    defer allocator.free(event);
    try appendLine(events_path, event);
}

fn appendCanonicalJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .object => |obj| {
            try out.append(allocator, '{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (isVolatileDigestField(entry.key_ptr.*)) continue;
                if (!first) try out.append(allocator, ',');
                first = false;
                const key_json = try stringifyAnyAlloc(allocator, entry.key_ptr.*);
                defer allocator.free(key_json);
                try out.appendSlice(allocator, key_json);
                try out.append(allocator, ':');
                try appendCanonicalJson(allocator, out, entry.value_ptr.*);
            }
            try out.append(allocator, '}');
        },
        .array => |arr| {
            try out.append(allocator, '[');
            for (arr.items, 0..) |item, index| {
                if (index > 0) try out.append(allocator, ',');
                try appendCanonicalJson(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        else => {
            const json = try core_json.stringifyAlloc(allocator, value);
            defer allocator.free(json);
            try out.appendSlice(allocator, json);
        },
    }
}

fn isVolatileDigestField(key: []const u8) bool {
    return std.mem.eql(u8, key, "id") or
        std.mem.eql(u8, key, "clientId") or
        std.mem.eql(u8, key, "startedAt") or
        std.mem.eql(u8, key, "completedAt") or
        std.mem.eql(u8, key, "durationMs");
}

fn persistInvalidRunArtifacts(
    allocator: std.mem.Allocator,
    options: Options,
    dcp: Dcp,
    rip: Rip,
    receipt_dir: []const u8,
    gate: GateResult,
    detached: bool,
) !void {
    try ensureDir(receipt_dir);
    try persistInputCopies(allocator, options, rip.inquiry_id);
    const events_path = try std.fmt.allocPrint(allocator, "{s}/events.jsonl", .{receipt_dir});
    defer allocator.free(events_path);
    const gate_event = try stringifyAnyAlloc(allocator, .{
        .event = "gate_failed",
        .failure_code = if (gate.failure_code) |code| code.asString() else "receipt_invalid",
        .failure_hint = gate.hint,
    });
    defer allocator.free(gate_event);
    try appendLine(events_path, gate_event);
    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{receipt_dir});
    defer allocator.free(summary_path);
    try writeSummary(
        allocator,
        summary_path,
        rip.inquiry_id,
        @tagName(InquiryState.failed),
        0,
        1,
        "",
        if (gate.failure_code) |code| code.asString() else FailureCode.receipt_invalid.asString(),
        gate.hint,
    );
    const state = .{
        .session_inquiry_record = .{
            .record_version = "SIR-v1",
            .inquiry_id = rip.inquiry_id,
            .state = @tagName(InquiryState.failed),
            .capsule_id = rip.plan_id,
            .plan_id = rip.inquiry_id,
            .source_thread_id = dcp.source_thread_id orelse "",
            .source_thread_id_present = dcp.source_thread_id != null,
            .source_rollout_path = dcp.source_rollout_path orelse "",
            .source_artifact_reconstructability = dcp.reconstructability,
            .lineage_mode = lineageMode(dcp).asString(),
            .managed_transport = .{
                .selected_transport = if (std.mem.eql(u8, options.transport, "auto")) "stdio" else options.transport,
                .detached = detached,
            },
            .lane_states = [_][]const u8{},
            .budgets = .{
                .max_forks = rip.max_forks,
                .max_turns_per_fork = rip.max_turns_per_fork,
                .max_total_tokens = rip.max_total_tokens,
                .timeout_ms = rip.timeout_ms,
            },
            .tokens_used = 0,
            .started_at = nowMillis(),
            .updated_at = nowMillis(),
            .terminal_at = nowMillis(),
            .failure_code = if (gate.failure_code) |code| code.asString() else FailureCode.receipt_invalid.asString(),
            .failure_hint = gate.hint,
            .summary_ref = summary_path,
        },
    };
    const state_path = try stateRecordPath(allocator, options.home, rip.inquiry_id);
    defer allocator.free(state_path);
    try ensureParentDir(state_path);
    try writeJsonFile(allocator, state_path, state);
}

fn persistInputCopies(allocator: std.mem.Allocator, options: Options, inquiry_id: []const u8) !void {
    if (options.capsule_definition_path) |source| {
        try persistInputCopy(
            allocator,
            options.home,
            inquiry_id,
            "capsule.definition.path",
            source,
            source,
        );
    }
    if (options.capsule_path) |source| {
        try persistInputCopy(
            allocator,
            options.home,
            inquiry_id,
            "capsule.json",
            options.capsule_bytes,
            source,
        );
    }
    if (options.capsule_validation_path) |source| {
        try persistInputCopy(
            allocator,
            options.home,
            inquiry_id,
            "capsule.validation.json",
            options.capsule_validation_bytes,
            source,
        );
    }
    if (options.plan_definition_path) |source| {
        try persistInputCopy(
            allocator,
            options.home,
            inquiry_id,
            "plan.definition.path",
            source,
            source,
        );
    }
    if (options.plan_path) |source| {
        try persistInputCopy(
            allocator,
            options.home,
            inquiry_id,
            "plan.json",
            options.plan_bytes,
            source,
        );
    }
    if (options.plan_validation_path) |source| {
        try persistInputCopy(
            allocator,
            options.home,
            inquiry_id,
            "plan.validation.json",
            options.plan_validation_bytes,
            source,
        );
    }
}

fn persistInputCopy(
    allocator: std.mem.Allocator,
    home: []const u8,
    inquiry_id: []const u8,
    name: []const u8,
    validated: ?[]const u8,
    source: []const u8,
) !void {
    const owned = if (validated == null)
        try readFileAlloc(allocator, source, MaxInputBytes)
    else
        null;
    defer if (owned) |bytes| allocator.free(bytes);
    const target = try inquiryPathJoin(
        allocator,
        home,
        inquiry_id,
        name,
    );
    defer allocator.free(target);
    try durable_store.writeTextAtomic(
        allocator,
        target,
        validated orelse owned.?,
    );
}

fn persistedDefinitionPathAlloc(
    allocator: std.mem.Allocator,
    home: []const u8,
    inquiry_id: []const u8,
    name: []const u8,
) ![]u8 {
    const path = try inquiryPathJoin(
        allocator,
        home,
        inquiry_id,
        name,
    );
    defer allocator.free(path);
    const raw = try readFileAlloc(allocator, path, MaxInputBytes);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or !std.fs.path.isAbsolute(trimmed)) {
        return error.InvalidDefinitionPath;
    }
    return allocator.dupe(u8, trimmed);
}

fn inquiryWorkspaceCwdAlloc(allocator: std.mem.Allocator, options: Options, rip: Rip) ![]const u8 {
    if (!std.mem.eql(u8, rip.workspace_policy, "transcript_only")) return allocator.dupe(u8, options.cwd);
    const workspace = try inquiryPathJoin(allocator, options.home, rip.inquiry_id, "workspace");
    try ensureDir(workspace);
    return workspace;
}

fn rootObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return core_json.objectField(obj, key);
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = core_json.stringField(obj, key) orelse return null;
    if (value.len == 0) return null;
    return value;
}

fn dupeOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn requiredString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return optionalString(obj, key) orelse error.MissingRequiredString;
}

fn requiredBool(obj: std.json.ObjectMap, key: []const u8) !bool {
    const value = obj.get(key) orelse return error.MissingRequiredBool;
    return switch (value) {
        .bool => |b| b,
        else => error.MissingRequiredBool,
    };
}

fn optionalBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn optionalU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = obj.get(key) orelse return null;
    const int = core_json.intFromValue(value) orelse return null;
    if (int < 0) return null;
    return @intCast(int);
}

fn requiredU64(obj: std.json.ObjectMap, key: []const u8) !u64 {
    return optionalU64(obj, key) orelse error.MissingRequiredInteger;
}

fn requiredListLen(obj: std.json.ObjectMap, key: []const u8) !usize {
    const value = obj.get(key) orelse return error.MissingRequiredList;
    return switch (value) {
        .array => |arr| arr.items.len,
        else => error.MissingRequiredList,
    };
}

fn resolveExecutablePathAlloc(allocator: std.mem.Allocator, codex_path: []const u8, path_env: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, codex_path, '/') != null) return allocator.dupe(u8, codex_path);
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, codex_path });
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    for ([_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin" }) |dir| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, codex_path });
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.CodexUnavailable;
}

var configured_store_root_override: ?[]const u8 = null;
var configured_store_cwd: ?[]const u8 = null;

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

fn stateRecordPath(allocator: std.mem.Allocator, home: []const u8, inquiry_id: []const u8) ![]const u8 {
    _ = home;
    const safe = try sanitizeInquiryIdAlloc(allocator, inquiry_id);
    defer allocator.free(safe);
    const root = try casStoreRootAlloc(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/session_inquiries/{s}.json", .{ root, safe });
}

fn inquiryPathJoin(allocator: std.mem.Allocator, home: []const u8, inquiry_id: []const u8, leaf: []const u8) ![]const u8 {
    _ = home;
    const safe = try sanitizeInquiryIdAlloc(allocator, inquiry_id);
    defer allocator.free(safe);
    const root = try casStoreRootAlloc(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/session_inquiries/{s}/{s}", .{ root, safe, leaf });
}

fn sanitizeInquiryIdAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0 or raw.len > 128) return error.InvalidInquiryId;
    for (raw) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return error.InvalidInquiryId;
    }
    var out = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |ch, i| {
        out[i] = ch;
    }
    return out;
}

fn ensureDir(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        const rel = std.mem.trim(u8, path, "/");
        if (rel.len == 0) return;
        var root = try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), "/", .{});
        defer root.close(std.Io.Threaded.global_single_threaded.io());
        try root.createDirPath(std.Io.Threaded.global_single_threaded.io(), rel);
    } else {
        try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), path);
    }
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    try ensureDir(parent);
}

fn absoluteDirPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.fs.path.isAbsolute(path)) {
        var dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
        defer dir.close(io);
        return dir.realPathFileAlloc(io, ".", allocator);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    return dir.realPathFileAlloc(io, ".", allocator);
}

fn absoluteLexicalPathAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(allocator, &.{path});
    }
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        ".",
        allocator,
    );
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > max_bytes) return error.FileTooBig;
    const len: usize = @intCast(size);
    const buffer = try allocator.alloc(u8, len);
    errdefer allocator.free(buffer);
    const read_len = try file.readPositionalAll(io, buffer, 0);
    return if (read_len == buffer.len) buffer else try allocator.realloc(buffer, read_len);
}

fn fileExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

fn expandSimpleGlobAlloc(allocator: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        var one = try allocator.alloc([]const u8, 1);
        one[0] = try allocator.dupe(u8, pattern);
        return one;
    }
    const dir_name = std.fs.path.dirname(pattern) orelse ".";
    const base = std.fs.path.basename(pattern);
    const dirs = try expandDirectoryGlobAlloc(allocator, dir_name);
    defer {
        for (dirs) |dir_path| allocator.free(dir_path);
        allocator.free(dirs);
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (dirs) |dir_path| {
        try appendFileGlobMatches(allocator, &out, dir_path, base);
    }
    return out.toOwnedSlice(allocator);
}

fn expandDirectoryGlobAlloc(allocator: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        var one = try allocator.alloc([]const u8, 1);
        one[0] = try allocator.dupe(u8, pattern);
        return one;
    }
    const parent = std.fs.path.dirname(pattern) orelse ".";
    const base = std.fs.path.basename(pattern);
    const parents = try expandDirectoryGlobAlloc(allocator, parent);
    defer {
        for (parents) |parent_path| allocator.free(parent_path);
        allocator.free(parents);
    }

    var out: std.ArrayList([]const u8) = .empty;
    for (parents) |parent_path| {
        if (std.mem.indexOfScalar(u8, base, '*')) |base_star| {
            var dir = if (std.fs.path.isAbsolute(parent_path))
                try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), parent_path, .{ .iterate = true })
            else
                try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), parent_path, .{ .iterate = true });
            defer dir.close(std.Io.Threaded.global_single_threaded.io());
            var iter = dir.iterate();
            const prefix = base[0..base_star];
            const suffix = base[base_star + 1 ..];
            while (try iter.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
                if (entry.kind != .directory) continue;
                if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
                if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
                try out.append(allocator, try joinPathAlloc(allocator, parent_path, entry.name));
            }
        } else {
            const candidate = try joinPathAlloc(allocator, parent_path, base);
            if (dirExists(candidate)) {
                try out.append(allocator, candidate);
            } else {
                allocator.free(candidate);
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendFileGlobMatches(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), dir_name: []const u8, base: []const u8) !void {
    const base_star = std.mem.indexOfScalar(u8, base, '*') orelse {
        const candidate = try joinPathAlloc(allocator, dir_name, base);
        if (fileExists(candidate)) {
            try out.append(allocator, candidate);
        } else {
            allocator.free(candidate);
        }
        return;
    };
    const prefix = base[0..base_star];
    const suffix = base[base_star + 1 ..];
    var dir = if (std.fs.path.isAbsolute(dir_name))
        try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), dir_name, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), dir_name, .{ .iterate = true });
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var iter = dir.iterate();
    while (try iter.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        try out.append(allocator, try joinPathAlloc(allocator, dir_name, entry.name));
    }
}

fn dirExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn joinPathAlloc(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) ![]const u8 {
    if (std.mem.eql(u8, parent, ".")) return allocator.dupe(u8, child);
    if (std.mem.eql(u8, parent, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{child});
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, child });
}

fn readFirReceiptValid(allocator: std.mem.Allocator, path: []const u8) !bool {
    const raw = try readFileAlloc(allocator, path, MaxInputBytes);
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return false,
    };
    const receipt = core_json.objectField(root, "fork_inquiry_receipt") orelse root;
    const gate = core_json.objectField(receipt, "gate") orelse return false;
    return boolField(gate, "receipt_valid") orelse false;
}

fn writeJsonFile(allocator: std.mem.Allocator, path: []const u8, value: anytype) !void {
    const json = try stringifyAnyAlloc(allocator, value);
    defer allocator.free(json);
    var payload: std.Io.Writer.Allocating = .init(allocator);
    defer payload.deinit();
    try payload.writer.writeAll(json);
    try payload.writer.writeByte('\n');
    const text = try payload.toOwnedSlice();
    defer allocator.free(text);
    try durable_store.writeTextAtomic(allocator, path, text);
}

fn appendLine(path: []const u8, line: []const u8) !void {
    const existing = readFileAlloc(std.heap.page_allocator, path, MaxInputBytes) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const owns_existing = existing.len > 0;
    defer if (owns_existing) std.heap.page_allocator.free(existing);
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    try out.writer.writeAll(existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.writer.writeByte('\n');
    try out.writer.writeAll(line);
    try out.writer.writeByte('\n');
    const payload = try out.toOwnedSlice();
    defer std.heap.page_allocator.free(payload);
    try durable_store.writeTextAtomic(std.heap.page_allocator, path, payload);
}

fn appendSimpleEvent(allocator: std.mem.Allocator, events_path: []const u8, event_name: []const u8) !void {
    const event = try stringifyAnyAlloc(allocator, .{ .event = event_name });
    defer allocator.free(event);
    try appendLine(events_path, event);
}

fn stringifyAnyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    return out.toOwnedSlice();
}

fn printJsonValue(allocator: std.mem.Allocator, value: anytype) !void {
    const json = try stringifyAnyAlloc(allocator, value);
    defer allocator.free(json);
    try printRawJson(json);
}

fn printRawJson(raw: []const u8) !void {
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{raw});
}

fn printFailureJson(allocator: std.mem.Allocator, code: FailureCode, hint: []const u8) !void {
    try printJsonValue(allocator, .{
        .session_inquiry_error = .{
            .failure_code = code.asString(),
            .failure_hint = hint,
        },
    });
}

fn printPreflightFailure(allocator: std.mem.Allocator, options: Options, err: anyerror) !void {
    const failure_code: FailureCode = switch (err) {
        error.AppServerPreflightFailed,
        error.AppServerPreflightStatusMismatch,
        error.AppServerPreflightHostIdentityMismatch,
        error.InvalidAppServerPreflightReceipt,
        => .codex_incompatible,
        else => .schema_unavailable,
    };
    try printJsonValue(allocator, .{
        .session_inquiry_preflight = .{
            .compatibility_verdict = "incompatible",
            .codex_path = options.codex_path,
            .codex_version = "",
            .schema_fingerprint = "",
            .cache_dir = "",
            .capabilities = zeroCapabilities(),
            .thread_fork_replay = false,
            .paginated_thread_fork = false,
            .rollout_transcript_replay = false,
            .selected_transport = options.transport,
            .code_mode_host_redacted = @as(?[]const u8, null),
            .code_mode_host_digest = @as(?[]const u8, null),
            .missing = [_][]const u8{"app-server/session-inquiry-preflight"},
            .inquiry_allowed = false,
            .failure_code = failure_code.asString(),
            .failure_hint = @errorName(err),
        },
    });
}

fn sha256HexAlloc(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const out = try allocator.alloc(u8, "sha256:".len + digest.len * 2);
    @memcpy(out[0.."sha256:".len], "sha256:");
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out["sha256:".len..], &hex);
    return out;
}

fn nowMillis() i128 {
    return @divTrunc(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000);
}

test "parseArgs accepts safe common flags and rejects unsafe sandbox" {
    const argv = [_][]const u8{
        "cas_session_inquiry",
        "preflight",
        "--cwd",
        "/tmp/work",
        "--sandbox",
        "read-only",
        "--transport",
        "managed-ws",
        "--json",
    };
    const options = try parseArgs(&argv);
    try std.testing.expectEqual(Command.preflight, options.command);
    try std.testing.expectEqualStrings("/tmp/work", options.cwd);
    try std.testing.expect(options.json);

    const bad = [_][]const u8{ "cas_session_inquiry", "run", "--sandbox", "workspace-write" };
    try std.testing.expectError(error.UnsafeSandbox, parseArgs(&bad));
}

test "casStoreRootAlloc falls back to cwd ledger outside git" {
    const old_store_root = configured_store_root_override;
    const old_store_cwd = configured_store_cwd;
    configured_store_root_override = null;
    defer configured_store_root_override = old_store_root;
    defer configured_store_cwd = old_store_cwd;

    const root = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/cas-session-inquiry-store-root-test-{d}",
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
}

test "deriveCapabilities recognizes exact schema method and local field surface" {
    const allocator = std.testing.allocator;
    var requests = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"oneOf":[{"properties":{"method":{"enum":["thread/fork"]}}},{"properties":{"method":{"enum":["thread/rollback"]}}},{"properties":{"method":{"enum":["thread/start"]}}},{"properties":{"method":{"enum":["thread/read"]}}},{"properties":{"method":{"enum":["thread/turns/list"]}}},{"properties":{"method":{"enum":["turn/start"]}}},{"properties":{"method":{"enum":["turn/interrupt"]}}},{"properties":{"method":{"enum":["thread/archive"]}}}]}
    , .{});
    defer requests.deinit();
    var fork_params = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"properties":{"ephemeral":{},"permissions":{},"sandbox":{},"path":{},"lastTurnId":{},"beforeTurnId":{},"excludeTurns":{}}}
    , .{});
    defer fork_params.deinit();
    var fork_response = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"definitions":{"Thread":{"properties":{"forkedFromId":{}}}}}
    , .{});
    defer fork_response.deinit();
    var rollback_params = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"properties":{"numTurns":{}}}
    , .{});
    defer rollback_params.deinit();
    var turns_list_params = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"properties":{"cursor":{},"limit":{},"sortDirection":{},"itemsView":{}}}
    , .{});
    defer turns_list_params.deinit();
    var turns_list_response = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"properties":{"data":{},"nextCursor":{}}}
    , .{});
    defer turns_list_response.deinit();
    const caps = deriveCapabilitiesFromSchemas(requests.value, fork_params.value, fork_response.value, rollback_params.value, turns_list_params.value, turns_list_response.value);
    try std.testing.expect(caps.thread_fork);
    try std.testing.expect(caps.thread_rollback);
    try std.testing.expect(caps.thread_start);
    try std.testing.expect(caps.thread_read);
    try std.testing.expect(caps.turn_start);
    try std.testing.expect(caps.exactAnchorSupported());
    try std.testing.expect(caps.rolloutTranscriptSupported());
}

test "validateLane enforces mode horizon invariants" {
    try validateLane(.{
        .lane_id = "counterfactual",
        .temporal_horizon = "pre_decision",
        .inquiry_mode = "counterfactual",
        .fork_count = 1,
        .prompt_template = "x",
        .evidence_allowed_count = 0,
        .evidence_withheld_count = 0,
    });
    try std.testing.expectError(error.BadLaneHorizon, validateLane(.{
        .lane_id = "counterfactual",
        .temporal_horizon = "outcome_aware",
        .inquiry_mode = "counterfactual",
        .fork_count = 1,
        .prompt_template = "x",
        .evidence_allowed_count = 0,
        .evidence_withheld_count = 0,
    }));
}

test "validateInquiryInputs rejects unavailable workspace" {
    const dcp = Dcp{
        .packet_id = "CAP",
        .source_episode_id = "session:test#turn:decision",
        .source_thread_id = "thr",
        .source_rollout_path = null,
        .source_turn_digest = "sha256:source",
        .source_model = null,
        .source_model_provider = null,
        .source_codex_version = null,
        .reconstructability = "head_only",
        .total_turns = 1,
        .decision_turn_index = 1,
        .first_outcome_turn_index = null,
        .anchors = [_]Anchor{
            .{ .name = .pre_decision, .available = true, .keep_through_turn_index = 0, .drop_last_n_turns = 1, .anchor_digest = "sha256:pre" },
            .{ .name = .post_decision_pre_outcome, .available = true, .keep_through_turn_index = 1, .drop_last_n_turns = 0, .anchor_digest = "sha256:post" },
            .{ .name = .outcome_aware, .available = true, .keep_through_turn_index = 1, .drop_last_n_turns = 0, .anchor_digest = "sha256:full" },
        },
    };
    var lanes = [_]Lane{.{
        .lane_id = "rationale",
        .temporal_horizon = "post_decision_pre_outcome",
        .inquiry_mode = "rationale",
        .fork_count = 1,
        .prompt_template = "x",
        .evidence_allowed_count = 0,
        .evidence_withheld_count = 0,
    }};
    const rip = Rip{
        .plan_id = "CAP",
        .inquiry_id = "INQ",
        .objective = "test",
        .model_policy = "current_recorded",
        .workspace_policy = "unavailable",
        .permission_read_only = true,
        .permission_network = false,
        .max_forks = 1,
        .max_turns_per_fork = 1,
        .max_total_tokens = 100,
        .timeout_ms = 1000,
        .lanes = lanes[0..],
    };
    const gate = validateInquiryInputs(std.testing.allocator, dcp, rip, .{ .command = .run });
    try std.testing.expect(!gate.valid);
    try std.testing.expectEqual(FailureCode.workspace_mismatch, gate.failure_code.?);
}

test "validateInquiryInputs accepts verified rollout transcript lineage only" {
    const allocator = std.testing.allocator;
    const rollout_path = try repoTestPathAlloc(
        allocator,
        "libs/trace_core/testdata/new_044_plus.jsonl",
    );
    defer allocator.free(rollout_path);

    var trace = try canonical_trace.parseSessionTrace(allocator, rollout_path, .{});
    defer trace.deinit(allocator);
    const source_digest = try trace_core.completeTraceDigest(allocator, trace);
    defer allocator.free(source_digest);
    const post_digest = try trace_core.retainedTraceDigest(allocator, trace, 1);
    defer allocator.free(post_digest);

    const dcp = Dcp{
        .packet_id = "CAP",
        .source_episode_id = "session:test#turn:decision",
        .source_thread_id = null,
        .source_rollout_path = rollout_path,
        .source_turn_digest = source_digest,
        .source_model = null,
        .source_model_provider = null,
        .source_codex_version = null,
        .reconstructability = "transcript_only",
        .total_turns = @intCast(trace.turns.items.len),
        .decision_turn_index = 1,
        .first_outcome_turn_index = null,
        .anchors = [_]Anchor{
            .{ .name = .pre_decision, .available = false },
            .{ .name = .post_decision_pre_outcome, .available = true, .keep_through_turn_index = 1, .drop_last_n_turns = 0, .anchor_digest = post_digest },
            .{ .name = .outcome_aware, .available = true, .keep_through_turn_index = 1, .drop_last_n_turns = 0, .anchor_digest = post_digest },
        },
    };
    var lanes = [_]Lane{.{
        .lane_id = "rationale",
        .temporal_horizon = "post_decision_pre_outcome",
        .inquiry_mode = "rationale",
        .fork_count = 1,
        .prompt_template = "x",
        .evidence_allowed_count = 0,
        .evidence_withheld_count = 0,
    }};
    const rip = Rip{
        .plan_id = "CAP",
        .inquiry_id = "INQ",
        .objective = "test",
        .model_policy = "current_recorded",
        .workspace_policy = "transcript_only",
        .permission_read_only = true,
        .permission_network = false,
        .max_forks = 1,
        .max_turns_per_fork = 1,
        .max_total_tokens = 100,
        .timeout_ms = 1000,
        .lanes = lanes[0..],
    };
    const gate = validateInquiryInputs(allocator, dcp, rip, .{ .command = .run });
    try std.testing.expect(gate.valid);

    var exact_workspace = rip;
    exact_workspace.workspace_policy = "exact";
    const exact_gate = validateInquiryInputs(allocator, dcp, exact_workspace, .{ .command = .run });
    try std.testing.expect(!exact_gate.valid);
    try std.testing.expectEqual(FailureCode.workspace_mismatch, exact_gate.failure_code.?);

    var stale_dcp = dcp;
    stale_dcp.source_turn_digest = "sha256:bad-source";
    const stale_gate = validateInquiryInputs(allocator, stale_dcp, rip, .{ .command = .run });
    try std.testing.expect(!stale_gate.valid);
    try std.testing.expectEqual(FailureCode.source_turn_digest_mismatch, stale_gate.failure_code.?);

    var anchor_bad_dcp = dcp;
    anchor_bad_dcp.anchors[1].anchor_digest = "sha256:bad-anchor";
    const anchor_gate = validateInquiryInputs(allocator, anchor_bad_dcp, rip, .{ .command = .run });
    try std.testing.expect(!anchor_gate.valid);
    try std.testing.expectEqual(FailureCode.anchor_digest_mismatch, anchor_gate.failure_code.?);
}

test "buildRolloutInquiryPromptAlloc labels transcript lineage and retained horizon" {
    const allocator = std.testing.allocator;
    const rollout_path = try repoTestPathAlloc(
        allocator,
        "libs/trace_core/testdata/new_044_plus.jsonl",
    );
    defer allocator.free(rollout_path);
    const dcp = Dcp{
        .packet_id = "CAP",
        .source_episode_id = "session:test#turn:decision",
        .source_thread_id = null,
        .source_rollout_path = rollout_path,
        .source_turn_digest = "sha256:source",
        .source_model = null,
        .source_model_provider = null,
        .source_codex_version = null,
        .reconstructability = "transcript_only",
        .total_turns = 1,
        .decision_turn_index = 1,
        .first_outcome_turn_index = null,
        .anchors = [_]Anchor{
            .{ .name = .pre_decision, .available = false },
            .{ .name = .post_decision_pre_outcome, .available = true, .keep_through_turn_index = 1, .drop_last_n_turns = 0, .anchor_digest = "sha256:post" },
            .{ .name = .outcome_aware, .available = true, .keep_through_turn_index = 1, .drop_last_n_turns = 0, .anchor_digest = "sha256:full" },
        },
    };
    const rip = Rip{
        .plan_id = "CAP",
        .inquiry_id = "INQ",
        .objective = "test objective",
        .model_policy = "current_recorded",
        .workspace_policy = "transcript_only",
        .permission_read_only = true,
        .permission_network = false,
        .max_forks = 1,
        .max_turns_per_fork = 1,
        .max_total_tokens = 100,
        .timeout_ms = 1000,
        .lanes = &.{},
    };
    const lane = Lane{
        .lane_id = "rationale",
        .temporal_horizon = "post_decision_pre_outcome",
        .inquiry_mode = "rationale",
        .fork_count = 1,
        .prompt_template = "why",
        .evidence_allowed_count = 0,
        .evidence_withheld_count = 0,
    };
    const prompt = try buildRolloutInquiryPromptAlloc(allocator, dcp, rip, lane, dcp.anchors[1]);
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "lineage_mode: rollout_transcript") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "visible_turns_retained: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "visible_historical_context") != null);
}

const test_dcp_json =
    \\{
    \\  "decision_context_packet": {
    \\    "packet_version": "DCP-v2",
    \\    "packet_id": "DCP-test",
    \\    "source": {
    \\      "source_episode_id": "session:dcp-basic#turn:turn-decision",
    \\      "session_id": "dcp-basic"
    \\    },
    \\    "artifact_state": {"reconstructability": "head_only"},
    \\    "turns": {
    \\      "total_turns": 3,
    \\      "decision_turn_index": 2,
    \\      "decision_turn_id": "turn-decision",
    \\      "first_outcome_turn_index": 3,
    \\      "source_turn_digest": "sha256:source"
    \\    },
    \\    "anchors": {
    \\      "pre_decision": {
    \\        "available": true,
    \\        "keep_through_turn_index": 1,
    \\        "drop_last_n_turns": 2,
    \\        "anchor_digest": "sha256:pre"
    \\      },
    \\      "post_decision_pre_outcome": {
    \\        "available": true,
    \\        "keep_through_turn_index": 2,
    \\        "drop_last_n_turns": 1,
    \\        "anchor_digest": "sha256:post"
    \\      },
    \\      "outcome_aware": {
    \\        "available": true,
    \\        "keep_through_turn_index": 3,
    \\        "drop_last_n_turns": 0,
    \\        "anchor_digest": "sha256:full"
    \\      }
    \\    }
    \\  }
    \\}
;

test "CAS rejects a DCP identity that does not bind its content" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        test_dcp_json,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.DcpContentIdentityMismatch,
        verifyDcpContentIdentity(allocator, parsed.value),
    );
}

test "CAS preserves the released DCP-v2 canonical identity profile" {
    const text =
        \\{"packet_id":"root","float":1e23,"fraction":333333333.33333325,"negative_zero":-0.0,"escape":"\b\t\n\f\r\u0000\"\\/","nested":{"packet_id":"nested","value":1e-7}}
    ;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        text,
        .{},
    );
    defer parsed.deinit();
    const canonical = try canonicalDcpV2JsonAlloc(
        std.testing.allocator,
        parsed.value,
        true,
    );
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(
        \\{"escape":"\b\t\n\f\r\u0000\"\\/","float":100000000000000000000000,"fraction":333333333.33333325,"negative_zero":-0,"nested":{"value":0.0000001}}
    , canonical);
}

test "CAS consumes the explicit DCP-v2 source episode identity" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        test_dcp_json,
        .{},
    );
    defer parsed.deinit();
    const dcp = try dcpFromValue(allocator, parsed.value);
    defer deinitDcp(allocator, dcp);
    try std.testing.expectEqualStrings(
        "session:dcp-basic#turn:turn-decision",
        dcp.source_episode_id.?,
    );
}

test "CAS rejects unsupported DCP reconstructability before inquiry" {
    const allocator = std.testing.allocator;
    const unsupported = try std.mem.replaceOwned(
        u8,
        allocator,
        test_dcp_json,
        "\"reconstructability\": \"head_only\"",
        "\"reconstructability\": \"invented\"",
    );
    defer allocator.free(unsupported);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        unsupported,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.BadReconstructability,
        dcpFromValue(allocator, parsed.value),
    );
}

test "CAS derives DCP-v2 source episode identity from canonical locators" {
    const allocator = std.testing.allocator;
    const without_explicit = try std.mem.replaceOwned(
        u8,
        allocator,
        test_dcp_json,
        "      \"source_episode_id\": \"session:dcp-basic#turn:turn-decision\",\n",
        "",
    );
    defer allocator.free(without_explicit);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        without_explicit,
        .{},
    );
    defer parsed.deinit();
    const dcp = try dcpFromValue(allocator, parsed.value);
    defer deinitDcp(allocator, dcp);
    try std.testing.expectEqualStrings("session:dcp-basic#turn:turn-decision", dcp.source_episode_id.?);
}

test "CAS accepts a validated DCP without a source episode projection" {
    const allocator = std.testing.allocator;
    const without_explicit = try std.mem.replaceOwned(
        u8,
        allocator,
        test_dcp_json,
        "      \"source_episode_id\": \"session:dcp-basic#turn:turn-decision\",\n",
        "",
    );
    defer allocator.free(without_explicit);
    const without_session = try std.mem.replaceOwned(
        u8,
        allocator,
        without_explicit,
        "      \"session_id\": \"dcp-basic\"\n",
        "",
    );
    defer allocator.free(without_session);
    const without_identity_inputs = try std.mem.replaceOwned(
        u8,
        allocator,
        without_session,
        "      \"decision_turn_id\": \"turn-decision\",\n",
        "",
    );
    defer allocator.free(without_identity_inputs);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        without_identity_inputs,
        .{},
    );
    defer parsed.deinit();
    const dcp = try dcpFromValue(allocator, parsed.value);
    defer deinitDcp(allocator, dcp);
    try std.testing.expect(dcp.source_episode_id == null);
}

fn repoTestPathAlloc(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, relative });
}

test "sanitizeInquiryId rejects path traversal" {
    const allocator = std.testing.allocator;
    const ok = try sanitizeInquiryIdAlloc(allocator, "INQ-001");
    defer allocator.free(ok);
    try std.testing.expectEqualStrings("INQ-001", ok);
    try std.testing.expectError(error.InvalidInquiryId, sanitizeInquiryIdAlloc(allocator, "../bad"));
}

test "validateLane rejects path traversal lane ids" {
    try validateLane(.{
        .lane_id = "rationale-1",
        .inquiry_mode = "rationale",
        .temporal_horizon = "pre_decision",
        .prompt_template = "why",
        .fork_count = 1,
        .evidence_allowed_count = 0,
        .evidence_withheld_count = 0,
    });
    try std.testing.expectError(error.BadLaneId, validateLane(.{
        .lane_id = "../../escape",
        .inquiry_mode = "rationale",
        .temporal_horizon = "pre_decision",
        .prompt_template = "why",
        .fork_count = 1,
        .evidence_allowed_count = 0,
        .evidence_withheld_count = 0,
    }));
}

test "expandSimpleGlobAlloc supports wildcard directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "INQ-1/lanes");
    try tmp.dir.createDirPath(std.Io.Threaded.global_single_threaded.io(), "INQ-2/lanes");
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "INQ-1/lanes/a.json", .data = "{}" });
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "INQ-2/lanes/b.json", .data = "{}" });
    const tmp_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);
    const pattern = try std.fmt.allocPrint(allocator, "{s}/*/lanes/*.json", .{tmp_path});
    defer allocator.free(pattern);
    const matches = try expandSimpleGlobAlloc(allocator, pattern);
    defer freeStringList(allocator, matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
}

test "sha256HexAlloc prefixes digest" {
    const allocator = std.testing.allocator;
    const digest = try sha256HexAlloc(allocator, "abc");
    defer allocator.free(digest);
    try std.testing.expectEqualStrings("sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", digest);
}

test "CAS binds caller Ledger receipts without a Ledger runtime" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = "{}";
    const input_digest = try sha256HexAlloc(allocator, input);
    defer allocator.free(input_digest);
    const receipt = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"ledger-validation-result/v1\"," ++
            "\"definition\":{{\"id\":\"retrace/decision-context-packet\"," ++
            "\"digest\":\"sha256:" ++
            "0000000000000000000000000000000000000000000000000000000000000000\"," ++
            "\"abi\":\"ledger-artifact-abi/v1\"}}," ++
            "\"input_digests\":{{\"packet\":\"{s}\"}}," ++
            "\"valid\":true,\"errors\":[],\"claims\":[]," ++
            "\"authority_granted\":false,\"storage_mutated\":false}}",
        .{input_digest},
    );
    defer allocator.free(receipt);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "capsule.json",
        .data = input,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "validation.json",
        .data = receipt,
    });
    const input_path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "capsule.json",
        allocator,
    );
    defer allocator.free(input_path);
    const receipt_path = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        "validation.json",
        allocator,
    );
    defer allocator.free(receipt_path);
    var validated = try validateLedgerInput(
        allocator,
        input_path,
        receipt_path,
        "retrace/decision-context-packet",
        "packet",
    );
    defer validated.deinit(allocator);
    try std.testing.expectEqualStrings(input, validated.input);
    try std.testing.expectEqualStrings(receipt, validated.receipt);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "capsule.json",
        .data = "{\"changed\":true}",
    });
    try std.testing.expectError(
        error.LedgerValidationInputDigestMismatch,
        validateLedgerInput(
            allocator,
            input_path,
            receipt_path,
            "retrace/decision-context-packet",
            "packet",
        ),
    );
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "capsule.json",
        .data = input,
    });
    try std.testing.expectError(
        error.LedgerValidationDefinitionDigestMismatch,
        validateLedgerInputReceipt(
            allocator,
            receipt_path,
            input_path,
            "retrace/decision-context-packet",
            "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            "packet",
        ),
    );
}

test "shared session inquiry preflight parser preserves exact profile evidence" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"schema":"cas-app-server-preflight/v1","action":"preflight","profile":"session-inquiry","status":"compatible","contractId":"codex-app-server-0.146.0",
        \\ "codex":{"path":"/tmp/codex-0.146.0","version":"0.146.0"},
        \\ "schemas":{"stableDigest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","experimentalDigest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","experimentalPath":"/tmp/cache/0.146.0/experimental"},
        \\ "methods":{"missingRequired":[]},
        \\ "handlerCoverage":{"status":"passed","failures":[]},
        \\ "shapeChecks":{"status":"passed","failures":[]},
        \\ "transport":{"selected":"managed-ws","codeModeHost":{"origin":"wss://example.test","sha256":"3333333333333333333333333333333333333333333333333333333333333333"}},
        \\ "behavioralProbes":[
        \\  {"id":"initialize-lifecycle","requirement":"required","status":"passed"},
        \\  {"id":"managed-websocket-transport","requirement":"required","status":"passed"},
        \\  {"id":"server-request-coverage","requirement":"required","status":"passed"},
        \\  {"id":"paginated-fork","requirement":"required","status":"passed"},
        \\  {"id":"ephemeral-fork","requirement":"required","status":"passed"},
        \\  {"id":"bounded-overload-retry","requirement":"required","status":"passed"},
        \\  {"id":"paginated-session-inquiry","requirement":"required","status":"passed"}
        \\ ]}
    ;
    var receipt = try parseSharedSessionInquiryPreflightAlloc(allocator, raw);
    defer receipt.deinit(allocator);
    try std.testing.expect(receipt.overall_compatible);
    try std.testing.expect(receipt.route_neutral_compatible);
    try std.testing.expect(receipt.paginated_fork_passed);
    try std.testing.expect(receipt.ephemeral_fork_passed);
    try std.testing.expect(receipt.paginated_inquiry_passed);
    try std.testing.expectEqualStrings("/tmp/codex-0.146.0", receipt.codex_path);
    try std.testing.expectEqualStrings("codex-cli 0.146.0", receipt.codex_version);
    try std.testing.expectEqualStrings("/tmp/cache/0.146.0", receipt.cache_dir);
    try std.testing.expectEqualStrings("sha256:3333333333333333333333333333333333333333333333333333333333333333", receipt.code_mode_host_digest.?);
}

test "failed fork witnesses preserve route neutral transcript compatibility" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"schema":"cas-app-server-preflight/v1","action":"preflight","profile":"session-inquiry","status":"incompatible","contractId":"codex-app-server-0.146.0",
        \\ "codex":{"path":"/tmp/codex-0.146.0","version":"0.146.0"},
        \\ "schemas":{"stableDigest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","experimentalDigest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","experimentalPath":"/tmp/cache/0.146.0/experimental"},
        \\ "methods":{"missingRequired":[]},
        \\ "handlerCoverage":{"status":"passed","failures":[]},
        \\ "shapeChecks":{"status":"passed","failures":[]},
        \\ "transport":{"selected":"managed-ws","codeModeHost":null},
        \\ "behavioralProbes":[
        \\  {"id":"initialize-lifecycle","requirement":"required","status":"passed"},
        \\  {"id":"managed-websocket-transport","requirement":"required","status":"passed"},
        \\  {"id":"server-request-coverage","requirement":"required","status":"passed"},
        \\  {"id":"paginated-fork","requirement":"required","status":"failed"},
        \\  {"id":"ephemeral-fork","requirement":"required","status":"passed"},
        \\  {"id":"bounded-overload-retry","requirement":"required","status":"passed"},
        \\  {"id":"paginated-session-inquiry","requirement":"required","status":"failed"}
        \\ ]}
    ;
    var receipt = try parseSharedSessionInquiryPreflightAlloc(allocator, raw);
    defer receipt.deinit(allocator);
    try std.testing.expect(!receipt.overall_compatible);
    try std.testing.expect(receipt.route_neutral_compatible);
    try std.testing.expect(!receipt.paginated_fork_passed);
    try std.testing.expect(receipt.ephemeral_fork_passed);
    try std.testing.expect(!receipt.paginated_inquiry_passed);
}

test "structural incompatibility blocks route neutral transcript compatibility" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"schema":"cas-app-server-preflight/v1","action":"preflight","profile":"session-inquiry","status":"incompatible","contractId":"codex-app-server-0.146.0",
        \\ "codex":{"path":"/tmp/codex-0.146.0","version":"0.146.0"},
        \\ "schemas":{"stableDigest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","experimentalDigest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","experimentalPath":"/tmp/cache/0.146.0/experimental"},
        \\ "methods":{"missingRequired":["thread/start"]},
        \\ "handlerCoverage":{"status":"passed","failures":[]},
        \\ "shapeChecks":{"status":"passed","failures":[]},
        \\ "transport":{"selected":"managed-ws","codeModeHost":null},
        \\ "behavioralProbes":[
        \\  {"id":"initialize-lifecycle","requirement":"required","status":"passed"},
        \\  {"id":"managed-websocket-transport","requirement":"required","status":"passed"},
        \\  {"id":"server-request-coverage","requirement":"required","status":"passed"},
        \\  {"id":"paginated-fork","requirement":"required","status":"failed"},
        \\  {"id":"ephemeral-fork","requirement":"required","status":"failed"},
        \\  {"id":"bounded-overload-retry","requirement":"required","status":"passed"},
        \\  {"id":"paginated-session-inquiry","requirement":"required","status":"failed"}
        \\ ]}
    ;
    var receipt = try parseSharedSessionInquiryPreflightAlloc(allocator, raw);
    defer receipt.deinit(allocator);
    try std.testing.expect(!receipt.overall_compatible);
    try std.testing.expect(!receipt.route_neutral_compatible);
}

test "shared session inquiry probe gate rejects failed or duplicate witnesses" {
    const allocator = std.testing.allocator;
    var failed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[{"id":"paginated-fork","requirement":"required","status":"failed"}]
    , .{});
    defer failed.deinit();
    try std.testing.expect(!requiredBehavioralProbePassed(failed.value, "paginated-fork"));

    var duplicate = try std.json.parseFromSlice(std.json.Value, allocator,
        \\[{"id":"paginated-fork","requirement":"required","status":"passed"},{"id":"paginated-fork","requirement":"required","status":"passed"}]
    , .{});
    defer duplicate.deinit();
    try std.testing.expect(!requiredBehavioralProbePassed(duplicate.value, "paginated-fork"));
}

test "resolveExecutablePathAlloc uses standard fallback paths" {
    if (!fileExists("/opt/homebrew/bin/codex")) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const path = try resolveExecutablePathAlloc(allocator, "codex", "");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/opt/homebrew/bin/codex", path);
}

test "parseFiaAnswerAlloc accepts exact FIA JSON" {
    const allocator = std.testing.allocator;
    const raw =
        \\{
        \\  "fork_inquiry_answer": {
        \\    "answer_version": "FIA-v1",
        \\    "reconstructed_decision": "decide",
        \\    "selected_route": "route-a",
        \\    "rejected_routes": ["route-b"],
        \\    "evidence_refs": ["turn:1"],
        \\    "assumptions": ["assume"],
        \\    "alternatives": ["alt"],
        \\    "route_flip_conditions": ["new evidence"],
        \\    "uncertainty": "medium",
        \\    "hindsight_available": "no",
        \\    "unsupported_claims": []
        \\  }
        \\}
    ;
    const answer = try parseFiaAnswerAlloc(allocator, raw, false);
    defer {
        allocator.free(answer.reconstructed_decision);
        allocator.free(answer.selected_route);
        allocator.free(answer.uncertainty);
        freeStringList(allocator, answer.rejected_routes);
        freeStringList(allocator, answer.evidence_refs);
        freeStringList(allocator, answer.assumptions);
        freeStringList(allocator, answer.alternatives);
        freeStringList(allocator, answer.route_flip_conditions);
        freeStringList(allocator, answer.unsupported_claims);
    }
    try std.testing.expectEqualStrings("route-a", answer.selected_route);
    try std.testing.expect(!answer.hindsight_available);
    try std.testing.expectEqual(@as(usize, 1), answer.evidence_refs.len);
}

test "parseFiaAnswerAlloc accepts root FIA version and leading text" {
    const allocator = std.testing.allocator;
    const raw =
        \\Echo: user prompt
        \\
        \\{
        \\  "answer_version": "FIA-v1",
        \\  "fork_inquiry_answer": {
        \\    "reconstructed_decision": "decide",
        \\    "selected_route": "route-a",
        \\    "rejected_routes": [],
        \\    "evidence_refs": [],
        \\    "assumptions": [],
        \\    "alternatives": [],
        \\    "route_flip_conditions": [],
        \\    "uncertainty": "low",
        \\    "hindsight_available": false,
        \\    "unsupported_claims": []
        \\  }
        \\}
    ;
    const answer = try parseFiaAnswerAlloc(allocator, raw, false);
    defer {
        allocator.free(answer.reconstructed_decision);
        allocator.free(answer.selected_route);
        allocator.free(answer.uncertainty);
        freeStringList(allocator, answer.rejected_routes);
        freeStringList(allocator, answer.evidence_refs);
        freeStringList(allocator, answer.assumptions);
        freeStringList(allocator, answer.alternatives);
        freeStringList(allocator, answer.route_flip_conditions);
        freeStringList(allocator, answer.unsupported_claims);
    }
    try std.testing.expectEqualStrings("route-a", answer.selected_route);
    try std.testing.expect(!answer.hindsight_available);
}

test "parseFiaAnswerAlloc normalizes structured list items" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"fork_inquiry_answer":{"answer_version":"FIA-v1","reconstructed_decision":"d","selected_route":"r","rejected_routes":[],"evidence_refs":[],"assumptions":[],"alternatives":[{"route":"isolated_conformance","why":"smaller"}],"route_flip_conditions":[],"uncertainty":"low","hindsight_available":false,"unsupported_claims":[]}}
    ;
    const answer = try parseFiaAnswerAlloc(allocator, raw, false);
    defer {
        allocator.free(answer.reconstructed_decision);
        allocator.free(answer.selected_route);
        allocator.free(answer.uncertainty);
        freeStringList(allocator, answer.rejected_routes);
        freeStringList(allocator, answer.evidence_refs);
        freeStringList(allocator, answer.assumptions);
        freeStringList(allocator, answer.alternatives);
        freeStringList(allocator, answer.route_flip_conditions);
        freeStringList(allocator, answer.unsupported_claims);
    }
    try std.testing.expectEqual(@as(usize, 1), answer.alternatives.len);
    try std.testing.expect(std.mem.indexOf(u8, answer.alternatives[0], "\"isolated_conformance\"") != null);
}

test "parseFiaAnswerAlloc skips echoed template before real answer" {
    const allocator = std.testing.allocator;
    const raw =
        \\The JSON must match this shape exactly:
        \\{
        \\  "fork_inquiry_answer": {
        \\    "answer_version": "FIA-v1",
        \\    "reconstructed_decision": "<concise answer to the lane question>",
        \\    "selected_route": "<selected route, verdict, or closure decision>",
        \\    "rejected_routes": [],
        \\    "evidence_refs": [],
        \\    "assumptions": [],
        \\    "alternatives": [],
        \\    "route_flip_conditions": [],
        \\    "uncertainty": "low|medium|high",
        \\    "hindsight_available": false,
        \\    "unsupported_claims": []
        \\  }
        \\}
        \\{
        \\  "fork_inquiry_answer": {
        \\    "answer_version": "FIA-v1",
        \\    "reconstructed_decision": "visible context is insufficient",
        \\    "selected_route": "blocked",
        \\    "rejected_routes": [],
        \\    "evidence_refs": ["turn:1"],
        \\    "assumptions": [],
        \\    "alternatives": [],
        \\    "route_flip_conditions": ["provide source transcript"],
        \\    "uncertainty": "high",
        \\    "hindsight_available": false,
        \\    "unsupported_claims": []
        \\  }
        \\}
    ;
    const answer = try parseFiaAnswerAlloc(allocator, raw, false);
    defer {
        allocator.free(answer.reconstructed_decision);
        allocator.free(answer.selected_route);
        allocator.free(answer.uncertainty);
        freeStringList(allocator, answer.rejected_routes);
        freeStringList(allocator, answer.evidence_refs);
        freeStringList(allocator, answer.assumptions);
        freeStringList(allocator, answer.alternatives);
        freeStringList(allocator, answer.route_flip_conditions);
        freeStringList(allocator, answer.unsupported_claims);
    }
    try std.testing.expectEqualStrings("blocked", answer.selected_route);
    try std.testing.expectEqualStrings("high", answer.uncertainty);
}

test "parseFiaAnswerAlloc rejects template-only answer echo" {
    const allocator = std.testing.allocator;
    const raw =
        \\{
        \\  "fork_inquiry_answer": {
        \\    "answer_version": "FIA-v1",
        \\    "reconstructed_decision": "<concise answer to the lane question>",
        \\    "selected_route": "<selected route, verdict, or closure decision>",
        \\    "rejected_routes": [],
        \\    "evidence_refs": [],
        \\    "assumptions": [],
        \\    "alternatives": [],
        \\    "route_flip_conditions": [],
        \\    "uncertainty": "low|medium|high",
        \\    "hindsight_available": false,
        \\    "unsupported_claims": []
        \\  }
        \\}
    ;
    try std.testing.expectError(error.AnswerParseFailed, parseFiaAnswerAlloc(allocator, raw, false));
}

test "parseFiaAnswerAlloc rejects hindsight mismatch" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"fork_inquiry_answer":{"answer_version":"FIA-v1","reconstructed_decision":"d","selected_route":"r","rejected_routes":[],"evidence_refs":[],"assumptions":[],"alternatives":[],"route_flip_conditions":[],"uncertainty":"low","hindsight_available":"yes","unsupported_claims":[]}}
    ;
    try std.testing.expectError(error.HindsightMismatch, parseFiaAnswerAlloc(allocator, raw, false));
}

test "forkPolicyProofFromResponse requires response-backed proof" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"approvalPolicy":"never","activePermissionProfile":{"id":"read-only"},"sandbox":"read-only","thread":{"id":"thr_1","ephemeral":true}}
    ;
    const proof = try forkPolicyProofFromResponse(allocator, raw, "read-only");
    try std.testing.expect(proof.valid());

    const unsafe =
        \\{"approvalPolicy":"never","thread":{"id":"thr_1","ephemeral":false}}
    ;
    const unsafe_proof = try forkPolicyProofFromResponse(allocator, unsafe, "read-only");
    try std.testing.expect(!unsafe_proof.valid());

    const no_readonly_proof =
        \\{"approvalPolicy":"never","thread":{"id":"thr_1","ephemeral":true}}
    ;
    const unproven = try forkPolicyProofFromResponse(allocator, no_readonly_proof, "read-only");
    try std.testing.expect(!unproven.safe());
}

test "detached lane handle round-trips persisted fork turn handle" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
    defer allocator.free(tmp_path);

    const path = try std.fmt.allocPrint(allocator, "{s}/lane.json", .{tmp_path});
    defer allocator.free(path);
    const lane_events = try std.fmt.allocPrint(allocator, "{s}/lane.events.jsonl", .{tmp_path});
    defer allocator.free(lane_events);
    const lane_final = try std.fmt.allocPrint(allocator, "{s}/lane.final.txt", .{tmp_path});
    defer allocator.free(lane_final);
    const lane_receipt = try std.fmt.allocPrint(allocator, "{s}/lane-receipt.json", .{tmp_path});
    defer allocator.free(lane_receipt);
    const workspace_cwd = try std.fmt.allocPrint(allocator, "{s}/work", .{tmp_path});
    defer allocator.free(workspace_cwd);

    const handle = LaneHandle{
        .inquiry_id = "INQ-TEST",
        .lane_id = "rationale",
        .inquiry_mode = "rationale",
        .temporal_horizon = "pre_decision",
        .question = "why",
        .ordinal = 1,
        .source_thread_id = "src",
        .fork_thread_id = "fork",
        .forked_from_id = "src",
        .turn_id = "turn",
        .client_user_message_id = "msg",
        .lane_events = lane_events,
        .lane_final = lane_final,
        .lane_receipt = lane_receipt,
        .lane_state_ref = path,
        .workspace_cwd = workspace_cwd,
        .model = "gpt-test",
        .model_provider = "openai",
        .service_tier = "",
        .codex_version = "codex-cli test",
        .schema_fingerprint = "sha256:test",
        .turns_before = 3,
        .turns_dropped = 2,
        .turns_after = 1,
        .anchor_digest_expected = "sha256:anchor",
        .anchor_digest_observed = "sha256:anchor",
        .expected_hindsight = false,
        .policy_request_count_before = 7,
        .fork_policy = .{ .ephemeral = true, .read_only = true, .approval_never = true },
        .fork_cleaned = true,
    };

    try writeLaneHandle(allocator, handle, @tagName(InquiryState.turn_running));
    const loaded = try loadLaneHandleAlloc(allocator, path);
    defer freeLaneHandle(allocator, loaded);
    try std.testing.expectEqualStrings("INQ-TEST", loaded.inquiry_id);
    try std.testing.expectEqualStrings("fork", loaded.fork_thread_id);
    try std.testing.expectEqualStrings("turn", loaded.turn_id);
    try std.testing.expectEqual(@as(u64, 2), loaded.turns_dropped);
    try std.testing.expectEqual(@as(u64, 7), loaded.policy_request_count_before);
    try std.testing.expect(loaded.fork_policy.valid());
    try std.testing.expect(loaded.fork_cleaned);
}

test "turnDigestFromThreadRead includes live function call records" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"thread":{"id":"thread-1","path":"rollout.jsonl","turns":[{"id":"turn-1","status":"completed","items":[{"type":"userMessage","content":[{"type":"text","text":"run ls"}]},{"type":"function_call","name":"exec_command","call_id":"call-1","arguments":"{\"cmd\":\"ls\",\"cwd\":\"/repo\"}"},{"type":"function_call_output","call_id":"call-1","output":"README.md","command":"ls","cwd":"/repo","exit_code":0},{"type":"agentMessage","text":"done","phase":"final_answer"}]}]}}
    ;
    const observed = try turnDigestFromThreadRead(allocator, raw);
    defer allocator.free(observed.digest);

    var trace = canonical_trace.CanonicalSessionTrace{
        .session = try canonical_trace.SessionRecord.init(allocator, "rollout.jsonl"),
    };
    defer trace.deinit(allocator);
    try trace.turns.append(allocator, .{
        .path = try allocator.dupe(u8, "rollout.jsonl"),
        .turn_id = try allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .status = .complete,
        .user_message = try allocator.dupe(u8, "run ls"),
        .final_answer = try allocator.dupe(u8, "done"),
    });
    try trace.tools.append(allocator, .{
        .path = try allocator.dupe(u8, "rollout.jsonl"),
        .turn_id = try allocator.dupe(u8, "turn-1"),
        .turn_index = 1,
        .call_id = try allocator.dupe(u8, "call-1"),
        .tool_name = try allocator.dupe(u8, "exec_command"),
        .arguments_json = try allocator.dupe(u8, "{\"cmd\":\"ls\",\"cwd\":\"/repo\"}"),
        .output_text = try allocator.dupe(u8, "README.md"),
        .command_text = try allocator.dupe(u8, "ls"),
        .cwd = try allocator.dupe(u8, "/repo"),
        .exit_code = 0,
        .lifecycle_status = .completed,
    });
    const expected = try trace_core.completeTraceDigest(allocator, trace);
    defer allocator.free(expected);
    try std.testing.expectEqual(@as(usize, 1), observed.count);
    try std.testing.expectEqualStrings(expected, observed.digest);
}

test "thread-backed inquiry accepts paginated history and rejects unknown modes" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(ThreadHistoryMode.legacy, try threadHistoryModeFromRead(
        allocator,
        "{\"thread\":{\"id\":\"thread-legacy\",\"historyMode\":\"legacy\",\"turns\":[]}}",
    ));
    try std.testing.expectEqual(ThreadHistoryMode.legacy, try threadHistoryModeFromRead(
        allocator,
        "{\"thread\":{\"id\":\"thread-compatible\",\"turns\":[]}}",
    ));
    try std.testing.expectEqual(ThreadHistoryMode.paginated, try threadHistoryModeFromRead(
        allocator,
        "{\"thread\":{\"id\":\"thread-paginated\",\"historyMode\":\"paginated\",\"turns\":[]}}",
    ));
    try std.testing.expectError(error.ThreadHistoryModeUnsupported, threadHistoryModeFromRead(
        allocator,
        "{\"thread\":{\"id\":\"thread-unknown\",\"historyMode\":\"future\",\"turns\":[]}}",
    ));
    try std.testing.expectEqual(
        FailureCode.thread_history_mode_unsupported,
        failureCodeForError(error.ThreadHistoryModeUnsupported),
    );
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn freeLaneHandle(allocator: std.mem.Allocator, handle: LaneHandle) void {
    allocator.free(handle.inquiry_id);
    allocator.free(handle.lane_id);
    allocator.free(handle.inquiry_mode);
    allocator.free(handle.temporal_horizon);
    allocator.free(handle.question);
    allocator.free(handle.source_thread_id);
    allocator.free(handle.fork_thread_id);
    allocator.free(handle.forked_from_id);
    allocator.free(handle.turn_id);
    allocator.free(handle.client_user_message_id);
    allocator.free(handle.lane_events);
    allocator.free(handle.lane_final);
    allocator.free(handle.lane_receipt);
    allocator.free(handle.lane_state_ref);
    allocator.free(handle.workspace_cwd);
    allocator.free(handle.model);
    allocator.free(handle.model_provider);
    allocator.free(handle.service_tier);
    allocator.free(handle.codex_version);
    allocator.free(handle.schema_fingerprint);
    allocator.free(handle.anchor_digest_expected);
    allocator.free(handle.anchor_digest_observed);
}

fn freeDetachedRecord(allocator: std.mem.Allocator, record: DetachedRecord) void {
    allocator.free(record.inquiry_id);
    allocator.free(record.state);
    allocator.free(record.receipt_dir);
    allocator.free(record.state_ref);
    allocator.free(record.events_ref);
    allocator.free(record.summary_ref);
    allocator.free(record.codex_path);
    allocator.free(record.codex_version);
    allocator.free(record.schema_fingerprint);
    allocator.free(record.code_mode_host_redacted);
    allocator.free(record.code_mode_host_digest);
    allocator.free(record.listen_url);
    allocator.free(record.cwd);
    allocator.free(record.failure_code);
    allocator.free(record.failure_hint);
}
