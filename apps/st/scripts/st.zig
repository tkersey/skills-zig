const app_meta = @import("app_meta");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const SchemaVersion: i64 = 3;
const GraphSchemaVersion: i64 = 4;
const GraphEnvelopeVersion: i64 = 1;
const PlanSyncVersion: i64 = 3;
const HelpSurface = core_cli.HelpSurface{
    .executable_name = "st",
    .help_text = UsageText,
};

const UsageText =
    \\st
    \\
    \\Manage dependency-aware JSONL v3/v4 plan state.
    \\
    \\usage: st {init,add,select,deselect,set-status,set-priority,set-deps,set-notes,add-comment,remove,show,ready,blocked,doctor,prime,assert-projection,reconcile-codex,import-proposed-plan,guard-session-start,guard-pre-tool-use,export,import-plan,import-orchplan,claim,heartbeat,set-runtime,set-proof,complete,proof,release,reclaim-stale,import-mesh-results,graph,aperture,compile} [options]
    \\
    \\commands:
    \\  init              Initialize plan storage
    \\  add               Add or upsert a plan item
    \\  select            Add tasks into the mirrored plan projection
    \\  deselect          Remove tasks from the mirrored plan projection
    \\  set-status        Set item status
    \\  set-priority      Set item priority
    \\  set-deps          Set item dependencies
    \\  set-notes         Set item notes
    \\  add-comment       Add a comment to an item
    \\  remove            Remove item
    \\  show              Show current plan
    \\  ready             Show ready pending items
    \\  blocked           Show blocked or waiting items
    \\  doctor            Inspect or repair seq contract integrity
    \\  prime             Select/project the durable frontier and emit plan_sync v3
    \\  assert-projection  Validate Codex/OpenCode projection invariants
    \\  reconcile-codex   Reconcile Codex update_plan payload or transcript into mirrored durable fields
    \\  import-proposed-plan  Import Plan Mode Markdown into durable backlog tasks
    \\  guard-session-start  Register expected SessionStart update_plan payload for a Codex session
    \\  guard-pre-tool-use  Check whether a SessionStart guard has been satisfied for the current turn
    \\  export            Export snapshot JSON
    \\  import-plan       Import snapshot JSON
    \\  import-orchplan   Import OrchPlan tasks into the durable ledger
    \\  claim             Claim a safe wave or task set with a lease
    \\  heartbeat         Refresh a held claim lease
    \\  set-runtime       Attach runtime execution metadata to a claimed item
    \\  set-proof         Record proof state and evidence for an item
    \\  complete          Record proof and complete a graph-mode item
    \\  proof             Proof commands: audit
    \\  release           Release a held claim and normalize task status
    \\  reclaim-stale     Reclaim expired held claims
    \\  import-mesh-results  Import mesh output CSV results into the ledger
    \\  graph            Graph compiler commands: schema, apply, audit, insights, polish
    \\  aperture         Aperture commands: next, plan, select, explain
    \\  compile          Compile shortcuts: intent, graph, ready, aperture
    \\
    \\common options:
    \\  --file PATH                     Path to plan JSONL file (default: .step/st-plan.jsonl)
    \\  --allow-multiple-in-progress    Allow multiple in_progress items
    \\  --format markdown|table|json|plan-sync|text  Output format for commands that support formats
    \\  --surface plan|all|backlog      Surface for show/ready/blocked (default: plan)
    \\  --priority high|medium|low      Priority for add/set-priority (add default: medium)
    \\  --limit N                       Projection limit for prime/assert-projection (default: 7)
    \\  --target codex|opencode|all     Projection target for prime/assert-projection (default: all/codex)
    \\  --mode selected|auto-top-up|replace-ready|aperture  Prime selection mode (default: selected)
    \\  --preview                       Compute prime output without writing selection changes
    \\  --hook-json                     Emit documented Codex hook JSON shapes
    \\  -h, --help                      Show help
    \\  -V, --version | version         Show version
;

const Status = enum {
    blocked,
    canceled,
    completed,
    deferred,
    in_progress,
    pending,

    fn asString(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .blocked => "blocked",
            .deferred => "deferred",
            .canceled => "canceled",
        };
    }
};

const Priority = enum {
    high,
    low,
    medium,

    fn asString(self: Priority) []const u8 {
        return switch (self) {
            .high => "high",
            .medium => "medium",
            .low => "low",
        };
    }
};

const DepState = enum {
    blocked_manual,
    na,
    ready,
    waiting_on_deps,

    fn asString(self: DepState) []const u8 {
        return switch (self) {
            .ready => "ready",
            .waiting_on_deps => "waiting_on_deps",
            .blocked_manual => "blocked_manual",
            .na => "n/a",
        };
    }
};

const Surface = enum {
    all,
    backlog,
    plan,

    fn asString(self: Surface) []const u8 {
        return switch (self) {
            .plan => "plan",
            .all => "all",
            .backlog => "backlog",
        };
    }
};

const ClaimState = enum {
    held,
    none,
    released,
    stale,

    fn asString(self: ClaimState) []const u8 {
        return switch (self) {
            .none => "none",
            .held => "held",
            .stale => "stale",
            .released => "released",
        };
    }
};

const ProofState = enum {
    fail,
    not_run,
    pass,

    fn asString(self: ProofState) []const u8 {
        return switch (self) {
            .not_run => "not_run",
            .pass => "pass",
            .fail => "fail",
        };
    }
};

const Dep = struct {
    id: []const u8,
    type: []const u8,
};

const Comment = struct {
    ts: []const u8,
    author: []const u8,
    text: []const u8,
};

const SourceMeta = struct {
    kind: []const u8 = "",
    locator: []const u8 = "",
    source_task_id: []const u8 = "",
    wave_id: []const u8 = "",
};

const ClaimMeta = struct {
    state: ClaimState = .none,
    owner: []const u8 = "",
    executor: []const u8 = "",
    wave_id: []const u8 = "",
    lock_roots: []const []const u8 = &.{},
    claimed_at: []const u8 = "",
    lease_seconds: i64 = 0,
    lease_expires_at: []const u8 = "",
    heartbeat_at: []const u8 = "",
    attempts: i64 = 0,
};

const RuntimeMeta = struct {
    substrate: []const u8 = "",
    thread_id: []const u8 = "",
    agent_id: []const u8 = "",
    row_id: []const u8 = "",
    output_ref: []const u8 = "",
    last_event: []const u8 = "",
};

const ProofMeta = struct {
    state: ProofState = .not_run,
    command: []const u8 = "",
    evidence_ref: []const u8 = "",
    last_run_at: []const u8 = "",
};

const ItemType = enum {
    bug,
    chore,
    decision,
    docs,
    epic,
    feature,
    research,
    spike,
    task,
    @"test",
    verification,

    fn asString(self: ItemType) []const u8 {
        return switch (self) {
            .epic => "epic",
            .feature => "feature",
            .task => "task",
            .bug => "bug",
            .@"test" => "test",
            .verification => "verification",
            .docs => "docs",
            .chore => "chore",
            .research => "research",
            .spike => "spike",
            .decision => "decision",
        };
    }
};

const GraphLink = struct {
    id: []const u8,
    type: []const u8,
    reason: []const u8 = "",
};

const ProofObligation = struct {
    id: []const u8,
    kind: []const u8,
    command: []const u8 = "",
    evidence_ref: []const u8 = "",
    required: bool = true,
};

const Contract = struct {
    objective: []const u8 = "",
    background: []const u8 = "",
    implementation_approach: []const u8 = "",
    success_criteria: []const []const u8 = &.{},
    proof_obligations: []const ProofObligation = &.{},
    risks: []const []const u8 = &.{},
};

const Item = struct {
    id: []const u8,
    step: []const u8,
    status: Status,
    priority: Priority,
    in_plan: bool,
    deps: []const Dep,
    notes: []const u8,
    comments: []const Comment,
    related_to: []const []const u8 = &.{},
    scope: []const []const u8 = &.{},
    location: []const []const u8 = &.{},
    validation: []const []const u8 = &.{},
    agent: []const u8 = "",
    role: []const u8 = "",
    source: ?SourceMeta = null,
    claim: ?ClaimMeta = null,
    runtime: ?RuntimeMeta = null,
    proof: ?ProofMeta = null,
    item_type: ItemType = .task,
    parent_id: ?[]const u8 = null,
    links: []const GraphLink = &.{},
    intent_refs: []const []const u8 = &.{},
    acceptance: []const []const u8 = &.{},
    contract: ?Contract = null,
    labels: []const []const u8 = &.{},
    lock_roots: []const []const u8 = &.{},
    uncertainty: []const []const u8 = &.{},
    non_goals: []const []const u8 = &.{},
};

const GraphPolicy = struct {
    completion_requires_proof: bool = false,
    implementation_ready_required: bool = true,
    default_projection_strategy: []const u8 = "aperture-score",
    default_gate: []const u8 = "implementation-ready",
    max_aperture_items: i64 = 7,
};

const IntentSource = struct {
    kind: []const u8 = "",
    locator: []const u8 = "",
    anchor: []const u8 = "",
};

const IntentAtom = struct {
    id: []const u8,
    source: ?IntentSource = null,
    text: []const u8,
    category: []const u8,
    disposition: []const u8,
    reason: []const u8 = "",
};

const Waiver = struct {
    id: []const u8,
    gate: []const u8,
    code: []const u8,
    target: []const u8,
    reason: []const u8,
    expires: []const u8,
    created_at: []const u8 = "",
    created_by: []const u8 = "",
};

const PolishDelta = struct {
    items_added: i64 = 0,
    items_removed: i64 = 0,
    items_split: i64 = 0,
    deps_changed: i64 = 0,
    contracts_changed: i64 = 0,
    intent_coverage_changed: i64 = 0,
};

const PolishPass = struct {
    pass: i64,
    seq: i64 = 0,
    created_at: []const u8 = "",
    structure_fingerprint: []const u8 = "",
    contract_fingerprint: []const u8 = "",
    coverage_fingerprint: []const u8 = "",
    execution_fingerprint: []const u8 = "",
    audit_gate: []const u8 = "",
    hard_failures: i64 = 0,
    warnings: i64 = 0,
    delta: PolishDelta = .{},
};

const PolishState = struct {
    session_id: []const u8 = "",
    passes: []const PolishPass = &.{},
};

const GraphFingerprints = struct {
    structure: []const u8 = "",
    contract: []const u8 = "",
    coverage: []const u8 = "",
    execution: []const u8 = "",
};

const GraphEnvelope = struct {
    version: i64 = GraphEnvelopeVersion,
    policy: GraphPolicy = .{},
    intent: []const IntentAtom = &.{},
    waivers: []const Waiver = &.{},
    polish: PolishState = .{},
    fingerprints: GraphFingerprints = .{},
};

const EnrichedItem = struct {
    item: *const Item,
    dep_state: DepState,
    waiting_on: []const []const u8,
    claim_state: ClaimState,
    claim_stale: bool,
    lock_roots: []const []const u8,
    executor_state: []const u8,
};

const MutationMeta = struct {
    allow_multiple_in_progress: bool,
    actor: []const u8,
    pid: i64,
    session: ?[]const u8,
};

const SessionGuardStateVersion: i64 = 1;

const SessionGuardState = struct {
    version: i64 = SessionGuardStateVersion,
    session_id: []const u8,
    plan_file: []const u8,
    expected_update_plan: []const u8,
    expected_selected_ids: []const []const u8 = &.{},
    cwd: []const u8,
};

const ProjectionTarget = enum {
    codex,
    opencode,
    all,

    fn asString(self: ProjectionTarget) []const u8 {
        return switch (self) {
            .codex => "codex",
            .opencode => "opencode",
            .all => "all",
        };
    }
};

const ProjectionMode = enum {
    aperture,
    auto_top_up,
    replace_ready,
    selected,

    fn asString(self: ProjectionMode) []const u8 {
        return switch (self) {
            .aperture => "aperture",
            .selected => "selected",
            .auto_top_up => "auto-top-up",
            .replace_ready => "replace-ready",
        };
    }
};

const ProjectionPolicy = struct {
    target: ProjectionTarget = .all,
    mode: ProjectionMode = .selected,
    limit: usize = 7,
    include_completed_context: bool = false,
    include_waiting_pending: bool = true,
    allow_opencode_parallel: bool = true,
    source_file: []const u8 = ".step/st-plan.jsonl",
    source_seq: i64 = 0,
};

const GraphCommand = enum {
    none,
    audit,
    apply,
    insights,
    polish,
    schema,
};

const PolishCommand = enum {
    none,
    begin,
    snapshot,
    status,
    gate,
};

const ApertureCommand = enum {
    none,
    next,
    plan,
    select,
    explain,
};

const CompileCommand = enum {
    none,
    intent,
    graph,
    ready,
    aperture,
};

const ProofCommand = enum {
    none,
    audit,
};

const AuditGate = enum {
    draft,
    implementation_ready,
    execution_ready,
    proof_complete,

    fn asString(self: AuditGate) []const u8 {
        return switch (self) {
            .draft => "draft",
            .implementation_ready => "implementation-ready",
            .execution_ready => "execution-ready",
            .proof_complete => "proof-complete",
        };
    }
};

const CodexPlanProjectionEntry = struct {
    id: []const u8,
    step: []const u8,
    status: []const u8,
};

const OpencodeTodoProjectionEntry = struct {
    id: []const u8,
    content: []const u8,
    status: []const u8,
    priority: []const u8,
};

const ProjectionResult = struct {
    rows: []const EnrichedItem,
    codex_plan: []CodexPlanProjectionEntry,
    opencode_todos: []OpencodeTodoProjectionEntry,
    selected_ids: []const []const u8,
    empty_reason: ?[]const u8,
    warnings: []const []const u8,
};

const FindingSeverity = enum {
    @"error",
    warning,
    info,

    fn asString(self: FindingSeverity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
            .info => "info",
        };
    }
};

const AuditFinding = struct {
    code: []const u8,
    severity: FindingSeverity,
    target: []const u8,
    message: []const u8,
    waived: bool = false,
    waiver_id: ?[]const u8 = null,
};

const AuditResult = struct {
    gate: AuditGate,
    findings: []AuditFinding,
    errors: usize,
    warnings: usize,
};

const GraphDelta = struct {
    seq_before: i64,
    seq_after: i64,
    items_added: []const []const u8 = &.{},
    items_removed: []const []const u8 = &.{},
    items_changed: []const []const u8 = &.{},
    intent_coverage_changed: []const []const u8 = &.{},
};

const RepairMeta = struct {
    op: []const u8,
};

const ItemState = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item),
    index: std.StringHashMap(usize),
    graph: GraphEnvelope,
    graph_active: bool,

    fn init(allocator: std.mem.Allocator) ItemState {
        return .{
            .allocator = allocator,
            .items = .empty,
            .index = std.StringHashMap(usize).init(allocator),
            .graph = .{},
            .graph_active = false,
        };
    }

    fn deinit(self: *ItemState) void {
        self.items.deinit(self.allocator);
        self.index.deinit();
    }

    fn clear(self: *ItemState) void {
        self.items.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
    }

    fn rebuildIndex(self: *ItemState) !void {
        self.index.clearRetainingCapacity();
        for (self.items.items, 0..) |item, idx| {
            try self.index.put(item.id, idx);
        }
    }

    fn get(self: *ItemState, id: []const u8) ?*Item {
        const idx = self.index.get(id) orelse return null;
        return &self.items.items[idx];
    }

    fn getConst(self: *const ItemState, id: []const u8) ?*const Item {
        const idx = self.index.get(id) orelse return null;
        return &self.items.items[idx];
    }

    fn upsert(self: *ItemState, item: Item) !void {
        if (self.index.get(item.id)) |idx| {
            self.items.items[idx] = item;
            return;
        }
        try self.items.append(self.allocator, item);
        try self.index.put(item.id, self.items.items.len - 1);
    }

    fn remove(self: *ItemState, id: []const u8) !void {
        const idx = self.index.get(id) orelse return;
        _ = self.items.orderedRemove(idx);
        try self.rebuildIndex();
    }
};

pub const Command = enum {
    @"export",
    add,
    add_comment,
    assert_projection,
    aperture,
    blocked,
    claim,
    compile,
    complete,
    deselect,
    doctor,
    guard_pre_tool_use,
    guard_session_start,
    graph,
    heartbeat,
    import_mesh_results,
    import_orchplan,
    import_plan,
    import_proposed_plan,
    init,
    prime,
    proof,
    ready,
    reclaim_stale,
    reconcile_codex,
    release,
    remove,
    select,
    set_proof,
    set_deps,
    set_notes,
    set_priority,
    set_runtime,
    set_status,
    show,
};

pub const CommandDef = struct {
    name: []const u8,
    command: Command,
};

const command_defs = [_]CommandDef{
    .{ .name = "init", .command = .init },
    .{ .name = "add", .command = .add },
    .{ .name = "select", .command = .select },
    .{ .name = "deselect", .command = .deselect },
    .{ .name = "set-status", .command = .set_status },
    .{ .name = "set-priority", .command = .set_priority },
    .{ .name = "set-deps", .command = .set_deps },
    .{ .name = "set-notes", .command = .set_notes },
    .{ .name = "add-comment", .command = .add_comment },
    .{ .name = "remove", .command = .remove },
    .{ .name = "show", .command = .show },
    .{ .name = "ready", .command = .ready },
    .{ .name = "blocked", .command = .blocked },
    .{ .name = "doctor", .command = .doctor },
    .{ .name = "prime", .command = .prime },
    .{ .name = "assert-projection", .command = .assert_projection },
    .{ .name = "aperture", .command = .aperture },
    .{ .name = "complete", .command = .complete },
    .{ .name = "reconcile-codex", .command = .reconcile_codex },
    .{ .name = "import-proposed-plan", .command = .import_proposed_plan },
    .{ .name = "guard-session-start", .command = .guard_session_start },
    .{ .name = "guard-pre-tool-use", .command = .guard_pre_tool_use },
    .{ .name = "graph", .command = .graph },
    .{ .name = "export", .command = .@"export" },
    .{ .name = "import-plan", .command = .import_plan },
    .{ .name = "import-orchplan", .command = .import_orchplan },
    .{ .name = "claim", .command = .claim },
    .{ .name = "compile", .command = .compile },
    .{ .name = "heartbeat", .command = .heartbeat },
    .{ .name = "set-runtime", .command = .set_runtime },
    .{ .name = "set-proof", .command = .set_proof },
    .{ .name = "proof", .command = .proof },
    .{ .name = "release", .command = .release },
    .{ .name = "reclaim-stale", .command = .reclaim_stale },
    .{ .name = "import-mesh-results", .command = .import_mesh_results },
};

pub fn commandDefs() []const CommandDef {
    return command_defs[0..];
}

pub const PerfCase = enum {
    init,
    set_status,
    set_priority,
    set_deps,
    set_notes,
    add_comment,
    remove,
    ready,
    blocked,
    doctor,
    prime,
    import_plan,
};

pub const PerfCaseDef = struct {
    name: []const u8,
    case: PerfCase,
};

const perf_case_defs = [_]PerfCaseDef{
    .{ .name = "init", .case = .init },
    .{ .name = "set-status", .case = .set_status },
    .{ .name = "set-priority", .case = .set_priority },
    .{ .name = "set-deps", .case = .set_deps },
    .{ .name = "set-notes", .case = .set_notes },
    .{ .name = "add-comment", .case = .add_comment },
    .{ .name = "remove", .case = .remove },
    .{ .name = "ready", .case = .ready },
    .{ .name = "blocked", .case = .blocked },
    .{ .name = "doctor", .case = .doctor },
    .{ .name = "prime", .case = .prime },
    .{ .name = "import-plan", .case = .import_plan },
};

pub fn perfCaseDefs() []const PerfCaseDef {
    return perf_case_defs[0..];
}

const OutputFormat = enum {
    json,
    markdown,
    plan_sync,
    table,
    text,
};

pub const Args = struct {
    command: Command,
    graph_command: GraphCommand = .none,
    polish_command: PolishCommand = .none,
    aperture_command: ApertureCommand = .none,
    compile_command: CompileCommand = .none,
    proof_command: ProofCommand = .none,
    gate: AuditGate = .draft,
    file: []const u8 = ".step/st-plan.jsonl",
    allow_multiple_in_progress: bool = false,
    format: OutputFormat = .markdown,
    surface: Surface = .plan,
    target: ProjectionTarget = .all,
    mode: ProjectionMode = .selected,
    limit: usize = 7,

    id: ?[]const u8 = null,
    ids: []const u8 = "",
    step: ?[]const u8 = null,
    status: []const u8 = "pending",
    priority: ?[]const u8 = null,
    deps: []const u8 = "",
    notes: ?[]const u8 = null,
    text: ?[]const u8 = null,
    author: ?[]const u8 = null,
    selection_status: ?[]const u8 = null,
    selection_priority: ?[]const u8 = null,
    executor: ?[]const u8 = null,
    wave: ?[]const u8 = null,
    lease_seconds: ?[]const u8 = null,
    substrate: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    row_id: ?[]const u8 = null,
    output_ref: ?[]const u8 = null,
    last_event: ?[]const u8 = null,
    proof_state: ?[]const u8 = null,
    proof_id: ?[]const u8 = null,
    evidence_ref: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    now: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    guard_root: ?[]const u8 = null,
    id_prefix: []const u8 = "st",
    start_at: ?[]const u8 = null,
    name: ?[]const u8 = null,
    pass_number: ?[]const u8 = null,
    min_stable_passes: usize = 2,
    strategy: []const u8 = "aperture-score",

    replace: bool = false,
    repair_seq: bool = false,
    output: ?[]const u8 = null,
    input: ?[]const u8 = null,
    backlog_only: bool = false,
    preview: bool = false,
    dry_run: bool = false,
    allow_unproven: bool = false,
    include_completed_context: bool = false,
    include_waiting_pending_set: bool = false,
    include_waiting_pending: bool = false,
    hook_json: bool = false,
    strict: bool = true,
    select_ready: bool = false,
    infer_linear_deps: bool = false,
};

pub fn runPerfCase(allocator: std.mem.Allocator, perf_case: PerfCase, base_dir: []const u8) !u8 {
    const plan_path = try std.fs.path.join(allocator, &.{ base_dir, "st-perf-plan.jsonl" });
    defer allocator.free(plan_path);
    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    switch (perf_case) {
        .init => return cmdInit(allocator, .{ .command = .init, .file = plan_path }),
        .set_status => {
            try seedBasicPlan(allocator, plan_path);
            return cmdSetStatus(allocator, .{
                .command = .set_status,
                .file = plan_path,
                .id = "st-001",
                .status = "completed",
            });
        },
        .set_priority => {
            try seedBasicPlan(allocator, plan_path);
            return cmdSetPriority(allocator, .{
                .command = .set_priority,
                .file = plan_path,
                .id = "st-001",
                .priority = "high",
            });
        },
        .set_deps => {
            try seedDependentPlan(allocator, plan_path);
            return cmdSetDeps(allocator, .{
                .command = .set_deps,
                .file = plan_path,
                .id = "st-002",
                .deps = "st-001",
            });
        },
        .set_notes => {
            try seedBasicPlan(allocator, plan_path);
            return cmdSetNotes(allocator, .{
                .command = .set_notes,
                .file = plan_path,
                .id = "st-001",
                .notes = "perf note",
            });
        },
        .add_comment => {
            try seedBasicPlan(allocator, plan_path);
            return cmdAddComment(allocator, .{
                .command = .add_comment,
                .file = plan_path,
                .id = "st-001",
                .text = "perf comment",
                .author = "perf",
            });
        },
        .remove => {
            try seedBasicPlan(allocator, plan_path);
            return cmdRemove(allocator, .{
                .command = .remove,
                .file = plan_path,
                .id = "st-001",
            });
        },
        .ready => {
            try seedBasicPlan(allocator, plan_path);
            return cmdReady(allocator, .{
                .command = .ready,
                .file = plan_path,
                .format = .json,
            });
        },
        .blocked => {
            try seedBlockedPlan(allocator, plan_path);
            return cmdBlocked(allocator, .{
                .command = .blocked,
                .file = plan_path,
                .format = .json,
            });
        },
        .doctor => {
            try seedBasicPlan(allocator, plan_path);
            return cmdDoctor(allocator, .{
                .command = .doctor,
                .file = plan_path,
            });
        },
        .prime => {
            try seedBasicPlan(allocator, plan_path);
            return cmdPrime(allocator, .{
                .command = .prime,
                .file = plan_path,
            });
        },
        .import_plan => {
            try seedImportPlan(allocator, base_dir, plan_path);
            const input_path = try std.fs.path.join(allocator, &.{ base_dir, "import.json" });
            defer allocator.free(input_path);
            return cmdImportPlan(allocator, .{
                .command = .import_plan,
                .file = plan_path,
                .input = input_path,
                .replace = true,
            });
        },
    }
}

const StdoutGuard = struct {
    saved_fd: std.posix.fd_t,
    devnull: std.Io.File,
};

fn silenceStdout() !StdoutGuard {
    const saved_fd = std.c.dup(std.posix.STDOUT_FILENO);
    if (saved_fd < 0) return error.SystemResources;
    const devnull = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), "/dev/null", .{ .mode = .write_only });
    if (std.c.dup2(devnull.handle, std.posix.STDOUT_FILENO) < 0) return error.SystemResources;
    return .{ .saved_fd = saved_fd, .devnull = devnull };
}

fn restoreStdout(guard: StdoutGuard) void {
    _ = std.c.dup2(guard.saved_fd, std.posix.STDOUT_FILENO);
    _ = std.c.close(guard.saved_fd);
    guard.devnull.close(std.Io.Threaded.global_single_threaded.io());
}

const ParsedRecords = struct {
    records: []std.json.Value,
    latest_seq: i64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len <= 1) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    if (core_cli.isHelpArg(argv[1])) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    if (core_cli.isVersionArg(argv[1]) or core_cli.isVersionSubcommand(argv[1])) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printVersion(stdout, Version);
        return;
    }

    if (argv.len >= 3 and core_cli.isHelpArg(argv[2])) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpSurface(stdout, HelpSurface, Version);
        return;
    }

    const args = parseArgs(argv) catch |err| {
        return exitWithError(err);
    };

    const mutating = isMutatingCommand(args.command) or
        (args.command == .graph and args.graph_command == .apply and !args.dry_run) or
        (args.command == .aperture and args.aperture_command == .select) or
        (args.command == .complete) or
        (args.command == .compile and (args.compile_command == .intent or args.compile_command == .graph or args.compile_command == .aperture));
    if (args.command == .doctor and args.repair_seq) {
        try ensureLockSidecarGitignored(allocator, args.file);
    }
    if (mutating) {
        try ensureLockSidecarGitignored(allocator, args.file);
    }

    const exit_code: u8 = runCommand(allocator, args) catch |err| {
        return exitWithError(err);
    };
    std.process.exit(exit_code);
}

fn exitWithError(err: anyerror) !void {
    core_cli.exitUsageFailure(HelpSurface, Version, @errorName(err), null);
}

fn parseArgs(argv: []const []const u8) !Args {
    if (argv.len < 2) return error.MissingCommand;

    var args = Args{
        .command = parseCommand(argv[1]) orelse return error.UnknownCommand,
    };

    var i: usize = 2;
    if (args.command == .graph) {
        if (argv.len < 3) return error.MissingCommand;
        args.graph_command = parseGraphCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
        if (args.graph_command == .polish) {
            if (argv.len < 4) return error.MissingCommand;
            args.polish_command = parsePolishCommand(argv[3]) orelse return error.UnknownCommand;
            i = 4;
        }
    }
    if (args.command == .aperture) {
        if (argv.len < 3) return error.MissingCommand;
        args.aperture_command = parseApertureCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
    }
    if (args.command == .compile) {
        if (argv.len < 3) return error.MissingCommand;
        args.compile_command = parseCompileCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
    }
    if (args.command == .proof) {
        if (argv.len < 3) return error.MissingCommand;
        args.proof_command = parseProofCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
    }
    while (i < argv.len) : (i += 1) {
        const token = argv[i];

        if (std.mem.eql(u8, token, "--file")) {
            i += 1;
            if (i >= argv.len) return error.MissingFileValue;
            args.file = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--allow-multiple-in-progress")) {
            args.allow_multiple_in_progress = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--format")) {
            i += 1;
            if (i >= argv.len) return error.MissingFormatValue;
            args.format = parseOutputFormat(argv[i]) orelse return error.InvalidFormat;
            continue;
        }
        if (std.mem.eql(u8, token, "--surface")) {
            i += 1;
            if (i >= argv.len) return error.MissingSurfaceValue;
            args.surface = parseSurface(argv[i]) orelse return error.InvalidSurface;
            continue;
        }
        if (std.mem.eql(u8, token, "--target")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.target = parseProjectionTarget(argv[i]) orelse return error.InvalidTarget;
            continue;
        }
        if (std.mem.eql(u8, token, "--limit")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.limit = try parsePositiveUsize(argv[i]);
            continue;
        }
        if (std.mem.eql(u8, token, "--include-completed-context")) {
            args.include_completed_context = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--include-waiting-pending")) {
            args.include_waiting_pending_set = true;
            args.include_waiting_pending = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--strategy")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.strategy = argv[i];
            continue;
        }

        switch (args.command) {
            .init => {
                if (std.mem.eql(u8, token, "--replace")) {
                    args.replace = true;
                    continue;
                }
                return error.InvalidInitArg;
            },
            .add => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--step")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingStepValue;
                    args.step = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--status")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingStatusValue;
                    args.status = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--deps")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingDepsValue;
                    args.deps = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--priority")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingPriorityValue;
                    args.priority = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--backlog-only")) {
                    args.backlog_only = true;
                    continue;
                }
                return error.InvalidAddArg;
            },
            .select, .deselect => {
                if (std.mem.eql(u8, token, "--ids")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdsValue;
                    args.ids = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--status")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingStatusValue;
                    args.selection_status = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--priority")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingPriorityValue;
                    args.selection_priority = argv[i];
                    continue;
                }
                return if (args.command == .select) error.InvalidSelectArg else error.InvalidDeselectArg;
            },
            .set_status => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--status")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingStatusValue;
                    args.status = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--allow-unproven")) {
                    args.allow_unproven = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--reason")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.reason = argv[i];
                    continue;
                }
                return error.InvalidSetStatusArg;
            },
            .set_priority => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--priority")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingPriorityValue;
                    args.priority = argv[i];
                    continue;
                }
                return error.InvalidSetPriorityArg;
            },
            .set_deps => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--deps")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingDepsValue;
                    args.deps = argv[i];
                    continue;
                }
                return error.InvalidSetDepsArg;
            },
            .set_notes => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--notes")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingNotesValue;
                    args.notes = argv[i];
                    continue;
                }
                return error.InvalidSetNotesArg;
            },
            .add_comment => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--text")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingTextValue;
                    args.text = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--author")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingAuthorValue;
                    args.author = argv[i];
                    continue;
                }
                return error.InvalidAddCommentArg;
            },
            .remove => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                return error.InvalidRemoveArg;
            },
            .show, .ready, .blocked => {
                return error.InvalidListArg;
            },
            .graph => {
                if (std.mem.eql(u8, token, "--input")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.input = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--gate")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.gate = parseAuditGate(argv[i]) orelse return error.InvalidGraphGate;
                    continue;
                }
                if (std.mem.eql(u8, token, "--dry-run")) {
                    args.dry_run = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--name")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.name = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--pass")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.pass_number = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--min-stable-passes")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.min_stable_passes = try parsePositiveUsize(argv[i]);
                    continue;
                }
                return error.InvalidGraphArg;
            },
            .aperture => {
                if (std.mem.eql(u8, token, "--replace")) {
                    args.replace = true;
                    continue;
                }
                return error.InvalidApertureArg;
            },
            .compile => {
                if (std.mem.eql(u8, token, "--input")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.input = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--gate")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.gate = parseAuditGate(argv[i]) orelse return error.InvalidGraphGate;
                    continue;
                }
                return error.InvalidCompileArg;
            },
            .doctor => {
                if (std.mem.eql(u8, token, "--repair-seq")) {
                    args.repair_seq = true;
                    continue;
                }
                return error.InvalidDoctorArg;
            },
            .claim => {
                if (std.mem.eql(u8, token, "--ids")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdsValue;
                    args.ids = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--executor")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.executor = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--wave")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.wave = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--lease-seconds")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.lease_seconds = argv[i];
                    continue;
                }
                return error.InvalidClaimArg;
            },
            .heartbeat => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                return error.InvalidHeartbeatArg;
            },
            .prime => {
                if (std.mem.eql(u8, token, "--mode")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.mode = parseProjectionMode(argv[i]) orelse return error.InvalidProjectionMode;
                    continue;
                }
                if (std.mem.eql(u8, token, "--preview")) {
                    args.preview = true;
                    continue;
                }
                return error.InvalidPrimeArg;
            },
            .assert_projection => {
                if (std.mem.eql(u8, token, "--strict")) {
                    args.strict = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--no-strict")) {
                    args.strict = false;
                    continue;
                }
                return error.InvalidAssertProjectionArg;
            },
            .guard_session_start => {
                if (std.mem.eql(u8, token, "--session-id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.session_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--guard-root")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.guard_root = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--hook-json")) {
                    args.hook_json = true;
                    continue;
                }
                return error.InvalidEmitArg;
            },
            .guard_pre_tool_use => {
                if (std.mem.eql(u8, token, "--session-id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.session_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--transcript-path")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.transcript_path = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--guard-root")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.guard_root = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--hook-json")) {
                    args.hook_json = true;
                    continue;
                }
                return error.InvalidImportArg;
            },
            .reconcile_codex => {
                if (std.mem.eql(u8, token, "--input")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.input = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--transcript-path")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.transcript_path = argv[i];
                    continue;
                }
                return error.InvalidImportArg;
            },
            .@"export" => {
                if (std.mem.eql(u8, token, "--output")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingOutputValue;
                    args.output = argv[i];
                    continue;
                }
                return error.InvalidExportArg;
            },
            .import_plan => {
                if (std.mem.eql(u8, token, "--input")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.input = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--replace")) {
                    args.replace = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--backlog-only")) {
                    args.backlog_only = true;
                    continue;
                }
                return error.InvalidImportArg;
            },
            .import_orchplan => {
                if (std.mem.eql(u8, token, "--input")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.input = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--replace")) {
                    args.replace = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--backlog-only")) {
                    args.backlog_only = true;
                    continue;
                }
                return error.InvalidImportArg;
            },
            .import_proposed_plan => {
                if (std.mem.eql(u8, token, "--input")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.input = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--replace")) {
                    args.replace = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--backlog-only")) {
                    args.backlog_only = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--select-ready")) {
                    args.select_ready = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--id-prefix")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.id_prefix = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--start-at")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.start_at = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--infer-linear-deps")) {
                    args.infer_linear_deps = true;
                    continue;
                }
                return error.InvalidImportArg;
            },
            .set_runtime => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--substrate")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.substrate = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--thread-id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.thread_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--agent-id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.agent_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--row-id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.row_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--output-ref")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.output_ref = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--last-event")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.last_event = argv[i];
                    continue;
                }
                return error.InvalidSetRuntimeArg;
            },
            .set_proof => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--proof-state")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.proof_state = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--command")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.step = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--evidence-ref")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.evidence_ref = argv[i];
                    continue;
                }
                return error.InvalidSetProofArg;
            },
            .complete => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--proof")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.proof_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--command")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.step = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--evidence-ref")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.evidence_ref = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--allow-unproven")) {
                    args.allow_unproven = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--reason")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.reason = argv[i];
                    continue;
                }
                return error.InvalidCompleteArg;
            },
            .proof => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                return error.InvalidProofArg;
            },
            .release => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--reason")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.reason = argv[i];
                    continue;
                }
                return error.InvalidReleaseArg;
            },
            .reclaim_stale => {
                if (std.mem.eql(u8, token, "--now")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.now = argv[i];
                    continue;
                }
                return error.InvalidReclaimArg;
            },
            .import_mesh_results => {
                if (std.mem.eql(u8, token, "--input")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.input = argv[i];
                    continue;
                }
                return error.InvalidImportArg;
            },
        }
    }

    switch (args.command) {
        .add => if (args.step == null) return error.MissingStepValue,
        .select, .deselect => {
            if (std.mem.trim(u8, args.ids, " \t\r\n").len == 0 and args.selection_status == null and args.selection_priority == null) {
                return error.MissingSelectionCriteria;
            }
        },
        .set_status => {
            if (args.id == null) return error.MissingIdValue;
        },
        .set_priority => {
            if (args.id == null) return error.MissingIdValue;
            if (args.priority == null) return error.MissingPriorityValue;
        },
        .set_deps => {
            if (args.id == null) return error.MissingIdValue;
        },
        .set_notes => {
            if (args.id == null) return error.MissingIdValue;
            if (args.notes == null) return error.MissingNotesValue;
        },
        .add_comment => {
            if (args.id == null) return error.MissingIdValue;
            if (args.text == null) return error.MissingTextValue;
        },
        .remove => if (args.id == null) return error.MissingIdValue,
        .import_plan => if (args.input == null) return error.MissingInputValue,
        .reconcile_codex => {
            if (args.input == null and args.transcript_path == null) return error.MissingInputValue;
            if (args.input != null and args.transcript_path != null) return error.InvalidImportArg;
        },
        .guard_session_start, .guard_pre_tool_use => if (args.session_id == null) return error.MissingValue,
        .import_orchplan => if (args.input == null) return error.MissingInputValue,
        .import_proposed_plan => if (args.input == null) return error.MissingInputValue,
        .claim => {
            if (args.executor == null) return error.MissingValue;
            if (args.wave == null and std.mem.trim(u8, args.ids, " \t\r\n").len == 0) {
                return error.MissingIdsValue;
            }
        },
        .heartbeat => if (args.id == null) return error.MissingIdValue,
        .set_runtime => {
            if (args.id == null) return error.MissingIdValue;
            if (args.substrate == null) return error.MissingValue;
        },
        .set_proof => {
            if (args.id == null) return error.MissingIdValue;
            if (args.proof_state == null) return error.MissingValue;
            if (args.step == null) return error.MissingValue;
        },
        .release => if (args.id == null) return error.MissingIdValue,
        .import_mesh_results => if (args.input == null) return error.MissingInputValue,
        .graph => {
            if (args.graph_command == .apply and args.input == null) return error.MissingInputValue;
            if (args.graph_command == .polish and args.polish_command == .begin and args.name == null) return error.MissingValue;
            if (args.graph_command == .polish and args.polish_command == .snapshot and args.pass_number == null) return error.MissingValue;
        },
        .compile => {
            if ((args.compile_command == .intent or args.compile_command == .graph) and args.input == null) return error.MissingInputValue;
        },
        else => {},
    }

    return args;
}

fn parseCommand(raw: []const u8) ?Command {
    for (command_defs) |def| {
        if (std.mem.eql(u8, raw, def.name)) return def.command;
    }
    return null;
}

fn parseGraphCommand(raw: []const u8) ?GraphCommand {
    if (std.mem.eql(u8, raw, "schema")) return .schema;
    if (std.mem.eql(u8, raw, "apply")) return .apply;
    if (std.mem.eql(u8, raw, "audit")) return .audit;
    if (std.mem.eql(u8, raw, "insights")) return .insights;
    if (std.mem.eql(u8, raw, "polish")) return .polish;
    return null;
}

fn parsePolishCommand(raw: []const u8) ?PolishCommand {
    if (std.mem.eql(u8, raw, "begin")) return .begin;
    if (std.mem.eql(u8, raw, "snapshot")) return .snapshot;
    if (std.mem.eql(u8, raw, "status")) return .status;
    if (std.mem.eql(u8, raw, "gate")) return .gate;
    return null;
}

fn parseApertureCommand(raw: []const u8) ?ApertureCommand {
    if (std.mem.eql(u8, raw, "next")) return .next;
    if (std.mem.eql(u8, raw, "plan")) return .plan;
    if (std.mem.eql(u8, raw, "select")) return .select;
    if (std.mem.eql(u8, raw, "explain")) return .explain;
    return null;
}

fn parseCompileCommand(raw: []const u8) ?CompileCommand {
    if (std.mem.eql(u8, raw, "intent")) return .intent;
    if (std.mem.eql(u8, raw, "graph")) return .graph;
    if (std.mem.eql(u8, raw, "ready")) return .ready;
    if (std.mem.eql(u8, raw, "aperture")) return .aperture;
    return null;
}

fn parseProofCommand(raw: []const u8) ?ProofCommand {
    if (std.mem.eql(u8, raw, "audit")) return .audit;
    return null;
}

fn parseAuditGate(raw: []const u8) ?AuditGate {
    if (std.mem.eql(u8, raw, "draft")) return .draft;
    if (std.mem.eql(u8, raw, "implementation-ready")) return .implementation_ready;
    if (std.mem.eql(u8, raw, "execution-ready")) return .execution_ready;
    if (std.mem.eql(u8, raw, "proof-complete")) return .proof_complete;
    return null;
}

fn parseOutputFormat(raw: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, raw, "markdown")) return .markdown;
    if (std.mem.eql(u8, raw, "table")) return .table;
    if (std.mem.eql(u8, raw, "json")) return .json;
    if (std.mem.eql(u8, raw, "plan-sync")) return .plan_sync;
    if (std.mem.eql(u8, raw, "text")) return .text;
    return null;
}

fn parseSurface(raw: []const u8) ?Surface {
    if (std.mem.eql(u8, raw, "plan")) return .plan;
    if (std.mem.eql(u8, raw, "all")) return .all;
    if (std.mem.eql(u8, raw, "backlog")) return .backlog;
    return null;
}

fn parseProjectionTarget(raw: []const u8) ?ProjectionTarget {
    if (std.mem.eql(u8, raw, "codex")) return .codex;
    if (std.mem.eql(u8, raw, "opencode")) return .opencode;
    if (std.mem.eql(u8, raw, "all")) return .all;
    return null;
}

fn parseProjectionMode(raw: []const u8) ?ProjectionMode {
    if (std.mem.eql(u8, raw, "selected")) return .selected;
    if (std.mem.eql(u8, raw, "aperture")) return .aperture;
    if (std.mem.eql(u8, raw, "auto-top-up")) return .auto_top_up;
    if (std.mem.eql(u8, raw, "auto_top_up")) return .auto_top_up;
    if (std.mem.eql(u8, raw, "replace-ready")) return .replace_ready;
    if (std.mem.eql(u8, raw, "replace_ready")) return .replace_ready;
    return null;
}

fn parsePositiveUsize(raw: []const u8) !usize {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const value = try std.fmt.parseInt(usize, trimmed, 10);
    if (value == 0) return error.InvalidLimit;
    return value;
}

fn parsePositiveI64(raw: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const value = try std.fmt.parseInt(i64, trimmed, 10);
    if (value <= 0) return error.InvalidLimit;
    return value;
}

fn isMutatingCommand(command: Command) bool {
    return switch (command) {
        .init,
        .add,
        .select,
        .deselect,
        .set_status,
        .set_priority,
        .set_deps,
        .set_notes,
        .add_comment,
        .remove,
        .prime,
        .reconcile_codex,
        .import_proposed_plan,
        .guard_session_start,
        .guard_pre_tool_use,
        .import_plan,
        .import_orchplan,
        .claim,
        .heartbeat,
        .set_runtime,
        .set_proof,
        .release,
        .reclaim_stale,
        .import_mesh_results,
        => true,
        else => false,
    };
}

fn seedBasicPlan(allocator: std.mem.Allocator, plan_path: []const u8) !void {
    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "Seed item",
        .priority = "medium",
    });
}

fn seedDependentPlan(allocator: std.mem.Allocator, plan_path: []const u8) !void {
    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "Parent",
        .priority = "medium",
        .status = "pending",
    });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-002",
        .step = "Child",
        .priority = "medium",
    });
}

fn seedBlockedPlan(allocator: std.mem.Allocator, plan_path: []const u8) !void {
    try seedDependentPlan(allocator, plan_path);
    _ = try cmdSetDeps(allocator, .{
        .command = .set_deps,
        .file = plan_path,
        .id = "st-002",
        .deps = "st-001",
    });
}

fn seedImportPlan(allocator: std.mem.Allocator, base_dir: []const u8, plan_path: []const u8) !void {
    const export_path = try std.fs.path.join(allocator, &.{ base_dir, "import.json" });
    defer allocator.free(export_path);
    try seedBasicPlan(allocator, plan_path);
    _ = try cmdExport(allocator, .{
        .command = .@"export",
        .file = plan_path,
        .output = export_path,
    });
    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
}

const SelectionMode = enum {
    select,
    deselect,
};

fn collectSelectionTargetIds(
    allocator: std.mem.Allocator,
    state: *ItemState,
    args: Args,
) ![][]const u8 {
    var selected = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(allocator);

    const explicit_ids = try parseCliIds(allocator, args.ids);
    for (explicit_ids) |item_id| {
        const item = state.getConst(item_id) orelse return error.UnknownItemId;
        if (seen.get(item.id) == null) {
            try seen.put(item.id, {});
            try selected.append(allocator, item.id);
        }
    }

    const status_filter = if (args.selection_status) |raw| try normalizeStatus(raw) else null;
    const priority_filter = if (args.selection_priority) |raw| try normalizePriority(raw) else null;

    if (status_filter != null or priority_filter != null) {
        for (state.items.items) |item| {
            if (status_filter) |filter_status| {
                if (item.status != filter_status) continue;
            }
            if (priority_filter) |filter_priority| {
                if (item.priority != filter_priority) continue;
            }
            if (seen.get(item.id) == null) {
                try seen.put(item.id, {});
                try selected.append(allocator, item.id);
            }
        }
    }

    if (selected.items.len == 0) return error.NoMatchingSelectionTargets;
    return selected.toOwnedSlice(allocator);
}

fn parseCliIds(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return &.{};

    var out = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(allocator);
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |token_raw| {
        const item_id = try requireNonEmptyString(allocator, token_raw, "selection id");
        if (seen.get(item_id) != null) continue;
        try seen.put(item_id, {});
        try out.append(allocator, item_id);
    }
    return out.toOwnedSlice(allocator);
}

fn collectOrchplanWaveTargetIds(
    allocator: std.mem.Allocator,
    state: *const ItemState,
    wave_id: []const u8,
) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| {
        const source = item.source orelse continue;
        if (!std.mem.eql(u8, source.kind, "orchplan")) continue;
        if (!std.mem.eql(u8, source.wave_id, wave_id)) continue;
        try out.append(allocator, item.id);
    }
    return out.toOwnedSlice(allocator);
}

fn applySelectionChange(
    allocator: std.mem.Allocator,
    state: *ItemState,
    target_ids: [][]const u8,
    mode: SelectionMode,
) !void {
    switch (mode) {
        .select => {
            var to_select = std.StringHashMap(void).init(allocator);
            for (target_ids) |item_id| {
                try collectSelectionClosure(allocator, state, item_id, &to_select);
            }
            var it = to_select.iterator();
            while (it.next()) |entry| {
                state.get(entry.key_ptr.*).?.in_plan = true;
            }
        },
        .deselect => {
            for (target_ids) |item_id| {
                const item = state.get(item_id) orelse return error.UnknownItemId;
                if (item.status == .in_progress) return error.CannotDeselectInProgress;
                item.in_plan = false;
            }
        },
    }
}

fn applyPrimeSelection(
    allocator: std.mem.Allocator,
    state: *ItemState,
    mode: ProjectionMode,
    limit: usize,
) !bool {
    var frontier = std.ArrayList([]const u8).empty;

    if (findValidExistingInProgress(state)) |id| {
        try frontier.append(allocator, id);
    }

    switch (mode) {
        .selected => {},
        .aperture => {
            const selected = try selectApertureIds(allocator, state, limit);
            for (selected) |id| try frontier.append(allocator, id);
        },
        .auto_top_up, .replace_ready => {
            if (mode == .auto_top_up) {
                for (state.items.items) |item| {
                    if (frontier.items.len >= limit) break;
                    if (!effectiveInPlan(item)) continue;
                    if (item.status == .pending and try isReadyPendingItem(allocator, state, item)) {
                        if (!containsString(frontier.items, item.id)) try frontier.append(allocator, item.id);
                    }
                }
            }
            const priorities = [_]Priority{ .high, .medium, .low };
            for (priorities) |priority| {
                for (state.items.items) |item| {
                    if (frontier.items.len >= limit) break;
                    if (effectiveInPlan(item) and mode == .auto_top_up) continue;
                    if (item.priority != priority) continue;
                    if (item.status != .pending) continue;
                    if (!try isReadyPendingItem(allocator, state, item)) continue;
                    if (!containsString(frontier.items, item.id)) try frontier.append(allocator, item.id);
                }
            }
        },
    }

    var changed = false;
    if (mode == .replace_ready or mode == .aperture) {
        for (state.items.items) |*item| {
            const should_select = containsString(frontier.items, item.id);
            if (item.in_plan != should_select) {
                item.in_plan = should_select;
                changed = true;
            }
            normalizeItemPlanMembership(item);
        }
        return changed;
    }
    if (mode == .auto_top_up) {
        for (frontier.items) |id| {
            const item = state.get(id) orelse return error.UnknownItemId;
            if (!item.in_plan) {
                item.in_plan = true;
                changed = true;
            }
        }
    }
    for (state.items.items) |*item| {
        const before = item.in_plan;
        normalizeItemPlanMembership(item);
        if (item.in_plan != before) changed = true;
    }
    return changed;
}

fn findValidExistingInProgress(state: *const ItemState) ?[]const u8 {
    for (state.items.items) |item| {
        if (item.status == .in_progress and effectiveInPlan(item)) return item.id;
    }
    return null;
}

fn isReadyPendingItem(allocator: std.mem.Allocator, state: *const ItemState, item: Item) !bool {
    if (item.status != .pending) return false;
    if (item.claim) |claim| {
        if (claim.state == .held or claim.state == .stale) return false;
    }
    const waiting = try unresolvedDependencyIds(allocator, item, state);
    return waiting.len == 0;
}

fn collectSelectionClosure(
    allocator: std.mem.Allocator,
    state: *ItemState,
    item_id: []const u8,
    selected: *std.StringHashMap(void),
) !void {
    if (selected.get(item_id) != null) return;
    const item = state.get(item_id) orelse return error.UnknownItemId;
    if (isTerminalStatus(item.status)) return error.TerminalTaskCannotBeSelected;

    try selected.put(item.id, {});
    for (item.deps) |dep| {
        const dep_item = state.get(dep.id) orelse return error.UnknownDependency;
        if (dep_item.status == .completed) continue;
        if (isTerminalStatus(dep_item.status)) return error.TerminalDependencyCannotBeSelected;
        try collectSelectionClosure(allocator, state, dep.id, selected);
    }
}

fn runCommand(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.command) {
        .init => try cmdInit(allocator, args),
        .add => try cmdAdd(allocator, args),
        .select => try cmdSelect(allocator, args),
        .deselect => try cmdDeselect(allocator, args),
        .set_status => try cmdSetStatus(allocator, args),
        .set_priority => try cmdSetPriority(allocator, args),
        .set_deps => try cmdSetDeps(allocator, args),
        .set_notes => try cmdSetNotes(allocator, args),
        .add_comment => try cmdAddComment(allocator, args),
        .remove => try cmdRemove(allocator, args),
        .show => try cmdShow(allocator, args),
        .ready => try cmdReady(allocator, args),
        .blocked => try cmdBlocked(allocator, args),
        .claim => try cmdClaim(allocator, args),
        .complete => try cmdComplete(allocator, args),
        .doctor => try cmdDoctor(allocator, args),
        .prime => try cmdPrime(allocator, args),
        .proof => try cmdProof(allocator, args),
        .assert_projection => try cmdAssertProjection(allocator, args),
        .guard_session_start => try cmdGuardSessionStart(allocator, args),
        .guard_pre_tool_use => try cmdGuardPreToolUse(allocator, args),
        .heartbeat => try cmdHeartbeat(allocator, args),
        .reconcile_codex => try cmdReconcileCodex(allocator, args),
        .@"export" => try cmdExport(allocator, args),
        .import_plan => try cmdImportPlan(allocator, args),
        .import_orchplan => try cmdImportOrchplan(allocator, args),
        .import_proposed_plan => try cmdImportProposedPlan(allocator, args),
        .set_runtime => try cmdSetRuntime(allocator, args),
        .set_proof => try cmdSetProof(allocator, args),
        .release => try cmdRelease(allocator, args),
        .reclaim_stale => try cmdReclaimStale(allocator, args),
        .import_mesh_results => try cmdImportMeshResults(allocator, args),
        .graph => try cmdGraph(allocator, args),
        .aperture => try cmdAperture(allocator, args),
        .compile => try cmdCompile(allocator, args),
    };
}

pub fn runPerfArgs(allocator: std.mem.Allocator, args: Args) !u8 {
    return runCommand(allocator, args);
}

fn cmdInit(allocator: std.mem.Allocator, args: Args) !u8 {
    const path = args.file;
    const exists = fileExists(path);
    if (!exists or (try fileSize(path)) == 0) {
        const ts = try nowUtcAlloc(allocator);
        try writeInitRecord(allocator, path, ts);
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("initialized {s}\n", .{path});
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("already initialized: {s}\n", .{path});
    }

    if (args.replace) {
        const parsed = try readRecords(allocator, path);
        var state = ItemState.init(allocator);
        defer state.deinit();
        const meta = buildMutationMeta(allocator, true);
        const ts = try nowUtcAlloc(allocator);
        try writeCanonicalRecords(path, &state, parsed.latest_seq + 1, ts, meta, null);

        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("cleared plan in {s}\n", .{path});
    }

    return 0;
}

fn cmdAdd(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = if (args.id) |raw_id|
        try requireNonEmptyString(allocator, raw_id, "--id")
    else
        try nextIdAlloc(allocator, &state);

    const step = try requireNonEmptyString(allocator, args.step.?, "--step");
    const status = try normalizeStatus(args.status);
    const priority = try normalizePriority(args.priority orelse "medium");
    const deps = try parseCliDeps(allocator, args.deps);

    const item = Item{
        .id = item_id,
        .step = step,
        .status = status,
        .priority = priority,
        .in_plan = !args.backlog_only,
        .deps = deps,
        .notes = "",
        .comments = &.{},
    };

    var normalized_item = item;
    normalizeItemPlanMembership(&normalized_item);
    try state.upsert(normalized_item);
    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("upserted {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdSelect(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const target_ids = try collectSelectionTargetIds(allocator, &state, args);
    try applySelectionChange(allocator, &state, target_ids, .select);
    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("selected {d} item(s)\n", .{target_ids.len});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdDeselect(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const target_ids = try collectSelectionTargetIds(allocator, &state, args);
    try applySelectionChange(allocator, &state, target_ids, .deselect);
    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("deselected {d} item(s)\n", .{target_ids.len});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdSetStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const status = try normalizeStatus(args.status);
    const item = state.get(item_id) orelse return error.UnknownItemId;
    if (status == .completed and state.graph_active and state.graph.policy.completion_requires_proof and isExecutableItem(item.*)) {
        if (proofCompletionMissingReason(item.*)) |missing| {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            if (!args.allow_unproven) {
                try stdout.print("completion blocked for {s}: {s}\n", .{ item_id, missing });
                return 2;
            }
            const waiver_reason = try requireNonEmptyString(allocator, args.reason orelse return error.MissingReason, "--reason");
            state.graph_active = true;
            const now = try nowUtcAlloc(allocator);
            try addForcedCompletionWaivers(allocator, &state, item_id, waiver_reason, now);
        }
    }
    item.status = status;
    normalizeItemPlanMembership(item);

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("updated {s} -> {s}\n", .{ item_id, status.asString() });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdSetPriority(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const priority = try normalizePriority(args.priority.?);
    const item = state.get(item_id) orelse return error.UnknownItemId;
    item.priority = priority;

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("updated {s} priority -> {s}\n", .{ item_id, priority.asString() });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdSetDeps(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const deps = try parseCliDeps(allocator, args.deps);
    const item = state.get(item_id) orelse return error.UnknownItemId;
    item.deps = deps;

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (deps.len == 0) {
        try stdout.print("updated {s} deps -> (none)\n", .{item_id});
    } else {
        try stdout.print("updated {s} deps -> ", .{item_id});
        for (deps, 0..) |dep, idx| {
            if (idx > 0) try stdout.writeAll(", ");
            if (std.mem.eql(u8, dep.type, "blocks")) {
                try stdout.writeAll(dep.id);
            } else {
                try stdout.print("{s}:{s}", .{ dep.id, dep.type });
            }
        }
        try stdout.writeByte('\n');
    }
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdSetNotes(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const notes = args.notes.?;
    const item = state.get(item_id) orelse return error.UnknownItemId;
    item.notes = notes;

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("updated {s} notes\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdAddComment(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const text = try requireNonEmptyString(allocator, args.text.?, "--text");
    const author = if (args.author) |a| try requireNonEmptyString(allocator, a, "--author") else defaultCommentAuthor();

    const ts = try nowUtcAlloc(allocator);
    const comment = Comment{ .ts = ts, .author = author, .text = text };

    const item = state.get(item_id) orelse return error.UnknownItemId;
    var comments = std.ArrayList(Comment).empty;
    try comments.appendSlice(allocator, item.comments);
    try comments.append(allocator, comment);
    item.comments = try comments.toOwnedSlice(allocator);

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("added comment to {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdRemove(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    if (state.get(item_id) == null) return error.UnknownItemId;
    try state.remove(item_id);
    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("removed {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdShow(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try renderShow(allocator, stdout, &state, args.format, args.surface);
    return 0;
}

fn cmdReady(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const enriched = try enrichItems(allocator, &state);
    var rows = std.ArrayList(EnrichedItem).empty;
    for (enriched) |row| {
        if (row.item.status == .pending and row.dep_state == .ready) {
            try rows.append(allocator, row);
        }
    }
    const filtered_rows = try filterRowsBySurface(allocator, rows.items, args.surface);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try renderItemRows(allocator, stdout, filtered_rows, args.format);
    return 0;
}

fn cmdBlocked(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const enriched = try enrichItems(allocator, &state);
    var rows = std.ArrayList(EnrichedItem).empty;
    for (enriched) |row| {
        if (row.item.status == .blocked or (row.item.status == .pending and row.dep_state == .waiting_on_deps)) {
            try rows.append(allocator, row);
        }
    }
    const filtered_rows = try filterRowsBySurface(allocator, rows.items, args.surface);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try renderItemRows(allocator, stdout, filtered_rows, args.format);
    return 0;
}

fn cmdPrime(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const include_waiting = if (args.include_waiting_pending_set)
        args.include_waiting_pending
    else
        args.mode == .selected;
    const changed = try applyPrimeSelection(allocator, &state, args.mode, args.limit);
    try validateState(&state, args.allow_multiple_in_progress);

    var seq = loaded.latest_seq;
    if (!args.preview and changed) {
        seq = loaded.latest_seq + 1;
        const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
        const ts = try nowUtcAlloc(allocator);
        try writeCanonicalRecords(args.file, &state, seq, ts, meta, null);
    }

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    const policy = ProjectionPolicy{
        .target = args.target,
        .mode = args.mode,
        .limit = args.limit,
        .include_completed_context = args.include_completed_context,
        .include_waiting_pending = include_waiting,
        .source_file = args.file,
        .source_seq = seq,
    };
    if (args.format == .json) {
        try emitPlanSyncWithPolicy(allocator, stdout, &state, policy, false);
    } else {
        try emitPlanSyncWithPolicy(allocator, stdout, &state, policy, true);
    }
    return 0;
}

fn cmdAssertProjection(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const include_waiting = if (args.include_waiting_pending_set)
        args.include_waiting_pending
    else
        true;
    const target = if (args.target == .all) .codex else args.target;
    const policy = ProjectionPolicy{
        .target = target,
        .mode = args.mode,
        .limit = args.limit,
        .include_completed_context = args.include_completed_context,
        .include_waiting_pending = include_waiting,
        .source_file = args.file,
        .source_seq = loaded.latest_seq,
    };
    const result = try computeProjectionResult(allocator, &state, policy);

    var ok = true;
    var failures = std.ArrayList([]const u8).empty;
    try assertCodexProjectionResult(allocator, &state, result, &ok, &failures);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try writerAssertProjectionJson(stdout, ok, result, failures.items);
    } else if (ok) {
        if (result.empty_reason) |reason| {
            try stdout.print("projection ok: empty ({s})\n", .{reason});
        } else {
            try stdout.print("projection ok: {d} Codex row(s)\n", .{result.codex_plan.len});
        }
    } else {
        try stdout.writeAll("projection invalid\n");
        for (failures.items) |failure| try stdout.print("- {s}\n", .{failure});
    }
    return if (ok) 0 else 2;
}

fn cmdGuardSessionStart(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const policy = ProjectionPolicy{ .target = .codex, .source_file = args.file, .source_seq = loaded.latest_seq };
    const result = try computeProjectionResult(allocator, &state, policy);
    if (result.codex_plan.len == 0) {
        try deleteSessionGuardState(allocator, args.session_id.?, args.guard_root);
        if (args.hook_json) {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            try stdout.writeAll("{\"continue\":true}\n");
        }
        return 0;
    }

    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();
    try writeCodexUpdatePlanPayload(&payload_writer.writer, result.codex_plan);
    const raw_payload = try payload_writer.toOwnedSlice();
    const payload = std.mem.trim(u8, raw_payload, "\n");
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);

    try writeSessionGuardState(allocator, .{
        .session_id = args.session_id.?,
        .plan_file = args.file,
        .expected_update_plan = payload,
        .expected_selected_ids = result.selected_ids,
        .cwd = cwd,
    }, args.guard_root);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.hook_json) {
        try stdout.writeAll("{\"continue\":true,\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":");
        const context = try std.fmt.allocPrint(
            allocator,
            "st has a pending Codex update_plan mirror. Before Bash/apply_patch work, call update_plan with exactly this payload: {s}. update_plan is invalid while Codex is in Plan Mode.",
            .{payload},
        );
        try std.json.Stringify.value(context, .{}, stdout);
        try stdout.writeAll("}}\n");
    } else {
        try stdout.writeAll(payload);
        try stdout.writeByte('\n');
    }
    return 0;
}

fn cmdGuardPreToolUse(allocator: std.mem.Allocator, args: Args) !u8 {
    const maybe_guard = try readSessionGuardState(allocator, args.session_id.?, args.guard_root);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    if (maybe_guard == null) {
        if (args.hook_json) {
            try stdout.writeAll("{\"continue\":true}\n");
        } else {
            try stdout.writeAll("{\"decision\":\"allow\"}\n");
        }
        return 0;
    }

    const guard = maybe_guard.?;
    const transcript_path = args.transcript_path orelse {
        try writeGuardDeny(stdout, args.hook_json, "SessionStart $st guard is pending and transcript_path is unavailable.");
        return 0;
    };

    const latest_arguments = try latestUpdatePlanArgumentsFromTranscript(allocator, transcript_path);
    if (latest_arguments) |arguments| {
        if (try updatePlanPayloadsSemanticallyEqual(allocator, arguments, guard.expected_update_plan)) {
            try deleteSessionGuardState(allocator, args.session_id.?, args.guard_root);
            if (args.hook_json) {
                try stdout.writeAll("{\"continue\":true}\n");
            } else {
                try stdout.writeAll("{\"decision\":\"allow\"}\n");
            }
            return 0;
        }
    }

    try writeGuardDeny(stdout, args.hook_json, "Run update_plan with the exact $st SessionStart payload before mutating tool use.");
    return 0;
}

fn cmdReconcileCodex(allocator: std.mem.Allocator, args: Args) !u8 {
    const imported_entries = if (args.transcript_path) |transcript_path|
        try parseUpdatePlanEntriesFromTranscript(allocator, transcript_path)
    else
        try parseUpdatePlanEntriesFromInputFile(allocator, args.input.?);

    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const changed = try applyCodexUpdatePlanImport(allocator, &state, imported_entries, args.allow_multiple_in_progress);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    if (changed) {
        const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
        const ts = try nowUtcAlloc(allocator);
        try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);
        if (args.transcript_path) |transcript_path| {
            try stdout.print("reconciled Codex plan from transcript {s}\n", .{transcript_path});
        } else {
            try stdout.print("reconciled Codex plan from {s}\n", .{args.input.?});
        }
    } else {
        if (args.transcript_path) |transcript_path| {
            try stdout.print("Codex plan already in sync with {s}\n", .{transcript_path});
        } else {
            try stdout.print("Codex plan already in sync with {s}\n", .{args.input.?});
        }
    }

    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, if (changed) loaded.latest_seq + 1 else loaded.latest_seq);
    return 0;
}

fn cmdExport(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    var out_writer: std.Io.Writer.Allocating = .init(allocator);
    defer out_writer.deinit();
    try writeSnapshotJson(&out_writer.writer, &state);
    try out_writer.writer.writeByte('\n');

    const payload = try out_writer.toOwnedSlice();

    if (args.output) |output_path| {
        try writeTextAtomic(allocator, output_path, payload);
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("wrote {s}\n", .{output_path});
    } else {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(payload);
    }

    return 0;
}

fn cmdImportPlan(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const input_bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);
    const parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, input_bytes, .{});
    const imported = try parseSnapshotPlan(allocator, parsed_snapshot.value);
    if (args.backlog_only) {
        for (imported.items) |*item| {
            item.in_plan = false;
            normalizeItemPlanMembership(item);
        }
    }

    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    if (args.replace) {
        state.clear();
        state.graph = if (imported.graph_active) imported.graph else .{};
        state.graph_active = imported.graph_active;
        for (imported.items) |item| {
            try state.upsert(item);
        }
    } else {
        if (imported.graph_active) {
            state.graph = imported.graph;
            state.graph_active = true;
        }
        for (imported.items) |item| {
            try state.upsert(item);
        }
    }

    try validateState(&state, args.allow_multiple_in_progress);

    const bump: i64 = if (args.replace) 1 else @intCast(@max(imported.items.len, 1));
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + bump, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.replace) {
        try stdout.print("replaced plan from {s}\n", .{input_path});
    } else {
        try stdout.print("imported {d} item(s) from {s}\n", .{ imported.items.len, input_path });
    }
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + bump);
    return 0;
}

fn cmdGraph(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.graph_command) {
        .schema => try cmdGraphSchema(allocator, args),
        .apply => try cmdGraphApply(allocator, args),
        .audit => try cmdGraphAudit(allocator, args),
        .insights => try cmdGraphInsights(allocator, args),
        .polish => try cmdGraphPolish(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdGraphSchema(allocator: std.mem.Allocator, args: Args) !u8 {
    _ = allocator;
    _ = args;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        "{\"version\":1,\"ops\":[\"upsert-intent\",\"waive-intent\",\"upsert-item\",\"remove-item\",\"set-status\",\"set-priority\",\"set-contract\",\"set-acceptance\",\"set-validation\",\"set-location\",\"set-scope\",\"set-labels\",\"set-lock-roots\",\"add-dep\",\"remove-dep\",\"add-link\",\"remove-link\",\"reparent\",\"add-comment\",\"waive-audit\"],\"gates\":[\"draft\",\"implementation-ready\",\"execution-ready\",\"proof-complete\"]}\n",
    );
    return 0;
}

fn cmdGraphAudit(allocator: std.mem.Allocator, args: Args) !u8 {
    _ = args.allow_multiple_in_progress;
    const parsed = try readRecords(allocator, args.file);
    var state = try materializeStateFromRecords(allocator, parsed.records);
    defer state.deinit();

    const audit = try auditGraph(allocator, &state, args.gate);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try writeAuditResultJson(stdout, &state, audit);
        try stdout.writeByte('\n');
    } else {
        try writeAuditResultMarkdown(stdout, audit);
    }
    return if (audit.errors == 0) 0 else 2;
}

fn cmdGraphInsights(allocator: std.mem.Allocator, args: Args) !u8 {
    const parsed = try readRecords(allocator, args.file);
    var state = try materializeStateFromRecords(allocator, parsed.records);
    defer state.deinit();

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try writeGraphInsightsJson(allocator, stdout, &state);
        try stdout.writeByte('\n');
    } else {
        try writeGraphInsightsMarkdown(allocator, stdout, &state);
    }
    return 0;
}

fn cmdGraphPolish(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.polish_command) {
        .begin => try cmdGraphPolishBegin(allocator, args),
        .snapshot => try cmdGraphPolishSnapshot(allocator, args),
        .status => try cmdGraphPolishStatus(allocator, args),
        .gate => try cmdGraphPolishGate(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdGraphPolishBegin(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();
    state.graph_active = true;
    state.graph.polish = .{ .session_id = args.name.?, .passes = &.{} };
    const fps = try computeGraphFingerprints(allocator, &state);
    state.graph.fingerprints = fps;
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.print("polish session started: {s}\n", .{args.name.?});
    return 0;
}

fn cmdGraphPolishSnapshot(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();
    state.graph_active = true;
    const pass_no = try parsePositiveI64(args.pass_number.?);
    const fps = try computeGraphFingerprints(allocator, &state);
    const audit = try auditGraph(allocator, &state, args.gate);
    const now = try nowUtcAlloc(allocator);
    var passes = std.ArrayList(PolishPass).empty;
    try passes.appendSlice(allocator, state.graph.polish.passes);
    try passes.append(allocator, .{
        .pass = pass_no,
        .seq = loaded.latest_seq + 1,
        .created_at = now,
        .structure_fingerprint = fps.structure,
        .contract_fingerprint = fps.contract,
        .coverage_fingerprint = fps.coverage,
        .execution_fingerprint = fps.execution,
        .audit_gate = args.gate.asString(),
        .hard_failures = @intCast(audit.errors),
        .warnings = @intCast(audit.warnings),
    });
    state.graph.polish.passes = try passes.toOwnedSlice(allocator);
    state.graph.fingerprints = fps;
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.print("polish snapshot recorded: pass {d}\n", .{pass_no});
    return 0;
}

fn cmdGraphPolishStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    const parsed = try readRecords(allocator, args.file);
    var state = try materializeStateFromRecords(allocator, parsed.records);
    defer state.deinit();
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try writePolishStatusJson(stdout, &state);
        try stdout.writeByte('\n');
    } else {
        try writePolishStatusMarkdown(stdout, &state);
    }
    return 0;
}

fn cmdGraphPolishGate(allocator: std.mem.Allocator, args: Args) !u8 {
    const parsed = try readRecords(allocator, args.file);
    var state = try materializeStateFromRecords(allocator, parsed.records);
    defer state.deinit();
    const audit = try auditGraph(allocator, &state, args.gate);
    const stable = polishStable(&state, args.min_stable_passes);
    const ok = audit.errors == 0 and stable;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try stdout.writeAll("{\"version\":1,\"ok\":");
        try stdout.writeAll(if (ok) "true" else "false");
        try stdout.writeAll(",\"gate\":");
        try std.json.Stringify.value(args.gate.asString(), .{}, stdout);
        try stdout.writeAll(",\"stable\":");
        try stdout.writeAll(if (stable) "true" else "false");
        try stdout.writeAll(",\"errors\":");
        try stdout.print("{d}", .{audit.errors});
        try stdout.writeAll("}\n");
    } else {
        try stdout.print("st graph polish gate: {s}\n", .{if (ok) "PASS" else "FAIL"});
        try stdout.print("Gate: {s}\nStable: {s}\nErrors: {d}\n", .{ args.gate.asString(), if (stable) "true" else "false", audit.errors });
    }
    return if (ok) 0 else 2;
}

fn cmdGraphApply(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const patch_bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);
    const parsed_patch = try std.json.parseFromSlice(std.json.Value, allocator, patch_bytes, .{});
    const patch_obj = switch (parsed_patch.value) {
        .object => |o| o,
        else => return error.InvalidGraphPatch,
    };
    const reason = try requireNonEmptyString(allocator, asString(patch_obj.get("reason") orelse return error.MissingReason) orelse return error.MissingReason, "patch.reason");
    _ = reason;
    const ops_value = patch_obj.get("ops") orelse return error.InvalidGraphPatch;
    const ops = switch (ops_value) {
        .array => |a| a.items,
        else => return error.InvalidGraphPatch,
    };
    if (ops.len == 0) return error.InvalidGraphPatch;

    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const before_ids = try itemIdsAlloc(allocator, &state);
    state.graph_active = true;
    if (!state.graph.policy.completion_requires_proof) {
        state.graph.policy.completion_requires_proof = true;
    }

    for (ops) |op_value| try applyGraphPatchOp(allocator, &state, op_value);

    const audit = try auditGraph(allocator, &state, args.gate);
    if (audit.errors != 0) {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try writeAuditSummaryJson(stdout, audit);
        try stdout.writeByte('\n');
        return 2;
    }
    try validateState(&state, args.allow_multiple_in_progress);

    const seq_after = if (args.dry_run) loaded.latest_seq else loaded.latest_seq + 1;
    const delta = try computeGraphDelta(allocator, before_ids, &state, loaded.latest_seq, seq_after);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    if (!args.dry_run) {
        const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
        const ts = try nowUtcAlloc(allocator);
        try writeCanonicalRecords(args.file, &state, seq_after, ts, meta, null);
    }

    try emitPlanSyncWithPolicy(allocator, stdout, &state, .{ .source_file = args.file, .source_seq = seq_after }, true);
    try stdout.writeAll("graph_delta: ");
    try writeGraphDeltaJson(stdout, delta);
    try stdout.writeByte('\n');
    try stdout.writeAll("audit_summary: ");
    try writeAuditSummaryJson(stdout, audit);
    try stdout.writeByte('\n');
    return 0;
}

const ApertureCandidate = struct {
    id: []const u8,
    score: i64,
    durable_index: usize,
};

fn cmdAperture(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.aperture_command) {
        .next => try cmdApertureNext(allocator, args),
        .plan => try cmdAperturePlan(allocator, args, false),
        .select => try cmdApertureSelect(allocator, args),
        .explain => try cmdAperturePlan(allocator, args, true),
        .none => error.MissingCommand,
    };
}

fn cmdCompile(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.compile_command) {
        .intent => try cmdCompileIntent(allocator, args),
        .graph => try cmdGraphApply(allocator, .{ .command = .graph, .graph_command = .apply, .file = args.file, .input = args.input, .gate = args.gate, .allow_multiple_in_progress = args.allow_multiple_in_progress }),
        .ready => try cmdGraphAudit(allocator, .{ .command = .graph, .graph_command = .audit, .file = args.file, .gate = .implementation_ready, .format = args.format }),
        .aperture => try cmdCompileAperture(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdCompileIntent(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_bytes = try readFileAlloc(allocator, args.input.?, 32 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input_bytes, .{});
    const intents = switch (parsed.value) {
        .array => |arr| arr.items,
        .object => |obj| switch (obj.get("intent") orelse parsed.value) {
            .array => |arr| arr.items,
            else => return error.InvalidIntentAtom,
        },
        else => return error.InvalidIntentAtom,
    };
    var ops = std.ArrayList(std.json.Value).empty;
    for (intents) |intent_value| {
        var op_obj: std.json.ObjectMap = .empty;
        try op_obj.put(allocator, "op", .{ .string = "upsert-intent" });
        try op_obj.put(allocator, "intent", intent_value);
        try ops.append(allocator, .{ .object = op_obj });
    }
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();
    state.graph_active = true;
    state.graph.policy.completion_requires_proof = true;
    for (ops.items) |op_value| try applyGraphPatchOp(allocator, &state, op_value);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try emitPlanSyncWithPolicy(allocator, &stdout_writer.interface, &state, .{ .source_file = args.file, .source_seq = loaded.latest_seq + 1 }, true);
    return 0;
}

fn cmdCompileAperture(allocator: std.mem.Allocator, args: Args) !u8 {
    const code = try cmdApertureSelect(allocator, .{ .command = .aperture, .aperture_command = .select, .file = args.file, .limit = args.limit, .allow_multiple_in_progress = args.allow_multiple_in_progress });
    if (code != 0) return code;
    return cmdPrime(allocator, .{ .command = .prime, .file = args.file, .mode = .aperture, .limit = args.limit, .allow_multiple_in_progress = args.allow_multiple_in_progress });
}

fn cmdApertureNext(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();
    const selected = try apertureCandidates(allocator, &state, 1);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (selected.len == 0) {
        try stdout.writeAll("{\"version\":1,\"id\":null}\n");
        return 0;
    }
    try writeApertureCandidateJson(stdout, &state, selected[0]);
    try stdout.writeByte('\n');
    return 0;
}

fn cmdAperturePlan(allocator: std.mem.Allocator, args: Args, markdown: bool) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();
    const selected = try apertureCandidates(allocator, &state, args.limit);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (markdown or args.format == .markdown) {
        try writeApertureMarkdown(stdout, &state, selected);
    } else {
        try writeAperturePlanJson(stdout, &state, selected, args.limit, args.strategy);
        try stdout.writeByte('\n');
    }
    return 0;
}

fn cmdApertureSelect(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();
    const selected_ids = try selectApertureIds(allocator, &state, args.limit);
    for (state.items.items) |*item| {
        item.in_plan = containsString(selected_ids, item.id);
        normalizeItemPlanMembership(item);
    }
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try emitPlanSyncWithPolicy(allocator, &stdout_writer.interface, &state, .{ .source_file = args.file, .source_seq = loaded.latest_seq + 1 }, true);
    return 0;
}

fn applyGraphPatchOp(allocator: std.mem.Allocator, state: *ItemState, value: std.json.Value) !void {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidGraphPatch,
    };
    const op = asString(obj.get("op") orelse return error.InvalidGraphPatch) orelse return error.InvalidGraphPatch;

    if (std.mem.eql(u8, op, "upsert-intent")) {
        const atom = try canonicalIntentAtom(allocator, obj.get("intent") orelse return error.InvalidIntentAtom);
        try upsertIntentAtom(allocator, &state.graph, atom);
        return;
    }
    if (std.mem.eql(u8, op, "upsert-item")) {
        const item_value = obj.get("item") orelse return error.InvalidItem;
        var item = try canonicalItem(allocator, item_value);
        if (state.getConst(item.id)) |existing| {
            const item_obj = switch (item_value) {
                .object => |o| o,
                else => return error.InvalidItem,
            };
            if (item_obj.get("claim") == null) item.claim = existing.claim;
            if (item_obj.get("runtime") == null) item.runtime = existing.runtime;
            if (item_obj.get("proof") == null) item.proof = existing.proof;
        }
        try state.upsert(item);
        return;
    }
    if (std.mem.eql(u8, op, "remove-item")) {
        const id = try graphOpItemId(allocator, obj);
        try state.remove(id);
        return;
    }
    if (std.mem.eql(u8, op, "set-status")) {
        const item = state.get(try graphOpItemId(allocator, obj)) orelse return error.UnknownItemId;
        item.status = try normalizeStatus(asString(obj.get("status") orelse return error.MissingStatusValue) orelse return error.MissingStatusValue);
        normalizeItemPlanMembership(item);
        return;
    }
    if (std.mem.eql(u8, op, "set-priority")) {
        const item = state.get(try graphOpItemId(allocator, obj)) orelse return error.UnknownItemId;
        item.priority = try normalizePriority(asString(obj.get("priority") orelse return error.MissingPriorityValue) orelse return error.MissingPriorityValue);
        return;
    }
    if (std.mem.eql(u8, op, "set-contract")) {
        const item = state.get(try graphOpItemId(allocator, obj)) orelse return error.UnknownItemId;
        item.contract = try canonicalContract(allocator, obj.get("contract") orelse return error.InvalidContract);
        return;
    }
    if (std.mem.eql(u8, op, "set-acceptance")) return try setItemStringListField(allocator, state, obj, "acceptance", .acceptance);
    if (std.mem.eql(u8, op, "set-validation")) return try setItemStringListField(allocator, state, obj, "validation", .validation);
    if (std.mem.eql(u8, op, "set-location")) return try setItemStringListField(allocator, state, obj, "location", .location);
    if (std.mem.eql(u8, op, "set-scope")) return try setItemStringListField(allocator, state, obj, "scope", .scope);
    if (std.mem.eql(u8, op, "set-labels")) return try setItemStringListField(allocator, state, obj, "labels", .labels);
    if (std.mem.eql(u8, op, "set-lock-roots")) return try setItemStringListField(allocator, state, obj, "lock_roots", .lock_roots);
    if (std.mem.eql(u8, op, "add-dep")) {
        const from = try graphOpFromId(allocator, obj);
        const item = state.get(from) orelse return error.UnknownItemId;
        const dep = try graphOpDep(allocator, obj);
        item.deps = try appendDep(allocator, item.deps, dep);
        return;
    }
    if (std.mem.eql(u8, op, "remove-dep")) {
        const from = try graphOpFromId(allocator, obj);
        const item = state.get(from) orelse return error.UnknownItemId;
        const dep_id = try graphOpToId(allocator, obj);
        item.deps = try removeDep(allocator, item.deps, dep_id);
        return;
    }
    if (std.mem.eql(u8, op, "add-link")) {
        const from = try graphOpFromId(allocator, obj);
        const item = state.get(from) orelse return error.UnknownItemId;
        const link = try graphOpLink(allocator, obj);
        item.links = try appendGraphLink(allocator, item.links, link);
        return;
    }
    if (std.mem.eql(u8, op, "remove-link")) {
        const from = try graphOpFromId(allocator, obj);
        const item = state.get(from) orelse return error.UnknownItemId;
        const to = try graphOpToId(allocator, obj);
        item.links = try removeGraphLink(allocator, item.links, to);
        return;
    }
    if (std.mem.eql(u8, op, "reparent")) {
        const item = state.get(try graphOpItemId(allocator, obj)) orelse return error.UnknownItemId;
        item.parent_id = if (obj.get("parent_id")) |v| try optionalString(allocator, v, "parent_id") else try optionalString(allocator, obj.get("parent") orelse .null, "parent");
        return;
    }
    if (std.mem.eql(u8, op, "add-comment")) {
        const item = state.get(try graphOpItemId(allocator, obj)) orelse return error.UnknownItemId;
        const text = try requireNonEmptyString(allocator, asString(obj.get("text") orelse return error.MissingTextValue) orelse return error.MissingTextValue, "text");
        const author = if (obj.get("author")) |v| asString(v) orelse "codex" else "codex";
        const ts = if (obj.get("ts")) |v| asString(v) orelse "" else "";
        var comments = std.ArrayList(Comment).empty;
        try comments.appendSlice(allocator, item.comments);
        try comments.append(allocator, .{ .ts = if (ts.len > 0) ts else try nowUtcAlloc(allocator), .author = author, .text = text });
        item.comments = try comments.toOwnedSlice(allocator);
        return;
    }
    if (std.mem.eql(u8, op, "waive-audit")) {
        const waiver = try canonicalWaiver(allocator, obj.get("waiver") orelse return error.InvalidWaiver);
        try upsertWaiver(allocator, &state.graph, waiver);
        return;
    }
    if (std.mem.eql(u8, op, "waive-intent")) {
        const waiver = try canonicalWaiver(allocator, obj.get("waiver") orelse return error.InvalidWaiver);
        try upsertWaiver(allocator, &state.graph, waiver);
        return;
    }

    return error.InvalidGraphPatchOp;
}

const StringListField = enum { acceptance, validation, location, scope, labels, lock_roots };

fn setItemStringListField(
    allocator: std.mem.Allocator,
    state: *ItemState,
    obj: std.json.ObjectMap,
    key: []const u8,
    field: StringListField,
) !void {
    const item = state.get(try graphOpItemId(allocator, obj)) orelse return error.UnknownItemId;
    const values = try normalizeStringList(allocator, obj.get(key) orelse return error.InvalidGraphPatch);
    switch (field) {
        .acceptance => item.acceptance = values,
        .validation => item.validation = values,
        .location => item.location = values,
        .scope => item.scope = values,
        .labels => item.labels = values,
        .lock_roots => item.lock_roots = values,
    }
}

fn upsertIntentAtom(allocator: std.mem.Allocator, graph: *GraphEnvelope, atom: IntentAtom) !void {
    var out = std.ArrayList(IntentAtom).empty;
    var replaced = false;
    for (graph.intent) |existing| {
        if (std.mem.eql(u8, existing.id, atom.id)) {
            try out.append(allocator, atom);
            replaced = true;
        } else {
            try out.append(allocator, existing);
        }
    }
    if (!replaced) try out.append(allocator, atom);
    graph.intent = try out.toOwnedSlice(allocator);
}

fn upsertWaiver(allocator: std.mem.Allocator, graph: *GraphEnvelope, waiver: Waiver) !void {
    var out = std.ArrayList(Waiver).empty;
    var replaced = false;
    for (graph.waivers) |existing| {
        if (std.mem.eql(u8, existing.id, waiver.id)) {
            try out.append(allocator, waiver);
            replaced = true;
        } else {
            try out.append(allocator, existing);
        }
    }
    if (!replaced) try out.append(allocator, waiver);
    graph.waivers = try out.toOwnedSlice(allocator);
}

fn graphOpItemId(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    return try requireNonEmptyString(allocator, asString(obj.get("id") orelse return error.MissingItemId) orelse return error.MissingItemId, "id");
}

fn graphOpFromId(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    if (obj.get("from")) |v| return try requireNonEmptyString(allocator, asString(v) orelse return error.MissingItemId, "from");
    return graphOpItemId(allocator, obj);
}

fn graphOpToId(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    if (obj.get("to")) |v| return try requireNonEmptyString(allocator, asString(v) orelse return error.MissingItemId, "to");
    if (obj.get("target")) |v| return try requireNonEmptyString(allocator, asString(v) orelse return error.MissingItemId, "target");
    if (obj.get("dep_id")) |v| return try requireNonEmptyString(allocator, asString(v) orelse return error.MissingItemId, "dep_id");
    return error.MissingItemId;
}

fn graphOpDep(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !Dep {
    if (obj.get("dep")) |v| return try canonicalDepEdge(allocator, v);
    return .{
        .id = try graphOpToId(allocator, obj),
        .type = if (obj.get("type")) |v| asString(v) orelse "requires" else "requires",
    };
}

fn graphOpLink(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !GraphLink {
    if (obj.get("link")) |v| return try canonicalGraphLink(allocator, v);
    return .{
        .id = try graphOpToId(allocator, obj),
        .type = try requireNonEmptyString(allocator, asString(obj.get("type") orelse return error.InvalidGraphLink) orelse return error.InvalidGraphLink, "link.type"),
        .reason = if (obj.get("reason")) |v| asString(v) orelse "" else "",
    };
}

fn appendDep(allocator: std.mem.Allocator, deps: []const Dep, dep: Dep) ![]const Dep {
    var out = std.ArrayList(Dep).empty;
    for (deps) |existing| {
        if (!std.mem.eql(u8, existing.id, dep.id)) try out.append(allocator, existing);
    }
    try out.append(allocator, dep);
    return try out.toOwnedSlice(allocator);
}

fn removeDep(allocator: std.mem.Allocator, deps: []const Dep, dep_id: []const u8) ![]const Dep {
    var out = std.ArrayList(Dep).empty;
    for (deps) |existing| {
        if (!std.mem.eql(u8, existing.id, dep_id)) try out.append(allocator, existing);
    }
    return try out.toOwnedSlice(allocator);
}

fn appendGraphLink(allocator: std.mem.Allocator, links: []const GraphLink, link: GraphLink) ![]const GraphLink {
    var out = std.ArrayList(GraphLink).empty;
    for (links) |existing| {
        if (!(std.mem.eql(u8, existing.id, link.id) and std.mem.eql(u8, existing.type, link.type))) {
            try out.append(allocator, existing);
        }
    }
    try out.append(allocator, link);
    return try out.toOwnedSlice(allocator);
}

fn removeGraphLink(allocator: std.mem.Allocator, links: []const GraphLink, link_id: []const u8) ![]const GraphLink {
    var out = std.ArrayList(GraphLink).empty;
    for (links) |existing| {
        if (!std.mem.eql(u8, existing.id, link_id)) try out.append(allocator, existing);
    }
    return try out.toOwnedSlice(allocator);
}

fn itemIdsAlloc(allocator: std.mem.Allocator, state: *const ItemState) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| try out.append(allocator, item.id);
    return try out.toOwnedSlice(allocator);
}

fn computeGraphDelta(allocator: std.mem.Allocator, before_ids: []const []const u8, state: *const ItemState, seq_before: i64, seq_after: i64) !GraphDelta {
    var added = std.ArrayList([]const u8).empty;
    var changed = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| {
        if (!containsString(before_ids, item.id)) {
            try added.append(allocator, item.id);
        } else {
            try changed.append(allocator, item.id);
        }
    }
    var removed = std.ArrayList([]const u8).empty;
    for (before_ids) |id| {
        if (state.getConst(id) == null) try removed.append(allocator, id);
    }
    var intent_ids = std.ArrayList([]const u8).empty;
    for (state.graph.intent) |atom| try intent_ids.append(allocator, atom.id);
    return .{
        .seq_before = seq_before,
        .seq_after = seq_after,
        .items_added = try added.toOwnedSlice(allocator),
        .items_removed = try removed.toOwnedSlice(allocator),
        .items_changed = try changed.toOwnedSlice(allocator),
        .intent_coverage_changed = try intent_ids.toOwnedSlice(allocator),
    };
}

fn auditGraph(allocator: std.mem.Allocator, state: *const ItemState, gate: AuditGate) !AuditResult {
    var findings = std.ArrayList(AuditFinding).empty;

    try auditDraftGraph(allocator, state, gate, &findings);
    if (gate == .implementation_ready or gate == .execution_ready or gate == .proof_complete) {
        try auditImplementationReadyGraph(allocator, state, gate, &findings);
    }
    if (gate == .execution_ready) {
        try auditExecutionReadyGraph(allocator, state, gate, &findings);
    }
    if (gate == .proof_complete) {
        try auditProofCompleteGraph(allocator, state, gate, &findings);
    }

    var errors: usize = 0;
    var warnings: usize = 0;
    for (findings.items) |finding| {
        if (finding.waived) continue;
        switch (finding.severity) {
            .@"error" => errors += 1,
            .warning => warnings += 1,
            .info => {},
        }
    }
    return .{ .gate = gate, .findings = try findings.toOwnedSlice(allocator), .errors = errors, .warnings = warnings };
}

fn auditDraftGraph(allocator: std.mem.Allocator, state: *const ItemState, gate: AuditGate, findings: *std.ArrayList(AuditFinding)) !void {
    var intent_ids = std.StringHashMap(void).init(allocator);
    for (state.graph.intent) |atom| {
        if (intent_ids.get(atom.id) != null) {
            try addFinding(allocator, state, gate, findings, "duplicate-id", .@"error", atom.id, "Intent atom id is duplicated.");
        } else {
            try intent_ids.put(atom.id, {});
        }
        if (!validIntentCategory(atom.category)) {
            try addFinding(allocator, state, gate, findings, "invalid-intent-category", .@"error", atom.id, "Intent atom category is invalid.");
        }
        if (!validIntentDisposition(atom.disposition)) {
            try addFinding(allocator, state, gate, findings, "invalid-intent-disposition", .@"error", atom.id, "Intent atom disposition is invalid.");
        }
    }

    for (state.items.items) |item| {
        for (item.deps) |dep| {
            if (std.mem.eql(u8, dep.id, item.id)) {
                try addFinding(allocator, state, gate, findings, "self-dependency", .@"error", item.id, "Item depends on itself.");
            } else if (state.getConst(dep.id) == null) {
                try addFinding(allocator, state, gate, findings, "unknown-dependency", .@"error", item.id, "Item dependency does not reference an existing item.");
            }
        }
        if (item.parent_id) |parent_id| {
            if (state.getConst(parent_id) == null) {
                try addFinding(allocator, state, gate, findings, "unknown-parent", .@"error", item.id, "Item parent_id does not reference an existing item.");
            }
        }
        for (item.links) |link| {
            if (!validLinkType(link.type)) {
                try addFinding(allocator, state, gate, findings, "invalid-link-type", .@"error", item.id, "Item link type is invalid.");
            }
            if (std.mem.eql(u8, link.type, "covers-intent")) {
                if (!intentExists(state, link.id)) try addFinding(allocator, state, gate, findings, "unknown-link-target", .@"error", item.id, "covers-intent link target does not exist.");
            } else if (state.getConst(link.id) == null) {
                try addFinding(allocator, state, gate, findings, "unknown-link-target", .@"error", item.id, "Item link target does not exist.");
            }
        }
        for (item.intent_refs) |intent_id| {
            if (!intentExists(state, intent_id)) {
                try addFinding(allocator, state, gate, findings, "unknown-intent-ref", .@"error", item.id, "Item references an unknown intent atom.");
            }
        }
        if (isExecutableItem(item) and item.contract == null) {
            try addFinding(allocator, state, gate, findings, "missing-contract", .warning, item.id, "Executable item has no structured contract.");
        }
        if (isExecutableItem(item) and item.acceptance.len == 0) {
            try addFinding(allocator, state, gate, findings, "missing-acceptance", .warning, item.id, "Executable item has no acceptance criteria.");
        }
        if (isExecutableItem(item) and item.validation.len == 0 and !itemHasProofObligations(item)) {
            try addFinding(allocator, state, gate, findings, "missing-validation", .warning, item.id, "Executable item has no validation or proof obligations.");
        }
    }

    try auditParentCycles(allocator, state, gate, findings);
    try auditDependencyCycles(allocator, state, gate, findings);
    for (state.graph.waivers) |waiver| {
        if (waiver.reason.len == 0) {
            try addFinding(allocator, state, gate, findings, "invalid-waiver-target", .@"error", waiver.id, "Waiver requires a reason.");
        }
        if (!waiverTargetExists(state, waiver.target)) {
            try addFinding(allocator, state, gate, findings, "invalid-waiver-target", .@"error", waiver.id, "Waiver target does not exist.");
        }
    }
}

fn auditImplementationReadyGraph(allocator: std.mem.Allocator, state: *const ItemState, gate: AuditGate, findings: *std.ArrayList(AuditFinding)) !void {
    for (state.graph.intent) |atom| {
        if (std.mem.eql(u8, atom.disposition, "unknown")) {
            try addFinding(allocator, state, gate, findings, "unknown-intent-disposition", .@"error", atom.id, "Intent atom has unknown disposition.");
        }
        if (std.mem.eql(u8, atom.disposition, "covered") and !intentCovered(state, atom.id)) {
            try addFinding(allocator, state, gate, findings, "intent-not-covered-or-waived", .@"error", atom.id, "Covered intent atom has no covering item.");
        }
        if (!std.mem.eql(u8, atom.disposition, "covered") and !std.mem.eql(u8, atom.disposition, "unknown") and atom.reason.len == 0) {
            try addFinding(allocator, state, gate, findings, "intent-disposition-missing-reason", .@"error", atom.id, "Non-covered intent disposition requires a reason or waiver.");
        }
    }
    for (state.items.items) |item| {
        if (!isExecutableItem(item)) continue;
        if (item.contract == null) {
            try addFinding(allocator, state, gate, findings, "executable-item-missing-contract", .@"error", item.id, "Executable item is missing a structured contract.");
        }
        if (item.acceptance.len == 0) {
            try addFinding(allocator, state, gate, findings, "executable-item-missing-acceptance", .@"error", item.id, "Executable item is missing acceptance criteria.");
        }
        if (item.validation.len == 0 and !itemHasProofObligations(item)) {
            try addFinding(allocator, state, gate, findings, "executable-item-missing-validation-or-proof-obligation", .@"error", item.id, "Executable item is missing validation or proof obligations.");
        }
        if ((item.item_type == .feature or item.item_type == .bug) and !itemHasTestCoverage(state, item)) {
            try addFinding(allocator, state, gate, findings, "feature-or-bug-missing-test-coverage", .@"error", item.id, "Feature or bug item has no validation, proof obligation, child test, or linked test coverage.");
        }
        if ((item.item_type == .@"test" or item.item_type == .verification) and !testItemLinkedToCoveredItem(state, item)) {
            try addFinding(allocator, state, gate, findings, "test-item-not-linked-to-covered-item", .@"error", item.id, "Test or verification item is not linked to covered work.");
        }
        if (item.contract) |contract| {
            if (contract.risks.len > 0 and item.validation.len == 0 and !itemHasProofObligations(item) and item.acceptance.len == 0) {
                try addFinding(allocator, state, gate, findings, "risk-without-mitigation", .@"error", item.id, "Contract risks have no structural validation, proof, or acceptance mitigation.");
            }
        }
    }
}

fn auditExecutionReadyGraph(allocator: std.mem.Allocator, state: *const ItemState, gate: AuditGate, findings: *std.ArrayList(AuditFinding)) !void {
    for (state.items.items) |item| {
        if (!effectiveInPlan(item)) continue;
        if (!isExecutableItem(item)) {
            try addFinding(allocator, state, gate, findings, "selected-draft-item", .@"error", item.id, "Selected item is not executable.");
        }
        if (isTerminalStatus(item.status)) {
            try addFinding(allocator, state, gate, findings, "terminal-item-selected", .@"error", item.id, "Terminal item is selected.");
        }
        const waiting = try unresolvedDependencyIds(allocator, item, state);
        if (waiting.len > 0) {
            try addFinding(allocator, state, gate, findings, "selected-item-waiting-on-deps", .@"error", item.id, "Selected item is waiting on dependencies.");
            if (item.status == .in_progress) {
                try addFinding(allocator, state, gate, findings, "in-progress-waiting-on-deps", .@"error", item.id, "In-progress item is waiting on dependencies.");
            }
        }
        if (item.claim) |claim| {
            if (claim.state == .stale) {
                try addFinding(allocator, state, gate, findings, "stale-claim-selected", .@"error", item.id, "Selected item has a stale claim.");
            }
        }
    }
}

fn auditProofCompleteGraph(allocator: std.mem.Allocator, state: *const ItemState, gate: AuditGate, findings: *std.ArrayList(AuditFinding)) !void {
    for (state.items.items) |item| {
        if (item.status != .completed or !isExecutableItem(item)) continue;
        const obligations = proofObligationsForItem(item);
        for (obligations) |obligation| {
            if (!obligation.required) continue;
            if (obligation.command.len == 0 and proofKindUsuallyNeedsCommand(obligation.kind)) {
                try addFinding(allocator, state, gate, findings, "proof-command-missing", .@"error", item.id, "Required proof obligation is missing a command.");
            }
            const proof = item.proof orelse {
                try addFinding(allocator, state, gate, findings, "completed-item-missing-required-proof", .@"error", item.id, "Completed item is missing required proof.");
                continue;
            };
            if (proof.state != .pass) {
                try addFinding(allocator, state, gate, findings, "proof-failed", .@"error", item.id, "Required proof did not pass.");
            }
            if (proof.evidence_ref.len == 0 and obligation.evidence_ref.len == 0) {
                try addFinding(allocator, state, gate, findings, "proof-evidence-ref-missing", .@"error", item.id, "Required proof has no evidence reference.");
            }
        }
    }
}

fn addFinding(
    allocator: std.mem.Allocator,
    state: *const ItemState,
    gate: AuditGate,
    findings: *std.ArrayList(AuditFinding),
    code: []const u8,
    severity: FindingSeverity,
    target: []const u8,
    message: []const u8,
) !void {
    const waiver_id = matchingWaiver(state, gate, code, target);
    try findings.append(allocator, .{
        .code = code,
        .severity = severity,
        .target = target,
        .message = message,
        .waived = waiver_id != null,
        .waiver_id = waiver_id,
    });
}

fn validIntentCategory(raw: []const u8) bool {
    const allowed = [_][]const u8{ "requirement", "constraint", "non-goal", "risk", "compatibility", "migration", "test-expectation", "user-behavior", "architecture", "performance", "security", "accessibility", "observability", "documentation" };
    return containsString(allowed[0..], raw);
}

fn validIntentDisposition(raw: []const u8) bool {
    const allowed = [_][]const u8{ "covered", "deferred", "rejected", "duplicate", "non-goal", "unknown" };
    return containsString(allowed[0..], raw);
}

fn validLinkType(raw: []const u8) bool {
    const allowed = [_][]const u8{ "tests", "validates", "implements", "documents", "covers-intent", "relates-to", "supersedes", "duplicate-of", "follow-up", "context-for", "risk-for" };
    return containsString(allowed[0..], raw);
}

fn intentExists(state: *const ItemState, intent_id: []const u8) bool {
    for (state.graph.intent) |atom| {
        if (std.mem.eql(u8, atom.id, intent_id)) return true;
    }
    return false;
}

fn intentCovered(state: *const ItemState, intent_id: []const u8) bool {
    for (state.items.items) |item| {
        if (containsString(item.intent_refs, intent_id)) return true;
        for (item.links) |link| {
            if (std.mem.eql(u8, link.type, "covers-intent") and std.mem.eql(u8, link.id, intent_id)) return true;
        }
    }
    return false;
}

fn waiverTargetExists(state: *const ItemState, target: []const u8) bool {
    if (state.getConst(target) != null) return true;
    if (intentExists(state, target)) return true;
    return false;
}

fn matchingWaiver(state: *const ItemState, gate: AuditGate, code: []const u8, target: []const u8) ?[]const u8 {
    for (state.graph.waivers) |waiver| {
        if (!std.mem.eql(u8, waiver.gate, gate.asString())) continue;
        if (!std.mem.eql(u8, waiver.code, code)) continue;
        if (!std.mem.eql(u8, waiver.target, target)) continue;
        if (!(std.mem.eql(u8, waiver.expires, "never") or std.mem.eql(u8, waiver.expires, "on-next-touch"))) continue;
        if (waiver.reason.len == 0) continue;
        return waiver.id;
    }
    return null;
}

fn isExecutableItem(item: Item) bool {
    return item.item_type != .epic and item.item_type != .decision;
}

fn itemHasProofObligations(item: Item) bool {
    return proofObligationsForItem(item).len > 0;
}

fn proofObligationsForItem(item: Item) []const ProofObligation {
    if (item.contract) |contract| return contract.proof_obligations;
    return &.{};
}

fn itemHasTestCoverage(state: *const ItemState, item: Item) bool {
    if (item.validation.len > 0 or itemHasProofObligations(item)) return true;
    for (item.links) |link| {
        if ((std.mem.eql(u8, link.type, "tests") or std.mem.eql(u8, link.type, "validates")) and state.getConst(link.id) != null) return true;
    }
    for (state.items.items) |candidate| {
        if (candidate.parent_id) |parent_id| {
            if (std.mem.eql(u8, parent_id, item.id) and (candidate.item_type == .@"test" or candidate.item_type == .verification)) return true;
        }
        for (candidate.links) |link| {
            if ((std.mem.eql(u8, link.type, "tests") or std.mem.eql(u8, link.type, "validates")) and std.mem.eql(u8, link.id, item.id)) return true;
        }
    }
    return false;
}

fn testItemLinkedToCoveredItem(state: *const ItemState, item: Item) bool {
    if (item.parent_id != null) return true;
    for (item.links) |link| {
        if ((std.mem.eql(u8, link.type, "tests") or std.mem.eql(u8, link.type, "validates")) and state.getConst(link.id) != null) return true;
    }
    return false;
}

fn proofKindUsuallyNeedsCommand(kind: []const u8) bool {
    const command_kinds = [_][]const u8{ "command", "test", "unit", "integration", "e2e", "lint", "typecheck", "benchmark" };
    return containsString(command_kinds[0..], kind);
}

fn proofCompletionMissingReason(item: Item) ?[]const u8 {
    const obligations = proofObligationsForItem(item);
    if (obligations.len == 0) return null;
    const proof = item.proof orelse return "missing required proof receipt";
    if (proof.state != .pass) return "proof receipt is not passing";
    if (proof.evidence_ref.len == 0) return "proof receipt is missing evidence reference";
    for (obligations) |obligation| {
        if (!obligation.required) continue;
        if (obligation.command.len == 0 and proofKindUsuallyNeedsCommand(obligation.kind)) return "required proof obligation is missing a command";
        if (obligation.command.len > 0 and proof.command.len == 0) return "proof receipt is missing command";
        if (obligation.command.len > 0 and !std.mem.eql(u8, obligation.command, proof.command)) return "proof command does not satisfy required obligation";
    }
    return null;
}

fn addForcedCompletionWaivers(allocator: std.mem.Allocator, state: *ItemState, item_id: []const u8, reason: []const u8, created_at: []const u8) !void {
    const codes = [_][]const u8{
        "completed-item-missing-required-proof",
        "proof-command-missing",
        "proof-evidence-ref-missing",
        "proof-failed",
        "unwaived-forced-completion",
    };
    for (codes) |code| {
        const waiver_id = try std.fmt.allocPrint(allocator, "waiver-{s}-{s}", .{ item_id, code });
        try upsertWaiver(allocator, &state.graph, .{
            .id = waiver_id,
            .gate = "proof-complete",
            .code = code,
            .target = item_id,
            .reason = reason,
            .expires = "on-next-touch",
            .created_at = created_at,
            .created_by = "codex",
        });
    }
}

fn auditParentCycles(allocator: std.mem.Allocator, state: *const ItemState, gate: AuditGate, findings: *std.ArrayList(AuditFinding)) !void {
    for (state.items.items) |item| {
        var seen = std.StringHashMap(void).init(allocator);
        var current: ?[]const u8 = item.parent_id;
        while (current) |parent_id| {
            if (std.mem.eql(u8, parent_id, item.id) or seen.get(parent_id) != null) {
                try addFinding(allocator, state, gate, findings, "parent-cycle", .@"error", item.id, "Parent hierarchy contains a cycle.");
                break;
            }
            try seen.put(parent_id, {});
            current = if (state.getConst(parent_id)) |parent| parent.parent_id else null;
        }
    }
}

fn auditDependencyCycles(allocator: std.mem.Allocator, state: *const ItemState, gate: AuditGate, findings: *std.ArrayList(AuditFinding)) !void {
    for (state.items.items) |item| {
        var visiting = std.StringHashMap(void).init(allocator);
        if (try dependencyCycleReachable(allocator, state, item.id, item.id, &visiting)) {
            try addFinding(allocator, state, gate, findings, "dependency-cycle", .@"error", item.id, "Dependency graph contains a cycle.");
        }
    }
}

fn dependencyCycleReachable(
    allocator: std.mem.Allocator,
    state: *const ItemState,
    start_id: []const u8,
    current_id: []const u8,
    visiting: *std.StringHashMap(void),
) !bool {
    const item = state.getConst(current_id) orelse return false;
    if (visiting.get(current_id) != null) return false;
    try visiting.put(current_id, {});
    for (item.deps) |dep| {
        if (std.mem.eql(u8, dep.id, start_id)) return true;
        if (try dependencyCycleReachable(allocator, state, start_id, dep.id, visiting)) return true;
    }
    _ = visiting.remove(current_id);
    return false;
}

fn writeGraphDeltaJson(writer: anytype, delta: GraphDelta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"version\":1,\"seq_before\":");
    try writer.print("{d}", .{delta.seq_before});
    try writer.writeAll(",\"seq_after\":");
    try writer.print("{d}", .{delta.seq_after});
    try writer.writeAll(",\"items_added\":");
    try writeStringListArray(writer, delta.items_added);
    try writer.writeAll(",\"items_removed\":");
    try writeStringListArray(writer, delta.items_removed);
    try writer.writeAll(",\"items_changed\":");
    try writeStringListArray(writer, delta.items_changed);
    try writer.writeAll(",\"deps_added\":[],\"deps_removed\":[],\"links_added\":[],\"links_removed\":[],\"intent_coverage_changed\":");
    try writeStringListArray(writer, delta.intent_coverage_changed);
    try writer.writeAll(",\"fingerprints\":{\"structure\":\"\",\"contract\":\"\",\"coverage\":\"\",\"execution\":\"\"}}");
}

fn writeAuditSummaryJson(writer: anytype, audit: AuditResult) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"gate\":");
    try std.json.Stringify.value(audit.gate.asString(), .{}, writer);
    try writer.writeAll(",\"ok\":");
    try writer.writeAll(if (audit.errors == 0) "true" else "false");
    try writer.writeAll(",\"errors\":");
    try writer.print("{d}", .{audit.errors});
    try writer.writeAll(",\"warnings\":");
    try writer.print("{d}", .{audit.warnings});
    try writer.writeAll(",\"top_findings\":[");
    var emitted: usize = 0;
    for (audit.findings) |finding| {
        if (finding.waived or finding.severity != .@"error") continue;
        if (emitted > 0) try writer.writeByte(',');
        try writeFindingJson(writer, finding);
        emitted += 1;
        if (emitted >= 5) break;
    }
    try writer.writeAll("]}");
}

fn writeAuditResultJson(writer: anytype, state: *const ItemState, audit: AuditResult) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"version\":1,\"gate\":");
    try std.json.Stringify.value(audit.gate.asString(), .{}, writer);
    try writer.writeAll(",\"ok\":");
    try writer.writeAll(if (audit.errors == 0) "true" else "false");
    try writer.writeAll(",\"summary\":{\"items\":");
    try writer.print("{d}", .{state.items.items.len});
    try writer.writeAll(",\"open\":");
    try writer.print("{d}", .{countOpenItems(state)});
    try writer.writeAll(",\"ready\":");
    try writer.print("{d}", .{countReadyItems(state)});
    try writer.writeAll(",\"blocked\":");
    try writer.print("{d}", .{countBlockedItems(state)});
    try writer.writeAll(",\"terminal\":");
    try writer.print("{d}", .{countTerminalItems(state)});
    try writer.writeAll(",\"intent\":");
    try writer.print("{d}", .{state.graph.intent.len});
    try writer.writeAll(",\"covered_intent\":");
    try writer.print("{d}", .{countCoveredIntent(state)});
    try writer.writeAll(",\"waived_intent\":0,\"unknown_intent\":");
    try writer.print("{d}", .{countUnknownIntent(state)});
    try writer.writeAll(",\"errors\":");
    try writer.print("{d}", .{audit.errors});
    try writer.writeAll(",\"warnings\":");
    try writer.print("{d}", .{audit.warnings});
    try writer.writeAll("},\"findings\":[");
    for (audit.findings, 0..) |finding, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeFindingJson(writer, finding);
    }
    try writer.writeAll("],\"waivers\":");
    try writeWaiversArray(writer, state.graph.waivers);
    try writer.writeAll(",\"fingerprints\":{\"structure\":\"\",\"contract\":\"\",\"coverage\":\"\",\"execution\":\"\"}}");
}

fn writeFindingJson(writer: anytype, finding: AuditFinding) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"code\":");
    try std.json.Stringify.value(finding.code, .{}, writer);
    try writer.writeAll(",\"severity\":");
    try std.json.Stringify.value(finding.severity.asString(), .{}, writer);
    try writer.writeAll(",\"target\":");
    try std.json.Stringify.value(finding.target, .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(finding.message, .{}, writer);
    try writer.writeAll(",\"waived\":");
    try writer.writeAll(if (finding.waived) "true" else "false");
    try writer.writeAll(",\"waiver_id\":");
    if (finding.waiver_id) |waiver_id| {
        try std.json.Stringify.value(waiver_id, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn writeAuditResultMarkdown(writer: anytype, audit: AuditResult) !void {
    try writer.print("# st graph audit: {s}\n\n", .{audit.gate.asString()});
    try writer.print("Status: {s}\n", .{if (audit.errors == 0) "PASS" else "FAIL"});
    try writer.print("Errors: {d}\nWarnings: {d}\n\n", .{ audit.errors, audit.warnings });
    try writer.writeAll("## Findings\n\n");
    var any = false;
    for (audit.findings) |finding| {
        if (finding.waived) continue;
        any = true;
        try writer.print("- [{s}] {s}: {s}\n", .{ finding.code, finding.target, finding.message });
    }
    if (!any) try writer.writeAll("- (none)\n");
}

fn countOpenItems(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.items.items) |item| {
        if (!isTerminalStatus(item.status)) count += 1;
    }
    return count;
}

fn countTerminalItems(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.items.items) |item| {
        if (isTerminalStatus(item.status)) count += 1;
    }
    return count;
}

fn countBlockedItems(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.items.items) |item| {
        if (item.status == .blocked) count += 1;
    }
    return count;
}

fn countReadyItems(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.items.items) |item| {
        if (item.status != .pending) continue;
        var ready = true;
        for (item.deps) |dep| {
            const dep_item = state.getConst(dep.id) orelse {
                ready = false;
                break;
            };
            if (dep_item.status != .completed) {
                ready = false;
                break;
            }
        }
        if (ready) count += 1;
    }
    return count;
}

fn countCoveredIntent(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.graph.intent) |atom| {
        if (intentCovered(state, atom.id)) count += 1;
    }
    return count;
}

fn countUnknownIntent(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.graph.intent) |atom| {
        if (std.mem.eql(u8, atom.disposition, "unknown")) count += 1;
    }
    return count;
}

fn computeGraphFingerprints(allocator: std.mem.Allocator, state: *const ItemState) !GraphFingerprints {
    return .{
        .structure = try fingerprintGraph(allocator, state, .structure),
        .contract = try fingerprintGraph(allocator, state, .contract),
        .coverage = try fingerprintGraph(allocator, state, .coverage),
        .execution = try fingerprintGraph(allocator, state, .execution),
    };
}

const FingerprintKind = enum { structure, contract, coverage, execution };

fn fingerprintGraph(allocator: std.mem.Allocator, state: *const ItemState, kind: FingerprintKind) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print("{s}\n", .{@tagName(kind)});
    for (state.items.items) |item| {
        switch (kind) {
            .structure => {
                try writer.print("{s}|{s}|", .{ item.id, item.item_type.asString() });
                if (item.parent_id) |parent_id| try writer.writeAll(parent_id);
                try writer.writeByte('|');
                try writeDepsArray(writer, item.deps);
                try writer.writeByte('|');
                try writeGraphLinksArray(writer, item.links);
                try writer.writeByte('|');
                try writeStringListArray(writer, item.intent_refs);
                try writer.writeByte('|');
                try writer.writeAll(item.priority.asString());
                try writer.writeByte('\n');
            },
            .contract => {
                try writer.print("{s}|{s}|{s}|", .{ item.id, item.step, item.notes });
                try writeStringListArray(writer, item.acceptance);
                try writer.writeByte('|');
                try writeStringListArray(writer, item.validation);
                try writer.writeByte('|');
                if (item.contract) |contract| try writeContractObject(writer, contract);
                try writer.writeByte('\n');
            },
            .coverage => {
                try writer.print("{s}|", .{item.id});
                try writeStringListArray(writer, item.intent_refs);
                try writer.writeByte('|');
                try writeGraphLinksArray(writer, item.links);
                try writer.writeByte('|');
                if (item.contract) |contract| try writeProofObligationsArray(writer, contract.proof_obligations);
                try writer.writeByte('\n');
            },
            .execution => {
                try writer.print("{s}|{s}|{s}|", .{ item.id, item.status.asString(), if (effectiveInPlan(item)) "true" else "false" });
                if (item.claim) |claim| try writeClaimMetaObject(writer, claim);
                try writer.writeByte('|');
                if (item.runtime) |runtime| try writeRuntimeMetaObject(writer, runtime);
                try writer.writeByte('|');
                if (item.proof) |proof| try writeProofMetaObject(writer, proof);
                try writer.writeByte('\n');
            },
        }
    }
    if (kind == .coverage) {
        try writeIntentArray(writer, state.graph.intent);
        try writer.writeByte('|');
        try writeWaiversArray(writer, state.graph.waivers);
    }
    const payload = try out.toOwnedSlice();
    return try hashTextSha256Alloc(allocator, payload);
}

fn hashTextSha256Alloc(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&encoded});
}

fn polishStable(state: *const ItemState, min_stable_passes: usize) bool {
    const passes = state.graph.polish.passes;
    if (passes.len < min_stable_passes) return false;
    const last = passes[passes.len - 1];
    var checked: usize = 1;
    var idx = passes.len - 1;
    while (checked < min_stable_passes) : (checked += 1) {
        if (idx == 0) return false;
        idx -= 1;
        const prior = passes[idx];
        if (!std.mem.eql(u8, prior.structure_fingerprint, last.structure_fingerprint)) return false;
        if (!std.mem.eql(u8, prior.coverage_fingerprint, last.coverage_fingerprint)) return false;
    }
    return true;
}

fn writeGraphInsightsJson(allocator: std.mem.Allocator, writer: anytype, state: *const ItemState) !void {
    const ready_ids = try readyItemIds(allocator, state);
    const blocked_ids = try blockedItemIds(allocator, state);
    try writer.writeByte('{');
    try writer.writeAll("\"version\":1,\"summary\":{\"items\":");
    try writer.print("{d}", .{state.items.items.len});
    try writer.writeAll(",\"ready\":");
    try writer.print("{d}", .{ready_ids.len});
    try writer.writeAll(",\"blocked\":");
    try writer.print("{d}", .{blocked_ids.len});
    try writer.writeAll(",\"critical_path_length\":");
    try writer.print("{d}", .{criticalPathLength(state)});
    try writer.writeAll(",\"intent_atoms\":");
    try writer.print("{d}", .{state.graph.intent.len});
    try writer.writeAll(",\"covered_intent\":");
    try writer.print("{d}", .{countCoveredIntent(state)});
    try writer.writeAll(",\"proof_complete\":");
    try writer.print("{d}", .{countProofComplete(state)});
    try writer.writeAll("},\"ready\":[");
    for (ready_ids, 0..) |id, idx| {
        if (idx > 0) try writer.writeByte(',');
        const item = state.getConst(id).?;
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(item.id, .{}, writer);
        try writer.writeAll(",\"step\":");
        try std.json.Stringify.value(item.step, .{}, writer);
        try writer.writeAll(",\"priority\":");
        try std.json.Stringify.value(item.priority.asString(), .{}, writer);
        try writer.writeAll(",\"score\":");
        try writer.print("{d}", .{priorityWeight(item.priority) + downstreamCount(state, item.id)});
        try writer.writeAll(",\"downstream_count\":");
        try writer.print("{d}", .{downstreamCount(state, item.id)});
        try writer.writeAll(",\"critical_path_length\":");
        try writer.print("{d}", .{criticalPathFrom(state, item.id)});
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"blocked\":");
    try writeStringListArray(writer, blocked_ids);
    try writer.writeAll(",\"coverage\":{\"intent\":{\"total\":");
    try writer.print("{d}", .{state.graph.intent.len});
    try writer.writeAll(",\"covered\":");
    try writer.print("{d}", .{countCoveredIntent(state)});
    try writer.writeAll(",\"waived\":0,\"unknown\":[]},\"tests\":{\"items_requiring_tests\":0,\"covered\":0,\"uncovered\":[]},\"proof\":{\"items_requiring_proof\":");
    try writer.print("{d}", .{countItemsWithProofObligations(state)});
    try writer.writeAll(",\"complete\":");
    try writer.print("{d}", .{countProofComplete(state)});
    try writer.writeAll(",\"missing\":[]}},\"waves\":[{\"wave\":1,\"items\":");
    try writeStringListArray(writer, ready_ids);
    try writer.writeAll(",\"safe_parallel\":");
    try writer.writeAll(if (readyIdsHaveDisjointLocks(state, ready_ids)) "true" else "false");
    try writer.writeAll("}]}");
}

fn writeGraphInsightsMarkdown(allocator: std.mem.Allocator, writer: anytype, state: *const ItemState) !void {
    const ready_ids = try readyItemIds(allocator, state);
    try writer.writeAll("# st graph insights\n\n");
    try writer.print("Items: {d}\nReady: {d}\nBlocked: {d}\nCritical path: {d}\nIntent: {d}/{d} covered\n\n", .{
        state.items.items.len,
        ready_ids.len,
        countBlockedItems(state),
        criticalPathLength(state),
        countCoveredIntent(state),
        state.graph.intent.len,
    });
    try writer.writeAll("## Ready\n\n");
    if (ready_ids.len == 0) {
        try writer.writeAll("- (none)\n");
    } else {
        for (ready_ids) |id| {
            const item = state.getConst(id).?;
            try writer.print("- {s}: {s}\n", .{ item.id, item.step });
        }
    }
}

fn writePolishStatusJson(writer: anytype, state: *const ItemState) !void {
    try writer.writeAll("{\"version\":1,\"session_id\":");
    try std.json.Stringify.value(state.graph.polish.session_id, .{}, writer);
    try writer.writeAll(",\"passes\":");
    try writer.print("{d}", .{state.graph.polish.passes.len});
    try writer.writeAll(",\"fingerprints\":");
    try writeGraphFingerprintsObject(writer, state.graph.fingerprints);
    try writer.writeByte('}');
}

fn writePolishStatusMarkdown(writer: anytype, state: *const ItemState) !void {
    try writer.writeAll("# st graph polish status\n\n");
    try writer.print("Session: {s}\nPasses: {d}\n", .{ state.graph.polish.session_id, state.graph.polish.passes.len });
    if (state.graph.polish.passes.len > 0) {
        const last = state.graph.polish.passes[state.graph.polish.passes.len - 1];
        try writer.print("Last pass: {d}\nStructure: {s}\nCoverage: {s}\n", .{ last.pass, last.structure_fingerprint, last.coverage_fingerprint });
    }
}

fn readyItemIds(allocator: std.mem.Allocator, state: *const ItemState) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| {
        if (item.status != .pending or !isExecutableItem(item)) continue;
        var ready = true;
        for (item.deps) |dep| {
            const dep_item = state.getConst(dep.id) orelse {
                ready = false;
                break;
            };
            if (dep_item.status != .completed) {
                ready = false;
                break;
            }
        }
        if (ready) try out.append(allocator, item.id);
    }
    return try out.toOwnedSlice(allocator);
}

fn blockedItemIds(allocator: std.mem.Allocator, state: *const ItemState) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| {
        if (item.status == .blocked) {
            try out.append(allocator, item.id);
            continue;
        }
        for (item.deps) |dep| {
            const dep_item = state.getConst(dep.id) orelse continue;
            if (dep_item.status != .completed) {
                try out.append(allocator, item.id);
                break;
            }
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn priorityWeight(priority: Priority) i64 {
    return switch (priority) {
        .high => 100,
        .medium => 50,
        .low => 10,
    };
}

fn downstreamCount(state: *const ItemState, item_id: []const u8) i64 {
    var count: i64 = 0;
    for (state.items.items) |item| {
        for (item.deps) |dep| {
            if (std.mem.eql(u8, dep.id, item_id)) {
                count += 1;
                break;
            }
        }
    }
    return count;
}

fn criticalPathLength(state: *const ItemState) i64 {
    var max_len: i64 = 0;
    for (state.items.items) |item| {
        const len = criticalPathFrom(state, item.id);
        if (len > max_len) max_len = len;
    }
    return max_len;
}

fn criticalPathFrom(state: *const ItemState, item_id: []const u8) i64 {
    var max_child: i64 = 0;
    for (state.items.items) |item| {
        for (item.deps) |dep| {
            if (std.mem.eql(u8, dep.id, item_id)) {
                const child_len = criticalPathFrom(state, item.id);
                if (child_len > max_child) max_child = child_len;
            }
        }
    }
    return 1 + max_child;
}

fn countProofComplete(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.items.items) |item| {
        if (item.proof) |proof| {
            if (proof.state == .pass) count += 1;
        }
    }
    return count;
}

fn countItemsWithProofObligations(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.items.items) |item| {
        if (itemHasProofObligations(item)) count += 1;
    }
    return count;
}

fn readyIdsHaveDisjointLocks(state: *const ItemState, ready_ids: []const []const u8) bool {
    for (ready_ids, 0..) |lhs_id, i| {
        const lhs = state.getConst(lhs_id) orelse continue;
        const lhs_roots = if (lhs.lock_roots.len > 0) lhs.lock_roots else lhs.location;
        if (lhs_roots.len == 0) return false;
        for (ready_ids[i + 1 ..]) |rhs_id| {
            const rhs = state.getConst(rhs_id) orelse continue;
            const rhs_roots = if (rhs.lock_roots.len > 0) rhs.lock_roots else rhs.location;
            if (rhs_roots.len == 0) return false;
            if (rootsOverlapAny(lhs_roots, rhs_roots)) return false;
        }
    }
    return true;
}

fn selectApertureIds(allocator: std.mem.Allocator, state: *const ItemState, limit: usize) ![]const []const u8 {
    const candidates = try apertureCandidates(allocator, state, limit);
    var out = std.ArrayList([]const u8).empty;
    for (candidates) |candidate| try out.append(allocator, candidate.id);
    return try out.toOwnedSlice(allocator);
}

fn apertureCandidates(allocator: std.mem.Allocator, state: *const ItemState, limit: usize) ![]const ApertureCandidate {
    const audit = try auditGraph(allocator, state, .implementation_ready);
    var out = std.ArrayList(ApertureCandidate).empty;
    for (state.items.items, 0..) |item, idx| {
        if (!try apertureEligibleItem(allocator, state, item, audit)) continue;
        try out.append(allocator, .{ .id = item.id, .score = apertureScore(state, item), .durable_index = idx });
    }
    const slice = try out.toOwnedSlice(allocator);
    std.mem.sort(ApertureCandidate, slice, state, apertureCandidateLess);
    return slice[0..@min(limit, slice.len)];
}

fn apertureCandidateLess(state: *const ItemState, lhs: ApertureCandidate, rhs: ApertureCandidate) bool {
    _ = state;
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    if (lhs.durable_index != rhs.durable_index) return lhs.durable_index < rhs.durable_index;
    return std.mem.lessThan(u8, lhs.id, rhs.id);
}

fn apertureEligibleItem(allocator: std.mem.Allocator, state: *const ItemState, item: Item, audit: AuditResult) !bool {
    if (item.status != .pending) return false;
    if (!isExecutableItem(item)) return false;
    if (item.claim) |claim| {
        if (claim.state == .held or claim.state == .stale) return false;
    }
    const waiting = try unresolvedDependencyIds(allocator, item, state);
    if (waiting.len > 0) return false;
    for (audit.findings) |finding| {
        if (finding.waived or finding.severity != .@"error") continue;
        if (std.mem.eql(u8, finding.target, item.id)) return false;
    }
    return true;
}

fn apertureScore(state: *const ItemState, item: Item) i64 {
    var score: i64 = priorityWeight(item.priority);
    score += 4 * criticalPathFrom(state, item.id);
    score += 3 * downstreamCount(state, item.id);
    score += 2 * downstreamCount(state, item.id);
    if (itemHasProofObligations(item) or item.validation.len > 0) score += 2;
    if (item.lock_roots.len > 0 or item.location.len > 0) score += 1 else score -= 2;
    score += @intCast(item.intent_refs.len);
    score -= 3 * @as(i64, @intCast(item.uncertainty.len));
    if (item.claim) |claim| {
        if (claim.state == .stale) score -= 4;
    }
    if (item.contract) |contract| {
        if (contract.risks.len > 0 and item.validation.len == 0 and !itemHasProofObligations(item)) score -= 5;
    }
    return score;
}

fn writeApertureCandidateJson(writer: anytype, state: *const ItemState, candidate: ApertureCandidate) !void {
    const item = state.getConst(candidate.id).?;
    try writer.writeByte('{');
    try writer.writeAll("\"version\":1,\"id\":");
    try std.json.Stringify.value(item.id, .{}, writer);
    try writer.writeAll(",\"step\":");
    try std.json.Stringify.value(item.step, .{}, writer);
    try writer.writeAll(",\"priority\":");
    try std.json.Stringify.value(item.priority.asString(), .{}, writer);
    try writer.writeAll(",\"item_type\":");
    try std.json.Stringify.value(item.item_type.asString(), .{}, writer);
    try writer.writeAll(",\"score\":");
    try writer.print("{d}", .{candidate.score});
    try writer.writeAll(",\"rationale\":[\"ready: all dependencies completed\",\"");
    try writer.writeAll(item.priority.asString());
    try writer.writeAll(" priority\"],\"validation\":");
    try writeStringListArray(writer, item.validation);
    try writer.writeAll(",\"location\":");
    try writeStringListArray(writer, item.location);
    try writer.writeAll(",\"lock_roots\":");
    try writeStringListArray(writer, if (item.lock_roots.len > 0) item.lock_roots else item.location);
    try writer.writeByte('}');
}

fn writeAperturePlanJson(writer: anytype, state: *const ItemState, selected: []const ApertureCandidate, limit: usize, strategy: []const u8) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"version\":1,\"strategy\":");
    try std.json.Stringify.value(strategy, .{}, writer);
    try writer.writeAll(",\"limit\":");
    try writer.print("{d}", .{limit});
    try writer.writeAll(",\"selected\":[");
    for (selected, 0..) |candidate, idx| {
        if (idx > 0) try writer.writeByte(',');
        const item = state.getConst(candidate.id).?;
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(item.id, .{}, writer);
        try writer.writeAll(",\"step\":");
        try std.json.Stringify.value(item.step, .{}, writer);
        try writer.writeAll(",\"score\":");
        try writer.print("{d}", .{candidate.score});
        try writer.writeAll(",\"rationale\":[\"ready\",\"ranked by aperture-score\"],\"lock_roots\":");
        try writeStringListArray(writer, if (item.lock_roots.len > 0) item.lock_roots else item.location);
        try writer.writeAll(",\"proof_obligations\":");
        try writeProofObligationCommands(writer, item);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"context\":[],\"waves\":[{\"id\":\"w1\",\"safe_parallel\":");
    var ids = std.ArrayList([]const u8).empty;
    for (selected) |candidate| try ids.append(state.allocator, candidate.id);
    try writer.writeAll(if (readyIdsHaveDisjointLocks(state, ids.items)) "true" else "false");
    try writer.writeAll(",\"items\":");
    try writeStringListArray(writer, ids.items);
    try writer.writeAll("}],\"warnings\":[]}");
}

fn writeProofObligationCommands(writer: anytype, item: *const Item) !void {
    try writer.writeByte('[');
    if (item.contract) |contract| {
        var emitted: usize = 0;
        for (contract.proof_obligations) |obligation| {
            if (obligation.command.len == 0) continue;
            if (emitted > 0) try writer.writeByte(',');
            try std.json.Stringify.value(obligation.command, .{}, writer);
            emitted += 1;
        }
    }
    try writer.writeByte(']');
}

fn writeApertureMarkdown(writer: anytype, state: *const ItemState, selected: []const ApertureCandidate) !void {
    try writer.writeAll("# st aperture\n\n");
    if (selected.len == 0) {
        try writer.writeAll("- (no eligible work)\n");
        return;
    }
    for (selected) |candidate| {
        const item = state.getConst(candidate.id).?;
        try writer.print("- {s} ({d}): {s}\n", .{ item.id, candidate.score, item.step });
    }
}

fn cmdImportOrchplan(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const input_bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);
    const imported_items = try parseOrchplanItems(allocator, input_bytes, input_path, args.backlog_only);

    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    if (args.replace) {
        state.clear();
    }
    for (imported_items) |item| {
        try state.upsert(item);
    }

    try validateState(&state, args.allow_multiple_in_progress);

    const bump: i64 = if (args.replace) 1 else @intCast(@max(imported_items.len, 1));
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + bump, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.replace) {
        try stdout.print("replaced plan from orchplan {s}\n", .{input_path});
    } else {
        try stdout.print("imported {d} orchplan item(s) from {s}\n", .{ imported_items.len, input_path });
    }
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + bump);
    return 0;
}

fn cmdImportProposedPlan(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const input_bytes = try readFileAlloc(allocator, input_path, 4 * 1024 * 1024);

    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    if (args.replace) state.clear();
    const start_at = if (args.start_at) |raw| try parsePositiveUsize(raw) else nextIdNumberWithPrefix(args.id_prefix, &state);
    _ = args.backlog_only;
    const backlog_only = true;
    const imported = try parseProposedPlanItems(
        allocator,
        input_bytes,
        input_path,
        args.id_prefix,
        start_at,
        backlog_only,
        args.infer_linear_deps,
    );
    for (imported) |item| try state.upsert(item);
    if (args.select_ready) {
        _ = try applyPrimeSelection(allocator, &state, .replace_ready, args.limit);
    }
    try validateState(&state, args.allow_multiple_in_progress);

    const bump: i64 = @intCast(@max(imported.len, 1));
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + bump, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("imported {d} proposed plan item(s) from {s}\n", .{ imported.len, input_path });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + bump);
    return 0;
}

fn cmdClaim(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const executor = try normalizeExecutor(allocator, args.executor.?);
    const wave_id = if (args.wave) |raw|
        try requireNonEmptyString(allocator, raw, "--wave")
    else
        "manual";
    const orchplan_wave_ids = if (args.wave != null)
        try collectOrchplanWaveTargetIds(allocator, &state, wave_id)
    else
        &.{};
    const explicit_ids = try parseCliIds(allocator, args.ids);
    const target_ids = if (orchplan_wave_ids.len > 0) blk: {
        if (explicit_ids.len > 0) return error.OrchplanWaveClaimDoesNotAcceptIds;
        break :blk orchplan_wave_ids;
    } else blk: {
        if (explicit_ids.len == 0) return error.MissingIdsValue;
        break :blk explicit_ids;
    };
    const lease_seconds = try parseLeaseSeconds(args.lease_seconds orelse "900");
    const now = try nowUtcAlloc(allocator);
    const lease_expires_at = try addSecondsUtcAlloc(allocator, @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000))) + lease_seconds);
    const actor = buildMutationMeta(allocator, args.allow_multiple_in_progress).actor;

    var claimed_roots: std.ArrayList([]const []const u8) = .empty;
    for (target_ids) |item_id| {
        const item = state.get(item_id) orelse return error.UnknownItemId;
        if (isTerminalStatus(item.status) or item.status == .blocked or item.status == .deferred) return error.InvalidClaimState;

        const waiting = try unresolvedDependencyIds(allocator, item.*, &state);
        if (item.status == .pending and waiting.len > 0) return error.UnresolvedDependencies;

        if (item.claim) |claim| {
            if (claim.state == .held and !claimExpiredAt(claim, now)) return error.ItemAlreadyClaimed;
        }

        const roots = try lockRootsForItem(allocator, item.*);
        try ensureRootsDoNotOverlapHeldClaims(allocator, &state, target_ids, roots, item_id);
        for (claimed_roots.items) |prior| {
            if (rootsOverlapAny(roots, prior)) return error.ScopeClaimConflict;
        }
        try claimed_roots.append(allocator, roots);

        const attempts = if (item.claim) |claim| claim.attempts + 1 else 1;
        item.claim = .{
            .state = .held,
            .owner = actor,
            .executor = executor,
            .wave_id = wave_id,
            .lock_roots = roots,
            .claimed_at = now,
            .lease_seconds = lease_seconds,
            .lease_expires_at = lease_expires_at,
            .heartbeat_at = now,
            .attempts = attempts,
        };
        item.in_plan = true;
        normalizeItemPlanMembership(item);
    }

    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("claimed {d} item(s) in wave {s}\n", .{ target_ids.len, wave_id });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdHeartbeat(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const item = state.get(item_id) orelse return error.UnknownItemId;
    var claim = item.claim orelse return error.NoHeldClaim;
    if (claim.state != .held) return error.NoHeldClaim;

    const now = try nowUtcAlloc(allocator);
    claim.heartbeat_at = now;
    const lease_seconds = if (claim.lease_seconds > 0) claim.lease_seconds else 900;
    claim.lease_expires_at = try addSecondsUtcAlloc(allocator, @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000))) + lease_seconds);
    item.claim = claim;

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("heartbeat refreshed for {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdSetRuntime(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const item = state.get(item_id) orelse return error.UnknownItemId;
    const claim = item.claim orelse return error.NoHeldClaim;
    if (claim.state != .held) return error.NoHeldClaim;

    var runtime = item.runtime orelse RuntimeMeta{};
    runtime.substrate = try normalizeRuntimeSubstrate(allocator, args.substrate.?);
    if (args.thread_id) |raw| runtime.thread_id = try requireNonEmptyString(allocator, raw, "--thread-id");
    if (args.agent_id) |raw| runtime.agent_id = try requireNonEmptyString(allocator, raw, "--agent-id");
    if (args.row_id) |raw| runtime.row_id = try requireNonEmptyString(allocator, raw, "--row-id");
    if (args.output_ref) |raw| runtime.output_ref = try requireNonEmptyString(allocator, raw, "--output-ref");
    runtime.last_event = if (args.last_event) |raw|
        try requireNonEmptyString(allocator, raw, "--last-event")
    else if (runtime.last_event.len > 0)
        runtime.last_event
    else
        "runtime_attached";
    item.runtime = runtime;
    if (item.status == .pending) {
        item.status = .in_progress;
        normalizeItemPlanMembership(item);
    }

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const now = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("attached runtime metadata to {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdSetProof(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const item = state.get(item_id) orelse return error.UnknownItemId;
    var proof = item.proof orelse ProofMeta{};
    proof.state = try normalizeProofState(args.proof_state.?);
    proof.command = try requireNonEmptyString(allocator, args.step.?, "--command");
    proof.evidence_ref = if (args.evidence_ref) |raw|
        try requireNonEmptyString(allocator, raw, "--evidence-ref")
    else
        "";
    proof.last_run_at = try nowUtcAlloc(allocator);
    item.proof = proof;

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, proof.last_run_at, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("updated proof for {s} -> {s}\n", .{ item_id, proof.state.asString() });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdComplete(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const item = state.get(item_id) orelse return error.UnknownItemId;
    if (state.graph_active and state.graph.policy.completion_requires_proof and isExecutableItem(item.*)) {
        if (!args.allow_unproven) {
            var proof = item.proof orelse ProofMeta{};
            proof.state = .pass;
            proof.command = try requireNonEmptyString(allocator, args.step orelse return error.MissingValue, "--command");
            proof.evidence_ref = if (args.evidence_ref) |raw|
                try requireNonEmptyString(allocator, raw, "--evidence-ref")
            else
                "";
            proof.last_run_at = try nowUtcAlloc(allocator);
            item.proof = proof;
        }
        if (proofCompletionMissingReason(item.*)) |missing| {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            if (!args.allow_unproven) {
                try stdout.print("completion blocked for {s}: {s}\n", .{ item_id, missing });
                return 2;
            }
            const waiver_reason = try requireNonEmptyString(allocator, args.reason orelse return error.MissingReason, "--reason");
            const now = try nowUtcAlloc(allocator);
            try addForcedCompletionWaivers(allocator, &state, item_id, waiver_reason, now);
        }
    }
    item.status = .completed;
    normalizeItemPlanMembership(item);

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, ts, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("completed {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdProof(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.proof_command) {
        .audit => try cmdProofAudit(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdProofAudit(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const item = state.getConst(item_id) orelse return error.UnknownItemId;
    const missing = proofCompletionMissingReason(item.*);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    switch (args.format) {
        .json => {
            try stdout.writeAll("{\"version\":1,\"id\":");
            try std.json.Stringify.value(item.id, .{}, stdout);
            try stdout.writeAll(",\"ok\":");
            try stdout.writeAll(if (missing == null) "true" else "false");
            try stdout.writeAll(",\"missing\":");
            if (missing) |reason| try std.json.Stringify.value(reason, .{}, stdout) else try stdout.writeAll("null");
            try stdout.writeAll(",\"proof\":");
            if (item.proof) |proof| try writeProofMetaObject(stdout, proof) else try stdout.writeAll("null");
            try stdout.writeAll(",\"required_obligations\":");
            try writeProofObligationsArray(stdout, proofObligationsForItem(item.*));
            try stdout.writeAll("}\n");
        },
        .markdown, .text, .table => {
            try stdout.print("# st proof audit: {s}\n\n", .{item.id});
            try stdout.print("Status: {s}\n", .{if (missing == null) "PASS" else "FAIL"});
            if (missing) |reason| try stdout.print("Missing: {s}\n", .{reason});
        },
        .plan_sync => return error.InvalidFormat,
    }
    return if (missing == null) 0 else 2;
}

fn cmdRelease(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const item = state.get(item_id) orelse return error.UnknownItemId;
    var claim = item.claim orelse return error.NoHeldClaim;
    if (claim.state != .held and claim.state != .stale) return error.NoHeldClaim;

    const now = try nowUtcAlloc(allocator);
    claim.state = .released;
    claim.heartbeat_at = now;
    claim.lease_expires_at = "";
    item.claim = claim;

    if (item.runtime) |runtime| {
        var next_runtime = runtime;
        next_runtime.last_event = if (args.reason) |raw|
            try requireNonEmptyString(allocator, raw, "--reason")
        else if (next_runtime.last_event.len > 0)
            next_runtime.last_event
        else
            "released";
        item.runtime = next_runtime;
    }

    if (item.status == .in_progress) {
        if (item.proof) |proof| {
            item.status = switch (proof.state) {
                .pass => .completed,
                .fail => .blocked,
                .not_run => .pending,
            };
        } else {
            item.status = .pending;
        }
        normalizeItemPlanMembership(item);
    }

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("released claim for {s}\n", .{item_id});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdReclaimStale(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const now = if (args.now) |raw|
        try requireNonEmptyString(allocator, raw, "--now")
    else
        try nowUtcAlloc(allocator);

    var reclaimed: usize = 0;
    for (state.items.items) |*item| {
        var claim = item.claim orelse continue;
        if (claim.state != .held) continue;
        if (!claimExpiredAt(claim, now)) continue;
        claim.state = .stale;
        claim.owner = "";
        claim.executor = "";
        claim.heartbeat_at = now;
        item.claim = claim;
        item.runtime = null;
        if (item.status == .in_progress) {
            item.status = .pending;
            normalizeItemPlanMembership(item);
        }
        reclaimed += 1;
    }

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("reclaimed {d} stale claim(s)\n", .{reclaimed});
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn cmdImportMeshResults(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);

    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header_line = lines.next() orelse return error.EmptyCsv;
    const headers = try parseHeaderColumns(allocator, header_line);
    const id_index = findFirstHeaderIndex(headers, &.{ "task_id", "item_id", "id" }) orelse return error.MissingIdHeader;
    const row_id_index = findFirstHeaderIndex(headers, &.{ "row_id", "item_id", "id" });
    const decision_index = findFirstHeaderIndex(headers, &.{ "decision", "status" });
    const proof_status_index = findFirstHeaderIndex(headers, &.{"proof_status"});
    const proof_evidence_index = findFirstHeaderIndex(headers, &.{ "proof_evidence", "proof_evidence_ref", "summary" });
    const output_ref_index = findFirstHeaderIndex(headers, &.{ "output_ref", "output_csv_path", "worktree_path" });
    const result_json_index = findFirstHeaderIndex(headers, &.{ "result_json", "result" });

    const now = try nowUtcAlloc(allocator);
    var updated: usize = 0;
    var rows_seen: usize = 0;

    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        rows_seen += 1;

        const item_id = nthCsvField(line, id_index) orelse "";
        if (item_id.len == 0) continue;
        const item = state.get(item_id) orelse continue;

        var runtime = item.runtime orelse RuntimeMeta{};
        runtime.substrate = "spawn_agents_on_csv";
        runtime.row_id = if (row_id_index) |idx|
            (nthCsvField(line, idx) orelse item_id)
        else
            item_id;
        runtime.output_ref = if (output_ref_index) |idx|
            (nthCsvField(line, idx) orelse input_path)
        else
            input_path;

        const result_json = if (result_json_index) |idx| (nthCsvField(line, idx) orelse "") else "";
        const decision = if (decision_index) |idx|
            (nthCsvField(line, idx) orelse extractJsonStringField(allocator, result_json, "decision"))
        else
            extractJsonStringField(allocator, result_json, "decision");
        runtime.last_event = if (decision.len > 0) decision else "mesh_result_imported";
        item.runtime = runtime;

        const proof_status_raw = if (proof_status_index) |idx|
            (nthCsvField(line, idx) orelse extractJsonStringField(allocator, result_json, "proof_status"))
        else
            extractJsonStringField(allocator, result_json, "proof_status");
        if (proof_status_raw.len > 0) {
            var proof = item.proof orelse ProofMeta{};
            proof.state = try normalizeProofStateFlexible(proof_status_raw);
            if (proof.command.len == 0 and item.validation.len > 0) {
                proof.command = item.validation[0];
            }
            proof.evidence_ref = if (proof_evidence_index) |idx|
                (nthCsvField(line, idx) orelse extractJsonStringField(allocator, result_json, "proof_evidence"))
            else
                extractJsonStringField(allocator, result_json, "proof_evidence");
            proof.last_run_at = now;
            item.proof = proof;

            if (proof.state == .pass) {
                item.status = .completed;
            } else if (proof.state == .fail) {
                item.status = .blocked;
            }
            normalizeItemPlanMembership(item);

            if (item.claim) |claim| {
                var next_claim = claim;
                next_claim.state = .released;
                next_claim.lease_expires_at = "";
                item.claim = next_claim;
            }
        }

        updated += 1;
    }

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("imported mesh results for {d} item(s) across {d} row(s)\n", .{ updated, rows_seen });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn emitSyncOutputs(
    allocator: std.mem.Allocator,
    writer: anytype,
    state: *const ItemState,
    allow_multiple_in_progress: bool,
    source_file: []const u8,
    source_seq: i64,
) !void {
    _ = allow_multiple_in_progress;
    try emitPlanSyncWithPolicy(allocator, writer, state, .{ .source_file = source_file, .source_seq = source_seq }, true);
}

fn cmdDoctor(allocator: std.mem.Allocator, args: Args) !u8 {
    const parsed = try readRecordsNoSeqValidation(allocator, args.file);
    const issues = try collectSeqContractIssues(allocator, parsed.records);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;

    if (issues.len == 0) {
        try stdout.print("seq contract ok: {s}\n", .{args.file});
        return 0;
    }

    try stdout.print("seq contract invalid: {s}\n", .{args.file});
    for (issues) |issue| {
        try stdout.print("- {s}\n", .{issue});
    }

    if (!args.repair_seq) {
        return 2;
    }

    const current = try readRecordsNoSeqValidation(allocator, args.file);
    const current_issues = try collectSeqContractIssues(allocator, current.records);
    if (current_issues.len == 0) {
        try stdout.writeAll("repair skipped: seq contract already valid\n");
        return 0;
    }

    var state = try materializeStateFromRecords(allocator, current.records);
    defer state.deinit();
    try validateState(&state, args.allow_multiple_in_progress);

    const repair_seq = current.latest_seq;
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(args.file, &state, repair_seq, ts, meta, RepairMeta{ .op = "doctor_repair_seq" });

    const repaired = try readRecordsNoSeqValidation(allocator, args.file);
    const repaired_issues = try collectSeqContractIssues(allocator, repaired.records);
    if (repaired_issues.len != 0) return error.SeqContractViolation;

    try stdout.print("repaired seq contract via checkpoint seq {d}\n", .{repair_seq});
    return 0;
}

const OrchTask = struct {
    id: []const u8,
    title: []const u8,
    agent: []const u8,
    role: []const u8,
    scopes: []const []const u8,
    locations: []const []const u8,
    validations: []const []const u8,
    depends_on: []const []const u8,
    related_to: []const []const u8,
    wave_id: []const u8,
};

const OrchWave = struct {
    id: []const u8,
    tasks: []const []const u8,
};

fn parseLeaseSeconds(raw: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidLeaseSeconds;
    const parsed = try std.fmt.parseInt(i64, trimmed, 10);
    if (parsed <= 0) return error.InvalidLeaseSeconds;
    return parsed;
}

fn normalizeExecutor(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var lower = std.ArrayList(u8).empty;
    for (std.mem.trim(u8, raw, " \t\r\n")) |c| {
        try lower.append(allocator, std.ascii.toLower(c));
    }
    const value = lower.items;
    if (std.mem.eql(u8, value, "teams") or std.mem.eql(u8, value, "mesh") or std.mem.eql(u8, value, "local")) {
        return value;
    }
    return error.InvalidExecutor;
}

fn normalizeRuntimeSubstrate(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var lower = std.ArrayList(u8).empty;
    for (std.mem.trim(u8, raw, " \t\r\n")) |c| {
        try lower.append(allocator, std.ascii.toLower(c));
    }
    const value = lower.items;
    if (std.mem.eql(u8, value, "spawn_agent") or std.mem.eql(u8, value, "spawn_agents_on_csv") or std.mem.eql(u8, value, "local")) {
        return value;
    }
    return error.InvalidRuntimeSubstrate;
}

fn normalizeProofState(raw: []const u8) !ProofState {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "not_run")) return .not_run;
    if (std.ascii.eqlIgnoreCase(trimmed, "pass")) return .pass;
    if (std.ascii.eqlIgnoreCase(trimmed, "fail")) return .fail;
    return error.InvalidProofState;
}

fn normalizeProofStateFlexible(raw: []const u8) !ProofState {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidProofState;
    if (std.ascii.eqlIgnoreCase(trimmed, "ok") or std.ascii.eqlIgnoreCase(trimmed, "success") or std.ascii.eqlIgnoreCase(trimmed, "passed")) {
        return .pass;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "error") or std.ascii.eqlIgnoreCase(trimmed, "failed")) {
        return .fail;
    }
    return normalizeProofState(trimmed);
}

fn addSecondsUtcAlloc(allocator: std.mem.Allocator, unix_seconds: i64) ![]u8 {
    var days = @divFloor(unix_seconds, 86_400);
    var seconds_of_day = unix_seconds - days * 86_400;
    if (seconds_of_day < 0) {
        seconds_of_day += 86_400;
        days -= 1;
    }

    const date = civilFromDays(days);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(seconds_of_day - hour * 3600, 60);
    const second = seconds_of_day - hour * 3600 - minute * 60;

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u32, @intCast(date.year)),
            @as(u32, @intCast(date.month)),
            @as(u32, @intCast(date.day)),
            @as(u32, @intCast(hour)),
            @as(u32, @intCast(minute)),
            @as(u32, @intCast(second)),
        },
    );
}

fn claimExpiredAt(claim: ClaimMeta, now: []const u8) bool {
    if (claim.lease_expires_at.len == 0) return false;
    return std.mem.order(u8, claim.lease_expires_at, now) != .gt;
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn normalizeScopeToken(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    for (trimmed) |ch| {
        if (ch == '\\') {
            try out.append(allocator, '/');
        } else {
            try out.append(allocator, ch);
        }
    }
    var token = out.items;
    if (std.mem.startsWith(u8, token, "./")) token = token[2..];
    while (std.mem.indexOf(u8, token, "//")) |idx| {
        token[idx] = '/';
        std.mem.copyForwards(u8, token[idx + 1 ..], token[idx + 2 ..]);
        token = token[0 .. token.len - 1];
    }
    while (token.len > 1 and token[token.len - 1] == '/') {
        token = token[0 .. token.len - 1];
    }
    return token;
}

fn isBroadScopeToken(token: []const u8) bool {
    return token.len == 0 or
        std.mem.eql(u8, token, ".") or
        std.mem.eql(u8, token, "*") or
        std.mem.eql(u8, token, "**") or
        std.mem.eql(u8, token, "**/*") or
        std.mem.eql(u8, token, "/");
}

fn lockRootFromScopeToken(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var token = try normalizeScopeToken(allocator, raw);
    if (token.len == 0) return ".";
    if (std.mem.endsWith(u8, token, "/**/*")) token = token[0 .. token.len - 5];
    if (std.mem.endsWith(u8, token, "/**")) token = token[0 .. token.len - 3];
    const glob_index = std.mem.indexOfAny(u8, token, "*?[") orelse token.len;
    token = std.mem.trim(u8, token[0..glob_index], "/");
    if (isBroadScopeToken(token)) return ".";
    return token;
}

fn lockRootsForScope(allocator: std.mem.Allocator, scope: []const []const u8) ![]const []const u8 {
    var roots = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(allocator);
    if (scope.len == 0) {
        try roots.append(allocator, ".");
        return try roots.toOwnedSlice(allocator);
    }
    for (scope) |entry| {
        const root = try lockRootFromScopeToken(allocator, entry);
        if (seen.get(root) != null) continue;
        try seen.put(root, {});
        try roots.append(allocator, root);
    }
    if (roots.items.len == 0) try roots.append(allocator, ".");
    return try roots.toOwnedSlice(allocator);
}

fn lockRootsForItem(allocator: std.mem.Allocator, item: Item) ![]const []const u8 {
    if (item.claim) |claim| {
        if (claim.lock_roots.len > 0) return claim.lock_roots;
    }
    return lockRootsForScope(allocator, item.scope);
}

fn rootsOverlap(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, ".") or std.mem.eql(u8, b, ".")) return true;
    if (std.mem.eql(u8, a, b)) return true;
    if (a.len > b.len and std.mem.startsWith(u8, a, b) and a[b.len] == '/') return true;
    if (b.len > a.len and std.mem.startsWith(u8, b, a) and b[a.len] == '/') return true;
    return false;
}

fn rootsOverlapAny(a: []const []const u8, b: []const []const u8) bool {
    for (a) |left| {
        for (b) |right| {
            if (rootsOverlap(left, right)) return true;
        }
    }
    return false;
}

fn ensureRootsDoNotOverlapHeldClaims(
    allocator: std.mem.Allocator,
    state: *const ItemState,
    target_ids: []const []const u8,
    roots: []const []const u8,
    current_id: []const u8,
) !void {
    _ = allocator;
    for (state.items.items) |item| {
        if (std.mem.eql(u8, item.id, current_id) or containsString(target_ids, item.id)) continue;
        const claim = item.claim orelse continue;
        if (claim.state != .held) continue;
        const prior_roots: []const []const u8 = if (claim.lock_roots.len > 0) claim.lock_roots else &[_][]const u8{"."};
        if (rootsOverlapAny(roots, prior_roots)) return error.ScopeClaimConflict;
    }
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonStringListValue(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]const []const u8 {
    const value = value_opt orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    switch (value) {
        .string => |s| {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len > 0) try out.append(allocator, trimmed);
        },
        .array => |arr| {
            for (arr.items) |entry| {
                if (entry != .string) continue;
                const trimmed = std.mem.trim(u8, entry.string, " \t\r\n");
                if (trimmed.len > 0) try out.append(allocator, trimmed);
            }
        },
        else => {},
    }
    if (out.items.len == 0) return &.{};
    return try out.toOwnedSlice(allocator);
}

fn parseOrchplanItems(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    locator: []const u8,
    backlog_only: bool,
) ![]Item {
    const tasks = if (parseOrchplanTasksFromJson(allocator, bytes)) |parsed|
        parsed
    else |_|
        try parseOrchplanTasksFromYaml(allocator, bytes);

    var items = std.ArrayList(Item).empty;
    for (tasks) |task| {
        const step = if (task.title.len > 0) task.title else task.id;
        const deps = try depsFromStringIds(allocator, task.depends_on);
        var item = Item{
            .id = task.id,
            .step = step,
            .status = .pending,
            .priority = .medium,
            .in_plan = !backlog_only,
            .deps = deps,
            .notes = "",
            .comments = &.{},
            .related_to = task.related_to,
            .scope = task.scopes,
            .location = task.locations,
            .validation = task.validations,
            .agent = task.agent,
            .role = task.role,
            .source = .{
                .kind = "orchplan",
                .locator = locator,
                .source_task_id = task.id,
                .wave_id = task.wave_id,
            },
        };
        normalizeItemPlanMembership(&item);
        try items.append(allocator, item);
    }
    return try items.toOwnedSlice(allocator);
}

fn depsFromStringIds(allocator: std.mem.Allocator, ids: []const []const u8) ![]Dep {
    if (ids.len == 0) return &.{};
    var out = std.ArrayList(Dep).empty;
    for (ids) |id| {
        try out.append(allocator, .{ .id = id, .type = "blocks" });
    }
    return try out.toOwnedSlice(allocator);
}

const ProposedStep = struct {
    text: []const u8,
    heading: []const u8,
    ordinal: usize,
};

fn parseProposedPlanItems(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    locator: []const u8,
    id_prefix: []const u8,
    start_at: usize,
    backlog_only: bool,
    infer_linear_deps: bool,
) ![]Item {
    const steps = try parseProposedPlanSteps(allocator, bytes);
    var items = std.ArrayList(Item).empty;
    var previous_impl_id: []const u8 = "";
    for (steps, 0..) |step, idx| {
        const id = try std.fmt.allocPrint(allocator, "{s}-{d:0>3}", .{ id_prefix, start_at + idx });
        var deps: []Dep = &.{};
        if (infer_linear_deps and previous_impl_id.len > 0 and proposedHeadingIsImplementation(step.heading)) {
            deps = try depsFromStringIds(allocator, &[_][]const u8{previous_impl_id});
        }
        var item = Item{
            .id = id,
            .step = step.text,
            .status = .pending,
            .priority = .medium,
            .in_plan = !backlog_only,
            .deps = deps,
            .notes = "",
            .comments = &.{},
            .source = .{
                .kind = "proposed_plan",
                .locator = locator,
                .source_task_id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ if (step.heading.len > 0) step.heading else "step", step.ordinal }),
            },
        };
        normalizeItemPlanMembership(&item);
        try items.append(allocator, item);
        if (proposedHeadingIsImplementation(step.heading)) previous_impl_id = id;
    }
    return try items.toOwnedSlice(allocator);
}

fn parseProposedPlanSteps(allocator: std.mem.Allocator, bytes: []const u8) ![]ProposedStep {
    var out = std.ArrayList(ProposedStep).empty;
    var current_heading: []const u8 = "";
    var accepted_section = false;
    var ordinal: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) {
            var heading_start: usize = 0;
            while (heading_start < line.len and line[heading_start] == '#') : (heading_start += 1) {}
            const heading = std.mem.trim(u8, line[heading_start..], " \t\r");
            current_heading = heading;
            accepted_section = proposedHeadingAccepted(heading);
            continue;
        }
        const maybe_step = proposedStepText(line, accepted_section) orelse continue;
        const cleaned = try stripProposedStepLabel(allocator, maybe_step);
        if (cleaned.len == 0) continue;
        ordinal += 1;
        try out.append(allocator, .{
            .text = cleaned,
            .heading = current_heading,
            .ordinal = ordinal,
        });
    }
    return try out.toOwnedSlice(allocator);
}

fn proposedStepText(line: []const u8, accepted_section: bool) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "- [ ]")) return std.mem.trim(u8, line[5..], " \t\r");
    if (std.mem.startsWith(u8, line, "- [x]") or std.mem.startsWith(u8, line, "- [X]")) return null;
    if (numberedListPayload(line)) |payload| return payload;
    if (accepted_section and std.mem.startsWith(u8, line, "- ")) return std.mem.trim(u8, line[2..], " \t\r");
    if (accepted_section and std.mem.startsWith(u8, line, "* ")) return std.mem.trim(u8, line[2..], " \t\r");
    return null;
}

fn numberedListPayload(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == 0 or i >= line.len or line[i] != '.') return null;
    return std.mem.trim(u8, line[i + 1 ..], " \t\r");
}

fn stripProposedStepLabel(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var text = std.mem.trim(u8, raw, " \t\r");
    inline for (&.{ "Step", "Task" }) |label| {
        if (std.ascii.startsWithIgnoreCase(text, label)) {
            var idx = label.len;
            while (idx < text.len and text[idx] == ' ') : (idx += 1) {}
            while (idx < text.len and std.ascii.isDigit(text[idx])) : (idx += 1) {}
            if (idx < text.len and text[idx] == ':') {
                text = std.mem.trim(u8, text[idx + 1 ..], " \t\r");
            }
        }
    }
    return allocator.dupe(u8, text);
}

fn proposedHeadingAccepted(heading: []const u8) bool {
    return std.ascii.eqlIgnoreCase(heading, "Implementation") or
        std.ascii.eqlIgnoreCase(heading, "Key Changes") or
        std.ascii.eqlIgnoreCase(heading, "Steps") or
        std.ascii.eqlIgnoreCase(heading, "Tasks") or
        std.ascii.eqlIgnoreCase(heading, "Test Plan");
}

fn proposedHeadingIsImplementation(heading: []const u8) bool {
    return std.ascii.eqlIgnoreCase(heading, "Implementation") or
        std.ascii.eqlIgnoreCase(heading, "Key Changes") or
        std.ascii.eqlIgnoreCase(heading, "Steps") or
        std.ascii.eqlIgnoreCase(heading, "Tasks");
}

fn nextIdNumberWithPrefix(prefix: []const u8, state: *const ItemState) usize {
    var max_seen: usize = 0;
    for (state.items.items) |item| {
        if (!std.mem.startsWith(u8, item.id, prefix)) continue;
        if (item.id.len <= prefix.len or item.id[prefix.len] != '-') continue;
        const parsed = std.fmt.parseInt(usize, item.id[prefix.len + 1 ..], 10) catch continue;
        if (parsed > max_seen) max_seen = parsed;
    }
    return max_seen + 1;
}

fn parseOrchplanTasksFromJson(allocator: std.mem.Allocator, bytes: []const u8) ![]OrchTask {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    if (parsed.value != .object) return error.InvalidOrchPlan;
    const obj = parsed.value.object;
    const tasks_value = obj.get("tasks") orelse return error.InvalidOrchPlan;
    if (tasks_value != .array) return error.InvalidOrchPlan;

    const waves = try parseOrchplanWavesFromJson(allocator, obj.get("waves"));
    var tasks: std.ArrayList(OrchTask) = .empty;
    for (tasks_value.array.items) |entry| {
        if (entry != .object) continue;
        const id = jsonStringField(entry.object, "id") orelse continue;
        try tasks.append(allocator, .{
            .id = id,
            .title = jsonStringField(entry.object, "title") orelse "",
            .agent = jsonStringField(entry.object, "agent") orelse "",
            .role = jsonStringField(entry.object, "role") orelse "",
            .scopes = try jsonStringListValue(allocator, entry.object.get("scope")),
            .locations = try jsonStringListValue(allocator, entry.object.get("location")),
            .validations = try jsonStringListValue(allocator, entry.object.get("validation")),
            .depends_on = try jsonStringListValue(allocator, entry.object.get("depends_on")),
            .related_to = try jsonStringListValue(allocator, entry.object.get("related_to")),
            .wave_id = findWaveIdForTask(waves, id),
        });
    }
    if (tasks.items.len == 0) return error.InvalidOrchPlan;
    return try tasks.toOwnedSlice(allocator);
}

fn parseOrchplanWavesFromJson(allocator: std.mem.Allocator, value_opt: ?std.json.Value) ![]OrchWave {
    const value = value_opt orelse return &.{};
    if (value != .array) return &.{};
    var waves: std.ArrayList(OrchWave) = .empty;
    for (value.array.items) |entry| {
        if (entry != .object) continue;
        const wave_id = jsonStringField(entry.object, "id") orelse continue;
        const tasks = try jsonStringListValue(allocator, entry.object.get("tasks"));
        try waves.append(allocator, .{ .id = wave_id, .tasks = tasks });
    }
    return try waves.toOwnedSlice(allocator);
}

fn parseOrchplanTasksFromYaml(allocator: std.mem.Allocator, bytes: []const u8) ![]OrchTask {
    const Section = enum { none, tasks, waves };
    const ActiveList = enum { none, scope, location, validation, depends_on, related_to, wave_tasks };
    const TaskBuilder = struct {
        id: []const u8 = "",
        title: []const u8 = "",
        agent: []const u8 = "",
        role: []const u8 = "",
        scopes: std.ArrayList([]const u8) = .empty,
        locations: std.ArrayList([]const u8) = .empty,
        validations: std.ArrayList([]const u8) = .empty,
        depends_on: std.ArrayList([]const u8) = .empty,
        related_to: std.ArrayList([]const u8) = .empty,
    };
    const WaveBuilder = struct {
        id: []const u8 = "",
        tasks: std.ArrayList([]const u8) = .empty,
    };

    var section: Section = .none;
    var active: ActiveList = .none;
    var current_task: ?TaskBuilder = null;
    var current_wave: ?WaveBuilder = null;
    var tasks: std.ArrayList(OrchTask) = .empty;
    var waves: std.ArrayList(OrchWave) = .empty;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const no_comment = stripYamlComment(line_raw);
        const trimmed_line = std.mem.trim(u8, no_comment, " \t\r");
        if (trimmed_line.len == 0) continue;

        if (std.mem.eql(u8, trimmed_line, "tasks:")) {
            if (current_wave) |*wave| {
                if (wave.id.len > 0) {
                    const task_ids = if (wave.tasks.items.len == 0) &.{} else try wave.tasks.toOwnedSlice(allocator);
                    try waves.append(allocator, .{ .id = wave.id, .tasks = task_ids });
                }
                current_wave = null;
            }
            section = .tasks;
            active = .none;
            continue;
        }
        if (std.mem.eql(u8, trimmed_line, "waves:")) {
            if (current_task) |*task| {
                if (task.id.len > 0) {
                    try tasks.append(allocator, .{
                        .id = task.id,
                        .title = task.title,
                        .agent = task.agent,
                        .role = task.role,
                        .scopes = if (task.scopes.items.len == 0) &.{} else try task.scopes.toOwnedSlice(allocator),
                        .locations = if (task.locations.items.len == 0) &.{} else try task.locations.toOwnedSlice(allocator),
                        .validations = if (task.validations.items.len == 0) &.{} else try task.validations.toOwnedSlice(allocator),
                        .depends_on = if (task.depends_on.items.len == 0) &.{} else try task.depends_on.toOwnedSlice(allocator),
                        .related_to = if (task.related_to.items.len == 0) &.{} else try task.related_to.toOwnedSlice(allocator),
                        .wave_id = "",
                    });
                }
                current_task = null;
            }
            section = .waves;
            active = .none;
            continue;
        }

        switch (section) {
            .tasks => {
                if (std.mem.startsWith(u8, trimmed_line, "- id:")) {
                    if (current_task) |*task| {
                        if (task.id.len > 0) {
                            try tasks.append(allocator, .{
                                .id = task.id,
                                .title = task.title,
                                .agent = task.agent,
                                .role = task.role,
                                .scopes = if (task.scopes.items.len == 0) &.{} else try task.scopes.toOwnedSlice(allocator),
                                .locations = if (task.locations.items.len == 0) &.{} else try task.locations.toOwnedSlice(allocator),
                                .validations = if (task.validations.items.len == 0) &.{} else try task.validations.toOwnedSlice(allocator),
                                .depends_on = if (task.depends_on.items.len == 0) &.{} else try task.depends_on.toOwnedSlice(allocator),
                                .related_to = if (task.related_to.items.len == 0) &.{} else try task.related_to.toOwnedSlice(allocator),
                                .wave_id = "",
                            });
                        }
                    }
                    current_task = TaskBuilder{};
                    active = .none;
                    current_task.?.id = parseYamlScalar(trimmed_line["- id:".len..]);
                    continue;
                }
                if (current_task == null) continue;
                if (std.mem.startsWith(u8, trimmed_line, "- ") and active != .none) {
                    const item = parseYamlScalar(trimmed_line[2..]);
                    if (item.len > 0) {
                        switch (active) {
                            .scope => try current_task.?.scopes.append(allocator, item),
                            .location => try current_task.?.locations.append(allocator, item),
                            .validation => try current_task.?.validations.append(allocator, item),
                            .depends_on => try current_task.?.depends_on.append(allocator, item),
                            .related_to => try current_task.?.related_to.append(allocator, item),
                            else => {},
                        }
                    }
                    continue;
                }
                const colon_idx = std.mem.indexOfScalar(u8, trimmed_line, ':') orelse continue;
                const key = std.mem.trim(u8, trimmed_line[0..colon_idx], " \t\r");
                const raw_val = trimmed_line[colon_idx + 1 ..];
                if (std.mem.eql(u8, key, "id")) {
                    current_task.?.id = parseYamlScalar(raw_val);
                    active = .none;
                } else if (std.mem.eql(u8, key, "title")) {
                    current_task.?.title = parseYamlScalar(raw_val);
                    active = .none;
                } else if (std.mem.eql(u8, key, "agent")) {
                    current_task.?.agent = parseYamlScalar(raw_val);
                    active = .none;
                } else if (std.mem.eql(u8, key, "role")) {
                    current_task.?.role = parseYamlScalar(raw_val);
                    active = .none;
                } else if (std.mem.eql(u8, key, "scope")) {
                    active = .scope;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_task.?.scopes.append(allocator, item);
                } else if (std.mem.eql(u8, key, "location")) {
                    active = .location;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_task.?.locations.append(allocator, item);
                } else if (std.mem.eql(u8, key, "validation")) {
                    active = .validation;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_task.?.validations.append(allocator, item);
                } else if (std.mem.eql(u8, key, "depends_on")) {
                    active = .depends_on;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_task.?.depends_on.append(allocator, item);
                } else if (std.mem.eql(u8, key, "related_to")) {
                    active = .related_to;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_task.?.related_to.append(allocator, item);
                }
            },
            .waves => {
                if (std.mem.startsWith(u8, trimmed_line, "- id:")) {
                    if (current_wave) |*wave| {
                        if (wave.id.len > 0) {
                            const task_ids = if (wave.tasks.items.len == 0) &.{} else try wave.tasks.toOwnedSlice(allocator);
                            try waves.append(allocator, .{ .id = wave.id, .tasks = task_ids });
                        }
                    }
                    current_wave = WaveBuilder{};
                    active = .none;
                    current_wave.?.id = parseYamlScalar(trimmed_line["- id:".len..]);
                    continue;
                }
                if (current_wave == null) continue;
                if (std.mem.startsWith(u8, trimmed_line, "- ") and active == .wave_tasks) {
                    const item = parseYamlScalar(trimmed_line[2..]);
                    if (item.len > 0) try current_wave.?.tasks.append(allocator, item);
                    continue;
                }
                const colon_idx = std.mem.indexOfScalar(u8, trimmed_line, ':') orelse continue;
                const key = std.mem.trim(u8, trimmed_line[0..colon_idx], " \t\r");
                const raw_val = trimmed_line[colon_idx + 1 ..];
                if (std.mem.eql(u8, key, "id")) {
                    current_wave.?.id = parseYamlScalar(raw_val);
                    active = .none;
                } else if (std.mem.eql(u8, key, "tasks")) {
                    active = .wave_tasks;
                    const inline_items = try parseYamlInlineList(allocator, raw_val);
                    for (inline_items) |item| try current_wave.?.tasks.append(allocator, item);
                }
            },
            .none => {},
        }
    }

    if (current_task) |*task| {
        if (task.id.len > 0) {
            try tasks.append(allocator, .{
                .id = task.id,
                .title = task.title,
                .agent = task.agent,
                .role = task.role,
                .scopes = if (task.scopes.items.len == 0) &.{} else try task.scopes.toOwnedSlice(allocator),
                .locations = if (task.locations.items.len == 0) &.{} else try task.locations.toOwnedSlice(allocator),
                .validations = if (task.validations.items.len == 0) &.{} else try task.validations.toOwnedSlice(allocator),
                .depends_on = if (task.depends_on.items.len == 0) &.{} else try task.depends_on.toOwnedSlice(allocator),
                .related_to = if (task.related_to.items.len == 0) &.{} else try task.related_to.toOwnedSlice(allocator),
                .wave_id = "",
            });
        }
    }
    if (current_wave) |*wave| {
        if (wave.id.len > 0) {
            const task_ids = if (wave.tasks.items.len == 0) &.{} else try wave.tasks.toOwnedSlice(allocator);
            try waves.append(allocator, .{ .id = wave.id, .tasks = task_ids });
        }
    }

    for (tasks.items) |*task| {
        task.wave_id = findWaveIdForTask(waves.items, task.id);
    }

    if (tasks.items.len == 0) return error.InvalidOrchPlan;
    return try tasks.toOwnedSlice(allocator);
}

fn stripYamlComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    for (line, 0..) |ch, idx| {
        if (ch == '\'' and !in_double) in_single = !in_single;
        if (ch == '"' and !in_single) in_double = !in_double;
        if (ch == '#' and !in_single and !in_double) return line[0..idx];
    }
    return line;
}

fn parseYamlScalar(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))) {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn parseYamlInlineList(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        var it = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
        while (it.next()) |part| {
            const item = parseYamlScalar(part);
            if (item.len > 0) try out.append(allocator, item);
        }
    } else {
        const item = parseYamlScalar(trimmed);
        if (item.len > 0) try out.append(allocator, item);
    }
    if (out.items.len == 0) return &.{};
    return try out.toOwnedSlice(allocator);
}

fn findWaveIdForTask(waves: []const OrchWave, task_id: []const u8) []const u8 {
    for (waves) |wave| {
        for (wave.tasks) |candidate| {
            if (std.mem.eql(u8, candidate, task_id)) return wave.id;
        }
    }
    return "";
}

fn parseHeaderColumns(allocator: std.mem.Allocator, header_line: []const u8) ![][]const u8 {
    var cols: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, header_line, ',');
    while (it.next()) |col| {
        try cols.append(allocator, std.mem.trim(u8, col, " \t\r"));
    }
    return try cols.toOwnedSlice(allocator);
}

fn findHeaderIndex(headers: []const []const u8, needle: []const u8) ?usize {
    for (headers, 0..) |header, idx| {
        if (std.mem.eql(u8, header, needle)) return idx;
    }
    return null;
}

fn findFirstHeaderIndex(headers: []const []const u8, needles: []const []const u8) ?usize {
    for (needles) |needle| {
        if (findHeaderIndex(headers, needle)) |idx| return idx;
    }
    return null;
}

fn nthCsvField(line: []const u8, idx: usize) ?[]const u8 {
    var current: usize = 0;
    var field_start: usize = 0;
    var i: usize = 0;
    var in_quotes = false;

    while (i <= line.len) : (i += 1) {
        const at_end = i == line.len;
        const ch: u8 = if (!at_end) line[i] else ',';
        if (!at_end and ch == '"') {
            in_quotes = !in_quotes;
            continue;
        }
        if (!in_quotes and ch == ',') {
            if (current == idx) return std.mem.trim(u8, line[field_start..i], " \t\r\"");
            current += 1;
            field_start = i + 1;
        }
    }
    return null;
}

fn extractJsonStringField(allocator: std.mem.Allocator, raw_json: []const u8, key: []const u8) []const u8 {
    if (raw_json.len == 0) return "";
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch return "";
    if (parsed.value != .object) return "";
    const value = parsed.value.object.get(key) orelse return "";
    return switch (value) {
        .string => |s| s,
        else => "",
    };
}

fn loadValidatedState(allocator: std.mem.Allocator, path: []const u8, allow_multiple: bool) !struct { state: ItemState, latest_seq: i64 } {
    const parsed = try readRecords(allocator, path);
    var state = try materializeStateFromRecords(allocator, parsed.records);
    try validateState(&state, allow_multiple);
    return .{ .state = state, .latest_seq = parsed.latest_seq };
}

fn readRecords(allocator: std.mem.Allocator, path: []const u8) !ParsedRecords {
    const parsed = try readRecordsNoSeqValidation(allocator, path);
    const issues = try collectSeqContractIssues(allocator, parsed.records);
    if (issues.len != 0) return error.SeqContractViolation;
    return parsed;
}

fn readRecordsNoSeqValidation(allocator: std.mem.Allocator, path: []const u8) !ParsedRecords {
    if (!fileExists(path)) {
        return .{ .records = &.{}, .latest_seq = 0 };
    }

    const bytes = try readFileAlloc(allocator, path, 64 * 1024 * 1024);
    var lines = std.mem.splitScalar(u8, bytes, '\n');

    var records = std.ArrayList(std.json.Value).empty;
    var latest: i64 = 0;

    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        if (parsed.value != .object) return error.InvalidRecord;
        try records.append(allocator, parsed.value);

        if (intField(parsed.value, "seq")) |seq| {
            if (seq < 0) return error.InvalidSeq;
            if (seq > latest) latest = seq;
        }
    }

    return .{ .records = try records.toOwnedSlice(allocator), .latest_seq = latest };
}

fn materializeStateFromRecords(allocator: std.mem.Allocator, records: []const std.json.Value) !ItemState {
    var state = ItemState.init(allocator);

    for (records, 0..) |record, idx| {
        const source_index: i64 = @intCast(idx + 1);
        const version = intField(record, "v") orelse return error.UnsupportedSchemaVersion;

        if (version == 2) {
            try applyEventOp(allocator, &state, record, source_index, version);
            continue;
        }
        if (version != SchemaVersion and version != GraphSchemaVersion) return error.UnsupportedSchemaVersion;

        const lane = normalizedLane(record) orelse return error.InvalidLane;
        if (std.mem.eql(u8, lane, "checkpoint")) {
            state.clear();
            if (version == GraphSchemaVersion) {
                state.graph = try canonicalGraphEnvelope(allocator, objectField(record, "graph") orelse .{ .object = .empty });
                state.graph_active = true;
            } else {
                state.graph = .{};
                state.graph_active = false;
            }
            const items_value = objectField(record, "items") orelse return error.InvalidCheckpoint;
            const arr = switch (items_value) {
                .array => |a| a.items,
                else => return error.InvalidCheckpoint,
            };
            for (arr) |raw_item| {
                const item = try canonicalItem(allocator, raw_item);
                try state.upsert(item);
            }
            continue;
        }

        try applyEventOp(allocator, &state, record, source_index, version);
    }

    normalizeStatePlanMembership(&state);
    try state.rebuildIndex();
    return state;
}

fn applyEventOp(allocator: std.mem.Allocator, state: *ItemState, record: std.json.Value, source_index: i64, version: i64) !void {
    _ = source_index;
    const op = normalizedOp(record) orelse return error.InvalidOp;

    if (std.mem.eql(u8, op, "init")) return;

    if (std.mem.eql(u8, op, "replace") or std.mem.eql(u8, op, "replace_all")) {
        const items_value = objectField(record, "items") orelse return error.ReplaceMissingItems;
        const arr = switch (items_value) {
            .array => |a| a.items,
            else => return error.ReplaceMissingItems,
        };
        state.clear();
        if (version == GraphSchemaVersion) {
            state.graph = try canonicalGraphEnvelope(allocator, objectField(record, "graph") orelse .{ .object = .empty });
            state.graph_active = true;
        }
        for (arr) |raw_item| {
            const item = try canonicalItem(allocator, raw_item);
            try state.upsert(item);
        }
        return;
    }

    if (std.mem.eql(u8, op, "upsert") or std.mem.eql(u8, op, "upsert_item")) {
        const raw_item = objectField(record, "item") orelse return error.UpsertMissingItem;
        const item = try canonicalItem(allocator, raw_item);
        try state.upsert(item);
        return;
    }

    const item_id = try requireNonEmptyString(allocator, stringField(record, "id") orelse return error.MissingItemId, "id");

    if (!std.mem.eql(u8, op, "remove") and state.get(item_id) == null) return error.UnknownItemId;

    if (std.mem.eql(u8, op, "set_status")) {
        const status_raw = stringField(record, "status") orelse return error.MissingStatusValue;
        const status = try normalizeStatus(status_raw);
        const item = state.get(item_id).?;
        item.status = status;
        normalizeItemPlanMembership(item);
        return;
    }

    if (std.mem.eql(u8, op, "set_deps")) {
        const deps_value = objectField(record, "deps") orelse return error.MissingDepsValue;
        const deps = try normalizeDeps(allocator, deps_value);
        state.get(item_id).?.deps = deps;
        return;
    }

    if (std.mem.eql(u8, op, "set_notes")) {
        const notes_value = if (objectField(record, "notes")) |v| v else std.json.Value{ .string = "" };
        const notes = switch (notes_value) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidNotes,
        };
        state.get(item_id).?.notes = notes;
        return;
    }

    if (std.mem.eql(u8, op, "add_comment") or std.mem.eql(u8, op, "append_comment") or std.mem.eql(u8, op, "comment")) {
        var comment_value = objectField(record, "comment");

        var fallback_comment_obj: std.json.ObjectMap = .empty;
        if (comment_value == null) {
            const ts = stringField(record, "ts") orelse return error.InvalidComment;
            const author = stringField(record, "author") orelse return error.InvalidComment;
            const text = stringField(record, "text") orelse return error.InvalidComment;
            try fallback_comment_obj.put(allocator, "ts", .{ .string = ts });
            try fallback_comment_obj.put(allocator, "author", .{ .string = author });
            try fallback_comment_obj.put(allocator, "text", .{ .string = text });
            comment_value = .{ .object = fallback_comment_obj };
        }

        const comment = try canonicalComment(allocator, comment_value.?);
        const item = state.get(item_id) orelse return error.UnknownItemId;

        var comments = std.ArrayList(Comment).empty;
        try comments.appendSlice(allocator, item.comments);
        try comments.append(allocator, comment);
        item.comments = try comments.toOwnedSlice(allocator);
        return;
    }

    if (std.mem.eql(u8, op, "remove")) {
        try state.remove(item_id);
        return;
    }

    return error.InvalidOp;
}

fn writeCanonicalRecords(
    path: []const u8,
    state: *ItemState,
    seq: i64,
    ts: []const u8,
    mutation: MutationMeta,
    repair: ?RepairMeta,
) !void {
    var out: std.Io.Writer.Allocating = .init(state.allocator);
    defer out.deinit();

    try writeEventRecord(&out.writer, seq, ts, state.items.items, mutation, repair, if (state.graph_active) state.graph else null);
    try out.writer.writeByte('\n');
    try writeCheckpointRecord(&out.writer, seq, ts, state.items.items, mutation, repair, if (state.graph_active) state.graph else null);
    try out.writer.writeByte('\n');

    const payload = try out.toOwnedSlice();
    try writeTextAtomic(state.allocator, path, payload);
}

fn writeInitRecord(allocator: std.mem.Allocator, path: []const u8, ts: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeByte('{');
    try out.writer.writeAll("\"v\":3,\"ts\":");
    try std.json.Stringify.value(ts, .{}, &out.writer);
    try out.writer.writeAll(",\"lane\":\"event\",\"seq\":1,\"op\":\"init\"}");
    try out.writer.writeByte('\n');

    const payload = try out.toOwnedSlice();
    try writeTextAtomic(allocator, path, payload);
}

fn writeEventRecord(
    writer: anytype,
    seq: i64,
    ts: []const u8,
    items: []const Item,
    mutation: MutationMeta,
    repair: ?RepairMeta,
    graph: ?GraphEnvelope,
) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"v\":");
    try writer.print("{d}", .{if (graph != null) GraphSchemaVersion else SchemaVersion});
    try writer.writeByte(',');
    try writer.writeAll("\"ts\":");
    try std.json.Stringify.value(ts, .{}, writer);
    try writer.writeAll(",\"lane\":\"event\"");
    try writer.writeAll(",\"seq\":");
    try writer.print("{d}", .{seq});
    try writer.writeAll(",\"op\":\"replace\",\"items\":");
    try writeItemsArray(writer, items);
    if (graph) |envelope| {
        try writer.writeAll(",\"graph\":");
        try writeGraphEnvelopeObject(writer, envelope);
    }
    if (repair) |repair_meta| {
        try writer.writeAll(",\"repair\":{\"op\":");
        try std.json.Stringify.value(repair_meta.op, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll(",\"mutation\":");
    try writeMutationMeta(writer, mutation);
    try writer.writeByte('}');
}

fn writeCheckpointRecord(
    writer: anytype,
    seq: i64,
    ts: []const u8,
    items: []const Item,
    mutation: MutationMeta,
    repair: ?RepairMeta,
    graph: ?GraphEnvelope,
) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"v\":");
    try writer.print("{d}", .{if (graph != null) GraphSchemaVersion else SchemaVersion});
    try writer.writeByte(',');
    try writer.writeAll("\"ts\":");
    try std.json.Stringify.value(ts, .{}, writer);
    try writer.writeAll(",\"lane\":\"checkpoint\"");
    try writer.writeAll(",\"seq\":");
    try writer.print("{d}", .{seq});
    try writer.writeAll(",\"items\":");
    try writeItemsArray(writer, items);
    if (graph) |envelope| {
        try writer.writeAll(",\"graph\":");
        try writeGraphEnvelopeObject(writer, envelope);
    }
    if (repair) |repair_meta| {
        try writer.writeAll(",\"repair\":{\"op\":");
        try std.json.Stringify.value(repair_meta.op, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll(",\"mutation\":");
    try writeMutationMeta(writer, mutation);
    try writer.writeByte('}');
}

fn writeMutationMeta(writer: anytype, meta: MutationMeta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"allow_multiple_in_progress\":");
    try writer.writeAll(if (meta.allow_multiple_in_progress) "true" else "false");
    try writer.writeAll(",\"actor\":");
    try std.json.Stringify.value(meta.actor, .{}, writer);
    try writer.writeAll(",\"pid\":");
    try writer.print("{d}", .{meta.pid});
    if (meta.session) |session| {
        try writer.writeAll(",\"session\":");
        try std.json.Stringify.value(session, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeItemsArray(writer: anytype, items: []const Item) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeItemObject(writer, item);
    }
    try writer.writeByte(']');
}

fn writeItemObject(writer: anytype, item: Item) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"id\":");
    try std.json.Stringify.value(item.id, .{}, writer);
    try writer.writeAll(",\"step\":");
    try std.json.Stringify.value(item.step, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(item.status.asString(), .{}, writer);
    try writer.writeAll(",\"priority\":");
    try std.json.Stringify.value(item.priority.asString(), .{}, writer);
    try writer.writeAll(",\"in_plan\":");
    try writer.writeAll(if (item.in_plan) "true" else "false");
    try writer.writeAll(",\"deps\":");
    try writeDepsArray(writer, item.deps);
    try writer.writeAll(",\"notes\":");
    try std.json.Stringify.value(item.notes, .{}, writer);
    try writer.writeAll(",\"comments\":");
    try writeCommentsArray(writer, item.comments);
    try writeOptionalItemMetadata(writer, item);
    try writer.writeByte('}');
}

fn writeDepsArray(writer: anytype, deps: []const Dep) !void {
    try writer.writeByte('[');
    for (deps, 0..) |dep, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(dep.id, .{}, writer);
        try writer.writeAll(",\"type\":");
        try std.json.Stringify.value(dep.type, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeCommentsArray(writer: anytype, comments: []const Comment) !void {
    try writer.writeByte('[');
    for (comments, 0..) |comment, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"ts\":");
        try std.json.Stringify.value(comment.ts, .{}, writer);
        try writer.writeAll(",\"author\":");
        try std.json.Stringify.value(comment.author, .{}, writer);
        try writer.writeAll(",\"text\":");
        try std.json.Stringify.value(comment.text, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeStringListArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, idx| {
        if (idx > 0) try writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, writer);
    }
    try writer.writeByte(']');
}

fn writeGraphLinksArray(writer: anytype, links: []const GraphLink) !void {
    try writer.writeByte('[');
    for (links, 0..) |link, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"id\":");
        try std.json.Stringify.value(link.id, .{}, writer);
        try writer.writeAll(",\"type\":");
        try std.json.Stringify.value(link.type, .{}, writer);
        if (link.reason.len > 0) {
            try writer.writeAll(",\"reason\":");
            try std.json.Stringify.value(link.reason, .{}, writer);
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeProofObligationsArray(writer: anytype, obligations: []const ProofObligation) !void {
    try writer.writeByte('[');
    for (obligations, 0..) |obligation, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"id\":");
        try std.json.Stringify.value(obligation.id, .{}, writer);
        try writer.writeAll(",\"kind\":");
        try std.json.Stringify.value(obligation.kind, .{}, writer);
        if (obligation.command.len > 0) {
            try writer.writeAll(",\"command\":");
            try std.json.Stringify.value(obligation.command, .{}, writer);
        }
        if (obligation.evidence_ref.len > 0) {
            try writer.writeAll(",\"evidence_ref\":");
            try std.json.Stringify.value(obligation.evidence_ref, .{}, writer);
        }
        try writer.writeAll(",\"required\":");
        try writer.writeAll(if (obligation.required) "true" else "false");
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeContractObject(writer: anytype, contract: Contract) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"objective\":");
    try std.json.Stringify.value(contract.objective, .{}, writer);
    try writer.writeAll(",\"background\":");
    try std.json.Stringify.value(contract.background, .{}, writer);
    try writer.writeAll(",\"implementation_approach\":");
    try std.json.Stringify.value(contract.implementation_approach, .{}, writer);
    try writer.writeAll(",\"success_criteria\":");
    try writeStringListArray(writer, contract.success_criteria);
    try writer.writeAll(",\"proof_obligations\":");
    try writeProofObligationsArray(writer, contract.proof_obligations);
    try writer.writeAll(",\"risks\":");
    try writeStringListArray(writer, contract.risks);
    try writer.writeByte('}');
}

fn writeOptionalItemMetadata(writer: anytype, item: Item) !void {
    if (item.related_to.len > 0) {
        try writer.writeAll(",\"related_to\":");
        try writeStringListArray(writer, item.related_to);
    }
    if (item.scope.len > 0) {
        try writer.writeAll(",\"scope\":");
        try writeStringListArray(writer, item.scope);
    }
    if (item.location.len > 0) {
        try writer.writeAll(",\"location\":");
        try writeStringListArray(writer, item.location);
    }
    if (item.validation.len > 0) {
        try writer.writeAll(",\"validation\":");
        try writeStringListArray(writer, item.validation);
    }
    if (item.agent.len > 0) {
        try writer.writeAll(",\"agent\":");
        try std.json.Stringify.value(item.agent, .{}, writer);
    }
    if (item.role.len > 0) {
        try writer.writeAll(",\"role\":");
        try std.json.Stringify.value(item.role, .{}, writer);
    }
    if (item.source) |source| {
        try writer.writeAll(",\"source\":");
        try writeSourceMetaObject(writer, source);
    }
    if (item.claim) |claim| {
        try writer.writeAll(",\"claim\":");
        try writeClaimMetaObject(writer, claim);
    }
    if (item.runtime) |runtime| {
        try writer.writeAll(",\"runtime\":");
        try writeRuntimeMetaObject(writer, runtime);
    }
    if (item.proof) |proof| {
        try writer.writeAll(",\"proof\":");
        try writeProofMetaObject(writer, proof);
    }
    if (item.item_type != .task) {
        try writer.writeAll(",\"item_type\":");
        try std.json.Stringify.value(item.item_type.asString(), .{}, writer);
    }
    if (item.parent_id) |parent_id| {
        try writer.writeAll(",\"parent_id\":");
        try std.json.Stringify.value(parent_id, .{}, writer);
    }
    if (item.links.len > 0) {
        try writer.writeAll(",\"links\":");
        try writeGraphLinksArray(writer, item.links);
    }
    if (item.intent_refs.len > 0) {
        try writer.writeAll(",\"intent_refs\":");
        try writeStringListArray(writer, item.intent_refs);
    }
    if (item.acceptance.len > 0) {
        try writer.writeAll(",\"acceptance\":");
        try writeStringListArray(writer, item.acceptance);
    }
    if (item.contract) |contract| {
        try writer.writeAll(",\"contract\":");
        try writeContractObject(writer, contract);
    }
    if (item.labels.len > 0) {
        try writer.writeAll(",\"labels\":");
        try writeStringListArray(writer, item.labels);
    }
    if (item.lock_roots.len > 0) {
        try writer.writeAll(",\"lock_roots\":");
        try writeStringListArray(writer, item.lock_roots);
    }
    if (item.uncertainty.len > 0) {
        try writer.writeAll(",\"uncertainty\":");
        try writeStringListArray(writer, item.uncertainty);
    }
    if (item.non_goals.len > 0) {
        try writer.writeAll(",\"non_goals\":");
        try writeStringListArray(writer, item.non_goals);
    }
}

fn writeSourceMetaObject(writer: anytype, source: SourceMeta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"kind\":");
    try std.json.Stringify.value(source.kind, .{}, writer);
    try writer.writeAll(",\"locator\":");
    try std.json.Stringify.value(source.locator, .{}, writer);
    if (source.source_task_id.len > 0) {
        try writer.writeAll(",\"source_task_id\":");
        try std.json.Stringify.value(source.source_task_id, .{}, writer);
    }
    if (source.wave_id.len > 0) {
        try writer.writeAll(",\"wave_id\":");
        try std.json.Stringify.value(source.wave_id, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeClaimMetaObject(writer: anytype, claim: ClaimMeta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"state\":");
    try std.json.Stringify.value(claim.state.asString(), .{}, writer);
    if (claim.owner.len > 0) {
        try writer.writeAll(",\"owner\":");
        try std.json.Stringify.value(claim.owner, .{}, writer);
    }
    if (claim.executor.len > 0) {
        try writer.writeAll(",\"executor\":");
        try std.json.Stringify.value(claim.executor, .{}, writer);
    }
    if (claim.wave_id.len > 0) {
        try writer.writeAll(",\"wave_id\":");
        try std.json.Stringify.value(claim.wave_id, .{}, writer);
    }
    if (claim.lock_roots.len > 0) {
        try writer.writeAll(",\"lock_roots\":");
        try writeStringListArray(writer, claim.lock_roots);
    }
    if (claim.claimed_at.len > 0) {
        try writer.writeAll(",\"claimed_at\":");
        try std.json.Stringify.value(claim.claimed_at, .{}, writer);
    }
    try writer.writeAll(",\"lease_seconds\":");
    try writer.print("{d}", .{claim.lease_seconds});
    if (claim.lease_expires_at.len > 0) {
        try writer.writeAll(",\"lease_expires_at\":");
        try std.json.Stringify.value(claim.lease_expires_at, .{}, writer);
    }
    if (claim.heartbeat_at.len > 0) {
        try writer.writeAll(",\"heartbeat_at\":");
        try std.json.Stringify.value(claim.heartbeat_at, .{}, writer);
    }
    try writer.writeAll(",\"attempts\":");
    try writer.print("{d}", .{claim.attempts});
    try writer.writeByte('}');
}

fn writeRuntimeMetaObject(writer: anytype, runtime: RuntimeMeta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"substrate\":");
    try std.json.Stringify.value(runtime.substrate, .{}, writer);
    if (runtime.thread_id.len > 0) {
        try writer.writeAll(",\"thread_id\":");
        try std.json.Stringify.value(runtime.thread_id, .{}, writer);
    }
    if (runtime.agent_id.len > 0) {
        try writer.writeAll(",\"agent_id\":");
        try std.json.Stringify.value(runtime.agent_id, .{}, writer);
    }
    if (runtime.row_id.len > 0) {
        try writer.writeAll(",\"row_id\":");
        try std.json.Stringify.value(runtime.row_id, .{}, writer);
    }
    if (runtime.output_ref.len > 0) {
        try writer.writeAll(",\"output_ref\":");
        try std.json.Stringify.value(runtime.output_ref, .{}, writer);
    }
    if (runtime.last_event.len > 0) {
        try writer.writeAll(",\"last_event\":");
        try std.json.Stringify.value(runtime.last_event, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeProofMetaObject(writer: anytype, proof: ProofMeta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"state\":");
    try std.json.Stringify.value(proof.state.asString(), .{}, writer);
    if (proof.command.len > 0) {
        try writer.writeAll(",\"command\":");
        try std.json.Stringify.value(proof.command, .{}, writer);
    }
    if (proof.evidence_ref.len > 0) {
        try writer.writeAll(",\"evidence_ref\":");
        try std.json.Stringify.value(proof.evidence_ref, .{}, writer);
    }
    if (proof.last_run_at.len > 0) {
        try writer.writeAll(",\"last_run_at\":");
        try std.json.Stringify.value(proof.last_run_at, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeGraphEnvelopeObject(writer: anytype, graph: GraphEnvelope) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"version\":");
    try writer.print("{d}", .{graph.version});
    try writer.writeAll(",\"policy\":");
    try writeGraphPolicyObject(writer, graph.policy);
    try writer.writeAll(",\"intent\":");
    try writeIntentArray(writer, graph.intent);
    try writer.writeAll(",\"waivers\":");
    try writeWaiversArray(writer, graph.waivers);
    try writer.writeAll(",\"polish\":");
    try writePolishStateObject(writer, graph.polish);
    try writer.writeAll(",\"fingerprints\":");
    try writeGraphFingerprintsObject(writer, graph.fingerprints);
    try writer.writeByte('}');
}

fn writeGraphPolicyObject(writer: anytype, policy: GraphPolicy) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"completion_requires_proof\":");
    try writer.writeAll(if (policy.completion_requires_proof) "true" else "false");
    try writer.writeAll(",\"implementation_ready_required\":");
    try writer.writeAll(if (policy.implementation_ready_required) "true" else "false");
    try writer.writeAll(",\"default_projection_strategy\":");
    try std.json.Stringify.value(policy.default_projection_strategy, .{}, writer);
    try writer.writeAll(",\"default_gate\":");
    try std.json.Stringify.value(policy.default_gate, .{}, writer);
    try writer.writeAll(",\"max_aperture_items\":");
    try writer.print("{d}", .{policy.max_aperture_items});
    try writer.writeByte('}');
}

fn writeIntentSourceObject(writer: anytype, source: IntentSource) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"kind\":");
    try std.json.Stringify.value(source.kind, .{}, writer);
    if (source.locator.len > 0) {
        try writer.writeAll(",\"locator\":");
        try std.json.Stringify.value(source.locator, .{}, writer);
    }
    if (source.anchor.len > 0) {
        try writer.writeAll(",\"anchor\":");
        try std.json.Stringify.value(source.anchor, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeIntentArray(writer: anytype, intent: []const IntentAtom) !void {
    try writer.writeByte('[');
    for (intent, 0..) |atom, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"id\":");
        try std.json.Stringify.value(atom.id, .{}, writer);
        if (atom.source) |source| {
            try writer.writeAll(",\"source\":");
            try writeIntentSourceObject(writer, source);
        }
        try writer.writeAll(",\"text\":");
        try std.json.Stringify.value(atom.text, .{}, writer);
        try writer.writeAll(",\"category\":");
        try std.json.Stringify.value(atom.category, .{}, writer);
        try writer.writeAll(",\"disposition\":");
        try std.json.Stringify.value(atom.disposition, .{}, writer);
        if (atom.reason.len > 0) {
            try writer.writeAll(",\"reason\":");
            try std.json.Stringify.value(atom.reason, .{}, writer);
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeWaiversArray(writer: anytype, waivers: []const Waiver) !void {
    try writer.writeByte('[');
    for (waivers, 0..) |waiver, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"id\":");
        try std.json.Stringify.value(waiver.id, .{}, writer);
        try writer.writeAll(",\"gate\":");
        try std.json.Stringify.value(waiver.gate, .{}, writer);
        try writer.writeAll(",\"code\":");
        try std.json.Stringify.value(waiver.code, .{}, writer);
        try writer.writeAll(",\"target\":");
        try std.json.Stringify.value(waiver.target, .{}, writer);
        try writer.writeAll(",\"reason\":");
        try std.json.Stringify.value(waiver.reason, .{}, writer);
        try writer.writeAll(",\"expires\":");
        try std.json.Stringify.value(waiver.expires, .{}, writer);
        if (waiver.created_at.len > 0) {
            try writer.writeAll(",\"created_at\":");
            try std.json.Stringify.value(waiver.created_at, .{}, writer);
        }
        if (waiver.created_by.len > 0) {
            try writer.writeAll(",\"created_by\":");
            try std.json.Stringify.value(waiver.created_by, .{}, writer);
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writePolishStateObject(writer: anytype, polish: PolishState) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"session_id\":");
    try std.json.Stringify.value(polish.session_id, .{}, writer);
    try writer.writeAll(",\"passes\":[");
    for (polish.passes, 0..) |pass, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writePolishPassObject(writer, pass);
    }
    try writer.writeAll("]}");
}

fn writePolishPassObject(writer: anytype, pass: PolishPass) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"pass\":");
    try writer.print("{d}", .{pass.pass});
    try writer.writeAll(",\"seq\":");
    try writer.print("{d}", .{pass.seq});
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(pass.created_at, .{}, writer);
    try writer.writeAll(",\"structure_fingerprint\":");
    try std.json.Stringify.value(pass.structure_fingerprint, .{}, writer);
    try writer.writeAll(",\"contract_fingerprint\":");
    try std.json.Stringify.value(pass.contract_fingerprint, .{}, writer);
    try writer.writeAll(",\"coverage_fingerprint\":");
    try std.json.Stringify.value(pass.coverage_fingerprint, .{}, writer);
    try writer.writeAll(",\"execution_fingerprint\":");
    try std.json.Stringify.value(pass.execution_fingerprint, .{}, writer);
    try writer.writeAll(",\"audit_gate\":");
    try std.json.Stringify.value(pass.audit_gate, .{}, writer);
    try writer.writeAll(",\"hard_failures\":");
    try writer.print("{d}", .{pass.hard_failures});
    try writer.writeAll(",\"warnings\":");
    try writer.print("{d}", .{pass.warnings});
    try writer.writeAll(",\"delta\":");
    try writePolishDeltaObject(writer, pass.delta);
    try writer.writeByte('}');
}

fn writePolishDeltaObject(writer: anytype, delta: PolishDelta) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"items_added\":");
    try writer.print("{d}", .{delta.items_added});
    try writer.writeAll(",\"items_removed\":");
    try writer.print("{d}", .{delta.items_removed});
    try writer.writeAll(",\"items_split\":");
    try writer.print("{d}", .{delta.items_split});
    try writer.writeAll(",\"deps_changed\":");
    try writer.print("{d}", .{delta.deps_changed});
    try writer.writeAll(",\"contracts_changed\":");
    try writer.print("{d}", .{delta.contracts_changed});
    try writer.writeAll(",\"intent_coverage_changed\":");
    try writer.print("{d}", .{delta.intent_coverage_changed});
    try writer.writeByte('}');
}

fn writeGraphFingerprintsObject(writer: anytype, fingerprints: GraphFingerprints) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"structure\":");
    try std.json.Stringify.value(fingerprints.structure, .{}, writer);
    try writer.writeAll(",\"contract\":");
    try std.json.Stringify.value(fingerprints.contract, .{}, writer);
    try writer.writeAll(",\"coverage\":");
    try std.json.Stringify.value(fingerprints.coverage, .{}, writer);
    try writer.writeAll(",\"execution\":");
    try std.json.Stringify.value(fingerprints.execution, .{}, writer);
    try writer.writeByte('}');
}

fn writeSnapshotJson(writer: anytype, state: *const ItemState) !void {
    try writer.writeByte('{');
    if (state.graph_active) {
        try writer.writeAll("\"graph\":");
        try writeGraphEnvelopeObject(writer, state.graph);
        try writer.writeByte(',');
    }
    try writer.writeAll("\"items\":");
    try writeItemsArray(writer, state.items.items);
    try writer.writeByte('}');
}

fn renderShow(
    allocator: std.mem.Allocator,
    writer: anytype,
    state: *const ItemState,
    format: OutputFormat,
    surface: Surface,
) !void {
    const enriched = try enrichItems(allocator, state);
    const filtered = try filterRowsBySurface(allocator, enriched, surface);

    switch (format) {
        .markdown => try renderShowMarkdown(allocator, writer, filtered, surface),
        .table => try renderTable(writer, filtered),
        .json => {
            try writeShowJson(writer, state, filtered);
            try writer.writeByte('\n');
        },
        .plan_sync, .text => return error.InvalidFormat,
    }
}

fn renderItemRows(allocator: std.mem.Allocator, writer: anytype, rows: []const EnrichedItem, format: OutputFormat) !void {
    switch (format) {
        .markdown => {
            if (rows.len == 0) {
                try writer.writeAll("- (none)\n");
                return;
            }
            for (rows) |row| {
                try writer.writeAll("- ");
                try writer.writeAll(row.item.id);
                try writer.writeByte(' ');
                try writer.writeAll(row.item.step);

                var detail_buf: std.ArrayList(u8) = .empty;
                defer detail_buf.deinit(allocator);
                if (row.dep_state != .na) {
                    var detail_writer_alloc: std.Io.Writer.Allocating = .fromArrayList(allocator, &detail_buf);
                    try detail_writer_alloc.writer.print("dep_state: {s}", .{row.dep_state.asString()});
                }
                if (row.item.deps.len > 0) {
                    if (detail_buf.items.len > 0) try detail_buf.appendSlice(allocator, "; ");
                    try detail_buf.appendSlice(allocator, "deps: ");
                    for (row.item.deps, 0..) |dep, idx| {
                        if (idx > 0) try detail_buf.appendSlice(allocator, ", ");
                        if (std.mem.eql(u8, dep.type, "blocks")) {
                            try detail_buf.appendSlice(allocator, dep.id);
                        } else {
                            const dep_text = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ dep.id, dep.type });
                            defer allocator.free(dep_text);
                            try detail_buf.appendSlice(allocator, dep_text);
                        }
                    }
                }
                if (row.waiting_on.len > 0) {
                    if (detail_buf.items.len > 0) try detail_buf.appendSlice(allocator, "; ");
                    try detail_buf.appendSlice(allocator, "waiting: ");
                    for (row.waiting_on, 0..) |id, idx| {
                        if (idx > 0) try detail_buf.appendSlice(allocator, ", ");
                        try detail_buf.appendSlice(allocator, id);
                    }
                }

                if (detail_buf.items.len > 0) {
                    try writer.writeAll(" (");
                    try writer.writeAll(detail_buf.items);
                    try writer.writeByte(')');
                }
                try writer.writeByte('\n');
            }
        },
        .table => try renderTable(writer, rows),
        .json => {
            try writeEnrichedItemsJson(writer, rows);
            try writer.writeByte('\n');
        },
        .plan_sync, .text => return error.InvalidFormat,
    }
}

fn renderShowMarkdown(
    allocator: std.mem.Allocator,
    writer: anytype,
    rows: []const EnrichedItem,
    surface: Surface,
) !void {
    if (rows.len == 0) {
        const empty_label = switch (surface) {
            .plan => "- [ ] (empty plan)\n",
            .all => "- (no tasks)\n",
            .backlog => "- (no backlog tasks)\n",
        };
        try writer.writeAll(empty_label);
        return;
    }

    const Section = struct {
        title: []const u8,
    };

    const sections = [_]Section{
        .{ .title = "In Progress" },
        .{ .title = "Ready" },
        .{ .title = "Waiting on Dependencies" },
        .{ .title = "Blocked" },
        .{ .title = "Deferred" },
        .{ .title = "Canceled" },
        .{ .title = "Completed" },
    };

    var first_section = true;
    for (sections) |section| {
        var matched: usize = 0;
        for (rows) |row| {
            if (rowMatchesSection(section.title, row)) matched += 1;
        }
        if (matched == 0) continue;

        if (!first_section) try writer.writeByte('\n');
        first_section = false;

        try writer.writeAll("### ");
        try writer.writeAll(section.title);
        try writer.writeByte('\n');

        for (rows) |row| {
            if (!rowMatchesSection(section.title, row)) continue;

            const marker = statusMarker(row.item.status);
            try writer.writeAll("- ");
            try writer.writeAll(marker);
            try writer.writeByte(' ');
            try writer.writeAll(row.item.id);
            try writer.writeByte(' ');

            if (row.item.status == .canceled) {
                try writer.writeAll("~~");
                try writer.writeAll(row.item.step);
                try writer.writeAll("~~");
            } else {
                try writer.writeAll(row.item.step);
            }

            var details = std.ArrayList(u8).empty;
            defer details.deinit(allocator);

            if (row.dep_state != .na) {
                var details_writer_alloc: std.Io.Writer.Allocating = .fromArrayList(allocator, &details);
                try details_writer_alloc.writer.print("dep_state: {s}", .{row.dep_state.asString()});
            }
            if (row.item.deps.len > 0) {
                if (details.items.len > 0) try details.appendSlice(allocator, "; ");
                try details.appendSlice(allocator, "deps: ");
                for (row.item.deps, 0..) |dep, idx| {
                    if (idx > 0) try details.appendSlice(allocator, ", ");
                    if (std.mem.eql(u8, dep.type, "blocks")) {
                        try details.appendSlice(allocator, dep.id);
                    } else {
                        const dep_text = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ dep.id, dep.type });
                        defer allocator.free(dep_text);
                        try details.appendSlice(allocator, dep_text);
                    }
                }
            }
            if (row.waiting_on.len > 0) {
                if (details.items.len > 0) try details.appendSlice(allocator, "; ");
                try details.appendSlice(allocator, "waiting: ");
                for (row.waiting_on, 0..) |id, idx| {
                    if (idx > 0) try details.appendSlice(allocator, ", ");
                    try details.appendSlice(allocator, id);
                }
            }
            if (row.item.status != .pending and row.item.status != .completed) {
                if (details.items.len > 0) try details.appendSlice(allocator, "; ");
                const status_text = try std.fmt.allocPrint(allocator, "status: {s}", .{row.item.status.asString()});
                defer allocator.free(status_text);
                try details.appendSlice(allocator, status_text);
            }

            if (details.items.len > 0) {
                try writer.writeAll(" (");
                try writer.writeAll(details.items);
                try writer.writeByte(')');
            }
            if (surface == .all) {
                try writer.print(" [in_plan={s}]", .{if (effectiveInPlan(row.item.*)) "true" else "false"});
            }
            try writer.writeByte('\n');
        }
    }
}

fn rowMatchesSection(section: []const u8, row: EnrichedItem) bool {
    if (std.mem.eql(u8, section, "In Progress")) return row.item.status == .in_progress;
    if (std.mem.eql(u8, section, "Ready")) return row.item.status == .pending and row.dep_state == .ready;
    if (std.mem.eql(u8, section, "Waiting on Dependencies")) return row.item.status == .pending and row.dep_state == .waiting_on_deps;
    if (std.mem.eql(u8, section, "Blocked")) return row.item.status == .blocked;
    if (std.mem.eql(u8, section, "Deferred")) return row.item.status == .deferred;
    if (std.mem.eql(u8, section, "Canceled")) return row.item.status == .canceled;
    if (std.mem.eql(u8, section, "Completed")) return row.item.status == .completed;
    return false;
}

fn statusMarker(status: Status) []const u8 {
    return switch (status) {
        .pending => "[ ]",
        .in_progress => "[~]",
        .completed => "[x]",
        .blocked => "[!]",
        .deferred => "[-]",
        .canceled => "[ ]",
    };
}

fn renderTable(writer: anytype, rows: []const EnrichedItem) !void {
    try writer.writeAll("ID         STATUS       IN_PLAN  DEP_STATE          WAITING_ON            DEPS                 STEP\n");
    try writer.writeAll("---------------------------------------------------------------------------------------------------------\n");

    for (rows) |row| {
        var waiting_buf: [128]u8 = undefined;
        var deps_buf: [128]u8 = undefined;

        const waiting = try joinCommaLimited(waiting_buf[0..], row.waiting_on);
        const deps = try formatDepsLimited(deps_buf[0..], row.item.deps);

        try writer.print(
            "{s:<10} {s:<12} {s:<8} {s:<18} {s:<20} {s:<20} {s}\n",
            .{
                row.item.id,
                row.item.status.asString(),
                if (effectiveInPlan(row.item.*)) "true" else "false",
                row.dep_state.asString(),
                waiting,
                deps,
                row.item.step,
            },
        );
    }
}

fn writeEnrichedItemObject(writer: anytype, row: EnrichedItem) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"id\":");
    try std.json.Stringify.value(row.item.id, .{}, writer);
    try writer.writeAll(",\"step\":");
    try std.json.Stringify.value(row.item.step, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(row.item.status.asString(), .{}, writer);
    try writer.writeAll(",\"priority\":");
    try std.json.Stringify.value(row.item.priority.asString(), .{}, writer);
    try writer.writeAll(",\"in_plan\":");
    try writer.writeAll(if (effectiveInPlan(row.item.*)) "true" else "false");
    try writer.writeAll(",\"deps\":");
    try writeDepsArray(writer, row.item.deps);
    try writer.writeAll(",\"notes\":");
    try std.json.Stringify.value(row.item.notes, .{}, writer);
    try writer.writeAll(",\"comments\":");
    try writeCommentsArray(writer, row.item.comments);
    try writer.writeAll(",\"dep_state\":");
    try std.json.Stringify.value(row.dep_state.asString(), .{}, writer);
    try writer.writeAll(",\"waiting_on\":");
    try writeWaitingOnArray(writer, row.waiting_on);
    try writeOptionalItemMetadata(writer, row.item.*);
    try writeDerivedExecutionFields(writer, row);
    try writer.writeByte('}');
}

fn writeDerivedExecutionFields(writer: anytype, row: EnrichedItem) !void {
    if (row.item.claim == null and row.item.runtime == null and row.lock_roots.len == 0) return;
    try writer.writeAll(",\"claim_state\":");
    try std.json.Stringify.value(row.claim_state.asString(), .{}, writer);
    try writer.writeAll(",\"claim_stale\":");
    try writer.writeAll(if (row.claim_stale) "true" else "false");
    try writer.writeAll(",\"lock_roots\":");
    try writeStringListArray(writer, row.lock_roots);
    try writer.writeAll(",\"executor_state\":");
    try std.json.Stringify.value(row.executor_state, .{}, writer);
}

fn writeWaitingOnArray(writer: anytype, waiting_on: []const []const u8) !void {
    try writer.writeByte('[');
    for (waiting_on, 0..) |item_id, idx| {
        if (idx > 0) try writer.writeByte(',');
        try std.json.Stringify.value(item_id, .{}, writer);
    }
    try writer.writeByte(']');
}

fn writeEnrichedItemsJson(writer: anytype, rows: []const EnrichedItem) !void {
    try writer.writeAll("{\"items\":[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeEnrichedItemObject(writer, row);
    }
    try writer.writeAll("]}");
}

fn writeShowJson(writer: anytype, state: *const ItemState, rows: []const EnrichedItem) !void {
    try writer.writeByte('{');
    if (state.graph_active) {
        try writer.writeAll("\"graph\":");
        try writeGraphEnvelopeObject(writer, state.graph);
        try writer.writeByte(',');
    }
    try writer.writeAll("\"items\":[");
    for (rows, 0..) |row, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeEnrichedItemObject(writer, row);
    }
    try writer.writeAll("]}");
}

fn emitPlanSync(
    allocator: std.mem.Allocator,
    writer: anytype,
    state: *const ItemState,
    allow_multiple_in_progress: bool,
    prefixed: bool,
) !void {
    _ = allow_multiple_in_progress;
    const policy = ProjectionPolicy{};
    try emitPlanSyncWithPolicy(allocator, writer, state, policy, prefixed);
}

fn emitPlanSyncWithPolicy(
    allocator: std.mem.Allocator,
    writer: anytype,
    state: *const ItemState,
    policy: ProjectionPolicy,
    prefixed: bool,
) !void {
    const result = try computeProjectionResult(allocator, state, policy);
    if (prefixed) {
        try writer.writeAll("plan_sync: ");
    }

    try writer.writeAll("{\"version\":");
    try writer.print("{d}", .{PlanSyncVersion});
    try writer.writeAll(",\"source\":{\"file\":");
    try std.json.Stringify.value(policy.source_file, .{}, writer);
    try writer.writeAll(",\"seq\":");
    try writer.print("{d}", .{policy.source_seq});
    try writer.writeAll("},\"explanation\":");
    try std.json.Stringify.value("Primed from st selected frontier.", .{}, writer);
    try writer.writeAll(",\"projection\":{\"target\":");
    try std.json.Stringify.value(policy.target.asString(), .{}, writer);
    try writer.writeAll(",\"mode\":");
    try std.json.Stringify.value(policy.mode.asString(), .{}, writer);
    try writer.writeAll(",\"limit\":");
    try writer.print("{d}", .{policy.limit});
    try writer.writeAll(",\"empty_reason\":");
    if (result.empty_reason) |reason| {
        try std.json.Stringify.value(reason, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"warnings\":");
    try writeStringListArray(writer, result.warnings);
    try writer.writeAll("},\"items\":[");
    for (result.rows, 0..) |row, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeEnrichedItemObject(writer, row);
    }
    try writer.writeAll("],\"codex\":{\"plan\":[");
    try writeCodexProjectionEntries(writer, result.codex_plan);
    try writer.writeAll("]},\"opencode\":{\"todos\":[");
    try writeOpencodeProjectionEntries(writer, result.opencode_todos);
    try writer.writeAll("]}}\n");
}

fn codexPlanStepAlloc(allocator: std.mem.Allocator, item: Item) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ item.id, item.step });
}

fn opencodeTodoStatusForRow(row: EnrichedItem) []const u8 {
    var mapped = switch (row.item.status) {
        .in_progress => "in_progress",
        .completed => "completed",
        .canceled => "cancelled",
        .pending, .blocked, .deferred => "pending",
    };
    if (row.dep_state == .waiting_on_deps and std.mem.eql(u8, mapped, "in_progress")) {
        mapped = "pending";
    }
    return mapped;
}

fn computeProjectionResult(
    allocator: std.mem.Allocator,
    state: *const ItemState,
    policy: ProjectionPolicy,
) !ProjectionResult {
    const rows = try enrichItems(allocator, state);
    return computeProjectionResultFromRows(allocator, rows, policy);
}

fn computeProjectionResultFromRows(
    allocator: std.mem.Allocator,
    rows: []const EnrichedItem,
    policy: ProjectionPolicy,
) !ProjectionResult {
    const primary_id = choosePrimaryCodexInProgress(rows);
    var warnings = std.ArrayList([]const u8).empty;
    const active_count = countCodexEligibleInProgress(rows);
    if (active_count > 1) {
        try warnings.append(allocator, "multiple durable in_progress items projected with one Codex active row");
    }

    var codex = std.ArrayList(CodexPlanProjectionEntry).empty;
    if (policy.target == .codex or policy.target == .all) {
        try computeCodexPlanEntries(allocator, rows, policy, primary_id, &codex);
    }

    var opencode = std.ArrayList(OpencodeTodoProjectionEntry).empty;
    if (policy.target == .opencode or policy.target == .all) {
        try computeOpencodeTodos(allocator, rows, policy, &opencode);
    }

    var selected_ids = std.ArrayList([]const u8).empty;
    for (rows) |row| {
        if (effectiveInPlan(row.item.*)) try selected_ids.append(allocator, row.item.id);
    }

    const empty_reason: ?[]const u8 = if (codex.items.len == 0 and opencode.items.len == 0)
        "no_projectable_frontier"
    else
        null;

    return .{
        .rows = rows,
        .codex_plan = try codex.toOwnedSlice(allocator),
        .opencode_todos = try opencode.toOwnedSlice(allocator),
        .selected_ids = try selected_ids.toOwnedSlice(allocator),
        .empty_reason = empty_reason,
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

fn computeCodexPlanEntries(
    allocator: std.mem.Allocator,
    rows: []const EnrichedItem,
    policy: ProjectionPolicy,
    primary_id: ?[]const u8,
    out: *std.ArrayList(CodexPlanProjectionEntry),
) !void {
    var emitted: usize = 0;
    for (rows) |row| {
        if (emitted >= policy.limit) break;
        if (!isCodexProjectableRow(row, policy, primary_id)) continue;
        const status = codexProjectionStatusForRow(row, primary_id);
        const step = try codexPlanStepAlloc(allocator, row.item.*);
        try out.append(allocator, .{ .id = row.item.id, .step = step, .status = status });
        emitted += 1;
    }
}

fn computeOpencodeTodos(
    allocator: std.mem.Allocator,
    rows: []const EnrichedItem,
    policy: ProjectionPolicy,
    out: *std.ArrayList(OpencodeTodoProjectionEntry),
) !void {
    var emitted: usize = 0;
    for (rows) |row| {
        if (emitted >= policy.limit) break;
        if (!effectiveInPlan(row.item.*)) continue;
        if (isTerminalStatus(row.item.status) or row.item.status == .deferred or row.item.status == .canceled) continue;
        if (row.claim_stale) continue;
        if (!policy.include_waiting_pending and row.dep_state == .waiting_on_deps) continue;
        if (row.item.status == .blocked) continue;
        try out.append(allocator, .{
            .id = row.item.id,
            .content = row.item.step,
            .status = opencodeTodoStatusForRow(row),
            .priority = row.item.priority.asString(),
        });
        emitted += 1;
    }
}

fn isCodexProjectableRow(row: EnrichedItem, policy: ProjectionPolicy, primary_id: ?[]const u8) bool {
    _ = primary_id;
    if (!effectiveInPlan(row.item.*)) return false;
    if (row.item.status == .completed) return policy.include_completed_context;
    if (row.item.status == .blocked or row.item.status == .deferred or row.item.status == .canceled) return false;
    if (row.claim_stale) return false;
    if (row.dep_state == .waiting_on_deps and !policy.include_waiting_pending) return false;
    return row.item.status == .pending or row.item.status == .in_progress;
}

fn choosePrimaryCodexInProgress(rows: []const EnrichedItem) ?[]const u8 {
    for (rows) |row| {
        if (!eligibleCodexInProgress(row)) continue;
        if (row.item.runtime) |runtime| {
            if (std.mem.eql(u8, runtime.substrate, "local")) return row.item.id;
        }
    }
    for (rows) |row| {
        if (eligibleCodexInProgress(row) and !row.claim_stale) return row.item.id;
    }
    for (rows) |row| {
        if (row.item.status == .in_progress and effectiveInPlan(row.item.*)) return row.item.id;
    }
    return null;
}

fn eligibleCodexInProgress(row: EnrichedItem) bool {
    return row.item.status == .in_progress and
        effectiveInPlan(row.item.*) and
        row.dep_state == .ready and
        !row.claim_stale and
        row.item.status != .blocked;
}

fn countCodexEligibleInProgress(rows: []const EnrichedItem) usize {
    var count: usize = 0;
    for (rows) |row| {
        if (eligibleCodexInProgress(row)) count += 1;
    }
    return count;
}

fn codexProjectionStatusForRow(row: EnrichedItem, primary_id: ?[]const u8) []const u8 {
    if (row.item.status == .completed) return "completed";
    if (row.item.status == .in_progress and primary_id != null and std.mem.eql(u8, primary_id.?, row.item.id) and row.dep_state == .ready and !row.claim_stale) {
        return "in_progress";
    }
    return "pending";
}

fn writeCodexProjectionEntries(writer: anytype, entries: []const CodexPlanProjectionEntry) !void {
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"step\":");
        try std.json.Stringify.value(entry.step, .{}, writer);
        try writer.writeAll(",\"status\":");
        try std.json.Stringify.value(entry.status, .{}, writer);
        try writer.writeByte('}');
    }
}

fn writeCodexUpdatePlanPayload(writer: anytype, entries: []const CodexPlanProjectionEntry) !void {
    try writer.writeAll("{\"plan\":[");
    try writeCodexProjectionEntries(writer, entries);
    try writer.writeAll("]}");
}

fn writeOpencodeProjectionEntries(writer: anytype, entries: []const OpencodeTodoProjectionEntry) !void {
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"content\":");
        try std.json.Stringify.value(entry.content, .{}, writer);
        try writer.writeAll(",\"status\":");
        try std.json.Stringify.value(entry.status, .{}, writer);
        try writer.writeAll(",\"priority\":");
        try std.json.Stringify.value(entry.priority, .{}, writer);
        try writer.writeByte('}');
    }
}

fn assertCodexProjectionResult(
    allocator: std.mem.Allocator,
    state: *const ItemState,
    result: ProjectionResult,
    ok: *bool,
    failures: *std.ArrayList([]const u8),
) !void {
    var in_progress_count: usize = 0;
    var seen = std.StringHashMap(void).init(allocator);
    for (result.codex_plan) |entry| {
        if (state.getConst(entry.id) == null) {
            ok.* = false;
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "unknown projected id {s}", .{entry.id}));
        }
        if (!std.mem.startsWith(u8, entry.step, "[")) {
            ok.* = false;
            try failures.append(allocator, "Codex step is missing [st-id] prefix");
        }
        const expected_prefix = try std.fmt.allocPrint(allocator, "[{s}] ", .{entry.id});
        if (!std.mem.startsWith(u8, entry.step, expected_prefix)) {
            ok.* = false;
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "Codex step for {s} does not begin with its durable id", .{entry.id}));
        }
        if (!(std.mem.eql(u8, entry.status, "pending") or std.mem.eql(u8, entry.status, "in_progress") or std.mem.eql(u8, entry.status, "completed"))) {
            ok.* = false;
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "unsupported Codex status for {s}", .{entry.id}));
        }
        if (std.mem.eql(u8, entry.status, "in_progress")) {
            in_progress_count += 1;
            const item = state.getConst(entry.id) orelse continue;
            const waiting = try unresolvedDependencyIds(allocator, item.*, state);
            if (waiting.len > 0 or item.status == .blocked or item.status == .deferred or item.status == .canceled) {
                ok.* = false;
                try failures.append(allocator, try std.fmt.allocPrint(allocator, "{s} is not eligible for Codex in_progress", .{entry.id}));
            }
            if (item.claim) |claim| {
                if (claim.state == .stale) {
                    ok.* = false;
                    try failures.append(allocator, try std.fmt.allocPrint(allocator, "{s} has a stale claim but is projected in_progress", .{entry.id}));
                }
            }
        }
        if (seen.get(entry.id) != null) {
            ok.* = false;
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "duplicate projected id {s}", .{entry.id}));
        }
        try seen.put(entry.id, {});
    }
    if (in_progress_count > 1) {
        ok.* = false;
        try failures.append(allocator, "Codex projection has more than one in_progress row");
    }
    for (state.items.items) |item| {
        if (isTerminalStatus(item.status) and item.in_plan) {
            ok.* = false;
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "terminal item {s} remains selected", .{item.id}));
        }
        if (!effectiveInPlan(item)) continue;
        for (item.deps) |dep| {
            const dep_item = state.getConst(dep.id) orelse continue;
            if (dep_item.status != .completed and !effectiveInPlan(dep_item.*)) {
                ok.* = false;
                try failures.append(allocator, try std.fmt.allocPrint(allocator, "selected item {s} depends on unresolved backlog-only {s}", .{ item.id, dep.id }));
            }
        }
    }
}

fn writerAssertProjectionJson(writer: anytype, ok: bool, result: ProjectionResult, failures: []const []const u8) !void {
    try writer.writeAll("{\"ok\":");
    try writer.writeAll(if (ok) "true" else "false");
    try writer.writeAll(",\"empty_reason\":");
    if (result.empty_reason) |reason| {
        try std.json.Stringify.value(reason, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"failures\":");
    try writeStringListArray(writer, failures);
    try writer.writeAll(",\"codex\":{\"plan\":[");
    try writeCodexProjectionEntries(writer, result.codex_plan);
    try writer.writeAll("]}}\n");
}

fn enrichItems(allocator: std.mem.Allocator, state: *const ItemState) ![]EnrichedItem {
    var enriched = std.ArrayList(EnrichedItem).empty;
    const now = try nowUtcAlloc(allocator);

    for (state.items.items) |*item| {
        const waiting = try unresolvedDependencyIds(allocator, item.*, state);
        const dep_state = dependencyState(item.*, waiting);
        const stale = isClaimStaleNow(item.*, now);
        const lock_roots = if (item.claim != null or item.scope.len > 0)
            try lockRootsForItem(allocator, item.*)
        else
            &.{};
        try enriched.append(allocator, .{
            .item = item,
            .dep_state = dep_state,
            .waiting_on = waiting,
            .claim_state = claimStateForItem(item.*, stale),
            .claim_stale = stale,
            .lock_roots = lock_roots,
            .executor_state = executorStateForItem(item.*, stale),
        });
    }

    return enriched.toOwnedSlice(allocator);
}

fn isClaimStaleNow(item: Item, now: []const u8) bool {
    const claim = item.claim orelse return false;
    if (claim.state == .stale) return true;
    if (claim.state != .held) return false;
    return claimExpiredAt(claim, now);
}

fn claimStateForItem(item: Item, stale: bool) ClaimState {
    const claim = item.claim orelse return .none;
    if (claim.state == .held and stale) return .stale;
    return claim.state;
}

fn executorStateForItem(item: Item, stale: bool) []const u8 {
    if (stale) return "stale";
    if (item.runtime != null and item.status == .in_progress) return "running";
    if (item.claim) |claim| {
        return switch (claim.state) {
            .held => "claimed",
            .released => "released",
            .stale => "stale",
            .none => "idle",
        };
    }
    return "idle";
}

fn dependencyState(item: Item, waiting: []const []const u8) DepState {
    if (item.status == .blocked) return .blocked_manual;
    if (item.status == .completed or item.status == .deferred or item.status == .canceled) return .na;
    if (waiting.len > 0) return .waiting_on_deps;
    return .ready;
}

fn isTerminalStatus(status: Status) bool {
    return switch (status) {
        .completed, .deferred, .canceled => true,
        else => false,
    };
}

fn effectiveInPlan(item: Item) bool {
    if (isTerminalStatus(item.status)) return false;
    return item.in_plan;
}

fn normalizeItemPlanMembership(item: *Item) void {
    if (isTerminalStatus(item.status)) {
        item.in_plan = false;
        return;
    }
    if (item.status == .in_progress) {
        item.in_plan = true;
    }
}

const CodexPlanEntry = struct {
    id: []const u8,
    step: []const u8,
    status: Status,
};

fn parseUpdatePlanEntriesFromInputFile(allocator: std.mem.Allocator, input_path: []const u8) ![]CodexPlanEntry {
    const bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);
    return parseUpdatePlanEntriesFromBytes(allocator, bytes);
}

fn parseUpdatePlanEntriesFromTranscript(allocator: std.mem.Allocator, transcript_path: []const u8) ![]CodexPlanEntry {
    const bytes = try readFileAlloc(allocator, transcript_path, 64 * 1024 * 1024);
    return parseUpdatePlanEntriesFromTranscriptBytes(allocator, bytes);
}

fn parseUpdatePlanEntriesFromBytes(allocator: std.mem.Allocator, input_bytes: []const u8) ![]CodexPlanEntry {
    const trimmed = std.mem.trim(u8, input_bytes, " \t\r\n");
    const payload = if (std.mem.startsWith(u8, trimmed, "update_plan:"))
        std.mem.trim(u8, trimmed["update_plan:".len..], " \t\r\n")
    else
        trimmed;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    return parseUpdatePlanEntries(allocator, parsed.value);
}

fn parseUpdatePlanEntriesFromTranscriptBytes(allocator: std.mem.Allocator, transcript_bytes: []const u8) ![]CodexPlanEntry {
    const arguments = (try latestUpdatePlanArgumentsFromTranscriptBytes(allocator, transcript_bytes)) orelse
        return error.MissingUpdatePlanInTranscript;
    const parsed_arguments = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    return parseUpdatePlanEntries(allocator, parsed_arguments.value);
}

fn latestUpdatePlanArgumentsFromTranscript(allocator: std.mem.Allocator, transcript_path: []const u8) !?[]const u8 {
    const bytes = try readFileAlloc(allocator, transcript_path, 64 * 1024 * 1024);
    return latestUpdatePlanArgumentsFromTranscriptBytes(allocator, bytes);
}

fn latestUpdatePlanArgumentsFromTranscriptBytes(allocator: std.mem.Allocator, transcript_bytes: []const u8) !?[]const u8 {
    var last_turn_context_index: usize = 0;
    var seen_turn_context = false;
    var line_index: usize = 0;

    var first_pass = std.mem.splitScalar(u8, transcript_bytes, '\n');
    while (first_pass.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        if (stringField(parsed.value, "type")) |line_type| {
            if (std.mem.eql(u8, line_type, "turn_context")) {
                last_turn_context_index = line_index;
                seen_turn_context = true;
            }
        }
        line_index += 1;
    }

    if (!seen_turn_context) return error.MissingTurnContext;

    var latest_arguments: ?[]const u8 = null;
    line_index = 0;
    var second_pass = std.mem.splitScalar(u8, transcript_bytes, '\n');
    while (second_pass.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;

        if (line_index < last_turn_context_index) {
            line_index += 1;
            continue;
        }

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        if (stringField(parsed.value, "type")) |line_type| {
            if (std.mem.eql(u8, line_type, "response_item")) {
                if (objectField(parsed.value, "payload")) |payload| {
                    const payload_type = stringField(payload, "type");
                    const tool_name = stringField(payload, "name");
                    if (payload_type != null and tool_name != null and
                        std.mem.eql(u8, payload_type.?, "function_call") and
                        std.mem.eql(u8, tool_name.?, "update_plan"))
                    {
                        if (stringField(payload, "arguments")) |arguments| {
                            latest_arguments = try allocator.dupe(u8, arguments);
                        }
                    }
                }
            } else if (std.mem.eql(u8, line_type, "turn/plan/updated")) {
                const payload = objectField(parsed.value, "payload") orelse parsed.value;
                var out: std.Io.Writer.Allocating = .init(allocator);
                defer out.deinit();
                if (objectField(payload, "plan") != null) {
                    try std.json.Stringify.value(payload, .{}, &out.writer);
                } else {
                    try out.writer.writeAll("{\"plan\":");
                    try std.json.Stringify.value(payload, .{}, &out.writer);
                    try out.writer.writeByte('}');
                }
                latest_arguments = try out.toOwnedSlice();
            }
        }
        line_index += 1;
    }

    return latest_arguments;
}

fn parseUpdatePlanEntries(allocator: std.mem.Allocator, value: std.json.Value) ![]CodexPlanEntry {
    const plan_value = switch (value) {
        .array => value,
        .object => |obj| obj.get("plan") orelse return error.MissingPlanArray,
        else => return error.InvalidUpdatePlan,
    };
    const plan_items = switch (plan_value) {
        .array => |arr| arr.items,
        else => return error.InvalidUpdatePlan,
    };

    var out = std.ArrayList(CodexPlanEntry).empty;
    var seen = std.StringHashMap(void).init(allocator);
    var in_progress_count: usize = 0;

    for (plan_items) |raw_entry| {
        const obj = switch (raw_entry) {
            .object => |entry| entry,
            else => return error.InvalidUpdatePlanEntry,
        };
        const step_raw = asString(obj.get("step") orelse return error.MissingStepValue) orelse return error.MissingStepValue;
        const status_raw = asString(obj.get("status") orelse return error.MissingStatusValue) orelse return error.MissingStatusValue;
        const parsed_step = try parseCodexPlanStep(allocator, step_raw);
        if (seen.get(parsed_step.id) != null) return error.DuplicateItemId;
        try seen.put(parsed_step.id, {});
        const status = try normalizeCodexPlanStatus(status_raw);
        if (status == .in_progress) {
            in_progress_count += 1;
            if (in_progress_count > 1) return error.MultipleCodexInProgress;
        }
        try out.append(allocator, .{
            .id = parsed_step.id,
            .step = parsed_step.step,
            .status = status,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn parseCodexPlanStep(allocator: std.mem.Allocator, raw: []const u8) !struct { id: []const u8, step: []const u8 } {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len < 3 or trimmed[0] != '[') return error.InvalidCodexPlanStep;
    const closing = std.mem.indexOfScalar(u8, trimmed, ']') orelse return error.InvalidCodexPlanStep;
    if (closing <= 1) return error.InvalidCodexPlanStep;

    const id = try requireNonEmptyString(allocator, trimmed[1..closing], "codex plan id");
    const step = try requireNonEmptyString(allocator, std.mem.trim(u8, trimmed[closing + 1 ..], " \t\r\n"), "codex plan step");
    return .{ .id = id, .step = step };
}

fn normalizeCodexPlanStatus(raw: []const u8) !Status {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "pending")) return .pending;
    if (std.ascii.eqlIgnoreCase(trimmed, "in_progress")) return .in_progress;
    if (std.ascii.eqlIgnoreCase(trimmed, "inProgress")) return .in_progress;
    if (std.ascii.eqlIgnoreCase(trimmed, "completed")) return .completed;
    return error.InvalidCodexPlanStatus;
}

fn applyCodexUpdatePlanImport(
    allocator: std.mem.Allocator,
    state: *ItemState,
    imported_entries: []const CodexPlanEntry,
    allow_multiple_in_progress: bool,
) !bool {
    var changed = false;
    var imported_ids = std.StringHashMap(void).init(allocator);
    defer imported_ids.deinit();

    for (imported_entries) |entry| {
        const item = state.get(entry.id) orelse return error.UnknownItemId;
        _ = item;
        try imported_ids.put(entry.id, {});
    }

    var reordered = std.ArrayList(Item).empty;
    defer reordered.deinit(allocator);

    for (imported_entries) |entry| {
        const current = state.get(entry.id).?;
        var item = current.*;
        const original = current.*;

        if (original.status == .canceled or original.status == .deferred) {
            return error.InvalidMirroredStatusTransition;
        }
        if (original.status == .completed and entry.status != .completed) {
            return error.InvalidMirroredStatusTransition;
        }
        if (original.claim) |claim| {
            if (claim.state == .held and entry.status == .completed) {
                return error.InvalidMirroredStatusTransition;
            }
        }

        item.step = entry.step;
        item.status = entry.status;
        item.in_plan = true;
        normalizeItemPlanMembership(&item);

        if (!itemsEqual(item, original)) changed = true;
        try reordered.append(allocator, item);
    }

    for (state.items.items) |existing| {
        if (imported_ids.get(existing.id) != null) continue;
        var item = existing;
        const original = existing;

        if (item.status == .in_progress) {
            if ((item.claim != null and item.claim.?.state == .held) or item.runtime != null) {
                return error.InvalidMirroredStatusTransition;
            }
            item.status = .pending;
        }
        item.in_plan = false;
        normalizeItemPlanMembership(&item);

        if (!itemsEqual(item, original)) changed = true;
        try reordered.append(allocator, item);
    }

    if (!itemOrderMatches(state, reordered.items)) changed = true;

    state.clear();
    for (reordered.items) |item| {
        try state.upsert(item);
    }
    try validateState(state, allow_multiple_in_progress);
    return changed;
}

fn itemOrderMatches(state: *const ItemState, reordered: []const Item) bool {
    if (state.items.items.len != reordered.len) return false;
    for (state.items.items, reordered) |lhs, rhs| {
        if (!std.mem.eql(u8, lhs.id, rhs.id)) return false;
    }
    return true;
}

fn itemsEqual(lhs: Item, rhs: Item) bool {
    return std.mem.eql(u8, lhs.id, rhs.id) and
        std.mem.eql(u8, lhs.step, rhs.step) and
        lhs.status == rhs.status and
        lhs.priority == rhs.priority and
        lhs.in_plan == rhs.in_plan and
        depsEqual(lhs.deps, rhs.deps) and
        std.mem.eql(u8, lhs.notes, rhs.notes) and
        commentsEqual(lhs.comments, rhs.comments) and
        stringListsEqual(lhs.related_to, rhs.related_to) and
        stringListsEqual(lhs.scope, rhs.scope) and
        stringListsEqual(lhs.location, rhs.location) and
        stringListsEqual(lhs.validation, rhs.validation) and
        std.mem.eql(u8, lhs.agent, rhs.agent) and
        std.mem.eql(u8, lhs.role, rhs.role) and
        sourceMetaEqual(lhs.source, rhs.source) and
        claimMetaEqual(lhs.claim, rhs.claim) and
        runtimeMetaEqual(lhs.runtime, rhs.runtime) and
        proofMetaEqual(lhs.proof, rhs.proof) and
        lhs.item_type == rhs.item_type and
        optionalStringEqual(lhs.parent_id, rhs.parent_id) and
        graphLinksEqual(lhs.links, rhs.links) and
        stringListsEqual(lhs.intent_refs, rhs.intent_refs) and
        stringListsEqual(lhs.acceptance, rhs.acceptance) and
        contractEqual(lhs.contract, rhs.contract) and
        stringListsEqual(lhs.labels, rhs.labels) and
        stringListsEqual(lhs.lock_roots, rhs.lock_roots) and
        stringListsEqual(lhs.uncertainty, rhs.uncertainty) and
        stringListsEqual(lhs.non_goals, rhs.non_goals);
}

fn depsEqual(lhs: []const Dep, rhs: []const Dep) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left.id, right.id) or !std.mem.eql(u8, left.type, right.type)) return false;
    }
    return true;
}

fn commentsEqual(lhs: []const Comment, rhs: []const Comment) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left.ts, right.ts) or !std.mem.eql(u8, left.author, right.author) or !std.mem.eql(u8, left.text, right.text)) return false;
    }
    return true;
}

fn stringListsEqual(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn optionalStringEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn graphLinksEqual(lhs: []const GraphLink, rhs: []const GraphLink) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left.id, right.id) or
            !std.mem.eql(u8, left.type, right.type) or
            !std.mem.eql(u8, left.reason, right.reason)) return false;
    }
    return true;
}

fn proofObligationsEqual(lhs: []const ProofObligation, rhs: []const ProofObligation) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left.id, right.id) or
            !std.mem.eql(u8, left.kind, right.kind) or
            !std.mem.eql(u8, left.command, right.command) or
            !std.mem.eql(u8, left.evidence_ref, right.evidence_ref) or
            left.required != right.required) return false;
    }
    return true;
}

fn contractEqual(lhs: ?Contract, rhs: ?Contract) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?.objective, rhs.?.objective) and
        std.mem.eql(u8, lhs.?.background, rhs.?.background) and
        std.mem.eql(u8, lhs.?.implementation_approach, rhs.?.implementation_approach) and
        stringListsEqual(lhs.?.success_criteria, rhs.?.success_criteria) and
        proofObligationsEqual(lhs.?.proof_obligations, rhs.?.proof_obligations) and
        stringListsEqual(lhs.?.risks, rhs.?.risks);
}

fn sourceMetaEqual(lhs: ?SourceMeta, rhs: ?SourceMeta) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?.kind, rhs.?.kind) and
        std.mem.eql(u8, lhs.?.locator, rhs.?.locator) and
        std.mem.eql(u8, lhs.?.source_task_id, rhs.?.source_task_id) and
        std.mem.eql(u8, lhs.?.wave_id, rhs.?.wave_id);
}

fn claimMetaEqual(lhs: ?ClaimMeta, rhs: ?ClaimMeta) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return lhs.?.state == rhs.?.state and
        std.mem.eql(u8, lhs.?.owner, rhs.?.owner) and
        std.mem.eql(u8, lhs.?.executor, rhs.?.executor) and
        std.mem.eql(u8, lhs.?.wave_id, rhs.?.wave_id) and
        stringListsEqual(lhs.?.lock_roots, rhs.?.lock_roots) and
        std.mem.eql(u8, lhs.?.claimed_at, rhs.?.claimed_at) and
        lhs.?.lease_seconds == rhs.?.lease_seconds and
        std.mem.eql(u8, lhs.?.lease_expires_at, rhs.?.lease_expires_at) and
        std.mem.eql(u8, lhs.?.heartbeat_at, rhs.?.heartbeat_at) and
        lhs.?.attempts == rhs.?.attempts;
}

fn runtimeMetaEqual(lhs: ?RuntimeMeta, rhs: ?RuntimeMeta) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?.substrate, rhs.?.substrate) and
        std.mem.eql(u8, lhs.?.thread_id, rhs.?.thread_id) and
        std.mem.eql(u8, lhs.?.agent_id, rhs.?.agent_id) and
        std.mem.eql(u8, lhs.?.row_id, rhs.?.row_id) and
        std.mem.eql(u8, lhs.?.output_ref, rhs.?.output_ref) and
        std.mem.eql(u8, lhs.?.last_event, rhs.?.last_event);
}

fn proofMetaEqual(lhs: ?ProofMeta, rhs: ?ProofMeta) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return lhs.?.state == rhs.?.state and
        std.mem.eql(u8, lhs.?.command, rhs.?.command) and
        std.mem.eql(u8, lhs.?.evidence_ref, rhs.?.evidence_ref) and
        std.mem.eql(u8, lhs.?.last_run_at, rhs.?.last_run_at);
}

fn normalizeStatePlanMembership(state: *ItemState) void {
    for (state.items.items) |*item| {
        normalizeItemPlanMembership(item);
    }
}

fn rowMatchesSurface(surface: Surface, row: EnrichedItem) bool {
    return switch (surface) {
        .all => true,
        .plan => effectiveInPlan(row.item.*),
        .backlog => !effectiveInPlan(row.item.*),
    };
}

fn filterRowsBySurface(
    allocator: std.mem.Allocator,
    rows: []const EnrichedItem,
    surface: Surface,
) ![]EnrichedItem {
    var filtered = std.ArrayList(EnrichedItem).empty;
    for (rows) |row| {
        if (rowMatchesSurface(surface, row)) {
            try filtered.append(allocator, row);
        }
    }
    return filtered.toOwnedSlice(allocator);
}

fn unresolvedDependencyIds(allocator: std.mem.Allocator, item: Item, state: *const ItemState) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(allocator);

    for (item.deps) |dep| {
        if (seen.get(dep.id) != null) continue;

        const dep_item = state.getConst(dep.id);
        if (dep_item == null or dep_item.?.status != .completed) {
            try out.append(allocator, dep.id);
            try seen.put(dep.id, {});
        }
    }

    return out.toOwnedSlice(allocator);
}

fn validateState(state: *ItemState, allow_multiple_in_progress: bool) !void {
    try state.rebuildIndex();
    normalizeStatePlanMembership(state);

    for (state.items.items) |item| {
        for (item.deps) |dep| {
            if (std.mem.eql(u8, dep.id, item.id)) return error.SelfDependency;
            if (state.getConst(dep.id) == null) return error.UnknownDependency;
        }
    }

    try ensureNoCycles(state);

    var in_progress_count: usize = 0;
    for (state.items.items) |item| {
        if (item.status == .in_progress) in_progress_count += 1;
    }
    if (!allow_multiple_in_progress and in_progress_count > 1) {
        try validateClaimSafeInProgress(state);
    }

    for (state.items.items) |item| {
        if (item.status != .in_progress and item.status != .completed) continue;
        const waiting = try unresolvedDependencyIds(state.allocator, item, state);
        if (waiting.len > 0) return error.UnresolvedDependencies;
    }

    try validatePlanProjection(state);
}

fn validateClaimSafeInProgress(state: *ItemState) !void {
    var claimed_roots: std.ArrayList([]const []const u8) = .empty;
    for (state.items.items) |item| {
        if (item.status != .in_progress) continue;
        const claim = item.claim orelse return error.MultipleInProgress;
        if (claim.state != .held) return error.MultipleInProgress;
        if (claim.wave_id.len == 0) return error.MultipleInProgress;
        if (!std.mem.eql(u8, claim.executor, "teams") and !std.mem.eql(u8, claim.executor, "mesh")) {
            return error.MultipleInProgress;
        }
        const roots = if (claim.lock_roots.len > 0) claim.lock_roots else return error.MultipleInProgress;
        for (claimed_roots.items) |prior| {
            if (rootsOverlapAny(roots, prior)) return error.MultipleInProgress;
        }
        try claimed_roots.append(state.allocator, roots);
    }
}

fn validatePlanProjection(state: *ItemState) !void {
    for (state.items.items) |item| {
        if (!effectiveInPlan(item)) continue;
        for (item.deps) |dep| {
            const dep_item = state.getConst(dep.id) orelse return error.UnknownDependency;
            if (dep_item.status == .completed) continue;
            if (!effectiveInPlan(dep_item.*)) return error.PlanDependencyNotSelected;
        }
    }
}

fn ensureNoCycles(state: *ItemState) !void {
    var visiting = std.StringHashMap(void).init(state.allocator);
    var visited = std.StringHashMap(void).init(state.allocator);

    var stack = std.ArrayList([]const u8).empty;

    for (state.items.items) |item| {
        try dfsCycle(state, item.id, &visiting, &visited, &stack);
    }
}

fn dfsCycle(
    state: *ItemState,
    node_id: []const u8,
    visiting: *std.StringHashMap(void),
    visited: *std.StringHashMap(void),
    stack: *std.ArrayList([]const u8),
) !void {
    if (visited.get(node_id) != null) return;
    if (visiting.get(node_id) != null) return error.DependencyCycle;

    try visiting.put(node_id, {});
    try stack.append(state.allocator, node_id);

    const node = state.getConst(node_id) orelse return error.UnknownDependency;
    for (node.deps) |dep| {
        try dfsCycle(state, dep.id, visiting, visited, stack);
    }

    _ = stack.pop();
    _ = visiting.remove(node_id);
    try visited.put(node_id, {});
}

fn nextIdAlloc(allocator: std.mem.Allocator, state: *const ItemState) ![]const u8 {
    var max_seen: u32 = 0;
    for (state.items.items) |item| {
        const n = parseIdSuffix(item.id) orelse continue;
        if (n > max_seen) max_seen = n;
    }
    return std.fmt.allocPrint(allocator, "st-{d:0>3}", .{max_seen + 1});
}

fn parseIdSuffix(id: []const u8) ?u32 {
    if (id.len < 4) return null;
    const a = std.ascii.toLower(id[0]);
    const b = std.ascii.toLower(id[1]);
    const c = id[2];
    if (!((a == 's' and b == 't' and c == '-') or (a == 'k' and b == 't' and c == '-'))) return null;
    return std.fmt.parseInt(u32, id[3..], 10) catch null;
}

const SnapshotPlan = struct {
    items: []Item,
    graph: GraphEnvelope = .{},
    graph_active: bool = false,
};

fn parseSnapshotPlan(allocator: std.mem.Allocator, value: std.json.Value) !SnapshotPlan {
    const items = try parseSnapshotItems(allocator, value);
    if (value == .object) {
        if (value.object.get("graph")) |graph_value| {
            return .{
                .items = items,
                .graph = try canonicalGraphEnvelope(allocator, graph_value),
                .graph_active = true,
            };
        }
    }
    return .{ .items = items };
}

fn parseSnapshotItems(allocator: std.mem.Allocator, value: std.json.Value) ![]Item {
    var arr_values: []const std.json.Value = undefined;
    switch (value) {
        .array => |arr| arr_values = arr.items,
        .object => |obj| {
            const v = obj.get("items") orelse return error.InvalidSnapshot;
            arr_values = switch (v) {
                .array => |arr| arr.items,
                else => return error.InvalidSnapshot,
            };
        },
        else => return error.InvalidSnapshot,
    }

    var out = std.ArrayList(Item).empty;
    var seen = std.StringHashMap(void).init(allocator);

    for (arr_values) |raw_item| {
        const item = try canonicalItem(allocator, raw_item);
        if (seen.get(item.id) != null) return error.DuplicateItemId;
        try seen.put(item.id, {});
        try out.append(allocator, item);
    }

    return out.toOwnedSlice(allocator);
}

fn canonicalItem(allocator: std.mem.Allocator, value: std.json.Value) !Item {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };

    const id_raw = obj.get("id") orelse return error.MissingItemId;
    const id = try requireNonEmptyString(allocator, asString(id_raw) orelse return error.MissingItemId, "item.id");

    const step_raw = obj.get("step") orelse return error.MissingStepValue;
    const step = try requireNonEmptyString(allocator, asString(step_raw) orelse return error.MissingStepValue, "item.step");

    const status_raw = if (obj.get("status")) |v| asString(v) orelse return error.InvalidStatus else "pending";
    const status = try normalizeStatus(status_raw);

    const priority_raw = if (obj.get("priority")) |v| asString(v) orelse return error.InvalidPriority else "medium";
    const priority = try normalizePriority(priority_raw);
    const in_plan = if (obj.get("in_plan")) |v| switch (v) {
        .bool => |b| b,
        .null => true,
        else => return error.InvalidInPlan,
    } else true;

    const deps = if (obj.get("deps")) |v| try normalizeDeps(allocator, v) else &.{};

    const notes = if (obj.get("notes")) |v| switch (v) {
        .string => |s| s,
        .null => "",
        else => return error.InvalidNotes,
    } else "";

    const comments = if (obj.get("comments")) |v| try normalizeComments(allocator, v) else &.{};
    const related_to = if (obj.get("related_to")) |v| try normalizeStringList(allocator, v) else &.{};
    const scope = if (obj.get("scope")) |v| try normalizeStringList(allocator, v) else &.{};
    const location = if (obj.get("location")) |v| try normalizeStringList(allocator, v) else &.{};
    const validation = if (obj.get("validation")) |v| try normalizeStringList(allocator, v) else &.{};
    const agent = if (obj.get("agent")) |v| switch (v) {
        .string => |s| s,
        .null => "",
        else => return error.InvalidItem,
    } else "";
    const role = if (obj.get("role")) |v| switch (v) {
        .string => |s| s,
        .null => "",
        else => return error.InvalidItem,
    } else "";
    const source = if (obj.get("source")) |v| try canonicalSourceMeta(allocator, v) else null;
    const claim = if (obj.get("claim")) |v| try canonicalClaimMeta(allocator, v) else null;
    const runtime = if (obj.get("runtime")) |v| try canonicalRuntimeMeta(allocator, v) else null;
    const proof = if (obj.get("proof")) |v| try canonicalProofMeta(allocator, v) else null;
    const item_type = if (obj.get("item_type")) |v| try normalizeItemType(asString(v) orelse return error.InvalidItemType) else ItemType.task;
    const parent_id = if (obj.get("parent_id")) |v| try optionalString(allocator, v, "parent_id") else null;
    const links = if (obj.get("links")) |v| try normalizeGraphLinks(allocator, v) else &.{};
    const intent_refs = if (obj.get("intent_refs")) |v| try normalizeStringList(allocator, v) else &.{};
    const acceptance = if (obj.get("acceptance")) |v| try normalizeStringList(allocator, v) else &.{};
    const contract = if (obj.get("contract")) |v| try canonicalContract(allocator, v) else null;
    const labels = if (obj.get("labels")) |v| try normalizeStringList(allocator, v) else &.{};
    const lock_roots = if (obj.get("lock_roots")) |v| try normalizeStringList(allocator, v) else &.{};
    const uncertainty = if (obj.get("uncertainty")) |v| try normalizeStringList(allocator, v) else &.{};
    const non_goals = if (obj.get("non_goals")) |v| try normalizeStringList(allocator, v) else &.{};

    var item = Item{
        .id = id,
        .step = step,
        .status = status,
        .priority = priority,
        .in_plan = in_plan,
        .deps = deps,
        .notes = notes,
        .comments = comments,
        .related_to = related_to,
        .scope = scope,
        .location = location,
        .validation = validation,
        .agent = agent,
        .role = role,
        .source = source,
        .claim = claim,
        .runtime = runtime,
        .proof = proof,
        .item_type = item_type,
        .parent_id = parent_id,
        .links = links,
        .intent_refs = intent_refs,
        .acceptance = acceptance,
        .contract = contract,
        .labels = labels,
        .lock_roots = lock_roots,
        .uncertainty = uncertainty,
        .non_goals = non_goals,
    };
    normalizeItemPlanMembership(&item);
    return item;
}

fn normalizeComments(allocator: std.mem.Allocator, value: std.json.Value) ![]Comment {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(Comment).empty;
            for (arr.items) |entry| {
                try out.append(allocator, try canonicalComment(allocator, entry));
            }
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidComment,
    };
}

fn canonicalComment(allocator: std.mem.Allocator, value: std.json.Value) !Comment {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidComment,
    };

    const ts = try requireNonEmptyString(allocator, asString(obj.get("ts") orelse return error.InvalidComment) orelse return error.InvalidComment, "comment.ts");
    const author = try requireNonEmptyString(allocator, asString(obj.get("author") orelse return error.InvalidComment) orelse return error.InvalidComment, "comment.author");
    const text = try requireNonEmptyString(allocator, asString(obj.get("text") orelse return error.InvalidComment) orelse return error.InvalidComment, "comment.text");

    return .{ .ts = ts, .author = author, .text = text };
}

fn normalizeStringList(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    return switch (value) {
        .null => &.{},
        .string => |s| blk: {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len == 0) break :blk &.{};
            var out = std.ArrayList([]const u8).empty;
            try out.append(allocator, trimmed);
            break :blk try out.toOwnedSlice(allocator);
        },
        .array => |arr| blk: {
            var out = std.ArrayList([]const u8).empty;
            for (arr.items) |entry| {
                if (entry != .string) continue;
                const trimmed = std.mem.trim(u8, entry.string, " \t\r\n");
                if (trimmed.len > 0) try out.append(allocator, trimmed);
            }
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidItem,
    };
}

fn optionalString(allocator: std.mem.Allocator, value: std.json.Value, field_name: []const u8) !?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |s| blk: {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len == 0) break :blk null;
            break :blk try requireNonEmptyString(allocator, trimmed, field_name);
        },
        else => error.InvalidItem,
    };
}

fn normalizeItemType(raw: []const u8) !ItemType {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "epic")) return .epic;
    if (std.ascii.eqlIgnoreCase(trimmed, "feature")) return .feature;
    if (std.ascii.eqlIgnoreCase(trimmed, "task")) return .task;
    if (std.ascii.eqlIgnoreCase(trimmed, "bug")) return .bug;
    if (std.ascii.eqlIgnoreCase(trimmed, "test")) return .@"test";
    if (std.ascii.eqlIgnoreCase(trimmed, "verification")) return .verification;
    if (std.ascii.eqlIgnoreCase(trimmed, "docs")) return .docs;
    if (std.ascii.eqlIgnoreCase(trimmed, "chore")) return .chore;
    if (std.ascii.eqlIgnoreCase(trimmed, "research")) return .research;
    if (std.ascii.eqlIgnoreCase(trimmed, "spike")) return .spike;
    if (std.ascii.eqlIgnoreCase(trimmed, "decision")) return .decision;
    return error.InvalidItemType;
}

fn normalizeGraphLinks(allocator: std.mem.Allocator, value: std.json.Value) ![]const GraphLink {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(GraphLink).empty;
            for (arr.items) |entry| {
                try out.append(allocator, try canonicalGraphLink(allocator, entry));
            }
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidGraphLink,
    };
}

fn canonicalGraphLink(allocator: std.mem.Allocator, value: std.json.Value) !GraphLink {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidGraphLink,
    };
    return .{
        .id = try requireNonEmptyString(allocator, asString(obj.get("id") orelse return error.InvalidGraphLink) orelse return error.InvalidGraphLink, "link.id"),
        .type = try requireNonEmptyString(allocator, asString(obj.get("type") orelse return error.InvalidGraphLink) orelse return error.InvalidGraphLink, "link.type"),
        .reason = if (obj.get("reason")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidGraphLink,
        } else "",
    };
}

fn canonicalContract(allocator: std.mem.Allocator, value: std.json.Value) !?Contract {
    if (value == .null) return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidContract,
    };
    return Contract{
        .objective = try optionalObjectString(allocator, obj, "objective"),
        .background = try optionalObjectString(allocator, obj, "background"),
        .implementation_approach = try optionalObjectString(allocator, obj, "implementation_approach"),
        .success_criteria = if (obj.get("success_criteria")) |v| try normalizeStringList(allocator, v) else &.{},
        .proof_obligations = if (obj.get("proof_obligations")) |v| try normalizeProofObligations(allocator, v) else &.{},
        .risks = if (obj.get("risks")) |v| try normalizeStringList(allocator, v) else &.{},
    };
}

fn normalizeProofObligations(allocator: std.mem.Allocator, value: std.json.Value) ![]const ProofObligation {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(ProofObligation).empty;
            for (arr.items) |entry| {
                try out.append(allocator, try canonicalProofObligation(allocator, entry));
            }
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidProofObligation,
    };
}

fn canonicalProofObligation(allocator: std.mem.Allocator, value: std.json.Value) !ProofObligation {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidProofObligation,
    };
    return .{
        .id = try requireNonEmptyString(allocator, asString(obj.get("id") orelse return error.InvalidProofObligation) orelse return error.InvalidProofObligation, "proof_obligation.id"),
        .kind = try requireNonEmptyString(allocator, asString(obj.get("kind") orelse return error.InvalidProofObligation) orelse return error.InvalidProofObligation, "proof_obligation.kind"),
        .command = try optionalObjectString(allocator, obj, "command"),
        .evidence_ref = try optionalObjectString(allocator, obj, "evidence_ref"),
        .required = if (obj.get("required")) |v| switch (v) {
            .bool => |b| b,
            .null => true,
            else => return error.InvalidProofObligation,
        } else true,
    };
}

fn optionalObjectString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    _ = allocator;
    return if (obj.get(key)) |v| switch (v) {
        .string => |s| s,
        .null => "",
        else => error.InvalidItem,
    } else "";
}

fn canonicalSourceMeta(allocator: std.mem.Allocator, value: std.json.Value) !?SourceMeta {
    if (value == .null) return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };
    return SourceMeta{
        .kind = if (obj.get("kind")) |v| try requireNonEmptyString(allocator, asString(v) orelse return error.InvalidItem, "source.kind") else "",
        .locator = if (obj.get("locator")) |v| try requireNonEmptyString(allocator, asString(v) orelse return error.InvalidItem, "source.locator") else "",
        .source_task_id = if (obj.get("source_task_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .wave_id = if (obj.get("wave_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
    };
}

fn canonicalClaimMeta(allocator: std.mem.Allocator, value: std.json.Value) !?ClaimMeta {
    if (value == .null) return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };
    const state = if (obj.get("state")) |v|
        try normalizeClaimState(asString(v) orelse return error.InvalidItem)
    else
        ClaimState.none;
    return ClaimMeta{
        .state = state,
        .owner = if (obj.get("owner")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .executor = if (obj.get("executor")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .wave_id = if (obj.get("wave_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .lock_roots = if (obj.get("lock_roots")) |v| try normalizeStringList(allocator, v) else &.{},
        .claimed_at = if (obj.get("claimed_at")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .lease_seconds = if (obj.get("lease_seconds")) |v| switch (v) {
            .integer => |n| n,
            .null => 0,
            else => return error.InvalidItem,
        } else 0,
        .lease_expires_at = if (obj.get("lease_expires_at")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .heartbeat_at = if (obj.get("heartbeat_at")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .attempts = if (obj.get("attempts")) |v| switch (v) {
            .integer => |n| n,
            .null => 0,
            else => return error.InvalidItem,
        } else 0,
    };
}

fn canonicalRuntimeMeta(allocator: std.mem.Allocator, value: std.json.Value) !?RuntimeMeta {
    _ = allocator;
    if (value == .null) return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };
    return RuntimeMeta{
        .substrate = if (obj.get("substrate")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .thread_id = if (obj.get("thread_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .agent_id = if (obj.get("agent_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .row_id = if (obj.get("row_id")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .output_ref = if (obj.get("output_ref")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .last_event = if (obj.get("last_event")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
    };
}

fn canonicalProofMeta(allocator: std.mem.Allocator, value: std.json.Value) !?ProofMeta {
    _ = allocator;
    if (value == .null) return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };
    const state = if (obj.get("state")) |v|
        try normalizeProofState(asString(v) orelse return error.InvalidItem)
    else
        ProofState.not_run;
    return ProofMeta{
        .state = state,
        .command = if (obj.get("command")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .evidence_ref = if (obj.get("evidence_ref")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
        .last_run_at = if (obj.get("last_run_at")) |v| switch (v) {
            .string => |s| s,
            .null => "",
            else => return error.InvalidItem,
        } else "",
    };
}

fn canonicalGraphEnvelope(allocator: std.mem.Allocator, value: std.json.Value) !GraphEnvelope {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidGraphEnvelope,
    };
    return .{
        .version = if (obj.get("version")) |v| switch (v) {
            .integer => |n| n,
            .null => GraphEnvelopeVersion,
            else => return error.InvalidGraphEnvelope,
        } else GraphEnvelopeVersion,
        .policy = if (obj.get("policy")) |v| try canonicalGraphPolicy(allocator, v) else .{},
        .intent = if (obj.get("intent")) |v| try normalizeIntentAtoms(allocator, v) else &.{},
        .waivers = if (obj.get("waivers")) |v| try normalizeWaivers(allocator, v) else &.{},
        .polish = if (obj.get("polish")) |v| try canonicalPolishState(allocator, v) else .{},
        .fingerprints = if (obj.get("fingerprints")) |v| try canonicalGraphFingerprints(allocator, v) else .{},
    };
}

fn canonicalGraphPolicy(allocator: std.mem.Allocator, value: std.json.Value) !GraphPolicy {
    _ = allocator;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidGraphPolicy,
    };
    return .{
        .completion_requires_proof = try optionalObjectBool(obj, "completion_requires_proof", false),
        .implementation_ready_required = try optionalObjectBool(obj, "implementation_ready_required", true),
        .default_projection_strategy = if (obj.get("default_projection_strategy")) |v| switch (v) {
            .string => |s| s,
            .null => "aperture-score",
            else => return error.InvalidGraphPolicy,
        } else "aperture-score",
        .default_gate = if (obj.get("default_gate")) |v| switch (v) {
            .string => |s| s,
            .null => "implementation-ready",
            else => return error.InvalidGraphPolicy,
        } else "implementation-ready",
        .max_aperture_items = if (obj.get("max_aperture_items")) |v| switch (v) {
            .integer => |n| n,
            .null => 7,
            else => return error.InvalidGraphPolicy,
        } else 7,
    };
}

fn normalizeIntentAtoms(allocator: std.mem.Allocator, value: std.json.Value) ![]const IntentAtom {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(IntentAtom).empty;
            for (arr.items) |entry| try out.append(allocator, try canonicalIntentAtom(allocator, entry));
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidIntentAtom,
    };
}

fn canonicalIntentAtom(allocator: std.mem.Allocator, value: std.json.Value) !IntentAtom {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidIntentAtom,
    };
    return .{
        .id = try requireNonEmptyString(allocator, asString(obj.get("id") orelse return error.InvalidIntentAtom) orelse return error.InvalidIntentAtom, "intent.id"),
        .source = if (obj.get("source")) |v| try canonicalIntentSource(allocator, v) else null,
        .text = try requireNonEmptyString(allocator, asString(obj.get("text") orelse return error.InvalidIntentAtom) orelse return error.InvalidIntentAtom, "intent.text"),
        .category = try requireNonEmptyString(allocator, asString(obj.get("category") orelse return error.InvalidIntentAtom) orelse return error.InvalidIntentAtom, "intent.category"),
        .disposition = try requireNonEmptyString(allocator, asString(obj.get("disposition") orelse return error.InvalidIntentAtom) orelse return error.InvalidIntentAtom, "intent.disposition"),
        .reason = try optionalObjectString(allocator, obj, "reason"),
    };
}

fn canonicalIntentSource(allocator: std.mem.Allocator, value: std.json.Value) !?IntentSource {
    if (value == .null) return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidIntentSource,
    };
    return IntentSource{
        .kind = try optionalObjectString(allocator, obj, "kind"),
        .locator = try optionalObjectString(allocator, obj, "locator"),
        .anchor = try optionalObjectString(allocator, obj, "anchor"),
    };
}

fn normalizeWaivers(allocator: std.mem.Allocator, value: std.json.Value) ![]const Waiver {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(Waiver).empty;
            for (arr.items) |entry| try out.append(allocator, try canonicalWaiver(allocator, entry));
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidWaiver,
    };
}

fn canonicalWaiver(allocator: std.mem.Allocator, value: std.json.Value) !Waiver {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidWaiver,
    };
    return .{
        .id = try requireNonEmptyString(allocator, asString(obj.get("id") orelse return error.InvalidWaiver) orelse return error.InvalidWaiver, "waiver.id"),
        .gate = try requireNonEmptyString(allocator, asString(obj.get("gate") orelse return error.InvalidWaiver) orelse return error.InvalidWaiver, "waiver.gate"),
        .code = try requireNonEmptyString(allocator, asString(obj.get("code") orelse return error.InvalidWaiver) orelse return error.InvalidWaiver, "waiver.code"),
        .target = try requireNonEmptyString(allocator, asString(obj.get("target") orelse return error.InvalidWaiver) orelse return error.InvalidWaiver, "waiver.target"),
        .reason = try requireNonEmptyString(allocator, asString(obj.get("reason") orelse return error.InvalidWaiver) orelse return error.InvalidWaiver, "waiver.reason"),
        .expires = try requireNonEmptyString(allocator, asString(obj.get("expires") orelse return error.InvalidWaiver) orelse return error.InvalidWaiver, "waiver.expires"),
        .created_at = try optionalObjectString(allocator, obj, "created_at"),
        .created_by = try optionalObjectString(allocator, obj, "created_by"),
    };
}

fn canonicalPolishState(allocator: std.mem.Allocator, value: std.json.Value) !PolishState {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidPolishState,
    };
    return .{
        .session_id = try optionalObjectString(allocator, obj, "session_id"),
        .passes = if (obj.get("passes")) |v| try normalizePolishPasses(allocator, v) else &.{},
    };
}

fn normalizePolishPasses(allocator: std.mem.Allocator, value: std.json.Value) ![]const PolishPass {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(PolishPass).empty;
            for (arr.items) |entry| try out.append(allocator, try canonicalPolishPass(allocator, entry));
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidPolishPass,
    };
}

fn canonicalPolishPass(allocator: std.mem.Allocator, value: std.json.Value) !PolishPass {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidPolishPass,
    };
    return .{
        .pass = try requiredObjectInt(obj, "pass", error.InvalidPolishPass),
        .seq = try optionalObjectInt(obj, "seq", 0, error.InvalidPolishPass),
        .created_at = try optionalObjectString(allocator, obj, "created_at"),
        .structure_fingerprint = try optionalObjectString(allocator, obj, "structure_fingerprint"),
        .contract_fingerprint = try optionalObjectString(allocator, obj, "contract_fingerprint"),
        .coverage_fingerprint = try optionalObjectString(allocator, obj, "coverage_fingerprint"),
        .execution_fingerprint = try optionalObjectString(allocator, obj, "execution_fingerprint"),
        .audit_gate = try optionalObjectString(allocator, obj, "audit_gate"),
        .hard_failures = try optionalObjectInt(obj, "hard_failures", 0, error.InvalidPolishPass),
        .warnings = try optionalObjectInt(obj, "warnings", 0, error.InvalidPolishPass),
        .delta = if (obj.get("delta")) |v| try canonicalPolishDelta(v) else .{},
    };
}

fn canonicalPolishDelta(value: std.json.Value) !PolishDelta {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidPolishPass,
    };
    return .{
        .items_added = try optionalObjectInt(obj, "items_added", 0, error.InvalidPolishPass),
        .items_removed = try optionalObjectInt(obj, "items_removed", 0, error.InvalidPolishPass),
        .items_split = try optionalObjectInt(obj, "items_split", 0, error.InvalidPolishPass),
        .deps_changed = try optionalObjectInt(obj, "deps_changed", 0, error.InvalidPolishPass),
        .contracts_changed = try optionalObjectInt(obj, "contracts_changed", 0, error.InvalidPolishPass),
        .intent_coverage_changed = try optionalObjectInt(obj, "intent_coverage_changed", 0, error.InvalidPolishPass),
    };
}

fn canonicalGraphFingerprints(allocator: std.mem.Allocator, value: std.json.Value) !GraphFingerprints {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidGraphFingerprints,
    };
    return .{
        .structure = try optionalObjectString(allocator, obj, "structure"),
        .contract = try optionalObjectString(allocator, obj, "contract"),
        .coverage = try optionalObjectString(allocator, obj, "coverage"),
        .execution = try optionalObjectString(allocator, obj, "execution"),
    };
}

fn optionalObjectBool(obj: std.json.ObjectMap, key: []const u8, default_value: bool) !bool {
    return if (obj.get(key)) |v| switch (v) {
        .bool => |b| b,
        .null => default_value,
        else => error.InvalidGraphPolicy,
    } else default_value;
}

fn optionalObjectInt(obj: std.json.ObjectMap, key: []const u8, default_value: i64, err: anyerror) !i64 {
    return if (obj.get(key)) |v| switch (v) {
        .integer => |n| n,
        .null => default_value,
        else => err,
    } else default_value;
}

fn requiredObjectInt(obj: std.json.ObjectMap, key: []const u8, err: anyerror) !i64 {
    return if (obj.get(key)) |v| switch (v) {
        .integer => |n| n,
        else => err,
    } else err;
}

fn normalizeClaimState(raw: []const u8) !ClaimState {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(trimmed, "held")) return .held;
    if (std.ascii.eqlIgnoreCase(trimmed, "stale")) return .stale;
    if (std.ascii.eqlIgnoreCase(trimmed, "released")) return .released;
    return error.InvalidClaimState;
}

fn normalizeDeps(allocator: std.mem.Allocator, value: std.json.Value) ![]Dep {
    const items = switch (value) {
        .array => |arr| arr.items,
        else => return error.InvalidDeps,
    };

    var out = std.ArrayList(Dep).empty;
    var seen = std.StringHashMap(void).init(allocator);

    for (items) |entry| {
        const dep = try canonicalDepEdge(allocator, entry);
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ dep.id, dep.type });
        if (seen.get(key) != null) continue;
        try seen.put(key, {});
        try out.append(allocator, dep);
    }

    return out.toOwnedSlice(allocator);
}

fn canonicalDepEdge(allocator: std.mem.Allocator, value: std.json.Value) !Dep {
    switch (value) {
        .string => |id_raw| {
            const id = try requireNonEmptyString(allocator, id_raw, "dependency id");
            return .{ .id = id, .type = "blocks" };
        },
        .object => |obj| {
            const id = try requireNonEmptyString(allocator, asString(obj.get("id") orelse return error.InvalidDeps) orelse return error.InvalidDeps, "dependency id");
            const type_raw = if (obj.get("type")) |t| asString(t) orelse return error.InvalidDepType else "blocks";
            const dep_type = try normalizeDepType(allocator, type_raw);
            return .{ .id = id, .type = dep_type };
        },
        else => return error.InvalidDeps,
    }
}

fn parseCliDeps(allocator: std.mem.Allocator, raw: []const u8) ![]Dep {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return &.{};

    var out = std.ArrayList(Dep).empty;
    var seen = std.StringHashMap(void).init(allocator);

    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len == 0) return error.EmptyDependencyToken;

        const colon = std.mem.indexOfScalar(u8, token, ':');
        const dep_id: []const u8 = if (colon) |idx| try requireNonEmptyString(allocator, token[0..idx], "dependency id") else try requireNonEmptyString(allocator, token, "dependency id");
        const dep_type: []const u8 = if (colon) |idx| try normalizeDepType(allocator, token[idx + 1 ..]) else "blocks";

        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ dep_id, dep_type });
        if (seen.get(key) != null) continue;
        try seen.put(key, {});
        try out.append(allocator, .{ .id = dep_id, .type = dep_type });
    }

    return out.toOwnedSlice(allocator);
}

fn normalizeDepType(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var lower = std.ArrayList(u8).empty;
    for (raw) |c| {
        try lower.append(allocator, std.ascii.toLower(c));
    }
    const trimmed = std.mem.trim(u8, lower.items, " \t\r\n");
    const candidate = if (trimmed.len == 0) "blocks" else trimmed;

    if (!isKebabCase(candidate)) return error.InvalidDepType;
    return candidate;
}

fn isKebabCase(text: []const u8) bool {
    if (text.len == 0) return false;
    var prev_dash = false;
    for (text, 0..) |c, idx| {
        if (c == '-') {
            if (idx == 0 or idx == text.len - 1 or prev_dash) return false;
            prev_dash = true;
            continue;
        }
        prev_dash = false;
        if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'z'))) return false;
    }
    return true;
}

fn normalizeStatus(raw: []const u8) !Status {
    var lower_buf: [32]u8 = undefined;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > lower_buf.len) return error.InvalidStatus;

    for (trimmed, 0..) |c, idx| lower_buf[idx] = std.ascii.toLower(c);
    const lower = lower_buf[0..trimmed.len];

    if (std.mem.eql(u8, lower, "open") or std.mem.eql(u8, lower, "queued") or std.mem.eql(u8, lower, "pending")) return .pending;
    if (std.mem.eql(u8, lower, "active") or std.mem.eql(u8, lower, "doing") or std.mem.eql(u8, lower, "in_progress") or std.mem.eql(u8, lower, "in-progress")) return .in_progress;
    if (std.mem.eql(u8, lower, "done") or std.mem.eql(u8, lower, "closed") or std.mem.eql(u8, lower, "completed")) return .completed;
    if (std.mem.eql(u8, lower, "blocked")) return .blocked;
    if (std.mem.eql(u8, lower, "deferred")) return .deferred;
    if (std.mem.eql(u8, lower, "canceled") or std.mem.eql(u8, lower, "cancelled")) return .canceled;

    return error.InvalidStatus;
}

fn normalizePriority(raw: []const u8) !Priority {
    var lower_buf: [16]u8 = undefined;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > lower_buf.len) return error.InvalidPriority;

    for (trimmed, 0..) |c, idx| lower_buf[idx] = std.ascii.toLower(c);
    const lower = lower_buf[0..trimmed.len];

    if (std.mem.eql(u8, lower, "high")) return .high;
    if (std.mem.eql(u8, lower, "medium")) return .medium;
    if (std.mem.eql(u8, lower, "low")) return .low;

    return error.InvalidPriority;
}

fn collectSeqContractIssues(allocator: std.mem.Allocator, records: []const std.json.Value) ![]const []const u8 {
    var issues = std.ArrayList([]const u8).empty;

    var max_prefix_seq: i64 = 0;
    var last_checkpoint_index: ?usize = null;
    var last_checkpoint_seq: i64 = 0;

    for (records, 0..) |record, idx| {
        const version = intField(record, "v");
        if (version == null or (version.? != 2 and version.? != SchemaVersion and version.? != GraphSchemaVersion)) {
            try issues.append(allocator, try std.fmt.allocPrint(allocator, "record {d} has unsupported version", .{idx + 1}));
            continue;
        }

        const seq = intField(record, "seq");
        if (seq == null or seq.? < 0) {
            try issues.append(allocator, try std.fmt.allocPrint(allocator, "record {d} has invalid seq", .{idx + 1}));
            continue;
        }

        if (version.? == SchemaVersion or version.? == GraphSchemaVersion) {
            const lane = normalizedLane(record) orelse {
                try issues.append(allocator, try std.fmt.allocPrint(allocator, "record {d} has invalid lane", .{idx + 1}));
                continue;
            };
            if (std.mem.eql(u8, lane, "checkpoint")) {
                if (seq.? != max_prefix_seq) {
                    try issues.append(allocator, try std.fmt.allocPrint(
                        allocator,
                        "record {d} checkpoint seq {d} must match current watermark {d}",
                        .{ idx + 1, seq.?, max_prefix_seq },
                    ));
                }
                last_checkpoint_index = idx;
                last_checkpoint_seq = seq.?;
            }
        }

        if (seq.? > max_prefix_seq) max_prefix_seq = seq.?;
    }

    const trailing_start: usize = if (last_checkpoint_index) |v| v + 1 else 0;
    var trailing_prev: ?i64 = if (last_checkpoint_index != null) last_checkpoint_seq else null;

    var i: usize = trailing_start;
    while (i < records.len) : (i += 1) {
        const seq = intField(records[i], "seq");
        if (seq == null or seq.? < 0) continue;
        if (trailing_prev != null and seq.? <= trailing_prev.?) {
            try issues.append(allocator, try std.fmt.allocPrint(
                allocator,
                "record {d} has non-monotonic trailing seq {d}; previous trailing seq is {d}",
                .{ i + 1, seq.?, trailing_prev.? },
            ));
        }
        trailing_prev = seq.?;
    }

    return issues.toOwnedSlice(allocator);
}

fn normalizedLane(record: std.json.Value) ?[]const u8 {
    if (stringField(record, "lane")) |lane_raw| {
        const lane = std.mem.trim(u8, lane_raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(lane, "event")) return "event";
        if (std.ascii.eqlIgnoreCase(lane, "checkpoint")) return "checkpoint";
        return null;
    }

    if (stringField(record, "kind")) |kind_raw| {
        const kind = std.mem.trim(u8, kind_raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(kind, "event")) return "event";
        if (std.ascii.eqlIgnoreCase(kind, "checkpoint")) return "checkpoint";
    }

    return null;
}

fn normalizedOp(record: std.json.Value) ?[]const u8 {
    const raw = stringField(record, "op") orelse return null;
    const op = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(op, "replace_all")) return "replace";
    return op;
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |obj| obj.get(key),
        else => null,
    };
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const child = objectField(value, key) orelse return null;
    return asString(child);
}

fn asString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn intField(value: std.json.Value, key: []const u8) ?i64 {
    const child = objectField(value, key) orelse return null;
    return switch (child) {
        .integer => |n| n,
        .float => |f| blk: {
            if (!std.math.isFinite(f)) break :blk null;
            const rounded = std.math.round(f);
            if (rounded != f) break :blk null;
            break :blk @intFromFloat(rounded);
        },
        else => null,
    };
}

fn requireNonEmptyString(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        _ = field;
        return error.EmptyString;
    }
    return allocator.dupe(u8, trimmed);
}

fn envTrimmed(name: []const u8) ?[]const u8 {
    const environ = std.Io.Threaded.global_single_threaded.environ.process_environ;
    if (std.process.Environ.getPosix(environ, name)) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn defaultCommentAuthor() []const u8 {
    if (envTrimmed("ST_COMMENT_AUTHOR")) |trimmed| return trimmed;
    if (envTrimmed("USER")) |trimmed| return trimmed;
    if (envTrimmed("LOGNAME")) |trimmed| return trimmed;
    return "unknown";
}

fn currentProcessId() i64 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .plan9 => @intCast(std.os.plan9.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

fn buildMutationMeta(allocator: std.mem.Allocator, allow_multiple: bool) MutationMeta {
    _ = allocator;
    const actor = blk: {
        if (envTrimmed("ST_ACTOR")) |trimmed| break :blk trimmed;
        break :blk defaultCommentAuthor();
    };

    const session = blk: {
        if (envTrimmed("ST_SESSION_ID")) |trimmed| break :blk trimmed;
        if (envTrimmed("CODEX_THREAD_ID")) |trimmed| break :blk trimmed;
        break :blk null;
    };

    return .{
        .allow_multiple_in_progress = allow_multiple,
        .actor = actor,
        .pid = currentProcessId(),
        .session = session,
    };
}

fn resolveCodexHomeAlloc(allocator: std.mem.Allocator) ![]const u8 {
    if (envTrimmed("CODEX_HOME")) |codex_home| return allocator.dupe(u8, codex_home);
    const home = envTrimmed("HOME") orelse return error.MissingHomeEnv;
    return std.fs.path.join(allocator, &.{ home, ".codex" });
}

fn sessionGuardPathAlloc(allocator: std.mem.Allocator, session_id: []const u8, guard_root_override: ?[]const u8) ![]const u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{session_id});
    defer allocator.free(filename);

    if (guard_root_override) |guard_root| {
        return std.fs.path.join(allocator, &.{ guard_root, filename });
    }
    if (envTrimmed("ST_GUARD_ROOT")) |guard_root| {
        return std.fs.path.join(allocator, &.{ guard_root, filename });
    }

    const codex_home = try resolveCodexHomeAlloc(allocator);
    defer allocator.free(codex_home);
    return std.fs.path.join(allocator, &.{ codex_home, "state", "st-session-guards", filename });
}

fn writeSessionGuardState(allocator: std.mem.Allocator, guard: SessionGuardState, guard_root_override: ?[]const u8) !void {
    const path = try sessionGuardPathAlloc(allocator, guard.session_id, guard_root_override);
    defer allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(guard, .{}, &out.writer);
    try out.writer.writeByte('\n');
    const payload = try out.toOwnedSlice();
    try writeTextAtomic(allocator, path, payload);
}

fn readSessionGuardState(allocator: std.mem.Allocator, session_id: []const u8, guard_root_override: ?[]const u8) !?SessionGuardState {
    const path = try sessionGuardPathAlloc(allocator, session_id, guard_root_override);
    defer allocator.free(path);
    if (!fileExists(path)) return null;

    const bytes = try readFileAlloc(allocator, path, 1024 * 1024);
    const parsed = try std.json.parseFromSlice(SessionGuardState, allocator, bytes, .{});
    if (parsed.value.version != SessionGuardStateVersion) return error.UnsupportedSchemaVersion;
    return parsed.value;
}

fn deleteSessionGuardState(allocator: std.mem.Allocator, session_id: []const u8, guard_root_override: ?[]const u8) !void {
    const path = try sessionGuardPathAlloc(allocator, session_id, guard_root_override);
    defer allocator.free(path);
    if (!fileExists(path)) return;

    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse ".";

    if (std.fs.path.isAbsolute(path)) {
        var dir = try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), parent, .{});
        defer dir.close(std.Io.Threaded.global_single_threaded.io());
        try dir.deleteFile(std.Io.Threaded.global_single_threaded.io(), base);
        return;
    }

    var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), parent, .{});
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    try dir.deleteFile(std.Io.Threaded.global_single_threaded.io(), base);
}

fn writeGuardDeny(writer: anytype, hook_json: bool, reason: []const u8) !void {
    if (hook_json) {
        try writer.writeAll("{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":");
        try std.json.Stringify.value(reason, .{}, writer);
        try writer.writeAll("}}\n");
        return;
    }
    try writer.writeAll("{\"decision\":\"block\",\"reason\":");
    try std.json.Stringify.value(reason, .{}, writer);
    try writer.writeAll("}\n");
}

fn updatePlanPayloadsSemanticallyEqual(allocator: std.mem.Allocator, actual: []const u8, expected: []const u8) !bool {
    const actual_entries = parseUpdatePlanEntriesFromBytes(allocator, actual) catch return false;
    const expected_entries = parseUpdatePlanEntriesFromBytes(allocator, expected) catch return false;
    if (actual_entries.len != expected_entries.len) return false;
    for (actual_entries, expected_entries) |a, e| {
        if (!std.mem.eql(u8, a.id, e.id)) return false;
        if (!std.mem.eql(u8, a.step, e.step)) return false;
        if (a.status != e.status) return false;
    }
    return true;
}

fn nowUtcAlloc(allocator: std.mem.Allocator) ![]u8 {
    const now_sec: i64 = @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000));
    var days = @divFloor(now_sec, 86_400);
    var seconds_of_day = now_sec - days * 86_400;
    if (seconds_of_day < 0) {
        seconds_of_day += 86_400;
        days -= 1;
    }

    const date = civilFromDays(days);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(seconds_of_day - hour * 3600, 60);
    const second = seconds_of_day - hour * 3600 - minute * 60;

    const year: u32 = @intCast(date.year);
    const month: u32 = @intCast(date.month);
    const day: u32 = @intCast(date.day);
    const hour_u: u32 = @intCast(hour);
    const minute_u: u32 = @intCast(minute);
    const second_u: u32 = @intCast(second);

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ year, month, day, hour_u, minute_u, second_u },
    );
}

const Date = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn civilFromDays(days_since_unix_epoch: i64) Date {
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    var m = mp + 3;
    if (m > 12) m -= 12;
    if (m <= 2) y += 1;

    return .{ .year = y, .month = m, .day = d };
}

fn ensureLockSidecarGitignored(allocator: std.mem.Allocator, plan_file: []const u8) !void {
    const parent = std.fs.path.dirname(plan_file) orelse ".";
    const git_root = findGitRootAlloc(allocator, parent) catch return;
    if (git_root.len == 0) return;
    const git_root_real_alloc = if (std.fs.path.isAbsolute(git_root))
        std.Io.Dir.realPathFileAbsoluteAlloc(std.Io.Threaded.global_single_threaded.io(), git_root, allocator) catch null
    else
        std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), git_root, allocator) catch null;
    defer if (git_root_real_alloc) |p| allocator.free(p);
    const git_root_real = git_root_real_alloc orelse git_root;

    const plan_rel = if (std.fs.path.isAbsolute(plan_file)) blk: {
        const plan_real = std.Io.Dir.realPathFileAbsoluteAlloc(std.Io.Threaded.global_single_threaded.io(), plan_file, allocator) catch plan_file;
        break :blk try std.fs.path.relative(allocator, git_root_real, null, git_root_real, plan_real);
    } else plan_file;
    const lock_rel = try std.fmt.allocPrint(allocator, "{s}.lock", .{plan_rel});

    var argv = [_][]const u8{ "git", "-C", git_root_real, "check-ignore", "-q", "--", lock_rel };
    const result = try runCommandCapture(allocator, null, &argv);
    if (result.exit_code == 0) return;
    if (result.exit_code == 1) {
        const fix_cmd = try std.fmt.allocPrint(
            allocator,
            "cd {s} && echo {s} >> .gitignore",
            .{ git_root, lock_rel },
        );
        _ = fix_cmd;
        return error.LockSidecarNotGitignored;
    }
    return error.GitCommandFailed;
}

fn findGitRootAlloc(allocator: std.mem.Allocator, start: []const u8) ![]const u8 {
    var argv = [_][]const u8{ "git", "-C", start, "rev-parse", "--show-toplevel" };
    const result = try runCommandCapture(allocator, null, &argv);
    if (result.exit_code != 0) return error.GitCommandFailed;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.GitCommandFailed;
    return allocator.dupe(u8, trimmed);
}

const CommandCapture = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
};

fn runCommandCapture(allocator: std.mem.Allocator, cwd: ?[]const u8, argv: []const []const u8) !CommandCapture {
    const result = try std.process.run(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    const exit_code: i32 = switch (result.term) {
        .exited => |code| code,
        else => -1,
    };

    return .{
        .exit_code = exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn fileExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

fn fileSize(path: []const u8) !u64 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{});
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
        return stat.size;
    }

    var file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    const stat = try file.stat(std.Io.Threaded.global_single_threaded.io());
    return stat.size;
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

fn writeTextAtomic(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    try ensureParentPath(path);

    const base = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse ".";
    const tmp_name = try std.fmt.allocPrint(allocator, ".{s}.{d}.tmp", .{ base, std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds });

    if (std.fs.path.isAbsolute(path)) {
        var dir = try std.Io.Dir.openDirAbsolute(std.Io.Threaded.global_single_threaded.io(), parent, .{});
        defer dir.close(std.Io.Threaded.global_single_threaded.io());

        var file = try dir.createFile(std.Io.Threaded.global_single_threaded.io(), tmp_name, .{ .truncate = true, .read = true });
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), text);
        try file.sync(std.Io.Threaded.global_single_threaded.io());
        try dir.rename(tmp_name, dir, base, std.Io.Threaded.global_single_threaded.io());
        return;
    }

    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(std.Io.Threaded.global_single_threaded.io(), parent, .{});
    defer dir.close(std.Io.Threaded.global_single_threaded.io());

    var file = try dir.createFile(std.Io.Threaded.global_single_threaded.io(), tmp_name, .{ .truncate = true, .read = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), text);
    try file.sync(std.Io.Threaded.global_single_threaded.io());
    try dir.rename(tmp_name, dir, base, std.Io.Threaded.global_single_threaded.io());
}

fn ensureParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;

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

fn joinCommaLimited(buf: []u8, items: []const []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    for (items, 0..) |item, idx| {
        if (idx > 0) try writer.writeAll(",");
        try writer.writeAll(item);
    }
    return writer.buffer;
}

fn formatDepsLimited(buf: []u8, deps: []const Dep) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    for (deps, 0..) |dep, idx| {
        if (idx > 0) try writer.writeAll(",");
        if (std.mem.eql(u8, dep.type, "blocks")) {
            try writer.writeAll(dep.id);
        } else {
            try writer.print("{s}:{s}", .{ dep.id, dep.type });
        }
    }
    return writer.buffer;
}

fn tmpDirRootAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    return dir.realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), ".", allocator);
}

fn makeSeqRecord(
    allocator: std.mem.Allocator,
    lane: []const u8,
    seq: i64,
    op: []const u8,
) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "v", .{ .integer = SchemaVersion });
    try obj.put(allocator, "lane", .{ .string = lane });
    try obj.put(allocator, "seq", .{ .integer = seq });
    try obj.put(allocator, "op", .{ .string = op });
    return .{ .object = obj };
}

test "parseCommand and parseOutputFormat recognize known values" {
    try std.testing.expect(parseCommand("set-status") != null);
    try std.testing.expectEqual(Command.select, parseCommand("select").?);
    try std.testing.expectEqual(Command.deselect, parseCommand("deselect").?);
    try std.testing.expectEqual(Command.import_orchplan, parseCommand("import-orchplan").?);
    try std.testing.expectEqual(Command.claim, parseCommand("claim").?);
    try std.testing.expectEqual(Command.set_runtime, parseCommand("set-runtime").?);
    try std.testing.expectEqual(Command.import_mesh_results, parseCommand("import-mesh-results").?);
    try std.testing.expectEqual(Command.set_priority, parseCommand("set-priority").?);
    try std.testing.expectEqual(Command.prime, parseCommand("prime").?);
    try std.testing.expectEqual(Command.assert_projection, parseCommand("assert-projection").?);
    try std.testing.expectEqual(Command.reconcile_codex, parseCommand("reconcile-codex").?);
    try std.testing.expectEqual(Command.import_proposed_plan, parseCommand("import-proposed-plan").?);
    try std.testing.expectEqual(Command.guard_session_start, parseCommand("guard-session-start").?);
    try std.testing.expectEqual(Command.guard_pre_tool_use, parseCommand("guard-pre-tool-use").?);
    try std.testing.expectEqual(Command.graph, parseCommand("graph").?);
    try std.testing.expectEqual(Command.complete, parseCommand("complete").?);
    try std.testing.expectEqual(Command.proof, parseCommand("proof").?);
    try std.testing.expectEqual(GraphCommand.apply, parseGraphCommand("apply").?);
    try std.testing.expectEqual(GraphCommand.insights, parseGraphCommand("insights").?);
    try std.testing.expectEqual(PolishCommand.snapshot, parsePolishCommand("snapshot").?);
    try std.testing.expectEqual(ApertureCommand.select, parseApertureCommand("select").?);
    try std.testing.expectEqual(CompileCommand.aperture, parseCompileCommand("aperture").?);
    try std.testing.expectEqual(ProofCommand.audit, parseProofCommand("audit").?);
    try std.testing.expectEqual(AuditGate.implementation_ready, parseAuditGate("implementation-ready").?);
    try std.testing.expect(parseCommand("unknown-cmd") == null);

    try std.testing.expectEqual(OutputFormat.markdown, parseOutputFormat("markdown").?);
    try std.testing.expectEqual(OutputFormat.table, parseOutputFormat("table").?);
    try std.testing.expectEqual(OutputFormat.json, parseOutputFormat("json").?);
    try std.testing.expect(parseOutputFormat("csv") == null);

    try std.testing.expectEqual(Surface.plan, parseSurface("plan").?);
    try std.testing.expectEqual(Surface.all, parseSurface("all").?);
    try std.testing.expectEqual(Surface.backlog, parseSurface("backlog").?);
    try std.testing.expect(parseSurface("queue") == null);
}

test "dependencyState maps blocked and waiting statuses" {
    const base = Item{
        .id = "st-001",
        .step = "sample",
        .status = .pending,
        .priority = .medium,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    };

    try std.testing.expectEqual(DepState.ready, dependencyState(base, &.{}));

    const waiting_on = [_][]const u8{"st-009"};
    try std.testing.expectEqual(DepState.waiting_on_deps, dependencyState(base, &waiting_on));

    var blocked_item = base;
    blocked_item.status = .blocked;
    try std.testing.expectEqual(DepState.blocked_manual, dependencyState(blocked_item, &.{}));

    var done_item = base;
    done_item.status = .completed;
    try std.testing.expectEqual(DepState.na, dependencyState(done_item, &.{}));
}

test "canonicalItem defaults missing priority to medium" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"id\":\"st-001\",\"step\":\"Sample\",\"status\":\"pending\",\"deps\":[],\"notes\":\"\",\"comments\":[]}",
        .{},
    );

    const item = try canonicalItem(allocator, parsed.value);
    try std.testing.expectEqual(Priority.medium, item.priority);
    try std.testing.expect(item.in_plan);
}

test "canonicalItem demotes terminal items out of the plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"id\":\"st-002\",\"step\":\"Done\",\"status\":\"completed\",\"priority\":\"medium\",\"in_plan\":true,\"deps\":[],\"notes\":\"\",\"comments\":[]}",
        .{},
    );

    const item = try canonicalItem(allocator, parsed.value);
    try std.testing.expect(!item.in_plan);
}

test "canonicalItem preserves orchestration metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"id":"st-003","step":"Mesh unit","status":"pending","priority":"medium","in_plan":true,"deps":[],"notes":"","comments":[],"related_to":["st-002"],"scope":["src/api/**"],"location":["src/api/router.ts"],"validation":["npm test -w api"],"agent":"worker","role":"implementation","source":{"kind":"orchplan","locator":"orchplan.yaml","source_task_id":"api","wave_id":"w1"},"claim":{"state":"held","owner":"tester","executor":"teams","wave_id":"w1","lock_roots":["src/api"],"claimed_at":"2026-03-12T00:00:00Z","lease_seconds":900,"lease_expires_at":"2026-03-12T00:15:00Z","heartbeat_at":"2026-03-12T00:00:00Z","attempts":1},"runtime":{"substrate":"spawn_agent","thread_id":"thread-1","agent_id":"agent-1","last_event":"runtime_attached"},"proof":{"state":"pass","command":"npm test -w api","evidence_ref":"log.txt","last_run_at":"2026-03-12T00:01:00Z"}}
    ,
        .{},
    );

    const item = try canonicalItem(allocator, parsed.value);
    try std.testing.expectEqualStrings("st-002", item.related_to[0]);
    try std.testing.expectEqualStrings("src/api/**", item.scope[0]);
    try std.testing.expectEqualStrings("worker", item.agent);
    try std.testing.expectEqualStrings("w1", item.source.?.wave_id);
    try std.testing.expectEqual(ClaimState.held, item.claim.?.state);
    try std.testing.expectEqualStrings("src/api", item.claim.?.lock_roots[0]);
    try std.testing.expectEqualStrings("spawn_agent", item.runtime.?.substrate);
    try std.testing.expectEqual(ProofState.pass, item.proof.?.state);
}

test "canonicalItem preserves graph capsule metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"id":"st-004","step":"Implement graph capsule","status":"pending","priority":"high","in_plan":true,"deps":[],"notes":"","comments":[],"item_type":"feature","parent_id":"st-001","links":[{"id":"st-009","type":"tests","reason":"coverage"}],"intent_refs":["intent-001"],"acceptance":["capsule round-trips"],"contract":{"objective":"Add capsule fields.","background":"Graph mode needs structured tasks.","implementation_approach":"Extend canonical item parser and writer.","success_criteria":["fields persist"],"proof_obligations":[{"id":"proof-001","kind":"unit","command":"zig build test-st","required":true}],"risks":["metadata loss"]},"labels":["graph"],"lock_roots":["apps/st"],"uncertainty":["parser defaults"],"non_goals":["external runtime integration"]}
    ,
        .{},
    );

    const item = try canonicalItem(allocator, parsed.value);
    try std.testing.expectEqual(ItemType.feature, item.item_type);
    try std.testing.expectEqualStrings("st-001", item.parent_id.?);
    try std.testing.expectEqualStrings("st-009", item.links[0].id);
    try std.testing.expectEqualStrings("tests", item.links[0].type);
    try std.testing.expectEqualStrings("intent-001", item.intent_refs[0]);
    try std.testing.expectEqualStrings("capsule round-trips", item.acceptance[0]);
    try std.testing.expectEqualStrings("Add capsule fields.", item.contract.?.objective);
    try std.testing.expectEqualStrings("proof-001", item.contract.?.proof_obligations[0].id);
    try std.testing.expect(item.contract.?.proof_obligations[0].required);
    try std.testing.expectEqualStrings("apps/st", item.lock_roots[0]);
    try std.testing.expectEqualStrings("external runtime integration", item.non_goals[0]);
}

test "v4 graph envelope round trips and stays out of plan_sync projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });

    var state = ItemState.init(allocator);
    defer state.deinit();
    state.graph_active = true;
    state.graph = .{
        .policy = .{ .completion_requires_proof = true },
        .intent = &.{
            .{
                .id = "intent-001",
                .source = .{ .kind = "markdown", .locator = "PLAN.md", .anchor = "Graph" },
                .text = "Graph metadata must be durable.",
                .category = "requirement",
                .disposition = "covered",
            },
        },
        .waivers = &.{
            .{
                .id = "waiver-001",
                .gate = "implementation-ready",
                .code = "fixture-only",
                .target = "st-001",
                .reason = "Fixture waiver exercises v4 round-trip.",
                .expires = "never",
            },
        },
        .fingerprints = .{ .structure = "sha256:structure" },
    };
    try state.upsert(.{
        .id = "st-001",
        .step = "Implement graph metadata",
        .status = .pending,
        .priority = .high,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .intent_refs = &.{"intent-001"},
        .acceptance = &.{"Graph envelope survives canonical rewrite"},
        .contract = .{
            .objective = "Round-trip graph metadata.",
            .proof_obligations = &.{.{ .id = "proof-001", .kind = "unit", .command = "zig build test-st" }},
        },
    });

    const meta = MutationMeta{ .allow_multiple_in_progress = false, .actor = "test", .pid = 1, .session = null };
    try writeCanonicalRecords(plan_path, &state, 1, "2026-06-03T00:00:00Z", meta, null);

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    try std.testing.expect(loaded.state.graph_active);
    try std.testing.expectEqual(GraphSchemaVersion, intField((try readRecords(allocator, plan_path)).records[0], "v").?);
    try std.testing.expect(loaded.state.graph.policy.completion_requires_proof);
    try std.testing.expectEqualStrings("intent-001", loaded.state.graph.intent[0].id);
    try std.testing.expectEqualStrings("waiver-001", loaded.state.graph.waivers[0].id);
    try std.testing.expectEqual(ItemType.feature, loaded.state.items.items[0].item_type);
    try std.testing.expectEqualStrings("intent-001", loaded.state.items.items[0].intent_refs[0]);

    var sync_writer: std.Io.Writer.Allocating = .init(allocator);
    defer sync_writer.deinit();
    try emitPlanSyncWithPolicy(allocator, &sync_writer.writer, &loaded.state, .{}, false);
    const sync_payload = try sync_writer.toOwnedSlice();
    try std.testing.expect(std.mem.indexOf(u8, sync_payload, "\"graph\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, sync_payload, "\"intent_refs\"") != null);
}

test "graph apply writes v4 candidate after implementation-ready gate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const patch_path = try std.fs.path.join(allocator, &.{ root, "patch.json" });
    try writeTextAtomic(allocator, patch_path,
        \\{"version":1,"author":"test","reason":"fixture graph apply","ops":[
        \\{"op":"upsert-intent","intent":{"id":"intent-001","source":{"kind":"markdown","locator":"PLAN.md"},"text":"Graph patch applies.","category":"requirement","disposition":"covered"}},
        \\{"op":"upsert-item","item":{"id":"st-001","step":"Implement graph apply fixture","status":"pending","priority":"high","in_plan":true,"item_type":"feature","intent_refs":["intent-001"],"acceptance":["Patch applies atomically"],"validation":["zig build test-st"],"contract":{"objective":"Apply graph patch.","proof_obligations":[{"id":"proof-001","kind":"unit","command":"zig build test-st"}]}}}
        \\]}
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    const exit_code = try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = plan_path, .input = patch_path, .gate = .implementation_ready });
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    try std.testing.expect(loaded.state.graph_active);
    try std.testing.expectEqualStrings("intent-001", loaded.state.graph.intent[0].id);
    try std.testing.expectEqual(ItemType.feature, loaded.state.items.items[0].item_type);
}

test "graph apply rejects invalid patch atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const patch_path = try std.fs.path.join(allocator, &.{ root, "bad.patch.json" });
    try writeTextAtomic(allocator, patch_path,
        \\{"version":1,"author":"test","reason":"bad dep","ops":[
        \\{"op":"upsert-item","item":{"id":"st-001","step":"Bad dep","deps":[{"id":"missing","type":"requires"}]}}
        \\]}
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    const exit_code = try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = plan_path, .input = patch_path, .gate = .draft });
    try std.testing.expectEqual(@as(u8, 2), exit_code);
    try std.testing.expect(!fileExists(plan_path));
}

test "graph audit implementation-ready findings can be waived by exact target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    state.graph_active = true;
    state.graph.waivers = &.{.{
        .id = "waiver-001",
        .gate = "implementation-ready",
        .code = "executable-item-missing-acceptance",
        .target = "st-001",
        .reason = "Fixture waiver",
        .expires = "never",
    }};
    try state.upsert(.{
        .id = "st-001",
        .step = "Waived missing acceptance",
        .status = .pending,
        .priority = .high,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .validation = &.{"zig build test-st"},
        .contract = .{ .objective = "Exercise waiver." },
    });

    const audit = try auditGraph(allocator, &state, .implementation_ready);
    try std.testing.expectEqual(@as(usize, 0), audit.errors);
}

test "graph insights and polish gate use stable fingerprints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const patch_path = try std.fs.path.join(allocator, &.{ root, "patch.json" });
    try writeTextAtomic(allocator, patch_path,
        \\{"version":1,"author":"test","reason":"fixture graph polish","ops":[
        \\{"op":"upsert-intent","intent":{"id":"intent-001","source":{"kind":"markdown","locator":"PLAN.md"},"text":"Polish gate passes.","category":"requirement","disposition":"covered"}},
        \\{"op":"upsert-item","item":{"id":"st-001","step":"Implement polish fixture","status":"pending","priority":"high","in_plan":true,"item_type":"feature","intent_refs":["intent-001"],"acceptance":["Polish gate passes"],"validation":["zig build test-st"],"lock_roots":["apps/st"],"contract":{"objective":"Exercise polish.","proof_obligations":[{"id":"proof-001","kind":"unit","command":"zig build test-st"}]}}}
        \\]}
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = plan_path, .input = patch_path, .gate = .implementation_ready }));
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .insights, .file = plan_path, .format = .json }));
    try std.testing.expectEqual(@as(u8, 2), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .polish, .polish_command = .gate, .file = plan_path, .gate = .implementation_ready, .min_stable_passes = 1 }));
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .polish, .polish_command = .begin, .file = plan_path, .name = "fixture" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .polish, .polish_command = .snapshot, .file = plan_path, .pass_number = "1", .gate = .implementation_ready }));
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .polish, .polish_command = .gate, .file = plan_path, .gate = .implementation_ready, .min_stable_passes = 1 }));

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.state.graph.polish.passes.len);
    try std.testing.expect(std.mem.startsWith(u8, loaded.state.graph.polish.passes[0].structure_fingerprint, "sha256:"));
}

test "aperture ranks ready executable work and prime selects it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    state.graph_active = true;
    try state.upsert(.{
        .id = "st-001",
        .step = "Completed dependency",
        .status = .completed,
        .priority = .medium,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });
    try state.upsert(.{
        .id = "st-002",
        .step = "Ready high value",
        .status = .pending,
        .priority = .high,
        .in_plan = false,
        .deps = &.{.{ .id = "st-001", .type = "requires" }},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .acceptance = &.{"done"},
        .validation = &.{"zig build test-st"},
        .lock_roots = &.{"apps/st"},
        .contract = .{ .objective = "ready", .proof_obligations = &.{.{ .id = "proof-001", .kind = "unit", .command = "zig build test-st" }} },
    });
    try state.upsert(.{
        .id = "st-003",
        .step = "Blocked item",
        .status = .pending,
        .priority = .high,
        .in_plan = false,
        .deps = &.{.{ .id = "st-099", .type = "requires" }},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .acceptance = &.{"done"},
        .validation = &.{"zig build test-st"},
        .contract = .{ .objective = "blocked" },
    });
    try state.upsert(.{
        .id = "st-004",
        .step = "Epic context",
        .status = .pending,
        .priority = .high,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .epic,
    });

    const selected = try selectApertureIds(allocator, &state, 7);
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("st-002", selected[0]);

    const changed = try applyPrimeSelection(allocator, &state, .aperture, 7);
    try std.testing.expect(changed);
    try std.testing.expect(state.getConst("st-002").?.in_plan);
    try std.testing.expect(!state.getConst("st-003").?.in_plan);
    try std.testing.expect(!state.getConst("st-004").?.in_plan);
}

test "graph complete requires proof and demotes completed item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const patch_path = try std.fs.path.join(allocator, &.{ root, "patch.json" });
    try writeTextAtomic(allocator, patch_path,
        \\{"version":1,"author":"test","reason":"proof completion fixture","ops":[
        \\{"op":"upsert-intent","intent":{"id":"intent-001","text":"Completion requires proof.","category":"requirement","disposition":"covered"}},
        \\{"op":"upsert-item","item":{"id":"st-001","step":"Implement proof fixture","status":"pending","priority":"high","in_plan":true,"item_type":"feature","intent_refs":["intent-001"],"acceptance":["Completion is proof-gated"],"validation":["zig build test-st"],"lock_roots":["apps/st"],"contract":{"objective":"Exercise proof-aware completion.","proof_obligations":[{"id":"proof-001","kind":"unit","command":"zig build test-st","required":true}]}}}
        \\]}
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = plan_path, .input = patch_path, .gate = .implementation_ready }));
    try std.testing.expectEqual(@as(u8, 2), try cmdSetStatus(allocator, .{ .command = .set_status, .file = plan_path, .id = "st-001", .status = "completed" }));

    var blocked = try loadValidatedState(allocator, plan_path, false);
    defer blocked.state.deinit();
    try std.testing.expectEqual(Status.pending, blocked.state.getConst("st-001").?.status);

    try std.testing.expectEqual(@as(u8, 0), try cmdComplete(allocator, .{ .command = .complete, .file = plan_path, .id = "st-001", .step = "zig build test-st", .evidence_ref = "proof.log" }));
    var completed = try loadValidatedState(allocator, plan_path, false);
    defer completed.state.deinit();
    const item = completed.state.getConst("st-001").?;
    try std.testing.expectEqual(Status.completed, item.status);
    try std.testing.expect(!item.in_plan);
    try std.testing.expectEqual(ProofState.pass, item.proof.?.state);
    try std.testing.expectEqualStrings("proof.log", item.proof.?.evidence_ref);
    try std.testing.expectEqual(@as(u8, 0), try cmdProof(allocator, .{ .command = .proof, .proof_command = .audit, .file = plan_path, .id = "st-001", .format = .json }));
}

test "emitPlanSync keeps inventory while filtering mirrored plan projections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{
        .id = "st-001",
        .step = "First step",
        .status = .pending,
        .priority = .high,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });
    try state.upsert(.{
        .id = "st-002",
        .step = "Canceled step",
        .status = .canceled,
        .priority = .low,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try emitPlanSync(allocator, &out.writer, &state, false, false);
    const actual = try out.toOwnedSlice();

    try std.testing.expectEqualStrings(
        "{\"version\":3,\"source\":{\"file\":\".step/st-plan.jsonl\",\"seq\":0},\"explanation\":\"Primed from st selected frontier.\",\"projection\":{\"target\":\"all\",\"mode\":\"selected\",\"limit\":7,\"empty_reason\":null,\"warnings\":[]},\"items\":[{\"id\":\"st-001\",\"step\":\"First step\",\"status\":\"pending\",\"priority\":\"high\",\"in_plan\":true,\"deps\":[],\"notes\":\"\",\"comments\":[],\"dep_state\":\"ready\",\"waiting_on\":[]},{\"id\":\"st-002\",\"step\":\"Canceled step\",\"status\":\"canceled\",\"priority\":\"low\",\"in_plan\":false,\"deps\":[],\"notes\":\"\",\"comments\":[],\"dep_state\":\"n/a\",\"waiting_on\":[]}],\"codex\":{\"plan\":[{\"step\":\"[st-001] First step\",\"status\":\"pending\"}]},\"opencode\":{\"todos\":[{\"content\":\"First step\",\"status\":\"pending\",\"priority\":\"high\"}]}}\n",
        actual,
    );
}

test "Codex projection payload contains only update_plan rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{
        .id = "st-001",
        .step = "High priority step",
        .status = .in_progress,
        .priority = .high,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const result = try computeProjectionResult(allocator, &state, .{ .target = .codex });
    try writeCodexUpdatePlanPayload(&out.writer, result.codex_plan);
    try out.writer.writeByte('\n');
    const actual = try out.toOwnedSlice();

    try std.testing.expectEqualStrings(
        "{\"plan\":[{\"step\":\"[st-001] High priority step\",\"status\":\"in_progress\"}]}\n",
        actual,
    );
}

test "reconcile-codex updates mirrored fields and preserves durable metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const update_plan_path = try std.fs.path.join(allocator, &.{ root, "update-plan.json" });

    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "Initial parent",
        .priority = "high",
    });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-002",
        .step = "Initial child",
        .priority = "medium",
        .backlog_only = true,
    });
    _ = try cmdSetDeps(allocator, .{
        .command = .set_deps,
        .file = plan_path,
        .id = "st-002",
        .deps = "st-001",
    });
    _ = try cmdSetNotes(allocator, .{
        .command = .set_notes,
        .file = plan_path,
        .id = "st-002",
        .notes = "preserve me",
    });

    try writeTextAtomic(allocator, update_plan_path,
        \\{"plan":[
        \\  {"step":"[st-002] Renamed child","status":"pending"},
        \\  {"step":"[st-001] Parent complete","status":"completed"}
        \\]}
    );

    _ = try cmdReconcileCodex(allocator, .{
        .command = .reconcile_codex,
        .file = plan_path,
        .input = update_plan_path,
    });

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();

    try std.testing.expectEqualStrings("st-002", loaded.state.items.items[0].id);
    try std.testing.expectEqualStrings("Renamed child", loaded.state.items.items[0].step);
    try std.testing.expectEqual(Status.pending, loaded.state.items.items[0].status);
    try std.testing.expect(loaded.state.items.items[0].in_plan);
    try std.testing.expectEqualStrings("preserve me", loaded.state.items.items[0].notes);
    try std.testing.expectEqualStrings("st-001", loaded.state.items.items[0].deps[0].id);

    try std.testing.expectEqualStrings("st-001", loaded.state.items.items[1].id);
    try std.testing.expectEqualStrings("Parent complete", loaded.state.items.items[1].step);
    try std.testing.expectEqual(Status.completed, loaded.state.items.items[1].status);
    try std.testing.expect(!loaded.state.items.items[1].in_plan);
}

test "reconcile-codex transcript path uses latest turn boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const transcript_path = try std.fs.path.join(allocator, &.{ root, "session.jsonl" });

    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "First",
        .priority = "medium",
    });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-002",
        .step = "Second",
        .priority = "medium",
        .backlog_only = true,
    });

    try writeTextAtomic(allocator, transcript_path,
        \\{"type":"turn_context","payload":{"turn_id":"1"}}
        \\{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"[st-001] Old choice\",\"status\":\"pending\"}]}" }}
        \\{"type":"turn_context","payload":{"turn_id":"2"}}
        \\{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"[st-002] Latest choice\",\"status\":\"pending\"}]}" }}
    );

    _ = try cmdReconcileCodex(allocator, .{
        .command = .reconcile_codex,
        .file = plan_path,
        .transcript_path = transcript_path,
    });

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();

    try std.testing.expectEqualStrings("st-002", loaded.state.items.items[0].id);
    try std.testing.expectEqualStrings("Latest choice", loaded.state.items.items[0].step);
    try std.testing.expect(loaded.state.items.items[0].in_plan);
    try std.testing.expect(!loaded.state.items.items[1].in_plan);
}

test "session guard blocks until latest turn matches expected update_plan payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const transcript_path = try std.fs.path.join(allocator, &.{ root, "session.jsonl" });
    const guard_root = try std.fs.path.join(allocator, &.{ root, "guard-root" });

    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "First",
        .priority = "medium",
    });

    _ = try cmdGuardSessionStart(allocator, .{
        .command = .guard_session_start,
        .file = plan_path,
        .session_id = "session-1",
        .guard_root = guard_root,
    });

    try writeTextAtomic(allocator, transcript_path,
        \\{"type":"turn_context","payload":{"turn_id":"1"}}
        \\{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"wrong\",\"status\":\"pending\"}]}" }}
    );
    _ = try cmdGuardPreToolUse(allocator, .{
        .command = .guard_pre_tool_use,
        .session_id = "session-1",
        .transcript_path = transcript_path,
        .guard_root = guard_root,
    });
    try std.testing.expect((try readSessionGuardState(allocator, "session-1", guard_root)) != null);

    const guard = (try readSessionGuardState(allocator, "session-1", guard_root)).?;
    var transcript_writer: std.Io.Writer.Allocating = .init(allocator);
    defer transcript_writer.deinit();
    try transcript_writer.writer.writeAll("{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"1\"}}\n");
    try transcript_writer.writer.writeAll("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"update_plan\",\"arguments\":");
    try std.json.Stringify.value(guard.expected_update_plan, .{}, &transcript_writer.writer);
    try transcript_writer.writer.writeAll("}}\n");
    const transcript_payload = try transcript_writer.toOwnedSlice();
    try writeTextAtomic(allocator, transcript_path, transcript_payload);

    _ = try cmdGuardPreToolUse(allocator, .{
        .command = .guard_pre_tool_use,
        .session_id = "session-1",
        .transcript_path = transcript_path,
        .guard_root = guard_root,
    });
    try std.testing.expect((try readSessionGuardState(allocator, "session-1", guard_root)) == null);
}

test "session guard short-circuits when mirrored plan is empty or terminal-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const guard_root = try std.fs.path.join(allocator, &.{ root, "guard-root" });

    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdGuardSessionStart(allocator, .{
        .command = .guard_session_start,
        .file = plan_path,
        .session_id = "session-empty",
        .guard_root = guard_root,
    });
    try std.testing.expect((try readSessionGuardState(allocator, "session-empty", guard_root)) == null);

    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "Done",
        .priority = "medium",
    });
    _ = try cmdSetStatus(allocator, .{
        .command = .set_status,
        .file = plan_path,
        .id = "st-001",
        .status = "completed",
    });
    _ = try cmdGuardSessionStart(allocator, .{
        .command = .guard_session_start,
        .file = plan_path,
        .session_id = "session-complete",
        .guard_root = guard_root,
    });
    try std.testing.expect((try readSessionGuardState(allocator, "session-complete", guard_root)) == null);
}

test "reconcile-codex rejects malformed codex plan steps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const update_plan_path = try std.fs.path.join(allocator, &.{ root, "bad-update-plan.json" });

    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "Only step",
        .priority = "medium",
    });

    try writeTextAtomic(allocator, update_plan_path,
        \\{"plan":[{"step":"Only step","status":"pending"}]}
    );

    try std.testing.expectError(error.InvalidCodexPlanStep, cmdReconcileCodex(allocator, .{
        .command = .reconcile_codex,
        .file = plan_path,
        .input = update_plan_path,
    }));
}

test "reconcile-codex no-op path avoids rewriting the durable plan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const update_plan_path = try std.fs.path.join(allocator, &.{ root, "update-plan.json" });

    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "Stable step",
        .priority = "medium",
    });

    try writeTextAtomic(allocator, update_plan_path,
        \\{"plan":[{"step":"[st-001] Stable step","status":"pending"}]}
    );

    _ = try cmdReconcileCodex(allocator, .{
        .command = .reconcile_codex,
        .file = plan_path,
        .input = update_plan_path,
    });

    const after_first = try readFileAlloc(allocator, plan_path, 1024 * 1024);
    const seq_after_first = (try readRecords(allocator, plan_path)).latest_seq;

    _ = try cmdReconcileCodex(allocator, .{
        .command = .reconcile_codex,
        .file = plan_path,
        .input = update_plan_path,
    });

    const after_second = try readFileAlloc(allocator, plan_path, 1024 * 1024);
    const seq_after_second = (try readRecords(allocator, plan_path)).latest_seq;

    try std.testing.expectEqual(seq_after_first, seq_after_second);
    try std.testing.expectEqualStrings(after_first, after_second);
}

test "prime auto-top-up selects ready backlog without selecting waiting children" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });

    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{ .command = .add, .file = plan_path, .id = "st-001", .step = "Ready parent", .backlog_only = true });
    _ = try cmdAdd(allocator, .{ .command = .add, .file = plan_path, .id = "st-002", .step = "Waiting child", .deps = "st-001", .backlog_only = true });

    _ = try cmdPrime(allocator, .{ .command = .prime, .file = plan_path, .mode = .auto_top_up, .limit = 2 });

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    try std.testing.expect(loaded.state.getConst("st-001").?.in_plan);
    try std.testing.expect(!loaded.state.getConst("st-002").?.in_plan);
}

test "projection emits at most one Codex in_progress and warns on parallel active rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{ .id = "st-001", .step = "Local active", .status = .in_progress, .priority = .medium, .in_plan = true, .deps = &.{}, .notes = "", .comments = &.{}, .runtime = .{ .substrate = "local" } });
    try state.upsert(.{ .id = "st-002", .step = "Parallel active", .status = .in_progress, .priority = .medium, .in_plan = true, .deps = &.{}, .notes = "", .comments = &.{} });

    const result = try computeProjectionResult(allocator, &state, .{ .target = .codex });
    var active_count: usize = 0;
    for (result.codex_plan) |entry| {
        if (std.mem.eql(u8, entry.status, "in_progress")) active_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), active_count);
    try std.testing.expectEqualStrings("st-001", result.codex_plan[0].id);
    try std.testing.expect(result.warnings.len >= 1);
}

test "reconcile-codex parses app-server plan events and inProgress status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const transcript =
        \\{"type":"turn_context","payload":{"turn_id":"1"}}
        \\{"type":"turn/plan/updated","payload":{"plan":[{"step":"[st-001] Active","status":"inProgress"}]}}
    ;
    const entries = try parseUpdatePlanEntriesFromTranscriptBytes(allocator, transcript);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(Status.in_progress, entries[0].status);
    try std.testing.expectEqualStrings("Active", entries[0].step);
}

test "guard comparison is semantic across update_plan whitespace differences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect(try updatePlanPayloadsSemanticallyEqual(
        allocator,
        "{ \"plan\" : [ { \"step\" : \"[st-001] Same\", \"status\" : \"pending\" } ] }",
        "{\"plan\":[{\"step\":\"[st-001] Same\",\"status\":\"pending\"}]}",
    ));
    try std.testing.expect(!try updatePlanPayloadsSemanticallyEqual(
        allocator,
        "{\"plan\":[{\"step\":\"[st-001] Same\",\"status\":\"completed\"}]}",
        "{\"plan\":[{\"step\":\"[st-001] Same\",\"status\":\"pending\"}]}",
    ));
}

test "import-proposed-plan imports markdown as backlog and optional linear implementation deps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const proposed_path = try std.fs.path.join(allocator, &.{ root, "proposed.md" });
    try writeTextAtomic(allocator, proposed_path,
        \\# Implementation
        \\1. Step 1: Reproduce failure
        \\2. Task 2: Patch parser
        \\
        \\# Test Plan
        \\- Add regression test
    );

    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdImportProposedPlan(allocator, .{
        .command = .import_proposed_plan,
        .file = plan_path,
        .input = proposed_path,
        .infer_linear_deps = true,
    });

    var loaded = try loadValidatedState(allocator, plan_path, true);
    defer loaded.state.deinit();
    try std.testing.expectEqual(@as(usize, 3), loaded.state.items.items.len);
    try std.testing.expect(!loaded.state.getConst("st-001").?.in_plan);
    try std.testing.expectEqualStrings("Reproduce failure", loaded.state.getConst("st-001").?.step);
    try std.testing.expectEqualStrings("st-001", loaded.state.getConst("st-002").?.deps[0].id);
    try std.testing.expectEqual(@as(usize, 0), loaded.state.getConst("st-003").?.deps.len);
    try std.testing.expectEqualStrings("proposed_plan", loaded.state.getConst("st-003").?.source.?.kind);
}

test "select auto-includes dependency closure and deselect rejects stranded dependents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });

    _ = try cmdInit(allocator, .{ .command = .init, .file = plan_path, .replace = true });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-001",
        .step = "Parent",
        .priority = "medium",
        .backlog_only = true,
    });
    _ = try cmdAdd(allocator, .{
        .command = .add,
        .file = plan_path,
        .id = "st-002",
        .step = "Child",
        .priority = "medium",
        .backlog_only = true,
    });
    _ = try cmdSetDeps(allocator, .{
        .command = .set_deps,
        .file = plan_path,
        .id = "st-002",
        .deps = "st-001",
    });
    _ = try cmdSelect(allocator, .{
        .command = .select,
        .file = plan_path,
        .ids = "st-002",
    });

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    try std.testing.expect(loaded.state.getConst("st-001").?.in_plan);
    try std.testing.expect(loaded.state.getConst("st-002").?.in_plan);

    try std.testing.expectError(error.PlanDependencyNotSelected, cmdDeselect(allocator, .{
        .command = .deselect,
        .file = plan_path,
        .ids = "st-001",
    }));
}

test "import-orchplan and claim-safe runtime allow parallel wave progress" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const orchplan_path = try std.fs.path.join(allocator, &.{ root, "orchplan.yaml" });
    try writeTextAtomic(allocator, orchplan_path,
        \\schema_version: 1
        \\kind: OrchPlan
        \\tasks:
        \\  - id: cfg
        \\    title: Update config loader
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["src/config/**"]
        \\    location: ["src/config/index.ts"]
        \\    validation: ["npm test -w config"]
        \\  - id: ui
        \\    title: Update settings UI
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["src/ui/**"]
        \\    location: ["src/ui/Settings.tsx"]
        \\    validation: ["npm test -w ui"]
        \\waves:
        \\  - id: w1
        \\    tasks: [cfg, ui]
    );

    _ = try cmdImportOrchplan(allocator, .{ .command = .import_orchplan, .file = plan_path, .input = orchplan_path, .replace = true });
    _ = try cmdClaim(allocator, .{ .command = .claim, .file = plan_path, .executor = "teams", .wave = "w1" });
    _ = try cmdSetRuntime(allocator, .{ .command = .set_runtime, .file = plan_path, .id = "cfg", .substrate = "spawn_agent", .thread_id = "thread-cfg" });
    _ = try cmdSetRuntime(allocator, .{ .command = .set_runtime, .file = plan_path, .id = "ui", .substrate = "spawn_agent", .thread_id = "thread-ui" });

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();

    const cfg = loaded.state.getConst("cfg").?;
    const ui = loaded.state.getConst("ui").?;
    try std.testing.expectEqual(Status.in_progress, cfg.status);
    try std.testing.expectEqual(Status.in_progress, ui.status);
    try std.testing.expectEqual(ClaimState.held, cfg.claim.?.state);
    try std.testing.expectEqualStrings("w1", cfg.claim.?.wave_id);
    try std.testing.expectEqualStrings("src/config", cfg.claim.?.lock_roots[0]);
    try std.testing.expectEqualStrings("src/ui", ui.claim.?.lock_roots[0]);
}

test "orchplan-backed claim rejects explicit ids when wave is authoritative" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const orchplan_path = try std.fs.path.join(allocator, &.{ root, "orchplan.yaml" });
    try writeTextAtomic(allocator, orchplan_path,
        \\schema_version: 1
        \\kind: OrchPlan
        \\tasks:
        \\  - id: cfg
        \\    title: Update config loader
        \\    agent: worker
        \\    scope: ["src/config/**"]
        \\waves:
        \\  - id: w1
        \\    tasks: [cfg]
    );

    _ = try cmdImportOrchplan(allocator, .{ .command = .import_orchplan, .file = plan_path, .input = orchplan_path, .replace = true });
    try std.testing.expectError(error.OrchplanWaveClaimDoesNotAcceptIds, cmdClaim(allocator, .{
        .command = .claim,
        .file = plan_path,
        .ids = "cfg",
        .executor = "teams",
        .wave = "w1",
    }));
}

test "reclaim-stale and import-mesh-results reconcile execution metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const orchplan_path = try std.fs.path.join(allocator, &.{ root, "mesh-orchplan.yaml" });
    const results_path = try std.fs.path.join(allocator, &.{ root, "mesh-results.csv" });
    try writeTextAtomic(allocator, orchplan_path,
        \\schema_version: 1
        \\kind: OrchPlan
        \\tasks:
        \\  - id: api
        \\    title: Add health endpoint
        \\    agent: worker
        \\    role: implementation
        \\    scope: ["src/api/**"]
        \\    validation: ["npm test -w api"]
        \\waves:
        \\  - id: w1
        \\    tasks: [api]
    );

    _ = try cmdImportOrchplan(allocator, .{ .command = .import_orchplan, .file = plan_path, .input = orchplan_path, .replace = true });
    _ = try cmdClaim(allocator, .{ .command = .claim, .file = plan_path, .executor = "mesh", .wave = "w1", .lease_seconds = "60" });
    _ = try cmdSetRuntime(allocator, .{ .command = .set_runtime, .file = plan_path, .id = "api", .substrate = "spawn_agents_on_csv", .row_id = "api" });
    _ = try cmdReclaimStale(allocator, .{ .command = .reclaim_stale, .file = plan_path, .now = "2099-01-01T00:00:00Z" });

    var loaded_stale = try loadValidatedState(allocator, plan_path, false);
    defer loaded_stale.state.deinit();
    try std.testing.expectEqual(ClaimState.stale, loaded_stale.state.getConst("api").?.claim.?.state);
    try std.testing.expectEqual(Status.pending, loaded_stale.state.getConst("api").?.status);

    _ = try cmdClaim(allocator, .{ .command = .claim, .file = plan_path, .ids = "api", .executor = "mesh", .wave = "w2" });
    try writeTextAtomic(allocator, results_path,
        \\task_id,proof_status,proof_evidence,decision
        \\api,pass,mesh-proof.txt,proof_complete
    );
    _ = try cmdImportMeshResults(allocator, .{ .command = .import_mesh_results, .file = plan_path, .input = results_path });

    var loaded_final = try loadValidatedState(allocator, plan_path, false);
    defer loaded_final.state.deinit();
    const api = loaded_final.state.getConst("api").?;
    try std.testing.expectEqual(Status.completed, api.status);
    try std.testing.expectEqual(ProofState.pass, api.proof.?.state);
    try std.testing.expectEqualStrings("mesh-proof.txt", api.proof.?.evidence_ref);
    try std.testing.expectEqualStrings("spawn_agents_on_csv", api.runtime.?.substrate);
    try std.testing.expectEqual(ClaimState.released, api.claim.?.state);
}

test "runPerfCase covers representative Wave B seams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const root = try tmpDirRootAlloc(alloc, tmp.dir);

    const cases = [_]PerfCase{
        .init,
        .set_status,
        .set_deps,
        .prime,
        .import_plan,
    };

    for (cases) |perf_case| {
        const exit_code = try runPerfCase(alloc, perf_case, root);
        try std.testing.expectEqual(@as(u8, 0), exit_code);
    }
}

test "collectSeqContractIssues detects non-monotonic trailing seq" {
    var records = [_]std.json.Value{
        try makeSeqRecord(std.testing.allocator, "event", 1, "init"),
        try makeSeqRecord(std.testing.allocator, "checkpoint", 1, "replace"),
        try makeSeqRecord(std.testing.allocator, "event", 2, "replace"),
        try makeSeqRecord(std.testing.allocator, "event", 2, "replace"),
    };
    defer for (&records) |*record| {
        if (record.* == .object) {
            record.object.deinit(std.testing.allocator);
        }
    };

    const issues = try collectSeqContractIssues(std.testing.allocator, &records);
    defer {
        for (issues) |issue| std.testing.allocator.free(issue);
        std.testing.allocator.free(issues);
    }

    try std.testing.expect(issues.len >= 1);
}
