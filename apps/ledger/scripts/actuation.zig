const app_meta = @import("app_meta");
const actuating_review_policy_cli = @import("actuating_review_policy.zig");
const actuating_review_resolution_cli = @import("actuating_review_resolution.zig");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const std = @import("std");

const Io = std.Io.Threaded.global_single_threaded;
const Version = core_cli.normalizeVersion(app_meta.version);
const ProgramName = "ledger --source actuation";
const DefaultStorePath = ".ledger/actuation/events.jsonl";
const ControlRoot = ".ledger/actuation";
const SourceMemoryControlPaths = [_][]const u8{
    ".ledger/learnings/events.jsonl",
    ".ledger/learnings/events.jsonl.lock",
    ".ledger/negative-ledger/events.jsonl",
    ".ledger/negative-ledger/events.jsonl.lock",
    ".ledger/synesthesia/events.jsonl",
    ".ledger/synesthesia/events.jsonl.lock",
};
const MaxStoreBytes = 64 * 1024 * 1024;
const MaxInputBytes = 4 * 1024 * 1024;
const MaxProcessOutputBytes = 4 * 1024 * 1024;
const MaxAllowedPathScanEntries = 64 * 1024;
const GenesisDigest = "actuation-genesis/v1";
threadlocal var runtime_io: ?std.Io = null;

fn defaultIo() std.Io {
    return if (builtin.is_test) std.testing.io else runtime_io orelse Io.io();
}

const UsageText =
    \\ledger --source actuation
    \\
    \\usage: ledger --source actuation [-h] [--repo PATH] [--path PATH]
    \\       {open,prepare,record,execute,observe,abort,supersede,state,close,decide,
    \\        doctor,path} ...
    \\
    \\Advance one causal actuation-kernel transition per invocation. /goal owns iteration.
    \\
    \\commands:
    \\  open       Bind authority, allowed paths, and verifier-backed obligations
    \\  prepare    Admit one operation and issue a random single-use capability
    \\  record     Consume an edit capability after independently reconciling the file delta
    \\  execute    Consume an inspect/verify capability by running its admitted verifier
    \\  observe    Run the admitted verifier after a recorded edit
    \\  abort      Cancel one unchanged prepared operation without discharging proof
    \\  supersede  Terminally disable a confined stale run and reserve one recovery successor
    \\  state      Fold the event chain and project the next legal transition
    \\  close      Close only after every obligation has a passing observation
    \\  decide     Project a Zig-native closure decision from the live kernel state
    \\  doctor     Validate sequence, hash chain, schemas, and state transitions
    \\  path       Print the resolved actuation event path
    \\
    \\options:
    \\  --repo PATH       Git repository to observe (default: current repository)
    \\  --path PATH       Event store path (default: .ledger/actuation/events.jsonl)
    \\  --json FILE|-     JSON input for open, prepare, or supersede
    \\  --run RUN-ID      Run identity for all post-open transitions
    \\  --step STEP-ID    Step identity for observe
    \\  --capability CAP  Raw capability returned once by prepare
    \\  -h, --help        Show help
    \\  -V, --version     Show version
;

const HelpSurface = core_cli.HelpSurface{
    .executable_name = ProgramName,
    .help_text = UsageText,
};

const Command = enum {
    open,
    prepare,
    record,
    execute,
    observe,
    abort,
    supersede,
    state,
    close,
    decide,
    doctor,
    path,
};

const Args = struct {
    command: ?Command = null,
    repo: []const u8 = ".",
    path: []const u8 = DefaultStorePath,
    json_path: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    step_id: ?[]const u8 = null,
    capability: ?[]const u8 = null,
};

const Effect = enum {
    inspect,
    edit,
    verify,

    fn parse(raw: []const u8) ?Effect {
        inline for (@typeInfo(Effect).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    fn name(self: Effect) []const u8 {
        return @tagName(self);
    }
};

const Phase = enum {
    ready,
    prepared,
    effect_recorded,
    closed,
    superseded,

    fn name(self: Phase) []const u8 {
        return @tagName(self);
    }
};

const GenerationKind = enum {
    legacy_v1,
    implementation,
    review_repair,
    terminal_proof,
    recovery,

    fn parse(raw: []const u8) ?GenerationKind {
        if (std.mem.eql(u8, raw, "implementation")) return .implementation;
        if (std.mem.eql(u8, raw, "review-repair")) return .review_repair;
        if (std.mem.eql(u8, raw, "terminal-proof")) return .terminal_proof;
        if (std.mem.eql(u8, raw, "recovery")) return .recovery;
        return null;
    }

    fn name(self: GenerationKind) []const u8 {
        return switch (self) {
            .legacy_v1 => "legacy-v1",
            .implementation => "implementation",
            .review_repair => "review-repair",
            .terminal_proof => "terminal-proof",
            .recovery => "recovery",
        };
    }
};

const RecoveryReason = enum {
    capability_lost_after_change,
    artifact_stale,
    explicit_user_restart,

    fn parse(raw: []const u8) ?RecoveryReason {
        if (std.mem.eql(u8, raw, "capability-lost-after-change")) {
            return .capability_lost_after_change;
        }
        if (std.mem.eql(u8, raw, "artifact-stale")) return .artifact_stale;
        if (std.mem.eql(u8, raw, "explicit-user-restart")) return .explicit_user_restart;
        return null;
    }

    fn name(self: RecoveryReason) []const u8 {
        return switch (self) {
            .capability_lost_after_change => "capability-lost-after-change",
            .artifact_stale => "artifact-stale",
            .explicit_user_restart => "explicit-user-restart",
        };
    }
};

const Completion = enum {
    complete,
    ready_to_ship,

    fn parse(raw: []const u8) ?Completion {
        if (std.mem.eql(u8, raw, "complete")) return .complete;
        if (std.mem.eql(u8, raw, "ready-to-ship")) return .ready_to_ship;
        return null;
    }

    fn name(self: Completion) []const u8 {
        return switch (self) {
            .complete => "complete",
            .ready_to_ship => "ready-to-ship",
        };
    }
};

const ObligationKind = enum {
    implementation,
    review,
    ship,
    acceptance,

    fn parse(raw: []const u8) ?ObligationKind {
        inline for (@typeInfo(ObligationKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    fn name(self: ObligationKind) []const u8 {
        return @tagName(self);
    }
};

const ObligationInput = struct {
    id: []const u8,
    kind: []const u8,
    statement: []const u8,
    verifier: []const []const u8,
};

const EvidenceInput = struct {
    ref: []const u8,
    digest: []const u8,
};

const EvidenceSnapshot = struct {
    ref: []const u8,
    path: []u8,
    real_path: [:0]u8,
    bytes: []u8,
    stat: std.Io.File.Stat,
    file_identity: FileIdentity,

    fn deinit(self: *EvidenceSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.real_path);
        allocator.free(self.bytes);
    }
};

const ReviewAdmissionInput = struct {
    policy_ref: ?[]const u8 = null,
    policy_digest: ?[]const u8 = null,
    resolution_ref: ?[]const u8 = null,
    resolution_digest: ?[]const u8 = null,
};

const ReviewWorkNodeInput = struct {
    node_id: []const u8,
    run_id: []const u8,
    owner_boundary: []const u8,
    paths: []const []const u8,
    verifier: []const []const u8,
};

const ReviewWorkNodeState = struct {
    node_id: []u8,
    run_id: []u8,
    owner_boundary: []u8,
    paths: [][]u8,
    verifier: [][]u8,

    fn deinit(self: *ReviewWorkNodeState, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.run_id);
        allocator.free(self.owner_boundary);
        freeStringList(allocator, self.paths);
        freeStringList(allocator, self.verifier);
    }

    fn input(self: *const ReviewWorkNodeState) ReviewWorkNodeInput {
        return .{
            .node_id = self.node_id,
            .run_id = self.run_id,
            .owner_boundary = self.owner_boundary,
            .paths = stringSlice(self.paths),
            .verifier = stringSlice(self.verifier),
        };
    }
};

const ReviewPolicyArtifactView = struct {
    repo: []const u8,
    base_ref: []const u8,
    base_sha: []const u8,
    head_sha: []const u8,
    state_fingerprint: []const u8,
};

const ReviewPolicyAdmissionView = struct {
    version: []const u8,
    policy_id: []const u8,
    run_id: []const u8,
    goal_contract_digest: []const u8,
    resolution_digest: ?[]const u8 = null,
    artifact: ReviewPolicyArtifactView,
    review_contract_ref: ?[]const u8 = null,
    review_contract_digest: ?[]const u8 = null,
};

const ReviewPolicyAdmissionEnvelope = struct {
    actuation_review_policy: ReviewPolicyAdmissionView,
};

const ReviewResolutionArtifactView = struct {
    repo: []const u8,
    base_sha: []const u8,
    branch: []const u8,
    head_sha: []const u8,
    state_fingerprint: []const u8,
};

const ReviewResolutionFoldView = struct {
    goal_id: ?[]const u8 = null,
};

const ReviewResolutionProfileView = struct {
    policy_ref: []const u8,
    policy_digest: []const u8,
    review_contract_fingerprint: []const u8,
};

const ReviewResolutionDecisionView = struct {
    selected_work_node: ?ReviewWorkNodeInput = null,
};

const ReviewResolutionOutcomeView = struct {
    status: []const u8,
};

const ReviewResolutionAdmissionView = struct {
    version: []const u8,
    resolution_id: []const u8,
    run_id: []const u8,
    artifact: ReviewResolutionArtifactView,
    review_folds: []const ReviewResolutionFoldView,
    review_profile: ReviewResolutionProfileView,
    decisions: []const ReviewResolutionDecisionView,
    outcome: ReviewResolutionOutcomeView,
};

const ReviewResolutionAdmissionEnvelope = struct {
    review_resolution: ReviewResolutionAdmissionView,
};

const RecoveryAdmissionInput = struct {
    authority_ref: ?[]const u8 = null,
    authority_digest: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

const GenerationAdmissionInput = struct {
    schema: []const u8,
    kind: []const u8,
    predecessor_run_id: ?[]const u8 = null,
    basis: EvidenceInput,
    review: ReviewAdmissionInput = .{},
    recovery: RecoveryAdmissionInput = .{},
};

const OpenInput = struct {
    schema: []const u8,
    run_id: []const u8,
    goal_id: []const u8,
    goal_contract_digest: []const u8,
    resolution_digest: ?[]const u8 = null,
    source_ref: []const u8,
    execution_authority_ref: []const u8,
    mutation_allowed: bool,
    completion: []const u8,
    allowed_paths: []const []const u8,
    obligations: []const ObligationInput,
    generation_admission: GenerationAdmissionInput,
};

const SupersedeInput = struct {
    schema: []const u8,
    basis: EvidenceInput,
    recovery: RecoveryAdmissionInput,
    external_run_id: ?[]const u8 = null,
};

const OperationInput = struct {
    schema: []const u8,
    step_id: []const u8,
    effect: []const u8,
    idempotency_key: []const u8,
    owner_boundary: []const u8,
    paths: []const []const u8,
    obligation_refs: []const []const u8,
};

const PathStateWire = struct {
    path: []const u8,
    digest: []const u8,
};

const RunOpenedBodyV1 = struct {
    schema: []const u8 = "actuation-run-opened/v1",
    goal_id: []const u8,
    goal_contract_digest: []const u8,
    resolution_digest: ?[]const u8,
    source_ref: []const u8,
    execution_authority_ref: []const u8,
    mutation_allowed: bool,
    completion: []const u8,
    repo: []const u8,
    store_path: []const u8,
    allowed_paths: []const []const u8,
    obligations: []const ObligationInput,
    artifact_digest: []const u8,
};

const RunOpenedBodyV2 = struct {
    schema: []const u8 = "actuation-run-opened/v2",
    generation_id: []const u8,
    predecessor_generation_id: ?[]const u8,
    generation_admission: GenerationAdmissionInput,
    review_work_node: ?ReviewWorkNodeInput = null,
    goal_id: []const u8,
    goal_contract_digest: []const u8,
    resolution_digest: ?[]const u8,
    source_ref: []const u8,
    execution_authority_ref: []const u8,
    mutation_allowed: bool,
    completion: []const u8,
    repo: []const u8,
    store_path: []const u8,
    allowed_paths: []const []const u8,
    obligations: []const ObligationInput,
    artifact_digest: []const u8,
    stable_unscoped_digest: []const u8,
    allowed_path_states: []const PathStateWire,
};

const OperationPreparedBody = struct {
    schema: []const u8 = "actuation-operation-prepared/v1",
    step_id: []const u8,
    effect: []const u8,
    idempotency_key: []const u8,
    owner_boundary: []const u8,
    paths: []const []const u8,
    obligation_refs: []const []const u8,
    verifier: []const []const u8,
    capability_digest: []const u8,
    artifact_before: []const u8,
    unscoped_before: []const u8,
    path_states_before: []const PathStateWire,
};

const EffectRecordedBody = struct {
    schema: []const u8 = "actuation-effect-recorded/v1",
    step_id: []const u8,
    effect: []const u8,
    idempotency_key: []const u8,
    capability_digest: []const u8,
    artifact_before: []const u8,
    artifact_after: []const u8,
    unscoped_before: []const u8,
    unscoped_after: []const u8,
    changed_paths: []const []const u8,
    path_states_after: []const PathStateWire,
};

const OperationObservedBody = struct {
    schema: []const u8 = "actuation-operation-observed/v1",
    step_id: []const u8,
    effect: []const u8,
    idempotency_key: []const u8,
    capability_digest: []const u8,
    verifier: []const []const u8,
    obligation_refs: []const []const u8,
    outcome: []const u8,
    exit_code: u8,
    stdout_digest: []const u8,
    stderr_digest: []const u8,
    artifact_before: []const u8,
    artifact_after: []const u8,
    stable_unscoped_after: ?[]const u8 = null,
    allowed_path_states_after: []const PathStateWire = &.{},
};

const OperationAbortedBody = struct {
    schema: []const u8 = "actuation-operation-aborted/v1",
    step_id: []const u8,
    idempotency_key: []const u8,
    capability_digest: []const u8,
    artifact_digest: []const u8,
    unscoped_digest: []const u8,
    path_states: []const PathStateWire,
};

const RunSupersededBody = struct {
    schema: []const u8 = "actuation-run-superseded/v1",
    generation_id: []const u8,
    artifact_before: []const u8,
    artifact_after: []const u8,
    scope_paths: []const []const u8,
    unscoped_before: []const u8,
    unscoped_after: []const u8,
    path_states_before: []const PathStateWire,
    path_states_after: []const PathStateWire,
    changed_paths: []const []const u8,
    recovery_basis: EvidenceInput,
    recovery: RecoveryAdmissionInput,
    external_run_id: ?[]const u8 = null,
    reserved_successor_generation_id: []const u8,
};

const RunClosedBody = struct {
    schema: []const u8 = "actuation-run-closed/v1",
    goal_contract_digest: []const u8,
    artifact_digest: []const u8,
    discharged_obligations: []const []const u8,
};

const EventWire = struct {
    schema: []const u8,
    sequence: u64,
    previous_digest: []const u8,
    run_id: []const u8,
    kind: []const u8,
    recorded_at_unix: i64,
    body: std.json.Value,
    body_digest: []const u8,
    event_digest: []const u8,
};

const ObligationState = struct {
    id: []u8,
    kind: ObligationKind,
    statement: []u8,
    verifier: [][]u8,
    discharged_by: ?[]u8 = null,

    fn deinit(self: *ObligationState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.statement);
        freeStringList(allocator, self.verifier);
        if (self.discharged_by) |step_id| allocator.free(step_id);
    }
};

const PathState = struct {
    path: []u8,
    digest: []u8,

    fn deinit(self: *PathState, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.digest);
    }
};

const Pending = struct {
    step_id: []u8,
    effect: Effect,
    idempotency_key: []u8,
    owner_boundary: []u8,
    paths: [][]u8,
    obligation_refs: [][]u8,
    verifier: [][]u8,
    capability_digest: []u8,
    artifact_before: []u8,
    artifact_after: ?[]u8 = null,
    unscoped_before: []u8,
    path_states_before: []PathState,
    path_states_after: ?[]PathState = null,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        allocator.free(self.step_id);
        allocator.free(self.idempotency_key);
        allocator.free(self.owner_boundary);
        freeStringList(allocator, self.paths);
        freeStringList(allocator, self.obligation_refs);
        freeStringList(allocator, self.verifier);
        allocator.free(self.capability_digest);
        allocator.free(self.artifact_before);
        if (self.artifact_after) |digest| allocator.free(digest);
        allocator.free(self.unscoped_before);
        for (self.path_states_before) |*state| state.deinit(allocator);
        allocator.free(self.path_states_before);
        if (self.path_states_after) |states| freePathStates(allocator, states);
    }
};

const GenerationAdmissionState = struct {
    kind: GenerationKind,
    predecessor_run_id: ?[]u8,
    basis_ref: []u8,
    basis_digest: []u8,
    review_policy_ref: ?[]u8,
    review_policy_digest: ?[]u8,
    review_resolution_ref: ?[]u8,
    review_resolution_digest: ?[]u8,
    recovery_authority_ref: ?[]u8,
    recovery_authority_digest: ?[]u8,
    recovery_reason: ?RecoveryReason,

    fn deinit(self: *GenerationAdmissionState, allocator: std.mem.Allocator) void {
        if (self.predecessor_run_id) |value| allocator.free(value);
        allocator.free(self.basis_ref);
        allocator.free(self.basis_digest);
        if (self.review_policy_ref) |value| allocator.free(value);
        if (self.review_policy_digest) |value| allocator.free(value);
        if (self.review_resolution_ref) |value| allocator.free(value);
        if (self.review_resolution_digest) |value| allocator.free(value);
        if (self.recovery_authority_ref) |value| allocator.free(value);
        if (self.recovery_authority_digest) |value| allocator.free(value);
    }
};

const RunState = struct {
    run_id: []u8,
    generation_id: ?[]u8 = null,
    predecessor_generation_id: ?[]u8 = null,
    admission: ?GenerationAdmissionState = null,
    review_work_node: ?ReviewWorkNodeState = null,
    goal_id: []u8,
    goal_contract_digest: []u8,
    resolution_digest: ?[]u8,
    source_ref: []u8,
    execution_authority_ref: []u8,
    mutation_allowed: bool,
    completion: Completion,
    repo: []u8,
    store_path: []u8,
    allowed_paths: [][]u8,
    obligations: []ObligationState,
    step_ids: std.ArrayList([]u8) = .empty,
    idempotency_keys: std.ArrayList([]u8) = .empty,
    artifact_digest: []u8,
    stable_unscoped_digest: ?[]u8 = null,
    stable_path_states: ?[]PathState = null,
    reserved_successor_generation_id: ?[]u8 = null,
    phase: Phase = .ready,
    pending: ?Pending = null,

    fn deinit(self: *RunState, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        if (self.generation_id) |value| allocator.free(value);
        if (self.predecessor_generation_id) |value| allocator.free(value);
        if (self.admission) |*value| value.deinit(allocator);
        if (self.review_work_node) |*value| value.deinit(allocator);
        allocator.free(self.goal_id);
        allocator.free(self.goal_contract_digest);
        if (self.resolution_digest) |digest| allocator.free(digest);
        allocator.free(self.source_ref);
        allocator.free(self.execution_authority_ref);
        allocator.free(self.repo);
        allocator.free(self.store_path);
        freeStringList(allocator, self.allowed_paths);
        for (self.obligations) |*obligation| obligation.deinit(allocator);
        allocator.free(self.obligations);
        freeOwnedArrayList(allocator, &self.step_ids);
        freeOwnedArrayList(allocator, &self.idempotency_keys);
        allocator.free(self.artifact_digest);
        if (self.stable_unscoped_digest) |value| allocator.free(value);
        if (self.stable_path_states) |states| freePathStates(allocator, states);
        if (self.reserved_successor_generation_id) |value| allocator.free(value);
        if (self.pending) |*pending| pending.deinit(allocator);
    }
};

const RunIndexEntry = struct {
    run_id: []u8,
    goal_id: []u8,
    goal_contract_digest: []u8,
    generation_id: ?[]u8,
    predecessor_run_id: ?[]u8,
    kind: GenerationKind,
    phase: Phase,
    mutation_allowed: bool,
    allowed_paths: [][]u8,
    review_work_node: ?ReviewWorkNodeState = null,
    artifact_digest: []u8,
    reserved_successor_generation_id: ?[]u8,
    recovery_contract_digest: []u8,

    fn deinit(self: *RunIndexEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.goal_id);
        allocator.free(self.goal_contract_digest);
        if (self.generation_id) |value| allocator.free(value);
        if (self.predecessor_run_id) |value| allocator.free(value);
        freeStringList(allocator, self.allowed_paths);
        if (self.review_work_node) |*value| value.deinit(allocator);
        allocator.free(self.artifact_digest);
        if (self.reserved_successor_generation_id) |value| allocator.free(value);
        allocator.free(self.recovery_contract_digest);
    }
};

const LedgerLoad = struct {
    event_count: u64 = 0,
    last_digest: []u8,
    store_revision: []u8,
    store_exists: bool,
    state: ?RunState = null,
    run_index: []RunIndexEntry,

    fn deinit(self: *LedgerLoad, allocator: std.mem.Allocator) void {
        allocator.free(self.last_digest);
        allocator.free(self.store_revision);
        if (self.state) |*state| state.deinit(allocator);
        for (self.run_index) |*entry| entry.deinit(allocator);
        allocator.free(self.run_index);
    }
};

const TransitionResult = struct {
    run_id: []u8,
    goal_id: ?[]u8 = null,
    event_digest: []u8,
    artifact_digest: []u8,
    generation_id: ?[]u8 = null,
    generation_kind: ?GenerationKind = null,
    predecessor_generation_id: ?[]u8 = null,
    reserved_successor_generation_id: ?[]u8 = null,
    capability: ?[]u8 = null,
    passed: ?bool = null,
    exit_code: ?u8 = null,

    fn deinit(self: *TransitionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        if (self.goal_id) |value| allocator.free(value);
        allocator.free(self.event_digest);
        allocator.free(self.artifact_digest);
        if (self.generation_id) |value| allocator.free(value);
        if (self.predecessor_generation_id) |value| allocator.free(value);
        if (self.reserved_successor_generation_id) |value| allocator.free(value);
        if (self.capability) |value| allocator.free(value);
    }
};

const ProcessResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const DecisionProjection = struct {
    terminal: bool,
    verdict: []const u8,
    goal_outcome: []const u8,
    implementation_outcome: []const u8,
    next_owner: []const u8,
    next_transition: []const u8,
};

const DecisionBasis = enum {
    evidence,
    review,
    ship,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const code = try runWithArgv(allocator, init.io, argv);
    if (code != 0) std.process.exit(code);
}

pub fn runWithArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const previous_io = runtime_io;
    runtime_io = io;
    defer runtime_io = previous_io;
    return runWithArgvInner(allocator, argv) catch |err| {
        try printFailure(allocator, err);
        return 2;
    };
}

fn runWithArgvInner(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    if (argv.len <= 1 or core_cli.isHelpArg(argv[1])) {
        try printHelp();
        return 0;
    }
    if (core_cli.isVersionArg(argv[1]) or core_cli.isVersionSubcommand(argv[1])) {
        var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
        try core_cli.printVersion(&stdout_writer.interface, Version);
        return 0;
    }

    const args = parseArgs(argv) catch |err| {
        core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
    };
    if (core_cli.containsHelpArg(argv[1..])) {
        try printHelp();
        return 0;
    }

    const repo = try discoverRepoRootAlloc(allocator, args.repo);
    defer allocator.free(repo);
    const store_path = try resolveStorePathAlloc(allocator, repo, args.path);
    defer allocator.free(store_path);

    switch (args.command orelse return error.MissingCommand) {
        .open => {
            const input = try readInputAlloc(allocator, args.json_path.?);
            defer allocator.free(input);
            var result = try cmdOpen(allocator, repo, store_path, input);
            defer result.deinit(allocator);
            try printTransitionResult(allocator, args.command.?, args.run_id, result);
            return 0;
        },
        .prepare => {
            const input = try readInputAlloc(allocator, args.json_path.?);
            defer allocator.free(input);
            var result = try cmdPrepare(allocator, repo, store_path, args.run_id.?, input);
            defer result.deinit(allocator);
            try printTransitionResult(allocator, args.command.?, args.run_id, result);
            return 0;
        },
        .record => {
            var result = try cmdRecord(allocator, repo, store_path, args.run_id.?, args.capability.?);
            defer result.deinit(allocator);
            try printTransitionResult(allocator, args.command.?, args.run_id, result);
            return 0;
        },
        .execute => {
            var result = try cmdExecute(allocator, repo, store_path, args.run_id.?, args.capability.?);
            defer result.deinit(allocator);
            try printTransitionResult(allocator, args.command.?, args.run_id, result);
            return if (result.passed == true) 0 else 2;
        },
        .observe => {
            var result = try cmdObserve(allocator, repo, store_path, args.run_id.?, args.step_id.?);
            defer result.deinit(allocator);
            try printTransitionResult(allocator, args.command.?, args.run_id, result);
            return if (result.passed == true) 0 else 2;
        },
        .abort => {
            var result = try cmdAbort(allocator, repo, store_path, args.run_id.?);
            defer result.deinit(allocator);
            try printTransitionResult(allocator, args.command.?, args.run_id, result);
            return 0;
        },
        .supersede => {
            const input = try readInputAlloc(allocator, args.json_path.?);
            defer allocator.free(input);
            var result = try cmdSupersede(allocator, repo, store_path, args.run_id.?, input);
            defer result.deinit(allocator);
            try printTransitionResult(allocator, args.command.?, args.run_id, result);
            return 0;
        },
        .state => {
            try cmdState(allocator, repo, store_path, args.run_id.?);
            return 0;
        },
        .close => {
            var result = try cmdClose(allocator, repo, store_path, args.run_id.?);
            defer result.deinit(allocator);
            try printTransitionResult(allocator, args.command.?, args.run_id, result);
            return 0;
        },
        .decide => {
            try cmdDecide(allocator, repo, store_path, args.run_id.?);
            return 0;
        },
        .doctor => {
            try cmdDoctor(allocator, store_path);
            return 0;
        },
        .path => {
            var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
            try stdout_writer.interface.print("{s}\n", .{store_path});
            return 0;
        },
    }
}

fn printHelp() !void {
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try core_cli.printHelpSurface(&stdout_writer.interface, HelpSurface, Version);
}

fn printFailure(allocator: std.mem.Allocator, err: anyerror) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"actuation-error/v1\",\"verdict\":\"blocked\",\"error\":");
    try std.json.Stringify.value(@errorName(err), .{}, &out.writer);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const token = argv[i];
        if (core_cli.isHelpArg(token)) continue;
        if (std.mem.eql(u8, token, "--repo")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.repo = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--path")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--json")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.json_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--run")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.run_id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--step")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.step_id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--capability")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.capability = argv[i];
            continue;
        }
        if (!std.mem.startsWith(u8, token, "-") and args.command == null) {
            args.command = parseCommand(token) orelse return error.UnknownCommand;
            continue;
        }
        return error.UnknownOption;
    }

    const command = args.command orelse return error.MissingCommand;
    if ((command == .open or command == .prepare or command == .supersede) and
        args.json_path == null)
    {
        return error.MissingJsonInput;
    }
    if (command != .open and command != .doctor and command != .path and args.run_id == null) return error.MissingRunId;
    if ((command == .record or command == .execute) and args.capability == null) return error.MissingCapability;
    if (command == .observe and args.step_id == null) return error.MissingStepId;
    return args;
}

fn parseCommand(raw: []const u8) ?Command {
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn cmdOpen(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    input_json: []const u8,
) !TransitionResult {
    var parsed = try std.json.parseFromSlice(OpenInput, allocator, input_json, .{});
    defer parsed.deinit();
    const input = parsed.value;
    const validated = try validateOpenInput(input);
    try validateActuationStorePath(allocator, repo, store_path);
    try validateAllowedPathsAgainstStore(
        allocator,
        repo,
        store_path,
        input.allowed_paths,
    );
    if (!builtin.is_test) try ensureStoreLockIgnored(allocator, repo, store_path);

    var persistence = durable_store.PersistentEventStore.init(store_path);
    var exclusive = try acquireActuationExclusive(allocator, persistence.eventStore());
    defer exclusive.release();
    var loaded = try loadLedgerExclusive(allocator, &exclusive, input.run_id);
    defer loaded.deinit(allocator);
    if (loaded.state != null) return error.DuplicateRunId;
    if (findRunIndex(loaded.run_index, input.run_id) != null) return error.DuplicateRunId;

    var review_work_node = try validateAdmissionEvidence(
        allocator,
        repo,
        store_path,
        input,
        validated.kind,
    );
    defer if (review_work_node) |*value| value.deinit(allocator);
    const artifact = try repositoryArtifactDigestAlloc(
        allocator,
        repo,
        store_path,
        input.allowed_paths,
    );
    defer allocator.free(artifact);

    const predecessor_run_id_opt = input.generation_admission.predecessor_run_id;
    const predecessor = if (predecessor_run_id_opt) |predecessor_run_id| blk: {
        break :blk findRunIndex(loaded.run_index, predecessor_run_id) orelse
            return error.PredecessorRunNotFound;
    } else null;
    if (validated.kind == .recovery) {
        if (predecessor.?.review_work_node) |*node| {
            review_work_node = try reviewWorkNodeStateFromInput(allocator, node.input());
        }
    }
    const predecessor_generation_id = if (predecessor) |entry|
        entry.generation_id orelse return error.LegacyPredecessorUnsupported
    else
        null;
    const generation_id = try generationIdAlloc(
        allocator,
        input,
        validated.kind,
        validated.completion,
        artifact,
        predecessor_generation_id,
        if (review_work_node) |*value| value.input() else null,
    );
    defer allocator.free(generation_id);
    try validateOpenLineage(
        allocator,
        input,
        validated,
        generation_id,
        predecessor,
        loaded.run_index,
        if (review_work_node) |*value| value.input() else null,
    );

    const stable_unscoped_digest = try unscopedDigestAlloc(
        allocator,
        repo,
        store_path,
        input.allowed_paths,
        input.allowed_paths,
    );
    defer allocator.free(stable_unscoped_digest);
    const allowed_path_states = try snapshotPathStatesAlloc(
        allocator,
        repo,
        store_path,
        input.allowed_paths,
    );
    defer freePathStates(allocator, allowed_path_states);
    const allowed_path_wires = try pathStateWiresAlloc(allocator, allowed_path_states);
    defer allocator.free(allowed_path_wires);

    const body = RunOpenedBodyV2{
        .generation_id = generation_id,
        .predecessor_generation_id = predecessor_generation_id,
        .generation_admission = input.generation_admission,
        .review_work_node = if (review_work_node) |*value| value.input() else null,
        .goal_id = input.goal_id,
        .goal_contract_digest = input.goal_contract_digest,
        .resolution_digest = input.resolution_digest,
        .source_ref = input.source_ref,
        .execution_authority_ref = input.execution_authority_ref,
        .mutation_allowed = input.mutation_allowed,
        .completion = validated.completion.name(),
        .repo = repo,
        .store_path = store_path,
        .allowed_paths = input.allowed_paths,
        .obligations = input.obligations,
        .artifact_digest = artifact,
        .stable_unscoped_digest = stable_unscoped_digest,
        .allowed_path_states = allowed_path_wires,
    };
    const body_json = try encodeBodyAlloc(allocator, body);
    defer allocator.free(body_json);
    const event_digest = try appendEventAlloc(allocator, &exclusive, loaded, input.run_id, "run_opened", body_json);
    errdefer allocator.free(event_digest);
    return .{
        .run_id = try allocator.dupe(u8, input.run_id),
        .goal_id = try allocator.dupe(u8, input.goal_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, artifact),
        .generation_id = try allocator.dupe(u8, generation_id),
        .generation_kind = validated.kind,
        .predecessor_generation_id = if (predecessor_generation_id) |value|
            try allocator.dupe(u8, value)
        else
            null,
    };
}

fn ensureStoreLockIgnored(allocator: std.mem.Allocator, repo: []const u8, store_path: []const u8) !void {
    const store_relative = try storeRelativeAlloc(allocator, repo, store_path);
    defer if (store_relative) |value| allocator.free(value);
    const relative = store_relative orelse return;
    const lock_relative = try std.fmt.allocPrint(allocator, "{s}.lock", .{relative});
    defer allocator.free(lock_relative);
    const result = try std.process.run(allocator, defaultIo(), .{
        .argv = &.{ "git", "check-ignore", "-q", "--", lock_relative },
        .cwd = .{ .path = repo },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (exitCode(result.term)) {
        0 => return,
        1 => return error.LockSidecarNotGitignored,
        else => return error.GitCommandFailed,
    }
}

fn validateActuationStorePath(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
) !void {
    durable_store.rejectSymlinkComponents(store_path) catch {
        return error.ReservedActuationStorePath;
    };
    const relative = try storeRelativeAlloc(allocator, repo, store_path);
    defer if (relative) |value| allocator.free(value);
    if (relative) |path| if (pathOverlapsAny(path, SourceMemoryControlPaths[0..])) {
        return error.ReservedActuationStorePath;
    };
    for (SourceMemoryControlPaths) |control_ref| {
        const control_path = try std.fs.path.join(allocator, &.{ repo, control_ref });
        defer allocator.free(control_path);
        if (try physicalPathsAliasOrOverlap(allocator, store_path, control_path)) {
            return error.ReservedActuationStorePath;
        }
    }
}

fn physicalPathsAliasOrOverlap(
    allocator: std.mem.Allocator,
    left_path: []const u8,
    right_path: []const u8,
) !bool {
    var left = try physicalPathIdentityAlloc(allocator, left_path);
    defer left.deinit(allocator);
    var right = try physicalPathIdentityAlloc(allocator, right_path);
    defer right.deinit(allocator);
    return identityAliasesAny(&left, &.{right});
}

fn cmdPrepare(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
    input_json: []const u8,
) !TransitionResult {
    var parsed = try std.json.parseFromSlice(OperationInput, allocator, input_json, .{});
    defer parsed.deinit();
    const operation = parsed.value;
    const effect = try validateOperationInput(operation);

    var persistence = durable_store.PersistentEventStore.init(store_path);
    var exclusive = try acquireActuationExclusive(allocator, persistence.eventStore());
    defer exclusive.release();
    var loaded = try loadLedgerExclusive(allocator, &exclusive, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(allocator, state, repo, store_path);
    try validateWritableGeneration(state);
    if (state.phase != .ready) return error.InvalidPhase;
    if (containsString(state.step_ids.items, operation.step_id)) return error.DuplicateStepId;
    if (containsString(state.idempotency_keys.items, operation.idempotency_key)) return error.DuplicateIdempotencyKey;
    if (effect == .edit and !state.mutation_allowed) return error.MutationForbidden;
    try validateOperationPaths(state.allowed_paths, operation.paths);

    const verifier = try commonVerifierForRefs(state, operation.obligation_refs);
    try validateReviewWorkOperation(
        allocator,
        state,
        effect,
        operation.owner_boundary,
        operation.paths,
        stringSlice(verifier),
    );
    try validateStateEvidencePhysicalScope(allocator, repo, state, operation.paths);
    const current_artifact = try repositoryArtifactDigestAlloc(allocator, repo, store_path, stringSlice(state.allowed_paths));
    defer allocator.free(current_artifact);
    if (!std.mem.eql(u8, current_artifact, state.artifact_digest)) return error.ArtifactStale;

    const raw_capability = try randomCapabilityAlloc(allocator);
    errdefer allocator.free(raw_capability);
    const capability_digest = try digestTextAlloc(allocator, raw_capability);
    defer allocator.free(capability_digest);
    const unscoped_before = try unscopedDigestAlloc(allocator, repo, store_path, operation.paths, stringSlice(state.allowed_paths));
    defer allocator.free(unscoped_before);
    const path_states = try snapshotPathStatesAlloc(allocator, repo, store_path, operation.paths);
    defer freePathStates(allocator, path_states);
    const path_wires = try pathStateWiresAlloc(allocator, path_states);
    defer allocator.free(path_wires);

    const body = OperationPreparedBody{
        .step_id = operation.step_id,
        .effect = effect.name(),
        .idempotency_key = operation.idempotency_key,
        .owner_boundary = operation.owner_boundary,
        .paths = operation.paths,
        .obligation_refs = operation.obligation_refs,
        .verifier = stringSlice(verifier),
        .capability_digest = capability_digest,
        .artifact_before = current_artifact,
        .unscoped_before = unscoped_before,
        .path_states_before = path_wires,
    };
    const body_json = try encodeBodyAlloc(allocator, body);
    defer allocator.free(body_json);
    const event_digest = try appendEventAlloc(allocator, &exclusive, loaded, run_id, "operation_prepared", body_json);
    errdefer allocator.free(event_digest);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .goal_id = try allocator.dupe(u8, state.goal_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, current_artifact),
        .generation_id = if (state.generation_id) |value| try allocator.dupe(u8, value) else null,
        .generation_kind = if (state.admission) |admission| admission.kind else .legacy_v1,
        .predecessor_generation_id = if (state.predecessor_generation_id) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .capability = raw_capability,
    };
}

fn cmdRecord(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
    raw_capability: []const u8,
) !TransitionResult {
    var persistence = durable_store.PersistentEventStore.init(store_path);
    var exclusive = try acquireActuationExclusive(allocator, persistence.eventStore());
    defer exclusive.release();
    var loaded = try loadLedgerExclusive(allocator, &exclusive, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(allocator, state, repo, store_path);
    try validateWritableGeneration(state);
    if (state.phase != .prepared) return error.InvalidPhase;
    const pending = if (state.pending) |*value| value else return error.PendingOperationMissing;
    if (pending.effect != .edit) return error.RecordRequiresEdit;
    try validateCapability(allocator, pending.capability_digest, raw_capability);
    try validateStateEvidencePhysicalScope(
        allocator,
        repo,
        state,
        stringSlice(pending.paths),
    );

    const artifact_after = try repositoryArtifactDigestAlloc(allocator, repo, store_path, stringSlice(state.allowed_paths));
    defer allocator.free(artifact_after);
    if (std.mem.eql(u8, artifact_after, pending.artifact_before)) return error.EditDidNotChangeArtifact;

    const unscoped_after = try unscopedDigestAlloc(allocator, repo, store_path, stringSlice(pending.paths), stringSlice(state.allowed_paths));
    defer allocator.free(unscoped_after);
    if (!std.mem.eql(u8, unscoped_after, pending.unscoped_before)) return error.OutOfScopeMutation;

    const path_states_after = try snapshotPathStatesAlloc(
        allocator,
        repo,
        store_path,
        stringSlice(pending.paths),
    );
    defer freePathStates(allocator, path_states_after);
    if (!allPathStatesChanged(pending.path_states_before, path_states_after)) return error.DeclaredPathUnchanged;
    const path_wires = try pathStateWiresAlloc(allocator, path_states_after);
    defer allocator.free(path_wires);

    const body = EffectRecordedBody{
        .step_id = pending.step_id,
        .effect = pending.effect.name(),
        .idempotency_key = pending.idempotency_key,
        .capability_digest = pending.capability_digest,
        .artifact_before = pending.artifact_before,
        .artifact_after = artifact_after,
        .unscoped_before = pending.unscoped_before,
        .unscoped_after = unscoped_after,
        .changed_paths = stringSlice(pending.paths),
        .path_states_after = path_wires,
    };
    const body_json = try encodeBodyAlloc(allocator, body);
    defer allocator.free(body_json);
    const event_digest = try appendEventAlloc(allocator, &exclusive, loaded, run_id, "effect_recorded", body_json);
    errdefer allocator.free(event_digest);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .goal_id = try allocator.dupe(u8, state.goal_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, artifact_after),
        .generation_id = if (state.generation_id) |value| try allocator.dupe(u8, value) else null,
        .generation_kind = if (state.admission) |admission| admission.kind else .legacy_v1,
        .predecessor_generation_id = if (state.predecessor_generation_id) |value|
            try allocator.dupe(u8, value)
        else
            null,
    };
}

fn cmdExecute(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
    raw_capability: []const u8,
) !TransitionResult {
    return observeOperation(allocator, repo, store_path, run_id, null, raw_capability, true);
}

fn cmdObserve(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
    step_id: []const u8,
) !TransitionResult {
    return observeOperation(allocator, repo, store_path, run_id, step_id, null, false);
}

fn observeOperation(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
    expected_step_id: ?[]const u8,
    raw_capability: ?[]const u8,
    direct_execute: bool,
) !TransitionResult {
    var persistence = durable_store.PersistentEventStore.init(store_path);
    var exclusive = try acquireActuationExclusive(allocator, persistence.eventStore());
    defer exclusive.release();
    var loaded = try loadLedgerExclusive(allocator, &exclusive, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(allocator, state, repo, store_path);
    try validateWritableGeneration(state);
    const expected_phase: Phase = if (direct_execute) .prepared else .effect_recorded;
    if (state.phase != expected_phase) return error.InvalidPhase;
    const pending = if (state.pending) |*value| value else return error.PendingOperationMissing;
    if (direct_execute) {
        if (pending.effect == .edit) return error.ExecuteRejectsEdit;
        try validateCapability(allocator, pending.capability_digest, raw_capability.?);
    } else {
        if (pending.effect != .edit) return error.ObserveRequiresRecordedEdit;
        if (!std.mem.eql(u8, pending.step_id, expected_step_id.?)) return error.StepMismatch;
    }

    const artifact_before = pending.artifact_after orelse pending.artifact_before;
    const current_artifact = try repositoryArtifactDigestAlloc(allocator, repo, store_path, stringSlice(state.allowed_paths));
    defer allocator.free(current_artifact);
    if (!std.mem.eql(u8, artifact_before, current_artifact)) return error.ArtifactStale;

    var process = try runProcessAlloc(allocator, repo, stringSlice(pending.verifier));
    defer process.deinit(allocator);
    const artifact_after = try repositoryArtifactDigestAlloc(allocator, repo, store_path, stringSlice(state.allowed_paths));
    defer allocator.free(artifact_after);
    const artifact_unchanged = std.mem.eql(u8, artifact_before, artifact_after);
    if (!artifact_unchanged) return error.VerifierMutatedArtifact;
    const passed = process.exit_code == 0;
    const stdout_digest = try digestTextAlloc(allocator, process.stdout);
    defer allocator.free(stdout_digest);
    const stderr_digest = try digestTextAlloc(allocator, process.stderr);
    defer allocator.free(stderr_digest);
    const stable_unscoped_after = try unscopedDigestAlloc(
        allocator,
        repo,
        store_path,
        stringSlice(state.allowed_paths),
        stringSlice(state.allowed_paths),
    );
    defer allocator.free(stable_unscoped_after);
    const allowed_path_states_after = try snapshotPathStatesAlloc(
        allocator,
        repo,
        store_path,
        stringSlice(state.allowed_paths),
    );
    defer freePathStates(allocator, allowed_path_states_after);
    const allowed_path_wires_after = try pathStateWiresAlloc(allocator, allowed_path_states_after);
    defer allocator.free(allowed_path_wires_after);

    const body = OperationObservedBody{
        .step_id = pending.step_id,
        .effect = pending.effect.name(),
        .idempotency_key = pending.idempotency_key,
        .capability_digest = pending.capability_digest,
        .verifier = stringSlice(pending.verifier),
        .obligation_refs = stringSlice(pending.obligation_refs),
        .outcome = if (passed) "passed" else "failed",
        .exit_code = process.exit_code,
        .stdout_digest = stdout_digest,
        .stderr_digest = stderr_digest,
        .artifact_before = artifact_before,
        .artifact_after = artifact_after,
        .stable_unscoped_after = stable_unscoped_after,
        .allowed_path_states_after = allowed_path_wires_after,
    };
    const body_json = try encodeBodyAlloc(allocator, body);
    defer allocator.free(body_json);
    const event_digest = try appendEventAlloc(allocator, &exclusive, loaded, run_id, "operation_observed", body_json);
    errdefer allocator.free(event_digest);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .goal_id = try allocator.dupe(u8, state.goal_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, artifact_after),
        .generation_id = if (state.generation_id) |value| try allocator.dupe(u8, value) else null,
        .generation_kind = if (state.admission) |admission| admission.kind else .legacy_v1,
        .predecessor_generation_id = if (state.predecessor_generation_id) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .passed = passed,
        .exit_code = process.exit_code,
    };
}

fn cmdAbort(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
) !TransitionResult {
    var persistence = durable_store.PersistentEventStore.init(store_path);
    var exclusive = try acquireActuationExclusive(allocator, persistence.eventStore());
    defer exclusive.release();
    var loaded = try loadLedgerExclusive(allocator, &exclusive, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(allocator, state, repo, store_path);
    try validateWritableGeneration(state);
    if (state.phase != .prepared) return error.InvalidPhase;
    const pending = if (state.pending) |*value| value else return error.PendingOperationMissing;

    const current_artifact = try repositoryArtifactDigestAlloc(
        allocator,
        repo,
        store_path,
        stringSlice(state.allowed_paths),
    );
    defer allocator.free(current_artifact);
    if (!std.mem.eql(u8, current_artifact, pending.artifact_before)) {
        return error.AbortArtifactChanged;
    }
    const current_unscoped = try unscopedDigestAlloc(
        allocator,
        repo,
        store_path,
        stringSlice(pending.paths),
        stringSlice(state.allowed_paths),
    );
    defer allocator.free(current_unscoped);
    if (!std.mem.eql(u8, current_unscoped, pending.unscoped_before)) {
        return error.AbortUnscopedChanged;
    }
    const current_path_states = try snapshotPathStatesAlloc(
        allocator,
        repo,
        store_path,
        stringSlice(pending.paths),
    );
    defer freePathStates(allocator, current_path_states);
    if (!equalPathStates(pending.path_states_before, current_path_states)) {
        return error.AbortPathChanged;
    }
    const current_path_wires = try pathStateWiresAlloc(allocator, current_path_states);
    defer allocator.free(current_path_wires);

    const body = OperationAbortedBody{
        .step_id = pending.step_id,
        .idempotency_key = pending.idempotency_key,
        .capability_digest = pending.capability_digest,
        .artifact_digest = current_artifact,
        .unscoped_digest = current_unscoped,
        .path_states = current_path_wires,
    };
    const body_json = try encodeBodyAlloc(allocator, body);
    defer allocator.free(body_json);
    const event_digest = try appendEventAlloc(
        allocator,
        &exclusive,
        loaded,
        run_id,
        "operation_aborted",
        body_json,
    );
    errdefer allocator.free(event_digest);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .goal_id = try allocator.dupe(u8, state.goal_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, current_artifact),
        .generation_id = if (state.generation_id) |value| try allocator.dupe(u8, value) else null,
        .generation_kind = if (state.admission) |admission| admission.kind else .legacy_v1,
        .predecessor_generation_id = if (state.predecessor_generation_id) |value|
            try allocator.dupe(u8, value)
        else
            null,
    };
}

fn cmdSupersede(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
    input_json: []const u8,
) !TransitionResult {
    var parsed = try std.json.parseFromSlice(SupersedeInput, allocator, input_json, .{});
    defer parsed.deinit();
    const input = parsed.value;
    const recovery_reason = try validateSupersedeInput(input);
    var basis_snapshot = try openEvidenceSnapshot(allocator, repo, input.basis);
    defer basis_snapshot.deinit(allocator);
    const authority_input = EvidenceInput{
        .ref = input.recovery.authority_ref.?,
        .digest = input.recovery.authority_digest.?,
    };
    var authority_snapshot = if (std.mem.eql(u8, input.basis.ref, authority_input.ref) and
        std.mem.eql(u8, input.basis.digest, authority_input.digest))
        null
    else
        try openEvidenceSnapshot(allocator, repo, authority_input);
    defer if (authority_snapshot) |*snapshot| snapshot.deinit(allocator);

    var persistence = durable_store.PersistentEventStore.init(store_path);
    var exclusive = try acquireActuationExclusive(allocator, persistence.eventStore());
    defer exclusive.release();
    var loaded = try loadLedgerExclusive(allocator, &exclusive, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(allocator, state, repo, store_path);
    try validateWritableGeneration(state);
    try validateEvidenceOutsideMutationScope(input.basis.ref, stringSlice(state.allowed_paths));
    try validateEvidenceOutsideMutationScope(
        input.recovery.authority_ref.?,
        stringSlice(state.allowed_paths),
    );
    try validateEvidenceSnapshotPhysicalScope(
        allocator,
        repo,
        store_path,
        &basis_snapshot,
        stringSlice(state.allowed_paths),
    );
    if (authority_snapshot) |*snapshot| {
        try validateEvidenceSnapshotPhysicalScope(
            allocator,
            repo,
            store_path,
            snapshot,
            stringSlice(state.allowed_paths),
        );
    }
    const generation_id = state.generation_id orelse return error.LegacyRunRecoveryUnsupported;
    if (state.phase == .closed or state.phase == .superseded) return error.InvalidPhase;
    if (state.phase != .ready and
        state.phase != .prepared and
        state.phase != .effect_recorded)
    {
        return error.InvalidPhase;
    }
    switch (state.phase) {
        .ready => {
            if (recovery_reason != .artifact_stale and
                recovery_reason != .explicit_user_restart)
            {
                return error.InvalidRecoveryReasonForPhase;
            }
            if (input.external_run_id == null) return error.ExternalMutationRunRequired;
        },
        .prepared => {
            if (input.external_run_id != null) return error.UnexpectedExternalMutationRun;
            const pending = state.pending orelse return error.PendingOperationMissing;
            if (!state.mutation_allowed or pending.effect != .edit) {
                return error.PreparedSupersedeRequiresEdit;
            }
            if (recovery_reason != .capability_lost_after_change and
                recovery_reason != .explicit_user_restart)
            {
                return error.InvalidRecoveryReasonForPhase;
            }
        },
        .effect_recorded => {
            if (input.external_run_id != null) return error.UnexpectedExternalMutationRun;
            if (recovery_reason != .artifact_stale and
                recovery_reason != .explicit_user_restart)
            {
                return error.InvalidRecoveryReasonForPhase;
            }
        },
        .closed, .superseded => unreachable,
    }

    const current_artifact = try repositoryArtifactDigestAlloc(
        allocator,
        repo,
        store_path,
        stringSlice(state.allowed_paths),
    );
    defer allocator.free(current_artifact);
    const supersession_artifact_before = if (state.phase == .effect_recorded)
        (state.pending orelse return error.PendingOperationMissing).artifact_before
    else
        state.artifact_digest;
    if (std.mem.eql(u8, current_artifact, supersession_artifact_before)) {
        return error.SupersedeRequiresArtifactChange;
    }
    if (state.phase == .effect_recorded) {
        const recorded = (state.pending orelse return error.PendingOperationMissing)
            .artifact_after orelse return error.StableSnapshotMissing;
        if (!std.mem.eql(u8, current_artifact, recorded)) {
            return error.UnpreparedMutationAfterRecord;
        }
    }
    if (input.external_run_id) |external_run_id| {
        const external = findRunIndex(loaded.run_index, external_run_id) orelse {
            return error.ExternalMutationRunNotFound;
        };
        if (std.mem.eql(u8, external.run_id, state.run_id) or
            external.phase != .closed or
            !external.mutation_allowed or
            !std.mem.eql(u8, external.artifact_digest, current_artifact) or
            !try equalCanonicalStringSets(
                allocator,
                stringSlice(external.allowed_paths),
                stringSlice(state.allowed_paths),
            ))
        {
            return error.ExternalMutationRunMismatch;
        }
    }

    var changed_paths: std.ArrayList([]const u8) = .empty;
    defer changed_paths.deinit(allocator);
    const scope_paths = switch (state.phase) {
        .ready => stringSlice(state.allowed_paths),
        .prepared, .effect_recorded => stringSlice(
            (state.pending orelse return error.PendingOperationMissing).paths,
        ),
        .closed, .superseded => unreachable,
    };
    const baseline_unscoped = switch (state.phase) {
        .ready => state.stable_unscoped_digest orelse return error.StableSnapshotMissing,
        .prepared, .effect_recorded => state.pending.?.unscoped_before,
        .closed, .superseded => unreachable,
    };
    const baseline_paths = switch (state.phase) {
        .ready => state.stable_path_states orelse return error.StableSnapshotMissing,
        .prepared => state.pending.?.path_states_before,
        .effect_recorded => state.pending.?.path_states_before,
        .closed, .superseded => unreachable,
    };
    try validateStateEvidencePhysicalScope(allocator, repo, state, scope_paths);
    const current_unscoped = try unscopedDigestAlloc(
        allocator,
        repo,
        store_path,
        scope_paths,
        stringSlice(state.allowed_paths),
    );
    defer allocator.free(current_unscoped);
    if (!std.mem.eql(u8, baseline_unscoped, current_unscoped)) return error.OutOfScopeMutation;
    const current_paths = try snapshotPathStatesAlloc(allocator, repo, store_path, scope_paths);
    defer freePathStates(allocator, current_paths);
    try appendChangedPaths(allocator, &changed_paths, baseline_paths, current_paths);
    if (changed_paths.items.len == 0) return error.SupersedeRequiresArtifactChange;
    const baseline_path_wires = try pathStateWiresAlloc(allocator, baseline_paths);
    defer allocator.free(baseline_path_wires);
    const current_path_wires = try pathStateWiresAlloc(allocator, current_paths);
    defer allocator.free(current_path_wires);

    const obligation_inputs = try obligationInputsAlloc(allocator, state.obligations);
    defer allocator.free(obligation_inputs);
    const recovery_admission = GenerationAdmissionInput{
        .schema = "actuation-generation-admission/v1",
        .kind = "recovery",
        .predecessor_run_id = state.run_id,
        .basis = input.basis,
        .recovery = input.recovery,
    };
    const successor_input = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = "reserved-successor",
        .goal_id = state.goal_id,
        .goal_contract_digest = state.goal_contract_digest,
        .resolution_digest = state.resolution_digest,
        .source_ref = state.source_ref,
        .execution_authority_ref = state.execution_authority_ref,
        .mutation_allowed = state.mutation_allowed,
        .completion = state.completion.name(),
        .allowed_paths = stringSlice(state.allowed_paths),
        .obligations = obligation_inputs,
        .generation_admission = recovery_admission,
    };
    const reserved_successor_generation_id = try generationIdAlloc(
        allocator,
        successor_input,
        .recovery,
        state.completion,
        current_artifact,
        generation_id,
        if (state.review_work_node) |*node| node.input() else null,
    );
    defer allocator.free(reserved_successor_generation_id);

    const body = RunSupersededBody{
        .generation_id = generation_id,
        .artifact_before = supersession_artifact_before,
        .artifact_after = current_artifact,
        .scope_paths = scope_paths,
        .unscoped_before = baseline_unscoped,
        .unscoped_after = current_unscoped,
        .path_states_before = baseline_path_wires,
        .path_states_after = current_path_wires,
        .changed_paths = changed_paths.items,
        .recovery_basis = input.basis,
        .recovery = .{
            .authority_ref = input.recovery.authority_ref,
            .authority_digest = input.recovery.authority_digest,
            .reason = recovery_reason.name(),
        },
        .external_run_id = input.external_run_id,
        .reserved_successor_generation_id = reserved_successor_generation_id,
    };
    const body_json = try encodeBodyAlloc(allocator, body);
    defer allocator.free(body_json);
    const event_digest = try appendEventAlloc(
        allocator,
        &exclusive,
        loaded,
        run_id,
        "run_superseded",
        body_json,
    );
    errdefer allocator.free(event_digest);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .goal_id = try allocator.dupe(u8, state.goal_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, current_artifact),
        .generation_id = try allocator.dupe(u8, generation_id),
        .generation_kind = state.admission.?.kind,
        .predecessor_generation_id = if (state.predecessor_generation_id) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .reserved_successor_generation_id = try allocator.dupe(
            u8,
            reserved_successor_generation_id,
        ),
    };
}

fn cmdClose(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
) !TransitionResult {
    var persistence = durable_store.PersistentEventStore.init(store_path);
    var exclusive = try acquireActuationExclusive(allocator, persistence.eventStore());
    defer exclusive.release();
    var loaded = try loadLedgerExclusive(allocator, &exclusive, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(allocator, state, repo, store_path);
    try validateWritableGeneration(state);
    if (state.phase != .ready or state.pending != null) return error.InvalidPhase;
    if (outstandingObligationCount(state) != 0) return error.ObligationsOutstanding;
    const current_artifact = try repositoryArtifactDigestAlloc(
        allocator,
        repo,
        store_path,
        stringSlice(state.allowed_paths),
    );
    defer allocator.free(current_artifact);
    if (!std.mem.eql(u8, current_artifact, state.artifact_digest)) return error.ArtifactStale;

    var discharged: std.ArrayList([]const u8) = .empty;
    defer discharged.deinit(allocator);
    for (state.obligations) |obligation| try discharged.append(allocator, obligation.id);
    const body = RunClosedBody{
        .goal_contract_digest = state.goal_contract_digest,
        .artifact_digest = current_artifact,
        .discharged_obligations = discharged.items,
    };
    const body_json = try encodeBodyAlloc(allocator, body);
    defer allocator.free(body_json);
    const event_digest = try appendEventAlloc(
        allocator,
        &exclusive,
        loaded,
        run_id,
        "run_closed",
        body_json,
    );
    errdefer allocator.free(event_digest);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .goal_id = try allocator.dupe(u8, state.goal_id),
        .event_digest = event_digest,
        .artifact_digest = try allocator.dupe(u8, current_artifact),
        .generation_id = if (state.generation_id) |value| try allocator.dupe(u8, value) else null,
        .generation_kind = if (state.admission) |admission| admission.kind else .legacy_v1,
        .predecessor_generation_id = if (state.predecessor_generation_id) |value|
            try allocator.dupe(u8, value)
        else
            null,
    };
}

fn cmdState(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
) !void {
    var loaded = try loadLedger(allocator, store_path, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(allocator, state, repo, store_path);
    try printState(allocator, state, loaded.event_count);
}

fn cmdDecide(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    run_id: []const u8,
) !void {
    var loaded = try loadLedger(allocator, store_path, run_id);
    defer loaded.deinit(allocator);
    const state = if (loaded.state) |*value| value else return error.RunNotFound;
    try validateContext(allocator, state, repo, store_path);

    const current_artifact = try repositoryArtifactDigestAlloc(
        allocator,
        repo,
        store_path,
        stringSlice(state.allowed_paths),
    );
    defer allocator.free(current_artifact);
    if (!std.mem.eql(u8, current_artifact, state.artifact_digest)) return error.ArtifactStale;

    const state_digest = try stateDigestAlloc(allocator, state);
    defer allocator.free(state_digest);
    const decision = projectDecision(state);
    const decision_id = try decisionDigestAlloc(
        allocator,
        state_digest,
        decision.verdict,
        decision.goal_outcome,
        decision.implementation_outcome,
        decision.next_owner,
        decision.next_transition,
    );
    defer allocator.free(decision_id);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"closure_decision\":{\"version\":\"closure-decision/v1\",\"decision_id\":");
    try std.json.Stringify.value(decision_id, .{}, &out.writer);
    try out.writer.writeAll(",\"run_id\":");
    try std.json.Stringify.value(state.run_id, .{}, &out.writer);
    try out.writer.writeAll(",\"evaluated_artifact\":{\"repo\":");
    try std.json.Stringify.value(state.repo, .{}, &out.writer);
    try out.writer.writeAll(",\"state_fingerprint\":");
    try std.json.Stringify.value(state.artifact_digest, .{}, &out.writer);
    try out.writer.writeAll("},\"run_digest\":");
    try std.json.Stringify.value(state_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"resolution_digest\":");
    if (state.resolution_digest) |digest| {
        try std.json.Stringify.value(digest, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"verdict\":");
    try std.json.Stringify.value(decision.verdict, .{}, &out.writer);
    try out.writer.writeAll(",\"outcomes\":{\"goal_outcome\":");
    try std.json.Stringify.value(decision.goal_outcome, .{}, &out.writer);
    try out.writer.writeAll(",\"implementation_outcome\":");
    try std.json.Stringify.value(decision.implementation_outcome, .{}, &out.writer);
    try out.writer.writeAll(",\"next_owner\":");
    try std.json.Stringify.value(decision.next_owner, .{}, &out.writer);
    try out.writer.writeAll("},\"evidence_basis\":");
    try writeDecisionBasis(&out.writer, state, .evidence);
    try out.writer.writeAll(",\"review_basis\":");
    try writeDecisionBasis(&out.writer, state, .review);
    try out.writer.writeAll(",\"ship_basis\":");
    try writeDecisionBasis(&out.writer, state, .ship);
    try out.writer.writeAll(",\"implementation_checkpoint\":null,\"reasons\":[");
    if (!decision.terminal) {
        const reason = try std.fmt.allocPrint(allocator, "next-transition:{s}", .{decision.next_transition});
        defer allocator.free(reason);
        try std.json.Stringify.value(reason, .{}, &out.writer);
    }
    try out.writer.writeAll("]}}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn writeDecisionBasis(writer: *std.Io.Writer, state: *const RunState, basis: DecisionBasis) !void {
    try writer.writeByte('[');
    var index: usize = 0;
    for (state.obligations) |obligation| {
        const step_id = obligation.discharged_by orelse continue;
        const included = switch (basis) {
            .evidence => obligation.kind == .implementation or obligation.kind == .acceptance,
            .review => obligation.kind == .review,
            .ship => obligation.kind == .ship,
        };
        if (!included) continue;
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"obligation_id\":");
        try std.json.Stringify.value(obligation.id, .{}, writer);
        try writer.writeAll(",\"step_id\":");
        try std.json.Stringify.value(step_id, .{}, writer);
        try writer.writeByte('}');
        index += 1;
    }
    try writer.writeByte(']');
}

fn projectDecision(state: *const RunState) DecisionProjection {
    const closed = state.phase == .closed;
    const superseded = state.phase == .superseded;
    const terminal = closed or superseded;
    const verdict = if (superseded)
        "superseded"
    else if (closed)
        state.completion.name()
    else
        "continue";
    const goal_outcome = if (!closed or state.completion == .ready_to_ship)
        "continue"
    else
        "complete";
    const implementation_outcome = if (superseded)
        "superseded"
    else if (closed)
        "complete"
    else
        "incomplete";
    return .{
        .terminal = terminal,
        .verdict = verdict,
        .goal_outcome = goal_outcome,
        .implementation_outcome = implementation_outcome,
        .next_owner = if (superseded)
            "goal-actuating"
        else if (!terminal)
            "goal-actuating"
        else if (state.completion == .ready_to_ship)
            "ship"
        else
            "none",
        .next_transition = nextTransition(state),
    };
}

fn cmdDoctor(allocator: std.mem.Allocator, store_path: []const u8) !void {
    var loaded = try loadLedger(allocator, store_path, null);
    defer loaded.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"actuation-doctor/v1\",\"ok\":true,\"events\":");
    try out.writer.print("{d}", .{loaded.event_count});
    try out.writer.writeAll(",\"last_event_digest\":");
    try std.json.Stringify.value(loaded.last_digest, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn stateDigestAlloc(allocator: std.mem.Allocator, state: *const RunState) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "schema", "actuation-kernel-state/v2");
    hashTagged(&hasher, "run", state.run_id);
    hashTagged(&hasher, "generation", state.generation_id orelse "legacy-v1");
    hashTagged(&hasher, "predecessor-generation", state.predecessor_generation_id orelse "");
    if (state.admission) |admission| {
        hashTagged(&hasher, "generation-kind", admission.kind.name());
        hashTagged(&hasher, "predecessor-run", admission.predecessor_run_id orelse "");
        hashTagged(&hasher, "basis-ref", admission.basis_ref);
        hashTagged(&hasher, "basis-digest", admission.basis_digest);
        hashTagged(&hasher, "review-policy-ref", admission.review_policy_ref orelse "");
        hashTagged(&hasher, "review-policy-digest", admission.review_policy_digest orelse "");
        hashTagged(&hasher, "review-resolution-ref", admission.review_resolution_ref orelse "");
        hashTagged(
            &hasher,
            "review-resolution-digest",
            admission.review_resolution_digest orelse "",
        );
        hashTagged(&hasher, "recovery-authority-ref", admission.recovery_authority_ref orelse "");
        hashTagged(
            &hasher,
            "recovery-authority-digest",
            admission.recovery_authority_digest orelse "",
        );
        hashTagged(
            &hasher,
            "recovery-reason",
            if (admission.recovery_reason) |reason| reason.name() else "",
        );
    } else {
        hashTagged(&hasher, "generation-kind", "legacy-v1");
    }
    if (state.review_work_node) |node| {
        hashTagged(&hasher, "review-work-node", node.node_id);
        hashTagged(&hasher, "review-work-run", node.run_id);
        hashTagged(&hasher, "review-work-owner", node.owner_boundary);
        for (node.paths) |path| hashTagged(&hasher, "review-work-path", path);
        for (node.verifier) |arg| hashTagged(&hasher, "review-work-verifier", arg);
    }
    hashTagged(&hasher, "goal", state.goal_id);
    hashTagged(&hasher, "goal-contract", state.goal_contract_digest);
    hashTagged(&hasher, "resolution", state.resolution_digest orelse "");
    hashTagged(&hasher, "source", state.source_ref);
    hashTagged(&hasher, "authority", state.execution_authority_ref);
    hashTagged(&hasher, "mutation", if (state.mutation_allowed) "true" else "false");
    hashTagged(&hasher, "completion", state.completion.name());
    hashTagged(&hasher, "repo", state.repo);
    hashTagged(&hasher, "store", state.store_path);
    hashTagged(&hasher, "artifact", state.artifact_digest);
    hashTagged(&hasher, "stable-unscoped", state.stable_unscoped_digest orelse "");
    if (state.stable_path_states) |states| for (states) |path_state| {
        hashTagged(&hasher, "stable-path", path_state.path);
        hashTagged(&hasher, "stable-path-digest", path_state.digest);
    };
    hashTagged(&hasher, "reserved-successor", state.reserved_successor_generation_id orelse "");
    hashTagged(&hasher, "phase", state.phase.name());
    for (state.allowed_paths) |path| hashTagged(&hasher, "allowed-path", path);
    for (state.obligations) |obligation| {
        hashTagged(&hasher, "obligation", obligation.id);
        hashTagged(&hasher, "obligation-kind", obligation.kind.name());
        hashTagged(&hasher, "statement", obligation.statement);
        for (obligation.verifier) |arg| hashTagged(&hasher, "verifier", arg);
        hashTagged(&hasher, "discharged-by", obligation.discharged_by orelse "");
    }
    for (state.step_ids.items) |step_id| hashTagged(&hasher, "step", step_id);
    for (state.idempotency_keys.items) |key| hashTagged(&hasher, "idempotency", key);
    if (state.pending) |pending| {
        hashTagged(&hasher, "pending-step", pending.step_id);
        hashTagged(&hasher, "pending-effect", pending.effect.name());
        hashTagged(&hasher, "pending-idempotency", pending.idempotency_key);
        hashTagged(&hasher, "pending-owner", pending.owner_boundary);
        for (pending.paths) |path| hashTagged(&hasher, "pending-path", path);
        for (pending.obligation_refs) |ref| hashTagged(&hasher, "pending-obligation", ref);
        for (pending.verifier) |arg| hashTagged(&hasher, "pending-verifier", arg);
        hashTagged(&hasher, "pending-capability", pending.capability_digest);
        hashTagged(&hasher, "pending-before", pending.artifact_before);
        hashTagged(&hasher, "pending-after", pending.artifact_after orelse "");
        hashTagged(&hasher, "pending-unscoped-before", pending.unscoped_before);
        for (pending.path_states_before) |path_state| {
            hashTagged(&hasher, "pending-path-before", path_state.path);
            hashTagged(&hasher, "pending-path-before-digest", path_state.digest);
        }
        if (pending.path_states_after) |states| for (states) |path_state| {
            hashTagged(&hasher, "pending-path-after", path_state.path);
            hashTagged(&hasher, "pending-path-after-digest", path_state.digest);
        };
    }
    return finishDigestAlloc(allocator, &hasher);
}

fn decisionDigestAlloc(
    allocator: std.mem.Allocator,
    state_digest: []const u8,
    verdict: []const u8,
    goal_outcome: []const u8,
    implementation_outcome: []const u8,
    next_owner: []const u8,
    transition: []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "schema", "closure-decision/v1");
    hashTagged(&hasher, "state", state_digest);
    hashTagged(&hasher, "verdict", verdict);
    hashTagged(&hasher, "goal", goal_outcome);
    hashTagged(&hasher, "implementation", implementation_outcome);
    hashTagged(&hasher, "owner", next_owner);
    hashTagged(&hasher, "transition", transition);
    return finishDigestAlloc(allocator, &hasher);
}

fn appendEventAlloc(
    allocator: std.mem.Allocator,
    exclusive: *const durable_store.EventStoreExclusive,
    loaded: LedgerLoad,
    run_id: []const u8,
    kind: []const u8,
    body_json: []const u8,
) ![]u8 {
    const body_digest = try digestTextAlloc(allocator, body_json);
    defer allocator.free(body_digest);
    const sequence = loaded.event_count + 1;
    const recorded_at_unix: i64 = @intCast(@divFloor(std.Io.Clock.real.now(defaultIo()).nanoseconds, std.time.ns_per_s));
    const event_digest = try eventDigestAlloc(
        allocator,
        sequence,
        loaded.last_digest,
        run_id,
        kind,
        recorded_at_unix,
        body_digest,
    );
    errdefer allocator.free(event_digest);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"actuation-event/v1\",\"sequence\":");
    try out.writer.print("{d}", .{sequence});
    try out.writer.writeAll(",\"previous_digest\":");
    try std.json.Stringify.value(loaded.last_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"run_id\":");
    try std.json.Stringify.value(run_id, .{}, &out.writer);
    try out.writer.writeAll(",\"kind\":");
    try std.json.Stringify.value(kind, .{}, &out.writer);
    try out.writer.writeAll(",\"recorded_at_unix\":");
    try out.writer.print("{d}", .{recorded_at_unix});
    try out.writer.writeAll(",\"body\":");
    try out.writer.writeAll(body_json);
    try out.writer.writeAll(",\"body_digest\":");
    try std.json.Stringify.value(body_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"event_digest\":");
    try std.json.Stringify.value(event_digest, .{}, &out.writer);
    try out.writer.writeByte('}');
    const line = try out.toOwnedSlice();
    defer allocator.free(line);
    var receipt = try exclusive.append(
        allocator,
        line,
        .{ .revision = loaded.store_revision, .exists = loaded.store_exists },
        MaxStoreBytes,
    );
    defer receipt.deinit(allocator);
    return event_digest;
}

fn loadLedger(allocator: std.mem.Allocator, store_path: []const u8, target_run_id: ?[]const u8) !LedgerLoad {
    var persistence = durable_store.PersistentEventStore.init(store_path);
    var snapshot = try persistence.eventStore().snapshot(allocator, MaxStoreBytes);
    defer snapshot.deinit(allocator);
    return loadLedgerFromSnapshot(allocator, snapshot, target_run_id);
}

fn acquireActuationExclusive(
    allocator: std.mem.Allocator,
    store: durable_store.EventStore,
) !durable_store.EventStoreExclusive {
    return store.acquireExclusive(allocator) catch |err| switch (err) {
        error.EventStoreBusy => error.PathAlreadyExists,
        else => err,
    };
}

fn loadLedgerExclusive(
    allocator: std.mem.Allocator,
    exclusive: *const durable_store.EventStoreExclusive,
    target_run_id: ?[]const u8,
) !LedgerLoad {
    var snapshot = try exclusive.snapshot(allocator, MaxStoreBytes);
    defer snapshot.deinit(allocator);
    return loadLedgerFromSnapshot(allocator, snapshot, target_run_id);
}

fn loadLedgerFromSnapshot(
    allocator: std.mem.Allocator,
    snapshot: durable_store.EventSnapshot,
    target_run_id: ?[]const u8,
) !LedgerLoad {
    var states: std.ArrayList(RunState) = .empty;
    defer {
        for (states.items) |*state| state.deinit(allocator);
        states.deinit(allocator);
    }
    var last_digest = try allocator.dupe(u8, GenesisDigest);
    errdefer allocator.free(last_digest);
    var expected_sequence: u64 = 1;
    for (snapshot.records) |record| {
        var parsed = try std.json.parseFromSlice(EventWire, allocator, record.payload, .{});
        defer parsed.deinit();
        const event = parsed.value;
        if (!std.mem.eql(u8, event.schema, "actuation-event/v1")) return error.InvalidEventSchema;
        if (event.sequence != expected_sequence) return error.EventSequenceMismatch;
        if (!std.mem.eql(u8, event.previous_digest, last_digest)) return error.PreviousDigestMismatch;
        try validateToken("run_id", event.run_id);

        const encoded_body = try encodeDynamicBodyAlloc(allocator, event.body);
        defer allocator.free(encoded_body);
        const computed_body_digest = try digestTextAlloc(allocator, encoded_body);
        defer allocator.free(computed_body_digest);
        if (!std.mem.eql(u8, event.body_digest, computed_body_digest)) return error.BodyDigestMismatch;
        const computed_event_digest = try eventDigestAlloc(
            allocator,
            event.sequence,
            event.previous_digest,
            event.run_id,
            event.kind,
            event.recorded_at_unix,
            event.body_digest,
        );
        defer allocator.free(computed_event_digest);
        if (!std.mem.eql(u8, event.event_digest, computed_event_digest)) return error.EventDigestMismatch;

        try applyEvent(allocator, &states, event.run_id, event.kind, encoded_body);
        allocator.free(last_digest);
        last_digest = try allocator.dupe(u8, event.event_digest);
        expected_sequence += 1;
    }

    const run_index = try allocator.alloc(RunIndexEntry, states.items.len);
    var indexed: usize = 0;
    errdefer {
        for (run_index[0..indexed]) |*entry| entry.deinit(allocator);
        allocator.free(run_index);
    }
    for (states.items, 0..) |*state, index| {
        run_index[index] = .{
            .run_id = try allocator.dupe(u8, state.run_id),
            .goal_id = try allocator.dupe(u8, state.goal_id),
            .goal_contract_digest = try allocator.dupe(u8, state.goal_contract_digest),
            .generation_id = if (state.generation_id) |value|
                try allocator.dupe(u8, value)
            else
                null,
            .predecessor_run_id = if (state.admission) |admission|
                if (admission.predecessor_run_id) |value|
                    try allocator.dupe(u8, value)
                else
                    null
            else
                null,
            .kind = if (state.admission) |admission| admission.kind else .legacy_v1,
            .phase = state.phase,
            .mutation_allowed = state.mutation_allowed,
            .allowed_paths = try dupeStringList(allocator, stringSlice(state.allowed_paths)),
            .review_work_node = if (state.review_work_node) |*node|
                try reviewWorkNodeStateFromInput(allocator, node.input())
            else
                null,
            .artifact_digest = try allocator.dupe(u8, state.artifact_digest),
            .reserved_successor_generation_id = if (state.reserved_successor_generation_id) |value|
                try allocator.dupe(u8, value)
            else
                null,
            .recovery_contract_digest = try recoveryContractDigestStateAlloc(allocator, state),
        };
        indexed += 1;
    }

    var result = LedgerLoad{
        .event_count = expected_sequence - 1,
        .last_digest = last_digest,
        .store_revision = try allocator.dupe(u8, snapshot.revision),
        .store_exists = snapshot.exists,
        .run_index = run_index,
    };
    errdefer allocator.free(result.store_revision);
    if (target_run_id) |wanted| {
        for (states.items, 0..) |state, index| {
            if (!std.mem.eql(u8, state.run_id, wanted)) continue;
            result.state = states.orderedRemove(index);
            break;
        }
    }
    return result;
}

fn applyEvent(
    allocator: std.mem.Allocator,
    states: *std.ArrayList(RunState),
    run_id: []const u8,
    kind: []const u8,
    body_json: []const u8,
) !void {
    const state_index = findRunState(states.items, run_id);
    if (std.mem.eql(u8, kind, "run_opened")) {
        if (state_index != null) return error.DuplicateRunId;
        var state = try stateFromOpenEvent(allocator, run_id, body_json);
        errdefer state.deinit(allocator);
        try validateReplayedLineage(allocator, states.items, &state);
        try states.append(allocator, state);
        return;
    }
    const index = state_index orelse return error.EventRunMissing;
    const state = &states.items[index];
    if (std.mem.eql(u8, kind, "operation_prepared")) {
        try applyPreparedEvent(allocator, state, body_json);
        return;
    }
    if (std.mem.eql(u8, kind, "effect_recorded")) {
        try applyEffectRecordedEvent(allocator, state, body_json);
        return;
    }
    if (std.mem.eql(u8, kind, "operation_observed")) {
        try applyObservedEvent(allocator, state, body_json);
        return;
    }
    if (std.mem.eql(u8, kind, "operation_aborted")) {
        try applyAbortedEvent(allocator, state, body_json);
        return;
    }
    if (std.mem.eql(u8, kind, "run_closed")) {
        try applyClosedEvent(allocator, state, body_json);
        return;
    }
    if (std.mem.eql(u8, kind, "run_superseded")) {
        try applySupersededEvent(allocator, state, states.items, body_json);
        return;
    }
    return error.UnknownEventKind;
}

fn stateFromOpenEvent(allocator: std.mem.Allocator, run_id: []const u8, body_json: []const u8) !RunState {
    const SchemaProbe = struct { schema: []const u8 };
    var probe = try std.json.parseFromSlice(
        SchemaProbe,
        allocator,
        body_json,
        .{ .ignore_unknown_fields = true },
    );
    defer probe.deinit();
    if (std.mem.eql(u8, probe.value.schema, "actuation-run-opened/v1")) {
        return stateFromOpenV1Event(allocator, run_id, body_json);
    }
    if (std.mem.eql(u8, probe.value.schema, "actuation-run-opened/v2")) {
        return stateFromOpenV2Event(allocator, run_id, body_json);
    }
    return error.InvalidBodySchema;
}

fn stateFromOpenV1Event(
    allocator: std.mem.Allocator,
    run_id: []const u8,
    body_json: []const u8,
) !RunState {
    var parsed = try std.json.parseFromSlice(RunOpenedBodyV1, allocator, body_json, .{});
    defer parsed.deinit();
    const body = parsed.value;
    if (!std.mem.eql(u8, body.schema, "actuation-run-opened/v1")) return error.InvalidBodySchema;
    try validateToken("run_id", run_id);
    try validateToken("goal_id", body.goal_id);
    try validateDigest(body.goal_contract_digest);
    if (body.resolution_digest) |digest| try validateDigest(digest);
    try validateNonEmpty("source_ref", body.source_ref);
    try validateNonEmpty("execution_authority_ref", body.execution_authority_ref);
    const completion = Completion.parse(body.completion) orelse return error.InvalidCompletion;
    try validateNonEmpty("repo", body.repo);
    try validateNonEmpty("store_path", body.store_path);
    try validateDigest(body.artifact_digest);
    try validateAllowedPaths(body.allowed_paths);
    try validateObligations(body.obligations);

    const obligations = try allocator.alloc(ObligationState, body.obligations.len);
    var initialized: usize = 0;
    errdefer {
        for (obligations[0..initialized]) |*obligation| obligation.deinit(allocator);
        allocator.free(obligations);
    }
    for (body.obligations, 0..) |source, index| {
        obligations[index] = .{
            .id = try allocator.dupe(u8, source.id),
            .kind = ObligationKind.parse(source.kind) orelse return error.InvalidObligationKind,
            .statement = try allocator.dupe(u8, source.statement),
            .verifier = try dupeStringList(allocator, source.verifier),
        };
        initialized += 1;
    }

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .goal_id = try allocator.dupe(u8, body.goal_id),
        .goal_contract_digest = try allocator.dupe(u8, body.goal_contract_digest),
        .resolution_digest = if (body.resolution_digest) |digest| try allocator.dupe(u8, digest) else null,
        .source_ref = try allocator.dupe(u8, body.source_ref),
        .execution_authority_ref = try allocator.dupe(u8, body.execution_authority_ref),
        .mutation_allowed = body.mutation_allowed,
        .completion = completion,
        .repo = try allocator.dupe(u8, body.repo),
        .store_path = try allocator.dupe(u8, body.store_path),
        .allowed_paths = try dupeStringList(allocator, body.allowed_paths),
        .obligations = obligations,
        .artifact_digest = try allocator.dupe(u8, body.artifact_digest),
    };
}

fn stateFromOpenV2Event(
    allocator: std.mem.Allocator,
    run_id: []const u8,
    body_json: []const u8,
) !RunState {
    var parsed = try std.json.parseFromSlice(RunOpenedBodyV2, allocator, body_json, .{});
    defer parsed.deinit();
    const body = parsed.value;
    if (!std.mem.eql(u8, body.schema, "actuation-run-opened/v2")) return error.InvalidBodySchema;
    try validateToken("run_id", run_id);
    try validateToken("goal_id", body.goal_id);
    try validateDigest(body.goal_contract_digest);
    if (body.resolution_digest) |digest| try validateDigest(digest);
    try validateNonEmpty("source_ref", body.source_ref);
    try validateNonEmpty("execution_authority_ref", body.execution_authority_ref);
    const completion = Completion.parse(body.completion) orelse return error.InvalidCompletion;
    try validateNonEmpty("repo", body.repo);
    try validateNonEmpty("store_path", body.store_path);
    try validateDigest(body.artifact_digest);
    try validateDigest(body.generation_id);
    if (body.predecessor_generation_id) |digest| try validateDigest(digest);
    try validateDigest(body.stable_unscoped_digest);
    try validateAllowedPaths(body.allowed_paths);
    try validateAllowedPathsAgainstStore(
        allocator,
        body.repo,
        body.store_path,
        body.allowed_paths,
    );
    try validateObligations(body.obligations);
    const replay_input = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = run_id,
        .goal_id = body.goal_id,
        .goal_contract_digest = body.goal_contract_digest,
        .resolution_digest = body.resolution_digest,
        .source_ref = body.source_ref,
        .execution_authority_ref = body.execution_authority_ref,
        .mutation_allowed = body.mutation_allowed,
        .completion = body.completion,
        .allowed_paths = body.allowed_paths,
        .obligations = body.obligations,
        .generation_admission = body.generation_admission,
    };
    const validated = try validateOpenInput(replay_input);
    const kind = validated.kind;
    const requires_review_work_node = kind == .review_repair or
        (kind == .implementation and
            hasCompleteReviewEvidence(body.generation_admission.review));
    const permits_review_work_node = requires_review_work_node or kind == .recovery;
    if ((requires_review_work_node and body.review_work_node == null) or
        (!permits_review_work_node and body.review_work_node != null))
    {
        return error.ReviewWorkNodeMismatch;
    }
    if (body.review_work_node) |node| {
        try validateNonEmpty("review_work_node_id", node.node_id);
        try validateNonEmpty("review_work_node_owner", node.owner_boundary);
        if (node.verifier.len == 0) return error.ReviewWorkNodeMismatch;
        for (node.verifier) |arg| try validateNonEmpty("review_work_node_verifier", arg);
        if ((kind != .recovery and !std.mem.eql(u8, node.run_id, run_id)) or
            !try equalCanonicalStringSets(allocator, node.paths, body.allowed_paths))
        {
            return error.ReviewWorkNodeMismatch;
        }
    }
    if (body.allowed_path_states.len != body.allowed_paths.len) return error.PathStateMismatch;
    for (body.allowed_path_states, 0..) |path_state, index| {
        if (!std.mem.eql(u8, path_state.path, body.allowed_paths[index])) {
            return error.PathStateMismatch;
        }
        try validateDigest(path_state.digest);
    }

    const expected_generation_id = try generationIdFromBodyAlloc(allocator, body, kind, completion);
    defer allocator.free(expected_generation_id);
    if (!std.mem.eql(u8, expected_generation_id, body.generation_id)) {
        return error.GenerationIdMismatch;
    }

    const obligations = try obligationStatesAlloc(allocator, body.obligations);
    errdefer freeObligationStates(allocator, obligations);
    const stable_path_states = try pathStatesFromWiresAlloc(allocator, body.allowed_path_states);
    errdefer freePathStates(allocator, stable_path_states);
    var admission = try admissionStateFromInput(allocator, body.generation_admission, kind);
    errdefer admission.deinit(allocator);
    var review_work_node = if (body.review_work_node) |node|
        try reviewWorkNodeStateFromInput(allocator, node)
    else
        null;
    errdefer if (review_work_node) |*value| value.deinit(allocator);

    return .{
        .run_id = try allocator.dupe(u8, run_id),
        .generation_id = try allocator.dupe(u8, body.generation_id),
        .predecessor_generation_id = if (body.predecessor_generation_id) |digest|
            try allocator.dupe(u8, digest)
        else
            null,
        .admission = admission,
        .review_work_node = review_work_node,
        .goal_id = try allocator.dupe(u8, body.goal_id),
        .goal_contract_digest = try allocator.dupe(u8, body.goal_contract_digest),
        .resolution_digest = if (body.resolution_digest) |digest|
            try allocator.dupe(u8, digest)
        else
            null,
        .source_ref = try allocator.dupe(u8, body.source_ref),
        .execution_authority_ref = try allocator.dupe(u8, body.execution_authority_ref),
        .mutation_allowed = body.mutation_allowed,
        .completion = completion,
        .repo = try allocator.dupe(u8, body.repo),
        .store_path = try allocator.dupe(u8, body.store_path),
        .allowed_paths = try dupeStringList(allocator, body.allowed_paths),
        .obligations = obligations,
        .artifact_digest = try allocator.dupe(u8, body.artifact_digest),
        .stable_unscoped_digest = try allocator.dupe(u8, body.stable_unscoped_digest),
        .stable_path_states = stable_path_states,
    };
}

fn applyPreparedEvent(allocator: std.mem.Allocator, state: *RunState, body_json: []const u8) !void {
    if (state.phase != .ready or state.pending != null) return error.InvalidEventTransition;
    var parsed = try std.json.parseFromSlice(OperationPreparedBody, allocator, body_json, .{});
    defer parsed.deinit();
    const body = parsed.value;
    if (!std.mem.eql(u8, body.schema, "actuation-operation-prepared/v1")) {
        return error.InvalidBodySchema;
    }
    try validateToken("step_id", body.step_id);
    if (containsString(state.step_ids.items, body.step_id)) return error.DuplicateStepId;
    try validateToken("idempotency_key", body.idempotency_key);
    if (containsString(state.idempotency_keys.items, body.idempotency_key)) {
        return error.DuplicateIdempotencyKey;
    }
    const effect = Effect.parse(body.effect) orelse return error.InvalidEffect;
    if (effect == .edit and !state.mutation_allowed) return error.MutationForbidden;
    try validateNonEmpty("owner_boundary", body.owner_boundary);
    try validateOperationPaths(state.allowed_paths, body.paths);
    const expected_verifier = try commonVerifierForRefs(state, body.obligation_refs);
    if (!equalStringLists(stringSlice(expected_verifier), body.verifier)) {
        return error.VerifierSubstitution;
    }
    try validateReviewWorkOperation(
        allocator,
        state,
        effect,
        body.owner_boundary,
        body.paths,
        body.verifier,
    );
    try validateDigest(body.capability_digest);
    if (!std.mem.eql(u8, state.artifact_digest, body.artifact_before)) {
        return error.EventArtifactMismatch;
    }
    try validateDigest(body.unscoped_before);
    if (body.path_states_before.len != body.paths.len) return error.PathStateMismatch;
    for (body.path_states_before, 0..) |path_state, index| {
        if (!std.mem.eql(u8, path_state.path, body.paths[index])) return error.PathStateMismatch;
        try validateDigest(path_state.digest);
    }

    const owned_path_states = try allocator.alloc(PathState, body.path_states_before.len);
    var initialized: usize = 0;
    errdefer {
        for (owned_path_states[0..initialized]) |*path_state| path_state.deinit(allocator);
        allocator.free(owned_path_states);
    }
    for (body.path_states_before, 0..) |path_state, index| {
        owned_path_states[index] = .{
            .path = try allocator.dupe(u8, path_state.path),
            .digest = try allocator.dupe(u8, path_state.digest),
        };
        initialized += 1;
    }

    state.pending = .{
        .step_id = try allocator.dupe(u8, body.step_id),
        .effect = effect,
        .idempotency_key = try allocator.dupe(u8, body.idempotency_key),
        .owner_boundary = try allocator.dupe(u8, body.owner_boundary),
        .paths = try dupeStringList(allocator, body.paths),
        .obligation_refs = try dupeStringList(allocator, body.obligation_refs),
        .verifier = try dupeStringList(allocator, body.verifier),
        .capability_digest = try allocator.dupe(u8, body.capability_digest),
        .artifact_before = try allocator.dupe(u8, body.artifact_before),
        .unscoped_before = try allocator.dupe(u8, body.unscoped_before),
        .path_states_before = owned_path_states,
    };
    try state.step_ids.append(allocator, try allocator.dupe(u8, body.step_id));
    try state.idempotency_keys.append(allocator, try allocator.dupe(u8, body.idempotency_key));
    state.phase = .prepared;
}

fn applyEffectRecordedEvent(allocator: std.mem.Allocator, state: *RunState, body_json: []const u8) !void {
    if (state.phase != .prepared) return error.InvalidEventTransition;
    const pending = if (state.pending) |*value| value else return error.PendingOperationMissing;
    if (pending.effect != .edit) return error.InvalidEventTransition;
    var parsed = try std.json.parseFromSlice(EffectRecordedBody, allocator, body_json, .{});
    defer parsed.deinit();
    const body = parsed.value;
    if (!std.mem.eql(u8, body.schema, "actuation-effect-recorded/v1")) return error.InvalidBodySchema;
    if (!std.mem.eql(u8, pending.step_id, body.step_id) or
        !std.mem.eql(u8, body.effect, "edit") or
        !std.mem.eql(u8, pending.idempotency_key, body.idempotency_key) or
        !std.mem.eql(u8, pending.capability_digest, body.capability_digest) or
        !std.mem.eql(u8, pending.artifact_before, body.artifact_before) or
        !std.mem.eql(u8, pending.unscoped_before, body.unscoped_before) or
        !std.mem.eql(u8, body.unscoped_before, body.unscoped_after) or
        !equalStringLists(stringSlice(pending.paths), body.changed_paths))
    {
        return error.EffectRecordMismatch;
    }
    if (std.mem.eql(u8, body.artifact_before, body.artifact_after)) return error.EditDidNotChangeArtifact;
    try validateDigest(body.artifact_after);
    if (body.path_states_after.len != pending.paths.len) return error.PathStateMismatch;
    for (body.path_states_after, 0..) |path_state, index| {
        if (!std.mem.eql(u8, path_state.path, pending.paths[index])) return error.PathStateMismatch;
        if (std.mem.eql(u8, path_state.digest, pending.path_states_before[index].digest)) return error.DeclaredPathUnchanged;
        try validateDigest(path_state.digest);
    }
    const owned_path_states_after = try pathStatesFromWiresAlloc(allocator, body.path_states_after);
    errdefer freePathStates(allocator, owned_path_states_after);
    const pending_artifact_after = try allocator.dupe(u8, body.artifact_after);
    errdefer allocator.free(pending_artifact_after);
    const state_artifact_after = try allocator.dupe(u8, body.artifact_after);
    errdefer allocator.free(state_artifact_after);
    pending.artifact_after = pending_artifact_after;
    pending.path_states_after = owned_path_states_after;
    allocator.free(state.artifact_digest);
    state.artifact_digest = state_artifact_after;
    state.phase = .effect_recorded;
}

fn applyObservedEvent(allocator: std.mem.Allocator, state: *RunState, body_json: []const u8) !void {
    if (state.phase != .prepared and state.phase != .effect_recorded) return error.InvalidEventTransition;
    const pending = if (state.pending) |*value| value else return error.PendingOperationMissing;
    var parsed = try std.json.parseFromSlice(OperationObservedBody, allocator, body_json, .{});
    defer parsed.deinit();
    const body = parsed.value;
    if (!std.mem.eql(u8, body.schema, "actuation-operation-observed/v1")) return error.InvalidBodySchema;
    const expected_before = pending.artifact_after orelse pending.artifact_before;
    if (!std.mem.eql(u8, pending.step_id, body.step_id) or
        !std.mem.eql(u8, pending.effect.name(), body.effect) or
        !std.mem.eql(u8, pending.idempotency_key, body.idempotency_key) or
        !std.mem.eql(u8, pending.capability_digest, body.capability_digest) or
        !equalStringLists(stringSlice(pending.verifier), body.verifier) or
        !equalStringLists(stringSlice(pending.obligation_refs), body.obligation_refs) or
        !std.mem.eql(u8, expected_before, body.artifact_before))
    {
        return error.ObservationMismatch;
    }
    const passed = std.mem.eql(u8, body.outcome, "passed");
    const failed = std.mem.eql(u8, body.outcome, "failed");
    if (!passed and !failed) return error.InvalidObservationOutcome;
    if (passed and (body.exit_code != 0 or !std.mem.eql(u8, body.artifact_before, body.artifact_after))) {
        return error.InvalidPassingObservation;
    }
    try validateDigest(body.stdout_digest);
    try validateDigest(body.stderr_digest);
    try validateDigest(body.artifact_after);
    if (passed) {
        for (pending.obligation_refs) |ref| {
            const obligation = findObligation(state, ref) orelse return error.UnknownObligation;
            if (obligation.discharged_by != null) return error.ObligationAlreadyDischarged;
            obligation.discharged_by = try allocator.dupe(u8, pending.step_id);
        }
    }
    if (state.admission != null) {
        const stable_unscoped =
            body.stable_unscoped_after orelse return error.StableSnapshotMissing;
        try validateDigest(stable_unscoped);
        if (body.allowed_path_states_after.len != state.allowed_paths.len) {
            return error.PathStateMismatch;
        }
        for (body.allowed_path_states_after, 0..) |path_state, index| {
            if (!std.mem.eql(u8, path_state.path, state.allowed_paths[index])) {
                return error.PathStateMismatch;
            }
            try validateDigest(path_state.digest);
        }
        const new_stable_paths = try pathStatesFromWiresAlloc(
            allocator,
            body.allowed_path_states_after,
        );
        errdefer freePathStates(allocator, new_stable_paths);
        if (state.stable_unscoped_digest) |value| allocator.free(value);
        state.stable_unscoped_digest = try allocator.dupe(u8, stable_unscoped);
        if (state.stable_path_states) |states| freePathStates(allocator, states);
        state.stable_path_states = new_stable_paths;
    }
    allocator.free(state.artifact_digest);
    state.artifact_digest = try allocator.dupe(u8, body.artifact_after);
    pending.deinit(allocator);
    state.pending = null;
    state.phase = .ready;
}

fn applyAbortedEvent(allocator: std.mem.Allocator, state: *RunState, body_json: []const u8) !void {
    if (state.phase != .prepared) return error.InvalidEventTransition;
    const pending = if (state.pending) |*value| value else return error.PendingOperationMissing;
    var parsed = try std.json.parseFromSlice(OperationAbortedBody, allocator, body_json, .{});
    defer parsed.deinit();
    const body = parsed.value;
    if (!std.mem.eql(u8, body.schema, "actuation-operation-aborted/v1")) {
        return error.InvalidBodySchema;
    }
    if (!std.mem.eql(u8, pending.step_id, body.step_id) or
        !std.mem.eql(u8, pending.idempotency_key, body.idempotency_key) or
        !std.mem.eql(u8, pending.capability_digest, body.capability_digest) or
        !std.mem.eql(u8, pending.artifact_before, body.artifact_digest) or
        !std.mem.eql(u8, pending.unscoped_before, body.unscoped_digest))
    {
        return error.AbortEventMismatch;
    }
    if (body.path_states.len != pending.path_states_before.len) return error.PathStateMismatch;
    for (body.path_states, 0..) |path_state, index| {
        if (!std.mem.eql(u8, path_state.path, pending.path_states_before[index].path) or
            !std.mem.eql(u8, path_state.digest, pending.path_states_before[index].digest))
        {
            return error.AbortEventMismatch;
        }
    }
    pending.deinit(allocator);
    state.pending = null;
    state.phase = .ready;
}

fn applySupersededEvent(
    allocator: std.mem.Allocator,
    state: *RunState,
    all_states: []const RunState,
    body_json: []const u8,
) !void {
    if (state.phase != .ready and
        state.phase != .prepared and
        state.phase != .effect_recorded)
    {
        return error.InvalidEventTransition;
    }
    const generation_id = state.generation_id orelse return error.LegacyRunRecoveryUnsupported;
    var parsed = try std.json.parseFromSlice(RunSupersededBody, allocator, body_json, .{});
    defer parsed.deinit();
    const body = parsed.value;
    if (!std.mem.eql(u8, body.schema, "actuation-run-superseded/v1")) {
        return error.InvalidBodySchema;
    }
    const recovery_reason = RecoveryReason.parse(body.recovery.reason orelse {
        return error.InvalidRecoveryReason;
    }) orelse return error.InvalidRecoveryReason;
    switch (state.phase) {
        .ready => {
            if (recovery_reason != .artifact_stale and
                recovery_reason != .explicit_user_restart)
            {
                return error.InvalidRecoveryReasonForPhase;
            }
            const external_run_id = body.external_run_id orelse {
                return error.ExternalMutationRunRequired;
            };
            const external_index = findRunState(all_states, external_run_id) orelse {
                return error.ExternalMutationRunNotFound;
            };
            const external = &all_states[external_index];
            if (std.mem.eql(u8, external.run_id, state.run_id) or
                external.phase != .closed or
                !external.mutation_allowed or
                !std.mem.eql(u8, external.artifact_digest, body.artifact_after) or
                !try equalCanonicalStringSets(
                    allocator,
                    stringSlice(external.allowed_paths),
                    stringSlice(state.allowed_paths),
                ))
            {
                return error.ExternalMutationRunMismatch;
            }
        },
        .prepared => {
            if (body.external_run_id != null) return error.UnexpectedExternalMutationRun;
            const pending = state.pending orelse return error.PendingOperationMissing;
            if (!state.mutation_allowed or pending.effect != .edit) {
                return error.PreparedSupersedeRequiresEdit;
            }
            if (recovery_reason != .capability_lost_after_change and
                recovery_reason != .explicit_user_restart)
            {
                return error.InvalidRecoveryReasonForPhase;
            }
        },
        .effect_recorded => {
            if (body.external_run_id != null) return error.UnexpectedExternalMutationRun;
            if (recovery_reason != .artifact_stale and
                recovery_reason != .explicit_user_restart)
            {
                return error.InvalidRecoveryReasonForPhase;
            }
            const recorded = (state.pending orelse return error.PendingOperationMissing)
                .artifact_after orelse return error.StableSnapshotMissing;
            if (!std.mem.eql(u8, recorded, body.artifact_after)) {
                return error.UnpreparedMutationAfterRecord;
            }
        },
        .closed, .superseded => unreachable,
    }
    const expected_artifact_before = if (state.phase == .effect_recorded)
        (state.pending orelse return error.PendingOperationMissing).artifact_before
    else
        state.artifact_digest;
    if (!std.mem.eql(u8, body.generation_id, generation_id) or
        !std.mem.eql(u8, body.artifact_before, expected_artifact_before) or
        std.mem.eql(u8, body.artifact_before, body.artifact_after) or
        !std.mem.eql(u8, body.unscoped_before, body.unscoped_after))
    {
        return error.SupersessionMismatch;
    }
    try validateDigest(body.artifact_after);
    try validateDigest(body.unscoped_before);
    try validateDigest(body.reserved_successor_generation_id);
    const expected_scope_paths = switch (state.phase) {
        .ready => stringSlice(state.allowed_paths),
        .prepared, .effect_recorded => stringSlice(state.pending.?.paths),
        .closed, .superseded => unreachable,
    };
    const expected_before_paths = switch (state.phase) {
        .ready => state.stable_path_states orelse return error.StableSnapshotMissing,
        .prepared => state.pending.?.path_states_before,
        .effect_recorded => state.pending.?.path_states_before,
        .closed, .superseded => unreachable,
    };
    const expected_unscoped = switch (state.phase) {
        .ready => state.stable_unscoped_digest orelse return error.StableSnapshotMissing,
        .prepared, .effect_recorded => state.pending.?.unscoped_before,
        .closed, .superseded => unreachable,
    };
    if (!equalStringLists(expected_scope_paths, body.scope_paths) or
        !std.mem.eql(u8, expected_unscoped, body.unscoped_before) or
        body.path_states_before.len != expected_before_paths.len or
        body.path_states_after.len != expected_before_paths.len)
    {
        return error.SupersessionMismatch;
    }
    var changed_count: usize = 0;
    for (expected_before_paths, 0..) |before, index| {
        const before_wire = body.path_states_before[index];
        const after_wire = body.path_states_after[index];
        if (!std.mem.eql(u8, before.path, before_wire.path) or
            !std.mem.eql(u8, before.digest, before_wire.digest) or
            !std.mem.eql(u8, before.path, after_wire.path))
        {
            return error.SupersessionMismatch;
        }
        try validateDigest(after_wire.digest);
        if (!std.mem.eql(u8, before.digest, after_wire.digest)) {
            if (changed_count >= body.changed_paths.len or
                !std.mem.eql(u8, before.path, body.changed_paths[changed_count]))
            {
                return error.SupersessionMismatch;
            }
            changed_count += 1;
        }
    }
    if (changed_count == 0 or
        changed_count != body.changed_paths.len)
    {
        return error.SupersessionMismatch;
    }
    try validateGenerationEvidenceFields(body.recovery_basis, .{}, body.recovery, .recovery);
    try validateEvidenceOutsideMutationScope(
        body.recovery_basis.ref,
        stringSlice(state.allowed_paths),
    );
    try validateEvidenceOutsideMutationScope(
        body.recovery.authority_ref.?,
        stringSlice(state.allowed_paths),
    );

    const obligation_inputs = try obligationInputsAlloc(allocator, state.obligations);
    defer allocator.free(obligation_inputs);
    const recovery_admission = GenerationAdmissionInput{
        .schema = "actuation-generation-admission/v1",
        .kind = "recovery",
        .predecessor_run_id = state.run_id,
        .basis = body.recovery_basis,
        .recovery = body.recovery,
    };
    const successor_input = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = "reserved-successor",
        .goal_id = state.goal_id,
        .goal_contract_digest = state.goal_contract_digest,
        .resolution_digest = state.resolution_digest,
        .source_ref = state.source_ref,
        .execution_authority_ref = state.execution_authority_ref,
        .mutation_allowed = state.mutation_allowed,
        .completion = state.completion.name(),
        .allowed_paths = stringSlice(state.allowed_paths),
        .obligations = obligation_inputs,
        .generation_admission = recovery_admission,
    };
    const expected_reserved = try generationIdAlloc(
        allocator,
        successor_input,
        .recovery,
        state.completion,
        body.artifact_after,
        generation_id,
        if (state.review_work_node) |*node| node.input() else null,
    );
    defer allocator.free(expected_reserved);
    if (!std.mem.eql(u8, expected_reserved, body.reserved_successor_generation_id)) {
        return error.GenerationIdMismatch;
    }

    if (state.pending) |*pending| pending.deinit(allocator);
    state.pending = null;
    allocator.free(state.artifact_digest);
    state.artifact_digest = try allocator.dupe(u8, body.artifact_after);
    state.reserved_successor_generation_id = try allocator.dupe(
        u8,
        body.reserved_successor_generation_id,
    );
    state.phase = .superseded;
}

fn applyClosedEvent(allocator: std.mem.Allocator, state: *RunState, body_json: []const u8) !void {
    if (state.phase != .ready or state.pending != null) return error.InvalidEventTransition;
    if (outstandingObligationCount(state) != 0) return error.ObligationsOutstanding;
    var parsed = try std.json.parseFromSlice(RunClosedBody, allocator, body_json, .{});
    defer parsed.deinit();
    const body = parsed.value;
    if (!std.mem.eql(u8, body.schema, "actuation-run-closed/v1")) return error.InvalidBodySchema;
    if (!std.mem.eql(u8, body.goal_contract_digest, state.goal_contract_digest) or
        !std.mem.eql(u8, body.artifact_digest, state.artifact_digest) or
        body.discharged_obligations.len != state.obligations.len)
    {
        return error.ClosureMismatch;
    }
    for (state.obligations, 0..) |obligation, index| {
        if (!std.mem.eql(u8, obligation.id, body.discharged_obligations[index])) {
            return error.ClosureMismatch;
        }
    }
    state.phase = .closed;
}

fn findRunState(states: []const RunState, run_id: []const u8) ?usize {
    for (states, 0..) |state, index| {
        if (std.mem.eql(u8, state.run_id, run_id)) return index;
    }
    return null;
}

const ValidatedOpen = struct {
    completion: Completion,
    kind: GenerationKind,
};

fn validateOpenInput(input: OpenInput) !ValidatedOpen {
    if (!std.mem.eql(u8, input.schema, "actuation-open/v2")) return error.InvalidInputSchema;
    try validateToken("run_id", input.run_id);
    try validateToken("goal_id", input.goal_id);
    try validateDigest(input.goal_contract_digest);
    if (input.resolution_digest) |digest| try validateDigest(digest);
    try validateNonEmpty("source_ref", input.source_ref);
    try validateNonEmpty("execution_authority_ref", input.execution_authority_ref);
    const completion = Completion.parse(input.completion) orelse return error.InvalidCompletion;
    try validateAllowedPaths(input.allowed_paths);
    try validateObligations(input.obligations);
    const kind = try validateGenerationAdmission(input.generation_admission);
    try validateAdmissionEvidenceScope(input.generation_admission, input.allowed_paths, kind);
    switch (kind) {
        .legacy_v1 => unreachable,
        .implementation => {
            if (!input.mutation_allowed) return error.ImplementationRequiresMutationAuthority;
            if (hasCompleteReviewEvidence(input.generation_admission.review)) {
                try requireMatchingResolutionDigest(input);
            } else if (input.resolution_digest != null) {
                return error.UnexpectedResolutionDigest;
            }
        },
        .review_repair => {
            if (!input.mutation_allowed) return error.ReviewRepairRequiresMutationAuthority;
            try requireMatchingResolutionDigest(input);
        },
        .terminal_proof => {
            if (input.mutation_allowed) return error.TerminalProofForbidsMutation;
            if (completion != .complete) return error.TerminalProofRequiresCompletion;
            try requireMatchingResolutionDigest(input);
        },
        .recovery => {},
    }
    return .{ .completion = completion, .kind = kind };
}

fn requireMatchingResolutionDigest(input: OpenInput) !void {
    const admission_digest = input.generation_admission.review.resolution_digest orelse {
        return error.ResolutionDigestMismatch;
    };
    if (input.resolution_digest == null or
        !std.mem.eql(u8, input.resolution_digest.?, admission_digest))
    {
        return error.ResolutionDigestMismatch;
    }
}

fn validateGenerationAdmission(input: GenerationAdmissionInput) !GenerationKind {
    if (!std.mem.eql(u8, input.schema, "actuation-generation-admission/v1")) {
        return error.InvalidGenerationAdmissionSchema;
    }
    const kind = GenerationKind.parse(input.kind) orelse return error.InvalidGenerationKind;
    if (input.predecessor_run_id) |run_id| try validateToken("predecessor_run_id", run_id);
    try validateGenerationEvidenceFields(input.basis, input.review, input.recovery, kind);
    if (kind == .implementation) {
        if (input.predecessor_run_id != null) return error.ImplementationMustBeRoot;
    } else if (input.predecessor_run_id == null) {
        return error.PredecessorRequired;
    }
    return kind;
}

fn validateGenerationEvidenceFields(
    basis: EvidenceInput,
    review: ReviewAdmissionInput,
    recovery: RecoveryAdmissionInput,
    kind: GenerationKind,
) !void {
    try validateRepoPath(basis.ref);
    try validateDigest(basis.digest);
    const review_all = review.policy_ref != null and review.policy_digest != null and
        review.resolution_ref != null and review.resolution_digest != null;
    const review_none = review.policy_ref == null and review.policy_digest == null and
        review.resolution_ref == null and review.resolution_digest == null;
    const recovery_all =
        recovery.authority_ref != null and
        recovery.authority_digest != null and
        recovery.reason != null;
    const recovery_none =
        recovery.authority_ref == null and
        recovery.authority_digest == null and
        recovery.reason == null;
    switch (kind) {
        .legacy_v1 => return error.InvalidGenerationKind,
        .implementation => {
            if ((!review_none and !review_all) or !recovery_none) {
                return error.UnexpectedGenerationEvidence;
            }
            if (review_all) {
                try validateRepoPath(review.policy_ref.?);
                try validateDigest(review.policy_digest.?);
                try validateRepoPath(review.resolution_ref.?);
                try validateDigest(review.resolution_digest.?);
            }
        },
        .review_repair, .terminal_proof => {
            if (!review_all or !recovery_none) return error.ReviewEvidenceRequired;
            try validateRepoPath(review.policy_ref.?);
            try validateDigest(review.policy_digest.?);
            try validateRepoPath(review.resolution_ref.?);
            try validateDigest(review.resolution_digest.?);
        },
        .recovery => {
            if (!review_none or !recovery_all) return error.RecoveryEvidenceRequired;
            try validateRepoPath(recovery.authority_ref.?);
            try validateDigest(recovery.authority_digest.?);
            _ = RecoveryReason.parse(recovery.reason.?) orelse return error.InvalidRecoveryReason;
        },
    }
}

fn validateAdmissionEvidenceScope(
    admission: GenerationAdmissionInput,
    allowed_paths: []const []const u8,
    kind: GenerationKind,
) !void {
    try validateEvidenceOutsideMutationScope(admission.basis.ref, allowed_paths);
    switch (kind) {
        .legacy_v1 => return error.InvalidGenerationKind,
        .implementation => if (hasCompleteReviewEvidence(admission.review)) {
            try validateEvidenceOutsideMutationScope(
                admission.review.policy_ref.?,
                allowed_paths,
            );
            try validateEvidenceOutsideMutationScope(
                admission.review.resolution_ref.?,
                allowed_paths,
            );
        },
        .review_repair, .terminal_proof => {
            try validateEvidenceOutsideMutationScope(admission.review.policy_ref.?, allowed_paths);
            try validateEvidenceOutsideMutationScope(
                admission.review.resolution_ref.?,
                allowed_paths,
            );
        },
        .recovery => try validateEvidenceOutsideMutationScope(
            admission.recovery.authority_ref.?,
            allowed_paths,
        ),
    }
}

fn hasCompleteReviewEvidence(review: ReviewAdmissionInput) bool {
    return review.policy_ref != null and
        review.policy_digest != null and
        review.resolution_ref != null and
        review.resolution_digest != null;
}

fn validateEvidenceOutsideMutationScope(ref: []const u8, allowed_paths: []const []const u8) !void {
    if (pathOverlapsAny(ref, allowed_paths)) return error.MutableAdmissionEvidence;
}

fn validateStateEvidencePhysicalScope(
    allocator: std.mem.Allocator,
    repo: []const u8,
    state: *const RunState,
    mutation_paths: []const []const u8,
) !void {
    const admission = state.admission orelse return error.LegacyRunReadOnly;
    try validatePhysicalEvidenceRef(
        allocator,
        repo,
        state.store_path,
        admission.basis_ref,
        mutation_paths,
    );
    if (admission.review_policy_ref) |ref| {
        try validatePhysicalEvidenceRef(allocator, repo, state.store_path, ref, mutation_paths);
    }
    if (admission.review_resolution_ref) |ref| {
        try validatePhysicalEvidenceRef(allocator, repo, state.store_path, ref, mutation_paths);
    }
    if (admission.recovery_authority_ref) |ref| {
        try validatePhysicalEvidenceRef(allocator, repo, state.store_path, ref, mutation_paths);
    }
}

fn validatePhysicalEvidenceRef(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    evidence_ref: []const u8,
    mutation_paths: []const []const u8,
) !void {
    const evidence_path = try std.fs.path.join(allocator, &.{ repo, evidence_ref });
    defer allocator.free(evidence_path);
    durable_store.rejectSymlinkComponents(evidence_path) catch {
        return error.EvidenceRefUnreadable;
    };
    const evidence_real = std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        evidence_path,
        allocator,
    ) catch return error.EvidenceRefUnreadable;
    defer allocator.free(evidence_real);
    const evidence_stat = std.Io.Dir.cwd().statFile(
        defaultIo(),
        evidence_real,
        .{ .follow_symlinks = false },
    ) catch return error.EvidenceRefUnreadable;
    if (evidence_stat.kind != .file) return error.EvidenceRefUnreadable;
    const evidence_identity = fileIdentityForPath(evidence_real) catch {
        return error.EvidenceRefUnreadable;
    };

    try validateEvidenceIdentityOutsidePaths(
        allocator,
        repo,
        evidence_real,
        evidence_identity,
        mutation_paths,
    );
    try validateEvidenceIdentityOutsideControlPlane(
        allocator,
        repo,
        store_path,
        evidence_real,
        evidence_identity,
    );
}

fn validateEvidenceSnapshotPhysicalScope(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    snapshot: *const EvidenceSnapshot,
    mutation_paths: []const []const u8,
) !void {
    try validateEvidenceIdentityOutsidePaths(
        allocator,
        repo,
        snapshot.real_path,
        snapshot.file_identity,
        mutation_paths,
    );
    try validateEvidenceIdentityOutsideControlPlane(
        allocator,
        repo,
        store_path,
        snapshot.real_path,
        snapshot.file_identity,
    );
}

fn validateEvidenceIdentityOutsideControlPlane(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    evidence_real: []const u8,
    evidence_identity: FileIdentity,
) !void {
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{store_path});
    defer allocator.free(lock_path);
    var controls = collectControlIdentities(allocator, repo, store_path, lock_path) catch {
        return error.InvalidActuationStorePath;
    };
    defer for (&controls) |*control| control.deinit(allocator);
    const evidence = PhysicalPathIdentity{
        .real_path = evidence_real,
        .stat = null,
        .file_identity = evidence_identity,
    };
    if (identityAliasesAny(&evidence, &controls)) return error.MutableAdmissionEvidence;
}

fn validateEvidenceIdentityOutsidePaths(
    allocator: std.mem.Allocator,
    repo: []const u8,
    evidence_real: []const u8,
    evidence_identity: FileIdentity,
    mutation_paths: []const []const u8,
) !void {
    const evidence = PhysicalPathIdentity{
        .real_path = evidence_real,
        .stat = null,
        .file_identity = evidence_identity,
    };
    var scan_entries_remaining: usize = MaxAllowedPathScanEntries;
    for (mutation_paths) |mutation_ref| {
        const mutation_path = try std.fs.path.join(allocator, &.{ repo, mutation_ref });
        defer allocator.free(mutation_path);
        durable_store.rejectSymlinkComponents(mutation_path) catch {
            return error.MutableAdmissionEvidence;
        };
        var mutation = try physicalPathIdentityAlloc(allocator, mutation_path);
        defer mutation.deinit(allocator);
        if (identityAliasesAny(&mutation, &.{evidence})) {
            return error.MutableAdmissionEvidence;
        }
        const mutation_stat = mutation.stat orelse continue;
        if (mutation_stat.kind == .directory) {
            const scan = scanDirectoryForPhysicalAliases(
                allocator,
                mutation.real_path,
                &.{evidence},
                &scan_entries_remaining,
            ) catch return error.MutableAdmissionEvidence;
            if (scan != .clear) return error.MutableAdmissionEvidence;
        }
    }
}

fn canonicalExistingPrefixAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    var probe = try allocator.dupe(u8, path);
    defer allocator.free(probe);
    for (0..MaxAllowedPathScanEntries) |_| {
        const stat = std.Io.Dir.cwd().statFile(
            defaultIo(),
            probe,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (stat != null) {
            const real = try std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), probe, allocator);
            defer allocator.free(real);
            const suffix = std.mem.trim(u8, path[probe.len..], "/\\");
            return if (suffix.len == 0)
                allocator.dupe(u8, real)
            else
                std.fs.path.join(allocator, &.{ real, suffix });
        }
        const parent = std.fs.path.dirname(probe) orelse return error.InvalidRepoPath;
        if (std.mem.eql(u8, parent, probe)) return error.InvalidRepoPath;
        const next = try allocator.dupe(u8, parent);
        allocator.free(probe);
        probe = next;
    }
    return error.AllowedPathScanLimitExceeded;
}

fn validateSupersedeInput(input: SupersedeInput) !RecoveryReason {
    if (!std.mem.eql(u8, input.schema, "actuation-supersede/v1")) return error.InvalidInputSchema;
    try validateGenerationEvidenceFields(input.basis, .{}, input.recovery, .recovery);
    if (input.external_run_id) |run_id| try validateToken("external_run_id", run_id);
    return RecoveryReason.parse(input.recovery.reason.?) orelse error.InvalidRecoveryReason;
}

fn openEvidenceSnapshot(
    allocator: std.mem.Allocator,
    repo: []const u8,
    evidence: EvidenceInput,
) !EvidenceSnapshot {
    try validateRepoPath(evidence.ref);
    try validateDigest(evidence.digest);
    const path = try std.fs.path.join(allocator, &.{ repo, evidence.ref });
    errdefer allocator.free(path);
    durable_store.rejectSymlinkComponents(path) catch return error.EvidenceRefUnreadable;
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(
        defaultIo(),
        path,
        allocator,
    ) catch return error.EvidenceRefUnreadable;
    errdefer allocator.free(real_path);
    var file = std.Io.Dir.openFileAbsolute(defaultIo(), real_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return error.EvidenceRefUnreadable;
    defer file.close(defaultIo());
    const before = file.stat(defaultIo()) catch return error.EvidenceRefUnreadable;
    if (before.kind != .file or before.size > MaxInputBytes) {
        return error.EvidenceRefUnreadable;
    }
    const file_identity = fileIdentityFromHandle(file) catch {
        return error.EvidenceRefUnreadable;
    };
    var reader = file.reader(defaultIo(), &.{});
    const bytes = reader.interface.allocRemaining(
        allocator,
        .limited(MaxInputBytes + 1),
    ) catch return error.EvidenceRefUnreadable;
    errdefer allocator.free(bytes);
    const after = file.stat(defaultIo()) catch return error.EvidenceRefUnreadable;
    if (!sameEvidenceFileStat(before, after) or bytes.len != before.size) {
        return error.EvidenceSnapshotDrift;
    }
    const digest = try digestTextAlloc(allocator, bytes);
    defer allocator.free(digest);
    if (!std.mem.eql(u8, digest, evidence.digest)) return error.EvidenceDigestMismatch;
    return .{
        .ref = evidence.ref,
        .path = path,
        .real_path = real_path,
        .bytes = bytes,
        .stat = before,
        .file_identity = file_identity,
    };
}

fn sameEvidenceFileStat(left: std.Io.File.Stat, right: std.Io.File.Stat) bool {
    return left.kind == .file and
        right.kind == .file and
        left.inode == right.inode and
        left.nlink == right.nlink and
        left.size == right.size and
        left.permissions.toMode() == right.permissions.toMode() and
        left.mtime.nanoseconds == right.mtime.nanoseconds and
        left.ctime.nanoseconds == right.ctime.nanoseconds;
}

fn validateAdmissionEvidence(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    input: OpenInput,
    kind: GenerationKind,
) !?ReviewWorkNodeState {
    var basis_snapshot = try openEvidenceSnapshot(
        allocator,
        repo,
        input.generation_admission.basis,
    );
    defer basis_snapshot.deinit(allocator);
    try validateEvidenceSnapshotPhysicalScope(
        allocator,
        repo,
        store_path,
        &basis_snapshot,
        input.allowed_paths,
    );
    if (kind == .recovery) {
        const authority = EvidenceInput{
            .ref = input.generation_admission.recovery.authority_ref.?,
            .digest = input.generation_admission.recovery.authority_digest.?,
        };
        if (std.mem.eql(u8, authority.ref, input.generation_admission.basis.ref)) {
            if (!std.mem.eql(
                u8,
                authority.digest,
                input.generation_admission.basis.digest,
            )) {
                return error.EvidenceDigestMismatch;
            }
        } else {
            var authority_snapshot = try openEvidenceSnapshot(allocator, repo, authority);
            defer authority_snapshot.deinit(allocator);
            try validateEvidenceSnapshotPhysicalScope(
                allocator,
                repo,
                store_path,
                &authority_snapshot,
                input.allowed_paths,
            );
        }
        return null;
    }
    const review_bound_implementation = kind == .implementation and
        hasCompleteReviewEvidence(input.generation_admission.review);
    if (!review_bound_implementation and
        kind != .review_repair and
        kind != .terminal_proof)
    {
        return null;
    }
    const review = input.generation_admission.review;
    const policy_input = EvidenceInput{
        .ref = review.policy_ref.?,
        .digest = review.policy_digest.?,
    };
    var owned_policy_snapshot: ?EvidenceSnapshot = null;
    defer if (owned_policy_snapshot) |*snapshot| snapshot.deinit(allocator);
    const policy_snapshot: *const EvidenceSnapshot = if (std.mem.eql(
        u8,
        policy_input.ref,
        input.generation_admission.basis.ref,
    )) blk: {
        if (!std.mem.eql(
            u8,
            policy_input.digest,
            input.generation_admission.basis.digest,
        )) return error.EvidenceDigestMismatch;
        break :blk &basis_snapshot;
    } else blk: {
        owned_policy_snapshot = try openEvidenceSnapshot(allocator, repo, policy_input);
        try validateEvidenceSnapshotPhysicalScope(
            allocator,
            repo,
            store_path,
            &owned_policy_snapshot.?,
            input.allowed_paths,
        );
        break :blk &owned_policy_snapshot.?;
    };
    const resolution_input = EvidenceInput{
        .ref = review.resolution_ref.?,
        .digest = review.resolution_digest.?,
    };
    var owned_resolution_snapshot: ?EvidenceSnapshot = null;
    defer if (owned_resolution_snapshot) |*snapshot| snapshot.deinit(allocator);
    const resolution_snapshot: *const EvidenceSnapshot = if (std.mem.eql(
        u8,
        resolution_input.ref,
        input.generation_admission.basis.ref,
    )) blk: {
        if (!std.mem.eql(
            u8,
            resolution_input.digest,
            input.generation_admission.basis.digest,
        )) return error.EvidenceDigestMismatch;
        break :blk &basis_snapshot;
    } else if (std.mem.eql(u8, resolution_input.ref, policy_input.ref)) blk: {
        if (!std.mem.eql(u8, resolution_input.digest, policy_input.digest)) {
            return error.EvidenceDigestMismatch;
        }
        break :blk policy_snapshot;
    } else blk: {
        owned_resolution_snapshot = try openEvidenceSnapshot(
            allocator,
            repo,
            resolution_input,
        );
        try validateEvidenceSnapshotPhysicalScope(
            allocator,
            repo,
            store_path,
            &owned_resolution_snapshot.?,
            input.allowed_paths,
        );
        break :blk &owned_resolution_snapshot.?;
    };
    const policy_bytes = policy_snapshot.bytes;
    const resolution_bytes = resolution_snapshot.bytes;

    const repair_admission = review_bound_implementation or kind == .review_repair;
    const policy_valid = if (repair_admission)
        try actuating_review_policy_cli.validateRepairAdmissionBytes(
            allocator,
            defaultIo(),
            policy_bytes,
            false,
        )
    else
        try actuating_review_policy_cli.validateCloseoutBytes(
            allocator,
            defaultIo(),
            policy_bytes,
            false,
        );
    if (!policy_valid) {
        return error.ReviewPolicyNotTerminal;
    }

    const resolution_valid = if (repair_admission)
        try actuating_review_resolution_cli.validatePreflightBytes(
            allocator,
            resolution_bytes,
        )
    else
        (try actuating_review_resolution_cli.validateCloseoutBytes(
            allocator,
            resolution_bytes,
        )) == .clean;
    if (!resolution_valid) {
        return error.ReviewResolutionNotTerminal;
    }
    return validateReviewEvidenceJoin(
        allocator,
        repo,
        store_path,
        input,
        policy_bytes,
        resolution_bytes,
        repair_admission,
    );
}

fn validateReviewEvidenceJoin(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    input: OpenInput,
    policy_bytes: []const u8,
    resolution_bytes: []const u8,
    repair_admission: bool,
) !?ReviewWorkNodeState {
    var parsed_policy = std.json.parseFromSlice(
        ReviewPolicyAdmissionEnvelope,
        allocator,
        policy_bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return error.ReviewEvidenceJoinMismatch;
    defer parsed_policy.deinit();
    var parsed_resolution = std.json.parseFromSlice(
        ReviewResolutionAdmissionEnvelope,
        allocator,
        resolution_bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return error.ReviewEvidenceJoinMismatch;
    defer parsed_resolution.deinit();
    const policy = parsed_policy.value.actuation_review_policy;
    const resolution = parsed_resolution.value.review_resolution;
    const review = input.generation_admission.review;

    if (!std.mem.eql(u8, policy.version, "actuation-review-policy/v2") or
        !std.mem.eql(u8, resolution.version, "review-resolution/v1") or
        !std.mem.eql(u8, policy.goal_contract_digest, input.goal_contract_digest) or
        !std.mem.eql(u8, resolution.run_id, input.run_id) or
        !std.mem.eql(u8, resolution.review_profile.policy_ref, review.policy_ref.?) or
        !std.mem.eql(u8, resolution.review_profile.policy_digest, review.policy_digest.?) or
        policy.review_contract_digest == null or
        !std.mem.eql(
            u8,
            resolution.review_profile.review_contract_fingerprint,
            policy.review_contract_digest.?,
        ))
    {
        return error.ReviewEvidenceJoinMismatch;
    }
    if (resolution.review_folds.len == 0) return error.ReviewEvidenceJoinMismatch;
    for (resolution.review_folds) |fold| {
        if (fold.goal_id == null or !std.mem.eql(u8, fold.goal_id.?, input.goal_id)) {
            return error.ReviewEvidenceJoinMismatch;
        }
    }
    try validateCurrentReviewArtifact(
        allocator,
        repo,
        store_path,
        review.policy_ref.?,
        review.resolution_ref.?,
        policy.artifact,
        resolution.artifact,
    );

    var selected: ?ReviewWorkNodeInput = null;
    for (resolution.decisions) |decision| if (decision.selected_work_node) |node| {
        if (selected != null) return error.ReviewWorkNodeCardinality;
        selected = node;
    };
    if (!repair_admission) {
        if (selected != null) return error.TerminalProofSelectsMutation;
        return null;
    }
    const node = selected orelse return error.ReviewWorkNodeMissing;
    try validateNonEmpty("review_work_node_id", node.node_id);
    try validateNonEmpty("review_work_node_owner", node.owner_boundary);
    if (!std.mem.eql(u8, node.run_id, input.run_id) or
        !try equalCanonicalStringSets(allocator, node.paths, input.allowed_paths) or
        node.verifier.len == 0)
    {
        return error.ReviewWorkNodeMismatch;
    }
    for (node.verifier) |arg| try validateNonEmpty("review_work_node_verifier", arg);
    return .{
        .node_id = try allocator.dupe(u8, node.node_id),
        .run_id = try allocator.dupe(u8, node.run_id),
        .owner_boundary = try allocator.dupe(u8, node.owner_boundary),
        .paths = try dupeStringList(allocator, node.paths),
        .verifier = try dupeStringList(allocator, node.verifier),
    };
}

fn validateCurrentReviewArtifact(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    policy_ref: []const u8,
    resolution_ref: []const u8,
    policy: ReviewPolicyArtifactView,
    resolution: ReviewResolutionArtifactView,
) !void {
    if (policy.base_ref.len == 0 or policy.base_ref[0] == '-' or
        !std.mem.eql(u8, policy.repo, repo) or
        !std.mem.eql(u8, resolution.repo, repo) or
        !std.mem.eql(u8, policy.base_sha, resolution.base_sha) or
        !std.mem.eql(u8, policy.head_sha, resolution.head_sha) or
        !std.mem.eql(u8, policy.state_fingerprint, resolution.state_fingerprint))
    {
        return error.ReviewArtifactMismatch;
    }
    const head_raw = try runGitRawAlloc(allocator, repo, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const base_raw = try runGitRawAlloc(allocator, repo, &.{
        "merge-base",
        "HEAD",
        policy.base_ref,
    });
    defer allocator.free(base_raw);
    const branch_raw = try runGitRawAlloc(allocator, repo, &.{ "branch", "--show-current" });
    defer allocator.free(branch_raw);
    const head = std.mem.trim(u8, head_raw, " \t\r\n");
    const base = std.mem.trim(u8, base_raw, " \t\r\n");
    const branch = std.mem.trim(u8, branch_raw, " \t\r\n");
    const state = try reviewArtifactStateDigestAlloc(
        allocator,
        repo,
        store_path,
        policy_ref,
        resolution_ref,
    );
    defer allocator.free(state);
    if (!std.mem.eql(u8, policy.head_sha, head) or
        !std.mem.eql(u8, policy.base_sha, base) or
        !std.mem.eql(u8, resolution.branch, branch) or
        !std.mem.eql(u8, policy.state_fingerprint, state))
    {
        return error.ReviewArtifactStale;
    }
}

fn validateOpenLineage(
    allocator: std.mem.Allocator,
    input: OpenInput,
    validated: ValidatedOpen,
    generation_id: []const u8,
    predecessor: ?*const RunIndexEntry,
    index: []const RunIndexEntry,
    review_work_node: ?ReviewWorkNodeInput,
) !void {
    for (index) |entry| {
        if (entry.generation_id) |existing| {
            if (std.mem.eql(u8, existing, generation_id)) return error.DuplicateGenerationId;
        }
    }
    if (validated.kind == .implementation) {
        for (index) |entry| {
            if (entry.kind != .legacy_v1 and
                entry.predecessor_run_id == null and
                std.mem.eql(u8, entry.goal_id, input.goal_id))
            {
                return error.DuplicateGoalRoot;
            }
        }
        return;
    }

    const prior = predecessor orelse return error.PredecessorRunNotFound;
    if (!std.mem.eql(u8, prior.goal_id, input.goal_id)) {
        return error.PredecessorGoalMismatch;
    }
    for (index) |entry| {
        if (entry.predecessor_run_id) |parent| {
            if (std.mem.eql(u8, parent, prior.run_id)) return error.SuccessorAlreadyExists;
        }
    }
    switch (validated.kind) {
        .legacy_v1, .implementation => unreachable,
        .review_repair => {
            if (prior.phase != .closed) return error.PredecessorNotClosed;
        },
        .terminal_proof => {
            if (prior.phase != .closed) return error.PredecessorNotClosed;
            if (!try equalCanonicalStringSets(
                allocator,
                input.allowed_paths,
                stringSlice(prior.allowed_paths),
            )) {
                return error.TerminalProofScopeMismatch;
            }
        },
        .recovery => {
            if (prior.phase != .superseded) return error.PredecessorNotSuperseded;
            if (!try optionalReviewWorkNodesEqual(
                allocator,
                review_work_node,
                if (prior.review_work_node) |*node| node.input() else null,
            )) {
                return error.ReviewWorkNodeMismatch;
            }
            const reserved = prior.reserved_successor_generation_id orelse {
                return error.RecoveryReservationMissing;
            };
            if (!std.mem.eql(u8, reserved, generation_id)) return error.RecoveryReservationMismatch;
            const candidate_contract = try recoveryContractDigestInputAlloc(
                allocator,
                input,
                validated.completion,
                review_work_node,
            );
            defer allocator.free(candidate_contract);
            if (!std.mem.eql(u8, candidate_contract, prior.recovery_contract_digest)) {
                return error.RecoveryBroadensContract;
            }
        },
    }
}

fn validateReplayedLineage(
    allocator: std.mem.Allocator,
    states: []const RunState,
    candidate: *const RunState,
) !void {
    const admission = candidate.admission orelse return;
    const generation_id = candidate.generation_id orelse return error.GenerationIdMissing;
    for (states) |state| {
        if (state.generation_id) |existing| {
            if (std.mem.eql(u8, existing, generation_id)) return error.DuplicateGenerationId;
        }
    }
    if (admission.kind == .implementation) {
        if (admission.predecessor_run_id != null or
            candidate.predecessor_generation_id != null)
        {
            return error.ImplementationMustBeRoot;
        }
        for (states) |state| {
            if (state.admission != null and state.admission.?.predecessor_run_id == null and
                std.mem.eql(u8, state.goal_id, candidate.goal_id))
            {
                return error.DuplicateGoalRoot;
            }
        }
        return;
    }
    const predecessor_run_id = admission.predecessor_run_id orelse return error.PredecessorRequired;
    const predecessor_index =
        findRunState(states, predecessor_run_id) orelse return error.PredecessorRunNotFound;
    const predecessor = &states[predecessor_index];
    const predecessor_generation_id =
        predecessor.generation_id orelse return error.LegacyPredecessorUnsupported;
    if (candidate.predecessor_generation_id == null or
        !std.mem.eql(u8, candidate.predecessor_generation_id.?, predecessor_generation_id) or
        !std.mem.eql(u8, candidate.goal_id, predecessor.goal_id))
    {
        return error.PredecessorGoalMismatch;
    }
    for (states) |state| {
        if (state.admission) |existing_admission| {
            if (existing_admission.predecessor_run_id) |parent| {
                if (std.mem.eql(u8, parent, predecessor_run_id)) {
                    return error.SuccessorAlreadyExists;
                }
            }
        }
    }
    switch (admission.kind) {
        .legacy_v1, .implementation => unreachable,
        .review_repair => {
            if (predecessor.phase != .closed) return error.PredecessorNotClosed;
        },
        .terminal_proof => {
            if (predecessor.phase != .closed) return error.PredecessorNotClosed;
            if (!try equalCanonicalStringSets(
                allocator,
                stringSlice(candidate.allowed_paths),
                stringSlice(predecessor.allowed_paths),
            )) {
                return error.TerminalProofScopeMismatch;
            }
        },
        .recovery => {
            if (predecessor.phase != .superseded) return error.PredecessorNotSuperseded;
            if (!try optionalReviewWorkNodesEqual(
                allocator,
                if (candidate.review_work_node) |*node| node.input() else null,
                if (predecessor.review_work_node) |*node| node.input() else null,
            )) {
                return error.ReviewWorkNodeMismatch;
            }
            const reserved = predecessor.reserved_successor_generation_id orelse {
                return error.RecoveryReservationMissing;
            };
            if (!std.mem.eql(u8, reserved, generation_id)) return error.RecoveryReservationMismatch;
            const candidate_contract = try recoveryContractDigestStateAlloc(allocator, candidate);
            defer allocator.free(candidate_contract);
            const predecessor_contract = try recoveryContractDigestStateAlloc(
                allocator,
                predecessor,
            );
            defer allocator.free(predecessor_contract);
            if (!std.mem.eql(u8, candidate_contract, predecessor_contract)) {
                return error.RecoveryBroadensContract;
            }
        },
    }
}

fn generationIdAlloc(
    allocator: std.mem.Allocator,
    input: OpenInput,
    kind: GenerationKind,
    completion: Completion,
    artifact_digest: []const u8,
    predecessor_generation_id: ?[]const u8,
    review_work_node: ?ReviewWorkNodeInput,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "schema", "actuation-generation-id/v1");
    hashTagged(&hasher, "goal", input.goal_id);
    hashTagged(&hasher, "goal-contract", input.goal_contract_digest);
    hashTagged(&hasher, "kind", kind.name());
    hashTagged(&hasher, "predecessor-generation", predecessor_generation_id orelse "root");
    hashTagged(&hasher, "basis-ref", input.generation_admission.basis.ref);
    hashTagged(&hasher, "basis-digest", input.generation_admission.basis.digest);
    hashTagged(
        &hasher,
        "review-policy-ref",
        input.generation_admission.review.policy_ref orelse "",
    );
    hashTagged(
        &hasher,
        "review-policy-digest",
        input.generation_admission.review.policy_digest orelse "",
    );
    hashTagged(
        &hasher,
        "review-resolution-ref",
        input.generation_admission.review.resolution_ref orelse "",
    );
    hashTagged(
        &hasher,
        "review-resolution-digest",
        input.generation_admission.review.resolution_digest orelse "",
    );
    hashTagged(
        &hasher,
        "recovery-authority-ref",
        input.generation_admission.recovery.authority_ref orelse "",
    );
    hashTagged(
        &hasher,
        "recovery-authority-digest",
        input.generation_admission.recovery.authority_digest orelse "",
    );
    hashTagged(&hasher, "recovery-reason", input.generation_admission.recovery.reason orelse "");
    hashTagged(&hasher, "resolution", input.resolution_digest orelse "");
    hashTagged(&hasher, "source", input.source_ref);
    hashTagged(&hasher, "execution-authority", input.execution_authority_ref);
    hashTagged(&hasher, "mutation", if (input.mutation_allowed) "true" else "false");
    hashTagged(&hasher, "completion", completion.name());
    hashTagged(&hasher, "artifact", artifact_digest);
    if (review_work_node) |node| {
        hashTagged(&hasher, "review-work-node", node.node_id);
        hashTagged(&hasher, "review-work-run", node.run_id);
        hashTagged(&hasher, "review-work-owner", node.owner_boundary);
        try hashCanonicalPaths(allocator, &hasher, node.paths);
        for (node.verifier) |arg| hashTagged(&hasher, "review-work-verifier", arg);
    }
    try hashCanonicalPaths(allocator, &hasher, input.allowed_paths);
    try hashCanonicalObligationInputs(allocator, &hasher, input.obligations);
    return finishDigestAlloc(allocator, &hasher);
}

fn generationIdFromBodyAlloc(
    allocator: std.mem.Allocator,
    body: RunOpenedBodyV2,
    kind: GenerationKind,
    completion: Completion,
) ![]u8 {
    const input = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = "replay",
        .goal_id = body.goal_id,
        .goal_contract_digest = body.goal_contract_digest,
        .resolution_digest = body.resolution_digest,
        .source_ref = body.source_ref,
        .execution_authority_ref = body.execution_authority_ref,
        .mutation_allowed = body.mutation_allowed,
        .completion = body.completion,
        .allowed_paths = body.allowed_paths,
        .obligations = body.obligations,
        .generation_admission = body.generation_admission,
    };
    return generationIdAlloc(
        allocator,
        input,
        kind,
        completion,
        body.artifact_digest,
        body.predecessor_generation_id,
        body.review_work_node,
    );
}

fn recoveryContractDigestInputAlloc(
    allocator: std.mem.Allocator,
    input: OpenInput,
    completion: Completion,
    review_work_node: ?ReviewWorkNodeInput,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "schema", "actuation-recovery-contract/v1");
    hashTagged(&hasher, "goal", input.goal_id);
    hashTagged(&hasher, "goal-contract", input.goal_contract_digest);
    hashTagged(&hasher, "resolution", input.resolution_digest orelse "");
    hashTagged(&hasher, "source", input.source_ref);
    hashTagged(&hasher, "execution-authority", input.execution_authority_ref);
    hashTagged(&hasher, "mutation", if (input.mutation_allowed) "true" else "false");
    hashTagged(&hasher, "completion", completion.name());
    try hashReviewWorkNode(allocator, &hasher, review_work_node);
    try hashCanonicalPaths(allocator, &hasher, input.allowed_paths);
    try hashCanonicalObligationInputs(allocator, &hasher, input.obligations);
    return finishDigestAlloc(allocator, &hasher);
}

fn recoveryContractDigestStateAlloc(allocator: std.mem.Allocator, state: *const RunState) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "schema", "actuation-recovery-contract/v1");
    hashTagged(&hasher, "goal", state.goal_id);
    hashTagged(&hasher, "goal-contract", state.goal_contract_digest);
    hashTagged(&hasher, "resolution", state.resolution_digest orelse "");
    hashTagged(&hasher, "source", state.source_ref);
    hashTagged(&hasher, "execution-authority", state.execution_authority_ref);
    hashTagged(&hasher, "mutation", if (state.mutation_allowed) "true" else "false");
    hashTagged(&hasher, "completion", state.completion.name());
    try hashReviewWorkNode(
        allocator,
        &hasher,
        if (state.review_work_node) |*node| node.input() else null,
    );
    try hashCanonicalPaths(allocator, &hasher, stringSlice(state.allowed_paths));
    try hashCanonicalObligationStates(allocator, &hasher, state.obligations);
    return finishDigestAlloc(allocator, &hasher);
}

fn hashReviewWorkNode(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    maybe_node: ?ReviewWorkNodeInput,
) !void {
    const node = maybe_node orelse {
        hashTagged(hasher, "review-work-node", "none");
        return;
    };
    hashTagged(hasher, "review-work-node", node.node_id);
    hashTagged(hasher, "review-work-run", node.run_id);
    hashTagged(hasher, "review-work-owner", node.owner_boundary);
    const ordered_paths = try canonicalStringOrderAlloc(allocator, node.paths);
    defer allocator.free(ordered_paths);
    for (ordered_paths) |path| hashTagged(hasher, "review-work-path", path);
    for (node.verifier) |arg| hashTagged(hasher, "review-work-verifier", arg);
}

fn optionalReviewWorkNodesEqual(
    allocator: std.mem.Allocator,
    left: ?ReviewWorkNodeInput,
    right: ?ReviewWorkNodeInput,
) !bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?.node_id, right.?.node_id) and
        std.mem.eql(u8, left.?.run_id, right.?.run_id) and
        std.mem.eql(u8, left.?.owner_boundary, right.?.owner_boundary) and
        try equalCanonicalStringSets(allocator, left.?.paths, right.?.paths) and
        equalStringLists(left.?.verifier, right.?.verifier);
}

fn hashCanonicalPaths(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    paths: []const []const u8,
) !void {
    const ordered = try canonicalStringOrderAlloc(allocator, paths);
    defer allocator.free(ordered);
    for (ordered) |path| hashTagged(hasher, "allowed-path", path);
}

fn canonicalStringOrderAlloc(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![][]const u8 {
    const ordered = try allocator.alloc([]const u8, values.len);
    @memcpy(ordered, values);
    std.mem.sort([]const u8, ordered, {}, lessStringSlice);
    return ordered;
}

fn equalCanonicalStringSets(
    allocator: std.mem.Allocator,
    left: []const []const u8,
    right: []const []const u8,
) !bool {
    if (left.len != right.len) return false;
    const ordered_left = try allocator.alloc([]const u8, left.len);
    defer allocator.free(ordered_left);
    const ordered_right = try allocator.alloc([]const u8, right.len);
    defer allocator.free(ordered_right);
    @memcpy(ordered_left, left);
    @memcpy(ordered_right, right);
    std.mem.sort([]const u8, ordered_left, {}, lessStringSlice);
    std.mem.sort([]const u8, ordered_right, {}, lessStringSlice);
    return equalStringLists(ordered_left, ordered_right);
}

fn hashCanonicalObligationInputs(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    obligations: []const ObligationInput,
) !void {
    const ordered = try allocator.alloc(*const ObligationInput, obligations.len);
    defer allocator.free(ordered);
    for (obligations, 0..) |*obligation, index| ordered[index] = obligation;
    std.mem.sort(*const ObligationInput, ordered, {}, lessObligationInput);
    for (ordered) |obligation| {
        hashTagged(hasher, "obligation", obligation.id);
        hashTagged(hasher, "obligation-kind", obligation.kind);
        hashTagged(hasher, "statement", obligation.statement);
        for (obligation.verifier) |arg| hashTagged(hasher, "verifier", arg);
    }
}

fn hashCanonicalObligationStates(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    obligations: []const ObligationState,
) !void {
    const ordered = try allocator.alloc(*const ObligationState, obligations.len);
    defer allocator.free(ordered);
    for (obligations, 0..) |*obligation, index| ordered[index] = obligation;
    std.mem.sort(*const ObligationState, ordered, {}, lessObligationState);
    for (ordered) |obligation| {
        hashTagged(hasher, "obligation", obligation.id);
        hashTagged(hasher, "obligation-kind", obligation.kind.name());
        hashTagged(hasher, "statement", obligation.statement);
        for (obligation.verifier) |arg| hashTagged(hasher, "verifier", arg);
    }
}

fn lessStringSlice(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn lessObligationInput(_: void, left: *const ObligationInput, right: *const ObligationInput) bool {
    return std.mem.order(u8, left.id, right.id) == .lt;
}

fn lessObligationState(_: void, left: *const ObligationState, right: *const ObligationState) bool {
    return std.mem.order(u8, left.id, right.id) == .lt;
}

fn admissionStateFromInput(
    allocator: std.mem.Allocator,
    input: GenerationAdmissionInput,
    kind: GenerationKind,
) !GenerationAdmissionState {
    return .{
        .kind = kind,
        .predecessor_run_id = if (input.predecessor_run_id) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .basis_ref = try allocator.dupe(u8, input.basis.ref),
        .basis_digest = try allocator.dupe(u8, input.basis.digest),
        .review_policy_ref = if (input.review.policy_ref) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .review_policy_digest = if (input.review.policy_digest) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .review_resolution_ref = if (input.review.resolution_ref) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .review_resolution_digest = if (input.review.resolution_digest) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .recovery_authority_ref = if (input.recovery.authority_ref) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .recovery_authority_digest = if (input.recovery.authority_digest) |value|
            try allocator.dupe(u8, value)
        else
            null,
        .recovery_reason = if (input.recovery.reason) |value| RecoveryReason.parse(value) else null,
    };
}

fn reviewWorkNodeStateFromInput(
    allocator: std.mem.Allocator,
    input: ReviewWorkNodeInput,
) !ReviewWorkNodeState {
    return .{
        .node_id = try allocator.dupe(u8, input.node_id),
        .run_id = try allocator.dupe(u8, input.run_id),
        .owner_boundary = try allocator.dupe(u8, input.owner_boundary),
        .paths = try dupeStringList(allocator, input.paths),
        .verifier = try dupeStringList(allocator, input.verifier),
    };
}

fn obligationStatesAlloc(
    allocator: std.mem.Allocator,
    inputs: []const ObligationInput,
) ![]ObligationState {
    const obligations = try allocator.alloc(ObligationState, inputs.len);
    var initialized: usize = 0;
    errdefer {
        for (obligations[0..initialized]) |*obligation| obligation.deinit(allocator);
        allocator.free(obligations);
    }
    for (inputs, 0..) |source, index| {
        obligations[index] = .{
            .id = try allocator.dupe(u8, source.id),
            .kind = ObligationKind.parse(source.kind) orelse return error.InvalidObligationKind,
            .statement = try allocator.dupe(u8, source.statement),
            .verifier = try dupeStringList(allocator, source.verifier),
        };
        initialized += 1;
    }
    return obligations;
}

fn freeObligationStates(allocator: std.mem.Allocator, obligations: []ObligationState) void {
    for (obligations) |*obligation| obligation.deinit(allocator);
    allocator.free(obligations);
}

fn obligationInputsAlloc(
    allocator: std.mem.Allocator,
    states: []const ObligationState,
) ![]ObligationInput {
    const inputs = try allocator.alloc(ObligationInput, states.len);
    for (states, 0..) |state, index| {
        inputs[index] = .{
            .id = state.id,
            .kind = state.kind.name(),
            .statement = state.statement,
            .verifier = stringSlice(state.verifier),
        };
    }
    return inputs;
}

fn pathStatesFromWiresAlloc(
    allocator: std.mem.Allocator,
    wires: []const PathStateWire,
) ![]PathState {
    const states = try allocator.alloc(PathState, wires.len);
    var initialized: usize = 0;
    errdefer {
        for (states[0..initialized]) |*state| state.deinit(allocator);
        allocator.free(states);
    }
    for (wires, 0..) |wire, index| {
        states[index] = .{
            .path = try allocator.dupe(u8, wire.path),
            .digest = try allocator.dupe(u8, wire.digest),
        };
        initialized += 1;
    }
    return states;
}

fn findRunIndex(index: []const RunIndexEntry, run_id: []const u8) ?*const RunIndexEntry {
    for (index) |*entry| if (std.mem.eql(u8, entry.run_id, run_id)) return entry;
    return null;
}

fn equalPathStates(left: []const PathState, right: []const PathState) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.digest, b.digest)) return false;
    }
    return true;
}

fn appendChangedPaths(
    allocator: std.mem.Allocator,
    changed: *std.ArrayList([]const u8),
    before: []const PathState,
    after: []const PathState,
) !void {
    if (before.len != after.len) return error.PathStateMismatch;
    for (before, after) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path)) return error.PathStateMismatch;
        if (!std.mem.eql(u8, left.digest, right.digest)) try changed.append(allocator, left.path);
    }
}

fn validateOperationInput(input: OperationInput) !Effect {
    if (!std.mem.eql(u8, input.schema, "actuation-operation/v1")) return error.InvalidInputSchema;
    try validateToken("step_id", input.step_id);
    try validateToken("idempotency_key", input.idempotency_key);
    try validateNonEmpty("owner_boundary", input.owner_boundary);
    if (input.paths.len == 0) return error.PathsMissing;
    if (input.obligation_refs.len == 0) return error.ObligationRefsMissing;
    return Effect.parse(input.effect) orelse error.InvalidEffect;
}

fn validateAllowedPaths(paths: []const []const u8) !void {
    if (paths.len == 0) return error.AllowedPathsMissing;
    for (paths, 0..) |path, index| {
        try validateRepoPath(path);
        if (pathOverlapsAny(path, SourceMemoryControlPaths[0..])) {
            return error.ReservedRepoPath;
        }
        for (paths[0..index]) |prior| {
            if (std.mem.eql(u8, path, prior)) return error.DuplicatePath;
            if (pathWithin(path, prior) or pathWithin(prior, path)) return error.OverlappingPath;
        }
    }
}

fn validateAllowedPathsAgainstStore(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    paths: []const []const u8,
) !void {
    const store_relative = try storeRelativeAlloc(allocator, repo, store_path);
    defer if (store_relative) |value| allocator.free(value);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{store_path});
    defer allocator.free(lock_path);
    const lock_relative = if (store_relative) |value|
        try std.fmt.allocPrint(allocator, "{s}.lock", .{value})
    else
        null;
    defer if (lock_relative) |value| allocator.free(value);
    var controls = try collectControlIdentities(allocator, repo, store_path, lock_path);
    defer for (&controls) |*control| control.deinit(allocator);
    var scan_entries_remaining: usize = MaxAllowedPathScanEntries;
    for (paths) |path| {
        if (store_relative) |value| {
            if (pathOverlapsAny(path, &.{value})) return error.ReservedRepoPath;
        }
        if (lock_relative) |value| {
            if (pathOverlapsAny(path, &.{value})) return error.ReservedRepoPath;
        }
        const path_absolute = try std.fs.path.join(allocator, &.{ repo, path });
        defer allocator.free(path_absolute);
        var allowed = try physicalPathIdentityAlloc(allocator, path_absolute);
        defer allowed.deinit(allocator);
        if (identityAliasesAny(&allowed, &controls)) return error.ReservedRepoPath;
        const stat = allowed.stat orelse continue;
        if (stat.kind != .directory) continue;
        const scan = try scanDirectoryForPhysicalAliases(
            allocator,
            allowed.real_path,
            &controls,
            &scan_entries_remaining,
        );
        if (scan != .clear) return error.ReservedRepoPath;
    }
}

const PhysicalPathIdentity = struct {
    real_path: []const u8,
    stat: ?std.Io.File.Stat,
    file_identity: ?FileIdentity,

    fn deinit(self: *PhysicalPathIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.real_path);
    }
};

const FileIdentity = struct {
    device: u128,
    inode: u128,
};

fn sameFileIdentity(left: FileIdentity, right: FileIdentity) bool {
    return left.device == right.device and left.inode == right.inode;
}

fn fileIdentityFromHandle(file: std.Io.File) !FileIdentity {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx = std.mem.zeroes(linux.Statx);
        const mask = linux.STATX{ .TYPE = true, .INO = true };
        const result = linux.statx(
            file.handle,
            "",
            linux.AT.EMPTY_PATH,
            mask,
            &statx,
        );
        if (linux.errno(result) != .SUCCESS or !statx.mask.INO) {
            return error.PhysicalIdentityUnavailable;
        }
        return .{
            .device = (@as(u128, statx.dev_major) << 64) | statx.dev_minor,
            .inode = statx.ino,
        };
    }
    if (comptime builtin.os.tag == .macos) {
        var stat = std.mem.zeroes(std.c.Stat);
        if (std.c.errno(std.c.fstat(file.handle, &stat)) != .SUCCESS) {
            return error.PhysicalIdentityUnavailable;
        }
        return .{
            .device = @as(u32, @bitCast(stat.dev)),
            .inode = stat.ino,
        };
    }
    return error.PhysicalIdentityUnsupported;
}

fn fileIdentityForPath(path: []const u8) !FileIdentity {
    var file = std.Io.Dir.openFileAbsolute(defaultIo(), path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return error.PhysicalIdentityUnavailable;
    defer file.close(defaultIo());
    return fileIdentityFromHandle(file);
}

fn physicalPathIdentityAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
) !PhysicalPathIdentity {
    const real_path = try canonicalExistingPrefixAlloc(allocator, path);
    errdefer allocator.free(real_path);
    const stat = std.Io.Dir.cwd().statFile(
        defaultIo(),
        real_path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const file_identity = if (stat) |value|
        if (value.kind == .file) try fileIdentityForPath(real_path) else null
    else
        null;
    return .{
        .real_path = real_path,
        .stat = stat,
        .file_identity = file_identity,
    };
}

fn collectControlIdentities(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    lock_path: []const u8,
) ![SourceMemoryControlPaths.len + 2]PhysicalPathIdentity {
    var identities: [SourceMemoryControlPaths.len + 2]PhysicalPathIdentity = undefined;
    var initialized: usize = 0;
    errdefer for (identities[0..initialized]) |*identity| identity.deinit(allocator);
    identities[initialized] = try physicalPathIdentityAlloc(allocator, store_path);
    initialized += 1;
    identities[initialized] = try physicalPathIdentityAlloc(allocator, lock_path);
    initialized += 1;
    for (SourceMemoryControlPaths) |control_ref| {
        const control_path = try std.fs.path.join(allocator, &.{ repo, control_ref });
        defer allocator.free(control_path);
        identities[initialized] = try physicalPathIdentityAlloc(allocator, control_path);
        initialized += 1;
    }
    return identities;
}

fn identityAliasesAny(
    candidate: *const PhysicalPathIdentity,
    controls: []const PhysicalPathIdentity,
) bool {
    for (controls) |*control| {
        if (pathWithin(candidate.real_path, control.real_path) or
            pathWithin(control.real_path, candidate.real_path)) return true;
        const candidate_file = candidate.file_identity orelse continue;
        const control_file = control.file_identity orelse continue;
        if (sameFileIdentity(candidate_file, control_file)) return true;
    }
    return false;
}

const DirectoryAliasScanResult = enum {
    clear,
    alias,
    directory_symlink,
};

fn scanDirectoryForPhysicalAliases(
    allocator: std.mem.Allocator,
    directory: []const u8,
    controls: []const PhysicalPathIdentity,
    entries_remaining: *usize,
) !DirectoryAliasScanResult {
    var dir = try std.Io.Dir.openDirAbsolute(
        defaultIo(),
        directory,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer dir.close(defaultIo());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(defaultIo())) |entry| {
        if (entries_remaining.* == 0) return error.AllowedPathScanLimitExceeded;
        entries_remaining.* -= 1;
        const child = try std.fs.path.join(allocator, &.{ directory, entry.path });
        defer allocator.free(child);
        const child_real = std.Io.Dir.cwd().realPathFileAlloc(
            defaultIo(),
            child,
            allocator,
        ) catch return error.AllowedPathScanFailed;
        defer allocator.free(child_real);
        const child_stat = std.Io.Dir.cwd().statFile(
            defaultIo(),
            child_real,
            .{ .follow_symlinks = false },
        ) catch return error.AllowedPathScanFailed;
        if (entry.kind == .sym_link and child_stat.kind == .directory) {
            return .directory_symlink;
        }
        const file_identity = if (child_stat.kind == .file)
            try fileIdentityForPath(child_real)
        else
            null;
        const identity = PhysicalPathIdentity{
            .real_path = child_real,
            .stat = child_stat,
            .file_identity = file_identity,
        };
        if (identityAliasesAny(&identity, controls)) return .alias;
    }
    return .clear;
}

fn validateOperationPaths(allowed_paths: []const []const u8, paths: []const []const u8) !void {
    if (paths.len == 0) return error.PathsMissing;
    for (paths, 0..) |path, index| {
        try validateRepoPath(path);
        var allowed = false;
        for (allowed_paths) |root| {
            if (pathWithin(path, root)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return error.PathOutsideScope;
        for (paths[0..index]) |prior| {
            if (std.mem.eql(u8, path, prior)) return error.DuplicatePath;
            if (pathWithin(path, prior) or pathWithin(prior, path)) return error.OverlappingPath;
        }
    }
}

fn validateObligations(obligations: []const ObligationInput) !void {
    if (obligations.len == 0) return error.ObligationsMissing;
    for (obligations, 0..) |obligation, index| {
        try validateToken("obligation_id", obligation.id);
        if (ObligationKind.parse(obligation.kind) == null) return error.InvalidObligationKind;
        try validateNonEmpty("obligation_statement", obligation.statement);
        if (obligation.verifier.len == 0) return error.VerifierMissing;
        for (obligation.verifier) |arg| try validateNonEmpty("verifier_arg", arg);
        for (obligations[0..index]) |prior| {
            if (std.mem.eql(u8, obligation.id, prior.id)) return error.DuplicateObligation;
        }
    }
}

fn validateRepoPath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidRepoPath;
    if (path[0] == ':' or std.mem.indexOfScalar(u8, path, '\\') != null) {
        return error.InvalidRepoPath;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        const invalid_component = component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..");
        if (invalid_component) {
            return error.InvalidRepoPath;
        }
    }
    if (pathWithin(path, ".git") or pathWithin(path, ".ledger/actuation")) {
        return error.ReservedRepoPath;
    }
}

fn validateToken(_: []const u8, value: []const u8) !void {
    if (value.len == 0 or value.len > 160) return error.InvalidToken;
    for (value) |byte| {
        const valid = std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '_' or byte == '.' or
            byte == ':' or byte == '/';
        if (!valid) {
            return error.InvalidToken;
        }
    }
}

fn validateNonEmpty(_: []const u8, value: []const u8) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.EmptyField;
}

fn validateDigest(value: []const u8) !void {
    if (value.len != 71 or !std.mem.startsWith(u8, value, "sha256:")) return error.InvalidDigest;
    for (value[7..]) |byte| if (!std.ascii.isHex(byte)) return error.InvalidDigest;
}

fn validateContext(
    allocator: std.mem.Allocator,
    state: *const RunState,
    repo: []const u8,
    store_path: []const u8,
) !void {
    if (!std.mem.eql(u8, state.repo, repo) or !std.mem.eql(u8, state.store_path, store_path)) {
        return error.RunContextMismatch;
    }
    try validateActuationStorePath(allocator, repo, store_path);
    try validateAllowedPathsAgainstStore(
        allocator,
        repo,
        store_path,
        stringSlice(state.allowed_paths),
    );
}

fn validateWritableGeneration(state: *const RunState) !void {
    if (state.admission == null or state.generation_id == null) return error.LegacyRunReadOnly;
}

fn commonVerifierForRefs(state: *RunState, refs: []const []const u8) ![][]u8 {
    if (refs.len == 0) return error.ObligationRefsMissing;
    var verifier: ?[][]u8 = null;
    for (refs, 0..) |ref, index| {
        try validateToken("obligation_ref", ref);
        for (refs[0..index]) |prior| {
            if (std.mem.eql(u8, prior, ref)) return error.DuplicateObligationRef;
        }
        const obligation = findObligation(state, ref) orelse return error.UnknownObligation;
        if (obligation.discharged_by != null) return error.ObligationAlreadyDischarged;
        if (verifier) |expected| {
            if (!equalStringLists(
                stringSlice(expected),
                stringSlice(obligation.verifier),
            )) return error.MixedVerifiers;
        } else {
            verifier = obligation.verifier;
        }
    }
    return verifier.?;
}

fn validateReviewWorkOperation(
    allocator: std.mem.Allocator,
    state: *const RunState,
    effect: Effect,
    owner_boundary: []const u8,
    paths: []const []const u8,
    verifier: []const []const u8,
) !void {
    if (effect != .edit) return;
    const node = state.review_work_node orelse return;
    if (!std.mem.eql(u8, owner_boundary, node.owner_boundary)) {
        return error.ReviewWorkOwnerMismatch;
    }
    if (!equalStringLists(verifier, stringSlice(node.verifier))) {
        return error.ReviewWorkVerifierMismatch;
    }
    if (!try equalCanonicalStringSets(
        allocator,
        paths,
        stringSlice(node.paths),
    )) {
        return error.ReviewWorkPathsMismatch;
    }
}

fn findObligation(state: *RunState, id: []const u8) ?*ObligationState {
    for (state.obligations) |*obligation| {
        if (std.mem.eql(u8, obligation.id, id)) return obligation;
    }
    return null;
}

fn outstandingObligationCount(state: *const RunState) usize {
    var count: usize = 0;
    for (state.obligations) |obligation| if (obligation.discharged_by == null) {
        count += 1;
    };
    return count;
}

fn validateCapability(
    allocator: std.mem.Allocator,
    expected_digest: []const u8,
    raw_capability: []const u8,
) !void {
    const actual = try digestTextAlloc(allocator, raw_capability);
    defer allocator.free(actual);
    if (!std.crypto.timing_safe.eql(
        [71]u8,
        actual[0..71].*,
        expected_digest[0..71].*,
    )) return error.CapabilityMismatch;
}

fn randomCapabilityAlloc(allocator: std.mem.Allocator) ![]u8 {
    var random: [32]u8 = undefined;
    try std.Io.randomSecure(defaultIo(), &random);
    const hex = std.fmt.bytesToHex(random, .lower);
    return std.fmt.allocPrint(allocator, "AKC1-{s}", .{hex});
}

fn repositoryArtifactDigestAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    allowed_paths: []const []const u8,
) ![]u8 {
    const control_excludes = try controlExcludesAlloc(allocator, repo, store_path);
    defer freeStringList(allocator, control_excludes);
    const excludes = stringSlice(control_excludes);
    const workspace = try workspaceDigestAlloc(allocator, repo, excludes);
    defer allocator.free(workspace);
    const head_raw = try runGitRawAlloc(allocator, repo, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const branch_raw = try runGitRawAlloc(allocator, repo, &.{ "branch", "--show-current" });
    defer allocator.free(branch_raw);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "head", head_raw);
    hashTagged(&hasher, "branch", branch_raw);
    hashTagged(&hasher, "workspace", workspace);
    const ordered_paths = try canonicalStringOrderAlloc(allocator, allowed_paths);
    defer allocator.free(ordered_paths);
    for (ordered_paths) |path| {
        const path_digest = try pathStateDigestAlloc(allocator, repo, path, excludes);
        defer allocator.free(path_digest);
        hashTagged(&hasher, path, path_digest);
    }
    return finishDigestAlloc(allocator, &hasher);
}

fn unscopedDigestAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    operation_paths: []const []const u8,
    allowed_paths: []const []const u8,
) ![]u8 {
    var excludes: std.ArrayList([]const u8) = .empty;
    defer excludes.deinit(allocator);
    try excludes.appendSlice(allocator, operation_paths);
    const control_excludes = try controlExcludesAlloc(allocator, repo, store_path);
    defer freeStringList(allocator, control_excludes);
    try excludes.appendSlice(allocator, stringSlice(control_excludes));
    const workspace = try workspaceDigestAlloc(allocator, repo, excludes.items);
    defer allocator.free(workspace);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "workspace", workspace);
    const ordered_paths = try canonicalStringOrderAlloc(allocator, allowed_paths);
    defer allocator.free(ordered_paths);
    for (ordered_paths) |path| {
        if (pathOverlapsAny(path, operation_paths)) continue;
        const path_digest = try pathStateDigestAlloc(
            allocator,
            repo,
            path,
            stringSlice(control_excludes),
        );
        defer allocator.free(path_digest);
        hashTagged(&hasher, path, path_digest);
    }
    return finishDigestAlloc(allocator, &hasher);
}

fn workspaceDigestAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    excludes: []const []const u8,
) ![]u8 {
    var diff_args: std.ArrayList([]const u8) = .empty;
    defer diff_args.deinit(allocator);
    var owned_pathspecs: std.ArrayList([]u8) = .empty;
    defer freeOwnedArrayList(allocator, &owned_pathspecs);
    try diff_args.appendSlice(
        allocator,
        &.{ "diff", "--binary", "--full-index", "HEAD", "--", "." },
    );
    for (excludes) |path| {
        const pathspec = try std.fmt.allocPrint(allocator, ":(exclude,literal){s}", .{path});
        try owned_pathspecs.append(allocator, pathspec);
        try diff_args.append(allocator, pathspec);
    }
    const diff = try runGitRawAlloc(allocator, repo, diff_args.items);
    defer allocator.free(diff);
    const tree = try runGitRawAlloc(allocator, repo, &.{ "ls-tree", "-r", "-z", "HEAD" });
    defer allocator.free(tree);
    const index = try runGitRawAlloc(allocator, repo, &.{ "ls-files", "--stage", "-z" });
    defer allocator.free(index);
    const untracked = try runGitRawAlloc(
        allocator,
        repo,
        &.{ "ls-files", "--others", "--exclude-standard", "-z" },
    );
    defer allocator.free(untracked);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "diff", diff);
    hashFilteredNulRecords(&hasher, "tree", tree, excludes, true);
    hashFilteredNulRecords(&hasher, "index", index, excludes, true);
    var records = std.mem.splitScalar(u8, untracked, 0);
    while (records.next()) |path| {
        if (path.len == 0 or pathCoveredByAny(path, excludes)) continue;
        const digest = try exactPathDigestAlloc(allocator, repo, path);
        defer allocator.free(digest);
        hashTagged(&hasher, path, digest);
    }
    return finishDigestAlloc(allocator, &hasher);
}

fn reviewArtifactStateDigestAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    policy_ref: []const u8,
    resolution_ref: []const u8,
) ![]u8 {
    const control_excludes = try controlExcludesAlloc(allocator, repo, store_path);
    defer freeStringList(allocator, control_excludes);
    var excludes: std.ArrayList([]const u8) = .empty;
    defer excludes.deinit(allocator);
    try excludes.appendSlice(allocator, stringSlice(control_excludes));
    try excludes.append(allocator, policy_ref);
    try excludes.append(allocator, resolution_ref);
    return workspaceDigestAlloc(allocator, repo, excludes.items);
}

fn pathStateDigestAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    path: []const u8,
    excludes: []const []const u8,
) ![]u8 {
    var owned_pathspecs: std.ArrayList([]u8) = .empty;
    defer freeOwnedArrayList(allocator, &owned_pathspecs);
    for (excludes) |excluded| {
        try owned_pathspecs.append(
            allocator,
            try std.fmt.allocPrint(allocator, ":(exclude,literal){s}", .{excluded}),
        );
    }
    const tree = try runGitRawAlloc(
        allocator,
        repo,
        &.{ "ls-tree", "-r", "-z", "HEAD", "--", path },
    );
    defer allocator.free(tree);
    var index_args: std.ArrayList([]const u8) = .empty;
    defer index_args.deinit(allocator);
    try index_args.appendSlice(allocator, &.{ "ls-files", "--stage", "-z", "--", path });
    for (owned_pathspecs.items) |pathspec| try index_args.append(allocator, pathspec);
    const index = try runGitRawAlloc(allocator, repo, index_args.items);
    defer allocator.free(index);
    var diff_args: std.ArrayList([]const u8) = .empty;
    defer diff_args.deinit(allocator);
    try diff_args.appendSlice(
        allocator,
        &.{ "diff", "--binary", "--full-index", "HEAD", "--", path },
    );
    for (owned_pathspecs.items) |pathspec| try diff_args.append(allocator, pathspec);
    const diff = try runGitRawAlloc(allocator, repo, diff_args.items);
    defer allocator.free(diff);
    var untracked_args: std.ArrayList([]const u8) = .empty;
    defer untracked_args.deinit(allocator);
    try untracked_args.appendSlice(
        allocator,
        &.{ "ls-files", "--others", "--exclude-standard", "-z", "--", path },
    );
    for (owned_pathspecs.items) |pathspec| try untracked_args.append(allocator, pathspec);
    const untracked = try runGitRawAlloc(allocator, repo, untracked_args.items);
    defer allocator.free(untracked);
    const exact = exactPathDigestAlloc(allocator, repo, path) catch
        try allocator.dupe(u8, "not-a-regular-file");
    defer allocator.free(exact);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashFilteredNulRecords(&hasher, "tree", tree, excludes, true);
    hashFilteredNulRecords(&hasher, "index", index, excludes, true);
    hashTagged(&hasher, "diff", diff);
    hashTagged(&hasher, "exact", exact);
    var records = std.mem.splitScalar(u8, untracked, 0);
    while (records.next()) |child| {
        if (child.len == 0) continue;
        const digest = try exactPathDigestAlloc(allocator, repo, child);
        defer allocator.free(digest);
        hashTagged(&hasher, child, digest);
    }
    return finishDigestAlloc(allocator, &hasher);
}

fn exactPathDigestAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    path: []const u8,
) ![]u8 {
    const raw = try runGitRawAlloc(
        allocator,
        repo,
        &.{ "hash-object", "--no-filters", "--", path },
    );
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.PathUnreadable;
    return digestTextAlloc(allocator, trimmed);
}

fn snapshotPathStatesAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    paths: []const []const u8,
) ![]PathState {
    const excludes = try controlExcludesAlloc(allocator, repo, store_path);
    defer freeStringList(allocator, excludes);
    const states = try allocator.alloc(PathState, paths.len);
    var initialized: usize = 0;
    errdefer {
        for (states[0..initialized]) |*state| state.deinit(allocator);
        allocator.free(states);
    }
    for (paths, 0..) |path, index| {
        states[index] = .{
            .path = try allocator.dupe(u8, path),
            .digest = try pathStateDigestAlloc(allocator, repo, path, stringSlice(excludes)),
        };
        initialized += 1;
    }
    return states;
}

fn controlExcludesAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
) ![][]u8 {
    const store_relative = try storeRelativeAlloc(allocator, repo, store_path);
    defer if (store_relative) |value| allocator.free(value);
    const custom_relative = if (store_relative) |value| !pathWithin(value, ControlRoot) else false;
    const count: usize = 1 + SourceMemoryControlPaths.len +
        (if (custom_relative) @as(usize, 2) else 0);
    const excludes = try allocator.alloc([]u8, count);
    var initialized: usize = 0;
    errdefer {
        for (excludes[0..initialized]) |value| allocator.free(value);
        allocator.free(excludes);
    }
    excludes[0] = try allocator.dupe(u8, ControlRoot);
    initialized = 1;
    for (SourceMemoryControlPaths) |path| {
        excludes[initialized] = try allocator.dupe(u8, path);
        initialized += 1;
    }
    if (custom_relative) {
        excludes[initialized] = try allocator.dupe(u8, store_relative.?);
        initialized += 1;
        excludes[initialized] = try std.fmt.allocPrint(
            allocator,
            "{s}.lock",
            .{store_relative.?},
        );
        initialized += 1;
    }
    return excludes;
}

fn pathStateWiresAlloc(allocator: std.mem.Allocator, states: []const PathState) ![]PathStateWire {
    const wires = try allocator.alloc(PathStateWire, states.len);
    for (states, 0..) |state, index| wires[index] = .{ .path = state.path, .digest = state.digest };
    return wires;
}

fn allPathStatesChanged(before: []const PathState, after: []const PathState) bool {
    if (before.len != after.len) return false;
    for (before, after) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path) or
            std.mem.eql(u8, left.digest, right.digest)) return false;
    }
    return true;
}

fn hashFilteredNulRecords(
    hasher: *std.crypto.hash.sha2.Sha256,
    tag: []const u8,
    raw: []const u8,
    excludes: []const []const u8,
    path_after_tab: bool,
) void {
    var records = std.mem.splitScalar(u8, raw, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const path = if (path_after_tab)
            record[(std.mem.indexOfScalar(u8, record, '\t') orelse continue) + 1 ..]
        else
            record;
        if (pathCoveredByAny(path, excludes)) continue;
        hashTagged(hasher, tag, record);
    }
}

fn pathCoveredByAny(path: []const u8, roots: []const []const u8) bool {
    for (roots) |root| if (pathWithin(path, root)) return true;
    return false;
}

fn pathOverlapsAny(path: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (pathWithin(path, candidate) or pathWithin(candidate, path)) return true;
    }
    return false;
}

fn pathWithin(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

fn storeRelativeAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
) !?[]u8 {
    const normalized_repo = try std.fs.path.resolve(allocator, &.{repo});
    defer allocator.free(normalized_repo);
    const normalized_store = try std.fs.path.resolve(allocator, &.{store_path});
    defer allocator.free(normalized_store);
    if (!std.mem.startsWith(u8, normalized_store, normalized_repo)) return null;
    if (normalized_store.len == normalized_repo.len) return null;
    if (normalized_store[normalized_repo.len] != '/') return null;
    return try allocator.dupe(u8, normalized_store[normalized_repo.len + 1 ..]);
}

fn discoverRepoRootAlloc(allocator: std.mem.Allocator, raw_repo: []const u8) ![]u8 {
    const result = try std.process.run(allocator, defaultIo(), .{
        .argv = &.{ "git", "-C", raw_repo, "rev-parse", "--show-toplevel" },
        .stderr_limit = .limited(MaxProcessOutputBytes),
        .stdout_limit = .limited(MaxProcessOutputBytes),
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (exitCode(result.term) != 0) return error.NotGitRepository;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.NotGitRepository;
    return allocator.dupe(u8, trimmed);
}

fn runGitRawAlloc(allocator: std.mem.Allocator, repo: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);
    const result = try std.process.run(allocator, defaultIo(), .{
        .argv = argv.items,
        .cwd = .{ .path = repo },
        .stderr_limit = .limited(MaxProcessOutputBytes),
        .stdout_limit = .limited(MaxProcessOutputBytes),
    });
    defer allocator.free(result.stderr);
    if (exitCode(result.term) != 0) {
        allocator.free(result.stdout);
        return error.GitCommandFailed;
    }
    defer allocator.free(result.stdout);
    return allocator.dupe(u8, result.stdout);
}

fn runProcessAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    argv: []const []const u8,
) !ProcessResult {
    if (argv.len == 0) return error.VerifierMissing;
    const result = try std.process.run(allocator, defaultIo(), .{
        .argv = argv,
        .cwd = .{ .path = repo },
        .stderr_limit = .limited(MaxProcessOutputBytes),
        .stdout_limit = .limited(MaxProcessOutputBytes),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const stdout = try allocator.dupe(u8, result.stdout);
    errdefer allocator.free(stdout);
    return .{
        .exit_code = exitCode(result.term),
        .stdout = stdout,
        .stderr = try allocator.dupe(u8, result.stderr),
    };
}

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        else => 255,
    };
}

fn resolveStorePathAlloc(
    allocator: std.mem.Allocator,
    repo: []const u8,
    raw_path: []const u8,
) ![]u8 {
    return if (std.fs.path.isAbsolute(raw_path))
        std.fs.path.resolve(allocator, &.{raw_path})
    else
        std.fs.path.resolve(allocator, &.{ repo, raw_path });
}

fn readInputAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var reader = std.Io.File.stdin().reader(defaultIo(), &.{});
        return reader.interface.allocRemaining(allocator, .limited(MaxInputBytes));
    }
    return std.Io.Dir.cwd().readFileAlloc(defaultIo(), path, allocator, .limited(MaxInputBytes));
}

fn eventDigestAlloc(
    allocator: std.mem.Allocator,
    sequence: u64,
    previous_digest: []const u8,
    run_id: []const u8,
    kind: []const u8,
    recorded_at_unix: i64,
    body_digest: []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashTagged(&hasher, "schema", "actuation-event/v1");
    var number_buffer: [64]u8 = undefined;
    const sequence_text = try std.fmt.bufPrint(&number_buffer, "{d}", .{sequence});
    hashTagged(&hasher, "sequence", sequence_text);
    hashTagged(&hasher, "previous", previous_digest);
    hashTagged(&hasher, "run", run_id);
    hashTagged(&hasher, "kind", kind);
    const time_text = try std.fmt.bufPrint(&number_buffer, "{d}", .{recorded_at_unix});
    hashTagged(&hasher, "time", time_text);
    hashTagged(&hasher, "body", body_digest);
    return finishDigestAlloc(allocator, &hasher);
}

fn digestTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(text);
    return finishDigestAlloc(allocator, &hasher);
}

fn hashTagged(hasher: *std.crypto.hash.sha2.Sha256, tag: []const u8, value: []const u8) void {
    hasher.update(tag);
    hasher.update(&.{0});
    hasher.update(value);
    hasher.update(&.{0xff});
}

fn finishDigestAlloc(allocator: std.mem.Allocator, hasher: *std.crypto.hash.sha2.Sha256) ![]u8 {
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

fn encodeBodyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn encodeDynamicBodyAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn printTransitionResult(
    allocator: std.mem.Allocator,
    command: Command,
    _: ?[]const u8,
    result: TransitionResult,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"actuation-transition-result/v1\",\"command\":");
    try std.json.Stringify.value(@tagName(command), .{}, &out.writer);
    try out.writer.writeAll(",\"run_id\":");
    try std.json.Stringify.value(result.run_id, .{}, &out.writer);
    try out.writer.writeAll(",\"goal_id\":");
    if (result.goal_id) |goal_id| {
        try std.json.Stringify.value(goal_id, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"event_digest\":");
    try std.json.Stringify.value(result.event_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"artifact_digest\":");
    try std.json.Stringify.value(result.artifact_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"generation_id\":");
    if (result.generation_id) |generation_id| {
        try std.json.Stringify.value(generation_id, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"generation_kind\":");
    if (result.generation_kind) |kind| {
        try std.json.Stringify.value(kind.name(), .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"predecessor_generation_id\":");
    if (result.predecessor_generation_id) |generation_id| {
        try std.json.Stringify.value(generation_id, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"reserved_successor_generation_id\":");
    if (result.reserved_successor_generation_id) |generation_id| {
        try std.json.Stringify.value(generation_id, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"capability\":");
    if (result.capability) |capability| {
        try std.json.Stringify.value(capability, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"passed\":");
    if (result.passed) |passed| {
        try out.writer.writeAll(if (passed) "true" else "false");
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"exit_code\":");
    if (result.exit_code) |code| {
        try out.writer.print("{d}", .{code});
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn printState(allocator: std.mem.Allocator, state: *const RunState, event_count: u64) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"schema\":\"actuation-kernel-state/v2\",\"run_id\":");
    try std.json.Stringify.value(state.run_id, .{}, &out.writer);
    try out.writer.writeAll(",\"generation_id\":");
    if (state.generation_id) |generation_id| {
        try std.json.Stringify.value(generation_id, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"generation_kind\":");
    try std.json.Stringify.value(
        if (state.admission) |admission| admission.kind.name() else "legacy-v1",
        .{},
        &out.writer,
    );
    try out.writer.writeAll(",\"predecessor_run_id\":");
    if (state.admission) |admission| {
        if (admission.predecessor_run_id) |predecessor_run_id| {
            try std.json.Stringify.value(predecessor_run_id, .{}, &out.writer);
        } else {
            try out.writer.writeAll("null");
        }
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"predecessor_generation_id\":");
    if (state.predecessor_generation_id) |generation_id| {
        try std.json.Stringify.value(generation_id, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"reserved_successor_generation_id\":");
    if (state.reserved_successor_generation_id) |generation_id| {
        try std.json.Stringify.value(generation_id, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"goal_id\":");
    try std.json.Stringify.value(state.goal_id, .{}, &out.writer);
    try out.writer.writeAll(",\"goal_contract_digest\":");
    try std.json.Stringify.value(state.goal_contract_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"resolution_digest\":");
    if (state.resolution_digest) |digest| {
        try std.json.Stringify.value(digest, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"repo\":");
    try std.json.Stringify.value(state.repo, .{}, &out.writer);
    try out.writer.writeAll(",\"mutation_allowed\":");
    try out.writer.writeAll(if (state.mutation_allowed) "true" else "false");
    try out.writer.writeAll(",\"completion\":");
    try std.json.Stringify.value(state.completion.name(), .{}, &out.writer);
    try out.writer.writeAll(",\"phase\":");
    try std.json.Stringify.value(state.phase.name(), .{}, &out.writer);
    try out.writer.writeAll(",\"artifact_digest\":");
    try std.json.Stringify.value(state.artifact_digest, .{}, &out.writer);
    try out.writer.writeAll(",\"event_count\":");
    try out.writer.print("{d}", .{event_count});
    try out.writer.writeAll(",\"outstanding_obligations\":[");
    var outstanding_index: usize = 0;
    for (state.obligations) |obligation| {
        if (obligation.discharged_by != null) continue;
        if (outstanding_index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(obligation.id, .{}, &out.writer);
        outstanding_index += 1;
    }
    try out.writer.writeAll("],\"discharged_obligations\":[");
    var discharged_index: usize = 0;
    for (state.obligations) |obligation| {
        if (obligation.discharged_by == null) continue;
        if (discharged_index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"id\":");
        try std.json.Stringify.value(obligation.id, .{}, &out.writer);
        try out.writer.writeAll(",\"step_id\":");
        try std.json.Stringify.value(obligation.discharged_by.?, .{}, &out.writer);
        try out.writer.writeByte('}');
        discharged_index += 1;
    }
    try out.writer.writeAll("],\"pending_step\":");
    if (state.pending) |pending| {
        try out.writer.writeAll("{\"step_id\":");
        try std.json.Stringify.value(pending.step_id, .{}, &out.writer);
        try out.writer.writeAll(",\"effect\":");
        try std.json.Stringify.value(pending.effect.name(), .{}, &out.writer);
        try out.writer.writeAll(",\"idempotency_key\":");
        try std.json.Stringify.value(pending.idempotency_key, .{}, &out.writer);
        try out.writer.writeAll(",\"owner_boundary\":");
        try std.json.Stringify.value(pending.owner_boundary, .{}, &out.writer);
        try out.writer.writeAll(",\"paths\":");
        try std.json.Stringify.value(stringSlice(pending.paths), .{}, &out.writer);
        try out.writer.writeAll(",\"obligation_refs\":");
        try std.json.Stringify.value(stringSlice(pending.obligation_refs), .{}, &out.writer);
        try out.writer.writeAll(",\"verifier\":");
        try std.json.Stringify.value(stringSlice(pending.verifier), .{}, &out.writer);
        try out.writer.writeAll(",\"capability_digest\":");
        try std.json.Stringify.value(pending.capability_digest, .{}, &out.writer);
        try out.writer.writeAll(",\"artifact_before\":");
        try std.json.Stringify.value(pending.artifact_before, .{}, &out.writer);
        try out.writer.writeAll(",\"artifact_after\":");
        if (pending.artifact_after) |digest| {
            try std.json.Stringify.value(digest, .{}, &out.writer);
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeByte('}');
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"next_transition\":");
    try std.json.Stringify.value(nextTransition(state), .{}, &out.writer);
    try out.writer.writeAll("}\n");
    try writeStdoutAlloc(allocator, &out);
}

fn nextTransition(state: *const RunState) []const u8 {
    return switch (state.phase) {
        .closed, .superseded => "terminal",
        .effect_recorded => "observe",
        .prepared => if (state.pending.?.effect == .edit) "record" else "execute",
        .ready => if (outstandingObligationCount(state) == 0) "close" else "prepare",
    };
}

fn writeStdoutAlloc(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) !void {
    const bytes = try out.toOwnedSlice();
    defer allocator.free(bytes);
    var stdout_writer = std.Io.File.stdout().writer(defaultIo(), &.{});
    try stdout_writer.interface.writeAll(bytes);
}

fn dupeStringList(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |value| allocator.free(value);
        allocator.free(out);
    }
    for (values, 0..) |value, index| {
        out[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return out;
}

fn freeStringList(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freeOwnedArrayList(allocator: std.mem.Allocator, values: *std.ArrayList([]u8)) void {
    for (values.items) |value| allocator.free(value);
    values.deinit(allocator);
}

fn freePathStates(allocator: std.mem.Allocator, states: []PathState) void {
    for (states) |*state| state.deinit(allocator);
    allocator.free(states);
}

fn containsString(values: []const []u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn equalStringLists(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

fn stringSlice(values: []const []u8) []const []const u8 {
    return @as([*]const []const u8, @ptrCast(values.ptr))[0..values.len];
}

const TestRepo = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    store: []u8,
    target: []u8,
    other: []u8,
};

fn setupTestRepo(allocator: std.mem.Allocator) !TestRepo {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const root_z = try tmp.dir.realPathFileAlloc(defaultIo(), ".", allocator);
    defer allocator.free(root_z);
    const root = try allocator.dupe(u8, root_z);
    errdefer allocator.free(root);
    const store = try std.fs.path.join(allocator, &.{ root, DefaultStorePath });
    errdefer allocator.free(store);
    const target = try std.fs.path.join(allocator, &.{ root, "target.txt" });
    errdefer allocator.free(target);
    const other = try std.fs.path.join(allocator, &.{ root, "other.txt" });
    errdefer allocator.free(other);
    const gitignore = try std.fs.path.join(allocator, &.{ root, ".gitignore" });
    defer allocator.free(gitignore);
    const basis = try std.fs.path.join(allocator, &.{ root, "basis.txt" });
    defer allocator.free(basis);
    try durable_store.writeTextAtomic(allocator, gitignore, ".ledger/actuation/\n");
    try durable_store.writeTextAtomic(allocator, basis, "basis\n");
    try durable_store.writeTextAtomic(allocator, target, "before\n");
    try durable_store.writeTextAtomic(allocator, other, "stable\n");
    try runTestCommand(allocator, root, &.{ "git", "init", "--quiet" });
    try runTestCommand(
        allocator,
        root,
        &.{ "git", "config", "user.email", "actuation@example.invalid" },
    );
    try runTestCommand(allocator, root, &.{ "git", "config", "user.name", "Actuation Test" });
    try runTestCommand(
        allocator,
        root,
        &.{ "git", "add", ".gitignore", "basis.txt", "target.txt", "other.txt" },
    );
    try runTestCommand(allocator, root, &.{ "git", "commit", "--quiet", "-m", "fixture" });
    return .{ .tmp = tmp, .root = root, .store = store, .target = target, .other = other };
}

fn cleanupTestRepo(
    allocator: std.mem.Allocator,
    fixture: *TestRepo,
) void {
    allocator.free(fixture.other);
    allocator.free(fixture.target);
    allocator.free(fixture.store);
    allocator.free(fixture.root);
    fixture.tmp.cleanup();
}

fn appendReviewBoundTestRoot(
    allocator: std.mem.Allocator,
    fixture: *const TestRepo,
) !void {
    const policy_path = try std.fs.path.join(allocator, &.{ fixture.root, "policy.json" });
    defer allocator.free(policy_path);
    const resolution_path = try std.fs.path.join(
        allocator,
        &.{ fixture.root, "resolution.json" },
    );
    defer allocator.free(resolution_path);
    try durable_store.writeTextAtomic(allocator, policy_path, "policy\n");
    try durable_store.writeTextAtomic(allocator, resolution_path, "resolution\n");

    const digest_a =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const basis_digest =
        "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c";
    const allowed_paths = [_][]const u8{ "target.txt", "other.txt" };
    const obligations = [_]ObligationInput{.{
        .id = "obl-1",
        .kind = "review",
        .statement = "The selected repair is verified.",
        .verifier = &.{ "git", "diff", "--check" },
    }};
    const admission = GenerationAdmissionInput{
        .schema = "actuation-generation-admission/v1",
        .kind = "implementation",
        .basis = .{ .ref = "basis.txt", .digest = basis_digest },
        .review = .{
            .policy_ref = "policy.json",
            .policy_digest = digest_a,
            .resolution_ref = "resolution.json",
            .resolution_digest = digest_a,
        },
    };
    const node = ReviewWorkNodeInput{
        .node_id = "review-node-1",
        .run_id = "run-1",
        .owner_boundary = "fixture",
        .paths = &allowed_paths,
        .verifier = &.{ "git", "diff", "--check" },
    };
    const input = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = "run-1",
        .goal_id = "goal-1",
        .goal_contract_digest = digest_a,
        .resolution_digest = digest_a,
        .source_ref = "user:turn",
        .execution_authority_ref = "user:turn",
        .mutation_allowed = true,
        .completion = "complete",
        .allowed_paths = &allowed_paths,
        .obligations = &obligations,
        .generation_admission = admission,
    };
    const artifact = try repositoryArtifactDigestAlloc(
        allocator,
        fixture.root,
        fixture.store,
        &allowed_paths,
    );
    defer allocator.free(artifact);
    const stable_unscoped = try unscopedDigestAlloc(
        allocator,
        fixture.root,
        fixture.store,
        &allowed_paths,
        &allowed_paths,
    );
    defer allocator.free(stable_unscoped);
    const path_states = try snapshotPathStatesAlloc(
        allocator,
        fixture.root,
        fixture.store,
        &allowed_paths,
    );
    defer freePathStates(allocator, path_states);
    const path_wires = try pathStateWiresAlloc(allocator, path_states);
    defer allocator.free(path_wires);
    const generation_id = try generationIdAlloc(
        allocator,
        input,
        .implementation,
        .complete,
        artifact,
        null,
        node,
    );
    defer allocator.free(generation_id);
    const body = RunOpenedBodyV2{
        .generation_id = generation_id,
        .predecessor_generation_id = null,
        .generation_admission = admission,
        .review_work_node = node,
        .goal_id = input.goal_id,
        .goal_contract_digest = input.goal_contract_digest,
        .resolution_digest = input.resolution_digest,
        .source_ref = input.source_ref,
        .execution_authority_ref = input.execution_authority_ref,
        .mutation_allowed = input.mutation_allowed,
        .completion = input.completion,
        .repo = fixture.root,
        .store_path = fixture.store,
        .allowed_paths = &allowed_paths,
        .obligations = &obligations,
        .artifact_digest = artifact,
        .stable_unscoped_digest = stable_unscoped,
        .allowed_path_states = path_wires,
    };
    const body_json = try encodeBodyAlloc(allocator, body);
    defer allocator.free(body_json);
    var persistence = durable_store.PersistentEventStore.init(fixture.store);
    var exclusive = try acquireActuationExclusive(allocator, persistence.eventStore());
    defer exclusive.release();
    var empty = try loadLedgerExclusive(allocator, &exclusive, null);
    defer empty.deinit(allocator);
    const event_digest = try appendEventAlloc(
        allocator,
        &exclusive,
        empty,
        "run-1",
        "run_opened",
        body_json,
    );
    allocator.free(event_digest);
}

fn runTestCommand(allocator: std.mem.Allocator, repo: []const u8, argv: []const []const u8) !void {
    var result = try runProcessAlloc(allocator, repo, argv);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

const TestOpenSingle =
    \\{
    \\  "schema": "actuation-open/v2",
    \\  "run_id": "run-1",
    \\  "goal_id": "goal-1",
    \\  "goal_contract_digest":
    \\    "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    \\  "source_ref": "user:turn",
    \\  "execution_authority_ref": "user:turn",
    \\  "mutation_allowed": true,
    \\  "completion": "complete",
    \\  "allowed_paths": [
    \\    "target.txt"
    \\  ],
    \\  "obligations": [
    \\    {
    \\      "id": "obl-1",
    \\      "kind": "implementation",
    \\      "statement": "The diff remains whitespace-clean.",
    \\      "verifier": [
    \\        "git",
    \\        "diff",
    \\        "--check"
    \\      ]
    \\    }
    \\  ],
    \\  "generation_admission": {
    \\    "schema": "actuation-generation-admission/v1",
    \\    "kind": "implementation",
    \\    "predecessor_run_id": null,
    \\    "basis": {
    \\      "ref": "basis.txt",
    \\      "digest": "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c"
    \\    },
    \\    "review": {},
    \\    "recovery": {}
    \\  }
    \\}
;

const TestOpenTwoPaths =
    \\{
    \\  "schema": "actuation-open/v2",
    \\  "run_id": "run-1",
    \\  "goal_id": "goal-1",
    \\  "goal_contract_digest":
    \\    "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    \\  "source_ref": "user:turn",
    \\  "execution_authority_ref": "user:turn",
    \\  "mutation_allowed": true,
    \\  "completion": "complete",
    \\  "allowed_paths": [
    \\    "target.txt",
    \\    "other.txt"
    \\  ],
    \\  "obligations": [
    \\    {
    \\      "id": "obl-1",
    \\      "kind": "implementation",
    \\      "statement": "The diff remains whitespace-clean.",
    \\      "verifier": [
    \\        "git",
    \\        "diff",
    \\        "--check"
    \\      ]
    \\    }
    \\  ],
    \\  "generation_admission": {
    \\    "schema": "actuation-generation-admission/v1",
    \\    "kind": "implementation",
    \\    "predecessor_run_id": null,
    \\    "basis": {
    \\      "ref": "basis.txt",
    \\      "digest": "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c"
    \\    },
    \\    "review": {},
    \\    "recovery": {}
    \\  }
    \\}
;

const TestOpenTwoObligations =
    \\{
    \\  "schema": "actuation-open/v2",
    \\  "run_id": "run-1",
    \\  "goal_id": "goal-1",
    \\  "goal_contract_digest":
    \\    "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    \\  "source_ref": "user:turn",
    \\  "execution_authority_ref": "user:turn",
    \\  "mutation_allowed": true,
    \\  "completion": "ready-to-ship",
    \\  "allowed_paths": [
    \\    "target.txt"
    \\  ],
    \\  "obligations": [
    \\    {
    \\      "id": "obl-1",
    \\      "kind": "implementation",
    \\      "statement": "The first verifier passes.",
    \\      "verifier": [
    \\        "git",
    \\        "diff",
    \\        "--check"
    \\      ]
    \\    },
    \\    {
    \\      "id": "obl-2",
    \\      "kind": "ship",
    \\      "statement": "The second verifier passes.",
    \\      "verifier": [
    \\        "git",
    \\        "diff",
    \\        "--check"
    \\      ]
    \\    }
    \\  ],
    \\  "generation_admission": {
    \\    "schema": "actuation-generation-admission/v1",
    \\    "kind": "implementation",
    \\    "predecessor_run_id": null,
    \\    "basis": {
    \\      "ref": "basis.txt",
    \\      "digest": "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c"
    \\    },
    \\    "review": {},
    \\    "recovery": {}
    \\  }
    \\}
;

const TestOpenDirectory =
    \\{
    \\  "schema": "actuation-open/v2",
    \\  "run_id": "run-1",
    \\  "goal_id": "goal-1",
    \\  "goal_contract_digest":
    \\    "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    \\  "source_ref": "user:turn",
    \\  "execution_authority_ref": "user:turn",
    \\  "mutation_allowed": true,
    \\  "completion": "complete",
    \\  "allowed_paths": [
    \\    "scope"
    \\  ],
    \\  "obligations": [
    \\    {
    \\      "id": "obl-1",
    \\      "kind": "implementation",
    \\      "statement": "The diff remains whitespace-clean.",
    \\      "verifier": [
    \\        "git",
    \\        "diff",
    \\        "--check"
    \\      ]
    \\    }
    \\  ],
    \\  "generation_admission": {
    \\    "schema": "actuation-generation-admission/v1",
    \\    "kind": "implementation",
    \\    "predecessor_run_id": null,
    \\    "basis": {
    \\      "ref": "basis.txt",
    \\      "digest": "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c"
    \\    },
    \\    "review": {},
    \\    "recovery": {}
    \\  }
    \\}
;

const TestOpenMutatingVerifier =
    \\{
    \\  "schema": "actuation-open/v2",
    \\  "run_id": "run-1",
    \\  "goal_id": "goal-1",
    \\  "goal_contract_digest":
    \\    "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    \\  "source_ref": "user:turn",
    \\  "execution_authority_ref": "user:turn",
    \\  "mutation_allowed": true,
    \\  "completion": "complete",
    \\  "allowed_paths": [
    \\    "target.txt"
    \\  ],
    \\  "obligations": [
    \\    {
    \\      "id": "obl-1",
    \\      "kind": "implementation",
    \\      "statement": "The verifier is observational.",
    \\      "verifier": [
    \\        "sh",
    \\        "-c",
    \\        "printf 'mutated\\n' > other.txt; exit 1"
    \\      ]
    \\    }
    \\  ],
    \\  "generation_admission": {
    \\    "schema": "actuation-generation-admission/v1",
    \\    "kind": "implementation",
    \\    "predecessor_run_id": null,
    \\    "basis": {
    \\      "ref": "basis.txt",
    \\      "digest": "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c"
    \\    },
    \\    "review": {},
    \\    "recovery": {}
    \\  }
    \\}
;

const TestEditOperation =
    \\{
    \\  "schema": "actuation-operation/v1",
    \\  "step_id": "step-1",
    \\  "effect": "edit",
    \\  "idempotency_key": "run-1:step-1",
    \\  "owner_boundary": "fixture",
    \\  "paths": [
    \\    "target.txt"
    \\  ],
    \\  "obligation_refs": [
    \\    "obl-1"
    \\  ]
    \\}
;

const TestSupersede =
    \\{
    \\  "schema": "actuation-supersede/v1",
    \\  "basis": {
    \\    "ref": "basis.txt",
    \\    "digest": "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c"
    \\  },
    \\  "recovery": {
    \\    "authority_ref": "basis.txt",
    \\    "authority_digest":
    \\      "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c",
    \\    "reason": "capability-lost-after-change"
    \\  }
    \\}
;

const TestSupersedeExternal =
    \\{
    \\  "schema": "actuation-supersede/v1",
    \\  "basis": {
    \\    "ref": "basis.txt",
    \\    "digest": "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c"
    \\  },
    \\  "recovery": {
    \\    "authority_ref": "basis.txt",
    \\    "authority_digest":
    \\      "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c",
    \\    "reason": "artifact-stale"
    \\  },
    \\  "external_run_id": "run-2"
    \\}
;

const TestRecoveryOpen =
    \\{
    \\  "schema": "actuation-open/v2",
    \\  "run_id": "run-2",
    \\  "goal_id": "goal-1",
    \\  "goal_contract_digest":
    \\    "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    \\  "source_ref": "user:turn",
    \\  "execution_authority_ref": "user:turn",
    \\  "mutation_allowed": true,
    \\  "completion": "complete",
    \\  "allowed_paths": [
    \\    "target.txt"
    \\  ],
    \\  "obligations": [
    \\    {
    \\      "id": "obl-1",
    \\      "kind": "implementation",
    \\      "statement": "The diff remains whitespace-clean.",
    \\      "verifier": [
    \\        "git",
    \\        "diff",
    \\        "--check"
    \\      ]
    \\    }
    \\  ],
    \\  "generation_admission": {
    \\    "schema": "actuation-generation-admission/v1",
    \\    "kind": "recovery",
    \\    "predecessor_run_id": "run-1",
    \\    "basis": {
    \\      "ref": "basis.txt",
    \\      "digest": "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c"
    \\    },
    \\    "review": {},
    \\    "recovery": {
    \\      "authority_ref": "basis.txt",
    \\      "authority_digest":
    \\        "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c",
    \\      "reason": "capability-lost-after-change"
    \\    }
    \\  }
    \\}
;

test "generation identity ignores run labels and canonicalizes paths and obligations" {
    const first_obligations = [_]ObligationInput{
        .{
            .id = "b",
            .kind = "review",
            .statement = "B",
            .verifier = &.{ "zig", "build", "test-b" },
        },
        .{
            .id = "a",
            .kind = "implementation",
            .statement = "A",
            .verifier = &.{ "zig", "build", "test-a" },
        },
    };
    const second_obligations = [_]ObligationInput{ first_obligations[1], first_obligations[0] };
    const admission = GenerationAdmissionInput{
        .schema = "actuation-generation-admission/v1",
        .kind = "implementation",
        .basis = .{
            .ref = "basis.txt",
            .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
    };
    const first = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = "run-one",
        .goal_id = "goal-one",
        .goal_contract_digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .source_ref = "user:turn",
        .execution_authority_ref = "user:turn",
        .mutation_allowed = true,
        .completion = "complete",
        .allowed_paths = &.{ "z.txt", "a.txt" },
        .obligations = &first_obligations,
        .generation_admission = admission,
    };
    var second = first;
    second.run_id = "run-two";
    second.allowed_paths = &.{ "a.txt", "z.txt" };
    second.obligations = &second_obligations;
    const first_id = try generationIdAlloc(
        std.testing.allocator,
        first,
        .implementation,
        .complete,
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        null,
        null,
    );
    defer std.testing.allocator.free(first_id);
    const second_id = try generationIdAlloc(
        std.testing.allocator,
        second,
        .implementation,
        .complete,
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        null,
        null,
    );
    defer std.testing.allocator.free(second_id);
    try std.testing.expectEqualStrings(first_id, second_id);

    var different_basis_admission = admission;
    different_basis_admission.basis.ref = "same-bytes-different-authority.txt";
    var different_basis = second;
    different_basis.generation_admission = different_basis_admission;
    const different_basis_id = try generationIdAlloc(
        std.testing.allocator,
        different_basis,
        .implementation,
        .complete,
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        null,
        null,
    );
    defer std.testing.allocator.free(different_basis_id);
    try std.testing.expect(!std.mem.eql(u8, first_id, different_basis_id));
}

test "ordinary successor keeps goal identity while admitting a new GoalContract" {
    var index = [_]RunIndexEntry{.{
        .run_id = @constCast("run-root"),
        .goal_id = @constCast("goal-one"),
        .goal_contract_digest = @constCast(
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ),
        .generation_id = @constCast("generation-root"),
        .predecessor_run_id = null,
        .kind = .implementation,
        .phase = .closed,
        .mutation_allowed = true,
        .allowed_paths = @constCast(&[_][]u8{}),
        .artifact_digest = @constCast(
            "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" ++
                "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        ),
        .reserved_successor_generation_id = null,
        .recovery_contract_digest = @constCast(
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        ),
    }};
    const input = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = "run-repair",
        .goal_id = "goal-one",
        .goal_contract_digest = "sha256:cccccccccccccccccccccccccccccccc" ++
            "cccccccccccccccccccccccccccccccc",
        .resolution_digest = "sha256:dddddddddddddddddddddddddddddddd" ++
            "dddddddddddddddddddddddddddddddd",
        .source_ref = "user:turn",
        .execution_authority_ref = "user:turn",
        .mutation_allowed = true,
        .completion = "ready-to-ship",
        .allowed_paths = &.{"target.txt"},
        .obligations = &.{},
        .generation_admission = .{
            .schema = "actuation-generation-admission/v1",
            .kind = "review-repair",
            .predecessor_run_id = "run-root",
            .basis = .{
                .ref = "basis.txt",
                .digest = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            },
            .review = .{
                .policy_ref = "policy.json",
                .policy_digest = "sha256:ffffffffffffffffffffffffffffffff" ++
                    "ffffffffffffffffffffffffffffffff",
                .resolution_ref = "resolution.json",
                .resolution_digest = "sha256:dddddddddddddddddddddddddddddddd" ++
                    "dddddddddddddddddddddddddddddddd",
            },
        },
    };
    try validateOpenLineage(
        std.testing.allocator,
        input,
        .{ .completion = .ready_to_ship, .kind = .review_repair },
        "generation-repair",
        &index[0],
        &index,
        null,
    );
}

test "terminal proof live and replay scope equals predecessor delivery set" {
    var prior_paths = [_][]u8{ @constCast("target.txt"), @constCast("other.txt") };
    var prior_index = [_]RunIndexEntry{.{
        .run_id = @constCast("run-root"),
        .goal_id = @constCast("goal-one"),
        .goal_contract_digest = @constCast(
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ),
        .generation_id = @constCast(
            "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        ),
        .predecessor_run_id = null,
        .kind = .implementation,
        .phase = .closed,
        .mutation_allowed = true,
        .allowed_paths = &prior_paths,
        .artifact_digest = @constCast(
            "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        ),
        .reserved_successor_generation_id = null,
        .recovery_contract_digest = @constCast(
            "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        ),
    }};
    const digest_e =
        "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    const terminal = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = "run-terminal",
        .goal_id = "goal-one",
        .goal_contract_digest = digest_e,
        .resolution_digest = digest_e,
        .source_ref = "user:turn",
        .execution_authority_ref = "user:turn",
        .mutation_allowed = false,
        .completion = "complete",
        .allowed_paths = &.{"target.txt"},
        .obligations = &.{},
        .generation_admission = .{
            .schema = "actuation-generation-admission/v1",
            .kind = "terminal-proof",
            .predecessor_run_id = "run-root",
            .basis = .{ .ref = "basis.txt", .digest = digest_e },
            .review = .{
                .policy_ref = "policy.json",
                .policy_digest = digest_e,
                .resolution_ref = "resolution.json",
                .resolution_digest = digest_e,
            },
        },
    };
    try std.testing.expectError(
        error.TerminalProofScopeMismatch,
        validateOpenLineage(
            std.testing.allocator,
            terminal,
            .{ .completion = .complete, .kind = .terminal_proof },
            digest_e,
            &prior_index[0],
            &prior_index,
            null,
        ),
    );
    var broad_terminal = terminal;
    broad_terminal.allowed_paths = &.{ "target.txt", "other.txt", "third.txt" };
    try std.testing.expectError(
        error.TerminalProofScopeMismatch,
        validateOpenLineage(
            std.testing.allocator,
            broad_terminal,
            .{ .completion = .complete, .kind = .terminal_proof },
            digest_e,
            &prior_index[0],
            &prior_index,
            null,
        ),
    );
    var exact_terminal = terminal;
    exact_terminal.allowed_paths = &.{ "other.txt", "target.txt" };
    try validateOpenLineage(
        std.testing.allocator,
        exact_terminal,
        .{ .completion = .complete, .kind = .terminal_proof },
        digest_e,
        &prior_index[0],
        &prior_index,
        null,
    );

    var no_obligations = [_]ObligationState{};
    const predecessor = RunState{
        .run_id = @constCast("run-root"),
        .generation_id = prior_index[0].generation_id,
        .goal_id = prior_index[0].goal_id,
        .goal_contract_digest = prior_index[0].goal_contract_digest,
        .resolution_digest = null,
        .source_ref = @constCast("user:turn"),
        .execution_authority_ref = @constCast("user:turn"),
        .mutation_allowed = true,
        .completion = .complete,
        .repo = @constCast("/repo"),
        .store_path = @constCast("/repo/.ledger/actuation/events.jsonl"),
        .allowed_paths = &prior_paths,
        .obligations = &no_obligations,
        .artifact_digest = prior_index[0].artifact_digest,
        .phase = .closed,
    };
    var candidate_paths = [_][]u8{@constCast("target.txt")};
    var candidate = RunState{
        .run_id = @constCast("run-terminal"),
        .generation_id = @constCast(digest_e),
        .predecessor_generation_id = predecessor.generation_id,
        .admission = .{
            .kind = .terminal_proof,
            .predecessor_run_id = @constCast("run-root"),
            .basis_ref = @constCast("basis.txt"),
            .basis_digest = @constCast(digest_e),
            .review_policy_ref = @constCast("policy.json"),
            .review_policy_digest = @constCast(digest_e),
            .review_resolution_ref = @constCast("resolution.json"),
            .review_resolution_digest = @constCast(digest_e),
            .recovery_authority_ref = null,
            .recovery_authority_digest = null,
            .recovery_reason = null,
        },
        .goal_id = @constCast("goal-one"),
        .goal_contract_digest = @constCast(digest_e),
        .resolution_digest = @constCast(digest_e),
        .source_ref = @constCast("user:turn"),
        .execution_authority_ref = @constCast("user:turn"),
        .mutation_allowed = false,
        .completion = .complete,
        .repo = @constCast("/repo"),
        .store_path = @constCast("/repo/.ledger/actuation/events.jsonl"),
        .allowed_paths = &candidate_paths,
        .obligations = &no_obligations,
        .artifact_digest = @constCast(digest_e),
    };
    try std.testing.expectError(
        error.TerminalProofScopeMismatch,
        validateReplayedLineage(
            std.testing.allocator,
            &.{predecessor},
            &candidate,
        ),
    );
    var exact_candidate_paths = [_][]u8{ @constCast("other.txt"), @constCast("target.txt") };
    candidate.allowed_paths = &exact_candidate_paths;
    try validateReplayedLineage(
        std.testing.allocator,
        &.{predecessor},
        &candidate,
    );
}

test "edit capability is issued before effect, consumed once, observed, and closed" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);

    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestEditOperation,
    );
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expect(prepared.capability != null);

    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "after\n");
    var recorded = try cmdRecord(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        prepared.capability.?,
    );
    defer recorded.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidPhase,
        cmdRecord(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "run-1",
            prepared.capability.?,
        ),
    );

    var observed = try cmdObserve(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        "step-1",
    );
    defer observed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?bool, true), observed.passed);
    var closed = try cmdClose(std.testing.allocator, fixture.root, fixture.store, "run-1");
    defer closed.deinit(std.testing.allocator);

    var loaded = try loadLedger(std.testing.allocator, fixture.store, "run-1");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(Phase.closed, loaded.state.?.phase);
    try std.testing.expectEqual(@as(u64, 5), loaded.event_count);
    const decision = projectDecision(&loaded.state.?);
    try std.testing.expectEqualStrings("complete", decision.verdict);
    try std.testing.expectEqualStrings("complete", decision.goal_outcome);
    try std.testing.expectEqualStrings("none", decision.next_owner);
    try std.testing.expectEqualStrings("terminal", decision.next_transition);
}

test "new writes reject actuation-open v1 while replay retains legacy history" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const legacy_input = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestOpenSingle,
        "actuation-open/v2",
        "actuation-open/v1",
    );
    defer std.testing.allocator.free(legacy_input);
    try std.testing.expectError(
        error.InvalidInputSchema,
        cmdOpen(std.testing.allocator, fixture.root, fixture.store, legacy_input),
    );

    const artifact = try repositoryArtifactDigestAlloc(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        &.{"target.txt"},
    );
    defer std.testing.allocator.free(artifact);
    const verifier = [_][]const u8{ "git", "diff", "--check" };
    const obligations = [_]ObligationInput{.{
        .id = "legacy-obligation",
        .kind = "implementation",
        .statement = "Legacy proof remains replayable.",
        .verifier = &verifier,
    }};
    const body = RunOpenedBodyV1{
        .goal_id = "legacy-goal",
        .goal_contract_digest = "sha256:00000000000000000000000000000000" ++
            "00000000000000000000000000000000",
        .resolution_digest = null,
        .source_ref = "legacy:source",
        .execution_authority_ref = "legacy:authority",
        .mutation_allowed = true,
        .completion = "complete",
        .repo = fixture.root,
        .store_path = fixture.store,
        .allowed_paths = &.{"target.txt"},
        .obligations = &obligations,
        .artifact_digest = artifact,
    };
    const body_json = try encodeBodyAlloc(std.testing.allocator, body);
    defer std.testing.allocator.free(body_json);
    {
        var persistence = durable_store.PersistentEventStore.init(fixture.store);
        var exclusive = try acquireActuationExclusive(
            std.testing.allocator,
            persistence.eventStore(),
        );
        defer exclusive.release();
        var empty = try loadLedgerExclusive(std.testing.allocator, &exclusive, null);
        defer empty.deinit(std.testing.allocator);
        const event_digest = try appendEventAlloc(
            std.testing.allocator,
            &exclusive,
            empty,
            "legacy-run",
            "run_opened",
            body_json,
        );
        std.testing.allocator.free(event_digest);
    }

    var loaded = try loadLedger(std.testing.allocator, fixture.store, "legacy-run");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(loaded.state.?.generation_id == null);
    try std.testing.expect(loaded.state.?.admission == null);
    try std.testing.expectEqual(Phase.ready, loaded.state.?.phase);
    try std.testing.expectError(
        error.LegacyRunReadOnly,
        cmdPrepare(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "legacy-run",
            TestEditOperation,
        ),
    );
}

test "generation admission evidence cannot be inside mutation scope" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const mutable_basis = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestOpenSingle,
        "\"allowed_paths\": [\n    \"target.txt\"\n  ]",
        "\"allowed_paths\": [\n    \"basis.txt\"\n  ]",
    );
    defer std.testing.allocator.free(mutable_basis);
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        cmdOpen(std.testing.allocator, fixture.root, fixture.store, mutable_basis),
    );
}

test "replayed implementation root rejects a phantom predecessor generation" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var loaded = try loadLedger(std.testing.allocator, fixture.store, "run-1");
    defer loaded.deinit(std.testing.allocator);
    loaded.state.?.predecessor_generation_id = try std.testing.allocator.dupe(
        u8,
        "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    );
    try std.testing.expectError(
        error.ImplementationMustBeRoot,
        validateReplayedLineage(std.testing.allocator, &.{}, &loaded.state.?),
    );
}

test "review-selected mutation preserves exact selected owner paths and verifier" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var loaded = try loadLedger(std.testing.allocator, fixture.store, "run-1");
    defer loaded.deinit(std.testing.allocator);
    loaded.state.?.review_work_node = try reviewWorkNodeStateFromInput(
        std.testing.allocator,
        .{
            .node_id = "review-node-1",
            .run_id = "run-1",
            .owner_boundary = "fixture",
            .paths = &.{ "target.txt", "second.txt" },
            .verifier = &.{ "git", "diff", "--check" },
        },
    );
    try std.testing.expectError(
        error.ReviewWorkOwnerMismatch,
        validateReviewWorkOperation(
            std.testing.allocator,
            &loaded.state.?,
            .edit,
            "different-owner",
            &.{ "target.txt", "second.txt" },
            &.{ "git", "diff", "--check" },
        ),
    );
    try std.testing.expectError(
        error.ReviewWorkVerifierMismatch,
        validateReviewWorkOperation(
            std.testing.allocator,
            &loaded.state.?,
            .edit,
            "fixture",
            &.{ "target.txt", "second.txt" },
            &.{ "git", "status" },
        ),
    );
    try std.testing.expectError(
        error.ReviewWorkPathsMismatch,
        validateReviewWorkOperation(
            std.testing.allocator,
            &loaded.state.?,
            .edit,
            "fixture",
            &.{"target.txt"},
            &.{ "git", "diff", "--check" },
        ),
    );
    try std.testing.expectError(
        error.ReviewWorkPathsMismatch,
        validateReviewWorkOperation(
            std.testing.allocator,
            &loaded.state.?,
            .edit,
            "fixture",
            &.{ "target.txt", "second.txt", "third.txt" },
            &.{ "git", "diff", "--check" },
        ),
    );
    try validateReviewWorkOperation(
        std.testing.allocator,
        &loaded.state.?,
        .edit,
        "fixture",
        &.{ "second.txt", "target.txt" },
        &.{ "git", "diff", "--check" },
    );
    try validateReviewWorkOperation(
        std.testing.allocator,
        &loaded.state.?,
        .verify,
        "different-owner",
        &.{"unselected.txt"},
        &.{ "git", "status" },
    );
}

test "review admission joins one live policy resolution and work projection" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const policy_ref = "review-policy.json";
    const resolution_ref = "review-resolution.json";
    const state_fingerprint = try reviewArtifactStateDigestAlloc(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        policy_ref,
        resolution_ref,
    );
    defer std.testing.allocator.free(state_fingerprint);
    const head_raw = try runGitRawAlloc(
        std.testing.allocator,
        fixture.root,
        &.{ "rev-parse", "HEAD" },
    );
    defer std.testing.allocator.free(head_raw);
    const branch_raw = try runGitRawAlloc(
        std.testing.allocator,
        fixture.root,
        &.{ "branch", "--show-current" },
    );
    defer std.testing.allocator.free(branch_raw);
    const head = std.mem.trim(u8, head_raw, " \t\r\n");
    const branch = std.mem.trim(u8, branch_raw, " \t\r\n");
    const goal_contract_digest =
        "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    const review_contract_digest =
        "sha256:1111111111111111111111111111111111111111111111111111111111111111";
    const policy_envelope = ReviewPolicyAdmissionEnvelope{
        .actuation_review_policy = .{
            .version = "actuation-review-policy/v2",
            .policy_id = "policy-1",
            .run_id = "review-campaign-1",
            .goal_contract_digest = goal_contract_digest,
            .artifact = .{
                .repo = fixture.root,
                .base_ref = "HEAD",
                .base_sha = head,
                .head_sha = head,
                .state_fingerprint = state_fingerprint,
            },
            .review_contract_ref = "review-contract.json",
            .review_contract_digest = review_contract_digest,
        },
    };
    const policy_bytes = try encodeBodyAlloc(std.testing.allocator, policy_envelope);
    defer std.testing.allocator.free(policy_bytes);
    const policy_digest = try digestTextAlloc(std.testing.allocator, policy_bytes);
    defer std.testing.allocator.free(policy_digest);
    const resolution_envelope = ReviewResolutionAdmissionEnvelope{
        .review_resolution = .{
            .version = "review-resolution/v1",
            .resolution_id = "resolution-1",
            .run_id = "run-review",
            .artifact = .{
                .repo = fixture.root,
                .base_sha = head,
                .branch = branch,
                .head_sha = head,
                .state_fingerprint = state_fingerprint,
            },
            .review_folds = &.{.{ .goal_id = "goal-review" }},
            .review_profile = .{
                .policy_ref = policy_ref,
                .policy_digest = policy_digest,
                .review_contract_fingerprint = review_contract_digest,
            },
            .decisions = &.{.{ .selected_work_node = .{
                .node_id = "work-1",
                .run_id = "run-review",
                .owner_boundary = "fixture",
                .paths = &.{"target.txt"},
                .verifier = &.{ "git", "diff", "--check" },
            } }},
            .outcome = .{ .status = "pending" },
        },
    };
    const resolution_bytes = try encodeBodyAlloc(
        std.testing.allocator,
        resolution_envelope,
    );
    defer std.testing.allocator.free(resolution_bytes);
    const resolution_digest = try digestTextAlloc(std.testing.allocator, resolution_bytes);
    defer std.testing.allocator.free(resolution_digest);
    const input = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = "run-review",
        .goal_id = "goal-review",
        .goal_contract_digest = goal_contract_digest,
        .resolution_digest = resolution_digest,
        .source_ref = "user:turn",
        .execution_authority_ref = "user:turn",
        .mutation_allowed = true,
        .completion = "complete",
        .allowed_paths = &.{"target.txt"},
        .obligations = &.{.{
            .id = "obl-review",
            .kind = "review",
            .statement = "The selected repair is verified.",
            .verifier = &.{ "git", "diff", "--check" },
        }},
        .generation_admission = .{
            .schema = "actuation-generation-admission/v1",
            .kind = "implementation",
            .basis = .{ .ref = "basis.txt", .digest = goal_contract_digest },
            .review = .{
                .policy_ref = policy_ref,
                .policy_digest = policy_digest,
                .resolution_ref = resolution_ref,
                .resolution_digest = resolution_digest,
            },
        },
    };
    var selected = (try validateReviewEvidenceJoin(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        input,
        policy_bytes,
        resolution_bytes,
        true,
    )).?;
    defer selected.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("work-1", selected.node_id);
    try std.testing.expectEqualStrings("fixture", selected.owner_boundary);

    var mismatched = input;
    var mismatched_review = input.generation_admission.review;
    mismatched_review.policy_digest = goal_contract_digest;
    mismatched.generation_admission.review = mismatched_review;
    try std.testing.expectError(
        error.ReviewEvidenceJoinMismatch,
        validateReviewEvidenceJoin(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            mismatched,
            policy_bytes,
            resolution_bytes,
            true,
        ),
    );
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.other, "stale-review\n");
    try std.testing.expectError(
        error.ReviewArtifactStale,
        validateReviewEvidenceJoin(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            input,
            policy_bytes,
            resolution_bytes,
            true,
        ),
    );
}

test "abort requires an exact unchanged prepared snapshot and consumes operation identities" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestEditOperation,
    );
    defer prepared.deinit(std.testing.allocator);
    var aborted = try cmdAbort(std.testing.allocator, fixture.root, fixture.store, "run-1");
    defer aborted.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.DuplicateStepId,
        cmdPrepare(std.testing.allocator, fixture.root, fixture.store, "run-1", TestEditOperation),
    );
    var loaded = try loadLedger(std.testing.allocator, fixture.store, "run-1");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(Phase.ready, loaded.state.?.phase);
    try std.testing.expect(loaded.state.?.pending == null);
    try std.testing.expectEqual(@as(usize, 1), outstandingObligationCount(&loaded.state.?));
}

test "abort rejects any prepared artifact change" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestEditOperation,
    );
    defer prepared.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "changed\n");
    try std.testing.expectError(
        error.AbortArtifactChanged,
        cmdAbort(std.testing.allocator, fixture.root, fixture.store, "run-1"),
    );
}

test "supersession disables the old capability and admits one exact recovery successor" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestEditOperation,
    );
    defer prepared.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "changed\n");
    var superseded = try cmdSupersede(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestSupersede,
    );
    defer superseded.deinit(std.testing.allocator);
    try std.testing.expect(superseded.reserved_successor_generation_id != null);
    try std.testing.expectError(
        error.InvalidPhase,
        cmdRecord(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "run-1",
            prepared.capability.?,
        ),
    );

    var recovered = try cmdOpen(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        TestRecoveryOpen,
    );
    defer recovered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        superseded.reserved_successor_generation_id.?,
        recovered.generation_id.?,
    );
    var predecessor = try loadLedger(std.testing.allocator, fixture.store, "run-1");
    defer predecessor.deinit(std.testing.allocator);
    try std.testing.expectEqual(Phase.superseded, predecessor.state.?.phase);
    var successor = try loadLedger(std.testing.allocator, fixture.store, "run-2");
    defer successor.deinit(std.testing.allocator);
    try std.testing.expectEqual(Phase.ready, successor.state.?.phase);
    try std.testing.expectEqual(@as(usize, 1), outstandingObligationCount(&successor.state.?));

    const duplicate = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestRecoveryOpen,
        "\"run_id\": \"run-2\"",
        "\"run_id\": \"run-3\"",
    );
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(
        error.DuplicateGenerationId,
        cmdOpen(std.testing.allocator, fixture.root, fixture.store, duplicate),
    );
}

test "superseded review repair recovery preserves selected node authority" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    try appendReviewBoundTestRoot(std.testing.allocator, &fixture);

    try std.testing.expectError(
        error.ReviewWorkPathsMismatch,
        cmdPrepare(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "run-1",
            TestEditOperation,
        ),
    );
    const selected_operation = OperationInput{
        .schema = "actuation-operation/v1",
        .step_id = "review-step",
        .effect = "edit",
        .idempotency_key = "run-1:review-step",
        .owner_boundary = "fixture",
        .paths = &.{ "other.txt", "target.txt" },
        .obligation_refs = &.{"obl-1"},
    };
    const selected_json = try encodeBodyAlloc(std.testing.allocator, selected_operation);
    defer std.testing.allocator.free(selected_json);
    var prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        selected_json,
    );
    defer prepared.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "changed\n");
    var superseded = try cmdSupersede(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestSupersede,
    );
    defer superseded.deinit(std.testing.allocator);

    const recovery_obligations = [_]ObligationInput{.{
        .id = "obl-1",
        .kind = "review",
        .statement = "The selected repair is verified.",
        .verifier = &.{ "git", "diff", "--check" },
    }};
    const recovery_contract_digest =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const recovery_basis_digest =
        "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c";
    const recovery_input = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = "run-2",
        .goal_id = "goal-1",
        .goal_contract_digest = recovery_contract_digest,
        .resolution_digest = recovery_contract_digest,
        .source_ref = "user:turn",
        .execution_authority_ref = "user:turn",
        .mutation_allowed = true,
        .completion = "complete",
        .allowed_paths = &.{ "target.txt", "other.txt" },
        .obligations = &recovery_obligations,
        .generation_admission = .{
            .schema = "actuation-generation-admission/v1",
            .kind = "recovery",
            .predecessor_run_id = "run-1",
            .basis = .{
                .ref = "basis.txt",
                .digest = recovery_basis_digest,
            },
            .recovery = .{
                .authority_ref = "basis.txt",
                .authority_digest = recovery_basis_digest,
                .reason = "capability-lost-after-change",
            },
        },
    };
    const recovery_json = try encodeBodyAlloc(std.testing.allocator, recovery_input);
    defer std.testing.allocator.free(recovery_json);
    var recovered = try cmdOpen(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        recovery_json,
    );
    defer recovered.deinit(std.testing.allocator);
    var loaded = try loadLedger(std.testing.allocator, fixture.store, "run-2");
    defer loaded.deinit(std.testing.allocator);
    const inherited = loaded.state.?.review_work_node orelse {
        return error.TestExpectedReviewWorkNode;
    };
    try std.testing.expectEqualStrings("review-node-1", inherited.node_id);
    try std.testing.expectEqualStrings("run-1", inherited.run_id);
    try std.testing.expectEqualStrings("fixture", inherited.owner_boundary);
    try std.testing.expect(try equalCanonicalStringSets(
        std.testing.allocator,
        stringSlice(inherited.paths),
        &.{ "target.txt", "other.txt" },
    ));

    const path_drift = OperationInput{
        .schema = "actuation-operation/v1",
        .step_id = "recovery-step",
        .effect = "edit",
        .idempotency_key = "run-2:recovery-step",
        .owner_boundary = "fixture",
        .paths = &.{"target.txt"},
        .obligation_refs = &.{"obl-1"},
    };
    const path_drift_json = try encodeBodyAlloc(std.testing.allocator, path_drift);
    defer std.testing.allocator.free(path_drift_json);
    try std.testing.expectError(
        error.ReviewWorkPathsMismatch,
        cmdPrepare(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "run-2",
            path_drift_json,
        ),
    );
    var owner_drift = path_drift;
    owner_drift.owner_boundary = "different-owner";
    owner_drift.paths = &.{ "target.txt", "other.txt" };
    const owner_drift_json = try encodeBodyAlloc(std.testing.allocator, owner_drift);
    defer std.testing.allocator.free(owner_drift_json);
    try std.testing.expectError(
        error.ReviewWorkOwnerMismatch,
        cmdPrepare(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "run-2",
            owner_drift_json,
        ),
    );
    var exact_recovery = path_drift;
    exact_recovery.paths = &.{ "other.txt", "target.txt" };
    const exact_recovery_json = try encodeBodyAlloc(
        std.testing.allocator,
        exact_recovery,
    );
    defer std.testing.allocator.free(exact_recovery_json);
    var recovery_prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-2",
        exact_recovery_json,
    );
    defer recovery_prepared.deinit(std.testing.allocator);
    var aborted = try cmdAbort(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-2",
    );
    defer aborted.deinit(std.testing.allocator);
}

test "replayed supersession rejects admission evidence inside mutation scope" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestEditOperation,
    );
    defer prepared.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "changed\n");

    var loaded = try loadLedger(std.testing.allocator, fixture.store, "run-1");
    defer loaded.deinit(std.testing.allocator);
    const state = &loaded.state.?;
    const pending = &state.pending.?;
    const current_artifact = try repositoryArtifactDigestAlloc(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        stringSlice(state.allowed_paths),
    );
    defer std.testing.allocator.free(current_artifact);
    const current_unscoped = try unscopedDigestAlloc(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        stringSlice(pending.paths),
        stringSlice(state.allowed_paths),
    );
    defer std.testing.allocator.free(current_unscoped);
    const current_paths = try snapshotPathStatesAlloc(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        stringSlice(pending.paths),
    );
    defer freePathStates(std.testing.allocator, current_paths);
    const before_wires = try pathStateWiresAlloc(std.testing.allocator, pending.path_states_before);
    defer std.testing.allocator.free(before_wires);
    const after_wires = try pathStateWiresAlloc(std.testing.allocator, current_paths);
    defer std.testing.allocator.free(after_wires);
    const placeholder_digest =
        "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    const body = RunSupersededBody{
        .generation_id = state.generation_id.?,
        .artifact_before = state.artifact_digest,
        .artifact_after = current_artifact,
        .scope_paths = stringSlice(pending.paths),
        .unscoped_before = pending.unscoped_before,
        .unscoped_after = current_unscoped,
        .path_states_before = before_wires,
        .path_states_after = after_wires,
        .changed_paths = &.{"target.txt"},
        .recovery_basis = .{ .ref = "target.txt", .digest = placeholder_digest },
        .recovery = .{
            .authority_ref = "basis.txt",
            .authority_digest = placeholder_digest,
            .reason = "capability-lost-after-change",
        },
        .reserved_successor_generation_id = placeholder_digest,
    };
    const body_json = try encodeBodyAlloc(std.testing.allocator, body);
    defer std.testing.allocator.free(body_json);
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        applySupersededEvent(std.testing.allocator, state, &.{}, body_json),
    );
}

test "ready supersession requires one exact closed external mutation run" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var original = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer original.deinit(std.testing.allocator);
    const external_open = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestOpenSingle,
        "\"run_id\": \"run-1\"",
        "\"run_id\": \"run-2\"",
    );
    defer std.testing.allocator.free(external_open);
    const external_goal = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        external_open,
        "\"goal_id\": \"goal-1\"",
        "\"goal_id\": \"goal-2\"",
    );
    defer std.testing.allocator.free(external_goal);
    var external = try cmdOpen(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        external_goal,
    );
    defer external.deinit(std.testing.allocator);
    const external_operation = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestEditOperation,
        "\"step_id\": \"step-1\"",
        "\"step_id\": \"step-2\"",
    );
    defer std.testing.allocator.free(external_operation);
    const external_operation_key = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        external_operation,
        "\"idempotency_key\": \"run-1:step-1\"",
        "\"idempotency_key\": \"run-2:step-2\"",
    );
    defer std.testing.allocator.free(external_operation_key);
    var prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-2",
        external_operation_key,
    );
    defer prepared.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        fixture.target,
        "externally-repaired\n",
    );
    var recorded = try cmdRecord(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-2",
        prepared.capability.?,
    );
    defer recorded.deinit(std.testing.allocator);
    var observed = try cmdObserve(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-2",
        "step-2",
    );
    defer observed.deinit(std.testing.allocator);
    try std.testing.expect(observed.passed.?);
    try std.testing.expectError(
        error.ExternalMutationRunMismatch,
        cmdSupersede(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "run-1",
            TestSupersedeExternal,
        ),
    );
    var closed = try cmdClose(std.testing.allocator, fixture.root, fixture.store, "run-2");
    defer closed.deinit(std.testing.allocator);

    const without_external = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestSupersede,
        "capability-lost-after-change",
        "artifact-stale",
    );
    defer std.testing.allocator.free(without_external);
    try std.testing.expectError(
        error.ExternalMutationRunRequired,
        cmdSupersede(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "run-1",
            without_external,
        ),
    );
    var superseded = try cmdSupersede(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestSupersedeExternal,
    );
    defer superseded.deinit(std.testing.allocator);
    try std.testing.expect(superseded.reserved_successor_generation_id != null);
}

test "effect-recorded staleness can supersede only from the exact post-record snapshot" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestEditOperation,
    );
    defer prepared.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "recorded\n");
    var recorded = try cmdRecord(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        prepared.capability.?,
    );
    defer recorded.deinit(std.testing.allocator);
    const stale_supersede = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestSupersede,
        "capability-lost-after-change",
        "artifact-stale",
    );
    defer std.testing.allocator.free(stale_supersede);
    var superseded = try cmdSupersede(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        stale_supersede,
    );
    defer superseded.deinit(std.testing.allocator);

    var loaded = try loadLedger(std.testing.allocator, fixture.store, "run-1");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(Phase.superseded, loaded.state.?.phase);
    try std.testing.expect(loaded.state.?.pending == null);
    try std.testing.expect(superseded.reserved_successor_generation_id != null);
}

test "effect-recorded supersession rejects an additional unprepared edit" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestEditOperation,
    );
    defer prepared.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "recorded\n");
    var recorded = try cmdRecord(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        prepared.capability.?,
    );
    defer recorded.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        fixture.target,
        "stale-after-record\n",
    );
    const stale_supersede = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestSupersede,
        "capability-lost-after-change",
        "artifact-stale",
    );
    defer std.testing.allocator.free(stale_supersede);
    try std.testing.expectError(
        error.UnpreparedMutationAfterRecord,
        cmdSupersede(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "run-1",
            stale_supersede,
        ),
    );
}

test "supersede rejects unchanged and out-of-scope prepared state" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenTwoPaths);
    defer opened.deinit(std.testing.allocator);
    var prepared = try cmdPrepare(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "run-1",
        TestEditOperation,
    );
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.SupersedeRequiresArtifactChange,
        cmdSupersede(std.testing.allocator, fixture.root, fixture.store, "run-1", TestSupersede),
    );
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "changed\n");
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.other, "escaped\n");
    try std.testing.expectError(
        error.OutOfScopeMutation,
        cmdSupersede(std.testing.allocator, fixture.root, fixture.store, "run-1", TestSupersede),
    );
}

test "artifact identity canonicalizes allowed path order" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const forward = try repositoryArtifactDigestAlloc(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        &.{ "target.txt", "other.txt" },
    );
    defer std.testing.allocator.free(forward);
    const reverse = try repositoryArtifactDigestAlloc(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        &.{ "other.txt", "target.txt" },
    );
    defer std.testing.allocator.free(reverse);
    try std.testing.expectEqualStrings(forward, reverse);
}

test "admission evidence cannot enter mutation scope through a parent symlink" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    try runTestCommand(
        std.testing.allocator,
        fixture.root,
        &.{ "ln", "-s", ".", "alias-root" },
    );
    const aliased_scope = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestOpenSingle,
        "target.txt",
        "alias-root/basis.txt",
    );
    defer std.testing.allocator.free(aliased_scope);
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        cmdOpen(std.testing.allocator, fixture.root, fixture.store, aliased_scope),
    );

    const aliased_evidence = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestOpenSingle,
        "\"ref\": \"basis.txt\"",
        "\"ref\": \"alias-root/basis.txt\"",
    );
    defer std.testing.allocator.free(aliased_evidence);
    try std.testing.expectError(
        error.EvidenceRefUnreadable,
        cmdOpen(std.testing.allocator, fixture.root, fixture.store, aliased_evidence),
    );
}

test "admission evidence hardlinks cannot be selected as mutation scope" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    try runTestCommand(
        std.testing.allocator,
        fixture.root,
        &.{ "ln", "basis.txt", "basis-hardlink.txt" },
    );
    const hardlinked_scope = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        TestOpenSingle,
        "target.txt",
        "basis-hardlink.txt",
    );
    defer std.testing.allocator.free(hardlinked_scope);
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        cmdOpen(std.testing.allocator, fixture.root, fixture.store, hardlinked_scope),
    );
}

test "case aliases are physically checked when the filesystem exposes them" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const case_alias = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "Basis.txt" },
    );
    defer std.testing.allocator.free(case_alias);
    const alias_stat = std.Io.Dir.cwd().statFile(
        defaultIo(),
        case_alias,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (alias_stat != null) {
        try std.testing.expectError(
            error.MutableAdmissionEvidence,
            validatePhysicalEvidenceRef(
                std.testing.allocator,
                fixture.root,
                fixture.store,
                "basis.txt",
                &.{"Basis.txt"},
            ),
        );
    }
}

test "all admission roles reject source-memory and selected-store control evidence" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const source_control = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, SourceMemoryControlPaths[0] },
    );
    defer std.testing.allocator.free(source_control);
    try std.Io.Dir.cwd().createDirPath(
        defaultIo(),
        std.fs.path.dirname(source_control).?,
    );
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        source_control,
        "source-control\n",
    );
    const source_digest = try digestTextAlloc(
        std.testing.allocator,
        "source-control\n",
    );
    defer std.testing.allocator.free(source_digest);
    const policy_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "policy.json" },
    );
    defer std.testing.allocator.free(policy_path);
    const resolution_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "resolution.json" },
    );
    defer std.testing.allocator.free(resolution_path);
    try durable_store.writeTextAtomic(std.testing.allocator, policy_path, "policy\n");
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        resolution_path,
        "resolution\n",
    );
    const policy_digest = try digestTextAlloc(std.testing.allocator, "policy\n");
    defer std.testing.allocator.free(policy_digest);
    const resolution_digest = try digestTextAlloc(
        std.testing.allocator,
        "resolution\n",
    );
    defer std.testing.allocator.free(resolution_digest);
    const goal_digest =
        "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    const basis_digest =
        "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c";
    const obligations = [_]ObligationInput{.{
        .id = "obl-1",
        .kind = "implementation",
        .statement = "The edit is verified.",
        .verifier = &.{ "git", "diff", "--check" },
    }};
    var input = OpenInput{
        .schema = "actuation-open/v2",
        .run_id = "run-control",
        .goal_id = "goal-control",
        .goal_contract_digest = goal_digest,
        .source_ref = "user:turn",
        .execution_authority_ref = "user:turn",
        .mutation_allowed = true,
        .completion = "complete",
        .allowed_paths = &.{"target.txt"},
        .obligations = &obligations,
        .generation_admission = .{
            .schema = "actuation-generation-admission/v1",
            .kind = "implementation",
            .basis = .{ .ref = SourceMemoryControlPaths[0], .digest = source_digest },
        },
    };
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        validateAdmissionEvidence(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            input,
            .implementation,
        ),
    );

    input.generation_admission.basis = .{ .ref = "basis.txt", .digest = basis_digest };
    input.generation_admission.review = .{
        .policy_ref = SourceMemoryControlPaths[0],
        .policy_digest = source_digest,
        .resolution_ref = "resolution.json",
        .resolution_digest = resolution_digest,
    };
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        validateAdmissionEvidence(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            input,
            .implementation,
        ),
    );
    input.generation_admission.review = .{
        .policy_ref = "policy.json",
        .policy_digest = policy_digest,
        .resolution_ref = SourceMemoryControlPaths[0],
        .resolution_digest = source_digest,
    };
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        validateAdmissionEvidence(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            input,
            .implementation,
        ),
    );
    input.generation_admission.kind = "recovery";
    input.generation_admission.review = .{};
    input.generation_admission.recovery = .{
        .authority_ref = SourceMemoryControlPaths[0],
        .authority_digest = source_digest,
        .reason = "artifact-stale",
    };
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        validateAdmissionEvidence(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            input,
            .recovery,
        ),
    );

    const custom_store = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "control/events.jsonl" },
    );
    defer std.testing.allocator.free(custom_store);
    try std.Io.Dir.cwd().createDirPath(defaultIo(), std.fs.path.dirname(custom_store).?);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        custom_store,
        "custom-store\n",
    );
    const custom_store_digest = try digestTextAlloc(
        std.testing.allocator,
        "custom-store\n",
    );
    defer std.testing.allocator.free(custom_store_digest);
    input.generation_admission.kind = "implementation";
    input.generation_admission.recovery = .{};
    input.generation_admission.basis = .{
        .ref = "control/events.jsonl",
        .digest = custom_store_digest,
    };
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        validateAdmissionEvidence(
            std.testing.allocator,
            fixture.root,
            custom_store,
            input,
            .implementation,
        ),
    );
    const custom_lock = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}.lock",
        .{custom_store},
    );
    defer std.testing.allocator.free(custom_lock);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        custom_lock,
        "custom-lock\n",
    );
    const custom_lock_digest = try digestTextAlloc(
        std.testing.allocator,
        "custom-lock\n",
    );
    defer std.testing.allocator.free(custom_lock_digest);
    input.generation_admission.basis = .{
        .ref = "control/events.jsonl.lock",
        .digest = custom_lock_digest,
    };
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        validateAdmissionEvidence(
            std.testing.allocator,
            fixture.root,
            custom_store,
            input,
            .implementation,
        ),
    );

    try runTestCommand(
        std.testing.allocator,
        fixture.root,
        &.{ "ln", SourceMemoryControlPaths[0], "control-alias.json" },
    );
    input.generation_admission.basis = .{
        .ref = "control-alias.json",
        .digest = source_digest,
    };
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        validateAdmissionEvidence(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            input,
            .implementation,
        ),
    );
    const source_case_alias = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, ".ledger/LEARNINGS/events.jsonl" },
    );
    defer std.testing.allocator.free(source_case_alias);
    const source_case_stat = std.Io.Dir.cwd().statFile(
        defaultIo(),
        source_case_alias,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (source_case_stat != null) {
        input.generation_admission.basis = .{
            .ref = ".ledger/LEARNINGS/events.jsonl",
            .digest = source_digest,
        };
        try std.testing.expectError(
            error.MutableAdmissionEvidence,
            validateAdmissionEvidence(
                std.testing.allocator,
                fixture.root,
                fixture.store,
                input,
                .implementation,
            ),
        );
    }
    const traversed = try resolveStorePathAlloc(
        std.testing.allocator,
        fixture.root,
        ".ledger/x/../learnings/events.jsonl",
    );
    defer std.testing.allocator.free(traversed);
    try std.testing.expectError(
        error.ReservedActuationStorePath,
        validateActuationStorePath(std.testing.allocator, fixture.root, traversed),
    );
}

test "evidence semantics consume the single owned byte snapshot" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const original_digest = try digestTextAlloc(std.testing.allocator, "basis\n");
    defer std.testing.allocator.free(original_digest);
    var snapshot = try openEvidenceSnapshot(
        std.testing.allocator,
        fixture.root,
        .{ .ref = "basis.txt", .digest = original_digest },
    );
    defer snapshot.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        snapshot.path,
        "replacement\n",
    );
    try std.testing.expectEqualStrings("basis\n", snapshot.bytes);
    const snapshot_digest = try digestTextAlloc(
        std.testing.allocator,
        snapshot.bytes,
    );
    defer std.testing.allocator.free(snapshot_digest);
    try std.testing.expectEqualStrings(original_digest, snapshot_digest);
}

test "actuation and exact source-memory control data are excluded" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const before = try repositoryArtifactDigestAlloc(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        &.{"target.txt"},
    );
    defer std.testing.allocator.free(before);
    try runTestCommand(
        std.testing.allocator,
        fixture.root,
        &.{
            "mkdir",
            "-p",
            ".ledger/actuation",
            ".ledger/learnings",
            ".ledger/negative-ledger",
            ".ledger/synesthesia",
        },
    );
    const control = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, ".ledger/actuation/noise.json" },
    );
    defer std.testing.allocator.free(control);
    try durable_store.writeTextAtomic(std.testing.allocator, control, "control\n");
    const after_control = try repositoryArtifactDigestAlloc(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        &.{"target.txt"},
    );
    defer std.testing.allocator.free(after_control);
    try std.testing.expectEqualStrings(before, after_control);

    for (SourceMemoryControlPaths) |relative| {
        const source_control = try std.fs.path.join(
            std.testing.allocator,
            &.{ fixture.root, relative },
        );
        defer std.testing.allocator.free(source_control);
        try durable_store.writeTextAtomic(
            std.testing.allocator,
            source_control,
            "checkpoint-control\n",
        );
        const after_source_control = try repositoryArtifactDigestAlloc(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            &.{"target.txt"},
        );
        defer std.testing.allocator.free(after_source_control);
        try std.testing.expectEqualStrings(before, after_source_control);
    }

    const learning = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, ".ledger/learnings/note.json" },
    );
    defer std.testing.allocator.free(learning);
    try durable_store.writeTextAtomic(std.testing.allocator, learning, "product-visible\n");
    const after_learning = try repositoryArtifactDigestAlloc(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        &.{"target.txt"},
    );
    defer std.testing.allocator.free(after_learning);
    try std.testing.expect(!std.mem.eql(u8, before, after_learning));
    try std.testing.expectError(
        error.ReservedRepoPath,
        validateAllowedPaths(&.{".ledger/learnings/events.jsonl"}),
    );
    try std.testing.expectError(
        error.ReservedRepoPath,
        validateAllowedPaths(&.{".ledger"}),
    );
    const reserved_store = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, ".ledger/learnings/events.jsonl" },
    );
    defer std.testing.allocator.free(reserved_store);
    try std.testing.expectError(
        error.ReservedActuationStorePath,
        validateActuationStorePath(std.testing.allocator, fixture.root, reserved_store),
    );
    const aliased_store = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "aliased-actuation-store.jsonl" },
    );
    defer std.testing.allocator.free(aliased_store);
    try runTestCommand(
        std.testing.allocator,
        fixture.root,
        &.{ "ln", ".ledger/learnings/events.jsonl", "aliased-actuation-store.jsonl" },
    );
    try std.testing.expectError(
        error.ReservedActuationStorePath,
        validateActuationStorePath(std.testing.allocator, fixture.root, aliased_store),
    );
}

fn writeTestRepoFile(
    allocator: std.mem.Allocator,
    repo: []const u8,
    relative: []const u8,
    text: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ repo, relative });
    defer allocator.free(path);
    try durable_store.writeTextAtomic(allocator, path, text);
}

fn expectAllowedPathReserved(
    allocator: std.mem.Allocator,
    repo: []const u8,
    store_path: []const u8,
    path: []const u8,
) !void {
    try std.testing.expectError(
        error.ReservedRepoPath,
        validateAllowedPathsAgainstStore(allocator, repo, store_path, &.{path}),
    );
}

fn prepareNestedControlAliasFixture(
    allocator: std.mem.Allocator,
    repo: []const u8,
    custom_store: []const u8,
    custom_lock: []const u8,
) !void {
    try runTestCommand(
        allocator,
        repo,
        &.{
            "mkdir",
            "-p",
            "allowed-store/nested",
            "allowed-lock/nested",
            "allowed-clean",
        },
    );
    try writeTestRepoFile(allocator, repo, "allowed-store/neighbor.txt", "neighbor\n");
    try writeTestRepoFile(allocator, repo, "allowed-lock/neighbor.txt", "neighbor\n");
    try writeTestRepoFile(allocator, repo, "allowed-clean/neighbor.txt", "neighbor\n");
    try runTestCommand(
        allocator,
        repo,
        &.{ "ln", custom_store, "allowed-store/nested/store-alias.jsonl" },
    );
    try runTestCommand(
        allocator,
        repo,
        &.{ "ln", custom_lock, "allowed-lock/nested/lock-alias" },
    );
}

fn prepareBridgedFileAliasFixture(
    allocator: std.mem.Allocator,
    repo: []const u8,
    external_root: []const u8,
    target_file: []const u8,
    symlink_scope: []const u8,
    hardlink_scope: []const u8,
) !void {
    const external_symlink = try std.fs.path.join(
        allocator,
        &.{ external_root, symlink_scope },
    );
    defer allocator.free(external_symlink);
    const external_hardlink = try std.fs.path.join(
        allocator,
        &.{ external_root, hardlink_scope },
    );
    defer allocator.free(external_hardlink);
    try std.Io.Dir.cwd().createDirPath(defaultIo(), external_symlink);
    try std.Io.Dir.cwd().createDirPath(defaultIo(), external_hardlink);
    try runTestCommand(allocator, repo, &.{ "mkdir", "-p", symlink_scope, hardlink_scope });
    const symlink_target = try std.fs.path.join(
        allocator,
        &.{ external_symlink, "target-link" },
    );
    defer allocator.free(symlink_target);
    const hardlink_target = try std.fs.path.join(
        allocator,
        &.{ external_hardlink, "target-link" },
    );
    defer allocator.free(hardlink_target);
    const symlink_bridge = try std.fmt.allocPrint(allocator, "{s}/bridge", .{symlink_scope});
    defer allocator.free(symlink_bridge);
    const hardlink_bridge = try std.fmt.allocPrint(allocator, "{s}/bridge", .{hardlink_scope});
    defer allocator.free(hardlink_bridge);
    try runTestCommand(allocator, repo, &.{ "ln", "-s", target_file, symlink_target });
    try runTestCommand(allocator, repo, &.{ "ln", target_file, hardlink_target });
    try runTestCommand(allocator, repo, &.{ "ln", "-s", external_symlink, symlink_bridge });
    try runTestCommand(allocator, repo, &.{ "ln", "-s", external_hardlink, hardlink_bridge });
}

fn expectBridgedControlAliasesReserved(
    allocator: std.mem.Allocator,
    fixture: *const TestRepo,
    control_root: []const u8,
    custom_store: []const u8,
) !void {
    try prepareBridgedFileAliasFixture(
        allocator,
        fixture.root,
        control_root,
        custom_store,
        "allowed-bridge-symlink",
        "allowed-bridge-hardlink",
    );
    try expectAllowedPathReserved(
        allocator,
        fixture.root,
        custom_store,
        "allowed-bridge-symlink",
    );
    try expectAllowedPathReserved(
        allocator,
        fixture.root,
        custom_store,
        "allowed-bridge-hardlink",
    );
}

fn expectSourceMemoryCaseAliasReserved(fixture: *const TestRepo) !void {
    const case_alias = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, ".ledger/LEARNINGS/events.jsonl" },
    );
    defer std.testing.allocator.free(case_alias);
    const case_stat = std.Io.Dir.cwd().statFile(
        defaultIo(),
        case_alias,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (case_stat.kind != .file) return error.UnexpectedCaseAliasKind;
    try expectAllowedPathReserved(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        ".ledger/LEARNINGS/events.jsonl",
    );
}

test "allowed files reject source-memory control physical aliases" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const source_control = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, SourceMemoryControlPaths[0] },
    );
    defer std.testing.allocator.free(source_control);
    try std.Io.Dir.cwd().createDirPath(
        defaultIo(),
        std.fs.path.dirname(source_control).?,
    );
    try durable_store.writeTextAtomic(
        std.testing.allocator,
        source_control,
        "source-control\n",
    );
    try runTestCommand(
        std.testing.allocator,
        fixture.root,
        &.{ "ln", SourceMemoryControlPaths[0], "source-control-hardlink.jsonl" },
    );
    try expectAllowedPathReserved(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "source-control-hardlink.jsonl",
    );
    try runTestCommand(
        std.testing.allocator,
        fixture.root,
        &.{ "ln", "-s", SourceMemoryControlPaths[0], "source-control-symlink.jsonl" },
    );
    try expectAllowedPathReserved(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        "source-control-symlink.jsonl",
    );
    try expectSourceMemoryCaseAliasReserved(&fixture);

    try writeTestRepoFile(
        std.testing.allocator,
        fixture.root,
        ".ledger/learnings/neighbor.json",
        "neighbor\n",
    );
    try validateAllowedPaths(&.{".ledger/learnings/neighbor.json"});
    try validateAllowedPathsAgainstStore(
        std.testing.allocator,
        fixture.root,
        fixture.store,
        &.{".ledger/learnings/neighbor.json"},
    );
}

test "allowed directories reject nested external store and lock aliases" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var control_tmp = std.testing.tmpDir(.{});
    defer control_tmp.cleanup();
    const control_root = try control_tmp.dir.realPathFileAlloc(
        defaultIo(),
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(control_root);
    const custom_store = try std.fs.path.join(
        std.testing.allocator,
        &.{ control_root, "events.jsonl" },
    );
    defer std.testing.allocator.free(custom_store);
    const custom_lock = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}.lock",
        .{custom_store},
    );
    defer std.testing.allocator.free(custom_lock);
    try durable_store.writeTextAtomic(std.testing.allocator, custom_store, "store\n");
    try durable_store.writeTextAtomic(std.testing.allocator, custom_lock, "lock\n");
    try prepareNestedControlAliasFixture(
        std.testing.allocator,
        fixture.root,
        custom_store,
        custom_lock,
    );
    try expectBridgedControlAliasesReserved(
        std.testing.allocator,
        &fixture,
        control_root,
        custom_store,
    );
    try expectAllowedPathReserved(
        std.testing.allocator,
        fixture.root,
        custom_store,
        "allowed-store",
    );
    try expectAllowedPathReserved(
        std.testing.allocator,
        fixture.root,
        custom_store,
        "allowed-lock",
    );
    try validateAllowedPathsAgainstStore(
        std.testing.allocator,
        fixture.root,
        custom_store,
        &.{ "allowed-store/neighbor.txt", "allowed-lock/neighbor.txt" },
    );
    try validateAllowedPathsAgainstStore(
        std.testing.allocator,
        fixture.root,
        custom_store,
        &.{"allowed-clean"},
    );
}

test "evidence scope rejects bridged directory symlink aliases" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const external_root = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "external-evidence" },
    );
    defer std.testing.allocator.free(external_root);
    try std.Io.Dir.cwd().createDirPath(defaultIo(), external_root);
    const basis = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "basis.txt" },
    );
    defer std.testing.allocator.free(basis);
    try prepareBridgedFileAliasFixture(
        std.testing.allocator,
        fixture.root,
        external_root,
        basis,
        "evidence-bridge-symlink",
        "evidence-bridge-hardlink",
    );
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        validatePhysicalEvidenceRef(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "basis.txt",
            &.{"evidence-bridge-symlink"},
        ),
    );
    try std.testing.expectError(
        error.MutableAdmissionEvidence,
        validatePhysicalEvidenceRef(
            std.testing.allocator,
            fixture.root,
            fixture.store,
            "basis.txt",
            &.{"evidence-bridge-hardlink"},
        ),
    );
}

test "allowed directory scans share one fail-closed entry limit" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    try runTestCommand(
        std.testing.allocator,
        fixture.root,
        &.{ "mkdir", "-p", "bounded-one", "bounded-two" },
    );
    try writeTestRepoFile(std.testing.allocator, fixture.root, "bounded-one/file", "1\n");
    try writeTestRepoFile(std.testing.allocator, fixture.root, "bounded-two/file", "2\n");
    const first_directory = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "bounded-one" },
    );
    defer std.testing.allocator.free(first_directory);
    const second_directory = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "bounded-two" },
    );
    defer std.testing.allocator.free(second_directory);
    var control = try physicalPathIdentityAlloc(std.testing.allocator, fixture.store);
    defer control.deinit(std.testing.allocator);
    var entries_remaining: usize = 1;
    try std.testing.expectEqual(
        DirectoryAliasScanResult.clear,
        try scanDirectoryForPhysicalAliases(
            std.testing.allocator,
            first_directory,
            &.{control},
            &entries_remaining,
        ),
    );
    try std.testing.expectError(
        error.AllowedPathScanLimitExceeded,
        scanDirectoryForPhysicalAliases(
            std.testing.allocator,
            second_directory,
            &.{control},
            &entries_remaining,
        ),
    );
}

test "file identity binds filesystem and inode" {
    const first = FileIdentity{ .device = 1, .inode = 7 };
    try std.testing.expect(sameFileIdentity(first, first));
    try std.testing.expect(!sameFileIdentity(first, .{ .device = 2, .inode = 7 }));
    try std.testing.expect(!sameFileIdentity(first, .{ .device = 1, .inode = 8 }));

    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    try runTestCommand(
        std.testing.allocator,
        fixture.root,
        &.{ "ln", "target.txt", "target-hardlink.txt" },
    );
    const hardlink = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "target-hardlink.txt" },
    );
    defer std.testing.allocator.free(hardlink);
    const target_identity = try fileIdentityForPath(fixture.target);
    const hardlink_identity = try fileIdentityForPath(hardlink);
    try std.testing.expect(sameFileIdentity(target_identity, hardlink_identity));

    const device_identity = fileIdentityForPath("/dev/null") catch return;
    if (target_identity.device == device_identity.device) return;
    try std.testing.expect(!sameFileIdentity(target_identity, device_identity));
}

test "custom in-repo store exclusion is exact to the store and lock" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const custom_store = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "control/events.jsonl" },
    );
    defer std.testing.allocator.free(custom_store);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, custom_store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    const stable = try repositoryArtifactDigestAlloc(
        std.testing.allocator,
        fixture.root,
        custom_store,
        &.{"target.txt"},
    );
    defer std.testing.allocator.free(stable);
    try std.testing.expectEqualStrings(opened.artifact_digest, stable);
    const neighbor = try std.fs.path.join(
        std.testing.allocator,
        &.{ fixture.root, "control/neighbor.txt" },
    );
    defer std.testing.allocator.free(neighbor);
    try durable_store.writeTextAtomic(std.testing.allocator, neighbor, "neighbor\n");
    const changed = try repositoryArtifactDigestAlloc(
        std.testing.allocator,
        fixture.root,
        custom_store,
        &.{"target.txt"},
    );
    defer std.testing.allocator.free(changed);
    try std.testing.expect(!std.mem.eql(u8, stable, changed));
    try std.testing.expectError(
        error.ReservedRepoPath,
        validateAllowedPathsAgainstStore(
            std.testing.allocator,
            fixture.root,
            custom_store,
            &.{"control/events.jsonl"},
        ),
    );
    try std.testing.expectError(
        error.ReservedRepoPath,
        validateAllowedPathsAgainstStore(
            std.testing.allocator,
            fixture.root,
            custom_store,
            &.{"control/events.jsonl.lock"},
        ),
    );
    try runTestCommand(
        std.testing.allocator,
        fixture.root,
        &.{ "ln", "control/events.jsonl", "control/events-alias.jsonl" },
    );
    try std.testing.expectError(
        error.ReservedRepoPath,
        validateAllowedPathsAgainstStore(
            std.testing.allocator,
            fixture.root,
            custom_store,
            &.{"control/events-alias.jsonl"},
        ),
    );
}

test "idempotency keys cannot authorize a second operation" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenTwoObligations);
    defer opened.deinit(std.testing.allocator);
    const first =
        \\{
        \\  "schema": "actuation-operation/v1",
        \\  "step_id": "step-1",
        \\  "effect": "verify",
        \\  "idempotency_key": "same-key",
        \\  "owner_boundary": "fixture",
        \\  "paths": [
        \\    "target.txt"
        \\  ],
        \\  "obligation_refs": [
        \\    "obl-1"
        \\  ]
        \\}
    ;
    var prepared = try cmdPrepare(std.testing.allocator, fixture.root, fixture.store, "run-1", first);
    defer prepared.deinit(std.testing.allocator);
    var executed = try cmdExecute(std.testing.allocator, fixture.root, fixture.store, "run-1", prepared.capability.?);
    defer executed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?bool, true), executed.passed);

    const second =
        \\{
        \\  "schema": "actuation-operation/v1",
        \\  "step_id": "step-2",
        \\  "effect": "verify",
        \\  "idempotency_key": "same-key",
        \\  "owner_boundary": "fixture",
        \\  "paths": [
        \\    "target.txt"
        \\  ],
        \\  "obligation_refs": [
        \\    "obl-2"
        \\  ]
        \\}
    ;
    try std.testing.expectError(
        error.DuplicateIdempotencyKey,
        cmdPrepare(std.testing.allocator, fixture.root, fixture.store, "run-1", second),
    );
}

test "ready-to-ship is a terminal projection chosen at open" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenTwoObligations);
    defer opened.deinit(std.testing.allocator);
    const operation =
        \\{
        \\  "schema": "actuation-operation/v1",
        \\  "step_id": "step-1",
        \\  "effect": "verify",
        \\  "idempotency_key": "verify-all",
        \\  "owner_boundary": "fixture",
        \\  "paths": [
        \\    "target.txt"
        \\  ],
        \\  "obligation_refs": [
        \\    "obl-1",
        \\    "obl-2"
        \\  ]
        \\}
    ;
    var prepared = try cmdPrepare(std.testing.allocator, fixture.root, fixture.store, "run-1", operation);
    defer prepared.deinit(std.testing.allocator);
    var executed = try cmdExecute(std.testing.allocator, fixture.root, fixture.store, "run-1", prepared.capability.?);
    defer executed.deinit(std.testing.allocator);
    var closed = try cmdClose(std.testing.allocator, fixture.root, fixture.store, "run-1");
    defer closed.deinit(std.testing.allocator);

    var loaded = try loadLedger(std.testing.allocator, fixture.store, "run-1");
    defer loaded.deinit(std.testing.allocator);
    const decision = projectDecision(&loaded.state.?);
    try std.testing.expect(loaded.state.?.resolution_digest == null);
    try std.testing.expectEqualStrings("ready-to-ship", decision.verdict);
    try std.testing.expectEqualStrings("continue", decision.goal_outcome);
    try std.testing.expectEqualStrings("complete", decision.implementation_outcome);
    try std.testing.expectEqualStrings("ship", decision.next_owner);

    var ship_basis: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ship_basis.deinit();
    try writeDecisionBasis(&ship_basis.writer, &loaded.state.?, .ship);
    const ship_json = try ship_basis.toOwnedSlice();
    defer std.testing.allocator.free(ship_json);
    try std.testing.expect(std.mem.indexOf(u8, ship_json, "obl-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, ship_json, "obl-1") == null);
}

test "post-hoc prepare is rejected when the live artifact already moved" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "post-hoc\n");
    try std.testing.expectError(
        error.ArtifactStale,
        cmdPrepare(std.testing.allocator, fixture.root, fixture.store, "run-1", TestEditOperation),
    );
}

test "record rejects a simultaneous mutation outside the prepared path set" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenTwoPaths);
    defer opened.deinit(std.testing.allocator);
    var prepared = try cmdPrepare(std.testing.allocator, fixture.root, fixture.store, "run-1", TestEditOperation);
    defer prepared.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.target, "after\n");
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.other, "escaped\n");
    try std.testing.expectError(
        error.OutOfScopeMutation,
        cmdRecord(std.testing.allocator, fixture.root, fixture.store, "run-1", prepared.capability.?),
    );
}

test "an allowed directory does not make its prepared child look out of scope" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    try runTestCommand(std.testing.allocator, fixture.root, &.{ "mkdir", "-p", "scope" });
    const child = try std.fs.path.join(std.testing.allocator, &.{ fixture.root, "scope/child.txt" });
    defer std.testing.allocator.free(child);
    try durable_store.writeTextAtomic(std.testing.allocator, child, "before\n");
    try runTestCommand(std.testing.allocator, fixture.root, &.{ "git", "add", "scope/child.txt" });
    try runTestCommand(std.testing.allocator, fixture.root, &.{ "git", "commit", "--quiet", "-m", "add scope" });

    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenDirectory);
    defer opened.deinit(std.testing.allocator);
    const operation =
        \\{
        \\  "schema": "actuation-operation/v1",
        \\  "step_id": "step-1",
        \\  "effect": "edit",
        \\  "idempotency_key": "nested-edit",
        \\  "owner_boundary": "fixture",
        \\  "paths": [
        \\    "scope/child.txt"
        \\  ],
        \\  "obligation_refs": [
        \\    "obl-1"
        \\  ]
        \\}
    ;
    var prepared = try cmdPrepare(std.testing.allocator, fixture.root, fixture.store, "run-1", operation);
    defer prepared.deinit(std.testing.allocator);
    try durable_store.writeTextAtomic(std.testing.allocator, child, "after\n");
    var recorded = try cmdRecord(std.testing.allocator, fixture.root, fixture.store, "run-1", prepared.capability.?);
    defer recorded.deinit(std.testing.allocator);
}

test "a verifier that mutates the repository cannot record an observation" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenMutatingVerifier);
    defer opened.deinit(std.testing.allocator);
    const operation =
        \\{
        \\  "schema": "actuation-operation/v1",
        \\  "step_id": "step-1",
        \\  "effect": "verify",
        \\  "idempotency_key": "mutating-verifier",
        \\  "owner_boundary": "fixture",
        \\  "paths": [
        \\    "target.txt"
        \\  ],
        \\  "obligation_refs": [
        \\    "obl-1"
        \\  ]
        \\}
    ;
    var prepared = try cmdPrepare(std.testing.allocator, fixture.root, fixture.store, "run-1", operation);
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.VerifierMutatedArtifact,
        cmdExecute(std.testing.allocator, fixture.root, fixture.store, "run-1", prepared.capability.?),
    );
    var loaded = try loadLedger(std.testing.allocator, fixture.store, "run-1");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(Phase.prepared, loaded.state.?.phase);
    try std.testing.expectEqual(@as(u64, 2), loaded.event_count);
}

test "close rejects uncovered obligations" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.ObligationsOutstanding,
        cmdClose(std.testing.allocator, fixture.root, fixture.store, "run-1"),
    );
}

test "decision projection remains a continuation before close" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    var loaded = try loadLedger(std.testing.allocator, fixture.store, "run-1");
    defer loaded.deinit(std.testing.allocator);
    const decision = projectDecision(&loaded.state.?);
    try std.testing.expectEqualStrings("continue", decision.verdict);
    try std.testing.expectEqualStrings("continue", decision.goal_outcome);
    try std.testing.expectEqualStrings("incomplete", decision.implementation_outcome);
    try std.testing.expectEqualStrings("goal-actuating", decision.next_owner);
    try std.testing.expectEqualStrings("prepare", decision.next_transition);
}

test "open rejects an unknown proof-basis kind" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    const invalid =
        \\{
        \\  "schema": "actuation-open/v2",
        \\  "run_id": "run-1",
        \\  "goal_id": "goal-1",
        \\  "goal_contract_digest":
        \\    "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        \\  "source_ref": "user:turn",
        \\  "execution_authority_ref": "user:turn",
        \\  "mutation_allowed": true,
        \\  "completion": "complete",
        \\  "allowed_paths": [
        \\    "target.txt"
        \\  ],
        \\  "obligations": [
        \\    {
        \\      "id": "obl-1",
        \\      "kind": "summary",
        \\      "statement": "Invalid proof kind.",
        \\      "verifier": [
        \\        "git",
        \\        "diff",
        \\        "--check"
        \\      ]
        \\    }
        \\  ],
        \\  "generation_admission": {
        \\    "schema": "actuation-generation-admission/v1",
        \\    "kind": "implementation",
        \\    "predecessor_run_id": null,
        \\    "basis": {
        \\      "ref": "basis.txt",
        \\      "digest": "sha256:ebb520608a046891535c131679c81446d3ecd4526e238a152b48f0a9ece0b68c"
        \\    },
        \\    "review": {},
        \\    "recovery": {}
        \\  }
        \\}
    ;
    try std.testing.expectError(
        error.InvalidObligationKind,
        cmdOpen(std.testing.allocator, fixture.root, fixture.store, invalid),
    );
}

test "tampered event body fails the hash-chain load" {
    var fixture = try setupTestRepo(std.testing.allocator);
    defer cleanupTestRepo(std.testing.allocator, &fixture);
    var opened = try cmdOpen(std.testing.allocator, fixture.root, fixture.store, TestOpenSingle);
    defer opened.deinit(std.testing.allocator);
    const bytes = try durable_store.readRegularFileNoSymlink(std.testing.allocator, fixture.store, MaxStoreBytes);
    defer std.testing.allocator.free(bytes);
    const marker = "goal-1";
    const index = std.mem.indexOf(u8, bytes, marker) orelse return error.TestMarkerMissing;
    const tampered = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(tampered);
    tampered[index + marker.len - 1] = '2';
    try durable_store.writeTextAtomic(std.testing.allocator, fixture.store, tampered);
    try std.testing.expectError(
        error.BodyDigestMismatch,
        loadLedger(std.testing.allocator, fixture.store, "run-1"),
    );
}
