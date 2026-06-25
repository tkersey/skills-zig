const app_meta = @import("app_meta");
const builtin = @import("builtin");
const core_cli = @import("core_cli");
const durable_store = @import("durable_store");
const execution_policy_core = @import("execution_policy_core");
const std = @import("std");

const Version = core_cli.normalizeVersion(app_meta.version);
const SchemaVersion: i64 = 3;
const GraphSchemaVersion: i64 = 4;
const GraphEnvelopeVersion: i64 = 2;
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
    \\usage: st {init,add,select,deselect,set-status,set-priority,set-deps,set-notes,add-comment,remove,show,ready,blocked,doctor,prime,assert-projection,reconcile-codex,import-proposed-plan,guard-session-start,guard-pre-tool-use,export,import-plan,import-orchplan,claim,heartbeat,set-runtime,set-proof,complete,proof,release,reclaim-stale,import-mesh-results,intake,graph,aperture,compile,workspace,plan,session,worktree,changeset,integrate,capabilities} [options]
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
    \\  intake          Material plan intake commands: scaffold, check, normalize, apply
    \\  graph            Graph compiler commands: schema, apply, audit, insights, polish, debt
    \\  aperture         Aperture commands: next, plan, select, explain
    \\  compile          Compile shortcuts: intent, graph, ready, aperture
    \\  workspace        Workspace commands: init, status, aperture
    \\  plan             Workspace plan commands: create, list, show
    \\  session          Workspace session commands: bind, show, switch-plan, release, list
    \\  worktree         Claim-bound external Git worktrees
    \\  changeset        Claim-bound worker output receipts
    \\  integrate        Serialized target-branch integration
    \\  capabilities     Emit machine-readable st feature capabilities
    \\
    \\common options:
    \\  --file PATH                     Path to plan JSONL file (default: .step/st-plan.jsonl)
    \\  --workspace PATH                Path to workspace root (default: .ledger/st)
    \\  --plan PLAN_ID                  Workspace plan id for plan-scoped commands
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

test "st uses execution policy core canonical digest" {
    var policy = try execution_policy_core.parsePolicy(std.testing.allocator, "{\"b\":2,\"a\":1}");
    defer policy.deinit(std.testing.allocator);
    var digest_a = try execution_policy_core.canonicalPolicyDigest(std.testing.allocator, &policy);
    defer digest_a.deinit(std.testing.allocator);

    var equivalent = try execution_policy_core.parsePolicy(std.testing.allocator, "{\"a\":1,\"b\":2}");
    defer equivalent.deinit(std.testing.allocator);
    var digest_b = try execution_policy_core.canonicalPolicyDigest(std.testing.allocator, &equivalent);
    defer digest_b.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(digest_a.text, digest_b.text);
}

const InitHelpText =
    \\st init
    \\
    \\Initialize plan storage.
    \\
    \\usage: st init --file PATH [--replace]
    \\
    \\options:
    \\  --file PATH       Path to plan JSONL file (default: .step/st-plan.jsonl)
    \\  --replace         Replace existing plan storage
    \\  -h, --help        Show help for init
;

const AddHelpText =
    \\st add
    \\
    \\Add or upsert a plan item.
    \\
    \\usage: st add --file PATH --id ID --step TEXT [options]
    \\
    \\options:
    \\  --id ID           Durable item id, for example st-001
    \\  --step TEXT       Task text
    \\  --status STATUS   pending|in_progress|completed|blocked|deferred|canceled
    \\  --priority LEVEL  high|medium|low
    \\  --deps DEPS       Comma-separated dependency list, for example st-001:blocks
    \\  --backlog-only    Add item outside the mirrored plan projection
    \\  --file PATH       Path to plan JSONL file
    \\  -h, --help        Show help for add
;

const SelectHelpText =
    \\st select
    \\
    \\Add tasks into the mirrored plan projection.
    \\
    \\usage: st select --file PATH [--ids IDS] [--status STATUS] [--priority LEVEL]
    \\
    \\options:
    \\  --ids IDS         Comma-separated item ids
    \\  --status STATUS   Select items with this status
    \\  --priority LEVEL  Select items with this priority
    \\  --file PATH       Path to plan JSONL file
    \\  -h, --help        Show help for select
;

const DeselectHelpText =
    \\st deselect
    \\
    \\Remove tasks from the mirrored plan projection.
    \\
    \\usage: st deselect --file PATH [--ids IDS] [--status STATUS] [--priority LEVEL]
    \\
    \\options:
    \\  --ids IDS         Comma-separated item ids
    \\  --status STATUS   Deselect items with this status
    \\  --priority LEVEL  Deselect items with this priority
    \\  --file PATH       Path to plan JSONL file
    \\  -h, --help        Show help for deselect
;

const SetStatusHelpText =
    \\st set-status
    \\
    \\Set item status.
    \\
    \\usage: st set-status --file PATH --id ID --status STATUS [options]
    \\
    \\options:
    \\  --id ID             Durable item id
    \\  --status STATUS     pending|in_progress|completed|blocked|deferred|canceled
    \\  --allow-unproven    Allow graph-mode completion without proof
    \\  --reason TEXT       Waiver reason when allowing unproven completion
    \\  --file PATH         Path to plan JSONL file
    \\  -h, --help          Show help for set-status
;

const SetPriorityHelpText =
    \\st set-priority
    \\
    \\Set item priority.
    \\
    \\usage: st set-priority --file PATH --id ID --priority high|medium|low
    \\
    \\options:
    \\  --id ID           Durable item id
    \\  --priority LEVEL  high|medium|low
    \\  --file PATH       Path to plan JSONL file
    \\  -h, --help        Show help for set-priority
;

const SetDepsHelpText =
    \\st set-deps
    \\
    \\Set item dependencies.
    \\
    \\usage: st set-deps --file PATH --id ID --deps DEPS
    \\
    \\options:
    \\  --id ID       Durable item id
    \\  --deps DEPS   Comma-separated dependency list, for example st-001:blocks
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for set-deps
;

const SetNotesHelpText =
    \\st set-notes
    \\
    \\Set item notes.
    \\
    \\usage: st set-notes --file PATH --id ID --notes TEXT
    \\
    \\options:
    \\  --id ID       Durable item id
    \\  --notes TEXT  Notes to store on the item
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for set-notes
;

const AddCommentHelpText =
    \\st add-comment
    \\
    \\Add a comment to an item.
    \\
    \\usage: st add-comment --file PATH --id ID --text TEXT [--author NAME]
    \\
    \\options:
    \\  --id ID        Durable item id
    \\  --text TEXT    Comment text
    \\  --author NAME  Comment author (default: codex)
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for add-comment
;

const RemoveHelpText =
    \\st remove
    \\
    \\Remove item.
    \\
    \\usage: st remove --file PATH --id ID
    \\
    \\options:
    \\  --id ID       Durable item id
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for remove
;

const ShowHelpText =
    \\st show
    \\
    \\Show current plan.
    \\
    \\usage: st show --file PATH [--id ID] [--surface plan|all|backlog] [--format markdown|table|json]
    \\
    \\options:
    \\  --id ID            Show one durable item by id
    \\  --surface SURFACE  plan|all|backlog (default: plan)
    \\  --format FORMAT    markdown|table|json
    \\  --file PATH        Path to plan JSONL file
    \\  -h, --help         Show help for show
;

const ReadyHelpText =
    \\st ready
    \\
    \\Show ready pending items.
    \\
    \\usage: st ready --file PATH [--surface plan|all|backlog] [--format markdown|table|json]
    \\
    \\options:
    \\  --surface SURFACE  plan|all|backlog (default: plan)
    \\  --format FORMAT    markdown|table|json
    \\  --file PATH        Path to plan JSONL file
    \\  -h, --help         Show help for ready
;

const BlockedHelpText =
    \\st blocked
    \\
    \\Show blocked or waiting items.
    \\
    \\usage: st blocked --file PATH [--surface plan|all|backlog] [--format markdown|table|json]
    \\
    \\options:
    \\  --surface SURFACE  plan|all|backlog (default: plan)
    \\  --format FORMAT    markdown|table|json
    \\  --file PATH        Path to plan JSONL file
    \\  -h, --help         Show help for blocked
;

const DoctorHelpText =
    \\st doctor
    \\
    \\Inspect or repair seq contract integrity.
    \\
    \\usage: st doctor --file PATH [--repair-seq]
    \\
    \\options:
    \\  --repair-seq   Repair seq contract issues when possible
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for doctor
;

const PrimeHelpText =
    \\st prime
    \\
    \\Select/project the durable frontier and emit plan_sync v3.
    \\
    \\usage: st prime --file PATH [options]
    \\
    \\options:
    \\  --mode MODE                    selected|auto-top-up|replace-ready|aperture
    \\  --limit N                      Projection limit (default: 7)
    \\  --target codex|opencode|all    Projection target
    \\  --preview                      Compute output without writing selection changes
    \\  --allow-multiple-in-progress   Allow multiple in_progress items
    \\  --file PATH                    Path to plan JSONL file
    \\  -h, --help                     Show help for prime
;

const AssertProjectionHelpText =
    \\st assert-projection
    \\
    \\Validate Codex/OpenCode projection invariants.
    \\
    \\usage: st assert-projection --file PATH [--strict|--no-strict] [--limit N] [--target codex|opencode|all]
    \\
    \\options:
    \\  --strict       Enforce strict projection invariants (default)
    \\  --no-strict    Relax strict projection invariants
    \\  --limit N      Projection limit (default: 7)
    \\  --target NAME  codex|opencode|all
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for assert-projection
;

const ReconcileCodexHelpText =
    \\st reconcile-codex
    \\
    \\Reconcile Codex update_plan payload or transcript into mirrored durable fields.
    \\
    \\usage: st reconcile-codex --file PATH (--input JSON | --transcript-path PATH)
    \\
    \\options:
    \\  --input PATH            JSON update_plan payload
    \\  --transcript-path PATH  Codex session transcript JSONL
    \\  --file PATH             Path to plan JSONL file
    \\  -h, --help              Show help for reconcile-codex
;

const ImportProposedPlanHelpText =
    \\st import-proposed-plan
    \\
    \\Import Plan Mode Markdown into durable backlog tasks.
    \\
    \\usage: st import-proposed-plan --file PATH --input PATH [options]
    \\
    \\options:
    \\  --input PATH          Proposed-plan markdown
    \\  --replace             Replace existing items
    \\  --backlog-only        Keep imported items outside projection
    \\  --select-ready        Select ready imported items
    \\  --id-prefix PREFIX    Generated id prefix (default: st)
    \\  --start-at N          First generated id number
    \\  --infer-linear-deps   Infer linear dependencies
    \\  --file PATH           Path to plan JSONL file
    \\  -h, --help            Show help for import-proposed-plan
;

const GuardSessionStartHelpText =
    \\st guard-session-start
    \\
    \\Register expected SessionStart update_plan payload for a Codex session.
    \\
    \\usage: st guard-session-start --session-id ID [--guard-root PATH] [--hook-json]
    \\
    \\options:
    \\  --session-id ID    Codex session id
    \\  --guard-root PATH  Guard state directory
    \\  --hook-json        Emit Codex hook JSON
    \\  -h, --help         Show help for guard-session-start
;

const GuardPreToolUseHelpText =
    \\st guard-pre-tool-use
    \\
    \\Check whether a SessionStart guard has been satisfied for the current turn.
    \\
    \\usage: st guard-pre-tool-use --session-id ID --transcript-path PATH [--guard-root PATH] [--hook-json]
    \\
    \\options:
    \\  --session-id ID         Codex session id
    \\  --transcript-path PATH  Codex session transcript JSONL
    \\  --guard-root PATH       Guard state directory
    \\  --hook-json             Emit Codex hook JSON
    \\  -h, --help              Show help for guard-pre-tool-use
;

const ExportHelpText =
    \\st export
    \\
    \\Export snapshot JSON.
    \\
    \\usage: st export --file PATH --output PATH
    \\
    \\options:
    \\  --output PATH  Snapshot output path
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for export
;

const ImportPlanHelpText =
    \\st import-plan
    \\
    \\Import snapshot JSON.
    \\
    \\usage: st import-plan --file PATH --input PATH [--replace] [--backlog-only]
    \\
    \\options:
    \\  --input PATH    Snapshot JSON path
    \\  --replace       Replace existing items
    \\  --backlog-only  Keep imported items outside projection
    \\  --file PATH     Path to plan JSONL file
    \\  -h, --help      Show help for import-plan
;

const ImportOrchplanHelpText =
    \\st import-orchplan
    \\
    \\Import OrchPlan tasks into the durable ledger.
    \\
    \\usage: st import-orchplan --file PATH --input PATH [--replace] [--backlog-only]
    \\
    \\options:
    \\  --input PATH    OrchPlan JSON or YAML path
    \\  --replace       Replace existing items
    \\  --backlog-only  Keep imported items outside projection
    \\  --file PATH     Path to plan JSONL file
    \\  -h, --help      Show help for import-orchplan
;

const ClaimHelpText =
    \\st claim
    \\
    \\Claim a safe wave or task set, or manage workspace-global claims.
    \\
    \\usage: st claim --file PATH (--ids IDS | --wave WAVE) --executor NAME [--lease-seconds N]
    \\       st claim grant --workspace PATH --session SESSION --executor NAME [--resources SPEC] [--lease-seconds N]
    \\       st claim {heartbeat,release,amend} --workspace PATH --claim CLAIM --session SESSION --fencing-token N [--resources SPEC]
    \\       st claim {show,list,conflicts,reclaim-stale} --workspace PATH [options]
    \\
    \\options:
    \\  --ids IDS            Comma-separated item ids
    \\  --wave WAVE          Wave id to claim
    \\  --executor NAME      Claim owner
    \\  --lease-seconds N    Lease duration (default: 900)
    \\  --resources SPEC     Comma-separated mode:resource entries for workspace claims
    \\  --claim CLAIM        Workspace claim id
    \\  --session SESSION    Workspace session id
    \\  --fencing-token N    Workspace fencing token
    \\  --workspace PATH     Workspace root
    \\  --file PATH          Path to plan JSONL file
    \\  -h, --help           Show help for claim
;

const WorktreeHelpText =
    \\st worktree
    \\
    \\Create claim-bound external Git worktrees.
    \\
    \\usage: st worktree create --workspace PATH --claim CLAIM --session SESSION --fencing-token N --output PATH [--source REPO]
    \\
    \\options:
    \\  --workspace PATH     Workspace root
    \\  --claim CLAIM        Workspace claim id
    \\  --session SESSION    Workspace session id
    \\  --fencing-token N    Workspace fencing token
    \\  --output PATH        External worktree path
    \\  --source REPO        Source repository root (default: current directory)
    \\  -h, --help           Show help for worktree
;

const ChangesetHelpText =
    \\st changeset
    \\
    \\Seal and manage claim-bound worker outputs.
    \\
    \\usage: st changeset seal --workspace PATH --claim CLAIM --session SESSION --fencing-token N --worktree PATH [--id ID] [--from OLD]
    \\       st changeset show --workspace PATH --id ID
    \\       st changeset reject --workspace PATH --id ID
    \\       st changeset supersede --workspace PATH --id OLD --to NEW
    \\
    \\options:
    \\  --workspace PATH     Workspace root
    \\  --claim CLAIM        Workspace claim id
    \\  --session SESSION    Workspace session id
    \\  --fencing-token N    Workspace fencing token
    \\  --worktree PATH      External worker worktree
    \\  --id ID              Change-set id
    \\  --from ID            Superseded change-set id for seal
    \\  --to ID              Superseding change-set id
    \\  -h, --help           Show help for changeset
;

const IntegrateHelpText =
    \\st integrate
    \\
    \\Serialize target-branch integration for sealed change sets.
    \\
    \\usage: st integrate enqueue --workspace PATH --id CHANGESET
    \\       st integrate status --workspace PATH
    \\       st integrate preview --workspace PATH [--id CHANGESET]
    \\       st integrate apply --workspace PATH --id CHANGESET [--source REPO] [--expect-branch-epoch N]
    \\       st integrate reject --workspace PATH --id CHANGESET
    \\       st integrate recover --workspace PATH
    \\
    \\options:
    \\  --workspace PATH          Workspace root
    \\  --id CHANGESET            Change-set id
    \\  --source REPO             Target repository root (default: current directory)
    \\  --expect-branch-epoch N   Expected branch epoch
    \\  --format FORMAT           json|markdown
    \\  -h, --help                Show help for integrate
;

const SessionHelpText =
    \\st session
    \\
    \\Manage session-scoped workspace views.
    \\
    \\usage: st session bind --workspace PATH --session SESSION --executor NAME [--plan PLAN] [--claim CLAIM --fencing-token N] [--ids IDS]
    \\       st session show --workspace PATH --session SESSION
    \\       st session switch-plan --workspace PATH --session SESSION --plan PLAN
    \\       st session release --workspace PATH --session SESSION
    \\       st session list --workspace PATH
    \\
    \\options:
    \\  --workspace PATH     Workspace root
    \\  --session SESSION    Session id
    \\  --executor NAME      Executor id
    \\  --plan PLAN          Plan id
    \\  --claim CLAIM        Workspace claim id
    \\  --fencing-token N    Workspace fencing token
    \\  --ids IDS            Comma-separated selected item ids
    \\  --format FORMAT      json|markdown
    \\  -h, --help           Show help for session
;

const HeartbeatHelpText =
    \\st heartbeat
    \\
    \\Refresh a held claim lease.
    \\
    \\usage: st heartbeat --file PATH --id ID
    \\
    \\options:
    \\  --id ID       Durable item id
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for heartbeat
;

const SetRuntimeHelpText =
    \\st set-runtime
    \\
    \\Attach runtime execution metadata to a claimed item.
    \\
    \\usage: st set-runtime --file PATH --id ID [options]
    \\
    \\options:
    \\  --id ID              Durable item id
    \\  --substrate NAME     Runtime substrate
    \\  --thread-id ID       Thread id
    \\  --agent-id ID        Agent id
    \\  --row-id ID          Row id
    \\  --output-ref REF     Output reference
    \\  --last-event TEXT    Last runtime event
    \\  --file PATH          Path to plan JSONL file
    \\  -h, --help           Show help for set-runtime
;

const SetProofHelpText =
    \\st set-proof
    \\
    \\Record proof state and evidence for an item.
    \\
    \\usage: st set-proof --file PATH --id ID --proof-state pass|fail|not_run [options]
    \\
    \\options:
    \\  --id ID             Durable item id
    \\  --proof-state STATE pass|fail|not_run
    \\  --proof-id ID       Proof obligation id
    \\  --command CMD       Validation command
    \\  --evidence-ref REF  Evidence path or reference
    \\  --now ISO8601       Proof timestamp
    \\  --file PATH         Path to plan JSONL file
    \\  -h, --help          Show help for set-proof
;

const CompleteHelpText =
    \\st complete
    \\
    \\Complete an item, using current proof receipts or a legacy proof command.
    \\
    \\usage: st complete --file PATH --id ID [--command CMD --evidence-ref REF] [options]
    \\
    \\options:
    \\  --id ID             Durable item id
    \\  --command CMD       Validation command
    \\  --evidence-ref REF  Evidence path or reference
    \\  --proof-id ID       Proof obligation id
    \\  --now ISO8601       Completion timestamp
    \\  --file PATH         Path to plan JSONL file
    \\  -h, --help          Show help for complete
;

const ProofHelpText =
    \\st proof
    \\
    \\Proof commands.
    \\
    \\usage: st proof {audit,plan,record} --file PATH [options]
    \\
    \\commands:
    \\  audit    Audit proof obligations for an item
    \\  plan     Plan proof actions for the selected aperture
    \\  record   Record one obligation-level proof receipt
    \\
    \\options:
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for proof
;

const ProofPlanHelpText =
    \\st proof plan
    \\
    \\Plan proof actions for the selected aperture.
    \\
    \\usage: st proof plan --file PATH [--format json]
    \\
    \\options:
    \\  --format FORMAT  json|markdown
    \\  --file PATH      Path to plan JSONL file
    \\  -h, --help       Show help for proof plan
;

const ProofRecordHelpText =
    \\st proof record
    \\
    \\Record one obligation-level proof receipt.
    \\
    \\usage: st proof record --file PATH --id ITEM --obligation OBL --action ACTION --command CMD --evidence-ref REF [--artifact-ref REF]
    \\
    \\options:
    \\  --id ID             Durable item id
    \\  --obligation ID     Proof obligation id
    \\  --action ID         Proof action id
    \\  --command CMD       Command that produced the receipt
    \\  --evidence-ref REF  Evidence path or reference
    \\  --artifact-ref REF  Artifact fingerprint or reference
    \\  --file PATH         Path to plan JSONL file
    \\  -h, --help          Show help for proof record
;

const ProofAuditHelpText =
    \\st proof audit
    \\
    \\Audit proof obligations for an item.
    \\
    \\usage: st proof audit --file PATH --id ID [--format json|markdown]
    \\
    \\options:
    \\  --id ID         Durable item id
    \\  --format FORMAT json|markdown
    \\  --file PATH     Path to plan JSONL file
    \\  -h, --help      Show help for proof audit
;

const WorkspaceHelpText =
    \\st workspace
    \\
    \\Manage `.ledger/st` workspace storage.
    \\
    \\usage: st workspace {init,status,audit,doctor,recover,export,import,aperture,migrate} [--workspace PATH] [--format json]
    \\
    \\commands:
    \\  aperture  Compute a workspace-global WAP-v1 aperture
    \\  audit     Validate workspace registry and plan files
    \\  doctor    Emit workspace health and recovery status
    \\  export    Export a workspace bundle
    \\  init      Initialize workspace storage
    \\  import    Import a workspace bundle
    \\  migrate   Atomically migrate a legacy `.step` plan into the workspace
    \\  recover   Inspect prepared transaction recovery state
    \\  status    Show workspace status
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for workspace
;

const WorkspaceApertureHelpText =
    \\st workspace aperture
    \\
    \\Compute a workspace-global aperture without mutating plan state.
    \\
    \\usage: st workspace aperture [--workspace PATH] [--limit N] [--format json|markdown]
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --limit N         Maximum selected allocations (default: 7)
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for workspace aperture
;

const WorkspaceAdminHelpText =
    \\st workspace admin
    \\
    \\Audit, doctor, recover, export, or import workspace state.
    \\
    \\usage: st workspace {audit,doctor,recover} --workspace PATH [--format json|markdown]
    \\       st workspace export --workspace PATH --output PATH [--format json|markdown]
    \\       st workspace import --workspace PATH --input PATH [--replace] [--format json|markdown]
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --input PATH      Import bundle path
    \\  --output PATH     Export bundle path
    \\  --replace         Replace existing workspace files during import
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for workspace admin commands
;

const WorkspaceInitHelpText =
    \\st workspace init
    \\
    \\Initialize workspace storage.
    \\
    \\usage: st workspace init [--workspace PATH] [--replace]
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --replace         Replace the workspace metadata file
    \\  -h, --help        Show help for workspace init
;

const WorkspaceStatusHelpText =
    \\st workspace status
    \\
    \\Show workspace status.
    \\
    \\usage: st workspace status [--workspace PATH] [--format json|markdown]
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for workspace status
;

const WorkspaceMigrateHelpText =
    \\st workspace migrate
    \\
    \\Atomically migrate a legacy single-plan JSONL ledger into `.ledger/st`.
    \\
    \\usage: st workspace migrate --from PATH --to PATH --plan-id PLAN_ID [--format json|markdown]
    \\
    \\options:
    \\  --from PATH     Legacy plan JSONL path, for example .step/st-plan.jsonl
    \\  --to PATH       Workspace root to publish, for example .ledger/st
    \\  --plan-id ID    Plan id to register in the workspace
    \\  --format FORMAT json|markdown
    \\  -h, --help      Show help for workspace migrate
;

const PlanHelpText =
    \\st plan
    \\
    \\Manage plans registered in a `.ledger/st` workspace.
    \\
    \\usage: st plan {create,list,show,pause,resume,complete,archive,link,unlink} [--workspace PATH] [--plan PLAN_ID] [--format json|markdown]
    \\
    \\commands:
    \\  create    Create and register a plan
    \\  list      List registered plans
    \\  show      Show one registered plan
    \\  pause     Pause an active plan
    \\  resume    Resume a paused plan
    \\  complete  Mark an active or paused plan completed
    \\  archive   Archive a non-active plan
    \\  link      Add a workspace-owned cross-plan edge
    \\  unlink    Remove a workspace-owned cross-plan edge
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --plan PLAN_ID    Plan id for create/show
    \\  --alias TEXT      Human-readable alias for create
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for plan
;

const PlanCreateHelpText =
    \\st plan create
    \\
    \\Create and register a plan in a workspace.
    \\
    \\usage: st plan create --workspace PATH --plan PLAN_ID [--alias TEXT] [--format json|markdown]
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --plan PLAN_ID    Plan id to create
    \\  --alias TEXT      Human-readable alias (default: PLAN_ID)
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for plan create
;

const PlanListHelpText =
    \\st plan list
    \\
    \\List plans registered in a workspace.
    \\
    \\usage: st plan list [--workspace PATH] [--format json|markdown]
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for plan list
;

const PlanShowHelpText =
    \\st plan show
    \\
    \\Show one plan registered in a workspace.
    \\
    \\usage: st plan show --workspace PATH --plan PLAN_ID [--format json|markdown]
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --plan PLAN_ID    Plan id to show
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for plan show
;

const PlanLifecycleHelpText =
    \\st plan <pause|resume|complete|archive>
    \\
    \\Update one plan registry lifecycle state.
    \\
    \\usage: st plan {pause,resume,complete,archive} --workspace PATH --plan PLAN_ID [--format json|markdown]
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --plan PLAN_ID    Plan id to update
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for plan lifecycle commands
;

const PlanLinkHelpText =
    \\st plan link
    \\
    \\Add a workspace-owned cross-plan edge.
    \\
    \\usage: st plan link --workspace PATH --from plan://PLAN/ITEM --to plan://PLAN/ITEM [--type hard|nonblocking] [--format json|markdown]
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --from REF        Dependent qualified item ref
    \\  --to REF          Referenced qualified item ref
    \\  --type TYPE       hard|nonblocking (default: hard)
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for plan link
;

const PlanUnlinkHelpText =
    \\st plan unlink
    \\
    \\Remove a workspace-owned cross-plan edge.
    \\
    \\usage: st plan unlink --workspace PATH --from plan://PLAN/ITEM --to plan://PLAN/ITEM [--type hard|nonblocking] [--format json|markdown]
    \\
    \\options:
    \\  --workspace PATH  Workspace root (default: .ledger/st)
    \\  --from REF        Dependent qualified item ref
    \\  --to REF          Referenced qualified item ref
    \\  --type TYPE       hard|nonblocking (default: hard)
    \\  --format FORMAT   json|markdown
    \\  -h, --help        Show help for plan unlink
;

const ReleaseHelpText =
    \\st release
    \\
    \\Release a held claim and normalize task status.
    \\
    \\usage: st release --file PATH --id ID [--reason TEXT]
    \\
    \\options:
    \\  --id ID        Durable item id
    \\  --reason TEXT  Release reason
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for release
;

const ReclaimStaleHelpText =
    \\st reclaim-stale
    \\
    \\Reclaim expired held claims.
    \\
    \\usage: st reclaim-stale --file PATH [--now ISO8601]
    \\
    \\options:
    \\  --now ISO8601  Timestamp used for stale-claim comparison
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for reclaim-stale
;

const ImportMeshResultsHelpText =
    \\st import-mesh-results
    \\
    \\Import mesh output CSV results into the ledger.
    \\
    \\usage: st import-mesh-results --file PATH --input PATH
    \\
    \\options:
    \\  --input PATH   Mesh output CSV
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for import-mesh-results
;

const IntakeHelpText =
    \\st intake
    \\
    \\Material plan intake commands.
    \\
    \\usage: st intake {scaffold,plan,check,normalize,apply} --file PATH [options]
    \\
    \\commands:
    \\  scaffold  Write a Markdown intake scaffold
    \\  plan      Deprecated alias for scaffold
    \\  check     Validate intake and emit line/path diagnostics
    \\  normalize Write canonical intake markdown
    \\  apply    Apply a Markdown intake file into the durable graph
    \\
    \\options:
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for intake
;

const IntakePlanHelpText =
    \\st intake plan
    \\
    \\Deprecated alias for st intake scaffold.
    \\
    \\usage: st intake plan --file PATH --source PATH --out PATH
    \\
    \\options:
    \\  --source PATH  Source plan, spec, or markdown path
    \\  --out PATH     Intake markdown output path
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for intake plan
;

const IntakeScaffoldHelpText =
    \\st intake scaffold
    \\
    \\Write a graph intake scaffold.
    \\
    \\usage: st intake scaffold --file PATH --source PATH --out PATH
    \\
    \\options:
    \\  --source PATH  Source plan, spec, or markdown path
    \\  --out PATH     Intake markdown output path
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for intake scaffold
;

const IntakeCheckHelpText =
    \\st intake check
    \\
    \\Validate a Markdown intake file without writing durable state.
    \\
    \\usage: st intake check --input PATH [--gate GATE] [--format json]
    \\
    \\options:
    \\  --input PATH   Intake markdown path
    \\  --gate GATE    draft|implementation-ready|execution-ready|proof-complete
    \\  --format json  Emit machine-readable diagnostics
    \\  -h, --help     Show help for intake check
;

const IntakeNormalizeHelpText =
    \\st intake normalize
    \\
    \\Normalize a Markdown intake file into canonical Markdown.
    \\
    \\usage: st intake normalize --input PATH --out PATH
    \\
    \\options:
    \\  --input PATH   Intake markdown path
    \\  --out PATH     Normalized intake output path
    \\  -h, --help     Show help for intake normalize
;

const IntakeApplyHelpText =
    \\st intake apply
    \\
    \\Apply a Markdown intake file into the durable graph.
    \\
    \\usage: st intake apply --file PATH --input PATH [--gate GATE]
    \\
    \\options:
    \\  --input PATH   Intake markdown path
    \\  --gate GATE    draft|implementation-ready|execution-ready|proof-complete
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for intake apply
;

const GraphHelpText =
    \\st graph
    \\
    \\Graph compiler commands.
    \\
    \\usage: st graph {schema,apply,audit,insights,polish,debt} --file PATH [options]
    \\
    \\commands:
    \\  schema    Emit graph patch schema
    \\  apply     Apply a graph patch
    \\  audit     Audit graph gates
    \\  insights  Emit graph insights
    \\  polish    Fixed-point polish commands
    \\  debt      List, waive, or resolve graph debt
    \\
    \\options:
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for graph
;

const GraphDebtHelpText =
    \\st graph debt
    \\
    \\Graph debt commands.
    \\
    \\usage: st graph debt {list,waive,resolve} --file PATH [options]
    \\
    \\commands:
    \\  list     List current graph debt
    \\  waive    Waive one debt record
    \\  resolve  Mark one debt record resolved
    \\
    \\options:
    \\  --id ID        Debt id for waive/resolve
    \\  --reason TEXT  Waiver reason
    \\  --format json  Emit machine-readable output
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for graph debt
;

const GraphSchemaHelpText =
    \\st graph schema
    \\
    \\Emit graph patch schema.
    \\
    \\usage: st graph schema
    \\
    \\options:
    \\  -h, --help    Show help for graph schema
;

const GraphApplyHelpText =
    \\st graph apply
    \\
    \\Apply a graph patch.
    \\
    \\usage: st graph apply --file PATH --input PATH [--gate GATE] [--dry-run]
    \\
    \\options:
    \\  --input PATH   Graph patch JSON
    \\  --gate GATE    draft|implementation-ready|execution-ready|proof-complete
    \\  --dry-run      Validate without writing
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for graph apply
;

const GraphAuditHelpText =
    \\st graph audit
    \\
    \\Audit graph gates.
    \\
    \\usage: st graph audit --file PATH [--gate GATE] [--format markdown|json]
    \\
    \\options:
    \\  --gate GATE      draft|implementation-ready|execution-ready|proof-complete
    \\  --format FORMAT  markdown|json
    \\  --file PATH      Path to plan JSONL file
    \\  -h, --help       Show help for graph audit
;

const GraphInsightsHelpText =
    \\st graph insights
    \\
    \\Emit graph insights.
    \\
    \\usage: st graph insights --file PATH [--format markdown|json]
    \\
    \\options:
    \\  --format FORMAT  markdown|json
    \\  --file PATH      Path to plan JSONL file
    \\  -h, --help       Show help for graph insights
;

const GraphPolishHelpText =
    \\st graph polish
    \\
    \\Fixed-point polish commands.
    \\
    \\usage: st graph polish {begin,snapshot,status,gate} --file PATH [options]
    \\
    \\commands:
    \\  begin     Start a polish session
    \\  snapshot  Record a polish pass
    \\  status    Show polish status
    \\  gate      Require stable polish passes and a graph gate
    \\
    \\options:
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for graph polish
;

const GraphPolishBeginHelpText =
    \\st graph polish begin
    \\
    \\Start a polish session.
    \\
    \\usage: st graph polish begin --file PATH --name NAME
    \\
    \\options:
    \\  --name NAME   Polish session name
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for graph polish begin
;

const GraphPolishSnapshotHelpText =
    \\st graph polish snapshot
    \\
    \\Record a polish pass.
    \\
    \\usage: st graph polish snapshot --file PATH --pass N [--gate GATE]
    \\
    \\options:
    \\  --pass N      Pass number
    \\  --gate GATE   draft|implementation-ready|execution-ready|proof-complete
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for graph polish snapshot
;

const GraphPolishStatusHelpText =
    \\st graph polish status
    \\
    \\Show polish status.
    \\
    \\usage: st graph polish status --file PATH [--format markdown|json]
    \\
    \\options:
    \\  --format FORMAT  markdown|json
    \\  --file PATH      Path to plan JSONL file
    \\  -h, --help       Show help for graph polish status
;

const GraphPolishGateHelpText =
    \\st graph polish gate
    \\
    \\Require stable polish passes and a graph gate.
    \\
    \\usage: st graph polish gate --file PATH [--min-stable-passes N] [--gate GATE] [--format markdown|json]
    \\
    \\options:
    \\  --min-stable-passes N  Required stable passes (default: 2)
    \\  --gate GATE            draft|implementation-ready|execution-ready|proof-complete
    \\  --format FORMAT        markdown|json
    \\  --file PATH            Path to plan JSONL file
    \\  -h, --help             Show help for graph polish gate
;

const ApertureHelpText =
    \\st aperture
    \\
    \\Aperture commands.
    \\
    \\usage: st aperture {next,plan,select,explain} --file PATH [options]
    \\
    \\commands:
    \\  next     Emit the next aperture candidate
    \\  plan     Emit an aperture plan
    \\  select   Select aperture items into the projection
    \\  explain  Explain aperture selection
    \\
    \\options:
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for aperture
;

const ApertureNextHelpText =
    \\st aperture next
    \\
    \\Emit the next aperture candidate.
    \\
    \\usage: st aperture next --file PATH [--format json]
    \\
    \\options:
    \\  --format FORMAT  json
    \\  --file PATH      Path to plan JSONL file
    \\  -h, --help       Show help for aperture next
;

const AperturePlanHelpText =
    \\st aperture plan
    \\
    \\Emit an aperture plan.
    \\
    \\usage: st aperture plan --file PATH [--limit N] [--format json|markdown]
    \\
    \\options:
    \\  --limit N        Candidate limit (default: 7)
    \\  --format FORMAT  json|markdown
    \\  --file PATH      Path to plan JSONL file
    \\  -h, --help       Show help for aperture plan
;

const ApertureSelectHelpText =
    \\st aperture select
    \\
    \\Select aperture items into the projection.
    \\
    \\usage: st aperture select --file PATH [--limit N] [--strategy aperture-score]
    \\
    \\options:
    \\  --limit N        Candidate limit (default: 7)
    \\  --strategy NAME  Selection strategy (default: aperture-score)
    \\  --file PATH      Path to plan JSONL file
    \\  -h, --help       Show help for aperture select
;

const ApertureExplainHelpText =
    \\st aperture explain
    \\
    \\Explain aperture selection.
    \\
    \\usage: st aperture explain --file PATH [--limit N] [--format markdown]
    \\
    \\options:
    \\  --limit N        Candidate limit (default: 7)
    \\  --format FORMAT  markdown
    \\  --file PATH      Path to plan JSONL file
    \\  -h, --help       Show help for aperture explain
;

const CompileHelpText =
    \\st compile
    \\
    \\Compile shortcuts.
    \\
    \\usage: st compile {intent,graph,ready,aperture} --file PATH [options]
    \\
    \\commands:
    \\  intent    Compile intent atoms into graph state
    \\  graph     Apply a graph patch
    \\  ready     Audit implementation-ready graph state
    \\  aperture  Select and project the execution aperture
    \\
    \\options:
    \\  --file PATH   Path to plan JSONL file
    \\  -h, --help    Show help for compile
;

const CompileIntentHelpText =
    \\st compile intent
    \\
    \\Compile intent atoms into graph state.
    \\
    \\usage: st compile intent --file PATH --input PATH
    \\
    \\options:
    \\  --input PATH   Intent JSON path
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for compile intent
;

const CompileGraphHelpText =
    \\st compile graph
    \\
    \\Apply a graph patch.
    \\
    \\usage: st compile graph --file PATH --input PATH [--gate GATE]
    \\
    \\options:
    \\  --input PATH   Graph patch JSON
    \\  --gate GATE    draft|implementation-ready|execution-ready|proof-complete
    \\  --file PATH    Path to plan JSONL file
    \\  -h, --help     Show help for compile graph
;

const CompileReadyHelpText =
    \\st compile ready
    \\
    \\Audit implementation-ready graph state.
    \\
    \\usage: st compile ready --file PATH [--format markdown|json]
    \\
    \\options:
    \\  --format FORMAT  markdown|json
    \\  --file PATH      Path to plan JSONL file
    \\  -h, --help       Show help for compile ready
;

const CompileApertureHelpText =
    \\st compile aperture
    \\
    \\Select and project the execution aperture.
    \\
    \\usage: st compile aperture --file PATH [--limit N] [--parallelism auto]
    \\       st compile aperture --workspace PATH --plan PLAN --session SESSION --claim CLAIM --fencing-token N [--expect-workspace-seq N] [--expect-plan-seq N] [--expect-branch-epoch N]
    \\
    \\options:
    \\  --limit N                 Projection limit (default: 7)
    \\  --parallelism auto        Legacy no-op compatibility alias
    \\  --file PATH               Path to plan JSONL file
    \\  --workspace PATH          Workspace root for GCR-v2
    \\  --plan PLAN               Workspace plan id for GCR-v2
    \\  --session SESSION         Session id for GCR-v2 view validation
    \\  --claim CLAIM             Claim id for GCR-v2 authority validation
    \\  --fencing-token N         Fencing token for GCR-v2 authority validation
    \\  --expect-workspace-seq N  Expected workspace sequence
    \\  --expect-plan-seq N       Expected plan sequence
    \\  --expect-branch-epoch N   Expected branch epoch
    \\  -h, --help                Show help for compile aperture
;

const CapabilitiesHelpText =
    \\st capabilities
    \\
    \\Emit machine-readable st feature capabilities.
    \\
    \\usage: st capabilities --format json
    \\
    \\options:
    \\  --format FORMAT  json
    \\  -h, --help       Show help for capabilities
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

const ProofReceipt = struct {
    receipt_version: []const u8 = "PRF-v2",
    obligation_id: []const u8,
    action_id: []const u8 = "",
    state: []const u8 = "not_run",
    command: []const u8 = "",
    evidence_ref: []const u8 = "",
    artifact_ref: []const u8 = "",
    recorded_at: []const u8 = "",
    waiver_id: []const u8 = "",
    workspace_id: []const u8 = "",
    workspace_sequence: i64 = -1,
    plan_id: []const u8 = "",
    plan_sequence: i64 = -1,
    branch_epoch: i64 = -1,
    tree_digest: []const u8 = "",
    dependency_resources: []const []const u8 = &.{},
};

const ProofCover = struct {
    item_id: []const u8,
    obligation_id: []const u8,
};

const ProofAction = struct {
    id: []const u8,
    command: []const u8,
    cost: i64 = 1,
    covers: []const ProofCover = &.{},
    scope: []const []const u8 = &.{},
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
    proof_receipts: []const ProofReceipt = &.{},
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
    graph_control_required: bool = false,
    default_projection_strategy: []const u8 = "aperture-score",
    default_gate: []const u8 = "implementation-ready",
    default_parallelism: []const u8 = "auto",
    max_aperture_items: i64 = 7,
    blocking_debt_policy: []const u8 = "warn",
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

const GraphLineageSource = struct {
    kind: []const u8 = "",
    locator: []const u8 = "",
    fingerprint: []const u8 = "",
};

const GraphLineage = struct {
    mode: []const u8 = "legacy",
    materiality: []const u8 = "unknown",
    source: GraphLineageSource = .{},
    intake_id: []const u8 = "",
    compiled_at: []const u8 = "",
    last_audited_seq: i64 = 0,
    last_audit_gate: []const u8 = "",
};

const GraphDebt = struct {
    debt_version: []const u8 = "GD-v1",
    id: []const u8,
    code: []const u8,
    severity: []const u8,
    target: []const u8,
    source: []const u8 = "automatic",
    reason: []const u8,
    created_at: []const u8 = "",
    resolved_at: []const u8 = "",
    waiver_id: []const u8 = "",
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
    lineage: GraphLineage = .{},
    intent: []const IntentAtom = &.{},
    waivers: []const Waiver = &.{},
    debt: []const GraphDebt = &.{},
    proof_actions: []const ProofAction = &.{},
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
    debt,
    insights,
    polish,
    schema,
};

const IntakeCommand = enum {
    none,
    apply,
    check,
    normalize,
    plan,
    scaffold,
};

const DebtCommand = enum {
    none,
    list,
    waive,
    resolve,
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
    plan,
    record,
};

const ClaimCommand = enum {
    grant,
    heartbeat,
    show,
    list,
    release,
    reclaim_stale,
    conflicts,
    amend,
};

const WorkspaceCommand = enum {
    none,
    aperture,
    audit,
    doctor,
    @"export",
    init,
    import,
    migrate,
    recover,
    status,
};

const PlanCommand = enum {
    none,
    create,
    list,
    show,
    pause,
    @"resume",
    complete,
    archive,
    link,
    unlink,
};

const SessionCommand = enum {
    none,
    bind,
    show,
    switch_plan,
    release,
    list,
};

const WorktreeCommand = enum {
    none,
    create,
};

const ChangesetCommand = enum {
    none,
    seal,
    show,
    reject,
    supersede,
};

const IntegrateCommand = enum {
    none,
    enqueue,
    status,
    preview,
    apply,
    reject,
    recover,
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
    deps_added: []const []const u8 = &.{},
    deps_removed: []const []const u8 = &.{},
    links_added: []const []const u8 = &.{},
    links_removed: []const []const u8 = &.{},
    intent_added: []const []const u8 = &.{},
    intent_removed: []const []const u8 = &.{},
    intent_coverage_changed: []const []const u8 = &.{},
    fingerprints_before: GraphFingerprints = .{},
    fingerprints_after: GraphFingerprints = .{},
};

const ItemFingerprint = struct {
    id: []const u8,
    fingerprint: []const u8,
};

const GraphDeltaBaseline = struct {
    item_ids: []const []const u8 = &.{},
    item_fingerprints: []const ItemFingerprint = &.{},
    dep_edges: []const []const u8 = &.{},
    link_edges: []const []const u8 = &.{},
    intent_ids: []const []const u8 = &.{},
    intent_coverage: []const []const u8 = &.{},
    fingerprints: GraphFingerprints = .{},
};

const GraphIndex = struct {
    item_index_by_id: std.StringHashMap(usize),
    predecessors: []const []const usize,
    successors: []const []const usize,
    topological_order: []const usize,
    reverse_topological_order: []const usize,
    dangling_item_id: ?[]const u8 = null,
    dangling_dep_id: ?[]const u8 = null,
    cycle_witness: []const usize = &.{},

    fn deinit(self: *GraphIndex, allocator: std.mem.Allocator) void {
        self.item_index_by_id.deinit();
        for (self.predecessors) |slice| allocator.free(slice);
        for (self.successors) |slice| allocator.free(slice);
        allocator.free(self.predecessors);
        allocator.free(self.successors);
        allocator.free(self.topological_order);
        allocator.free(self.reverse_topological_order);
        if (self.cycle_witness.len > 0) allocator.free(self.cycle_witness);
    }

    fn valid(self: GraphIndex) bool {
        return self.dangling_item_id == null and self.dangling_dep_id == null and self.cycle_witness.len == 0;
    }
};

const IntakeSection = enum {
    none,
    covers,
    depends,
    locations,
    acceptance,
    validation,
    proof,
    background,
    objective,
    approach,
    risks,
};

const IntakeIntentBuilder = struct {
    id: []const u8,
    category: []const u8,
    disposition: []const u8,
    text: []const u8 = "",
    source_locator: []const u8 = "",
};

const IntakeItemBuilder = struct {
    id: []const u8,
    item_type: ItemType,
    priority: Priority,
    step: []const u8 = "",
    covers: std.ArrayList([]const u8) = .empty,
    deps: std.ArrayList(Dep) = .empty,
    locations: std.ArrayList([]const u8) = .empty,
    acceptance: std.ArrayList([]const u8) = .empty,
    validation: std.ArrayList([]const u8) = .empty,
    proof: std.ArrayList(ProofObligation) = .empty,
    background: std.ArrayList(u8) = .empty,
    objective: std.ArrayList(u8) = .empty,
    approach: std.ArrayList(u8) = .empty,
    risks: std.ArrayList([]const u8) = .empty,
};

const ParsedIntake = struct {
    source: []const u8,
    intents: []const IntentAtom,
    items: []const Item,
};

const IntakeDiagnostic = struct {
    severity: []const u8,
    code: []const u8,
    line: usize,
    column: usize = 1,
    path: []const u8,
    message: []const u8,
    suggested_fix: []const u8 = "",
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
    capabilities,
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
    intake,
    integrate,
    init,
    plan,
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
    session,
    show,
    worktree,
    workspace,
    changeset,
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
    .{ .name = "worktree", .command = .worktree },
    .{ .name = "changeset", .command = .changeset },
    .{ .name = "ready", .command = .ready },
    .{ .name = "blocked", .command = .blocked },
    .{ .name = "capabilities", .command = .capabilities },
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
    .{ .name = "intake", .command = .intake },
    .{ .name = "integrate", .command = .integrate },
    .{ .name = "workspace", .command = .workspace },
    .{ .name = "plan", .command = .plan },
    .{ .name = "session", .command = .session },
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
    intake_command: IntakeCommand = .none,
    debt_command: DebtCommand = .none,
    polish_command: PolishCommand = .none,
    aperture_command: ApertureCommand = .none,
    compile_command: CompileCommand = .none,
    proof_command: ProofCommand = .none,
    claim_command: ClaimCommand = .grant,
    workspace_command: WorkspaceCommand = .none,
    plan_command: PlanCommand = .none,
    session_command: SessionCommand = .none,
    worktree_command: WorktreeCommand = .none,
    changeset_command: ChangesetCommand = .none,
    integrate_command: IntegrateCommand = .none,
    gate: AuditGate = .draft,
    file: []const u8 = ".step/st-plan.jsonl",
    file_explicit: bool = false,
    workspace: []const u8 = ".ledger/st",
    workspace_explicit: bool = false,
    workspace_from_env: bool = false,
    plan_id: ?[]const u8 = null,
    plan_from_env: bool = false,
    workspace_plan_resolved: bool = false,
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
    obligation_id: ?[]const u8 = null,
    action_id: ?[]const u8 = null,
    evidence_ref: ?[]const u8 = null,
    artifact_ref: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    now: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    claim_id: ?[]const u8 = null,
    fencing_token: ?[]const u8 = null,
    worktree_path: ?[]const u8 = null,
    expect_workspace_seq: ?[]const u8 = null,
    expect_plan_seq: ?[]const u8 = null,
    expect_branch_epoch: ?[]const u8 = null,
    resources: []const u8 = "",
    guard_root: ?[]const u8 = null,
    id_prefix: []const u8 = "st",
    start_at: ?[]const u8 = null,
    name: ?[]const u8 = null,
    from_ref: ?[]const u8 = null,
    to_ref: ?[]const u8 = null,
    link_type: []const u8 = "hard",
    pass_number: ?[]const u8 = null,
    min_stable_passes: usize = 2,
    strategy: []const u8 = "aperture-score",

    replace: bool = false,
    repair_seq: bool = false,
    output: ?[]const u8 = null,
    input: ?[]const u8 = null,
    source: ?[]const u8 = null,
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

fn dupFd(fd: std.posix.fd_t) !std.posix.fd_t {
    while (true) {
        const rc = std.posix.system.dup(fd);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return error.BadFileDescriptor,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn dup2Fd(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !void {
    try std.Io.Threaded.dup2(old_fd, new_fd);
}

fn silenceStdout() !StdoutGuard {
    const saved_fd = try dupFd(std.posix.STDOUT_FILENO);
    errdefer std.Io.Threaded.closeFd(saved_fd);

    const devnull = try std.Io.Dir.openFileAbsolute(std.Io.Threaded.global_single_threaded.io(), "/dev/null", .{ .mode = .write_only });
    errdefer devnull.close(std.Io.Threaded.global_single_threaded.io());

    try dup2Fd(devnull.handle, std.posix.STDOUT_FILENO);
    return .{ .saved_fd = saved_fd, .devnull = devnull };
}

fn restoreStdout(guard: StdoutGuard) void {
    dup2Fd(guard.saved_fd, std.posix.STDOUT_FILENO) catch {};
    std.Io.Threaded.closeFd(guard.saved_fd);
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

    if (commandHelpTextForArgv(argv)) |help_text| {
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
        const stdout = &stdout_writer.interface;
        try core_cli.printHelpWithVersion(stdout, help_text, Version);
        return;
    }

    var args = parseArgs(argv) catch |err| {
        return exitWithError(err);
    };
    var resolved_workspace_plan_file: ?[]u8 = null;
    defer if (resolved_workspace_plan_file) |path| allocator.free(path);
    try resolveWorkspacePlanArgsInPlace(allocator, &args, &resolved_workspace_plan_file);

    const mutating = isMutatingCommand(args.command) or
        (args.command == .graph and args.graph_command == .apply and !args.dry_run) or
        (args.command == .graph and args.graph_command == .debt and (args.debt_command == .waive or args.debt_command == .resolve)) or
        (args.command == .intake and args.intake_command == .apply) or
        (args.command == .aperture and args.aperture_command == .select) or
        (args.command == .workspace and (args.workspace_command == .init or args.workspace_command == .migrate or args.workspace_command == .import)) or
        (args.command == .plan and args.plan_command != .list and args.plan_command != .show) or
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

fn commandHelpTextForArgv(argv: []const []const u8) ?[]const u8 {
    if (argv.len < 3 or !hasHelpArgFrom(argv, 2)) return null;
    const command = parseCommand(argv[1]) orelse return null;
    return switch (command) {
        .graph => graphHelpTextForArgv(argv),
        .intake => intakeHelpTextForArgv(argv),
        .aperture => apertureHelpTextForArgv(argv),
        .compile => compileHelpTextForArgv(argv),
        .proof => proofHelpTextForArgv(argv),
        .workspace => workspaceHelpTextForArgv(argv),
        .plan => planHelpTextForArgv(argv),
        .session => SessionHelpText,
        else => commandHelpText(command),
    };
}

fn hasHelpArgFrom(argv: []const []const u8, start: usize) bool {
    var i = start;
    while (i < argv.len) : (i += 1) {
        if (core_cli.isHelpArg(argv[i])) return true;
    }
    return false;
}

fn commandHelpText(command: Command) []const u8 {
    return switch (command) {
        .init => InitHelpText,
        .add => AddHelpText,
        .select => SelectHelpText,
        .deselect => DeselectHelpText,
        .set_status => SetStatusHelpText,
        .set_priority => SetPriorityHelpText,
        .set_deps => SetDepsHelpText,
        .set_notes => SetNotesHelpText,
        .add_comment => AddCommentHelpText,
        .remove => RemoveHelpText,
        .show => ShowHelpText,
        .ready => ReadyHelpText,
        .blocked => BlockedHelpText,
        .doctor => DoctorHelpText,
        .prime => PrimeHelpText,
        .assert_projection => AssertProjectionHelpText,
        .reconcile_codex => ReconcileCodexHelpText,
        .import_proposed_plan => ImportProposedPlanHelpText,
        .guard_session_start => GuardSessionStartHelpText,
        .guard_pre_tool_use => GuardPreToolUseHelpText,
        .@"export" => ExportHelpText,
        .import_plan => ImportPlanHelpText,
        .import_orchplan => ImportOrchplanHelpText,
        .claim => ClaimHelpText,
        .worktree => WorktreeHelpText,
        .changeset => ChangesetHelpText,
        .integrate => IntegrateHelpText,
        .heartbeat => HeartbeatHelpText,
        .set_runtime => SetRuntimeHelpText,
        .set_proof => SetProofHelpText,
        .complete => CompleteHelpText,
        .proof => ProofHelpText,
        .release => ReleaseHelpText,
        .reclaim_stale => ReclaimStaleHelpText,
        .import_mesh_results => ImportMeshResultsHelpText,
        .intake => IntakeHelpText,
        .graph => GraphHelpText,
        .aperture => ApertureHelpText,
        .compile => CompileHelpText,
        .capabilities => CapabilitiesHelpText,
        .workspace => WorkspaceHelpText,
        .plan => PlanHelpText,
        .session => SessionHelpText,
    };
}

fn graphHelpTextForArgv(argv: []const []const u8) []const u8 {
    if (argv.len < 4 or core_cli.isHelpArg(argv[2])) return GraphHelpText;
    const graph_command = parseGraphCommand(argv[2]) orelse return GraphHelpText;
    if (graph_command == .polish) return graphPolishHelpTextForArgv(argv);
    return switch (graph_command) {
        .none => GraphHelpText,
        .schema => GraphSchemaHelpText,
        .apply => GraphApplyHelpText,
        .audit => GraphAuditHelpText,
        .insights => GraphInsightsHelpText,
        .polish => GraphPolishHelpText,
        .debt => GraphDebtHelpText,
    };
}

fn graphPolishHelpTextForArgv(argv: []const []const u8) []const u8 {
    if (argv.len < 5 or core_cli.isHelpArg(argv[3])) return GraphPolishHelpText;
    const polish_command = parsePolishCommand(argv[3]) orelse return GraphPolishHelpText;
    return switch (polish_command) {
        .none => GraphPolishHelpText,
        .begin => GraphPolishBeginHelpText,
        .snapshot => GraphPolishSnapshotHelpText,
        .status => GraphPolishStatusHelpText,
        .gate => GraphPolishGateHelpText,
    };
}

fn intakeHelpTextForArgv(argv: []const []const u8) []const u8 {
    if (argv.len < 4 or core_cli.isHelpArg(argv[2])) return IntakeHelpText;
    const intake_command = parseIntakeCommand(argv[2]) orelse return IntakeHelpText;
    return switch (intake_command) {
        .none => IntakeHelpText,
        .plan => IntakePlanHelpText,
        .scaffold => IntakeScaffoldHelpText,
        .check => IntakeCheckHelpText,
        .normalize => IntakeNormalizeHelpText,
        .apply => IntakeApplyHelpText,
    };
}

fn apertureHelpTextForArgv(argv: []const []const u8) []const u8 {
    if (argv.len < 4 or core_cli.isHelpArg(argv[2])) return ApertureHelpText;
    const aperture_command = parseApertureCommand(argv[2]) orelse return ApertureHelpText;
    return switch (aperture_command) {
        .none => ApertureHelpText,
        .next => ApertureNextHelpText,
        .plan => AperturePlanHelpText,
        .select => ApertureSelectHelpText,
        .explain => ApertureExplainHelpText,
    };
}

fn compileHelpTextForArgv(argv: []const []const u8) []const u8 {
    if (argv.len < 4 or core_cli.isHelpArg(argv[2])) return CompileHelpText;
    const compile_command = parseCompileCommand(argv[2]) orelse return CompileHelpText;
    return switch (compile_command) {
        .none => CompileHelpText,
        .intent => CompileIntentHelpText,
        .graph => CompileGraphHelpText,
        .ready => CompileReadyHelpText,
        .aperture => CompileApertureHelpText,
    };
}

fn proofHelpTextForArgv(argv: []const []const u8) []const u8 {
    if (argv.len < 4 or core_cli.isHelpArg(argv[2])) return ProofHelpText;
    const proof_command = parseProofCommand(argv[2]) orelse return ProofHelpText;
    return switch (proof_command) {
        .none => ProofHelpText,
        .audit => ProofAuditHelpText,
        .plan => ProofPlanHelpText,
        .record => ProofRecordHelpText,
    };
}

fn workspaceHelpTextForArgv(argv: []const []const u8) []const u8 {
    if (argv.len < 4 or core_cli.isHelpArg(argv[2])) return WorkspaceHelpText;
    const workspace_command = parseWorkspaceCommand(argv[2]) orelse return WorkspaceHelpText;
    return switch (workspace_command) {
        .none => WorkspaceHelpText,
        .aperture => WorkspaceApertureHelpText,
        .audit, .doctor, .recover, .@"export", .import => WorkspaceAdminHelpText,
        .init => WorkspaceInitHelpText,
        .migrate => WorkspaceMigrateHelpText,
        .status => WorkspaceStatusHelpText,
    };
}

fn planHelpTextForArgv(argv: []const []const u8) []const u8 {
    if (argv.len < 4 or core_cli.isHelpArg(argv[2])) return PlanHelpText;
    const plan_command = parsePlanCommand(argv[2]) orelse return PlanHelpText;
    return switch (plan_command) {
        .none => PlanHelpText,
        .create => PlanCreateHelpText,
        .list => PlanListHelpText,
        .show => PlanShowHelpText,
        .pause, .@"resume", .complete, .archive => PlanLifecycleHelpText,
        .link => PlanLinkHelpText,
        .unlink => PlanUnlinkHelpText,
    };
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
        if (args.graph_command == .debt) {
            if (argv.len < 4) return error.MissingCommand;
            args.debt_command = parseDebtCommand(argv[3]) orelse return error.UnknownCommand;
            i = 4;
        }
    }
    if (args.command == .intake) {
        if (argv.len < 3) return error.MissingCommand;
        args.intake_command = parseIntakeCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
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
    if (args.command == .claim) {
        if (argv.len >= 3) {
            if (parseClaimCommand(argv[2])) |claim_command| {
                args.claim_command = claim_command;
                i = 3;
            }
        }
    }
    if (args.command == .workspace) {
        if (argv.len < 3) return error.MissingCommand;
        args.workspace_command = parseWorkspaceCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
    }
    if (args.command == .plan) {
        if (argv.len < 3) return error.MissingCommand;
        args.plan_command = parsePlanCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
    }
    if (args.command == .session) {
        if (argv.len < 3) return error.MissingCommand;
        args.session_command = parseSessionCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
    }
    if (args.command == .worktree) {
        if (argv.len < 3) return error.MissingCommand;
        args.worktree_command = parseWorktreeCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
    }
    if (args.command == .changeset) {
        if (argv.len < 3) return error.MissingCommand;
        args.changeset_command = parseChangesetCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
    }
    if (args.command == .integrate) {
        if (argv.len < 3) return error.MissingCommand;
        args.integrate_command = parseIntegrateCommand(argv[2]) orelse return error.UnknownCommand;
        i = 3;
    }
    while (i < argv.len) : (i += 1) {
        const token = argv[i];

        if (std.mem.eql(u8, token, "--file")) {
            i += 1;
            if (i >= argv.len) return error.MissingFileValue;
            args.file = argv[i];
            args.file_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--workspace")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.workspace = argv[i];
            args.workspace_explicit = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--plan") or std.mem.eql(u8, token, "--plan-id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.plan_id = argv[i];
            args.plan_from_env = false;
            continue;
        }
        if (std.mem.eql(u8, token, "--session")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.session_id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--claim") or std.mem.eql(u8, token, "--claim-id")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.claim_id = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--fencing-token")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.fencing_token = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--expect-workspace-seq")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.expect_workspace_seq = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--expect-plan-seq")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.expect_plan_seq = argv[i];
            continue;
        }
        if (std.mem.eql(u8, token, "--expect-branch-epoch")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            args.expect_branch_epoch = argv[i];
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
            .show => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                return error.InvalidListArg;
            },
            .ready, .blocked, .capabilities => {
                return error.InvalidListArg;
            },
            .workspace => {
                if (std.mem.eql(u8, token, "--replace")) {
                    args.replace = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--input")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingInputValue;
                    args.input = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--output")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingOutputValue;
                    args.output = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--from")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.from_ref = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--to")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.to_ref = argv[i];
                    args.workspace = argv[i];
                    args.workspace_explicit = true;
                    continue;
                }
                return error.InvalidWorkspaceArg;
            },
            .plan => {
                if (std.mem.eql(u8, token, "--alias")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.name = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--from")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.from_ref = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--to")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.to_ref = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--type")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.link_type = argv[i];
                    continue;
                }
                return error.InvalidPlanArg;
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
                return error.InvalidGraphArg;
            },
            .intake => {
                if (std.mem.eql(u8, token, "--source")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.source = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--out")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingOutputValue;
                    args.output = argv[i];
                    continue;
                }
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
                return error.InvalidImportArg;
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
                if (std.mem.eql(u8, token, "--preview")) {
                    args.preview = true;
                    continue;
                }
                if (std.mem.eql(u8, token, "--parallelism") and args.compile_command == .aperture) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    if (!std.mem.eql(u8, argv[i], "auto")) return error.InvalidCompileArg;
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
                if (std.mem.eql(u8, token, "--resources")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.resources = argv[i];
                    continue;
                }
                return error.InvalidClaimArg;
            },
            .session => {
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
                return error.InvalidSessionArg;
            },
            .worktree => {
                if (std.mem.eql(u8, token, "--output")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingOutputValue;
                    args.output = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--source")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.source = argv[i];
                    continue;
                }
                return error.InvalidWorktreeArg;
            },
            .changeset => {
                if (std.mem.eql(u8, token, "--worktree")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.worktree_path = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--from")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.from_ref = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--to")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.to_ref = argv[i];
                    continue;
                }
                return error.InvalidChangesetArg;
            },
            .integrate => {
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--source")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.source = argv[i];
                    continue;
                }
                return error.InvalidIntegrationArg;
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
                if (std.mem.eql(u8, token, "--proof-id")) {
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
                if (std.mem.eql(u8, token, "--now")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.now = argv[i];
                    continue;
                }
                return error.InvalidSetProofArg;
            },
            .complete => {
                if (!std.mem.startsWith(u8, token, "--") and args.id == null) {
                    args.id = token;
                    continue;
                }
                if (std.mem.eql(u8, token, "--id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingIdValue;
                    args.id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--proof")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.evidence_ref = argv[i];
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
                if (std.mem.eql(u8, token, "--proof-id")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.proof_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--now")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.now = argv[i];
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
                if (std.mem.eql(u8, token, "--obligation")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.obligation_id = argv[i];
                    continue;
                }
                if (std.mem.eql(u8, token, "--action")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.action_id = argv[i];
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
                if (std.mem.eql(u8, token, "--artifact-ref")) {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    args.artifact_ref = argv[i];
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

    applyWorkspaceEnvDefaults(&args);

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
            if (args.claim_command == .grant and !workspaceModeRequested(args)) {
                if (args.executor == null) return error.MissingValue;
                if (args.wave == null and std.mem.trim(u8, args.ids, " \t\r\n").len == 0) {
                    return error.MissingIdsValue;
                }
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
        .proof => {
            if (args.proof_command == .audit and args.id == null) return error.MissingIdValue;
            if (args.proof_command == .record) {
                if (args.id == null) return error.MissingIdValue;
                if (args.obligation_id == null) return error.MissingValue;
                if (args.action_id == null) return error.MissingValue;
                if (args.step == null) return error.MissingValue;
                if (args.evidence_ref == null) return error.MissingValue;
            }
        },
        .release => if (args.id == null) return error.MissingIdValue,
        .import_mesh_results => if (args.input == null) return error.MissingInputValue,
        .graph => {
            if (args.graph_command == .apply and args.input == null) return error.MissingInputValue;
            if (args.graph_command == .polish and args.polish_command == .begin and args.name == null) return error.MissingValue;
            if (args.graph_command == .polish and args.polish_command == .snapshot and args.pass_number == null) return error.MissingValue;
            if (args.graph_command == .debt and (args.debt_command == .waive or args.debt_command == .resolve) and args.id == null) return error.MissingIdValue;
            if (args.graph_command == .debt and args.debt_command == .waive and args.reason == null) return error.MissingReason;
        },
        .workspace => {},
        .plan => {
            if ((args.plan_command == .create or args.plan_command == .show) and args.plan_id == null) return error.MissingPlanScope;
        },
        .session => {
            if (args.session_command != .list and args.session_id == null) return error.SessionUnbound;
            if ((args.session_command == .bind or args.session_command == .switch_plan) and args.session_command == .bind and args.executor == null) return error.MissingValue;
        },
        .worktree => {
            if (args.worktree_command == .create) {
                if (args.claim_id == null) return error.ClaimMissing;
                if (args.session_id == null) return error.SessionUnbound;
                if (args.fencing_token == null) return error.FencingTokenStale;
                if (args.output == null) return error.MissingOutputValue;
            }
        },
        .changeset => switch (args.changeset_command) {
            .seal => {
                if (args.claim_id == null) return error.ClaimMissing;
                if (args.session_id == null) return error.SessionUnbound;
                if (args.fencing_token == null) return error.FencingTokenStale;
                if (args.worktree_path == null) return error.MissingValue;
            },
            .show, .reject => if (args.id == null) return error.MissingIdValue,
            .supersede => {
                if (args.id == null) return error.MissingIdValue;
                if (args.to_ref == null) return error.MissingValue;
            },
            .none => return error.MissingCommand,
        },
        .integrate => switch (args.integrate_command) {
            .enqueue, .apply, .reject => if (args.id == null) return error.MissingIdValue,
            .preview => {},
            .status, .recover => {},
            .none => return error.MissingCommand,
        },
        .intake => {
            if ((args.intake_command == .plan or args.intake_command == .scaffold) and args.source == null) return error.MissingValue;
            if ((args.intake_command == .plan or args.intake_command == .scaffold or args.intake_command == .normalize) and args.output == null) return error.MissingOutputValue;
            if ((args.intake_command == .check or args.intake_command == .normalize or args.intake_command == .apply) and args.input == null) return error.MissingInputValue;
            if (args.intake_command == .apply and args.input == null) return error.MissingInputValue;
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
    if (std.mem.eql(u8, raw, "debt")) return .debt;
    return null;
}

fn parseIntakeCommand(raw: []const u8) ?IntakeCommand {
    if (std.mem.eql(u8, raw, "plan")) return .plan;
    if (std.mem.eql(u8, raw, "scaffold")) return .scaffold;
    if (std.mem.eql(u8, raw, "check")) return .check;
    if (std.mem.eql(u8, raw, "normalize")) return .normalize;
    if (std.mem.eql(u8, raw, "apply")) return .apply;
    return null;
}

fn parseDebtCommand(raw: []const u8) ?DebtCommand {
    if (std.mem.eql(u8, raw, "list")) return .list;
    if (std.mem.eql(u8, raw, "waive")) return .waive;
    if (std.mem.eql(u8, raw, "resolve")) return .resolve;
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
    if (std.mem.eql(u8, raw, "plan")) return .plan;
    if (std.mem.eql(u8, raw, "record")) return .record;
    return null;
}

fn parseClaimCommand(raw: []const u8) ?ClaimCommand {
    if (std.mem.eql(u8, raw, "grant")) return .grant;
    if (std.mem.eql(u8, raw, "heartbeat")) return .heartbeat;
    if (std.mem.eql(u8, raw, "show")) return .show;
    if (std.mem.eql(u8, raw, "list")) return .list;
    if (std.mem.eql(u8, raw, "release")) return .release;
    if (std.mem.eql(u8, raw, "reclaim-stale")) return .reclaim_stale;
    if (std.mem.eql(u8, raw, "conflicts")) return .conflicts;
    if (std.mem.eql(u8, raw, "amend")) return .amend;
    return null;
}

fn parseWorkspaceCommand(raw: []const u8) ?WorkspaceCommand {
    if (std.mem.eql(u8, raw, "aperture")) return .aperture;
    if (std.mem.eql(u8, raw, "audit")) return .audit;
    if (std.mem.eql(u8, raw, "doctor")) return .doctor;
    if (std.mem.eql(u8, raw, "export")) return .@"export";
    if (std.mem.eql(u8, raw, "init")) return .init;
    if (std.mem.eql(u8, raw, "import")) return .import;
    if (std.mem.eql(u8, raw, "migrate")) return .migrate;
    if (std.mem.eql(u8, raw, "recover")) return .recover;
    if (std.mem.eql(u8, raw, "status")) return .status;
    return null;
}

fn parsePlanCommand(raw: []const u8) ?PlanCommand {
    if (std.mem.eql(u8, raw, "create")) return .create;
    if (std.mem.eql(u8, raw, "list")) return .list;
    if (std.mem.eql(u8, raw, "show")) return .show;
    if (std.mem.eql(u8, raw, "pause")) return .pause;
    if (std.mem.eql(u8, raw, "resume")) return .@"resume";
    if (std.mem.eql(u8, raw, "complete")) return .complete;
    if (std.mem.eql(u8, raw, "archive")) return .archive;
    if (std.mem.eql(u8, raw, "link")) return .link;
    if (std.mem.eql(u8, raw, "unlink")) return .unlink;
    return null;
}

fn parseSessionCommand(raw: []const u8) ?SessionCommand {
    if (std.mem.eql(u8, raw, "bind")) return .bind;
    if (std.mem.eql(u8, raw, "show")) return .show;
    if (std.mem.eql(u8, raw, "switch-plan")) return .switch_plan;
    if (std.mem.eql(u8, raw, "release")) return .release;
    if (std.mem.eql(u8, raw, "list")) return .list;
    return null;
}

fn parseWorktreeCommand(raw: []const u8) ?WorktreeCommand {
    if (std.mem.eql(u8, raw, "create")) return .create;
    return null;
}

fn parseChangesetCommand(raw: []const u8) ?ChangesetCommand {
    if (std.mem.eql(u8, raw, "seal")) return .seal;
    if (std.mem.eql(u8, raw, "show")) return .show;
    if (std.mem.eql(u8, raw, "reject")) return .reject;
    if (std.mem.eql(u8, raw, "supersede")) return .supersede;
    return null;
}

fn parseIntegrateCommand(raw: []const u8) ?IntegrateCommand {
    if (std.mem.eql(u8, raw, "enqueue")) return .enqueue;
    if (std.mem.eql(u8, raw, "status")) return .status;
    if (std.mem.eql(u8, raw, "preview")) return .preview;
    if (std.mem.eql(u8, raw, "apply")) return .apply;
    if (std.mem.eql(u8, raw, "reject")) return .reject;
    if (std.mem.eql(u8, raw, "recover")) return .recover;
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
        .session,
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
    var resolved_args = args;
    var resolved_workspace_plan_file: ?[]u8 = null;
    defer if (resolved_workspace_plan_file) |path| allocator.free(path);
    try resolveWorkspacePlanArgsInPlace(allocator, &resolved_args, &resolved_workspace_plan_file);

    return switch (resolved_args.command) {
        .init => try cmdInit(allocator, resolved_args),
        .add => try cmdAdd(allocator, resolved_args),
        .select => try cmdSelect(allocator, resolved_args),
        .deselect => try cmdDeselect(allocator, resolved_args),
        .set_status => try cmdSetStatus(allocator, resolved_args),
        .set_priority => try cmdSetPriority(allocator, resolved_args),
        .set_deps => try cmdSetDeps(allocator, resolved_args),
        .set_notes => try cmdSetNotes(allocator, resolved_args),
        .add_comment => try cmdAddComment(allocator, resolved_args),
        .remove => try cmdRemove(allocator, resolved_args),
        .show => try cmdShow(allocator, resolved_args),
        .ready => try cmdReady(allocator, resolved_args),
        .blocked => try cmdBlocked(allocator, resolved_args),
        .capabilities => try cmdCapabilities(allocator, resolved_args),
        .claim => try cmdClaim(allocator, resolved_args),
        .complete => try cmdComplete(allocator, resolved_args),
        .doctor => try cmdDoctor(allocator, resolved_args),
        .prime => try cmdPrime(allocator, resolved_args),
        .proof => try cmdProof(allocator, resolved_args),
        .assert_projection => try cmdAssertProjection(allocator, resolved_args),
        .guard_session_start => try cmdGuardSessionStart(allocator, resolved_args),
        .guard_pre_tool_use => try cmdGuardPreToolUse(allocator, resolved_args),
        .heartbeat => try cmdHeartbeat(allocator, resolved_args),
        .reconcile_codex => try cmdReconcileCodex(allocator, resolved_args),
        .@"export" => try cmdExport(allocator, resolved_args),
        .import_plan => try cmdImportPlan(allocator, resolved_args),
        .import_orchplan => try cmdImportOrchplan(allocator, resolved_args),
        .import_proposed_plan => try cmdImportProposedPlan(allocator, resolved_args),
        .set_runtime => try cmdSetRuntime(allocator, resolved_args),
        .set_proof => try cmdSetProof(allocator, resolved_args),
        .release => try cmdRelease(allocator, resolved_args),
        .reclaim_stale => try cmdReclaimStale(allocator, resolved_args),
        .import_mesh_results => try cmdImportMeshResults(allocator, resolved_args),
        .intake => try cmdIntake(allocator, resolved_args),
        .graph => try cmdGraph(allocator, resolved_args),
        .aperture => try cmdAperture(allocator, resolved_args),
        .compile => try cmdCompile(allocator, resolved_args),
        .workspace => try cmdWorkspace(allocator, resolved_args),
        .plan => try cmdPlan(allocator, resolved_args),
        .session => try cmdSession(allocator, resolved_args),
        .worktree => try cmdWorktree(allocator, resolved_args),
        .changeset => try cmdChangeset(allocator, resolved_args),
        .integrate => try cmdIntegrate(allocator, resolved_args),
    };
}

pub fn runPerfArgs(allocator: std.mem.Allocator, args: Args) !u8 {
    return runCommand(allocator, args);
}

fn commandUsesWorkspacePlanFile(command: Command) bool {
    return switch (command) {
        .init,
        .workspace,
        .plan,
        .session,
        .worktree,
        .changeset,
        .integrate,
        .capabilities,
        => false,
        else => true,
    };
}

fn applyWorkspaceEnvDefaults(args: *Args) void {
    if (args.file_explicit) return;
    if (!args.workspace_explicit) {
        if (envTrimmed("ST_WORKSPACE")) |workspace| {
            args.workspace = workspace;
            args.workspace_from_env = true;
        }
    }
    if (args.plan_id == null) {
        if (envTrimmed("ST_PLAN")) |plan_id| {
            args.plan_id = plan_id;
            args.plan_from_env = true;
        }
    }
}

fn workspaceModeRequested(args: Args) bool {
    return args.workspace_explicit or args.workspace_from_env or args.plan_id != null;
}

fn resolveWorkspacePlanArgsInPlace(allocator: std.mem.Allocator, args: *Args, owned_file_out: *?[]u8) !void {
    if (args.workspace_plan_resolved) return;
    if (args.command == .claim and (args.claim_command != .grant or workspaceModeRequested(args.*))) return;
    if (!commandUsesWorkspacePlanFile(args.command)) return;
    if (args.file_explicit) {
        if (workspaceModeRequested(args.*)) return error.InvalidPlanScope;
        return;
    }

    const raw_plan_id = args.plan_id orelse blk: {
        if (!workspaceModeRequested(args.*)) return;
        break :blk try inferSingleActiveWorkspacePlanId(allocator, args.workspace);
    };
    defer if (args.plan_id == null) allocator.free(raw_plan_id);
    const plan_file = try resolveWorkspacePlanFile(allocator, args.workspace, raw_plan_id);
    errdefer allocator.free(plan_file);
    args.file = plan_file;
    args.workspace_plan_resolved = true;
    owned_file_out.* = plan_file;
}

fn inferSingleActiveWorkspacePlanId(allocator: std.mem.Allocator, raw_workspace: []const u8) ![]u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, raw_workspace);
    defer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);
    if (!fileExists(workspace_file)) return error.WorkspaceMissing;

    const checkpoint_line = try readLastJsonlLine(allocator, workspace_file);
    defer allocator.free(checkpoint_line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, checkpoint_line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;
    const plans_value = parsed.value.object.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;

    var active_plan_id: ?[]const u8 = null;
    var active_count: usize = 0;
    for (plans_value.array.items) |entry| {
        if (entry != .object) return error.WorkspaceInvalid;
        const state = stringField(entry, "state") orelse return error.WorkspaceInvalid;
        if (!std.mem.eql(u8, state, "active")) continue;
        active_count += 1;
        if (active_count > 1) return error.PlanAmbiguous;
        active_plan_id = stringField(entry, "plan_id") orelse return error.WorkspaceInvalid;
    }
    const plan_id = active_plan_id orelse return error.PlanMissing;
    return allocator.dupe(u8, plan_id);
}

fn resolveWorkspacePlanFile(allocator: std.mem.Allocator, raw_workspace: []const u8, raw_plan_id: []const u8) ![]u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, raw_workspace);
    defer allocator.free(workspace_root);
    const plan_id = try normalizePlanId(allocator, raw_plan_id);
    defer allocator.free(plan_id);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);
    if (!fileExists(workspace_file)) return error.WorkspaceMissing;

    const checkpoint_line = try readLastJsonlLine(allocator, workspace_file);
    defer allocator.free(checkpoint_line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, checkpoint_line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;
    const plans_value = parsed.value.object.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;

    const expected_graph_ref = try workspacePlanGraphRefAlloc(allocator, plan_id);
    defer allocator.free(expected_graph_ref);
    for (plans_value.array.items) |entry| {
        if (entry != .object) return error.WorkspaceInvalid;
        const entry_plan_id = stringField(entry, "plan_id") orelse return error.WorkspaceInvalid;
        if (!std.mem.eql(u8, entry_plan_id, plan_id)) continue;
        const state = stringField(entry, "state") orelse return error.WorkspaceInvalid;
        if (!std.mem.eql(u8, state, "active")) return error.PlanInactive;
        const graph_ref = stringField(entry, "graph_ref") orelse return error.WorkspaceInvalid;
        if (!std.mem.eql(u8, graph_ref, expected_graph_ref)) return error.WorkspaceInvalid;
        const plan_file = try std.fs.path.join(allocator, &.{ workspace_root, graph_ref });
        errdefer allocator.free(plan_file);
        if (!fileExists(plan_file)) return error.PlanMissing;
        return plan_file;
    }
    return error.PlanMissing;
}

const WorkspaceLayoutDirs = [_][]const u8{
    "plans",
    "proof",
    "runtime/sessions",
    "runtime/views",
    "worktrees",
    "changesets",
    "integration/receipts",
    "integration/scratch",
    "transactions",
    "locks",
    "migration",
};

fn cmdWorkspace(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.workspace_command) {
        .aperture => try cmdWorkspaceAperture(allocator, args),
        .audit => try cmdWorkspaceAudit(allocator, args),
        .doctor => try cmdWorkspaceDoctor(allocator, args),
        .@"export" => try cmdWorkspaceExport(allocator, args),
        .init => try cmdWorkspaceInit(allocator, args),
        .import => try cmdWorkspaceImport(allocator, args),
        .migrate => try cmdWorkspaceMigrate(allocator, args),
        .recover => try cmdWorkspaceRecover(allocator, args),
        .status => try cmdWorkspaceStatus(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdWorkspaceInit(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);

    try durable_store.ensureDirectoryPathNoSymlinks(workspace_root);
    for (WorkspaceLayoutDirs) |dir| {
        const path = try std.fs.path.join(allocator, &.{ workspace_root, dir });
        defer allocator.free(path);
        try durable_store.ensureDirectoryPathNoSymlinks(path);
    }

    const now = try nowUtcAlloc(allocator);
    const workspace_json = try jsonStringAlloc(allocator, workspace_root);
    defer allocator.free(workspace_json);
    const now_json = try jsonStringAlloc(allocator, now);
    defer allocator.free(now_json);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"lane\":\"checkpoint\",\"schema\":\"STW-v1\",\"workspace_sequence\":1,\"artifact_root\":\".ledger\",\"st_root\":{s},\"created_at\":{s},\"updated_at\":{s},\"target_branch\":null,\"target_head\":null,\"branch_epoch\":0,\"plans\":[],\"cross_plan_edges\":[],\"claims\":[],\"fencing_counter\":0,\"policy\":{{\"fail_closed\":true,\"workspace_v1\":true}}}}\n",
        .{ workspace_json, now_json, now_json },
    );
    defer allocator.free(payload);

    const workspace_exists = fileExists(workspace_file);
    if (!args.replace and workspace_exists) return error.PathAlreadyExists;
    const expected_sequence: i64 = if (workspace_exists) blk: {
        const checkpoint_line = try readLastJsonlLine(allocator, workspace_file);
        defer allocator.free(checkpoint_line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, checkpoint_line, .{});
        defer parsed.deinit();
        break :blk intField(parsed.value, "workspace_sequence") orelse return error.WorkspaceInvalid;
    } else 0;
    var receipt = try publishWorkspaceCheckpointTransaction(
        allocator,
        workspace_root,
        workspace_file,
        payload,
        expected_sequence,
        if (args.replace) "workspace-init-replace" else "workspace-init",
        if (args.replace) .replace else .append,
        args.replace,
    );
    defer receipt.deinit(allocator);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try stdout.writeAll("{\"workspace_init\":{\"ok\":true,\"schema\":\"STW-v1\",\"workspace\":");
        try std.json.Stringify.value(workspace_root, .{}, stdout);
        try stdout.writeAll(",\"workspace_sequence\":1}}\n");
    } else {
        try stdout.print("initialized workspace {s}\n", .{workspace_root});
    }
    return 0;
}

fn cmdWorkspaceStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);

    const exists = fileExists(workspace_file);
    var schema: []const u8 = "";
    var schema_owned: ?[]u8 = null;
    defer if (schema_owned) |owned| allocator.free(owned);
    var sequence: i64 = 0;
    if (exists) {
        const data = try durable_store.readRegularFileNoSymlink(allocator, workspace_file, 1024 * 1024);
        defer allocator.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.WorkspaceInvalid;
            const object = parsed.value.object;
            if (object.get("schema")) |value| {
                if (value == .string) {
                    if (schema_owned) |owned| allocator.free(owned);
                    schema_owned = try allocator.dupe(u8, value.string);
                    schema = schema_owned.?;
                }
            }
            if (object.get("workspace_sequence")) |value| {
                if (value == .integer) sequence = value.integer;
            }
        }
    }

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try stdout.writeAll("{\"workspace_status\":{\"exists\":");
        try stdout.writeAll(if (exists) "true" else "false");
        try stdout.writeAll(",\"workspace\":");
        try std.json.Stringify.value(workspace_root, .{}, stdout);
        try stdout.writeAll(",\"workspace_file\":");
        try std.json.Stringify.value(workspace_file, .{}, stdout);
        try stdout.writeAll(",\"schema\":");
        try std.json.Stringify.value(schema, .{}, stdout);
        try stdout.writeAll(",\"workspace_sequence\":");
        try stdout.print("{d}", .{sequence});
        try stdout.writeAll("}}\n");
    } else if (exists) {
        try stdout.print("workspace {s}: {s} seq {d}\n", .{ workspace_root, schema, sequence });
    } else {
        try stdout.print("workspace missing: {s}\n", .{workspace_root});
    }
    return if (exists) 0 else 2;
}

fn cmdWorkspaceAudit(allocator: std.mem.Allocator, args: Args) !u8 {
    const audit = try workspaceAuditSummary(allocator, args.workspace);
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_audit\":{\"ok\":");
    try stdout.writeAll(if (audit.missing_plan_files == 0) "true" else "false");
    try stdout.writeAll(",\"workspace_sequence\":");
    try stdout.print("{d}", .{workspaceSequence(workspace.parsed.value)});
    try stdout.writeAll(",\"plans\":");
    try stdout.print("{d}", .{audit.plan_count});
    try stdout.writeAll(",\"missing_plan_files\":");
    try stdout.print("{d}", .{audit.missing_plan_files});
    try stdout.writeAll("}}\n");
    return if (audit.missing_plan_files == 0) 0 else 2;
}

fn cmdWorkspaceDoctor(allocator: std.mem.Allocator, args: Args) !u8 {
    const audit = try workspaceAuditSummary(allocator, args.workspace);
    const prepared = try countWorkspacePreparedTransactions(allocator, args.workspace);
    const ok = audit.missing_plan_files == 0 and prepared == 0;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_doctor\":{\"ok\":");
    try stdout.writeAll(if (ok) "true" else "false");
    try stdout.writeAll(",\"plans\":");
    try stdout.print("{d}", .{audit.plan_count});
    try stdout.writeAll(",\"missing_plan_files\":");
    try stdout.print("{d}", .{audit.missing_plan_files});
    try stdout.writeAll(",\"prepared_transactions\":");
    try stdout.print("{d}", .{prepared});
    try stdout.writeAll(",\"recovery_required\":");
    try stdout.writeAll(if (prepared == 0) "false" else "true");
    try stdout.writeAll("}}\n");
    return if (ok) 0 else 2;
}

const WorkspaceAuditSummary = struct {
    plan_count: usize,
    missing_plan_files: usize,
};

fn workspaceAuditSummary(allocator: std.mem.Allocator, raw_workspace: []const u8) !WorkspaceAuditSummary {
    const workspace = try loadWorkspaceCheckpoint(allocator, raw_workspace);
    defer workspace.deinit();
    const workspace_obj = switch (workspace.parsed.value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const plans_value = workspace_obj.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    var missing: usize = 0;
    for (plans_value.array.items) |entry| {
        if (entry != .object) return error.WorkspaceInvalid;
        const graph_ref = stringField(entry, "graph_ref") orelse return error.WorkspaceInvalid;
        const plan_path = try std.fs.path.join(allocator, &.{ workspace.root, graph_ref });
        defer allocator.free(plan_path);
        if (!fileExists(plan_path)) missing += 1;
    }
    return .{
        .plan_count = plans_value.array.items.len,
        .missing_plan_files = missing,
    };
}

fn cmdWorkspaceRecover(allocator: std.mem.Allocator, args: Args) !u8 {
    const prepared = try countWorkspacePreparedTransactions(allocator, args.workspace);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_recover\":{\"ok\":");
    try stdout.writeAll(if (prepared == 0) "true" else "false");
    try stdout.writeAll(",\"prepared_transactions\":");
    try stdout.print("{d}", .{prepared});
    try stdout.writeAll(",\"action\":\"inspect-only\"}}\n");
    return if (prepared == 0) 0 else 2;
}

fn countWorkspacePreparedTransactions(allocator: std.mem.Allocator, raw_workspace: []const u8) !usize {
    const workspace_root = try normalizeWorkspacePath(allocator, raw_workspace);
    defer allocator.free(workspace_root);
    const transactions_dir = try workspaceTransactionsDirAlloc(allocator, workspace_root);
    defer allocator.free(transactions_dir);
    var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), transactions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".prepared.json")) continue;
        const prefix = entry.name[0 .. entry.name.len - ".prepared.json".len];
        const commit_name = try std.fmt.allocPrint(allocator, "{s}.commit.json", .{prefix});
        defer allocator.free(commit_name);
        const commit_path = try std.fs.path.join(allocator, &.{ transactions_dir, commit_name });
        defer allocator.free(commit_path);
        if (!fileExists(commit_path)) count += 1;
    }
    return count;
}

fn cmdWorkspaceExport(allocator: std.mem.Allocator, args: Args) !u8 {
    const output_path = args.output orelse return error.MissingOutputValue;
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const workspace_obj = switch (workspace.parsed.value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const plans_value = workspace_obj.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"receipt_version\":\"STW-EXPORT-v1\",\"workspace\":");
    try std.json.Stringify.value(workspace.parsed.value, .{}, writer);
    try writer.writeAll(",\"plans\":[");
    for (plans_value.array.items, 0..) |entry, idx| {
        if (entry != .object) return error.WorkspaceInvalid;
        if (idx != 0) try writer.writeByte(',');
        const plan_id = stringField(entry, "plan_id") orelse return error.WorkspaceInvalid;
        const graph_ref = stringField(entry, "graph_ref") orelse return error.WorkspaceInvalid;
        const plan_path = try std.fs.path.join(allocator, &.{ workspace.root, graph_ref });
        defer allocator.free(plan_path);
        const content = try durable_store.readRegularFileNoSymlink(allocator, plan_path, 64 * 1024 * 1024);
        defer allocator.free(content);
        try writer.writeAll("{\"plan_id\":");
        try std.json.Stringify.value(plan_id, .{}, writer);
        try writer.writeAll(",\"graph_ref\":");
        try std.json.Stringify.value(graph_ref, .{}, writer);
        try writer.writeAll(",\"content\":");
        try std.json.Stringify.value(content, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
    const payload = try out.toOwnedSlice();
    try writeTextAtomic(allocator, output_path, payload);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_export\":{\"ok\":true,\"output\":");
    try std.json.Stringify.value(output_path, .{}, stdout);
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdWorkspaceImport(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input orelse return error.MissingInputValue;
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);
    if (fileExists(workspace_file) and !args.replace) return error.PathAlreadyExists;
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, input_path, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, stringField(parsed.value, "receipt_version") orelse "", "STW-EXPORT-v1")) return error.WorkspaceInvalid;
    const workspace_value = parsed.value.object.get("workspace") orelse return error.WorkspaceInvalid;
    const plans_value = parsed.value.object.get("plans") orelse return error.WorkspaceInvalid;
    if (workspace_value != .object or plans_value != .array) return error.WorkspaceInvalid;
    try durable_store.ensureDirectoryPathNoSymlinks(workspace_root);
    for (WorkspaceLayoutDirs) |dir| {
        const path = try std.fs.path.join(allocator, &.{ workspace_root, dir });
        defer allocator.free(path);
        try durable_store.ensureDirectoryPathNoSymlinks(path);
    }
    for (plans_value.array.items) |entry| {
        if (entry != .object) return error.WorkspaceInvalid;
        const graph_ref = stringField(entry, "graph_ref") orelse return error.WorkspaceInvalid;
        const content = stringField(entry, "content") orelse return error.WorkspaceInvalid;
        const plan_path = try std.fs.path.join(allocator, &.{ workspace_root, graph_ref });
        defer allocator.free(plan_path);
        const plan_dir = std.fs.path.dirname(plan_path) orelse return error.WorkspaceInvalid;
        try durable_store.ensureDirectoryPathNoSymlinks(plan_dir);
        try writeTextAtomic(allocator, plan_path, content);
    }
    var workspace_out: std.Io.Writer.Allocating = .init(allocator);
    defer workspace_out.deinit();
    try std.json.Stringify.value(workspace_value, .{}, &workspace_out.writer);
    try workspace_out.writer.writeByte('\n');
    const workspace_payload = try workspace_out.toOwnedSlice();
    try writeTextAtomic(allocator, workspace_file, workspace_payload);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_import\":{\"ok\":true,\"workspace\":");
    try std.json.Stringify.value(workspace_root, .{}, stdout);
    try stdout.writeAll(",\"plans\":");
    try stdout.print("{d}", .{plans_value.array.items.len});
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdWorkspaceMigrate(allocator: std.mem.Allocator, args: Args) !u8 {
    if (args.file_explicit) return error.InvalidWorkspaceArg;

    const from_path = args.from_ref orelse return error.MissingValue;
    const to_path = args.to_ref orelse args.workspace;
    const plan_id_raw = args.plan_id orelse return error.MissingValue;
    const plan_id = try normalizePlanId(allocator, plan_id_raw);
    defer allocator.free(plan_id);

    const workspace_root = try normalizeWorkspacePath(allocator, to_path);
    defer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);
    const graph_ref = try workspacePlanGraphRefAlloc(allocator, plan_id);
    defer allocator.free(graph_ref);
    const plan_dir = try std.fs.path.join(allocator, &.{ workspace_root, "plans", plan_id });
    defer allocator.free(plan_dir);
    const plan_file = try std.fs.path.join(allocator, &.{ plan_dir, "plan.jsonl" });
    defer allocator.free(plan_file);

    if (!fileExists(from_path)) return error.FileNotFound;

    const legacy_loaded = try loadValidatedState(allocator, from_path, true);
    var legacy_state = legacy_loaded.state;
    defer legacy_state.deinit();

    const legacy_bytes = try durable_store.readRegularFileNoSymlink(allocator, from_path, 64 * 1024 * 1024);
    defer allocator.free(legacy_bytes);
    const migrated_plan = try renderMigratedPlanJsonl(allocator, legacy_bytes, plan_id);
    defer allocator.free(migrated_plan);

    const migrated_records = try parseRecordsFromBytes(allocator, migrated_plan);
    var migrated_state = try materializeStateFromRecords(allocator, migrated_records.records);
    defer migrated_state.deinit();
    try validateState(&migrated_state, true);
    try assertMigrationParity(allocator, &legacy_state, &migrated_state, legacy_loaded.latest_seq, migrated_records.latest_seq);

    const now = try nowUtcAlloc(allocator);
    defer allocator.free(now);
    const source_digest = try hashTextSha256Alloc(allocator, legacy_bytes);
    defer allocator.free(source_digest);
    const migrated_digest = try hashTextSha256Alloc(allocator, migrated_plan);
    defer allocator.free(migrated_digest);

    const workspace_exists = fileExists(workspace_file);
    if (workspace_exists) {
        const checkpoint_line = try readLastJsonlLine(allocator, workspace_file);
        defer allocator.free(checkpoint_line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, checkpoint_line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.WorkspaceInvalid;
        if (!workspaceHasPlanRecord(parsed.value.object, plan_id, graph_ref)) return error.PathAlreadyExists;
        if (!fileExists(plan_file)) return error.WorkspaceInvalid;
        const existing_plan = try durable_store.readRegularFileNoSymlink(allocator, plan_file, 64 * 1024 * 1024);
        defer allocator.free(existing_plan);
        const existing_records = try parseRecordsFromBytes(allocator, existing_plan);
        var existing_state = try materializeStateFromRecords(allocator, existing_records.records);
        defer existing_state.deinit();
        try validateState(&existing_state, true);
        try assertMigrationParity(allocator, &legacy_state, &existing_state, legacy_loaded.latest_seq, existing_records.latest_seq);
        try writeMigrationReceipt(allocator, workspace_root, plan_id, from_path, plan_file, source_digest, migrated_digest, legacy_loaded.latest_seq, workspaceSequence(parsed.value), "idempotent", now);
        try writeWorkspaceMigrateOutput(allocator, args, workspace_root, plan_id, plan_file, workspaceSequence(parsed.value), legacy_loaded.latest_seq, "idempotent");
        return 0;
    }

    try durable_store.ensureDirectoryPathNoSymlinks(workspace_root);
    for (WorkspaceLayoutDirs) |dir| {
        const path = try std.fs.path.join(allocator, &.{ workspace_root, dir });
        defer allocator.free(path);
        try durable_store.ensureDirectoryPathNoSymlinks(path);
    }
    try durable_store.ensureDirectoryPathNoSymlinks(plan_dir);
    try durable_store.writeTextCreateNew(allocator, plan_file, migrated_plan, .{});
    try archiveMigrationSource(allocator, workspace_root, from_path, legacy_bytes);

    const workspace_payload = try renderMigratedWorkspaceCheckpoint(allocator, workspace_root, plan_id, graph_ref, legacy_loaded.latest_seq, legacy_state.graph.fingerprints, now);
    defer allocator.free(workspace_payload);
    var receipt = try publishWorkspaceCheckpointTransaction(
        allocator,
        workspace_root,
        workspace_file,
        workspace_payload,
        0,
        "workspace-migrate",
        .append,
        false,
    );
    defer receipt.deinit(allocator);

    try writeMigrationReceipt(allocator, workspace_root, plan_id, from_path, plan_file, source_digest, migrated_digest, legacy_loaded.latest_seq, 1, "migrated", now);
    try writeWorkspaceMigrateOutput(allocator, args, workspace_root, plan_id, plan_file, 1, legacy_loaded.latest_seq, "migrated");
    return 0;
}

fn workspaceHasPlanRecord(workspace_obj: std.json.ObjectMap, plan_id: []const u8, graph_ref: []const u8) bool {
    const plans_value = workspace_obj.get("plans") orelse return false;
    if (plans_value != .array) return false;
    for (plans_value.array.items) |entry| {
        if (entry != .object) return false;
        const entry_plan_id = stringField(entry, "plan_id") orelse return false;
        if (!std.mem.eql(u8, entry_plan_id, plan_id)) continue;
        const entry_graph_ref = stringField(entry, "graph_ref") orelse return false;
        return std.mem.eql(u8, entry_graph_ref, graph_ref);
    }
    return false;
}

fn writeWorkspaceMigrateOutput(
    allocator: std.mem.Allocator,
    args: Args,
    workspace_root: []const u8,
    plan_id: []const u8,
    plan_file: []const u8,
    workspace_sequence: i64,
    plan_sequence: i64,
    state: []const u8,
) !void {
    _ = allocator;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try stdout.writeAll("{\"workspace_migrate\":{\"ok\":true,\"state\":");
        try std.json.Stringify.value(state, .{}, stdout);
        try stdout.writeAll(",\"workspace\":");
        try std.json.Stringify.value(workspace_root, .{}, stdout);
        try stdout.writeAll(",\"plan_id\":");
        try std.json.Stringify.value(plan_id, .{}, stdout);
        try stdout.writeAll(",\"plan_file\":");
        try std.json.Stringify.value(plan_file, .{}, stdout);
        try stdout.writeAll(",\"workspace_sequence\":");
        try stdout.print("{d}", .{workspace_sequence});
        try stdout.writeAll(",\"plan_sequence\":");
        try stdout.print("{d}", .{plan_sequence});
        try stdout.writeAll("}}\n");
    } else {
        try stdout.print("workspace migration {s}: {s} -> {s} ({s})\n", .{ state, plan_id, plan_file, workspace_root });
    }
}

fn writeMigrationReceipt(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    plan_id: []const u8,
    source_path: []const u8,
    plan_file: []const u8,
    source_digest: []const u8,
    migrated_digest: []const u8,
    plan_sequence: i64,
    workspace_sequence: i64,
    state: []const u8,
    now: []const u8,
) !void {
    const migration_dir = try std.fs.path.join(allocator, &.{ workspace_root, "migration" });
    defer allocator.free(migration_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(migration_dir);
    const receipt_path = try std.fs.path.join(allocator, &.{ migration_dir, "receipt.json" });
    defer allocator.free(receipt_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"receipt_version\":\"STM-v1\",\"state\":");
    try std.json.Stringify.value(state, .{}, writer);
    try writer.writeAll(",\"plan_id\":");
    try std.json.Stringify.value(plan_id, .{}, writer);
    try writer.writeAll(",\"source_path\":");
    try std.json.Stringify.value(source_path, .{}, writer);
    try writer.writeAll(",\"plan_file\":");
    try std.json.Stringify.value(plan_file, .{}, writer);
    try writer.writeAll(",\"source_digest\":");
    try std.json.Stringify.value(source_digest, .{}, writer);
    try writer.writeAll(",\"migrated_digest\":");
    try std.json.Stringify.value(migrated_digest, .{}, writer);
    try writer.writeAll(",\"plan_sequence\":");
    try writer.print("{d}", .{plan_sequence});
    try writer.writeAll(",\"workspace_sequence\":");
    try writer.print("{d}", .{workspace_sequence});
    try writer.writeAll(",\"parity\":\"pass\",\"created_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll("}\n");
    const payload = try out.toOwnedSlice();
    try writeTextAtomic(allocator, receipt_path, payload);
}

fn archiveMigrationSource(allocator: std.mem.Allocator, workspace_root: []const u8, source_path: []const u8, legacy_bytes: []const u8) !void {
    const source_dir = try std.fs.path.join(allocator, &.{ workspace_root, "migration", "source" });
    defer allocator.free(source_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(source_dir);
    const base = std.fs.path.basename(source_path);
    const safe_base = if (base.len == 0) "st-plan.jsonl" else base;
    const archive_path = try std.fs.path.join(allocator, &.{ source_dir, safe_base });
    defer allocator.free(archive_path);
    if (!fileExists(archive_path)) {
        try durable_store.writeTextCreateNew(allocator, archive_path, legacy_bytes, .{});
    }
}

const CommandRunResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: CommandRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCommandCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !CommandRunResult {
    const process_allocator = std.heap.page_allocator;
    var process_io: std.Io.Threaded = .init(process_allocator, .{});
    defer process_io.deinit();
    const result = try std.process.run(process_allocator, process_io.io(), .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(32 * 1024 * 1024),
        .stderr_limit = .limited(32 * 1024 * 1024),
    });
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => 1,
    };
    return .{
        .exit_code = code,
        .stdout = try allocator.dupe(u8, result.stdout),
        .stderr = try allocator.dupe(u8, result.stderr),
    };
}

fn gitCapture(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);
    const result = try runCommandCapture(allocator, argv.items, cwd);
    defer allocator.free(result.stderr);
    if (result.exit_code != 0) {
        allocator.free(result.stdout);
        return error.GitCommandFailed;
    }
    return result.stdout;
}

fn gitTrimmedAlloc(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    const stdout = try gitCapture(allocator, cwd, args);
    defer allocator.free(stdout);
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return error.GitCommandFailed;
    return allocator.dupe(u8, trimmed);
}

fn absolutePathForPossiblyMissingAlloc(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const trimmed = try requireNonEmptyString(allocator, raw_path, "path");
    defer allocator.free(trimmed);
    if (std.mem.indexOfScalar(u8, trimmed, 0) != null) return error.InvalidPath;
    if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);
    const cwd = try std.process.currentPathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, trimmed });
}

fn pathInsideOrSame(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

fn changesetFilePathAlloc(allocator: std.mem.Allocator, workspace_root: []const u8, changeset_id: []const u8) ![]u8 {
    const safe_id = try normalizeArtifactId(allocator, changeset_id, "--id");
    defer allocator.free(safe_id);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{safe_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ workspace_root, "changesets", file_name });
}

fn changesetPatchPathAlloc(allocator: std.mem.Allocator, workspace_root: []const u8, changeset_id: []const u8) ![]u8 {
    const safe_id = try normalizeArtifactId(allocator, changeset_id, "--id");
    defer allocator.free(safe_id);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.patch", .{safe_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ workspace_root, "changesets", file_name });
}

fn worktreeFilePathAlloc(allocator: std.mem.Allocator, workspace_root: []const u8, claim_id: []const u8) ![]u8 {
    const safe_id = try normalizeArtifactId(allocator, claim_id, "--claim");
    defer allocator.free(safe_id);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{safe_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ workspace_root, "worktrees", file_name });
}

fn normalizeArtifactId(allocator: std.mem.Allocator, raw: []const u8, field: []const u8) ![]const u8 {
    const trimmed = try requireNonEmptyString(allocator, raw, field);
    errdefer allocator.free(trimmed);
    if (trimmed.len > 160) return error.InvalidArtifactId;
    for (trimmed) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
        if (!ok) return error.InvalidArtifactId;
    }
    if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..") or std.mem.indexOf(u8, trimmed, "..") != null) return error.InvalidArtifactId;
    return trimmed;
}

fn cmdWorktree(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.worktree_command) {
        .create => try cmdWorktreeCreate(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdWorktreeCreate(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const workspace_obj = switch (workspace.parsed.value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const claim_id = try requireNonEmptyString(allocator, args.claim_id orelse return error.ClaimMissing, "--claim");
    defer allocator.free(claim_id);
    const session_id = try requireNonEmptyString(allocator, args.session_id orelse return error.SessionUnbound, "--session");
    defer allocator.free(session_id);
    const token = try parseFencingTokenArg(args.fencing_token orelse return error.FencingTokenStale);
    const now = try nowUtcAlloc(allocator);
    _ = try validateWorkspaceClaimAuthority(workspace_obj, claim_id, session_id, token, now);

    const source_repo_raw = args.source orelse ".";
    const repo_root = try gitTrimmedAlloc(allocator, source_repo_raw, &.{ "rev-parse", "--show-toplevel" });
    defer allocator.free(repo_root);
    const repo_common_dir = try gitTrimmedAlloc(allocator, repo_root, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    defer allocator.free(repo_common_dir);
    const target_head = if (stringField(workspace.parsed.value, "target_head")) |head|
        try allocator.dupe(u8, head)
    else
        try gitTrimmedAlloc(allocator, repo_root, &.{ "rev-parse", "HEAD" });
    defer allocator.free(target_head);

    const worktree_path = try absolutePathForPossiblyMissingAlloc(allocator, args.output orelse return error.MissingOutputValue);
    defer allocator.free(worktree_path);
    if (pathInsideOrSame(repo_root, worktree_path)) return error.NestedPrimaryCheckoutWorktree;

    var add_result = try runCommandCapture(allocator, &.{ "git", "-C", repo_root, "worktree", "add", "--detach", worktree_path, target_head }, null);
    defer add_result.deinit(allocator);
    if (add_result.exit_code != 0) return error.GitCommandFailed;

    const worktree_common_dir = try gitTrimmedAlloc(allocator, worktree_path, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    defer allocator.free(worktree_common_dir);
    if (!std.mem.eql(u8, repo_common_dir, worktree_common_dir)) return error.GitCommonDirMismatch;

    const metadata_path = try worktreeFilePathAlloc(allocator, workspace.root, claim_id);
    defer allocator.free(metadata_path);
    const now_json = try jsonStringAlloc(allocator, now);
    defer allocator.free(now_json);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"receipt_version\":\"WT-v1\",\"state\":\"active\",\"claim_id\":");
    try std.json.Stringify.value(claim_id, .{}, writer);
    try writer.writeAll(",\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, writer);
    try writer.writeAll(",\"fencing_token\":");
    try writer.print("{d}", .{token});
    try writer.writeAll(",\"workspace_sequence\":");
    try writer.print("{d}", .{workspaceSequence(workspace.parsed.value)});
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{intField(workspace.parsed.value, "branch_epoch") orelse 0});
    try writer.writeAll(",\"repo_root\":");
    try std.json.Stringify.value(repo_root, .{}, writer);
    try writer.writeAll(",\"worktree_path\":");
    try std.json.Stringify.value(worktree_path, .{}, writer);
    try writer.writeAll(",\"git_common_dir\":");
    try std.json.Stringify.value(repo_common_dir, .{}, writer);
    try writer.writeAll(",\"target_head\":");
    try std.json.Stringify.value(target_head, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try writer.writeAll(now_json);
    try writer.writeAll("}\n");
    const payload = try out.toOwnedSlice();
    try writeTextAtomic(allocator, metadata_path, payload);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"worktree_create\":{\"receipt_version\":\"WT-v1\",\"claim_id\":");
    try std.json.Stringify.value(claim_id, .{}, stdout);
    try stdout.writeAll(",\"worktree_path\":");
    try std.json.Stringify.value(worktree_path, .{}, stdout);
    try stdout.writeAll(",\"target_head\":");
    try std.json.Stringify.value(target_head, .{}, stdout);
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdChangeset(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.changeset_command) {
        .seal => try cmdChangesetSeal(allocator, args),
        .show => try cmdChangesetShow(allocator, args),
        .reject => try cmdChangesetReject(allocator, args),
        .supersede => try cmdChangesetSupersede(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdIntegrate(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.integrate_command) {
        .enqueue => try cmdIntegrateEnqueue(allocator, args),
        .status => try cmdIntegrateStatus(allocator, args),
        .preview => try cmdIntegratePreview(allocator, args),
        .apply => try cmdIntegrateApply(allocator, args),
        .reject => try cmdIntegrateReject(allocator, args),
        .recover => try cmdIntegrateRecover(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdChangesetSeal(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const workspace_obj = switch (workspace.parsed.value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const claim_id = try requireNonEmptyString(allocator, args.claim_id orelse return error.ClaimMissing, "--claim");
    defer allocator.free(claim_id);
    const session_id = try requireNonEmptyString(allocator, args.session_id orelse return error.SessionUnbound, "--session");
    defer allocator.free(session_id);
    const token = try parseFencingTokenArg(args.fencing_token orelse return error.FencingTokenStale);
    const now = try nowUtcAlloc(allocator);
    const claim = try validateWorkspaceClaimAuthority(workspace_obj, claim_id, session_id, token, now);
    const worktree_path = try absolutePathForPossiblyMissingAlloc(allocator, args.worktree_path orelse return error.MissingValue);
    defer allocator.free(worktree_path);
    try validateWorktreeMetadataForClaim(allocator, workspace.root, claim_id, worktree_path);

    const changed_paths = try deriveGitChangedPaths(allocator, worktree_path);
    defer freeStringList(allocator, changed_paths);
    if (changed_paths.len == 0) return error.ChangeSetStale;
    try ensureChangedPathsWithinClaim(claim, changed_paths);

    const patch = try gitCapture(allocator, worktree_path, &.{ "diff", "--binary", "HEAD", "--" });
    defer allocator.free(patch);
    const patch_digest = try hashTextSha256Alloc(allocator, patch);
    defer allocator.free(patch_digest);
    const head = try gitTrimmedAlloc(allocator, worktree_path, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head);
    const tree_digest = try hashChangesetTreeDigest(allocator, head, patch, changed_paths);
    defer allocator.free(tree_digest);
    const changeset_id = if (args.id) |raw|
        try normalizeArtifactId(allocator, raw, "--id")
    else
        try std.fmt.allocPrint(allocator, "cs-{s}-{s}", .{ claim_id, patch_digest["sha256:".len .. "sha256:".len + 12] });
    defer allocator.free(changeset_id);
    if (args.from_ref) |old_id| try ensureChangesetMutable(allocator, workspace.root, old_id);

    const changeset_path = try changesetFilePathAlloc(allocator, workspace.root, changeset_id);
    defer allocator.free(changeset_path);
    if (fileExists(changeset_path)) return error.PathAlreadyExists;
    const patch_path = try changesetPatchPathAlloc(allocator, workspace.root, changeset_id);
    defer allocator.free(patch_path);
    try writeTextAtomic(allocator, patch_path, patch);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeChangesetReceiptJson(&out.writer, .{
        .changeset_id = changeset_id,
        .state = "sealed",
        .claim_id = claim_id,
        .session_id = session_id,
        .fencing_token = token,
        .workspace_sequence = workspaceSequence(workspace.parsed.value),
        .branch_epoch = intField(workspace.parsed.value, "branch_epoch") orelse 0,
        .worktree_path = worktree_path,
        .base_head = head,
        .changed_paths = changed_paths,
        .patch_path = patch_path,
        .patch_digest = patch_digest,
        .tree_digest = tree_digest,
        .created_at = now,
        .supersedes = args.from_ref orelse "",
    });
    const payload = try out.toOwnedSlice();
    try writeTextAtomic(allocator, changeset_path, payload);
    if (args.from_ref) |old_id| try writeChangesetState(allocator, workspace.root, old_id, "superseded", changeset_id, now);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"changeset_seal\":{\"receipt_version\":\"CS-v1\",\"changeset_id\":");
    try std.json.Stringify.value(changeset_id, .{}, stdout);
    try stdout.writeAll(",\"claim_id\":");
    try std.json.Stringify.value(claim_id, .{}, stdout);
    try stdout.writeAll(",\"changed_paths\":");
    try writeJsonStringArray(stdout, changed_paths);
    try stdout.writeAll(",\"patch_digest\":");
    try std.json.Stringify.value(patch_digest, .{}, stdout);
    try stdout.writeAll(",\"tree_digest\":");
    try std.json.Stringify.value(tree_digest, .{}, stdout);
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdChangesetShow(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const changeset_id = try requireNonEmptyString(allocator, args.id orelse return error.MissingIdValue, "--id");
    defer allocator.free(changeset_id);
    const path = try changesetFilePathAlloc(allocator, workspace_root, changeset_id);
    defer allocator.free(path);
    if (!fileExists(path)) return error.ChangeSetStale;
    const data = try durable_store.readRegularFileNoSymlink(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(data);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.writeAll(data);
    return 0;
}

fn cmdChangesetReject(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const id = try requireNonEmptyString(allocator, args.id orelse return error.MissingIdValue, "--id");
    defer allocator.free(id);
    const path = try changesetFilePathAlloc(allocator, workspace_root, id);
    defer allocator.free(path);
    const data = try durable_store.readRegularFileNoSymlink(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const claim_id = stringField(parsed.value, "claim_id") orelse return error.WorkspaceInvalid;
    const worktree_path = stringField(parsed.value, "worktree_path") orelse "";
    const now = try nowUtcAlloc(allocator);
    try writeChangesetState(allocator, workspace_root, id, "rejected", "", now);
    if (worktree_path.len > 0) try markWorktreeRecoveryIfDirty(allocator, workspace_root, claim_id, worktree_path, now);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"changeset_reject\":{\"ok\":true,\"changeset_id\":");
    try std.json.Stringify.value(id, .{}, stdout);
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdChangesetSupersede(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const old_id = try requireNonEmptyString(allocator, args.id orelse return error.MissingIdValue, "--id");
    defer allocator.free(old_id);
    const new_id = try requireNonEmptyString(allocator, args.to_ref orelse return error.MissingValue, "--to");
    defer allocator.free(new_id);
    const new_path = try changesetFilePathAlloc(allocator, workspace_root, new_id);
    defer allocator.free(new_path);
    if (!fileExists(new_path)) return error.ChangeSetStale;
    const now = try nowUtcAlloc(allocator);
    try writeChangesetState(allocator, workspace_root, old_id, "superseded", new_id, now);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"changeset_supersede\":{\"ok\":true,\"old_changeset_id\":");
    try std.json.Stringify.value(old_id, .{}, stdout);
    try stdout.writeAll(",\"new_changeset_id\":");
    try std.json.Stringify.value(new_id, .{}, stdout);
    try stdout.writeAll("}}\n");
    return 0;
}

fn integrationQueuePathAlloc(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ workspace_root, "integration", "queue.jsonl" });
}

fn integrationReceiptPathAlloc(allocator: std.mem.Allocator, workspace_root: []const u8, changeset_id: []const u8) ![]u8 {
    const safe_id = try normalizeArtifactId(allocator, changeset_id, "--id");
    defer allocator.free(safe_id);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{safe_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ workspace_root, "integration", "receipts", file_name });
}

fn integrationConflictPathAlloc(allocator: std.mem.Allocator, workspace_root: []const u8, changeset_id: []const u8) ![]u8 {
    const safe_id = try normalizeArtifactId(allocator, changeset_id, "--id");
    defer allocator.free(safe_id);
    const file_name = try std.fmt.allocPrint(allocator, "{s}-conflict.txt", .{safe_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ workspace_root, "integration", "scratch", file_name });
}

fn integrationScratchWorktreePathAlloc(allocator: std.mem.Allocator, repo_root: []const u8, changeset_id: []const u8) ![]u8 {
    const safe_id = try normalizeArtifactId(allocator, changeset_id, "--id");
    defer allocator.free(safe_id);
    const parent = std.fs.path.dirname(repo_root) orelse return error.InvalidPath;
    const dir_name = try std.fmt.allocPrint(allocator, ".st-integration-{s}", .{safe_id});
    defer allocator.free(dir_name);
    return std.fs.path.join(allocator, &.{ parent, dir_name });
}

fn nextIntegrationQueueSequence(allocator: std.mem.Allocator, queue_path: []const u8) !i64 {
    if (!fileExists(queue_path)) return 1;
    const data = try durable_store.readRegularFileNoSymlink(allocator, queue_path, 16 * 1024 * 1024);
    defer allocator.free(data);
    var max_sequence: i64 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        max_sequence = @max(max_sequence, intField(parsed.value, "enqueue_sequence") orelse 0);
    }
    return max_sequence + 1;
}

fn appendIntegrationQueueEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    changeset_id: []const u8,
    state: []const u8,
    now: []const u8,
    conflict_artifact: []const u8,
) !i64 {
    const queue_path = try integrationQueuePathAlloc(allocator, workspace_root);
    defer allocator.free(queue_path);
    const sequence = try nextIntegrationQueueSequence(allocator, queue_path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"receipt_version\":\"IQE-v1\",\"enqueue_sequence\":");
    try writer.print("{d}", .{sequence});
    try writer.writeAll(",\"changeset_id\":");
    try std.json.Stringify.value(changeset_id, .{}, writer);
    try writer.writeAll(",\"state\":");
    try std.json.Stringify.value(state, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    if (conflict_artifact.len > 0) {
        try writer.writeAll(",\"conflict_artifact\":");
        try std.json.Stringify.value(conflict_artifact, .{}, writer);
    }
    try writer.writeAll("}\n");
    const payload = try out.toOwnedSlice();
    defer allocator.free(payload);
    if (fileExists(queue_path)) {
        try appendTextFile(allocator, queue_path, payload);
    } else {
        try writeTextAtomic(allocator, queue_path, payload);
    }
    return sequence;
}

fn appendTextFile(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    const previous = if (fileExists(path)) try durable_store.readRegularFileNoSymlink(allocator, path, 16 * 1024 * 1024) else try allocator.dupe(u8, "");
    defer allocator.free(previous);
    const payload = try std.fmt.allocPrint(allocator, "{s}{s}", .{ previous, text });
    defer allocator.free(payload);
    try writeTextAtomic(allocator, path, payload);
}

fn loadChangesetJson(allocator: std.mem.Allocator, workspace_root: []const u8, changeset_id: []const u8) !std.json.Parsed(std.json.Value) {
    const path = try changesetFilePathAlloc(allocator, workspace_root, changeset_id);
    defer allocator.free(path);
    if (!fileExists(path)) return error.ChangeSetStale;
    const data = try durable_store.readRegularFileNoSymlink(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(data);
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{});
}

fn changesetChangedPathList(allocator: std.mem.Allocator, changeset: std.json.Value) ![]const []const u8 {
    const changed_paths = switch (changeset) {
        .object => |obj| obj.get("changed_paths") orelse return error.WorkspaceInvalid,
        else => return error.WorkspaceInvalid,
    };
    if (changed_paths != .array) return error.WorkspaceInvalid;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    for (changed_paths.array.items) |entry| {
        const path = asString(entry) orelse return error.WorkspaceInvalid;
        try out.append(allocator, try allocator.dupe(u8, path));
    }
    return out.toOwnedSlice(allocator);
}

fn cmdIntegrateEnqueue(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const changeset_id = try requireNonEmptyString(allocator, args.id orelse return error.MissingIdValue, "--id");
    defer allocator.free(changeset_id);
    var parsed = try loadChangesetJson(allocator, workspace_root, changeset_id);
    defer parsed.deinit();
    const state = stringField(parsed.value, "state") orelse return error.WorkspaceInvalid;
    if (!std.mem.eql(u8, state, "sealed")) return error.ChangeSetStale;
    const now = try nowUtcAlloc(allocator);
    defer allocator.free(now);
    const sequence = try appendIntegrationQueueEvent(allocator, workspace_root, changeset_id, "queued", now, "");

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"integrate_enqueue\":{\"receipt_version\":\"IQE-v1\",\"changeset_id\":");
    try std.json.Stringify.value(changeset_id, .{}, stdout);
    try stdout.writeAll(",\"enqueue_sequence\":");
    try stdout.print("{d}", .{sequence});
    try stdout.writeAll(",\"state\":\"queued\"}}\n");
    return 0;
}

fn cmdIntegrateStatus(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const queue_path = try integrationQueuePathAlloc(allocator, workspace_root);
    defer allocator.free(queue_path);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"integration_status\":{\"entries\":[");
    if (fileExists(queue_path)) {
        const data = try durable_store.readRegularFileNoSymlink(allocator, queue_path, 16 * 1024 * 1024);
        defer allocator.free(data);
        var first = true;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            if (!first) try stdout.writeByte(',');
            try std.json.Stringify.value(parsed.value, .{}, stdout);
            first = false;
        }
    }
    try stdout.writeAll("]}}\n");
    return 0;
}

fn cmdIntegratePreview(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const changeset_id = if (args.id) |id| try requireNonEmptyString(allocator, id, "--id") else try nextQueuedChangesetIdAlloc(allocator, workspace_root);
    defer allocator.free(changeset_id);
    var parsed = try loadChangesetJson(allocator, workspace_root, changeset_id);
    defer parsed.deinit();
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"integration_preview\":{\"changeset\":");
    try std.json.Stringify.value(parsed.value, .{}, stdout);
    try stdout.writeAll("}}\n");
    return 0;
}

fn nextQueuedChangesetIdAlloc(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const queue_path = try integrationQueuePathAlloc(allocator, workspace_root);
    defer allocator.free(queue_path);
    if (!fileExists(queue_path)) return error.ChangeSetStale;
    const data = try durable_store.readRegularFileNoSymlink(allocator, queue_path, 16 * 1024 * 1024);
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, stringField(parsed.value, "state") orelse "", "queued")) continue;
        const id = stringField(parsed.value, "changeset_id") orelse return error.WorkspaceInvalid;
        return allocator.dupe(u8, id);
    }
    return error.ChangeSetStale;
}

fn cmdIntegrateReject(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const changeset_id = try requireNonEmptyString(allocator, args.id orelse return error.MissingIdValue, "--id");
    defer allocator.free(changeset_id);
    const now = try nowUtcAlloc(allocator);
    defer allocator.free(now);
    _ = try appendIntegrationQueueEvent(allocator, workspace_root, changeset_id, "rejected", now, "");
    try writeIntegrationReceipt(allocator, workspace_root, .{
        .changeset_id = changeset_id,
        .state = "rejected",
        .target_branch = "",
        .expected_head = "",
        .new_head = "",
        .branch_epoch_before = 0,
        .branch_epoch_after = 0,
        .changed_paths = &.{},
        .proof_status = "not_run",
        .conflict_artifact = "",
        .created_at = now,
    });
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"integrate_reject\":{\"ok\":true,\"changeset_id\":");
    try std.json.Stringify.value(changeset_id, .{}, stdout);
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdIntegrateRecover(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const scratch_dir = try std.fs.path.join(allocator, &.{ workspace_root, "integration", "scratch" });
    defer allocator.free(scratch_dir);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"integration_recover\":{\"artifacts\":[");
    var emitted = false;
    var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), scratch_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try stdout.writeAll("]}}\n");
            return 0;
        },
        else => return err,
    };
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var it = dir.iterate();
    while (try it.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (emitted) try stdout.writeByte(',');
        try std.json.Stringify.value(entry.name, .{}, stdout);
        emitted = true;
    }
    try stdout.writeAll("]}}\n");
    return 0;
}

const IntegrationReceipt = struct {
    changeset_id: []const u8,
    state: []const u8,
    target_branch: []const u8,
    expected_head: []const u8,
    new_head: []const u8,
    branch_epoch_before: i64,
    branch_epoch_after: i64,
    changed_paths: []const []const u8,
    proof_status: []const u8,
    conflict_artifact: []const u8,
    created_at: []const u8,
};

fn writeIntegrationReceipt(allocator: std.mem.Allocator, workspace_root: []const u8, receipt: IntegrationReceipt) !void {
    const receipt_path = try integrationReceiptPathAlloc(allocator, workspace_root, receipt.changeset_id);
    defer allocator.free(receipt_path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"receipt_version\":\"IGR-v1\",\"changeset_id\":");
    try std.json.Stringify.value(receipt.changeset_id, .{}, writer);
    try writer.writeAll(",\"state\":");
    try std.json.Stringify.value(receipt.state, .{}, writer);
    try writer.writeAll(",\"target_branch\":");
    try std.json.Stringify.value(receipt.target_branch, .{}, writer);
    try writer.writeAll(",\"expected_head\":");
    try std.json.Stringify.value(receipt.expected_head, .{}, writer);
    try writer.writeAll(",\"new_head\":");
    try std.json.Stringify.value(receipt.new_head, .{}, writer);
    try writer.writeAll(",\"branch_epoch_before\":");
    try writer.print("{d}", .{receipt.branch_epoch_before});
    try writer.writeAll(",\"branch_epoch_after\":");
    try writer.print("{d}", .{receipt.branch_epoch_after});
    try writer.writeAll(",\"changed_paths\":");
    try writeJsonStringArray(writer, receipt.changed_paths);
    try writer.writeAll(",\"proof_status\":");
    try std.json.Stringify.value(receipt.proof_status, .{}, writer);
    if (receipt.conflict_artifact.len > 0) {
        try writer.writeAll(",\"conflict_artifact\":");
        try std.json.Stringify.value(receipt.conflict_artifact, .{}, writer);
    }
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(receipt.created_at, .{}, writer);
    try writer.writeAll("}\n");
    const payload = try out.toOwnedSlice();
    try writeTextAtomic(allocator, receipt_path, payload);
}

fn appendProofInvalidationEvents(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_value: std.json.Value,
    changeset_id: []const u8,
    changed_paths: []const []const u8,
    branch_epoch_before: i64,
    branch_epoch_after: i64,
    tree_digest: []const u8,
    now: []const u8,
) !void {
    const workspace_obj = switch (workspace_value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const plans_value = workspace_obj.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    for (plans_value.array.items) |plan_record| {
        if (plan_record != .object) return error.WorkspaceInvalid;
        const plan_id = stringField(plan_record, "plan_id") orelse return error.WorkspaceInvalid;
        const plan_proof_dir = try std.fs.path.join(allocator, &.{ workspace_root, "proof", plan_id });
        defer allocator.free(plan_proof_dir);
        try durable_store.ensureDirectoryPathNoSymlinks(plan_proof_dir);
        const invalidation_path = try std.fs.path.join(allocator, &.{ plan_proof_dir, "invalidations.jsonl" });
        defer allocator.free(invalidation_path);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const writer = &out.writer;
        try writer.writeAll("{\"receipt_version\":\"PINV-v1\",\"changeset_id\":");
        try std.json.Stringify.value(changeset_id, .{}, writer);
        try writer.writeAll(",\"plan_id\":");
        try std.json.Stringify.value(plan_id, .{}, writer);
        try writer.writeAll(",\"branch_epoch_before\":");
        try writer.print("{d}", .{branch_epoch_before});
        try writer.writeAll(",\"branch_epoch_after\":");
        try writer.print("{d}", .{branch_epoch_after});
        try writer.writeAll(",\"tree_digest\":");
        try std.json.Stringify.value(tree_digest, .{}, writer);
        try writer.writeAll(",\"changed_paths\":");
        try writeJsonStringArray(writer, changed_paths);
        try writer.writeAll(",\"changed_resources\":[");
        for (changed_paths, 0..) |path, idx| {
            if (idx != 0) try writer.writeByte(',');
            const resource = try std.fmt.allocPrint(allocator, "path:{s}", .{path});
            defer allocator.free(resource);
            try std.json.Stringify.value(resource, .{}, writer);
        }
        try writer.writeAll("],\"final_proof_stale\":true,\"dependency_cut\":\"changed_resources\",\"created_at\":");
        try std.json.Stringify.value(now, .{}, writer);
        try writer.writeAll("}\n");
        const payload = try out.toOwnedSlice();
        defer allocator.free(payload);
        if (fileExists(invalidation_path)) {
            try appendTextFile(allocator, invalidation_path, payload);
        } else {
            try writeTextAtomic(allocator, invalidation_path, payload);
        }
    }
}

fn cmdIntegrateApply(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    if (workspace.parsed.value != .object) return error.WorkspaceInvalid;
    const branch_epoch = intField(workspace.parsed.value, "branch_epoch") orelse 0;
    if (args.expect_branch_epoch) |raw| {
        if (try parseNonNegativeI64(raw) != branch_epoch) return error.BranchEpochStale;
    }

    const changeset_id = try requireNonEmptyString(allocator, args.id orelse return error.MissingIdValue, "--id");
    defer allocator.free(changeset_id);
    var changeset = try loadChangesetJson(allocator, workspace.root, changeset_id);
    defer changeset.deinit();
    const state = stringField(changeset.value, "state") orelse return error.WorkspaceInvalid;
    if (!std.mem.eql(u8, state, "sealed")) return error.ChangeSetStale;
    const changed_paths = try changesetChangedPathList(allocator, changeset.value);
    defer freeStringList(allocator, changed_paths);

    const repo_source = args.source orelse ".";
    const repo_root = try gitTrimmedAlloc(allocator, repo_source, &.{ "rev-parse", "--show-toplevel" });
    defer allocator.free(repo_root);
    const primary_status = try gitCapture(allocator, repo_root, &.{ "status", "--porcelain=v1", "--untracked-files=no" });
    defer allocator.free(primary_status);
    if (std.mem.trim(u8, primary_status, " \t\r\n").len != 0) return error.IntegrationConflict;

    const target_branch = if (stringField(workspace.parsed.value, "target_branch")) |branch|
        try allocator.dupe(u8, branch)
    else
        try gitTrimmedAlloc(allocator, repo_root, &.{ "branch", "--show-current" });
    defer allocator.free(target_branch);
    const actual_head = try gitTrimmedAlloc(allocator, repo_root, &.{ "rev-parse", target_branch });
    defer allocator.free(actual_head);
    const expected_head = if (stringField(workspace.parsed.value, "target_head")) |head|
        try allocator.dupe(u8, head)
    else
        try allocator.dupe(u8, actual_head);
    defer allocator.free(expected_head);
    if (!std.mem.eql(u8, actual_head, expected_head)) return error.TargetHeadStale;
    if (!std.mem.eql(u8, stringField(changeset.value, "base_head") orelse "", expected_head)) return error.ChangeSetStale;

    const patch_path = if (stringField(changeset.value, "patch_path")) |path|
        try allocator.dupe(u8, path)
    else
        try changesetPatchPathAlloc(allocator, workspace.root, changeset_id);
    defer allocator.free(patch_path);
    const patch = try durable_store.readRegularFileNoSymlink(allocator, patch_path, 32 * 1024 * 1024);
    defer allocator.free(patch);
    const patch_digest = try hashTextSha256Alloc(allocator, patch);
    defer allocator.free(patch_digest);
    if (!std.mem.eql(u8, patch_digest, stringField(changeset.value, "patch_digest") orelse "")) return error.ChangeSetStale;

    const scratch = try integrationScratchWorktreePathAlloc(allocator, repo_root, changeset_id);
    defer allocator.free(scratch);
    var added = try runCommandCapture(allocator, &.{ "git", "-C", repo_root, "worktree", "add", "--detach", scratch, expected_head }, null);
    defer added.deinit(allocator);
    if (added.exit_code != 0) return error.GitCommandFailed;
    const cleanup_scratch = true;
    defer if (cleanup_scratch) {
        var cleanup = runCommandCapture(allocator, &.{ "git", "-C", repo_root, "worktree", "remove", "--force", scratch }, null) catch null;
        if (cleanup) |*result| result.deinit(allocator);
    };

    var check = try runCommandCapture(allocator, &.{ "git", "-C", scratch, "apply", "--check", patch_path }, null);
    defer check.deinit(allocator);
    const now = try nowUtcAlloc(allocator);
    defer allocator.free(now);
    if (check.exit_code != 0) {
        const conflict_path = try integrationConflictPathAlloc(allocator, workspace.root, changeset_id);
        defer allocator.free(conflict_path);
        try writeTextAtomic(allocator, conflict_path, check.stderr);
        _ = try appendIntegrationQueueEvent(allocator, workspace.root, changeset_id, "blocked", now, conflict_path);
        try writeIntegrationReceipt(allocator, workspace.root, .{
            .changeset_id = changeset_id,
            .state = "blocked",
            .target_branch = target_branch,
            .expected_head = expected_head,
            .new_head = "",
            .branch_epoch_before = branch_epoch,
            .branch_epoch_after = branch_epoch,
            .changed_paths = changed_paths,
            .proof_status = "not_run",
            .conflict_artifact = conflict_path,
            .created_at = now,
        });
        return error.IntegrationConflict;
    }

    var apply = try runCommandCapture(allocator, &.{ "git", "-C", scratch, "apply", patch_path }, null);
    defer apply.deinit(allocator);
    if (apply.exit_code != 0) return error.IntegrationConflict;
    var add_args: std.ArrayList([]const u8) = .empty;
    defer add_args.deinit(allocator);
    try add_args.appendSlice(allocator, &.{ "git", "-C", scratch, "add", "--" });
    try add_args.appendSlice(allocator, changed_paths);
    var add_result = try runCommandCapture(allocator, add_args.items, null);
    defer add_result.deinit(allocator);
    if (add_result.exit_code != 0) return error.GitCommandFailed;
    var commit = try runCommandCapture(allocator, &.{ "git", "-C", scratch, "-c", "user.name=st", "-c", "user.email=st@example.com", "commit", "-m", "st integrate changeset" }, null);
    defer commit.deinit(allocator);
    if (commit.exit_code != 0) return error.GitCommandFailed;
    const new_head = try gitTrimmedAlloc(allocator, scratch, &.{ "rev-parse", "HEAD" });
    defer allocator.free(new_head);
    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{target_branch});
    defer allocator.free(ref_name);
    var cas = try runCommandCapture(allocator, &.{ "git", "-C", repo_root, "update-ref", ref_name, new_head, expected_head }, null);
    defer cas.deinit(allocator);
    if (cas.exit_code != 0) return error.TargetHeadStale;
    var reset = try runCommandCapture(allocator, &.{ "git", "-C", repo_root, "reset", "--hard", new_head }, null);
    defer reset.deinit(allocator);
    if (reset.exit_code != 0) return error.GitCommandFailed;

    const workspace_payload = try renderWorkspaceCheckpointWithBranchState(allocator, workspace.root, workspace.parsed.value, target_branch, new_head, branch_epoch + 1, now);
    defer allocator.free(workspace_payload);
    var receipt = try appendWorkspaceCheckpointTransaction(allocator, workspace.root, workspace.file, workspace_payload, workspaceSequence(workspace.parsed.value), "integrate-apply");
    defer receipt.deinit(allocator);
    try writeChangesetState(allocator, workspace.root, changeset_id, "integrated", "", now);
    _ = try appendIntegrationQueueEvent(allocator, workspace.root, changeset_id, "integrated", now, "");
    try writeIntegrationReceipt(allocator, workspace.root, .{
        .changeset_id = changeset_id,
        .state = "integrated",
        .target_branch = target_branch,
        .expected_head = expected_head,
        .new_head = new_head,
        .branch_epoch_before = branch_epoch,
        .branch_epoch_after = branch_epoch + 1,
        .changed_paths = changed_paths,
        .proof_status = "not_declared",
        .conflict_artifact = "",
        .created_at = now,
    });
    try appendProofInvalidationEvents(allocator, workspace.root, workspace.parsed.value, changeset_id, changed_paths, branch_epoch, branch_epoch + 1, new_head, now);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"integrate_apply\":{\"receipt_version\":\"IGR-v1\",\"changeset_id\":");
    try std.json.Stringify.value(changeset_id, .{}, stdout);
    try stdout.writeAll(",\"target_branch\":");
    try std.json.Stringify.value(target_branch, .{}, stdout);
    try stdout.writeAll(",\"expected_head\":");
    try std.json.Stringify.value(expected_head, .{}, stdout);
    try stdout.writeAll(",\"new_head\":");
    try std.json.Stringify.value(new_head, .{}, stdout);
    try stdout.writeAll(",\"branch_epoch\":");
    try stdout.print("{d}", .{branch_epoch + 1});
    try stdout.writeAll("}}\n");
    return 0;
}

fn validateWorktreeMetadataForClaim(allocator: std.mem.Allocator, workspace_root: []const u8, claim_id: []const u8, worktree_path: []const u8) !void {
    const metadata_path = try worktreeFilePathAlloc(allocator, workspace_root, claim_id);
    defer allocator.free(metadata_path);
    if (!fileExists(metadata_path)) return error.WorktreeMissing;
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, metadata_path, 1024 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;
    const recorded_path = stringField(parsed.value, "worktree_path") orelse return error.WorkspaceInvalid;
    if (!std.mem.eql(u8, recorded_path, worktree_path)) return error.WorktreeMismatch;
    const recorded_common = stringField(parsed.value, "git_common_dir") orelse return error.WorkspaceInvalid;
    const current_common = try gitTrimmedAlloc(allocator, worktree_path, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    defer allocator.free(current_common);
    if (!std.mem.eql(u8, recorded_common, current_common)) return error.GitCommonDirMismatch;
}

fn markWorktreeRecoveryIfDirty(allocator: std.mem.Allocator, workspace_root: []const u8, claim_id: []const u8, worktree_path: []const u8, now: []const u8) !void {
    const status_or_null: ?[]u8 = gitCapture(allocator, worktree_path, &.{ "status", "--porcelain=v1" }) catch null;
    const status = status_or_null orelse return;
    defer allocator.free(status);
    if (std.mem.trim(u8, status, " \t\r\n").len == 0) return;

    const metadata_path = try worktreeFilePathAlloc(allocator, workspace_root, claim_id);
    defer allocator.free(metadata_path);
    if (!fileExists(metadata_path)) return error.WorktreeMissing;
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, metadata_path, 1024 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"receipt_version\":\"WT-v1\",\"state\":\"recovery\",\"claim_id\":");
    try std.json.Stringify.value(stringField(parsed.value, "claim_id") orelse claim_id, .{}, writer);
    try writer.writeAll(",\"session_id\":");
    try std.json.Stringify.value(stringField(parsed.value, "session_id") orelse "", .{}, writer);
    try writer.writeAll(",\"fencing_token\":");
    try writer.print("{d}", .{intField(parsed.value, "fencing_token") orelse 0});
    try writer.writeAll(",\"workspace_sequence\":");
    try writer.print("{d}", .{intField(parsed.value, "workspace_sequence") orelse 0});
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{intField(parsed.value, "branch_epoch") orelse 0});
    try writer.writeAll(",\"repo_root\":");
    try std.json.Stringify.value(stringField(parsed.value, "repo_root") orelse "", .{}, writer);
    try writer.writeAll(",\"worktree_path\":");
    try std.json.Stringify.value(stringField(parsed.value, "worktree_path") orelse worktree_path, .{}, writer);
    try writer.writeAll(",\"git_common_dir\":");
    try std.json.Stringify.value(stringField(parsed.value, "git_common_dir") orelse "", .{}, writer);
    try writer.writeAll(",\"target_head\":");
    try std.json.Stringify.value(stringField(parsed.value, "target_head") orelse "", .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(stringField(parsed.value, "created_at") orelse now, .{}, writer);
    try writer.writeAll(",\"recovery_reason\":\"dirty_abandoned_worktree\",\"recovery_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll("}\n");
    const payload = try out.toOwnedSlice();
    try writeTextAtomic(allocator, metadata_path, payload);
}

fn deriveGitChangedPaths(allocator: std.mem.Allocator, worktree_path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    const diff = try gitCapture(allocator, worktree_path, &.{ "diff", "--name-only", "HEAD", "--" });
    defer allocator.free(diff);
    try appendGitPathLines(allocator, &out, diff);
    const untracked = try gitCapture(allocator, worktree_path, &.{ "ls-files", "--others", "--exclude-standard" });
    defer allocator.free(untracked);
    try appendGitPathLines(allocator, &out, untracked);
    return out.toOwnedSlice(allocator);
}

fn appendGitPathLines(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), data: []const u8) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const normalized = try normalizeResourcePath(allocator, line);
        errdefer allocator.free(normalized);
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, normalized)) {
                allocator.free(normalized);
                break;
            }
        } else {
            try out.append(allocator, normalized);
        }
    }
}

fn freeStringList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn ensureChangedPathsWithinClaim(claim: std.json.Value, changed_paths: []const []const u8) !void {
    if (claim != .object) return error.WorkspaceInvalid;
    const resources = claim.object.get("resources") orelse return error.ChangeSetOutsideClaim;
    if (resources != .array) return error.WorkspaceInvalid;
    for (changed_paths) |path| {
        var authorized = false;
        for (resources.array.items) |entry| {
            const resource = try workspaceResourceFromJson(entry);
            if (resourceAuthorizesChangedPath(resource, path)) {
                authorized = true;
                break;
            }
        }
        if (!authorized) return error.ChangeSetOutsideClaim;
    }
}

fn resourceAuthorizesChangedPath(resource: WorkspaceResource, changed_path: []const u8) bool {
    if (resource.mode == .read) return false;
    return switch (resource.kind) {
        .repo_all => true,
        .path, .symbol => std.mem.eql(u8, resource.primary, changed_path) or pathIsAncestor(resource.primary, changed_path),
        else => false,
    };
}

fn hashChangesetTreeDigest(allocator: std.mem.Allocator, head: []const u8, patch: []const u8, paths: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(head);
    try out.writer.writeByte('\n');
    for (paths) |path| {
        try out.writer.writeAll(path);
        try out.writer.writeByte('\n');
    }
    try out.writer.writeAll(patch);
    const payload = try out.toOwnedSlice();
    defer allocator.free(payload);
    return hashTextSha256Alloc(allocator, payload);
}

const ChangesetReceipt = struct {
    changeset_id: []const u8,
    state: []const u8,
    claim_id: []const u8,
    session_id: []const u8,
    fencing_token: u64,
    workspace_sequence: i64,
    branch_epoch: i64,
    worktree_path: []const u8,
    base_head: []const u8,
    changed_paths: []const []const u8,
    patch_path: []const u8 = "",
    patch_digest: []const u8,
    tree_digest: []const u8,
    created_at: []const u8,
    supersedes: []const u8 = "",
    superseded_by: []const u8 = "",
    rejected_at: []const u8 = "",
};

fn writeChangesetReceiptJson(writer: anytype, receipt: ChangesetReceipt) !void {
    try writer.writeAll("{\"receipt_version\":\"CS-v1\",\"changeset_id\":");
    try std.json.Stringify.value(receipt.changeset_id, .{}, writer);
    try writer.writeAll(",\"state\":");
    try std.json.Stringify.value(receipt.state, .{}, writer);
    try writer.writeAll(",\"claim_id\":");
    try std.json.Stringify.value(receipt.claim_id, .{}, writer);
    try writer.writeAll(",\"session_id\":");
    try std.json.Stringify.value(receipt.session_id, .{}, writer);
    try writer.writeAll(",\"fencing_token\":");
    try writer.print("{d}", .{receipt.fencing_token});
    try writer.writeAll(",\"workspace_sequence\":");
    try writer.print("{d}", .{receipt.workspace_sequence});
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{receipt.branch_epoch});
    try writer.writeAll(",\"worktree_path\":");
    try std.json.Stringify.value(receipt.worktree_path, .{}, writer);
    try writer.writeAll(",\"base_head\":");
    try std.json.Stringify.value(receipt.base_head, .{}, writer);
    try writer.writeAll(",\"changed_paths\":");
    try writeJsonStringArray(writer, receipt.changed_paths);
    if (receipt.patch_path.len > 0) {
        try writer.writeAll(",\"patch_path\":");
        try std.json.Stringify.value(receipt.patch_path, .{}, writer);
    }
    try writer.writeAll(",\"patch_digest\":");
    try std.json.Stringify.value(receipt.patch_digest, .{}, writer);
    try writer.writeAll(",\"tree_digest\":");
    try std.json.Stringify.value(receipt.tree_digest, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(receipt.created_at, .{}, writer);
    if (receipt.supersedes.len > 0) {
        try writer.writeAll(",\"supersedes\":");
        try std.json.Stringify.value(receipt.supersedes, .{}, writer);
    }
    if (receipt.superseded_by.len > 0) {
        try writer.writeAll(",\"superseded_by\":");
        try std.json.Stringify.value(receipt.superseded_by, .{}, writer);
    }
    if (receipt.rejected_at.len > 0) {
        try writer.writeAll(",\"rejected_at\":");
        try std.json.Stringify.value(receipt.rejected_at, .{}, writer);
    }
    try writer.writeAll("}\n");
}

fn writeJsonStringArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, idx| {
        if (idx != 0) try writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, writer);
    }
    try writer.writeByte(']');
}

fn ensureChangesetMutable(allocator: std.mem.Allocator, workspace_root: []const u8, id: []const u8) !void {
    const path = try changesetFilePathAlloc(allocator, workspace_root, id);
    defer allocator.free(path);
    if (!fileExists(path)) return error.ChangeSetStale;
    const data = try durable_store.readRegularFileNoSymlink(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const state = stringField(parsed.value, "state") orelse return error.WorkspaceInvalid;
    if (std.mem.eql(u8, state, "integrated") or std.mem.eql(u8, state, "rejected")) return error.ChangeSetStale;
}

fn writeChangesetState(allocator: std.mem.Allocator, workspace_root: []const u8, id: []const u8, state: []const u8, superseded_by: []const u8, now: []const u8) !void {
    const path = try changesetFilePathAlloc(allocator, workspace_root, id);
    defer allocator.free(path);
    if (!fileExists(path)) return error.ChangeSetStale;
    const data = try durable_store.readRegularFileNoSymlink(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;
    const old_state = stringField(parsed.value, "state") orelse return error.WorkspaceInvalid;
    if (std.mem.eql(u8, old_state, "integrated") or std.mem.eql(u8, old_state, "rejected")) return error.ChangeSetStale;
    const changed_paths = parsed.value.object.get("changed_paths") orelse return error.WorkspaceInvalid;
    if (changed_paths != .array) return error.WorkspaceInvalid;
    var path_list: std.ArrayList([]const u8) = .empty;
    defer path_list.deinit(allocator);
    for (changed_paths.array.items) |entry| {
        const path_text = asString(entry) orelse return error.WorkspaceInvalid;
        try path_list.append(allocator, path_text);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeChangesetReceiptJson(&out.writer, .{
        .changeset_id = stringField(parsed.value, "changeset_id") orelse return error.WorkspaceInvalid,
        .state = state,
        .claim_id = stringField(parsed.value, "claim_id") orelse return error.WorkspaceInvalid,
        .session_id = stringField(parsed.value, "session_id") orelse return error.WorkspaceInvalid,
        .fencing_token = @intCast(intField(parsed.value, "fencing_token") orelse return error.WorkspaceInvalid),
        .workspace_sequence = intField(parsed.value, "workspace_sequence") orelse 0,
        .branch_epoch = intField(parsed.value, "branch_epoch") orelse 0,
        .worktree_path = stringField(parsed.value, "worktree_path") orelse "",
        .base_head = stringField(parsed.value, "base_head") orelse "",
        .changed_paths = path_list.items,
        .patch_path = stringField(parsed.value, "patch_path") orelse "",
        .patch_digest = stringField(parsed.value, "patch_digest") orelse return error.WorkspaceInvalid,
        .tree_digest = stringField(parsed.value, "tree_digest") orelse return error.WorkspaceInvalid,
        .created_at = stringField(parsed.value, "created_at") orelse now,
        .supersedes = stringField(parsed.value, "supersedes") orelse "",
        .superseded_by = superseded_by,
        .rejected_at = if (std.mem.eql(u8, state, "rejected")) now else "",
    });
    const payload = try out.toOwnedSlice();
    try writeTextAtomic(allocator, path, payload);
}

const WorkspaceApertureCandidate = struct {
    plan_id: []const u8,
    item_id: []const u8,
    qualified_id: []const u8,
    step: []const u8,
    score: i64,
    fairness_debt: i64 = 0,
    resources: []const WorkspaceResource,
};

const WorkspaceApertureRejected = struct {
    qualified_id: []const u8,
    reason: []const u8,
    conflicting: []const u8 = "",
};

fn cmdWorkspaceAperture(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const workspace_obj = switch (workspace.parsed.value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const plans_value = workspace_obj.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    const edges_value = workspace_obj.get("cross_plan_edges") orelse return error.WorkspaceInvalid;
    if (edges_value != .array) return error.WorkspaceInvalid;

    const now = try nowUtcAlloc(allocator);
    var candidates: std.ArrayList(WorkspaceApertureCandidate) = .empty;
    var rejected: std.ArrayList(WorkspaceApertureRejected) = .empty;

    for (plans_value.array.items) |plan_record| {
        if (plan_record != .object) return error.WorkspaceInvalid;
        const state = stringField(plan_record, "state") orelse return error.WorkspaceInvalid;
        if (!std.mem.eql(u8, state, "active")) continue;
        const plan_id = stringField(plan_record, "plan_id") orelse return error.WorkspaceInvalid;
        const graph_ref = stringField(plan_record, "graph_ref") orelse return error.WorkspaceInvalid;
        const plan_file = try std.fs.path.join(allocator, &.{ workspace.root, graph_ref });
        var loaded = try loadValidatedState(allocator, plan_file, false);
        defer loaded.state.deinit();
        const index = try buildGraphIndex(allocator, &loaded.state);
        const critical_depths = try criticalDepthsAlloc(allocator, &loaded.state, index);

        for (loaded.state.items.items) |item| {
            if (!try isReadyPendingItem(allocator, &loaded.state, item)) continue;
            const qualified = try std.fmt.allocPrint(allocator, "plan://{s}/{s}", .{ plan_id, item.id });
            if (try workspaceHardDependencyBlocker(allocator, workspace.root, plans_value, edges_value, qualified)) |blocker| {
                try rejected.append(allocator, .{
                    .qualified_id = qualified,
                    .reason = "cross_plan_dependency_blocked",
                    .conflicting = blocker,
                });
                continue;
            }
            const resources = try workspaceResourcesForItem(allocator, item);
            if (try workspaceHeldClaimConflict(workspace_obj, resources, now)) |claim_id| {
                try rejected.append(allocator, .{
                    .qualified_id = qualified,
                    .reason = "resource_conflict",
                    .conflicting = claim_id,
                });
                continue;
            }
            try candidates.append(allocator, .{
                .plan_id = plan_id,
                .item_id = item.id,
                .qualified_id = qualified,
                .step = item.step,
                .score = apertureScore(&loaded.state, item, index, critical_depths),
                .resources = resources,
            });
        }
    }

    std.mem.sort(WorkspaceApertureCandidate, candidates.items, {}, workspaceApertureCandidateLessThan);

    var selected: std.ArrayList(WorkspaceApertureCandidate) = .empty;
    for (candidates.items) |candidate| {
        if (selected.items.len >= args.limit) {
            try rejected.append(allocator, .{ .qualified_id = candidate.qualified_id, .reason = "aperture_limit" });
            continue;
        }
        if (workspaceCandidateConflict(candidate, selected.items)) |conflict| {
            try rejected.append(allocator, .{
                .qualified_id = candidate.qualified_id,
                .reason = "resource_conflict",
                .conflicting = conflict,
            });
            continue;
        }
        try selected.append(allocator, candidate);
    }

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try writeWorkspaceApertureJson(stdout, workspace.parsed.value, selected.items, rejected.items, args);
    } else {
        try stdout.print("workspace aperture seq {d} epoch {d}\n", .{ workspaceSequence(workspace.parsed.value), intField(workspace.parsed.value, "branch_epoch") orelse 0 });
        for (selected.items) |candidate| try stdout.print("- {s} ({d}): {s}\n", .{ candidate.qualified_id, candidate.score, candidate.step });
        for (rejected.items) |entry| {
            try stdout.print("rejected {s}: {s}", .{ entry.qualified_id, entry.reason });
            if (entry.conflicting.len > 0) try stdout.print(" ({s})", .{entry.conflicting});
            try stdout.writeByte('\n');
        }
    }
    return 0;
}

fn workspaceApertureCandidateLessThan(_: void, lhs: WorkspaceApertureCandidate, rhs: WorkspaceApertureCandidate) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    if (lhs.fairness_debt != rhs.fairness_debt) return lhs.fairness_debt > rhs.fairness_debt;
    return std.mem.lessThan(u8, lhs.qualified_id, rhs.qualified_id);
}

fn workspaceResourcesForItem(allocator: std.mem.Allocator, item: Item) ![]WorkspaceResource {
    const roots = apertureLockRootsForItem(item);
    if (roots.len == 0) {
        const inferred = try inferUnknownMutationResource(allocator);
        const out = try allocator.alloc(WorkspaceResource, 1);
        out[0] = inferred.resource;
        return out;
    }
    var out: std.ArrayList(WorkspaceResource) = .empty;
    for (roots) |root| {
        const resource = try std.fmt.allocPrint(allocator, "path:{s}", .{root});
        try out.append(allocator, try parseWorkspaceResource(allocator, resource, .write));
    }
    return out.toOwnedSlice(allocator);
}

fn workspaceHardDependencyBlocker(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    plans_value: std.json.Value,
    edges_value: std.json.Value,
    qualified_id: []const u8,
) !?[]const u8 {
    if (edges_value != .array) return error.WorkspaceInvalid;
    for (edges_value.array.items) |entry| {
        if (entry != .object) return error.WorkspaceInvalid;
        if (!std.mem.eql(u8, stringField(entry, "type") orelse "", "hard")) continue;
        if (!std.mem.eql(u8, stringField(entry, "from") orelse "", qualified_id)) continue;
        const target_raw = stringField(entry, "to") orelse return error.WorkspaceInvalid;
        const target = try parseQualifiedRef(allocator, target_raw);
        defer target.deinit(allocator);
        const graph_ref = try workspacePlanGraphRefForId(allocator, plans_value, target.plan_id);
        const plan_file = try std.fs.path.join(allocator, &.{ workspace_root, graph_ref });
        var loaded = try loadValidatedState(allocator, plan_file, false);
        defer loaded.state.deinit();
        const target_item = loaded.state.getConst(target.item_id) orelse return error.UnknownItemId;
        if (target_item.status != .completed) return target_raw;
    }
    return null;
}

fn workspaceHeldClaimConflict(workspace_obj: std.json.ObjectMap, resources: []const WorkspaceResource, now: []const u8) !?[]const u8 {
    const claims = workspace_obj.get("claims") orelse return null;
    if (claims != .array) return error.WorkspaceInvalid;
    for (claims.array.items) |claim| {
        if (!workspaceClaimIsHeldCurrent(claim, now)) continue;
        if (try workspaceClaimConflictsWithResources(claim, resources)) {
            return stringField(claim, "claim_id") orelse return error.WorkspaceInvalid;
        }
    }
    return null;
}

fn workspaceCandidateConflict(candidate: WorkspaceApertureCandidate, selected: []const WorkspaceApertureCandidate) ?[]const u8 {
    for (selected) |held| {
        for (held.resources) |held_resource| {
            for (candidate.resources) |candidate_resource| {
                if (workspaceResourcesConflict(held_resource, candidate_resource)) return held.qualified_id;
            }
        }
    }
    return null;
}

fn writeWorkspaceApertureJson(
    writer: anytype,
    workspace_value: std.json.Value,
    selected: []const WorkspaceApertureCandidate,
    rejected: []const WorkspaceApertureRejected,
    args: Args,
) !void {
    try writer.writeAll("{\"workspace_aperture\":{\"receipt_version\":\"WAP-v1\",\"workspace_sequence\":");
    try writer.print("{d}", .{workspaceSequence(workspace_value)});
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{intField(workspace_value, "branch_epoch") orelse 0});
    try writer.writeAll(",\"allocations\":[");
    for (selected, 0..) |candidate, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"executor\":");
        try std.json.Stringify.value(args.executor orelse "", .{}, writer);
        try writer.writeAll(",\"session_id\":");
        try std.json.Stringify.value(args.session_id orelse "", .{}, writer);
        try writer.writeAll(",\"plan_id\":");
        try std.json.Stringify.value(candidate.plan_id, .{}, writer);
        try writer.writeAll(",\"item_ids\":[");
        try std.json.Stringify.value(candidate.item_id, .{}, writer);
        try writer.writeAll("],\"qualified_item\":");
        try std.json.Stringify.value(candidate.qualified_id, .{}, writer);
        try writer.writeAll(",\"score\":");
        try writer.print("{d}", .{candidate.score});
        try writer.writeAll(",\"fairness_debt\":");
        try writer.print("{d}", .{candidate.fairness_debt});
        try writer.writeAll(",\"resources\":");
        try writeWorkspaceResourcesArray(writer, candidate.resources);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"rejected\":[");
    for (rejected, 0..) |entry, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeAll("{\"qualified_item\":");
        try std.json.Stringify.value(entry.qualified_id, .{}, writer);
        try writer.writeAll(",\"reason\":");
        try std.json.Stringify.value(entry.reason, .{}, writer);
        try writer.writeAll(",\"conflicting_claim_or_candidate\":");
        try std.json.Stringify.value(entry.conflicting, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}}\n");
}

fn cmdPlan(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.plan_command) {
        .create => try cmdPlanCreate(allocator, args),
        .list => try cmdPlanList(allocator, args),
        .show => try cmdPlanShow(allocator, args),
        .pause => try cmdPlanLifecycle(allocator, args, "paused"),
        .@"resume" => try cmdPlanLifecycle(allocator, args, "active"),
        .complete => try cmdPlanLifecycle(allocator, args, "completed"),
        .archive => try cmdPlanLifecycle(allocator, args, "archived"),
        .link => try cmdPlanCrossLink(allocator, args, .link),
        .unlink => try cmdPlanCrossLink(allocator, args, .unlink),
        .none => error.MissingCommand,
    };
}

fn cmdSession(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.session_command) {
        .bind => try cmdSessionBind(allocator, args),
        .show => try cmdSessionShow(allocator, args),
        .switch_plan => try cmdSessionSwitchPlan(allocator, args),
        .release => try cmdSessionRelease(allocator, args),
        .list => try cmdSessionList(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdSessionBind(allocator: std.mem.Allocator, args: Args) !u8 {
    const executor = try normalizeExecutor(allocator, args.executor.?);
    const session_id = try normalizeSessionId(allocator, args.session_id.?);
    defer allocator.free(session_id);
    return writeSessionBinding(allocator, args, session_id, executor, "bound");
}

fn cmdSessionSwitchPlan(allocator: std.mem.Allocator, args: Args) !u8 {
    const session_id = try normalizeSessionId(allocator, args.session_id.?);
    defer allocator.free(session_id);
    const session_path = try workspaceSessionFilePathAlloc(allocator, args.workspace, session_id);
    defer allocator.free(session_path);
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, session_path, 1024 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const state = stringField(parsed.value, "state") orelse return error.SessionUnbound;
    const claim_id = stringField(parsed.value, "claim_id") orelse "";
    if (std.mem.eql(u8, state, "bound") and claim_id.len > 0) return error.SessionPlanMismatch;
    const executor = stringField(parsed.value, "executor") orelse return error.WorkspaceInvalid;
    return writeSessionBinding(allocator, args, session_id, executor, "bound");
}

fn cmdSessionRelease(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const session_id = try normalizeSessionId(allocator, args.session_id.?);
    defer allocator.free(session_id);
    const session_path = try workspaceSessionFilePathAlloc(allocator, args.workspace, session_id);
    defer allocator.free(session_path);
    const bytes = try durable_store.readRegularFileNoSymlink(allocator, session_path, 1024 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const now = try nowUtcAlloc(allocator);
    const payload = try renderSessionRecord(allocator, .{
        .session_id = session_id,
        .executor = stringField(parsed.value, "executor") orelse "",
        .plan_id = stringField(parsed.value, "plan_id") orelse "",
        .claim_id = stringField(parsed.value, "claim_id") orelse "",
        .fencing_token = intField(parsed.value, "fencing_token") orelse 0,
        .workspace_sequence = workspaceSequence(workspace.parsed.value),
        .plan_sequence = intField(parsed.value, "plan_sequence") orelse 0,
        .branch_epoch = intField(workspace.parsed.value, "branch_epoch") orelse 0,
        .state = "released",
        .updated_at = now,
    });
    defer allocator.free(payload);
    try writeTextAtomic(allocator, session_path, payload);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"session_release\":{\"ok\":true,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, stdout);
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdSessionShow(allocator: std.mem.Allocator, args: Args) !u8 {
    const session_id = try normalizeSessionId(allocator, args.session_id.?);
    defer allocator.free(session_id);
    const session_path = try workspaceSessionFilePathAlloc(allocator, args.workspace, session_id);
    defer allocator.free(session_path);
    const view_path = try workspaceViewFilePathAlloc(allocator, args.workspace, session_id);
    defer allocator.free(view_path);
    const session_bytes = try durable_store.readRegularFileNoSymlink(allocator, session_path, 1024 * 1024);
    defer allocator.free(session_bytes);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"session_show\":{\"session\":");
    try stdout.writeAll(session_bytes);
    try stdout.writeAll(",\"view\":");
    if (fileExists(view_path)) {
        const view_bytes = try durable_store.readRegularFileNoSymlink(allocator, view_path, 1024 * 1024);
        defer allocator.free(view_bytes);
        try stdout.writeAll(view_bytes);
    } else {
        try stdout.writeAll("null");
    }
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdSessionList(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const sessions_dir = try std.fs.path.join(allocator, &.{ workspace_root, "runtime", "sessions" });
    defer allocator.free(sessions_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(sessions_dir);

    var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), sessions_dir, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    var iter = dir.iterate();

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"session_list\":{\"sessions\":[");
    var emitted = false;
    while (try iter.next(std.Io.Threaded.global_single_threaded.io())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fs.path.join(allocator, &.{ sessions_dir, entry.name });
        defer allocator.free(path);
        const bytes = try durable_store.readRegularFileNoSymlink(allocator, path, 1024 * 1024);
        defer allocator.free(bytes);
        if (emitted) try stdout.writeByte(',');
        try stdout.writeAll(bytes);
        emitted = true;
    }
    try stdout.writeAll("]}}\n");
    return 0;
}

const SessionRecord = struct {
    session_id: []const u8,
    executor: []const u8,
    plan_id: []const u8,
    claim_id: []const u8,
    fencing_token: i64,
    workspace_sequence: i64,
    plan_sequence: i64,
    branch_epoch: i64,
    state: []const u8,
    updated_at: []const u8,
};

fn writeSessionBinding(allocator: std.mem.Allocator, args: Args, session_id: []const u8, executor: []const u8, state: []const u8) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const workspace_obj = switch (workspace.parsed.value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const plan_id_owned = if (args.plan_id) |raw|
        try normalizePlanId(allocator, raw)
    else
        try inferSingleActiveWorkspacePlanId(allocator, args.workspace);
    defer allocator.free(plan_id_owned);
    const plan_file = try resolveWorkspacePlanFile(allocator, args.workspace, plan_id_owned);
    defer allocator.free(plan_file);
    var plan_state = try loadValidatedState(allocator, plan_file, false);
    defer plan_state.state.deinit();

    const selected_ids = try parseCliIds(allocator, args.ids);
    for (selected_ids) |item_id| {
        if (plan_state.state.getConst(item_id) == null) return error.UnknownItemId;
    }

    const claim_id = args.claim_id orelse "";
    const fencing_token: i64 = if (claim_id.len > 0) blk: {
        const token = try parseFencingTokenArg(args.fencing_token orelse return error.MissingValue);
        const now_for_claim = try nowUtcAlloc(allocator);
        _ = try validateWorkspaceClaimAuthority(workspace_obj, claim_id, session_id, token, now_for_claim);
        break :blk @intCast(token);
    } else 0;

    const plan_sequence = try planSequenceForFile(allocator, plan_file);
    const workspace_sequence = workspaceSequence(workspace.parsed.value);
    const branch_epoch = intField(workspace.parsed.value, "branch_epoch") orelse 0;
    const now = try nowUtcAlloc(allocator);
    const digest_input = try sessionDigestInputAlloc(allocator, session_id, executor, plan_id_owned, claim_id, fencing_token, workspace_sequence, plan_sequence, branch_epoch, selected_ids, args.target);
    defer allocator.free(digest_input);
    const projection_digest = try hashTextSha256Alloc(allocator, digest_input);
    defer allocator.free(projection_digest);

    const session_payload = try renderSessionRecord(allocator, .{
        .session_id = session_id,
        .executor = executor,
        .plan_id = plan_id_owned,
        .claim_id = claim_id,
        .fencing_token = fencing_token,
        .workspace_sequence = workspace_sequence,
        .plan_sequence = plan_sequence,
        .branch_epoch = branch_epoch,
        .state = state,
        .updated_at = now,
    });
    defer allocator.free(session_payload);
    const view_payload = try renderSessionView(allocator, session_id, executor, plan_id_owned, claim_id, fencing_token, workspace_sequence, plan_sequence, branch_epoch, selected_ids, args.target, projection_digest, now);
    defer allocator.free(view_payload);

    const sessions_dir = try std.fs.path.join(allocator, &.{ workspace.root, "runtime", "sessions" });
    defer allocator.free(sessions_dir);
    const views_dir = try std.fs.path.join(allocator, &.{ workspace.root, "runtime", "views" });
    defer allocator.free(views_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(sessions_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(views_dir);
    const session_path = try workspaceSessionFilePathAlloc(allocator, args.workspace, session_id);
    defer allocator.free(session_path);
    const view_path = try workspaceViewFilePathAlloc(allocator, args.workspace, session_id);
    defer allocator.free(view_path);
    try writeTextAtomic(allocator, session_path, session_payload);
    try writeTextAtomic(allocator, view_path, view_payload);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"session_bind\":{\"ok\":true,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, stdout);
    try stdout.writeAll(",\"plan_id\":");
    try std.json.Stringify.value(plan_id_owned, .{}, stdout);
    try stdout.writeAll(",\"projection_digest\":");
    try std.json.Stringify.value(projection_digest, .{}, stdout);
    try stdout.writeAll("}}\n");
    return 0;
}

fn normalizeSessionId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = try requireNonEmptyString(allocator, raw, "--session");
    if (trimmed.len > 128 or std.mem.indexOfScalar(u8, trimmed, 0) != null) return error.InvalidSessionId;
    if (std.mem.indexOfAny(u8, trimmed, "/\\") != null) return error.InvalidSessionId;
    if (std.mem.indexOf(u8, trimmed, "..") != null) return error.InvalidSessionId;
    return allocator.dupe(u8, trimmed);
}

fn workspaceSessionFilePathAlloc(allocator: std.mem.Allocator, raw_workspace: []const u8, session_id: []const u8) ![]u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, raw_workspace);
    defer allocator.free(workspace_root);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{session_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ workspace_root, "runtime", "sessions", file_name });
}

fn workspaceViewFilePathAlloc(allocator: std.mem.Allocator, raw_workspace: []const u8, session_id: []const u8) ![]u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, raw_workspace);
    defer allocator.free(workspace_root);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{session_id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ workspace_root, "runtime", "views", file_name });
}

fn planSequenceForFile(allocator: std.mem.Allocator, plan_file: []const u8) !i64 {
    const line = try readLastJsonlLine(allocator, plan_file);
    defer allocator.free(line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    return intField(parsed.value, "plan_sequence") orelse intField(parsed.value, "seq") orelse 0;
}

fn sessionDigestInputAlloc(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    executor: []const u8,
    plan_id: []const u8,
    claim_id: []const u8,
    fencing_token: i64,
    workspace_sequence: i64,
    plan_sequence: i64,
    branch_epoch: i64,
    selected_ids: []const []const u8,
    target: ProjectionTarget,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("{s}|{s}|{s}|{s}|{d}|{d}|{d}|{d}|{s}|", .{ session_id, executor, plan_id, claim_id, fencing_token, workspace_sequence, plan_sequence, branch_epoch, target.asString() });
    for (selected_ids) |item_id| try writer.print("{s},", .{item_id});
    return out.toOwnedSlice();
}

fn renderSessionRecord(allocator: std.mem.Allocator, record: SessionRecord) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"receipt_version\":\"SES-v1\",\"session_id\":");
    try std.json.Stringify.value(record.session_id, .{}, writer);
    try writer.writeAll(",\"executor\":");
    try std.json.Stringify.value(record.executor, .{}, writer);
    try writer.writeAll(",\"plan_id\":");
    try std.json.Stringify.value(record.plan_id, .{}, writer);
    try writer.writeAll(",\"claim_id\":");
    try std.json.Stringify.value(record.claim_id, .{}, writer);
    try writer.writeAll(",\"fencing_token\":");
    try writer.print("{d}", .{record.fencing_token});
    try writer.writeAll(",\"workspace_sequence\":");
    try writer.print("{d}", .{record.workspace_sequence});
    try writer.writeAll(",\"plan_sequence\":");
    try writer.print("{d}", .{record.plan_sequence});
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{record.branch_epoch});
    try writer.writeAll(",\"state\":");
    try std.json.Stringify.value(record.state, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(record.updated_at, .{}, writer);
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn renderSessionView(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    executor: []const u8,
    plan_id: []const u8,
    claim_id: []const u8,
    fencing_token: i64,
    workspace_sequence: i64,
    plan_sequence: i64,
    branch_epoch: i64,
    selected_ids: []const []const u8,
    target: ProjectionTarget,
    projection_digest: []const u8,
    now: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"receipt_version\":\"SVW-v1\",\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, writer);
    try writer.writeAll(",\"executor\":");
    try std.json.Stringify.value(executor, .{}, writer);
    try writer.writeAll(",\"plan_id\":");
    try std.json.Stringify.value(plan_id, .{}, writer);
    try writer.writeAll(",\"claim_id\":");
    try std.json.Stringify.value(claim_id, .{}, writer);
    try writer.writeAll(",\"fencing_token\":");
    try writer.print("{d}", .{fencing_token});
    try writer.writeAll(",\"workspace_sequence\":");
    try writer.print("{d}", .{workspace_sequence});
    try writer.writeAll(",\"plan_sequence\":");
    try writer.print("{d}", .{plan_sequence});
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{branch_epoch});
    try writer.writeAll(",\"selected_item_ids\":[");
    for (selected_ids, 0..) |item_id, idx| {
        if (idx != 0) try writer.writeByte(',');
        try std.json.Stringify.value(item_id, .{}, writer);
    }
    try writer.writeAll("],\"target\":");
    try std.json.Stringify.value(target.asString(), .{}, writer);
    try writer.writeAll(",\"projection_digest\":");
    try std.json.Stringify.value(projection_digest, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn cmdPlanCreate(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);
    if (!fileExists(workspace_file)) return error.WorkspaceMissing;

    const plan_id = try normalizePlanId(allocator, args.plan_id.?);
    defer allocator.free(plan_id);
    const alias = try requireNonEmptyString(allocator, args.name orelse plan_id, "--alias");
    defer allocator.free(alias);

    const checkpoint_line = try readLastJsonlLine(allocator, workspace_file);
    defer allocator.free(checkpoint_line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, checkpoint_line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;
    const workspace_obj = parsed.value.object;
    const plans_value = workspace_obj.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    for (plans_value.array.items) |entry| {
        if (entry != .object) return error.WorkspaceInvalid;
        const existing_id = stringField(entry, "plan_id") orelse return error.WorkspaceInvalid;
        if (std.mem.eql(u8, existing_id, plan_id)) return error.PlanAlreadyExists;
    }

    const plan_dir = try std.fs.path.join(allocator, &.{ workspace_root, "plans", plan_id });
    defer allocator.free(plan_dir);
    const plan_file = try std.fs.path.join(allocator, &.{ plan_dir, "plan.jsonl" });
    defer allocator.free(plan_file);
    const transactions_dir = try workspaceTransactionsDirAlloc(allocator, workspace_root);
    defer allocator.free(transactions_dir);
    try durable_store.ensureNoPendingTransactions(allocator, transactions_dir);
    try durable_store.ensureDirectoryPathNoSymlinks(plan_dir);

    const now = try nowUtcAlloc(allocator);
    defer allocator.free(now);
    const plan_checkpoint = try renderInitialWorkspacePlanCheckpoint(allocator, plan_id, now);
    defer allocator.free(plan_checkpoint);
    try durable_store.writeTextCreateNew(allocator, plan_file, plan_checkpoint, .{});
    errdefer {
        std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), plan_file) catch {};
        std.Io.Dir.cwd().deleteDir(std.Io.Threaded.global_single_threaded.io(), plan_dir) catch {};
    }

    const workspace_payload = try renderWorkspaceCheckpointWithPlan(allocator, workspace_root, parsed.value, plan_id, alias, now);
    defer allocator.free(workspace_payload);
    var receipt = try appendWorkspaceCheckpointTransaction(
        allocator,
        workspace_root,
        workspace_file,
        workspace_payload,
        intField(parsed.value, "workspace_sequence") orelse 0,
        "plan-create",
    );
    defer receipt.deinit(allocator);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        const graph_ref = try workspacePlanGraphRefAlloc(allocator, plan_id);
        defer allocator.free(graph_ref);
        try stdout.writeAll("{\"plan_create\":{\"ok\":true,\"plan_id\":");
        try std.json.Stringify.value(plan_id, .{}, stdout);
        try stdout.writeAll(",\"graph_ref\":");
        try std.json.Stringify.value(graph_ref, .{}, stdout);
        try stdout.writeAll("}}\n");
    } else {
        try stdout.print("created plan {s}\n", .{plan_id});
    }
    return 0;
}

fn cmdPlanList(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);
    if (!fileExists(workspace_file)) return error.WorkspaceMissing;

    const checkpoint_line = try readLastJsonlLine(allocator, workspace_file);
    defer allocator.free(checkpoint_line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, checkpoint_line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;
    const plans_value = parsed.value.object.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try stdout.writeAll("{\"plan_list\":{\"workspace_sequence\":");
        try stdout.print("{d}", .{intField(parsed.value, "workspace_sequence") orelse 0});
        try stdout.writeAll(",\"plans\":");
        try std.json.Stringify.value(plans_value, .{}, stdout);
        try stdout.writeAll("}}\n");
    } else {
        for (plans_value.array.items) |entry| {
            if (entry != .object) return error.WorkspaceInvalid;
            try stdout.print("{s}\t{s}\n", .{ stringField(entry, "plan_id") orelse "", stringField(entry, "state") orelse "" });
        }
    }
    return 0;
}

fn cmdPlanShow(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);
    if (!fileExists(workspace_file)) return error.WorkspaceMissing;
    const wanted_plan_id = try normalizePlanId(allocator, args.plan_id.?);
    defer allocator.free(wanted_plan_id);

    const checkpoint_line = try readLastJsonlLine(allocator, workspace_file);
    defer allocator.free(checkpoint_line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, checkpoint_line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;
    const plans_value = parsed.value.object.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;

    var match: ?std.json.Value = null;
    for (plans_value.array.items) |entry| {
        if (entry != .object) return error.WorkspaceInvalid;
        const plan_id = stringField(entry, "plan_id") orelse return error.WorkspaceInvalid;
        if (std.mem.eql(u8, plan_id, wanted_plan_id)) {
            match = entry;
            break;
        }
    }
    const plan_record = match orelse return error.PlanMissing;

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try stdout.writeAll("{\"plan_show\":{\"workspace_sequence\":");
        try stdout.print("{d}", .{intField(parsed.value, "workspace_sequence") orelse 0});
        try stdout.writeAll(",\"plan\":");
        try std.json.Stringify.value(plan_record, .{}, stdout);
        try stdout.writeAll("}}\n");
    } else {
        try stdout.print("{s}\t{s}\t{s}\n", .{
            stringField(plan_record, "plan_id") orelse "",
            stringField(plan_record, "state") orelse "",
            stringField(plan_record, "graph_ref") orelse "",
        });
    }
    return 0;
}

fn cmdPlanLifecycle(allocator: std.mem.Allocator, args: Args, target_state: []const u8) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);
    if (!fileExists(workspace_file)) return error.WorkspaceMissing;
    const wanted_plan_id = try normalizePlanId(allocator, args.plan_id.?);
    defer allocator.free(wanted_plan_id);

    const checkpoint_line = try readLastJsonlLine(allocator, workspace_file);
    defer allocator.free(checkpoint_line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, checkpoint_line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;
    const plans_value = parsed.value.object.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;

    var current_state: ?[]const u8 = null;
    for (plans_value.array.items) |entry| {
        if (entry != .object) return error.WorkspaceInvalid;
        const plan_id = stringField(entry, "plan_id") orelse return error.WorkspaceInvalid;
        if (std.mem.eql(u8, plan_id, wanted_plan_id)) {
            current_state = stringField(entry, "state") orelse return error.WorkspaceInvalid;
            break;
        }
    }
    const from_state = current_state orelse return error.PlanMissing;
    if (!planLifecycleTransitionAllowed(from_state, target_state)) return error.InvalidPlanStateTransition;

    const now = try nowUtcAlloc(allocator);
    defer allocator.free(now);
    const workspace_payload = try renderWorkspaceCheckpointWithPlanState(allocator, workspace_root, parsed.value, wanted_plan_id, target_state, now);
    defer allocator.free(workspace_payload);
    var receipt = try appendWorkspaceCheckpointTransaction(
        allocator,
        workspace_root,
        workspace_file,
        workspace_payload,
        intField(parsed.value, "workspace_sequence") orelse 0,
        "plan-lifecycle",
    );
    defer receipt.deinit(allocator);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try stdout.writeAll("{\"plan_lifecycle\":{\"ok\":true,\"plan_id\":");
        try std.json.Stringify.value(wanted_plan_id, .{}, stdout);
        try stdout.writeAll(",\"from\":");
        try std.json.Stringify.value(from_state, .{}, stdout);
        try stdout.writeAll(",\"to\":");
        try std.json.Stringify.value(target_state, .{}, stdout);
        try stdout.writeAll(",\"workspace_sequence\":");
        try stdout.print("{d}", .{(intField(parsed.value, "workspace_sequence") orelse 0) + 1});
        try stdout.writeAll("}}\n");
    } else {
        try stdout.print("updated plan {s}: {s} -> {s}\n", .{ wanted_plan_id, from_state, target_state });
    }
    return 0;
}

const CrossPlanEdgeOp = enum {
    link,
    unlink,
};

const QualifiedRef = struct {
    plan_id: []const u8,
    item_id: []const u8,
    canonical: []const u8,

    fn deinit(self: QualifiedRef, allocator: std.mem.Allocator) void {
        allocator.free(self.plan_id);
        allocator.free(self.item_id);
        allocator.free(self.canonical);
    }
};

const CrossPlanEdge = struct {
    from: []const u8,
    to: []const u8,
    edge_type: []const u8,
};

const WorkspaceResourceKind = enum {
    path,
    symbol,
    generated,
    schema,
    service,
    git_index,
    git_branch,
    repo_all,
};

const WorkspaceResourceMode = enum {
    read,
    write,
    exclusive,
};

const WorkspaceResource = struct {
    kind: WorkspaceResourceKind,
    mode: WorkspaceResourceMode,
    primary: []const u8,
    secondary: []const u8 = "",

    fn deinit(self: WorkspaceResource, allocator: std.mem.Allocator) void {
        allocator.free(self.primary);
        if (self.secondary.len != 0) allocator.free(self.secondary);
    }
};

const InferredWorkspaceResource = struct {
    resource: WorkspaceResource,
    confidence: []const u8,
};

const WorkspaceClaimDraft = struct {
    claim_id: []const u8,
    state: []const u8,
    owner: []const u8,
    executor: []const u8,
    session_id: []const u8,
    plan_id: []const u8 = "",
    item_ids: []const []const u8 = &.{},
    resources: []const WorkspaceResource = &.{},
    fencing_token: u64,
    claimed_at: []const u8,
    lease_seconds: i64,
    lease_expires_at: []const u8,
    heartbeat_at: []const u8,
    released_at: []const u8 = "",
    stale_at: []const u8 = "",
    supersedes: []const u8 = "",
};

fn cmdWorkspaceClaim(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.claim_command) {
        .grant => try cmdWorkspaceClaimGrant(allocator, args),
        .heartbeat => try cmdWorkspaceClaimHeartbeat(allocator, args),
        .show => try cmdWorkspaceClaimShow(allocator, args),
        .list => try cmdWorkspaceClaimList(allocator, args),
        .release => try cmdWorkspaceClaimRelease(allocator, args),
        .reclaim_stale => try cmdWorkspaceClaimReclaimStale(allocator, args),
        .conflicts => try cmdWorkspaceClaimConflicts(allocator, args),
        .amend => try cmdWorkspaceClaimAmend(allocator, args),
    };
}

fn cmdWorkspaceClaimGrant(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const workspace_root = workspace.root;
    const workspace_file = workspace.file;
    const previous = workspace.parsed.value;
    const previous_obj = switch (previous) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };

    const now = try nowUtcAlloc(allocator);
    const resources = try parseWorkspaceClaimResources(allocator, args.resources);
    try ensureWorkspaceClaimNoConflicts(previous_obj, resources, null, now);

    const current_counter = workspaceFencingCounter(previous);
    const token: u64 = current_counter + 1;
    const claim_id = try std.fmt.allocPrint(allocator, "claim-{d}", .{token});
    const lease_seconds = try parseLeaseSeconds(args.lease_seconds orelse "900");
    const lease_expires_at = try addSecondsUtcAlloc(allocator, @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000))) + lease_seconds);
    const actor = buildMutationMeta(allocator, args.allow_multiple_in_progress).actor;
    const executor = if (args.executor) |raw| try normalizeExecutor(allocator, raw) else envTrimmed("ST_EXECUTOR") orelse "manual";
    const session_id = args.session_id orelse envTrimmed("ST_SESSION") orelse "default";
    const item_ids = try parseCliIds(allocator, args.ids);
    const draft = WorkspaceClaimDraft{
        .claim_id = claim_id,
        .state = "held",
        .owner = actor,
        .executor = executor,
        .session_id = session_id,
        .plan_id = args.plan_id orelse "",
        .item_ids = item_ids,
        .resources = resources,
        .fencing_token = token,
        .claimed_at = now,
        .lease_seconds = lease_seconds,
        .lease_expires_at = lease_expires_at,
        .heartbeat_at = now,
    };

    var claims_writer: std.Io.Writer.Allocating = .init(allocator);
    defer claims_writer.deinit();
    try writeWorkspaceClaimsWithAppend(&claims_writer.writer, previous_obj, draft);
    const claims_json = try claims_writer.toOwnedSlice();
    const payload = try renderWorkspaceCheckpointReplacingClaims(allocator, workspace_root, previous, claims_json, token, now);
    defer allocator.free(payload);
    try publishWorkspaceClaimCheckpoint(allocator, workspace_root, workspace_file, payload, previous, args, "claim-grant");

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_claim\":{\"receipt_version\":\"WCL-v1\",\"state\":\"held\",\"claim_id\":");
    try std.json.Stringify.value(claim_id, .{}, stdout);
    try stdout.writeAll(",\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, stdout);
    try stdout.writeAll(",\"fencing_token\":");
    try stdout.print("{d}", .{token});
    try stdout.writeAll(",\"workspace_sequence\":");
    try stdout.print("{d}", .{workspaceSequence(previous) + 1});
    try stdout.writeAll(",\"resources\":");
    try writeWorkspaceResourcesArray(stdout, resources);
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdWorkspaceClaimHeartbeat(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const previous = workspace.parsed.value;
    const previous_obj = switch (previous) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const claim_id = try requireNonEmptyString(allocator, args.claim_id orelse args.id orelse return error.MissingValue, "--claim");
    const token = try parseFencingTokenArg(args.fencing_token orelse return error.MissingValue);
    const now = try nowUtcAlloc(allocator);
    _ = try validateWorkspaceClaimAuthority(previous_obj, claim_id, args.session_id, token, now);

    const lease_seconds = try workspaceClaimLeaseSeconds(previous_obj, claim_id);
    const lease_expires_at = try addSecondsUtcAlloc(allocator, @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000))) + lease_seconds);
    var claims_writer: std.Io.Writer.Allocating = .init(allocator);
    defer claims_writer.deinit();
    try writeWorkspaceClaimsWithHeartbeat(&claims_writer.writer, previous_obj, claim_id, lease_expires_at, now);
    const claims_json = try claims_writer.toOwnedSlice();
    const payload = try renderWorkspaceCheckpointReplacingClaims(allocator, workspace.root, previous, claims_json, workspaceFencingCounter(previous), now);
    defer allocator.free(payload);
    try publishWorkspaceClaimCheckpoint(allocator, workspace.root, workspace.file, payload, previous, args, "claim-heartbeat");

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_claim_heartbeat\":{\"ok\":true,\"claim_id\":");
    try std.json.Stringify.value(claim_id, .{}, stdout);
    try stdout.writeAll(",\"workspace_sequence\":");
    try stdout.print("{d}", .{workspaceSequence(previous) + 1});
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdWorkspaceClaimRelease(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const previous = workspace.parsed.value;
    const previous_obj = switch (previous) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const claim_id = try requireNonEmptyString(allocator, args.claim_id orelse args.id orelse return error.MissingValue, "--claim");
    const token = try parseFencingTokenArg(args.fencing_token orelse return error.MissingValue);
    const now = try nowUtcAlloc(allocator);
    _ = try validateWorkspaceClaimAuthority(previous_obj, claim_id, args.session_id, token, now);

    var claims_writer: std.Io.Writer.Allocating = .init(allocator);
    defer claims_writer.deinit();
    try writeWorkspaceClaimsWithStateChange(&claims_writer.writer, previous_obj, claim_id, "released", now);
    const claims_json = try claims_writer.toOwnedSlice();
    const payload = try renderWorkspaceCheckpointReplacingClaims(allocator, workspace.root, previous, claims_json, workspaceFencingCounter(previous), now);
    defer allocator.free(payload);
    try publishWorkspaceClaimCheckpoint(allocator, workspace.root, workspace.file, payload, previous, args, "claim-release");

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_claim_release\":{\"ok\":true,\"claim_id\":");
    try std.json.Stringify.value(claim_id, .{}, stdout);
    try stdout.writeAll(",\"workspace_sequence\":");
    try stdout.print("{d}", .{workspaceSequence(previous) + 1});
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdWorkspaceClaimReclaimStale(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const previous = workspace.parsed.value;
    const previous_obj = switch (previous) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const now = if (args.now) |raw| try requireNonEmptyString(allocator, raw, "--now") else try nowUtcAlloc(allocator);

    var reclaimed: usize = 0;
    var claims_writer: std.Io.Writer.Allocating = .init(allocator);
    defer claims_writer.deinit();
    try writeWorkspaceClaimsWithReclaim(&claims_writer.writer, previous_obj, now, &reclaimed);
    const claims_json = try claims_writer.toOwnedSlice();
    const payload = try renderWorkspaceCheckpointReplacingClaims(allocator, workspace.root, previous, claims_json, workspaceFencingCounter(previous), now);
    defer allocator.free(payload);
    try publishWorkspaceClaimCheckpoint(allocator, workspace.root, workspace.file, payload, previous, args, "claim-reclaim-stale");

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_claim_reclaim_stale\":{\"reclaimed\":");
    try stdout.print("{d}", .{reclaimed});
    try stdout.writeAll(",\"workspace_sequence\":");
    try stdout.print("{d}", .{workspaceSequence(previous) + 1});
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdWorkspaceClaimAmend(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const previous = workspace.parsed.value;
    const previous_obj = switch (previous) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const old_claim_id = try requireNonEmptyString(allocator, args.claim_id orelse args.id orelse return error.MissingValue, "--claim");
    const old_token = try parseFencingTokenArg(args.fencing_token orelse return error.MissingValue);
    const now = try nowUtcAlloc(allocator);
    const old_claim = try validateWorkspaceClaimAuthority(previous_obj, old_claim_id, args.session_id, old_token, now);
    const resources = try parseWorkspaceClaimResources(allocator, args.resources);
    try ensureWorkspaceClaimNoConflicts(previous_obj, resources, old_claim_id, now);

    const token = workspaceFencingCounter(previous) + 1;
    const claim_id = try std.fmt.allocPrint(allocator, "claim-{d}", .{token});
    const lease_seconds = try parseLeaseSeconds(args.lease_seconds orelse "900");
    const lease_expires_at = try addSecondsUtcAlloc(allocator, @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, 1_000_000_000))) + lease_seconds);
    const draft = WorkspaceClaimDraft{
        .claim_id = claim_id,
        .state = "held",
        .owner = stringField(old_claim, "owner") orelse "",
        .executor = stringField(old_claim, "executor") orelse "",
        .session_id = stringField(old_claim, "session_id") orelse args.session_id orelse "default",
        .plan_id = stringField(old_claim, "plan_id") orelse "",
        .item_ids = try workspaceClaimItemIds(allocator, old_claim),
        .resources = resources,
        .fencing_token = token,
        .claimed_at = now,
        .lease_seconds = lease_seconds,
        .lease_expires_at = lease_expires_at,
        .heartbeat_at = now,
        .supersedes = old_claim_id,
    };

    var claims_writer: std.Io.Writer.Allocating = .init(allocator);
    defer claims_writer.deinit();
    try writeWorkspaceClaimsWithAmend(&claims_writer.writer, previous_obj, old_claim_id, now, draft);
    const claims_json = try claims_writer.toOwnedSlice();
    const payload = try renderWorkspaceCheckpointReplacingClaims(allocator, workspace.root, previous, claims_json, token, now);
    defer allocator.free(payload);
    try publishWorkspaceClaimCheckpoint(allocator, workspace.root, workspace.file, payload, previous, args, "claim-amend");

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_claim_amend\":{\"ok\":true,\"old_claim_id\":");
    try std.json.Stringify.value(old_claim_id, .{}, stdout);
    try stdout.writeAll(",\"claim_id\":");
    try std.json.Stringify.value(claim_id, .{}, stdout);
    try stdout.writeAll(",\"fencing_token\":");
    try stdout.print("{d}", .{token});
    try stdout.writeAll(",\"workspace_sequence\":");
    try stdout.print("{d}", .{workspaceSequence(previous) + 1});
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdWorkspaceClaimShow(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const previous_obj = switch (workspace.parsed.value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const claim_id = try requireNonEmptyString(allocator, args.claim_id orelse args.id orelse return error.MissingValue, "--claim");
    const claim = findWorkspaceClaim(previous_obj, claim_id) orelse return error.ClaimMissing;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_claim_show\":{\"workspace_sequence\":");
    try stdout.print("{d}", .{workspaceSequence(workspace.parsed.value)});
    try stdout.writeAll(",\"claim\":");
    try std.json.Stringify.value(claim, .{}, stdout);
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdWorkspaceClaimList(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const previous_obj = switch (workspace.parsed.value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_claim_list\":{\"workspace_sequence\":");
    try stdout.print("{d}", .{workspaceSequence(workspace.parsed.value)});
    try stdout.writeAll(",\"claims\":");
    if (previous_obj.get("claims")) |claims| {
        try std.json.Stringify.value(claims, .{}, stdout);
    } else {
        try stdout.writeAll("[]");
    }
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdWorkspaceClaimConflicts(allocator: std.mem.Allocator, args: Args) !u8 {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const previous_obj = switch (workspace.parsed.value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const now = try nowUtcAlloc(allocator);
    const resources = try parseWorkspaceClaimResources(allocator, args.resources);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"workspace_claim_conflicts\":{\"workspace_sequence\":");
    try stdout.print("{d}", .{workspaceSequence(workspace.parsed.value)});
    try stdout.writeAll(",\"conflicts\":[");
    var emitted = false;
    if (previous_obj.get("claims")) |claims| {
        if (claims != .array) return error.WorkspaceInvalid;
        for (claims.array.items) |claim| {
            if (!workspaceClaimIsHeldCurrent(claim, now)) continue;
            if (!try workspaceClaimConflictsWithResources(claim, resources)) continue;
            if (emitted) try stdout.writeByte(',');
            try stdout.writeAll("{\"claim_id\":");
            try std.json.Stringify.value(stringField(claim, "claim_id") orelse "", .{}, stdout);
            try stdout.writeAll(",\"reason\":\"resource_conflict\"}");
            emitted = true;
        }
    }
    try stdout.writeAll("]}}\n");
    return if (emitted) 2 else 0;
}

const LoadedWorkspaceCheckpoint = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    file: []u8,
    line: []u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: LoadedWorkspaceCheckpoint) void {
        self.parsed.deinit();
        self.allocator.free(self.line);
        self.allocator.free(self.file);
        self.allocator.free(self.root);
    }
};

fn loadWorkspaceCheckpoint(allocator: std.mem.Allocator, raw_workspace: []const u8) !LoadedWorkspaceCheckpoint {
    const workspace_root = try normalizeWorkspacePath(allocator, raw_workspace);
    errdefer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    errdefer allocator.free(workspace_file);
    if (!fileExists(workspace_file)) return error.WorkspaceMissing;
    const line = try readLastJsonlLine(allocator, workspace_file);
    errdefer allocator.free(line);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;
    return .{ .allocator = allocator, .root = workspace_root, .file = workspace_file, .line = line, .parsed = parsed };
}

fn publishWorkspaceClaimCheckpoint(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_file: []const u8,
    payload: []const u8,
    previous: std.json.Value,
    args: Args,
    operation: []const u8,
) !void {
    const current_sequence = workspaceSequence(previous);
    if (args.expect_workspace_seq) |raw| {
        const expected_arg = try parseNonNegativeI64(raw);
        if (expected_arg != current_sequence) return error.WorkspaceSequenceStale;
    }
    var receipt = try appendWorkspaceCheckpointTransaction(
        allocator,
        workspace_root,
        workspace_file,
        payload,
        current_sequence,
        operation,
    );
    defer receipt.deinit(allocator);
}

fn workspaceSequence(value: std.json.Value) i64 {
    return intField(value, "workspace_sequence") orelse 0;
}

fn workspaceFencingCounter(value: std.json.Value) u64 {
    const raw = intField(value, "fencing_counter") orelse 0;
    if (raw <= 0) return 0;
    return @intCast(raw);
}

fn parseNonNegativeI64(raw: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const value = try std.fmt.parseInt(i64, trimmed, 10);
    if (value < 0) return error.InvalidSequence;
    return value;
}

fn parseFencingTokenArg(raw: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const value = try std.fmt.parseInt(u64, trimmed, 10);
    if (value == 0) return error.FencingTokenStale;
    return value;
}

fn parseWorkspaceClaimResources(allocator: std.mem.Allocator, raw: []const u8) ![]WorkspaceResource {
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) {
        const inferred = try inferUnknownMutationResource(allocator);
        const out = try allocator.alloc(WorkspaceResource, 1);
        out[0] = inferred.resource;
        return out;
    }

    var out: std.ArrayList(WorkspaceResource) = .empty;
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidResource;
        const mode_raw = part[0..colon];
        const resource_raw = part[colon + 1 ..];
        const mode = parseWorkspaceResourceModeString(mode_raw) orelse return error.InvalidResource;
        try out.append(allocator, try parseWorkspaceResource(allocator, resource_raw, mode));
    }
    if (out.items.len == 0) return error.InvalidResource;
    return out.toOwnedSlice(allocator);
}

fn parseWorkspaceResourceModeString(raw: []const u8) ?WorkspaceResourceMode {
    if (std.mem.eql(u8, raw, "read")) return .read;
    if (std.mem.eql(u8, raw, "write")) return .write;
    if (std.mem.eql(u8, raw, "exclusive")) return .exclusive;
    return null;
}

fn workspaceResourceModeString(mode: WorkspaceResourceMode) []const u8 {
    return switch (mode) {
        .read => "read",
        .write => "write",
        .exclusive => "exclusive",
    };
}

fn workspaceResourceKindString(kind: WorkspaceResourceKind) []const u8 {
    return switch (kind) {
        .path => "path",
        .symbol => "symbol",
        .generated => "generated",
        .schema => "schema",
        .service => "service",
        .git_index => "git:index",
        .git_branch => "git:branch",
        .repo_all => "repo:all",
    };
}

fn parseWorkspaceResourceKindString(raw: []const u8) ?WorkspaceResourceKind {
    if (std.mem.eql(u8, raw, "path")) return .path;
    if (std.mem.eql(u8, raw, "symbol")) return .symbol;
    if (std.mem.eql(u8, raw, "generated")) return .generated;
    if (std.mem.eql(u8, raw, "schema")) return .schema;
    if (std.mem.eql(u8, raw, "service")) return .service;
    if (std.mem.eql(u8, raw, "git:index")) return .git_index;
    if (std.mem.eql(u8, raw, "git:branch")) return .git_branch;
    if (std.mem.eql(u8, raw, "repo:all")) return .repo_all;
    return null;
}

fn writeWorkspaceResourceObject(writer: anytype, resource: WorkspaceResource) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"kind\":");
    try std.json.Stringify.value(workspaceResourceKindString(resource.kind), .{}, writer);
    try writer.writeAll(",\"mode\":");
    try std.json.Stringify.value(workspaceResourceModeString(resource.mode), .{}, writer);
    try writer.writeAll(",\"primary\":");
    try std.json.Stringify.value(resource.primary, .{}, writer);
    if (resource.secondary.len > 0) {
        try writer.writeAll(",\"secondary\":");
        try std.json.Stringify.value(resource.secondary, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeWorkspaceResourcesArray(writer: anytype, resources: []const WorkspaceResource) !void {
    try writer.writeByte('[');
    for (resources, 0..) |resource, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeWorkspaceResourceObject(writer, resource);
    }
    try writer.writeByte(']');
}

fn workspaceResourceFromJson(value: std.json.Value) !WorkspaceResource {
    if (value != .object) return error.WorkspaceInvalid;
    const kind = parseWorkspaceResourceKindString(stringField(value, "kind") orelse return error.WorkspaceInvalid) orelse return error.WorkspaceInvalid;
    const mode = parseWorkspaceResourceModeString(stringField(value, "mode") orelse return error.WorkspaceInvalid) orelse return error.WorkspaceInvalid;
    return .{
        .kind = kind,
        .mode = mode,
        .primary = stringField(value, "primary") orelse "",
        .secondary = stringField(value, "secondary") orelse "",
    };
}

fn ensureWorkspaceClaimNoConflicts(
    workspace_obj: std.json.ObjectMap,
    resources: []const WorkspaceResource,
    except_claim_id: ?[]const u8,
    now: []const u8,
) !void {
    const claims = workspace_obj.get("claims") orelse return;
    if (claims != .array) return error.WorkspaceInvalid;
    for (claims.array.items) |claim| {
        if (except_claim_id) |except| {
            if (std.mem.eql(u8, stringField(claim, "claim_id") orelse "", except)) continue;
        }
        if (!workspaceClaimIsHeldCurrent(claim, now)) continue;
        if (try workspaceClaimConflictsWithResources(claim, resources)) return error.ResourceConflict;
    }
}

fn workspaceClaimConflictsWithResources(claim: std.json.Value, resources: []const WorkspaceResource) !bool {
    if (claim != .object) return error.WorkspaceInvalid;
    const claim_resources = claim.object.get("resources") orelse return false;
    if (claim_resources != .array) return error.WorkspaceInvalid;
    for (claim_resources.array.items) |entry| {
        const held = try workspaceResourceFromJson(entry);
        for (resources) |candidate| {
            if (workspaceResourcesConflict(held, candidate)) return true;
        }
    }
    return false;
}

fn workspaceClaimIsHeldCurrent(claim: std.json.Value, now: []const u8) bool {
    const state = stringField(claim, "state") orelse return false;
    if (!std.mem.eql(u8, state, "held")) return false;
    const expires = stringField(claim, "lease_expires_at") orelse "";
    if (expires.len == 0) return true;
    return std.mem.order(u8, expires, now) == .gt;
}

fn validateWorkspaceClaimAuthority(
    workspace_obj: std.json.ObjectMap,
    claim_id: []const u8,
    session_id: ?[]const u8,
    token: u64,
    now: []const u8,
) !std.json.Value {
    const claim = findWorkspaceClaim(workspace_obj, claim_id) orelse return error.ClaimMissing;
    const state = stringField(claim, "state") orelse return error.WorkspaceInvalid;
    if (!std.mem.eql(u8, state, "held")) return error.FencingTokenStale;
    if (!workspaceClaimIsHeldCurrent(claim, now)) return error.ClaimExpired;
    const held_token_raw = intField(claim, "fencing_token") orelse return error.WorkspaceInvalid;
    if (held_token_raw <= 0 or @as(u64, @intCast(held_token_raw)) != token) return error.FencingTokenStale;
    if (session_id) |wanted| {
        const held_session = stringField(claim, "session_id") orelse "";
        if (!std.mem.eql(u8, held_session, wanted)) return error.ClaimOwnerMismatch;
    }
    return claim;
}

fn findWorkspaceClaim(workspace_obj: std.json.ObjectMap, claim_id: []const u8) ?std.json.Value {
    const claims = workspace_obj.get("claims") orelse return null;
    if (claims != .array) return null;
    for (claims.array.items) |claim| {
        if (std.mem.eql(u8, stringField(claim, "claim_id") orelse "", claim_id)) return claim;
    }
    return null;
}

fn findWorkspacePlanRecord(workspace_obj: std.json.ObjectMap, plan_id: []const u8) ?std.json.Value {
    const plans = workspace_obj.get("plans") orelse return null;
    if (plans != .array) return null;
    for (plans.array.items) |plan_record| {
        if (std.mem.eql(u8, stringField(plan_record, "plan_id") orelse "", plan_id)) return plan_record;
    }
    return null;
}

fn workspacePlanRecordFingerprintsCurrent(plan_record: std.json.Value, fps: GraphFingerprints) !bool {
    if (plan_record != .object) return error.WorkspaceInvalid;
    const registry_fps = plan_record.object.get("graph_fingerprints") orelse return true;
    if (registry_fps != .object) return error.WorkspaceInvalid;
    if (registry_fps.object.count() == 0) return true;
    return graphFingerprintFieldMatches(registry_fps, "structure", fps.structure) and
        graphFingerprintFieldMatches(registry_fps, "contract", fps.contract) and
        graphFingerprintFieldMatches(registry_fps, "coverage", fps.coverage) and
        graphFingerprintFieldMatches(registry_fps, "execution", fps.execution);
}

fn graphFingerprintFieldMatches(registry_fps: std.json.Value, field: []const u8, current: []const u8) bool {
    const value = registry_fps.object.get(field) orelse return false;
    const stored = asString(value) orelse return false;
    return stored.len > 0 and std.mem.eql(u8, stored, current);
}

fn workspaceClaimLeaseSeconds(workspace_obj: std.json.ObjectMap, claim_id: []const u8) !i64 {
    const claim = findWorkspaceClaim(workspace_obj, claim_id) orelse return error.ClaimMissing;
    const raw = intField(claim, "lease_seconds") orelse 900;
    if (raw <= 0) return 900;
    return raw;
}

fn workspaceClaimItemIds(allocator: std.mem.Allocator, claim: std.json.Value) ![]const []const u8 {
    if (claim != .object) return error.WorkspaceInvalid;
    const value = claim.object.get("item_ids") orelse return &.{};
    if (value != .array) return error.WorkspaceInvalid;
    var out: std.ArrayList([]const u8) = .empty;
    for (value.array.items) |entry| {
        if (entry != .string) return error.WorkspaceInvalid;
        try out.append(allocator, entry.string);
    }
    return out.toOwnedSlice(allocator);
}

fn writeWorkspaceClaimObject(writer: anytype, claim: WorkspaceClaimDraft) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"claim_id\":");
    try std.json.Stringify.value(claim.claim_id, .{}, writer);
    try writer.writeAll(",\"state\":");
    try std.json.Stringify.value(claim.state, .{}, writer);
    try writer.writeAll(",\"owner\":");
    try std.json.Stringify.value(claim.owner, .{}, writer);
    try writer.writeAll(",\"executor\":");
    try std.json.Stringify.value(claim.executor, .{}, writer);
    try writer.writeAll(",\"session_id\":");
    try std.json.Stringify.value(claim.session_id, .{}, writer);
    try writer.writeAll(",\"plan_id\":");
    try std.json.Stringify.value(claim.plan_id, .{}, writer);
    try writer.writeAll(",\"item_ids\":[");
    for (claim.item_ids, 0..) |item_id, idx| {
        if (idx != 0) try writer.writeByte(',');
        try std.json.Stringify.value(item_id, .{}, writer);
    }
    try writer.writeAll("],\"resources\":");
    try writeWorkspaceResourcesArray(writer, claim.resources);
    try writer.writeAll(",\"fencing_token\":");
    try writer.print("{d}", .{claim.fencing_token});
    try writer.writeAll(",\"claimed_at\":");
    try std.json.Stringify.value(claim.claimed_at, .{}, writer);
    try writer.writeAll(",\"lease_seconds\":");
    try writer.print("{d}", .{claim.lease_seconds});
    try writer.writeAll(",\"lease_expires_at\":");
    try std.json.Stringify.value(claim.lease_expires_at, .{}, writer);
    try writer.writeAll(",\"heartbeat_at\":");
    try std.json.Stringify.value(claim.heartbeat_at, .{}, writer);
    if (claim.released_at.len > 0) {
        try writer.writeAll(",\"released_at\":");
        try std.json.Stringify.value(claim.released_at, .{}, writer);
    }
    if (claim.stale_at.len > 0) {
        try writer.writeAll(",\"stale_at\":");
        try std.json.Stringify.value(claim.stale_at, .{}, writer);
    }
    if (claim.supersedes.len > 0) {
        try writer.writeAll(",\"supersedes\":");
        try std.json.Stringify.value(claim.supersedes, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeExistingWorkspaceClaimObject(
    writer: anytype,
    entry: std.json.Value,
    state: ?[]const u8,
    lease_expires_at: ?[]const u8,
    heartbeat_at: ?[]const u8,
    released_at: ?[]const u8,
    stale_at: ?[]const u8,
) !void {
    if (entry != .object) return error.WorkspaceInvalid;
    const obj = entry.object;
    try writer.writeByte('{');
    try writer.writeAll("\"claim_id\":");
    try std.json.Stringify.value(stringField(entry, "claim_id") orelse return error.WorkspaceInvalid, .{}, writer);
    try writer.writeAll(",\"state\":");
    try std.json.Stringify.value(state orelse stringField(entry, "state") orelse return error.WorkspaceInvalid, .{}, writer);
    try writer.writeAll(",\"owner\":");
    try std.json.Stringify.value(stringField(entry, "owner") orelse "", .{}, writer);
    try writer.writeAll(",\"executor\":");
    try std.json.Stringify.value(stringField(entry, "executor") orelse "", .{}, writer);
    try writer.writeAll(",\"session_id\":");
    try std.json.Stringify.value(stringField(entry, "session_id") orelse "", .{}, writer);
    try writer.writeAll(",\"plan_id\":");
    try std.json.Stringify.value(stringField(entry, "plan_id") orelse "", .{}, writer);
    try writer.writeAll(",\"item_ids\":");
    if (obj.get("item_ids")) |item_ids| {
        try std.json.Stringify.value(item_ids, .{}, writer);
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeAll(",\"resources\":");
    if (obj.get("resources")) |resources| {
        try std.json.Stringify.value(resources, .{}, writer);
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeAll(",\"fencing_token\":");
    try writer.print("{d}", .{intField(entry, "fencing_token") orelse 0});
    try writer.writeAll(",\"claimed_at\":");
    try std.json.Stringify.value(stringField(entry, "claimed_at") orelse "", .{}, writer);
    try writer.writeAll(",\"lease_seconds\":");
    try writer.print("{d}", .{intField(entry, "lease_seconds") orelse 900});
    try writer.writeAll(",\"lease_expires_at\":");
    try std.json.Stringify.value(lease_expires_at orelse stringField(entry, "lease_expires_at") orelse "", .{}, writer);
    try writer.writeAll(",\"heartbeat_at\":");
    try std.json.Stringify.value(heartbeat_at orelse stringField(entry, "heartbeat_at") orelse "", .{}, writer);
    if (released_at orelse stringField(entry, "released_at")) |value| {
        if (value.len > 0) {
            try writer.writeAll(",\"released_at\":");
            try std.json.Stringify.value(value, .{}, writer);
        }
    }
    if (stale_at orelse stringField(entry, "stale_at")) |value| {
        if (value.len > 0) {
            try writer.writeAll(",\"stale_at\":");
            try std.json.Stringify.value(value, .{}, writer);
        }
    }
    if (stringField(entry, "supersedes")) |value| {
        try writer.writeAll(",\"supersedes\":");
        try std.json.Stringify.value(value, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeWorkspaceClaimsWithAppend(writer: anytype, workspace_obj: std.json.ObjectMap, draft: WorkspaceClaimDraft) !void {
    try writer.writeByte('[');
    var emitted = false;
    if (workspace_obj.get("claims")) |claims| {
        if (claims != .array) return error.WorkspaceInvalid;
        for (claims.array.items) |entry| {
            if (emitted) try writer.writeByte(',');
            try std.json.Stringify.value(entry, .{}, writer);
            emitted = true;
        }
    }
    if (emitted) try writer.writeByte(',');
    try writeWorkspaceClaimObject(writer, draft);
    try writer.writeByte(']');
}

fn writeWorkspaceClaimsWithHeartbeat(writer: anytype, workspace_obj: std.json.ObjectMap, claim_id: []const u8, lease_expires_at: []const u8, now: []const u8) !void {
    try writer.writeByte('[');
    var emitted = false;
    const claims = workspace_obj.get("claims") orelse return error.ClaimMissing;
    if (claims != .array) return error.WorkspaceInvalid;
    for (claims.array.items) |entry| {
        if (emitted) try writer.writeByte(',');
        if (std.mem.eql(u8, stringField(entry, "claim_id") orelse "", claim_id)) {
            try writeExistingWorkspaceClaimObject(writer, entry, null, lease_expires_at, now, null, null);
        } else {
            try std.json.Stringify.value(entry, .{}, writer);
        }
        emitted = true;
    }
    try writer.writeByte(']');
}

fn writeWorkspaceClaimsWithStateChange(writer: anytype, workspace_obj: std.json.ObjectMap, claim_id: []const u8, state: []const u8, now: []const u8) !void {
    try writer.writeByte('[');
    var emitted = false;
    const claims = workspace_obj.get("claims") orelse return error.ClaimMissing;
    if (claims != .array) return error.WorkspaceInvalid;
    for (claims.array.items) |entry| {
        if (emitted) try writer.writeByte(',');
        if (std.mem.eql(u8, stringField(entry, "claim_id") orelse "", claim_id)) {
            const released_at = if (std.mem.eql(u8, state, "released")) now else null;
            const stale_at = if (std.mem.eql(u8, state, "stale")) now else null;
            try writeExistingWorkspaceClaimObject(writer, entry, state, "", now, released_at, stale_at);
        } else {
            try std.json.Stringify.value(entry, .{}, writer);
        }
        emitted = true;
    }
    try writer.writeByte(']');
}

fn writeWorkspaceClaimsWithReclaim(writer: anytype, workspace_obj: std.json.ObjectMap, now: []const u8, reclaimed: *usize) !void {
    try writer.writeByte('[');
    var emitted = false;
    if (workspace_obj.get("claims")) |claims| {
        if (claims != .array) return error.WorkspaceInvalid;
        for (claims.array.items) |entry| {
            if (emitted) try writer.writeByte(',');
            const state = stringField(entry, "state") orelse @as([]const u8, "");
            if (state.len > 0 and !workspaceClaimIsHeldCurrent(entry, now) and std.mem.eql(u8, state, "held")) {
                try writeExistingWorkspaceClaimObject(writer, entry, "stale", "", now, null, now);
                reclaimed.* += 1;
            } else {
                try std.json.Stringify.value(entry, .{}, writer);
            }
            emitted = true;
        }
    }
    try writer.writeByte(']');
}

fn writeWorkspaceClaimsWithAmend(writer: anytype, workspace_obj: std.json.ObjectMap, old_claim_id: []const u8, now: []const u8, draft: WorkspaceClaimDraft) !void {
    try writer.writeByte('[');
    var emitted = false;
    const claims = workspace_obj.get("claims") orelse return error.ClaimMissing;
    if (claims != .array) return error.WorkspaceInvalid;
    for (claims.array.items) |entry| {
        if (emitted) try writer.writeByte(',');
        if (std.mem.eql(u8, stringField(entry, "claim_id") orelse "", old_claim_id)) {
            try writeExistingWorkspaceClaimObject(writer, entry, "released", "", now, now, null);
        } else {
            try std.json.Stringify.value(entry, .{}, writer);
        }
        emitted = true;
    }
    if (emitted) try writer.writeByte(',');
    try writeWorkspaceClaimObject(writer, draft);
    try writer.writeByte(']');
}

fn renderWorkspaceCheckpointReplacingClaims(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    previous: std.json.Value,
    claims_json: []const u8,
    fencing_counter: u64,
    now: []const u8,
) ![]u8 {
    const previous_obj = switch (previous) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const plans_value = previous_obj.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    const workspace_sequence = workspaceSequence(previous) + 1;
    const artifact_root = stringField(previous, "artifact_root") orelse ".ledger";
    const st_root = stringField(previous, "st_root") orelse workspace_root;
    const created_at = stringField(previous, "created_at") orelse now;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"lane\":\"checkpoint\",\"schema\":\"STW-v1\",\"workspace_sequence\":");
    try writer.print("{d}", .{workspace_sequence});
    try writer.writeAll(",\"artifact_root\":");
    try std.json.Stringify.value(artifact_root, .{}, writer);
    try writer.writeAll(",\"st_root\":");
    try std.json.Stringify.value(st_root, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(created_at, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll(",\"target_branch\":");
    try std.json.Stringify.value(previous_obj.get("target_branch") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"target_head\":");
    try std.json.Stringify.value(previous_obj.get("target_head") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{intField(previous, "branch_epoch") orelse 0});
    try writer.writeAll(",\"plans\":");
    try std.json.Stringify.value(plans_value, .{}, writer);
    try writer.writeAll(",\"cross_plan_edges\":");
    if (previous_obj.get("cross_plan_edges")) |cross_plan_edges| {
        try std.json.Stringify.value(cross_plan_edges, .{}, writer);
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeAll(",\"claims\":");
    try writer.writeAll(claims_json);
    try writer.writeAll(",\"fencing_counter\":");
    try writer.print("{d}", .{fencing_counter});
    try writer.writeAll(",\"policy\":");
    if (previous_obj.get("policy")) |policy| {
        try std.json.Stringify.value(policy, .{}, writer);
    } else {
        try writer.writeAll("{\"fail_closed\":true,\"workspace_v1\":true}");
    }
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn renderWorkspaceCheckpointWithBranchState(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    previous: std.json.Value,
    target_branch: []const u8,
    target_head: []const u8,
    branch_epoch: i64,
    now: []const u8,
) ![]u8 {
    const previous_obj = switch (previous) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const plans_value = previous_obj.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    const workspace_sequence = workspaceSequence(previous) + 1;
    const artifact_root = stringField(previous, "artifact_root") orelse ".ledger";
    const st_root = stringField(previous, "st_root") orelse workspace_root;
    const created_at = stringField(previous, "created_at") orelse now;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"lane\":\"checkpoint\",\"schema\":\"STW-v1\",\"workspace_sequence\":");
    try writer.print("{d}", .{workspace_sequence});
    try writer.writeAll(",\"artifact_root\":");
    try std.json.Stringify.value(artifact_root, .{}, writer);
    try writer.writeAll(",\"st_root\":");
    try std.json.Stringify.value(st_root, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(created_at, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll(",\"target_branch\":");
    try std.json.Stringify.value(target_branch, .{}, writer);
    try writer.writeAll(",\"target_head\":");
    try std.json.Stringify.value(target_head, .{}, writer);
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{branch_epoch});
    try writer.writeAll(",\"plans\":");
    try std.json.Stringify.value(plans_value, .{}, writer);
    try writer.writeAll(",\"cross_plan_edges\":");
    if (previous_obj.get("cross_plan_edges")) |cross_plan_edges| {
        try std.json.Stringify.value(cross_plan_edges, .{}, writer);
    } else {
        try writer.writeAll("[]");
    }
    try writeWorkspaceAuthorityFields(writer, previous_obj);
    try writer.writeAll(",\"policy\":");
    if (previous_obj.get("policy")) |policy| {
        try std.json.Stringify.value(policy, .{}, writer);
    } else {
        try writer.writeAll("{\"fail_closed\":true,\"workspace_v1\":true}");
    }
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn cmdPlanCrossLink(allocator: std.mem.Allocator, args: Args, op: CrossPlanEdgeOp) !u8 {
    const workspace_root = try normalizeWorkspacePath(allocator, args.workspace);
    defer allocator.free(workspace_root);
    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_root, "workspace.jsonl" });
    defer allocator.free(workspace_file);
    if (!fileExists(workspace_file)) return error.WorkspaceMissing;

    const from_ref = try parseQualifiedRef(allocator, args.from_ref orelse return error.MissingValue);
    defer from_ref.deinit(allocator);
    const to_ref = try parseQualifiedRef(allocator, args.to_ref orelse return error.MissingValue);
    defer to_ref.deinit(allocator);
    const edge_type = try normalizeCrossPlanEdgeType(args.link_type);
    const edge = CrossPlanEdge{ .from = from_ref.canonical, .to = to_ref.canonical, .edge_type = edge_type };

    const checkpoint_line = try readLastJsonlLine(allocator, workspace_file);
    defer allocator.free(checkpoint_line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, checkpoint_line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WorkspaceInvalid;
    const plans_value = parsed.value.object.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    const edges_value = parsed.value.object.get("cross_plan_edges");
    if (edges_value) |value| {
        if (value != .array) return error.WorkspaceInvalid;
    }

    try validateQualifiedRefTarget(allocator, workspace_root, plans_value, from_ref);
    try validateQualifiedRefTarget(allocator, workspace_root, plans_value, to_ref);

    const exists = if (edges_value) |value| try crossPlanEdgeExists(value, edge) else false;
    switch (op) {
        .link => if (exists) return error.CrossPlanEdgeExists,
        .unlink => if (!exists) return error.CrossPlanEdgeMissing,
    }

    const now = try nowUtcAlloc(allocator);
    defer allocator.free(now);
    const workspace_payload = try renderWorkspaceCheckpointWithCrossPlanEdge(allocator, workspace_root, parsed.value, edge, op, now);
    defer allocator.free(workspace_payload);
    var receipt = try appendWorkspaceCheckpointTransaction(
        allocator,
        workspace_root,
        workspace_file,
        workspace_payload,
        intField(parsed.value, "workspace_sequence") orelse 0,
        if (op == .link) "plan-link" else "plan-unlink",
    );
    defer receipt.deinit(allocator);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json) {
        try stdout.writeAll("{\"plan_");
        try stdout.writeAll(if (op == .link) "link" else "unlink");
        try stdout.writeAll("\":{\"ok\":true,\"from\":");
        try std.json.Stringify.value(edge.from, .{}, stdout);
        try stdout.writeAll(",\"to\":");
        try std.json.Stringify.value(edge.to, .{}, stdout);
        try stdout.writeAll(",\"type\":");
        try std.json.Stringify.value(edge.edge_type, .{}, stdout);
        try stdout.writeAll(",\"workspace_sequence\":");
        try stdout.print("{d}", .{(intField(parsed.value, "workspace_sequence") orelse 0) + 1});
        try stdout.writeAll("}}\n");
    } else {
        try stdout.print("{s} cross-plan edge {s} -> {s} ({s})\n", .{ if (op == .link) "linked" else "unlinked", edge.from, edge.to, edge.edge_type });
    }
    return 0;
}

fn parseQualifiedRef(allocator: std.mem.Allocator, raw: []const u8) !QualifiedRef {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const prefix = "plan://";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return error.InvalidQualifiedRef;
    const rest = trimmed[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidQualifiedRef;
    const plan_part = rest[0..slash];
    const item_part = rest[slash + 1 ..];
    if (item_part.len == 0 or std.mem.indexOfScalar(u8, item_part, '/') != null or std.mem.indexOfScalar(u8, item_part, 0) != null) {
        return error.InvalidQualifiedRef;
    }
    const plan_id = try normalizePlanId(allocator, plan_part);
    errdefer allocator.free(plan_id);
    const item_id = try requireNonEmptyString(allocator, item_part, "qualified item id");
    errdefer allocator.free(item_id);
    const canonical = try std.fmt.allocPrint(allocator, "plan://{s}/{s}", .{ plan_id, item_id });
    return .{ .plan_id = plan_id, .item_id = item_id, .canonical = canonical };
}

fn normalizeCrossPlanEdgeType(raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "hard")) return "hard";
    if (std.mem.eql(u8, trimmed, "nonblocking")) return "nonblocking";
    return error.InvalidCrossPlanEdgeType;
}

fn validateQualifiedRefTarget(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    plans_value: std.json.Value,
    ref: QualifiedRef,
) !void {
    const graph_ref = try workspacePlanGraphRefForId(allocator, plans_value, ref.plan_id);
    defer allocator.free(graph_ref);
    const plan_file = try std.fs.path.join(allocator, &.{ workspace_root, graph_ref });
    defer allocator.free(plan_file);
    var loaded = try loadValidatedState(allocator, plan_file, false);
    defer loaded.state.deinit();
    if (loaded.state.getConst(ref.item_id) == null) return error.UnknownItemId;
}

fn workspacePlanGraphRefForId(allocator: std.mem.Allocator, plans_value: std.json.Value, plan_id: []const u8) ![]u8 {
    if (plans_value != .array) return error.WorkspaceInvalid;
    for (plans_value.array.items) |entry| {
        if (entry != .object) return error.WorkspaceInvalid;
        const entry_plan_id = stringField(entry, "plan_id") orelse return error.WorkspaceInvalid;
        if (std.mem.eql(u8, entry_plan_id, plan_id)) {
            return allocator.dupe(u8, stringField(entry, "graph_ref") orelse return error.WorkspaceInvalid);
        }
    }
    return error.PlanMissing;
}

fn crossPlanEdgeExists(edges_value: std.json.Value, edge: CrossPlanEdge) !bool {
    if (edges_value != .array) return error.WorkspaceInvalid;
    for (edges_value.array.items) |entry| {
        if (entry != .object) return error.WorkspaceInvalid;
        if (crossPlanEdgeMatches(entry, edge)) return true;
    }
    return false;
}

fn crossPlanEdgeMatches(entry: std.json.Value, edge: CrossPlanEdge) bool {
    return std.mem.eql(u8, stringField(entry, "from") orelse "", edge.from) and
        std.mem.eql(u8, stringField(entry, "to") orelse "", edge.to) and
        std.mem.eql(u8, stringField(entry, "type") orelse "", edge.edge_type);
}

fn parseWorkspaceResource(allocator: std.mem.Allocator, raw: []const u8, mode: WorkspaceResourceMode) !WorkspaceResource {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "path:")) {
        const path = try normalizeResourcePath(allocator, trimmed["path:".len..]);
        return .{ .kind = .path, .mode = mode, .primary = path };
    }
    if (std.mem.startsWith(u8, trimmed, "symbol:")) {
        const body = trimmed["symbol:".len..];
        const marker = std.mem.indexOfScalar(u8, body, '#') orelse return error.InvalidResource;
        if (std.mem.indexOfScalar(u8, body[marker + 1 ..], '#') != null) return error.InvalidResource;
        const path = try normalizeResourcePath(allocator, body[0..marker]);
        errdefer allocator.free(path);
        const symbol = try normalizeResourceIdentifier(allocator, body[marker + 1 ..], false);
        return .{ .kind = .symbol, .mode = mode, .primary = path, .secondary = symbol };
    }
    if (std.mem.startsWith(u8, trimmed, "generated:")) {
        const name = try normalizeResourceIdentifier(allocator, trimmed["generated:".len..], true);
        return .{ .kind = .generated, .mode = mode, .primary = name };
    }
    if (std.mem.startsWith(u8, trimmed, "schema:")) {
        const name = try normalizeResourceIdentifier(allocator, trimmed["schema:".len..], true);
        return .{ .kind = .schema, .mode = mode, .primary = name };
    }
    if (std.mem.startsWith(u8, trimmed, "service:")) {
        const name = try normalizeResourceIdentifier(allocator, trimmed["service:".len..], true);
        return .{ .kind = .service, .mode = mode, .primary = name };
    }
    if (std.mem.eql(u8, trimmed, "git:index")) {
        return .{ .kind = .git_index, .mode = mode, .primary = try allocator.dupe(u8, "index") };
    }
    if (std.mem.startsWith(u8, trimmed, "git:branch:")) {
        const branch = try normalizeGitBranchResource(allocator, trimmed["git:branch:".len..]);
        return .{ .kind = .git_branch, .mode = mode, .primary = branch };
    }
    if (std.mem.eql(u8, trimmed, "repo:all")) {
        return .{ .kind = .repo_all, .mode = mode, .primary = try allocator.dupe(u8, "all") };
    }
    return error.InvalidResource;
}

fn inferUnknownMutationResource(allocator: std.mem.Allocator) !InferredWorkspaceResource {
    return .{
        .resource = .{ .kind = .repo_all, .mode = .exclusive, .primary = try allocator.dupe(u8, "all") },
        .confidence = "low",
    };
}

fn workspaceResourcesConflict(a: WorkspaceResource, b: WorkspaceResource) bool {
    if (a.kind == .repo_all or b.kind == .repo_all) return true;
    if (workspaceResourcePathLike(a) and workspaceResourcePathLike(b)) {
        return resourcePathsOverlap(a.primary, b.primary) and resourceModesConflict(a.mode, b.mode);
    }
    if (a.kind != b.kind) return false;
    if (!std.mem.eql(u8, a.primary, b.primary)) return false;
    return resourceModesConflict(a.mode, b.mode);
}

fn workspaceResourcePathLike(resource: WorkspaceResource) bool {
    return resource.kind == .path or resource.kind == .symbol;
}

fn resourceModesConflict(a: WorkspaceResourceMode, b: WorkspaceResourceMode) bool {
    if (a == .exclusive or b == .exclusive) return true;
    return !(a == .read and b == .read);
}

fn resourcePathsOverlap(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    return pathIsAncestor(a, b) or pathIsAncestor(b, a);
}

fn pathIsAncestor(parent: []const u8, child: []const u8) bool {
    return child.len > parent.len and
        std.mem.startsWith(u8, child, parent) and
        child[parent.len] == '/';
}

fn normalizeResourcePath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, 0) != null) return error.InvalidResource;
    if (std.fs.path.isAbsolute(trimmed)) return error.InvalidResource;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var wrote = false;
    var components = std.mem.splitAny(u8, trimmed, "/\\");
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) return error.InvalidResource;
        if (wrote) try out.writer.writeByte('/');
        try out.writer.writeAll(component);
        wrote = true;
    }
    if (!wrote) return error.InvalidResource;
    const normalized = try out.toOwnedSlice();
    errdefer allocator.free(normalized);
    try durable_store.rejectSymlinkComponents(normalized);
    return normalized;
}

fn normalizeResourceIdentifier(allocator: std.mem.Allocator, raw: []const u8, lowercase: bool) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, 0) != null) return error.InvalidResource;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (trimmed) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
        if (!ok) return error.InvalidResource;
        try out.writer.writeByte(if (lowercase) std.ascii.toLower(c) else c);
    }
    return out.toOwnedSlice();
}

fn normalizeGitBranchResource(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, 0) != null) return error.InvalidResource;
    if (trimmed[0] == '/' or trimmed[trimmed.len - 1] == '/' or std.mem.indexOf(u8, trimmed, "..") != null) return error.InvalidResource;
    for (trimmed) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/';
        if (!ok) return error.InvalidResource;
    }
    return allocator.dupe(u8, trimmed);
}

fn planLifecycleTransitionAllowed(from_state: []const u8, target_state: []const u8) bool {
    if (std.mem.eql(u8, target_state, "paused")) {
        return std.mem.eql(u8, from_state, "active");
    }
    if (std.mem.eql(u8, target_state, "active")) {
        return std.mem.eql(u8, from_state, "paused");
    }
    if (std.mem.eql(u8, target_state, "completed")) {
        return std.mem.eql(u8, from_state, "active") or std.mem.eql(u8, from_state, "paused");
    }
    if (std.mem.eql(u8, target_state, "archived")) {
        return std.mem.eql(u8, from_state, "paused") or std.mem.eql(u8, from_state, "completed");
    }
    return false;
}

fn appendWorkspaceCheckpointTransaction(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_file: []const u8,
    checkpoint_line: []const u8,
    expected_sequence: i64,
    operation: []const u8,
) !durable_store.JsonlTransactionReceipt {
    return publishWorkspaceCheckpointTransaction(
        allocator,
        workspace_root,
        workspace_file,
        checkpoint_line,
        expected_sequence,
        operation,
        .append,
        false,
    );
}

fn publishWorkspaceCheckpointTransaction(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    workspace_file: []const u8,
    checkpoint_line: []const u8,
    expected_sequence: i64,
    operation: []const u8,
    mode: durable_store.JsonlTransactionMode,
    allow_sequence_reset: bool,
) !durable_store.JsonlTransactionReceipt {
    const locks_dir = try workspaceLocksDirAlloc(allocator, workspace_root);
    defer allocator.free(locks_dir);
    const transactions_dir = try workspaceTransactionsDirAlloc(allocator, workspace_root);
    defer allocator.free(transactions_dir);
    return durable_store.appendJsonlCheckpointTransaction(
        allocator,
        workspace_file,
        locks_dir,
        transactions_dir,
        checkpoint_line,
        .{
            .expected_sequence = expected_sequence,
            .sequence_field = "workspace_sequence",
            .operation = operation,
            .max_existing_bytes = 1024 * 1024,
            .mode = mode,
            .allow_sequence_reset = allow_sequence_reset,
        },
    );
}

fn workspaceLocksDirAlloc(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ workspace_root, "locks" });
}

fn workspaceTransactionsDirAlloc(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ workspace_root, "transactions" });
}

fn normalizeWorkspacePath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = try requireNonEmptyString(allocator, raw, "--workspace");
    if (std.mem.indexOfScalar(u8, trimmed, 0) != null) return error.InvalidWorkspacePath;

    var components = std.mem.splitAny(u8, trimmed, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.InvalidWorkspacePath;
    }
    return allocator.dupe(u8, trimmed);
}

fn normalizePlanId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = try requireNonEmptyString(allocator, raw, "--plan");
    if (trimmed.len > 128) return error.InvalidPlanId;
    for (trimmed) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return error.InvalidPlanId;
    }
    if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) return error.InvalidPlanId;
    if (std.mem.indexOf(u8, trimmed, "..") != null) return error.InvalidPlanId;
    return allocator.dupe(u8, trimmed);
}

fn readLastJsonlLine(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const data = try durable_store.readRegularFileNoSymlink(allocator, path, 1024 * 1024);
    defer allocator.free(data);
    var last: []const u8 = "";
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len != 0) last = line;
    }
    if (last.len == 0) return error.WorkspaceInvalid;
    return allocator.dupe(u8, last);
}

fn workspacePlanGraphRefAlloc(allocator: std.mem.Allocator, plan_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "plans/{s}/plan.jsonl", .{plan_id});
}

fn renderInitialWorkspacePlanCheckpoint(allocator: std.mem.Allocator, plan_id: []const u8, now: []const u8) ![]u8 {
    const plan_id_json = try jsonStringAlloc(allocator, plan_id);
    defer allocator.free(plan_id_json);
    const now_json = try jsonStringAlloc(allocator, now);
    defer allocator.free(now_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"v\":4,\"ts\":{s},\"lane\":\"event\",\"seq\":1,\"op\":\"replace\",\"items\":[],\"graph\":{{\"version\":2,\"policy\":{{\"completion_requires_proof\":true}},\"intent\":[],\"waivers\":[],\"debt\":[],\"proof_actions\":[],\"polish\":{{\"session_id\":\"\",\"passes\":[]}},\"fingerprints\":{{}}}},\"mutation\":{{\"actor\":\"st\",\"session\":\"workspace-plan-create\"}}}}\n" ++
            "{{\"v\":4,\"ts\":{s},\"lane\":\"checkpoint\",\"seq\":1,\"plan_id\":{s},\"plan_sequence\":1,\"items\":[],\"graph\":{{\"version\":2,\"policy\":{{\"completion_requires_proof\":true}},\"intent\":[],\"waivers\":[],\"debt\":[],\"proof_actions\":[],\"polish\":{{\"session_id\":\"\",\"passes\":[]}},\"fingerprints\":{{}}}},\"mutation\":{{\"actor\":\"st\",\"session\":\"workspace-plan-create\"}}}}\n",
        .{ now_json, now_json, plan_id_json },
    );
}

fn renderMigratedWorkspaceCheckpoint(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    plan_id: []const u8,
    graph_ref: []const u8,
    plan_sequence: i64,
    fingerprints: GraphFingerprints,
    now: []const u8,
) ![]u8 {
    const workspace_json = try jsonStringAlloc(allocator, workspace_root);
    defer allocator.free(workspace_json);
    const now_json = try jsonStringAlloc(allocator, now);
    defer allocator.free(now_json);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"lane\":\"checkpoint\",\"schema\":\"STW-v1\",\"workspace_sequence\":1,\"artifact_root\":\".ledger\",\"st_root\":");
    try writer.writeAll(workspace_json);
    try writer.writeAll(",\"created_at\":");
    try writer.writeAll(now_json);
    try writer.writeAll(",\"updated_at\":");
    try writer.writeAll(now_json);
    try writer.writeAll(",\"target_branch\":null,\"target_head\":null,\"branch_epoch\":0,\"plans\":[{\"plan_id\":");
    try std.json.Stringify.value(plan_id, .{}, writer);
    try writer.writeAll(",\"alias\":");
    try std.json.Stringify.value(plan_id, .{}, writer);
    try writer.writeAll(",\"state\":\"active\",\"graph_ref\":");
    try std.json.Stringify.value(graph_ref, .{}, writer);
    try writer.writeAll(",\"target_branch\":null,\"source\":\"st workspace migrate\",\"plan_sequence\":");
    try writer.print("{d}", .{plan_sequence});
    try writer.writeAll(",\"graph_fingerprints\":");
    try writeGraphFingerprintsObject(writer, fingerprints);
    try writer.writeAll(",\"created_at\":");
    try writer.writeAll(now_json);
    try writer.writeAll(",\"updated_at\":");
    try writer.writeAll(now_json);
    try writer.writeAll("}],\"cross_plan_edges\":[],\"claims\":[],\"fencing_counter\":0,\"policy\":{\"fail_closed\":true,\"workspace_v1\":true,\"legacy_writes\":\"read_only_after_migration\"}}\n");
    return out.toOwnedSlice();
}

fn renderWorkspaceCheckpointWithPlan(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    previous: std.json.Value,
    plan_id: []const u8,
    alias: []const u8,
    now: []const u8,
) ![]u8 {
    const previous_obj = switch (previous) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const plans_value = previous_obj.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    const workspace_sequence = (intField(previous, "workspace_sequence") orelse 0) + 1;
    const artifact_root = stringField(previous, "artifact_root") orelse ".ledger";
    const st_root = stringField(previous, "st_root") orelse workspace_root;
    const created_at = stringField(previous, "created_at") orelse now;
    const graph_ref = try workspacePlanGraphRefAlloc(allocator, plan_id);
    defer allocator.free(graph_ref);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"lane\":\"checkpoint\",\"schema\":\"STW-v1\",\"workspace_sequence\":");
    try writer.print("{d}", .{workspace_sequence});
    try writer.writeAll(",\"artifact_root\":");
    try std.json.Stringify.value(artifact_root, .{}, writer);
    try writer.writeAll(",\"st_root\":");
    try std.json.Stringify.value(st_root, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(created_at, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll(",\"target_branch\":");
    try std.json.Stringify.value(previous_obj.get("target_branch") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"target_head\":");
    try std.json.Stringify.value(previous_obj.get("target_head") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{intField(previous, "branch_epoch") orelse 0});
    try writer.writeAll(",\"plans\":[");
    for (plans_value.array.items, 0..) |entry, idx| {
        if (idx != 0) try writer.writeByte(',');
        try std.json.Stringify.value(entry, .{}, writer);
    }
    if (plans_value.array.items.len != 0) try writer.writeByte(',');
    try writer.writeAll("{\"plan_id\":");
    try std.json.Stringify.value(plan_id, .{}, writer);
    try writer.writeAll(",\"alias\":");
    try std.json.Stringify.value(alias, .{}, writer);
    try writer.writeAll(",\"state\":\"active\",\"graph_ref\":");
    try std.json.Stringify.value(graph_ref, .{}, writer);
    try writer.writeAll(",\"target_branch\":");
    try std.json.Stringify.value(previous_obj.get("target_branch") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"source\":\"st plan create\",\"plan_sequence\":1,\"graph_fingerprints\":{},\"created_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll("}],\"cross_plan_edges\":");
    if (previous_obj.get("cross_plan_edges")) |cross_plan_edges| {
        try std.json.Stringify.value(cross_plan_edges, .{}, writer);
    } else {
        try writer.writeAll("[]");
    }
    try writeWorkspaceAuthorityFields(writer, previous_obj);
    try writer.writeAll(",\"policy\":");
    if (previous_obj.get("policy")) |policy| {
        try std.json.Stringify.value(policy, .{}, writer);
    } else {
        try writer.writeAll("{\"fail_closed\":true,\"workspace_v1\":true}");
    }
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn renderWorkspaceCheckpointWithPlanState(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    previous: std.json.Value,
    plan_id: []const u8,
    target_state: []const u8,
    now: []const u8,
) ![]u8 {
    const previous_obj = switch (previous) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const plans_value = previous_obj.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    const workspace_sequence = (intField(previous, "workspace_sequence") orelse 0) + 1;
    const artifact_root = stringField(previous, "artifact_root") orelse ".ledger";
    const st_root = stringField(previous, "st_root") orelse workspace_root;
    const created_at = stringField(previous, "created_at") orelse now;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"lane\":\"checkpoint\",\"schema\":\"STW-v1\",\"workspace_sequence\":");
    try writer.print("{d}", .{workspace_sequence});
    try writer.writeAll(",\"artifact_root\":");
    try std.json.Stringify.value(artifact_root, .{}, writer);
    try writer.writeAll(",\"st_root\":");
    try std.json.Stringify.value(st_root, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(created_at, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll(",\"target_branch\":");
    try std.json.Stringify.value(previous_obj.get("target_branch") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"target_head\":");
    try std.json.Stringify.value(previous_obj.get("target_head") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{intField(previous, "branch_epoch") orelse 0});
    try writer.writeAll(",\"plans\":[");
    for (plans_value.array.items, 0..) |entry, idx| {
        if (entry != .object) return error.WorkspaceInvalid;
        if (idx != 0) try writer.writeByte(',');
        const entry_plan_id = stringField(entry, "plan_id") orelse return error.WorkspaceInvalid;
        if (std.mem.eql(u8, entry_plan_id, plan_id)) {
            try writeWorkspacePlanRecordWithState(writer, entry, target_state, now);
        } else {
            try std.json.Stringify.value(entry, .{}, writer);
        }
    }
    try writer.writeAll("],\"cross_plan_edges\":");
    if (previous_obj.get("cross_plan_edges")) |cross_plan_edges| {
        try std.json.Stringify.value(cross_plan_edges, .{}, writer);
    } else {
        try writer.writeAll("[]");
    }
    try writeWorkspaceAuthorityFields(writer, previous_obj);
    try writer.writeAll(",\"policy\":");
    if (previous_obj.get("policy")) |policy| {
        try std.json.Stringify.value(policy, .{}, writer);
    } else {
        try writer.writeAll("{\"fail_closed\":true,\"workspace_v1\":true}");
    }
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn writeWorkspacePlanRecordWithState(writer: anytype, entry: std.json.Value, target_state: []const u8, now: []const u8) !void {
    const obj = switch (entry) {
        .object => |o| o,
        else => return error.WorkspaceInvalid,
    };
    try writer.writeByte('{');
    try writer.writeAll("\"plan_id\":");
    try std.json.Stringify.value(stringField(entry, "plan_id") orelse return error.WorkspaceInvalid, .{}, writer);
    try writer.writeAll(",\"alias\":");
    try std.json.Stringify.value(stringField(entry, "alias") orelse "", .{}, writer);
    try writer.writeAll(",\"state\":");
    try std.json.Stringify.value(target_state, .{}, writer);
    try writer.writeAll(",\"graph_ref\":");
    try std.json.Stringify.value(stringField(entry, "graph_ref") orelse return error.WorkspaceInvalid, .{}, writer);
    try writer.writeAll(",\"target_branch\":");
    try std.json.Stringify.value(obj.get("target_branch") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"source\":");
    try std.json.Stringify.value(stringField(entry, "source") orelse "", .{}, writer);
    try writer.writeAll(",\"plan_sequence\":");
    try writer.print("{d}", .{intField(entry, "plan_sequence") orelse 0});
    try writer.writeAll(",\"graph_fingerprints\":");
    try std.json.Stringify.value(obj.get("graph_fingerprints") orelse std.json.Value{ .object = .empty }, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(stringField(entry, "created_at") orelse now, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeByte('}');
}

fn renderWorkspaceCheckpointWithCrossPlanEdge(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    previous: std.json.Value,
    edge: CrossPlanEdge,
    op: CrossPlanEdgeOp,
    now: []const u8,
) ![]u8 {
    const previous_obj = switch (previous) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const plans_value = previous_obj.get("plans") orelse return error.WorkspaceInvalid;
    if (plans_value != .array) return error.WorkspaceInvalid;
    const edges_value = previous_obj.get("cross_plan_edges");
    if (edges_value) |value| {
        if (value != .array) return error.WorkspaceInvalid;
    }
    const workspace_sequence = (intField(previous, "workspace_sequence") orelse 0) + 1;
    const artifact_root = stringField(previous, "artifact_root") orelse ".ledger";
    const st_root = stringField(previous, "st_root") orelse workspace_root;
    const created_at = stringField(previous, "created_at") orelse now;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"lane\":\"checkpoint\",\"schema\":\"STW-v1\",\"workspace_sequence\":");
    try writer.print("{d}", .{workspace_sequence});
    try writer.writeAll(",\"artifact_root\":");
    try std.json.Stringify.value(artifact_root, .{}, writer);
    try writer.writeAll(",\"st_root\":");
    try std.json.Stringify.value(st_root, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(created_at, .{}, writer);
    try writer.writeAll(",\"updated_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeAll(",\"target_branch\":");
    try std.json.Stringify.value(previous_obj.get("target_branch") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"target_head\":");
    try std.json.Stringify.value(previous_obj.get("target_head") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"branch_epoch\":");
    try writer.print("{d}", .{intField(previous, "branch_epoch") orelse 0});
    try writer.writeAll(",\"plans\":");
    try std.json.Stringify.value(plans_value, .{}, writer);
    try writer.writeAll(",\"cross_plan_edges\":[");
    var wrote_edge = false;
    if (edges_value) |value| {
        for (value.array.items) |entry| {
            if (entry != .object) return error.WorkspaceInvalid;
            if (op == .unlink and crossPlanEdgeMatches(entry, edge)) continue;
            if (wrote_edge) try writer.writeByte(',');
            try std.json.Stringify.value(entry, .{}, writer);
            wrote_edge = true;
        }
    }
    if (op == .link) {
        if (wrote_edge) try writer.writeByte(',');
        try writeCrossPlanEdgeObject(writer, edge, now);
    }
    try writer.writeByte(']');
    try writeWorkspaceAuthorityFields(writer, previous_obj);
    try writer.writeAll(",\"policy\":");
    if (previous_obj.get("policy")) |policy| {
        try std.json.Stringify.value(policy, .{}, writer);
    } else {
        try writer.writeAll("{\"fail_closed\":true,\"workspace_v1\":true}");
    }
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn writeWorkspaceAuthorityFields(writer: anytype, previous_obj: std.json.ObjectMap) !void {
    try writer.writeAll(",\"claims\":");
    if (previous_obj.get("claims")) |claims| {
        try std.json.Stringify.value(claims, .{}, writer);
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeAll(",\"fencing_counter\":");
    if (previous_obj.get("fencing_counter")) |counter| {
        try std.json.Stringify.value(counter, .{}, writer);
    } else {
        try writer.writeAll("0");
    }
}

fn writeCrossPlanEdgeObject(writer: anytype, edge: CrossPlanEdge, now: []const u8) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"from\":");
    try std.json.Stringify.value(edge.from, .{}, writer);
    try writer.writeAll(",\"to\":");
    try std.json.Stringify.value(edge.to, .{}, writer);
    try writer.writeAll(",\"type\":");
    try std.json.Stringify.value(edge.edge_type, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(now, .{}, writer);
    try writer.writeByte('}');
}

fn jsonStringAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
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
    try renderShow(allocator, stdout, &state, args.format, args.surface, args.id);
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
        .debt => try cmdGraphDebt(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdIntake(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.intake_command) {
        .scaffold => try cmdIntakePlan(allocator, args),
        .plan => try cmdIntakePlan(allocator, args),
        .check => try cmdIntakeCheck(allocator, args),
        .normalize => try cmdIntakeNormalize(allocator, args),
        .apply => try cmdIntakeApply(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdCapabilities(allocator: std.mem.Allocator, args: Args) !u8 {
    _ = allocator;
    _ = args;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"st_capabilities\":{\"version\":");
    try std.json.Stringify.value(Version, .{}, stdout);
    try stdout.writeAll(",\"storage\":{\"ledger_artifact_root_v1\":true,\"workspace_v1\":true,\"workspace_schema\":\"STW-v1\",\"plan_graph_schema\":4,\"transaction_journal_v1\":true,\"compare_and_swap_v1\":true},\"plans\":{\"plan_namespace_v1\":true,\"qualified_refs_v1\":true,\"cross_plan_dependencies_v1\":true,\"plan_bundle_import_export_v1\":true},\"concurrency\":{\"workspace_claim_v1\":true,\"resource_grammar_v1\":true,\"fencing_token_v1\":true,\"session_view_v1\":true,\"workspace_aperture_v1\":true},\"git\":{\"external_worktree_v1\":true,\"changeset_v1\":true,\"serialized_integration_v1\":true,\"branch_epoch_v1\":true},\"proof\":{\"proof_receipt_v3\":true,\"dependency_cut_invalidation_v1\":true},\"control\":{\"gcr_v2\":true},\"schema_versions\":{\"readable\":[3,4],\"writable\":[3,4],\"graph_envelope\":[1,2]},\"features\":{\"intake_check\":true,\"intake_normalize\":true,\"graph_control_receipt\":true,\"gcr_v2\":true,\"safe_parallel_wave\":true,\"proof_basis\":true,\"multi_proof_receipts\":true,\"proof_receipt_v3\":true,\"proof_invalidation\":true,\"workspace_init\":true,\"workspace_status\":true,\"workspace_audit\":true,\"workspace_doctor\":true,\"workspace_recover\":true,\"workspace_export\":true,\"workspace_import\":true,\"workspace_migrate\":true,\"workspace_transactions\":true,\"resource_grammar\":true,\"workspace_claims\":true,\"fencing_tokens\":true,\"session_views\":true,\"workspace_aperture\":true,\"external_worktrees\":true,\"changesets\":true,\"serialized_integration\":true,\"plan_create\":true,\"plan_list\":true,\"plan_show\":true,\"plan_pause\":true,\"plan_resume\":true,\"plan_complete\":true,\"plan_archive\":true,\"qualified_refs\":true,\"plan_link\":true,\"plan_unlink\":true}}}\n");
    return 0;
}

fn cmdIntakePlan(allocator: std.mem.Allocator, args: Args) !u8 {
    const source = try requireNonEmptyString(allocator, args.source.?, "--source");
    const output_path = args.output.?;
    const payload = try std.fmt.allocPrint(allocator,
        \\# st graph intake
        \\
        \\Source: {s}
        \\
        \\## Intent
        \\
        \\- intent-001 | requirement | covered
        \\  Text: <material requirement from the source plan>
        \\  Source: {s}
        \\
        \\- intent-002 | test-expectation | covered
        \\  Text: <material validation expectation>
        \\  Source: {s}
        \\
        \\## Items
        \\
        \\### st-001 | feature | high
        \\
        \\Step: <actionable task title>
        \\
        \\Covers:
        \\- intent-001
        \\
        \\Depends:
        \\- none
        \\
        \\Locations:
        \\- <file-or-directory>
        \\- <test-file-or-directory>
        \\
        \\Acceptance:
        \\- <user-visible done criterion>
        \\- <another criterion>
        \\
        \\Validation:
        \\- <command that proves the work>
        \\
        \\Proof:
        \\- proof-001 | unit | <command that proves the work>
        \\
        \\Contract:
        \\Background:
        \\<Why this exists and what source-plan context must not be lost.>
        \\
        \\Objective:
        \\<What this item accomplishes.>
        \\
        \\Implementation Approach:
        \\<How to implement at a useful level of specificity.>
        \\
        \\Risks:
        \\- <risk or edge case>
        \\- <risk or edge case>
        \\
    , .{ source, source, source });
    try writeTextAtomic(allocator, output_path, payload);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("wrote intake scaffold: {s}\n", .{output_path});
    return 0;
}

fn cmdIntakeCheck(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const input_bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);
    const diagnostics = try collectIntakeDiagnostics(allocator, input_bytes);

    var parse_ok = diagnostics.len == 0;
    if (parse_ok) {
        _ = parseIntakeMarkdown(allocator, input_bytes, input_path) catch |err| {
            parse_ok = false;
            var mutable_diags = std.ArrayList(IntakeDiagnostic).empty;
            try mutable_diags.appendSlice(allocator, diagnostics);
            try mutable_diags.append(allocator, .{
                .severity = "error",
                .code = "parse-error",
                .line = 1,
                .path = "intake",
                .message = try std.fmt.allocPrint(allocator, "intake parser rejected input: {s}", .{@errorName(err)}),
                .suggested_fix = "Run st intake scaffold and fill each required field.",
            });
            return writeIntakeDiagnosticsExit(allocator, args, try mutable_diags.toOwnedSlice(allocator));
        };
    }
    return writeIntakeDiagnosticsExit(allocator, args, diagnostics);
}

fn writeIntakeDiagnosticsExit(allocator: std.mem.Allocator, args: Args, diagnostics: []const IntakeDiagnostic) !u8 {
    _ = allocator;
    const error_count = countIntakeDiagnostics(diagnostics, "error");
    const warning_count = countIntakeDiagnostics(diagnostics, "warning");
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (args.format == .json or args.format == .markdown) {
        try stdout.writeAll("{\"intake_check\":{\"ok\":");
        try stdout.writeAll(if (error_count == 0) "true" else "false");
        try stdout.writeAll(",\"errors\":");
        try stdout.print("{d}", .{error_count});
        try stdout.writeAll(",\"warnings\":");
        try stdout.print("{d}", .{warning_count});
        try stdout.writeAll(",\"diagnostics\":[");
        for (diagnostics, 0..) |diagnostic, idx| {
            if (idx > 0) try stdout.writeByte(',');
            try writeIntakeDiagnosticJson(stdout, diagnostic);
        }
        try stdout.writeAll("]}}\n");
    } else {
        try stdout.print("intake check: {s} ({d} error(s), {d} warning(s))\n", .{ if (error_count == 0) "PASS" else "FAIL", error_count, warning_count });
        for (diagnostics) |diagnostic| {
            try stdout.print("- {s}:{d}:{d} [{s}] {s}: {s}\n", .{ diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.severity, diagnostic.code, diagnostic.message });
        }
    }
    return if (error_count == 0) 0 else 2;
}

fn cmdIntakeNormalize(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const input_bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);
    const diagnostics = try collectIntakeDiagnostics(allocator, input_bytes);
    if (countIntakeDiagnostics(diagnostics, "error") != 0) {
        return writeIntakeDiagnosticsExit(allocator, args, diagnostics);
    }
    const intake = parseIntakeMarkdown(allocator, input_bytes, input_path) catch |err| {
        var mutable_diags = std.ArrayList(IntakeDiagnostic).empty;
        try mutable_diags.append(allocator, .{
            .severity = "error",
            .code = "parse-error",
            .line = 1,
            .path = "intake",
            .message = try std.fmt.allocPrint(allocator, "intake parser rejected input: {s}", .{@errorName(err)}),
            .suggested_fix = "Repair the reported material fields before normalization.",
        });
        return writeIntakeDiagnosticsExit(allocator, args, try mutable_diags.toOwnedSlice(allocator));
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeNormalizedIntakeMarkdown(&out.writer, intake);
    try writeTextAtomic(allocator, args.output.?, try out.toOwnedSlice());

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.print("wrote normalized intake: {s}\n", .{args.output.?});
    return 0;
}

fn collectIntakeDiagnostics(allocator: std.mem.Allocator, bytes: []const u8) ![]const IntakeDiagnostic {
    var diagnostics = std.ArrayList(IntakeDiagnostic).empty;
    var item_lines = std.StringHashMap(usize).init(allocator);
    var intent_lines = std.StringHashMap(usize).init(allocator);
    var dep_refs = std.ArrayList(struct { from: []const u8, to: []const u8, line: usize }).empty;
    var intent_refs = std.ArrayList(struct { item_id: []const u8, intent_id: []const u8, line: usize }).empty;

    var current_item: []const u8 = "";
    var section: IntakeSection = .none;
    var in_items = false;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(line, "## Intent")) {
            in_items = false;
            current_item = "";
            section = .none;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(line, "## Items")) {
            in_items = true;
            section = .none;
            continue;
        }

        if (std.mem.indexOfScalar(u8, line, '<') != null and std.mem.indexOfScalar(u8, line, '>') != null) {
            try appendIntakeDiagnostic(allocator, &diagnostics, "error", "placeholder-not-replaced", line_no, "intake", "unreplaced placeholder value", "Replace angle-bracket placeholder text with concrete intake content.");
        }

        if (!in_items and std.mem.startsWith(u8, line, "- intent-")) {
            const raw_fields = std.mem.trim(u8, line[2..], " \t\r\n");
            const id = pipeField(raw_fields, 0) orelse "";
            if (id.len == 0 or pipeField(raw_fields, 1) == null or pipeField(raw_fields, 2) == null) {
                try appendIntakeDiagnostic(allocator, &diagnostics, "error", "malformed-pipes", line_no, "intent", "intent row must be id | category | disposition", "Use: - intent-001 | requirement | covered");
            } else if (intent_lines.get(id)) |prior_line| {
                try appendIntakeDiagnostic(allocator, &diagnostics, "error", "duplicate-id", line_no, id, try std.fmt.allocPrint(allocator, "duplicate intent id; first seen on line {d}", .{prior_line}), "Use a unique stable intent id.");
            } else {
                try intent_lines.put(id, line_no);
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "### ")) {
            const raw_fields = std.mem.trim(u8, line[4..], " \t\r\n");
            const id = pipeField(raw_fields, 0) orelse "";
            current_item = id;
            in_items = true;
            section = .none;
            if (id.len == 0 or pipeField(raw_fields, 1) == null or pipeField(raw_fields, 2) == null) {
                try appendIntakeDiagnostic(allocator, &diagnostics, "error", "malformed-pipes", line_no, "items", "item heading must be id | type | priority", "Use: ### st-001 | feature | high");
            } else if (item_lines.get(id)) |prior_line| {
                try appendIntakeDiagnostic(allocator, &diagnostics, "error", "duplicate-id", line_no, id, try std.fmt.allocPrint(allocator, "duplicate item id; first seen on line {d}", .{prior_line}), "Use a unique stable item id.");
            } else {
                try item_lines.put(id, line_no);
            }
            continue;
        }

        if (std.mem.eql(u8, line, "Covers:")) {
            section = .covers;
            continue;
        }
        if (std.mem.eql(u8, line, "Depends:")) {
            section = .depends;
            continue;
        }
        if (std.mem.eql(u8, line, "Locations:")) {
            section = .locations;
            continue;
        }
        if (std.mem.eql(u8, line, "Acceptance:")) {
            section = .acceptance;
            continue;
        }
        if (std.mem.eql(u8, line, "Validation:")) {
            section = .validation;
            continue;
        }
        if (std.mem.eql(u8, line, "Proof:")) {
            section = .proof;
            continue;
        }
        if (std.mem.eql(u8, line, "Risks:")) {
            section = .risks;
            continue;
        }

        if (std.mem.startsWith(u8, line, "- ")) {
            const bullet = std.mem.trim(u8, line[2..], " \t\r\n");
            switch (section) {
                .depends => if (current_item.len > 0 and !std.ascii.eqlIgnoreCase(bullet, "none")) {
                    const dep = parseIntakeDep(allocator, bullet) catch {
                        try appendIntakeDiagnostic(allocator, &diagnostics, "error", "invalid-dependency", line_no, current_item, "dependency row is malformed", "Use: - st-001 | requires");
                        continue;
                    };
                    try dep_refs.append(allocator, .{ .from = current_item, .to = dep.id, .line = line_no });
                },
                .covers => if (current_item.len > 0) {
                    try intent_refs.append(allocator, .{ .item_id = current_item, .intent_id = bullet, .line = line_no });
                },
                else => {},
            }
        }
    }

    if (intent_lines.count() == 0) {
        try appendIntakeDiagnostic(allocator, &diagnostics, "error", "missing-section", 1, "intent", "no intent atoms found", "Add a ## Intent section with at least one intent row.");
    }
    if (item_lines.count() == 0) {
        try appendIntakeDiagnostic(allocator, &diagnostics, "error", "missing-section", 1, "items", "no items found", "Add a ## Items section with at least one item heading.");
    }

    for (dep_refs.items) |ref| {
        if (item_lines.get(ref.to) == null) {
            try appendIntakeDiagnostic(allocator, &diagnostics, "error", "unknown-dependency", ref.line, ref.from, try std.fmt.allocPrint(allocator, "unknown dependency target {s}", .{ref.to}), "Reference an existing item id or use none.");
        }
    }
    for (intent_refs.items) |ref| {
        if (intent_lines.get(ref.intent_id) == null) {
            try appendIntakeDiagnostic(allocator, &diagnostics, "error", "unknown-reference", ref.line, ref.item_id, try std.fmt.allocPrint(allocator, "unknown intent target {s}", .{ref.intent_id}), "Reference an existing intent id.");
        }
    }
    return diagnostics.toOwnedSlice(allocator);
}

fn appendIntakeDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(IntakeDiagnostic),
    severity: []const u8,
    code: []const u8,
    line: usize,
    path: []const u8,
    message: []const u8,
    suggested_fix: []const u8,
) !void {
    try diagnostics.append(allocator, .{
        .severity = severity,
        .code = code,
        .line = line,
        .path = path,
        .message = message,
        .suggested_fix = suggested_fix,
    });
}

fn countIntakeDiagnostics(diagnostics: []const IntakeDiagnostic, severity: []const u8) usize {
    var count: usize = 0;
    for (diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.severity, severity)) count += 1;
    }
    return count;
}

fn writeIntakeDiagnosticJson(writer: anytype, diagnostic: IntakeDiagnostic) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"severity\":");
    try std.json.Stringify.value(diagnostic.severity, .{}, writer);
    try writer.writeAll(",\"code\":");
    try std.json.Stringify.value(diagnostic.code, .{}, writer);
    try writer.writeAll(",\"line\":");
    try writer.print("{d}", .{diagnostic.line});
    try writer.writeAll(",\"column\":");
    try writer.print("{d}", .{diagnostic.column});
    try writer.writeAll(",\"path\":");
    try std.json.Stringify.value(diagnostic.path, .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(diagnostic.message, .{}, writer);
    try writer.writeAll(",\"suggested_fix\":");
    try std.json.Stringify.value(diagnostic.suggested_fix, .{}, writer);
    try writer.writeByte('}');
}

fn writeNormalizedIntakeMarkdown(writer: anytype, intake: ParsedIntake) !void {
    try writer.writeAll("# st graph intake\n\nSource: ");
    try writer.writeAll(intake.source);
    try writer.writeAll("\n\n## Intent\n\n");
    for (intake.intents) |intent| {
        try writer.print("- {s} | {s} | {s}\n", .{ intent.id, intent.category, intent.disposition });
        try writer.print("  Text: {s}\n", .{intent.text});
        if (intent.source) |source| {
            if (source.locator.len > 0) try writer.print("  Source: {s}\n", .{source.locator});
        }
        try writer.writeByte('\n');
    }
    try writer.writeAll("## Items\n\n");
    for (intake.items) |item| {
        try writer.print("### {s} | {s} | {s}\n\n", .{ item.id, item.item_type.asString(), item.priority.asString() });
        try writer.print("Step: {s}\n\nCovers:\n", .{item.step});
        if (item.intent_refs.len == 0) {
            try writer.writeAll("- none\n");
        } else for (item.intent_refs) |intent_ref| try writer.print("- {s}\n", .{intent_ref});
        try writer.writeAll("\nDepends:\n");
        if (item.deps.len == 0) {
            try writer.writeAll("- none\n");
        } else for (item.deps) |dep| try writer.print("- {s} | {s}\n", .{ dep.id, dep.type });
        try writer.writeAll("\nLocations:\n");
        for (item.location) |location| try writer.print("- {s}\n", .{location});
        try writer.writeAll("\nAcceptance:\n");
        for (item.acceptance) |acceptance| try writer.print("- {s}\n", .{acceptance});
        try writer.writeAll("\nValidation:\n");
        for (item.validation) |validation| try writer.print("- {s}\n", .{validation});
        try writer.writeAll("\nProof:\n");
        if (item.contract) |contract| {
            for (contract.proof_obligations) |obligation| try writer.print("- {s} | {s} | {s}\n", .{ obligation.id, obligation.kind, obligation.command });
            try writer.writeAll("\nContract:\n");
            try writer.print("Background:\n{s}\n\nObjective:\n{s}\n\nImplementation Approach:\n{s}\n\nRisks:\n", .{ contract.background, contract.objective, contract.implementation_approach });
            for (contract.risks) |risk| try writer.print("- {s}\n", .{risk});
        }
        try writer.writeByte('\n');
    }
}

fn cmdIntakeApply(allocator: std.mem.Allocator, args: Args) !u8 {
    const input_path = args.input.?;
    const input_bytes = try readFileAlloc(allocator, input_path, 32 * 1024 * 1024);
    const diagnostics = try collectIntakeDiagnostics(allocator, input_bytes);
    if (countIntakeDiagnostics(diagnostics, "error") != 0) {
        return writeIntakeDiagnosticsExit(allocator, args, diagnostics);
    }
    const intake = try parseIntakeMarkdown(allocator, input_bytes, input_path);

    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    state.graph_active = true;
    state.graph.version = GraphEnvelopeVersion;
    state.graph.policy.completion_requires_proof = true;
    state.graph.policy.graph_control_required = true;
    state.graph.policy.default_projection_strategy = "control-v2";
    state.graph.policy.default_parallelism = "auto";
    state.graph.policy.blocking_debt_policy = "block-material";
    const now = try nowUtcAlloc(allocator);
    state.graph.lineage = .{
        .mode = "compiled",
        .materiality = "material",
        .source = .{
            .kind = "markdown",
            .locator = intake.source,
            .fingerprint = try hashTextSha256Alloc(allocator, input_bytes),
        },
        .intake_id = try std.fmt.allocPrint(allocator, "intake-{d}", .{loaded.latest_seq + 1}),
        .compiled_at = now,
        .last_audited_seq = loaded.latest_seq + 1,
        .last_audit_gate = args.gate.asString(),
    };
    const intent_conflicts = try collectIntakeIntentConflictDiagnostics(allocator, state.graph, intake.intents, input_path);
    if (countIntakeDiagnostics(intent_conflicts, "error") != 0) {
        return writeIntakeDiagnosticsExit(allocator, args, intent_conflicts);
    }
    for (intake.intents) |intent| try upsertIntentAtom(allocator, &state.graph, intent);
    for (intake.items) |item| {
        var backlog_item = item;
        backlog_item.in_plan = false;
        normalizeItemPlanMembership(&backlog_item);
        try state.upsert(backlog_item);
    }
    state.graph.debt = try computeGraphDebtAlloc(allocator, &state, now);

    state.graph.fingerprints = try computeGraphFingerprints(allocator, &state);
    const audit = try auditGraph(allocator, &state, args.gate);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (audit.errors != 0) {
        try writeAuditSummaryJson(stdout, audit);
        try stdout.writeByte('\n');
        return 2;
    }
    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = now;
    const seq_after = loaded.latest_seq + 1;
    try writeCanonicalRecords(args.file, &state, seq_after, ts, meta, null);

    try emitPlanSyncWithPolicy(allocator, stdout, &state, .{ .source_file = args.file, .source_seq = seq_after }, true);
    try stdout.print(
        "st_receipt: {{\"kind\":\"graph_intake\",\"gate\":\"{s}\",\"items\":{d},\"intent\":{d},\"source\":",
        .{ args.gate.asString(), intake.items.len, intake.intents.len },
    );
    try std.json.Stringify.value(intake.source, .{}, stdout);
    try stdout.writeAll("}\n");
    return 0;
}

fn parseIntakeMarkdown(allocator: std.mem.Allocator, bytes: []const u8, fallback_source: []const u8) !ParsedIntake {
    var source = try requireNonEmptyString(allocator, fallback_source, "source");
    var intents = std.ArrayList(IntentAtom).empty;
    var items = std.ArrayList(Item).empty;
    var current_intent: ?IntakeIntentBuilder = null;
    var current_item: ?IntakeItemBuilder = null;
    var section: IntakeSection = .none;
    var in_items = false;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "```")) continue;

        if (std.mem.eql(u8, line, "## Intent")) {
            try finishIntakeItem(allocator, &current_item, &items, source);
            in_items = false;
            section = .none;
            continue;
        }
        if (std.mem.eql(u8, line, "## Items")) {
            try finishIntakeIntent(allocator, &current_intent, &intents, source);
            in_items = true;
            section = .none;
            continue;
        }
        if (std.mem.startsWith(u8, line, "Source:") and current_intent == null and !in_items) {
            source = try requireNonEmptyString(allocator, valueAfterPrefix(line, "Source:"), "source");
            continue;
        }
        if (std.mem.startsWith(u8, line, "- intent-") and !in_items) {
            try finishIntakeIntent(allocator, &current_intent, &intents, source);
            const raw_fields = std.mem.trim(u8, line[2..], " \t\r\n");
            current_intent = .{
                .id = try requireNonEmptyString(allocator, pipeField(raw_fields, 0) orelse return error.InvalidIntentAtom, "intent.id"),
                .category = try requireNonEmptyString(allocator, pipeField(raw_fields, 1) orelse return error.InvalidIntentAtom, "intent.category"),
                .disposition = try requireNonEmptyString(allocator, pipeField(raw_fields, 2) orelse return error.InvalidIntentAtom, "intent.disposition"),
            };
            section = .none;
            continue;
        }
        if (current_intent) |*intent| {
            if (std.mem.startsWith(u8, line, "Text:")) {
                intent.text = try requireNonEmptyString(allocator, valueAfterPrefix(line, "Text:"), "intent.text");
                continue;
            }
            if (std.mem.startsWith(u8, line, "Source:")) {
                intent.source_locator = try requireNonEmptyString(allocator, valueAfterPrefix(line, "Source:"), "intent.source");
                continue;
            }
        }

        if (std.mem.startsWith(u8, line, "### ")) {
            try finishIntakeIntent(allocator, &current_intent, &intents, source);
            try finishIntakeItem(allocator, &current_item, &items, source);
            const raw_fields = std.mem.trim(u8, line[4..], " \t\r\n");
            current_item = .{
                .id = try requireNonEmptyString(allocator, pipeField(raw_fields, 0) orelse return error.MissingItemId, "item.id"),
                .item_type = try normalizeItemType(pipeField(raw_fields, 1) orelse "task"),
                .priority = try normalizePriority(pipeField(raw_fields, 2) orelse "medium"),
            };
            in_items = true;
            section = .none;
            continue;
        }

        const item = if (current_item) |*item| item else continue;
        if (std.mem.startsWith(u8, line, "Step:")) {
            item.step = try requireNonEmptyString(allocator, valueAfterPrefix(line, "Step:"), "item.step");
            section = .none;
            continue;
        }
        if (std.mem.eql(u8, line, "Covers:")) {
            section = .covers;
            continue;
        }
        if (std.mem.eql(u8, line, "Depends:")) {
            section = .depends;
            continue;
        }
        if (std.mem.eql(u8, line, "Locations:")) {
            section = .locations;
            continue;
        }
        if (std.mem.eql(u8, line, "Acceptance:")) {
            section = .acceptance;
            continue;
        }
        if (std.mem.eql(u8, line, "Validation:")) {
            section = .validation;
            continue;
        }
        if (std.mem.eql(u8, line, "Proof:")) {
            section = .proof;
            continue;
        }
        if (std.mem.eql(u8, line, "Contract:")) {
            section = .none;
            continue;
        }
        if (std.mem.startsWith(u8, line, "Background:")) {
            section = .background;
            try appendInlineSectionText(allocator, &item.background, line, "Background:");
            continue;
        }
        if (std.mem.startsWith(u8, line, "Objective:")) {
            section = .objective;
            try appendInlineSectionText(allocator, &item.objective, line, "Objective:");
            continue;
        }
        if (std.mem.startsWith(u8, line, "Implementation Approach:")) {
            section = .approach;
            try appendInlineSectionText(allocator, &item.approach, line, "Implementation Approach:");
            continue;
        }
        if (std.mem.eql(u8, line, "Risks:")) {
            section = .risks;
            continue;
        }

        if (std.mem.startsWith(u8, line, "- ")) {
            const bullet = try requireNonEmptyString(allocator, line[2..], "intake.list_item");
            switch (section) {
                .covers => try item.covers.append(allocator, bullet),
                .depends => if (!std.ascii.eqlIgnoreCase(bullet, "none")) {
                    try item.deps.append(allocator, try parseIntakeDep(allocator, bullet));
                },
                .locations => try item.locations.append(allocator, bullet),
                .acceptance => try item.acceptance.append(allocator, bullet),
                .validation => try item.validation.append(allocator, bullet),
                .proof => try item.proof.append(allocator, try parseIntakeProof(allocator, bullet)),
                .risks => try item.risks.append(allocator, bullet),
                else => {},
            }
            continue;
        }

        switch (section) {
            .background => try appendParagraphLine(allocator, &item.background, line),
            .objective => try appendParagraphLine(allocator, &item.objective, line),
            .approach => try appendParagraphLine(allocator, &item.approach, line),
            else => {},
        }
    }

    try finishIntakeIntent(allocator, &current_intent, &intents, source);
    try finishIntakeItem(allocator, &current_item, &items, source);
    if (intents.items.len == 0) return error.InvalidIntentAtom;
    if (items.items.len == 0) return error.InvalidItem;

    return .{
        .source = source,
        .intents = try intents.toOwnedSlice(allocator),
        .items = try items.toOwnedSlice(allocator),
    };
}

fn finishIntakeIntent(
    allocator: std.mem.Allocator,
    current: *?IntakeIntentBuilder,
    intents: *std.ArrayList(IntentAtom),
    default_source: []const u8,
) !void {
    const builder = current.* orelse return;
    const text = try requireNonEmptyString(allocator, builder.text, "intent.text");
    const locator = if (builder.source_locator.len > 0) builder.source_locator else default_source;
    try intents.append(allocator, .{
        .id = builder.id,
        .source = .{ .kind = "markdown", .locator = locator },
        .text = text,
        .category = builder.category,
        .disposition = builder.disposition,
    });
    current.* = null;
}

fn finishIntakeItem(
    allocator: std.mem.Allocator,
    current: *?IntakeItemBuilder,
    items: *std.ArrayList(Item),
    source: []const u8,
) !void {
    var builder = current.* orelse return;
    const step = try requireNonEmptyString(allocator, builder.step, "item.step");
    const locations = try builder.locations.toOwnedSlice(allocator);
    const acceptance = try builder.acceptance.toOwnedSlice(allocator);
    const validation = try builder.validation.toOwnedSlice(allocator);
    const proof = try builder.proof.toOwnedSlice(allocator);
    const risks = try builder.risks.toOwnedSlice(allocator);
    const objective = if (builder.objective.items.len > 0)
        try builder.objective.toOwnedSlice(allocator)
    else
        step;
    const background = if (builder.background.items.len > 0)
        try builder.background.toOwnedSlice(allocator)
    else
        "";
    const approach = if (builder.approach.items.len > 0)
        try builder.approach.toOwnedSlice(allocator)
    else
        "";
    var item = Item{
        .id = builder.id,
        .step = step,
        .status = .pending,
        .priority = builder.priority,
        .in_plan = true,
        .deps = try builder.deps.toOwnedSlice(allocator),
        .notes = "",
        .comments = &.{},
        .location = locations,
        .validation = validation,
        .source = .{ .kind = "intake", .locator = source },
        .item_type = builder.item_type,
        .intent_refs = try builder.covers.toOwnedSlice(allocator),
        .acceptance = acceptance,
        .contract = .{
            .objective = objective,
            .background = background,
            .implementation_approach = approach,
            .success_criteria = acceptance,
            .proof_obligations = proof,
            .risks = risks,
        },
        .lock_roots = locations,
    };
    normalizeItemPlanMembership(&item);
    try items.append(allocator, item);
    current.* = null;
}

fn valueAfterPrefix(line: []const u8, prefix: []const u8) []const u8 {
    return std.mem.trim(u8, line[prefix.len..], " \t\r\n");
}

fn pipeField(raw: []const u8, wanted: usize) ?[]const u8 {
    var it = std.mem.splitScalar(u8, raw, '|');
    var idx: usize = 0;
    while (it.next()) |field| : (idx += 1) {
        if (idx == wanted) {
            const trimmed = std.mem.trim(u8, field, " \t\r\n");
            if (trimmed.len == 0) return null;
            return trimmed;
        }
    }
    return null;
}

fn parseIntakeDep(allocator: std.mem.Allocator, raw: []const u8) !Dep {
    const id_raw = pipeField(raw, 0) orelse raw;
    var parts = std.mem.splitScalar(u8, id_raw, ':');
    const id = try requireNonEmptyString(allocator, parts.next() orelse return error.MissingItemId, "dep.id");
    const dep_type = if (parts.next()) |raw_type|
        try requireNonEmptyString(allocator, raw_type, "dep.type")
    else
        "requires";
    return .{ .id = id, .type = dep_type };
}

fn parseIntakeProof(allocator: std.mem.Allocator, raw: []const u8) !ProofObligation {
    return .{
        .id = try requireNonEmptyString(allocator, pipeField(raw, 0) orelse return error.InvalidProofObligation, "proof.id"),
        .kind = try requireNonEmptyString(allocator, pipeField(raw, 1) orelse return error.InvalidProofObligation, "proof.kind"),
        .command = if (pipeTailField(raw, 2)) |command|
            try requireNonEmptyString(allocator, command, "proof.command")
        else
            "",
    };
}

fn pipeTailField(raw: []const u8, wanted: usize) ?[]const u8 {
    var bars_seen: usize = 0;
    for (raw, 0..) |byte, idx| {
        if (byte != '|') continue;
        bars_seen += 1;
        if (bars_seen == wanted) {
            const trimmed = std.mem.trim(u8, raw[idx + 1 ..], " \t\r\n");
            if (trimmed.len == 0) return null;
            return trimmed;
        }
    }
    return if (wanted == 0) std.mem.trim(u8, raw, " \t\r\n") else null;
}

fn appendInlineSectionText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8, prefix: []const u8) !void {
    const value = valueAfterPrefix(line, prefix);
    if (value.len > 0) try appendParagraphLine(allocator, out, value);
}

fn appendParagraphLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    const text = std.mem.trim(u8, line, " \t\r\n");
    if (text.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, text);
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

    state.graph.fingerprints = try computeGraphFingerprints(allocator, &state);
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

    const validity_audit = try auditGraph(allocator, &state, .draft);
    state.graph.fingerprints = try computeGraphFingerprints(allocator, &state);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (auditHasGraphValidityErrors(validity_audit)) {
        if (args.format == .json) {
            try writeAuditResultJson(stdout, &state, validity_audit);
            try stdout.writeByte('\n');
        } else {
            try writeAuditResultMarkdown(stdout, validity_audit);
        }
        return 2;
    }
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
        .delta = polishDeltaFromPrevious(state.graph.polish.passes, fps),
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

fn cmdGraphDebt(allocator: std.mem.Allocator, args: Args) !u8 {
    return switch (args.debt_command) {
        .list => try cmdGraphDebtList(allocator, args),
        .waive => try cmdGraphDebtWaive(allocator, args),
        .resolve => try cmdGraphDebtResolve(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdGraphDebtList(allocator: std.mem.Allocator, args: Args) !u8 {
    const parsed = try readRecords(allocator, args.file);
    var state = try materializeStateFromRecords(allocator, parsed.records);
    defer state.deinit();
    const now = try nowUtcAlloc(allocator);
    const debts = try computeGraphDebtAlloc(allocator, &state, now);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"graph_debt\":{\"blocking\":");
    try writeGraphDebtFilteredArray(stdout, debts, "blocking");
    try stdout.writeAll(",\"warnings\":");
    try writeGraphDebtFilteredArray(stdout, debts, "warning");
    try stdout.writeAll("}}\n");
    return 0;
}

fn cmdGraphDebtWaive(allocator: std.mem.Allocator, args: Args) !u8 {
    return try mutateGraphDebtRecord(allocator, args, .waive);
}

fn cmdGraphDebtResolve(allocator: std.mem.Allocator, args: Args) !u8 {
    return try mutateGraphDebtRecord(allocator, args, .resolve);
}

const DebtMutation = enum { waive, resolve };

fn mutateGraphDebtRecord(allocator: std.mem.Allocator, args: Args, mutation: DebtMutation) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();
    state.graph_active = true;
    state.graph.version = GraphEnvelopeVersion;
    const now = try nowUtcAlloc(allocator);
    state.graph.debt = try computeGraphDebtAlloc(allocator, &state, now);

    var found = false;
    var debts = std.ArrayList(GraphDebt).empty;
    for (state.graph.debt) |debt| {
        var next = debt;
        if (std.mem.eql(u8, debt.id, args.id.?)) {
            found = true;
            switch (mutation) {
                .waive => {
                    next.waiver_id = try std.fmt.allocPrint(allocator, "waiver-{s}", .{debt.id});
                    try upsertWaiver(allocator, &state.graph, .{
                        .id = next.waiver_id,
                        .gate = "graph-debt",
                        .code = debt.code,
                        .target = debt.target,
                        .reason = args.reason.?,
                        .expires = "on-next-touch",
                        .created_at = now,
                        .created_by = "codex",
                    });
                },
                .resolve => next.resolved_at = now,
            }
        }
        try debts.append(allocator, next);
    }
    if (!found) return error.UnknownItemId;
    state.graph.debt = try debts.toOwnedSlice(allocator);
    try validateState(&state, args.allow_multiple_in_progress);

    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    try stdout_writer.interface.print("graph debt {s}: {s}\n", .{ @tagName(mutation), args.id.? });
    return 0;
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

    const baseline = try graphDeltaBaselineAlloc(allocator, &state);
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
    const delta = try computeGraphDelta(allocator, baseline, &state, loaded.latest_seq, seq_after);
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
    const parsed = try readRecords(allocator, args.file);
    var state = try materializeStateFromRecords(allocator, parsed.records);
    defer state.deinit();

    const validity_audit = try auditGraph(allocator, &state, .draft);
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    if (auditHasGraphValidityErrors(validity_audit)) {
        const fps = try computeGraphFingerprints(allocator, &state);
        const receipt_id = try gcrReceiptIdAlloc(allocator, parsed.latest_seq, fps.structure);
        try stdout.writeAll("graph_control_receipt: ");
        try writeGraphControlReceiptJson(allocator, stdout, &state, args.file, parsed.latest_seq, fps, validity_audit, &.{}, args.limit, receipt_id);
        try stdout.writeByte('\n');
        try maybeWriteWorkspaceGraphControlReceiptJson(allocator, stdout, args, &state, parsed.latest_seq, fps, validity_audit, &.{}, receipt_id, true);
        try stdout.writeAll("st_receipt: ");
        try writeStReceiptJson(stdout, "st compile aperture", "gate_blocked", 2, args.file, parsed.latest_seq, parsed.latest_seq, state.graph_active, receipt_id, &.{"invalid-graph"});
        try stdout.writeByte('\n');
        return 2;
    }

    _ = try applyPrimeSelection(allocator, &state, .aperture, args.limit);
    try validateState(&state, args.allow_multiple_in_progress);
    const now = try nowUtcAlloc(allocator);
    state.graph.debt = try computeGraphDebtAlloc(allocator, &state, now);

    const seq_after = if (args.preview) parsed.latest_seq else parsed.latest_seq + 1;
    const fps = try computeGraphFingerprints(allocator, &state);
    state.graph.fingerprints = fps;
    const audit = try auditGraph(allocator, &state, .execution_ready);
    const selected_ids = try selectedInPlanIdsAlloc(allocator, &state);
    const receipt_id = try gcrReceiptIdAlloc(allocator, seq_after, fps.structure);
    const gate_blocked = audit.errors != 0 or countActiveGraphDebt(state.graph.debt, "blocking") != 0;

    if (gate_blocked) {
        const blocked_receipt_id = try gcrReceiptIdAlloc(allocator, parsed.latest_seq, fps.structure);
        try stdout.writeAll("graph_control_receipt: ");
        try writeGraphControlReceiptJson(allocator, stdout, &state, args.file, parsed.latest_seq, fps, audit, selected_ids, args.limit, blocked_receipt_id);
        try stdout.writeByte('\n');
        try maybeWriteWorkspaceGraphControlReceiptJson(allocator, stdout, args, &state, parsed.latest_seq, fps, audit, selected_ids, blocked_receipt_id, true);
        try stdout.writeAll("st_receipt: ");
        try writeStReceiptJson(stdout, "st compile aperture", "gate_blocked", 2, args.file, parsed.latest_seq, parsed.latest_seq, state.graph_active, blocked_receipt_id, &.{"execution-gate-blocked"});
        try stdout.writeByte('\n');
        return 2;
    }

    if (!args.preview) {
        const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
        const ts = try nowUtcAlloc(allocator);
        try writeCanonicalRecords(args.file, &state, seq_after, ts, meta, null);
    }

    try stdout.writeAll("graph_control_receipt: ");
    try writeGraphControlReceiptJson(allocator, stdout, &state, args.file, seq_after, fps, audit, selected_ids, args.limit, receipt_id);
    try stdout.writeByte('\n');
    try maybeWriteWorkspaceGraphControlReceiptJson(allocator, stdout, args, &state, seq_after, fps, audit, selected_ids, receipt_id, false);
    try emitPlanSyncWithPolicy(allocator, stdout, &state, .{ .source_file = args.file, .source_seq = seq_after, .mode = .aperture, .limit = args.limit }, true);
    try stdout.writeAll("st_receipt: ");
    try writeStReceiptJson(stdout, "st compile aperture", "success", 0, args.file, parsed.latest_seq, seq_after, state.graph_active, receipt_id, &.{});
    try stdout.writeByte('\n');
    return 0;
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

fn findIntentAtom(graph: GraphEnvelope, id: []const u8) ?IntentAtom {
    for (graph.intent) |atom| {
        if (std.mem.eql(u8, atom.id, id)) return atom;
    }
    return null;
}

fn intentSourceEqual(lhs: ?IntentSource, rhs: ?IntentSource) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?.kind, rhs.?.kind) and
        std.mem.eql(u8, lhs.?.locator, rhs.?.locator) and
        std.mem.eql(u8, lhs.?.anchor, rhs.?.anchor);
}

fn intentAtomEqual(lhs: IntentAtom, rhs: IntentAtom) bool {
    return std.mem.eql(u8, lhs.id, rhs.id) and
        intentSourceEqual(lhs.source, rhs.source) and
        std.mem.eql(u8, lhs.text, rhs.text) and
        std.mem.eql(u8, lhs.category, rhs.category) and
        std.mem.eql(u8, lhs.disposition, rhs.disposition) and
        std.mem.eql(u8, lhs.reason, rhs.reason);
}

fn collectIntakeIntentConflictDiagnostics(
    allocator: std.mem.Allocator,
    graph: GraphEnvelope,
    intents: []const IntentAtom,
    path: []const u8,
) ![]const IntakeDiagnostic {
    var diagnostics = std.ArrayList(IntakeDiagnostic).empty;
    for (intents) |intent| {
        const existing = findIntentAtom(graph, intent.id) orelse continue;
        if (intentAtomEqual(existing, intent)) continue;
        const message = try std.fmt.allocPrint(allocator, "intake intent id '{s}' conflicts with an existing graph intent atom", .{intent.id});
        try appendIntakeDiagnostic(
            allocator,
            &diagnostics,
            "error",
            "conflicting-intent-id",
            1,
            path,
            message,
            "Use a new intent id or submit an identical atom.",
        );
    }
    return try diagnostics.toOwnedSlice(allocator);
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

fn graphDeltaBaselineAlloc(allocator: std.mem.Allocator, state: *const ItemState) !GraphDeltaBaseline {
    var item_ids = std.ArrayList([]const u8).empty;
    var item_fps = std.ArrayList(ItemFingerprint).empty;
    var dep_edges = std.ArrayList([]const u8).empty;
    var link_edges = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| {
        try item_ids.append(allocator, item.id);
        try item_fps.append(allocator, .{ .id = item.id, .fingerprint = try itemFingerprintAlloc(allocator, item) });
        for (item.deps) |dep| {
            try dep_edges.append(allocator, try std.fmt.allocPrint(allocator, "{s}->{s}:{s}", .{ item.id, dep.id, dep.type }));
        }
        for (item.links) |link| {
            try link_edges.append(allocator, try std.fmt.allocPrint(allocator, "{s}->{s}:{s}", .{ item.id, link.id, link.type }));
        }
    }
    var intent_ids = std.ArrayList([]const u8).empty;
    var intent_coverage = std.ArrayList([]const u8).empty;
    for (state.graph.intent) |atom| {
        try intent_ids.append(allocator, atom.id);
        try intent_coverage.append(allocator, try std.fmt.allocPrint(allocator, "{s}:{s}", .{ atom.id, atom.disposition }));
    }
    return .{
        .item_ids = try item_ids.toOwnedSlice(allocator),
        .item_fingerprints = try item_fps.toOwnedSlice(allocator),
        .dep_edges = try dep_edges.toOwnedSlice(allocator),
        .link_edges = try link_edges.toOwnedSlice(allocator),
        .intent_ids = try intent_ids.toOwnedSlice(allocator),
        .intent_coverage = try intent_coverage.toOwnedSlice(allocator),
        .fingerprints = try computeGraphFingerprints(allocator, state),
    };
}

fn computeGraphDelta(allocator: std.mem.Allocator, baseline: GraphDeltaBaseline, state: *const ItemState, seq_before: i64, seq_after: i64) !GraphDelta {
    var added = std.ArrayList([]const u8).empty;
    var changed = std.ArrayList([]const u8).empty;
    var dep_edges = std.ArrayList([]const u8).empty;
    var link_edges = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| {
        if (!containsString(baseline.item_ids, item.id)) {
            try added.append(allocator, item.id);
        } else if (!std.mem.eql(u8, findItemFingerprint(baseline.item_fingerprints, item.id) orelse "", try itemFingerprintAlloc(allocator, item))) {
            try changed.append(allocator, item.id);
        }
        for (item.deps) |dep| {
            try dep_edges.append(allocator, try std.fmt.allocPrint(allocator, "{s}->{s}:{s}", .{ item.id, dep.id, dep.type }));
        }
        for (item.links) |link| {
            try link_edges.append(allocator, try std.fmt.allocPrint(allocator, "{s}->{s}:{s}", .{ item.id, link.id, link.type }));
        }
    }
    var removed = std.ArrayList([]const u8).empty;
    for (baseline.item_ids) |id| {
        if (state.getConst(id) == null) try removed.append(allocator, id);
    }
    var intent_ids = std.ArrayList([]const u8).empty;
    var intent_coverage = std.ArrayList([]const u8).empty;
    for (state.graph.intent) |atom| {
        try intent_ids.append(allocator, atom.id);
        try intent_coverage.append(allocator, try std.fmt.allocPrint(allocator, "{s}:{s}", .{ atom.id, atom.disposition }));
    }
    return .{
        .seq_before = seq_before,
        .seq_after = seq_after,
        .items_added = try added.toOwnedSlice(allocator),
        .items_removed = try removed.toOwnedSlice(allocator),
        .items_changed = try changed.toOwnedSlice(allocator),
        .deps_added = try listAddedAlloc(allocator, baseline.dep_edges, dep_edges.items),
        .deps_removed = try listRemovedAlloc(allocator, baseline.dep_edges, dep_edges.items),
        .links_added = try listAddedAlloc(allocator, baseline.link_edges, link_edges.items),
        .links_removed = try listRemovedAlloc(allocator, baseline.link_edges, link_edges.items),
        .intent_added = try listAddedAlloc(allocator, baseline.intent_ids, intent_ids.items),
        .intent_removed = try listRemovedAlloc(allocator, baseline.intent_ids, intent_ids.items),
        .intent_coverage_changed = try listSymmetricChangedAlloc(allocator, baseline.intent_coverage, intent_coverage.items),
        .fingerprints_before = baseline.fingerprints,
        .fingerprints_after = try computeGraphFingerprints(allocator, state),
    };
}

fn itemFingerprintAlloc(allocator: std.mem.Allocator, item: Item) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeItemObject(&out.writer, item);
    return try hashTextSha256Alloc(allocator, try out.toOwnedSlice());
}

fn findItemFingerprint(fingerprints: []const ItemFingerprint, id: []const u8) ?[]const u8 {
    for (fingerprints) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry.fingerprint;
    }
    return null;
}

fn listAddedAlloc(allocator: std.mem.Allocator, before: []const []const u8, after: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (after) |value| {
        if (!containsString(before, value)) try out.append(allocator, value);
    }
    return try out.toOwnedSlice(allocator);
}

fn listRemovedAlloc(allocator: std.mem.Allocator, before: []const []const u8, after: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (before) |value| {
        if (!containsString(after, value)) try out.append(allocator, value);
    }
    return try out.toOwnedSlice(allocator);
}

fn listSymmetricChangedAlloc(allocator: std.mem.Allocator, before: []const []const u8, after: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (after) |value| {
        if (!containsString(before, value)) try out.append(allocator, value);
    }
    for (before) |value| {
        if (!containsString(after, value)) try out.append(allocator, value);
    }
    return try out.toOwnedSlice(allocator);
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

fn auditHasGraphValidityErrors(audit: AuditResult) bool {
    for (audit.findings) |finding| {
        if (finding.waived or finding.severity != .@"error") continue;
        if (std.mem.eql(u8, finding.code, "unknown-dependency") or
            std.mem.eql(u8, finding.code, "self-dependency") or
            std.mem.eql(u8, finding.code, "dependency-cycle"))
        {
            return true;
        }
    }
    return false;
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
        if (itemRequiresImplementationReadyCapsule(item) and item.contract == null) {
            try addFinding(allocator, state, gate, findings, "missing-contract", .warning, item.id, "Executable item has no structured contract.");
        }
        if (itemRequiresImplementationReadyCapsule(item) and item.acceptance.len == 0) {
            try addFinding(allocator, state, gate, findings, "missing-acceptance", .warning, item.id, "Executable item has no acceptance criteria.");
        }
        if (itemRequiresImplementationReadyCapsule(item) and item.validation.len == 0 and !itemHasProofObligations(item)) {
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
        if (!itemRequiresImplementationReadyCapsule(item)) continue;
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

fn itemRequiresImplementationReadyCapsule(item: Item) bool {
    return isExecutableItem(item) and !isTerminalStatus(item.status);
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
    if (item.proof_receipts.len > 0) {
        for (obligations) |obligation| {
            if (!obligation.required) continue;
            if (obligation.command.len == 0 and proofKindUsuallyNeedsCommand(obligation.kind)) return "required proof obligation is missing a command";
            if (!proofReceiptSatisfiesObligation(item.proof_receipts, obligation)) return "missing passing proof receipt for required obligation";
        }
        return null;
    }
    const proof = item.proof orelse return "missing required proof receipt";
    if (hasMultipleDistinctRequiredProofCommands(obligations)) return "legacy proof cannot satisfy multiple distinct required commands";
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

fn proofReceiptSatisfiesObligation(receipts: []const ProofReceipt, obligation: ProofObligation) bool {
    for (receipts) |receipt| {
        if (!std.mem.eql(u8, receipt.obligation_id, obligation.id)) continue;
        if (!std.mem.eql(u8, receipt.state, "pass")) continue;
        if (receipt.evidence_ref.len == 0) continue;
        if (obligation.command.len > 0 and !std.mem.eql(u8, receipt.command, obligation.command)) continue;
        return true;
    }
    return false;
}

fn hasMultipleDistinctRequiredProofCommands(obligations: []const ProofObligation) bool {
    var first: ?[]const u8 = null;
    for (obligations) |obligation| {
        if (!obligation.required or obligation.command.len == 0) continue;
        if (first == null) {
            first = obligation.command;
            continue;
        }
        if (!std.mem.eql(u8, first.?, obligation.command)) return true;
    }
    return false;
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

fn upsertProofReceipt(allocator: std.mem.Allocator, item: *Item, receipt: ProofReceipt) !void {
    var out = std.ArrayList(ProofReceipt).empty;
    var replaced = false;
    for (item.proof_receipts) |existing| {
        if (std.mem.eql(u8, existing.obligation_id, receipt.obligation_id) and
            std.mem.eql(u8, existing.action_id, receipt.action_id))
        {
            try out.append(allocator, receipt);
            replaced = true;
        } else {
            try out.append(allocator, existing);
        }
    }
    if (!replaced) try out.append(allocator, receipt);
    item.proof_receipts = try out.toOwnedSlice(allocator);
}

fn timestampArgOrNowAlloc(allocator: std.mem.Allocator, raw: ?[]const u8) ![]const u8 {
    if (raw) |value| return try requireNonEmptyString(allocator, value, "--now");
    return try nowUtcAlloc(allocator);
}

fn proofObligationCommandMatches(obligation: ProofObligation, command: []const u8) bool {
    return obligation.command.len == 0 or std.mem.eql(u8, obligation.command, command);
}

fn maybeLegacyReceiptForCommand(allocator: std.mem.Allocator, item: *Item, proof: ProofMeta, proof_id: ?[]const u8) !void {
    if (proof_id) |raw_id| {
        const obligation_id = try requireNonEmptyString(allocator, raw_id, "--proof-id");
        const obligation = findProofObligation(item.*, obligation_id) orelse return error.InvalidProofObligation;
        if (!proofObligationCommandMatches(obligation, proof.command)) return error.InvalidProofObligation;
        try upsertProofReceipt(allocator, item, .{
            .obligation_id = obligation.id,
            .action_id = "legacy-single-proof",
            .state = proof.state.asString(),
            .command = proof.command,
            .evidence_ref = proof.evidence_ref,
            .recorded_at = proof.last_run_at,
        });
        return;
    }

    const obligations = proofObligationsForItem(item.*);
    var matched: ?ProofObligation = null;
    for (obligations) |obligation| {
        if (!obligation.required) continue;
        if (proofObligationCommandMatches(obligation, proof.command)) {
            if (matched != null and !std.mem.eql(u8, matched.?.id, obligation.id)) return;
            matched = obligation;
        }
    }
    if (matched) |obligation| {
        try upsertProofReceipt(allocator, item, .{
            .obligation_id = obligation.id,
            .action_id = "legacy-single-proof",
            .state = proof.state.asString(),
            .command = proof.command,
            .evidence_ref = proof.evidence_ref,
            .recorded_at = proof.last_run_at,
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
    var index = try buildGraphIndex(allocator, state);
    defer index.deinit(allocator);
    if (index.cycle_witness.len == 0) return;

    const target_index = index.cycle_witness[0];
    const target = state.items.items[target_index].id;
    const message = try cycleWitnessMessage(allocator, state, index.cycle_witness);
    try addFinding(allocator, state, gate, findings, "dependency-cycle", .@"error", target, message);
}

fn buildGraphIndex(allocator: std.mem.Allocator, state: *const ItemState) !GraphIndex {
    const n = state.items.items.len;
    var item_index_by_id = std.StringHashMap(usize).init(allocator);
    errdefer item_index_by_id.deinit();

    for (state.items.items, 0..) |item, idx| {
        const entry = try item_index_by_id.getOrPut(item.id);
        if (entry.found_existing) return error.DuplicateItemId;
        entry.value_ptr.* = idx;
    }

    var predecessor_builders = try allocator.alloc(std.ArrayList(usize), n);
    defer allocator.free(predecessor_builders);
    var successor_builders = try allocator.alloc(std.ArrayList(usize), n);
    defer allocator.free(successor_builders);
    for (0..n) |idx| {
        predecessor_builders[idx] = .empty;
        successor_builders[idx] = .empty;
    }
    errdefer {
        for (predecessor_builders) |*list| list.deinit(allocator);
        for (successor_builders) |*list| list.deinit(allocator);
    }

    var dangling_item_id: ?[]const u8 = null;
    var dangling_dep_id: ?[]const u8 = null;
    for (state.items.items, 0..) |item, item_idx| {
        for (item.deps) |dep| {
            const predecessor_idx = item_index_by_id.get(dep.id) orelse {
                if (dangling_dep_id == null) {
                    dangling_item_id = item.id;
                    dangling_dep_id = dep.id;
                }
                continue;
            };
            try predecessor_builders[item_idx].append(allocator, predecessor_idx);
            try successor_builders[predecessor_idx].append(allocator, item_idx);
        }
    }

    var predecessors = try allocator.alloc([]const usize, n);
    errdefer {
        for (predecessors) |slice| allocator.free(slice);
        allocator.free(predecessors);
    }
    var successors = try allocator.alloc([]const usize, n);
    errdefer {
        for (successors) |slice| allocator.free(slice);
        allocator.free(successors);
    }
    for (0..n) |idx| {
        predecessors[idx] = try predecessor_builders[idx].toOwnedSlice(allocator);
        successors[idx] = try successor_builders[idx].toOwnedSlice(allocator);
    }

    var indegree = try allocator.alloc(usize, n);
    defer allocator.free(indegree);
    for (predecessors, 0..) |preds, idx| indegree[idx] = preds.len;

    var ready = std.ArrayList(usize).empty;
    defer ready.deinit(allocator);
    for (indegree, 0..) |degree, idx| {
        if (degree == 0) try ready.append(allocator, idx);
    }

    var topological_order_list = std.ArrayList(usize).empty;
    var cursor: usize = 0;
    while (cursor < ready.items.len) : (cursor += 1) {
        const node_idx = ready.items[cursor];
        try topological_order_list.append(allocator, node_idx);
        for (successors[node_idx]) |successor_idx| {
            indegree[successor_idx] -= 1;
            if (indegree[successor_idx] == 0) try ready.append(allocator, successor_idx);
        }
    }
    const topological_order = try topological_order_list.toOwnedSlice(allocator);
    errdefer allocator.free(topological_order);

    const reverse_topological_order = try allocator.alloc(usize, topological_order.len);
    errdefer allocator.free(reverse_topological_order);
    for (topological_order, 0..) |node_idx, idx| {
        reverse_topological_order[topological_order.len - 1 - idx] = node_idx;
    }

    const cycle_witness = if (dangling_dep_id == null and topological_order.len != n)
        try cycleWitnessFromIndex(allocator, predecessors, topological_order)
    else
        &.{};
    errdefer allocator.free(cycle_witness);

    return .{
        .item_index_by_id = item_index_by_id,
        .predecessors = predecessors,
        .successors = successors,
        .topological_order = topological_order,
        .reverse_topological_order = reverse_topological_order,
        .dangling_item_id = dangling_item_id,
        .dangling_dep_id = dangling_dep_id,
        .cycle_witness = cycle_witness,
    };
}

fn cycleWitnessFromIndex(allocator: std.mem.Allocator, predecessors: []const []const usize, topological_order: []const usize) ![]const usize {
    var processed = try allocator.alloc(bool, predecessors.len);
    defer allocator.free(processed);
    @memset(processed, false);
    for (topological_order) |idx| processed[idx] = true;

    var start: ?usize = null;
    for (processed, 0..) |done, idx| {
        if (!done) {
            start = idx;
            break;
        }
    }
    var current = start orelse return &.{};

    var seen = std.AutoHashMap(usize, usize).init(allocator);
    var path = std.ArrayList(usize).empty;
    while (true) {
        if (seen.get(current)) |cycle_start| {
            var witness = std.ArrayList(usize).empty;
            for (path.items[cycle_start..]) |idx| try witness.append(allocator, idx);
            try witness.append(allocator, current);
            return try witness.toOwnedSlice(allocator);
        }
        try seen.put(current, path.items.len);
        try path.append(allocator, current);

        var next: ?usize = null;
        for (predecessors[current]) |predecessor_idx| {
            if (!processed[predecessor_idx]) {
                next = predecessor_idx;
                break;
            }
        }
        current = next orelse return &.{};
    }
}

fn cycleWitnessMessage(allocator: std.mem.Allocator, state: *const ItemState, witness: []const usize) ![]const u8 {
    var message = std.ArrayList(u8).empty;
    try message.appendSlice(allocator, "Dependency graph contains a cycle: ");
    for (witness, 0..) |idx, pos| {
        if (pos > 0) try message.appendSlice(allocator, " -> ");
        try message.appendSlice(allocator, state.items.items[idx].id);
    }
    return try message.toOwnedSlice(allocator);
}

fn ensureGraphIndexValid(index: GraphIndex) !void {
    if (index.dangling_dep_id != null) return error.UnknownDependency;
    if (index.cycle_witness.len != 0) return error.DependencyCycle;
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
    try writer.writeAll(",\"deps_added\":");
    try writeStringListArray(writer, delta.deps_added);
    try writer.writeAll(",\"deps_removed\":");
    try writeStringListArray(writer, delta.deps_removed);
    try writer.writeAll(",\"links_added\":");
    try writeStringListArray(writer, delta.links_added);
    try writer.writeAll(",\"links_removed\":");
    try writeStringListArray(writer, delta.links_removed);
    try writer.writeAll(",\"intent_added\":");
    try writeStringListArray(writer, delta.intent_added);
    try writer.writeAll(",\"intent_removed\":");
    try writeStringListArray(writer, delta.intent_removed);
    try writer.writeAll(",\"intent_coverage_changed\":");
    try writeStringListArray(writer, delta.intent_coverage_changed);
    try writer.writeAll(",\"fingerprints\":{\"before\":");
    try writeGraphFingerprintsObject(writer, delta.fingerprints_before);
    try writer.writeAll(",\"after\":");
    try writeGraphFingerprintsObject(writer, delta.fingerprints_after);
    try writer.writeAll("}}");
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
    try writer.writeAll(",\"fingerprints\":");
    try writeGraphFingerprintsObject(writer, state.graph.fingerprints);
    try writer.writeByte('}');
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
                try writer.writeByte('|');
                try writeProofReceiptsArray(writer, item.proof_receipts);
                try writer.writeByte('\n');
            },
            .execution => {
                try writer.print("{s}|{s}|{s}|", .{ item.id, item.status.asString(), if (effectiveInPlan(item)) "true" else "false" });
                if (item.claim) |claim| try writeClaimMetaObject(writer, claim);
                try writer.writeByte('|');
                if (item.runtime) |runtime| try writeRuntimeMetaObject(writer, runtime);
                try writer.writeByte('|');
                if (item.proof) |proof| try writeProofMetaObject(writer, proof);
                try writer.writeByte('|');
                try writeProofReceiptsArray(writer, item.proof_receipts);
                try writer.writeByte('\n');
            },
        }
    }
    if (kind == .coverage) {
        try writeIntentArray(writer, state.graph.intent);
        try writer.writeByte('|');
        try writeWaiversArray(writer, state.graph.waivers);
        try writer.writeByte('|');
        try writeProofActionsArray(writer, state.graph.proof_actions);
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
        if (!std.mem.eql(u8, prior.contract_fingerprint, last.contract_fingerprint)) return false;
        if (!std.mem.eql(u8, prior.coverage_fingerprint, last.coverage_fingerprint)) return false;
    }
    return true;
}

fn polishDeltaFromPrevious(passes: []const PolishPass, fps: GraphFingerprints) PolishDelta {
    if (passes.len == 0) return .{};
    const prior = passes[passes.len - 1];
    return .{
        .deps_changed = if (std.mem.eql(u8, prior.structure_fingerprint, fps.structure)) 0 else 1,
        .contracts_changed = if (std.mem.eql(u8, prior.contract_fingerprint, fps.contract)) 0 else 1,
        .intent_coverage_changed = if (std.mem.eql(u8, prior.coverage_fingerprint, fps.coverage)) 0 else 1,
    };
}

fn writeGraphInsightsJson(allocator: std.mem.Allocator, writer: anytype, state: *const ItemState) !void {
    const ready_ids = try readyItemIds(allocator, state);
    const blocked_ids = try blockedItemIds(allocator, state);
    var index = try buildGraphIndex(allocator, state);
    defer index.deinit(allocator);
    try ensureGraphIndexValid(index);
    const critical_depths = try criticalDepthsAlloc(allocator, state, index);
    defer allocator.free(critical_depths);
    const proof_summary = try proofObligationSummaryAlloc(allocator, state);
    try writer.writeByte('{');
    try writer.writeAll("\"version\":1,\"summary\":{\"items\":");
    try writer.print("{d}", .{state.items.items.len});
    try writer.writeAll(",\"ready\":");
    try writer.print("{d}", .{ready_ids.len});
    try writer.writeAll(",\"blocked\":");
    try writer.print("{d}", .{blocked_ids.len});
    try writer.writeAll(",\"critical_path_length\":");
    try writer.print("{d}", .{criticalPathLengthFromDepths(critical_depths)});
    try writer.writeAll(",\"intent_atoms\":");
    try writer.print("{d}", .{state.graph.intent.len});
    try writer.writeAll(",\"covered_intent\":");
    try writer.print("{d}", .{countCoveredIntent(state)});
    try writer.writeAll(",\"proof_complete\":");
    try writer.print("{d}", .{proof_summary.satisfied});
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
        try writer.print("{d}", .{criticalPathFromIndex(index, critical_depths, item.id)});
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"blocked\":");
    try writeStringListArray(writer, blocked_ids);
    try writer.writeAll(",\"coverage\":{\"intent\":{\"total\":");
    try writer.print("{d}", .{state.graph.intent.len});
    try writer.writeAll(",\"covered\":");
    try writer.print("{d}", .{countCoveredIntent(state)});
    try writer.writeAll(",\"waived\":0,\"unknown\":[]},\"tests\":{\"items_requiring_tests\":null,\"covered\":null,\"uncovered\":null,\"reason\":\"not-computed\"},\"proof\":{\"obligations_required\":");
    try writer.print("{d}", .{proof_summary.total});
    try writer.writeAll(",\"complete\":");
    try writer.print("{d}", .{proof_summary.satisfied});
    try writer.writeAll(",\"missing\":");
    try writeStringListArray(writer, proof_summary.missing);
    try writer.writeAll("}},\"waves\":[{\"wave\":1,\"items\":");
    try writeStringListArray(writer, ready_ids);
    try writer.writeAll(",\"safe_parallel\":");
    try writer.writeAll(if (readyIdsHaveDisjointLocks(state, ready_ids)) "true" else "false");
    try writer.writeAll("}]}");
}

fn writeGraphInsightsMarkdown(allocator: std.mem.Allocator, writer: anytype, state: *const ItemState) !void {
    const ready_ids = try readyItemIds(allocator, state);
    var index = try buildGraphIndex(allocator, state);
    defer index.deinit(allocator);
    try ensureGraphIndexValid(index);
    const critical_depths = try criticalDepthsAlloc(allocator, state, index);
    defer allocator.free(critical_depths);
    try writer.writeAll("# st graph insights\n\n");
    try writer.print("Items: {d}\nReady: {d}\nBlocked: {d}\nCritical path: {d}\nIntent: {d}/{d} covered\n\n", .{
        state.items.items.len,
        ready_ids.len,
        countBlockedItems(state),
        criticalPathLengthFromDepths(critical_depths),
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

fn criticalDepthsAlloc(allocator: std.mem.Allocator, state: *const ItemState, index: GraphIndex) ![]i64 {
    var depths = try allocator.alloc(i64, state.items.items.len);
    @memset(depths, 0);
    for (index.reverse_topological_order) |item_idx| {
        const item = state.items.items[item_idx];
        var max_successor_depth: i64 = 0;
        for (index.successors[item_idx]) |successor_idx| {
            if (depths[successor_idx] > max_successor_depth) max_successor_depth = depths[successor_idx];
        }
        const node_weight: i64 = if (!isTerminalStatus(item.status) and isExecutableItem(item)) 1 else 0;
        depths[item_idx] = node_weight + max_successor_depth;
    }
    return depths;
}

fn criticalPathLengthFromDepths(depths: []const i64) i64 {
    var max_len: i64 = 0;
    for (depths) |len| {
        if (len > max_len) max_len = len;
    }
    return max_len;
}

fn criticalPathFromIndex(index: GraphIndex, depths: []const i64, item_id: []const u8) i64 {
    const item_idx = index.item_index_by_id.get(item_id) orelse return 0;
    return depths[item_idx];
}

const ProofObligationSummary = struct {
    total: usize,
    satisfied: usize,
    missing: []const []const u8,
};

fn proofObligationSummaryAlloc(allocator: std.mem.Allocator, state: *const ItemState) !ProofObligationSummary {
    return proofObligationSummaryForIdsAlloc(allocator, state, &.{});
}

fn proofObligationSummaryForIdsAlloc(allocator: std.mem.Allocator, state: *const ItemState, item_ids: []const []const u8) !ProofObligationSummary {
    var total: usize = 0;
    var satisfied: usize = 0;
    var missing = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| {
        if (item_ids.len > 0 and !containsString(item_ids, item.id)) continue;
        if (!isExecutableItem(item)) continue;
        for (proofObligationsForItem(item)) |obligation| {
            if (!obligation.required) continue;
            total += 1;
            if (proofObligationSatisfied(item, obligation)) {
                satisfied += 1;
            } else {
                try missing.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ item.id, obligation.id }));
            }
        }
    }
    return .{
        .total = total,
        .satisfied = satisfied,
        .missing = try missing.toOwnedSlice(allocator),
    };
}

fn proofObligationSatisfied(item: Item, obligation: ProofObligation) bool {
    if (!obligation.required) return true;
    if (item.proof_receipts.len > 0) return proofReceiptSatisfiesObligation(item.proof_receipts, obligation);
    const proof = item.proof orelse return false;
    if (hasMultipleDistinctRequiredProofCommands(proofObligationsForItem(item))) return false;
    if (proof.state != .pass) return false;
    if (proof.evidence_ref.len == 0) return false;
    if (obligation.command.len == 0 and proofKindUsuallyNeedsCommand(obligation.kind)) return false;
    if (obligation.command.len > 0 and !std.mem.eql(u8, proof.command, obligation.command)) return false;
    return true;
}

fn readyIdsHaveDisjointLocks(state: *const ItemState, ready_ids: []const []const u8) bool {
    for (ready_ids, 0..) |lhs_id, i| {
        const lhs = state.getConst(lhs_id) orelse continue;
        const lhs_roots = apertureLockRootsForItem(lhs.*);
        if (lhs_roots.len == 0) return false;
        for (ready_ids[i + 1 ..]) |rhs_id| {
            const rhs = state.getConst(rhs_id) orelse continue;
            const rhs_roots = apertureLockRootsForItem(rhs.*);
            if (rhs_roots.len == 0) return false;
            if (rootsOverlapAny(lhs_roots, rhs_roots)) return false;
        }
    }
    return true;
}

fn selectApertureIds(allocator: std.mem.Allocator, state: *const ItemState, limit: usize) ![]const []const u8 {
    const candidates = try apertureCandidates(allocator, state, state.items.items.len);
    var out = std.ArrayList([]const u8).empty;
    for (candidates) |candidate| {
        if (out.items.len >= limit) break;
        if (!candidateCompatibleWithSelected(state, candidate.id, out.items)) continue;
        try out.append(allocator, candidate.id);
    }
    return try out.toOwnedSlice(allocator);
}

fn apertureCandidates(allocator: std.mem.Allocator, state: *const ItemState, limit: usize) ![]const ApertureCandidate {
    const audit = try auditGraph(allocator, state, .implementation_ready);
    var index = try buildGraphIndex(allocator, state);
    defer index.deinit(allocator);
    try ensureGraphIndexValid(index);
    const critical_depths = try criticalDepthsAlloc(allocator, state, index);
    defer allocator.free(critical_depths);
    var out = std.ArrayList(ApertureCandidate).empty;
    for (state.items.items, 0..) |item, idx| {
        if (!try apertureEligibleItem(allocator, state, item, audit)) continue;
        try out.append(allocator, .{ .id = item.id, .score = apertureScore(state, item, index, critical_depths), .durable_index = idx });
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

fn candidateCompatibleWithSelected(state: *const ItemState, candidate_id: []const u8, selected_ids: []const []const u8) bool {
    const candidate = state.getConst(candidate_id) orelse return false;
    const candidate_roots = apertureLockRootsForItem(candidate.*);
    if (candidate_roots.len == 0 and selected_ids.len > 0) return false;
    for (selected_ids) |selected_id| {
        const selected = state.getConst(selected_id) orelse return false;
        const selected_roots = apertureLockRootsForItem(selected.*);
        if (candidate_roots.len == 0 or selected_roots.len == 0) return false;
        if (rootsOverlapAny(candidate_roots, selected_roots)) return false;
    }
    return true;
}

fn apertureLockRootsForItem(item: Item) []const []const u8 {
    return if (item.lock_roots.len > 0) item.lock_roots else item.location;
}

fn apertureScore(state: *const ItemState, item: Item, index: GraphIndex, critical_depths: []const i64) i64 {
    var score: i64 = priorityWeight(item.priority);
    score += 4 * criticalPathFromIndex(index, critical_depths, item.id);
    score += 3 * downstreamCount(state, item.id);
    if (itemHasProofObligations(item) or item.validation.len > 0) score += 2;
    if (apertureLockRootsForItem(item).len > 0) score += 1 else score -= 2;
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
    try writeStringListArray(writer, apertureLockRootsForItem(item.*));
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
        try writeStringListArray(writer, apertureLockRootsForItem(item.*));
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

fn selectedInPlanIdsAlloc(allocator: std.mem.Allocator, state: *const ItemState) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| {
        if (effectiveInPlan(item)) try out.append(allocator, item.id);
    }
    return try out.toOwnedSlice(allocator);
}

fn activeItemIdsAlloc(allocator: std.mem.Allocator, state: *const ItemState) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (state.items.items) |item| {
        if (item.status == .in_progress) try out.append(allocator, item.id);
    }
    return try out.toOwnedSlice(allocator);
}

fn residualCount(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.items.items) |item| {
        if (!isTerminalStatus(item.status)) count += 1;
    }
    return count;
}

fn executableResidualCount(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.items.items) |item| {
        if (!isTerminalStatus(item.status) and isExecutableItem(item)) count += 1;
    }
    return count;
}

fn hardEdgeCount(state: *const ItemState) usize {
    var count: usize = 0;
    for (state.items.items) |item| count += item.deps.len;
    return count;
}

fn gcrReceiptIdAlloc(allocator: std.mem.Allocator, seq: i64, structure_fingerprint: []const u8) ![]const u8 {
    const raw = if (std.mem.startsWith(u8, structure_fingerprint, "sha256:"))
        structure_fingerprint["sha256:".len..]
    else
        structure_fingerprint;
    const prefix_len = @min(raw.len, 8);
    return try std.fmt.allocPrint(allocator, "GCR-{d}-{s}", .{ seq, raw[0..prefix_len] });
}

fn criticalPathIndexesAlloc(allocator: std.mem.Allocator, state: *const ItemState, index: GraphIndex, depths: []const i64) ![]const usize {
    if (depths.len == 0) return &.{};
    var start_idx: ?usize = null;
    var best_depth: i64 = 0;
    for (depths, 0..) |depth, idx| {
        if (depth > best_depth) {
            best_depth = depth;
            start_idx = idx;
        }
    }
    var current = start_idx orelse return &.{};
    var out = std.ArrayList(usize).empty;
    while (depths[current] > 0) {
        if (!isTerminalStatus(state.items.items[current].status) and isExecutableItem(state.items.items[current])) {
            try out.append(allocator, current);
        }
        var next: ?usize = null;
        var next_depth: i64 = 0;
        for (index.successors[current]) |successor_idx| {
            if (depths[successor_idx] > next_depth) {
                next_depth = depths[successor_idx];
                next = successor_idx;
            }
        }
        current = next orelse break;
    }
    return try out.toOwnedSlice(allocator);
}

fn writeItemIndexPath(writer: anytype, state: *const ItemState, indexes: []const usize) !void {
    try writer.writeByte('[');
    for (indexes, 0..) |idx, pos| {
        if (pos > 0) try writer.writeByte(',');
        try std.json.Stringify.value(state.items.items[idx].id, .{}, writer);
    }
    try writer.writeByte(']');
}

fn writeGraphControlReceiptJson(
    allocator: std.mem.Allocator,
    writer: anytype,
    state: *const ItemState,
    file: []const u8,
    seq: i64,
    fps: GraphFingerprints,
    audit: AuditResult,
    selected_ids: []const []const u8,
    limit: usize,
    receipt_id: []const u8,
) !void {
    const ready_ids = try readyItemIds(allocator, state);
    const blocked_ids = try blockedItemIds(allocator, state);
    const active_ids = try activeItemIdsAlloc(allocator, state);
    const debts = try computeGraphDebtAlloc(allocator, state, try nowUtcAlloc(allocator));
    const blocking_debt = countActiveGraphDebt(debts, "blocking");
    const gate_blocked = audit.errors != 0 or blocking_debt != 0;
    var proof_actions = std.ArrayList(ProofAction).empty;
    for (state.graph.proof_actions) |action| try proof_actions.append(allocator, action);
    try appendSyntheticProofActions(allocator, state, &proof_actions);
    const proof_basis = try directProofBasisAlloc(allocator, state, proof_actions.items);
    const proof_summary = if (selected_ids.len == 0)
        ProofObligationSummary{ .total = 0, .satisfied = 0, .missing = &.{} }
    else
        try proofObligationSummaryForIdsAlloc(allocator, state, selected_ids);
    var index = try buildGraphIndex(allocator, state);
    defer index.deinit(allocator);

    var critical_depth: ?i64 = null;
    var critical_path: []const usize = &.{};
    if (index.valid()) {
        const depths = try criticalDepthsAlloc(allocator, state, index);
        critical_depth = criticalPathLengthFromDepths(depths);
        critical_path = try criticalPathIndexesAlloc(allocator, state, index, depths);
    }

    try writer.writeAll("{\"graph_control_receipt\":{\"receipt_version\":\"GCR-v1\",\"receipt_id\":");
    try std.json.Stringify.value(receipt_id, .{}, writer);
    try writer.writeAll(",\"mode\":");
    try std.json.Stringify.value(if (!state.graph_active) "ledger" else if (blocking_debt != 0) "degraded" else "graph", .{}, writer);
    try writer.writeAll(",\"artifact_state\":{\"file\":");
    try std.json.Stringify.value(file, .{}, writer);
    try writer.writeAll(",\"seq\":");
    try writer.print("{d}", .{seq});
    try writer.writeAll(",\"graph_version\":");
    try writer.print("{d}", .{state.graph.version});
    try writer.writeAll(",\"structure_fingerprint\":");
    try std.json.Stringify.value(fps.structure, .{}, writer);
    try writer.writeAll(",\"contract_fingerprint\":");
    try std.json.Stringify.value(fps.contract, .{}, writer);
    try writer.writeAll(",\"coverage_fingerprint\":");
    try std.json.Stringify.value(fps.coverage, .{}, writer);
    try writer.writeAll(",\"execution_fingerprint\":");
    try std.json.Stringify.value(fps.execution, .{}, writer);
    try writer.writeAll("},\"audit\":{\"gate\":");
    try std.json.Stringify.value(audit.gate.asString(), .{}, writer);
    try writer.writeAll(",\"outcome\":");
    try std.json.Stringify.value(if (!gate_blocked) "pass" else "gate-blocked", .{}, writer);
    try writer.writeAll(",\"errors\":");
    try writer.print("{d}", .{audit.errors});
    try writer.writeAll(",\"warnings\":");
    try writer.print("{d}", .{audit.warnings});
    try writer.writeAll(",\"findings\":[");
    for (audit.findings, 0..) |finding, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeFindingJson(writer, finding);
    }
    try writer.writeAll("]},\"graph\":{\"nodes\":{\"total\":");
    try writer.print("{d}", .{state.items.items.len});
    try writer.writeAll(",\"residual\":");
    try writer.print("{d}", .{residualCount(state)});
    try writer.writeAll(",\"executable_residual\":");
    try writer.print("{d}", .{executableResidualCount(state)});
    try writer.writeAll("},\"hard_edges\":");
    try writer.print("{d}", .{hardEdgeCount(state)});
    try writer.writeAll(",\"critical\":{\"method\":");
    try std.json.Stringify.value(if (critical_depth == null) "not-computed" else "unit-weight-dag", .{}, writer);
    try writer.writeAll(",\"depth\":");
    if (critical_depth) |depth| try writer.print("{d}", .{depth}) else try writer.writeAll("null");
    try writer.writeAll(",\"path\":");
    try writeItemIndexPath(writer, state, critical_path);
    try writer.writeAll("}},\"frontier\":{\"active\":");
    try writeStringListArray(writer, active_ids);
    try writer.writeAll(",\"ready\":");
    try writeStringListArray(writer, ready_ids);
    try writer.writeAll(",\"waiting_on_dependencies\":");
    try writeStringListArray(writer, blocked_ids);
    try writer.writeAll(",\"selected\":");
    try writeStringListArray(writer, selected_ids);
    try writer.writeAll(",\"unselected_ready\":[");
    var emitted: usize = 0;
    for (ready_ids) |id| {
        if (containsString(selected_ids, id)) continue;
        if (emitted > 0) try writer.writeByte(',');
        try std.json.Stringify.value(id, .{}, writer);
        emitted += 1;
    }
    try writer.writeAll("]},\"parallelism\":{\"requested\":\"auto\",\"ready_width\":");
    try writer.print("{d}", .{ready_ids.len});
    try writer.writeAll(",\"safe_ready_width\":");
    try writer.print("{d}", .{if (readyIdsHaveDisjointLocks(state, ready_ids)) ready_ids.len else @min(ready_ids.len, 1)});
    try writer.writeAll(",\"selected_wave\":{\"method\":\"legacy-aperture-score\",\"optimality\":\"deterministic-heuristic\",\"safe_parallel\":");
    try writer.writeAll(if (readyIdsHaveDisjointLocks(state, selected_ids)) "true" else "false");
    try writer.writeAll(",\"items\":");
    try writeStringListArray(writer, selected_ids);
    try writer.writeAll("}},\"aperture_decision\":{\"strategy\":\"control-v2\",\"limit\":");
    try writer.print("{d}", .{limit});
    try writer.writeAll(",\"selected_nodes\":[");
    for (selected_ids, 0..) |id, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeAll(",\"why_selected\":[\"ready-or-active\",\"within-aperture-limit\"]}");
    }
    try writer.writeAll("],\"unselected_ready\":[");
    emitted = 0;
    for (ready_ids) |id| {
        if (containsString(selected_ids, id)) continue;
        if (emitted > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeAll(",\"why_not_selected\":[\"aperture-limit-or-lock-conflict\"]}");
        emitted += 1;
    }
    try writer.writeAll("]},\"proof\":{\"obligations\":{\"total\":");
    try writer.print("{d}", .{proof_summary.total});
    try writer.writeAll(",\"satisfied\":");
    try writer.print("{d}", .{proof_summary.satisfied});
    try writer.writeAll(",\"missing\":");
    try writeStringListArray(writer, proof_summary.missing);
    try writer.writeAll("},\"proof_basis\":{\"method\":\"direct-command-dedup\",\"optimality\":\"exact\",\"action_ids\":[");
    for (proof_basis.actions, 0..) |action, idx| {
        if (idx > 0) try writer.writeByte(',');
        try std.json.Stringify.value(action.id, .{}, writer);
    }
    try writer.writeAll("],\"commands\":[");
    for (proof_basis.actions, 0..) |action, idx| {
        if (idx > 0) try writer.writeByte(',');
        try std.json.Stringify.value(action.command, .{}, writer);
    }
    try writer.writeAll("]}},\"debt\":{\"blocking\":");
    try writeGraphDebtFilteredArray(writer, debts, "blocking");
    try writer.writeAll(",\"warnings\":");
    try writeGraphDebtFilteredArray(writer, debts, "warning");
    try writer.writeAll(",\"waivers\":");
    try writeWaiversArray(writer, state.graph.waivers);
    try writer.writeAll("},\"gate\":{\"projection_allowed\":");
    try std.json.Stringify.value(if (!gate_blocked) "yes" else "no", .{}, writer);
    try writer.writeAll(",\"execution_allowed\":");
    try std.json.Stringify.value(if (!gate_blocked) "yes" else "no", .{}, writer);
    try writer.writeAll(",\"completion_claim_allowed\":\"no\",\"reason\":");
    try std.json.Stringify.value(if (!gate_blocked) "selected aperture is projected; proof remains outstanding" else if (blocking_debt != 0) "blocking graph debt" else "graph gate blocked", .{}, writer);
    try writer.writeAll("}}}");
}

fn maybeWriteWorkspaceGraphControlReceiptJson(
    allocator: std.mem.Allocator,
    writer: anytype,
    args: Args,
    state: *const ItemState,
    seq: i64,
    fps: GraphFingerprints,
    audit: AuditResult,
    selected_ids: []const []const u8,
    gcr_v1_id: []const u8,
    graph_gate_blocked: bool,
) !void {
    if (!workspaceModeRequested(args)) return;
    try writer.writeAll("workspace_graph_control_receipt: ");
    try writeWorkspaceGraphControlReceiptJson(allocator, writer, args, state, seq, fps, audit, selected_ids, gcr_v1_id, graph_gate_blocked);
    try writer.writeByte('\n');
}

fn writeWorkspaceGraphControlReceiptJson(
    allocator: std.mem.Allocator,
    writer: anytype,
    args: Args,
    state: *const ItemState,
    seq: i64,
    fps: GraphFingerprints,
    audit: AuditResult,
    selected_ids: []const []const u8,
    gcr_v1_id: []const u8,
    graph_gate_blocked: bool,
) !void {
    const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
    defer workspace.deinit();
    const workspace_obj = switch (workspace.parsed.value) {
        .object => |obj| obj,
        else => return error.WorkspaceInvalid,
    };
    const workspace_sequence = workspaceSequence(workspace.parsed.value);
    const branch_epoch = intField(workspace.parsed.value, "branch_epoch") orelse 0;
    const plan_sequence = try planSequenceForFile(allocator, args.file);
    const plan_id_owned = if (args.plan_id) |plan_id|
        try normalizePlanId(allocator, plan_id)
    else
        try inferSingleActiveWorkspacePlanId(allocator, args.workspace);
    defer allocator.free(plan_id_owned);
    const plan_record = findWorkspacePlanRecord(workspace_obj, plan_id_owned) orelse return error.PlanMissing;

    var denials: std.ArrayList([]const u8) = .empty;
    if (!try workspacePlanRecordFingerprintsCurrent(plan_record, fps)) {
        try denials.append(allocator, "gcr_stale");
    }

    if (args.expect_workspace_seq) |raw| {
        if (try parseNonNegativeI64(raw) != workspace_sequence) try denials.append(allocator, "workspace_sequence_stale");
    }
    if (args.expect_plan_seq) |raw| {
        if (try parseNonNegativeI64(raw) != plan_sequence) try denials.append(allocator, "plan_sequence_stale");
    }
    if (args.expect_branch_epoch) |raw| {
        if (try parseNonNegativeI64(raw) != branch_epoch) try denials.append(allocator, "branch_epoch_stale");
    }
    if (graph_gate_blocked or audit.errors != 0 or countActiveGraphDebt(state.graph.debt, "blocking") != 0) {
        try denials.append(allocator, "graph_gate_blocked");
    }

    var claim_value: ?std.json.Value = null;
    const claim_id = args.claim_id orelse "";
    const session_id = args.session_id orelse "";
    const token: i64 = if (args.fencing_token) |raw| try parseNonNegativeI64(raw) else 0;
    if (claim_id.len == 0) {
        try denials.append(allocator, "claim_missing");
    } else if (token <= 0) {
        try denials.append(allocator, "fencing_token_stale");
    } else {
        const now_for_claim = try nowUtcAlloc(allocator);
        defer allocator.free(now_for_claim);
        claim_value = validateWorkspaceClaimAuthority(workspace_obj, claim_id, if (session_id.len > 0) session_id else null, @intCast(token), now_for_claim) catch |err| blk: {
            try denials.append(allocator, workspaceGcrDenialForError(err));
            break :blk null;
        };
    }

    var projection_digest: []const u8 = "";
    var projection_digest_owned: ?[]u8 = null;
    defer if (projection_digest_owned) |owned| allocator.free(owned);
    if (session_id.len == 0) {
        try denials.append(allocator, "session_unbound");
    } else {
        const view_path = try workspaceViewFilePathAlloc(allocator, args.workspace, session_id);
        defer allocator.free(view_path);
        const view_bytes = durable_store.readRegularFileNoSymlink(allocator, view_path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => blk: {
                try denials.append(allocator, "session_unbound");
                break :blk "";
            },
            else => return err,
        };
        defer if (view_bytes.len > 0) allocator.free(view_bytes);
        if (view_bytes.len > 0) {
            var parsed_view = try std.json.parseFromSlice(std.json.Value, allocator, view_bytes, .{});
            defer parsed_view.deinit();
            if (stringField(parsed_view.value, "projection_digest")) |digest| {
                projection_digest_owned = try allocator.dupe(u8, digest);
                projection_digest = projection_digest_owned.?;
            }
            if (!std.mem.eql(u8, stringField(parsed_view.value, "plan_id") orelse "", plan_id_owned)) try denials.append(allocator, "session_plan_mismatch");
            if (!std.mem.eql(u8, stringField(parsed_view.value, "claim_id") orelse "", claim_id)) try denials.append(allocator, "view_stale");
            if ((intField(parsed_view.value, "fencing_token") orelse -1) != token) try denials.append(allocator, "view_stale");
            if ((intField(parsed_view.value, "workspace_sequence") orelse -1) != workspace_sequence) try denials.append(allocator, "view_stale");
            if ((intField(parsed_view.value, "plan_sequence") orelse -1) != plan_sequence) try denials.append(allocator, "view_stale");
            if ((intField(parsed_view.value, "branch_epoch") orelse -1) != branch_epoch) try denials.append(allocator, "branch_epoch_stale");
        }
    }

    const execution_allowed = denials.items.len == 0;
    const receipt_id = try std.fmt.allocPrint(allocator, "GCR2-{d}-{s}", .{ seq, fps.structure["sha256:".len..@min(fps.structure.len, "sha256:".len + 8)] });
    defer allocator.free(receipt_id);
    try writer.writeAll("{\"graph_control_receipt\":{\"receipt_version\":\"GCR-v2\",\"receipt_id\":");
    try std.json.Stringify.value(receipt_id, .{}, writer);
    try writer.writeAll(",\"extends\":");
    try std.json.Stringify.value(gcr_v1_id, .{}, writer);
    try writer.writeAll(",\"workspace\":{\"workspace_sequence\":");
    try writer.print("{d}", .{workspace_sequence});
    try writer.writeAll(",\"st_root\":");
    try std.json.Stringify.value(stringField(workspace.parsed.value, "st_root") orelse args.workspace, .{}, writer);
    try writer.writeAll("},\"plan\":{\"plan_id\":");
    try std.json.Stringify.value(plan_id_owned, .{}, writer);
    try writer.writeAll(",\"plan_sequence\":");
    try writer.print("{d}", .{plan_sequence});
    try writer.writeAll(",\"graph_fingerprints\":");
    try writeGraphFingerprintsObject(writer, fps);
    try writer.writeAll(",\"registry_graph_fingerprints\":");
    if (plan_record.object.get("graph_fingerprints")) |registry_fps| {
        try std.json.Stringify.value(registry_fps, .{}, writer);
    } else {
        try writer.writeAll("{}");
    }
    try writer.writeAll(",\"selected_item_ids\":");
    try writeStringListArray(writer, selected_ids);
    try writer.writeAll("},\"branch\":{\"epoch\":");
    try writer.print("{d}", .{branch_epoch});
    try writer.writeAll(",\"target_branch\":");
    try std.json.Stringify.value(workspace_obj.get("target_branch") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll(",\"target_head\":");
    try std.json.Stringify.value(workspace_obj.get("target_head") orelse std.json.Value{ .null = {} }, .{}, writer);
    try writer.writeAll("},\"claim\":{\"claim_id\":");
    try std.json.Stringify.value(claim_id, .{}, writer);
    try writer.writeAll(",\"fencing_token\":");
    try writer.print("{d}", .{token});
    try writer.writeAll(",\"resources\":");
    if (claim_value) |claim| {
        if (claim.object.get("resources")) |resources| {
            try std.json.Stringify.value(resources, .{}, writer);
        } else {
            try writer.writeAll("[]");
        }
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeAll("},\"session_view\":{\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, writer);
    try writer.writeAll(",\"projection_digest\":");
    try std.json.Stringify.value(projection_digest, .{}, writer);
    try writer.writeAll("},\"currentness\":{\"workspace_sequence\":");
    try writer.writeAll(if (!containsString(denials.items, "workspace_sequence_stale")) "true" else "false");
    try writer.writeAll(",\"plan_sequence\":");
    try writer.writeAll(if (!containsString(denials.items, "plan_sequence_stale")) "true" else "false");
    try writer.writeAll(",\"branch_epoch\":");
    try writer.writeAll(if (!containsString(denials.items, "branch_epoch_stale")) "true" else "false");
    try writer.writeAll(",\"graph_fingerprints\":");
    try writer.writeAll(if (!containsString(denials.items, "gcr_stale")) "true" else "false");
    try writer.writeAll(",\"claim_and_fencing\":");
    try writer.writeAll(if (claim_value != null and !containsString(denials.items, "fencing_token_stale")) "true" else "false");
    try writer.writeAll(",\"session_view\":");
    try writer.writeAll(if (!containsString(denials.items, "view_stale") and !containsString(denials.items, "session_unbound") and !containsString(denials.items, "session_plan_mismatch")) "true" else "false");
    try writer.writeAll("},\"gate\":{\"execution_allowed\":");
    try std.json.Stringify.value(if (execution_allowed) "yes" else "no", .{}, writer);
    try writer.writeAll(",\"denials\":");
    try writeStringListArray(writer, denials.items);
    try writer.writeAll("}}}");
}

fn workspaceGcrDenialForError(err: anyerror) []const u8 {
    return switch (err) {
        error.ClaimMissing => "claim_missing",
        error.ClaimExpired => "claim_expired",
        error.ClaimOwnerMismatch => "claim_owner_mismatch",
        error.FencingTokenStale => "fencing_token_stale",
        else => "workspace_invalid",
    };
}

fn countActiveGraphDebt(debts: []const GraphDebt, severity: []const u8) usize {
    var count: usize = 0;
    for (debts) |debt| {
        if (debt.resolved_at.len > 0 or debt.waiver_id.len > 0) continue;
        if (std.mem.eql(u8, debt.severity, severity)) count += 1;
    }
    return count;
}

fn writeStReceiptJson(
    writer: anytype,
    command: []const u8,
    outcome: []const u8,
    exit_code: u8,
    file: []const u8,
    seq_before: i64,
    seq_after: i64,
    graph_mode: bool,
    gcr_id: []const u8,
    codes: []const []const u8,
) !void {
    try writer.writeAll("{\"st_receipt\":{\"receipt_version\":\"ST-R1\",\"command\":");
    try std.json.Stringify.value(command, .{}, writer);
    try writer.writeAll(",\"outcome\":");
    try std.json.Stringify.value(outcome, .{}, writer);
    try writer.writeAll(",\"exit_code\":");
    try writer.print("{d}", .{exit_code});
    try writer.writeAll(",\"file\":");
    try std.json.Stringify.value(file, .{}, writer);
    try writer.writeAll(",\"seq_before\":");
    try writer.print("{d}", .{seq_before});
    try writer.writeAll(",\"seq_after\":");
    try writer.print("{d}", .{seq_after});
    try writer.writeAll(",\"graph_mode\":");
    try std.json.Stringify.value(if (graph_mode) "yes" else "no", .{}, writer);
    try writer.writeAll(",\"gcr_id\":");
    try std.json.Stringify.value(gcr_id, .{}, writer);
    try writer.writeAll(",\"codes\":");
    try writeStringListArray(writer, codes);
    try writer.writeAll("}}");
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
    if (args.claim_command != .grant or workspaceModeRequested(args)) {
        return cmdWorkspaceClaim(allocator, args);
    }

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
    proof.last_run_at = try timestampArgOrNowAlloc(allocator, args.now);
    item.proof = proof;
    try maybeLegacyReceiptForCommand(allocator, item, proof, args.proof_id);

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
        var missing_reason = proofCompletionMissingReason(item.*);
        if (missing_reason != null and !args.allow_unproven and args.step != null) {
            var proof = item.proof orelse ProofMeta{};
            proof.state = .pass;
            proof.command = try requireNonEmptyString(allocator, args.step.?, "--command");
            proof.evidence_ref = if (args.evidence_ref) |raw|
                try requireNonEmptyString(allocator, raw, "--evidence-ref")
            else
                "";
            proof.last_run_at = try timestampArgOrNowAlloc(allocator, args.now);
            item.proof = proof;
            try maybeLegacyReceiptForCommand(allocator, item, proof, args.proof_id);
            missing_reason = proofCompletionMissingReason(item.*);
        }
        if (missing_reason) |missing| {
            var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
            const stdout = &stdout_writer.interface;
            if (!args.allow_unproven) {
                try stdout.print("completion blocked for {s}: {s}\n", .{ item_id, missing });
                return 2;
            }
            const waiver_reason = try requireNonEmptyString(allocator, args.reason orelse return error.MissingReason, "--reason");
            const now = try timestampArgOrNowAlloc(allocator, args.now);
            try addForcedCompletionWaivers(allocator, &state, item_id, waiver_reason, now);
        }
    }
    item.status = .completed;
    normalizeItemPlanMembership(item);

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    const ts = try timestampArgOrNowAlloc(allocator, args.now);
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
        .plan => try cmdProofPlan(allocator, args),
        .record => try cmdProofRecord(allocator, args),
        .none => error.MissingCommand,
    };
}

fn cmdProofPlan(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    var actions = std.ArrayList(ProofAction).empty;
    for (state.graph.proof_actions) |action| try actions.append(allocator, action);
    try appendSyntheticProofActions(allocator, &state, &actions);
    const basis = try directProofBasisAlloc(allocator, &state, actions.items);

    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("{\"proof_plan\":{\"scope\":\"aperture\",\"method\":\"direct-command-dedup\",\"optimality\":\"exact\",\"action_ids\":[");
    for (basis.actions, 0..) |action, idx| {
        if (idx > 0) try stdout.writeByte(',');
        try std.json.Stringify.value(action.id, .{}, stdout);
    }
    try stdout.writeAll("],\"commands\":[");
    for (basis.actions, 0..) |action, idx| {
        if (idx > 0) try stdout.writeByte(',');
        try std.json.Stringify.value(action.command, .{}, stdout);
    }
    try stdout.writeAll("],\"covers\":[");
    var emitted: usize = 0;
    for (basis.actions) |action| {
        for (action.covers) |cover| {
            if (emitted > 0) try stdout.writeByte(',');
            try stdout.writeAll("{\"action_id\":");
            try std.json.Stringify.value(action.id, .{}, stdout);
            try stdout.writeAll(",\"item_id\":");
            try std.json.Stringify.value(cover.item_id, .{}, stdout);
            try stdout.writeAll(",\"obligation_id\":");
            try std.json.Stringify.value(cover.obligation_id, .{}, stdout);
            try stdout.writeByte('}');
            emitted += 1;
        }
    }
    try stdout.writeAll("]}}\n");
    return 0;
}

fn cmdProofRecord(allocator: std.mem.Allocator, args: Args) !u8 {
    const loaded = try loadValidatedState(allocator, args.file, args.allow_multiple_in_progress);
    var state = loaded.state;
    defer state.deinit();

    const item_id = try requireNonEmptyString(allocator, args.id.?, "--id");
    const obligation_id = try requireNonEmptyString(allocator, args.obligation_id.?, "--obligation");
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &.{});
    const stdout = &stdout_writer.interface;
    const item = state.get(item_id) orelse {
        try stdout.print("proof record blocked for {s}/{s}: unknown item\n", .{ item_id, obligation_id });
        return 2;
    };
    const obligation = findProofObligation(item.*, obligation_id) orelse {
        try stdout.print("proof record blocked for {s}/{s}: unknown proof obligation\n", .{ item_id, obligation_id });
        return 2;
    };
    const command = try requireNonEmptyString(allocator, args.step.?, "--command");
    if (!proofObligationCommandMatches(obligation, command)) {
        try stdout.print("proof record blocked for {s}/{s}: command mismatch; expected \"{s}\", got \"{s}\"\n", .{ item_id, obligation_id, obligation.command, command });
        return 2;
    }
    const now = try nowUtcAlloc(allocator);
    var receipt = ProofReceipt{
        .obligation_id = obligation_id,
        .action_id = try requireNonEmptyString(allocator, args.action_id.?, "--action"),
        .state = "pass",
        .command = command,
        .evidence_ref = try requireNonEmptyString(allocator, args.evidence_ref.?, "--evidence-ref"),
        .artifact_ref = if (args.artifact_ref) |raw| try requireNonEmptyString(allocator, raw, "--artifact-ref") else "",
        .recorded_at = now,
    };
    var workspace_plan_id: ?[]u8 = null;
    defer if (workspace_plan_id) |owned| allocator.free(owned);
    var tree_digest_owned: ?[]u8 = null;
    defer if (tree_digest_owned) |owned| allocator.free(owned);
    if (workspaceModeRequested(args)) {
        const workspace = try loadWorkspaceCheckpoint(allocator, args.workspace);
        defer workspace.deinit();
        workspace_plan_id = if (args.plan_id) |plan_id|
            try normalizePlanId(allocator, plan_id)
        else
            try inferSingleActiveWorkspacePlanId(allocator, args.workspace);
        tree_digest_owned = currentGitTreeDigestAlloc(allocator) catch try allocator.dupe(u8, "");
        receipt.receipt_version = "PRF-v3";
        receipt.workspace_id = stringField(workspace.parsed.value, "st_root") orelse workspace.root;
        receipt.workspace_sequence = workspaceSequence(workspace.parsed.value);
        receipt.plan_id = workspace_plan_id.?;
        receipt.plan_sequence = loaded.latest_seq + 1;
        receipt.branch_epoch = intField(workspace.parsed.value, "branch_epoch") orelse 0;
        receipt.tree_digest = tree_digest_owned.?;
        receipt.dependency_resources = try proofDependencyResourcesForItem(allocator, item.*);
    }
    try upsertProofReceipt(allocator, item, receipt);

    try validateState(&state, args.allow_multiple_in_progress);
    const meta = buildMutationMeta(allocator, args.allow_multiple_in_progress);
    try writeCanonicalRecords(args.file, &state, loaded.latest_seq + 1, now, meta, null);

    try stdout.print("recorded proof receipt for {s}/{s}\n", .{ item_id, obligation_id });
    try emitSyncOutputs(allocator, stdout, &state, args.allow_multiple_in_progress, args.file, loaded.latest_seq + 1);
    return 0;
}

fn currentGitTreeDigestAlloc(allocator: std.mem.Allocator) ![]u8 {
    const tree = try gitTrimmedAlloc(allocator, ".", &.{ "rev-parse", "HEAD^{tree}" });
    defer allocator.free(tree);
    return std.fmt.allocPrint(allocator, "git-tree:{s}", .{tree});
}

fn proofDependencyResourcesForItem(allocator: std.mem.Allocator, item: Item) ![]const []const u8 {
    const roots = if (item.lock_roots.len > 0)
        item.lock_roots
    else if (item.location.len > 0)
        item.location
    else if (item.scope.len > 0)
        item.scope
    else
        &[_][]const u8{"repo:all"};
    var out: std.ArrayList([]const u8) = .empty;
    for (roots) |root| {
        if (std.mem.indexOfScalar(u8, root, ':') != null) {
            try out.append(allocator, root);
        } else {
            try out.append(allocator, try std.fmt.allocPrint(allocator, "path:{s}", .{root}));
        }
    }
    return try out.toOwnedSlice(allocator);
}

const ProofBasis = struct {
    actions: []const ProofAction,
};

fn appendSyntheticProofActions(allocator: std.mem.Allocator, state: *const ItemState, actions: *std.ArrayList(ProofAction)) !void {
    for (state.items.items) |item| {
        if (!effectiveInPlan(item) or !isExecutableItem(item)) continue;
        for (proofObligationsForItem(item)) |obligation| {
            if (!obligation.required or obligation.command.len == 0) continue;
            if (proofReceiptSatisfiesObligation(item.proof_receipts, obligation)) continue;
            if (actionCoversObligation(actions.items, item.id, obligation.id)) continue;
            try actions.append(allocator, .{
                .id = try std.fmt.allocPrint(allocator, "proof-action-direct-{s}-{s}", .{ item.id, obligation.id }),
                .command = obligation.command,
                .covers = try singleProofCoverAlloc(allocator, item.id, obligation.id),
            });
        }
    }
}

fn directProofBasisAlloc(allocator: std.mem.Allocator, state: *const ItemState, actions: []const ProofAction) !ProofBasis {
    var out = std.ArrayList(ProofAction).empty;
    for (state.items.items) |item| {
        if (!effectiveInPlan(item) or !isExecutableItem(item)) continue;
        for (proofObligationsForItem(item)) |obligation| {
            if (!obligation.required or obligation.command.len == 0) continue;
            if (proofReceiptSatisfiesObligation(item.proof_receipts, obligation)) continue;
            const action = findFirstActionCovering(actions, item.id, obligation.id) orelse continue;
            try appendOrMergeProofAction(allocator, &out, action, item.id, obligation.id);
        }
    }
    return .{ .actions = try out.toOwnedSlice(allocator) };
}

fn appendOrMergeProofAction(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ProofAction),
    action: ProofAction,
    item_id: []const u8,
    obligation_id: []const u8,
) !void {
    for (out.items) |*existing| {
        if (!std.mem.eql(u8, existing.command, action.command)) continue;
        var covers = std.ArrayList(ProofCover).empty;
        try covers.appendSlice(allocator, existing.covers);
        try covers.append(allocator, .{ .item_id = item_id, .obligation_id = obligation_id });
        existing.covers = try covers.toOwnedSlice(allocator);
        return;
    }
    try out.append(allocator, .{
        .id = action.id,
        .command = action.command,
        .cost = action.cost,
        .covers = try singleProofCoverAlloc(allocator, item_id, obligation_id),
        .scope = action.scope,
    });
}

fn singleProofCoverAlloc(allocator: std.mem.Allocator, item_id: []const u8, obligation_id: []const u8) ![]const ProofCover {
    const covers = try allocator.alloc(ProofCover, 1);
    covers[0] = .{ .item_id = item_id, .obligation_id = obligation_id };
    return covers;
}

fn actionCoversObligation(actions: []const ProofAction, item_id: []const u8, obligation_id: []const u8) bool {
    return findFirstActionCovering(actions, item_id, obligation_id) != null;
}

fn findFirstActionCovering(actions: []const ProofAction, item_id: []const u8, obligation_id: []const u8) ?ProofAction {
    for (actions) |action| {
        for (action.covers) |cover| {
            if (std.mem.eql(u8, cover.item_id, item_id) and std.mem.eql(u8, cover.obligation_id, obligation_id)) return action;
        }
    }
    return null;
}

fn findProofObligation(item: Item, obligation_id: []const u8) ?ProofObligation {
    for (proofObligationsForItem(item)) |obligation| {
        if (std.mem.eql(u8, obligation.id, obligation_id)) return obligation;
    }
    return null;
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
            try stdout.writeAll(",\"proof_receipts\":");
            try writeProofReceiptsArray(stdout, item.proof_receipts);
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
    return parseRecordsFromBytes(allocator, bytes);
}

fn parseRecordsFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !ParsedRecords {
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

fn renderMigratedPlanJsonl(allocator: std.mem.Allocator, legacy_bytes: []const u8, plan_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, legacy_bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        if (parsed.value != .object) return error.InvalidRecord;
        const lane = normalizedLane(parsed.value) orelse "";
        if (std.mem.eql(u8, lane, "checkpoint")) {
            try writeMigratedCheckpointRecord(&out.writer, parsed.value, plan_id);
        } else {
            try std.json.Stringify.value(parsed.value, .{}, &out.writer);
        }
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn writeMigratedCheckpointRecord(writer: anytype, record: std.json.Value, plan_id: []const u8) !void {
    if (record != .object) return error.InvalidRecord;
    const has_plan_id = record.object.get("plan_id") != null;
    const has_plan_sequence = record.object.get("plan_sequence") != null;
    var emitted: usize = 0;
    try writer.writeByte('{');
    var it = record.object.iterator();
    while (it.next()) |entry| {
        if (emitted != 0) try writer.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
        try writer.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, writer);
        emitted += 1;
    }
    if (!has_plan_id) {
        if (emitted != 0) try writer.writeByte(',');
        try writer.writeAll("\"plan_id\":");
        try std.json.Stringify.value(plan_id, .{}, writer);
        emitted += 1;
    }
    if (!has_plan_sequence) {
        if (emitted != 0) try writer.writeByte(',');
        try writer.writeAll("\"plan_sequence\":");
        try writer.print("{d}", .{intField(record, "seq") orelse 0});
    }
    try writer.writeByte('}');
}

fn assertMigrationParity(
    allocator: std.mem.Allocator,
    legacy_state: *const ItemState,
    migrated_state: *const ItemState,
    legacy_seq: i64,
    migrated_seq: i64,
) !void {
    if (legacy_seq != migrated_seq) return error.MigrationParityFailed;
    const legacy_snapshot = try renderMigrationParitySnapshot(allocator, legacy_state);
    defer allocator.free(legacy_snapshot);
    const migrated_snapshot = try renderMigrationParitySnapshot(allocator, migrated_state);
    defer allocator.free(migrated_snapshot);
    if (!std.mem.eql(u8, legacy_snapshot, migrated_snapshot)) return error.MigrationParityFailed;
}

fn renderMigrationParitySnapshot(allocator: std.mem.Allocator, state: *const ItemState) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    try out.writer.writeAll("\"graph_active\":");
    try out.writer.writeAll(if (state.graph_active) "true" else "false");
    if (state.graph_active) {
        try out.writer.writeAll(",\"graph\":");
        try writeGraphEnvelopeObject(&out.writer, state.graph);
    }
    try out.writer.writeAll(",\"items\":");
    try writeItemsArray(&out.writer, state.items.items);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
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
    if (item.proof_receipts.len > 0) {
        try writer.writeAll(",\"proof_receipts\":");
        try writeProofReceiptsArray(writer, item.proof_receipts);
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

fn writeProofReceiptsArray(writer: anytype, receipts: []const ProofReceipt) !void {
    try writer.writeByte('[');
    for (receipts, 0..) |receipt, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"receipt_version\":");
        try std.json.Stringify.value(receipt.receipt_version, .{}, writer);
        try writer.writeAll(",\"obligation_id\":");
        try std.json.Stringify.value(receipt.obligation_id, .{}, writer);
        if (receipt.action_id.len > 0) {
            try writer.writeAll(",\"action_id\":");
            try std.json.Stringify.value(receipt.action_id, .{}, writer);
        }
        try writer.writeAll(",\"state\":");
        try std.json.Stringify.value(receipt.state, .{}, writer);
        if (receipt.command.len > 0) {
            try writer.writeAll(",\"command\":");
            try std.json.Stringify.value(receipt.command, .{}, writer);
        }
        if (receipt.evidence_ref.len > 0) {
            try writer.writeAll(",\"evidence_ref\":");
            try std.json.Stringify.value(receipt.evidence_ref, .{}, writer);
        }
        if (receipt.artifact_ref.len > 0) {
            try writer.writeAll(",\"artifact_ref\":");
            try std.json.Stringify.value(receipt.artifact_ref, .{}, writer);
        }
        if (receipt.recorded_at.len > 0) {
            try writer.writeAll(",\"recorded_at\":");
            try std.json.Stringify.value(receipt.recorded_at, .{}, writer);
        }
        if (receipt.waiver_id.len > 0) {
            try writer.writeAll(",\"waiver_id\":");
            try std.json.Stringify.value(receipt.waiver_id, .{}, writer);
        }
        if (receipt.workspace_id.len > 0) {
            try writer.writeAll(",\"workspace_id\":");
            try std.json.Stringify.value(receipt.workspace_id, .{}, writer);
        }
        if (receipt.workspace_sequence >= 0) {
            try writer.writeAll(",\"workspace_sequence\":");
            try writer.print("{d}", .{receipt.workspace_sequence});
        }
        if (receipt.plan_id.len > 0) {
            try writer.writeAll(",\"plan_id\":");
            try std.json.Stringify.value(receipt.plan_id, .{}, writer);
        }
        if (receipt.plan_sequence >= 0) {
            try writer.writeAll(",\"plan_sequence\":");
            try writer.print("{d}", .{receipt.plan_sequence});
        }
        if (receipt.branch_epoch >= 0) {
            try writer.writeAll(",\"branch_epoch\":");
            try writer.print("{d}", .{receipt.branch_epoch});
        }
        if (receipt.tree_digest.len > 0) {
            try writer.writeAll(",\"tree_digest\":");
            try std.json.Stringify.value(receipt.tree_digest, .{}, writer);
        }
        if (receipt.dependency_resources.len > 0) {
            try writer.writeAll(",\"dependency_resources\":");
            try writeJsonStringArray(writer, receipt.dependency_resources);
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeGraphEnvelopeObject(writer: anytype, graph: GraphEnvelope) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"version\":");
    try writer.print("{d}", .{graph.version});
    try writer.writeAll(",\"policy\":");
    try writeGraphPolicyObject(writer, graph.policy);
    try writer.writeAll(",\"lineage\":");
    try writeGraphLineageObject(writer, graph.lineage);
    try writer.writeAll(",\"intent\":");
    try writeIntentArray(writer, graph.intent);
    try writer.writeAll(",\"waivers\":");
    try writeWaiversArray(writer, graph.waivers);
    try writer.writeAll(",\"debt\":");
    try writeGraphDebtArray(writer, graph.debt);
    try writer.writeAll(",\"proof_actions\":");
    try writeProofActionsArray(writer, graph.proof_actions);
    try writer.writeAll(",\"polish\":");
    try writePolishStateObject(writer, graph.polish);
    try writer.writeAll(",\"fingerprints\":");
    try writeGraphFingerprintsObject(writer, graph.fingerprints);
    try writer.writeByte('}');
}

fn writeProofActionsArray(writer: anytype, actions: []const ProofAction) !void {
    try writer.writeByte('[');
    for (actions, 0..) |action, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"id\":");
        try std.json.Stringify.value(action.id, .{}, writer);
        try writer.writeAll(",\"command\":");
        try std.json.Stringify.value(action.command, .{}, writer);
        try writer.writeAll(",\"cost\":");
        try writer.print("{d}", .{action.cost});
        try writer.writeAll(",\"covers\":[");
        for (action.covers, 0..) |cover, cover_idx| {
            if (cover_idx > 0) try writer.writeByte(',');
            try writer.writeAll("{\"item_id\":");
            try std.json.Stringify.value(cover.item_id, .{}, writer);
            try writer.writeAll(",\"obligation_id\":");
            try std.json.Stringify.value(cover.obligation_id, .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"scope\":");
        try writeStringListArray(writer, action.scope);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeGraphPolicyObject(writer: anytype, policy: GraphPolicy) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"completion_requires_proof\":");
    try writer.writeAll(if (policy.completion_requires_proof) "true" else "false");
    try writer.writeAll(",\"implementation_ready_required\":");
    try writer.writeAll(if (policy.implementation_ready_required) "true" else "false");
    try writer.writeAll(",\"graph_control_required\":");
    try writer.writeAll(if (policy.graph_control_required) "true" else "false");
    try writer.writeAll(",\"default_projection_strategy\":");
    try std.json.Stringify.value(policy.default_projection_strategy, .{}, writer);
    try writer.writeAll(",\"default_gate\":");
    try std.json.Stringify.value(policy.default_gate, .{}, writer);
    try writer.writeAll(",\"default_parallelism\":");
    try std.json.Stringify.value(policy.default_parallelism, .{}, writer);
    try writer.writeAll(",\"max_aperture_items\":");
    try writer.print("{d}", .{policy.max_aperture_items});
    try writer.writeAll(",\"blocking_debt_policy\":");
    try std.json.Stringify.value(policy.blocking_debt_policy, .{}, writer);
    try writer.writeByte('}');
}

fn writeGraphLineageObject(writer: anytype, lineage: GraphLineage) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"mode\":");
    try std.json.Stringify.value(lineage.mode, .{}, writer);
    try writer.writeAll(",\"materiality\":");
    try std.json.Stringify.value(lineage.materiality, .{}, writer);
    try writer.writeAll(",\"source\":{\"kind\":");
    try std.json.Stringify.value(lineage.source.kind, .{}, writer);
    try writer.writeAll(",\"locator\":");
    try std.json.Stringify.value(lineage.source.locator, .{}, writer);
    try writer.writeAll(",\"fingerprint\":");
    try std.json.Stringify.value(lineage.source.fingerprint, .{}, writer);
    try writer.writeByte('}');
    if (lineage.intake_id.len > 0) {
        try writer.writeAll(",\"intake_id\":");
        try std.json.Stringify.value(lineage.intake_id, .{}, writer);
    }
    if (lineage.compiled_at.len > 0) {
        try writer.writeAll(",\"compiled_at\":");
        try std.json.Stringify.value(lineage.compiled_at, .{}, writer);
    }
    try writer.writeAll(",\"last_audited_seq\":");
    try writer.print("{d}", .{lineage.last_audited_seq});
    if (lineage.last_audit_gate.len > 0) {
        try writer.writeAll(",\"last_audit_gate\":");
        try std.json.Stringify.value(lineage.last_audit_gate, .{}, writer);
    }
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

fn writeGraphDebtArray(writer: anytype, debts: []const GraphDebt) !void {
    try writer.writeByte('[');
    for (debts, 0..) |debt, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeGraphDebtObject(writer, debt);
    }
    try writer.writeByte(']');
}

fn writeGraphDebtObject(writer: anytype, debt: GraphDebt) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"debt_version\":");
    try std.json.Stringify.value(debt.debt_version, .{}, writer);
    try writer.writeAll(",\"id\":");
    try std.json.Stringify.value(debt.id, .{}, writer);
    try writer.writeAll(",\"code\":");
    try std.json.Stringify.value(debt.code, .{}, writer);
    try writer.writeAll(",\"severity\":");
    try std.json.Stringify.value(debt.severity, .{}, writer);
    try writer.writeAll(",\"target\":");
    try std.json.Stringify.value(debt.target, .{}, writer);
    try writer.writeAll(",\"source\":");
    try std.json.Stringify.value(debt.source, .{}, writer);
    try writer.writeAll(",\"reason\":");
    try std.json.Stringify.value(debt.reason, .{}, writer);
    if (debt.created_at.len > 0) {
        try writer.writeAll(",\"created_at\":");
        try std.json.Stringify.value(debt.created_at, .{}, writer);
    }
    if (debt.resolved_at.len > 0) {
        try writer.writeAll(",\"resolved_at\":");
        try std.json.Stringify.value(debt.resolved_at, .{}, writer);
    }
    if (debt.waiver_id.len > 0) {
        try writer.writeAll(",\"waiver_id\":");
        try std.json.Stringify.value(debt.waiver_id, .{}, writer);
    }
    try writer.writeByte('}');
}

fn writeGraphDebtFilteredArray(writer: anytype, debts: []const GraphDebt, severity: []const u8) !void {
    try writer.writeByte('[');
    var emitted: usize = 0;
    for (debts) |debt| {
        if (debt.resolved_at.len > 0) continue;
        if (!std.mem.eql(u8, debt.severity, severity)) continue;
        if (emitted > 0) try writer.writeByte(',');
        try writeGraphDebtObject(writer, debt);
        emitted += 1;
    }
    try writer.writeByte(']');
}

fn computeGraphDebtAlloc(allocator: std.mem.Allocator, state: *const ItemState, now: []const u8) ![]const GraphDebt {
    var out = std.ArrayList(GraphDebt).empty;
    for (state.graph.debt) |debt| {
        if (debt.resolved_at.len > 0) {
            try out.append(allocator, debt);
        }
    }

    const material = std.mem.eql(u8, state.graph.lineage.materiality, "material");
    if (!state.graph_active) return try out.toOwnedSlice(allocator);

    if (!std.mem.eql(u8, state.graph.lineage.materiality, "material") and
        !std.mem.eql(u8, state.graph.lineage.materiality, "simple"))
    {
        try appendGeneratedDebt(allocator, state, &out, "materiality-unknown", "blocking", "graph", "graph materiality is unknown", now);
    }

    if (material and state.graph.intent.len == 0) {
        try appendGeneratedDebt(allocator, state, &out, "intent-coverage-missing", "blocking", "graph", "material graph has no intent atoms", now);
    }

    for (state.items.items) |item| {
        if (!isExecutableItem(item) or isTerminalStatus(item.status)) continue;
        if (material and item.intent_refs.len == 0) {
            try appendGeneratedDebt(allocator, state, &out, "intent-coverage-missing", "blocking", item.id, "material executable item has no intent coverage", now);
        }
        if (material and item.contract == null) {
            try appendGeneratedDebt(allocator, state, &out, "implementation-ready-audit-missing", "blocking", item.id, "material executable item has no contract", now);
        }
        if (material and !itemHasProofObligations(item)) {
            try appendGeneratedDebt(allocator, state, &out, "proof-obligations-missing", "blocking", item.id, "material executable item has no proof obligations", now);
        }
        if (apertureLockRootsForItem(item).len == 0) {
            try appendGeneratedDebt(allocator, state, &out, "lock-roots-missing", if (material) "warning" else "warning", item.id, "item has no lock roots or locations for safe wave planning", now);
        }
        if (item.proof != null and item.contract != null and item.contract.?.proof_obligations.len > 1) {
            try appendGeneratedDebt(allocator, state, &out, "legacy-single-proof", "warning", item.id, "legacy single proof cannot represent several obligations exactly", now);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn appendGeneratedDebt(
    allocator: std.mem.Allocator,
    state: *const ItemState,
    out: *std.ArrayList(GraphDebt),
    code: []const u8,
    severity: []const u8,
    target: []const u8,
    reason: []const u8,
    now: []const u8,
) !void {
    const id = try debtIdAlloc(allocator, code, target);
    if (debtAlreadyAppended(out.items, id)) return;
    var debt = GraphDebt{
        .id = id,
        .code = code,
        .severity = severity,
        .target = target,
        .source = "automatic",
        .reason = reason,
        .created_at = now,
    };
    if (findExistingDebt(state.graph.debt, id)) |existing| {
        debt.created_at = if (existing.created_at.len > 0) existing.created_at else now;
        debt.resolved_at = existing.resolved_at;
        debt.waiver_id = existing.waiver_id;
    }
    if (debt.waiver_id.len == 0) {
        if (findActiveDebtWaiver(state.graph.waivers, code, target)) |waiver_id| debt.waiver_id = waiver_id;
    }
    try out.append(allocator, debt);
}

fn debtIdAlloc(allocator: std.mem.Allocator, code: []const u8, target: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "debt-");
    try appendDebtIdSegment(allocator, &out, code);
    try out.append(allocator, '-');
    try appendDebtIdSegment(allocator, &out, target);
    return out.toOwnedSlice(allocator);
}

fn appendDebtIdSegment(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    for (raw) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-') {
            try out.append(allocator, std.ascii.toLower(byte));
        } else {
            try out.append(allocator, '-');
        }
    }
}

fn debtAlreadyAppended(debts: []const GraphDebt, id: []const u8) bool {
    for (debts) |debt| {
        if (std.mem.eql(u8, debt.id, id)) return true;
    }
    return false;
}

fn findExistingDebt(debts: []const GraphDebt, id: []const u8) ?GraphDebt {
    for (debts) |debt| {
        if (std.mem.eql(u8, debt.id, id)) return debt;
    }
    return null;
}

fn findActiveDebtWaiver(waivers: []const Waiver, code: []const u8, target: []const u8) ?[]const u8 {
    for (waivers) |waiver| {
        if (!std.mem.eql(u8, waiver.code, code)) continue;
        if (!std.mem.eql(u8, waiver.target, target)) continue;
        if (std.mem.eql(u8, waiver.expires, "expired")) continue;
        return waiver.id;
    }
    return null;
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
    item_id: ?[]const u8,
) !void {
    const enriched = try enrichItems(allocator, state);
    const filtered = if (item_id) |id|
        try filterRowsById(allocator, enriched, id)
    else
        try filterRowsBySurface(allocator, enriched, surface);

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
        proofReceiptsEqual(lhs.proof_receipts, rhs.proof_receipts) and
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

fn proofReceiptsEqual(lhs: []const ProofReceipt, rhs: []const ProofReceipt) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left.receipt_version, right.receipt_version) or
            !std.mem.eql(u8, left.obligation_id, right.obligation_id) or
            !std.mem.eql(u8, left.action_id, right.action_id) or
            !std.mem.eql(u8, left.state, right.state) or
            !std.mem.eql(u8, left.command, right.command) or
            !std.mem.eql(u8, left.evidence_ref, right.evidence_ref) or
            !std.mem.eql(u8, left.artifact_ref, right.artifact_ref) or
            !std.mem.eql(u8, left.recorded_at, right.recorded_at) or
            !std.mem.eql(u8, left.waiver_id, right.waiver_id) or
            !std.mem.eql(u8, left.workspace_id, right.workspace_id) or
            left.workspace_sequence != right.workspace_sequence or
            !std.mem.eql(u8, left.plan_id, right.plan_id) or
            left.plan_sequence != right.plan_sequence or
            left.branch_epoch != right.branch_epoch or
            !std.mem.eql(u8, left.tree_digest, right.tree_digest) or
            !stringSlicesEqual(left.dependency_resources, right.dependency_resources)) return false;
    }
    return true;
}

fn stringSlicesEqual(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
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

fn filterRowsById(
    allocator: std.mem.Allocator,
    rows: []const EnrichedItem,
    item_id: []const u8,
) ![]EnrichedItem {
    var filtered = std.ArrayList(EnrichedItem).empty;
    for (rows) |row| {
        if (std.mem.eql(u8, row.item.id, item_id)) {
            try filtered.append(allocator, row);
            break;
        }
    }
    if (filtered.items.len == 0) return error.UnknownItemId;
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
    const proof_receipts = if (obj.get("proof_receipts")) |v| try normalizeProofReceipts(allocator, v) else &.{};
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
        .proof_receipts = proof_receipts,
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

fn normalizeProofReceipts(allocator: std.mem.Allocator, value: std.json.Value) ![]const ProofReceipt {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(ProofReceipt).empty;
            for (arr.items) |entry| try out.append(allocator, try canonicalProofReceipt(allocator, entry));
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidItem,
    };
}

fn canonicalProofReceipt(allocator: std.mem.Allocator, value: std.json.Value) !ProofReceipt {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidItem,
    };
    return .{
        .receipt_version = if (obj.get("receipt_version")) |v| try optionalStringValue(allocator, v, "PRF-v2") else "PRF-v2",
        .obligation_id = try requireNonEmptyString(allocator, asString(obj.get("obligation_id") orelse return error.InvalidItem) orelse return error.InvalidItem, "proof_receipt.obligation_id"),
        .action_id = try optionalObjectString(allocator, obj, "action_id"),
        .state = if (obj.get("state")) |v| try optionalStringValue(allocator, v, "not_run") else "not_run",
        .command = try optionalObjectString(allocator, obj, "command"),
        .evidence_ref = try optionalObjectString(allocator, obj, "evidence_ref"),
        .artifact_ref = try optionalObjectString(allocator, obj, "artifact_ref"),
        .recorded_at = try optionalObjectString(allocator, obj, "recorded_at"),
        .waiver_id = try optionalObjectString(allocator, obj, "waiver_id"),
        .workspace_id = try optionalObjectString(allocator, obj, "workspace_id"),
        .workspace_sequence = if (obj.get("workspace_sequence")) |v| switch (v) {
            .integer => |n| n,
            .null => -1,
            else => return error.InvalidItem,
        } else -1,
        .plan_id = try optionalObjectString(allocator, obj, "plan_id"),
        .plan_sequence = if (obj.get("plan_sequence")) |v| switch (v) {
            .integer => |n| n,
            .null => -1,
            else => return error.InvalidItem,
        } else -1,
        .branch_epoch = if (obj.get("branch_epoch")) |v| switch (v) {
            .integer => |n| n,
            .null => -1,
            else => return error.InvalidItem,
        } else -1,
        .tree_digest = try optionalObjectString(allocator, obj, "tree_digest"),
        .dependency_resources = try jsonStringListValue(allocator, obj.get("dependency_resources")),
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
        .lineage = if (obj.get("lineage")) |v| try canonicalGraphLineage(allocator, v) else .{},
        .intent = if (obj.get("intent")) |v| try normalizeIntentAtoms(allocator, v) else &.{},
        .waivers = if (obj.get("waivers")) |v| try normalizeWaivers(allocator, v) else &.{},
        .debt = if (obj.get("debt")) |v| try normalizeGraphDebt(allocator, v) else &.{},
        .proof_actions = if (obj.get("proof_actions")) |v| try normalizeProofActions(allocator, v) else &.{},
        .polish = if (obj.get("polish")) |v| try canonicalPolishState(allocator, v) else .{},
        .fingerprints = if (obj.get("fingerprints")) |v| try canonicalGraphFingerprints(allocator, v) else .{},
    };
}

fn normalizeProofActions(allocator: std.mem.Allocator, value: std.json.Value) ![]const ProofAction {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(ProofAction).empty;
            for (arr.items) |entry| try out.append(allocator, try canonicalProofAction(allocator, entry));
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidGraphEnvelope,
    };
}

fn canonicalProofAction(allocator: std.mem.Allocator, value: std.json.Value) !ProofAction {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidGraphEnvelope,
    };
    return .{
        .id = try requireNonEmptyString(allocator, asString(obj.get("id") orelse return error.InvalidGraphEnvelope) orelse return error.InvalidGraphEnvelope, "proof_action.id"),
        .command = try requireNonEmptyString(allocator, asString(obj.get("command") orelse return error.InvalidGraphEnvelope) orelse return error.InvalidGraphEnvelope, "proof_action.command"),
        .cost = try optionalObjectInt(obj, "cost", 1, error.InvalidGraphEnvelope),
        .covers = if (obj.get("covers")) |v| try normalizeProofCovers(allocator, v) else &.{},
        .scope = if (obj.get("scope")) |v| try normalizeStringList(allocator, v) else &.{},
    };
}

fn normalizeProofCovers(allocator: std.mem.Allocator, value: std.json.Value) ![]const ProofCover {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(ProofCover).empty;
            for (arr.items) |entry| {
                const obj = switch (entry) {
                    .object => |o| o,
                    else => return error.InvalidGraphEnvelope,
                };
                try out.append(allocator, .{
                    .item_id = try requireNonEmptyString(allocator, asString(obj.get("item_id") orelse return error.InvalidGraphEnvelope) orelse return error.InvalidGraphEnvelope, "proof_action.cover.item_id"),
                    .obligation_id = try requireNonEmptyString(allocator, asString(obj.get("obligation_id") orelse return error.InvalidGraphEnvelope) orelse return error.InvalidGraphEnvelope, "proof_action.cover.obligation_id"),
                });
            }
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidGraphEnvelope,
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
        .graph_control_required = try optionalObjectBool(obj, "graph_control_required", false),
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
        .default_parallelism = if (obj.get("default_parallelism")) |v| switch (v) {
            .string => |s| s,
            .null => "auto",
            else => return error.InvalidGraphPolicy,
        } else "auto",
        .max_aperture_items = if (obj.get("max_aperture_items")) |v| switch (v) {
            .integer => |n| n,
            .null => 7,
            else => return error.InvalidGraphPolicy,
        } else 7,
        .blocking_debt_policy = if (obj.get("blocking_debt_policy")) |v| switch (v) {
            .string => |s| s,
            .null => "warn",
            else => return error.InvalidGraphPolicy,
        } else "warn",
    };
}

fn canonicalGraphLineage(allocator: std.mem.Allocator, value: std.json.Value) !GraphLineage {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidGraphEnvelope,
    };
    return .{
        .mode = if (obj.get("mode")) |v| try optionalStringValue(allocator, v, "legacy") else "legacy",
        .materiality = if (obj.get("materiality")) |v| try optionalStringValue(allocator, v, "unknown") else "unknown",
        .source = if (obj.get("source")) |v| try canonicalGraphLineageSource(allocator, v) else .{},
        .intake_id = try optionalObjectString(allocator, obj, "intake_id"),
        .compiled_at = try optionalObjectString(allocator, obj, "compiled_at"),
        .last_audited_seq = try optionalObjectInt(obj, "last_audited_seq", 0, error.InvalidGraphEnvelope),
        .last_audit_gate = try optionalObjectString(allocator, obj, "last_audit_gate"),
    };
}

fn canonicalGraphLineageSource(allocator: std.mem.Allocator, value: std.json.Value) !GraphLineageSource {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidGraphEnvelope,
    };
    return .{
        .kind = try optionalObjectString(allocator, obj, "kind"),
        .locator = try optionalObjectString(allocator, obj, "locator"),
        .fingerprint = try optionalObjectString(allocator, obj, "fingerprint"),
    };
}

fn optionalStringValue(allocator: std.mem.Allocator, value: std.json.Value, default_value: []const u8) ![]const u8 {
    _ = allocator;
    return switch (value) {
        .string => |s| s,
        .null => default_value,
        else => error.InvalidGraphEnvelope,
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

fn normalizeGraphDebt(allocator: std.mem.Allocator, value: std.json.Value) ![]const GraphDebt {
    return switch (value) {
        .null => &.{},
        .array => |arr| blk: {
            var out = std.ArrayList(GraphDebt).empty;
            for (arr.items) |entry| try out.append(allocator, try canonicalGraphDebt(allocator, entry));
            if (out.items.len == 0) break :blk &.{};
            break :blk try out.toOwnedSlice(allocator);
        },
        else => error.InvalidGraphEnvelope,
    };
}

fn canonicalGraphDebt(allocator: std.mem.Allocator, value: std.json.Value) !GraphDebt {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidGraphEnvelope,
    };
    return .{
        .debt_version = if (obj.get("debt_version")) |v| try optionalStringValue(allocator, v, "GD-v1") else "GD-v1",
        .id = try requireNonEmptyString(allocator, asString(obj.get("id") orelse return error.InvalidGraphEnvelope) orelse return error.InvalidGraphEnvelope, "debt.id"),
        .code = try requireNonEmptyString(allocator, asString(obj.get("code") orelse return error.InvalidGraphEnvelope) orelse return error.InvalidGraphEnvelope, "debt.code"),
        .severity = try requireNonEmptyString(allocator, asString(obj.get("severity") orelse return error.InvalidGraphEnvelope) orelse return error.InvalidGraphEnvelope, "debt.severity"),
        .target = try requireNonEmptyString(allocator, asString(obj.get("target") orelse return error.InvalidGraphEnvelope) orelse return error.InvalidGraphEnvelope, "debt.target"),
        .source = if (obj.get("source")) |v| try optionalStringValue(allocator, v, "automatic") else "automatic",
        .reason = try requireNonEmptyString(allocator, asString(obj.get("reason") orelse return error.InvalidGraphEnvelope) orelse return error.InvalidGraphEnvelope, "debt.reason"),
        .created_at = try optionalObjectString(allocator, obj, "created_at"),
        .resolved_at = try optionalObjectString(allocator, obj, "resolved_at"),
        .waiver_id = try optionalObjectString(allocator, obj, "waiver_id"),
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
    return durable_store.ensureLockSidecarGitignored(allocator, plan_file);
}

fn fileExists(path: []const u8) bool {
    return durable_store.fileExists(path);
}

fn fileSize(path: []const u8) !u64 {
    return durable_store.fileSize(path);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]const u8 {
    return durable_store.readFileAlloc(allocator, path, max_bytes);
}

fn writeTextAtomic(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    return durable_store.writeTextAtomic(allocator, path, text);
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
    try std.testing.expectEqual(Command.intake, parseCommand("intake").?);
    try std.testing.expectEqual(Command.workspace, parseCommand("workspace").?);
    try std.testing.expectEqual(Command.plan, parseCommand("plan").?);
    try std.testing.expectEqual(Command.capabilities, parseCommand("capabilities").?);
    try std.testing.expectEqual(Command.complete, parseCommand("complete").?);
    try std.testing.expectEqual(Command.proof, parseCommand("proof").?);
    try std.testing.expectEqual(IntakeCommand.plan, parseIntakeCommand("plan").?);
    try std.testing.expectEqual(IntakeCommand.scaffold, parseIntakeCommand("scaffold").?);
    try std.testing.expectEqual(IntakeCommand.apply, parseIntakeCommand("apply").?);
    try std.testing.expectEqual(GraphCommand.apply, parseGraphCommand("apply").?);
    try std.testing.expectEqual(GraphCommand.insights, parseGraphCommand("insights").?);
    try std.testing.expectEqual(PolishCommand.snapshot, parsePolishCommand("snapshot").?);
    try std.testing.expectEqual(ApertureCommand.select, parseApertureCommand("select").?);
    try std.testing.expectEqual(CompileCommand.aperture, parseCompileCommand("aperture").?);
    try std.testing.expectEqual(ProofCommand.audit, parseProofCommand("audit").?);
    try std.testing.expectEqual(ProofCommand.plan, parseProofCommand("plan").?);
    try std.testing.expectEqual(ProofCommand.record, parseProofCommand("record").?);
    try std.testing.expectEqual(WorkspaceCommand.aperture, parseWorkspaceCommand("aperture").?);
    try std.testing.expectEqual(WorkspaceCommand.init, parseWorkspaceCommand("init").?);
    try std.testing.expectEqual(WorkspaceCommand.status, parseWorkspaceCommand("status").?);
    try std.testing.expectEqual(PlanCommand.create, parsePlanCommand("create").?);
    try std.testing.expectEqual(PlanCommand.list, parsePlanCommand("list").?);
    try std.testing.expectEqual(PlanCommand.show, parsePlanCommand("show").?);
    try std.testing.expectEqual(PlanCommand.pause, parsePlanCommand("pause").?);
    try std.testing.expectEqual(PlanCommand.@"resume", parsePlanCommand("resume").?);
    try std.testing.expectEqual(PlanCommand.complete, parsePlanCommand("complete").?);
    try std.testing.expectEqual(PlanCommand.archive, parsePlanCommand("archive").?);
    try std.testing.expectEqual(PlanCommand.link, parsePlanCommand("link").?);
    try std.testing.expectEqual(PlanCommand.unlink, parsePlanCommand("unlink").?);
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

test "commandHelpTextForArgv resolves command-specific help" {
    const prime_help = commandHelpTextForArgv(&.{ "st", "prime", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, prime_help, "usage: st prime --file PATH [options]") != null);
    try std.testing.expect(std.mem.indexOf(u8, prime_help, "usage: st {") == null);

    const show_help = commandHelpTextForArgv(&.{ "st", "show", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, show_help, "usage: st show --file PATH [--id ID]") != null);

    const complete_help = commandHelpTextForArgv(&.{ "st", "complete", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, complete_help, "usage: st complete --file PATH --id ID [--command CMD --evidence-ref REF] [options]") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_help, "using current proof receipts") != null);
}

test "show parses item id selector" {
    const args = try parseArgs(&.{
        "st",
        "show",
        "--file",
        ".step/st-plan.jsonl",
        "--id",
        "st-001",
        "--format",
        "json",
    });

    try std.testing.expectEqual(Command.show, args.command);
    try std.testing.expectEqual(OutputFormat.json, args.format);
    try std.testing.expectEqualStrings("st-001", args.id.?);
}

test "commandHelpTextForArgv resolves nested command help" {
    const graph_help = commandHelpTextForArgv(&.{ "st", "graph", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, graph_help, "usage: st graph {schema,apply,audit,insights,polish,debt} --file PATH [options]") != null);

    const audit_help = commandHelpTextForArgv(&.{ "st", "graph", "audit", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, audit_help, "usage: st graph audit --file PATH [--gate GATE] [--format markdown|json]") != null);

    const polish_help = commandHelpTextForArgv(&.{ "st", "graph", "polish", "snapshot", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, polish_help, "usage: st graph polish snapshot --file PATH --pass N [--gate GATE]") != null);

    const compile_aperture_help = commandHelpTextForArgv(&.{ "st", "compile", "aperture", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, compile_aperture_help, "usage: st compile aperture --file PATH [--limit N] [--parallelism auto]") != null);
    try std.testing.expect(std.mem.indexOf(u8, compile_aperture_help, "Legacy no-op compatibility alias") != null);

    const plan_create_help = commandHelpTextForArgv(&.{ "st", "plan", "create", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, plan_create_help, "usage: st plan create --workspace PATH --plan PLAN_ID") != null);

    const plan_pause_help = commandHelpTextForArgv(&.{ "st", "plan", "pause", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, plan_pause_help, "usage: st plan {pause,resume,complete,archive}") != null);

    const plan_link_help = commandHelpTextForArgv(&.{ "st", "plan", "link", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, plan_link_help, "usage: st plan link --workspace PATH --from plan://PLAN/ITEM") != null);

    const workspace_migrate_help = commandHelpTextForArgv(&.{ "st", "workspace", "migrate", "--help" }).?;
    try std.testing.expect(std.mem.indexOf(u8, workspace_migrate_help, "usage: st workspace migrate --from PATH --to PATH --plan-id PLAN_ID") != null);
}

test "compile aperture accepts legacy parallelism auto flag" {
    const args = try parseArgs(&.{
        "st",
        "compile",
        "aperture",
        "--file",
        ".step/st-plan.jsonl",
        "--limit",
        "7",
        "--parallelism",
        "auto",
    });

    try std.testing.expectEqual(Command.compile, args.command);
    try std.testing.expectEqual(CompileCommand.aperture, args.compile_command);
    try std.testing.expectEqual(@as(usize, 7), args.limit);
}

test "compile aperture rejects unsupported parallelism values" {
    try std.testing.expectError(error.InvalidCompileArg, parseArgs(&.{
        "st",
        "compile",
        "aperture",
        "--parallelism",
        "wide",
    }));
}

test "show id selector returns one matching item across surfaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{
        .id = "st-001",
        .step = "Selected task",
        .status = .pending,
        .priority = .high,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });
    try state.upsert(.{
        .id = "st-002",
        .step = "Backlog task",
        .status = .pending,
        .priority = .medium,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try renderShow(allocator, &out.writer, &state, .json, .plan, "st-002");
    try out.writer.writeByte('\n');
    const actual = try out.toOwnedSlice();

    try std.testing.expect(std.mem.indexOf(u8, actual, "\"id\":\"st-002\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "\"id\":\"st-001\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "\"in_plan\":false") != null);
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

test "intake plan writes markdown scaffold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const out_path = try std.fs.path.join(allocator, &.{ root, "st-intake.md" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdIntake(allocator, .{ .command = .intake, .intake_command = .scaffold, .source = "PLAN.md", .output = out_path }));

    const got = try readFileAlloc(allocator, out_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, got, "Source: PLAN.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "st intake apply") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "### st-001 | feature | high") != null);
}

test "capabilities command emits successfully" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdCapabilities(allocator, .{ .command = .capabilities, .format = .json }));
}

test "workspace init creates STW-v1 skeleton and refuses overwrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectError(error.PathAlreadyExists, cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .status, .workspace = workspace_path, .format = .json }));

    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_path, "workspace.jsonl" });
    const payload = try durable_store.readRegularFileNoSymlink(allocator, workspace_file, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"schema\":\"STW-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"workspace_sequence\":1") != null);
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ workspace_path, "runtime", "sessions" })));
    try std.testing.expect(fileExists(try std.fs.path.join(allocator, &.{ workspace_path, "integration", "receipts" })));
}

test "workspace migrate preserves graph plan parity and is idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const legacy_dir = try std.fs.path.join(allocator, &.{ root, ".step" });
    try durable_store.ensureDirectoryPathNoSymlinks(legacy_dir);
    const legacy_path = try std.fs.path.join(allocator, &.{ legacy_dir, "st-plan.jsonl" });
    const patch_path = try std.fs.path.join(allocator, &.{ root, "patch.json" });
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });
    try writeTextAtomic(allocator, patch_path,
        \\{"version":1,"author":"test","reason":"migration fixture","ops":[
        \\{"op":"upsert-intent","intent":{"id":"intent-001","text":"Migration preserves graph state.","category":"requirement","disposition":"covered"}},
        \\{"op":"upsert-item","item":{"id":"st-001","step":"Migrate graph fixture","status":"pending","priority":"high","in_plan":true,"item_type":"feature","intent_refs":["intent-001"],"acceptance":["State survives migration"],"validation":["zig build test-st"],"lock_roots":["apps/st"],"contract":{"objective":"Exercise workspace migration.","proof_obligations":[{"id":"proof-001","kind":"unit","command":"zig build test-st","required":true}]}}}
        \\]}
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = legacy_path, .input = patch_path, .gate = .implementation_ready }));
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .migrate, .from_ref = legacy_path, .to_ref = workspace_path, .workspace = workspace_path, .plan_id = "default", .format = .json }));
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .migrate, .from_ref = legacy_path, .to_ref = workspace_path, .workspace = workspace_path, .plan_id = "default", .format = .json }));

    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_path, "workspace.jsonl" });
    const plan_file = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "default", "plan.jsonl" });
    const receipt_file = try std.fs.path.join(allocator, &.{ workspace_path, "migration", "receipt.json" });
    const source_archive = try std.fs.path.join(allocator, &.{ workspace_path, "migration", "source", "st-plan.jsonl" });
    try std.testing.expect(fileExists(workspace_file));
    try std.testing.expect(fileExists(plan_file));
    try std.testing.expect(fileExists(receipt_file));
    try std.testing.expect(fileExists(source_archive));

    var legacy_loaded = try loadValidatedState(allocator, legacy_path, true);
    defer legacy_loaded.state.deinit();
    var migrated_loaded = try loadValidatedState(allocator, plan_file, true);
    defer migrated_loaded.state.deinit();
    try assertMigrationParity(allocator, &legacy_loaded.state, &migrated_loaded.state, legacy_loaded.latest_seq, migrated_loaded.latest_seq);

    const plan_bytes = try durable_store.readRegularFileNoSymlink(allocator, plan_file, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, plan_bytes, "\"plan_id\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_bytes, "\"plan_sequence\":") != null);

    const workspace_line = try readLastJsonlLine(allocator, workspace_file);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, workspace_line, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), intField(parsed.value, "workspace_sequence").?);
    const plans = parsed.value.object.get("plans") orelse return error.WorkspaceInvalid;
    try std.testing.expectEqual(@as(usize, 1), plans.array.items.len);
    try std.testing.expectEqualStrings("default", stringField(plans.array.items[0], "plan_id").?);
    try std.testing.expectEqual(legacy_loaded.latest_seq, intField(plans.array.items[0], "plan_sequence").?);

    const receipt_bytes = try durable_store.readRegularFileNoSymlink(allocator, receipt_file, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, "\"state\":\"idempotent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, "\"parity\":\"pass\"") != null);
}

test "plan create registers plan and rejects duplicate ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "default", .name = "Default Plan", .format = .json }));
    try std.testing.expectError(error.PlanAlreadyExists, cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "default" }));
    try std.testing.expectError(error.InvalidPlanId, cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "../escape" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .list, .workspace = workspace_path, .format = .json }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .show, .workspace = workspace_path, .plan_id = "default", .format = .json }));
    try std.testing.expectError(error.PlanMissing, cmdPlan(allocator, .{ .command = .plan, .plan_command = .show, .workspace = workspace_path, .plan_id = "missing" }));

    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_path, "workspace.jsonl" });
    const workspace_payload = try durable_store.readRegularFileNoSymlink(allocator, workspace_file, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, workspace_payload, "\"workspace_sequence\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, workspace_payload, "\"plan_id\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, workspace_payload, "\"graph_ref\":\"plans/default/plan.jsonl\"") != null);

    const plan_file = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "default", "plan.jsonl" });
    const plan_payload = try durable_store.readRegularFileNoSymlink(allocator, plan_file, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, plan_payload, "\"plan_id\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_payload, "\"plan_sequence\":1") != null);
}

test "workspace audit and doctor fail on missing registered plan file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "default" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .audit, .workspace = workspace_path, .format = .json }));
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .doctor, .workspace = workspace_path, .format = .json }));

    const plan_file = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "default", "plan.jsonl" });
    try std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), plan_file);

    try std.testing.expectEqual(@as(u8, 2), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .audit, .workspace = workspace_path, .format = .json }));
    try std.testing.expectEqual(@as(u8, 2), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .doctor, .workspace = workspace_path, .format = .json }));
}

test "plan lifecycle transitions update registry and active inference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "alpha" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "beta" }));

    try std.testing.expectError(error.InvalidPlanStateTransition, cmdPlan(allocator, .{ .command = .plan, .plan_command = .archive, .workspace = workspace_path, .plan_id = "beta" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .pause, .workspace = workspace_path, .plan_id = "beta", .format = .json }));
    try std.testing.expectError(error.InvalidPlanStateTransition, cmdPlan(allocator, .{ .command = .plan, .plan_command = .pause, .workspace = workspace_path, .plan_id = "beta" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .workspace_explicit = true, .id = "st-001", .step = "Inferred alpha after beta pause" }));

    const alpha_file = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "alpha", "plan.jsonl" });
    var alpha = try loadValidatedState(allocator, alpha_file, false);
    defer alpha.state.deinit();
    try std.testing.expectEqualStrings("Inferred alpha after beta pause", alpha.state.get("st-001").?.step);

    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .@"resume", .workspace = workspace_path, .plan_id = "beta" }));
    try std.testing.expectError(error.PlanAmbiguous, runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .workspace_explicit = true, .id = "st-002", .step = "Ambiguous after resume" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .complete, .workspace = workspace_path, .plan_id = "beta" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .archive, .workspace = workspace_path, .plan_id = "beta" }));
    try std.testing.expectError(error.InvalidPlanStateTransition, cmdPlan(allocator, .{ .command = .plan, .plan_command = .@"resume", .workspace = workspace_path, .plan_id = "beta" }));
    try std.testing.expectError(error.PlanMissing, cmdPlan(allocator, .{ .command = .plan, .plan_command = .pause, .workspace = workspace_path, .plan_id = "missing" }));

    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_path, "workspace.jsonl" });
    const workspace_payload = try durable_store.readRegularFileNoSymlink(allocator, workspace_file, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, workspace_payload, "\"workspace_sequence\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, workspace_payload, "\"plan_id\":\"beta\",\"alias\":\"beta\",\"state\":\"archived\"") != null);
}

test "plan link and unlink mutate workspace cross-plan edges only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "alpha" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "beta" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "alpha", .id = "st-001", .step = "Alpha task" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "beta", .id = "st-001", .step = "Beta task" }));

    const alpha_file = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "alpha", "plan.jsonl" });
    const beta_file = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "beta", "plan.jsonl" });
    const alpha_before = try durable_store.readRegularFileNoSymlink(allocator, alpha_file, 1024 * 1024);
    const beta_before = try durable_store.readRegularFileNoSymlink(allocator, beta_file, 1024 * 1024);

    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{
        .command = .plan,
        .plan_command = .link,
        .workspace = workspace_path,
        .from_ref = "plan://alpha/st-001",
        .to_ref = "plan://beta/st-001",
        .link_type = "hard",
        .format = .json,
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{
        .command = .plan,
        .plan_command = .link,
        .workspace = workspace_path,
        .from_ref = "plan://beta/st-001",
        .to_ref = "plan://alpha/st-001",
        .link_type = "nonblocking",
    }));

    const alpha_after = try durable_store.readRegularFileNoSymlink(allocator, alpha_file, 1024 * 1024);
    const beta_after = try durable_store.readRegularFileNoSymlink(allocator, beta_file, 1024 * 1024);
    try std.testing.expectEqualStrings(alpha_before, alpha_after);
    try std.testing.expectEqualStrings(beta_before, beta_after);

    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_path, "workspace.jsonl" });
    const linked_workspace = try durable_store.readRegularFileNoSymlink(allocator, workspace_file, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, linked_workspace, "\"from\":\"plan://alpha/st-001\",\"to\":\"plan://beta/st-001\",\"type\":\"hard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, linked_workspace, "\"from\":\"plan://beta/st-001\",\"to\":\"plan://alpha/st-001\",\"type\":\"nonblocking\"") != null);

    try std.testing.expectError(error.CrossPlanEdgeExists, cmdPlan(allocator, .{
        .command = .plan,
        .plan_command = .link,
        .workspace = workspace_path,
        .from_ref = "plan://alpha/st-001",
        .to_ref = "plan://beta/st-001",
        .link_type = "hard",
    }));
    try std.testing.expectError(error.PlanMissing, cmdPlan(allocator, .{
        .command = .plan,
        .plan_command = .link,
        .workspace = workspace_path,
        .from_ref = "plan://missing/st-001",
        .to_ref = "plan://beta/st-001",
    }));
    try std.testing.expectError(error.UnknownItemId, cmdPlan(allocator, .{
        .command = .plan,
        .plan_command = .link,
        .workspace = workspace_path,
        .from_ref = "plan://alpha/st-404",
        .to_ref = "plan://beta/st-001",
    }));
    try std.testing.expectError(error.InvalidQualifiedRef, cmdPlan(allocator, .{
        .command = .plan,
        .plan_command = .link,
        .workspace = workspace_path,
        .from_ref = "alpha/st-001",
        .to_ref = "plan://beta/st-001",
    }));

    const before_invalid = try durable_store.readRegularFileNoSymlink(allocator, workspace_file, 1024 * 1024);
    try std.testing.expectError(error.CrossPlanEdgeMissing, cmdPlan(allocator, .{
        .command = .plan,
        .plan_command = .unlink,
        .workspace = workspace_path,
        .from_ref = "plan://alpha/st-001",
        .to_ref = "plan://beta/st-001",
        .link_type = "nonblocking",
    }));
    const after_invalid = try durable_store.readRegularFileNoSymlink(allocator, workspace_file, 1024 * 1024);
    try std.testing.expectEqualStrings(before_invalid, after_invalid);

    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{
        .command = .plan,
        .plan_command = .unlink,
        .workspace = workspace_path,
        .from_ref = "plan://alpha/st-001",
        .to_ref = "plan://beta/st-001",
        .link_type = "hard",
    }));
    const unlinked_checkpoint = try readLastJsonlLine(allocator, workspace_file);
    try std.testing.expect(std.mem.indexOf(u8, unlinked_checkpoint, "\"from\":\"plan://alpha/st-001\",\"to\":\"plan://beta/st-001\",\"type\":\"hard\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, unlinked_checkpoint, "\"from\":\"plan://beta/st-001\",\"to\":\"plan://alpha/st-001\",\"type\":\"nonblocking\"") != null);
}

test "workspace aperture blocks hard cross-plan deps and ignores nonblocking links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "alpha" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "beta" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "alpha", .id = "st-blocked", .step = "Blocked alpha", .selection_priority = "high" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "alpha", .id = "st-free", .step = "Free alpha", .selection_priority = "high" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "beta", .id = "st-blocker", .step = "Beta blocker" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{
        .command = .plan,
        .plan_command = .link,
        .workspace = workspace_path,
        .from_ref = "plan://alpha/st-blocked",
        .to_ref = "plan://beta/st-blocker",
        .link_type = "hard",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{
        .command = .plan,
        .plan_command = .link,
        .workspace = workspace_path,
        .from_ref = "plan://alpha/st-free",
        .to_ref = "plan://beta/st-blocker",
        .link_type = "nonblocking",
    }));

    const workspace = try loadWorkspaceCheckpoint(allocator, workspace_path);
    defer workspace.deinit();
    const plans = workspace.parsed.value.object.get("plans") orelse return error.WorkspaceInvalid;
    const edges = workspace.parsed.value.object.get("cross_plan_edges") orelse return error.WorkspaceInvalid;
    try std.testing.expect((try workspaceHardDependencyBlocker(allocator, workspace.root, plans, edges, "plan://alpha/st-blocked")) != null);
    try std.testing.expect((try workspaceHardDependencyBlocker(allocator, workspace.root, plans, edges, "plan://alpha/st-free")) == null);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .aperture, .workspace = workspace_path, .format = .json }));
}

test "workspace aperture selects deterministic conflict-free candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "alpha" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "beta" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "alpha", .id = "st-a", .step = "Alpha A", .selection_priority = "high" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "beta", .id = "st-b", .step = "Beta B", .selection_priority = "high" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "beta", .id = "st-c", .step = "Beta C", .selection_priority = "medium" }));

    const alpha_file = try resolveWorkspacePlanFile(allocator, workspace_path, "alpha");
    const beta_file = try resolveWorkspacePlanFile(allocator, workspace_path, "beta");
    const alpha_patch = try std.fs.path.join(allocator, &.{ root, "alpha-locks.json" });
    const beta_patch = try std.fs.path.join(allocator, &.{ root, "beta-locks.json" });
    try writeTextAtomic(allocator, alpha_patch,
        \\{"version":1,"author":"test","reason":"alpha locks","ops":[
        \\{"op":"set-lock-roots","id":"st-a","lock_roots":["src/shared"]}
        \\]}
    );
    try writeTextAtomic(allocator, beta_patch,
        \\{"version":1,"author":"test","reason":"beta locks","ops":[
        \\{"op":"set-lock-roots","id":"st-b","lock_roots":["src/shared/api.zig"]},
        \\{"op":"set-lock-roots","id":"st-c","lock_roots":["docs"]}
        \\]}
    );
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = alpha_file, .input = alpha_patch, .gate = .draft }));
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = beta_file, .input = beta_patch, .gate = .draft }));

    const workspace = try loadWorkspaceCheckpoint(allocator, workspace_path);
    defer workspace.deinit();
    const now = try nowUtcAlloc(allocator);
    var alpha_state = try loadValidatedState(allocator, alpha_file, false);
    defer alpha_state.state.deinit();
    var beta_state = try loadValidatedState(allocator, beta_file, false);
    defer beta_state.state.deinit();
    const alpha = alpha_state.state.getConst("st-a").?;
    const beta = beta_state.state.getConst("st-b").?;
    const docs = beta_state.state.getConst("st-c").?;
    const alpha_resources = try workspaceResourcesForItem(allocator, alpha.*);
    const beta_resources = try workspaceResourcesForItem(allocator, beta.*);
    const docs_resources = try workspaceResourcesForItem(allocator, docs.*);
    try std.testing.expect(workspaceResourcesConflict(alpha_resources[0], beta_resources[0]));
    try std.testing.expect(!workspaceResourcesConflict(alpha_resources[0], docs_resources[0]));
    try std.testing.expect((try workspaceHeldClaimConflict(workspace.parsed.value.object, alpha_resources, now)) == null);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .aperture, .workspace = workspace_path, .format = .json }));
}

test "workspace resource grammar normalizes and rejects unsafe resources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try parseWorkspaceResource(allocator, "path:src//st\\workspace.zig", .write);
    try std.testing.expectEqual(WorkspaceResourceKind.path, path.kind);
    try std.testing.expectEqual(WorkspaceResourceMode.write, path.mode);
    try std.testing.expectEqualStrings("src/st/workspace.zig", path.primary);

    const symbol = try parseWorkspaceResource(allocator, "symbol:src/st/workspace.zig#WorkspaceClaim", .read);
    try std.testing.expectEqual(WorkspaceResourceKind.symbol, symbol.kind);
    try std.testing.expectEqualStrings("src/st/workspace.zig", symbol.primary);
    try std.testing.expectEqualStrings("WorkspaceClaim", symbol.secondary);

    const generated = try parseWorkspaceResource(allocator, "generated:OpenAPI.Client", .write);
    try std.testing.expectEqual(WorkspaceResourceKind.generated, generated.kind);
    try std.testing.expectEqualStrings("openapi.client", generated.primary);

    const branch = try parseWorkspaceResource(allocator, "git:branch:feature/st-workspace", .exclusive);
    try std.testing.expectEqual(WorkspaceResourceKind.git_branch, branch.kind);
    try std.testing.expectEqualStrings("feature/st-workspace", branch.primary);

    try std.testing.expectError(error.InvalidResource, parseWorkspaceResource(allocator, "path:/absolute", .write));
    try std.testing.expectError(error.InvalidResource, parseWorkspaceResource(allocator, "path:../escape", .write));
    try std.testing.expectError(error.InvalidResource, parseWorkspaceResource(allocator, "path:src/\x00bad", .write));
    try std.testing.expectError(error.InvalidResource, parseWorkspaceResource(allocator, "symbol:src/a.zig", .write));
    try std.testing.expectError(error.InvalidResource, parseWorkspaceResource(allocator, "generated:name/with/slash", .write));
    try std.testing.expectError(error.InvalidResource, parseWorkspaceResource(allocator, "git:branch:../main", .write));
}

test "workspace resource conflicts follow mode matrix and overlap rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path_read_a = try parseWorkspaceResource(allocator, "path:src/app.zig", .read);
    const path_read_b = try parseWorkspaceResource(allocator, "path:src/app.zig", .read);
    const path_write = try parseWorkspaceResource(allocator, "path:src/app.zig", .write);
    const dir_write = try parseWorkspaceResource(allocator, "path:src", .write);
    const other_write = try parseWorkspaceResource(allocator, "path:test/app.zig", .write);
    try std.testing.expect(!workspaceResourcesConflict(path_read_a, path_read_b));
    try std.testing.expect(workspaceResourcesConflict(path_read_a, path_write));
    try std.testing.expect(workspaceResourcesConflict(dir_write, path_write));
    try std.testing.expect(!workspaceResourcesConflict(path_write, other_write));

    const symbol_a = try parseWorkspaceResource(allocator, "symbol:src/app.zig#A", .write);
    const symbol_b = try parseWorkspaceResource(allocator, "symbol:src/app.zig#B", .write);
    const symbol_read = try parseWorkspaceResource(allocator, "symbol:src/app.zig#A", .read);
    try std.testing.expect(workspaceResourcesConflict(path_write, symbol_read));
    try std.testing.expect(workspaceResourcesConflict(symbol_a, symbol_b));

    const generated_a = try parseWorkspaceResource(allocator, "generated:client", .write);
    const generated_b = try parseWorkspaceResource(allocator, "generated:client", .read);
    const generated_c = try parseWorkspaceResource(allocator, "generated:server", .write);
    try std.testing.expect(workspaceResourcesConflict(generated_a, generated_b));
    try std.testing.expect(!workspaceResourcesConflict(generated_a, generated_c));

    const schema_a = try parseWorkspaceResource(allocator, "schema:events", .write);
    const schema_b = try parseWorkspaceResource(allocator, "schema:events", .write);
    const service_a = try parseWorkspaceResource(allocator, "service:api", .exclusive);
    const service_b = try parseWorkspaceResource(allocator, "service:api", .read);
    try std.testing.expect(workspaceResourcesConflict(schema_a, schema_b));
    try std.testing.expect(workspaceResourcesConflict(service_a, service_b));

    const git_index = try parseWorkspaceResource(allocator, "git:index", .write);
    const git_index_read = try parseWorkspaceResource(allocator, "git:index", .read);
    const git_branch = try parseWorkspaceResource(allocator, "git:branch:main", .write);
    try std.testing.expect(workspaceResourcesConflict(git_index, git_index_read));
    try std.testing.expect(!workspaceResourcesConflict(git_index, git_branch));

    const repo = try parseWorkspaceResource(allocator, "repo:all", .read);
    try std.testing.expect(workspaceResourcesConflict(repo, path_read_a));

    const unknown = try inferUnknownMutationResource(allocator);
    try std.testing.expectEqual(WorkspaceResourceKind.repo_all, unknown.resource.kind);
    try std.testing.expectEqual(WorkspaceResourceMode.exclusive, unknown.resource.mode);
    try std.testing.expectEqualStrings("low", unknown.confidence);
    try std.testing.expect(workspaceResourcesConflict(unknown.resource, other_write));
}

test "workspace claims grant disjoint resources and reject conflicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "default" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .workspace = workspace_path,
        .workspace_explicit = true,
        .session_id = "s1",
        .executor = "teams",
        .resources = "write:path:src/a.zig",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .workspace = workspace_path,
        .workspace_explicit = true,
        .session_id = "s2",
        .executor = "teams",
        .resources = "write:path:src/b.zig",
    }));
    try std.testing.expectError(error.ResourceConflict, cmdClaim(allocator, .{
        .command = .claim,
        .workspace = workspace_path,
        .workspace_explicit = true,
        .session_id = "s3",
        .executor = "teams",
        .resources = "write:path:src/a.zig",
    }));

    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_path, "workspace.jsonl" });
    const checkpoint = try readLastJsonlLine(allocator, workspace_file);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint, "\"claim_id\":\"claim-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint, "\"claim_id\":\"claim-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint, "\"fencing_counter\":2") != null);
}

test "workspace claim fencing validates heartbeat, reclaim, and amend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "default" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .workspace = workspace_path,
        .workspace_explicit = true,
        .session_id = "s1",
        .executor = "teams",
        .resources = "write:path:src/a.zig",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .claim_command = .heartbeat,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "s1",
        .fencing_token = "1",
    }));
    try std.testing.expectError(error.ClaimOwnerMismatch, cmdClaim(allocator, .{
        .command = .claim,
        .claim_command = .heartbeat,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "wrong",
        .fencing_token = "1",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .claim_command = .amend,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "s1",
        .fencing_token = "1",
        .resources = "write:path:src/a.zig,write:path:src/c.zig",
    }));
    try std.testing.expectError(error.FencingTokenStale, cmdClaim(allocator, .{
        .command = .claim,
        .claim_command = .heartbeat,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "s1",
        .fencing_token = "1",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .claim_command = .heartbeat,
        .workspace = workspace_path,
        .claim_id = "claim-2",
        .session_id = "s1",
        .fencing_token = "2",
    }));

    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .workspace = workspace_path,
        .workspace_explicit = true,
        .session_id = "s2",
        .executor = "teams",
        .lease_seconds = "1",
        .resources = "write:path:src/expired.zig",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .claim_command = .reclaim_stale,
        .workspace = workspace_path,
        .now = "2999-01-01T00:00:00Z",
    }));
    try std.testing.expectError(error.FencingTokenStale, cmdClaim(allocator, .{
        .command = .claim,
        .claim_command = .heartbeat,
        .workspace = workspace_path,
        .claim_id = "claim-3",
        .session_id = "s2",
        .fencing_token = "3",
    }));

    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_path, "workspace.jsonl" });
    const checkpoint = try readLastJsonlLine(allocator, workspace_file);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint, "\"claim_id\":\"claim-1\",\"state\":\"released\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint, "\"claim_id\":\"claim-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint, "\"claim_id\":\"claim-3\",\"state\":\"stale\"") != null);
}

fn runTestGit(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);
    var result = try runCommandCapture(allocator, argv.items, cwd);
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.TestGitCommandFailed;
}

test "external worktree and changeset sealing enforce claim path authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const repo_path = try std.fs.path.join(allocator, &.{ root, "repo" });
    const worktree_path = try std.fs.path.join(allocator, &.{ root, "worker" });
    const workspace_path = try std.fs.path.join(allocator, &.{ repo_path, ".ledger", "st" });
    try durable_store.ensureDirectoryPathNoSymlinks(repo_path);

    try runTestGit(allocator, repo_path, &.{ "init", "-b", "main" });
    const a_path = try std.fs.path.join(allocator, &.{ repo_path, "src", "a.txt" });
    const b_path = try std.fs.path.join(allocator, &.{ repo_path, "src", "b.txt" });
    try writeTextAtomic(allocator, a_path, "alpha\n");
    try writeTextAtomic(allocator, b_path, "beta\n");
    try runTestGit(allocator, repo_path, &.{ "add", "src/a.txt", "src/b.txt" });
    try runTestGit(allocator, repo_path, &.{ "-c", "user.name=st-test", "-c", "user.email=st-test@example.com", "commit", "-m", "initial" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .workspace = workspace_path,
        .workspace_explicit = true,
        .session_id = "s1",
        .executor = "teams",
        .resources = "write:path:src/a.txt",
    }));

    const nested_path = try std.fs.path.join(allocator, &.{ repo_path, "nested-worker" });
    try std.testing.expectError(error.NestedPrimaryCheckoutWorktree, cmdWorktree(allocator, .{
        .command = .worktree,
        .worktree_command = .create,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "s1",
        .fencing_token = "1",
        .source = repo_path,
        .output = nested_path,
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdWorktree(allocator, .{
        .command = .worktree,
        .worktree_command = .create,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "s1",
        .fencing_token = "1",
        .source = repo_path,
        .output = worktree_path,
    }));

    const worker_a = try std.fs.path.join(allocator, &.{ worktree_path, "src", "a.txt" });
    try writeTextAtomic(allocator, worker_a, "alpha changed\n");
    try std.testing.expectEqual(@as(u8, 0), try cmdChangeset(allocator, .{
        .command = .changeset,
        .changeset_command = .seal,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "s1",
        .fencing_token = "1",
        .worktree_path = worktree_path,
        .id = "cs-1",
    }));
    const cs1_path = try changesetFilePathAlloc(allocator, workspace_path, "cs-1");
    const cs1 = try durable_store.readRegularFileNoSymlink(allocator, cs1_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, cs1, "\"receipt_version\":\"CS-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cs1, "\"changed_paths\":[\"src/a.txt\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, cs1, "\"patch_digest\":\"sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cs1, "\"tree_digest\":\"sha256:") != null);

    const worker_b = try std.fs.path.join(allocator, &.{ worktree_path, "src", "b.txt" });
    try writeTextAtomic(allocator, worker_b, "outside claim\n");
    try std.testing.expectError(error.ChangeSetOutsideClaim, cmdChangeset(allocator, .{
        .command = .changeset,
        .changeset_command = .seal,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "s1",
        .fencing_token = "1",
        .worktree_path = worktree_path,
        .id = "cs-outside",
    }));

    try runTestGit(allocator, worktree_path, &.{ "checkout", "--", "src/b.txt" });
    try writeTextAtomic(allocator, worker_a, "alpha changed twice\n");
    try std.testing.expectEqual(@as(u8, 0), try cmdChangeset(allocator, .{
        .command = .changeset,
        .changeset_command = .seal,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "s1",
        .fencing_token = "1",
        .worktree_path = worktree_path,
        .id = "cs-2",
        .from_ref = "cs-1",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdChangeset(allocator, .{
        .command = .changeset,
        .changeset_command = .show,
        .workspace = workspace_path,
        .id = "cs-2",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdChangeset(allocator, .{
        .command = .changeset,
        .changeset_command = .reject,
        .workspace = workspace_path,
        .id = "cs-2",
    }));
    const wt_metadata_path = try worktreeFilePathAlloc(allocator, workspace_path, "claim-1");
    const wt_metadata = try durable_store.readRegularFileNoSymlink(allocator, wt_metadata_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, wt_metadata, "\"state\":\"recovery\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wt_metadata, "\"recovery_reason\":\"dirty_abandoned_worktree\"") != null);
    try std.testing.expectError(error.ChangeSetStale, cmdChangeset(allocator, .{
        .command = .changeset,
        .changeset_command = .supersede,
        .workspace = workspace_path,
        .id = "cs-2",
        .to_ref = "cs-1",
    }));
}

test "serialized integration applies sealed changeset with branch CAS and epoch receipt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const repo_path = try std.fs.path.join(allocator, &.{ root, "repo" });
    const worktree_path = try std.fs.path.join(allocator, &.{ root, "worker" });
    const workspace_path = try std.fs.path.join(allocator, &.{ repo_path, ".ledger", "st" });
    try durable_store.ensureDirectoryPathNoSymlinks(repo_path);

    try runTestGit(allocator, repo_path, &.{ "init", "-b", "main" });
    const a_path = try std.fs.path.join(allocator, &.{ repo_path, "src", "a.txt" });
    try writeTextAtomic(allocator, a_path, "alpha\n");
    try runTestGit(allocator, repo_path, &.{ "add", "src/a.txt" });
    try runTestGit(allocator, repo_path, &.{ "-c", "user.name=st-test", "-c", "user.email=st-test@example.com", "commit", "-m", "initial" });
    const initial_head = try gitTrimmedAlloc(allocator, repo_path, &.{ "rev-parse", "HEAD" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "default" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .workspace = workspace_path,
        .workspace_explicit = true,
        .session_id = "s1",
        .executor = "teams",
        .resources = "write:path:src/a.txt",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdWorktree(allocator, .{
        .command = .worktree,
        .worktree_command = .create,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "s1",
        .fencing_token = "1",
        .source = repo_path,
        .output = worktree_path,
    }));

    const worker_a = try std.fs.path.join(allocator, &.{ worktree_path, "src", "a.txt" });
    try writeTextAtomic(allocator, worker_a, "alpha integrated\n");
    try std.testing.expectEqual(@as(u8, 0), try cmdChangeset(allocator, .{
        .command = .changeset,
        .changeset_command = .seal,
        .workspace = workspace_path,
        .claim_id = "claim-1",
        .session_id = "s1",
        .fencing_token = "1",
        .worktree_path = worktree_path,
        .id = "cs-int",
    }));

    try std.testing.expectEqual(@as(u8, 0), try cmdIntegrate(allocator, .{ .command = .integrate, .integrate_command = .enqueue, .workspace = workspace_path, .id = "cs-int" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdIntegrate(allocator, .{ .command = .integrate, .integrate_command = .status, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdIntegrate(allocator, .{ .command = .integrate, .integrate_command = .preview, .workspace = workspace_path, .id = "cs-int" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdIntegrate(allocator, .{
        .command = .integrate,
        .integrate_command = .apply,
        .workspace = workspace_path,
        .id = "cs-int",
        .source = repo_path,
        .expect_branch_epoch = "0",
    }));

    const integrated_text = try readFileAlloc(allocator, a_path, 1024 * 1024);
    try std.testing.expectEqualStrings("alpha integrated\n", integrated_text);
    const new_head = try gitTrimmedAlloc(allocator, repo_path, &.{ "rev-parse", "HEAD" });
    try std.testing.expect(!std.mem.eql(u8, initial_head, new_head));

    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_path, "workspace.jsonl" });
    const workspace_checkpoint = try readLastJsonlLine(allocator, workspace_file);
    try std.testing.expect(std.mem.indexOf(u8, workspace_checkpoint, "\"target_branch\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, workspace_checkpoint, "\"branch_epoch\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, workspace_checkpoint, new_head) != null);

    const cs_path = try changesetFilePathAlloc(allocator, workspace_path, "cs-int");
    const cs = try durable_store.readRegularFileNoSymlink(allocator, cs_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, cs, "\"state\":\"integrated\"") != null);
    const receipt_path = try integrationReceiptPathAlloc(allocator, workspace_path, "cs-int");
    const receipt = try durable_store.readRegularFileNoSymlink(allocator, receipt_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, receipt, "\"receipt_version\":\"IGR-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt, "\"branch_epoch_after\":1") != null);
    const queue_path = try integrationQueuePathAlloc(allocator, workspace_path);
    const queue = try durable_store.readRegularFileNoSymlink(allocator, queue_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, queue, "\"state\":\"queued\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, queue, "\"state\":\"integrated\"") != null);
    const invalidation_path = try std.fs.path.join(allocator, &.{ workspace_path, "proof", "default", "invalidations.jsonl" });
    const invalidation = try durable_store.readRegularFileNoSymlink(allocator, invalidation_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, invalidation, "\"receipt_version\":\"PINV-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalidation, "\"changed_resources\":[\"path:src/a.txt\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalidation, "\"final_proof_stale\":true") != null);
}

test "workspace sessions bind independent views and gate claimed switch-plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "alpha" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "beta" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "alpha", .id = "st-001", .step = "Alpha task" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "beta", .id = "st-001", .step = "Beta task" }));

    try std.testing.expectEqual(@as(u8, 0), try cmdSession(allocator, .{
        .command = .session,
        .session_command = .bind,
        .workspace = workspace_path,
        .session_id = "s1",
        .executor = "teams",
        .plan_id = "alpha",
        .ids = "st-001",
        .format = .json,
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdSession(allocator, .{
        .command = .session,
        .session_command = .bind,
        .workspace = workspace_path,
        .session_id = "s2",
        .executor = "teams",
        .plan_id = "beta",
        .ids = "st-001",
        .format = .json,
    }));

    const s1_view_path = try workspaceViewFilePathAlloc(allocator, workspace_path, "s1");
    const s2_view_path = try workspaceViewFilePathAlloc(allocator, workspace_path, "s2");
    const s1_view = try durable_store.readRegularFileNoSymlink(allocator, s1_view_path, 1024 * 1024);
    const s2_view = try durable_store.readRegularFileNoSymlink(allocator, s2_view_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, s1_view, "\"receipt_version\":\"SVW-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1_view, "\"plan_id\":\"alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2_view, "\"plan_id\":\"beta\"") != null);
    try std.testing.expect(!std.mem.eql(u8, s1_view, s2_view));

    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .workspace = workspace_path,
        .workspace_explicit = true,
        .session_id = "s3",
        .executor = "teams",
        .resources = "write:path:src/session.zig",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdSession(allocator, .{
        .command = .session,
        .session_command = .bind,
        .workspace = workspace_path,
        .session_id = "s3",
        .executor = "teams",
        .plan_id = "alpha",
        .claim_id = "claim-1",
        .fencing_token = "1",
    }));
    try std.testing.expectError(error.SessionPlanMismatch, cmdSession(allocator, .{
        .command = .session,
        .session_command = .switch_plan,
        .workspace = workspace_path,
        .session_id = "s3",
        .plan_id = "beta",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdSession(allocator, .{
        .command = .session,
        .session_command = .release,
        .workspace = workspace_path,
        .session_id = "s3",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdSession(allocator, .{
        .command = .session,
        .session_command = .switch_plan,
        .workspace = workspace_path,
        .session_id = "s3",
        .plan_id = "beta",
    }));

    const s3_view_path = try workspaceViewFilePathAlloc(allocator, workspace_path, "s3");
    const s3_view = try durable_store.readRegularFileNoSymlink(allocator, s3_view_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, s3_view, "\"plan_id\":\"beta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s3_view, "\"claim_id\":\"\"") != null);
}

test "GCR-v2 binds workspace claim, session view, and registry graph fingerprints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });
    const plan_path = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "default", "plan.jsonl" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "default" }));

    var state = ItemState.init(allocator);
    defer state.deinit();
    state.graph_active = true;
    state.graph.version = GraphEnvelopeVersion;
    state.graph.lineage.materiality = "material";
    state.graph.policy.completion_requires_proof = true;
    state.graph.intent = &.{.{ .id = "intent-001", .text = "Authorize workspace execution.", .category = "requirement", .disposition = "covered" }};
    try state.upsert(.{
        .id = "st-001",
        .step = "Authorized work",
        .status = .pending,
        .priority = .high,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .intent_refs = &.{"intent-001"},
        .acceptance = &.{"GCR-v2 authorizes current state"},
        .validation = &.{"zig build test-st"},
        .contract = .{
            .objective = "Emit current workspace execution authority.",
            .proof_obligations = &.{.{ .id = "proof-001", .kind = "unit", .command = "zig build test-st" }},
        },
        .lock_roots = &.{"apps/st/scripts/st.zig"},
    });
    const now = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(plan_path, &state, 2, now, buildMutationMeta(allocator, false), null);
    const fps = try computeGraphFingerprints(allocator, &state);
    state.graph.fingerprints = fps;
    const audit = AuditResult{ .gate = .execution_ready, .findings = &.{}, .errors = 0, .warnings = 0 };

    try std.testing.expectEqual(@as(u8, 0), try cmdClaim(allocator, .{
        .command = .claim,
        .workspace = workspace_path,
        .workspace_explicit = true,
        .session_id = "s1",
        .executor = "teams",
        .plan_id = "default",
        .resources = "write:path:apps/st/scripts/st.zig",
    }));
    try std.testing.expectEqual(@as(u8, 0), try cmdSession(allocator, .{
        .command = .session,
        .session_command = .bind,
        .workspace = workspace_path,
        .session_id = "s1",
        .executor = "teams",
        .plan_id = "default",
        .claim_id = "claim-1",
        .fencing_token = "1",
        .ids = "st-001",
    }));

    var allowed_writer: std.Io.Writer.Allocating = .init(allocator);
    defer allowed_writer.deinit();
    try writeWorkspaceGraphControlReceiptJson(allocator, &allowed_writer.writer, .{
        .command = .compile,
        .workspace = workspace_path,
        .file = plan_path,
        .plan_id = "default",
        .session_id = "s1",
        .claim_id = "claim-1",
        .fencing_token = "1",
    }, &state, 2, fps, audit, &.{"st-001"}, "GCR-test", false);
    const allowed_json = try allowed_writer.toOwnedSlice();
    try std.testing.expect(std.mem.indexOf(u8, allowed_json, "\"receipt_version\":\"GCR-v2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, allowed_json, "\"execution_allowed\":\"yes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, allowed_json, "\"graph_fingerprints\":{\"structure\":\"sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, allowed_json, "\"registry_graph_fingerprints\":{}") != null);

    const workspace_file = try std.fs.path.join(allocator, &.{ workspace_path, "workspace.jsonl" });
    const workspace_line = try readLastJsonlLine(allocator, workspace_file);
    const marker = "\"graph_fingerprints\":{}";
    const marker_index = std.mem.indexOf(u8, workspace_line, marker) orelse return error.TestUnexpectedResult;
    var stale_workspace: std.Io.Writer.Allocating = .init(allocator);
    defer stale_workspace.deinit();
    try stale_workspace.writer.writeAll(workspace_line[0..marker_index]);
    try stale_workspace.writer.writeAll("\"graph_fingerprints\":{\"structure\":\"sha256:stale\",\"contract\":\"sha256:stale\",\"coverage\":\"sha256:stale\",\"execution\":\"sha256:stale\"}");
    try stale_workspace.writer.writeAll(workspace_line[marker_index + marker.len ..]);
    try stale_workspace.writer.writeByte('\n');
    const stale_payload = try stale_workspace.toOwnedSlice();
    try writeTextAtomic(allocator, workspace_file, stale_payload);

    var stale_writer: std.Io.Writer.Allocating = .init(allocator);
    defer stale_writer.deinit();
    try writeWorkspaceGraphControlReceiptJson(allocator, &stale_writer.writer, .{
        .command = .compile,
        .workspace = workspace_path,
        .file = plan_path,
        .plan_id = "default",
        .session_id = "s1",
        .claim_id = "claim-1",
        .fencing_token = "1",
    }, &state, 2, fps, audit, &.{"st-001"}, "GCR-test", false);
    const stale_json = try stale_writer.toOwnedSlice();
    try std.testing.expect(std.mem.indexOf(u8, stale_json, "\"execution_allowed\":\"no\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stale_json, "\"gcr_stale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stale_json, "\"graph_fingerprints\":false") != null);
}

test "workspace plan scope routes legacy add commands to registered graph files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });
    const legacy_path = try std.fs.path.join(allocator, &.{ root, "legacy.jsonl" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "alpha" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "beta" }));

    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "alpha", .id = "st-001", .step = "Alpha local task" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "beta", .id = "st-001", .step = "Beta local task" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .file = legacy_path, .id = "st-001", .step = "Legacy local task" }));

    const alpha_file = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "alpha", "plan.jsonl" });
    const beta_file = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "beta", "plan.jsonl" });
    var alpha = try loadValidatedState(allocator, alpha_file, false);
    defer alpha.state.deinit();
    var beta = try loadValidatedState(allocator, beta_file, false);
    defer beta.state.deinit();
    var legacy = try loadValidatedState(allocator, legacy_path, false);
    defer legacy.state.deinit();

    try std.testing.expectEqualStrings("Alpha local task", alpha.state.get("st-001").?.step);
    try std.testing.expectEqualStrings("Beta local task", beta.state.get("st-001").?.step);
    try std.testing.expectEqualStrings("Legacy local task", legacy.state.get("st-001").?.step);
    try std.testing.expectError(error.PlanMissing, runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "missing", .id = "st-002", .step = "Should not write" }));
    try std.testing.expectError(error.InvalidPlanScope, runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .plan_id = "alpha", .file = legacy_path, .file_explicit = true, .id = "st-002", .step = "Ambiguous write" }));
}

test "workspace plan scope infers exactly one active plan and rejects ambiguity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "solo" }));
    try std.testing.expectEqual(@as(u8, 0), try runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .workspace_explicit = true, .id = "st-001", .step = "Inferred solo task" }));

    const solo_file = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "solo", "plan.jsonl" });
    var solo = try loadValidatedState(allocator, solo_file, false);
    defer solo.state.deinit();
    try std.testing.expectEqualStrings("Inferred solo task", solo.state.get("st-001").?.step);

    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "other" }));
    try std.testing.expectError(error.PlanAmbiguous, runCommand(allocator, .{ .command = .add, .workspace = workspace_path, .workspace_explicit = true, .id = "st-002", .step = "Ambiguous task" }));

    var solo_after = try loadValidatedState(allocator, solo_file, false);
    defer solo_after.state.deinit();
    try std.testing.expect(solo_after.state.get("st-002") == null);
    const other_file = try std.fs.path.join(allocator, &.{ workspace_path, "plans", "other", "plan.jsonl" });
    var other = try loadValidatedState(allocator, other_file, false);
    defer other.state.deinit();
    try std.testing.expect(other.state.get("st-002") == null);
}

test "intake apply compiles markdown into graph state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const intake_path = try std.fs.path.join(allocator, &.{ root, "st-intake.md" });
    try writeTextAtomic(allocator, intake_path,
        \\# st graph intake
        \\
        \\Source: PLAN.md
        \\
        \\## Intent
        \\
        \\- intent-001 | requirement | covered
        \\  Text: Intake apply must create graph state.
        \\  Source: PLAN.md#intake
        \\
        \\- intent-002 | test-expectation | covered
        \\  Text: Intake apply must preserve proof commands.
        \\  Source: PLAN.md#proof
        \\
        \\## Items
        \\
        \\### st-001 | feature | high
        \\
        \\Step: Implement intake apply fixture
        \\
        \\Covers:
        \\- intent-001
        \\- intent-002
        \\
        \\Depends:
        \\- none
        \\
        \\Locations:
        \\- apps/st/scripts/st.zig
        \\
        \\Acceptance:
        \\- Intake markdown creates durable graph items.
        \\
        \\Validation:
        \\- zig build test-st
        \\
        \\Proof:
        \\- proof-001 | unit | zig build test-st 2>&1 | tee .step/proof/st-001.log
        \\
        \\Contract:
        \\Background:
        \\Skill documentation names intake commands.
        \\
        \\Objective:
        \\Add executable intake apply support.
        \\
        \\Implementation Approach:
        \\Parse the documented Markdown template into existing graph fields.
        \\
        \\Risks:
        \\- Markdown drift could drop proof metadata.
        \\
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdIntake(allocator, .{ .command = .intake, .intake_command = .apply, .file = plan_path, .input = intake_path, .gate = .implementation_ready }));

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    try std.testing.expect(loaded.state.graph_active);
    try std.testing.expect(loaded.state.graph.policy.completion_requires_proof);
    try std.testing.expectEqual(@as(usize, 2), loaded.state.graph.intent.len);
    const item = loaded.state.items.items[0];
    try std.testing.expectEqualStrings("st-001", item.id);
    try std.testing.expectEqual(ItemType.feature, item.item_type);
    try std.testing.expectEqualStrings("intent-002", item.intent_refs[1]);
    try std.testing.expectEqualStrings("apps/st/scripts/st.zig", item.lock_roots[0]);
    try std.testing.expectEqualStrings("proof-001", item.contract.?.proof_obligations[0].id);
    try std.testing.expect(std.mem.indexOf(u8, item.contract.?.proof_obligations[0].command, "| tee .step/proof/st-001.log") != null);
}

test "implementation-ready audit treats completed legacy capsule debt as historical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    state.graph_active = true;
    state.graph.intent = &.{.{ .id = "intent-001", .text = "Covered by active work", .category = "requirement", .disposition = "covered" }};
    try state.upsert(.{
        .id = "st-legacy",
        .step = "Completed legacy row without capsule fields",
        .status = .completed,
        .priority = .medium,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
    });
    try state.upsert(.{
        .id = "st-active",
        .step = "Active row with full capsule",
        .status = .pending,
        .priority = .high,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .intent_refs = &.{"intent-001"},
        .acceptance = &.{"behavior is implemented"},
        .validation = &.{"zig build test-st"},
        .contract = .{ .objective = "Exercise implementation-ready capsule checks." },
    });

    const audit = try auditGraph(allocator, &state, .implementation_ready);
    try std.testing.expectEqual(@as(usize, 0), audit.errors);
    try std.testing.expectEqual(@as(usize, 0), audit.warnings);
}

test "implementation-ready audit rejects active malformed executable rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    state.graph_active = true;
    try state.upsert(.{
        .id = "st-active",
        .step = "Active malformed row",
        .status = .pending,
        .priority = .high,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
    });

    const audit = try auditGraph(allocator, &state, .implementation_ready);
    try std.testing.expect(audit.errors > 0);
    var saw_missing_contract = false;
    for (audit.findings) |finding| {
        if (std.mem.eql(u8, finding.code, "executable-item-missing-contract") and
            std.mem.eql(u8, finding.target, "st-active"))
        {
            saw_missing_contract = true;
        }
    }
    try std.testing.expect(saw_missing_contract);
}

test "intake apply rejects conflicting existing intent id atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const intake_path = try std.fs.path.join(allocator, &.{ root, "st-intake.md" });

    var state = ItemState.init(allocator);
    defer state.deinit();
    state.graph_active = true;
    state.graph.intent = &.{.{ .id = "intent-001", .text = "Original graph intent", .category = "requirement", .disposition = "covered" }};
    try state.upsert(.{
        .id = "st-existing",
        .step = "Existing covering item",
        .status = .completed,
        .priority = .medium,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .intent_refs = &.{"intent-001"},
    });
    const now = try nowUtcAlloc(allocator);
    try writeCanonicalRecords(plan_path, &state, 1, now, buildMutationMeta(allocator, false), null);

    try writeTextAtomic(allocator, intake_path,
        \\# st graph intake
        \\
        \\Source: PLAN.md
        \\
        \\## Intent
        \\
        \\- intent-001 | requirement | covered
        \\  Text: Different intake intent
        \\
        \\## Items
        \\
        \\### st-001 | feature | high
        \\
        \\Step: Attempt conflicting intake
        \\
        \\Covers:
        \\- intent-001
        \\
        \\Depends:
        \\- none
        \\
        \\Acceptance:
        \\- Intake is rejected.
        \\
        \\Validation:
        \\- zig build test-st
        \\
        \\Contract:
        \\Objective:
        \\Exercise conflict rejection.
        \\
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 2), try cmdIntake(allocator, .{ .command = .intake, .intake_command = .apply, .file = plan_path, .input = intake_path, .gate = .implementation_ready }));

    const parsed = try readRecords(allocator, plan_path);
    try std.testing.expectEqual(@as(i64, 1), parsed.latest_seq);
    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.state.graph.intent.len);
    try std.testing.expectEqualStrings("Original graph intent", loaded.state.graph.intent[0].text);
    try std.testing.expect(loaded.state.getConst("st-001") == null);
}

test "intake diagnostics report placeholders and unknown dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const diagnostics = try collectIntakeDiagnostics(allocator,
        \\# st graph intake
        \\
        \\Source: PLAN.md
        \\
        \\## Intent
        \\
        \\- intent-001 | requirement | covered
        \\  Text: <replace me>
        \\
        \\## Items
        \\
        \\### st-001 | feature | high
        \\
        \\Step: Build thing
        \\
        \\Covers:
        \\- intent-001
        \\
        \\Depends:
        \\- st-404 | requires
        \\
    );
    try std.testing.expect(countIntakeDiagnostics(diagnostics, "error") >= 2);
    var saw_placeholder = false;
    var saw_unknown_dep = false;
    for (diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.code, "placeholder-not-replaced")) saw_placeholder = true;
        if (std.mem.eql(u8, diagnostic.code, "unknown-dependency")) saw_unknown_dep = true;
    }
    try std.testing.expect(saw_placeholder);
    try std.testing.expect(saw_unknown_dep);
}

test "intake normalize writes canonical markdown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const input_path = try std.fs.path.join(allocator, &.{ root, "st-intake.md" });
    const output_path = try std.fs.path.join(allocator, &.{ root, "st-intake.normalized.md" });
    try writeTextAtomic(allocator, input_path,
        \\# st graph intake
        \\
        \\Source: PLAN.md
        \\
        \\## Intent
        \\- intent-001 | requirement | covered
        \\  Text: Normalize material intake.
        \\
        \\## Items
        \\### st-001 | feature | high
        \\Step: Normalize intake fixture
        \\Covers:
        \\- intent-001
        \\Depends:
        \\- none
        \\Locations:
        \\- apps/st
        \\Acceptance:
        \\- Output is canonical.
        \\Validation:
        \\- zig build test-st
        \\Proof:
        \\- proof-001 | unit | zig build test-st
        \\Contract:
        \\Background:
        \\Fixture.
        \\Objective:
        \\Normalize.
        \\Implementation Approach:
        \\Parse then render.
        \\Risks:
        \\- Drift.
        \\
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdIntake(allocator, .{ .command = .intake, .intake_command = .normalize, .input = input_path, .output = output_path }));
    const normalized = try readFileAlloc(allocator, output_path, 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, normalized, "### st-001 | feature | high") != null);
    try std.testing.expect(std.mem.indexOf(u8, normalized, "Proof:") != null);
}

test "blocking graph debt prevents compile aperture sequence transition" {
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
    state.graph.version = GraphEnvelopeVersion;
    state.graph.lineage.materiality = "material";
    state.graph.policy.graph_control_required = true;
    state.graph.policy.blocking_debt_policy = "block-material";
    try state.upsert(.{
        .id = "st-001",
        .step = "Material item without coverage",
        .status = .pending,
        .priority = .high,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .acceptance = &.{"done"},
        .validation = &.{"zig build test-st"},
    });
    const now = try nowUtcAlloc(allocator);
    state.graph.debt = try computeGraphDebtAlloc(allocator, &state, now);
    try writeCanonicalRecords(plan_path, &state, 1, now, buildMutationMeta(allocator, false), null);

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 2), try cmdCompileAperture(allocator, .{ .command = .compile, .compile_command = .aperture, .file = plan_path, .limit = 7 }));
    const parsed = try readRecords(allocator, plan_path);
    try std.testing.expectEqual(@as(i64, 1), parsed.latest_seq);
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

test "graph delta reports only actual canonical changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    state.graph_active = true;
    state.graph.intent = &.{.{ .id = "intent-001", .text = "Track delta", .category = "requirement", .disposition = "unknown" }};
    try state.upsert(.{
        .id = "st-001",
        .step = "Unchanged item",
        .status = .pending,
        .priority = .medium,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });
    try state.upsert(.{
        .id = "st-002",
        .step = "Changed item",
        .status = .pending,
        .priority = .medium,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });

    const baseline = try graphDeltaBaselineAlloc(allocator, &state);
    state.get("st-002").?.notes = "changed";
    state.get("st-002").?.deps = &.{.{ .id = "st-001", .type = "requires" }};
    state.graph.intent = &.{.{ .id = "intent-001", .text = "Track delta", .category = "requirement", .disposition = "covered" }};

    const delta = try computeGraphDelta(allocator, baseline, &state, 1, 2);
    try std.testing.expectEqual(@as(usize, 0), delta.items_added.len);
    try std.testing.expectEqual(@as(usize, 0), delta.items_removed.len);
    try std.testing.expectEqual(@as(usize, 1), delta.items_changed.len);
    try std.testing.expectEqualStrings("st-002", delta.items_changed[0]);
    try std.testing.expectEqual(@as(usize, 1), delta.deps_added.len);
    try std.testing.expectEqualStrings("st-002->st-001:requires", delta.deps_added[0]);
    try std.testing.expect(std.mem.startsWith(u8, delta.fingerprints_before.structure, "sha256:"));
    try std.testing.expect(std.mem.startsWith(u8, delta.fingerprints_after.structure, "sha256:"));
    try std.testing.expect(delta.intent_coverage_changed.len >= 1);
}

test "audit result emits current graph fingerprints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    state.graph_active = true;
    try state.upsert(.{
        .id = "st-001",
        .step = "Fingerprint item",
        .status = .pending,
        .priority = .medium,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
    });
    state.graph.fingerprints = try computeGraphFingerprints(allocator, &state);
    const audit = try auditGraph(allocator, &state, .draft);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeAuditResultJson(&out.writer, &state, audit);
    const json = try out.toOwnedSlice();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fingerprints\":{\"structure\":\"sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"contract\":\"sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"coverage\":\"sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"execution\":\"sha256:") != null);
}

test "polish stability includes contract fingerprint and records deltas" {
    const passes = [_]PolishPass{
        .{
            .pass = 1,
            .structure_fingerprint = "sha256:structure",
            .contract_fingerprint = "sha256:contract-a",
            .coverage_fingerprint = "sha256:coverage",
        },
        .{
            .pass = 2,
            .structure_fingerprint = "sha256:structure",
            .contract_fingerprint = "sha256:contract-b",
            .coverage_fingerprint = "sha256:coverage",
        },
    };
    var state = ItemState.init(std.testing.allocator);
    defer state.deinit();
    state.graph.polish.passes = passes[0..];
    try std.testing.expect(!polishStable(&state, 2));

    const delta = polishDeltaFromPrevious(passes[0..1], .{
        .structure = "sha256:structure",
        .contract = "sha256:contract-b",
        .coverage = "sha256:coverage",
        .execution = "sha256:execution",
    });
    try std.testing.expectEqual(@as(i64, 0), delta.deps_changed);
    try std.testing.expectEqual(@as(i64, 1), delta.contracts_changed);
    try std.testing.expectEqual(@as(i64, 0), delta.intent_coverage_changed);
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

test "graph index computes critical depth iteratively for branching DAG" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{ .id = "st-001", .step = "root", .status = .pending, .priority = .high, .in_plan = true, .deps = &.{}, .notes = "", .comments = &.{} });
    try state.upsert(.{ .id = "st-002", .step = "left", .status = .pending, .priority = .high, .in_plan = true, .deps = &.{.{ .id = "st-001", .type = "requires" }}, .notes = "", .comments = &.{} });
    try state.upsert(.{ .id = "st-003", .step = "right", .status = .pending, .priority = .high, .in_plan = true, .deps = &.{.{ .id = "st-001", .type = "requires" }}, .notes = "", .comments = &.{} });
    try state.upsert(.{ .id = "st-004", .step = "leaf", .status = .pending, .priority = .high, .in_plan = true, .deps = &.{.{ .id = "st-002", .type = "requires" }}, .notes = "", .comments = &.{} });

    var index = try buildGraphIndex(allocator, &state);
    defer index.deinit(allocator);
    try ensureGraphIndexValid(index);
    const depths = try criticalDepthsAlloc(allocator, &state, index);
    defer allocator.free(depths);

    try std.testing.expectEqual(@as(i64, 3), criticalPathLengthFromDepths(depths));
    try std.testing.expectEqual(@as(i64, 3), criticalPathFromIndex(index, depths, "st-001"));
    try std.testing.expectEqual(@as(i64, 1), criticalPathFromIndex(index, depths, "st-003"));
}

test "graph index rejects dependency cycle with concrete witness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{ .id = "st-001", .step = "one", .status = .pending, .priority = .high, .in_plan = true, .deps = &.{.{ .id = "st-002", .type = "requires" }}, .notes = "", .comments = &.{} });
    try state.upsert(.{ .id = "st-002", .step = "two", .status = .pending, .priority = .high, .in_plan = true, .deps = &.{.{ .id = "st-003", .type = "requires" }}, .notes = "", .comments = &.{} });
    try state.upsert(.{ .id = "st-003", .step = "three", .status = .pending, .priority = .high, .in_plan = true, .deps = &.{.{ .id = "st-001", .type = "requires" }}, .notes = "", .comments = &.{} });

    var index = try buildGraphIndex(allocator, &state);
    defer index.deinit(allocator);
    try std.testing.expect(!index.valid());
    try std.testing.expectError(error.DependencyCycle, ensureGraphIndexValid(index));
    try std.testing.expect(index.cycle_witness.len >= 2);

    const audit = try auditGraph(allocator, &state, .draft);
    try std.testing.expectEqual(@as(usize, 1), audit.errors);
    var saw_cycle = false;
    for (audit.findings) |finding| {
        if (std.mem.eql(u8, finding.code, "dependency-cycle")) {
            saw_cycle = true;
            try std.testing.expect(std.mem.indexOf(u8, finding.message, " -> ") != null);
        }
    }
    try std.testing.expect(saw_cycle);
}

test "graph insights refuses invalid dependency graph before analytics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });

    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{ .id = "st-001", .step = "one", .status = .pending, .priority = .high, .in_plan = true, .deps = &.{.{ .id = "st-002", .type = "requires" }}, .notes = "", .comments = &.{} });
    try state.upsert(.{ .id = "st-002", .step = "two", .status = .pending, .priority = .high, .in_plan = true, .deps = &.{.{ .id = "st-001", .type = "requires" }}, .notes = "", .comments = &.{} });
    const meta = MutationMeta{ .allow_multiple_in_progress = false, .actor = "test", .pid = 1, .session = null };
    try writeCanonicalRecords(plan_path, &state, 1, "2026-06-18T00:00:00Z", meta, null);

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 2), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .insights, .file = plan_path, .format = .json }));
}

test "graph index computes ten thousand node chain without recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    const total: usize = 10_000;
    for (0..total) |idx| {
        const id = try std.fmt.allocPrint(allocator, "st-{d:0>5}", .{idx + 1});
        const deps: []const Dep = if (idx == 0)
            &.{}
        else
            try allocator.dupe(Dep, &.{.{ .id = state.items.items[idx - 1].id, .type = "requires" }});
        try state.upsert(.{ .id = id, .step = "chain", .status = .pending, .priority = .medium, .in_plan = false, .deps = deps, .notes = "", .comments = &.{} });
    }

    var index = try buildGraphIndex(allocator, &state);
    defer index.deinit(allocator);
    try ensureGraphIndexValid(index);
    const depths = try criticalDepthsAlloc(allocator, &state, index);
    defer allocator.free(depths);
    try std.testing.expectEqual(@as(i64, @intCast(total)), criticalPathLengthFromDepths(depths));
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
    state.graph.version = GraphEnvelopeVersion;
    state.graph.policy.completion_requires_proof = true;
    state.graph.policy.graph_control_required = true;
    state.graph.policy.default_projection_strategy = "control-v2";
    state.graph.policy.blocking_debt_policy = "block-material";
    state.graph.lineage.materiality = "material";
    state.graph.lineage.mode = "compiled";
    state.graph.lineage.source = .{ .kind = "markdown", .locator = "PLAN.md", .fingerprint = "sha256:test" };
    state.graph.intent = &.{.{
        .id = "intent-001",
        .text = "Compile aperture emits a graph control receipt.",
        .category = "requirement",
        .disposition = "covered",
    }};
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
        .id = "st-099",
        .step = "Pending predecessor",
        .status = .pending,
        .priority = .medium,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .epic,
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

test "aperture selects lower ranked compatible work instead of lock conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{
        .id = "st-001",
        .step = "Highest value",
        .status = .pending,
        .priority = .high,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .acceptance = &.{"done"},
        .validation = &.{"zig build test-st"},
        .lock_roots = &.{"apps/st"},
        .contract = .{ .objective = "one", .proof_obligations = &.{.{ .id = "proof-001", .kind = "unit", .command = "zig build test-st" }} },
    });
    try state.upsert(.{
        .id = "st-002",
        .step = "Conflicting high value",
        .status = .pending,
        .priority = .high,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .acceptance = &.{"done"},
        .validation = &.{"zig build test-st"},
        .lock_roots = &.{"apps/st"},
        .contract = .{ .objective = "two", .proof_obligations = &.{.{ .id = "proof-001", .kind = "unit", .command = "zig build test-st" }} },
    });
    try state.upsert(.{
        .id = "st-003",
        .step = "Compatible lower value",
        .status = .pending,
        .priority = .medium,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .acceptance = &.{"done"},
        .validation = &.{"zig build test-st"},
        .lock_roots = &.{"docs"},
        .contract = .{ .objective = "three", .proof_obligations = &.{.{ .id = "proof-001", .kind = "unit", .command = "zig build test-st" }} },
    });

    const selected = try selectApertureIds(allocator, &state, 2);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqualStrings("st-001", selected[0]);
    try std.testing.expectEqualStrings("st-003", selected[1]);
}

test "compile aperture writes one sequence transition and emits GCR envelope" {
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
    state.graph.version = GraphEnvelopeVersion;
    state.graph.policy.completion_requires_proof = true;
    state.graph.policy.graph_control_required = true;
    state.graph.policy.default_projection_strategy = "control-v2";
    state.graph.policy.blocking_debt_policy = "block-material";
    state.graph.lineage.materiality = "material";
    state.graph.lineage.mode = "compiled";
    state.graph.lineage.source = .{ .kind = "markdown", .locator = "PLAN.md", .fingerprint = "sha256:test" };
    state.graph.intent = &.{.{
        .id = "intent-001",
        .text = "Compile aperture emits a graph control receipt.",
        .category = "requirement",
        .disposition = "covered",
    }};
    try state.upsert(.{
        .id = "st-001",
        .step = "Completed context",
        .status = .completed,
        .priority = .medium,
        .in_plan = false,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .epic,
    });
    try state.upsert(.{
        .id = "st-002",
        .step = "Ready graph work",
        .status = .pending,
        .priority = .high,
        .in_plan = false,
        .deps = &.{.{ .id = "st-001", .type = "requires" }},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .intent_refs = &.{"intent-001"},
        .acceptance = &.{"GCR emitted"},
        .validation = &.{"zig build test-st"},
        .lock_roots = &.{"apps/st"},
        .contract = .{
            .objective = "Compile aperture.",
            .background = "Fixture.",
            .implementation_approach = "Select ready work.",
            .success_criteria = &.{"GCR emitted"},
            .proof_obligations = &.{.{ .id = "proof-001", .kind = "unit", .command = "zig build test-st" }},
        },
    });
    const meta = MutationMeta{ .allow_multiple_in_progress = false, .actor = "test", .pid = 1, .session = null };
    try writeCanonicalRecords(plan_path, &state, 1, "2026-06-18T00:00:00Z", meta, null);

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdCompileAperture(allocator, .{ .command = .compile, .compile_command = .aperture, .file = plan_path, .limit = 7 }));

    const parsed = try readRecords(allocator, plan_path);
    try std.testing.expectEqual(@as(i64, 2), parsed.latest_seq);
    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    try std.testing.expect(loaded.state.getConst("st-002").?.in_plan);

    const fps = try computeGraphFingerprints(allocator, &loaded.state);
    const audit = try auditGraph(allocator, &loaded.state, .execution_ready);
    const selected = try selectedInPlanIdsAlloc(allocator, &loaded.state);
    const receipt_id = try gcrReceiptIdAlloc(allocator, parsed.latest_seq, fps.structure);
    var receipt_writer: std.Io.Writer.Allocating = .init(allocator);
    defer receipt_writer.deinit();
    try writeGraphControlReceiptJson(allocator, &receipt_writer.writer, &loaded.state, plan_path, parsed.latest_seq, fps, audit, selected, 7, receipt_id);
    const receipt = try receipt_writer.toOwnedSlice();
    try std.testing.expect(std.mem.indexOf(u8, receipt, "\"receipt_version\":\"GCR-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt, "\"selected\":[\"st-002\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt, "\"critical\":{\"method\":\"unit-weight-dag\"") != null);
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

    try std.testing.expectEqual(@as(u8, 0), try cmdComplete(allocator, .{ .command = .complete, .file = plan_path, .id = "st-001", .proof_id = "proof-001", .step = "zig build test-st", .evidence_ref = "proof.log", .now = "2026-06-18T01:02:03Z" }));
    var completed = try loadValidatedState(allocator, plan_path, false);
    defer completed.state.deinit();
    const item = completed.state.getConst("st-001").?;
    try std.testing.expectEqual(Status.completed, item.status);
    try std.testing.expect(!item.in_plan);
    try std.testing.expectEqual(ProofState.pass, item.proof.?.state);
    try std.testing.expectEqualStrings("proof.log", item.proof.?.evidence_ref);
    try std.testing.expectEqual(@as(usize, 1), item.proof_receipts.len);
    try std.testing.expectEqualStrings("proof-001", item.proof_receipts[0].obligation_id);
    try std.testing.expectEqualStrings("2026-06-18T01:02:03Z", item.proof_receipts[0].recorded_at);
    try std.testing.expectEqual(@as(u8, 0), try cmdProof(allocator, .{ .command = .proof, .proof_command = .audit, .file = plan_path, .id = "st-001", .format = .json }));
}

test "set-proof records named proof receipt with timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const patch_path = try std.fs.path.join(allocator, &.{ root, "patch.json" });
    try writeTextAtomic(allocator, patch_path,
        \\{"version":1,"author":"test","reason":"named proof fixture","ops":[
        \\{"op":"upsert-intent","intent":{"id":"intent-001","text":"Completion requires named proof.","category":"requirement","disposition":"covered"}},
        \\{"op":"upsert-item","item":{"id":"st-001","step":"Implement named proof fixture","status":"pending","priority":"high","in_plan":true,"item_type":"feature","intent_refs":["intent-001"],"acceptance":["Completion is proof-gated"],"validation":["zig build test-st"],"lock_roots":["apps/st"],"contract":{"objective":"Exercise named legacy proof receipt.","proof_obligations":[{"id":"proof-001","kind":"unit","command":"zig build test-st","required":true}]}}}
        \\]}
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = plan_path, .input = patch_path, .gate = .implementation_ready }));
    try std.testing.expectEqual(@as(u8, 0), try cmdSetProof(allocator, .{ .command = .set_proof, .file = plan_path, .id = "st-001", .proof_state = "pass", .proof_id = "proof-001", .step = "zig build test-st", .evidence_ref = "proof.log", .now = "2026-06-18T01:02:03Z" }));

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    const item = loaded.state.getConst("st-001").?;
    try std.testing.expectEqual(ProofState.pass, item.proof.?.state);
    try std.testing.expectEqualStrings("2026-06-18T01:02:03Z", item.proof.?.last_run_at);
    try std.testing.expectEqual(@as(usize, 1), item.proof_receipts.len);
    try std.testing.expectEqualStrings("proof-001", item.proof_receipts[0].obligation_id);
    try std.testing.expectEqualStrings("legacy-single-proof", item.proof_receipts[0].action_id);
    try std.testing.expectEqualStrings("2026-06-18T01:02:03Z", item.proof_receipts[0].recorded_at);
    try std.testing.expect(proofCompletionMissingReason(item.*) == null);
}

test "multiple required proof obligations can be satisfied by multiple receipts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const patch_path = try std.fs.path.join(allocator, &.{ root, "patch.json" });
    try writeTextAtomic(allocator, patch_path,
        \\{"version":1,"author":"test","reason":"multi receipt fixture","ops":[
        \\{"op":"upsert-intent","intent":{"id":"intent-001","text":"Completion requires two proofs.","category":"requirement","disposition":"covered"}},
        \\{"op":"upsert-item","item":{"id":"st-001","step":"Implement multi proof fixture","status":"pending","priority":"high","in_plan":true,"item_type":"feature","intent_refs":["intent-001"],"acceptance":["Completion is proof-gated"],"validation":["zig build test-st","zig build build-st"],"lock_roots":["apps/st"],"contract":{"objective":"Exercise receipt-aware completion.","proof_obligations":[{"id":"proof-001","kind":"unit","command":"zig build test-st","required":true},{"id":"proof-002","kind":"build","command":"zig build build-st","required":true}]}}}
        \\]}
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = plan_path, .input = patch_path, .gate = .implementation_ready }));
    try std.testing.expectEqual(@as(u8, 0), try cmdProofRecord(allocator, .{ .command = .proof, .proof_command = .record, .file = plan_path, .id = "st-001", .obligation_id = "proof-001", .action_id = "proof-action-test", .step = "zig build test-st", .evidence_ref = "test.log", .artifact_ref = "git:test" }));
    try std.testing.expectEqual(@as(u8, 0), try cmdProofRecord(allocator, .{ .command = .proof, .proof_command = .record, .file = plan_path, .id = "st-001", .obligation_id = "proof-002", .action_id = "proof-action-build", .step = "zig build build-st", .evidence_ref = "build.log", .artifact_ref = "git:build" }));

    var receipted = try loadValidatedState(allocator, plan_path, false);
    defer receipted.state.deinit();
    const receipted_item = receipted.state.getConst("st-001").?;
    try std.testing.expectEqual(@as(usize, 2), receipted_item.proof_receipts.len);
    try std.testing.expect(proofCompletionMissingReason(receipted_item.*) == null);
    const proof_summary = try proofObligationSummaryAlloc(allocator, &receipted.state);
    try std.testing.expectEqual(@as(usize, 2), proof_summary.total);
    try std.testing.expectEqual(@as(usize, 2), proof_summary.satisfied);
    try std.testing.expectEqual(@as(usize, 0), proof_summary.missing.len);

    try std.testing.expectEqual(@as(u8, 0), try cmdComplete(allocator, .{ .command = .complete, .file = plan_path, .id = "st-001" }));
    var completed = try loadValidatedState(allocator, plan_path, false);
    defer completed.state.deinit();
    const completed_item = completed.state.getConst("st-001").?;
    try std.testing.expectEqual(Status.completed, completed_item.status);
    try std.testing.expectEqual(@as(usize, 2), completed_item.proof_receipts.len);
    try std.testing.expect(completed_item.proof == null);
}

test "workspace proof record emits PRF-v3 branch and dependency lineage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const workspace_path = try std.fs.path.join(allocator, &.{ root, ".ledger", "st" });
    const patch_path = try std.fs.path.join(allocator, &.{ root, "patch.json" });

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdWorkspace(allocator, .{ .command = .workspace, .workspace_command = .init, .workspace = workspace_path }));
    try std.testing.expectEqual(@as(u8, 0), try cmdPlan(allocator, .{ .command = .plan, .plan_command = .create, .workspace = workspace_path, .plan_id = "default" }));
    const plan_path = try resolveWorkspacePlanFile(allocator, workspace_path, "default");
    try writeTextAtomic(allocator, patch_path,
        \\{"version":1,"author":"test","reason":"prf-v3 fixture","ops":[
        \\{"op":"upsert-intent","intent":{"id":"intent-001","text":"Workspace proof records carry lineage.","category":"requirement","disposition":"covered"}},
        \\{"op":"upsert-item","item":{"id":"st-001","step":"Record PRF-v3 proof","status":"pending","priority":"high","in_plan":true,"item_type":"feature","intent_refs":["intent-001"],"acceptance":["PRF-v3 emitted"],"validation":["zig build test-st"],"lock_roots":["apps/st"],"contract":{"objective":"Exercise PRF-v3 receipt.","proof_obligations":[{"id":"proof-001","kind":"unit","command":"zig build test-st","required":true}]}}}
        \\]}
    );
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = plan_path, .input = patch_path, .gate = .implementation_ready }));
    var before = try loadValidatedState(allocator, plan_path, false);
    defer before.state.deinit();
    const expected_plan_sequence = before.latest_seq + 1;
    try std.testing.expectEqual(@as(u8, 0), try cmdProofRecord(allocator, .{
        .command = .proof,
        .proof_command = .record,
        .file = plan_path,
        .workspace = workspace_path,
        .workspace_explicit = true,
        .plan_id = "default",
        .id = "st-001",
        .obligation_id = "proof-001",
        .action_id = "proof-action-test",
        .step = "zig build test-st",
        .evidence_ref = "test.log",
        .artifact_ref = "git:test",
    }));

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    const receipt = loaded.state.getConst("st-001").?.proof_receipts[0];
    try std.testing.expectEqualStrings("PRF-v3", receipt.receipt_version);
    try std.testing.expectEqualStrings("default", receipt.plan_id);
    try std.testing.expectEqual(expected_plan_sequence, receipt.plan_sequence);
    try std.testing.expectEqual(@as(i64, 2), receipt.workspace_sequence);
    try std.testing.expectEqual(@as(i64, 0), receipt.branch_epoch);
    try std.testing.expectEqualStrings("path:apps/st", receipt.dependency_resources[0]);
}

test "proof record command mismatch is a blocked result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirRootAlloc(allocator, tmp.dir);
    const plan_path = try std.fs.path.join(allocator, &.{ root, "st-plan.jsonl" });
    const patch_path = try std.fs.path.join(allocator, &.{ root, "patch.json" });
    try writeTextAtomic(allocator, patch_path,
        \\{"version":1,"author":"test","reason":"proof mismatch fixture","ops":[
        \\{"op":"upsert-intent","intent":{"id":"intent-001","text":"Proof command must match.","category":"requirement","disposition":"covered"}},
        \\{"op":"upsert-item","item":{"id":"st-001","step":"Implement proof mismatch fixture","status":"pending","priority":"high","in_plan":true,"item_type":"feature","intent_refs":["intent-001"],"acceptance":["Completion is proof-gated"],"validation":["zig build test-st"],"lock_roots":["apps/st"],"contract":{"objective":"Exercise proof record diagnostics.","proof_obligations":[{"id":"proof-001","kind":"unit","command":"zig build test-st","required":true}]}}}
        \\]}
    );

    const stdout_guard = try silenceStdout();
    defer restoreStdout(stdout_guard);
    try std.testing.expectEqual(@as(u8, 0), try cmdGraph(allocator, .{ .command = .graph, .graph_command = .apply, .file = plan_path, .input = patch_path, .gate = .implementation_ready }));
    try std.testing.expectEqual(@as(u8, 2), try cmdProofRecord(allocator, .{ .command = .proof, .proof_command = .record, .file = plan_path, .id = "st-001", .obligation_id = "proof-001", .action_id = "proof-action-test", .step = "zig build other", .evidence_ref = "test.log", .artifact_ref = "git:test" }));

    var loaded = try loadValidatedState(allocator, plan_path, false);
    defer loaded.state.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.state.getConst("st-001").?.proof_receipts.len);
}

test "legacy proof cannot satisfy multiple distinct required commands" {
    const obligations = [_]ProofObligation{
        .{ .id = "proof-001", .kind = "unit", .command = "zig build test-st", .required = true },
        .{ .id = "proof-002", .kind = "build", .command = "zig build build-st", .required = true },
    };
    const item = Item{
        .id = "st-001",
        .step = "Legacy proof fixture",
        .status = .pending,
        .priority = .high,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .proof = .{ .state = .pass, .command = "zig build test-st", .evidence_ref = "proof.log", .last_run_at = "2026-06-18T00:00:00Z" },
        .item_type = .feature,
        .contract = .{ .proof_obligations = obligations[0..] },
    };
    try std.testing.expectEqualStrings("legacy proof cannot satisfy multiple distinct required commands", proofCompletionMissingReason(item).?);
}

test "proof basis deduplicates identical direct proof commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obligation_1 = [_]ProofObligation{.{ .id = "proof-001", .kind = "unit", .command = "zig build test-st", .required = true }};
    const obligation_2 = [_]ProofObligation{.{ .id = "proof-001", .kind = "unit", .command = "zig build test-st", .required = true }};
    var state = ItemState.init(allocator);
    defer state.deinit();
    try state.upsert(.{
        .id = "st-001",
        .step = "First selected item",
        .status = .pending,
        .priority = .high,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .contract = .{ .proof_obligations = obligation_1[0..] },
    });
    try state.upsert(.{
        .id = "st-002",
        .step = "Second selected item",
        .status = .pending,
        .priority = .high,
        .in_plan = true,
        .deps = &.{},
        .notes = "",
        .comments = &.{},
        .item_type = .feature,
        .contract = .{ .proof_obligations = obligation_2[0..] },
    });

    var actions = std.ArrayList(ProofAction).empty;
    try appendSyntheticProofActions(allocator, &state, &actions);
    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    const basis = try directProofBasisAlloc(allocator, &state, actions.items);
    try std.testing.expectEqual(@as(usize, 1), basis.actions.len);
    try std.testing.expectEqualStrings("zig build test-st", basis.actions[0].command);
    try std.testing.expectEqual(@as(usize, 2), basis.actions[0].covers.len);
}

test "complete parses legacy positional id and proof evidence alias" {
    const args = try parseArgs(&.{
        "st",
        "complete",
        "st-982",
        "--proof",
        ".step/proof/st-982.log",
        "--proof-id",
        "proof-001",
        "--command",
        "zig build test-st --summary all",
        "--now",
        "2026-06-18T01:02:03Z",
    });

    try std.testing.expectEqual(Command.complete, args.command);
    try std.testing.expectEqualStrings("st-982", args.id.?);
    try std.testing.expectEqualStrings(".step/proof/st-982.log", args.evidence_ref.?);
    try std.testing.expectEqualStrings("proof-001", args.proof_id.?);
    try std.testing.expectEqualStrings("zig build test-st --summary all", args.step.?);
    try std.testing.expectEqualStrings("2026-06-18T01:02:03Z", args.now.?);
}

test "set-proof parses documented proof id and timestamp flags" {
    const args = try parseArgs(&.{
        "st",
        "set-proof",
        "--file",
        ".step/st-plan.jsonl",
        "--id",
        "st-982",
        "--proof-state",
        "pass",
        "--proof-id",
        "proof-001",
        "--command",
        "zig build test-st --summary all",
        "--evidence-ref",
        ".step/proof/st-982.log",
        "--now",
        "2026-06-18T01:02:03Z",
    });

    try std.testing.expectEqual(Command.set_proof, args.command);
    try std.testing.expectEqualStrings("st-982", args.id.?);
    try std.testing.expectEqualStrings("pass", args.proof_state.?);
    try std.testing.expectEqualStrings("proof-001", args.proof_id.?);
    try std.testing.expectEqualStrings("zig build test-st --summary all", args.step.?);
    try std.testing.expectEqualStrings(".step/proof/st-982.log", args.evidence_ref.?);
    try std.testing.expectEqualStrings("2026-06-18T01:02:03Z", args.now.?);
}

test "proof record parses documented full flag combination" {
    const args = try parseArgs(&.{
        "st",
        "proof",
        "record",
        "--file",
        ".step/st-plan.jsonl",
        "--id",
        "st-001",
        "--obligation",
        "proof-001",
        "--action",
        "proof-action-test",
        "--command",
        "zig build test-st",
        "--evidence-ref",
        "test.log",
        "--artifact-ref",
        "git:test",
    });

    try std.testing.expectEqual(Command.proof, args.command);
    try std.testing.expectEqual(ProofCommand.record, args.proof_command);
    try std.testing.expectEqualStrings("st-001", args.id.?);
    try std.testing.expectEqualStrings("proof-001", args.obligation_id.?);
    try std.testing.expectEqualStrings("proof-action-test", args.action_id.?);
    try std.testing.expectEqualStrings("zig build test-st", args.step.?);
    try std.testing.expectEqualStrings("test.log", args.evidence_ref.?);
    try std.testing.expectEqualStrings("git:test", args.artifact_ref.?);
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
